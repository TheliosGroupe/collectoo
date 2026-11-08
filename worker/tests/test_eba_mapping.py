"""M0-15: EU-template <-> operational mapping round trip on a 10-loan sample."""

import csv
import datetime as dt
import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

from collectoo_worker.boarding.eba_mapping import MappingError, from_core, load_spec, to_core

REPO = Path(__file__).resolve().parents[2]
CATALOGUE = REPO / "docs/reference/eba_field_catalogue.csv"


def _gen_sql() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "gen_sql", REPO / "tools/eba_catalogue/gen_sql.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COLUMN_NAME = _gen_sql().column_name
FIELDS = list(csv.DictReader(CATALOGUE.open(encoding="utf-8")))
COLUMNS = {
    "t1_counterparty": [
        COLUMN_NAME(f["field_id"], f["field_name"]) for f in FIELDS if f["template_id"] == "T1"
    ],
    "t3_loan": [
        COLUMN_NAME(f["field_id"], f["field_name"]) for f in FIELDS if f["template_id"] == "T3"
    ],
}
LEGAL_TYPES = [
    "Households",
    "Non-financial corporations-SMEs",
    "Non-financial corporations-other than SMEs",
]


def _value(field: dict[str, str], n: int) -> str:
    allowed = [v for v in field["allowed_values"].split(" | ") if v]
    match field["data_type"]:
        case "Date":
            return (dt.date(2020, 1, 1) + dt.timedelta(days=37 * n)).strftime("%d/%m/%Y")
        case "Number":
            return f"{1000 + n * 13}.{n % 100:02d}"
        case "Percentage":
            return f"0.0{n % 10}"
        case "Boolean":
            return "Yes" if n % 2 else "No"
        case "Choice" if allowed:
            return allowed[n % len(allowed)]
        case _:
            return f"{field['field_id']}-v{n}"


def _sample_tape() -> dict[str, list[dict[str, str | None]]]:
    t1 = []
    for n in range(8):
        row: dict[str, str | None] = {}
        for f in (f for f in FIELDS if f["template_id"] == "T1"):
            row[COLUMN_NAME(f["field_id"], f["field_name"])] = _value(f, n)
        row["f1_02_counterparty_identifier"] = f"CPTY-{n}"
        row["f1_06_legal_type_of_counterparty"] = LEGAL_TYPES[n % 3]
        row["f1_33_description_of_other_legal_measures"] = None  # empty values survive too
        t1.append(row)
    t3: list[dict[str, str | None]] = []
    t2: list[dict[str, str | None]] = []
    for n in range(10):
        row = {
            COLUMN_NAME(f["field_id"], f["field_name"]): _value(f, n)
            for f in FIELDS
            if f["template_id"] == "T3"
        }
        row["f3_01_loan_identifier"] = f"LOAN-{n}"
        row["f3_08_currency"] = "EUR"
        t3.append(row)
        t2.append(
            {"f2_00_counterparty_identifier": f"CPTY-{n % 8}", "f2_01_loan_identifier": f"LOAN-{n}"}
        )
    return {"t1_counterparty": t1, "t3_loan": t3, "t2_1_borrower_loan": t2}


def test_spec_only_uses_catalogued_columns() -> None:
    known = {COLUMN_NAME(f["field_id"], f["field_name"]) for f in FIELDS}
    assert load_spec().source_columns() <= known


def test_round_trip_is_lossless() -> None:
    tape = _sample_tape()
    core = to_core(tape)
    assert (
        len(core["party"]) == 8 and len(core["account"]) == 10 and len(core["account_party"]) == 10
    )
    back = from_core(core, COLUMNS)
    assert back == tape


def test_typed_targets_and_source_attributes() -> None:
    core = to_core(_sample_tape())
    account = core["account"][0]
    assert account["external_ref"] == "LOAN-0"
    assert isinstance(account["contract_date"], dt.date)
    # Mapped losslessly: only in its column. Unmapped: kept verbatim for re-export.
    assert "f3_02_inception_date" not in account["source_attributes"]
    assert account["source_attributes"]["f3_09_principal_amount"] == "1000.00"
    party = core["party"][1]
    assert party["kind"] == "legal_entity"
    # Many-to-one enum: the original value is kept so SME vs non-SME survives.
    assert party["source_attributes"]["f1_06_legal_type_of_counterparty"] == LEGAL_TYPES[1]


def test_capacity_is_derived_from_legal_type() -> None:
    core = to_core(_sample_tape())
    by_ref = {link["party_seller_ref"]: link["capacity"] for link in core["account_party"]}
    assert by_ref["CPTY-0"] == "consumer"
    assert by_ref["CPTY-1"] == "legal_entity"
    assert {link["role"] for link in core["account_party"]} == {"borrower"}


@pytest.mark.parametrize(
    ("table", "column", "value", "message"),
    [
        ("t3_loan", "f3_01_loan_identifier", "", "f3_01_loan_identifier is required"),
        ("t3_loan", "f3_02_inception_date", "2021-03-15", "is not DD/MM/YYYY"),
        ("t1_counterparty", "f1_06_legal_type_of_counterparty", "Bank", "is not an allowed value"),
        ("t2_1_borrower_loan", "f2_01_loan_identifier", "LOAN-404", "unknown counterparty or loan"),
    ],
)
def test_invalid_rows_are_rejected_with_row_reference(
    table: str, column: str, value: str, message: str
) -> None:
    tape = _sample_tape()
    tape[table][0][column] = value
    with pytest.raises(MappingError, match=message):
        to_core(tape)
