"""The statement's own detail of an entry kept unsplit, and the charges it records (M2c-6b-2a, plan
docs/design/m2c-6b-2-plan.md §2.1-§2.2; critic F8, L11; critic2 ML-5, ML-6, ML-10, CSO2-9).

An entry the parser keeps as one line (its details cannot be split) now carries the details of ours
the statement itself gives — id (own or original), direction, amount (`Amt` first, then
`AmtDtls/TxAmt/Amt`, in the statement's currency, else none) — with the entry's detail count and
NbOfTxs; a line that is its entry's only line carries the charges the statement records for it
(`Chrgs`: debit records in the account's currency included in the entry amount, else none).
What the import checks (private.ingest_statement) holds for every line the parser returns."""

from __future__ import annotations

import re
from dataclasses import replace
from datetime import date
from pathlib import Path

from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from collectoo_worker.payments.camt053 import parse_camt053
from collectoo_worker.payments.statement import (
    OUR_ISSUED_ID_RE,
    ParsedStatement,
    StatementLine,
    UnsplitDetail,
)
from collectoo_worker.synth.camt053 import Entry, Tx, generate_entries, make_doc, render_camt053

IBAN = "FR7630004000031234567890143"
START = date(2026, 10, 1)
NS = {
    "02": "urn:iso:std:iso:20022:tech:xsd:camt.053.001.02",
    "08": "urn:iso:std:iso:20022:tech:xsd:camt.053.001.08",
}
RMT_A = "RMT0000000000A1"
RMT_B = "RMT0000000000B2"


def _parse(tmp_path: Path, data: bytes) -> ParsedStatement:
    path = tmp_path / "statement.xml"
    path.write_bytes(data)
    return parse_camt053(path, iban=IBAN, currency="EUR")


def _amt(value: str, ccy: str = "EUR") -> str:
    return f'<Amt Ccy="{ccy}">{value}</Amt>'


def _tx(  # noqa: PLR0913 - one keyword per part of a detail a test changes
    e2e: str | None = None,
    *,
    orig: str | None = None,
    amt: str | None = None,
    tx_amt: str | None = None,
    ccy: str = "EUR",
    tx_ccy: str = "EUR",
    side: str | None = None,
    charges: str = "",
    reason: str | None = None,
) -> str:
    out = f"<TxDtls><Refs><EndToEndId>{e2e or 'NOTPROVIDED'}</EndToEndId></Refs>"
    if amt is not None:
        out += _amt(amt, ccy)
    if side is not None:
        out += f"<CdtDbtInd>{side}</CdtDbtInd>"
    if tx_amt is not None:
        out += f"<AmtDtls><TxAmt>{_amt(tx_amt, tx_ccy)}</TxAmt></AmtDtls>"
    out += charges
    if reason or orig:
        out += "<RtrInf>"
        out += f"<OrgnlEndToEndId>{orig}</OrgnlEndToEndId>" if orig else ""
        out += f"<Rsn><Cd>{reason}</Cd></Rsn>" if reason else ""
        out += "</RtrInf>"
    return out + "</TxDtls>"


def _ntry(  # noqa: PLR0913 - one keyword per part of an entry a test changes
    amount: str,
    *details: str,
    side: str = "DBIT",
    ref: str = "N1",
    nb: int | None = None,
    charges: str = "",
    sts: str = "<Sts><Cd>BOOK</Cd></Sts>",
) -> str:
    batch = f"<Btch><NbOfTxs>{nb}</NbOfTxs></Btch>" if nb is not None else ""
    dtls = f"<NtryDtls>{batch}{''.join(details)}</NtryDtls>" if details or batch else ""
    return (
        f"<Ntry>{_amt(amount)}<CdtDbtInd>{side}</CdtDbtInd>{sts}"
        f"<BookgDt><Dt>2026-10-01</Dt></BookgDt><AcctSvcrRef>{ref}</AcctSvcrRef>"
        f"{charges}{dtls}</Ntry>"
    )


def _xml(entries: list[str], version: str = "08") -> bytes:
    """A statement opened at 10 000,00 € (so that any entry fits), closed by its entries."""
    moved = 0
    for e in entries:
        m = re.search(r'<Amt Ccy="EUR">([0-9.]+)</Amt><CdtDbtInd>(CRDT|DBIT)</CdtDbtInd>', e)
        assert m is not None
        cents = round(float(m.group(1)) * 100)
        moved += cents if m.group(2) == "CRDT" else -cents
    closing = 1_000_000 + moved
    bal = (
        "<Bal><Tp><CdOrPrtry><Cd>{code}</Cd></CdOrPrtry></Tp>"
        '<Amt Ccy="EUR">{amt}</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>{day}</Dt></Dt></Bal>'
    )
    return (
        f'<?xml version="1.0" encoding="UTF-8"?><Document xmlns="{NS[version]}"><BkToCstmrStmt>'
        "<GrpHdr><MsgId>M</MsgId><CreDtTm>2026-10-01T20:00:00</CreDtTm></GrpHdr>"
        f"<Stmt><Id>S</Id><CreDtTm>2026-10-01T20:00:00</CreDtTm><Acct><Id><IBAN>{IBAN}</IBAN></Id>"
        "<Ccy>EUR</Ccy></Acct>"
        + bal.format(code="OPBD", amt="10000.00", day="2026-09-30")
        + bal.format(code="CLBD", amt=f"{closing // 100}.{closing % 100:02d}", day="2026-10-01")
        + "".join(entries)
        + "</Stmt></BkToCstmrStmt></Document>"
    ).encode()


