"""Ledger model (M2-04): entries, lines and their invariants, without I/O.

The database enforces the same rules (supabase/migrations/20261108170000_ledger.sql, for
payments 20261109090000_payments_ledger.sql, and for the two funds of M2c
20261111090000_remittance_funds.sql); this module lets the worker build and check an entry before
sending it, and is the reference for the property tests. Amounts are signed integer minor units
(+ debit, - credit). No floats.
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
    # M2c (ADR-0014): the servicer's money on the dedicated account, and the servicer's fund
    DUE_TO_SERVICER = "due_to_servicer"
    DUE_FROM_CLIENT_FUNDS = "due_from_client_funds"
    OWN_CASH = "own_cash"
    COMMISSION_RECEIVABLE = "commission_receivable"
    CLIENT_ADVANCE_RECEIVABLE = "client_advance_receivable"
    VAT_COLLECTED = "vat_collected"
    VAT_PENDING = "vat_pending"
    BANK_FEES = "bank_fees"
    SERVICER_LOSSES = "servicer_losses"


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
    # M2c: the funds (design m2c-remittances §5.2)
    COMMISSION_INVOICE = "commission_invoice"
    COMMISSION_CREDIT_NOTE = "commission_credit_note"
    CLIENT_SETTLEMENT = "client_settlement"
    REMITTANCE = "remittance"
    SERVICER_SWEEP = "servicer_sweep"
    SERVICER_TOP_UP = "servicer_top_up"
    BANK_FEE = "bank_fee"
    CLIENT_ADVANCE = "client_advance"
    SERVICER_LOSS = "servicer_loss"
    CLIENT_PAYMENT_OWN = "client_payment_own"
    CLIENT_PAYMENT_DEDICATED = "client_payment_dedicated"
    CLIENT_REFUND_OWN = "client_refund_own"
    ADVANCE_WRITE_OFF = "advance_write_off"


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
    Book.SERVICER_REVENUE: BookSpec("7060", "client", "servicer", -1, False),
    Book.CLIENT_MONEY_CASH: BookSpec("5120", "bank", "client", 1, False),
    Book.DUE_TO_SERVICER: BookSpec("4679", "pooled", "client", -1, False),
    Book.DUE_FROM_CLIENT_FUNDS: BookSpec("4689", "pooled", "servicer", 1, False),
    Book.OWN_CASH: BookSpec("5122", "bank", "servicer", 1, False),
    Book.COMMISSION_RECEIVABLE: BookSpec("4111", "client", "servicer", 1, False),
    Book.CLIENT_ADVANCE_RECEIVABLE: BookSpec("4112", "client", "servicer", 1, False),
    Book.VAT_COLLECTED: BookSpec("44571", "pooled", "servicer", -1, False),
    Book.VAT_PENDING: BookSpec("44574", "pooled", "servicer", -1, False),
    Book.BANK_FEES: BookSpec("6270", "pooled", "servicer", 1, False),
    Book.SERVICER_LOSSES: BookSpec("6780", "pooled", "servicer", 1, False),
}
CLAIM_BOOKS = frozenset({Book.DEBTOR_RECEIVABLE, Book.OWNER_CLAIM})
# The dedicated-account fund (money_of = client: 5120, 4710, 4670, 4679) and the servicer's fund:
# each closed in every entry, per currency (I2', ADR-0014).
CLIENT_MONEY_BOOKS = frozenset(b for b, spec in BOOKS.items() if spec.money_of == "client")
SERVICER_FUND_BOOKS = frozenset(b for b, spec in BOOKS.items() if spec.money_of == "servicer")
# The only crossing between the funds: 4679 and 4689 mirror each other in every entry (I12).
MIRROR_BOOKS = frozenset({Book.DUE_TO_SERVICER, Book.DUE_FROM_CLIENT_FUNDS})
BANK_BOOKS = frozenset({Book.CLIENT_MONEY_CASH, Book.OWN_CASH})
# Books of one client (the line names it); the other non-claim books are pooled (4710 may name one).
CLIENT_BOOKS = frozenset(
    {
        Book.CLIENT_PAYABLE,
        Book.SERVICER_REVENUE,
        Book.COMMISSION_RECEIVABLE,
        Book.CLIENT_ADVANCE_RECEIVABLE,
    }
)
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
    # M2c: no type touches 1100, 3100 or 4710; 7060 only through the two commission types.
    EntryType.COMMISSION_INVOICE: frozenset(
        {Book.COMMISSION_RECEIVABLE, Book.SERVICER_REVENUE, Book.VAT_PENDING, Book.VAT_COLLECTED}
    ),
    EntryType.COMMISSION_CREDIT_NOTE: frozenset(
        {Book.COMMISSION_RECEIVABLE, Book.SERVICER_REVENUE, Book.VAT_PENDING, Book.VAT_COLLECTED}
    ),
    EntryType.CLIENT_SETTLEMENT: frozenset(
        {
            Book.CLIENT_PAYABLE,
            Book.DUE_TO_SERVICER,
            Book.DUE_FROM_CLIENT_FUNDS,
            Book.COMMISSION_RECEIVABLE,
            Book.CLIENT_ADVANCE_RECEIVABLE,
            Book.VAT_PENDING,
            Book.VAT_COLLECTED,
        }
    ),
    EntryType.REMITTANCE: frozenset({Book.CLIENT_PAYABLE, Book.CLIENT_MONEY_CASH}),
    EntryType.SERVICER_SWEEP: frozenset(
        {Book.DUE_TO_SERVICER, Book.CLIENT_MONEY_CASH, Book.OWN_CASH, Book.DUE_FROM_CLIENT_FUNDS}
    ),
    EntryType.SERVICER_TOP_UP: frozenset(
        {Book.CLIENT_MONEY_CASH, Book.DUE_TO_SERVICER, Book.DUE_FROM_CLIENT_FUNDS, Book.OWN_CASH}
    ),
    EntryType.BANK_FEE: frozenset(
        {Book.DUE_TO_SERVICER, Book.CLIENT_MONEY_CASH, Book.BANK_FEES, Book.DUE_FROM_CLIENT_FUNDS}
    ),
    EntryType.CLIENT_ADVANCE: frozenset(
        {
            Book.DUE_TO_SERVICER,
            Book.CLIENT_PAYABLE,
            Book.CLIENT_ADVANCE_RECEIVABLE,
            Book.DUE_FROM_CLIENT_FUNDS,
        }
    ),
    EntryType.SERVICER_LOSS: frozenset(
        {
            Book.DUE_TO_SERVICER,
            Book.CLIENT_MONEY_CASH,
            Book.SERVICER_LOSSES,
            Book.DUE_FROM_CLIENT_FUNDS,
        }
    ),
    EntryType.CLIENT_PAYMENT_OWN: frozenset(
        {
            Book.OWN_CASH,
            Book.COMMISSION_RECEIVABLE,
            Book.CLIENT_ADVANCE_RECEIVABLE,
            Book.VAT_PENDING,
            Book.VAT_COLLECTED,
        }
    ),
    EntryType.CLIENT_PAYMENT_DEDICATED: frozenset(
        {
            Book.CLIENT_MONEY_CASH,
            Book.DUE_TO_SERVICER,
            Book.DUE_FROM_CLIENT_FUNDS,
            Book.COMMISSION_RECEIVABLE,
            Book.CLIENT_ADVANCE_RECEIVABLE,
            Book.VAT_PENDING,
            Book.VAT_COLLECTED,
        }
    ),
    EntryType.CLIENT_REFUND_OWN: frozenset({Book.COMMISSION_RECEIVABLE, Book.OWN_CASH}),
    EntryType.ADVANCE_WRITE_OFF: frozenset({Book.SERVICER_LOSSES, Book.CLIENT_ADVANCE_RECEIVABLE}),
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
# The M2c entries of the funds, posted only by private.ledger_post_set too.
FUND_ENTRY_TYPES = frozenset(
    {
        EntryType.COMMISSION_INVOICE,
        EntryType.COMMISSION_CREDIT_NOTE,
        EntryType.CLIENT_SETTLEMENT,
        EntryType.REMITTANCE,
        EntryType.SERVICER_SWEEP,
        EntryType.SERVICER_TOP_UP,
        EntryType.BANK_FEE,
        EntryType.CLIENT_ADVANCE,
        EntryType.SERVICER_LOSS,
        EntryType.CLIENT_PAYMENT_OWN,
        EntryType.CLIENT_PAYMENT_DEDICATED,
        EntryType.CLIENT_REFUND_OWN,
        EntryType.ADVANCE_WRITE_OFF,
    }
)
# Each M2c entry names its document (C. com. R123-174): the source types each may name.
FUND_SOURCE_TYPES: Mapping[EntryType, frozenset[str]] = {
    EntryType.COMMISSION_INVOICE: frozenset({"commission_invoice"}),
    EntryType.COMMISSION_CREDIT_NOTE: frozenset({"commission_invoice"}),
    EntryType.CLIENT_SETTLEMENT: frozenset({"remittance_run"}),
    EntryType.REMITTANCE: frozenset({"bank_transfer", "bank_transaction"}),
    EntryType.SERVICER_SWEEP: frozenset({"bank_transfer", "bank_transaction"}),
    EntryType.SERVICER_TOP_UP: frozenset({"bank_transfer", "bank_transaction"}),
    EntryType.BANK_FEE: frozenset({"bank_transaction"}),
    EntryType.CLIENT_ADVANCE: frozenset({"client_advance"}),
    EntryType.SERVICER_LOSS: frozenset({"bank_transaction"}),
    EntryType.CLIENT_PAYMENT_OWN: frozenset({"document"}),
    EntryType.CLIENT_PAYMENT_DEDICATED: frozenset({"bank_transaction"}),
    EntryType.CLIENT_REFUND_OWN: frozenset({"document"}),
    EntryType.ADVANCE_WRITE_OFF: frozenset({"document"}),
}
# Never reversed (a credit note corrects an invoice; a settlement survives a returned payout).
NEVER_REVERSED = frozenset(
    {
        EntryType.CASH_IN,
        EntryType.COMMISSION_INVOICE,
        EntryType.COMMISSION_CREDIT_NOTE,
        EntryType.CLIENT_SETTLEMENT,
        EntryType.ADVANCE_WRITE_OFF,
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
        EntryType.SERVICER_LOSS,
        EntryType.CLIENT_PAYMENT_OWN,
        EntryType.CLIENT_PAYMENT_DEDICATED,
        EntryType.CLIENT_REFUND_OWN,
        EntryType.ADVANCE_WRITE_OFF,
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


class ClientMoneyShortError(LedgerError):
    """A client's 4670 would be in debit at commit: its money would come from another client or
    the servicer (I13). Cover the shortfall first (an advance from the servicer's money)."""

    sqlstate = "LG008"


ERRORS_BY_SQLSTATE: Mapping[str, type[LedgerError]] = {
    "LG000": AppendOnlyError,
    "LG001": UnbalancedEntryError,
    "LG002": ScopeError,
    "LG003": ReversalError,
    "LG004": IdempotencyConflictError,
    "LG005": OpeningMismatchError,
    "LG006": InvalidRequestError,
    "LG007": OverdrawnError,
    "LG008": ClientMoneyShortError,
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

    def _check_dimensions(self) -> None:  # noqa: PLR0912 - one rule per book, as in SQL
        """Which of item, component, client and bank account each book's line carries."""
        if (self.bank_account_id is not None) != (self.book in BANK_BOOKS):
            raise InvalidRequestError("a cash line, and only a cash line, names its bank account")
        if self.book in BANK_BOOKS:
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
            if self.client_organization_id is None and self.book in CLIENT_BOOKS:
                raise InvalidRequestError(f"a {self.book} line names its client")
            if (
                self.client_organization_id is not None
                and self.book not in CLIENT_BOOKS
                and self.book is not Book.UNALLOCATED_PAYMENT
            ):
                raise InvalidRequestError(f"a {self.book} line is pooled (no client)")

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
    """Net movement of the client fund (5120, 4710, 4670, 4679): zero in every entry (I2')."""
    out: dict[str, int] = defaultdict(int)
    for line in lines:
        if line.book in CLIENT_MONEY_BOOKS:
            out[line.currency] += line.amount_minor
    return dict(out)


def servicer_fund_by_currency(lines: Iterable[Line]) -> dict[str, int]:
    """Net movement of the servicer's fund (4689, 5122, 4111, 4112, 4457x, 7060, 6270, 6780):
    zero in every entry (I2')."""
    out: dict[str, int] = defaultdict(int)
    for line in lines:
        if line.book in SERVICER_FUND_BOOKS:
            out[line.currency] += line.amount_minor
    return dict(out)


def mirror_by_currency(lines: Iterable[Line]) -> dict[str, int]:
    """Net movement of 4679 + 4689: zero in every entry (I12), money crosses the funds only so."""
    out: dict[str, int] = defaultdict(int)
    for line in lines:
        if line.book in MIRROR_BOOKS:
            out[line.currency] += line.amount_minor
    return dict(out)


def _counts(lines: list[Line]) -> tuple[dict[Book, int], dict[Book, int]]:
    """Lines per book, and debits per book."""
    n: dict[Book, int] = defaultdict(int)
    d: dict[Book, int] = defaultdict(int)
    for x in lines:
        n[x.book] += 1
        if x.amount_minor > 0:
            d[x.book] += 1
    return n, d


def _vat_pair(n: dict[Book, int], d: dict[Book, int], lines: list[Line]) -> bool:
    """At most one VAT pair, +44574 v / -44571 v (VAT moved from pending to due)."""
    vatp, vatc = Book.VAT_PENDING, Book.VAT_COLLECTED
    moved = sum(x.amount_minor for x in lines if x.book in (vatp, vatc))
    return n[vatp] == n[vatc] <= 1 and d[vatp] == n[vatp] and d[vatc] == 0 and moved == 0


def _settled(n: dict[Book, int], d: dict[Book, int]) -> bool:
    """4111 and 4112 at most once each, at least one of them; an advance is only credited."""
    com, adv = Book.COMMISSION_RECEIVABLE, Book.CLIENT_ADVANCE_RECEIVABLE
    return n[com] <= 1 and n[adv] <= 1 and n[com] + n[adv] >= 1 and d[adv] == 0


# The four-line types: the debit and credit book of each fund, + debit / - credit (§5.2).
_FOUR_LINES: Mapping[EntryType, tuple[Book, Book, Book, Book]] = {
    # debit (client fund), credit (client fund), debit (servicer fund), credit (servicer fund)
    EntryType.SERVICER_SWEEP: (
        Book.DUE_TO_SERVICER,
        Book.CLIENT_MONEY_CASH,
        Book.OWN_CASH,
        Book.DUE_FROM_CLIENT_FUNDS,
    ),
    EntryType.SERVICER_TOP_UP: (
        Book.CLIENT_MONEY_CASH,
        Book.DUE_TO_SERVICER,
        Book.DUE_FROM_CLIENT_FUNDS,
        Book.OWN_CASH,
    ),
    EntryType.BANK_FEE: (
        Book.DUE_TO_SERVICER,
        Book.CLIENT_MONEY_CASH,
        Book.BANK_FEES,
        Book.DUE_FROM_CLIENT_FUNDS,
    ),
    EntryType.CLIENT_ADVANCE: (
        Book.DUE_TO_SERVICER,
        Book.CLIENT_PAYABLE,
        Book.CLIENT_ADVANCE_RECEIVABLE,
        Book.DUE_FROM_CLIENT_FUNDS,
    ),
    EntryType.SERVICER_LOSS: (
        Book.DUE_TO_SERVICER,
        Book.CLIENT_MONEY_CASH,
        Book.SERVICER_LOSSES,
        Book.DUE_FROM_CLIENT_FUNDS,
    ),
}
# The two-line types: (debit book, credit book).
_TWO_LINES: Mapping[EntryType, tuple[Book, Book]] = {
    EntryType.REMITTANCE: (Book.CLIENT_PAYABLE, Book.CLIENT_MONEY_CASH),
    EntryType.CLIENT_REFUND_OWN: (Book.COMMISSION_RECEIVABLE, Book.OWN_CASH),
    EntryType.ADVANCE_WRITE_OFF: (Book.SERVICER_LOSSES, Book.CLIENT_ADVANCE_RECEIVABLE),
}


def has_fund_shape(entry_type: EntryType, lines: Iterable[Line]) -> bool:  # noqa: PLR0911
    """I3': the shape of an M2c entry, as the database checks it (one currency)."""
    ls = list(lines)
    if len({x.currency for x in ls}) != 1:
        return False
    n, d = _counts(ls)
    total = len(ls)
    com, rev = Book.COMMISSION_RECEIVABLE, Book.SERVICER_REVENUE
    vatp, vatc, adv = Book.VAT_PENDING, Book.VAT_COLLECTED, Book.CLIENT_ADVANCE_RECEIVABLE
    pay, dts, dfc = Book.CLIENT_PAYABLE, Book.DUE_TO_SERVICER, Book.DUE_FROM_CLIENT_FUNDS
    cash, own = Book.CLIENT_MONEY_CASH, Book.OWN_CASH
    if entry_type in _FOUR_LINES:
        books = _FOUR_LINES[entry_type]
        return (
            total == 4 and all(n[b] == 1 for b in books) and [d[b] for b in books] == [1, 0, 1, 0]
        )
    if entry_type in _TWO_LINES:
        dr, cr = _TWO_LINES[entry_type]
        return total == 2 and n[dr] == 1 and d[dr] == 1 and n[cr] == 1 and d[cr] == 0
    if entry_type is EntryType.COMMISSION_INVOICE:
        return (
            n[com] == d[com] == 1
            and n[rev] == 1
            and d[rev] == 0
            and n[vatp] + n[vatc] <= 1
            and d[vatp] == d[vatc] == 0
            and total == 2 + n[vatp] + n[vatc]
        )
    if entry_type is EntryType.COMMISSION_CREDIT_NOTE:
        return (
            n[com] == 1
            and d[com] == 0
            and n[rev] == d[rev] == 1
            and n[vatp] <= 1
            and n[vatc] <= 1
            and d[vatp] == n[vatp]
            and d[vatc] == n[vatc]
            and total == 2 + n[vatp] + n[vatc]
        )
    if entry_type is EntryType.CLIENT_SETTLEMENT:
        return (
            n[pay] == n[dts] == n[dfc] == 1
            and _settled(n, d)
            and _vat_pair(n, d, ls)
            and total == 3 + n[com] + n[adv] + n[vatp] + n[vatc]
        )
    if entry_type is EntryType.CLIENT_PAYMENT_OWN:
        return (
            n[own] == d[own] == 1
            and _settled(n, d)
            and d[com] == 0
            and _vat_pair(n, d, ls)
            and total == 1 + n[com] + n[adv] + n[vatp] + n[vatc]
        )
    if entry_type is EntryType.CLIENT_PAYMENT_DEDICATED:
        return (
            n[cash] == d[cash] == 1
            and n[dts] == 1
            and d[dts] == 0
            and n[dfc] == d[dfc] == 1
            and _settled(n, d)
            and d[com] == 0
            and _vat_pair(n, d, ls)
            and total == 3 + n[com] + n[adv] + n[vatp] + n[vatc]
        )
    return False


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
            # the debt goes down by exactly the money allocated
            and sum(x.amount_minor for x in ls if x.book is rec)
            == -sum(x.amount_minor for x in ls if x.book is pool)
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
        if t not in PAYMENT_ENTRY_TYPES | FUND_ENTRY_TYPES:
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
        client_lines = any(x.book in CLIENT_BOOKS for x in self.lines)
        if self.client_organization_id is not None and (
            t in (EntryType.ALLOCATION, EntryType.NETTING) or not client_lines
        ):
            raise InvalidRequestError("only entries with client lines and no account name a client")
        if t in FUND_ENTRY_TYPES and (
            self.source_type not in FUND_SOURCE_TYPES[t] or not self.source_id
        ):
            raise InvalidRequestError(f"a {t} entry names its document")
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
        if any(servicer_fund_by_currency(self.lines).values()):
            raise UnbalancedEntryError("the servicer's fund left open (closure)")
        if any(mirror_by_currency(self.lines).values()):
            raise UnbalancedEntryError("4679 and 4689 do not mirror each other")
        if t in FUND_ENTRY_TYPES:
            if not has_fund_shape(t, self.lines):
                raise UnbalancedEntryError(f"not the shape of a {t} entry")
        elif not has_payment_shape(t, self.lines):
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
