"""Integration (needs `make up`): queue exactly-once effects and the profiling job end to end."""

import hashlib
import json
import os
import uuid
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import psycopg
import pytest

from collectoo_worker.ai.mock import MockProvider
from collectoo_worker.jobs.boarding import make_handler
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.runtime.storage import SupabaseStorage
from collectoo_worker.synth.civil import write_civil

pytestmark = pytest.mark.integration
DB = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")


@pytest.fixture
def queue() -> Iterator[str]:
    name = f"t_{uuid.uuid4().hex[:8]}"
    with psycopg.connect(DB, autocommit=True) as conn:
        conn.execute("select pgmq.create(%s)", (name,))
        conn.execute("select pgmq.create(%s)", (f"{name}_dlq",))
        conn.execute(f"create table public.{name}_effects (msg text)")
    yield name
    with psycopg.connect(DB, autocommit=True) as conn:
        conn.execute("select pgmq.drop_queue(%s)", (name,))
        conn.execute("select pgmq.drop_queue(%s)", (f"{name}_dlq",))
        conn.execute(f"drop table public.{name}_effects")


def _send(queue: str, payload: dict[str, Any]) -> int:
    with psycopg.connect(DB, autocommit=True) as conn:
        row = conn.execute(
            "select pgmq.send(%s, %s::jsonb)", (queue, json.dumps(payload))
        ).fetchone()
        assert row is not None
        return int(row[0])


def _effects(queue: str) -> int:
    with psycopg.connect(DB) as conn:
        row = conn.execute(f"select count(*) from public.{queue}_effects").fetchone()  # noqa: S608
        assert row is not None
        return int(row[0])


def _make_visible(queue: str, msg_id: int) -> None:
    with psycopg.connect(DB, autocommit=True) as conn:
        conn.execute("select pgmq.set_vt(%s, %s::bigint, 0)", (queue, msg_id))


def test_a_killed_worker_does_not_double_process(queue: str) -> None:
    crash = {"on": True}

    def handler(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        conn.execute(f"insert into public.{queue}_effects values (%s)", (payload["n"],))  # noqa: S608
        if crash["on"]:
            raise KeyboardInterrupt  # the process dies mid-job, after a write

    msg_id = _send(queue, {"n": "1"})
    consumer = QueueConsumer(DB, queue, handler, visibility_timeout_s=30)
    with pytest.raises(KeyboardInterrupt):
        consumer.poll_once()
    assert _effects(queue) == 0  # the write died with the transaction
    crash["on"] = False
    _make_visible(queue, msg_id)  # visibility timeout elapsed
    assert consumer.poll_once() == 1
    assert _effects(queue) == 1
    _make_visible(queue, msg_id)
    assert consumer.poll_once() == 0  # archived: nothing left to read


def test_failures_retry_then_dead_letter(queue: str) -> None:
    calls = {"n": 0}

    def handler(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        calls["n"] += 1
        raise ValueError("boom")

    dead: list[tuple[dict[str, Any], str]] = []
    msg_id = _send(queue, {"n": "x"})
    consumer = QueueConsumer(
        DB,
        queue,
        handler,
        max_attempts=2,
        backoff_base_s=60,
        on_dead=lambda payload, error, conn: dead.append((payload, error)),
    )
    for _ in range(3):
        consumer.poll_once()
        _make_visible(queue, msg_id)
    assert calls["n"] == 2
    assert dead == [({"n": "x"}, "ValueError: boom")]  # the job's owner is told once
    with psycopg.connect(DB) as conn:
        status = conn.execute(
            "select status, last_error from private.job_run where queue = %s and msg_id = %s",
            (queue, msg_id),
        ).fetchone()
        dlq = conn.execute(f"select count(*) from pgmq.q_{queue}_dlq").fetchone()  # noqa: S608
    assert status == ("dead", "ValueError: boom")
    assert dlq == (1,)


def test_profile_job_end_to_end(tmp_path: Path) -> None:
    url = os.environ.get("SUPABASE_URL", "http://127.0.0.1:54321")
    key = os.environ["SUPABASE_SECRET_KEY"]
    storage = SupabaseStorage(url, key)
    path = write_civil("b2b_invoice", "fr_semicolon", 300, 9, tmp_path)
    data = path.read_bytes()
    with psycopg.connect(DB) as conn, conn.transaction():
        servicer = conn.execute(
            "insert into public.organization (kind, legal_name)"
            " values ('servicer', 'S') returning id"
        ).fetchone()[0]  # type: ignore[index]
        client = conn.execute(
            "insert into public.organization (kind, servicer_organization_id, legal_name)"
            " values ('creditor_client', %s, 'C') returning id",
            (servicer,),
        ).fetchone()[0]  # type: ignore[index]
        portfolio = conn.execute(
            "insert into public.portfolio (organization_id, client_organization_id, name)"
            " values (%s, %s, 'P') returning id",
            (servicer, client),
        ).fetchone()[0]  # type: ignore[index]
        batch = conn.execute(
            "insert into public.boarding_batch"
            " (organization_id, client_organization_id, portfolio_id, version)"
            " values (%s, %s, %s, 1) returning id",
            (servicer, client, portfolio),
        ).fetchone()[0]  # type: ignore[index]
        storage_path = f"{client}/{batch}/f/{path.name}"
        conn.execute(
            "insert into public.boarding_file"
            " (batch_id, file_name, format, storage_path, sha256, size_bytes, status)"
            " values (%s, %s, 'csv', %s, %s, %s, 'uploaded')",
            (batch, path.name, storage_path, hashlib.sha256(data).hexdigest(), len(data)),
        )
        conn.execute("select private.transition_batch(%s, 'uploaded')", (batch,))
    storage.upload("boarding-uploads", storage_path, data, "text/csv")
    _send("boarding", {"type": "profile", "batch_id": str(batch)})

    consumer = QueueConsumer(DB, "boarding", make_handler(storage, MockProvider()))
    while consumer.poll_once():
        pass
    with psycopg.connect(DB) as conn:
        status = conn.execute(
            "select status from public.boarding_batch where id = %s", (batch,)
        ).fetchone()
        file_row = conn.execute(
            "select status, row_count, profile -> 'csv' ->> 'separator'"
            " from public.boarding_file where batch_id = %s",
            (batch,),
        ).fetchone()
    assert status == ("mapping_proposed",)  # profiling queues the mapping proposal
    assert file_row == ("profiled", 300, ";")
