"""CSV statements that must be refused, or read one documented way, never guessed (M2b-2 review):
returns only from the bank's operation type, the encoding of the whole file, quotes and row shapes,
negative credits, the booking-date aliases of one export, size caps and the line numbers of
refusals. Every refusal is a `StatementRejected` with a stable code, never a crash."""

import codecs
from datetime import date, timedelta
from pathlib import Path

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from collectoo_worker.payments import csv_import
from collectoo_worker.payments.csv_import import parse_csv
from collectoo_worker.payments.statement import ParsedStatement, StatementRejected
from collectoo_worker.synth.camt053 import (
    expected_lines,
    generate_entries,
    make_doc,
    render_bank_csv,
)

START = date(2026, 10, 1)


def _write(tmp_path: Path, data: bytes) -> Path:
    path = tmp_path / "releve.csv"
    path.write_bytes(data)
    return path


def _parse(tmp_path: Path, data: bytes | str, today: date | None = None) -> ParsedStatement:
    raw = data.encode("utf-8") if isinstance(data, str) else data
    return parse_csv(_write(tmp_path, raw), currency="EUR", today=today)


def _refused(tmp_path: Path, data: bytes | str, today: date | None = None) -> StatementRejected:
    with pytest.raises(StatementRejected) as err:
        _parse(tmp_path, data, today)
    return err.value


# -- returns: only the bank's operation type at the start of the label (finding 3) ---------------


@pytest.mark.parametrize(
    "label",
    [
        "VIR RECU 1234567 DE: DUPONT JEAN MOTIF: REGLEMENT IMPAYE F-103",
        "VIR SEPA DUPONT JEAN REGLT IMPAYE DOSSIER 12",
        "VIR SEPA RECU REGLEMENT IMPAYE /DE DUPONT /MOTIF F-103",
        "IMPAYE FACTURE 12 DUPONT",
        "ANNULATION DE MA DETTE DOSSIER 12",
        "VIR INST RECU DUPONT REJET DU PLAN",
    ],
)
def test_a_payers_words_never_make_a_credit_a_return(tmp_path: Path, label: str) -> None:
    (line,) = _parse(tmp_path, f"Date;Libellé;Montant\n02/11/2026;{label};150,00\n").lines
    assert (line.direction, line.kind) == ("credit", "debtor_credit")


@pytest.mark.parametrize(
    "label",
    [
        "RETOUR VIR SEPA /DE DUPONT /MOTIF AC04",
        "RETOUR VIR SEPA DUPONT AC04",
        "REJET PRLV SEPA MD06 FRAIS",
        "Rejet de prélèvement SEPA",
        "RETOUR DE VIREMENT DUPONT",
        "PRLV SEPA REJETE DUPONT",
        "VIR SEPA RETOUR /DE X",
        "IMPAYE CHQ 1234567",
        "ANNULATION CB 12/10 BOUTIQUE",
    ],
)
@pytest.mark.parametrize("amount", ["50,00", "-50,00"])
def test_the_banks_operation_type_at_the_start_of_the_label_makes_a_return(
    tmp_path: Path, label: str, amount: str
) -> None:
    (line,) = _parse(tmp_path, f"Date;Libellé;Montant\n02/11/2026;{label};{amount}\n").lines
    assert line.kind == "return"


# -- encoding: the whole file, UTF-8 (optional BOM) or Windows-1252 (findings 6 and 11) ----------


def _ascii_rows(n_bytes: int) -> bytes:
    rows, size, i = [], 0, 0
    while size < n_bytes:
        row = f"01/10/2026;VIR SEPA RECU /DE A /MOTIF FACTURE {i};1,00\r\n".encode("ascii")
        rows.append(row)
        size += len(row)
        i += 1
    return b"".join(rows)


def test_a_windows_1252_byte_after_the_first_256_kib_is_read_as_windows_1252(
    tmp_path: Path,
) -> None:
    data = b"Date;Libelle;Montant\r\n" + _ascii_rows(300 * 1024)
    data += "02/10/2026;FRAIS PRÉLÈVEMENT;-1,50\r\n".encode("cp1252")
    parsed = _parse(tmp_path, data)
    assert parsed.lines[-1].remittance_text == "FRAIS PRÉLÈVEMENT"
    assert (parsed.lines[-1].direction, parsed.lines[-1].amount_minor) == ("debit", 150)


def test_utf8_with_a_bom_is_read_as_utf8(tmp_path: Path) -> None:
    data = codecs.BOM_UTF8 + "Date;Libellé;Montant\n01/10/2026;VIR CRÉPERIE €;1,00\n".encode()
    (line,) = _parse(tmp_path, data).lines
    assert line.remittance_text == "VIR CRÉPERIE €"


