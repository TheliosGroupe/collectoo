"""What a client's payment to the servicer settles (M2c-7c-1; plan docs/design/m2c-7-plan.md §5.2.3;
ADR-0014 « M2c-7c-1 »). Pure; the twin of private.client_payment_plan, the core of
private.client_settlement_plan that « Règlement du client » (own account) and « Règlement d'une
facture ou d'une avance du cabinet » (dedicated account) post (parity: Hypothesis, the db job).

* With the client's designation ([critic] L16; C. civ. 1342-10 al. 1): the documents it names, in
  its order, each up to its open part — one it may not pay (a claim born before its proceeding
  opened, L622-7 I al. 1: `payable` false) is held for the procedure, never settled — then the
  written-off advances it names, each up to what is left to recover ([critic] M7-MONEY-10): a
  recovery, or (review round 1, MONEY-1) held for the procedure the same way when the client may not
  repay it (`payable` false), never income; the rest is a credit owed back to it, never another
  document.
* Without it, the default order — our reading of 1342-10 al. 2 (founder Q4, OQ-89): invoices due on
  or before the payment's date by (due date, year, number), then advances by (birth, recording,
  id), then the other invoices by (due date, nulls last, year, number) — skipping what the client
  may not pay ([check 1] gap 11); the rest a credit owed back.
* A credit owed back is of cause `procedure` for a designated document (or written-off advance) the
  client may not pay, and for the surplus while a proceeding of the client stands; else
  `overpayment` ([critic] M7-MONEY-10, L21). One row per payment and cause (their sum is the
  entry's 419 credit line).
* VAT moved on an invoice part: R(pending x part / open), all of it when the part closes it.

Amounts are integer minor units; documents in flight (an approved or sent run settles them) are
the caller's: never passed here."""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime
from typing import Literal

from collectoo_worker.remittance.settlement import vat_part

DocumentKind = Literal["invoice", "advance"]
PartKind = Literal["invoice", "advance", "written_off", "client_credit"]
CreditCause = Literal["overpayment", "procedure"]


class ClientPaymentInputError(ValueError):
    """Inputs the plan cannot settle (a data error, never a client's refusal)."""


@dataclass(frozen=True)
class PayableDocument:
    """An open invoice or advance of the client (open part > 0), not in flight."""

    kind: DocumentKind
    id: str
    open_minor: int
    pending_vat_minor: int = 0
    payable: bool = True  # private.document_client_payable on the payment's date
    due_date: date | None = None  # an invoice's
    year: int = 0
    seq: int = 0
    born_on: date | None = None  # an advance's (private.advance_born_on)
    created_at: datetime | None = None  # an advance's recording


@dataclass(frozen=True)
class WrittenOff:
    """A written-off advance the client designates: what is left to recover (passed as a loss less
    what was already recovered), and whether the client may repay it on the payment's date (review
    round 1, MONEY-1: private.client_payment_recoveries' `payable`, document_client_payable)."""

    id: str
    available_minor: int
    payable: bool = True


@dataclass(frozen=True)
class PaymentPart:
    ord: int
    document_kind: PartKind
    document_id: str | None  # None: the surplus
    amount_minor: int
    vat_moved_minor: int
    cause: CreditCause | None  # a client_credit part's


_NONE = datetime.min.replace(tzinfo=UTC)


def _key(d: PayableDocument, on: date) -> tuple[int, date, int, int, datetime, str]:
    if d.kind == "invoice" and d.due_date is not None and d.due_date <= on:
        return (0, d.due_date, d.year, d.seq, _NONE, d.id)
    if d.kind == "advance":
        if d.born_on is None or d.created_at is None:
            raise ClientPaymentInputError(f"{d.id}: an advance has its birth and its recording")
        return (1, d.born_on, 0, 0, d.created_at, d.id)
    return (2, d.due_date or date.max, d.year, d.seq, _NONE, d.id)


def default_order(docs: Iterable[PayableDocument], on: date) -> list[PayableDocument]:
    """The order the default plan pays the documents in (what may not be paid included: the caller
    filters it)."""
    return sorted(docs, key=lambda d: _key(d, on))


