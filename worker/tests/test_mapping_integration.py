"""Integration (needs `make up`): profile -> propose -> approve -> reuse of the saved mapping."""

import hashlib
import json
import os
import uuid
from pathlib import Path
from typing import Any

import psycopg
import pytest

from collectoo_worker.ai.mock import MockProvider
from collectoo_worker.boarding.mapping import header_signature
from collectoo_worker.jobs.boarding import make_handler
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.runtime.storage import SupabaseStorage
from collectoo_worker.synth.civil import write_civil

pytestmark = pytest.mark.integration
DB = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")


def _one(conn: psycopg.Connection[Any], sql: str, params: tuple[Any, ...] = ()) -> Any:
    row = conn.execute(sql, params).fetchone()
    assert row is not None
    return row[0]


@pytest.fixture
def tenant() -> dict[str, Any]:
    with psycopg.connect(DB) as conn, conn.transaction():
        servicer = _one(
            conn,
            "insert into public.organization (kind, legal_name)"
            " values ('servicer', 'S') returning id",
        )
        client = _one(
            conn,
            "insert into public.organization (kind, servicer_organization_id, legal_name)"
            " values ('creditor_client', %s, 'C') returning id",
            (servicer,),
        )
        portfolio = _one(
            conn,
            "insert into public.portfolio (organization_id, client_organization_id, name)"
            " values (%s, %s, 'P') returning id",
            (servicer, client),
        )
        user = uuid.uuid4()
        conn.execute(
            "insert into auth.users (id, email, aud, role)"
            " values (%s, %s, 'authenticated', 'authenticated')",
            (user, f"{user}@c.test"),
        )
        conn.execute(
            "insert into public.membership (user_id, organization_id, role)"
            " values (%s, %s, 'client_admin')",
            (user, client),
        )
    return {"client": client, "portfolio": portfolio, "user": str(user)}


def _as_user(conn: psycopg.Connection[Any], user: str) -> None:
    claims = json.dumps({"sub": user, "role": "authenticated", "aal": "aal1"})
    conn.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
    conn.execute("set local role authenticated")


def _board(tenant: dict[str, Any], storage: SupabaseStorage, path: Path) -> str:
    """Create a batch, upload the file and submit, as the client admin (through the commands)."""
    data = path.read_bytes()
    with psycopg.connect(DB) as conn, conn.transaction():
        _as_user(conn, tenant["user"])
        batch = _one(
            conn,
            "select public.create_boarding_batch(%s, %s)",
            (str(uuid.uuid4()), tenant["portfolio"]),
        )
        reg = _one(
            conn,
            "select public.add_boarding_file(%s, %s, %s, %s)",
            (batch, path.name, hashlib.sha256(data).hexdigest(), len(data)),
        )
    storage.upload("boarding-uploads", reg["storage_path"], data, "text/csv")
    with psycopg.connect(DB) as conn, conn.transaction():
        _as_user(conn, tenant["user"])
        conn.execute("select public.submit_boarding_batch(%s)", (batch,))
    return str(batch)


def _drain(storage: SupabaseStorage) -> None:
    consumer = QueueConsumer(DB, "boarding", make_handler(storage, MockProvider()))
    while consumer.poll_once():
        pass


def test_proposal_review_and_reuse(tenant: dict[str, Any], tmp_path: Path) -> None:
    storage = SupabaseStorage(
        os.environ.get("SUPABASE_URL", "http://127.0.0.1:54321"), os.environ["SUPABASE_SECRET_KEY"]
    )
    path = write_civil("b2b_invoice", "fr_semicolon", 150, 4, tmp_path)

    batch = _board(tenant, storage, path)
    _drain(storage)
    with psycopg.connect(DB) as conn:
        assert (
            _one(conn, "select status from public.boarding_batch where id = %s", (batch,))
            == "mapping_proposed"
        )
        rows = conn.execute(
            "select source_column, target, origin, file_id"
            " from public.mapping_proposal where batch_id = %s",
            (batch,),
        ).fetchall()
        logged = _one(
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
        _as_user(conn, tenant["user"])
        conn.execute(
            "select public.approve_mapping(%s, %s)",
            (batch, json.dumps({file_id: {"IBAN": None}})),
        )
    with psycopg.connect(DB) as conn:
        status = _one(conn, "select status from public.boarding_batch where id = %s", (batch,))
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
    batch2 = _board(
        tenant, storage, write_civil("b2b_invoice", "fr_semicolon", 90, 8, tmp_path / "again")
    )
    _drain(storage)
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
    storage = SupabaseStorage(
        os.environ.get("SUPABASE_URL", "http://127.0.0.1:54321"), os.environ["SUPABASE_SECRET_KEY"]
    )
    batch = _board(tenant, storage, write_civil("rent", "en_comma", 40, 2, tmp_path))
    _drain(storage)
    with psycopg.connect(DB) as conn:
        file_id = str(
            _one(conn, "select id from public.boarding_file where batch_id = %s", (batch,))
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
            _as_user(conn, tenant["user"])
            conn.execute("select public.approve_mapping(%s, %s)", (batch, json.dumps(overrides)))
