"""Our transfers' debits and returns booked from the statement (M2c-6b-1, decide_bookings;
plan docs/design/m2c-6b-plan.md §2.3, §2.4, §4.3). Examples per rule, then Hypothesis properties: a
transfer is in at most one automatic debit booking and one return booking per pass; a booking only
when every condition of plan §2.3 holds (its file handed out, its amount, account and currency, its
run in flight; a batch line exactly its in_file members, of one kind, adding up); any line naming a
cancelled transfer (or a batch line with a cancelled member) or a second debit goes to ops, never
booked; the decisions do not depend on the order the lines come in; amounts_make_up is a subset sum
(bounded like its SQL twin)."""

from __future__ import annotations

import itertools
import random
from dataclasses import replace
from datetime import date, timedelta

from hypothesis import find, given, settings
from hypothesis import strategies as st

from collectoo_worker.payments.debits import (
    BATCH_MIXED,
    BATCH_PARTIAL,
    BOOKING_REVIEW_REASONS,
    CANCELLED_TRANSFER_DEBITED,
    OWN_TRANSFER_OUT,
    P0_REVIEWS,
    RETURN_BEFORE_DEBIT,
    RETURN_DIFFERS,
    RUN_NOT_IN_FLIGHT,
    TOP_UP_DIFFERS,
    TOP_UP_NOT_FOUND,
    TRANSFER_DEBITED_TWICE,
    TRANSFER_DIFFERS,
    TRANSFER_NOT_HANDED_OUT,
    TRANSFER_UNKNOWN,
    Booking,
    DebitLine,
    FundsLine,
    RefundCandidate,
    TransferFact,
    amounts_make_up,
    decide,
    decide_bookings,
    decide_line,
    deferred_returns,
)

BANK = "bank-1"
DAY = date(2026, 11, 3)
FILE = "file-1"
PMT = "TF-2026-000001-1"


def fact(  # noqa: PLR0913 - a transfer's facts
    tid: str,
    amount: int,
    *,
    role: str = "own",
    kind: str = "payout",
    status: str = "in_file",
    downloads: int = 1,
    file_status: str = "downloaded",
    run_status: str | None = "sent",
    run_transfer: str | None = None,
    bank: str = BANK,
    debit_booked: bool = False,
    return_booked: bool = False,
    return_seen: bool = False,
    debit_date: date | None = None,
) -> TransferFact:
    return TransferFact(
        id=tid,
        role=role,
        kind=kind,
        status=status,
        amount_minor=amount,
        debtor_bank_account_id=bank,
        file_id=FILE,
        file_status=file_status,
        file_download_count=downloads,
        pmt_inf_id=PMT,
        batch_file_id=FILE if role == "member" else None,
        batch_file_status=file_status if role == "member" else None,
        batch_file_download_count=downloads if role == "member" else 0,
        run_status=run_status if kind == "payout" else None,
        run_transfer_id=(run_transfer or tid) if kind == "payout" else None,
        debit_booked=debit_booked,
        return_booked=return_booked,
        return_seen=return_seen,
        debit_date=debit_date,
    )


def debit(
    amount: int,
    *facts: TransferFact,
    e2e: str | None = "RMT0123456789AB",
    line: str = "L1",
    unsplit_ours: int | None = None,
) -> FundsLine:
    return FundsLine(
        line,
        "batch_unsplit" if unsplit_ours is not None else "transfer_out",
        "debit",
        BANK,
        amount,
        DAY,
        end_to_end_id=e2e,
        unsplit_ours=unsplit_ours,
        facts=tuple(facts),
    )


def batch(
    amount: int,
    *members: TransferFact,
    kind: str = "batch_unsplit",
    line: str = "B1",
    unsplit_ours: int | None = None,
) -> FundsLine:
    return FundsLine(
        line,
        kind,
        "debit",
        BANK,
        amount,
        DAY,
        payment_info_id=PMT,
        unsplit_ours=unsplit_ours,
        facts=tuple(members),
    )


