"""M2-05 prerequisites (design §7.4): one definition of claim items shared by validation, the
DQ report and staging; validation spec v2 codes."""

import json
from decimal import Decimal
from typing import Any

import polars as pl
import pytest
from test_validation import _eba_files, _validate

from collectoo_worker.boarding.dq import build_report
from collectoo_worker.boarding.items import civil_items, eba_loans
from collectoo_worker.boarding.opening import check_bridge
from collectoo_worker.boarding.stage import encode, split_skipped, stage_rows
from collectoo_worker.boarding.validate import FileResult, IssueLog, rules

CIVIL_MAPPING: dict[str, str | None] = {
    "compte": "account.external_ref",
    "nom": "party.display_name",
    "type": "claim_item.kind",
    "piece": "claim_item.ref",
    "periode": "claim_item.period",
    "echeance": "claim_item.due_date",
    "montant": "claim_item.amount",
    "regle": "claim_item.amount_paid",
    "devise": "claim_item.currency",
}


def civil_file(file_id: str, rows: list[dict[str, str | None]]) -> FileResult:
    """A civil file as read from CSV (all text, empty cells null), mapped by CIVIL_MAPPING."""
    raw = pl.DataFrame(
        {c: [r.get(c) or None for r in rows] for c in CIVIL_MAPPING},
        schema={c: pl.Utf8 for c in CIVIL_MAPPING},
    )
    return FileResult(file_id, f"{file_id}.csv", raw, dict(CIVIL_MAPPING))


def row(account: str | None = "A1", **kw: str | None) -> dict[str, str | None]:
    base: dict[str, str | None] = {
        "compte": account,
        "nom": "DURAND",
        "echeance": "05/03/2026",
        "montant": "100.00",
    }
    return {**base, **kw}


def validate(*files: FileResult, **kw: Any) -> IssueLog:
    return _validate(list(files), {}, **kw)


def codes(log: IssueLog, code: str) -> list[tuple[str, int | None, str]]:
    return [(i.file_id, i.row, i.severity) for i in log.issues if i.code == code]


def staged_items(*files: FileResult) -> list[dict[str, Any]]:
    staged = stage_rows(list(files), IssueLog())
    return [json.loads(d) for d in encode(staged["claim_item"])["data"].to_list()]


# --- Kind, sign and ref ------------------------------------------------------------------------


def test_a_credit_note_with_a_period_stays_a_credit_note() -> None:
    f = civil_file("f1", [row(type="AVOIR", periode="03/2026", montant="100.00")])
    validate(f)
    (item,) = staged_items(f)
    assert item["kind"] == "credit_note" and item["original_minor"] == 10000
    assert item["ref"] == "03/2026"
    frame = civil_items([f])
    assert frame["outstanding_minor"].to_list() == [-10000]


def test_a_negative_amount_is_a_credit_note() -> None:
    f = civil_file("f1", [row(type="FACTURE", montant="-50.00")])
    log = validate(f)
    (item,) = staged_items(f)
    assert item["kind"] == "credit_note" and item["original_minor"] == 5000
    assert civil_items([f])["outstanding_minor"].to_list() == [-5000]
    assert codes(log, "negative_amount") == [("f1", 1, "blocking")]  # still reported


def test_kind_precedence_rent_then_invoice() -> None:
    f = civil_file(
        "f1",
        [row(periode="03/2026"), row(piece="F1"), row(type="AVOIR", piece="AV1", montant="5.00")],
    )
    validate(f)
    assert [i["kind"] for i in staged_items(f)] == ["rent_period", "invoice", "credit_note"]


def test_signed_amounts_paid_and_overpaid() -> None:
    f = civil_file(
        "f1",
        [
            row(piece="F1", montant="1250.00", regle="250.00"),
            row(piece="F2", montant="30.00", regle="45.00"),  # overpaid: debtor in credit
            row(piece="AV1", type="AVOIR", montant="-12.34"),
        ],
    )
    validate(f)
    frame = civil_items([f])
    assert frame["original_minor"].to_list() == [125000, 3000, 1234]
    assert frame["seller_paid_minor"].to_list() == [25000, 4500, 0]
    assert frame["outstanding_minor"].to_list() == [100000, -1500, -1234]


