"""Bank statements (M2-07): what a parser hands to the import, and the rules the camt.053 and CSV
parsers share (exact amounts, dedup keys, kinds of lines).

A parsed statement is checked before anything is written: a file that cannot be read exactly is
refused with a stable code (`StatementRejected`), which the back-office words in French.
Design: docs/design/m2b-payments.md §8.3; ADR-0013.
"""

from __future__ import annotations

import hashlib
import re
from collections import Counter
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal
from typing import Any

MAX_MINOR = 10**15  # same bound as the ledger and payment tables


class StatementRejected(Exception):  # noqa: N818 - a business outcome, not a programming error
    """The file cannot be imported. `code` is stable; `detail` says where (English, for staff)."""

    def __init__(self, code: str, detail: str) -> None:
        super().__init__(f"{code}: {detail}")
        self.code = code
        self.detail = detail


# ISO 20022 amounts: digits, an optional "." and at most 5 decimals, no sign, no exponent.
ISO_AMOUNT_RE = re.compile(r"(?P<units>[0-9]{1,18})(?:\.(?P<frac>[0-9]{1,5}))?")


def decimal_to_minor(units: str, frac: str, exponent: int) -> int:
    """Major units and decimals (as written) -> integer minor units, exactly.

    Decimals beyond the currency's exponent are accepted only if they are zeros: an amount is
    refused, never rounded (design §8.3; `money.to_minor_units` rounds and is not used here).
    """
    if frac[exponent:].strip("0"):
        raise ValueError(f"{units}.{frac} has more decimals than the currency allows ({exponent})")
    value = Decimal(f"{units}.{frac or '0'}").scaleb(exponent)
    if value != value.to_integral_value():  # pragma: no cover - excluded by the check above
        raise ValueError(f"{units}.{frac} is not a whole number of minor units")
    minor = int(value)
    if minor > MAX_MINOR:
        raise ValueError(f"{units}.{frac} is larger than an amount can be")
    return minor


def iso_to_minor(text: str | None, exponent: int) -> int:
    """camt.053 amount text (`1234.5`) -> minor units (`123450` for EUR)."""
    match = ISO_AMOUNT_RE.fullmatch((text or "").strip())
    if match is None:
        raise ValueError(f"{text!r} is not an ISO 20022 amount")
    return decimal_to_minor(match["units"], match["frac"] or "", exponent)


def minor_to_iso(minor: int, exponent: int) -> str:
    """Minor units -> ISO 20022 amount text (`123450` -> `1234.50`)."""
    if minor < 0:
        raise ValueError("ISO 20022 amounts carry no sign")
    if exponent == 0:
        return str(minor)
    units, frac = divmod(minor, 10**exponent)
    return f"{units}.{frac:0{exponent}d}"


# Bank transaction sub-families that undo an earlier movement (ISO external code list).
RETURN_SUBFAMILIES = frozenset({"RRTN", "RPCR", "UPDD", "PRDD"})
# Family of a bank transaction code -> payment method.
METHOD_BY_FAMILY = {
    "RCDT": "sct",
    "ICDT": "sct",
    "RRCT": "sct",
    "RDDT": "sdd",
    "IDDT": "sdd",
    "RCHQ": "cheque",
    "ICHQ": "cheque",
    "CCRD": "card",
    "MCRD": "card",
}
REFUND_PREFIX = "RFD"  # end-to-end ids of our own refunds (design §6 refund_request, M2b-6)


def classify(
    direction: str,
    *,
    reversal: bool,
    return_reason: str | None,
    sub_family: str | None,
    end_to_end_id: str | None,
) -> str:
    """Kind of a line (design §8.3 step 6).

    A line that undoes an earlier movement (return reason, reversal indicator or a return
    sub-family) is a `return`, in either direction: a credit that reverses a debit (a returned
    refund, a fee taken back) is not a debtor payment (ADR-0013, M2b-2 addendum).
    """
    if return_reason or reversal or (sub_family in RETURN_SUBFAMILIES):
        return "return"
    if direction == "credit":
        return "debtor_credit"
    if end_to_end_id and end_to_end_id.startswith(REFUND_PREFIX):
        return "refund_out"
    return "other_debit"


def normalise_text(text: str | None) -> str:
    """Upper case, single spaces: what the fingerprint of a line compares."""
    return " ".join((text or "").upper().split())


