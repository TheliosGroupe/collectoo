"""M2c-3 (design §8.5, §9.2, §18): the SQL side of the engines equals the rule packs and the Python
engine.

* `public.vat_rate` equals worker/rule_packs/vat/fr.yaml, row for row (the CI equality);
* `public.business_calendar` equals the calendar the Python engine computes from
  worker/rule_packs/remittance/fr.yaml, day for day, over the whole seeded horizon;
* `private.remittance_deadline` gives the dates and the « unmeetable » flag of
  collectoo_worker.remittance.deadline on 10,000 generated (encaissement, delay) pairs — short
  delays of 1 to 6 days among them —, its default margins are the pack's, and both refuse the same
  out-of-horizon dates; the 10,000 calls read the calendar by index only (ARCHITECTURE §4);
* `private.reference_data_alerts` raises what the Python tripwires say, and the seeded horizon
  covers the next 12 months (CI fails otherwise)."""

import random
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, one

from collectoo_worker.payments.receipts import paris_date
from collectoo_worker.remittance.calendar import CalendarHorizonError, conservative, horizon_alert
from collectoo_worker.remittance.deadline import (
    add_month_cpc641,
    encaissement_date,
    remittance_deadline,
)
from collectoo_worker.remittance.packs import vat_pack
from collectoo_worker.remittance.vat import rate_on, reviews_due

pytestmark = pytest.mark.integration
N = 10_000


def test_vat_rate_equals_the_rule_pack() -> None:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select code, territory, rate, valid_from, valid_to, legal_ref, legal_url,
                      review_due_on, reviewed_on, reviewed_by
               from public.vat_rate order by code, territory, valid_from"""
        ).fetchall()
        assert [one(conn, "select private.vat_rate_on(%s)", (d,)) for d in _days()] == [
            rate_on(d) for d in _days()
        ]
    pack = [
        (
            r.code,
            r.territory,
            Decimal(r.rate),
            r.valid_from,
            r.valid_to,
            r.legal_ref.title,
            r.legal_ref.url,
            r.review.due_from if r.review else None,
            r.review.reviewed_on if r.review else None,
            r.review.reviewed_by if r.review else None,
        )
        for r in sorted(vat_pack().rates, key=lambda r: (r.code, r.territory, r.valid_from))
    ]
    assert rows == pack


def _days() -> list[date]:
    return [
        date(2014, 1, 1),
        date(2026, 11, 10),
        date(2026, 12, 31),
        date(2027, 1, 1),
        date(2031, 1, 1),
    ]


def test_business_calendar_equals_the_python_calendar() -> None:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select day, closed, label, sources from public.business_calendar
               where scope = 'FR-conservative' order by day"""
        ).fetchall()
    expected = [
        (d, c is not None, " ; ".join(c.labels) if c else None, list(c.sources) if c else [])
        for d, c in conservative().days()
    ]
    assert len(rows) == len(expected) == 2_191
    differ = [(r, e) for r, e in zip(rows, expected, strict=True) if tuple(r) != e]
    assert not differ, differ[:5]


def _pairs(seed: int) -> list[tuple[date, int]]:
    rng = random.Random(seed)
    lo, hi = date(2026, 1, 20), date(2031, 11, 20)
    span = (hi - lo).days
    out = [
        (lo + timedelta(days=rng.randint(0, span)), rng.choice([30, 30, 30, rng.randint(1, 30)]))
        for _ in range(N)
    ]
    # every day of January and February in a leap and a common year, every holiday of the horizon
    edges = [date(2028, 1, 1) + timedelta(days=k) for k in range(70)] + [
        date(2027, 1, 1) + timedelta(days=k) for k in range(70)
    ]
    edges += [
        d for d, c in conservative().days() if c and c.sources != ("weekend",) and lo <= d <= hi
    ]
    # short mandate delays, where the latest execution can fall on or before E (the flag)
    short = [(lo + timedelta(days=3 * k), 1 + k % 6) for k in range(700)]
    return out[: N - len(edges) - len(short)] + [(d, 30) for d in edges] + short


