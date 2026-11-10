"""The commission engine `commission-1` (design §8.3, §8.4, §18 M2-13; review fixes of 2026-11-10):
Hypothesis properties and the input errors.

* a function of the live lines: across terms versions, the commission a (file, tier key) ends with
  is the same however its lines fell into runs and in whatever order the runs came; it is what one
  run over the surviving lines alone gives; inside one version it is F(Σ basis) (telescoping);
* undoing one collection gives back what it adds to the file — exactly its own charge when nothing
  else changed since, priced under its own version, with VAT too (the rounding reserve included);
  undoing everything brings the file back to 0;
* with flat or bracket rates, any minimums, across versions: a reversal never raises the commission
  and a collection never lowers it (the minimum is taken on the file: second review);
* the cap and the minimum: F monotone; HT x 1,2 plus one cent per open invoice within the basis,
  so the TTC billed to a file over any number of runs never exceeds what it brought in; the hold
  that ensures it never more than ⌈(n + 1) / 1,2⌉ cents; inside one version a run of collections
  never issues a credit note nor gives a part below 0;
* `keep`: a kept reversal never lowers the commission and never issues a credit note, VAT or not,
  and what is collected after it is priced at the net tier position;
* documents: never more credited than an invoice charged per (file, tier key); credit-note VAT ≤
  the invoice's VAT and equal to it on a full credit; Σ open charges = the commission charged; no
  invoice line shows a negative band (a re-tiering is its own regularisation line); a reversal is
  credited on its original's invoice first;
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
    schedule_commission,
)
from collectoo_worker.remittance.documents import EarlierCharge
from collectoo_worker.remittance.terms import CommissionSchedule
from collectoo_worker.remittance.vat import vat_of

TAU = Decimal("0.2")
NO_VAT = Decimal("0")
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
Key = tuple[str, str]


def rate_text(n: int) -> str:
    return "1" if n == 10_000 else f"0.{n:04d}"


ALL_KINDS = ("flat", "marginal", "bracket")
LINEAR = ("flat", "bracket")  # one rate per file: no tiers to re-tier


@st.composite
def rate_docs(draw: st.DrawFn, kinds: tuple[str, ...] = ALL_KINDS) -> dict[str, Any]:
    kind = draw(st.sampled_from(kinds))
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
def schedules(
    draw: st.DrawFn,
    tier_key: str = "k",
    on_reversal: str = "credit",
    kinds: tuple[str, ...] = ALL_KINDS,
    two_keys: bool = False,
) -> CommissionSchedule:
    """One rule (tier key k), or with `two_keys` principal on key kp and the rest on key ko."""
    rule: dict[str, Any] = {
        "id": "r",
        "tier_key": tier_key,
        "label_fr": "Règle",
        "match": {},
        "rate": draw(rate_docs(kinds)),
    }
    rules = [rule]
    if two_keys:
        rules = [
            {**rule, "id": "p", "tier_key": "kp", "match": {"families": ["principal"]}},
            {**rule, "id": "o", "tier_key": "ko", "rate": draw(rate_docs(kinds))},
        ]
    for r in rules:
        if draw(st.booleans()):
            r["min_per_file_minor"] = str(draw(st.integers(0, 50_000)))
    return CommissionSchedule.model_validate(
        {"schema": "commission-1", "basis": {**BASIS, "on_reversal": on_reversal}, "rules": rules}
    )


def _file(boarded: int = 300_000, account: str = "F", mandate: str = "M") -> FileFacts:
    return FileFacts(account, mandate, "b2b_invoice", "P", boarded_amount_minor=boarded)


def _line(  # noqa: PLR0913 - a test line's facts
    n: int, amount: int, e: date, *, reversal: bool = False, account: str = "F", of: str = ""
) -> Line:
    eff = e + timedelta(days=40 if reversal else 0)
    return Line(
        entry_id=f"{'R' if reversal else 'A'}{n:05d}",
        kind=LineKind.ALLOCATION_REVERSAL if reversal else LineKind.ALLOCATION,
        account_id=account,
        encaissement_date=e,
        effective_date=eff,
        posted_at=datetime(eff.year, eff.month, eff.day, 12, tzinfo=UTC) + timedelta(seconds=n),
        amount_minor=-amount if reversal else amount,
        basis={"principal": -amount if reversal else amount},
        original_entry_id=of or None,
    )


def _undo(n: int, original: Line) -> Line:
    undo = _line(
        n,
        original.amount_minor,
        original.encaissement_date,
        reversal=True,
        account=original.account_id or "F",
        of=original.entry_id,
    )
    return replace(undo, basis={k: -v for k, v in original.basis.items()})


@st.composite
def histories(  # noqa: PLR0913, PLR0917 - the shapes of a history
    draw: st.DrawFn,
    max_ops: int = 25,
    accounts: tuple[str, ...] = ("F",),
    undo_all: bool = False,
    small: bool = False,
    interest: bool = False,
) -> list[Line]:
    """Collections (any encaissement date: back-dated ones too) and reversals of live ones, each
    reversal after its original; with `undo_all`, every collection undone at the end. `small`:
    amounts up to 4,00 € (the minimum's cap and the rounding reserve bind); `interest`: some of
    each collection allocated to interest."""
    lines: list[Line] = []
    live: list[Line] = []
    for n in range(draw(st.integers(1, max_ops))):
        if live and draw(st.integers(0, 3)) == 0:
            lines.append(_undo(n, live.pop(draw(st.integers(0, len(live) - 1)))))
        else:
            amount = draw(st.integers(1, 400 if small else 1_000_000))
            e = D0 + timedelta(days=draw(st.integers(0, 300)))
            ln = _line(n, amount, e, account=draw(st.sampled_from(accounts)))
            if interest:
                share = draw(st.integers(0, amount))
                parts = {"principal": amount - share, "interest": share}
                ln = replace(ln, basis={k: v for k, v in parts.items() if v})
            lines.append(ln)
            live.append(ln)
    if undo_all:
        lines += [_undo(5000 + i, o) for i, o in enumerate(live)]
    return lines


def _runs(lines: list[Line], cuts: list[int]) -> list[list[Line]]:
    """Split lines (in creation order) into consecutive runs: every reversal lands in its original's
    run or later."""
    points = sorted({c % (len(lines) + 1) for c in cuts} | {0, len(lines)})
    return [lines[a:b] for a, b in pairwise(points) if b > a]


def _one_version(schedule: CommissionSchedule) -> dict[str, list[TermsVersion]]:
    return {"M": [TermsVersion("v", "M", date(2026, 1, 1), None, schedule)]}


@st.composite
def terms(
    draw: st.DrawFn,
    on_reversal: str = "credit",
    kinds: tuple[str, ...] = ALL_KINDS,
    two_keys: bool = False,
) -> dict[str, list[TermsVersion]]:
    """One to three versions of mandate M sharing its tier keys, each from its own date."""
    switches = sorted(draw(st.sets(st.integers(1, 299), max_size=2)))
    starts = [date(2026, 1, 1), *(D0 + timedelta(days=s) for s in switches)]
    ends: list[date | None] = [*starts[1:], None]
    return {
        "M": [
            TermsVersion(
                f"v{i}",
                "M",
                a,
                b,
                draw(schedules(on_reversal=on_reversal, kinds=kinds, two_keys=two_keys)),
            )
            for i, (a, b) in enumerate(zip(starts, ends, strict=True))
        ]
    }


def _live(lines: list[Line]) -> list[Line]:
    undone = {ln.original_entry_id for ln in lines if ln.original_entry_id}
    return [ln for ln in lines if ln.kind is LineKind.ALLOCATION and ln.entry_id not in undone]


def _targets(
    history: dict[Key, KeyState],
    files: dict[str, FileFacts],
    versions: dict[str, list[TermsVersion]],
    tau: Decimal,
) -> dict[Key, int]:
    return {k: schedule_commission(s, files[k[0]], k[1], versions, tau) for k, s in history.items()}


# -- a function of the live lines ------------------------------------------------------------------


@settings(max_examples=300, deadline=None)
@given(
    versions=terms(),
    lines=histories(accounts=("F", "G")),
    cuts=st.lists(st.integers(0, 50), max_size=6),
    seed=st.integers(0, 2**32),
    boarded=st.integers(0, 3_000_000),
)
def test_partition_invariance_across_versions(
    versions: dict[str, list[TermsVersion]],
    lines: list[Line],
    cuts: list[int],
    seed: int,
    boarded: int,
) -> None:
    """However the lines fall into runs: the schedule's commission per (file, tier key) is that of
    one run over the same lines, and that of one run over the surviving lines alone. With no VAT
    there is no rounding reserve: what is charged is exactly that, partition or not."""
    files = {"F": _file(boarded), "G": _file(2_000_000, "G")}
    once = compute(lines, files, versions, {}, TAU)
    alive = compute(_live(lines), files, versions, {}, TAU)
    for tau in (TAU, NO_VAT):
        sim = Simulator(files, versions, tau)
        for run in _runs(lines, cuts):
            sim.run(run)
        target = _targets(sim.history, files, versions, tau)
        if tau == TAU:
            assert target == _targets(once.history, files, versions, tau)
            survivors = _targets(alive.history, files, versions, tau)
            assert {k: v for k, v in target.items() if v} == {
                k: v for k, v in survivors.items() if v
            }
        else:
            assert {k: s.commission_minor for k, s in sim.history.items()} == target
            single = compute(lines, files, versions, {}, tau)
            assert {k: s.commission_minor for k, s in single.history.items()} == target
    # the runs in another order (a run's lines are sorted by the engine; history only grows)
    shuffled = list(lines)
    random.Random(seed).shuffle(shuffled)
    other = compute(shuffled, files, versions, {}, TAU)
    assert other.history == once.history and other.lines == once.lines
    assert other.inputs_hash == once.inputs_hash


@settings(max_examples=300, deadline=None)
@given(
    schedule=schedules(),
    lines=histories(),
    cuts=st.lists(st.integers(0, 50), max_size=6),
    boarded=st.integers(0, 3_000_000),
)
def test_telescoping_inside_one_version(
    schedule: CommissionSchedule, lines: list[Line], cuts: list[int], boarded: int
) -> None:
    files = {"F": _file(boarded)}
    versions = _one_version(schedule)
    sim = Simulator(files, versions, NO_VAT)
    total = 0
    for run in _runs(lines, cuts):
        result, _ = sim.run(run)
        total += sum(r.commission_minor for r in result.lines)
    c = sum(ln.amount_minor for ln in lines)
    rule = schedule.rules[0]
    assert (
        total == cumulative(c, rule, files["F"], NO_VAT) == sim.history[("F", "k")].commission_minor
    )


@settings(max_examples=300, deadline=None)
@given(
    versions=terms(),
    lines=histories(max_ops=15),
    cuts=st.lists(st.integers(0, 30), max_size=4),
    pick=st.integers(0, 10**6),
    amount=st.integers(1, 1_000_000),
    day=st.integers(0, 300),
)
def test_undoing_one_collection_gives_back_its_own_charge(  # noqa: PLR0913, PLR0917
    versions: dict[str, list[TermsVersion]],
    lines: list[Line],
    cuts: list[int],
    pick: int,
    amount: int,
    day: int,
) -> None:
    """(1) A collection charged in one run and undone in the next gives back exactly its charge,
    whatever came before and whatever version its date falls in. (2) Undoing any live collection
    gives back what it adds to the file: the file is then charged what its other lines earn."""
    files = {"F": _file()}
    for tau in (TAU, NO_VAT):
        sim = Simulator(files, versions, tau)
        for run in _runs(lines, cuts):
            sim.run(run)
        fresh = _line(9000, amount, D0 + timedelta(days=day))
        charged, _ = sim.run([fresh])
        undone, _ = sim.run([_undo(9001, fresh)])
        target = _targets(sim.history, files, versions, tau)
        _gives_back(charged.lines[0].commission_minor, undone.lines[0].commission_minor)
        before = _targets(compute(lines, files, versions, {}, tau).history, files, versions, tau)
        assert target.get(("F", "k"), 0) == before.get(("F", "k"), 0)
    live = _live(lines)
    if live:
        victim = live[pick % len(live)]
        sim = Simulator(files, versions, NO_VAT)
        sim.run(lines)
        sim.run([_undo(9002, victim)])
        rest = compute([ln for ln in live if ln is not victim], files, versions, {}, NO_VAT)
        assert sim.history[("F", "k")].commission_minor == (
            rest.history[("F", "k")].commission_minor if ("F", "k") in rest.history else 0
        )


def _gives_back(charge: int, back: int) -> None:
    """A collection charged in one run and undone in the next gives back exactly its charge. The
    one exception: a collection that lowered the commission (a change of marginal grid re-tiered
    later ones) on a file at its rounding hold — its undoing needs an invoice, whose VAT rounding
    the reserve must then cover: at most one cent less, released at the file's next collection."""
    if charge >= 0:
        assert back == -charge, (charge, back)
    else:
        assert -charge - 1 <= back <= -charge, (charge, back)


@settings(max_examples=300, deadline=None)
@given(
    versions=terms(two_keys=True),
    lines=histories(max_ops=20, small=True, interest=True),
    cuts=st.lists(st.integers(0, 60), max_size=10),
    amount=st.integers(1, 400),
    day=st.integers(0, 300),
)
def test_with_vat_an_undone_collection_gives_back_its_charge(
    versions: dict[str, list[TermsVersion]],
    lines: list[Line],
    cuts: list[int],
    amount: int,
    day: int,
) -> None:
    """With VAT and small collections (the reserve binds): the charge of the run before is given
    back, the cent of the reserve included (the reserve counts the invoices the reversal's credit
    note closes, so undoing a collection returns the hold to where it was)."""
    files = {"F": _file()}
    sim = Simulator(files, versions, TAU)
    for run in _runs(lines, cuts):
        sim.run(run)
    fresh = _line(9000, amount, D0 + timedelta(days=day))
    charged, _ = sim.run([fresh])
    undone, _ = sim.run([_undo(9001, fresh)])
    _gives_back(charged.lines[0].commission_minor, undone.lines[0].commission_minor)
    if len(versions["M"]) == 1:
        assert undone.lines[0].commission_minor == -charged.lines[0].commission_minor


def _small(lines: list[Line]) -> list[Line]:
    """The same history with amounts up to 4,00 €, all principal."""
    small = {ln.entry_id: ln.amount_minor % 401 or 1 for ln in lines if not ln.original_entry_id}
    out = []
    for ln in lines:
        a = -small[ln.original_entry_id] if ln.original_entry_id else small[ln.entry_id]
        out.append(replace(ln, amount_minor=a, basis={"principal": a}))
    return out


@settings(max_examples=300, deadline=None)
@given(
    versions=terms(kinds=LINEAR, two_keys=True),
    lines=histories(max_ops=25, interest=True),
    small=st.booleans(),
)
def test_with_flat_rates_a_reversal_never_raises_and_a_collection_never_lowers(
    versions: dict[str, list[TermsVersion]], lines: list[Line], small: bool
) -> None:
    """Flat (and bracket) rates, any minimums, across versions (second review: the minimum is
    taken on the file, not per version): the schedule's commission and what is charged never go
    down on a collection and never up on a reversal, each line in its own run, with or without
    VAT."""
    if small:
        lines = _small(lines)
    files = {"F": _file()}
    for tau in (TAU, NO_VAT):
        sim = Simulator(files, versions, tau)
        for ln in lines:
            targets = _targets(sim.history, files, versions, tau)
            before = {k: (targets[k], s.commission_minor) for k, s in sim.history.items()}
            sim.run([ln])
            targets = _targets(sim.history, files, versions, tau)
            for k, s in sim.history.items():
                was, now = before.get(k, (0, 0)), (targets[k], s.commission_minor)
                if ln.kind is LineKind.ALLOCATION_REVERSAL:
                    assert now[0] <= was[0] and now[1] <= was[1], (k, was, now)
                else:
                    assert now[0] >= was[0] and now[1] >= was[1], (k, was, now)


@settings(max_examples=300, deadline=None)
@given(
    schedule=schedules(two_keys=True),
    lines=histories(max_ops=30, small=True, interest=True),
    cuts=st.lists(st.integers(0, 60), max_size=14),
)
def test_without_a_reversal_no_credit_note_and_no_negative_part(
    schedule: CommissionSchedule, lines: list[Line], cuts: list[int]
) -> None:
    """Inside one version, a run of collections only never issues a credit note and never gives a
    line a negative part, whatever the rounding reserve holds (second review: the hold is taken
    from the key's positive parts, last to first, never below 0)."""
    sim = Simulator({"F": _file()}, _one_version(schedule), TAU)
    for run in _runs(lines, cuts):
        result, docs = sim.run(run)
        if not any(ln.kind is LineKind.ALLOCATION_REVERSAL for ln in run):
            assert all(d.credit_note is None for d in docs.values()), docs
            assert all(p.commission_minor >= 0 for r in result.lines for p in r.parts)


def test_the_hold_never_turns_a_collection_into_a_credit() -> None:
    """The review's case: 5 %, minimum 30,00 €, three small runs; the third collects 0,50 € and
    0,01 €. The reserve holds 3 cents (three invoices): taken from the last positive parts (0,01
    €'s 1 cent, then 2 of 0,50 €'s), not as -0,01 € on the second collection (a credit note)."""
    sim = Simulator({"F": _file()}, _one_version(_flat("0.05", min_per_file_minor="3000")), TAU)
    d = date(2026, 3, 2)
    for i, amount in enumerate((50, 59)):
        sim.run([_line(i, amount, d + timedelta(days=i))])
    x, y = _line(2, 50, d + timedelta(days=2)), _line(3, 1, d + timedelta(days=3))
    result, docs = sim.run([x, y])
    assert [r.commission_minor for r in result.lines] == [41, 0]  # ⌊(1,60 - 0,03) / 1,2⌋ - 0,89
    assert result.lines[1].parts[0].held_minor == 3
    invoice = docs["M"].invoice
    assert docs["M"].credit_note is None and invoice is not None
    assert (invoice.ht_minor, invoice.vat_minor) == (41, 8)  # 0,48 + 0,59 + 0,49 = 1,56 € ≤ 1,60 €


def test_a_kept_reversal_does_not_deepen_the_hold() -> None:
    """The review's case: 5 %, minimum 30,00 €, `keep`, 20,01 € collected (16,66 € charged, one
    cent held for its invoice), then undone: the fee is kept and the reversal issues no invoice,
    so the reserve keeps counting one invoice — nothing credited (it was -0,01 €)."""
    keep = CommissionSchedule.model_validate(
        {
            "schema": "commission-1",
            "basis": {**BASIS, "on_reversal": "keep"},
            "rules": [
                {
                    "id": "r",
                    "tier_key": "k",
                    "label_fr": "R",
                    "match": {},
                    "rate": {"kind": "flat", "rate": "0.05"},
                    "min_per_file_minor": "3000",
                }
            ],
        }
    )
    sim = Simulator({"F": _file()}, _one_version(keep), TAU)
    a = _line(1, 2001, D0)
    first, _ = sim.run([a])
    assert first.lines[0].commission_minor == 1666  # ⌊(20,01 - 0,01) / 1,2⌋
    undone, docs = sim.run([_undo(2, a)])
    assert undone.lines[0].commission_minor == 0 and docs == {}
    assert sim.history[("F", "k")].commission_minor == 1666


@settings(max_examples=300, deadline=None)
@given(
    versions=terms(on_reversal="keep", two_keys=True),
    lines=histories(max_ops=25, small=True, interest=True),
    big=histories(max_ops=4),
)
def test_with_vat_a_kept_reversal_never_issues_a_credit_note(
    versions: dict[str, list[TermsVersion]], lines: list[Line], big: list[Line]
) -> None:
    """Under `keep`, with VAT, across versions, each line in its own run: a reversal never lowers
    what is charged and never issues a credit note (its run issues no invoice, so the reserve
    counts no new one)."""
    sim = Simulator({"F": _file()}, versions, TAU)
    for ln in [*lines, *big]:
        before = {k: s.commission_minor for k, s in sim.history.items()}
        _, docs = sim.run([ln])
        if ln.kind is LineKind.ALLOCATION_REVERSAL:
            assert all(d.credit_note is None for d in docs.values())
            assert all(s.commission_minor >= before.get(k, 0) for k, s in sim.history.items())


@settings(max_examples=300, deadline=None)
@given(
    versions=terms(two_keys=True),
    lines=histories(max_ops=25, accounts=("F", "G"), interest=True),
    cuts=st.lists(st.integers(0, 60), max_size=10),
)
def test_documents_never_show_a_negative_band_and_credit_the_originals_invoice_first(
    versions: dict[str, list[TermsVersion]], lines: list[Line], cuts: list[int]
) -> None:
    """Across versions: every invoice line's bands are positive (a re-tiering is its own
    regularisation line, with no bands) and the lines add up to the invoice; a reversal's credit
    goes to the invoice that charged its original, and elsewhere only once that invoice charges
    the key nothing more."""
    files = {"F": _file(), "G": _file(2_000_000, "G")}
    sim = Simulator(files, versions, TAU)
    for run in _runs(lines, cuts):
        originals = dict(sim.line_invoices)
        result, docs = sim.run(run)
        for d in docs.values():
            if d.invoice:
                assert sum(il.ht_minor for il in d.invoice.lines) == d.invoice.ht_minor
                for il in d.invoice.lines:
                    assert il.ht_minor > 0 and all(b > 0 for _, b in il.tiers), il
                    assert il.kind == "commission" or not il.tiers
        open_after = {(c.invoice_id, k): c.open_minor for k, v in sim.charges.items() for c in v}
        allocations = [a for d in docs.values() if d.credit_note for a in d.credit_note.allocations]
        for r in result.lines:
            first = originals.get(r.original_entry_id or "")
            if r.kind is not LineKind.ALLOCATION_REVERSAL or first is None:
                continue
            for a in allocations:
                if a.entry_id == r.entry_id and a.original_invoice_id != first:
                    assert open_after.get((first, (a.account_id, a.tier_key)), 0) == 0, a


# -- the cap, the minimum, the TTC billed, the documents -------------------------------------------


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
    # HT x 1,2 ≤ c exactly (the minimum included); one invoice's TTC, VAT rounded, too
    assert f_hi * 12 <= hi * 10
    assert f_hi + vat_of(f_hi, TAU) <= hi


@st.composite
def scenarios(draw: st.DrawFn) -> tuple[dict[str, list[TermsVersion]], list[list[Line]]]:
    """Versions, two files of one mandate, collections, reversals, runs; everything undone last."""
    versions = draw(terms())
    lines = draw(histories(max_ops=20, accounts=("F", "G"), undo_all=True))
    return versions, _runs(lines, draw(st.lists(st.integers(0, 60), max_size=8)))


def _check_documents(sim: Simulator, docs: Any, vat_credited: dict[str, int]) -> None:
    for key, state in sim.history.items():
        open_charges = sum(c.open_minor for c in sim.charges.get(key, []))
        assert open_charges == state.commission_minor, key  # never more credited than charged
        assert all(0 <= c.credited_minor <= c.charged_minor for c in sim.charges.get(key, []))
        # HT x 1,2 plus a cent per open invoice within the basis (the reserve); its TTC share too
        assert state.commission_minor * 12 + 10 * sim.open_invoices(key) <= 10 * max(
            state.gross_basis_minor, 0
        ) or (state.commission_minor == 0)
    for d in docs.values():
        if d.invoice:
            assert d.invoice.ht_minor > 0
            assert d.invoice.vat_minor == vat_of(d.invoice.ht_minor, TAU)
        if d.credit_note:
            assert d.credit_note.ht_minor < 0
            for c in d.credit_note.corrected:
                vat_credited[c.invoice_id] -= c.vat_minor
                assert c.vat_minor <= 0


@settings(max_examples=300, deadline=None)
@given(scenario=scenarios())
def test_across_versions_documents_vat_and_back_to_zero(
    scenario: tuple[dict[str, list[TermsVersion]], list[list[Line]]],
) -> None:
    versions, runs = scenario
    files = {"F": _file(), "G": FileFacts("G", "M", "rent", "P", boarded_amount_minor=2_000_000)}
    sim = Simulator(files, versions, TAU)
    vat_credited: dict[str, int] = defaultdict(int)
    for run in runs:
        _, docs = sim.run(run)
        _check_documents(sim, docs, vat_credited)
    for inv_id, inv in sim.invoices.items():
        assert inv.credited_ht_minor <= inv.ht_minor
        assert vat_credited[inv_id] <= sim.invoice_vat[inv_id]
        if inv.credited_ht_minor == inv.ht_minor:
            assert vat_credited[inv_id] == sim.invoice_vat[inv_id], (
                "a full credit gives back exactly the VAT"
            )
    # everything was undone: every invoice is fully credited, every file back to 0
    assert all(s.commission_minor == 0 and s.basis_minor == 0 for s in sim.history.values())
    assert all(inv.credited_ht_minor == inv.ht_minor for inv in sim.invoices.values())


@settings(max_examples=300, deadline=None)
@given(
    versions=terms(),
    lines=histories(max_ops=30),
    cuts=st.lists(st.integers(0, 60), max_size=12),
    small=st.booleans(),
)
def test_the_ttc_billed_to_a_file_never_exceeds_what_it_brought_in(
    versions: dict[str, list[TermsVersion]], lines: list[Line], cuts: list[int], small: bool
) -> None:
    """A file alone on its mandate, invoiced over many runs (small collections, so that the
    minimum's cap binds and each invoice rounds its own VAT): after every run, Σ invoice TTC -
    Σ credit-note TTC ≤ the file's basis, and the hold that ensures it stays within ⌈(n + 1) / 1,2⌉
    (n the invoices open before the run)."""
    if small:
        lines = [
            replace(ln, amount_minor=ln.amount_minor % 997 or 1, basis={"principal": 0})
            for ln in lines
        ]
        by_id = {ln.entry_id: ln for ln in lines}
        lines = [
            replace(
                ln,
                amount_minor=(a := -by_id[ln.original_entry_id].amount_minor)
                if ln.original_entry_id
                else ln.amount_minor,
                basis={"principal": a if ln.original_entry_id else ln.amount_minor},
            )
            for ln in lines
        ]
    files = {"F": _file()}
    sim = Simulator(files, versions, TAU)
    billed = 0
    for run in _runs(lines, cuts):
        n = sim.open_invoices(("F", "k"))
        _, docs = sim.run(run)
        for d in docs.values():
            billed += (d.invoice.ttc_minor if d.invoice else 0) + (
                d.credit_note.ttc_minor if d.credit_note else 0
            )
        state = sim.history.get(("F", "k"), KeyState())
        assert billed <= state.basis_minor, (billed, state)
        target = schedule_commission(state, files["F"], "k", versions, TAU)
        # the hold: at most what one more invoice than were open costs
        assert 0 <= target - state.commission_minor <= -(-(n + 1) * 10 // 12)
        assert target <= cap_of(state.basis_minor, TAU)


# -- the fee kept by clause ------------------------------------------------------------------------


@settings(max_examples=300, deadline=None)
@given(
    schedule=schedules(on_reversal="keep"),
    lines=histories(max_ops=20),
    again=st.integers(1, 1_000_000),
)
def test_a_kept_reversal_never_lowers_the_commission(
    schedule: CommissionSchedule, lines: list[Line], again: int
) -> None:
    """Under `keep` a reversal gives nothing back, and what is collected after it is priced at the
    net tier position: with no minimum, its commission is F(net + a) - F(net)."""
    files = {"F": _file()}
    sim = Simulator(files, _one_version(schedule), NO_VAT)
    for ln in lines:
        before = sim.history.get(("F", "k"), KeyState()).commission_minor
        result, docs = sim.run([ln])
        after = sim.history[("F", "k")].commission_minor
        if ln.kind is LineKind.ALLOCATION_REVERSAL:
            assert after == before and not any(d.credit_note for d in docs.values())
        else:
            assert after >= before
    state = sim.history[("F", "k")]
    net = state.basis_minor
    result, _ = sim.run([_line(9000, again, D0 + timedelta(days=301))])
    rule = schedule.rules[0]
    if not rule.min_per_file_minor or int(rule.min_per_file_minor) == 0:
        assert result.lines[0].commission_minor == cumulative(
            net + again, rule, files["F"], NO_VAT
        ) - cumulative(net, rule, files["F"], NO_VAT)


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
    state = KeyState(basis=(("v", 1),))
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
        inputs_hash(lines, files, versions, {("F", "k"): state}, TAU),
        inputs_hash(
            lines, files, versions, {}, TAU, {("F", "k"): [EarlierCharge("FC-1", (2026, 1), 1)]}
        ),
        inputs_hash(lines, files, versions, {("F", "k"): replace(state, kept_minor=1)}, TAU),
        inputs_hash(lines, files, versions, {}, Decimal("0.1")),
        inputs_hash(
            [replace(lines[0], encaissement_date=D0 + timedelta(days=1)), lines[1]],
            files,
            versions,
            {},
            TAU,
        ),
        inputs_hash([replace(lines[0], original_entry_id="X"), lines[1]], files, versions, {}, TAU),
    ]
    assert len({base, *changed}) == 1 + len(changed)
    # the invoice that charged the line a reversal undoes (it is credited first)
    undo = [*lines, _line(3, 10_000, D0, reversal=True, of=lines[0].entry_id)]
    first = lines[0].entry_id
    assert inputs_hash(undo, files, versions, {}, TAU) != inputs_hash(
        undo, files, versions, {}, TAU, line_invoices={first: "FC-1"}
    )
    assert inputs_hash(lines, files, versions, {}, TAU) == inputs_hash(
        lines, files, versions, {}, TAU, line_invoices={first: "FC-1"}
    )  # only the invoices of the lines the run undoes


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
    with pytest.raises(CommissionInputError, match="version x"):
        compute([ok], files, versions, {("F", "k"): KeyState(basis=(("x", 5),))}, TAU)
    with pytest.raises(CommissionInputError, match="negative kept"):
        compute([ok], files, versions, {("F", "k"): KeyState(kept_minor=-1)}, TAU)
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


def test_minimum_cap_and_reserve_flags() -> None:
    files = {"F": _file()}
    versions = _one_version(_flat("0.05", min_per_file_minor="3000"))
    first = compute([_line(1, 2_000, D0)], files, versions, {}, TAU).lines[0].parts[0]
    # min 30,00 capped at ⌊20,00 / 1,2⌋ = 16,66, held at ⌊(20,00 - 0,01) / 1,2⌋ (one invoice)
    assert (first.commission_minor, first.capped, first.minimum_applied, first.held_minor) == (
        1_665,
        True,
        True,
        1,
    )
    second = (
        compute([_line(1, 2_000, D0), _line(2, 8_000, D0)], files, versions, {}, TAU)
        .lines[1]
        .parts[0]
    )
    # in one run the hold is settled on the key's total: 30,00 - 16,66, nothing held
    assert (second.commission_minor, second.capped, second.minimum_applied) == (1_334, False, True)
    assert second.held_minor == 0
    none = compute([_line(1, 2_000, D0)], files, versions, {}, NO_VAT).lines[0].parts[0]
    assert (none.commission_minor, none.held_minor) == (2_000, 0)  # no VAT: nothing to reserve


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


def test_a_credit_beyond_earlier_invoices_nets_in_the_run() -> None:
    """0 % to 5 000,00 €, then 100 %: A (1 000,00 €) is charged nothing; a back-dated collection C
    then puts A in the 100 % band (+1 000,00) and A's reversal in the same run takes it back.
    Earlier invoices charge nothing to credit: what the run added and takes back nets inside it."""
    schedule = CommissionSchedule.model_validate(
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
                        "kind": "marginal",
                        "tiers": [
                            {"up_to_minor": "500000", "rate": "0"},
                            {"up_to_minor": None, "rate": "1"},
                        ],
                    },
                }
            ],
        }
    )
    sim = Simulator({"F": _file()}, _one_version(schedule), TAU)
    a = _line(1, 100_000, D0 + timedelta(days=10))
    first, docs = sim.run([a])
    assert first.lines[0].commission_minor == 0 and docs == {}
    c = _line(2, 500_000, D0)
    second, docs = sim.run([c, _undo(3, a)])
    assert [r.commission_minor for r in second.lines] == [100_000, -100_000]
    assert docs == {} and sim.history[("F", "k")].commission_minor == 0
