"""M2c-6a scale (needs `make up`; design §19 « pain.001 ≤ 200 transfers < 0.2 s », the brief's
file of 5,000 transfers and the cash check under load).

5,000 unidentified credits are imported on one statement and each is refunded in the transfer file
(`request_refund`, execution mode `file`: 5,000 RFD transfers ordered); then « Générer le fichier »
(one command: the per-transfer checks, the cash check, the items, the transfers in the file), the
`transfer_file` job (5,000 transactions written, checked, uploaded), the download, the cash check
and « Virements » with the 5,000 in flight, then a statement showing their 5,000 debits (each seen
by its RFD id: none in flight any more). M2c-6b-1: the debit job over those 5,000 debits — the
M2b pass links each to its refund (the funds pass, in its own message, finds none of them: RFD
lines are the M2b pass's; payouts booked by the funds pass are timed in
test_debit_bookings_scale_integration.py), each transfer read by key; then the nightly checks with
I19 and I20 over them (plan §1.4: < 5 s). The new tables' statistics are forgotten first (the
state CI meets). Prints the timings (docs/benchmarks/remittances.md). TRANSFER_FILE_SIZE changes
the size."""

import hashlib
import json
import logging
import os
import time
import uuid
from pathlib import Path
from typing import Any, LiteralString

import psycopg
import pytest
from debit_helpers import violations
from integration_helpers import DB, one, storage
from psycopg.conninfo import make_conninfo
from psycopg.types.json import Jsonb
from reconciliation_helpers import pay
from remittance_helpers import drain, recent_business_day, staff
from statement_helpers import bank_tenant
from statement_helpers import drain as drain_payments
from stats_helpers import forget_statistics

from collectoo_worker.remittance import pain001
from collectoo_worker.synth.reconciliation import Credit

pytestmark = pytest.mark.integration
SIZE = int(os.environ.get("TRANSFER_FILE_SIZE", "5000"))


def _credits(n: int) -> list[Credit]:
    return [
        Credit(1000 + k, f"PAYEUR {k}", None, (f"VIREMENT {k}",), None, None, "no_match", "none")
        for k in range(n)
    ]


_FETCHED = (
    "select coalesce(sum(idx_tup_fetch + seq_tup_read), 0) from pg_stat_xact_user_tables"
    " where relid = 'public.bank_transaction'::regclass"
)


def _transfer_reads() -> int:
    """Rows of bank_transfer read since the statistics were last reset, by every backend (the
    job's own connections included): the M2b and funds passes read each transfer by key."""
    with psycopg.connect(DB) as conn:
        conn.execute("select pg_stat_force_next_flush()")
        row = conn.execute(
            "select coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0) from pg_stat_user_tables"
            " where relid = 'public.bank_transfer'::regclass"
        ).fetchone()
    return int(row[0]) if row else 0


# The nightly checks' reads, by table (review round 2, P3): the rows of the servicer's own each
# table holds, and how many times the checks may read each of them at most (each check reads the
# rows it needs by the servicer's key; a check aggregating the servicer's whole ledger reads it
# once). A table read by a sequential scan reads every servicer's rows: only small tables may be.
OWN_ROWS: dict[str, LiteralString] = {
    "public.ledger_entry": "select count(*) from public.ledger_entry where organization_id = %s",
    "public.ledger_account": "select count(*) from public.ledger_account"
    " where organization_id = %s",
    "public.bank_transaction": "select count(*) from public.bank_transaction"
    " where organization_id = %s",
    "public.payment": "select count(*) from public.payment where organization_id = %s",
    "public.bank_transfer": "select count(*) from public.bank_transfer where organization_id = %s",
    "public.bank_line_booking": "select count(*) from public.bank_line_booking"
    " where organization_id = %s",
    "public.bank_debit_link": "select count(*) from public.bank_debit_link"
    " where organization_id = %s",
    "public.refund_request": "select count(*) from public.refund_request"
    " where organization_id = %s",
    "public.receipt": "select count(*) from public.receipt where organization_id = %s",
    "public.ledger_posting": """select count(*) from public.ledger_posting p
                                join public.ledger_entry e on e.id = p.entry_id
                                where e.organization_id = %s""",
    "public.client_notification": """select count(*) from public.client_notification n
                                     join public.organization o on o.id = n.client_organization_id
                                     where o.servicer_organization_id = %s""",
}
PER_OWN_ROW = {
    "public.ledger_entry": 8,
    "public.ledger_posting": 12,
    "public.ledger_account": 12,
    "public.bank_transaction": 6,
    "public.payment": 6,
    "public.bank_transfer": 6,
    "public.bank_line_booking": 10,
    "public.bank_debit_link": 6,
    "public.refund_request": 6,
    "public.receipt": 4,
    "public.client_notification": 4,
}
CHECK_SLACK = 2_000  # the small tables' rows (reference data, statements, bank accounts)
# a sequential scan reads every servicer's rows: one is the right plan only where the servicer owns
# most of the table (one servicer alone in the database), never where others' rows outnumber its own
SEQ_PER_OWN_ROW = 2


