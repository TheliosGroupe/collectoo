"""Commission invoices and credit notes (M2-15; design §14.2; locked template
`facture-commission-fr-3`, `facture-commission-fr-2` kept for the payloads frozen before it): the
French wording of a document, from the payload M2c-4 froze at
issue (`private.issue_commission_documents`) — never from the current settings. Amounts are text
in minor units, dates ISO; nothing is computed here, no model or LLM is involved.

Mentions and their basis (design §14.2):
* « Facture » / « Avoir », its number and issue date — CGI ann. II 242 nonies A 6°, 7°;
* the seller: legal name, legal form and capital, SIREN, RCS city, registered office, VAT number,
  « en liquidation » / « EI » when they apply — 242 nonies A 1°, 2°; C. com. R123-237, R123-238;
  its billing address too when it differs — L441-9 I;
* the buyer: legal name, SIREN, its address (registered office) and its billing address when it
  differs (« le nom des parties ainsi que leur adresse et leur adresse de facturation si elle est
  différente », L441-9 I; review legal#1), VAT number when known — 242 nonies A 1°;
* « Prestations de services » — 242 nonies A 8° bis;
* the service and its period, « Recouvrement amiable de créances pour votre compte — encaissements
  du … au … » — 242 nonies A 10°;
* each line: designation, quantity 1, unit price HT, VAT rate, amount HT — 242 nonies A 8°;
* « Aucun rabais, remise ni ristourne » — 242 nonies A 9°;
* total HT, VAT per rate, TTC — 242 nonies A 11°; « Option pour le paiement de la taxe d'après les
  débits » only when opted — 11° bis;
* the payment date — C. com. L441-9 I « la date à laquelle le règlement doit intervenir »: what the
  run's plan sets off on its payout (« À régler par compensation sur le reversement RV-… : X €
  (exécution demandée le …) ») and the remainder on the next run by its date (review legal#4), or
  « Compensation le … » when the run transfers nothing (N = 0, legal#5), « … sur le prochain
  reversement, au plus tard le … », or « À régler au plus tard le … par virement sur … »;
* « Pas d'escompte pour paiement anticipé », the penalty text and, for every professional buyer,
  the 40 € flat indemnity for recovery costs (L441-9 I: the invoice states « le montant de
  l'indemnité forfaitaire pour frais de recouvrement due au créancier en cas de retard de
  paiement »; L441-10 II; D441-5: 40 euros). A proceeding of the client does not remove the
  mention: L441-10 II only bars invoking the indemnity while the opening forbids paying the claim
  at its date — the dunning step's concern (review legal#0);
* a credit note: each line names the invoice it rectifies and why — CGI 289 I 5, 272 1; and, from
  `facture-commission-fr-3` (M2c-5b review legal#1), per invoice it rectifies, that invoice's HT
  and VAT once the note is applied, « Après cet avoir, la facture FC-… du … s'élève à X € HT, TVA
  Y € (taux) » — the note states « le montant du total hors taxes et de la TVA due après
  application de la réduction de prix » (BOI-TVA-DECLA-30-20-20-20 §260, BOI-TVA-DED-40-10-20
  §80), frozen in the payload (`ht_after`, `vat_after`); what it gives back beyond what the
  invoices still owe is owed to the client, paid with a later payout or, with none, by transfer
  (never « remboursé » before the money moves).
No CGI article number is printed (the VAT articles move to the CIBS on 2027-01-01: design §3.1).
Nothing says « payé » or « réglé » before the bank's debit.
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

TEMPLATE_V2 = "facture-commission-fr-2"  # M2c-5 review (fr-1 never left the slice)
TEMPLATE_VERSION = "facture-commission-fr-3"  # M2c-5b review legal#1: the invoice after the credit
TEMPLATE_VERSIONS = (TEMPLATE_V2, TEMPLATE_VERSION)  # fr-2 renders what it rendered, to the byte
FLAT_INDEMNITY_MINOR = (
    4000  # C. com. D441-5: « fixé à 40 euros » (when the payload names no amount)
)


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
    billing = _other_billing_address(seller)
    if billing:
        seller_lines.append(f"Adresse de facturation : {billing}")
    if seller.get("vat_number"):
        seller_lines.append(f"N° de TVA intracommunautaire : {seller['vat_number']}")
    buyer = p["buyer"]
    buyer_lines = [f"Client : {buyer['name']}"]
    if buyer.get("siren"):
        buyer_lines.append(f"SIREN {_siren(str(buyer['siren']))}")
    if buyer.get("registered_office"):
        buyer_lines.append(f"Siège social : {address(buyer['registered_office'])}")
        billing = _other_billing_address(buyer)
        if billing:
            buyer_lines.append(f"Adresse de facturation : {billing}")
    elif buyer.get("billing_address"):
        buyer_lines.append(f"Adresse de facturation : {address(buyer['billing_address'])}")
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


def _other_billing_address(party: Mapping[str, Any]) -> str:
    """A party's billing address, worded, when it differs from its registered office as printed
    (L441-9 I: « leur adresse de facturation si elle est différente »); empty otherwise."""
    billing, office = party.get("billing_address"), party.get("registered_office")
    if not billing or not office:
        return ""
    text = address(billing)
    return text if text != address(office) else ""


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
    run = ref.get("run_number")
    when = format_date(ref.get("execution_date"))
    if ref.get("amount_minor") is None:  # a payload without the plan's amount: the run sets it off
        return (
            f"À régler par compensation sur le reversement {run} (exécution demandée le {when} ; "
            f"{on})."
        )
    amount = _money(ref["amount_minor"])
    if ref.get("transfer") is False:  # N = 0: the plan is posted at approval, nothing transferred
        text = (
            f"Compensation le {when} avec les sommes encaissées pour votre compte, relevé de "
            f"reversement {run} (aucun virement) : {amount} ({on})."
        )
    else:
        text = (
            f"À régler par compensation sur le reversement {run} : {amount} (exécution demandée "
            f"le {when} ; {on})."
        )
    if ref.get("remainder_minor"):
        text += (
            f" Le solde de {_money(ref['remainder_minor'])} : à régler par compensation sur le "
            "prochain reversement de vos encaissements, au plus tard le "
            f"{format_date(ref.get('latest_date'))}."
        )
    return text


def _iban(iban: str) -> str:
    compact = iban.replace(" ", "")
    return " ".join(compact[i : i + 4] for i in range(0, len(compact), 4))


def _mentions(doc: InvoiceDocument, credit: bool) -> tuple[str, ...]:
    p = doc.payload
    out: list[str] = []
    if credit:
        v2 = doc.template_version == TEMPLATE_V2
        for c in p.get("corrections") or ():
            ref = doc.refs.get(str(c["original_invoice_id"])) or {}
            name = f"la facture {ref.get('number', '?')} du {format_date(ref.get('issue_date'))}"
            out.append(
                f"Avoir n° {doc.number} rectifiant {name} : HT {_money(c['ht'])}, "
                f"TVA {_money(c['vat'])}."
            )
            if not v2 and c.get("ht_after") is not None and c.get("vat_after") is not None:
                out.append(  # BOI-TVA-DECLA-30-20-20-20 §260: the totals after the reduction
                    f"Après cet avoir, {name} s'élève à {_money(c['ht_after'])} HT, "
                    f"TVA {_money(c['vat_after'])} ({percent(str(c['vat_rate']))})."
                )
        out.append(
            "Le montant de cet avoir est déduit des factures qu'il rectifie ; l'excédent éventuel "
            "vous est remboursé avec un prochain reversement."
            if v2
            else "Le montant de cet avoir est déduit des factures qu'il rectifie ; l'excédent "
            "éventuel vous est dû : il vous sera versé avec un prochain reversement, ou par "
            "virement s'il n'y en a pas."
        )
    else:
        out.append("Aucun rabais, remise ni ristourne.")
        out.append(_payment_line(doc))
        out.append("Pas d'escompte pour paiement anticipé.")
        out.append(str(p["penalty_text"]))
        # to every professional buyer, whatever was frozen about a proceeding (L441-9 I; legal#0)
        indemnity = p.get("flat_indemnity") or {}
        professional = (p.get("buyer") or {}).get("is_professional")
        if professional or (professional is None and indemnity.get("applies")):
            out.append(
                "Indemnité forfaitaire pour frais de recouvrement en cas de retard de paiement : "
                f"{_money(indemnity.get('amount_minor') or FLAT_INDEMNITY_MINOR)}."
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
