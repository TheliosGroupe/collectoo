"""M2c-7f-2 — the 50k close-out volume run (needs `make up`; plan docs/design/m2c-7-plan.md §8.3,
docs/design/m2c-7f-plan.md §3 V1-V3). Each row of §8.3 is asserted with its bound, then measured
in docs/benchmarks/remittances.md. Its own CI job (`scale-closeout`, founder Q2 (a)): on pushes
to main and on dispatch, never on pull requests.

The world. One servicer, one client, 50,000 files boarded from the synthetic EU loan tape (as the
M2-08 and M2c-4 scale files), its mandate with a netting clause and a claw-back clause. The
statistics are the state CI meets: a reset, then the imports; before the measured steps of rows 1,
2, 4 and 5 (the claw-back run's prepare and approval, its booking) the statistics of the tables 7a's
reads use (FROZEN) are forgotten and kept so (autovacuum off on them meanwhile), as the 6a/6b files
do. (Review round 1, VC-4) Rows 6 and 7 and V3 run on the statistics the history left (analysed by
autovacuum as it goes), and row 8 on scale-payouts' own plant (its five tables forgotten, not
ledger_account): their reads under stale statistics are the db job's reads tests'
(test_client_payment_reads_integration, test_close_out_fixes_reads_integration: the pooled lookup
under three planted states). The cancellation-after-download switch stays off: nothing here writes
it.

- History: RUNS (10) collections of every file (a statement paying each file by its RF, imported,
  matched and allocated through the payments queue), each remitted in a 50k-line run requested,
  prepared and approved through the jobs, its payout filed, downloaded, debited on a statement and
  booked by the debit job (`book_payout`, the real path). Debited on the collections' last day:
  each run is booked days before today.
- The day (rows 1, 2, 4): a statement of DAY (1,000, 2 %) full returns of payments of the first
  booked run, imported; the debit job's first message (the M2b pass) reverses each allocation and
  covers each reversal (an advance of the servicer, `cover_remitted_reversals`). Row 4 compares
  the night with 1 and with RUNS booked runs: the same day measured twice, each time in one
  transaction rolled back (the import, the debit chunk, the nightly's passes), after the first run
  and after the last — so both nights read the same 1,000 reversals and 1,000 covers, and differ
  only by the booked runs. The window of the delta pass (`run_advance_checks`: the reversals,
  bookings and covers since the servicer's last completed check run, less one day of overlap)
  needs that run a day after the history; the measuring transaction plants it (a completed
  payment_check_run starting one day after its own start, less a millisecond: payment_check_run has
  no guard; the plant goes with the rollback), so the history lies before the window as days-old
  history would (asserted: the delta pass reads no booked run's lines). Then the day is
  imported again and debited for real (the queue's jobs).
- Row 6: one `record_client_payment` per cover of the day (1,000), each naming its advance with
  its proof and designation, timed one by one.
- Row 5: OPEN_ADVANCES (1,000) open advances under the claw-back clause — the covers of 800 more
  returns of the second run's payments (debited for real), and 200 `payout_overrun` advances on
  the history's 50k-line runs' payouts, posted as the funds pass posts one (its entry by
  `ledger_post_set`, then its row, as test_remitted_reversal_integration's plant: no product path
  makes 200 overruns on 50k-line runs) and dated at those runs' debits (the oldest); then a new
  collection of every file and the client's run (the claw-back takes the 1,000 advances back,
  oldest first, on the mandate's money): its prepare and approval jobs timed, « Avances » timed
  before its approval; its settlement at its debit (the funds pass's post_run_settlements) timed.
- Row 3: before that run's payout is debited, RETURNS_IN_FLIGHT (1,000) of its own lines'
  payments returned (reversed while the run is in flight: nothing to cover yet); at its booking
  the funds pass covers them (`cover_booked_run_reversals`), timed — in the same funds pass.
- Row 7: SERVICERS (100) other servicers, each owing its dedicated account (a bank charge posted
  as the funds pass posts one), the hourly `top_ups` job over them, one message (one
  transaction) each; then again with one servicer's remit lock held by another session.
- Row 8: the 5,000-payout funds pass of `scale-payouts` (test_debit_bookings_scale_integration's
  fixture and batch pass, reused): its time with the at-booking cover and the per-row run check.
- V3: the payout blockers' nested calls (5,000 calls for a client with a death recorded), and
  `ledger_post_set`'s own time in row 8.

Function times come from `pg_stat_xact_user_functions` (track_functions, the superuser's session
running the job as the worker's role); rows read from `pg_stat_xact_user_tables` (index fetches +
sequential reads): deterministic, whatever the cache. CLOSEOUT_* change the sizes (for a quick
local run; the bounds are the plan's at full size)."""

from __future__ import annotations

import json
import logging
import os
import threading
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any

import psycopg
import pytest
from debit_helpers import return_entry
from explain_helpers import ADMIN
from integration_helpers import DB, as_user, one, storage
from psycopg.types.json import Jsonb
from reconciliation_helpers import pay
from remittance_helpers import (
    add_admin,
    book_payout,
    confirm_payout,
    own_account,
    paris_today,
    recent_business_day,
    revalidate_after_date_change,
    run_row,
    staff,
)
from statement_helpers import bank_tenant
from statement_helpers import drain as drain_payments
from stats_helpers import forget_statistics, frozen_statistics
from test_allocation_scale_integration import _files
from test_debit_bookings_scale_integration import _batch_pass, _file_payouts, _statement
from test_matching_scale_integration import _board

from collectoo_worker.jobs.debits import run_process_debits
from collectoo_worker.jobs.payments import import_statement
from collectoo_worker.jobs.payments import make_handler as payments_handler
from collectoo_worker.jobs.payments import record_dead_job as payments_dead
from collectoo_worker.jobs.remittances import make_handler as remittances_handler
from collectoo_worker.jobs.remittances import record_dead_job as remittances_dead
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.synth.camt053 import make_doc, render_camt053
from collectoo_worker.synth.reconciliation import Credit

pytestmark = pytest.mark.integration
log = logging.getLogger(__name__)

FILES = int(os.environ.get("CLOSEOUT_FILES", "50000"))
RUNS = int(os.environ.get("CLOSEOUT_RUNS", "10"))  # booked 50k-line runs (the history)
DAY = int(os.environ.get("CLOSEOUT_DAY", "1000"))  # the day's returns (2 %), their covers
OPEN_ADVANCES = int(os.environ.get("CLOSEOUT_OPEN_ADVANCES", "1000"))  # row 5's
OVERRUNS = int(os.environ.get("CLOSEOUT_OVERRUNS", "200"))  # of them payout_overrun
RETURNS_IN_FLIGHT = int(os.environ.get("CLOSEOUT_IN_FLIGHT", "1000"))  # row 3's
SERVICERS = int(os.environ.get("CLOSEOUT_SERVICERS", "100"))  # row 7's
PAYOUTS = int(os.environ.get("CLOSEOUT_PAYOUTS", "5000"))  # row 8's (scale-payouts' fixture)
BLOCKER_CALLS = int(os.environ.get("CLOSEOUT_BLOCKER_CALLS", "5000"))  # V3

CLAWBACK_TERMS = {
    "schema": "remittance-1",
    "frequency": "twice_monthly",
    "netting": {"clause_ref": "art. 7.2"},
    "clawback": {"clause_ref": "art. 7.4"},
    "invoice_payment_days": 30,
}
# a collection pays a sixteenth of each file's opening balance (eleven of them: the history's, the
# claw-back run's)
SHARE = 16
# the tables whose statistics each measured step forgets and keeps forgotten: 7a's reads (the
# entries, the runs, their lines, the covers, the bookings, the settlements, the attributions)
FROZEN = (
    "public.ledger_entry",
    "public.remittance_line",
    "public.remittance_run",
    "public.client_advance",
    "public.bank_line_booking",
    "public.bank_transfer",
    "public.commission_settlement",
    "private.unplanned_paid_item",
)

