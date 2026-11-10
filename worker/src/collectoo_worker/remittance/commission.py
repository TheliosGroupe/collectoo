"""The commission engine `commission-1` (design §8.1, §8.3; founder #4, #5, #6; ADR-0014 M2c-3).

Pure and deterministic: integers in minor units, rates as exact decimals (at most 4 places). Per
version v of the terms and per (file, tier key), the design's rate function, summed exactly:

    g(c) = r·c                              flat
         = Σᵢ rᵢ·max(0, min(c, uᵢ) - lᵢ)     marginal: tiers on what the file brought in
         = r(attribute)·c                   bracket: one rate set by boarded amount or age

and, inside one version, its cumulative function F(c) = 0 if c = 0, else
min(max(m, R(g(c))), ⌊c / (1 + τ)⌋) — m the minimum per file, τ the VAT rate, R one rounding
half-up to the cent.

The commission of a (file, tier key) is a function of its live lines only, never of how they fell
into runs (review fixes of 2026-11-10): each live line priced by the version in force on its
encaissement date (founder #5: new rates only for the future), each version's tiers continuing
where the earlier versions' net basis ends (the tier key is stable across versions; the
versions' segments in version order). With b_v the net basis the live lines brought in under v,
C_<v and C_≤v the net basis of the versions before v and up to v, and C the file's net basis:

    K°  = Σ_v [g_v(C_≤v) - g_v(C_<v)]                  exact: the rates alone, never rounded
    K°_≤v = the same sum over the versions up to v
    top = max(0, max over the versions v with b_v > 0 of (m_v - K°_≤v))
    K   = min(R(K° + top), ⌊C / (1 + τ)⌋)

Each version's minimum is a floor on what the lines up to that version earn, and the lines of
later versions earn their own rates on top (second review: the minimum and the rounding are taken
once on the file, not per version, so a minimum a new version introduces is not waived by the
collections made before it, and a flat-rate change shifts nothing). Inside one version K = F(C).

A run charges each key K(after) - K(charged before): the total charged after any runs is K of the
lines still live, so a reversal gives back exactly what its collection adds to the file (its own
charge when nothing else changed since; priced in its own version, the same encaissement date),
and a file undone in full is back to 0.

* **Event order** (third review): a run takes its lines in the order the events happened —
  (effective date, posted at, entry id), the order runs are cut in — so any split of the same
  events into consecutive runs goes through the same states. The encaissement date only chooses
  the version (a bounce carries its collection's). Under `credit` the order only attributes K to
  the lines; under `keep` it is the order the kept fees are taken in.
* **A collection undone in its own run** under `credit` is taken out with its reversal before
  pricing: both are charged 0 with no parts (they leave K unchanged), so no invoice charges it and
  no band moves twice. The reversal must mirror it (same file and version, minus its basis).
  Under `keep` both are priced: the clause keeps the collection's fee. A kept reversal between
  them still sees the collection live (`transient`), as in any split.
* **Fees kept by the clause** (`on_reversal: keep`, OQ-39): the reversal leaves the tier position
  (net of reversals, design §8.1), so later collections are priced where the undone money was; the
  commission it would have given back is kept (κ) and the minimum per file is charged once:
  K = max(R(K° + top), R(K°) + κ), capped on the gross basis.
* **The rounding reserve** (TTC within what the file brought in across runs): each invoice rounds
  its own VAT, which can add up to ½ cent to a file's share (less than 1 cent after a partial
  credit). What a key is charged, V, is also held within ⌊(C - n) / (1 + τ)⌋, n the key's invoices
  still open once the run's documents are issued — the earlier ones its credits do not take back
  in full, and the run's own invoice when the key has an amount on it. n depends on V (what the
  run charges decides what it credits and invoices): the engine takes the largest V ≤ K whose own
  n holds it, simulating the run's documents for the key (`key_side`, shared with documents.py)
  on the open charges of its earlier invoices. The hold binds only near the cap (the minimum per
  file on a small file), is at most ⌈(n + 1) / (1 + τ)⌉ cents, and is released only by a run in
  which the key has a collection. Across a change of tiered grid an undo can need an invoice of
  its own (a tier regularisation), one more open invoice for the reserve: then it gives back up
  to 1 cent more or less than its collection was charged (otherwise exactly that charge).
* **The hold on the parts**: the difference between V and the parts' sum goes to the key's
  positive parts, last to first, never below 0 (only what they cannot absorb goes to its
  reversals); a release goes to its last positive collection.
* **A change of the VAT rate**: a run with no reversal on a key never takes back what its earlier
  invoices charged at their own rate (V ≥ what was charged before, less only its own collections'
  re-tiering); a run with a reversal re-applies the cap and the reserve at the new rate. Each
  earlier invoice carries its own rate (`OpenCharge.vat_rate`, M2c-4): the reserve weighs what it
  still charges at that rate, so after a fall of the rate the TTC billed stays within the basis.

* **A manual credit note's waiver** (M2c-5b): a manual credit note (`issue_credit_note`, design
  §14.1, risk R2) takes back part of what an invoice charges a (file, tier key) while no line
  changes, so the schedule's commission K is unchanged: that part of the invoice's open charge
  becomes a waiver held on the same (invoice, file, tier key) (`OpenCharge.waived_minor`; the key's
  total `KeyState.waived_minor`). For every key, Σ open charges + Σ waivers = V, the commission
  charged. The waiver is invisible to what the engine charges: V, the cap, the rounding reserve
  and the allocation of credits all read each invoice's charge before the manual credit (its
  capacity: open + waived), so a later collection never re-charges a waived amount and V is what
  it would have been without the manual credit. Only the documents differ: a credit the engine
  allocates to an invoice (its original's first, then LIFO) is absorbed by that invoice's waiver
  for the key first (no credit note for that part: the client already has it), and only the rest
  is credited, so no invoice is credited beyond its remaining HT.
* **After a cancelled run** (M2c-4 C7; M2c-5b review math#0): its corrective invoice of each
  (mandate, VAT rate) charges again what the run credited at that rate and holds, as its waiver,
  what the run's credits absorbed there (where no corrective invoice was issued at a rate, the
  waiver goes back on the invoice it was absorbed from: the file is then exactly as before the
  run). Running a reversal again takes first, on each of those invoices, exactly what the
  cancelled run took for it there per (file, tier key) (`Retake`, a capped link of its chain),
  then its original's own invoice — so a corrective invoice pooling several reversals, or a credit
  that fell on invoices at two rates, gives each reversal its own share in any order: the run
  again gives the documents of the run never approved. (With no corrective invoice at a rate,
  the same history without manual credit notes has one more open invoice than this one: its
  reserve, and under mixed VAT rates its LIFO order, can then differ — review math#1.)

Basis (founder #4): an allocation's 1100 credits per component family, filtered by the schedule's
families; a forward's amount only when the schedule lists its reason; a reversal minus its
original's; advances, returned and unplanned payouts never earn commission. A rule is chosen per
family part, first match on (claim type, family, portfolio); a forward matches only rules that do
not filter on families. An item with no file or no terms in force on its date gets state `none`
(remitted gross; M2c-4 alerts).
"""

from __future__ import annotations

import hashlib
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from datetime import date, datetime
from decimal import Decimal
from enum import StrEnum
from functools import cache
from typing import Literal, NamedTuple, Protocol

from collectoo_worker.remittance.terms import (
    FAMILIES,
    BracketRate,
    CommissionSchedule,
    FlatRate,
    MarginalRate,
    Rule,
)
from collectoo_worker.remittance.vat import RATE_SCALE, scaled

ENGINE_VERSION = "commission-1"
FORWARD_PART = "forward"  # the basis of a forward has no component family
Key = tuple[str, str]  # (file, tier key)


class CommissionInputError(ValueError):
    """Inputs the engine cannot price (a data error: the run keeps the commission pending)."""


