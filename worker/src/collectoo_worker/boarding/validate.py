"""Transform and validate the files of a boarding batch (M1-11, M1-14, M1-15).

Input: each file's raw rows (all text), its approved mapping and its profile. Output: typed
values per target, claim type and legal regime per row, and validation issues (blocking or
warning) with the row number in the file. Nothing is written here; the job persists results.
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

MAX_DETAILS_PER_CODE = 1000  # per file; counts stay exact
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


@dataclass
class FileResult:
    file_id: str
    name: str
    raw: pl.DataFrame
    mapping: dict[str, str | None]  # source column -> target
    values: dict[str, list[Any]] = field(default_factory=dict)  # target -> typed values
    claim_types: list[str | None] = field(default_factory=list)
    legal_regimes: list[str | None] = field(default_factory=list)
    eba_table: str | None = None

    @property
    def rows(self) -> int:
        return self.raw.height

    def column_for(self, target: str) -> str | None:
        return next((c for c, t in self.mapping.items() if t == target), None)


@dataclass
class IssueLog:
    conformance: str = "servicing"
    issues: list[Issue] = field(default_factory=list)
    counts: Counter[tuple[str, str, str]] = field(default_factory=Counter)  # (file, code, severity)

    def add(self, issue: Issue) -> None:
        severity = issue.severity
        if issue.code == "eba_mandatory_missing" and self.conformance == "regulatory":
            severity = "blocking"
            issue = Issue(**{**issue.__dict__, "severity": severity})
        key = (issue.file_id, issue.code, severity)
        self.counts[key] += 1
        if self.counts[key] <= MAX_DETAILS_PER_CODE:
            self.issues.append(issue)

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
        values, errors = transform_column(result.raw[column], _chain_for(spec, target, col_profile))
        result.values[target] = values
        raw_values = result.raw[column].to_list()
        for i, err in errors.items():
            log.add(
                Issue(
                    result.file_id,
                    i + 1,
                    column,
                    target,
                    err.code,
                    severity(err.code),
                    str(err),
                    raw_values[i],
                )
            )
        if spec.target_types.get(target) == "date" and col_profile:
            _mixed_dates(result, column, target, col_profile=col_profile, raw=raw_values, log=log)


def _mixed_dates(  # noqa: PLR0913 - one column's context
    result: FileResult,
    column: str,
    target: str,
    *,
    col_profile: dict[str, Any],
    raw: list[Any],
    log: IssueLog,
) -> None:
    shares = {k: v for k, v in col_profile.get("patterns", {}).items() if k in _DATE_SHAPES}
    if len(shares) < 2:
        return
    main = max(shares, key=lambda k: shares[k])
    for i, v in enumerate(raw):
        if (
            v
            and not _DATE_SHAPES[main].match(v.strip())
            and any(p.match(v.strip()) for p in _DATE_SHAPES.values())
        ):
            log.add(
                Issue(
                    result.file_id,
                    i + 1,
                    column,
                    target,
                    "mixed_date_format",
                    severity("mixed_date_format"),
                    f"date written in another format than the column ({main})",
                    v,
                )
            )


# --- Assignment ---------------------------------------------------------------------------


def assign_rows(result: FileResult, portfolio_default: str | None, log: IssueLog) -> None:
    n = result.rows
    if result.eba_table == "t3_loan":
        instr = result.values.get("eba.f3_06_type_of_instrument", [None] * n)
        asset = result.values.get("eba.f3_05_asset_class", [None] * n)
        dates = result.values.get("eba.f3_02_inception_date", [None] * n)
        types = [assign.eba_claim_type(instr[i], asset[i], portfolio_default)[0] for i in range(n)]
    elif result.eba_table:
        return  # other EU-template tables carry no claim
    else:
        ct, _ = assign.file_claim_type({t for t in result.mapping.values() if t}, portfolio_default)
        types = [ct] * n
        dates = [None] * n
    regimes = [assign.legal_regime(types[i], dates[i]) for i in range(n)]
    result.claim_types, result.legal_regimes = types, regimes
    for i in range(n):
        if types[i] is None:
            log.add(
                Issue(
                    result.file_id,
                    i + 1,
                    None,
                    None,
                    "unassigned_claim_type",
                    severity("unassigned_claim_type"),
                    "no claim type rule matched this row",
                )
            )
        elif regimes[i] is None:
            log.add(
                Issue(
                    result.file_id,
                    i + 1,
                    None,
                    None,
                    "unknown_legal_regime",
                    severity("unknown_legal_regime"),
                    f"{types[i]}: the contract date is needed to choose the legal regime",
                )
            )


# --- Row and file rules -----------------------------------------------------------------


def _required(result: FileResult, log: IssueLog) -> None:
    req, rec = rules()["required"], rules()["recommended"]
    for i, ct in enumerate(result.claim_types):
        if ct is None:
            continue
        key = ct if ct in CIVIL_CLAIM_TYPES else "bank_credit"
        for code, targets in (
            ("missing_required", req.get(key, [])),
            ("missing_recommended", rec.get(key, [])),
        ):
            for target in targets:
                if result.values.get(target, [None] * result.rows)[i] is None:
                    col = result.column_for(target)
                    # A value that failed transformation already has its own issue.
                    if col and result.raw[col][i] not in (None, "") and target in result.values:
                        continue
                    log.add(
                        Issue(
                            result.file_id,
                            i + 1,
                            col,
                            target,
                            code,
                            severity(code),
                            f"{target} is missing",
                        )
                    )


def _duplicates(result: FileResult, log: IssueLog) -> None:
    dup = result.raw.select(~pl.struct(pl.all()).is_first_distinct()).to_series().to_list()
    for i, is_dup in enumerate(dup):
        if is_dup:
            log.add(
                Issue(
                    result.file_id,
                    i + 1,
                    None,
                    None,
                    "duplicate_row",
                    severity("duplicate_row"),
                    "identical to an earlier row; boarded once",
                )
            )
    refs = result.values.get("account.external_ref")
    docs = result.values.get("claim_item.ref")
    if refs and docs:
        seen: set[tuple[Any, Any]] = set()
        for i, key in enumerate(zip(refs, docs, strict=True)):
            if dup[i] or None in key:
                continue
            if key in seen:
                log.add(
                    Issue(
                        result.file_id,
                        i + 1,
                        result.column_for("claim_item.ref"),
                        "claim_item.ref",
                        "duplicate_document",
                        severity("duplicate_document"),
                        f"document {key[1]} appears twice for account {key[0]}",
                        str(key[1]),
                    )
                )
            seen.add(key)


def _amounts(result: FileResult, log: IssueLog) -> None:
    amount = result.values.get("claim_item.amount")
    if amount is None:
        return
    paid = result.values.get("claim_item.amount_paid", [None] * result.rows)
    kind = result.values.get("claim_item.kind", [None] * result.rows)
    col = result.column_for("claim_item.amount")
    for i, a in enumerate(amount):
        if a is None:
            continue
        if a < 0 and kind[i] != "credit_note":
            log.add(
                Issue(
                    result.file_id,
                    i + 1,
                    col,
                    "claim_item.amount",
                    "negative_amount",
                    severity("negative_amount"),
                    "negative amount on a document that is not a credit note",
                    str(result.raw[col][i]) if col else None,
                )
            )
        if paid[i] is not None and a > 0 and paid[i] > a:
            log.add(
                Issue(
                    result.file_id,
                    i + 1,
                    result.column_for("claim_item.amount_paid"),
                    "claim_item.amount_paid",
                    "overpaid",
                    severity("overpaid"),
                    "amount paid is greater than the amount due",
                )
            )


def _contacts(result: FileResult, log: IssueLog) -> None:
    if not ({"contact.email", "contact.phone"} & set(result.values)):
        return
    email = result.values.get("contact.email", [None] * result.rows)
    phone = result.values.get("contact.phone", [None] * result.rows)
    for i in range(result.rows):
        if email[i] is None and phone[i] is None:
            log.add(
                Issue(
                    result.file_id,
                    i + 1,
                    None,
                    None,
                    "missing_contact",
                    severity("missing_contact"),
                    "no valid email or phone: postal contact only",
                )
            )


def _eba_mandatory(result: FileResult, log: IssueLog, exempt: bool) -> None:
    if exempt or result.eba_table not in ("t1_counterparty", "t3_loan"):
        return
    template = "T1" if result.eba_table == "t1_counterparty" else "T3"
    legal = result.values.get("eba.f1_06_legal_type_of_counterparty", [None] * result.rows)
    for f in fields():
        if f.template_id != template or not f.mandatory or f.loan_type == "Secured":
            continue  # unsecured tapes only for now; secured checks come with collateral boarding
        target = f"eba.{f.column}"
        values = result.values.get(target)
        for i in range(result.rows):
            if template == "T1" and f.borrower_type != "Applicable to all":
                is_individual = legal[i] == "Households"
                if (f.borrower_type == "Private Individual") != is_individual:
                    continue
            if values is None or values[i] is None:
                log.add(
                    Issue(
                        result.file_id,
                        i + 1,
                        f.column if values is not None else None,
                        target,
                        "eba_mandatory_missing",
                        severity("eba_mandatory_missing"),
                        f"EU template mandatory field {f.field_id} {f.name} is empty",
                    )
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
        if child is None or parent is None:
            continue
        known = set(parent.values.get(parent_key, []))
        for i, v in enumerate(child.values.get(child_key, [])):
            if v is not None and v not in known:
                log.add(
                    Issue(
                        child.file_id,
                        i + 1,
                        child.column_for(child_key),
                        child_key,
                        "broken_reference",
                        severity("broken_reference"),
                        f"{v} not found in {parent.name}",
                        str(v),
                    )
                )
    by_id = {f.file_id: f for f in files}
    for jk in join_keys:
        members = [(by_id[fid], col) for fid, col in jk["columns"].items() if fid in by_id]
        parents = [(f, c) for f, c in members if f.raw[c].drop_nulls().is_unique().all()]
        if not parents:
            continue
        parent, pcol = parents[0]
        known = set(parent.raw[pcol].to_list())
        for f, col in members:
            if f is parent:
                continue
            for i, v in enumerate(f.raw[col].to_list()):
                if v and v not in known:
                    log.add(
                        Issue(
                            f.file_id,
                            i + 1,
                            col,
                            jk["target"],
                            "broken_reference",
                            severity("broken_reference"),
                            f"{v} not found in {parent.name}",
                            v,
                        )
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
