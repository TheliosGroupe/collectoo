"""From a run's line commissions to its documents (design §8.4; founder #6; ADR-0014 M2c-3). Pure:
M2c-4 numbers, posts and stores them; M2c-5 renders them.

1. Per (mandate, file, tier key), the parts that raise the commission go to the mandate's invoice
   and the parts that lower it to its credit note — never netted across documents (review fix,
   founder #6: « a credit note on the original invoice »; CGI 289 I 5, 272 1). What the run nets
   was never invoiced: a reversal whose original is in the same run, and a credit beyond what the
   earlier invoices charge the key (the run's own collections moved the tiers it takes back). A
   mandate whose amounts are all 0 issues nothing (and draws no number).
2. Invoice lines group the keys per (claim type, rule, families): quantity 1, unit price HT, the
   base that moved in each rate band (for the designation: 242 nonies A 8°).
3. Invoice VAT = R(HT x rate) at the rate of the issue date (11°).
4. A credit is allocated first to the invoice that charged the line the reversal undoes (its
   original), up to what that invoice still charges the (file, tier key), then LIFO to the other
   invoices that charged the key; every allocation names its invoice (289 I 5) and its line.
5. Credit-note VAT per corrected invoice by cumulative difference at that invoice's rate: never
   above its VAT, exactly it on a full credit.

Signs: invoice amounts are positive; credit-note amounts negative, as printed (« -30 000 HT »).
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field, replace
from decimal import Decimal

from collectoo_worker.remittance.commission import (
    REVERSALS,
    CommissionInputError,
    FileFacts,
    LineCommission,
    Part,
)
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
    entries: tuple[str, ...]  # the lines it charges (a later reversal credits this invoice first)


@dataclass(frozen=True)
class CreditAllocation:
    original_invoice_id: str
    account_id: str
    tier_key: str
    ht_minor: int  # negative
    entry_id: str  # the line whose part it credits (a reversal: the line that undoes a collection)


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


@dataclass
class _Charge:
    """One key's invoice side in the run."""

    amount: int = 0
    tiers: dict[str, int] = field(default_factory=dict)
    families: set[str] = field(default_factory=set)
    rule_id: str = ""
    label_fr: str = ""
    entries: list[str] = field(default_factory=list)  # the lines whose parts raise it
    last_entry: str = ""


@dataclass(frozen=True)
class _Credit:
    key: Key
    amount: int  # positive magnitude
    preferred: str | None  # the invoice that charged the line the reversal undoes
    entry_id: str


def run_documents(  # noqa: PLR0913, PLR0917 - the run's lines and the history
    results: Sequence[LineCommission],
    files: Mapping[str, FileFacts],
    charges: Mapping[Key, Sequence[EarlierCharge]],
    invoices: Mapping[str, EarlierInvoice],
    vat_rate: Decimal,
    line_invoices: Mapping[str, str] | None = None,
) -> dict[str, MandateDocuments]:
    """The invoice and credit note of each mandate of the run (absent: nothing to issue).
    `line_invoices`: an earlier line → the invoice that charged it (M2c-4: the remittance line's
    invoice), so that its reversal is credited on that invoice first."""
    by_mandate = _split(results, line_invoices or {})
    out: dict[str, MandateDocuments] = {}
    for mandate in sorted(by_mandate):
        side, credits = by_mandate[mandate]
        invoice, credit = _documents(mandate, side, credits, files, charges, invoices, vat_rate)
        if invoice or credit:
            out[mandate] = MandateDocuments(mandate, invoice, credit)
    return out


def _split(
    results: Sequence[LineCommission], line_invoices: Mapping[str, str]
) -> dict[str, tuple[dict[Key, _Charge], list[_Credit]]]:
    """Per mandate: each key's invoice side (raising parts, and same-run reversals), and the
    credits (the other lowering parts, each with the invoice of the line it undoes)."""
    in_run = {r.entry_id for r in results}
    by_mandate: dict[str, tuple[dict[Key, _Charge], list[_Credit]]] = {}
    for r in results:  # the engine's order
        if r.state != "charged" or r.mandate_id is None or not r.parts:
            continue
        side, credits = by_mandate.setdefault(r.mandate_id, ({}, []))
        reversal = r.kind in REVERSALS
        same_run = reversal and r.original_entry_id in in_run
        for p in r.parts:
            key = (p.account_id, p.tier_key)
            if p.commission_minor > 0 or (same_run and p.commission_minor < 0):
                _charge(side.setdefault(key, _Charge()), p, r.entry_id)
            elif p.commission_minor < 0:
                preferred = (
                    line_invoices.get(r.original_entry_id)
                    if reversal and r.original_entry_id
                    else None
                )
                credits.append(_Credit(key, -p.commission_minor, preferred, r.entry_id))
    return by_mandate


