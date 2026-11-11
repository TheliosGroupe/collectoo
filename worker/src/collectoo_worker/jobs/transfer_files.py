"""Job `remittances.transfer_file {file_id, token}` (M2c-6a; design §11, §16): write one pain.001
file that `public.generate_transfer_file` reserved.

One transaction (the queue's, exactly once):

1. under a savepoint, `private.transfer_file_begin` returns what the file holds, frozen at
   generation (null: the file was superseded meanwhile, or the token is another job's — nothing to
   do), and holds the file row until the commit;
2. `remittance.pain001.render` writes the bytes (deterministic: a retry writes the same ones),
   `pain001.check` verifies every field design §11 lists, and the ISO 20022 XSD of the version
   validates them when it is vendored (docs/reference/iso20022/README.md; whether it did is
   recorded on the file);
3. the bytes go to the private bucket `transfer-files` at `<servicer>/<file>/<number>.xml`, then
   `private.transfer_file_record` stores their SHA-256 (the web route checks it before serving the
   file) and the file is `generated`.

A data error (the writer's `Pain001Error`, SQLSTATE 22/23/LG) rolls the savepoint back, removes
what was uploaded and fails the file at once (`private.transfer_file_failed`: its transfers wait for
the next file; the nightly alert `transfer_file_failed` says why). Any other error fails the job,
which the queue retries; the dead-letter hook fails the file then. No model, no LLM: every amount
comes from the transfers (CLAUDE.md).
"""

from __future__ import annotations

import hashlib
import logging
import time
from datetime import date
from typing import Any

import psycopg

from collectoo_worker.remittance import pain001
from collectoo_worker.remittance.pain001 import (
    RENDERER_VERSION,
    Pain001Error,
    PaymentInfo,
    Transaction,
    TransferFile,
)
from collectoo_worker.runtime.storage import Storage

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.remittances")
BUCKET = "transfer-files"


def deterministic(exc: BaseException) -> bool:
    if isinstance(exc, Pain001Error):
        return True
    return isinstance(exc, psycopg.Error) and (exc.sqlstate or "").startswith(("LG", "22", "23"))


def transfer_file_from(body: dict[str, Any]) -> TransferFile:
    """The writer's input from `private.transfer_file_begin` (amounts as text → int)."""
    return TransferFile(
        version=str(body["version"]),
        msg_id=str(body["msg_id"]),
        created_at=str(body["created_at"]),
        initiating_party=str(body["initiating_party"]),
        payment_infos=tuple(
            PaymentInfo(
                pmt_inf_id=str(p["pmt_inf_id"]),
                requested_execution_date=date.fromisoformat(str(p["execution_date"])),
                debtor_name=str(p["debtor_name"]),
                debtor_iban=str(p["debtor_iban"]),
                debtor_bic=p.get("debtor_bic"),
                transactions=tuple(
                    Transaction(
                        instr_id=str(t["instr_id"]),
                        end_to_end_id=str(t["end_to_end_id"]),
                        amount_minor=int(t["amount_minor"]),
                        currency=str(t["currency"]),
                        creditor_name=str(t["creditor_name"]),
                        creditor_iban=str(t["creditor_iban"]),
                        creditor_bic=t.get("creditor_bic"),
                        remittance_info=str(t["remittance_info"] or ""),
                    )
                    for t in p["transactions"]
                ),
            )
            for p in body["payment_infos"]
        ),
    )


def write_file(body: dict[str, Any]) -> tuple[bytes, dict[str, Any], bool]:
    """The bytes, the check's facts, and whether the XSD validated them (False: not vendored)."""
    f = transfer_file_from(body)
    data = pain001.render(f)
    facts = pain001.check(data, f.version)
    if facts["nb_of_txs"] != int(body["nb_of_txs"]) or facts["ctrl_sum_minor"] != int(
        body["ctrl_sum_minor"]
    ):
        raise Pain001Error("the written file differs from what was generated (NbOfTxs, CtrlSum)")
    try:
        pain001.validate_xsd(data, f.version)
        validated = True
    except pain001.XsdUnavailableError:
        validated = False
    return data, facts, validated


def _remove_quietly(storage: Storage, path: str | None) -> None:
    if path is None:
        return
    try:
        storage.remove(BUCKET, [path])
    except Exception:
        log.exception("transfer file: %s not removed (left to the sweep)", path)


def run_transfer_file(conn: Conn, storage: Storage, payload: dict[str, Any]) -> dict[str, Any]:
    file_id, token = str(payload["file_id"]), str(payload["token"])
    started = time.monotonic()
    uploaded: str | None = None
    try:
        with conn.transaction():
            row = conn.execute(
                "select private.transfer_file_begin(%s, %s)", (file_id, token)
            ).fetchone()
            body = row[0] if row else None
            if body is None:
                log.info("transfer file %s: nothing to write (superseded, or not its job)", file_id)
                return {"status": "skipped"}
            t0 = time.monotonic()
            data, facts, validated = write_file(body)
            t1 = time.monotonic()
            path = str(body["storage_path"])
            uploaded = path
            storage.upload(BUCKET, path, data, "application/xml")
            t2 = time.monotonic()
            res = conn.execute(
                "select private.transfer_file_record(%s, %s, %s, %s, %s, %s, %s, %s, %s)",
                (
                    file_id,
                    token,
                    hashlib.sha256(data).hexdigest(),
                    len(data),
                    path,
                    validated,
                    RENDERER_VERSION,
                    facts["nb_of_txs"],
                    facts["ctrl_sum_minor"],
                ),
            ).fetchone()
    except BaseException as exc:
        if not deterministic(exc):
            if uploaded is not None:
                _remove_quietly(storage, uploaded)
            raise
        _remove_quietly(storage, uploaded)
        message = (
            exc.diag.message_primary
            if isinstance(exc, psycopg.Error) and exc.diag.message_primary
            else str(exc)
        )
        log.warning("transfer file %s: not written (%s)", file_id, message)
        conn.execute(
            "select private.transfer_file_failed(%s, %s, %s)", (file_id, token, message[:2000])
        )
        return {"status": "failed", "error": message}
    result = dict(res[0]) if res else {}
    log.info(
        "transfer file %s: %s, %s transactions, %d bytes, XSD %s; write %.2fs, upload %.2fs, %.2fs",
        body["number"],
        result.get("status"),
        facts["nb_of_txs"],
        len(data),
        "validated" if validated else "not vendored",
        t1 - t0,
        t2 - t1,
        time.monotonic() - started,
    )
    return {**result, "xsd_validated": validated, "bytes": len(data)}


def record_dead_job(payload: dict[str, Any], error: str, conn: Conn) -> None:
    """Retried to the end: the file fails, its transfers wait for the next one."""
    file_id, token = payload.get("file_id"), payload.get("token")
    if file_id and token:
        conn.execute(
            "select private.transfer_file_failed(%s, %s, %s)",
            (str(file_id), str(token), error[:2000]),
        )
