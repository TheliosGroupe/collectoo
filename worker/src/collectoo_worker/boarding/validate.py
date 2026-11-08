"""Transform and validate the files of a boarding batch (M1-11, M1-14, M1-15).

Input: each file's raw rows (all text), its approved mapping and its profile. Output: typed
columns per target (Polars series), claim type and legal regime per row, and validation issues
(blocking or warning) with the row number in the file. Rules are evaluated column-wise so a
1M-row tape stays fast and small in memory. Nothing is written here; the job persists results.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from functools import cache
from importlib import resources
from typing import Any

import polars as pl
import yaml

from collectoo_worker.boarding import assign
from collectoo_worker.boarding.transforms import (
    _DATE_SHAPES,
    TransformSpec,
    build_step,
    load_spec,
    transform_column,
)
from collectoo_worker.eba.catalogue import fields

MAX_DETAILS_PER_CODE = 1000  # per file and code; counts stay exact
CIVIL_CLAIM_TYPES = {"b2b_invoice", "b2c_invoice", "rent", "private_loan", "judgment_debt"}


@dataclass(frozen=True)
class Issue:
    file_id: str
    row: int | None  # 1-based data row; None = file-level
    column: str | None
    target: str | None
    code: str
    severity: str
    message: str
    value: str | None = None


def first_distinct(df: pl.DataFrame) -> pl.Series:
    """True for the first occurrence of each distinct row, False for later identical rows.

    Rows are hashed (8 bytes each) and compared in full only where hashes collide, so the
    result is exact and memory stays small on wide files (a struct of every column would copy
    the whole file).
    """
    hashes = df.hash_rows()
    candidates = hashes.is_duplicated()
    keep = pl.repeat(True, df.height, eager=True, dtype=pl.Boolean)
    if candidates.any():
        idx = candidates.arg_true()
        exact = df[idx].select(pl.struct(pl.all()).is_first_distinct()).to_series()
        keep = keep.scatter(idx, exact)
    return keep


@dataclass
class FileResult:
    file_id: str
    name: str
    raw: pl.DataFrame
    mapping: dict[str, str | None]  # source column -> target
    values: dict[str, pl.Series] = field(default_factory=dict)  # target -> typed column
    claim_types: list[str | None] = field(default_factory=list)
    legal_regimes: list[str | None] = field(default_factory=list)
    eba_table: str | None = None
    _first: pl.Series | None = field(default=None, repr=False)

    @property
    def rows(self) -> int:
        return self.raw.height

    def first_distinct(self) -> pl.Series:
        """Rows to board (duplicate rows are boarded once); computed once per file."""
        if self._first is None:
            self._first = first_distinct(self.raw)
        return self._first

    def column_for(self, target: str) -> str | None:
        return next((c for c, t in self.mapping.items() if t == target), None)

    def col(self, target: str, dtype: pl.DataType | None = None) -> pl.Series:
        """Typed column for a target; nulls of `dtype` (default text) when it is not mapped."""
        if target in self.values:
            return self.values[target]
        return pl.Series(target, [None] * self.rows, dtype=dtype or pl.Utf8())

    def raw_values(self, column: str | None) -> list[Any] | None:
        return self.raw[column].to_list() if column and column in self.raw.columns else None


@dataclass
class IssueLog:
    conformance: str = "servicing"
    issues: list[Issue] = field(default_factory=list)
    counts: Counter[tuple[str, str, str]] = field(default_factory=Counter)  # (file, code, severity)

    def _severity(self, code: str) -> str:
        if code == "eba_mandatory_missing" and self.conformance == "regulatory":
            return "blocking"
        return severity(code)

    def add(self, issue: Issue) -> None:
        self.add_rows(
            issue.file_id,
            [issue.row - 1] if issue.row else [],
            code=issue.code,
            message=issue.message,
            column=issue.column,
            target=issue.target,
            values=None if issue.value is None else {(issue.row or 1) - 1: issue.value},
            file_level=issue.row is None,
        )

    def add_rows(  # noqa: PLR0913 - one rule's outcome
        self,
        file_id: str,
        rows: list[int],
        *,
        code: str,
        message: str,
        column: str | None = None,
        target: str | None = None,
        values: dict[int, Any] | list[Any] | None = None,
        file_level: bool = False,
    ) -> None:
        """Record a rule failing on `rows` (0-based): exact count, details up to the cap."""
        sev = self._severity(code)
        key = (file_id, code, sev)
        if file_level:
            self.counts[key] += 1
            if self.counts[key] <= MAX_DETAILS_PER_CODE:
                self.issues.append(Issue(file_id, None, column, target, code, sev, message))
            return
        room = max(0, MAX_DETAILS_PER_CODE - self.counts[key])
        for i in rows[:room]:
            raw = values[i] if values is not None else None
            value = None if raw is None else str(raw)
            self.issues.append(Issue(file_id, i + 1, column, target, code, sev, message, value))
        self.counts[key] += len(rows)

    @property
    def blocking(self) -> int:
        return sum(n for (_, _, sev), n in self.counts.items() if sev == "blocking")


@cache
def rules(version: int = 1) -> dict[str, Any]:
    text = (
        resources.files("collectoo_worker.boarding.specs")
        .joinpath(f"validation.v{version}.yaml")
        .read_text()
    )
    raw: dict[str, Any] = yaml.safe_load(text)
    return raw


def severity(code: str) -> str:
    return str(rules()["severity"].get(code, "warning"))


def detect_eba_table(mapping: dict[str, str | None]) -> str | None:
    """Which EU-template table a file is, from the template prefix of its mapped targets."""
    prefixes = Counter(t.split("_")[0] for t in mapping.values() if t and t.startswith("eba.f"))
    if not prefixes:
        return None
    top = prefixes.most_common(1)[0][0]
    return {
        "eba.f1": "t1_counterparty",
        "eba.f2": "t2_1_borrower_loan",
        "eba.f3": "t3_loan",
        "eba.f4": "t4_1_protection",
        "eba.f5": "t5_collection",
    }.get(top)


def _rows(mask: pl.Series) -> list[int]:
    return mask.fill_null(False).arg_true().to_list()


# --- Transformation ---------------------------------------------------------------------------


def _chain_for(
    spec: TransformSpec, target: str, column_profile: dict[str, Any] | None
) -> list[Any]:
    """The spec's chain, adapted to the column: decimal mark detected by profiling."""
    chain = spec.chain_for(target)
    if column_profile and spec.target_types.get(target) == "amount":
        guess = column_profile.get("type_guess")
        mark = {"decimal_comma": ",", "decimal_dot": "."}.get(guess or "")
        if mark:
            raw = spec.overrides.get(target) or spec.defaults["amount"]
            adapted = [
                {"parse_decimal": {"decimal": mark}}
                if isinstance(s, dict) and "parse_decimal" in s
                else s
                for s in raw
            ]
            chain = [build_step(s) for s in adapted]
    return chain


