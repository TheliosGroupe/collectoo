"""The commission engine `commission-1` (design §8.3, §8.4, §18 M2-13): Hypothesis properties and
the input errors.

* telescoping: inside one version, Σ line commissions of a file = F(Σ basis), however the lines fall
  into runs and whatever order they are given in; a full reversal brings the file back to 0;
* F monotone; the commission's TTC within what the file brought in (the minimum's cap);
* across versions: each (file, tier key) keeps 0 ≤ K ≤ ⌊c / (1 + τ)⌋, a full reversal gives
  everything back;
* documents: credit notes never exceed what an invoice charged per (file, tier key); credit-note VAT
  ≤ the invoice's VAT and equal to it on a full credit; Σ open charges = K;
* the inputs hash: the same inputs in any order give the same hash, any change another.
"""

from __future__ import annotations

import random
from collections import defaultdict
from dataclasses import replace
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from itertools import pairwise
from typing import Any

import pytest
from commission_cases import Simulator
from hypothesis import given, settings
from hypothesis import strategies as st

from collectoo_worker.remittance.commission import (
    CommissionInputError,
    FileFacts,
    KeyState,
    Line,
    LineKind,
    TermsVersion,
    cap_of,
    compute,
    cumulative,
    inputs_hash,
)
from collectoo_worker.remittance.terms import CommissionSchedule
from collectoo_worker.remittance.vat import vat_of

TAU = Decimal("0.2")
BASIS = {
    "families": "all",
    "forwards": {
        "file_recalled": False,
        "before_servicing_start": False,
        "client_ratification": False,
    },
    "on_reversal": "credit",
}
D0 = date(2026, 1, 5)


def rate_text(n: int) -> str:
    return "1" if n == 10_000 else f"0.{n:04d}"


@st.composite
def rate_docs(draw: st.DrawFn) -> dict[str, Any]:
    kind = draw(st.sampled_from(["flat", "marginal", "bracket"]))
    rate = st.integers(0, 10_000).map(rate_text)
    if kind == "flat":
        return {"kind": "flat", "rate": draw(rate)}
    bounds = sorted(draw(st.sets(st.integers(1, 2_000_000), min_size=0, max_size=3)))
    bands: list[str | None] = [str(b) for b in bounds]
    bands.append(None)
    if kind == "marginal":
        return {
            "kind": "marginal",
            "tiers": [{"up_to_minor": b, "rate": draw(rate)} for b in bands],
        }
    return {
        "kind": "bracket",
        "attribute": "boarded_amount",
        "brackets": [{"up_to": b, "rate": draw(rate)} for b in bands],
    }


@st.composite
def schedules(draw: st.DrawFn, tier_key: str = "k") -> CommissionSchedule:
    rule: dict[str, Any] = {
        "id": "r",
        "tier_key": tier_key,
        "label_fr": "Règle",
        "match": {},
        "rate": draw(rate_docs()),
    }
    if draw(st.booleans()):
        rule["min_per_file_minor"] = str(draw(st.integers(0, 50_000)))
    return CommissionSchedule.model_validate(
        {"schema": "commission-1", "basis": BASIS, "rules": [rule]}
    )


def _file(boarded: int = 300_000) -> FileFacts:
    return FileFacts("F", "M", "b2b_invoice", "P", boarded_amount_minor=boarded)


def _line(n: int, amount: int, e: date, *, reversal: bool = False) -> Line:
    eff = e + timedelta(days=40 if reversal else 0)
    return Line(
        entry_id=f"{'R' if reversal else 'A'}{n:05d}",
        kind=LineKind.ALLOCATION_REVERSAL if reversal else LineKind.ALLOCATION,
        account_id="F",
        encaissement_date=e,
        effective_date=eff,
        posted_at=datetime(eff.year, eff.month, eff.day, 12, tzinfo=UTC) + timedelta(seconds=n),
        amount_minor=-amount if reversal else amount,
        basis={"principal": -amount if reversal else amount},
    )


@st.composite
def histories(draw: st.DrawFn, max_ops: int = 25) -> list[Line]:
    """Collections and full reversals of earlier collections, each reversal after its original."""
    lines: list[Line] = []
    live: list[Line] = []
    for n in range(draw(st.integers(1, max_ops))):
        if live and draw(st.integers(0, 3)) == 0:
            original = live.pop(draw(st.integers(0, len(live) - 1)))
            lines.append(_line(n, original.amount_minor, original.encaissement_date, reversal=True))
        else:
            amount = draw(st.integers(1, 1_000_000))
            e = D0 + timedelta(days=draw(st.integers(0, 300)))
            ln = _line(n, amount, e)
            lines.append(ln)
            live.append(ln)
    return lines


