"""Golden cases of the commission engine `commission-1` (design §8, §18 M2-13; founder #4, #5, #6):
worked examples to the cent in worker/tests/golden/commission/*.yaml — flat; claim-type and family
rates; marginal tiers crossed inside one collection and back; brackets by boarded amount and by age;
the minimum per file, capped, across several runs; a version change; a collection made before a
change undone after it; a minimum introduced or dropped by a new version; a marginal grid change
re-tiering later collections (the regularisation line); the cap across versions; a reversal and a
new collection in one run (a credit note and an invoice); the fee kept by clause, flat and
marginal; forwards; items that earn nothing; a change of the VAT rate between runs; and the §7.2
worked example (RV-2026-000001 … 000003); a descending grid re-tiered down by a late-booked earlier
collection (a credit note whose cause is the re-tiering, not a collection undone); manual credit
notes (M2c-5b): the waiver a later collection never re-charges and a reversal's credit meets first,
held per invoice, spread over two files, and a run cancelled with waivers present. Each run's
lines, then its invoice and credit note per mandate (§8.4) — a credit's cause per corrected invoice,
what a waiver absorbs — with the history carried to the next run. Every case is marked TO VALIDATE
until the founder's anonymised clauses replace the synthetic ones."""

from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from commission_cases import GOLDEN, Simulator, files_of, lines_of, load_case, versions_of

CASES = sorted(GOLDEN.glob("*.yaml"))


def test_the_golden_set() -> None:
    names = {p.stem for p in CASES}
    assert {
        "worked-example-7-2",
        "claim-type-and-family-rates",
        "marginal-tiers-crossed",
        "brackets",
        "minimum-capped",
        "version-change",
        "version-change-partial-reversal",
        "version-change-retiering",
        "minimum-new-version",
        "cross-version-cap",
        "same-run-credit-and-invoice",
        "reversal-keep",
        "reversal-keep-marginal",
        "forwards",
        "none-states",
        "vat-rate-change",
        "retiering-credit-descending",
        "manual-credit-waiver",
        "manual-credit-per-invoice",
        "manual-credit-two-files",
        "manual-credit-cancelled-run",
        "manual-credit-cancel-two-reversals",
        "manual-credit-cancel-all-absorbed",
        "cancel-credit-across-rates",
        "manual-credit-rate-fall",
    } <= names
    for p in CASES:
        case = load_case(p)
        assert case["case"] == p.stem
        assert case["status"] == "TO VALIDATE", (
            "a case is validated only by the founder's golden files"
        )


def _check_lines(result: Any, expect: dict[str, Any], where: str) -> None:
    got = {r.entry_id: r for r in result.lines}
    assert set(got) == set(expect), where
    for entry, want in expect.items():
        r = got[entry]
        assert r.commission_minor == int(want["commission"]), f"{where} {entry}"
        assert r.state == want.get("state", "charged"), f"{where} {entry}"
        assert r.reason == want.get("reason"), f"{where} {entry}"
        if "parts" in want:
            parts = {p.tier_key: p.commission_minor for p in r.parts}
            assert parts == {k: int(v) for k, v in want["parts"].items()}, f"{where} {entry}"
        if "terms" in want:
            assert r.terms_id == want["terms"], f"{where} {entry}"
        if "capped" in want:
            assert any(p.capped for p in r.parts) == want["capped"], f"{where} {entry}"


