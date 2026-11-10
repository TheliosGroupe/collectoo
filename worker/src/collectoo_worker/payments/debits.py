"""Debit lines (M2b-6): what money leaving the client-funds account is. Pure, no I/O.

Design: docs/design/m2b-payments.md §2 #3 and #13, §6 (bank_debit_link, refund_request), §8.1, §8.3
step 6-7; founder decisions #8, #13, #20 (ADR-0013, M2b-6 addendum).

A statement's debits (and its credits that undo a debit) are recorded at import, not booked. The
`payments.process_debits` job loads every line not linked yet with what its references name, and
these rules decide, deterministically and explainably (no model, no LLM):

- **return** (a debit undoing a debtor's credit: R-transaction, chargeback, bank reversal): linked
  automatically to the one payment of the same bank account whose end-to-end id or bank
  transaction id the line carries, booked on or before it, not returned, when the line takes back
  exactly what is left of it (amount - what already went back out). Anything else goes to ops: no
  candidate, two candidates (never guessed), less than what is left (a partial return: ops
  decide), more than what is left, or dated before the payment's free-from date (its latest
  reversal dated after the entry it reverses: until then its money was allocated or out, so a
  cash_out at the line's date would overdraw it, I4). The posting then reverses the payment's
  allocations at the return date and books the cash_out (SQL, `private.post_debit_links`).
- **refund_out** (our refund, end-to-end id RFD...): linked to its request when the request is still
  pending, on the same bank account, for the same amount, not dated before the payment's
  free-from date, and the payment still has that much unallocated. A refund is never booked
  above what is left of the payment (LG007 backstop).
- **return credit** (a credit undoing a debit): linked to our executed refund it names, same
  amount, on or after the refund (the refund came back unpaid: its cash_out is reversed) — unless
  the bank has taken the payment back since: where that money goes is not decided (ops; open
  question), so it is never booked automatically.

The SQL re-checks every rule under its locks (the same codes): a line these rules link but the
posting refuses is skipped (the facts changed meanwhile) or left to ops (`posting_failed`), never
taking the other lines of the run down.

M2c-1 adds the lines booked in the funds (`decide_bookings`): the bank's charges as fees, the
top-ups we ordered when their credit shows; our other transfers and credits wait for ops. Other
debits are classified by ops (« Frais bancaires »).
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from datetime import date
from typing import Any

Day = date  # (RefundCandidate has a field named `date`)

# Review reasons (public.bank_debit_review.reason).
NO_CANDIDATE = "no_candidate"
AMBIGUOUS = "ambiguous"
AMOUNT_DIFFERS = "amount_differs"
PARTIAL_RETURN = "partial_return"
REFUND_NOT_PENDING = "refund_not_pending"
ALREADY_RETURNED = "already_returned"
PAYMENT_RETURNED = "payment_returned"  # a refund came back to a payment the bank took back since
BEFORE_PREVIOUS_RETURN = "before_previous_return"  # dated before the payment's free-from date
POSTING_FAILED = "posting_failed"  # the SQL posting refused it (written by the SQL, not here)

REVIEW_REASONS = frozenset(
    {
        NO_CANDIDATE,
        AMBIGUOUS,
        AMOUNT_DIFFERS,
        PARTIAL_RETURN,
        REFUND_NOT_PENDING,
        ALREADY_RETURNED,
        PAYMENT_RETURNED,
        BEFORE_PREVIOUS_RETURN,
        POSTING_FAILED,
    }
)


@dataclass(frozen=True, slots=True)
class DebitLine:
    """A bank line not linked yet: kind `return` or `refund_out` (as read, or as released)."""

    id: str
    kind: str
    direction: str  # debit | credit
    bank_account_id: str
    amount_minor: int
    booking_date: date


@dataclass(frozen=True, slots=True)
class PaymentCandidate:
    """A payment a return names, and its position (from the ledger)."""

    payment_id: str
    bank_account_id: str
    amount_minor: int
    left_minor: int  # amount - what already went back out (returns, refunds)
    pending_minor: int  # refunds requested, not executed
    status: str
    booking_date: date
    via: str  # end_to_end_id | tx_id
    # its latest reversal dated after the entry it reverses (a return, a refund that bounced, an
    # allocation reversed later): nothing goes out of it before that date (I4)
    free_from: date | None = None


@dataclass(frozen=True, slots=True)
class RefundCandidate:
    """A refund request a line names by our RFD id, and its payment's unallocated money."""

    refund_request_id: str
    payment_id: str
    bank_account_id: str
    amount_minor: int
    status: str  # requested | executed | cancelled | bounced
    unallocated_minor: int  # what is left of the payment, unallocated (U)
    date: date  # the payment's booking date (requested) or the refund's execution date (executed)
    payment_status: str = "unmatched"  # the payment's own status (returned: the bank took it back)
    free_from: Day | None = None  # the payment's free-from date (see PaymentCandidate)


