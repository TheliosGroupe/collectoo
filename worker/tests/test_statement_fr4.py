"""The statement fr-4 (M2c-7d-3; plan docs/design/m2c-7-plan.md §6.2.8, §6.4; ADR-0014
« M2c-7d-3 »): a payload of schema 2 — the end of the mandate as of K ([critic] L13: its date and
the day the servicer recorded it, C. civ. 2008), the payee it requires, who the statement is
addressed to ([critic] L12: the role only, the names and addresses stay staff's), a set-off a
debit withheld and this run gives back ([critic] M7-MONEY-5), each advance taken back with its date
(§1.2) — is drawn by `releve-reversement-fr-4`; a payload of schema 1 keeps fr-3 and its bytes.
Every amount and date is the payload's; nothing is presented as the law's but what the texts say."""

from __future__ import annotations

import copy
import hashlib
from typing import Any

import pytest
from document_cases import (
    cancelled_statement_payload,
    fr4_curatorship_payload,
    fr4_statement_payload,
    fr4_withheld_payload,
    statement_payload,
)

from collectoo_worker.remittance.statement import (
    TEMPLATE_V3,
    TEMPLATE_VERSION,
    TEMPLATE_VERSIONS,
    StatementPayloadError,
    line_records,
    statement_text,
    statement_view,
    template_of,
)
from collectoo_worker.remittance.statement_csv import render_statement_csv
from collectoo_worker.remittance.statement_pdf import render_statement_pdf

# M2c-7d-3: the fr-4 fixtures' bytes, each a statement the SQL can build (review round 1, TUI-3):
# the end of the mandate (its PDF the « Fin du mandat » block, the addressee, the invoice due,
# nothing set off) and the withheld set-off given back (its CSV the withheld line; its PDF the
# withheld row and the advance's date, both in the totals); each PDF names fr-4 its creator
GOLDEN_FR4_CSV = "38d598d577aada2c4c867cc7973cb1f0882d9db585013155cfde491cceb31ffe"
GOLDEN_FR4_PDF = "2bb6194f9ac5e0b0a7b31dbd99818336efaa41e01d52b3fa36d3c9130ef6dd43"
GOLDEN_FR4_WITHHELD_CSV = "8cfd04ed89605f23b22d878fe28a88b9c4047a0221b8b2a6df394be512807cc6"
GOLDEN_FR4_WITHHELD_PDF = "da6bc20564b6a94ecb00ad0cd8f628c5ede36c9f59b0d8a698b183a7c6e88dbf"
SHA = "0" * 64


def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _section(payload: dict[str, object], title: str) -> tuple[str, ...]:
    return next(s.texts for s in statement_view(payload, SHA).sections if s.title == title)


def test_the_template_follows_the_payload_s_schema() -> None:
    assert (TEMPLATE_V3, TEMPLATE_VERSION) == (
        "releve-reversement-fr-3",
        "releve-reversement-fr-4",
    )
    assert TEMPLATE_VERSIONS == ("releve-reversement-fr-3", "releve-reversement-fr-4")
    assert template_of(statement_payload()) == "releve-reversement-fr-3"
    assert template_of(fr4_statement_payload()) == "releve-reversement-fr-4"
    later = statement_payload()
    later["schema"] = 3
    with pytest.raises(StatementPayloadError, match="payload_version"):
        template_of(later)
    # a schema-1 payload never carries fr-4's keys (the SQL builds schema 2 when one is needed)
    mixed = statement_payload()
    mixed["mandate_end"] = fr4_statement_payload()["mandate_end"]
    with pytest.raises(StatementPayloadError, match="payload_version"):
        render_statement_pdf(mixed, SHA)


def test_the_end_of_the_mandate_is_stated_as_the_code_applies_it() -> None:
    p = fr4_statement_payload()
    view = statement_view(p, SHA)
    assert view.sections[0].title == "Fin du mandat"
    assert view.sections[0].texts == (
        "Le mandat a pris fin le 25/10/2026 (décès du mandant) ; le cabinet en a été informé le "
        "30/10/2026.",
        "Ce relevé rend compte des sommes encaissées pour votre compte. Ce que le cabinet a fait "
        "avant d'en être informé l'a été selon le mandat ; depuis le 30/10/2026, les paiements "
        "reçus sur vos dossiers à partir du 25/10/2026 sont mis de côté : ils sont reversés sans "
        "commission, ou restitués à leurs payeurs, au cas par cas.",
        "Ce que vous devez au cabinet (factures, avances) figure dans la position ci-dessous ; "
        "depuis le 30/10/2026, il n'est plus déduit des reversements.",
        "Les reversements sont faits sur le compte confirmé de la succession (compte du notaire, "
        "ou compte désigné par tous les héritiers).",
    )
    # the rest of the statement, as fr-3 draws it
    assert [s.title for s in view.sections[1:]] == [
        s.title for s in statement_view(statement_payload(), SHA).sections
    ]


