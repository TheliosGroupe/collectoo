"""M2c-6b-1 review round 3 (M3; round 2's P1): the funds pass's re-check of a batch line is linear
in time and memory whatever its size (needs `make up`; ARCHITECTURE §4, ADR-0014 « M2c-6b-1
review fixes »). Not a scale test: it runs in the `db` job, in a few seconds.

One batch line of N sweeps (one PmtInf of a downloaded file of a dedicated account, every member
in_file: the batch rule accepts it) and, before it, the individual debit of its first member
(line A): the job's rows for both, re-checked by private.post_bank_bookings in one call — every
rule runs over the N rows, then « a transfer booked once per call » refuses the batch line's row
of that first member (A comes first), so the whole batch line is left to ops and only A is
posted. Everything is written in one transaction, rolled back.

Every statement of the call is read from its plan (auto_explain JSON, rows and buffers, no
timing): none writes a temporary file (work_mem pinned at 4 MB, the local stack's) and none
handles more than a few rows per row of the job. Round 2 read the line's PmtInf once per row of
the line for its keys (N² rows sorted for a distinct: 16 million rows, ~770 MB of temporary
files at 2,000 members) and grouped each line's N rows by the array of its N transfer ids (an
N² sort to disk: ~620 MB at 2,000 members); « one kind per line » and « a transfer booked once
per call » compared every pair of the line's rows (4 and 8 million join-filter rows)."""

import random
import uuid
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN, explained, statement, temp_blocks, work

from collectoo_worker.synth.ids import iban_fr

pytestmark = pytest.mark.integration
MEMBERS = 2_000
# rows a statement of the call may handle per row of the job (measured, 2026-11-12: the batch
# rule 18, the keys 16, the facts 11, every other statement fewer); n² is 2,000 a row here
ROWS_PER_ROW = 40
SLACK = 2_000  # the locks' and the posting's few rows (one sweep), the reference tables