class LineKind(StrEnum):
    ALLOCATION = "allocation"
    ALLOCATION_REVERSAL = "allocation_reversal"
    FORWARD = "forward"
    FORWARD_REVERSAL = "forward_reversal"
    CLIENT_ADVANCE = "client_advance"
    CLIENT_ADVANCE_REVERSAL = "client_advance_reversal"  # an advance undone with its cause (M2c-7)
    PAYOUT_RETURNED = "payout_returned"
    UNPLANNED_PAYOUT = "unplanned_payout"


# the reasons a schedule may list in `basis.forwards`; any other forward never earns commission
FORWARD_REASONS = frozenset({"file_recalled", "before_servicing_start", "client_ratification"})
NEVER_COMMISSIONED = frozenset(
    {
        LineKind.CLIENT_ADVANCE,
        LineKind.CLIENT_ADVANCE_REVERSAL,
        LineKind.PAYOUT_RETURNED,
        LineKind.UNPLANNED_PAYOUT,
    }
)
REVERSALS = frozenset({LineKind.ALLOCATION_REVERSAL, LineKind.FORWARD_REVERSAL})


@dataclass(frozen=True)
class FileFacts:
    """A file (account) as the engine sees it; the bracket attributes are fixed at boarding."""

    account_id: str
    mandate_id: str
    claim_type: str
    portfolio_id: str
    boarded_amount_minor: int | None = None
    age_days_at_boarding: int | None = None  # servicing start - oldest due date


@dataclass(frozen=True)
class TermsVersion:
    """A `mandate_terms` version: its schedule prices the lines whose encaissement it covers."""

    id: str
    mandate_id: str
    valid_from: date
    valid_to: date | None  # exclusive
    schedule: CommissionSchedule

    def covers(self, day: date) -> bool:
        return self.valid_from <= day and (self.valid_to is None or day < self.valid_to)


@dataclass(frozen=True)
class Line:
    """An item of the run: one ledger entry that moved the client's 4670 (design §9.1)."""

    entry_id: str
    kind: LineKind
    account_id: str | None
    encaissement_date: date
    effective_date: date
    posted_at: datetime
    amount_minor: int  # the 4670 posting, signed: + owed to the client
    basis: Mapping[str, int] = field(
        default_factory=dict
    )  # per family, signed (a reversal's are ≤ 0)
    forward_reason: str | None = (
        None  # file_recalled | before_servicing_start | client_ratification | …
    )
    original_entry_id: str | None = None  # a reversal: the entry it undoes (its invoice, §8.4)

    def event_key(self) -> tuple[datetime, str]:
        """The order runs are cut in: the posting order of the pending queue (final review). Not the
        encaissement date, which only chooses the version (a bounce carries its collection's date),
        nor the effective date (a payment matched late is posted after a bounce dated before it)."""
        return (self.posted_at, self.entry_id)


@dataclass(frozen=True, slots=True)
class KeyState:
    """What a (file, tier key) holds after the live lines so far: the net basis per terms version
    (the tier positions), the basis and commission kept by `keep` reversals, and the commission
    charged (HT, net of credits: what its invoices' open charges add up to)."""

    basis: tuple[tuple[str, int], ...] = ()  # (terms version id, net basis), by version id
    kept_basis_minor: int = 0
    kept_minor: int = 0  # κ
    commission_minor: int = 0  # V: charged, net of credits (Σ open charges + the waiver)
    # W: what manual credit notes took back from its invoices and no later credit absorbed yet
    waived_minor: int = 0

    @property
    def basis_minor(self) -> int:
        return sum(b for _, b in self.basis)

    @property
    def gross_basis_minor(self) -> int:
        return self.basis_minor + self.kept_basis_minor


class OpenCharge(Protocol):
    """What one earlier invoice still charges a (file, tier key) (`documents.EarlierCharge`)."""

    @property
    def invoice_id(self) -> str: ...

    @property
    def order(self) -> tuple[int, int]: ...  # (year, seq) in the invoice series: LIFO

    @property
    def open_minor(self) -> int: ...

    @property
    def vat_rate(self) -> Decimal | None: ...  # the invoice's own rate (None: the run's)

    @property
    def waived_minor(self) -> int: ...  # taken back by manual credit notes, not yet absorbed


def capacity(charge: OpenCharge) -> int:
    """What an earlier invoice charges a key as the engine sees it: its open charge plus what
    manual credit notes waived on it (its charge net of the engine's own credits only)."""
    return charge.open_minor + charge.waived_minor


@dataclass(frozen=True, slots=True)
class Retake:
    """After a cancelled run (M2c-4 C7; M2c-5b review math#0): an invoice that holds again what the
    cancelled run took for one reversal — its corrective invoice at the VAT rate of the invoices
    the run credited, the credited part as its charge and the absorbed part as its waiver (or,
    where the cancellation issued no corrective invoice at that rate, the invoice whose waiver it
    restored) — and how much per (file, tier key). Running the reversal again takes exactly that
    from it, whatever the other reversals of the run take there: the pooled corrective invoice
    gives each its own share."""

    invoice_id: str
    caps: tuple[tuple[Key, int], ...]  # per (file, tier key), > 0


ChainLink = str | Retake
# an earlier line → the invoices its reversal is credited on first: its own invoice, or (after a
# cancellation) the invoices holding again what the cancelled run took, then the line's own
LineInvoices = Mapping[str, "str | tuple[ChainLink, ...]"]
Preferred = tuple[tuple[str, int | None], ...]  # (invoice, at most that much: None, what it holds)


def chain(found: str | tuple[ChainLink, ...] | None) -> tuple[ChainLink, ...]:
    """The invoices a reversal is credited on first, in order (`line_invoices`' value: one invoice,
    or the invoices a cancellation restored what the run took on, then the original line's own)."""
    if found is None:
        return ()
    return (found,) if isinstance(found, str) else tuple(found)


def preferred_for(found: str | tuple[ChainLink, ...] | None, key: Key) -> Preferred:
    """The chain for one (file, tier key): each invoice with the most the reversal takes there
    first (a `Retake`'s amount for the key; None: what the invoice still holds)."""
    if found is None:
        return ()
    if isinstance(found, str):
        return ((found, None),)
    out: list[tuple[str, int | None]] = []
    for link in found:
        if isinstance(link, str):
            out.append((link, None))
            continue
        for k, cap in link.caps:
            if k == key and cap > 0:
                out.append((link.invoice_id, cap))
    return tuple(out)


@dataclass(frozen=True, slots=True)
class Part:
    """A line's share for one rule: its basis, where it moved the file's cumulative basis, and its
    commission."""

    account_id: str
    tier_key: str
    rule_id: str
    label_fr: str
    families: tuple[str, ...]
    basis_minor: int
    basis_before: int  # the key's net basis (every version) before and after the part
    basis_after: int
    commission_minor: int
    # (rate, basis that moved inside that rate's band of the part's own version): the designation
    tiers: tuple[tuple[str, int], ...]
    minimum_applied: bool  # the file's commission is at a minimum per file
    capped: bool  # held at ⌊C / (1 + τ)⌋ (gross basis)
    held_minor: int = 0  # the key's last part of the run: what the rounding reserve holds back
    # the later versions' segments the part moved, re-tiered (rate, signed basis): a change of terms
    retiering: tuple[tuple[str, int], ...] = ()
    kept: bool = False  # a reversal under `keep`: its own band's fee stays charged


@dataclass(frozen=True, slots=True)
class LineCommission:
    entry_id: str
    kind: LineKind
    account_id: str | None
    mandate_id: str | None
    terms_id: str | None
    state: Literal["charged", "none"]
    reason: str | None  # none: not_commissionable | no_file | no_terms
    commission_minor: int
    parts: tuple[Part, ...]
    original_entry_id: str | None = None


@dataclass(frozen=True)
class RunCommission:
    lines: tuple[LineCommission, ...]  # in the engine's order
    history: dict[tuple[str, str], KeyState]  # (file, tier key) after the run
    inputs_hash: str
    engine_version: str = ENGINE_VERSION


Head = tuple[Line, str | None, str | None, str | None]  # the line, mandate, terms, why nothing
# per (file, tier key): (event index of the collection, of its reversal, terms version, basis)
Transient = dict[Key, list[tuple[int, int, str, int]]]
_UNDOES = {
    LineKind.ALLOCATION_REVERSAL: LineKind.ALLOCATION,
    LineKind.FORWARD_REVERSAL: LineKind.FORWARD,
}


