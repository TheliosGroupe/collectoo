"""The commission engine `commission-1` (design §8.3, §8.4, §18 M2-13; review fixes of 2026-11-10):
Hypothesis properties and the input errors.

* a function of the live lines: across terms versions, the commission a (file, tier key) ends with
  is the same however its lines fell into runs and in whatever order the runs came; it is what one
  run over the surviving lines alone gives; inside one version it is F(Σ basis) (telescoping);
* undoing one collection gives back what it adds to the file — exactly its own charge when nothing
  else changed since, priced under its own version, with VAT too (the rounding reserve included),
  except by at most one cent when the undo issues a tier regularisation invoice at the hold (third
  review, a documented bound); undoing everything brings the file back to 0;
* event order (third review): under `keep` one run over the events gives what any split of them
  into consecutive runs gives (a bounce after a later collection); under `credit` a collection
  undone in its own run is never priced, so no invoice charges it and no band moves twice;
* a change of the VAT rate: a run of collections never issues a credit note nor lowers what is
  charged; whether the rate rises or falls the TTC billed stays within the basis (each invoice
  keeps its own rate in the reserve, M2c-4);
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
* the inputs hash: the same inputs in any order give the same hash, any change another;
* manual credit notes (M2c-5b): Σ open charges + Σ waivers = V for every key at every step; the
  waiver is invisible to what the engine charges (V, tiers, kept fees and invoices are those of a
  twin without manual credit notes), so no later collection re-charges a waived amount, whatever
  the partition into runs, the order of a run's lines and the VAT rates; a later credit is absorbed
  by the credited invoice's waiver first, then credited, never beyond that invoice's remaining HT;
  a full reversal leaves every invoice credited in full, its VAT exactly; a cancelled run restores
  the state before it, and running it again is the run never cancelled — every key's state with
  its waiver, every earlier invoice's charge and waiver, each corrective invoice credited in full
  (review math#0); at another VAT rate it stays within the reserve of the run never approved where
  each key has at most two invoices and one reversal, a reversal's links coming in the order the
  cancelled run took them (`retake_links`, review round 2) — beyond its chain LIFO, so a smaller
  credit run again comes off the oldest invoice the cancelled run took from (round 3); a manual
  credit is spread over the invoice's keys in proportion to what each still charges.
"""

from __future__ import annotations

import copy
import random
from collections import defaultdict
from dataclasses import replace
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from itertools import pairwise
from typing import Any

import pytest
from commission_cases import Simulator
from hypothesis import example, given, settings
from hypothesis import strategies as st

from collectoo_worker.remittance.commission import (
    CommissionInputError,
    FileFacts,
    KeyState,
    Line,
    LineCommission,
    LineKind,
    Part,
    Retake,
    TermsVersion,
    cap_of,
    chain,
    compute,
    cumulative,
    inputs_hash,
    retake_links,
    schedule_commission,
)
from collectoo_worker.remittance.documents import (
    EarlierCharge,
    EarlierInvoice,
    MandateDocuments,
    ManualCreditError,
    manual_credit,
    run_documents,
)
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
    """One to three versions of mandate M sharing its tier keys, each from its own date; with
    `on_reversal="mixed"` each version draws its own clause (a mandate whose clause changes)."""
    switches = sorted(draw(st.sets(st.integers(1, 299), max_size=2)))
    starts = [date(2026, 1, 1), *(D0 + timedelta(days=s) for s in switches)]
    ends: list[date | None] = [*starts[1:], None]
    out = []
    for i, (a, b) in enumerate(zip(starts, ends, strict=True)):
        clause = (
            draw(st.sampled_from(("credit", "keep"))) if on_reversal == "mixed" else on_reversal
        )
        schedule = draw(schedules(on_reversal=clause, kinds=kinds, two_keys=two_keys))
        out.append(TermsVersion(f"v{i}", "M", a, b, schedule))
    return {"M": out}


CLAUSES = st.sampled_from(("credit", "keep", "mixed"))


def _live(lines: list[Line]) -> list[Line]:
    undone = {ln.original_entry_id for ln in lines if ln.original_entry_id}
    return [ln for ln in lines if ln.kind is LineKind.ALLOCATION and ln.entry_id not in undone]


def _nonzero(amounts: dict[Key, int]) -> dict[Key, int]:
    """A key a run never priced (a collection undone in its own run) is absent: as if 0."""
    return {k: v for k, v in amounts.items() if v}


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
        target = _nonzero(_targets(sim.history, files, versions, tau))
        if tau == TAU:
            assert target == _nonzero(_targets(once.history, files, versions, tau))
            assert target == _nonzero(_targets(alive.history, files, versions, tau))
        else:
            assert _nonzero({k: s.commission_minor for k, s in sim.history.items()}) == target
            single = compute(lines, files, versions, {}, tau)
            assert _nonzero({k: s.commission_minor for k, s in single.history.items()}) == target
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
        total
        == cumulative(c, rule, files["F"], NO_VAT)
        == sim.history.get(("F", "k"), KeyState()).commission_minor
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
        undone, docs = sim.run([_undo(9001, fresh)])
        target = _targets(sim.history, files, versions, tau)
        _gives_back(charged.lines[0].commission_minor, undone.lines[0].commission_minor, docs)
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


def _gives_back(charge: int, back: int, docs: dict[str, MandateDocuments]) -> None:
    """A collection charged in one run and undone in the next gives back exactly its charge. The
    one exception (third review, a documented bound): an undo that issues a tier regularisation
    invoice (a change of tiered grid re-tiers later collections) on a file at its rounding hold —
    one more open invoice whose VAT rounding the reserve must cover — gives back up to one cent
    more or less than the charge, released at the file's next collection."""
    regularised = any(
        il.kind == "regularisation" for d in docs.values() if d.invoice for il in d.invoice.lines
    )
    if regularised:
        assert abs(back + charge) <= 1, (charge, back)
    else:
        assert back == -charge, (charge, back)


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
    undone, docs = sim.run([_undo(9001, fresh)])
    _gives_back(charged.lines[0].commission_minor, undone.lines[0].commission_minor, docs)
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
    versions=CLAUSES.flatmap(lambda c: terms(on_reversal=c, two_keys=True)),
    lines=histories(max_ops=25, accounts=("F", "G"), interest=True),
    cuts=st.lists(st.integers(0, 60), max_size=10),
    small=st.booleans(),
    tau=st.sampled_from((TAU, NO_VAT)),
)
def test_documents_never_show_a_negative_band_and_credit_the_originals_invoice_first(
    versions: dict[str, list[TermsVersion]],
    lines: list[Line],
    cuts: list[int],
    small: bool,
    tau: Decimal,
) -> None:
    """Across versions and clauses, with reversals of the same run or of earlier ones: every
    invoice line's bands are positive (a re-tiering is its own regularisation line, with no bands;
    third review: a collection undone in its own run is never priced under `credit`, so its band
    never moves twice) and the lines add up to the invoice; under `credit` no invoice charges a
    collection its own run undoes (both lines charged 0, no parts); a reversal's credit goes to
    the invoice that charged its original, and elsewhere only once that invoice charges the key
    nothing more."""
    if small:
        lines = _small(lines)
    files = {"F": _file(), "G": _file(2_000_000, "G")}
    clause = {v.id: v.schedule.basis.on_reversal for v in versions["M"]}
    sim = Simulator(files, versions, tau)
    for run in _runs(lines, cuts):
        originals = {k: str(chain(v)[0]) for k, v in sim.line_invoices.items()}  # no cancellation
        result, docs = sim.run(run)
        by_entry = {r.entry_id: r for r in result.lines}
        invoiced = {e for d in docs.values() if d.invoice for e in d.invoice.entries}
        for r in result.lines:
            undone = by_entry.get(r.original_entry_id or "")
            if undone is not None and clause[r.terms_id or ""] == "credit":
                assert r.commission_minor == undone.commission_minor == 0, (r, undone)
                assert not r.parts and not undone.parts and undone.entry_id not in invoiced
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


