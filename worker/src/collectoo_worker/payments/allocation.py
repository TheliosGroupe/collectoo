"""Allocation waterfall (M2-09): which debts a payment pays, in the legal order. Pure, no I/O.

Design: docs/design/m2b-payments.md §8.5; founder decisions #4-#6 (ADR-0013, M2b-4 addendum).

Legal order (texts quoted in the design, §3):
- C. civ. 1342-10: « Le débiteur de plusieurs dettes peut indiquer, lorsqu'il paie, celle qu'il
  entend acquitter. A défaut d'indication par le débiteur, l'imputation a lieu comme suit : d'abord
  sur les dettes échues ; parmi celles-ci, sur les dettes que le débiteur avait le plus d'intérêt
  d'acquitter. A égalité d'intérêt, l'imputation se fait sur la plus ancienne ; toutes choses
  égales, elle se fait proportionnellement. » A "debt" is a claim item. Designated items first (in
  the order named; an item not yet due is honoured, 1305-3), then due items, oldest due date first
  (then issue date), equal keys shared pro rata, then items not yet due. « Plus d'intérêt
  d'acquitter » is not encoded (OQ-21).
- C. civ. 1343-1: « Le paiement partiel s'impute d'abord sur les intérêts. » Inside each item the
  interest family first, always (not configurable, OQ-19; a designation names debts, not the order
  inside one).
- The rank of the accessories (indemnity, charge, cost: none exists before M3) is the only thing a
  policy chooses (founder #5; OQ-7 for the B2B €40): before principal (CALCULATION_RULES default)
  or after it. The seller's unclassified amounts (EU 3.11, balancing line) come last; for consumer
  loans they are held back until ops classify them (founder #6, OQ-18): the extra stays unallocated
  (an overpayment, founder #8).

Pro rata (largest remainder): share_i = floor(R x demand_i / demand), then one minor unit to the
largest remainders (R x demand_i mod demand), ties by item id, so the shares add up to R exactly.
Each item spends its share in its own family order.

Availability: a slot is a (claim item, component) with an available amount > 0 at the effective
date D, where available = min over t >= D of that receivable's running balance (design §2 #6), so an
allocation dated D never overdraws a later date (I6). `BalanceProfile` computes it and records what
a plan takes, so several payments of one file in one run are planned in date order on the same
numbers the ledger will hold. M3 re-runs earlier allocations by date (founder #16): reverse, then
call `allocate` again on the slots at D; nothing here depends on the clock or on input order.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from datetime import date
from enum import StrEnum
from typing import Any

ENGINE_VERSION = "alloc-1"


class Family(StrEnum):
    """public.ledger_component.family."""

    INTEREST = "interest"
    INDEMNITY = "indemnity"
    CHARGE = "charge"
    COST = "cost"
    PRINCIPAL = "principal"
    UNCLASSIFIED = "unclassified"


ACCESSORIES = frozenset({Family.INDEMNITY, Family.CHARGE, Family.COST})
ACCESSORY_RANKS = ("before_principal", "after_principal")
UNCLASSIFIED_MODES = ("last", "held")
# Consumer loans (Code de la consommation: crédit à la consommation, crédit immobilier): the
# seller's unclassified amounts are not paid by allocation until ops classify them (founder #6,
# OQ-18).
CONSUMER_REGIMES = frozenset(
    {"consumer_credit_pre_ccd2", "consumer_credit_ccd2", "consumer_mortgage"}
)


class PolicyError(ValueError):
    """A policy that the law does not let a client or a portfolio choose."""


@dataclass(frozen=True, slots=True)
class Policy:
    """What a client or portfolio may set (founder #5): where accessories rank, and whether the
    seller's unclassified amounts are held. Interest before principal, designation first and due
    before not due cannot be expressed: there is no field for them."""

    accessory_rank: str = "before_principal"
    unclassified: str = "last"
    policy_id: str | None = None  # None: the built-in default (no allocation_policy row)
    version: int = 0

    def __post_init__(self) -> None:
        if self.accessory_rank not in ACCESSORY_RANKS:
            raise PolicyError(f"accessory_rank must be one of {ACCESSORY_RANKS}")
        if self.unclassified not in UNCLASSIFIED_MODES:
            raise PolicyError(f"unclassified must be one of {UNCLASSIFIED_MODES}")

    @classmethod
    def from_json(cls, data: Mapping[str, Any]) -> Policy:
        """A policy as stored (allocation_policy row or jsonb); unknown keys are refused, so an
        order the law fixes can never be smuggled in (e.g. principal before interest)."""
        allowed = {"accessory_rank", "unclassified", "policy_id", "version"}
        extra = set(data) - allowed
        if extra:
            raise PolicyError(
                f"a policy only sets accessory_rank and unclassified (got {sorted(extra)})"
            )
        return cls(
            accessory_rank=str(data.get("accessory_rank", "before_principal")),
            unclassified=str(data.get("unclassified", "last")),
            policy_id=str(data["policy_id"]) if data.get("policy_id") else None,
            version=int(data.get("version", 0)),
        )

    def for_regime(self, legal_regime: str) -> Policy:
        """Consumer regimes force `held` (founder #6), whatever the policy says."""
        if legal_regime in CONSUMER_REGIMES and self.unclassified != "held":
            return replace(self, unclassified="held")
        return self

    def as_json(self) -> dict[str, Any]:
        return {
            "accessory_rank": self.accessory_rank,
            "unclassified": self.unclassified,
            "policy_id": self.policy_id,
            "version": self.version,
        }

    def family_rank(self, family: Family) -> int | None:
        """Position of a family inside one item; None: never paid by allocation (held)."""
        if family is Family.INTEREST:
            return 0
        if family in ACCESSORIES:
            return 1 if self.accessory_rank == "before_principal" else 3
        if family is Family.PRINCIPAL:
            return 2
        return None if self.unclassified == "held" else 4


@dataclass(frozen=True, slots=True)
class Slot:
    """An open (claim item, component) and what is available on it at the effective date."""

    item_id: str
    component: str
    family: Family
    component_order: int  # public.ledger_component.sort_order
    available_minor: int
    due_date: date | None
    issue_date: date | None = None


@dataclass(frozen=True, slots=True)
class Line:
    item_id: str
    component: str
    amount_minor: int


@dataclass(frozen=True, slots=True)
class Allocation:
    lines: tuple[Line, ...]
    remainder_minor: int  # what stays unallocated (an overpayment, kept in 4710: founder #8)

    @property
    def allocated_minor(self) -> int:
        return sum(x.amount_minor for x in self.lines)


@dataclass(frozen=True, slots=True)
class _Item:
    item_id: str
    due_date: date | None
    issue_date: date | None
    slots: tuple[Slot, ...]  # in family order, held families left out

    @property
    def demand(self) -> int:
        return sum(s.available_minor for s in self.slots)


def _debt_key(item: _Item, designation: Mapping[str, int], as_of: date) -> tuple[Any, ...]:
    """Sort key of a debt (equal keys form one tie group, shared pro rata).

    Designated items first, in the order named; then due items by due date, then issue date; an item
    without a due date counts as due, after the dated ones (its age is unknown; a defaulted loan's
    single item); then items not yet due by due date. An unknown issue date sorts last."""
    if item.item_id in designation:
        return (0, designation[item.item_id])
    issue = item.issue_date or date.max
    if item.due_date is None:
        return (1, 1, issue)
    if item.due_date <= as_of:
        return (1, 0, item.due_date, issue)
    return (2, 0, item.due_date, issue)


def _items(slots: Iterable[Slot], policy: Policy) -> list[_Item]:
    by_item: dict[str, list[Slot]] = {}
    for s in slots:
        if s.available_minor < 0:
            raise ValueError(f"slot {s.item_id}/{s.component}: negative availability")
        if s.available_minor == 0 or policy.family_rank(s.family) is None:
            continue
        by_item.setdefault(s.item_id, []).append(s)
    items = []
    for item_id, group in by_item.items():
        dates = {(s.due_date, s.issue_date) for s in group}
        if len(dates) != 1:
            raise ValueError(f"item {item_id}: its slots disagree on its dates")
        if len({s.component for s in group}) != len(group):
            raise ValueError(f"item {item_id}: a component appears twice")
        ordered = sorted(
            group, key=lambda s: (policy.family_rank(s.family), s.component_order, s.component)
        )
        due, issue = next(iter(dates))
        items.append(_Item(item_id, due, issue, tuple(ordered)))
    return items


def _spend(item: _Item, amount: int, out: list[Line]) -> None:
    """An item's share, spent in its family order (interest first: 1343-1)."""
    left = amount
    for s in item.slots:
        if left == 0:
            return
        take = min(left, s.available_minor)
        if take > 0:
            out.append(Line(s.item_id, s.component, take))
            left -= take
    if left:
        raise AssertionError("a share larger than its item")  # pragma: no cover - by construction


def pro_rata(remaining: int, demands: Sequence[tuple[str, int]]) -> dict[str, int]:
    """Shares of `remaining` (< total demand) by largest remainder; ties by id. Exact integers."""
    total = sum(d for _, d in demands)
    if not 0 <= remaining < total:
        raise ValueError("pro rata only applies when the remaining amount is below the demand")
    shares = {k: remaining * d // total for k, d in demands}
    left = remaining - sum(shares.values())
    by_remainder = sorted(demands, key=lambda kd: (-(remaining * kd[1] % total), kd[0]))
    for k, _ in by_remainder[:left]:
        shares[k] += 1
    return shares


def allocate(
    amount_minor: int,
    slots: Iterable[Slot],
    policy: Policy,
    designation: Sequence[str] = (),
    *,
    as_of: date,
) -> Allocation:
    """The lines of one payment on one file. Deterministic and independent of the input order."""
    if amount_minor < 0:
        raise ValueError("a payment amount is never negative")
    named = {item: n for n, item in enumerate(dict.fromkeys(designation))}
    items = sorted(_items(slots, policy), key=lambda it: (_debt_key(it, named, as_of), it.item_id))
    groups: list[list[_Item]] = []
    for it in items:
        if groups and _debt_key(groups[-1][0], named, as_of) == _debt_key(it, named, as_of):
            groups[-1].append(it)
        else:
            groups.append([it])
    out: list[Line] = []
    remaining = amount_minor
    for group in groups:
        if remaining == 0:
            break
        demand = sum(it.demand for it in group)
        if remaining >= demand:
            for it in group:
                _spend(it, it.demand, out)
            remaining -= demand
            continue
        shares = pro_rata(remaining, [(it.item_id, it.demand) for it in group])
        for it in group:
            _spend(it, shares[it.item_id], out)
        remaining = 0
    return Allocation(tuple(out), remaining)


# -- balances over time (what a plan may take at a date) -----------------------------------------


@dataclass
class BalanceProfile:
    """One receivable's postings summed per date, plus what this run already planned on it."""

    points: dict[date, int] = field(default_factory=dict)

    def balance(self, at: date) -> int:
        return sum(v for d, v in self.points.items() if d <= at)

    def available(self, at: date) -> int:
        """min over t >= at of the running balance (0 if it never goes above 0)."""
        running = self.balance(at)
        low = running
        for d in sorted(k for k in self.points if k > at):
            running += self.points[d]
            low = min(low, running)
        return max(low, 0)

    def take(self, at: date, amount_minor: int) -> None:
        self.points[at] = self.points.get(at, 0) - amount_minor


@dataclass(frozen=True, slots=True)
class Component:
    """A receivable of a file: (item, component) with the facts the order needs."""

    item_id: str
    component: str
    family: Family
    component_order: int
    due_date: date | None
    issue_date: date | None = None


@dataclass
class FileBalances:
    """The receivables of one file (account) and their profiles, for planning several payments."""

    components: dict[tuple[str, str], Component] = field(default_factory=dict)
    profiles: dict[tuple[str, str], BalanceProfile] = field(default_factory=dict)

    def add(self, c: Component, points: Mapping[date, int]) -> None:
        key = (c.item_id, c.component)
        self.components[key] = c
        self.profiles[key] = BalanceProfile(dict(points))

    def slots(self, at: date) -> list[Slot]:
        out = []
        for key, c in sorted(self.components.items()):
            avail = self.profiles[key].available(at)
            if avail > 0:
                out.append(
                    Slot(
                        c.item_id,
                        c.component,
                        c.family,
                        c.component_order,
                        avail,
                        c.due_date,
                        c.issue_date,
                    )
                )
        return out

    def plan(
        self,
        amount_minor: int,
        policy: Policy,
        designation: Sequence[str],
        *,
        at: date,
    ) -> tuple[Allocation, list[Slot]]:
        """Allocate at date `at` and record what it takes (later payments of the run see it)."""
        slots = self.slots(at)
        result = allocate(amount_minor, slots, policy, designation, as_of=at)
        for line in result.lines:
            self.profiles[(line.item_id, line.component)].take(at, line.amount_minor)
        return result, slots


def inputs_hash(  # noqa: PLR0913 - every input of the computation is in the hash
    *,
    payment_id: str,
    account_id: str,
    amount_minor: int,
    effective_date: date,
    policy: Policy,
    designation: Sequence[str],
    slots: Sequence[Slot],
) -> str:
    """sha256 of the canonical inputs (ledger_entry.inputs_hash): the same inputs give the same
    allocation, so M3 can tell whether a re-run by date changes anything."""
    payload = {
        "engine": ENGINE_VERSION,
        "payment": payment_id,
        "account": account_id,
        "amount": str(amount_minor),
        "date": effective_date.isoformat(),
        "policy": policy.as_json(),
        "designation": list(designation),
        "slots": sorted(
            [
                s.item_id,
                s.component,
                str(s.available_minor),
                s.due_date.isoformat() if s.due_date else None,
                s.issue_date.isoformat() if s.issue_date else None,
            ]
            for s in slots
        ),
    }
    text = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode()).hexdigest()
