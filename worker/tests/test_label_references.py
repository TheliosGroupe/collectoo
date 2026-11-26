"""M2c-7e-2 (plan docs/design/m2c-7-plan.md §7.3's S24 up to the review, §7.5's worker tests;
ADR-0014 « M2c-7e-2 »), pure: our references in a CSV label.

- The CSV parser reads, on a line whose « référence de bout en bout » column is empty, absent or
  NOTPROVIDED (SEPA's « none », review round 1 MB-2), every whole token of our form (RMT, SWP or
  TOP and 12 upper-case hexadecimal digits) in the label, in its order and each once, that is not
  the line's own end-to-end id (a /REF marker's value is that id, as since M2b) into
  `StatementLine.label_references` (review round 1, MB-1: not only the first; of those that are
  transfers of the account the import keeps a booked run's payout, else the first, round 3) — never
  into the end-to-end or the original id, so
  `names_our_transfer`, `decide_line`'s return rule and the SQL never read it as our transfer.
- `refine_kind` (twin of SQL `private.bank_line_refined_kind`'s ninth argument): a credit read as a
  debtor's credit that is not ours, not a client's and not one of our transfers coming back, or a
  client's credit, becomes `label_reference` with a candidate; debits, returns, batches and our own
  account's credits are unchanged; a parser's `label_reference` reading is read again from the
  facts. Whether the candidate names one of our transfers of the account is the import's word
  (`private.ingest_statement`), tested on the database (pgTAP 047b, the integration tests).
- `decide_line`: a `label_reference` line goes to review `label_reference` whatever its other facts,
  never booked.
The Python/SQL parity on generated labels and kinds: tests/test_label_references_integration.py."""

from datetime import date
from pathlib import Path
from typing import Any

import pytest
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.jobs.payments import stage_row
from collectoo_worker.payments.csv_import import parse_csv
from collectoo_worker.payments.debits import (
    BOOKING_REVIEW_REASONS,
    LABEL_REFERENCE,
    Booking,
    FundsLine,
    TransferFact,
    decide_bookings,
    decide_line,
)
from collectoo_worker.payments.statement import (
    LABEL_REFERENCE_KIND,
    STAGE_COLUMNS,
    DedupKeys,
    KnownIbans,
    classify,
    label_reference,
    label_references,
    refine_kind,
)

OWN = "FR7030001007940000000002002"  # synthetic own account
CLIENT = "FR0930001007940000000003003"  # synthetic client payout account
DEBTOR = "FR7630004000031234567890143"
IBANS = KnownIbans(own=frozenset({OWN}), clients=frozenset({CLIENT}))
RMT = "RMT0123456789AB"
SWP = "SWP0123456789AC"
TOP = "TOP0123456789AD"
BANK = "00000000-0000-0000-0000-0000000000cf"
DAY = date(2026, 11, 26)
HEAD = "Date;Libellé;Débit;Crédit;IBAN contrepartie"
HEAD_E2E = "Date;Libellé;Débit;Crédit;IBAN contrepartie;Référence de bout en bout"


def _parse(
    tmp_path: Path, *rows: str, head: str = HEAD
) -> list[tuple[str, str | None, str | None]]:
    path = tmp_path / "releve.csv"
    path.write_text("\n".join((head, *rows)) + "\n", encoding="utf-8")
    parsed = parse_csv(path, currency="EUR", ibans=IBANS, today=DAY)
    return [
        (x.kind, x.label_references[0] if x.label_references else None, x.end_to_end_id)
        for x in parsed.lines
    ]


def _candidates(tmp_path: Path, *rows: str, head: str = HEAD) -> list[tuple[str, ...] | None]:
    path = tmp_path / "releve.csv"
    path.write_text("\n".join((head, *rows)) + "\n", encoding="utf-8")
    parsed = parse_csv(path, currency="EUR", ibans=IBANS, today=DAY)
    return [x.label_references for x in parsed.lines]


# -- the parser (CSV presets) ----------------------------------------------------------------------


