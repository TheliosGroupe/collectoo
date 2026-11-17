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
* concurrency (plan §2.5 [critic], §4.3): the job's first message and a command holding a run's
  row (its cancellation, its file's re-download), the paying account (a file's generation) or the
  payment of a single-refund batch line (a refund of the rest) never deadlock: the funds pass runs
  in its own transaction (staged on three sessions); the funds pass and a refund holding a late
  line's payment never deadlock (concurrency-2); the funds pass waits for the allocation lock
  holding only what comes before it in ADR-0014's order;
* a returned payout re-proposed keeps its R124-6 date (K2); a return dated before its debit is
  left to ops (K5).
"""

from __future__ import annotations

import hashlib
import random
import threading
import time
import uuid
from collections.abc import Callable
from datetime import date, timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from allocation_helpers import credit as bank_credit
from allocation_helpers import state, statement
from debit_helpers import checks, import_entries, refund_request, return_entry, violations
from integration_helpers import DB, as_user, storage
from psycopg.rows import dict_row
from remittance_helpers import (
    approve,
    confirm_payout,
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
from test_transfer_files_integration import (
    _bytes,
    _file,
    _file_row,
    _generate,
    _own_account,
    _two_runs,
)

from collectoo_worker.jobs.debits import debit_dates, funds_lines, run_process_debits
from collectoo_worker.remittance import pain001
from collectoo_worker.synth.camt053 import (
    FEE_CODE,
    Entry,
    Tx,
    debits_of,
    make_doc,
    render_camt053,
)
from collectoo_worker.synth.ids import iban_fr
from collectoo_worker.synth.reconciliation import credit_entries

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

# the sessions of these tests report a deadlock after DEADLOCK_TIMEOUT (the server's check), well
# under every command's own lock_timeout (2 s or 5 s): a command that times out on a lock
# (55P03) waited for a slow job, never in a cycle — it is retried, a deadlock (40P01) never is
# (review round 2: the 5 s timeouts under CI load)
DEADLOCK_TIMEOUT_MS = 100
COMMANDS = {
    "cancel": "public.cancel_remittance_run(text,uuid,integer,text)",
    "download": "public.transfer_file_download(uuid,text,boolean)",
    "generate": "public.generate_transfer_file(text,uuid,text)",
    "refund": "public.request_refund(text,uuid,text,text,text,text,text,text,text,text)",
}
# what the other side may answer, by SQLSTATE and message: it holds a run's row (or a payment's),
# then waits for the allocation lock; refused under them (the switch off: a downloaded file's
# payout is not cancelled, an executed file is not downloaded again), or done
REFUSALS = {
    "cancel": ("23514", "remittance run refused: payout_in_downloaded_file"),
    "download": ("23514", "transfer file refused: file_executed"),
}
# a retry after a lock timeout may come once the funds pass has booked the run
LATER_REFUSALS = {
    "cancel": ("23514", "remittance run refused: not_cancellable"),
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


def _waits(pid: int, event: str | None = "advisory", timeout_s: float = 15.0) -> bool:
    """True once the session waits on a heavyweight lock (`event`: an advisory lock — the
    allocation lock —, or any when None: a row's)."""
    with psycopg.connect(DB, autocommit=True) as conn:
        end = time.monotonic() + timeout_s
        while time.monotonic() < end:
            row = conn.execute(
                "select wait_event_type, wait_event from pg_stat_activity where pid = %s", (pid,)
            ).fetchone()
            if row is not None and row[0] == "Lock" and (event is None or row[1] == event):
                return True
            time.sleep(0.02)
    return False


def _session() -> psycopg.Connection[Any]:
    """A session that reports a deadlock after DEADLOCK_TIMEOUT_MS (autocommit: each
    `transaction()` block is one transaction)."""
    conn = psycopg.connect(DB, autocommit=True)
    conn.execute(f"set deadlock_timeout = '{DEADLOCK_TIMEOUT_MS}ms'")
    return conn


def _lock_timeout_ms(function: str) -> int:
    """The lock_timeout a command sets for itself (its function's SET clause)."""
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select (select c from unnest(p.proconfig) c where c like 'lock_timeout=%%')
               from pg_proc p where p.oid = %s::regprocedure""",
            (function,),
        ).fetchone()
    assert row is not None and row[0] is not None, function
    value = str(row[0]).split("=", 1)[1]
    assert value.endswith("s") and not value.endswith("ms"), value
    return int(value[:-1]) * 1000


def _retried(
    run: Callable[[], None], refusal: tuple[str, str] | None, later: tuple[str, str] | None
) -> tuple[str, int]:
    """The command, retried after a lock timeout (55P03); its outcome (`done`, or `refused` with
    the expected refusal — or, on a retry, the one it gets once the run is booked) and the number of
    timeouts. Anything else, a deadlock (40P01) included, is raised."""
    timeouts = 0
    while True:
        try:
            run()
        except psycopg.errors.LockNotAvailable:
            timeouts += 1
            if timeouts == 5:
                raise
            continue
        except psycopg.Error as exc:
            got = (exc.sqlstate, exc.diag.message_primary)
            if got == refusal or (timeouts > 0 and got == later):
                return "refused", timeouts
            raise
        return "done", timeouts


def _unidentified(tenant: dict[str, Any], amount: int) -> str:
    """A credit naming nothing (no reference) on the account's next statement (opened with the
    last one's closing: the files' cash check reads it): an unmatched payment ops may refund."""
    opening, last = _last_closing(tenant)
    day = max(paris_today(), last)
    prefix = f"U{uuid.uuid4().hex[:6].upper()}"
    entries = credit_entries([bank_credit(amount)], start=day, days=1, prefix=prefix)
    doc = make_doc(entries, iban=tenant["iban"], from_date=day, to_date=day,
                   opening_minor=opening, stmt_id=f"S-{prefix}")  # fmt: skip
    target = upload(tenant, storage(), render_camt053(doc, "08"), name=f"{prefix}.xml")
    drain_payments(storage())
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select p.id::text from public.payment p
               join public.bank_transaction t on t.id = p.bank_transaction_id
               where t.statement_id = %s""",
            (target["statement_id"],),
        ).fetchone()
    assert row is not None
    return str(row[0])


