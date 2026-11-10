"""The statement's PDF (design §10; template `releve-reversement-fr-1`): the header and the seven
sections of `statement.statement_view`, with the per-file table up to 2,000 files (above that, the
CSV's SHA-256 for the detail). Deterministic: the bytes are a function of the payload and the CSV's
hash (`remittance.pdf`: reportlab pinned, invariant mode, DejaVu Sans, the PDF dated K, never the
clock).
"""

from __future__ import annotations

# isort: off
from collectoo_worker.payments import reportlab_defaults  # noqa: F401 - first: reportlab's own defaults
# isort: on

import hashlib
from collections.abc import Mapping
from typing import Any

from reportlab.lib.units import mm
from reportlab.platypus import Flowable, Spacer, Table, TableStyle

from collectoo_worker.remittance import pdf
from collectoo_worker.remittance.statement import TEMPLATE_VERSION, known_at, statement_view


def render_statement_pdf(payload: Mapping[str, Any], csv_sha256: str) -> bytes:
    v = statement_view(payload, csv_sha256)
    s = pdf.styles()
    w = pdf.FRAME_WIDTH
    story: list[Flowable] = []
    header = Table(
        [
            [pdf.p(v.title, s["title"]), pdf.p(v.number_line, s["right_bold"])],
            ["", pdf.p(v.issued_line, s["right"])],
            ["", pdf.p(v.known_line, s["right"])],
        ],
        colWidths=[w * 0.55, w * 0.45],
    )
    header.setStyle(
        TableStyle(
            [
                ("SPAN", (0, 0), (0, 2)),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("LINEBELOW", (0, 2), (-1, 2), 0.6, pdf.LINE),
                ("BOTTOMPADDING", (0, 2), (-1, 2), 6),
            ]
        )
    )
    story += [header, Spacer(1, 3 * mm)]
    story += [pdf.p(line, s["small"]) for line in v.issuer_lines]
    story.append(Spacer(1, 3 * mm))
    story += [pdf.p(line, s["base"]) for line in v.client_lines]
    story += [pdf.p(line, s["label"]) for line in v.mandate_lines]
    story.append(pdf.p(v.period_line, s["label"]))
    for section in v.sections:
        story += [Spacer(1, 4 * mm), pdf.p(section.title, s["h2"]), Spacer(1, 1 * mm)]
        story += [pdf.p(t, s["base"]) for t in section.texts]
        if section.rows:
            story.append(Spacer(1, 1 * mm))
            story.append(pdf.pairs([pdf.Row(a, b) for a, b in section.rows], s))
        if section.table is not None:
            head, rows = section.table
            story.append(Spacer(1, 2 * mm))
            story.append(pdf.grid(head, rows, (0.22, 0.38, 0.1, 0.15, 0.15), (2, 3, 4), s))
        if section.note:
            story += [Spacer(1, 1.5 * mm), pdf.p(section.note, s["small"])]
    return pdf.build(
        story,
        known_at(payload),
        title=f"Relevé de reversement {payload['number']}",
        author=str(payload["issuer"]["name"]),
        subject=v.title,
        creator=TEMPLATE_VERSION,
        footer=v.footer,
    )


def pdf_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
