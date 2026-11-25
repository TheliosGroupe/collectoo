"""The letter « Demande de remboursement d'avance » (M2c-7c-2; plan docs/design/m2c-7-plan.md §5.3;
template `demande-remboursement-avance-fr-1`): the French wording of a request, from the payload
SQL froze when the request was made (private.advance_repayment_payload) — never from the current
settings. Amounts are text in minor units, dates ISO; nothing is computed here but their French
form, no model or LLM is involved (CLAUDE.md).

What the letter states, and only that ([critic] L6: facts per cause, no characterisation; founder
Q6 a; OQ-95 leaves its legal basis to counsel):
* the issuer's identity (R123-237/238: name, form, capital, SIREN, RCS city, registered office) and
  the recipient (the client's name and billing address; from M2c-7d-1 the person recorded who acts
  for it after a liquidation, a death or a tutelle, with its role for the client (« Tuteur de … »),
  and after a curatelle the client with « Copie : » its curator — private.client_addressee, frozen
  in the payload);
* the date, the subject and its reference (DRA-…);
* that the sums below were paid to the client beyond what was its due and remain to be repaid
  (« versées » when every row was paid out; « réglées » when an N = 0 run set one off or netted it);
* per advance: the day it was recorded, its mandate (« plusieurs mandats » for a payout of
  several, « — » with none), its origin worded from its facts — each date a recording date, in the
  real order of events ([critic] L3, M7-MONEY-9) —, what was paid beyond the due, what the client
  repaid already, what is asked (a part passed as a loss is never worded: LEX-28);
* the total, the own account to repay to (holder, IBAN) and the reference to quote;
* « Ce document n'est pas une facture. »
No legal article, no interest, no penalty, no due date, no formal notice. Never an RMT, SWP or TOP
id ([critic] M7-MONEY-6: only the DRA and run numbers). Never « versé » for an N = 0 run, nor for a
payout that came back and was not paid again (the request refuses `payout_not_received`; a payload
that would state one is refused here too).
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime, time
from typing import Any

from collectoo_worker.payments.receipts import format_date, format_money, issuer_block
from collectoo_worker.remittance.statement import address

TEMPLATE_VERSION = "demande-remboursement-avance-fr-1"
TEMPLATE_VERSIONS = (TEMPLATE_VERSION,)
CAUSES = ("remitted_reversal", "payout_overrun", "double_payout")
DASH = "—"
HEAD = ("Date", "Mandat", "Origine", "Versé", "Déjà remboursé", "Demandé")
# (review round 1, TUI-2) a request one of whose rows was set off or netted (an N = 0 run): no
# « Versé » head, no « versée » opening — [check 1], ADR D6: never « versé » for an N = 0 run
HEAD_SETTLED = ("Date", "Mandat", "Origine", "Montant", "Déjà remboursé", "Demandé")
# M2c-7d-1 (plan §6.2.12): the addressee who acts for the client, and the copy of a curatelle
ROLE_OF = {
    "notary": "Notaire — succession de",
    "heirs": "Héritiers — succession de",
    "tutor": "Tuteur de",
    "liquidator": "Liquidateur de",
}
COPY_ROLE = {"curator": "curateur"}


def _lines(lines: Any, what: str) -> str:
    if not isinstance(lines, list) or not lines or not all(isinstance(x, str) and x for x in lines):
        raise RepaymentRequestPayloadError(f"a {what} without its address")
    return ", ".join(lines)


class RepaymentRequestPayloadError(ValueError):
    """A payload the letter cannot state truthfully (or not of this template)."""


@dataclass(frozen=True, slots=True)
class RepaymentRequestDocument:
    """What a letter is rendered from: the request's number, issue date and frozen payload."""

    number: str
    issue_date: date
    payload: Mapping[str, Any]
    template_version: str = TEMPLATE_VERSION


@dataclass(frozen=True, slots=True)
class RequestRowView:
    recorded: str
    mandate: str
    origin: str
    paid: str
    repaid: str
    owed: str


