"""M2c-6b-3b part 3 scale (needs `make up`; ADR-0014 « M2c-6b-3b part 3 »; founder question 3 of
« M2c-6b-3b part 2 », its default): the held rows' alert « remittance_breach_held » at volume.

SIZE (2,000) clients' runs are approved through the jobs (test_debit_bookings_scale_integration's
fixture: set-based clients, their collections imported, matched and allocated three weeks back) and
their payouts filed, written and downloaded (F). Then, in **one transaction with the switch on**
(rolled back: the switch is never committed on, as test_transfer_cancellation_scale_integration.py;
`held_runs`):

- time moved on: F dated back to X (as pgTAP's pg_temp.backdate), and a statement of X and its next
  business day Y, produced after them, imported with no debit (neither executed);
- F's cancellation asked (ops manager) and confirmed (an admin): its SIZE payouts x cancelled out
  of a downloaded file and re-issued (y), filed by « Générer le fichier » into F2, written (the
  job emulated, as pgTAP's pg_temp.write) and downloaded; half of the x then dated a business day
  earlier still, W (their e0, the window's start: two windows on one account);
- each run's lines held to L (as pgTAP's chain_prefix), the business day M after Y on no statement
  (nor W), and a statement from M's next business day to today showing the SIZE y debited today
  under their own end-to-end ids, after L: the debit job's funds pass books them, each run booked
  by its re-issue — the SIZE re-issued payouts whose R124-6 rows are held, the paying account's
  statements not covering [least(e0, L), L];
- the nightly checks, timed: every run raises « remittance_breach_held » naming M (and W for the
  half dated back), no row is written; the alert's rows are those of the standalone reading
  (private.remittance_breach_held, part 2's, one snapshot); the work counted by function
  (track_functions: calls are deterministic, whatever the machine) — the booked runs read once,
  the holds' facts once per run and date held to, the uncovered days once per account and window;
- review round 1 (cost-1, tests-ui-1), rolled back to a savepoint: the waiting lines' variant
  (`_waiting_variant`) — every window covered, the half dated back waiting on WAITING debits
  without our references of their x's amount: alerted with those lines, as the standalone reading
  says it, the others' rows written; timed (the holds' options asked 1,000 times: before
  private.transfer_line_offers released its working tables, the lock table filled);
- then the statements of W and M imported: the next nightly checks write each run's rows and raise
  no alert (timed too).

Prints the timings (docs/benchmarks/remittances.md « M2c-6b-3b part 3 »). BREACH_HELD_SIZE changes
the size; test_breach_held_integration.py runs the same scenario at a few runs in the db job."""

import os
import time
import uuid
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

import psycopg
import pytest
from integration_helpers import DB, as_user, one
from psycopg.conninfo import make_conninfo
from remittance_helpers import paris_today
from test_debit_bookings_scale_integration import _file_payouts
from test_transfer_cancellation_scale_integration import _backdate, _statement

from collectoo_worker.jobs.debits import run_process_debits

pytestmark = pytest.mark.integration
SIZE = int(os.environ.get("BREACH_HELD_SIZE", "2000"))
ADMIN = make_conninfo(DB, user="supabase_admin")
PARIS = ZoneInfo("Europe/Paris")
CODE = "remittance_breach_held"
# The nightly checks with SIZE held chained runs (2,000), measured on the 4-vCPU VM
# (docs/benchmarks/remittances.md « M2c-6b-3b part 3 »): 28.5 and 29.1 s before the dedups (two
# windows; the review's one-window case: 22 s at 2,001 runs), 12.8 and 13.0 s after; the night the
# rows are written 20.3 and 23.4 s before, 14.6 and 15.1 s after — on one fixture committed and
# measured again; this file alone right after a reset: 18.1 s both nights; after the payouts'
# bookings, as CI's scale-payouts job runs it: 13.4 and 12.6 s.
# Each bound keeps twice the worst run after the dedups (above plan §1.4's 5 s, which is for 5,000
# booked payouts: what remains is the booked branch's own chain reading, recorded in ADR-0014
# « M2c-6b-3b part 3 »); the dedups themselves are pinned by the calls, exactly.
NIGHTLY_S = 37.0
ROWS_NIGHT_S = 37.0
# review round 1 (cost-1): in the waiting lines' variant, each run of the half dated back waits on
# WAITING debits without our references of its x's amount
WAITING = 2
# ... and its night, measured on the same VM right after a reset (docs/benchmarks/remittances.md
# « M2c-6b-3b part 3 review fixes »): 52.8 s — the holds asking the options of each run's first
# line (1,000 calls of private.transfer_line_check, 11.5 s own; the chain's events 10.1 s; the
# lines that may be a debit 6.4 s), the alert itself a fraction of a second. The bound keeps twice
# it, as the others (a cliff, not the holds' own cost).
WAITING_NIGHT_S = 110.0
# the functions whose calls the dedups count
WATCHED = (
    "remittance_booked_chain_runs",
    "remittance_chain_hold_facts",
    "remittance_chain_paid",
    "remittance_run_late_lines",
    "statement_covers",
    "transfer_chain",
    "remittance_breach_held",
)


