"""Synthetic bank statements of a client-funds account: camt.053 (.001.02 / .001.08) and the
documented CSV (M2-07; founder decision #19: synthetic files only until anonymised real exports
arrive).

A statement is a model (`Doc` > `Stmt` > `Entry` > `Tx`), rendered to XML or CSV. `expected_lines`
is the ground truth a parser must return, line by line; the manifest written next to a file
carries it (amounts in minor units, as text). The mix covers what French banks send: structured
RF references, RF references typed in the free text (spaces, lower case, split lines), invoice
numbers, free text, batch bookings (with details that add up, without details, or not adding up),
returns (AC04, MD06, MS03, reversal indicator), bank fees, our own refunds (RFD…), pending
entries, NOTPROVIDED end-to-end ids, ultimate debtors, and identical twins without references.
Every name, IBAN and reference is synthetic (Faker fr_FR, valid check digits, random digits).
"""

from __future__ import annotations

import json
import random
from collections.abc import Iterable, Sequence
from dataclasses import asdict, dataclass, field, replace
from datetime import date, timedelta
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape, quoteattr

from faker import Faker

from collectoo_worker.payments.rf import rf_format, rf_make
from collectoo_worker.payments.statement import classify, minor_to_iso
from collectoo_worker.synth.ids import iban_fr

RETURN_REASONS = ("AC04", "MD06", "MS03")


@dataclass(frozen=True)
class Tx:
    amount_minor: int | None  # None: the details carry no amount
    ref: str | None = None  # TxDtls/Refs/AcctSvcrRef
    end_to_end_id: str | None = None  # None -> NOTPROVIDED
    tx_id: str | None = None
    mandate_ref: str | None = None
    name: str | None = None  # the debtor of a credit, the creditor of a debit
    iban: str | None = None
    ultimate_name: str | None = None
    ustrd: tuple[str, ...] = ()
    creditor_ref: str | None = None
    return_reason: str | None = None


@dataclass(frozen=True)
class Entry:
    amount_minor: int
    credit: bool
    booking_date: date
    value_date: date | None = None
    status: str = "BOOK"
    reversal: bool = False
    ref: str | None = None  # Ntry/AcctSvcrRef
    code: str | None = "PMNT/RCDT/ESCT"
    txs: tuple[Tx, ...] = ()
    batch_count: int | None = None  # NtryDtls/Btch/NbOfTxs
    info: str | None = None  # AddtlNtryInf

    @property
    def signed(self) -> int:
        return self.amount_minor if self.credit else -self.amount_minor

    def adds_up(self) -> bool:
        """The details can be split into lines (design §8.3: Σ TxAmt = Ntry/Amt)."""
        if not self.txs:
            return not (self.batch_count or 0) > 1
        if self.batch_count and self.batch_count != len(self.txs):
            return False
        if len(self.txs) == 1:  # one transaction: the booked amount
            return True
        amounts = [t.amount_minor for t in self.txs]
        return (
            None not in amounts
            and 0 not in amounts
            and sum(a or 0 for a in amounts) == self.amount_minor
        )


@dataclass(frozen=True)
class Stmt:
    stmt_id: str
    seq: int | None
    iban: str
    currency: str
    from_date: date
    to_date: date
    opening_minor: int
    entries: tuple[Entry, ...]

    @property
    def closing_minor(self) -> int:
        return self.opening_minor + sum(e.signed for e in self.entries if e.status == "BOOK")


@dataclass(frozen=True)
class Doc:
    msg_id: str
    created: str  # ISO date-time
    statements: tuple[Stmt, ...]


@dataclass(frozen=True)
class Expected:
    """What a parser must return for one line (the ground truth of the manifest)."""

    section_no: int
    direction: str
    amount_minor: int
    booking_date: date
    value_date: date | None
    kind: str
    key_prefix: str  # t | e | h
    bank_ref: str | None  # what a CSV export prints in its reference column
    end_to_end_id: str | None
    creditor_reference: str | None
    counterparty_name: str | None
    counterparty_iban: str | None
    remittance_text: str | None
    return_reason: str | None = None


# -- generation -------------------------------------------------------------------------------

SCENARIOS: tuple[tuple[str, float], ...] = (
    ("rf_structured", 0.42),
    ("rf_text", 0.24),
    ("invoice_text", 0.14),
    ("free_text", 0.07),
    ("no_details", 0.02),
    ("batch", 0.025),
    ("batch_no_details", 0.004),
    ("batch_mismatch", 0.004),
    ("return", 0.02),
    ("fee", 0.008),
    ("refund_out", 0.005),
    ("pending", 0.005),
    ("twin", 0.006),
)