def checks_with_reads(tenant: dict[str, Any]) -> tuple[dict[str, Any], float, dict[str, Any]]:
    """The nightly checks of the servicer (the job's SQL), timed, and the rows their transaction
    read from each table: (by index, by sequential scans) — deterministic, whatever the cache.
    Prints where the time went (the functions' own time, track_functions)."""
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        conn.execute("set local track_functions = 'all'")
        started = time.monotonic()
        row = conn.execute(
            "select private.run_payment_checks(%s)", (tenant["servicer"],)
        ).fetchone()
        elapsed = time.monotonic() - started
        rows = conn.execute(
            """select relid::regclass::text, coalesce(idx_tup_fetch, 0), coalesce(seq_tup_read, 0)
               from pg_stat_xact_user_tables
               where coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0) > 0"""
        ).fetchall()
        spent = conn.execute(
            """select funcname, round(self_time::numeric), calls from pg_stat_xact_user_functions
               order by self_time desc limit 5"""
        ).fetchall()
    print(f"\nnightly checks {elapsed:.2f}s, the functions' own ms (calls): {spent}")
    assert row is not None
    reads = {("public." + r[0]).replace("public.public.", "public."): (int(r[1]), int(r[2]))
             for r in rows}  # fmt: skip
    return dict(row[0]), elapsed, reads


# The local stack's superuser (as stats_helpers): auto_explain's ANALYZE settings are its own.
ADMIN = make_conninfo(DB, user="supabase_admin")
PER_CHECK = 4  # rows each check may handle, per row the servicer owns (OWN_ROWS' tables together)
# buffers each check may touch (shared, hit or read), per row the servicer owns: a probe by key
# touches a few; an index scan through every request of the servicer, dead versions included,
# for each payment touched 1.44 million for 5,000 refunds (review round 2, P3)
PER_CHECK_BLOCKS = 4


def _work(node: dict[str, Any]) -> int:
    """The rows a plan node and its children handled: those each node returned, and those its
    filters, join filters and rechecks threw away (a table read whole, or rows compared n²)."""
    loops = int(node.get("Actual Loops", 1))
    n = loops * (
        int(node.get("Actual Rows", 0))
        + int(node.get("Rows Removed by Filter", 0))
        + int(node.get("Rows Removed by Join Filter", 0))
        + int(node.get("Rows Removed by Index Recheck", 0))
    )
    return n + sum(_work(c) for c in node.get("Plans", []))


