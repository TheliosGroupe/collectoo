# ruff: noqa: E501, PLR0913, PLR0917 - SQL fixtures read better unwrapped
"""Ledger against Postgres (M2-04, M2b-1; needs `make up`): property machine (corrections and
payment entries), commit-time checks, append-only after commit, concurrent idempotency, the
allocation lock and balances as known at a time."""

from __future__ import annotations

import threading
import time
from datetime import UTC, date, datetime
from typing import Any
from uuid import UUID, uuid4

import psycopg
import pytest
from hypothesis import settings
from integration_helpers import DB, make_tenant, one
from ledger_machine import (
    ACCOUNT,
    BANK,
    CLIENT,
    ITEMS,
    ORG,
    Backend,
    Dim,
    LedgerMachine,
    Payment,
    cash_in,
)

from collectoo_worker import ledger
from collectoo_worker.ledger import (
    AppendOnlyError,
    Book,
    Component,
    EntryDraft,
    EntryType,
    Line,
    OverdrawnError,
    PostResult,
)
from collectoo_worker.ledger.model import ALLOWED_BOOKS, BOOKS

IBAN = "FR3430001007940000000001001"  # synthetic

pytestmark = pytest.mark.integration


def _fixture(
    conn: psycopg.Connection[Any],
    org: UUID,
    client: UUID,
    account: UUID,
    items: tuple[UUID, ...],
    portfolio: UUID | None = None,
) -> UUID:
    """A confirmed account with items and its ownership period, inside the current transaction."""
    if portfolio is None:
        conn.execute(
            "insert into public.organization (id, kind, legal_name) values (%s, 'servicer', 'S')",
            (org,),
        )
        conn.execute(
            "insert into public.organization (id, kind, servicer_organization_id, legal_name)"
            " values (%s, 'creditor_client', %s, 'C')",
            (client, org),
        )
        portfolio = one(
            conn,
            "insert into public.portfolio (organization_id, client_organization_id, name)"
            " values (%s, %s, 'P') returning id",
            (org, client),
        )
    conn.execute(
        """insert into public.account (id, organization_id, client_organization_id, portfolio_id,
             claim_type_code, external_ref, legal_regime, currency, status)
           values (%s, %s, %s, %s, 'b2b_invoice', %s, 'commercial_b2b', 'EUR', 'awaiting_first_letter')""",
        (account, org, client, portfolio, f"ref-{account}"),
    )
    for i, item in enumerate(items):
        conn.execute(
            "insert into public.claim_item (id, account_id, kind, ref, original_minor)"
            " values (%s, %s, 'invoice', %s, 100000)",
            (item, account, f"F-{i}"),
        )
    conn.execute(
        """insert into public.claim_ownership_period (account_id, owner_organization_id,
             servicer_organization_id, mandate_type, valid_from)
           values (%s, %s, %s, 'mandate_amicable', '2026-01-01')""",
        (account, client, org),
    )
    return portfolio


def _bank_account(conn: psycopg.Connection[Any], org: UUID, bank: UUID) -> None:
    conn.execute(
        """insert into public.bank_account (id, organization_id, iban, currency, label, feed, opened_on)
           values (%s, %s, %s, 'EUR', 'Fonds de tiers', 'camt053', '2026-01-01')""",
        (bank, org, IBAN),
    )


def _payment(conn: psycopg.Connection[Any], org: UUID, bank: UUID, payment: Payment) -> None:
    """A payment is the bank line it comes from (M2b-2): a statement being imported, its line, the
    payment (the import job does the same set-based)."""
    statement, line = uuid4(), uuid4()
    conn.execute(
        """insert into public.bank_statement (id, organization_id, bank_account_id, currency, format,
             file_name, file_sha256, size_bytes, storage_path)
           values (%s, %s, %s, %s, 'camt053', 'releve.xml', %s, 1, %s)""",
        (statement, org, bank, payment.currency, uuid4().hex * 2, f"test/{statement}.xml"),
    )
    conn.execute(
        "update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = %s",
        (statement,),
    )
    conn.execute(
        """insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id,
             line_no, dedup_key, direction, amount_minor, currency, booking_date, kind)
           values (%s, %s, %s, %s, 1, %s, 'credit', %s, %s, %s, 'debtor_credit')""",
        (
            line,
            org,
            bank,
            statement,
            f"t:{line}",
            payment.amount_minor,
            payment.currency,
            payment.booking_date,
        ),
    )
    conn.execute(
        """insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id,
             channel, method, amount_minor, currency, booking_date)
           values (%s, %s, %s, %s, 'camt053', 'sct', %s, %s, %s)""",
        (payment.id, org, bank, line, payment.amount_minor, payment.currency, payment.booking_date),
    )


