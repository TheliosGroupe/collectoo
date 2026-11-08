"""Which job errors are recorded at once and which are left to the queue's retries (M2a-3)."""

import psycopg
import pytest

from collectoo_worker.jobs.boarding import SEND_BACK, _deterministic


def _error(state: str) -> psycopg.Error:
    class _Err(psycopg.Error):
        sqlstate = state

    return _Err("x")


@pytest.mark.parametrize(
    "state",
    [
        "LG001",  # unbalanced entry
        "LG005",  # opening plan differs from the report
        "LG006",  # invalid request
        "23514",  # check violation
        "23505",  # unique violation (e.g. a duplicate claim item)
        "23502",  # not null violation
        "22007",  # invalid date
        "22003",  # numeric out of range
    ],
)
def test_data_constraint_and_ledger_errors_are_not_retried(state: str) -> None:
    assert _deterministic(_error(state))


@pytest.mark.parametrize(
    "state",
    [
        "40001",  # serialization failure
        "40P01",  # deadlock
        "57014",  # statement timeout / cancel
        "53100",  # disk full
        "08006",  # connection failure
        "55P03",  # lock not available
    ],
)
def test_transient_errors_are_retried_by_the_queue(state: str) -> None:
    assert not _deterministic(_error(state))


def test_an_error_without_sqlstate_is_retried() -> None:
    assert not _deterministic(psycopg.OperationalError("connection lost"))


def test_each_step_goes_back_one_state() -> None:
    assert SEND_BACK["commit"][:2] == ("committing", "staged")
    assert SEND_BACK["confirm"][:2] == ("confirming", "committed")
