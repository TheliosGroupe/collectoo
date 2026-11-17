"""M2c-6b-2a foundations, pure parts (plan docs/design/m2c-6b-2-plan.md §2.3, §2.5, §2.6, §6, §8.2):

- `unique_subset`, the twin of SQL `private.unique_subset`: the only subset of a lot's amounts that
  makes a line, or None (none, several, or past a bound) — against brute force, on its complement
  side, at each bound (the lot cap, the partial sums, the stored paths, the work), visiting the
  amounts in the order given (critic2 CSO2-2);
- the job's twin never books a return of a transfer that has an open unplanned booking
  (`unplanned_payout_return`) or a debit pending on a statement (`return_debit_pending`; critic F1,
  L5; critic2 ML-3);
- `P0_REVIEWS` is the alerts' P0 set (critic L14);
- the stage row of a line carries its unsplit details as JSON (critic2 CSO2-9)."""

from __future__ import annotations

import itertools
import re
from dataclasses import replace
from datetime import date
from pathlib import Path

from hypothesis import given, settings
from hypothesis import strategies as st
from psycopg.types.json import Jsonb

from collectoo_worker.jobs.payments import stage_row
from collectoo_worker.payments.debits import (
    BOOKING_REVIEW_REASONS,
    LOT_CAP,
    P0_REVIEWS,
    RETURN_BEFORE_DEBIT,
    RETURN_DEBIT_PENDING,
    SUBSET_PATHS_BOUND,
    SUBSET_SUMS_BOUND,
    SUBSET_WORK_BOUND,
    TRANSFER_UNKNOWN,
    UNPLANNED_PAYOUT_RETURN,
    FundsLine,
    TransferFact,
    decide_bookings,
    decide_line,
    unique_subset,
    unique_subset_trace,
)
from collectoo_worker.payments.statement import STAGE_COLUMNS, StatementLine, UnsplitDetail

REPO = Path(__file__).resolve().parents[2]
BANK = "bank-1"
DAY = date(2026, 11, 3)


# -- unique_subset ------------------------------------------------------------------------------


def brute(amounts: list[int], target: int) -> list[int] | None:
    """The only subset (1-based indexes) summing to target, by enumeration."""
    found = [
        [i + 1 for i in combo]
        for k in range(len(amounts) + 1)
        for combo in itertools.combinations(range(len(amounts)), k)
        if sum(amounts[i] for i in combo) == target
    ]
    return found[0] if len(found) == 1 else None


def oracle(amounts: list[int], target: int) -> list[int] | None:
    """The only subset by another method: up to two subsets kept per sum (no complement side, no
    bound), for the 13-20 amounts brute force is too slow for."""
    if target < 0:
        return None
    ways: dict[int, list[tuple[int, ...]]] = {0: [()]}
    for i, a in enumerate(amounts, start=1):
        new = {s: list(v) for s, v in ways.items()}
        for s, subsets in ways.items():
            if s + a > target:
                continue
            kept = new.setdefault(s + a, [])
            for sub in subsets:
                if len(kept) < 2:
                    kept.append((*sub, i))
        ways = new
    found = ways.get(target, [])
    return list(found[0]) if len(found) == 1 else None


def test_unique_subset_examples() -> None:
    assert unique_subset([100, 100], 100) is None  # equal amounts: two subsets
    assert unique_subset([100, 250, 300], 350) == [1, 2]
    assert unique_subset([100, 200, 400], 600) == [2, 3]  # the complement of the only 100
    assert unique_subset([100, 200, 300], 300) is None  # 300, and 100 + 200
    assert unique_subset([100, 200], 400) is None  # past the total
    assert unique_subset([100, 200], 0) == []
    assert unique_subset([100, 200], 300) == [1, 2]
    assert unique_subset([], 0) == []
    assert unique_subset([100, 0], 100) is None  # an amount that is not positive: no answer
    assert unique_subset([100], -1) is None


@settings(max_examples=600)
@given(
    st.lists(st.integers(1, 40), max_size=12)
    | st.lists(st.sampled_from([5, 10, 15, 20]), max_size=12),
    st.data(),
)
def test_unique_subset_is_the_only_subset_by_brute_force(
    amounts: list[int], data: st.DataObject
) -> None:
    """Hypothesis oracle (≤ 12 amounts: equal amounts, the complement side, every target)."""
    target = data.draw(st.integers(-2, sum(amounts) + 2))
    assert unique_subset(amounts, target) == brute(amounts, target)


def test_the_bounds() -> None:
    assert (LOT_CAP, SUBSET_SUMS_BOUND, SUBSET_PATHS_BOUND, SUBSET_WORK_BOUND) == (
        500,
        10_000,
        200_000,
        1_000_000,
    )
    cap = unique_subset_trace([100] * 501, 100)
    assert (cap.indexes, cap.tripped_at, cap.bound) == (None, 0, "cap")
    full = unique_subset_trace([100] * 500, 50_000)  # t' = 0: the complement of the empty subset
    assert (full.indexes, full.bound) == (tuple(range(1, 501)), None)
    sums = unique_subset_trace([2**g for g in range(14)] + [1_000_000], 12_345)
    assert (sums.indexes, sums.tripped_at, sums.bound) == (None, 14, "sums")
    paths = unique_subset_trace([2**g for g in range(10)] + [1_000_000], 1000, paths_bound=100)
    assert (paths.indexes, paths.tripped_at, paths.bound) == (None, 6, "paths")
    under = unique_subset_trace([2**g for g in range(10)] + [1_000_000], 1000)
    assert (under.indexes, under.bound) == ((4, 6, 7, 8, 9, 10), None)


