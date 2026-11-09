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
  decide), more than what is left. The posting then reverses the payment's allocations at the
  return date and books the cash_out (SQL, `private.post_debit_links`).
- **refund_out** (our refund, end-to-end id RFD...): linked to its request when the request is still
  pending, on the same bank account, for the same amount, and the payment still has that much
  unallocated. A refund is never booked above what is left of the payment (LG007 backstop).
- **return credit** (a credit undoing a debit): linked to our executed refund it names, same
  amount, on or after the refund (the refund came back unpaid: its cash_out is reversed).

Bank fees and other debits are never classified here: they stay explained gaps (founder #20).
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from datetime import date
from typing import Any

# Review reasons (public.bank_debit_review.reason).
NO_CANDIDATE = "no_candidate"
AMBIGUOUS = "ambiguous"
AMOUNT_DIFFERS = "amount_differs"
PARTIAL_RETURN = "partial_return"
REFUND_NOT_PENDING = "refund_not_pending"
ALREADY_RETURNED = "already_returned"

REVIEW_REASONS = frozenset(
    {NO_CANDIDATE, AMBIGUOUS, AMOUNT_DIFFERS, PARTIAL_RETURN, REFUND_NOT_PENDING, ALREADY_RETURNED}
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
    if (
        r.amount_minor != line.amount_minor
        or line.amount_minor > r.unallocated_minor
        or line.booking_date < r.date
    ):
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
