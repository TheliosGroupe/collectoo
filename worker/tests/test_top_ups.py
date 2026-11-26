"""M2c-7e-1 (plan docs/design/m2c-7-plan.md §7.2 [critic] M7-MONEY-4; ADR-0014 « M2c-7e-1 »): the
debit job's decision on a credit carrying the TOP id of one of our top-ups — the twin of the SQL
re-check (private.bank_booking_recheck's top-up rule; integration parity in
test_top_ups_integration.py).

A top-up's credit books as servicer_top_up when its transfer is `ordered`, or `in_file` of an
own-account file of the servicer (`transfer_filed_own`: private.top_up_in_own_file, the file's
debtor that servicer's own account); a credit naming a `cancelled` top-up goes to review
`top_up_cancelled_credit` (« Approvisionnement annulé puis exécuté par la banque »: ops book it with
no transfer); any other state, amount or account goes to review `top_up_differs`, as before. A
credit naming one of our lots of the dedicated account is never a top-up (S3, unchanged)."""

from __future__ import annotations

from dataclasses import replace
from datetime import date

from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.payments.debits import (
    BOOKING_REVIEW_REASONS,
    P0_REVIEWS,
    TOP_UP_CANCELLED_CREDIT,
    TOP_UP_DIFFERS,
    TOP_UP_NOT_FOUND,
    Booking,
    FundsLine,
    decide_bookings,
    decide_line,
)

BANK = "cf-1"
DAY = date(2026, 11, 26)


def credit(  # noqa: PLR0913 - a credit's facts
    status: str = "ordered",
    *,
    filed_own: bool = False,
    amount: int = 150_000,
    transfer_amount: int = 150_000,
    creditor: str = BANK,
    names_our_lot: bool = False,
    line: str = "C1",
    transfer: str | None = "TOP1",
) -> FundsLine:
    return FundsLine(
        line,
        "own_transfer_in",
        "credit",
        BANK,
        amount,
        DAY,
        transfer_id=transfer,
        transfer_status=status if transfer else None,
        transfer_amount_minor=transfer_amount if transfer else None,
        transfer_creditor=creditor if transfer else None,
        transfer_filed_own=filed_own,
        end_to_end_id="TOP0123456789AB" if transfer else None,
        names_our_lot=names_our_lot,
    )


def reason(line: FundsLine) -> str | None:
    out = decide_line(line)
    assert len(out) == 1
    return out[0].review_reason


def test_a_filed_top_up_s_credit_is_booked() -> None:
    """[critic] M7-MONEY-4: filing puts a top-up in_file; its credit books it, as an ordered one."""
    assert decide_line(credit("ordered")) == [Booking("C1", "top_up", "TOP1")]
    assert decide_line(credit("in_file", filed_own=True)) == [Booking("C1", "top_up", "TOP1")]


def test_a_top_up_in_file_of_no_own_account_file_is_not_booked() -> None:
    """Only an own-account file of the servicer holds top-ups (the item guard); any other in_file
    state is not bookable: reviewed as before."""
    assert reason(credit("in_file", filed_own=False)) == TOP_UP_DIFFERS


def test_the_credit_of_a_cancelled_top_up_goes_to_its_own_review() -> None:
    """A top-up cancelled (with its file, or alone) then executed by the bank: the servicer's own
    money arrived; ops book it with no transfer (« Comptabiliser comme approvisionnement »)."""
    assert reason(credit("cancelled")) == TOP_UP_CANCELLED_CREDIT
    # whatever its amount (no transfer is booked by it)
    assert reason(credit("cancelled", amount=1)) == TOP_UP_CANCELLED_CREDIT
    # but never on another dedicated account than the one it was ordered to (as the SQL's
    # transfer_unknown comes before its status)
    assert reason(credit("cancelled", creditor="cf-2")) == TOP_UP_DIFFERS


def test_other_states_amounts_and_accounts_keep_their_review() -> None:
    for status in ("booked", "returned"):
        assert reason(credit(status)) == TOP_UP_DIFFERS
        assert reason(credit(status, filed_own=True)) == TOP_UP_DIFFERS
    assert reason(credit("ordered", amount=149_999)) == TOP_UP_DIFFERS
    assert reason(credit("in_file", filed_own=True, amount=150_001)) == TOP_UP_DIFFERS
    assert reason(credit("in_file", filed_own=True, creditor="cf-2")) == TOP_UP_DIFFERS
    # (S3, unchanged) naming one of our lots of the dedicated account: never a top-up
    assert reason(credit("in_file", filed_own=True, names_our_lot=True)) == TOP_UP_DIFFERS
    assert reason(credit("cancelled", names_our_lot=True)) == TOP_UP_DIFFERS
    assert reason(credit(transfer=None)) == TOP_UP_NOT_FOUND


def test_the_new_review_is_a_booking_review_and_no_p0() -> None:
    assert TOP_UP_CANCELLED_CREDIT == "top_up_cancelled_credit"
    assert TOP_UP_CANCELLED_CREDIT in BOOKING_REVIEW_REASONS
    assert TOP_UP_CANCELLED_CREDIT not in P0_REVIEWS


def test_a_filed_top_up_is_booked_once_per_pass() -> None:
    """Two credits carrying the same filed TOP id in one pass: the first books it, the second waits
    (top_up_differs), as for an ordered one."""
    a, b = credit("in_file", filed_own=True), credit("in_file", filed_own=True, line="C2")
    out = decide_bookings([a, b])
    assert [x.kind for x in out] == ["top_up", None]
    assert out[1].review_reason == TOP_UP_DIFFERS


def expected(line: FundsLine) -> tuple[str | None, str | None]:
    """The reference rule (the SQL re-check's order: our lot, no order, the account, the status, the
    amount)."""
    if line.transfer_id is None:
        return None, TOP_UP_NOT_FOUND
    if line.names_our_lot or line.transfer_creditor != line.bank_account_id:
        return None, TOP_UP_DIFFERS
    if line.transfer_status == "cancelled":
        return None, TOP_UP_CANCELLED_CREDIT
    bookable = line.transfer_status == "ordered" or (
        line.transfer_status == "in_file" and line.transfer_filed_own
    )
    if not bookable or line.transfer_amount_minor != line.amount_minor:
        return None, TOP_UP_DIFFERS
    return "top_up", None


@given(
    status=st.sampled_from(["ordered", "in_file", "cancelled", "booked", "returned"]),
    filed_own=st.booleans(),
    same_amount=st.booleans(),
    same_account=st.booleans(),
    lot=st.booleans(),
    has_order=st.booleans(),
)
def test_decide_line_on_top_up_credits(  # noqa: PLR0913, PLR0917 - one fact per strategy
    status: str, filed_own: bool, same_amount: bool, same_account: bool, lot: bool, has_order: bool
) -> None:
    """[critic] Hypothesis on transfer_status ∈ {ordered, in_file, cancelled, …} for top-up credits:
    the job books exactly when the transfer is ordered or filed in an own-account file, of the
    line's amount, ordered to the line's account, and reviews a cancelled one apart."""
    line = credit(
        status,
        filed_own=filed_own,
        transfer_amount=150_000 if same_amount else 150_100,
        creditor=BANK if same_account else "cf-2",
        names_our_lot=lot,
        transfer="TOP1" if has_order else None,
    )
    kind, why = expected(line)
    out = decide_line(line)
    assert len(out) == 1
    assert (out[0].kind, out[0].review_reason) == (kind, why)
    if kind is not None:
        assert out[0].transfer_id == "TOP1"
    assert decide_line(replace(line, id="C9"))[0].line_id == "C9"