def test_deadline_parity_on_10k_dates() -> None:
    pairs = _pairs(20261111)
    assert len(pairs) == N
    with psycopg.connect(DB) as conn, conn.transaction():
        rows = conn.execute(
            """select t.n, d.encaissement_date, d.deadline, d.last_business_day,
                      d.latest_execution_date, d.alert_soon_date, d.alert_critical_date,
                      d.unmeetable
               from unnest(%s::date[], %s::int[]) with ordinality t (e, days, n)
               cross join lateral private.remittance_deadline(t.e, t.days) d
               order by t.n""",
            ([p[0] for p in pairs], [p[1] for p in pairs]),
        ).fetchall()
        # by key only, whatever the statistics: no sequential scan of the calendar
        scans = conn.execute(
            """select seq_scan, idx_scan from pg_stat_xact_user_tables
               where schemaname = 'public' and relname = 'business_calendar'"""
        ).fetchone()
    assert scans is not None and scans[0] == 0 and scans[1] > 0, scans
    differ = []
    for (e, days), row in zip(pairs, rows, strict=True):
        d = remittance_deadline(e, days)
        py = (
            d.encaissement,
            d.deadline,
            d.last_business_day,
            d.latest_execution,
            d.alert_soon,
            d.alert_critical,
            d.unmeetable,
        )
        if tuple(row[1:]) != py:
            differ.append((e, days, row[1:], py))
    assert not differ, differ[:5]
    flagged = [(e, days) for (e, days), row in zip(pairs, rows, strict=True) if row[7]]
    assert flagged and all(days <= 5 for _, days in flagged), flagged[:5]


def test_both_refuse_the_same_dates() -> None:
    near_ends = [date(2026, 1, 1) + timedelta(days=k) for k in range(15)]
    near_ends += [date(2031, 11, 25) + timedelta(days=k) for k in range(40)]
    cases: list[tuple[date, int]] = [(d, days) for d in near_ends for days in (1, 5, 30)]
    cases.append((date(2025, 12, 1), 30))
    with psycopg.connect(DB) as conn:
        for e, days in cases:
            try:
                py: Any = remittance_deadline(e, days).latest_execution
            except CalendarHorizonError:
                py = "refused"
            try:
                with conn.transaction():
                    sql: Any = one(
                        conn,
                        "select latest_execution_date from private.remittance_deadline(%s, %s)",
                        (e, days),
                    )
            except psycopg.errors.InvalidParameterValue as exc:
                assert "business calendar" in str(exc)
                sql = "refused"
            assert sql == py, (e, days)
        for bad in (0, 31):
            with pytest.raises(psycopg.errors.InvalidParameterValue), conn.transaction():
                conn.execute("select private.remittance_deadline('2026-10-12', %s)", (bad,))


def test_the_small_twins() -> None:
    cases = [
        date(2026, 1, 31),
        date(2027, 1, 31),
        date(2028, 1, 31),
        date(2026, 3, 31),
        date(2026, 12, 31),
    ]
    with psycopg.connect(DB) as conn:
        for d in cases:
            assert one(conn, "select private.add_month_cpc641(%s)", (d,)) == add_month_cpc641(d)
        for booking, value in ((date(2026, 10, 12), date(2026, 10, 9)), (date(2026, 10, 12), None)):
            assert one(conn, "select private.encaissement_date(%s, %s)", (booking, value)) == (
                encaissement_date(booking, value)
            )


@pytest.mark.parametrize(
    "today",
    [
        date(2026, 11, 10),
        date(2026, 11, 30),
        date(2026, 12, 1),
        date(2030, 12, 31),
        date(2031, 1, 1),
    ],
)
def test_reference_data_alerts_are_the_tripwires(today: date) -> None:
    with psycopg.connect(DB) as conn:
        codes = sorted(
            r[0]
            for r in conn.execute("select code from private.reference_data_alerts(%s)", (today,))
        )
    expected = (["calendar_horizon"] if horizon_alert(today) else []) + (
        ["vat_pack_review"] * len(reviews_due(today))
    )
    assert codes == sorted(expected)


def test_the_seeded_horizon_covers_the_next_12_months() -> None:
    today = paris_date(datetime.now(UTC))
    with psycopg.connect(DB) as conn:
        codes = [
            r[0]
            for r in conn.execute("select code from private.reference_data_alerts(%s)", (today,))
        ]
    assert "calendar_horizon" not in codes