# -- event order, same-run pairs, a change of VAT rate (third review) ------------------------------


def _positions(history: dict[Key, KeyState]) -> dict[Key, tuple[Any, int, int]]:
    """What no split into runs may change: the tier positions, the kept basis and the kept fee
    (V may differ by the rounding hold)."""
    return {
        k: (s.basis, s.kept_basis_minor, s.kept_minor)
        for k, s in history.items()
        if s.basis or s.kept_basis_minor or s.kept_minor
    }


@settings(max_examples=300, deadline=None)
@given(
    versions=st.sampled_from(("keep", "mixed")).flatmap(
        lambda c: terms(on_reversal=c, two_keys=True)
    ),
    lines=histories(max_ops=25, accounts=("F", "G"), interest=True),
    cuts=st.lists(st.integers(0, 60), max_size=10),
    small=st.booleans(),
)
def test_keep_one_run_or_any_split_of_the_same_events(
    versions: dict[str, list[TermsVersion]], lines: list[Line], cuts: list[int], small: bool
) -> None:
    """Under `keep` (and a mandate whose clause changes across versions) the kept fee is what a
    reversal would give back when it happens, so the order of the events matters — never how
    that sequence is cut into runs (third review: lines were taken in encaissement-date order, so a
    bounce, which carries its collection's date, came before a later collection in one run and
    after it in two). One run over the events gives the same tier positions, kept basis and fee,
    and schedule K as any split into consecutive runs; with no VAT, the same charge."""
    if small:
        lines = _small(lines)
    files = {"F": _file(), "G": _file(2_000_000, "G")}
    events = sorted(lines, key=Line.event_key)
    for tau in (TAU, NO_VAT):
        once = Simulator(files, versions, tau)
        once.run(events)
        split = Simulator(files, versions, tau)
        for run in _runs(events, cuts):
            split.run(run)
        assert _positions(split.history) == _positions(once.history)
        target = _nonzero(_targets(split.history, files, versions, tau))
        assert target == _nonzero(_targets(once.history, files, versions, tau))
        if tau == NO_VAT:
            assert _nonzero({k: s.commission_minor for k, s in split.history.items()}) == target
            assert _nonzero({k: s.commission_minor for k, s in once.history.items()}) == target


def _keep(rate: dict[str, Any], **rule: Any) -> dict[str, list[TermsVersion]]:
    schedule = CommissionSchedule.model_validate(
        {
            "schema": "commission-1",
            "basis": {**BASIS, "on_reversal": "keep"},
            "rules": [
                {"id": "r", "tier_key": "k", "label_fr": "R", "match": {}, "rate": rate, **rule}
            ],
        }
    )
    return _one_version(schedule)


def _marginal(*tiers: tuple[str | None, str]) -> dict[str, Any]:
    return {"kind": "marginal", "tiers": [{"up_to_minor": u, "rate": r} for u, r in tiers]}


@pytest.mark.parametrize(
    ("versions", "amount", "expected"),
    [
        (_keep({"kind": "flat", "rate": "0.01"}, min_per_file_minor="30000"), 100_000, 30_000),
        (_keep(_marginal(("500000", "0.10"), (None, "0.05"))), 500_000, 75_000),
    ],
)
def test_keep_a_bounce_after_a_later_collection(
    versions: dict[str, list[TermsVersion]], amount: int, expected: int
) -> None:
    """The review's case: X collected on 02/11 (run 1), Y on 20/11, X's cheque bounces on 12/12.
    Y and the bounce in one run or in two: the same commission (1 % with a 300,00 € minimum:
    300,00 €, not 310,00 €; 10 % to 5 000,00 € then 5 %: 750,00 €, not 1 000,00 €) — the bounce
    keeps what X would give back after Y, as it happened."""
    for tau in (NO_VAT, TAU):
        out = []
        for split in (False, True):
            sim = Simulator({"F": _file()}, versions, tau)
            x = _line(1, amount, date(2026, 11, 2))
            sim.run([x])
            y = _line(2, amount, date(2026, 11, 20))
            bounce = replace(
                _undo(3, x),
                effective_date=date(2026, 12, 12),
                posted_at=datetime(2026, 12, 12, 9, tzinfo=UTC),
            )
            for run in [[y], [bounce]] if split else [[y, bounce]]:
                sim.run(run)
            out.append(schedule_commission(sim.history[("F", "k")], _file(), "k", versions, tau))
            if tau == NO_VAT:
                assert sim.history[("F", "k")].commission_minor == expected
        assert out == [expected, expected], (tau, out)


@pytest.mark.parametrize(
    ("versions", "amount", "expected"),
    [
        (_keep({"kind": "flat", "rate": "0.01"}, min_per_file_minor="30000"), 100_000, 31_000),
        (_keep(_marginal(("500000", "0.10"), (None, "0.05"))), 500_000, 100_000),
    ],
)
def test_keep_a_collection_matched_after_a_bounce(
    versions: dict[str, list[TermsVersion]], amount: int, expected: int
) -> None:
    """Final review: X collected on 02/11 (run 1); X's cheque bounces, posted 12/12; Y was booked by
    the bank on 10/12 but matched by ops and posted on 15/12. Runs are cut in posting order (the
    pending queue), so the bounce comes first: one run or two, the same commission (1 % with a
    300,00 € minimum: 310,00 €; 10 % to 5 000,00 € then 5 %: 1 000,00 €). Sorting a run by
    effective date instead put Y before the bounce in one run only (300,00 € / 750,00 €)."""
    for tau in (NO_VAT, TAU):
        out = []
        for split in (False, True):
            sim = Simulator({"F": _file()}, versions, tau)
            x = _line(1, amount, date(2026, 11, 2))
            sim.run([x])
            bounce = replace(
                _undo(2, x),
                effective_date=date(2026, 12, 12),
                posted_at=datetime(2026, 12, 12, 12, tzinfo=UTC),
            )
            y = replace(
                _line(3, amount, date(2026, 12, 10)),
                effective_date=date(2026, 12, 10),
                posted_at=datetime(2026, 12, 15, 12, tzinfo=UTC),
            )
            for run in [[bounce], [y]] if split else [[bounce, y]]:
                sim.run(run)
            out.append(sim.history[("F", "k")].commission_minor)
        assert out == [expected, expected], (tau, out)


def test_a_kept_reversal_between_a_credit_pair_keeps_the_same_fee() -> None:
    """A mandate whose clause changes: v1 `keep`, v2 `credit`, both 10 % to 5 000,00 € then 5 %.
    A 5 000,00 € under v1 (run 1); then X 5 000,00 € under v2, A bounces, X is undone. However
    the last three fall into runs, A keeps 250,00 € (what it would give back with X live, X now in
    the first tier) and X gives back its 500,00 €: 250,00 € in all. In one run X and its reversal
    are never priced, so the kept fee is taken with X's basis live between them (third review)."""
    grid = _marginal(("500000", "0.10"), (None, "0.05"))
    rule = {"id": "r", "tier_key": "k", "label_fr": "R", "match": {}, "rate": grid}
    credit = CommissionSchedule.model_validate(
        {"schema": "commission-1", "basis": BASIS, "rules": [rule]}
    )
    change = date(2026, 11, 16)
    versions = {
        "M": [
            TermsVersion("v1", "M", date(2026, 1, 1), change, _keep(grid)["M"][0].schedule),
            TermsVersion("v2", "M", change, None, credit),
        ]
    }
    a = _line(1, 500_000, date(2026, 11, 2))
    x = _line(2, 500_000, date(2026, 11, 20))
    bounce = replace(
        _undo(3, a), effective_date=date(2026, 11, 25), posted_at=datetime(2026, 11, 25, tzinfo=UTC)
    )
    undo_x = _undo(4, x)
    for tau in (NO_VAT, TAU):
        for runs in ([[x, bounce, undo_x]], [[x], [bounce, undo_x]], [[x, bounce], [undo_x]]):
            sim = Simulator({"F": _file()}, versions, tau)
            sim.run([a])
            for run in runs:
                sim.run(run)
            state = sim.history[("F", "k")]
            assert (state.basis, state.kept_minor) == ((), 25_000), (tau, runs)
            assert schedule_commission(state, _file(), "k", versions, tau) == 25_000


