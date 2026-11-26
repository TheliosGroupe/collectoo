"""M2c-1 (M2-12), pure: our own transfers recognised at import (`payments.statement.refine_kind`,
`classify`), camt.053 PmtInfId, and the debit job's bookings in the funds
(`payments.debits.decide_bookings`: bank charges as fees, the top-ups we ordered). Design
docs/design/m2c-remittances.md §12; the SQL twins: tests/test_funds_integration.py."""

from datetime import date
from pathlib import Path

import pytest
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.payments.camt053 import parse_camt053
from collectoo_worker.payments.csv_import import parse_csv
from collectoo_worker.payments.debits import (
    CLIENT_CREDIT,
    OWN_TRANSFER_OUT,
    TOP_UP_CANCELLED_CREDIT,
    TOP_UP_DIFFERS,
    TOP_UP_NOT_FOUND,
    Booking,
    FundsLine,
    charge_code,
    decide_booking,
    decide_bookings,
)
from collectoo_worker.payments.statement import (
    OUR_PMT_INF_RE,
    TOP_UP_ID_RE,
    TRANSFER_OUT_ID_RE,
    KnownIbans,
    classify,
    names_our_transfer,
    refine_kind,
)
from collectoo_worker.synth.camt053 import Entry, Tx, expected_lines, make_doc, render_camt053

OWN = "FR7030001007940000000002002"  # synthetic own account
CLIENT = "FR0930001007940000000003003"  # synthetic client payout account
IBANS = KnownIbans(own=frozenset({OWN}), clients=frozenset({CLIENT}))
TOP = "TOP0123456789AB"
DAY = date(2026, 11, 6)

KINDS = (
    "debtor_credit",
    "return",
    "refund_out",
    "other_debit",
    "batch_unsplit",
    "transfer_out",
    "own_transfer_in",
    "client_transfer_in",
)
e2e_ids = st.one_of(
    st.none(),
    st.sampled_from([TOP, "RMT0123456789AB", "SWP0123456789AB", "RFD0123456789AB", "TOPAZ-1"]),
    st.from_regex(r"(TOP|RMT|SWP|RFD|E2E)[0-9A-Fa-f]{10,13}", fullmatch=True),
)
ibans = st.one_of(st.none(), st.sampled_from([OWN, CLIENT, "FR7630004000031234567890143"]))


@pytest.mark.parametrize(
    ("direction", "e2e", "iban", "kind"),
    [
        ("credit", TOP, None, "own_transfer_in"),  # our TOP id
        ("credit", "E2E-1", OWN, "own_transfer_in"),  # from our own IBAN
        ("credit", "E2E-1", CLIENT, "client_transfer_in"),  # from a client's payout IBAN
        ("credit", "TOPAZ-2026-1", None, "debtor_credit"),  # a look-alike is a debtor's
        ("credit", "top0123456789ab", None, "debtor_credit"),  # our ids are upper-case hex
        ("debit", "RMT0123456789AB", None, "transfer_out"),  # our payout
        ("debit", "SWP0123456789AB", None, "transfer_out"),  # our sweep
        ("debit", None, OWN, "transfer_out"),  # to our own IBAN
        ("debit", "RFD0123456789AB", OWN, "refund_out"),  # our refund stays a refund
        ("debit", None, None, "other_debit"),
    ],
)
def test_our_own_transfers_are_recognised(
    direction: str, e2e: str | None, iban: str | None, kind: str
) -> None:
    got = classify(
        direction,
        reversal=False,
        return_reason=None,
        sub_family=None,
        end_to_end_id=e2e,
        counterparty_iban=iban,
        ibans=IBANS,
    )
    assert got == kind


def test_a_return_stays_a_return_whatever_it_carries() -> None:
    assert (
        classify(
            "credit",
            reversal=True,
            return_reason=None,
            sub_family=None,
            end_to_end_id=TOP,
            counterparty_iban=OWN,
            ibans=IBANS,
        )
        == "return"
    )


@given(st.sampled_from(KINDS), st.sampled_from(["credit", "debit"]), e2e_ids, ibans)
def test_a_credit_from_our_own_account_is_never_a_debtor_payment(
    kind: str, direction: str, e2e: str | None, iban: str | None
) -> None:
    got = refine_kind(kind, direction, e2e, iban, IBANS)
    if got == "debtor_credit" and direction == "credit":
        assert iban not in {OWN, CLIENT}
        assert not TOP_UP_ID_RE.fullmatch(e2e or "")
    # the refinement reads the facts again: refining twice changes nothing
    assert refine_kind(got, direction, e2e, iban, IBANS) == got
    # a parser's reading of our kinds is not the last word: the facts decide
    if kind in ("own_transfer_in", "client_transfer_in", "transfer_out"):
        base = "debtor_credit" if kind != "transfer_out" else "other_debit"
        assert got == refine_kind(base, direction, e2e, iban, IBANS)
    # returns and our refunds are never re-read; an unsplit batch only when it is a credit carrying
    # our payout's or sweep's id, our transfer coming back (review round 4, N1: a `return`)
    if kind in ("return", "refund_out"):
        assert got == kind
    if kind == "batch_unsplit":
        ours = direction == "credit" and TRANSFER_OUT_ID_RE.fullmatch(e2e or "") is not None
        assert got == ("return" if ours else kind)


def test_the_pmtinfid_of_a_batch_debit_is_kept(tmp_path: Path) -> None:
    entries = [
        Entry(
            70000,
            False,
            DAY,
            DAY,
            ref="NB1",
            code="PMNT/ICDT/ESCT",
            payment_info_id="PMTINF-RV-0001",
            batch_count=2,
            txs=(
                Tx(40000, ref="B1", end_to_end_id="RMT0123456789AB", name="MARTIN SAS"),
                Tx(30000, ref="B2", end_to_end_id="RMT0123456789AC", name="LILAS SAS"),
            ),
        ),
        Entry(
            5000, True, DAY, DAY, ref="NC1", txs=(Tx(5000, ref="C1", end_to_end_id=TOP, iban=OWN),)
        ),
        Entry(1200, False, DAY, DAY, ref="NF1", code="ACMT/MDOP/CHRG", info="FRAIS"),
    ]
    doc = make_doc(
        entries, iban="FR7630004000031234567890143", from_date=DAY, to_date=DAY, opening_minor=0
    )
    path = tmp_path / "s.xml"
    path.write_bytes(render_camt053(doc, "08"))
    parsed = parse_camt053(path, iban="FR7630004000031234567890143", currency="EUR", ibans=IBANS)
    got = [(x.kind, x.payment_info_id, x.amount_minor) for x in parsed.lines]
    assert got == [
        ("transfer_out", "PMTINF-RV-0001", 40000),
        ("transfer_out", "PMTINF-RV-0001", 30000),
        ("own_transfer_in", None, 5000),
        ("other_debit", None, 1200),
    ]


