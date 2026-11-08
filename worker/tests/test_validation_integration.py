"""Integration (needs `make up`): approve -> transform + validate -> needs_fix or validated."""

import json
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, as_user, board, drain, make_tenant, one, storage

from collectoo_worker.synth.civil import write_civil

pytestmark = pytest.mark.integration


@pytest.fixture
def tenant() -> dict[str, Any]:
    return make_tenant()


def _approve(tenant: dict[str, Any], batch: str, control_minor: int | None = None) -> None:
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        if control_minor is not None:
            conn.execute("select public.set_control_totals(%s, %s, %s)", (batch, control_minor, 0))
        conn.execute("select public.approve_mapping(%s, %s)", (batch, json.dumps({})))


def test_defective_file_needs_fix_with_issues(tenant: dict[str, Any], tmp_path: Path) -> None:
    store = storage()
    path = write_civil("b2b_invoice", "fr_semicolon", 300, 13, tmp_path)
    manifest = json.loads(path.with_suffix(".manifest.json").read_text())
    batch = board(tenant, store, path)
    drain(store)
    _approve(tenant, batch)
    drain(store)
    with psycopg.connect(DB) as conn:
        status = one(conn, "select status from public.boarding_batch where id = %s", (batch,))
        issues = conn.execute(
            "select row_number, code, severity from public.validation_issue where batch_id = %s",
            (batch,),
        ).fetchall()
        report = one(conn, "select dq_report from public.boarding_batch where id = %s", (batch,))
        events = [r[0] for r in conn.execute(
            "select to_status from public.boarding_event where batch_id = %s order by id", (batch,)
        ).fetchall()]  # fmt: skip
    assert status == "needs_fix"
    assert events[-2:] == ["transformed", "needs_fix"]
    found = {(r[0], r[1]) for r in issues}
    expected = {
        "impossible_date",
        "negative_amount",
        "invalid_siren",
        "missing_contact",
        "duplicate_row",
        "mixed_date_format",
        "overpaid",
    }
    for d in manifest["defects"]:
        if d["type"] in expected:
            assert (d["row"], d["type"]) in found, d
    assert report["totals"]["blocking"] > 0
    assert report["spec_versions"] == {"transform": 1, "validation": 1, "claim_types": 1}
    assert report["claim_types"] == {"b2b_invoice": 300}


def test_clean_file_is_validated_with_a_full_report(tenant: dict[str, Any], tmp_path: Path) -> None:
    store = storage()
    path = write_civil("rent", "tab_dotted", 120, 4, tmp_path)
    # A clean copy: regenerate without defects through the generator's API.
    from collectoo_worker.synth.civil import DIALECT_SPECS, generate_civil  # noqa: PLC0415

    table, _ = generate_civil("rent", "tab_dotted", 120, 4, defect_rate=0)
    path.write_text("\n".join(DIALECT_SPECS["tab_dotted"].delimiter.join(r) for r in table) + "\n")
    batch = board(tenant, store, path)
    drain(store)
    _approve(tenant, batch, control_minor=0)
    drain(store)
    with psycopg.connect(DB) as conn:
        status = one(conn, "select status from public.boarding_batch where id = %s", (batch,))
        report = one(conn, "select dq_report from public.boarding_batch where id = %s", (batch,))
        blocking = one(
            conn,
            "select count(*) from public.validation_issue"
            " where batch_id = %s and severity = 'blocking'",
            (batch,),
        )
    assert status == "staged" and blocking == 0  # validated, then staged automatically
    rec = report["reconciliation"]
    assert (
        rec["status"] == "mismatch"
        and rec["difference_minor"] == rec["computed"]["total_minor"] > 0
    )
    assert report["legal_regimes"] == {"civil": 120}
    assert report["addresses"]["provider"] == "mock" and report["addresses"]["addresses"] == 120
    assert 0 < report["contactability"]["any_pct"] <= 1
