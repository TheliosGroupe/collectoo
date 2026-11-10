"""When a run is due (design §9.3; founder #1): the 1st and the 16th, or a weekday, moved to the
next business day; the deadline guard 5 business days before the earliest latest execution date."""

from dataclasses import dataclass
from datetime import date, timedelta

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from collectoo_worker.remittance.calendar import conservative
from collectoo_worker.remittance.deadline import RemittanceDeadline, remittance_deadline
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


# -- the scheduler's promise (COMPLIANCE CPCE-08; review M2c-4 legal#8, round 2) -------------------


@dataclass(frozen=True)
class _Collection:
    e: date  # its encaissement date
    posted: date  # the day its allocation reaches the pending queue
    own: RemittanceDeadline  # under the mandate's delay
    month: RemittanceDeadline  # one month (R124-6): what an unmeetable delay is held to


def _simulate(
    terms: RemittanceTerms,
    collections: list[_Collection],
    start: date,
    end: date,
    *,
    one_live_run: bool = False,
) -> dict[int, date]:
    """The hourly schedule of one client, a day at a time from `start` to `end`: the day's
    collections reach the queue first; then a run is cut on a scheduled business day of the
    mandate, or on any day the deadline guard is due over the waiting items' latest execution dates
    (the job runs every hour, every day). The run takes every waiting item and pays them out on the
    next business day (approved the day it is drafted, the default execution date). With
    `one_live_run`, as `private.create_remittance_run` holds today, no run is cut while the previous
    one is in flight — until its debit is booked, here on its execution day. Returns each
    collection's execution date."""
    cal = conservative()
    executed: dict[int, date] = {}
    waiting: list[int] = []
    in_flight: date | None = None  # the execution date of the run not yet debited
    day = start
    while day <= end and len(executed) < len(collections):
        waiting += [i for i, c in enumerate(collections) if c.posted == day]
        if in_flight is not None and day >= in_flight:
            in_flight = None  # its debit booked
        if waiting and (in_flight is None or not one_live_run):
            scheduled = cal.is_business_day(day) and is_scheduled(terms, day, cal)
            latest = [collections[i].own.latest_execution for i in waiting]
            if scheduled or guard_due(day, latest, cal):
                in_flight = cal.after(day)
                executed.update(dict.fromkeys(waiting, in_flight))
                waiting = []
        day += timedelta(days=1)
    return executed


def _collections(start: date, days: int, events: list[tuple[int, int]]) -> list[_Collection]:
    return [
        _Collection(
            e, e + timedelta(days=lag), remittance_deadline(e, days), remittance_deadline(e, 30)
        )
        for offset, lag in events
        for e in [start + timedelta(days=offset)]
    ]


SCHEDULE_CASES = {
    "start": st.dates(min_value=D("2026-02-01"), max_value=D("2031-08-31")),  # (seeded calendar)
    "terms": st.one_of(st.just(TWICE), st.integers(1, 5).map(weekly)),
    "days": st.one_of(st.integers(1, 5), st.integers(6, 30)),  # 1 to 5: unmeetable at times (OQ-71)
    "events": st.lists(st.tuples(st.integers(0, 45), st.integers(0, 4)), min_size=1, max_size=30),
}


@settings(max_examples=400, deadline=None)
@given(**SCHEDULE_CASES)
def test_no_collection_waits_past_its_latest_execution_date(
    start: date, terms: RemittanceTerms, days: int, events: list[tuple[int, int]]
) -> None:
    """CPCE-08: with the mandate's run days and the deadline guard, every collection is paid out on
    or before its latest execution date — whatever the calendar (weekends, holidays, TARGET days),
    the frequency and the delay — when it reached the queue on its encaissement date or by its J-5
    alert date (one allocated later is the guard's to draft at once, not this promise's). A delay
    no payout can meet (latest execution on or before E: some 1- to 5-day delays, OQ-71) is paid out
    by the one-month latest execution date, the date the checks then hold it to. Each collection is
    paid out, after it reached the queue. (No miss in 290,000 collections checked offline.)"""
    collections = _collections(start, days, events)
    executed = _simulate(terms, collections, start, start + timedelta(days=45 + 4 + 40))
    assert len(executed) == len(collections)
    for i, c in enumerate(collections):
        assert executed[i] > c.posted
        if c.own.unmeetable:
            assert executed[i] <= c.month.latest_execution, (c, executed[i])
        elif c.posted == c.e or c.posted <= c.own.alert_soon:
            assert executed[i] <= c.own.latest_execution, (c, executed[i])


