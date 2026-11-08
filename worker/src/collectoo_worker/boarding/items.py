"""Claim items of a batch: ONE definition shared by validation, the DQ report and staging.

The three must agree to the cent: the opening balances posted at confirmation are checked
against the DQ report's reconciled total (M2-05, docs/design/m2a-ledger.md §7.3-7.4).

Civil and commercial files, one item per source row that has an amount (exact duplicate rows
are boarded once):
- kind: `credit_note` when the mapped document kind says so or the amount is negative, else
  `rent_period` when a period is given, else `invoice`;
- amounts: `original_minor` = |amount|; signed -|amount| for a credit note, +amount otherwise;
  `seller_paid_minor` = the amount paid or 0; outstanding = signed - paid (negative for a credit
  note or an overpaid invoice);
- ref: the document number, else one derived from the period or the due date (ISO). Derived
  refs that collide for the same account and kind get `#2`, `#3`, … across the batch, in
  batch order (file order, then row order): rent and charges of the same month stay two items,
  in one file or in two (founder decision 2026-11-08 #7). Only the same row sent again in
  another file (identical in every mapped value) gets the same ref, so a file sent twice is
  counted once. Rows are compared through a 64-bit hash of their mapped values: a collision
  could only merge two rows of the same account, kind and period/due date, and would then be
  reported (`duplicate_document` or `conflicting_document`), never dropped silently;
- an item with no document number, period or due date has no ref: it is blocking
  (`missing_required`) and, until fixed, counted like a derived one (each row once, the same
  row sent again in another file once);
- identity: (account, kind, ref) across all civil files of the batch, in batch order. Later
  rows with the same identity are never staged: identical (amount, paid, currency, due date)
  → `duplicate_document` (warning), different → `conflicting_document` (blocking).

EU-template tapes: one loan per loan identifier (3.01), its first distinct T3 row. Another,
different row with the same identifier is a blocking `duplicate_loan`. Amounts 3.09-3.12 are
exact decimal strings, converted with `money.to_minor_units` (half-up) wherever they are used.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from decimal import Decimal
from typing import TYPE_CHECKING

import polars as pl

from collectoo_worker.money import to_minor_units

if TYPE_CHECKING:
    from collectoo_worker.boarding.validate import FileResult

DEFAULT_CURRENCY = "EUR"
IDENTITY = ("account_key", "kind", "ref")
CONTENT = ("original_minor", "seller_paid_minor", "currency", "due_date")  # duplicate vs conflict
ITEM_SCHEMA = {
    "file_id": pl.Utf8(),
    "row": pl.Int64(),  # 0-based row in its file
    "account_key": pl.Utf8(),
    "kind": pl.Utf8(),
    "ref": pl.Utf8(),
    "issue_date": pl.Date(),
    "due_date": pl.Date(),
    "original_minor": pl.Int64(),
    "seller_paid_minor": pl.Int64(),
    "currency": pl.Utf8(),
    "signed_minor": pl.Int64(),
    "outstanding_minor": pl.Int64(),
}
EBA_AMOUNTS = {  # column of the loans frame -> EU-template target
    "p309": "eba.f3_09_principal_amount",
    "p310": "eba.f3_10_accrued_interest",
    "p311": "eba.f3_11_other_balances",
    "p312": "eba.f3_12_legal_balance",
}


def _typed(f: FileResult, target: str, dtype: pl.DataType) -> pl.Series:
    """A target's typed column; an unmapped or all-invalid column is nulls of `dtype`."""
    return f.col(target, dtype).cast(dtype)


def _content(f: FileResult, targets: Mapping[str, pl.DataType]) -> pl.Series:
    """Per row, a hash of its mapped values (null for a target this file does not map), with the
    same columns and types in every file of the batch, so comparable across them."""
    if not targets:
        return pl.repeat(0, f.rows, eager=True, dtype=pl.UInt64)
    columns = [f.col(t, dtype).cast(dtype, strict=False).alias(t) for t, dtype in targets.items()]
    return pl.DataFrame(columns).hash_rows()


def _file_items(f: FileResult, targets: Mapping[str, pl.DataType]) -> pl.DataFrame:
    amount = _typed(f, "claim_item.amount", pl.Int64())
    frame = pl.DataFrame(
        [
            pl.repeat(f.file_id, f.rows, eager=True, dtype=pl.Utf8).alias("file_id"),
            pl.int_range(0, f.rows, eager=True, dtype=pl.Int64).alias("row"),
            _typed(f, "account.external_ref", pl.Utf8()).alias("account_key"),
            _typed(f, "claim_item.kind", pl.Utf8()).alias("doc_kind"),
            _typed(f, "claim_item.ref", pl.Utf8()).alias("doc_ref"),
            _typed(f, "claim_item.period", pl.Utf8()).alias("period"),
            _typed(f, "claim_item.issue_date", pl.Date()).alias("issue_date"),
            _typed(f, "claim_item.due_date", pl.Date()).alias("due_date"),
            amount.alias("amount"),
            _typed(f, "claim_item.amount_paid", pl.Int64()).alias("paid"),
            _typed(f, "claim_item.currency", pl.Utf8()).alias("currency"),
            _content(f, targets).alias("content"),
        ]
    ).filter(f.first_distinct() & amount.is_not_null())
    credit = (pl.col("doc_kind") == "credit_note").fill_null(False) | (pl.col("amount") < 0)
    kind = (
        pl.when(credit)
        .then(pl.lit("credit_note"))
        .when(pl.col("period").is_not_null())
        .then(pl.lit("rent_period"))
        .otherwise(pl.lit("invoice"))
    )
    original = pl.col("amount").abs()
    return (
        frame.with_columns(
            kind.alias("kind"),
            pl.coalesce("doc_ref", "period", pl.col("due_date").cast(pl.Utf8)).alias("base"),
            pl.col("doc_ref").is_null().alias("numbered"),  # no document number
            original.alias("original_minor"),
            pl.col("paid").fill_null(0).alias("seller_paid_minor"),
            pl.col("currency").fill_null(DEFAULT_CURRENCY),
        )
        .with_columns(
            pl.when(pl.col("kind") == "credit_note")
            .then(-pl.col("original_minor"))
            .otherwise(pl.col("original_minor"))
            .alias("signed_minor"),
        )
        .with_columns(
            (pl.col("signed_minor") - pl.col("seller_paid_minor")).alias("outstanding_minor"),
        )
    )


