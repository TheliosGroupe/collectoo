"""M2c-7c-2 (needs `make up`; plan docs/design/m2c-7-plan.md §5.2.7, §5.4, §5.7 « Worker »; design
§7.3; ADR-0014 « M2c-7c-2 »): the repayment request through the real commands, the real prepare and
the letter's job.

* design §7.3's first variant — Martin's mandate without a claw-back clause: RV-1 (E2 200 000)
  debited, P1 taken back by the bank (A1), RV-3 through the real prepare: N 282 000 (A1 not
  taken); « Demander le remboursement » for A1 (200 000): its letter drawn by the job, stored at
  repayment-requests/<servicer>/<request>.pdf, the stored bytes hashing to its document's SHA-256,
  the client space listing it; Martin repays to the own account (« Règlement du client »): 4112 of
  Martin at 0, advance_open silent;
* [critic] M7-MONEY-3, L7: the request first, then the terms gain a claw-back clause: the real
  prepare leaves A1 to its request (N 282 000); the request withdrawn, « Actualiser » takes it back
  (N 82 000) and the run is approved;
* the letter's job: a replay draws nothing again; a failed upload records nothing and removes what
  it wrote, the job retried draws it.
"""

from __future__ import annotations

import hashlib
import json
import uuid
from datetime import timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from debit_helpers import import_entries, line_id, link_of, return_entry
from integration_helpers import DB, one, storage
from remittance_helpers import (
    TERMS,
    approve,
    book_payout,
    book_sweep,
    drain,
    own_account,
    paid_file,
    paris_today,
    remittance_tenant,
    request_run,
    run_row,
    staff,
    top_up,
)
from test_client_payments_integration import REASON, _evidence

from collectoo_worker.jobs.remittances import make_handler

pytestmark = pytest.mark.integration


def _value(sql: str, *params: Any) -> Any:
    with psycopg.connect(DB) as conn:
        return one(conn, sql, params)


def _cash(tenant: dict[str, Any]) -> int:
    return int(
        _value(
            """select coalesce(sum(p.amount_minor), 0) from public.ledger_posting p
               join public.ledger_account la on la.id = p.ledger_account_id
               where la.book = 'client_money_cash' and la.organization_id = %s""",
            tenant["servicer"],
        )
    )


def _advance_of_return(tenant: dict[str, Any], payment: str) -> str:
    """The bank takes P back (a camt.053 return naming its end-to-end id): the cover A1's id."""
    e2e = str(_value("select end_to_end_id from public.payment where id = %s", payment))
    ref = f"RT{uuid.uuid4().hex[:8].upper()}"
    import_entries(
        tenant,
        storage(),
        [return_entry(200_000, e2e, ref, paris_today())],
        day=paris_today(),
        opening=_cash(tenant),
    )
    line = line_id(tenant, ref)
    assert link_of(line) is not None and link_of(line)[0] == "return"  # type: ignore[index]
    return str(
        _value(
            """select a.id from public.client_advance a
               where a.client_organization_id = %s and a.cause = 'remitted_reversal'""",
            tenant["client"],
        )
    )


def _worked_example(terms: dict[str, Any]) -> tuple[dict[str, Any], str]:
    """§7.2 up to 12/11 and the top-up of 13/11: RV-1 debited and swept, P6 allocated, P1 taken back
    (A1). Returns the tenant and A1."""
    tenant = remittance_tenant(terms=terms)
    own, own_iban = own_account(tenant)
    _f42, p1 = paid_file(tenant, 200_000)
    rv1 = request_run(tenant)
    approve(tenant, rv1)
    drain()
    book_payout(rv1)
    assert run_row(rv1)["status"] == "booked"
    assert book_sweep(tenant) == 36_000
    paid_file(tenant, 300_000)  # P6
    a1 = _advance_of_return(tenant, p1)
    top_up(tenant, own, own_iban, 200_000)
    tenant["own"] = own
    return tenant, a1


def _request(
    tenant: dict[str, Any], advances: list[str], total: str, key: str | None = None
) -> Any:
    return staff(
        tenant,
        "select public.request_advance_repayment(%s, %s, 'EUR', %s::uuid[], %s)",
        key or str(uuid.uuid4()),
        tenant["client"],
        advances,
        total,
    )