def _batch_world(conn: psycopg.Connection[Any], n: int, line_a: bool = True) -> dict[str, Any]:
    """A servicer, its dedicated and own accounts, a downloaded file holding one PmtInf of n
    sweeps (in_file), its batch line and the first sweep's own debit line (A) on one statement;
    the job's rows (A first) in pg_temp._bank_booking. Without `line_a`: the batch line alone,
    and the job's rows its n members (the batch rule accepts it: every member is posted)."""
    rng = random.Random(f"batch-rules-{uuid.uuid4()}")
    org, funds, own = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    funds_iban, own_iban = iban_fr(rng), iban_fr(rng)
    file_id, statement_id = uuid.uuid4(), uuid.uuid4()
    line_a_id, line_b = uuid.uuid4(), uuid.uuid4()
    number = f"TF-2099-{rng.randint(10**8, 10**9 - 1)}"
    pmt_inf = f"{number}-1"
    amounts = [1_000 + k for k in range(n)]
    conn.execute(
        "insert into public.organization (id, kind, legal_name) values (%s, 'servicer', 'Lot SAS')",
        (org,),
    )
    conn.execute(
        """insert into public.bank_account (id, organization_id, purpose, iban, currency, label,
             feed, opened_on)
           values (%s, %s, 'client_funds', %s, 'EUR', 'Fonds', 'camt053', '2026-01-01'),
                  (%s, %s, 'own', %s, 'EUR', 'Propre', null, '2026-01-01')""",
        (funds, org, funds_iban, own, org, own_iban),
    )
    conn.execute(
        """insert into public.transfer_file (id, organization_id, debtor_bank_account_id, number,
             msg_id, pain_version, created_at_iso, initiating_party, debtor_name, debtor_iban,
             nb_of_txs, ctrl_sum_minor, first_execution_date, last_execution_date, cash_check)
           values (%s, %s, %s, %s, %s, 'pain.001.001.09', '2026-11-12T10:00:00+01:00', 'Lot SAS',
                   'Lot SAS', %s, %s, %s, private.paris_today(), private.paris_today(), '{}')""",
        (file_id, org, funds, number, f"M{number}", funds_iban, n, sum(amounts)),
    )
    conn.execute(
        """update public.transfer_file set status = 'generated', file_sha256 = repeat('a', 64),
             size_bytes = 1, storage_path = 'probe/' || id, generated_at = now() where id = %s""",
        (file_id,),
    )
    conn.execute(
        """update public.transfer_file set status = 'downloaded', download_count = 1,
             first_downloaded_at = now() where id = %s""",
        (file_id,),
    )
    conn.execute("drop table if exists pg_temp._members")  # (a second world in the transaction)
    conn.execute(
        """create temp table _members on commit drop as
           select k, gen_random_uuid() as id,
                  'SWP' || upper(substr(md5(gen_random_uuid()::text), 1, 12)) as e2e,
                  (%s::bigint[])[k] as amount
           from generate_series(1, %s) k""",
        (amounts, n),
    )
    conn.execute(
        """insert into public.bank_transfer (id, organization_id, kind, debtor_bank_account_id,
             creditor_bank_account_id, currency, amount_minor, payee_name, payee_iban,
             end_to_end_id, requested_execution_date)
           select m.id, %s, 'sweep', %s, %s, 'EUR', m.amount, 'Lot SAS', %s, m.e2e,
                  private.paris_today()
           from _members m""",
        (org, funds, own, own_iban),
    )
    conn.execute(
        """update public.bank_transfer t set status = 'in_file', transfer_file_id = %s
           from _members m where t.id = m.id""",
        (file_id,),
    )
    conn.execute(
        """insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id,
             pmt_inf_id, execution_date)
           select %s, m.k, m.id, %s, %s, private.paris_today() from _members m""",
        (file_id, org, pmt_inf),
    )
    conn.execute(
        """insert into public.bank_statement (id, organization_id, bank_account_id, currency,
             format, file_name, file_sha256, size_bytes, storage_path)
           values (%s, %s, %s, 'EUR', 'camt053', 'lot.xml', md5(%s::text) || md5(%s::text), 1,
                   'probe/' || %s)""",
        (statement_id, org, funds, statement_id, org, statement_id),
    )
    conn.execute(
        "update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = %s",
        (statement_id,),
    )
    conn.execute(
        """insert into public.bank_transaction (id, organization_id, bank_account_id,
             statement_id, line_no, dedup_key, direction, amount_minor, currency, booking_date,
             kind, end_to_end_id, payment_info_id, counterparty_iban)
           select * from (values
             (%s::uuid, %s::uuid, %s::uuid, %s::uuid, 1, 't:' || %s, 'debit', %s::bigint, 'EUR',
              private.paris_today(), 'transfer_out', (select e2e from _members where k = 1),
              null::text, %s),
             (%s, %s, %s, %s, 2, 't:' || %s, 'debit', %s, 'EUR', private.paris_today(),
              'batch_unsplit', null, %s, null)) v
           where %s or v.column1 <> %s""",
        (line_a_id, org, funds, statement_id, line_a_id, amounts[0], own_iban,
         line_b, org, funds, statement_id, line_b, sum(amounts), pmt_inf, line_a, line_a_id),
    )  # fmt: skip
    conn.execute(
        """update public.bank_statement set status = 'imported',
             from_date = private.paris_today(), to_date = private.paris_today(),
             opening_booked_minor = 0, closing_booked_minor = 0, counts = '{}',
             finished_at = clock_timestamp() where id = %s""",
        (statement_id,),
    )
    conn.execute("select private.bank_booking_begin()")
    conn.execute(
        """insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method)
           select 1, %s, 'sweep', (select id from _members where k = 1), 'auto' where %s
           union all
           select 1 + m.k, %s, 'sweep', m.id, 'auto' from _members m""",
        (line_a_id, line_a, line_b),
    )
    return {"org": org, "line_a": line_a_id, "line_b": line_b}


