"""Debit rules (M2b-6, payments.debits): what a debit is, or why ops decide. Examples, then
Hypothesis properties: a return is linked only to the one payment it names and only for exactly
what is left of it (never more than was allocated and left unallocated); a refund only for its
pending request's amount, never above what is left of the payment; the order of the candidates
never matters; a payment is linked at most once per run."""

import random
from dataclasses import replace
from datetime import date, timedelta

from hypothesis import given, settings
from hypothesis import strategies as st

from collectoo_worker.payments.debits import (
    ALREADY_RETURNED,
    AMBIGUOUS,
    AMOUNT_DIFFERS,
    NO_CANDIDATE,
    PARTIAL_RETURN,
    REFUND_NOT_PENDING,
    DebitLine,
    PaymentCandidate,
    RefundCandidate,
    decide,
    decide_all,
)

BANK = "bank-1"
DAY = date(2026, 11, 3)


def ret(
    amount: int, *, line_id: str = "L1", day: date = DAY, direction: str = "debit"
) -> DebitLine:
    return DebitLine(line_id, "return", direction, BANK, amount, day)


def pay(  # noqa: PLR0913 - a candidate's facts
    pid: str,
    left: int,
    *,
    amount: int | None = None,
    status: str = "allocated",
    bank: str = BANK,
    day: date = date(2026, 10, 5),
    via: str = "end_to_end_id",
    pending: int = 0,
) -> PaymentCandidate:
    return PaymentCandidate(pid, bank, amount or left, left, pending, status, day, via)


def refund(  # noqa: PLR0913 - a candidate's facts
    rid: str,
    amount: int,
    *,
    status: str = "requested",
    unallocated: int | None = None,
    bank: str = BANK,
    day: date = date(2026, 10, 5),
    payment: str = "P1",
) -> RefundCandidate:
    left = amount if unallocated is None else unallocated
    return RefundCandidate(rid, payment, bank, amount, status, left, day)


# -- returns --------------------------------------------------------------------------------------


def test_a_full_return_of_the_one_payment_named_is_linked() -> None:
    d = decide(ret(20000), [pay("P1", 20000)])
    assert (d.kind, d.payment_id) == ("return", "P1")
    assert d.candidates == ({"payment_id": "P1", "via": "end_to_end_id"},)


def test_named_twice_by_end_to_end_id_and_transaction_id_is_one_candidate() -> None:
    d = decide(ret(500), [pay("P1", 500, via="tx_id"), pay("P1", 500)])
    assert (d.kind, d.payment_id) == ("return", "P1")


def test_two_payments_named_go_to_ops() -> None:
    d = decide(ret(500), [pay("P1", 500), pay("P2", 500)])
    assert (d.kind, d.review_reason) == ("review", AMBIGUOUS)


def test_less_than_what_is_left_is_a_partial_return_for_ops() -> None:
    d = decide(ret(400), [pay("P1", 500)])
    assert (d.kind, d.review_reason) == ("review", PARTIAL_RETURN)


def test_more_than_what_is_left_goes_to_ops() -> None:
    # 500 received, 100 already refunded: a return of 500 cannot be booked (I4)
    d = decide(ret(500), [pay("P1", 400, amount=500)])
    assert (d.kind, d.review_reason) == ("review", AMOUNT_DIFFERS)


def test_no_payment_named() -> None:
    assert decide(ret(500), []).review_reason == NO_CANDIDATE


def test_a_payment_already_returned_or_on_another_account_or_later() -> None:
    assert decide(ret(500), [pay("P1", 0, status="returned")]).review_reason == ALREADY_RETURNED
    assert decide(ret(500), [pay("P1", 500, bank="bank-2")]).review_reason == NO_CANDIDATE
    later = DAY + timedelta(days=1)
    assert decide(ret(500), [pay("P1", 500, day=later)]).review_reason == NO_CANDIDATE


def test_a_refund_pending_does_not_stop_a_full_return() -> None:
    # the posting cancels the pending refund: nothing is left to refund
    d = decide(ret(500), [pay("P1", 500, status="refund_pending", pending=200)])
    assert (d.kind, d.payment_id) == ("return", "P1")


# -- refunds --------------------------------------------------------------------------------------


def out(amount: int, day: date = DAY) -> DebitLine:
    return DebitLine("L9", "refund_out", "debit", BANK, amount, day)


def test_our_refund_is_linked_to_its_pending_request() -> None:
    d = decide(out(8000), refunds=[refund("R1", 8000)])
    assert (d.kind, d.refund_request_id, d.payment_id) == ("refund", "R1", "P1")


def test_a_refund_not_pending_another_amount_or_account_goes_to_ops() -> None:
    assert decide(out(8000), refunds=[refund("R1", 8000, status="cancelled")]).review_reason == (
        REFUND_NOT_PENDING
    )
    assert decide(out(8000), refunds=[refund("R1", 7999)]).review_reason == AMOUNT_DIFFERS
    assert decide(out(8000), refunds=[refund("R1", 8000, bank="bank-2")]).review_reason == (
        NO_CANDIDATE
    )
    # the payment no longer has that much unallocated (a return came first)
    assert decide(out(8000), refunds=[refund("R1", 8000, unallocated=0)]).review_reason == (
        AMOUNT_DIFFERS
    )
    assert decide(out(8000), refunds=[]).review_reason == NO_CANDIDATE


