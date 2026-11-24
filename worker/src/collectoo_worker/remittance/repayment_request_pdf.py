"""The PDF of a « Demande de remboursement d'avance » (M2c-7c-2; plan §5.3; template
`demande-remboursement-avance-fr-1`): `repayment_request.request_view` drawn on A4 by the shared
machinery (`remittance.pdf`: reportlab pinned, invariant mode, DejaVu Sans, no compression).
Deterministic: bytes = f(the request's number, issue date and frozen payload, the template and
renderer versions), dated by its issue date, never by the clock.
"""

from __future__ import annotations

# isort: off
from collectoo_worker.payments import reportlab_defaults  # noqa: F401 - first: reportlab's own defaults
# isort: on

import hashlib
from typing import Any

from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import Flowable, Spacer, Table, TableStyle

from collectoo_worker.remittance import pdf
from collectoo_worker.remittance.repayment_request import (
    RepaymentRequestDocument,
    RequestView,
    issued_at,
    request_view,
)


def render_request_pdf(doc: RepaymentRequestDocument) -> bytes:
    v = request_view(doc)
    s = pdf.styles()
    w = pdf.FRAME_WIDTH
    story: list[Flowable] = []
    parties = Table(
        [
            [
                [pdf.p("Émetteur", s["label"]), *(pdf.p(x, s["base"]) for x in v.issuer_lines)],
                [
                    pdf.p("Destinataire", s["label"]),
                    *(pdf.p(x, s["base"]) for x in v.recipient_lines),
                ],
            ]
        ],
        colWidths=[w * 0.52, w * 0.48],
    )
    parties.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (0, -1), 8),
                ("RIGHTPADDING", (1, 0), (1, -1), 0),
            ]
        )
    )
    story += [parties, Spacer(1, 6 * mm)]
    story += [pdf.p(v.date_line, s["right"]), Spacer(1, 2 * mm), pdf.p(v.subject_line, s["bold"])]
    story += [Spacer(1, 5 * mm), pdf.p(v.salutation, s["base"]), Spacer(1, 2 * mm)]
    story += [pdf.p(v.opening, s["base"]), Spacer(1, 4 * mm)]
    story.append(_rows_table(v, s))
    story += [Spacer(1, 3 * mm), pdf.p(v.total_line, s["right_bold"]), Spacer(1, 5 * mm)]
    story += [pdf.p(v.payment_line, s["base"]), Spacer(1, 4 * mm)]
    story += [pdf.p(m, s["bold"]) for m in v.mentions]
    story += [Spacer(1, 5 * mm), pdf.p(v.closing, s["base"]), Spacer(1, 3 * mm)]
    story.append(pdf.p(v.signature, s["base"]))
    return pdf.build(
        story,
        issued_at(doc),
        title=f"Demande de remboursement {doc.number}",
        author=v.signature,
        subject="Demande de remboursement d'avance",
        creator=doc.template_version,
        footer=v.footer,
    )


def _rows_table(v: RequestView, s: dict[str, ParagraphStyle]) -> Table:
    """The rows: the date and the amounts never wrap (each column as wide as its widest text), the
    mandate on its share, the origin takes the rest; the header repeated on each page."""
    rows = [(r.recorded, r.mandate, r.origin, r.paid, r.repaid, r.owed) for r in v.rows]
    amounts = (3, 4, 5)

    def need(col: int) -> float:
        head = pdf.width_of(v.head[col], s["th_right"] if col in amounts else s["th"])
        style = s["cell_amount"] if col in amounts else s["cell"]
        return max([head] + [pdf.width_of(r[col], style) for r in rows]) + 5

    widths = [need(0), pdf.FRAME_WIDTH * 0.15, 0.0, need(3), need(4), need(5)]
    widths[2] = pdf.FRAME_WIDTH - sum(widths)
    data: list[list[Any]] = [
        [pdf.p(h, s["th_right"] if i in amounts else s["th"]) for i, h in enumerate(v.head)]
    ]
    for r in rows:
        data.append(
            [pdf.p(c, s["cell_amount"] if i in amounts else s["cell"]) for i, c in enumerate(r)]
        )
    table = Table(data, colWidths=widths, repeatRows=1)
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-2, -1), 4),
                ("RIGHTPADDING", (-1, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 1.5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 1.5),
                ("LINEBELOW", (0, 0), (-1, 0), 0.6, pdf.LINE),
                ("LINEBELOW", (0, 1), (-1, -1), 0.25, pdf.LINE),
            ]
        )
    )
    return table


def pdf_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
