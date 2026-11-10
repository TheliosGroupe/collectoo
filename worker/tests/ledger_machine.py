"""Shared ledger property-test machinery (M2-04, M2b-1).

`InMemoryLedger` is an oracle with the database's rules: entries, reversals and idempotency (M2a),
and since M2b the payment entries with their checks at commit: client money closed in every entry
(I2), the shape of each type (I3), what is left of a payment never negative at any date (I4), and
a receivable credited by an allocation or a netting never overdrawn afterwards (I6); since M2c
the two funds closed in every entry (I2'), the 4679 / 4689 mirror (I12), the shapes of the fund
entries (I3') and each client's 4670 never in debit at commit (I13, LG008).

`LedgerMachine` drives random corrections, receipts (a payment and its cash_in), allocations,
forwards, refunds, nettings, reversals (with forced idempotency-key collisions) and, since M2c,
the funds' entries (commission invoices, settlements, remittances, sweeps, top-ups, fees, losses,
advances, entries of the wrong shape) against a backend and checks the invariants after every
step. The pure test runs it against the oracle; the integration test runs it against Postgres
(payment and fund entries through private.ledger_post_set) and compares outcomes and balances
with the oracle.
"""

from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date
from typing import Any, Protocol
from uuid import UUID, uuid4

from hypothesis import event
from hypothesis import strategies as st
from hypothesis.stateful import Bundle, RuleBasedStateMachine, invariant, precondition, rule

from collectoo_worker.ledger import (
    AlreadyReversedError,
    Book,
    ClientMoneyShortError,
    Component,
    EntryDraft,
    EntryType,
    IdempotencyConflictError,
    Line,
    OverdrawnError,
    PostResult,
    ReversalError,
    ScopeError,
    balance_by_currency,
    mirror,
)
from collectoo_worker.ledger.model import (
    CLIENT_MONEY_BOOKS,
    MIRROR_BOOKS,
    NEVER_REVERSED,
    SERVICER_FUND_BOOKS,
)

ORG = UUID("00000000-0000-0000-0000-0000000000f0")
CLIENT = UUID("00000000-0000-0000-0000-0000000000f1")
ACCOUNT = UUID("30000000-0000-0000-0000-0000000000f1")
ITEMS = (UUID("40000000-0000-0000-0000-0000000000f1"), UUID("40000000-0000-0000-0000-0000000000f2"))
BANK = UUID("80000000-0000-0000-0000-0000000000f1")
OWN = UUID("80000000-0000-0000-0000-0000000000f2")  # the servicer's own account (5122)
DATES = (date(2026, 2, 1), date(2026, 3, 1), date(2026, 4, 1))
CHECK_DATES = (date(2026, 1, 31), *DATES)
KEYS = tuple(f"prop-key-{i:04d}" for i in range(8))
PAY_KEYS = tuple(f"pay-key-{i:04d}" for i in range(6))

# A ledger "dimension": what identifies a ledger account inside one tenant.
Dim = tuple[str, str, str | None, str | None, str | None, str | None]
# book, currency, item, component, client, bank account


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
        str(line.bank_account_id) if line.bank_account_id else None,
    )


def request_hash(draft: EntryDraft) -> str:
    payload = {
        "type": str(draft.entry_type),
        "date": draft.effective_date.isoformat(),
        "account": str(draft.account_id),
        "payment": str(draft.payment_id),
        "client": str(draft.client_organization_id),
        "source": [draft.source_type, draft.source_id],
        "reason": draft.reason,
        "lines": sorted([list(map(str, dim(line))), line.amount_minor] for line in draft.lines),
    }
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


@dataclass(frozen=True)
class Payment:
    id: UUID
    amount_minor: int
    booking_date: date
    currency: str = "EUR"


@dataclass
class Entry:
    id: UUID
    entry_type: EntryType
    effective_date: date
    lines: tuple[Line, ...]
    reverses: UUID | None = None
    payment_id: UUID | None = None
    account_id: UUID | None = None


def pool_movement(entry: Entry) -> int:
    """Debits on the pooled unallocated book: what the entry takes out of its payment."""
    return sum(x.amount_minor for x in entry.lines if x.book is Book.UNALLOCATED_PAYMENT)


def running(points: dict[date, int]) -> list[tuple[date, int]]:
    out, total = [], 0
    for d in sorted(points):
        total += points[d]
        out.append((d, total))
    return out