def transform_file(
    result: FileResult, profile: dict[str, Any], log: IssueLog, spec: TransformSpec
) -> None:
    by_name = {c["name"]: c for c in profile.get("columns", [])}
    for column, target in result.mapping.items():
        if target is None or column not in result.raw.columns:
            continue
        col_profile = by_name.get(column)
        raw = result.raw[column]
        values, errors = transform_column(raw, _chain_for(spec, target, col_profile))
        result.values[target] = values
        by_code: dict[str, list[int]] = {}
        messages: dict[str, str] = {}
        for i, err in errors.items():
            by_code.setdefault(err.code, []).append(i)
            messages.setdefault(err.code, str(err))
        for code, rows in by_code.items():
            raw_vals = {i: raw[i] for i in rows[:MAX_DETAILS_PER_CODE]}
            log.add_rows(
                result.file_id,
                rows,
                code=code,
                message=messages[code],
                column=column,
                target=target,
                values=raw_vals,
            )
        if spec.target_types.get(target) == "date" and col_profile:
            _mixed_dates(result, column, target, col_profile, log)


def _mixed_dates(
    result: FileResult, column: str, target: str, col_profile: dict[str, Any], log: IssueLog
) -> None:
    shares = {k: v for k, v in col_profile.get("patterns", {}).items() if k in _DATE_SHAPES}
    if len(shares) < 2:
        return
    main = max(shares, key=lambda k: shares[k])
    text = result.raw[column].str.strip_chars()
    other = pl.Series([False] * result.rows)
    for k in _DATE_SHAPES:
        if k != main:
            other = other | text.str.contains(_DATE_SHAPES[k].pattern).fill_null(False)
    rows = _rows(other)
    log.add_rows(
        result.file_id,
        rows,
        code="mixed_date_format",
        message=f"date written in another format than the column ({main})",
        column=column,
        target=target,
        values={i: result.raw[column][i] for i in rows[:MAX_DETAILS_PER_CODE]},
    )


