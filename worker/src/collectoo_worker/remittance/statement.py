"""The client statement « Relevé de reversement » (M2-14; design §10; C. civ. 1993 « rendre
compte »): the French wording of a statement, from its payload.

The payload is built once in SQL (`private.remittance_statement_build`, migration
20261113090000): amounts are text in minor units with the currency's exponent, dates ISO, and every
line an array in the order `line_columns` names. This module only words and formats it (locked
template `TEMPLATE_VERSION`); `statement_csv` writes its lines and `statement_pdf` draws its
summary. Nothing is computed here but the layout: every amount, total and date is the payload's,
which comes from the run's frozen lines, its documents and the ledger; no model or LLM is involved.
No wording says « payé » or « réglé » before the bank's debit (M2c-6 books it): a payout is
« ordonné », a set-off « à régler par compensation ».
"""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime
from typing import Any

from collectoo_worker.payments.receipts import (
    COMPONENT_LABEL,
    COUNTRY_FR,
    DASH,
    ITEM_KIND_LABEL,
    NNBSP,
    PARIS,
    format_date,
    format_money,
    issuer_block,
)
from collectoo_worker.remittance.run import percent

TEMPLATE_VERSION = "releve-reversement-fr-1"
TEMPLATE_VERSIONS = (TEMPLATE_VERSION,)
PDF_FILE_ROWS_MAX = 2000  # above this, the PDF names the CSV for the detail (design §10)

NATURE = {
    "allocation": "Paiement imputé",
    "allocation_reversal": "Imputation annulée",
    "forward": "Reversement sans imputation",
    "forward_reversal": "Reversement sans imputation annulé",
    "client_advance": "Avance du cabinet",
    "client_advance_reversal": "Avance du cabinet annulée",
    "payout_returned": "Virement revenu impayé — reversé à nouveau",
    "unplanned_payout": "Virement exécuté hors reversement",
}
FORWARD_REASON = {
    "file_recalled": "dossier rappelé",
    "before_servicing_start": "antérieur à la reprise",
    "client_ratification": "ratification",
}
BANK_RETURN = {
    "allocation_reversal": "Paiement repris par la banque du payeur",
    "forward_reversal": "Reversement sans imputation repris par la banque du payeur",
}
# why money received on a file waits (payment.review_reason), and why it went back to the payer
HELD_REASON = {
    "hold_blocks_allocation": "paiement bloqué (procédure en cours)",
    "nothing_due": "aucune somme due sur le dossier",
    "credit_note_to_apply": "avoir à imputer",
    "overpayment": "trop-perçu",
    "before_servicing_start": "antérieur à la reprise du dossier",
    "account_closed": "dossier clos",
    "currency_mismatch": "autre devise",
    "partial_return": "reste d'un retour partiel",
    "no_mandate": "dossier sans mandat",
    "account_not_confirmed": "dossier non confirmé",
    "allocation_reversed": "imputation annulée",
    "pending": "en cours d'imputation",
}
REFUND_REASON = {
    "overpayment": "trop-perçu",
    "currency_mismatch": "paiement dans une autre devise",
    "no_mandate": "dossier sans mandat",
    "unidentified": "paiement non identifié",
    "held_file": "dossier bloqué",
    "account_closed": "dossier clos",
    "partial_return": "reste d'un retour partiel",
    "other": "autre motif",
}
CSV_HEADER = (
    "releve",
    "date_releve",
    "mandat",
    "portefeuille",
    "dossier",
    "debiteur",
    "piece",
    "composante",
    "nature",
    "date_encaissement",
    "date_imputation",
    "date_limite_reversement",
    "montant",
    "montant_centimes",
    "regle",
    "taux",
    "base_commission_centimes",
    "commission_ht",
    "commission_ht_centimes",
    "facture",
    "quittance",
    "hors_delai",
)


@dataclass(frozen=True, slots=True)
class StatementLine:
    """One line of the statement as the CSV writes it (a run's line, or an earlier line whose
    commission this run priced: amount 0)."""

    mandate: str
    portfolio: str
    file: str
    debtor: str
    items: str
    components: str
    nature: str
    encaissement_date: str  # ISO
    effective_date: str  # ISO
    deadline: str  # ISO
    amount_minor: int
    rules: str
    rates: str
    basis_minor: int
    commission_minor: int
    invoice: str
    receipt: str
    late: str


