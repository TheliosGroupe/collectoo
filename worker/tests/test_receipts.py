"""M2-10 receipts, without the database: French formatting of the payload (amounts « 1 234,56 € »,
dates « 09/11/2026 »), the locked template's text (snapshot), the third-party payer rule (founder
#15), versions and void receipts, and a deterministic PDF: the same receipt renders to the same
bytes, pinned by a golden SHA-256 for a fixed synthetic receipt (design §13 M2-10, risk R7)."""

import copy
import hashlib
from datetime import UTC, datetime
from typing import Any

import pytest
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.payments.receipt_pdf import RENDERER_VERSION, render_receipt
from collectoo_worker.payments.receipts import (
    NBSP,
    NNBSP,
    TEMPLATE_VERSION,
    THIRD_PARTY,
    ReceiptDocument,
    format_date,
    format_money,
    paris_date,
    payer_text,
    receipt_text,
    receipt_view,
)

# Pinned to TEMPLATE_VERSION and RENDERER_VERSION: a change of either (or of reportlab, the font,
# the layout) changes the bytes; stored receipts keep their PDF, new ones carry the new versions.
GOLDEN_TEMPLATE = "quittance-fr-1"
GOLDEN_RENDERER = "reportlab-4.4.10/dejavu-2.37/r1"
GOLDEN_PDF_SHA256 = "41477476288bbb3872f05199282d1f1cae47b609580a2ad1b4dfe2c90044a47e"
KNOWN_AT = datetime(2026, 11, 9, 10, 15, 30, tzinfo=UTC)


def plain(text: str) -> str:
    return text.replace(NNBSP, " ").replace(NBSP, " ")


def payload(**over: Any) -> dict[str, Any]:
    """The design's worked example P1 (§8.2), as private.receipt_payload builds it."""
    base: dict[str, Any] = {
        "schema": 1,
        "state": "issued",
        "issuer": {"name": "Collectoo SAS"},
        "creditor": {"name": "Martin SAS"},
        "file": {"reference": "M-0042"},
        "debtor": {"name": "Martin-Durand SARL"},
        "payer": {"name": "MARTIN-DURAND", "third_party": False},
        "payment": {
            "amount_minor": "200000",
            "currency": "EUR",
            "exponent": 2,
            "method": "sct",
            "booking_date": "2026-10-12",
            "value_date": "2026-10-12",
            "reference": "E2E-2026-0001",
        },
        "allocation": [
            _line("F-103", "2026-08-20", "40000"),
            _line("F-101", "2026-06-10", "130000"),
            _line("F-102", "2026-07-15", "30000"),
        ],
        "totals": {
            "allocated_minor": "200000",
            "forwarded_minor": "0",
            "returned_minor": "0",
            "unallocated_minor": "0",
        },
        "first_letter": None,
    }
    base.update(over)
    return base


def _line(ref: str, due: str | None, amount: str, file: str = "M-0042") -> dict[str, Any]:
    return {
        "file_reference": file,
        "item_ref": ref,
        "item_kind": "invoice",
        "due_date": due,
        "component": "principal",
        "component_label": "Principal",
        "amount_minor": amount,
    }


def doc(version: int = 1, kind: str = "original", **over: Any) -> ReceiptDocument:
    return ReceiptDocument("Q-2026-000001", version, kind, KNOWN_AT, payload(**over))


# -- formatting -----------------------------------------------------------------------------------


def test_amounts_are_french_with_grouping_and_a_decimal_comma() -> None:
    assert format_money(123456, 2, "EUR") == f"1{NNBSP}234,56{NBSP}€"
    assert plain(format_money("123456", 2, "EUR")) == "1 234,56 €"
    assert plain(format_money(5, 2, "EUR")) == "0,05 €"
    assert plain(format_money(0, 2, "EUR")) == "0,00 €"
    assert plain(format_money(100_000_000_00, 2, "EUR")) == "100 000 000,00 €"
    assert plain(format_money(1234, 0, "JPY")) == "1 234 JPY"
    assert plain(format_money(-1050, 2, "USD")) == "-10,50 USD"
    with pytest.raises(ValueError):
        format_money(1, -1, "EUR")


