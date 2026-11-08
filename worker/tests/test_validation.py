"""M1-14 claim types, M1-15 validation rules and M1-16 data-quality report (offline, mock LLM)."""

import csv
from pathlib import Path
from typing import Any

import polars as pl
import pytest

from collectoo_worker.ai.gateway import Gateway
from collectoo_worker.ai.mock import MockProvider
from collectoo_worker.boarding.dq import build_report
from collectoo_worker.boarding.mapping import propose
from collectoo_worker.boarding.profile import profile_frame
from collectoo_worker.boarding.readers import scan_csv
from collectoo_worker.boarding.validate import (
    FileResult,
    IssueLog,
    detect_eba_table,
    validate_batch,
)
from collectoo_worker.eba.catalogue import columns
from collectoo_worker.synth.civil import DIALECTS, KINDS, generate_civil
from collectoo_worker.synth.eba import generate_eba

DEFECT_TO_ISSUE = {
    "missing_contact": ("missing_contact", "warning"),
    "duplicate_row": ("duplicate_row", "warning"),
    "invalid_siren": ("invalid_siren", "warning"),
    "impossible_date": ("impossible_date", "blocking"),
    "mixed_date_format": ("mixed_date_format", "warning"),
    "negative_amount": ("negative_amount", "blocking"),
    "overpaid": ("overpaid", "warning"),
}
CLAIMS = {
    "b2b_invoice": ("b2b_invoice", "commercial_b2b"),
    "b2c_invoice": ("b2c_invoice", "consumer_b2c"),
    "rent": ("rent", "civil"),
}


def _civil(
    tmp_path: Path, kind: str, dialect: str, defect_rate: float
) -> tuple[FileResult, dict[str, Any], dict[str, Any]]:
    table, manifest = generate_civil(kind, dialect, 400, 31, defect_rate=defect_rate)  # type: ignore[arg-type]
    path = tmp_path / f"{kind}_{dialect}.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        csv.writer(fh, delimiter=str(manifest["delimiter"])).writerows(table)
    profile = profile_frame(scan_csv(path)[0])
    mapping = {p.source_column: p.target for p in propose(Gateway(MockProvider()), profile)}
    return FileResult("f1", path.name, scan_csv(path)[0].collect(), mapping), profile, manifest


def _validate(files: list[FileResult], profiles: dict[str, Any], **kw: Any) -> IssueLog:
    args: dict[str, Any] = {
        "portfolio_default": None,
        "conformance": "servicing",
        "art4_exempt": False,
        "join_keys": [],
    }
    return validate_batch(files, profiles, **{**args, **kw})


@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("dialect", DIALECTS)
def test_every_injected_defect_is_reported_with_its_severity(
    tmp_path: Path, kind: str, dialect: str
) -> None:
    result, profile, manifest = _civil(tmp_path, kind, dialect, 0.2)
    log = _validate([result], {"f1": profile})
    found = {(i.row, i.code, i.severity) for i in log.issues}
    for defect in manifest["defects"]:
        code, sev = DEFECT_TO_ISSUE[defect["type"]]
        assert (defect["row"], code, sev) in found, defect
    assert set(result.claim_types) == {CLAIMS[kind][0]}
    assert set(result.legal_regimes) == {CLAIMS[kind][1]}


@pytest.mark.parametrize("kind", KINDS)
def test_a_clean_file_has_no_blocking_issue(tmp_path: Path, kind: str) -> None:
    result, profile, _ = _civil(tmp_path, kind, "fr_semicolon", 0.0)
    log = _validate([result], {"f1": profile})
    assert log.blocking == 0, [i for i in log.issues if i.severity == "blocking"][:3]
    # Amounts became integer cents, dates real dates.
    assert all(isinstance(a, int) for a in result.values["claim_item.amount"] if a is not None)


def test_portfolio_default_wins_over_file_signals(tmp_path: Path) -> None:
    result, profile, _ = _civil(tmp_path, "b2c_invoice", "en_comma", 0.0)
    _validate([result], {"f1": profile}, portfolio_default="private_loan")
    assert set(result.claim_types) == {"private_loan"} and set(result.legal_regimes) == {"civil"}