def test_a_late_utf8_character_in_an_ascii_file_is_read_as_utf8(tmp_path: Path) -> None:
    data = b"Date;Libelle;Montant\n" + _ascii_rows(300 * 1024)
    data += "02/10/2026;VIR CRÉPERIE;2,00\n".encode()
    assert _parse(tmp_path, data).lines[-1].remittance_text == "VIR CRÉPERIE"


@pytest.mark.parametrize(
    ("data", "detail"),
    [
        # says UTF-8 (BOM), then a Windows-1252 byte on line 3
        (
            codecs.BOM_UTF8 + b"Date;Libelle;Montant\n01/10/2026;A;1,00\n02/10/2026;CR\xc9;1,00\n",
            "line 3",
        ),
        # neither UTF-8 nor Windows-1252 (0x81 is unassigned in Windows-1252) on line 2
        (b"Date;Libelle;Montant\r\n01/10/2026;A\x81\xe9;1,00\r\n", "line 2"),
        # UTF-16 exports (Excel « texte Unicode »)
        ("Date;Libellé;Montant\n01/10/2026;A;1,00\n".encode("utf-16"), "UTF-16"),
        ("Date;Libellé;Montant\n01/10/2026;A;1,00\n".encode("utf-16-le"), "line 1"),
    ],
)
def test_a_file_that_is_not_utf8_or_windows_1252_is_refused(
    tmp_path: Path, data: bytes, detail: str
) -> None:
    err = _refused(tmp_path, data)
    assert err.code == "csv_encoding" and detail in err.detail, err


def test_a_field_over_the_csv_field_limit_is_a_refused_row_not_a_crash(tmp_path: Path) -> None:
    text = f"Date;Libellé;Montant\n01/10/2026;A;1,00\n02/10/2026;{'X' * 200_000};1,00\n"
    err = _refused(tmp_path, text)
    assert (err.code, err.detail.split(":")[0]) == ("csv_row", "line 3"), err


def test_a_malformed_csv_profile_is_refused_not_a_crash() -> None:
    for data in ({"columns": ["Date"]}, {"columns": 3}, {"decimal": 1}):
        with pytest.raises(StatementRejected) as err:
            csv_import.CsvProfile.from_json(data)
        assert err.value.code == "csv_profile_invalid"


# -- negative credits (finding 8) ------------------------------------------------------------------


def test_a_negative_amount_in_the_credit_column_is_refused(tmp_path: Path) -> None:
    err = _refused(tmp_path, "Date;Libellé;Débit;Crédit\n02/11/2026;ANNUL VIR;;-50,00\n")
    assert (err.code, err.detail.split(":")[0]) == ("csv_row", "line 2"), err
    assert "credit" in err.detail


def test_a_debit_printed_negative_or_positive_is_a_debit(tmp_path: Path) -> None:
    text = "Date;Libellé;Débit;Crédit\n02/11/2026;FRAIS;-12,90;\n02/11/2026;FRAIS 2;12,90;\n"
    assert [(x.direction, x.amount_minor) for x in _parse(tmp_path, text).lines] == [
        ("debit", 1290),
        ("debit", 1290),
    ]


# -- quotes and the shape of rows (findings 9 and 12) ---------------------------------------------


@pytest.mark.parametrize(
    ("text", "line"),
    [
        # the quote opens in a middle column and would swallow every later row
        (
            "Date;Tiers;Libellé;Montant\n01/10/2026;LEROY;VIR;100,00\n"
            '01/10/2026;"DUPONT & FILS;VIR;150,00\n01/10/2026;MARTIN;VIR;200,00\n'
            "01/10/2026;DURAND;VIR;300,00\n",
            3,
        ),
        # the label is the last column: the row stays full length, its label takes the next rows
        (
            'Date;Montant;Libellé\n01/10/2026;10,00;"VIR A\n02/10/2026;5,00;VIR B\n'
            "03/10/2026;7,00;VIR C\n",
            2,
        ),
        # CRLF, a preamble and a blank line: the line is still the file's
        (
            'Compte 123\r\n\r\nDate;Libellé;Montant\r\n01/10/2026;"CHEQUE N 123 "REMISE;10,00\r\n'
            '01/10/2026;"VIR RECU DUPONT;5,00\r\n03/10/2026;VIR;7,00\r\n',
            5,
        ),
        # the last row's quote is never closed and the file has no final line break
        ('Date;Libellé;Montant\n01/10/2026;VIR A;1,00\n02/10/2026;"VIR B;5,00', 3),
    ],
)
def test_an_unclosed_quote_refuses_the_file_at_its_line(
    tmp_path: Path, text: str, line: int
) -> None:
    err = _refused(tmp_path, text)
    assert (err.code, err.detail.split(":")[0]) == ("csv_row", f"line {line}"), err


