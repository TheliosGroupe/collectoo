"""M1-21: a 50,000-loan synthetic EU-template tape boarded end to end (needs `make up`).

Upload -> profile -> mapping proposal (mock) -> approval -> transform + validate -> staging ->
commit -> confirmation (opening balances posted by the worker, M2-05). Runs in the CI database
job; target: well under 5 minutes (72 s locally, docs/benchmarks/boarding.md).
"""

import json
import os
import time
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, as_user, board, drain, make_tenant, one, storage

from collectoo_worker.bench import generate

pytestmark = pytest.mark.integration
LOANS = int(os.environ.get("SCALE_LOANS", "50000"))


def test_board_a_50k_loan_tape(tmp_path: Path) -> None:
    started = time.monotonic()
    counts = generate(LOANS, tmp_path)
    tenant: dict[str, Any] = make_tenant()
    store = storage()
    files = [tmp_path / f"{t}.csv" for t in ("t1_counterparty", "t2_1_borrower_loan", "t3_loan")]
    batch = board(tenant, store, *files)
    drain(store)
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.approve_mapping(%s, %s)", (batch, json.dumps({})))
    drain(store)
    with psycopg.connect(DB) as conn:
        status = one(conn, "select status from public.boarding_batch where id = %s", (batch,))
        report = one(conn, "select dq_report from public.boarding_batch where id = %s", (batch,))
    assert status == "staged", report["totals"]
    commit_started = time.monotonic()
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("set local statement_timeout = '8s'")  # what the API allows a request
        conn.execute("select public.commit_boarding_batch(%s)", (batch,))
    drain(store)  # M2a-3: the commit job writes the rows and the opening plan
    commit_s = time.monotonic() - commit_started
    # M2-05: confirmation (staff at aal2, active mandate) queues the job that posts the openings.
    with psycopg.connect(DB) as conn, conn.transaction():
        mandate = one(
            conn,
            "insert into public.mandate (organization_id, client_organization_id, reference,"
            " mandate_type, signed_on)"
            " values (%s, %s, %s, 'mandate_amicable', '2026-01-01') returning id",
            (tenant["servicer"], tenant["client"], f"M-{batch}"),
        )
        conn.execute(
            "insert into public.mandate_terms (mandate_id, valid_from, commission_rate)"
            " values (%s, '2026-01-01', 0.15)",
            (mandate,),
        )
        conn.execute(
            "update public.portfolio set mandate_id = %s where id = %s",
            (mandate, tenant["portfolio"]),
        )
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["staff"], aal="aal2")
        conn.execute("set local statement_timeout = '8s'")  # what the API allows a request
        conn.execute("select public.confirm_boarding_batch(%s)", (batch,))
    confirm_started = time.monotonic()
    drain(store)
    confirm_s = time.monotonic() - confirm_started
    with psycopg.connect(DB) as conn:
        status = one(conn, "select status from public.boarding_batch where id = %s", (batch,))
        openings = one(
            conn,
            "select count(*) from public.ledger_entry where boarding_batch_id = %s"
            " and entry_type = 'opening'",
            (batch,),
        )
        posted = one(
            conn,
            """select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_entry e
               join public.ledger_posting p on p.entry_id = e.id
               join public.ledger_account la on la.id = p.ledger_account_id
               where la.book = 'debtor_receivable' and e.boarding_batch_id = %s""",
            (batch,),
        )
        accounts = one(
            conn, "select count(*) from public.account where boarding_batch_id = %s", (batch,)
        )
        loans = one(conn, "select count(*) from eba.t3_loan where boarding_batch_id = %s", (batch,))
        parties = one(
            conn, "select count(*) from public.party where boarding_batch_id = %s", (batch,)
        )
        references = one(
            conn,
            """select count(*) from public.payment_reference r
               join public.account a on a.id = r.account_id
               where a.boarding_batch_id = %s and r.status = 'active'
                 and r.rf ~ '^RF[0-9]{14}$' and private.rf_valid(r.rf)""",
            (batch,),
        )
    # M2-06 backfill path (references for every workable account without one), timed on this
    # batch's accounts and rolled back.
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            """update public.payment_reference r set status = 'retired', retired_at = now(),
                 retired_reason = 'benchmark' from public.account a
               where a.id = r.account_id and a.boarding_batch_id = %s and r.status = 'active'""",
            (batch,),
        )
        backfill_started = time.monotonic()
        backfilled = one(conn, "select private.issue_payment_references(null)")
        backfill_s = time.monotonic() - backfill_started
        raise psycopg.Rollback  # nothing of this measurement stays
    elapsed = time.monotonic() - started
    print(
        f"\n50k boarding: {elapsed:.0f}s (commit {commit_s:.1f}s, confirm job {confirm_s:.1f}s),"
        f" accounts={accounts}, parties={parties}, openings={openings}, rows={counts},"
        f" RF references={references}; backfill of {backfilled} references {backfill_s:.1f}s"
    )
    assert accounts == loans == LOANS
    assert parties == counts["t1_counterparty"]
    assert report["claim_types"] == {
        k: v
        for k, v in report["claim_types"].items()
        if k in ("consumer_instalment_loan", "professional_loan")
    }
    assert report["reconciliation"]["computed"]["rows"] == LOANS
    assert status == "confirmed" and openings == LOANS
    assert references == LOANS and backfilled >= LOANS  # M2-06: one per workable account
    assert posted == int(report["reconciliation"]["computed"]["outstanding_minor"])  # M2-05
    assert elapsed < 300