@dataclass
class _Gen:
    rng: random.Random
    references: Sequence[str]
    payers: list[tuple[str, str]]
    next_ref: int = 0
    log: list[str] = field(default_factory=list)

    def ref(self, prefix: str) -> str:
        self.next_ref += 1
        return f"{prefix}{self.next_ref:012d}"

    def rf(self) -> str:
        if self.references:
            return self.rng.choice(self.references)
        return rf_make(f"{self.rng.randrange(10**12):012d}")

    def payer(self) -> tuple[str, str]:
        return self.rng.choice(self.payers)

    def amount(self) -> int:
        """Between 10.00 and about 5,000.00 euros, mostly small (minor units)."""
        return int(1000 + self.rng.paretovariate(1.6) * 4000) % 500_000 + 1000

    def e2e(self) -> str | None:
        return None if self.rng.random() < 0.3 else self.ref("E2E")


def _payers(fake: Faker, rng: random.Random, n: int) -> list[tuple[str, str]]:
    out = []
    for _ in range(n):
        name = fake.company() if rng.random() < 0.6 else fake.name()
        out.append((name.upper() if rng.random() < 0.5 else name, iban_fr(rng)))
    return out


def _rf_in_text(g: _Gen, rf: str) -> tuple[str, ...]:
    style = g.rng.randrange(4)
    if style == 0:
        return (f"REGLT {rf_format(rf)}",)
    if style == 1:
        return (f"paiement {rf.lower()}",)
    if style == 2:
        grouped = rf_format(rf)
        return (f"VIR {grouped[:9]}", grouped[10:])  # split over two Ustrd lines
    return (f"Ref {rf} merci",)


def _credit_tx(g: _Gen, scenario: str, amount: int | None, *, tx_ref: bool = True) -> Tx:
    name, iban = g.payer()
    invoice = f"FA-2026-{g.rng.randrange(100000):05d}"
    ustrd: tuple[str, ...]
    creditor_ref = None
    if scenario == "rf_structured":
        creditor_ref = g.rf()
        ustrd = (f"Facture {invoice}",) if g.rng.random() < 0.5 else ()
    elif scenario == "rf_text":
        ustrd = _rf_in_text(g, g.rf())
    elif scenario == "invoice_text":
        ustrd = (f"REGLT FACT {invoice}",)
    else:
        ustrd = (g.rng.choice(("VIREMENT", "Remboursement", "Paiement dossier", "Solde")),)
    return Tx(
        amount_minor=amount,
        ref=g.ref("TX") if tx_ref else None,
        end_to_end_id=g.e2e(),
        tx_id=g.ref("TXID") if g.rng.random() < 0.5 else None,
        name=name,
        iban=iban,
        ultimate_name=g.payer()[0] if g.rng.random() < 0.05 else None,
        ustrd=ustrd,
        creditor_ref=creditor_ref,
    )


