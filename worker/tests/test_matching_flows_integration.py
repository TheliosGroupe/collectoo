"""Reconciliation flows through the database (M2-08, needs `make up`): a payment waits for its file
and is matched again at confirmation (founder #11), or is left without mandate when the batch is
rolled back; ops unassign and assign, and the IBAN memory follows their decisions."""

import csv
import json
import random
import uuid
from datetime import date
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, as_user, board, drain, one, storage
from reconciliation_helpers import outcomes, pay, world_into_db
from statement_helpers import bank_tenant
from statement_helpers import drain as drain_payments

from collectoo_worker.payments.matching import ItemInfo
from collectoo_worker.payments.rf import rf_make
from collectoo_worker.synth.civil import DIALECT_SPECS, generate_civil
from collectoo_worker.synth.ids import iban_fr
from collectoo_worker.synth.reconciliation import Credit, World, WorldAccount, line_ref

pytestmark = pytest.mark.integration


# -- a file not confirmed yet --------------------------------------------------------------------


def _staged_tape(tenant: dict[str, Any], tmp_path: Path, seed: int) -> str:
    """A small B2B tape boarded and committed: its files are staged (not confirmed)."""
    table, _ = generate_civil("b2b_invoice", "fr_semicolon", 12, seed, defect_rate=0)
    path = tmp_path / "factures.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        csv.writer(fh, delimiter=DIALECT_SPECS["fr_semicolon"].delimiter).writerows(table)
    store = storage()
    batch = board(tenant, store, path)
    drain(store)
    _as(tenant["user"], "select public.approve_mapping(%s, %s)", (batch, json.dumps({})))
    drain(store)
    _as(tenant["user"], "select public.commit_boarding_batch(%s, null)", (batch,))
    drain(store)
    with psycopg.connect(DB) as conn:
        assert one(conn, "select status from public.boarding_batch where id = %s", (batch,)) == (
            "committed"
        )
    return batch


def _as(user: str, sql: str, params: tuple[Any, ...], aal: str = "aal1") -> Any:
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, user, aal)
        conn.execute("set local statement_timeout = '8s'")  # what the API allows a request
        row = conn.execute(sql, params).fetchone()
    return row[0] if row else None


def _invoice_of_a_staged_file(batch: str) -> tuple[str, str, str, int]:
    """(file, invoice ref, debtor name, invoice amount) of one staged file of the batch."""
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select a.id::text, i.ref, p.display_name, i.original_minor
               from public.account a
               join public.claim_item i on i.account_id = a.id
               join public.account_party ap on ap.account_id = a.id
               join public.party p on p.id = ap.party_id
               where a.boarding_batch_id = %s and a.status = 'staged' and i.original_minor > 1000
               order by a.external_ref, i.ref limit 1""",
            (batch,),
        ).fetchone()
    assert row is not None
    return row[0], row[1], row[2], int(row[3])


def _credit_for(file: str, ref: str, name: str, amount: int) -> Credit:
    iban = iban_fr(random.Random(uuid.uuid4().int))
    text = (f"REGLT FACT {ref}",)
    return Credit(amount // 2, name.upper(), iban, text, None, file, "auto", "item_ref")


def _mandate(tenant: dict[str, Any]) -> None:
    with psycopg.connect(DB) as conn, conn.transaction():
        mandate = one(
            conn,
            "insert into public.mandate (organization_id, client_organization_id, reference,"
            " mandate_type, signed_on) values (%s, %s, %s, 'mandate_amicable', '2026-01-01')"
            " returning id",
            (tenant["servicer"], tenant["client"], f"M-{uuid.uuid4().hex[:6]}"),
        )
        conn.execute(
            "insert into public.mandate_terms (mandate_id, valid_from, commission_rate)"
            " values (%s, '2026-01-01', 0.15)",
            (mandate,),
        )
        conn.execute(
            "update public.portfolio set mandate_id = %s where id = %s",
            (mandate, tenant["portfolio"]),
        )


def test_a_payment_waits_for_its_file_and_is_matched_at_confirmation(tmp_path: Path) -> None:
    tenant = bank_tenant()
    batch = _staged_tape(tenant, tmp_path, seed=31)
    file, ref, name, amount = _invoice_of_a_staged_file(batch)
    statement = pay(tenant, storage(), [_credit_for(file, ref, name, amount)], prefix="W")
    candidate, reason, method, status = outcomes(statement)[line_ref("W", 1)]
    assert (candidate, reason, method, status) == (file, "account_not_confirmed", None, "unmatched")

    _mandate(tenant)
    _as(tenant["staff"], "select public.confirm_boarding_batch(%s)", (batch,), aal="aal2")
    drain(storage())  # the confirmation job posts the openings and queues the rematch
    drain_payments(storage())
    account, reason, method, status = outcomes(statement)[line_ref("W", 1)]
    assert (account, reason, method, status) == (file, None, "item_ref", "matched")
    with psycopg.connect(DB) as conn:
        trigger = one(
            conn,
            "select trigger from public.payment_match where account_id = %s and action = 'assign'",
            (file,),
        )
    assert trigger == "rematch"


def test_a_rolled_back_file_leaves_its_payment_without_mandate(tmp_path: Path) -> None:
    """1342-2: money paid for a claim outside any mandate is refunded unless the client ratifies."""
    tenant = bank_tenant()
    batch = _staged_tape(tenant, tmp_path, seed=37)
    file, ref, name, amount = _invoice_of_a_staged_file(batch)
    statement = pay(tenant, storage(), [_credit_for(file, ref, name, amount)], prefix="R")
    _as(tenant["user"], "select public.rollback_boarding_batch(%s, %s)", (batch, "erreur"))
    _candidate, reason, _method, status = outcomes(statement)[line_ref("R", 1)]
    assert (reason, status) == ("no_mandate", "unmatched")


# -- ops decide; the IBAN memory follows -----------------------------------------------------------


def _two_files(tenant: dict[str, Any]) -> tuple[WorldAccount, WorldAccount]:
    def file(n: int, name: str) -> WorldAccount:
        items = (ItemInfo(f"i{n}", f"FX-2026-{n:05d}", 500_000),)
        rf = rf_make(f"{uuid.uuid4().int % 10**12:012d}")
        return WorldAccount(f"a{n}", f"DOS-{n:05d}", "invoice", "in_collection", rf, (name,), items)

    world = world_into_db(tenant, World([file(1, "Durand Martin"), file(2, "Lefebvre Alice")]))
    a, b = world.accounts
    return a, b


def _ops(tenant: dict[str, Any], sql: str, *params: Any) -> Any:
    return _as(tenant["staff"], sql, params, aal="aal2")


def _history(payment: str) -> list[tuple[str, str, str | None, bool]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select action, method, rule, iban_link from public.payment_match
               where payment_id = %s order by decided_at, id""",
            (payment,),
        ).fetchall()
    return [(r[0], r[1], r[2], r[3]) for r in rows]


