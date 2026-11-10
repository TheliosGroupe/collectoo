"""M2-10 receipts, without the database: French formatting of the payload (amounts « 1 234,56 € »,
dates « 09/11/2026 »), the locked template's text (snapshot), the third-party payer rule (founder
#15), versions and void receipts, and a deterministic PDF: the same receipt renders to the same
bytes, pinned by a golden SHA-256 for a fixed synthetic receipt (design §13 M2-10, risk R7),
whatever reportlab settings the environment holds (review #4); amounts never wrap (review #6);
components in the template's own debtor-facing words (review #2)."""

import copy
import hashlib
import json
import os
import subprocess
import sys
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pytest
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.payments import receipt_pdf
from collectoo_worker.payments.receipt_pdf import RENDERER_VERSION, render_receipt
from collectoo_worker.payments.receipts import (
    NBSP,
    NNBSP,
    TEMPLATE_VERSION,
    TEMPLATE_VERSIONS,
    THIRD_PARTY,
    ReceiptDocument,
    format_date,
    format_money,
    issuer_block,
    paris_date,
    payer_text,
    receipt_text,
    receipt_view,
)

# Pinned to the template version and RENDERER_VERSION: a change of either (or of reportlab, the
# font, the layout) changes the bytes; stored receipts keep their PDF, new ones carry the new
# versions. quittance-fr-2's golden is M2b-5's, unchanged by M2c-2 (the receipts issued before it
# regenerate to the same bytes); quittance-fr-3 adds the issuer block (R123-237/238).
GOLDEN_TEMPLATE = "quittance-fr-2"
GOLDEN_RENDERER = "reportlab-4.4.10/dejavu-2.37/r2"
GOLDEN_PDF_SHA256 = "8e1f450ce3f1062e50243b5937850491bffad8a4f95e26add4d04a913833dfcb"
GOLDEN_FR3_PDF_SHA256 = "6c3d4439a3770a9b188afe77a9736384d8836ce29d0f6daa11b5f47868619b21"
ISSUER = {  # as private.receipt_issuer builds it from billing_identity (synthetic)
    "name": "Collectoo",
    "siren": "424392447",
    "legal_form": "SAS",
    "share_capital_minor": "1000000",
    "currency": "EUR",
    "rcs_city": "Paris",
    "registered_office": {
        "line1": "10 rue de la Bourse",
        "postcode": "75002",
        "city": "Paris",
        "country": "FR",
    },
    "in_liquidation": False,
    "entrepreneur_individuel": False,
}
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
        "amount_minor": amount,
    }


def doc(version: int = 1, kind: str = "original", **over: Any) -> ReceiptDocument:
    """A quittance-fr-2 receipt (M2b-5's tests, golden and snapshots unchanged)."""
    return ReceiptDocument(
        "Q-2026-000001", version, kind, KNOWN_AT, payload(**over), GOLDEN_TEMPLATE
    )


def doc3(version: int = 1, kind: str = "original", **over: Any) -> ReceiptDocument:
    """A quittance-fr-3 receipt (M2c-2): the payload's issuer is the full block."""
    over.setdefault("issuer", ISSUER)
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
    line = _line("X-9", None, "100") | {"item_kind": "credit_note", "component": "new_code"}
    view = receipt_view(doc(allocation=[line], payment=payload()["payment"] | {"method": "?"}))
    assert view.allocation[0].item == "X-9" and view.allocation[0].nature == "new_code"
    assert ("Mode de paiement", "Autre") in [(r.label, r.value) for r in view.payment]


