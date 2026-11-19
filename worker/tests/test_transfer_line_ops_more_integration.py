"""M2c-6b-2b, the integration scenarios 6b-2b deferred (needs `make up`; plan
docs/design/m2c-6b-2-plan.md §8.2 « Integration (6b-2b) »; ADR-0014 « M2c-6b-2b deferred
tests »), through the real camt.053 / CSV import, the debit job, the command and its options as an
aal2 API session, and the remittance jobs:

* E1-E9 (the design's worked example: collections, runs approved, the file downloaded, each payout
  debited and settled, the sweep), then every payout debited a second time (`--mode twice`): the
  job reviews each second debit `transfer_debited_twice`, ops book the options' proposal (P = 0, the
  advance A); Martin's next run (RV-3) is what it would have been — its gross the new collection,
  the double payout's -A and +A netting 0 — and is approved; then one copy comes back (`--return`):
  the job reviews it `unplanned_payout_return`, ops book the proposal, nothing re-owed, the advance
  closed (critic F1);
* both copies of one payout back on one statement (critic2 CSO2-7): both reviewed, ops book one as
  the unplanned booking's return, the funds pass it queues books the other as payout_returned(x),
  and the schedule drafts the client's run (trigger payout_returned);
* a second debit left unbooked, then a return of one copy (critic2 ML-3): reviewed
  `return_debit_pending`, nothing booked, the options point at the pending debit; ops book that
  debit, the funds pass reviews the return `unplanned_payout_return`, ops book its proposal —
  nothing re-owed;
* a run cancelled after its file was handed out (the switch on for that one transaction only, as
  6b-3 will do it), its file's late debit: P = A, the client's draft re-prepared by the job and
  approved by the approval job; Martin's check — what he received is his collections less the
  commission invoiced net of its credit note;
* `--mode partial`: ops book the lot's only subset; the left-out member's own debit the next day is
  booked by the job;
* a CSV export without the end-to-end column: rule 3b's one candidate (the payout in flight of that
  amount), and the late execution of a payout cancelled after download (critic F12): its unplanned
  payout with P;
* `--debit-charge 120`: the ISO shape (class U, the S08-on-U proposal: payout + fee) and the detail
  without an amount (class E: payout + fee) are booked; the ISO shape without `Chrgs` is refused
  `unsplit_detail_missing` and stays unbooked;
* `--unflagged-returns`: our payout back unflagged from the payee's IBAN is « Virement revenu » at
  the exact amount, and the schedule drafts the payout_returned run, its line held to the original
  run line's date (K2);
* an entry kept unsplit netting our booked payout's return into our next payout's debit: the U
  proposal (payout + payout_returned) booked; `--unsplit-details no-amounts` refused;
* P parity (critic F2-F5, critic2 ML-1): the command's P, advance and bound (its preview) equal the
  Python twin's `unplanned_p` on the same SQL facts, on 200 generated pools of a cancelled run's
  released items (signed amounts, reversals, attributions of earlier bookings, the client's queue),
  each in its own rolled-back transaction.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import replace
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from allocation_helpers import credit as bank_credit
from allocation_helpers import statement
from debit_helpers import api
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st
from integration_helpers import DB, as_user, storage
from psycopg.types.json import Jsonb
from remittance_helpers import (
    approve,
    paris_today,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)
from remittance_helpers import drain as drain_remittances
from statement_helpers import drain as drain_payments
from statement_helpers import upload
from test_debit_bookings_integration import (
    _bank,
    _bookings,
    _downloaded,
    _last_closing,
    _no_violation,
    _payouts,
    _replace_payout_account,
    _reviews,
    _run_transfer,
    _transfer,
)
from test_transfer_files_integration import _file, _own_account, _two_runs
from test_transfer_line_foundations_integration import (
    _booked,
    _day,
    _return_entries,
    _statement,
)
from test_transfer_line_ops_integration import (
    REASON,
    _book,
    _debit_again,
    _options,
    _pool_item,
    _queue,
)

from collectoo_worker.jobs.remittances import PARIS, run_schedule
from collectoo_worker.payments.transfer_lines import UnplannedAsk, unplanned_p
from collectoo_worker.remittance import pain001
from collectoo_worker.synth.camt053 import (
    TRANSFER_DEBIT_CODE,
    Entry,
    Tx,
    debits_of,
    expected_lines,
    make_doc,
    render_bank_csv,
)

pytestmark = pytest.mark.integration


def _lines(statement_id: str) -> list[str]:
    with psycopg.connect(DB) as conn:
        return [
            str(r[0])
            for r in conn.execute(
                "select id::text from public.bank_transaction where statement_id = %s"
                " order by line_no",
                (statement_id,),
            ).fetchall()
        ]


def _review(line: str) -> str | None:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select reason from public.bank_debit_review where bank_transaction_id = %s", (line,)
        ).fetchone()
    return None if row is None else str(row[0])


def _line_bookings(line: str) -> list[tuple[str, int]]:
    with psycopg.connect(DB) as conn:
        return [
            (str(r[0]), int(r[1]))
            for r in conn.execute(
                """select kind, amount_minor from public.bank_line_booking
                   where bank_transaction_id = %s order by seq""",
                (line,),
            ).fetchall()
        ]


def _proposal(tenant: dict[str, Any], line: str, action: str | None = None) -> dict[str, Any]:
    opts = _options(tenant, line)
    props = [p for p in opts["proposals"] if action is None or p["action"] == action]
    assert len(props) == 1, json.dumps(opts, default=str)
    return dict(props[0])


def _open_advances(client: str) -> list[tuple[str, int]]:
    """The client's double_payout advances whose entry is not reversed."""
    with psycopg.connect(DB) as conn:
        return [
            (str(r[0]), int(r[1]))
            for r in conn.execute(
                """select a.cause, a.amount_minor from public.client_advance a
                   where a.client_organization_id = %s and a.cause = 'double_payout'
                     and not exists (select 1 from public.ledger_entry r
                                     where r.reverses_entry_id = a.entry_id)
                   order by a.created_at""",
                (client,),
            ).fetchall()
        ]