def filed_payouts(factory: pytest.TempPathFactory, size: int, label: str) -> dict[str, Any]:
    """size clients' runs approved, their payouts' file downloaded; the collections three weeks
    back (their deadline a week ahead: approved on time), before every day of `held_runs`."""
    with psycopg.connect(DB) as conn:
        day = one(
            conn,
            """select max(c.day) from public.business_calendar c
               where c.scope = 'FR-conservative' and not c.closed
                 and c.day <= private.paris_today() - 21""",
        )
    return _file_payouts(factory, size, 0, label, day=day)


@pytest.fixture(scope="module")
def filed(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    return filed_payouts(tmp_path_factory, SIZE, "held")


def _as(conn: psycopg.Connection[Any], user: str, sql: str, *params: Any) -> Any:
    """A command as `user` (aal2) inside the open transaction, then back to the admin role."""
    as_user(conn, user, "aal2")
    try:
        row = conn.execute(sql, params).fetchone()
    finally:
        conn.execute("reset role")
    return row[0] if row else None


def _business_days_back(conn: psycopg.Connection[Any], n: int) -> list[date]:
    """The n business days before today, the latest first."""
    return [
        r[0]
        for r in conn.execute(
            """select c.day from public.business_calendar c
               where c.scope = 'FR-conservative' and not c.closed and c.day < private.paris_today()
               order by c.day desc limit %s""",
            (n,),
        ).fetchall()
    ]


def _checks(
    conn: psycopg.Connection[Any], org: str
) -> tuple[str, float, dict[str, tuple[int, int]]]:
    """The servicer's nightly checks in the open transaction, timed; the calls and own time (ms)
    of each function they ran (track_functions, this transaction's)."""
    sql = "select funcname, calls, self_time::bigint from pg_stat_xact_user_functions"
    before = {str(r[0]): (int(r[1]), int(r[2])) for r in conn.execute(sql).fetchall()}
    started = time.monotonic()
    run = one(conn, "select private.run_payment_checks(%s)", (org,))
    elapsed = time.monotonic() - started
    after = {str(r[0]): (int(r[1]), int(r[2])) for r in conn.execute(sql).fetchall()}
    spent = {
        f: (c - before.get(f, (0, 0))[0], t - before.get(f, (0, 0))[1])
        for f, (c, t) in after.items()
        if c > before.get(f, (0, 0))[0]
    }
    return str(run["run_id"]), elapsed, spent


def _alerts(conn: psycopg.Connection[Any], run_id: str) -> list[tuple[Any, ...]]:
    return conn.execute(
        """select subject_id::text, currency, amount_minor, count, oldest_days, details
           from public.payment_check_result where run_id = %s and code = %s
           order by subject_id""",
        (run_id, CODE),
    ).fetchall()


def _waiting_statement(  # noqa: PLR0913 - a statement's identity, as _statement
    conn: psycopg.Connection[Any],
    tenant: dict[str, Any],
    *,
    day: date,
    opening: int,
    file_id: str,
    runs: list[str],
    created: datetime,
) -> None:
    """An imported camt.053 statement of the account for `day`, holding WAITING debits without
    our references of the amount of each run's x (a payout of F) and one credit of their total
    (the servicer's own transfer in): its closing is its opening, the balances follow."""
    st = one(
        conn,
        """insert into public.bank_statement (organization_id, bank_account_id, currency, format,
             file_name, file_sha256, size_bytes, storage_path)
           values (%s, %s, 'EUR', 'camt053', 's.xml', %s, 1, %s) returning id""",
        (tenant["servicer"], tenant["bank"], uuid.uuid4().hex * 2, f"test/{uuid.uuid4()}"),
    )
    conn.execute(
        "update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = %s",
        (st,),
    )
    conn.execute(
        """with d as (
             select t.id, k.k, t.amount_minor
             from public.bank_transfer t cross join generate_series(1, %(k)s) k (k)
             where t.transfer_file_id = %(file)s and t.kind = 'payout'
               and t.run_id = any(%(runs)s::uuid[])),
           l as (
             select 'debit' as direction, d.amount_minor, 'other_debit' as kind,
                    d.id::text as o, d.k
             from d
             union all
             select 'credit', (select sum(d.amount_minor) from d), 'own_transfer_in', 'z', 0)
           insert into public.bank_transaction (organization_id, bank_account_id, statement_id,
             line_no, dedup_key, direction, amount_minor, currency, booking_date, kind)
           select %(org)s, %(bank)s, %(st)s, l.n, 'c:' || %(st)s || ':' || l.n, l.direction,
                  l.amount_minor, 'EUR', %(day)s, l.kind
           from (select l.*, row_number() over (order by l.o, l.k) as n from l) l""",
        {"k": WAITING, "file": file_id, "runs": runs, "org": tenant["servicer"],
         "bank": tenant["bank"], "st": st, "day": day},
    )  # fmt: skip
    conn.execute(
        """update public.bank_statement set status = 'imported', from_date = %s, to_date = %s,
             opening_booked_minor = %s, closing_booked_minor = %s, counts = '{}',
             finished_at = clock_timestamp(),
             sections = jsonb_build_array(jsonb_build_object(
               'from_date', %s::date, 'to_date', %s::date, 'covers_from', %s::date,
               'covers_to', %s::date, 'opening_minor', %s::text, 'closing_minor', %s::text,
               'created_at', %s::text))
           where id = %s""",
        (day, day, opening, opening, day, day, day, day, opening, opening,
         created.isoformat(timespec="seconds"), st),
    )  # fmt: skip


def _waiting_variant(  # noqa: PLR0913 - the scenario's state
    conn: psycopg.Connection[Any],
    tenant: dict[str, Any],
    file_id: str,
    out: dict[str, Any],
    *,
    w: date,
    m: date,
    closing: int,
) -> None:
    """Review round 1 of M2c-6b-3b part 3 (cost-1, tests-ui-1), rolled back to a savepoint: the x
    requested for W (as pgTAP's chain_prefix sets x's date back; no command moves it), then W's and
    M's statements imported — W's holding WAITING debits without our references of x's amount for
    each run of the half dated back (`_waiting_statement`) —: every window covered; those runs wait
    on their lines (each may be their x's debit, and offers its booking), the others get their
    rows. The nightly checks timed; the alert as the standalone reading says it."""
    early = sorted(out["early"])
    org = str(tenant["servicer"])
    with conn.transaction(force_rollback=True):
        conn.execute("alter table public.bank_transfer disable trigger bank_transfer_guard")
        conn.execute(
            """update public.bank_transfer set requested_execution_date = %s
               where transfer_file_id = %s and kind = 'payout'""",
            (w, file_id),
        )
        conn.execute("alter table public.bank_transfer enable always trigger bank_transfer_guard")
        after = datetime.combine(w + timedelta(days=1), datetime.min.time(), PARIS)
        _waiting_statement(
            conn, tenant, day=w, opening=closing, file_id=file_id, runs=early,
            created=after + timedelta(hours=9),
        )  # fmt: skip
        _statement(
            conn, tenant, start=m, end=m, opening=closing, debits=[],
            created=datetime.combine(m + timedelta(days=1), datetime.min.time(), PARIS)
            + timedelta(hours=9),
        )  # fmt: skip
        run_id, out["waiting_s"], out["waiting_spent"] = _checks(conn, org)
        out["waiting_alerts"] = _alerts(conn, run_id)
        out["waiting_oracle"] = conn.execute(
            """select h.run_id::text, h.currency, h.amount_minor, h.line_count, h.oldest_days,
                      h.details
               from private.remittance_breach_held(%s, %s) h order by h.run_id""",
            (org, out["today"]),
        ).fetchall()
        out["waiting_rows"] = conn.execute(
            """select count(distinct b.run_id), count(*) filter (where b.blocked_reason is not null)
               from public.remittance_deadline_breach b where b.run_id = any(%s::uuid[])""",
            (out["runs"],),
        ).fetchone()


def held_runs(filed: dict[str, Any]) -> dict[str, Any]:  # noqa: PLR0915 - one scenario
    """The module's scenario (rolled back at its end): what it measured and read."""
    tenant, org, runs = filed["tenant"], filed["org"], filed["paid"]
    size = len(runs)
    today = paris_today()
    with psycopg.connect(DB) as conn:
        back = _business_days_back(conn, 12)
        last_to, closing0 = conn.execute(
            """select to_date, closing_booked_minor from public.bank_statement
               where bank_account_id = %s and status = 'imported'
               order by to_date desc, created_at desc limit 1""",
            (tenant["bank"],),
        ).fetchone() or (None, 0)
    # W, X: the earliest execution dates of the x (half of them W); Y: X's next business day; M:
    # the business day after Y; W and M on no statement; the lines held to L, two business days
    # after M; the debits of the re-issues today
    w, x, y, m, after_m, held_to = back[10], back[9], back[8], back[7], back[6], back[5]
    assert last_to is not None and last_to < w, (last_to, w)
    out: dict[str, Any] = {"w": w, "m": m, "held_to": held_to, "today": today, "runs": runs}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        conn.execute("set local track_functions = 'all'")
        conn.execute(
            "update private.feature_switch set enabled = true"
            " where key = 'downloaded_file_cancellation'"
        )
        # time moved on: F dated back to X, the statement of X and Y (no debit) produced after
        _backdate(conn, filed["file_id"], x)
        closing = _statement(
            conn, tenant, start=x, end=y, opening=int(closing0), debits=[],
            created=datetime.combine(m, datetime.min.time(), PARIS) + timedelta(hours=9),
        )  # fmt: skip
        assert closing == int(closing0)
        version = one(
            conn, "select version from public.transfer_file where id = %s", (filed["file_id"],)
        )
        asked = _as(
            conn, tenant["staff"],
            """select public.request_transfer_file_cancellation(%s, %s, %s,
                 'Fichier non déposé (test d''échelle)', 'not_uploaded') ->> 'status'""",
            str(uuid.uuid4()), filed["file_id"], version,
        )  # fmt: skip
        assert asked is not None
        confirming = time.monotonic()
        confirmed = _as(
            conn, tenant["admin"], "select public.confirm_transfer_file_cancellation(%s, %s, %s)",
            str(uuid.uuid4()), filed["file_id"], version,
        )  # fmt: skip
        out["confirm_s"] = time.monotonic() - confirming
        assert confirmed["status"] == "superseded", confirmed
        # « Générer le fichier »: the re-issues filed (nothing debited: none held), the job's
        # write emulated, the file downloaded, dated today
        generated = _as(
            conn, tenant["staff"], "select public.generate_transfer_file(%s, %s, null)",
            str(uuid.uuid4()), tenant["bank"],
        )  # fmt: skip
        assert generated["nb_of_txs"] == size and generated["held"] == [], generated["held"][:3]
        f2 = str(generated["file_id"])
        digest = one(conn, "select encode(sha256(convert_to(%s::text, 'UTF8')), 'hex')", (f2,))
        conn.execute(
            """select private.transfer_file_record(f.id, f.job_token, %s, 1234,
                 f.organization_id || '/' || f.id || '/' || f.number || '.xml', false,
                 'pain001-1', f.nb_of_txs, f.ctrl_sum_minor)
               from public.transfer_file f where f.id = %s""",
            (digest, f2),
        )
        _as(
            conn, tenant["staff"], "select public.transfer_file_download(%s, %s, false)", f2, digest
        )
        _backdate(conn, f2, today)
        # half of the x executed from W (their item dated back once more): their runs' window
        # starts at W, the others' at X
        conn.execute(
            "alter table public.transfer_file_item disable trigger transfer_file_item_append_only"
        )
        early = [
            str(r[0])
            for r in conn.execute(
                """update public.transfer_file_item i set execution_date = %s
                   from (select q.id, q.run_id from public.bank_transfer q
                         where q.transfer_file_id = %s and q.kind = 'payout'
                         order by q.id limit %s) t
                   where i.transfer_id = t.id and i.file_id = %s
                   returning t.run_id""",
                (w, filed["file_id"], size // 2, filed["file_id"]),
            ).fetchall()
        ]
        conn.execute(
            "alter table public.transfer_file_item"
            " enable always trigger transfer_file_item_append_only"
        )
        out["early"] = set(early)
        reissued = conn.execute(
            """select y.end_to_end_id, y.amount_minor from public.bank_transfer y
               join public.bank_transfer x on x.id = y.replaces_transfer_id
               where x.transfer_file_id = %s and x.kind = 'payout' and x.status = 'cancelled'
                 and y.transfer_file_id = %s
               order by y.end_to_end_id""",
            (filed["file_id"], f2),
        ).fetchall()
        assert len(reissued) == size
        # the runs' collections held to L (as pgTAP's chain_prefix): late at today's debits
        conn.execute("alter table public.remittance_line disable trigger remittance_line_guard")
        conn.execute(
            """update public.remittance_line set latest_execution_date = %s, deadline = %s
               where run_id = any(%s::uuid[])""",
            (held_to, back[3], runs),
        )
        conn.execute(
            "alter table public.remittance_line enable always trigger remittance_line_guard"
        )
        # M on no statement; the next one from M's next business day to today: the re-issues
        # debited today under their own ids
        _statement(
            conn, tenant, start=after_m, end=today, opening=closing,
            debits=[(str(e), int(a)) for e, a in reissued],
            created=datetime.now(PARIS), kind="transfer_out",
        )  # fmt: skip
        booking = time.monotonic()
        conn.execute("set role postgres")  # the worker's role (its working tables are its own)
        try:
            summary = run_process_debits(conn, {"organization_id": org, "funds_after": None})
        finally:
            conn.execute("reset role")
        out["book_s"] = time.monotonic() - booking
        out["booked"] = conn.execute(
            """select (select count(*) from public.remittance_run
                       where id = any(%s::uuid[]) and status = 'booked'),
                      (select count(*) from public.remittance_deadline_breach
                       where run_id = any(%s::uuid[]))""",
            (runs, runs),
        ).fetchone()
        out["summary"] = summary

        # the nightly checks: every run held, alerted; no row
        held_run, out["nightly_s"], out["spent"] = _checks(conn, org)
        out["alerts"] = _alerts(conn, held_run)
        started = time.monotonic()
        out["oracle"] = conn.execute(
            """select h.run_id::text, h.currency, h.amount_minor, h.line_count, h.oldest_days,
                      h.details
               from private.remittance_breach_held(%s, %s) h order by h.run_id""",
            (org, today),
        ).fetchall()
        out["oracle_s"] = time.monotonic() - started
        out["written"] = one(
            conn,
            "select count(*) from public.remittance_deadline_breach where run_id = any(%s::uuid[])",
            (runs,),
        )
        # review round 1 (dt3-race-alert-for-run-paid-on-time, its default): what re-reading each
        # alerted run's chain paid date in the results' statement would cost (not done; timed only)
        started = time.monotonic()
        one(
            conn,
            """select count(c.paid_on) from public.remittance_run r
               cross join lateral private.remittance_chain_paid(r.transfer_id) c
               where r.id = any(%s::uuid[])""",
            (runs,),
        )
        out["recheck_s"] = time.monotonic() - started
        _waiting_variant(conn, tenant, filed["file_id"], out, w=w, m=m, closing=closing)
        # W's and M's statements imported (the balances follow): the next night writes every row
        for day in (w, m):
            _statement(
                conn, tenant, start=day, end=day, opening=closing, debits=[],
                created=datetime.combine(day + timedelta(days=1), datetime.min.time(), PARIS)
                + timedelta(hours=9),
            )  # fmt: skip
        written_run, out["written_s"], out["written_spent"] = _checks(conn, org)
        out["after_rows"] = conn.execute(
            """select (select count(*) from public.remittance_deadline_breach
                       where run_id = any(%s::uuid[])),
                      (select count(distinct run_id) from public.remittance_deadline_breach
                       where run_id = any(%s::uuid[])),
                      (select count(*) from public.payment_check_result
                       where run_id = %s and code = %s)""",
            (runs, runs, written_run, CODE),
        ).fetchone()
        out["lines"] = one(
            conn,
            """select count(*) from public.remittance_line
               where run_id = any(%s::uuid[]) and amount_minor > 0 and not released""",
            (runs,),
        )
    with psycopg.connect(DB) as conn:
        assert one(conn, "select private.switch_on('downloaded_file_cancellation')") is False
    return out


def assert_held(out: dict[str, Any], size: int) -> None:
    """What every size of the scenario holds to: each run held, alerted once with its days; the
    alert as the standalone reading says it; the rows written once the days are covered; the
    work counted."""
    alerts, m, w = out["alerts"], out["m"].isoformat(), out["w"].isoformat()
    assert out["booked"] == (size, 0), (out["booked"], out["summary"])
    assert out["written"] == 0
    assert len(alerts) == size, len(alerts)
    # the half dated back to W: W and M named; the others: M alone
    named = {a[0]: (tuple(a[5]["uncovered_days"]), a[5]["uncovered_count"]) for a in alerts}
    assert {named[r] for r in out["early"]} == {((w, m), 2)}, alerts[0]
    assert {v for r, v in named.items() if r not in out["early"]} == {((m,), 1)}, alerts[-1]
    assert {a[4] for a in alerts} == {(out["today"] - out["held_to"]).days}
    # the alert as the standalone reading (part 2's one-snapshot rule) says it, run by run
    assert alerts == out["oracle"], next(
        (a, o) for a, o in zip(alerts, out["oracle"], strict=False) if a != o
    )
    # the next night, W and M covered: every run's rows written (one per held line), no alert
    assert out["after_rows"] == (out["lines"], size, 0), (out["after_rows"], out["lines"])
    # the work, deterministic: the booked chained runs read once by the checks, the holds' facts
    # once per run and date held to (here one), the late lines twice per run (the runs, their
    # rows), the uncovered days of each window (two on the account) once — not once per run
    calls = {f: c for f, (c, _) in out["spent"].items() if f in WATCHED}
    assert calls.get("remittance_booked_chain_runs") == 1, calls
    assert calls.get("remittance_chain_hold_facts") == size, calls
    assert calls.get("remittance_run_late_lines") == 2 * size, calls
    assert calls.get("statement_covers", 0) <= size + 2 * 7, calls
    # review round 1 (cost-1, tests-ui-1): the waiting lines' variant — every window covered, the
    # half dated back alerted with WAITING lines each and no day, as the standalone reading says it;
    # the others' rows written
    waiting = out["waiting_alerts"]
    assert waiting == out["waiting_oracle"], next(
        (a, o) for a, o in zip(waiting, out["waiting_oracle"], strict=False) if a != o
    )
    assert {a[0] for a in waiting} == out["early"], (len(waiting), len(out["early"]))
    assert {
        (tuple(a[5]["uncovered_days"]), a[5]["waiting_count"], len(a[5]["waiting"]),
         a[5]["balance_break"])
        for a in waiting
    } == {((), WAITING, WAITING, False)}, waiting[0]  # fmt: skip
    assert out["waiting_rows"] == (size - len(out["early"]), 0), out["waiting_rows"]


def test_two_thousand_re_issued_payouts_held_by_a_missing_statement_day(
    filed: dict[str, Any],
) -> None:
    out = held_runs(filed)
    top = sorted(out["spent"].items(), key=lambda s: -s[1][1])[:8]
    print(
        f"\n{SIZE} payouts cancelled out of a downloaded file and re-issued, their runs booked by"
        f" the re-issues' debits and held by missing statement days: confirmation"
        f" {out['confirm_s']:.2f}s; the funds pass {out['book_s']:.1f}s; nightly checks"
        f" {out['nightly_s']:.2f}s ({len(out['alerts'])} alerts; the functions' calls and own ms:"
        f" {top}); the standalone reading {out['oracle_s']:.2f}s; once the days are imported,"
        f" nightly checks {out['written_s']:.2f}s ({out['after_rows'][0]} rows written; calls"
        f" {sorted(out['written_spent'].items(), key=lambda s: -s[1][1])[:5]}); the waiting lines'"
        f" variant {out['waiting_s']:.2f}s ({len(out['waiting_alerts'])} alerts, {WAITING} lines"
        f" each; calls {sorted(out['waiting_spent'].items(), key=lambda s: -s[1][1])[:5]}); one"
        f" chain paid date per run read again {out['recheck_s']:.2f}s"
    )
    assert_held(out, SIZE)
    # plan §1.4's nightly bound, held chained runs: see NIGHTLY_S
    assert out["nightly_s"] < NIGHTLY_S, out["nightly_s"]
    assert out["written_s"] < ROWS_NIGHT_S, out["written_s"]
    assert out["waiting_s"] < WAITING_NIGHT_S, out["waiting_s"]
