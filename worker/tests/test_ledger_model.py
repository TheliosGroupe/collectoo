"""Ledger model (M2-04), pure: entry rules and property tests against the in-memory oracle."""

from dataclasses import replace
from datetime import date
from decimal import Decimal
from typing import Any
from uuid import uuid4

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from ledger_machine import CLIENT, ITEMS, LedgerMachine, drafts

from collectoo_worker.ledger import (
    Book,
    Component,
    EntryDraft,
    EntryType,
    InvalidRequestError,
    Line,
    MirrorBrokenError,
    ScopeError,
    UnbalancedEntryError,
    balance_by_currency,
    mirror,
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


def test_entry_rules() -> None:
    base = EntryDraft(
        organization_id=uuid4(),
        entry_type=EntryType.ADJUSTMENT,
        effective_date=date(2026, 3, 1),
        idempotency_key="entry-rules-1",
        lines=(
            Line(Book.UNALLOCATED_PAYMENT, 100, "EUR"),
            Line(Book.CLIENT_PAYABLE, -100, "EUR", client_organization_id=CLIENT),
        ),
        reason="test",
    )
    base.validate()
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
        replace(
            base,
            lines=(
                Line(Book.DEBTOR_RECEIVABLE, 100, "EUR", ITEMS[0], Component.PRINCIPAL),
                Line(Book.OWNER_CLAIM, -100, "EUR", component=Component.PRINCIPAL),
            ),
        ).validate()  # claim lines without the account


TestLedgerMachine = LedgerMachine.TestCase
TestLedgerMachine.settings = settings(max_examples=60, stateful_step_count=25, deadline=None)