@dataclass
class InMemoryLedger:
    entries: dict[UUID, Entry] = field(default_factory=dict)
    by_key: dict[str, tuple[UUID, str]] = field(default_factory=dict)
    reversed_by: dict[UUID, UUID] = field(default_factory=dict)
    payments: dict[UUID, Payment] = field(default_factory=dict)

    def add_payment(self, payment: Payment) -> None:
        self.payments[payment.id] = payment

    def _replay(self, key: str, h: str) -> PostResult | None:
        if key in self.by_key:
            entry_id, existing = self.by_key[key]
            if existing != h:
                raise IdempotencyConflictError(key)
            return PostResult(entry_id, False)
        return None

    def _commit(self, entry: Entry, key: str, h: str) -> PostResult:
        self.check(entry)
        self.check_client_payable(entry)
        self.entries[entry.id] = entry
        self.by_key[key] = (entry.id, h)
        return PostResult(entry.id, True)

    def post(self, draft: EntryDraft) -> PostResult:
        """private.ledger_post: corrections on claims."""
        draft.validate()
        h = request_hash(draft)
        replay = self._replay(draft.idempotency_key, h)
        if replay is not None:
            return replay
        entry = Entry(
            uuid4(),
            draft.entry_type,
            draft.effective_date,
            draft.lines,
            account_id=draft.account_id,
        )
        return self._commit(entry, draft.idempotency_key, h)

    def post_set(self, draft: EntryDraft) -> PostResult:
        """private.ledger_post_set: one payment entry."""
        draft.validate_set()
        if draft.payment_id is not None:
            payment = self.payments.get(draft.payment_id)
            if payment is None or any(x.currency != payment.currency for x in draft.lines):
                raise ScopeError("payment of another servicer or in another currency")
        h = request_hash(draft)
        replay = self._replay(draft.idempotency_key, h)
        if replay is not None:
            return replay
        entry = Entry(
            uuid4(),
            draft.entry_type,
            draft.effective_date,
            draft.lines,
            payment_id=draft.payment_id,
            account_id=draft.account_id,
        )
        return self._commit(entry, draft.idempotency_key, h)

    def reverse(self, entry_id: UUID, key: str, when: date | None) -> PostResult:
        target = self.entries[entry_id]
        effective = when or target.effective_date
        # A replay must repeat the request: same entry and same effective date.
        request = f"reversal:{entry_id}:{effective.isoformat()}"
        replay = self._replay(key, request)
        if replay is not None:
            return replay
        if target.reverses is not None:
            raise ReversalError("a reversal is not reversed")
        if target.entry_type in NEVER_REVERSED:
            raise ReversalError(f"a {target.entry_type} is not reversed")
        if effective < target.effective_date:
            raise ReversalError("reversal dated before the entry")
        if entry_id in self.reversed_by:
            raise AlreadyReversedError(str(entry_id))
        entry = Entry(
            uuid4(),
            EntryType.REVERSAL,
            effective,
            mirror(target.lines),
            reverses=entry_id,
            payment_id=target.payment_id,
            account_id=target.account_id,
        )
        result = self._commit(entry, key, request)
        self.reversed_by[entry_id] = entry.id
        return result

    # --- Checks at commit (I4, I6) -------------------------------------------------------------

    def check(self, new: Entry) -> None:
        entries = [*self.entries.values(), new]
        if new.payment_id is not None:
            self.check_payment(new.payment_id, entries)
        if new.entry_type in (
            EntryType.ALLOCATION,
            EntryType.NETTING,
            EntryType.ADJUSTMENT,
            EntryType.REVERSAL,
        ):
            for d in {dim(x) for x in new.lines if x.book is Book.DEBTOR_RECEIVABLE}:
                lines = [x for x in new.lines if dim(x) == d]
                credited = any(x.amount_minor < 0 for x in lines)
                debited = any(x.amount_minor > 0 for x in lines)
                self.check_receivable(d, entries, credited=credited, debited=debited)

    def check_client_payable(self, new: Entry) -> None:
        """I13 at commit: Σ4670 of each client, all dates, never in debit (LG008)."""
        clients = {x.client_organization_id for x in new.lines if x.book is Book.CLIENT_PAYABLE}
        for client in clients:
            total = sum(
                x.amount_minor
                for e in [*self.entries.values(), new]
                for x in e.lines
                if x.book is Book.CLIENT_PAYABLE and x.client_organization_id == client
            )
            if total > 0:
                raise ClientMoneyShortError(f"client {client} would be in debit by {total}")

    def left_over(self, payment_id: UUID, entries: list[Entry] | None = None) -> list[int]:
        """U_p at each date where an entry of the payment moves it (I4)."""
        payment = self.payments[payment_id]
        per_day: dict[date, int] = defaultdict(int)
        for e in entries if entries is not None else self.entries.values():
            if e.payment_id == payment_id:
                per_day[e.effective_date] += pool_movement(e)
        return [
            (payment.amount_minor if d >= payment.booking_date else 0) - taken
            for d, taken in running(per_day)
        ]

    def check_payment(self, payment_id: UUID, entries: list[Entry]) -> None:
        if any(u < 0 for u in self.left_over(payment_id, entries)):
            raise OverdrawnError(f"payment {payment_id} overdrawn")
        per_account: dict[UUID | None, dict[date, int]] = defaultdict(lambda: defaultdict(int))
        for e in entries:
            if e.payment_id == payment_id:
                per_account[e.account_id][e.effective_date] += pool_movement(e)
        if any(net < 0 for days in per_account.values() for _, net in running(days)):
            raise OverdrawnError(f"payment {payment_id}: negative net allocation")

    @staticmethod
    def check_receivable(d: Dim, entries: list[Entry], *, credited: bool, debited: bool) -> None:
        postings = [
            (e.entry_type, e.effective_date, x.amount_minor)
            for e in entries
            for x in e.lines
            if dim(x) == d
        ]
        d_cr = min(
            (
                on
                for t, on, a in postings
                if a < 0 and t in (EntryType.ALLOCATION, EntryType.NETTING)
            ),
            default=None,
        )
        d_dr = min((on for t, on, a in postings if a > 0 and t is EntryType.NETTING), default=None)
        per_day: dict[date, int] = defaultdict(int)
        for _, on, a in postings:
            per_day[on] += a
        balances = running(per_day)
        if credited and d_cr is not None and min(b for on, b in balances if on >= d_cr) < 0:
            raise OverdrawnError(f"receivable {d} overdrawn")
        if debited and d_dr is not None and max(b for on, b in balances if on >= d_dr) > 0:
            raise OverdrawnError(f"credit item {d} above zero")

    def available(self, d: Dim, on: date) -> int:
        """What can be taken from a ledger account on a date: its lowest balance from then on."""
        points = [on, *(e.effective_date for e in self.entries.values() if e.effective_date > on)]
        return min(self.balances(t).get(d, 0) for t in points)

    def remaining(self, payment_id: UUID, on: date) -> int:
        """What can be taken from a payment on a date: its lowest remainder from then on."""
        payment = self.payments[payment_id]
        tagged = [e for e in self.entries.values() if e.payment_id == payment_id]
        points = [on, *(e.effective_date for e in tagged if e.effective_date > on)]
        return min(
            (payment.amount_minor if t >= payment.booking_date else 0)
            - sum(pool_movement(e) for e in tagged if e.effective_date <= t)
            for t in points
        )

    def balances(self, as_of: date) -> dict[Dim, int]:
        out: dict[Dim, int] = defaultdict(int)
        for entry in self.entries.values():
            if entry.effective_date <= as_of:
                for line in entry.lines:
                    out[dim(line)] += line.amount_minor
        return {k: v for k, v in out.items() if v}


