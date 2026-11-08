"""Ledger model (M2-04), pure: entry rules and property tests against the in-memory oracle."""

from dataclasses import replace
from datetime import date
from decimal import Decimal
from typing import Any
from uuid import uuid4

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from ledger_machine import ACCOUNT, BANK, CLIENT, ITEMS, ORG, LedgerMachine, drafts

from collectoo_worker.ledger import (
    Book,
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
from collectoo_worker.ledger.model import ALLOWED_BOOKS, CLIENT_MONEY_BOOKS, PAYMENT_ENTRY_TYPES


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


TestLedgerMachine = LedgerMachine.TestCase
TestLedgerMachine.settings = settings(max_examples=100, stateful_step_count=50, deadline=None)