def back(
    amount: int,
    f: TransferFact,
    *,
    orig: str = "RMT0123456789AB",
    line: str = "R1",
    unsplit_ours: int | None = None,
) -> FundsLine:
    return FundsLine(
        line,
        "return",
        "credit",
        BANK,
        amount,
        DAY,
        original_end_to_end_id=orig,
        unsplit_ours=unsplit_ours,
        facts=(replace(f, role="return"),),
    )


def reason(line: FundsLine) -> str | None:
    out = decide_line(line)
    assert len(out) == 1 and not out[0].booked
    return out[0].review_reason


# -- a debit carrying our id ----------------------------------------------------------------------


def test_a_payout_debited_under_its_own_id_is_booked() -> None:
    assert decide_line(debit(164000, fact("T1", 164000))) == [Booking("L1", "payout", "T1")]
    sweep = fact("S1", 12000, kind="sweep")
    assert decide_line(debit(12000, sweep, e2e="SWP0123456789AB")) == [Booking("L1", "sweep", "S1")]


def test_a_debit_of_our_id_is_never_booked_otherwise() -> None:
    assert reason(debit(164000)) == TRANSFER_UNKNOWN  # our id's form, no transfer of ours
    assert (
        reason(debit(164000, fact("T1", 164000, status="cancelled"))) == CANCELLED_TRANSFER_DEBITED
    )
    assert reason(debit(164000, fact("T1", 164000, status="booked"))) == TRANSFER_DEBITED_TWICE
    assert reason(debit(164000, fact("T1", 164000, debit_booked=True))) == TRANSFER_DEBITED_TWICE
    assert reason(debit(164000, fact("T1", 164000, status="ordered"))) == TRANSFER_NOT_HANDED_OUT
    never = fact("T1", 164000, downloads=0, file_status="generated")
    assert reason(debit(164000, never)) == TRANSFER_NOT_HANDED_OUT
    assert reason(debit(163999, fact("T1", 164000))) == TRANSFER_DIFFERS
    assert reason(debit(164000, fact("T1", 164000, bank="bank-2"))) == TRANSFER_DIFFERS
    assert reason(debit(164000, fact("T1", 164000, run_status="cancelled"))) == RUN_NOT_IN_FLIGHT
    # a re-issue moved the run to another transfer: the old id never books the run's payout
    assert reason(debit(164000, fact("T1", 164000, run_transfer="T2"))) == RUN_NOT_IN_FLIGHT
    # an RMT id naming a sweep, an SWP id naming a payout
    assert reason(debit(12000, fact("S1", 12000, kind="sweep"))) == TRANSFER_UNKNOWN
    assert reason(debit(5000, fact("T1", 5000), e2e="SWP0123456789AB")) == TRANSFER_UNKNOWN


def test_a_debit_to_our_own_iban_without_our_reference_waits_for_ops() -> None:
    assert reason(debit(5000, e2e=None)) == OWN_TRANSFER_OUT


# -- a batch line ---------------------------------------------------------------------------------


def test_a_batch_line_books_exactly_its_in_file_members() -> None:
    a, b = fact("T1", 82000, role="member"), fact("T2", 50000, role="member")
    assert decide_line(batch(132000, b, a)) == [
        Booking("B1", "payout", "T1"),
        Booking("B1", "payout", "T2"),
    ]
    # kept as transfer_out (to the own IBAN: the sweep) or an other debit, the same
    sweep = fact("S1", 12000, role="member", kind="sweep")
    assert decide_line(batch(12000, sweep, kind="transfer_out")) == [Booking("B1", "sweep", "S1")]
    # a member booked by its own id already: the line is the others'
    done = fact("T3", 7000, role="member", status="booked", debit_booked=True)
    assert len(decide_line(batch(132000, a, b, done, kind="other_debit"))) == 2


