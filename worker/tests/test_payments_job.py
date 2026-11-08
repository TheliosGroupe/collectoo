"""Payments queue jobs without a database: unknown jobs fail loudly; which errors are retried; a
file the parser cannot read is refused once, never retried."""

import hashlib
from datetime import date
from pathlib import Path
from typing import Any, cast

import psycopg
import pytest

from collectoo_worker.jobs import payments as payments_job
from collectoo_worker.jobs.payments import (
    SQL_REFUSALS,
    deterministic,
    import_statement,
    make_handler,
)


class _NoStorage:
    def download(self, *_args: Any) -> Any:  # pragma: no cover - never reached
        raise AssertionError

    def upload(self, *_args: Any) -> None:  # pragma: no cover - never reached
        raise AssertionError

    def remove(self, *_args: Any) -> None:  # pragma: no cover - never reached
        raise AssertionError


def _error(sqlstate: str) -> psycopg.Error:
    """An error with this SQLSTATE (psycopg reads it from the class)."""
    cls = type(f"E{sqlstate}", (psycopg.Error,), {"sqlstate": sqlstate})
    error: psycopg.Error = cls("x")
    return error


def test_an_unknown_job_type_is_an_error() -> None:
    handle = make_handler(_NoStorage())
    with pytest.raises(ValueError, match="unknown payments job type"):
        handle({"type": "match"}, None)


@pytest.mark.parametrize(
    ("state", "retried"),
    [("22023", False), ("23514", False), ("LG001", False), ("40001", True), ("57014", True)],
)
def test_data_and_ledger_errors_are_not_retried(state: str, retried: bool) -> None:
    assert deterministic(_error(state)) is not retried


def test_the_sql_refusal_codes_are_worded_on_the_page() -> None:
    page = (
        Path(__file__).resolve().parents[2] / "apps/web/src/lib/payments/statements.ts"
    ).read_text("utf-8")
    worded = {c for c in SQL_REFUSALS if f"  {c}:" in page}
    # header_invalid and statement_unknown are internal faults: « contactez le support »
    assert SQL_REFUSALS - worded == {"header_invalid", "statement_unknown"}


class _Result:
    def __init__(self, row: Any) -> None:
        self.row = row

    def fetchone(self) -> Any:
        return self.row


class _Conn:
    """What import_statement asks of the database before it parses: the statement row, and the
    update that refuses it."""

    def __init__(self, row: tuple[Any, ...]) -> None:
        self.row = row
        self.updates: list[tuple[Any, ...]] = []

    def execute(self, sql: str, params: tuple[Any, ...] = ()) -> _Result:
        if sql.lstrip().startswith("select"):
            return _Result(self.row)
        self.updates.append(params)
        return _Result(None)


class _LocalStorage:
    def __init__(self, data: bytes) -> None:
        self.data = data

    def download(self, _bucket: str, _path: str, dest: Path) -> Path:
        dest.write_bytes(self.data)
        return dest


def _import(data: bytes) -> tuple[str, list[tuple[Any, ...]]]:
    row = (
        "uploaded",
        "csv",
        "bank-statements",
        "s/1.csv",
        hashlib.sha256(data).hexdigest(),
        "EUR",
        "FR7630004000031234567890143",
        None,
        2,
        date(2026, 11, 8),
    )
    conn = _Conn(row)
    outcome = import_statement(cast(Any, conn), cast(Any, _LocalStorage(data)), "s-1")
    return outcome, conn.updates


def test_an_unreadable_csv_is_refused_with_its_code_not_retried() -> None:
    outcome, updates = _import(b"Date;Libelle;Montant\r\n01/10/2026;A\x81;1,00\r\n")
    assert outcome == "rejected"
    ((code, detail, *_rest),) = updates
    assert (code, detail.split(":")[0]) == ("csv_encoding", "line 2")


def test_an_unexpected_parser_error_is_a_refusal_not_a_retry(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Parsing reads only the file: what fails once fails on every retry."""

    def broken(*_args: Any, **_kwargs: Any) -> Any:
        raise TypeError("boom")

    monkeypatch.setattr(payments_job, "parse_csv", broken)
    outcome, updates = _import(b"Date;Libelle;Montant\r\n01/10/2026;A;1,00\r\n")
    assert outcome == "rejected"
    ((code, detail, *_rest),) = updates
    assert (code, detail) == ("parse_failed", "TypeError: boom")


def test_an_io_error_while_parsing_is_retried(monkeypatch: pytest.MonkeyPatch) -> None:
    def unreadable(*_args: Any, **_kwargs: Any) -> Any:
        raise OSError("disk")

    monkeypatch.setattr(payments_job, "parse_csv", unreadable)
    with pytest.raises(OSError, match="disk"):
        _import(b"Date;Libelle;Montant\r\n01/10/2026;A;1,00\r\n")