def test_an_eu_loan_receipt_words_each_component_for_the_debtor() -> None:
    """Review #2: the template's own words per component code, never the ledger's staff labels
    (« … déclarés par le cédant », « Écart au solde légal déclaré »): the client may never have
    bought the claim, and the balancing line is an internal reconciliation."""
    staff = {
        "accrued_interest": "Intérêts échus déclarés par le cédant",
        "other_balances": "Autres sommes déclarées par le cédant",
        "balancing_line": "Écart au solde légal déclaré",
    }
    lines = [
        {
            "file_reference": "L-0007",
            "item_ref": "PRET-L",
            "item_kind": "loan_principal",
            "due_date": None,
            "component": component,
            "component_label": staff.get(component, "Principal"),  # a stale label: ignored
            "amount_minor": amount,
        }
        for component, amount in (
            ("accrued_interest", "12000"),
            ("principal", "500000"),
            ("other_balances", "3000"),
            ("balancing_line", "150"),
        )
    ]
    loan = payload(
        file={"reference": "L-0007"},
        debtor={"name": "Lilas Dupont"},
        payer={"name": None, "third_party": True},
        allocation=lines,
        totals={
            "allocated_minor": "515150",
            "forwarded_minor": "0",
            "returned_minor": "0",
            "unallocated_minor": "4850",
        },
        payment=payload()["payment"] | {"amount_minor": "520000"},
    )
    text = plain(receipt_text(ReceiptDocument("Q-2026-000007", 1, "original", KNOWN_AT, loan)))
    assert text == "\n".join(
        [
            "Quittance",
            "N° Q-2026-000007",
            "Version 1",
            "Établie le 09/11/2026",
            "",
            "Émetteur : Collectoo SAS, agissant pour le compte de Martin SAS",
            "Débiteur : Lilas Dupont",
            "Dossier : L-0007",
            "",
            "Paiement reçu",
            "Montant reçu : 5 200,00 €",
            "Date de réception : 12/10/2026",
            "Date de valeur : 12/10/2026",
            "Mode de paiement : Virement SEPA",
            "Payeur : Versement d'un tiers",
            "Référence de l'opération : E2E-2026-0001",
            "",
            "Imputation",
            "Prêt PRET-L | \u2013 | Intérêts | 120,00 €",
            "Prêt PRET-L | \u2013 | Principal | 5 000,00 €",
            "Prêt PRET-L | \u2013 | Autres sommes | 30,00 €",
            "Prêt PRET-L | \u2013 | Autres sommes | 1,50 €",
            "",
            "Total imputé : 5 151,50 €",
            "Montant non imputé : 48,50 €",
            "",
            "Quittance n° Q-2026-000007 · version 1",
        ]
    )
    assert "cédant" not in text and "Écart" not in text and "solde" not in text


# -- the PDF -------------------------------------------------------------------------------------


def test_the_pdf_is_deterministic_and_pinned_by_a_golden_hash() -> None:
    first = render_receipt(doc())
    assert render_receipt(copy.deepcopy(doc())) == first  # same input, same bytes
    assert first.startswith(b"%PDF-1.4") and b"/CreationDate (D:20261109101530+00'00')" in first
    assert b"/Title (Quittance Q-2026-000001 version 1)" in first
    assert RENDERER_VERSION == GOLDEN_RENDERER and GOLDEN_TEMPLATE in TEMPLATE_VERSIONS
    assert hashlib.sha256(first).hexdigest() == GOLDEN_PDF_SHA256
    # the issuer block in its payload changes nothing in a quittance-fr-2 receipt
    assert render_receipt(doc(issuer=ISSUER | {"name": "Collectoo SAS"})) == first


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


