"""M2c-6b-1 bookings core through the database, the worker, storage and the real camt.053 parser
(needs `make up`; plan docs/design/m2c-6b-plan.md §2, §6; design m2c-remittances §7, §12, §13).

A file of two payouts is generated, written by the job, downloaded; its bytes are read back
(`pain001.read`) and the bank's statement of its debits is synthesised (`synth camt053
--debits-of`), imported and the payments queue drained: the M2b pass, then the funds pass in its
own message (plan §2.5 [critic]).

* §7.2 E5-E8: each payout booked from its debit (by its RMT id, or one batch line of its PmtInf),
  its run settled (`client_settlement`), transfer and run `booked`; E9: the sweep the next file
  carries, booked from its debit (`servicer_sweep`); I9, I19 and I20 hold;
* a batch line missing a member, a second debit of a payout: never booked, left to ops with why;
* §7.3: a payout returned (charges deducted: the full reversal, the difference a `bank_fee`), the
  payout account `returned`, a `payout_returned` item; a bank fee on its own;
* concurrency (plan §2.5 [critic]): the job's first message and a command holding a run's row
  (its cancellation, its file's re-download) never deadlock: the funds pass runs in its own
  transaction (staged on three sessions);
* a returned payout re-proposed keeps its R124-6 date (K2); a return dated before its debit is
  left to ops (K5).
"""

from __future__ import annotations

import hashlib
import threading
import time
import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from debit_helpers import checks, return_entry, violations
from integration_helpers import DB, as_user, storage
from psycopg.rows import dict_row
from remittance_helpers import approve, confirm_payout, paris_today, request_run, run_row, staff
from remittance_helpers import drain as drain_remittances
from statement_helpers import drain as drain_payments
from statement_helpers import upload
from test_transfer_files_integration import _bytes, _file_row, _generate, _two_runs

from collectoo_worker.jobs.debits import debit_dates, funds_lines, run_process_debits
from collectoo_worker.remittance import pain001
from collectoo_worker.synth.camt053 import FEE_CODE, debits_of, make_doc, render_camt053

pytestmark = pytest.mark.integration


def _downloaded(tenant: dict[str, Any], tmp_path: Path) -> tuple[dict[str, Any], bytes]:
    """The next file of the account generated, written by the job, downloaded; its bytes."""
    res = _generate(tenant)
    drain_remittances()
    f = _file_row(res["file_id"])
    assert f["status"] == "generated"
    data = _bytes(f["storage_path"], tmp_path)
    staff(
        tenant,
        "select public.transfer_file_download(%s, %s)",
        f["id"],
        hashlib.sha256(data).hexdigest(),
    )
    return f, data


def _last_closing(tenant: dict[str, Any]) -> tuple[int, date]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select closing_booked_minor, to_date from public.bank_statement
               where bank_account_id = %s order by to_date desc, created_at desc limit 1""",
            (tenant["bank"],),
        ).fetchone()
    assert row is not None
    return int(row[0]), row[1]


def _bank(tenant: dict[str, Any], data: bytes, *, only_back: bool = False, **kw: Any) -> str:
    """The statement of the file's debits (and what else `kw` asks), imported; the queue drained.
    `only_back`: the returns and the fee alone (the debits were on an earlier statement)."""
    opening, last = _last_closing(tenant)
    day = max(paris_today(), last)
    kw.setdefault("booking_date", day)
    entries = debits_of(pain001.read(data), ref_prefix=f"D{uuid.uuid4().hex[:6].upper()}", **kw)
    if only_back:
        entries = [e for e in entries if e.credit or e.code == FEE_CODE]
    days = [e.booking_date for e in entries]
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        entries,
        iban=tenant["iban"],
        from_date=min(days),
        to_date=max(days),
        opening_minor=opening,
        stmt_id=stmt,
    )
    target = upload(tenant, storage(), render_camt053(doc, "08"), name=f"{stmt}.xml")
    drain_payments(storage())
    return str(target["statement_id"])


def _bookings(statement_id: str) -> list[tuple[str, str | None, int]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select b.kind, t.end_to_end_id, b.amount_minor
               from public.bank_line_booking b
               join public.bank_transaction l on l.id = b.bank_transaction_id
               left join public.bank_transfer t on t.id = b.transfer_id
               where l.statement_id = %s order by l.line_no, b.seq""",
            (statement_id,),
        ).fetchall()
    return [(r[0], r[1], int(r[2])) for r in rows]