@given(st.integers(min_value=0, max_value=10**15))
def test_formatting_keeps_every_minor_unit(minor: int) -> None:
    text = plain(format_money(minor, 2, "EUR"))
    digits = text.removesuffix(" €").replace(" ", "").replace(",", "")
    assert int(digits) == minor and text.count(",") == 1


def test_dates_are_day_month_year() -> None:
    assert format_date("2026-11-09") == "09/11/2026"
    assert format_date("2026-01-02T00:00:00") == "02/01/2026"
    assert format_date(None) == "" and format_date("") == ""


def test_the_issue_date_is_the_paris_business_day() -> None:
    assert paris_date(datetime(2026, 11, 9, 23, 30, tzinfo=UTC)).isoformat() == "2026-11-10"
    assert paris_date(datetime(2026, 7, 1, 21, 59, tzinfo=UTC)).isoformat() == "2026-07-01"
    with pytest.raises(ValueError):
        paris_date(datetime(2026, 11, 9))  # noqa: DTZ001 - refused: no zone


# -- the template ------------------------------------------------------------------------------


def test_the_receipt_text_snapshot() -> None:
    assert plain(receipt_text(doc())) == "\n".join(
        [
            "Quittance",
            "N° Q-2026-000001",
            "Version 1",
            "Établie le 09/11/2026",
            "",
            "Émetteur : Collectoo SAS, agissant pour le compte de Martin SAS",
            "Débiteur : Martin-Durand SARL",
            "Dossier : M-0042",
            "",
            "Paiement reçu",
            "Montant reçu : 2 000,00 €",
            "Date de réception : 12/10/2026",
            "Date de valeur : 12/10/2026",
            "Mode de paiement : Virement SEPA",
            "Payeur : MARTIN-DURAND",
            "Référence de l'opération : E2E-2026-0001",
            "",
            "Imputation",
            "Facture F-103 | 20/08/2026 | Principal | 400,00 €",
            "Facture F-101 | 10/06/2026 | Principal | 1 300,00 €",
            "Facture F-102 | 15/07/2026 | Principal | 300,00 €",
            "",
            "Total imputé : 2 000,00 €",
            "",
            "Quittance n° Q-2026-000001 · version 1",
        ]
    )


def test_a_third_party_payer_is_never_named() -> None:
    """Founder #15: « versement d'un tiers » unless the payer is a party to the file."""
    text = receipt_text(doc(payer={"name": None, "third_party": True}))
    assert f"Payeur : {THIRD_PARTY}" in text
    assert payer_text({"name": "M DURAND", "third_party": True}) == THIRD_PARTY  # even if given
    assert payer_text({"name": None, "third_party": False}) == THIRD_PARTY
    assert payer_text({}) == THIRD_PARTY
    assert payer_text({"name": "VERDIER SAS", "third_party": False}) == "VERDIER SAS"


def test_what_is_not_allocated_forwarded_or_returned_is_said_and_nothing_else() -> None:
    """No remaining balance (founder #14); « Montant non imputé » for an overpayment or a payment
    waiting (a hold reads the same: neutral words); a forward and a refund when there are."""
    over = payload()["totals"] | {"allocated_minor": "512000", "unallocated_minor": "8000"}
    text = plain(receipt_text(doc(totals=over)))
    assert "Montant non imputé : 80,00 €" in text
    assert "Reversé" not in text and "restitué" not in text and "solde" not in text.lower()
    waiting = plain(
        receipt_text(
            doc(
                allocation=[],
                totals={
                    "allocated_minor": "0",
                    "forwarded_minor": "0",
                    "returned_minor": "0",
                    "unallocated_minor": "200000",
                },
            )
        )
    )
    assert "Aucune imputation à ce jour." in waiting
    assert "Montant non imputé : 2 000,00 €" in waiting and "Imputation\n" not in waiting
    forwarded = plain(
        receipt_text(
            doc(
                allocation=[],
                totals={
                    "allocated_minor": "0",
                    "forwarded_minor": "200000",
                    "returned_minor": "1000",
                    "unallocated_minor": "0",
                },
            )
        )
    )
    assert "Reversé au créancier sans imputation : 2 000,00 €" in forwarded
    assert "Montant restitué : 10,00 €" in forwarded and "Aucune imputation" not in forwarded