def _runs(lines: list[Line], cuts: list[int]) -> list[list[Line]]:
    """Split lines (in creation order) into consecutive runs: every reversal lands in its original's
    run or later."""
    points = sorted({c % (len(lines) + 1) for c in cuts} | {0, len(lines)})
    return [lines[a:b] for a, b in pairwise(points) if b > a]


def _one_version(schedule: CommissionSchedule) -> dict[str, list[TermsVersion]]:
    return {"M": [TermsVersion("v", "M", date(2026, 1, 1), None, schedule)]}


@settings(max_examples=300, deadline=None)
@given(
    schedule=schedules(),
    lines=histories(),
    cuts=st.lists(st.integers(0, 50), max_size=6),
    boarded=st.integers(0, 3_000_000),
)
def test_telescoping_whatever_the_split_into_runs(
    schedule: CommissionSchedule, lines: list[Line], cuts: list[int], boarded: int
) -> None:
    files = {"F": _file(boarded)}
    versions = _one_version(schedule)
    history: dict[tuple[str, str], KeyState] = {}
    total = 0
    for run in _runs(lines, cuts):
        result = compute(run, files, versions, history, TAU)
        total += sum(r.commission_minor for r in result.lines)
        history = result.history
        for state in history.values():
            assert 0 <= state.commission_minor <= cap_of(state.basis_minor, TAU)
            assert not any(p.clamped for r in result.lines for p in r.parts), (
                "inside one version the bound never binds"
            )
    c = sum(ln.amount_minor for ln in lines)
    rule = schedule.rules[0]
    assert total == cumulative(c, rule, files["F"], TAU) == history[("F", "k")].commission_minor
    # all at once gives the same total
    once = compute(lines, files, versions, {}, TAU)
    assert sum(r.commission_minor for r in once.lines) == total


@settings(max_examples=200, deadline=None)
@given(schedule=schedules(), lines=histories(), seed=st.integers(0, 2**32))
def test_order_of_the_input_does_not_matter(
    schedule: CommissionSchedule, lines: list[Line], seed: int
) -> None:
    files = {"F": _file()}
    versions = _one_version(schedule)
    shuffled = list(lines)
    random.Random(seed).shuffle(shuffled)
    a = compute(lines, files, versions, {}, TAU)
    b = compute(shuffled, files, versions, {}, TAU)
    assert a.lines == b.lines
    assert a.history == b.history
    assert a.inputs_hash == b.inputs_hash


@settings(max_examples=200, deadline=None)
@given(schedule=schedules(), lines=histories())
def test_a_full_reversal_brings_the_file_back_to_zero(
    schedule: CommissionSchedule, lines: list[Line]
) -> None:
    files = {"F": _file()}
    live = {ln.entry_id: ln for ln in lines if ln.kind is LineKind.ALLOCATION}
    for ln in lines:
        if ln.kind is LineKind.ALLOCATION_REVERSAL:
            live.pop(
                next(
                    k
                    for k, v in live.items()
                    if v.amount_minor == -ln.amount_minor
                    and v.encaissement_date == ln.encaissement_date
                )
            )
    undo = [
        _line(1000 + i, ln.amount_minor, ln.encaissement_date, reversal=True)
        for i, ln in enumerate(live.values())
    ]
    first = compute(lines, files, _one_version(schedule), {}, TAU)
    second = compute(undo, files, _one_version(schedule), first.history, TAU)
    assert second.history[("F", "k")] == KeyState(0, 0)
    assert sum(r.commission_minor for r in (*first.lines, *second.lines)) == 0


@settings(max_examples=300, deadline=None)
@given(
    schedule=schedules(),
    a=st.integers(0, 5_000_000),
    b=st.integers(0, 5_000_000),
    boarded=st.integers(0, 3_000_000),
)
def test_f_is_monotone_and_its_ttc_stays_within_the_basis(
    schedule: CommissionSchedule, a: int, b: int, boarded: int
) -> None:
    rule, file = schedule.rules[0], _file(boarded)
    lo, hi = sorted((a, b))
    f_lo, f_hi = cumulative(lo, rule, file, TAU), cumulative(hi, rule, file, TAU)
    assert 0 <= f_lo <= f_hi
    # HT x 1,2 ≤ c exactly: the TTC never exceeds what the file brought in (the minimum included)
    assert f_hi * 12 <= hi * 10
    assert (
        f_hi + vat_of(f_hi, TAU) <= hi
    )  # and so does its TTC, VAT rounded (TTC ≤ c + ½ cent, an integer)