# -- the rate function ----------------------------------------------------------------------------


def cap_of(c: int, vat_rate: Decimal) -> int:
    """⌊c / (1 + τ)⌋: the most HT whose TTC stays within c (exact)."""
    return (c * RATE_SCALE) // (RATE_SCALE + scaled(vat_rate))


def bracket_rate(rate: BracketRate, file: FileFacts) -> str:
    value = (
        file.boarded_amount_minor
        if rate.attribute == "boarded_amount"
        else file.age_days_at_boarding
    )
    if value is None:
        raise CommissionInputError(
            f"file {file.account_id}: no {rate.attribute} for a bracket rule"
        )
    for b in rate.brackets:
        if b.up_to is None or value <= int(b.up_to):  # « jusqu'à » : the bound is included
            return b.rate
    raise CommissionInputError("brackets end with an unbounded one")  # pragma: no cover (validated)


def bands(rule: Rule, file: FileFacts) -> list[tuple[int, int | None, str]]:
    """The rule's rate bands as (lower, upper or None, rate) over the cumulative basis."""
    rate = rule.rate
    if isinstance(rate, FlatRate):
        return [(0, None, rate.rate)]
    if isinstance(rate, MarginalRate):
        out: list[tuple[int, int | None, str]] = []
        lower = 0
        for t in rate.tiers:
            upper = None if t.up_to_minor is None else int(t.up_to_minor)
            out.append((lower, upper, t.rate))
            lower = upper or lower
        return out
    return [(0, None, bracket_rate(rate, file))]


Band = tuple[int, int | None, str, int]  # (lower, upper, rate as written, rate x RATE_SCALE)


@dataclass(frozen=True, slots=True)
class _Priced:
    """A rule as the engine evaluates it for one file: bands with their rates scaled once."""

    rule: Rule
    bands: tuple[Band, ...]
    minimum: int


def _priced(rule: Rule, file: FileFacts) -> _Priced:
    return _Priced(
        rule,
        tuple((lo, up, r, scaled(Decimal(r))) for lo, up, r in bands(rule, file)),
        int(rule.min_per_file_minor or 0),
    )


def _gx(c: int, rule_bands: Sequence[Band]) -> int:
    """g(c) exactly, in minor units x RATE_SCALE: Σ rᵢ · (part of c in band i), c ≥ 0."""
    total = 0
    for lower, upper, _, rate in rule_bands:
        if c <= lower:
            break
        total += ((c if upper is None or c < upper else upper) - lower) * rate
    return total


def _round(x: int) -> int:
    """R: half-up to the cent of an amount in minor units x RATE_SCALE."""
    return (2 * x + RATE_SCALE) // (2 * RATE_SCALE)


def _round_signed(x: int) -> int:
    """R by magnitude (half away from zero): a reversal's band mirrors its collection's."""
    return _round(x) if x >= 0 else -_round(-x)


@cache
def rate_scaled(rate: str) -> int:
    return scaled(Decimal(rate))


def band_amount(moves: Iterable[tuple[str, int]]) -> int:
    """R(Σ rate x base) of signed band moves, by magnitude: what a designation's bands charge."""
    return _round_signed(sum(rate_scaled(r) * b for r, b in moves))


def _f(c: int, p: _Priced, cap_den: int) -> tuple[int, bool, bool]:
    """F(c) inside one version and whether the minimum, then the cap, decided it."""
    if c == 0:
        return 0, False, False
    g = _round(_gx(c, p.bands))
    v = p.minimum if p.minimum > g else g
    cap = c * RATE_SCALE // cap_den
    if v > cap:
        return cap, p.minimum > g, True
    return v, p.minimum > g, False


def rounded_g(c: int, rule_bands: Sequence[tuple[int, int | None, str]]) -> int:
    """R(g(c)) over bands as `bands` gives them."""
    return _round(_gx(c, [(lo, up, r, scaled(Decimal(r))) for lo, up, r in rule_bands]))


def cumulative(c: int, rule: Rule, file: FileFacts, vat_rate: Decimal) -> int:
    """F(c) for one (file, tier key) under one rule, in minor units."""
    if c < 0:
        raise CommissionInputError(f"file {file.account_id}: a negative cumulative basis ({c})")
    return _f(c, _priced(rule, file), RATE_SCALE + scaled(vat_rate))[0]


def _moves(lo: int, hi: int, rule_bands: Sequence[Band], sign: int, out: dict[str, int]) -> None:
    for lower, upper, rate, _ in rule_bands:
        if hi <= lower:
            break
        inside = (hi if upper is None or hi < upper else upper) - (lo if lo > lower else lower)
        if inside > 0:
            out[rate] = out.get(rate, 0) + sign * inside


# -- rules and bases ------------------------------------------------------------------------------


def rule_for(schedule: CommissionSchedule, file: FileFacts, family: str) -> Rule:
    """First rule matching (claim type, family, portfolio); a forward (no family) skips rules
    filtering families."""
    for rule in schedule.rules:
        m = rule.match
        if m.claim_types and file.claim_type not in m.claim_types:
            continue
        if m.portfolio_ids and file.portfolio_id not in m.portfolio_ids:
            continue
        if m.families and (family == FORWARD_PART or family not in m.families):
            continue
        return rule
    raise CommissionInputError("the last rule matches everything")  # pragma: no cover (validated)


def basis_parts(line: Line, schedule: CommissionSchedule) -> list[tuple[str, int]]:
    """The line's commissionable basis as (family, signed amount), in family order. A reversal's
    is minus its original's, under `keep` too (the tier position is net of reversals)."""
    sign = -1 if line.kind in REVERSALS else 1
    if line.kind in (LineKind.FORWARD, LineKind.FORWARD_REVERSAL):
        if line.basis:
            raise CommissionInputError(f"{line.entry_id}: a forward has no component families")
        if sign * line.amount_minor < 0:
            raise CommissionInputError(
                f"{line.entry_id}: a forward is positive, its reversal negative"
            )
        listed = (
            line.forward_reason in FORWARD_REASONS
            and getattr(schedule.basis.forwards, line.forward_reason) is True
        )
        return [(FORWARD_PART, line.amount_minor)] if listed and line.amount_minor else []
    unknown = set(line.basis) - set(FAMILIES)
    if unknown:
        raise CommissionInputError(f"{line.entry_id}: unknown families {sorted(unknown)}")
    families = schedule.basis.families
    out: list[tuple[str, int]] = []
    for family in FAMILIES:
        amount = line.basis.get(family, 0)
        if sign * amount < 0:
            raise CommissionInputError(
                f"{line.entry_id}: an allocation's basis is positive, its reversal's negative"
            )
        if amount and (families == "all" or family in families):
            out.append((family, amount))
    return out


def version_on(versions: Iterable[TermsVersion], day: date) -> TermsVersion | None:
    found = [v for v in versions if v.covers(day)]
    if len(found) > 1:
        raise CommissionInputError(f"terms versions overlap on {day.isoformat()}")
    return found[0] if found else None


# -- a key's documents (shared with documents.py) -------------------------------------------------

REGULARISATION_LABEL_FR = "Régularisation de paliers (changement de conditions)"


@dataclass(frozen=True, slots=True)
class SidePart:
    """A part as a run's documents see it: its line, its commission (after the hold), whether it
    undoes a collection of the same run (a kept reversal: under `credit` such a pair is never
    priced; its regularisation nets in the run), and, for a reversal, the invoice that charged its
    original (credited first)."""

    entry_id: str
    part: Part
    commission_minor: int
    same_run: bool = False
    # the invoices credited first, in order, each up to what it holds or to its cap (what a
    # cancellation restored there for this reversal; then the original line's own invoice)
    preferred: Preferred = ()