def _entries_for(g: _Gen, scenario: str, day: date) -> list[Entry]:  # noqa: PLR0911 - one per scenario
    rng = g.rng
    value = day + timedelta(days=rng.choice((0, 0, 0, 1)))

    def entry(amount: int, credit: bool, **kw: Any) -> Entry:
        return Entry(amount, credit, day, value, **kw)

    if scenario in ("rf_structured", "rf_text", "invoice_text", "free_text"):
        amount = g.amount()
        own_ref = rng.random() < 0.8  # else only the entry's reference (e: keys)
        tx = _credit_tx(g, scenario, amount if rng.random() < 0.9 else None, tx_ref=own_ref)
        return [entry(amount, True, ref=g.ref("NTRY"), txs=(tx,))]
    if scenario == "no_details":
        name = g.payer()[0]
        return [entry(g.amount(), True, ref=g.ref("NTRY"), info=f"VIR SEPA RECU {name}")]
    if scenario in ("batch", "batch_mismatch"):
        txs = tuple(_credit_tx(g, "rf_structured", g.amount()) for _ in range(rng.randint(2, 4)))
        total = sum(t.amount_minor or 0 for t in txs) + (100 if scenario == "batch_mismatch" else 0)
        return [
            entry(
                total,
                True,
                ref=g.ref("NTRY"),
                txs=txs,
                batch_count=len(txs),
                info="REMISE VIREMENTS",
            )
        ]
    if scenario == "batch_no_details":
        n = rng.randint(2, 6)
        return [
            entry(
                sum(g.amount() for _ in range(n)),
                True,
                ref=g.ref("NTRY"),
                batch_count=n,
                info=f"LOT {n} VIREMENTS RECUS",
            )
        ]
    if scenario == "return":
        name, iban = g.payer()
        reason = rng.choice(RETURN_REASONS)
        code = rng.choice(("PMNT/RDDT/UPDD", "PMNT/RCDT/RRTN"))
        tx = Tx(
            g.amount(),
            ref=g.ref("TX"),
            end_to_end_id=g.ref("E2E"),
            name=name,
            iban=iban,
            ustrd=(f"RETOUR {reason}",),
            return_reason=reason,
        )
        return [
            entry(
                tx.amount_minor or 0, False, reversal=True, ref=g.ref("NTRY"), code=code, txs=(tx,)
            )
        ]
    if scenario == "fee":
        fee = rng.choice((150, 290, 1200))
        return [
            entry(
                fee, False, ref=g.ref("NTRY"), code="PMNT/MDOP/FEES", info="FRAIS TENUE DE COMPTE"
            )
        ]
    if scenario == "refund_out":
        name, iban = g.payer()
        refund_id = f"RFD{rng.randrange(36**5):05X}"
        tx = Tx(
            g.amount(),
            ref=g.ref("TX"),
            end_to_end_id=refund_id,
            name=name,
            iban=iban,
            ustrd=("REMBOURSEMENT TROP PERCU",),
        )
        return [
            entry(tx.amount_minor or 0, False, ref=g.ref("NTRY"), code="PMNT/ICDT/ESCT", txs=(tx,))
        ]
    if scenario == "pending":
        tx = _credit_tx(g, "rf_structured", None)
        return [entry(g.amount(), True, status="PDNG", ref=g.ref("NTRY"), txs=(tx,))]
    # twin: two identical transfers on one day, without any bank reference (h: keys #1 and #2)
    name, iban = g.payer()
    tx = Tx(5000, name=name, iban=iban, ustrd=("COTISATION",))
    twin = entry(5000, True, txs=(tx,))
    return [twin, twin]