def test_a_batch_line_is_never_a_best_subset() -> None:
    a, b = fact("T1", 82000, role="member"), fact("T2", 50000, role="member")
    assert reason(batch(82000, a, b)) == BATCH_PARTIAL
    assert reason(batch(132001, a, b)) == BATCH_PARTIAL
    refund = fact("Q1", 5000, role="member", kind="refund")
    assert reason(batch(87000, a, refund)) == BATCH_MIXED
    two = fact("Q2", 3000, role="member", kind="refund")
    assert reason(batch(8000, refund, two)) == BATCH_MIXED
    gone = replace(a, status="cancelled")
    assert reason(batch(132000, gone, b)) == CANCELLED_TRANSFER_DEBITED  # it can be in the line
    assert reason(batch(50000, gone, b)) == BATCH_PARTIAL  # it cannot: still never booked
    paid = replace(gone, return_seen=True)  # paid in the batch, then returned
    assert decide_line(batch(50000, paid, b)) == [Booking("B1", "payout", "T2")]
    booked = replace(a, status="booked", debit_booked=True)
    assert reason(batch(82000, booked)) == TRANSFER_DEBITED_TWICE
    never = fact("T1", 82000, role="member", downloads=0, file_status="generated")
    assert reason(batch(82000, never)) == TRANSFER_NOT_HANDED_OUT
    assert reason(batch(82000)) == TRANSFER_UNKNOWN


def test_a_batch_line_of_a_file_never_handed_out_is_that_first() -> None:
    """Review round 2 (T2's precedence): a batch line naming the PmtInf of a file the bank never
    had (never downloaded) is `transfer_not_handed_out`, even when a member of that PmtInf is
    cancelled and the line could be it — the file's state is read before its members' (mutant:
    the file's check removed, the line reads `cancelled_transfer_debited`)."""
    live = fact("T1", 82000, role="member", downloads=0, file_status="generated")
    gone = replace(live, id="T2", amount_minor=50000, status="cancelled")
    assert reason(batch(50000, live, gone)) == TRANSFER_NOT_HANDED_OUT
    assert reason(batch(132000, live, gone)) == TRANSFER_NOT_HANDED_OUT
    # handed out, the same line is the cancelled member's possible debit (P0)
    handed = [
        replace(
            m,
            file_status="downloaded",
            batch_file_status="downloaded",
            file_download_count=1,
            batch_file_download_count=1,
        )
        for m in (live, gone)
    ]
    assert reason(batch(50000, *handed)) == CANCELLED_TRANSFER_DEBITED


def test_a_batch_line_is_never_booked_when_one_member_could_not_be() -> None:
    """Review T2 (mutant P16): in a downloaded file, a batch line whose sum and kind are right is
    left to ops, never booked, when one of its members could not be booked on its own: its run
    not in flight (cancelled, or moved to a re-issue), debited from another account, or already
    debited (P0: a second debit)."""
    a, b = fact("T1", 82000, role="member"), fact("T2", 50000, role="member")
    assert reason(batch(132000, a, replace(b, run_status="cancelled"))) == RUN_NOT_IN_FLIGHT
    assert reason(batch(132000, a, replace(b, run_transfer_id="T9"))) == RUN_NOT_IN_FLIGHT
    assert reason(batch(132000, a, replace(b, debtor_bank_account_id="bank-2"))) == (
        TRANSFER_DIFFERS
    )
    assert reason(batch(132000, a, replace(b, debit_booked=True))) == TRANSFER_DEBITED_TWICE
    assert reason(batch(132000, a, replace(b, currency="CHF"))) == TRANSFER_DIFFERS


# -- a return -------------------------------------------------------------------------------------


