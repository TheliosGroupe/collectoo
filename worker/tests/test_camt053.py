"""camt.053 reader (M2-07, design §8.3 and §13): synthetic statements of every version French banks
send are read line for line as the generator wrote them (batch bookings, returns, RF references,
free text, twins); hand-written files pin the edge cases; unsafe or inexact files are refused with
a stable code and nothing is returned."""

from dataclasses import replace
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from collectoo_worker.payments.camt053 import MAX_LINES, parse_camt053
from collectoo_worker.payments.statement import ParsedStatement, StatementRejected
from collectoo_worker.synth.camt053 import (
    Doc,
    Entry,
    Expected,
    Stmt,
    Tx,
    expected_lines,
    generate_entries,
    make_doc,
    render_camt053,
)

IBAN = "FR7630004000031234567890143"  # synthetic, valid check digits
START = date(2026, 10, 1)
NS2 = "urn:iso:std:iso:20022:tech:xsd:camt.053.001.02"


def _parse(tmp_path: Path, data: bytes, today: date | None = None) -> ParsedStatement:
    path = tmp_path / "statement.xml"
    path.write_bytes(data)
    return parse_camt053(path, iban=IBAN, currency="EUR", today=today)


def _refused(tmp_path: Path, data: bytes, today: date | None = None) -> str:
    with pytest.raises(StatementRejected) as err:
        _parse(tmp_path, data, today)
    return err.value.code


def _doc(*entries: Entry, opening: int = 0) -> Doc:
    return make_doc(entries, iban=IBAN, from_date=START, to_date=START, opening_minor=opening)


def _assert_lines(parsed: ParsedStatement, expected: list[Expected]) -> None:
    assert len(parsed.lines) == len(expected)
    for got, want in zip(parsed.lines, expected, strict=True):
        assert (
            got.section_no,
            got.direction,
            got.amount_minor,
            got.booking_date,
            got.value_date,
        ) == (
            want.section_no,
            want.direction,
            want.amount_minor,
            want.booking_date,
            want.value_date,
        )
        assert (got.kind, got.dedup_key[0], got.end_to_end_id, got.creditor_reference) == (
            want.kind,
            want.key_prefix,
            want.end_to_end_id,
            want.creditor_reference,
        )
        assert (got.counterparty_name, got.counterparty_iban, got.remittance_text) == (
            want.counterparty_name,
            want.counterparty_iban,
            want.remittance_text,
        )
        assert got.return_reason == want.return_reason


@pytest.mark.parametrize("version", ["02", "04", "06", "08"])
def test_a_synthetic_statement_is_read_line_for_line(tmp_path: Path, version: str) -> None:
    entries = generate_entries(600, seed=3, start=START, days=4)
    doc = make_doc(entries, iban=IBAN, from_date=START, to_date=START + timedelta(days=3))
    parsed = _parse(tmp_path, render_camt053(doc, version), today=date(2026, 11, 8))
    expected = expected_lines(doc)
    _assert_lines(parsed, expected)
    assert parsed.version == version
    assert parsed.skipped_not_booked == sum(
        1 for e in doc.statements[0].entries if e.status != "BOOK"
    )
    section = parsed.sections[0]
    assert (section.opening_minor, section.closing_minor) == (0, doc.statements[0].closing_minor)
    assert (section.from_date, section.to_date, section.stmt_id, section.seq) == (
        START,
        START + timedelta(days=3),
        "STMT-1",
        1,
    )
    kinds = {x.kind for x in expected}
    assert {"debtor_credit", "batch_unsplit", "return", "other_debit", "refund_out"} <= kinds
    assert len({line.dedup_key for line in parsed.lines}) == len(parsed.lines)


@settings(
    max_examples=25, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture]
)
@given(
    seed=st.integers(min_value=0, max_value=10**6),
    lines=st.integers(min_value=1, max_value=60),
    version=st.sampled_from(["02", "08"]),
    opening=st.integers(min_value=-(10**9), max_value=10**9),
)
def test_round_trip_generate_render_parse_keeps_every_amount(
    tmp_path: Path, seed: int, lines: int, version: str, opening: int
) -> None:
    """Property (design §13): generate → render → parse gives the same amounts, in minor units,
    line by line, and the bank's proof holds."""
    entries = generate_entries(lines, seed=seed, start=START, days=3, payers=20)
    doc = make_doc(
        entries,
        iban=IBAN,
        from_date=START,
        to_date=START + timedelta(days=2),
        opening_minor=opening,
    )
    parsed = _parse(tmp_path, render_camt053(doc, version))
    expected = expected_lines(doc)
    assert [(x.direction, x.amount_minor) for x in parsed.lines] == [
        (x.direction, x.amount_minor) for x in expected
    ]
    moved = sum(x.signed_minor for x in parsed.lines)
    assert parsed.sections[0].opening_minor + moved == parsed.sections[0].closing_minor


