"""M2c-4 runs and invoices through the database (needs `make up`; design §9, §14, §15, §18 M2-14 and
M2-15; ADR-0014 M2c-4 addendum).

* the worked example's first run (§7.2 RV-1): « Préparer maintenant », the prepare job, approval —
  FC-…-000001 36 000 TTC netted, the payout RMT 164 000 ordered (nothing leaves 5120 before the
  bank's debit, M2c-6), the lines frozen, the queue empty, the tier history written, the checks
  clean;
* gapless numbering: two runs of two clients approved at once by two connections take consecutive
  numbers; an approval rolled back after numbering leaves no gap;
* one stale run never blocks the others: two runs approved together, one whose payout IBAN was
  retired meanwhile goes back to draft with its reason, the other is approved;
* N = 0: a run whose collection was undone in it is booked at approval with nothing posted;
* cancellation before the transfer is in a file: one full credit note per invoice, the lines
  released, the items back in the queue, the tier history restored, and the next run prices them
  again;
* the schedule (a frozen Paris time): a draft on a scheduled day, the deadline guard on another day;
* R124-6: an item past its latest execution date writes a breach row and a violation; a stale page
  (its inputs hash) is refused without queuing.
"""

from __future__ import annotations

import threading
import uuid
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

import psycopg
import pytest
from debit_helpers import checks
from integration_helpers import DB, one
from psycopg.types.json import Jsonb
from remittance_helpers import (
    add_client,
    approve,
    documents,
    drain,
    entry_books,
    next_business_day,
    paid_file,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)

from collectoo_worker.jobs.remittances import run_schedule

pytestmark = pytest.mark.integration
PARIS = ZoneInfo("Europe/Paris")


def _lines(run: str) -> list[tuple[str, int, int, str]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select kind, amount_minor, commission_minor, commission_state
               from public.remittance_line where run_id = %s order by line_no""",
            (run,),
        ).fetchall()
    return [(r[0], int(r[1]), int(r[2]), r[3]) for r in rows]


def _pending(tenant: dict[str, Any]) -> int:
    with psycopg.connect(DB) as conn:
        return int(
            one(
                conn,
                "select count(*) from private.remittance_pending where client_organization_id = %s",
                (tenant["client"],),
            )
        )


def one_value(sql: str, *params: Any) -> Any:
    with psycopg.connect(DB) as conn:
        return one(conn, sql, params)


def _remittance_violations(run_id: str) -> list[tuple[str, str | None]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select code, subject_id::text from public.payment_check_result
               where run_id = %s and severity = 'violation' order by code""",
            (run_id,),
        ).fetchall()
    return [(r[0], r[1]) for r in rows]


def test_the_first_run_of_the_worked_example() -> None:
    """§7.2 RV-1: 200 000 collected on Martin's file at 15 % with a netting clause."""
    tenant = remittance_tenant()
    f, payment = paid_file(tenant, 200_000)
    run = request_run(tenant)
    draft = run_row(run)
    assert draft["status"] == "draft" and draft["job"] is None and draft["prepared_at"] is not None
    assert (draft["gross_minor"], draft["invoice_ttc_minor"], draft["net_minor"]) == (
        200_000,
        36_000,
        164_000,
    )
    assert (draft["settlement_minor"], draft["blockers"]) == (36_000, [])
    assert draft["earliest_latest_execution_date"] is not None
    result = approve(tenant, run)
    assert [r["status"] for r in result["results"]] == ["queued"]
    drain()
    done = run_row(run)
    assert done["status"] == "approved", done["last_failure"]
    (inv,) = documents(run)
    assert (inv["kind"], inv["ht_minor"], inv["vat_minor"], inv["ttc_minor"]) == (
        "invoice",
        30_000,
        6_000,
        36_000,
    )
    assert inv["number"] == f"FC-{inv['issue_date'].year}-{inv['seq']:06d}" and inv["seq"] == 1
    assert inv["settlement"] == "netted"
    with psycopg.connect(DB) as conn:
        entry = one(
            conn,
            "select ledger_entry_id from public.commission_invoice where run_id = %s",
            (run,),
        )
        transfer = conn.execute(
            "select kind, status, amount_minor, end_to_end_id, remittance_info"
            " from public.bank_transfer where run_id = %s",
            (run,),
        ).fetchone()
        states = conn.execute(
            "select tier_key, commission_minor from public.remittance_key_state where run_id = %s",
            (run,),
        ).fetchall()
    assert entry_books(str(entry)) == {
        "commission_receivable": 36_000,
        "servicer_revenue": -30_000,
        "vat_pending": -6_000,
    }
    assert transfer is not None
    assert transfer[:3] == ("payout", "ordered", 164_000) and transfer[3].startswith("RMT")
    assert inv["number"] in transfer[4]
    assert _lines(run) == [("allocation", 200_000, 30_000, "charged")]
    assert _pending(tenant) == 0
    assert states == [("tout", 30_000)]
    run_checks = checks(tenant)
    assert _remittance_violations(str(run_checks["run_id"])) == []
    del f, payment


