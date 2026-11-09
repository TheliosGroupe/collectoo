"""Deterministic PDF rendering of a receipt (M2-10, design §10, risk R7).

PDF bytes = f(receipt row, payload, TEMPLATE_VERSION, RENDERER_VERSION): reportlab pinned in
`uv.lock` and run with its own defaults only (`reportlab_defaults`: no RL_* variable, settings file
or mods hook of the environment reaches it, its global configuration is pinned again before each
render, and a reportlab another module configured first is refused: review #4), in invariant mode
(fixed document id), without compression (no dependency on the zlib build), with the DejaVu Sans
font committed next to this module (embedded as a subset; it covers names outside WinAnsi) and the
PDF dates taken from the receipt's `known_at`, never from the clock. Regenerating a stored receipt
therefore gives the same bytes and the same SHA-256 (golden hash in tests/test_receipts.py). An
amount is one unbreakable token in a column wide enough for it: it never wraps mid-number
(review #6). Nothing here reads the network or the clock.
"""

from __future__ import annotations

# isort: off
from collectoo_worker.payments import reportlab_defaults  # first: reportlab with its own defaults
# isort: on

import hashlib
import io
import time
from collections.abc import Callable, Sequence
from datetime import UTC, datetime
from functools import cache
from pathlib import Path
from typing import Any, cast
from xml.sax.saxutils import escape

import reportlab
from reportlab.lib import colors
from reportlab.lib.enums import TA_RIGHT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.lib.utils import TimeStamp
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen.canvas import Canvas
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

from collectoo_worker.payments.receipts import (
    NBSP,
    NNBSP,
    TEMPLATE_VERSION,
    ReceiptDocument,
    ReceiptView,
    Row,
    receipt_view,
)

FONTS = Path(__file__).parent / "fonts"
FONT, FONT_BOLD = "DejaVuSans", "DejaVuSans-Bold"
# Changes whenever the bytes may change for one input: reportlab's version, the font, this file.
# r2: amounts unbreakable (NBSP grouping), reportlab's configuration pinned (review #4, #6).
RENDERER_VERSION = f"reportlab-{reportlab.Version}/dejavu-2.37/r2"
FRAME_WIDTH = A4[0] - 36 * mm - 12  # the frame keeps 6 pt of padding on each side
GREY = colors.HexColor("#52525b")
LINE = colors.HexColor("#d4d4d8")
SIZE = 9.5  # body text and amounts


@cache
def _fonts() -> None:
    pdfmetrics.registerFont(TTFont(FONT, str(FONTS / "DejaVuSans.ttf"), asciiReadable=1))
    pdfmetrics.registerFont(TTFont(FONT_BOLD, str(FONTS / "DejaVuSans-Bold.ttf"), asciiReadable=1))


def _timestamp(at: datetime) -> TimeStamp:
    """reportlab's document time, set to `at` (UTC) instead of the clock or its fixed 2000-01-01."""
    ts = TimeStamp(invariant=1)
    seconds = int(at.astimezone(UTC).timestamp())
    gm = time.gmtime(seconds)
    ts.t = seconds
    ts.lt = gm
    ts.YMDhms = tuple(gm)[:6]
    ts.dhh = ts.dmm = 0
    ts.tzname = "UTC"
    return ts


def _canvas_at(at: datetime) -> Callable[..., Canvas]:
    """A canvas dated `at`: its time stamp, and the document id reportlab derives from it (seeded
    as reportlab seeds it, so SOURCE_DATE_EPOCH or the clock never reach the bytes)."""

    def make(*args: Any, **kwargs: Any) -> Canvas:
        canvas = Canvas(*args, **kwargs)
        ts = _timestamp(at)
        signature = hashlib.md5(usedforsecurity=False)
        signature.update(b"a reportlab document")
        signature.update(ascii(ts.t).encode("ascii"))
        doc = cast(Any, canvas)._doc  # reportlab's document: the one way to date the PDF
        doc._timeStamp = ts
        doc.signature = signature
        return canvas

    return make


def _styles() -> dict[str, ParagraphStyle]:
    _fonts()
    base = ParagraphStyle("base", fontName=FONT, fontSize=SIZE, leading=12.5)
    right = ParagraphStyle("right", parent=base, alignment=TA_RIGHT)
    right_bold = ParagraphStyle("right_bold", parent=base, fontName=FONT_BOLD, alignment=TA_RIGHT)
    return {
        "base": base,
        "title": ParagraphStyle("title", parent=base, fontName=FONT_BOLD, fontSize=20, leading=24),
        "right": right,
        "right_bold": right_bold,
        # an amount is one word (NBSP grouping) that is never split: its column fits it
        "amount": ParagraphStyle("amount", parent=right, splitLongWords=0),
        "amount_bold": ParagraphStyle("amount_bold", parent=right_bold, splitLongWords=0),
        "h2": ParagraphStyle("h2", parent=base, fontName=FONT_BOLD, fontSize=11.5, leading=15),
        "label": ParagraphStyle("label", parent=base, textColor=GREY),
        "small": ParagraphStyle("small", parent=base, fontSize=8, leading=10, textColor=GREY),
        "th": ParagraphStyle("th", parent=base, fontName=FONT_BOLD, fontSize=8.5, leading=11),
        "th_right": ParagraphStyle(
            "th_right",
            parent=base,
            fontName=FONT_BOLD,
            fontSize=8.5,
            leading=11,
            alignment=TA_RIGHT,
        ),
    }


def _drawn(text: str) -> str:
    """The text as drawn: reportlab breaks lines at U+202F (and prints it as a space), never at
    U+00A0, so thousands are grouped with a no-break space: an amount is one unbreakable word."""
    return text.replace(NNBSP, NBSP)


