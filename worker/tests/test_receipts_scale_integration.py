"""M2-10 scale (needs `make up`): 50,000 files boarded from the synthetic EU loan tape (as the M2-09
scale test), one credit each paid by RF, imported, matched and allocated with the receipts left
aside (as before receipts existed); then the migration's backfill queues the receipts (200 payments
per job) and the jobs render and store them. Prints the timings (docs/benchmarks/payments.md;
design risk R8) and checks set-based that every payment on a file has exactly one receipt number
with one version, its payload's totals adding up to the payment, a stored PDF hash per version.
RECEIPT_FILES changes the size (CI: 5,000, rendering takes ~10 ms a receipt; benchmark: 50,000).
The receipt jobs run with the ledger's statistics as CI met them in the allocation scale test
(ledger_entry not analysed yet): the payloads' ledger lookups must not rest on fresh statistics."""

import logging
import os
import time
from pathlib import Path

import psycopg
import pytest
from integration_helpers import DB, one, storage
from reconciliation_helpers import pay
from statement_helpers import bank_tenant
from statement_helpers import drain as drain_payments
from stats_helpers import analyse, forget_statistics, frozen_statistics
from test_allocation_scale_integration import _credits, _files
from test_matching_scale_integration import _board

pytestmark = pytest.mark.integration
FILES = int(os.environ.get("RECEIPT_FILES", "50000"))


def test_receipts_for_allocated_payments_at_scale(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO, logger="collectoo.payments")
    tenant = bank_tenant()
    store = storage()
    started = time.monotonic()
    _board(tenant, tmp_path, FILES)
    files = [f for f in _files(tenant) if f[2] > 0]
    credits = _credits(files)
    pay(tenant, store, credits, prefix="Q", days=5)  # imported, matched, allocated; no receipts
    allocated = time.monotonic()
    org = tenant["servicer"]
    with psycopg.connect(DB) as conn, conn.transaction():
        jobs = one(conn, "select private.queue_receipt_backfill(%s)", (org,))
    caplog.clear()
    ledger = ("public.ledger_entry", "public.ledger_posting", "public.ledger_account")
    with frozen_statistics(*ledger) as conn:
        analyse(conn, "public.ledger_account", "public.ledger_posting")
        forget_statistics("public.ledger_entry")
        started_receipts = time.monotonic()
        drain_payments(store, receipts=True)
        issued = time.monotonic()
    logs = [r.getMessage() for r in caplog.records if r.getMessage().startswith("receipts ")]
    print(
        f"\n{len(files)} files boarded, {len(credits)} credits imported, matched and allocated in"
        f" {allocated - started:.0f}s; {jobs} receipt jobs in {issued - started_receipts:.1f}s"
        f" ({(issued - started_receipts) / max(len(credits), 1) * 1000:.1f} ms per receipt)"
        "\n  first: " + (logs[0] if logs else "-") + "\n  last: " + (logs[-1] if logs else "-")
    )
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select count(*) filter (where p.account_id is not null),
                      count(*) filter (where p.account_id is not null and r.n = 1 and r.v = 1),
                      count(*) filter (where r.bad > 0),
                      coalesce(sum(r.n), 0)
               from public.payment p
               left join lateral (
                 select count(*) as n, max(x.version) as v,
                        count(*) filter (
                          where (x.payload #>> '{totals,allocated_minor}')::bigint
                              + (x.payload #>> '{totals,forwarded_minor}')::bigint
                              + (x.payload #>> '{totals,returned_minor}')::bigint
                              + (x.payload #>> '{totals,unallocated_minor}')::bigint
                              <> p.amount_minor
                             or x.pdf_sha256 !~ '^[0-9a-f]{64}$') as bad
                 from public.receipt x where x.payment_id = p.id) r on true
               where p.organization_id = %s""",
            (org,),
        ).fetchone()
        assert row is not None
        on_file, one_receipt, bad, receipts = row
        print(f"  payments on a file: {on_file}, with one receipt v1: {one_receipt}")
        assert on_file == len(credits) == one_receipt == receipts
        assert bad == 0
        numbers = one(
            conn,
            "select count(distinct number) from public.receipt where organization_id = %s",
            (org,),
        )
        assert numbers == len(credits)
