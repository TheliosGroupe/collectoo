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
debits are classified by ops (« Frais bancaires »). M2c-6b-1 (plan docs/design/m2c-6b-plan.md §2.3,
§2.4) books our payouts and sweeps from their debits (by their own id, or a batch line of their
PmtInf), and their returns; a batch line of one refund alone is that refund's debit, linked here
(`decide`) as an RFD line is.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from datetime import date
from typing import Any

from collectoo_worker.payments.statement import LABEL_REFERENCE_KIND

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
    # M2c-6b-1: a batch line (no end-to-end id) whose PmtInf holds one refund alone, named by its
    # transfer (private.debit_candidates)
    if line.direction == "debit" and line.kind in ("other_debit", "batch_unsplit") and refunds:
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


# --- M2c-1, M2c-6b-1: bank lines booked in the funds (design m2c-remittances §12, plan §2.3) --
#
# A bank's own charge on the dedicated account (camt.053 BkTxCd sub-family CHRG or FEES) is a
# `bank_fee`: the servicer's cost, booked automatically (founder #9). A credit carrying the TOP id
# of a top-up we ordered, for its amount, on the account it was ordered to, is that top-up
# (`servicer_top_up`).
#
# M2c-6b-1 books our transfers out from the statement, as the bank's facts:
#   * a debit carrying our RMT id (a payout) or SWP id (the sweep) is that transfer's debit, and
#     only that transfer's (own id first: a re-issue is never booked by its predecessor's id) —
#     when the transfer is in a file handed out (downloaded or sent), for its amount, account and
#     currency, and (a payout) its run approved or sent with that transfer;
#   * a batch line (no end-to-end id, the PmtInfId of one of our files: the bank ignored
#     BtchBookg false) is its PmtInf's members in their current file — all of them in_file, none
#     cancelled (but returned), of one kind, adding up exactly to the line; never a « best
#     subset » (a PmtInf of one refund alone is the M2b refund link, payments.debits.decide);
#   * a credit returning our payout or sweep (its original RMT/SWP id) is that transfer's return,
#     when it was booked and the credit is no more than it (a charge deducted: the SQL books the
#     difference as a fee on the same line) — review round 6 (R1), round 7 (S1): for a line of its
#     own only, never a line read from a camt.053 entry kept unsplit (its amount the entry's total),
#     whatever its count and amount (a detail of ours that is the whole entry is a line of its own:
#     payments.camt053).
# Never automatically (left to ops with why, P0): a debit of a cancelled transfer (or a batch line
# that can hold one), a second debit, a debit of a transfer never handed out, an id we do not know,
# a run not in flight, a batch line that does not add up or mixes kinds; review round 7 (S2) any
# line of an entry kept unsplit holding a detail of ours (`unsplit_ours` > 0), whatever its
# direction — reviewed, it waits for ops' booking (M2c-6b-2; COMPLIANCE OQ-84 (h)); (S3) a credit
# from our own account naming one of our lots of its account (`names_our_lot`): never a top-up.
# Our other transfers and the credits from a client wait for ops. Other debits are classified by ops
# (« Frais bancaires »).

