"""PR #40's CI round (needs `make up`; ADR-0014 « M2c-6b-3b part 3 — CI round (PR #40) »): the
nightly checks read a cancelled refund's chain by key, whatever the statistics and the rows' order.

CI run 44909449352 (the scale job): test_transfer_cancellation_scale_integration.py's nightly
checks read 486,480 rows of bank_transfer (its bound 183,008). In private.run_transfer_checks, the
arm « transfer_already_debited » over the cancelled transfers of a downloaded file debited late
excluded a refund whose chain's live end is still waiting by reading every refund the servicer has
waiting, each one's transfer and chain (private.transfer_chain), once per cancelled refund — and
stopped early only when the scan happened to meet the match first (refund_request not analysed
yet: its waiting index read in requested_at order, the cancelled refunds' requests among the
first; analysed, a bitmap scan of them all). The same exclusion is now read from the cancelled
refund forward, by key (private.transfer_reissues).

Deterministic here, at a few hundred refunds in the db job: the cancelled refunds' requests are
asked after SIZE others still waiting, so whatever plan reads the waiting refunds meets SIZE of them
before a cancelled one's; the statistics of the tables the arm reads are forgotten and a probe of a
key index is priced at 1,000 sequential pages, in the test's rolled-back transaction (the switch on
there only, as in the scale file). Counted: private.transfer_chain's calls (track_functions:
deterministic, whatever the plan or the stack) — before, one per waiting refund met per cancelled
refund debited late (6,210 here); and the rows read from bank_transfer, a few per transfer the
servicer owns plus one reading of the table (before, 21,410 here, two per waiting refund met)."""

import uuid
from datetime import datetime, timedelta
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, one, storage
from reconciliation_helpers import pay
from remittance_helpers import add_admin, paris_today, recent_business_day, remittance_tenant
from test_transfer_cancellation_scale_integration import (
    ADMIN,
    PARIS,
    _as,
    _backdate,
    _credits,
    _file,
    _refund,
    _statement,
)

pytestmark = pytest.mark.integration
# refunds in a downloaded file, and as many ordered since: the servicer's waiting refunds
SIZE = 300
# refunds cancelled out of their own downloaded file and re-issued, half of them debited late
CANCELLED = 40
# a probe of a key index priced at this many sequential pages (random_page_cost)
PROBE_PAGES = 1_000
# The tables the arm reads, their statistics forgotten in the transaction (as before autovacuum's
# first analyse)
FORGOTTEN = ("bank_transfer", "refund_request", "transfer_file_item", "transfer_file")
# rows of bank_transfer the nightly checks may read per transfer the servicer owns (the scale file's
# per transfer of a downloaded file), plus a slack for the reference reads
PER_ROW = 12
SLACK = 1_000
# private.transfer_chain's calls the nightly checks may make in this world (the in-flight branch and
# the arms that read a cancelled transfer's own chain: a few per cancelled transfer)
CHAIN_CALLS = 4 * CANCELLED + 100


def _forget_in_transaction(conn: psycopg.Connection[Any]) -> None:
    """FORGOTTEN as never analysed (no row count, no column statistics), in `conn`'s transaction
    only (the superuser's: rolled back with it), as stats_helpers.forget_statistics leaves one."""
    for t in FORGOTTEN:
        conn.execute("delete from pg_statistic where starelid = %s::regclass", (f"public.{t}",))
        conn.execute(
            "update pg_class set reltuples = -1, relpages = 0 where oid = %s::regclass",
            (f"public.{t}",),
        )


def _work(conn: psycopg.Connection[Any]) -> dict[str, int]:
    """This transaction's rows read from bank_transfer, and its calls of the chains' readers."""
    reads = one(
        conn,
        """select coalesce(sum(idx_tup_fetch + seq_tup_read), 0) from pg_stat_xact_user_tables
           where relid = 'public.bank_transfer'::regclass""",
    )
    calls = dict(
        conn.execute(
            """select funcname, calls from pg_stat_xact_user_functions
               where schemaname = 'private'
                 and funcname in ('transfer_chain', 'transfer_reissues')"""
        ).fetchall()
    )
    return {"bank_transfer": int(reads), **{str(k): int(v) for k, v in calls.items()}}