def _refund_args(payment: str, amount: int) -> tuple[Any, ...]:
    """request_refund's arguments as the page sends them (the payment's reason and what is left),
    in the next file, to a synthetic IBAN."""
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select p.review_reason, x.unallocated_minor::text
               from public.payment p cross join lateral private.payment_positions(array[p.id]) x
               where p.id = %s""",
            (payment,),
        ).fetchone()
    assert row is not None
    return (str(uuid.uuid4()), payment, str(amount), iban_fr(random.Random(payment)), "PAYEUR",
            "other", row[0], row[1], "remboursement au payeur", "file")  # fmt: skip


REQUEST_REFUND = "select public.request_refund(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)"


@pytest.mark.parametrize("other", ["cancel", "download", "generate", "refund"])
def test_the_funds_pass_and_a_command_holding_the_run_never_deadlock(  # noqa: PLR0915
    tmp_path: Path, other: str
) -> None:
    """Plan §2.5 [critic], §4.3: a command holds a run's row (cancel_remittance_run,
    transfer_file_download), the paying account's (generate_transfer_file) or the payment of the
    single-refund batch line the M2b pass links (request_refund), then waits for the allocation
    lock; the job's first message (the M2b pass: a payer's return or that refund on the statement
    takes the allocation lock) must not then wait for what the command holds. Staged on three
    sessions: one holds the allocation lock; the job's first message queues on it; the command
    queues behind the job; the lock is released. The M2b pass commits without the funds pass, the
    command gets the lock (refused, or done), the funds message (the queue's, in its own
    transaction) books each payout once. With the funds pass in the M2b pass's transaction (mutant
    MERGED) the job would hold the allocation lock while it waits for the command's run row: a
    deadlock (cancel, download), or the job's outcome `job:with_funds` (each)."""
    tenant, _client, r1, r2 = _two_runs()
    refund: dict[str, Any] = {}
    if other == "refund":  # a refund of 50,00 € in the file: its PmtInf one refund alone
        refund["payment"] = _unidentified(tenant, 10_000)
        refund["prior"] = state(refund["payment"])[1]
        refund["first"] = refund_request(tenant, refund["payment"], 5_000, "unidentified")
    f, data = _downloaded(tenant, tmp_path)
    if other == "generate":  # a refund ordered after the download: the next file's
        refund["payment"] = _unidentified(tenant, 10_000)
        refund["first"] = refund_request(tenant, refund["payment"], 5_000, "unidentified")
    opening, last = _last_closing(tenant)
    day = max(paris_today(), last)
    ref = f"C{uuid.uuid4().hex[:6].upper()}"
    mode = "batch" if other == "refund" else "individual"
    entries = [
        *debits_of(pain001.read(data), booking_date=day, ref_prefix=ref, mode=mode),
        # a payer's return (a line of the M2b pass: it takes the allocation lock)
        return_entry(5_000, f"E2E{uuid.uuid4().hex[:12].upper()}", f"{ref}R", day),
    ]
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(entries, iban=tenant["iban"], from_date=day, to_date=day,
                   opening_minor=opening, stmt_id=stmt)  # fmt: skip
    _import_only(render_camt053(doc, "08"), tenant, f"{stmt}.xml")
    assert run_row(r1)["status"] == "sent"  # its debit is not booked yet
    assert _lock_timeout_ms(COMMANDS[other]) > DEADLOCK_TIMEOUT_MS
    org = str(tenant["servicer"])
    version = run_row(r1)["version"]
    pids: dict[str, int] = {}
    errors: list[BaseException] = []
    outcome: list[str] = []
    timeouts: list[int] = []
    go = threading.Event()

    def job() -> None:
        try:
            with _session() as conn:
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
        try:
            with _session() as conn:
                pids["other"] = conn.info.backend_pid
                go.wait(30)
                # once its batch line executed the first refund: the payment as it was, 50,00 € left
                args = (str(uuid.uuid4()), refund.get("payment"), "5000",
                        iban_fr(random.Random(refund.get("payment"))), "PAYEUR", "other",
                        refund.get("prior"), "5000", "remboursement au payeur", "file")  # fmt: skip

                def run() -> None:
                    with conn.transaction():
                        as_user(conn, tenant["staff"] if other == "refund" else tenant["admin"],
                                "aal2")  # fmt: skip
                        conn.execute("set local statement_timeout = '60s'")
                        if other == "cancel":
                            conn.execute(
                                "select public.cancel_remittance_run(%s, %s, %s, %s)",
                                (str(uuid.uuid4()), r1, version, "test de concurrence"),
                            )
                        elif other == "download":  # a re-download, acknowledged
                            conn.execute(
                                "select public.transfer_file_download(%s, %s, true)",
                                (f["id"], hashlib.sha256(data).hexdigest()),
                            )
                        elif other == "generate":
                            conn.execute(
                                "select public.generate_transfer_file(%s, %s, null)",
                                (str(uuid.uuid4()), tenant["bank"]),
                            )
                        else:  # the rest of the payment the single-refund line executes
                            conn.execute(REQUEST_REFUND, args)

                done, n = _retried(run, REFUSALS.get(other), LATER_REFUSALS.get(other))
                timeouts.append(n)
            outcome.append(f"{other}:{done}")
        except BaseException as exc:  # a deadlock included: fails the test
            errors.append(exc)

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
        assert _waits(pids["job"]), "the job's first message never queued"
        go.set()
        # the refund waits for its payment's row, which the job's M2b pass holds
        assert _waits(pids["other"], None if other == "refund" else "advisory"), (
            "the command never queued behind it"
        )
    a.join(120)
    b.join(120)
    assert not a.is_alive() and not b.is_alive()
    deadlocks = [e for e in errors if isinstance(e, psycopg.errors.DeadlockDetected)]
    assert deadlocks == [], deadlocks
    if errors:
        raise errors[0]
    done = "done" if other in ("generate", "refund") else "refused"
    assert sorted(outcome) == sorted(["job:m2b", f"{other}:{done}"]), (outcome, timeouts)
    drain_payments(storage())
    with psycopg.connect(DB) as conn:
        booked = conn.execute(
            """select t.run_id::text, count(b.bank_transaction_id) from public.bank_transfer t
               left join public.bank_line_booking b on b.transfer_id = t.id and b.kind = 'payout'
               where t.run_id = any(%s::uuid[]) and t.kind = 'payout' group by t.run_id""",
            ([r1, r2],),
        ).fetchall()
        refunds = conn.execute(
            """select q.status, t.status, coalesce(f.download_count, -1)
               from public.refund_request q
               join public.bank_transfer t on t.id = q.transfer_id
               left join public.transfer_file f on f.id = t.transfer_file_id
               where q.payment_id = %s order by q.requested_at""",
            (refund.get("payment"),),
        ).fetchall()
    assert dict(booked) == {r1: 1, r2: 1}  # each payout booked once (I20)
    assert run_row(r1)["status"] == run_row(r2)["status"] == "booked"
    if other == "refund":  # executed by its batch line; the rest asked for the next file
        assert [tuple(r) for r in refunds] == [
            ("executed", "booked", 1),
            ("requested", "ordered", -1),
        ]
    if other == "generate":  # the refund in the new file, not downloaded yet
        assert [tuple(r) for r in refunds] == [("requested", "in_file", 0)]
    _no_violation(tenant)


