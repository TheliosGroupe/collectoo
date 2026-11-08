"""Build the EU NPL transaction data template field catalogue.

Source of truth: EUR-Lex HTML of Implementing Regulation (EU) 2023/2083, Annex II
(data glossary). The EBA Excel annexes (final draft ITS, Dec 2022) are parsed only
to log differences. French labels come from the FR EUR-Lex HTML.

Usage (from repo root):
    uv run --with beautifulsoup4 --with lxml --with openpyxl \
        python -I tools/eba_catalogue/build_catalogue.py
Outputs:
    docs/reference/eba_field_catalogue.csv
    docs/reference/eba_field_catalogue.json
    docs/reference/eba_excel_vs_eurlex_diff.md
"""
from __future__ import annotations

import csv
import json
import re
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")
from bs4 import BeautifulSoup  # noqa: E402
import openpyxl  # noqa: E402

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
SRC = ROOT / "docs/reference/eba"
OUT = ROOT / "docs/reference"

TEMPLATE_IDS = {"1": "T1", "2": "T2", "3": "T3", "4": "T4", "5": "T5"}
FIELD_TYPES = ["Boolean", "Choice", "Date", "Alphanumeric", "Percentage", "Number"]


def norm_index(raw: str) -> str:
    """'1,00' / '1.00' / '4' -> '1.00' style."""
    s = raw.strip().replace(",", ".").replace(" ", "")
    if re.fullmatch(r"\d+", s):
        s += ".00"
    if re.fullmatch(r"\d+\.\d", s):
        s += "0"
    return s


def clean(s: str) -> str:
    return re.sub(r"\s+", " ", s or "").strip()


def base_type(ft: str, has_choices: bool = False) -> str:
    low = ft.lower()
    if has_choices:
        return "Choice"
    if "dd/mm/yyyy" in low:
        return "Date"
    if not low:
        return "Unspecified"
    for t in FIELD_TYPES:
        if low.startswith(t.lower()):
            return t
    if "choice" in low:
        return "Choice"
    if "date" in low:
        return "Date"
    return "Unknown"


def code_list(ft: str) -> str:
    m = re.search(r"(ISO[ \d\-]*\d(?: ALPHA-2| alpha-2)?|UN/LOCODE|NACE)", ft, re.I)
    return m.group(1).strip() if m else ""


def parse_choices(cell) -> list[str]:
    """Choices are nested tables of '(a)' | 'label' rows inside the field-type cell."""
    out = []
    for t in cell.find_all("table"):
        for tr in t.find_all("tr"):
            tds = tr.find_all("td")
            if len(tds) >= 2:
                label = clean(tds[1].get_text(" ", strip=True)).rstrip(";.,")
                out.append(label)
    return out


def parse_eurlex(path: Path) -> list[dict]:
    soup = BeautifulSoup(path.read_text(encoding="utf-8"), "lxml")
    target = None
    for t in soup.find_all("table"):
        body = t.find("tbody") or t
        rows = body.find_all("tr", recursive=False)
        if rows and len(rows[0].find_all(["td", "th"], recursive=False)) == 13 and len(rows) > 100:
            target = rows
            break
    if target is None:
        raise SystemExit(f"Annex II table not found in {path}")
    header = [clean(c.get_text(" ", strip=True)) for c in target[0].find_all(["td", "th"], recursive=False)]
    fields = []
    for tr in target[1:]:
        cells = tr.find_all(["td", "th"], recursive=False)
        vals = [clean(c.get_text(" ", strip=True)) for c in cells]
        ft_cell = cells[7]
        # field-type text without nested choice tables
        ft_copy = BeautifulSoup(str(ft_cell), "lxml")
        for nested in ft_copy.find_all("table"):
            nested.decompose()
        ft_text = clean(ft_copy.get_text(" ", strip=True))
        fields.append(
            {
                "field_id": norm_index(vals[0]),
                "template": vals[1],
                "field_name": vals[2],
                "borrower_type": vals[3],
                "loan_type": vals[4],
                "definition": vals[5],
                "mandatory": vals[6],
                "field_type_raw": ft_text,
                "choices": parse_choices(ft_cell),
                "ref_esma_rts_2020_1224": vals[8],
                "ref_anacredit": vals[9],
                "ref_finrep": vals[10],
                "ref_crr": vals[11],
                "ref_ias_ifrs": vals[12],
                "_header": header,
            }
        )
    return fields