def test_a_credit_citing_our_payout_in_its_label_carries_it_as_a_candidate(tmp_path: Path) -> None:
    """S24: « /MOTIF REMB RMT… » with no end-to-end column — the candidate, never the end-to-end id;
    the kind label_reference (the import keeps it only for a transfer of the account)."""
    assert _parse(
        tmp_path, f"26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF REMB {RMT};;100,00;{DEBTOR}"
    ) == [(LABEL_REFERENCE_KIND, RMT, None)]


@pytest.mark.parametrize(
    ("label", "candidate"),
    [
        (f"VIR SEPA RECU /DE X /MOTIF {SWP}", SWP),  # our sweep
        (f"VIR SEPA RECU /DE X /MOTIF {TOP}", TOP),  # our top-up, from another IBAN than ours
        (f"VIR SEPA RECU /DE X /MOTIF REMB {RMT}.", RMT),  # punctuation is a boundary
        (f"VIR SEPA RECU /DE X /MOTIF REF:{RMT}", RMT),
        (f"VIR SEPA RECU /DE X /MOTIF ({RMT})", RMT),
        (f"VIR SEPA RECU /DE X /MOTIF {RMT.lower()}", RMT),  # a bank printing it as typed
        (f"VIR SEPA RECU /DE X /MOTIF {RMT}_RETOUR", RMT),  # an underscore separates
        (f"VIR SEPA RECU /DE X /MOTIF {RMT} {SWP}", RMT),  # the first one
        (f"VIR SEPA RECU /DE X /MOTIF {RMT}C", None),  # 13 hex digits: not ours
        (f"VIR SEPA RECU /DE X /MOTIF X{RMT}", None),  # glued to a letter
        (f"VIR SEPA RECU /DE X /MOTIF 1{RMT}", None),  # glued to a digit
        (f"VIR SEPA RECU /DE X /MOTIF é{RMT}", None),  # glued to an accented letter
        ("VIR SEPA RECU /DE X /MOTIF RFD0123456789AB", None),  # our refunds keep M2b's link
        ("VIR SEPA RECU /DE X /MOTIF RMT0123456789AG", None),  # not hexadecimal
        ("VIR SEPA RECU /DE X /MOTIF FACTURE 12", None),
    ],
)
def test_a_whole_token_of_our_form_is_the_candidate(
    tmp_path: Path, label: str, candidate: str | None
) -> None:
    kind = LABEL_REFERENCE_KIND if candidate else "debtor_credit"
    assert _parse(tmp_path, f"26/11/2026;{label};;50,00;{DEBTOR}") == [(kind, candidate, None)]


def test_the_ref_marker_stays_the_end_to_end_id(tmp_path: Path) -> None:
    """A /REF marker's value is the line's end-to-end id (M2b; 6b-2's S24 is « outside /REF »): our
    RMT there keeps 6b-1's reading (a return of that transfer), no candidate; a /REF that is not
    ours beside our RMT in the motif keeps it, and the candidate is read."""
    assert _parse(
        tmp_path,
        f"26/11/2026;VIR SEPA RECU /DE MARTIN /REF {RMT};;100,00;{DEBTOR}",
        f"26/11/2026;VIR SEPA RECU /DE MARTIN /MOTIF {RMT} /REF {RMT};;101,00;{DEBTOR}",
        f"26/11/2026;VIR SEPA RECU /DE MARTIN /MOTIF REMB {RMT} /REF FACT-12;;102,00;{DEBTOR}",
        f"26/11/2026;VIR SEPA RECU /DE MARTIN /REF {RMT} EN RETOUR;;103,00;{DEBTOR}",
    ) == [
        ("return", None, RMT),
        ("return", None, RMT),
        (LABEL_REFERENCE_KIND, RMT, "FACT-12"),
        (LABEL_REFERENCE_KIND, RMT, f"{RMT} EN RETOUR"),
    ]