@dataclass(frozen=True, slots=True)
class RequestView:
    issuer_lines: tuple[str, ...]
    recipient_lines: tuple[str, ...]
    date_line: str
    subject_line: str
    salutation: str
    opening: str
    head: tuple[str, ...]
    rows: tuple[RequestRowView, ...]
    total_line: str
    payment_line: str
    mentions: tuple[str, ...]
    closing: str
    signature: str
    footer: str


def _money(minor: int | str, currency: str) -> str:
    return format_money(minor, 2, currency)


def _iban(iban: str) -> str:
    compact = iban.replace(" ", "")
    return " ".join(compact[i : i + 4] for i in range(0, len(compact), 4))


def _day(value: Any, what: str) -> str:
    if not value:
        raise RepaymentRequestPayloadError(f"a row without its {what}")
    return format_date(str(value))


def _paid_clause(o: Mapping[str, Any]) -> str:
    """How the client received the collection (plan §3.2.1 `paid_how`), never « versé » for an
    N = 0 run, never stated for a payout that came back and was not paid again."""
    how, run = o.get("paid_how"), o.get("run_number")
    if not o.get("paid_on") or how is None:
        raise RepaymentRequestPayloadError(
            "a collection the client has not received (payout_not_received) is never requested"
        )
    on = format_date(str(o["paid_on"]))
    paid_run = o.get("paid_run_number") or run
    if how == "paid":
        if paid_run == run or not o.get("returned_via"):
            return f"versé le {on} (relevé {paid_run})"
        back = (
            f"après le retour du virement du relevé {run}"
            if o["returned_via"] == "run"
            else "après le retour d'un virement hors reversement"
        )
        return f"versé le {on} (relevé {paid_run}, {back})"
    if how == "unplanned":
        return f"versé le {on} par un virement hors reversement"
    if how == "set_off":
        return f"réglé par compensation dans le relevé {paid_run} du {on}"
    if how == "netted":
        return f"compris dans le relevé {paid_run} du {on} (montant net nul)"
    raise RepaymentRequestPayloadError(f"unknown paid_how {how!r}")


def _reversal_clause(o: Mapping[str, Any], currency: str, first: bool) -> str:
    """The reversal of the collection: a bank return (in part: what the bank took back and the
    allocation undone in full), a « Désimputer », or another reversal — on the day it was recorded
    (the return line's booking date for a bank return). `first`: it came before the payment."""
    kind = o.get("reversal")
    on = _day(o.get("reversed_on"), "reversal's date")
    if kind == "bank_return":
        if o.get("returned_minor"):
            return (
                f"paiement repris en partie par la banque le {on} "
                f"({_money(o['returned_minor'], currency)}) ; imputation annulée en entier "
                f"({_money(o['reversed_minor'], currency)})"
            )
        return f"repris par la banque du payeur le {on}"
    if kind == "unallocated":
        return f"imputation annulée le {on}" if first else f"annulé le {on} (imputation corrigée)"
    return f"annulé le {on}"


