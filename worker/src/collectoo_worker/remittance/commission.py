"""The commission engine `commission-1` (design §8.1, §8.3; founder #4, #5, #6; ADR-0014 M2c-3).

Pure and deterministic: integers in minor units, rates as exact decimals (at most 4 places), one
rounding half-up to the cent per value of a cumulative function. Per version v of the terms and per
(file, tier key), the design's cumulative function:

    g(c)   = r·c                              flat
           = Σᵢ rᵢ·max(0, min(c, uᵢ) - lᵢ)     marginal: tiers on what the file brought in
           = r(attribute)·c                   bracket: one rate set by boarded amount or age
    F_v(c) = 0 if c = 0, else min(max(m, R(g(c))), ⌊c / (1 + τ)⌋)     m = minimum per file, τ = VAT

The commission of a (file, tier key) is a function of its live lines only, never of how they fell
into runs (the review fix of 2026-11-10): the live lines in order of encaissement date, each priced
by the version in force on its date (founder #5: new rates only for the future), each version's
tiers continuing where the earlier versions' net basis ends (the tier key is stable across
versions). Versions never overlap, so the lines of one version are consecutive in that order and
their F_v differences telescope; with b_v the net basis the live lines brought in under v and
C_<v, C_≤v the net basis of the versions before v and up to v:

    K° = Σ_v [F_v(C_≤v) - F_v(C_<v)]            the design's « F_v(after) - F_v(before) » per line
    K  = min(K° (+ fees kept, below), ⌊C / (1 + τ)⌋)    never more, TTC, than the file brought in

A run charges each key K(after) - K(charged before): the total charged after any runs is K of the
lines still live, so a reversal gives back exactly what its collection adds to the file (its own
charge when nothing else changed since; priced in its own version, the same encaissement date),
and a file undone in full is back to 0. Inside one version K = F(Σ basis) (telescoping).

* **Fees kept by the clause** (`on_reversal: keep`, OQ-39): the reversal leaves the tier position
  (net of reversals, design §8.1), so later collections are priced where the undone money was; the
  commission it would have given back is kept (κ) and the minimum per file is charged once
  (K = K° + max(0, κ - the minimum's top-up in K°), capped on the gross basis).
* **The rounding reserve** (TTC within what the file brought in across runs, review fix): each
  invoice rounds its own VAT, which can add up to ½ cent to a file's share (less than 1 cent after a
  partial credit). K is also held within ⌊(C - n) / (1 + τ)⌋, n the key's invoices still open after
  the run: then the file's open HT plus its pro-rata share of those invoices' VAT never exceeds C.
  The hold binds only near the cap (the minimum per file on a small file) and is released as soon
  as the file's basis leaves room; it is the only place where runs matter, by at most ⌈n / (1+τ)⌉.

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
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal
from enum import StrEnum
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


class CommissionInputError(ValueError):
    """Inputs the engine cannot price (a data error: the run keeps the commission pending)."""


class LineKind(StrEnum):
    ALLOCATION = "allocation"
    ALLOCATION_REVERSAL = "allocation_reversal"
    FORWARD = "forward"
    FORWARD_REVERSAL = "forward_reversal"
    CLIENT_ADVANCE = "client_advance"
    PAYOUT_RETURNED = "payout_returned"
    UNPLANNED_PAYOUT = "unplanned_payout"


# the reasons a schedule may list in `basis.forwards`; any other forward never earns commission
FORWARD_REASONS = frozenset({"file_recalled", "before_servicing_start", "client_ratification"})
NEVER_COMMISSIONED = frozenset(
    {LineKind.CLIENT_ADVANCE, LineKind.PAYOUT_RETURNED, LineKind.UNPLANNED_PAYOUT}
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

    def sort_key(self) -> tuple[date, date, datetime, str]:
        return (self.encaissement_date, self.effective_date, self.posted_at, self.entry_id)


@dataclass(frozen=True, slots=True)
class KeyState:
    """What a (file, tier key) holds after the live lines so far: the net basis per terms version
    (the tier positions), the basis and commission kept by `keep` reversals, the commission K
    charged (HT, net of credits) and how many of its invoices still have a charge open."""

    basis: tuple[tuple[str, int], ...] = ()  # (terms version id, net basis), by version id
    kept_basis_minor: int = 0
    kept_minor: int = 0  # κ
    commission_minor: int = 0  # K charged
    # the rounding reserve's n: the engine returns what it reserved for (the invoices open before
    # the run, and the run's own); the caller sets the real count once the documents are issued
    # (`documents.open_invoices`; M2c-4: from the invoices' open charges)
    open_invoices: int = 0

    @property
    def basis_minor(self) -> int:
        return sum(b for _, b in self.basis)

    @property
    def gross_basis_minor(self) -> int:
        return self.basis_minor + self.kept_basis_minor


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
    tiers: tuple[
        tuple[str, int], ...
    ]  # (rate, basis that moved inside that rate's band), for the designation
    minimum_applied: bool  # a version's F is at its minimum per file
    capped: bool  # held at ⌊c / (1 + τ)⌋ (a version's F, or the file's total)
    held_minor: int = 0  # the key's last part of the run: what the rounding reserve holds back


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


# -- the cumulative function ----------------------------------------------------------------------


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


def _g(c: int, rule_bands: Sequence[Band]) -> int:
    """R(g(c)): Σ rᵢ · (part of c in band i), summed exactly, rounded once half-up (c ≥ 0)."""
    total = 0
    for lower, upper, _, rate in rule_bands:
        if c <= lower:
            break
        total += ((c if upper is None or c < upper else upper) - lower) * rate
    return (2 * total + RATE_SCALE) // (2 * RATE_SCALE)


def _f(c: int, p: _Priced, cap_den: int, minimum: bool = True) -> tuple[int, bool, bool]:
    """F(c) and whether the minimum, then the cap, decided it."""
    if c == 0:
        return 0, False, False
    g = _g(c, p.bands)
    m = p.minimum if minimum else 0
    v = m if m > g else g
    cap = c * RATE_SCALE // cap_den
    if v > cap:
        return cap, m > g, True
    return v, m > g, False


def rounded_g(c: int, rule_bands: Sequence[tuple[int, int | None, str]]) -> int:
    """R(g(c)) over bands as `bands` gives them."""
    return _g(c, [(lo, up, r, scaled(Decimal(r))) for lo, up, r in rule_bands])


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


# -- the state of a (file, tier key) -------------------------------------------------------------


class _Pricer:
    """Per run, once: the version in force per (mandate, day), the rule per (version, file kind,
    family), the rules of each (mandate, tier key) in version order, their bands priced."""

    def __init__(self, versions: Mapping[str, Sequence[TermsVersion]], vat_rate: Decimal) -> None:
        self.versions = versions
        self.cap_den = RATE_SCALE + scaled(vat_rate)
        self.reserve = scaled(vat_rate) > 0  # no VAT, no rounding to reserve for
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
    open_before: int
    sched_before: int = 0  # the schedule's K of the history's state, at this run's τ
    sched: int = 0  # the schedule's K of the current state
    last_part: tuple[int, int] | None = None  # (line index, part index) that takes the hold
    last_positive: tuple[int, int] | None = None
    positive: bool = False


class _Eval(NamedTuple):
    sched: int  # K: with the kept fees, capped on the gross basis
    pre_cap: int  # the same before that cap (`keep` keeps it)
    k: int  # K° (net positions, minimums)
    k0: int  # K° with no minimum (only when fees are kept)
    minimum: bool
    capped: bool


def _price(key: _Key, vid: str, rule: Rule, pricer: _Pricer) -> _Priced:
    p = key.prices.get(vid)
    if p is None:
        p = key.prices[vid] = pricer.priced(vid, rule, key.file)
    return p


def _evaluate(key: _Key, pricer: _Pricer, kept: int | None = None, nomin: bool = False) -> _Eval:
    cap_den = pricer.cap_den
    kept = key.kept if kept is None else kept
    nomin = nomin or kept > 0
    c = k = k0 = 0
    minimum = capped = False
    net = key.net
    for vid, rule in key.seq:
        b = net.get(vid, 0)
        if not b:
            continue
        p = key.prices.get(vid) or _price(key, vid, rule, pricer)
        lo, c = c, c + b
        hi, mn, cp = _f(c, p, cap_den)
        k += hi - _f(lo, p, cap_den)[0] if lo else hi
        minimum |= mn
        capped |= cp
        if nomin:
            k0 += _f(c, p, cap_den, minimum=False)[0] - _f(lo, p, cap_den, minimum=False)[0]
    top = k - k0 if nomin and k > k0 else 0
    pre = k + (kept - top if kept > top else 0)
    cap = (c + key.kept_basis) * RATE_SCALE // cap_den
    if pre > cap:
        return _Eval(cap, pre, k, k0, minimum, True)
    return _Eval(pre, pre, k, k0, minimum, capped)


def _key_of(state: KeyState, file: FileFacts, tier_key: str, pricer: _Pricer) -> _Key:
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
    if state.kept_basis_minor < 0 or state.kept_minor < 0 or state.open_invoices < 0:
        raise CommissionInputError(f"file {file.account_id}: a negative kept basis or fee")
    key = _Key(
        file=file,
        tier_key=tier_key,
        seq=seq,
        prices={},
        net={vid: b for vid, b in state.basis if b},
        kept_basis=state.kept_basis_minor,
        kept=state.kept_minor,
        charged_before=state.commission_minor,
        open_before=state.open_invoices,
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
    return _key_of(state, file, tier_key, pricer).sched


# -- the engine -----------------------------------------------------------------------------------


def compute(
    lines: Sequence[Line],
    files: Mapping[str, FileFacts],
    versions: Mapping[str, Sequence[TermsVersion]],
    history: Mapping[tuple[str, str], KeyState],
    vat_rate: Decimal,
) -> RunCommission:
    """Commission of one run's lines. `versions` per mandate (every version the history names);
    `history` per (file, tier key) from earlier runs; `vat_rate` the rate the run's invoices will
    bear (the cap's τ)."""
    ids = [ln.entry_id for ln in lines]
    if len(set(ids)) != len(ids):
        raise CommissionInputError("an entry appears twice in the run")
    pricer = _Pricer(versions, vat_rate)
    keys: dict[tuple[str, str], _Key] = {}
    heads: list[tuple[Line, str | None, str | None, str | None]] = []
    parts: list[list[Part]] = []
    for ln in sorted(lines, key=Line.sort_key):
        head, line_parts = _line(ln, len(heads), files, history, keys, pricer)
        heads.append(head)
        parts.append(line_parts)

    new_history = dict(history)
    for k, key in keys.items():
        held = _finish(key, pricer, parts)
        new_history[k] = KeyState(
            basis=tuple(sorted((vid, b) for vid, b in key.net.items() if b)),
            kept_basis_minor=key.kept_basis,
            kept_minor=key.kept,
            commission_minor=key.sched - held,
            open_invoices=key.open_before + (1 if key.positive else 0),
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
        tuple(out), new_history, inputs_hash(lines, files, versions, history, vat_rate)
    )


def _finish(key: _Key, pricer: _Pricer, parts: list[list[Part]]) -> int:
    """Charge the key K(after) within the rounding reserve; the difference with the parts' sum
    (the hold, or a change of τ since the last run) goes to its last positive part, else its last
    part. Returns the hold."""
    c = sum(key.net.values()) + key.kept_basis
    n = key.open_before + (1 if key.positive else 0) if pricer.reserve else 0
    reserve = (c - n) * RATE_SCALE // pricer.cap_den if c > n else 0
    charged = key.sched if key.sched <= reserve else reserve
    adjust = (charged - key.charged_before) - (key.sched - key.sched_before)
    held = key.sched - charged
    where = key.last_positive or key.last_part
    if where is not None and (adjust or held):
        i, j = where
        p = parts[i][j]
        parts[i][j] = Part(
            p.account_id,
            p.tier_key,
            p.rule_id,
            p.label_fr,
            p.families,
            p.basis_minor,
            p.basis_before,
            p.basis_after,
            p.commission_minor + adjust,
            p.tiers,
            p.minimum_applied,
            p.capped,
            held,
        )
    return held


def _line(  # noqa: PLR0913, PLR0917 - a line and the run it is priced in
    line: Line,
    index: int,
    files: Mapping[str, FileFacts],
    history: Mapping[tuple[str, str], KeyState],
    keys: dict[tuple[str, str], _Key],
    pricer: _Pricer,
) -> tuple[tuple[Line, str | None, str | None, str | None], list[Part]]:
    """(the line, its mandate, its terms version, why it earns nothing), and its parts."""
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

    grouped: dict[str, tuple[Rule, list[str], int]] = {}
    for family, amount in basis_parts(line, version.schedule):
        rule = pricer.rule(version, file, family)
        prev = grouped.get(rule.id)
        if prev is None:
            grouped[rule.id] = (rule, [family], amount)
        else:
            grouped[rule.id] = (rule, [*prev[1], family], prev[2] + amount)

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
            key = keys[k] = _key_of(history.get(k, KeyState()), file, rule.tier_key, pricer)
        part = _part(key, version.id, rule, fams, amount, keep, pricer)
        parts.append(part)
        key.last_part = (index, len(parts) - 1)
        if part.commission_minor > 0:
            key.positive = True
            key.last_positive = key.last_part
        elif key.sched_before > key.charged_before:
            key.positive = True  # catching up a hold: an invoice charge
    return (line, file.mandate_id, version.id, None), parts


def _part(  # noqa: PLR0913, PLR0917 - one part: its key, version, rule and amount
    key: _Key,
    version_id: str,
    rule: Rule,
    families: list[str],
    amount: int,
    keep: bool,
    pricer: _Pricer,
) -> Part:
    before = key.sched
    if not key.kept_basis and not key.kept and not (keep and amount < 0):
        return _plain_part(key, version_id, rule, families, amount, pricer)
    tiers = _tier_moves(key, version_id, amount, pricer)
    basis_before = sum(key.net.values())
    if keep and amount < 0:
        # the clause keeps the fee (OQ-39): the basis leaves the tier position, its fee stays
        pre = _evaluate(key, pricer, nomin=True).pre_cap
        _add(key, version_id, amount)
        key.kept_basis -= amount
        moved = _evaluate(key, pricer, kept=0, nomin=True)
        top = moved.k - moved.k0 if moved.k > moved.k0 else 0
        key.kept = max(0, pre - moved.k + top)
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
        tuple([(r, b) for r, b in tiers.items() if b]),
        after.minimum,
        after.capped,
    )


