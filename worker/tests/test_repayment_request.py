"""The letter « Demande de remboursement d'avance » (M2c-7c-2; plan docs/design/m2c-7-plan.md §5.3,
§5.7 « Worker »; template `demande-remboursement-avance-fr-1`): deterministic, from the payload SQL
froze (private.advance_repayment_payload), no model, no LLM. Its text snapshot; one origin per
cause and per way the item reached the client, each date a recording date and each origin in the
real order of events ([critic] L3, M7-MONEY-9: a « Désimputer » after the payout, a reversal while
the run was in flight, a partial bank return; [check 1] an origin per `paid_how` — paid, paid
through a later run, set off, netted, and paid by a payout outside any run); a multi-mandate
request; no RMT, SWP or TOP id anywhere ([critic] M7-MONEY-6); never « versé » for an N = 0 run;
no legal article, interest, penalty, due date or formal notice (founder Q6); the amounts as the
payload states them (nothing computed but their French form); golden SHA-256 of the PDF.
"""

from __future__ import annotations

import copy
import hashlib
import re
from datetime import date
from typing import Any

import pytest
from hypothesis import given
from hypothesis import strategies as st
from repayment_cases import (
    curatelle_payload,
    every_origin_payload,
    request_payload,
    reversal,
    row,
    tutelle_payload,
)

from collectoo_worker.remittance.pdf import RENDERER_VERSION
from collectoo_worker.remittance.repayment_request import (
    TEMPLATE_VERSION,
    RepaymentRequestDocument,
    RepaymentRequestPayloadError,
    mandate_text,
    origin_text,
    request_text,
    request_view,
)
from collectoo_worker.remittance.repayment_request_pdf import pdf_sha256, render_request_pdf

GOLDEN_RENDERER = "reportlab-4.4.10/dejavu-2.37/d1"
GOLDEN_REQUEST_PDF = "5caae878afb31020f7380687911fd3cf140184b4623928b27f6ad86609970ec2"
GOLDEN_EVERY_ORIGIN_PDF = "42574b464724fe1c6065be06df5cc0f826a2b159eac8f95df2b6045ff5ac97f1"
# M2c-7d-1: the two addressees of a curatelle (the client, a copy to its curator)
GOLDEN_CURATELLE_PDF = "5f5ca25c3051575e17b91dec818cff43961806dca7c16b63c39ae6c6df41cf74"
NNBSP = "\u202f"
NBSP = "\u00a0"


def _doc(payload: dict[str, Any]) -> RepaymentRequestDocument:
    return RepaymentRequestDocument(
        number=str(payload["number"]),
        issue_date=date.fromisoformat(str(payload["issue_date"])),
        payload=payload,
    )


def test_the_letter_text_snapshot() -> None:
    text = request_text(_doc(request_payload()))
    assert text == "\n".join(
        [
            f"Collectoo SAS au capital de 10{NNBSP}000{NBSP}€",
            f"SIREN 732{NNBSP}829{NNBSP}320 · RCS Paris",
            "Siège social : 1 rue de la Paix, 75002 Paris",
            "",
            "Martin SAS",
            "12 avenue des Tilleuls, 69003 Lyon",
            "",
            "Le 20/11/2026",
            "Objet : Demande de remboursement — référence DRA-2026-000001",
            "",
            "Madame, Monsieur,",
            "",
            "La somme ci-dessous vous a été versée au-delà de ce qui vous revenait. Elle reste à "
            "rembourser au cabinet.",
            "",
            "Date | Mandat | Origine | Versé | Déjà remboursé | Demandé",
            "20/11/2026 | MAND-MARTIN-2026 | Encaissement du 12/10/2026 (dossier F-103), versé le "
            "03/11/2026 (relevé RV-2026-000001), puis repris par la banque du payeur le 12/11/2026 "
            "| "
            f"2{NNBSP}000,00{NBSP}€ | 0,00{NBSP}€ | 2{NNBSP}000,00{NBSP}€",
            "",
            f"Total à rembourser : 2{NNBSP}000,00{NBSP}€",
            "",
            "Nous vous remercions de bien vouloir nous rembourser cette somme par virement sur "
            "notre "
            "compte : titulaire Collectoo, IBAN FR76 1010 7001 0112 3456 7890 129, en indiquant la "
            "référence DRA-2026-000001.",
            "",
            "Ce document n'est pas une facture.",
            "",
            "Veuillez agréer, Madame, Monsieur, l'expression de nos salutations distinguées.",
            "Collectoo",
            "",
            "Demande de remboursement n° DRA-2026-000001",
        ]
    )


