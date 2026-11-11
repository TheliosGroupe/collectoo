"""M2c-6a transfer files through the database, the worker and storage (needs `make up`; design
§11, §9.7 to §9.9, §18 « pain.001: … golden bytes, CtrlSum and NbOfTxs, unique end-to-end ids
≤ 35, charset property, same bytes when downloaded twice »; ADR-0014 M2c-6a addendum).

* two clients paid on one statement, their runs approved: `generate_transfer_file` reserves a file
  of both payouts (the cash check reads the statement's closing balance), the `transfer_file` job
  on the remittances queue writes it, checks it and uploads it; the stored bytes are the recorded
  SHA-256, carry every field design §11 lists (MsgId = the file number, CtrlSum = Σ nets from
  integer minor units, our RMT ids, the payees as on their RIB, the run and invoice numbers in
  RmtInf), and validate against the structural check; the XSD is recorded as not vendored;
* `.03` per bank account: a new generation replaces the file not downloaded yet (new MsgId, the
  `.03` namespace), the job of the superseded file writes nothing;
* two generations at once for one account: the second waits for the first's locks, then replaces
  it (one live file per account);
* download: the hash check, every download recorded, the second one only with the warning
  acknowledged; the runs sent;
* a payee whose name has no EPC character: the job fails the file (a data error, not retried) and
  its transfer waits for the next file.
"""

from __future__ import annotations

import hashlib
import threading
import time
import uuid
from pathlib import Path
from typing import Any

import psycopg
import pytest
from allocation_helpers import File, Item, create_file, statement
from allocation_helpers import credit as bank_credit
from integration_helpers import DB, as_user, one, storage
from lxml import etree
from remittance_helpers import (
    add_admin,
    add_client,
    approve,
    drain,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)

from collectoo_worker.remittance import pain001
from collectoo_worker.synth.ids import iban_fr

pytestmark = pytest.mark.integration


def _own_account(tenant: dict[str, Any]) -> str:
    import random  # noqa: PLC0415 - one synthetic IBAN

    with psycopg.connect(DB) as conn, conn.transaction():
        own = one(
            conn,
            """insert into public.bank_account (organization_id, purpose, iban, currency, label,
                 opened_on) values (%s, 'own', %s, 'EUR', 'Compte propre', '2026-01-01')
               returning id""",
            (tenant["servicer"], iban_fr(random.Random(f"own-{tenant['servicer']}"))),
        )
        conn.execute(
            """insert into public.servicer_billing_settings (organization_id, own_bank_account_id)
               values (%s, %s) on conflict (organization_id)
               do update set own_bank_account_id = excluded.own_bank_account_id""",
            (tenant["servicer"], own),
        )
    return str(own)


def _file(tenant: dict[str, Any], amount: int) -> File:
    return create_file(
        tenant,
        File(
            f"F-{uuid.uuid4().hex[:8]}",
            "b2b",
            "Débiteur SARL",
            [Item("INV-1", {"principal": amount}, recent_business_day(30))],
        ),
    )


def _two_runs() -> tuple[dict[str, Any], dict[str, Any], str, str]:
    """Martin 2 000,00 € and Lilas 5 120,00 € paid on one statement; their runs approved."""
    tenant = remittance_tenant()
    other = add_client(tenant, "Lilas Finance")
    _own_account(tenant)
    f1, f2 = _file(tenant, 200_000), _file(other, 512_000)
    prefix = f"T{uuid.uuid4().hex[:6].upper()}"
    statement(
        tenant,
        storage(),
        [bank_credit(200_000, rf=f1.rf), bank_credit(512_000, rf=f2.rf)],
        prefix,
        recent_business_day(),
    )
    r1, r2 = request_run(tenant), request_run(other)
    approve(tenant, r1, r2)
    drain()
    assert run_row(r1)["status"] == run_row(r2)["status"] == "approved"
    return tenant, other, r1, r2