def test_a_returned_payout_is_booked_from_its_original_id() -> None:
    booked = fact("T1", 164000, status="booked", debit_booked=True)
    assert decide_line(back(164000, booked)) == [Booking("R1", "payout_returned", "T1")]
    assert decide_line(back(163000, booked)) == [Booking("R1", "payout_returned", "T1")]  # charges
    assert reason(back(164001, booked)) == RETURN_DIFFERS
    assert reason(back(164000, fact("T1", 164000))) == RETURN_BEFORE_DEBIT
    assert (
        reason(back(164000, replace(booked, status="returned", return_booked=True)))
        == RETURN_DIFFERS
    )
    assert reason(back(164000, replace(booked, status="cancelled"))) == RETURN_DIFFERS
    sweep = fact("S1", 12000, kind="sweep", status="booked", debit_booked=True)
    assert decide_line(back(12000, sweep, orig="SWP0123456789AB")) == [
        Booking("R1", "sweep_returned", "S1")
    ]


def test_a_return_dated_before_its_debit_is_never_booked() -> None:
    """Review T4, K5: a return dated before the debit it returns (the debit's entry date) is
    `return_before_debit`, as the SQL re-check says — the same day or later, booked."""
    booked = fact("T1", 164000, status="booked", debit_booked=True)
    later = replace(booked, debit_date=DAY + timedelta(days=1))
    assert reason(back(164000, later)) == RETURN_BEFORE_DEBIT
    assert decide_line(back(164000, replace(booked, debit_date=DAY))) == [
        Booking("R1", "payout_returned", "T1")
    ]
    sweep = fact("S1", 12000, kind="sweep", status="booked", debit_booked=True)
    early = back(12000, replace(sweep, debit_date=DAY + timedelta(days=2)), orig="SWP0123456789AB")
    assert reason(early) == RETURN_BEFORE_DEBIT


def test_an_unsplit_batch_is_never_our_transfer_s_return() -> None:
    """Review round 6 (R1), narrowed by round 7 (S1, verdict new:unsplit-exact-total-other-details):
    a line read from a camt.053 entry kept unsplit carries the entry's total, not one
    transaction's — whatever its count of details of ours and its amount, it is never booked as our
    transfer's return: `return_differs`. Round 6 still booked exactly one detail of ours for the
    transfer's exact amount, and the verifier booked a debtor's 50,00 € (u05, u06) or a detail 50,00
    € short (u03) into our return that way. The parser gives a detail that is the whole entry a line
    of its own (payments.camt053), which keeps the rules: the transfer's amount, or less with the
    rest as the bank's charge."""
    booked = fact("T1", 419840, status="booked", debit_booked=True)
    netted = back(419840 - 32800, booked, unsplit_ours=1)  # our return + another payout's debit
    assert reason(netted) == RETURN_DIFFERS
    assert reason(back(419840 - 300000, booked, unsplit_ours=1)) == RETURN_DIFFERS  # a chargeback
    assert reason(back(419840 + 5000, booked, unsplit_ours=1)) == RETURN_DIFFERS  # a debtor's too
    assert reason(back(419840, booked, unsplit_ours=1)) == RETURN_DIFFERS  # u05, u06, u03, u01
    assert reason(back(419840, booked, unsplit_ours=2)) == RETURN_DIFFERS  # several of ours
    assert reason(back(419840, booked, unsplit_ours=0)) == RETURN_DIFFERS
    assert decide_line(back(419840, booked)) == [Booking("R1", "payout_returned", "T1")]
    assert decide_line(back(419840 - 150, booked)) == [Booking("R1", "payout_returned", "T1")]
    sweep = fact("S1", 12000, kind="sweep", status="booked", debit_booked=True)
    assert reason(back(11000, sweep, orig="SWP0123456789AB", unsplit_ours=1)) == RETURN_DIFFERS
    assert reason(back(12000, sweep, orig="SWP0123456789AB", unsplit_ours=1)) == RETURN_DIFFERS
    assert decide_line(back(12000, sweep, orig="SWP0123456789AB")) == [
        Booking("R1", "sweep_returned", "S1")
    ]
    # the clearer reasons first, as before: not booked yet, or returned already
    assert reason(back(419840, fact("T1", 419840), unsplit_ours=1)) == RETURN_BEFORE_DEBIT