def _received(client: str) -> int:
    """What the client was paid: its remittance entries' 4670 debits (planned and unplanned) net
    of the returns that reversed them."""
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select coalesce(sum(p.amount_minor), 0) from public.ledger_entry e
               join public.ledger_posting p on p.entry_id = e.id
               join public.ledger_account a on a.id = p.ledger_account_id
               left join public.ledger_entry t on t.id = e.reverses_entry_id
               where a.book = 'client_payable' and a.client_organization_id = %s
                 and (e.entry_type = 'remittance'
                      or (e.entry_type = 'reversal' and t.entry_type = 'remittance'))""",
            (client,),
        ).fetchone()
    return int(row[0]) if row else 0


def _cancel_after_download(tenant: dict[str, Any], run: str) -> None:
    """(as 6b-3 will do it) the run's payout cancelled after its file was handed out, then the run
    cancelled by an admin — the switch on for this one transaction only: committed off again."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            """update private.feature_switch set enabled = true
               where key = 'downloaded_file_cancellation'"""
        )
        conn.execute(
            """update public.bank_transfer set status = 'cancelled', cancelled_at = now(),
                 cancel_reason = 'annulé après remise (test)'
               where id = (select transfer_id from public.remittance_run where id = %s)""",
            (run,),
        )
        version = conn.execute(
            "select version from public.remittance_run where id = %s", (run,)
        ).fetchone()
        assert version is not None
        as_user(conn, tenant["admin"], "aal2")
        out = conn.execute(
            "select public.cancel_remittance_run(%s, %s, %s, %s)",
            (str(uuid.uuid4()), run, version[0], "annulé après remise (test)"),
        ).fetchone()
        assert out is not None and out[0]["status"] == "cancelled", out
        conn.execute("reset role")
        conn.execute(
            """update private.feature_switch set enabled = false
               where key = 'downloaded_file_cancellation'"""
        )
    with psycopg.connect(DB) as conn:
        row = conn.execute("select private.switch_on('downloaded_file_cancellation')").fetchone()
    assert row == (False,)


def _executed_on(file_id: str, day: date) -> None:
    """(test only, as pgTAP 037's exec_on) the file's items executed on `day`: a file generated
    today executes on the next business day, and a statement line is never dated in the future."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "alter table public.transfer_file_item disable trigger transfer_file_item_append_only"
        )
        conn.execute(
            "update public.transfer_file_item set execution_date = %s where file_id = %s",
            (day, file_id),
        )
        conn.execute(
            "alter table public.transfer_file_item enable always trigger"
            " transfer_file_item_append_only"
        )


def _schedule(tenant: dict[str, Any]) -> list[str]:
    """The schedule's drafts for the servicer now (10:00 Paris today)."""
    now = datetime.combine(paris_today(), datetime.min.time(), PARIS).replace(hour=10)
    with psycopg.connect(DB) as conn, conn.transaction():
        return run_schedule(conn, {"organization_id": tenant["servicer"]}, now=now)


def _trigger(run: str) -> str:
    return str(run_row(run)["trigger"])


# -- E1-E9, each payout debited twice, one copy back -------------------------------------------