def test_only_when_the_end_to_end_column_is_empty_or_absent(tmp_path: Path) -> None:
    rows = (
        f"26/11/2026;VIR SEPA RECU /DE X /MOTIF {RMT};;10,00;{DEBTOR};E2E-CLIENT-1",
        f"26/11/2026;VIR SEPA RECU /DE X /MOTIF {RMT};;11,00;{DEBTOR};",
    )
    assert _parse(tmp_path, *rows, head=HEAD_E2E) == [
        ("debtor_credit", None, "E2E-CLIENT-1"),
        (LABEL_REFERENCE_KIND, RMT, None),
    ]


@pytest.mark.parametrize("cell", ["NOTPROVIDED", "notprovided", " NotProvided "])
def test_notprovided_in_the_end_to_end_column_is_no_end_to_end_id(
    tmp_path: Path, cell: str
) -> None:
    """Review round 1 (MB-2, TUI-2): SEPA's placeholder for an end-to-end id the payer did not give
    is none, as the camt.053 parser reads it — the label's candidates are read and no end-to-end id
    is stored. Review round 2 (notprovided-ref-books-return): nor does a /REF marker give one — the
    bank says the line has none, so a /REF of ours there can only be text the payer typed: it is a
    candidate like any token of the label (held), never our transfer coming back."""
    rows = (
        f"26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF REMB {RMT};;1000,00;{DEBTOR};{cell}",
        f"26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF REMB {RMT} /REF FACT-9;;10,00;{DEBTOR};{cell}",
        f"26/11/2026;VIR SEPA RECU /DE MARTIN /REF {SWP};;11,00;{DEBTOR};{cell}",
    )
    assert _parse(tmp_path, *rows, head=HEAD_E2E) == [
        (LABEL_REFERENCE_KIND, RMT, None),
        (LABEL_REFERENCE_KIND, RMT, None),
        (LABEL_REFERENCE_KIND, SWP, None),
    ]


def _lines(tmp_path: Path, *rows: str, head: str = HEAD_E2E) -> list[Any]:
    path = tmp_path / "releve.csv"
    path.write_text("\n".join((head, *rows)) + "\n", encoding="utf-8")
    return list(parse_csv(path, currency="EUR", ibans=IBANS, today=DAY).lines)


def test_a_ref_of_ours_beside_a_notprovided_cell_is_a_candidate_never_the_end_to_end_id(
    tmp_path: Path,
) -> None:
    """Review round 2 (notprovided-ref-books-return): a client repaying an advance types « /REF
    RMT… » in its motif and the bank appends its own « /REF NOTPROVIDED », the « référence de bout
    en bout » cell reading NOTPROVIDED — the line is no return of our payout (it was, read by the
    first /REF, and the debit job booked payout_returned from the label alone), nor is a /REF TOP
    our top-up's credit (own_transfer_in): each is a candidate (held for review by the import), no
    end-to-end and no original id; a bank's return keeps its kind, with no original id (as before
    7e-2: none matches); a debit is no transfer_out by it; an RF reference stays the creditor's
    reference."""
    rf = "RF18539007547034"
    rows = (
        f"26/11/2026;VIR SEPA RECU /DE MARTIN SAS /MOTIF REMBOURSEMENT AVANCE /REF {RMT} "
        "/REF NOTPROVIDED;;1000,00;;NOTPROVIDED",
        f"26/11/2026;VIR SEPA RECU /DE MARTIN SAS /MOTIF APPRO /REF {TOP};;47,00;;NOTPROVIDED",
        f"26/11/2026;RETOUR VIR SEPA /DE MARTIN SAS /REF {RMT};;999,00;;NOTPROVIDED",
        f"26/11/2026;VIR SEPA EMIS /A MARTIN SAS /REF {SWP};50,00;;;NOTPROVIDED",
        f"26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF F-12 /REF {rf};;12,00;{DEBTOR};NOTPROVIDED",
    )
    got = [
        (
            x.kind,
            x.end_to_end_id,
            x.original_end_to_end_id,
            x.label_references,
            x.creditor_reference,
        )
        for x in _lines(tmp_path, *rows)
    ]
    assert got == [
        (LABEL_REFERENCE_KIND, None, None, (RMT,), None),
        (LABEL_REFERENCE_KIND, None, None, (TOP,), None),
        ("return", None, None, (RMT,), None),
        ("other_debit", None, None, (SWP,), None),
        ("debtor_credit", None, None, None, rf),
    ]
    # with the cell empty (or no column), the /REF is the line's end-to-end id, as since M2b (the
    # risk the ADR records: a payer's /REF before the bank's own)
    assert [
        (x.kind, x.end_to_end_id)
        for x in _lines(tmp_path, f"26/11/2026;VIR SEPA RECU /DE MARTIN SAS /REF {RMT};;10,00;;")
    ] == [("return", RMT)]


