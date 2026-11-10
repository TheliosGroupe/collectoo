"""M2-10 receipts and M2-11 client feed through the database (needs `make up`): statement import ->
match -> allocation -> receipts job. Every payment on a file gets exactly one receipt number with a
current version; the payload's amounts are the ledger's postings; the stored PDF is the one the
receipt row names, and regenerating it in another process gives the same bytes; a reversal issues a
new version, taking the payment off its file a void one; running the job again issues nothing; the
migration's backfill covers allocations made before receipts existed. The client feed shows what
was allocated or held, amounts from the postings, and records its delivery. M2c-2: new versions
carry the servicer's issuer block (template quittance-fr-3, C. com. R123-237/238); a new or changed
identity alone issues no version, so stored receipts keep their bytes."""

import hashlib
import json
import subprocess
import sys
import tempfile
import uuid
from datetime import date
from pathlib import Path
from typing import Any

import psycopg
import pytest
from allocation_helpers import File, Item, create_file, credit, evidence, ops, state, statement
from integration_helpers import DB, as_user, make_tenant, one, storage
from psycopg.types.json import Jsonb
from statement_helpers import bank_tenant
from statement_helpers import drain as drain_payments

from collectoo_worker.jobs import receipts as receipts_job
from collectoo_worker.payments.matching import NAME_NOISE, name_words
from collectoo_worker.runtime.storage import Storage
from collectoo_worker.synth.reconciliation import line_ref

pytestmark = pytest.mark.integration
DAY = date(2026, 10, 12)
REGENERATE = """
import hashlib, json, sys
from datetime import datetime
from collectoo_worker.payments.receipt_pdf import render_receipt
from collectoo_worker.payments.receipts import ReceiptDocument
row = json.load(sys.stdin)
doc = ReceiptDocument(row["number"], row["version"], row["kind"],
                      datetime.fromisoformat(row["known_at"]), row["payload"],
                      row["template_version"])
print(hashlib.sha256(render_receipt(doc)).hexdigest())
"""


def _files(tenant: dict[str, Any]) -> tuple[File, File]:
    a = create_file(
        tenant,
        File(f"V-{uuid.uuid4().hex[:6]}", "b2b", "Verdier SAS",
             [Item("F-1", {"principal": 100_000}, date(2026, 8, 1)),
              Item("F-2", {"principal": 50_000}, date(2026, 9, 1))]),
    )  # fmt: skip
    b = create_file(
        tenant,
        File(f"L-{uuid.uuid4().hex[:6]}", "consumer", "Lilas Dupont",
             [Item("PRET-L", {"accrued_interest": 12_000, "principal": 500_000,
                              "other_balances": 3_000}, None, kind="loan_principal")]),
    )  # fmt: skip
    return a, b


def _receipts(payment: str) -> list[dict[str, Any]]:
    with psycopg.connect(DB) as conn, conn.cursor(row_factory=psycopg.rows.dict_row) as cur:
        rows = cur.execute(
            """select r.id::text, r.number, r.version, r.kind, r.account_id::text, r.payload,
                      r.payload_sha256, r.pdf_sha256, r.known_at, r.template_version,
                      r.renderer_version, d.storage_bucket, d.storage_path, d.sha256 as doc_sha,
                      encode(sha256(convert_to(r.payload::text, 'UTF8')), 'hex') as recomputed
               from public.receipt r join public.document d on d.id = r.document_id
               where r.payment_id = %s order by r.version""",
            (payment,),
        ).fetchall()
    return [dict(r) for r in rows]


