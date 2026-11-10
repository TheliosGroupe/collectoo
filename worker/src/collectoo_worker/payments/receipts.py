"""Receipts (M2-10, CPCE R124-6, design §10): the French wording of a receipt, from its payload.

The payload is built in SQL from the ledger (`private.receipt_payload`, migration
20261110090000): amounts are text in integer minor units with the currency's exponent, dates are
ISO. This module only formats them (« 1 234,56 € », « 09/11/2026 ») and lays out the locked French
template (`TEMPLATE_VERSION`); `receipt_pdf` draws exactly this view. No amount is computed here, no
model or LLM is involved, and the receipt carries no mention the law does not require (COMPLIANCE
OQ-22): no remaining balance until M3 computes interest (founder #14), the payer named only when
he is certainly a party to the file, otherwise « Versement d'un tiers » (founder #15; the SQL
decides, and leaves a third party's name out of the payload altogether). Each allocated component
is worded here for the debtor (`COMPONENT_LABEL`), never with the ledger's back-office labels
(« … déclarés par le cédant », « Écart au solde légal déclaré »: review #2).

Template versions (each stored receipt names its own; regenerating it uses that version, so its
bytes never change):
* `quittance-fr-2` (M2b-5 review): the issuer by its name only;
* `quittance-fr-3` (M2c-2, founder 2026-11-09): the issuer block a receipt (« récépissé »)
  must carry (C. com. R123-237: SIREN, « RCS » and the city of its registry, the registered
  office, « en liquidation » when it applies, « EI »; R123-238: the legal form and the capital
  next to the name), from the payload's `issuer` (built in SQL from `billing_identity`).
"""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any
from zoneinfo import ZoneInfo

TEMPLATE_VERSION = "quittance-fr-3"  # 3: the issuer block (R123-237/238; M2c-2)
# every version a stored receipt may name (2: debtor-facing component words, review #2)
TEMPLATE_VERSIONS = ("quittance-fr-2", "quittance-fr-3")
PARIS = ZoneInfo("Europe/Paris")
NNBSP = "\u202f"  # thousands separator, as Intl fr-FR prints it (the web pages)
NBSP = "\u00a0"  # between the amount and the currency sign
DASH = "\u2013"
THIRD_PARTY = "Versement d'un tiers"

METHOD_LABEL = {
    "sct": "Virement SEPA",
    "sdd": "Prélèvement SEPA",
    "card": "Carte bancaire",
    "cheque": "Chèque",
    "other": "Autre",
}
ITEM_KIND_LABEL = {
    "invoice": "Facture",
    "instalment": "Échéance",
    "rent_period": "Loyer",
    "judgment_head": "Condamnation",
    "loan_principal": "Prêt",
}
# What a component of an item is, in the debtor's words (ledger_component codes). The ledger's own
# labels describe the seller's tape for staff; a receipt states no cession, nor an internal
# reconciliation line. An unknown code prints as it is.
COMPONENT_LABEL = {
    "principal": "Principal",
    "accrued_interest": "Intérêts",
    "other_balances": "Autres sommes",
    "balancing_line": "Autres sommes",
}
CURRENCY_SIGN = {"EUR": "€"}
COUNTRY_FR = {"FR": "France", "BE": "Belgique", "LU": "Luxembourg", "MC": "Monaco", "CH": "Suisse"}


def format_money(minor: int | str, exponent: int, currency: str) -> str:
    """« 1 234,56 € »: integer minor units, French grouping and decimal comma (no float)."""
    value = int(minor)
    if exponent < 0:
        raise ValueError("a currency exponent is never negative")
    units, fraction = divmod(abs(value), 10**exponent)
    text = f"{units:,}".replace(",", NNBSP)
    if exponent:
        text += f",{fraction:0{exponent}d}"
    sign = "-" if value < 0 else ""
    return f"{sign}{text}{NBSP}{CURRENCY_SIGN.get(currency, currency)}"


def format_date(value: str | date | None) -> str:
    """« 09/11/2026 » (an ISO date or a date); empty for none."""
    if value is None or value == "":
        return ""
    day = value if isinstance(value, date) else date.fromisoformat(str(value)[:10])
    return day.strftime("%d/%m/%Y")


def paris_date(at: datetime) -> date:
    """The business day (Europe/Paris) of a time stored in UTC."""
    if at.tzinfo is None:
        raise ValueError("a time without its zone")
    return at.astimezone(PARIS).date()


