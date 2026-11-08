"""Manual CSV statements (M2-07): the documented column set, French dates and amounts (refused,
never rounded), label markers, preamble lines, and the round trip with the synthetic exports."""

from datetime import date, timedelta
from pathlib import Path

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from collectoo_worker.payments.csv_import import (
    CsvProfile,
    method_of,
    parse_csv,
    parse_fr_amount,
    parse_fr_date,
    parse_label,
)
from collectoo_worker.payments.statement import ParsedStatement, StatementRejected
from collectoo_worker.synth.camt053 import (
    Expected,
    expected_csv,
    expected_lines,
    generate_entries,
    make_doc,
    render_bank_csv,
)

IBAN = "FR7630004000031234567890143"
START = date(2026, 10, 1)


def _write(tmp_path: Path, text: str, encoding: str = "utf-8") -> Path:
    path = tmp_path / "releve.csv"
    path.write_bytes(text.encode(encoding))
    return path


def _parse(tmp_path: Path, text: str, profile: CsvProfile | None = None) -> ParsedStatement:
    return parse_csv(_write(tmp_path, text), currency="EUR", profile=profile)


def _refused(tmp_path: Path, text: str) -> StatementRejected:
    with pytest.raises(StatementRejected) as err:
        _parse(tmp_path, text)
    return err.value


@pytest.mark.parametrize(
    ("text", "minor"),
    [
        ("1 234,56", 123456),
        ("1\u00a0234,56", 123456),
        ("1\u202f234,56 €", 123456),
        ("1.234,56", 123456),
        ("-50,00", -5000),
        ("50,00-", -5000),
        ("+7,5", 750),
        ("12", 1200),
        ("0,10 EUR", 10),
        ("1.234", 123400),
        ("", None),
        ("  ", None),
    ],
)
def test_french_amounts(text: str, minor: int | None) -> None:
    assert parse_fr_amount(text) == minor


@pytest.mark.parametrize(
    "text", ["12,345", "1234.56", "1,2,3", "abc", "12,3a", "1 23,00", "--5,00"]
)
def test_amounts_a_french_reader_cannot_be_sure_of_are_refused(text: str) -> None:
    with pytest.raises(ValueError):
        parse_fr_amount(text)


def test_decimal_point_profile() -> None:
    assert parse_fr_amount("1,234.56", decimal=".") == 123456
    with pytest.raises(ValueError):
        parse_fr_amount("1.234,56", decimal=".")


@given(
    st.integers(min_value=-(10**13), max_value=10**13), st.sampled_from([" ", "\u00a0", ".", ""])
)
def test_french_amount_text_round_trips(minor: int, group: str) -> None:
    units, cents = divmod(abs(minor), 100)
    text = f"{'-' if minor < 0 else ''}{units:,}".replace(",", group) + f",{cents:02d}"
    assert parse_fr_amount(text) == minor


def test_french_dates() -> None:
    assert parse_fr_date("31/12/2026") == date(2026, 12, 31)
    assert parse_fr_date("01-02-2026") == date(2026, 2, 1)
    assert parse_fr_date("01.02.2026") == date(2026, 2, 1)
    assert parse_fr_date(" 2026-02-01 ") == date(2026, 2, 1)
    for bad in ("31/02/2026", "1/2/2026", "02/01/26", "2026/02/01", ""):
        with pytest.raises(ValueError):
            parse_fr_date(bad)


def test_labels_and_methods() -> None:
    label = parse_label("VIR SEPA RECU /DE MARTIN SAS /MOTIF REGLT  F-103 /REF RF18539007547034")
    assert (label.head, label.name, label.motif, label.reference) == (
        "VIR SEPA RECU",
        "MARTIN SAS",
        "REGLT F-103",
        "RF18539007547034",
    )
    assert label.text == "VIR SEPA RECU /DE MARTIN SAS /MOTIF REGLT F-103 /REF RF18539007547034"
    assert parse_label("FRAIS TENUE DE COMPTE").name is None
    assert [
        method_of(t) for t in ("VIR SEPA RECU", "PRLV SEPA", "REM CHQ 123", "CB CARREFOUR", "Frais")
    ] == ["sct", "sdd", "cheque", "card", "other"]