TOP_UP_NOT_FOUND = "top_up_not_found"  # a credit from our own account no order matches
TOP_UP_DIFFERS = "top_up_differs"  # it carries our TOP id, for another amount or account
# M2c-7e-1 ([critic] M7-MONEY-4): it carries the TOP id of a top-up cancelled since (with its file,
# or alone), executed by the bank all the same: the servicer's own money, booked by ops with no
# transfer (« Comptabiliser comme approvisionnement »), swept back with the next file
TOP_UP_CANCELLED_CREDIT = "top_up_cancelled_credit"
CLIENT_CREDIT = "client_credit"  # a credit from a client's payout account
OWN_TRANSFER_OUT = "own_transfer_out"  # a debit to our own IBAN carrying none of our references
CANCELLED_TRANSFER_DEBITED = "cancelled_transfer_debited"  # P0: the bank paid a cancelled transfer
TRANSFER_DEBITED_TWICE = "transfer_debited_twice"  # P0: a second debit of a transfer
TRANSFER_NOT_HANDED_OUT = "transfer_not_handed_out"  # P0: no file of it was downloaded
TRANSFER_UNKNOWN = "transfer_unknown"  # our id's form, no transfer of ours
TRANSFER_DIFFERS = "transfer_differs"  # another amount, account or currency
RUN_NOT_IN_FLIGHT = "run_not_in_flight"  # the payout's run is not approved or sent with it
BATCH_PARTIAL = "batch_partial"  # a batch line its PmtInf's members do not add up to
BATCH_MIXED = "batch_mixed"  # payouts and refunds, or several refunds, in one line
RETURN_DIFFERS = "return_differs"  # more than the transfer, or of a transfer not booked
RETURN_BEFORE_DEBIT = "return_before_debit"  # its debit not booked, or booked on a later day
# M2c-6b-2a (plan docs/design/m2c-6b-2-plan.md §2.3; critic F1, L5; critic2 ML-3): a return the job
# never books — of a transfer that has an open unplanned booking (a booked or returned transfer
# executed again, a cancelled one executed late: the copy that comes back is the unplanned payout's,
# booked by ops as its return, never the planned payout's: that would pay the client twice), or of a
# transfer whose second or late debit is on a statement and not booked yet (that debit first)
UNPLANNED_PAYOUT_RETURN = "unplanned_payout_return"
RETURN_DEBIT_PENDING = "return_debit_pending"
# M2c-7e-2 (plan docs/design/m2c-7-plan.md §7.3, S24; [critic] M7-MONEY-6, [check 2] gap 1 (3)): a
# credit held because its CSV label cites one of our transfers of its account (kind
# `label_reference`): never booked by the job — a reference read from a label never books alone; it
# waits for ops (its exits are M2c-7e-3's)
LABEL_REFERENCE = "label_reference"

BOOKING_REVIEW_REASONS = frozenset(
    {
        TOP_UP_NOT_FOUND,
        TOP_UP_DIFFERS,
        TOP_UP_CANCELLED_CREDIT,
        CLIENT_CREDIT,
        OWN_TRANSFER_OUT,
        CANCELLED_TRANSFER_DEBITED,
        TRANSFER_DEBITED_TWICE,
        TRANSFER_NOT_HANDED_OUT,
        TRANSFER_UNKNOWN,
        TRANSFER_DIFFERS,
        RUN_NOT_IN_FLIGHT,
        BATCH_PARTIAL,
        BATCH_MIXED,
        RETURN_DIFFERS,
        RETURN_BEFORE_DEBIT,
        UNPLANNED_PAYOUT_RETURN,
        RETURN_DEBIT_PENDING,
        LABEL_REFERENCE,
    }
)
# the reviews that are a P0 (money may have left twice, or for a transfer we never handed out;
# M2c-6b-2a, critic L14: or a line carrying a reference of ours no transfer of ours has, debit or
# credit) — the alerts' P0 set (private.run_transfer_checks) and « À classer »'s (P0_DEBIT_REVIEWS)
P0_REVIEWS = frozenset(
    {CANCELLED_TRANSFER_DEBITED, TRANSFER_DEBITED_TWICE, TRANSFER_NOT_HANDED_OUT, TRANSFER_UNKNOWN}
)
CHARGE_SUBFAMILIES = frozenset({"CHRG", "FEES"})
OUR_ID = re.compile(r"^(RMT|SWP)[0-9A-F]{12}$")  # our payouts' and sweeps' end-to-end ids
OUR_PMT_INF = re.compile(r"^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$")  # <file number>-<n>
MAKE_UP_BOUND = 10_000  # partial sums kept (private.amounts_make_up's bound: past it, « can »)


