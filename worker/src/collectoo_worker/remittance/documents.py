"""From a run's line commissions to its documents (design §8.4; founder #6; ADR-0014 M2c-3). Pure:
M2c-4 numbers, posts and stores them; M2c-5 renders them.

1. Per (mandate, file, tier key), the parts that raise the commission go to the mandate's invoice
   and the parts that lower it to its credit note — never netted across documents (review fix,
   founder #6: « a credit note on the original invoice »; CGI 289 I 5, 272 1). What the run nets
   was never invoiced: what a kept reversal of a same-run collection moves (under `credit` the
   engine never prices such a pair: both lines are charged 0 with no parts, so no invoice charges
   a collection its own run undoes), and a credit beyond what the earlier invoices charge the key
   (the run's own collections moved the tiers it takes back). A mandate whose amounts are all 0
   issues nothing (and draws no number).
2. Invoice lines group the keys per (claim type, rule, families): quantity 1, unit price HT, the
   base that moved in each rate band of the collections' own versions (for the designation:
   242 nonies A 8°, « la dénomination précise »). When a change of terms re-tiers collections of a
   later version (a collection dated before the change booked after them, or one undone), that
   re-tiering is its own line, « Régularisation de paliers (changement de conditions) », with its
   net HT and no bands, never a negative band (second review); when it lowers the commission it is
   credited like any decrease (a reversal's on its original's invoice first, else LIFO). A
   commission line only ever sums collections' own bands; a negative band would be an engine
   error, refused (`CommissionInputError`: the commission stays pending) rather than issued.
3. Invoice VAT = R(HT x rate) at the rate of the issue date (11°).
4. A reversal's credit is allocated first to the invoice that charged the line it undoes (its
   original), up to what that invoice still charges the (file, tier key) — every reversal of the
   run there before any credit goes LIFO — then LIFO to the other invoices that charged the key;
   every allocation names its invoice (289 I 5) and its line. The per-key logic is
   `commission.key_side`, which the engine's rounding reserve simulates too.
5. Credit-note VAT per corrected invoice by cumulative difference at that invoice's rate: never
   above its VAT, exactly it on a full credit.

Signs: invoice amounts are positive; credit-note amounts negative, as printed (« -30 000 HT »).
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from decimal import Decimal
from typing import Literal

from collectoo_worker.remittance.commission import (
    REGULARISATION_LABEL_FR,
    REVERSALS,
    CommissionInputError,
    FileFacts,
    KeySide,
    LineCommission,
    SidePart,
    key_side,
)
from collectoo_worker.remittance.vat import credit_note_vat, vat_of

Key = tuple[str, str]  # (file, tier key)
LineKindFr = Literal["commission", "regularisation"]
COMMISSION: LineKindFr = "commission"
REGULARISATION: LineKindFr = "regularisation"
_Group = tuple[str, str, tuple[str, ...], LineKindFr]  # (claim type, rule, families, kind)


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
    # commission: the keys' own bands; regularisation: a change of terms re-tiered later ones
    kind: LineKindFr = "commission"


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
    invoice), so that its reversal is credited on that invoice first. The engine reserves for the
    same documents (`commission.compute(…, charges=, line_invoices=)`)."""
    by_mandate = _split(results, line_invoices or {})
    order = {r.entry_id: i for i, r in enumerate(results)}
    out: dict[str, MandateDocuments] = {}
    for mandate in sorted(by_mandate):
        sides = {key: key_side(ps, charges.get(key, ())) for key, ps in by_mandate[mandate].items()}
        credit = _credit_note(mandate, sides, invoices, order)
        invoice = _invoice(mandate, sides, files, vat_rate)
        if invoice or credit:
            out[mandate] = MandateDocuments(mandate, invoice, credit)
    return out


