"""M2-09 allocation waterfall: properties (Hypothesis) and the design's worked example (§8.2).

Acceptance (ROADMAP M2-09): allocation never exceeds component balances; Σ allocated = payment
amount, or the remainder is an overpayment. An item is never paid beyond the net of all its
components (a negative balancing line or credit counts: M2b-4 review #0). Plus the legal order:
designated debts first, then due debts oldest first, equal ones pro rata, then debts not yet due
(the same order among designated debts: review #1); inside each debt interest first (1343-1);
accessories where the policy ranks them (OQ-7); the seller's unclassified amounts last, held for
consumer loans (founder #6). Deterministic, independent of input order, re-runnable by date (M3).
"""

from __future__ import annotations

import random
from collections import defaultdict
from datetime import date, timedelta
from fractions import Fraction

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from collectoo_worker.payments.allocation import (
    Allocation,
    Component,
    Family,
    FileBalances,
    Policy,
    PolicyError,
    Slot,
    allocate,
    inputs_hash,
    pro_rata,
)

AS_OF = date(2026, 10, 12)
OPENED = date(2026, 9, 30)
COMPONENTS = (
    ("accrued_interest", Family.INTEREST, 20),
    ("late_interest", Family.INTEREST, 25),
    ("b2b_indemnity", Family.INDEMNITY, 40),
    ("principal", Family.PRINCIPAL, 10),
    ("other_balances", Family.UNCLASSIFIED, 30),
    ("balancing_line", Family.UNCLASSIFIED, 90),
)
ORDER = {c: n for c, _, n in COMPONENTS}
FAMILY = {c: f for c, f, _ in COMPONENTS}

dates = st.one_of(st.none(), st.dates(AS_OF - timedelta(days=200), AS_OF + timedelta(days=60)))
# few distinct dates, so equal due dates (pro rata) are common
due_dates = st.one_of(
    st.none(),
    st.sampled_from(
        [AS_OF - timedelta(days=90), AS_OF - timedelta(days=30), AS_OF, AS_OF + timedelta(days=20)]
    ),
)


@st.composite
def files(draw: st.DrawFn) -> list[Slot]:
    n_items = draw(st.integers(1, 6))
    slots = []
    for i in range(n_items):
        item = f"i{i:02d}"
        due = draw(due_dates)
        issue = draw(
            st.one_of(
                st.none(),
                st.sampled_from([AS_OF - timedelta(days=120), AS_OF - timedelta(days=60)]),
            )
        )
        comps = draw(
            st.lists(st.sampled_from(COMPONENTS), min_size=1, max_size=4, unique_by=lambda c: c[0])
        )
        for comp, family, order in comps:
            slots.append(Slot(item, comp, family, order, draw(st.integers(0, 100_000)), due, issue))
    return slots


policies = st.builds(
    Policy,
    accessory_rank=st.sampled_from(["before_principal", "after_principal"]),
    unclassified=st.sampled_from(["last", "held"]),
)


