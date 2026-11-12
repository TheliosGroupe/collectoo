"""What a statement did, read from its plan (ARCHITECTURE §4; ADR-0014 « M2c-6b-1 review fixes »):
auto_explain's JSON plans of every statement a call runs, nested ones included (row counts and
buffers, no timing), and what each plan node handled. Deterministic — rows and pages, whatever the
cache. Needs `make up` (the local stack's superuser: auto_explain's settings are its own)."""

import json
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

import psycopg
from integration_helpers import DB
from psycopg.conninfo import make_conninfo

# The local stack's superuser (Supabase CLI default, as the CI workflow uses it).
ADMIN = make_conninfo(DB, user="supabase_admin")


@contextmanager
def explained(
    conn: psycopg.Connection[Any],
    min_duration_ms: int = 0,
    into: list[dict[str, Any]] | None = None,
) -> Iterator[list[dict[str, Any]]]:
    """Every statement `conn` runs meanwhile, nested ones included, longer than `min_duration_ms`:
    its plan under EXPLAIN ANALYZE without timing, with buffers — the list filled as each
    statement ends ({"Query Text", "Plan"}). `conn` is a superuser's, entered and left with its
    own role (the caller may `set role postgres` meanwhile: the worker's role, owner of the
    functions and of the temporary tables they write). Off again afterwards. `into`: the list to
    fill (a new one by default)."""
    plans: list[dict[str, Any]] = [] if into is None else into

    def collect(d: psycopg.errors.Diagnostic) -> None:
        msg = d.message_primary or ""
        if "plan:" in msg:
            plans.append(json.loads(msg.split("plan:", 1)[1]))

    conn.add_notice_handler(collect)
    for setting in (
        "load 'auto_explain'",
        f"set auto_explain.log_min_duration = {int(min_duration_ms)}",
        "set auto_explain.log_analyze = on",
        "set auto_explain.log_timing = off",
        "set auto_explain.log_buffers = on",
        "set auto_explain.log_format = 'json'",
        "set auto_explain.log_nested_statements = on",
        "set client_min_messages = log",
    ):
        conn.execute(setting)
    try:
        yield plans
    finally:
        failed = conn.info.transaction_status == psycopg.pq.TransactionStatus.INERROR
        for setting in (
            ()
            if failed
            else (  # (a failed transaction: rolled back by the caller)
                "set client_min_messages = notice",
                "reset auto_explain.log_min_duration",
                "reset auto_explain.log_analyze",
                "reset auto_explain.log_nested_statements",
            )
        ):
            conn.execute(setting)
        conn.remove_notice_handler(collect)


def work(node: dict[str, Any]) -> int:
    """The rows a plan node and its children handled: those each node returned, and those its
    filters, join filters and rechecks threw away (a table read whole, or rows compared n²)."""
    loops = int(node.get("Actual Loops", 1))
    n = loops * (
        int(node.get("Actual Rows", 0))
        + int(node.get("Rows Removed by Filter", 0))
        + int(node.get("Rows Removed by Join Filter", 0))
        + int(node.get("Rows Removed by Index Recheck", 0))
    )
    return n + sum(work(c) for c in node.get("Plans", []))


def temp_blocks(node: dict[str, Any]) -> int:
    """The temporary-file blocks a plan node and its children wrote (a sort or a hash that did not
    fit in work_mem: 392 MB for one batch line of 5,000 members, review round 2's P1)."""
    return int(node.get("Temp Written Blocks", 0)) + sum(
        temp_blocks(c) for c in node.get("Plans", [])
    )


def statement(plan: dict[str, Any]) -> str:
    """The statement's first words (its text squeezed to one line), to name it in a message."""
    return " ".join(str(plan.get("Query Text", "")).split())[:90]
