"""M2c-1 (M2-12), pure: our own transfers recognised at import (`payments.statement.refine_kind`,
`classify`), camt.053 PmtInfId, and the debit job's bookings in the funds
(`payments.debits.decide_bookings`: bank charges as fees, the top-ups we ordered). Design
docs/design/m2c-remittances.md §12; the SQL twins: tests/test_funds_integration.py."""

from datetime import date
from pathlib import Path

import pytest
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.payments.camt053 import parse_camt053
from collectoo_worker.payments.debits import (
    CLIENT_CREDIT,
    OWN_TRANSFER_OUT,
    TOP_UP_DIFFERS,
    TOP_UP_NOT_FOUND,
    Booking,
    FundsLine,
    charge_code,
    decide_booking,
    decide_bookings,
)
from collectoo_worker.payments.statement import TOP_UP_ID_RE, KnownIbans, classify, refine_kind
from collectoo_worker.synth.camt053 import Entry, Tx, make_doc, render_camt053

OWN = "FR7030001007940000000002002"  # synthetic own account
CLIENT = "FR0930001007940000000003003"  # synthetic client payout account
IBANS = KnownIbans(own=frozenset({OWN}), clients=frozenset({CLIENT}))
TOP = "TOP0123456789AB"
DAY = date(2026, 11, 6)

KINDS = (
    "debtor_credit",
    "return",
    "refund_out",
    "other_debit",
    "batch_unsplit",
    "transfer_out",
    "own_transfer_in",
    "client_transfer_in",
)
e2e_ids = st.one_of(
    st.none(),
    st.sampled_from([TOP, "RMT0123456789AB", "SWP0123456789AB", "RFD0123456789AB", "TOPAZ-1"]),
    st.from_regex(r"(TOP|RMT|SWP|RFD|E2E)[0-9A-Fa-f]{10,13}", fullmatch=True),
)
ibans = st.one_of(st.none(), st.sampled_from([OWN, CLIENT, "FR7630004000031234567890143"]))


@pytest.mark.parametrize(
    ("direction", "e2e", "iban", "kind"),
    [
        ("credit", TOP, None, "own_transfer_in"),  # our TOP id
        ("credit", "E2E-1", OWN, "own_transfer_in"),  # from our own IBAN
        ("credit", "E2E-1", CLIENT, "client_transfer_in"),  # from a client's payout IBAN
        ("credit", "TOPAZ-2026-1", None, "debtor_credit"),  # a look-alike is a debtor's
        ("credit", "top0123456789ab", None, "debtor_credit"),  # our ids are upper-case hex
        ("debit", "RMT0123456789AB", None, "transfer_out"),  # our payout
        ("debit", "SWP0123456789AB", None, "transfer_out"),  # our sweep
        ("debit", None, OWN, "transfer_out"),  # to our own IBAN
        ("debit", "RFD0123456789AB", OWN, "refund_out"),  # our refund stays a refund
        ("debit", None, None, "other_debit"),
    ],
)
def test_our_own_transfers_are_recognised(
    direction: str, e2e: str | None, iban: str | None, kind: str
) -> None:
    got = classify(
        direction,
        reversal=False,
        return_reason=None,
        sub_family=None,
        end_to_end_id=e2e,
        counterparty_iban=iban,
        ibans=IBANS,
    )
    assert got == kind


def test_a_return_stays_a_return_whatever_it_carries() -> None:
    assert (
        classify(
            "credit",
            reversal=True,
            return_reason=None,
            sub_family=None,
            end_to_end_id=TOP,
            counterparty_iban=OWN,
            ibans=IBANS,
        )
        == "return"
    )


@given(st.sampled_from(KINDS), st.sampled_from(["credit", "debit"]), e2e_ids, ibans)
def test_a_credit_from_our_own_account_is_never_a_debtor_payment(
    kind: str, direction: str, e2e: str | None, iban: str | None
) -> None:
    got = refine_kind(kind, direction, e2e, iban, IBANS)
    if got == "debtor_credit" and direction == "credit":
        assert iban not in {OWN, CLIENT}
        assert not TOP_UP_ID_RE.fullmatch(e2e or "")
    # the refinement reads the facts again: refining twice changes nothing
    assert refine_kind(got, direction, e2e, iban, IBANS) == got
    # a parser's reading of our kinds is not the last word: the facts decide
    if kind in ("own_transfer_in", "client_transfer_in", "transfer_out"):
        base = "debtor_credit" if kind != "transfer_out" else "other_debit"
        assert got == refine_kind(base, direction, e2e, iban, IBANS)
    # returns, our refunds and unsplit batches are never re-read
    if kind in ("return", "refund_out", "batch_unsplit"):
        assert got == kind


