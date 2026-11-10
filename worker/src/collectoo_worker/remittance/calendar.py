"""The conservative business calendar (design §8.5, §9.2; rule pack `remittance/fr`, ADR-0014
M2c-3).

A day is a business day unless it is a weekend day, a French public holiday (C. trav. L3133-1) or a
TARGET closing day. Closing days come from the pack: fixed days of the year, or days relative to
Easter Sunday (Gregorian computus). The calendar only answers inside its seeded horizon (the pack's
`seeded_from` … `seeded_to`), like its SQL twin `public.business_calendar`, which holds every day of
that horizon: outside it, both refuse rather than guess.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, timedelta
from functools import cache

from collectoo_worker.remittance.packs import CalendarSpec, remittance_pack

ONE_DAY = timedelta(days=1)


class CalendarHorizonError(ValueError):
    """A day outside the seeded horizon of the calendar (SQL twin: 22023 « business calendar: …
    horizon »)."""


def easter_sunday(year: int) -> date:
    """Gregorian Easter Sunday (anonymous Gregorian algorithm, a.k.a. Meeus/Jones/Butcher)."""
    a = year % 19
    b, c = divmod(year, 100)
    d, e = divmod(b, 4)
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = divmod(c, 4)
    el = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * el) // 451
    month, day = divmod(h + el - 7 * m + 114, 31)
    return date(year, month, day + 1)


@dataclass(frozen=True)
class ClosedDay:
    day: date
    labels: tuple[str, ...]  # French, e.g. ("Lundi de Pâques",) or ("samedi",)
    sources: tuple[str, ...]  # weekend | public_holiday | target


@dataclass(frozen=True)
class Calendar:
    """Business days of one scope over its horizon. Pure: built once from the pack."""

    scope: str
    first: date
    last: date
    closed: dict[date, ClosedDay] = field(repr=False)

    def _check(self, day: date) -> None:
        if not self.first <= day <= self.last:
            raise CalendarHorizonError(
                f"business calendar: {day.isoformat()} is outside the seeded horizon "
                f"({self.first.isoformat()} … {self.last.isoformat()})"
            )

    def is_business_day(self, day: date) -> bool:
        self._check(day)
        return day not in self.closed

    def on_or_before(self, day: date) -> date:
        """The last business day on or before `day`."""
        while not self.is_business_day(day):
            day -= ONE_DAY
        return day

    def on_or_after(self, day: date) -> date:
        """The first business day on or after `day` (a scheduled day that is not one moves to the
        next)."""
        while not self.is_business_day(day):
            day += ONE_DAY
        return day

    def before(self, day: date, n: int = 1) -> date:
        """The n-th business day strictly before `day` (n ≥ 1)."""
        if n < 1:
            raise ValueError("n ≥ 1")
        for _ in range(n):
            day = self.on_or_before(day - ONE_DAY)
        return day

    def after(self, day: date, n: int = 1) -> date:
        """The n-th business day strictly after `day` (n ≥ 1)."""
        if n < 1:
            raise ValueError("n ≥ 1")
        for _ in range(n):
            day = self.on_or_after(day + ONE_DAY)
        return day

    def days(self) -> list[tuple[date, ClosedDay | None]]:
        """Every day of the horizon with its closure (None: a business day): what the SQL table
        holds."""
        out: list[tuple[date, ClosedDay | None]] = []
        day = self.first
        while day <= self.last:
            out.append((day, self.closed.get(day)))
            day += ONE_DAY
        return out


WEEKDAY_FR = ("lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche")


def closing_days(spec: CalendarSpec, year: int) -> dict[date, ClosedDay]:
    """The closing days of one year (holidays and TARGET days; `build` adds the weekends)."""
    easter = easter_sunday(year)
    out: dict[date, ClosedDay] = {}
    for c in spec.closing_days:
        if c.easter_offset is not None:
            day = easter + timedelta(days=c.easter_offset)
        else:
            assert c.month is not None and c.day is not None  # noqa: S101 (validated by the pack model)
            day = date(year, c.month, c.day)
        prev = out.get(day)
        labels = (*prev.labels, c.label_fr) if prev else (c.label_fr,)
        sources = tuple(sorted(set(prev.sources if prev else ()) | set(c.sources)))
        out[day] = ClosedDay(day, labels, sources)
    return out


def build(spec: CalendarSpec) -> Calendar:
    closed: dict[date, ClosedDay] = {}
    for year in range(spec.seeded_from.year, spec.seeded_to.year + 1):
        closed.update(closing_days(spec, year))
    day = spec.seeded_from
    while day <= spec.seeded_to:
        if day.isoweekday() in spec.weekend_isodays:
            prev = closed.get(day)
            labels = (
                (*prev.labels, WEEKDAY_FR[day.weekday()]) if prev else (WEEKDAY_FR[day.weekday()],)
            )
            sources = tuple(sorted({"weekend", *(prev.sources if prev else ())}))
            closed[day] = ClosedDay(day, labels, sources)
        day += ONE_DAY
    return Calendar(spec.scope, spec.seeded_from, spec.seeded_to, closed)


@cache
def conservative() -> Calendar:
    """The FR-conservative calendar of the remittance pack."""
    return build(remittance_pack().calendar)


def horizon_alert(today: date, cal: Calendar | None = None) -> bool:
    """True when less than the pack's minimum horizon (12 months) is seeded after `today`
    (`calendar_horizon`)."""
    cal = cal or conservative()
    months = remittance_pack().calendar.min_horizon_months
    return cal.last < add_months(today, months)


def add_months(day: date, months: int) -> date:
    """`day` plus whole months; a day the target month lacks becomes its last day (CPC 641 al. 2;
    Postgres `date + interval 'n months'` does the same)."""
    y, m = divmod(day.month - 1 + months, 12)
    year, month = day.year + y, m + 1
    nxt = date(year + (month == 12), month % 12 + 1, 1)
    return min(date(year, month, 1) + timedelta(days=day.day - 1), nxt - ONE_DAY)


def seed_values_sql(cal: Calendar | None = None) -> str:
    """The holiday rows of the migration's seed (weekends are generated in SQL): one VALUES row per
    closing day that is not only a weekend day. `python -m collectoo_worker.remittance.calendar`
    prints them."""
    cal = cal or conservative()
    rows = []
    for day, closed in cal.days():
        if closed is None or closed.sources == ("weekend",):
            continue
        labels = [lab for lab in closed.labels if lab not in WEEKDAY_FR]
        sources = [s for s in closed.sources if s != "weekend"]
        label = " ; ".join(labels).replace("'", "''")
        rows.append(f"  ('{day.isoformat()}', '{label}', array{sources!r}::text[])")
    return ",\n".join(rows)


if __name__ == "__main__":  # pragma: no cover
    print(seed_values_sql())
