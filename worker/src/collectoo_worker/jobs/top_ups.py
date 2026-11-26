"""Job `remittances.top_ups {organization_id}` (M2c-7e-1; plan docs/design/m2c-7-plan.md §7.1,
design §13 #4, [critic] F8): what one servicer owes its dedicated account, ordered back from its
own account.

pg_cron `servicer-top-ups` (minute 37 of every hour) queues one message per servicer with an
active dedicated account (`private.queue_top_ups`); each message is handled in its own
transaction (the queue's), so the advisory locks one servicer takes never wait on, nor hold up,
another's. Under a savepoint, `private.order_due_top_up` (lock_timeout 2 s) takes the servicer's
allocation and remit locks, logs its shortfall period and orders exactly what design §13 #4's
formula says is needed (an ordered top-up lowers it: idempotent hour after hour). When the lock is
held past 2 s (a file generation, a « Désimputer », the debit job: SQLSTATE 55P03) the step is
rolled back and the servicer is skipped until the next hour: a miss is recorded; a data error is
recorded as a failure (the queue does not retry it: the next hour does); any other error fails
the job, which the queue retries, and its dead-letter records a failure. The nightly alerts
`top_up_order_failed` after three consecutive misses or any failure (`private.top_up_order_state`).
No model, no LLM: the amount is the ledger's (CLAUDE.md).
"""

from __future__ import annotations

import logging
import time
from typing import Any

import psycopg

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.remittances")
LOCK_NOT_AVAILABLE = "55P03"


def deterministic(exc: psycopg.Error) -> bool:
    """Data, constraint and ledger errors fail the same way on every retry (jobs.remittances)."""
    return (exc.sqlstate or "").startswith(("LG", "22", "23"))


def _record(conn: Conn, org: str, outcome: str, ordered: int, error: str | None) -> None:
    conn.execute(
        "select private.record_top_up_order(%s, %s, %s, %s)",
        (org, outcome, ordered, (error or None) and error[:2000]),
    )


def run_top_ups(conn: Conn, payload: dict[str, Any]) -> dict[str, Any]:
    org = str(payload["organization_id"])
    started = time.monotonic()
    try:
        with conn.transaction():
            row = conn.execute("select private.order_due_top_up(%s)", (org,)).fetchone()
    except psycopg.Error as exc:
        state = exc.sqlstate or ""
        message = exc.diag.message_primary or str(exc)
        if state == LOCK_NOT_AVAILABLE:
            log.info("top-ups %s: the servicer's lock is held; skipped until the next hour", org)
            _record(conn, org, "missed", 0, f"{state}: {message}")
            return {"status": "missed"}
        if deterministic(exc):
            log.warning("top-ups %s: not ordered (%s %s)", org, state, message)
            _record(conn, org, "failed", 0, f"{state}: {message}")
            return {"status": "failed", "error": message}
        raise
    ordered = int(row[0]) if row and row[0] is not None else 0
    _record(conn, org, "done", ordered, None)
    if ordered:
        log.info("top-ups %s: %d ordered, %.2fs", org, ordered, time.monotonic() - started)
    return {"status": "done", "ordered": ordered}


def record_dead_job(payload: dict[str, Any], error: str, conn: Conn) -> None:
    """Retried to the end: recorded as a failure for the nightly (top_up_order_failed)."""
    org = payload.get("organization_id")
    if org:
        _record(conn, str(org), "failed", 0, error)
