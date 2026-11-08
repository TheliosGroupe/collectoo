"""Payments queue jobs (M2b, design §9).

- `import` (M2-07): read an uploaded bank statement (camt.053 or CSV), check it, stage its lines
  and call `private.ingest_statement`: new lines become `bank_transaction` rows (deduplicated per
  bank account), debtor credits become `payment` rows, and each booking day of the statement is
  booked by one `cash_in` entry (Dr 5120 / Cr 4710). One transaction: the queue's (exactly once).

A file that cannot be imported is refused (`rejected`, with a stable code the back-office words
in French): parse errors before anything is written, refusals of the SQL import (closed bank
account, unbalanced, duplicate reference…) by rolling back to a savepoint. An unexpected error of
a parser is a refusal too (`parse_failed`): parsing reads only the file, so a retry would fail the
same way. Technical failures (I/O, database) are retried by the queue, then dead-lettered
(`failed`).
"""

from __future__ import annotations

import hashlib
import logging
import re
import tempfile
import time
from datetime import date
from pathlib import Path
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.payments.camt053 import parse_camt053
from collectoo_worker.payments.csv_import import CsvProfile, parse_csv
from collectoo_worker.payments.statement import STAGE_COLUMNS, ParsedStatement, StatementRejected
from collectoo_worker.runtime.storage import Storage

Conn = psycopg.Connection[Any]
CODE_RE = re.compile(r"([a-z0-9_]{1,64}): ")
# Refusals of private.ingest_statement ("<code>: <detail>"); any other data error is import_refused.
SQL_REFUSALS = frozenset(
    {
        "statement_unknown",
        "bank_account_closed",
        "header_invalid",
        "currency_mismatch",
        "future_booking_date",
        "line_invalid",
        "duplicate_reference_in_file",
        "unbalanced",
        "reference_conflict",
    }
)
log = logging.getLogger("collectoo.payments")


def make_handler(storage: Storage) -> Any:
    def handle(payload: dict[str, Any], conn: Conn) -> None:
        kind = payload.get("type")
        if kind == "import":
            import_statement(conn, storage, str(payload["statement_id"]))
        else:
            raise ValueError(f"unknown payments job type: {kind!r}")

    return handle


def record_dead_job(payload: dict[str, Any], error: str, conn: Conn) -> None:
    """The import failed for good: the statement says so (the back-office stops waiting)."""
    if payload.get("type") != "import" or not payload.get("statement_id"):
        return
    conn.execute(
        """update public.bank_statement
           set status = 'failed', error_code = 'import_failed', error = %s, finished_at = now()
           where id = %s and status = 'uploaded'""",
        (error[:2000], str(payload["statement_id"])),
    )


def deterministic(exc: psycopg.Error) -> bool:
    """Data, constraint and ledger errors fail the same way on every retry (see jobs.boarding)."""
    return (exc.sqlstate or "").startswith(("LG", "22", "23"))


def import_statement(conn: Conn, storage: Storage, statement_id: str) -> str:
    row = conn.execute(
        """select s.status, s.format, s.storage_bucket, s.storage_path, s.file_sha256, s.currency,
                  b.iban, b.csv_profile, c.minor_exponent, private.paris_today()
           from public.bank_statement s
           join public.bank_account b on b.id = s.bank_account_id
           join public.currency c on c.code = s.currency
           where s.id = %s for update of s""",
        (statement_id,),
    ).fetchone()
    if row is None or row[0] != "uploaded":
        return "skipped"  # unknown, or already done by an earlier delivery
    _status, fmt, bucket, path, sha256, currency, iban, csv_profile, exponent, today = row
    started = time.monotonic()
    with tempfile.TemporaryDirectory() as tmp:
        local = storage.download(bucket, path, Path(tmp) / "statement")
        downloaded = time.monotonic()
        try:
            if _sha256(local) != sha256:
                raise StatementRejected("file_changed", "the stored file is not the one declared")
            parsed = parse_file(
                local,
                fmt=fmt,
                iban=iban,
                currency=str(currency).strip(),
                exponent=int(exponent),
                csv_profile=csv_profile,
                today=today,
            )
        except StatementRejected as exc:
            reject(conn, statement_id, exc.code, exc.detail)
            return "rejected"
        except (OSError, MemoryError):
            raise  # the machine, not the file: retried by the queue
        except Exception as exc:
            # Parsing reads only the file: it would fail the same way on every retry.
            log.exception("statement %s: the parser failed", statement_id)
            reject(conn, statement_id, "parse_failed", f"{type(exc).__name__}: {exc}")
            return "rejected"
    parsed_at = time.monotonic()
    try:
        with conn.transaction():  # savepoint: a refused import leaves nothing behind
            stage(conn, statement_id, parsed)
            staged = time.monotonic()
            conn.execute(
                "select private.ingest_statement(%s, %s)", (statement_id, Jsonb(parsed.header()))
            )
    except psycopg.Error as exc:
        if not deterministic(exc):
            raise
        message = exc.diag.message_primary or str(exc)
        found = CODE_RE.match(message)
        code = found.group(1) if found and found.group(1) in SQL_REFUSALS else None
        reject(
            conn,
            statement_id,
            code or "import_refused",
            message if code else f"{exc.sqlstate}: {message}",
            parsed,
        )
        return "rejected"
    log.info(
        "statement %s imported: %d lines, download %.1fs, parse %.1fs, copy %.1fs, ingest %.1fs",
        statement_id,
        len(parsed.lines),
        downloaded - started,
        parsed_at - downloaded,
        staged - parsed_at,
        time.monotonic() - staged,
    )
    return "imported"


def parse_file(  # noqa: PLR0913 - the bank account's settings
    path: Path,
    *,
    fmt: str,
    iban: str,
    currency: str,
    exponent: int,
    csv_profile: dict[str, Any] | None,
    today: date,
) -> ParsedStatement:
    if fmt == "camt053":
        return parse_camt053(path, iban=iban, currency=currency, exponent=exponent, today=today)
    return parse_csv(
        path,
        currency=currency,
        exponent=exponent,
        profile=CsvProfile.from_json(csv_profile),
        today=today,
    )


def stage(conn: Conn, statement_id: str, parsed: ParsedStatement) -> None:
    """COPY the lines into private.bank_import_stage (ingest_statement reads them, same tx)."""
    columns = ", ".join(("statement_id", *STAGE_COLUMNS))
    with (
        conn.cursor() as cur,
        cur.copy(f"copy private.bank_import_stage ({columns}) from stdin") as copy,
    ):
        for line in parsed.lines:
            copy.write_row((statement_id, *(getattr(line, c) for c in STAGE_COLUMNS)))


def reject(
    conn: Conn, statement_id: str, code: str, detail: str, parsed: ParsedStatement | None = None
) -> None:
    """Refused: the statement keeps the reason (and what the file said, when it could be read)."""
    sections = parsed.header()["sections"] if parsed is not None and parsed.sections else None
    dates = [d for s in (parsed.sections if parsed else []) for d in (s.from_date, s.to_date)]
    dates += [line.booking_date for line in (parsed.lines if parsed and not dates else [])]
    conn.execute(
        """update public.bank_statement
           set status = 'rejected', error_code = %s, error = %s, finished_at = now(),
               sections = %s, from_date = %s, to_date = %s
           where id = %s and status = 'uploaded'""",
        (
            code,
            detail[:2000],
            Jsonb(sections) if sections is not None else None,
            min(dates) if dates else None,
            max(dates) if dates else None,
            statement_id,
        ),
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()