# §8.3 bounds (each the plan's; `x 1.1` where the plan says so)
CHUNK_S = 60.0  # row 1: one debit-job chunk
COVER_S = 2.0  # row 1: the cover statement (cover_remitted_reversals), 1,000 reversals
COVER_READS_PER_REVERSAL = 20  # row 1: rows read per table, per reversal
LG009_S = 0.5  # row 2: the deferred LG009 checks of the 1,000 reversals
BOOKED_COVER_S = 3.0  # row 3: cover_booked_run_reversals at the booking
DELTA_S = 0.5  # row 4: run_advance_checks' delta pass
DELTA_READS_SPREAD = 0.10  # row 4: its reads with 1 and with RUNS booked runs, within 10 %
FULL_S = 8.0  # row 4: the p_full pass
NIGHTLY_INCREASE_S = 2.0  # row 4: the whole nightly, before and after 7a's checks
PREPARE_S = 10.6 * 1.1  # row 5: M2c-4's measures
APPROVAL_S = 6.1 * 1.1
SETTLEMENT_S = 2.0  # row 5: the settlement at the debit (1,000 settlement rows)
ADVANCES_PAGE_S = 0.3  # row 5: « Avances »
CLIENT_PAYMENT_S = 0.2  # row 6: each record_client_payment
TOP_UPS_S = 2.0  # row 7: the job over 100 servicers
FUNDS_PASS_S = 24.0 * 1.1  # row 8
BLOCKERS_S = 8.0  # V3: 5,000 calls, a death recorded
# a few rows a call reads besides its own (the servicer's reference rows, a check run's)
PER_CALL = 100
# row 4: below this many rows, a table's reads are compared within this many rows
SPREAD_SLACK = 50
# row 4: the delta pass's remittance_line rows per reversal of the day (its line, the same-run
# probe): a booked run's lines (50,000) read by the delta pass break it
DELTA_LINES_PER_REVERSAL = 6


@dataclass
class World:
    tenant: dict[str, Any]
    mandate: str
    files: list[tuple[str, str, int]]
    start: date
    runs: list[str] = field(default_factory=list)
    collections: list[str] = field(default_factory=list)  # each run's statement
    timings: dict[str, Any] = field(default_factory=dict)
    nights: dict[int, dict[str, Any]] = field(
        default_factory=dict
    )  # booked runs → the day measured
    day_entries: list[Any] = field(default_factory=list)  # the day's returns (camt entries)
    day_date: date | None = None


# ---------------------------------------------------------------------------------------------
# The jobs: the queues drained through the worker's own handlers, timed by message
# ---------------------------------------------------------------------------------------------


