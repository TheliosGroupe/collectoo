"""The PDF machinery the statement and the invoices share with the receipts (M2b-5; design §10, §14;
risk R9): reportlab pinned in `uv.lock` and run with its own defaults only (`reportlab_defaults`),
invariant mode, no compression, the DejaVu Sans font committed with the receipts (embedded as a
subset), the PDF's dates taken from the document (never from the clock). Bytes = f(payload, template
version, `RENDERER_VERSION`).
"""

from __future__ import annotations

# isort: off
from collectoo_worker.payments import reportlab_defaults  # first: reportlab with its own defaults
# isort: on

import io
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Any

import reportlab
from reportlab.lib import colors
from reportlab.lib.enums import TA_RIGHT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfgen.canvas import Canvas
from reportlab.platypus import Flowable, Paragraph, SimpleDocTemplate, Table, TableStyle

from collectoo_worker.payments.receipt_pdf import FONT, _canvas_at, _drawn, _fonts
from collectoo_worker.payments.receipts import NBSP, NNBSP

# Changes whenever the bytes may change for one input: reportlab's version, the font, this package.
RENDERER_VERSION = f"reportlab-{reportlab.Version}/dejavu-2.37/d1"
FRAME_WIDTH = A4[0] - 36 * mm - 12  # the frame keeps 6 pt of padding on each side
GREY = colors.HexColor("#52525b")
LINE = colors.HexColor("#d4d4d8")
SIZE = 9


@dataclass(frozen=True, slots=True)
class Row:
    label: str
    value: str


def styles() -> dict[str, ParagraphStyle]:
    _fonts()
    base = ParagraphStyle("base", fontName=FONT, fontSize=SIZE, leading=11.5)
    bold = ParagraphStyle("bold", parent=base, fontName="DejaVuSans-Bold")
    right = ParagraphStyle("right", parent=base, alignment=TA_RIGHT)
    right_bold = ParagraphStyle("right_bold", parent=bold, alignment=TA_RIGHT)
    return {
        "base": base,
        "bold": bold,
        "title": ParagraphStyle("title", parent=bold, fontSize=18, leading=22),
        "right": right,
        "right_bold": right_bold,
        "amount": ParagraphStyle("amount", parent=right, splitLongWords=0),
        "amount_bold": ParagraphStyle("amount_bold", parent=right_bold, splitLongWords=0),
        "h2": ParagraphStyle("h2", parent=bold, fontSize=11, leading=14, spaceBefore=4),
        "label": ParagraphStyle("label", parent=base, textColor=GREY),
        "small": ParagraphStyle("small", parent=base, fontSize=7.5, leading=9.5, textColor=GREY),
        "th": ParagraphStyle("th", parent=bold, fontSize=8, leading=10),
        "th_right": ParagraphStyle(
            "th_right", parent=bold, fontSize=8, leading=10, alignment=TA_RIGHT
        ),
        "cell": ParagraphStyle("cell", parent=base, fontSize=8, leading=10),
        "cell_amount": ParagraphStyle(
            "cell_amount", parent=base, fontSize=8, leading=10, alignment=TA_RIGHT, splitLongWords=0
        ),
    }


def p(text: str, style: ParagraphStyle) -> Paragraph:
    from xml.sax.saxutils import escape  # noqa: PLC0415 - local: only the drawing escapes

    return Paragraph(escape(_drawn(text)), style)


def width_of(text: str, style: ParagraphStyle) -> float:
    return float(pdfmetrics.stringWidth(_drawn(text), style.fontName, style.fontSize))


def pairs(rows: Sequence[Row], s: dict[str, ParagraphStyle], label_share: float = 0.42) -> Table:
    """Label / value rows; the value column fits the widest value (amounts never wrap)."""
    need = max([0.0] + [width_of(r.value, s["amount"]) for r in rows]) + 2
    value_w = max(FRAME_WIDTH * (1 - label_share), need)
    table = Table(
        [[p(r.label, s["base"]), p(r.value, s["amount"])] for r in rows],
        colWidths=[FRAME_WIDTH - value_w, value_w],
    )
    table.setStyle(_plain_style())
    return table


def pairs_left(rows: Sequence[Row], s: dict[str, ParagraphStyle]) -> Table:
    """Label / text rows (the text wraps)."""
    table = Table(
        [[p(r.label, s["label"]), p(r.value, s["base"])] for r in rows],
        colWidths=[FRAME_WIDTH * 0.28, FRAME_WIDTH * 0.72],
    )
    table.setStyle(_plain_style())
    return table


def _plain_style() -> TableStyle:
    return TableStyle(
        [
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 0),
            ("RIGHTPADDING", (0, 0), (-1, -1), 0),
            ("TOPPADDING", (0, 0), (-1, -1), 1.2),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 1.2),
        ]
    )


def grid(
    head: Sequence[str],
    rows: Sequence[Sequence[str]],
    shares: Sequence[float],
    amount_cols: Sequence[int],
    s: dict[str, ParagraphStyle],
) -> Table:
    """A table with a header row repeated on each page; amount columns right-aligned, each at least
    as wide as its widest amount (taken from the first column)."""
    widths = [FRAME_WIDTH * x for x in shares]
    for c in amount_cols:
        need = max(
            [width_of(head[c], s["th_right"])] + [width_of(r[c], s["cell_amount"]) for r in rows]
        )
        extra = need + 5 - widths[c]
        if extra > 0:
            widths[c] += extra
            widths[0] -= extra
    data: list[list[Any]] = [
        [p(h, s["th_right"] if i in amount_cols else s["th"]) for i, h in enumerate(head)]
    ]
    for r in rows:
        data.append(
            [p(c, s["cell_amount"] if i in amount_cols else s["cell"]) for i, c in enumerate(r)]
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
                ("LINEBELOW", (0, 0), (-1, 0), 0.6, LINE),
                ("LINEBELOW", (0, 1), (-1, -1), 0.25, LINE),
            ]
        )
    )
    return table


def build(  # noqa: PLR0913 - the PDF's metadata, by keyword
    story: list[Flowable],
    at: datetime,
    *,
    title: str,
    author: str,
    subject: str,
    creator: str,
    footer: str,
) -> bytes:
    """The PDF (A4), dated `at` (from the document), deterministic."""
    reportlab_defaults.pin()

    def draw_footer(canvas: Canvas, _doc: Any) -> None:
        canvas.saveState()
        canvas.setFont(FONT, 7.5)
        canvas.setFillColor(GREY)
        canvas.drawString(18 * mm + 6, 11 * mm, _drawn(footer))
        canvas.drawRightString(A4[0] - 18 * mm - 6, 11 * mm, f"page {canvas.getPageNumber()}")
        canvas.restoreState()

    buf = io.BytesIO()
    template = SimpleDocTemplate(
        buf,
        pagesize=A4,
        leftMargin=18 * mm,
        rightMargin=18 * mm,
        topMargin=16 * mm,
        bottomMargin=18 * mm,
        title=title,
        author=author,
        subject=subject,
        creator=creator,
        invariant=1,
        pageCompression=0,
    )
    make: Callable[..., Canvas] = _canvas_at(at)
    template.build(story, onFirstPage=draw_footer, onLaterPages=draw_footer, canvasmaker=make)
    return buf.getvalue()


__all__ = ["NBSP", "NNBSP", "RENDERER_VERSION"]