def test_colliding_derived_refs_get_suffixes_in_source_order() -> None:
    f = civil_file(
        "f1",
        [
            row(periode="03/2026", montant="500.00"),  # rent
            row(periode="03/2026", montant="80.00"),  # charges, same month
            row(periode="03/2026", montant="500.00", echeance="06/03/2026"),
            row("A2", periode="03/2026", montant="500.00"),  # another account: no suffix
            row(echeance="05/04/2026", montant="10.00"),  # no period: the due date
            row(echeance="05/04/2026", montant="10.00", nom="DURAND SA"),
        ],
    )
    log = validate(f)
    refs = [(i["account_key"], i["ref"]) for i in staged_items(f)]
    assert refs == [
        ("A1", "03/2026"),
        ("A1", "03/2026#2"),
        ("A1", "03/2026#3"),
        ("A2", "03/2026"),
        ("A1", "2026-04-05"),
        ("A1", "2026-04-05#2"),
    ]
    assert not codes(log, "duplicate_document") and not codes(log, "conflicting_document")


# --- Identity across files ----------------------------------------------------------------------


def test_the_same_document_in_two_files_is_staged_once() -> None:
    f1 = civil_file("f1", [row(piece="F1"), row(piece="F2")])
    f2 = civil_file("f2", [row(piece="F2", nom="DURAND SARL"), row(piece="F3")])
    log = validate(f1, f2)
    assert codes(log, "duplicate_document") == [("f2", 1, "warning")]
    assert log.blocking == 0
    assert [i["ref"] for i in staged_items(f1, f2)] == ["F1", "F2", "F3"]
    rec = build_report([f1, f2], log, control={}, spec_versions={})["reconciliation"]
    assert rec["computed"]["rows"] == 3 and rec["computed"]["outstanding_minor"] == 30000


def test_a_file_sent_twice_without_document_numbers_is_counted_once() -> None:
    rows = [row(periode="03/2026", montant="500.00"), row(periode="03/2026", montant="80.00")]
    f1, f2 = civil_file("f1", rows), civil_file("f2", rows)
    log = validate(f1, f2)
    assert codes(log, "duplicate_document") == [("f2", 1, "warning"), ("f2", 2, "warning")]
    assert [i["ref"] for i in staged_items(f1, f2)] == ["03/2026", "03/2026#2"]
    computed = build_report([f1, f2], log, control={}, spec_versions={})["reconciliation"]
    assert computed["computed"]["outstanding_minor"] == 58000


def test_conflicting_document_within_a_file() -> None:
    f = civil_file("f1", [row(piece="F1"), row(piece="F1", montant="120.00")])
    log = validate(f)
    assert codes(log, "conflicting_document") == [("f1", 2, "blocking")]
    assert not codes(log, "duplicate_document")


@pytest.mark.parametrize(
    "change",
    [{"montant": "100.01"}, {"regle": "1.00"}, {"devise": "USD"}, {"echeance": "06/03/2026"}],
)
def test_conflicting_document_across_files(change: dict[str, str]) -> None:
    f1 = civil_file("f1", [row(piece="F1")])
    f2 = civil_file("f2", [row(piece="F1", **change)])
    log = validate(f1, f2)
    assert codes(log, "conflicting_document") == [("f2", 1, "blocking")]
    assert len(staged_items(f1, f2)) == 1  # never staged twice (commit would raise 23505)


def test_an_invoice_and_a_credit_note_may_share_a_number() -> None:
    f = civil_file("f1", [row(piece="F1"), row(piece="F1", type="AVOIR")])
    log = validate(f)
    assert log.blocking == 0 and not codes(log, "duplicate_document")
    assert [i["kind"] for i in staged_items(f)] == ["invoice", "credit_note"]


