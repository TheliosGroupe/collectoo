"""Staging (M1-17): turn validated files into rows per operational entity.

Civil and commercial files (one account per client account reference, founder decision):
  party (the debtor), contact, account, claim_item (one per document or rent period).
EU-template tapes: party (T1), account (T3), account_party (T2.1), claim_item (legal balance,
3.12) and the typed Layer-1 rows (eba.*).

Rows are built column-wise with Polars and kept typed (a `key` column plus the data columns);
they are JSON-encoded chunk by chunk while being loaded with COPY into
`private.boarding_staging`, so a 1M-loan tape never holds its JSON in memory at once.
Duplicate rows are staged once. Re-running gives identical rows.
"""

from __future__ import annotations

import hashlib
import io
from collections.abc import Iterator
from typing import Any

import polars as pl
import psycopg

from collectoo_worker.boarding.validate import FileResult, IssueLog

EBA_TABLES = (
    "t1_counterparty",
    "t2_1_borrower_loan",
    "t3_loan",
    "t4_1_protection",
    "t4_2_mortgage",
    "t5_collection",
)
CAPACITY = {"b2b_invoice": "legal_entity", "professional_loan": "legal_entity"}


CHUNK_ROWS = 100_000


def _json(df: pl.DataFrame, key: pl.Expr, data_cols: list[str]) -> pl.DataFrame:
    """Typed staging rows: `key` then the data columns (encoded to JSON when written)."""
    return df.select(key.cast(pl.Utf8).alias("key"), *data_cols)


def _keep(df: pl.DataFrame, mask: pl.Series) -> pl.DataFrame:
    """Drop duplicate rows; no copy when there are none (the usual case on large tapes)."""
    return df if mask.all() else df.filter(mask)


def encode(rows: pl.DataFrame) -> pl.DataFrame:
    """(key, data JSON) for typed staging rows."""
    return rows.select("key", pl.struct(pl.exclude("key")).struct.json_encode().alias("data"))


def _civil(f: FileResult) -> dict[str, pl.DataFrame]:
    keep = f.first_distinct()
    n = f.rows

    def c(target: str, dtype: pl.DataType | None = None) -> pl.Series:
        return f.col(target, dtype).rename(target.split(".", 1)[1])

    claim_types = pl.Series("claim_type", f.claim_types or [None] * n, dtype=pl.Utf8)
    df = _keep(
        pl.DataFrame(
            [
                c("account.external_ref"),
                c("party.display_name"),
                c("party.first_name"),
                c("party.siren"),
                c("party.siret"),
                c("party.iban"),
                c("contact.email"),
                c("contact.phone"),
                c("contact.address_line"),
                c("contact.postcode"),
                c("contact.city"),
                c("claim_item.kind").rename("doc_kind"),
                c("claim_item.ref").rename("doc_ref"),
                c("claim_item.issue_date", pl.Date()),
                c("claim_item.due_date", pl.Date()),
                c("claim_item.amount", pl.Int64()),
                c("claim_item.amount_paid", pl.Int64()),
                c("claim_item.currency"),
                c("claim_item.period"),
                claim_types,
                pl.Series("legal_regime", f.legal_regimes or [None] * n, dtype=pl.Utf8),
            ]
        ),
        keep,
    )
    is_company = pl.col("claim_type").eq("b2b_invoice") | pl.col("siren").is_not_null()
    parties = (
        df.group_by("external_ref", maintain_order=True)
        .agg(pl.all().drop_nulls().first())
        .with_columns(
            pl.when(is_company)
            .then(pl.lit("legal_entity"))
            .otherwise(pl.lit("natural_person"))
            .alias("kind"),
            pl.when(~is_company & pl.col("first_name").is_not_null())
            .then(pl.concat_str(["display_name", "first_name"], separator=" "))
            .otherwise(pl.col("display_name"))
            .alias("display_name"),
            pl.col("external_ref").alias("seller_ref"),
            pl.col("claim_type").replace_strict(CAPACITY, default="consumer").alias("capacity"),
            pl.col("currency").fill_null("EUR"),
        )
    )
    party = _json(
        parties,
        pl.col("seller_ref"),
        ["seller_ref", "display_name", "first_name", "kind", "siren", "siret", "iban"],
    )
    account = _json(
        parties,
        pl.col("external_ref"),
        ["external_ref", "claim_type", "legal_regime", "currency", "capacity"],
    )
    contacts = []
    for typ, col in (("email", "email"), ("phone", "phone")):
        contacts.append(
            df.filter(pl.col(col).is_not_null())
            .select(
                pl.col("external_ref").alias("party_key"),
                pl.lit(typ).alias("type"),
                pl.col(col).alias("value"),
            )
            .unique(maintain_order=True)
        )
    contacts.append(
        df.filter(pl.col("address_line").is_not_null())
        .select(
            pl.col("external_ref").alias("party_key"),
            pl.lit("postal").alias("type"),
            pl.concat_str(
                ["address_line", "postcode", "city"], separator=" ", ignore_nulls=True
            ).alias("value"),
        )
        .unique(maintain_order=True)
    )
    contact = _json(pl.concat(contacts), pl.col("party_key"), ["party_key", "type", "value"])
    items = df.with_columns(
        pl.col("external_ref").alias("account_key"),
        pl.when(pl.col("period").is_not_null())
        .then(pl.lit("rent_period"))
        .when(pl.col("doc_kind") == "credit_note")
        .then(pl.lit("credit_note"))
        .otherwise(pl.lit("invoice"))
        .alias("kind"),
        pl.coalesce("doc_ref", "period", pl.col("due_date").cast(pl.Utf8)).alias("ref"),
        pl.col("amount").abs().alias("original_minor"),
        pl.col("amount_paid").fill_null(0).alias("seller_paid_minor"),
        pl.col("currency").fill_null("EUR"),
    ).filter(pl.col("original_minor").is_not_null())
    claim_item = _json(
        items,
        pl.col("account_key"),
        [
            "account_key",
            "kind",
            "ref",
            "issue_date",
            "due_date",
            "original_minor",
            "seller_paid_minor",
            "currency",
        ],
    )
    return {"party": party, "contact": contact, "account": account, "claim_item": claim_item}


