# ruff: noqa: E501 - SQL fixtures read better unwrapped
"""M2c-7f-1 (needs `make up`; plan docs/design/m2c-7f-plan.md §2.3, §2.8; ADR-0014 « M2c-7f-1 »): the close-out's
behaviour fixes through real sessions and the real jobs.
- H9 (MONEY-BANK-3), two sessions: while the hourly job holds the servicer's remit lock (its read of what is owed,
  then its order), ops' « Approvisionner le compte dédié » is refused 55P03 (allocation_busy); retried after the job's
  commit, it is recorded beside the job's top-up, which top_up_needed then counts. The reverse: while ops' order is
  open, the job's order waits and is refused; after ops' commit the job orders only what is still needed.
- H11 (MONEY-2), two sessions recording one proof: the second waits for the first's locks, then is refused
  evidence_already_used — one payment, one entry.
- H14: a mandate's end committed by another session between the allocation job's read and its post: the post's
  backstop refuses it (LG006), nothing allocated.
- H17: a repayment-request letter whose job died (its message archived after its retries) is re-queued by
  private.requeue_repayment_letters and drawn once; a drawn or withdrawn request is never re-queued.
- H18: a CSV credit whose label carries two /REF markers (a payer's « /REF RMT… » of ours before the bank's) gives
  no end-to-end id: held label_reference by the real import and the debit job, never booked payout_returned."""

from __future__ import annotations

import threading
import time
import uuid
from datetime import timedelta
from typing import Any

import psycopg
import pytest
from allocation_helpers import File, Item, create_file, credit
from explain_helpers import ADMIN
from integration_helpers import DB, as_user, one, storage
from reconciliation_helpers import pay
from remittance_helpers import (
    TERMS,
    drain,
    own_account,
    paris_today,
    recent_business_day,
    remittance_tenant,
)
from statement_helpers import bank_tenant, upload
from statement_helpers import drain as drain_payments
from test_client_payments_integration import NO_NETTING
from test_label_references_integration import DEBTOR, _fr, _transfers
from test_repayment_requests_integration import _request, _request_row, _worked_example
from test_top_ups_integration import _fee, _owed, _tops

pytestmark = pytest.mark.integration


def _need(tenant: dict[str, Any]) -> int:
    with psycopg.connect(DB) as conn:
        return int(one(conn, "select private.top_up_needed(%s, 'EUR')", (tenant["servicer"],)))


def _request_top_up(
    conn: psycopg.Connection[Any], tenant: dict[str, Any], own: str, amount: int
) -> Any:
    """« Approvisionner le compte dédié » as the ops manager (aal2), in `conn`'s open transaction."""
    as_user(conn, tenant["staff"], "aal2")
    conn.execute("set local role authenticated")
    value = one(
        conn,
        "select public.request_top_up(%s, %s, %s, %s, 'Approvisionnement demandé à la banque (test)', null)",
        (str(uuid.uuid4()), own, tenant["bank"], str(amount)),
    )
    conn.execute("reset role")
    return value


def test_ops_top_up_and_the_hourly_order_are_serialised() -> None:
    tenant = remittance_tenant()
    own, _own_iban = own_account(tenant)
    _fee(tenant, 1_234)
    assert _owed(tenant) == 1_234
    # the job first: its order holds the locks until its commit; ops' order is refused meanwhile
    job = psycopg.connect(DB)
    try:
        job.execute("begin")
        assert one(job, "select private.order_due_top_up(%s)", (tenant["servicer"],)) == 1
        with psycopg.connect(DB) as ops:
            with (
                pytest.raises(psycopg.errors.LockNotAvailable, match="allocation_busy"),
                ops.transaction(),
            ):
                _request_top_up(ops, tenant, own, 500)
            job.execute("commit")
            with ops.transaction():
                done = _request_top_up(ops, tenant, own, 500)
        assert done["amount_minor"] == "500", done
    finally:
        job.close()
    assert sorted(t[2] for t in _tops(tenant)) == [500, 1_234]
    assert _need(tenant) == 0  # the job's top-up and ops' both counted
    # the reverse: ops' order open, the job waits for it and is refused (its 2 s); after ops' commit, the job orders
    # only what is still needed
    _fee(tenant, 2_000)
    assert _need(tenant) == 1_500
    ops = psycopg.connect(DB)
    try:
        ops.execute("begin")
        _request_top_up(ops, tenant, own, 600)
        with psycopg.connect(DB) as job2:
            with pytest.raises(psycopg.errors.LockNotAvailable), job2.transaction():
                job2.execute("select private.order_due_top_up(%s)", (tenant["servicer"],))
            ops.execute("commit")
            with job2.transaction():
                assert one(job2, "select private.order_due_top_up(%s)", (tenant["servicer"],)) == 1
    finally:
        ops.close()
    assert sorted(t[2] for t in _tops(tenant)) == [500, 600, 900, 1_234]
    assert _need(tenant) == 0