def test_the_worst_saturating_input_trips_the_work_bound() -> None:
    """CSO2-2: 500 amounts of 5-90 €, t' = 8 000: the sums saturate at t' + 1 and never trip the
    partial-sum bound; the work bound does (the same input as pgTAP 036 D)."""
    amounts = [500 + (g * 7919) % 8501 for g in range(1, 501)]
    out = unique_subset_trace(amounts, 8000)
    assert (out.indexes, out.bound) == (None, "work")
    assert out.tripped_at is not None and 100 < out.tripped_at < 500


def test_the_smaller_side_is_the_one_searched() -> None:
    """A subset makes t iff its complement makes Σ - t: a target near Σ is searched as its small
    complement (here {1}), and answered as the complement of that: twenty powers of two, every
    subset sum distinct, the sums for Σ - 1 itself would pass the partial-sum bound."""
    amounts = [2**i for i in range(20)]
    out = unique_subset_trace(amounts, sum(amounts) - 1)
    assert (out.indexes, out.bound) == (tuple(range(2, 21)), None)
    assert unique_subset(amounts, 1) == [1]


@settings(max_examples=300)
@given(st.lists(st.integers(1, 400), min_size=13, max_size=20), st.data())
def test_near_the_bound_the_answer_is_brute_force_or_a_named_trip(
    amounts: list[int], data: st.DataObject
) -> None:
    """13-20 amounts, where 2^n crosses 10 000: under a lowered bound the trace either answers as
    brute force does, or trips a bound at an item it names (null)."""
    target = data.draw(st.integers(0, sum(amounts)))
    assert unique_subset(amounts, target) == oracle(amounts, target)  # the default bounds
    out = unique_subset_trace(amounts, target, sums_bound=2_000, work_bound=20_000)
    if out.bound is None:
        want = oracle(amounts, target)
        assert (None if out.indexes is None else list(out.indexes)) == want
    else:
        assert out.indexes is None and out.bound in ("sums", "paths", "work")
        assert out.tripped_at is not None and 1 <= out.tripped_at <= len(amounts)


def test_the_items_are_visited_in_the_order_given() -> None:
    """The visiting order is pinned (the callers pass the PmtInf's items by seq): a bound trips at
    the same item in both twins, and an order changes where it trips, not the answer."""
    amounts = [2**g for g in range(14)] + [1_000_000]
    assert unique_subset_trace(amounts, 12_345).tripped_at == 14
    assert unique_subset_trace(list(reversed(amounts)), 12_345).tripped_at == 15


# -- the job's return rule ----------------------------------------------------------------------


def returned(
    *, status: str = "booked", unplanned_open: bool = False, debit_pending: bool = False
) -> FundsLine:
    f = TransferFact(
        id="T1",
        role="return",
        kind="payout",
        status=status,
        amount_minor=164000,
        debtor_bank_account_id=BANK,
        file_id="F1",
        file_status="downloaded",
        file_download_count=1,
        run_status="booked",
        run_transfer_id="T1",
        debit_booked=status in ("booked", "returned"),
        return_booked=status == "returned",
        debit_date=DAY if status in ("booked", "returned") else None,
        unplanned_open=unplanned_open,
        debit_pending=debit_pending,
    )
    return FundsLine(
        "R1",
        "return",
        "credit",
        BANK,
        164000,
        DAY,
        original_end_to_end_id="RMT0123456789AB",
        facts=(f,),
    )


def test_a_return_with_an_open_unplanned_booking_is_reviewed_never_booked() -> None:
    (b,) = decide_line(returned(unplanned_open=True))
    assert (b.booked, b.review_reason) == (False, UNPLANNED_PAYOUT_RETURN)
    (b,) = decide_line(returned(status="cancelled", unplanned_open=True))
    assert b.review_reason == UNPLANNED_PAYOUT_RETURN  # not return_differs
    (b,) = decide_line(returned(debit_pending=True))
    assert (b.booked, b.review_reason) == (False, RETURN_DEBIT_PENDING)
    (b,) = decide_line(returned(status="cancelled", debit_pending=True))
    assert b.review_reason == RETURN_DEBIT_PENDING
    (b,) = decide_line(returned(unplanned_open=True, debit_pending=True))
    assert b.review_reason == UNPLANNED_PAYOUT_RETURN  # the open booking first
    (b,) = decide_line(returned(status="in_file", unplanned_open=True))
    assert b.review_reason == RETURN_BEFORE_DEBIT  # still the first rule
    (b,) = decide_line(returned())
    assert (b.booked, b.kind) == (True, "payout_returned")  # as today
    assert {UNPLANNED_PAYOUT_RETURN, RETURN_DEBIT_PENDING} <= BOOKING_REVIEW_REASONS