def test_an_amount_never_wraps_inside_its_cell() -> None:
    """Review #6: reportlab breaks lines at U+202F, so a large amount split mid-number. Amounts are
    drawn as one unbreakable token, in a column wide enough for the widest."""
    huge = "123456789000"  # 1 234 567 890,00 €, in the narrow 5-column layout
    lines = [_line("F-1", "2026-08-01", huge), _line("B-1", None, "100", file="B-77")]
    totals = payload()["totals"] | {
        "allocated_minor": huge + "00",
        "unallocated_minor": huge + "00",
    }
    view = receipt_view(doc(allocation=lines, totals=totals))
    assert view.show_file_column
    styles = receipt_pdf._styles()
    width = receipt_pdf.FRAME_WIDTH
    for table in (
        receipt_pdf._allocation(view, styles, width),
        receipt_pdf._totals(view, styles, width),
    ):
        layout = cast(Any, table)  # reportlab keeps the cells and widths it lays out
        amounts = [row[-1] for row in layout._cellvalues]
        table.wrap(width, 800)
        widths: list[float] = layout._colWidths
        assert sum(widths) <= width + 0.01
        for amount in amounts:
            amount.wrap(widths[-1], 800)
            assert len(amount.blPara.lines) == 1, amount.text
            assert amount.minWidth() <= widths[-1] + 1e-6, amount.text  # and fits its column
    assert render_receipt(doc(allocation=lines, totals=totals)).startswith(b"%PDF-")


# -- reportlab's configuration never reaches the bytes (review #4) ---------------------------------

RENDER = """
import hashlib, json, sys
from datetime import datetime
from collectoo_worker.payments.receipt_pdf import render_receipt
from collectoo_worker.payments.receipts import ReceiptDocument
row = json.load(sys.stdin)
doc = ReceiptDocument(row["number"], row["version"], row["kind"],
                      datetime.fromisoformat(row["known_at"]), row["payload"],
                      row["template_version"])
print(hashlib.sha256(render_receipt(doc)).hexdigest())
"""
RL_ENV = {
    "RL_invariant": "0",
    "RL_ttfAsciiReadable": "0",
    "RL_pdfMultiLine": "1",
    "RL_pdfComments": "1",
    "RL_canvas_basefontname": "Courier",
    "RL_documentLang": "fr-FR",
    "RL_paraFontSizeHeightOffset": "0",
    "RL_spaceShrinkage": "0.3",
    "RL_useA85": "0",
}


def _render_elsewhere(
    env: dict[str, str], cwd: Path, script: str = RENDER
) -> subprocess.CompletedProcess[str]:
    row = asdict(doc()) | {"known_at": KNOWN_AT.isoformat()}
    return subprocess.run(  # noqa: S603 - our interpreter, our code
        [sys.executable, "-c", script],
        input=json.dumps(row),
        capture_output=True,
        text=True,
        env={k: v for k, v in os.environ.items() if not k.startswith("RL_")} | env,
        cwd=cwd,
        check=False,
    )


def test_reportlab_settings_of_the_environment_do_not_change_the_bytes(tmp_path: Path) -> None:
    """RL_* variables, a reportlab_settings.py on the path, ~/.reportlab_settings and the
    reportlab_mods hooks are ignored: the renderer uses reportlab's own defaults."""
    on_path = tmp_path / "path"
    on_path.mkdir()
    (on_path / "reportlab_settings.py").write_text("pdfComments = 1\nttfAsciiReadable = 0\n")
    (on_path / "reportlab_mods.py").write_text("raise SystemExit('reportlab_mods must not run')\n")
    home = tmp_path / "home"
    home.mkdir()
    (home / ".reportlab_settings").write_text("pdfMultiLine = 1\ncanvas_basefontname = 'Courier'\n")
    (home / ".reportlab_mods").write_text("raise SystemExit('~/.reportlab_mods must not run')\n")
    pythonpath = os.pathsep.join(filter(None, [str(on_path), os.environ.get("PYTHONPATH")]))
    for env in (
        RL_ENV,
        RL_ENV | {"PYTHONPATH": pythonpath},
        {"HOME": str(home)},
        RL_ENV | {"HOME": str(home)},
    ):
        out = _render_elsewhere(env, tmp_path)
        assert out.returncode == 0, out.stderr
        assert out.stdout.strip() == GOLDEN_PDF_SHA256, env


