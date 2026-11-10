"""The commission engine `commission-1` (design §8.1, §8.3; founder #4, #5, #6; ADR-0014 M2c-3).

Pure and deterministic: integers in minor units, rates as exact decimals (at most 4 places), one
rounding half-up to the cent per value of the cumulative function. For each (file, tier key) — `c`
the cumulative commissionable basis over the live lines of earlier runs, then this run's lines in
order of (encaissement date, effective date, posted at, entry id):

    g(c) = r·c                              flat
         = Σᵢ rᵢ·max(0, min(c, uᵢ) - lᵢ)     marginal: tiers on what the file brought in
         = r(attribute)·c                   bracket: one rate set by boarded amount or age
    F(c) = 0 if c = 0, else min(max(m, R(g(c))), ⌊c / (1 + τ)⌋)
                                            m = minimum per file, τ = VAT rate
    line = F_v(c_after) - F_v(c_before)     v = the version in force on the encaissement date

Within one version the total of a file is F(Σ basis), however the lines fall into runs
(telescoping): a reversal gives back exactly what F says, across marginal tiers, and a full reversal
brings the file back to 0. Across versions the differences no longer telescope, so the engine keeps
each (file, tier key)'s commission K within [0, ⌊c / (1 + τ)⌋]: never negative (a credit note never
exceeds what was charged) and its TTC never above what the file brought in (the minimum's cap) —
inside one version the bound never binds.

Basis (founder #4): an allocation's 1100 credits per component family, filtered by the schedule's
families; a forward's amount only when the schedule lists its reason; a reversal minus its
original's (zero when the clause keeps the fee, `on_reversal: keep`); advances, returned and
unplanned payouts never earn commission. A rule is chosen per family part, first match on (claim
type, family, portfolio); a forward matches only rules that do not filter on families. An item with
no file or no terms in force on its date gets state `none` (remitted gross; M2c-4 alerts).
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal
from enum import StrEnum
from typing import Literal

from collectoo_worker.remittance.terms import (
    FAMILIES,
    BracketRate,
    CommissionSchedule,
    FlatRate,
    MarginalRate,
    Rule,
)
from collectoo_worker.remittance.vat import RATE_SCALE, div_half_up, scaled

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

    def sort_key(self) -> tuple[date, date, datetime, str]:
        return (self.encaissement_date, self.effective_date, self.posted_at, self.entry_id)


@dataclass(frozen=True)
class KeyState:
    """What a (file, tier key) holds after the live lines so far: basis c and commission K (HT, net
    of credits)."""

    basis_minor: int = 0
    commission_minor: int = 0


@dataclass(frozen=True)
class Part:
    """A line's share for one rule: its basis, where it moved the file's cumulative basis, and its
    commission."""

    account_id: str
    tier_key: str
    rule_id: str
    label_fr: str
    families: tuple[str, ...]
    basis_minor: int
    basis_before: int
    basis_after: int
    commission_minor: int
    tiers: tuple[
        tuple[str, int], ...
    ]  # (rate, basis that moved inside that rate's band), for the designation
    minimum_applied: bool  # F(c_after) is the minimum per file
    capped: bool  # F(c_after) or K is held at ⌊c / (1 + τ)⌋
    clamped: bool  # K kept within [0, ⌊c / (1 + τ)⌋] across versions (never inside one version)


@dataclass(frozen=True)
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


def rounded_g(c: int, rule_bands: Sequence[tuple[int, int | None, str]]) -> int:
    """R(g(c)): Σ rᵢ · (part of c in band i), summed exactly, rounded once half-up."""
    total = 0
    for lower, upper, rate in rule_bands:
        inside = max(0, (c if upper is None else min(c, upper)) - lower)
        total += inside * scaled(Decimal(rate))
    return div_half_up(total, RATE_SCALE)


def cumulative(c: int, rule: Rule, file: FileFacts, vat_rate: Decimal) -> int:
    """F(c) for one (file, tier key) under one rule, in minor units."""
    if c < 0:
        raise CommissionInputError(f"file {file.account_id}: a negative cumulative basis ({c})")
    if c == 0:
        return 0
    m = int(rule.min_per_file_minor or 0)
    return min(max(m, rounded_g(c, bands(rule, file))), cap_of(c, vat_rate))


def _tier_moves(
    before: int, after: int, rule_bands: Sequence[tuple[int, int | None, str]]
) -> tuple[tuple[str, int], ...]:
    lo, hi, sign = (before, after, 1) if after >= before else (after, before, -1)
    out: list[tuple[str, int]] = []
    for lower, upper, rate in rule_bands:
        inside = max(0, (hi if upper is None else min(hi, upper)) - max(lo, lower))
        if inside:
            out.append((rate, sign * inside))
    return tuple(out)


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
    """The line's commissionable basis as (family, signed amount), in family order."""
    reversal = line.kind in REVERSALS
    if reversal and schedule.basis.on_reversal == "keep":
        return []  # the clause keeps the fee: a reversal gives nothing back
    sign = -1 if reversal else 1
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


# -- the engine -----------------------------------------------------------------------------------


def compute(
    lines: Sequence[Line],
    files: Mapping[str, FileFacts],
    versions: Mapping[str, Sequence[TermsVersion]],
    history: Mapping[tuple[str, str], KeyState],
    vat_rate: Decimal,
) -> RunCommission:
    """Commission of one run's lines. `versions` per mandate; `history` per (file, tier key) from
    earlier runs' live, charged lines; `vat_rate` the rate the run's invoices will bear (the cap's
    τ)."""
    ids = [ln.entry_id for ln in lines]
    if len(set(ids)) != len(ids):
        raise CommissionInputError("an entry appears twice in the run")
    state = dict(history)
    out = [_line(ln, files, versions, state, vat_rate) for ln in sorted(lines, key=Line.sort_key)]
    return RunCommission(tuple(out), state, inputs_hash(lines, files, versions, history, vat_rate))