# --- the debit job's bookings in the funds -------------------------------------------------------


def _line(  # noqa: PLR0913 - the order a credit names, field by field
    kind: str,
    direction: str,
    *,
    bank_tx_code: str | None = None,
    transfer_id: str | None = None,
    transfer_status: str | None = None,
    transfer_amount_minor: int | None = None,
    transfer_creditor: str | None = None,
) -> FundsLine:
    return FundsLine(
        "L1",
        kind,
        direction,
        "B1",
        5000,
        DAY,
        bank_tx_code=bank_tx_code,
        transfer_id=transfer_id,
        transfer_status=transfer_status,
        transfer_amount_minor=transfer_amount_minor,
        transfer_creditor=transfer_creditor,
    )


def test_bank_charges_are_booked_as_fees() -> None:
    assert charge_code("ACMT/MDOP/CHRG") and charge_code("PMNT/MDOP/FEES")
    assert (
        not charge_code("PMNT/ICDT/ESCT")
        and not charge_code("PRTRY:CHRG")
        and not charge_code(None)
    )
    assert decide_booking(_line("other_debit", "debit", bank_tx_code="ACMT/MDOP/CHRG")) == Booking(
        "L1", "fee"
    )
    assert decide_booking(_line("other_debit", "debit", bank_tx_code="PMNT/ICDT/ESCT")) is None


def test_a_top_up_is_booked_from_its_order_only() -> None:
    def credit(
        transfer_id: str | None = "T1",
        status: str = "ordered",
        amount: int = 5000,
        creditor: str = "B1",
    ) -> FundsLine:
        return _line(
            "own_transfer_in",
            "credit",
            transfer_id=transfer_id,
            transfer_status=status,
            transfer_amount_minor=amount,
            transfer_creditor=creditor,
        )

    booked = decide_booking(credit())
    assert booked is not None and (booked.kind, booked.transfer_id) == ("top_up", "T1")
    for line, reason in [
        (credit(transfer_id=None), TOP_UP_NOT_FOUND),
        (credit(amount=4999), TOP_UP_DIFFERS),
        # M2c-7e-1 ([critic] M7-MONEY-4; R3, ADR-0014 « M2c-7e-1 »): a cancelled top-up's credit has
        # its own review (top_up_cancelled_credit: booked by ops with no transfer)
        (credit(status="cancelled"), TOP_UP_CANCELLED_CREDIT),
        (credit(status="in_file"), TOP_UP_DIFFERS),
        (credit(creditor="B2"), TOP_UP_DIFFERS),
        (_line("client_transfer_in", "credit"), CLIENT_CREDIT),
        (_line("transfer_out", "debit"), OWN_TRANSFER_OUT),
    ]:
        left = decide_booking(line)
        assert left is not None and not left.booked and left.review_reason == reason


lines = st.builds(
    FundsLine,
    id=st.uuids().map(str),
    kind=st.sampled_from(["other_debit", "transfer_out", "own_transfer_in", "client_transfer_in"]),
    direction=st.sampled_from(["credit", "debit"]),
    bank_account_id=st.sampled_from(["B1", "B2"]),
    amount_minor=st.integers(1, 10**6),
    booking_date=st.just(DAY),
    bank_tx_code=st.sampled_from([None, "ACMT/MDOP/CHRG", "PMNT/MDOP/FEES", "PMNT/ICDT/ESCT"]),
    transfer_id=st.sampled_from([None, "T1", "T2"]),
    transfer_status=st.sampled_from([None, "ordered", "in_file", "booked", "cancelled"]),
    transfer_amount_minor=st.one_of(st.none(), st.integers(1, 10**6)),
    transfer_creditor=st.sampled_from([None, "B1", "B2"]),
    transfer_filed_own=st.booleans(),
)


@given(st.lists(lines, max_size=12))
def test_bookings_book_only_what_the_bank_and_our_orders_prove(batch: list[FundsLine]) -> None:
    out = decide_bookings(batch)
    by_id = {x.id: x for x in batch}
    seen: set[str] = set()
    for b in out:
        line = by_id[b.line_id]
        if b.kind == "fee":
            assert (
                line.direction == "debit"
                and line.kind == "other_debit"
                and charge_code(line.bank_tx_code)
            )
        elif b.kind == "top_up":
            assert line.direction == "credit" and line.kind == "own_transfer_in"
            # M2c-7e-1 ([critic] M7-MONEY-4): ordered, or in_file of an own-account file
            assert b.transfer_id == line.transfer_id and (
                line.transfer_status == "ordered"
                or (line.transfer_status == "in_file" and line.transfer_filed_own)
            )
            assert line.transfer_amount_minor == line.amount_minor
            assert line.transfer_creditor == line.bank_account_id
            assert b.transfer_id is not None and b.transfer_id not in seen  # booked once
            seen.add(b.transfer_id)
        else:
            assert b.review_reason in {
                TOP_UP_NOT_FOUND,
                TOP_UP_DIFFERS,
                TOP_UP_CANCELLED_CREDIT,
                CLIENT_CREDIT,
                OWN_TRANSFER_OUT,
            }
    # nothing else is ever booked: a debtor's credit, a return, a credit as a fee
    assert all(by_id[b.line_id].kind != "client_transfer_in" or not b.booked for b in out)


