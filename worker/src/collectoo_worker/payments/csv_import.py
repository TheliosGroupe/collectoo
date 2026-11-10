"""Manual CSV bank statements (M2-07, design §8.3 step 3).

The documented column set (docs/DOMAIN.md §3.5, « Relevé CSV »): headers are matched without case,
accents or punctuation, so « Date opération », « DATE OPERATION » and « date_operation » are one
column. Required: the booking date, the label, and either one signed amount column or a debit and
a credit column. Optional: value date, the bank's own operation id (exact dedup; only under an
unambiguous header such as « Référence opération »: a plain « Référence » may be the payer's and is
not trusted), counterparty name and IBAN, currency, creditor reference, end-to-end id. The header
row may follow a few preamble lines (account number, period). A bank account's `csv_profile` may
name its own headers ({"columns": {"booking_date": "Date opé"}, "decimal": ","}).

Formats: French dates (31/12/2026, 31-12-2026, 31.12.2026; ISO 2026-12-31 too) and French
amounts (1 234,56 · 1.234,56 · -50,00 · 50,00- · non-breaking spaces); more decimals than the
currency has are refused, never rounded. A Débit may be printed negative; a negative Crédit is
refused. The separator is sniffed as for boarding files.

What cannot be read one way only is refused before anything is written (DOMAIN §3.5): a file over
MAX_BYTES or MAX_LINES; a file that is neither UTF-8 (BOM optional) from its first byte to its
last, nor Windows-1252; a field that runs over a line break (an unclosed quote would swallow the
next rows); a row without the date, label or amount cells of its header, or with a non-empty cell
beyond it. Refusals name the line of the file as a text editor or a spreadsheet numbers it (header
and preamble included, from 1), and a CSV line's `line_no` is that same number.

The label parser reads the markers French banks print: « /DE <payer> /MOTIF <text> /REF <ref> ».
A line is a `return` only when the label starts with the bank's operation type saying so
(« RETOUR VIR SEPA », « REJET DE PRLV », « PRLV SEPA REJETE », « IMPAYE CHQ »): words the payer
wrote never turn a credit into a non-payment. A CSV export proves no balance: there is no
opening/closing check (the page says so); re-exported lines are caught by the bank id column when
there is one, and otherwise held as suspected duplicates by the import (SQL).
"""

from __future__ import annotations

import codecs
import csv
import re
import unicodedata
from collections.abc import Iterator, Mapping
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import TYPE_CHECKING, Any, NamedTuple

from collectoo_worker.boarding.readers import SAMPLE_BYTES, SEPARATORS, sniff_separator
from collectoo_worker.payments.rf import rf_normalise, rf_valid
from collectoo_worker.payments.statement import (
    NO_IBANS,
    DedupKeys,
    KnownIbans,
    ParsedStatement,
    StatementLine,
    StatementRejected,
    check_dates,
    classify,
    decimal_to_minor,
)

if TYPE_CHECKING:
    from _csv import Reader

# Caps, checked before parsing: the parsed lines are held in memory by the worker process that also
# runs boarding (about 0.7 KB per line: 250,000 synthetic lines peak at 236 MB, parsed in 6 s).
# 2.5 times the design's 100k-line target; 64 MiB is 250,000 lines of 256 bytes. A larger export
# is cut by period.
MAX_BYTES = 64 * 1024 * 1024
MAX_LINES = 250_000
READ_CHUNK = 1 << 20