@dataclass(slots=True)
class KeySide:
    """What a run's parts put on one (file, tier key)'s documents: the invoice's commission line
    (its own bands) and its tier regularisation line, and the credits allocated to the earlier
    invoices that charged the key (invoice id, HT credited > 0, the line)."""

    commission_minor: int = 0
    tiers: dict[str, int] = field(default_factory=dict)
    families: set[str] = field(default_factory=set)
    rule_id: str = ""
    label_fr: str = ""
    entries: list[str] = field(default_factory=list)
    regularisation_minor: int = 0
    regularisation_entries: list[str] = field(default_factory=list)
    allocations: list[tuple[str, int, str]] = field(default_factory=list)
    # what the waivers of the invoices credited absorb (invoice id, HT > 0, the line): no document
    absorbed: list[tuple[str, int, str]] = field(default_factory=list)

    @property
    def invoiced_minor(self) -> int:
        return self.commission_minor + self.regularisation_minor

    def taken(self) -> dict[str, int]:
        """Per earlier invoice, what the run takes from its capacity (credited or absorbed)."""
        out: dict[str, int] = {}
        for inv, take, _ in (*self.allocations, *self.absorbed):
            out[inv] = out.get(inv, 0) + take
        return out


def _components(p: Part, commission: int) -> tuple[int, int]:
    """A part's commission as (its own band's, the tier regularisation's). The own band is what
    the designation shows with rates (never a negative base); a change of terms re-tiers the later
    versions' collections (242 nonies A 8°: a precise designation, not « 5 % sur -5 000,00 € »)."""
    if p.kept:
        return 0, commission  # the own band's fee is kept: what moves is the later tiers
    if not p.retiering:
        if commission > 0 and p.basis_minor < 0 and any(b < 0 for _, b in p.tiers):
            return 0, commission  # never a negative band on an invoice line
        return commission, 0
    own = band_amount(p.tiers)
    return own, commission - own


def key_side(parts: Sequence[SidePart], earlier: Sequence[OpenCharge]) -> KeySide:
    """Per (file, tier key), in the engine's order (founder #6; CGI 289 I 5, 272 1; design §8.4
    amended): what raises the commission goes to the invoice, what lowers it to the credit note —
    never netted across documents. A credit is allocated first to the invoice that charged the
    collection it undoes (up to what that invoice still charges the key), then LIFO. Only what was
    never invoiced nets inside the run: what a kept reversal of a same-run collection moves (a
    regularisation), and a credit beyond what the earlier invoices charge the key (the run's own
    collections moved the tiers it takes back), netted on the regularisation first. The
    commission line carries only collections' own bands: never a negative base."""
    if len(parts) == 1:  # the usual key of a run: one collection, nothing re-tiered
        sp = parts[0]
        p = sp.part
        if sp.commission_minor > 0 and p.basis_minor > 0 and not p.retiering:
            return KeySide(
                sp.commission_minor,
                dict(p.tiers),
                set(p.families),
                p.rule_id,
                p.label_fr,
                [sp.entry_id],
            )
    side, credits = _place(parts)
    if credits:
        rest = _allocate(side, credits, earlier)
        _absorb(side, earlier)
        if rest:
            take = min(rest, side.regularisation_minor)
            side.regularisation_minor -= take
            rest -= take
            if rest > side.commission_minor:
                first = parts[0].part
                raise CommissionInputError(
                    f"credit on {(first.account_id, first.tier_key)}: earlier invoices and this"
                    f" run charge {rest - side.commission_minor} too little"
                )
            side.commission_minor -= rest
    return side


Credit = tuple[int, Preferred, str]  # (HT > 0, the invoices to credit first, the line)


def _place(parts: Sequence[SidePart]) -> tuple[KeySide, list[Credit]]:
    """Each part's own band and regularisation on the invoice side (raising, or undoing a same-run
    line) or as a credit (amount > 0, the invoices to credit first, the line)."""
    side = KeySide()
    credits: list[Credit] = []
    last = ""  # the last line on the regularisation side
    for sp in parts:
        if not sp.commission_minor:
            continue
        p = sp.part
        own, reg = _components(p, sp.commission_minor)
        if own > 0:  # only a collection's own band: never a negative base (third review)
            side.commission_minor += own
            for rate, base in p.tiers:
                side.tiers[rate] = side.tiers.get(rate, 0) + base
            side.entries.append(sp.entry_id)
        elif own:
            credits.append((-own, sp.preferred, sp.entry_id))
        if reg > 0 or (reg and sp.same_run):  # a kept reversal of a same-run collection nets
            side.regularisation_minor += reg
            last = sp.entry_id
            if reg > 0:
                side.regularisation_entries.append(sp.entry_id)
        elif reg:  # what it re-tiers: a reversal's, on its original's invoice first, else LIFO
            credits.append((-reg, sp.preferred, sp.entry_id))
        if own > 0 or reg > 0:  # the rule and label of the key's last raising part
            side.families.update(p.families)
            side.rule_id, side.label_fr = p.rule_id, p.label_fr
    if side.regularisation_minor < 0:
        credits.append((-side.regularisation_minor, (), last))
        side.regularisation_minor = 0
    return side, credits


def _allocate(side: KeySide, credits: Sequence[Credit], earlier: Sequence[OpenCharge]) -> int:
    """Allocate the credits on the earlier invoices (each up to what it still charges the key, its
    capacity: a manual credit note's waiver included): first every reversal on the invoices that
    charge its original (the one that charges it now first), then what is left of each credit
    LIFO, in the engine's order (so a credit with no original's invoice never takes the one
    another reversal's original was charged on). A capped invoice of the chain (what a cancellation
    restored there for that reversal) gives the line at most its cap, over all its credits on the
    key, so a pooled corrective invoice gives each reversal its own share in any order. Returns
    what the invoices cannot take."""
    lifo = sorted(earlier, key=lambda c: c.order, reverse=True)
    open_ = {c.invoice_id: capacity(c) for c in earlier}
    left = [amount for amount, _, _ in credits]
    caps: dict[tuple[str, str], int] = {}  # (line, invoice) → what its cap still allows
    for n, (_, preferred, entry) in enumerate(credits):
        for inv, cap in preferred:
            if not left[n]:
                break
            available = open_.get(inv, 0)
            if cap is not None:
                allowed = caps.setdefault((entry, inv), cap)
                available = allowed if allowed < available else available
            take = left[n] if left[n] < available else available
            if take > 0:
                side.allocations.append((inv, take, entry))
                open_[inv] -= take
                left[n] -= take
                if cap is not None:
                    caps[(entry, inv)] -= take
    for n, (_, _, entry) in enumerate(credits):
        for ch in lifo:
            if not left[n]:
                break
            available = open_[ch.invoice_id]
            take = left[n] if left[n] < available else available
            if take > 0:
                side.allocations.append((ch.invoice_id, take, entry))
                open_[ch.invoice_id] = available - take
                left[n] -= take
    return sum(left)


def _absorb(side: KeySide, earlier: Sequence[OpenCharge]) -> None:
    """Each invoice's waiver for the key absorbs the takes on it first, in the order they were
    allocated (M2c-5b): what a manual credit note already gave back on that invoice is not credited
    again; only the rest of each take is credited — never beyond the invoice's remaining HT, a take
    never exceeding its capacity."""
    waived = {c.invoice_id: c.waived_minor for c in earlier if c.waived_minor}
    if not waived:
        return
    credited: list[tuple[str, int, str]] = []
    for inv, take, entry in side.allocations:
        w = waived.get(inv, 0)
        a = take if take < w else w
        if a:
            waived[inv] = w - a
            side.absorbed.append((inv, a, entry))
        if take - a:
            credited.append((inv, take - a, entry))
    side.allocations = credited


def open_after(side: KeySide, earlier: Sequence[OpenCharge]) -> int:
    """How many invoices still charge the key once the side is issued (the reserve's n), by
    capacity: a manual credit note's waiver changes nothing the engine charges."""
    taken = side.taken()
    n = sum(1 for c in earlier if capacity(c) - taken.get(c.invoice_id, 0) > 0)
    return n + (1 if side.invoiced_minor > 0 else 0)


# -- the state of a (file, tier key) -------------------------------------------------------------


