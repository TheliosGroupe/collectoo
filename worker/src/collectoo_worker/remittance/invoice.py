"""Commission invoices and credit notes (M2-15; design §14.2; locked template
`facture-commission-fr-1`): the French wording of a document, from the payload M2c-4 froze at
issue (`private.issue_commission_documents`) — never from the current settings. Amounts are text
in minor units, dates ISO; nothing is computed here, no model or LLM is involved.

Mentions and their basis (design §14.2):
* « Facture » / « Avoir », its number and issue date — CGI ann. II 242 nonies A 6°, 7°;
* the seller: legal name, legal form and capital, SIREN, RCS city, registered office, VAT number,
  « en liquidation » / « EI » when they apply — 242 nonies A 1°, 2°; C. com. R123-237, R123-238;
* the buyer: legal name, SIREN, billing address (and VAT number when known) — 242 nonies A 1°;
* « Prestations de services » — 242 nonies A 8° bis;
* the service and its period, « Recouvrement amiable de créances pour votre compte — encaissements
  du … au … » — 242 nonies A 10°;
* each line: designation, quantity 1, unit price HT, VAT rate, amount HT — 242 nonies A 8°;
* « Aucun rabais, remise ni ristourne » — 242 nonies A 9°;
* total HT, VAT per rate, TTC — 242 nonies A 11°; « Option pour le paiement de la taxe d'après les
  débits » only when opted — 11° bis;
* the payment date (« À régler par compensation sur le reversement RV-… (exécution demandée le …)
  », « … sur le prochain reversement, au plus tard le … » or « À régler au plus tard le … par
  virement sur … »), « Pas d'escompte pour paiement anticipé », the penalty text and, for a
  professional buyer outside a proceeding, the 40 € flat indemnity — C. com. L441-9 I, L441-10 II,
  D441-5;
* a credit note: each line names the invoice it rectifies and why — CGI 289 I 5, 272 1.
No CGI article number is printed (the VAT articles move to the CIBS on 2027-01-01: design §3.1).
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime, time
from decimal import Decimal
from typing import Any

from collectoo_worker.payments.receipts import NNBSP, format_date, format_money, issuer_block
from collectoo_worker.remittance.run import percent
from collectoo_worker.remittance.statement import address

TEMPLATE_VERSION = "facture-commission-fr-1"
TEMPLATE_VERSIONS = (TEMPLATE_VERSION,)


@dataclass(frozen=True, slots=True)
class InvoiceDocument:
    """What a document is rendered from: its row (number, kind, issue date), its frozen payload, and
    the number and date of every invoice it names (append-only rows)."""

    number: str
    kind: str  # invoice | credit_note
    issue_date: date
    payload: Mapping[str, Any]
    refs: Mapping[str, Mapping[str, Any]]
    template_version: str = TEMPLATE_VERSION


@dataclass(frozen=True, slots=True)
class InvoiceLineView:
    designation: str
    quantity: str
    unit_price: str
    vat_rate: str
    amount: str


@dataclass(frozen=True, slots=True)
class InvoiceView:
    title: str
    number_line: str
    issued_line: str
    seller_lines: tuple[str, ...]
    buyer_lines: tuple[str, ...]
    nature_line: str
    service_line: str
    reference_lines: tuple[str, ...]
    lines: tuple[InvoiceLineView, ...]
    totals: tuple[tuple[str, str], ...]
    mentions: tuple[str, ...]
    footer: str


def _money(minor: int | str) -> str:
    return format_money(minor, 2, "EUR")


def _siren(s: str) -> str:
    return f"{s[0:3]}{NNBSP}{s[3:6]}{NNBSP}{s[6:9]}"


def invoice_view(doc: InvoiceDocument) -> InvoiceView:
    if doc.template_version not in TEMPLATE_VERSIONS:
        raise ValueError(f"unknown invoice template {doc.template_version!r}")
    p = doc.payload
    credit = doc.kind == "credit_note"
    seller = p["seller"]
    seller_lines = [*issuer_block(seller)] or [str(seller["name"])]
    if seller.get("vat_number"):
        seller_lines.append(f"N° de TVA intracommunautaire : {seller['vat_number']}")
    buyer = p["buyer"]
    buyer_lines = [f"Client : {buyer['name']}"]
    if buyer.get("siren"):
        buyer_lines.append(f"SIREN {_siren(str(buyer['siren']))}")
    addr = buyer.get("billing_address") or buyer.get("registered_office")
    if addr:
        buyer_lines.append(address(addr))
    if buyer.get("vat_number"):
        buyer_lines.append(f"N° de TVA intracommunautaire : {buyer['vat_number']}")
    period = p.get("service_period") or {}
    if period.get("from") and period.get("to"):
        span = f"encaissements du {format_date(period['from'])} au {format_date(period['to'])}"
    else:
        span = "encaissements de la période"
    service = (
        "Rectification de la commission de recouvrement amiable de créances pour votre compte"
        f" — {span}"
        if credit
        else f"Recouvrement amiable de créances pour votre compte — {span}"
    )
    refs = [f"Mandat {p['mandate']['reference']}"]
    if p.get("run"):
        refs.append(f"Relevé de reversement {p['run']['number']}")
    if p.get("po_number"):
        refs.append(f"Votre bon de commande n° {p['po_number']}")
    return InvoiceView(
        title="Avoir" if credit else "Facture",
        number_line=f"N° {doc.number}",
        issued_line=f"Date d'émission : {format_date(doc.issue_date)}",
        seller_lines=tuple(seller_lines),
        buyer_lines=tuple(buyer_lines),
        nature_line="Prestations de services",
        service_line=service,
        reference_lines=tuple(refs),
        lines=tuple(_line(x) for x in p["lines"]),
        totals=_totals(p, credit),
        mentions=_mentions(doc, credit),
        footer=f"{'Avoir' if credit else 'Facture'} n° {doc.number}",
    )


def _line(x: Mapping[str, Any]) -> InvoiceLineView:
    return InvoiceLineView(
        designation=str(x["designation_fr"]),
        quantity="1",
        unit_price=_money(x["ht"]),
        vat_rate=percent(str(x["vat_rate"])),
        amount=_money(x["ht"]),
    )


def _totals(p: Mapping[str, Any], credit: bool) -> tuple[tuple[str, str], ...]:
    t = p["totals"]
    rows = [("Total HT", _money(t["ht_minor"]))]
    for rate, ht, vat in vat_by_rate(p, credit):
        rows.append((f"TVA {percent(rate)} sur {_money(ht)}", _money(vat)))
    rows.append(("Total TTC", _money(t["ttc_minor"])))
    return tuple(rows)


def vat_by_rate(p: Mapping[str, Any], credit: bool) -> list[tuple[str, int, int]]:
    """(rate, HT, VAT) per rate, as stored (242 nonies A 11°): an invoice has one rate; a credit
    note one per rate of the invoices it rectifies (the VAT of each by cumulative difference)."""
    t = p["totals"]
    if not credit:
        return [(str(t["vat_rate"]), int(t["ht_minor"]), int(t["vat_minor"]))]
    acc: dict[Decimal, list[int]] = defaultdict(lambda: [0, 0])
    for c in p.get("corrections") or ():
        rate = Decimal(str(c["vat_rate"]))
        acc[rate][0] += int(c["ht"])
        acc[rate][1] += int(c["vat"])
    return [(str(r), ht, vat) for r, (ht, vat) in sorted(acc.items(), reverse=True)]


def _payment_line(doc: InvoiceDocument) -> str:
    p = doc.payload
    settlement = p.get("settlement") or {}
    clause = settlement.get("clause_ref")
    mandate = p["mandate"]["reference"]
    on = f"mandat {mandate}, {clause}" if clause else f"mandat {mandate}"
    ref = p.get("payment_reference") or {}
    if settlement.get("mode") != "due" and not ref:
        return f"À régler par compensation sur un prochain reversement de vos encaissements ({on})."
    if settlement.get("mode") == "due":
        acc = p.get("own_account") or {}
        text = f"À régler au plus tard le {format_date(p.get('due_date'))}"
        if acc.get("iban"):
            text += f" par virement sur le compte {_iban(str(acc['iban']))}"
            if acc.get("bic"):
                text += f" (BIC {acc['bic']})"
            if acc.get("holder"):
                text += f", titulaire {acc['holder']}"
        return text + "."
    if ref.get("mode") == "next_run":
        return (
            "À régler par compensation sur le prochain reversement de vos encaissements, au plus "
            f"tard le {format_date(ref.get('latest_date'))} ({on})."
        )
    return (
        f"À régler par compensation sur le reversement {ref.get('run_number')} (exécution demandée "
        f"le {format_date(ref.get('execution_date'))} ; {on})."
    )


def _iban(iban: str) -> str:
    compact = iban.replace(" ", "")
    return " ".join(compact[i : i + 4] for i in range(0, len(compact), 4))


def _mentions(doc: InvoiceDocument, credit: bool) -> tuple[str, ...]:
    p = doc.payload
    out: list[str] = []
    if credit:
        for c in p.get("corrections") or ():
            ref = doc.refs.get(str(c["original_invoice_id"])) or {}
            out.append(
                f"Avoir n° {doc.number} rectifiant la facture {ref.get('number', '?')} du "
                f"{format_date(ref.get('issue_date'))} : HT {_money(c['ht'])}, "
                f"TVA {_money(c['vat'])}."
            )
        out.append(
            "Le montant de cet avoir est déduit des factures qu'il rectifie ; l'excédent éventuel "
            "vous est remboursé avec un prochain reversement."
        )
    else:
        out.append("Aucun rabais, remise ni ristourne.")
        out.append(_payment_line(doc))
        out.append("Pas d'escompte pour paiement anticipé.")
        out.append(str(p["penalty_text"]))
        indemnity = p.get("flat_indemnity") or {}
        if indemnity.get("applies"):
            out.append(
                "Indemnité forfaitaire pour frais de recouvrement en cas de retard de paiement : "
                f"{_money(indemnity['amount_minor'])}."
            )
    if p.get("vat_on_debits"):
        out.append("Option pour le paiement de la taxe d'après les débits.")
    return tuple(out)


def issued_at(doc: InvoiceDocument) -> datetime:
    """The PDF's date: the issue date at midnight UTC (from the document, never the clock)."""
    return datetime.combine(doc.issue_date, time(0, 0), tzinfo=UTC)


def invoice_text(doc: InvoiceDocument) -> str:
    """The document as plain text, in the order the PDF draws it (snapshot tests)."""
    v = invoice_view(doc)
    out = [v.title, v.number_line, v.issued_line, "", *v.seller_lines, "", *v.buyer_lines, ""]
    out += [v.nature_line, v.service_line, *v.reference_lines, ""]
    out += [
        f"{x.designation} | {x.quantity} | {x.unit_price} | {x.vat_rate} | {x.amount}"
        for x in v.lines
    ]
    out.append("")
    out += [f"{label} : {value}" for label, value in v.totals]
    out.append("")
    out += list(v.mentions)
    out += ["", v.footer]
    return "\n".join(out)


def mention_list(doc: InvoiceDocument) -> Sequence[str]:
    return invoice_view(doc).mentions