def line_records(payload: Mapping[str, Any]) -> list[StatementLine]:
    """The payload's lines, worded (same order)."""
    cols = {name: i for i, name in enumerate(payload["line_columns"])}
    out = []
    for row in payload["lines"]:
        v = {name: row[i] for name, i in cols.items()}
        out.append(
            StatementLine(
                mandate=str(v["mandate"] or ""),
                portfolio=str(v["portfolio"] or ""),
                file=str(v["file"] or ""),
                debtor=str(v["debtor"] or ""),
                items=" ; ".join(_item(k, ref) for k, ref in v["items"] or ()),
                components=" ; ".join(
                    COMPONENT_LABEL.get(str(c), str(c)) for c in _distinct(v["components"] or ())
                ),
                nature=nature(str(v["nature"]), v["nature_reason"], v["from_run"]),
                encaissement_date=str(v["encaissement_date"] or ""),
                effective_date=str(v["effective_date"] or ""),
                deadline=str(v["deadline"] or ""),
                amount_minor=int(v["amount_minor"]),
                rules=_rules(v),
                rates=" ; ".join(percent(str(r)) for r in v["rates"] or ()),
                basis_minor=int(v["basis_minor"]),
                commission_minor=int(v["commission_minor"]),
                invoice=str(v["invoice"] or ""),
                receipt=str(v["receipt"] or ""),
                late=_late(v["late"], v["late_reason"]),
            )
        )
    return out


def _distinct(values: Sequence[Any]) -> list[Any]:
    return list(dict.fromkeys(values))


def _item(kind: str, ref: str) -> str:
    label = ITEM_KIND_LABEL.get(kind)
    return f"{label} {ref}" if label else str(ref)


def _rules(v: Mapping[str, Any]) -> str:
    if v["commission_state"] == "pending":
        return "Commission en attente"
    return " ; ".join(str(r) for r in v["rules"] or ())


def _late(late: Any, reason: Any) -> str:
    if not late:
        return ""
    return f"oui {DASH} {reason}" if reason else "oui"


def nature(kind: str, reason: Any, from_run: Any) -> str:
    """The nature of a line in the client's words (§10.2)."""
    if from_run:
        return f"Commission sur un encaissement du relevé {from_run}"
    if kind == "repricing":
        return "Commission sur des encaissements de relevés précédents"
    if reason == "bank_return" and kind in BANK_RETURN:
        return BANK_RETURN[kind]
    base = NATURE.get(kind, kind)
    if kind == "forward" and reason in FORWARD_REASON:
        return f"{base} ({FORWARD_REASON[str(reason)]})"
    return base


# -- the summary (PDF) ----------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Section:
    title: str
    rows: tuple[tuple[str, str], ...] = ()  # (label, amount)
    texts: tuple[str, ...] = ()  # paragraphs
    table: tuple[tuple[str, ...], tuple[tuple[str, ...], ...]] | None = None  # (head, rows)
    note: str = ""


@dataclass(frozen=True, slots=True)
class StatementView:
    title: str
    number_line: str
    issued_line: str
    known_line: str
    issuer_lines: tuple[str, ...]
    client_lines: tuple[str, ...]
    mandate_lines: tuple[str, ...]
    period_line: str
    sections: tuple[Section, ...]
    footer: str


def money_of(payload: Mapping[str, Any]) -> Callable[[int | str], str]:
    exponent = int(payload["exponent"])
    currency = str(payload["currency"]).strip()
    return lambda minor: format_money(minor, exponent, currency)


def known_at(payload: Mapping[str, Any]) -> datetime:
    return datetime.fromisoformat(str(payload["known_at"]).replace("Z", "+00:00")).astimezone(UTC)


def _paris(at: datetime) -> str:
    local = at.astimezone(PARIS)
    return f"{local:%d/%m/%Y} à {local:%H:%M}"


def statement_view(payload: Mapping[str, Any], csv_sha256: str) -> StatementView:
    """The locked French template `releve-reversement-fr-1` filled from the payload."""
    money = money_of(payload)
    k = known_at(payload)
    number = str(payload["number"])
    issuer = payload["issuer"]
    issuer_lines = [*issuer_block(issuer)] or [str(issuer["name"])]
    if issuer.get("vat_number"):
        issuer_lines.append(f"N° de TVA intracommunautaire : {issuer['vat_number']}")
    issuer_lines.append("agissant en qualité de mandataire de recouvrement amiable")
    period = payload["service_period"]
    return StatementView(
        title="Relevé de reversement",
        number_line=f"N° {number}",
        issued_line=f"Établi le {format_date(payload['issue_date'])}",
        known_line=f"Encaissements connus au {_paris(k)}",
        issuer_lines=tuple(issuer_lines),
        client_lines=_client_lines(payload["client"]),
        mandate_lines=tuple(_mandate_line(m) for m in payload["mandates"]),
        period_line=(
            f"Période : du {format_date(period['from'])} au {format_date(period['to'])} · "
            f"devise : {str(payload['currency']).strip()}"
        ),
        sections=(
            _summary(payload, money),
            _collected(payload, money, csv_sha256),
            _deductions(payload, money),
            _payout(payload, money),
            _follow_up(payload, money),
            _not_remitted(payload),
            _position(payload, money, k),
        ),
        footer=f"Relevé de reversement {number} · CSV SHA-256 {csv_sha256[:16]}…",
    )