def _computed(files: list[FileResult], log: IssueLog) -> dict[str, Any]:
    report = build_report(files, log, control={}, spec_versions={})
    computed: dict[str, Any] = report["reconciliation"]["computed"]
    return computed


def test_rent_and_charges_of_the_same_month_in_two_files_are_two_items() -> None:
    f1 = civil_file("f1", [row(periode="03/2026", montant="500.00")])  # rent
    f2 = civil_file("f2", [row(periode="03/2026", montant="80.00")])  # charges, another file
    log = validate(f1, f2)
    assert log.blocking == 0
    assert not codes(log, "duplicate_document") and not codes(log, "conflicting_document")
    items = [(i["ref"], i["original_minor"]) for i in staged_items(f1, f2)]
    assert items == [("03/2026", 50000), ("03/2026#2", 8000)]
    assert _computed([f1, f2], log)["outstanding_minor"] == 58000


def test_the_same_derived_row_in_another_file_is_counted_once() -> None:
    f1 = civil_file("f1", [row(periode="03/2026", montant="500.00")])
    f2 = civil_file("f2", [row(periode="03/2026", montant="500.00")])  # identical row
    log = validate(f1, f2)
    assert codes(log, "duplicate_document") == [("f2", 1, "warning")]  # ambiguous: reported
    assert log.blocking == 0
    assert [i["ref"] for i in staged_items(f1, f2)] == ["03/2026"]
    assert _computed([f1, f2], log)["outstanding_minor"] == 50000


def test_derived_refs_are_numbered_across_the_batch_in_file_then_row_order() -> None:
    f1 = civil_file(
        "f1", [row(periode="03/2026", montant="500.00"), row(periode="03/2026", montant="80.00")]
    )
    f2 = civil_file(
        "f2",
        [
            row(periode="03/2026", montant="30.00"),  # new: numbered after f1's two
            row(periode="03/2026", montant="500.00"),  # f1's first row again
            row(periode="03/2026", montant="80.00", nom="DURAND SA"),  # another value: new
        ],
    )
    log = validate(f1, f2)
    assert codes(log, "duplicate_document") == [("f2", 2, "warning")]
    assert log.blocking == 0
    refs = [(i["ref"], i["original_minor"]) for i in staged_items(f1, f2)]
    assert refs == [
        ("03/2026", 50000),
        ("03/2026#2", 8000),
        ("03/2026#3", 3000),
        ("03/2026#4", 8000),
    ]
    assert staged_items(f1, f2) == staged_items(f1, f2)  # deterministic


def test_items_without_any_ref_are_blocking_and_all_counted() -> None:
    # private_loan requires no ref, period or due date: two items of A1 with none of them.
    f = civil_file("f1", [row(echeance=None), row(echeance=None, montant="250.00")])
    log = validate(f, portfolio_default="private_loan")
    found = [(i.row, i.target, i.severity) for i in log.issues if i.code == "missing_required"]
    assert found == [(1, "claim_item.ref", "blocking"), (2, "claim_item.ref", "blocking")]
    assert not codes(log, "conflicting_document") and not codes(log, "duplicate_document")
    computed = _computed([f], log)
    assert computed["rows"] == 2 and computed["outstanding_minor"] == 35000  # nothing dropped
    # The same file sent twice is still counted once.
    again = civil_file("f2", [row(echeance=None), row(echeance=None, montant="250.00")])
    twice = validate(f, again, portfolio_default="private_loan")
    assert _computed([f, again], twice)["outstanding_minor"] == 35000


@pytest.mark.parametrize(
    ("claim_type", "expected"),
    [
        ("b2c_invoice", ["claim_item.due_date", "claim_item.ref"]),
        ("rent", ["claim_item.due_date"]),
    ],
)
def test_a_missing_ref_is_reported_once(claim_type: str, expected: list[str]) -> None:
    # These claim types require the due date (b2c: the document number too): `_required`
    # already reports the row, no second issue for the same reason.
    f = civil_file("f1", [row(echeance=None)])
    log = validate(f, portfolio_default=claim_type)
    found = sorted(i.target or "" for i in log.issues if i.code == "missing_required")
    assert found == expected