def test_batch_bookings(tmp_path: Path) -> None:
    txs = (
        Tx(1000, ref="T1", name="A", ustrd=("F-1",)),
        Tx(2500, ref="T2", name="B", ustrd=("F-2",)),
    )
    split = Entry(3500, True, START, ref="N1", txs=txs, batch_count=2)
    mismatch = Entry(
        3600,
        True,
        START,
        ref="N2",
        txs=(replace(txs[0], ref="T3"), replace(txs[1], ref="T4")),
        batch_count=2,
    )
    no_details = Entry(9000, True, START, ref="N3", batch_count=3, info="LOT 3 VIREMENTS")
    miscounted = Entry(
        3500,
        True,
        START,
        ref="N4",
        txs=(replace(txs[0], ref="T5"), replace(txs[1], ref="T6")),
        batch_count=3,
    )
    parsed = _parse(tmp_path, render_camt053(_doc(split, mismatch, no_details, miscounted), "08"))
    got = [(x.kind, x.amount_minor, x.dedup_key, x.batch_entry_ref) for x in parsed.lines]
    assert got == [
        ("debtor_credit", 1000, "t:T1", "N1"),
        ("debtor_credit", 2500, "t:T2", "N1"),
        (
            "batch_unsplit",
            3600,
            "e:N2#1",
            "N2",
        ),  # details do not add up: one line, the booked amount
        ("batch_unsplit", 9000, "e:N3#1", "N3"),  # no details
        ("batch_unsplit", 3500, "e:N4#1", "N4"),  # 3 announced, 2 detailed
    ]
    assert parsed.lines[3].remittance_text == "LOT 3 VIREMENTS"


def test_returns_and_reversals(tmp_path: Path) -> None:
    entries = [
        Entry(
            4200,
            False,
            START,
            reversal=True,
            ref=f"R{i}",
            code="PMNT/RDDT/UPDD",
            txs=(
                Tx(
                    4200,
                    ref=f"RT{i}",
                    end_to_end_id=f"E2E-{i}",
                    name="DUPONT",
                    iban=IBAN,
                    return_reason=reason,
                    ustrd=(f"RETOUR {reason}",),
                ),
            ),
        )
        for i, reason in enumerate(("AC04", "MD06", "MS03"))
    ]
    entries.append(Entry(150, True, START, reversal=True, ref="RV", code="PMNT/MDOP/FEES"))
    parsed = _parse(tmp_path, render_camt053(_doc(*entries), "02"))
    returns = parsed.lines[:3]
    assert [(x.kind, x.direction, x.return_reason) for x in returns] == [
        ("return", "debit", "AC04"),
        ("return", "debit", "MD06"),
        ("return", "debit", "MS03"),
    ]
    assert [x.original_end_to_end_id for x in returns] == ["E2E-0", "E2E-1", "E2E-2"]
    assert all(x.reversal_indicator for x in parsed.lines)
    assert returns[0].counterparty_name == "DUPONT" and returns[0].method == "sdd"
    # a credit that takes back a debit (a fee refunded) is not a debtor's payment
    assert (parsed.lines[3].kind, parsed.lines[3].direction) == ("return", "credit")


def test_references_texts_and_parties(tmp_path: Path) -> None:
    rf = "RF18539007547034"
    tx = Tx(
        5000,
        ref="T1",
        end_to_end_id=None,
        tx_id="TXID-1",
        name="MARTIN SAS",
        iban=IBAN,
        ultimate_name="MARTIN HOLDING",
        ustrd=("VIR MARTIN", "rf18 5390 0754 7034"),
        creditor_ref=rf,
    )
    pending = Entry(7000, True, START, status="PDNG", ref="P1", txs=(replace(tx, ref="T2"),))
    for version in ("02", "08"):
        parsed = _parse(
            tmp_path,
            render_camt053(_doc(Entry(5000, True, START, ref="N1", txs=(tx,)), pending), version),
        )
        (line,) = parsed.lines
        assert line.end_to_end_id is None  # NOTPROVIDED
        assert (line.tx_id, line.creditor_reference) == ("TXID-1", rf)
        assert line.remittance_text == "VIR MARTIN\nrf18 5390 0754 7034"
        assert (line.counterparty_name, line.ultimate_counterparty_name) == (
            "MARTIN SAS",
            "MARTIN HOLDING",
        )
        assert (line.counterparty_iban, line.method, line.bank_tx_code) == (
            IBAN,
            "sct",
            "PMNT/RCDT/ESCT",
        )
        assert parsed.skipped_not_booked == 1  # pending entries are not booked