def test_a_notprovided_line_keeps_the_fingerprint_it_had_before(tmp_path: Path) -> None:
    """Review round 2: the dedup fingerprint of a line whose « référence de bout en bout » reads
    NOTPROVIDED is computed from the cell, as before 7e-2 (the cell was then the line's end-to-end
    id) — an export imported before this slice and again after is the same lines, caught by their
    keys, never held as suspected duplicates; the stored end-to-end id stays none."""
    label = f"VIR SEPA RECU /DE MARTIN SAS /MOTIF REMB /REF {RMT}"
    (line,) = _lines(tmp_path, f"26/11/2026;{label};;10,00;{DEBTOR};NOTPROVIDED")
    expected = DedupKeys().fingerprint(
        booking_date=DAY,
        value_date=None,
        direction="credit",
        amount_minor=1000,
        currency="EUR",
        counterparty_iban=DEBTOR,
        end_to_end_id="NOTPROVIDED",
        remittance_text=label,
    )
    assert (line.dedup_key, line.end_to_end_id) == (expected, None)


def test_every_whole_token_of_ours_is_a_candidate_in_the_label_s_order(tmp_path: Path) -> None:
    """Review round 1 (MB-1): a look-alike, another account's or another servicer's reference
    before our real one never hides it — every token is staged, in the label's order and each once,
    the line's own end-to-end id (/REF) left out; of those that are transfers of the account the
    import keeps a booked run's payout, else the first (pgTAP 047b k4 and k5, the integration
    tests)."""
    look = "RMT0000000047BF"
    assert _candidates(
        tmp_path,
        f"26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF REMB {look} {RMT};;2000,00;{DEBTOR}",
        f"26/11/2026;VIR SEPA RECU /DE X /MOTIF REMB {SWP} {RMT} {SWP.lower()};;20,00;{DEBTOR}",
        f"26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF {TOP} {RMT} /REF {SWP};;21,00;{DEBTOR}",
        f"26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF {RMT} /REF {RMT};;22,00;{DEBTOR}",
        "26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF FACTURE 12;;23,00;" + DEBTOR,
    ) == [(look, RMT), (SWP, RMT), (TOP, RMT), None, None]
    assert _parse(
        tmp_path, f"26/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF REMB {look} {RMT};;2000,00;{DEBTOR}"
    ) == [(LABEL_REFERENCE_KIND, look, None)]


def test_ours_and_debits_keep_their_kind_with_the_candidate(tmp_path: Path) -> None:
    """From a client's payout IBAN: label_reference; from our own: own_transfer_in (unchanged); a
    debit (a coded charge naming our payout) and a return the label flags keep their kind; the
    candidate is stored for each."""
    assert _parse(
        tmp_path,
        f"26/11/2026;VIR SEPA RECU /DE MARTIN SAS /MOTIF {RMT};;20,00;{CLIENT}",
        f"26/11/2026;VIR SEPA RECU /DE COLLECTOO /MOTIF {RMT};;21,00;{OWN}",
        f"26/11/2026;FRAIS VIREMENT {RMT};12,00;;",
        f"26/11/2026;RETOUR VIR SEPA /DE X /MOTIF {RMT};;22,00;{DEBTOR}",
    ) == [
        (LABEL_REFERENCE_KIND, RMT, None),
        ("own_transfer_in", RMT, None),
        ("other_debit", RMT, None),
        ("return", RMT, None),
    ]