@dataclass(frozen=True, slots=True)
class Decision:
    line_id: str
    kind: str  # return | refund | refund_returned | review
    payment_id: str | None = None
    refund_request_id: str | None = None
    review_reason: str | None = None
    candidates: tuple[dict[str, Any], ...] = field(default_factory=tuple)

    @property
    def linked(self) -> bool:
        return self.kind != "review"


def _review(line: DebitLine, reason: str, candidates: Iterable[dict[str, Any]] = ()) -> Decision:
    return Decision(line.id, "review", review_reason=reason, candidates=tuple(candidates))


def _payment_signal(p: PaymentCandidate) -> dict[str, Any]:
    return {"payment_id": p.payment_id, "via": p.via}


def _refund_signal(r: RefundCandidate) -> dict[str, Any]:
    return {"refund_request_id": r.refund_request_id, "payment_id": r.payment_id}


def decide(
    line: DebitLine,
    payments: Sequence[PaymentCandidate] = (),
    refunds: Sequence[RefundCandidate] = (),
) -> Decision:
    """What a line is, or why ops must decide. The order of the candidates does not matter."""
    if line.direction == "debit" and line.kind == "return":
        return _return(line, payments)
    if line.direction == "debit" and line.kind == "refund_out":
        return _refund(line, refunds)
    if line.direction == "credit" and line.kind == "return":
        return _refund_returned(line, refunds)
    return _review(line, NO_CANDIDATE)


def _return(line: DebitLine, payments: Sequence[PaymentCandidate]) -> Decision:
    # The same payment named twice (by its end-to-end id and its transaction id) is one candidate.
    by_id: dict[str, PaymentCandidate] = {}
    for p in sorted(payments, key=lambda p: (p.payment_id, p.via)):
        by_id.setdefault(p.payment_id, p)
    named = sorted(by_id.values(), key=lambda p: p.payment_id)
    signals = [_payment_signal(p) for p in named]
    usable = [
        p
        for p in named
        if p.bank_account_id == line.bank_account_id and p.booking_date <= line.booking_date
    ]
    live = [p for p in usable if p.status != "returned" and p.left_minor > 0]
    if not live:
        return _review(line, ALREADY_RETURNED if usable else NO_CANDIDATE, signals)
    if len(live) > 1:
        return _review(line, AMBIGUOUS, signals)  # never guessed: a wrong return reopens a debt
    p = live[0]
    if p.free_from is not None and line.booking_date < p.free_from:
        return _review(line, BEFORE_PREVIOUS_RETURN, signals)  # its money was allocated then (I4)
    if line.amount_minor == p.left_minor:
        return Decision(line.id, "return", payment_id=p.payment_id, candidates=tuple(signals))
    if line.amount_minor < p.left_minor:
        return _review(line, PARTIAL_RETURN, signals)  # ops decide what is left
    return _review(line, AMOUNT_DIFFERS, signals)


def _refund(line: DebitLine, refunds: Sequence[RefundCandidate]) -> Decision:
    named = sorted(refunds, key=lambda r: r.refund_request_id)
    signals = [_refund_signal(r) for r in named]
    usable = [r for r in named if r.bank_account_id == line.bank_account_id]
    if not usable:
        return _review(line, NO_CANDIDATE, signals)
    pending = [r for r in usable if r.status == "requested"]
    if len(pending) != 1:
        return _review(line, REFUND_NOT_PENDING if not pending else AMBIGUOUS, signals)
    r = pending[0]
    if r.amount_minor != line.amount_minor or line.booking_date < r.date:
        return _review(line, AMOUNT_DIFFERS, signals)
    if r.free_from is not None and line.booking_date < r.free_from:
        return _review(line, BEFORE_PREVIOUS_RETURN, signals)
    if line.amount_minor > r.unallocated_minor:
        return _review(line, AMOUNT_DIFFERS, signals)
    return Decision(
        line.id,
        "refund",
        payment_id=r.payment_id,
        refund_request_id=r.refund_request_id,
        candidates=tuple(signals),
    )


def _refund_returned(line: DebitLine, refunds: Sequence[RefundCandidate]) -> Decision:
    named = sorted(refunds, key=lambda r: r.refund_request_id)
    signals = [_refund_signal(r) for r in named]
    executed = [
        r for r in named if r.bank_account_id == line.bank_account_id and r.status == "executed"
    ]
    if not executed:
        return _review(line, NO_CANDIDATE if not named else REFUND_NOT_PENDING, signals)
    if len(executed) > 1:
        return _review(line, AMBIGUOUS, signals)
    r = executed[0]
    if r.payment_status == "returned":
        return _review(line, PAYMENT_RETURNED, signals)  # not booked: where it goes is not decided
    if r.amount_minor != line.amount_minor or line.booking_date < r.date:
        return _review(line, AMOUNT_DIFFERS, signals)
    return Decision(
        line.id,
        "refund_returned",
        payment_id=r.payment_id,
        refund_request_id=r.refund_request_id,
        candidates=tuple(signals),
    )


