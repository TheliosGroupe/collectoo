"""The statement and the commission invoices as documents (M2c-5; design §10, §14.2, §18 M2-14 and
M2-15; risk R9): the French wording from the payload (text snapshots), the mentions the law
requires on an invoice and a credit note (CGI ann. II 242 nonies A, C. com. L441-9, L441-10,
D441-5, R123-237/238), the CSV's format (BOM, `;`, CRLF, fixed headers, both amount forms), and
deterministic bytes pinned by golden SHA-256 for fixed synthetic payloads
(`tests/document_cases.py`) — whatever reportlab settings the environment holds.
"""

from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from document_cases import (
    CREDIT_REFS,
    ISSUE,
    credit_note_payload,
    due_invoice_payload,
    invoice_payload,
    statement_payload,
)
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.remittance.invoice import (
    TEMPLATE_VERSION as INVOICE_TEMPLATE,
)
from collectoo_worker.remittance.invoice import (
    InvoiceDocument,
    invoice_text,
    invoice_view,
)
from collectoo_worker.remittance.invoice_pdf import render_invoice_pdf
from collectoo_worker.remittance.pdf import RENDERER_VERSION
from collectoo_worker.remittance.statement import (
    CSV_HEADER,
    PDF_FILE_ROWS_MAX,
    TEMPLATE_VERSION,
    line_records,
    statement_text,
)
from collectoo_worker.remittance.statement_csv import csv_amount, render_statement_csv
from collectoo_worker.remittance.statement_pdf import render_statement_pdf

GOLDEN_RENDERER = "reportlab-4.4.10/dejavu-2.37/d1"
GOLDEN_STATEMENT_CSV = "e30782b1ad5ae3c4cb7335308d1e278affe133ee3641977591fd59d28e08b901"
GOLDEN_STATEMENT_PDF = "a91daca67a7e494199c7ad6bd32ac0fccc71097bce848c35de8a1973465c2629"
GOLDEN_INVOICE_PDF = "b9d9d5d7ac5382310afdb51b5c1745f70ca575379292e14a0b11fc789212a6c6"
GOLDEN_DUE_PDF = "9606cefbd0636b54ba67ec226ea2059d9003e00ca4ecdcb196208cade723fa25"
GOLDEN_CREDIT_PDF = "4b2ab2e9bfeb8c7b1b68145c7febfb260d67d24addbcbd96268eed651cfec0ce"


def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _doc(
    payload: dict[str, object], refs: dict[str, dict[str, str]] | None = None
) -> InvoiceDocument:
    return InvoiceDocument(str(payload["number"]), str(payload["kind"]), ISSUE, payload, refs or {})


# -- the CSV --------------------------------------------------------------------------------------


def test_csv_amounts_are_french_with_grouping_and_in_cents() -> None:
    assert csv_amount(123_456_789, 2) == "1\u00a0234\u00a0567,89"
    assert csv_amount(-1, 2) == "-0,01"
    assert csv_amount(0, 2) == "0,00"
    assert csv_amount(5, 0) == "5"


@given(st.integers(min_value=-(10**15), max_value=10**15))
def test_csv_amounts_keep_every_minor_unit(minor: int) -> None:
    text = csv_amount(minor, 2).replace("\u00a0", "").replace(",", "")
    assert int(text) == minor


def test_the_csv_format() -> None:
    data = render_statement_csv(statement_payload())
    assert data.startswith(b"\xef\xbb\xbf")
    body = data.decode("utf-8-sig")
    assert body.count("\r\n") == body.count("\n") == 1 + 6  # header + 5 lines + 1 repricing
    rows = list(csv.reader(io.StringIO(body, newline=""), delimiter=";"))
    assert tuple(rows[0]) == CSV_HEADER
    assert CSV_HEADER[:21] == (
        "releve", "date_releve", "mandat", "portefeuille", "dossier", "debiteur", "piece",
        "composante", "nature", "date_encaissement", "date_imputation",
        "date_limite_reversement", "montant", "montant_centimes", "regle", "taux",
        "base_commission_centimes", "commission_ht", "commission_ht_centimes", "facture",
        "quittance",
    )  # fmt: skip
    first = dict(zip(CSV_HEADER, rows[1], strict=True))
    assert first["piece"] == "Facture F-001 ; Facture F-002"  # quoted: it holds the separator
    assert first["composante"] == "Principal ; Intérêts"
    assert (first["montant"], first["montant_centimes"]) == ("2\u00a0000,00", "200000")
    assert first["date_encaissement"] == "2026-10-21" and first["date_releve"] == "2026-11-02"