def _file_row(file_id: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute("select * from public.transfer_file where id = %s", (file_id,))
        row = cur.fetchone()
        assert row is not None and cur.description is not None
        return {d.name: v for d, v in zip(cur.description, row, strict=True)}


def _bytes(path: str, tmp_path: Path) -> bytes:
    dest = tmp_path / f"{uuid.uuid4().hex}.xml"
    storage().download("transfer-files", path, dest)
    return dest.read_bytes()


def _generate(tenant: dict[str, Any], late: str | None = None) -> dict[str, Any]:
    return dict(
        staff(
            tenant,
            "select public.generate_transfer_file(%s, %s, %s)",
            str(uuid.uuid4()),
            tenant["bank"],
            late,
        )
    )


def _transfers(*runs: str) -> dict[str, dict[str, Any]]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute(
            """select r.id::text, t.end_to_end_id, t.amount_minor, t.status, r.number,
                      t.transfer_file_id::text, r.status
               from public.remittance_run r join public.bank_transfer t on t.id = r.transfer_id
               where r.id = any(%s::uuid[])""",
            (list(runs),),
        )
        return {
            x[0]: {
                "e2e": x[1],
                "amount": x[2],
                "status": x[3],
                "number": x[4],
                "file": x[5],
                "run_status": x[6],
            }
            for x in cur.fetchall()
        }


NS = "{urn:iso:std:iso:20022:tech:xsd:%s}"


def test_a_file_of_two_payouts_written_by_the_job(tmp_path: Path) -> None:
    tenant, _other, r1, r2 = _two_runs()
    res = _generate(tenant)
    assert res["status"] == "pending" and res["nb_of_txs"] == 2
    t = _transfers(r1, r2)
    nets = run_row(r1)["net_minor"] + run_row(r2)["net_minor"]
    assert int(res["ctrl_sum_minor"]) == nets
    drain()
    f = _file_row(res["file_id"])
    assert f["status"] == "generated" and f["xsd_validated"] is False
    assert f["renderer_version"] == pain001.RENDERER_VERSION
    data = _bytes(f["storage_path"], tmp_path)
    assert hashlib.sha256(data).hexdigest() == f["file_sha256"] and len(data) == f["size_bytes"]
    facts = pain001.check(data, "pain.001.001.09")
    assert facts == {
        "msg_id": f["number"],
        "nb_of_txs": 2,
        "ctrl_sum_minor": nets,
        "pmt_inf_ids": [f"{f['number']}-1"],
    }
    doc = etree.fromstring(data)
    ns = NS % "pain.001.001.09"
    e2e = sorted(x.text or "" for x in doc.iter(f"{ns}EndToEndId"))
    assert e2e == sorted(v["e2e"] for v in t.values())
    assert {x.text for x in doc.iter(f"{ns}InstrId")} == {v["number"] for v in t.values()}
    names = [x.text for x in doc.iter(f"{ns}Nm")]
    assert names.count("Client SAS") == 2  # the payout accounts' holder, as on the RIB
    info = [x.text or "" for x in doc.iter(f"{ns}Ustrd")]
    assert all(i.startswith("REVERSEMENT RV-") and " FACTURE FC-" in i for i in info)
    debtor = doc.find(f".//{ns}DbtrAcct/{ns}Id/{ns}IBAN")
    assert debtor is not None and debtor.text == tenant["iban"]
    # the client's money left nothing: no remittance entry before the bank's debit (M2c-6b)
    with psycopg.connect(DB) as conn:
        assert (
            one(
                conn,
                """select count(*) from public.ledger_entry where organization_id = %s
                   and entry_type in ('remittance', 'servicer_sweep')""",
                (tenant["servicer"],),
            )
            == 0
        )


def test_a_new_generation_replaces_a_file_not_downloaded_and_the_bank_reads_03(
    tmp_path: Path,
) -> None:
    tenant, _other, r1, r2 = _two_runs()
    first = _generate(tenant)
    admin = add_admin(tenant)
    staff(
        tenant,
        "select public.set_bank_account_pain_version(%s, %s, 'pain.001.001.03')",
        str(uuid.uuid4()),
        tenant["bank"],
        user=admin,
    )
    second = _generate(tenant)
    assert second["superseded"] == [first["file_id"]]
    drain()  # the first file's job finds it superseded: nothing written
    a, b = _file_row(first["file_id"]), _file_row(second["file_id"])
    assert a["status"] == "superseded" and a["storage_path"] is None
    assert a["superseded_by"] == b["id"]
    assert b["status"] == "generated" and b["pain_version"] == "pain.001.001.03"
    assert b["msg_id"] != a["msg_id"]
    data = _bytes(b["storage_path"], tmp_path)
    assert pain001.check(data, "pain.001.001.03")["nb_of_txs"] == 2
    root = etree.fromstring(data)
    assert root.tag == f"{NS % 'pain.001.001.03'}Document"
    assert {v["file"] for v in _transfers(r1, r2).values()} == {str(b["id"])}


def test_two_generations_at_once_leave_one_live_file() -> None:
    tenant, _other, r1, r2 = _two_runs()
    results: dict[str, Any] = {}
    with psycopg.connect(DB) as a:
        as_user(a, tenant["staff"], "aal2")
        first = a.execute(
            "select public.generate_transfer_file(%s, %s, null)",
            (str(uuid.uuid4()), tenant["bank"]),
        ).fetchone()
        assert first is not None

        def second() -> None:
            results["second"] = _generate(tenant)
            results["at"] = time.monotonic()

        thread = threading.Thread(target=second)
        thread.start()
        time.sleep(1.0)
        assert thread.is_alive(), "the second generation waits for the first one's locks"
        committed = time.monotonic()
        a.commit()
    thread.join(10)
    assert results["at"] >= committed
    assert results["second"]["superseded"] == [first[0]["file_id"]]
    drain()
    live = _transfers(r1, r2)
    assert {v["file"] for v in live.values()} == {results["second"]["file_id"]}
    assert _file_row(results["second"]["file_id"])["status"] == "generated"
    assert _file_row(first[0]["file_id"])["status"] == "superseded"


def test_download_checks_the_hash_and_warns_the_second_time(tmp_path: Path) -> None:
    tenant, _other, r1, r2 = _two_runs()
    res = _generate(tenant)
    drain()
    f = _file_row(res["file_id"])
    data = _bytes(f["storage_path"], tmp_path)
    digest = hashlib.sha256(data).hexdigest()
    with pytest.raises(psycopg.errors.CheckViolation, match="hash_mismatch"):
        staff(tenant, "select public.transfer_file_download(%s, %s)", f["id"], "0" * 64)
    first = staff(tenant, "select public.transfer_file_download(%s, %s)", f["id"], digest)
    assert first["download"] == 1 and first["storage_path"] == f["storage_path"]
    with pytest.raises(psycopg.errors.CheckViolation, match="already_downloaded"):
        staff(tenant, "select public.transfer_file_download(%s, %s)", f["id"], digest)
    again = staff(tenant, "select public.transfer_file_download(%s, %s, true)", f["id"], digest)
    assert again["download"] == 2
    assert _bytes(f["storage_path"], tmp_path) == data  # the same bytes downloaded twice
    assert {v["run_status"] for v in _transfers(r1, r2).values()} == {"sent"}
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            "select n, warning_acknowledged from public.transfer_file_download"
            " where file_id = %s order by n",
            (f["id"],),
        ).fetchall()
    assert rows == [(1, False), (2, True)]


def test_a_payee_name_without_epc_characters_fails_the_file_not_the_queue() -> None:
    tenant = remittance_tenant()
    with psycopg.connect(DB) as conn, conn.transaction():
        # a RIB holder in Greek letters (the guard keeps a confirmed account fixed: set aside here)
        conn.execute(
            "alter table public.client_payout_account disable trigger client_payout_account_guard"
        )
        conn.execute(
            "update public.client_payout_account set holder_name = 'Ωμέγα' where id = %s",
            (tenant["payout"],),
        )
        conn.execute(
            "alter table public.client_payout_account enable always trigger"
            " client_payout_account_guard"
        )
    f1 = _file(tenant, 100_000)
    statement(
        tenant,
        storage(),
        [bank_credit(100_000, rf=f1.rf)],
        f"G{uuid.uuid4().hex[:6].upper()}",
        recent_business_day(),
    )
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    res = _generate(tenant)
    drain()
    f = _file_row(res["file_id"])
    assert f["status"] == "failed" and "no EPC character" in (f["error"] or "")
    assert _transfers(run)[run]["status"] == "ordered"