def _xml(  # noqa: PLR0913 - one keyword per part of the file a test changes
    entries: str,
    *,
    opening: str = '<Amt Ccy="EUR">0.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>',
    closing: str = '<Amt Ccy="EUR">0.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>',
    opening_code: str = "OPBD",
    head: str = "",
    ccy: str = "<Ccy>EUR</Ccy>",
    iban: str = IBAN,
    ns: str = NS2,
    created: str | None = "2026-10-01T20:00:00",
    group_created: str | None = "2026-10-01T20:00:00",
    period: str = "",
    opening_date: str = "2026-09-30",
    closing_date: str = "2026-10-01",
) -> bytes:
    stmt_created = "" if created is None else f"<CreDtTm>{created}</CreDtTm>"
    grp_created = "" if group_created is None else f"<CreDtTm>{group_created}</CreDtTm>"
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>{head}<Document xmlns="{ns}"><BkToCstmrStmt>'
        f"<GrpHdr><MsgId>M</MsgId>{grp_created}</GrpHdr>"
        f"<Stmt><Id>S</Id>{stmt_created}{period}<Acct><Id><IBAN>{iban}</IBAN></Id>{ccy}</Acct>"
        f"<Bal><Tp><CdOrPrtry><Cd>{opening_code}</Cd></CdOrPrtry></Tp>{opening}"
        f"<Dt><Dt>{opening_date}</Dt></Dt></Bal>"
        f"<Bal><Tp><CdOrPrtry><Cd>CLBD</Cd></CdOrPrtry></Tp>{closing}<Dt><Dt>{closing_date}</Dt></Dt></Bal>"
        f"{entries}</Stmt></BkToCstmrStmt></Document>"
    ).encode()


def _ntry(
    amount: str,
    *,
    side: str = "CRDT",
    booked: str = "<Dt>2026-10-01</Dt>",
    ref: str = "N1",
    ccy: str = "EUR",
) -> str:
    return (
        f'<Ntry><Amt Ccy="{ccy}">{amount}</Amt><CdtDbtInd>{side}</CdtDbtInd><Sts>BOOK</Sts>'
        f"<BookgDt>{booked}</BookgDt><ValDt><DtTm>2026-10-02T10:00:00</DtTm></ValDt>"
        f"<AcctSvcrRef>{ref}</AcctSvcrRef></Ntry>"
    )


def test_hand_written_file_dates_balances_and_signs(tmp_path: Path) -> None:
    data = _xml(
        _ntry("12.30", booked="<DtTm>2026-10-01T09:30:00+02:00</DtTm>")
        + _ntry("2.30", side="DBIT", ref="N2")
        + _ntry("0.00", ref="N3"),
        opening='<Amt Ccy="EUR">5.00</Amt><CdtDbtInd>DBIT</CdtDbtInd>',
        closing='<Amt Ccy="EUR">5.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>',
        opening_code="PRCD",
    )
    parsed = _parse(tmp_path, data)
    assert [(x.direction, x.amount_minor, x.dedup_key) for x in parsed.lines] == [
        ("credit", 1230, "e:N1#1"),
        ("debit", 230, "e:N2#1"),
    ]
    assert parsed.lines[0].booking_date == date(2026, 10, 1)  # the date as the bank wrote it
    assert parsed.lines[0].value_date == date(2026, 10, 2)
    assert (parsed.sections[0].opening_minor, parsed.sections[0].closing_minor) == (-500, 500)
    assert parsed.skipped_not_booked == 1  # a zero amount moves nothing
    # no FrToDt: a PRCD balance closes the day before, so the period starts the day after it (review
    # round 4, G3)
    assert (parsed.sections[0].from_date, parsed.sections[0].to_date) == (
        date(2026, 10, 1),
        date(2026, 10, 1),
    )


