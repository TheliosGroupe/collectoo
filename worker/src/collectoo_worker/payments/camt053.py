"""camt.053 bank statements (ISO 20022 BankToCustomerStatement), versions .001.02 to .001.13 read
by local name (M2-07, design §8.3).

What is read, per <Stmt>: Id, ElctrncSeqNb, CreDtTm (GrpHdr/CreDtTm when a <Stmt> has none), FrToDt,
Acct/Id/IBAN and Ccy (must be the selected client-funds account), the opening (OPBD, else PRCD) and
closing (CLBD) booked balances. FrToDt is read in Paris time (its offset, else Paris; a bound
written as a date only is its midnight) and conservatively (M2c-6a review rounds 3 and 4, E4, G3):
the period (from_date … to_date) runs from FrDtTm's day to ToDtTm's, a ToDtTm at midnight on a
later date than the start ending it the day before; the days it shows whole (covers_from …
covers_to, none when it shows part of a day only) start the day after FrDtTm unless that is at
00:00:00 and end the day before ToDtTm unless that is at 23:59:59 or later. Without FrToDt the
period starts at the closing balance's date — the day after the opening balance's when that one is
a PRCD or dated before the closing — and ends at the closing balance's date. CreDtTm is kept, with
its offset (Paris time when it has none): a day counts as covered only by a statement the bank
produced after it. Per
<Ntry> booked (Sts BOOK; PDNG and INFO are counted and skipped): Amt, CdtDbtInd, RvslInd,
BookgDt, ValDt, AcctSvcrRef, BkTxCd, AddtlNtryInf. Per <TxDtls>: Refs (AcctSvcrRef, EndToEndId
with NOTPROVIDED read as none, TxId, MndtId), the amount (TxDtls/Amt, or AmtDtls/TxAmt/Amt in .02),
debtor or creditor name (Nm, or Pty/Nm from .08 on) and IBAN, ultimate party, every Ustrd,
Strd/CdtrRefInf/Ref, RtrInf/Rsn.

A batch booking becomes one line per TxDtls when the details add up to the entry (same currency
and direction, as many as NbOfTxs says); otherwise one line of kind `batch_unsplit` with the
booked amount (a credit is still one payment; ops split it across files), or `return` when the
entry or any of its details undoes an earlier movement. A single TxDtls takes the booked amount.
Zero amounts move nothing and are skipped. The file is refused unless, per <Stmt>, opening +
credits - debits = closing; nothing is written then.

Keys (design §8.3 step 4): `t:<TxDtls ref>` when every detail of the entry has its own; else
`e:<Ntry ref>#<n>`, n from 1 (an entry kept as one line is `#1`, with or without one detail); else
an `h:` fingerprint. Every line carries its entry's reference (`entry_ref`): the import refuses a
known entry that comes back split another way.

Safety: a file that declares a DTD is refused before parsing (no entity can be defined); lxml
parses with entity resolution, DTD loading and network access off and its default limits (no
huge tree); only <Ntry> and <Stmt> are handed to Python and each is cleared once read, so memory
stays flat for 100k-line statements.
"""

from __future__ import annotations

import codecs
import re
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from lxml import etree

from collectoo_worker.payments.rf import rf_normalise
from collectoo_worker.payments.statement import (
    METHOD_BY_FAMILY,
    NO_IBANS,
    RETURN_SUBFAMILIES,
    DedupKeys,
    KnownIbans,
    ParsedStatement,
    Section,
    StatementLine,
    StatementRejected,
    check_balanced,
    check_dates,
    classify,
    iso_to_minor,
)

NS_RE = re.compile(rb"urn:iso:std:iso:20022:tech:xsd:camt\.053\.001\.([0-9]{2})")
# xs:date: a date, then an optional time zone (hours 00 to 14, 14:00 at most)
ISO_DATE_RE = re.compile(
    r"([0-9]{4}-[0-9]{2}-[0-9]{2})(?:Z|[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00))?"
)
# xs:dateTime: a date, a time (optional fraction), then an optional time zone
ISO_DATETIME_RE = re.compile(
    r"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?"
    r"(Z|[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00))?"
)
MIDNIGHT = time(0)  # a period bound at the start of its day
END_OF_DAY = time(23, 59, 59)  # a period bound at the end of its day (or later)
PARIS = ZoneInfo("Europe/Paris")  # a bank's local time when a date-time has no offset
HEAD_BYTES = 64 * 1024
MAX_LINES = 250_000  # the same cap as the CSV reader: a longer statement is exported in parts
NOT_PROVIDED = "NOTPROVIDED"
DIRECTIONS = {"CRDT": "credit", "DBIT": "debit"}