def test_numbers_are_gapless_under_concurrency_and_rollback() -> None:
    """Two clients' runs approved at the same time by two connections: consecutive numbers of one
    series. An approval rolled back after it numbered leaves no gap: the next takes that number."""
    a = remittance_tenant()
    b = add_client(a, "Lilas")
    paid_file(a, 200_000)
    paid_file(b, 512_000)
    ra, rb = request_run(a), request_run(b)
    approve(a, ra, rb)
    tokens = {r: str(run_row(r)["job_token"]) for r in (ra, rb)}
    barrier = threading.Barrier(2)
    errors: list[BaseException] = []

    def approve_one(run: str) -> None:
        try:
            with psycopg.connect(DB) as conn, conn.transaction():
                barrier.wait()
                conn.execute("select private.approve_remittance_run(%s, %s)", (run, tokens[run]))
        except BaseException as exc:  # pragma: no cover - reported below
            errors.append(exc)

    threads = [threading.Thread(target=approve_one, args=(r,)) for r in (ra, rb)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
    assert sorted([documents(ra)[0]["seq"], documents(rb)[0]["seq"]]) == [1, 2]
    # a third client's approval rolled back after numbering: the counter is back, no gap
    c = add_client(a, "Rollback")
    paid_file(c, 10_000)
    rc = request_run(c)
    approve(c, rc)
    token = str(run_row(rc)["job_token"])
    with psycopg.connect(DB) as conn:
        conn.execute("select private.approve_remittance_run(%s, %s)", (rc, token))
        assert one(conn, "select max(seq) from public.commission_invoice"
                   " where organization_id = %s", (a["servicer"],)) == 3  # fmt: skip
        conn.rollback()
    with psycopg.connect(DB) as conn:
        assert one(conn, "select last_seq from private.invoice_counter where organization_id = %s",
                   (a["servicer"],)) == 2  # fmt: skip
    drain()  # the queued job: numbered 3 now
    assert run_row(rc)["status"] == "approved"
    assert documents(rc)[0]["seq"] == 3


def test_one_stale_run_never_blocks_the_others() -> None:
    a = remittance_tenant()
    b = add_client(a, "Autre")
    paid_file(a, 50_000)
    paid_file(b, 80_000)
    ra, rb = request_run(a), request_run(b)
    approve(a, ra, rb)
    with psycopg.connect(DB) as conn, conn.transaction():  # a's IBAN retired meanwhile
        conn.execute(
            """update public.client_payout_account set status = 'retired', closed_by = %s,
                 closed_at = now(), closed_reason = 'test' where id = %s""",
            (a["staff"], a["payout"]),
        )
    drain()
    stale, fine = run_row(ra), run_row(rb)
    assert stale["status"] == "draft" and stale["job"] is None
    assert stale["last_failure"]["code"] == "payout_blocked:payout_account_missing"
    assert fine["status"] == "approved"
    assert documents(ra) == [] and len(documents(rb)) == 1
    # a page that showed an older version is refused, nothing queued
    refused = staff(
        a,
        "select public.approve_remittance_runs(%s, %s::jsonb)",
        str(uuid.uuid4()),
        f'[{{"run_id": "{rb}", "inputs_hash": "{"0" * 64}", "net_text": "1"}}]',
    )
    assert refused["results"][0]["status"] == "refused"


def test_a_run_whose_collection_was_undone_in_it_is_booked_at_once() -> None:
    """N = 0 (§9.5 step 5): the allocation and its reversal in one run: gross 0, no commission
    (a same-run pair is never priced), booked at approval with nothing posted."""
    tenant = remittance_tenant()
    _, payment = paid_file(tenant, 40_000)
    with psycopg.connect(DB) as conn:
        entry = one(
            conn,
            "select id from public.ledger_entry"
            " where payment_id = %s and entry_type = 'allocation'",
            (payment,),
        )
    f_id = one_value("select account_id from public.ledger_entry where id = %s", str(entry))
    staff(
        tenant,
        "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        str(uuid.uuid4()),
        payment,
        f_id,
        [str(entry)],
        "erreur d'imputation",
    )
    run = request_run(tenant)
    draft = run_row(run)
    assert (draft["gross_minor"], draft["net_minor"], draft["settlement_minor"]) == (0, 0, 0)
    approve(tenant, run)
    drain()
    done = run_row(run)
    assert done["status"] == "booked", done["last_failure"]
    assert done["booked_on"] is not None and done["transfer_id"] is None
    assert documents(run) == []
    assert sorted(k for k, *_ in _lines(run)) == ["allocation", "allocation_reversal"]
    assert all(c == 0 for _, _, c, _ in _lines(run))


def test_cancellation_before_the_file_credits_the_invoices_and_frees_the_items() -> None:
    tenant = remittance_tenant()
    paid_file(tenant, 100_000)
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    approved = run_row(run)
    assert approved["status"] == "approved"
    result = staff(
        tenant,
        "select public.cancel_remittance_run(%s, %s, %s, %s)",
        str(uuid.uuid4()),
        run,
        approved["version"],
        "IBAN à vérifier",
        user=tenant["admin"],
    )
    assert result["status"] == "cancelled" and result["lines_released"] == 1
    docs = documents(run)
    assert [(d["kind"], d["ttc_minor"], d["reason"]) for d in docs] == [
        ("invoice", 18_000, "commission"),
        ("credit_note", -18_000, "run_cancelled"),
    ]
    assert docs[1]["seq"] == docs[0]["seq"] + 1
    assert _pending(tenant) == 1
    with psycopg.connect(DB) as conn:
        transfer = one(conn, "select status from public.bank_transfer where run_id = %s", (run,))
        state = conn.execute(
            """select cause, commission_minor from public.remittance_key_state
               where client_organization_id = %s order by seq desc limit 1""",
            (tenant["client"],),
        ).fetchone()
    assert transfer == "cancelled" and state == ("cancelled", 0)
    # the next run prices the item again: a new invoice
    again = request_run(tenant)
    assert run_row(again)["invoice_ttc_minor"] == 18_000
    approve(tenant, again)
    drain()
    assert run_row(again)["status"] == "approved"
    assert documents(again)[0]["seq"] == docs[1]["seq"] + 1


def test_the_schedule_and_the_deadline_guard() -> None:
    tenant = remittance_tenant()
    paid_file(tenant, 30_000)
    payload = {"organization_id": tenant["servicer"]}
    # before 05:00 Paris nothing is decided
    with psycopg.connect(DB) as conn, conn.transaction():
        assert run_schedule(conn, payload, now=datetime(2026, 11, 16, 4, 30, tzinfo=PARIS)) == []
    # Mon 16/11/2026: the 16th, a scheduled day of twice-monthly terms
    with psycopg.connect(DB) as conn, conn.transaction():
        created = run_schedule(conn, payload, now=datetime(2026, 11, 16, 6, 0, tzinfo=PARIS))
    assert len(created) == 1
    assert run_row(created[0])["trigger"] == "schedule"
    drain()
    staff(tenant, "select public.discard_remittance_run(%s, %s, %s, %s)", str(uuid.uuid4()),
          created[0], run_row(created[0])["version"], "test")  # fmt: skip
    # the same day again: its key was used, nothing new
    with psycopg.connect(DB) as conn, conn.transaction():
        assert run_schedule(conn, payload, now=datetime(2026, 11, 16, 9, 0, tzinfo=PARIS)) == []
    # a day that is not scheduled, 3 business days before the latest execution date: the guard
    with psycopg.connect(DB) as conn:
        latest = one(
            conn,
            """select min(d.latest_execution_date) from private.pending_item_deadlines(%s) d
               where d.client_organization_id = %s""",
            (tenant["servicer"], tenant["client"]),
        )
        day = one(
            conn,
            """select c.day from public.business_calendar c where c.day < %s and not c.closed
               order by c.day desc offset 2 limit 1""",
            (latest,),
        )
    assert day.day not in (1, 16, 17, 2)
    with psycopg.connect(DB) as conn, conn.transaction():
        guard = run_schedule(conn, payload, now=datetime.combine(day, datetime.min.time(), PARIS)
                             + timedelta(hours=7))  # fmt: skip
    assert len(guard) == 1 and run_row(guard[0])["trigger"] == "deadline"
    drain()


def test_a_collection_past_its_latest_execution_date_is_a_breach() -> None:
    """R124-6 (I21): E Mon 05/10/2026 under 30 days → deadline Wed 04/11, latest execution Tue
    03/11; not paid: a breach
    row and the violation; then « Préparer » and approve with a reason (paying late beats not
    paying): the payout ordered, the breach recorded with the reason."""
    tenant = remittance_tenant()
    paid_file(tenant, 25_000, day=date(2026, 10, 5))
    run_checks = checks(tenant)
    assert ("remittance_deadline_breached", str(tenant["client"])) in _remittance_violations(
        str(run_checks["run_id"])
    )
    with psycopg.connect(DB) as conn:
        breach = conn.execute(
            """select latest_execution_date, blocked_reason from public.remittance_deadline_breach
               where client_organization_id = %s""",
            (tenant["client"],),
        ).fetchone()
    assert breach == (date(2026, 11, 3), None)
    run = request_run(tenant)
    refused = approve(tenant, run)
    assert refused["results"][0]["reason"] == "late_reason_required"
    approve(tenant, run, day=next_business_day(), late_reason="Encaissement identifié tardivement")
    drain()
    assert run_row(run)["status"] == "approved"


def _book_payout(run: str) -> None:
    """What M2c-6 does at the payout's debit, emulated: the remittance (+4670 N / -5120 N) and the
    settlement of the run's plan, the transfer and the run booked."""
    r = run_row(run)
    with psycopg.connect(DB) as conn, conn.transaction():
        transfer = conn.execute(
            "select id, debtor_bank_account_id, amount_minor from public.bank_transfer"
            " where run_id = %s",
            (run,),
        ).fetchone()
        assert transfer is not None
        conn.execute("select private.ledger_post_set_begin()")
        conn.execute(
            """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type,
                 effective_date,
                 idempotency_key, client_organization_id, source_type, source_id)
               values (1, %s, 'remittance', private.paris_today(), %s, %s, 'bank_transfer', %s)""",
            (
                r["organization_id"],
                f"remit:{transfer[0]}",
                r["client_organization_id"],
                transfer[0],
            ),
        )
        conn.execute(
            """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency,
                 bank_account_id) values (1, 1, 'client_payable', %s, 'EUR', null),
                 (1, 2, 'client_money_cash', %s, 'EUR', %s)""",
            (transfer[2], -transfer[2], transfer[1]),
        )
        entry = one(conn, "select entry_id from private.ledger_post_set()")
        conn.execute(
            "select private.post_run_settlement(%s, %s, private.paris_today())",
            (run, Jsonb(r["settlement_plan"])),
        )
        conn.execute(
            "update public.bank_transfer set status = 'booked', entry_id = %s where id = %s",
            (entry, transfer[0]),
        )
        conn.execute(
            "update public.remittance_run set status = 'booked', booked_on = private.paris_today()"
            " where id = %s",
            (run,),
        )


def test_the_worked_example_continues_a_credit_note_on_a_settled_invoice() -> None:
    """§7.2 RV-3 (without the advance, M2c-7): RV-1 debited (emulated M2c-6: FC-1 settled, its VAT
    due); then E10 +300 000 on another file and P1's allocation undone: FC-3 54 000 TTC and a credit
    note on FC-1 of 36 000 TTC, its VAT off the VAT already due (44571); FC-1 settled, the 36 000 is
    a refund owed paid with the payout: N 82 000, D 18 000; 4111 = the open documents."""
    tenant = remittance_tenant()
    f42, p1 = paid_file(tenant, 200_000)
    rv1 = request_run(tenant)
    approve(tenant, rv1)
    drain()
    _book_payout(rv1)
    (fc1,) = documents(rv1)
    paid_file(tenant, 300_000)
    e2 = one_value(
        "select id from public.ledger_entry where payment_id = %s and entry_type = 'allocation'", p1
    )
    staff(
        tenant,
        "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        str(uuid.uuid4()),
        p1,
        f42.id,
        [str(e2)],
        "paiement repris par la banque",
    )
    rv3 = request_run(tenant)
    draft = run_row(rv3)
    assert (draft["gross_minor"], draft["refund_minor"], draft["net_minor"]) == (
        100_000,
        36_000,
        82_000,
    ), draft["last_failure"]
    approve(tenant, rv3)
    drain()
    done = run_row(rv3)
    assert done["status"] == "approved", done["last_failure"]
    fc3, fc4 = documents(rv3)
    assert (fc3["kind"], fc3["ttc_minor"], fc3["seq"]) == ("invoice", 54_000, fc1["seq"] + 1)
    assert (fc4["kind"], fc4["ht_minor"], fc4["vat_minor"], fc4["seq"]) == (
        "credit_note",
        -30_000,
        -6_000,
        fc1["seq"] + 2,
    )
    with psycopg.connect(DB) as conn:
        corr = conn.execute(
            """select c.vat_pending_minor, c.vat_collected_minor, c.applied_minor, c.excess_minor,
                      o.number
               from public.commission_credit_correction c
               join public.commission_invoice o on o.id = c.original_invoice_id
               join public.commission_invoice n on n.id = c.credit_note_id
               where n.run_id = %s""",
            (rv3,),
        ).fetchone()
    entry = one_value(
        "select ledger_entry_id from public.commission_invoice where run_id = %s"
        " and kind = 'credit_note'",
        rv3,
    )
    receivable = one_value(
        """select sum(p.amount_minor) from public.ledger_account la
           join public.ledger_posting p on p.ledger_account_id = la.id
           where la.book = 'commission_receivable' and la.client_organization_id = %s""",
        tenant["client"],
    )
    assert corr == (0, 6_000, 0, 36_000, fc1["number"])
    assert entry_books(str(entry)) == {
        "commission_receivable": -36_000,
        "servicer_revenue": 30_000,
        "vat_collected": 6_000,
    }
    assert receivable == 54_000 - 36_000
    run_checks = checks(tenant)
    # (the emulated debit has no bank line: I19 flags it; M2c-6 books from the statement)
    found = _remittance_violations(str(run_checks["run_id"]))
    assert [code for code, _ in found if code != "bank_cash_identity"] == []