def _drain_remittances(times: list[tuple[str, float]] | None = None) -> None:
    """The remittances queue drained (one consumer: one client's run at a time); the documents
    jobs taken off unrun (they render PDFs and touch no booking, as the scale-payouts fixture).
    `times`: (message type, seconds) of each message handled."""
    handle = remittances_handler(storage())

    def handler(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        kind = str(payload.get("type"))
        if kind == "documents":
            return
        started = time.monotonic()
        handle(payload, conn)
        if times is not None:
            times.append((kind, time.monotonic() - started))

    consumer = QueueConsumer(DB, "remittances", handler, on_dead=remittances_dead)
    while consumer.poll_once():
        pass


FUNCTIONS = (
    "cover_remitted_reversals",
    "cover_booked_run_reversals",
    "post_run_settlements",
    "remitted_cover_check",
    "run_booked_cover_check",
    "ledger_post_set",
    "bank_booking_post_rows",
)


def _functions(conn: psycopg.Connection[Any]) -> dict[str, tuple[int, float]]:
    """This transaction's calls and total ms of the functions FUNCTIONS names (track_functions)."""
    rows = conn.execute(
        """select funcname, sum(calls)::bigint, sum(total_time)::float8
           from pg_stat_xact_user_functions where funcname = any(%s) group by funcname""",
        (list(FUNCTIONS),),
    ).fetchall()
    return {str(r[0]): (int(r[1]), float(r[2])) for r in rows}


def _reads(conn: psycopg.Connection[Any]) -> dict[str, int]:
    """This transaction's rows read so far, per table (index fetches + sequential reads)."""
    rows = conn.execute(
        """select schemaname || '.' || relname,
                  coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0)
           from pg_stat_xact_user_tables
           where coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0) > 0"""
    ).fetchall()
    return {str(r[0]): int(r[1]) for r in rows}


def _delta(after: dict[str, int], before: dict[str, int]) -> dict[str, int]:
    return {t: n - before.get(t, 0) for t, n in after.items() if n - before.get(t, 0) > 0}


def _drain_payments_measured(found: list[dict[str, Any]]) -> None:
    """The payments queue drained by the superuser's session, each message run as the worker's
    role with track_functions on: per message, its type, its seconds and, before the queue's
    commit (the deferred checks forced first, as the job's own ledger_check_now does), the calls
    and times of FUNCTIONS. The worker's handlers unchanged."""
    handle = payments_handler(storage())

    def handler(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        kind = str(payload.get("type"))
        if kind == "receipts":  # (receipt PDFs: not this file's)
            return
        conn.execute("set local track_functions = 'all'")
        conn.execute("set local role postgres")
        started = time.monotonic()
        try:
            handle(payload, conn)
            conn.execute("set constraints all immediate")
            conn.execute("set constraints all deferred")
        finally:
            conn.execute("reset role")
        found.append(
            {
                "type": kind,
                "funds": "funds_after" in payload,
                "s": time.monotonic() - started,
                "functions": _functions(conn),
                "reads": _reads(conn),
            }
        )

    consumer = QueueConsumer(ADMIN, "payments", handler, on_dead=payments_dead)
    while consumer.poll_once():
        pass


# ---------------------------------------------------------------------------------------------
# The world and the history
# ---------------------------------------------------------------------------------------------


def _clawback_terms(mandate: str) -> None:
    """The mandate's version given its claw-back clause before any run reads it (the version is
    in force from its signature, immutable then: set before any use, as remittance_tenant does)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("alter table public.mandate_terms disable trigger mandate_terms_guard")
        conn.execute(
            "update public.mandate_terms set remittance_terms = %s where mandate_id = %s",
            (json.dumps(CLAWBACK_TERMS), mandate),
        )
        conn.execute("alter table public.mandate_terms enable trigger mandate_terms_guard")


def _collection(w: World, label: str) -> str:
    """A statement paying every file a sixteenth of its opening balance by its RF, imported,
    matched and allocated through the payments queue (receipts left unrun). Its id."""
    credits = [
        Credit(max(1, b // SHARE), "PAYEUR", None, ("ECHEANCE",), rf, account, "auto", "closeout")
        for account, rf, b in w.files
    ]
    prefix = f"{label}{uuid.uuid4().hex[:4].upper()}"
    return pay(w.tenant, storage(), credits, prefix=prefix, start=w.start, days=5)


def _run(w: World, times: list[tuple[str, float]] | None = None) -> str:
    """« Préparer maintenant » for the client, its prepare job, « Valider » and its approval job
    (the documents jobs left unrun); midnight in Paris meanwhile: « Valider » again."""
    out = staff(
        w.tenant,
        "select public.request_remittance_run(%s, %s, 'EUR')",
        str(uuid.uuid4()),
        w.tenant["client"],
    )
    run = str(out["run_id"])
    _drain_remittances(times)
    draft = run_row(run)
    assert draft["prepared_at"] is not None, draft["last_failure"]
    since = paris_today()
    item = [
        {"run_id": run, "inputs_hash": draft["inputs_hash"], "net_text": str(draft["net_minor"])}
    ]
    queued = staff(
        w.tenant,
        "select public.approve_remittance_runs(%s, %s)",
        str(uuid.uuid4()),
        json.dumps(item),
    )
    assert queued["results"][0]["status"] == "queued", queued
    _drain_remittances(times)
    if revalidate_after_date_change(w.tenant, [run], since):
        _drain_remittances(times)
    done = run_row(run)
    assert done["status"] == "approved", done["last_failure"]
    return run


def _lines(run: str) -> int:
    with psycopg.connect(DB) as conn:
        return int(
            one(
                conn,
                "select count(*) from public.remittance_line where run_id = %s and not released",
                (run,),
            )
        )


def _history_run(w: World, k: int) -> None:
    started = time.monotonic()
    w.collections.append(_collection(w, f"H{k:02d}"))
    collected = time.monotonic()
    run = _run(w)
    approved = time.monotonic()
    book_payout(run)
    booked = time.monotonic()
    w.runs.append(run)
    lines = _lines(run)
    assert lines >= 0.98 * len(w.files), (lines, len(w.files))
    w.timings.setdefault("history", []).append(
        (
            k,
            lines,
            round(collected - started, 1),
            round(approved - collected, 1),
            round(booked - approved, 1),
        )
    )
    print(
        f"\nhistory run {k}: {lines} lines; collected {collected - started:.1f}s, prepared and"
        f" approved {approved - collected:.1f}s, booked {booked - approved:.1f}s"
    )


def _payments_of(statement_id: str, n: int, offset: int = 0) -> list[tuple[str, int, str]]:
    """n allocated payments of a statement (id, amount, end-to-end id), by id."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select p.id::text, p.amount_minor, p.end_to_end_id
               from public.bank_transaction t join public.payment p on p.bank_transaction_id = t.id
               where t.statement_id = %s and p.status = 'allocated' and p.end_to_end_id is not null
               order by p.id offset %s limit %s""",
            (statement_id, offset, n),
        ).fetchall()
    assert len(rows) == n, (len(rows), n)
    return [(str(r[0]), int(r[1]), str(r[2])) for r in rows]


def _last_statement(tenant: dict[str, Any]) -> tuple[int, date]:
    with psycopg.connect(DB) as conn:
        last = conn.execute(
            """select closing_booked_minor, to_date from public.bank_statement
               where bank_account_id = %s and status = 'imported'
               order by to_date desc, created_at desc limit 1""",
            (tenant["bank"],),
        ).fetchone()
    assert last is not None
    return int(last[0]), last[1]


def _returns_doc(w: World, payments: list[tuple[str, int, str]], day: date, tag: str) -> bytes:
    """A one-day camt.053 of full returns of these payments (by their end-to-end ids), chained to
    the account's last closing balance."""
    entries = [
        return_entry(amount, e2e, f"{tag}{n:08d}", day)
        for n, (_p, amount, e2e) in enumerate(payments)
    ]
    opening, _ = _last_statement(w.tenant)
    doc = make_doc(
        entries,
        iban=w.tenant["iban"],
        from_date=day,
        to_date=day,
        opening_minor=opening,
        stmt_id=f"S-{tag}",
    )
    return render_camt053(doc, "08")


def _import_for_real(w: World, data: bytes, name: str) -> str:
    """create_statement_upload, the upload, submit_statement_import (ops at aal2, the API's 8 s),
    then the payments queue drained by the worker's handlers. The statement's id."""
    from statement_helpers import upload  # noqa: PLC0415 - the real path, once

    target = upload(w.tenant, storage(), data, name=name)
    drain_payments(storage())
    return str(target["statement_id"])


# ---------------------------------------------------------------------------------------------
# The day measured: rows 1, 2 and 4, in one transaction rolled back
# ---------------------------------------------------------------------------------------------

# the cover statement's probe: cover_remitted_reversals renamed and wrapped, in the measuring
# transaction only (rolled back with it) — the time and this transaction's rows read per table
# around the one call the debit chunk makes
_PROBE = """
create temp table _cover_probe (fn text, at text, ts timestamptz, rel text, n bigint);
alter function private.cover_remitted_reversals(uuid[], uuid[]) rename to
  cover_remitted_reversals_probed;
create function private.cover_remitted_reversals(p_reversal_ids uuid[], p_line_ids uuid[] default
  null)
returns integer language plpgsql security definer set search_path = '' as $f$
declare v integer;
begin
  -- the balance checks of the entries posted before (the reversals, the cash_out) run now, not in
  -- the cover's own posting (ledger_post_set forces every pending one immediate as it ends)
  set constraints public.ledger_entry_balanced immediate;
  set constraints public.ledger_entry_balanced deferred;
  insert into pg_temp._cover_probe
  select 'cover', 'before', clock_timestamp(), schemaname || '.' || relname,
         coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0) from
           pg_catalog.pg_stat_xact_user_tables;
  v := private.cover_remitted_reversals_probed(p_reversal_ids, p_line_ids);
  insert into pg_temp._cover_probe
  select 'cover', 'after', clock_timestamp(), schemaname || '.' || relname,
         coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0) from
           pg_catalog.pg_stat_xact_user_tables;
  return v;
end $f$;
alter function private.remitted_cover_post() rename to remitted_cover_post_probed;
create function private.remitted_cover_post()
returns integer language plpgsql security definer set search_path = '' as $f$
declare v integer;
begin
  insert into pg_temp._cover_probe
  select 'post', 'before', clock_timestamp(), schemaname || '.' || relname,
         coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0) from
           pg_catalog.pg_stat_xact_user_tables;
  v := private.remitted_cover_post_probed();
  insert into pg_temp._cover_probe
  select 'post', 'after', clock_timestamp(), schemaname || '.' || relname,
         coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0) from
           pg_catalog.pg_stat_xact_user_tables;
  return v;
end $f$;
"""

# run_remittance_checks without 7a's checks (its body before M2c-7a: 20261115090000 line 3710),
# swapped into a savepoint of the measuring transaction
_BEFORE_7A = """
create or replace function private.run_remittance_checks(p_check_run_id uuid, p_organization_id
  uuid,
                                                         p_today date default null)
returns void language plpgsql security definer set search_path = '' as $f$
begin
  perform private.run_remittance_runs_checks(p_check_run_id, p_organization_id, p_today);
  perform private.run_transfer_checks(p_check_run_id, p_organization_id, p_today);
end $f$;
"""


def _probe_rows(conn: psycopg.Connection[Any], fn: str) -> tuple[float, dict[str, int]]:
    """The probe's seconds and rows read per table (temporary tables apart) around `fn`'s one
    call."""
    rows = conn.execute(
        """select at, ts, rel, n from pg_temp._cover_probe
           where fn = %s and rel not like 'pg_temp%%'""",
        (fn,),
    ).fetchall()
    ts = {str(r[0]): r[1] for r in rows}
    before = {str(r[2]): int(r[3]) for r in rows if r[0] == "before"}
    after = {str(r[2]): int(r[3]) for r in rows if r[0] == "after"}
    assert set(ts) == {"before", "after"}, rows[:3]
    return (ts["after"] - ts["before"]).total_seconds(), _delta(after, before)


def _night(
    conn: psycopg.Connection[Any], org: str, today: date, full: bool
) -> tuple[float, dict[str, int]]:
    """run_advance_checks alone (a check run of its own): its seconds and rows read."""
    run = one(
        conn,
        "insert into public.payment_check_run (organization_id) values (%s) returning id",
        (org,),
    )
    before = _reads(conn)
    started = time.monotonic()
    conn.execute("select private.run_advance_checks(%s, %s, %s, %s)", (run, org, today, full))
    elapsed = time.monotonic() - started
    return elapsed, _delta(_reads(conn), before)


def _whole_nightly(conn: psycopg.Connection[Any], org: str, before_7a: bool) -> float:
    """The servicer's whole nightly (private.run_payment_checks), in a savepoint rolled back; with
    `before_7a`, run_remittance_checks' body before 7a's checks swapped in."""
    with conn.transaction(force_rollback=True):
        if before_7a:
            conn.execute(_BEFORE_7A)
        started = time.monotonic()
        conn.execute("select private.run_payment_checks(%s)", (org,))
        return time.monotonic() - started


def _measure_day(w: World) -> dict[str, Any]:
    """The day (DAY returns of the first run's payments) imported and debited, then the night, in
    one transaction rolled back: row 1 (the chunk, the cover statement and its reads), row 2 (the
    deferred LG009 checks), row 4 (the delta pass, the full pass, the whole nightly before and
    after 7a's checks)."""
    org, day = str(w.tenant["servicer"]), w.day_date
    assert day is not None
    data = _returns_doc(w, w.day_entries, day, f"DY{len(w.runs):02d}")
    out: dict[str, Any] = {"booked_runs": len(w.runs)}
    with frozen_statistics(*FROZEN):
        for t in FROZEN:
            forget_statistics(t)
        with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
            # the upload and the import's submission, as ops at aal2 (their rows rolled back)
            as_user(conn, w.tenant["staff"], "aal2")
            target = one(
                conn,
                "select public.create_statement_upload(%s, %s, %s, %s, %s)",
                (
                    str(uuid.uuid4()),
                    w.tenant["bank"],
                    "jour.xml",
                    __import__("hashlib").sha256(data).hexdigest(),
                    len(data),
                ),
            )
            if not target["uploaded"]:
                storage().upload(
                    target["bucket"], target["storage_path"], data, "application/octet-stream"
                )
            conn.execute(
                "select public.submit_statement_import(%s, %s)",
                (str(uuid.uuid4()), target["statement_id"]),
            )
            conn.execute("reset role")
            conn.execute("set local role postgres")
            assert import_statement(conn, storage(), str(target["statement_id"])) != "skipped"
            conn.execute(_PROBE)
            conn.execute("reset role")
            conn.execute("set local track_functions = 'all'")
            conn.execute("set local role postgres")
            started = time.monotonic()
            summary = run_process_debits(conn, {"organization_id": org})
            out["chunk_s"] = time.monotonic() - started
            conn.execute("set constraints all immediate")
            conn.execute("set constraints all deferred")
            out["functions"] = _functions(conn)
            out["cover_s"], out["cover_reads"] = _probe_rows(conn, "cover")
            out["post_s"], out["post_reads"] = _probe_rows(conn, "post")
            out["fact_reads"] = _delta(out["cover_reads"], out["post_reads"])
            out["summary"] = summary
            covers = one(
                conn,
                """select count(*) from public.client_advance a
                   join public.bank_transaction t on t.id = a.bank_transaction_id
                   where t.statement_id = %s and a.cause = 'remitted_reversal'""",
                (target["statement_id"],),
            )
            out["covers"] = int(covers)
            # the night: the window planted after the history (a completed check run starting one
            # day after this transaction's start, less a millisecond: its delta starts just before
            # it, after every booking of the history — each committed before it began)
            conn.execute(
                """insert into public.payment_check_run (organization_id, started_at, finished_at,
                     violations, alerts, summary)
                   values (%s, now() + interval '1 day' - interval '1 millisecond',
                           now() + interval '1 day' - interval '1 millisecond', 0, 0,
                           ('{"planted": "the close-out volume file: the history before the '
                            || 'window"}')::jsonb)""",
                (org,),
            )
            conn.execute("reset role")
            conn.execute("set local track_functions = 'none'")
            conn.execute("set local role postgres")
            today = one(conn, "select private.paris_today()")
            out["delta_s"], out["delta_reads"] = _night(conn, org, today, False)
            out["full_s"], out["full_reads"] = _night(conn, org, today, True)
            out["today_first"] = today.day == 1
            befores, afters = [], []
            for _ in range(2):
                befores.append(_whole_nightly(conn, org, True))
                afters.append(_whole_nightly(conn, org, False))
            out["nightly_before_s"], out["nightly_after_s"] = min(befores), min(afters)
            conn.execute("reset role")
    print(
        f"\nthe day with {out['booked_runs']} booked runs (rolled back): the debit chunk"
        f" {out['chunk_s']:.1f}s"
        f" ({out['summary']}), the cover statement {out['cover_s']:.2f}s for {out['covers']} covers"
        f" (rows read {out['cover_reads']}: its facts {out['fact_reads']}, its posting"
        f" {out['post_s']:.2f}s"
        f" {out['post_reads']}), functions (calls, ms) {out['functions']};"
        f" the night's delta pass {out['delta_s']:.3f}s (rows read {out['delta_reads']}),"
        f" the full pass {out['full_s']:.2f}s (rows read {out['full_reads']}); the whole nightly"
        f" {out['nightly_after_s']:.2f}s, without 7a's checks {out['nightly_before_s']:.2f}s"
        f" (each the faster of two)"
    )
    return out


@pytest.fixture(scope="module")
def world(tmp_path_factory: pytest.TempPathFactory) -> World:
    """The 50k files, RUNS booked 50k-line runs, the day measured after the first and after the
    last run (rolled back), then the day debited for real."""
    started = time.monotonic()
    tenant = bank_tenant()
    _board(tenant, tmp_path_factory.mktemp("closeout"), count=FILES)
    with psycopg.connect(DB) as conn, conn.transaction():
        confirm_payout(conn, tenant, str(tenant["client"]))
        mandate = str(
            one(
                conn,
                "select mandate_id from public.portfolio where id = %s",
                (tenant["portfolio"],),
            )
        )
    _clawback_terms(mandate)
    tenant["admin"] = add_admin(tenant)
    files = [f for f in _files(tenant) if f[2] > 0][:FILES]
    w = World(tenant, mandate, files, recent_business_day(8))
    w.timings["boarded_s"] = time.monotonic() - started
    print(f"\n{len(files)} files boarded in {w.timings['boarded_s']:.0f}s")
    w.day_date = recent_business_day(1)
    for k in range(1, RUNS + 1):
        _history_run(w, k)
        if k == 1:
            w.day_entries = _payments_of(w.collections[0], DAY)
            w.nights[1] = _measure_day(w)
    if RUNS > 1:
        w.nights[RUNS] = _measure_day(w)
    # the day for real: imported, the debit job (the queue's): reversals and their covers
    mark = time.monotonic()
    data = _returns_doc(w, w.day_entries, w.day_date, "DAYREAL")
    caplog_chunks: list[dict[str, Any]] = []
    from statement_helpers import upload  # noqa: PLC0415

    target = upload(w.tenant, storage(), data, name="jour-reel.xml")
    _drain_payments_measured(caplog_chunks)
    w.timings["day_real_s"] = time.monotonic() - mark
    w.timings["day_real_jobs"] = [(m["type"], m["funds"], round(m["s"], 2)) for m in caplog_chunks]
    with psycopg.connect(DB) as conn:
        covers = one(
            conn,
            """select count(*) from public.client_advance a
               join public.bank_transaction t on t.id = a.bank_transaction_id
               where t.statement_id = %s and a.cause = 'remitted_reversal'""",
            (target["statement_id"],),
        )
    assert covers == DAY, covers
    w.timings["day_statement"] = str(target["statement_id"])
    w.timings["built_s"] = time.monotonic() - started
    print(
        f"\nthe day for real: {w.timings['day_real_jobs']} in {w.timings['day_real_s']:.1f}s;"
        f" the world built in {w.timings['built_s']:.0f}s"
    )
    return w


# ---------------------------------------------------------------------------------------------
# Rows 1, 2, 4
# ---------------------------------------------------------------------------------------------


def test_row_1_the_covers_at_the_reversal(world: World) -> None:
    """§8.3 row 1: a statement of 1,000 returns (2 %) of payments of a booked 50k-line run, one
    debit-job chunk: the chunk < 60 s; the cover statement (cover_remitted_reversals, 1,000
    reversals) < 2 s; its reads keyed, ≤ 20 rows per reversal of each table. The statement's two
    parts are bounded each: its facts (7a's reads: each reversal's entry, line, run, payout and
    covers) and its posting (private.remitted_cover_post: the posting core, ledger_post_set, which
    reads each of an advance entry's four lines five times in its checks, 20 rows per reversal of
    ledger_posting and ledger_account) — both the same with 1 and with RUNS booked runs."""
    for runs, night in sorted(world.nights.items()):
        assert night["covers"] == DAY, (runs, night["covers"], night["summary"])
        assert night["chunk_s"] < CHUNK_S, (runs, night["chunk_s"])
        calls, ms = night["functions"]["cover_remitted_reversals"]
        assert calls == 1, night["functions"]
        # (the probe's inner time, and the whole call's: the reversals' balance checks it forces)
        assert max(night["cover_s"], ms / 1000) < COVER_S, (runs, night["cover_s"], ms)
        for part in ("fact_reads", "post_reads"):
            over = {
                t: n
                for t, n in night[part].items()
                if n > COVER_READS_PER_REVERSAL * DAY + PER_CALL
            }
            assert over == {}, (runs, part, over)
    if len(world.nights) > 1:  # the history read by neither part: the same rows in all, within 10 %
        (_, a), (_, b) = sorted(world.nights.items())
        total_a, total_b = sum(a["cover_reads"].values()), sum(b["cover_reads"].values())
        assert (
            abs(total_b - total_a) <= DELTA_READS_SPREAD * max(total_a, total_b) + SPREAD_SLACK
        ), (
            a["cover_reads"],
            b["cover_reads"],
        )


def test_row_2_the_deferred_lg009_checks(world: World) -> None:
    """§8.3 row 2: the deferred LG009 checks of the 1,000 reversals (ledger_entry_remitted_cover,
    one per reversal: private.remitted_cover_check) < 0.5 s in all."""
    for runs, night in sorted(world.nights.items()):
        calls, ms = night["functions"].get("remitted_cover_check", (0, 0.0))
        assert calls >= DAY, (runs, night["functions"])
        assert ms / 1000 < LG009_S, (runs, calls, ms)


def test_row_4_the_nightly_with_1_and_with_10_booked_runs(world: World) -> None:
    """§8.3 row 4 [critic] F9, F17: run_advance_checks' delta pass < 0.5 s and its reads
    independent of the number of booked runs (with 1 and with RUNS booked 50k-line runs, the rows
    read in all within 10 %; and no table read more with RUNS than with 1 beyond 10 %: one-sided,
    as the tables 7a's reads do not use — ledger_account, ledger_posting — keep their own
    statistics, which differ between the two nights and moved their plans by about 250 rows each
    the other way, 1 run reading more); the p_full pass < 8 s; the whole nightly's increase
    before and after 7a's checks ≤ 2 s (same transaction, same order)."""
    assert RUNS > 1 and set(world.nights) == {1, RUNS}, world.nights.keys()
    one_run, history = world.nights[1], world.nights[RUNS]
    for night in (one_run, history):
        assert night["delta_s"] < DELTA_S, night["delta_s"]
        assert night["full_s"] < FULL_S, night["full_s"]
        # (on the 1st of a month, Paris, the whole nightly runs the full pass: its own bound then)
        bound = NIGHTLY_INCREASE_S + (FULL_S if night["today_first"] else 0)
        assert night["nightly_after_s"] - night["nightly_before_s"] <= bound, night
    for night in (one_run, history):  # the window after the history: no booked run's lines read
        assert (
            night["delta_reads"].get("public.remittance_line", 0)
            <= DELTA_LINES_PER_REVERSAL * DAY + PER_CALL
        ), night
    a, b = one_run["delta_reads"], history["delta_reads"]
    spread = {
        t: (a.get(t, 0), b.get(t, 0))
        for t in set(a) | set(b)
        if b.get(t, 0) - a.get(t, 0) > max(DELTA_READS_SPREAD * a.get(t, 0), SPREAD_SLACK)
    }
    assert spread == {}, spread
    total_a, total_b = sum(a.values()), sum(b.values())
    assert abs(total_b - total_a) <= DELTA_READS_SPREAD * max(total_a, total_b) + SPREAD_SLACK, (
        total_a,
        total_b,
    )


# ---------------------------------------------------------------------------------------------
# Rows 6, 5 and 3: the client's payments, the claw-back run, its lines reversed in flight
# ---------------------------------------------------------------------------------------------


def _euros(minor: int) -> str:
    return f"{minor // 100},{minor % 100:02d}"


def _documents(w: World, kind: str, n: int) -> list[str]:
    """n documents of the client of `kind` (as « Joindre un document » registers them), each its
    own content (SHA-256)."""
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        rows = conn.execute(
            """insert into public.document (organization_id, client_organization_id, kind,
              storage_path,
                 sha256, mime_type)
               select %s, %s, %s, 'client/test/' || gen_random_uuid() || '.pdf',
                      encode(sha256(convert_to(gen_random_uuid()::text, 'UTF8')), 'hex'),
                        'application/pdf'
               from generate_series(1, %s)
               returning id::text""",
            (w.tenant["servicer"], w.tenant["client"], kind, n),
        ).fetchall()
    return [str(r[0]) for r in rows]


def _open_advances(w: World) -> list[tuple[str, str, int]]:
    """The client's open advances (id, cause, open part), oldest first."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select advance_id::text, cause, open_minor
               from private.client_open_advances(%s, 'EUR') order by born_on, created_at,
                 advance_id""",
            (w.tenant["client"],),
        ).fetchall()
    return [(str(r[0]), str(r[1]), int(r[2])) for r in rows]


def _day_covers(w: World) -> list[tuple[str, int]]:
    """The day's covers (their advance and amount)."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select a.id::text, a.amount_minor from public.client_advance a
               join public.bank_transaction t on t.id = a.bank_transaction_id
               where t.statement_id = %s and a.cause = 'remitted_reversal' order by a.created_at,
                 a.id""",
            (w.timings["day_statement"],),
        ).fetchall()
    return [(str(r[0]), int(r[1])) for r in rows]