def _two_ends() -> dict[str, Any]:
    """(Review round 3) the death known first (25/10, recorded 30/10), then an old « Tutelle ou
    curatelle » row qualified a tutelle effective 01/10 on 02/11, before K: the code applied the
    death's end from 30/10 and the tutelle's from 02/11 (private.statement_mandate_end's
    `earlier`)."""
    p = fr4_statement_payload()
    p["mandate_end"].update(
        kind="guardianship", effective_date="2026-10-01", recorded_on="2026-11-02"
    )
    p["mandate_end"]["earlier"] = [
        {"kind": "death", "effective_date": "2026-10-25", "recorded_on": "2026-10-30"}
    ]
    return p


def test_two_ends_known_on_different_days_are_each_stated_with_their_own_day() -> None:
    """(Review round 3) every sentence true of what the code did: informed of an end from the
    first day, each end's payments set aside from the day it was known, nothing deducted from the
    first day."""
    assert _section(_two_ends(), "Fin du mandat") == (
        "Le mandat a pris fin le 01/10/2026 (tutelle du mandant) ; le cabinet en a été informé le "
        "02/11/2026.",
        "Auparavant, le cabinet avait été informé le 30/10/2026 d'une fin du mandat le 25/10/2026 "
        "(décès du mandant).",
        "Ce relevé rend compte des sommes encaissées pour votre compte. Ce que le cabinet a fait "
        "avant d'être informé d'une fin du mandat l'a été selon le mandat ; depuis le 30/10/2026, "
        "les paiements reçus sur vos dossiers à partir du 25/10/2026 sont mis de côté, et depuis "
        "le 02/11/2026, ceux reçus à partir du 01/10/2026 : ils sont reversés sans commission, ou "
        "restitués à leurs payeurs, au cas par cas.",
        "Ce que vous devez au cabinet (factures, avances) figure dans la position ci-dessous ; "
        "depuis le 30/10/2026, il n'est plus déduit des reversements.",
        "Les reversements sont faits sur le compte confirmé de la succession (compte du notaire, "
        "ou compte désigné par tous les héritiers).",
    )
    p = _two_ends()
    p["mandate_end"]["earlier"] = [
        {"kind": "mandate_ended", "effective_date": "2026-10-28", "recorded_on": "2026-10-28"},
        {"kind": "death", "effective_date": "2026-10-25", "recorded_on": "2026-10-30"},
    ]
    texts = _section(p, "Fin du mandat")
    assert texts[1] == (
        "Auparavant, le cabinet avait été informé le 28/10/2026 d'une fin du mandat le 28/10/2026 "
        "(révocation ou renonciation du mandat), puis le 30/10/2026 d'une fin du mandat le "
        "25/10/2026 (décès du mandant)."
    )
    assert texts[2].endswith(
        "depuis le 28/10/2026, les paiements reçus sur vos dossiers à partir du 28/10/2026 sont "
        "mis de côté, depuis le 30/10/2026, ceux reçus à partir du 25/10/2026, et depuis le "
        "02/11/2026, ceux reçus à partir du 01/10/2026 : ils sont reversés sans commission, ou "
        "restitués à leurs payeurs, au cas par cas."
    )
    assert texts[3].endswith("depuis le 28/10/2026, il n'est plus déduit des reversements.")
    # one end (no `earlier`, or an empty one): fr-4's sentences, unchanged
    one = fr4_statement_payload()
    one["mandate_end"]["earlier"] = []
    assert _section(one, "Fin du mandat") == _section(fr4_statement_payload(), "Fin du mandat")


@pytest.mark.parametrize(
    "spoil",
    [
        lambda e: e[0].update(kind="curatorship"),
        lambda e: e[0].pop("recorded_on"),
        lambda e: e[0].pop("effective_date"),
        # known on or after the end at K, or effective on or before it: not an end applied earlier
        lambda e: e[0].update(recorded_on="2026-11-02"),
        lambda e: e[0].update(effective_date="2026-10-01"),
        # two earlier ends out of order (each applied from its own day, each earlier in effect)
        lambda e: e.append(
            {"kind": "mandate_ended", "effective_date": "2026-10-28", "recorded_on": "2026-10-29"}
        ),
    ],
)
def test_an_earlier_end_fr4_cannot_word_truly_is_refused(spoil: object) -> None:
    p = _two_ends()
    spoil(p["mandate_end"]["earlier"])  # type: ignore[operator]
    with pytest.raises(StatementPayloadError, match="payload_version"):
        render_statement_pdf(p, SHA)


