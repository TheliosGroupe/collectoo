"""Ledger model (M2-04): entries, lines and their invariants, without I/O.

The database enforces the same rules (supabase/migrations/20261108170000_ledger.sql); this module
lets the worker build and check an entry before sending it, and is the reference for the
property tests. Amounts are signed integer minor units (+ debit, - credit). No floats.
"""

from __future__ import annotations

import re
from collections import defaultdict
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, replace
from datetime import date
from enum import StrEnum
from uuid import UUID

MAX_ABS_MINOR = 10**15
MAX_LINES = 100_000
KEY_RE = re.compile(r"[A-Za-z0-9:._#-]{8,200}")
CURRENCY_RE = re.compile(r"[A-Z]{3}")
HASH_RE = re.compile(r"[0-9a-f]{64}")
MAX_REASON = 2000


class Book(StrEnum):
    DEBTOR_RECEIVABLE = "debtor_receivable"
    OWNER_CLAIM = "owner_claim"
    UNALLOCATED_PAYMENT = "unallocated_payment"
    CLIENT_PAYABLE = "client_payable"
    SERVICER_REVENUE = "servicer_revenue"


class Component(StrEnum):
    PRINCIPAL = "principal"
    ACCRUED_INTEREST = "accrued_interest"
    OTHER_BALANCES = "other_balances"
    BALANCING_LINE = "balancing_line"


class EntryType(StrEnum):
    OPENING = "opening"
    ADJUSTMENT = "adjustment"
    REVERSAL = "reversal"


@dataclass(frozen=True, slots=True)
class BookSpec:
    account_number: str
    dimension: str  # claim | owner | client
    money_of: str  # owner | client | servicer
    normal_side: int
    client_visible: bool


# Mirrors public.ledger_book (a test compares them).
BOOKS: Mapping[Book, BookSpec] = {
    Book.DEBTOR_RECEIVABLE: BookSpec("1100", "claim", "owner", 1, True),
    Book.OWNER_CLAIM: BookSpec("3100", "owner", "owner", -1, True),
    Book.UNALLOCATED_PAYMENT: BookSpec("4710", "client", "client", -1, True),
    Book.CLIENT_PAYABLE: BookSpec("4670", "client", "client", -1, True),
    Book.SERVICER_REVENUE: BookSpec("7060", "client", "servicer", -1, True),
}
CLAIM_BOOKS = frozenset({Book.DEBTOR_RECEIVABLE, Book.OWNER_CLAIM})
ALLOWED_BOOKS: Mapping[EntryType, frozenset[Book]] = {
    EntryType.OPENING: CLAIM_BOOKS,
    EntryType.ADJUSTMENT: frozenset({*CLAIM_BOOKS, Book.UNALLOCATED_PAYMENT, Book.CLIENT_PAYABLE}),
}


# --- Errors (SQLSTATE LG000-LG006 in the database) -------------------------------------------


class LedgerError(Exception):
    sqlstate = "LG"


class AppendOnlyError(LedgerError):
    sqlstate = "LG000"


class UnbalancedEntryError(LedgerError):
    sqlstate = "LG001"


class MirrorBrokenError(UnbalancedEntryError):
    """The receivable and the owner claim must move by opposite amounts per component."""


class ScopeError(LedgerError):
    sqlstate = "LG002"


class ReversalError(LedgerError):
    sqlstate = "LG003"


class AlreadyReversedError(ReversalError):
    pass


class IdempotencyConflictError(LedgerError):
    sqlstate = "LG004"


class OpeningMismatchError(LedgerError):
    sqlstate = "LG005"


class InvalidRequestError(LedgerError):
    sqlstate = "LG006"


ERRORS_BY_SQLSTATE: Mapping[str, type[LedgerError]] = {
    "LG000": AppendOnlyError,
    "LG001": UnbalancedEntryError,
    "LG002": ScopeError,
    "LG003": ReversalError,
    "LG004": IdempotencyConflictError,
    "LG005": OpeningMismatchError,
    "LG006": InvalidRequestError,
}


# --- Lines and entries -----------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Line:
    book: Book
    amount_minor: int
    currency: str
    claim_item_id: UUID | None = None
    component: Component | None = None
    client_organization_id: UUID | None = None

    def __post_init__(self) -> None:
        # bool is an int subclass, Decimal and float are not exact here: refuse them all.
        if type(self.amount_minor) is not int:
            raise InvalidRequestError(
                f"amount_minor must be an int, got {type(self.amount_minor).__name__}"
            )
        if self.amount_minor == 0 or abs(self.amount_minor) > MAX_ABS_MINOR:
            raise InvalidRequestError(f"amount_minor out of range: {self.amount_minor}")
        if not CURRENCY_RE.fullmatch(self.currency):
            raise InvalidRequestError(f"currency must be 3 capital letters, got {self.currency!r}")
        if self.book is Book.DEBTOR_RECEIVABLE:
            if self.claim_item_id is None or self.component is None:
                raise InvalidRequestError("a receivable line names its claim item and component")
            if self.client_organization_id is not None:
                raise InvalidRequestError("a receivable line takes its client from the account")
        elif self.book is Book.OWNER_CLAIM:
            if self.component is None or self.claim_item_id is not None:
                raise InvalidRequestError("an owner-claim line names a component, not an item")
            if self.client_organization_id is not None:
                raise InvalidRequestError("an owner-claim line takes its client from the account")
        else:
            if self.claim_item_id is not None or self.component is not None:
                raise InvalidRequestError("client lines have no item or component")
            if self.client_organization_id is None and self.book is not Book.UNALLOCATED_PAYMENT:
                raise InvalidRequestError(f"a {self.book} line names its client")

    def negated(self) -> Line:
        return replace(self, amount_minor=-self.amount_minor)

    def as_json(self) -> dict[str, object]:
        """Wire format of private.ledger_post: ints stay JSON integers (exact)."""
        out: dict[str, object] = {
            "book": str(self.book),
            "amount_minor": self.amount_minor,
            "currency": self.currency,
        }
        if self.claim_item_id is not None:
            out["claim_item_id"] = str(self.claim_item_id)
        if self.component is not None:
            out["component"] = str(self.component)
        if self.client_organization_id is not None:
            out["client_organization_id"] = str(self.client_organization_id)
        return out