def _client_payments(w: World) -> list[float]:
    """Row 6: « Enregistrer un règlement » once per cover of the day (its advance named, paid in
    full, its own proof, the client's designation), each as ops at aal2 in its own transaction
    under the API's 8 s: the seconds of each call."""
    covers = _day_covers(w)
    assert len(covers) == DAY, len(covers)
    proofs = _documents(w, "client_payment_evidence", len(covers))
    (designation,) = _documents(w, "payment_designation_evidence", 1)
    times = []
    with psycopg.connect(DB) as conn:
        for (advance, amount), proof in zip(covers, proofs, strict=True):
            with conn.transaction():
                as_user(conn, w.tenant["staff"], "aal2")
                conn.execute("set local statement_timeout = '8s'")
                started = time.monotonic()
                out = one(
                    conn,
                    """select public.record_client_payment(%s, %s, 'EUR', %s,
                      private.paris_today(), %s,
                                                           %s::uuid[], %s, null, %s, %s)""",
                    (
                        str(uuid.uuid4()),
                        w.tenant["client"],
                        _euros(amount),
                        proof,
                        [advance],
                        designation,
                        str(amount),
                        "Virement reçu du client (test d'échelle)",
                    ),
                )
                times.append(time.monotonic() - started)
            assert [(x["document_id"], int(x["amount_minor"])) for x in out["settled"]] == [
                (advance, amount)
            ], out
    return times