Element = etree._Element
Flat = dict[str, list[str]]


def first(flat: Flat, path: str) -> str | None:
    values = flat.get(path)
    return values[0] if values else None


def check_prolog(head: bytes) -> None:
    """Everything before the root element: an optional XML declaration, comments and processing
    instructions. A DTD (or anything else starting with `<!`) is refused: no entity can exist."""
    if head.startswith(
        (codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE, codecs.BOM_UTF32_LE, codecs.BOM_UTF32_BE)
    ):
        raise StatementRejected("xml_encoding", "camt.053 files are UTF-8")
    i = len(codecs.BOM_UTF8) if head.startswith(codecs.BOM_UTF8) else 0
    n = len(head)
    while True:
        while i < n and head[i : i + 1] in (b" ", b"\t", b"\r", b"\n"):
            i += 1
        if i >= n:
            raise StatementRejected("not_camt053", "no XML element at the start of the file")
        if head.startswith(b"<!--", i):
            end = head.find(b"-->", i + 4)
            if end < 0:
                raise StatementRejected("xml_invalid", "unterminated comment before the root")
            i = end + 3
        elif head.startswith(b"<?", i):
            end = head.find(b"?>", i + 2)
            if end < 0:
                raise StatementRejected("xml_invalid", "unterminated declaration before the root")
            i = end + 2
        elif head.startswith(b"<!", i):
            raise StatementRejected("xml_dtd_refused", "a document type declaration is refused")
        elif head.startswith(b"<", i):
            return
        else:
            raise StatementRejected("xml_invalid", "text before the root element")


class _Ns:
    """Namespace-qualified paths of one camt.053 version (cached)."""

    def __init__(self, ns: str) -> None:
        self.ns = ns
        self._paths: dict[str, str] = {}
        self._local: dict[str, str] = {}

    def path(self, p: str) -> str:
        cached = self._paths.get(p)
        if cached is None:
            cached = "/".join(f"{{{self.ns}}}{part}" for part in p.split("/"))
            self._paths[p] = cached
        return cached

    def text(self, elem: Element, p: str) -> str | None:
        found = elem.find(self.path(p))
        if found is None or found.text is None:
            return None
        return found.text.strip() or None

    def texts(self, elem: Element, p: str) -> list[str]:
        return [t.text.strip() for t in elem.findall(self.path(p)) if t.text and t.text.strip()]

    def flat(self, elem: Element | None, skip: str = "") -> Flat:
        """Every leaf under `elem` by local path ("Refs/EndToEndId": [texts], in document order),
        plus the currency of each amount ("Amt@Ccy"): one pass instead of a lookup per field."""
        out: Flat = {}
        if elem is not None:
            self._walk(elem, "", skip, out)
        return out

    def _walk(self, elem: Element, prefix: str, skip: str, out: Flat) -> None:
        local = self._local
        for child in elem:
            tag = child.tag
            if not isinstance(tag, str):
                continue
            name = local.get(tag)
            if name is None:
                name = local[tag] = tag.rpartition("}")[2]
            if name == skip:
                continue
            path = prefix + name
            if len(child):
                self._walk(child, path + "/", "", out)
                continue
            text = (child.text or "").strip()
            if text:
                out.setdefault(path, []).append(text)
            if name == "Amt":
                out.setdefault(path + "@Ccy", []).append(child.get("Ccy") or "")