def test_csv_equals_the_payload_totals() -> None:
    """CSV = PDF = run: the rows add up to the gross and to the commission the payload states."""
    p = statement_payload()
    rows = list(
        csv.reader(
            io.StringIO(render_statement_csv(p).decode("utf-8-sig"), newline=""), delimiter=";"
        )
    )[1:]
    t = p["totals"]
    assert sum(int(r[13]) for r in rows) == int(t["gross_minor"])
    assert sum(int(r[18]) for r in rows) == int(t["commission_ht_minor"])
    assert sum(1 for r in rows if not r[8].startswith("Commission sur")) == t["line_count"]
    # the per-file table of the PDF and the natures add up to the same
    assert sum(int(f["amount_minor"]) for f in p["files"]) == int(t["gross_minor"])
    assert sum(int(f["commission_minor"]) for f in p["files"]) == int(t["commission_ht_minor"])
    assert sum(int(n["amount_minor"]) for n in p["natures"]) == int(t["gross_minor"])


def test_the_natures_and_late_lines_are_worded() -> None:
    lines = line_records(statement_payload())
    assert [x.nature for x in lines] == [
        "Paiement imputé",
        "Paiement imputé",
        "Paiement repris par la banque du payeur",
        "Reversement sans imputation (dossier rappelé)",
        "Paiement imputé",
        "Commission sur un encaissement du relevé RV-2026-000001",
    ]
    assert lines[1].late == "oui \u2013 IBAN du mandant à confirmer"
    assert lines[4].rules == "Commission en attente" and lines[4].commission_minor == 0
    assert lines[0].rates == "15\u00a0%"


def test_a_field_holding_a_quote_or_a_line_break_is_quoted() -> None:
    p = statement_payload()
    p["lines"][0][4] = 'Durand "le jeune";\nSARL'
    body = render_statement_csv(p).decode("utf-8-sig")
    rows = list(csv.reader(io.StringIO(body, newline=""), delimiter=";"))
    assert rows[1][5] == 'Durand "le jeune";\nSARL' and len(rows) == 7


# -- the statement's summary ----------------------------------------------------------------------

STATEMENT_SNAPSHOT_START = """Relevé de reversement
N° RV-2026-000002
Établi le 02/11/2026
Encaissements connus au 02/11/2026 à 05:47

Collectoo SAS au capital de 10\u202f000\u00a0€
SIREN 732\u202f829\u202f320 · RCS Paris
Siège social : 10 rue de la Bourse, 75002 Paris
N° de TVA intracommunautaire : FR44732829320
agissant en qualité de mandataire de recouvrement amiable

Mandant : Martin SAS
SIREN 552\u202f100\u202f554
3 quai Perrache, Bât. B, 69002 Lyon
Mandat MAND-MARTIN-2026 du 15/01/2026 (rémunération : art. 6 ; reversements : art. 7 ; \
compensation : art. 7.2 ; reprise des avances : art. 7.4)
Période : du 21/10/2026 au 02/11/2026 · devise : EUR

Récapitulatif
Sommes encaissées pour votre compte : 2\u202f633,45\u00a0€
Encaissements annulés ou repris : -200,00\u00a0€
Montant brut à reverser : 2\u202f433,45\u00a0€
Factures de commission (TTC) : 464,40\u00a0€
Avoirs (TTC) : -36,00\u00a0€
Commission à régler par compensation : -568,40\u00a0€
Montant net du reversement : 1\u202f865,05\u00a0€
"""