def parse_excel(path: Path) -> dict[str, dict]:
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    ws = wb["Data glossary"]
    out = {}
    for row in ws.iter_rows(min_row=3, values_only=True):
        if not row or row[0] is None or not re.match(r"^\s*\d", str(row[0])):
            continue
        fid = norm_index(f"{row[0]}")
        out[fid] = {
            "template": clean(str(row[1] or "")),
            "field_name": clean(str(row[2] or "")),
            "borrower_type": clean(str(row[3] or "")),
            "loan_type": clean(str(row[4] or "")),
            "definition": clean(str(row[5] or "")),
            "mandatory": clean(str(row[6] or "")),
            "field_type_raw": clean(str(row[7] or "")),
        }
    return out


JSON_TYPES = {
    "Alphanumeric": {"type": "string"},
    "Number": {"type": "string", "pattern": r"^-?\d+(\.\d{1,2})?$", "description": "Decimal, 2 dp (Annex III Part 1 §3); kept as string to avoid floats"},
    "Percentage": {"type": "string", "pattern": r"^-?\d+(\.\d{1,2})?$", "description": "Ratio, 2 dp"},
    "Date": {"type": "string", "pattern": r"^\d{2}/\d{2}/\d{4}$", "description": "DD/MM/YYYY"},
    "Boolean": {"enum": ["Yes", "No"]},
    "Unspecified": {"type": "string"},
}


def write_json_schema(rows: list[dict]) -> None:
    """Generated typed model: one JSON Schema object per template (language-agnostic;
    the worker and frontend generate their own types from it)."""
    defs: dict = {}
    for r in rows:
        tpl = r["template_id"]
        d = defs.setdefault(tpl, {"type": "object", "title": r["template"], "properties": {}, "required": []})
        if r["data_type"] == "Choice" and r["allowed_values"]:
            schema = {"enum": r["allowed_values"].split(" | ")}
        elif r["data_type"] == "Choice":
            schema = {"type": "string", "description": f"Code list: {r['code_list'] or r['field_type_raw']}"}
        else:
            schema = dict(JSON_TYPES[r["data_type"]])
        schema["title"] = r["field_name"]
        schema["x-eba-field-id"] = r["field_id"]
        schema["x-borrower-type"] = r["borrower_type"]
        schema["x-loan-type"] = r["loan_type"]
        schema["x-mandatory"] = r["mandatory"] == "Y"
        d["properties"][f"f{r['field_id'].replace('.', '_')}"] = schema
        # 'required' is conditional (borrower/loan type, Art. 4(1) exemptions): enforced by
        # boarding validation rules, not by the schema.
    doc = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://collectoo.local/schemas/eba-npl-template-2023-2083.json",
        "title": "EU NPL transaction data templates, Implementing Regulation (EU) 2023/2083",
        "$defs": defs,
    }
    (OUT / "eba_template.schema.json").write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")