def decide_all(
    lines: Sequence[DebitLine],
    payments: dict[str, list[PaymentCandidate]],
    refunds: dict[str, list[RefundCandidate]],
) -> list[Decision]:
    """Every line, in the order given. Two lines naming the same payment in one run: only the
    first may be linked automatically (the second waits: ops, or the next run)."""
    out: list[Decision] = []
    taken: set[str] = set()
    for line in lines:
        d = decide(line, payments.get(line.id, ()), refunds.get(line.id, ()))
        if d.linked and d.payment_id in taken:
            d = _review(line, AMBIGUOUS, d.candidates)
        if d.linked and d.payment_id is not None:
            taken.add(d.payment_id)
        out.append(d)
    return out


# --- M2c-1: bank lines booked in the funds (design m2c-remittances §12) ------------------------
#
# A bank's own charge on the dedicated account (camt.053 BkTxCd sub-family CHRG or FEES) is a
# `bank_fee`: the servicer's cost, booked automatically (founder #9). A credit carrying the TOP id
# of a top-up we ordered, for its amount, on the account it was ordered to, is that top-up
# (`servicer_top_up`). Everything else stays to ops: a credit from our own account matching no
# order (or another amount), a credit from a client, our own transfer out (payouts and sweeps are
# booked from M2c-6). Other debits are classified by ops (« Frais bancaires »).

TOP_UP_NOT_FOUND = "top_up_not_found"  # a credit from our own account no order matches
TOP_UP_DIFFERS = "top_up_differs"  # it carries our TOP id, for another amount or account
CLIENT_CREDIT = "client_credit"  # a credit from a client's payout account
OWN_TRANSFER_OUT = "own_transfer_out"  # one of our transfers out (booked from M2c-6)

BOOKING_REVIEW_REASONS = frozenset(
    {TOP_UP_NOT_FOUND, TOP_UP_DIFFERS, CLIENT_CREDIT, OWN_TRANSFER_OUT}
)
CHARGE_SUBFAMILIES = frozenset({"CHRG", "FEES"})


@dataclass(frozen=True, slots=True)
class FundsLine:
    """A bank line not booked nor linked: a bank charge, our transfer out, a credit from our own
    account (with the order its TOP id names, if any) or from a client
    (`private.bank_booking_candidates`)."""

    id: str
    kind: str  # other_debit | transfer_out | own_transfer_in | client_transfer_in
    direction: str
    bank_account_id: str
    amount_minor: int
    booking_date: date
    bank_tx_code: str | None = None
    transfer_id: str | None = None  # the top-up its TOP id names
    transfer_status: str | None = None
    transfer_amount_minor: int | None = None
    transfer_creditor: str | None = None  # the dedicated account the top-up was ordered to


@dataclass(frozen=True, slots=True)
class Booking:
    """What the job does with a line: book it (`fee` or `top_up`), or leave it to ops."""

    line_id: str
    kind: str | None = None  # fee | top_up
    transfer_id: str | None = None
    review_reason: str | None = None

    @property
    def booked(self) -> bool:
        return self.kind is not None


def charge_code(code: str | None) -> bool:
    """A bank's own charge: ISO bank transaction code DOMAIN/FAMILY/SUBFAMILY, sub-family CHRG or
    FEES (proprietary codes are not read)."""
    if not code or code.startswith("PRTRY:"):
        return False
    parts = [*code.split("/"), "", ""]
    return parts[2] in CHARGE_SUBFAMILIES


def decide_booking(line: FundsLine) -> Booking | None:  # noqa: PLR0911 - one outcome per case
    """The job's decision for one line; None for a line it leaves untouched (an other debit with
    no charge code: ops classify it, no review)."""
    if line.direction == "debit" and line.kind == "other_debit":
        return Booking(line.id, "fee") if charge_code(line.bank_tx_code) else None
    if line.direction == "debit" and line.kind == "transfer_out":
        return Booking(line.id, review_reason=OWN_TRANSFER_OUT)
    if line.direction == "credit" and line.kind == "client_transfer_in":
        return Booking(line.id, review_reason=CLIENT_CREDIT)
    if line.direction == "credit" and line.kind == "own_transfer_in":
        if line.transfer_id is None:
            return Booking(line.id, review_reason=TOP_UP_NOT_FOUND)
        if (
            line.transfer_status != "ordered"
            or line.transfer_amount_minor != line.amount_minor
            or line.transfer_creditor != line.bank_account_id
        ):
            return Booking(line.id, review_reason=TOP_UP_DIFFERS)
        return Booking(line.id, "top_up", transfer_id=line.transfer_id)
    return None


def decide_bookings(lines: Iterable[FundsLine]) -> list[Booking]:
    """Every line in the order given (each order booked once: a second credit carrying the same TOP
    id waits for ops)."""
    out: list[Booking] = []
    taken: set[str] = set()
    for line in lines:
        b = decide_booking(line)
        if b is None:
            continue
        if b.transfer_id is not None and b.transfer_id in taken:
            b = Booking(line.id, review_reason=TOP_UP_DIFFERS)
        if b.transfer_id is not None:
            taken.add(b.transfer_id)
        out.append(b)
    return out