class Backend(Protocol):
    def add_payment(self, payment: Payment) -> None: ...

    def post(self, draft: EntryDraft) -> PostResult: ...

    def post_set(self, draft: EntryDraft) -> PostResult: ...

    def reverse(self, entry_id: UUID, key: str, when: date | None) -> PostResult: ...

    def balances(self, as_of: date) -> dict[Dim, int]: ...

    def entry_lines(self) -> dict[UUID, list[tuple[str, int]]]: ...

    def entry_detail(self) -> dict[UUID, tuple[UUID | None, list[tuple[str, int]]]]:
        """Per entry: the entry it reverses, and its lines as (ledger account key, amount)."""
        ...

    def check(self) -> None: ...


class OracleBackend:
    def __init__(self) -> None:
        self.ledger = InMemoryLedger()

    def add_payment(self, payment: Payment) -> None:
        self.ledger.add_payment(payment)

    def post(self, draft: EntryDraft) -> PostResult:
        return self.ledger.post(draft)

    def post_set(self, draft: EntryDraft) -> PostResult:
        return self.ledger.post_set(draft)

    def reverse(self, entry_id: UUID, key: str, when: date | None) -> PostResult:
        return self.ledger.reverse(entry_id, key, when)

    def balances(self, as_of: date) -> dict[Dim, int]:
        return self.ledger.balances(as_of)

    def entry_lines(self) -> dict[UUID, list[tuple[str, int]]]:
        return {
            e.id: [(line.currency, line.amount_minor) for line in e.lines]
            for e in self.ledger.entries.values()
        }

    def entry_detail(self) -> dict[UUID, tuple[UUID | None, list[tuple[str, int]]]]:
        return {
            e.id: (e.reverses, [(repr(dim(line)), line.amount_minor) for line in e.lines])
            for e in self.ledger.entries.values()
        }

    def check(self) -> None:
        return None


