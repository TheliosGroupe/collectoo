"""Golden cases of the commission engine `commission-1` (design §8, §18 M2-13; founder #4, #5, #6):
worked examples to the cent in worker/tests/golden/commission/*.yaml — flat; claim-type and family
rates; marginal tiers crossed inside one collection and back; brackets by boarded amount and by age;
the minimum per file, capped, across several runs; a version change; a collection made before a
change undone after it; a minimum introduced or dropped by a new version; a marginal grid change
re-tiering later collections (the regularisation line); the cap across versions; a reversal and a
new collection in one run (a credit note and an invoice); the fee kept by clause, flat and
marginal; forwards; items that earn nothing; a change of the VAT rate between runs; and the §7.2
worked example (RV-2026-000001 … 000003). Each run's lines, then its invoice and credit note per
mandate (§8.4), with the history carried to the next run. Every case is marked TO VALIDATE until
the founder's anonymised clauses replace the synthetic ones."""

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


@pytest.mark.parametrize("path", CASES, ids=[p.stem for p in CASES])
def test_golden_case(path: Path) -> None:
    case = load_case(path)
    sim = Simulator(files_of(case), versions_of(case), Decimal(case["vat_rate"]))
    for run in case["runs"]:
        expect = run["expect"]
        numbers = {
            m: d["invoice"]["number"]
            for m, d in (expect.get("documents") or {}).items()
            if d.get("invoice")
        }
        if "vat_rate" in run:  # a change of the rate between runs (third review)
            sim.vat_rate = Decimal(run["vat_rate"])
        result, docs = sim.run(lines_of(run), numbers)
        where = f"{case['case']} / {run['name']}"
        _check_lines(result, expect["lines"], where)
        _check_documents(docs, expect.get("documents") or {}, where)
