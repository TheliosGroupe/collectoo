# ruff: noqa: E501, PLR0913, PLR0917 - SQL fixtures read better unwrapped
"""Ledger against Postgres (M2-04, needs `make up`): property machine, commit-time checks,
append-only after commit, concurrent idempotency and balances as known at a time."""

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
from ledger_machine import ACCOUNT, CLIENT, ITEMS, ORG, Backend, Dim, LedgerMachine

from collectoo_worker import ledger
from collectoo_worker.ledger import (
    AppendOnlyError,
    Book,
    Component,
    EntryDraft,
    EntryType,
    Line,
    PostResult,
)
from collectoo_worker.ledger.model import BOOKS

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


class DbBackend:
    """One transaction per Hypothesis example, rolled back at teardown (ledger rows never persist)."""

    def __init__(self) -> None:
        self.conn = psycopg.connect(DB)
        _fixture(self.conn, ORG, CLIENT, ACCOUNT, ITEMS)

    def post(self, draft: EntryDraft) -> PostResult:
        with self.conn.transaction():
            return ledger.post(self.conn, draft)

    def reverse(self, entry_id: UUID, key: str, when: date | None) -> PostResult:
        with self.conn.transaction():
            return ledger.reverse(
                self.conn,
                entry_id,
                idempotency_key=key,
                reason="property test",
                effective_date=when,
            )

    def balances(self, as_of: date) -> dict[Dim, int]:
        rows = self.conn.execute(
            """select la.book, p.currency, la.claim_item_id::text, la.component,
                      la.client_organization_id::text, sum(p.amount_minor)::bigint
               from public.ledger_posting p join public.ledger_account la on la.id = p.ledger_account_id
               where la.organization_id = %s and p.effective_date <= %s
               group by 1, 2, 3, 4, 5 having sum(p.amount_minor) <> 0""",
            (ORG, as_of),
        ).fetchall()
        return {(r[0], r[1], r[2], r[3], r[4]): int(r[5]) for r in rows}

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
TestDbLedgerMachine.settings = settings(max_examples=25, stateful_step_count=15, deadline=None)


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
    db = {r[0]: (r[1], r[2], r[3], r[4], r[5]) for r in rows}
    py = {
        str(b): (s.account_number, s.dimension, s.money_of, s.normal_side, s.client_visible)
        for b, s in BOOKS.items()
    }
    assert py == db