def checks_work(tenant: dict[str, Any]) -> list[tuple[str, int, int]]:
    """The checks statement of the servicer's nightly checks, run again under EXPLAIN ANALYZE
    (auto_explain: row counts and buffers, no timing) and rolled back: the rows each check handled
    and the buffers it touched — each branch of its UNION ALL (with the CTEs it is the first to
    read) and each of its CTEs. Deterministic: rows and pages, whatever the cache."""
    notices: list[str] = []
    with psycopg.connect(ADMIN) as conn:
        conn.add_notice_handler(lambda d: notices.append(d.message_primary or ""))
        try:
            for setting in (
                "load 'auto_explain'",
                # (the checks statement takes longer; the statements a function runs per row,
                # less: logged, 50,000 of them cost a minute)
                "set auto_explain.log_min_duration = 1",
                "set auto_explain.log_analyze = on",
                "set auto_explain.log_timing = off",
                "set auto_explain.log_buffers = on",
                "set auto_explain.log_format = 'json'",
                "set auto_explain.log_nested_statements = on",
                "set client_min_messages = log",
            ):
                conn.execute(setting)
            started = time.monotonic()
            conn.execute("select private.run_payment_checks(%s)", (tenant["servicer"],))
            again_s = time.monotonic() - started
        finally:
            conn.rollback()
    print(f"\nnightly checks again (row counts on, warm) {again_s:.2f}s")
    plans = [json.loads(n.split("plan:", 1)[1]) for n in notices if "plan:" in n]
    found = [
        p["Plan"] for p in plans if p["Query Text"].lstrip().startswith("insert into pg_temp._chk")
    ]
    assert len(found) == 1, [p["Query Text"][:60] for p in plans]
    plan = found[0]
    append = plan["Plans"][0]["Plans"][0]
    assert append["Node Type"] == "Append", append["Node Type"]
    return [
        (
            c.get("Subplan Name") or f"check {k}",
            _work(c),
            int(c.get("Shared Hit Blocks", 0)) + int(c.get("Shared Read Blocks", 0)),
        )
        for k, c in enumerate(append["Plans"])
    ]


def assert_checks_bounded(org: str, work: list[tuple[str, int, int]]) -> None:
    """Each check handled at most PER_CHECK rows and touched at most PER_CHECK_BLOCKS buffers per
    row the servicer owns (+ the slack): never every servicer's rows, never its own n² (review
    round 2, P3: its payments joined to their grouped entries by a nested loop compared 12.5
    million rows for 5,000 refunds)."""
    with psycopg.connect(DB) as conn:
        own = sum(int(one(conn, q, (org,))) for q in OWN_ROWS.values())
    print(
        f"\nnightly checks, rows handled and buffers touched per check (the servicer owns {own}):"
        f" {sorted(work, key=lambda w: -w[1])[:8]}"
    )
    over = [
        w
        for w in work
        if w[1] > PER_CHECK * own + CHECK_SLACK or w[2] > PER_CHECK_BLOCKS * own + CHECK_SLACK
    ]
    assert over == [], (over, own)


def assert_checks_keyed(org: str, reads: dict[str, Any]) -> None:
    """Each table the checks read: its rows read at most PER_OWN_ROW times the servicer's own (+
    the slack), and by sequential scans (every servicer's rows) at most SEQ_PER_OWN_ROW times."""
    with psycopg.connect(DB) as conn:
        own = {t: int(one(conn, q, (org,))) for t, q in OWN_ROWS.items()}
    print(f"\nnightly checks, rows read (by index, by sequential scans) / the servicer's own: "
          f"{ {t: (reads.get(t, (0, 0)), own[t]) for t in OWN_ROWS} }")  # fmt: skip
    over = {
        t: (reads.get(t, (0, 0)), own[t])
        for t in OWN_ROWS
        if sum(reads.get(t, (0, 0))) > PER_OWN_ROW[t] * own[t] + CHECK_SLACK
        or reads.get(t, (0, 0))[1] > SEQ_PER_OWN_ROW * own[t] + CHECK_SLACK
    }
    assert over == {}, over


def _cash(tenant: dict[str, Any]) -> tuple[dict[str, Any], float, int]:
    """The cash check, its time, and the bank lines it read (this transaction's counters)."""
    started = time.monotonic()
    with psycopg.connect(DB) as conn:
        before = one(conn, _FETCHED)
        cash = one(conn, "select private.transfer_cash_position(%s)", (tenant["bank"],))
        read = one(conn, _FETCHED) - before
    return dict(cash), time.monotonic() - started, int(read)


