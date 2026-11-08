"""Shared ledger property-test machinery (M2-04).

`InMemoryLedger` is an oracle with the database's rules. `LedgerMachine` drives random posts and
reversals (with forced idempotency-key collisions) against a backend and checks the invariants
after every step. The pure test runs it against the oracle; the integration test runs it against
Postgres and compares balances with the oracle.
"""

from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date
from typing import Any, Protocol
from uuid import UUID, uuid4

from hypothesis import strategies as st
from hypothesis.stateful import Bundle, RuleBasedStateMachine, invariant, rule

from collectoo_worker.ledger import (
    AlreadyReversedError,
    Book,
    Component,
    EntryDraft,
    EntryType,
    IdempotencyConflictError,
    Line,
    PostResult,
    ReversalError,
    balance_by_currency,
    mirror,
)

ORG = UUID("00000000-0000-0000-0000-0000000000f0")
CLIENT = UUID("00000000-0000-0000-0000-0000000000f1")
ACCOUNT = UUID("30000000-0000-0000-0000-0000000000f1")
ITEMS = (UUID("40000000-0000-0000-0000-0000000000f1"), UUID("40000000-0000-0000-0000-0000000000f2"))
DATES = (date(2026, 2, 1), date(2026, 3, 1), date(2026, 4, 1))
KEYS = tuple(f"prop-key-{i:04d}" for i in range(8))

# A ledger "dimension": what identifies a ledger account inside one tenant.
Dim = tuple[str, str, str | None, str | None, str | None]  # book, currency, item, component, client


def dim(line: Line) -> Dim:
    client = None
    if line.book in (Book.DEBTOR_RECEIVABLE, Book.OWNER_CLAIM):
        client = str(CLIENT)
    elif line.client_organization_id is not None:
        client = str(line.client_organization_id)
    return (
        str(line.book),
        line.currency,
        str(line.claim_item_id) if line.claim_item_id else None,
        str(line.component) if line.component else None,
        client,
    )


def request_hash(draft: EntryDraft) -> str:
    payload = {
        "type": str(draft.entry_type),
        "date": draft.effective_date.isoformat(),
        "account": str(draft.account_id),
        "reason": draft.reason,
        "lines": sorted([list(map(str, dim(line))), line.amount_minor] for line in draft.lines),
    }
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


@dataclass
class Entry:
    id: UUID
    effective_date: date
    lines: tuple[Line, ...]
    reverses: UUID | None = None


@dataclass
class InMemoryLedger:
    entries: dict[UUID, Entry] = field(default_factory=dict)
    by_key: dict[str, tuple[UUID, str]] = field(default_factory=dict)
    reversed_by: dict[UUID, UUID] = field(default_factory=dict)

    def post(self, draft: EntryDraft) -> PostResult:
        draft.validate()
        h = request_hash(draft)
        if draft.idempotency_key in self.by_key:
            entry_id, existing = self.by_key[draft.idempotency_key]
            if existing != h:
                raise IdempotencyConflictError(draft.idempotency_key)
            return PostResult(entry_id, False)
        entry = Entry(uuid4(), draft.effective_date, draft.lines)
        self.entries[entry.id] = entry
        self.by_key[draft.idempotency_key] = (entry.id, h)
        return PostResult(entry.id, True)

    def reverse(self, entry_id: UUID, key: str, when: date | None) -> PostResult:
        target = self.entries[entry_id]
        if key in self.by_key:
            existing_id, existing_hash = self.by_key[key]
            if existing_hash == f"reversal:{entry_id}":
                return PostResult(existing_id, False)
            raise IdempotencyConflictError(key)
        if target.reverses is not None:
            raise ReversalError("a reversal is not reversed")
        effective = when or target.effective_date
        if effective < target.effective_date:
            raise ReversalError("reversal dated before the entry")
        if entry_id in self.reversed_by:
            raise AlreadyReversedError(str(entry_id))
        entry = Entry(uuid4(), effective, mirror(target.lines), reverses=entry_id)
        self.entries[entry.id] = entry
        self.by_key[key] = (entry.id, f"reversal:{entry_id}")
        self.reversed_by[entry_id] = entry.id
        return PostResult(entry.id, True)

    def balances(self, as_of: date) -> dict[Dim, int]:
        out: dict[Dim, int] = defaultdict(int)
        for entry in self.entries.values():
            if entry.effective_date <= as_of:
                for line in entry.lines:
                    out[dim(line)] += line.amount_minor
        return {k: v for k, v in out.items() if v}


class Backend(Protocol):
    def post(self, draft: EntryDraft) -> PostResult: ...

    def reverse(self, entry_id: UUID, key: str, when: date | None) -> PostResult: ...

    def balances(self, as_of: date) -> dict[Dim, int]: ...

    def entry_lines(self) -> dict[UUID, list[tuple[str, int]]]: ...

    def check(self) -> None: ...