def _check(docs: Sequence[PayableDocument], recover: Sequence[WrittenOff]) -> None:
    for d in docs:
        if d.open_minor <= 0 or d.pending_vat_minor < 0 or d.pending_vat_minor > d.open_minor:
            raise ClientPaymentInputError(f"{d.id}: an open part > 0 and its pending VAT within it")
    for w in recover:
        if w.available_minor <= 0:
            raise ClientPaymentInputError(f"{w.id}: something left to recover")


def _part(d: PayableDocument, part: int) -> tuple[PartKind, int, CreditCause | None]:
    """A document's part: settled (its VAT moved, an invoice's), or held for the procedure when the
    client may not pay it."""
    if not d.payable:
        return "client_credit", 0, "procedure"
    return (
        d.kind,
        vat_part(d.pending_vat_minor, d.open_minor, part) if d.kind == "invoice" else 0,
        None,
    )


def _recovery(w: WrittenOff) -> tuple[PartKind, int, CreditCause | None]:
    """A written-off advance's part: a recovery (7714), or held for the procedure when the client
    may not repay it (review round 1, MONEY-1)."""
    return ("written_off", 0, None) if w.payable else ("client_credit", 0, "procedure")


def _ordered(
    docs: Sequence[PayableDocument],
    named: Sequence[str],
    recover: Sequence[WrittenOff],
    on: date,
) -> list[PayableDocument | WrittenOff]:
    """What the payment pays, in its order: the client's designation (its documents, then its
    recoveries), else the default order over what it may pay."""
    if not (named or recover):
        return list(default_order((x for x in docs if x.payable), on))
    by_id = {d.id: d for d in docs}
    out: list[PayableDocument | WrittenOff] = []
    for i in named:
        d = by_id.get(i)
        if d is None:
            raise ClientPaymentInputError(f"{i}: a named document the plan does not hold")
        out.append(d)
    return [*out, *recover]


def plan_client_payment(  # noqa: PLR0913 - the payment and the client's documents
    docs: Sequence[PayableDocument],
    amount: int,
    named: Sequence[str],
    recover: Sequence[WrittenOff],
    *,
    procedure: bool,
    on: date,
) -> list[PaymentPart]:
    """The parts of a payment of `amount`: `docs` the client's open documents not in flight,
    `named` the ones it designates (in its order), `recover` the written-off advances it repays,
    `procedure` whether a proceeding of the client stands on `on` (the payment's date)."""
    if amount <= 0:
        raise ClientPaymentInputError("a payment is > 0")
    _check(docs, recover)
    parts: list[PaymentPart] = []
    rest = amount
    for d in _ordered(docs, named, recover, on):
        part = min(rest, d.available_minor if isinstance(d, WrittenOff) else d.open_minor)
        if part == 0:
            continue
        kind, vat, cause = _recovery(d) if isinstance(d, WrittenOff) else _part(d, part)
        parts.append(PaymentPart(len(parts) + 1, kind, d.id, part, vat, cause))
        rest -= part
    if rest > 0:
        cause_of_rest: CreditCause = "procedure" if procedure else "overpayment"
        parts.append(PaymentPart(len(parts) + 1, "client_credit", None, rest, 0, cause_of_rest))
    return parts


def considered_open(
    docs: Sequence[PayableDocument], named: Sequence[str], recover: Sequence[WrittenOff]
) -> int:
    """What the payment may settle, as the page shows it (the command's compare and set): the named
    documents and recoveries with a designation, else every document the client may pay."""
    if named or recover:
        return sum(d.open_minor for d in docs if d.id in set(named)) + sum(
            w.available_minor for w in recover
        )
    return sum(d.open_minor for d in docs if d.payable)


def entry_lines(parts: Sequence[PaymentPart]) -> dict[str, int]:
    """The servicer's fund lines the parts make (+ debit, - credit), besides the cash line (5122 on
    the own account, or 4689 on the dedicated one) of their sum: 4111 the invoices, 4112 the
    advances, 419 the credits owed back, 7714 the recoveries, and the VAT moved 44574 → 44571."""
    total = {"invoice": 0, "advance": 0, "client_credit": 0, "written_off": 0}
    vat = 0
    for p in parts:
        total[p.document_kind] += p.amount_minor
        vat += p.vat_moved_minor
    return {
        "commission_receivable": -total["invoice"],
        "client_advance_receivable": -total["advance"],
        "client_credit_owed": -total["client_credit"],
        "written_off_recovered": -total["written_off"],
        "vat_pending": vat,
        "vat_collected": -vat,
    }