def _chrgs(
    amount: str,
    *,
    ind: str | None = "DBIT",
    incl: str | None = "true",
    ccy: str = "EUR",
    v02: bool = False,
) -> str:
    """One charges record: v04 and later wrap it in Rcrd (with ChrgInclInd); v02's has none."""
    side = f"<CdtDbtInd>{ind}</CdtDbtInd>" if ind else ""
    if v02:
        return f"<Chrgs>{_amt(amount, ccy)}{side}</Chrgs>"
    included = f"<ChrgInclInd>{incl}</ChrgInclInd>" if incl else ""
    return f"<Chrgs><Rcrd>{_amt(amount, ccy)}{side}{included}</Rcrd></Chrgs>"


def test_an_unsplit_entry_keeps_its_details_of_ours_in_the_file_order(tmp_path: Path) -> None:
    """The round-5 netted credit (our payout's return netted with another payout's debit) and d03
    (two debits of ours whose details do not add up): each detail of ours with its direction and
    amount, in the file's order; the entry's detail count and NbOfTxs."""
    netted = _ntry(
        "3870.40",
        _tx("NOTPROVIDED", orig=RMT_A, amt="4198.40", side="CRDT", reason="AC04"),
        _tx(RMT_B, amt="328.00", side="DBIT"),
        side="CRDT",
        ref="N1",
        nb=2,
    )
    d03 = _ntry(
        "700.00",
        _tx("RMT0000000000C3", amt="300.00", side="DBIT"),
        _tx("SWP0000000000C4", amt="450.00", side="DBIT"),
        ref="N2",
    )
    lines = _parse(tmp_path, _xml([netted, d03])).lines
    assert [
        (x.kind, x.unsplit_ours, x.unsplit_details, x.unsplit_detail_count, x.unsplit_batch_count)
        for x in lines
    ] == [
        (
            "return",
            2,
            (UnsplitDetail(RMT_A, "credit", 419840), UnsplitDetail(RMT_B, "debit", 32800)),
            2,
            2,
        ),
        (
            "batch_unsplit",
            2,
            (
                UnsplitDetail("RMT0000000000C3", "debit", 30000),
                UnsplitDetail("SWP0000000000C4", "debit", 45000),
            ),
            2,
            None,
        ),
    ]


def test_ml5_an_entry_with_our_detail_and_others_counts_every_detail(tmp_path: Path) -> None:
    """ML-5: our detail and two others (a debtor's credit and a debit netting it): count 3,
    unsplit_ours 1 — what lets a booking tell an entry made only of ours from one that is not."""
    entry = _ntry(
        "200.00",
        _tx(RMT_A, amt="200.00", side="DBIT"),
        _tx("E2E-DEBTOR", amt="55.00", side="CRDT"),
        _tx("E2E-OTHER", amt="55.00", side="DBIT"),
        nb=3,
    )
    (line,) = _parse(tmp_path, _xml([entry])).lines
    assert (
        line.unsplit_ours,
        line.unsplit_details,
        line.unsplit_detail_count,
        line.unsplit_batch_count,
    ) == (1, (UnsplitDetail(RMT_A, "debit", 20000),), 3, 3)


def test_a_detail_s_amount_is_read_as_split_and_whole_read_it(tmp_path: Path) -> None:
    """CSO2-9, ML-6: `Amt` first, then `AmtDtls/TxAmt/Amt`, in the statement's currency — the
    amount that decided the entry was unsplit; a detail without one, or only in another currency,
    keeps none."""
    entry = _ntry(
        "1680.00",
        _tx(RMT_A, amt="1640.00", side="DBIT", tx_amt="1600.00", tx_ccy="USD"),
        _tx(RMT_B, tx_amt="30.00", tx_ccy="USD"),
        _tx("RFD0000000000D3"),
        _tx("TOP0000000000D4", tx_amt="5.00"),
        ref="N1",
    )
    (line,) = _parse(tmp_path, _xml([entry])).lines
    assert line.unsplit_details == (
        UnsplitDetail(RMT_A, "debit", 164000),
        UnsplitDetail(RMT_B, "debit", None),
        UnsplitDetail("RFD0000000000D3", "debit", None),
        UnsplitDetail("TOP0000000000D4", "debit", 500),
    )
    assert line.unsplit_detail_count == 4
    hash(line)  # StatementLine (frozen, slotted) stays hashable with its details


