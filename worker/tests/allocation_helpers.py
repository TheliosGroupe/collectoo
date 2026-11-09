"""Helpers for the allocation integration tests (need `make up`): files with items, components and
opening balances written straight into the database, statements imported, matched and allocated
through the payments queue, and the ledger read back."""

import random
import uuid
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import date
from typing import Any

import psycopg
from integration_helpers import DB, as_user, one
from reconciliation_helpers import pay

from collectoo_worker.ledger.db import post
from collectoo_worker.ledger.model import Book, Component, EntryDraft, EntryType, Line
from collectoo_worker.payments.rf import rf_make
from collectoo_worker.runtime.storage import Storage
from collectoo_worker.synth.reconciliation import Credit, line_ref

CUT_OFF = date(2026, 9, 30)  # openings and servicing start (the batch cut-off, as boarding sets it)
REGIMES = {
    "b2b": ("b2b_invoice", "commercial_b2b", "legal_entity"),
    "consumer": ("consumer_instalment_loan", "consumer_credit_pre_ccd2", "consumer"),
}


@dataclass
class Item:
    ref: str
    balances: dict[str, int]  # component -> opening balance (minor units; negative for a credit)
    due: date | None = None
    kind: str = "invoice"
    issue: date | None = None
    id: str = field(default_factory=lambda: str(uuid.uuid4()))


@dataclass
class File:
    ref: str
    kind: str  # b2b | consumer
    debtor: str
    items: list[Item]
    status: str = "in_collection"
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    rf: str = ""
    party_id: str = ""

    def item(self, ref: str) -> Item:
        return next(i for i in self.items if i.ref == ref)


def create_file(tenant: dict[str, Any], f: File, *, party_of: File | None = None) -> File:
    """The file, its debtor (or `party_of`'s: the same debtor), items, ownership from the cut-off, an
    RF reference, and the opening balances (one correction entry, as the match tests do)."""
    claim_type, regime, capacity = REGIMES[f.kind]
    f.rf = rf_make(f"{random.Random(f.id).randrange(10**12):012d}")
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            """insert into public.account (id, organization_id, client_organization_id, portfolio_id,
                 claim_type_code, external_ref, legal_regime, currency, status)
               values (%s, %s, %s, %s, %s, %s, %s, 'EUR', %s)""",
            (f.id, tenant["servicer"], tenant["client"], tenant["portfolio"], claim_type, f.ref,
             regime, f.status),
        )  # fmt: skip
        if party_of is None:
            f.party_id = str(
                one(
                    conn,
                    """insert into public.party (organization_id, client_organization_id, kind,
                         display_name) values (%s, %s, %s, %s) returning id""",
                    (tenant["servicer"], tenant["client"],
                     "legal_entity" if capacity == "legal_entity" else "natural_person", f.debtor),
                )  # fmt: skip
            )
        else:
            f.party_id = party_of.party_id
        conn.execute(
            """insert into public.account_party (account_id, party_id, role, capacity)
               values (%s, %s, 'borrower', %s)""",
            (f.id, f.party_id, capacity),
        )
        for i in f.items:
            conn.execute(
                """insert into public.claim_item (id, account_id, kind, ref, issue_date, due_date,
                     original_minor) values (%s, %s, %s, %s, %s, %s, %s)""",
                (i.id, f.id, i.kind, i.ref, i.issue, i.due, abs(sum(i.balances.values()))),
            )
        conn.execute(
            """insert into public.claim_ownership_period (account_id, owner_organization_id,
                 servicer_organization_id, mandate_type, valid_from)
               values (%s, %s, %s, 'mandate_amicable', %s)""",
            (f.id, tenant["client"], tenant["servicer"], CUT_OFF),
        )
        conn.execute(
            """insert into public.payment_reference (organization_id, client_organization_id,
                 portfolio_id, account_id, rf) values (%s, %s, %s, %s, %s)""",
            (tenant["servicer"], tenant["client"], tenant["portfolio"], f.id, f.rf),
        )
        lines: list[Line] = []
        per_component: dict[str, int] = {}
        for i in f.items:
            for comp, amount in i.balances.items():
                if amount:
                    lines.append(
                        Line(Book.DEBTOR_RECEIVABLE, amount, "EUR", uuid.UUID(i.id), Component(comp))
                    )
                    per_component[comp] = per_component.get(comp, 0) + amount
        for comp, total in per_component.items():
            if total:
                lines.append(Line(Book.OWNER_CLAIM, -total, "EUR", component=Component(comp)))
        post(
            conn,
            EntryDraft(
                organization_id=uuid.UUID(str(tenant["servicer"])),
                entry_type=EntryType.ADJUSTMENT,
                effective_date=CUT_OFF,
                idempotency_key=f"opening:{f.id}",
                lines=tuple(lines),
                account_id=uuid.UUID(f.id),
                reason="ouverture (tests d'imputation)",
            ),
        )
    return f


