"""M2c-7a's CI round on main (needs `make up`; ADR-0014 « M2c-7a — CI round (main) »): the covers of
a booked run's reversed lines, the check of a run set booked and the nightly's booked runs read
each run's lines by the run's key, whatever the statistics.

CI run 45206756541 (the scale job, the push of 245296d to main): in
test_transfer_line_scale_integration.py, booking the 500-member lot short of one read 25,202,495
rows of remittance_line (about 50,500 per member: every live line of the table) and took 6.2 s.
private.cover_booked_run_reversals, new in M2c-7a and run at each payout booking, read each booked
run's lines through a lateral subquery keyed by the run and filtered on `not released` and the
line's kind: when the last analyse of remittance_line saw two runs holding every line (the 50,000-
line run cancelled, its lines released, and its re-run), a probe of the run's key was priced at
half the table, and a bitmap of the whole partial index remittance_line_live_uq (whose predicate
`not released` the filter implies) cheaper — once per member. The same read sat in the deferred
check of a run set booked (private.run_booked_cover_check: its generic plan) and in the nightly's
booked runs (private.run_advance_checks). Each now reads the run's lines by the run's key alone,
its conditions applied outside the fence, so no partial index can stand for the key.

Deterministic here, in the db job: a lot of LOT payouts made through the jobs; in each test's
rolled-back transaction, two runs' worth of planted lines (PLANTED each, one run's released: no
trigger, no foreign key — they belong to no run, entry or client of ours) and remittance_line
analysed with run_id's n_distinct pinned at 2 — the statistics CI's scale order left. Then the lot
short of one member booked as the API's session would book it; and (the second test) one member's
collection reversed while its run is in flight, the same booking under generic plans (its cover
posted at the booking), and the night's advance checks: the rows read from remittance_line
(pg_stat_xact_user_tables), a few per member or per run booked, never the planted lines once per
member. On 245296d's bodies: 111,761 rows for the booking (the bound 120), 243,779 under generic
plans, 111,717 for the advance checks (the bound 160).

A second 7a read had the same exposure: the double payout's advance (private.transfer_line_post,
[critic] F10) reads the single mandate of its transfer's run's lines once per unplanned_payout
part, and that function had no enable_seqscan off. The third test has the bank debit the lot's
PmtInf twice (the cancellation switch off): the second line's parts are the members' unplanned
payouts, each with its advance. On 7a's body: 240,588 rows, 12 sequential scans of remittance_line
(one per member); fixed: 24, none — each advance still on the mandate its run's lines hold."""

from __future__ import annotations

import uuid
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN
from integration_helpers import one
from psycopg.types.json import Jsonb
from test_debit_bookings_scale_integration import _file_payouts, _statement
from test_transfer_line_scale_integration import REASON, _as_ops, _insert_short_line

pytestmark = pytest.mark.integration
LOT = 12
# the planted lines per run (two runs): CI's two 50,000-line runs, scaled down
PLANTED = 10_000
# remittance_line rows the booking may read per member of the lot (the scale file's bound: the
# locks, the preview's and the command's checks, the posting, the covers and the run's check)
PER_MEMBER = 10
# the advance checks' rows per run booked (each run's lines, read once by the full pass), plus a
# slack for the servicer's other reads
PER_RUN = 5
SLACK = 100