def _reviews(statement_id: str) -> list[str]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select r.reason from public.bank_debit_review r
               join public.bank_transaction l on l.id = r.bank_transaction_id
               where l.statement_id = %s order by l.line_no""",
            (statement_id,),
        ).fetchall()
    return [r[0] for r in rows]


def _transfer(e2e: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute("select * from public.bank_transfer where end_to_end_id = %s", (e2e,))
        row = cur.fetchone()
        assert row is not None and cur.description is not None
        return {d.name: v for d, v in zip(cur.description, row, strict=True)}


def _entries(source_id: str) -> list[tuple[str, int]]:
    """The entries posted for a transfer or a run: type and the 5120 / 4679 movement."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select e.entry_type,
                      coalesce(sum(p.amount_minor) filter (where a.book = 'client_money_cash'), 0)
               from public.ledger_entry e
               join public.ledger_posting p on p.entry_id = e.id
               join public.ledger_account a on a.id = p.ledger_account_id
               where e.source_id = %s group by e.id, e.entry_type order by min(e.posted_at)""",
            (source_id,),
        ).fetchall()
    return [(r[0], int(r[1])) for r in rows]


def _dated(source_id: str, entry_type: str) -> list[date]:
    """The effective dates of a transfer's or a run's entries of one type."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select effective_date from public.ledger_entry
               where source_id = %s and entry_type = %s order by posted_at""",
            (source_id, entry_type),
        ).fetchall()
    return [r[0] for r in rows]


def _no_violation(tenant: dict[str, Any]) -> None:
    result = checks(tenant)
    bad = violations(str(result["run_id"])) if "run_id" in result else []
    assert [
        v
        for v in bad
        if v[0]
        in ("bank_cash_identity", "transfer_booked_once", "bank_line_booked", "bank_balance_gap")
    ] == []


def _payouts(data: bytes) -> list[tuple[str, int]]:
    f = pain001.read(data)
    return [(t.end_to_end_id, t.amount_minor) for p in f.payment_infos for t in p.transactions]


@pytest.mark.parametrize("mode", ["individual", "batch", "batch-details"])
def test_e5_to_e9_payouts_settlements_and_the_sweep_booked_from_the_bank(
    tmp_path: Path, mode: str
) -> None:
    tenant, _other, r1, r2 = _two_runs()
    f, data = _downloaded(tenant, tmp_path)
    paid = _payouts(data)
    assert len(paid) == 2
    # debited the day before the job runs (review T5: the remittance, the run's settlement and its
    # VAT move, settled_on and booked_on are dated at the debit, never at the job's day — OQ-37)
    debited = paris_today() - timedelta(days=1)
    assert debited >= _last_closing(tenant)[1]
    sid = _bank(tenant, data, mode=mode, booking_date=debited)
    assert sorted(_bookings(sid)) == sorted(("payout", e2e, n) for e2e, n in paid)
    assert _reviews(sid) == []
    for e2e, n in paid:
        t = _transfer(e2e)
        assert t["status"] == "booked"
        assert _entries(str(t["id"])) == [("remittance", -n)]  # E5 / E7: -N on 5120
        assert _dated(str(t["id"]), "remittance") == [debited]
    for r in (r1, r2):
        run = run_row(r)
        assert run["status"] == "booked" and run["booked_on"] == debited
        assert [k for k, _ in _entries(r)][-1:] == ["client_settlement"]  # E6 / E8
        assert _dated(r, "client_settlement") == [debited]
        with psycopg.connect(DB) as conn:
            settled = conn.execute(
                "select distinct settled_on from public.commission_settlement where run_id = %s",
                (r,),
            ).fetchall()
        assert [x[0] for x in settled] == [debited]
    _no_violation(tenant)
    # E9: the next file carries the sweep of the servicer's share (4679), booked from its debit
    f2, data2 = _downloaded(tenant, tmp_path)
    assert f2["id"] != f["id"]
    swept = _payouts(data2)
    assert len(swept) == 1 and swept[0][0].startswith("SWP")
    commission = sum(
        int(run_row(r)["gross_minor"]) - int(run_row(r)["net_minor"]) for r in (r1, r2)
    )
    assert swept[0][1] == commission
    sid2 = _bank(tenant, data2)
    assert _bookings(sid2) == [("sweep", swept[0][0], commission)]
    s = _transfer(swept[0][0])
    assert s["status"] == "booked" and _entries(str(s["id"])) == [("servicer_sweep", -commission)]
    _no_violation(tenant)


def test_a_partial_batch_and_a_second_debit_are_left_to_ops(tmp_path: Path) -> None:
    tenant, _other, r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    sid = _bank(tenant, data, mode="partial")  # one member missing: not booked, never in part
    assert _bookings(sid) == []
    assert _reviews(sid) != []
    assert run_row(r1)["status"] != "booked"
    tenant2, _o2, _a, _b = _two_runs()
    _f2, data2 = _downloaded(tenant2, tmp_path)
    # each debited again the next day (today: a statement is never dated in the future)
    sid2 = _bank(tenant2, data2, mode="twice", booking_date=paris_today() - timedelta(days=1))
    assert len(_bookings(sid2)) == 2
    assert _reviews(sid2) == ["transfer_debited_twice", "transfer_debited_twice"]


def test_a_payout_returned_less_the_bank_s_charge_and_a_fee(tmp_path: Path) -> None:
    tenant, _other, r1, r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    paid = _payouts(data)
    _bank(tenant, data)
    e2e, _n = paid[0]
    sid = _bank(
        tenant,
        data,
        mode="batch",
        returns=[e2e],
        charges_minor=150,
        fee_minor=1_200,
        return_date=max(paris_today(), _last_closing(tenant)[1]),
        only_back=True,
    )
    kinds = [k for k, _, _ in _bookings(sid)]
    assert "payout_returned" in kinds and kinds.count("fee") == 2  # the charge and the fee
    t = _transfer(e2e)
    assert t["status"] == "returned"
    assert [k for k, _ in _entries(str(t["id"]))] == ["remittance"]
    with psycopg.connect(DB) as conn:  # E5 reversed in full (the charge is the fee)
        rev = conn.execute(
            """select e.entry_type, e.reverses_entry_id = t.entry_id
               from public.bank_line_booking b join public.ledger_entry e on e.id = b.entry_id
               join public.bank_transfer t on t.id = b.transfer_id
               where b.transfer_id = %s and b.kind = 'payout_returned'""",
            (t["id"],),
        ).fetchone()
    assert rev == ("reversal", True)
    with psycopg.connect(DB) as conn:
        # the payout account of the returned transfer's own run (review T8: a payout transfer has
        # no creditor bank account; the run names the client's payout account), and the other's
        accounts: dict[str, str] = dict(
            conn.execute(
                """select r.id::text, a.status from public.remittance_run r
                   join public.client_payout_account a on a.id = r.payout_account_id
                   where r.id = any(%s::uuid[])""",
                ([r1, r2],),
            ).fetchall()
        )
        pending = conn.execute(
            """select count(*) from private.remittance_pending
               where organization_id = %s and kind = 'payout_returned'""",
            (tenant["servicer"],),
        ).fetchone()
    returned_run = str(t["run_id"])
    assert returned_run in (r1, r2)
    assert accounts == {r: "returned" if r == returned_run else "active" for r in (r1, r2)}
    assert pending is not None and pending[0] >= 1
    assert run_row(r1)["status"] == "booked"  # E6 stays: the compensation took place
    _no_violation(tenant)


# -- concurrency: the funds pass in its own transaction (plan §2.5 [critic]; concurrency-1, T1) --

# what the other side may answer, by SQLSTATE and message: it holds the run's row, then waits for
# the allocation lock; refused under them (the switch off: a downloaded file's payout is not
# cancelled, an executed file is not downloaded again)
REFUSALS = {
    "cancel": ("23514", "remittance run refused: payout_in_downloaded_file"),
    "download": ("23514", "transfer file refused: file_executed"),
}


def _import_only(statement: bytes, tenant: dict[str, Any], name: str) -> None:
    """The statement imported, its `process_debits` message taken off the queue unrun: its lines
    wait for the job's first message, which the test runs."""
    from collectoo_worker.jobs.payments import make_handler, record_dead_job  # noqa: PLC0415
    from collectoo_worker.runtime.queue import QueueConsumer  # noqa: PLC0415

    upload(tenant, storage(), statement, name=name)
    handle = make_handler(storage())

    def handler(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        if payload.get("type") != "process_debits":
            handle(payload, conn)

    consumer = QueueConsumer(DB, "payments", handler, on_dead=record_dead_job)
    while consumer.poll_once():
        pass


def _waits_on_advisory(pid: int, timeout_s: float = 15.0) -> bool:
    """True once the session waits on an advisory lock (the allocation lock)."""
    with psycopg.connect(DB, autocommit=True) as conn:
        end = time.monotonic() + timeout_s
        while time.monotonic() < end:
            row = conn.execute(
                "select wait_event_type, wait_event from pg_stat_activity where pid = %s", (pid,)
            ).fetchone()
            if row is not None and tuple(row) == ("Lock", "advisory"):
                return True
            time.sleep(0.02)
    return False


@pytest.mark.parametrize("other", ["cancel", "download"])
def test_the_funds_pass_and_a_command_holding_the_run_never_deadlock(  # noqa: PLR0915
    tmp_path: Path, other: str
) -> None:
    """Plan §2.5 [critic]: a command holds a run's row, then waits for the allocation lock
    (cancel_remittance_run, transfer_file_download); the job's first message (the M2b pass: a
    payer's return on the statement takes the allocation lock) must not then wait for that row.
    Staged on three sessions: one holds the allocation lock; the job's first message queues on
    it; the command locks r1's row and queues behind the job; the lock is released. The M2b pass
    commits without the funds pass, the command gets the lock and is refused, the funds message
    (the queue's, in its own transaction) books each payout once. With the funds pass in the M2b
    pass's transaction, the job would hold the allocation lock while it waits for r1's row: a
    deadlock (mutant MERGED: DeadlockDetected)."""
    tenant, _client, r1, r2 = _two_runs()
    f, data = _downloaded(tenant, tmp_path)
    opening, last = _last_closing(tenant)
    day = max(paris_today(), last)
    ref = f"C{uuid.uuid4().hex[:6].upper()}"
    entries = [
        *debits_of(pain001.read(data), booking_date=day, ref_prefix=ref),
        # a payer's return (a line of the M2b pass: it takes the allocation lock)
        return_entry(5_000, f"E2E{uuid.uuid4().hex[:12].upper()}", f"{ref}R", day),
    ]
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(entries, iban=tenant["iban"], from_date=day, to_date=day,
                   opening_minor=opening, stmt_id=stmt)  # fmt: skip
    _import_only(render_camt053(doc, "08"), tenant, f"{stmt}.xml")
    assert run_row(r1)["status"] == "sent"  # its debit is not booked yet
    org = str(tenant["servicer"])
    version = run_row(r1)["version"]
    pids: dict[str, int] = {}
    errors: list[BaseException] = []
    outcome: list[str] = []
    go = threading.Event()

    def job() -> None:
        try:
            with psycopg.connect(DB) as conn:
                pids["job"] = conn.info.backend_pid
                with conn.transaction():  # the job's first message (the queue's transaction)
                    summary = run_process_debits(
                        conn, {"type": "process_debits", "organization_id": org}
                    )
                outcome.append("job:with_funds" if "funds" in summary else "job:m2b")
            drain_payments(storage())  # then the funds message it queued, in its own
        except BaseException as exc:  # asserted below
            errors.append(exc)

    def command() -> None:
        sqlstate, message = REFUSALS[other]
        try:
            with psycopg.connect(DB) as conn:
                pids["other"] = conn.info.backend_pid
                go.wait(30)
                with conn.transaction():
                    as_user(conn, tenant["admin"], "aal2")
                    conn.execute("set local statement_timeout = '30s'")
                    if other == "cancel":
                        conn.execute(
                            "select public.cancel_remittance_run(%s, %s, %s, %s)",
                            (str(uuid.uuid4()), r1, version, "test de concurrence"),
                        )
                    else:  # a re-download, acknowledged
                        conn.execute(
                            "select public.transfer_file_download(%s, %s, true)",
                            (f["id"], hashlib.sha256(data).hexdigest()),
                        )
            outcome.append(f"{other}:done")
        except psycopg.Error as exc:
            if exc.sqlstate == sqlstate and exc.diag.message_primary == message:
                outcome.append(f"{other}:refused")
            else:
                errors.append(exc)  # anything else (a deadlock included) fails the test

    a, b = threading.Thread(target=job), threading.Thread(target=command)
    # the third session holds the allocation lock; once it commits, the job gets the lock first
    # (it queued first), then the command
    with psycopg.connect(DB) as holder, holder.transaction():
        holder.execute("select pg_advisory_xact_lock(hashtext('payments:' || %s))", (org,))
        a.start()
        b.start()
        for _ in range(1500):
            if "job" in pids and "other" in pids:
                break
            time.sleep(0.01)
        assert _waits_on_advisory(pids["job"]), "the job's first message never queued"
        go.set()
        assert _waits_on_advisory(pids["other"]), "the command never queued behind it"
    a.join(90)
    b.join(90)
    assert not a.is_alive() and not b.is_alive()
    deadlocks = [e for e in errors if isinstance(e, psycopg.errors.DeadlockDetected)]
    assert deadlocks == [], deadlocks
    if errors:
        raise errors[0]
    assert sorted(outcome) == sorted(["job:m2b", f"{other}:refused"])
    drain_payments(storage())
    with psycopg.connect(DB) as conn:
        booked = conn.execute(
            """select t.run_id::text, count(b.bank_transaction_id) from public.bank_transfer t
               left join public.bank_line_booking b on b.transfer_id = t.id and b.kind = 'payout'
               where t.run_id = any(%s::uuid[]) and t.kind = 'payout' group by t.run_id""",
            ([r1, r2],),
        ).fetchall()
    assert dict(booked) == {r1: 1, r2: 1}  # each payout booked once (I20)
    assert run_row(r1)["status"] == run_row(r2)["status"] == "booked"
    _no_violation(tenant)


# -- a returned payout re-proposed keeps its R124-6 date (K2; review legal-texts#1, money-2) ----


def _run_transfer(run: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute(
            """select * from public.bank_transfer
               where run_id = %s and kind = 'payout' and status <> 'cancelled'""",
            (run,),
        )
        row = cur.fetchone()
        assert row is not None and cur.description is not None
        return {d.name: v for d, v in zip(cur.description, row, strict=True)}


def _replace_payout_account(tenant: dict[str, Any]) -> str:
    """The client's returned payout account retired and a new one confirmed (as a client who gives
    a new RIB after the return: the payout_account_returned blocker lifts)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            """update public.client_payout_account set status = 'retired', closed_by = %s,
                 closed_at = now(), closed_reason = 'Remplacé après le retour du virement'
               where client_organization_id = %s and currency = 'EUR' and status = 'returned'""",
            (tenant["staff"], tenant["client"]),
        )
        return confirm_payout(conn, tenant, tenant["client"])


def _deadline_cols(table: str, where: str, *params: Any) -> tuple[Any, ...]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            f"""select encaissement_date, deadline, latest_execution_date, unmeetable
                from {table} where {where}""",  # noqa: S608 - the tests' own constants
            params,
        ).fetchone()
    assert row is not None
    return tuple(row)


@pytest.fixture(scope="module")
def re_proposed(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """Martin's payout booked from its debit, then returned (§7.3); his payout account replaced; a
    run requested for him and prepared by the worker's job: the payout_returned item re-proposed.
    Then approved after the date it is held to: without a reason, then with one."""
    tmp = tmp_path_factory.mktemp("returned")
    tenant, _other, r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp)
    _bank(tenant, data)
    t = _run_transfer(r1)
    _bank(
        tenant,
        data,
        returns=[t["end_to_end_id"]],
        return_date=max(paris_today(), _last_closing(tenant)[1]),
        only_back=True,
    )
    assert _transfer(t["end_to_end_id"])["status"] == "returned"
    with psycopg.connect(DB) as conn:
        item = conn.execute(
            """select q.ledger_entry_id, q.amount_minor from private.remittance_pending q
               where q.client_organization_id = %s and q.kind = 'payout_returned'""",
            (tenant["client"],),
        ).fetchone()
        # the returned run's line it is held to: positive, live, dated, the earliest date
        held = conn.execute(
            """select l.line_no, l.mandate_terms_id from public.remittance_line l
               where l.run_id = %s and l.amount_minor > 0 and not l.released
                 and l.latest_execution_date is not null
               order by l.latest_execution_date, l.line_no limit 1""",
            (r1,),
        ).fetchone()
    assert item is not None and held is not None
    _replace_payout_account(tenant)
    rerun = request_run(tenant)
    assert run_row(rerun)["prepared_at"] is not None
    original = _deadline_cols("public.remittance_line", "run_id = %s and line_no = %s", r1, held[0])
    # the date the nightly checks hold the item to while it waits in the draft (SQL)
    queue = _deadline_cols(
        "private.pending_item_deadlines(%s)", "ledger_entry_id = %s", tenant["servicer"], item[0]
    )
    drafted = _deadline_cols(
        "private.remittance_draft_line", "run_id = %s and ledger_entry_id = %s", rerun, item[0]
    )
    with psycopg.connect(DB) as conn:
        terms = conn.execute(
            """select mandate_id, mandate_terms_id, commission_state
               from private.remittance_draft_line where run_id = %s and ledger_entry_id = %s""",
            (rerun, item[0]),
        ).fetchone()
        late_day = conn.execute(
            "select private.next_business_day(%s)", (original[2] + timedelta(days=1),)
        ).fetchone()
    assert late_day is not None
    head = run_row(rerun)
    refused = approve(tenant, rerun, day=late_day[0])
    reason = "Nouvel IBAN du client confirmé après le retour du virement"
    queued = approve(tenant, rerun, day=late_day[0], late_reason=reason)
    drain_remittances()
    with psycopg.connect(DB) as conn:
        late = conn.execute(
            """select ledger_entry_id, latest_execution_date, requested_execution_date, late_reason
               from public.remittance_late_approval where run_id = %s""",
            (rerun,),
        ).fetchall()
        breach = conn.execute(
            """select run_id, deadline, latest_execution_date, requested_execution_date,
                      late_reason, blocked_reason
               from public.remittance_deadline_breach where ledger_entry_id = %s""",
            (item[0],),
        ).fetchall()
    return {
        "tenant": tenant,
        "rerun": rerun,
        "item": str(item[0]),
        "amount": int(item[1]),
        "original": original,
        "held_terms": held[1],
        "queue": queue,
        "drafted": drafted,
        "terms": terms,
        "head": head,
        "late_day": late_day[0],
        "refused": refused,
        "queued": queued,
        "reason": reason,
        "late": late,
        "breach": breach,
    }


def test_a_returned_payout_re_proposed_keeps_its_r124_6_date(re_proposed: dict[str, Any]) -> None:
    """K2: the re-proposed item's line carries the original line's E and dates (the same as the
    SQL queue holds it to while it waits: parity of load_facts/prepare_run with
    private.pending_item_deadlines), stays uncommissioned and outside every mandate; the run's
    header counts it, so an approval after that date needs the late reason (late_reason_required)
    and, with one, writes the late-approval row and the item's breach row."""
    x = re_proposed
    assert x["drafted"] == x["original"] == x["queue"]  # (E, deadline, latest, unmeetable)
    assert x["terms"] == (None, x["held_terms"], "none")
    assert x["head"]["earliest_latest_execution_date"] == x["original"][2]
    assert x["head"]["earliest_deadline"] == x["original"][1]
    assert x["late_day"] > x["original"][2]
    (one,) = x["refused"]["results"]
    assert (one["status"], one["reason"]) == ("refused", "late_reason_required")
    (ok,) = x["queued"]["results"]
    assert (ok["status"], ok["reason"]) == ("queued", None)
    run = run_row(x["rerun"])
    assert run["status"] == "approved" and run["late_reason"] == x["reason"]
    assert run["requested_execution_date"] == x["late_day"]
    item, latest = x["item"], x["original"][2]
    assert [(str(a), b, c, d) for a, b, c, d in x["late"]] == [
        (item, latest, x["late_day"], x["reason"])
    ]
    assert [(str(r[0]), r[1], r[2], r[3], r[4]) for r in x["breach"]] == [
        (x["rerun"], x["original"][1], latest, x["late_day"], x["reason"])
    ]
    with psycopg.connect(DB) as conn:  # frozen as drafted
        line = conn.execute(
            """select encaissement_date, deadline, latest_execution_date, unmeetable
               from public.remittance_line where run_id = %s and ledger_entry_id = %s""",
            (x["rerun"], item),
        ).fetchone()
    assert line is not None and tuple(line) == x["original"]


def test_a_returned_payout_s_breach_row_says_why_it_was_held(re_proposed: dict[str, Any]) -> None:
    """K2 (Q7): the breach row of a payout_returned line says it was held by the return."""
    assert [r[5] for r in re_proposed["breach"]] == ["payout_returned"]


# -- a return dated before its debit (K5; review T4) --------------------------------------------


def test_a_return_dated_before_its_debit_is_left_to_ops(tmp_path: Path) -> None:
    """K5: the job reads each returned transfer's debit date (the date of the entry its debit
    booked, as private.post_bank_bookings does) and a return dated before it is reviewed
    `return_before_debit`, never booked: on the statement that carries both (the return, decided
    first by its date, finds the transfer not booked yet), and on a later pass, once the debit is
    booked."""
    tenant, _other, r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    day = paris_today()
    e2e = _run_transfer(r1)["end_to_end_id"]
    sid = _bank(tenant, data, booking_date=day, returns=[e2e], return_date=day - timedelta(days=1))
    assert [k for k, _, _ in _bookings(sid)] == ["payout", "payout"]
    assert _reviews(sid) == ["return_before_debit"]
    assert _transfer(e2e)["status"] == "booked"
    org = tenant["servicer"]
    with psycopg.connect(DB) as conn, conn.cursor(row_factory=dict_row) as cur:
        rows = cur.execute(
            "select * from private.bank_booking_candidates(%s, null, null, 100)", (org,)
        ).fetchall()
        debit_dates(conn, rows)
    (back,) = [x for x in funds_lines(rows) if x.kind == "return"]
    assert [(f.role, f.debit_date) for f in back.facts] == [("return", day)]
    with psycopg.connect(DB) as conn, conn.transaction():  # the next statement's pass
        run_process_debits(conn, {"organization_id": org, "funds_after": None})
    assert [k for k, _, _ in _bookings(sid)] == ["payout", "payout"]
    assert _reviews(sid) == ["return_before_debit"]
    assert _transfer(e2e)["status"] == "booked"
