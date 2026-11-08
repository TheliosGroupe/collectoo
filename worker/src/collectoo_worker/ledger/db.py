"""Ledger database API (M2-04): post, reverse and read balances through the SQL functions.

Nothing here commits: every call runs inside the caller's transaction (for example a queue job),
so ledger effects are exactly-once together with the job. The tables are never written directly
(tests/test_no_raw_ledger_dml.py enforces it).
"""

from __future__ import annotations

from datetime import date, datetime
from typing import Any
from uuid import UUID

import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.ledger.model import (
    ERRORS_BY_SQLSTATE,
    AlreadyReversedError,
    Balance,
    ClientMoney,
    Component,
    EntryDraft,
    LedgerError,
    PostResult,
)

Conn = psycopg.Connection[Any]


def from_db_error(exc: psycopg.Error) -> LedgerError | None:
    """The ledger exception for a database error raised by the ledger (SQLSTATE LG0xx)."""
    sqlstate = getattr(exc, "sqlstate", None) or ""
    cls = ERRORS_BY_SQLSTATE.get(sqlstate)
    if cls is None:
        return None
    message = str(exc).split("\n", 1)[0]
    if sqlstate == "LG003" and "already reversed" in message:
        return AlreadyReversedError(message)
    return cls(message)


def _call(conn: Conn, sql: str, params: tuple[Any, ...]) -> list[tuple[Any, ...]]:
    try:
        return conn.execute(sql, params).fetchall()
    except psycopg.Error as exc:
        mapped = from_db_error(exc)
        if mapped is not None:
            raise mapped from exc
        raise


def post(conn: Conn, draft: EntryDraft) -> PostResult:
    """Post an entry; the same idempotency key and request return the existing entry."""
    draft.validate()
    rows = _call(
        conn,
        "select entry_id, created from private.ledger_post(%s, %s, %s, %s, %s, %s)",
        (
            draft.organization_id,
            str(draft.entry_type),
            draft.effective_date,
            draft.idempotency_key,
            Jsonb([line.as_json() for line in draft.lines]),
            Jsonb(draft.meta_json()),
        ),
    )
    return PostResult(rows[0][0], bool(rows[0][1]))


def reverse(
    conn: Conn,
    entry_id: UUID,
    *,
    idempotency_key: str,
    reason: str,
    effective_date: date | None = None,
) -> PostResult:
    """Reverse an entry (ROADMAP `ledger.reverse`): a mirror entry, never an edit."""
    rows = _call(
        conn,
        "select entry_id, created from private.ledger_reverse(%s, %s, %s, %s)",
        (entry_id, idempotency_key, reason, effective_date),
    )
    return PostResult(rows[0][0], bool(rows[0][1]))


def ledger_balance(
    conn: Conn, ledger_account_id: UUID, *, as_of: date, known_at: datetime | None = None
) -> int:
    rows = _call(
        conn,
        "select private.ledger_balance(%s, %s, %s)",
        (ledger_account_id, as_of, known_at),
    )
    return int(rows[0][0])


def account_balances(
    conn: Conn, account_id: UUID, *, as_of: date, known_at: datetime | None = None
) -> list[Balance]:
    rows = _call(
        conn,
        """select claim_item_id, component, currency, balance_minor
           from private.account_balances(%s, %s, %s) order by claim_item_id, component""",
        (account_id, as_of, known_at),
    )
    return [Balance(r[0], Component(r[1]), r[2], int(r[3])) for r in rows]


def client_money_balances(
    conn: Conn, client_organization_id: UUID, *, as_of: date, known_at: datetime | None = None
) -> dict[str, ClientMoney]:
    rows = _call(
        conn,
        """select currency, unallocated_minor, payable_minor, held_minor
           from private.client_money_balances(%s, %s, %s)""",
        (client_organization_id, as_of, known_at),
    )
    return {r[0]: ClientMoney(r[0], int(r[1]), int(r[2]), int(r[3])) for r in rows}


def verify_pending(conn: Conn) -> None:
    """Run the deferred balance checks now (they otherwise run at commit)."""
    try:
        conn.execute("set constraints public.ledger_entry_balanced immediate")
        conn.execute("set constraints public.ledger_entry_balanced deferred")
    except psycopg.Error as exc:
        mapped = from_db_error(exc)
        if mapped is not None:
            raise mapped from exc
        raise