def _plant_overruns(w: World) -> None:
    """OVERRUNS payout_overrun advances on the history's runs' payouts (cycling through them): each
    entry posted as the funds pass posts it (+4679 A / -4670[c] A ‖ +4112[c] A / -4689 A, its key
    on the payout's transfer, dated at its debit), then its advance row (its cause the payout's
    remittance entry, its transfer, its debit line, the runs' mandate) — test_remitted_reversal_
    integration's plant, here on 50k-line runs."""
    with psycopg.connect(DB) as conn:
        payouts = conn.execute(
            """select t.id::text, t.entry_id::text, r.booked_on, b.bank_transaction_id::text
               from public.remittance_run r
               join public.bank_transfer t on t.run_id = r.id and t.kind = 'payout' and t.status =
                 'booked'
               join public.bank_line_booking b on b.transfer_id = t.id and b.kind = 'payout'
               where r.id = any(%s::uuid[]) order by r.booked_on, r.id""",
            (w.runs,),
        ).fetchall()
    assert len(payouts) == len(w.runs), payouts
    org, client = str(w.tenant["servicer"]), str(w.tenant["client"])
    plants = [
        (n, payouts[n % len(payouts)], str(uuid.uuid4()), 10_000 + n) for n in range(OVERRUNS)
    ]
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("select private.ledger_post_set_begin()")
        with conn.cursor() as cur:
            cur.executemany(
                """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type,
                  effective_date,
                     idempotency_key, client_organization_id, source_type, source_id, reason)
                   values (%s, %s, 'client_advance', %s, %s, %s, 'client_advance', %s,
                           'Reversement au-delà de ce qui restait dû au mandant : avance du '
                           || 'cabinet')""",
                [
                    (n + 1, org, p[2], f"adv:payout:{p[0]}:closeout:{n}", client, adv)
                    for n, p, adv, _a in plants
                ],
            )
            cur.executemany(
                """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
                   values (%s, 1, 'due_to_servicer', %s, 'EUR'), (%s, 2, 'client_payable', %s,
                     'EUR'),
                          (%s, 3, 'client_advance_receivable', %s, 'EUR'), (%s, 4,
                            'due_from_client_funds', %s, 'EUR')""",
                [(n + 1, a, n + 1, -a, n + 1, a, n + 1, -a) for n, _p, _adv, a in plants],
            )
        conn.execute(
            "create temp table _planted on commit drop as select * from private.ledger_post_set()"
        )
        conn.execute(
            """insert into public.client_advance (id, organization_id, client_organization_id,
              mandate_id, currency,
                 amount_minor, cause, cause_entry_id, entry_id, bank_transaction_id, transfer_id)
               select x.advance::uuid, %s, %s, %s, 'EUR', x.amount, 'payout_overrun',
                 x.cause::uuid, p.entry_id,
                      x.line::uuid, x.transfer::uuid
               from unnest(%s::int[], %s::text[], %s::bigint[], %s::text[], %s::text[], %s::text[])
                 x (n, advance, amount, cause, line, transfer)
               join pg_temp._planted p on p.entry_no = x.n + 1""",
            (
                org,
                client,
                w.mandate,
                [n for n, *_ in plants],
                [adv for _n, _p, adv, _a in plants],
                [a for *_, a in plants],
                [p[1] for _n, p, _adv, _a in plants],
                [p[3] for _n, p, _adv, _a in plants],
                [p[0] for _n, p, _adv, _a in plants],
            ),
        )