# Field -> accepted headers (normalised: lower case, no accents, words separated by one space).
COLUMNS: Mapping[str, tuple[str, ...]] = {
    "booking_date": (
        "date de comptabilisation",
        "date comptable",
        "date operation",
        "date d operation",
        "date",
    ),
    "value_date": ("date valeur", "date de valeur"),
    "label": ("libelle", "libelle operation", "libelle de l operation", "description", "intitule"),
    "amount": ("montant", "montant eur", "montant en euros"),
    "debit": ("debit", "debit eur", "debit euros"),
    "credit": ("credit", "credit eur", "credit euros"),
    # The bank's own id of the line. A plain « Référence » may hold the payer's reference, which
    # repeats across payments and would hide a payment as "already imported": not accepted.
    "bank_id": (
        "reference operation",
        "reference de l operation",
        "reference banque",
        "ref banque",
        "id operation",
        "identifiant operation",
        "numero d operation",
    ),
    "counterparty_name": ("contrepartie", "nom contrepartie", "tiers", "emetteur beneficiaire"),
    "counterparty_iban": ("iban contrepartie", "iban"),
    "currency": ("devise",),
    "creditor_reference": ("reference creancier", "reference rf"),
    "end_to_end_id": ("reference de bout en bout", "end to end", "end to end id"),
}
# When a file has two headers of one field, the one listed here wins; two of the same rank are
# refused. The BPCE group's exports print « Date de comptabilisation » (the booking date) and
# « Date opération » (when the operation was made) side by side.
PREFERRED: Mapping[str, tuple[str, ...]] = {
    "booking_date": ("date de comptabilisation", "date comptable"),
}
MARKER_RE = re.compile(r"\s*/(DE|MOTIF|REF)\b\s*", re.IGNORECASE)
# A return as banks print it: the operation type at the very start of the label, with a return word
# before or after it (« RETOUR VIR SEPA », « REJET DE PRLV », « PRLV SEPA REJETE », « IMPAYE CHQ »).
# The payer's words come later in the label and are never read for this.
_RETURN_WORDS = "RETOUR|RETOURNE|REJET|REJETE|IMPAYE|ANNULATION"
_OPERATION_WORDS = "VIR|VIREMENT|PRLV|PRELEVEMENT|SEPA|CHQ|CHEQUE|REM|REMISE|CB|CARTE"
RETURN_RE = re.compile(
    rf"(?:(?:{_RETURN_WORDS})(?:\s+(?:DE|DU))?\s+(?:{_OPERATION_WORDS})"
    rf"|(?:{_OPERATION_WORDS})(?:\s+SEPA)?\s+(?:{_RETURN_WORDS}))\b"
)
DATE_FR_RE = re.compile(r"([0-9]{2})[/.-]([0-9]{2})[/.-]([0-9]{4})")
DATE_ISO_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
METHOD_PREFIXES = (
    (("VIR", "VIREMENT"), "sct"),
    (("PRLV", "PRELEVEMENT"), "sdd"),
    (("REM CHQ", "REMISE CHEQUE", "REMISE CHQ", "CHQ", "CHEQUE"), "cheque"),
    (("CB", "CARTE"), "card"),
)
HEADER_SCAN_ROWS = 20


def normalise_header(text: str) -> str:
    """« Date d'opération » -> « date d operation »."""
    decomposed = unicodedata.normalize("NFKD", text.replace("\ufeff", ""))
    plain = "".join(c for c in decomposed if not unicodedata.combining(c)).lower()
    return " ".join(re.sub(r"[^a-z0-9]+", " ", plain).split())


def plain_upper(text: str) -> str:
    if text.isascii():  # most bank labels: nothing to decompose
        return text.upper()
    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(c for c in decomposed if not unicodedata.combining(c)).upper()


@dataclass(frozen=True)
class CsvProfile:
    """Which header holds which field, and the decimal separator."""

    columns: Mapping[str, tuple[str, ...]] = field(default_factory=lambda: dict(COLUMNS))
    decimal: str = ","

    @classmethod
    def from_json(cls, data: Mapping[str, Any] | None) -> CsvProfile:
        """A bank account's csv_profile: its own header per field (on top of the defaults)."""
        if not data:
            return cls()
        named = (data.get("columns") or {}) if isinstance(data, Mapping) else None
        if not isinstance(named, Mapping):
            raise StatementRejected("csv_profile_invalid", "columns must map fields to headers")
        columns = dict(COLUMNS)
        for name, header in named.items():
            if name not in COLUMNS or not isinstance(header, str) or not header.strip():
                raise StatementRejected("csv_profile_invalid", f"unknown column field {name!r}")
            columns[name] = (normalise_header(header),)
        decimal = data.get("decimal", ",")
        if decimal not in (",", "."):
            raise StatementRejected("csv_profile_invalid", "decimal separator must be , or .")
        return cls(columns=columns, decimal=str(decimal))