# -- across versions, and the documents ------------------------------------------------------------


@st.composite
def scenarios(draw: st.DrawFn) -> tuple[dict[str, list[TermsVersion]], list[list[Line]]]:
    """Two files, two versions with the same tier key, collections on both sides of the change,
    reversals, runs."""
    switch = D0 + timedelta(days=draw(st.integers(1, 299)))
    v1, v2 = draw(schedules()), draw(schedules())
    versions = {
        "M": [
            TermsVersion("v1", "M", date(2026, 1, 1), switch, v1),
            TermsVersion("v2", "M", switch, None, v2),
        ]
    }
    lines: list[Line] = []
    live: list[Line] = []
    for n in range(draw(st.integers(1, 20))):
        if live and draw(st.integers(0, 2)) == 0:
            o = live.pop(draw(st.integers(0, len(live) - 1)))
            lines.append(
                replace(
                    _line(n, o.amount_minor, o.encaissement_date, reversal=True),
                    account_id=o.account_id,
                )
            )
        else:
            ln = _line(
                n, draw(st.integers(1, 1_000_000)), D0 + timedelta(days=draw(st.integers(0, 300)))
            )
            ln = replace(ln, account_id=draw(st.sampled_from(["F", "G"])))
            lines.append(ln)
            live.append(ln)
    # and finally everything undone
    for i, o in enumerate(live):
        lines.append(
            replace(
                _line(5000 + i, o.amount_minor, o.encaissement_date, reversal=True),
                account_id=o.account_id,
            )
        )
    cuts = draw(st.lists(st.integers(0, 60), max_size=8))
    return versions, _runs(lines, cuts)


@settings(max_examples=300, deadline=None)
@given(scenario=scenarios())
def test_across_versions_bounds_documents_and_vat(
    scenario: tuple[dict[str, list[TermsVersion]], list[list[Line]]],
) -> None:
    versions, runs = scenario
    files = {"F": _file(), "G": FileFacts("G", "M", "rent", "P", boarded_amount_minor=2_000_000)}
    sim = Simulator(files, versions, TAU)
    vat_credited: dict[str, int] = defaultdict(int)
    for run in runs:
        _, docs = sim.run(run)
        for key, state in sim.history.items():
            assert 0 <= state.commission_minor <= cap_of(state.basis_minor, TAU), key
            open_charges = sum(c.open_minor for c in sim.charges.get(key, []))
            assert open_charges == state.commission_minor, (
                key
            )  # credit notes never exceed what was charged
            assert all(0 <= c.credited_minor <= c.charged_minor for c in sim.charges.get(key, []))
        for d in docs.values():
            if d.invoice:
                assert d.invoice.ht_minor > 0
                assert d.invoice.vat_minor == vat_of(d.invoice.ht_minor, TAU)
            if d.credit_note:
                assert d.credit_note.ht_minor < 0
                for c in d.credit_note.corrected:
                    vat_credited[c.invoice_id] -= c.vat_minor
                    assert c.vat_minor <= 0
    for inv_id, inv in sim.invoices.items():
        assert inv.credited_ht_minor <= inv.ht_minor
        assert vat_credited[inv_id] <= sim.invoice_vat[inv_id]
        if inv.credited_ht_minor == inv.ht_minor:
            assert vat_credited[inv_id] == sim.invoice_vat[inv_id], (
                "a full credit gives back exactly the VAT"
            )
    # everything was undone: every invoice is fully credited, every file back to 0
    assert all(s == KeyState(0, 0) for s in sim.history.values())
    assert all(inv.credited_ht_minor == inv.ht_minor for inv in sim.invoices.values())


# -- the inputs hash and the input errors ----------------------------------------------------------


def _flat(rate: str = "0.15", **rule: Any) -> CommissionSchedule:
    return CommissionSchedule.model_validate(
        {
            "schema": "commission-1",
            "basis": BASIS,
            "rules": [
                {
                    "id": "r",
                    "tier_key": "k",
                    "label_fr": "R",
                    "match": {},
                    "rate": {"kind": "flat", "rate": rate},
                    **rule,
                }
            ],
        }
    )


