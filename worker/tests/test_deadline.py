"""The R124-6 remittance deadline and the conservative business calendar (design §8.5, §9.2; founder
#2; rule pack `remittance/fr`): the design's examples, Easter and the French public holidays, the
horizon, and Hypothesis properties over the seeded horizon. The SQL twin's parity on 10,000 dates is
in test_engines_integration.py."""

from datetime import UTC, date, datetime, timedelta

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from collectoo_worker.payments.receipts import paris_date
from collectoo_worker.remittance.calendar import (
    CalendarHorizonError,
    add_months,
    build,
    closing_days,
    conservative,
    easter_sunday,
    horizon_alert,
    seed_values_sql,
)
from collectoo_worker.remittance.deadline import (
    add_month_cpc641,
    encaissement_date,
    remittance_deadline,
)
from collectoo_worker.remittance.packs import CalendarSpec, remittance_pack

D = date.fromisoformat


def test_the_design_examples() -> None:
    # §9.2: E 12/10/2026 → Wed 11/11 (a public holiday) → Tue 10/11 → latest execution Mon 09/11
    d = remittance_deadline(D("2026-10-12"), 30)
    assert (d.deadline, d.last_business_day, d.latest_execution) == (
        D("2026-11-11"),
        D("2026-11-10"),
        D("2026-11-09"),
    )
    assert (d.alert_soon, d.alert_critical) == (D("2026-11-02"), D("2026-11-06"))  # 01/11 a Sunday
    # §9.2: E Sun 31/01/2027 → least(02/03, 28/02) = 28/02 → Fri 26/02 → Thu 25/02
    d = remittance_deadline(D("2027-01-31"), 30)
    assert (d.deadline, d.last_business_day, d.latest_execution) == (
        D("2027-02-28"),
        D("2027-02-26"),
        D("2027-02-25"),
    )
    # §7.2: P6 E 10/11 → 10/12/2026, latest execution Wed 09/12
    d = remittance_deadline(D("2026-11-10"), 30)
    assert (d.deadline, d.latest_execution) == (D("2026-12-10"), D("2026-12-09"))
    # a shorter delay in the mandate wins
    d = remittance_deadline(D("2026-10-12"), 10)
    assert (d.deadline, d.last_business_day, d.latest_execution) == (
        D("2026-10-22"),
        D("2026-10-22"),
        D("2026-10-21"),
    )
    # Easter 2027: E 26/02 → least(28/03, 26/03) = Fri 26/03, Good Friday (TARGET) → Thu 25/03
    # → Wed 24/03
    d = remittance_deadline(D("2027-02-26"), 30)
    assert (d.deadline, d.last_business_day, d.latest_execution) == (
        D("2027-03-26"),
        D("2027-03-25"),
        D("2027-03-24"),
    )
    # Christmas 2026: deadline Sat 26/12 → Thu 24/12 → Wed 23/12
    d = remittance_deadline(D("2026-11-26"), 30)
    assert (d.deadline, d.last_business_day, d.latest_execution) == (
        D("2026-12-26"),
        D("2026-12-24"),
        D("2026-12-23"),
    )
    assert not d.unmeetable


def test_a_short_delay_can_be_unmeetable() -> None:
    """A mandate's delay of 1 to 5 days can leave no business day after the money arrives: both
    twins flag it (M2c-4: « délai intenable », not an operational breach; OQ-71)."""
    # Fri 13/11/2026 under 2 days: deadline Sun 15/11 → Fri 13/11 → latest execution Thu 12/11
    d = remittance_deadline(D("2026-11-13"), 2)
    assert (d.deadline, d.last_business_day, d.latest_execution, d.unmeetable) == (
        D("2026-11-15"),
        D("2026-11-13"),
        D("2026-11-12"),
        True,
    )
    assert remittance_deadline(D("2026-12-24"), 1).latest_execution == D("2026-12-23")
    assert remittance_deadline(D("2026-12-24"), 1).unmeetable
    assert not remittance_deadline(D("2026-11-16"), 2).unmeetable  # Mon → Wed 18/11, exec Tue 17/11
    # from 6 days on it never happens on the seeded calendar
    cal = conservative()
    for k in range((D("2031-11-30") - D("2026-02-01")).days + 1):
        e = D("2026-02-01") + timedelta(days=k)
        assert not remittance_deadline(e, 6, cal).unmeetable, e


def test_encaissement_and_one_month() -> None:
    assert encaissement_date(D("2026-10-12"), D("2026-10-09")) == D("2026-10-09")
    assert encaissement_date(D("2026-10-12"), D("2026-10-13")) == D("2026-10-12")
    assert encaissement_date(D("2026-10-12"), None) == D("2026-10-12")
    assert add_month_cpc641(D("2027-01-31")) == D("2027-02-28")
    assert add_month_cpc641(D("2028-01-31")) == D("2028-02-29")
    assert add_month_cpc641(D("2026-03-31")) == D("2026-04-30")
    assert add_month_cpc641(D("2026-03-30")) == D("2026-04-30")
    assert add_month_cpc641(D("2026-12-31")) == D("2027-01-31")
    assert add_months(D("2026-11-10"), 12) == D("2027-11-10")
    assert add_months(D("2028-02-29"), 12) == D("2029-02-28")