@pytest.mark.parametrize(
    ("data", "code"),
    [
        (_xml(_ntry("1.00"), iban="FR1420041010050500013M02606"), "wrong_account"),
        (_xml(_ntry("1.00"), ccy="<Ccy>USD</Ccy>"), "wrong_currency"),
        (
            _xml(
                _ntry("1.00", ccy="USD"),
                closing='<Amt Ccy="EUR">1.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>',
            ),
            "wrong_currency",
        ),
        (_xml(_ntry("1.00")), "unbalanced"),
        (
            _xml(_ntry("1.001"), closing='<Amt Ccy="EUR">1.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>'),
            "amount_invalid",
        ),
        (_xml(_ntry("1,00")), "amount_invalid"),
        (_xml(_ntry("1.00", side="XXXX")), "line_invalid"),
        (_xml(_ntry("1.00", booked="<Dt>2026-13-01</Dt>")), "date_invalid"),
        (
            _xml(
                _ntry("1.00") + _ntry("1.00"),
                closing='<Amt Ccy="EUR">2.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>',
            ),
            "duplicate_reference_in_file",
        ),
        (_xml("", opening_code="ITBD"), "missing_balance"),
        (_xml("", ns="urn:iso:std:iso:20022:tech:xsd:camt.052.001.02"), "not_camt053"),
        (b"\xff\xfe<\x00?\x00x\x00", "xml_encoding"),
        (_xml(_ntry("1.00"))[:300], "xml_invalid"),
        (b"just text", "xml_invalid"),
    ],
)
def test_inexact_or_foreign_files_are_refused(tmp_path: Path, data: bytes, code: str) -> None:
    assert _refused(tmp_path, data) == code


BOMB = (
    '<!DOCTYPE d [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">'
    '<!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]>'
)
XXE = '<!DOCTYPE d [<!ENTITY x SYSTEM "file:///etc/passwd">]>'


@pytest.mark.parametrize(
    "head", [BOMB, XXE, '<!DOCTYPE Document SYSTEM "http://example.invalid/camt.dtd">']
)
def test_document_type_declarations_are_refused_before_parsing(tmp_path: Path, head: str) -> None:
    """No entity can be defined, so none is expanded or fetched (XXE, entity bombs)."""
    assert (
        _refused(tmp_path, _xml(_ntry("1.00").replace("N1", "&c;"), head=head)) == "xml_dtd_refused"
    )


def test_a_long_prolog_cannot_hide_a_declaration(tmp_path: Path) -> None:
    padding = "<!--" + "x" * 70_000 + "-->"
    assert _refused(tmp_path, _xml("", head=padding + XXE)) == "xml_invalid"


def test_entries_outside_a_statement_refuse_the_file(tmp_path: Path) -> None:
    data = _xml("").replace(b"<GrpHdr>", b"<GrpHdr>" + _ntry("1.00").encode())
    assert _refused(tmp_path, data) == "not_camt053"


def test_several_statements_in_one_file(tmp_path: Path) -> None:
    first = Stmt("S1", 7, IBAN, "EUR", START, START, 100, (Entry(500, True, START, ref="A"),))
    second = Stmt(
        "S2",
        8,
        IBAN,
        "EUR",
        START + timedelta(days=1),
        START + timedelta(days=1),
        600,
        (Entry(200, False, START + timedelta(days=1), ref="B", code="PMNT/MDOP/FEES"),),
    )
    parsed = _parse(
        tmp_path, render_camt053(Doc("M", "2026-10-02T20:00:00", (first, second)), "08")
    )
    assert [(s.stmt_id, s.seq, s.opening_minor, s.closing_minor) for s in parsed.sections] == [
        ("S1", 7, 100, 600),
        ("S2", 8, 600, 400),
    ]
    assert [(x.section_no, x.kind) for x in parsed.lines] == [
        (1, "debtor_credit"),
        (2, "other_debit"),
    ]
    header = parsed.header()
    assert header["sections"][1]["closing_minor"] == "400"  # amounts as text
    assert header["line_count"] == 2


def test_a_line_booked_in_the_future_is_refused(tmp_path: Path) -> None:
    doc = _doc(Entry(500, True, START, ref="A"))
    assert (
        _refused(tmp_path, render_camt053(doc), today=START - timedelta(days=1))
        == "future_booking_date"
    )


# -- review fixes (M2b-2) -------------------------------------------------------------------------


def _keys(tmp_path: Path, entry: Entry) -> list[tuple[str, int, str | None]]:
    parsed = _parse(tmp_path, render_camt053(_doc(entry), "08"))
    return [(x.dedup_key, x.amount_minor, x.entry_ref) for x in parsed.lines]