def test_a_collection_undone_in_its_own_run_is_never_priced() -> None:
    """The review's cases. (a) 10 %, minimum 30,00 €, τ 0,20: X1 2,40, X2 33,60, X3 1,20, X4
    34,80 € and the reversals of X1, X4, X2 in one run: only X3 is priced — « 10 % sur 1,20 € »
    for 0,99 € (⌊(1,20 - 0,01) / 1,2⌋), not « 10 % sur -32,40 € ». (b) 2 % to 4 000,00 €, then
    10 %: A 1 000,00 € and A2 3 800,00 € earlier; one run with B 500,00 € (dated with them, booked
    later), A undone, then B undone: no invoice (B never charged), a credit note of 84,00 €, A's
    own 20,00 € on A's invoice first."""
    sim = Simulator({"F": _file()}, _one_version(_flat("0.10", min_per_file_minor="3000")), TAU)
    d = date(2026, 3, 2)
    xs = [_line(i, a, d) for i, a in enumerate((240, 3360, 120, 3480), 1)]
    undo = [_undo(10 + n, xs[i]) for n, i in enumerate((0, 3, 1))]  # X1, X4, X2 in that order
    result, docs = sim.run([*xs, *undo])
    assert [(r.entry_id, r.commission_minor, len(r.parts)) for r in result.lines] == [
        ("A00001", 0, 0),
        ("A00002", 0, 0),
        ("A00003", 99, 1),
        ("A00004", 0, 0),
        ("R00010", 0, 0),
        ("R00011", 0, 0),
        ("R00012", 0, 0),
    ]
    invoice = docs["M"].invoice
    assert invoice is not None and docs["M"].credit_note is None
    assert [(il.tiers, il.ht_minor) for il in invoice.lines] == [((("0.10", 120),), 99)]
    assert (invoice.ht_minor, invoice.vat_minor, invoice.entries) == (99, 20, ("A00003",))

    tiered = _one_version(
        CommissionSchedule.model_validate(
            {
                "schema": "commission-1",
                "basis": BASIS,
                "rules": [
                    {
                        "id": "r",
                        "tier_key": "k",
                        "label_fr": "R",
                        "match": {},
                        "rate": _marginal(("400000", "0.02"), (None, "0.10")),
                    }
                ],
            }
        )
    )
    for tau in (NO_VAT, TAU):
        sim = Simulator({"F": _file()}, tiered, tau)
        a, a2 = _line(1, 100_000, d), _line(2, 380_000, d)
        sim.run([a])
        sim.run([a2])
        b = replace(
            _line(3, 50_000, d),
            effective_date=d + timedelta(days=5),
            posted_at=datetime(2026, 3, 7, 12, tzinfo=UTC),
        )
        result, docs = sim.run([b, _undo(4, a), _undo(5, b)])
        assert {r.entry_id: r.commission_minor for r in result.lines} == {
            "A00003": 0,
            "R00004": -8_400,  # 2 % of 3 800,00 = 76,00 against 160,00
            "R00005": 0,
        }
        note = docs["M"].credit_note
        assert docs["M"].invoice is None and note is not None
        assert [(x.original_invoice_id, x.ht_minor) for x in note.allocations] == [
            ("FC-2026-000001", -2_000),
            ("FC-2026-000002", -6_400),
        ]


def test_an_undo_across_a_tiered_grid_change_at_the_hold() -> None:
    """The documented bound (third review): v1 10 %, minimum 50,00 € until 15/11; v2 5 % to 100,00
    € then 10 %, minimum 50,00 €. 52,00 € on 20/11, then 10,00 € dated 10/11, then x = 57,00 €
    dated 10/11 (charged +1,90 €: its own 5,70 € invoiced, 3,80 € of re-tiering credited), then x
    undone: its own 5,70 € credited on its invoice and a regularisation invoice of 3,79 € — one
    more open invoice for the reserve, so it gives back 1,91 €, one cent more than its charge; the
    hold (2 cents) is released at the file's next collection."""
    tiered = CommissionSchedule.model_validate(
        {
            "schema": "commission-1",
            "basis": BASIS,
            "rules": [
                {
                    "id": "r",
                    "tier_key": "k",
                    "label_fr": "R",
                    "match": {},
                    "rate": _marginal(("10000", "0.05"), (None, "0.10")),
                    "min_per_file_minor": "5000",
                }
            ],
        }
    )
    change = date(2026, 11, 16)
    versions = {
        "M": [
            TermsVersion(
                "v1", "M", date(2026, 1, 1), change, _flat("0.10", min_per_file_minor="5000")
            ),
            TermsVersion("v2", "M", change, None, tiered),
        ]
    }
    sim = Simulator({"F": _file()}, versions, TAU)
    sim.run([_line(1, 5_200, date(2026, 11, 20))])
    sim.run([_line(2, 1_000, date(2026, 11, 10))])
    x = _line(3, 5_700, date(2026, 11, 10))
    charged, _ = sim.run([x])
    undone, docs = sim.run([_undo(4, x)])
    assert (charged.lines[0].commission_minor, undone.lines[0].commission_minor) == (190, -191)
    invoice, note = docs["M"].invoice, docs["M"].credit_note
    assert invoice is not None and note is not None
    assert [(il.kind, il.ht_minor) for il in invoice.lines] == [("regularisation", 379)]
    assert [(a.entry_id, a.ht_minor) for a in note.allocations] == [("R00004", -570)]
    _gives_back(190, -191, docs)
    state = sim.history[("F", "k")]
    assert schedule_commission(state, _file(), "k", versions, TAU) - state.commission_minor == 2
    sim.run([_line(5, 10_000, date(2026, 11, 25))])
    state = sim.history[("F", "k")]
    assert schedule_commission(state, _file(), "k", versions, TAU) == state.commission_minor


RATES = st.sampled_from((Decimal("0"), Decimal("0.055"), Decimal("0.1"), Decimal("0.2")))


@settings(max_examples=300, deadline=None)
@given(
    versions=st.one_of(
        terms(kinds=LINEAR, two_keys=True), schedules(two_keys=True).map(_one_version)
    ),
    lines=histories(max_ops=25, small=True, interest=True),
    rates=st.lists(RATES, min_size=1, max_size=25),
    rising=st.booleans(),
)
def test_after_a_vat_rate_change_a_run_of_collections_never_credits(
    versions: dict[str, list[TermsVersion]],
    lines: list[Line],
    rates: list[Decimal],
    rising: bool,
) -> None:
    """Each line in its own run at its own VAT rate (flat or bracket rates across versions, or any
    grid in one): a run with no reversal never issues a credit note and never lowers what is
    charged — earlier invoices were within the basis at their own rate when issued (third review:
    the new rate's cap and reserve re-applied to them credited 1,51 € on a 0,01 € collection).
    Whether the rate rises or falls, the TTC billed to a file alone on its mandate stays within
    what it brought in: each earlier invoice keeps its own rate in the reserve (M2c-4; before,
    after a fall a capped file was billed 21,65 € for 20,01 €)."""
    if rising:
        rates = sorted(rates)
    sim = Simulator({"F": _file()}, versions, TAU)
    billed = 0
    for n, ln in enumerate(lines):
        sim.vat_rate = rates[min(n, len(rates) - 1)] if rising else rates[n % len(rates)]
        before = {k: s.commission_minor for k, s in sim.history.items()}
        _, docs = sim.run([ln])
        for d in docs.values():
            billed += (d.invoice.ttc_minor if d.invoice else 0) + (
                d.credit_note.ttc_minor if d.credit_note else 0
            )
        if ln.kind is LineKind.ALLOCATION:
            assert all(d.credit_note is None for d in docs.values()), docs
            assert all(s.commission_minor >= before.get(k, 0) for k, s in sim.history.items())
        assert billed <= sum(s.basis_minor for s in sim.history.values()), (billed, rates)