@pytest.fixture(scope="module")
def lot(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    return _file_payouts(tmp_path_factory, LOT, 0, "cover-reads")


def _plant(conn: psycopg.Connection[Any]) -> None:
    """Two runs holding almost every line of remittance_line, one of them released, and the table
    analysed with run_id's n_distinct pinned at 2 — in `conn`'s transaction only (the superuser's:
    rolled back with it). The lines are written without their triggers (the insert guard reads
    each run and entry: these belong to none) and without foreign keys (replica role)."""
    conn.execute("set local session_replication_role = replica")
    conn.execute("alter table public.remittance_line disable trigger remittance_line_insert_guard")
    conn.execute(
        """insert into public.remittance_line (run_id, line_no, organization_id,
             client_organization_id, currency, ledger_entry_id, kind, effective_date, posted_at,
             amount_minor, commission_state, released, released_at)
           select r.id, g, r.org, r.client, 'EUR', gen_random_uuid(), 'allocation',
                  private.paris_today(), now(), 100, 'none', r.released,
                  case when r.released then now() end
           from (values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), true),
                        (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), false))
                r (id, org, client, released)
           cross join generate_series(1, %s) g""",
        (PLANTED,),
    )
    conn.execute(
        "alter table public.remittance_line enable always trigger remittance_line_insert_guard"
    )
    conn.execute("set local session_replication_role = origin")
    conn.execute("alter table public.remittance_line alter column run_id set (n_distinct = 2)")
    conn.execute("analyze public.remittance_line")


def _lines_read(conn: psycopg.Connection[Any]) -> int:
    """This transaction's rows of remittance_line so far, by index or by a sequential scan."""
    return int(
        one(
            conn,
            """select coalesce(sum(coalesce(idx_tup_fetch, 0) + seq_tup_read), 0)
               from pg_stat_xact_user_tables where relid = 'public.remittance_line'::regclass""",
        )
    )


def _seq_scans(conn: psycopg.Connection[Any]) -> int:
    """This transaction's sequential scans of remittance_line so far."""
    return int(
        one(
            conn,
            """select coalesce(sum(seq_scan), 0)
               from pg_stat_xact_user_tables where relid = 'public.remittance_line'::regclass""",
        )
    )


def _book(
    conn: psycopg.Connection[Any], lot: dict[str, Any], line: str, kind: str = "payout"
) -> tuple[list[dict[str, Any]], int, int]:
    """The lot's line booked as the API's session books it (options, then the command), its single
    proposal's parts all of `kind`: the bookings, and the remittance_line rows and sequential scans
    the command read. The session's role reset after."""
    _as_ops(conn, lot["tenant"])
    opts = one(conn, "select public.transfer_line_options(%s)", (line,))
    assert (opts["class"], opts["member_count"], opts["refusal"]) == ("B", LOT, None), opts
    (proposal,) = opts["proposals"]
    assert {p["kind"] for p in proposal["request"]} == {kind}, proposal["request"]
    before, scans = _lines_read(conn), _seq_scans(conn)
    res = one(
        conn,
        "select public.book_transfer_line(%s, %s, %s, %s, %s)",
        (
            str(uuid.uuid4()),
            line,
            Jsonb(proposal["request"]),
            proposal["preview"]["expected_text"],
            REASON,
        ),
    )
    read, scans = _lines_read(conn) - before, _seq_scans(conn) - scans
    conn.execute("reset role")
    return list(res["bookings"]), read, scans


def _reverse_one(conn: psycopg.Connection[Any], lot: dict[str, Any], left: str) -> list[str]:
    """« Désimputer » (ops, as the API's session) of one member's collection while its run is in
    flight (sent, its payout in the downloaded file): the booking covers that line's reversal
    (private.cover_booked_run_reversals) and the run's check reads it (D2, D3). The reversals."""
    payment, account = conn.execute(
        """select l.payment_id, l.account_id from public.remittance_line l
           join public.remittance_run r on r.id = l.run_id
           join public.bank_transfer t on t.id = r.transfer_id
           where r.id = any(%s::uuid[]) and t.end_to_end_id <> %s and not l.released
             and l.kind = 'allocation'
           order by r.id, l.line_no limit 1""",
        (lot["paid"], left),
    ).fetchone() or (None, None)
    entries = one(
        conn,
        """select array_agg(x.id order by x.id) from public.ledger_entry x
           where x.payment_id = %s and x.entry_type = 'allocation' and x.account_id = %s
             and not exists (select 1 from public.ledger_entry r
                             where r.reverses_entry_id = x.id)""",
        (payment, account),
    )
    _as_ops(conn, lot["tenant"])
    out = one(
        conn,
        "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        (str(uuid.uuid4()), payment, account, entries, "Imputation erronée (test)"),
    )
    conn.execute("reset role")
    assert out["advances"] == [], out  # not remitted yet: covered at the booking
    return [str(r) for r in out["reversals"]]


def test_a_lot_is_booked_reading_each_runs_lines_by_key_whatever_the_statistics(
    lot: dict[str, Any],
) -> None:
    """CI's failure, at LOT members: before the fix, each member's run read every planted live
    line (PLANTED rows a member, by a bitmap of remittance_line_live_uq)."""
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn)
        conn.execute("set role postgres")
        line, _left = _insert_short_line(conn, lot)
        conn.execute("reset role")
        bookings, read, _scans = _book(conn, lot, line)
    booked = len(bookings)
    print(
        f"\n{LOT}-member lot short of one, {2 * PLANTED} lines planted in two runs: {booked}"
        f" bookings, {read} remittance_line rows read"
    )
    assert booked == LOT - 1
    assert read <= PER_MEMBER * LOT, read