def test_an_entry_kept_as_one_line_has_the_same_key_with_or_without_one_detail(
    tmp_path: Path,
) -> None:
    """Review #0/#5: one entry, one line, one key (`e:REF#1`), whatever detail the file gives;
    every line carries the entry's own reference (`entry_ref`), the import's backstop."""
    no_details = Entry(5000, True, START, ref="R1")
    one_detail = Entry(5000, True, START, ref="R1", txs=(Tx(5000, name="DUPONT"),))
    assert _keys(tmp_path, no_details) == _keys(tmp_path, one_detail) == [("e:R1#1", 5000, "R1")]
    own_ref = Entry(5000, True, START, ref="R1", txs=(Tx(5000, ref="X1", name="DUPONT"),))
    assert _keys(tmp_path, own_ref) == [("t:X1", 5000, "R1")]  # design §8.3: the line's own ref


def test_a_batch_unsplit_or_split_meets_its_earlier_lines(tmp_path: Path) -> None:
    """Review #0: the unsplit batch is `e:REM1#1` (booked amount), the same batch split without
    references of its own `e:REM1#1`, `e:REM1#2`: the first key comes back with another amount
    (reference_conflict); split with its own references, every line still names REM1."""
    unsplit = Entry(15000, True, START, ref="REM1", batch_count=2)
    no_refs = Entry(15000, True, START, ref="REM1", txs=(Tx(10000), Tx(5000)), batch_count=2)
    own = Entry(
        15000,
        True,
        START,
        ref="REM1",
        txs=(Tx(10000, ref="T1"), Tx(5000, ref="T2")),
        batch_count=2,
    )
    assert _keys(tmp_path, unsplit) == [("e:REM1#1", 15000, "REM1")]
    assert _keys(tmp_path, no_refs) == [("e:REM1#1", 10000, "REM1"), ("e:REM1#2", 5000, "REM1")]
    assert _keys(tmp_path, own) == [("t:T1", 10000, "REM1"), ("t:T2", 5000, "REM1")]
    no_ref = Entry(5000, True, START, txs=(Tx(5000, name="DUPONT"),))
    ((key, _, entry_ref),) = _keys(tmp_path, no_ref)
    assert key.startswith("h:") and entry_ref is None


def test_an_unsplit_batch_that_undoes_a_debit_is_a_return(tmp_path: Path) -> None:
    """Review #4/#14 (ADR-0013 M2b-2 #2): a credit that undoes a debit is a `return`, never a
    payment, even when its batch cannot be split; the reason of any detail is kept."""
    reversed_batch = Entry(
        30000, True, START, reversal=True, ref="R1", code="PMNT/ICDT/RRTN", batch_count=3
    )
    returned_details = Entry(
        8000,
        True,
        START,
        ref="R2",
        txs=(Tx(None, ref="T1", return_reason="AC04"), Tx(None, ref="T2", return_reason="MD06")),
        batch_count=2,
    )
    miscounted = Entry(
        4000, True, START, ref="R3", txs=(Tx(4000, ref="T3", return_reason="AC04"),), batch_count=2
    )
    plain = Entry(9000, True, START, ref="R4", batch_count=3)
    debit = Entry(700, False, START, ref="R5", code="PMNT/ICDT/ESCT", batch_count=2)
    doc = _doc(reversed_batch, returned_details, miscounted, plain, debit)
    parsed = _parse(tmp_path, render_camt053(doc, "08"))
    got = [(x.kind, x.direction, x.amount_minor, x.return_reason) for x in parsed.lines]
    assert got == [
        ("return", "credit", 30000, None),
        ("return", "credit", 8000, "AC04"),
        ("return", "credit", 4000, "AC04"),
        ("batch_unsplit", "credit", 9000, None),
        ("batch_unsplit", "debit", 700, None),
    ]
    _assert_lines(parsed, expected_lines(doc))  # the generator's ground truth agrees


def test_an_unsplit_batch_with_instructed_amounts_only_and_a_return_reason(tmp_path: Path) -> None:
    """Review #4: details that carry only AmtDtls/InstdAmt cannot be split; their RtrInf still
    makes the credit a return."""
    tx = (
        "<TxDtls><Refs><EndToEndId>E{i}</EndToEndId></Refs>"
        '<AmtDtls><InstdAmt><Amt Ccy="EUR">40.00</Amt></InstdAmt></AmtDtls>'
        "<RtrInf><Rsn><Cd>AC04</Cd></Rsn></RtrInf></TxDtls>"
    )
    ntry = (
        '<Ntry><Amt Ccy="EUR">80.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><Sts>BOOK</Sts>'
        "<BookgDt><Dt>2026-10-01</Dt></BookgDt><AcctSvcrRef>R1</AcctSvcrRef>"
        "<NtryDtls><Btch><NbOfTxs>2</NbOfTxs></Btch>"
        f"{tx.format(i=1)}{tx.format(i=2)}</NtryDtls></Ntry>"
    )
    data = _xml(ntry, closing='<Amt Ccy="EUR">80.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>')
    (line,) = _parse(tmp_path, data).lines
    assert (line.kind, line.amount_minor, line.return_reason, line.dedup_key) == (
        "return",
        8000,
        "AC04",
        "e:R1#1",
    )