def generate_entries(  # noqa: PLR0913 - explicit generation parameters read best here
    lines: int,
    *,
    seed: int = 1,
    start: date,
    days: int = 5,
    references: Sequence[str] = (),
    payers: int = 2000,
) -> list[Entry]:
    """About `lines` statement lines (as parsed) spread over `days` booking days."""
    rng = random.Random(seed)
    fake = Faker("fr_FR")
    fake.seed_instance(seed)
    g = _Gen(rng, references, _payers(fake, rng, max(1, min(payers, lines))))
    names, weights = zip(*SCENARIOS, strict=True)
    entries: list[Entry] = []
    produced = 0
    while produced < lines:
        day = start + timedelta(days=min(days - 1, produced * days // max(lines, 1)))
        for e in _entries_for(g, rng.choices(names, weights)[0], day):
            entries.append(e)
            if e.status == "BOOK":
                produced += len(e.txs) if e.txs and e.adds_up() else 1
    return entries


def make_doc(  # noqa: PLR0913 - the statement's identity
    entries: Iterable[Entry],
    *,
    iban: str,
    currency: str = "EUR",
    from_date: date,
    to_date: date,
    opening_minor: int = 0,
    stmt_id: str = "STMT-1",
    seq: int | None = 1,
) -> Doc:
    """One <Stmt> with the entries booked between the dates."""
    chosen = tuple(e for e in entries if from_date <= e.booking_date <= to_date)
    stmt = Stmt(stmt_id, seq, iban, currency, from_date, to_date, opening_minor, chosen)
    return Doc(f"MSG-{stmt_id}", f"{to_date.isoformat()}T20:00:00", (stmt,))


def balance_before(entries: Iterable[Entry], day: date, opening_minor: int = 0) -> int:
    return opening_minor + sum(
        e.signed for e in entries if e.status == "BOOK" and e.booking_date < day
    )


# -- ground truth -------------------------------------------------------------------------------


def _sub_family(code: str | None) -> str | None:
    parts = (code or "").split("/")
    return parts[2] if len(parts) > 2 else None


def expected_lines(doc: Doc) -> list[Expected]:
    out: list[Expected] = []
    for section_no, st in enumerate(doc.statements, start=1):
        for e in st.entries:
            if e.status != "BOOK":
                continue
            direction = "credit" if e.credit else "debit"
            if not e.adds_up() or not e.txs:
                one = e.txs[0] if len(e.txs) == 1 else Tx(None)
                kind = (
                    "batch_unsplit"
                    if not e.adds_up()
                    else classify(
                        direction,
                        reversal=e.reversal,
                        return_reason=None,
                        sub_family=_sub_family(e.code),
                        end_to_end_id=None,
                    )
                )
                out.append(
                    Expected(
                        section_no,
                        direction,
                        e.amount_minor,
                        e.booking_date,
                        e.value_date,
                        kind,
                        "e" if e.ref else "h",
                        f"{e.ref}-0" if e.ref else None,
                        one.end_to_end_id,
                        one.creditor_ref,
                        one.name,
                        one.iban,
                        "\n".join(one.ustrd) or e.info,
                    )
                )
                continue
            refs = [t.ref for t in e.txs]
            own = None not in refs and len(set(refs)) == len(refs)
            for i, t in enumerate(e.txs, start=1):
                amount = e.amount_minor if len(e.txs) == 1 else (t.amount_minor or 0)
                kind = classify(
                    direction,
                    reversal=e.reversal,
                    return_reason=t.return_reason,
                    sub_family=_sub_family(e.code),
                    end_to_end_id=t.end_to_end_id,
                )
                prefix = "t" if own else ("e" if e.ref else "h")
                bank_ref = t.ref if own else (f"{e.ref}-{i}" if e.ref else None)
                remittance = "\n".join(t.ustrd) or (e.info if i == 1 else None)
                out.append(
                    Expected(
                        section_no,
                        direction,
                        amount,
                        e.booking_date,
                        e.value_date,
                        kind,
                        prefix,
                        bank_ref,
                        t.end_to_end_id,
                        t.creditor_ref,
                        t.name,
                        t.iban,
                        remittance,
                        t.return_reason,
                    )
                )
    return out


# -- camt.053 ------------------------------------------------------------------------------------


def _amt(minor: int, currency: str) -> str:
    return f"<Amt Ccy={quoteattr(currency)}>{minor_to_iso(minor, 2)}</Amt>"


def _text(tag: str, value: str | None) -> str:
    return "" if value is None else f"<{tag}>{escape(value)}</{tag}>"


def _code(code: str | None) -> str:
    if code is None:
        return ""
    d, f, s = [*code.split("/"), "", ""][:3]
    return (
        f"<BkTxCd><Domn><Cd>{d}</Cd><Fmly><Cd>{f}</Cd><SubFmlyCd>{s}</SubFmlyCd></Fmly>"
        "</Domn></BkTxCd>"
    )


def _party(tag: str, name: str | None, v08: bool) -> str:
    if name is None:
        return ""
    inner = f"<Nm>{escape(name)}</Nm>"
    return f"<{tag}>{f'<Pty>{inner}</Pty>' if v08 else inner}</{tag}>"


def _tx(t: Tx, e: Entry, currency: str, v08: bool) -> str:
    side = "Dbtr" if e.credit else "Cdtr"
    refs = (
        _text("AcctSvcrRef", t.ref)
        + _text("EndToEndId", t.end_to_end_id or "NOTPROVIDED")
        + _text("TxId", t.tx_id)
        + _text("MndtId", t.mandate_ref)
    )
    out = [f"<TxDtls><Refs>{refs}</Refs>"]
    if t.amount_minor is not None:
        if v08:
            out.append(_amt(t.amount_minor, currency))
            out.append(f"<CdtDbtInd>{'CRDT' if e.credit else 'DBIT'}</CdtDbtInd>")
        else:
            out.append(f"<AmtDtls><TxAmt>{_amt(t.amount_minor, currency)}</TxAmt></AmtDtls>")
    parties = _party(side, t.name, v08)
    if t.iban:
        parties += f"<{side}Acct><Id><IBAN>{t.iban}</IBAN></Id></{side}Acct>"
    parties += _party(f"Ultmt{side}", t.ultimate_name, v08)
    if parties:
        out.append(f"<RltdPties>{parties}</RltdPties>")
    remittance = "".join(_text("Ustrd", u) for u in t.ustrd)
    if t.creditor_ref:
        remittance += (
            "<Strd><CdtrRefInf><Tp><CdOrPrtry><Cd>SCOR</Cd></CdOrPrtry></Tp>"
            f"<Ref>{t.creditor_ref}</Ref></CdtrRefInf></Strd>"
        )
    if remittance:
        out.append(f"<RmtInf>{remittance}</RmtInf>")
    if t.return_reason:
        out.append(f"<RtrInf><Rsn><Cd>{t.return_reason}</Cd></Rsn></RtrInf>")
    out.append("</TxDtls>")
    return "".join(out)


def _entry(e: Entry, currency: str, v08: bool) -> str:
    status = f"<Sts><Cd>{e.status}</Cd></Sts>" if v08 else f"<Sts>{e.status}</Sts>"
    out = [
        "<Ntry>",
        _amt(e.amount_minor, currency),
        f"<CdtDbtInd>{'CRDT' if e.credit else 'DBIT'}</CdtDbtInd>",
        "<RvslInd>true</RvslInd>" if e.reversal else "",
        status,
        f"<BookgDt><Dt>{e.booking_date.isoformat()}</Dt></BookgDt>",
        f"<ValDt><Dt>{e.value_date.isoformat()}</Dt></ValDt>" if e.value_date else "",
        _text("AcctSvcrRef", e.ref),
        _code(e.code),
    ]
    if e.txs or e.batch_count:
        batch = f"<Btch><NbOfTxs>{e.batch_count}</NbOfTxs></Btch>" if e.batch_count else ""
        out.append(
            f"<NtryDtls>{batch}{''.join(_tx(t, e, currency, v08) for t in e.txs)}</NtryDtls>"
        )
    out.append(_text("AddtlNtryInf", e.info))
    out.append("</Ntry>")
    return "".join(out)


def _balance(code: str, minor: int, currency: str, day: date) -> str:
    side = "CRDT" if minor >= 0 else "DBIT"
    return (
        f"<Bal><Tp><CdOrPrtry><Cd>{code}</Cd></CdOrPrtry></Tp>{_amt(abs(minor), currency)}"
        f"<CdtDbtInd>{side}</CdtDbtInd><Dt><Dt>{day.isoformat()}</Dt></Dt></Bal>"
    )


def render_camt053(doc: Doc, version: str = "02") -> bytes:
    """camt.053.001.<version> XML (UTF-8). Version 08 uses its own shapes (Sts/Cd, Pty/Nm, Amt)."""
    v08 = int(version) >= 8
    ns = f"urn:iso:std:iso:20022:tech:xsd:camt.053.001.{version}"
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        f'<Document xmlns="{ns}"><BkToCstmrStmt>',
        f"<GrpHdr><MsgId>{escape(doc.msg_id)}</MsgId><CreDtTm>{doc.created}</CreDtTm></GrpHdr>",
    ]
    for st in doc.statements:
        out.append(f"<Stmt><Id>{escape(st.stmt_id)}</Id>")
        if st.seq is not None:
            out.append(f"<ElctrncSeqNb>{st.seq}</ElctrncSeqNb>")
        out.append(f"<CreDtTm>{doc.created}</CreDtTm>")
        out.append(
            f"<FrToDt><FrDtTm>{st.from_date.isoformat()}T00:00:00</FrDtTm>"
            f"<ToDtTm>{st.to_date.isoformat()}T23:59:59</ToDtTm></FrToDt>"
        )
        out.append(f"<Acct><Id><IBAN>{st.iban}</IBAN></Id><Ccy>{st.currency}</Ccy></Acct>")
        out.append(_balance("OPBD", st.opening_minor, st.currency, st.from_date))
        out.append(_balance("CLBD", st.closing_minor, st.currency, st.to_date))
        out.extend(_entry(e, st.currency, v08) for e in st.entries)
        out.append("</Stmt>")
    out.append("</BkToCstmrStmt></Document>\n")
    return "".join(out).encode("utf-8")


# -- CSV ------------------------------------------------------------------------------------------


def _fr_amount(minor: int, rng: random.Random) -> str:
    units, cents = divmod(minor, 100)
    grouped = f"{units:,}".replace(",", rng.choice((" ", "\u00a0", ".")))
    return f"{grouped},{cents:02d}"


def _label(x: Expected) -> str:
    ref = x.creditor_reference or x.end_to_end_id
    text = " ".join((x.remittance_text or "").split())
    if x.kind == "return":
        head = "RETOUR VIR SEPA"
    elif x.kind == "refund_out":
        head = "VIR SEPA EMIS"
    elif x.kind == "other_debit":
        return text or "FRAIS BANCAIRES"
    else:
        head = "VIR SEPA RECU"
    label = head + (f" /DE {x.counterparty_name}" if x.counterparty_name else "")
    label += f" /MOTIF {text}" if text else ""
    return label + (f" /REF {ref}" if ref else "")


def render_bank_csv(
    lines: Sequence[Expected], *, seed: int = 1, signed: bool = False, bank_ids: bool = True
) -> bytes:
    """The documented CSV (semicolons, French dates and amounts, Windows-1252 like most French
    bank exports). `signed`: one Montant column, else Débit and Crédit columns."""
    rng = random.Random(seed)
    head = ["Date opération", "Date de valeur", "Libellé"]
    head += ["Montant"] if signed else ["Débit", "Crédit"]
    head += ["Référence opération"] if bank_ids else []
    rows = [";".join(head)]
    for x in lines:
        amount = _fr_amount(x.amount_minor, rng)
        if signed:
            money = [("-" if x.direction == "debit" else "") + amount]
        else:
            money = [amount, ""] if x.direction == "debit" else ["", amount]
        value = x.value_date.strftime("%d/%m/%Y") if x.value_date else ""
        cells = [x.booking_date.strftime("%d/%m/%Y"), value, _label(x).replace(";", ","), *money]
        cells += [x.bank_ref or ""] if bank_ids else []
        rows.append(";".join(cells))
    return ("\r\n".join(rows) + "\r\n").encode("cp1252", errors="replace")


def _csv_kind(x: Expected) -> str:
    """A CSV row is one line: a batch is just a credit (or a debit) there."""
    if x.kind != "batch_unsplit":
        return x.kind
    return "debtor_credit" if x.direction == "credit" else "other_debit"


def expected_csv(lines: Sequence[Expected], *, bank_ids: bool = True) -> list[Expected]:
    """What the CSV parser returns for a CSV rendered from these lines (labels lose structure)."""
    out = []
    for x in lines:
        label = _label(x).replace(";", ",")
        ref = x.creditor_reference or x.end_to_end_id
        remittance = " ".join(label.split())
        out.append(
            replace(
                x,
                section_no=0,
                key_prefix="c" if bank_ids and x.bank_ref else "h",
                bank_ref=x.bank_ref if bank_ids else None,
                end_to_end_id=None if ref is None or x.creditor_reference else ref,
                counterparty_iban=None,
                remittance_text=remittance,
                return_reason=None,
                kind=_csv_kind(x),
                counterparty_name=x.counterparty_name if x.kind != "other_debit" else None,
            )
        )
    return out


# -- files ---------------------------------------------------------------------------------------


def manifest(doc: Doc, lines: Sequence[Expected]) -> dict[str, Any]:
    def row(x: Expected) -> dict[str, Any]:
        d = asdict(x)
        d["amount_minor"] = str(x.amount_minor)
        d["booking_date"] = x.booking_date.isoformat()
        d["value_date"] = x.value_date.isoformat() if x.value_date else None
        return d

    kinds: dict[str, int] = {}
    for x in lines:
        kinds[x.kind] = kinds.get(x.kind, 0) + 1
    return {
        "statements": [
            {
                "stmt_id": s.stmt_id,
                "from": s.from_date.isoformat(),
                "to": s.to_date.isoformat(),
                "opening_minor": str(s.opening_minor),
                "closing_minor": str(s.closing_minor),
                "pending": sum(1 for e in s.entries if e.status != "BOOK"),
            }
            for s in doc.statements
        ],
        "kinds": kinds,
        "lines": [row(x) for x in lines],
    }


def write_statement(
    doc: Doc, out: Path, name: str, *, version: str = "02", csv: bool = False
) -> list[Path]:
    """Write the camt.053 file (or the CSV export) and its manifest; returns the paths."""
    out.mkdir(parents=True, exist_ok=True)
    lines = expected_lines(doc)
    if csv:
        path = out / f"{name}.csv"
        path.write_bytes(render_bank_csv(lines))
        lines = expected_csv(lines)
    else:
        path = out / f"{name}.xml"
        path.write_bytes(render_camt053(doc, version))
    meta = out / f"{name}.manifest.json"
    meta.write_text(json.dumps(manifest(doc, lines), indent=1, ensure_ascii=False), "utf-8")
    return [path, meta]