EVERY_ORIGIN = [
    # a reversal recorded after the covered payout's debit: a bank return, a « Désimputer »
    "Encaissement du 12/10/2026 (dossier F-103), versé le 03/11/2026 (relevé RV-2026-000001), puis "
    "repris par la banque du payeur le 12/11/2026",
    "Encaissement du 12/10/2026 (dossier F-103), versé le 03/11/2026 (relevé RV-2026-000001), puis "
    "annulé le 13/11/2026 (imputation corrigée)",
    # [critic] M7-MONEY-9: a partial bank return (every allocation reversed)
    "Encaissement du 12/10/2026 (dossier F-103), versé le 03/11/2026 (relevé RV-2026-000001), puis "
    f"paiement repris en partie par la banque le 14/11/2026 (90,00{NBSP}€) ; imputation annulée en "
    f"entier (150,00{NBSP}€)",
    # a reversal recorded while the run was in flight (the at-booking cover)
    "Encaissement du 12/10/2026 (dossier F-103), repris par la banque du payeur le 01/11/2026 "
    "alors "
    "que le reversement RV-2026-000001 était en cours, puis versé le 03/11/2026 (relevé "
    "RV-2026-000001)",
    "Encaissement du 12/10/2026 (dossier F-103), imputation annulée le 02/11/2026 alors que le "
    "reversement RV-2026-000001 était en cours, puis versé le 03/11/2026 (relevé RV-2026-000001)",
    # (review round 1, TUI-1) recorded while the run was in flight, after the bank had paid it:
    # the dates' order, never « alors que … en cours, puis versé » before the reversal's day
    "Encaissement du 12/10/2026 (dossier F-103), versé le 03/11/2026 (relevé RV-2026-000001), puis "
    "annulé le 04/11/2026 (imputation corrigée)",
    # [check 1] paid through a later run after the run's own payout, or a payout outside any run,
    # came back
    "Encaissement du 12/10/2026 (dossier F-103), repris par la banque du payeur le 12/11/2026, "
    "puis "
    "versé le 18/11/2026 (relevé RV-2026-000004, après le retour du virement du relevé "
    "RV-2026-000001)",
    "Encaissement du 12/10/2026 (dossier F-103), repris par la banque du payeur le 12/11/2026, "
    "puis "
    "versé le 18/11/2026 (relevé RV-2026-000005, après le retour d'un virement hors reversement)",
    # paid in full by a payout outside any run, kept
    "Encaissement du 12/10/2026 (dossier F-103), versé le 06/11/2026 par un virement hors "
    "reversement, puis repris par la banque du payeur le 12/11/2026",
    # an N = 0 run: never « versé »
    "Encaissement du 12/10/2026 (dossier F-103), réglé par compensation dans le relevé "
    "RV-2026-000001 du 04/11/2026, puis annulé le 12/11/2026 (imputation corrigée)",
    "Encaissement du 12/10/2026 (dossier F-103), compris dans le relevé RV-2026-000001 du "
    "05/11/2026 (montant net nul), puis annulé le 12/11/2026 (imputation corrigée)",
    # a forward on no file
    "Encaissement du 12/10/2026, versé le 03/11/2026 (relevé RV-2026-000001), puis annulé le "
    "15/11/2026",
    "Reversement RV-2026-000002 versé le 07/11/2026 pour un montant supérieur à ce qui vous "
    "restait "
    "dû",
    "Virement exécuté par notre banque le 08/11/2026 en plus du reversement RV-2026-000003, "
    "au-delà "
    "de ce qui vous restait dû",
    "Virement exécuté par notre banque le 09/11/2026 hors de tout reversement, au-delà de ce qui "
    "vous restait dû",
]


def test_each_origin_is_worded_from_its_facts_in_the_real_order() -> None:
    rows = every_origin_payload()["rows"]
    assert [origin_text(r) for r in rows] == EVERY_ORIGIN


def test_the_mandate_column() -> None:
    rows = every_origin_payload()["rows"]
    assert [mandate_text(r) for r in rows] == [
        *["MAND-MARTIN-2026"] * 11,
        "—",  # a remitted forward on no file: no mandate stated
        "plusieurs mandats",  # an overrun of a run of several mandates
        "MAND-MARTIN-2026",
        "—",  # a double payout outside any run
    ]


def test_a_multi_mandate_request_lists_each_row_and_its_total() -> None:
    v = request_view(_doc(every_origin_payload()))
    assert len(v.rows) == 15
    # (review round 1, TUI-2) some of its rows were set off or netted (an N = 0 run): never
    # « versées » nor « Versé » for the whole request
    assert v.opening == (
        "Les sommes ci-dessous vous ont été réglées au-delà de ce qui vous revenait. Elles restent "
        "à "
        "rembourser au cabinet."
    )
    assert v.head == ("Date", "Mandat", "Origine", "Montant", "Déjà remboursé", "Demandé")
    third = v.rows[2]
    assert (third.paid, third.repaid, third.owed) == (
        f"150,00{NBSP}€",
        f"50,00{NBSP}€",
        f"100,00{NBSP}€",
    )
    assert v.total_line == f"Total à rembourser : 3{NNBSP}030,00{NBSP}€"