def test_e1_to_e9_then_each_payout_debited_twice_and_one_copy_back(  # noqa: PLR0915
    tmp_path: Path,
) -> None:
    tenant, other, r1, r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    paid = _payouts(data)
    debited = paris_today() - timedelta(days=1)
    sid = _bank(tenant, data, booking_date=debited)
    # E5-E8: each payout booked from its debit, its run settled
    assert sorted(_bookings(sid)) == sorted(("payout", e, n) for e, n in paid)
    assert run_row(r1)["status"] == run_row(r2)["status"] == "booked"
    # E9: the next file sweeps the servicer's share, booked from its debit
    _f2, data2 = _downloaded(tenant, tmp_path)
    ((swp, share),) = _payouts(data2)
    assert swp.startswith("SWP")
    sid2 = _bank(tenant, data2)
    assert _bookings(sid2) == [("sweep", swp, share)]
    _no_violation(tenant)
    # `--mode twice`: each payout debited a second time (the copies only, dated today)
    today = paris_today()
    twice = [
        e
        for e in debits_of(
            pain001.read(data),
            booking_date=today - timedelta(days=1),
            mode="twice",
            ref_prefix=f"W{uuid.uuid4().hex[:6].upper()}",
        )
        if e.booking_date == today
    ]
    sid = _statement(tenant, twice)
    assert _bookings(sid) == []
    assert _reviews(sid) == ["transfer_debited_twice", "transfer_debited_twice"]
    for line in _lines(sid):
        proposal = _proposal(tenant, line, "unplanned_payout")
        (part,) = proposal["preview"]["parts"]
        assert (int(part["paid_minor"]), part["p_bound"]) == (0, "none")
        res = _book(tenant, line, proposal)
        assert res["funds_pass_queued"] is True
        assert [(b["kind"], int(b["advance_minor"])) for b in res["bookings"]] == [
            ("unplanned_payout", int(part["amount_minor"]))
        ]
    assert sorted(_open_advances(str(tenant["client"])) + _open_advances(str(other["client"]))) == (
        sorted(("double_payout", n) for _e, n in paid)
    )
    drain_payments(storage())  # the funds passes the command queued: nothing left to book
    _no_violation(tenant)
    # RV-3: Martin's next run holds the new collection, and the double payout's -A and +A net 0
    more = _file(tenant, 100_000)
    statement(
        tenant,
        storage(),
        [bank_credit(100_000, rf=more.rf)],
        f"T{uuid.uuid4().hex[:6].upper()}",
        recent_business_day(1),
    )
    rv3 = request_run(tenant)
    with psycopg.connect(DB) as conn:
        kinds = {
            str(r[0]): int(r[1])
            for r in conn.execute(
                """select kind, sum(amount_minor) from private.remittance_draft_line
                   where run_id = %s group by kind""",
                (rv3,),
            ).fetchall()
        }
    (martin_e2e, martin_n) = next(
        (e, n) for e, n in paid if _transfer(e)["client_organization_id"] == tenant["client"]
    )
    assert kinds == {
        "allocation": 100_000,
        "unplanned_payout": -martin_n,
        "client_advance": martin_n,
    }, kinds
    assert int(run_row(rv3)["gross_minor"]) == 100_000
    approve(tenant, rv3)
    drain_remittances()
    assert run_row(rv3)["status"] == "approved"
    # one copy of Martin's payout comes back: the job reviews it, ops book the proposal
    sid3 = _statement(tenant, _return_entries(data, martin_e2e, _day(tenant)))
    (back,) = _lines(sid3)
    assert _reviews(sid3) == ["unplanned_payout_return"]
    with psycopg.connect(DB) as conn:
        before = _queue(conn, str(tenant["client"]))
    proposal = _proposal(tenant, back, "returned")
    assert [p["kind"] for p in proposal["request"]] == ["unplanned_payout_returned"]
    res = _book(tenant, back, proposal)
    assert res["funds_pass_queued"] is True
    with psycopg.connect(DB) as conn:
        assert _queue(conn, str(tenant["client"])) == before  # +A and -A: nothing re-owed
    assert _open_advances(str(tenant["client"])) == []
    assert _transfer(martin_e2e)["status"] == "booked"
    drain_payments(storage())
    _no_violation(tenant)


# -- CSO2-7: both copies back on one statement --------------------------------------------------


def test_cso2_7_both_copies_back_on_one_statement(tmp_path: Path) -> None:
    tenant, _other, r1, _r2 = _two_runs()
    data, _paid = _booked(tenant, tmp_path)
    x = _run_transfer(r1)
    e2e, a = str(x["end_to_end_id"]), int(x["amount_minor"])
    client = str(tenant["client"])
    _sid, line = _debit_again(tenant, e2e, a)
    _book(tenant, line, _proposal(tenant, line, "unplanned_payout"))
    drain_payments(storage())
    day = _day(tenant)
    sid = _statement(tenant, _return_entries(data, e2e, day) + _return_entries(data, e2e, day))
    first, second = _lines(sid)
    assert _reviews(sid) == ["unplanned_payout_return", "unplanned_payout_return"]
    with psycopg.connect(DB) as conn:
        before = _queue(conn, client)
    res = _book(tenant, first, _proposal(tenant, first, "returned"))
    assert [b["kind"] for b in res["bookings"]] == ["unplanned_payout_returned"]
    assert res["funds_pass_queued"] is True
    drain_payments(storage())  # the pass the command queued reads the second line again
    assert _line_bookings(second) == [("payout_returned", a)]
    assert _review(second) is None
    assert _transfer(e2e)["status"] == "returned"
    with psycopg.connect(DB) as conn:
        assert _queue(conn, client) == before + a  # owed once again: the planned payout's return
    (draft,) = [
        r
        for r in _schedule(tenant)
        if run_row(r)["client_organization_id"] == x["client_organization_id"]
    ]
    assert (_trigger(draft), run_row(draft)["status"]) == ("payout_returned", "draft")
    _no_violation(tenant)