@pytest.mark.parametrize("claim_type", ["private_loan", "judgment_debt"])
def test_a_row_without_an_account_reference_is_blocking(claim_type: str) -> None:
    f = civil_file("f1", [row(None, piece="P1"), row(None, montant=None), row("A1", piece="P2")])
    log = validate(f, portfolio_default=claim_type)
    found = [(i.row, i.target, i.severity) for i in log.issues if i.code == "missing_required"]
    missing = ("account.external_ref", "blocking")
    assert found == [(1, *missing), (2, *missing)]


def _accounts(*files: FileResult) -> list[dict[str, Any]]:
    staged = stage_rows(list(files), IssueLog())
    return [json.loads(d) for d in encode(staged["account"])["data"].to_list()]


def test_a_civil_account_takes_the_currency_of_its_items() -> None:
    # Row 2 has no amount (no item): its currency never becomes the account's (commit: LG006).
    f = civil_file(
        "f1", [row("P1", piece="P1", montant="1000.00"), row("P1", montant=None, devise="USD")]
    )
    log = validate(f, portfolio_default="private_loan")
    assert log.blocking == 0
    (account,) = _accounts(f)
    assert account["currency"] == "EUR"
    _, opening, skipped = split_skipped(stage_rows([f], log), set())
    check_bridge(_computed([f], log)["currencies"], opening, skipped)
    assert set(opening["currencies"]) == {"EUR"}
    assert opening["currencies"]["EUR"]["accounts"] == 1


def test_an_account_in_several_files_takes_the_currency_of_its_items() -> None:
    f1 = civil_file("f1", [row("A1", montant=None), row("A2", montant=None, devise="USD")])
    f2 = civil_file("f2", [row("A1", piece="F1", devise="USD")])  # A1's only item
    log = validate(f1, f2, portfolio_default="private_loan")
    assert log.blocking == 0
    currencies = {a["external_ref"]: a["currency"] for a in _accounts(f1, f2)}
    assert currencies == {"A1": "USD", "A2": "EUR"}  # no item: EUR, whatever its rows say
    _, opening, skipped = split_skipped(stage_rows([f1, f2], log), set())
    check_bridge(_computed([f1, f2], log)["currencies"], opening, skipped)
    assert opening["currencies"]["USD"]["accounts"] == 1
    assert opening["currencies"]["EUR"]["accounts_without_balance"] == 1


def test_a_negative_amount_paid_is_blocking() -> None:
    f = civil_file("f1", [row(piece="F1", regle="-30.00"), row(piece="F2", regle="10.00")])
    log = validate(f)
    found = [(i.row, i.target, i.severity) for i in log.issues if i.code == "negative_amount"]
    assert found == [(1, "claim_item.amount_paid", "blocking")]


# --- Other v2 rules ----------------------------------------------------------------------------


def test_a_paid_amount_on_a_credit_note_is_blocking() -> None:
    f = civil_file(
        "f1", [row(piece="AV1", type="AVOIR", regle="10.00"), row(piece="AV2", type="AVOIR")]
    )
    log = validate(f)
    assert codes(log, "credit_note_paid") == [("f1", 1, "blocking")]


def test_one_account_one_currency() -> None:
    f = civil_file("f1", [row(piece="F1"), row(piece="F2", devise="USD"), row("A2", piece="F3")])
    log = validate(f)
    assert codes(log, "mixed_currency_account") == [("f1", 2, "blocking")]
    other = civil_file("f2", [row(piece="F9", devise="GBP")])
    across = validate(civil_file("f1", [row(piece="F1")]), other)
    assert codes(across, "mixed_currency_account") == [("f2", 1, "blocking")]