def _eba_files(loans: int = 60) -> tuple[list[FileResult], dict[str, Any]]:
    tape = generate_eba(loans, 5)
    files, profiles = [], {}
    for table, rows in tape.items():
        df = pl.DataFrame(rows, schema={c: pl.Utf8 for c in rows[0]})
        mapping = {c: (f"eba.{c}" if c.startswith("f") else None) for c in df.columns}
        files.append(FileResult(table, table, df, mapping, eba_table=detect_eba_table(mapping)))
        profiles[table] = profile_frame(df.lazy())
    return files, profiles


def test_eba_tape_claim_types_regimes_and_references() -> None:
    files, profiles = _eba_files()
    log = _validate(files, profiles)
    loans = next(f for f in files if f.eba_table == "t3_loan")
    assert set(loans.claim_types) == {"consumer_instalment_loan", "professional_loan"}
    assert set(loans.legal_regimes) == {
        "consumer_credit_pre_ccd2",
        "professional_credit",
    }  # inception < CCD2
    assert not [i for i in log.issues if i.code == "broken_reference"]
    assert log.blocking == 0


def test_eba_broken_links_and_mandatory_fields() -> None:
    files, profiles = _eba_files()
    links = next(f for f in files if f.eba_table == "t2_1_borrower_loan")
    links.raw = links.raw.with_columns(
        pl.when(pl.int_range(pl.len()) == 0)
        .then(pl.lit("LOAN-999999"))
        .otherwise(pl.col("f2_01_loan_identifier"))
        .alias("f2_01_loan_identifier")
    )
    servicing = _validate(files, profiles)
    broken = [i for i in servicing.issues if i.code == "broken_reference"]
    assert [(i.row, i.severity) for i in broken] == [(1, "blocking")]
    mandatory = [i for i in servicing.issues if i.code == "eba_mandatory_missing"]
    assert mandatory and {i.severity for i in mandatory} == {"warning"}
    regulatory = _validate(files, profiles, conformance="regulatory")
    assert {i.severity for i in regulatory.issues if i.code == "eba_mandatory_missing"} == {
        "blocking"
    }
    exempt = _validate(files, profiles, art4_exempt=True)
    assert not [i for i in exempt.issues if i.code == "eba_mandatory_missing"]


def test_consumer_loans_need_a_contract_date_for_the_legal_regime() -> None:
    files, profiles = _eba_files(20)
    loans = next(f for f in files if f.eba_table == "t3_loan")
    loans.mapping["f3_02_inception_date"] = None
    log = _validate(files, profiles)
    consumer_rows = [i for i in log.issues if i.code == "unknown_legal_regime"]
    assert consumer_rows and {i.severity for i in consumer_rows} == {"blocking"}


def test_dq_report_reconciles_to_the_cent(tmp_path: Path) -> None:
    result, profile, _ = _civil(tmp_path, "b2b_invoice", "fr_semicolon", 0.0)
    log = _validate([result], {"f1": profile})
    expected = sum(a for a in result.values["claim_item.amount"] if a is not None)
    report = build_report(
        [result], log, control={"total_minor": expected - 1, "rows": 400}, spec_versions={}
    )
    rec = report["reconciliation"]
    assert rec["computed"]["total_minor"] == expected
    assert rec["difference_minor"] == 1 and rec["status"] == "mismatch"
    matched = build_report([result], log, control={"total_minor": expected}, spec_versions={})
    assert matched["reconciliation"]["status"] == "matched"
    contact = report["contactability"]
    assert contact["rows"] == 400 and 0.5 < contact["any_pct"] <= 1.0
    assert report["files"][0]["completeness"]["claim_item.amount"] == 1.0


def test_dq_report_reconciles_eba_legal_balance() -> None:
    files, profiles = _eba_files(30)
    log = _validate(files, profiles)
    loans = next(f for f in files if f.eba_table == "t3_loan")
    from decimal import Decimal  # noqa: PLC0415

    tape_total = sum(Decimal(v) for v in loans.raw["f3_12_legal_balance"].to_list())
    report = build_report(
        files, log, control={"total_minor": int(tape_total * 100)}, spec_versions={}
    )
    assert report["reconciliation"]["status"] == "matched"
    assert report["claim_types"] == {
        k: v
        for k, v in report["claim_types"].items()
        if k in ("consumer_instalment_loan", "professional_loan")
    }
    assert columns("T3")[0] == "f3_00_cut_off_date"
