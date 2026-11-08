"""M1-21: a 50,000-loan synthetic EU-template tape boarded end to end (needs `make up`).

Upload -> profile -> mapping proposal (mock) -> approval -> transform + validate -> staging ->
commit. Runs in the CI database job; target: well under 5 minutes.
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
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.commit_boarding_batch(%s)", (batch,))
    with psycopg.connect(DB) as conn:
        accounts = one(
            conn, "select count(*) from public.account where boarding_batch_id = %s", (batch,)
        )
        loans = one(conn, "select count(*) from eba.t3_loan where boarding_batch_id = %s", (batch,))
        parties = one(
            conn, "select count(*) from public.party where boarding_batch_id = %s", (batch,)
        )
    elapsed = time.monotonic() - started
    print(f"\n50k boarding: {elapsed:.0f}s, accounts={accounts}, parties={parties}, rows={counts}")
    assert accounts == loans == LOANS
    assert parties == counts["t1_counterparty"]
    assert report["claim_types"] == {
        k: v
        for k, v in report["claim_types"].items()
        if k in ("consumer_instalment_loan", "professional_loan")
    }
    assert report["reconciliation"]["computed"]["rows"] == LOANS
    assert elapsed < 300
