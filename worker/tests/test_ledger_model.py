"""Ledger model (M2-04), pure: entry rules and property tests against the in-memory oracle."""

from dataclasses import replace
from datetime import date
from decimal import Decimal
from typing import Any
from uuid import uuid4

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from ledger_machine import ACCOUNT, BANK, CLIENT, ITEMS, ORG, OWN, LedgerMachine, drafts

from collectoo_worker.ledger import (
    Book,
    ClientMoneyShortError,
    Component,
    EntryDraft,
    EntryType,
    InvalidRequestError,
    Line,
    MirrorBrokenError,
    OverdrawnError,
    ScopeError,
    UnbalancedEntryError,
    balance_by_currency,
    from_db_error,
    mirror,
)
from collectoo_worker.ledger.model import (
    ALLOWED_BOOKS,
    BOOKS,
    CLIENT_MONEY_BOOKS,
    FUND_ENTRY_TYPES,
    FUND_SOURCE_TYPES,
    MIRROR_BOOKS,
    PAYMENT_ENTRY_TYPES,
    SERVICER_FUND_BOOKS,
    has_fund_shape,
)


@given(drafts())
def test_generated_drafts_are_valid(draft: EntryDraft) -> None:
    draft.validate()


@given(drafts(), st.integers(min_value=1, max_value=10**6), st.data())
def test_changing_one_amount_unbalances_the_entry(draft: EntryDraft, k: int, data: Any) -> None:
    i = data.draw(st.integers(min_value=0, max_value=len(draft.lines) - 1))
    line = draft.lines[i]
    bumped = line.amount_minor + k if line.amount_minor + k != 0 else line.amount_minor + k + 1
    lines = (*draft.lines[:i], replace(line, amount_minor=bumped), *draft.lines[i + 1 :])
    with pytest.raises(UnbalancedEntryError):
        replace(draft, lines=lines).validate()


@given(drafts())
def test_moving_an_owner_claim_line_to_another_component_breaks_the_mirror(
    draft: EntryDraft,
) -> None:
    owner = [i for i, line in enumerate(draft.lines) if line.book is Book.OWNER_CLAIM]
    if not owner:
        return
    i = owner[0]
    line = draft.lines[i]
    other = next(c for c in Component if c != line.component)
    lines = (*draft.lines[:i], replace(line, component=other), *draft.lines[i + 1 :])
    totals: dict[tuple[str, str], int] = {}
    for x in lines:
        if x.book in (Book.DEBTOR_RECEIVABLE, Book.OWNER_CLAIM):
            key = (str(x.component), x.currency)
            totals[key] = totals.get(key, 0) + x.amount_minor
    if all(v == 0 for v in totals.values()):
        return  # the move happened to keep every component balanced
    with pytest.raises(MirrorBrokenError):
        replace(draft, lines=lines).validate()


@given(drafts())
def test_mirror_negates_every_line_and_cancels_out(draft: EntryDraft) -> None:
    mirrored = mirror(draft.lines)
    assert [m.amount_minor for m in mirrored] == [-line.amount_minor for line in draft.lines]
    assert [replace(m, amount_minor=-m.amount_minor) for m in mirrored] == list(draft.lines)
    assert all(v == 0 for v in balance_by_currency(draft.lines + mirrored).values())


@pytest.mark.parametrize("amount", [True, 1.0, Decimal(1), 0, 10**15 + 1])
def test_amounts_are_non_zero_python_ints(amount: Any) -> None:
    with pytest.raises(InvalidRequestError):
        Line(Book.UNALLOCATED_PAYMENT, amount, "EUR")


def test_line_shapes() -> None:
    with pytest.raises(InvalidRequestError):
        Line(Book.DEBTOR_RECEIVABLE, 100, "EUR")  # no item
    with pytest.raises(InvalidRequestError):
        Line(Book.OWNER_CLAIM, 100, "EUR", claim_item_id=ITEMS[0], component=Component.PRINCIPAL)
    with pytest.raises(InvalidRequestError):
        Line(Book.CLIENT_PAYABLE, 100, "EUR")  # no client
    with pytest.raises(InvalidRequestError):
        Line(Book.UNALLOCATED_PAYMENT, 100, "eur")
    with pytest.raises(InvalidRequestError):
        Line(Book.CLIENT_MONEY_CASH, 100, "EUR")  # no bank account
    with pytest.raises(InvalidRequestError):
        Line(Book.UNALLOCATED_PAYMENT, 100, "EUR", bank_account_id=BANK)
    with pytest.raises(InvalidRequestError):
        Line(
            Book.CLIENT_MONEY_CASH, 100, "EUR", client_organization_id=CLIENT, bank_account_id=BANK
        )
    assert Line(Book.CLIENT_MONEY_CASH, 100, "EUR", bank_account_id=BANK).as_json() == {
        "book": "client_money_cash",
        "amount_minor": 100,
        "currency": "EUR",
        "bank_account_id": str(BANK),
    }