def origin_text(row: Mapping[str, Any], currency: str = "EUR") -> str:
    """A row's « Origine », deterministic from its facts, each date a recording date, in the real
    order: the payment then the reversal, or — a reversal recorded while the run was in flight, or
    before a later run paid the collection again — the reversal then the payment."""
    cause = row.get("cause")
    o = row.get("origin") or {}
    if cause == "payout_overrun":
        paid_on = _day(o.get("paid_on"), "payout date")
        return (
            f"Reversement {o.get('run_number')} versé le {paid_on} pour un montant supérieur à ce "
            "qui vous restait dû"
        )
    if cause == "double_payout":
        executed = _day(o.get("executed_on"), "execution date")
        beside = (
            f"en plus du reversement {o['run_number']}"
            if o.get("run_number")
            else "hors de tout reversement"
        )
        return (
            f"Virement exécuté par notre banque le {executed} {beside}, au-delà de ce qui vous "
            "restait dû"
        )
    if cause != "remitted_reversal":
        raise RepaymentRequestPayloadError(f"unknown cause {cause!r}")
    head = f"Encaissement du {_day(o.get('collected_on'), 'collection date')}"
    if o.get("file_ref"):
        head += f" (dossier {o['file_ref']})"
    paid = _paid_clause(o)
    # (review round 1, TUI-1) the dates' order: a reversal recorded while the run was in flight
    # comes first only when it is not dated after the payout's bank date (the debit's booking date
    # precedes the « Désimputer » when its statement is imported the next day)
    rev_on, paid_on = str(o.get("reversed_on")), str(o.get("paid_on"))
    in_flight = bool(o.get("in_flight")) and rev_on <= paid_on
    first = in_flight or rev_on < paid_on
    reversal = _reversal_clause(o, currency, first)
    if in_flight:
        run = o.get("run_number")
        return f"{head}, {reversal} alors que le reversement {run} était en cours, puis {paid}"
    if first:
        return f"{head}, {reversal}, puis {paid}"
    return f"{head}, {paid}, puis {reversal}"


def _paid_out(row: Mapping[str, Any]) -> bool:
    """Whether the row's sum reached the client by a transfer (« versé »): an overrun, a double
    payout, a collection paid by a run's payout or a payout outside any run — never one an N = 0 run
    set off or netted."""
    if row.get("cause") != "remitted_reversal":
        return True
    return (row.get("origin") or {}).get("paid_how") in ("paid", "unplanned")


def mandate_text(row: Mapping[str, Any]) -> str:
    """« Mandat »: the advance's mandate; with none, « plusieurs mandats » for a payout of a run
    of several mandates (an overrun, a double payout of a run), « — » otherwise (a forward on no
    file, a payout outside any run)."""
    if row.get("mandate"):
        return str(row["mandate"])
    o = row.get("origin") or {}
    if row.get("cause") in ("payout_overrun", "double_payout") and o.get("run_number"):
        return "plusieurs mandats"
    return DASH


def _check(doc: RepaymentRequestDocument) -> tuple[str, Sequence[Mapping[str, Any]]]:
    if doc.template_version not in TEMPLATE_VERSIONS:
        raise RepaymentRequestPayloadError(f"unknown template {doc.template_version!r}")
    p = doc.payload
    rows = list(p.get("rows") or ())
    if not rows:
        raise RepaymentRequestPayloadError("a request without rows")
    for r in rows:
        if r.get("cause") not in CAUSES:
            raise RepaymentRequestPayloadError(f"unknown cause {r.get('cause')!r}")
    if sum(int(r["open_minor"]) for r in rows) != int(p["total_minor"]):
        raise RepaymentRequestPayloadError("the rows do not add up to the request's total")
    return str(p.get("currency") or "EUR"), rows