# -- concurrency-2: the payments of late lines locked before the allocation lock -----------------


@pytest.fixture
def late_run(tmp_path: Path) -> dict[str, Any]:
    """Martin's payout of 1 640,00 € in a downloaded file, approved on time while its line's
    latest execution date (set in the draft before approval: the header, which the approval reads,
    keeps the later one) is yesterday: debited today, it is late and its breach row is written at
    the booking — the foreign key key-share locks its payment. That payment (2 100,00 € paid on a
    file of 2 000,00 €) keeps 100,00 € of overpayment ops may refund. Its debit is on a statement
    imported, the job's message taken off unrun."""
    tenant = remittance_tenant()
    _own_account(tenant)
    f1 = _file(tenant, 200_000)
    ids = statement(tenant, storage(), [bank_credit(210_000, rf=f1.rf)],
                    f"L{uuid.uuid4().hex[:6].upper()}", recent_business_day())  # fmt: skip
    payment = next(iter(ids.values()))
    run = request_run(tenant)
    with psycopg.connect(DB) as conn, conn.transaction():
        yesterday = conn.execute(
            "select max(c.day) from public.business_calendar c "
            "where c.scope = 'FR-conservative' and not c.closed and c.day < %s",
            (paris_today(),),
        ).fetchone()
        assert yesterday is not None
        conn.execute(
            "update private.remittance_draft_line set latest_execution_date = %s where run_id = %s",
            (yesterday[0], run),
        )
    approve(tenant, run)
    drain_remittances()
    assert run_row(run)["status"] == "approved"
    f, data = _downloaded(tenant, tmp_path)
    opening, last = _last_closing(tenant)
    day = max(paris_today(), last)
    assert day > yesterday[0]
    entries = debits_of(pain001.read(data), booking_date=day, ref_prefix=f"K{uuid.uuid4().hex[:5]}")
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(entries, iban=tenant["iban"], from_date=day, to_date=day,
                   opening_minor=opening, stmt_id=stmt)  # fmt: skip
    _import_only(render_camt053(doc, "08"), tenant, f"{stmt}.xml")
    t = _run_transfer(run)
    with psycopg.connect(DB) as conn:
        line = conn.execute(
            "select id from public.bank_transaction where end_to_end_id = %s", (t["end_to_end_id"],)
        ).fetchone()
        late = conn.execute(
            "select payment_id::text from public.remittance_line where run_id = %s "
            "and latest_execution_date < %s",
            (run, day),
        ).fetchall()
    assert line is not None and [r[0] for r in late] == [payment]
    return {"tenant": tenant, "run": run, "payment": payment, "file": f, "transfer": t,
            "line": str(line[0]), "org": str(tenant["servicer"])}  # fmt: skip


def _funds_pass(org: str, pids: dict[str, int], errors: list[BaseException]) -> None:
    """The debit job's funds message (its own transaction), in a session that reports a deadlock
    after DEADLOCK_TIMEOUT_MS."""
    try:
        with _session() as conn:
            pids["funds"] = conn.info.backend_pid
            with conn.transaction():
                run_process_debits(conn, {"organization_id": org, "funds_after": None})
    except BaseException as exc:  # asserted by the tests
        errors.append(exc)


def test_the_funds_pass_and_a_command_holding_a_late_line_s_payment_never_deadlock(  # noqa: PLR0915
    late_run: dict[str, Any],
) -> None:
    """Review concurrency-2: the funds pass books a late payout; its breach row's foreign key
    key-share locks the late line's payment. request_refund (file mode) holds that payment FOR
    UPDATE, then waits for the allocation lock. The funds pass takes that key-share lock before the
    allocation lock (private.post_bank_bookings, in id order), so it never waits for the payment
    while holding the allocation lock. Staged: a third session holds the allocation lock; the funds
    pass queues on it (holding the payment's key share); the refund then waits for the payment; the
    lock is released: the funds pass books, the refund follows. Mutants: the key-share statement
    deleted, or moved after the allocation lock — the refund takes the payment first and queues
    behind the funds pass, which then waits for the payment under the allocation lock: a
    deadlock (40P01)."""
    x = late_run
    assert _lock_timeout_ms(COMMANDS["refund"]) > DEADLOCK_TIMEOUT_MS
    args = _refund_args(x["payment"], 10_000)
    pids: dict[str, int] = {}
    errors: list[BaseException] = []
    outcome: list[str] = []
    timeouts: list[int] = []

    def refund() -> None:
        try:
            with _session() as conn:
                pids["refund"] = conn.info.backend_pid

                def run() -> None:
                    with conn.transaction():
                        as_user(conn, x["tenant"]["staff"], "aal2")
                        conn.execute("set local statement_timeout = '60s'")
                        conn.execute(REQUEST_REFUND, args)

                done, n = _retried(run, None, None)
                timeouts.append(n)
                outcome.append(f"refund:{done}")
        except BaseException as exc:  # a deadlock included: fails the test
            errors.append(exc)

    funds = threading.Thread(target=_funds_pass, args=(x["org"], pids, errors))
    command = threading.Thread(target=refund)
    with psycopg.connect(DB) as holder, holder.transaction():
        holder.execute("select pg_advisory_xact_lock(hashtext('payments:' || %s))", (x["org"],))
        funds.start()
        for _ in range(1500):
            if "funds" in pids:
                break
            time.sleep(0.01)
        assert _waits(pids["funds"]), "the funds pass never queued on the allocation lock"
        command.start()
        for _ in range(1500):
            if "refund" in pids:
                break
            time.sleep(0.01)
        assert _waits(pids["refund"], None), "the refund never waited"
    funds.join(120)
    command.join(120)
    assert not funds.is_alive() and not command.is_alive()
    deadlocks = [e for e in errors if isinstance(e, psycopg.errors.DeadlockDetected)]
    assert deadlocks == [], deadlocks
    if errors:
        raise errors[0]
    assert outcome == ["refund:done"], (outcome, timeouts)
    with psycopg.connect(DB) as conn:
        booked = conn.execute(
            "select count(*) from public.bank_line_booking where bank_transaction_id = %s",
            (x["line"],),
        ).fetchone()
        breach = conn.execute(
            "select payment_id::text from public.remittance_deadline_breach where run_id = %s",
            (x["run"],),
        ).fetchall()
        asked = conn.execute(
            "select status, execution_mode from public.refund_request where payment_id = %s",
            (x["payment"],),
        ).fetchall()
    assert booked is not None and booked[0] == 1
    assert run_row(x["run"])["status"] == "booked"
    assert [r[0] for r in breach] == [x["payment"]]  # the late line's, at the booking
    assert [tuple(r) for r in asked] == [("requested", "file")]
    _no_violation(x["tenant"])


