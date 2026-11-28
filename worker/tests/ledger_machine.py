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


# =================================================================================================
# M2c-7f-2: the funds model — the close-out machine's oracle (plan docs/design/m2c-7f-plan.md §3
# M1-M6; docs/design/m2c-7-plan.md §8.2). Pure: it never reads the database. The machine tells it
# what happened (a collection booked, a reversal, a run approved with the documents the engine
# priced, a payout debited or returned, a top-up credited...) and it says what must follow from its
# own model of the client queues, the runs and their lines, the payouts, the advances, the
# settlements, the client credits and the top-ups — never from `remitted_cover_target` or any SQL
# helper the machine checks (M7-MONEY-1). The engine's prices (each run's documents, their HT, VAT
# and TTC, and how a credit note applies to the invoices it corrects) are its inputs: the model
# checks what is set off, recovered, paid, owed and moved with them, not the commission rates.
# =================================================================================================


def half_up(n: int, d: int) -> int:
    """n / d rounded half-up, symmetric (the oracle's own; it never imports the engine)."""
    q = (2 * abs(n) + d) // (2 * d)
    return q if n >= 0 else -q


def vat_moved(pending: int, open_minor: int, take: int) -> int:
    """§9.6: the pending VAT a settled part moves to due, pro rata; all of it when it closes."""
    if take >= open_minor:
        return pending
    return half_up(pending * take, open_minor) if open_minor else 0


@dataclass
class FMandate:
    id: str
    client: str
    netting: bool
    clawback: bool


@dataclass
class FItem:
    """An item of a client's queue (a 4670 posting of an allocation, a reversal, an advance, a
    returned payout): its entry, whose money it is and the run holding it as a live line."""

    key: str
    client: str
    mandate: str | None
    amount: int
    kind: str  # collection | reversal | advance | payout_returned | unplanned
    origin: str | None = None  # a reversal: the collection it undoes; an advance: its reversal
    run: str | None = None


@dataclass
class FAdvance:
    id: str
    client: str
    mandate: str | None
    amount: int
    cause: str
    cover_of: str | None  # the reversal it covers (remitted_reversal)
    item: str  # its entry: the queue item
    seq: int
    settled: int = 0
    written_off: int = 0
    reversed: bool = False
    requested_by: set[str] = field(default_factory=set)
    in_flight: str | None = None  # the run whose settlement takes it back, until booked

    @property
    def open(self) -> int:
        return 0 if self.reversed else self.amount - self.settled - self.written_off


@dataclass
class FDocument:
    id: str
    client: str
    mandate: str | None
    kind: str  # invoice | credit_note
    ttc: int
    vat: int
    seq: int
    open: int = 0
    pending_vat: int = 0
    in_flight: str | None = None  # the run whose settlement takes it, until booked
    due: date | None = None  # a due invoice's (no netting clause): the client pays it
    number: tuple[int, int] = (0, 0)  # (year, seq) in its series


@dataclass
class FRun:
    id: str
    client: str
    lines: tuple[str, ...]
    gross: int
    status: str = "approved"  # approved | booked | cancelled
    net: int = 0
    settlement: int = 0
    takes: dict[str, int] = field(default_factory=dict)  # document or advance -> amount
    refunds: dict[str, int] = field(default_factory=dict)  # credit note -> excess paid
    booked_on: date | None = None
    returned: bool = False
    account: int = 0  # the client's payout account it pays (its generation at the approval)


@dataclass
class FCredit:
    """What the servicer owes a client back (419): a payment's surplus."""

    id: str
    client: str
    amount: int
    refunded: int = 0

    @property
    def open(self) -> int:
        return self.amount - self.refunded


@dataclass
class FTransfer:
    id: str
    kind: str  # payout | sweep | refund | top_up
    amount: int
    e2e: str
    status: str = "ordered"  # ordered | in_file | downloaded | debited | returned | cancelled
    run: str | None = None
    file: str | None = None
    payment: str | None = None  # a refund: the payment it gives back
    replaced_by: str | None = None  # cancelled after download: its re-issue
    late: bool = False  # the bank executed it after its cancellation
    held: bool = False  # its client's status changed since its run was approved: never filed