def _eba(files: list[FileResult]) -> dict[str, pl.DataFrame]:
    out: dict[str, pl.DataFrame] = {}
    by_table = {f.eba_table: f for f in files if f.eba_table}
    t1, t3, t21 = (
        by_table.get("t1_counterparty"),
        by_table.get("t3_loan"),
        by_table.get("t2_1_borrower_loan"),
    )
    for table, f in by_table.items():
        cols = [
            s.rename(t.removeprefix("eba.")) for t, s in f.values.items() if t.startswith("eba.")
        ]
        if table == "t5_collection" and "month_offset" in f.raw.columns:
            cols.append(f.raw["month_offset"].cast(pl.Int32))
        source_row = pl.int_range(1, f.rows + 1, eager=True).alias("source_row")
        # Built from the typed columns directly: no copy of the file's data.
        rows = pl.DataFrame([source_row.cast(pl.Utf8).alias("key"), *cols, source_row])
        out[f"eba.{table}"] = _keep(rows, f.first_distinct())
    if t1 is not None:
        p = pl.DataFrame(
            {
                "seller_ref": t1.col("eba.f1_02_counterparty_identifier"),
                "display_name": t1.col("eba.f1_03_name_of_counterparty"),
                "kind": t1.col("eba.f1_06_legal_type_of_counterparty").replace_strict(
                    {"Households": "natural_person"}, default="legal_entity"
                ),
                "birth_date": t1.col("eba.f1_07_date_of_birth", pl.Date()),
                "siren": t1.col("eba.f1_10_national_identifier").str.extract(r"^(\d{9})$"),
            }
        ).unique("seller_ref", keep="first", maintain_order=True)
        out["party"] = _json(p, pl.col("seller_ref"), p.columns)
    if t3 is not None:
        a = pl.DataFrame(
            {
                "external_ref": t3.col("eba.f3_01_loan_identifier"),
                "claim_type": pl.Series(t3.claim_types, dtype=pl.Utf8),
                "legal_regime": pl.Series(t3.legal_regimes, dtype=pl.Utf8),
                "currency": t3.col("eba.f3_08_currency").fill_null("EUR"),
                "contract_date": t3.col("eba.f3_02_inception_date", pl.Date()),
                "seller_limitation_date": t3.col(
                    "eba.f3_29_statute_of_limitations_date", pl.Date()
                ),
                "legal_balance": t3.col("eba.f3_12_legal_balance"),
            }
        ).unique("external_ref", keep="first", maintain_order=True)
        out["account"] = _json(
            a,
            pl.col("external_ref"),
            [
                "external_ref",
                "claim_type",
                "legal_regime",
                "currency",
                "contract_date",
                "seller_limitation_date",
            ],
        )
        items = a.filter(pl.col("legal_balance").is_not_null()).select(
            pl.col("external_ref").alias("account_key"),
            pl.lit("loan_principal").alias("kind"),
            pl.col("external_ref").alias("ref"),
            (pl.col("legal_balance").cast(pl.Decimal(38, 2)) * 100)
            .cast(pl.Int64)
            .alias("original_minor"),
            pl.lit(0).alias("seller_paid_minor"),
            pl.col("currency"),
        )
        out["claim_item"] = _json(items, pl.col("account_key"), items.columns)
    if t21 is not None and t1 is not None:
        kinds = dict(
            zip(
                t1.col("eba.f1_02_counterparty_identifier").to_list(),
                t1.col("eba.f1_06_legal_type_of_counterparty").to_list(),
                strict=True,
            )
        )
        links = (
            pl.DataFrame(
                {
                    "account_key": t21.col("eba.f2_01_loan_identifier"),
                    "party_key": t21.col("eba.f2_00_counterparty_identifier"),
                }
            )
            .unique(maintain_order=True)
            .with_columns(
                pl.col("party_key")
                .replace_strict(kinds, default=None)
                .replace_strict({"Households": "consumer"}, default="legal_entity")
                .alias("capacity"),
                pl.lit("borrower").alias("role"),
            )
        )
        out["account_party"] = _json(links, pl.col("account_key"), links.columns)
    return out