class _Reader:
    def __init__(  # noqa: PLR0913 - the version read and the bank account's settings
        self,
        ns: str,
        version: str,
        *,
        iban: str,
        currency: str,
        exponent: int,
        max_lines: int = MAX_LINES,
        ibans: KnownIbans = NO_IBANS,
    ) -> None:
        self.q = _Ns(ns)
        self.iban = iban
        self.ibans = ibans
        self.currency = currency
        self.exponent = exponent
        self.max_lines = max_lines
        self.out = ParsedStatement(format="camt053", currency=currency, version=version)
        self.keys = DedupKeys()
        self.section_open: Element | None = None  # the <Stmt> whose header was read
        self.header: _Header | None = None
        self.entry_no = 0
        self.group_created: datetime | None = None  # GrpHdr/CreDtTm (a <Stmt> without its own)

    # -- <GrpHdr> ----------------------------------------------------------------------------

    def group_header(self, header: Element) -> None:
        self.group_created = self.datetime(self.q.text(header, "CreDtTm"), "the group header")

    # -- <Stmt> ------------------------------------------------------------------------------

    def open_section(self, stmt: Element) -> None:
        q = self.q
        where = f"statement {len(self.out.sections) + 1}"
        account = q.text(stmt, "Acct/Id/IBAN")
        if account is None or rf_normalise(account) != self.iban:
            raise StatementRejected(
                "wrong_account", f"{where} is not for the selected bank account (IBAN)"
            )
        account_ccy = q.text(stmt, "Acct/Ccy")
        if account_ccy is not None and account_ccy != self.currency:
            raise StatementRejected("wrong_currency", f"{where} is in {account_ccy}")
        balances: dict[str, tuple[int, date | None]] = {}
        for bal in stmt.findall(q.path("Bal")):
            f = q.flat(bal)
            code = first(f, "Tp/CdOrPrtry/Cd") or first(f, "Tp/CdOrPrtry/Prtry") or ""
            amount = self.amount(f, "Amt", f"{where}, balance {code}")
            sign = -1 if first(f, "CdtDbtInd") == "DBIT" else 1
            balances.setdefault(code, (sign * amount, self.day(f, "Dt", where)))
        opening_code = "OPBD" if "OPBD" in balances else "PRCD"
        opening = balances.get("OPBD") or balances.get("PRCD")
        closing = balances.get("CLBD")
        if opening is None or closing is None:
            raise StatementRejected(
                "missing_balance", f"{where} has no opening (OPBD) or closing (CLBD) balance"
            )
        seq_text = q.text(stmt, "ElctrncSeqNb")
        # review round 4 (G3): the bounds in Paris time, and the days the period shows whole
        from_at = _bound(q.text(stmt, "FrToDt/FrDtTm"), where)
        to_at = _bound(q.text(stmt, "FrToDt/ToDtTm"), where)
        start: date | None
        whole_from: date | None
        if from_at is not None:
            start = from_at.date()
            whole_from = start if from_at.time() == MIDNIGHT else start + timedelta(days=1)
        else:
            start = whole_from = _start_without_period(opening[1], closing[1], opening_code)
        end: date | None
        whole_to: date | None
        if to_at is not None:
            end = to_at.date()
            # a period up to the next midnight is the days before it (review round 3, E4)
            if to_at.time() == MIDNIGHT and start is not None and end > start:
                end -= timedelta(days=1)
            whole_to = to_at.date() - timedelta(days=0 if to_at.time() >= END_OF_DAY else 1)
        else:
            end = whole_to = closing[1]
        self.header = _Header(
            stmt_id=q.text(stmt, "Id"),
            seq=int(seq_text) if seq_text and seq_text.isdigit() else None,
            start=start,
            end=end,
            opening=opening[0],
            closing=closing[0],
            created_at=self.datetime(q.text(stmt, "CreDtTm"), where) or self.group_created,
            whole_from=whole_from,
            whole_to=whole_to,
        )
        self.section_open = stmt
        self.entry_no = 0

    def close_section(self, stmt: Element) -> None:
        if self.section_open is not stmt:
            self.open_section(stmt)  # a statement without entries
        h = self.header
        if h is None:  # pragma: no cover - open_section just set it
            raise StatementRejected("not_camt053", "statement without a header")
        section_no = len(self.out.sections) + 1
        booked = [line.booking_date for line in self.out.lines if line.section_no == section_no]
        start = h.start or (min(booked) if booked else None)
        end = h.end or (max(booked) if booked else None)
        if start is None or end is None:
            raise StatementRejected("date_invalid", f"statement {section_no} has no dates")
        # the whole days (review round 4, G3): none known when the dates came from the lines, or
        # when the period shows part of a day only
        whole_from, whole_to = h.whole_from, h.whole_to
        if whole_from is None or whole_to is None or whole_from > whole_to:
            whole_from = whole_to = None
        section = Section(
            stmt_id=h.stmt_id,
            seq=h.seq,
            iban=self.iban,
            currency=self.currency,
            from_date=min(start, end),
            to_date=max(start, end),
            opening_minor=h.opening,
            closing_minor=h.closing,
            created_at=h.created_at,
            covers_from=whole_from,
            covers_to=whole_to,
        )
        check_balanced(section, self.out.lines, section_no)
        self.out.sections.append(section)
        self.section_open = None

    # -- <Ntry> ------------------------------------------------------------------------------

    def entry(self, ntry: Element) -> None:
        self.entry_no += 1
        section_no = len(self.out.sections) + 1
        where = f"statement {section_no}, entry {self.entry_no}"
        f = self.q.flat(ntry, skip="NtryDtls")
        status = first(f, "Sts/Cd") or first(f, "Sts")
        if status != "BOOK":
            self.out.skipped_not_booked += 1
            return
        amount = self.amount(f, "Amt", where)
        if amount == 0:  # moves nothing (information entry)
            self.out.skipped_not_booked += 1
            return
        direction = DIRECTIONS.get(first(f, "CdtDbtInd") or "")
        if direction is None:
            raise StatementRejected("line_invalid", f"{where}: CdtDbtInd is neither CRDT nor DBIT")
        booking = self.day(f, "BookgDt", where)
        if booking is None:
            raise StatementRejected("date_invalid", f"{where}: BookgDt missing")
        entry = _Entry(
            section_no=section_no,
            where=where,
            amount=amount,
            direction=direction,
            reversal=(first(f, "RvslInd") or "").lower() in ("true", "1"),  # xs:boolean
            booking=booking,
            value=self.day(f, "ValDt", where),
            ref=first(f, "AcctSvcrRef"),
            code=_code(f, "BkTxCd/"),
            info=first(f, "AddtlNtryInf"),
            payment_info_id=_max35(next(iter(self.q.texts(ntry, "NtryDtls/Btch/PmtInfId")), None)),
        )
        txs = [self.q.flat(tx) for tx in ntry.findall(self.q.path("NtryDtls/TxDtls"))]
        counts = self.q.texts(ntry, "NtryDtls/Btch/NbOfTxs")
        batch = max((int(c) for c in counts if c.isdigit()), default=0)
        parts = self.split(entry, txs)
        # A batch whose count disagrees with its details cannot be split safely. An entry kept as
        # one line is its line 1, as when one detail comes with it: the same entry keeps its key
        # whatever detail a file gives.
        if parts is None or (not txs and batch > 1) or (txs and batch and batch != len(txs)):
            single = txs[0] if len(txs) == 1 else {}
            self.add(entry, single, amount, 1, unsplit=True, batch=True, details=txs)
        elif not txs:
            self.add(entry, {}, amount, 1, unsplit=False, batch=False)
        else:
            refs = [first(tx, "Refs/AcctSvcrRef") for tx in txs]
            own_refs = None not in refs and len(set(refs)) == len(refs)
            for i, (tx, part) in enumerate(zip(txs, parts, strict=True), start=1):
                self.add(entry, tx, part, i, unsplit=False, batch=len(txs) > 1, own_ref=own_refs)

    def split(self, entry: _Entry, txs: list[Flat]) -> list[int] | None:
        """Amounts of the transactions, or None when they do not add up to the entry."""
        if not txs:
            return []
        if len(txs) == 1:  # what the bank booked (charges may differ from the instructed amount)
            return [entry.amount]
        parts: list[int] = []
        for tx in txs:
            path = "Amt" if "Amt" in tx else "AmtDtls/TxAmt/Amt"
            tx_dir = DIRECTIONS.get(first(tx, "CdtDbtInd") or "", entry.direction)
            if (
                path not in tx
                or first(tx, path + "@Ccy") != self.currency
                or tx_dir != entry.direction
            ):
                return None
            part = self.amount(tx, path, entry.where)
            if part == 0:
                return None
            parts.append(part)
        return parts if sum(parts) == entry.amount else None

    def add(  # noqa: PLR0913 - one line: its entry, its details and how it was split
        self,
        entry: _Entry,
        tx: Flat,
        amount: int,
        index: int,
        *,
        unsplit: bool,
        batch: bool,
        own_ref: bool = False,
        details: list[Flat] | None = None,
    ) -> None:
        """One line. `index` is 1-based within its entry; `details` are every TxDtls of an entry
        kept as one unsplit line (a return reason or sub-family in any of them counts)."""
        details = details or []
        credit = entry.direction == "credit"
        side, other = ("Dbtr", "Cdtr") if credit else ("Cdtr", "Dbtr")
        tx_ref = first(tx, "Refs/AcctSvcrRef")
        e2e = _provided(first(tx, "Refs/EndToEndId"))
        name = _party(tx, f"RltdPties/{side}")
        if name is None and not credit:
            name = _party(tx, f"RltdPties/{other}")
        iban = first(tx, f"RltdPties/{side}Acct/Id/IBAN")
        if iban is None and not credit:
            iban = first(tx, f"RltdPties/{other}Acct/Id/IBAN")
        remittance = (
            "\n".join(tx.get("RmtInf/Ustrd", ()))
            or first(tx, "AddtlTxInf")
            or (entry.info if index <= 1 else None)
        )
        creditor_ref = first(tx, "RmtInf/Strd/CdtrRefInf/Ref")
        return_reason = _return_reason(tx) or next(filter(None, map(_return_reason, details)), None)
        code = _code(tx, "BkTxCd/") or entry.code
        family, sub_family = _family(code)
        kind = classify(
            entry.direction,
            reversal=entry.reversal,
            return_reason=return_reason,
            sub_family=sub_family,
            end_to_end_id=e2e,
            counterparty_iban=rf_normalise(iban) if iban else None,
            ibans=self.ibans,
        )
        if unsplit:
            # A batch that cannot be split is still a return when the entry or any of its details
            # undoes an earlier movement (ADR-0013 M2b-2 #2): never a payment.
            undone = kind == "return" or any(
                _family(_code(d, "BkTxCd/"))[1] in RETURN_SUBFAMILIES for d in details
            )
            kind = "return" if undone else "batch_unsplit"
        if tx_ref is not None and own_ref and not unsplit:
            key = self.keys.claim(f"t:{tx_ref}")
        elif entry.ref is not None:
            key = self.keys.claim(f"e:{entry.ref}#{index}")
        else:
            key = self.keys.fingerprint(
                booking_date=entry.booking,
                value_date=entry.value,
                direction=entry.direction,
                amount_minor=amount,
                currency=self.currency,
                counterparty_iban=iban,
                end_to_end_id=e2e,
                remittance_text=remittance,
            )
        if len(self.out.lines) >= self.max_lines:  # checked while streaming: memory stays bounded
            raise StatementRejected(
                "file_too_large",
                f"{entry.where}: more than {self.max_lines} lines; export a shorter period",
            )
        self.out.lines.append(
            StatementLine(
                line_no=len(self.out.lines) + 1,
                section_no=entry.section_no,
                dedup_key=key,
                direction=entry.direction,
                amount_minor=amount,
                currency=self.currency,
                booking_date=entry.booking,
                value_date=entry.value,
                kind=kind,
                method=METHOD_BY_FAMILY.get(family or "", "other"),
                reversal_indicator=entry.reversal,
                bank_tx_code=code,
                acct_svcr_ref=tx_ref or entry.ref,
                end_to_end_id=e2e,
                tx_id=_provided(first(tx, "Refs/TxId")),
                mandate_ref=first(tx, "Refs/MndtId"),
                counterparty_name=name,
                ultimate_counterparty_name=_party(tx, f"RltdPties/Ultmt{side}"),
                counterparty_iban=rf_normalise(iban) if iban else None,
                remittance_text=remittance,
                creditor_reference=rf_normalise(creditor_ref) if creditor_ref else None,
                return_reason=return_reason,
                original_end_to_end_id=first(tx, "RtrInf/OrgnlEndToEndId")
                or (e2e if kind == "return" else None),
                batch_entry_ref=(entry.ref or entry.where) if batch else None,
                entry_ref=entry.ref,
                payment_info_id=entry.payment_info_id,
            )
        )

    # -- values ------------------------------------------------------------------------------

    def amount(self, f: Flat, path: str, where: str) -> int:
        text = first(f, path)
        if text is None:
            raise StatementRejected("amount_invalid", f"{where}: amount missing")
        currency = first(f, path + "@Ccy")
        if currency != self.currency:
            raise StatementRejected(
                "wrong_currency", f"{where}: amount in {currency}, not {self.currency}"
            )
        try:
            return iso_to_minor(text, self.exponent)
        except ValueError as exc:
            raise StatementRejected("amount_invalid", f"{where}: {exc}") from exc

    def day(self, f: Flat, path: str, where: str) -> date | None:
        text = first(f, f"{path}/Dt")
        if text is not None:
            return _iso_date(text, where)
        return self.datetime_date(first(f, f"{path}/DtTm"), where)

    @staticmethod
    def datetime_date(text: str | None, where: str) -> date | None:
        """The date as written (a bank's business date; no time zone conversion)."""
        return None if text is None else _iso_date(text[:10], where)

    @staticmethod
    def datetime(text: str | None, where: str) -> datetime | None:
        """An xs:dateTime as an aware datetime: its own offset, else Paris time (the bank's)."""
        return None if text is None else _iso_datetime(text, where)