def test_an_unsplit_entry_with_none_of_ours_keeps_no_details_but_its_count(tmp_path: Path) -> None:
    entry = _ntry("90.00", _tx("E2E-1", amt="50.00"), _tx("E2E-2", amt="50.00"), side="CRDT")
    (line,) = _parse(tmp_path, _xml([entry])).lines
    assert (line.kind, line.unsplit_ours, line.unsplit_details, line.unsplit_detail_count) == (
        "batch_unsplit",
        0,
        (),
        2,
    )


def test_a_whole_entry_detail_is_still_a_line_of_its_own(tmp_path: Path) -> None:
    """Review round 7 (S1) unchanged: a detail of ours that is the whole entry is its line, with no
    unsplit details; a split batch's lines neither."""
    whole = _ntry("1640.00", _tx(RMT_A, amt="1640.00", side="DBIT"), ref="N1")
    split = _ntry(
        "50.00", _tx("E2E-1", amt="20.00"), _tx("E2E-2", amt="30.00"), side="CRDT", ref="N2"
    )
    lines = _parse(tmp_path, _xml([whole, split])).lines
    assert [
        (
            x.end_to_end_id,
            x.amount_minor,
            x.unsplit_ours,
            x.unsplit_details,
            x.unsplit_detail_count,
            x.unsplit_batch_count,
        )
        for x in lines
    ] == [
        (RMT_A, 164000, None, None, None, None),
        ("E2E-1", 2000, None, None, None, None),
        ("E2E-2", 3000, None, None, None, None),
    ]


def test_ml6_the_iso_shape_of_a_charged_transfer_is_unsplit_with_its_charge(
    tmp_path: Path,
) -> None:
    """ML-6, CSO2-1: our transfer at N in its detail (TxAmt), the entry N + F, F in `Chrgs`: kept
    unsplit (class U) with its one detail at N and the stored charge F."""
    entry = _ntry("1641.20", _tx(RMT_A, tx_amt="1640.00"), charges=_chrgs("1.20"))
    (line,) = _parse(tmp_path, _xml([entry])).lines
    assert (
        line.kind,
        line.amount_minor,
        line.unsplit_ours,
        line.unsplit_details,
        line.unsplit_detail_count,
        line.charges_minor,
    ) == ("batch_unsplit", 164120, 1, (UnsplitDetail(RMT_A, "debit", 164000),), 1, 120)
    # without the detail's amount the detail is the whole entry: a line of its own, its charge kept
    own = _ntry("1641.20", _tx(RMT_A), charges=_chrgs("1.20"))
    (line,) = _parse(tmp_path, _xml([own])).lines
    assert (line.kind, line.end_to_end_id, line.unsplit_ours, line.charges_minor) == (
        "transfer_out",
        RMT_A,
        None,
        120,
    )


def test_charges_are_read_from_the_entry_and_its_one_detail(tmp_path: Path) -> None:
    """ML-6, ML-10: v02 (`Chrgs/Amt`) and v04+ (`Chrgs/Rcrd/Amt`), on the entry or on its one
    detail, several records summed; both levels must agree."""
    cases = [
        ("02", _ntry("10.00", charges=_chrgs("1.20", v02=True)), 120),
        ("08", _ntry("10.00", charges=_chrgs("1.20")), 120),
        ("08", _ntry("10.00", charges=_chrgs("1.20") + _chrgs("0.30", incl=None)), 150),
        ("08", _ntry("10.00", _tx(RMT_A, charges=_chrgs("1.20"))), 120),
        ("08", _ntry("10.00", _tx(RMT_A, charges=_chrgs("1.20")), charges=_chrgs("1.20")), 120),
        ("08", _ntry("10.00", _tx(RMT_A, charges=_chrgs("1.20")), charges=_chrgs("1.30")), None),
        ("08", _ntry("10.00"), None),
    ]
    for version, entry, want in cases:
        (line,) = _parse(tmp_path, _xml([entry], version)).lines
        assert line.charges_minor == want, (version, entry)