@pytest.mark.parametrize(
    "written", ["2026-10-01+01:00", "2026-10-01-05:00", "2026-10-01Z", "2026-10-01+14:00"]
)
def test_an_xs_date_with_a_time_zone_keeps_the_date_as_written(
    tmp_path: Path, written: str
) -> None:
    """Review #7: ISODate is xs:date, whose time zone is optional; the business date is the
    date as the bank wrote it (no conversion)."""
    data = _xml(
        _ntry("1.00", booked=f"<Dt>{written}</Dt>"),
        closing='<Amt Ccy="EUR">1.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>',
    ).replace(b"<Dt><Dt>2026-10-01</Dt></Dt>", f"<Dt><Dt>{written}</Dt></Dt>".encode())
    parsed = _parse(tmp_path, data)
    assert parsed.lines[0].booking_date == date(2026, 10, 1)
    assert parsed.sections[0].to_date == date(2026, 10, 1)


@pytest.mark.parametrize(
    ("from_written", "to_written", "period"),
    [
        # N6: X's statement up to the next midnight is X's alone (nothing of Y is on it)
        ("2026-10-28T00:00:00+01:00", "2026-10-29T00:00:00+01:00", (date(2026, 10, 28),) * 2),
        # review round 4 (G3): the midnight is Paris time — 00:00 UTC is 01:00 in Paris, so this
        # period reaches into the 29th (not its whole day: covers_to stays the 28th)
        (
            "2026-10-28T00:00:00",
            "2026-10-29T00:00:00.000Z",
            (date(2026, 10, 28), date(2026, 10, 29)),
        ),
        (
            "2026-10-27T00:00:00+01:00",
            "2026-10-29T00:00:00+01:00",
            (date(2026, 10, 27), date(2026, 10, 28)),
        ),
        # a period ending within its last day keeps it; a midnight on its first day is that day
        ("2026-10-28T00:00:00+01:00", "2026-10-28T23:59:59+01:00", (date(2026, 10, 28),) * 2),
        (
            "2026-10-28T00:00:00+01:00",
            "2026-10-29T00:00:01+01:00",
            (date(2026, 10, 28), date(2026, 10, 29)),
        ),
        ("2026-10-28T00:00:00+01:00", "2026-10-28T00:00:00+01:00", (date(2026, 10, 28),) * 2),
    ],
)
def test_a_to_date_time_at_midnight_ends_the_period_the_day_before(
    tmp_path: Path, from_written: str, to_written: str, period: tuple[date, date]
) -> None:
    """M2c-6a review round 3 (E4, N6): ToDtTm is read conservatively — a ToDtTm at T00:00:00 on a
    later date than the period's start ends it the day before, so the statement is never taken
    for one of a day it shows nothing of (the evidence before re-issuing a transfer, OQ-80 (f))."""
    data = _xml(
        "",
        period=f"<FrToDt><FrDtTm>{from_written}</FrDtTm><ToDtTm>{to_written}</ToDtTm></FrToDt>",
    )
    section = _parse(tmp_path, data).sections[0]
    assert (section.from_date, section.to_date) == period


OCT = (date(2026, 10, 26), date(2026, 10, 27), date(2026, 10, 28), date(2026, 10, 29))