def test_the_stage_carries_the_candidate(tmp_path: Path) -> None:
    path = tmp_path / "releve.csv"
    path.write_text(
        f"{HEAD}\n26/11/2026;VIR SEPA RECU /MOTIF {SWP};;5,00;{DEBTOR}\n", encoding="utf-8"
    )
    line = parse_csv(path, currency="EUR", ibans=IBANS, today=DAY).lines[0]
    row = stage_row("s1", line)
    assert "label_references" in STAGE_COLUMNS
    assert "reference_from_label" not in STAGE_COLUMNS  # the import's to keep, never the stage's
    assert row[1 + STAGE_COLUMNS.index("label_references")] == [SWP]  # a text[]
    assert row[1 + STAGE_COLUMNS.index("end_to_end_id")] is None
    assert row[1 + STAGE_COLUMNS.index("original_end_to_end_id")] is None


separators = st.sampled_from([" ", ".", ",", ";", ":", "(", ")", "/", "-", "_", "'", "*"])
tokens = st.builds(
    lambda p, h: p + h,
    st.sampled_from(["RMT", "SWP", "TOP"]),
    st.from_regex(r"[0-9A-F]{12}", fullmatch=True),
)
words = st.text(st.sampled_from("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 éèàç"), max_size=30)


@given(before=words, token=tokens, after=words, left=separators, right=separators)
def test_a_token_between_separators_is_found_glued_to_a_letter_it_is_not(
    before: str, token: str, after: str, left: str, right: str
) -> None:
    """The rule (Hypothesis): a token of our form between non-alphanumeric characters (or the
    label's ends) is read, in either case; glued to a letter or a digit it is not."""
    assert (
        label_reference(f"{before}{left}{token}{right}{after}")
        == label_reference(f"{before}{left}")
        or label_reference(f"{before}{left}{token}{right}{after}") == token
    )
    assert label_reference(f"{left}{token}{right}{after}") == token
    assert label_reference(f"{left}{token.lower()}{right}") == token
    assert label_reference(f"{left}A{token}{right}") is None
    assert label_reference(f"{left}{token}0{right}") is None
    assert label_reference(f"{left}{token}{right}", end_to_end_id=token) is None


@given(
    picked=st.lists(st.tuples(tokens, st.booleans()), max_size=6),
    seps=st.lists(separators, min_size=7, max_size=7),
    e2e=st.one_of(st.none(), tokens),
)
def test_every_token_is_read_in_order_once(
    picked: list[tuple[str, bool]], seps: list[str], e2e: str | None
) -> None:
    """Review round 1 (MB-1), Hypothesis: the candidates are the label's tokens of our form, in
    its order, each once (whatever its case), the line's own end-to-end id left out; the first of
    them is `label_reference`'s."""
    label = seps[0] + "".join(
        (t.lower() if low else t) + seps[i + 1] for i, (t, low) in enumerate(picked)
    )
    want: list[str] = []
    for t, _ in picked:
        if t != e2e and t not in want:
            want.append(t)
    assert label_references(label, e2e) == tuple(want)
    assert label_reference(label, e2e) == (want[0] if want else None)


# -- the classifier (refine_kind, the twin of the SQL's ninth argument) ----------------------------