# --- review M2c-6b-1 round 4 (N1): our transfers coming back are never a debtor's credit --------
#
# A credit carrying our payout's or sweep's RMT/SWP id (as its own end-to-end id or as the original
# it returns), or naming one of our files' PmtInfIds with no end-to-end id, that the parser would
# read as a debtor's credit (`debtor_credit`) or an unsplit batch (`batch_unsplit`) — a CSV export
# without the counterparty IBAN column, an unflagged label, an IBAN neither ours nor a client's — is
# read as a `return` (COMPLIANCE OQ-84's default): the import makes no payment of it; the debit job
# books it as that transfer's return when it matches, else leaves it to ops. From our own or a
# client's IBAN it stays what round 3 made it (own_transfer_in / client_transfer_in: every command
# refuses it).

RMT = "RMT0123456789AB"
SWP = "SWP0123456789AC"
LOT = "TF-2026-000001-1"
ELSEWHERE = "FR7630004000031234567890143"


@pytest.mark.parametrize(
    ("kind", "e2e", "original", "pmt_inf", "iban", "want"),
    [
        ("debtor_credit", RMT, None, None, None, "return"),  # our payout, its own id
        ("debtor_credit", SWP, None, None, None, "return"),  # our sweep
        ("debtor_credit", "E2E-1", RMT, None, None, "return"),  # our payout as the original
        ("debtor_credit", None, SWP, None, None, "return"),
        ("debtor_credit", None, None, LOT, None, "return"),  # one of our lots, no end-to-end id
        ("batch_unsplit", None, None, LOT, None, "return"),  # an unsplit batch of our lot
        ("batch_unsplit", RMT, None, None, None, "return"),
        ("debtor_credit", RMT, None, None, ELSEWHERE, "return"),  # an IBAN not ours nor a client's
        ("own_transfer_in", RMT, None, None, None, "return"),  # a parser's reading is read again
        ("debtor_credit", "E2E-1", None, LOT, None, "debtor_credit"),  # an e2e id not ours: round 3
        ("debtor_credit", "rmt0123456789ab", None, None, None, "debtor_credit"),  # upper-case only
        ("debtor_credit", "RMT0123456789ABC", None, None, None, "debtor_credit"),  # 13 digits
        ("debtor_credit", "RMT0123456789AB\n", None, None, None, "debtor_credit"),
        ("debtor_credit", None, None, "TF-2026-000001-1\n", None, "debtor_credit"),
        ("debtor_credit", None, None, "PMTINF-RV-0001", None, "debtor_credit"),  # not ours
        ("debtor_credit", None, "RFD0123456789AB", None, None, "debtor_credit"),  # (a refund: M2b)
        ("batch_unsplit", None, None, None, None, "batch_unsplit"),
        ("debtor_credit", SWP, None, None, OWN, "own_transfer_in"),  # round 3: from our own IBAN
        ("debtor_credit", RMT, None, None, CLIENT, "client_transfer_in"),  # round 3: client's IBAN
        ("debtor_credit", TOP, RMT, None, None, "own_transfer_in"),  # our TOP id first (round 3)
        ("return", RMT, RMT, None, None, "return"),
        ("other_debit", None, None, LOT, None, "other_debit"),  # a debit: our batch line, as before
    ],
)
def test_a_credit_carrying_our_transfer_s_id_is_read_as_its_return(  # noqa: PLR0913, PLR0917
    kind: str,
    e2e: str | None,
    original: str | None,
    pmt_inf: str | None,
    iban: str | None,
    want: str,
) -> None:
    direction = "debit" if kind == "other_debit" else "credit"
    got = refine_kind(
        kind, direction, e2e, iban, IBANS, original_end_to_end_id=original, payment_info_id=pmt_inf
    )
    assert got == want
    if kind in ("debtor_credit", "other_debit"):  # classify, the parsers' entry point, alike
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
                payment_info_id=pmt_inf,
            )
            == want
        )


originals = st.one_of(st.none(), st.sampled_from([RMT, SWP, "E2E-9", TOP]))
pmt_infs = st.one_of(
    st.none(), st.sampled_from([LOT, "TF-2026-000123-12", "PMTINF-1", "TF-2026-1-1"])
)


@given(
    st.sampled_from(KINDS),
    st.sampled_from(["credit", "debit"]),
    e2e_ids,
    ibans,
    originals,
    pmt_infs,
)
def test_a_debtor_s_credit_never_carries_one_of_our_transfers(  # noqa: PLR0913, PLR0917
    kind: str,
    direction: str,
    e2e: str | None,
    iban: str | None,
    original: str | None,
    pmt_inf: str | None,
) -> None:
    def refine(k: str) -> str:
        return refine_kind(
            k, direction, e2e, iban, IBANS, original_end_to_end_id=original, payment_info_id=pmt_inf
        )

    got = refine(kind)
    ours = (
        TRANSFER_OUT_ID_RE.fullmatch(e2e or "") is not None
        or TRANSFER_OUT_ID_RE.fullmatch(original or "") is not None
        or (e2e is None and OUR_PMT_INF_RE.fullmatch(pmt_inf or "") is not None)
    )
    # what the import makes a payment of (a debtor's credit, an unsplit batch) never carries our ids
    if direction == "credit" and got in ("debtor_credit", "batch_unsplit"):
        assert not ours
    # such a credit is our transfer coming back: its return, or (from our own or a client's IBAN, or
    # carrying our TOP id) round 3's own/client kinds, which every command refuses
    credit_kinds = ("debtor_credit", "batch_unsplit", "own_transfer_in", "client_transfer_in")
    if direction == "credit" and kind in credit_kinds and ours:
        assert got in ("return", "own_transfer_in", "client_transfer_in")
        if got != "return":
            assert kind != "batch_unsplit"
            assert iban in {OWN, CLIENT} or TOP_UP_ID_RE.fullmatch(e2e or "") is not None
    assert refine(got) == got  # idempotent


