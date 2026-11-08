"""Integration (needs `make up`): profile -> propose -> approve -> reuse of the saved mapping."""

import json
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, as_user, board, drain, make_tenant, one, storage

from collectoo_worker.boarding.mapping import header_signature
from collectoo_worker.synth.civil import write_civil

pytestmark = pytest.mark.integration


@pytest.fixture
def tenant() -> dict[str, Any]:
    return make_tenant()


def test_proposal_review_and_reuse(tenant: dict[str, Any], tmp_path: Path) -> None:
    store = storage()
    path = write_civil("b2b_invoice", "fr_semicolon", 150, 4, tmp_path)

    batch = board(tenant, store, path)
    drain(store)
    with psycopg.connect(DB) as conn:
        assert (
            one(conn, "select status from public.boarding_batch where id = %s", (batch,))
            == "mapping_proposed"
        )
        rows = conn.execute(
            "select source_column, target, origin, file_id"
            " from public.mapping_proposal where batch_id = %s",
            (batch,),
        ).fetchall()
        logged = one(
            conn,
            "select count(*) from private.llm_call where batch_id = %s and status = 'ok'",
            (batch,),
        )
    assert len(rows) == 17 and {r[2] for r in rows} == {"mock"}
    assert dict((r[0], r[1]) for r in rows)["Échéance"] == "claim_item.due_date"
    assert logged == 1
    file_id = str(rows[0][3])

    # Review: the client admin overrides one column, then approves.
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute(
            "select public.approve_mapping(%s, %s)",
            (batch, json.dumps({file_id: {"IBAN": None}})),
        )
    with psycopg.connect(DB) as conn:
        status = one(conn, "select status from public.boarding_batch where id = %s", (batch,))
        saved = conn.execute(
            "select header_signature, version, mapping"
            " from public.mapping_profile where client_organization_id = %s",
            (tenant["client"],),
        ).fetchall()
    assert status == "mapping_approved"
    assert len(saved) == 1
    signature, version, mapping = saved[0]
    assert signature == header_signature(list(mapping))  # SQL and Python agree
    assert version == 1 and mapping["IBAN"] is None

    # Same layout again: the saved mapping is reused with full confidence, override included.
    batch2 = board(
        tenant, store, write_civil("b2b_invoice", "fr_semicolon", 90, 8, tmp_path / "again")
    )
    drain(store)
    with psycopg.connect(DB) as conn:
        rows2 = conn.execute(
            "select source_column, target, origin, confidence"
            " from public.mapping_proposal where batch_id = %s",
            (batch2,),
        ).fetchall()
    assert {r[2] for r in rows2} == {"profile"}
    assert {float(r[3]) for r in rows2} == {1.0}
    assert dict((r[0], r[1]) for r in rows2)["IBAN"] is None


def test_approval_rules(tenant: dict[str, Any], tmp_path: Path) -> None:
    store = storage()
    batch = board(tenant, store, write_civil("rent", "en_comma", 40, 2, tmp_path))
    drain(store)
    with psycopg.connect(DB) as conn:
        file_id = str(
            one(conn, "select id from public.boarding_file where batch_id = %s", (batch,))
        )
    bad = [
        ({file_id: {"no_such_column": "contact.city"}}, "unknown file or column"),
        ({file_id: {"amount": "claim_item.amount_paid"}}, "same target"),
    ]
    for overrides, message in bad:
        with (
            pytest.raises(psycopg.errors.CheckViolation, match=message),
            psycopg.connect(DB) as conn,
            conn.transaction(),
        ):
            as_user(conn, tenant["user"])
            conn.execute("select public.approve_mapping(%s, %s)", (batch, json.dumps(overrides)))
