"""M2c-7f-2 review round 1, VC-3: the prepare gives the engine a key's earlier charges summed
(`ChargeTotals`: per VAT rate, the invoices still charging it and their capacity; the open charges'
and the waivers' sums) unless the run credits it. The engine's result on summed charges is its
result on the same charges one by one — the lines, their parts, the key states and the documents
(the inputs hash names what it was given) —, or it asks for them one by one (`ChargesNeeded`), and
the prepare prices the run again with every key whole (`prepare_run`, `Facts.whole_charges`)."""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Mapping, Sequence
from dataclasses import replace
from datetime import date
from decimal import Decimal
from typing import Any

import pytest
from commission_cases import Simulator
from hypothesis import event, given, settings
from hypothesis import strategies as st
from test_commission import (
    BASIS,
    D0,
    NO_VAT,
    TAU,
    Plan,
    _credit,
    _file,
    _line,
    _one_version,
    credit_plans,
    scenarios,
)
from test_remittance_run import _alloc, _facts, _undo

from collectoo_worker.remittance.commission import (
    ChargesNeeded,
    ChargeTotals,
    FileFacts,
    KeyState,
    Line,
    TermsVersion,
    capacity,
    compute,
)
from collectoo_worker.remittance.documents import EarlierCharge, EarlierInvoice, run_documents
from collectoo_worker.remittance.run import prepare_run
from collectoo_worker.remittance.terms import CommissionSchedule

Key = tuple[str, str]


def summed(charges: Mapping[Key, Sequence[EarlierCharge]]) -> dict[Key, ChargeTotals]:
    """Each key's charges summed as private.remittance_charge_totals sums them."""
    out = {}
    for key, cs in charges.items():
        groups: dict[Decimal | None, list[int]] = defaultdict(lambda: [0, 0])
        for c in cs:
            if capacity(c) > 0:
                groups[c.vat_rate][0] += 1
                groups[c.vat_rate][1] += capacity(c)
        out[key] = ChargeTotals(
            key,
            sum(c.open_minor for c in cs),
            sum(c.waived_minor for c in cs),
            tuple(sorted(((r, n, a) for r, (n, a) in groups.items()), key=lambda g: str(g[0]))),
        )
    return out


def _priced(sim: Simulator, lines: Sequence[Line], charges: Mapping[Key, Any]) -> tuple[Any, Any]:
    result = compute(
        lines,
        sim.files,
        sim.versions,
        sim.history,
        sim.vat_rate,
        charges=charges,
        line_invoices=sim.line_invoices,
    )
    docs = run_documents(
        result.lines, sim.files, charges, sim.invoices, sim.vat_rate, sim.line_invoices
    )
    return result, docs


def _same_run(sim: Simulator, run: Sequence[Line]) -> bool:
    """The run priced on summed charges gives what it gives on them one by one (then the simulator
    runs it): True, or the engine asked for them (`ChargesNeeded`): False."""
    try:
        got, got_docs = _priced(sim, run, summed(sim.charges))
    except ChargesNeeded as exc:
        assert exc.key in sim.charges, exc.key
        sim.run(run)
        return False
    want, want_docs = sim.run(run)
    assert got.lines == want.lines
    assert got.history == want.history
    assert got_docs == want_docs
    return True


@settings(max_examples=300, deadline=None)
@given(scenario=scenarios(), plan=credit_plans(runs=8))
def test_summed_charges_price_a_run_as_its_charges_one_by_one(
    scenario: tuple[dict[str, list[TermsVersion]], list[list[Line]]], plan: Plan
) -> None:
    """Over versions, two files, collections, reversals and manual credit notes (the engine's own
    scenarios), each run priced on the history's charges summed: the same lines, parts, key states
    and documents as on its charges one by one, or `ChargesNeeded` (a credit on a summed key)."""
    versions, runs = scenario
    files = {"F": _file(), "G": FileFacts("G", "M", "rent", "P", boarded_amount_minor=2_000_000)}
    sim = Simulator(files, versions, TAU)
    for n, run in enumerate(runs):
        for at, pick, share, one_file in plan:
            if at == n:
                _credit(sim, pick, share, one_file)
        event("summed" if _same_run(sim, run) else "asked for them one by one")


@settings(max_examples=200, deadline=None)
@given(
    rates=st.lists(st.sampled_from(["0", "0.055", "0.021", "0.1", "0.2"]), min_size=2, max_size=5),
    amounts=st.lists(st.integers(1_000, 120_000), min_size=5, max_size=5),
)
def test_the_reserve_under_mixed_rates_on_summed_charges(
    rates: list[str], amounts: list[int]
) -> None:
    """The rounding reserve under invoices at several VAT rates (`_reserved`'s mixed branch: the
    TTC cap binds a small file under a 5 000,00 € minimum, as the M2c-5b round-3 case): each run of
    one collection, at its own rate, priced on the earlier charges summed per rate, gives what it
    gives on them one by one."""
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
    sim = Simulator({"F": _file()}, _one_version(schedule), NO_VAT)
    for n, (rate, amount) in enumerate(zip(rates, amounts, strict=False), start=1):
        sim.vat_rate = Decimal(rate)
        assert _same_run(sim, [_line(n, amount, D0)])


def test_a_run_crediting_a_summed_key_is_priced_again_whole() -> None:
    """RV-3 of test_remittance_run (a reversal of a collection FC-1 charged): its key given summed,
    the engine asks for its charges one by one; with `whole_charges` the draft is the draft of the
    facts whole (its documents, lines, plan), the inputs hash too (priced on the whole facts);
    without it, the engine's request goes up."""
    e2 = _alloc("E2", 200_000, date(2026, 10, 12))
    e10 = _alloc("E10", 300_000, date(2026, 11, 10), account="F77")
    r_e2 = _undo("RE2", e2, date(2026, 11, 12))
    whole_charges = {("F42", "tout"): [EarlierCharge("FC1", (2026, 1), 30_000, vat_rate=TAU)]}
    whole = {
        "charges": whole_charges,
        "invoices": {"FC1": EarlierInvoice("FC1", 30_000, TAU)},
        "invoice_numbers": {"FC1": ("FC-2026-000001", date(2026, 11, 2))},
    }
    facts = _facts(
        [e10, r_e2],
        number="RV-2026-000003",
        today=date(2026, 11, 16),
        history={("F42", "tout"): KeyState((("T1", 200_000),), commission_minor=30_000)},
        history_seq=1,
        line_invoices={"E2": "FC1"},
        open_documents=[],
        **whole,
    )
    want = prepare_run(facts)
    asked: list[int] = []

    def loader() -> dict[str, Any]:
        asked.append(1)
        return whole

    lazy = replace(
        facts, charges=summed(whole_charges), invoices={}, invoice_numbers={}, whole_charges=loader
    )
    got = prepare_run(lazy)
    assert asked == [1]
    assert (got.lines, got.documents, got.key_states, got.plan, got.header) == (
        want.lines,
        want.documents,
        want.key_states,
        want.plan,
        want.header,
    )
    with pytest.raises(ChargesNeeded):
        prepare_run(replace(lazy, whole_charges=None))