def test_a_csv_without_the_iban_column_reads_our_unflagged_credits_as_returns(
    tmp_path: Path,
) -> None:
    """The round-3 verifier's case (`parse_csv.out`): a CSV with the « Référence de bout en bout »
    column and no IBAN column, a label the return words miss (« /MOTIF RETOUR FONDS » is the payer's
    text): the credits carrying our RMT and SWP ids were read `debtor_credit` and the import made
    two payments of them. Now `return`, their original id their own (the funds pass books them by
    it); with an IBAN column, the one from an IBAN neither ours nor a client's too, while the
    client's one stays `client_transfer_in` (round 3)."""
    noiban = tmp_path / "noiban.csv"
    noiban.write_text(
        "Date;Libellé;Débit;Crédit;Référence de bout en bout\n"
        f"10/11/2026;VIR SEPA RECU /DE LILAS FINANCE /MOTIF RETOUR FONDS;;4198,40;{RMT}\n"
        f"10/11/2026;VIR SEPA RECU /DE COLLECTOO SAS;;120,00;{SWP}\n"
        f"10/11/2026;RETOUR VIR SEPA LILAS;;4198,40;{RMT}\n"
        "10/11/2026;VIR SEPA RECU /DE DUPONT /MOTIF FACTURE 12;;50,00;E2E-DUPONT-1\n",
        encoding="utf-8",
    )
    got = [
        (x.kind, x.end_to_end_id, x.original_end_to_end_id)
        for x in parse_csv(noiban, currency="EUR", ibans=IBANS).lines
    ]
    assert got == [
        ("return", RMT, RMT),
        ("return", SWP, SWP),
        ("return", RMT, RMT),  # flagged by its label, as before
        ("debtor_credit", "E2E-DUPONT-1", None),
    ]
    with_iban = tmp_path / "iban.csv"
    with_iban.write_text(
        "Date;Libellé;Débit;Crédit;Référence de bout en bout;IBAN contrepartie\n"
        f"10/11/2026;VIR SEPA RECU /DE LILAS FINANCE;;4198,40;{RMT};{CLIENT}\n"
        f"10/11/2026;VIR SEPA RECU /DE LILAS FINANCE NOUVEAU COMPTE;;4198,40;{RMT};{ELSEWHERE}\n",
        encoding="utf-8",
    )
    read = [
        (x.kind, x.original_end_to_end_id)
        for x in parse_csv(with_iban, currency="EUR", ibans=IBANS).lines
    ]
    assert read == [("client_transfer_in", None), ("return", RMT)]


def test_a_camt053_reads_our_unflagged_credits_as_returns(tmp_path: Path) -> None:
    """camt.053: a credit carrying our RMT id with no return code, reason or reversal; a credit
    naming one of our lots with no end-to-end id; an unsplit credit batch of our lot (its count
    disagrees with its details); an unsplit credit batch whose details carry our RMT ids: each a
    `return` (its original id its own when it has one). A debtor's credit is unchanged, and the
    synthetic ground truth agrees.

    Review round 5 (Q2): an unsplit credit batch read `return` because one of its details carries
    our RMT/SWP id keeps that identification on its line — the detail's id as the line's original
    one (the first in the file's order when several do) — so every refusal that reads
    `names_our_transfer` on the stored line sees it (before: no id at all, so « Classer sans
    comptabiliser » and « Remboursement revenu » were accepted on it). A batch our PmtInfId already
    names keeps no original (the smallest change), and a debtor's batch stays `batch_unsplit`."""
    entries = [
        Entry(5000, True, DAY, DAY, ref="NR1", txs=(Tx(5000, ref="R1", end_to_end_id=RMT),)),
        Entry(1000, True, DAY, DAY, ref="NP1", payment_info_id=LOT, txs=(Tx(1000, ref="P1"),)),
        Entry(
            9000,
            True,
            DAY,
            DAY,
            ref="NB1",
            payment_info_id=LOT,
            batch_count=3,
            txs=(Tx(3000, ref="B1"), Tx(3000, ref="B2")),
        ),
        Entry(
            8000,
            True,
            DAY,
            DAY,
            ref="NB2",
            batch_count=3,
            txs=(
                Tx(4000, ref="C1", end_to_end_id=RMT),
                Tx(4000, ref="C2", end_to_end_id="RMT0123456789AD"),
            ),
        ),
        Entry(700, True, DAY, DAY, ref="ND1", txs=(Tx(700, ref="D1", end_to_end_id="E2E-D1"),)),
        # one detail of ours among a debtor's (its count disagrees): our SWP id kept as the original
        Entry(
            6500,
            True,
            DAY,
            DAY,
            ref="NB3",
            batch_count=3,
            txs=(
                Tx(1500, ref="E1", end_to_end_id="E2E-E1"),
                Tx(5000, ref="E2", end_to_end_id=SWP),
            ),
        ),
        # our lot's PmtInfId names it already: no original added
        Entry(
            9000,
            True,
            DAY,
            DAY,
            ref="NB4",
            payment_info_id=LOT,
            batch_count=3,
            txs=(Tx(4500, ref="F1", end_to_end_id=RMT), Tx(4500, ref="F2")),
        ),
        # a debtor's unsplit batch: unchanged
        Entry(
            3000,
            True,
            DAY,
            DAY,
            ref="NB5",
            batch_count=3,
            txs=(Tx(1500, ref="G1", end_to_end_id="E2E-G1"), Tx(1500, ref="G2")),
        ),
        # a detail returning our sweep under another end-to-end id (its original, ours, is kept)
        Entry(
            4000,
            True,
            DAY,
            DAY,
            ref="NB6",
            batch_count=3,
            txs=(
                Tx(2000, ref="H1", end_to_end_id="E2E-H1", return_reason="MD06"),
                Tx(2000, ref="H2", end_to_end_id="E2E-H2"),
            ),
        ),
        # an unsplit debit batch whose details carry our ids: our debits, never a return
        Entry(
            9000,
            False,
            DAY,
            DAY,
            ref="NB7",
            code="PMNT/ICDT/ESCT",
            batch_count=3,
            txs=(
                Tx(4500, ref="K1", end_to_end_id=RMT),
                Tx(4500, ref="K2", end_to_end_id="RMT0123456789AD"),
            ),
        ),
    ]
    doc = make_doc(entries, iban=ELSEWHERE, from_date=DAY, to_date=DAY, opening_minor=0)
    path = tmp_path / "s.xml"
    xml = render_camt053(doc, "08")
    reason = b"<RtrInf><Rsn><Cd>MD06</Cd></Rsn></RtrInf>"
    assert xml.count(reason) == 1
    path.write_bytes(
        xml.replace(reason, b"<RtrInf><OrgnlEndToEndId>" + SWP.encode() + b"</OrgnlEndToEndId>"
                    b"<Rsn><Cd>MD06</Cd></Rsn></RtrInf>")
    )  # fmt: skip
    parsed = parse_camt053(path, iban=ELSEWHERE, currency="EUR", ibans=IBANS)
    got = [(x.kind, x.end_to_end_id, x.original_end_to_end_id) for x in parsed.lines]
    assert got == [
        ("return", RMT, RMT),
        ("return", None, None),
        ("return", None, None),
        ("return", None, RMT),  # the first of our ids in the file's order
        ("debtor_credit", "E2E-D1", None),
        ("return", None, SWP),
        ("return", None, None),
        ("batch_unsplit", None, None),
        ("return", None, SWP),  # the detail's original, not its own end-to-end id
        ("batch_unsplit", None, None),
    ]
    assert [x.kind for x in expected_lines(doc)] == [k for k, _, _ in got]
    # every line read `return` because it is ours carries what the refusals read
    for x in parsed.lines:
        if x.kind == "return":
            assert names_our_transfer(x.end_to_end_id, x.original_end_to_end_id, x.payment_info_id)