def _request_row(request: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute(
            "select * from public.advance_repayment_request where id = %s", (request,)
        )
        row = cur.fetchone()
        assert row is not None and cur.description is not None
        return {d.name: v for d, v in zip(cur.description, row, strict=True)}


def _book(tenant: dict[str, Any], book: str) -> int:
    return int(
        _value(
            """select coalesce(sum(p.amount_minor), 0) from public.ledger_posting p
               join public.ledger_account la on la.id = p.ledger_account_id
               where la.book = %s and la.client_organization_id = %s""",
            book,
            tenant["client"],
        )
    )


def _advance_open_alerts(tenant: dict[str, Any], advance: str, days: int) -> int:
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        run = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (tenant["servicer"],),
        )
        conn.execute(
            "select private.run_advance_checks(%s, %s, %s, true)",
            (run, tenant["servicer"], paris_today() + timedelta(days=days)),
        )
        return int(
            one(
                conn,
                """select count(*) from public.payment_check_result
                   where run_id = %s and code = 'advance_open' and subject_id = %s""",
                (run, advance),
            )
        )


def test_the_first_variant_of_7_3_a_request_its_letter_and_the_client_s_repayment(
    tmp_path: Path,
) -> None:
    """Design §7.3, no claw-back clause: RV-3 N 282 000, a request DRA for 200 000 whose PDF the job
    stores, then Martin's repayment to the own account: 4112[Martin] = 0, advance_open silent."""
    tenant, a1 = _worked_example(TERMS)
    rv3 = request_run(tenant)
    draft = run_row(rv3)
    assert (draft["net_minor"], draft["advance_recovered_minor"]) == (282_000, 0), draft[
        "last_failure"
    ]
    result = _request(tenant, [a1], "200000")
    assert result["number"].startswith("DRA-")
    request = str(result["request_id"])
    assert _value("select count(*) from public.ledger_entry where source_id = %s", request) == 0
    drain()  # the letter's job (remittances: repayment_request)
    row = _request_row(request)
    assert row["document_id"] is not None and row["renderer_version"]
    doc = dict(
        zip(
            ("storage_path", "sha256", "kind", "file_name"),
            _value(
                """select array[storage_path, sha256, kind, file_name] from public.document
                   where id = %s""",
                row["document_id"],
            ),
            strict=True,
        )
    )
    assert doc["storage_path"] == f"repayment-requests/{tenant['servicer']}/{request}.pdf"
    assert (doc["kind"], doc["file_name"]) == (
        "advance_repayment_request_pdf",
        f"{row['number']}.pdf",
    )
    stored = storage().download("documents", doc["storage_path"], tmp_path / "letter.pdf")
    data = stored.read_bytes()
    assert data.startswith(b"%PDF")
    assert hashlib.sha256(data).hexdigest() == doc["sha256"] == row["pdf_sha256"]
    # the client's requests as the pages read them (money staff here; its whole-client members too:
    # pgTAP 045b h, p)
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        conn.execute(
            "select set_config('request.jwt.claims', %s, true)",
            (json.dumps({"sub": tenant["staff"], "role": "authenticated", "aal": "aal2"}),),
        )
        conn.execute("set local role authenticated")
        space = one(conn, "select public.client_repayment_requests(%s)", (tenant["client"],))
    assert [(r["number"], r["document_id"], r["total_minor"]) for r in space["rows"]] == [
        (row["number"], str(row["document_id"]), "200000")
    ]
    # Martin repays the advance to the own account (« Règlement du client », its proof)
    paid = staff(
        tenant,
        """select public.record_client_payment(%s, %s, 'EUR', '2000,00', private.paris_today(), %s,
                                               array[%s]::uuid[], %s, null, '200000', %s)""",
        str(uuid.uuid4()),
        tenant["client"],
        _evidence(tenant, "client_payment_evidence"),
        a1,
        _evidence(tenant, "payment_designation_evidence"),
        REASON,
    )
    assert [(s["document_kind"], s["amount_minor"]) for s in paid["settled"]] == [
        ("advance", "200000")
    ]
    assert _book(tenant, "client_advance_receivable") == 0
    assert _advance_open_alerts(tenant, a1, 31) == 0