def parse_fr_amount(text: str, *, decimal: str = ",", exponent: int = 2) -> int | None:
    """French amount text -> signed minor units (None when blank). Refused, never rounded."""
    t = text.replace("\u00a0", " ").replace("\u202f", " ").replace("€", "")
    t = re.sub(r"\bEUR\b", "", t, flags=re.IGNORECASE).strip()
    if not t:
        return None
    sign = 1
    if t[0] in "+-":
        sign, t = (-1 if t[0] == "-" else 1), t[1:].strip()
    elif t.endswith("-"):
        sign, t = -1, t[:-1].strip()
    thousands = "." if decimal == "," else ","
    pattern = (
        rf"(?P<units>[0-9]{{1,3}}(?:[ {re.escape(thousands)}][0-9]{{3}})+|[0-9]+)"
        rf"(?:{re.escape(decimal)}(?P<frac>[0-9]+))?"
    )
    match = re.fullmatch(pattern, t)
    if match is None:
        raise ValueError(f"{text!r} is not an amount")
    units = re.sub(r"[^0-9]", "", match["units"])
    if len(units) > 18:
        raise ValueError(f"{text!r} is larger than an amount can be")
    return sign * decimal_to_minor(units, match["frac"] or "", exponent)


def parse_fr_date(text: str) -> date:
    t = text.strip()
    match = DATE_FR_RE.fullmatch(t)
    if match is not None:
        return date(int(match[3]), int(match[2]), int(match[1]))
    if DATE_ISO_RE.fullmatch(t):
        return date.fromisoformat(t)
    raise ValueError(f"{text!r} is not a date (JJ/MM/AAAA)")


@dataclass(frozen=True)
class Label:
    text: str  # the label as printed, single spaces: the line's remittance information
    head: str  # the bank's part, before the first marker (« VIR SEPA RECU »)
    name: str | None
    motif: str | None
    reference: str | None


def parse_label(label: str) -> Label:
    """« VIR SEPA RECU /DE MARTIN SAS /MOTIF REGLT F-103 /REF RF18… » -> payer, motif, reference.
    The whole label stays the remittance text: banks word and cut it differently, and matching
    (M2b-3) reads references wherever they are."""
    parts = MARKER_RE.split(label)
    fields: dict[str, str] = {}
    for i in range(1, len(parts) - 1, 2):
        fields.setdefault(parts[i].upper(), " ".join(parts[i + 1].split()))
    return Label(
        text=" ".join(label.split()),
        head=" ".join(parts[0].split()),
        name=fields.get("DE") or None,
        motif=fields.get("MOTIF") or None,
        reference=fields.get("REF") or None,
    )


def method_of(label: str) -> str:
    upper = plain_upper(label).strip()
    for prefixes, method in METHOD_PREFIXES:
        if any(upper == p or upper.startswith(p + " ") for p in prefixes):
            return method
    return "other"


class _Columns:
    def __init__(self, header: list[str], profile: CsvProfile) -> None:
        names = [normalise_header(h) for h in header]
        self.width = len(header)
        self.index: dict[str, int] = {}
        for name, accepted in profile.columns.items():
            found = [i for i, h in enumerate(names) if h in accepted]
            if len(found) > 1:
                found = [i for i in found if names[i] in PREFERRED.get(name, ())]
                if len(found) != 1:
                    raise StatementRejected("csv_header", f"two columns for {name}")
            if found:
                self.index[name] = found[0]
        self.missing = [n for n in ("booking_date", "label") if n not in self.index]
        if "amount" not in self.index and not {"debit", "credit"} <= set(self.index):
            self.missing.append("amount (or debit and credit)")
        money = ("amount",) if "amount" in self.index else ("debit", "credit")
        self.needed = max(
            (self.index[n] for n in ("booking_date", "label", *money) if n in self.index),
            default=0,
        )

    def get(self, row: list[str], name: str) -> str:
        i = self.index.get(name)
        return row[i].strip() if i is not None and i < len(row) else ""

    def check_shape(self, row: list[str]) -> None:
        """The cells of the date, the label and the amounts are there, and nothing lies beyond the
        header (an unquoted separator in a label would move the amounts to other columns).
        Optional cells missing at the end of a row are read as empty."""
        if len(row) <= self.needed:
            raise ValueError(f"{len(row)} cells, the header has {self.width}")
        if any(cell.strip() for cell in row[self.width :]):
            raise ValueError(
                f"{len(row)} cells, the header has {self.width} (a separator inside a label?)"
            )


