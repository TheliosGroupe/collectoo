"""Job `payments.receipts` (M2-10, CPCE R124-6; design §9, §10): the receipts of these payments.

Queued (200 payments per message) by every ledger entry tagged with a payment and by a payment
given a file, taken off one or gated (migration 20261110090000), and once by that migration for the
payments matched before it (backfill). One transaction (the queue's, exactly once):

1. take the servicer's receipts lock: receipts of one servicer are issued one job at a time (one
   number counter, a payment's versions in order); the allocation lock is not taken, so receipts
   never hold up allocations or ops commands;
2. `private.receipt_prepare`: for each payment, the payload built in SQL from the ledger at the
   job's start (`known_at`); a version is due only when it differs from the current one (the job is
   idempotent), a void one first when the payment's current version is about another file than its
   own now (the payment is then queued again for its new file's version); numbers are drawn for
   first versions;
3. render each PDF (`payments.receipt_pdf`, deterministic) and upload it to the private bucket
   `documents` at its key, uploads running alongside the rendering (`UPLOADS` at a time);
4. `private.receipt_issue`: one `document` (SHA-256) and one `receipt` row per version.

The PDFs are uploaded before the transaction that records them commits. If the attempt fails after
its uploads started, it removes what it uploaded (best effort) before failing: its keys are above
the last committed number or version and the servicer's lock is still held, so no recorded receipt
is touched. A retry draws its numbers again (others if another job of the servicer committed
meanwhile, or in a new year) and renders new bytes (a new `known_at`); a key it reuses is
overwritten. What a killed attempt leaves is removed by `run_receipt_sweep`.

Job `payments.receipts_sweep` (daily, one per servicer, pg_cron): receipt PDFs of the servicer that
no document names and older than `SWEEP_AGE` are deleted, `SWEEP_LIMIT` per run (the rest queued),
under the servicer's receipts lock.

At most `CHUNK` payments per run: the rest of a longer list is queued in the same transaction. No
model, no LLM: every amount comes from the ledger (CLAUDE.md).
"""

from __future__ import annotations

import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.payments.receipt_pdf import RENDERER_VERSION, pdf_sha256, render_receipt
from collectoo_worker.payments.receipts import TEMPLATE_VERSION, ReceiptDocument
from collectoo_worker.runtime.storage import Storage

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.payments")
CHUNK = int(os.environ.get("RECEIPTS_CHUNK", "200"))  # design §9: 200 per message
UPLOADS = int(os.environ.get("RECEIPTS_UPLOADS", "8"))  # concurrent uploads to Storage
BUCKET = "documents"
SWEEP_AGE = "1 hour"  # an object without its document this old belongs to no running attempt
SWEEP_LIMIT = 1000  # objects removed per sweep run


def _lock(conn: Conn, org: str) -> None:
    conn.execute("select pg_advisory_xact_lock(hashtext('receipts:' || %s))", (org,))


def _remove_quietly(storage: Storage, paths: list[str]) -> None:
    """Best effort: a failed removal is logged and left to the sweep, never raised over the error
    that failed the attempt."""
    if not paths:
        return
    try:
        storage.remove(BUCKET, paths)
    except Exception:
        log.exception("receipts: %d uploaded PDFs not removed (left to the sweep)", len(paths))


def run_receipts(conn: Conn, storage: Storage, payload: dict[str, Any]) -> dict[str, Any]:
    org = str(payload["organization_id"])
    ids = list(dict.fromkeys(str(x) for x in payload.get("payment_ids") or ()))
    if len(ids) > CHUNK:
        rest = {"type": "receipts", "organization_id": org, "payment_ids": ids[CHUNK:]}
        conn.execute("select pgmq.send('payments', %s)", (Jsonb(rest),))
        ids = ids[:CHUNK]
    if not ids:
        return {"payments": 0, "issued": 0}
    started = time.monotonic()
    _lock(conn, org)
    conn.execute("select private.receipt_begin()")
    rows = conn.execute(
        """select payment_id::text, number, version, kind, known_at, storage_path, payload
           from private.receipt_prepare(%s, %s::uuid[])""",
        (org, ids),
    ).fetchall()
    prepared = time.monotonic()
    rendered: list[tuple[str, str]] = []
    uploaded: list[str] = []  # every key an upload was started for
    try:
        # Rendering is CPU-bound (one at a time); uploads wait on the network: they run alongside.
        # Leaving the block waits for every started upload, even on an error.
        with ThreadPoolExecutor(max_workers=UPLOADS) as pool:
            uploads = []
            for payment_id, number, version, kind, known_at, path, body in rows:
                pdf = render_receipt(ReceiptDocument(number, int(version), kind, known_at, body))
                uploaded.append(path)
                uploads.append(pool.submit(storage.upload, BUCKET, path, pdf, "application/pdf"))
                rendered.append((payment_id, pdf_sha256(pdf)))
            for upload in uploads:
                upload.result()  # a failed upload fails the job (retried by the queue)
        stored = time.monotonic()
        with (
            conn.cursor() as cur,
            cur.copy("copy pg_temp._receipt_pdf (payment_id, pdf_sha256) from stdin") as copy,
        ):
            for row in rendered:
                copy.write_row(row)
        found = conn.execute(
            "select private.receipt_issue(%s, %s)", (TEMPLATE_VERSION, RENDERER_VERSION)
        ).fetchone()
    except BaseException:
        _remove_quietly(storage, uploaded)
        raise
    issued = int(found[0]) if found else 0
    log.info(
        "receipts %s: %d payments, %d issued; prepare %.2fs, render + store %.2fs, record %.2fs",
        org,
        len(ids),
        issued,
        prepared - started,
        stored - prepared,
        time.monotonic() - stored,
    )
    return {"payments": len(ids), "issued": issued}


def run_receipt_sweep(conn: Conn, storage: Storage, payload: dict[str, Any]) -> dict[str, Any]:
    """Receipt PDFs of the servicer that no document names, older than `SWEEP_AGE`: deleted. Under
    the servicer's receipts lock, so no attempt of the servicer is uploading meanwhile."""
    org = str(payload["organization_id"])
    _lock(conn, org)
    names = [
        str(r[0])
        for r in conn.execute(
            "select private.receipt_orphan_objects(%s, %s::interval, %s)",
            (org, SWEEP_AGE, SWEEP_LIMIT),
        ).fetchall()
    ]
    if names:
        storage.remove(BUCKET, names)
        log.warning("receipts sweep %s: %d PDFs without a document removed", org, len(names))
    if len(names) == SWEEP_LIMIT:  # more may be left: the next run takes them
        conn.execute("select pgmq.send('payments', %s)", (Jsonb(payload),))
    return {"removed": len(names)}