def test_lines_on_another_file_of_the_debtor_name_it() -> None:
    lines = [_line("F-1", "2026-08-01", "10000"), _line("B-1", None, "15000", file="B-77")]
    view = receipt_view(doc(allocation=lines))
    assert view.show_file_column
    assert [(x.file, x.item, x.due) for x in view.allocation] == [
        ("M-0042", "Facture F-1", "01/08/2026"),
        ("B-77", "Facture B-1", "\u2013"),
    ]
    assert not receipt_view(doc()).show_file_column


def test_versions_and_void_receipts() -> None:
    assert receipt_view(doc(2, "update")).version_line == "Version 2 \u2013 remplace la version 1"
    void = ReceiptDocument(
        "Q-2026-000001",
        3,
        "void",
        KNOWN_AT,
        {
            k: v
            for k, v in payload(state="void").items()
            if k not in ("allocation", "totals", "payer")
        },
    )
    view = receipt_view(void)
    assert (view.title, view.version_line) == (
        "Quittance annulée",
        "Version 3 \u2013 annule la version 2",
    )
    assert view.notes == (
        "Ce paiement n'est plus rattaché au dossier M-0042 : la version 2 de cette quittance est "
        "annulée.",
    )
    assert view.allocation == () and view.totals == ()
    assert "Payeur" not in receipt_text(void)
    assert render_receipt(void).startswith(b"%PDF-")


def test_the_first_letter_is_recalled_when_there_is_one() -> None:
    """R124-4 last paragraph (OQ-22): empty until M4 sends first letters."""
    assert "première lettre" not in receipt_text(doc())
    text = receipt_text(doc(first_letter={"reference": "L1-2026-000042", "sent_on": "2026-10-01"}))
    assert "Référence et date d'envoi de notre première lettre : L1-2026-000042, 01/10/2026" in text


def test_unknown_codes_fall_back_to_what_the_payload_says() -> None:
    line = _line("X-9", None, "100") | {"item_kind": "credit_note", "component_label": None}
    view = receipt_view(doc(allocation=[line], payment=payload()["payment"] | {"method": "?"}))
    assert view.allocation[0].item == "X-9" and view.allocation[0].nature == "principal"
    assert ("Mode de paiement", "Autre") in [(r.label, r.value) for r in view.payment]


# -- the PDF -------------------------------------------------------------------------------------


def test_the_pdf_is_deterministic_and_pinned_by_a_golden_hash() -> None:
    first = render_receipt(doc())
    assert render_receipt(copy.deepcopy(doc())) == first  # same input, same bytes
    assert first.startswith(b"%PDF-1.4") and b"/CreationDate (D:20261109101530+00'00')" in first
    assert b"/Title (Quittance Q-2026-000001 version 1)" in first
    assert (TEMPLATE_VERSION, RENDERER_VERSION) == (GOLDEN_TEMPLATE, GOLDEN_RENDERER)
    assert hashlib.sha256(first).hexdigest() == GOLDEN_PDF_SHA256


def test_the_pdf_depends_on_the_receipt_only() -> None:
    base = render_receipt(doc())
    assert render_receipt(doc(2, "update")) != base
    other_time = ReceiptDocument("Q-2026-000001", 1, "original", datetime(2026, 11, 10, tzinfo=UTC),
                                 payload())  # fmt: skip
    assert render_receipt(other_time) != base
    names = payload(debtor={"name": "Łukasz Wójcik-Œuvray"}, issuer={"name": "Collectoo & Cie"})
    assert render_receipt(ReceiptDocument("Q-2026-000001", 1, "original", KNOWN_AT, names)) != base


def test_a_long_allocation_runs_over_several_pages() -> None:
    lines = [_line(f"F-{n:04d}", "2026-08-01", "100") for n in range(120)]
    pdf = render_receipt(doc(allocation=lines))
    assert pdf.count(b"/Type /Page\n") >= 2