def test_unsupported_currency() -> None:
    f = civil_file("f1", [row(piece="F1", devise="JPY"), row("A2", piece="F2", devise="USD")])
    log = validate(f)
    assert codes(log, "unsupported_currency") == [("f1", 1, "blocking")]
    euro_only = validate(f, currencies=frozenset({"EUR"}))
    assert codes(euro_only, "unsupported_currency") == [
        ("f1", 1, "blocking"),
        ("f1", 2, "blocking"),
    ]


class _FakeConn:
    def __init__(self, table: bool, codes: list[str]) -> None:
        self.table, self.codes = table, codes
        self.rows: list[tuple[Any, ...]] = []

    def execute(self, query: str, *_: Any) -> "_FakeConn":
        self.rows = [(self.table,)] if "to_regclass" in query else [(c,) for c in self.codes]
        return self

    def fetchone(self) -> tuple[Any, ...]:
        return self.rows[0]

    def fetchall(self) -> list[tuple[Any, ...]]:
        return self.rows


def test_claim_currencies_come_from_the_currency_table() -> None:
    from collectoo_worker.jobs.boarding import claim_currencies  # noqa: PLC0415

    assert claim_currencies(_FakeConn(True, ["EUR", "CHF"])) == {"EUR", "CHF"}  # type: ignore[arg-type]
    before_ledger = claim_currencies(_FakeConn(False, []))  # type: ignore[arg-type]
    assert before_ledger == {"EUR", "USD", "GBP", "CHF"}


def test_validation_spec_v2_is_the_default_and_v1_is_kept() -> None:
    assert rules()["version"] == 2 and rules(1)["version"] == 1
    v2 = rules()["severity"]
    for code in (
        "conflicting_document",
        "duplicate_loan",
        "credit_note_paid",
        "mixed_currency_account",
        "unsupported_currency",
        "file_not_boarded",
        "duplicate_eba_table",
        "negative_amount",
        "bad_month_offset",
    ):
        assert v2[code] == "blocking", code
    for code in ("sub_cent_amount", "components_exceed_legal_balance", "duplicate_document"):
        assert v2[code] == "warning", code


# --- EU-template tapes -------------------------------------------------------------------------


def _loans(files: list[FileResult]) -> FileResult:
    return next(f for f in files if f.eba_table == "t3_loan")


def _set(t3: FileResult, column: str, row_index: int, value: str | None) -> None:
    t3.raw = t3.raw.with_columns(
        pl.when(pl.int_range(pl.len()) == row_index)
        .then(pl.lit(value, dtype=pl.Utf8))
        .otherwise(pl.col(column))
        .alias(column)
    )


def test_duplicate_loan_id_with_different_content_is_blocking() -> None:
    files, profiles = _eba_files(10)
    t3 = _loans(files)
    first = t3.raw.row(0, named=True)
    copy = {**t3.raw.row(1, named=True), "f3_01_loan_identifier": first["f3_01_loan_identifier"]}
    t3.raw = pl.concat([t3.raw, pl.DataFrame([first, copy], schema=t3.raw.schema)])
    log = _validate(files, profiles)
    assert codes(log, "duplicate_loan") == [(t3.file_id, 12, "blocking")]
    identical = [c for c in codes(log, "duplicate_row") if c[0] == t3.file_id]
    assert identical == [(t3.file_id, 11, "warning")]  # an identical row is only a warning
    assert eba_loans(t3).filter("first").height == 10


