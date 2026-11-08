"""Ledger model (M2-04): entries, lines and their invariants, without I/O.

The database enforces the same rules (supabase/migrations/20261108170000_ledger.sql and, for
payments, 20261109090000_payments_ledger.sql); this module lets the worker build and check an
entry before sending it, and is the reference for the property tests. Amounts are signed integer
minor units (+ debit, - credit). No floats.
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
    CLIENT_MONEY_CASH = "client_money_cash"


class Component(StrEnum):
    PRINCIPAL = "principal"
    ACCRUED_INTEREST = "accrued_interest"
    OTHER_BALANCES = "other_balances"
    BALANCING_LINE = "balancing_line"


class EntryType(StrEnum):
    OPENING = "opening"
    ADJUSTMENT = "adjustment"
    REVERSAL = "reversal"
    CASH_IN = "cash_in"
    ALLOCATION = "allocation"
    FORWARD = "forward"
    CASH_OUT = "cash_out"
    NETTING = "netting"


@dataclass(frozen=True, slots=True)
class BookSpec:
    account_number: str
    dimension: str  # claim | owner | client | bank
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
    Book.CLIENT_MONEY_CASH: BookSpec("5120", "bank", "client", 1, False),
}
CLAIM_BOOKS = frozenset({Book.DEBTOR_RECEIVABLE, Book.OWNER_CLAIM})
# Books holding money of the clients (money_of = client): closed in every entry (I2, ADR-0013).
CLIENT_MONEY_BOOKS = frozenset(b for b, spec in BOOKS.items() if spec.money_of == "client")
# Mirrors public.ledger_entry_type.allowed_books (a test compares them). Since M2b an adjustment
# cannot move client money; no payment type reaches 7060 (M2-12).
ALLOWED_BOOKS: Mapping[EntryType, frozenset[Book]] = {
    EntryType.OPENING: CLAIM_BOOKS,
    EntryType.ADJUSTMENT: CLAIM_BOOKS,
    EntryType.CASH_IN: frozenset({Book.CLIENT_MONEY_CASH, Book.UNALLOCATED_PAYMENT}),
    EntryType.ALLOCATION: frozenset({*CLAIM_BOOKS, Book.UNALLOCATED_PAYMENT, Book.CLIENT_PAYABLE}),
    EntryType.FORWARD: frozenset({Book.UNALLOCATED_PAYMENT, Book.CLIENT_PAYABLE}),
    EntryType.CASH_OUT: frozenset({Book.UNALLOCATED_PAYMENT, Book.CLIENT_MONEY_CASH}),
    EntryType.NETTING: frozenset({Book.DEBTOR_RECEIVABLE}),
}
# Posted only by private.ledger_post_set (from other definer functions), never by ledger_post.
PAYMENT_ENTRY_TYPES = frozenset(
    {
        EntryType.CASH_IN,
        EntryType.ALLOCATION,
        EntryType.FORWARD,
        EntryType.CASH_OUT,
        EntryType.NETTING,
    }
)
PAYMENT_TAGGED = frozenset({EntryType.ALLOCATION, EntryType.FORWARD, EntryType.CASH_OUT})
REQUIRES_REASON = frozenset(
    {
        EntryType.ADJUSTMENT,
        EntryType.REVERSAL,
        EntryType.FORWARD,
        EntryType.CASH_OUT,
        EntryType.NETTING,
    }
)


# --- Errors (SQLSTATE LG000-LG007 in the database) -------------------------------------------


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


class OverdrawnError(LedgerError):
    """A payment, an allocation or a receivable would go below zero at some date (I4, I6)."""

    sqlstate = "LG007"


ERRORS_BY_SQLSTATE: Mapping[str, type[LedgerError]] = {
    "LG000": AppendOnlyError,
    "LG001": UnbalancedEntryError,
    "LG002": ScopeError,
    "LG003": ReversalError,
    "LG004": IdempotencyConflictError,
    "LG005": OpeningMismatchError,
    "LG006": InvalidRequestError,
    "LG007": OverdrawnError,
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
    bank_account_id: UUID | None = None

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
        self._check_dimensions()

    def _check_dimensions(self) -> None:
        """Which of item, component, client and bank account each book's line carries."""
        if (self.bank_account_id is not None) != (self.book is Book.CLIENT_MONEY_CASH):
            raise InvalidRequestError("a cash line, and only a cash line, names its bank account")
        if self.book is Book.CLIENT_MONEY_CASH:
            if self.claim_item_id or self.component or self.client_organization_id:
                raise InvalidRequestError("a cash line has no item, component or client")
        elif self.book is Book.DEBTOR_RECEIVABLE:
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
        if self.bank_account_id is not None:
            out["bank_account_id"] = str(self.bank_account_id)
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


