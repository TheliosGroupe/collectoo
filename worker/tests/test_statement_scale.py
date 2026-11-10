"""The statement's files at the design's scale (§19: « Statement CSV / PDF — 50k rows / ≤ 2,000 file
rows — < 2 s / < 15 s »): a 50,000-line payload over 2,000 files, the CSV of every line and the PDF
with its 2,000-file table. A guard with generous bounds, so that a regression shows before the scale
run; the measured figures are in docs/benchmarks/remittances.md."""

from __future__ import annotations

import hashlib
import time

from document_cases import COLUMNS, statement_payload

from collectoo_worker.remittance.statement import PDF_FILE_ROWS_MAX
from collectoo_worker.remittance.statement_csv import render_statement_csv
from collectoo_worker.remittance.statement_pdf import render_statement_pdf

LINES = 50_000
FILES = PDF_FILE_ROWS_MAX
CSV_BOUND_S = 10.0  # measured ≈ 1.3 s (14.6 MB)
PDF_BOUND_S = 60.0  # measured ≈ 1.6 s for 2,000 file rows


def _big_payload() -> dict[str, object]:
    p = statement_payload()
    template = dict(zip(COLUMNS, p["lines"][0], strict=True))
    lines = []
    for i in range(LINES):
        v = dict(template)
        f = i % FILES
        v.update(
            line_no=i + 1,
            file=f"L-{f:05d}",
            debtor=f"Débiteur n° {f} SARL",
            amount_minor=str(10_000 + i),
            basis_minor=str(10_000 + i),
            commission_minor=str((10_000 + i) * 15 // 100),
            receipt=f"Q-2026-{i + 1:06d}",
        )
        lines.append([v[c] for c in COLUMNS])
    p["lines"] = lines
    p["files"] = [
        {"file": f"L-{f:05d}", "debtor": f"Débiteur n° {f} SARL", "lines": "25",
         "amount_minor": "1234567", "commission_minor": "185185", "late": "0"}
        for f in range(FILES)
    ]  # fmt: skip
    return p


def test_a_50k_line_statement_renders_within_the_targets() -> None:
    p = _big_payload()
    t0 = time.monotonic()
    data = render_statement_csv(p)
    t1 = time.monotonic()
    pdf = render_statement_pdf(p, hashlib.sha256(data).hexdigest())
    t2 = time.monotonic()
    assert data.count(b"\r\n") == LINES + 1
    assert pdf.startswith(b"%PDF-")
    print(
        f"\n{LINES} lines, {FILES} files: CSV {t1 - t0:.2f}s ({len(data) / 1e6:.1f} MB), "
        f"PDF {t2 - t1:.2f}s ({len(pdf) / 1e6:.1f} MB)"
    )
    assert t1 - t0 < CSV_BOUND_S
    assert t2 - t1 < PDF_BOUND_S