@st.composite
def cases(draw: st.DrawFn) -> tuple[int, list[Slot], Policy, list[str]]:
    slots = draw(files())
    policy = draw(policies)
    items = sorted({s.item_id for s in slots})
    designation = draw(st.lists(st.sampled_from(items), max_size=3, unique=True))
    total = sum(s.available_minor for s in slots)
    amount = draw(st.integers(0, total + total // 5 + 10))
    return amount, slots, policy, designation


def eligible(slots: list[Slot], policy: Policy) -> list[Slot]:
    return [s for s in slots if s.available_minor > 0 and policy.family_rank(s.family) is not None]


def paid(result: Allocation) -> dict[tuple[str, str], int]:
    out: dict[tuple[str, str], int] = defaultdict(int)
    for x in result.lines:
        out[(x.item_id, x.component)] += x.amount_minor
    return out


def exhausted(slots: list[Slot], result: Allocation, item: str) -> bool:
    p = paid(result)
    return all(
        p.get((s.item_id, s.component), 0) == s.available_minor for s in slots if s.item_id == item
    )


def item_paid(result: Allocation, item: str) -> int:
    return sum(x.amount_minor for x in result.lines if x.item_id == item)


def legal_rank(
    item: str, designation: list[str], meta: dict[str, tuple[date | None, date | None]]
) -> tuple[object, ...]:
    """1342-10: designated debts first, then the others; in each block due debts oldest due date
    first (then issue date; undated after dated), then debts not yet due. Equal ranks: pro rata."""
    due, issue = meta[item]
    issue_key = issue or date.max
    if due is None:
        legal: tuple[object, ...] = (0, 1, issue_key)
    elif due <= AS_OF:
        legal = (0, 0, due, issue_key)
    else:
        legal = (1, 0, due, issue_key)
    return (0 if item in designation else 1, *legal)


@given(cases())
@settings(max_examples=400)
def test_amounts_add_up_and_never_exceed_a_balance(
    case: tuple[int, list[Slot], Policy, list[str]],
) -> None:
    amount, slots, policy, designation = case
    result = allocate(amount, slots, policy, designation, as_of=AS_OF)
    # Σ allocated + remainder = the payment (the remainder is an overpayment, kept unallocated)
    assert result.allocated_minor + result.remainder_minor == amount
    assert result.remainder_minor >= 0
    by_key = {(s.item_id, s.component): s for s in slots}
    seen = set()
    for line in result.lines:
        assert line.amount_minor > 0
        key = (line.item_id, line.component)
        assert key not in seen  # one line per (item, component)
        seen.add(key)
        assert line.amount_minor <= by_key[key].available_minor
    # a remainder only once every slot the policy lets us pay is empty
    ok = eligible(slots, policy)
    if result.remainder_minor > 0:
        assert result.allocated_minor == sum(s.available_minor for s in ok)
    else:
        assert result.allocated_minor == amount


@given(cases())
@settings(max_examples=400)
def test_interest_first_inside_each_debt(case: tuple[int, list[Slot], Policy, list[str]]) -> None:
    """1343-1: no principal while the same item's interest has something left; accessories where the
    policy ranks them; unclassified last, or never when held."""
    amount, slots, policy, designation = case
    result = allocate(amount, slots, policy, designation, as_of=AS_OF)
    p = paid(result)
    for line in result.lines:
        rank = policy.family_rank(FAMILY[line.component])
        assert rank is not None  # a held family is never paid
        for s in slots:
            other = policy.family_rank(s.family)
            if s.item_id == line.item_id and other is not None and other < rank:
                assert p.get((s.item_id, s.component), 0) == s.available_minor


@given(cases())
@settings(max_examples=400)
def test_debts_in_the_legal_order(case: tuple[int, list[Slot], Policy, list[str]]) -> None:
    """1342-10: designated debts first (among them the legal order: a designation without a split
    names debts, not an order), then due ones oldest first, then the rest; an item is paid only once
    every debt before it is exhausted."""
    amount, slots, policy, designation = case
    result = allocate(amount, slots, policy, designation, as_of=AS_OF)
    ok = eligible(slots, policy)
    meta = {s.item_id: (s.due_date, s.issue_date) for s in ok}

    def rank(item: str) -> tuple[object, ...]:
        return legal_rank(item, designation, meta)

    paid_items = {x.item_id for x in result.lines}
    for item in paid_items:
        for other in meta:
            if rank(other) < rank(item):
                assert exhausted(ok, result, other), (item, other)
    # due before not due
    not_due = {i for i, (due, _) in meta.items() if due is not None and due > AS_OF}
    if any(i in not_due and i not in designation for i in paid_items):
        for i, (due, _) in meta.items():
            if i not in designation and (due is None or due <= AS_OF):
                assert exhausted(ok, result, i)


@given(cases())
@settings(max_examples=400)
def test_equal_debts_share_pro_rata_to_the_cent(
    case: tuple[int, list[Slot], Policy, list[str]],
) -> None:
    amount, slots, policy, designation = case
    result = allocate(amount, slots, policy, designation, as_of=AS_OF)
    ok = eligible(slots, policy)
    meta = {s.item_id: (s.due_date, s.issue_date) for s in ok}
    demand: dict[str, int] = defaultdict(int)
    for s in ok:
        demand[s.item_id] += s.available_minor
    groups: dict[tuple[object, ...], list[str]] = defaultdict(list)
    for item in meta:  # designated debts with equal keys share pro rata too (review #1)
        groups[legal_rank(item, designation, meta)].append(item)
    for members in groups.values():
        got = {i: item_paid(result, i) for i in members}
        total = sum(demand[i] for i in members)
        r = sum(got.values())
        if 0 < r < total:  # the group the money ran out in: shares within one cent of exact
            for i in members:
                exact = Fraction(r * demand[i], total)
                assert abs(got[i] - exact) < 1


@given(cases(), st.randoms(use_true_random=False))
@settings(max_examples=200)
def test_deterministic_and_independent_of_input_order(
    case: tuple[int, list[Slot], Policy, list[str]], rnd: random.Random
) -> None:
    amount, slots, policy, designation = case
    first = allocate(amount, slots, policy, designation, as_of=AS_OF)
    shuffled = list(slots)
    rnd.shuffle(shuffled)
    assert allocate(amount, shuffled, policy, designation, as_of=AS_OF) == first
    assert allocate(amount, slots, policy, designation, as_of=AS_OF) == first
    # the order a designation was stored in changes nothing (the RPC stores uuid order: review #1)
    named = list(designation)
    rnd.shuffle(named)
    assert allocate(amount, slots, policy, named, as_of=AS_OF) == first


@given(cases())
@settings(max_examples=200)
def test_consumer_loans_never_pay_unclassified_amounts(
    case: tuple[int, list[Slot], Policy, list[str]],
) -> None:
    amount, slots, policy, designation = case
    consumer = policy.for_regime("consumer_credit_ccd2")
    assert consumer.unclassified == "held"
    result = allocate(amount, slots, consumer, designation, as_of=AS_OF)
    assert all(FAMILY[x.component] is not Family.UNCLASSIFIED for x in result.lines)
    assert policy.for_regime("commercial_b2b") == policy


@given(st.integers(0, 10**9), st.lists(st.integers(1, 10**7), min_size=1, max_size=8))
def test_pro_rata_is_exact(remaining_seed: int, demands: list[int]) -> None:
    total = sum(demands)
    remaining = remaining_seed % total
    named = [(f"k{n}", d) for n, d in enumerate(demands)]
    shares = pro_rata(remaining, named)
    assert sum(shares.values()) == remaining
    for k, d in named:
        assert 0 <= shares[k] <= d
        assert abs(shares[k] - Fraction(remaining * d, total)) < 1


def test_pro_rata_gives_the_leftover_cents_to_the_largest_remainders_then_by_id() -> None:
    # 100 shared by three equal debts: 33.33 each; the leftover cent goes to the first id
    assert pro_rata(100, [("b", 50), ("a", 50), ("c", 50)]) == {"a": 34, "b": 33, "c": 33}
    # 10 shared 1:2: 3.33 / 6.67 -> the larger remainder (0.67) gets the cent
    assert pro_rata(10, [("x", 100), ("y", 200)]) == {"x": 3, "y": 7}


def test_a_policy_cannot_put_principal_before_interest() -> None:
    with pytest.raises(PolicyError):
        Policy.from_json({"order": ["principal", "interest"]})
    with pytest.raises(PolicyError):
        Policy.from_json({"interest_rank": "after_principal"})
    with pytest.raises(PolicyError):
        Policy(accessory_rank="first")
    with pytest.raises(PolicyError):
        Policy(unclassified="before_principal")
    # every policy that can be expressed ranks interest before principal
    for p in (
        Policy(a, u) for a in ("before_principal", "after_principal") for u in ("last", "held")
    ):
        assert p.family_rank(Family.INTEREST) < p.family_rank(Family.PRINCIPAL)  # type: ignore[operator]


def test_accessories_follow_the_policy() -> None:
    """OQ-7: where the B2B €40 ranks is data (none exists before M3)."""
    slots = [
        Slot("f", "late_interest", Family.INTEREST, 25, 1_000, AS_OF),
        Slot("f", "b2b_indemnity", Family.INDEMNITY, 40, 4_000, AS_OF),
        Slot("f", "principal", Family.PRINCIPAL, 10, 100_000, AS_OF),
    ]
    before = allocate(6_000, slots, Policy("before_principal"), as_of=AS_OF)
    assert [(x.component, x.amount_minor) for x in before.lines] == [
        ("late_interest", 1_000),
        ("b2b_indemnity", 4_000),
        ("principal", 1_000),
    ]
    after = allocate(6_000, slots, Policy("after_principal"), as_of=AS_OF)
    assert [(x.component, x.amount_minor) for x in after.lines] == [
        ("late_interest", 1_000),
        ("principal", 5_000),
    ]


def test_worked_example_of_the_design() -> None:
    """§8.2: P1 (200 000, designates F-103) on M-0042 after the credit note; P2 (520 000) on L-9,
    consumer credit: interest, then principal; the unclassified 3 000 is held, 8 000 stays over."""
    m42 = [
        Slot("F-101", "principal", Family.PRINCIPAL, 10, 130_000, date(2026, 6, 10)),
        Slot("F-102", "principal", Family.PRINCIPAL, 10, 80_000, date(2026, 7, 15)),
        Slot("F-103", "principal", Family.PRINCIPAL, 10, 40_000, date(2026, 8, 20)),
        Slot("F-104", "principal", Family.PRINCIPAL, 10, 30_000, date(2026, 12, 15)),
    ]
    p1 = allocate(200_000, m42, Policy(), ["F-103"], as_of=AS_OF)
    assert [(x.item_id, x.amount_minor) for x in p1.lines] == [
        ("F-103", 40_000),
        ("F-101", 130_000),
        ("F-102", 30_000),
    ]
    assert p1.remainder_minor == 0
    l9 = [
        Slot("loan", "accrued_interest", Family.INTEREST, 20, 12_000, None),
        Slot("loan", "principal", Family.PRINCIPAL, 10, 500_000, None),
        Slot("loan", "other_balances", Family.UNCLASSIFIED, 30, 3_000, None),
    ]
    p2 = allocate(520_000, l9, Policy().for_regime("consumer_credit_pre_ccd2"), as_of=AS_OF)
    assert [(x.component, x.amount_minor) for x in p2.lines] == [
        ("accrued_interest", 12_000),
        ("principal", 500_000),
    ]
    assert (
        p2.remainder_minor == 8_000
    )  # overpayment: partially_allocated, never passed to the client
    # a B2B loan pays the seller's unclassified amounts last
    b2b = allocate(520_000, l9, Policy(), as_of=AS_OF)
    assert [(x.component, x.amount_minor) for x in b2b.lines][-1] == ("other_balances", 3_000)
    assert b2b.remainder_minor == 5_000


def test_a_designated_debt_not_yet_due_is_honoured() -> None:
    """1305-3: the term benefits the debtor; he may pay a debt not yet due if he names it."""
    slots = [
        Slot("due", "principal", Family.PRINCIPAL, 10, 50_000, AS_OF - timedelta(days=10)),
        Slot("later", "principal", Family.PRINCIPAL, 10, 30_000, AS_OF + timedelta(days=30)),
    ]
    named = allocate(40_000, slots, Policy(), ["later"], as_of=AS_OF)
    assert [(x.item_id, x.amount_minor) for x in named.lines] == [
        ("later", 30_000),
        ("due", 10_000),
    ]
    plain = allocate(40_000, slots, Policy(), as_of=AS_OF)
    assert [(x.item_id, x.amount_minor) for x in plain.lines] == [("due", 40_000)]
    # among designated debts the due one first; the designated one not yet due still comes before
    # the debts not named
    older = Slot("older", "principal", Family.PRINCIPAL, 10, 20_000, AS_OF - timedelta(days=90))
    both = allocate(70_000, [*slots, older], Policy(), ["later", "due"], as_of=AS_OF)
    assert [(x.item_id, x.amount_minor) for x in both.lines] == [
        ("due", 50_000),
        ("later", 20_000),
    ]


# 9f... sorts after 1a...: the RPC path (assign_payment) stores a designation in uuid order
F101 = "9f000000-0000-0000-0000-000000000101"
F103 = "1a000000-0000-0000-0000-000000000103"


@pytest.mark.parametrize("named", [[F101, F103], [F103, F101]])
def test_designated_debts_are_paid_oldest_first_whatever_the_stored_order(
    named: list[str],
) -> None:
    """M2b-4 review #1: the debtor named F-101 (due 10/06) and F-103 (due 20/08) and paid less than
    both. A designation without a split names debts, not an order: 1342-10 decides among them, so
    F-101, the oldest, is paid first, whatever order the designation was stored in."""
    slots = [
        Slot(F101, "principal", Family.PRINCIPAL, 10, 130_000, date(2026, 6, 10)),
        Slot(F103, "principal", Family.PRINCIPAL, 10, 40_000, date(2026, 8, 20)),
    ]
    result = allocate(50_000, slots, Policy(), named, as_of=AS_OF)
    assert [(x.item_id, x.amount_minor) for x in result.lines] == [(F101, 50_000)]


@pytest.mark.parametrize("named", [["a", "b"], ["b", "a"]])
def test_designated_debts_due_the_same_day_share_pro_rata(named: list[str]) -> None:
    """M2b-4 review #1: two designated invoices of 500,00 € due the same day, 600,00 € paid:
    « toutes choses égales, elle se fait proportionnellement » (1342-10), as without designation."""
    slots = [
        Slot("a", "principal", Family.PRINCIPAL, 10, 50_000, date(2026, 9, 1)),
        Slot("b", "principal", Family.PRINCIPAL, 10, 50_000, date(2026, 9, 1)),
    ]
    result = allocate(60_000, slots, Policy(), named, as_of=AS_OF)
    assert [(x.item_id, x.amount_minor) for x in result.lines] == [("a", 30_000), ("b", 30_000)]
    assert allocate(60_000, slots, Policy(), as_of=AS_OF) == result


# -- several payments on one file, over time (I6, and M3's re-run by date) -----------------------


@st.composite
def histories(
    draw: st.DrawFn,
) -> tuple[list[tuple[Component, dict[date, int]]], list[tuple[date, int]], Policy]:
    comps = []
    n = draw(st.integers(1, 4))
    for i in range(n):
        due = draw(due_dates)
        for comp, family, order in draw(
            st.lists(st.sampled_from(COMPONENTS), min_size=1, max_size=3, unique_by=lambda c: c[0])
        ):
            # a component may be negative: a credit, or an EU balancing line that brings the
            # components down to the legal balance 3.12 (review #0)
            opening = draw(st.integers(-20_000, 50_000))
            points = {OPENED: opening}
            # an earlier run's allocation dated later than some of this run's payments, or a later
            # correction that takes a negative component further down
            if draw(st.booleans()) and opening:
                points[date(2026, 10, 20)] = -draw(st.integers(0, abs(opening)))
            comps.append((Component(f"i{i}", comp, family, order, due), points))
    payments = draw(
        st.lists(
            st.tuples(
                st.sampled_from([date(2026, 10, d) for d in (1, 5, 12, 25)]), st.integers(1, 60_000)
            ),
            max_size=6,
        )
    )
    return comps, sorted(payments, key=lambda p: p[0]), draw(policies)


def _file(comps: list[tuple[Component, dict[date, int]]]) -> FileBalances:
    f = FileBalances()
    for c, pts in comps:
        f.add(c, pts)
    return f


@given(histories())
@settings(max_examples=300)
def test_payments_planned_in_date_order_never_overdraw_a_later_date(
    h: tuple[list[tuple[Component, dict[date, int]]], list[tuple[date, int]], Policy],
) -> None:
    """I6: after the run, a receivable credited at D is never below zero from D on."""
    comps, payments, policy = h
    f = _file(comps)
    taken: dict[tuple[str, str], date] = {}
    for at, amount in payments:
        result, _ = f.plan(amount, policy, (), at=at)
        assert result.allocated_minor + result.remainder_minor == amount
        for x in result.lines:
            taken.setdefault((x.item_id, x.component), at)
    for key, first in taken.items():
        prof = f.profiles[key]
        for d in sorted({*prof.points, first}):
            if d >= first:
                assert prof.balance(d) >= 0


@given(histories())
@settings(max_examples=300)
def test_a_rerun_by_date_gives_the_same_allocation(
    h: tuple[list[tuple[Component, dict[date, int]]], list[tuple[date, int]], Policy],
) -> None:
    """Founder #16 (M3 re-runs earlier allocations by date): planning the payments one per run, each
    run reading the ledger as the previous ones left it, gives what one run planned; and reversing
    everything, then re-running, gives the same lines again (nothing changed, nothing moves)."""
    comps, payments, policy = h
    one_run = _file(comps)
    together = [one_run.plan(amount, policy, (), at=at)[0] for at, amount in payments]
    ledger = {c.item_id + "/" + c.component: dict(p) for c, p in comps}
    separate = []
    for at, amount in payments:
        f = _file([(c, ledger[c.item_id + "/" + c.component]) for c, _ in comps])
        result, _ = f.plan(amount, policy, (), at=at)
        separate.append(result)
        for x in result.lines:  # what post_allocations writes, read back by the next run
            pts = ledger[x.item_id + "/" + x.component]
            pts[at] = pts.get(at, 0) - x.amount_minor
    assert separate == together
    again = _file(comps)  # every allocation reversed at its own date: the openings again
    assert [again.plan(amount, policy, (), at=at)[0] for at, amount in payments] == together


def item_net(f: FileBalances, item: str, at: date) -> int:
    """The item as a whole at a date: every component summed, held and negative ones included."""
    return sum(p.balance(at) for (i, _), p in f.profiles.items() if i == item)


def from_on(f: FileBalances, at: date) -> list[date]:
    """`at` and every later date a balance of the file changes (balances are step functions)."""
    return sorted({at, *(d for p in f.profiles.values() for d in p.points if d > at)})


@given(histories())
@settings(max_examples=400)
def test_an_item_is_never_paid_beyond_its_net_balance(
    h: tuple[list[tuple[Component, dict[date, int]]], list[tuple[date, int]], Policy],
) -> None:
    """M2b-4 review #0: Σ lines on an item ≤ the item's net balance (all its components, held and
    negative ones included) at every date from D on; the excess stays unallocated (an overpayment:
    founder #8, C. civ. 1302-1). The cap trims the lowest ranks first, so interest stays first; and
    a remainder is left only once every item is paid up to the lower of its slots and its net."""
    comps, payments, policy = h
    f = _file(comps)
    items = sorted({c.item_id for c, _ in comps})
    first: dict[str, date] = {}
    for at, amount in payments:
        dates = from_on(f, at)
        net = {i: min(item_net(f, i, t) for t in dates) for i in items}
        avail = {k: max(0, min(p.balance(t) for t in dates)) for k, p in f.profiles.items()}
        result, _ = f.plan(amount, policy, (), at=at)
        assert result.allocated_minor + result.remainder_minor == amount
        per_item: dict[str, int] = defaultdict(int)
        for x in result.lines:
            per_item[x.item_id] += x.amount_minor
            first.setdefault(x.item_id, at)
        for i, got in per_item.items():
            assert got <= net[i], (i, got, net[i])
        p = paid(result)
        for x in result.lines:  # 1343-1, measured on what each component had before the cap
            rank = policy.family_rank(FAMILY[x.component])
            assert rank is not None
            for (i, c), a in avail.items():
                other = policy.family_rank(FAMILY[c])
                if i == x.item_id and other is not None and other < rank:
                    assert p.get((i, c), 0) == a, (x, c)
        if result.remainder_minor:
            for i in items:
                payable = sum(
                    a
                    for (j, c), a in avail.items()
                    if j == i and policy.family_rank(FAMILY[c]) is not None
                )
                assert per_item.get(i, 0) == min(payable, max(net[i], 0)), i
    # after the run, an item paid at D is not below zero on any date from D on (the SQL backstop)
    for i, d0 in first.items():
        for t in from_on(f, d0):
            assert item_net(f, i, t) >= 0, (i, t)


def _loan(points: dict[str, dict[date, int]]) -> FileBalances:
    f = FileBalances()
    for comp, pts in points.items():
        f.add(Component("L", comp, FAMILY[comp], ORDER[comp], None), pts)
    return f


@pytest.mark.parametrize(
    "policy", [Policy(), Policy().for_regime("consumer_credit_ccd2")], ids=["b2b", "consumer"]
)
def test_a_negative_balancing_line_caps_the_loan_at_its_legal_balance(policy: Policy) -> None:
    """M2b-4 review #0: an EU loan's components add up to the legal balance 3.12 through a signed
    balancing line (founder 2026-11-07 #6). Principal 5 000,00, interest 120,00, balancing line
    -220,00: 3.12 = 4 900,00. A payment of 5 120,00 (an old statement) pays interest 120,00, then
    principal 4 780,00; the 220,00 not owed stay unallocated (an overpayment, refunded: founder #8,
    C. civ. 1302-1), never passed to the client."""
    f = _loan(
        {
            "principal": {OPENED: 500_000},
            "accrued_interest": {OPENED: 12_000},
            "other_balances": {OPENED: 0},
            "balancing_line": {OPENED: -22_000},
        }
    )
    result, slots = f.plan(512_000, policy, (), at=AS_OF)
    assert [(x.component, x.amount_minor) for x in result.lines] == [
        ("accrued_interest", 12_000),
        ("principal", 478_000),
    ]
    assert result.remainder_minor == 22_000
    assert item_net(f, "L", AS_OF) == 0
    # the slots returned (for the inputs hash) are the capped ones: they give the same lines
    assert allocate(512_000, slots, policy, as_of=AS_OF) == result


def test_a_negative_principal_nets_a_positive_balancing_line() -> None:
    """M2b-4 review #0: principal -1,01 and balancing line +1,01 (a rounding case of the opening):
    the item's net is 0, so nothing is paid."""
    f = _loan({"principal": {OPENED: -101}, "balancing_line": {OPENED: 101}})
    result, _ = f.plan(1_000, Policy(), (), at=AS_OF)
    assert result.lines == ()
    assert result.remainder_minor == 1_000


def test_the_cap_trims_the_lowest_ranks_first_and_looks_at_later_dates() -> None:
    """The excess over the item's net comes off the slot paid last (unclassified, then principal):
    interest is trimmed last (1343-1). A later-dated fall of the item's net caps it too (an
    allocation at D never takes the item below zero at a later date)."""
    pts = {
        "accrued_interest": {OPENED: 1_000},
        "principal": {OPENED: 10_000},
        "other_balances": {OPENED: 3_000},
        "balancing_line": {OPENED: -2_000},
    }
    b2b, _ = _loan(pts).plan(20_000, Policy(), (), at=AS_OF)
    assert [(x.component, x.amount_minor) for x in b2b.lines] == [
        ("accrued_interest", 1_000),
        ("principal", 10_000),
        ("other_balances", 1_000),
    ]
    assert b2b.remainder_minor == 8_000
    # held (consumer): 3.11 is not paid, and the net (12 000) is above what may be paid (11 000)
    consumer = Policy().for_regime("consumer_mortgage")
    held, _ = _loan(pts).plan(20_000, consumer, (), at=AS_OF)
    assert [(x.component, x.amount_minor) for x in held.lines] == [
        ("accrued_interest", 1_000),
        ("principal", 10_000),
    ]
    later = _loan(
        {
            "accrued_interest": {OPENED: 1_000},
            "principal": {OPENED: 10_000},
            "balancing_line": {AS_OF + timedelta(days=8): -10_500},
        }
    )
    capped, _ = later.plan(20_000, Policy(), (), at=AS_OF)
    assert [(x.component, x.amount_minor) for x in capped.lines] == [("accrued_interest", 500)]
    assert capped.remainder_minor == 19_500


def test_inputs_hash_changes_with_any_input() -> None:
    slots = [Slot("a", "principal", Family.PRINCIPAL, 10, 1_000, AS_OF)]
    base = {
        "payment_id": "p",
        "account_id": "a",
        "amount_minor": 500,
        "effective_date": AS_OF,
        "policy": Policy(),
        "designation": (),
        "slots": slots,
    }
    h = inputs_hash(**base)  # type: ignore[arg-type]
    assert h == inputs_hash(**base)  # type: ignore[arg-type]
    assert len(h) == 64
    for change in (
        {"amount_minor": 501},
        {"effective_date": AS_OF + timedelta(days=1)},
        {"policy": Policy(unclassified="held")},
        {"designation": ("a",)},
        {"slots": [Slot("a", "principal", Family.PRINCIPAL, 10, 999, AS_OF)]},
    ):
        assert inputs_hash(**{**base, **change}) != h  # type: ignore[arg-type]
    # a designation is a set of debts (review #1): the order it was stored in is not an input
    two = {**base, "slots": [*slots, Slot("b", "principal", Family.PRINCIPAL, 10, 1_000, AS_OF)]}
    assert inputs_hash(**{**two, "designation": ("a", "b")}) == inputs_hash(  # type: ignore[arg-type]
        **{**two, "designation": ("b", "a")}  # type: ignore[arg-type]
    )