@pytest.mark.parametrize(
    ("from_written", "to_written", "period", "whole"),
    [
        # H8a: the afternoon of a day up to the next midnight shows no whole day
        ("2026-10-28T14:00:00+01:00", "2026-10-29T00:00:00+01:00", (OCT[2],) * 2, None),
        # H8b: a Paris day written in UTC is that Paris day, not the day before
        ("2026-10-27T23:00:00Z", "2026-10-28T23:00:00Z", (OCT[2],) * 2, (OCT[2],) * 2),
        ("2026-10-27T23:00:00.000Z", "2026-10-28T22:59:59Z", (OCT[2],) * 2, (OCT[2],) * 2),
        # a UTC day is the end of one Paris day and the start of the next: no whole Paris day
        ("2026-10-28T00:00:00Z", "2026-10-29T00:00:00Z", (OCT[2], OCT[3]), None),
        # a day statement written in Paris time, with or without its offset, is that day
        ("2026-10-28T00:00:00+01:00", "2026-10-28T23:59:59+01:00", (OCT[2],) * 2, (OCT[2],) * 2),
        ("2026-10-28T00:00:00", "2026-10-28T23:59:59.999", (OCT[2],) * 2, (OCT[2],) * 2),
        # T24:00:00 is the end of its day (xs:dateTime)
        ("2026-10-28T00:00:00", "2026-10-28T24:00:00", (OCT[2],) * 2, (OCT[2],) * 2),
        # from a cut-off to the next: the first day starts late, the last ends early — no whole day
        ("2026-10-27T18:00:00+01:00", "2026-10-28T18:00:00+01:00", (OCT[1], OCT[2]), None),
        # a period ending during its last day shows that day only in part
        ("2026-10-27T00:00:00+01:00", "2026-10-28T14:00:00+01:00", (OCT[1], OCT[2]), (OCT[1],) * 2),
        ("2026-10-28T00:00:00+01:00", "2026-10-29T00:00:01+01:00", (OCT[2], OCT[3]), (OCT[2],) * 2),
        # a period that starts and ends at the same midnight holds nothing
        ("2026-10-28T00:00:00+01:00", "2026-10-28T00:00:00+01:00", (OCT[2],) * 2, None),
        # a bound written as a date only is read as its midnight (the start of that day)
        ("2026-10-27", "2026-10-29", (OCT[1], OCT[2]), (OCT[1], OCT[2])),
    ],
)
def test_a_statement_covers_only_the_whole_days_of_its_period_in_paris_time(
    tmp_path: Path,
    from_written: str,
    to_written: str,
    period: tuple[date, date],
    whole: tuple[date, date] | None,
) -> None:
    """M2c-6a review round 4 (G3, H8a, H8b): FrDtTm and ToDtTm are read in Paris time (their
    offset, or Paris when none). The section keeps its period (from_date … to_date: its first and
    last day, a ToDtTm at the next midnight ending it the day before) and the days it shows whole
    (covers_from … covers_to: none when it shows part of a day only) — the only days it can prove
    nothing was debited on (private.statement_covers, OQ-80 (f))."""
    data = _xml(
        "",
        period=f"<FrToDt><FrDtTm>{from_written}</FrDtTm><ToDtTm>{to_written}</ToDtTm></FrToDt>",
    )
    section = _parse(tmp_path, data).sections[0]
    assert (section.from_date, section.to_date) == period
    assert (
        None if section.covers_from is None else (section.covers_from, section.covers_to)
    ) == whole
    covers = section.as_json()
    assert (covers["covers_from"], covers["covers_to"]) == (
        (None, None) if whole is None else (whole[0].isoformat(), whole[1].isoformat())
    )


@pytest.mark.parametrize(
    ("code", "opening_date", "closing_date", "period"),
    [
        # H8 (no FrToDt): an opening balance dated the day before the closing one is that
        # evening's, so the statement is of the closing day — not of both
        ("OPBD", "2026-10-27", "2026-10-28", (OCT[2],) * 2),
        # a PRCD balance is the previous day's closing by definition
        ("PRCD", "2026-10-27", "2026-10-28", (OCT[2],) * 2),
        ("OPBD", "2026-10-28", "2026-10-28", (OCT[2],) * 2),
        ("OPBD", "2026-10-25", "2026-10-28", (OCT[0], OCT[2])),
    ],
)
def test_without_a_period_a_statement_starts_after_its_opening_balance(
    tmp_path: Path, code: str, opening_date: str, closing_date: str, period: tuple[date, date]
) -> None:
    """M2c-6a review round 4 (G3): without FrToDt the period starts at the closing balance's date,
    or the day after the opening balance's when that one is dated before the closing or is a PRCD
    (it may be the previous evening's); it ends at the closing balance's date, every day whole."""
    data = _xml("", opening_code=code, opening_date=opening_date, closing_date=closing_date)
    section = _parse(tmp_path, data).sections[0]
    assert (section.from_date, section.to_date) == period
    assert (section.covers_from, section.covers_to) == period