def test_a_line_holding_our_transfer_unsplit_is_reviewed_and_never_booked() -> None:
    """Review round 7 (S2, verdict new:debit-entry-unsplit-with-our-details-explainable): a line of
    a camt.053 entry the bank kept unsplit holding a detail of ours (`unsplit_ours` > 0), whatever
    its direction, is never booked automatically and always reviewed — it waits for ops' booking
    (M2c-6b-2; COMPLIANCE OQ-84). The P0 reasons keep their place: a cancelled transfer's id first.
    A debit by the id its one detail gives (d04), a batch line of our lot whose details are given
    but do not add up: `batch_partial`; a debit holding ours with no id (d01, d02, d03), a debit
    return holding ours: `batch_partial`; a credit whose only detail of ours is of the other
    direction (x01: no id of ours kept): `return_differs`. With no detail of ours (0), a batch line
    of our lot keeps its rules (the bank sent no details: booked), and a line of its own too."""
    t = fact("T1", 32800)
    assert reason(debit(32800, t, unsplit_ours=1)) == BATCH_PARTIAL  # d04
    assert decide_line(debit(32800, t)) == [Booking("L1", "payout", "T1")]
    gone = fact("T1", 32800, status="cancelled")
    assert reason(debit(32800, gone, unsplit_ours=1)) == CANCELLED_TRANSFER_DEBITED
    a, b = fact("T1", 82000, role="member"), fact("T2", 50000, role="member")
    assert reason(batch(132000, a, b, unsplit_ours=2)) == BATCH_PARTIAL
    assert decide_line(batch(132000, a, b, unsplit_ours=0)) == [
        Booking("B1", "payout", "T1"),
        Booking("B1", "payout", "T2"),
    ]
    assert reason(batch(132000, replace(a, status="cancelled"), b, unsplit_ours=2)) == (
        CANCELLED_TRANSFER_DEBITED
    )
    for amount, kind, ours in ((80160, "batch_unsplit", 1), (61800, "batch_unsplit", 2),
                               (4000, "return", 1)):  # fmt: skip
        line = FundsLine("D1", kind, "debit", BANK, amount, DAY, unsplit_ours=ours)
        assert reason(line) == BATCH_PARTIAL
        assert decide_line(replace(line, unsplit_ours=0)) == []  # not ours: ops classify it
    x01 = FundsLine("X1", "return", "credit", BANK, 50000, DAY, unsplit_ours=1)
    assert reason(x01) == RETURN_DIFFERS
    assert decide_line(replace(x01, unsplit_ours=0)) == []  # (the M2b pass's)


def test_an_own_credit_naming_our_lot_is_never_a_top_up() -> None:
    """Review round 7 (S3, verdict new:own-client-credit-naming-our-lot-relay-top-up): a credit
    from our own account naming a handed-out lot of its own account (`names_our_lot`, read by
    private.bank_booking_candidates) is our outgoing transfer coming back, whatever its end-to-end
    id — even one carrying the TOP id of a pending top-up of its amount: never booked as the top-up
    (the SQL re-check refuses it, own_transfer_line), reviewed. A top-up's lot would be a file of
    the own account, never of this dedicated one."""
    line = FundsLine(
        "C1",
        "own_transfer_in",
        "credit",
        BANK,
        5000,
        DAY,
        transfer_id="TOP1",
        transfer_status="ordered",
        transfer_amount_minor=5000,
        transfer_creditor=BANK,
        end_to_end_id="TOP0123456789AB",
        payment_info_id=PMT,
    )
    assert decide_line(line) == [Booking("C1", "top_up", "TOP1")]
    assert reason(replace(line, names_our_lot=True)) == TOP_UP_DIFFERS
    no_order = replace(line, transfer_id=None, end_to_end_id="VIR-CABINET-1", names_our_lot=True)
    assert reason(no_order) == TOP_UP_NOT_FOUND


# -- a pass ----------------------------------------------------------------------------------