def _client_lines(client: Mapping[str, Any]) -> tuple[str, ...]:
    out = [f"Mandant : {client['name']}"]
    if client.get("siren"):
        s = str(client["siren"])
        out.append(f"SIREN {s[0:3]}{NNBSP}{s[3:6]}{NNBSP}{s[6:9]}")
    addr = client.get("billing_address") or client.get("registered_office")
    if addr:
        out.append(address(addr))
    return tuple(out)


def address(a: Mapping[str, Any]) -> str:
    parts = [str(a["line1"])]
    if a.get("line2"):
        parts.append(str(a["line2"]))
    parts.append(f"{a['postcode']} {a['city']}")
    if a.get("country") and a["country"] != "FR":
        parts.append(COUNTRY_FR.get(str(a["country"]), str(a["country"])))
    return ", ".join(parts)


def _mandate_line(m: Mapping[str, Any]) -> str:
    refs = []
    for key, label in (
        ("commission_clause_ref", "rémunération"),
        ("remittance_clause_ref", "reversements"),
        ("netting_clause_ref", "compensation"),
        ("clawback_clause_ref", "reprise des avances"),
    ):
        if m.get(key):
            refs.append(f"{label} : {m[key]}")
    line = f"Mandat {m['reference']}"
    if m.get("signed_on"):
        line += f" du {format_date(m['signed_on'])}"
    return line + (f" ({' ; '.join(refs)})" if refs else "")


def _summary(p: Mapping[str, Any], money: Callable[[int | str], str]) -> Section:
    t = p["totals"]
    rows = [
        ("Sommes encaissées pour votre compte", money(t["collected_minor"])),
        ("Encaissements annulés ou repris", money(t["reversed_minor"])),
        ("Montant brut à reverser", money(t["gross_minor"])),
    ]
    if int(t["invoice_ttc_minor"]) or int(t["credit_ttc_minor"]):
        rows.append(("Factures de commission (TTC)", money(t["invoice_ttc_minor"])))
        rows.append(("Avoirs (TTC)", money(-int(t["credit_ttc_minor"]))))
    if int(t["commission_taken_minor"]):
        rows.append(
            ("Commission à régler par compensation", money(-int(t["commission_taken_minor"])))
        )
    if int(t["advance_recovered_minor"]):
        rows.append(
            ("Avances à régler par compensation", money(-int(t["advance_recovered_minor"])))
        )
    if int(t["refund_minor"]):
        rows.append(("Remboursement d'avoir inclus", money(t["refund_minor"])))
    rows.append(("Montant net du reversement", money(t["net_minor"])))
    return Section("Récapitulatif", rows=tuple(rows))


def _collected(p: Mapping[str, Any], money: Callable[[int | str], str], csv_sha256: str) -> Section:
    t = p["totals"]
    texts = [
        f"{t['line_count']} encaissement(s) sur {t['file_count']} dossier(s). Commission HT de la "
        f"période : {money(t['commission_ht_minor'])}."
    ]
    if int(t.get("repriced_count", 0)):
        texts.append(
            f"Dont la commission de {t['repriced_count']} encaissement(s) de relevés précédents, "
            "restée en attente jusqu'ici."
        )
    if int(t["late_count"]):
        texts.append(
            f"{t['late_count']} encaissement(s) reversé(s) hors délai : le détail et leur motif "
            "figurent dans le fichier CSV (colonne hors_delai)."
        )
    files = p["files"]
    table = None
    note = ""
    if len(files) <= PDF_FILE_ROWS_MAX:
        table = (
            ("Dossier", "Débiteur", "Encaiss.", "Montant", "Commission HT"),
            tuple(
                (
                    str(f["file"] or "Hors dossier"),
                    str(f["debtor"] or DASH),
                    str(f["lines"]),
                    money(f["amount_minor"]),
                    money(f["commission_minor"]),
                )
                for f in files
            ),
        )
        note = (
            "Le détail de chaque encaissement (pièces, nature, dates, règle et taux de commission, "
            f"facture, quittance) figure dans le fichier CSV joint (SHA-256 {csv_sha256})."
        )
    else:
        note = (
            f"{len(files)} dossiers : détail complet dans le fichier CSV joint "
            f"(SHA-256 {csv_sha256})."
        )
    rows = tuple(
        (f"{nature(str(n['kind']), n['reason'], None)} ({n['count']})", money(n["amount_minor"]))
        for n in p["natures"]
    )
    return Section(
        "Sommes encaissées pour votre compte", rows=rows, texts=tuple(texts), table=table, note=note
    )