def test_entry_rules() -> None:
    base = EntryDraft(
        organization_id=uuid4(),
        entry_type=EntryType.ADJUSTMENT,
        effective_date=date(2026, 3, 1),
        idempotency_key="entry-rules-1",
        lines=(
            Line(Book.DEBTOR_RECEIVABLE, 100, "EUR", ITEMS[0], Component.PRINCIPAL),
            Line(Book.OWNER_CLAIM, -100, "EUR", component=Component.PRINCIPAL),
        ),
        account_id=ACCOUNT,
        reason="test",
    )
    base.validate()
    with pytest.raises(ScopeError):  # M2b: client money never moves through a correction
        replace(
            base,
            lines=(
                Line(Book.UNALLOCATED_PAYMENT, 100, "EUR"),
                Line(Book.CLIENT_PAYABLE, -100, "EUR", client_organization_id=CLIENT),
            ),
            account_id=None,
        ).validate()
    with pytest.raises(InvalidRequestError):  # payment entries go through ledger_post_set
        replace(base, entry_type=EntryType.NETTING).validate()
    with pytest.raises(InvalidRequestError):
        replace(base, reason=" ").validate()
    with pytest.raises(InvalidRequestError):
        replace(base, entry_type=EntryType.OPENING).validate()
    with pytest.raises(InvalidRequestError):
        replace(base, idempotency_key="short").validate()
    with pytest.raises(ScopeError):
        replace(
            base,
            lines=(
                Line(Book.CLIENT_PAYABLE, 100, "EUR", client_organization_id=CLIENT),
                Line(Book.SERVICER_REVENUE, -100, "EUR", client_organization_id=CLIENT),
            ),
        ).validate()
    with pytest.raises(ScopeError):
        replace(
            base,
            lines=(
                Line(Book.CLIENT_PAYABLE, 100, "EUR", client_organization_id=CLIENT),
                Line(Book.CLIENT_PAYABLE, -100, "EUR", client_organization_id=uuid4()),
            ),
        ).validate()
    with pytest.raises(InvalidRequestError):
        replace(base, account_id=None).validate()  # claim lines without the account


PAYMENT = uuid4()


SET_DEFAULTS: dict[EntryType, dict[str, Any]] = {
    EntryType.CASH_IN: {"source_type": "bank_statement", "source_id": "stmt-1"},
    EntryType.ALLOCATION: {"account_id": ACCOUNT, "payment_id": PAYMENT},
    EntryType.FORWARD: {"payment_id": PAYMENT, "client_organization_id": CLIENT, "reason": "x"},
    EntryType.CASH_OUT: {"payment_id": PAYMENT, "reason": "refund"},
    EntryType.NETTING: {"account_id": ACCOUNT, "reason": "credit note"},
}


def _set(entry_type: EntryType, *lines: Line, **kw: Any) -> EntryDraft:
    defaults = SET_DEFAULTS[entry_type]
    return EntryDraft(
        organization_id=ORG,
        entry_type=entry_type,
        effective_date=date(2026, 3, 1),
        idempotency_key="payment-entry-1",
        lines=lines,
        **{**defaults, **kw},
    )


POOL_DR = Line(Book.UNALLOCATED_PAYMENT, 100, "EUR")
POOL_CR = Line(Book.UNALLOCATED_PAYMENT, -100, "EUR")
CASH_DR = Line(Book.CLIENT_MONEY_CASH, 100, "EUR", bank_account_id=BANK)
CASH_CR = Line(Book.CLIENT_MONEY_CASH, -100, "EUR", bank_account_id=BANK)
PAY_CR = Line(Book.CLIENT_PAYABLE, -100, "EUR", client_organization_id=CLIENT)
REC_CR = Line(Book.DEBTOR_RECEIVABLE, -100, "EUR", ITEMS[0], Component.PRINCIPAL)
OWN_DR = Line(Book.OWNER_CLAIM, 100, "EUR", component=Component.PRINCIPAL)
VALID = {
    EntryType.CASH_IN: (CASH_DR, POOL_CR),
    EntryType.ALLOCATION: (POOL_DR, PAY_CR, REC_CR, OWN_DR),
    EntryType.FORWARD: (POOL_DR, PAY_CR),
    EntryType.CASH_OUT: (POOL_DR, CASH_CR),
    EntryType.NETTING: (REC_CR.negated(), replace(REC_CR, claim_item_id=ITEMS[1])),
}