def _plain_part(  # noqa: PLR0913, PLR0917 - as `_part`
    key: _Key, version_id: str, rule: Rule, families: list[str], amount: int, pricer: _Pricer
) -> Part:
    """`_part` with nothing kept, in one pass over the versions: the part moves its own version's
    segment, the later segments shift by its amount (tier moves for the designation), and K° is
    summed over the new segments, then capped on the file's basis."""
    cap_den = pricer.cap_den
    net = key.net
    tiers: dict[str, int] = {}
    c = k = basis_before = shift = 0
    minimum = capped = seen = False
    for vid, r in key.seq:
        b = net.get(vid, 0)
        if vid == version_id:
            seen = True
            p = key.prices.get(vid) or _price(key, vid, r, pricer)
            _shift(c + b, amount, p.bands, 1, tiers)
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
                _shift(c - shift + b, shift, p.bands, 1, tiers)
                _shift(c - shift, shift, p.bands, -1, tiers)
        lo, c = c, c + b
        hi, mn, cp = _f(c, p, cap_den)
        k += hi - _f(lo, p, cap_den)[0] if lo else hi
        minimum |= mn
        capped |= cp
    if not seen:  # pragma: no cover (the line's version has the rule of this tier key)
        raise CommissionInputError(f"version {version_id} has no tier key {key.tier_key}")
    cap = c * RATE_SCALE // cap_den
    if k > cap:
        k, capped = cap, True
    before, key.sched = key.sched, k
    return Part(
        key.file.account_id,
        rule.tier_key,
        rule.id,
        rule.label_fr,
        tuple(families),
        amount,
        basis_before,
        basis_before + amount,
        k - before,
        tuple([(t, m) for t, m in tiers.items() if m]),
        minimum,
        capped,
    )