def test_easter_and_the_closing_days() -> None:
    assert [easter_sunday(y) for y in range(2026, 2032)] == [
        D("2026-04-05"),
        D("2027-03-28"),
        D("2028-04-16"),
        D("2029-04-01"),
        D("2030-04-21"),
        D("2031-04-13"),
    ]
    assert easter_sunday(2000) == D("2000-04-23")
    assert easter_sunday(2019) == D("2019-04-21")
    spec = remittance_pack().calendar
    days = closing_days(spec, 2026)
    assert sorted(days) == [
        D("2026-01-01"),
        D("2026-04-03"),  # Vendredi saint (TARGET)
        D("2026-04-06"),
        D("2026-05-01"),
        D("2026-05-08"),
        D("2026-05-14"),  # Ascension
        D("2026-05-25"),  # Lundi de Pentecôte
        D("2026-07-14"),
        D("2026-08-15"),
        D("2026-11-01"),
        D("2026-11-11"),
        D("2026-12-25"),
        D("2026-12-26"),  # TARGET
    ]
    assert days[D("2026-04-03")].sources == ("target",)
    assert days[D("2026-04-06")].sources == ("public_holiday", "target")
    cal = conservative()
    assert not cal.is_business_day(D("2026-11-01"))  # Toussaint, a Sunday
    assert cal.closed[D("2026-11-01")].labels == ("Toussaint", "dimanche")
    assert cal.is_business_day(D("2026-11-02"))
    assert cal.on_or_after(D("2026-11-01")) == D("2026-11-02")  # the 1st is a Sunday: run on Monday
    assert cal.after(D("2026-12-24")) == D("2026-12-28")
    assert cal.before(D("2026-12-28"), 2) == D("2026-12-23")


def test_the_horizon() -> None:
    cal = conservative()
    assert (cal.first, cal.last) == (D("2026-01-01"), D("2031-12-31"))
    assert len(cal.days()) == 365 * 5 + 366
    with pytest.raises(CalendarHorizonError, match="horizon"):
        cal.is_business_day(D("2032-01-01"))
    with pytest.raises(CalendarHorizonError):
        remittance_deadline(D("2031-12-15"), 30)  # deadline 2032-01-14
    with pytest.raises(CalendarHorizonError):
        remittance_deadline(D("2025-12-31"), 1)  # walks back before 2026-01-01
    assert not horizon_alert(D("2030-12-31"))
    assert horizon_alert(D("2031-01-01"))


def test_calendar_horizon_tripwire() -> None:
    """Fails CI when less than 12 months are seeded: extend the horizon and seed the table."""
    assert not horizon_alert(paris_date(datetime.now(UTC))), (
        "business calendar: extend seeded_to in worker/rule_packs/remittance/fr.yaml and seed"
        " the new years into public.business_calendar by a migration (seed_values_sql)"
    )


def test_seed_rows_are_the_holidays() -> None:
    rows = seed_values_sql().split(",\n")
    first = "  ('2026-01-01', 'Jour de l''an', array['public_holiday', 'target']::text[])"
    assert rows[0] == first
    assert len(rows) == sum(
        1 for _, c in conservative().days() if c is not None and set(c.sources) - {"weekend"}
    )


def test_refusals() -> None:
    with pytest.raises(ValueError, match=r"1\.\.30"):
        remittance_deadline(D("2026-10-12"), 31)
    with pytest.raises(ValueError, match=r"1\.\.30"):
        remittance_deadline(D("2026-10-12"), 0)
    with pytest.raises(ValueError):
        conservative().before(D("2026-10-12"), 0)
    spec = remittance_pack().calendar
    with pytest.raises(ValueError, match="whole years"):
        CalendarSpec.model_validate({**spec.model_dump(), "seeded_to": "2026-06-30"})
    # the calendar a spec builds is that spec's: another horizon, other bounds
    other = build(spec.model_copy(update={"seeded_from": D("2027-01-01")}))
    with pytest.raises(CalendarHorizonError):
        other.is_business_day(D("2026-12-31"))


# -- properties over the horizon -------------------------------------------------------------------

dates = st.dates(min_value=D("2026-01-20"), max_value=D("2031-11-20"))


@settings(max_examples=2_000)
@given(e=dates, days=st.integers(1, 30))
def test_deadline_properties(e: date, days: int) -> None:
    cal = conservative()
    d = remittance_deadline(e, days)
    assert d.deadline == min(e + timedelta(days=days), add_month_cpc641(e))
    assert 1 <= (d.deadline - e).days <= days
    if days == 30:
        assert 28 <= (d.deadline - e).days <= 30
    # never later than the deadline: no weekend or holiday extension
    assert d.last_business_day <= d.deadline and cal.is_business_day(d.last_business_day)
    assert all(
        not cal.is_business_day(d.last_business_day + timedelta(days=k))
        for k in range(1, (d.deadline - d.last_business_day).days + 1)
    )
    # credited by D+1 (L133-13 I): the next business day after the latest execution is last_bd
    assert d.latest_execution < d.last_business_day
    assert cal.after(d.latest_execution) == d.last_business_day
    assert d.alert_soon < d.alert_critical < d.latest_execution
    assert cal.after(d.alert_critical) == d.latest_execution
    assert cal.after(d.alert_soon, 5) == d.latest_execution
    # unmeetable: no business day after E is left to execute on
    assert d.unmeetable == (d.latest_execution < cal.after(e)) == (d.latest_execution <= e)
    if days >= 6:
        assert not d.unmeetable


@given(e=st.dates(min_value=D("2000-01-01"), max_value=D("2099-12-31")))
def test_one_month_is_cpc_641(e: date) -> None:
    m = add_month_cpc641(e)
    assert (m.year * 12 + m.month) - (e.year * 12 + e.month) == 1
    nxt = date(m.year + (m.month == 12), m.month % 12 + 1, 1)
    last = (nxt - timedelta(days=1)).day
    assert m.day == min(e.day, last)