def balance_by_currency(lines: Iterable[Line]) -> dict[str, int]:
    out: dict[str, int] = defaultdict(int)
    for line in lines:
        out[line.currency] += line.amount_minor
    return dict(out)


def mirror_by_component(lines: Iterable[Line]) -> dict[tuple[str, str], int]:
    """Net movement of the claim books per (component, currency): zero in every valid entry."""
    out: dict[tuple[str, str], int] = defaultdict(int)
    for line in lines:
        if line.book in CLAIM_BOOKS:
            out[(str(line.component), line.currency)] += line.amount_minor
    return dict(out)


def mirror(lines: Iterable[Line]) -> tuple[Line, ...]:
    """The lines of a reversal: same order, amounts negated."""
    return tuple(line.negated() for line in lines)


def check_key(key: str) -> None:
    if not KEY_RE.fullmatch(key):
        raise InvalidRequestError("idempotency key: 8-200 characters among A-Z a-z 0-9 : . _ # -")


def check_reason(reason: str | None) -> None:
    if not (reason and reason.strip()):
        raise InvalidRequestError("a reason is required")
    if len(reason.strip()) > MAX_REASON:
        raise InvalidRequestError(f"a reason has at most {MAX_REASON} characters")


@dataclass(frozen=True, slots=True)
class EntryDraft:
    organization_id: UUID
    entry_type: EntryType
    effective_date: date
    idempotency_key: str
    lines: tuple[Line, ...]
    account_id: UUID | None = None
    reason: str | None = None
    source_type: str | None = None
    source_id: str | None = None
    engine_version: str | None = None
    rule_pack_version_id: UUID | None = None
    inputs_hash: str | None = None

    def validate(self) -> None:
        """Same rules as the database: refuse before sending (the database stays the backstop)."""
        if self.entry_type is not EntryType.ADJUSTMENT:
            raise InvalidRequestError(f"{self.entry_type} entries are not posted through the API")
        if not 2 <= len(self.lines) <= MAX_LINES:
            raise InvalidRequestError(f"an entry has 2 to {MAX_LINES} lines, got {len(self.lines)}")
        if not KEY_RE.fullmatch(self.idempotency_key):
            raise InvalidRequestError(
                "idempotency key: 8-200 characters among A-Z a-z 0-9 : . _ # -"
            )
        check_reason(self.reason)
        allowed = ALLOWED_BOOKS[self.entry_type]
        if any(line.book not in allowed for line in self.lines):
            raise ScopeError(f"a {self.entry_type} entry may only touch {sorted(allowed)}")
        has_claim = any(line.book in CLAIM_BOOKS for line in self.lines)
        if has_claim and self.account_id is None:
            raise InvalidRequestError("claim lines need the account")
        if not has_claim and self.account_id is not None:
            raise InvalidRequestError("account given without claim lines")
        clients = {
            line.client_organization_id for line in self.lines if line.client_organization_id
        }
        if len(clients) > 1:
            raise ScopeError("an entry concerns one client at most")
        unbalanced = {c: s for c, s in balance_by_currency(self.lines).items() if s}
        if unbalanced:
            raise UnbalancedEntryError(f"not balanced: {unbalanced}")
        broken = {k: s for k, s in mirror_by_component(self.lines).items() if s}
        if broken:
            raise MirrorBrokenError(f"receivable/owner-claim mirror broken: {broken}")
        if (self.engine_version is None) != (self.inputs_hash is None):
            raise InvalidRequestError("engine_version and inputs_hash go together")
        if self.inputs_hash is not None and not HASH_RE.fullmatch(self.inputs_hash):
            raise InvalidRequestError("inputs_hash is a sha-256 in lowercase hex")

    def meta_json(self) -> dict[str, str]:
        out: dict[str, str] = {}
        for key in ("reason", "source_type", "source_id", "engine_version", "inputs_hash"):
            value = getattr(self, key)
            if value is not None:
                out[key] = str(value)
        if self.account_id is not None:
            out["account_id"] = str(self.account_id)
        if self.rule_pack_version_id is not None:
            out["rule_pack_version_id"] = str(self.rule_pack_version_id)
        return out


@dataclass(frozen=True, slots=True)
class PostResult:
    entry_id: UUID
    created: bool


@dataclass(frozen=True, slots=True)
class Balance:
    claim_item_id: UUID
    component: Component
    currency: str
    balance_minor: int


@dataclass(frozen=True, slots=True)
class ClientMoney:
    currency: str
    unallocated_minor: int
    payable_minor: int
    held_minor: int