@pytest.mark.parametrize("entry_type", sorted(VALID))
def test_payment_entries_of_the_design_validate(entry_type: EntryType) -> None:
    draft = _set(entry_type, *VALID[entry_type])
    draft.validate_set()
    assert all(v == 0 for v in balance_by_currency(draft.lines).values())
    with pytest.raises(InvalidRequestError):
        draft.validate()  # never through ledger_post


def test_payment_entry_rules() -> None:
    assert frozenset(VALID) == PAYMENT_ENTRY_TYPES
    assert {
        Book.CLIENT_MONEY_CASH,
        Book.UNALLOCATED_PAYMENT,
        Book.CLIENT_PAYABLE,
        Book.DUE_TO_SERVICER,  # M2c: the servicer's money on the dedicated account
    } == CLIENT_MONEY_BOOKS
    assert all(Book.SERVICER_REVENUE not in ALLOWED_BOOKS[t] for t in PAYMENT_ENTRY_TYPES)
    with pytest.raises(InvalidRequestError):  # an allocation names its payment
        _set(EntryType.ALLOCATION, *VALID[EntryType.ALLOCATION], payment_id=None).validate_set()
    with pytest.raises(InvalidRequestError):  # a cash_in names its statement
        _set(EntryType.CASH_IN, *VALID[EntryType.CASH_IN], source_id=None).validate_set()
    with pytest.raises(InvalidRequestError):  # a refund needs a reason
        _set(EntryType.CASH_OUT, *VALID[EntryType.CASH_OUT], reason=None).validate_set()
    with pytest.raises(InvalidRequestError):  # unallocated money is pooled
        _set(
            EntryType.CASH_IN, CASH_DR, replace(POOL_CR, client_organization_id=CLIENT)
        ).validate_set()
    with pytest.raises(ScopeError):  # 7060 is reached by no payment entry (M2-12)
        _set(
            EntryType.FORWARD,
            POOL_DR,
            Line(Book.SERVICER_REVENUE, -100, "EUR", client_organization_id=CLIENT),
        ).validate_set()
    with pytest.raises(UnbalancedEntryError):  # an allocation only credits receivables
        _set(
            EntryType.ALLOCATION,
            POOL_DR,
            PAY_CR,
            replace(REC_CR, amount_minor=-200),
            replace(REC_CR, claim_item_id=ITEMS[1], amount_minor=100),
            OWN_DR,
        ).validate_set()
    with pytest.raises(UnbalancedEntryError):  # the debt goes down by the money allocated
        _set(
            EntryType.ALLOCATION,
            POOL_DR,
            PAY_CR,
            replace(REC_CR, amount_minor=REC_CR.amount_minor + 1),  # a rounding gap of 1 cent
            replace(OWN_DR, amount_minor=OWN_DR.amount_minor - 1),
        ).validate_set()
    with pytest.raises(UnbalancedEntryError):  # a cash_in is one debit and one credit
        _set(
            EntryType.CASH_IN,
            replace(CASH_DR, amount_minor=200),
            POOL_CR,
            POOL_CR,
        ).validate_set()
    with pytest.raises(UnbalancedEntryError):  # a netting is on principal only
        _set(
            EntryType.NETTING,
            replace(REC_CR, component=Component.ACCRUED_INTEREST).negated(),
            replace(REC_CR, claim_item_id=ITEMS[1], component=Component.ACCRUED_INTEREST),
        ).validate_set()


class _DbError(Exception):
    def __init__(self, sqlstate: str) -> None:
        super().__init__(f"ledger: {sqlstate}")
        self.sqlstate = sqlstate


def test_lg007_is_an_overdraft() -> None:
    mapped = from_db_error(_DbError("LG007"))  # type: ignore[arg-type]
    assert isinstance(mapped, OverdrawnError)


def test_lg008_is_client_money_short() -> None:
    mapped = from_db_error(_DbError("LG008"))  # type: ignore[arg-type]
    assert isinstance(mapped, ClientMoneyShortError)


# --- M2c: the funds (design m2c-remittances §5) -------------------------------------------------


def _l(book: Book, amount: int, *, bank: bool = False) -> Line:
    client = (
        CLIENT
        if book
        in (
            Book.CLIENT_PAYABLE,
            Book.SERVICER_REVENUE,
            Book.COMMISSION_RECEIVABLE,
            Book.CLIENT_ADVANCE_RECEIVABLE,
        )
        else None
    )
    bank_id = None
    if book is Book.CLIENT_MONEY_CASH:
        bank_id = BANK
    elif book is Book.OWN_CASH:
        bank_id = OWN
    return Line(book, amount, "EUR", client_organization_id=client, bank_account_id=bank_id)