def test_the_job_and_a_refund_holding_a_late_line_s_payment_never_deadlock(  # noqa: PLR0915
    late_run: dict[str, Any],
) -> None:
    """Plan §4.3, the harness above with the job's first message (a payer's return on the
    statement: its M2b pass takes the allocation lock first): request_refund holds the late
    line's payment, then queues behind the job on the allocation lock. The M2b pass commits
    without the funds pass; the refund gets the lock; the funds message then key-shares the
    payment and books the late payout. With the funds pass in the M2b pass's transaction — even
    silent, its summary unchanged (mutant MERGED B) — it would wait for that payment under the
    allocation lock the refund waits for: a deadlock (the key-share lock before the allocation
    lock cannot help once the M2b pass holds it)."""
    x = late_run
    org = x["org"]
    opening, last = _last_closing(x["tenant"])
    day = max(paris_today(), last)
    ref = f"P{uuid.uuid4().hex[:6].upper()}"
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc([return_entry(5_000, f"E2E{uuid.uuid4().hex[:12].upper()}", f"{ref}R", day)],
                   iban=x["tenant"]["iban"], from_date=day, to_date=day, opening_minor=opening,
                   stmt_id=stmt)  # fmt: skip
    _import_only(render_camt053(doc, "08"), x["tenant"], f"{stmt}.xml")
    args = _refund_args(x["payment"], 10_000)
    pids: dict[str, int] = {}
    errors: list[BaseException] = []
    outcome: list[str] = []
    timeouts: list[int] = []
    go = threading.Event()

    def job() -> None:
        try:
            with _session() as conn:
                pids["job"] = conn.info.backend_pid
                with conn.transaction():  # the job's first message (the queue's transaction)
                    summary = run_process_debits(
                        conn, {"type": "process_debits", "organization_id": org}
                    )
                outcome.append("job:with_funds" if "funds" in summary else "job:m2b")
            drain_payments(storage())  # then the funds message it queued, in its own
        except BaseException as exc:  # asserted below
            errors.append(exc)

    def refund() -> None:
        try:
            with _session() as conn:
                pids["refund"] = conn.info.backend_pid
                go.wait(30)

                def run() -> None:
                    with conn.transaction():
                        as_user(conn, x["tenant"]["staff"], "aal2")
                        conn.execute("set local statement_timeout = '60s'")
                        conn.execute(REQUEST_REFUND, args)

                done, n = _retried(run, None, None)
                timeouts.append(n)
                outcome.append(f"refund:{done}")
        except BaseException as exc:  # a deadlock included: fails the test
            errors.append(exc)

    a, b = threading.Thread(target=job), threading.Thread(target=refund)
    with psycopg.connect(DB) as holder, holder.transaction():
        holder.execute("select pg_advisory_xact_lock(hashtext('payments:' || %s))", (org,))
        a.start()
        b.start()
        for _ in range(1500):
            if "job" in pids and "refund" in pids:
                break
            time.sleep(0.01)
        assert _waits(pids["job"]), "the job's first message never queued"
        go.set()
        assert _waits(pids["refund"]), "the refund never queued behind it, holding the payment"
    a.join(120)
    b.join(120)
    assert not a.is_alive() and not b.is_alive()
    deadlocks = [e for e in errors if isinstance(e, psycopg.errors.DeadlockDetected)]
    assert deadlocks == [], deadlocks
    if errors:
        raise errors[0]
    assert sorted(outcome) == ["job:m2b", "refund:done"], (outcome, timeouts)
    drain_payments(storage())
    with psycopg.connect(DB) as conn:
        breach = conn.execute(
            "select payment_id::text from public.remittance_deadline_breach where run_id = %s",
            (x["run"],),
        ).fetchall()
    assert run_row(x["run"])["status"] == "booked"
    assert [r[0] for r in breach] == [x["payment"]]
    _no_violation(x["tenant"])


def _nowait(sql: str, *params: Any) -> bool:
    """Whether a session gets the lock at once (each statement its own transaction)."""
    with psycopg.connect(DB, autocommit=True) as conn:
        try:
            row = conn.execute(sql, params).fetchone()
        except psycopg.errors.LockNotAvailable:
            return False
    return row is None or row[0] is not False


def test_the_funds_pass_waits_for_the_allocation_lock_holding_only_what_comes_before_it(
    late_run: dict[str, Any],
) -> None:
    """Plan §4.3 (035's « a second session holding the allocation lock »; review round 2: a
    pgTAP test cannot stage it, its own transaction holds that lock from its fixtures and a dblink
    session cannot see them): while another session holds the allocation lock, the funds pass
    waits for it holding the run's row (FOR UPDATE), the paying account (FOR SHARE) and the late
    line's payment (FOR KEY SHARE: concurrency-2), and not yet the line, the remit lock, the file or
    the transfer — ADR-0014's order (runs → payout accounts → bank accounts → payments →
    `payments:<org>` → lines → `remit:<org>` → files → transfers). Released, it books."""
    x = late_run
    t = x["transfer"]
    pids: dict[str, int] = {}
    errors: list[BaseException] = []
    funds = threading.Thread(target=_funds_pass, args=(x["org"], pids, errors))
    with psycopg.connect(DB) as holder, holder.transaction():
        holder.execute("select pg_advisory_xact_lock(hashtext('payments:' || %s))", (x["org"],))
        funds.start()
        for _ in range(1500):
            if "funds" in pids:
                break
            time.sleep(0.01)
        assert _waits(pids["funds"]), "the funds pass never queued on the allocation lock"
        held = {
            "run": not _nowait(
                "select true from public.remittance_run where id = %s for update nowait", x["run"]
            ),
            "bank_account": not _nowait(
                "select true from public.bank_account where id = %s for update nowait",
                x["tenant"]["bank"],
            ),
            "payment": not _nowait(
                "select true from public.payment where id = %s for update nowait", x["payment"]
            ),
            "line": not _nowait(
                "select true from public.bank_transaction where id = %s for update nowait",
                x["line"],
            ),
            "remit": not _nowait(
                "select pg_try_advisory_xact_lock(hashtext('remit:' || %s))", x["org"]
            ),
            "file": not _nowait(
                "select true from public.transfer_file where id = %s for update nowait",
                x["file"]["id"],
            ),
            "transfer": not _nowait(
                "select true from public.bank_transfer where id = %s for update nowait", t["id"]
            ),
        }
    funds.join(120)
    assert not funds.is_alive()
    if errors:
        raise errors[0]
    assert held == {"run": True, "bank_account": True, "payment": True, "line": False,
                    "remit": False, "file": False, "transfer": False}  # fmt: skip
    assert run_row(x["run"])["status"] == "booked"


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


