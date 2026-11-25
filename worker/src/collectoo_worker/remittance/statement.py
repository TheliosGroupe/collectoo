"""The client statement « Relevé de reversement » (M2-14; design §10; C. civ. 1993 « rendre
compte »): the French wording of a statement, from its payload.

The payload is built once in SQL (`private.remittance_statement_build`, migration
20261113090000): amounts are text in minor units with the currency's exponent, dates ISO, and every
line an array in the order `line_columns` names. This module only words and formats it (locked
template `TEMPLATE_VERSION`); `statement_csv` writes its lines and `statement_pdf` draws its
summary. Nothing is computed here but the layout: every amount, total and date is the payload's,
which comes from the run's frozen lines, its documents and the ledger; no model or LLM is involved.
No wording says « payé » or « réglé » before the bank's debit (M2c-6 books it): a payout is
« ordonné », a set-off « à régler par compensation » — « compensé le … » only when the run transfers
nothing (N = 0: the settlement is posted at approval). A run cancelled before its statement is drawn
says so, and sets nothing off. A late line states a cause the data supports, never the approver's
free text (review legal#6). Since M2c-6b-2d (template fr-3, migration 20261117120000) « Suivi »
words the events of the client's earlier runs' payouts posted in the window from the previous
approved run's K to this K (`previous_payouts`), each one sentence from the payload's amounts and
dates; a payload of another template is refused (`StatementPayloadError`, `payload_version`).
Since M2c-7d-3 (template fr-4, migration 20261128090000) a payload of schema 2 adds what fr-3 cannot
word — the end of the mandate known at K (« Fin du mandat »: its day, the day the servicer recorded
it, the payee it requires), who the statement is addressed to (by role only), the set-offs a debit
withheld that this run gives back, each advance taken back with its date — and is drawn by fr-4; a
payload of schema 1 is drawn by fr-3, its bytes unchanged (`template_of`).
"""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime
from itertools import pairwise
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

# M2c-6b-2d (plan §5): « Suivi » words the events of the earlier runs' payouts as of K
# (`previous_payouts`); fr-2 drew M2c-5's `follow_up`. Stored statements are never re-rendered
# (their bytes are kept); a payload built for another template is refused.
# M2c-7d-3 (plan §6.2.8): fr-4 draws the payloads of schema 2 (« Fin du mandat », the addressee, the
# withheld set-off given back, the advances' dates); fr-3 still draws schema 1, byte for byte.
TEMPLATE_V3 = "releve-reversement-fr-3"
TEMPLATE_VERSION = "releve-reversement-fr-4"
TEMPLATE_VERSIONS = (TEMPLATE_V3, TEMPLATE_VERSION)
SCHEMA_TEMPLATE = {1: TEMPLATE_V3, 2: TEMPLATE_VERSION}
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
    # M2c-7d-2 (plan §6.2.11 (a) 8): a set-off withheld at a payout's debit (the client's status
    # barred it by then), given back with this run (no file, no commission). A new code only: no
    # payload drawn before carries it (fr-3 renders it; 7d-3's fr-4 adds the row that explains it)
    "settlement_withheld": "Compensation retenue au débit, rendue",
}
# M2c-6b-2b (review LT-2; plan §5, critic L4, brought forward from 6b-2d): the item an unplanned
# payout's return re-owes (payload nature_reason `unplanned` on a payout_returned line) — its money
# came back unpaid and is owed again, never « reversé à nouveau ». A new code only: no payload
# drawn before carries it (no template version).
UNPLANNED_RETURN = "Virement exécuté hors reversement revenu"