def test_a_quote_inside_a_field_is_still_read(tmp_path: Path) -> None:
    text = 'Date;Libellé;Montant\n01/10/2026;"CHEQUE N 123 "REMISE;10,00\n02/10/2026;VIR;5,00\n'
    lines = _parse(tmp_path, text).lines
    assert [(x.remittance_text, x.amount_minor) for x in lines] == [
        ("CHEQUE N 123 REMISE", 1000),
        ("VIR", 500),
    ]


def test_a_quoted_label_with_the_separator_is_read(tmp_path: Path) -> None:
    text = 'Date;Libellé;Montant\n01/10/2026;"VIR A; B";10,00\n'
    (line,) = _parse(tmp_path, text).lines
    assert (line.remittance_text, line.amount_minor) == ("VIR A; B", 1000)


@pytest.mark.parametrize(
    ("text", "line"),
    [
        # an unquoted separator in the label moves the amounts one column right
        ("Date;Libellé;Débit;Crédit\n01/10/2026;VIR 12;5;;10,00\n", 2),
        # a row too short to hold the amount columns
        ("Date;Libellé;Débit;Crédit\n01/10/2026;VIR;1,00;\n01/10/2026;VIR\n", 3),
    ],
)
def test_a_row_that_does_not_fit_the_header_is_refused(
    tmp_path: Path, text: str, line: int
) -> None:
    err = _refused(tmp_path, text)
    assert (err.code, err.detail.split(":")[0]) == ("csv_row", f"line {line}"), err
    assert "cells" in err.detail


def test_empty_trailing_cells_and_missing_optional_cells_are_read(tmp_path: Path) -> None:
    text = (
        "Date;Libellé;Montant;Référence opération\n01/10/2026;VIR A;1,00;OP1;;\n"
        "01/10/2026;VIR B;2,00\n"
    )
    lines = _parse(tmp_path, text).lines
    assert [(x.amount_minor, x.dedup_key[:2]) for x in lines] == [(100, "c:"), (200, "h:")]


# -- the BPCE layout: two booking-date headers (finding 10) ---------------------------------------

BPCE = (
    "Date de comptabilisation;Libelle simplifie;Libelle operation;Reference;"
    "Informations complementaires;Type operation;Categorie;Sous categorie;Debit;Credit;"
    "Date operation;Date de valeur;Pointage operation"
)


def test_the_bpce_layout_reads_the_booking_date_from_date_de_comptabilisation(
    tmp_path: Path,
) -> None:
    text = (
        f"{BPCE}\n"
        "03/11/2026;VIR DUPONT;VIR SEPA RECU /DE DUPONT /MOTIF F-103;REF1;;Virement;;;"
        ";150,00;31/10/2026;03/11/2026;0\n"
    )
    (line,) = _parse(tmp_path, text).lines
    assert (line.booking_date, line.value_date, line.amount_minor, line.kind) == (
        date(2026, 11, 3),
        date(2026, 11, 3),
        15000,
        "debtor_credit",
    )
    assert line.remittance_text == "VIR SEPA RECU /DE DUPONT /MOTIF F-103"


@pytest.mark.parametrize(
    "header",
    [
        "Date;Date opération;Libellé;Montant",
        "Date comptable;Date de comptabilisation;Libellé;Montant",
    ],
)
def test_two_booking_date_headers_of_the_same_rank_are_refused(tmp_path: Path, header: str) -> None:
    err = _refused(tmp_path, f"{header}\n01/10/2026;02/10/2026;VIR;1,00\n")
    assert (err.code, "two columns for booking_date" in err.detail) == ("csv_header", True), err


# -- size caps (finding 13) ------------------------------------------------------------------------