def _check_documents(docs: Any, expect: dict[str, Any], where: str) -> None:
    assert set(docs) == set(expect), where
    for mandate, want in expect.items():
        d = docs[mandate]
        inv, crn = want.get("invoice"), want.get("credit_note")
        absorbed: dict[str, dict[tuple[str, str], int]] = {}
        for w in d.absorbed:  # M2c-5b: what a manual credit note's waiver absorbs (no document)
            per = absorbed.setdefault(w.invoice_id, {})
            per[(w.account_id, w.tier_key)] = (
                per.get((w.account_id, w.tier_key), 0) + w.amount_minor
            )
        assert absorbed == {
            n: {_key(k): int(v) for k, v in per.items()}
            for n, per in (want.get("absorbed") or {}).items()
        }, f"{where} {mandate}"
        assert (d.invoice is None) == (inv is None), f"{where} {mandate}"
        assert (d.credit_note is None) == (crn is None), f"{where} {mandate}"
        if inv:
            got = (d.invoice.ht_minor, d.invoice.vat_minor, d.invoice.ttc_minor)
            assert got == (int(inv["ht"]), int(inv["vat"]), int(inv["ttc"])), f"{where} {mandate}"
            assert d.invoice.ttc_minor == d.invoice.ht_minor + d.invoice.vat_minor
            if "lines" in inv:
                lines = [
                    {
                        "claim_type": ln.claim_type,
                        "rule": ln.rule_id,
                        "families": list(ln.families),
                        "ht": str(ln.ht_minor),
                        "tiers": [[r, str(b)] for r, b in ln.tiers],
                        "kind": ln.kind,
                    }
                    for ln in d.invoice.lines
                ]
                want_lines = [{"kind": "commission", **ln} for ln in inv["lines"]]
                assert lines == want_lines, f"{where} {mandate}"
        if crn:
            got = (d.credit_note.ht_minor, d.credit_note.vat_minor, d.credit_note.ttc_minor)
            assert got == (int(crn["ht"]), int(crn["vat"]), int(crn["ttc"])), f"{where} {mandate}"
            corrected = {c.invoice_id: (c.ht_minor, c.vat_minor) for c in d.credit_note.corrected}
            assert corrected == {
                k: (int(v["ht"]), int(v["vat"])) for k, v in crn["corrected"].items()
            }, f"{where} {mandate}"
            for c in d.credit_note.corrected:  # each credit's causes sum to its corrected HT
                assert sum(ht for _, ht in c.causes) == c.ht_minor, f"{where} {c.invoice_id}"
            if "causes" in crn:
                causes = {c.invoice_id: dict(c.causes) for c in d.credit_note.corrected}
                assert causes == {
                    k: {cause: int(ht) for cause, ht in v.items()} for k, v in crn["causes"].items()
                }, f"{where} {mandate}"


def _key(text: str) -> tuple[str, str]:
    file, tier = text.split("/")
    return file, tier


def _check_manual_credit(sim: Simulator, want: dict[str, Any], where: str) -> None:
    """A manual credit note (M2c-5b): its HT spread over the invoice's keys, its VAT."""
    credit = sim.manual_credit(want["invoice"], int(want["amount"]), want.get("file"))
    expect = want["expect"]
    assert (credit.ht_minor, credit.vat_minor) == (int(expect["ht"]), int(expect["vat"])), where
    assert dict(credit.allocations) == {
        _key(k): int(v) for k, v in expect["allocations"].items()
    }, where


def _check_state(sim: Simulator, want: dict[str, Any], where: str) -> None:
    """Per (file, tier key): the commission charged (V) and the waiver; Σ open + Σ waived = V."""
    for text, expect in want.items():
        key = _key(text)
        state = sim.history[key]
        assert state.commission_minor == int(expect["commission"]), f"{where} {text}"
        assert state.waived_minor == int(expect.get("waived", "0")), f"{where} {text}"
        charges = sim.charges.get(key, [])
        assert sum(c.open_minor + c.waived_minor for c in charges) == state.commission_minor
        assert sum(c.waived_minor for c in charges) == state.waived_minor
        if "invoices" in expect:  # per invoice: what it still charges the key, and its waiver
            assert {
                c.invoice_id: [str(c.open_minor), str(c.waived_minor)]
                for c in charges
                if c.open_minor or c.waived_minor
            } == expect["invoices"], f"{where} {text}"


def _check_cancel(sim: Simulator, want: dict[str, Any], where: str) -> None:
    """The previous run cancelled (M2c-4 C7): its corrective invoices, per number."""
    corrective = sim.cancel_last()
    assert {
        n: {"ht": str(inv.ht_minor), "vat": str(sim.invoice_vat[n])}
        for n, inv in corrective.items()
    } == want, where


@pytest.mark.parametrize("path", CASES, ids=[p.stem for p in CASES])
def test_golden_case(path: Path) -> None:
    case = load_case(path)
    sim = Simulator(files_of(case), versions_of(case), Decimal(case["vat_rate"]))
    for run in case["runs"]:
        where = f"{case['case']} / {run['name']}"
        expect = run["expect"]
        if "cancel_previous" in run:  # M2c-5b: a run cancelled with waivers present
            _check_cancel(sim, run["cancel_previous"], where)
        for mc in run.get("manual_credit_notes") or ():  # M2c-5b, before the run's lines
            _check_manual_credit(sim, mc, where)
        if run.get("lines"):
            numbers = {
                m: d["invoice"]["number"]
                for m, d in (expect.get("documents") or {}).items()
                if d.get("invoice")
            }
            if "vat_rate" in run:  # a change of the rate between runs (third review)
                sim.vat_rate = Decimal(run["vat_rate"])
            result, docs = sim.run(lines_of(run), numbers)
            _check_lines(result, expect["lines"], where)
            _check_documents(docs, expect.get("documents") or {}, where)
        if "state" in expect:
            _check_state(sim, expect["state"], where)