def test_a_refund_that_came_back_is_linked_to_the_executed_refund() -> None:
    back = ret(8000, line_id="L7", direction="credit")
    d = decide(back, refunds=[refund("R1", 8000, status="executed", day=date(2026, 10, 21))])
    assert (d.kind, d.refund_request_id) == ("refund_returned", "R1")
    assert decide(back, refunds=[refund("R1", 8000)]).review_reason == REFUND_NOT_PENDING
    assert decide(back, refunds=[]).review_reason == NO_CANDIDATE


def test_one_payment_is_linked_once_per_run() -> None:
    lines = [ret(500, line_id="L1"), ret(500, line_id="L2")]
    both = {"L1": [pay("P1", 500)], "L2": [pay("P1", 500)]}
    d1, d2 = decide_all(lines, both, {})
    assert (d1.kind, d2.kind, d2.review_reason) == ("return", "review", AMBIGUOUS)


# -- properties -----------------------------------------------------------------------------------

amounts = st.integers(min_value=1, max_value=10**9)
days = st.integers(min_value=-30, max_value=30).map(lambda n: DAY + timedelta(days=n))
payments = st.lists(
    st.builds(
        PaymentCandidate,
        payment_id=st.sampled_from(["P1", "P2", "P3"]),
        bank_account_id=st.sampled_from([BANK, "bank-2"]),
        amount_minor=amounts,
        left_minor=st.integers(min_value=0, max_value=10**9),
        pending_minor=st.integers(min_value=0, max_value=10**6),
        status=st.sampled_from(["allocated", "partially_allocated", "matched", "returned"]),
        booking_date=days,
        via=st.sampled_from(["end_to_end_id", "tx_id"]),
    ),
    max_size=5,
)
refunds = st.lists(
    st.builds(
        RefundCandidate,
        refund_request_id=st.sampled_from(["R1", "R2"]),
        payment_id=st.sampled_from(["P1", "P2"]),
        bank_account_id=st.sampled_from([BANK, "bank-2"]),
        amount_minor=amounts,
        status=st.sampled_from(["requested", "executed", "cancelled", "bounced"]),
        unallocated_minor=st.integers(min_value=0, max_value=10**9),
        date=days,
    ),
    max_size=3,
    unique_by=lambda r: r.refund_request_id,
)
lines = st.builds(
    DebitLine,
    id=st.just("L1"),
    kind=st.sampled_from(["return", "refund_out"]),
    direction=st.sampled_from(["debit", "credit"]),
    bank_account_id=st.just(BANK),
    amount_minor=amounts,
    booking_date=days,
)


def _consistent(cands: list[PaymentCandidate]) -> list[PaymentCandidate]:
    """One set of facts per payment, whatever way it was named (as the loader gives it)."""
    first: dict[str, PaymentCandidate] = {}
    for c in cands:
        first.setdefault(c.payment_id, c)
    return [replace(first[c.payment_id], via=c.via) for c in cands]


@settings(max_examples=400)
@given(line=lines, cands=payments, refs=refunds, seed=st.integers())
def test_links_never_take_more_than_is_left_and_ignore_order(
    line: DebitLine, cands: list[PaymentCandidate], refs: list[RefundCandidate], seed: int
) -> None:
    cands = _consistent(cands)
    d = decide(line, cands, refs)
    shuffled_p, shuffled_r = list(cands), list(refs)
    random.Random(seed).shuffle(shuffled_p)
    random.Random(seed).shuffle(shuffled_r)
    assert decide(line, shuffled_p, shuffled_r) == d
    if d.kind == "return":
        live = {
            c.payment_id
            for c in cands
            if c.bank_account_id == line.bank_account_id
            and c.booking_date <= line.booking_date
            and c.status != "returned"
            and c.left_minor > 0
        }
        p = next(c for c in cands if c.payment_id == d.payment_id)
        assert live == {d.payment_id}  # the one payment named: never a guess between two
        assert line.direction == "debit"
        assert line.amount_minor == p.left_minor  # exactly what is left: never more, never partial
        assert p.booking_date <= line.booking_date and p.bank_account_id == line.bank_account_id
    elif d.kind == "refund":
        (r,) = [x for x in refs if x.refund_request_id == d.refund_request_id]
        assert r.status == "requested" and r.bank_account_id == line.bank_account_id
        assert (
            line.amount_minor == r.amount_minor <= r.unallocated_minor
        )  # never above what is left
        assert d.payment_id == r.payment_id
    elif d.kind == "refund_returned":
        (r,) = [x for x in refs if x.refund_request_id == d.refund_request_id]
        assert line.direction == "credit" and r.status == "executed"
        assert line.amount_minor == r.amount_minor and line.booking_date >= r.date
    else:
        assert d.review_reason is not None


@settings(max_examples=200)
@given(
    amounts_=st.lists(amounts, min_size=1, max_size=6),
    names=st.lists(st.sampled_from(["P1", "P2", "P3"]), min_size=1, max_size=6),
)
def test_a_payment_is_linked_at_most_once_per_run(amounts_: list[int], names: list[str]) -> None:
    n = min(len(amounts_), len(names))
    lines_ = [ret(amounts_[k], line_id=f"L{k}") for k in range(n)]
    cands = {f"L{k}": [pay(names[k], amounts_[k])] for k in range(n)}
    linked = [d.payment_id for d in decide_all(lines_, cands, {}) if d.linked]
    assert len(linked) == len(set(linked))