def _timed_page(w: World, sql: str, *params: Any) -> tuple[float, Any]:
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, w.tenant["staff"], "aal2")
        conn.execute("set local statement_timeout = '8s'")
        started = time.monotonic()
        out = one(conn, sql, params)
        return time.monotonic() - started, out


def _book_measured(w: World, run: str, in_flight: Callable[[], None]) -> list[dict[str, Any]]:
    """book_payout's real path (the run's transfer filed, the file written and downloaded, a one-day
    statement of its debit by its RMT id imported), the payments queue drained by the measured
    consumer: what each message did (the funds pass's functions among them). `in_flight` runs once
    the file is downloaded, before the debit is imported (the payout handed to the bank: a
    collection reversed then is « in flight »; before the file, the payout would be held
    `payout_not_covered`)."""
    import hashlib  # noqa: PLC0415
    import tempfile  # noqa: PLC0415

    from remittance_helpers import _bank_catch_up  # noqa: PLC0415
    from statement_helpers import upload  # noqa: PLC0415

    from collectoo_worker.synth.camt053 import Entry, Tx  # noqa: PLC0415

    with psycopg.connect(DB) as conn:
        t = conn.execute(
            """select t.id, t.status, t.amount_minor, t.end_to_end_id, t.payee_name, t.payee_iban
               from public.bank_transfer t where t.run_id = %s and t.kind = 'payout' and t.status
                 <> 'cancelled'""",
            (run,),
        ).fetchone()
    assert t is not None and t[1] == "ordered", t
    _bank_catch_up(w.tenant)
    filed = staff(
        w.tenant,
        "select public.generate_transfer_file(%s, %s, null)",
        str(uuid.uuid4()),
        w.tenant["bank"],
    )
    assert filed["nb_of_txs"] >= 1 and filed["held"] == [], filed
    _drain_remittances()  # the transfer_file job
    with psycopg.connect(DB) as conn:
        f = conn.execute(
            "select id, storage_path from public.transfer_file where id = %s", (filed["file_id"],)
        ).fetchone()
    assert f is not None
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "f.xml"
        storage().download("transfer-files", f[1], dest)
        digest = hashlib.sha256(dest.read_bytes()).hexdigest()
    staff(w.tenant, "select public.transfer_file_download(%s, %s)", f[0], digest)
    in_flight()
    opening, day = _last_statement(w.tenant)
    ref = f"BP{uuid.uuid4().hex[:10].upper()}"
    debit = Entry(
        int(t[2]),
        False,
        day,
        day,
        ref=ref,
        code="PMNT/ICDT/ESCT",
        txs=(Tx(int(t[2]), end_to_end_id=t[3], name=t[4], iban=t[5]),),
    )
    doc = make_doc(
        [debit],
        iban=w.tenant["iban"],
        from_date=day,
        to_date=day,
        opening_minor=opening,
        stmt_id=f"S-{ref}",
    )
    upload(w.tenant, storage(), render_camt053(doc, "08"), name=f"{ref}.xml")
    found: list[dict[str, Any]] = []
    with frozen_statistics(*FROZEN):
        for table in FROZEN:
            forget_statistics(table)
        _drain_payments_measured(found)
    assert run_row(run)["status"] == "booked", run_row(run)
    return found


@dataclass
class Clawback:
    run: str
    payments_s: list[float]
    open_before: list[tuple[str, str, int]]
    times: list[tuple[str, float]]
    page_s: float
    page_client_s: float
    taken: int
    in_flight_covers_at_reversal: int
    booking: list[dict[str, Any]]
    covers_at_booking: int
    settlements: int


@pytest.fixture(scope="module")
def clawback(world: World) -> Clawback:
    """Row 6, then rows 5 and 3 on the world: the day's covers paid by the client one by one; 800
    more returns covered; 200 overrun advances planted; a new collection and the client's run
    (the claw-back takes the 1,000 open advances back); 1,000 of its lines' payments returned
    while it is in flight; its payout booked (the covers at the booking, its settlement)."""
    # the servicer's own account, from here on (« Règlement du client » is paid to it): none during
    # the history, so no file of it carried a sweep (book_payout debits the payouts only)
    own_account(world.tenant)
    payments_s = _client_payments(world)
    assert _day_covers(world) and all(
        c[0] not in {a for a, _c, _o in _open_advances(world)} for c in _day_covers(world)
    )
    # the second run's returns, debited for real: OPEN_ADVANCES - OVERRUNS more covers
    more = OPEN_ADVANCES - OVERRUNS
    day = world.day_date
    assert day is not None
    if more > 0:
        data = _returns_doc(
            world,
            _payments_of(
                world.collections[min(1, len(world.collections) - 1)],
                more,
                offset=DAY if RUNS == 1 else 0,
            ),
            day,
            "MORE",
        )
        _import_for_real(world, data, "retours-2.xml")
    _plant_overruns(world)
    open_before = _open_advances(world)
    assert len(open_before) == OPEN_ADVANCES, (len(open_before), OPEN_ADVANCES)
    assert sum(1 for _a, c, _o in open_before if c == "payout_overrun") == OVERRUNS
    # the claw-back run: a new collection, « Préparer maintenant », its prepare job timed
    collection = _collection(world, "CB")
    times: list[tuple[str, float]] = []
    with frozen_statistics(*FROZEN):
        for t in FROZEN:
            forget_statistics(t)
        out = staff(
            world.tenant,
            "select public.request_remittance_run(%s, %s, 'EUR')",
            str(uuid.uuid4()),
            world.tenant["client"],
        )
        run = str(out["run_id"])
        _drain_remittances(times)
        draft = run_row(run)
        assert draft["prepared_at"] is not None, draft["last_failure"]
        # « Avances » with the 1,000 open advances (the servicer's page, then the client's)
        page_s, page = _timed_page(
            world, "select public.client_advances(%s, null, true)", world.tenant["servicer"]
        )
        page_client_s, _ = _timed_page(
            world,
            "select public.client_advances(%s, %s, true)",
            world.tenant["servicer"],
            world.tenant["client"],
        )
        assert page["rows"], page
        since = paris_today()
        item = [
            {
                "run_id": run,
                "inputs_hash": draft["inputs_hash"],
                "net_text": str(draft["net_minor"]),
            }
        ]
        queued = staff(
            world.tenant,
            "select public.approve_remittance_runs(%s, %s)",
            str(uuid.uuid4()),
            json.dumps(item),
        )
        assert queued["results"][0]["status"] == "queued", queued
        _drain_remittances(times)
        if revalidate_after_date_change(world.tenant, [run], since):
            _drain_remittances(times)
    approved = run_row(run)
    assert approved["status"] == "approved", approved["last_failure"]
    taken = sum(1 for s in approved["settlement_plan"]["settles"] if s.get("kind") == "advance")
    # row 3: RETURNS_IN_FLIGHT of the run's own lines' payments returned while it is in flight (its
    # file downloaded, its debit not yet on a statement), then its payout booked
    flight: dict[str, str] = {}

    def returns_in_flight() -> None:
        data = _returns_doc(world, _payments_of(collection, RETURNS_IN_FLIGHT), day, "FLIGHT")
        flight["statement"] = _import_for_real(world, data, "retours-en-vol.xml")

    booking = _book_measured(world, run, returns_in_flight)
    with psycopg.connect(DB) as conn:
        at_reversal = int(
            one(
                conn,
                """select count(*) from public.client_advance a
                   join public.bank_transaction t on t.id = a.bank_transaction_id
                   where t.statement_id = %s""",
                (flight["statement"],),
            )
        )
    with psycopg.connect(DB) as conn:
        transfer = one(
            conn,
            "select id from public.bank_transfer where run_id = %s and kind = 'payout'",
            (run,),
        )
        covers_at_booking = int(
            one(
                conn,
                """select count(*) from public.client_advance
                   where transfer_id = %s and cause = 'remitted_reversal'""",
                (transfer,),
            )
        )
        settlements = int(
            one(
                conn,
                """select count(*) from public.commission_settlement
               where run_id = %s and document_kind = 'advance'""",
                (run,),
            )
        )
    print(
        f"\nthe claw-back run: {OPEN_ADVANCES} open advances ({OVERRUNS} overruns); jobs"
        f" {times}; « Avances »"
        f" {page_s:.3f}s (the client's {page_client_s:.3f}s); {taken} advances taken; its booking"
        f" {[(m['type'], m['funds'], round(m['s'], 2), m['functions']) for m in booking]};"
        f" covers at the"
        f" booking {covers_at_booking}, at the reversal {at_reversal}; settlement rows"
        f" {settlements}"
    )
    return Clawback(
        run,
        payments_s,
        open_before,
        times,
        page_s,
        page_client_s,
        taken,
        at_reversal,
        booking,
        covers_at_booking,
        settlements,
    )


