"""M2c-4 review fixes of the schedule, the prepare's history read and the nightly checks'
unallocated money (needs `make up`; design §9.3, §9.4, §15; ARCHITECTURE §4).

* the hourly schedule: one client's data error never stops the others — the stuck jobs are
  recovered, the other clients get their drafts, the failure is recorded — and a dead schedule job
  is recorded too; the nightly checks raise `remittance_schedule_failed` (review nc#0);
* the prepare reads one tier-history state per (file, tier key), however long the history (perf#7);
* the money matched to a file and not allocated is read by key from each payment, even with no
  statistics on ledger_entry (perf#0).
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

import psycopg
import pytest
from allocation_helpers import File, Item, create_file, credit, statement
from debit_helpers import checks
from integration_helpers import DB, one, storage
from remittance_helpers import (
    add_client,
    approve,
    drain,
    paid_file,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)
from statement_helpers import bank_tenant
from stats_helpers import forget_statistics, frozen_statistics

from collectoo_worker.jobs.remittances import load_facts, record_dead_job, run_schedule

pytestmark = pytest.mark.integration
PARIS = ZoneInfo("Europe/Paris")


def _reads(conn: psycopg.Connection[Any], *tables: str) -> dict[str, tuple[int, int]]:
    """(seq scans, index-fetched rows) this transaction made of each table so far."""
    rows = conn.execute(
        """select x.relid::regclass::text, x.seq_scan, coalesce(x.idx_tup_fetch, 0)
           from pg_stat_xact_user_tables x where x.relid = any(%s::regclass[])""",
        (list(tables),),
    ).fetchall()
    return {r[0]: (int(r[1]), int(r[2])) for r in rows}


def _since(before: dict[str, tuple[int, int]], after: dict[str, tuple[int, int]]) -> dict[str, Any]:
    return {k: (after[k][0] - before[k][0], after[k][1] - before[k][1]) for k in after}


def test_one_failing_client_never_stops_the_schedule() -> None:
    tenant = remittance_tenant()
    other = add_client(tenant, "C2")
    paid_file(tenant, 30_000)
    paid_file(other, 40_000)
    stranger = bank_tenant()  # a client of another servicer
    bogus = str(uuid.uuid4())
    with psycopg.connect(DB) as conn, conn.transaction():
        # client 1's draft, its prepare stuck for 11 minutes
        stuck = one(
            conn,
            "select private.create_remittance_run(%s, %s, 'EUR', 'manual', null, null)",
            (tenant["servicer"], tenant["client"]),
        )
        conn.execute(
            "update public.remittance_run set job_queued_at = now() - interval '11 minutes'"
            " where id = %s",
            (stuck,),
        )
        token = one(conn, "select job_token from public.remittance_run where id = %s", (stuck,))
        # an item of the servicer's queue naming a client that is not its own (corrupt data): its
        # draft fails with a data error (23514)
        conn.execute(
            """insert into private.remittance_pending (ledger_entry_id, organization_id,
                 client_organization_id, currency, kind, amount_minor, posted_at)
               values (%s, %s, %s, 'EUR', 'payout_returned', 100, now())""",
            (bogus, tenant["servicer"], stranger["client"]),
        )
    try:
        payload = {"organization_id": tenant["servicer"]}
        with psycopg.connect(DB) as conn, conn.transaction():
            created = run_schedule(conn, payload, now=datetime(2026, 11, 16, 6, 0, tzinfo=PARIS))
        # the other client's draft is created, the stuck prepare queued again, the failure recorded
        assert len(created) == 1
        assert str(run_row(created[0])["client_organization_id"]) == str(other["client"])
        assert run_row(stuck)["job_token"] != token
        with psycopg.connect(DB) as conn:
            failures = conn.execute(
                """select code, client_organization_id::text, error
                   from private.remittance_schedule_failure where organization_id = %s""",
                (tenant["servicer"],),
            ).fetchall()
        assert [(c, cl) for c, cl, _ in failures] == [("client", str(stranger["client"]))]
        assert failures[0][2].startswith("23514")
        # a schedule job dead-lettered after its retries is recorded as well
        with psycopg.connect(DB) as conn, conn.transaction():
            record_dead_job({"type": "schedule", **payload}, "OperationalError: boom", conn)
        run = checks(tenant)
        with psycopg.connect(DB) as conn:
            alert = conn.execute(
                """select severity, count, details from public.payment_check_result
                   where run_id = %s and code = 'remittance_schedule_failed'""",
                (run["run_id"],),
            ).fetchone()
        assert alert is not None
        assert (alert[0], alert[1]) == ("alert", 2)
        assert alert[2]["codes"] == ["client", "dead"]
        assert alert[2]["client_ids"] == [str(stranger["client"])]
    finally:
        with psycopg.connect(DB) as conn, conn.transaction():
            conn.execute(
                "delete from private.remittance_pending where ledger_entry_id = %s", (bogus,)
            )
        drain()


def test_the_prepare_reads_one_history_state_per_key() -> None:
    """A file with a long tier history (20 states): the prepare reads its latest only."""
    tenant = remittance_tenant()
    invoice = Item("INV-1", {"principal": 300_000})
    f = create_file(tenant, File(f"H-{uuid.uuid4().hex[:8]}", "b2b", "Débiteur SARL", [invoice]))
    day = recent_business_day()
    statement(
        tenant, storage(), [credit(200_000, rf=f.rf)], f"H{uuid.uuid4().hex[:5].upper()}", day
    )
    first = request_run(tenant)
    approve(tenant, first)
    drain()
    assert run_row(first)["status"] == "approved"
    with psycopg.connect(DB) as conn, conn.transaction():
        # the same state written again by 20 later runs (the latest is the state)
        conn.execute(
            """insert into public.remittance_key_state (organization_id, client_organization_id,
                 account_id, tier_key, run_id, cause, basis, kept_basis_minor, kept_minor,
                 commission_minor)
               select k.organization_id, k.client_organization_id, k.account_id, k.tier_key,
                      k.run_id, k.cause, k.basis, k.kept_basis_minor, k.kept_minor,
                      k.commission_minor
               from public.remittance_key_state k cross join generate_series(1, 20)
               where k.account_id = %s""",
            (f.id,),
        )
    # the run of 01/12 is booked meanwhile (M2c-6): a new collection on the same file
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "update public.remittance_run set status = 'booked', booked_on = private.paris_today()"
            " where id = %s",
            (first,),
        )
    statement(
        tenant, storage(), [credit(100_000, rf=f.rf)], f"H{uuid.uuid4().hex[:5].upper()}", day
    )
    sql = "select public.request_remittance_run(%s, %s, 'EUR')"
    result = staff(tenant, sql, str(uuid.uuid4()), tenant["client"])
    run = str(result["run_id"])
    token = str(run_row(run)["job_token"])
    with psycopg.connect(DB) as conn, conn.transaction():
        before = _reads(conn, "public.remittance_key_state")
        facts = load_facts(conn, run, token)
        after = _reads(conn, "public.remittance_key_state")
    assert facts is not None
    assert set(facts.history) == {(f.id, "tout")}
    assert facts.history[(f.id, "tout")].commission_minor == 30_000
    seq_scans, fetched = _since(before, after)["remittance_key_state"]
    # the key's latest state, and the client's last history number (not the 21 states)
    assert seq_scans == 0 and fetched <= 2, (seq_scans, fetched)
    drain()
    assert run_row(run)["prepared_at"] is not None, run_row(run)["last_failure"]


def test_unallocated_money_is_read_by_key_without_statistics() -> None:
    """Overpaid files (the rest of each payment stays in 4710): with ledger_entry's statistics
    forgotten, the nightly checks' read neither scans the accounts nor the postings."""
    tenant = remittance_tenant()
    credits, files = [], []
    for n in range(12):
        invoice = Item("INV-1", {"principal": 10_000})
        f = create_file(tenant, File(f"U-{n}-{uuid.uuid4().hex[:6]}", "b2b", "Débiteur", [invoice]))
        files.append(f)
        credits.append(credit(15_000, rf=f.rf))
    ids = statement(
        tenant, storage(), credits, f"U{uuid.uuid4().hex[:5].upper()}", recent_business_day()
    )
    with frozen_statistics("public.ledger_entry"):
        forget_statistics("public.ledger_entry")
        with psycopg.connect(DB) as conn, conn.transaction():
            tables = (
                "public.ledger_account",
                "public.ledger_posting",
                "public.ledger_entry",
                "public.payment",
            )
            before = _reads(conn, *tables)
            rows = conn.execute(
                """select payment_id::text, unallocated_minor
                   from private.unallocated_payment_deadlines(%s)""",
                (tenant["servicer"],),
            ).fetchall()
            after = _reads(conn, *tables)
    assert sorted(rows) == sorted((p, 5_000) for p in ids.values())
    reads = _since(before, after)
    assert all(seq == 0 for seq, _ in reads.values()), reads
    # each payment's postings by its entries: a few per payment, never the 4710 pool
    assert reads["ledger_posting"][1] <= 10 * len(ids), reads