@dataclass(frozen=True, slots=True)
class _Header:
    stmt_id: str | None
    seq: int | None
    start: date | None
    end: date | None
    opening: int
    closing: int
    created_at: datetime | None
    whole_from: date | None
    whole_to: date | None


@dataclass(frozen=True, slots=True, kw_only=True)
class _Entry:
    section_no: int
    where: str
    amount: int
    direction: str
    reversal: bool
    booking: date
    value: date | None
    ref: str | None
    code: str | None
    info: str | None
    payment_info_id: str | None = None  # NtryDtls/Btch/PmtInfId


MAX35 = 35  # ISO 20022 Max35Text


def _max35(text: str | None) -> str | None:
    """An ISO Max35Text kept as given (outside 1-35 characters it is not one: dropped)."""
    return text if text is not None and 1 <= len(text) <= MAX35 else None


def _provided(text: str | None) -> str | None:
    return None if text is None or text.upper() == NOT_PROVIDED else text


def _party(tx: Flat, base: str) -> str | None:
    return first(tx, f"{base}/Nm") or first(tx, f"{base}/Pty/Nm")


def _code(f: Flat, prefix: str) -> str | None:
    """ISO bank transaction code as DOMAIN/FAMILY/SUBFAMILY, or PRTRY:<code>."""
    domain = first(f, prefix + "Domn/Cd")
    if domain is not None:
        family = first(f, prefix + "Domn/Fmly/Cd") or ""
        return f"{domain}/{family}/{first(f, prefix + 'Domn/Fmly/SubFmlyCd') or ''}"
    proprietary = first(f, prefix + "Prtry/Cd")
    return f"PRTRY:{proprietary}" if proprietary else None