# --- Assignment ---------------------------------------------------------------------------


def assign_rows(result: FileResult, portfolio_default: str | None, log: IssueLog) -> None:
    n = result.rows
    if result.eba_table == "t3_loan":
        instr = result.col("eba.f3_06_type_of_instrument").to_list()
        asset = result.col("eba.f3_05_asset_class").to_list()
        dates = result.col("eba.f3_02_inception_date").to_list()
        cache_: dict[tuple[Any, Any], str | None] = {}
        types = []
        for i in range(n):
            key = (instr[i], asset[i])
            if key not in cache_:
                cache_[key] = assign.eba_claim_type(instr[i], asset[i], portfolio_default)[0]
            types.append(cache_[key])
    elif result.eba_table:
        return  # other EU-template tables carry no claim
    else:
        ct, _ = assign.file_claim_type({t for t in result.mapping.values() if t}, portfolio_default)
        types = [ct] * n
        dates = [None] * n
    regimes = [assign.legal_regime(types[i], dates[i]) for i in range(n)]
    result.claim_types, result.legal_regimes = types, regimes
    unassigned = [i for i in range(n) if types[i] is None]
    unknown = [i for i in range(n) if types[i] is not None and regimes[i] is None]
    log.add_rows(
        result.file_id,
        unassigned,
        code="unassigned_claim_type",
        message="no claim type rule matched this row",
    )
    log.add_rows(
        result.file_id,
        unknown,
        code="unknown_legal_regime",
        message="the contract date is needed to choose the consumer-credit legal regime",
    )


# --- Row and file rules -----------------------------------------------------------------


def _required(result: FileResult, log: IssueLog) -> None:
    req, rec = rules()["required"], rules()["recommended"]
    keys = pl.Series(
        [
            None if ct is None else (ct if ct in CIVIL_CLAIM_TYPES else "bank_credit")
            for ct in result.claim_types
        ],
        dtype=pl.Utf8,
    )
    for code, spec in (("missing_required", req), ("missing_recommended", rec)):
        for key, targets in spec.items():
            applies = keys == key
            if not applies.any():
                continue
            for target in targets:
                col = result.column_for(target)
                missing = result.col(target).is_null()
                if col is not None and target in result.values:
                    # A value that failed transformation already has its own issue.
                    raw = result.raw[col]
                    missing = missing & (raw.is_null() | (raw.str.strip_chars() == ""))
                log.add_rows(
                    result.file_id,
                    _rows(applies & missing),
                    code=code,
                    message=f"{target} is missing",
                    column=col,
                    target=target,
                )


def _duplicates(result: FileResult, log: IssueLog) -> pl.Series:
    dup = ~result.first_distinct()
    log.add_rows(
        result.file_id,
        _rows(dup),
        code="duplicate_row",
        message="identical to an earlier row; boarded once",
    )
    if {"account.external_ref", "claim_item.ref"} <= set(result.values):
        frame = pl.DataFrame(
            {"a": result.values["account.external_ref"], "d": result.values["claim_item.ref"]}
        )
        repeated = ~frame.select(pl.struct("a", "d").is_first_distinct()).to_series()
        complete = frame["a"].is_not_null() & frame["d"].is_not_null()
        rows = _rows(repeated & complete & ~dup)
        log.add_rows(
            result.file_id,
            rows,
            code="duplicate_document",
            message="the same document appears twice for this account",
            column=result.column_for("claim_item.ref"),
            target="claim_item.ref",
            values={i: frame["d"][i] for i in rows[:MAX_DETAILS_PER_CODE]},
        )
    return dup


def _amounts(result: FileResult, log: IssueLog) -> None:
    if "claim_item.amount" not in result.values:
        return
    amount = result.values["claim_item.amount"]
    paid = result.col("claim_item.amount_paid", pl.Int64())
    kind = result.col("claim_item.kind")
    col = result.column_for("claim_item.amount")
    negative = (amount < 0) & (kind.is_null() | (kind != "credit_note"))
    rows = _rows(negative)
    log.add_rows(
        result.file_id,
        rows,
        code="negative_amount",
        message="negative amount on a document that is not a credit note",
        column=col,
        target="claim_item.amount",
        values={i: result.raw[col][i] for i in rows[:MAX_DETAILS_PER_CODE]} if col else None,
    )
    overpaid = (amount > 0) & paid.is_not_null() & (paid > amount)
    log.add_rows(
        result.file_id,
        _rows(overpaid),
        code="overpaid",
        message="amount paid is greater than the amount due",
        column=result.column_for("claim_item.amount_paid"),
        target="claim_item.amount_paid",
    )