@pytest.mark.parametrize(
    ("code", "opening_date"),
    [
        # a bank that dates the previous closing (PRCD) with the statement's own day
        ("PRCD", "2026-10-28"),
        # an opening balance dated after the closing one
        ("OPBD", "2026-10-29"),
        ("PRCD", "2026-10-29"),
    ],
)
def test_without_a_period_a_statement_never_starts_after_its_closing_balance(
    tmp_path: Path, code: str, opening_date: str
) -> None:
    """M2c-6a review round 5 (the G3 reader regression): without FrToDt, an opening balance whose
    next day is after the closing balance's date gave a period starting one day after the
    closing (28 → 29 for a PRCD dated on the 28th), so consecutive statements never met (no
    `statement_gap`, no `opening_differs`, an `overlap` on every import). The period is then the
    closing balance's day alone, and no day is shown whole: how the bank dates that balance is not
    known (COMPLIANCE OQ-80 (f): ask the bank how it dates PRCD/OPBD)."""
    data = _xml("", opening_code=code, opening_date=opening_date, closing_date="2026-10-28")
    section = _parse(tmp_path, data).sections[0]
    assert (section.from_date, section.to_date) == (OCT[2], OCT[2])
    assert (section.covers_from, section.covers_to) == (None, None)


@pytest.mark.parametrize(
    ("stmt", "group", "kept"),
    [
        (
            "2026-10-29T06:10:00+01:00",
            "2026-10-30T00:00:00Z",
            datetime(2026, 10, 29, 5, 10, tzinfo=UTC),
        ),
        ("2026-10-29T06:10:00Z", None, datetime(2026, 10, 29, 6, 10, tzinfo=UTC)),
        # no offset: the bank's local time, Paris (CET in late October, CEST before)
        (
            "2026-10-29T06:10:00.123456789",
            None,
            datetime(2026, 10, 29, 5, 10, 0, 123456, tzinfo=UTC),
        ),
        ("2026-10-01T20:00:00", None, datetime(2026, 10, 1, 18, 0, tzinfo=UTC)),
        # a <Stmt> without its own: the group header's
        (None, "2026-10-29T06:10:00+01:00", datetime(2026, 10, 29, 5, 10, tzinfo=UTC)),
        (None, None, None),
    ],
)
def test_the_creation_time_of_the_statement_is_kept(
    tmp_path: Path, stmt: str | None, group: str | None, kept: datetime | None
) -> None:
    """M2c-6a review round 3 (E4): Stmt/CreDtTm, GrpHdr/CreDtTm as its fallback, is kept with its
    offset; the import stores it (`bank_statement.bank_created_at`) and a statement covers a day
    only once the bank produced it after that day, whenever it is uploaded."""
    section = _parse(tmp_path, _xml("", created=stmt, group_created=group)).sections[0]
    assert section.created_at == kept
    if kept is not None:
        assert section.created_at is not None and section.created_at.utcoffset() is not None
        assert datetime.fromisoformat(section.as_json()["created_at"]) == kept
    else:
        assert section.as_json()["created_at"] is None


@pytest.mark.parametrize(
    "written", ["29/10/2026 06:10", "2026-10-29", "2026-10-29T06:10", "2026-10-29T06:10:00+1:00"]
)
def test_a_creation_time_that_is_not_a_date_time_is_refused(tmp_path: Path, written: str) -> None:
    assert _refused(tmp_path, _xml("", created=written)) == "date_invalid"
    assert _refused(tmp_path, _xml("", created=None, group_created=written)) == "date_invalid"


@pytest.mark.parametrize(
    "written", ["2026-10-01+1:00", "2026-10-01+15:00", "2026-10-01+01:60", "2026-10-01T10:00:00"]
)
def test_a_date_with_anything_else_after_it_is_refused(tmp_path: Path, written: str) -> None:
    data = _xml(
        _ntry("1.00", booked=f"<Dt>{written}</Dt>"),
        closing='<Amt Ccy="EUR">1.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>',
    )
    assert _refused(tmp_path, data) == "date_invalid"


def test_a_statement_beyond_the_line_cap_is_refused_while_streaming(tmp_path: Path) -> None:
    """Review #13: like the CSV reader, at most 250,000 lines (a parameter here): the reader stops
    at the first line beyond the cap, before the lines pile up in memory."""
    batch = Entry(3500, True, START, ref="N1", txs=(Tx(1000, ref="T1"), Tx(2500, ref="T2")))
    doc = _doc(Entry(500, True, START, ref="A"), batch)
    path = tmp_path / "statement.xml"
    path.write_bytes(render_camt053(doc, "08"))
    assert len(parse_camt053(path, iban=IBAN, currency="EUR", max_lines=3).lines) == 3
    with pytest.raises(StatementRejected) as err:
        parse_camt053(path, iban=IBAN, currency="EUR", max_lines=2)
    assert err.value.code == "file_too_large"
    assert MAX_LINES == 250_000
