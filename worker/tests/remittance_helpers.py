"""Helpers for the remittance run integration tests (need `make up`): a servicer with its dedicated
account and clients ready for runs (billing identities, a mandate with complete terms, a confirmed
payout IBAN), files paid through the payments queue, the remittances queue drained, and the runs
read back."""

from __future__ import annotations

import json
import random
import uuid
from datetime import date, timedelta
from typing import Any

import psycopg
from allocation_helpers import File, Item, create_file, credit, statement
from integration_helpers import DB, SCHEDULE, TERMS, as_user, one, ready_mandate, storage
from psycopg.types.json import Jsonb
from statement_helpers import bank_tenant

from collectoo_worker.jobs.remittances import make_handler, record_dead_job
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.synth.ids import iban_fr

USER_SQL = (
    "insert into auth.users (id, email, aud, role)"
    " values (%s, %s, 'authenticated', 'authenticated')"
)


def paris_today() -> date:
    with psycopg.connect(DB) as conn:
        return one(conn, "select private.paris_today()")  # type: ignore[no-any-return]


def recent_business_day(back: int = 3) -> date:
    """A business day a few days ago: collections recent enough that no deadline is near."""
    with psycopg.connect(DB) as conn:
        return one(  # type: ignore[no-any-return]
            conn,
            """select max(c.day) from public.business_calendar c
               where c.day <= private.paris_today() - %s and not c.closed""",
            (back,),
        )


def confirm_payout(conn: psycopg.Connection[Any], tenant: dict[str, Any], client: str) -> str:
    iban = iban_fr(random.Random(f"payout-{client}"))
    doc = one(
        conn,
        """insert into public.document (organization_id, client_organization_id, kind, storage_path,
             sha256, mime_type) values (%s, %s, 'payout_rib', %s, %s, 'application/pdf')
           returning id""",
        (tenant["servicer"], client, f"client/test/{uuid.uuid4()}.pdf", "b" * 64),
    )
    account = one(
        conn,
        """insert into public.client_payout_account (organization_id, client_organization_id,
             currency, iban, holder_name, evidence_document_id, proposed_by)
           values (%s, %s, 'EUR', %s, 'Client SAS', %s, %s) returning id""",
        (tenant["servicer"], client, iban, doc, tenant["staff"]),
    )
    user = uuid.uuid4()
    conn.execute(
        USER_SQL,
        (user, f"{user}@c.test"),
    )
    conn.execute(
        """update public.client_payout_account set status = 'active', confirmed_by = %s,
             confirmed_at = now(), confirmed_via = 'client_portal' where id = %s""",
        (user, account),
    )
    return str(account)


def remittance_tenant(
    schedule: dict[str, Any] | None = None, terms: dict[str, Any] | None = None
) -> dict[str, Any]:
    """A servicer with its dedicated account (EUR) and one client ready for runs; the tenant's
    portfolio is the client's, under a mandate with complete terms (15 % flat, netting by
    default)."""
    tenant = bank_tenant()
    with psycopg.connect(DB) as conn, conn.transaction():
        tenant["mandate"] = ready_mandate(conn, tenant, f"MAND-{uuid.uuid4().hex[:6]}")
        if schedule is not None or terms is not None:
            # the version is in force from its signature (immutable then): set before any use
            conn.execute("alter table public.mandate_terms disable trigger mandate_terms_guard")
            conn.execute(
                """update public.mandate_terms
                   set commission_schedule = coalesce(%s, commission_schedule),
                     remittance_terms = coalesce(%s, remittance_terms) where mandate_id = %s""",
                (
                    None if schedule is None else json.dumps(schedule),
                    None if terms is None else json.dumps(terms),
                    tenant["mandate"],
                ),
            )
            conn.execute("alter table public.mandate_terms enable trigger mandate_terms_guard")
        tenant["payout"] = confirm_payout(conn, tenant, tenant["client"])
        admin = uuid.uuid4()
        conn.execute(
            USER_SQL,
            (admin, f"{admin}@s.test"),
        )
        conn.execute(
            "insert into public.membership (user_id, organization_id, role)"
            " values (%s, %s, 'admin')",
            (admin, tenant["servicer"]),
        )
        tenant["admin"] = str(admin)
    return tenant


def add_admin(tenant: dict[str, Any]) -> str:
    """An admin of the tenant's servicer (cancellations are an admin's)."""
    admin = uuid.uuid4()
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(USER_SQL, (admin, f"{admin}@s.test"))
        conn.execute(
            "insert into public.membership (user_id, organization_id, role)"
            " values (%s, %s, 'admin')",
            (admin, tenant["servicer"]),
        )
    return str(admin)


