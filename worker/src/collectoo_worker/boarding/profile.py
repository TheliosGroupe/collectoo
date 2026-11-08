"""Column profiling (M1-05): what each column looks like, before any mapping.

The profile feeds the mapping proposal (M1-08), the review UI and the data-quality report. It is
JSON-serialisable and stored in `boarding_file.profile`.
"""

from __future__ import annotations

import datetime as dt
import re
from typing import Any

import polars as pl

from collectoo_worker.synth.ids import iban_valid, luhn_valid

# Order matters for the type guess: the first pattern reaching the threshold wins.
PATTERNS: dict[str, str] = {
    "date_fr": r"^\d{2}/\d{2}/\d{4}$",
    "date_iso": r"^\d{4}-\d{2}-\d{2}$",
    "date_dotted": r"^\d{2}\.\d{2}\.\d{4}$",
    "siret": r"^\d{14}$",
    "siren": r"^\d{9}$",
    "postcode_fr": r"^\d{5}$",
    "iban": r"^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$",
    "email": r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$",
    "phone_fr": r"^(\+33|0033|0)\s?[1-9]([ .-]?\d{2}){4}$",
    "integer": r"^-?\d+$",
    "decimal_comma": r"^-?\d{1,3}([ \u00a0\u202f.]\d{3})*,\d+$|^-?\d+,\d+$",
    "decimal_dot": r"^-?\d+\.\d+$",
}
DATE_FORMATS = {"date_fr": "%d/%m/%Y", "date_iso": "%Y-%m-%d", "date_dotted": "%d.%m.%Y"}
TYPE_THRESHOLD = 0.8
TOP_VALUES = 5
SAMPLE_ROWS = 5


def _clean(lf: pl.LazyFrame) -> pl.LazyFrame:
    """Trim every column; empty strings become nulls."""
    return lf.with_columns(pl.all().str.strip_chars().replace("", None))


def _impossible_dates(values: list[str], fmt: str) -> int:
    bad = 0
    for v in values:
        try:
            dt.datetime.strptime(v, fmt)  # noqa: DTZ007 - calendar validity check only
        except ValueError:
            bad += 1
    return bad


def profile_frame(lf: pl.LazyFrame) -> dict[str, Any]:
    lf = _clean(lf)
    names = lf.collect_schema().names()
    exprs: list[pl.Expr] = [pl.len().alias("__rows")]
    for c in names:
        col = pl.col(c)
        exprs += [col.null_count().alias(f"{c}|nulls"), col.n_unique().alias(f"{c}|distinct")]
        exprs += [col.str.contains(rx).sum().alias(f"{c}|p|{p}") for p, rx in PATTERNS.items()]
        # Loose date-like shape (dd?mm?yyyy) to catch impossible dates such as 31/02.
        exprs.append(col.str.contains(r"^-").sum().alias(f"{c}|negatives"))
    stats = lf.select(exprs).collect(engine="streaming").row(0, named=True)
    rows = int(stats["__rows"])
    # Extra copies of an identical row (a row present 3 times counts 2).
    distinct_rows = lf.select(pl.struct(names).n_unique()).collect(engine="streaming").item()
    duplicate_rows = rows - int(distinct_rows)
    columns = []
    for c in names:
        non_null = rows - int(stats[f"{c}|nulls"])
        patterns = {p: int(stats[f"{c}|p|{p}"]) for p in PATTERNS if stats[f"{c}|p|{p}"]}
        shares = {p: round(n / non_null, 4) for p, n in patterns.items()} if non_null else {}
        guess = next((p for p in PATTERNS if shares.get(p, 0) >= TYPE_THRESHOLD), "text")
        info: dict[str, Any] = {
            "name": c,
            "non_null": non_null,
            "null_pct": round(1 - non_null / rows, 4) if rows else 0.0,
            "distinct": int(stats[f"{c}|distinct"]),
            "patterns": shares,
            "type_guess": guess,
            "issues": {},
        }
        _column_checks(lf, info, int(stats[f"{c}|negatives"]))
        columns.append(info)
    top = _top_values(lf, names)
    for info in columns:
        info["top_values"] = top[info["name"]]
    sample = lf.head(SAMPLE_ROWS).collect().to_dicts()
    return {
        "row_count": rows,
        "duplicate_rows": duplicate_rows,
        "columns": columns,
        "sample": sample,
    }


def _column_checks(lf: pl.LazyFrame, info: dict[str, Any], negatives: int) -> None:
    c, guess, shares = info["name"], info["type_guess"], info["patterns"]
    issues: dict[str, Any] = info["issues"]
    date_kinds = [p for p in DATE_FORMATS if shares.get(p)]
    loose_date = re.compile(r"^\d{1,4}[/.-]\d{1,2}[/.-]\d{1,4}$")
    if date_kinds:
        if len(date_kinds) > 1:
            issues["mixed_date_formats"] = {p: shares[p] for p in date_kinds}
        main = max(date_kinds, key=lambda p: shares[p])
        counts = (
            lf.select(pl.col(c).drop_nulls())
            .group_by(c)
            .agg(pl.len().alias("n"))
            .collect(engine="streaming")
            .rows()
        )
        main_rx = re.compile(PATTERNS[main])
        known = [re.compile(PATTERNS[p]) for p in DATE_FORMATS]
        impossible = 0
        for value, n in counts:
            if main_rx.match(value):
                impossible += n * _impossible_dates([value], DATE_FORMATS[main])
            elif loose_date.match(value) and not any(k.match(value) for k in known):
                impossible += n  # date-shaped but in no known format
        if impossible:
            issues["impossible_dates"] = impossible
    if guess in ("siren", "siret"):
        values = lf.select(pl.col(c).drop_nulls()).collect().to_series().to_list()
        bad = sum(1 for v in values if v.isdigit() and not luhn_valid(v))
        if bad:
            issues["luhn_invalid"] = bad
    if guess == "iban":
        values = lf.select(pl.col(c).drop_nulls()).collect().to_series().to_list()
        bad = sum(1 for v in values if not iban_valid(v))
        if bad:
            issues["iban_invalid"] = bad
    if guess in ("integer", "decimal_comma", "decimal_dot") and negatives:
        issues["negatives"] = negatives


def _top_values(lf: pl.LazyFrame, names: list[str]) -> dict[str, list[dict[str, Any]]]:
    out = {}
    for c in names:
        counts = (
            lf.select(pl.col(c).drop_nulls())
            .group_by(c)
            .agg(pl.len().alias("count"))
            .sort(["count", c], descending=[True, False])
            .head(TOP_VALUES)
            .collect(engine="streaming")
        )
        out[c] = [{"value": r[c], "count": int(r["count"])} for r in counts.to_dicts()]
    return out