@dataclass(frozen=True, slots=True)
class TransferFact:
    """A transfer of ours a funds line names (`private.bank_booking_candidates`, one row per (line,
    transfer)): the one its end-to-end id is (`own`), a member of the PmtInf a batch line names
    (`member`, held by that file), the one a credit returns (`return`), the top-up its TOP id is
    (`top_up`)."""

    id: str
    role: str  # own | member | return | top_up
    kind: str  # payout | sweep | refund | top_up
    status: str  # ordered | in_file | booked | returned | cancelled
    amount_minor: int
    currency: str = "EUR"
    debtor_bank_account_id: str | None = None
    creditor_bank_account_id: str | None = None
    file_id: str | None = None  # the file it is in now (kept once booked or cancelled from it)
    file_status: str | None = None
    file_download_count: int = 0
    pmt_inf_id: str | None = None  # its PmtInf in that file
    batch_file_id: str | None = None  # a member: the file the batch line's PmtInfId names
    batch_file_status: str | None = None
    batch_file_download_count: int = 0
    run_status: str | None = None
    run_transfer_id: str | None = None  # the run's transfer now (a re-issue moves it)
    replaces_transfer_id: str | None = None
    debit_booked: bool = False  # a debit booking of it exists
    return_booked: bool = False
    return_seen: bool = False  # (cancelled) the bank returned it: it was paid in its batch
    # (booked) its debit's date: its entry's, as the SQL re-check reads it
    debit_date: date | None = None
    # M2c-6b-2a (a return's facts, private.bank_booking_candidates): an unplanned booking of it
    # (unplanned_payout / unplanned_sweep) whose entry is not reversed; a debit line of it on a
    # statement not booked beyond its booked debit (private.transfer_late_lines)
    unplanned_open: bool = False
    debit_pending: bool = False


@dataclass(frozen=True, slots=True)
class FundsLine:
    """A bank line not booked nor linked: a bank charge, our transfer out (by its id, to our own
    IBAN, or a batch line of our PmtInf), a credit returning one of them, a credit from our own
    account (with the order its TOP id names, if any) or from a client
    (`private.bank_booking_candidates`)."""

    id: str
    kind: str  # other_debit | batch_unsplit | transfer_out | return | own_transfer_in | ...
    direction: str
    bank_account_id: str
    amount_minor: int
    booking_date: date
    bank_tx_code: str | None = None
    transfer_id: str | None = None  # the top-up its TOP id names
    transfer_status: str | None = None
    transfer_amount_minor: int | None = None
    transfer_creditor: str | None = None  # the dedicated account the top-up was ordered to
    # M2c-7e-1 ([critic] M7-MONEY-4): the top-up is in_file of an own-account file of its servicer
    # (private.top_up_in_own_file, read by the loader): filing puts it in_file, its credit books it
    transfer_filed_own: bool = False
    currency: str = "EUR"
    end_to_end_id: str | None = None
    original_end_to_end_id: str | None = None
    payment_info_id: str | None = None
    facts: tuple[TransferFact, ...] = ()
    # review round 6 (R1): read from a camt.053 entry kept unsplit, how many of its details are ours
    # (bank_transaction.unsplit_ours, the parser's count); None for a line of its own
    unsplit_ours: int | None = None
    # review round 7 (S3): a credit naming one of our lots of its account (a file of that account
    # handed out: private.names_our_lot), whatever its end-to-end id
    names_our_lot: bool = False

    @property
    def returned_id(self) -> str | None:
        return self.original_end_to_end_id or self.end_to_end_id

    @property
    def batch(self) -> bool:
        """A debit with no end-to-end id carrying one of our PmtInfIds."""
        return (
            self.direction == "debit"
            and self.end_to_end_id is None
            and self.payment_info_id is not None
            and OUR_PMT_INF.match(self.payment_info_id) is not None
        )


@dataclass(frozen=True, slots=True)
class Booking:
    """What the job does with a line: book it (one row per transfer: a batch line has one per
    member) as `fee`, `top_up`, `payout`, `sweep`, `payout_returned` or `sweep_returned`, or
    leave it to ops with why."""

    line_id: str
    kind: str | None = None
    transfer_id: str | None = None
    review_reason: str | None = None
    candidates: tuple[dict[str, Any], ...] = ()

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


def amounts_make_up(amounts: Iterable[int], target: int) -> bool:
    """Whether some of `amounts`, one or several together, add up to exactly `target` — the SQL's
    private.amounts_make_up: past MAKE_UP_BOUND partial sums it answers « can » (never guesses)."""
    if target <= 0:
        return target == 0
    sums = {0}
    for a in amounts:
        if a <= 0 or a > target:
            continue
        if target - a in sums:
            return True
        sums |= {s + a for s in sums if s + a < target}
        if len(sums) > MAKE_UP_BOUND:
            return True
    return False


