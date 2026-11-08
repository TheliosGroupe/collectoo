"""M0-16/M0-17/M0-18: synthetic generators are valid, deterministic and honest about defects."""

import random
import re
from decimal import Decimal
from pathlib import Path

import jsonschema
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.boarding.eba_mapping import to_core
from collectoo_worker.eba.catalogue import columns, fields, json_schema
from collectoo_worker.synth.civil import DIALECT_SPECS, DIALECTS, KINDS, generate_civil
from collectoo_worker.synth.eba import HISTORY_MONTHS, generate_eba
from collectoo_worker.synth.ids import iban_fr, iban_valid, luhn_valid, siren, siret
from collectoo_worker.synth.seed import USERS, seed_sql

REPO = Path(__file__).resolve().parents[2]


@given(st.integers())
def test_identifiers_have_valid_check_digits(seed: int) -> None:
    rng = random.Random(seed)
    s = siren(rng)
    assert len(s) == 9 and luhn_valid(s)
    t = siret(rng, s)
    assert len(t) == 14 and t.startswith(s) and luhn_valid(t)
    iban = iban_fr(rng)
    assert iban.startswith("FR") and len(iban) == 27 and iban_valid(iban)


def test_catalogue_columns_match_the_generated_migration() -> None:
    sql = (REPO / "supabase/migrations/20261108110100_eba_layer1.sql").read_text()
    migration_columns = set(re.findall(r"^  (f\d+_\d+_[a-z0-9_]+) ", sql, re.MULTILINE))
    assert {f.column for f in fields()} <= migration_columns


def _validator(template_id: str) -> jsonschema.Draft202012Validator:
    schema = json_schema()
    sub = {"$schema": schema["$schema"], **schema["$defs"][template_id]}
    return jsonschema.Draft202012Validator(sub)


def test_eba_tape_matches_template_columns_and_schema() -> None:
    tape = generate_eba(200, seed=7)
    by_column = {f.column: f"f{f.field_id.replace('.', '_')}" for f in fields()}
    for table, template_id in (("t1_counterparty", "T1"), ("t3_loan", "T3")):
        validator = _validator(template_id)
        for row in tape[table]:
            assert list(row) == columns(template_id)
            instance = {by_column[c]: v for c, v in row.items() if v != ""}
            errors = list(validator.iter_errors(instance))
            assert not errors, (table, errors[0].message)


def test_eba_tape_is_internally_consistent() -> None:
    tape = generate_eba(300, seed=3)
    loans = {r["f3_01_loan_identifier"]: r for r in tape["t3_loan"]}
    cptys = {r["f1_02_counterparty_identifier"] for r in tape["t1_counterparty"]}
    assert len(loans) == 300
    for link in tape["t2_1_borrower_loan"]:
        assert link["f2_00_counterparty_identifier"] in cptys
        assert link["f2_01_loan_identifier"] in loans
    for loan in loans.values():
        parts = sum(
            Decimal(loan[c])
            for c in ("f3_09_principal_amount", "f3_10_accrued_interest", "f3_11_other_balances")
        )
        assert parts == Decimal(loan["f3_12_legal_balance"])
    assert len(tape["t5_collection"]) == 300 * HISTORY_MONTHS
    kinds = {r["f1_06_legal_type_of_counterparty"] for r in tape["t1_counterparty"]}
    assert kinds == {"Households", "Non-financial corporations-SMEs"}


def test_eba_tape_boards_through_the_mapping_spec() -> None:
    core = to_core(generate_eba(100, seed=11))
    assert len(core["account"]) == 100
    assert {link["capacity"] for link in core["account_party"]} == {"consumer", "legal_entity"}


def test_generators_are_deterministic() -> None:
    assert generate_eba(50, seed=1) == generate_eba(50, seed=1)
    assert generate_eba(50, seed=1) != generate_eba(50, seed=2)
    assert generate_civil("rent", "tab_dotted", 80, 5) == generate_civil(
        "rent", "tab_dotted", 80, 5
    )
    assert seed_sql(1) == seed_sql(1)


def test_civil_files_declare_every_injected_defect() -> None:
    for kind in KINDS:
        for dialect in DIALECTS:
            table, manifest = generate_civil(kind, dialect, rows=400, seed=42, defect_rate=0.2)
            header, data = table[0], table[1:]
            col = {name: i for i, name in enumerate(header)}
            h = manifest["columns"]
            assert isinstance(h, dict) and isinstance(manifest["defects"], list)
            assert manifest["rows"] == len(data)
            types = {d["type"] for d in manifest["defects"]}
            assert len(types) >= 5, (kind, dialect, types)
            for d in manifest["defects"]:
                row = data[d["row"] - 1]
                match d["type"]:
                    case "duplicate_row":
                        assert row == data[d["row"] - 2]
                    case "missing_contact":
                        assert row[col[h["email"]]] == "" and row[col[h["phone"]]] == ""
                    case "invalid_siren":
                        assert not luhn_valid(row[col[h["siren"]]])
                    case "impossible_date":
                        assert "31" in row[col[h["due_date"]]] and "02" in row[col[h["due_date"]]]
                    case "mixed_date_format":
                        assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", row[col[h["due_date"]]])
                    case "negative_amount":
                        assert row[col[h["amount"]]].startswith("-")


def test_civil_dialects_use_their_number_and_date_formats() -> None:
    table, manifest = generate_civil("b2b_invoice", "fr_semicolon", 30, 1, defect_rate=0)
    amount = table[1][table[0].index("Montant TTC")]
    assert re.fullmatch(r"-?\d+,\d{2}", amount)
    assert re.fullmatch(r"\d{2}/\d{2}/\d{4}", table[1][table[0].index("Échéance")])
    assert DIALECT_SPECS["tab_dotted"].thousands == "\u00a0"
    assert manifest["defects"] == []


def test_seed_sql_has_every_role_and_only_test_domains() -> None:
    sql = seed_sql(1)
    roles = {r for _, _, r in USERS}
    assert roles == {"admin", "ops_manager", "collector", "client_admin", "client_viewer"}
    emails = set(re.findall(r"'([^'@\s]+@[^'\s]+)'", sql))
    user_emails = {e for e, _, _ in USERS}
    assert user_emails <= emails
    assert all(e.endswith(".test") for e in user_emails)
    assert sql.count("'in_collection'") > 100