def test_a_transfer_is_booked_once_per_pass() -> None:
    t = fact("T1", 164000)
    out = decide_bookings([debit(164000, t, line="L1"), debit(164000, t, line="L2")])
    assert out[0] == Booking("L1", "payout", "T1")
    assert not out[1].booked and out[1].review_reason == TRANSFER_DEBITED_TWICE


def test_a_same_day_return_after_its_debit_waits_for_the_next_pass() -> None:
    t = fact("T1", 164000)
    lines = [
        back(164000, replace(t, status="booked", debit_booked=True), line="A0"),
        debit(164000, t, line="Z9"),
    ]
    out = decide_bookings(lines)
    assert out == [Booking("Z9", "payout", "T1")]  # the day's debits first
    assert deferred_returns(lines, out) == ["A0"]


def test_a_batch_line_of_one_refund_is_the_m2b_refund_link() -> None:
    line = DebitLine("B1", "batch_unsplit", "debit", BANK, 5000, DAY)
    r = RefundCandidate("Q1", "P1", BANK, 5000, "requested", 5000, DAY - timedelta(days=3))
    assert (decide(line, refunds=[r]).kind, decide(line, refunds=[r]).refund_request_id) == (
        "refund",
        "Q1",
    )
    assert decide(line).kind == "review"  # with no refund named: nothing to link


# -- properties --------------------------------------------------------------------------------

AMOUNTS = (5000, 7000, 12000, 50000, 82000)
statuses = st.sampled_from(
    ["ordered", "in_file", "in_file", "in_file", "booked", "returned", "cancelled"]
)


@st.composite
def worlds(draw: st.DrawFn) -> list[FundsLine]:
    """A few transfers of ours and the lines a statement shows of them: debits by their own id,
    batch lines of their PmtInf (of any subset, any amount), returns."""
    n = draw(st.integers(1, 6))
    transfers = []
    for i in range(n):
        status = draw(statuses)
        transfers.append(
            fact(
                f"T{i}",
                draw(st.sampled_from(AMOUNTS)),
                kind=draw(st.sampled_from(["payout", "payout", "sweep", "refund"])),
                status=status,
                downloads=draw(st.sampled_from([0, 1, 2])),
                file_status=draw(st.sampled_from(["generated", "downloaded", "sent"])),
                run_status=draw(st.sampled_from(["approved", "sent", "booked", "cancelled"])),
                run_transfer=draw(st.sampled_from([None, "T9"])),
                bank=draw(st.sampled_from([BANK, BANK, "bank-2"])),
                debit_booked=status in ("booked", "returned") or draw(st.booleans()),
                return_booked=status == "returned",
                return_seen=draw(st.booleans()),
                debit_date=DAY + timedelta(days=draw(st.integers(0, 2)))
                if status in ("booked", "returned")
                else None,
            )
        )
    lines: list[FundsLine] = []
    for k in range(draw(st.integers(1, 6))):
        shape = draw(st.sampled_from(["own", "batch", "return"]))
        t = draw(st.sampled_from(transfers))
        amount = draw(st.sampled_from([t.amount_minor, t.amount_minor - 1, *AMOUNTS]))
        # review round 7 (S2): a line of its own, or of an entry kept unsplit with 0, 1 or 2 of its
        # details ours
        unsplit = draw(st.sampled_from([None, None, 0, 1, 1, 2]))
        if shape == "own":
            e2e = ("RMT" if t.kind == "payout" else "SWP") + "0123456789AB"
            ours = None if unsplit is None else max(unsplit, 1)  # its one detail is ours
            lines.append(debit(amount, t, e2e=e2e, line=f"L{k}", unsplit_ours=ours))
        elif shape == "batch":
            members = draw(
                st.lists(
                    st.sampled_from(transfers), min_size=1, max_size=4, unique_by=lambda f: f.id
                )
            )
            total = draw(st.sampled_from([sum(m.amount_minor for m in members), amount]))
            # every member is in the one file the PmtInfId names (review T2): its facts are that
            # file's, so the line reaches the cancelled, kind, sum and per-member rules
            head = min(members, key=lambda m: m.id)
            lines.append(
                batch(
                    total,
                    *(
                        replace(
                            m,
                            role="member",
                            file_status=head.file_status,
                            file_download_count=head.file_download_count,
                            batch_file_id=FILE,
                            batch_file_status=head.file_status,
                            batch_file_download_count=head.file_download_count,
                        )
                        for m in members
                    ),
                    line=f"L{k}",
                    # (a batch line of an entry kept unsplit holding ours less often: the guard
                    # below must still find a booked batch line)
                    unsplit_ours=None if unsplit == 1 else unsplit,
                )
            )
        elif t.kind in ("payout", "sweep"):
            orig = ("RMT" if t.kind == "payout" else "SWP") + "0123456789AB"
            lines.append(back(amount, t, orig=orig, line=f"L{k}", unsplit_ours=unsplit))
        day = DAY + timedelta(days=draw(st.integers(0, 2)))
        if lines:
            lines[-1] = replace(lines[-1], booking_date=day)
    return lines


