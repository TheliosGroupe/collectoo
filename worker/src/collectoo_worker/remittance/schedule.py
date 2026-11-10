"""When a run is due (design §9.3; founder #1; rule pack `remittance/fr`). Pure; the hourly job of
M2c-4 asks it once per Paris business date.

* (a) a scheduled day of the mandate: twice monthly on the 1st and the 16th, or weekly on the
  mandate's weekday (`remittance-1`); a scheduled day that is not a business day moves to the next
  business day;
* (b) the deadline guard: the earliest latest execution date of the client's positive pending items,
  less the pack's 5 business days, is today or past.

(c) a returned payout and (d) « Préparer maintenant » are events, not dates: M2c-4 handles them.
"""

from __future__ import annotations

from collections.abc import Iterable
from datetime import date, timedelta

from collectoo_worker.remittance.calendar import Calendar, conservative
from collectoo_worker.remittance.packs import remittance_pack
from collectoo_worker.remittance.terms import RemittanceTerms


def scheduled_days(terms: RemittanceTerms, month: date, cal: Calendar | None = None) -> list[date]:
    """The run days of one calendar month (`month`: any day of it), moved to business days."""
    cal = cal or conservative()
    first = month.replace(day=1)
    nxt = (first + timedelta(days=32)).replace(day=1)
    if terms.frequency == "twice_monthly":
        nominal = [first.replace(day=d) for d in remittance_pack().schedule.twice_monthly_days]
    else:
        assert terms.weekday is not None  # noqa: S101 (validated: weekly names a weekday)
        offset = (terms.weekday - first.isoweekday()) % 7
        nominal = [first + timedelta(days=offset + 7 * k) for k in range(6)]
        nominal = [d for d in nominal if d < nxt]
    return sorted({cal.on_or_after(d) for d in nominal})


def is_scheduled(terms: RemittanceTerms, today: date, cal: Calendar | None = None) -> bool:
    """True when `today` is a run day of these terms (a moved day may fall in the next month)."""
    cal = cal or conservative()
    if not cal.is_business_day(today):
        return False
    previous = (today.replace(day=1) - timedelta(days=1)).replace(day=1)
    return today in scheduled_days(terms, today, cal) or today in scheduled_days(
        terms, previous, cal
    )


def guard_due(today: date, latest_executions: Iterable[date], cal: Calendar | None = None) -> bool:
    """The deadline guard: a run is prepared once the earliest latest execution date of the positive
    pending items is no more than the pack's margin (5 business days) away."""
    cal = cal or conservative()
    earliest = min(latest_executions, default=None)
    if earliest is None:
        return False
    return cal.before(earliest, remittance_pack().deadline.alert_soon_business_days) <= today
