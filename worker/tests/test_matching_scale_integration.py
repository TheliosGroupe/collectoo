"""M2-08 scale (needs `make up`): 50,000 files boarded from a synthetic EU loan tape (as the M1-21
run), a statement of earlier payments (what teaches the IBAN memory), then a 50,000-credit
statement imported and matched by the `payments.match` job. Prints the job's timings
(docs/benchmarks/payments.md) and asserts the acceptance numbers: ≥ 95 % automatic, none wrong,
every other credit in the queue with its reason. MATCH_FILES / MATCH_CREDITS change the sizes.
Both imports run with bank_transaction's statistics taken before the account had any line (as CI met
them: the lookups of a 50k import must not rest on fresh statistics)."""

import json
import logging
import os
import random
import time
import uuid
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, as_user, board, drain, one, ready_mandate, storage
from reconciliation_helpers import pay, score, world_from_db
from statement_helpers import bank_tenant
from stats_helpers import analyse, estimated_rows, frozen_statistics, lines_of_another_account

from collectoo_worker.bench import generate
from collectoo_worker.synth.reconciliation import generate_credits, history_credits, with_history

pytestmark = pytest.mark.integration
FILES = int(os.environ.get("MATCH_FILES", "50000"))
CREDITS = int(os.environ.get("MATCH_CREDITS", "50000"))


def _board(tenant: dict[str, Any], tmp_path: Path, count: int = FILES) -> None:
    """Upload, mapping, commit, confirmation: the files are confirmed, with balances and RFs."""
    generate(count, tmp_path)
    store = storage()
    files = [tmp_path / f"{t}.csv" for t in ("t1_counterparty", "t2_1_borrower_loan", "t3_loan")]
    batch = board(tenant, store, *files)
    drain(store)
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.approve_mapping(%s, %s)", (batch, json.dumps({})))
    drain(store)
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.commit_boarding_batch(%s)", (batch,))
    drain(store)
    with psycopg.connect(DB) as conn, conn.transaction():
        ready_mandate(conn, tenant, f"M-{uuid.uuid4().hex[:6]}")
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["staff"], aal="aal2")
        conn.execute("select public.confirm_boarding_batch(%s)", (batch,))
    drain(store)
    with psycopg.connect(DB) as conn:
        assert one(conn, "select status from public.boarding_batch where id = %s", (batch,)) == (
            "confirmed"
        )


def _match_logs(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [r.getMessage() for r in caplog.records if r.getMessage().startswith("match ")]


def _import_logs(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [r.getMessage() for r in caplog.records if " imported: " in r.getMessage()]


def test_match_50k_payments_against_50k_files(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO, logger="collectoo.payments")
    tenant = bank_tenant()
    store = storage()
    started = time.monotonic()
    _board(tenant, tmp_path)
    boarded = time.monotonic()
    world = with_history(world_from_db(tenant), random.Random(3))
    history = history_credits(world, seed=3)
    credits = generate_credits(world, CREDITS, seed=4, earlier=history)
    # bank_transaction analysed while this account had no line, not again until both imports are
    # done (CI: the 50k import's lookups planned for 1 line of the account, 13.5k in fact; its entry
    # check took 133 s)
    lines_of_another_account(store, tenant["bank"])
    with frozen_statistics("public.bank_transaction") as conn:
        analyse(conn, "public.bank_transaction")
        hist_started = time.monotonic()
        # matching only (the allocation of these payments is measured by the allocation scale test)
        hist = score(pay(tenant, store, history, prefix="H", days=2, allocate=False), history, "H")
        hist_s = time.monotonic() - hist_started
        assert hist.wrong == [] and hist.auto == hist.total
        estimate = estimated_rows(
            conn,
            "select 1 from public.bank_transaction where bank_account_id = %s",
            (tenant["bank"],),
        )
        assert estimate < len(history) // 100, estimate  # the state the imports must not mind
        main_started = time.monotonic()
        statement = pay(tenant, store, credits, prefix="M", days=5, allocate=False)
        main_s = time.monotonic() - main_started
    result = score(statement, credits, "M")
    logs = _match_logs(caplog)
    imports = _import_logs(caplog)
    ingest_s = float(imports[-1].rsplit(" ingest ", 1)[1].rstrip("s")) if imports else 0.0
    print(
        f"\n{len(world.accounts)} files boarded in {boarded - started:.0f}s;"
        f" history: {len(history)} credits imported + matched in {hist_s:.1f}s;"
        f" statement: {len(credits)} credits imported + matched in {main_s:.1f}s"
        f" (lines of the account estimated at {estimate} before it)"
        f"\n  {imports[-1] if imports else '?'}"
        f"\n  {logs[-1] if logs else '?'}\n" + json.dumps(result.report(), indent=1)
    )
    assert result.wrong == [], result.wrong[:5]
    assert result.policy_violations == [], result.policy_violations[:5]  # founder #3
    assert result.bad_reason == [], result.bad_reason[:5]
    assert result.rate >= 0.95, result.report()
    assert result.ready_rate >= 0.95, result.report()  # and not held by the gating
    assert main_s < 240
    # the import's lookups keyed whatever the statistics (its entry check alone took 133 s in CI)
    assert 0 < ingest_s < 60, imports[-1:]