def test_the_pmtinfid_of_a_batch_debit_is_kept(tmp_path: Path) -> None:
    entries = [
        Entry(
            70000,
            False,
            DAY,
            DAY,
            ref="NB1",
            code="PMNT/ICDT/ESCT",
            payment_info_id="PMTINF-RV-0001",
            batch_count=2,
            txs=(
                Tx(40000, ref="B1", end_to_end_id="RMT0123456789AB", name="MARTIN SAS"),
                Tx(30000, ref="B2", end_to_end_id="RMT0123456789AC", name="LILAS SAS"),
            ),
        ),
        Entry(
            5000, True, DAY, DAY, ref="NC1", txs=(Tx(5000, ref="C1", end_to_end_id=TOP, iban=OWN),)
        ),
        Entry(1200, False, DAY, DAY, ref="NF1", code="ACMT/MDOP/CHRG", info="FRAIS"),
    ]
    doc = make_doc(
        entries, iban="FR7630004000031234567890143", from_date=DAY, to_date=DAY, opening_minor=0
    )
    path = tmp_path / "s.xml"
    path.write_bytes(render_camt053(doc, "08"))
    parsed = parse_camt053(path, iban="FR7630004000031234567890143", currency="EUR", ibans=IBANS)
    got = [(x.kind, x.payment_info_id, x.amount_minor) for x in parsed.lines]
    assert got == [
        ("transfer_out", "PMTINF-RV-0001", 40000),
        ("transfer_out", "PMTINF-RV-0001", 30000),
        ("own_transfer_in", None, 5000),
        ("other_debit", None, 1200),
    ]


# --- the debit job's bookings in the funds -------------------------------------------------------


def _line(  # noqa: PLR0913 - the order a credit names, field by field
    kind: str,
    direction: str,
    *,
    bank_tx_code: str | None = None,
    transfer_id: str | None = None,
    transfer_status: str | None = None,
    transfer_amount_minor: int | None = None,
    transfer_creditor: str | None = None,
) -> FundsLine:
    return FundsLine(
        "L1",
        kind,
        direction,
        "B1",
        5000,
        DAY,
        bank_tx_code=bank_tx_code,
        transfer_id=transfer_id,
        transfer_status=transfer_status,
        transfer_amount_minor=transfer_amount_minor,
        transfer_creditor=transfer_creditor,
    )


def test_bank_charges_are_booked_as_fees() -> None:
    assert charge_code("ACMT/MDOP/CHRG") and charge_code("PMNT/MDOP/FEES")
    assert (
        not charge_code("PMNT/ICDT/ESCT")
        and not charge_code("PRTRY:CHRG")
        and not charge_code(None)
    )
    assert decide_booking(_line("other_debit", "debit", bank_tx_code="ACMT/MDOP/CHRG")) == Booking(
        "L1", "fee"
    )
    assert decide_booking(_line("other_debit", "debit", bank_tx_code="PMNT/ICDT/ESCT")) is None


def test_a_top_up_is_booked_from_its_order_only() -> None:
    def credit(
        transfer_id: str | None = "T1",
        status: str = "ordered",
        amount: int = 5000,
        creditor: str = "B1",
    ) -> FundsLine:
        return _line(
            "own_transfer_in",
            "credit",
            transfer_id=transfer_id,
            transfer_status=status,
            transfer_amount_minor=amount,
            transfer_creditor=creditor,
        )

    booked = decide_booking(credit())
    assert booked is not None and (booked.kind, booked.transfer_id) == ("top_up", "T1")
    for line, reason in [
        (credit(transfer_id=None), TOP_UP_NOT_FOUND),
        (credit(amount=4999), TOP_UP_DIFFERS),
        (credit(status="cancelled"), TOP_UP_DIFFERS),
        (credit(creditor="B2"), TOP_UP_DIFFERS),
        (_line("client_transfer_in", "credit"), CLIENT_CREDIT),
        (_line("transfer_out", "debit"), OWN_TRANSFER_OUT),
    ]:
        left = decide_booking(line)
        assert left is not None and not left.booked and left.review_reason == reason


lines = st.builds(
    FundsLine,
    id=st.uuids().map(str),
    kind=st.sampled_from(["other_debit", "transfer_out", "own_transfer_in", "client_transfer_in"]),
    direction=st.sampled_from(["credit", "debit"]),
    bank_account_id=st.sampled_from(["B1", "B2"]),
    amount_minor=st.integers(1, 10**6),
    booking_date=st.just(DAY),
    bank_tx_code=st.sampled_from([None, "ACMT/MDOP/CHRG", "PMNT/MDOP/FEES", "PMNT/ICDT/ESCT"]),
    transfer_id=st.sampled_from([None, "T1", "T2"]),
    transfer_status=st.sampled_from([None, "ordered", "booked", "cancelled"]),
    transfer_amount_minor=st.one_of(st.none(), st.integers(1, 10**6)),
    transfer_creditor=st.sampled_from([None, "B1", "B2"]),
)


@given(st.lists(lines, max_size=12))
def test_bookings_book_only_what_the_bank_and_our_orders_prove(batch: list[FundsLine]) -> None:
    out = decide_bookings(batch)
    by_id = {x.id: x for x in batch}
    seen: set[str] = set()
    for b in out:
        line = by_id[b.line_id]
        if b.kind == "fee":
            assert (
                line.direction == "debit"
                and line.kind == "other_debit"
                and charge_code(line.bank_tx_code)
            )
        elif b.kind == "top_up":
            assert line.direction == "credit" and line.kind == "own_transfer_in"
            assert b.transfer_id == line.transfer_id and line.transfer_status == "ordered"
            assert line.transfer_amount_minor == line.amount_minor
            assert line.transfer_creditor == line.bank_account_id
            assert b.transfer_id is not None and b.transfer_id not in seen  # booked once
            seen.add(b.transfer_id)
        else:
            assert b.review_reason in {
                TOP_UP_NOT_FOUND,
                TOP_UP_DIFFERS,
                CLIENT_CREDIT,
                OWN_TRANSFER_OUT,
            }
    # nothing else is ever booked: a debtor's credit, a return, a credit as a fee
    assert all(by_id[b.line_id].kind != "client_transfer_in" or not b.booked for b in out)
