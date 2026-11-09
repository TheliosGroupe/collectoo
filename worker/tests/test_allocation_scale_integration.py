"""M2-09 scale (needs `make up`): 50,000 files boarded from the synthetic EU loan tape (as the M2-08
scale test), a 50,000-credit statement paying them by their RF reference (partial, exact and over
amounts), imported and matched, then allocated by the `payments.allocate` jobs (chunks of 10,000).
Prints the timings (docs/benchmarks/payments.md; design risk R1: the per-entry checks at commit) and
checks the money set-based: every allocation within the payment and the receivables, Σ allocated +
unallocated = Σ received, client money closed (I8), one client notification per allocation entry.
ALLOC_FILES changes the size."""

import logging
import os
import random
import time
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, one, storage
from reconciliation_helpers import pay
from statement_helpers import bank_tenant
from statement_helpers import drain as drain_payments
from test_matching_scale_integration import _board

from collectoo_worker.synth.reconciliation import Credit

pytestmark = pytest.mark.integration
FILES = int(os.environ.get("ALLOC_FILES", "50000"))


def _files(tenant: dict[str, Any]) -> list[tuple[str, str, int]]:
    """(file, RF, open balance) of the tenant's confirmed files."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select a.id::text, r.rf, coalesce(sum(lp.amount_minor), 0)
               from public.account a
               join public.payment_reference r on r.account_id = a.id and r.status = 'active'
               join public.ledger_account la on la.account_id = a.id
                 and la.book = 'debtor_receivable'
               join public.ledger_posting lp on lp.ledger_account_id = la.id
               where a.organization_id = %s group by a.id, r.rf order by a.id""",
            (tenant["servicer"],),
        ).fetchall()
    return [(r[0], r[1], int(r[2])) for r in rows]


def _credits(files: list[tuple[str, str, int]]) -> list[Credit]:
    """One credit per file, by its structured RF: partial (10 to 60 %), the balance, or more."""
    rng = random.Random(9)
    out = []
    for n, (account, rf, balance) in enumerate(files):
        kind = n % 10
        if kind < 6:
            amount = max(1, balance * (kind + 1) // 10)
        elif kind < 8:
            amount = balance
        elif kind == 8:
            amount = balance + rng.randint(1, 50_000)
        else:
            amount = max(1, balance // 2)
        out.append(Credit(amount, "PAYEUR", None, ("ECHEANCE",), rf, account, "auto", "scale"))
    return out


def test_allocate_50k_payments(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.INFO, logger="collectoo.payments")
    tenant = bank_tenant()
    store = storage()
    started = time.monotonic()
    _board(tenant, tmp_path)
    boarded = time.monotonic()
    files = [f for f in _files(tenant) if f[2] > 0][:FILES]
    credits = _credits(files)
    pay(tenant, store, credits, prefix="A", days=5, allocate=False)  # imported and matched only
    matched = time.monotonic()
    with psycopg.connect(DB) as conn:  # what the match queued (taken off above), timed on its own
        conn.execute(
            "select pgmq.send('payments', jsonb_build_object('type', 'allocate',"
            " 'organization_id', %s::text))",
            (str(tenant["servicer"]),),
        )
    drain_payments(store)  # the allocation jobs: 10k payments each, then their continuation
    allocated = time.monotonic()
    logs = [r.getMessage() for r in caplog.records if r.getMessage().startswith("allocate ")]
    print(
        f"\n{len(files)} files boarded in {boarded - started:.0f}s; {len(credits)} credits imported"
        f" + matched in {matched - boarded:.1f}s; allocated in {allocated - matched:.1f}s"
        "\n  " + "\n  ".join(logs)
    )
    org = tenant["servicer"]
    with psycopg.connect(DB) as conn:
        statuses: dict[str, int] = dict(
            conn.execute(
                """select coalesce(review_reason, status), count(*) from public.payment
                   where organization_id = %s group by 1""",
                (org,),
            ).fetchall()
        )
        print(f"  payments: {statuses}")
        # every payment matched by its RF reached the ledger (or a reason ops can read)
        assert statuses.get("matched", 0) == 0 and statuses.get("unmatched", 0) == 0, statuses
        assert statuses.get("allocated", 0) + statuses.get("overpayment", 0) == len(credits), (
            statuses
        )
        # Σ received = Σ allocated + Σ unallocated (I5), from the ledger
        positions = conn.execute(
            """select sum(x.amount_minor), sum(x.allocated_minor), sum(x.unallocated_minor),
                      count(*) filter (where x.unallocated_minor < 0)
               from private.payment_positions(
                 array(select id from public.payment where organization_id = %s)) x""",
            (org,),
        ).fetchone()
        assert positions is not None
        assert positions[0] == positions[1] + positions[2] and positions[3] == 0
        assert positions[0] == sum(c.amount_minor for c in credits)
        # no receivable below zero; client money closed (I8)
        negative = one(
            conn,
            """select count(*) from (
                 select la.id from public.ledger_account la
                 join public.ledger_posting lp on lp.ledger_account_id = la.id
                 where la.organization_id = %s and la.book = 'debtor_receivable'
                 group by la.id having sum(lp.amount_minor) < 0) x""",
            (org,),
        )
        assert negative == 0
        money = one(
            conn,
            """select coalesce(sum(lp.amount_minor), 0) from public.ledger_account la
               join public.ledger_posting lp on lp.ledger_account_id = la.id
               where la.organization_id = %s
                 and la.book in ('client_money_cash', 'unallocated_payment', 'client_payable')""",
            (org,),
        )
        assert money == 0
        # M2-11: one notification per allocation entry
        entries, notified = conn.execute(
            """select count(*), count(n.id) from public.ledger_entry e
               left join public.client_notification n on n.ledger_entry_id = e.id
               where e.organization_id = %s and e.entry_type = 'allocation'""",
            (org,),
        ).fetchone() or (0, 0)
        assert entries == notified == len(credits)
        # consumer loans: the seller's unclassified amounts are never paid by allocation (#6)
        unclassified = one(
            conn,
            """select count(*) from public.ledger_entry e
               join public.ledger_posting lp on lp.entry_id = e.id
               join public.ledger_account la on la.id = lp.ledger_account_id
               join public.account a on a.id = e.account_id
               where e.organization_id = %s and e.entry_type = 'allocation'
                 and la.component in ('other_balances', 'balancing_line')
                 and a.legal_regime like 'consumer%%'""",
            (org,),
        )
        assert unclassified == 0
    assert allocated - matched < 240