# -- review round 4 (N1): our payout coming back unflagged ----------------------------------------


def _back(tenant: dict[str, Any], credits: list[tuple[str, int]], day: date) -> str:
    """A statement of credits carrying our payouts' RMT ids with no return code, reason or
    reversal (an ordinary SEPA credit's code: the bank did not flag them as returns), imported and
    drained."""
    opening, _last = _last_closing(tenant)
    tag = uuid.uuid4().hex[:6].upper()
    entries = [
        Entry(
            n,
            True,
            day,
            day,
            ref=f"NB{tag}{i}",
            code="PMNT/RCDT/ESCT",
            txs=(Tx(n, ref=f"B{tag}{i}", end_to_end_id=e2e, name="LILAS FINANCE"),),
        )
        for i, (e2e, n) in enumerate(credits, start=1)
    ]
    return import_entries(tenant, storage(), entries, day=day, opening=opening)


def _payments_of(statement_id: str) -> int:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select count(*) from public.payment p
               join public.bank_transaction t on t.id = p.bank_transaction_id
               where t.statement_id = %s""",
            (statement_id,),
        ).fetchone()
    assert row is not None
    return int(row[0])


def test_our_payout_back_unflagged_is_its_return_once_and_never_before_its_debit(
    tmp_path: Path,
) -> None:
    """N1: the import reads a credit carrying our payout's RMT id as a `return` even when the bank
    does not flag it (before: `debtor_credit`, an unmatched payment of our own money). The funds
    pass then books the payout's return when its debit is booked (`payout_returned`, the transfer
    `returned`); never for a payout still in its file (debit not booked: `return_before_debit`,
    nothing booked); and never twice (a second such credit: `return_differs`, nothing booked). No
    payment is made of any of them."""
    tenant, _other, _r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    (first, n1), (second, n2) = _payouts(data)
    day = max(paris_today(), _last_closing(tenant)[1])
    # the first payout's debit alone (by its RMT id): booked; the second stays in its file
    opening, _last = _last_closing(tenant)
    debit = Entry(
        n1,
        False,
        day,
        day,
        ref=f"ND{uuid.uuid4().hex[:6].upper()}",
        code="PMNT/ICDT/ESCT",
        txs=(Tx(n1, ref=f"D{uuid.uuid4().hex[:6].upper()}", end_to_end_id=first, name="X"),),
    )
    sid0 = import_entries(tenant, storage(), [debit], day=day, opening=opening)
    assert _bookings(sid0) == [("payout", first, n1)]
    assert (_transfer(first)["status"], _transfer(second)["status"]) == ("booked", "in_file")
    # both come back, unflagged
    sid = _back(tenant, [(first, n1), (second, n2)], day)
    with psycopg.connect(DB) as conn:
        kinds = conn.execute(
            """select kind, original_end_to_end_id from public.bank_transaction
               where statement_id = %s order by line_no""",
            (sid,),
        ).fetchall()
    assert [tuple(k) for k in kinds] == [("return", first), ("return", second)]
    assert _payments_of(sid) == 0
    assert _bookings(sid) == [("payout_returned", first, n1)]
    assert _reviews(sid) == ["return_before_debit"]
    assert (_transfer(first)["status"], _transfer(second)["status"]) == ("returned", "in_file")
    # the first one again: never a second return
    sid2 = _back(tenant, [(first, n1)], day)
    assert _payments_of(sid2) == 0
    assert _bookings(sid2) == []
    assert _reviews(sid2) == ["return_differs"]
    with psycopg.connect(DB) as conn:
        returned = conn.execute(
            """select count(*) from public.bank_line_booking b
               join public.bank_transfer t on t.id = b.transfer_id
               where t.end_to_end_id = %s and b.kind = 'payout_returned'""",
            (first,),
        ).fetchone()
    assert returned is not None and returned[0] == 1
    _no_violation(tenant)


def test_our_lot_and_an_unsplit_batch_back_unflagged_are_never_linked_nor_explained(
    tmp_path: Path,
) -> None:
    """Review round 5. A downloaded file of two payouts (one PmtInf), then, unflagged by the bank,
    a credit naming that lot with no end-to-end id and an unsplit credit batch (its count disagrees
    with its details) one of whose details carries the first payout's RMT id beside a debtor's.
    Both are `return` (round 4, N1); no payment. Q2: the batch keeps our RMT id as its original
    (before: no id at all). Q3: the M2b pass reviews the lot's credit `no_candidate` (before: it
    never read it); the batch, carrying our RMT id, is the funds pass's (the payout still in its
    file: `return_before_debit`, nothing booked). Q1: neither takes « Classer sans comptabiliser »
    (`own_transfer_line`), and debit_link_options lists nothing on either."""
    tenant, _other, _r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    (first, n1), (_second, _n2) = _payouts(data)
    lot = pain001.read(data).payment_infos[0].pmt_inf_id
    opening, last = _last_closing(tenant)
    day = max(paris_today(), last)
    tag = uuid.uuid4().hex[:6].upper()
    entries = [
        Entry(
            n1, True, day, day, ref=f"NL{tag}", payment_info_id=lot, txs=(Tx(n1, ref=f"L{tag}"),)
        ),
        Entry(
            n1 + 2_000,
            True,
            day,
            day,
            ref=f"NU{tag}",
            batch_count=3,
            txs=(
                Tx(2_000, ref=f"U1{tag}", end_to_end_id=f"E2E-{tag}", name="DURAND"),
                Tx(n1, ref=f"U2{tag}", end_to_end_id=first, name="LILAS FINANCE"),
            ),
        ),
    ]
    sid = import_entries(tenant, storage(), entries, day=day, opening=opening)
    with psycopg.connect(DB) as conn:
        lines = conn.execute(
            """select id, kind, end_to_end_id, original_end_to_end_id, payment_info_id,
                      private.names_our_transfer(end_to_end_id, original_end_to_end_id,
                                                 payment_info_id)
               from public.bank_transaction where statement_id = %s order by line_no""",
            (sid,),
        ).fetchall()
    assert [tuple(r[1:]) for r in lines] == [
        ("return", None, None, lot, True),
        ("return", None, first, None, True),
    ]
    assert _payments_of(sid) == 0
    assert _reviews(sid) == ["no_candidate", "return_before_debit"]
    assert _bookings(sid) == []
    for line in (str(r[0]) for r in lines):
        options = staff(tenant, "select public.debit_link_options(%s)", line)
        assert (options["payments"], options["refunds"]) == ([], [])
        with pytest.raises(psycopg.errors.CheckViolation, match="own_transfer_line"):
            staff(
                tenant,
                "select public.link_debit(%s, %s, 'explained', null, null, null, 'vu')",
                str(uuid.uuid4()),
                line,
            )
    _no_violation(tenant)


# -- review round 6 (R1): an entry kept unsplit is never a partial return -------------------------


def _import_netted(
    tenant: dict[str, Any], entries: list[Entry], day: date, debit_refs: list[str]
) -> str:
    """A one-day camt.053 of these entries whose details named in `debit_refs` are debits (an
    entry the bank netted: its details cannot be split), imported; the payments queue drained."""
    opening, _last = _last_closing(tenant)
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        entries,
        iban=tenant["iban"],
        from_date=day,
        to_date=day,
        opening_minor=opening,
        stmt_id=stmt,
    )
    xml = render_camt053(doc, "08")
    for ref in debit_refs:
        at = xml.index(f"<AcctSvcrRef>{ref}</AcctSvcrRef>".encode())
        ind = xml.index(b"<CdtDbtInd>CRDT</CdtDbtInd>", at)
        xml = xml[:ind] + b"<CdtDbtInd>DBIT</CdtDbtInd>" + xml[ind + 27 :]
    target = upload(tenant, storage(), xml, name=f"{stmt}.xml")
    drain_payments(storage())
    return str(target["statement_id"])


def _fees(tenant: dict[str, Any]) -> int:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select coalesce(sum(p.amount_minor), 0) from public.ledger_posting p
               join public.ledger_account a on a.id = p.ledger_account_id
               join public.ledger_entry e on e.id = p.entry_id
               where e.organization_id = %s and a.book = 'bank_fees'""",
            (tenant["servicer"],),
        ).fetchone()
    assert row is not None
    return int(row[0])