def _evidence_of(tenant: dict[str, Any], sha: str) -> str:
    """A payment proof of the client whose file has the SHA-256 `sha` (as « Joindre un document » registers it)."""
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        return str(
            one(
                conn,
                """insert into public.document (organization_id, client_organization_id, kind, storage_path, sha256,
                     mime_type)
                   values (%s, %s, 'client_payment_evidence', %s, %s, 'application/pdf') returning id""",
                (tenant["servicer"], tenant["client"], f"client/test/{uuid.uuid4()}.pdf", sha),
            )
        )


def _record(conn: psycopg.Connection[Any], tenant: dict[str, Any], evidence: str) -> Any:
    as_user(conn, tenant["staff"], "aal2")
    conn.execute("set local role authenticated")
    value = one(
        conn,
        """select public.record_client_payment(%s, %s, 'EUR', '25,00', private.paris_today(), %s, null, null, null,
                                               '0', 'Virement reçu sur le compte du cabinet (test)')""",
        (str(uuid.uuid4()), tenant["client"], evidence),
    )
    conn.execute("reset role")
    return value


def test_one_proof_recorded_by_two_sessions_is_recorded_once() -> None:
    tenant = remittance_tenant(terms=NO_NETTING)
    own_account(tenant)
    sha = uuid.uuid4().hex + uuid.uuid4().hex
    first, again = _evidence_of(tenant, sha), _evidence_of(tenant, sha)  # one file uploaded twice
    errors: list[str] = []
    s1 = psycopg.connect(DB)
    try:
        s1.execute("begin")
        _record(s1, tenant, first)  # its locks held until its commit

        def second() -> None:
            try:
                with psycopg.connect(DB) as s2, s2.transaction():
                    _record(s2, tenant, again)
            except psycopg.Error as exc:
                errors.append(str(exc.diag.message_primary))

        t = threading.Thread(target=second)
        t.start()
        time.sleep(0.5)  # the second session waits for the first's locks (lock_timeout 2 s)
        s1.execute("commit")
        t.join(10)
    finally:
        s1.close()
    assert errors == ["client payment refused: evidence_already_used"], errors
    with psycopg.connect(DB) as conn:
        entries = one(
            conn,
            """select count(*) from public.ledger_entry where entry_type = 'client_payment_own'
                 and source_id = any(%s::text[])""",
            ([first, again],),
        )
    assert entries == 1, entries


def test_a_mandate_end_committed_before_the_post_holds_the_allocation() -> None:
    tenant = remittance_tenant()
    f = create_file(tenant, File(f"F-{uuid.uuid4().hex[:8]}", "b2b", "Débiteur SARL",
                                 [Item("INV-1", {"principal": 40_000}, None)]))  # fmt: skip
    day = recent_business_day()
    pay(tenant, storage(), [credit(40_000, rf=f.rf)], prefix=f"H{uuid.uuid4().hex[:5].upper()}", start=day,
        days=1, allocate=False)  # fmt: skip
    with psycopg.connect(DB) as conn:
        payment, account, item, booked_on, client = conn.execute(
            """select p.id, a.id, i.id, p.booking_date, a.client_organization_id from public.payment p
               join public.account a on a.id = p.account_id
               join public.claim_item i on i.account_id = a.id
               where a.external_ref = %s and p.status = 'matched'""",
            (f.ref,),
        ).fetchone() or (None, None, None, None, None)
    assert payment is not None
    job = psycopg.connect(DB)
    try:
        job.execute("begin")
        job.execute("select private.allocation_begin()")
        job.execute(
            """insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy,
                 inputs_hash)
               select %s, 1, %s, 'allocate', greatest(%s::date, min(o.valid_from)),
                      '{"accessory_rank": "before_principal", "unclassified": "last"}', repeat('0', 64)
               from public.claim_ownership_period o where o.account_id = %s""",
            (payment, account, booked_on, account),
        )
        job.execute(
            """insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
               values (%s, 1, %s, 'principal', 40000)""",
            (payment, item),
        )
        # another session records the client's death, effective before the payment, and commits
        with psycopg.connect(ADMIN) as other, other.transaction():
            evidence = one(
                other,
                """insert into public.document (organization_id, client_organization_id, kind, storage_path, sha256,
                     mime_type)
                   values (%s, %s, 'client_status_evidence', %s, repeat('e', 64), 'application/pdf') returning id""",
                (tenant["servicer"], client, f"client/test/{uuid.uuid4()}.pdf"),
            )
            other.execute(
                """insert into public.client_status_event (organization_id, client_organization_id, kind,
                     effective_date, evidence_document_id, note, recorded_by)
                   values (%s, %s, 'death', %s, %s, 'Décès (test)', %s)""",
                (
                    tenant["servicer"],
                    client,
                    booked_on - timedelta(days=1),
                    evidence,
                    tenant["staff"],
                ),
            )
        # (LG006: the ledger's own SQLSTATE, a DatabaseError to psycopg)
        with pytest.raises(psycopg.DatabaseError, match="may not be allocated on this file now"):
            job.execute(
                "select private.post_allocations(%s, 'ready', 'alloc-1')", (tenant["servicer"],)
            )
        job.execute("rollback")
    finally:
        job.close()
    with psycopg.connect(DB) as conn:
        assert one(conn, "select count(*) from public.ledger_entry where payment_id = %s and entry_type = 'allocation'",
                   (payment,)) == 0  # fmt: skip


