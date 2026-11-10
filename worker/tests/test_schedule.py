"""When a run is due (design §9.3; founder #1): the 1st and the 16th, or a weekday, moved to the
next business day; the deadline guard 5 business days before the earliest latest execution date."""

from datetime import date, timedelta

from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.remittance.calendar import conservative
from collectoo_worker.remittance.deadline import remittance_deadline
from collectoo_worker.remittance.schedule import guard_due, is_scheduled, scheduled_days
from collectoo_worker.remittance.terms import RemittanceTerms

D = date.fromisoformat
BASE = {"schema": "remittance-1", "netting": None, "clawback": None, "invoice_payment_days": 30}
TWICE = RemittanceTerms.model_validate({**BASE, "frequency": "twice_monthly"})


def weekly(day: int) -> RemittanceTerms:
    return RemittanceTerms.model_validate({**BASE, "frequency": "weekly", "weekday": day})


def test_twice_a_month() -> None:
    # §7.2: the 1st of November 2026 is a Sunday, the run is on Monday 02/11
    assert scheduled_days(TWICE, D("2026-11-20")) == [D("2026-11-02"), D("2026-11-16")]
    # 01/01/2027 a holiday, 16/01/2027 a Saturday
    assert scheduled_days(TWICE, D("2027-01-05")) == [D("2027-01-04"), D("2027-01-18")]
    assert is_scheduled(TWICE, D("2026-11-02"))
    assert not is_scheduled(TWICE, D("2026-11-01"))
    assert not is_scheduled(TWICE, D("2026-11-03"))


def test_weekly() -> None:
    assert scheduled_days(weekly(2), D("2026-11-01")) == [
        D("2026-11-03"),
        D("2026-11-10"),
        D("2026-11-17"),
        D("2026-11-24"),
    ]
    # Wednesday 11/11 is a holiday: Thursday 12/11
    assert scheduled_days(weekly(3), D("2026-11-01")) == [
        D("2026-11-04"),
        D("2026-11-12"),
        D("2026-11-18"),
        D("2026-11-25"),
    ]
    # Good Friday 30/03/2029, the weekend, Easter Monday: Tuesday 03/04, a day of March's runs
    assert scheduled_days(weekly(5), D("2029-03-01"))[-1] == D("2029-04-03")
    assert is_scheduled(weekly(5), D("2029-04-03"))
    assert not is_scheduled(weekly(5), D("2029-04-04"))


@given(month=st.dates(min_value=D("2026-01-01"), max_value=D("2031-11-30")))
def test_twice_a_month_property(month: date) -> None:
    cal = conservative()
    days = scheduled_days(TWICE, month)
    assert len(days) == 2
    for nominal, run in zip((month.replace(day=1), month.replace(day=16)), days, strict=True):
        assert run >= nominal and cal.is_business_day(run) and run.month == month.month
        assert all(
            not cal.is_business_day(nominal + timedelta(days=k))
            for k in range((run - nominal).days)
        )


def test_the_deadline_guard() -> None:
    latest = remittance_deadline(D("2026-10-12"), 30).latest_execution  # Mon 09/11
    assert not guard_due(D("2026-10-30"), [latest])
    assert guard_due(D("2026-11-02"), [latest])  # 5 business days before (01/11 a Sunday)
    assert guard_due(D("2026-11-02"), [D("2026-12-09"), latest])  # the earliest counts
    assert not guard_due(D("2026-11-02"), [])


@given(e=st.dates(min_value=D("2026-01-20"), max_value=D("2031-11-20")), days=st.integers(1, 30))
def test_the_guard_leaves_five_business_days(e: date, days: int) -> None:
    cal = conservative()
    d = remittance_deadline(e, days)
    assert guard_due(d.alert_soon, [d.latest_execution])
    before = cal.before(d.alert_soon)
    assert not guard_due(before, [d.latest_execution])
    assert cal.after(d.alert_soon, 5) == d.latest_execution