def test_an_unsplit_entry_netting_our_return_is_never_booked_as_a_partial_return(
    tmp_path: Path,
) -> None:
    """R1 (round-5 verdict Q2, a regression of round 5): a downloaded file of two payouts, the
    larger one debited (booked). The bank then reports one credit entry it netted: the larger
    payout's return (its RMT id) beside the other payout's debit (its RMT id, a DBIT detail) — the
    entry is kept unsplit, its amount the difference. Round 5 read it as the larger payout's return
    of less than its amount and booked the rest as our bank fee: the other payout's debit hidden as
    the servicer's charge, that payout left in its file. Now the line records two details of ours
    and the funds pass reviews it `return_differs`, nothing booked (no payout_returned, no fee), the
    other payout untouched; the same with a chargeback's debit (one detail of ours). Round 7 (S1):
    the same payout's return alone in an entry kept unsplit (one detail shown of two: NbOfTxs 2),
    for its exact amount, is no longer booked either (round 6 booked it); alone in an entry whose
    one detail is the whole entry (no count), it is booked as its return."""
    tenant, _other, _r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    (big, n_big), (small, n_small) = sorted(_payouts(data), key=lambda p: -p[1])
    day = max(paris_today(), _last_closing(tenant)[1])
    opening, _last = _last_closing(tenant)
    tag = uuid.uuid4().hex[:6].upper()
    debit = Entry(
        n_big,
        False,
        day,
        day,
        ref=f"ND{tag}",
        code="PMNT/ICDT/ESCT",
        txs=(Tx(n_big, ref=f"D{tag}", end_to_end_id=big, name="LILAS FINANCE"),),
    )
    sid0 = import_entries(tenant, storage(), [debit], day=day, opening=opening)
    assert _bookings(sid0) == [("payout", big, n_big)]
    fees_before = _fees(tenant)
    chargeback = 30_000
    netted = [
        Entry(
            n_big - n_small,
            True,
            day,
            day,
            ref=f"NN{tag}",
            txs=(
                Tx(n_big, ref=f"N1{tag}", end_to_end_id=big, name="LILAS FINANCE"),
                Tx(n_small, ref=f"N2{tag}", end_to_end_id=small, name="MARTIN SAS"),
            ),
        ),
        Entry(
            n_big - chargeback,
            True,
            day,
            day,
            ref=f"NC{tag}",
            txs=(
                Tx(n_big, ref=f"C1{tag}", end_to_end_id=big, name="LILAS FINANCE"),
                Tx(chargeback, ref=f"C2{tag}", end_to_end_id=f"E2E-CB-{tag}", name="BANQUE"),
            ),
        ),
    ]
    sid = _import_netted(tenant, netted, day, [f"N2{tag}", f"C2{tag}"])
    with psycopg.connect(DB) as conn:
        lines = conn.execute(
            """select kind, amount_minor, end_to_end_id, original_end_to_end_id, unsplit_ours
               from public.bank_transaction where statement_id = %s order by line_no""",
            (sid,),
        ).fetchall()
    assert [tuple(r) for r in lines] == [
        ("return", n_big - n_small, None, big, 2),
        ("return", n_big - chargeback, None, big, 1),
    ]
    assert _payments_of(sid) == 0
    assert _bookings(sid) == []
    assert _reviews(sid) == ["return_differs", "return_differs"]
    assert (_transfer(big)["status"], _transfer(small)["status"]) == ("booked", "in_file")
    assert _fees(tenant) == fees_before  # no charge booked of the other payout's debit
    # the payout's return alone in an entry kept unsplit (one detail shown of two), its amount
    back = Entry(
        n_big,
        True,
        day,
        day,
        ref=f"NE{tag}",
        batch_count=2,
        txs=(Tx(n_big, ref=f"E1{tag}", end_to_end_id=big, name="LILAS FINANCE"),),
    )
    sid2 = _import_netted(tenant, [back], day, [])
    assert _bookings(sid2) == []
    assert _reviews(sid2) == ["return_differs"]
    assert (_transfer(big)["status"], _transfer(small)["status"]) == ("booked", "in_file")
    whole = Entry(
        n_big,
        True,
        day,
        day,
        ref=f"NW{tag}",
        txs=(Tx(n_big, ref=f"W1{tag}", end_to_end_id=big, name="LILAS FINANCE"),),
    )
    sid3 = _import_netted(tenant, [whole], day, [])
    assert _bookings(sid3) == [("payout_returned", big, n_big)]
    assert (_transfer(big)["status"], _transfer(small)["status"]) == ("returned", "in_file")
    assert _fees(tenant) == fees_before
    _no_violation(tenant)