def request_view(doc: RepaymentRequestDocument) -> RequestView:
    currency, rows = _check(doc)
    p = doc.payload
    issuer = p.get("issuer") or {}
    issuer_lines = tuple(issuer_block(issuer)) or (str(issuer.get("name", "")),)
    recipient = p.get("recipient") or {}
    # M2c-7d-1 (plan §6.2.12; [critic] L12, [check 1] gap 7): after a death, a tutelle or a
    # liquidation the person who acts for the client is the addressee (its role, for the client);
    # after a curatelle the client, with a copy to its curator — private.client_addressee
    role = recipient.get("role")
    recipient_lines = [str(recipient.get("name", ""))]
    if role is not None:
        if role not in ROLE_OF:
            raise RepaymentRequestPayloadError(f"unknown addressee {role!r}")
        recipient_lines.append(f"{ROLE_OF[role]} {recipient.get('client_name', '')}")
        recipient_lines.append(_lines(recipient.get("address_lines"), "addressee"))
    elif recipient.get("address"):
        recipient_lines.append(address(recipient["address"]))
    for c in p.get("copies") or ():
        if c.get("role") not in COPY_ROLE:
            raise RepaymentRequestPayloadError(f"unknown copy {c.get('role')!r}")
        where = _lines(c.get("address_lines"), "copy")
        recipient_lines.append(f"Copie : {c.get('name', '')}, {COPY_ROLE[c['role']]}, {where}")
    own = p.get("own_account") or {}
    one = len(rows) == 1
    # (review round 1, TUI-2) « versée(s) » and « Versé » only when every row was paid out; a
    # request with a row an N = 0 run set off or netted says « réglée(s) » and « Montant »
    paid_out = all(_paid_out(r) for r in rows)
    how = ("versée", "versées") if paid_out else ("réglée", "réglées")
    if role is not None:
        # (M2c-7d-1) the sums were paid to the client, not to the person who acts for it
        client = str(recipient.get("client_name", ""))
        opening = (
            f"La somme ci-dessous a été {how[0]} à {client} au-delà de ce qui lui revenait. Elle "
            "reste à rembourser au cabinet."
            if one
            else f"Les sommes ci-dessous ont été {how[1]} à {client} au-delà de ce qui lui "
            "revenait. "
            "Elles restent à rembourser au cabinet."
        )
    else:
        opening = (
            f"La somme ci-dessous vous a été {how[0]} au-delà de ce qui vous revenait. Elle reste "
            "à rembourser au cabinet."
            if one
            else f"Les sommes ci-dessous vous ont été {how[1]} au-delà de ce qui vous revenait. "
            "Elles restent à rembourser au cabinet."
        )
    holder = own.get("holder") or issuer.get("name", "")
    return RequestView(
        issuer_lines=issuer_lines,
        recipient_lines=tuple(recipient_lines),
        date_line=f"Le {format_date(doc.issue_date)}",
        subject_line=f"Objet : Demande de remboursement {DASH} référence {doc.number}",
        salutation="Madame, Monsieur,",
        opening=opening,
        head=HEAD if paid_out else HEAD_SETTLED,
        rows=tuple(
            RequestRowView(
                recorded=_day(r.get("recorded_on"), "recording date"),
                mandate=mandate_text(r),
                origin=origin_text(r, currency),
                paid=_money(r["amount_minor"], currency),
                repaid=_money(r["repaid_minor"], currency),
                owed=_money(r["open_minor"], currency),
            )
            for r in rows
        ),
        total_line=f"Total à rembourser : {_money(p['total_minor'], currency)}",
        payment_line=(
            "Nous vous remercions de bien vouloir nous rembourser cette somme par virement sur "
            f"notre compte : titulaire {holder}, IBAN {_iban(str(own.get('iban', '')))}, en "
            f"indiquant la référence {doc.number}."
        ),
        mentions=("Ce document n'est pas une facture.",),
        closing="Veuillez agréer, Madame, Monsieur, l'expression de nos salutations distinguées.",
        signature=str(issuer.get("name", "")),
        footer=f"Demande de remboursement n° {doc.number}",
    )


def issued_at(doc: RepaymentRequestDocument) -> datetime:
    """The PDF's date: the issue date at midnight UTC (from the request, never the clock)."""
    return datetime.combine(doc.issue_date, time(0, 0), tzinfo=UTC)


def request_text(doc: RepaymentRequestDocument) -> str:
    """The letter as plain text, in the order the PDF draws it (snapshot tests)."""
    v = request_view(doc)
    out = [*v.issuer_lines, "", *v.recipient_lines, "", v.date_line, v.subject_line, ""]
    out += [v.salutation, "", v.opening, "", " | ".join(v.head)]
    out += [" | ".join((r.recorded, r.mandate, r.origin, r.paid, r.repaid, r.owed)) for r in v.rows]
    out += ["", v.total_line, "", v.payment_line, ""]
    out += list(v.mentions)
    out += ["", v.closing, v.signature, "", v.footer]
    return "\n".join(out)