def _deductions(p: Mapping[str, Any], money: Callable[[int | str], str]) -> Section:
    texts: list[str] = []
    for d in p["documents"]:
        texts.append(_document_text(d, p, money))
    for e in p["earlier_settled"]:
        what = "Facture" if e.get("document_kind") == "invoice" else "Avoir"
        if e["kind"] == "refund":
            texts.append(
                f"Avoir {e['number']} du {format_date(e['issue_date'])} : remboursement "
                f"inclus dans le présent reversement : {money(e['amount_minor'])}."
            )
        elif e["kind"] == "advance":
            texts.append(
                "Remboursement d'une avance du cabinet : à régler par compensation sur le présent "
                f"reversement : {money(e['amount_minor'])}."
            )
        else:
            texts.append(
                f"{what} {e['number']} du {format_date(e['issue_date'])} : à régler par "
                f"compensation sur le présent reversement : {money(e['amount_minor'])}."
            )
    if not texts:
        texts.append("Aucune retenue ni compensation sur ce reversement.")
    return Section("Retenues et compensations", texts=tuple(texts))


def _document_text(
    d: Mapping[str, Any], p: Mapping[str, Any], money: Callable[[int | str], str]
) -> str:
    head = "Facture" if d["kind"] == "invoice" else "Avoir"
    text = f"{head} {d['number']} du {format_date(d['issue_date'])} (mandat {d['mandate']}) : HT "
    text += f"{money(d['ht_minor'])}"
    if d["kind"] == "invoice":
        text += f", TVA {percent(str(d['vat_rate']))} {money(d['vat_minor'])}"
    else:
        text += f", TVA {money(d['vat_minor'])}"
    text += f", TTC {money(d['ttc_minor'])}."
    corrects = d.get("corrects") or []
    if corrects:
        text += (
            " Rectifie "
            + ", ".join(
                f"la facture {c['number']} du {format_date(c['issue_date'])}" for c in corrects
            )
            + "."
        )
    clause = f" ({d['clause_ref']} du mandat)" if d.get("clause_ref") else ""
    settles = int(d.get("settles_minor") or 0)
    ref = d.get("payment_reference") or {}
    if d["kind"] == "invoice":
        if d["settlement"] == "due":
            acc = d.get("own_account") or {}
            text += f" À régler au plus tard le {format_date(d['due_date'])}"
            if acc.get("iban"):
                text += f" sur le compte {acc['iban']} (compte propre du cabinet)"
            text += "."
        elif settles:
            text += (
                f" À régler par compensation sur le présent reversement{clause} : {money(settles)}."
            )
        elif ref.get("mode") == "next_run":
            text += (
                f" À régler par compensation sur le prochain reversement{clause}, au plus tard le "
                f"{format_date(ref.get('latest_date'))}."
            )
        else:
            text += f" À régler par compensation sur un prochain reversement{clause}."
    else:
        text += " Son montant est déduit des factures qu'il rectifie"
        if settles:
            text += (
                f" ; l'excédent vous est remboursé avec le présent reversement : {money(settles)}"
            )
        text += "."
    return text


def _payout(p: Mapping[str, Any], money: Callable[[int | str], str]) -> Section:
    t = p["totals"]
    out = p.get("payout")
    if p.get("status") == "cancelled":
        texts = [
            f"Reversement annulé le {format_date(p.get('cancelled_on'))} avant l'exécution de "
            "son virement : les sommes vous revenant figureront sur un prochain relevé, et ses "
            "factures sont annulées par avoir."
        ]
    elif out:
        texts = [
            f"Virement de {money(out['amount_minor'])} ordonné le {format_date(out['ordered_on'])} "
            f"vers {out['iban']} (titulaire {out['holder']}), exécution demandée le "
            f"{format_date(out['requested_execution_date'])}, référence {out['end_to_end_id']}."
        ]
    elif int(t["gross_minor"]) == 0:
        texts = ["Aucun virement : les encaissements de la période s'annulent."]
    else:
        texts = [
            "Aucun virement : le montant net est nul, les sommes vous revenant étant compensées "
            "par les documents ci-dessus."
        ]
    return Section(
        "Reversement", rows=(("Montant net", money(t["net_minor"])),), texts=tuple(texts)
    )