B = Book
# The §7.2 worked example's entries (EUR, minor units), one per type.
FUND_VALID: dict[EntryType, tuple[Line, ...]] = {
    EntryType.COMMISSION_INVOICE: (
        _l(B.COMMISSION_RECEIVABLE, 36000),
        _l(B.SERVICER_REVENUE, -30000),
        _l(B.VAT_PENDING, -6000),
    ),
    EntryType.COMMISSION_CREDIT_NOTE: (
        _l(B.COMMISSION_RECEIVABLE, -36000),
        _l(B.SERVICER_REVENUE, 30000),
        _l(B.VAT_COLLECTED, 6000),
    ),
    EntryType.CLIENT_SETTLEMENT: (
        _l(B.CLIENT_PAYABLE, 218000),
        _l(B.DUE_TO_SERVICER, -218000),
        _l(B.DUE_FROM_CLIENT_FUNDS, 218000),
        _l(B.COMMISSION_RECEIVABLE, -18000),
        _l(B.CLIENT_ADVANCE_RECEIVABLE, -200000),
        _l(B.VAT_PENDING, 9000),
        _l(B.VAT_COLLECTED, -9000),
    ),
    EntryType.REMITTANCE: (_l(B.CLIENT_PAYABLE, 82000), _l(B.CLIENT_MONEY_CASH, -82000)),
    EntryType.SERVICER_SWEEP: (
        _l(B.DUE_TO_SERVICER, 218000),
        _l(B.CLIENT_MONEY_CASH, -218000),
        _l(B.OWN_CASH, 218000),
        _l(B.DUE_FROM_CLIENT_FUNDS, -218000),
    ),
    EntryType.SERVICER_TOP_UP: (
        _l(B.CLIENT_MONEY_CASH, 200000),
        _l(B.DUE_TO_SERVICER, -200000),
        _l(B.DUE_FROM_CLIENT_FUNDS, 200000),
        _l(B.OWN_CASH, -200000),
    ),
    EntryType.BANK_FEE: (
        _l(B.DUE_TO_SERVICER, 1200),
        _l(B.CLIENT_MONEY_CASH, -1200),
        _l(B.BANK_FEES, 1200),
        _l(B.DUE_FROM_CLIENT_FUNDS, -1200),
    ),
    EntryType.CLIENT_ADVANCE: (
        _l(B.DUE_TO_SERVICER, 200000),
        _l(B.CLIENT_PAYABLE, -200000),
        _l(B.CLIENT_ADVANCE_RECEIVABLE, 200000),
        _l(B.DUE_FROM_CLIENT_FUNDS, -200000),
    ),
    EntryType.SERVICER_LOSS: (
        _l(B.DUE_TO_SERVICER, 500),
        _l(B.CLIENT_MONEY_CASH, -500),
        _l(B.SERVICER_LOSSES, 500),
        _l(B.DUE_FROM_CLIENT_FUNDS, -500),
    ),
    EntryType.CLIENT_PAYMENT_OWN: (
        _l(B.OWN_CASH, 236000),
        _l(B.COMMISSION_RECEIVABLE, -36000),
        _l(B.CLIENT_ADVANCE_RECEIVABLE, -200000),
        _l(B.VAT_PENDING, 6000),
        _l(B.VAT_COLLECTED, -6000),
    ),
    EntryType.CLIENT_PAYMENT_DEDICATED: (
        _l(B.CLIENT_MONEY_CASH, 36000),
        _l(B.DUE_TO_SERVICER, -36000),
        _l(B.DUE_FROM_CLIENT_FUNDS, 36000),
        _l(B.COMMISSION_RECEIVABLE, -36000),
    ),
    EntryType.CLIENT_REFUND_OWN: (_l(B.COMMISSION_RECEIVABLE, 36000), _l(B.OWN_CASH, -36000)),
    EntryType.ADVANCE_WRITE_OFF: (
        _l(B.SERVICER_LOSSES, 200000),
        _l(B.CLIENT_ADVANCE_RECEIVABLE, -200000),
    ),
}
CLIENT_TYPES = frozenset(
    t for t, lines in FUND_VALID.items() if any(x.client_organization_id is not None for x in lines)
)


