"""Payments queue jobs without a database: unknown jobs fail loudly; which errors are retried."""

from pathlib import Path
from typing import Any

import psycopg
import pytest

from collectoo_worker.jobs.payments import SQL_REFUSALS, deterministic, make_handler


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