# -- ML-3: a second debit left unbooked, then a return of one copy ------------------------------


def test_ml3_the_return_waits_for_the_pending_second_debit(tmp_path: Path) -> None:
    tenant, _other, r1, _r2 = _two_runs()
    data, _paid = _booked(tenant, tmp_path)
    x = _run_transfer(r1)
    e2e, a = str(x["end_to_end_id"]), int(x["amount_minor"])
    client = str(tenant["client"])
    sid, d2 = _debit_again(tenant, e2e, a)
    assert _reviews(sid) == ["transfer_debited_twice"]
    sid2 = _statement(tenant, _return_entries(data, e2e, _day(tenant)))
    (back,) = _lines(sid2)
    assert _reviews(sid2) == ["return_debit_pending"] and _bookings(sid2) == []
    assert _transfer(e2e)["status"] == "booked"
    opts = _options(tenant, back)
    assert (opts["proposals"], opts["refusal"], opts["pending_line_id"]) == (
        [],
        "debit_pending",
        d2,
    )
    with psycopg.connect(DB) as conn:
        before = _queue(conn, client)
    res = _book(tenant, d2, _proposal(tenant, d2, "unplanned_payout"))
    assert res["funds_pass_queued"] is True
    drain_payments(storage())  # the pass re-reads the return: now an unplanned booking's copy
    assert _review(back) == "unplanned_payout_return" and _line_bookings(back) == []
    proposal = _proposal(tenant, back, "returned")
    assert [p["kind"] for p in proposal["request"]] == ["unplanned_payout_returned"]
    _book(tenant, back, proposal)
    with psycopg.connect(DB) as conn:
        assert _queue(conn, client) == before  # P = 0 then +A -A: nothing re-owed
    assert _open_advances(client) == []
    assert _transfer(e2e)["status"] == "booked"
    _no_violation(tenant)


# -- a run cancelled after download, its file's late debit (P = A), Martin's check --------------