def main() -> None:
    en = parse_eurlex(SRC / "CELEX_32023R2083_EN.html")
    fr = {f["field_id"]: f for f in parse_eurlex(SRC / "CELEX_32023R2083_FR.html")}
    xl = parse_excel(SRC / "EBA_ITS_2022_05_Annex2_glossary.xlsx")

    rows = []
    extension_slots = [f for f in en if not re.fullmatch(r"\d+\.\d+", f["field_id"])]
    en = [f for f in en if re.fullmatch(r"\d+\.\d+", f["field_id"])]
    for f in en:
        fid = f["field_id"]
        tpl = TEMPLATE_IDS.get(fid.split(".")[0], "?")
        if tpl == "T4" and f["template"].lower().startswith("mortgage"):
            tpl = "T4.2"
        elif tpl == "T4":
            tpl = "T4.1"
        mand = f["mandatory"].strip().lower().startswith("mandatory")
        rows.append(
            {
                "template_id": tpl,
                "template": f["template"],
                "field_id": fid,
                "field_name": f["field_name"],
                "field_name_fr": fr.get(fid, {}).get("field_name", ""),
                "definition": f["definition"],
                "data_type": base_type(f["field_type_raw"], bool(f["choices"])),
                "code_list": code_list(f["field_type_raw"]),
                "field_type_raw": f["field_type_raw"],
                "allowed_values": " | ".join(f["choices"]),
                "borrower_type": f["borrower_type"],
                "loan_type": f["loan_type"],
                "mandatory": "Y" if mand else "N",
                "ref_esma_rts_2020_1224": f["ref_esma_rts_2020_1224"],
                "ref_anacredit": f["ref_anacredit"],
                "ref_finrep": f["ref_finrep"],
                "ref_crr": f["ref_crr"],
                "ref_ias_ifrs": f["ref_ias_ifrs"],
                "source": "EUR-Lex 32023R2083 Annex II",
            }
        )

    cols = list(rows[0].keys())
    with open(OUT / "eba_field_catalogue.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    (OUT / "eba_field_catalogue.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8"
    )

    write_json_schema(rows)

    # Diff Excel vs EUR-Lex, matched by (template number, normalised field name)
    def key(fid: str, name: str) -> tuple[str, str]:
        return fid.split(".")[0], re.sub(r"[^a-z0-9]", "", name.lower())

    lines = [
        "# EBA Excel (final draft ITS, Dec 2022) vs EUR-Lex 2023/2083 Annex II",
        "",
        "_Generated by `tools/eba_catalogue/build_catalogue.py`. EUR-Lex prevails; the catalogue uses EUR-Lex only._",
        "",
        "Fields are matched by template number and field name (indexes shift between the two versions).",
        "",
    ]
    def keyed(items):
        """Add an occurrence counter so repeated names (e.g. 'National identifier') stay distinct."""
        seen: dict = {}
        out = {}
        for fid, payload, name in items:
            k = key(fid, name)
            seen[k] = seen.get(k, 0) + 1
            out[k + (seen[k],)] = payload
        return out

    xl_sorted = sorted(
        ((i, v) for i, v in xl.items() if re.fullmatch(r"\d+\.\d+", i)),
        key=lambda iv: tuple(int(p) for p in iv[0].split(".")),
    )
    xl_by_key = keyed((i, (i, v), v["field_name"]) for i, v in xl_sorted)
    en_by_key = keyed((r["field_id"], r, r["field_name"]) for r in rows)
    only_xl = [xl_by_key[k] for k in xl_by_key if k not in en_by_key]
    only_en = [en_by_key[k] for k in en_by_key if k not in xl_by_key]
    lines += [
        f"- Fields in EUR-Lex: **{len(rows)}** (plus {len(extension_slots)} `x.xx` extension slots, Annex III Part 1 §4, not catalogued).",
        f"- Fields in Excel glossary: **{len(xl_by_key)}**.",
        "",
        "## Only in Excel (dropped from the adopted regulation; not catalogued)",
        "",
    ]
    lines += [f"- `{i}` {v['field_name']}" for i, v in only_xl] or ["- none"]
    lines += ["", "## Only in EUR-Lex (added in the adopted regulation)", ""]
    lines += [f"- `{r['field_id']}` {r['field_name']}" for r in only_en] or ["- none"]
    lines += ["", "## Matched fields with different attributes", "", "| EUR-Lex ID | Excel ID | Field | Attribute | Excel | EUR-Lex |", "|---|---|---|---|---|---|"]
    n = 0
    for k, r in en_by_key.items():
        if k not in xl_by_key:
            continue
        xi, a = xl_by_key[k]
        diffs = []
        if xi != r["field_id"]:
            diffs.append(("index", xi, r["field_id"]))
        for attr in ["borrower_type", "loan_type"]:
            if a[attr].lower().rstrip(". ") != r[attr].lower().rstrip(". "):
                diffs.append((attr, a[attr] or "—", r[attr] or "—"))
        am = "Mandatory" if a["mandatory"].lower().startswith("mandatory") else "—"
        rm = "Mandatory" if r["mandatory"] == "Y" else "—"
        if am != rm:
            diffs.append(("mandatory", am, rm))
        at = base_type(a["field_type_raw"], a["field_type_raw"].lower().startswith("choice"))
        if at != r["data_type"]:
            diffs.append(("data_type", at, r["data_type"]))
        if re.sub(r"\W", "", a["definition"].lower()) != re.sub(r"\W", "", r["definition"].lower()):
            diffs.append(("definition", "wording differs", "wording differs"))
        for attr, va, vb in diffs:
            if attr == "index":
                continue
            lines.append(f"| `{r['field_id']}` | `{xi}` | {r['field_name']} | {attr} | {va} | {vb} |")
            n += 1
    if n == 0:
        lines.append("| — | — | — | — | — | — |")
    shifted = sum(1 for k, r in en_by_key.items() if k in xl_by_key and xl_by_key[k][0] != r["field_id"])
    lines += ["", f"Index shifts: {shifted} matched fields have a different index in the Excel."]
    (OUT / "eba_excel_vs_eurlex_diff.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"catalogue: {len(rows)} fields; excel: {len(xl_by_key)}; only_excel={len(only_xl)} only_eurlex={len(only_en)} attr_diffs={n} shifted={shifted}")


if __name__ == "__main__":
    main()