@dataclass
class FPayment:
    id: str
    amount: int
    e2e: str
    allocated: int = 0
    out: int = 0  # returned to the payer or refunded

    @property
    def unallocated(self) -> int:
        return self.amount - self.allocated - self.out


@dataclass
class FundsModel:
    """The oracle of the close-out machine (module comment above)."""

    mandates: dict[str, FMandate] = field(default_factory=dict)
    items: dict[str, FItem] = field(default_factory=dict)
    advances: dict[str, FAdvance] = field(default_factory=dict)
    documents: dict[str, FDocument] = field(default_factory=dict)
    runs: dict[str, FRun] = field(default_factory=dict)
    transfers: dict[str, FTransfer] = field(default_factory=dict)
    payments: dict[str, FPayment] = field(default_factory=dict)
    # the covers the model expects: reversal -> amount (now), and the run whose booking covers it
    covers: dict[str, int] = field(default_factory=dict)
    cover_at_booking: dict[str, str] = field(default_factory=dict)  # reversal -> run in flight
    credits: dict[str, FCredit] = field(default_factory=dict)
    bars: dict[str, tuple[str, date]] = field(default_factory=dict)  # client -> (event, its day)
    proofs: set[str] = field(default_factory=set)  # the sha256 of each proof a payment used
    returned_accounts: set[str] = field(default_factory=set)  # clients whose payout came back
    account_gen: dict[str, int] = field(default_factory=dict)  # each client's account, replaced +1
    requests: dict[str, set[str]] = field(default_factory=dict)  # live request -> its advances
    # the books the model keeps itself
    bank: int = 0  # 5120 as the bank's lines move it (each one booked)
    due_to_servicer: int = 0  # Σ4679 (+: the servicer owes the dedicated account)
    own_cash: int = 0  # 5122 (+: in the own account)
    vat_pending: int = 0  # Σ pending VAT of open documents (44574 = -this)
    vat_due: int = 0  # VAT moved to due (44571 = -this)
    received: dict[str, int] = field(default_factory=dict)  # client -> payouts debited - returned
    seq: int = 0
    events: list[str] = field(default_factory=list)

    def _next(self) -> int:
        self.seq += 1
        return self.seq

    # -- the client queue ---------------------------------------------------------------------

    def pending(self, client: str) -> list[FItem]:
        return [i for i in self.items.values() if i.client == client and i.run is None]

    def in_flight(self, client: str) -> int:
        return sum(r.net + r.settlement for r in self.runs.values()
                   if r.client == client and r.status == "approved")  # fmt: skip

    def payable(self, client: str) -> int:
        """I14 from the model: 4670[c] = -(its pending items + its runs in flight)."""
        return -(sum(i.amount for i in self.pending(client)) + self.in_flight(client))

    def live_run_of(self, key: str) -> FRun | None:
        item = self.items[key]
        return self.runs[item.run] if item.run else None

    # -- collections and their reversals -------------------------------------------------------

    def collect(self, payment: FPayment, key: str, client: str, mandate: str | None,
                amount: int) -> None:  # fmt: skip
        self.payments.setdefault(payment.id, payment)
        self.payments[payment.id].allocated += amount
        self.items[key] = FItem(key, client, mandate, amount, "collection")

    def reverse(self, reversal: str, collection: str, *, returned: bool) -> int:
        """A reversal R of a collection E (« Désimputer », or its payment's return): R in the queue,
        and the cover the model expects of it now (M2, rules 1-2a, 3): E's line amount when E is a
        live line of a booked run (R is not in that run: R is new), at that run's booking when the
        run is in flight, none while E waits in the queue (R nets with it, a same-run pair once
        both are in one run). Returns the amount covered now."""
        e = self.items[collection]
        self.items[reversal] = FItem(
            reversal, e.client, e.mandate, -e.amount, "reversal", collection
        )
        run = self.live_run_of(collection)
        if run is not None and run.status == "booked":
            self.covers[reversal] = e.amount
            self.events.append(f"cover at reversal {e.amount}")
            return e.amount
        if run is not None and run.status == "approved":
            self.cover_at_booking[reversal] = run.id
            self.events.append("cover deferred to the booking")
        else:
            self.events.append("reversal nets in the queue")
        return 0

    def cover(
        self, advance: str, item: str, reversal: str, amount: int, mandate: str | None
    ) -> None:
        """The advance that covers R (what the database posted), the queue's +A."""
        r = self.items[reversal]
        self.advances[advance] = FAdvance(advance, r.client, mandate, amount, "remitted_reversal",
                                          reversal, item, self._next())  # fmt: skip
        self.items[item] = FItem(item, r.client, mandate, amount, "advance", reversal)
        self.due_to_servicer += amount

    # -- runs ----------------------------------------------------------------------------------

    def open_invoices(self, mandate: str | None) -> list[FDocument]:
        return sorted(
            (d for d in self.documents.values()
             if d.mandate == mandate and d.kind == "invoice" and d.open > 0
             and d.in_flight is None),
            key=lambda d: d.seq,
        )  # fmt: skip

    def open_advances(self, mandate: str | None) -> list[FAdvance]:
        return sorted(
            (a for a in self.advances.values()
             if a.mandate == mandate and a.open > 0 and not a.requested_by
             and a.in_flight is None),
            key=lambda a: a.seq,
        )  # fmt: skip

    def expected_plan(  # noqa: PLR0912 - §9.6 per mandate, then the cross-mandate cap
        self, client: str, lines: list[FItem], excess: dict[str | None, int],
        new_invoices: list[FDocument],
    ) -> dict[str | None, dict[str, Any]]:  # fmt: skip
        """§9.6 from the model: per mandate (None: outside every mandate), its gross, the open
        invoices it sets off (netting clause: oldest first, its own money only), then its open
        advances (claw-back clause: oldest first, never one a live request names: rules 7, 8, 13),
        the net; then, when the mandates' nets add up below 0, the takes reduced (advances first,
        the last mandate first); then, when what the run would take equals the refunds it owes
        (D = 0: no settlement entry could carry the VAT moved), nothing is settled now — the takes
        and the refunds left for a later run, N = gross. `excess` the refunds owed per mandate
        (`refunds_owed`: credit notes beyond what they correct); `new_invoices` the run's own,
        settled last among the mandate's invoices."""
        order: list[str | None] = []
        for i in lines:
            if i.mandate not in order:
                order.append(i.mandate)
        for m in excess:
            if m not in order:
                order.append(m)
        out: dict[str | None, dict[str, Any]] = {}
        for m in order:
            gross = sum(i.amount for i in lines if i.mandate == m)
            avail = gross + excess.get(m, 0)
            fm = self.mandates.get(m) if m is not None else None
            takes: dict[str, int] = {}
            take = take_adv = 0
            bar = self.bars.get(client, ("", None))[0]
            if fm is not None and fm.netting and bar != "liquidation":
                room = max(0, avail)
                for d in [*self.open_invoices(m), *(x for x in new_invoices if x.mandate == m)]:
                    t = min(d.open, room)
                    if t > 0:
                        takes[d.id] = t
                        take += t
                        room -= t
            # rule 17: no advance is taken back while a proceeding stands, nothing set off in
            # liquidation
            if fm is not None and fm.clawback and not bar:
                room = max(0, avail - take)
                for a in self.open_advances(m):
                    t = min(a.open, room)
                    if t > 0:
                        takes[a.id] = t
                        take_adv += t
                        room -= t
            out[m] = {
                "gross": gross,
                "excess": excess.get(m, 0),
                "take": take,
                "take_advance": take_adv,
                "net": avail - take - take_adv,
                "takes": takes,
            }
        # the client's other money is drawn on only until N ≥ 0: the takes reduced, advances
        # first, the last mandate first
        short = -sum(x["net"] for x in out.values())
        for kind in ("advance", "invoice"):
            for m in reversed(order):
                if short <= 0:
                    break
                x = out[m]
                for key in reversed(list(x["takes"])):
                    if short <= 0:
                        break
                    if (key in self.advances) != (kind == "advance"):
                        continue
                    cut = min(x["takes"][key], short)
                    x["takes"][key] -= cut
                    x["take_advance" if kind == "advance" else "take"] -= cut
                    x["net"] += cut
                    short -= cut
                    if x["takes"][key] == 0:
                        del x["takes"][key]
        taken = sum(x["take"] + x["take_advance"] for x in out.values())
        owed = sum(excess.values())
        if taken == owed and (taken or any(v > 0 for v in excess.values())):
            for x in out.values():
                x["net"] = x["gross"]
                x["excess"] = x["take"] = x["take_advance"] = 0
                x["takes"] = {}
                x["deferred"] = True
        return out

    def refunds_owed(self, client: str) -> dict[str | None, int]:
        """What the client's credit notes owe back beyond the invoices they corrected, per mandate,
        not yet paid (none held by a run in flight)."""
        out: dict[str | None, int] = {}
        for d in self.documents.values():
            if d.client == client and d.kind == "credit_note" and d.open > 0 and not d.in_flight:
                out[d.mandate] = out.get(d.mandate, 0) + d.open
        return out

    def issue(self, d: FDocument, applications: list[tuple[str, int, int]]) -> None:
        """A document the engine issued (a run's, or a cancellation's): an invoice open for its TTC,
        its VAT pending; a credit note applied first to the invoices it corrects ((invoice, amount,
        pending VAT taken back): the engine's), the rest owed back to the client, its VAT off the
        pending VAT of what it corrects first, the rest off the VAT already due (§5.2)."""
        if d.kind == "invoice":
            d.open, d.pending_vat = d.ttc, d.vat
            self.vat_pending += d.vat
        else:
            d.open = -d.ttc
            taken_back = 0
            for inv, amount, vat in applications:
                corrected = self.documents[inv]
                corrected.open -= amount
                corrected.pending_vat -= vat
                self.vat_pending -= vat
                taken_back += vat
                d.open -= amount
            self.vat_due -= -d.vat - taken_back
        self.documents[d.id] = d

    def approve(self, run: FRun) -> None:
        """A run approved (its documents issued already): its lines leave the queue, the documents
        its settlement takes go in flight until its booking."""
        for key in run.lines:
            self.items[key].run = run.id
        for key in [*run.takes, *run.refunds]:
            x = self.documents.get(key) or self.advances.get(key)
            if x is not None:
                x.in_flight = run.id
        self.runs[run.id] = run

    def barred(self, client: str, key: str) -> bool:
        """A take a bar recorded since the run's approval withholds at the debit (rule 17): every
        one in liquidation, an advance while a proceeding stands (the machine's documents are all
        issued on the day: none is born before an opening)."""
        bar = self.bars.get(client, ("", None))[0]
        return bar == "liquidation" or (bar == "proceeding" and key in self.advances)

    def book(self, run_id: str, on: date, withheld_item: str | None = None) -> list[str]:
        """The run's payout debited (or its approval when N = 0): its settlement posted — each
        take set off, its VAT moved pro rata (MONEY-11), 4679 credited by D —, the client paid N;
        a take a bar recorded since withholds is not set off (posted and reversed at once) but owed
        to the client again (`withheld_item`, outside every mandate: rules 17, 27); then (rule 2)
        each line E reversed while the run was in flight is covered now. The reversals the booking
        must cover."""
        run = self.runs[run_id]
        run.status, run.booked_on = "booked", on
        withheld = {k: t for k, t in run.takes.items() if self.barred(run.client, k)}
        owed_back = sum(withheld.values())
        if withheld and run.settlement > 0 and run.settlement - owed_back <= 0:
            # never a zero (or negative) allowed settlement while settles remain: the whole plan
            # withheld, its refunds with it (W = D)
            withheld = dict(run.takes)
            owed_back = run.settlement
            for key in run.refunds:
                self.documents[key].in_flight = None
            run.refunds = {}
        for key in withheld:
            x = self.documents.get(key) or self.advances[key]
            x.in_flight = None
        run.takes = {k: t for k, t in run.takes.items() if k not in withheld}
        if withheld:
            assert withheld_item is not None, ("a withheld set-off owed back", withheld)
            run.settlement -= owed_back
            self.items[withheld_item] = FItem(
                withheld_item, run.client, None, owed_back, "withheld", run_id
            )
        for key, t in run.takes.items():
            if key in self.documents:
                d = self.documents[key]
                moved = vat_moved(d.pending_vat, d.open, t)
                d.pending_vat -= moved
                d.open -= t
                d.in_flight = None
                self.vat_pending -= moved
                self.vat_due += moved
            else:
                self.advances[key].settled += t
                self.advances[key].in_flight = None
        for key, t in run.refunds.items():
            d = self.documents[key]
            d.open -= t
            d.in_flight = None
        self.due_to_servicer -= run.settlement
        self.received[run.client] = self.received.get(run.client, 0) + run.net
        due = [r for r, x in self.cover_at_booking.items() if x == run_id]
        for r in due:
            del self.cover_at_booking[r]
            self.covers[r] = self.items[self.items[r].origin or ""].amount
        return due

    def expected_vat_moves(self, run_id: str) -> dict[str, int]:
        """What the run's booking will move per document (before `book`)."""
        run = self.runs[run_id]
        out = {}
        for key, t in run.takes.items():
            if key in self.documents and not self.barred(run.client, key):
                d = self.documents[key]
                out[key] = vat_moved(d.pending_vat, d.open, t)
        return out

    def cancel(self, run_id: str) -> None:
        """Cancelled before its file was handed out: its lines back in the queue."""
        run = self.runs[run_id]
        run.status = "cancelled"
        for key in run.lines:
            self.items[key].run = None
        for d in self.documents.values():
            if d.in_flight == run_id:
                d.in_flight = None
        for a in self.advances.values():
            if a.in_flight == run_id:
                a.in_flight = None
        for r, x in list(self.cover_at_booking.items()):
            if x == run_id:
                del self.cover_at_booking[r]

    def payout_returned(self, run_id: str, item: str) -> None:
        """The client's bank sent the payout back: what it carried is owed again (one item, outside
        every mandate, Q17); the settlement stays; the payout account blocks until replaced."""
        run = self.runs[run_id]
        run.returned = True
        self.items[item] = FItem(item, run.client, None, run.net, "payout_returned", run_id)
        self.received[run.client] = self.received.get(run.client, 0) - run.net
        if run.account == self.account_gen.get(run.client, 0):
            # the account it was paid to is still the client's: blocked until replaced (one
            # replaced since stays as it is)
            self.returned_accounts.add(run.client)

    # -- the servicer's money ------------------------------------------------------------------

    def top_up_needed(self) -> int:
        """Rule 19: max(0, Σ4679 + sweeps in flight - top-ups ordered or filed)."""
        sweeps = sum(
            t.amount
            for t in self.transfers.values()
            if t.kind == "sweep" and t.status in ("ordered", "in_file", "downloaded")
        )
        tops = sum(t.amount for t in self.transfers.values()
                   if t.kind == "top_up" and t.status in ("ordered", "in_file"))  # fmt: skip
        return max(0, self.due_to_servicer + sweeps - tops)

    def documents_open(self, client: str) -> int:
        """4111[c] from the model: the invoices' open parts less what credit notes owe back."""
        return sum(d.open if d.kind == "invoice" else -d.open
                   for d in self.documents.values() if d.client == client)  # fmt: skip

    def advances_open(self, client: str) -> int:
        return sum(a.open for a in self.advances.values() if a.client == client)

    # -- client payments (rule 12) --------------------------------------------------------------

    def client_payment_parts(self, client: str, amount: int, on: date,
                             named: list[str] | None
                             ) -> tuple[list[tuple[str, int, int]], int]:  # fmt: skip
        """What a client's payment settles, from the model: with a designation the documents it
        names in its order, each up to its open part; else invoices due on or before the day (by
        due date, number), then advances (by birth), then the other invoices (due date nulls last,
        number); never a document in flight (rule 13); VAT pro rata; the rest a credit owed back.
        ([(document or advance, part, VAT moved)], the credit)."""
        invoices = [d for d in self.documents.values()
                    if d.client == client and d.kind == "invoice" and d.open > 0
                    and d.in_flight is None]  # fmt: skip
        advances = sorted((a for a in self.advances.values()
                           if a.client == client and a.open > 0 and a.in_flight is None),
                          key=lambda a: a.seq)  # fmt: skip
        if named is not None:
            pool: list[Any] = [
                x for k in named for x in [self.documents.get(k) or self.advances.get(k)] if x
            ]
        else:
            due = sorted((d for d in invoices if d.due is not None and d.due <= on),
                         key=lambda d: (d.due, d.number))  # fmt: skip
            rest = sorted((d for d in invoices if d not in due),
                          key=lambda d: (d.due is None, d.due or on, d.number))  # fmt: skip
            pool = [*due, *advances, *rest]
        parts = []
        left = amount
        for x in pool:
            part = min(left, x.open)
            if part <= 0:
                continue
            vat = vat_moved(x.pending_vat, x.open, part) if isinstance(x, FDocument) else 0
            parts.append((x.id, part, vat))
            left -= part
        return parts, left

    def considered(self, client: str, named: list[str] | None) -> int:
        """What the page shows the payment may settle (the command's compare and set)."""
        if named is not None:
            return sum((self.documents.get(k) or self.advances[k]).open for k in named)
        return sum(d.open for d in self.documents.values()
                   if d.client == client and d.kind == "invoice" and d.in_flight is None) + sum(
            a.open for a in self.advances.values()
            if a.client == client and a.in_flight is None)  # fmt: skip

    def client_paid(self, parts: list[tuple[str, int, int]], credit: FCredit | None,
                    *, own: bool, amount: int) -> None:  # fmt: skip
        """The payment posted: each part settled, its VAT moved, the rest owed back; the money in
        the own account (5122), or on the dedicated account (the servicer's share there: 4679)."""
        for key, part, vat in parts:
            if key in self.documents:
                d = self.documents[key]
                d.open -= part
                d.pending_vat -= vat
                self.vat_pending -= vat
                self.vat_due += vat
            else:
                self.advances[key].settled += part
        if credit is not None:
            self.credits[credit.id] = credit
        if own:
            self.own_cash += amount
        else:
            self.due_to_servicer -= amount

    def credits_open(self, client: str) -> int:
        return sum(c.open for c in self.credits.values() if c.client == client)

    def remitted(self, collection: str) -> bool:
        """E is remitted (the model's own pair rule): a live line of a booked run."""
        run = self.live_run_of(collection)
        return run is not None and run.status == "booked"

    def settled_on(self, run_id: str, depth: int = 0) -> date | None:
        """[check 2] « the client was paid » from the model: a booked run's own payout that stayed
        paid (or an N = 0 run) on its booking day; one that came back, when what it carried (its
        returned item) was paid by a later booked run — that run's day; else not paid."""
        run = self.runs[run_id]
        if run.status != "booked" or depth > 10:
            return None
        if not run.returned:
            return run.booked_on
        back = [
            i for i in self.items.values() if i.kind == "payout_returned" and i.origin == run_id
        ]
        if not back:
            return None
        days = []
        for item in back:
            later = self.runs.get(item.run or "")
            if later is None or later.id == run_id:
                return None
            day = self.settled_on(later.id, depth + 1)
            if day is None:
                return None
            days.append(day)
        return max(days)