amounts = st.one_of(st.integers(1, 1_000_000), st.integers(-1_000_000, -1))
pay_keys = st.one_of(st.sampled_from(PAY_KEYS), st.uuids().map(lambda u: f"pay-{u}"))


@st.composite
def drafts(draw: st.DrawFn, key: str | None = None) -> EntryDraft:
    """Balanced corrections on claims: receivable/owner-claim pairs (no client money since M2b)."""
    moves = draw(
        st.lists(
            st.tuples(st.sampled_from(ITEMS), st.sampled_from(list(Component)), amounts),
            min_size=1,
            max_size=4,
        )
    )
    lines: list[Line] = []
    per_component: dict[Component, int] = defaultdict(int)
    for item, component, amount in moves:
        lines.append(Line(Book.DEBTOR_RECEIVABLE, amount, "EUR", item, component))
        per_component[component] += amount
    lines += [
        Line(Book.OWNER_CLAIM, -amount, "EUR", component=component)
        for component, amount in per_component.items()
        if amount
    ]
    return EntryDraft(
        organization_id=ORG,
        entry_type=EntryType.ADJUSTMENT,
        effective_date=draw(st.sampled_from(DATES)),
        idempotency_key=key or draw(st.sampled_from(KEYS)),
        lines=tuple(draw(st.permutations(lines))),
        account_id=ACCOUNT,
        reason="property test",
    )


def cash_in(payment: Payment) -> EntryDraft:
    return EntryDraft(
        organization_id=ORG,
        entry_type=EntryType.CASH_IN,
        effective_date=payment.booking_date,
        idempotency_key=f"cash_in:{payment.id}",
        lines=(
            Line(Book.CLIENT_MONEY_CASH, payment.amount_minor, "EUR", bank_account_id=BANK),
            Line(Book.UNALLOCATED_PAYMENT, -payment.amount_minor, "EUR"),
        ),
        source_type="bank_statement",
        source_id=f"stmt-{payment.id}",
    )