def _family(code: str | None) -> tuple[str | None, str | None]:
    """(family, sub-family) of an ISO bank transaction code `DOMAIN/FAMILY/SUBFAMILY`."""
    if code is None or code.startswith("PRTRY:"):
        return None, None
    parts = [*code.split("/"), "", ""]
    return parts[1] or None, parts[2] or None


def _return_reason(tx: Flat) -> str | None:
    return first(tx, "RtrInf/Rsn/Cd") or first(tx, "RtrInf/Rsn/Prtry")


def _iso_date(text: str, where: str) -> date:
    """ISODate is xs:date: YYYY-MM-DD with an optional time zone (Z, +hh:mm, -hh:mm). The business
    date is the date as written; the time zone is not applied."""
    found = ISO_DATE_RE.fullmatch(text)
    try:
        if found is None:
            raise ValueError(text)
        return date.fromisoformat(found.group(1))
    except ValueError as exc:
        raise StatementRejected("date_invalid", f"{where}: {text!r} is not a date") from exc


def _iso_datetime(text: str, where: str) -> datetime:
    """ISODateTime is xs:dateTime: YYYY-MM-DDThh:mm:ss, an optional fraction, an optional time zone
    (Z, +hh:mm, -hh:mm). Without one, the bank's local time (Paris). 24:00:00 is the end of its
    day: the next day's midnight."""
    found = ISO_DATETIME_RE.fullmatch(text)
    end_of_day = False
    try:
        if found is None:
            raise ValueError(text)
        base, fraction, zone = found.group(1), found.group(2) or "", found.group(3)
        offset = "" if zone is None else "+00:00" if zone == "Z" else zone
        end_of_day = base.endswith("T24:00:00") and fraction.strip(".0") == ""
        if end_of_day:
            base, fraction = base[:11] + "00:00:00", ""
        value = datetime.fromisoformat(base + fraction[:7] + offset)  # microseconds at most
    except ValueError as exc:
        raise StatementRejected("date_invalid", f"{where}: {text!r} is not a date-time") from exc
    if end_of_day:
        value += timedelta(days=1)
    return value if value.tzinfo is not None else value.replace(tzinfo=PARIS)