# -- review round 7 (S1, S2): an entry kept unsplit holding our transfer is never booked ----------


def _flip(xml: bytes, refs: list[str]) -> bytes:
    """Each named detail's CdtDbtInd turned to the other direction (an entry the bank netted)."""
    for ref in refs:
        at = xml.index(f"<AcctSvcrRef>{ref}</AcctSvcrRef>".encode())
        end = xml.index(b"</TxDtls>", at)
        span = xml[at:end]
        flipped = (
            span.replace(b"<CdtDbtInd>CRDT</CdtDbtInd>", b"<CdtDbtInd>XXXX</CdtDbtInd>")
            .replace(b"<CdtDbtInd>DBIT</CdtDbtInd>", b"<CdtDbtInd>CRDT</CdtDbtInd>")
            .replace(b"<CdtDbtInd>XXXX</CdtDbtInd>", b"<CdtDbtInd>DBIT</CdtDbtInd>")
        )
        assert flipped != span
        xml = xml[:at] + flipped + xml[end:]
    return xml


def _import_turned(
    tenant: dict[str, Any], entries: list[Entry], day: date, turned: list[str]
) -> str:
    """A one-day camt.053 of these entries, the details named in `turned` of the other direction
    than their entry, imported; the payments queue drained (the M2b pass, then the funds pass)."""
    opening, _last = _last_closing(tenant)
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        entries, iban=tenant["iban"], from_date=day, to_date=day, opening_minor=opening,
        stmt_id=stmt,
    )  # fmt: skip
    xml = _flip(render_camt053(doc, "08"), turned)
    target = upload(tenant, storage(), xml, name=f"{stmt}.xml")
    drain_payments(storage())
    return str(target["statement_id"])


def test_an_unsplit_entry_holding_our_transfer_is_never_booked_nor_explained(
    tmp_path: Path,
) -> None:
    """Review round 7, through the real camt.053 import and the debit job. A downloaded file of
    two payouts and a refund; the larger payout debited (booked). The bank then reports, kept
    unsplit, the verifier's shapes (S1, verdict new:unsplit-exact-total-other-details), each for
    the booked payout's exact amount: u05 (its detail 50,00 € short beside a debtor's 50,00 €,
    NbOfTxs 3), u06 (the same with no detail amounts), u03 (its one detail 50,00 € short,
    NbOfTxs 2), u01 (its one detail exact, one shown of two), x01 (a debtor's credit of twice its
    amount and the payout's own DBIT detail), m04 (its return, a debtor's credit and our refund's
    debit netting to zero); and (S2, verdict new:debit-entry-unsplit-with-our-details-explainable)
    d01, an outgoing debit with the payout's return netted in. Round 6 booked the payout returned
    from the first of them (u05, u06, u03, u01, x01, m04: the debtor's money, a detail short or our
    payout's own debit taken as its return) and let ops explain d01 away. Now: no payment, nothing
    booked, the payout still booked, the other payout and the refund untouched, each line reviewed
    (return_differs; d01 batch_partial), no link nor explanation on any (own_transfer_line),
    debit_link_options lists nothing. x01 keeps no id of ours (its detail of ours is a debit), only
    its count. The payout's return as the whole of its entry is then booked."""
    tenant, _other, _r1, _r2 = _two_runs()
    payment = _unidentified(tenant, 10_000)
    staff(tenant, REQUEST_REFUND, *_refund_args(payment, 10_000))
    _f, data = _downloaded(tenant, tmp_path)
    paid = _payouts(data)
    (big, n_big), (small, _n_small) = sorted(
        ((e, n) for e, n in paid if e.startswith("RMT")), key=lambda p: -p[1]
    )
    ((rfd, n_rfd),) = [(e, n) for e, n in paid if e.startswith("RFD")]
    day = max(paris_today(), _last_closing(tenant)[1])
    opening, _last = _last_closing(tenant)
    tag = uuid.uuid4().hex[:6].upper()
    debit = Entry(
        n_big,
        False,
        day,
        day,
        ref=f"ND{tag}",
        code="PMNT/ICDT/ESCT",
        txs=(Tx(n_big, ref=f"D{tag}", end_to_end_id=big, name="LILAS FINANCE"),),
    )
    sid0 = import_entries(tenant, storage(), [debit], day=day, opening=opening)
    assert _bookings(sid0) == [("payout", big, n_big)]
    fees_before = _fees(tenant)

    def entry(ref: str, *txs: Tx, credit: bool = True, count: int | None = None) -> Entry:
        amount = n_big if credit else 500_000 - n_big
        code = "PMNT/RCDT/ESCT" if credit else "PMNT/ICDT/ESCT"
        return Entry(amount, credit, day, day, ref=f"{ref}{tag}", code=code, txs=txs,
                     batch_count=count)  # fmt: skip

    entries = [
        entry("U5", Tx(n_big - 5_000, ref=f"U5A{tag}", end_to_end_id=big),
              Tx(5_000, ref=f"U5B{tag}", end_to_end_id=f"E2E-U5-{tag}"), count=3),
        entry("U6", Tx(None, ref=f"U6A{tag}", end_to_end_id=big),
              Tx(None, ref=f"U6B{tag}", end_to_end_id=f"E2E-U6-{tag}")),
        entry("U3", Tx(n_big - 5_000, ref=f"U3A{tag}", end_to_end_id=big), count=2),
        entry("U1", Tx(n_big, ref=f"U1A{tag}", end_to_end_id=big), count=2),
        entry("X1", Tx(2 * n_big, ref=f"X1A{tag}", end_to_end_id=f"E2E-X1-{tag}"),
              Tx(n_big, ref=f"X1B{tag}", end_to_end_id=big)),
        entry("M4", Tx(n_big, ref=f"M4A{tag}", end_to_end_id=big),
              Tx(n_rfd, ref=f"M4B{tag}", end_to_end_id=f"E2E-M4-{tag}"),
              Tx(n_rfd, ref=f"M4C{tag}", end_to_end_id=rfd)),
        entry("D1", Tx(500_000, ref=f"D1A{tag}", end_to_end_id=f"E2E-OUT-{tag}"),
              Tx(n_big, ref=f"D1B{tag}", end_to_end_id=big), credit=False),
    ]  # fmt: skip
    sid = _import_turned(tenant, entries, day, [f"X1B{tag}", f"M4C{tag}", f"D1B{tag}"])
    with psycopg.connect(DB) as conn:
        lines = conn.execute(
            """select id, direction, kind, amount_minor, original_end_to_end_id, unsplit_ours
               from public.bank_transaction where statement_id = %s order by line_no""",
            (sid,),
        ).fetchall()
    assert [tuple(r[1:]) for r in lines] == [
        ("credit", "return", n_big, big, 1),  # u05
        ("credit", "return", n_big, big, 1),  # u06
        ("credit", "return", n_big, big, 1),  # u03
        ("credit", "return", n_big, big, 1),  # u01
        ("credit", "return", n_big, None, 1),  # x01: no id of ours kept, counted
        ("credit", "return", n_big, big, 1),  # m04
        ("debit", "batch_unsplit", 500_000 - n_big, None, 1),  # d01
    ]
    assert _payments_of(sid) == 0
    assert _bookings(sid) == []
    assert _reviews(sid) == [*["return_differs"] * 6, "batch_partial"]
    assert (_transfer(big)["status"], _transfer(small)["status"], _transfer(rfd)["status"]) == (
        "booked",
        "in_file",
        "in_file",
    )
    assert _fees(tenant) == fees_before
    for line in (str(r[0]) for r in lines):
        options = staff(tenant, "select public.debit_link_options(%s)", line)
        assert (options["payments"], options["refunds"]) == ([], [])
        with pytest.raises(psycopg.errors.CheckViolation, match="own_transfer_line"):
            staff(
                tenant,
                "select public.link_debit(%s, %s, 'explained', null, null, null, 'vu')",
                str(uuid.uuid4()),
                line,
            )
    # the payout's return as the whole of its entry: its return
    whole = entry("W1", Tx(n_big, ref=f"W1A{tag}", end_to_end_id=big))
    sid2 = _import_turned(tenant, [whole], day, [])
    assert _bookings(sid2) == [("payout_returned", big, n_big)]
    assert (_transfer(big)["status"], _transfer(small)["status"], _transfer(rfd)["status"]) == (
        "returned",
        "in_file",
        "in_file",
    )
    assert _fees(tenant) == fees_before
    _no_violation(tenant)


