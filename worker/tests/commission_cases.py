"""Helpers for the commission tests: golden-case loading (worker/tests/golden/commission/*.yaml) and
a small run simulator that carries the history from run to run, as M2c-4's runs will (the state per
(file, tier key), the invoices and what they still charge each key, which invoice charged each
line: what the engine's rounding reserve and the documents both read)."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field, replace
from datetime import UTC, date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

from collectoo_worker.remittance.commission import (
    FileFacts,
    KeyState,
    Line,
    LineKind,
    RunCommission,
    TermsVersion,
    chain,
    compute,
)
from collectoo_worker.remittance.documents import (
    EarlierCharge,
    EarlierInvoice,
    MandateDocuments,
    ManualCredit,
    after_issue,
    after_manual_credit,
    manual_credit,
    run_documents,
)
from collectoo_worker.remittance.packs import load_yaml
from collectoo_worker.remittance.terms import CommissionSchedule
from collectoo_worker.remittance.vat import vat_of

GOLDEN = Path(__file__).parent / "golden" / "commission"

Key = tuple[str, str]


def _int(v: Any) -> int:
    if isinstance(v, bool) or not isinstance(v, int | str):
        raise TypeError(f"an amount as text or integer, not {v!r}")
    return int(v)


def load_case(path: Path) -> dict[str, Any]:
    data = load_yaml(path)  # refuses floats
    assert isinstance(data, dict)
    return data


def files_of(case: Mapping[str, Any]) -> dict[str, FileFacts]:
    return {
        k: FileFacts(
            account_id=k,
            mandate_id=v["mandate"],
            claim_type=v["claim_type"],
            portfolio_id=v["portfolio"],
            boarded_amount_minor=None if "boarded_minor" not in v else _int(v["boarded_minor"]),
            age_days_at_boarding=None if "age_days" not in v else _int(v["age_days"]),
        )
        for k, v in case["files"].items()
    }


def versions_of(case: Mapping[str, Any]) -> dict[str, list[TermsVersion]]:
    schedules = {k: CommissionSchedule.model_validate(v) for k, v in case["schedules"].items()}
    return {
        mandate: [
            TermsVersion(
                id=v["id"],
                mandate_id=mandate,
                valid_from=date.fromisoformat(v["from"]),
                valid_to=None if v["to"] is None else date.fromisoformat(v["to"]),
                schedule=schedules[v["schedule"]],
            )
            for v in vs
        ]
        for mandate, vs in case["mandates"].items()
    }


def lines_of(run: Mapping[str, Any]) -> list[Line]:
    out = []
    for raw in run["lines"]:
        eff = date.fromisoformat(raw["eff"])
        at = (
            datetime.fromisoformat(raw["at"])
            if "at" in raw
            else datetime(eff.year, eff.month, eff.day, 12, tzinfo=UTC)
        )
        out.append(
            Line(
                entry_id=raw["entry"],
                kind=LineKind(raw["kind"]),
                account_id=raw["file"],
                encaissement_date=date.fromisoformat(raw["e"]),
                effective_date=eff,
                posted_at=at,
                amount_minor=_int(raw["amount"]),
                basis={k: _int(v) for k, v in (raw.get("basis") or {}).items()},
                forward_reason=raw.get("forward_reason"),
                original_entry_id=raw.get("original"),
            )
        )
    return out


@dataclass
class Simulator:
    """Runs one after the other: the engine, the documents, then the history the next run starts
    from."""

    files: dict[str, FileFacts]
    versions: dict[str, list[TermsVersion]]
    vat_rate: Decimal
    history: dict[Key, KeyState] = field(default_factory=dict)
    charges: dict[Key, list[EarlierCharge]] = field(default_factory=dict)
    invoices: dict[str, EarlierInvoice] = field(default_factory=dict)
    invoice_vat: dict[str, int] = field(default_factory=dict)  # number → VAT of the invoice
    # entry → the invoice(s) that charge it (a cancellation's corrective invoice first)
    line_invoices: dict[str, str | tuple[str, ...]] = field(default_factory=dict)
    seq: int = 0
    vat_credited: dict[str, int] = field(default_factory=dict)  # number → VAT credited on it
    # the last run, for `cancel_last`: the state before it, its documents and invoice numbers
    last: tuple[Any, ...] | None = None

    def run(
        self, lines: Sequence[Line], numbers: Mapping[str, str] | None = None
    ) -> tuple[RunCommission, dict[str, MandateDocuments]]:
        before = (dict(self.history), dict(self.line_invoices))
        result = compute(
            lines,
            self.files,
            self.versions,
            self.history,
            self.vat_rate,
            charges=self.charges,
            line_invoices=self.line_invoices,
        )
        docs = run_documents(
            result.lines,
            self.files,
            self.charges,
            self.invoices,
            self.vat_rate,
            self.line_invoices,
        )
        issued: dict[str, tuple[str, tuple[int, int]]] = {}
        for mandate in sorted(docs):
            if docs[mandate].invoice:
                self.seq += 1
                number = (numbers or {}).get(mandate) or f"FC-2026-{self.seq:06d}"
                _, year, seq = number.split("-")  # FC-AAAA-NNNNNN: the series order LIFO follows
                issued[mandate] = (number, (int(year), int(seq)))
                invoice = docs[mandate].invoice
                assert invoice is not None
                self.invoice_vat[number] = invoice.vat_minor
                self.line_invoices.update(dict.fromkeys(invoice.entries, number))
            credit = docs[mandate].credit_note
            if credit:
                self.seq += 1
                for c in credit.corrected:
                    self.vat_credited[c.invoice_id] = (
                        self.vat_credited.get(c.invoice_id, 0) - c.vat_minor
                    )
        self.charges, self.invoices = after_issue(self.charges, self.invoices, docs, issued)
        self.history = dict(result.history)
        touched = {(p.account_id, p.tier_key) for lc in result.lines for p in lc.parts}
        originals = {ln.entry_id: ln.original_entry_id for ln in lines if ln.original_entry_id}
        self.last = (*before, docs, issued, touched, originals)
        return result, docs

    def manual_credit(self, invoice: str, amount: int, account: str | None = None) -> ManualCredit:
        """A manual credit note on an invoice (`issue_credit_note`, M2c-5b): its own number, its
        HT spread over what the invoice still charges each key (of the file, if one is named)."""
        open_by_key = {
            k: c.open_minor for k, cs in self.charges.items() for c in cs if c.invoice_id == invoice
        }
        credit = manual_credit(self.invoices[invoice], open_by_key, amount, account)
        self.charges, self.invoices, self.history = after_manual_credit(
            self.charges, self.invoices, self.history, credit
        )
        self.seq += 1
        self.vat_credited[invoice] = self.vat_credited.get(invoice, 0) + credit.vat_minor
        return credit

    def cancel_last(self) -> dict[str, EarlierInvoice]:  # noqa: PLR0912 - the cancellation's steps
        """Cancel the last run before its transfer (M2c-4 `cancel_remittance_run`, C7, with the
        waivers of M2c-5b): each of its invoices credited in full on what it still charges each
        key (its waivers cleared); per mandate and VAT rate a corrective invoice charging again what
        its credit notes credited on earlier invoices, at their rate and with the VAT of its own
        HT; what its credits absorbed of earlier waivers restored; each key back to its state
        before the run, its waiver the sum of its invoices' waivers. Returns the corrective
        invoices."""
        assert self.last is not None, "no run to cancel"
        history0, line_invoices0, docs, issued, touched, originals = self.last
        self.last = None
        own = {number for number, _ in issued.values()}
        for key, cs in self.charges.items():
            self.charges[key] = [
                replace(c, credited_minor=c.charged_minor, waived_minor=0)
                if c.invoice_id in own
                else c
                for c in cs
            ]
        for number in own:
            inv = self.invoices[number]
            self.vat_credited[number] = self.invoice_vat[number]  # a full credit: all its VAT
            self.invoices[number] = replace(inv, credited_ht_minor=inv.ht_minor)
            self.seq += 1
        restore: dict[tuple[str, Decimal], dict[Key, int]] = {}
        for mandate, d in docs.items():
            for w in d.absorbed:
                key = (w.account_id, w.tier_key)
                self.charges[key] = [
                    replace(c, waived_minor=c.waived_minor + w.amount_minor)
                    if c.invoice_id == w.invoice_id
                    else c
                    for c in self.charges[key]
                ]
            if d.credit_note:
                for a in d.credit_note.allocations:
                    rate = self.invoices[a.original_invoice_id].vat_rate
                    per = restore.setdefault((mandate, rate), {})
                    per[(a.account_id, a.tier_key)] = (
                        per.get((a.account_id, a.tier_key), 0) - a.ht_minor
                    )
        corrective: dict[str, EarlierInvoice] = {}
        credited_on: dict[str, str] = {}  # the reversal → the corrective invoice charging it again
        for (mandate, rate), per in sorted(restore.items(), key=lambda x: (x[0][0], x[0][1])):
            self.seq += 1
            number = f"FC-2026-{self.seq:06d}"
            ht = sum(per.values())
            corrective[number] = self.invoices[number] = EarlierInvoice(number, ht, rate)
            self.invoice_vat[number] = vat_of(ht, rate)
            for key, amount in sorted(per.items()):
                self.charges.setdefault(key, []).append(
                    EarlierCharge(number, (2026, self.seq), amount, vat_rate=rate)
                )
            for a in docs[mandate].credit_note.allocations:
                if self.invoices[a.original_invoice_id].vat_rate == rate:
                    credited_on[a.entry_id] = number
        # the lines go back to pending: their invoices are the state's before the run, except that
        # a reversal the run credited is credited first on the corrective invoice, then on its
        # original's own invoice
        self.line_invoices = dict(line_invoices0)
        for reversal, original in originals.items():
            if reversal in credited_on:
                self.line_invoices[original] = (
                    credited_on[reversal],
                    *chain(line_invoices0.get(original)),
                )
        for key in touched:
            state = history0.get(key, KeyState())
            waived = sum(c.waived_minor for c in self.charges.get(key, ()))
            self.history[key] = replace(state, waived_minor=waived)
        return corrective

    def open_invoices(self, key: Key) -> int:
        """How many invoices still charge the key something (the rounding reserve's n: by capacity,
        a manual credit note's waiver included)."""
        return sum(1 for c in self.charges.get(key, []) if c.open_minor + c.waived_minor > 0)