def _handed(f: TransferFact) -> bool:
    return f.file_download_count > 0 and f.file_status in ("downloaded", "sent")


@settings(max_examples=400)
@given(worlds())
def test_a_booking_only_when_every_condition_holds(lines: list[FundsLine]) -> None:
    out = decide_bookings(lines)
    by_id = {x.id: x for x in lines}
    debited: set[str] = set()
    returned: set[str] = set()
    for b in out:
        line = by_id[b.line_id]
        if not b.booked:
            assert b.review_reason in BOOKING_REVIEW_REASONS
            continue
        f = next(x for x in line.facts if x.id == b.transfer_id)
        if b.kind in ("payout", "sweep"):
            assert f.kind == b.kind and f.status == "in_file" and _handed(f) and not f.debit_booked
            assert f.debtor_bank_account_id == line.bank_account_id
            if f.kind == "payout":
                assert f.run_status in ("approved", "sent") and f.run_transfer_id == f.id
            assert b.transfer_id not in debited  # booked once
            debited.add(f.id)
            # S2: never from an entry kept unsplit holding a detail of ours
            assert not line.unsplit_ours
            if line.end_to_end_id is not None:
                assert f.role == "own" and f.amount_minor == line.amount_minor
            else:  # a batch line: exactly its in_file members, one kind, adding up, none cancelled
                assert all(m.status != "cancelled" or m.return_seen for m in line.facts)
                live = [m for m in line.facts if m.status == "in_file"]
                assert {m.kind for m in live} == {b.kind}
                assert sum(m.amount_minor for m in live) == line.amount_minor
                assert {x.transfer_id for x in out if x.line_id == line.id} == {m.id for m in live}
        else:
            assert b.kind == f"{f.kind}_returned" and f.status == "booked" and f.debit_booked
            assert line.amount_minor <= f.amount_minor and f.id not in returned
            assert f.debit_date is None or line.booking_date >= f.debit_date
            assert line.unsplit_ours is None  # R1, S1: a line of its own only
            returned.add(f.id)


@settings(max_examples=400)
@given(worlds())
def test_a_cancelled_transfer_or_a_second_debit_is_never_booked(lines: list[FundsLine]) -> None:
    out = decide_bookings(lines)
    by_id = {x.id: x for x in lines}
    for b in out:
        line = by_id[b.line_id]
        named = [f for f in line.facts if f.role in ("own", "member")]
        if any(f.status == "cancelled" and not f.return_seen for f in named):
            assert not b.booked
        if b.booked and b.kind in ("payout", "sweep"):
            f = next(x for x in named if x.id == b.transfer_id)
            assert f.status not in ("booked", "returned") and not f.debit_booked
        if not b.booked and b.review_reason in P0_REVIEWS:
            assert b.candidates or b.review_reason == TRANSFER_UNKNOWN or line.facts


@settings(max_examples=200)
@given(worlds(), st.randoms(use_true_random=False))
def test_the_decisions_do_not_depend_on_the_lines_order(
    lines: list[FundsLine], rnd: random.Random
) -> None:
    shuffled = lines[:]
    rnd.shuffle(shuffled)
    assert decide_bookings(shuffled) == decide_bookings(lines)