def test_a_batch_line_of_2000_members_is_re_checked_in_linear_time_and_memory() -> None:
    n = MEMBERS
    with psycopg.connect(ADMIN) as conn:  # (the superuser: auto_explain's settings)
        try:
            conn.execute("set role postgres")  # the worker's: its temporary tables, as the job's
            world = _batch_world(conn, n)
            conn.execute("set local work_mem = '4MB'")  # the local stack's and CI's
            conn.execute("reset role")
            with explained(conn) as plans:
                conn.execute("set role postgres")
                summary = conn.execute(
                    "select private.post_bank_bookings(%s, false)", (world["org"],)
                ).fetchone()
                skipped: dict[uuid.UUID, str] = dict(
                    conn.execute(
                        "select bank_transaction_id, why from pg_temp._booking_skipped"
                    ).fetchall()
                )
                conn.execute("reset role")
        finally:
            conn.rollback()
    assert summary is not None
    # every rule ran over the batch line's n rows, which the batch rule accepted: only « a transfer
    # booked once per call » (its first member's row, after line A's) left the line to ops
    assert skipped == {world["line_b"]: "transfer_twice"}, (skipped, summary)
    assert len(plans) > 10, "auto_explain logged nothing"
    rows = sorted(((work(p["Plan"]), statement(p)) for p in plans), reverse=True)
    print(f"\na batch line of {n} members: {summary[0]}, {len(plans)} statements, the heaviest"
          f" (rows handled) {rows[:6]}")  # fmt: skip
    spilled = [(statement(p), temp_blocks(p["Plan"])) for p in plans if temp_blocks(p["Plan"])]
    assert spilled == [], spilled
    over = [(r, s) for r, s in rows if r > ROWS_PER_ROW * (n + 1) + SLACK]
    assert over == [], over


# A probe of a key index priced as this many sequential pages: above a scan of every table the
# re-check reads (the batch line's 2,000 transfers fill about 100 pages), as CI's statistics priced
# it for its small tables (below).
PROBE_PAGES = 1_000


def _scans_per_row(node: dict[str, Any], n: int) -> list[tuple[str, int, int]]:
    """The sequential scans of a stored table a plan repeats once per row of the job or more: (the
    table, its loops, the rows they read). A temporary table (`_…`) is the job's own: scanned
    whole by design."""
    name = str(node.get("Relation Name", ""))
    loops = int(node.get("Actual Loops", 1))
    found = (
        [(name, loops, work({k: v for k, v in node.items() if k != "Plans"}))]
        if node.get("Node Type") == "Seq Scan" and not name.startswith("_") and loops >= n
        else []
    )
    return found + [f for c in node.get("Plans", []) for f in _scans_per_row(c, n)]


def test_the_re_check_reads_by_key_whatever_the_statistics() -> None:
    """CI run 44850889494 (PR #38; ADR-0014 « M2c-6b-3b part 1 — CI round (PR #38) »): the test
    above failed its bound in the `db` job, its facts' statement handling 338,170 rows — a
    sequential scan of bank_transaction (15 rows) and of ledger_entry (144) per row of the job,
    each table's scan priced below a probe of its primary key (tables vacuumed to a few pages,
    their keys left bloated by the pgTAP suite's rolled-back rows; the same commit passed in the
    next run, autovacuum having run at other times). Deterministic here: the same batch line, the
    planner pricing a probe of a key index at PROBE_PAGES sequential pages (random_page_cost) — so
    a scan of any table the re-check reads looks cheaper than one probe of it. Every statement of
    the call holds the same per-statement bound, and no stored table is scanned once per row: the
    re-check's keys, locks, facts and rules read each row by its key whatever the planner's
    estimates (enable_seqscan off in private.bank_booking_recheck; the posting keeps its callers'
    settings). Before the fix, at 2,000 members: the facts 8.3 million rows, the batch rule, the
    keys and the files' lock 4 million each (bank_transfer scanned once per member)."""
    n = MEMBERS
    with psycopg.connect(ADMIN) as conn:  # (the superuser: auto_explain's settings)
        try:
            conn.execute("set role postgres")  # the worker's: its temporary tables, as the job's
            world = _batch_world(conn, n)
            conn.execute("set local work_mem = '4MB'")  # the local stack's and CI's
            conn.execute(f"set local random_page_cost = {PROBE_PAGES}")
            conn.execute("reset role")
            with explained(conn) as plans:
                conn.execute("set role postgres")
                summary = conn.execute(
                    "select private.post_bank_bookings(%s, false)", (world["org"],)
                ).fetchone()
                skipped: dict[uuid.UUID, str] = dict(
                    conn.execute(
                        "select bank_transaction_id, why from pg_temp._booking_skipped"
                    ).fetchall()
                )
                conn.execute("reset role")
        finally:
            conn.rollback()
    assert summary is not None
    # the same verdicts as above: only « a transfer booked once per call » left the line to ops
    assert skipped == {world["line_b"]: "transfer_twice"}, (skipped, summary)
    assert len(plans) > 10, "auto_explain logged nothing"
    rows = sorted(((work(p["Plan"]), statement(p)) for p in plans), reverse=True)
    print(f"\na batch line of {n} members, probes priced at {PROBE_PAGES} pages: {summary[0]},"
          f" {len(plans)} statements, the heaviest (rows handled) {rows[:6]}")  # fmt: skip
    per_row = [(statement(p), s) for p in plans for s in _scans_per_row(p["Plan"], n)]
    assert per_row == [], per_row
    spilled = [(statement(p), temp_blocks(p["Plan"])) for p in plans if temp_blocks(p["Plan"])]
    assert spilled == [], spilled
    over = [(r, s) for r, s in rows if r > ROWS_PER_ROW * (n + 1) + SLACK]
    assert over == [], over