def _split(
    results: Sequence[LineCommission], line_invoices: Mapping[str, str]
) -> dict[str, dict[Key, list[SidePart]]]:
    """Per mandate and (file, tier key), its parts in the engine's order: whether each undoes a
    collection of the same run, and the invoice that charged the line a reversal undoes."""
    in_run = {r.entry_id for r in results}
    by_mandate: dict[str, dict[Key, list[SidePart]]] = {}
    for r in results:  # the engine's order
        if r.state != "charged" or r.mandate_id is None or not r.parts:
            continue
        keys = by_mandate.setdefault(r.mandate_id, {})
        reversal = r.kind in REVERSALS
        same_run = reversal and r.original_entry_id in in_run
        preferred = (
            line_invoices.get(r.original_entry_id)
            if reversal and r.original_entry_id and not same_run
            else None
        )
        for p in r.parts:
            keys.setdefault((p.account_id, p.tier_key), []).append(
                SidePart(r.entry_id, p, p.commission_minor, same_run, preferred)
            )
    return by_mandate


def _invoice(
    mandate: str,
    sides: Mapping[Key, KeySide],
    files: Mapping[str, FileFacts],
    vat_rate: Decimal,
) -> DraftInvoice | None:
    """Lines per (claim type, rule, families): the commission with the base moved in each band of
    the collections' own versions, and the tier regularisation of a change of terms (no bands)."""
    groups: dict[_Group, list[tuple[Key, int, dict[str, int]]]] = defaultdict(list)
    labels: dict[_Group, str] = {}
    for key in sorted(sides):
        side = sides[key]
        families = tuple(sorted(side.families))
        head = (files[key[0]].claim_type, side.rule_id, families)
        if side.commission_minor > 0:
            groups[(*head, COMMISSION)].append((key, side.commission_minor, side.tiers))
            labels[(*head, COMMISSION)] = side.label_fr
        if side.regularisation_minor > 0:
            groups[(*head, REGULARISATION)].append((key, side.regularisation_minor, {}))
            labels[(*head, REGULARISATION)] = REGULARISATION_LABEL_FR
    if not groups:
        return None
    lines = []
    for (claim_type, rule_id, families, kind), items in sorted(groups.items()):
        tiers: dict[str, int] = defaultdict(int)
        for _, _, moved in items:
            for rate, base in moved.items():
                tiers[rate] += base
        if any(base < 0 for base in tiers.values()):  # 242 nonies A 8°: never « 5 % sur -… »
            raise CommissionInputError(
                f"mandate {mandate}: a negative band on an invoice line (an engine error: the"
                " commission stays pending)"
            )
        lines.append(
            InvoiceLine(
                claim_type=claim_type,
                rule_id=rule_id,
                label_fr=labels[(claim_type, rule_id, families, kind)],
                families=families,
                keys=tuple(k for k, _, _ in items),
                tiers=tuple((r, b) for r, b in tiers.items() if b),  # band order
                ht_minor=sum(amount for _, amount, _ in items),
                kind=kind,
            )
        )
    ht = sum(line.ht_minor for line in lines)
    vat = vat_of(ht, vat_rate)
    charged = tuple(
        sorted((k, side.invoiced_minor) for k, side in sides.items() if side.invoiced_minor > 0)
    )
    entries = tuple(
        sorted(
            {
                e
                for side in sides.values()
                if side.invoiced_minor > 0
                for e in (*side.entries, *side.regularisation_entries)
            }
        )
    )
    return DraftInvoice(mandate, tuple(lines), ht, vat_rate, vat, ht + vat, charged, entries)


def _credit_note(
    mandate: str,
    sides: Mapping[Key, KeySide],
    invoices: Mapping[str, EarlierInvoice],
    order: Mapping[str, int],
) -> DraftCreditNote | None:
    """The allocations of every key, in the engine's order of the lines they credit; VAT per
    corrected invoice by cumulative difference at that invoice's rate."""
    allocations = sorted(
        (
            CreditAllocation(inv, key[0], key[1], -take, entry)
            for key in sorted(sides)
            for inv, take, entry in sides[key].allocations
        ),
        key=lambda a: order.get(a.entry_id, -1),
    )
    if not allocations:
        return None
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