@settings(max_examples=300)
@given(
    st.integers(1, 10**12),
    st.one_of(st.just(0), st.integers(-(10**6), 10**6)),
    st.one_of(st.none(), st.integers(0, 4)),
    st.sampled_from(["payout", "sweep"]),
)
def test_an_unsplit_entry_is_never_booked_as_a_return(
    amount: int, delta: int, unsplit: int | None, kind: str
) -> None:
    """Review round 6 (R1) as a property, narrowed by round 7 (S1): a return of our booked transfer
    is booked from a line of its own when no more than the transfer (the rest the bank's charge),
    and never from a line of an entry kept unsplit, whatever its count and amount —
    `return_differs`, nothing booked."""
    f = fact("T1", amount, kind=kind, status="booked", debit_booked=True)
    orig = ("RMT" if kind == "payout" else "SWP") + "0123456789AB"
    line_amount = max(1, amount + delta)
    (out,) = decide_line(back(line_amount, f, orig=orig, unsplit_ours=unsplit))
    want = unsplit is None and line_amount <= amount
    assert out.booked == want
    assert out.booked or out.review_reason == RETURN_DIFFERS


@settings(max_examples=400)
@given(worlds())
def test_a_line_holding_ours_unsplit_is_always_reviewed_never_booked(
    lines: list[FundsLine],
) -> None:
    """Review round 7 (S2) as a property of a pass: a line of an entry kept unsplit holding a detail
    of ours (or, a return, any line of an entry kept unsplit) never gets a booking and always gets
    a review — or waits for the next pass when its transfer's debit is booked by this one."""
    out = decide_bookings(lines)
    later = set(deferred_returns(lines, out))
    for line in lines:
        if line.unsplit_ours or (line.direction == "credit" and line.unsplit_ours is not None):
            mine = [b for b in out if b.line_id == line.id]
            assert all(not b.booked for b in mine)
            assert len(mine) == 1 or (not mine and line.id in later)
            assert not mine or mine[0].review_reason in BOOKING_REVIEW_REASONS


@given(st.lists(st.integers(1, 60), max_size=7), st.integers(0, 150))
def test_amounts_make_up_is_a_subset_sum(amounts: list[int], target: int) -> None:
    brute = target == 0 or any(
        sum(c) == target
        for k in range(1, len(amounts) + 1)
        for c in itertools.combinations(amounts, k)
    )
    assert amounts_make_up(amounts, target) == brute


def _booked_batch(lines: list[FundsLine]) -> bool:
    return any(b.booked for x in lines if x.batch for b in decide_line(x))


def test_the_worlds_book_batch_lines_and_reach_every_review() -> None:
    """Review T2: the generator must reach the batch rules (a booked batch line), or the
    properties check nothing of them; and every reason a transfer line can be reviewed for."""
    # (review round 7: more examples allowed — the worlds draw lines of unsplit entries too)
    world = find(worlds(), _booked_batch, settings=settings(max_examples=8000, database=None))
    assert _booked_batch(world)
    seen: set[str] = set()

    @settings(max_examples=1500, database=None)
    @given(worlds())
    def collect(lines: list[FundsLine]) -> None:
        seen.update(b.review_reason for b in decide_bookings(lines) if b.review_reason)
        seen.update(
            b.review_reason for x in lines if x.batch for b in decide_line(x) if b.review_reason
        )

    collect()
    assert {
        BATCH_MIXED,
        BATCH_PARTIAL,
        CANCELLED_TRANSFER_DEBITED,
        RUN_NOT_IN_FLIGHT,
        TRANSFER_DEBITED_TWICE,
        TRANSFER_DIFFERS,
        TRANSFER_NOT_HANDED_OUT,
        RETURN_BEFORE_DEBIT,
        RETURN_DIFFERS,
    } <= seen
