"""Helpers for the bank statement integration tests (need `make up`)."""

import hashlib
import random
import uuid
from collections import Counter
from collections.abc import Iterable
from datetime import date
from typing import Any

import psycopg
from integration_helpers import DB, as_user, make_tenant, one

from collectoo_worker.jobs.payments import make_handler, record_dead_job
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.runtime.storage import Storage
from collectoo_worker.synth.camt053 import Expected
from collectoo_worker.synth.ids import iban_fr

START = date(2026, 10, 1)


def bank_tenant(feed: str = "camt053") -> dict[str, Any]:
    """A servicer with an ops manager (aal2) and an active client-funds bank account."""
    tenant = make_tenant()
    iban = iban_fr(random.Random(str(tenant["servicer"])))
    with psycopg.connect(DB) as conn, conn.transaction():
        tenant["bank"] = one(
            conn,
            """insert into public.bank_account (organization_id, iban, currency, label, feed,
                 opened_on) values (%s, %s, 'EUR', 'Fonds de tiers', %s, '2026-01-01')
               returning id""",
            (tenant["servicer"], iban, feed),
        )
    tenant["iban"] = iban
    return tenant


def other_bank(tenant: dict[str, Any], feed: str = "camt053") -> dict[str, Any]:
    """The same servicer and staff, another active client-funds bank account."""
    iban = iban_fr(random.Random(f"{tenant['servicer']}-2"))
    with psycopg.connect(DB) as conn, conn.transaction():
        bank = one(
            conn,
            """insert into public.bank_account (organization_id, iban, currency, label, feed,
                 opened_on) values (%s, %s, 'EUR', 'Fonds de tiers 2', %s, '2026-01-01')
               returning id""",
            (tenant["servicer"], iban, feed),
        )
    return {**tenant, "bank": bank, "iban": iban}


def upload(
    tenant: dict[str, Any], store: Storage, data: bytes, name: str = "releve.xml"
) -> dict[str, Any]:
    """create_statement_upload, the upload, submit_statement_import: as the ops manager, within
    the 8 s the API allows a request."""
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["staff"], aal="aal2")
        conn.execute("set local statement_timeout = '8s'")
        target = one(
            conn,
            "select public.create_statement_upload(%s, %s, %s, %s, %s)",
            (str(uuid.uuid4()), tenant["bank"], name, hashlib.sha256(data).hexdigest(), len(data)),
        )
    if not target["uploaded"]:
        store.upload(target["bucket"], target["storage_path"], data, "application/octet-stream")
    if not target["duplicate"]:
        with psycopg.connect(DB) as conn, conn.transaction():
            as_user(conn, tenant["staff"], aal="aal2")
            conn.execute("set local statement_timeout = '8s'")
            conn.execute(
                "select public.submit_statement_import(%s, %s)",
                (str(uuid.uuid4()), target["statement_id"]),
            )
    return dict(target)


def drain(store: Storage, **kwargs: Any) -> None:
    consumer = QueueConsumer(DB, "payments", make_handler(store), on_dead=record_dead_job, **kwargs)
    while consumer.poll_once():
        pass


def statement(statement_id: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select status, error_code, error, counts, warnings, bank_check, from_date, to_date,
                      format_version
               from public.bank_statement where id = %s""",
            (statement_id,),
        ).fetchone()
    assert row is not None
    keys = (
        "status",
        "error_code",
        "error",
        "counts",
        "warnings",
        "bank_check",
        "from",
        "to",
        "format_version",
    )
    return dict(zip(keys, row, strict=True))


def paid_by_day(lines: Iterable[Expected]) -> dict[date, int]:
    """What a statement's credits that debtors paid add up to, per booking day (I11)."""
    out: Counter[date] = Counter()
    for x in lines:
        if x.direction == "credit" and x.kind in ("debtor_credit", "batch_unsplit"):
            out[x.booking_date] += x.amount_minor
    return dict(out)


def cash_in_by_day(bank: str, statement_id: str) -> dict[date, int]:
    """5120 debits of the statement's cash_in entries, per effective date."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select e.effective_date, p.amount_minor from public.ledger_entry e
               join public.ledger_posting p on p.entry_id = e.id
               join public.ledger_account la on la.id = p.ledger_account_id
               where la.bank_account_id = %s and e.entry_type = 'cash_in' and e.source_id = %s""",
            (bank, statement_id),
        ).fetchall()
    return {d: int(v) for d, v in rows}


def money_state(bank: str) -> dict[str, Any]:
    """What the imports wrote for a bank account: lines, payments, cash entries, a ledger hash."""
    with psycopg.connect(DB) as conn:
        lines = one(
            conn, "select count(*) from public.bank_transaction where bank_account_id = %s", (bank,)
        )
        payments = conn.execute(
            "select count(*), coalesce(sum(amount_minor), 0)::bigint from public.payment"
            " where bank_account_id = %s",
            (bank,),
        ).fetchone()
        cash = conn.execute(
            """select count(distinct e.id), coalesce(sum(p.amount_minor), 0)::bigint,
                      md5(coalesce(string_agg(e.id::text || p.amount_minor::text, ','
                                              order by e.id), ''))
               from public.ledger_account la
               join public.ledger_posting p on p.ledger_account_id = la.id
               join public.ledger_entry e on e.id = p.entry_id
               where la.bank_account_id = %s""",
            (bank,),
        ).fetchone()
    assert payments is not None and cash is not None
    return {
        "lines": lines,
        "payments": payments[0],
        "payments_minor": payments[1],
        "cash_entries": cash[0],
        "cash_minor": cash[1],
        "ledger_hash": cash[2],
    }