def _bound(text: str | None, where: str) -> datetime | None:
    """A FrToDt bound in Paris time (review round 4, G3): an xs:dateTime with its offset, else
    Paris; one written as a date only (not the schema's type, read as before) is its midnight."""
    if text is None:
        return None
    if ISO_DATE_RE.fullmatch(text):
        return datetime.combine(_iso_date(text, where), MIDNIGHT, tzinfo=PARIS)
    return _iso_datetime(text, where).astimezone(PARIS)


def _start_without_period(opening: date | None, closing: date | None, code: str) -> date | None:
    """Without FrToDt (review round 4, G3): the closing balance's date — the day after the opening
    balance's when that one is a PRCD (the previous day's closing) or is dated before the closing
    (it may be the previous evening's): the earliest day the statement can be said to show whole."""
    if opening is None:
        return closing
    if code == "PRCD" or (closing is not None and opening < closing):
        return opening + timedelta(days=1)
    return closing if closing is not None else opening


def _read(path: Path, ns: str, reader: _Reader) -> None:
    """Stream the file: only <GrpHdr>, <Ntry> and <Stmt> reach Python, each freed once read."""
    checked = False
    for _event, elem in etree.iterparse(
        str(path),
        events=("end",),
        tag=(f"{{{ns}}}GrpHdr", f"{{{ns}}}Ntry", f"{{{ns}}}Stmt"),
        resolve_entities=False,
        load_dtd=False,
        no_network=True,
        huge_tree=False,
        remove_comments=True,
        remove_pis=True,
    ):
        if not checked:
            tree = elem.getroottree()
            if tree.docinfo.doctype or tree.getroot().tag != f"{{{ns}}}Document":
                raise StatementRejected("not_camt053", "the root is not a camt.053 Document")
            checked = True
        parent = elem.getparent()
        if parent is None:  # pragma: no cover - GrpHdr, Ntry and Stmt always have a parent
            continue
        local = etree.QName(elem).localname
        if local == "GrpHdr":
            if parent.tag == f"{{{ns}}}BkToCstmrStmt":
                reader.group_header(elem)
        elif local == "Ntry":
            if parent.tag != f"{{{ns}}}Stmt":
                raise StatementRejected("not_camt053", "an entry (<Ntry>) outside a statement")
            if reader.section_open is not parent:
                reader.open_section(parent)
            reader.entry(elem)
        else:
            reader.close_section(elem)
        # Read: free it, and the siblings before it (the statement header was read already).
        elem.clear(keep_tail=False)
        while elem.getprevious() is not None:
            del parent[0]