def parse_csv(  # noqa: PLR0913 - the bank account's settings
    path: Path,
    *,
    currency: str,
    exponent: int = 2,
    profile: CsvProfile | None = None,
    today: date | None = None,
    ibans: KnownIbans = NO_IBANS,
) -> ParsedStatement:
    """Parse a CSV export of the bank account, or refuse it (the file's line in the detail).
    `ibans`: the servicer's own and its clients' IBANs, to recognise our own transfers (M2c)."""
    profile = profile or CsvProfile()
    encoding = check_file(path)
    separator = _separator(path, encoding, profile)
    out = ParsedStatement(format="csv", currency=currency)
    keys = DedupKeys()
    with path.open("r", encoding=encoding, newline="") as fh:
        reader = csv.reader(fh, delimiter=separator)
        columns = _find_header(reader, profile)
        ctx = _File(columns, profile, currency, exponent, keys, ibans)
        for line_no, row in _data_rows(reader):
            try:
                line = _line(row, ctx, line_no)
            except ValueError as exc:
                raise StatementRejected("csv_row", f"line {line_no}: {exc}") from exc
            except StatementRejected as exc:
                raise StatementRejected(exc.code, f"line {line_no}: {exc.detail}") from exc
            if line is None:
                out.skipped_not_booked += 1
            else:
                out.lines.append(line)
    if not out.lines:
        raise StatementRejected("csv_empty", "the file has no line to import")
    if today is not None:
        check_dates(out.lines, today)
    return out


class _Scan(NamedTuple):
    lines: int
    bad_line: int | None = None  # the first line with a byte the codec cannot read, or a NUL
    bad_byte: int = 0  # that byte (0 for a NUL)


def _breaks(data: bytes, after_cr: bool) -> int:
    """Line ends as csv reads them: CR LF, LF or a lone CR (a CR LF may span two chunks)."""
    n = data.count(b"\n") + data.count(b"\r") - data.count(b"\r\n")
    return n - 1 if after_cr and data.startswith(b"\n") else n


def _scan(path: Path, codec: str) -> _Scan:
    """Decode the whole file in chunks (constant memory) and count its lines."""
    decoder = codecs.getincrementaldecoder(codec)()
    breaks, after_cr, ends_line, size = 0, False, False, 0
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(READ_CHUNK)
            pending = len(decoder.getstate()[0])
            bad: int | None = None
            byte = 0
            try:
                decoder.decode(chunk, final=not chunk)
            except UnicodeDecodeError as exc:
                bad, byte = max(exc.start - pending, 0), exc.object[exc.start]
            nul = chunk.find(b"\x00")
            if nul >= 0 and (bad is None or nul < bad):
                bad, byte = nul, 0
            if bad is not None:
                return _Scan(breaks, breaks + _breaks(chunk[:bad], after_cr) + 1, byte)
            if not chunk:
                return _Scan(breaks + (1 if size and not ends_line else 0))
            breaks += _breaks(chunk, after_cr)
            after_cr, ends_line = chunk.endswith(b"\r"), chunk.endswith((b"\r", b"\n"))
            size += len(chunk)


