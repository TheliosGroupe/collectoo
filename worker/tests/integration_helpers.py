"""Shared helpers for integration tests (need `make up`)."""

import hashlib
import json
import os
import uuid
from pathlib import Path
from typing import Any

import psycopg

from collectoo_worker.ai.mock import MockProvider
from collectoo_worker.jobs.boarding import make_handler
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.runtime.storage import SupabaseStorage

DB = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")


def storage() -> SupabaseStorage:
    return SupabaseStorage(
        os.environ.get("SUPABASE_URL", "http://127.0.0.1:54321"), os.environ["SUPABASE_SECRET_KEY"]
    )


def one(conn: psycopg.Connection[Any], sql: str, params: tuple[Any, ...] = ()) -> Any:
    row = conn.execute(sql, params).fetchone()
    assert row is not None
    return row[0]


def make_tenant() -> dict[str, Any]:
    with psycopg.connect(DB) as conn, conn.transaction():
        servicer = one(
            conn,
            "insert into public.organization (kind, legal_name)"
            " values ('servicer', 'S') returning id",
        )
        client = one(
            conn,
            "insert into public.organization (kind, servicer_organization_id, legal_name)"
            " values ('creditor_client', %s, 'C') returning id",
            (servicer,),
        )
        portfolio = one(
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
        staff = uuid.uuid4()
        conn.execute(
            "insert into auth.users (id, email, aud, role)"
            " values (%s, %s, 'authenticated', 'authenticated')",
            (staff, f"{staff}@s.test"),
        )
        conn.execute(
            "insert into public.membership (user_id, organization_id, role)"
            " values (%s, %s, 'ops_manager')",
            (staff, servicer),
        )
    return {
        "servicer": servicer,
        "client": client,
        "portfolio": portfolio,
        "user": str(user),
        "staff": str(staff),
    }


def as_user(conn: psycopg.Connection[Any], user: str, aal: str = "aal1") -> None:
    claims = json.dumps({"sub": user, "role": "authenticated", "aal": aal})
    conn.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
    conn.execute("set local role authenticated")


def board(tenant: dict[str, Any], storage: SupabaseStorage, *paths: Path) -> str:
    """Create a batch, upload the files and submit, as the client admin (through the commands)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        batch = one(
            conn,
            "select public.create_boarding_batch(%s, %s)",
            (str(uuid.uuid4()), tenant["portfolio"]),
        )
        regs = []
        for path in paths:
            data = path.read_bytes()
            reg = one(
                conn,
                "select public.add_boarding_file(%s, %s, %s, %s)",
                (batch, path.name, hashlib.sha256(data).hexdigest(), len(data)),
            )
            regs.append((reg["storage_path"], data))
    for storage_path, data in regs:
        storage.upload("boarding-uploads", storage_path, data, "application/octet-stream")
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.submit_boarding_batch(%s)", (batch,))
    return str(batch)


def drain(storage: SupabaseStorage) -> None:
    consumer = QueueConsumer(DB, "boarding", make_handler(storage, MockProvider()))
    while consumer.poll_once():
        pass