def test_no_rmt_swp_or_top_reference_nor_legal_mention_anywhere() -> None:
    for payload in (request_payload(), every_origin_payload()):
        text = request_text(_doc(payload))
        assert not re.search(r"\b(RMT|SWP|TOP)[0-9A-F]", text), text
        low = text.lower()
        for word in (
            "article",
            "art.",
            "intérêt",
            "pénalit",
            "mise en demeure",
            "au plus tard",
            "délai",
        ):
            assert word not in low, word
        assert "facture" in low and "n'est pas une facture" in low


def test_an_n0_run_is_never_said_versed() -> None:
    for how in ("set_off", "netted"):
        r = row(reversal(paid_how=how, paid_on="2026-11-04", reversal="unallocated"))
        assert "versé" not in origin_text(r), how


def test_a_request_of_n0_runs_only_never_says_versed_anywhere() -> None:
    """(review round 1, TUI-2) [check 1] / ADR D6: never « versé » for an N = 0 run — nor in the
    opening or the amount's column of a request whose rows were all set off or netted; a request
    of payouts alone keeps the plan's wording (the snapshot above)."""
    rows = [
        row(
            reversal(paid_how=how, paid_on="2026-11-04", reversal="unallocated"),
            amount=amount,
            advance_id=f"00000000-0000-4000-8000-00000000002{i}",
        )
        for i, (how, amount) in enumerate((("set_off", "7000"), ("netted", "6000")))
    ]
    for rs in (rows, rows[:1]):
        doc = _doc(request_payload(rs))
        text = request_text(doc)
        assert "versé" not in text.lower(), text
        v = request_view(doc)
        assert v.head[3] == "Montant"
        assert "réglée" in v.opening
    one = request_view(_doc(request_payload(rows[:1])))
    assert one.opening == (
        "La somme ci-dessous vous a été réglée au-delà de ce qui vous revenait. Elle reste à "
        "rembourser au cabinet."
    )
    paid = request_view(_doc(request_payload()))
    assert paid.head[3] == "Versé" and "versée" in paid.opening


def test_a_reversal_in_flight_is_worded_in_the_order_of_its_dates() -> None:
    """(review round 1, TUI-1) [critic] L3, M7-MONEY-9: a reversal recorded while its run was in
    flight comes first only when it is not dated after the payout's bank date (the debit's
    booking date may precede the « Désimputer » when its statement is imported the next day)."""
    before = row(reversal(in_flight=True, reversal="unallocated", reversed_on="2026-11-02"))
    same = row(reversal(in_flight=True, reversal="unallocated", reversed_on="2026-11-03"))
    after = row(reversal(in_flight=True, reversal="unallocated", reversed_on="2026-11-04"))
    assert "alors que le reversement" in origin_text(before)
    assert "alors que le reversement" in origin_text(same)
    text = origin_text(after)
    assert "alors que" not in text
    assert text.index("versé le 03/11/2026") < text.index("annulé le 04/11/2026"), text


def test_a_payout_that_came_back_is_never_stated_as_received() -> None:
    """The request refuses payout_not_received (paid_on null): the letter refuses such a row too."""
    p = request_payload([row(reversal(paid_on=None, paid_how=None, paid_run_number=None))])
    with pytest.raises(RepaymentRequestPayloadError, match="not received"):
        request_text(_doc(p))


def test_a_payload_that_does_not_add_up_or_an_unknown_template_is_refused() -> None:
    p = request_payload()
    p["total_minor"] = "199999"
    with pytest.raises(RepaymentRequestPayloadError, match="total"):
        request_text(_doc(p))
    q = request_payload()
    q["rows"][0]["cause"] = "gift"
    with pytest.raises(RepaymentRequestPayloadError, match="cause"):
        request_text(_doc(q))
    with pytest.raises(RepaymentRequestPayloadError, match="template"):
        request_text(
            RepaymentRequestDocument(
                "DRA-2026-000001", date(2026, 11, 20), request_payload(), "x-1"
            )
        )


