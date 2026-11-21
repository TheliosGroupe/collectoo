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


def _batch_world(conn: psycopg.Connection[Any], n: int) -> dict[str, Any]:
    """A servicer, its dedicated and own accounts, a downloaded file holding one PmtInf of n
    sweeps (in_file), its batch line and the first sweep's own debit line (A) on one statement;
    the job's rows (A first) in pg_temp._bank_booking."""
    rng = random.Random(f"batch-rules-{uuid.uuid4()}")
    org, funds, own = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    funds_iban, own_iban = iban_fr(rng), iban_fr(rng)
    file_id, statement_id = uuid.uuid4(), uuid.uuid4()
    line_a, line_b = uuid.uuid4(), uuid.uuid4()
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
           values (%s, %s, %s, %s, 1, 't:' || %s, 'debit', %s, 'EUR', private.paris_today(),
                   'transfer_out', (select e2e from _members where k = 1), null, %s),
                  (%s, %s, %s, %s, 2, 't:' || %s, 'debit', %s, 'EUR', private.paris_today(),
                   'batch_unsplit', null, %s, null)""",
        (line_a, org, funds, statement_id, line_a, amounts[0], own_iban,
         line_b, org, funds, statement_id, line_b, sum(amounts), pmt_inf),
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
           select 1, %s, 'sweep', (select id from _members where k = 1), 'auto'
           union all
           select 1 + m.k, %s, 'sweep', m.id, 'auto' from _members m""",
        (line_a, line_b),
    )
    return {"org": org, "line_a": line_a, "line_b": line_b}


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
