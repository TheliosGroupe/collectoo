"""RF creditor references (M2-06, ISO 11649): generation, validation and their error detection.

97 is prime and divides neither d·10^k (one digit changed by d) nor (a - b)·(10^x - 10^y) for
|x - y| < 96 (two digits swapped; 10 has order 96 modulo 97), so every single substitution and
every transposition inside a reference is detected.
"""

import pytest
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.payments.rf import (
    ISSUED_RE,
    iban_valid,
    mod97,
    random_body,
    rf_format,
    rf_make,
    rf_normalise,
    rf_valid,
)

ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
bodies = st.text(alphabet=ALNUM, min_size=1, max_size=21)
digit_bodies = st.text(alphabet="0123456789", min_size=12, max_size=12)


def test_iso_vector_and_the_design_examples() -> None:
    assert rf_valid("RF18539007547034")
    assert rf_make("539007547034") == "RF18539007547034"
    assert rf_valid("RF60482193057612")  # docs/design/m2b-payments.md §8.2
    assert rf_valid("RF72730261884529")
    assert rf_format("RF18539007547034") == "RF18 5390 0754 7034"


@given(bodies)
def test_a_made_reference_validates(body: str) -> None:
    ref = rf_make(body)
    assert rf_valid(ref)
    assert 2 <= int(ref[2:4]) <= 98
    assert ref[4:] == body


@given(digit_bodies, st.data())
def test_every_single_substitution_is_rejected(body: str, data: st.DataObject) -> None:
    ref = rf_make(body)
    for i in range(2, len(ref)):  # check digits and body
        for c in "0123456789":
            if c != ref[i]:
                assert not rf_valid(ref[:i] + c + ref[i + 1 :]), (ref, i, c)


@given(digit_bodies)
def test_every_adjacent_transposition_is_rejected(body: str) -> None:
    ref = rf_make(body)
    for i in range(2, len(ref) - 1):
        if ref[i] != ref[i + 1]:
            swapped = ref[:i] + ref[i + 1] + ref[i] + ref[i + 2 :]
            assert not rf_valid(swapped), (ref, i)


@given(digit_bodies)
def test_check_digits_outside_02_98_are_refused(body: str) -> None:
    assert rf_valid(rf_make(body))
    # 98 ≡ 1 (mod 97): "RF01" would pass the arithmetic with the same body as "RF98".
    for cd in ("00", "01", "99"):
        assert not rf_valid(f"RF{cd}{body}")


@given(digit_bodies)
def test_printed_and_typed_forms_normalise_back(body: str) -> None:
    ref = rf_make(body)
    assert rf_normalise(rf_format(ref)) == ref
    assert rf_normalise(rf_format(ref).lower().replace(" ", "\n ")) == ref
    assert not rf_valid(rf_format(ref))  # validation takes the normalised form


def test_malformed_references_are_invalid() -> None:
    for ref in (
        None,
        "",
        "RF",
        "RF18",
        "rf18539007547034",
        "XX18539007547034",
        "RF185390075470341234567890",
        "RF18 539007547034",
        "RF1853900754703é",
    ):
        assert not rf_valid(ref), ref


def test_issued_references_are_rf_and_14_digits() -> None:
    refs = {rf_make(random_body()) for _ in range(2000)}
    assert all(ISSUED_RE.fullmatch(r) and rf_valid(r) for r in refs)
    assert len(refs) > 1990  # random, not a sequence


def test_mod97_takes_alphanumerics_only() -> None:
    assert mod97("RF") == 2715 % 97
    with pytest.raises(ValueError, match="0-9 and A-Z"):
        mod97("rf")
    with pytest.raises(ValueError, match="0-9 and A-Z"):
        rf_make("12 34")


def test_ibans() -> None:
    assert iban_valid("FR3430001007940000000001001")
    assert iban_valid("FR1420041010050500013M02606")
    assert not iban_valid("FR3430001007940000000001002")
    assert not iban_valid("FR34 3000 1007 9400 0000 0001 001")
    assert not iban_valid("FR0130001007940000000001001")
    assert not iban_valid(None)