def test_a_cancelled_refunds_chain_is_read_by_key_whatever_the_statistics() -> None:
    tenant = remittance_tenant()
    admin = add_admin(tenant)
    d0 = recent_business_day(back=20)
    sid = pay(
        tenant, storage(), _credits(2 * SIZE + CANCELLED), prefix="R", start=d0, days=1,
        allocate=False,
    )  # fmt: skip
    # SIZE refunds in a downloaded file asked first, then the CANCELLED ones in a file of their own,
    # then SIZE more ordered since: every cancelled refund's request comes after SIZE waiting ones
    assert _refund(tenant, SIZE) == SIZE
    large = _file(tenant, SIZE)
    assert _refund(tenant, CANCELLED) == CANCELLED
    small = _file(tenant, CANCELLED)
    assert _refund(tenant, SIZE) == SIZE
    with psycopg.connect(DB) as conn:
        x = one(
            conn,
            """select min(c.day) from public.business_calendar c
               where c.scope = 'FR-conservative' and not c.closed and c.day > %s""",
            (d0 + timedelta(days=2),),
        )
        y = one(conn, "select private.next_business_day(%s)", (x,))
        opening = one(
            conn, "select closing_booked_minor from public.bank_statement where id = %s", (sid,)
        )
        late = conn.execute(
            """select t.id, t.end_to_end_id, t.amount_minor from public.transfer_file_item i
               join public.bank_transfer t on t.id = i.transfer_id
               where i.file_id = %s order by i.seq limit %s""",
            (small, CANCELLED // 2),
        ).fetchall()
        owned = one(
            conn,
            """select count(*) from public.bank_transfer where organization_id = %s""",
            (tenant["servicer"],),
        )
    today = paris_today()
    # time moved on (as the scale file): both files dated back to X, a statement of X and Y
    # produced after them shows no debit
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        _backdate(conn, small, x)
        _backdate(conn, large, x)
        closing = _statement(
            conn, tenant, start=d0 + timedelta(days=1), end=y, opening=int(opening), debits=[],
            created=datetime.combine(y + timedelta(days=1), datetime.min.time(), PARIS)
            + timedelta(hours=9),
        )  # fmt: skip

    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        conn.execute(
            "update private.feature_switch set enabled = true"
            " where key = 'downloaded_file_cancellation'"
        )
        version = one(conn, "select version from public.transfer_file where id = %s", (small,))
        asked = _as(
            conn, tenant["staff"],
            """select public.request_transfer_file_cancellation(%s, %s, %s,
                 'Fichier non déposé (test)', 'not_uploaded') ->> 'status'""",
            str(uuid.uuid4()), small, version,
        )  # fmt: skip
        assert asked is not None
        confirmed = _as(
            conn, admin, "select public.confirm_transfer_file_cancellation(%s, %s, %s)",
            str(uuid.uuid4()), small, version,
        )  # fmt: skip
        assert confirmed["status"] == "superseded", confirmed  # its refunds re-issued
        # the bank executed half of them all the same, late (their own end-to-end ids)
        _statement(
            conn, tenant, start=y + timedelta(days=1), end=today, opening=closing,
            debits=[(str(e), int(a)) for _, e, a in late], created=datetime.now(PARIS),
        )  # fmt: skip
        reissues = {
            str(r[0])
            for r in conn.execute(
                "select id from public.bank_transfer where replaces_transfer_id = any(%s)",
                ([r[0] for r in late],),
            ).fetchall()
        }
        assert len(reissues) == len(late)
        stored = one(conn, "select count(*) from public.bank_transfer")
        _forget_in_transaction(conn)
        conn.execute(f"set local random_page_cost = {PROBE_PAGES}")
        conn.execute("set local track_functions = 'all'")
        before = _work(conn)
        run = one(conn, "select private.run_payment_checks(%s)", (tenant["servicer"],))
        after = _work(conn)
        already = {
            str(r[0])
            for r in conn.execute(
                """select subject_id from public.payment_check_result
                   where run_id = %s and code = 'transfer_already_debited'""",
                (run["run_id"],),
            ).fetchall()
        }
        debited = one(
            conn,
            """select count(*) from public.payment_check_result
               where run_id = %s and code = 'cancelled_transfer_debited'""",
            (run["run_id"],),
        )
    work = {k: after.get(k, 0) - before.get(k, 0) for k in after}
    print(
        f"\n{SIZE} refunds in a downloaded file and {SIZE} ordered, {CANCELLED} cancelled out of"
        f" theirs and re-issued ({len(late)} debited late); the servicer's {owned} transfers of"
        f" {stored}: the nightly checks' work {work} (probes at {PROBE_PAGES} pages, statistics of"
        f" {', '.join(FORGOTTEN)} forgotten)"
    )
    # the same rows as before: each late cancelled refund's re-issue alerted (still waiting, its
    # predecessor debited), never the cancelled refund itself (the live end of its chain is), and
    # each late line once
    assert already == reissues, (sorted(already - reissues)[:3], sorted(reissues - already)[:3])
    assert debited == len(late), debited
    # each cancelled transfer's chain read a bounded number of times — deterministic, whatever the
    # plan or the stack: before, a chain per waiting refund (SIZE of them before the match) per
    # cancelled refund debited late (6,000 calls at least; 6,021 measured)
    assert work.get("transfer_chain", 0) <= CHAIN_CALLS, work
    assert work.get("transfer_reissues", 0) <= CANCELLED, work
    # bank_transfer read by key a bounded number of times per transfer the servicer owns, plus one
    # reading of the table's rows at most (private.run_payment_checks reads the servicer's transfers
    # by its index, or the table being small by a scan of it: every servicer's, the stack's)
    assert work["bank_transfer"] <= PER_ROW * owned + stored + SLACK, (work, owned, stored)