def test_charges_that_cannot_be_read_as_the_bank_s_debit_are_none(tmp_path: Path) -> None:
    """ML-6: a credit record, another currency, ChrgInclInd false (pre-advised, not in the entry),
    a record without its direction, or one that is not an amount: none is the statement's word for
    a charge in the entry — the line keeps none (never a guess, never a refusal of the file)."""
    for record in (
        _chrgs("1.20", ind="CRDT"),
        _chrgs("1.20", ccy="USD"),
        _chrgs("1.20", incl="false"),
        _chrgs("1.20", ind=None),
        _chrgs("0.00"),
        _chrgs("1.20") + _chrgs("0.50", ind="CRDT"),
        '<Chrgs><TtlChrgsAndTaxAmt Ccy="EUR">1.20</TtlChrgsAndTaxAmt></Chrgs>',
    ):
        (line,) = _parse(tmp_path, _xml([_ntry("10.00", charges=record)])).lines
        assert line.charges_minor is None, record


def test_charges_belong_only_to_a_line_that_is_its_entry_s_only_line(tmp_path: Path) -> None:
    """A split batch's lines keep none (the entry's charge is no one line's); an unsplit entry of
    several details keeps the entry's own record only when no detail carries one."""
    split = _ntry(
        "50.00",
        _tx("E2E-1", amt="20.00"),
        _tx("E2E-2", amt="30.00"),
        side="CRDT",
        ref="N1",
        charges=_chrgs("1.00"),
    )
    unsplit = _ntry(
        "60.00", _tx(RMT_A, amt="20.00"), _tx(RMT_B, amt="30.00"), ref="N2", charges=_chrgs("1.00")
    )
    detailed = _ntry(
        "60.00",
        _tx(RMT_A, amt="20.00", charges=_chrgs("1.00")),
        _tx(RMT_B, amt="30.00"),
        ref="N3",
        charges=_chrgs("1.00"),
    )
    lines = _parse(tmp_path, _xml([split, unsplit, detailed])).lines
    assert [x.charges_minor for x in lines] == [None, None, 100, None]


def _ingest_accepts(line: StatementLine) -> bool:  # noqa: PLR0911 - one exit per check
    """The shape private.ingest_statement checks (line_invalid otherwise), as the parser must give
    it: details only with unsplit_ours, exactly that many, ours, a direction, digits; counts only
    with details, the detail count at least unsplit_ours; a positive charge."""
    if line.unsplit_details is None:
        if line.unsplit_detail_count is not None or line.unsplit_batch_count is not None:
            return False
    else:
        if line.unsplit_ours is None or len(line.unsplit_details) != line.unsplit_ours:
            return False
        if line.unsplit_detail_count is None or line.unsplit_detail_count < line.unsplit_ours:
            return False
        for d in line.unsplit_details:
            if OUR_ISSUED_ID_RE.fullmatch(d.id) is None or d.direction not in ("debit", "credit"):
                return False
            if d.amount_minor is not None and not 0 < d.amount_minor <= 10**15:
                return False
        if line.unsplit_batch_count is not None and line.unsplit_batch_count <= 0:
            return False
    return line.charges_minor is None or 0 < line.charges_minor <= 10**15


ours = st.sampled_from(["RMT0000000000A1", "SWP0000000000A2", "RFD0000000000A3", "TOP0000000000A4"])


@st.composite
def unsplit_entries(draw: st.DrawFn) -> Entry:
    n = draw(st.integers(1, 4))
    txs = tuple(
        Tx(
            draw(st.one_of(st.none(), st.integers(1, 90000))),
            ref=f"T{i}",
            end_to_end_id=draw(st.one_of(ours, st.just(f"E2E-{i}"))),
        )
        for i in range(n)
    )
    amount = draw(st.integers(1, 400000))
    nb = draw(st.one_of(st.none(), st.integers(1, 6)))
    return Entry(
        amount, draw(st.booleans()), START, ref="N1", code="PMNT/ICDT/ESCT", txs=txs, batch_count=nb
    )


@settings(max_examples=150, suppress_health_check=[HealthCheck.function_scoped_fixture])
@given(st.lists(unsplit_entries(), min_size=1, max_size=4), st.sampled_from(["02", "08"]))
def test_every_line_the_parser_returns_has_the_shape_the_import_checks(
    tmp_path: Path, entries: list[Entry], version: str
) -> None:
    """Parity with the ingest's shape check, over entries of every shape (split or kept unsplit,
    with details of ours or not, with or without amounts and NbOfTxs), and over the generator's
    statements."""
    distinct = [
        replace(e, ref=f"N{i}", txs=tuple(replace(t, ref=f"T{i}-{k}") for k, t in enumerate(e.txs)))
        for i, e in enumerate(entries)
    ]
    doc = make_doc(distinct, iban=IBAN, from_date=START, to_date=START, opening_minor=10**9)
    for line in _parse(tmp_path, render_camt053(doc, version)).lines:
        assert _ingest_accepts(line), line
    generated = generate_entries(300, seed=7, start=START, days=1)
    doc = make_doc(generated, iban=IBAN, from_date=START, to_date=START, opening_minor=10**9)
    assert all(_ingest_accepts(x) for x in _parse(tmp_path, render_camt053(doc, version)).lines)