def _ledger_lines(payment: str) -> list[tuple[str, str, int]]:
    """(item ref, component, net amount) credited by the payment's live allocations."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select i.ref, la.component, -sum(lp.amount_minor)
               from public.ledger_entry e
               left join public.ledger_entry r on r.id = e.reverses_entry_id
               join public.ledger_posting lp on lp.entry_id = e.id
               join public.ledger_account la on la.id = lp.ledger_account_id
                 and la.book = 'debtor_receivable'
               join public.claim_item i on i.id = la.claim_item_id
               where e.payment_id = %s and coalesce(r.entry_type, e.entry_type) = 'allocation'
               group by i.ref, la.component having sum(lp.amount_minor) <> 0
               order by i.ref, la.component""",
            (payment,),
        ).fetchall()
    return [(r[0], r[1], int(r[2])) for r in rows]


def _payload_lines(payload: dict[str, Any]) -> list[tuple[str, str, int]]:
    return sorted(
        (x["item_ref"], x["component"], int(x["amount_minor"])) for x in payload["allocation"]
    )


def _regenerate(receipt: dict[str, Any]) -> str:
    """The PDF rendered again from the stored row, in another process."""
    row = {
        "number": receipt["number"],
        "version": receipt["version"],
        "kind": receipt["kind"],
        "known_at": receipt["known_at"].isoformat(),
        "payload": receipt["payload"],
        "template_version": receipt["template_version"],  # a stored receipt keeps its template
    }
    out = subprocess.run(  # noqa: S603 - our interpreter, our code
        [sys.executable, "-c", REGENERATE],
        input=json.dumps(row),
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout.strip()


def _queue_receipts(tenant: dict[str, Any], *payments: str) -> None:
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select pgmq.send('payments', %s)",
            (Jsonb({"type": "receipts", "organization_id": str(tenant["servicer"]),
                    "payment_ids": list(payments)}),),
        )  # fmt: skip


def test_each_payment_on_a_file_gets_one_receipt_from_the_ledger_and_regenerates_identically() -> (
    None
):
    tenant = bank_tenant()
    a, b = _files(tenant)
    store = storage()
    ids = statement(
        tenant,
        store,
        [
            credit(120_000, "REGLT FACTURES", rf=a.rf, name="VERDIER SAS"),
            credit(520_000, "ECHEANCE PRET", rf=b.rf, name="SOCIETE GENERALE POUR M DURAND"),
            credit(7_500, "REMBOURSEMENT", name="INCONNU"),
        ],
        "RQ",
        DAY,
        receipts=True,
    )
    p1, p2, p3 = (ids[line_ref("RQ", k)] for k in (1, 2, 3))
    assert state(p1) == ("allocated", None)
    assert state(p2) == ("partially_allocated", "overpayment")
    assert _receipts(p3) == []  # no file, no debtor known: no receipt (design §2 #8)

    (r1,) = _receipts(p1)
    (r2,) = _receipts(p2)
    for r in (r1, r2):
        assert (r["version"], r["kind"]) == (1, "original")
        assert r["number"].startswith("Q-2026-") and len(r["number"]) == len("Q-2026-000001")
        assert r["payload_sha256"] == r["recomputed"]  # sha256 of the canonical jsonb
        assert r["pdf_sha256"] == r["doc_sha"]
        assert r["storage_bucket"] == "documents"
        assert r["storage_path"] == (f"receipts/{tenant['servicer']}/2026/{r['number']}-v1.pdf")
        # the stored object is the PDF the row names, and another process renders the same bytes
        with tempfile.TemporaryDirectory() as tmp:
            data = store.download("documents", r["storage_path"], Path(tmp) / "q.pdf").read_bytes()
        assert data.startswith(b"%PDF-")
        assert hashlib.sha256(data).hexdigest() == r["pdf_sha256"] == _regenerate(r)
        assert "remaining" not in json.dumps(r["payload"])  # no balance until M3 (founder #14)
    assert r1["number"] != r2["number"]

    # amounts are the ledger's: lines = the live allocation postings; totals add up to the payment
    for p, r, amount in ((p1, r1, 120_000), (p2, r2, 520_000)):
        payload = r["payload"]
        assert _payload_lines(payload) == _ledger_lines(p)
        totals = {k: int(v) for k, v in payload["totals"].items()}
        assert totals["allocated_minor"] == sum(x[2] for x in _ledger_lines(p))
        assert sum(totals.values()) == amount
        assert payload["payment"]["amount_minor"] == str(amount)
    assert r1["payload"]["totals"]["unallocated_minor"] == "0"
    assert r2["payload"]["totals"]["unallocated_minor"] == "8000"  # « Montant non imputé »
    # founder #15: the payer is named only when he is a party to the file, by the party's own name
    assert r1["payload"]["payer"] == {"name": "Verdier SAS", "third_party": False}
    assert r2["payload"]["payer"] == {"name": None, "third_party": True}
    assert "GENERALE" not in json.dumps(r2["payload"])
    assert r1["payload"]["debtor"] == {"name": "Verdier SAS"}

    # idempotent: the same job again issues nothing
    _queue_receipts(tenant, p1, p2, p3)
    drain_payments(store, receipts=True)
    assert [len(_receipts(p)) for p in (p1, p2, p3)] == [1, 1, 0]


