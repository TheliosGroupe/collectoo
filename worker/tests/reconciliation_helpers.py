"""Helpers for the reconciliation integration tests (need `make up`): a synthetic world of files in
the database, statements of its credits imported and matched by the payments queue, and the
outcome scored against the truth."""

import uuid
from collections.abc import Sequence
from dataclasses import replace
from datetime import date, timedelta
from typing import Any

import psycopg
from integration_helpers import DB, one
from statement_helpers import drain, upload

from collectoo_worker.ledger.db import post
from collectoo_worker.ledger.model import Book, Component, EntryDraft, EntryType, Line
from collectoo_worker.payments.matching import ItemInfo
from collectoo_worker.runtime.storage import Storage
from collectoo_worker.synth.camt053 import make_doc, render_camt053
from collectoo_worker.synth.reconciliation import (
    Credit,
    Score,
    World,
    WorldAccount,
    credit_entries,
    line_ref,
)

CLAIM_TYPE = {
    "invoice": ("b2b_invoice", "commercial_b2b", "invoice", "legal_entity"),
    "rent": ("rent", "civil", "rent_period", "consumer"),
    "loan": ("consumer_instalment_loan", "consumer_credit_pre_ccd2", "loan_principal", "consumer"),
}
OPENED = date(2026, 9, 30)  # balances as of the cut-off; servicing starts 2026-01-01


def fresh_ids(world: World) -> World:
    """The same world under new ids (ledger rows are never deleted: every run gets its own)."""
    ids = {a.id: str(uuid.uuid4()) for a in world.accounts}
    accounts = [
        replace(
            a,
            id=ids[a.id],
            items=tuple(ItemInfo(str(uuid.uuid4()), i.ref, i.balance_minor) for i in a.items),
        )
        for a in world.accounts
    ]
    links = {iban: {ids[k]: n for k, n in v.items()} for iban, v in world.iban_links.items()}
    return World(accounts, links)


def world_into_db(tenant: dict[str, Any], world: World, *, staged: Sequence[str] = ()) -> World:
    """Writes the world (fresh ids) under the tenant's portfolio: parties, files, items, ownership,
    RF references and open balances (one adjustment entry per file). `staged` files (world ids)
    are not confirmed: no reference, no balance."""
    out = fresh_ids(world)
    staged_ids = {
        new.id for old, new in zip(world.accounts, out.accounts, strict=True) if old.id in staged
    }
    with psycopg.connect(DB) as conn, conn.transaction():
        for a in out.accounts:
            _file(conn, tenant, a, "staged" if a.id in staged_ids else a.status)
        for a in out.accounts:
            if a.id not in staged_ids and a.balance_minor > 0:
                _balance(conn, tenant, a)
    final = [
        replace(a, status="staged", rf=None) if a.id in staged_ids else a for a in out.accounts
    ]
    return World(final, out.iban_links)


def _file(
    conn: psycopg.Connection[Any], tenant: dict[str, Any], a: WorldAccount, status: str
) -> None:
    claim_type, regime, item_kind, capacity = CLAIM_TYPE[a.kind]
    conn.execute(
        """insert into public.account (id, organization_id, client_organization_id, portfolio_id,
             claim_type_code, external_ref, legal_regime, currency, status)
           values (%s, %s, %s, %s, %s, %s, %s, 'EUR', %s)""",
        (a.id, tenant["servicer"], tenant["client"], tenant["portfolio"], claim_type,
         a.external_ref, regime, status),
    )  # fmt: skip
    for n, name in enumerate(a.names):
        party = one(
            conn,
            """insert into public.party (organization_id, client_organization_id, kind,
                 display_name) values (%s, %s, %s, %s) returning id""",
            (tenant["servicer"], tenant["client"],
             "legal_entity" if capacity == "legal_entity" else "natural_person", name),
        )  # fmt: skip
        conn.execute(
            """insert into public.account_party (account_id, party_id, role, capacity)
               values (%s, %s, %s, %s)""",
            (a.id, party, "borrower" if n == 0 else "co_borrower", capacity),
        )
    for i in a.items:
        conn.execute(
            """insert into public.claim_item (id, account_id, kind, ref, original_minor)
               values (%s, %s, %s, %s, %s)""",
            (i.id, a.id, item_kind, i.ref, max(i.balance_minor, 0)),
        )
    conn.execute(
        """insert into public.claim_ownership_period (account_id, owner_organization_id,
             servicer_organization_id, mandate_type, valid_from)
           values (%s, %s, %s, 'mandate_amicable', '2026-01-01')""",
        (a.id, tenant["client"], tenant["servicer"]),
    )
    if status != "staged" and a.rf:
        conn.execute(
            """insert into public.payment_reference (organization_id, client_organization_id,
                 portfolio_id, account_id, rf) values (%s, %s, %s, %s, %s)""",
            (tenant["servicer"], tenant["client"], tenant["portfolio"], a.id, a.rf),
        )