def _follow_up(p: Mapping[str, Any], money: Callable[[int | str], str]) -> Section:
    texts = []
    for f in p.get("follow_up") or ():
        status = f.get("transfer_status")
        if status is None:
            texts.append(f"Relevé {f['number']} : aucun virement (montant net nul).")
        elif status == "booked":
            texts.append(
                f"Relevé {f['number']} : virement de {money(f['amount_minor'])} débité de notre "
                f"compte dédié le {format_date(f.get('debited_on'))}."
            )
        elif status == "returned":
            texts.append(
                f"Relevé {f['number']} : virement de {money(f['amount_minor'])} revenu impayé le "
                f"{format_date(f.get('returned_on'))} ; il vous est proposé à nouveau."
            )
        elif status == "cancelled":
            texts.append(f"Relevé {f['number']} : virement annulé avant son exécution.")
        else:
            texts.append(
                f"Relevé {f['number']} : virement de {money(f['amount_minor'])} ordonné, exécution "
                f"demandée le {format_date(f.get('requested_execution_date'))} ; son débit n'est "
                "pas encore constaté sur notre relevé bancaire."
            )
    if not texts:
        texts.append("Aucun reversement précédent à suivre.")
    return Section("Suivi de vos reversements précédents", texts=tuple(texts))


def _not_remitted(p: Mapping[str, Any]) -> Section:
    nr = p["not_remitted"]
    texts = []
    for h in nr["held"]:
        money = _currency_money(str(h["currency"]), p)
        texts.append(
            f"Dossier {h['file']} : {money(h['amount_minor'])} reçus et en attente — "
            f"{HELD_REASON.get(str(h['reason']), str(h['reason']))} ({_dates(h)})."
        )
    for r in nr["refunded"]:
        money = _currency_money(str(r["currency"]), p)
        texts.append(
            f"Dossier {r['file']} : {money(r['amount_minor'])} restitués au payeur — "
            f"{REFUND_REASON.get(str(r['reason']), str(r['reason']))} ({_dates(r, 'le')})."
        )
    if not texts:
        texts.append("Aucune somme reçue sur vos dossiers n'est restée sans reversement.")
    return Section("Sommes reçues sur vos dossiers et non reversées", texts=tuple(texts))


def _currency_money(currency: str, p: Mapping[str, Any]) -> Callable[[int | str], str]:
    exponent = int(p["exponent"]) if currency.strip() == str(p["currency"]).strip() else 2
    return lambda minor: format_money(minor, exponent, currency.strip())


def _dates(x: Mapping[str, Any], single: str = "reçus le") -> str:
    first, last = format_date(x["first_date"]), format_date(x["last_date"])
    if first == last:
        return f"{single} {first}"
    return f"du {first} au {last}"


def _position(p: Mapping[str, Any], money: Callable[[int | str], str], k: datetime) -> Section:
    pos = p["position"]
    at = format_date(k.astimezone(PARIS).date())
    rows = [
        (f"Sommes vous revenant au {at}", money(pos["owed_before_minor"])),
        ("Après le présent reversement", money(pos["owed_after_minor"])),
        (f"Factures de commission restant dues au {at}", money(pos["receivable_before_minor"])),
        ("Après le présent relevé et son règlement", money(pos["receivable_after_minor"])),
    ]
    if int(pos["advances_before_minor"]) or int(pos["advances_after_minor"]):
        rows += [
            (f"Avances du cabinet à rembourser au {at}", money(pos["advances_before_minor"])),
            ("Après le présent reversement", money(pos["advances_after_minor"])),
        ]
    return Section(
        "Position",
        rows=tuple(rows),
        texts=(
            "Les compensations sont réalisées au débit du virement sur notre compte dédié ; "
            "jusque-là elles restent à régler.",
        ),
    )


def statement_text(payload: Mapping[str, Any], csv_sha256: str) -> str:
    """The statement as plain text, in the order the PDF draws it (snapshot tests)."""
    v = statement_view(payload, csv_sha256)
    out = [v.title, v.number_line, v.issued_line, v.known_line, ""]
    out += [*v.issuer_lines, "", *v.client_lines, *v.mandate_lines, v.period_line]
    for s in v.sections:
        out += ["", s.title]
        out += list(s.texts)
        out += [f"{label} : {value}" for label, value in s.rows]
        if s.table is not None:
            head, rows = s.table
            out.append(" | ".join(head))
            out += [" | ".join(r) for r in rows]
        if s.note:
            out.append(s.note)
    out += ["", v.footer]
    return "\n".join(out)


def issue_day(payload: Mapping[str, Any]) -> date:
    return date.fromisoformat(str(payload["issue_date"]))