# -- M2c-6b-2a: the only subset of a lot (plan §2.5; critic2 CSO2-2) -----------------------------

LOT_CAP = 500  # private.transfer_line_lot_cap(): a lot of more items is refused lot_too_large
SUBSET_SUMS_BOUND = 10_000  # partial sums kept (as amounts_make_up)
SUBSET_PATHS_BOUND = 200_000  # path entries stored for the sums one subset alone reaches
SUBSET_WORK_BOUND = 1_000_000  # Σ over the items visited of the number of partial sums


@dataclass(frozen=True, slots=True)
class SubsetTrace:
    """What unique_subset answered (`indexes`, 1-based, or None) and, when a bound stopped it,
    which (`cap`, `sums`, `paths`, `work`) and at which item (`tripped_at`; 0 for the cap)."""

    indexes: tuple[int, ...] | None
    tripped_at: int | None = None
    bound: str | None = None


def unique_subset_trace(  # noqa: PLR0911, PLR0912, PLR0913 - one exit per bound, as the SQL twin's
    amounts: Sequence[int],
    target: int,
    *,
    sums_bound: int = SUBSET_SUMS_BOUND,
    paths_bound: int = SUBSET_PATHS_BOUND,
    work_bound: int = SUBSET_WORK_BOUND,
    cap: int = LOT_CAP,
) -> SubsetTrace:
    """The twin of SQL `private.unique_subset_trace` (pgTAP 036 D; the integration test compares
    them): the only subset of `amounts` summing to `target`, by a dynamic programme over partial
    sums with a count capped at 2 and, for a count of 1, its path. It works on the smaller side
    t' = min(target, Σ - target) (a subset makes t iff its complement makes Σ - t) and answers the
    complement when t' is not the target. Amounts above t' are skipped; the others are visited in
    the order given (the callers pass a PmtInf's items by seq), so both twins trip a bound at the
    same item. None: no subset, several, an amount that is not positive, or past a bound — more
    amounts than the lot cap (at once), more than `sums_bound` partial sums, more than
    `paths_bound` path entries stored, or more than `work_bound` (Σ over the items visited of the
    number of partial sums before it: the bound on the run time)."""
    n = len(amounts)
    if n > cap:
        return SubsetTrace(None, 0, "cap")
    if target < 0 or any(a <= 0 for a in amounts):
        return SubsetTrace(None)
    total = sum(amounts)
    if target > total:
        return SubsetTrace(None)
    t = min(target, total - target)
    # sum -> (count capped at 2, its path when the count is 1)
    sums: dict[int, tuple[int, tuple[int, ...] | None]] = {0: (1, ())}
    work = 0
    for i, a in enumerate(amounts, start=1):
        if a > t:
            continue
        work += len(sums)
        if work > work_bound:
            return SubsetTrace(None, i, "work")
        new = dict(sums)
        for s, (count, path) in sums.items():
            u = s + a
            if u > t:
                continue
            had = sums.get(u, (0, None))
            reached = min(2, had[0] + count)
            if reached == 1:
                new[u] = (1, had[1] if had[0] == 1 else (*(path or ()), i))
            else:
                new[u] = (2, None)
        sums = new
        if len(sums) > sums_bound:
            return SubsetTrace(None, i, "sums")
        if sum(len(p or ()) for c, p in sums.values() if c == 1) > paths_bound:
            return SubsetTrace(None, i, "paths")
    count, path = sums.get(t, (0, None))
    if count != 1 or path is None:
        return SubsetTrace(None)
    if t == target:
        return SubsetTrace(path)
    chosen = set(path)
    return SubsetTrace(tuple(k for k in range(1, n + 1) if k not in chosen))


def unique_subset(amounts: Sequence[int], target: int) -> list[int] | None:
    """The 1-based indexes of the only subset of `amounts` summing to `target`, or None
    (`unique_subset_trace` with the default bounds; SQL `private.unique_subset`)."""
    out = unique_subset_trace(amounts, target)
    return None if out.indexes is None else list(out.indexes)


