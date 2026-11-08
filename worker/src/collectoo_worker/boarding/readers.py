"""Tape readers (M1-04): CSV (encoding and separator sniffing), XLSX (all sheets), fixed width.

Every column is read as text: types are decided by profiling and transformations, never by a
reader guessing. CSVs are scanned lazily so large tapes stream instead of loading in memory.
"""

from __future__ import annotations

import codecs
import csv
import tempfile
from dataclasses import dataclass
from pathlib import Path

import polars as pl

SAMPLE_BYTES = 256 * 1024
SEPARATORS = (";", ",", "\t", "|")


@dataclass(frozen=True)
class CsvDialect:
    encoding: str  # python codec name of the source file
    separator: str
    has_bom: bool


def sniff_encoding(sample: bytes) -> tuple[str, bool]:
    """UTF-8 (with or without BOM) or Windows-1252, the usual French accounting exports."""
    if sample.startswith(codecs.BOM_UTF8):
        return "utf-8", True
    try:
        # A multi-byte character may be cut at the end of the sample: ignore the last 3 bytes.
        sample[:-3].decode("utf-8") if len(sample) == SAMPLE_BYTES else sample.decode("utf-8")
    except UnicodeDecodeError:
        return "cp1252", False
    return "utf-8", False


def sniff_separator(text: str) -> str:
    """The candidate that splits the first lines into the same, largest number of fields."""
    lines = [line for line in text.splitlines()[:50] if line.strip()]
    best, best_score = ",", (-1, -1)
    for sep in SEPARATORS:
        counts = [len(next(csv.reader([line], delimiter=sep))) for line in lines]
        if not counts or counts[0] < 2:
            continue
        consistent = sum(1 for c in counts if c == counts[0])
        score = (consistent, counts[0])
        if score > best_score:
            best, best_score = sep, score
    return best


def sniff_csv(path: Path) -> CsvDialect:
    with path.open("rb") as fh:
        sample = fh.read(SAMPLE_BYTES)
    encoding, bom = sniff_encoding(sample)
    text = sample.decode(encoding, errors="ignore")
    return CsvDialect(encoding=encoding, separator=sniff_separator(text), has_bom=bom)


def _utf8_copy(path: Path, encoding: str) -> Path:
    """Polars reads UTF-8 only: transcode other encodings in streaming chunks."""
    out = Path(tempfile.mkstemp(suffix=".csv")[1])
    with (
        path.open("r", encoding=encoding, newline="") as src,
        out.open("w", encoding="utf-8", newline="") as dst,
    ):
        while chunk := src.read(1 << 20):
            dst.write(chunk)
    return out


def scan_csv(path: Path, dialect: CsvDialect | None = None) -> tuple[pl.LazyFrame, CsvDialect]:
    dialect = dialect or sniff_csv(path)
    source = path if dialect.encoding == "utf-8" else _utf8_copy(path, dialect.encoding)
    lf = pl.scan_csv(
        source,
        separator=dialect.separator,
        infer_schema=False,  # every column as text
        encoding="utf8",
        truncate_ragged_lines=True,
    )
    if dialect.has_bom:
        first = lf.collect_schema().names()[0]
        lf = lf.rename({first: first.lstrip("﻿")})
    return lf, dialect


def read_xlsx(path: Path) -> dict[str, pl.DataFrame]:
    """Every sheet, all columns as text."""
    # Empty sheets (notes, covers) are common: read them as empty tables instead of failing.
    sheets = pl.read_excel(path, sheet_id=0, infer_schema_length=0, raise_if_empty=False)
    return {name: df.with_columns(pl.all().cast(pl.Utf8)) for name, df in sheets.items()}


@dataclass(frozen=True)
class FixedWidthColumn:
    name: str
    start: int  # 0-based, inclusive
    end: int  # exclusive


def read_fixed_width(
    path: Path, layout: list[FixedWidthColumn], encoding: str = "utf-8", skip_header_lines: int = 0
) -> pl.DataFrame:
    """Fixed-width file described by a layout spec; values are stripped, empty means null."""
    data: dict[str, list[str | None]] = {c.name: [] for c in layout}
    with path.open("r", encoding=encoding) as fh:
        for i, line in enumerate(fh):
            if i < skip_header_lines or not line.strip():
                continue
            for c in layout:
                value = line[c.start : c.end].strip()
                data[c.name].append(value or None)
    return pl.DataFrame(data, schema={c.name: pl.Utf8 for c in layout})