def test_a_camt053_entry_kept_unsplit_records_how_many_of_its_details_are_ours(
    tmp_path: Path,
) -> None:
    """Review round 6 (R1): a line read from a camt.053 entry kept unsplit (its details cannot be
    split: a count that disagrees, details that do not add up, a detail of the other direction)
    carries the entry's total, not one transaction's, so the parser records on it how many of its
    details name one of our transfers (`unsplit_ours`: their own or original end-to-end id is our
    RMT/SWP id); a line of its own, a detail of a split batch and a CSV line record nothing (None).
    The funds pass books such a line as our transfer's return only when exactly one detail is ours
    and its amount is that transfer's (payments.debits).

    The brief's wording for the original id: set when exactly one detail is ours; when several
    are, the first (the only field the refusals read), and the count says the line is never
    booked whatever its amount. The round-5 verifier's netted entry (our payout's return and
    another payout's debit in one credit entry) counts both."""
    other = "RMT0123456789AD"
    entries = [
        Entry(5000, True, DAY, DAY, ref="NR1", txs=(Tx(5000, ref="R1", end_to_end_id=RMT),)),
        # split batch: each detail its own line
        Entry(
            7000,
            True,
            DAY,
            DAY,
            ref="NS1",
            txs=(Tx(5000, ref="S1", end_to_end_id=RMT), Tx(2000, ref="S2", end_to_end_id="E2E-S")),
        ),
        # count disagrees: one of ours beside a debtor's
        Entry(
            6500,
            True,
            DAY,
            DAY,
            ref="NB1",
            batch_count=3,
            txs=(Tx(1500, ref="B1", end_to_end_id="E2E-B"), Tx(5000, ref="B2", end_to_end_id=SWP)),
        ),
        # two of ours
        Entry(
            8000,
            True,
            DAY,
            DAY,
            ref="NB2",
            batch_count=3,
            txs=(Tx(4000, ref="C1", end_to_end_id=RMT), Tx(4000, ref="C2", end_to_end_id=other)),
        ),
        # netted (the second detail turned DBIT below): our return and another payout's debit
        Entry(
            3000,
            True,
            DAY,
            DAY,
            ref="NB3",
            txs=(Tx(5000, ref="N1", end_to_end_id=RMT), Tx(2000, ref="N2", end_to_end_id=other)),
        ),
        # netted with a debit not ours (a chargeback)
        Entry(
            3000,
            True,
            DAY,
            DAY,
            ref="NB4",
            txs=(Tx(5000, ref="F1", end_to_end_id=RMT), Tx(2000, ref="F2", end_to_end_id="E2E-CB")),
        ),
        # a debtor's batch, and a batch with no detail at all
        Entry(
            3000,
            True,
            DAY,
            DAY,
            ref="NB5",
            batch_count=3,
            txs=(Tx(1500, ref="G1", end_to_end_id="E2E-G1"), Tx(1500, ref="G2")),
        ),
        Entry(4000, True, DAY, DAY, ref="NB6", batch_count=2),
        # one detail shown of two (count disagrees): ours, the entry's total
        Entry(
            5000,
            True,
            DAY,
            DAY,
            ref="NB7",
            batch_count=2,
            txs=(Tx(5000, ref="H1", end_to_end_id=RMT),),
        ),
        # the same transfer of ours named by two details: two details of ours
        Entry(
            10000,
            True,
            DAY,
            DAY,
            ref="NB9",
            batch_count=3,
            txs=(Tx(5000, ref="J1", end_to_end_id=RMT), Tx(5000, ref="J2", end_to_end_id=RMT)),
        ),
        # an unsplit debit batch of our payouts
        Entry(
            9000,
            False,
            DAY,
            DAY,
            ref="NB8",
            code="PMNT/ICDT/ESCT",
            batch_count=3,
            txs=(Tx(4500, ref="K1", end_to_end_id=RMT), Tx(4500, ref="K2", end_to_end_id=other)),
        ),
    ]
    doc = make_doc(entries, iban=ELSEWHERE, from_date=DAY, to_date=DAY, opening_minor=0)
    xml = render_camt053(doc, "08")
    for ref in (b"N2", b"F2"):  # the netted entries' second detail is a debit
        at = xml.index(b"<AcctSvcrRef>" + ref + b"</AcctSvcrRef>")
        ind = xml.index(b"<CdtDbtInd>CRDT</CdtDbtInd>", at)
        xml = xml[:ind] + b"<CdtDbtInd>DBIT</CdtDbtInd>" + xml[ind + 27 :]
    path = tmp_path / "s.xml"
    path.write_bytes(xml)
    parsed = parse_camt053(path, iban=ELSEWHERE, currency="EUR", ibans=IBANS)
    got = [
        (x.kind, x.amount_minor, x.end_to_end_id, x.original_end_to_end_id, x.unsplit_ours)
        for x in parsed.lines
    ]
    assert got == [
        ("return", 5000, RMT, RMT, None),  # a line of its own
        ("return", 5000, RMT, RMT, None),  # split: its own amount
        ("debtor_credit", 2000, "E2E-S", None, None),
        ("return", 6500, None, SWP, 1),  # exactly one of ours: its id
        ("return", 8000, None, RMT, 2),  # several: the first, never booked
        ("return", 3000, None, RMT, 2),  # netted with our other payout's debit
        ("return", 3000, None, RMT, 1),  # netted with a chargeback
        ("batch_unsplit", 3000, None, None, 0),
        ("batch_unsplit", 4000, None, None, 0),
        ("return", 5000, RMT, RMT, 1),
        ("return", 10000, None, RMT, 2),  # one id, two details
        ("batch_unsplit", 9000, None, None, 2),
    ]
    # a CSV line is always one transaction: nothing recorded
    csv = tmp_path / "s.csv"
    csv.write_text(
        "Date;Libellé;Débit;Crédit;Référence de bout en bout\n"
        f"10/11/2026;VIR SEPA RECU;;50,00;{RMT}\n",
        encoding="utf-8",
    )
    rows = parse_csv(csv, currency="EUR", ibans=IBANS).lines
    assert [x.unsplit_ours for x in rows] == [None]


