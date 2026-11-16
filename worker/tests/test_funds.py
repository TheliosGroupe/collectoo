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
        (credit(status="cancelled"), TOP_UP_DIFFERS),
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
    transfer_status=st.sampled_from([None, "ordered", "booked", "cancelled"]),
    transfer_amount_minor=st.one_of(st.none(), st.integers(1, 10**6)),
    transfer_creditor=st.sampled_from([None, "B1", "B2"]),
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
            assert b.transfer_id == line.transfer_id and line.transfer_status == "ordered"
            assert line.transfer_amount_minor == line.amount_minor
            assert line.transfer_creditor == line.bank_account_id
            assert b.transfer_id is not None and b.transfer_id not in seen  # booked once
            seen.add(b.transfer_id)
        else:
            assert b.review_reason in {
                TOP_UP_NOT_FOUND,
                TOP_UP_DIFFERS,
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
