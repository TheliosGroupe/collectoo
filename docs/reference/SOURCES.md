# Reference sources

Retrieved 2026-11-07 (UTC) with `curl --retry 4` from this cloud session. Files are stored unmodified in `docs/reference/eba/`.

| File | What | URL | SHA-256 |
|---|---|---|---|
| `CELEX_32023R2083_EN.html` | Implementing Regulation (EU) 2023/2083, EN, full text incl. Annexes I–III (**binding source of truth**) | https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32023R2083 | `1998450e28408202757ec4fbefa110ac7d79f68386a9d37cfacd7cb22fb376bb` |
| `CELEX_32023R2083_EN.pdf` | Same, OJ PDF (43 pages) | https://eur-lex.europa.eu/legal-content/EN/TXT/PDF/?uri=CELEX:32023R2083 | `21bad9834d18477376e40a5e19502db4f0de9e75d4df9a4f21045e1839e3a1f5` |
| `CELEX_32023R2083_FR.html` | Same, French version (used for `field_name_fr`) | https://eur-lex.europa.eu/legal-content/FR/TXT/HTML/?uri=CELEX:32023R2083 | `b12ee5283c0aefca5cecc7144d4309fba984bf36d2f65e9d13f67d378fa74e20` |
| `CELEX_32023R2083_FR.pdf` | Same, French OJ PDF | https://eur-lex.europa.eu/legal-content/FR/TXT/PDF/?uri=CELEX:32023R2083 | `483f35b713c030edab322ae16d3338045d478eb2b28824de94bbee76b7a18adc` |
| `EBA_ITS_2022_05_Annex1_templates.xlsx` | EBA final draft ITS (EBA/ITS/2022/05), Annex 1 templates | https://www.eba.europa.eu/sites/default/files/document_library/Publications/Draft%20Technical%20Standards/2022/EBA-ITS-2022-05%20ITS%20on%20NPL%20transaction%20data%20templates/1045967/Annex%201%20-%20Draft%20ITS%20on%20NPL%20transaction%20data%20templates.xlsx | `ce52ba306a1f10f9a25868942c0b57c6de5459e569b4ae2574edcba5c5883bf3` |
| `EBA_ITS_2022_05_Annex2_glossary.xlsx` | EBA final draft ITS, Annex 2 data glossary | https://www.eba.europa.eu/sites/default/files/document_library/Publications/Draft%20Technical%20Standards/2022/EBA-ITS-2022-05%20ITS%20on%20NPL%20transaction%20data%20templates/1045965/Annex%202%20-%20Draft%20ITS%20on%20NPL%20transaction%20data%20templates.xlsx | `35185a2b38f6c62c8c132b0caf83e66fca7fc8ac9639cd788eab2c6114289f82` |
| `EBA_ITS_2022_05_Final_report.pdf` | EBA final report on the draft ITS (Dec 2022) | https://www.eba.europa.eu/sites/default/files/document_library/Publications/Draft%20Technical%20Standards/2022/EBA-ITS-2022-05%20ITS%20on%20NPL%20transaction%20data%20templates/1045969/Final%20report%20on%20draft%20ITS%20on%20NPL%20transaction%20data%20templates.pdf | `a8e6728ae7c64471653bc4a8c9d38302f8657e8e0aa58991cc0f51d1deb1a2d1` |

EBA landing page: https://www.eba.europa.eu/legacy/regulation-and-policy/regulatory-activities/credit-risk/implementing-technical-standards-npl

Not retrieved: Commission documents register C(2023)6306 (fallback only). `ec.europa.eu` timed out; not needed since EUR-Lex has all annexes.

## Derived files (regenerate with `tools/eba_catalogue/build_catalogue.py`)

- `eba_field_catalogue.csv` / `.json`: 135 fields from EUR-Lex Annex II (the 5 `x.xx` extension slots of Annex III Part 1 §4 are excluded).
- `eba_template.schema.json`: generated typed model (JSON Schema, one object per template).
- `eba_excel_vs_eurlex_diff.md`: differences between the EBA Excel and EUR-Lex. EUR-Lex prevails.

## Notes on the catalogue

- "Mandatory/optional per portfolio type": the regulation expresses this with three columns, `mandatory`, `borrower_type` (Corporate / Private Individual / all) and `loan_type` (Secured / all), plus Art. 4(1)(a)–(f), which exempts some transactions (single-borrower sales, syndicated loans, non-EU borrowers, intra-group, loans acquired from non-CRR entities, unsecured consumer loans outside Directive 2008/48/EC) from the mandatory fields. No other per-portfolio rule exists in the text.
- Field `4.12 Year of construction` has an empty field type in EUR-Lex (catalogued as `Unspecified`).
- Choice fields populated from code lists (ISO 4217, ISO 3166, NACE, UN/LOCODE, ISO 17442) have the list in `code_list`, not `allowed_values`.