HEADER = "Date opération;Date de valeur;Libellé;Débit;Crédit;Référence opération"


def test_a_documented_csv_with_preamble_and_both_amount_columns(tmp_path: Path) -> None:
    text = "\n".join(
        [
            "Compte;FR76 3000 4000 0312 3456 7890 143",
            "Période;01/10/2026 au 02/10/2026",
            "",
            HEADER,
            "01/10/2026;01/10/2026;VIR SEPA RECU /DE MARTIN SAS /MOTIF REGLT"
            " /REF rf18 5390 0754 7034;;1 200,00;OP1",
            "01/10/2026;;PRLV SEPA FRAIS;12,90;;OP2",
            "02/10/2026;02/10/2026;RETOUR VIR SEPA /DE DUPONT /MOTIF RETOUR AC04"
            " /REF E2E-9;50,00;;OP3",
            "02/10/2026;;VIR SEPA RECU /DE X /MOTIF solde rejete par erreur;;0,00;OP4",
            "02/10/2026;;VIR SEPA EMIS /DE Y /REF RFD7Q2K9;80,00;;OP5",
        ]
    )
    parsed = _parse(tmp_path, text)
    got = [(x.line_no, x.direction, x.amount_minor, x.kind, x.dedup_key) for x in parsed.lines]
    assert got == [
        (1, "credit", 120000, "debtor_credit", "c:OP1"),
        (2, "debit", 1290, "other_debit", "c:OP2"),
        (3, "debit", 5000, "return", "c:OP3"),
        (4, "debit", 8000, "refund_out", "c:OP5"),
    ]
    assert parsed.skipped_not_booked == 1  # zero amount
    first = parsed.lines[0]
    assert (first.counterparty_name, first.creditor_reference, first.method) == (
        "MARTIN SAS",
        "RF18539007547034",
        "sct",
    )
    assert (first.value_date, parsed.lines[1].value_date) == (date(2026, 10, 1), None)
    assert parsed.lines[2].original_end_to_end_id == "E2E-9"
    assert parsed.header() == {
        "format": "csv",
        "line_count": 4,
        "skipped_not_booked": 1,
        "version": None,
        "sections": [],
    }


def test_a_preamble_line_without_separator_does_not_hide_the_header(tmp_path: Path) -> None:
    text = "Relevé de compte courant\nDate;Libellé;Montant\n01/10/2026;VIR A;1 000,00\n"
    (line,) = _parse(tmp_path, text).lines
    assert (line.amount_minor, line.remittance_text) == (100000, "VIR A")


def test_return_words_from_the_payer_do_not_make_a_return(tmp_path: Path) -> None:
    text = (
        "Date;Libellé;Montant\n01/10/2026;VIR SEPA RECU /DE A /MOTIF retour de marchandise;10,00\n"
    )
    assert _parse(tmp_path, text).lines[0].kind == "debtor_credit"


def test_a_plain_reference_column_is_not_a_bank_id(tmp_path: Path) -> None:
    """A payer's reference repeats across payments: it must not hide one as already imported."""
    text = (
        "Date;Libellé;Montant;Référence\n01/10/2026;VIR A;10,00;FA-1\n01/10/2026;VIR B;10,00;FA-1\n"
    )
    keys = [x.dedup_key for x in _parse(tmp_path, text).lines]
    assert all(k.startswith("h:") for k in keys) and len(set(keys)) == 2


def test_signed_amount_column_windows_1252_and_profile(tmp_path: Path) -> None:
    text = "Date compta;Intitulé;Somme\r\n01/10/2026;VIR SEPA RECU /DE CRÉPERIE;-1.234,50\r\n"
    path = tmp_path / "export.csv"
    path.write_bytes(text.encode("cp1252"))
    profile = CsvProfile.from_json({"columns": {"booking_date": "Date compta", "amount": "Somme"}})
    parsed = parse_csv(path, currency="EUR", profile=profile)
    (line,) = parsed.lines
    assert (line.direction, line.amount_minor, line.counterparty_name) == (
        "debit",
        123450,
        "CRÉPERIE",
    )
    with pytest.raises(StatementRejected):
        CsvProfile.from_json({"columns": {"nope": "X"}})
    with pytest.raises(StatementRejected):
        CsvProfile.from_json({"decimal": ";"})