def test_the_statement_text_snapshot() -> None:
    p = statement_payload()
    text = statement_text(p, GOLDEN_STATEMENT_CSV)
    assert text.startswith(STATEMENT_SNAPSHOT_START)
    for expected in (
        "Paiement repris par la banque du payeur (1) : -200,00\u00a0€",
        "L-003 | Société Nouvelle d'Équipement | 2 | 133,45\u00a0€ | 0,00\u00a0€",
        f"figure dans le fichier CSV joint (SHA-256 {GOLDEN_STATEMENT_CSV}).",
        "Facture FC-2026-000003 du 02/11/2026 (mandat MAND-MARTIN-2026) : HT 387,00\u00a0€, TVA "
        "20\u00a0% 77,40\u00a0€, TTC 464,40\u00a0€. À régler par compensation sur le présent "
        "reversement (art. 7.2 du mandat) : 464,40\u00a0€.",
        "Rectifie la facture FC-2026-000001 du 20/10/2026.",
        "Virement de 1\u202f865,05\u00a0€ ordonné le 02/11/2026 vers FR76 •••• •••• •••• 1234 "
        "(titulaire MARTIN SAS), exécution demandée le 03/11/2026, référence RMT0A1B2C3D4E5F.",
        "Relevé RV-2026-000001 : virement de 1\u202f000,00\u00a0€ débité de notre compte dédié le "
        "21/10/2026.",
        "Dossier L-002 : 150,00\u00a0€ reçus et en attente — paiement bloqué (procédure en cours) "
        "(du 12/10/2026 au 19/10/2026).",
        "Dossier L-009 : 80,00\u00a0€ restitués au payeur — trop-perçu (le 21/10/2026).",
        "Sommes vous revenant au 02/11/2026 : 2\u202f433,45\u00a0€",
        "Factures de commission restant dues au 02/11/2026 : 140,00\u00a0€",
    ):
        assert expected in text, expected


def test_nothing_says_paid_before_the_banks_debit() -> None:
    """« ordonné », « à régler par compensation »: never « payé » or « réglé » (M2c-6 books the
    debit), whatever the run's state."""
    p = statement_payload()
    variants = [p]
    zero = statement_payload()
    zero["payout"] = None
    zero["totals"]["net_minor"] = "0"
    variants.append(zero)
    cancelled = statement_payload()
    cancelled["status"], cancelled["cancelled_on"] = "cancelled", "2026-11-02"
    variants.append(cancelled)
    pending = statement_payload()
    pending["follow_up"][0]["transfer_status"] = "in_file"
    variants.append(pending)
    for v in variants:
        text = statement_text(v, GOLDEN_STATEMENT_CSV).lower()
        assert " payé" not in text and " réglé" not in text and "payée" not in text
    assert "aucun virement : le montant net est nul" in statement_text(zero, "0" * 64).lower()
    assert "annulé le 02/11/2026 avant l'exécution" in statement_text(cancelled, "0" * 64)
    assert "son débit n'est pas encore constaté" in statement_text(pending, "0" * 64)


def test_above_two_thousand_files_the_pdf_names_the_csv() -> None:
    p = statement_payload()
    p["files"] = [
        {
            "file": f"L-{i:05d}",
            "debtor": "D",
            "lines": "1",
            "amount_minor": "1",
            "commission_minor": "0",
            "late": "0",
        }
        for i in range(PDF_FILE_ROWS_MAX + 1)
    ]
    text = statement_text(p, "a" * 64)
    assert (
        f"{PDF_FILE_ROWS_MAX + 1} dossiers : détail complet dans le fichier CSV joint "
        f"(SHA-256 {'a' * 64})." in text
    )
    assert "Dossier | Débiteur" not in text


# -- the invoices: mentions ----------------------------------------------------------------------