def test_after_a_fall_of_the_vat_rate_a_capped_file_stays_within_its_basis() -> None:
    """The gap M2c-3 left (CALCULATION_RULES §7): a 20,00 € minimum on a file that brought in
    20,01 € is capped (HT 16,66 €, TTC 19,99 € at 20 %); after the rate falls to 5,5 %, a 0,01 €
    collection was charged 2,29 € more HT at 5,5 % (22,41 € billed for 20,02 €). Each earlier
    invoice now keeps its own rate in the reserve: nothing more is charged."""
    versions = _one_version(_flat("0.0100", min_per_file_minor="2000"))
    sim = Simulator({"F": _file()}, versions, TAU)
    _, docs = sim.run([_line(1, 2001, D0)])
    invoice = docs["M"].invoice
    assert invoice is not None
    assert (invoice.ht_minor, invoice.vat_minor, invoice.ttc_minor) == (1666, 333, 1999)
    sim.vat_rate = Decimal("0.055")
    _, docs = sim.run([_line(2, 1, D0 + timedelta(days=3))])
    assert docs == {}  # nothing more fits: TTC stays 19,99 € ≤ 20,02 €
    assert sim.history[("F", "k")].commission_minor == 1666
    sim.vat_rate = TAU  # the rate rises back: the same invoice at its own rate, nothing to credit
    _, docs = sim.run([_line(3, 1_000, D0 + timedelta(days=6))])
    billed = 1999 + sum(d.invoice.ttc_minor for d in docs.values() if d.invoice)
    assert billed <= 2001 + 1 + 1_000
    charges = sim.charges[("F", "k")]
    assert [c.vat_rate for c in charges] == [TAU] * len(charges)


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
    # M2c-5b (review tests-ui#5): the waivers, the chain of invoices and what a cancellation put
    # back on each for the reversal are inputs; a history without them hashes as before
    key = ("F", "k")
    charge = EarlierCharge("FC-1", (2026, 1), 1)
    hashed = {
        "state": inputs_hash(lines, files, versions, {key: state}, TAU),
        "state waived": inputs_hash(
            lines, files, versions, {key: replace(state, waived_minor=1)}, TAU
        ),
        "charge": inputs_hash(lines, files, versions, {}, TAU, {key: [charge]}),
        "charge waived": inputs_hash(
            lines, files, versions, {}, TAU, {key: [replace(charge, waived_minor=1)]}
        ),
        "own": inputs_hash(undo, files, versions, {}, TAU, line_invoices={first: "FC-6"}),
        "chain": inputs_hash(
            undo, files, versions, {}, TAU, line_invoices={first: ("FC-6", "FC-1")}
        ),
        "retake": inputs_hash(
            undo,
            files,
            versions,
            {},
            TAU,
            line_invoices={first: (Retake("FC-6", ((key, 100),)), "FC-1")},
        ),
        "retake cap": inputs_hash(
            undo,
            files,
            versions,
            {},
            TAU,
            line_invoices={first: (Retake("FC-6", ((key, 101),)), "FC-1")},
        ),
        "retake key": inputs_hash(
            undo,
            files,
            versions,
            {},
            TAU,
            line_invoices={first: (Retake("FC-6", ((("F", "kp"), 100),)), "FC-1")},
        ),
    }
    assert len(set(hashed.values())) == len(hashed), hashed
    assert inputs_hash(
        undo, files, versions, {}, TAU, line_invoices={first: ("FC-1",)}
    ) == inputs_hash(undo, files, versions, {}, TAU, line_invoices={first: "FC-1"})
    # pinned: the hash of a history without manual credit notes is the one M2c-4 drew
    assert (
        inputs_hash(undo, files, versions, {key: state}, TAU, {key: [charge]}, {first: "FC-1"})
        == "1578d3f485633812740070e2fd446bf4f0b8c26d7cc47262d3d527f632058b09"
    )  # main, M2c-5


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
    # a reversal of a collection of the same run mirrors it (third review: such a pair is taken
    # out before pricing, so it must leave K unchanged), and an entry is undone once
    undo = _undo(2, ok)
    with pytest.raises(CommissionInputError, match="undone twice"):
        compute([ok, undo, replace(undo, entry_id="R2")], files, versions, {}, TAU)
    with pytest.raises(CommissionInputError, match="minus its original"):
        compute([ok, replace(undo, basis={"principal": -1})], files, versions, {}, TAU)
    with pytest.raises(CommissionInputError, match="of its own file"):
        compute([ok, replace(undo, kind=LineKind.FORWARD_REVERSAL)], files, versions, {}, TAU)
    later = {
        "M": [
            TermsVersion("a", "M", D0, D0 + timedelta(days=1), _flat()),
            TermsVersion("b", "M", D0 + timedelta(days=1), None, _flat()),
        ]
    }
    moved = replace(undo, encaissement_date=D0 + timedelta(days=1))
    with pytest.raises(CommissionInputError, match="original's terms version"):
        compute([ok, moved], files, later, {}, TAU)
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


def test_an_invoice_line_never_shows_a_negative_band() -> None:
    """The documents' guard (third review): a commission line whose bands net below 0 is an
    engine error, refused (the commission stays pending) rather than issued."""
    part = Part("F", "k", "r", "R", ("principal",), 100, 0, 100, 10, (("0.1", -100),), False, False)
    line = LineCommission("A1", LineKind.ALLOCATION, "F", "M", "v", "charged", None, 10, (part,))
    with pytest.raises(CommissionInputError, match="negative band"):
        run_documents([line], {"F": _file()}, {}, {}, TAU)


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


# -- manual credit notes: the waiver per (invoice, file, tier key) (M2c-5b) -----------------------


Plan = list[
    tuple[int, int, int, bool]
]  # (after run n, invoice pick, ‱ of its remaining HT, one file)


@st.composite
def credit_plans(draw: st.DrawFn, runs: int = 12) -> Plan:
    """Manual credit notes between runs: after which run, on which invoice still open, how much of
    what it still charges (at least a cent), on the whole invoice or on one of its files."""
    return draw(
        st.lists(
            st.tuples(
                st.integers(0, runs),
                st.integers(0, 10**6),
                st.integers(1, 10_000),
                st.booleans(),
            ),
            max_size=6,
        )
    )


def _open_invoices(sim: Simulator) -> list[str]:
    return sorted(n for n, inv in sim.invoices.items() if inv.ht_minor - inv.credited_ht_minor > 0)