def test_sub_cent_amounts_are_rounded_half_up_with_a_warning() -> None:
    files, profiles = _eba_files(5)
    t3 = _loans(files)
    _set(t3, "f3_09_principal_amount", 0, "100.125")
    _set(t3, "f3_10_accrued_interest", 0, "0.004")
    _set(t3, "f3_11_other_balances", 0, "0")
    _set(t3, "f3_12_legal_balance", 0, "100.125")
    _set(t3, "f3_12_legal_balance", 1, "2.500")  # trailing zero: nothing rounded
    log = _validate(files, profiles)
    found = [(i.row, i.target, i.severity) for i in log.issues if i.code == "sub_cent_amount"]
    assert found == [
        (1, "eba.f3_09_principal_amount", "warning"),
        (1, "eba.f3_10_accrued_interest", "warning"),
        (1, "eba.f3_12_legal_balance", "warning"),
    ]
    staged = stage_rows(files, log)
    item = json.loads(encode(staged["claim_item"])["data"][0])
    assert item["original_minor"] == 10013  # half-up, not half-even (10012)
    assert json.loads(encode(staged["claim_item"])["data"][1])["original_minor"] == 250
    report = build_report(files, log, control={}, spec_versions={})
    legal = sum(Decimal(v) for v in t3.raw["f3_12_legal_balance"].to_list()[2:]) * 100
    assert report["reconciliation"]["computed"]["outstanding_minor"] == int(legal) + 10013 + 250


def test_components_above_the_legal_balance_are_flagged() -> None:
    files, profiles = _eba_files(5)
    t3 = _loans(files)
    for col, value in (
        ("f3_09_principal_amount", "100.00"),
        ("f3_10_accrued_interest", "20.00"),
        ("f3_11_other_balances", "5.00"),
        ("f3_12_legal_balance", "120.00"),
    ):
        _set(t3, col, 0, value)
    _set(t3, "f3_11_other_balances", 1, None)  # missing component
    log = _validate(files, profiles)
    assert codes(log, "components_exceed_legal_balance") == [(t3.file_id, 1, "warning")]
    report = build_report(files, log, control={}, spec_versions={})
    balancing = report["balancing"]["EUR"]
    assert balancing["negative_balancing"] == 1 and balancing["missing_components"] == 1
    assert balancing["loans_with_balancing"] >= 1
    parts = ("principal_minor", "accrued_interest_minor", "other_balances_minor", "balancing_minor")
    total = report["reconciliation"]["computed"]["currencies"]["EUR"]["outstanding_minor"]
    assert sum(int(balancing[p]) for p in parts) == int(total)  # components sum to 3.12


def test_eu_currency_is_checked_case_insensitively() -> None:
    files, profiles = _eba_files(5)
    t3 = _loans(files)
    _set(t3, "f3_08_currency", 0, "JPY")
    _set(t3, "f3_08_currency", 1, "eur")
    log = _validate(files, profiles)
    assert codes(log, "unsupported_currency") == [(t3.file_id, 1, "blocking")]
    staged = stage_rows(files, log)
    accounts = [json.loads(d) for d in encode(staged["account"])["data"].to_list()]
    assert accounts[1]["currency"] == "EUR"


def test_a_negative_eu_legal_balance_is_blocking() -> None:
    files, profiles = _eba_files(5)
    t3 = _loans(files)
    _set(t3, "f3_12_legal_balance", 0, "-125.50")  # claim_item.original_minor >= 0 at commit
    _set(t3, "f3_12_legal_balance", 1, "-0.004")  # rounds to 0.00: nothing negative is staged
    log = _validate(files, profiles)
    found = [(i.row, i.target, i.severity) for i in log.issues if i.code == "negative_amount"]
    assert found == [(1, "eba.f3_12_legal_balance", "blocking")]


def _copy(f: FileResult, file_id: str, raw: pl.DataFrame | None = None) -> FileResult:
    data = f.raw if raw is None else raw
    return FileResult(file_id, file_id, data, dict(f.mapping), eba_table=f.eba_table)


@pytest.mark.parametrize(
    "table", ["t1_counterparty", "t2_1_borrower_loan", "t3_loan", "t5_collection"]
)
def test_two_files_for_the_same_eu_table_are_blocking(table: str) -> None:
    files, profiles = _eba_files(20)
    original = next(f for f in files if f.eba_table == table)
    again = _copy(original, "again")
    log = _validate([*files, again], {**profiles, "again": profiles[original.file_id]})
    assert codes(log, "duplicate_eba_table") == [("again", None, "blocking")]
    assert log.blocking == 1