@pytest.mark.parametrize(
    ("text", "code", "detail"),
    [
        ("", "csv_empty", ""),
        ("Date;Libellé\n01/10/2026;VIR\n", "csv_header", "amount"),
        ("Date;Libellé;Débit\n", "csv_header", "amount"),
        ("Date;Libellé;Montant;Montant EUR\n", "csv_header", "two columns"),
        ("Date;Libellé;Montant\n", "csv_empty", ""),
        ("Date;Libellé;Montant\n01/10/2026;VIR;12,345\n", "csv_row", "line 2"),
        ("Date;Libellé;Montant\n31/02/2026;VIR;12,34\n", "csv_row", "line 2"),
        ("Date;Libellé;Montant\n;VIR;12,34\n", "csv_row", "booking date"),
        ("Date;Libellé;Débit;Crédit\n01/10/2026;VIR;1,00;2,00\n", "csv_row", "both"),
        ("Date;Libellé;Montant;Devise\n01/10/2026;VIR;1,00;USD\n", "wrong_currency", ""),
        (
            "Date;Libellé;Montant;Référence opération\n01/10/2026;A;1,00;X\n01/10/2026;B;2,00;X\n",
            "duplicate_reference_in_file",
            "",
        ),
    ],
)
def test_files_that_cannot_be_read_exactly_are_refused(
    tmp_path: Path, text: str, code: str, detail: str
) -> None:
    err = _refused(tmp_path, text)
    assert err.code == code and detail in err.detail


def _synthetic(lines: int, seed: int) -> list[Expected]:
    entries = generate_entries(lines, seed=seed, start=START, days=3, payers=30)
    doc = make_doc(entries, iban=IBAN, from_date=START, to_date=START + timedelta(days=2))
    return expected_lines(doc)


@pytest.mark.parametrize(("signed", "bank_ids"), [(False, True), (True, False)])
def test_the_synthetic_export_is_read_line_for_line(
    tmp_path: Path, signed: bool, bank_ids: bool
) -> None:
    lines = _synthetic(400, seed=5)
    path = tmp_path / "export.csv"
    path.write_bytes(render_bank_csv(lines, signed=signed, bank_ids=bank_ids))
    parsed = parse_csv(path, currency="EUR", today=date(2026, 11, 8))
    expected = expected_csv(lines, bank_ids=bank_ids)
    assert len(parsed.lines) == len(expected)
    for got, want in zip(parsed.lines, expected, strict=True):
        assert (got.direction, got.amount_minor, got.booking_date, got.value_date, got.kind) == (
            want.direction,
            want.amount_minor,
            want.booking_date,
            want.value_date,
            want.kind,
        )
        assert (
            got.dedup_key[0],
            got.creditor_reference,
            got.end_to_end_id,
            got.remittance_text,
        ) == (want.key_prefix, want.creditor_reference, want.end_to_end_id, want.remittance_text)
        assert got.counterparty_name == want.counterparty_name


@settings(
    max_examples=25, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture]
)
@given(
    seed=st.integers(min_value=0, max_value=10**6),
    lines=st.integers(min_value=1, max_value=50),
    signed=st.booleans(),
)
def test_round_trip_generate_render_parse_keeps_every_amount(
    tmp_path: Path, seed: int, lines: int, signed: bool
) -> None:
    expected = _synthetic(lines, seed)
    path = tmp_path / "export.csv"
    path.write_bytes(render_bank_csv(expected, seed=seed, signed=signed))
    parsed = parse_csv(path, currency="EUR")
    assert [(x.direction, x.amount_minor, x.booking_date) for x in parsed.lines] == [
        (x.direction, x.amount_minor, x.booking_date) for x in expected
    ]