def test_the_invoice_mentions() -> None:
    """CGI ann. II 242 nonies A 1°, 2°, 6° to 11°; R123-237/238; L441-9; L441-10 II; D441-5."""
    text = invoice_text(_doc(invoice_payload()))
    for mention, basis in (
        ("Facture\nN° FC-2026-000003\nDate d'émission : 02/11/2026", "242 nonies A 6°, 7°"),
        ("Collectoo SAS au capital de 10\u202f000\u00a0€", "242 nonies A 1°; R123-238"),
        ("SIREN 732\u202f829\u202f320 · RCS Paris", "242 nonies A 1°; R123-237 1°, 2°"),
        ("Siège social : 10 rue de la Bourse, 75002 Paris", "242 nonies A 1°; R123-237 3°"),
        ("N° de TVA intracommunautaire : FR44732829320", "242 nonies A 2°"),
        (
            "Client : Martin SAS\nSIREN 552\u202f100\u202f554\n3 quai Perrache, Bât. B, 69002 Lyon",
            "242 nonies A 1°",
        ),
        ("Prestations de services", "242 nonies A 8° bis"),
        (
            "Recouvrement amiable de créances pour votre compte — encaissements du 21/10/2026 au "
            "02/11/2026",
            "242 nonies A 10°",
        ),
        ("| 1 | 375,00\u00a0€ | 20\u00a0% | 375,00\u00a0€", "242 nonies A 8°"),
        ("Aucun rabais, remise ni ristourne.", "242 nonies A 9°"),
        (
            "Total HT : 387,00\u00a0€\nTVA 20\u00a0% sur 387,00\u00a0€ : 77,40\u00a0€\n"
            "Total TTC : 464,40\u00a0€",
            "242 nonies A 11°",
        ),
        (
            "À régler par compensation sur le reversement RV-2026-000002 (exécution demandée le "
            "03/11/2026 ; mandat MAND-MARTIN-2026, art. 7.2).",
            "L441-9 I",
        ),
        ("Pas d'escompte pour paiement anticipé.", "L441-9 I"),
        (
            "Pénalités de retard : taux d'intérêt appliqué par la Banque centrale européenne",
            "L441-10 II",
        ),
        (
            "Indemnité forfaitaire pour frais de recouvrement en cas de retard de paiement : "
            "40,00\u00a0€.",
            "L441-10 II; D441-5",
        ),
    ):
        assert mention in text, basis
    assert "Option pour le paiement de la taxe d'après les débits" not in text
    assert "CGI" not in text and "article" not in text.lower()  # no article number (design §3.1)


def test_the_mentions_frozen_at_issue_are_the_payloads() -> None:
    """The penalty text, the indemnity, the own account and the date come from the payload (M2c-4
    froze them before hashing), never from the current settings."""
    due = invoice_text(_doc(due_invoice_payload()))
    assert (
        "À régler au plus tard le 02/12/2026 par virement sur le compte FR76 3000 6000 0112 3456 "
        "7890 189 (BIC AGRIFRPPXXX), titulaire Collectoo."
    ) in due
    no_indemnity = invoice_payload(
        flat_indemnity={"applies": False, "amount_minor": None},
        penalty_text="Pénalités : 3 fois le taux d'intérêt légal.",
        vat_on_debits=True,
    )
    text = invoice_text(_doc(no_indemnity))
    assert "Indemnité forfaitaire" not in text  # not claimed: a proceeding, or not professional
    assert "Pénalités : 3 fois le taux d'intérêt légal." in text
    assert "Option pour le paiement de la taxe d'après les débits." in text
    nxt = invoice_payload(
        reason="run_cancelled",
        payment_reference={"mode": "next_run", "latest_date": "2026-12-02"},
        due_date="2026-12-02",
    )
    assert (
        "À régler par compensation sur le prochain reversement de vos encaissements, au plus "
        "tard le 02/12/2026 (mandat MAND-MARTIN-2026, art. 7.2)."
    ) in invoice_text(_doc(nxt))
    po = invoice_text(_doc(invoice_payload(po_number="BC-77")))
    assert "Votre bon de commande n° BC-77" in po


def test_the_credit_note_names_the_invoice_it_rectifies() -> None:
    """CGI 289 I 5, 272 1: each line and the mention name the rectified invoice."""
    text = invoice_text(_doc(credit_note_payload(), CREDIT_REFS))
    assert text.startswith("Avoir\nN° FC-2026-000004\n")
    assert (
        "Avoir n° FC-2026-000004 rectifiant la facture FC-2026-000001 du 20/10/2026 : HT "
        "-30,00\u00a0€, TVA -6,00\u00a0€."
    ) in text
    assert (
        "Avoir rectifiant la facture FC-2026-000001 du 20/10/2026 — encaissements annulés" in text
    )
    assert "TVA 20\u00a0% sur -30,00\u00a0€ : -6,00\u00a0€" in text
    assert "Aucun rabais" not in text and "Indemnité" not in text and "escompte" not in text