def test_a_csv_over_the_byte_cap_is_refused_before_it_is_read(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(csv_import, "MAX_BYTES", 1000)
    data = b"Date;Libelle;Montant\n" + _ascii_rows(2000)
    err = _refused(tmp_path, data)
    assert err.code == "file_too_large" and "bytes" in err.detail, err


def test_a_csv_over_the_line_cap_is_refused_before_it_is_read(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(csv_import, "MAX_LINES", 50)
    data = b"Date;Libelle;Montant\n" + _ascii_rows(60 * 45)
    calls: list[int] = []
    monkeypatch.setattr(csv_import, "_line", lambda *a: calls.append(1))
    err = _refused(tmp_path, data)
    assert err.code == "file_too_large" and "lines" in err.detail, err
    assert calls == []  # nothing parsed


def test_the_caps_are_well_above_the_100k_line_target() -> None:
    assert csv_import.MAX_LINES >= 250_000
    assert csv_import.MAX_BYTES >= 64 * 1024 * 1024


# -- one line numbering: the file's line, header and preamble included (finding 16) ---------------


def test_refusals_and_lines_carry_the_files_line_number(tmp_path: Path) -> None:
    text = (
        "Compte;123\n"  # 1
        "Période;octobre\n"  # 2
        "\n"  # 3
        "Date;Libellé;Montant\n"  # 4
        "01/10/2026;VIR A;0,00\n"  # 5: information line
        "01/10/2026;VIR B;1,00\n"  # 6
        "\n"  # 7
        "20/12/2026;VIR C;2,00\n"  # 8: after today
    )
    err = _refused(tmp_path, text, today=date(2026, 11, 8))
    assert (err.code, err.detail.split(" is ")[0]) == ("future_booking_date", "line 8"), err
    parsed = _parse(tmp_path, text, today=date(2026, 12, 31))
    assert [x.line_no for x in parsed.lines] == [6, 8]


def test_lone_carriage_returns_count_as_lines(tmp_path: Path) -> None:
    text = "Date;Libellé;Montant\r01/10/2026;VIR A;1,00\r02/10/2026;VIR B;12,345\r"
    err = _refused(tmp_path, text)
    assert (err.code, err.detail.split(":")[0]) == ("csv_row", "line 3"), err


@pytest.mark.parametrize(
    ("text", "code", "line"),
    [
        (
            "Date;Libellé;Montant;Devise\n01/10/2026;A;1,00;EUR\n01/10/2026;B;1,00;USD\n",
            "wrong_currency",
            3,
        ),
        (
            "Date;Libellé;Montant;Référence opération\n"
            "01/10/2026;A;1,00;X\n\n01/10/2026;B;2,00;X\n",
            "duplicate_reference_in_file",
            4,
        ),
    ],
)
def test_other_refusals_of_a_row_name_its_line(
    tmp_path: Path, text: str, code: str, line: int
) -> None:
    err = _refused(tmp_path, text)
    assert (err.code, err.detail.split(":")[0]) == (code, f"line {line}"), err


# -- properties over the synthetic exports ---------------------------------------------------------


def _export(lines: int, seed: int, signed: bool) -> bytes:
    entries = generate_entries(lines, seed=seed, start=START, days=3, payers=30)
    doc = make_doc(
        entries,
        iban="FR7630004000031234567890143",
        from_date=START,
        to_date=START + timedelta(days=2),
    )
    return render_bank_csv(expected_lines(doc), seed=seed, signed=signed)


@settings(
    max_examples=40, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture]
)
@given(
    seed=st.integers(min_value=0, max_value=10**6),
    lines=st.integers(min_value=2, max_value=30),
    signed=st.booleans(),
    data=st.data(),
)
def test_an_unclosed_quote_anywhere_refuses_at_its_line_or_loses_nothing(
    tmp_path: Path, seed: int, lines: int, signed: bool, data: st.DataObject
) -> None:
    """A quote opened at the start of any cell of any row: the file is refused at that row's line,
    or (a quote in the last cell of the last row) read with the same money; never rows lost."""
    raw = _export(lines, seed, signed)
    want = parse_csv(_write(tmp_path, raw), currency="EUR")
    assert [x.line_no for x in want.lines] == list(range(2, len(want.lines) + 2))
    rows = raw.split(b"\r\n")
    target = data.draw(st.integers(min_value=1, max_value=len(want.lines)), label="row")
    cells = rows[target].split(b";")
    col = data.draw(st.integers(min_value=0, max_value=len(cells) - 1), label="cell")
    cells[col] = b'"' + cells[col]
    rows[target] = b";".join(cells)
    try:
        got = parse_csv(_write(tmp_path, b"\r\n".join(rows)), currency="EUR")
    except StatementRejected as err:
        assert (err.code, err.detail.split(":")[0]) == ("csv_row", f"line {target + 1}"), err
        return
    money = [(x.direction, x.amount_minor, x.booking_date, x.line_no) for x in got.lines]
    assert money == [(x.direction, x.amount_minor, x.booking_date, x.line_no) for x in want.lines]