def test_the_runs_booked_and_the_night_after_read_by_key_under_generic_plans(
    lot: dict[str, Any],
) -> None:
    """The same booking with every PL/pgSQL statement planned generically (plan_cache_mode): the
    check of each run set booked (private.run_booked_cover_check, fired by ledger_check_now) reads
    its run's lines by key — before the fix, its generic plan read every planted live line per run.
    One member's collection reversed while its run was in flight, so the booking covers it and the
    run's check reads it: « R is a live line of that run » by R's own key (before the fix, under
    these statistics, a hash of every planted live line, once per statement or per run). Then the
    night's checks for the servicer, and its advance checks again on that check run
    (private.run_advance_checks, the servicer's first night: the full pass over its booked runs):
    each run booked read by key — before the fix, every planted live line per run booked."""
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn)
        conn.execute("set role postgres")
        line, left = _insert_short_line(conn, lot)
        conn.execute("reset role")
        reversals = _reverse_one(conn, lot, left)
        conn.execute("set local plan_cache_mode = force_generic_plan")
        bookings, read, _scans = _book(conn, lot, line)
        booked = len(bookings)
        covered = one(
            conn,
            """select count(*) from public.client_advance
               where cause_entry_id = any(%s::uuid[]) and cause = 'remitted_reversal'""",
            (reversals,),
        )
        conn.execute("set role postgres")  # the worker's role, as the nightly job runs
        before = _lines_read(conn)
        run = one(conn, "select private.run_payment_checks(%s)", (lot["org"],))
        night = _lines_read(conn) - before
        before = _lines_read(conn)
        conn.execute("select private.run_advance_checks(%s, %s)", (run["run_id"], lot["org"]))
        advance = _lines_read(conn) - before
        conn.execute("reset role")
    print(
        f"\n{LOT}-member lot short of one, generic plans, {2 * PLANTED} lines planted: {booked}"
        f" bookings, {read} remittance_line rows read; the night's checks {night} rows, its"
        f" advance checks {advance} ({len(reversals)} reversed and covered: {covered};"
        f" {run['by_code']})"
    )
    assert booked == LOT - 1
    assert covered == len(reversals) > 0, (covered, reversals)  # the reversed line covered
    assert run["violations"] == 0, run  # I23 holds: no remitted_reversal_uncovered
    assert read <= PER_MEMBER * LOT, read
    assert advance <= PER_RUN * LOT + SLACK, advance


def _insert_whole_line(conn: psycopg.Connection[Any], lot: dict[str, Any], name: str) -> str:
    """The file's PmtInf debited whole as one batch line, in `conn`'s transaction: the line."""
    (pmt,) = lot["payouts"].payment_infos
    st = _statement(conn, lot, name)
    line = one(
        conn,
        """insert into public.bank_transaction (organization_id, bank_account_id,
             statement_id, line_no, dedup_key, direction, amount_minor, currency,
             booking_date, kind, payment_info_id)
           values (%s, %s, %s, 1, %s, 'debit', %s, 'EUR', private.paris_today(),
                   'batch_unsplit', %s) returning id""",
        (lot["org"], lot["tenant"]["bank"], st, f"t:{st}:1", pmt.ctrl_sum_minor, pmt.pmt_inf_id),
    )
    conn.execute(
        """update public.bank_statement set status = 'imported',
             from_date = private.paris_today(), to_date = private.paris_today(),
             opening_booked_minor = 0, closing_booked_minor = 0, counts = '{}',
             finished_at = now() where id = %s""",
        (st,),
    )
    return str(line)


def _single_mandate(mandates: list[str | None]) -> str | None:
    """[critic] F10: the single mandate of a run's lines (released or not), none when they hold
    several, any line holds none, or there is no line."""
    held = set(mandates)
    return mandates[0] if len(held) == 1 and None not in held else None