def _numbered(items: pl.DataFrame) -> pl.DataFrame:
    """Refs of the items without a document number, numbered across the batch.

    A slot is (account, kind, base, row content, occurrence of that content in its file): two
    different rows of one file are always two slots; the same row in a later file is the same
    slot. New slots of an (account, kind, base) are numbered in batch order; `new` marks the
    first row of each slot.
    """
    group = ("account_key", "kind", "base", "numbered")
    slot = (*group, "content", "occurrence")
    items = (
        items.with_columns(
            pl.int_range(1, pl.len() + 1).over("file_id", *group, "content").alias("occurrence")
        )
        .with_columns(pl.struct(*slot).is_first_distinct().alias("new"))
        .with_columns(pl.col("new").cast(pl.Int64).cum_sum().over(*group).alias("nth"))
        .with_columns(pl.col("nth").first().over(*slot))  # a repeated slot: its first number
    )
    nth = pl.col("nth")
    suffixed = pl.concat_str([pl.col("base"), pl.lit("#"), nth.cast(pl.Utf8)])
    return items.with_columns(
        pl.when(pl.col("numbered") & pl.col("base").is_not_null() & (nth > 1))
        .then(suffixed)
        .otherwise(pl.col("base"))
        .alias("ref")
    )


def civil_items(files: Sequence[FileResult]) -> pl.DataFrame:
    """Every candidate item of the civil files, in batch order (file order, then row order).

    `first` marks the item staged for its identity; `duplicate` and `conflict` mark later rows
    with the same identity (never staged).
    """
    civil = [f for f in files if f.eba_table is None]
    flags = {"first": pl.Boolean(), "duplicate": pl.Boolean(), "conflict": pl.Boolean()}
    if not civil:
        return pl.DataFrame(schema={**ITEM_SCHEMA, **flags})
    targets: dict[str, pl.DataType] = {}
    for f in civil:
        for target, values in f.values.items():
            targets.setdefault(target, values.dtype)
    targets = dict(sorted(targets.items()))
    items = _numbered(pl.concat([_file_items(f, targets) for f in civil], how="vertical"))
    no_ref = pl.col("ref").is_null()
    # No ref (blocking): one item per slot, so nothing is dropped from the report meanwhile.
    first = pl.when(no_ref).then(pl.col("new")).otherwise(pl.struct(*IDENTITY).is_first_distinct())
    same = no_ref | pl.all_horizontal(
        pl.col(c).eq_missing(pl.col(c).first().over(*IDENTITY)) for c in CONTENT
    )
    return items.with_columns(first.alias("first")).select(
        *ITEM_SCHEMA,
        "first",
        (~pl.col("first") & same).alias("duplicate"),
        (~pl.col("first") & ~same).alias("conflict"),
    )


def staged_items(files: Sequence[FileResult]) -> pl.DataFrame:
    """The civil items staged (and counted in the DQ report): one per identity."""
    return civil_items(files).filter(pl.col("first"))


def eba_loans(t3: FileResult) -> pl.DataFrame:
    """The distinct rows of a T3 loan tape: `row` (0-based), `loan_id`, `currency` (upper-cased,
    EUR when empty), `p309`…`p312` (exact decimal strings) and `first` (the row staged for its
    loan identifier; a later one is a `duplicate_loan`)."""
    currency = _typed(t3, "eba.f3_08_currency", pl.Utf8()).str.to_uppercase()
    frame = pl.DataFrame(
        [
            pl.int_range(0, t3.rows, eager=True, dtype=pl.Int64).alias("row"),
            _typed(t3, "eba.f3_01_loan_identifier", pl.Utf8()).alias("loan_id"),
            currency.fill_null(DEFAULT_CURRENCY).alias("currency"),
            *(_typed(t3, target, pl.Utf8()).alias(name) for name, target in EBA_AMOUNTS.items()),
        ]
    ).filter(t3.first_distinct())
    return frame.with_columns(pl.col("loan_id").is_first_distinct().alias("first"))


def minor_units(values: pl.Series) -> list[int | None]:
    """Exact decimal strings (major units) -> minor units, half-up; None stays None."""
    return [None if v is None else to_minor_units(Decimal(v)) for v in values.to_list()]


def has_sub_cent(value: str) -> bool:
    """True when the amount has non-zero digits below the cent (so it gets rounded)."""
    d = Decimal(value)
    return d * 100 != to_minor_units(d)