def _flip(xml: bytes, refs: tuple[bytes, ...]) -> bytes:
    """Each named detail's CdtDbtInd turned to the other direction (a netted entry)."""
    for ref in refs:
        at = xml.index(b"<AcctSvcrRef>" + ref + b"</AcctSvcrRef>")
        end = xml.index(b"</TxDtls>", at)
        span = xml[at:end]
        flipped = (
            span.replace(b"<CdtDbtInd>CRDT</CdtDbtInd>", b"<CdtDbtInd>XXXX</CdtDbtInd>")
            .replace(b"<CdtDbtInd>DBIT</CdtDbtInd>", b"<CdtDbtInd>CRDT</CdtDbtInd>")
            .replace(b"<CdtDbtInd>XXXX</CdtDbtInd>", b"<CdtDbtInd>DBIT</CdtDbtInd>")
        )
        assert flipped != span
        xml = xml[:at] + flipped + xml[end:]
    return xml


def test_a_camt053_detail_of_ours_is_a_line_of_its_own_only_when_it_is_the_whole_entry(
    tmp_path: Path,
) -> None:
    """Review round 7 (S1, verdict new:unsplit-exact-total-other-details): a camt.053 entry holding
    exactly one detail is an ordinary line (its own amount the entry's) only when that detail is
    the whole entry — NbOfTxs absent or 1, the entry's direction, its own Amt absent or the
    entry's. A detail of ours that is not (its Amt differs from the entry's, it is of the other
    direction) now keeps its entry unsplit, so the funds pass never books it as our transfer's
    return; the verifier's u01 (one detail shown of two: NbOfTxs 2) was unsplit already. And a
    detail of the other direction is never read as what the line returns (x01, x03: our payout's
    DBIT detail in a credit entry beside a debtor's credit: no original id, still counted), nor
    gives the line its own end-to-end id. A debtor's single detail keeps the booked amount (the
    bank's charges), as before. The synthetic ground truth agrees where it can say it."""
    other = "RMT0123456789AD"
    rfd = "RFD0123456789AB"
    entries = [
        # 1-2: the whole entry: no count, or a count of 1 — a line of its own
        Entry(5000, True, DAY, DAY, ref="NS1", txs=(Tx(5000, ref="S1", end_to_end_id=RMT),)),
        Entry(
            5000,
            True,
            DAY,
            DAY,
            ref="NS2",
            batch_count=1,
            txs=(Tx(5000, ref="S2", end_to_end_id=RMT),),
        ),
        # 3: u01, one detail shown of two
        Entry(
            5000,
            True,
            DAY,
            DAY,
            ref="NS3",
            batch_count=2,
            txs=(Tx(5000, ref="S3", end_to_end_id=RMT),),
        ),
        # 4: u03 with no count: its own amount 50,00 below the entry's
        Entry(10000, True, DAY, DAY, ref="NS4", txs=(Tx(5000, ref="S4", end_to_end_id=RMT),)),
        # 5: our payout's debit detail alone in a credit entry (turned DBIT below)
        Entry(5000, True, DAY, DAY, ref="NS5", txs=(Tx(5000, ref="S5", end_to_end_id=RMT),)),
        # 6-7: x01, x03 — a debtor's credit of 100,00 and our payout's debit of 50,00 (turned DBIT)
        Entry(
            5000,
            True,
            DAY,
            DAY,
            ref="NX1",
            txs=(
                Tx(10000, ref="X1", end_to_end_id="E2E-X1"),
                Tx(5000, ref="X2", end_to_end_id=RMT),
            ),
        ),
        Entry(
            5000,
            True,
            DAY,
            DAY,
            ref="NX3",
            txs=(
                Tx(5000, ref="X3", end_to_end_id=RMT),
                Tx(10000, ref="X4", end_to_end_id="E2E-X4"),
            ),
        ),
        # 8: m04 — our return, a debtor's credit and our refund's debit (turned DBIT) netting to 0
        Entry(
            5000,
            True,
            DAY,
            DAY,
            ref="NM4",
            txs=(
                Tx(5000, ref="M1", end_to_end_id=RMT),
                Tx(1000, ref="M2", end_to_end_id="E2E-M2"),
                Tx(1000, ref="M3", end_to_end_id=rfd),
            ),
        ),
        # 9: a debtor's single detail below the entry: the booked amount, a line of its own
        Entry(7300, True, DAY, DAY, ref="ND1", txs=(Tx(7000, ref="D1", end_to_end_id="E2E-D1"),)),
        # 10: our payout's return detail alone in a debit entry (turned CRDT below)
        Entry(
            5000,
            False,
            DAY,
            DAY,
            ref="NR1",
            code="PMNT/ICDT/ESCT",
            txs=(Tx(5000, ref="R1", end_to_end_id=other),),
        ),
        # 11: d01 — an outgoing debit with our payout's return netted in (turned CRDT)
        Entry(
            5000,
            False,
            DAY,
            DAY,
            ref="NR2",
            code="PMNT/ICDT/ESCT",
            txs=(
                Tx(10000, ref="R2", end_to_end_id="E2E-OUT"),
                Tx(5000, ref="R3", end_to_end_id=RMT),
            ),
        ),
    ]
    doc = make_doc(entries, iban=ELSEWHERE, from_date=DAY, to_date=DAY, opening_minor=100000)
    xml = _flip(render_camt053(doc, "08"), (b"S5", b"X2", b"X3", b"M3", b"R1", b"R3"))
    path = tmp_path / "s.xml"
    path.write_bytes(xml)
    parsed = parse_camt053(path, iban=ELSEWHERE, currency="EUR", ibans=IBANS)
    got = [
        (x.kind, x.amount_minor, x.end_to_end_id, x.original_end_to_end_id, x.unsplit_ours)
        for x in parsed.lines
    ]
    assert got == [
        ("return", 5000, RMT, RMT, None),  # the whole entry: its line
        ("return", 5000, RMT, RMT, None),
        ("return", 5000, RMT, RMT, 1),  # u01: unsplit (never booked)
        ("return", 10000, RMT, RMT, 1),  # its own amount is not the entry's: unsplit
        ("return", 5000, None, None, 1),  # the other direction: counted, never its id
        ("return", 5000, None, None, 1),  # x01
        ("return", 5000, None, None, 1),  # x03
        # m04: our return's id; round 8 (T2): our refund's debit counted too — two details of ours
        ("return", 5000, None, RMT, 2),
        ("debtor_credit", 7300, "E2E-D1", None, None),  # a debtor's: unchanged
        ("batch_unsplit", 5000, None, None, 1),  # a debit entry: never our payout's debit by it
        ("batch_unsplit", 5000, None, None, 1),  # d01
    ]
    # the ground truth says the same where no detail is turned (entries 1-4 and 9): the kind, and
    # whether the line is its entry's (e:) or its detail's own (t:)
    truth = [(x.kind, x.key_prefix) for x in expected_lines(doc)]
    read = [(x.kind, x.dedup_key[0]) for x in parsed.lines]
    assert [truth[i] for i in (0, 1, 2, 3, 8)] == [read[i] for i in (0, 1, 2, 3, 8)]
    assert read[3] == ("return", "e")
    for x in parsed.lines:
        if x.unsplit_ours is not None:
            assert x.batch_entry_ref is not None