def _credit(
    sim: Simulator, pick: int, share: int, one_file: bool, exclude: frozenset[str] = frozenset()
) -> bool:
    """One manual credit note as `credit_plans` drew it (none when no invoice is open; never on
    `exclude`, the invoices of a run still in flight: refused as `run_in_flight`): issued?"""
    open_ = [n for n in _open_invoices(sim) if n not in exclude]
    if not open_:
        return False
    number = open_[pick % len(open_)]
    by_file: dict[str, int] = defaultdict(int)
    for (owner, _), cs in sim.charges.items():
        for c in cs:
            if c.invoice_id == number:
                by_file[owner] += c.open_minor
    account: str | None = None
    if one_file:
        files = sorted(a for a, o in by_file.items() if o > 0)
        account = files[pick % len(files)]
    remaining = by_file[account] if account else sum(by_file.values())
    sim.manual_credit(number, max(1, remaining * share // 10_000), account)
    return True


def _invariants(sim: Simulator) -> None:
    """Σ open charges + Σ waivers = V for every key; each (invoice, key)'s waiver within what it
    charged net of the engine's credits; nothing credited beyond what an invoice charged."""
    for key, state in sim.history.items():
        cs = sim.charges.get(key, [])
        assert sum(c.open_minor + c.waived_minor for c in cs) == state.commission_minor, key
        assert sum(c.waived_minor for c in cs) == state.waived_minor >= 0, key
        for c in cs:
            assert c.waived_minor >= 0 and c.open_minor >= 0, (key, c)
            assert 0 <= c.credited_minor <= c.charged_minor, (key, c)
    for inv in sim.invoices.values():
        assert 0 <= inv.credited_ht_minor <= inv.ht_minor
        assert sim.vat_credited.get(inv.invoice_id, 0) <= sim.invoice_vat[inv.invoice_id]


def _charged_state(history: dict[Key, KeyState]) -> dict[Key, tuple[Any, int, int, int]]:
    """What the engine charges from (the waiver aside: a twin without manual credit notes)."""
    return {
        k: (s.basis, s.kept_basis_minor, s.kept_minor, s.commission_minor)
        for k, s in history.items()
        if s.basis or s.kept_minor or s.commission_minor
    }


def _state_of(history: dict[Key, KeyState]) -> dict[Key, tuple[Any, int, int, int, int]]:
    """A key's whole state: what the engine charges from and its waiver (review math#0)."""
    return {
        k: (s.basis, s.kept_basis_minor, s.kept_minor, s.commission_minor, s.waived_minor)
        for k, s in history.items()
        if s.basis or s.kept_minor or s.commission_minor or s.waived_minor
    }


def _per_invoice(sim: Simulator) -> dict[tuple[str, Key], tuple[int, int]]:
    """Per (invoice, key) with anything on it: (what it still charges, its waiver)."""
    return {
        (c.invoice_id, k): (c.open_minor, c.waived_minor)
        for k, cs in sim.charges.items()
        for c in cs
        if c.open_minor or c.waived_minor
    }


def _takes(d: MandateDocuments | None) -> dict[tuple[str, Key], list[int]]:
    """Per (earlier invoice, key): what a run credits on it and what its waiver absorbs."""
    took: dict[tuple[str, Key], list[int]] = defaultdict(lambda: [0, 0])
    for a in d.credit_note.allocations if d and d.credit_note else ():
        took[(a.original_invoice_id, (a.account_id, a.tier_key))][0] -= a.ht_minor
    for w in d.absorbed if d else ():
        took[(w.invoice_id, (w.account_id, w.tier_key))][1] += w.amount_minor
    return took


@settings(max_examples=300, deadline=None)
@given(
    versions=terms(on_reversal="mixed", two_keys=True),
    lines=histories(max_ops=25, accounts=("F", "G"), interest=True),
    cuts=st.lists(st.integers(0, 60), max_size=10),
    plan=credit_plans(),
    small=st.booleans(),
    rates=st.lists(RATES, max_size=12),
)
def test_a_manual_credit_note_never_changes_what_the_engine_charges(  # noqa: PLR0913, PLR0917
    versions: dict[str, list[TermsVersion]],
    lines: list[Line],
    cuts: list[int],
    plan: Plan,
    small: bool,
    rates: list[Decimal],
) -> None:
    """Manual credit notes between runs, beside a twin without them: after every step Σ open
    charges + Σ waivers = V for every key; V, the tier positions and the kept fees stay the twin's
    (the waiver is invisible: no later collection re-charges a waived amount, whatever the
    partition); a run's invoices are the twin's to the cent, and each credit the twin issues is
    absorbed by the waiver first, then credited, on the same invoice and key, never beyond its
    remaining HT. The VAT rate changes between runs (review tests-ui#1): after a fall, the cap and
    the reserve weigh each open invoice at its own rate, its waiver included."""
    if small:
        lines = _small(lines)
    files = {"F": _file(), "G": _file(2_000_000, "G")}
    sim = Simulator(files, versions, TAU)
    twin = Simulator(files, versions, TAU)
    runs = _runs(lines, cuts)
    alias: dict[str, str] = {}  # the sim's invoice number → the twin's (manual credits: numbered)
    for n, run in enumerate(runs):
        for at, pick, share, one_file in plan:
            if at == n:
                _credit(sim, pick, share, one_file)
                _invariants(sim)
        waived = {(c.invoice_id, k): c.waived_minor for k, cs in sim.charges.items() for c in cs}
        opened = {(c.invoice_id, k): c.open_minor for k, cs in sim.charges.items() for c in cs}
        if n < len(rates):
            sim.vat_rate = twin.vat_rate = rates[n]
        _, docs = sim.run(run)
        _, twin_docs = twin.run(run)
        assert sim.last is not None and twin.last is not None
        for mandate, (number, _) in sim.last[3].items():
            alias[number] = twin.last[3][mandate][0]
        _invariants(sim)
        assert _charged_state(sim.history) == _charged_state(twin.history)
        assert set(docs) <= set(twin_docs)
        for mandate, t in twin_docs.items():
            d = docs.get(mandate)
            inv = d.invoice if d else None
            assert (inv.ht_minor if inv else 0) == (t.invoice.ht_minor if t.invoice else 0)
            took = _takes(d)
            assert {(alias[i], k): c + w for (i, k), (c, w) in took.items()} == {
                k: c for k, (c, _) in _takes(t).items()
            }
            for k, (credited, absorbed) in took.items():
                assert credited <= opened[k] and absorbed <= waived[k], k
                if credited:  # the waiver first
                    assert absorbed == waived[k], k
    for at, pick, share, one_file in plan:
        if at >= len(runs):
            _credit(sim, pick, share, one_file)
    _invariants(sim)
    if all(v.schedule.basis.on_reversal == "credit" for v in versions["M"]):
        # whatever the partition (under `keep` the events' order matters, never the split)
        once = compute(lines, files, versions, {}, TAU)
        assert _nonzero(_targets(sim.history, files, versions, TAU)) == _nonzero(
            _targets(once.history, files, versions, TAU)
        )


@settings(max_examples=300, deadline=None)
@given(
    schedule=schedules(two_keys=True),
    lines=histories(max_ops=15, interest=True),
    plan=credit_plans(runs=1),
    more=st.lists(st.integers(1, 1_000_000), min_size=1, max_size=4),
    seed=st.integers(0, 2**32),
)
def test_a_waived_amount_is_never_charged_again(
    schedule: CommissionSchedule,
    lines: list[Line],
    plan: Plan,
    more: list[int],
    seed: int,
) -> None:
    """After manual credit notes, inside one version (no re-tiering), a run of collections only
    invoices exactly what it adds to the schedule's commission, keeps every waiver and issues no
    credit note; the same run in any order of its lines gives the same pricing. (Across versions
    the first property compares every run with a twin without manual credit notes.)"""
    files = {"F": _file()}
    versions = _one_version(schedule)
    sim = Simulator(files, versions, TAU)
    sim.run(lines)
    for _, pick, share, one_file in plan:
        _credit(sim, pick, share, one_file)
    waived = {k: s.waived_minor for k, s in sim.history.items()}
    collections = [_line(8000 + i, a, D0 + timedelta(days=a % 300)) for i, a in enumerate(more)]
    shuffled = list(collections)
    random.Random(seed).shuffle(shuffled)
    other = compute(
        shuffled,
        files,
        versions,
        sim.history,
        TAU,
        charges=sim.charges,
        line_invoices=sim.line_invoices,
    )
    before = {k: s.commission_minor for k, s in sim.history.items()}
    result, docs = sim.run(collections)
    assert other.lines == result.lines and other.history == result.history
    assert all(d.credit_note is None and not d.absorbed for d in docs.values())
    assert {k: s.waived_minor for k, s in sim.history.items() if k in waived} == waived
    charged = sum(d.invoice.ht_minor for d in docs.values() if d.invoice)
    assert charged == sum(s.commission_minor - before.get(k, 0) for k, s in sim.history.items())


@settings(max_examples=300, deadline=None)
@given(scenario=scenarios(), plan=credit_plans(runs=8))
def test_with_waivers_a_full_reversal_leaves_every_invoice_closed(
    scenario: tuple[dict[str, list[TermsVersion]], list[list[Line]]], plan: Plan
) -> None:
    """Everything undone at the end, manual credit notes along the way: every file back to 0 with
    no waiver left, every invoice credited in full by its manual and run credit notes together,
    their VAT exactly the invoice's (nothing left pending)."""
    versions, runs = scenario
    files = {"F": _file(), "G": FileFacts("G", "M", "rent", "P", boarded_amount_minor=2_000_000)}
    sim = Simulator(files, versions, TAU)
    for n, run in enumerate(runs):
        for at, pick, share, one_file in plan:
            if at == n:
                _credit(sim, pick, share, one_file)
        sim.run(run)
        _invariants(sim)
    assert all(
        s.commission_minor == 0 and s.basis_minor == 0 and s.waived_minor == 0
        for s in sim.history.values()
    )
    for number, inv in sim.invoices.items():
        assert inv.credited_ht_minor == inv.ht_minor, number
        assert sim.vat_credited.get(number, 0) == sim.invoice_vat[number], number
    assert all(c.open_minor == 0 and c.waived_minor == 0 for cs in sim.charges.values() for c in cs)


@settings(max_examples=400, deadline=None)
@given(
    versions=terms(two_keys=True),
    lines=histories(max_ops=20, accounts=("F", "G"), interest=True),
    cuts=st.lists(st.integers(0, 60), max_size=4),
    rates=st.lists(RATES, min_size=1, max_size=5),
    before=credit_plans(runs=4),
    after=credit_plans(runs=0),
)
def test_with_waivers_a_cancellation_then_the_run_again_is_the_run_never_approved(  # noqa: PLR0913, PLR0917
    versions: dict[str, list[TermsVersion]],
    lines: list[Line],
    cuts: list[int],
    rates: list[Decimal],
    before: Plan,
    after: Plan,
) -> None:
    """Runs at changing VAT rates with manual credit notes between them, then a run R, manual credit
    notes on earlier invoices while R is in flight (never on R's own: `run_in_flight`), R cancelled
    (M2c-4 C7 with the waivers) and run again (review math#0): after the cancellation every key is
    back to its state before R, its waiver what its invoices hold (Σ open + Σ waived = V); after the
    run again every key's state — V and the waiver included — and every earlier invoice's open
    charge and waiver per key are those of R never cancelled, and every corrective invoice is
    credited in full with nothing waived left on it: each reversal took back, on each corrective
    invoice, exactly what the cancelled run took for it at that rate (pooled across reversals,
    invoices at several rates, a waiver restored on the corrective invoice of its rate)."""
    files = {"F": _file(), "G": _file(2_000_000, "G")}
    sim = Simulator(files, versions, rates[0])
    runs = _runs(lines, cuts)
    *heads, run = runs
    if not run:
        return
    for n, head in enumerate(heads):
        sim.vat_rate = rates[n % len(rates)]
        if head:
            sim.run(head)
        for at, pick, share, one_file in before:
            if at == n:
                _credit(sim, pick, share, one_file)
    sim.vat_rate = rates[-1]
    charged_before = _charged_state(sim.history)
    state_before, invoices_before = _state_of(sim.history), _per_invoice(sim)
    sim.run(run)
    assert sim.last is not None
    own = frozenset(number for number, _ in sim.last[3].values())
    for _, pick, share, one_file in after:
        _credit(sim, pick, share, one_file, exclude=own)
    never_cancelled = copy.deepcopy(sim)
    corrective = sim.cancel_last()
    _invariants(sim)
    assert _charged_state(sim.history) == charged_before
    if not corrective and not after:
        # nothing credited (every take absorbed, or no credit at all): no corrective invoice, and
        # the files exactly as before the run — its waivers where they were (review math#1)
        assert _state_of(sim.history) == state_before
        assert {x: v for x, v in _per_invoice(sim).items() if x[0] not in own} == invoices_before
    sim.run(run)
    _invariants(sim)
    assert _state_of(sim.history) == _state_of(never_cancelled.history)
    again = _per_invoice(sim)
    earlier = {
        x: v for x, v in _per_invoice(never_cancelled).items() if x[0] not in own | set(corrective)
    }
    assert {x: v for x, v in again.items() if x[0] in {i for i, _ in earlier}} == earlier
    assert not any(i in corrective for i, _ in again)  # each corrective invoice credited in full
    for number in corrective:
        assert sim.vat_credited.get(number, 0) == sim.invoice_vat[number], number


def _taken_per_line(docs: dict[str, MandateDocuments]) -> dict[tuple[Key, str], int]:
    """Per (key, line): what a run takes back from earlier invoices, credited or absorbed."""
    out: dict[tuple[Key, str], int] = defaultdict(int)
    for d in docs.values():
        for a in d.credit_note.allocations if d.credit_note else ():
            out[((a.account_id, a.tier_key), a.entry_id)] -= a.ht_minor
        for w in d.absorbed:
            out[((w.account_id, w.tier_key), w.entry_id)] += w.amount_minor
    return out


Recancel = tuple[
    dict[str, list[TermsVersion]], list[Decimal], list[list[Line]], list[Line], Decimal, Plan
]


@st.composite
def rerun_cases(draw: st.DrawFn) -> Recancel:
    """Files F, G, H on one tier key (any rates, a minimum half the time), each with at most two
    collections, spread over one to four runs at their own VAT rates (manual credit notes between
    them); then a run R undoing at most one collection per file, and the VAT rate τ of R again.
    So each key has at most two invoices and one reversal: what R takes back for it is its own
    invoice's, then the other's — at their own rates, never interleaved with another reversal."""
    minimum = draw(st.none() | st.integers(0, 50_000))  # small files: where the cap binds
    rule = {"id": "r", "tier_key": "k", "label_fr": "Règle", "match": {}, "rate": draw(rate_docs())}
    if minimum is not None:
        rule["min_per_file_minor"] = str(minimum)
    schedule = {"schema": "commission-1", "basis": BASIS, "rules": [rule]}
    versions = _one_version(CommissionSchedule.model_validate(schedule))
    rates = draw(st.lists(RATES, min_size=1, max_size=4))
    runs: list[list[Line]] = [[] for _ in rates]
    undo: list[Line] = []
    n = 0
    for account in ("F", "G", "H"):
        mine = []
        for _ in range(draw(st.integers(0, 2))):
            amount = draw(st.integers(1, 400) | st.integers(1, 5_000) | st.integers(1, 10**6))
            e = D0 + timedelta(days=draw(st.integers(0, 300)))
            ln = _line(n, amount, e, account=account)
            n += 1
            runs[draw(st.integers(0, len(rates) - 1))].append(ln)
            mine.append(ln)
        undone = draw(st.booleans())
        if mine and undone:
            undo.append(_undo(9000 + n, mine[draw(st.integers(0, len(mine) - 1))]))
    tau = draw(RATES.filter(lambda t: t != rates[-1]))  # the same rate: the property above
    return versions, rates, runs, undo, tau, draw(credit_plans(runs=len(rates)))


# a small file under a 5 000,00 € minimum (the TTC cap binds): 92,00 € collected at 0 % VAT, then
# 33,00 € at 20 %; the run undoing the second takes 12,15 € back from its own invoice and 15,35 € by
# LIFO from the first, is cancelled, and runs again at 0 % for 12,16 €: taken from where the
# cancelled run took first (its own invoice's share, at 20 %), V is that of the run never approved
# within a cent; taken from the 0 % corrective invoice first (the integrated fix's number order),
# 89,54 € instead of 91,99 € (review round 2, math#0)
_FIRST, _SECOND = _line(1, 9_200, D0, account="H"), _line(2, 3_300, D0, account="H")
_RATE_BACK: Recancel = (
    _one_version(
        CommissionSchedule.model_validate(
            {
                "schema": "commission-1",
                "basis": BASIS,
                "rules": [
                    {
                        "id": "r",
                        "tier_key": "k",
                        "label_fr": "Règle",
                        "match": {},
                        "rate": {"kind": "flat", "rate": "0.1"},
                        "min_per_file_minor": "500000",
                    }
                ],
            }
        )
    ),
    [NO_VAT, TAU],
    [[_FIRST], [_SECOND]],
    [_undo(9, _SECOND)],
    NO_VAT,
    [],
)


@settings(max_examples=1500, deadline=None)
@given(case=rerun_cases())
@example(case=_RATE_BACK)
def test_with_waivers_a_cancellation_then_another_vat_rate_stays_within_the_reserve_of_the_run_never_approved(  # noqa: E501
    case: Recancel,
) -> None:
    """A run R, cancelled, the VAT rate set to τ and R again, against R never approved (the same
    history and manual credit notes, τ, then R once; review round 2). At the same rate R again is
    that run exactly. At another rate the cap and the reserve change what R credits, and R again
    takes each reversal's credit back where the cancelled run took it, in the order it took it
    (`retake_links`: its own invoice's share first) — so whatever share the new rate leaves, it
    comes off the invoices R never approved takes it from, at their VAT rates. Per (file, tier key):

        |ΔV| ≤ n + 1        |ΔW| ≤ |ΔV| (+ D when two of its invoices share a VAT rate)

    n the invoices still charging the key before R again: the cancellation leaves its charge on
    the corrective invoice as well as on the invoices it credited in part, and the reserve holds
    one cent per open invoice (plus the run's own); W moves with V's cent; and where both invoices
    the cancelled run took from bear one rate, its corrective invoice pools them — the charge one
    held and the waiver the other held — so of D (Σ |what the cancelled run took back for the
    reversal - what R again takes back|) the waiver absorbs first what the never-approved run
    credits. Taken in another order (the corrective invoices by number), the share left falls on
    the other rate: the TTC the mixed-rate cap weighs moves by its amount times the gap in rates,
    far beyond n + 1 (the integrated M2c-5b fix: gen2 seed 1896, 0,45 €)."""
    versions, rates, runs, undo, tau, plan = case
    if not undo:
        return
    files = {"F": _file(), "G": _file(2_000_000, "G"), "H": _file(1_000, "H")}
    sim = Simulator(files, versions, rates[0])
    for n, run in enumerate(runs):
        sim.vat_rate = rates[n]
        if run:
            sim.run(run)
        for at, pick, share, one_file in plan:
            if at == n:
                _credit(sim, pick, share, one_file)
    never = copy.deepcopy(sim)
    _, cancelled = sim.run(undo)
    sim.cancel_last()
    sim.vat_rate = never.vat_rate = tau
    still = {
        k: sum(1 for c in cs if c.open_minor + c.waived_minor) for k, cs in sim.charges.items()
    }
    _, again = sim.run(undo)
    never.run(undo)
    _invariants(sim)
    took, takes = _taken_per_line(cancelled), _taken_per_line(again)
    for key in set(sim.history) | set(never.history):
        a, b = sim.history.get(key, KeyState()), never.history.get(key, KeyState())
        dv, dw = a.commission_minor - b.commission_minor, a.waived_minor - b.waived_minor
        assert abs(dv) <= still.get(key, 0) + 1, (key, dv)
        moved = sum(abs(took[x] - takes[x]) for x in set(took) | set(takes) if x[0] == key)
        taken_on = {i for (i, k) in _takes(cancelled.get("M")) if k == key}
        shared = len({never.invoices[i].vat_rate for i in taken_on}) < len(taken_on)
        assert abs(dw) <= abs(dv) + (moved if shared else 0), (key, dw, dv, moved)


def test_retake_links_come_in_the_order_the_cancelled_run_took() -> None:
    """Review round 2 (math#0): a reversal's links after its run was cancelled follow the order
    that run took what they hold — its chain's invoices first, in the chain's order, then LIFO —
    never the corrective invoices' numbers; a link pooling several takes comes where its first
    came, and holds their sum per (file, tier key)."""
    k, kp = ("F", "k"), ("F", "kp")
    # own invoice FC-2 (20 %) first, then LIFO FC-1 (0 %): the cancellation issued the 0 %
    # corrective FC-4 before the 20 % one, FC-5 — by number, the reverse
    assert retake_links(
        ("FC-2026-000002",),
        [
            ("FC-2026-000004", "FC-2026-000001", (2026, 1), k, 1_600),
            ("FC-2026-000005", "FC-2026-000002", (2026, 2), k, 1_100),
        ],
    ) == (
        Retake("FC-2026-000005", ((k, 1_100),)),
        Retake("FC-2026-000004", ((k, 1_600),)),
    )
    # LIFO newest first; FC-7 pools the own invoice's take (first) and FC-2's (last)
    assert retake_links(
        ("FC-2026-000001",),
        [
            ("FC-2026-000007", "FC-2026-000002", (2026, 2), k, 500),
            ("FC-2026-000006", "FC-2026-000003", (2026, 3), k, 700),
            ("FC-2026-000007", "FC-2026-000001", (2026, 1), kp, 900),
        ],
    ) == (
        Retake("FC-2026-000007", ((k, 500), (kp, 900))),
        Retake("FC-2026-000006", ((k, 700),)),
    )
    # cancelled again: the run had the first cancellation's links, then the own invoice
    prior = (
        Retake("FC-2026-000006", ((k, 300),)),
        Retake("FC-2026-000005", ((k, 400),)),
        "FC-2026-000001",
    )
    assert retake_links(
        prior,
        [
            ("FC-2026-000012", "FC-2026-000009", (2026, 9), k, 100),
            ("FC-2026-000011", "FC-2026-000005", (2026, 5), k, 400),
            ("FC-2026-000010", "FC-2026-000006", (2026, 6), k, 300),
        ],
    ) == (
        Retake("FC-2026-000010", ((k, 300),)),
        Retake("FC-2026-000011", ((k, 400),)),
        Retake("FC-2026-000012", ((k, 100),)),
    )


def _credited(d: MandateDocuments | None) -> list[tuple[str, int]]:
    """A run's credit note, in the order it credits: (invoice credited, HT > 0)."""
    cn = d.credit_note if d else None
    return [(a.original_invoice_id, -a.ht_minor) for a in cn.allocations] if cn else []


def _left_by_rate(sim: Simulator) -> dict[Decimal, tuple[int, int]]:
    """Per VAT rate: the HT its invoices still charge and the VAT still billed on them."""
    out: dict[Decimal, list[int]] = defaultdict(lambda: [0, 0])
    for number, inv in sim.invoices.items():
        left = out[inv.vat_rate]
        left[0] += inv.ht_minor - inv.credited_ht_minor
        left[1] += sim.invoice_vat[number] - sim.vat_credited.get(number, 0)
    return {rate: (ht, vat) for rate, (ht, vat) in out.items() if ht or vat}


def test_a_smaller_credit_run_again_comes_off_the_oldest_invoice_the_cancelled_run_took_from() -> (
    None
):
    """LIFO among a reversal's links beyond its chain (review M2c-5b round 3, gen5 seed 9967: the
    rate down, the LIFO order pinned by no test). A small file under a 5 000,00 € minimum (the TTC
    cap binds): 1 000,00 € collected at 0 % VAT (FC-1), 80,00 € at 5,5 % (FC-2, 23,67 €), 200,00 €
    at 2,1 % (FC-3, 230,00 €). Undone at 20 %, the third takes its own invoice's 230,00 €, then
    LIFO FC-2's 23,67 € and 100,01 € of FC-1, the oldest. Cancelled: FC-5 100,01 € at 0 %, FC-6
    230,00 € at 2,1 %, FC-7 23,67 € at 5,5 %. Run again at 10 %, the cap leaves room for more
    commission and the reversal credits 81,81 € less: the run never approved takes that shortfall
    off FC-1 — the last invoice its LIFO reaches — so the run again takes it off FC-5, FC-1's
    corrective invoice, its links in the order the cancelled run took (FC-6, FC-7, FC-5). With the
    links beyond the chain oldest first (FC-6, FC-5, FC-7: the mutant the round-3 review ran) FC-5
    takes the whole credit left and FC-7 is never credited: 23,67 € HT and 1,30 € of VAT still
    billed at 5,5 %, which the run never approved credits, and V a cent lower."""
    schedule = CommissionSchedule.model_validate(
        {
            "schema": "commission-1",
            "basis": BASIS,
            "rules": [
                {
                    "id": "r",
                    "tier_key": "k",
                    "label_fr": "Règle",
                    "match": {},
                    "rate": {"kind": "flat", "rate": "0.1"},
                    "min_per_file_minor": "500000",
                }
            ],
        }
    )
    key = ("F", "k")
    first, second, third = _line(1, 100_000, D0), _line(2, 8_000, D0), _line(3, 20_000, D0)
    sim = Simulator({"F": _file()}, _one_version(schedule), NO_VAT)
    for rate, line in ((NO_VAT, first), (Decimal("0.055"), second), (Decimal("0.021"), third)):
        sim.vat_rate = rate
        sim.run([line])
    assert {c.invoice_id: c.open_minor for c in sim.charges[key]} == {
        "FC-2026-000001": 100_000,
        "FC-2026-000002": 2_367,
        "FC-2026-000003": 23_000,
    }
    never = copy.deepcopy(sim)
    undo = [_undo(9, third)]
    sim.vat_rate = TAU
    _, cancelled = sim.run(undo)
    assert _credited(cancelled.get("M")) == [
        ("FC-2026-000003", 23_000),  # its own invoice
        ("FC-2026-000002", 2_367),  # then LIFO: the newer invoice, at 5,5 %
        ("FC-2026-000001", 10_001),  # and the older one, at 0 %
    ]
    corrective = sim.cancel_last()
    assert {n: (inv.ht_minor, inv.vat_rate) for n, inv in corrective.items()} == {
        "FC-2026-000005": (10_001, NO_VAT),
        "FC-2026-000006": (23_000, Decimal("0.021")),
        "FC-2026-000007": (2_367, Decimal("0.055")),
    }
    assert sim.line_invoices[third.entry_id] == (
        Retake("FC-2026-000006", ((key, 23_000),)),
        Retake("FC-2026-000007", ((key, 2_367),)),
        Retake("FC-2026-000005", ((key, 10_001),)),
        "FC-2026-000003",
    )
    sim.vat_rate = never.vat_rate = Decimal("0.1")
    _, again = sim.run(undo)
    _, once = never.run(undo)
    _invariants(sim)
    assert _credited(once.get("M")) == [
        ("FC-2026-000003", 23_000),
        ("FC-2026-000002", 2_367),
        ("FC-2026-000001", 1_820),  # 81,81 € less than the cancelled run: off the oldest
    ]
    assert _credited(again.get("M")) == [
        ("FC-2026-000006", 23_000),
        ("FC-2026-000007", 2_367),
        ("FC-2026-000005", 1_820),  # the shortfall off FC-1's corrective invoice
    ]
    assert _state_of(sim.history) == _state_of(never.history)
    assert sim.history[key].commission_minor == 98_180
    assert _left_by_rate(sim) == _left_by_rate(never) == {NO_VAT: (98_180, 0)}


# -- manual credit notes: the allocation over the invoice's keys ----------------------------------


@settings(max_examples=500, deadline=None)
@given(
    opened=st.dictionaries(
        st.tuples(st.sampled_from("ABC"), st.sampled_from(("k", "kp", "ko"))),
        st.integers(0, 10**7),
        min_size=1,
        max_size=6,
    ),
    share=st.integers(1, 10_000),
    one_file=st.booleans(),
    credited=st.integers(0, 10**6),
)
def test_a_manual_credit_is_spread_in_proportion_never_beyond_a_keys_charge(
    opened: dict[Key, int], share: int, one_file: bool, credited: int
) -> None:
    """The HT a manual credit note takes back is spread over what the invoice still charges each
    (file, tier key) in proportion to it (largest remainders), adds up to the amount, never takes
    more than a key's open charge, and its VAT is the cumulative difference at the invoice's rate
    (all its remaining VAT when it credits all the rest)."""
    account = sorted(opened)[0][0] if one_file else None
    total = sum(o for k, o in opened.items() if account is None or k[0] == account)
    inv = EarlierInvoice("FC", sum(opened.values()) + credited, TAU, credited)
    if total == 0:
        with pytest.raises(ManualCreditError):
            manual_credit(inv, opened, 1, account)
        return
    amount = max(1, total * share // 10_000)
    mc = manual_credit(inv, opened, amount, account)
    got = dict(mc.allocations)
    assert sum(got.values()) == amount == mc.ht_minor
    for k, x in got.items():
        assert 0 < x <= opened[k] and (account is None or k[0] == account)
        exact = Decimal(amount * opened[k]) / Decimal(total)
        assert abs(Decimal(x) - exact) < 1  # its share, rounded to a cent either way
    assert mc.vat_minor == vat_of(credited + amount, TAU) - vat_of(credited, TAU)
    if amount == inv.ht_minor - credited:
        assert vat_of(credited, TAU) + mc.vat_minor == vat_of(inv.ht_minor, TAU)
    with pytest.raises(ManualCreditError):
        manual_credit(inv, opened, total + 1, account)
    with pytest.raises(ManualCreditError):
        manual_credit(inv, opened, 0, account)


def test_the_waiver_is_per_invoice_a_reversal_never_takes_another_invoices() -> None:
    """10 % flat. A charged on FC-1 (100,00 €), B on FC-2 (100,00 €); a manual credit note of
    40,00 € on FC-2. Undoing A credits FC-1 in full: FC-2's waiver stays (a waiver held per key
    only would have absorbed 40,00 € of A's credit, the client billed again for B the 40,00 € it
    was given back). Undoing B then: 40,00 € absorbed, 60,00 € credited on FC-2."""
    sim = Simulator({"F": _file()}, _one_version(_flat("0.10")), TAU)
    a, b = _line(1, 100_000, D0), _line(2, 100_000, D0 + timedelta(days=1))
    sim.run([a])
    sim.run([b])
    sim.manual_credit("FC-2026-000002", 4_000)
    assert sim.history[("F", "k")].waived_minor == 4_000
    _, docs = sim.run([_undo(3, a)])
    (d,) = docs.values()
    assert d.credit_note is not None and not d.absorbed
    assert [(c.invoice_id, c.ht_minor) for c in d.credit_note.corrected] == [
        ("FC-2026-000001", -10_000)
    ]
    assert sim.history[("F", "k")].waived_minor == 4_000
    _, docs = sim.run([_undo(4, b)])
    (d,) = docs.values()
    assert [(w.invoice_id, w.amount_minor) for w in d.absorbed] == [("FC-2026-000002", 4_000)]
    assert d.credit_note is not None
    assert [(c.invoice_id, c.ht_minor, c.vat_minor) for c in d.credit_note.corrected] == [
        ("FC-2026-000002", -6_000, -1_200)
    ]
    assert sim.history[("F", "k")] == KeyState(commission_minor=0)
    _invariants(sim)


def test_input_errors_of_the_waiver() -> None:
    """The engine refuses a history whose waivers and open charges do not add up to V."""
    files = {"F": _file()}
    versions = _one_version(_flat("0.10"))
    ok = _line(1, 1_000, D0)
    state = KeyState(basis=(("v", 100_000),), commission_minor=10_000, waived_minor=3_000)
    good = [EarlierCharge("FC-1", (2026, 1), 10_000, 3_000, TAU, waived_minor=3_000)]
    compute([ok], files, versions, {("F", "k"): state}, TAU, charges={("F", "k"): good})
    bad = [
        [EarlierCharge("FC-1", (2026, 1), 10_000, 3_000, TAU)],  # the waivers do not add up
        [EarlierCharge("FC-1", (2026, 1), 10_000, 4_000, TAU, waived_minor=3_000)],  # ≠ V
        [  # a negative waiver
            EarlierCharge("FC-1", (2026, 1), 10_000, 0, TAU, waived_minor=-3_000),
            EarlierCharge("FC-2", (2026, 2), 6_000, 0, TAU, waived_minor=6_000),
        ],
    ]
    for charges in bad:
        with pytest.raises(CommissionInputError):
            compute([ok], files, versions, {("F", "k"): state}, TAU, charges={("F", "k"): charges})