@pytest.mark.parametrize(
    ("kind", "direction", "e2e", "original", "iban", "candidate", "want"),
    [
        ("debtor_credit", "credit", None, None, None, RMT, LABEL_REFERENCE_KIND),
        ("debtor_credit", "credit", None, None, CLIENT, RMT, LABEL_REFERENCE_KIND),
        ("client_transfer_in", "credit", None, None, CLIENT, SWP, LABEL_REFERENCE_KIND),
        ("debtor_credit", "credit", None, None, OWN, RMT, "own_transfer_in"),
        ("debtor_credit", "credit", TOP, None, None, RMT, "own_transfer_in"),
        ("debtor_credit", "credit", "RMT0123456789AC", None, None, RMT, "return"),
        ("debtor_credit", "credit", None, SWP, None, TOP, "return"),
        ("return", "credit", None, None, None, RMT, "return"),
        ("batch_unsplit", "credit", None, None, None, RMT, "batch_unsplit"),
        ("other_debit", "debit", None, None, None, RMT, "other_debit"),
        ("transfer_out", "debit", RMT, None, None, SWP, "transfer_out"),
        (LABEL_REFERENCE_KIND, "credit", None, None, None, None, "debtor_credit"),
        (LABEL_REFERENCE_KIND, "credit", None, None, CLIENT, None, "client_transfer_in"),
        (LABEL_REFERENCE_KIND, "credit", None, None, None, TOP, LABEL_REFERENCE_KIND),
        ("debtor_credit", "credit", "E2E-1", None, None, SWP, LABEL_REFERENCE_KIND),
        ("debtor_credit", "credit", None, None, None, None, "debtor_credit"),
    ],
)
def test_the_ninth_argument_holds_a_debtor_s_or_a_client_s_credit(  # noqa: PLR0913, PLR0917
    kind: str,
    direction: str,
    e2e: str | None,
    original: str | None,
    iban: str | None,
    candidate: str | None,
    want: str,
) -> None:
    """The same matrix as pgTAP 047b's r."""
    got = refine_kind(
        kind,
        direction,
        e2e,
        iban,
        IBANS,
        original_end_to_end_id=original,
        reference_from_label=candidate,
    )
    assert got == want


KINDS = (
    "debtor_credit",
    "return",
    "refund_out",
    "other_debit",
    "batch_unsplit",
    "transfer_out",
    "own_transfer_in",
    "client_transfer_in",
    LABEL_REFERENCE_KIND,
)
ids = st.one_of(
    st.none(),
    st.sampled_from([RMT, SWP, TOP, "RFD0123456789AB", "E2E-1", "rmt0123456789ab"]),
    st.from_regex(r"(TOP|RMT|SWP|E2E)[0-9A-F]{11,13}", fullmatch=True),
)
candidates = st.one_of(st.none(), st.sampled_from([RMT, SWP, TOP]))
ibans = st.one_of(st.none(), st.sampled_from([OWN, CLIENT, DEBTOR]))


@given(
    kind=st.sampled_from(KINDS),
    direction=st.sampled_from(["credit", "debit"]),
    e2e=ids,
    original=ids,
    iban=ibans,
    candidate=candidates,
)
def test_a_candidate_only_ever_holds_a_credit_nothing_else_changes(  # noqa: PLR0913, PLR0917
    kind: str,
    direction: str,
    e2e: str | None,
    original: str | None,
    iban: str | None,
    candidate: str | None,
) -> None:
    def refine(k: str, c: str | None) -> str:
        return refine_kind(
            k, direction, e2e, iban, IBANS, original_end_to_end_id=original, reference_from_label=c
        )

    got = refine(kind, candidate)
    plain = refine(LABEL_REFERENCE_KIND if kind == LABEL_REFERENCE_KIND else kind, None)
    if got == LABEL_REFERENCE_KIND:
        # held only with a candidate, only a credit, only where it would be a debtor's or a client's
        assert candidate is not None
        assert direction == "credit"
        assert plain in ("debtor_credit", "client_transfer_in")
    else:
        # without a candidate (or where it does not apply) the reading is the one before 7e-2
        assert got == plain
    # read again from the facts: refining twice changes nothing
    assert refine(got, candidate) == got
    # a parser's label_reference reading is never the last word: the facts decide
    if kind == LABEL_REFERENCE_KIND:
        assert got == refine("debtor_credit", candidate)
    # a debit is never held, whatever it cites
    if direction == "debit":
        assert got != LABEL_REFERENCE_KIND
    # classify, the parsers' entry point, alike (a credit it reads as a debtor's)
    if kind == "debtor_credit" and direction == "credit":
        assert (
            classify(
                direction,
                reversal=False,
                return_reason=None,
                sub_family=None,
                end_to_end_id=e2e,
                counterparty_iban=iban,
                ibans=IBANS,
                original_end_to_end_id=original,
                reference_from_label=candidate,
            )
            == got
        )