def _original(xml: bytes, ref: bytes, original: str) -> bytes:
    """The named detail gains the original end-to-end id it returns (RtrInf/OrgnlEndToEndId)."""
    at = xml.index(b"<AcctSvcrRef>" + ref + b"</AcctSvcrRef>")
    end = xml.index(b"</TxDtls>", at)
    span = xml[at:end]
    tag = b"<OrgnlEndToEndId>" + original.encode() + b"</OrgnlEndToEndId>"
    if b"<RtrInf>" in span:
        span = span.replace(b"<RtrInf>", b"<RtrInf>" + tag, 1)
    else:
        span += b"<RtrInf>" + tag + b"</RtrInf>"
    return xml[:at] + span + xml[end:]


def test_our_refunds_and_top_ups_in_a_camt053_entry_count_as_ours(tmp_path: Path) -> None:
    """Review round 8 (T2, verdict new:unsplit-entry-our-refund-or-top-uncounted): our refunds'
    RFD ids and our top-ups' TOP ids (ids we issue, as our payouts' RMT and our sweeps' SWP) are
    counted in a camt.053 entry the way round 7 counts RMT/SWP: a detail of ours is a line of its
    own only when it is the whole entry, a line kept unsplit counts every detail of ours
    (`unsplit_ours`) and takes its original id only from one of the entry's direction, and a credit
    holding ours is a return (no payment). Before, the verifier's r5 (our refund's return shown
    alone of two: the M2b pass linked it `refund_returned`), r1q, r2q and r4 (our refund's debit
    shown alone of two, beside a debit with no amounts, netted with a credit: `batch_unsplit`
    counting 0, explainable) and t1 (our top-up shown alone of two: `batch_unsplit`, one debtor's
    payment) were outside both. Our refund and our top-up as the whole of their entry keep their
    line of its own, as before; the ground truth agrees where it can say it."""
    rfd = "RFD0123456789AB"
    rtrn = "PMNT/RCDT/RRTN"
    out = "PMNT/ICDT/ESCT"
    entries = [
        # 1: r5 — our refund's return (AC04, its RFD id as its own) shown alone of two
        Entry(1000, True, DAY, DAY, ref="NR5", code=rtrn, batch_count=2,
              txs=(Tx(1000, ref="R5", end_to_end_id=rfd, return_reason="AC04"),)),
        # 2: r5 with the RFD id as the original it returns (inserted below)
        Entry(1000, True, DAY, DAY, ref="NR6", code=rtrn, batch_count=2,
              txs=(Tx(1000, ref="R6", end_to_end_id="E2E-R6", return_reason="AC04"),)),
        # 3: r1q — our refund's debit shown alone of two
        Entry(1000, False, DAY, DAY, ref="NQ1", code=out, batch_count=2,
              txs=(Tx(1000, ref="Q1", end_to_end_id=rfd),)),
        # 4: r2q — our refund's debit beside a foreign debit, no amounts
        Entry(1500, False, DAY, DAY, ref="NQ2", code=out,
              txs=(Tx(None, ref="Q2", end_to_end_id=rfd),
                   Tx(None, ref="Q3", end_to_end_id="E2E-F"))),
        # 5: r4 — our refund's debit of 10,00 netted with a credit of 3,00 (turned CRDT below)
        Entry(700, False, DAY, DAY, ref="NQ4", code=out,
              txs=(Tx(1000, ref="Q4", end_to_end_id=rfd),
                   Tx(300, ref="Q5", end_to_end_id="E2E-C"))),
        # 6: r3 — our refund's debit alone, its own amount not the entry's
        Entry(1500, False, DAY, DAY, ref="NQ6", code=out,
              txs=(Tx(1000, ref="Q6", end_to_end_id=rfd),)),
        # 7: t1 — our top-up from the own account shown alone of two
        Entry(3000, True, DAY, DAY, ref="NT1", batch_count=2,
              txs=(Tx(3000, ref="T1", end_to_end_id=TOP, iban=OWN),)),
        # 8: our top-up beside a debtor's credit, no amounts (R3's camt.053 shape)
        Entry(8000, True, DAY, DAY, ref="NT2",
              txs=(Tx(None, ref="T2", end_to_end_id="E2E-T2"),
                   Tx(None, ref="T3", end_to_end_id=TOP))),
        # 9-11: our refund's debit, its return and our top-up as the whole of their entry: lines of
        # their own, as before
        Entry(1000, False, DAY, DAY, ref="NW1", code=out,
              txs=(Tx(1000, ref="W1", end_to_end_id=rfd),)),
        Entry(1000, True, DAY, DAY, ref="NW2", code=rtrn,
              txs=(Tx(1000, ref="W2", end_to_end_id=rfd, return_reason="AC04"),)),
        Entry(3000, True, DAY, DAY, ref="NW3",
              txs=(Tx(3000, ref="W3", end_to_end_id=TOP, iban=OWN),)),
        # 12: a debtor's unsplit batch, none of ours: one payment, as before
        Entry(4000, True, DAY, DAY, ref="NB1", batch_count=3,
              txs=(Tx(2000, ref="B1", end_to_end_id="E2E-B1"),
                   Tx(2000, ref="B2", end_to_end_id="E2E-B2"))),
        # 13: our top-up, then our payout's return, no amounts: both counted, the RMT id kept as the
        # original (the one names_our_transfer reads), whatever the file's order
        Entry(9000, True, DAY, DAY, ref="NM1",
              txs=(Tx(None, ref="M1", end_to_end_id=TOP), Tx(None, ref="M2", end_to_end_id=RMT))),
    ]  # fmt: skip
    doc = make_doc(entries, iban=ELSEWHERE, from_date=DAY, to_date=DAY, opening_minor=100000)
    xml = _original(_flip(render_camt053(doc, "08"), (b"Q5",)), b"R6", rfd)
    path = tmp_path / "s.xml"
    path.write_bytes(xml)
    parsed = parse_camt053(path, iban=ELSEWHERE, currency="EUR", ibans=IBANS)
    got = [
        (x.kind, x.amount_minor, x.end_to_end_id, x.original_end_to_end_id, x.unsplit_ours)
        for x in parsed.lines
    ]
    assert got == [
        ("return", 1000, rfd, rfd, 1),  # r5: reviewed, never linked by the M2b pass
        ("return", 1000, "E2E-R6", rfd, 1),
        ("batch_unsplit", 1000, rfd, None, 1),  # r1q: never explained
        ("batch_unsplit", 1500, None, None, 1),  # r2q
        ("batch_unsplit", 700, None, None, 1),  # r4
        ("batch_unsplit", 1500, rfd, None, 1),  # r3: its own amount is not the entry's
        ("return", 3000, TOP, TOP, 1),  # t1: no payment, never the top-up
        ("return", 8000, None, TOP, 1),  # our top-up beside a debtor's: no payment
        ("refund_out", 1000, rfd, None, None),  # the whole entry: its line
        ("return", 1000, rfd, rfd, None),
        ("own_transfer_in", 3000, TOP, None, None),
        ("batch_unsplit", 4000, None, None, 0),  # none of ours: one payment
        ("return", 9000, None, RMT, 2),
    ]
    # the ground truth says the same where nothing is turned nor inserted: the kind, and whether the
    # line is its entry's (e:) or its detail's own (t:)
    truth = [(x.kind, x.key_prefix) for x in expected_lines(doc)]
    read = [(x.kind, x.dedup_key[0]) for x in parsed.lines]
    same = (0, 2, 3, 5, 6, 7, 8, 9, 10, 11)
    assert [truth[i] for i in same] == [read[i] for i in same]
    assert [read[i] for i in (5, 8)] == [("batch_unsplit", "e"), ("refund_out", "t")]