class OracleBackend:
    def __init__(self) -> None:
        self.ledger = InMemoryLedger()

    def post(self, draft: EntryDraft) -> PostResult:
        return self.ledger.post(draft)

    def reverse(self, entry_id: UUID, key: str, when: date | None) -> PostResult:
        return self.ledger.reverse(entry_id, key, when)

    def balances(self, as_of: date) -> dict[Dim, int]:
        return self.ledger.balances(as_of)

    def entry_lines(self) -> dict[UUID, list[tuple[str, int]]]:
        return {
            e.id: [(line.currency, line.amount_minor) for line in e.lines]
            for e in self.ledger.entries.values()
        }

    def check(self) -> None:
        return None


amounts = st.integers(min_value=-1_000_000, max_value=1_000_000).filter(bool)


@st.composite
def drafts(draw: st.DrawFn, key: str | None = None) -> EntryDraft:
    """Balanced adjustments: receivable/owner-claim pairs and/or client-money pairs."""
    lines: list[Line] = []
    with_claims = draw(st.booleans())
    if with_claims:
        moves = draw(
            st.lists(
                st.tuples(st.sampled_from(ITEMS), st.sampled_from(list(Component)), amounts),
                min_size=1,
                max_size=4,
            )
        )
        per_component: dict[Component, int] = defaultdict(int)
        for item, component, amount in moves:
            lines.append(Line(Book.DEBTOR_RECEIVABLE, amount, "EUR", item, component))
            per_component[component] += amount
        lines += [
            Line(Book.OWNER_CLAIM, -amount, "EUR", component=component)
            for component, amount in per_component.items()
            if amount
        ]
    if not with_claims or len(lines) < 2 or draw(st.booleans()):
        amount = draw(amounts)
        currency = draw(st.sampled_from(["EUR", "USD"]))
        lines += [
            Line(Book.UNALLOCATED_PAYMENT, amount, currency),
            Line(Book.CLIENT_PAYABLE, -amount, currency, client_organization_id=CLIENT),
        ]
    has_claim = any(line.book in (Book.DEBTOR_RECEIVABLE, Book.OWNER_CLAIM) for line in lines)
    return EntryDraft(
        organization_id=ORG,
        entry_type=EntryType.ADJUSTMENT,
        effective_date=draw(st.sampled_from(DATES)),
        idempotency_key=key or draw(st.sampled_from(KEYS)),
        lines=tuple(draw(st.permutations(lines))),
        account_id=ACCOUNT if has_claim else None,
        reason="property test",
    )


class LedgerMachine(RuleBasedStateMachine):
    """Random posts and reversals; invariants hold after every step."""

    backend: Backend
    oracle: InMemoryLedger

    entries = Bundle("entries")

    def __init__(self) -> None:
        super().__init__()
        self.backend = self.make_backend()
        self.oracle = InMemoryLedger()
        self.keys_ok: set[str] = set()
        self.ids: dict[UUID, UUID] = {}  # backend id -> oracle id

    def make_backend(self) -> Backend:
        return OracleBackend()

    def _same(self, f: Any, g: Any) -> tuple[Any, Any]:
        """Run on the backend and the oracle: same outcome (result or exception class)."""
        try:
            got = f()
        except Exception as exc:
            got = exc
        try:
            want = g()
        except Exception as exc:
            want = exc
        if isinstance(want, Exception):
            assert isinstance(got, type(want)), (got, want)
        else:
            assert not isinstance(got, Exception), (got, want)
            assert got.created == want.created
        return got, want

    @rule(target=entries, draft=drafts())
    def post(self, draft: EntryDraft) -> Any:
        got, want = self._same(lambda: self.backend.post(draft), lambda: self.oracle.post(draft))
        self.backend.check()
        if isinstance(got, Exception):
            return None
        self.keys_ok.add(draft.idempotency_key)
        self.ids[got.entry_id] = want.entry_id
        return got.entry_id

    @rule(target=entries, entry=entries, fresh=st.booleans(), when=st.sampled_from([None, *DATES]))
    def reverse(self, entry: UUID | None, fresh: bool, when: date | None) -> Any:
        if entry is None:
            return None
        key = f"reversal-{entry}"[:40] if not fresh else f"rev-{uuid4()}"
        oracle_id = self.ids[entry]
        got, want = self._same(
            lambda: self.backend.reverse(entry, key, when),
            lambda: self.oracle.reverse(oracle_id, key, when),
        )
        self.backend.check()
        if isinstance(got, Exception):
            return None
        self.ids[got.entry_id] = want.entry_id
        return got.entry_id

    @invariant()
    def every_entry_is_balanced(self) -> None:
        for lines in self.backend.entry_lines().values():
            per_currency: dict[str, int] = defaultdict(int)
            for currency, amount in lines:
                per_currency[currency] += amount
            assert all(v == 0 for v in per_currency.values())

    @invariant()
    def one_entry_per_successful_key(self) -> None:
        assert len(self.backend.entry_lines()) == len(self.oracle.entries)

    @invariant()
    def balances_match_the_oracle(self) -> None:
        for d in (date(2026, 1, 31), *DATES):
            assert self.backend.balances(d) == self.oracle.balances(d)

    @invariant()
    def everything_nets_to_zero_per_currency(self) -> None:
        lines = [line for entry in self.oracle.entries.values() for line in entry.lines]
        assert all(v == 0 for v in balance_by_currency(lines).values())
