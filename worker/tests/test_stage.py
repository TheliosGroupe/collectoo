"""M1-17 staging: entities per file type, duplicates staged once, re-runs are identical."""

import csv
import json
from decimal import Decimal
from pathlib import Path
from typing import Any

import polars as pl
from test_validation import _eba_files

from collectoo_worker.ai.gateway import Gateway
from collectoo_worker.ai.mock import MockProvider
from collectoo_worker.boarding.mapping import propose
from collectoo_worker.boarding.profile import profile_frame
from collectoo_worker.boarding.readers import scan_csv
from collectoo_worker.boarding.stage import encode, stage_rows, staging_digest
from collectoo_worker.boarding.validate import FileResult, validate_batch
from collectoo_worker.synth.civil import generate_civil


def _civil(
    tmp_path: Path, kind: str, defect_rate: float = 0.0
) -> tuple[FileResult, dict[str, Any], list[list[str]]]:
    table, manifest = generate_civil(kind, "fr_semicolon", 300, 17, defect_rate=defect_rate)  # type: ignore[arg-type]
    path = tmp_path / f"{kind}.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        csv.writer(fh, delimiter=";").writerows(table)
    profile = profile_frame(scan_csv(path)[0])
    mapping = {p.source_column: p.target for p in propose(Gateway(MockProvider()), profile)}
    result = FileResult("f1", path.name, scan_csv(path)[0].collect(), mapping)
    validate_batch(
        [result],
        {"f1": profile},
        portfolio_default=None,
        conformance="servicing",
        art4_exempt=False,
        join_keys=[],
    )
    return result, manifest, table


def _data(staged: dict[str, pl.DataFrame], entity: str) -> list[dict[str, Any]]:
    return [json.loads(d) for d in encode(staged[entity])["data"].to_list()]


def test_b2b_invoices_stage_one_account_per_client_reference(tmp_path: Path) -> None:
    result, _, table = _civil(tmp_path, "b2b_invoice")
    staged = stage_rows([result], None)  # type: ignore[arg-type]
    refs = {r[0] for r in table[1:]}
    assert staged["account"].height == len(refs) == staged["party"].height
    items = _data(staged, "claim_item")
    assert len(items) == 300
    assert {i["kind"] for i in items} <= {"invoice", "credit_note"}
    assert all(i["original_minor"] >= 0 for i in items)  # credit notes stored as positive amounts
    parties = _data(staged, "party")
    assert {p["kind"] for p in parties} == {"legal_entity"}
    accounts = _data(staged, "account")
    assert {a["claim_type"] for a in accounts} == {"b2b_invoice"}
    assert {a["capacity"] for a in accounts} == {"legal_entity"}


def test_duplicates_are_staged_once(tmp_path: Path) -> None:
    result, manifest, _ = _civil(tmp_path, "rent", defect_rate=0.2)
    dups = sum(1 for d in manifest["defects"] if d["type"] == "duplicate_row")
    staged = stage_rows([result], None)  # type: ignore[arg-type]
    items = _data(staged, "claim_item")
    assert dups > 0
    assert len(items) <= 300 - dups
    assert {i["kind"] for i in items} == {"rent_period"}


def test_restaging_gives_identical_rows_and_hashes(tmp_path: Path) -> None:
    first, _, _ = _civil(tmp_path, "b2c_invoice")
    (tmp_path / "again").mkdir()
    second, _, _ = _civil(tmp_path / "again", "b2c_invoice")
    d1 = staging_digest(stage_rows([first], None))  # type: ignore[arg-type]
    d2 = staging_digest(stage_rows([second], None))  # type: ignore[arg-type]
    assert d1 == d2


def test_eba_tape_stages_layer_1_and_layer_2() -> None:
    files, profiles = _eba_files(40)
    validate_batch(
        files,
        profiles,
        portfolio_default=None,
        conformance="servicing",
        art4_exempt=False,
        join_keys=[],
    )
    staged = stage_rows(files, None)  # type: ignore[arg-type]
    t1 = next(f for f in files if f.eba_table == "t1_counterparty")
    t3 = next(f for f in files if f.eba_table == "t3_loan")
    assert staged["party"].height == t1.rows
    assert staged["account"].height == t3.rows == staged["claim_item"].height
    assert (
        staged["account_party"].height
        == next(f for f in files if f.eba_table == "t2_1_borrower_loan").rows
    )
    assert staged["eba.t3_loan"].height == t3.rows and staged["eba.t5_collection"].height == 40 * 36
    item = _data(staged, "claim_item")[0]
    loan = t3.raw.row(0, named=True)
    assert item["original_minor"] == int(Decimal(loan["f3_12_legal_balance"]) * 100)
    row = _data(staged, "eba.t3_loan")[0]
    assert row["f3_01_loan_identifier"] == loan["f3_01_loan_identifier"] and row["source_row"] == 1
    assert row["f3_02_inception_date"].count("-") == 2  # ISO date, ready for Postgres
