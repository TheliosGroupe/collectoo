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
currency has are refused, never rounded. Encoding (UTF-8 or Windows-1252) and separator are
sniffed as for boarding files.

The label parser reads the markers French banks print: « /DE <payer> /MOTIF <text> /REF <ref> ».
A CSV export proves no balance: there is no opening/closing check (the page says so); re-exported
lines are caught by the bank id column when there is one, and otherwise held as suspected
duplicates by the import (SQL).
"""

from __future__ import annotations

import csv
import re
import unicodedata
from collections.abc import Iterator, Mapping
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any

from collectoo_worker.boarding.readers import SEPARATORS, sniff_csv
from collectoo_worker.payments.rf import rf_normalise, rf_valid
from collectoo_worker.payments.statement import (
    DedupKeys,
    ParsedStatement,
    StatementLine,
    StatementRejected,
    check_dates,
    classify,
    decimal_to_minor,
)

# Field -> accepted headers (normalised: lower case, no accents, words separated by one space).
COLUMNS: Mapping[str, tuple[str, ...]] = {
    "booking_date": (
        "date",
        "date operation",
        "date d operation",
        "date comptable",
        "date de comptabilisation",
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
MARKER_RE = re.compile(r"\s*/(DE|MOTIF|REF)\b\s*", re.IGNORECASE)
# Read in the bank's part of the label (before « /DE », « /MOTIF »…), never in the payer's words.
RETURN_WORDS_RE = re.compile(r"\b(RETOUR|RETOURNE|REJET|REJETE|IMPAYE|ANNULATION)\b")
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
        columns = dict(COLUMNS)
        for name, header in dict(data.get("columns") or {}).items():
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
        self.index: dict[str, int] = {}
        for name, accepted in profile.columns.items():
            found = [i for i, h in enumerate(names) if h in accepted]
            if len(found) > 1:
                raise StatementRejected("csv_header", f"two columns for {name}")
            if found:
                self.index[name] = found[0]
        self.missing = [n for n in ("booking_date", "label") if n not in self.index]
        if "amount" not in self.index and not {"debit", "credit"} <= set(self.index):
            self.missing.append("amount (or debit and credit)")

    def get(self, row: list[str], name: str) -> str:
        i = self.index.get(name)
        return row[i].strip() if i is not None and i < len(row) else ""


def parse_csv(
    path: Path,
    *,
    currency: str,
    exponent: int = 2,
    profile: CsvProfile | None = None,
    today: date | None = None,
) -> ParsedStatement:
    """Parse a CSV export of the bank account, or refuse it (line number in the detail)."""
    profile = profile or CsvProfile()
    dialect = sniff_csv(path)
    separator = _separator(path, dialect.encoding, dialect.separator, profile)
    out = ParsedStatement(format="csv", currency=currency)
    keys = DedupKeys()
    with path.open("r", encoding=dialect.encoding, newline="") as fh:
        rows = csv.reader(fh, delimiter=separator)
        columns, header_row = _find_header(rows, profile)
        ctx = _File(columns, profile, currency, exponent, keys)
        for row_no, row in enumerate(rows, start=header_row + 1):
            if not any(cell.strip() for cell in row):
                continue
            try:
                line = _line(row, ctx, len(out.lines) + 1)
            except ValueError as exc:
                raise StatementRejected("csv_row", f"line {row_no}: {exc}") from exc
            if line is None:
                out.skipped_not_booked += 1
            else:
                out.lines.append(line)
    if not out.lines:
        raise StatementRejected("csv_empty", "the file has no line to import")
    if today is not None:
        check_dates(out.lines, today)
    return out


def _separator(path: Path, encoding: str, sniffed: str, profile: CsvProfile) -> str:
    """The sniffed separator, or the first other one that reveals the header row (a preamble
    line without separators can mislead the sniffing)."""
    for candidate in dict.fromkeys((sniffed, *SEPARATORS)):
        with path.open("r", encoding=encoding, newline="") as fh:
            try:
                _find_header(csv.reader(fh, delimiter=candidate), profile)
            except StatementRejected:
                continue
            return candidate
    return sniffed


def _find_header(rows: Iterator[list[str]], profile: CsvProfile) -> tuple[_Columns, int]:
    """The header row: the first of the first rows that names every required column (bank exports
    often start with the account number and the period)."""
    first: _Columns | None = None
    for row_no, row in enumerate(rows, start=1):
        if not any(cell.strip() for cell in row):
            continue
        columns = _Columns(row, profile)
        if not columns.missing:
            return columns, row_no
        first = first or columns
        if row_no >= HEADER_SCAN_ROWS:
            break
    if first is None:
        raise StatementRejected("csv_empty", "the file is empty")
    raise StatementRejected("csv_header", f"missing column(s): {', '.join(first.missing)}")


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
        return -abs(debit)
    return abs(credit or 0)


@dataclass(frozen=True)
class _File:
    columns: _Columns
    profile: CsvProfile
    currency: str
    exponent: int
    keys: DedupKeys


def _line(row: list[str], ctx: _File, line_no: int) -> StatementLine | None:
    columns, currency, keys = ctx.columns, ctx.currency, ctx.keys
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
        if RETURN_WORDS_RE.search(plain_upper(label.head))
        else classify(
            direction, reversal=False, return_reason=None, sub_family=None, end_to_end_id=e2e
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