def _second_line(conn: psycopg.Connection[Any], run: str, mandate: str | None) -> None:
    """(M2c-7c-1, ADR-0014 7a CI round « Left open ») A second line in a booked run of the lot, on
    `mandate` (another member's) or on none, after the run's own: written as _plant writes its
    lines (no trigger, no foreign key: the line names no entry of ours), in `conn`'s transaction."""
    conn.execute("set local session_replication_role = replica")
    conn.execute("alter table public.remittance_line disable trigger remittance_line_insert_guard")
    conn.execute(
        """insert into public.remittance_line (run_id, line_no, organization_id,
             client_organization_id, currency, ledger_entry_id, kind, mandate_id, effective_date,
             posted_at, amount_minor, commission_state)
           select r.id, 99, r.organization_id, r.client_organization_id, r.currency,
                  gen_random_uuid(), 'allocation', %s, private.paris_today(), now(), 100, 'none'
           from public.remittance_run r where r.id = %s""",
        (mandate, run),
    )
    conn.execute(
        "alter table public.remittance_line enable always trigger remittance_line_insert_guard"
    )
    conn.execute("set local session_replication_role = origin")


def test_a_lot_debited_twice_reads_each_advances_run_by_key(lot: dict[str, Any]) -> None:
    """The bank debits the lot's PmtInf twice (the cancellation switch off): the first line books
    the lot's payouts, the second's options propose each member as an unplanned payout of its
    booked transfer (P = 0), each with its double_payout advance. The advance's mandate
    (private.transfer_line_post, [critic] F10) is the single mandate of its transfer's run's
    lines, read once per part — before the fix, under these statistics, by a sequential scan of
    remittance_line per member (transfer_line_post had no enable_seqscan off: every planted line
    once per member). Each advance still gets the mandate its run's lines hold.

    (M2c-7c-1, the 7a CI round's « Left open ») One member's run then holds a second line on
    another member's mandate, and another's a line on no mandate: those two advances are on no
    mandate (several mandates; a line without one), the others keep their run's — the two
    mutants of the mandate expression, « count(q.mandate_id) = count(*) » dropped and
    « count(distinct q.mandate_id) = 1 » dropped, each give one of those two the run's first
    line's mandate."""
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn)
        conn.execute("set role postgres")
        first = _insert_whole_line(conn, lot, "first.xml")
        conn.execute("reset role")
        paid, _read, _scans = _book(conn, lot, first)
        runs = conn.execute(
            """select r.id::text, (select l.mandate_id::text from public.remittance_line l
                                   where l.run_id = r.id order by l.line_no limit 1)
               from public.remittance_run r where r.id = any(%s::uuid[]) order by r.id""",
            (lot["paid"],),
        ).fetchall()
        (several, other_mandate), (no_mandate, _m) = runs[0], runs[1]
        assert runs[2][1] is not None and runs[2][1] != other_mandate, runs
        _second_line(conn, several, runs[2][1])  # a second mandate in the run
        _second_line(conn, no_mandate, None)  # a line on no mandate
        conn.execute("set role postgres")
        second = _insert_whole_line(conn, lot, "second.xml")
        conn.execute("reset role")
        twice, read, scans = _book(conn, lot, second, "unplanned_payout")
        advances = conn.execute(
            """select a.transfer_id::text, a.mandate_id::text,
                      array(select q.mandate_id::text from public.remittance_line q
                            where q.run_id = x.run_id order by q.line_no), x.run_id::text
               from public.client_advance a
               join public.bank_transfer x on x.id = a.transfer_id
               where a.bank_transaction_id = %s and a.cause = 'double_payout'""",
            (second,),
        ).fetchall()
    print(
        f"\n{LOT}-member lot debited twice, {2 * PLANTED} lines planted in two runs:"
        f" {len(paid)} payouts, then {len(twice)} unplanned payouts"
        f" ({sum(1 for b in twice if int(b.get('advance_minor') or 0) > 0)} with an advance):"
        f" {read} remittance_line rows read, {scans} sequential scans"
    )
    assert len(paid) == LOT
    assert len(twice) == LOT
    assert all(int(b.get("advance_minor") or 0) > 0 for b in twice), twice
    assert scans == 0, scans
    assert read <= PER_MEMBER * LOT, read
    # each advance on the single mandate its run's lines hold; the run of two mandates and the run
    # with a line on none: no mandate (7c-1)
    assert len(advances) == LOT, advances
    for transfer, mandate, lines, run in advances:
        if run in (several, no_mandate):
            assert len(lines) == 2 and lines[0] is not None, (transfer, lines)
            assert _single_mandate(lines) is None and mandate is None, (transfer, mandate, lines)
            continue
        assert lines and _single_mandate(lines) is not None, (transfer, lines)
        assert mandate == _single_mandate(lines), (transfer, mandate, lines)
    assert {run for *_x, run in advances} >= {several, no_mandate}