@dataclass(frozen=True, slots=True)
class ReceiptDocument:
    """What a receipt version is rendered from: its row (number, version, kind, the time the
    ledger was read) and its payload. The PDF is a function of this and the template and renderer
    versions only."""

    number: str
    version: int
    kind: str  # original | update | void
    known_at: datetime
    payload: Mapping[str, Any]
    template_version: str = TEMPLATE_VERSION  # a stored receipt: the version it was issued with


@dataclass(frozen=True, slots=True)
class Row:
    label: str
    value: str


@dataclass(frozen=True, slots=True)
class AllocationLine:
    file: str
    item: str
    due: str
    nature: str
    amount: str


@dataclass(frozen=True, slots=True)
class ReceiptView:
    title: str
    number_line: str
    version_line: str
    issued_line: str
    issuer_lines: tuple[str, ...]  # quittance-fr-3: the issuer block (R123-237/238)
    parties: tuple[Row, ...]
    payment: tuple[Row, ...]
    allocation: tuple[AllocationLine, ...]
    show_file_column: bool
    totals: tuple[Row, ...]
    notes: tuple[str, ...]
    footer: str


def receipt_view(doc: ReceiptDocument) -> ReceiptView:
    """The locked French template (the receipt's template version) filled from the payload."""
    if doc.template_version not in TEMPLATE_VERSIONS:
        raise ValueError(f"unknown receipt template {doc.template_version!r}")
    p = doc.payload
    pay = p["payment"]
    money = _money(pay)
    void = doc.kind == "void" or p.get("state") == "void"
    file_ref = str(p["file"]["reference"])
    if doc.version == 1:
        version_line = "Version 1"
    else:
        verb = "annule" if void else "remplace"
        version_line = f"Version {doc.version} {DASH} {verb} la version {doc.version - 1}"
    issuer = f"{p['issuer']['name']}, agissant pour le compte de {p['creditor']['name']}"
    parties = (
        Row("Émetteur", issuer),
        Row("Débiteur", str(p["debtor"].get("name") or DASH)),
        Row("Dossier", file_ref),
    )
    if void:
        lines: tuple[AllocationLine, ...] = ()
        totals: tuple[Row, ...] = ()
        notes = [
            f"Ce paiement n'est plus rattaché au dossier {file_ref} : la version "
            f"{doc.version - 1} de cette quittance est annulée."
        ]
    else:
        lines = tuple(_line(x, money) for x in p.get("allocation") or ())
        totals, notes = _totals(p["totals"], bool(lines), money)
    letter = p.get("first_letter")
    if letter:  # R124-4 last paragraph (OQ-22): the first letter's reference and date, from M4
        notes.append(
            "Référence et date d'envoi de notre première lettre : "
            f"{letter['reference']}, {format_date(letter['sent_on'])}"
        )
    return ReceiptView(
        title="Quittance annulée" if void else "Quittance",
        number_line=f"N° {doc.number}",
        version_line=version_line,
        issued_line=f"Établie le {format_date(paris_date(doc.known_at))}",
        issuer_lines=issuer_block(p["issuer"]) if doc.template_version != "quittance-fr-2" else (),
        parties=parties,
        payment=_payment_rows(pay, None if void else p.get("payer") or {}, money),
        allocation=lines,
        show_file_column=any(line.file != file_ref for line in lines),
        totals=totals,
        notes=tuple(notes),
        footer=f"Quittance n° {doc.number} · version {doc.version}",
    )


def issuer_block(issuer: Mapping[str, Any]) -> tuple[str, ...]:
    """The issuer's mentions on a receipt (« récépissé », C. com. R123-237; R123-238):
    « Collectoo SAS au capital de 10 000 € », « SIREN 424 392 447 · RCS Paris », « Siège social :
    10 rue de la Bourse, 75002 Paris »; « en liquidation » (4°) and « EI » (9°, the form) when they
    apply. Nothing when the servicer has no billing identity (its name stays in « Émetteur »)."""
    if not issuer.get("siren"):
        return ()
    head = str(issuer["name"])
    if issuer.get("legal_form"):
        head += f" {issuer['legal_form']}"
    if issuer.get("share_capital_minor"):
        head += f" au capital de {_capital(str(issuer['share_capital_minor']))}"
    if issuer.get("in_liquidation"):
        head += f" {DASH} en liquidation"
    siren = str(issuer["siren"])
    ids = f"SIREN {siren[0:3]}{NNBSP}{siren[3:6]}{NNBSP}{siren[6:9]}"
    if issuer.get("rcs_city"):
        ids += f" · RCS {issuer['rcs_city']}"
    lines = [head, ids]
    office = issuer.get("registered_office") or {}
    if office:
        parts = [str(office["line1"])]
        if office.get("line2"):
            parts.append(str(office["line2"]))
        parts.append(f"{office['postcode']} {office['city']}")
        if office.get("country") and office["country"] != "FR":
            parts.append(COUNTRY_FR.get(str(office["country"]), str(office["country"])))
        lines.append("Siège social : " + ", ".join(parts))
    return tuple(lines)