def test_the_renderer_refuses_a_reportlab_configured_before_it(tmp_path: Path) -> None:
    """Imported first by other code under RL_* variables, reportlab's import-time copies may differ:
    rendering then refuses rather than produce other bytes."""
    script = "import reportlab.platypus\n" + RENDER
    out = _render_elsewhere({"RL_pdfComments": "1"}, tmp_path, script)
    assert out.returncode != 0
    assert "reportlab was configured outside the receipt renderer" in out.stderr
    assert "pdfComments" in out.stderr


# -- quittance-fr-3: the issuer block (M2c-2; C. com. R123-237, R123-238) ------------------------


def test_new_receipts_carry_the_issuer_block() -> None:
    assert TEMPLATE_VERSION == "quittance-fr-3" and TEMPLATE_VERSIONS[-1] == TEMPLATE_VERSION
    text = plain(receipt_text(doc3()))
    lines = text.splitlines()
    assert lines[:9] == [
        "Quittance",
        "N° Q-2026-000001",
        "Version 1",
        "Établie le 09/11/2026",
        "",
        "Collectoo SAS au capital de 10 000 €",
        "SIREN 424 392 447 · RCS Paris",
        "Siège social : 10 rue de la Bourse, 75002 Paris",
        "",
    ]
    assert "Émetteur : Collectoo, agissant pour le compte de Martin SAS" in lines
    # the rest of the receipt is quittance-fr-2's
    assert (
        text.split("Siège social : 10 rue de la Bourse, 75002 Paris\n\n")[1]
        == plain(receipt_text(doc(issuer={"name": "Collectoo"}))).split(
            "Établie le 09/11/2026\n\n"
        )[1]
    )


def test_the_issuer_block_states_liquidation_ei_capital_and_a_foreign_office() -> None:
    assert issuer_block({"name": "Collectoo"}) == ()  # no identity: the name only, as before
    liquidation = ISSUER | {"in_liquidation": True, "share_capital_minor": "1000050"}
    assert plain(issuer_block(liquidation)[0]) == (
        "Collectoo SAS au capital de 10 000,50 € \u2013 en liquidation"
    )
    ei = ISSUER | {"name": "Jean Durand", "legal_form": "EI", "share_capital_minor": None,
                   "entrepreneur_individuel": True}  # fmt: skip
    assert issuer_block(ei)[0] == "Jean Durand EI"
    no_rcs = ISSUER | {"rcs_city": None}
    assert plain(issuer_block(no_rcs)[1]) == "SIREN 424 392 447"
    office = {"line1": "1 rue X", "line2": "Bât. B", "postcode": "98000", "city": "Monaco",
              "country": "MC"}  # fmt: skip
    assert issuer_block(ISSUER | {"registered_office": office})[2] == (
        "Siège social : 1 rue X, Bât. B, 98000 Monaco, Monaco"
    )


def test_a_void_version_carries_the_block_too() -> None:
    void = ReceiptDocument(
        "Q-2026-000001", 2, "void", KNOWN_AT,
        {"schema": 1, "state": "void", "issuer": ISSUER, "creditor": {"name": "Martin SAS"},
         "file": {"reference": "M-0042"}, "debtor": {"name": "Martin-Durand SARL"},
         "payment": payload()["payment"], "first_letter": None},
    )  # fmt: skip
    assert "SIREN 424 392 447 · RCS Paris" in plain(receipt_text(void))


def test_an_unknown_template_is_refused() -> None:
    bad = ReceiptDocument("Q-2026-000001", 1, "original", KNOWN_AT, payload(), "quittance-fr-9")
    with pytest.raises(ValueError, match="unknown receipt template"):
        receipt_view(bad)


def test_the_fr3_pdf_is_deterministic_and_pinned_by_its_golden_hash() -> None:
    first = render_receipt(doc3())
    assert render_receipt(copy.deepcopy(doc3())) == first
    assert b"/Creator (quittance-fr-3)" in first
    assert hashlib.sha256(first).hexdigest() == GOLDEN_FR3_PDF_SHA256
    assert render_receipt(doc3(issuer=ISSUER | {"in_liquidation": True})) != first