def _funds(c: Clawback) -> dict[str, tuple[int, float]]:
    (funds,) = [m for m in c.booking if m["type"] == "process_debits" and m["funds"]]
    return dict(funds["functions"])


def test_row_6_client_payments(clawback: Clawback) -> None:
    """§8.3 row 6: 1,000 record_client_payment calls, each < 200 ms."""
    times = sorted(clawback.payments_s)
    print(
        f"\nrow 6: {len(times)} calls, median {times[len(times) // 2] * 1000:.0f} ms, p99"
        f" {times[int(len(times) * 0.99) - 1] * 1000:.0f} ms, max {times[-1] * 1000:.0f} ms"
    )
    assert len(times) == DAY
    assert times[-1] < CLIENT_PAYMENT_S, times[-5:]


def test_row_5_the_claw_back_run(clawback: Clawback) -> None:
    """§8.3 row 5 [critic] F10: 50k new collections and 1,000 open advances under the claw-back
    clause, 200 of them payout_overrun on 50k-line runs: its prepare ≤ 10.6 s x 1.1, its approval
    ≤ 6.1 s x 1.1 (M2c-4's measures), its settlement at the debit < 2 s (1,000 settlement rows);
    « Avances » < 300 ms."""
    prepares = [s for k, s in clawback.times if k == "prepare"]
    approvals = [s for k, s in clawback.times if k == "approve"]
    assert len(prepares) == 1 and len(approvals) >= 1, clawback.times
    assert prepares[0] <= PREPARE_S, clawback.times
    assert approvals[-1] <= APPROVAL_S, clawback.times
    assert clawback.taken == OPEN_ADVANCES, clawback.taken
    assert clawback.settlements == OPEN_ADVANCES, clawback.settlements
    calls, ms = _funds(clawback)["post_run_settlements"]
    assert calls == 1 and ms / 1000 < SETTLEMENT_S, (calls, ms)
    assert clawback.page_s < ADVANCES_PAGE_S and clawback.page_client_s < ADVANCES_PAGE_S, (
        clawback.page_s,
        clawback.page_client_s,
    )


def test_row_3_the_covers_at_the_booking(clawback: Clawback) -> None:
    """§8.3 row 3: a 50k-line run with 1,000 lines reversed in flight, its payout booked:
    cover_booked_run_reversals < 3 s (here the claw-back run's: the same funds pass)."""
    assert clawback.in_flight_covers_at_reversal == 0  # in flight: nothing remitted yet
    assert clawback.covers_at_booking == RETURNS_IN_FLIGHT, clawback.covers_at_booking
    calls, ms = _funds(clawback)["cover_booked_run_reversals"]
    assert calls == 1 and ms / 1000 < BOOKED_COVER_S, (calls, ms)


# ---------------------------------------------------------------------------------------------
# V3: the payout blockers' nested calls, a death recorded
# ---------------------------------------------------------------------------------------------


def test_v3_the_blockers_for_a_client_with_a_death(world: World) -> None:
    """V3 (7d-1 CC-1, plan R5): 5,000 calls of private.remittance_payout_blockers (as
    transfer_hold_reason makes them, in a plpgsql loop) for the world's client, with a death
    recorded (in a transaction rolled back): under 8 s (7d-1: 2.2-2.4 s on a small world)."""
    org, client = str(world.tenant["servicer"]), str(world.tenant["client"])
    loop = f"""do $$ declare v text[]; begin
                 for i in 1..{BLOCKER_CALLS} loop
                   v := private.remittance_payout_blockers('{client}', 'EUR', current_date);
                 end loop; end $$"""
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        started = time.monotonic()
        conn.execute(loop)
        none_s = time.monotonic() - started
        evidence = one(
            conn,
            """insert into public.document (organization_id, client_organization_id, kind,
              storage_path, sha256,
                 mime_type)
               values (%s, %s, 'client_status_evidence', %s, repeat('e', 64), 'application/pdf')
                 returning id""",
            (org, client, f"client/test/{uuid.uuid4()}.pdf"),
        )
        conn.execute(
            """insert into public.client_status_event (organization_id, client_organization_id,
              kind, effective_date,
                 evidence_document_id, note, recorded_by)
               values (%s, %s, 'death', private.paris_today() - 1, %s, 'Décès (test d''échelle)',
                 %s)""",
            (org, client, evidence, world.tenant["staff"]),
        )
        blockers = one(
            conn, "select private.remittance_payout_blockers(%s, 'EUR', current_date)", (client,)
        )
        started = time.monotonic()
        conn.execute(loop)
        death_s = time.monotonic() - started
    print(
        f"\nV3: {BLOCKER_CALLS} blockers calls: no event {none_s:.2f}s, a death recorded"
        f" {death_s:.2f}s ({blockers})"
    )
    assert blockers, blockers
    assert death_s < BLOCKERS_S, death_s


# ---------------------------------------------------------------------------------------------
# Row 7: the hourly top-ups over 100 servicers
# ---------------------------------------------------------------------------------------------