def _tier_moves(key: _Key, version_id: str, amount: int, pricer: _Pricer) -> dict[str, int]:
    """The basis a part moves inside each rate band (for the designation): its own version's
    band at the top of that version's segment, and the later versions' segments shifted by the
    amount (their tiers continue where the earlier versions end)."""
    tiers: dict[str, int] = {}
    lo = 0
    seen = False
    for vid, rule in key.seq:
        b = key.net.get(vid, 0)
        hi = lo + b
        if vid == version_id:
            seen = True
            _shift(hi, amount, _price(key, vid, rule, pricer).bands, 1, tiers)
        elif seen and b:
            bands_w = _price(key, vid, rule, pricer).bands
            _shift(hi, amount, bands_w, 1, tiers)
            _shift(lo, amount, bands_w, -1, tiers)
        lo = hi
    return tiers


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


def inputs_hash(
    lines: Sequence[Line],
    files: Mapping[str, FileFacts],
    versions: Mapping[str, Sequence[TermsVersion]],
    history: Mapping[tuple[str, str], KeyState],
    vat_rate: Decimal,
) -> str:
    """SHA-256 of everything the result depends on (§9.4 `inputs_hash`): the same inputs, in any
    order, give the same hash; amounts as text (no float)."""
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
        _put(
            h,
            "history",
            account,
            tier,
            repr(s.basis),
            s.kept_basis_minor,
            s.kept_minor,
            s.commission_minor,
            s.open_invoices,
        )
    return h.hexdigest()