@pytest.mark.parametrize(
    ("kind", "payee", "cause", "account"),
    [
        ("guardianship", "protected_adult", "tutelle du mandant",
         "ouvert au nom du mandant, la personne protégée (C. civ. 427)"),
        ("mandate_ended", "client", "révocation ou renonciation du mandat",
         "du mandant, confirmé à nouveau"),
        ("death", "court_appointed", "décès du mandant", "du liquidateur"),
    ],
)  # fmt: skip
def test_each_end_and_payee_is_worded(kind: str, payee: str, cause: str, account: str) -> None:
    p = fr4_statement_payload()
    p["mandate_end"].update(kind=kind, payee_kind=payee)
    texts = _section(p, "Fin du mandat")
    assert texts[0] == (
        f"Le mandat a pris fin le 25/10/2026 ({cause}) ; le cabinet en a été informé le 30/10/2026."
    )
    assert texts[-1] == f"Les reversements sont faits sur le compte confirmé {account}."


def test_an_old_protection_measure_still_to_qualify_names_no_account() -> None:
    p = fr4_statement_payload()
    p["mandate_end"]["payee_kind"] = "to_qualify"
    assert _section(p, "Fin du mandat")[-1] == (
        "Les reversements sont suspendus jusqu'à ce que la mesure de protection soit précisée."
    )


def test_the_statement_is_addressed_by_role_only() -> None:
    view = statement_view(fr4_statement_payload(), SHA)
    assert view.client_lines[-1] == "À l'attention du notaire chargé de la succession du mandant"
    assert (
        statement_view(fr4_curatorship_payload(), SHA).client_lines[-1]
        == "Copie : le curateur du mandant"
    )
    for role, line in (
        ("tutor", "À l'attention du tuteur du mandant"),
        ("heirs", "À l'attention des héritiers du mandant"),
        ("liquidator", "À l'attention du liquidateur du mandant"),
        ("administrator", "À l'attention de l'administrateur judiciaire du mandant"),
    ):
        p = fr4_statement_payload()
        p["addressees"] = [{"role": role, "copy": False}]
        assert statement_view(p, SHA).client_lines[-1] == line
    # the client alone (no one acts for it): nothing more than fr-3's block
    alone = fr4_statement_payload()
    alone["addressees"] = [{"role": "client", "copy": False}]
    fr3 = statement_payload()
    fr3["client"] = alone["client"]
    assert statement_view(alone, SHA).client_lines == statement_view(fr3, SHA).client_lines


def test_the_withheld_set_off_given_back_and_the_advance_s_date() -> None:
    texts = _section(fr4_withheld_payload(), "Retenues et compensations")
    assert (
        "Compensation retenue sur RV-2026-000001 et rendue : 200,00\u00a0€. Au débit de son "
        "virement le 28/10/2026, cette compensation n'a pas été faite (« Compensation retenue : "
        "saisie entre les mains du cabinet depuis le 27/10/2026 (règle du cabinet) ») ; la somme "
        "est reprise dans le présent reversement."
    ) in texts
    assert (
        "Remboursement de l'avance du cabinet née le 09/10/2026 : à régler par compensation sur "
        "le présent reversement : 150,00\u00a0€."
    ) in texts
    # the line's nature, in the CSV
    natures = [r.nature for r in line_records(fr4_withheld_payload())]
    assert natures[-1] == "Compensation retenue au débit, rendue"


def test_a_cancelled_run_never_says_the_withheld_set_off_given_back() -> None:
    p = cancelled_statement_payload()
    p["schema"] = 2
    p["withheld_given_back"] = copy.deepcopy(fr4_withheld_payload()["withheld_given_back"])
    texts = _section(p, "Retenues et compensations")
    assert (
        "Compensation retenue sur RV-2026-000001 : 200,00\u00a0€. Au débit de son virement le "
        "28/10/2026, cette compensation n'a pas été faite (« Compensation retenue : saisie entre "
        "les mains du cabinet depuis le 27/10/2026 (règle du cabinet) ») ; ce reversement étant "
        "annulé, la somme figurera sur un prochain reversement."
    ) in texts
    assert not any("rendue" in t for t in texts)


