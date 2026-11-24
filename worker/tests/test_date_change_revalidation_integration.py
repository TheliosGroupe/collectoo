"""M2c-7c-1, carried low 4 (needs `make up`; ADR-0014 « M2c-7c-1 »): a fixture that requests,
prepares and approves runs survives a change of the Paris date while its approval jobs run.

PR #43's dispatched scale-payouts run: « Valider » at 22:55 UTC (23:55 in Paris) asked for the next
business day by default; the approval jobs run after midnight in Paris found that day was today,
with no cut-off recorded, and refused 1,755 of 5,050 runs `execution_date_after_cutoff` (RR001,
back to draft). The product is right; the fixture now does what ops would the next morning:
remittance_helpers.revalidate_after_date_change validates again, with a fresh « Valider », the runs
a date change alone sent back (`execution_date_after_cutoff` or `execution_date_passed`, refused on
a Paris day after the command's, today no longer that day) — never a run refused for anything else.
The scale files call it after their own « Valider »; remittance_helpers.drain() calls it for the
runs the integration tests' approve() queued with their default execution date.

Here the date change is simulated: the run's requested execution date moved to a day the job
refuses (yesterday: `execution_date_passed` whatever the calendar; today, when it is a business
day: `execution_date_after_cutoff`), and the command's day given as yesterday."""

from __future__ import annotations

from datetime import timedelta

import psycopg
import pytest
import remittance_helpers
from explain_helpers import ADMIN
from integration_helpers import one
from remittance_helpers import (
    approve,
    date_change_refusals,
    drain,
    paid_file,
    paris_today,
    remittance_tenant,
    request_run,
    revalidate_after_date_change,
    run_row,
)

pytestmark = pytest.mark.integration


def _move_execution_date(run: str, day: str) -> None:
    """(test only) the approved-but-queued run's requested execution date set to `day` (an SQL
    expression), as « Valider » before midnight left it once the date has changed."""
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        conn.execute("alter table public.remittance_run disable trigger remittance_run_guard")
        conn.execute(
            f"update public.remittance_run set requested_execution_date = {day} where id = %s",  # noqa: S608
            (run,),
        )
        conn.execute("alter table public.remittance_run enable always trigger remittance_run_guard")


def _queued_run() -> tuple[dict[str, object], str]:
    tenant = remittance_tenant()
    paid_file(tenant, 100_000)
    run = request_run(tenant)  # prepared (the prepare job drained)
    out = approve(tenant, run)
    assert [r["status"] for r in out["results"]] == ["queued"], out
    return tenant, run


@pytest.mark.parametrize("day", ["private.paris_today() - 1", "private.paris_today()"])
def test_a_run_refused_for_the_date_alone_is_validated_again_the_next_morning(day: str) -> None:
    with psycopg.connect(ADMIN) as conn:
        business = one(conn, "select private.is_business_day(private.paris_today())")
    if day.endswith("()") and not business:
        pytest.skip("today is not a business day: the job refuses execution_date_not_business_day")
    tenant, run = _queued_run()
    today = paris_today()
    _move_execution_date(run, day)
    drain()  # the approval job
    refused = run_row(run)
    expected = "execution_date_passed" if day.endswith("- 1") else "execution_date_after_cutoff"
    assert (refused["status"], refused["job"]) == ("draft", None), refused
    assert refused["last_failure"]["code"] == expected, refused["last_failure"]
    # the same day: no date change — left to the fixture's own assertion, never re-validated
    assert date_change_refusals([run], today) == []
    assert revalidate_after_date_change(tenant, [run], today) == []
    assert run_row(run)["status"] == "draft"
    # « Valider » was issued the day before: validated again, its default execution date now
    assert revalidate_after_date_change(tenant, [run], today - timedelta(days=1)) == [run]
    drain()
    done = run_row(run)
    assert done["status"] == "approved", done["last_failure"]
    assert done["requested_execution_date"] > today


def test_drain_validates_again_what_approve_queued_before_a_date_change() -> None:
    """drain() does it for the integration tests' approve(): a run « Valider » queued the day before
    (its day recorded as yesterday, as a command issued before midnight) and refused for the date
    alone is validated again and approved within the same drain()."""
    tenant, run = _queued_run()
    today = paris_today()
    # approve() recorded the run and the day « Valider » was issued; that day made yesterday
    assert remittance_helpers._VALIDATED[run] == (tenant, today)
    _move_execution_date(run, "private.paris_today() - 1")
    remittance_helpers._VALIDATED[run] = (tenant, today - timedelta(days=1))
    drain()
    done = run_row(run)
    assert done["status"] == "approved", done["last_failure"]
    assert done["requested_execution_date"] > today


def test_a_run_refused_for_anything_else_is_never_validated_again() -> None:
    tenant, run = _queued_run()
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        conn.execute(
            """update public.client_payout_account set status = 'retired', closed_by = %s,
                 closed_at = now(), closed_reason = 'test' where id = %s""",
            (tenant["staff"], tenant["payout"]),
        )
    drain()
    refused = run_row(run)
    assert refused["status"] == "draft"
    assert refused["last_failure"]["code"] == "payout_blocked:payout_account_missing"
    yesterday = paris_today() - timedelta(days=1)
    remittance_helpers._VALIDATED[run] = (tenant, yesterday)
    drain()  # the refusal kept: never validated again
    assert run_row(run)["last_failure"]["code"] == "payout_blocked:payout_account_missing"
    assert date_change_refusals([run], yesterday) == []
    assert revalidate_after_date_change(tenant, [run], yesterday) == []
    assert run_row(run)["status"] == "draft"