def _capital(minor: str) -> str:
    """The capital in euros (R123-238 4° b: « peut être arrondi à la valeur entière inférieure »):
    whole euros without cents, otherwise to the cent."""
    text = format_money(minor, 2, "EUR")
    return text.replace(",00" + NBSP, NBSP)


def _money(pay: Mapping[str, Any]) -> Callable[[int | str], str]:
    exponent = int(pay["exponent"])
    currency = str(pay["currency"]).strip()
    return lambda minor: format_money(minor, exponent, currency)


def _payment_rows(
    pay: Mapping[str, Any], payer: Mapping[str, Any] | None, money: Callable[[int | str], str]
) -> tuple[Row, ...]:
    """The payment as the bank reported it; the payer only on a receipt in force (#15)."""
    rows = [
        Row("Montant reçu", money(pay["amount_minor"])),
        Row("Date de réception", format_date(pay["booking_date"])),
    ]
    if pay.get("value_date"):
        rows.append(Row("Date de valeur", format_date(pay["value_date"])))
    rows.append(Row("Mode de paiement", METHOD_LABEL.get(str(pay["method"]), "Autre")))
    if payer is not None:
        rows.append(Row("Payeur", payer_text(payer)))
    if pay.get("reference"):
        rows.append(Row("Référence de l'opération", str(pay["reference"])))
    return tuple(rows)


def _totals(
    t: Mapping[str, Any], allocated: bool, money: Callable[[int | str], str]
) -> tuple[tuple[Row, ...], list[str]]:
    """What was allocated, forwarded, not allocated and returned (each only when there is some);
    never a remaining balance (founder #14)."""
    rows = []
    if allocated:
        rows.append(Row("Total imputé", money(t["allocated_minor"])))
    for key, label in (
        ("forwarded_minor", "Reversé au créancier sans imputation"),
        ("unallocated_minor", "Montant non imputé"),
        ("returned_minor", "Montant restitué"),
    ):
        if int(t[key]):
            rows.append(Row(label, money(t[key])))
    notes = [] if allocated or int(t["forwarded_minor"]) else ["Aucune imputation à ce jour."]
    return tuple(rows), notes


def payer_text(payer: Mapping[str, Any]) -> str:
    """Founder #15: the payer's name only if he is a party to the file."""
    name = payer.get("name")
    if payer.get("third_party", True) or not name:
        return THIRD_PARTY
    return str(name)


def _line(x: Mapping[str, Any], money: Callable[[int | str], str]) -> AllocationLine:
    kind = ITEM_KIND_LABEL.get(str(x.get("item_kind")))
    item = f"{kind} {x['item_ref']}" if kind else str(x["item_ref"])
    return AllocationLine(
        file=str(x.get("file_reference") or ""),
        item=item,
        due=format_date(x.get("due_date")) or DASH,
        nature=COMPONENT_LABEL.get(str(x["component"]), str(x["component"])),
        amount=money(x["amount_minor"]),
    )


def receipt_text(doc: ReceiptDocument) -> str:
    """The receipt as plain text, line by line in the order the PDF draws it (snapshot tests)."""
    v = receipt_view(doc)
    out = [v.title, v.number_line, v.version_line, v.issued_line, ""]
    if v.issuer_lines:
        out += [*v.issuer_lines, ""]
    out += [f"{r.label} : {r.value}" for r in v.parties]
    out += ["", "Paiement reçu"]
    out += [f"{r.label} : {r.value}" for r in v.payment]
    if v.allocation:
        out += ["", "Imputation"]
        for line in v.allocation:
            cells: Sequence[str] = (line.item, line.due, line.nature, line.amount)
            if v.show_file_column:
                cells = (line.file, *cells)
            out.append(" | ".join(cells))
    if v.totals:
        out.append("")
        out += [f"{r.label} : {r.value}" for r in v.totals]
    if v.notes:
        out.append("")
        out += list(v.notes)
    out += ["", v.footer]
    return "\n".join(out)