def test_a_repayment_letter_whose_job_died_is_requeued_and_drawn_once() -> None:
    tenant, a1 = _worked_example(TERMS)
    request = str(_request(tenant, [a1], "200000")["request_id"])
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        # the letter's job dead: its message archived after its retries, never run
        archived = one(
            conn,
            """select count(pgmq.archive('remittances', m.msg_id)) from pgmq.q_remittances m
               where m.message ->> 'type' = 'repayment_request' and m.message ->> 'request_id' = %s""",
            (request,),
        )
        assert archived == 1
        # recorded two hours ago (its guard set aside for the test)
        conn.execute(
            "alter table public.advance_repayment_request disable trigger advance_repayment_request_guard"
        )
        conn.execute(
            "update public.advance_repayment_request set created_at = now() - interval '2 hours' where id = %s",
            (request,),
        )
        conn.execute(
            "alter table public.advance_repayment_request enable always trigger advance_repayment_request_guard"
        )
    with psycopg.connect(DB) as conn, conn.transaction():
        assert one(conn, "select private.requeue_repayment_letters()") == 1
        assert (
            one(conn, "select private.requeue_repayment_letters()") == 0
        )  # its message waits: never sent twice
    drain()
    row = _request_row(request)
    assert row["document_id"] is not None
    with psycopg.connect(DB) as conn:
        drawn = one(
            conn,
            "select count(*) from public.document where kind = 'advance_repayment_request_pdf' and client_organization_id = %s",
            (tenant["client"],),
        )
        assert drawn == 1  # drawn once, whatever the messages
        with conn.transaction():
            assert (
                one(conn, "select private.requeue_repayment_letters()") == 0
            )  # drawn: nothing to re-queue


def test_two_ref_markers_give_no_end_to_end_id() -> None:
    tenant = bank_tenant(feed="csv")
    ids = _transfers(tenant)
    tag = uuid.uuid4().hex[:6].upper()
    day = _fr(paris_today())
    csv = (
        "Date;Libellé;Débit;Crédit;IBAN contrepartie\n"
        f"{day};VIR SEPA RECU /DE DUPONT JEAN /MOTIF REMB /REF {ids['rmt']} /REF BQ{tag};;1000,00;{DEBTOR}\n"
        f"{day};VIR SEPA RECU /DE DURAND /MOTIF REMB /REF BQ{tag}X;;20,00;{DEBTOR}\n"
    ).encode()
    target = upload(tenant, storage(), csv, name=f"releve-{tag}.csv")
    drain_payments(storage())
    with psycopg.connect(DB) as conn:
        lines = conn.execute(
            """select t.kind, t.end_to_end_id, t.reference_from_label, r.reason,
                      (select count(*) from public.bank_line_booking b where b.bank_transaction_id = t.id)
               from public.bank_transaction t
               left join public.bank_debit_review r on r.bank_transaction_id = t.id
               where t.statement_id = %s order by t.line_no""",
            (str(target["statement_id"]),),
        ).fetchall()
    # the payer's « /REF RMT… » then the bank's: no end-to-end id, our payout a candidate of the label — held for
    # review, never our payout coming back; one /REF keeps M2b's reading (the line's end-to-end id)
    assert [tuple(r) for r in lines] == [
        ("label_reference", None, ids["rmt"], "label_reference", 0),
        ("debtor_credit", f"BQ{tag}X", None, None, 0),
    ], lines
