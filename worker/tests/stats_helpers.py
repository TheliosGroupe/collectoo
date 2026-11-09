"""Statistics as autovacuum can leave them in the middle of a scale run (CI scale job, M2b-6): a
table loaded a moment ago and not analysed yet, or analysed before the rows a test then adds. The
scale tests put the tables they load into such a state on purpose, so a plan that rests on fresh
statistics fails every run, not by chance in CI. Needs `make up`."""

from collections.abc import Iterator
from contextlib import contextmanager
from datetime import date
from typing import Any, LiteralString

import psycopg
from integration_helpers import DB
from psycopg import sql
from psycopg.conninfo import make_conninfo
from statement_helpers import bank_tenant, drain, upload

from collectoo_worker.runtime.storage import Storage
from collectoo_worker.synth.camt053 import generate_entries, make_doc, render_camt053

# The local stack's superuser (Supabase CLI default, as the CI workflow uses it): only to clear
# statistics, which the tables' owner cannot do.
ADMIN = make_conninfo(DB, user="supabase_admin")


def _table(name: str) -> sql.Composed:
    schema, table = name.split(".")
    return sql.SQL("{}.{}").format(sql.Identifier(schema), sql.Identifier(table))


@contextmanager
def frozen_statistics(*tables: str) -> Iterator[psycopg.Connection[Any]]:
    """Autovacuum kept off these tables meanwhile: their statistics stay as the test sets them.
    Afterwards the setting is reset and the tables are analysed, whatever happened."""
    with psycopg.connect(DB, autocommit=True) as conn:
        for t in tables:
            conn.execute(
                sql.SQL("alter table {} set (autovacuum_enabled = false)").format(_table(t))
            )
        try:
            yield conn
        finally:
            for t in tables:
                conn.execute(sql.SQL("alter table {} reset (autovacuum_enabled)").format(_table(t)))
                conn.execute(sql.SQL("analyze {}").format(_table(t)))


def analyse(conn: psycopg.Connection[Any], *tables: str) -> None:
    for t in tables:
        conn.execute(sql.SQL("analyze {}").format(_table(t)))


def forget_statistics(table: str) -> None:
    """The table as autovacuum leaves it until its first analyse: no row count, no column
    statistics (what the planner had of ledger_entry when payment_positions took 439 s in CI)."""
    with psycopg.connect(ADMIN, autocommit=True) as admin:
        admin.execute("delete from pg_statistic where starelid = %s::regclass", (table,))
        admin.execute(
            "update pg_class set reltuples = -1, relpages = 0 where oid = %s::regclass", (table,)
        )


def estimated_rows(
    conn: psycopg.Connection[Any], query: LiteralString, params: tuple[Any, ...]
) -> int:
    """What the planner expects `query` (a SELECT) to return."""
    row = conn.execute("explain (format json) " + query, params).fetchone()
    assert row is not None
    return int(row[0][0]["Plan"]["Plan Rows"])


def lines_of_another_account(store: Storage, bank_account_id: str, lines: int = 500) -> None:
    """Bank lines of another account in bank_transaction (a throwaway servicer's statement), unless
    there are some already: analysed then, the statistics know no line of `bank_account_id` (an
    account with none yet), as CI met them after the earlier scale tests."""
    with psycopg.connect(DB) as conn:
        found = conn.execute(
            "select exists (select 1 from public.bank_transaction where bank_account_id <> %s)",
            (bank_account_id,),
        ).fetchone()
    if found and found[0]:
        return
    tenant = bank_tenant()
    start = date(2026, 10, 1)
    entries = generate_entries(lines, seed=5, start=start, days=1)
    doc = make_doc(entries, iban=tenant["iban"], from_date=start, to_date=start, stmt_id="S-OTHER")
    upload(tenant, store, render_camt053(doc, "08"), name="autre.xml")
    drain(store)