def test_a_run_cancelled_after_download_then_its_late_debit_pays_its_items(
    tmp_path: Path,
) -> None:
    tenant, _other, r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    x = _run_transfer(r1)
    e2e, a = str(x["end_to_end_id"]), int(x["amount_minor"])
    client = str(tenant["client"])
    _cancel_after_download(tenant, r1)
    assert _transfer(e2e)["status"] == "cancelled" and run_row(r1)["status"] == "cancelled"
    draft = request_run(tenant)  # the released item reserved, prepared by the job
    prepared = run_row(draft)
    assert prepared["prepared_at"] is not None and int(prepared["gross_minor"]) == 200_000
    # the bank executes the file anyway: Lilas' payout booked by the job, Martin's left to ops
    sid = _bank(tenant, data)
    late = next(line for line in _lines(sid) if not _line_bookings(line))
    proposal = _proposal(tenant, late, "unplanned_payout")
    (part,) = proposal["preview"]["parts"]
    assert (int(part["paid_minor"]), int(part["advance_minor"]), part["p_bound"]) == (
        a,
        0,
        "amount",
    )
    assert [d["run_id"] for d in proposal["preview"]["drafts"]] == [draft]
    res = _book(tenant, late, proposal)
    assert res["drafts_requeued"] == [draft]
    head = run_row(draft)
    assert (head["job"], head["last_failure"], head["prepared_at"]) == ("prepare", None, None)
    drain_remittances()  # the prepare job under the new token
    head = run_row(draft)
    assert head["job"] is None and int(head["gross_minor"]) == 200_000 - a
    approve(tenant, draft)
    drain_remittances()
    assert run_row(draft)["status"] in ("approved", "booked")
    # Martin's check: he received his collection less the commission invoiced net of credit notes
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select coalesce(sum(d.ttc_minor), 0) from public.commission_invoice d
               where d.client_organization_id = %s""",
            (client,),
        ).fetchone()
    commission = int(row[0]) if row else 0
    received = _received(client) + (
        int(run_row(draft)["net_minor"]) if run_row(draft)["status"] == "approved" else 0
    )
    assert received == 200_000 - commission, (received, commission)
    assert _open_advances(client) == []
    drain_payments(storage())
    _no_violation(tenant)


# -- --mode partial ------------------------------------------------------------------------------


def test_a_partial_lot_booked_by_ops_then_the_left_out_member_by_the_job(tmp_path: Path) -> None:
    tenant, _other, r1, r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    paid = _payouts(data)
    sid = _bank(tenant, data, mode="partial")
    (line,) = _lines(sid)
    assert _bookings(sid) == [] and _reviews(sid) != []
    proposal = _proposal(tenant, line, "lot")
    ((kept_e2e, kept_n),) = [
        (p["end_to_end_id"], int(p["amount_minor"])) for p in proposal["preview"]["parts"]
    ]
    (left_e2e, left_n) = next((e, n) for e, n in paid if e != kept_e2e)
    _book(tenant, line, proposal)
    assert _line_bookings(line) == [("payout", kept_n)]
    assert _transfer(kept_e2e)["status"] == "booked" and _transfer(left_e2e)["status"] == "in_file"
    # the left-out member's own debit, the next day: the job books it
    day = _day(tenant)
    entry = Entry(
        left_n,
        False,
        day,
        day,
        ref=f"L{uuid.uuid4().hex[:7].upper()}",
        code=TRANSFER_DEBIT_CODE,
        txs=(Tx(left_n, end_to_end_id=left_e2e),),
    )
    sid2 = _statement(tenant, [entry])
    assert _bookings(sid2) == [("payout", left_e2e, left_n)]
    assert run_row(r1)["status"] == run_row(r2)["status"] == "booked"
    _no_violation(tenant)


# -- a CSV without the end-to-end column: rule 3b, and F12 --------------------------------------


def test_a_csv_without_references_rule_3b_and_a_cancelled_payout_s_late_execution(
    tmp_path: Path,
) -> None:
    tenant, other, r1, r2 = _two_runs()
    f, data = _downloaded(tenant, tmp_path)
    x1, x2 = _run_transfer(r1), _run_transfer(r2)
    _cancel_after_download(tenant, r2)  # Lilas' payout cancelled after download, its run too
    draft = request_run(other)  # Lilas' released item reserved by her draft
    day = _day(tenant)
    _executed_on(str(f["id"]), day)
    with psycopg.connect(DB) as conn:
        conn.execute("update public.bank_account set feed = 'csv' where id = %s", (tenant["bank"],))
    opening, _last = _last_closing(tenant)
    entries = debits_of(pain001.read(data), booking_date=day, ref_prefix=f"C{uuid.uuid4().hex[:5]}")
    doc = make_doc(entries, iban=tenant["iban"], from_date=day, to_date=day, opening_minor=opening)
    csv = render_bank_csv(expected_lines(doc), references=False)
    target = upload(tenant, storage(), csv, name=f"export-{uuid.uuid4().hex[:6]}.csv")
    drain_payments(storage())
    lines = _lines(str(target["statement_id"]))
    by_amount: dict[int, str] = {}
    with psycopg.connect(DB) as conn:
        for line in lines:
            row = conn.execute(
                """select amount_minor, end_to_end_id, counterparty_iban, kind
                   from public.bank_transaction where id = %s""",
                (line,),
            ).fetchone()
            assert row is not None and row[1] is None and row[2] is None, row
            by_amount[int(row[0])] = line
    l1, l2 = by_amount[int(x1["amount_minor"])], by_amount[int(x2["amount_minor"])]
    assert _line_bookings(l1) == [] and _line_bookings(l2) == []
    # rule 3b: the one payout in flight of that amount on the account
    opts = _options(tenant, l1)
    assert opts["class"] == "N"
    proposal = _proposal(tenant, l1, "payout")
    assert [p["transfer_id"] for p in proposal["request"]] == [str(x1["id"])]
    _book(tenant, l1, proposal)
    assert _transfer(str(x1["end_to_end_id"]))["status"] == "booked"
    # F12: the cancelled payout's late execution, its unplanned payout with P from its run's items
    proposal = _proposal(tenant, l2, "unplanned_payout")
    assert [p["transfer_id"] for p in proposal["request"]] == [str(x2["id"])]
    (part,) = proposal["preview"]["parts"]
    assert (int(part["paid_minor"]), part["p_bound"]) == (int(x2["amount_minor"]), "amount")
    res = _book(tenant, l2, proposal)
    assert res["drafts_requeued"] == [draft]
    assert _transfer(str(x2["end_to_end_id"]))["status"] == "cancelled"
    drain_payments(storage())
    drain_remittances()
    _no_violation(tenant)


# -- --debit-charge 120 ---------------------------------------------------------------------------


def _charged(data: bytes, day: date, *, detail_amount: bool, charges: bool = True) -> list[Entry]:
    entries = debits_of(
        pain001.read(data),
        booking_date=day,
        debit_charge_minor=120,
        debit_charge_detail_amount=detail_amount,
        ref_prefix=f"C{uuid.uuid4().hex[:6].upper()}",
    )
    if charges:
        return entries
    return [replace(e, charges_minor=None) for e in entries]


def test_a_debit_with_the_bank_s_charge_is_payout_and_fee(tmp_path: Path) -> None:
    tenant, _other, _r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    (a, na), (b, nb) = _payouts(data)
    day = _day(tenant)
    iso = next(e for e in _charged(data, day, detail_amount=True) if e.txs[0].end_to_end_id == a)
    plain = next(e for e in _charged(data, day, detail_amount=False) if e.txs[0].end_to_end_id == b)
    sid = _statement(tenant, [iso, plain])
    l_iso, l_plain = _lines(sid)
    assert _bookings(sid) == []
    for line, n, cls in ((l_iso, na, "U"), (l_plain, nb, "E")):
        opts = _options(tenant, line)
        assert opts["class"] == cls, opts
        (proposal,) = opts["proposals"]
        assert [(p["kind"], int(p["amount"])) for p in proposal["request"]] == [
            ("payout", n),
            ("fee", 120),
        ]
        _book(tenant, line, proposal)
        assert sorted(_line_bookings(line)) == sorted([("payout", n), ("fee", 120)])
    assert _transfer(a)["status"] == _transfer(b)["status"] == "booked"
    _no_violation(tenant)


def test_the_iso_charged_debit_without_chrgs_and_an_unsplit_entry_without_amounts_stay(
    tmp_path: Path,
) -> None:
    tenant, _other, _r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    (a, _na), _ = _payouts(data)
    day = _day(tenant)
    bare = next(
        e
        for e in _charged(data, day, detail_amount=True, charges=False)
        if e.txs[0].end_to_end_id == a
    )
    no_amounts = debits_of(
        pain001.read(data),
        booking_date=day,
        mode="batch",
        unsplit_details="no-amounts",
        ref_prefix=f"U{uuid.uuid4().hex[:6].upper()}",
    )
    sid = _statement(tenant, [bare, *no_amounts])
    l_bare, l_none = _lines(sid)
    for line in (l_bare, l_none):
        opts = _options(tenant, line)
        assert (opts["class"], opts["proposals"], opts["refusal"]) == (
            "U",
            [],
            "unsplit_detail_missing",
        ), opts
        assert _line_bookings(line) == [] and _review(line) is not None
    assert _transfer(a)["status"] == "in_file"
    # the request a sheet could still send is refused the same way
    with pytest.raises(psycopg.Error) as exc:
        api(
            tenant,
            "select public.book_transfer_line(%s, %s, %s, %s, %s)",
            str(uuid.uuid4()),
            l_bare,
            Jsonb(
                [
                    {"kind": "payout", "transfer_id": str(_transfer(a)["id"]), "amount": str(_na)},
                    {"kind": "fee", "amount": "120"},
                ]
            ),
            "x",
            REASON,
        )
    assert exc.value.diag.message_primary == "transfer line booking refused: unsplit_detail_missing"


# -- --unflagged-returns ------------------------------------------------------------------------


def test_an_unflagged_return_is_virement_revenu_and_the_schedule_drafts_its_run(
    tmp_path: Path,
) -> None:
    tenant, _other, r1, _r2 = _two_runs()
    data, _paid = _booked(tenant, tmp_path)
    x = _run_transfer(r1)
    e2e, a = str(x["end_to_end_id"]), int(x["amount_minor"])
    entries = [
        e
        for e in debits_of(
            pain001.read(data),
            returns=[e2e],
            return_date=_day(tenant),
            unflagged_returns=True,
            ref_prefix=f"R{uuid.uuid4().hex[:6].upper()}",
        )
        if e.credit
    ]
    sid = _statement(tenant, entries)
    (line,) = _lines(sid)
    if not _line_bookings(line):  # left to ops: « Virement revenu », the exact amount
        proposal = _proposal(tenant, line, "returned")
        assert [(p["kind"], int(p["amount"])) for p in proposal["request"]] == [
            ("payout_returned", a)
        ]
        _book(tenant, line, proposal)
    assert _line_bookings(line) == [("payout_returned", a)]
    assert _transfer(e2e)["status"] == "returned"
    with psycopg.connect(DB) as conn:
        held = conn.execute(
            """select l.latest_execution_date from public.remittance_line l
               where l.run_id = %s and l.amount_minor > 0
               order by l.latest_execution_date limit 1""",
            (r1,),
        ).fetchone()
    _replace_payout_account(tenant)
    (draft,) = [
        r for r in _schedule(tenant) if run_row(r)["client_organization_id"] == tenant["client"]
    ]
    assert _trigger(draft) == "payout_returned"
    drain_remittances()
    with psycopg.connect(DB) as conn:
        line_held = conn.execute(
            """select latest_execution_date from private.remittance_draft_line
               where run_id = %s and kind = 'payout_returned'""",
            (draft,),
        ).fetchone()
    assert held is not None and line_held is not None and line_held[0] == held[0]
    _no_violation(tenant)


# -- an entry kept unsplit netting our return into our next payout ------------------------------


def test_an_unsplit_entry_of_our_details_is_booked_from_its_stored_details(tmp_path: Path) -> None:
    tenant, _other, _r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    (a, na), (b, nb) = sorted(_payouts(data), key=lambda p: p[1])  # na < nb
    day = _day(tenant)
    # a's own debit first: the job books it
    first = Entry(na, False, day, day, ref=f"A{uuid.uuid4().hex[:7].upper()}",
                  code=TRANSFER_DEBIT_CODE, txs=(Tx(na, end_to_end_id=a),))  # fmt: skip
    sid = _statement(tenant, [first])
    assert _bookings(sid) == [("payout", a, na)]
    # then one entry netting a's return into b's debit: kept unsplit, every detail ours
    netted = Entry(
        nb - na,
        False,
        day,
        day,
        ref=f"U{uuid.uuid4().hex[:7].upper()}",
        code=TRANSFER_DEBIT_CODE,
        txs=(
            Tx(nb, end_to_end_id=b, direction="debit"),
            Tx(na, end_to_end_id=a, direction="credit"),
        ),
        batch_count=2,
    )
    sid2 = _statement(tenant, [netted])
    (line,) = _lines(sid2)
    assert _bookings(sid2) == []
    opts = _options(tenant, line)
    assert (opts["class"], opts["unsplit_ours"]) == ("U", 2), opts
    (proposal,) = opts["proposals"]
    assert sorted((p["kind"], int(p["amount"])) for p in proposal["request"]) == sorted(
        [("payout", nb), ("payout_returned", na)]
    )
    _book(tenant, line, proposal)
    assert sorted(_line_bookings(line)) == sorted([("payout", nb), ("payout_returned", na)])
    assert (_transfer(a)["status"], _transfer(b)["status"]) == ("returned", "booked")
    _no_violation(tenant)


# -- P parity: the command's P = the Python twin's, on 200 generated pools ----------------------


@pytest.fixture(scope="module")
def cancelled_pool() -> dict[str, Any]:
    """A client's run of four collections approved, then cancelled before any file: its payout x
    cancelled, its four released items back in the queue; a fifth collection paid after the
    approval (another item of the queue); x's debit on a statement (class E, its RMT id),
    committed. Each example then shapes the facts in its own transaction, rolled back."""
    tenant = remittance_tenant()
    _own_account(tenant)
    amounts = (40_000, 30_000, 20_000, 10_000)
    files = [_file(tenant, n) for n in amounts]
    statement(
        tenant,
        storage(),
        [bank_credit(n, rf=f.rf) for f, n in zip(files, amounts, strict=True)],
        f"P{uuid.uuid4().hex[:6].upper()}",
        recent_business_day(2),
    )
    run = request_run(tenant)
    approve(tenant, run)
    drain_remittances()
    fifth = _file(tenant, 5_000)
    statement(
        tenant,
        storage(),
        [bank_credit(5_000, rf=fifth.rf)],
        f"Q{uuid.uuid4().hex[:6].upper()}",
        recent_business_day(1),
    )
    staff(
        tenant,
        "select public.cancel_remittance_run(%s, %s, %s, %s)",
        str(uuid.uuid4()),
        run,
        run_row(run)["version"],
        "annulé (test de parité)",
        user=tenant["admin"],
    )
    with psycopg.connect(DB) as conn:
        cur = conn.execute(
            "select * from public.bank_transfer where run_id = %s and kind = 'payout'", (run,)
        )
        found = cur.fetchone()
        assert found is not None and cur.description is not None
        x = {d.name: v for d, v in zip(cur.description, found, strict=True)}
    assert x["status"] == "cancelled" and run_row(run)["status"] == "cancelled"
    day = _day(tenant)
    entry = Entry(
        int(x["amount_minor"]),
        False,
        day,
        day,
        ref=f"X{uuid.uuid4().hex[:7].upper()}",
        code=TRANSFER_DEBIT_CODE,
        txs=(Tx(int(x["amount_minor"]), end_to_end_id=str(x["end_to_end_id"])),),
    )
    sid = _statement(tenant, [entry])
    (line,) = _lines(sid)
    with psycopg.connect(DB) as conn:
        items = [
            str(r[0])
            for r in conn.execute(
                """select ledger_entry_id from public.remittance_line
                   where run_id = %s and released order by ledger_entry_id""",
                (run,),
            ).fetchall()
        ]
        booking = conn.execute(
            """select e.id::text from public.ledger_entry e
               where e.organization_id = %s and e.entry_type = 'cash_in'
               order by e.posted_at desc limit 1""",
            (tenant["servicer"],),
        ).fetchone()
        # the fifth collection's item: the client's only other pending row (the examples' reversals
        # add rows of their own, never this one)
        others = conn.execute(
            """select ledger_entry_id::text, amount_minor from private.remittance_pending
               where client_organization_id = %s and ledger_entry_id <> all(%s::uuid[])""",
            (tenant["client"], items),
        ).fetchall()
    assert len(items) == 4 and booking is not None
    assert [int(r[1]) for r in others] == [5_000], others
    return {"tenant": tenant, "x": x, "line": line, "items": items, "booking": booking[0],
            "fifth": others[0][0]}  # fmt: skip


# an item: its pending (None: no row), its reversal's pending, what an earlier unreversed booking
# attributed to it
ITEM = st.tuples(
    st.one_of(st.none(), st.integers(-30_000, -1), st.integers(1, 60_000)),
    st.one_of(st.none(), st.integers(-60_000, -1), st.integers(1, 30_000)),
    st.integers(0, 30_000),
)


@settings(
    max_examples=200,
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture, HealthCheck.too_slow],
)
@given(
    pool=st.lists(ITEM, min_size=4, max_size=4),
    amount=st.integers(1, 120_000),
    extra=st.integers(-50_000, 80_000).filter(lambda v: v != -5_000),  # the fifth item: never 0
    other=st.booleans(),
)
def test_p_parity_with_the_twin_on_generated_pools(
    cancelled_pool: dict[str, Any], pool: list[tuple[int | None, int | None, int]], amount: int,
    extra: int, other: bool,
) -> None:  # fmt: skip
    """The command's P, advance and bound (its preview, as ops see it) equal the twin's on the
    same facts, read back from SQL (`_pool_item`, `_queue`). With `other` (review M2c-6b-3a-2
    round 1, tests-7), the earlier attributions are those of an unplanned booking of another
    transfer (a bank_line_booking of it on that entry): J's items, `paid_by_other` read with the
    SQL predicate and the ask carrying x."""
    t, x, line = cancelled_pool["tenant"], cancelled_pool["x"], cancelled_pool["line"]
    client = str(t["client"])
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        # (the transaction is rolled back: the guards are off only inside it)
        conn.execute("alter table public.bank_transfer disable trigger user")
        conn.execute("alter table public.bank_transaction disable trigger user")
        conn.execute("update public.bank_transfer set amount_minor = %s where id = %s",
                     (amount, x["id"]))  # fmt: skip
        conn.execute("update public.bank_transaction set amount_minor = %s where id = %s",
                     (amount, line))  # fmt: skip
        for entry, (pending, reversal, paid) in zip(cancelled_pool["items"], pool, strict=True):
            if reversal is not None:
                rev = conn.execute(
                    "select entry_id from private.ledger_reverse(%s, %s, %s, %s)",
                    (entry, f"parity:{uuid.uuid4()}", "parité (test)", paris_today()),
                ).fetchone()
                assert rev is not None
                conn.execute(
                    """update private.remittance_pending set amount_minor = %s
                       where ledger_entry_id = %s""",
                    (reversal, rev[0]),
                )
            if pending is None:
                conn.execute(
                    "delete from private.remittance_pending where ledger_entry_id = %s", (entry,)
                )
            else:
                conn.execute(
                    """update private.remittance_pending set amount_minor = %s
                       where ledger_entry_id = %s""",
                    (pending, entry),
                )
            if paid:
                conn.execute(
                    """insert into private.unplanned_paid_item (booking_entry_id, ledger_entry_id,
                         organization_id, client_organization_id, currency, amount_minor)
                       values (%s, %s, %s, %s, 'EUR', %s)""",
                    (cancelled_pool["booking"], entry, t["servicer"], client, paid),
                )
        if extra:
            conn.execute(
                """update private.remittance_pending set amount_minor = amount_minor + %s
                   where ledger_entry_id = %s""",
                (extra, cancelled_pool["fifth"]),
            )
        if other:
            # the attributions' booking is an unplanned payout of another cancelled transfer (a
            # copy of x under another id and reference), on another line of the account
            conn.execute("alter table public.bank_line_booking disable trigger user")
            copy = conn.execute(
                """insert into public.bank_transfer
                   select (jsonb_populate_record(null::public.bank_transfer, to_jsonb(t)
                           || jsonb_build_object('id', gen_random_uuid(),
                                                 'end_to_end_id', 'RMTF' || upper(left(md5(
                                                   random()::text), 11))))).*
                   from public.bank_transfer t where t.id = %s returning id""",
                (x["id"],),
            ).fetchone()
            assert copy is not None
            conn.execute(
                """insert into public.bank_line_booking (bank_transaction_id, seq, organization_id,
                     bank_account_id, kind, transfer_id, entry_id, amount_minor, method)
                   select q.id, 99, q.organization_id, q.bank_account_id, 'unplanned_payout', %s,
                          %s, 1, 'auto'
                   from public.bank_transaction q
                   where q.organization_id = %s and q.id <> %s limit 1""",
                (copy[0], cancelled_pool["booking"], t["servicer"], line),
            )
        transfer = str(x["id"])
        items = {e: _pool_item(conn, e, transfer) for e in cancelled_pool["items"]}
        assert other or not any(i.paid_by_other for i in items.values())
        queue = _queue(conn, client)
        (twin,) = unplanned_p(
            [UnplannedAsk(amount, client, tuple(cancelled_pool["items"]), transfer=transfer)],
            items,
            {client: queue},
        )
        claims = json.dumps({"sub": t["staff"], "role": "authenticated", "aal": "aal2"})
        conn.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
        conn.execute("set local role authenticated")
        row = conn.execute(
            "select public.transfer_line_preview(%s, %s)",
            (line, Jsonb([{"kind": "unplanned_payout", "transfer_id": str(x["id"]),
                           "amount": str(amount)}])),
        ).fetchone()  # fmt: skip
        assert row is not None
        preview = row[0]
        assert preview["ok"], preview
        (part,) = preview["parts"]
        got = (int(part["paid_minor"]), int(part["advance_minor"]), part["p_bound"])
        assert got == (twin.p, twin.advance, twin.bound), (got, twin, items, queue)