def _fund(entry_type: EntryType, lines: tuple[Line, ...], **kw: Any) -> EntryDraft:
    defaults: dict[str, Any] = {
        "source_type": sorted(FUND_SOURCE_TYPES[entry_type])[0],
        "source_id": "doc-1",
        "reason": "x",
        "client_organization_id": CLIENT if entry_type in CLIENT_TYPES else None,
    }
    return EntryDraft(
        organization_id=ORG,
        entry_type=entry_type,
        effective_date=date(2026, 3, 1),
        idempotency_key="fund-entry-1",
        lines=lines,
        **{**defaults, **kw},
    )


def test_python_books_and_types_cover_the_funds() -> None:
    assert frozenset(FUND_VALID) == FUND_ENTRY_TYPES == frozenset(FUND_SOURCE_TYPES)
    assert {b for b, s in BOOKS.items() if s.money_of == "servicer"} == SERVICER_FUND_BOOKS
    assert MIRROR_BOOKS <= CLIENT_MONEY_BOOKS | SERVICER_FUND_BOOKS
    claims_or_pool = {Book.DEBTOR_RECEIVABLE, Book.OWNER_CLAIM, Book.UNALLOCATED_PAYMENT}
    assert all(not (ALLOWED_BOOKS[t] & claims_or_pool) for t in FUND_ENTRY_TYPES)
    revenue = {t for t, books in ALLOWED_BOOKS.items() if Book.SERVICER_REVENUE in books}
    assert revenue == {EntryType.COMMISSION_INVOICE, EntryType.COMMISSION_CREDIT_NOTE}
    servicer_or_share = SERVICER_FUND_BOOKS | {Book.DUE_TO_SERVICER}
    assert all(not (ALLOWED_BOOKS[t] & servicer_or_share) for t in PAYMENT_ENTRY_TYPES)


@pytest.mark.parametrize("entry_type", sorted(FUND_VALID))
def test_fund_entries_of_the_design_validate(entry_type: EntryType) -> None:
    draft = _fund(entry_type, FUND_VALID[entry_type])
    draft.validate_set()
    with pytest.raises(InvalidRequestError):
        draft.validate()  # never through ledger_post


@pytest.mark.parametrize("entry_type", sorted(FUND_VALID))
def test_a_fund_entry_with_its_signs_flipped_is_refused(entry_type: EntryType) -> None:
    """Balanced, each fund closed, the mirror kept, but of the wrong shape (I3')."""
    flipped = mirror(FUND_VALID[entry_type])
    assert not has_fund_shape(entry_type, flipped)
    with pytest.raises(UnbalancedEntryError):
        _fund(entry_type, flipped).validate_set()


def test_fund_entry_rules() -> None:
    fee = FUND_VALID[EntryType.BANK_FEE]
    with pytest.raises(UnbalancedEntryError):  # 4679 without 4689: the mirror (I12)
        _fund(EntryType.BANK_FEE, fee[:2]).validate_set()
    with pytest.raises(ScopeError):  # Dr 4670 / Cr 7060: collections never reach 7060 (M2-12)
        _fund(
            EntryType.COMMISSION_INVOICE,
            (_l(B.CLIENT_PAYABLE, 100), _l(B.SERVICER_REVENUE, -100)),
        ).validate_set()
    with pytest.raises(InvalidRequestError):  # a fee concerns no client
        _fund(EntryType.BANK_FEE, fee, client_organization_id=CLIENT).validate_set()
    with pytest.raises(InvalidRequestError):  # each entry names its document (R123-174)
        _fund(EntryType.BANK_FEE, fee, source_type="document").validate_set()
    with pytest.raises(InvalidRequestError):  # a loss needs its motif
        _fund(
            EntryType.SERVICER_LOSS, FUND_VALID[EntryType.SERVICER_LOSS], reason=None
        ).validate_set()
    with pytest.raises(InvalidRequestError):  # 5122 names its bank account; 4679 is pooled
        Line(Book.OWN_CASH, 100, "EUR")
    with pytest.raises(InvalidRequestError):
        Line(Book.DUE_TO_SERVICER, 100, "EUR", client_organization_id=CLIENT)


@given(st.sampled_from(sorted(FUND_VALID)), st.integers(min_value=1, max_value=10**9))
def test_fund_shapes_hold_at_any_scale(entry_type: EntryType, k: int) -> None:
    """Shapes are about books and signs: every amount scaled by k keeps the entry valid."""
    lines = tuple(replace(x, amount_minor=x.amount_minor * k) for x in FUND_VALID[entry_type])
    if any(abs(x.amount_minor) > 10**15 for x in lines):
        return
    _fund(entry_type, lines).validate_set()


TestLedgerMachine = LedgerMachine.TestCase
TestLedgerMachine.settings = settings(max_examples=100, stateful_step_count=50, deadline=None)
