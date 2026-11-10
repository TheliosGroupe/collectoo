"""The PDF of a commission invoice or credit note (design §14.2; template
`facture-commission-fr-1`): `invoice.invoice_view` drawn on A4. Deterministic: bytes = f(the
document's row and frozen payload, the numbers it names, the template and renderer versions), dated
by its issue date (`remittance.pdf`), never by the clock.
"""

from __future__ import annotations

# isort: off
from collectoo_worker.payments import reportlab_defaults  # noqa: F401 - first: reportlab's own defaults
# isort: on

import hashlib

from reportlab.lib.units import mm
from reportlab.platypus import Flowable, Spacer, Table, TableStyle

from collectoo_worker.remittance import pdf
from collectoo_worker.remittance.invoice import InvoiceDocument, invoice_view, issued_at


def render_invoice_pdf(doc: InvoiceDocument) -> bytes:
    v = invoice_view(doc)
    s = pdf.styles()
    w = pdf.FRAME_WIDTH
    story: list[Flowable] = []
    header = Table(
        [
            [pdf.p(v.title, s["title"]), pdf.p(v.number_line, s["right_bold"])],
            ["", pdf.p(v.issued_line, s["right"])],
        ],
        colWidths=[w * 0.5, w * 0.5],
    )
    header.setStyle(
        TableStyle(
            [
                ("SPAN", (0, 0), (0, 1)),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("LINEBELOW", (0, 1), (-1, 1), 0.6, pdf.LINE),
                ("BOTTOMPADDING", (0, 1), (-1, 1), 6),
            ]
        )
    )
    story += [header, Spacer(1, 4 * mm)]
    parties = Table(
        [
            [
                [pdf.p("Émetteur", s["label"]), *(pdf.p(x, s["base"]) for x in v.seller_lines)],
                [pdf.p("Destinataire", s["label"]), *(pdf.p(x, s["base"]) for x in v.buyer_lines)],
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
    story += [parties, Spacer(1, 5 * mm)]
    story += [pdf.p(v.nature_line, s["bold"]), pdf.p(v.service_line, s["base"])]
    story += [pdf.p(x, s["label"]) for x in v.reference_lines]
    story.append(Spacer(1, 4 * mm))
    story.append(
        pdf.grid(
            ("Désignation", "Qté", "Prix unitaire HT", "TVA", "Montant HT"),
            [(x.designation, x.quantity, x.unit_price, x.vat_rate, x.amount) for x in v.lines],
            (0.52, 0.06, 0.16, 0.08, 0.18),
            (1, 2, 3, 4),
            s,
        )
    )
    story += [Spacer(1, 3 * mm), pdf.pairs([pdf.Row(a, b) for a, b in v.totals], s, 0.6)]
    story.append(Spacer(1, 5 * mm))
    story += [pdf.p(m, s["base"]) for m in v.mentions]
    return pdf.build(
        story,
        issued_at(doc),
        title=f"{v.title} {doc.number}",
        author=str(doc.payload["seller"]["name"]),
        subject=v.title,
        creator=doc.template_version,
        footer=v.footer,
    )


def pdf_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