def test_an_own_credit_naming_our_lot_is_never_a_top_up_nor_relayed(tmp_path: Path) -> None:
    """Review round 7 (S3, verdict new:own-client-credit-naming-our-lot-relay-top-up), through the
    real camt.053 import and the debit job. A downloaded file of two payouts on the dedicated
    account; a top-up of 30,00 € ordered from the own account. A credit from the own account then
    carries the top-up's TOP id, for its amount, with the PmtInfId of that file's payouts lot (a lot
    of this dedicated account handed out: our outgoing transfer coming back, never a top-up — a
    top-up's lot would be a file of the own account). Round 6 booked it as the top-up (the job) and
    let ops relay it as a debtor's payment or book it. Now the job reviews it `top_up_differs`
    (it reads names_our_lot from private.bank_booking_candidates), nothing booked, the order still
    `ordered`; the relay and ops' top-up refused `own_transfer_line`. The same credit without the
    lot is the top-up."""
    tenant, _other, _r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    lot = pain001.read(data).payment_infos[0].pmt_inf_id
    with psycopg.connect(DB) as conn:  # the own account _two_runs registered
        row = conn.execute(
            """select a.id::text, a.iban from public.servicer_billing_settings s
               join public.bank_account a on a.id = s.own_bank_account_id
               where s.organization_id = %s""",
            (tenant["servicer"],),
        ).fetchone()
    assert row is not None
    own, own_iban = str(row[0]), str(row[1])
    top = staff(
        tenant,
        "select public.request_top_up(%s, %s, %s, '3000', 'couvrir les frais du compte dédié')",
        str(uuid.uuid4()),
        own,
        tenant["bank"],
    )
    day = max(paris_today(), _last_closing(tenant)[1])
    opening, _last = _last_closing(tenant)
    tag = uuid.uuid4().hex[:6].upper()
    back = Entry(
        3_000,
        True,
        day,
        day,
        ref=f"NL{tag}",
        payment_info_id=lot,
        txs=(Tx(3_000, ref=f"L{tag}", end_to_end_id=top["end_to_end_id"], iban=own_iban),),
    )
    sid = import_entries(tenant, storage(), [back], day=day, opening=opening)
    with psycopg.connect(DB) as conn:
        line = conn.execute(
            """select id::text, kind, private.names_our_lot(bank_account_id, payment_info_id)
               from public.bank_transaction where statement_id = %s""",
            (sid,),
        ).fetchone()
    assert line is not None and tuple(line[1:]) == ("own_transfer_in", True)
    assert _payments_of(sid) == 0
    assert _bookings(sid) == []
    assert _reviews(sid) == ["top_up_differs"]
    assert _transfer(top["end_to_end_id"])["status"] == "ordered"
    with pytest.raises(psycopg.errors.CheckViolation, match="own_transfer_line"):
        staff(
            tenant, "select public.release_own_credit(%s, %s, 'relayé')", str(uuid.uuid4()), line[0]
        )
    with pytest.raises(psycopg.errors.CheckViolation, match="own_transfer_line"):
        staff(
            tenant,
            "select public.link_debit(%s, %s, 'own_credit', null, null, null, 'approvisionnement')",
            str(uuid.uuid4()),
            line[0],
        )
    # the same credit with no PmtInfId of ours: the top-up we ordered
    plain = Entry(
        3_000,
        True,
        day,
        day,
        ref=f"NP{tag}",
        txs=(Tx(3_000, ref=f"P{tag}", end_to_end_id=top["end_to_end_id"], iban=own_iban),),
    )
    opening2, _last2 = _last_closing(tenant)
    sid2 = import_entries(tenant, storage(), [plain], day=day, opening=opening2)
    assert [k for k, _, _ in _bookings(sid2)] == ["top_up"]
    assert _transfer(top["end_to_end_id"])["status"] == "booked"
    _no_violation(tenant)