def post_set(conn: psycopg.Connection[Any], draft: EntryDraft) -> PostResult:
    """One payment entry through private.ledger_post_set, as the M2b definer functions do."""
    try:
        conn.execute("select private.ledger_post_set_begin()")
        conn.execute(
            """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date,
                 idempotency_key, account_id, client_organization_id, payment_id, source_type, source_id, reason)
               values (1, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
            (
                draft.organization_id,
                str(draft.entry_type),
                draft.effective_date,
                draft.idempotency_key,
                draft.account_id,
                draft.client_organization_id,
                draft.payment_id,
                draft.source_type,
                draft.source_id,
                draft.reason,
            ),
        )
        with conn.cursor() as cur:
            cur.executemany(
                """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency,
                     claim_item_id, component, bank_account_id)
                   values (1, %s, %s, %s, %s, %s, %s, %s)""",
                [
                    (
                        n,
                        str(x.book),
                        x.amount_minor,
                        x.currency,
                        x.claim_item_id,
                        str(x.component) if x.component else None,
                        x.bank_account_id,
                    )
                    for n, x in enumerate(draft.lines, start=1)
                ],
            )
        row = conn.execute("select entry_id, created from private.ledger_post_set()").fetchone()
    except psycopg.Error as exc:
        mapped = ledger.from_db_error(exc)
        if mapped is not None:
            raise mapped from exc
        raise
    assert row is not None
    return PostResult(row[0], bool(row[1]))


class DbBackend:
    """One transaction per Hypothesis example, rolled back at teardown (ledger rows never persist).
    Each call runs the commit-time checks at once, inside its savepoint, so a refusal (LG007)
    shows on the call that caused it."""

    def __init__(self) -> None:
        self.conn = psycopg.connect(DB)
        _fixture(self.conn, ORG, CLIENT, ACCOUNT, ITEMS)
        _bank_account(self.conn, ORG, BANK)

    def add_payment(self, payment: Payment) -> None:
        _payment(self.conn, ORG, BANK, payment)

    def post(self, draft: EntryDraft) -> PostResult:
        with self.conn.transaction():
            result = ledger.post(self.conn, draft)
            ledger.verify_pending(self.conn)
            return result

    def post_set(self, draft: EntryDraft) -> PostResult:
        with self.conn.transaction():
            return post_set(self.conn, draft)

    def reverse(self, entry_id: UUID, key: str, when: date | None) -> PostResult:
        with self.conn.transaction():
            result = ledger.reverse(
                self.conn,
                entry_id,
                idempotency_key=key,
                reason="property test",
                effective_date=when,
            )
            ledger.verify_pending(self.conn)
            return result

    def balances(self, as_of: date) -> dict[Dim, int]:
        rows = self.conn.execute(
            """select la.book, p.currency, la.claim_item_id::text, la.component,
                      la.client_organization_id::text, la.bank_account_id::text, sum(p.amount_minor)::bigint
               from public.ledger_posting p join public.ledger_account la on la.id = p.ledger_account_id
               where la.organization_id = %s and p.effective_date <= %s
               group by 1, 2, 3, 4, 5, 6 having sum(p.amount_minor) <> 0""",
            (ORG, as_of),
        ).fetchall()
        return {(r[0], r[1], r[2], r[3], r[4], r[5]): int(r[6]) for r in rows}

    def entry_lines(self) -> dict[UUID, list[tuple[str, int]]]:
        rows = self.conn.execute(
            """select e.id, p.currency, p.amount_minor from public.ledger_entry e
               join public.ledger_posting p on p.entry_id = e.id where e.organization_id = %s""",
            (ORG,),
        ).fetchall()
        out: dict[UUID, list[tuple[str, int]]] = {}
        for entry_id, currency, amount in rows:
            out.setdefault(entry_id, []).append((currency, int(amount)))
        return out

    def entry_detail(self) -> dict[UUID, tuple[UUID | None, list[tuple[str, int]]]]:
        rows = self.conn.execute(
            """select e.id, e.reverses_entry_id, p.ledger_account_id::text, p.amount_minor
               from public.ledger_entry e join public.ledger_posting p on p.entry_id = e.id
               where e.organization_id = %s""",
            (ORG,),
        ).fetchall()
        out: dict[UUID, tuple[UUID | None, list[tuple[str, int]]]] = {}
        for entry_id, reverses, account, amount in rows:
            out.setdefault(entry_id, (reverses, []))[1].append((account, int(amount)))
        return out

    def check(self) -> None:
        ledger.verify_pending(self.conn)

    def close(self) -> None:
        self.conn.rollback()
        self.conn.close()


class DbLedgerMachine(LedgerMachine):
    def make_backend(self) -> Backend:
        return DbBackend()

    def teardown(self) -> None:
        backend = self.backend
        assert isinstance(backend, DbBackend)
        backend.close()


TestDbLedgerMachine = DbLedgerMachine.TestCase
TestDbLedgerMachine.settings = settings(max_examples=30, stateful_step_count=50, deadline=None)


# --- Committed data: unique tenants per test (ledger rows can never be deleted) ---------------------


def _confirmed_account() -> tuple[UUID, UUID, UUID, tuple[UUID, UUID]]:
    tenant = make_tenant()
    account, items = uuid4(), (uuid4(), uuid4())
    with psycopg.connect(DB) as conn, conn.transaction():
        _fixture(
            conn,
            tenant["servicer"],
            tenant["client"],
            account,
            items,
            portfolio=tenant["portfolio"],
        )
    return tenant["servicer"], tenant["client"], account, items


def _draft(org: UUID, account: UUID, item: UUID, amount: int, key: str, when: date) -> EntryDraft:
    return EntryDraft(
        organization_id=org,
        entry_type=EntryType.ADJUSTMENT,
        effective_date=when,
        idempotency_key=key,
        lines=(
            Line(Book.DEBTOR_RECEIVABLE, amount, "EUR", item, Component.PRINCIPAL),
            Line(Book.OWNER_CLAIM, -amount, "EUR", component=Component.PRINCIPAL),
        ),
        account_id=account,
        reason="integration test",
    )


def test_an_unbalanced_entry_fails_at_commit() -> None:
    org, client, account, items = _confirmed_account()
    conn = psycopg.connect(DB)
    try:
        with conn.cursor() as cur:
            portfolio = one(
                conn, "select portfolio_id from public.account where id = %s", (account,)
            )
            entry = cur.execute(
                """insert into public.ledger_entry (organization_id, client_organization_id, portfolio_id,
                     account_id, entry_type, effective_date, line_count, idempotency_key, request_hash, reason)
                   values (%s, %s, %s, %s, 'adjustment', '2026-03-01', 2, %s, %s, 'raw')
                   returning id""",
                (org, client, portfolio, account, f"raw-{uuid4()}", "0" * 64),
            ).fetchone()
            assert entry is not None
            la = []
            for book, comp, item in (
                ("debtor_receivable", "principal", items[0]),
                ("owner_claim", "principal", None),
            ):
                la.append(
                    cur.execute(
                        """insert into public.ledger_account (organization_id, book, currency, client_organization_id,
                         owner_organization_id, portfolio_id, account_id, claim_item_id, component)
                       values (%s, %s, 'EUR', %s, %s, %s, %s, %s, %s) returning id""",
                        (
                            org,
                            book,
                            client,
                            client if book == "owner_claim" else None,
                            portfolio,
                            account if item else None,
                            item,
                            comp,
                        ),
                    ).fetchone()[0]  # type: ignore[index]
                )
            cur.execute(
                "insert into public.ledger_posting values (%s, 1, %s, 100, 'EUR', '2026-03-01'),"
                " (%s, 2, %s, -99, 'EUR', '2026-03-01')",
                (entry[0], la[0], entry[0], la[1]),
            )
        with pytest.raises(psycopg.Error) as exc:
            conn.commit()
        assert exc.value.sqlstate == "LG001"
    finally:
        conn.close()


def test_committed_entries_cannot_be_updated_or_deleted() -> None:
    org, _, account, items = _confirmed_account()
    with psycopg.connect(DB) as conn, conn.transaction():
        posted = ledger.post(
            conn, _draft(org, account, items[0], 1500, f"commit-{uuid4()}", date(2026, 3, 1))
        )
    with psycopg.connect(DB) as conn:
        with pytest.raises(psycopg.Error) as exc:
            conn.execute(
                "update public.ledger_posting set amount_minor = 1 where entry_id = %s",
                (posted.entry_id,),
            )
        assert ledger.from_db_error(exc.value).__class__ is AppendOnlyError
        conn.rollback()
        with pytest.raises(psycopg.Error) as exc2:
            conn.execute("delete from public.ledger_entry where id = %s", (posted.entry_id,))
        assert exc2.value.sqlstate in ("42501", "LG000")


def test_the_same_key_from_two_connections_gives_one_entry() -> None:
    org, _, account, items = _confirmed_account()
    key = f"race-{uuid4()}"
    draft = _draft(org, account, items[0], 4200, key, date(2026, 3, 2))
    results: list[PostResult] = []
    first = psycopg.connect(DB)
    try:
        results.append(ledger.post(first, draft))  # holds the key until it commits

        def second() -> None:
            with psycopg.connect(DB) as conn, conn.transaction():
                results.append(ledger.post(conn, draft))

        thread = threading.Thread(target=second)
        thread.start()
        time.sleep(0.5)  # the second insert waits on the first transaction's key
        first.commit()
        thread.join(timeout=30)
    finally:
        first.close()
    assert [r.created for r in results] == [True, False]
    assert results[0].entry_id == results[1].entry_id
    with psycopg.connect(DB) as conn:
        assert (
            one(conn, "select count(*) from public.ledger_entry where idempotency_key = %s", (key,))
            == 1
        )


def test_balances_as_known_at_a_time() -> None:
    org, _, account, items = _confirmed_account()
    with psycopg.connect(DB) as conn, conn.transaction():
        posted = ledger.post(
            conn, _draft(org, account, items[1], 9900, f"known-{uuid4()}", date(2026, 3, 3))
        )
    before = datetime.now(UTC)
    time.sleep(0.05)
    with psycopg.connect(DB) as conn, conn.transaction():
        ledger.reverse(
            conn, posted.entry_id, idempotency_key=f"known-rev-{uuid4()}", reason="duplicate"
        )
    with psycopg.connect(DB) as conn:
        now_view = ledger.account_balances(conn, account, as_of=date(2026, 3, 31))
        then_view = ledger.account_balances(conn, account, as_of=date(2026, 3, 31), known_at=before)
    assert [b.balance_minor for b in now_view] == [0]
    assert [b.balance_minor for b in then_view] == [9900]


def test_python_books_match_the_chart_of_accounts() -> None:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            "select code, account_number, dimension, money_of, normal_side, client_visible from public.ledger_book"
        ).fetchall()
        types = conn.execute(
            "select code, allowed_books from public.ledger_entry_type where allowed_books is not null"
        ).fetchall()
    db = {r[0]: (r[1], r[2], r[3], r[4], r[5]) for r in rows}
    py = {
        str(b): (s.account_number, s.dimension, s.money_of, s.normal_side, s.client_visible)
        for b, s in BOOKS.items()
    }
    assert py == db
    assert {t: set(books) for t, books in types} == {
        str(t): {str(b) for b in books} for t, books in ALLOWED_BOOKS.items()
    }


def test_payment_entries_of_one_servicer_wait_for_each_other() -> None:
    """The allocation lock (design §5.2): a refund requested while an allocation of the same
    payment is being posted waits for it, then sees it, and is refused if it would overdraw."""
    org, client, account, items = _confirmed_account()
    bank, payment = uuid4(), Payment(uuid4(), 100_000, date(2026, 3, 1))
    with psycopg.connect(DB) as conn, conn.transaction():
        _bank_account(conn, org, bank)
        _payment(conn, org, bank, payment)
        post_set(conn, replace_org(cash_in(payment), org, bank))
        ledger.post(
            conn, _draft(org, account, items[0], 80_000, f"open-{uuid4()}", date(2026, 2, 1))
        )
    allocation = EntryDraft(
        organization_id=org,
        entry_type=EntryType.ALLOCATION,
        effective_date=date(2026, 3, 1),
        idempotency_key=f"alloc-{uuid4()}",
        lines=(
            Line(Book.UNALLOCATED_PAYMENT, 60_000, "EUR"),
            Line(Book.CLIENT_PAYABLE, -60_000, "EUR", client_organization_id=client),
            Line(Book.DEBTOR_RECEIVABLE, -60_000, "EUR", items[0], Component.PRINCIPAL),
            Line(Book.OWNER_CLAIM, 60_000, "EUR", component=Component.PRINCIPAL),
        ),
        account_id=account,
        payment_id=payment.id,
    )
    refund = EntryDraft(
        organization_id=org,
        entry_type=EntryType.CASH_OUT,
        effective_date=date(2026, 3, 2),
        idempotency_key=f"refund-{uuid4()}",
        lines=(
            Line(Book.UNALLOCATED_PAYMENT, 50_000, "EUR"),
            Line(Book.CLIENT_MONEY_CASH, -50_000, "EUR", bank_account_id=bank),
        ),
        payment_id=payment.id,
        reason="refund to the payer",
    )
    outcome: list[object] = []
    first = psycopg.connect(DB)
    try:
        post_set(first, allocation)  # holds the servicer's allocation lock until it commits

        def second() -> None:
            with psycopg.connect(DB) as conn:
                try:
                    with conn.transaction():
                        outcome.append(post_set(conn, refund))
                except OverdrawnError as exc:
                    outcome.append(exc)

        thread = threading.Thread(target=second)
        thread.start()
        time.sleep(0.5)
        assert thread.is_alive() and outcome == []  # waiting for the lock
        first.commit()
        thread.join(timeout=30)
    finally:
        first.close()
    assert len(outcome) == 1 and isinstance(outcome[0], OverdrawnError)  # 400.00 left, not 500.00


def replace_org(draft: EntryDraft, org: UUID, bank: UUID) -> EntryDraft:
    lines = tuple(
        Line(x.book, x.amount_minor, x.currency, bank_account_id=bank)
        if x.book is Book.CLIENT_MONEY_CASH
        else x
        for x in draft.lines
    )
    return EntryDraft(
        organization_id=org,
        entry_type=draft.entry_type,
        effective_date=draft.effective_date,
        idempotency_key=draft.idempotency_key,
        lines=lines,
        source_type=draft.source_type,
        source_id=draft.source_id,
    )


def test_a_correction_raising_a_receivable_waits_for_running_allocations() -> None:
    """Raising a receivable can push a netted credit item above zero (I6): such a correction
    takes the allocation lock too, so its commit-time check sees the running netting."""
    org, client, account, items = _confirmed_account()
    bank, payment = uuid4(), Payment(uuid4(), 100_000, date(2026, 3, 1))
    with psycopg.connect(DB) as conn, conn.transaction():
        _bank_account(conn, org, bank)
        _payment(conn, org, bank, payment)
        post_set(conn, replace_org(cash_in(payment), org, bank))
        ledger.post(
            conn, _draft(org, account, items[0], 80_000, f"open-{uuid4()}", date(2026, 2, 1))
        )
    allocation = EntryDraft(
        organization_id=org,
        entry_type=EntryType.ALLOCATION,
        effective_date=date(2026, 3, 1),
        idempotency_key=f"alloc-{uuid4()}",
        lines=(
            Line(Book.UNALLOCATED_PAYMENT, 10_000, "EUR"),
            Line(Book.CLIENT_PAYABLE, -10_000, "EUR", client_organization_id=client),
            Line(Book.DEBTOR_RECEIVABLE, -10_000, "EUR", items[0], Component.PRINCIPAL),
            Line(Book.OWNER_CLAIM, 10_000, "EUR", component=Component.PRINCIPAL),
        ),
        account_id=account,
        payment_id=payment.id,
    )
    done: list[str] = []
    first = psycopg.connect(DB)
    try:
        post_set(first, allocation)  # holds the servicer's allocation lock until it commits

        def second() -> None:
            with psycopg.connect(DB) as conn, conn.transaction():
                ledger.post(
                    conn, _draft(org, account, items[1], 500, f"fix-{uuid4()}", date(2026, 3, 2))
                )
                done.append("posted")

        thread = threading.Thread(target=second)
        thread.start()
        time.sleep(0.5)
        assert thread.is_alive() and done == []  # waiting for the lock
        first.commit()
        thread.join(timeout=30)
    finally:
        first.close()
    assert done == ["posted"]