def test_the_inputs_hash_names_every_input() -> None:
    files = {"F": _file()}
    lines = [_line(1, 10_000, D0), _line(2, 20_000, D0 + timedelta(days=3))]
    versions = _one_version(_flat())
    base = inputs_hash(lines, files, versions, {}, TAU)
    assert base == inputs_hash(list(reversed(lines)), files, versions, {}, TAU)
    changed = [
        inputs_hash(
            [replace(lines[0], amount_minor=10_001, basis={"principal": 10_001}), lines[1]],
            files,
            versions,
            {},
            TAU,
        ),
        inputs_hash(lines, {"F": _file(1)}, versions, {}, TAU),
        inputs_hash(lines, files, _one_version(_flat("0.16")), {}, TAU),
        inputs_hash(lines, files, versions, {("F", "k"): KeyState(1, 0)}, TAU),
        inputs_hash(lines, files, versions, {}, Decimal("0.1")),
        inputs_hash(
            [replace(lines[0], encaissement_date=D0 + timedelta(days=1)), lines[1]],
            files,
            versions,
            {},
            TAU,
        ),
    ]
    assert len({base, *changed}) == 7


def test_input_errors() -> None:
    files = {"F": _file()}
    versions = _one_version(_flat())
    ok = _line(1, 10_000, D0)
    with pytest.raises(CommissionInputError, match="twice"):
        compute([ok, ok], files, versions, {}, TAU)
    with pytest.raises(CommissionInputError, match="not given"):
        compute([replace(ok, account_id="X")], files, versions, {}, TAU)
    with pytest.raises(CommissionInputError, match="negative cumulative"):
        compute([_line(2, 10_000, D0, reversal=True)], files, versions, {}, TAU)
    with pytest.raises(CommissionInputError, match="positive"):
        compute([replace(ok, basis={"principal": -1})], files, versions, {}, TAU)
    with pytest.raises(CommissionInputError, match="unknown families"):
        compute([replace(ok, basis={"fees": 1})], files, versions, {}, TAU)
    with pytest.raises(CommissionInputError, match="no component families"):
        compute(
            [replace(ok, kind=LineKind.FORWARD, forward_reason="file_recalled")],
            files,
            versions,
            {},
            TAU,
        )
    overlap = {
        "M": [TermsVersion("a", "M", D0, None, _flat()), TermsVersion("b", "M", D0, None, _flat())]
    }
    with pytest.raises(CommissionInputError, match="overlap"):
        compute([ok], files, overlap, {}, TAU)
    bracket = CommissionSchedule.model_validate(
        {
            "schema": "commission-1",
            "basis": BASIS,
            "rules": [
                {
                    "id": "r",
                    "tier_key": "k",
                    "label_fr": "R",
                    "match": {},
                    "rate": {
                        "kind": "bracket",
                        "attribute": "age_days_at_boarding",
                        "brackets": [{"up_to": None, "rate": "0.1"}],
                    },
                }
            ],
        }
    )
    with pytest.raises(CommissionInputError, match="age_days_at_boarding"):
        compute([ok], files, _one_version(bracket), {}, TAU)


def test_minimum_and_cap_flags() -> None:
    files = {"F": _file()}
    versions = _one_version(_flat("0.05", min_per_file_minor="3000"))
    first = compute([_line(1, 2_000, D0)], files, versions, {}, TAU).lines[0].parts[0]
    assert (first.commission_minor, first.capped, first.minimum_applied) == (1_666, True, False)
    second = (
        compute([_line(1, 2_000, D0), _line(2, 8_000, D0)], files, versions, {}, TAU)
        .lines[1]
        .parts[0]
    )
    assert (second.commission_minor, second.capped, second.minimum_applied) == (1_334, False, True)


def test_only_the_listed_forward_reasons_earn() -> None:
    files = {"F": _file()}
    forwards = {**BASIS["forwards"], "client_ratification": True}  # type: ignore[dict-item]
    listed = CommissionSchedule.model_validate(
        {
            "schema": "commission-1",
            "basis": {**BASIS, "forwards": forwards},
            "rules": [
                {
                    "id": "r",
                    "tier_key": "k",
                    "label_fr": "R",
                    "match": {},
                    "rate": {"kind": "flat", "rate": "0.1"},
                }
            ],
        }
    )
    forward = replace(_line(1, 10_000, D0), kind=LineKind.FORWARD, basis={})
    for reason, expected in (
        ("client_ratification", 1_000),
        ("file_recalled", 0),
        ("ops_correction", 0),
        ("model_config", 0),  # never an attribute lookup on whatever the reason says
        (None, 0),
    ):
        line = replace(forward, forward_reason=reason)
        result = compute([line], files, _one_version(listed), {}, TAU)
        assert result.lines[0].commission_minor == expected, reason
