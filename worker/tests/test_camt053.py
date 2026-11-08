"""camt.053 reader (M2-07, design §8.3 and §13): synthetic statements of every version French banks
send are read line for line as the generator wrote them (batch bookings, returns, RF references,
free text, twins); hand-written files pin the edge cases; unsafe or inexact files are refused with
a stable code and nothing is returned."""

from dataclasses import replace
from datetime import date, timedelta
from pathlib import Path

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from collectoo_worker.payments.camt053 import parse_camt053
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
            "e:N2#0",
            "N2",
        ),  # details do not add up: one line, the booked amount
        ("batch_unsplit", 9000, "e:N3#0", "N3"),  # no details
        ("batch_unsplit", 3500, "e:N4#0", "N4"),  # 3 announced, 2 detailed
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
) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>{head}<Document xmlns="{ns}"><BkToCstmrStmt>'
        "<GrpHdr><MsgId>M</MsgId><CreDtTm>2026-10-01T20:00:00</CreDtTm></GrpHdr>"
        f"<Stmt><Id>S</Id><CreDtTm>2026-10-01T20:00:00</CreDtTm><Acct><Id><IBAN>{iban}</IBAN></Id>{ccy}</Acct>"
        f"<Bal><Tp><CdOrPrtry><Cd>{opening_code}</Cd></CdOrPrtry></Tp>{opening}<Dt><Dt>2026-09-30</Dt></Dt></Bal>"
        f"<Bal><Tp><CdOrPrtry><Cd>CLBD</Cd></CdOrPrtry></Tp>{closing}<Dt><Dt>2026-10-01</Dt></Dt></Bal>"
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
        ("credit", 1230, "e:N1#0"),
        ("debit", 230, "e:N2#0"),
    ]
    assert parsed.lines[0].booking_date == date(2026, 10, 1)  # the date as the bank wrote it
    assert parsed.lines[0].value_date == date(2026, 10, 2)
    assert (parsed.sections[0].opening_minor, parsed.sections[0].closing_minor) == (-500, 500)
    assert parsed.skipped_not_booked == 1  # a zero amount moves nothing
    assert (parsed.sections[0].from_date, parsed.sections[0].to_date) == (
        date(2026, 9, 30),
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