def _signal(f: TransferFact) -> dict[str, Any]:
    return {
        "transfer_id": f.id,
        "kind": f.kind,
        "status": f.status,
        "amount_minor": str(f.amount_minor),
    }


def _funds_review(
    line: FundsLine, reason: str, facts: Iterable[TransferFact] = ()
) -> list[Booking]:
    return [
        Booking(
            line.id,
            review_reason=reason,
            candidates=tuple(_signal(f) for f in sorted(facts, key=lambda f: f.id)),
        )
    ]


def _handed_out(status: str | None, downloads: int) -> bool:
    return downloads > 0 and status in ("downloaded", "sent")


def _transfer_refusal(line: FundsLine, f: TransferFact) -> str | None:
    """Why this one transfer of ours cannot be booked by this debit (plan §2.3 rows 1-2), or
    None."""
    if f.status == "cancelled":
        return CANCELLED_TRANSFER_DEBITED
    if f.status in ("booked", "returned") or f.debit_booked:
        return TRANSFER_DEBITED_TWICE
    if f.status != "in_file" or not _handed_out(f.file_status, f.file_download_count):
        return TRANSFER_NOT_HANDED_OUT
    if f.debtor_bank_account_id != line.bank_account_id or f.currency != line.currency:
        return TRANSFER_DIFFERS
    if f.kind == "payout" and (
        f.run_status not in ("approved", "sent") or f.run_transfer_id != f.id
    ):
        return RUN_NOT_IN_FLIGHT
    return None


def _own_debit(line: FundsLine) -> list[Booking]:
    """A debit carrying our RMT/SWP id: that id's transfer only (plan §2.4 rule 1)."""
    expected = "payout" if (line.end_to_end_id or "").startswith("RMT") else "sweep"
    own = [f for f in line.facts if f.role == "own"]
    if not own or own[0].kind != expected:
        return _funds_review(line, TRANSFER_UNKNOWN, own)
    f = own[0]
    why = _transfer_refusal(line, f)
    if why is None and f.amount_minor != line.amount_minor:
        why = TRANSFER_DIFFERS
    if why is None and line.unsplit_ours is not None:
        # review round 7 (S2): its id given by the one detail shown of an entry kept unsplit (the
        # verifier's d04: NbOfTxs 2) — the entry's total, never booked as that transfer's debit
        why = BATCH_PARTIAL
    if why is not None:
        return _funds_review(line, why, own)
    return [Booking(line.id, expected, transfer_id=f.id)]


def _may_hold(line: FundsLine, f: TransferFact, members: Sequence[TransferFact]) -> bool:
    """Whether this batch line can contain the (cancelled) transfer: its amount alone, or with
    others of the PmtInf not debited on their own (private.batch_debit_may_hold's rule)."""
    if line.amount_minor == f.amount_minor:
        return True
    others = [
        o.amount_minor for o in members if o.id != f.id and o.status not in ("booked", "returned")
    ]
    return amounts_make_up(others, line.amount_minor - f.amount_minor)


def _batch(line: FundsLine) -> list[Booking]:  # noqa: PLR0911 - one outcome per case
    """A batch line of our PmtInf (plan §2.3 row 3, §2.4 rule 2): exactly its in_file members."""
    members = sorted((f for f in line.facts if f.role == "member"), key=lambda f: f.id)
    if not members:
        return _funds_review(line, TRANSFER_UNKNOWN)
    head = members[0]
    if not _handed_out(head.batch_file_status, head.batch_file_download_count):
        return _funds_review(line, TRANSFER_NOT_HANDED_OUT, members)
    cancelled = [m for m in members if m.status == "cancelled" and not m.return_seen]
    if cancelled:
        held = any(_may_hold(line, m, members) for m in cancelled)
        return _funds_review(line, CANCELLED_TRANSFER_DEBITED if held else BATCH_PARTIAL, members)
    live = [m for m in members if m.status == "in_file"]
    if not live:
        return _funds_review(line, TRANSFER_DEBITED_TWICE, members)
    kinds = {m.kind for m in live}
    if len(kinds) > 1 or "refund" in kinds:
        return _funds_review(line, BATCH_MIXED, members)
    if sum(m.amount_minor for m in live) != line.amount_minor:
        return _funds_review(line, BATCH_PARTIAL, members)
    for m in live:
        why = _transfer_refusal(line, m)
        if why is not None:
            return _funds_review(line, why, members)
    if line.unsplit_ours:
        # review round 7 (S2): its details given but not adding up (an entry kept unsplit
        # holding ours): never booked, whatever the members' sum; a batch line with no details
        # keeps the rule
        return _funds_review(line, BATCH_PARTIAL, members)
    return [Booking(line.id, m.kind, transfer_id=m.id) for m in live]