_GUARD_TEXT = "select min(n.bank_transaction_id::text || ':' || n.seq) from new_rows n"
# The tables the guard reads per new row: their statistics forgotten inside the test's transaction
# (rolled back with it), as a fresh stack leaves them before autovacuum's first analyse
_GUARD_TABLES = (
    "bank_transaction",
    "bank_duplicate_resolution",
    "ledger_entry",
    "bank_debit_link",
    "payment",
    "bank_transfer",
    "bank_line_booking",
    "ledger_posting",
    "ledger_account",
)


def _forget_in_transaction(conn: psycopg.Connection[Any]) -> None:
    """The guard's tables as never analysed (no row count, no column statistics), and their
    indexes as a vacuum that saw none of their rows left them (pages, no tuples: as after the pgTAP
    suite's rolled-back rows, or a table filled since its last vacuum) — in `conn`'s transaction
    only (the superuser's: the catalogue rows are rolled back with it). Review round 1 of M2c-6b-3b
    part 2 (tests-ui-1): the indexes' own row counts were the stack's — autovacuum's, after earlier
    runs or none after a reset —, and a partial index recorded empty prices its whole scan at
    nothing, the plan the joined read of the reversed booking's run took or not with them."""
    for t in _GUARD_TABLES:
        conn.execute("delete from pg_statistic where starelid = %s::regclass", (f"public.{t}",))
        conn.execute(
            "update pg_class set reltuples = -1, relpages = 0 where oid = %s::regclass",
            (f"public.{t}",),
        )
        conn.execute(
            """update pg_class set reltuples = 0,
                 relpages = greatest(2, pg_relation_size(oid) / current_setting('block_size')::int)
               where oid in (select indexrelid from pg_index where indrelid = %s::regclass)""",
            (f"public.{t}",),
        )


def _whole_index_reads_per_row(node: dict[str, Any], n: int) -> list[tuple[str, str, int, int]]:
    """The index scans a plan repeats once per row of the job or more without an index condition —
    each loop reading a stored table's index whole (a partial index's whole predicate; its rows
    sifted by a filter): (the table, or the index of a bitmap scan, the index, its loops, the rows
    they read). No sequential scan, yet as costly as one (review round 1 of M2c-6b-3b part 2,
    tests-ui-1: the reversed booking's run joined read bank_line_booking_transfer_idx whole per new
    row, as a bitmap)."""
    name = str(node.get("Relation Name", ""))
    loops = int(node.get("Actual Loops", 1))
    found = (
        [
            (
                name,
                str(node.get("Index Name", "")),
                loops,
                work({k: v for k, v in node.items() if k != "Plans"}),
            )
        ]
        if node.get("Node Type") in ("Index Scan", "Index Only Scan", "Bitmap Index Scan")
        and "Index Cond" not in node
        and not name.startswith("_")
        and loops >= n
        else []
    )
    return found + [f for c in node.get("Plans", []) for f in _whole_index_reads_per_row(c, n)]