def _contacts(result: FileResult, log: IssueLog) -> None:
    if not ({"contact.email", "contact.phone"} & set(result.values)):
        return
    none = result.col("contact.email").is_null() & result.col("contact.phone").is_null()
    log.add_rows(
        result.file_id,
        _rows(none),
        code="missing_contact",
        message="no valid email or phone: postal contact only",
    )


def _eba_mandatory(result: FileResult, log: IssueLog, exempt: bool) -> None:
    if exempt or result.eba_table not in ("t1_counterparty", "t3_loan"):
        return
    template = "T1" if result.eba_table == "t1_counterparty" else "T3"
    individual = result.col("eba.f1_06_legal_type_of_counterparty") == "Households"
    for f in fields():
        if f.template_id != template or not f.mandatory or f.loan_type == "Secured":
            continue  # unsecured tapes only for now; secured checks come with collateral boarding
        target = f"eba.{f.column}"
        applies = pl.Series([True] * result.rows)
        if template == "T1" and f.borrower_type == "Private Individual":
            applies = individual.fill_null(False)
        elif template == "T1" and f.borrower_type == "Corporate":
            applies = ~individual.fill_null(False)
        missing = applies & result.col(target).is_null()
        log.add_rows(
            result.file_id,
            _rows(missing),
            code="eba_mandatory_missing",
            message=f"EU template mandatory field {f.field_id} {f.name} is empty",
            column=f.column if target in result.values else None,
            target=target,
        )


def _references(files: list[FileResult], join_keys: list[dict[str, Any]], log: IssueLog) -> None:
    eba = {f.eba_table: f for f in files if f.eba_table}
    links = [
        (
            "t2_1_borrower_loan",
            "eba.f2_00_counterparty_identifier",
            "t1_counterparty",
            "eba.f1_02_counterparty_identifier",
        ),
        ("t2_1_borrower_loan", "eba.f2_01_loan_identifier", "t3_loan", "eba.f3_01_loan_identifier"),
        ("t5_collection", "eba.f5_00_loan_identifier", "t3_loan", "eba.f3_01_loan_identifier"),
    ]
    for child_t, child_key, parent_t, parent_key in links:
        child, parent = eba.get(child_t), eba.get(parent_t)
        if child is None or parent is None or child_key not in child.values:
            continue
        values = child.values[child_key]
        broken = values.is_not_null() & ~values.is_in(parent.col(parent_key).drop_nulls().implode())
        rows = _rows(broken)
        log.add_rows(
            child.file_id,
            rows,
            code="broken_reference",
            message=f"not found in {parent.name}",
            column=child.column_for(child_key),
            target=child_key,
            values={i: values[i] for i in rows[:MAX_DETAILS_PER_CODE]},
        )
    by_id = {f.file_id: f for f in files}
    for jk in join_keys:
        members = [(by_id[fid], col) for fid, col in jk["columns"].items() if fid in by_id]
        parents = [(f, c) for f, c in members if f.raw[c].drop_nulls().is_unique().all()]
        if not parents:
            continue
        parent, pcol = parents[0]
        for f, col in members:
            if f is parent:
                continue
            raw = f.raw[col]
            broken = (
                raw.is_not_null()
                & (raw != "")
                & ~raw.is_in(parent.raw[pcol].drop_nulls().implode())
            )
            rows = _rows(broken)
            log.add_rows(
                f.file_id,
                rows,
                code="broken_reference",
                message=f"not found in {parent.name}",
                column=col,
                target=jk["target"],
                values={i: raw[i] for i in rows[:MAX_DETAILS_PER_CODE]},
            )


def validate_batch(  # noqa: PLR0913 - the batch's inputs
    files: list[FileResult],
    profiles: dict[str, dict[str, Any]],
    *,
    portfolio_default: str | None,
    conformance: str,
    art4_exempt: bool,
    join_keys: list[dict[str, Any]],
) -> IssueLog:
    log = IssueLog(conformance=conformance)
    spec = load_spec()
    for result in files:
        transform_file(result, profiles.get(result.file_id, {}), log, spec)
        assign_rows(result, portfolio_default, log)
        _required(result, log)
        _duplicates(result, log)
        _amounts(result, log)
        _contacts(result, log)
        _eba_mandatory(result, log, art4_exempt)
    _references(files, join_keys, log)
    return log