@settings(max_examples=400)
@given(
    st.sampled_from(["ordered", "in_file", "booked", "returned", "cancelled"]),
    st.booleans(),
    st.booleans(),
    st.sampled_from(["payout", "sweep"]),
    st.integers(-5000, 0),
)
def test_a_return_is_never_booked_beside_an_unplanned_booking_or_a_pending_debit(
    status: str, unplanned_open: bool, debit_pending: bool, kind: str, delta: int
) -> None:
    """Hypothesis on decide_line (and a pass): an open unplanned booking or a debit pending on a
    statement → never a booking, always its review (unless the transfer is not debited yet)."""
    line = returned(status=status, unplanned_open=unplanned_open, debit_pending=debit_pending)
    orig = ("RMT" if kind == "payout" else "SWP") + "0123456789AB"
    line = replace(
        line,
        amount_minor=164000 + delta,
        original_end_to_end_id=orig,
        facts=(replace(line.facts[0], kind=kind),),
    )
    for out in (decide_line(line), decide_bookings([line])):
        (b,) = out
        if unplanned_open or debit_pending:
            assert not b.booked
            if status not in ("ordered", "in_file"):
                assert b.review_reason == (
                    UNPLANNED_PAYOUT_RETURN if unplanned_open else RETURN_DEBIT_PENDING
                )
        if b.booked:
            assert not unplanned_open and not debit_pending


# -- P0 -----------------------------------------------------------------------------------------


def _latest_definition(name: str) -> str:
    """The body of the latest migration's definition of a function."""
    for path in sorted((REPO / "supabase" / "migrations").glob("*.sql"), reverse=True):
        text = path.read_text("utf-8")
        start = text.find(f"create or replace function {name}(")
        if start >= 0:
            return text[start : text.find("\n$$;", start)]
    raise AssertionError(name)


def test_p0_reviews_are_the_alerts_p0_set() -> None:
    """L14: the reviews the nightly checks raise as P0 alerts (run_transfer_checks: the lines the
    job left to ops for them, cancelled_transfer_debited by its own branch) are P0_REVIEWS, and
    « À classer » ranks the same set first (lib/payments/debits.ts P0_DEBIT_REVIEWS)."""
    body = _latest_definition("private.run_transfer_checks")
    m = re.search(r"v\.reason in \(([^)]*)\)\s*and not exists", body)
    assert m is not None
    alerted = set(re.findall(r"'([a-z_]+)'", m.group(1))) | {"cancelled_transfer_debited"}
    assert alerted == P0_REVIEWS
    web = (REPO / "apps/web/src/lib/payments/debits.ts").read_text("utf-8")
    m = re.search(r"P0_DEBIT_REVIEWS = new Set\(\[([^\]]*)\]\)", web)
    assert m is not None
    assert set(re.findall(r'"([a-z_]+)"', m.group(1))) == P0_REVIEWS
    assert TRANSFER_UNKNOWN in P0_REVIEWS


# -- the stage row ------------------------------------------------------------------------------


def test_the_stage_row_carries_the_details_as_json() -> None:
    """CSO2-9: `stage()` writes the details as Jsonb (a bare tuple would be dumped as an array and
    the COPY into jsonb would fail), the amounts as text, null when absent."""
    line = StatementLine(
        line_no=1,
        section_no=1,
        dedup_key="e:N1#1",
        direction="debit",
        amount_minor=70000,
        currency="EUR",
        booking_date=DAY,
        value_date=None,
        kind="batch_unsplit",
        method="sct",
        batch_entry_ref="N1",
        entry_ref="N1",
        unsplit_ours=2,
        unsplit_details=(
            UnsplitDetail("RMT0000000000A1", "debit", 30000),
            UnsplitDetail("SWP0000000000A2", "credit", None),
        ),
        unsplit_detail_count=3,
        unsplit_batch_count=3,
    )
    row = stage_row("stmt-1", line)
    assert len(row) == 1 + len(STAGE_COLUMNS)
    values = dict(zip(("statement_id", *STAGE_COLUMNS), row, strict=True))
    details = values["unsplit_details"]
    assert isinstance(details, Jsonb)
    assert details.obj == [
        {"id": "RMT0000000000A1", "direction": "debit", "amount_minor": "30000"},
        {"id": "SWP0000000000A2", "direction": "credit", "amount_minor": None},
    ]
    assert (
        values["unsplit_detail_count"],
        values["unsplit_batch_count"],
        values["charges_minor"],
    ) == (3, 3, None)
    plain = replace(
        line,
        unsplit_details=None,
        unsplit_detail_count=None,
        unsplit_batch_count=None,
        unsplit_ours=None,
        charges_minor=120,
    )
    values = dict(zip(("statement_id", *STAGE_COLUMNS), stage_row("stmt-1", plain), strict=True))
    assert (values["unsplit_details"], values["charges_minor"]) == (None, 120)