class _Pricer:
    """Per run, once: the version in force per (mandate, day), the rule per (version, file kind,
    family), the rules of each (mandate, tier key) in version order, their bands priced."""

    def __init__(self, versions: Mapping[str, Sequence[TermsVersion]], vat_rate: Decimal) -> None:
        self.versions = versions
        self.tau = scaled(vat_rate)
        self.cap_den = RATE_SCALE + self.tau
        self.reserve = self.tau > 0  # no VAT, no rounding to reserve for
        self._on: dict[tuple[str, date], TermsVersion | None] = {}
        self._rule: dict[tuple[str, str, str, str], Rule] = {}
        self._seq: dict[tuple[str, str], tuple[tuple[str, Rule], ...]] = {}
        self._priced: dict[tuple[str, str, str], _Priced] = {}

    def version(self, mandate: str, day: date) -> TermsVersion | None:
        k = (mandate, day)
        if k not in self._on:
            self._on[k] = version_on(self.versions.get(mandate, ()), day)
        return self._on[k]

    def rule(self, version: TermsVersion, file: FileFacts, family: str) -> Rule:
        k = (version.id, file.claim_type, file.portfolio_id, family)
        found = self._rule.get(k)
        if found is None:
            found = self._rule[k] = rule_for(version.schedule, file, family)
        return found

    def seq(self, mandate: str, tier_key: str) -> tuple[tuple[str, Rule], ...]:
        """(version id, its rule of that tier key), in version order."""
        found = self._seq.get((mandate, tier_key))
        if found is None:
            out = []
            for v in sorted(self.versions.get(mandate, ()), key=lambda v: v.valid_from):
                rule = next((r for r in v.schedule.rules if r.tier_key == tier_key), None)
                if rule is not None:
                    out.append((v.id, rule))
            found = self._seq[(mandate, tier_key)] = tuple(out)
        return found

    def priced(self, version_id: str, rule: Rule, file: FileFacts) -> _Priced:
        rate = rule.rate
        one = bracket_rate(rate, file) if isinstance(rate, BracketRate) else ""
        key = (version_id, rule.id, one)
        found = self._priced.get(key)
        if found is None:
            found = self._priced[key] = _priced(rule, file)
        return found


@dataclass(slots=True)
class _Key:
    """A (file, tier key) while the run is computed."""

    file: FileFacts
    tier_key: str
    seq: tuple[tuple[str, Rule], ...]
    prices: dict[str, _Priced]
    net: dict[str, int]
    kept_basis: int
    kept: int
    charged_before: int
    earlier: Sequence[OpenCharge]
    waived: int = 0  # W before the run: Σ of its earlier invoices' waivers
    sched_before: int = 0  # the schedule's K of the history's state, at this run's τ
    sched: int = 0  # the schedule's K of the current state
    # its parts in the run: (line index, part index, a collection's, undoes a same-run line,
    # the invoices charging the line a reversal undoes, for this key)
    where: list[tuple[int, int, bool, bool, Preferred]] = field(default_factory=list)
    # the collections of this run undone in it under `credit` (never priced): (event index of the
    # collection, of its reversal, terms version, basis) — live between the two for `keep`
    transient: list[tuple[int, int, str, int]] = field(default_factory=list)


class _Eval(NamedTuple):
    sched: int  # K: with the kept fees, capped on the gross basis
    pre_cap: int  # the same before that cap (`keep` keeps it)
    k: int  # R(K° + top): the rates and the minimums
    k0: int  # R(K°): the rates alone
    minimum: bool
    capped: bool


def _price(key: _Key, vid: str, rule: Rule, pricer: _Pricer) -> _Priced:
    p = key.prices.get(vid)
    if p is None:
        p = key.prices[vid] = pricer.priced(vid, rule, key.file)
    return p


def _result(kx: int, top: int, gross: int, cap_den: int, kept: int) -> _Eval:
    """K from K° and the minimums' top-up (exact), the kept fee and the cap on the gross basis."""
    k0 = _round(kx)
    k = _round(kx + top) if top > 0 else k0
    pre = k if k >= k0 + kept else k0 + kept  # the minimum per file and κ are charged once
    cap = gross * RATE_SCALE // cap_den
    if pre > cap:
        return _Eval(cap, pre, k, k0, k > k0 + kept, True)
    return _Eval(pre, pre, k, k0, k > k0 + kept, False)


def _evaluate(key: _Key, pricer: _Pricer, kept: int | None = None) -> _Eval:
    kept = key.kept if kept is None else kept
    c = kx = top = 0
    for vid, rule in key.seq:
        b = key.net.get(vid, 0)
        if not b:
            continue
        p = key.prices.get(vid) or _price(key, vid, rule, pricer)
        lo, c = c, c + b
        kx += _gx(c, p.bands) - (_gx(lo, p.bands) if lo else 0)
        if p.minimum and p.minimum * RATE_SCALE - kx > top:
            top = p.minimum * RATE_SCALE - kx  # this version's floor on the lines up to it
    return _result(kx, top, c + key.kept_basis, pricer.cap_den, kept)


def _key_of(
    state: KeyState,
    file: FileFacts,
    tier_key: str,
    pricer: _Pricer,
    earlier: Sequence[OpenCharge],
) -> _Key:
    seq = pricer.seq(file.mandate_id, tier_key)
    known = {vid for vid, _ in seq}
    for vid, b in state.basis:
        if vid not in known:
            raise CommissionInputError(
                f"file {file.account_id}: history names terms version {vid} without tier key"
                f" {tier_key}, or a version not given"
            )
        if b < 0:
            raise CommissionInputError(f"file {file.account_id}: a negative cumulative basis ({b})")
    if state.kept_basis_minor < 0 or state.kept_minor < 0 or state.commission_minor < 0:
        raise CommissionInputError(f"file {file.account_id}: a negative kept basis or fee")
    if state.waived_minor < 0 or any(c.waived_minor < 0 for c in earlier):
        raise CommissionInputError(f"file {file.account_id}, {tier_key}: a negative waiver")
    if sum(c.waived_minor for c in earlier) != state.waived_minor:
        raise CommissionInputError(
            f"file {file.account_id}, {tier_key}: its invoices' waivers do not add up to the"
            f" key's ({state.waived_minor})"
        )
    if any(c.open_minor < 0 for c in earlier) or (
        sum(capacity(c) for c in earlier) != state.commission_minor
    ):
        raise CommissionInputError(
            f"file {file.account_id}, {tier_key}: its invoices' open charges and waivers do not add"
            f" up to the commission charged ({state.commission_minor})"
        )
    key = _Key(
        file=file,
        tier_key=tier_key,
        seq=seq,
        prices={},
        net={vid: b for vid, b in state.basis if b},
        kept_basis=state.kept_basis_minor,
        kept=state.kept_minor,
        charged_before=state.commission_minor,
        earlier=earlier,
        waived=state.waived_minor,
    )
    if key.net or key.kept:
        key.sched = key.sched_before = _evaluate(key, pricer).sched
    return key


def schedule_commission(
    state: KeyState,
    file: FileFacts,
    tier_key: str,
    versions: Mapping[str, Sequence[TermsVersion]],
    vat_rate: Decimal,
) -> int:
    """K of a (file, tier key) state before the rounding reserve: what the schedule says the live
    lines earn, however they fell into runs."""
    pricer = _Pricer(versions, vat_rate)
    key = _Key(
        file=file,
        tier_key=tier_key,
        seq=pricer.seq(file.mandate_id, tier_key),
        prices={},
        net={vid: b for vid, b in state.basis if b},
        kept_basis=state.kept_basis_minor,
        kept=state.kept_minor,
        charged_before=state.commission_minor,
        earlier=(),
    )
    return _evaluate(key, pricer).sched if key.net or key.kept else 0


# -- the engine -----------------------------------------------------------------------------------