def stage_rows(files: list[FileResult], log: IssueLog) -> dict[str, pl.DataFrame]:
    """Typed rows to stage per entity (`key` + data columns)."""
    del log  # blocking issues stop the batch before staging; warnings do not remove rows
    staged: dict[str, list[pl.DataFrame]] = {}
    civil = [f for f in files if f.eba_table is None]
    for f in civil:
        for entity, df in _civil(f).items():
            staged.setdefault(entity, []).append(df)
    for entity, df in _eba([f for f in files if f.eba_table]).items():
        staged.setdefault(entity, []).append(df)
    return {
        entity: pl.concat(dfs, how="diagonal_relaxed") if len(dfs) > 1 else dfs[0]
        for entity, dfs in staged.items()
    }


def _chunks(staged: dict[str, pl.DataFrame]) -> Iterator[tuple[str, pl.DataFrame]]:
    """(entity, encoded chunk) in a fixed order: entities sorted, rows in staging order."""
    for entity in sorted(staged):
        for part in staged[entity].iter_slices(n_rows=CHUNK_ROWS):
            yield entity, encode(part)


class _Digest:
    def __init__(self) -> None:
        self.rows: dict[str, int] = {}
        self.hashes: dict[str, Any] = {}

    def update(self, entity: str, chunk: pl.DataFrame) -> None:
        h = self.hashes.setdefault(entity, hashlib.sha256())
        self.rows[entity] = self.rows.get(entity, 0) + chunk.height
        line = pl.concat_str(
            [pl.col("key").fill_null(""), pl.lit("\x1f"), pl.col("data"), pl.lit("\x1e")]
        )
        h.update("".join(chunk.select(line).to_series().to_list()).encode())

    def result(self, staged: dict[str, pl.DataFrame]) -> dict[str, Any]:
        empty = hashlib.sha256().hexdigest()
        return {
            e: {
                "rows": self.rows.get(e, 0),
                "sha256": self.hashes[e].hexdigest() if e in self.hashes else empty,
            }
            for e in sorted(staged)
        }


def staging_digest(staged: dict[str, pl.DataFrame]) -> dict[str, Any]:
    """Row counts and a content hash per entity (re-running staging must give the same)."""
    digest = _Digest()
    for entity, chunk in _chunks(staged):
        digest.update(entity, chunk)
    return digest.result(staged)


def write_staging(
    conn: psycopg.Connection[Any], batch_id: str, staged: dict[str, pl.DataFrame]
) -> dict[str, Any]:
    """Replace the batch's staging rows; returns the staging digest."""
    conn.execute("delete from private.boarding_staging where batch_id = %s", (batch_id,))
    digest = _Digest()
    with (
        conn.cursor() as cur,
        cur.copy(
            "copy private.boarding_staging (batch_id, entity, key, data) from stdin (format csv)"
        ) as copy,
    ):
        for entity, chunk in _chunks(staged):
            digest.update(entity, chunk)
            buf = io.BytesIO()
            chunk.select(
                pl.lit(batch_id).alias("batch_id"), pl.lit(entity).alias("entity"), "key", "data"
            ).write_csv(buf, include_header=False)
            copy.write(buf.getvalue())
    return digest.result(staged)