def _set_clawback(tenant: dict[str, Any], clause: str) -> None:
    """(test only) the claw-back clause in the mandate's terms in force (the version's guard set
    aside, as pgTAP 044's)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("alter table public.mandate_terms disable trigger mandate_terms_guard")
        conn.execute(
            """update public.mandate_terms
               set remittance_terms = jsonb_set(remittance_terms, '{clawback}', %s::jsonb)
               where mandate_id = %s""",
            (json.dumps({"clause_ref": clause}), tenant["mandate"]),
        )
        conn.execute("alter table public.mandate_terms enable always trigger mandate_terms_guard")


def test_a_requested_advance_is_never_also_taken_by_the_real_prepare() -> None:
    """[critic] M7-MONEY-3: A1 requested (no clause then); the terms gain the claw-back clause; the
    real prepare leaves A1 to its request (N 282 000, nothing taken); the request withdrawn,
    « Actualiser » takes A1 back (N 82 000, 200 000 taken) and the run is approved."""
    tenant, a1 = _worked_example(TERMS)
    request = str(_request(tenant, [a1], "200000")["request_id"])
    _set_clawback(tenant, "art. 7.4")
    rv3 = request_run(tenant)
    draft = run_row(rv3)
    assert (draft["net_minor"], draft["advance_recovered_minor"]) == (282_000, 0), draft[
        "last_failure"
    ]
    staff(
        tenant,
        "select public.withdraw_advance_repayment_request(%s, %s, %s)",
        str(uuid.uuid4()),
        request,
        "Le client conteste la somme (test)",
    )
    staff(
        tenant,
        "select public.refresh_remittance_run(%s, %s, %s)",
        str(uuid.uuid4()),
        rv3,
        draft["version"],
    )
    drain()
    again = run_row(rv3)
    assert (again["net_minor"], again["advance_recovered_minor"]) == (82_000, 200_000), again[
        "last_failure"
    ]
    approve(tenant, rv3)
    drain()
    assert run_row(rv3)["status"] == "approved"


class _FailingStorage:
    """The storage's upload fails once (its remove recorded): nothing is recorded, the upload is
    removed, the job raises (the queue retries it)."""

    def __init__(self) -> None:
        self.inner = storage()
        self.removed: list[str] = []
        self.failed = False

    def download(self, bucket: str, path: str, dest: Path) -> Path:
        return self.inner.download(bucket, path, dest)

    def upload(
        self, bucket: str, path: str, data: bytes, content_type: str = "application/octet-stream"
    ) -> None:
        if not self.failed:
            self.failed = True
            self.inner.upload(bucket, path, data, content_type)  # written, then the job fails
            raise RuntimeError("storage unavailable (test)")
        self.inner.upload(bucket, path, data, content_type)

    def remove(self, bucket: str, paths: list[str]) -> None:
        self.removed.extend(paths)
        self.inner.remove(bucket, paths)


def test_the_letter_s_job_draws_once_and_a_failed_upload_records_nothing() -> None:
    tenant, a1 = _worked_example(TERMS)
    request = str(_request(tenant, [a1], "200000")["request_id"])
    failing = _FailingStorage()
    handler = make_handler(failing)
    payload = {"type": "repayment_request", "request_id": request}
    with (
        psycopg.connect(DB) as conn,
        pytest.raises(RuntimeError, match="storage unavailable"),
        conn.transaction(),
    ):
        handler(payload, conn)
    assert _request_row(request)["document_id"] is None
    assert failing.removed == [f"repayment-requests/{tenant['servicer']}/{request}.pdf"]
    with psycopg.connect(DB) as conn, conn.transaction():
        handler(payload, conn)
    row = _request_row(request)
    assert row["document_id"] is not None
    with psycopg.connect(DB) as conn, conn.transaction():
        handler(payload, conn)  # a replay draws nothing again
    assert _request_row(request)["document_id"] == row["document_id"]
    drawn = _value(
        """select count(*) from public.document
           where kind = 'advance_repayment_request_pdf' and client_organization_id = %s""",
        tenant["client"],
    )
    assert drawn == 1


class _RecordingStorage:
    """The storage, its uploads recorded."""

    def __init__(self) -> None:
        self.inner = storage()
        self.uploaded: list[str] = []

    def download(self, bucket: str, path: str, dest: Path) -> Path:
        return self.inner.download(bucket, path, dest)

    def upload(
        self, bucket: str, path: str, data: bytes, content_type: str = "application/octet-stream"
    ) -> None:
        self.uploaded.append(path)
        self.inner.upload(bucket, path, data, content_type)

    def remove(self, bucket: str, paths: list[str]) -> None:
        self.inner.remove(bucket, paths)


def test_a_request_withdrawn_before_its_letter_is_drawn_gets_none() -> None:
    """(review round 1, NIGHT-1, CC-1) A request withdrawn while its letter's job waits: the job
    draws nothing (no file stored, no document), and the client space never offers a letter of a
    request withdrawn before it existed; the nightly raises nothing for it (045b c2)."""
    tenant, a1 = _worked_example(TERMS)
    request = str(_request(tenant, [a1], "200000")["request_id"])
    staff(
        tenant,
        "select public.withdraw_advance_repayment_request(%s, %s, %s)",
        str(uuid.uuid4()),
        request,
        "Demande adressée par erreur (test)",
    )
    recording = _RecordingStorage()
    with psycopg.connect(DB) as conn, conn.transaction():
        make_handler(recording)({"type": "repayment_request", "request_id": request}, conn)
    assert recording.uploaded == []
    assert _request_row(request)["document_id"] is None
    drawn = _value(
        """select count(*) from public.document
           where kind = 'advance_repayment_request_pdf' and client_organization_id = %s""",
        tenant["client"],
    )
    assert drawn == 0