@pytest.mark.parametrize(
    ("fixture", "spoil"),
    [
        (fr4_statement_payload, lambda p: p["mandate_end"].update(kind="curatorship")),
        (fr4_statement_payload, lambda p: p["mandate_end"].update(payee_kind="nobody")),
        (fr4_statement_payload, lambda p: p["mandate_end"].pop("recorded_on")),
        (fr4_statement_payload, lambda p: p.update(addressees=[{"role": "cousin", "copy": False}])),
        (fr4_withheld_payload, lambda p: p["withheld_given_back"][0].pop("reason")),
        (fr4_withheld_payload, lambda p: p["earlier_settled"][-1].pop("born_on")),
    ],
)
def test_a_fact_fr4_does_not_word_is_refused(fixture: object, spoil: object) -> None:
    p = fixture()  # type: ignore[operator]
    spoil(p)  # type: ignore[operator]
    with pytest.raises(StatementPayloadError, match="payload_version"):
        render_statement_pdf(p, SHA)


def test_no_fr4_text_says_paid_abandoned_or_remitted_debt() -> None:
    for p in (fr4_statement_payload(), fr4_withheld_payload(), fr4_curatorship_payload()):
        lower = statement_text(p, SHA).lower()
        assert "abandon" not in lower and "remise" not in lower and " payé" not in lower


@pytest.mark.parametrize("fixture", [fr4_statement_payload, fr4_withheld_payload])
def test_each_fr4_fixture_is_a_statement_the_books_can_make(fixture: object) -> None:
    """(Review round 1, TUI-3) the fixtures' figures hold together as the SQL builds them: the
    gross is what was collected less what was reversed, the settlement what is set off (commission
    and advances), the net the gross less it, the payout the net; the position closes."""
    p = fixture()  # type: ignore[operator]
    t = {k: int(v) for k, v in p["totals"].items()}
    assert t["gross_minor"] == t["collected_minor"] + t["reversed_minor"]
    assert t["settlement_minor"] == t["commission_taken_minor"] + t["advance_recovered_minor"]
    assert t["net_minor"] == t["gross_minor"] - t["settlement_minor"] + t["refund_minor"]
    assert int(p["payout"]["amount_minor"]) == t["net_minor"]
    taken = sum(int(d["settles_minor"]) for d in p["documents"] if d["kind"] == "invoice")
    earlier = [int(e["amount_minor"]) for e in p["earlier_settled"]]
    advances = [int(e["amount_minor"]) for e in p["earlier_settled"] if e["kind"] == "advance"]
    assert taken + sum(earlier) - sum(advances) == t["commission_taken_minor"]
    assert sum(advances) == t["advance_recovered_minor"]
    pos = {k: int(v) for k, v in p["position"].items()}
    assert pos["owed_before_minor"] - t["gross_minor"] == pos["owed_after_minor"] == 0
    assert pos["advances_before_minor"] - sum(advances) == pos["advances_after_minor"]
    files = sum(int(f["amount_minor"]) for f in p["files"])
    assert files == t["collected_minor"] + t["reversed_minor"]
    assert sum(int(n["amount_minor"]) for n in p["natures"]) == t["gross_minor"]


def test_after_the_end_of_the_mandate_nothing_is_set_off() -> None:
    """(Review round 1, TUI-3) the death's fixture: no set-off, no advance taken back, its invoice
    due to the own account; every collection before the death."""
    p = fr4_statement_payload()
    assert p["earlier_settled"] == [] and "withheld_given_back" not in p
    assert [d["settlement"] for d in p["documents"] if d["kind"] == "invoice"] == ["due"]
    assert all(r.encaissement_date < p["mandate_end"]["effective_date"] for r in line_records(p))
    texts = _section(p, "Retenues et compensations")
    assert not any("compensation sur le présent reversement" in x for x in texts)
    assert any("À régler au plus tard le 02/12/2026" in x for x in texts)


@pytest.mark.parametrize(
    ("fixture", "golden"),
    [
        (fr4_statement_payload, ("GOLDEN_FR4_CSV", "GOLDEN_FR4_PDF")),
        (fr4_withheld_payload, ("GOLDEN_FR4_WITHHELD_CSV", "GOLDEN_FR4_WITHHELD_PDF")),
    ],
)
def test_the_fr4_golden_hashes(fixture: object, golden: tuple[str, str]) -> None:
    p = fixture()  # type: ignore[operator]
    data = render_statement_csv(p)
    pdf = render_statement_pdf(p, _sha(data))
    assert pdf == render_statement_pdf(p, _sha(data))
    assert (_sha(data), _sha(pdf)) == (globals()[golden[0]], globals()[golden[1]])
    assert b"releve-reversement-fr-4" in pdf and b"releve-reversement-fr-3" not in pdf
    assert b"releve-reversement-fr-3" in render_statement_pdf(statement_payload(), _sha(data))