@settings(max_examples=400, deadline=None)
@given(**SCHEDULE_CASES)
def test_one_live_run_per_client_still_pays_on_time_from_six_days_or_a_business_day(
    start: date, terms: RemittanceTerms, days: int, events: list[tuple[int, int]]
) -> None:
    """The same promise with one live run per client (the run in flight debited on its execution
    day), where it holds: a delay of 6 days or more, or an encaissement on a business day; and an
    unmeetable delay within the month. Outside it, see the gap below (OQ-73). (No miss in 670,000
    collections checked offline.)"""
    cal = conservative()
    collections = _collections(start, days, events)
    executed = _simulate(
        terms, collections, start, start + timedelta(days=45 + 4 + 40), one_live_run=True
    )
    assert len(executed) == len(collections)
    for i, c in enumerate(collections):
        if c.own.unmeetable:
            assert executed[i] <= c.month.latest_execution, (c, executed[i])
        elif (c.posted == c.e or c.posted <= c.own.alert_soon) and (
            days >= 6 or cal.is_business_day(c.e)
        ):
            assert executed[i] <= c.own.latest_execution, (c, executed[i])


@pytest.mark.xfail(
    strict=True,
    reason="OQ-73: one live run per client holds back a collection that arrives while a payout is"
    " in flight; a 2- to 5-day delay can then miss its date (M2c-6 decides)",
)
def test_a_short_delay_collected_while_a_payout_is_in_flight() -> None:
    """The gap the property found (round 2): a 2-day mandate; a collection of Mon 22/06/2026
    allocated late, on Fri 26/06, is drafted at once and paid out on Mon 29/06; another, collected
    and allocated on Sun 28/06 (an instant payment), has its latest execution date on Mon 29/06,
    but no run can be cut while the first is in flight: it is drafted on Mon 29/06 and paid out on
    Tue 30/06, a business day late. The guard is due on time; the rule « one live run per client »
    (`private.create_remittance_run`) holds it back. With the debit booked the next business day,
    2- to 5-day delays miss on business days too (2,558 of 143,071 collections offline)."""
    late = _Collection(
        D("2026-06-22"), D("2026-06-26"), remittance_deadline(D("2026-06-22"), 2),
        remittance_deadline(D("2026-06-22"), 30),
    )  # fmt: skip
    sunday = _Collection(
        D("2026-06-28"), D("2026-06-28"), remittance_deadline(D("2026-06-28"), 2),
        remittance_deadline(D("2026-06-28"), 30),
    )  # fmt: skip
    executed = _simulate(TWICE, [late, sunday], D("2026-06-22"), D("2026-07-31"), one_live_run=True)
    assert executed[0] == D("2026-06-29") and sunday.own.latest_execution == D("2026-06-29")
    assert executed[1] <= sunday.own.latest_execution  # fails: Tue 30/06


def test_the_simulation_pays_a_short_delay_within_the_month() -> None:
    """(the model on one example) A 1-day delay: E Mon 05/10/2026 leaves no business day (latest
    execution on E); the guard is due at once, the run cut that day pays out on Tue 06/10, within
    the month (its latest execution date Tue 03/11)."""
    e = D("2026-10-05")
    c = _Collection(e, e, remittance_deadline(e, 1), remittance_deadline(e, 30))
    assert c.own.unmeetable and c.month.latest_execution == D("2026-11-03")
    assert _simulate(TWICE, [c], e, e + timedelta(days=40), one_live_run=True) == {
        0: D("2026-10-06")
    }