def compute(  # noqa: PLR0913 - the run's lines, its world and its documents' history
    lines: Sequence[Line],
    files: Mapping[str, FileFacts],
    versions: Mapping[str, Sequence[TermsVersion]],
    history: Mapping[tuple[str, str], KeyState],
    vat_rate: Decimal,
    *,
    charges: Mapping[Key, Sequence[OpenCharge]] | None = None,
    line_invoices: LineInvoices | None = None,
) -> RunCommission:
    """Commission of one run's lines. `versions` per mandate (every version the history names);
    `history` per (file, tier key) from earlier runs; `vat_rate` the rate the run's invoices will
    bear (the cap's τ); `charges` what each earlier invoice still charges each (file, tier key)
    and `line_invoices` the invoice that charged each earlier line — the same history the run's
    documents are drawn from (`documents.run_documents`): the rounding reserve counts the
    invoices that will still be open."""
    ids = [ln.entry_id for ln in lines]
    if len(set(ids)) != len(ids):
        raise CommissionInputError("an entry appears twice in the run")
    charges = charges or {}
    line_invoices = line_invoices or {}
    pricer = _Pricer(versions, vat_rate)
    keys: dict[tuple[str, str], _Key] = {}
    heads: list[Head] = []
    parts: list[list[Part]] = []
    in_run = set(ids)
    order = sorted(lines, key=Line.event_key)
    paired, transient = _same_run_pairs(order, files, pricer)
    for ln in order:
        pair = paired.get(ln.entry_id)
        if pair is not None:  # a collection undone in its own run, under `credit`: never priced
            heads.append(pair)
            parts.append([])
            continue
        reversal = ln.kind in REVERSALS
        same_run = reversal and ln.original_entry_id in in_run
        found = (
            line_invoices.get(ln.original_entry_id)
            if reversal and ln.original_entry_id and not same_run
            else None
        )
        mark = (len(heads), not reversal, same_run, found)
        head, line_parts = _line(ln, files, history, keys, pricer, charges, mark, transient)
        heads.append(head)
        parts.append(line_parts)

    new_history = dict(history)
    for k, key in keys.items():
        charged = _finish(key, pricer, parts, heads)
        new_history[k] = KeyState(
            basis=tuple(sorted((vid, b) for vid, b in key.net.items() if b)),
            kept_basis_minor=key.kept_basis,
            kept_minor=key.kept,
            commission_minor=charged,
            waived_minor=key.waived - _absorbed(key, parts, heads),
        )
    out = []
    for (ln, mandate, terms, reason), ps in zip(heads, parts, strict=True):
        total = 0
        for p in ps:
            total += p.commission_minor
        out.append(
            LineCommission(
                ln.entry_id,
                ln.kind,
                ln.account_id,
                mandate,
                terms,
                "none" if reason else "charged",
                reason,
                total,
                tuple(ps),
                ln.original_entry_id,
            )
        )
    return RunCommission(
        tuple(out),
        new_history,
        inputs_hash(lines, files, versions, history, vat_rate, charges, line_invoices),
    )


def _grouped(
    parts: Iterable[tuple[str, int]], version: TermsVersion, file: FileFacts, pricer: _Pricer
) -> dict[str, tuple[Rule, list[str], int]]:
    """A line's basis parts per rule (rule id → the rule, its families, their basis)."""
    grouped: dict[str, tuple[Rule, list[str], int]] = {}
    for family, amount in parts:
        rule = pricer.rule(version, file, family)
        prev = grouped.get(rule.id)
        if prev is None:
            grouped[rule.id] = (rule, [family], amount)
        else:
            grouped[rule.id] = (rule, [*prev[1], family], prev[2] + amount)
    return grouped


def _same_run_pairs(
    order: Sequence[Line], files: Mapping[str, FileFacts], pricer: _Pricer
) -> tuple[dict[str, Head], Transient]:
    """Under `credit`, a collection and its reversal in the same run leave K unchanged (K is a
    function of the live lines): both are taken out before pricing, charged 0 with no parts, so no
    invoice charges a collection its own run undoes and no band moves twice (third review). Under
    `keep` they are priced (the clause keeps the fee). What such a pair still weighs on is the fee
    a kept reversal between them keeps (a mandate whose clause differs across versions): in any
    split into runs the collection is live then, so its basis is returned per (file, tier key)
    with the event indexes it is live between (`transient`). A reversal must mirror its original:
    the same file and terms version, minus its commissionable basis; an entry is undone once."""
    by_id = {ln.entry_id: ln for ln in order}
    at = {ln.entry_id: i for i, ln in enumerate(order)}
    paired: dict[str, Head] = {}
    transient: Transient = {}
    undone: set[str] = set()
    for rev in order:
        if rev.kind not in REVERSALS or rev.original_entry_id is None:
            continue
        if rev.original_entry_id in undone:
            raise CommissionInputError(f"{rev.original_entry_id}: undone twice in the run")
        undone.add(rev.original_entry_id)
        orig = by_id.get(rev.original_entry_id)
        if orig is None:
            continue
        if orig.kind is not _UNDOES[rev.kind] or orig.account_id != rev.account_id:
            raise CommissionInputError(
                f"{rev.entry_id}: a reversal undoes a {_UNDOES[rev.kind]} of its own file,"
                f" not {orig.entry_id}"
            )
        file = files.get(rev.account_id) if rev.account_id is not None else None
        if file is None:
            continue  # no file: both `none` (or not given: `_line` refuses it)
        version = pricer.version(file.mandate_id, rev.encaissement_date)
        if version is not pricer.version(file.mandate_id, orig.encaissement_date):
            raise CommissionInputError(
                f"{rev.entry_id}: a reversal falls under its original's terms version"
                f" ({orig.entry_id})"
            )
        if version is None or version.schedule.basis.on_reversal != "credit":
            continue
        given = basis_parts(orig, version.schedule)
        if basis_parts(rev, version.schedule) != [(f, -a) for f, a in given]:
            raise CommissionInputError(
                f"{rev.entry_id}: a reversal's basis is minus its original's ({orig.entry_id})"
            )
        for ln in (orig, rev):
            paired[ln.entry_id] = (ln, file.mandate_id, version.id, None)
        for rule, _, amount in _grouped(given, version, file, pricer).values():
            transient.setdefault((file.account_id, rule.tier_key), []).append(
                (at[orig.entry_id], at[rev.entry_id], version.id, amount)
            )
    return paired, transient


def _spread(base: list[int], collection: list[bool], adjust: int) -> list[int]:
    """The parts' commissions once the key's charge differs from the schedule's by `adjust` (the
    hold, its release, a change of τ): taken from the positive parts, last to first, never below
    0, and only what they cannot absorb from the reversals; given to the last positive collection
    (else the last collection), else to the reversals, never above 0."""
    out = list(base)
    if adjust < 0:
        left = -adjust
        for i in range(len(out) - 1, -1, -1):
            if out[i] > 0:
                take = out[i] if out[i] < left else left
                out[i] -= take
                left -= take
                if not left:
                    return out
        rev = [i for i, c in enumerate(collection) if not c]
        out[rev[-1] if rev else -1] -= left
    elif adjust > 0:
        cols = [i for i, c in enumerate(collection) if c]
        pos = [i for i in cols if out[i] > 0]
        if cols:
            out[(pos or cols)[-1]] += adjust
            return out
        left = adjust
        for i in range(len(out) - 1, -1, -1):
            if out[i] < 0:
                give = -out[i] if -out[i] < left else left
                out[i] += give
                left -= give
                if not left:
                    return out
        out[-1] += left
    return out