class LedgerMachine(RuleBasedStateMachine):
    """Random entries of every kind; the invariants hold after every step."""

    backend: Backend
    oracle: InMemoryLedger

    entries = Bundle("entries")
    payments = Bundle("payments")

    def __init__(self) -> None:
        super().__init__()
        self.backend = self.make_backend()
        self.oracle = InMemoryLedger()
        self.keys_ok: set[str] = set()
        self.rev_keys_ok: set[str] = set()
        self.first_id: dict[str, UUID] = {}  # key -> id returned by its first successful call
        self.ids: dict[UUID, UUID] = {}  # backend id -> oracle id
        self.cash_ins: list[tuple[UUID, UUID]] = []  # (backend id, oracle id)

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

    def _remember(self, key: str, got: PostResult) -> None:
        """Same key => single entry: a replay returns the id of the first call."""
        if got.created:
            assert key not in self.first_id
            self.first_id[key] = got.entry_id
        else:
            assert self.first_id[key] == got.entry_id

    def _post(self, draft: EntryDraft, *, payment_entry: bool) -> UUID | None:
        if payment_entry:
            got, want = self._same(
                lambda: self.backend.post_set(draft), lambda: self.oracle.post_set(draft)
            )
        else:
            got, want = self._same(
                lambda: self.backend.post(draft), lambda: self.oracle.post(draft)
            )
        self.backend.check()
        outcome = type(got).__name__ if isinstance(got, Exception) else got.created
        event(f"{draft.entry_type}: {outcome}")
        if isinstance(got, Exception):
            return None
        self._remember(draft.idempotency_key, got)
        self.keys_ok.add(draft.idempotency_key)
        self.ids[got.entry_id] = want.entry_id
        entry_id: UUID = got.entry_id
        return entry_id

    @rule(target=entries, draft=drafts())
    def post(self, draft: EntryDraft) -> Any:
        return self._post(draft, payment_entry=False)

    @rule(
        target=entries,
        item=st.sampled_from(ITEMS),
        component=st.sampled_from([Component.PRINCIPAL, Component.ACCRUED_INTEREST]),
        amount=st.one_of(st.integers(1, 300_000), st.integers(-60_000, -1)),
        when=st.sampled_from(DATES),
    )
    def owe(self, item: UUID, component: Component, amount: int, when: date) -> Any:
        """What the seller declared (an opening stand-in): mostly debts, sometimes a credit item."""
        draft = EntryDraft(
            organization_id=ORG,
            entry_type=EntryType.ADJUSTMENT,
            effective_date=when,
            idempotency_key=f"owe-{uuid4()}",
            lines=(
                Line(Book.DEBTOR_RECEIVABLE, amount, "EUR", item, component),
                Line(Book.OWNER_CLAIM, -amount, "EUR", component=component),
            ),
            account_id=ACCOUNT,
            reason="seller balance",
        )
        return self._post(draft, payment_entry=False)

    @rule(
        target=payments,
        amount=st.integers(min_value=1, max_value=200_000),
        booked=st.sampled_from(DATES),
    )
    def receive(self, amount: int, booked: date) -> Any:
        """A credit on the dedicated account: the payment and its statement day's cash_in."""
        payment = Payment(uuid4(), amount, booked)
        self.backend.add_payment(payment)
        self.oracle.add_payment(payment)
        entry = self._post(cash_in(payment), payment_entry=True)
        assert entry is not None
        self.cash_ins.append((entry, self.ids[entry]))
        return payment.id

    @rule(
        target=entries,
        payment=payments,
        moves=st.lists(
            st.tuples(
                st.sampled_from(ITEMS),
                st.sampled_from([Component.PRINCIPAL, Component.ACCRUED_INTEREST]),
                st.integers(min_value=1, max_value=100_000),
            ),
            min_size=1,
            max_size=3,
            unique_by=lambda m: (m[0], m[1]),
        ),
        when=st.sampled_from(DATES),
        key=pay_keys,
    )
    def allocate(
        self, payment: UUID, moves: list[tuple[UUID, Component, int]], when: date, key: str
    ) -> Any:
        total = sum(a for _, _, a in moves)
        per_component: dict[Component, int] = defaultdict(int)
        for _, component, a in moves:
            per_component[component] += a
        lines = (
            Line(Book.UNALLOCATED_PAYMENT, total, "EUR"),
            Line(Book.CLIENT_PAYABLE, -total, "EUR", client_organization_id=CLIENT),
            *(Line(Book.DEBTOR_RECEIVABLE, -a, "EUR", item, c) for item, c, a in moves),
            *(Line(Book.OWNER_CLAIM, a, "EUR", component=c) for c, a in per_component.items()),
        )
        draft = EntryDraft(
            organization_id=ORG,
            entry_type=EntryType.ALLOCATION,
            effective_date=when,
            idempotency_key=key,
            lines=lines,
            account_id=ACCOUNT,
            payment_id=payment,
        )
        return self._post(draft, payment_entry=True)

    @rule(
        target=entries,
        payment=payments,
        item=st.sampled_from(ITEMS),
        component=st.sampled_from([Component.PRINCIPAL, Component.ACCRUED_INTEREST]),
        when=st.sampled_from(DATES),
        percent=st.integers(min_value=1, max_value=100),
    )
    def allocate_what_is_due(
        self, payment: UUID, item: UUID, component: Component, when: date, percent: int
    ) -> Any:
        """An allocation sized from the oracle's balances: mostly accepted (the waterfall)."""
        line = Line(Book.DEBTOR_RECEIVABLE, -1, "EUR", item, component)
        room = min(self.oracle.available(dim(line), when), self.oracle.remaining(payment, when))
        return self.allocate(
            payment, [(item, component, max(1, room * percent // 100))], when, f"pay-{uuid4()}"
        )

    @rule(
        target=entries,
        payment=payments,
        amount=st.integers(min_value=1, max_value=100_000),
        when=st.sampled_from(DATES),
        key=pay_keys,
        refund=st.booleans(),
    )
    def release(self, payment: UUID, amount: int, when: date, key: str, refund: bool) -> Any:
        """Money of a payment leaves the pool: refunded to the payer, or forwarded to the client."""
        if refund:
            lines = (
                Line(Book.UNALLOCATED_PAYMENT, amount, "EUR"),
                Line(Book.CLIENT_MONEY_CASH, -amount, "EUR", bank_account_id=BANK),
            )
            client = None
        else:
            lines = (
                Line(Book.UNALLOCATED_PAYMENT, amount, "EUR"),
                Line(Book.CLIENT_PAYABLE, -amount, "EUR", client_organization_id=CLIENT),
            )
            client = CLIENT
        draft = EntryDraft(
            organization_id=ORG,
            entry_type=EntryType.CASH_OUT if refund else EntryType.FORWARD,
            effective_date=when,
            idempotency_key=key,
            lines=lines,
            payment_id=payment,
            client_organization_id=client,
            reason="property test",
        )
        return self._post(draft, payment_entry=True)

    @rule(
        target=entries,
        amount=st.integers(min_value=1, max_value=100_000),
        when=st.sampled_from(DATES),
        key=pay_keys,
        credit_note_first=st.booleans(),
    )
    def net(self, amount: int, when: date, key: str, credit_note_first: bool) -> Any:
        """A credit item applied to an invoice (both principal)."""
        credit, invoice = ITEMS if credit_note_first else ITEMS[::-1]
        draft = EntryDraft(
            organization_id=ORG,
            entry_type=EntryType.NETTING,
            effective_date=when,
            idempotency_key=key,
            lines=(
                Line(Book.DEBTOR_RECEIVABLE, amount, "EUR", credit, Component.PRINCIPAL),
                Line(Book.DEBTOR_RECEIVABLE, -amount, "EUR", invoice, Component.PRINCIPAL),
            ),
            account_id=ACCOUNT,
            reason="property test",
        )
        return self._post(draft, payment_entry=True)

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
        event(f"reversal: {type(got).__name__ if isinstance(got, Exception) else got.created}")
        if isinstance(got, Exception):
            return None
        self._remember(key, got)
        self.rev_keys_ok.add(key)
        self.ids[got.entry_id] = want.entry_id
        return got.entry_id

    # --- M2c: the funds -----------------------------------------------------------------------

    def _fund(
        self, entry_type: EntryType, lines: tuple[Line, ...], when: date, *, client: bool = False
    ) -> UUID | None:
        source = {
            EntryType.COMMISSION_INVOICE: "commission_invoice",
            EntryType.CLIENT_SETTLEMENT: "remittance_run",
            EntryType.CLIENT_ADVANCE: "client_advance",
        }.get(entry_type, "bank_transaction")
        draft = EntryDraft(
            organization_id=ORG,
            entry_type=entry_type,
            effective_date=when,
            idempotency_key=f"fund-{uuid4()}",
            lines=lines,
            client_organization_id=CLIENT if client else None,
            source_type=source,
            source_id=f"doc-{uuid4()}",
            reason="property test",
        )
        return self._post(draft, payment_entry=True)

    @rule(
        target=entries,
        kind=st.sampled_from(["sweep", "top_up", "fee", "loss"]),
        amount=st.integers(min_value=1, max_value=100_000),
        when=st.sampled_from(DATES),
    )
    def move_servicer_money(self, kind: str, amount: int, when: date) -> Any:
        """The servicer's money on the dedicated account: swept out, topped up, fees, losses."""
        cash = Line(Book.CLIENT_MONEY_CASH, -amount, "EUR", bank_account_id=BANK)
        dts = Line(Book.DUE_TO_SERVICER, amount, "EUR")
        dfc = Line(Book.DUE_FROM_CLIENT_FUNDS, -amount, "EUR")
        if kind == "sweep":
            lines = (dts, cash, Line(Book.OWN_CASH, amount, "EUR", bank_account_id=OWN), dfc)
            return self._fund(EntryType.SERVICER_SWEEP, lines, when)
        if kind == "top_up":
            lines = (
                cash.negated(),
                dts.negated(),
                dfc.negated(),
                Line(Book.OWN_CASH, -amount, "EUR", bank_account_id=OWN),
            )
            return self._fund(EntryType.SERVICER_TOP_UP, lines, when)
        book = Book.BANK_FEES if kind == "fee" else Book.SERVICER_LOSSES
        entry_type = EntryType.BANK_FEE if kind == "fee" else EntryType.SERVICER_LOSS
        return self._fund(entry_type, (dts, cash, Line(book, amount, "EUR"), dfc), when)

    @rule(
        target=entries,
        ht=st.integers(min_value=1, max_value=50_000),
        when=st.sampled_from(DATES),
    )
    def invoice(self, ht: int, when: date) -> Any:
        """A commission invoice (VAT 20 %, pending until settled)."""
        vat = ht // 5
        lines = [
            Line(Book.COMMISSION_RECEIVABLE, ht + vat, "EUR", client_organization_id=CLIENT),
            Line(Book.SERVICER_REVENUE, -ht, "EUR", client_organization_id=CLIENT),
        ]
        if vat:
            lines.append(Line(Book.VAT_PENDING, -vat, "EUR"))
        return self._fund(EntryType.COMMISSION_INVOICE, tuple(lines), when, client=True)

    @rule(
        target=entries,
        kind=st.sampled_from(["remittance", "settlement", "advance"]),
        amount=st.integers(min_value=1, max_value=200_000),
        when=st.sampled_from(DATES),
    )
    def pay_the_client(self, kind: str, amount: int, when: date) -> Any:
        """What the client is owed moves: a remittance, a settlement of its invoice from it, an
        advance (more owed). A payout beyond what the client is owed fails at commit (LG008)."""
        pay = Line(Book.CLIENT_PAYABLE, amount, "EUR", client_organization_id=CLIENT)
        if kind == "remittance":
            lines: tuple[Line, ...] = (
                pay,
                Line(Book.CLIENT_MONEY_CASH, -amount, "EUR", bank_account_id=BANK),
            )
            return self._fund(EntryType.REMITTANCE, lines, when, client=True)
        dts = Line(Book.DUE_TO_SERVICER, -amount, "EUR")
        dfc = Line(Book.DUE_FROM_CLIENT_FUNDS, amount, "EUR")
        if kind == "settlement":
            com = Line(Book.COMMISSION_RECEIVABLE, -amount, "EUR", client_organization_id=CLIENT)
            return self._fund(EntryType.CLIENT_SETTLEMENT, (pay, dts, dfc, com), when, client=True)
        adv = Line(Book.CLIENT_ADVANCE_RECEIVABLE, amount, "EUR", client_organization_id=CLIENT)
        lines = (dts.negated(), pay.negated(), adv, dfc.negated())
        return self._fund(EntryType.CLIENT_ADVANCE, lines, when, client=True)

    @rule(
        kind=st.sampled_from(["sweep", "fee", "advance", "remittance"]),
        amount=st.integers(min_value=1, max_value=100_000),
        when=st.sampled_from(DATES),
    )
    def wrong_shape(self, kind: str, amount: int, when: date) -> None:
        """A balanced entry, each fund closed and the mirror kept, but of the wrong shape (signs
        flipped): refused by both (I3', LG001)."""
        cash = Line(Book.CLIENT_MONEY_CASH, amount, "EUR", bank_account_id=BANK)
        dts = Line(Book.DUE_TO_SERVICER, -amount, "EUR")
        dfc = Line(Book.DUE_FROM_CLIENT_FUNDS, amount, "EUR")
        pay = Line(Book.CLIENT_PAYABLE, -amount, "EUR", client_organization_id=CLIENT)
        entry_type, lines, client = {
            "sweep": (
                EntryType.SERVICER_SWEEP,
                (dts, cash, Line(Book.OWN_CASH, -amount, "EUR", bank_account_id=OWN), dfc),
                False,
            ),
            "fee": (
                EntryType.BANK_FEE,
                (dts, cash, Line(Book.BANK_FEES, -amount, "EUR"), dfc),
                False,
            ),
            "advance": (
                EntryType.CLIENT_ADVANCE,
                (
                    dts,
                    pay.negated(),
                    Line(
                        Book.CLIENT_ADVANCE_RECEIVABLE,
                        -amount,
                        "EUR",
                        client_organization_id=CLIENT,
                    ),
                    dfc,
                ),
                True,
            ),
            "remittance": (EntryType.REMITTANCE, (pay, cash), True),
        }[kind]
        before = len(self.oracle.entries)
        assert self._fund(entry_type, lines, when, client=client) is None
        assert len(self.oracle.entries) == before

    @precondition(lambda self: bool(self.cash_ins))
    @rule(data=st.data())
    def reverse_a_cash_in(self, data: st.DataObject) -> None:
        backend_id, oracle_id = data.draw(st.sampled_from(self.cash_ins))
        key = f"rev-{uuid4()}"
        got, _ = self._same(
            lambda: self.backend.reverse(backend_id, key, None),
            lambda: self.oracle.reverse(oracle_id, key, None),
        )
        assert isinstance(got, ReversalError)

    @invariant()
    def entries_are_the_successful_keys(self) -> None:
        assert len(self.backend.entry_lines()) == len(self.keys_ok) + len(self.rev_keys_ok)

    @invariant()
    def a_reversal_negates_its_entry_line_by_line(self) -> None:
        detail = self.backend.entry_detail()
        for reverses, lines in detail.values():
            if reverses is not None:
                target = detail[reverses][1]
                assert sorted(lines) == sorted((k, -a) for k, a in target)

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
        for d in CHECK_DATES:
            assert self.backend.balances(d) == self.oracle.balances(d)

    @invariant()
    def everything_nets_to_zero_per_currency(self) -> None:
        lines = [line for entry in self.oracle.entries.values() for line in entry.lines]
        assert all(v == 0 for v in balance_by_currency(lines).values())

    @invariant()
    def client_money_is_cash_minus_what_is_owed(self) -> None:
        """I8: Σ5120 + Σ4710 + Σ4670 = 0 at every date."""
        for d in CHECK_DATES:
            per_currency: dict[str, int] = defaultdict(int)
            for k, v in self.backend.balances(d).items():
                if Book(k[0]) in CLIENT_MONEY_BOOKS:
                    per_currency[k[1]] += v
            assert all(v == 0 for v in per_currency.values()), (d, per_currency)

    @invariant()
    def the_servicers_fund_and_the_mirror_net_to_zero(self) -> None:
        """I2' summed over entries, and I12: the servicer's fund and Σ4679 + Σ4689 at every date."""
        for d in CHECK_DATES:
            fund: dict[str, int] = defaultdict(int)
            crossing: dict[str, int] = defaultdict(int)
            for k, v in self.backend.balances(d).items():
                if Book(k[0]) in SERVICER_FUND_BOOKS:
                    fund[k[1]] += v
                if Book(k[0]) in MIRROR_BOOKS:
                    crossing[k[1]] += v
            assert all(v == 0 for v in fund.values()), (d, fund)
            assert all(v == 0 for v in crossing.values()), (d, crossing)

    @invariant()
    def every_entry_closes_both_funds(self) -> None:
        """I2' and I12 per entry (the oracle's entries are the backend's: balances match)."""
        for e in self.oracle.entries.values():
            for books in (CLIENT_MONEY_BOOKS, SERVICER_FUND_BOOKS, MIRROR_BOOKS):
                assert sum(x.amount_minor for x in e.lines if x.book in books) == 0, e

    @invariant()
    def no_client_is_owed_less_than_nothing(self) -> None:
        """I13: Σ4670 of the client (all postings) is never in debit after a commit."""
        last = max(CHECK_DATES)
        owed = sum(v for k, v in self.backend.balances(last).items() if k[0] == Book.CLIENT_PAYABLE)
        assert owed <= 0, owed

    @invariant()
    def what_is_left_of_each_payment_is_in_the_pool(self) -> None:
        """I4/I5: U_p ≥ 0 at every date, and the pooled 4710 balance = -Σ U_p."""
        for p in self.oracle.payments.values():
            assert all(u >= 0 for u in self.oracle.left_over(p.id))
        for d in CHECK_DATES:
            pool = sum(
                v for k, v in self.backend.balances(d).items() if k[0] == Book.UNALLOCATED_PAYMENT
            )
            left = 0
            for p in self.oracle.payments.values():
                taken = sum(
                    pool_movement(e)
                    for e in self.oracle.entries.values()
                    if e.payment_id == p.id and e.effective_date <= d
                )
                left += (p.amount_minor if p.booking_date <= d else 0) - taken
            assert pool == -left, (d, pool, left)

    @invariant()
    def no_allocated_receivable_is_overdrawn(self) -> None:
        """I6 after any sequence: from the first allocation or netting credit, never below zero."""
        entries = list(self.oracle.entries.values())
        for d in {dim(x) for e in entries for x in e.lines if x.book is Book.DEBTOR_RECEIVABLE}:
            self.oracle.check_receivable(d, entries, credited=True, debited=True)