def test_a_file_of_5000_transfers(  # noqa: PLR0915 - one scenario, its timings printed together
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO, logger="collectoo.remittances")
    tenant = bank_tenant()
    day = recent_business_day()
    sid = pay(tenant, storage(), _credits(SIZE), prefix="U", start=day, days=1, allocate=False)
    with psycopg.connect(DB) as conn, conn.transaction():
        n = one(
            conn,
            "select count(*) from public.payment"
            " where bank_account_id = %s and status = 'unmatched'",
            (tenant["bank"],),
        )
    assert n == SIZE
    for table in (
        "public.bank_transfer",
        "public.refund_request",
        "public.transfer_file",
        "public.transfer_file_item",
    ):
        forget_statistics(table)

    asking = time.monotonic()
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select set_config('request.jwt.claims', %s, true)",
            (f'{{"sub": "{tenant["staff"]}", "role": "authenticated", "aal": "aal2"}}',),
        )
        conn.execute("set local role authenticated")
        asked = one(
            conn,
            """select count(public.request_refund('scale-rfd-' || p.id, p.id, p.amount_minor::text,
                        'FR7630004000031234567890143', p.payer_name, 'other', p.review_reason,
                        p.amount_minor::text, 'test d''échelle'))
               from public.payment p where p.bank_account_id = %s and p.status = 'unmatched'""",
            (tenant["bank"],),
        )
        conn.execute("reset role")
        # the debit job each refund queues has nothing to find: taken off the payments queue
        conn.execute(
            "delete from pgmq.q_payments where message ->> 'organization_id' = %s",
            (str(tenant["servicer"]),),
        )
    asked_s = time.monotonic() - asking
    assert asked == SIZE

    generating = time.monotonic()
    generated = staff(
        tenant,
        "select public.generate_transfer_file(%s, %s, null)",
        str(uuid.uuid4()),
        tenant["bank"],
    )
    generate_s = time.monotonic() - generating
    assert generated["nb_of_txs"] == SIZE and generated["held"] == []
    writing = time.monotonic()
    drain()  # the transfer_file job
    write_s = time.monotonic() - writing
    with psycopg.connect(DB) as conn:
        path, digest, status = conn.execute(
            "select storage_path, file_sha256, status from public.transfer_file where id = %s",
            (generated["file_id"],),
        ).fetchone() or (None, None, None)
    assert status == "generated"
    dest = tmp_path / "file.xml"
    storage().download("transfer-files", str(path), dest)
    data = dest.read_bytes()
    assert hashlib.sha256(data).hexdigest() == digest
    checking = time.monotonic()
    facts = pain001.check(data, "pain.001.001.09")
    check_s = time.monotonic() - checking
    assert facts["nb_of_txs"] == SIZE
    assert facts["ctrl_sum_minor"] == int(generated["ctrl_sum_minor"])

    downloading = time.monotonic()
    staff(tenant, "select public.transfer_file_download(%s, %s)", generated["file_id"], digest)
    download_s = time.monotonic() - downloading
    cash, cash_s, cash_read = _cash(tenant)
    assert int(cash["in_flight_minor"]) == int(generated["ctrl_sum_minor"])
    assert cash["in_flight_count"] == SIZE
    showing = time.monotonic()
    overview = staff(tenant, "select public.transfer_overview()")
    overview_s = time.monotonic() - showing
    assert overview["accounts"][0]["files"][0]["nb_of_txs"] == SIZE

    # their debits on the next statement: none in flight any more
    with psycopg.connect(DB) as conn, conn.transaction():
        st = one(
            conn,
            """insert into public.bank_statement (organization_id, bank_account_id, currency,
                 format, file_name, file_sha256, size_bytes, storage_path)
               values (%s, %s, 'EUR', 'camt053', 'debits.xml', %s, 1, %s) returning id""",
            (tenant["servicer"], tenant["bank"], uuid.uuid4().hex * 2, f"test/{uuid.uuid4()}"),
        )
        conn.execute(
            "update public.bank_statement set status = 'uploaded', uploaded_at = now()"
            " where id = %s",
            (st,),
        )
        conn.execute(
            """insert into public.bank_transaction (organization_id, bank_account_id, statement_id,
                 line_no, dedup_key, direction, amount_minor, currency, booking_date, kind,
                 end_to_end_id)
               select t.organization_id, t.debtor_bank_account_id, %s,
                      row_number() over (order by t.id), 'e:' || t.id, 'debit', t.amount_minor,
                      'EUR', private.paris_today(), 'refund_out', t.end_to_end_id
               from public.bank_transfer t where t.transfer_file_id = %s""",
            (st, generated["file_id"]),
        )
        closing = one(
            conn,
            "select closing_booked_minor from public.bank_statement where id = %s",
            (sid,),
        )
        conn.execute(
            """update public.bank_statement set status = 'imported',
                 from_date = private.paris_today(), to_date = private.paris_today(),
                 opening_booked_minor = %s, closing_booked_minor = %s, counts = '{}',
                 finished_at = now() where id = %s""",
            (closing, closing - int(generated["ctrl_sum_minor"]), st),
        )
    seen, seen_s, seen_read = _cash(tenant)
    assert seen["in_flight_minor"] == "0" and seen["in_flight_count"] == 0
    # keyed whatever the statistics (ARCHITECTURE §4): each transfer's own debit is probed by
    # its end-to-end id, reading its line at most, never the account's other lines (integration
    # of the M2c-6a review: right after the debits' import the planner took the account's
    # unposted-lines index, every line of the account read per probe: 2 s)
    assert cash_read <= 2 * SIZE, cash_read
    assert seen_read <= 2 * SIZE, seen_read

    # M2c-6b-1: the debit job books them (as the import queues it), then the nightly checks
    forget_statistics("public.bank_line_booking")
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select pgmq.send('payments', %s)",
            (Jsonb({"type": "process_debits", "organization_id": str(tenant["servicer"])}),),
        )
    transfers_before = _transfer_reads()
    booking = time.monotonic()
    drain_payments(storage())
    book_s = time.monotonic() - booking
    transfer_reads = _transfer_reads() - transfers_before
    with psycopg.connect(DB) as conn:
        executed = one(
            conn,
            """select count(*) from public.refund_request r
               join public.bank_transfer t on t.id = r.transfer_id
               where t.transfer_file_id = %s and r.status = 'executed'
                 and r.cash_out_entry_id is not null""",
            (generated["file_id"],),
        )
    assert executed == SIZE
    # each transfer read by key, a bounded number of times over the passes (10,000 for 5,000)
    assert transfer_reads <= 3 * SIZE, transfer_reads
    run, nightly_s, check_reads = checks_with_reads(tenant)
    assert violations(str(run["run_id"])) == []
    logs = [r.getMessage() for r in caplog.records if r.getMessage().startswith("transfer file ")]
    print(
        f"\n{SIZE} transfers: refunds asked in {asked_s:.1f}s; generation (command)"
        f" {generate_s:.2f}s; job {write_s:.2f}s ({'; '.join(logs)}); structural check"
        f" {check_s:.2f}s; {len(data)} bytes; download (command) {download_s:.2f}s; cash check with"
        f" {SIZE} in flight {cash_s:.2f}s ({cash_read} bank lines read), once their debits are seen"
        f" {seen_s:.2f}s ({seen_read} read); « Virements »"
        f" {overview_s:.2f}s; the debit job booking the {SIZE} debits {book_s:.1f}s"
        f" ({transfer_reads} transfer rows read, all passes); nightly checks {nightly_s:.2f}s"
        f" (rows read by index, by sequential scans: {check_reads})"
    )
    # the commands within the API's 8 s; the job well within the queue's visibility timeout
    assert generate_s < 8
    assert download_s < 8
    assert overview_s < 8
    assert write_s < 60
    assert book_s < 120
    # integration of the M2c-6b-1 review, then review round 2 (P3): every check reads the
    # servicer's rows by its key — the ledger accounts by (organization, book), the payments'
    # entries from the payments, each payment's bank line by its id — never every servicer's by a
    # sequential scan (cold right after the earlier scale runs' writes: 5 to 7.6 s here)
    assert_checks_keyed(str(tenant["servicer"]), check_reads)
    assert_checks_bounded(str(tenant["servicer"]), checks_work(tenant))
    assert nightly_s < 5  # plan §1.4