def test_a_superset_t3_file_is_blocking() -> None:
    files, profiles = _eba_files(20)
    t3 = _loans(files)
    extra = t3.raw.head(1).with_columns(pl.lit("LOAN-NEW").alias("f3_01_loan_identifier"))
    superset = _copy(t3, "superset", pl.concat([t3.raw, extra]))
    log = _validate([*files, superset], {**profiles, "superset": profiles[t3.file_id]})
    assert codes(log, "duplicate_eba_table") == [("superset", None, "blocking")]


# --- NOT NULL columns of the commit: a validated tape never leaves them empty ------------------


def _missing(log: IssueLog) -> list[tuple[str, int | None, str | None, str]]:
    return [
        (i.file_id, i.row, i.target, i.severity) for i in log.issues if i.code == "missing_required"
    ]


@pytest.mark.parametrize("claim_type", ["private_loan", "judgment_debt"])
def test_a_civil_debtor_needs_a_name(claim_type: str) -> None:
    # party.display_name is NOT NULL.
    f = civil_file("f1", [row(piece="P1", nom=None), row("A2", piece="P2")])
    log = validate(f, portfolio_default=claim_type)
    assert _missing(log) == [("f1", 1, "party.display_name", "blocking")]


@pytest.mark.parametrize(
    "mode",
    [{}, {"conformance": "regulatory"}, {"art4_exempt": True}],
    ids=["servicing", "regulatory", "art4_exempt"],
)
def test_an_eu_counterparty_needs_a_name_in_every_mode(mode: dict[str, Any]) -> None:
    files, profiles = _eba_files(5)
    t1 = next(f for f in files if f.eba_table == "t1_counterparty")
    _set(t1, "f1_03_name_of_counterparty", 1, None)  # 1.03 becomes party.display_name
    log = _validate(files, profiles, **mode)
    assert _missing(log) == [(t1.file_id, 2, "eba.f1_03_name_of_counterparty", "blocking")]


def test_eu_loans_need_their_identifier_and_balance_whatever_their_claim_type() -> None:
    # Without instrument or asset class, a loan takes the portfolio's (civil) default type: it
    # still needs 3.01 (account.external_ref) and 3.12, not the civil file's columns.
    files, profiles = _eba_files(5)
    t3 = _loans(files)
    for i in (0, 1):
        _set(t3, "f3_05_asset_class", i, None)
        _set(t3, "f3_06_type_of_instrument", i, None)
    _set(t3, "f3_01_loan_identifier", 1, None)
    log = _validate(files, profiles, portfolio_default="private_loan")
    assert t3.claim_types[:2] == ["private_loan", "private_loan"]
    assert _missing(log) == [(t3.file_id, 2, "eba.f3_01_loan_identifier", "blocking")]


def _history(files: list[FileResult]) -> FileResult:
    return next(f for f in files if f.eba_table == "t5_collection")


def test_eu_collection_history_needs_a_month_offset_column() -> None:
    # eba.t5_collection.month_offset is NOT NULL (staged from the `month_offset` column).
    files, profiles = _eba_files(5)
    t5 = _history(files)
    t5.raw = t5.raw.drop("month_offset")
    t5.mapping.pop("month_offset")
    log = _validate(files, profiles)
    assert _missing(log) == [(t5.file_id, None, None, "blocking")]


def test_eu_collection_history_month_offsets_are_positive_integers() -> None:
    files, profiles = _eba_files(5)
    t5 = _history(files)
    for i, value in ((0, None), (1, "x"), (2, "0"), (3, "-1"), (4, "1.5")):
        _set(t5, "month_offset", i, value)
    log = _validate(files, profiles)
    assert _missing(log) == [(t5.file_id, 1, None, "blocking")]
    assert codes(log, "bad_month_offset") == [(t5.file_id, r, "blocking") for r in (2, 3, 4, 5)]
    assert log.blocking == 5
