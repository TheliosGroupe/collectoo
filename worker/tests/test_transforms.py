"""M1-11 transformations and M1-12 validators/normalisers: unit and property-based tests."""

import datetime as dt
import random
from decimal import Decimal

import polars as pl
import pytest
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.boarding.targets import registry
from collectoo_worker.boarding.transforms import (
    TransformError,
    apply_chain,
    check,
    e164,
    load_spec,
    lookup,
    parse_date,
    parse_decimal,
    to_minor,
    transform_column,
)
from collectoo_worker.synth.ids import iban_fr, siren, siret

dates = st.dates(min_value=dt.date(1900, 1, 1), max_value=dt.date(2099, 12, 31))


@given(dates)
def test_dates_round_trip_in_every_supported_format(d: dt.date) -> None:
    for fmt in ("%d/%m/%Y", "%Y-%m-%d", "%d.%m.%Y"):
        assert parse_date("auto")(d.strftime(fmt)) == d


@pytest.mark.parametrize(
    ("value", "code"),
    [("31/02/2026", "impossible_date"), ("2026-13-01", "impossible_date"), ("demain", "bad_date")],
)
def test_bad_dates_are_errors_not_guesses(value: str, code: str) -> None:
    with pytest.raises(TransformError) as err:
        parse_date("auto")(value)
    assert err.value.code == code


def test_a_restricted_format_rejects_other_formats() -> None:
    with pytest.raises(TransformError):
        parse_date(["date_fr"])("2026-03-01")


def _fr(amount: Decimal, thousands: str) -> str:
    units, cents = f"{abs(amount):.2f}".split(".")
    grouped = f"{int(units):,}".replace(",", thousands)
    return f"{'-' if amount < 0 else ''}{grouped},{cents}"


@given(st.decimals(min_value=Decimal("-10000000"), max_value=Decimal("10000000"), places=2))
def test_amounts_in_any_french_or_english_style_convert_to_exact_cents(amount: Decimal) -> None:
    expected = int(amount * 100)
    styles = [
        (_fr(amount, "\u00a0"), ","),  # 1 234,56 (no-break space)
        (_fr(amount, "\u202f"), ","),  # 1 234,56 (narrow no-break space)
        (_fr(amount, "."), ","),  # 1.234,56
        (f"{amount:.2f}", "."),  # 1234.56
        (f"{amount:,.2f}", "."),  # 1,234.56
    ]
    for text, mark in styles:
        assert to_minor()(parse_decimal(mark)(text)) == expected, text
        assert to_minor()(parse_decimal("auto")(text)) == expected, text


def test_minor_units_round_half_up() -> None:
    assert to_minor()(Decimal("10.005")) == 1001
    assert to_minor()(Decimal("-10.005")) == -1001
    assert to_minor()(Decimal("10.004")) == 1000


def test_not_an_amount() -> None:
    with pytest.raises(TransformError) as err:
        parse_decimal(",")("12,5O")
    assert err.value.code == "bad_amount"


@given(st.integers())
def test_identifier_checks_accept_valid_and_reject_mutated(seed: int) -> None:
    rng = random.Random(seed)
    for kind, value in (("siren", siren(rng)), ("siret", siret(rng)), ("iban", iban_fr(rng))):
        assert check(kind)(value) == value
        last = value[-1]
        mutated = value[:-1] + str((int(last) + 1) % 10)
        with pytest.raises(TransformError):
            check(kind)(mutated)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("01 23 45 67 89", "+33123456789"),
        ("06.12.34.56.78", "+33612345678"),
        ("+33 6 12 34 56 78", "+33612345678"),
    ],
)
def test_phones_normalise_to_e164(raw: str, expected: str) -> None:
    assert e164("FR")(raw) == expected


def test_invalid_phone_and_email() -> None:
    with pytest.raises(TransformError):
        e164("FR")("12")
    with pytest.raises(TransformError):
        check("email")("jean.dupont@")


def test_lookup_maps_document_kinds() -> None:
    assert lookup("document_kind")("avoir") == "credit_note"
    with pytest.raises(TransformError):
        lookup("document_kind")("BON DE LIVRAISON")


def test_every_operational_target_has_a_chain() -> None:
    spec = load_spec()
    for t in registry():
        assert spec.chain_for(t.id), t.id
    assert apply_chain(spec.chain_for("claim_item.amount"), "1 234,56") == (123456, None)
    assert apply_chain(spec.chain_for("claim_item.currency"), "  ") == (None, None)
    assert apply_chain(spec.chain_for("contact.postcode"), "6000")[0] == "06000"


def test_transform_column_reports_errors_by_row() -> None:
    chain = load_spec().chain_for("claim_item.due_date")
    values, errors = transform_column(
        pl.Series(["05/03/2026", None, "31/02/2026", "05/03/2026"]), chain
    )
    assert values == [dt.date(2026, 3, 5), None, None, dt.date(2026, 3, 5)]
    assert list(errors) == [2] and errors[2].code == "impossible_date"