def _transfer_return(line: FundsLine) -> list[Booking]:  # noqa: PLR0911 - one review per rule
    """A credit returning our payout or sweep (its original id): the transfer's return."""
    expected = "payout" if (line.returned_id or "").startswith("RMT") else "sweep"
    named = [f for f in line.facts if f.role == "return"]
    if not named or named[0].kind != expected:
        return _funds_review(line, TRANSFER_UNKNOWN, named)
    f = named[0]
    if f.status in ("ordered", "in_file"):
        return _funds_review(line, RETURN_BEFORE_DEBIT, named)
    # M2c-6b-2a (critic F1, L5): a copy coming back closes the unplanned payout first (ops); then
    # (critic2 ML-3) a debit pending on a statement is booked first
    if f.unplanned_open:
        return _funds_review(line, UNPLANNED_PAYOUT_RETURN, named)
    if f.debit_pending:
        return _funds_review(line, RETURN_DEBIT_PENDING, named)
    if f.status != "booked" or not f.debit_booked or f.return_booked:
        return _funds_review(line, RETURN_DIFFERS, named)
    if f.debtor_bank_account_id != line.bank_account_id or f.currency != line.currency:
        return _funds_review(line, TRANSFER_DIFFERS, named)
    if line.amount_minor > f.amount_minor:
        return _funds_review(line, RETURN_DIFFERS, named)
    if line.unsplit_ours is not None:
        # review round 6 (R1): an entry the bank kept unsplit carries its total, not this
        # transfer's return: less than the transfer is never its return with the rest as the
        # bank's charge (the round-5 verifier's netted entry: our payout's return beside another
        # payout's debit, or a chargeback), nor any amount with several details of ours; round 7
        # (S1): nor its exact amount with one of ours (a debtor's credit beside it, a detail short)
        return _funds_review(line, RETURN_DIFFERS, named)
    if f.debit_date is not None and line.booking_date < f.debit_date:
        # dated before the debit it returns (the SQL re-check's last rule; review T4, K5): never
        # booked (the ledger refuses a reversal dated before its entry), ops see why
        return _funds_review(line, RETURN_BEFORE_DEBIT, named)
    return [Booking(line.id, f"{expected}_returned", transfer_id=f.id)]


