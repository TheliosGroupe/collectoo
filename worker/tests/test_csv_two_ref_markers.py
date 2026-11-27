# ruff: noqa: E501 - CSV rows read better unwrapped
"""M2c-7f-1 H18 (plan docs/design/m2c-7f-plan.md §2.3; ADR-0014 « M2c-7e-2 review fixes » round 2, « M2c-7f-1 »;
COMPLIANCE OQ-84): a CSV label carrying two or more /REF markers gives no end-to-end id. One of them can be text the
payer typed (« /REF RMT… » of ours) before the bank's own: which is the bank's cannot be told, so none is read as the
line's end-to-end id; the label's tokens of ours are then its candidates (held label_reference, never our transfer
coming back by itself). A single /REF keeps M2b's reading. The duplicate fingerprint is the one the line had before
(computed from the first /REF value, as the parser read it then): a re-import of a file imported before 7f-1 is the
same lines, caught by their keys."""

from __future__ import annotations

import tempfile
from datetime import date
from pathlib import Path

from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.payments.csv_import import parse_csv, parse_label
from collectoo_worker.payments.statement import (
    LABEL_REFERENCE_KIND,
    DedupKeys,
    KnownIbans,
    StatementLine,
)

DEBTOR = "FR7630004000031234567890143"
IBANS = KnownIbans(own=frozenset({"FR7030001007940000000002002"}), clients=frozenset())
RMT = "RMT0123456789AB"
SWP = "SWP0123456789AC"
DAY = date(2026, 11, 26)
HEAD = "Date;Libellé;Débit;Crédit;IBAN contrepartie"


def _lines(tmp_path: Path, *rows: str) -> list[StatementLine]:
    path = tmp_path / "releve.csv"
    path.write_text("\n".join((HEAD, *rows)) + "\n", encoding="utf-8")
    return list(parse_csv(path, currency="EUR", ibans=IBANS, today=DAY).lines)


def test_the_label_counts_its_ref_markers() -> None:
    assert parse_label("VIR SEPA RECU /DE X /MOTIF M /REF A").references == 1
    assert parse_label(f"VIR SEPA RECU /DE X /REF {RMT} /REF BQ12").references == 2
    assert parse_label("VIR SEPA RECU /ref a /REF b /Ref c").references == 3
    assert parse_label("FRAIS TENUE DE COMPTE").references == 0
    # the first value is still the label's reference (the fingerprint's and the creditor reference's reading)
    assert parse_label(f"VIR SEPA RECU /DE X /REF {RMT} /REF BQ12").reference == RMT


def test_a_payers_ref_of_ours_before_the_banks_is_a_candidate_never_the_end_to_end_id(
    tmp_path: Path,
) -> None:
    (line,) = _lines(
        tmp_path,
        f"26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF REMB /REF {RMT} /REF BQ12;;100,00;{DEBTOR}",
    )
    assert (line.kind, line.end_to_end_id, line.label_references) == (
        LABEL_REFERENCE_KIND,
        None,
        (RMT,),
    )


def test_two_refs_none_ours_give_no_end_to_end_id_and_no_candidate(tmp_path: Path) -> None:
    (line,) = _lines(
        tmp_path, f"26/11/2026;VIR SEPA RECU /DE DUPONT /REF FACT-12 /REF BQ12;;100,00;{DEBTOR}"
    )
    assert (line.kind, line.end_to_end_id, line.label_references) == ("debtor_credit", None, None)


def test_a_single_ref_keeps_m2bs_reading(tmp_path: Path) -> None:
    (a, b) = _lines(
        tmp_path,
        f"26/11/2026;VIR SEPA RECU /DE DUPONT /REF {RMT};;100,00;{DEBTOR}",
        f"26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF {SWP} /REF FACT-12;;101,00;{DEBTOR}",
    )
    assert (a.kind, a.end_to_end_id, a.label_references) == ("return", RMT, None)
    assert (b.kind, b.end_to_end_id, b.label_references) == (
        LABEL_REFERENCE_KIND,
        "FACT-12",
        (SWP,),
    )


def test_a_two_ref_line_keeps_the_fingerprint_it_had_before(tmp_path: Path) -> None:
    label = f"VIR SEPA RECU /DE DUPONT /MOTIF REMB /REF {RMT} /REF BQ12"
    (line,) = _lines(tmp_path, f"26/11/2026;{label};;10,00;{DEBTOR}")
    before = DedupKeys().fingerprint(
        booking_date=DAY,
        value_date=None,
        direction="credit",
        amount_minor=1000,
        currency="EUR",
        counterparty_iban=DEBTOR,
        end_to_end_id=RMT,  # the parser's reading before 7f-1: the first /REF
        remittance_text=label,
    )
    assert line.dedup_key == before


values = st.sampled_from([RMT, SWP, "FACT-12", "BQ7", "RF18539007547034", "A B"])


@given(
    refs=st.lists(values, min_size=2, max_size=4),
    motif=st.sampled_from(["REMB", f"REMB {SWP}", "FACTURE 9"]),
)
def test_two_or_more_ref_markers_never_give_an_end_to_end_id(refs: list[str], motif: str) -> None:

    label = f"VIR SEPA RECU /DE DUPONT /MOTIF {motif} " + " ".join(f"/REF {r}" for r in refs)
    with tempfile.TemporaryDirectory() as d:
        (line,) = _lines(Path(d), f"26/11/2026;{label};;10,00;{DEBTOR}")
    assert line.end_to_end_id is None
    ours = [t for t in (*motif.split(), *refs) if t in (RMT, SWP)]
    expected = tuple(dict.fromkeys(ours)) or None
    assert line.label_references == expected
    assert line.kind == (LABEL_REFERENCE_KIND if expected else "debtor_credit")