def _payment(statement: str) -> str:
    with psycopg.connect(DB) as conn:
        return str(
            one(
                conn,
                """select p.id from public.payment p join public.bank_transaction t
                     on t.id = p.bank_transaction_id where t.statement_id = %s""",
                (statement,),
            )
        )


def _links(tenant: dict[str, Any], iban: str) -> dict[str, int]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select account_id::text, confirmed_count from private.payer_account_link
               where organization_id = %s and payer_iban = %s""",
            (tenant["servicer"], iban),
        ).fetchall()
    return {r[0]: int(r[1]) for r in rows}


def test_ops_unassign_and_assign_and_the_iban_memory_follows() -> None:
    tenant = bank_tenant()
    store = storage()
    a, b = _two_files(tenant)
    iban = iban_fr(random.Random(uuid.uuid4().int))

    def credit(prefix: str, ref: str | None = None) -> str:
        c = Credit(10_000, "PARENT PAYEUR", iban, ("VIREMENT",), ref, None, "auto", "x")
        return _payment(pay(tenant, store, [c], prefix=prefix, start=date(2026, 10, 6), days=1))

    p1 = credit("P1", a.rf)  # R1: the RF of A, from IBAN X: X now paid A
    assert _links(tenant, iban) == {a.id: 1}
    p2 = credit("P2")  # R4: X paid A and no other file
    assert _history(p2) == [("assign", "iban_memory", "R4", False)]
    assert _links(tenant, iban) == {a.id: 1}  # an R4 match does not teach the memory again

    key = str(uuid.uuid4())
    sql = "select public.unassign_payment(%s, %s, %s)"
    _ops(tenant, sql, key, p2, "le payeur règle aussi le dossier de sa fille")
    _ops(tenant, sql, key, p2, "le payeur règle aussi le dossier de sa fille")  # same key: replay
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        _ops(tenant, sql, key, p2, "autre motif")  # the key of another request
    drain_payments(store)  # fresh suggestions for ops, never the file the payment left
    with psycopg.connect(DB) as conn:
        status, reason = conn.execute(
            "select status, review_reason from public.payment where id = %s", (p2,)
        ).fetchone() or ("", "")
        left = conn.execute(
            "select count(*) from public.payment_match_candidate"
            " where payment_id = %s and account_id = %s",
            (p2, a.id),
        ).fetchone()
    assert (status, reason, left) == ("unmatched", "no_match", (0,))

    assign = "select public.assign_payment(%s, %s, %s, null, %s)"
    out = _ops(
        tenant,
        assign,
        str(uuid.uuid4()),
        p2,
        json.dumps([{"account_id": b.id}]),
        "courriel du payeur",
    )
    assert out == {"payment_id": p2, "account_id": b.id, "review_reason": None}
    assert _links(tenant, iban) == {a.id: 1, b.id: 1}
    assert _history(p2) == [
        ("assign", "iban_memory", "R4", False),
        ("unassign", "manual", None, False),
        ("assign", "manual", None, True),
    ]

    p3 = credit("P3")  # X paid two open files: ops decide
    with psycopg.connect(DB) as conn:
        assert conn.execute(
            "select status, review_reason from public.payment where id = %s", (p3,)
        ).fetchone() == ("unmatched", "ambiguous")

    _ops(tenant, sql, str(uuid.uuid4()), p1, "référence imprimée sur le mauvais courrier")
    assert _links(tenant, iban) == {a.id: 0, b.id: 1}  # what P1 taught is forgotten
    p4 = credit("P4")
    assert _history(p4) == [("assign", "iban_memory", "R4", False)]
    with psycopg.connect(DB) as conn:
        assert one(conn, "select account_id::text from public.payment where id = %s", (p4,)) == b.id
