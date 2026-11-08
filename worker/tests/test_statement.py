"""Bank statement rules shared by the camt.053 and CSV readers (M2-07): exact amounts, kinds of
lines, dedup keys, the bank's balance proof. Amounts are refused, never rounded."""

from datetime import date

import pytest
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.payments.statement import (
    MAX_MINOR,
    DedupKeys,
    Section,
    StatementLine,
    StatementRejected,
    check_balanced,
    check_dates,
    classify,
    iso_to_minor,
    minor_to_iso,
)

minors = st.integers(min_value=0, max_value=MAX_MINOR)
exponents = st.sampled_from((0, 2, 3))


@pytest.mark.parametrize(
    ("text", "exponent", "minor"),
    [
        ("0.01", 2, 1),
        ("1234.5", 2, 123450),
        ("1234.50", 2, 123450),
        ("1234.50000", 2, 123450),  # zeros beyond the exponent change nothing
        ("12", 2, 1200),
        ("0012.30", 2, 1230),
        ("12", 0, 12),
        ("1.234", 3, 1234),
        ("10000000000000.00", 2, MAX_MINOR),
    ],
)
def test_iso_amounts_become_exact_minor_units(text: str, exponent: int, minor: int) -> None:
    assert iso_to_minor(text, exponent) == minor


@pytest.mark.parametrize(
    "text",
    [
        "1.234",
        "0.001",
        "-1.00",
        "+1.00",
        "1e3",
        "1,00",
        "",
        " ",
        "1.",
        ".5",
        "1.123456",
        "1 000.00",
        "10000000000000.01",
        "NaN",
    ],
)
def test_amounts_that_are_not_exact_iso_amounts_are_refused(text: str) -> None:
    with pytest.raises(ValueError):
        iso_to_minor(text, 2)


@given(minors, exponents)
def test_minor_units_round_trip_through_iso_text(minor: int, exponent: int) -> None:
    assert iso_to_minor(minor_to_iso(minor, exponent), exponent) == minor


@given(st.integers(min_value=0, max_value=10**12), st.integers(min_value=1, max_value=9))
def test_a_non_zero_digit_beyond_the_exponent_is_refused(minor: int, digit: int) -> None:
    with pytest.raises(ValueError):
        iso_to_minor(f"{minor_to_iso(minor, 2)}{digit}", 2)


def test_iso_text_carries_no_sign() -> None:
    with pytest.raises(ValueError):
        minor_to_iso(-1, 2)


@pytest.mark.parametrize(
    ("direction", "reversal", "reason", "sub_family", "e2e", "kind"),
    [
        ("credit", False, None, "ESCT", "E2E1", "debtor_credit"),
        ("credit", True, None, "ESCT", None, "return"),  # a debit taken back is no payment
        ("credit", False, "AC04", None, None, "return"),
        ("debit", False, "MD06", None, None, "return"),
        ("debit", False, None, "UPDD", None, "return"),
        ("debit", False, None, "RRTN", None, "return"),
        ("debit", False, None, "ESCT", "RFD7Q2K9", "refund_out"),
        ("debit", False, None, "FEES", None, "other_debit"),
        ("debit", False, None, "ESCT", "E2E-RFD", "other_debit"),
    ],
)
def test_lines_are_classified(  # noqa: PLR0913, PLR0917 - one parameter per column of the table
    direction: str,
    reversal: bool,
    reason: str | None,
    sub_family: str | None,
    e2e: str | None,
    kind: str,
) -> None:
    got = classify(
        direction, reversal=reversal, return_reason=reason, sub_family=sub_family, end_to_end_id=e2e
    )
    assert got == kind


def _fp(keys: DedupKeys, amount: int = 5000, text: str | None = "COTISATION") -> str:
    return keys.fingerprint(
        booking_date=date(2026, 10, 1),
        value_date=None,
        direction="credit",
        amount_minor=amount,
        currency="EUR",
        counterparty_iban="FR7630004000031234567890143",
        end_to_end_id=None,
        remittance_text=text,
    )


def test_identical_lines_without_reference_stay_two_lines() -> None:
    keys = DedupKeys()
    first, second = _fp(keys), _fp(keys)
    assert first.startswith("h:") and first.endswith("#1") and second.endswith("#2")
    assert first[:-2] == second[:-2]
    # the same facts in another file give the same keys (a re-import is recognised)
    again = DedupKeys()
    assert (_fp(again), _fp(again)) == (first, second)
    # the label is compared without case or spacing
    assert _fp(DedupKeys(), text="  cotisation ") == first
    assert _fp(DedupKeys(), amount=5001) != first


def test_a_bank_reference_used_twice_in_a_file_refuses_it() -> None:
    keys = DedupKeys()
    keys.claim("t:REF1")
    with pytest.raises(StatementRejected) as err:
        keys.claim("t:REF1")
    assert err.value.code == "duplicate_reference_in_file"
    with pytest.raises(StatementRejected) as err:
        keys.claim("t:" + "X" * 300)
    assert err.value.code == "line_invalid"


def _line(no: int, direction: str, amount: int, booked: date = date(2026, 10, 1)) -> StatementLine:
    return StatementLine(
        line_no=no,
        section_no=1,
        dedup_key=f"t:{no}",
        direction=direction,
        amount_minor=amount,
        currency="EUR",
        booking_date=booked,
        value_date=None,
        kind="debtor_credit" if direction == "credit" else "other_debit",
        method="sct",
    )


def test_the_bank_balance_proof() -> None:
    lines = [_line(1, "credit", 10000), _line(2, "debit", 2500)]
    section = Section("S1", 1, None, "EUR", date(2026, 10, 1), date(2026, 10, 1), -500, 7000)
    check_balanced(section, lines, 1)
    off = Section("S1", 1, None, "EUR", date(2026, 10, 1), date(2026, 10, 1), -500, 7001)
    with pytest.raises(StatementRejected) as err:
        check_balanced(off, lines, 1)
    assert err.value.code == "unbalanced"


def test_a_line_booked_after_today_is_refused() -> None:
    check_dates([_line(1, "credit", 1, date(2026, 10, 2))], date(2026, 10, 2))
    with pytest.raises(StatementRejected) as err:
        check_dates([_line(1, "credit", 1, date(2026, 10, 3))], date(2026, 10, 2))
    assert err.value.code == "future_booking_date"