def _line(
    line: Line,
    files: Mapping[str, FileFacts],
    versions: Mapping[str, Sequence[TermsVersion]],
    state: dict[tuple[str, str], KeyState],
    vat_rate: Decimal,
) -> LineCommission:
    def none(reason: str, mandate: str | None = None) -> LineCommission:
        return LineCommission(
            line.entry_id, line.kind, line.account_id, mandate, None, "none", reason, 0, ()
        )

    if line.kind in NEVER_COMMISSIONED:
        known = files.get(line.account_id) if line.account_id is not None else None
        return none("not_commissionable", known.mandate_id if known else None)
    if line.account_id is None:
        return none("no_file")
    file = files.get(line.account_id)
    if file is None:
        raise CommissionInputError(f"{line.entry_id}: file {line.account_id} not given")
    version = version_on(versions.get(file.mandate_id, ()), line.encaissement_date)
    if version is None:
        return none("no_terms", file.mandate_id)

    grouped: dict[str, tuple[Rule, list[str], int]] = {}
    for family, amount in basis_parts(line, version.schedule):
        rule = rule_for(version.schedule, file, family)
        prev = grouped.get(rule.id)
        fams = [*prev[1], family] if prev else [family]
        grouped[rule.id] = (rule, fams, (prev[2] if prev else 0) + amount)

    parts = []
    for rule in version.schedule.rules:  # rule order: deterministic
        if rule.id not in grouped:
            continue
        _, fams, amount = grouped[rule.id]
        key = (file.account_id, rule.tier_key)
        before = state.get(key, KeyState())
        c0, c1 = before.basis_minor, before.basis_minor + amount
        f1 = cumulative(c1, rule, file, vat_rate)
        raw = f1 - cumulative(c0, rule, file, vat_rate)
        cap = cap_of(c1, vat_rate)
        k1 = min(max(before.commission_minor + raw, 0), cap)
        state[key] = KeyState(c1, k1)
        m = int(rule.min_per_file_minor or 0)
        rule_bands = bands(rule, file)
        g1 = rounded_g(c1, rule_bands)
        parts.append(
            Part(
                account_id=file.account_id,
                tier_key=rule.tier_key,
                rule_id=rule.id,
                label_fr=rule.label_fr,
                families=tuple(fams),
                basis_minor=amount,
                basis_before=c0,
                basis_after=c1,
                commission_minor=k1 - before.commission_minor,
                tiers=_tier_moves(c0, c1, rule_bands),
                minimum_applied=c1 > 0 and m > g1 and f1 == m,
                capped=c1 > 0 and k1 == cap and k1 < max(m, g1),
                clamped=k1 != before.commission_minor + raw,
            )
        )
    return LineCommission(
        line.entry_id,
        line.kind,
        line.account_id,
        file.mandate_id,
        version.id,
        "charged",
        None,
        sum(p.commission_minor for p in parts),
        tuple(parts),
    )


# -- inputs hash ----------------------------------------------------------------------------------


def _canonical(obj: object) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def inputs_hash(
    lines: Sequence[Line],
    files: Mapping[str, FileFacts],
    versions: Mapping[str, Sequence[TermsVersion]],
    history: Mapping[tuple[str, str], KeyState],
    vat_rate: Decimal,
) -> str:
    """SHA-256 of everything the result depends on (§9.4 `inputs_hash`): the same inputs, in any
    order, give the same hash; amounts as text (no float)."""
    doc = {
        "engine": ENGINE_VERSION,
        "vat_rate": str(scaled(vat_rate)),
        "lines": sorted(
            (
                {
                    "entry": ln.entry_id,
                    "kind": str(ln.kind),
                    "file": ln.account_id,
                    "e": ln.encaissement_date.isoformat(),
                    "eff": ln.effective_date.isoformat(),
                    "at": ln.posted_at.isoformat(),
                    "amount": str(ln.amount_minor),
                    "basis": {k: str(v) for k, v in sorted(ln.basis.items()) if v},
                    "forward": ln.forward_reason,
                }
                for ln in lines
            ),
            key=lambda d: str(d["entry"]),
        ),
        "files": {
            k: {
                "mandate": f.mandate_id,
                "claim_type": f.claim_type,
                "portfolio": f.portfolio_id,
                "boarded": None if f.boarded_amount_minor is None else str(f.boarded_amount_minor),
                "age": None if f.age_days_at_boarding is None else str(f.age_days_at_boarding),
            }
            for k, f in files.items()
        },
        "versions": {
            m: sorted(
                (
                    {
                        "id": v.id,
                        "from": v.valid_from.isoformat(),
                        "to": None if v.valid_to is None else v.valid_to.isoformat(),
                        "schedule": v.schedule.model_dump(mode="json", by_alias=True),
                    }
                    for v in vs
                ),
                key=lambda d: str(d["id"]),
            )
            for m, vs in versions.items()
        },
        "history": sorted(
            [k[0], k[1], str(s.basis_minor), str(s.commission_minor)] for k, s in history.items()
        ),
    }
    return hashlib.sha256(_canonical(doc).encode("utf-8")).hexdigest()