def _finish(
    key: _Key,
    pricer: _Pricer,
    parts: list[list[Part]],
    heads: Sequence[Head],
) -> int:
    """Charge the key V: the schedule's K within the rounding reserve, for the n its own documents
    leave open; spread the difference over its parts (`_spread`). Returns V.

    A run with no reversal on the key never takes back what earlier invoices charged: V stays at
    least what was charged before, less only what the run's own collections take back by
    re-tiering (third review: after a change of τ the cap and the reserve re-applied at the new
    rate to invoices issued, within the basis, at their own rate; at an unchanged τ this floor
    never binds)."""
    where = key.where
    cb, sched, drift = key.charged_before, key.sched, key.sched - key.sched_before
    hi = sched
    if sched - cb > max(0, drift) and not any(w[2] for w in where):
        hi = cb + max(0, drift)  # a run of reversals only never releases a hold
    floor = cb + min(0, drift) if all(w[2] for w in where) else None
    if floor is not None and hi < floor:
        hi = floor
    base = [parts[i][j].commission_minor for i, j, *_ in where]
    collection = [w[2] for w in where]
    charged = _reserved(key, pricer, parts, heads, (hi, floor, drift), (base, collection))
    held = sched - charged
    if charged - cb == drift and not held:
        return charged  # the parts are the schedule's
    commissions = _spread(base, collection, (charged - cb) - drift)
    for n, ((i, j, *_), m) in enumerate(zip(where, commissions, strict=True)):
        p = parts[i][j]
        last = n == len(where) - 1
        if m != p.commission_minor or (last and held):
            parts[i][j] = replace(p, commission_minor=m, held_minor=max(0, held) if last else 0)
    return charged


def _reserved(  # noqa: PLR0913, PLR0917 - the key, its run, its bounds, its parts
    key: _Key,
    pricer: _Pricer,
    parts: list[list[Part]],
    heads: Sequence[Head],
    bounds: tuple[int, int | None, int],
    spread: tuple[list[int], list[bool]],
) -> int:
    """The largest V ≤ hi that the rounding reserve holds for the n its own documents leave open
    (at least the floor). Each earlier invoice keeps its own VAT rate (M2c-4): after a fall of the
    rate, an invoice still open at a higher one weighs at its own rate, never at the run's, so the
    TTC billed stays within the basis; `top` is the highest rate the key's open documents bear."""
    hi, floor, drift = bounds
    base, collection = spread
    cb, where = key.charged_before, key.where
    c = sum(key.net.values()) + key.kept_basis
    open_before = sum(1 for ch in key.earlier if capacity(ch) > 0)
    rates = {ch.invoice_id: _rate_scaled(ch, pricer.tau) for ch in key.earlier if capacity(ch)}
    top = max(pricer.tau, *rates.values()) if rates else pricer.tau
    mixed = top > pricer.tau
    # V within it holds whatever the rates of the key's invoices: at most one more invoice
    low = (c - open_before - 1) * RATE_SCALE // (RATE_SCALE + top) if c > open_before + 1 else 0
    if not (pricer.reserve or mixed) or hi <= low:
        return hi
    if floor is not None and low < floor:
        low = floor

    def fits(v: int) -> bool:
        commissions = _spread(base, collection, (v - cb) - drift)
        side = key_side(
            [
                SidePart(heads[i][0].entry_id, parts[i][j], m, same, pref)
                for (i, j, _, same, pref), m in zip(where, commissions, strict=True)
            ],
            key.earlier,
        )
        n = open_after(side, key.earlier)
        if not mixed:
            return v <= (c - n) * RATE_SCALE // pricer.cap_den if c > n else v <= 0
        credited = side.taken()
        ttc = side.invoiced_minor * pricer.cap_den + sum(
            (capacity(ch) - credited.get(ch.invoice_id, 0)) * (RATE_SCALE + rates[ch.invoice_id])
            for ch in key.earlier
            if capacity(ch)
        )
        return ttc + n * RATE_SCALE <= c * RATE_SCALE

    if not mixed:
        for v in range(hi, low, -1):  # the largest V that its own documents' n holds
            if fits(v):
                return v
        return low
    if fits(hi):
        return hi
    while hi - low > 1:  # rates differ: the range can be wide, bisect (n moves by one at most)
        mid = (low + hi) // 2
        if fits(mid):
            low = mid
        else:
            hi = mid
    return low


def _absorbed(key: _Key, parts: list[list[Part]], heads: Sequence[Head]) -> int:
    """What the waivers of the key's earlier invoices absorb of its credits in the run, once its
    parts are final: the run's documents for the key (`key_side`, the code documents.py runs on the
    same parts), so the state's waiver and the documents agree."""
    if not key.waived:
        return 0
    side = key_side(
        [
            SidePart(heads[i][0].entry_id, parts[i][j], parts[i][j].commission_minor, same, pref)
            for i, j, _, same, pref in key.where
        ],
        key.earlier,
    )
    return sum(a for _, a, _ in side.absorbed)


def _rate_scaled(charge: OpenCharge, tau: int) -> int:
    """The VAT rate an earlier invoice bears, x RATE_SCALE (None: the run's)."""
    rate = charge.vat_rate
    return tau if rate is None else scaled(rate)


def _line(  # noqa: PLR0913, PLR0917 - a line and the run it is priced in
    line: Line,
    files: Mapping[str, FileFacts],
    history: Mapping[tuple[str, str], KeyState],
    keys: dict[tuple[str, str], _Key],
    pricer: _Pricer,
    charges: Mapping[Key, Sequence[OpenCharge]],
    mark: tuple[int, bool, bool, str | tuple[ChainLink, ...] | None],
    transient: Transient,
) -> tuple[Head, list[Part]]:
    """(the line, its mandate, its terms version, why it earns nothing), and its parts; each key
    it reaches records where its part is (`mark`: the line's event index, a collection's, undoes a
    same-run line, the invoices charging the line it undoes — resolved per key)."""
    if line.kind in NEVER_COMMISSIONED:
        known = files.get(line.account_id) if line.account_id is not None else None
        return (line, known.mandate_id if known else None, None, "not_commissionable"), []
    if line.account_id is None:
        return (line, None, None, "no_file"), []
    file = files.get(line.account_id)
    if file is None:
        raise CommissionInputError(f"{line.entry_id}: file {line.account_id} not given")
    version = pricer.version(file.mandate_id, line.encaissement_date)
    if version is None:
        return (line, file.mandate_id, None, "no_terms"), []
    keep = line.kind in REVERSALS and version.schedule.basis.on_reversal == "keep"
    grouped = _grouped(basis_parts(line, version.schedule), version, file, pricer)

    parts: list[Part] = []
    rules = version.schedule.rules if len(grouped) > 1 else [g[0] for g in grouped.values()]
    for rule in rules:  # rule order: deterministic
        found = grouped.get(rule.id)
        if found is None:
            continue
        _, fams, amount = found
        k = (file.account_id, rule.tier_key)
        key = keys.get(k)
        if key is None:
            key = keys[k] = _key_of(
                history.get(k, KeyState()), file, rule.tier_key, pricer, charges.get(k, ())
            )
            key.transient = transient.get(k, [])
        key.where.append((mark[0], len(parts), mark[1], mark[2], preferred_for(mark[3], k)))
        parts.append(_part(key, version.id, rule, fams, amount, keep, pricer, mark[0]))
    return (line, file.mandate_id, version.id, None), parts


def _part(  # noqa: PLR0913, PLR0917 - one part: its key, version, rule and amount
    key: _Key,
    version_id: str,
    rule: Rule,
    families: list[str],
    amount: int,
    keep: bool,
    pricer: _Pricer,
    at: int,
) -> Part:
    before = key.sched
    if not key.kept_basis and not key.kept and not (keep and amount < 0):
        return _plain_part(key, version_id, rule, families, amount, pricer)
    own, retier = _tier_moves(key, version_id, amount, pricer)
    basis_before = sum(key.net.values())
    if keep and amount < 0:
        # the clause keeps the fee (OQ-39): the basis leaves the tier position, its fee stays —
        # what the reversal would give back at this point of the events, with the collections
        # live then that a later reversal of this run undoes (as in any split into runs)
        live = [(vid, b) for lo, hi, vid, b in key.transient if lo < at < hi]
        for vid, b in live:
            key.net[vid] = key.net.get(vid, 0) + b
        pre = _evaluate(key, pricer).pre_cap
        key.net[version_id] = key.net.get(version_id, 0) + amount
        key.kept_basis -= amount
        k0 = _evaluate(key, pricer, kept=0).k0
        for vid, b in live:
            key.net[vid] -= b
        _add(key, version_id, 0)  # never below 0 without them
        key.kept = max(0, pre - k0)
    else:
        _add(key, version_id, amount)
    after = _evaluate(key, pricer)
    key.sched = after.sched
    return Part(
        key.file.account_id,
        rule.tier_key,
        rule.id,
        rule.label_fr,
        tuple(families),
        amount,
        basis_before,
        basis_before + amount,
        after.sched - before,
        tuple([(r, b) for r, b in own.items() if b]),
        after.minimum,
        after.capped,
        retiering=tuple([(r, b) for r, b in retier.items() if b]),
        kept=keep and amount < 0,
    )


