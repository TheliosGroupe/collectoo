"""The R124-6 remittance deadline of one encaissement (design §9.2; founder #2; rule pack
`remittance/fr`).

    E              = least(booking date, coalesce(value date, booking date))
    deadline       = least(E + mandate days, E + one month)   CPC 641: same day, else the last
    last_bd        = last business day ≤ deadline              no weekend or holiday extension
    latest_exec    = business day before last_bd               CMF L133-13 I: credited by D+1
    alert_soon     = latest_exec - 5 business days
    alert_critical = latest_exec - 1 business day
    unmeetable     = latest_exec ≤ E                           the money cannot be paid out in time

A mandate's delay of 1 to 5 days can leave no business day after the encaissement on which to
execute (E 13/11/2026 under 2 days: the deadline is Sun 15/11, the latest execution Thu 12/11). Both
twins flag it (`unmeetable`, review fix): M2c-4 records such a line as « délai intenable », not as
an operational breach. From 6 days on it never happens on the seeded calendar (2026 to 2031, a
property test); whether the terms should refuse such a delay is the founder's call (OQ-71).

Pure. The SQL twin `private.remittance_deadline(E, days)` gives the same dates (CI parity on 10,000
dates). Both refuse a date whose computation leaves the calendar's seeded horizon.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta

from collectoo_worker.remittance.calendar import Calendar, add_months, conservative
from collectoo_worker.remittance.packs import remittance_pack

MAX_DAYS = 30  # mandate_terms.remittance_max_days is 1..30


@dataclass(frozen=True)
class RemittanceDeadline:
    encaissement: date
    deadline: date
    last_business_day: date
    latest_execution: date
    alert_soon: date
    alert_critical: date
    unmeetable: bool  # latest execution on or before E: no business day left to pay out


def encaissement_date(booking_date: date, value_date: date | None) -> date:
    """E: the earlier of the booking and value dates (founder #2, OQ-36)."""
    return min(booking_date, value_date or booking_date)


def add_month_cpc641(day: date) -> date:
    """One month after `day`: the same day of the next month, else its last day (CPC 641 al. 2, by
    analogy)."""
    return add_months(day, remittance_pack().deadline.months)


def remittance_deadline(
    encaissement: date, max_days: int, cal: Calendar | None = None
) -> RemittanceDeadline:
    if not 1 <= max_days <= MAX_DAYS:
        raise ValueError(
            f"remittance deadline: the mandate's delay is 1..{MAX_DAYS} days, not {max_days}"
        )
    cal = cal or conservative()
    pack = remittance_pack().deadline
    deadline = min(encaissement + timedelta(days=max_days), add_month_cpc641(encaissement))
    last_bd = cal.on_or_before(deadline)
    latest = cal.before(last_bd)
    return RemittanceDeadline(
        encaissement=encaissement,
        deadline=deadline,
        last_business_day=last_bd,
        latest_execution=latest,
        alert_soon=cal.before(latest, pack.alert_soon_business_days),
        alert_critical=cal.before(latest, pack.alert_critical_business_days),
        unmeetable=latest <= encaissement,
    )