def test_a_credit_note_on_invoices_of_two_rates_states_each() -> None:
    p = credit_note_payload()
    p["corrections"].append(
        {
            "original_invoice_id": "c0000000-0000-0000-0000-000000000002",
            "vat_rate": "0.1000",
            "ht": "-1000",
            "vat": "-100",
        }
    )
    totals = dict(invoice_view(_doc(p, CREDIT_REFS)).totals)
    assert totals["TVA 20\u00a0% sur -30,00\u00a0€"] == "-6,00\u00a0€"
    assert totals["TVA 10\u00a0% sur -10,00\u00a0€"] == "-1,00\u00a0€"


def test_an_unknown_template_is_refused() -> None:
    doc = InvoiceDocument("FC-1", "invoice", ISSUE, invoice_payload(), {}, "facture-xx")
    with pytest.raises(ValueError, match="unknown invoice template"):
        invoice_view(doc)


# -- deterministic bytes --------------------------------------------------------------------------


def test_the_golden_hashes() -> None:
    assert RENDERER_VERSION == GOLDEN_RENDERER
    assert (TEMPLATE_VERSION, INVOICE_TEMPLATE) == (
        "releve-reversement-fr-1",
        "facture-commission-fr-1",
    )
    p = statement_payload()
    data = render_statement_csv(p)
    assert _sha(data) == GOLDEN_STATEMENT_CSV
    pdf = render_statement_pdf(p, _sha(data))
    assert pdf == render_statement_pdf(p, _sha(data))
    assert _sha(pdf) == GOLDEN_STATEMENT_PDF
    assert _sha(render_invoice_pdf(_doc(invoice_payload()))) == GOLDEN_INVOICE_PDF
    assert _sha(render_invoice_pdf(_doc(due_invoice_payload()))) == GOLDEN_DUE_PDF
    assert _sha(render_invoice_pdf(_doc(credit_note_payload(), CREDIT_REFS))) == GOLDEN_CREDIT_PDF


def test_the_pdf_depends_on_the_payload_only() -> None:
    p = statement_payload()
    a = render_statement_pdf(p, "a" * 64)
    assert render_statement_pdf(p, "b" * 64) != a  # it names the CSV
    q = statement_payload()
    q["totals"]["net_minor"] = "186506"
    assert render_statement_pdf(q, "a" * 64) != a


def test_reportlab_settings_of_the_environment_do_not_change_the_bytes(tmp_path: Path) -> None:
    payload = tmp_path / "p.json"
    payload.write_text(json.dumps(statement_payload()))
    script = (
        "import hashlib, json, sys; from collectoo_worker.remittance.statement_csv import "
        "render_statement_csv; from collectoo_worker.remittance.statement_pdf import "
        "render_statement_pdf; p = json.load(open(sys.argv[1])); c = render_statement_csv(p); "
        "h = hashlib.sha256(c).hexdigest(); print(h, hashlib.sha256(render_statement_pdf(p, h))"
        ".hexdigest())"
    )
    (tmp_path / "reportlab_settings.py").write_text("invariant = 0\nttfAsciiReadable = 0\n")
    for env in (
        {"RL_invariant": "0", "RL_ttfAsciiReadable": "0", "TZ": "Pacific/Auckland"},
        {"PYTHONPATH": str(tmp_path), "SOURCE_DATE_EPOCH": "1"},
    ):
        out = subprocess.run(  # noqa: S603 - our own interpreter and code
            [sys.executable, "-c", script, str(payload)],
            capture_output=True,
            text=True,
            check=False,
            env={k: v for k, v in os.environ.items() if not k.startswith("RL_")} | env,
            cwd=tmp_path,
        )
        assert out.returncode == 0, out.stderr
        assert out.stdout.split() == [GOLDEN_STATEMENT_CSV, GOLDEN_STATEMENT_PDF], env


def test_a_long_statement_runs_over_pages() -> None:
    p = statement_payload()
    p["files"] = [
        {
            "file": f"L-{i:05d}",
            "debtor": "Débiteur au nom assez long pour passer à la ligne SARL",
            "lines": "1",
            "amount_minor": str(123_456_789 + i),
            "commission_minor": "0",
            "late": "0",
        }
        for i in range(300)
    ]
    pdf = render_statement_pdf(p, "a" * 64)
    assert pdf.count(b"/Type /Page\n") >= 6 or pdf.count(b"/Type /Page") >= 6