def add_client(tenant: dict[str, Any], name: str = "C2") -> dict[str, Any]:
    """Another client of the same servicer, ready for runs (its portfolio, mandate and IBAN)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        client = one(
            conn,
            """insert into public.organization (kind, servicer_organization_id, legal_name, siren)
               values ('creditor_client', %s, %s, '552100554') returning id""",
            (tenant["servicer"], name),
        )
        portfolio = one(
            conn,
            """insert into public.portfolio (organization_id, client_organization_id, name)
               values (%s, %s, 'P') returning id""",
            (tenant["servicer"], client),
        )
        other = {**tenant, "client": client, "portfolio": portfolio}
        other["mandate"] = ready_mandate(conn, other, f"MAND-{uuid.uuid4().hex[:6]}")
        other["payout"] = confirm_payout(conn, other, str(client))
    return other


def paid_file(
    tenant: dict[str, Any], amount: int, day: date | None = None, prefix: str | None = None
) -> tuple[File, str]:
    """A B2B file with one invoice of `amount`, paid in full by RF on `day`: imported, matched and
    allocated through the payments queue. Returns the file and the payment."""
    day = day or recent_business_day()
    f = create_file(
        tenant,
        File(
            f"F-{uuid.uuid4().hex[:8]}",
            "b2b",
            "Débiteur SARL",
            [Item("INV-1", {"principal": amount}, date(2026, 9, 1))],
        ),
    )
    p = prefix or f"R{uuid.uuid4().hex[:6].upper()}"
    ids = statement(tenant, storage(), [credit(amount, rf=f.rf)], p, day)
    return f, next(iter(ids.values()))


def drain() -> None:
    consumer = QueueConsumer(DB, "remittances", make_handler(storage()), on_dead=record_dead_job)
    while consumer.poll_once():
        pass


def staff(tenant: dict[str, Any], sql: str, *params: Any, user: str | None = None) -> Any:
    """A command as the ops manager (or `user`) at aal2, within the API's 8 s."""
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, user or tenant["staff"], "aal2")
        conn.execute("set local statement_timeout = '8s'")
        row = conn.execute(sql, params).fetchone()
    return row[0] if row else None


def request_run(tenant: dict[str, Any]) -> str:
    result = staff(
        tenant,
        "select public.request_remittance_run(%s, %s, 'EUR')",
        str(uuid.uuid4()),
        tenant["client"],
    )
    drain()
    return str(result["run_id"])


def run_row(run: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute("select * from public.remittance_run where id = %s", (run,))
        row = cur.fetchone()
        assert row is not None and cur.description is not None
        return {d.name: v for d, v in zip(cur.description, row, strict=True)}


def approve(
    tenant: dict[str, Any], *runs: str, day: date | None = None, late_reason: str | None = None
) -> dict[str, Any]:
    items = []
    for r in runs:
        row = run_row(r)
        items.append(
            {"run_id": r, "inputs_hash": row["inputs_hash"], "net_text": str(row["net_minor"])}
        )
    result = staff(
        tenant,
        "select public.approve_remittance_runs(%s, %s, %s, %s)",
        str(uuid.uuid4()),
        json.dumps(items),
        day,
        late_reason,
    )
    return dict(result)


def documents(run: str) -> list[dict[str, Any]]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute(
            """select kind, number, seq, issue_date, ht_minor, vat_minor, ttc_minor, settlement,
                      reason
               from public.commission_invoice where run_id = %s order by seq""",
            (run,),
        )
        assert cur.description is not None
        names = [d.name for d in cur.description]
        return [dict(zip(names, r, strict=True)) for r in cur.fetchall()]


def entry_books(entry: str) -> dict[str, int]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select la.book, sum(p.amount_minor) from public.ledger_posting p
               join public.ledger_account la on la.id = p.ledger_account_id
               where p.entry_id = %s group by la.book""",
            (entry,),
        ).fetchall()
    return {r[0]: int(r[1]) for r in rows}


def next_business_day() -> date:
    with psycopg.connect(DB) as conn:
        return one(conn, "select private.next_business_day(private.paris_today())")  # type: ignore[no-any-return]


def book_payout(run: str) -> None:
    """What M2c-6 does at the payout's debit, emulated: the remittance (+4670 N / -5120 N) and the
    settlement of the run's plan, the transfer and the run booked (as the runs' integration test
    does)."""
    r = run_row(run)
    with psycopg.connect(DB) as conn, conn.transaction():
        transfer = conn.execute(
            "select id, debtor_bank_account_id, amount_minor from public.bank_transfer"
            " where run_id = %s",
            (run,),
        ).fetchone()
        assert transfer is not None
        conn.execute("select private.ledger_post_set_begin()")
        conn.execute(
            """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type,
                 effective_date, idempotency_key, client_organization_id, source_type, source_id)
               values (1, %s, 'remittance', private.paris_today(), %s, %s, 'bank_transfer', %s)""",
            (
                r["organization_id"],
                f"remit:{transfer[0]}",
                r["client_organization_id"],
                transfer[0],
            ),
        )
        conn.execute(
            """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency,
                 bank_account_id) values (1, 1, 'client_payable', %s, 'EUR', null),
                 (1, 2, 'client_money_cash', %s, 'EUR', %s)""",
            (transfer[2], -transfer[2], transfer[1]),
        )
        entry = one(conn, "select entry_id from private.ledger_post_set()")
        conn.execute(
            "select private.post_run_settlement(%s, %s, private.paris_today())",
            (run, Jsonb(r["settlement_plan"])),
        )
        conn.execute(
            "update public.bank_transfer set status = 'booked', entry_id = %s where id = %s",
            (entry, transfer[0]),
        )
        conn.execute(
            "update public.remittance_run set status = 'booked', booked_on = private.paris_today()"
            " where id = %s",
            (run,),
        )


__all__ = ["SCHEDULE", "TERMS", "timedelta"]
