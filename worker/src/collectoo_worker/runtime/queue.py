"""pgmq consumer (M1-03): exactly-once effects on top of at-least-once delivery.

Each message is handled inside ONE database transaction that also records the job as done and
archives the message. If the worker dies mid-job, the transaction rolls back and the message
becomes visible again after its visibility timeout: the job reruns from scratch, and no effect
is applied twice. Failures are retried with exponential backoff, then dead-lettered.
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

log = logging.getLogger("collectoo.queue")

Handler = Callable[[dict[str, Any], psycopg.Connection[Any]], None]
DeadHandler = Callable[[dict[str, Any], str, psycopg.Connection[Any]], None]


@dataclass(frozen=True)
class Message:
    msg_id: int
    read_ct: int
    payload: dict[str, Any]


@dataclass
class QueueConsumer:
    conninfo: str
    queue: str
    handler: Handler
    visibility_timeout_s: int = 300
    max_attempts: int = 5
    backoff_base_s: int = 10
    # Called in the dead-letter transaction with (payload, last error, conn): lets the job's
    # owner record the failure where users can see it.
    on_dead: DeadHandler | None = None

    @property
    def dlq(self) -> str:
        return f"{self.queue}_dlq"

    def poll_once(self, batch: int = 1) -> int:
        """Read and handle up to `batch` messages. Returns how many were read."""
        with psycopg.connect(self.conninfo, autocommit=True) as conn:
            rows = conn.execute(
                "select msg_id, read_ct, message from pgmq.read(%s, %s, %s)",
                (self.queue, self.visibility_timeout_s, batch),
            ).fetchall()
        for msg_id, read_ct, payload in rows:
            self._handle(Message(int(msg_id), int(read_ct), dict(payload)))
        return len(rows)

    def run_forever(self, idle_sleep_s: float = 1.0) -> None:  # pragma: no cover - loop
        log.info("consumer started", extra={"queue": self.queue})
        while True:
            if self.poll_once() == 0:
                time.sleep(idle_sleep_s)

    def _handle(self, msg: Message) -> None:
        ctx = {"queue": self.queue, "msg_id": msg.msg_id, "attempt": msg.read_ct}
        if msg.read_ct > self.max_attempts:
            self._dead_letter(msg)
            log.error("dead-lettered", extra=ctx)
            return
        try:
            with psycopg.connect(self.conninfo) as conn, conn.transaction():
                done = conn.execute(
                    "select 1 from private.job_run"
                    " where queue = %s and msg_id = %s and status = 'done'",
                    (self.queue, msg.msg_id),
                ).fetchone()
                if not done:
                    conn.execute(
                        "select set_config('app.actor', %s, true)", (f"worker:{self.queue}",)
                    )
                    self.handler(msg.payload, conn)
                    conn.execute(
                        """insert into private.job_run
                             (queue, msg_id, status, attempts, finished_at)
                           values (%s, %s, 'done', %s, now())
                           on conflict (queue, msg_id) do update
                             set status = 'done', attempts = excluded.attempts, finished_at = now(),
                                 last_error = null""",
                        (self.queue, msg.msg_id, msg.read_ct),
                    )
                conn.execute("select pgmq.archive(%s, %s::bigint)", (self.queue, msg.msg_id))
            log.info("done", extra=ctx)
        except Exception as exc:
            self._record_failure(msg, exc)
            log.warning("failed, will retry", extra={**ctx, "error": str(exc)})

    def _record_failure(self, msg: Message, exc: Exception) -> None:
        delay = self.backoff_base_s * 2 ** (msg.read_ct - 1)
        with psycopg.connect(self.conninfo, autocommit=True) as conn:
            conn.execute(
                """insert into private.job_run (queue, msg_id, status, attempts, last_error)
                   values (%s, %s, 'failed', %s, %s)
                   on conflict (queue, msg_id) do update
                     set status = 'failed', attempts = excluded.attempts,
                         last_error = excluded.last_error""",
                (self.queue, msg.msg_id, msg.read_ct, f"{type(exc).__name__}: {exc}"[:2000]),
            )
            conn.execute("select pgmq.set_vt(%s, %s::bigint, %s)", (self.queue, msg.msg_id, delay))

    def _dead_letter(self, msg: Message) -> None:
        with psycopg.connect(self.conninfo) as conn, conn.transaction():
            conn.execute("select set_config('app.actor', %s, true)", (f"worker:{self.queue}",))
            body = {**msg.payload, "_dead_letter": {"queue": self.queue, "msg_id": msg.msg_id}}
            conn.execute("select pgmq.send(%s, %s)", (self.dlq, Jsonb(body)))
            conn.execute(
                """insert into private.job_run (queue, msg_id, status, attempts)
                   values (%s, %s, 'dead', %s)
                   on conflict (queue, msg_id) do update
                     set status = 'dead', attempts = excluded.attempts""",
                (self.queue, msg.msg_id, msg.read_ct),
            )
            if self.on_dead is not None:
                row = conn.execute(
                    "select last_error from private.job_run where queue = %s and msg_id = %s",
                    (self.queue, msg.msg_id),
                ).fetchone()
                self.on_dead(msg.payload, (row[0] if row else None) or "unknown error", conn)
            conn.execute("select pgmq.archive(%s, %s::bigint)", (self.queue, msg.msg_id))


def run_all(consumers: list[QueueConsumer], idle_sleep_s: float = 1.0) -> None:  # pragma: no cover
    """One process, several queues: poll each in turn, sleep when all are empty."""
    for consumer in consumers:
        log.info("consumer started", extra={"queue": consumer.queue})
    while True:
        if sum(consumer.poll_once() for consumer in consumers) == 0:
            time.sleep(idle_sleep_s)


def json_log_formatter() -> logging.Formatter:
    """Structured logs: one JSON object per line with the extra fields."""

    class _Json(logging.Formatter):
        def format(self, record: logging.LogRecord) -> str:
            base = {"level": record.levelname, "logger": record.name, "msg": record.getMessage()}
            extras = {
                k: v
                for k, v in record.__dict__.items()
                if k in ("queue", "msg_id", "attempt", "error", "batch_id")
            }
            return json.dumps({**base, **extras}, default=str)

    return _Json()