def _documents(  # noqa: PLR0913, PLR0917 - a mandate's amounts and the history they credit
    mandate: str,
    side: dict[Key, _Charge],
    credits: list[_Credit],
    files: Mapping[str, FileFacts],
    charges: Mapping[Key, Sequence[EarlierCharge]],
    invoices: Mapping[str, EarlierInvoice],
    vat_rate: Decimal,
) -> tuple[DraftInvoice | None, DraftCreditNote | None]:
    """A mandate's credit note, allocated first, then its invoice of what remains to charge."""
    for key in sorted(side):
        ch = side[key]
        if ch.amount < 0:  # a same-run reversal beyond what its run charged the key
            credits.append(_Credit(key, -ch.amount, None, ch.last_entry))
            ch.amount = 0
    credit, unallocated = (
        _credit_note(mandate, credits, charges, invoices) if credits else (None, {})
    )
    for key, rest in unallocated.items():
        # what the run itself added to the key and takes back (a back-dated collection moved
        # the tiers, a reversal moves them back): never invoiced, so netted here
        found = side.get(key)
        if found is None or found.amount < rest:
            raise CommissionInputError(
                f"credit on {key}: earlier invoices and this run charge {rest} too little"
            )
        found.amount -= rest
    groups: dict[tuple[str, str, tuple[str, ...]], list[tuple[Key, _Charge]]] = defaultdict(list)
    for key in sorted(side):
        ch = side[key]
        if ch.amount > 0:
            families = tuple(sorted(ch.families))
            groups[(files[key[0]].claim_type, ch.rule_id, families)].append((key, ch))
    invoice = _invoice(mandate, groups, vat_rate) if groups else None
    return invoice, credit


def _charge(ch: _Charge, p: Part, entry_id: str) -> None:
    ch.amount += p.commission_minor
    ch.last_entry = entry_id
    for rate, base in p.tiers:
        ch.tiers[rate] = ch.tiers.get(rate, 0) + base
    if p.commission_minor > 0:  # the rule and label of the key's last raising part
        ch.families.update(p.families)
        ch.rule_id, ch.label_fr = p.rule_id, p.label_fr
        ch.entries.append(entry_id)


def _invoice(
    mandate: str,
    groups: Mapping[tuple[str, str, tuple[str, ...]], list[tuple[Key, _Charge]]],
    vat_rate: Decimal,
) -> DraftInvoice:
    lines = []
    for (claim_type, rule_id, families), items in sorted(groups.items()):
        tiers: dict[str, int] = defaultdict(int)
        for _, ch in items:
            for rate, base in ch.tiers.items():
                tiers[rate] += base
        lines.append(
            InvoiceLine(
                claim_type=claim_type,
                rule_id=rule_id,
                label_fr=items[-1][1].label_fr,
                families=families,
                keys=tuple(k for k, _ in items),
                tiers=tuple((r, b) for r, b in tiers.items() if b),  # band order
                ht_minor=sum(ch.amount for _, ch in items),
            )
        )
    ht = sum(line.ht_minor for line in lines)
    vat = vat_of(ht, vat_rate)
    charged = tuple(sorted((k, ch.amount) for items in groups.values() for k, ch in items))
    entries = tuple(sorted({e for items in groups.values() for _, ch in items for e in ch.entries}))
    return DraftInvoice(mandate, tuple(lines), ht, vat_rate, vat, ht + vat, charged, entries)


def _credit_note(
    mandate: str,
    credits: Sequence[_Credit],
    charges: Mapping[Key, Sequence[EarlierCharge]],
    invoices: Mapping[str, EarlierInvoice],
) -> tuple[DraftCreditNote | None, dict[Key, int]]:
    """The credit note, and per key what earlier invoices do not charge (for the run to net)."""
    open_: dict[tuple[str, Key], int] = {}
    allocations: list[CreditAllocation] = []
    unallocated: dict[Key, int] = defaultdict(int)
    for cr in credits:
        left = cr.amount
        earlier = sorted(charges.get(cr.key, ()), key=lambda c: c.order, reverse=True)
        if cr.preferred is not None:  # its original's invoice first (founder #6)
            earlier.sort(key=lambda c: c.invoice_id != cr.preferred)
        for ch in earlier:
            k = (ch.invoice_id, cr.key)
            available = open_.setdefault(k, ch.open_minor)
            take = min(left, available)
            if take > 0:
                allocations.append(
                    CreditAllocation(ch.invoice_id, cr.key[0], cr.key[1], -take, cr.entry_id)
                )
                open_[k] = available - take
                left -= take
            if left == 0:
                break
        if left:
            unallocated[cr.key] += left
    if not allocations:
        return None, dict(unallocated)
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
    note = DraftCreditNote(mandate, tuple(allocations), tuple(corrected), ht, vat, ht + vat)
    return note, dict(unallocated)


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


def open_invoices(charges: Mapping[Key, Sequence[EarlierCharge]]) -> dict[Key, int]:
    """Per (file, tier key), how many invoices still charge it something: the engine's rounding
    reserve (`KeyState.open_invoices`)."""
    return {k: sum(1 for c in v if c.open_minor > 0) for k, v in charges.items()}