def _balance(conn: psycopg.Connection[Any], tenant: dict[str, Any], a: WorldAccount) -> None:
    lines = [
        Line(Book.DEBTOR_RECEIVABLE, i.balance_minor, "EUR", uuid.UUID(i.id), Component.PRINCIPAL)
        for i in a.items
        if i.balance_minor > 0
    ]
    lines.append(Line(Book.OWNER_CLAIM, -a.balance_minor, "EUR", component=Component.PRINCIPAL))
    post(
        conn,
        EntryDraft(
            organization_id=uuid.UUID(str(tenant["servicer"])),
            entry_type=EntryType.ADJUSTMENT,
            effective_date=OPENED,
            idempotency_key=f"world:{a.id}",
            lines=tuple(lines),
            account_id=uuid.UUID(a.id),
            reason="synthetic world (reconciliation tests)",
        ),
    )


def pay(  # noqa: PLR0913 - the statement's identity
    tenant: dict[str, Any],
    store: Storage,
    credits: Sequence[Credit],
    *,
    prefix: str,
    start: date = date(2026, 10, 5),
    days: int = 3,
    allocate: bool = True,
    receipts: bool = False,
) -> str:
    """A camt.053 statement of these credits, imported and matched (the queue drained; with
    `allocate`, the payments ready for it are allocated too; with `receipts`, their receipts are
    issued)."""
    entries = credit_entries(credits, start=start, days=days, prefix=prefix)
    end = start + timedelta(days=days - 1)
    doc = make_doc(
        entries, iban=tenant["iban"], from_date=start, to_date=end, stmt_id=f"S-{prefix}"
    )
    target = upload(tenant, store, render_camt053(doc, "08"), name=f"{prefix}.xml")
    drain(store, allocate=allocate, receipts=receipts)
    return str(target["statement_id"])


def outcomes(statement_id: str) -> dict[str, tuple[str | None, str | None, str | None, str]]:
    """Per bank line reference: (file, review reason, method, status) of its payment."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select t.acct_svcr_ref, p.account_id::text, p.review_reason, p.match_method,
                      p.status, p.candidate_account_id::text
               from public.bank_transaction t join public.payment p on p.bank_transaction_id = t.id
               where t.statement_id = %s""",
            (statement_id,),
        ).fetchall()
    return {
        r[0]: (r[1] or (r[5] if r[2] == "account_not_confirmed" else None), r[2], r[3], r[4])
        for r in rows
    }


def score(statement_id: str, credits: Sequence[Credit], prefix: str) -> Score:
    """The database's decisions against the truth (an automatic match = a rule's method)."""
    found = outcomes(statement_id)
    s = Score()
    for k, c in enumerate(credits, start=1):
        account, reason, method, _status = found[line_ref(prefix, k)]
        automatic = method in ("rf_structured", "rf_text", "rf_body", "item_ref", "iban_memory")
        queue_reason = reason if not automatic else None
        gated = automatic and reason is not None
        s.add(c, line_ref(prefix, k), account if automatic else None, queue_reason, gated)
    return s


KIND_OF = {"b2b_invoice": "invoice", "b2c_invoice": "invoice", "rent": "rent"}


def world_from_db(tenant: dict[str, Any]) -> World:
    """The tenant's files as the generator needs them (references, items, balances, parties)."""
    with psycopg.connect(DB) as conn:
        files = conn.execute(
            """select a.id::text, a.external_ref, a.claim_type_code, a.status, r.rf
               from public.account a
               left join public.payment_reference r on r.account_id = a.id and r.status = 'active'
               where a.organization_id = %s order by a.external_ref""",
            (tenant["servicer"],),
        ).fetchall()
        items: dict[str, list[ItemInfo]] = {}
        for item, account, ref, balance in conn.execute(
            """select i.id::text, i.account_id::text, i.ref, coalesce(sum(lp.amount_minor), 0)
               from public.claim_item i
               join public.account a on a.id = i.account_id and a.organization_id = %s
               left join public.ledger_account la on la.claim_item_id = i.id
               left join public.ledger_posting lp on lp.ledger_account_id = la.id
               group by i.id, i.account_id, i.ref""",
            (tenant["servicer"],),
        ).fetchall():
            items.setdefault(account, []).append(ItemInfo(item, ref, int(balance)))
        names: dict[str, list[str]] = {}
        for account, name in conn.execute(
            """select ap.account_id::text, p.display_name from public.account_party ap
               join public.party p on p.id = ap.party_id
               where p.organization_id = %s order by ap.role, p.display_name""",
            (tenant["servicer"],),
        ).fetchall():
            names.setdefault(account, []).append(name)
    accounts = [
        WorldAccount(aid, ref, KIND_OF.get(ct, "loan"), status, rf,
                     tuple(names.get(aid, ("?",))), tuple(items.get(aid, ())))
        for aid, ref, ct, status, rf in files
    ]  # fmt: skip
    return World(accounts)