# -- the debit job's decision ----------------------------------------------------------------------


def _held(**facts: object) -> FundsLine:
    return FundsLine(
        "L1",
        LABEL_REFERENCE_KIND,
        "credit",
        BANK,
        100_000,
        DAY,
        **facts,  # type: ignore[arg-type]
    )


def test_the_job_sends_such_a_line_to_review_and_never_books_it() -> None:
    assert LABEL_REFERENCE in BOOKING_REVIEW_REASONS
    assert decide_line(_held()) == [Booking("L1", review_reason=LABEL_REFERENCE)]
    # whatever it carries: a TOP id and an ordered top-up of its amount, our RMT as its original, a
    # return's facts — none is read before the kind
    top_up = _held(
        end_to_end_id=TOP,
        transfer_id="TOP1",
        transfer_status="ordered",
        transfer_amount_minor=100_000,
        transfer_creditor=BANK,
    )
    assert decide_line(top_up) == [Booking("L1", review_reason=LABEL_REFERENCE)]
    returned = _held(
        original_end_to_end_id=RMT,
        facts=(
            TransferFact(
                "P1",
                "return",
                "payout",
                "booked",
                100_000,
                debtor_bank_account_id=BANK,
                debit_booked=True,
            ),
        ),
    )
    assert decide_line(returned) == [Booking("L1", review_reason=LABEL_REFERENCE)]
    assert decide_bookings([returned, top_up]) == [
        Booking("L1", review_reason=LABEL_REFERENCE),
        Booking("L1", review_reason=LABEL_REFERENCE),
    ]


statuses = st.sampled_from(["ordered", "in_file", "booked", "returned", "cancelled"])
facts = st.lists(
    st.builds(
        TransferFact,
        id=st.sampled_from(["T1", "T2"]),
        role=st.sampled_from(["own", "member", "return", "top_up"]),
        kind=st.sampled_from(["payout", "sweep", "refund", "top_up"]),
        status=statuses,
        amount_minor=st.integers(1, 200_000),
        debtor_bank_account_id=st.sampled_from([BANK, "other"]),
        creditor_bank_account_id=st.sampled_from([BANK, None]),
        debit_booked=st.booleans(),
        return_booked=st.booleans(),
    ),
    max_size=3,
)


@given(
    amount=st.integers(1, 10**9),
    e2e=ids,
    original=ids,
    transfer=st.one_of(st.none(), st.just("TOP1")),
    status=st.one_of(st.none(), statuses),
    filed=st.booleans(),
    unsplit=st.one_of(st.none(), st.integers(0, 3)),
    lot=st.booleans(),
    code=st.one_of(st.none(), st.sampled_from(["PMNT/CCRD/CHRG", "PMNT/RCDT/ESCT"])),
    fs=facts,
)
def test_a_held_line_is_reviewed_whatever_its_other_facts(  # noqa: PLR0913, PLR0917
    amount: int,
    e2e: str | None,
    original: str | None,
    transfer: str | None,
    status: str | None,
    filed: bool,
    unsplit: int | None,
    lot: bool,
    code: str | None,
    fs: list[TransferFact],
) -> None:
    line = FundsLine(
        "L1",
        LABEL_REFERENCE_KIND,
        "credit",
        BANK,
        amount,
        DAY,
        bank_tx_code=code,
        transfer_id=transfer,
        transfer_status=status,
        transfer_amount_minor=amount if transfer else None,
        transfer_creditor=BANK if transfer else None,
        transfer_filed_own=filed,
        end_to_end_id=e2e,
        original_end_to_end_id=original,
        facts=tuple(fs),
        unsplit_ours=unsplit,
        names_our_lot=lot,
    )
    assert decide_line(line) == [Booking("L1", review_reason=LABEL_REFERENCE)]