def _p(text: str, style: ParagraphStyle) -> Paragraph:
    return Paragraph(escape(_drawn(text)), style)


def _width(text: str, style: ParagraphStyle) -> float:
    return float(pdfmetrics.stringWidth(_drawn(text), style.fontName, style.fontSize))


def _fit_last(widths: list[float], need: float, give: Sequence[int], floor: float) -> list[float]:
    """The last column at least `need` wide, the difference taken from the columns `give` (in that
    order), none below `floor`."""
    out = list(widths)
    extra = need - out[-1]
    for i in give:
        if extra <= 0:
            break
        take = min(extra, max(0.0, out[i] - floor))
        out[i] -= take
        out[-1] += take
        extra -= take
    return out


def render_receipt(doc: ReceiptDocument) -> bytes:
    """The receipt's PDF (A4, French), deterministic."""
    reportlab_defaults.pin()
    v = receipt_view(doc)
    s = _styles()
    width = FRAME_WIDTH
    story: list[Any] = []
    header = Table(
        [
            [_p(v.title, s["title"]), _p(v.number_line, s["right_bold"])],
            ["", _p(v.version_line, s["right"])],
            ["", _p(v.issued_line, s["right"])],
        ],
        colWidths=[width * 0.55, width * 0.45],
    )
    header.setStyle(
        TableStyle(
            [
                ("SPAN", (0, 0), (0, 2)),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("LINEBELOW", (0, 2), (-1, 2), 0.6, LINE),
                ("BOTTOMPADDING", (0, 2), (-1, 2), 8),
            ]
        )
    )
    story += [header, Spacer(1, 5 * mm)]
    story.append(_pairs(v.parties, s, width))
    story += [Spacer(1, 5 * mm), _p("Paiement reçu", s["h2"]), Spacer(1, 1.5 * mm)]
    story.append(_pairs(v.payment, s, width))
    if v.allocation:
        story += [Spacer(1, 5 * mm), _p("Imputation", s["h2"]), Spacer(1, 1.5 * mm)]
        story.append(_allocation(v, s, width))
    if v.totals:
        story += [Spacer(1, 3 * mm), _totals(v, s, width)]
    for note in v.notes:
        story += [Spacer(1, 3 * mm), _p(note, s["base"])]

    def footer(canvas: Canvas, _doc: Any) -> None:
        canvas.saveState()
        canvas.setFont(FONT, 8)
        canvas.setFillColor(GREY)
        canvas.drawString(18 * mm + 6, 12 * mm, v.footer)
        canvas.drawRightString(A4[0] - 18 * mm - 6, 12 * mm, f"page {canvas.getPageNumber()}")
        canvas.restoreState()

    buf = io.BytesIO()
    template = SimpleDocTemplate(
        buf,
        pagesize=A4,
        leftMargin=18 * mm,
        rightMargin=18 * mm,
        topMargin=18 * mm,
        bottomMargin=20 * mm,
        title=f"Quittance {doc.number} version {doc.version}",
        author=str(doc.payload["issuer"]["name"]),
        subject=v.title,
        creator=TEMPLATE_VERSION,
        invariant=1,
        pageCompression=0,
    )
    template.build(
        story, onFirstPage=footer, onLaterPages=footer, canvasmaker=_canvas_at(doc.known_at)
    )
    return buf.getvalue()


def _pairs(rows: Sequence[Row], s: dict[str, ParagraphStyle], width: float) -> Table:
    table = Table(
        [[_p(r.label, s["label"]), _p(r.value, s["base"])] for r in rows],
        colWidths=[width * 0.3, width * 0.7],
    )
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 1.5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 1.5),
            ]
        )
    )
    return table


def _allocation(v: ReceiptView, s: dict[str, ParagraphStyle], width: float) -> Table:
    head = ["Facture ou échéance", "Échéance", "Nature", "Montant"]
    shares = [0.32, 0.16, 0.32, 0.2]
    give = [2, 0]  # the nature, then the item, make room for a wide amount
    if v.show_file_column:
        head = ["Dossier", *head]
        shares = [0.16, 0.24, 0.14, 0.28, 0.18]
        give = [3, 1, 0]
    need = max(
        [_width("Montant", s["th_right"])] + [_width(x.amount, s["amount"]) for x in v.allocation]
    )
    widths = _fit_last([width * x for x in shares], need + 1, give, width * 0.1)
    rows: list[list[Any]] = [
        [_p(h, s["th_right"] if h == "Montant" else s["th"]) for h in head],
    ]
    for line in v.allocation:
        cells = [line.item, line.due, line.nature]
        if v.show_file_column:
            cells = [line.file, *cells]
        rows.append([*(_p(c, s["base"]) for c in cells), _p(line.amount, s["amount"])])
    table = Table(rows, colWidths=widths, repeatRows=1)
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-2, -1), 4),
                ("RIGHTPADDING", (-1, 0), (-1, -1), 0),
                ("LINEBELOW", (0, 0), (-1, 0), 0.6, LINE),
                ("LINEBELOW", (0, 1), (-1, -1), 0.3, LINE),
            ]
        )
    )
    return table


def _totals(v: ReceiptView, s: dict[str, ParagraphStyle], width: float) -> Table:
    need = max([0.0] + [_width(r.value, s["amount_bold"]) for r in v.totals])
    widths = _fit_last([width * 0.75, width * 0.25], need + 1, [0], width * 0.3)
    table = Table(
        [[_p(r.label, s["right"]), _p(r.value, s["amount_bold"])] for r in v.totals],
        colWidths=widths,
    )
    table.setStyle(
        TableStyle(
            [
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 1.5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 1.5),
            ]
        )
    )
    return table


def pdf_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