def check_file(path: Path) -> str:
    """The codec the whole file decodes with: UTF-8 (a BOM is dropped), else Windows-1252. Refused
    before any parsing: too large (`file_too_large`), UTF-16 or a byte that is neither UTF-8 nor
    Windows-1252 (`csv_encoding`, with its line)."""
    size = path.stat().st_size
    cap = f"a CSV statement has at most {MAX_BYTES} bytes and {MAX_LINES} lines"
    if size > MAX_BYTES:
        raise StatementRejected("file_too_large", f"{size} bytes: {cap}; export a shorter period")
    with path.open("rb") as fh:
        head = fh.read(len(codecs.BOM_UTF8))
    if head.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        raise StatementRejected(
            "csv_encoding", "the file is UTF-16: save it as CSV UTF-8 or CSV Windows-1252"
        )
    bom = head.startswith(codecs.BOM_UTF8)
    codec, scan = ("utf-8-sig" if bom else "utf-8"), _scan(path, "utf-8")
    if scan.bad_line is not None and scan.bad_byte and not bom:
        codec, scan = "cp1252", _scan(path, "cp1252")
    if scan.bad_line is not None:
        if not scan.bad_byte:
            problem = "a NUL byte, so not a text file (UTF-16?): save it as CSV UTF-8"
        elif bom:
            problem = f"byte 0x{scan.bad_byte:02X} is not UTF-8, though the file starts as UTF-8"
        else:
            problem = f"byte 0x{scan.bad_byte:02X} is neither UTF-8 nor Windows-1252"
        raise StatementRejected("csv_encoding", f"line {scan.bad_line}: {problem}")
    if scan.lines > MAX_LINES:
        raise StatementRejected(
            "file_too_large", f"{scan.lines} lines: {cap}; export a shorter period"
        )
    return codec


def _separator(path: Path, encoding: str, profile: CsvProfile) -> str:
    """The sniffed separator, or the first other one that reveals the header row (a preamble
    line without separators can mislead the sniffing)."""
    with path.open("rb") as fh:
        sample = fh.read(SAMPLE_BYTES).decode(encoding, errors="ignore")
    try:
        sniffed = sniff_separator(sample)
    except csv.Error:  # a field over the csv module's limit in the first lines: refused when read
        sniffed = SEPARATORS[0]
    for candidate in dict.fromkeys((sniffed, *SEPARATORS)):
        with path.open("r", encoding=encoding, newline="") as fh:
            try:
                _find_header(csv.reader(fh, delimiter=candidate), profile)
            except StatementRejected:
                continue
            return candidate
    return sniffed


def _next_row(reader: Reader, first: int) -> list[str] | None:
    """The next row (None at the end). A csv error (a field over the csv module's limit of
    131,072 characters) refuses the file at the line the row starts on."""
    try:
        return next(reader)
    except StopIteration:
        return None
    except csv.Error as exc:
        raise StatementRejected("csv_row", f"line {first}: {exc}") from exc


def _find_header(reader: Reader, profile: CsvProfile) -> _Columns:
    """The header row: the first of the first rows that names every required column (bank exports
    often start with the account number and the period)."""
    first: _Columns | None = None
    while (row := _next_row(reader, reader.line_num + 1)) is not None:
        if not any(cell.strip() for cell in row):
            continue
        columns = _Columns(row, profile)
        if not columns.missing:
            return columns
        first = first or columns
        if reader.line_num >= HEADER_SCAN_ROWS:
            break
    if first is None:
        raise StatementRejected("csv_empty", "the file is empty")
    raise StatementRejected("csv_header", f"missing column(s): {', '.join(first.missing)}")


def _data_rows(reader: Reader) -> Iterator[tuple[int, list[str]]]:
    """The non-blank rows after the header, with the file line each starts on. A row spread over
    several lines is refused: no documented field holds a line break, so it is a quote left open
    that swallowed the next rows."""
    first = reader.line_num + 1
    try:
        for row in reader:
            start, first = first, reader.line_num + 1
            if not any(cell.strip() for cell in row):
                continue
            if first - start > 1:
                raise StatementRejected(
                    "csv_row",
                    f"line {start}: a quoted field runs over {first - start} lines"
                    " (a quote that is not closed?)",
                )
            yield start, row
    except csv.Error as exc:  # a field over the csv module's limit of 131,072 characters
        raise StatementRejected("csv_row", f"line {first}: {exc}") from exc