@dataclass(frozen=True, slots=True)
class StatementLine:
    """One line as the import stores it (`private.bank_import_stage`, then `bank_transaction`)."""

    line_no: int
    section_no: int  # 1-based <Stmt> of a camt.053 file; 0 for CSV
    dedup_key: str
    direction: str  # credit | debit
    amount_minor: int
    currency: str
    booking_date: date
    value_date: date | None
    kind: str
    method: str
    reversal_indicator: bool = False
    bank_tx_code: str | None = None
    acct_svcr_ref: str | None = None
    end_to_end_id: str | None = None
    tx_id: str | None = None
    mandate_ref: str | None = None
    counterparty_name: str | None = None
    ultimate_counterparty_name: str | None = None
    counterparty_iban: str | None = None
    remittance_text: str | None = None
    creditor_reference: str | None = None
    return_reason: str | None = None
    original_end_to_end_id: str | None = None
    batch_entry_ref: str | None = None

    @property
    def signed_minor(self) -> int:
        return self.amount_minor if self.direction == "credit" else -self.amount_minor


STAGE_COLUMNS = (
    "line_no",
    "section_no",
    "dedup_key",
    "direction",
    "amount_minor",
    "currency",
    "booking_date",
    "value_date",
    "reversal_indicator",
    "bank_tx_code",
    "acct_svcr_ref",
    "end_to_end_id",
    "tx_id",
    "mandate_ref",
    "counterparty_name",
    "ultimate_counterparty_name",
    "counterparty_iban",
    "remittance_text",
    "creditor_reference",
    "return_reason",
    "original_end_to_end_id",
    "batch_entry_ref",
    "kind",
    "method",
)


@dataclass(frozen=True, slots=True)
class Section:
    """One <Stmt> of a camt.053 file: the bank's own proof (opening + lines = closing)."""

    stmt_id: str | None
    seq: int | None
    iban: str | None
    currency: str
    from_date: date
    to_date: date
    opening_minor: int  # signed (DBIT balance = negative)
    closing_minor: int

    def as_json(self) -> dict[str, Any]:
        """Amounts as text (no JSON number for money)."""
        return {
            "stmt_id": self.stmt_id,
            "seq": self.seq,
            "from_date": self.from_date.isoformat(),
            "to_date": self.to_date.isoformat(),
            "opening_minor": str(self.opening_minor),
            "closing_minor": str(self.closing_minor),
        }


@dataclass
class ParsedStatement:
    format: str  # camt053 | csv
    currency: str
    sections: list[Section] = field(default_factory=list)
    lines: list[StatementLine] = field(default_factory=list)
    skipped_not_booked: int = 0  # pending/information entries, zero-amount CSV rows
    version: str | None = None  # camt.053.001.XX

    def header(self) -> dict[str, Any]:
        return {
            "format": self.format,
            "line_count": len(self.lines),
            "skipped_not_booked": self.skipped_not_booked,
            "version": self.version,
            "sections": [s.as_json() for s in self.sections],
        }


class DedupKeys:
    """Dedup keys of one file (design §8.3 step 4), first that applies:
    `t:` the line's own bank reference, `e:` the entry's reference and the line's index in it,
    `c:` a CSV bank id column, else `h:` a fingerprint of the facts and its occurrence number
    in the file (two identical €50 transfers on one day stay two lines)."""

    def __init__(self) -> None:
        self._seen: Counter[str] = Counter()
        self._keys: set[str] = set()

    def fingerprint(  # noqa: PLR0913 - the facts that identify a line without a bank reference
        self,
        *,
        booking_date: date,
        value_date: date | None,
        direction: str,
        amount_minor: int,
        currency: str,
        counterparty_iban: str | None,
        end_to_end_id: str | None,
        remittance_text: str | None,
    ) -> str:
        raw = "|".join(
            (
                booking_date.isoformat(),
                value_date.isoformat() if value_date else "",
                direction,
                str(amount_minor),
                currency,
                counterparty_iban or "",
                end_to_end_id or "",
                normalise_text(remittance_text),
            )
        )
        digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()
        self._seen[digest] += 1
        return self.claim(f"h:{digest}#{self._seen[digest]}")

    def claim(self, key: str) -> str:
        """A key is used once per file: a bank reference reported twice makes the file unusable."""
        if len(key) > 300:
            raise StatementRejected("line_invalid", f"bank reference too long: {key[:40]}…")
        if key in self._keys:
            raise StatementRejected(
                "duplicate_reference_in_file", f"{key} appears twice in the file"
            )
        self._keys.add(key)
        return key


def check_balanced(section: Section, lines: list[StatementLine], section_no: int) -> None:
    """The bank's proof for one <Stmt>: opening + credits - debits = closing, to the cent."""
    moved = sum(line.signed_minor for line in lines if line.section_no == section_no)
    if section.opening_minor + moved != section.closing_minor:
        raise StatementRejected(
            "unbalanced",
            f"statement {section.stmt_id or section_no}: opening {section.opening_minor}"
            f" + lines {moved} != closing {section.closing_minor} (minor units)",
        )


def check_dates(lines: list[StatementLine], today: date) -> None:
    late = next((line for line in lines if line.booking_date > today), None)
    if late is not None:
        raise StatementRejected(
            "future_booking_date", f"line {late.line_no} is booked on {late.booking_date}"
        )