def client_money_by_currency(lines: Iterable[Line]) -> dict[str, int]:
    """Net movement of the client-money books (5120, 4710, 4670): zero in every entry (I2)."""
    out: dict[str, int] = defaultdict(int)
    for line in lines:
        if line.book in CLIENT_MONEY_BOOKS:
            out[line.currency] += line.amount_minor
    return dict(out)


def has_payment_shape(entry_type: EntryType, lines: Iterable[Line]) -> bool:
    """I3: the shape of a payment entry, as the database checks it (4710 lines are pooled)."""
    ls = list(lines)

    def count(book: Book, sign: int = 0) -> int:
        return sum(1 for x in ls if x.book is book and (sign == 0 or x.amount_minor * sign > 0))

    pooled = all(x.client_organization_id is None for x in ls if x.book is Book.UNALLOCATED_PAYMENT)
    cash, pool, pay = Book.CLIENT_MONEY_CASH, Book.UNALLOCATED_PAYMENT, Book.CLIENT_PAYABLE
    rec, own = Book.DEBTOR_RECEIVABLE, Book.OWNER_CLAIM
    if entry_type is EntryType.CASH_IN:
        return pooled and len(ls) == 2 and count(cash, 1) == 1 and count(pool, -1) == 1
    if entry_type is EntryType.CASH_OUT:
        return pooled and len(ls) == 2 and count(pool, 1) == 1 and count(cash, -1) == 1
    if entry_type is EntryType.FORWARD:
        return pooled and len(ls) == 2 and count(pool, 1) == 1 and count(pay, -1) == 1
    if entry_type is EntryType.ALLOCATION:
        return (
            pooled
            and count(pool) == 1
            and count(pool, 1) == 1
            and count(pay) == 1
            and count(pay, -1) == 1
            and count(rec, -1) >= 1
            and count(rec, 1) == 0
            and len(ls) == 2 + count(rec, -1) + count(own, 1)
        )
    if entry_type is EntryType.NETTING:
        return all(x.component is Component.PRINCIPAL for x in ls)
    return True


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
    payment_id: UUID | None = None
    client_organization_id: UUID | None = None  # forward: the client paid (others: the account's)

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

    def validate_set(self) -> None:  # noqa: PLR0912 - one rule per line, as in SQL
        """Rules of private.ledger_post_set for a payment entry, before any ledger state (the
        payment and receivable checks, I4 and I6, need the ledger: see tests/ledger_machine.py)."""
        t = self.entry_type
        if t not in PAYMENT_ENTRY_TYPES:
            raise InvalidRequestError(f"{t} entries are not posted as payment entries")
        if not 2 <= len(self.lines) <= MAX_LINES:
            raise InvalidRequestError(f"an entry has 2 to {MAX_LINES} lines, got {len(self.lines)}")
        check_key(self.idempotency_key)
        if t in REQUIRES_REASON:
            check_reason(self.reason)
        if (t in PAYMENT_TAGGED) != (self.payment_id is not None):
            raise InvalidRequestError("allocation, forward and cash_out (only) name their payment")
        if (self.account_id is not None) != (t in (EntryType.ALLOCATION, EntryType.NETTING)):
            raise InvalidRequestError("allocation and netting (only) name their account")
        if self.client_organization_id is not None and t is not EntryType.FORWARD:
            raise InvalidRequestError("only a forward names its client")
        if t is EntryType.CASH_IN and (self.source_type != "bank_statement" or not self.source_id):
            raise InvalidRequestError("a cash_in names its bank statement")
        if any(x.book is Book.UNALLOCATED_PAYMENT and x.client_organization_id for x in self.lines):
            raise InvalidRequestError("unallocated money is pooled (no client)")
        allowed = ALLOWED_BOOKS[t]
        if any(line.book not in allowed for line in self.lines):
            raise ScopeError(f"a {t} entry may only touch {sorted(allowed)}")
        clients = {x.client_organization_id for x in self.lines if x.client_organization_id}
        if self.client_organization_id is not None:
            clients.add(self.client_organization_id)
        if len(clients) > 1:
            raise ScopeError("an entry concerns one client at most")
        if any(balance_by_currency(self.lines).values()):
            raise UnbalancedEntryError("not balanced")
        if any(mirror_by_component(self.lines).values()):
            raise MirrorBrokenError("receivable/owner-claim mirror broken")
        if any(client_money_by_currency(self.lines).values()):
            raise UnbalancedEntryError("client money left open (closure)")
        if not has_payment_shape(t, self.lines):
            raise UnbalancedEntryError(f"not the shape of a {t} entry")

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
