"""M1-04 readers and M1-05 profiling against the M0-17 messy files and their manifests."""

import json
from pathlib import Path

import polars as pl
import pytest

from collectoo_worker.boarding.profile import profile_frame
from collectoo_worker.boarding.readers import (
    FixedWidthColumn,
    read_fixed_width,
    read_xlsx,
    scan_csv,
    sniff_csv,
)
from collectoo_worker.synth.civil import DIALECTS, KINDS, write_civil
from collectoo_worker.synth.ids import luhn_valid

EXPECTED = {"fr_semicolon": ";", "en_comma": ",", "tab_dotted": "\t"}


@pytest.mark.parametrize("dialect", DIALECTS)
def test_csv_dialects_are_sniffed_and_read(tmp_path: Path, dialect: str) -> None:
    path = write_civil("b2b_invoice", dialect, 120, 3, tmp_path)  # type: ignore[arg-type]
    sniffed = sniff_csv(path)
    assert sniffed.separator == EXPECTED[dialect]
    assert sniffed.has_bom == (dialect == "fr_semicolon")
    lf, _ = scan_csv(path)
    df = lf.collect()
    assert df.height == 120
    assert all(dtype == pl.Utf8 for dtype in df.schema.values())
    manifest = json.loads(path.with_suffix(".manifest.json").read_text())
    assert df.columns == list(manifest["columns"].values())  # BOM stripped from the first header


def test_latin1_files_are_transcoded(tmp_path: Path) -> None:
    path = tmp_path / "export.csv"
    path.write_bytes(
        "Société;Échéance;Montant\nCrêperie Hélène;05/01/2026;12,50\n".encode("cp1252")
    )
    sniffed = sniff_csv(path)
    assert sniffed.encoding == "cp1252"
    df = scan_csv(path)[0].collect()
    assert df.columns == ["Société", "Échéance", "Montant"]
    assert df.row(0) == ("Crêperie Hélène", "05/01/2026", "12,50")


def test_xlsx_reads_every_sheet_as_text(tmp_path: Path) -> None:
    path = tmp_path / "tape.xlsx"
    import xlsxwriter  # type: ignore[import-untyped]  # noqa: PLC0415

    with xlsxwriter.Workbook(path) as wb:
        sheets_data: dict[str, list[list[str | float]]] = {
            "Débiteurs": [["ref", "nom"], ["C1", "Durand"]],
            "Factures": [["n", "montant"], ["F1", 12.5]],
        }
        for name, rows in sheets_data.items():
            ws = wb.add_worksheet(name)
            for r, row in enumerate(rows):
                ws.write_row(r, 0, row)
    sheets = read_xlsx(path)
    assert set(sheets) == {"Débiteurs", "Factures"}
    assert sheets["Factures"].row(0) == ("F1", "12.5")


def test_fixed_width_layout(tmp_path: Path) -> None:
    path = tmp_path / "tape.dat"
    path.write_text("REF   NOM       MONTANT\nA0001 DURAND    0001250\nA0002 MARTIN    0009900\n")
    layout = [
        FixedWidthColumn("ref", 0, 5),
        FixedWidthColumn("nom", 6, 15),
        FixedWidthColumn("montant", 16, 23),
    ]
    df = read_fixed_width(path, layout, skip_header_lines=1)
    assert df.to_dicts() == [
        {"ref": "A0001", "nom": "DURAND", "montant": "0001250"},
        {"ref": "A0002", "nom": "MARTIN", "montant": "0009900"},
    ]


def test_50k_row_csv_streams(tmp_path: Path) -> None:
    row = "C1234;Durand SARL;123456782;durand@example.org;01/02/2026;1 234,56\n"
    path = tmp_path / "big.csv"
    with path.open("w", encoding="utf-8") as fh:
        fh.write("client;nom;siren;email;echeance;montant\n")
        fh.writelines(row for _ in range(50_000))
    lf, _ = scan_csv(path)
    assert lf.select(pl.len()).collect(engine="streaming").item() == 50_000
    profile = profile_frame(lf)
    assert profile["row_count"] == 50_000
    cols = {c["name"]: c for c in profile["columns"]}
    assert cols["echeance"]["type_guess"] == "date_fr"
    assert cols["montant"]["type_guess"] == "decimal_comma"
    assert cols["siren"]["type_guess"] == "siren"


@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("dialect", DIALECTS)
def test_profile_detects_every_injected_defect(tmp_path: Path, kind: str, dialect: str) -> None:
    from collectoo_worker.synth.civil import generate_civil  # noqa: PLC0415

    table, manifest = generate_civil(kind, dialect, 600, 21, defect_rate=0.2)  # type: ignore[arg-type]
    path = tmp_path / "f.csv"
    sep = str(manifest["delimiter"])
    path.write_text(
        "\n".join(sep.join(f'"{v}"' if sep in v else v for v in r) for r in table) + "\n"
    )
    profile = profile_frame(scan_csv(path)[0])
    h: dict[str, str] = manifest["columns"]  # type: ignore[assignment]
    cols = {c["name"]: c for c in profile["columns"]}
    defect_list: list[dict[str, object]] = manifest["defects"]  # type: ignore[assignment]
    defects = [str(d["type"]) for d in defect_list]
    count = {t: defects.count(t) for t in set(defects)}

    assert profile["row_count"] == manifest["rows"]
    if count.get("duplicate_row"):
        assert profile["duplicate_rows"] == count["duplicate_row"]
    if count.get("missing_contact"):
        assert cols[h["email"]]["non_null"] <= manifest["rows"] - count["missing_contact"]  # type: ignore[operator]
    if count.get("invalid_siren"):
        col = table[0].index(h["siren"])
        actual = sum(1 for r in table[1:] if not luhn_valid(r[col]))  # duplicates copy defects
        assert cols[h["siren"]]["issues"]["luhn_invalid"] == actual >= count["invalid_siren"]
    due = cols[h["due_date"]]
    if count.get("impossible_date"):
        assert due["issues"]["impossible_dates"] >= count["impossible_date"]
    if count.get("mixed_date_format"):
        assert "date_iso" in due["issues"]["mixed_date_formats"]
    if count.get("negative_amount"):
        assert cols[h["amount"]]["issues"]["negatives"] >= count["negative_amount"]
    assert cols[h["amount"]]["type_guess"] == (
        "decimal_dot" if dialect == "en_comma" else "decimal_comma"
    )