def _signed_amount(row: list[str], columns: _Columns, profile: CsvProfile, exponent: int) -> int:
    if "amount" in columns.index:
        amount = parse_fr_amount(
            columns.get(row, "amount"), decimal=profile.decimal, exponent=exponent
        )
        return amount or 0
    debit = parse_fr_amount(columns.get(row, "debit"), decimal=profile.decimal, exponent=exponent)
    credit = parse_fr_amount(columns.get(row, "credit"), decimal=profile.decimal, exponent=exponent)
    if debit and credit:
        raise ValueError("both a debit and a credit")
    if debit:
        return -abs(debit)  # banks print debits negative or positive
    if credit is not None and credit < 0:
        raise ValueError(f"{columns.get(row, 'credit')!r} is negative in the credit column")
    return credit or 0


@dataclass(frozen=True)
class _File:
    columns: _Columns
    profile: CsvProfile
    currency: str
    exponent: int
    keys: DedupKeys
    ibans: KnownIbans = NO_IBANS


def _line(row: list[str], ctx: _File, line_no: int) -> StatementLine | None:
    columns, currency, keys = ctx.columns, ctx.currency, ctx.keys
    columns.check_shape(row)
    raw_date = columns.get(row, "booking_date")
    if not raw_date:
        raise ValueError("booking date missing")
    booking = parse_fr_date(raw_date)
    raw_value = columns.get(row, "value_date")
    value = parse_fr_date(raw_value) if raw_value else None
    row_currency = columns.get(row, "currency").upper()
    if row_currency and row_currency != currency:
        raise StatementRejected("wrong_currency", f"a line is in {row_currency}, not {currency}")
    signed = _signed_amount(row, columns, ctx.profile, ctx.exponent)
    if signed == 0:
        return None  # an information line: nothing moved
    direction = "credit" if signed > 0 else "debit"
    text = columns.get(row, "label")
    label = parse_label(text)
    reference = label.reference
    creditor_ref = columns.get(row, "creditor_reference") or None
    e2e = columns.get(row, "end_to_end_id") or None
    if reference is not None and creditor_ref is None and rf_valid(rf_normalise(reference)):
        creditor_ref = reference
    elif reference is not None and e2e is None:
        e2e = reference
    name = columns.get(row, "counterparty_name") or label.name
    iban = rf_normalise(columns.get(row, "counterparty_iban")) or None
    kind = (
        "return"
        if RETURN_RE.match(plain_upper(label.text[:64]))  # a match is at most 30 characters
        else classify(
            direction,
            reversal=False,
            return_reason=None,
            sub_family=None,
            end_to_end_id=e2e,
            counterparty_iban=iban,
            ibans=ctx.ibans,
        )
    )
    bank_id = columns.get(row, "bank_id")
    amount = abs(signed)
    key = (
        keys.claim(f"c:{bank_id}")
        if bank_id
        else keys.fingerprint(
            booking_date=booking,
            value_date=value,
            direction=direction,
            amount_minor=amount,
            currency=currency,
            counterparty_iban=iban,
            end_to_end_id=e2e,
            remittance_text=text,
        )
    )
    return StatementLine(
        line_no=line_no,
        section_no=0,
        dedup_key=key,
        direction=direction,
        amount_minor=amount,
        currency=currency,
        booking_date=booking,
        value_date=value,
        kind=kind,
        method=method_of(text),
        acct_svcr_ref=bank_id or None,
        end_to_end_id=e2e,
        counterparty_name=name,
        counterparty_iban=iban,
        remittance_text=label.text,
        creditor_reference=rf_normalise(creditor_ref) if creditor_ref else None,
        original_end_to_end_id=e2e if kind == "return" else None,
    )