def statement(
    tenant: dict[str, Any], store: Storage, credits: Sequence[Credit], prefix: str, day: date
) -> dict[str, str]:
    """Imported, matched and allocated (the payments queue drained); payment id per line, in order."""
    sid = pay(tenant, store, credits, prefix=prefix, start=day, days=1)
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select t.acct_svcr_ref, p.id::text from public.bank_transaction t
               join public.payment p on p.bank_transaction_id = t.id where t.statement_id = %s""",
            (sid,),
        ).fetchall()
    found = dict(rows)
    return {line_ref(prefix, k): found[line_ref(prefix, k)] for k in range(1, len(credits) + 1)}


def credit(amount: int, text: str = "VIREMENT", rf: str | None = None, name: str = "PAYEUR") -> Credit:
    iban = None  # no IBAN: nothing for the IBAN memory to learn across tests
    return Credit(amount, name, iban, (text,), rf, None, "auto", "allocation")


def state(payment: str) -> tuple[str, str | None]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select status, review_reason from public.payment where id = %s", (payment,)
        ).fetchone()
    assert row is not None
    return row[0], row[1]


def allocations(payment: str, live: bool = True) -> list[tuple[str, str, int]]:
    """(item ref, component, amount credited) of the payment's allocation entries (live ones only, or
    every one), in entry and line order."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select i.ref, la.component, -lp.amount_minor
               from public.ledger_entry e
               join public.ledger_posting lp on lp.entry_id = e.id
               join public.ledger_account la on la.id = lp.ledger_account_id
                 and la.book = 'debtor_receivable'
               join public.claim_item i on i.id = la.claim_item_id
               where e.payment_id = %s and e.entry_type = 'allocation'
                 and (not %s or not exists (select 1 from public.ledger_entry r
                                            where r.reverses_entry_id = e.id))
               order by e.posted_at, e.id, lp.line_no""",
            (payment, live),
        ).fetchall()
    return [(r[0], r[1], int(r[2])) for r in rows]


def entry_lines(entry_id: str) -> list[tuple[str, str | None, str | None, int]]:
    """(book, item ref, component, amount) of an entry, in line order."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select la.book, i.ref, la.component, lp.amount_minor
               from public.ledger_posting lp
               join public.ledger_account la on la.id = lp.ledger_account_id
               left join public.claim_item i on i.id = la.claim_item_id
               where lp.entry_id = %s order by lp.line_no""",
            (entry_id,),
        ).fetchall()
    return [(r[0], r[1], r[2], int(r[3])) for r in rows]


def balances(f: File) -> dict[tuple[str, str], int]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select i.ref, la.component, sum(lp.amount_minor)
               from public.ledger_account la
               join public.ledger_posting lp on lp.ledger_account_id = la.id
               join public.claim_item i on i.id = la.claim_item_id
               where la.account_id = %s group by i.ref, la.component""",
            (f.id,),
        ).fetchall()
    return {(r[0], r[1]): int(r[2]) for r in rows}


def ops(tenant: dict[str, Any], sql: str, *params: Any) -> Any:
    """A command as the ops manager at aal2, within the 8 s the API allows a request."""
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["staff"], "aal2")
        conn.execute("set local statement_timeout = '8s'")
        row = conn.execute(sql, params).fetchone()
    return row[0] if row else None


def evidence(tenant: dict[str, Any], account: str) -> str:
    with psycopg.connect(DB) as conn, conn.transaction():
        return str(
            one(
                conn,
                """insert into public.document (organization_id, client_organization_id, account_id,
                     kind, storage_path, sha256, mime_type)
                   values (%s, %s, %s, 'evidence', %s, %s, 'application/pdf') returning id""",
                (tenant["servicer"], tenant["client"], account, f"test/{uuid.uuid4()}.pdf", "a" * 64),
            )
        )


def client_money(tenant: dict[str, Any]) -> dict[str, int]:
    """Σ per client-money book (5120, 4710, 4670) of the servicer."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select la.book, coalesce(sum(lp.amount_minor), 0)
               from public.ledger_account la
               join public.ledger_posting lp on lp.ledger_account_id = la.id
               where la.organization_id = %s
                 and la.book in ('client_money_cash', 'unallocated_payment', 'client_payable')
               group by la.book""",
            (tenant["servicer"],),
        ).fetchall()
    return {r[0]: int(r[1]) for r in rows}