def test_the_booking_guard_reads_by_key_whatever_the_statistics() -> None:
    """PR #38's known limit (ADR-0014 « M2c-6b-3b part 2 »): private.bank_line_booking_guard(),
    the statement trigger on bank_line_booking, disabled hash and merge joins but not sequential
    scans, so under stale statistics each of its keyed reads (the line, its duplicate resolution,
    the entry, the debit link, the payment, the transfer, the bookings of the reversed entry, the
    entry's postings) could run as a scan of its table once per new row: posting a 2,000-member
    batch line in one statement handled 5.5 million rows. Deterministic here, as the re-check's
    test above: the batch line alone (the batch rule accepts it: its 2,000 sweeps are posted, and
    their 2,000 bookings inserted by one statement), a probe of a key index priced at PROBE_PAGES
    sequential pages, and the statistics of the tables it reads forgotten (as before autovacuum's
    first analyse; in this transaction only). The guard's statement holds the per-statement bound
    and scans no stored table once per new row: before, 36 million rows (bank_transfer scanned
    five times per new row, 4 million rows each); with enable_seqscan off alone, 12 million — the
    reversed booking's run, a join, read bank_line_booking whole through its transfer index per
    new row — hence that read keyed too (the transfer by the reversed entry, then its run):
    48,001 rows.

    Review round 1 (tests-ui-1): forgotten statistics leave the planner sizing each table by its
    blocks, so whether the joined read is planned whole per new row depended on what the stack's
    bank_line_booking held (rows committed by earlier tests, or none after a reset): with it empty,
    that mutant passed. A first 2,000-member batch line is now posted in the transaction before,
    so bank_line_booking always holds bookings whatever the stack holds, and the guard's plan is
    also read for an index read whole per new row (no index condition: a full index scan is no
    sequential scan)."""
    n = MEMBERS
    with psycopg.connect(ADMIN) as conn:  # (the superuser: auto_explain's settings)
        try:
            conn.execute("set role postgres")  # the worker's: its temporary tables, as the job's
            # bookings stored before, whatever the stack holds: a first batch line posted
            first = _batch_world(conn, n, line_a=False)
            conn.execute("select private.post_bank_bookings(%s, false)", (first["org"],))
            stored = conn.execute(
                "select count(*) from public.bank_line_booking where bank_transaction_id = %s",
                (first["line_b"],),
            ).fetchone()
            world = _batch_world(conn, n, line_a=False)
            conn.execute("set local work_mem = '4MB'")  # the local stack's and CI's
            conn.execute(f"set local random_page_cost = {PROBE_PAGES}")
            conn.execute("reset role")
            _forget_in_transaction(conn)
            with explained(conn) as plans:
                conn.execute("set role postgres")
                summary = conn.execute(
                    "select private.post_bank_bookings(%s, false)", (world["org"],)
                ).fetchone()
                skipped = conn.execute("select count(*) from pg_temp._booking_skipped").fetchone()
                booked = conn.execute(
                    """select count(*) from public.bank_line_booking
                       where bank_transaction_id = %s and kind = 'sweep'""",
                    (world["line_b"],),
                ).fetchone()
                conn.execute("reset role")
        finally:
            conn.rollback()
    assert summary is not None
    assert stored == (n,), stored
    # the batch line is posted whole: one booking per member, inserted by one statement
    assert skipped == (0,), (skipped, summary)
    assert booked == (n,), (booked, summary)
    # the guard's one statement (its text: « a booking that does not match its line, entry or
    # transfer »)
    guard = [p for p in plans if _GUARD_TEXT in " ".join(str(p.get("Query Text", "")).split())]
    assert len(guard) == 1, [statement(p) for p in plans if "new_rows" in str(p.get("Query Text"))]
    handled = work(guard[0]["Plan"])
    rows = sorted(((work(p["Plan"]), statement(p)) for p in plans), reverse=True)
    print(f"\na batch line of {n} members posted, probes priced at {PROBE_PAGES} pages: the"
          f" guard handled {handled} rows; {summary[0]}, the heaviest {rows[:6]}")  # fmt: skip
    per_row = _scans_per_row(guard[0]["Plan"], n)
    assert per_row == [], per_row
    whole = _whole_index_reads_per_row(guard[0]["Plan"], n)
    assert whole == [], whole
    # every statement of the call (the re-check, the posting, the guard and the ledger's
    # triggers) within the per-statement bound, none spilled to disk
    spilled = [(statement(p), temp_blocks(p["Plan"])) for p in plans if temp_blocks(p["Plan"])]
    assert spilled == [], spilled
    over = [(r, s) for r, s in rows if r > ROWS_PER_ROW * (n + 1) + SLACK]
    assert over == [], over