def _plain_part(  # noqa: PLR0913, PLR0917 - as `_part`
    key: _Key, version_id: str, rule: Rule, families: list[str], amount: int, pricer: _Pricer
) -> Part:
    """`_part` with nothing kept, in one pass over the versions: the part moves its own version's
    segment, the later segments shift by its amount (tier moves for the designation), and K° and
    the minimums' top-up are summed over the new segments, then capped on the file's basis."""
    cap_den = pricer.cap_den
    net = key.net
    own: dict[str, int] = {}
    retier: dict[str, int] = {}
    c = kx = top = basis_before = shift = 0
    seen = False
    for vid, r in key.seq:
        b = net.get(vid, 0)
        if vid == version_id:
            seen = True
            p = key.prices.get(vid) or _price(key, vid, r, pricer)
            _shift(c + b, amount, p.bands, 1, own)
            basis_before += b
            b += amount
            if b < 0:
                raise CommissionInputError(
                    f"file {key.file.account_id}: a negative cumulative basis ({b}) under {vid}"
                )
            net[vid] = b
            shift = amount
            if not b:
                continue
        elif not b:
            continue
        else:
            basis_before += b
            p = key.prices.get(vid) or _price(key, vid, r, pricer)
            if shift:  # this later segment moved from [c - shift, c - shift + b]
                _shift(c - shift + b, shift, p.bands, 1, retier)
                _shift(c - shift, shift, p.bands, -1, retier)
        lo, c = c, c + b
        kx += _gx(c, p.bands) - (_gx(lo, p.bands) if lo else 0)
        if p.minimum and p.minimum * RATE_SCALE - kx > top:
            top = p.minimum * RATE_SCALE - kx
    if not seen:  # pragma: no cover (the line's version has the rule of this tier key)
        raise CommissionInputError(f"version {version_id} has no tier key {key.tier_key}")
    after = _result(kx, top, c + key.kept_basis, cap_den, 0)
    before, key.sched = key.sched, after.sched
    return Part(
        key.file.account_id,
        rule.tier_key,
        rule.id,
        rule.label_fr,
        tuple(families),
        amount,
        basis_before,
        basis_before + amount,
        after.sched - before,
        tuple([(t, m) for t, m in own.items() if m]),
        after.minimum,
        after.capped,
        retiering=tuple([(t, m) for t, m in retier.items() if m]),
    )


def _tier_moves(
    key: _Key, version_id: str, amount: int, pricer: _Pricer
) -> tuple[dict[str, int], dict[str, int]]:
    """The basis a part moves inside each rate band (for the designation): its own version's band
    at the top of that version's segment, and the later versions' segments shifted by the amount
    (their tiers continue where the earlier versions end: a re-tiering)."""
    own: dict[str, int] = {}
    retier: dict[str, int] = {}
    lo = 0
    seen = False
    for vid, rule in key.seq:
        b = key.net.get(vid, 0)
        hi = lo + b
        if vid == version_id:
            seen = True
            _shift(hi, amount, _price(key, vid, rule, pricer).bands, 1, own)
        elif seen and b:
            bands_w = _price(key, vid, rule, pricer).bands
            _shift(hi, amount, bands_w, 1, retier)
            _shift(lo, amount, bands_w, -1, retier)
        lo = hi
    return own, retier


def _shift(
    at: int, amount: int, rule_bands: Sequence[Band], sign: int, out: dict[str, int]
) -> None:
    """Add sign x the basis between `at` and `at + amount` (signed) to each band."""
    if amount >= 0:
        _moves(at, at + amount, rule_bands, sign, out)
    else:
        _moves(at + amount, at, rule_bands, -sign, out)


def _add(key: _Key, version_id: str, amount: int) -> None:
    b = key.net.get(version_id, 0) + amount
    if b < 0:
        raise CommissionInputError(
            f"file {key.file.account_id}: a negative cumulative basis ({b}) under {version_id}"
        )
    key.net[version_id] = b


# -- inputs hash ----------------------------------------------------------------------------------


class _Hasher(Protocol):
    def update(self, data: bytes, /) -> None: ...


def _put(h: _Hasher, *fields: str | int | None) -> None:
    """One record: the repr of a tuple of texts, integers and None is unambiguous."""
    h.update(repr(fields).encode())
    h.update(b"\n")


def inputs_hash(  # noqa: PLR0913, PLR0917 - every input of `compute`
    lines: Sequence[Line],
    files: Mapping[str, FileFacts],
    versions: Mapping[str, Sequence[TermsVersion]],
    history: Mapping[tuple[str, str], KeyState],
    vat_rate: Decimal,
    charges: Mapping[Key, Sequence[OpenCharge]] | None = None,
    line_invoices: LineInvoices | None = None,
) -> str:
    """SHA-256 of everything the result depends on (§9.4 `inputs_hash`): the same inputs, in any
    order, give the same hash; amounts as text (no float). Of `line_invoices`, the invoices of the
    lines the run's reversals undo. A waiver (M2c-5b) is named only when there is one, so a history
    without manual credit notes hashes as before."""
    h = hashlib.sha256()
    _put(h, "engine", ENGINE_VERSION, scaled(vat_rate))
    for ln in sorted(lines, key=lambda x: x.entry_id):
        _put(
            h,
            "line",
            ln.entry_id,
            ln.kind.value,
            ln.account_id,
            ln.encaissement_date.isoformat(),
            ln.effective_date.isoformat(),
            ln.posted_at.isoformat(),
            ln.amount_minor,
            ",".join(f"{k}={v}" for k, v in sorted(ln.basis.items()) if v),
            ln.forward_reason,
            ln.original_entry_id,
        )
    for k in sorted(files):
        f = files[k]
        _put(
            h,
            "file",
            k,
            f.mandate_id,
            f.claim_type,
            f.portfolio_id,
            f.boarded_amount_minor,
            f.age_days_at_boarding,
        )
    dumped: dict[int, str] = {}
    for m in sorted(versions):
        for v in sorted(versions[m], key=lambda v: v.id):
            text = dumped.get(id(v.schedule))
            if text is None:
                text = dumped[id(v.schedule)] = v.schedule.model_dump_json(by_alias=True)
            to = None if v.valid_to is None else v.valid_to.isoformat()
            _put(h, "version", m, v.id, v.valid_from.isoformat(), to, text)
    for (account, tier), s in sorted(history.items()):
        waiver = ("waived", s.waived_minor) if s.waived_minor else ()
        _put(
            h,
            "history",
            account,
            tier,
            repr(s.basis),
            s.kept_basis_minor,
            s.kept_minor,
            s.commission_minor,
            *waiver,
        )
    for (account, tier), earlier in sorted((charges or {}).items()):
        for ch in sorted(earlier, key=lambda c: c.invoice_id):
            rate = None if ch.vat_rate is None else scaled(ch.vat_rate)
            waiver = ("waived", ch.waived_minor) if ch.waived_minor else ()
            _put(h, "charge", account, tier, ch.invoice_id, *ch.order, ch.open_minor, rate, *waiver)
    invoices = line_invoices or {}
    for original in sorted({ln.original_entry_id for ln in lines if ln.original_entry_id}):
        found = invoices.get(original)
        _put(h, "line invoice", original, None if found is None else _chain_text(found))
    return h.hexdigest()


def _chain_text(found: str | tuple[ChainLink, ...]) -> str:
    """A chain as text: invoice ids, a `Retake` with its caps per key (« inv[file/tier=cap;…] »)."""
    return ",".join(
        link
        if isinstance(link, str)
        else link.invoice_id + "[" + ";".join(f"{a}/{t}={c}" for (a, t), c in link.caps) + "]"
        for link in chain(found)
    )