def parse_camt053(  # noqa: PLR0913 - the bank account's settings and the reader's limits
    path: Path,
    *,
    iban: str,
    currency: str,
    exponent: int = 2,
    today: date | None = None,
    max_lines: int = MAX_LINES,
    ibans: KnownIbans = NO_IBANS,
) -> ParsedStatement:
    """Parse a camt.053 file for the given bank account (IBAN and currency), or refuse it
    (`file_too_large` beyond `max_lines` lines, while streaming). `ibans`: the servicer's own
    and its clients' IBANs, to recognise our own transfers (M2c)."""
    with path.open("rb") as fh:
        head = fh.read(HEAD_BYTES)
    check_prolog(head)
    found = NS_RE.search(head)
    if found is None:
        raise StatementRejected("not_camt053", "not a camt.053 (BankToCustomerStatement) file")
    version = found.group(1).decode("ascii")
    ns = found.group(0).decode("ascii")
    reader = _Reader(
        ns,
        version,
        iban=iban,
        currency=currency,
        exponent=exponent,
        max_lines=max_lines,
        ibans=ibans,
    )
    try:
        _read(path, ns, reader)
    except etree.XMLSyntaxError as exc:
        raise StatementRejected("xml_invalid", f"line {exc.lineno}: {exc.msg}") from exc
    if not reader.out.sections:
        raise StatementRejected("not_camt053", "the file contains no statement (<Stmt>)")
    if today is not None:
        check_dates(reader.out.lines, today)
    return reader.out