def decide_line(line: FundsLine) -> list[Booking]:  # noqa: PLR0911, PLR0912 - one rule per kind
    """The job's decision for one line: its bookings (one per transfer), one review, or nothing (an
    other debit with no charge code: ops classify it, no review). M2c-7e-2: a credit held because
    its label cites one of our transfers is reviewed `label_reference` before any other rule,
    whatever else it carries, and never booked."""
    if line.kind == LABEL_REFERENCE_KIND:
        return _funds_review(line, LABEL_REFERENCE)
    if line.direction == "debit" and line.end_to_end_id and OUR_ID.match(line.end_to_end_id):
        return _own_debit(line)
    if line.batch:
        return _batch(line)
    if (
        line.direction == "credit"
        and line.kind == "return"
        and line.returned_id
        and OUR_ID.match(line.returned_id)
    ):
        return _transfer_return(line)
    if line.unsplit_ours:
        # review round 7 (S2): an entry kept unsplit holding a detail of ours that no rule above
        # reads (a debit netting or holding ours with no id: d01-d03; a credit whose detail of ours
        # is a debit: x01): never booked, never waiting without a reason
        return _funds_review(
            line, RETURN_DIFFERS if line.direction == "credit" else BATCH_PARTIAL, line.facts
        )
    if line.direction == "debit" and line.kind == "other_debit":
        return [Booking(line.id, "fee")] if charge_code(line.bank_tx_code) else []
    if line.direction == "debit" and line.kind == "transfer_out":
        return _funds_review(line, OWN_TRANSFER_OUT)
    if line.direction == "credit" and line.kind == "client_transfer_in":
        return _funds_review(line, CLIENT_CREDIT)
    if line.direction == "credit" and line.kind == "own_transfer_in":
        if line.names_our_lot:
            # review round 7 (S3): naming one of our lots of this account, our outgoing transfer
            # coming back (a top-up is never in a file of this dedicated account): never the
            # top-up, whatever its end-to-end id (the SQL re-check refuses it: own_transfer_line)
            return _funds_review(line, TOP_UP_DIFFERS if line.transfer_id else TOP_UP_NOT_FOUND)
        if line.transfer_id is None:
            return _funds_review(line, TOP_UP_NOT_FOUND)
        # M2c-7e-1 ([critic] M7-MONEY-4), the SQL re-check's order (private.bank_booking_recheck):
        # the account it was ordered to, then its status — a cancelled one's credit waits for ops
        # (top_up_cancelled_credit); a top-up books from ordered, or in_file of an own-account file
        if line.transfer_creditor != line.bank_account_id:
            return _funds_review(line, TOP_UP_DIFFERS)
        if line.transfer_status == "cancelled":
            return _funds_review(line, TOP_UP_CANCELLED_CREDIT)
        bookable = line.transfer_status == "ordered" or (
            line.transfer_status == "in_file" and line.transfer_filed_own
        )
        if not bookable or line.transfer_amount_minor != line.amount_minor:
            return _funds_review(line, TOP_UP_DIFFERS)
        return [Booking(line.id, "top_up", transfer_id=line.transfer_id)]
    return []


def decide_booking(line: FundsLine) -> Booking | None:
    """One line's single outcome (a fee, a top-up, a booking of one transfer, or a review); None for
    a line left untouched. A batch line's several bookings: decide_line."""
    out = decide_line(line)
    return out[0] if out else None


def decision_order(line: FundsLine) -> tuple[date, int, str]:
    """The order lines are decided in (plan §2.4 rule 4): by booking date, a day's debits before its
    credits (a same-day return after its debit), then by id."""
    return (line.booking_date, 0 if line.direction == "debit" else 1, line.id)


def decide_bookings(lines: Iterable[FundsLine]) -> list[Booking]:
    """Every line, in decision_order. A transfer is taken once per chunk: a second debit of it is
    `transfer_debited_twice`, a second credit carrying the same TOP id waits for ops
    (`top_up_differs`); a return of a transfer whose debit this chunk books is left for the next
    pass (no booking, no review: its facts are read again once the debit is booked; see
    deferred_returns)."""
    out: list[Booking] = []
    debited: set[str] = set()
    returned: set[str] = set()
    for line in sorted(lines, key=decision_order):
        bookings = decide_line(line)
        if not bookings:
            continue
        ids = {b.transfer_id for b in bookings if b.booked and b.transfer_id is not None}
        if bookings[0].kind in ("payout_returned", "sweep_returned"):
            if ids & debited:
                continue  # its debit is booked by this chunk: decided again by the next pass
            if ids & returned:
                bookings = _funds_review(line, RETURN_DIFFERS, line.facts)
            returned |= ids
        elif ids & debited:
            reason = TOP_UP_DIFFERS if bookings[0].kind == "top_up" else TRANSFER_DEBITED_TWICE
            bookings = _funds_review(line, reason, line.facts)
        else:
            debited |= ids
        out.extend(bookings)
    return out


def deferred_returns(lines: Iterable[FundsLine], bookings: Sequence[Booking]) -> list[str]:
    """The return lines decide_bookings left for the next pass (their transfer's debit booked by
    this chunk)."""
    decided = {b.line_id for b in bookings}
    return [
        x.id
        for x in lines
        if x.id not in decided
        and x.direction == "credit"
        and x.kind == "return"
        and x.returned_id is not None
        and OUR_ID.match(x.returned_id) is not None
    ]