@pytest.mark.parametrize(
    ("e2e", "issued"),
    [
        ("RMT0123456789AB", True),  # a payout
        ("SWP0123456789AB", True),  # a sweep
        ("RFD0123456789AB", True),  # a refund
        ("TOP0123456789AB", True),  # a top-up
        ("RFD0123456789A", False),  # 11 digits: not one of ours
        ("rfd0123456789ab", False),  # our ids are upper-case hex
        ("RFDX-V5-0001", False),
        ("TOPAZ-2026-1", False),
        ("E2E-1", False),
        (None, False),
    ],
)
def test_the_ids_we_issue_are_ours_to_every_reader_of_an_id_s_prefix(
    tmp_path: Path, e2e: str | None, issued: bool
) -> None:
    """Review round 8 (T2): every place that decides « ours » from an id's prefix agrees. The ids
    we issue (the SQL generators': RMT, SWP, RFD or TOP and 12 upper-case hex digits) are each
    counted by a camt.053 entry kept unsplit (`unsplit_ours`; its credit then a return). Of them,
    only our payouts' and sweeps' are `names_our_transfer` (with our lots: lines only ever booked,
    never linked); our refund's debit stays `refund_out` (the M2b pass links it) and a credit
    carrying our TOP id `own_transfer_in` (the funds pass books it as the top-up), as before."""
    entry = Entry(5000, True, DAY, DAY, ref="NI1", batch_count=2,
                  txs=(Tx(5000, ref="I1", end_to_end_id=e2e),))  # fmt: skip
    doc = make_doc([entry], iban=ELSEWHERE, from_date=DAY, to_date=DAY, opening_minor=100000)
    path = tmp_path / "s.xml"
    path.write_bytes(render_camt053(doc, "08"))
    (line,) = parse_camt053(path, iban=ELSEWHERE, currency="EUR", ibans=IBANS).lines
    assert (line.unsplit_ours, line.kind) == ((1, "return") if issued else (0, "batch_unsplit"))
    prefix = (e2e or "")[:3]
    assert names_our_transfer(e2e, None, None) is (issued and prefix in ("RMT", "SWP"))
    if issued and prefix == "RFD":
        assert classify("debit", reversal=False, return_reason=None, sub_family=None,
                        end_to_end_id=e2e) == "refund_out"  # fmt: skip
    if issued and prefix == "TOP":
        assert refine_kind("debtor_credit", "credit", e2e, None, IBANS) == "own_transfer_in"