FORWARD_REASON = {
    "file_recalled": "dossier rappelé",
    "before_servicing_start": "antérieur à la reprise",
    "client_ratification": "ratification",
    # M2c-7d-1 (plan §6.2.8; founder Q10): a payment received after the client's mandate ended,
    # forwarded without allocation and without commission (no schedule key). A new code only: no
    # payload drawn before carries it (no template version)
    "mandate_ended": "reçu après la fin du mandat",
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
    "refund_pending": "à restituer au payeur",
}
# why a line was paid after its latest execution date (payload `late_cause`, a category the data
# supports: review legal#6). M2c-6b-1 review round 2 (L1): a payout of it that came back unpaid,
# paid again — the line keeps the date of the run line it came from (K2), so its lateness is the
# return's, never a collection's. A new code only: no payload drawn before carries it, so the
# template's bytes for them are unchanged (no new template version).
LATE_CAUSE = {
    "payout_returned": "virement revenu impayé, reversé à nouveau",
    # M2c-6b-2b (review LT-2): an unplanned payout's return, its item held to the date of the
    # items it paid (critic2 ML-2); a new code only, as above
    "unplanned_payout_returned": "virement exécuté hors reversement revenu impayé",
    "unmeetable": "délai contractuel intenable (art. R124-6 : un mois)",
    "identified_late": "encaissement identifié tardivement",
    "approved_late": "validation tardive",
    # M2c-6b-2d (critic L9, critic2 ML-9; Q15's default: the item keeps its own clock): an unplanned
    # payout's P paid all of the line, as of K — worded with that payout's date (« versé le … »);
    # review round 1 (legal-texts-3): one it paid in part keeps its own cause, the attribution
    # added after it (« … ; dont … versés le … »): `_late`
    "paid_by_unplanned": "par un virement exécuté hors reversement",
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


class StatementPayloadError(ValueError):
    """A payload this template cannot draw (code `payload_version`): built for another template
    (M2c-5's `follow_up`, no `previous_payouts`), or holding a fact it does not word. Never drawn
    with a section missing; the documents job records the failure and retries the statement."""

    code = "payload_version"

    def __init__(self, detail: str) -> None:
        super().__init__(f"{self.code}: {detail}")


FR4_KEYS = ("mandate_end", "addressees", "withheld_given_back")
# (M2c-7d-3) what fr-4 words: an end of the mandate (C. civ. 2003 names « la mort, la tutelle des
# majeurs », the revocation and the renunciation; a curatelle ends nothing), a payee, a role
END_CAUSE = {
    "death": "décès du mandant",
    "guardianship": "tutelle du mandant",
    "mandate_ended": "révocation ou renonciation du mandat",
}
PAYEE_ACCOUNT = {
    "estate": "de la succession (compte du notaire, ou compte désigné par tous les héritiers)",
    "protected_adult": ("ouvert au nom du mandant, la personne protégée (C. civ. 427)"),
    "client": "du mandant, confirmé à nouveau",
    "court_appointed": "du liquidateur",
}
ADDRESSEE = {
    "notary": "À l'attention du notaire chargé de la succession du mandant",
    "heirs": "À l'attention des héritiers du mandant",
    "tutor": "À l'attention du tuteur du mandant",
    "liquidator": "À l'attention du liquidateur du mandant",
    "administrator": "À l'attention de l'administrateur judiciaire du mandant",
}
COPY_TO = {"curator": "Copie : le curateur du mandant"}


def template_of(payload: Mapping[str, Any]) -> str:
    """The template a payload is drawn by (M2c-7d-3): fr-3 for schema 1, fr-4 for schema 2."""
    template = SCHEMA_TEMPLATE.get(payload.get("schema", 1))
    if template is None:
        raise StatementPayloadError(f"schema {payload.get('schema')!r}")
    return template


def check_payload(payload: Mapping[str, Any]) -> None:
    """The payload is one `releve-reversement-fr-3` or `-fr-4` draws (M2c-6b-2d, migration
    20261117120000): its « Suivi » is `previous_payouts`, never M2c-5's `follow_up`; (M2c-7d-3) a
    schema-1 payload holds none of fr-4's facts, a schema-2 one only facts fr-4 words."""
    template = template_of(payload)
    if "follow_up" in payload or not isinstance(payload.get("previous_payouts"), Mapping):
        raise StatementPayloadError(f"not a {template} payload (« Suivi »)")
    if template == TEMPLATE_V3:
        if any(k in payload for k in FR4_KEYS):
            raise StatementPayloadError(f"a {TEMPLATE_V3} payload with fr-4's facts")
        return
    _check_fr4(payload)


def _check_fr4(payload: Mapping[str, Any]) -> None:
    end = payload.get("mandate_end")
    if end is not None and (
        end.get("kind") not in END_CAUSE
        or not end.get("effective_date")
        or not end.get("recorded_on")
        or (end.get("payee_kind") not in PAYEE_ACCOUNT and end.get("payee_kind") != "to_qualify")
    ):
        raise StatementPayloadError(f"mandate_end {end!r}")
    if end is not None:
        _check_earlier_ends(end)
    for a in payload.get("addressees") or ():
        known = COPY_TO if a.get("copy") else ADDRESSEE
        if a.get("role") != "client" and a.get("role") not in known:
            raise StatementPayloadError(f"addressee {a!r}")
    for w in payload.get("withheld_given_back") or ():
        if not (w.get("run_number") and w.get("withheld_on") and w.get("reason")):
            raise StatementPayloadError(f"withheld_given_back {w!r}")
    for e in payload.get("earlier_settled") or ():
        if e.get("kind") == "advance" and not e.get("born_on"):
            raise StatementPayloadError("an advance taken back without its date")


def _check_earlier_ends(end: Mapping[str, Any]) -> None:
    """(Review round 3) the ends the code applied before the one at K (`earlier`), as the SQL
    builds them: each an end fr-4 words, known on a day before the next one's (the end at K's
    last) and earlier in effect than each end before it — else its sentences would not be true."""
    chain = [*(end.get("earlier") or ()), end]
    for e in chain[:-1]:
        if e.get("kind") not in END_CAUSE or not (e.get("effective_date") and e.get("recorded_on")):
            raise StatementPayloadError(f"mandate_end earlier {e!r}")
    for a, b in pairwise(chain):
        if not (
            str(a["recorded_on"]) < str(b["recorded_on"])
            and str(a["effective_date"]) > str(b["effective_date"])
        ):
            raise StatementPayloadError(f"mandate_end earlier {a!r} before {b!r}")


def line_records(payload: Mapping[str, Any]) -> list[StatementLine]:
    """The payload's lines, worded (same order)."""
    check_payload(payload)
    cols = {name: i for i, name in enumerate(payload["line_columns"])}
    money = money_of(payload)
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
                late=_late(v, money),
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


def _late(v: Mapping[str, Any], money: Callable[[int | str], str]) -> str:
    if not v["late"]:
        return ""
    cause = v.get("late_cause")
    if cause == "paid_by_unplanned":
        return f"oui {DASH} {_paid_by_unplanned(v)}"
    label = LATE_CAUSE.get(str(cause)) if cause else None
    text = f"oui {DASH} {label}" if label else "oui"
    if v.get("paid_by_unplanned_minor") is not None:
        # review round 1 (legal-texts-3): an unplanned payout paid part of the line — the line's
        # own cause stays (it is the remainder's), the attribution follows it
        on = v.get("paid_by_unplanned_on")
        if not on:
            raise StatementPayloadError("paid_by_unplanned_minor without its date")
        text += (
            f"{' ;' if label else f' {DASH}'} dont {money(v['paid_by_unplanned_minor'])} versés "
            f"le {format_date(on)} {LATE_CAUSE['paid_by_unplanned']}"
        )
    return text


def _paid_by_unplanned(v: Mapping[str, Any]) -> str:
    """critic L9, critic2 ML-9: « versé le … » when the amount an unplanned payout's P attributed
    to the line (as of K) is all of it — the payload's cause `paid_by_unplanned` says so (review
    round 1, legal-texts-3: a part keeps the line's own cause, `_late`); without the amount and the
    date, or with an amount short of the line, the cause cannot be worded truthfully."""
    paid, on = v.get("paid_by_unplanned_minor"), v.get("paid_by_unplanned_on")
    if paid is None or not on:
        raise StatementPayloadError("paid_by_unplanned without its amount or date")
    if int(paid) < int(v["amount_minor"]):
        raise StatementPayloadError("paid_by_unplanned for part of the line")
    return f"versé le {format_date(on)} {LATE_CAUSE['paid_by_unplanned']}"


def nature(kind: str, reason: Any, from_run: Any) -> str:
    """The nature of a line in the client's words (§10.2)."""
    if from_run:
        return f"Commission sur un encaissement du relevé {from_run}"
    if kind == "repricing":
        return "Commission sur des encaissements de relevés précédents"
    if reason == "bank_return" and kind in BANK_RETURN:
        return BANK_RETURN[kind]
    if kind == "payout_returned" and reason == "unplanned":
        return UNPLANNED_RETURN
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
    """The locked French template — `releve-reversement-fr-3`, or (M2c-7d-3) `-fr-4` for a payload
    of schema 2 (`template_of`) — filled from the payload (one it draws: `check_payload`)."""
    check_payload(payload)
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
        client_lines=_client_lines(payload["client"]) + _addressee_lines(payload),
        mandate_lines=tuple(_mandate_line(m) for m in payload["mandates"]),
        period_line=(
            f"Période : du {format_date(period['from'])} au {format_date(period['to'])} · "
            f"devise : {str(payload['currency']).strip()}"
        ),
        sections=(
            *_mandate_end(payload),
            _summary(payload, money),
            _collected(payload, money, csv_sha256),
            _deductions(payload, money),
            _payout(payload, money),
            _previous_payouts(payload, money),
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


def _addressee_lines(p: Mapping[str, Any]) -> tuple[str, ...]:
    """(M2c-7d-3, [critic] L12) who the statement is addressed to, by role only (the names and
    addresses of who acts for the client stay staff's): the notary, the heirs, the tutor, the
    liquidator; after a curatelle the client, the curator in copy. Nothing for the client alone."""
    out = []
    for a in p.get("addressees") or ():
        role = str(a.get("role"))
        if role == "client":
            continue
        out.append(COPY_TO[role] if a.get("copy") else ADDRESSEE[role])
    return tuple(out)


def _mandate_end(p: Mapping[str, Any]) -> tuple[Section, ...]:
    """(M2c-7d-3, plan §6.4; [critic] L13) « Fin du mandat »: the end known at K, worded around the
    day the servicer recorded it — what it did before was done under the mandate; from that day
    the payments received on the files since the end are set aside (forwarded without commission
    or restored to their payers, case by case), nothing owed to the servicer is deducted from a
    payout, and the payouts go to the account the end requires — each what the code does.
    (Review round 3) Each end the code applied before the one at K (`earlier`) is stated with its
    own day: informed of an end, and nothing deducted, from the first; each end's payments set
    aside from the day it was known."""
    end = p.get("mandate_end")
    if not end:
        return ()
    eff, rec = format_date(end["effective_date"]), format_date(end["recorded_on"])
    # (review round 3) the ends the code applied before the one at K, each from its own day (the
    # SQL's `earlier`): informed of an end from the first day, each end's payments set aside from
    # the day it was known, nothing deducted from the first day — one end: the sentences as before
    earlier = [
        (format_date(e["effective_date"]), format_date(e["recorded_on"]), END_CAUSE[str(e["kind"])])
        for e in end.get("earlier") or ()
    ]
    steps = [*((e, r) for e, r, _c in earlier), (eff, rec)]
    first_eff, first = steps[0]
    later = [f"depuis le {r}, ceux reçus à partir du {e}" for e, r in steps[1:]]
    if later:
        later[-1] = "et " + later[-1]
    aside = ", ".join(
        [f"depuis le {first}, les paiements reçus sur vos dossiers à partir du {first_eff} sont "
         "mis de côté", *later]
    )  # fmt: skip
    before = "d'être informé d'une fin du mandat" if earlier else "d'en être informé"
    texts = [
        f"Le mandat a pris fin le {eff} ({END_CAUSE[str(end['kind'])]}) ; le cabinet en a été "
        f"informé le {rec}."
    ]
    if earlier:
        told = ", puis ".join(f"le {r} d'une fin du mandat le {e} ({c})" for e, r, c in earlier)
        texts.append(f"Auparavant, le cabinet avait été informé {told}.")
    texts += [
        "Ce relevé rend compte des sommes encaissées pour votre compte. Ce que le cabinet a fait "
        f"avant {before} l'a été selon le mandat ; {aside} : ils sont reversés sans commission, ou "
        "restitués à leurs payeurs, au cas par cas.",
        "Ce que vous devez au cabinet (factures, avances) figure dans la position ci-dessous ; "
        f"depuis le {first}, il n'est plus déduit des reversements.",
    ]
    payee = str(end["payee_kind"])
    if payee == "to_qualify":
        texts.append(
            "Les reversements sont suspendus jusqu'à ce que la mesure de protection soit précisée."
        )
    else:
        texts.append(f"Les reversements sont faits sur le compte confirmé {PAYEE_ACCOUNT[payee]}.")
    return (Section("Fin du mandat", texts=tuple(texts)),)


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


def _cancelled(p: Mapping[str, Any]) -> bool:
    return p.get("status") == "cancelled"


def _settled_on(p: Mapping[str, Any]) -> str:
    """The approval date when the run transfers nothing (N = 0: its settlement posted then), else
    empty."""
    return format_date(p.get("settled_on")) if p.get("settled_on") else ""


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
    if _cancelled(p):
        # nothing is transferred nor set off: the run's documents are annulled by credit note
        texts = (
            f"Reversement annulé le {format_date(p.get('cancelled_on'))} avant l'exécution de son "
            "virement : rien n'a été viré ni compensé ; les sommes vous revenant figureront sur un "
            "prochain relevé.",
        )
        return Section("Récapitulatif", rows=tuple(rows), texts=texts)
    done = _settled_on(p)
    if int(t["commission_taken_minor"]):
        label = (
            f"Commission compensée le {done}" if done else "Commission à régler par compensation"
        )
        rows.append((label, money(-int(t["commission_taken_minor"]))))
    if int(t["advance_recovered_minor"]):
        label = f"Avances compensées le {done}" if done else "Avances à régler par compensation"
        rows.append((label, money(-int(t["advance_recovered_minor"]))))
    if int(t["refund_minor"]):
        rows.append(("Remboursement d'avoir inclus", money(t["refund_minor"])))
    rows.append(("Montant net du reversement", money(t["net_minor"])))
    return Section("Récapitulatif", rows=tuple(rows))


def _absorbed_text(t: Mapping[str, Any], money: Callable[[int | str], str]) -> str:
    """What the run's credits absorbed of manual credit notes' waivers (M2c-5b; review legal#4): a
    credit already issued by the manual credit note named — never « rendu », which would read as
    money returned while a refund it leaves is only ordered with the payout."""
    notes = t.get("waived_absorbed_credit_notes") or ()
    if notes:
        named = ", ".join(f"n° {n['number']} rectifiant la facture {n['invoice']}" for n in notes)
        which = f"(avoir{'s' if len(notes) > 1 else ''} {named})"
    else:  # a payload frozen without the credit notes: the invoices it was absorbed on
        invoices = [str(n) for n in t.get("waived_absorbed_invoices") or ()]
        which = f"sur {'les factures' if len(invoices) > 1 else 'la facture'} {', '.join(invoices)}"
    return (
        f"Dont {money(-int(t['waived_absorbed_minor']))} de commission sur des encaissements "
        f"annulés, déjà crédités par avoir manuel {which} : aucun nouvel avoir pour ce montant."
    )


def _collected(p: Mapping[str, Any], money: Callable[[int | str], str], csv_sha256: str) -> Section:
    t = p["totals"]
    texts = [
        f"{t['line_count']} encaissement(s) sur {t['file_count']} dossier(s). Commission HT de la "
        f"période : {money(t['commission_ht_minor'])}."
    ]
    if int(t.get("waived_absorbed_minor", 0)):  # M2c-5b: absent from payloads drawn before
        texts.append(_absorbed_text(t, money))
    if int(t.get("repriced_count", 0)):
        texts.append(
            f"Dont la commission de {t['repriced_count']} encaissement(s) de relevés précédents, "
            "restée en attente jusqu'ici."
        )
    if int(t.get("repriced_only_file_count", 0)):
        texts.append(
            f"{t['repriced_only_file_count']} dossier(s) du tableau n'ont pas d'encaissement "
            "dans ce relevé : seule la commission d'encaissements précédents y est calculée."
        )
    if int(t["late_count"]):
        texts.append(
            f"{t['late_count']} encaissement(s) reversé(s) hors délai : le détail et leur cause "
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
    done = _settled_on(p)
    on_run = (
        f"compensation le {done}"
        if done
        else "à régler par compensation sur le présent reversement"
    )
    for e in p["earlier_settled"]:
        what = "Facture" if e.get("document_kind") == "invoice" else "Avoir"
        if e["kind"] == "refund":
            how = (
                f"remboursement par compensation le {done}"
                if done
                else "remboursement inclus dans le présent reversement"
            )
            texts.append(
                f"Avoir {e['number']} du {format_date(e['issue_date'])} : {how} : "
                f"{money(e['amount_minor'])}."
            )
        elif e["kind"] == "advance" and e.get("born_on"):
            # (M2c-7d-3, plan §1.2) fr-4: the advance's date, as the client space prints it
            texts.append(
                f"Remboursement de l'avance du cabinet née le {format_date(e['born_on'])} : "
                f"{on_run} : {money(e['amount_minor'])}."
            )
        elif e["kind"] == "advance":
            texts.append(
                f"Remboursement d'une avance du cabinet : {on_run} : {money(e['amount_minor'])}."
            )
        else:
            texts.append(
                f"{what} {e['number']} du {format_date(e['issue_date'])} : {on_run} : "
                f"{money(e['amount_minor'])}."
            )
    texts += [_withheld_text(w, p, money) for w in p.get("withheld_given_back") or ()]
    if not texts:
        texts.append("Aucune retenue ni compensation sur ce reversement.")
    return Section("Retenues et compensations", texts=tuple(texts))


def _withheld_text(
    w: Mapping[str, Any], p: Mapping[str, Any], money: Callable[[int | str], str]
) -> str:
    """(M2c-7d-3, plan §6.2.8; [critic] M7-MONEY-5) a set-off a debit withheld (the client's
    status barred it by then: the reason the ledger recorded, « règle du cabinet » in it) that this
    run gives back — « rendue » only when the run is not cancelled."""
    head = f"Compensation retenue sur {w['run_number']}"
    why = (
        f"Au débit de son virement le {format_date(w['withheld_on'])}, cette compensation n'a pas "
        f"été faite (« {w['reason']} »)"
    )
    if _cancelled(p):
        return (
            f"{head} : {money(w['amount_minor'])}. {why} ; ce reversement étant annulé, la somme "
            "figurera sur un prochain reversement."
        )
    return (
        f"{head} et rendue : {money(w['amount_minor'])}. {why} ; la somme est reprise dans le "
        "présent reversement."
    )


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
    if d["kind"] != "invoice":
        text += " Son montant est déduit des factures qu'il rectifie"
        settles = int(d.get("settles_minor") or 0)
        if settles and _settled_on(p):
            text += f" ; l'excédent vous est remboursé par compensation : {money(settles)}"
        elif settles:
            text += (
                f" ; l'excédent vous est remboursé avec le présent reversement : {money(settles)}"
            )
        return text + "."
    return text + _invoice_payment(d, p, money)


def _invoice_payment(
    d: Mapping[str, Any], p: Mapping[str, Any], money: Callable[[int | str], str]
) -> str:
    """How the run's invoice is paid, as its frozen payment reference states it (review legal#4:
    what the plan sets off on this run, and the remainder on the next run by its date)."""
    annulled = d.get("cancelled_by") or []
    if annulled:
        return (
            " Annulée par "
            + ", ".join(
                f"l'avoir {c['number']} du {format_date(c['issue_date'])}" for c in annulled
            )
            + "."
        )
    if d["settlement"] == "due":
        acc = d.get("own_account") or {}
        text = f" À régler au plus tard le {format_date(d['due_date'])}"
        if acc.get("iban"):
            text += f" sur le compte {acc['iban']} (compte propre du cabinet)"
        return text + "."
    clause = f" ({d['clause_ref']} du mandat)" if d.get("clause_ref") else ""
    settles = 0 if _cancelled(p) else int(d.get("settles_minor") or 0)
    ref = d.get("payment_reference") or {}
    ttc = int(d["ttc_minor"])
    latest = ref.get("latest_date") or d.get("due_date")
    text = ""
    if settles:
        done = _settled_on(p)
        if done:
            text += (
                f" Compensée le {done} avec les sommes vous revenant{clause} : {money(settles)}."
            )
        else:
            text += (
                f" À régler par compensation sur le présent reversement{clause} : {money(settles)}."
            )
        rest = ttc - settles
        if rest > 0:
            text += (
                f" Solde de {money(rest)} : à régler par compensation sur le prochain reversement"
            )
            text += f", au plus tard le {format_date(latest)}." if latest else "."
        return text
    if latest:
        return (
            f" À régler par compensation sur le prochain reversement{clause}, au plus tard le "
            f"{format_date(latest)}."
        )
    return f" À régler par compensation sur un prochain reversement{clause}."


def _payout(p: Mapping[str, Any], money: Callable[[int | str], str]) -> Section:
    t = p["totals"]
    out = p.get("payout")
    if _cancelled(p):
        texts = [
            f"Reversement annulé le {format_date(p.get('cancelled_on'))} avant l'exécution de "
            "son virement : les sommes vous revenant figureront sur un prochain relevé, et ses "
            "factures sont annulées par avoir."
        ]
        return Section("Reversement", texts=tuple(texts))
    if out:
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


# « Suivi » (M2c-6b-2d, plan §5): one sentence per event of `previous_payouts` (the SQL's order:
# its date, then the run number), each from the payload's amounts and dates alone. An event this
# run does not hold (`here` false: it was booked after this run's items were taken, or this run was
# cancelled since) is « pris en compte dans un prochain reversement ».
SUIVI_TITLE = "Suivi de vos reversements précédents"
NEXT_RUN = " ; il sera pris en compte dans un prochain reversement."
# why the advance could not be deducted from the client's waiting sums, by the bound that set P
# (critic F17, L16, critic2 ML-9: the booking recorded it; `amount`: no advance, no clause)
ADVANCE_CAUSE = {
    "items": " : elle dépassait ce qui restait à vous reverser des sommes de ce reversement",
    "none": " : elle dépassait ce qui restait à vous reverser des sommes de ce reversement",
    "queue": " : vos sommes en attente à cette date ne permettaient pas d'en déduire davantage",
}


def masked_iban_end(last4: Any) -> str:
    """An IBAN by its last four characters, as the pages print one (review 6b-2c T1, pages-2:
    « IBAN …1234 », never a country code or check digits assumed)."""
    return f"IBAN …{last4}" if last4 else ""


def _previous_payouts(p: Mapping[str, Any], money: Callable[[int | str], str]) -> Section:
    pp = p["previous_payouts"]
    texts = [_event_text(e, money) for e in pp.get("events") or ()]
    if not texts:
        since = pp.get("since")
        if since:
            at = _paris(datetime.fromisoformat(str(since["known_at"]).replace("Z", "+00:00")))
            texts.append(
                "Rien à signaler sur vos reversements précédents depuis le relevé "
                f"{since['number']} (encaissements connus au {at})."
            )
        else:
            texts.append("Aucun reversement précédent à suivre.")
    return Section(SUIVI_TITLE, texts=tuple(texts))


def _event_text(e: Mapping[str, Any], money: Callable[[int | str], str]) -> str:  # noqa: PLR0911
    kind, run, on = e.get("kind"), e.get("run_number"), format_date(e.get("on"))
    if kind == "debited":
        return (
            f"Reversement {run} : virement de {money(e['amount_minor'])} (référence "
            f"{e['end_to_end_id']}) débité de notre compte dédié le {on}."
        )
    if kind == "returned":
        head = (
            f"Reversement {run} : virement de {money(e['amount_minor'])} débité le "
            f"{format_date(e.get('debited_on'))}, revenu impayé le {on}"
        )
        if e.get("repaid") == "here":
            return (
                f"{head} ; son montant figure dans le présent reversement "
                f"(« {NATURE['payout_returned']} »)."
            )
        if e.get("repaid") == "run" and e.get("repaid_by"):
            return f"{head} ; reversé à nouveau par le reversement {e['repaid_by']}."
        return f"{head} ; son montant vous sera reversé par un prochain reversement."
    if kind == "cancelled":
        return f"Reversement {run} annulé le {on}, avant que son virement soit remis à la banque."
    if kind == "executed_after_cancellation":
        head = _after_cancellation_head(e, money, run, on)
        if not e.get("here"):
            return head + NEXT_RUN
        return (
            f"{head} ; ce montant, que vous avez reçu, figure dans le présent reversement "
            f"(« {NATURE['unplanned_payout']} »){_advance_clause(e, money)}."
        )
    if kind == "debited_again":
        head, this = _debited_again_head(e, money, run, on)
        if not e.get("here"):
            return head + NEXT_RUN
        advance = int(e.get("advance_minor") or 0)
        extra = (
            f", et « {NATURE['client_advance']} » pour {this} ({money(advance)})"
            if advance > 0
            else ""
        )
        return (
            f"{head} ; {this}, que vous avez reçu, figure dans le présent reversement "
            f"(« {NATURE['unplanned_payout']} »{extra})."
        )
    if kind == "unplanned_returned":
        return _unplanned_returned(e, money, on)
    if kind == "executed_outside":
        iban = masked_iban_end(e.get("iban_last4"))
        head = (
            f"Virement de {money(e['amount_minor'])} vers votre compte{' ' + iban if iban else ''} "
            f"le {on}, exécuté hors de tout reversement"
        )
        if not e.get("here"):
            return head + NEXT_RUN
        with_advance = (
            f" et « {NATURE['client_advance']} »" if int(e.get("advance_minor") or 0) else ""
        )
        return (
            f"{head} : il figure dans le présent reversement (« {NATURE['unplanned_payout']} »"
            f"{with_advance})."
        )
    raise StatementPayloadError(f"« Suivi » event {kind!r}")


def _execution_no(e: Mapping[str, Any]) -> int:
    """The execution's rank among its transfer chain's executions booked by K (review round 1:
    legal-texts-1), as the SQL gave it; a payload without it cannot be worded truthfully."""
    n = e.get("execution_no")
    if n is None or int(n) < 1:
        raise StatementPayloadError(f"« Suivi » event {e.get('kind')!r} without its execution rank")
    return int(n)


def _after_cancellation_head(
    e: Mapping[str, Any], money: Callable[[int | str], str], run: Any, on: str
) -> str:
    """A cancelled run's payout executed all the same: « néanmoins » the first time, « de nouveau »
    (with its rank) for each later execution — never the same sentence twice (review round 1)."""
    cancelled = f"Reversement {run} annulé le {format_date(e.get('cancelled_on'))} : la banque a "
    amount = money(e["unplanned_minor"])
    n = _execution_no(e)
    if n == 1:
        return f"{cancelled}néanmoins exécuté son virement de {amount} le {on}"
    return f"{cancelled}de nouveau exécuté son virement de {amount} le {on} ({n}e exécution)"


def _debited_again_head(
    e: Mapping[str, Any], money: Callable[[int | str], str], run: Any, on: str
) -> tuple[str, str]:
    """A booked (or returned) payout executed again, and how the rest of its sentence names it
    (review round 1: statement-money, legal-texts-1). « une seconde fois » only of the second
    execution; a later one « de nouveau » with its rank; one the bank made before the planned debit
    (booked after it) is neither: it was executed « en plus de son débit du … »."""
    amount = money(e["unplanned_minor"])
    debited_on = e.get("debited_on")
    if not debited_on:
        raise StatementPayloadError("debited_again without the debit it repeats")
    n = _execution_no(e)
    if e.get("before_debit"):
        return (
            f"Reversement {run} : la banque a exécuté son virement le {on} ({amount}), en plus de "
            f"son débit du {format_date(debited_on)}",
            "ce virement en plus",
        )
    if n < 2:
        raise StatementPayloadError("debited_again ranked first but not before its debit")
    if n == 2:
        return (
            f"Reversement {run} : la banque a exécuté son virement une seconde fois le {on} "
            f"({amount})",
            "ce second virement",
        )
    return (
        f"Reversement {run} : la banque a exécuté son virement de nouveau le {on} ({amount} ; "
        f"{n}e exécution)",
        "ce nouveau virement",
    )


def _advance_clause(e: Mapping[str, Any], money: Callable[[int | str], str]) -> str:
    """The servicer's advance of an execution after cancellation (critic F17, L16) and why it could
    not be deducted, by the bound that set P (critic2 ML-9): none when P = A."""
    advance = int(e.get("advance_minor") or 0)
    if advance <= 0:
        return ""
    return (
        f", et « {NATURE['client_advance']} » pour la part qui n'a pas pu être déduite de vos "
        f"sommes en attente ({money(advance)}){ADVANCE_CAUSE.get(str(e.get('p_bound')), '')}"
    )


def _unplanned_returned(e: Mapping[str, Any], money: Callable[[int | str], str], on: str) -> str:
    """The return of an unplanned payout (critic L4): its advance reversed, P owed again — each
    said only when the payload's amount for it is not nil."""
    parts = []
    if int(e.get("advance_minor") or 0) > 0:
        parts.append("l'avance du cabinet correspondante est annulée")
    if int(e.get("owed_minor") or 0) > 0:
        parts.append(f"{money(e['owed_minor'])} vous sont de nouveau dus")
    text = (
        f"Le virement de {money(e['unplanned_minor'])} exécuté hors reversement le "
        f"{format_date(e.get('executed_on'))} est revenu le {on}"
    )
    if parts:
        text += " : " + " et ".join(parts)
    if e.get("here"):
        text += f" ; voir « {UNPLANNED_RETURN} » dans le présent reversement"
    return text + "."


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
    return Section(
        "Sommes reçues sur vos dossiers et non reversées",
        texts=(f"Au {_paris(known_at(p))} :", *texts),
    )


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
    cancelled = _cancelled(p)
    done = _settled_on(p)
    if cancelled:
        after = "Après l'annulation du reversement"
    elif done:
        after = f"Après les compensations du {done}"
    else:
        after = "Après le présent reversement"
    rows = [
        (f"Sommes vous revenant au {at}", money(pos["owed_before_minor"])),
        (after, money(pos["owed_after_minor"])),
        (f"Factures de commission restant dues au {at}", money(pos["receivable_before_minor"])),
        (
            "Après le présent relevé" if cancelled else "Après le présent relevé et son règlement",
            money(pos["receivable_after_minor"]),
        ),
    ]
    if int(pos["advances_before_minor"]) or int(pos["advances_after_minor"]):
        rows += [
            (f"Avances du cabinet à rembourser au {at}", money(pos["advances_before_minor"])),
            (after, money(pos["advances_after_minor"])),
        ]
    if cancelled:
        text = (
            "Le reversement étant annulé, aucune compensation n'est réalisée : les factures de ce "
            "relevé sont annulées par avoir."
        )
    elif done:
        text = f"Les compensations ci-dessus ont été réalisées le {done}, sans virement."
    else:
        text = (
            "Les compensations sont réalisées au débit du virement sur notre compte dédié ; "
            "jusque-là elles restent à régler."
        )
    return Section("Position", rows=tuple(rows), texts=(text,))


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
