"""From a run's line commissions to its documents (design §8.4; ADR-0014 M2c-3). Pure: M2c-4
numbers, posts and stores them; M2c-5 renders them.

1. Per (mandate, file, tier key) the run's net Δ = Σ line commissions. A positive Δ goes to the
   mandate's invoice, a negative Δ to its credit note; a mandate whose Δ are all 0 issues nothing
   (and draws no number).
2. Invoice lines group the keys per (claim type, rule, families): quantity 1, unit price HT = Σ Δ,
   the base that moved in each rate band (for the designation: 242 nonies A 8°).
3. Invoice VAT = R(HT x rate) at the rate of the issue date (11°).
4. A negative Δ is credited LIFO to the earlier invoices that charged that (file, tier key), each up
   to what it charged net of earlier credits; every allocation names its invoice (CGI 289 I 5).
5. Credit-note VAT per corrected invoice by cumulative difference at that invoice's rate: never
   above its VAT, exactly it on a full credit.

Signs: invoice amounts are positive; credit-note amounts negative, as printed (« -30 000 HT »).
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from decimal import Decimal

from collectoo_worker.remittance.commission import CommissionInputError, FileFacts, LineCommission
from collectoo_worker.remittance.vat import credit_note_vat, vat_of

Key = tuple[str, str]  # (file, tier key)


@dataclass(frozen=True)
class EarlierCharge:
    """What one earlier invoice charged for one (file, tier key), and what credit notes took back
    since."""

    invoice_id: str
    order: tuple[int, int]  # (year, seq) in the invoice series: LIFO takes the highest first
    charged_minor: int
    credited_minor: int = 0

    @property
    def open_minor(self) -> int:
        return self.charged_minor - self.credited_minor


@dataclass(frozen=True)
class EarlierInvoice:
    invoice_id: str
    ht_minor: int
    vat_rate: Decimal
    credited_ht_minor: int = 0  # over all its keys, by earlier credit notes


@dataclass(frozen=True)
class InvoiceLine:
    claim_type: str
    rule_id: str
    label_fr: str
    families: tuple[str, ...]
    keys: tuple[Key, ...]
    tiers: tuple[tuple[str, int], ...]  # (rate, base moved in that band), net over the keys
    ht_minor: int


@dataclass(frozen=True)
class DraftInvoice:
    mandate_id: str
    lines: tuple[InvoiceLine, ...]
    ht_minor: int
    vat_rate: Decimal
    vat_minor: int
    ttc_minor: int
    charges: tuple[
        tuple[Key, int], ...
    ]  # what it charges per (file, tier key): the LIFO history of later credits


@dataclass(frozen=True)
class CreditAllocation:
    original_invoice_id: str
    account_id: str
    tier_key: str
    ht_minor: int  # negative


@dataclass(frozen=True)
class CorrectedInvoice:
    invoice_id: str
    vat_rate: Decimal
    ht_minor: int  # negative
    vat_minor: int  # negative


@dataclass(frozen=True)
class DraftCreditNote:
    mandate_id: str
    allocations: tuple[CreditAllocation, ...]
    corrected: tuple[CorrectedInvoice, ...]
    ht_minor: int
    vat_minor: int
    ttc_minor: int


@dataclass(frozen=True)
class MandateDocuments:
    mandate_id: str
    invoice: DraftInvoice | None
    credit_note: DraftCreditNote | None


def _deltas(results: Sequence[LineCommission]) -> dict[str, dict[Key, list[LineCommission]]]:
    by: dict[str, dict[Key, list[LineCommission]]] = defaultdict(lambda: defaultdict(list))
    for r in results:
        if r.state != "charged" or r.mandate_id is None:
            continue
        for p in r.parts:
            by[r.mandate_id][(p.account_id, p.tier_key)].append(r)
    return by


def run_documents(
    results: Sequence[LineCommission],
    files: Mapping[str, FileFacts],
    charges: Mapping[Key, Sequence[EarlierCharge]],
    invoices: Mapping[str, EarlierInvoice],
    vat_rate: Decimal,
) -> dict[str, MandateDocuments]:
    """The invoice and credit note of each mandate of the run (absent: nothing to issue)."""
    out: dict[str, MandateDocuments] = {}
    for mandate, keyed in sorted(_deltas(results).items()):
        positive: dict[
            tuple[str, str, tuple[str, ...]], list[tuple[Key, int, dict[str, int], str]]
        ] = defaultdict(list)
        negative: list[tuple[Key, int]] = []
        for key in sorted(keyed):
            parts = [p for r in keyed[key] for p in r.parts if (p.account_id, p.tier_key) == key]
            delta = sum(p.commission_minor for p in parts)
            if delta > 0:
                last = parts[-1]
                families = tuple(sorted({f for p in parts for f in p.families}))
                tiers: dict[str, int] = defaultdict(int)
                for p in parts:
                    for rate, base in p.tiers:
                        tiers[rate] += base
                claim_type = files[key[0]].claim_type
                positive[(claim_type, last.rule_id, families)].append(
                    (key, delta, tiers, last.label_fr)
                )
            elif delta < 0:
                negative.append((key, delta))
        invoice = _invoice(mandate, positive, vat_rate) if positive else None
        credit = _credit_note(mandate, negative, charges, invoices) if negative else None
        if invoice or credit:
            out[mandate] = MandateDocuments(mandate, invoice, credit)
    return out


def _invoice(
    mandate: str,
    groups: Mapping[tuple[str, str, tuple[str, ...]], list[tuple[Key, int, dict[str, int], str]]],
    vat_rate: Decimal,
) -> DraftInvoice:
    lines = []
    for (claim_type, rule_id, families), items in sorted(groups.items()):
        tiers: dict[str, int] = defaultdict(int)
        for _, _, t, _ in items:
            for rate, base in t.items():
                tiers[rate] += base
        lines.append(
            InvoiceLine(
                claim_type=claim_type,
                rule_id=rule_id,
                label_fr=items[-1][3],
                families=families,
                keys=tuple(k for k, _, _, _ in items),
                tiers=tuple((r, b) for r, b in tiers.items() if b),  # band order
                ht_minor=sum(d for _, d, _, _ in items),
            )
        )
    ht = sum(line.ht_minor for line in lines)
    vat = vat_of(ht, vat_rate)
    charged = tuple((k, d) for _, items in sorted(groups.items()) for k, d, _, _ in items)
    return DraftInvoice(mandate, tuple(lines), ht, vat_rate, vat, ht + vat, tuple(sorted(charged)))


def _credit_note(
    mandate: str,
    negative: Sequence[tuple[Key, int]],
    charges: Mapping[Key, Sequence[EarlierCharge]],
    invoices: Mapping[str, EarlierInvoice],
) -> DraftCreditNote:
    allocations: list[CreditAllocation] = []
    for key, delta in negative:
        left = -delta
        for ch in sorted(charges.get(key, ()), key=lambda c: c.order, reverse=True):
            take = min(left, ch.open_minor)
            if take > 0:
                allocations.append(CreditAllocation(ch.invoice_id, key[0], key[1], -take))
                left -= take
            if left == 0:
                break
        if left:
            raise CommissionInputError(
                f"credit of {-delta} on {key}: earlier invoices charged {-delta - left} only"
            )
    per_invoice: dict[str, int] = defaultdict(int)
    for a in allocations:
        per_invoice[a.original_invoice_id] -= a.ht_minor
    corrected = []
    for inv_id in sorted(per_invoice):
        inv = invoices[inv_id]
        before = inv.credited_ht_minor
        after = before + per_invoice[inv_id]
        vat = credit_note_vat(inv.ht_minor, inv.vat_rate, before, after)
        corrected.append(CorrectedInvoice(inv_id, inv.vat_rate, -per_invoice[inv_id], -vat))
    ht = sum(c.ht_minor for c in corrected)
    vat = sum(c.vat_minor for c in corrected)
    return DraftCreditNote(mandate, tuple(allocations), tuple(corrected), ht, vat, ht + vat)


def after_issue(
    charges: Mapping[Key, Sequence[EarlierCharge]],
    invoices: Mapping[str, EarlierInvoice],
    docs: Mapping[str, MandateDocuments],
    numbers: Mapping[str, tuple[str, tuple[int, int]]],
) -> tuple[dict[Key, list[EarlierCharge]], dict[str, EarlierInvoice]]:
    """The charge and invoice history once the run's invoices are issued under `numbers` (mandate →
    (invoice id, (year, seq))) and its credit notes applied: what the next run's credit notes
    allocate against."""
    new_charges = {k: list(v) for k, v in charges.items()}
    new_invoices = dict(invoices)
    for mandate, d in docs.items():
        if d.credit_note:
            for a in d.credit_note.allocations:
                key = (a.account_id, a.tier_key)
                new_charges[key] = [
                    replace(c, credited_minor=c.credited_minor - a.ht_minor)
                    if c.invoice_id == a.original_invoice_id
                    else c
                    for c in new_charges[key]
                ]
            for c in d.credit_note.corrected:
                inv = new_invoices[c.invoice_id]
                new_invoices[c.invoice_id] = replace(
                    inv, credited_ht_minor=inv.credited_ht_minor - c.ht_minor
                )
        if d.invoice:
            inv_id, order = numbers[mandate]
            new_invoices[inv_id] = EarlierInvoice(inv_id, d.invoice.ht_minor, d.invoice.vat_rate)
            for key, amount in d.invoice.charges:
                new_charges.setdefault(key, []).append(EarlierCharge(inv_id, order, amount))
    return new_charges, new_invoices