@given(
    st.lists(st.integers(min_value=1, max_value=10**12), min_size=1, max_size=8),
    st.data(),
)
def test_the_amounts_are_the_payload_s(amounts: list[int], data: st.DataObject) -> None:
    """Every amount printed is the payload's, in French form: each row's three and the total."""
    rows = []
    for i, amount in enumerate(amounts):
        repaid = data.draw(st.integers(min_value=0, max_value=amount - 1))
        rows.append(
            row(
                reversal(),
                amount=str(amount),
                repaid=str(repaid),
                advance_id=f"00000000-0000-4000-8000-{i:012d}",
            )
        )
    v = request_view(_doc(request_payload(rows)))
    for r, x in zip(rows, v.rows, strict=True):
        assert int(re.sub(r"[^0-9]", "", x.paid)) == int(r["amount_minor"])
        assert int(re.sub(r"[^0-9]", "", x.owed)) == int(r["open_minor"])
        assert int(re.sub(r"[^0-9]", "", x.repaid)) == int(r["repaid_minor"])
    assert int(re.sub(r"[^0-9]", "", v.total_line)) == sum(int(r["open_minor"]) for r in rows)


def test_the_golden_hashes() -> None:
    assert RENDERER_VERSION == GOLDEN_RENDERER
    assert TEMPLATE_VERSION == "demande-remboursement-avance-fr-1"
    one = render_request_pdf(_doc(request_payload()))
    assert one == render_request_pdf(_doc(request_payload()))
    assert pdf_sha256(one) == hashlib.sha256(one).hexdigest() == GOLDEN_REQUEST_PDF
    every = render_request_pdf(_doc(every_origin_payload()))
    assert pdf_sha256(every) == GOLDEN_EVERY_ORIGIN_PDF


def test_the_pdf_depends_on_the_payload_only() -> None:
    a = render_request_pdf(_doc(request_payload()))
    p = copy.deepcopy(request_payload())
    p["rows"][0]["origin"]["reversed_on"] = "2026-11-13"
    assert render_request_pdf(_doc(p)) != a
    assert render_request_pdf(_doc(request_payload(number="DRA-2026-000009"))) != a


# -- M2c-7d-1 (plan §6.2.12; [critic] L12, [check 1] gap 7): who receives the letter ---------------


def test_after_a_tutelle_the_letter_is_addressed_to_the_tutor_for_the_client() -> None:
    """C. civ. 473 al. 1 (« le tuteur la représente dans tous les actes de la vie civile »): the
    tutor is the addressee; the sums were paid to the client, so the letter says so in the third
    person; nothing else changes."""
    text = request_text(_doc(tutelle_payload()))
    lines = text.split("\n")
    assert lines[4:8] == [
        "UDAF du Rhône",
        "Tuteur de Martin SAS",
        "3 place du Palais, 69002 Lyon",
        "",
    ]
    assert (
        "La somme ci-dessous a été versée à Martin SAS au-delà de ce qui lui revenait. Elle reste "
        "à rembourser au cabinet." in lines
    )
    assert "vous a été versée" not in text
    assert "Copie" not in text


def test_after_a_curatelle_the_client_receives_it_with_a_copy_to_its_curator() -> None:
    """C. civ. 440 al. 1 (the curatelle assists, it does not represent); the copy is the
    servicer's rule by analogy with 467 al. 3, which governs significations (OQ-94): the client
    is the addressee, the curator's copy printed under its block."""
    text = request_text(_doc(curatelle_payload()))
    lines = text.split("\n")
    assert lines[4:8] == [
        "Martin SAS",
        "12 avenue des Tilleuls, 69003 Lyon",
        "Copie : Association Tutélaire de Lyon, curateur, 3 place du Palais, 69002 Lyon",
        "",
    ]
    assert "La somme ci-dessous vous a été versée au-delà de ce qui vous revenait." in text


def test_a_plain_client_s_letter_is_unchanged() -> None:
    """The golden request (no representative, no copy) keeps its bytes (test_the_golden_hashes)."""
    v = request_view(_doc(request_payload()))
    assert v.recipient_lines == ("Martin SAS", "12 avenue des Tilleuls, 69003 Lyon")


def test_an_unknown_role_or_a_copy_without_its_address_is_refused() -> None:
    p = tutelle_payload()
    p["recipient"] = p["recipient"] | {"role": "cousin"}
    with pytest.raises(RepaymentRequestPayloadError):
        request_view(_doc(p))
    q = curatelle_payload()
    q["copies"] = [{"role": "curator", "name": "X", "address_lines": []}]
    with pytest.raises(RepaymentRequestPayloadError):
        request_view(_doc(q))


def test_the_golden_hash_of_a_curatelle_s_letter() -> None:
    one = render_request_pdf(_doc(curatelle_payload()))
    assert one == render_request_pdf(_doc(curatelle_payload()))
    assert pdf_sha256(one) == GOLDEN_CURATELLE_PDF
    assert pdf_sha256(render_request_pdf(_doc(tutelle_payload()))) != pdf_sha256(one)