def test_a_reversal_issues_a_new_version_and_leaving_the_file_a_void_one() -> None:
    tenant = bank_tenant()
    a, _ = _files(tenant)
    other = create_file(
        tenant,
        File(f"W-{uuid.uuid4().hex[:6]}", "b2b", "Autre SAS",
             [Item("W-1", {"principal": 90_000}, date(2026, 8, 1))]),
    )  # fmt: skip
    store = storage()
    p = statement(tenant, store, [credit(30_000, "REGLT", rf=a.rf)], "RV", DAY, receipts=True)[
        line_ref("RV", 1)
    ]
    (v1,) = _receipts(p)
    assert _payload_lines(v1["payload"]) == [("F-1", "principal", 30_000)]

    with psycopg.connect(DB) as conn:
        entries = [
            r[0]
            for r in conn.execute(
                "select id::text from public.ledger_entry where payment_id = %s", (p,)
            ).fetchall()
        ]
    ops(tenant, "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        str(uuid.uuid4()), p, a.id, entries, "mauvais dossier")  # fmt: skip
    drain_payments(store, receipts=True)
    assert state(p) == ("matched", "allocation_reversed")
    v1_, v2 = _receipts(p)
    assert v1_ == v1  # versions are kept
    assert (v2["number"], v2["version"], v2["kind"]) == (v1["number"], 2, "update")
    assert v2["payload"]["allocation"] == []
    assert v2["payload"]["totals"]["unallocated_minor"] == "30000"
    assert v2["storage_path"].endswith(f"{v1['number']}-v2.pdf")

    ops(tenant, "select public.unassign_payment(%s, %s, %s)", str(uuid.uuid4()), p,
        "ne concerne pas ce dossier")  # fmt: skip
    drain_payments(store, receipts=True, allocate=False)
    *_, v3 = _receipts(p)
    assert (v3["version"], v3["kind"], v3["account_id"]) == (3, "void", a.id)
    assert v3["payload"]["state"] == "void" and "allocation" not in v3["payload"]
    assert _regenerate(v3) == v3["pdf_sha256"]

    _queue_receipts(tenant, p)
    drain_payments(store, receipts=True)
    assert len(_receipts(p)) == 3  # void again: nothing new

    # assigned to the right file: a new version for its debtor, same number
    ops(tenant, "select public.assign_payment(%s, %s, %s, null, %s)", str(uuid.uuid4()), p,
        json.dumps([{"account_id": other.id}]), "bon dossier")  # fmt: skip
    drain_payments(store, receipts=True)
    assert state(p) == ("allocated", None)
    *_, v4 = _receipts(p)
    assert (v4["number"], v4["version"], v4["kind"], v4["account_id"]) == (
        v1["number"], 4, "update", other.id
    )  # fmt: skip
    assert v4["payload"]["debtor"] == {"name": "Autre SAS"}
    assert _payload_lines(v4["payload"]) == [("W-1", "principal", 30_000)]


def _hold_receipt_jobs(tenant: dict[str, Any], seconds: int) -> int:
    """Receipt jobs of the servicer kept out of sight for `seconds` (a backlog, a retry backoff);
    0 brings them back."""
    with psycopg.connect(DB) as conn, conn.transaction():
        return int(
            one(
                conn,
                """select count(*) from pgmq.q_payments q
                   cross join lateral pgmq.set_vt('payments', q.msg_id, %s::integer) v
                   where q.message ->> 'type' = 'receipts'
                     and q.message ->> 'organization_id' = %s""",
                (seconds, str(tenant["servicer"])),
            )
        )


def test_a_payment_moved_before_its_receipts_jobs_run_gets_a_void_version_first() -> None:
    """Review #1: ops reverse, unassign and assign the payment to another file, and the allocation
    there runs, all before the receipts jobs queued meanwhile (a backlog): the first file still
    gets its void version, then the new file its update."""
    tenant = bank_tenant()
    a, _ = _files(tenant)
    other = create_file(
        tenant,
        File(f"W-{uuid.uuid4().hex[:6]}", "b2b", "Autre SAS",
             [Item("W-1", {"principal": 90_000}, date(2026, 8, 1))]),
    )  # fmt: skip
    store = storage()
    p = statement(tenant, store, [credit(30_000, "REGLT", rf=a.rf)], "MV", DAY, receipts=True)[
        line_ref("MV", 1)
    ]
    (v1,) = _receipts(p)
    with psycopg.connect(DB) as conn:
        entries = [
            r[0]
            for r in conn.execute(
                "select id::text from public.ledger_entry where payment_id = %s", (p,)
            ).fetchall()
        ]
    ops(tenant, "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        str(uuid.uuid4()), p, a.id, entries, "mauvais dossier")  # fmt: skip
    ops(tenant, "select public.unassign_payment(%s, %s, %s)", str(uuid.uuid4()), p,
        "ne concerne pas ce dossier")  # fmt: skip
    ops(tenant, "select public.assign_payment(%s, %s, %s, null, %s)", str(uuid.uuid4()), p,
        json.dumps([{"account_id": other.id}]), "bon dossier")  # fmt: skip
    assert _hold_receipt_jobs(tenant, 3600) == 2  # the reversal's and the unassignment's
    drain_payments(store, receipts=True)  # the allocation on the new file first, its receipts job
    assert state(p) == ("allocated", None)
    assert _hold_receipt_jobs(tenant, 0) == 2
    drain_payments(store, receipts=True)  # then the late jobs: nothing more
    assert [(r["version"], r["kind"], r["account_id"]) for r in _receipts(p)] == [
        (1, "original", a.id),
        (2, "void", a.id),
        (3, "update", other.id),
    ]
    *_, v2, v3 = _receipts(p)
    assert v2["number"] == v3["number"] == v1["number"]
    assert v2["payload"]["file"] == v1["payload"]["file"] and "allocation" not in v2["payload"]
    assert _payload_lines(v3["payload"]) == [("W-1", "principal", 30_000)]


class FlakyStorage:
    """The real bucket, but one upload fails (the n-th) and every upload is recorded."""

    def __init__(self, inner: Storage, fail_at: int | None) -> None:
        self.inner, self.fail_at, self.uploads = inner, fail_at, 0
        self.paths: list[str] = []

    def download(self, bucket: str, path: str, dest: Path) -> Path:
        return self.inner.download(bucket, path, dest)

    def upload(
        self, bucket: str, path: str, data: bytes, content_type: str = "application/octet-stream"
    ) -> None:
        self.uploads += 1
        if self.uploads == self.fail_at:
            raise RuntimeError("storage unavailable (test)")
        self.inner.upload(bucket, path, data, content_type)
        self.paths.append(path)

    def remove(self, bucket: str, paths: list[str]) -> None:
        self.inner.remove(bucket, paths)


def _objects(paths: list[str]) -> int:
    with psycopg.connect(DB) as conn:
        return int(
            one(
                conn,
                "select count(*) from storage.objects where bucket_id = 'documents' "
                "and name = any(%s)",
                (paths,),
            )
        )


@pytest.mark.parametrize("fail", ["upload", "issue"])
def test_a_failed_attempt_removes_the_pdfs_it_uploaded(
    fail: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Review #11: the PDFs are uploaded before the transaction that records them commits; when the
    attempt fails (an upload, or recording them), it removes what it uploaded: no PDF of a
    receipt that does not exist stays in the bucket."""
    tenant = bank_tenant()
    a, _ = _files(tenant)
    store = storage()
    ids = statement(tenant, store, [credit(1_000, "R", rf=a.rf) for _ in range(3)], "FA", DAY)
    flaky = FlakyStorage(store, 3 if fail == "upload" else None)
    if fail == "issue":  # refused by receipt_issue's check, after every upload
        monkeypatch.setattr(receipts_job, "TEMPLATE_VERSION", "NOT A VERSION")
    message = {
        "type": "receipts",
        "organization_id": str(tenant["servicer"]),
        "payment_ids": sorted(ids.values()),
    }
    with pytest.raises(Exception), psycopg.connect(DB) as conn, conn.transaction():  # noqa: B017
        receipts_job.run_receipts(conn, flaky, message)
    assert len(flaky.paths) == (2 if fail == "upload" else 3)
    assert _objects(flaky.paths) == 0
    assert all(_receipts(p) == [] for p in ids.values())


def test_the_sweep_removes_receipt_pdfs_no_document_names(monkeypatch: pytest.MonkeyPatch) -> None:
    """Review #11: what a killed attempt left (no document row) is removed by the daily sweep, under
    the servicer's receipts lock; recorded receipts and other servicers' objects stay."""
    tenant = bank_tenant()
    a, _ = _files(tenant)
    store = storage()
    p = statement(tenant, store, [credit(1_000, "R", rf=a.rf)], "SW", DAY, receipts=True)[
        line_ref("SW", 1)
    ]
    (kept,) = _receipts(p)
    stranger = make_tenant()
    orphans = [f"receipts/{tenant['servicer']}/2026/Q-2026-99999{n}-v1.pdf" for n in range(3)]
    elsewhere = f"receipts/{stranger['servicer']}/2026/Q-2026-999999-v1.pdf"
    for path in [*orphans, elsewhere]:
        store.upload("documents", path, b"%PDF-1.4 orphan", "application/pdf")
    monkeypatch.setattr(receipts_job, "SWEEP_AGE", "0 seconds")
    monkeypatch.setattr(receipts_job, "SWEEP_LIMIT", 2)  # more than one batch: it queues the rest
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select pgmq.send('payments', %s)",
            (Jsonb({"type": "receipts_sweep", "organization_id": str(tenant["servicer"])}),),
        )
    drain_payments(store)
    assert _objects(orphans) == 0
    assert _objects([kept["storage_path"], elsewhere]) == 2
    store.remove("documents", [elsewhere])


def test_the_receipt_name_words_are_the_matching_rules_words() -> None:
    """The payer rule compares word sets built in SQL (private.name_word_set) with the matching
    rules' list (payments.matching NAME_NOISE): both give the same words for the same name."""
    names = [
        "M. Jean-Pierre DUPONT",
        "M OU MME LILAS JEAN-PIERRE ET MARIE",
        "S.A.R.L. Les Jardins de l'Œuvre",
        "SOCIETE GENERALE POUR M DURAND",
        "MME VVE DUPONT JEAN",
        "J P DUPONT",
        "Dupont d'Argent",
        "Élodie Bérénice Ñúñez",
        "CŒUR & FILS SAS",
        "SCI 2000",
        "Straße",
        "Le Roux De Sousa",
        *sorted(NAME_NOISE),
        *(f"{w} DURAND JEAN" for w in sorted(NAME_NOISE)),
    ]
    with psycopg.connect(DB) as conn:
        for name in names:
            sql = one(conn, "select private.name_word_set(%s)", (name,))
            assert sorted(sql) == sorted(set(name_words(name))), name


def test_the_backfill_issues_receipts_for_allocations_made_before_receipts() -> None:
    tenant = bank_tenant()
    a, b = _files(tenant)
    store = storage()
    ids = statement(
        tenant, store, [credit(10_000, "R", rf=a.rf), credit(20_000, "R", rf=b.rf)], "BF", DAY
    )  # receipts not run: as before the migration
    payments = list(ids.values())
    assert all(_receipts(p) == [] for p in payments)
    with psycopg.connect(DB) as conn, conn.transaction():
        queued = one(conn, "select private.queue_receipt_backfill(%s)", (tenant["servicer"],))
    assert queued == 1  # 200 payments per job
    drain_payments(store, receipts=True)
    assert [len(_receipts(p)) for p in payments] == [1, 1]
    with psycopg.connect(DB) as conn, conn.transaction():
        assert one(conn, "select private.queue_receipt_backfill(%s)", (tenant["servicer"],)) == 0


def test_a_job_takes_bounded_chunks_and_queues_the_rest(monkeypatch: pytest.MonkeyPatch) -> None:
    tenant = bank_tenant()
    a, _ = _files(tenant)
    store = storage()
    ids = statement(tenant, store, [credit(1_000, "R", rf=a.rf) for _ in range(3)], "CK", DAY)
    payments = sorted(ids.values())
    monkeypatch.setattr(receipts_job, "CHUNK", 2)
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        out = receipts_job.run_receipts(
            conn, store,
            {"type": "receipts", "organization_id": str(tenant["servicer"]),
             "payment_ids": payments},
        )  # fmt: skip
        assert out == {"payments": 2, "issued": 2}
        rest = one(
            conn,
            """select message from pgmq.q_payments where message ->> 'type' = 'receipts'
               and message ->> 'organization_id' = %s order by msg_id desc limit 1""",
            (str(tenant["servicer"]),),
        )
        assert rest["payment_ids"] == payments[2:]


def test_a_held_payment_gets_its_receipt_and_the_client_reads_the_feed() -> None:
    tenant = bank_tenant()
    a, b = _files(tenant)
    proof = evidence(tenant, b.id)
    hold = "select public.place_account_hold(%s, %s, 'surendettement', 'C. conso L722-5', %s, %s)"
    ops(tenant, hold, str(uuid.uuid4()), b.id, proof, "recevabilité")
    store = storage()
    ids = statement(
        tenant,
        store,
        [credit(30_000, "R", rf=a.rf, name="VERDIER"), credit(20_000, "ECHEANCE", rf=b.rf)],
        "FD",
        DAY,
        receipts=True,
    )
    allocated, held = ids[line_ref("FD", 1)], ids[line_ref("FD", 2)]
    assert state(held) == ("matched", "hold_blocks_allocation")
    (r,) = _receipts(held)
    assert r["payload"]["allocation"] == []
    assert r["payload"]["totals"]["unallocated_minor"] == "20000"  # neutral: « non imputé »
    assert "hold" not in json.dumps(r["payload"])
    assert "surendettement" not in json.dumps(r, default=str)

    def feed(user: str, client: Any) -> list[dict[str, Any]]:
        with psycopg.connect(DB) as conn, conn.transaction():
            as_user(conn, user, "aal2")
            conn.execute("set local statement_timeout = '8s'")
            with conn.cursor(row_factory=psycopg.rows.dict_row) as cur:
                return [
                    dict(x)
                    for x in cur.execute(
                        "select * from public.client_payment_feed(%s)", (client,)
                    ).fetchall()
                ]

    staff_view = feed(tenant["staff"], tenant["client"])
    assert {x["kind"] for x in staff_view} == {"payment_allocated", "payment_held"}
    assert all(x["delivered_at"] is None for x in staff_view)  # staff reading is no delivery
    rows = feed(tenant["user"], tenant["client"])
    by_kind = {x["kind"]: x for x in rows}
    assert by_kind["payment_allocated"]["amount_minor"] == "30000"  # the entry's 4670 posting
    assert [(x["item_ref"], x["amount_minor"]) for x in by_kind["payment_allocated"]["lines"]] == [
        ("F-1", "30000")
    ]
    assert by_kind["payment_held"]["amount_minor"] == "20000"
    assert by_kind["payment_held"]["reason"] == "hold_blocks_allocation"
    assert by_kind["payment_allocated"]["receipt_number"] == _receipts(allocated)[0]["number"]
    assert all(x["first_view"] and x["delivered_at"] is not None for x in rows)
    again = feed(tenant["user"], tenant["client"])
    assert not any(x["first_view"] for x in again)
    assert [x["delivered_at"] for x in again] == [x["delivered_at"] for x in rows]
    # another client's member reads nothing of it
    stranger = make_tenant()
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        feed(stranger["user"], tenant["client"])


def _set_servicer_identity(tenant: dict[str, Any], city: str) -> None:
    """The servicer's billing identity (synthetic SIREN 849 678 297), its registered office in
    `city`: what receipts print from M2c-2 on."""
    office = {"line1": "10 rue de la Bourse", "postcode": "75002", "city": city, "country": "FR"}
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "update public.organization set siren = '849678297' where id = %s",
            (tenant["servicer"],),
        )
        conn.execute(
            """insert into public.billing_identity (organization_id, legal_form,
                 share_capital_minor, rcs_city, registered_office, vat_number, is_professional)
               values (%s, 'SAS', 1000000, 'Paris', %s, 'FR33849678297', true)
               on conflict (organization_id) do update
               set registered_office = excluded.registered_office""",
            (tenant["servicer"], Jsonb(office)),
        )


def test_new_versions_carry_the_issuer_block_and_an_identity_alone_issues_none() -> None:
    tenant = bank_tenant()
    a, _ = _files(tenant)
    store = storage()
    # a receipt issued before the servicer had a billing identity: its name only
    p = statement(tenant, store, [credit(30_000, "REGLT", rf=a.rf)], "IS", DAY, receipts=True)[
        line_ref("IS", 1)
    ]
    (v1,) = _receipts(p)
    assert set(v1["payload"]["issuer"]) == {"name"}

    # the identity alone (as at the M2c-2 migration): the job issues nothing, the PDF stays
    _set_servicer_identity(tenant, "Paris")
    _queue_receipts(tenant, p)
    drain_payments(store, receipts=True)
    assert _receipts(p) == [v1]
    assert _regenerate(v1) == v1["pdf_sha256"]

    # what the receipt says about the payment changes: the new version carries the block
    with psycopg.connect(DB) as conn:
        entries = [
            r[0]
            for r in conn.execute(
                "select id::text from public.ledger_entry where payment_id = %s", (p,)
            ).fetchall()
        ]
    ops(tenant, "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        str(uuid.uuid4()), p, a.id, entries, "erreur")  # fmt: skip
    drain_payments(store, receipts=True)
    _, v2 = _receipts(p)
    assert (v2["version"], v2["template_version"]) == (2, "quittance-fr-3")
    issuer = v2["payload"]["issuer"]
    assert (issuer["siren"], issuer["rcs_city"], issuer["legal_form"]) == (
        "849678297",
        "Paris",
        "SAS",
    )
    assert issuer["registered_office"]["city"] == "Paris"
    assert _regenerate(v2) == v2["pdf_sha256"]
    # a later change of the registered office alone issues nothing either
    _set_servicer_identity(tenant, "Lyon")
    _queue_receipts(tenant, p)
    drain_payments(store, receipts=True)
    assert len(_receipts(p)) == 2