def _owe(tenants: list[dict[str, Any]], amount: int) -> None:
    """Each servicer owes its dedicated account `amount` (+4679): a bank charge posted as the funds
    pass posts one (+4679 / -5120 ‖ +6270 / -4689, by ledger_post_set), in one transaction."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("select private.ledger_post_set_begin()")
        with conn.cursor() as cur:
            cur.executemany(
                """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type,
                  effective_date,
                     idempotency_key, client_organization_id, source_type, source_id, reason)
                   values (%s, %s, 'bank_fee', private.paris_today(), %s, null,
                     'bank_transaction', %s,
                           'Frais de la banque (test d''échelle)')""",
                [
                    (n + 1, t["servicer"], f"fee:closeout:{uuid.uuid4()}", str(uuid.uuid4()))
                    for n, t in enumerate(tenants)
                ],
            )
            cur.executemany(
                """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency,
                  bank_account_id)
                   values (%s, 1, 'due_to_servicer', %s, 'EUR', null), (%s, 2,
                     'client_money_cash', %s, 'EUR', %s),
                          (%s, 3, 'bank_fees', %s, 'EUR', null), (%s, 4, 'due_from_client_funds',
                            %s, 'EUR', null)""",
                [
                    (n + 1, amount, n + 1, -amount, t["bank"], n + 1, amount, n + 1, -amount)
                    for n, t in enumerate(tenants)
                ],
            )
        n = len(conn.execute("select * from private.ledger_post_set()").fetchall())
    assert n == len(tenants), n


def _hourly(tenants: list[dict[str, Any]]) -> tuple[float, list[float]]:
    """One `top_ups` message per servicer (as private.queue_top_ups sends them), the remittances
    queue drained by the worker's handler: the wall time, and each message's own."""
    with psycopg.connect(DB) as conn, conn.transaction():
        for t in tenants:
            conn.execute(
                "select pgmq.send('remittances', %s)",
                (Jsonb({"type": "top_ups", "organization_id": str(t["servicer"])}),),
            )
    times: list[tuple[str, float]] = []
    started = time.monotonic()
    _drain_remittances(times)
    return time.monotonic() - started, [s for k, s in times if k == "top_ups"]


def _top_up_state(tenants: list[dict[str, Any]]) -> dict[str, tuple[str, int, int]]:
    """Per servicer: its last outcome, its misses, its top-ups ordered."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select o.id::text, s.last_outcome, s.consecutive_misses,
                      (select count(*) from public.bank_transfer b
                       where b.organization_id = o.id and b.kind = 'top_up' and b.status =
                         'ordered')
               from public.organization o left join private.top_up_order_state s on
                 s.organization_id = o.id
               where o.id = any(%s::uuid[])""",
            ([str(t["servicer"]) for t in tenants],),
        ).fetchall()
    return {str(r[0]): (str(r[1]), int(r[2] or 0), int(r[3])) for r in rows}


def test_row_7_the_top_ups_over_100_servicers() -> None:
    """§8.3 row 7 [critic] F8: the top_ups job over 100 servicers, one transaction each: < 2 s in
    all; with one servicer's remit lock held by another session, the others complete and it is
    skipped (its miss recorded). « In all » is the job's: the handler's time summed over the 100
    messages. The wall time (printed) adds the queue consumer's own cost, a new connection per
    poll and per message (worker/src/collectoo_worker/runtime/queue.py), about 2 s for 100
    messages on this VM: not the job's, and the same for every queue
    (docs/benchmarks/remittances.md « M2c-7f-2, part 2 »)."""
    tenants = [bank_tenant() for _ in range(SERVICERS)]
    for t in tenants:
        own_account(t)
    _owe(tenants, 1_234)
    wall, each = _hourly(tenants)
    state = _top_up_state(tenants)
    assert set(state.values()) == {("done", 0, 1)}, state
    # again, one servicer's remit lock held by another session meanwhile
    _owe(tenants, 567)
    held, release = threading.Event(), threading.Event()
    skipped = str(tenants[0]["servicer"])

    def hold() -> None:
        with psycopg.connect(DB) as conn, conn.transaction():
            conn.execute("select pg_advisory_xact_lock(hashtext('remit:' || %s))", (skipped,))
            held.set()
            release.wait(60)

    holder = threading.Thread(target=hold)
    holder.start()
    try:
        assert held.wait(10)
        wall_held, _each_held = _hourly(tenants)
    finally:
        release.set()
        holder.join()
    state = _top_up_state(tenants)
    print(
        f"\nrow 7: {SERVICERS} servicers' top-ups in {wall:.2f}s (the messages' own"
        f" {sum(each):.2f}s, the"
        f" slowest {max(each):.3f}s); with one servicer's lock held {wall_held:.2f}s"
    )
    assert len(each) == SERVICERS, each
    assert sum(each) < TOP_UPS_S, (sum(each), wall)
    assert state.pop(skipped) == ("missed", 1, 1), skipped
    assert set(state.values()) == {("done", 0, 2)}, state


# ---------------------------------------------------------------------------------------------
# Row 8: the 5,000-payout funds pass, with the at-booking cover and the per-row run check
# ---------------------------------------------------------------------------------------------


def _batch_pass_functions(filed: dict[str, Any]) -> tuple[float, dict[str, tuple[int, float]]]:
    """test_debit_bookings_scale_integration's batch pass again (each PmtInf of the file debited as
    one batch line, the funds pass in one transaction rolled back, the statistics forgotten), run
    as the worker's role by the superuser's session with track_functions on: the functions' calls
    and times (the deferred checks forced first)."""
    org, tenant, payouts = filed["org"], filed["tenant"], filed["payouts"]
    frozen = (
        "public.bank_transfer",
        "public.transfer_file_item",
        "public.bank_line_booking",
        "public.client_advance",
        "public.remittance_run",
    )  # (scale-payouts' FROZEN)
    with (
        frozen_statistics(*frozen),
        psycopg.connect(ADMIN) as conn,
        conn.transaction(force_rollback=True),
    ):
        for t in frozen:
            forget_statistics(t)
        conn.execute("set local track_functions = 'all'")
        conn.execute("set local role postgres")
        st = _statement(conn, filed, "batch-functions.xml")
        for n, p in enumerate(payouts.payment_infos, start=1):
            conn.execute(
                """insert into public.bank_transaction (organization_id, bank_account_id,
                  statement_id, line_no,
                     dedup_key, direction, amount_minor, currency, booking_date, kind,
                       payment_info_id)
                   values (%s, %s, %s, %s, %s, 'debit', %s, 'EUR', private.paris_today(),
                     'batch_unsplit', %s)""",
                (org, tenant["bank"], st, n, f"t:{st}:{n}", p.ctrl_sum_minor, p.pmt_inf_id),
            )
        conn.execute(
            """update public.bank_statement set status = 'imported', from_date =
              private.paris_today(),
                 to_date = private.paris_today(), opening_booked_minor = 0, closing_booked_minor =
                   0, counts = '{}',
                 finished_at = now() where id = %s""",
            (st,),
        )
        started = time.monotonic()
        run_process_debits(conn, {"organization_id": org, "funds_after": None})
        conn.execute("set constraints all immediate")
        elapsed = time.monotonic() - started
        functions = _functions(conn)
        conn.execute("reset role")
    return elapsed, functions


@pytest.fixture(scope="module")
def payouts(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """scale-payouts' fixture: PAYOUTS clients' runs approved through the jobs, the file of their
    payouts written and downloaded (test_debit_bookings_scale_integration._file_payouts)."""
    return _file_payouts(tmp_path_factory, PAYOUTS, 0, "closeout-payouts")


def test_row_8_the_funds_pass_after_7a(payouts: dict[str, Any]) -> None:
    """§8.3 row 8 [critic] F17: the 5,000-payout funds-pass chunk of scale-payouts (24.0 s before
    7a) with the at-booking cover (cover_booked_run_reversals, one call for the chunk's runs) and
    the per-row run check (remittance_run_booked_cover: one deferred check per run set booked):
    ≤ 24 s x 1.1 — else V2 (the run check made statement-level). Then V3: the same pass again
    with track_functions, where the time goes (ledger_post_set's pooled-dimension lookup among
    it)."""
    elapsed, booked, reads, seq_reads, temp = _batch_pass(payouts)
    again_s, functions = _batch_pass_functions(payouts)
    print(
        f"\nrow 8: the {PAYOUTS}-member batch line's funds pass {elapsed:.1f}s (reads {reads},"
        f" by sequential"
        f" scans {seq_reads}, temporary bytes {temp}); again with track_functions {again_s:.1f}s:"
        f" {functions}"
    )
    assert booked == PAYOUTS
    assert elapsed <= FUNDS_PASS_S, elapsed
    calls, _ms = functions["run_booked_cover_check"]
    assert calls == PAYOUTS, functions  # one deferred check per run set booked
    assert functions["cover_booked_run_reversals"][0] == 1, functions
