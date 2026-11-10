"""Helpers for the commission tests: golden-case loading (worker/tests/golden/commission/*.yaml) and
a small run simulator that carries the history from run to run, as M2c-4's runs will (the state per
(file, tier key), the invoices and what they still charge each key, which invoice charged each
line: what the engine's rounding reserve and the documents both read)."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
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
    compute,
)
from collectoo_worker.remittance.documents import (
    EarlierCharge,
    EarlierInvoice,
    MandateDocuments,
    after_issue,
    run_documents,
)
from collectoo_worker.remittance.packs import load_yaml
from collectoo_worker.remittance.terms import CommissionSchedule

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
    line_invoices: dict[str, str] = field(default_factory=dict)  # entry → invoice that charged it
    seq: int = 0

    def run(
        self, lines: Sequence[Line], numbers: Mapping[str, str] | None = None
    ) -> tuple[RunCommission, dict[str, MandateDocuments]]:
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
            if docs[mandate].credit_note:
                self.seq += 1
        self.charges, self.invoices = after_issue(self.charges, self.invoices, docs, issued)
        self.history = dict(result.history)
        return result, docs

    def open_invoices(self, key: Key) -> int:
        """How many invoices still charge the key something (the rounding reserve's n)."""
        return sum(1 for c in self.charges.get(key, []) if c.open_minor > 0)
