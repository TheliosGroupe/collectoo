"""Reconciliation flows through the database (M2-08, needs `make up`): a payment waits for its file
and is matched again at confirmation (founder #11), or is left without mandate when the batch is
rolled back; ops unassign and assign, and the IBAN memory follows their decisions."""

import csv
import json
import random
import threading
import time
import uuid
from collections.abc import Callable
from datetime import date
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, as_user, board, drain, one, ready_mandate, storage
from psycopg.types.json import Jsonb
from reconciliation_helpers import outcomes, pay, world_into_db
from statement_helpers import bank_tenant, upload
from statement_helpers import drain as drain_payments

from collectoo_worker.jobs import matching as match_job
from collectoo_worker.jobs.payments import make_handler
from collectoo_worker.payments.matching import ItemInfo
from collectoo_worker.payments.rf import rf_make
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.runtime.storage import Storage
from collectoo_worker.synth.camt053 import make_doc, render_camt053
from collectoo_worker.synth.civil import DIALECT_SPECS, generate_civil
from collectoo_worker.synth.ids import iban_fr
from collectoo_worker.synth.reconciliation import (
    Credit,
    World,
    WorldAccount,
    credit_entries,
    line_ref,
)

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
        ready_mandate(conn, tenant, f"M-{uuid.uuid4().hex[:6]}")


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
    # matched at confirmation, then allocated by the job the match queued (M2b-4)
    assert (account, reason, method, status) == (file, None, "item_ref", "allocated")
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
        # matching only: the payments stay matched (allocated, they could not be unassigned)
        return _payment(
            pay(tenant, store, [c], prefix=prefix, start=date(2026, 10, 6), days=1, allocate=False)
        )

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
    drain_payments(store, allocate=False)  # fresh suggestions, never the file the payment left
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


# -- races with the match run (review fixes) -------------------------------------------------------
# The match job is run here by hand, in its own transaction, while another transaction (a hold
# command, a batch rollback) is open: what each must see of the other is checked on the result.

DAY = date(2026, 10, 6)


def _import_only(tenant: dict[str, Any], store: Storage, credits: list[Credit], prefix: str) -> str:
    """A statement imported; the match job it queued is dropped (the test runs it by hand)."""
    entries = credit_entries(credits, start=DAY, days=1, prefix=prefix)
    doc = make_doc(entries, iban=tenant["iban"], from_date=DAY, to_date=DAY, stmt_id=f"S-{prefix}")
    target = upload(tenant, store, render_camt053(doc, "08"), name=f"{prefix}.xml")
    handle = make_handler(store)

    def imports_only(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        if payload.get("type") == "import":
            handle(payload, conn)

    consumer = QueueConsumer(DB, "payments", imports_only)
    while consumer.poll_once():
        pass
    return str(target["statement_id"])


def _match(tenant: dict[str, Any], trigger: str = "import") -> Callable[[Any], Any]:
    def job(conn: psycopg.Connection[Any]) -> Any:
        conn.execute("select set_config('app.actor', 'worker:payments', true)")
        payload = {"organization_id": str(tenant["servicer"]), "trigger": trigger}
        return match_job.run_match(conn, payload)

    return job


def _race(holder: psycopg.Connection[Any], job: Callable[[Any], Any]) -> bool:
    """Runs `job` in its own transaction while `holder`'s transaction is open, commits `holder` as
    soon as the job waits for a lock (or has finished), and says whether the job had to wait."""
    pid: list[int] = []
    errors: list[BaseException] = []

    def run() -> None:
        try:
            with psycopg.connect(DB) as conn, conn.transaction():
                pid.append(conn.info.backend_pid)
                job(conn)
        except BaseException as exc:  # reported by the test
            errors.append(exc)

    thread = threading.Thread(target=run)
    thread.start()
    waited = False
    with psycopg.connect(DB, autocommit=True) as watch:
        deadline = time.monotonic() + 30
        while thread.is_alive() and time.monotonic() < deadline and not waited:
            if pid:
                row = watch.execute(
                    "select wait_event_type = 'Lock' from pg_stat_activity where pid = %s",
                    (pid[0],),
                ).fetchone()
                waited = bool(row and row[0])
            time.sleep(0.05)
    holder.commit()
    thread.join(60)
    assert not errors, errors
    return waited


def _state(payment: str) -> tuple[str, str | None, str | None]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select status, account_id::text, review_reason from public.payment where id = %s",
            (payment,),
        ).fetchone()
    assert row is not None
    return row[0], row[1], row[2]


def _evidence(tenant: dict[str, Any], account: str) -> str:
    """The recevabilité decision, filed on the file (a hold for surendettement needs its proof)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        return str(
            one(
                conn,
                """insert into public.document (organization_id, client_organization_id, account_id,
                     kind, storage_path, sha256, mime_type)
                   values (%s, %s, %s, 'evidence', %s, %s, 'application/pdf') returning id""",
                (
                    tenant["servicer"],
                    tenant["client"],
                    account,
                    f"test/{uuid.uuid4()}.pdf",
                    "a" * 64,
                ),
            )
        )


def _rf_credit(rf: str | None, name: str = "DURAND MARTIN", amount: int = 10_000) -> Credit:
    iban = iban_fr(random.Random(uuid.uuid4().int))
    return Credit(amount, name, iban, ("VIREMENT",), rf, None, "auto", "x")


def test_a_hold_placed_while_a_match_run_applies_holds_the_payment() -> None:
    """Surendettement (L722-5): a hold committed while the run gates payments is never missed."""
    tenant = bank_tenant()
    a, _ = _two_files(tenant)
    proof = _evidence(tenant, a.id)
    payment = _payment(_import_only(tenant, storage(), [_rf_credit(a.rf)], "HP"))
    with psycopg.connect(DB) as hold:
        as_user(hold, tenant["staff"], "aal2")
        hold.execute(
            "select public.place_account_hold(%s, %s, 'surendettement', 'C. conso L722-5', %s, %s)",
            (str(uuid.uuid4()), a.id, proof, "décision de recevabilité"),
        )
        waited = _race(hold, _match(tenant))
    assert _state(payment) == ("matched", a.id, "hold_blocks_allocation")
    assert waited  # the gating waited for the hold to commit, then saw it


def test_a_hold_lifted_while_a_match_run_applies_frees_the_payment() -> None:
    tenant = bank_tenant()
    a, _ = _two_files(tenant)
    proof = _evidence(tenant, a.id)
    _ops(
        tenant,
        "select public.place_account_hold(%s, %s, 'collective_proceeding', 'L622-7', %s, %s)",
        str(uuid.uuid4()),
        a.id,
        proof,
        "jugement d'ouverture",
    )
    payment = _payment(_import_only(tenant, storage(), [_rf_credit(a.rf)], "HL"))
    with psycopg.connect(DB) as lift:
        as_user(lift, tenant["staff"], "aal2")
        lift.execute(
            """select public.lift_account_hold(%s, (select id from public.account_hold
                 where account_id = %s and ended_at is null), %s)""",
            (str(uuid.uuid4()), a.id, "plan arrêté"),
        )
        waited = _race(lift, _match(tenant))
    assert _state(payment) == ("matched", a.id, None)  # never held by a hold that is gone
    assert waited


def test_a_batch_rolled_back_while_a_match_run_applies_leaves_no_mandate(tmp_path: Path) -> None:
    """1342-2: the payment named a file whose batch is rolled back during the run."""
    tenant = bank_tenant()
    batch = _staged_tape(tenant, tmp_path, seed=41)
    file, ref, name, amount = _invoice_of_a_staged_file(batch)
    statement = _import_only(tenant, storage(), [_credit_for(file, ref, name, amount)], "RA")
    with psycopg.connect(DB) as rollback:
        as_user(rollback, tenant["user"])
        rollback.execute("select public.rollback_boarding_batch(%s, %s)", (batch, "erreur"))
        _race(rollback, _match(tenant))
    _candidate, reason, _method, status = outcomes(statement)[line_ref("RA", 1)]
    assert (status, reason) == ("unmatched", "no_mandate")  # not « waiting » for a deleted file


def test_a_batch_rolled_back_between_the_rules_and_apply_leaves_no_mandate(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    tenant = bank_tenant()
    batch = _staged_tape(tenant, tmp_path, seed=43)
    file, ref, name, amount = _invoice_of_a_staged_file(batch)
    statement = _import_only(tenant, storage(), [_credit_for(file, ref, name, amount)], "RB")
    real_apply = match_job.apply

    def rolled_back_first(conn: psycopg.Connection[Any], *args: Any) -> Any:
        _as(tenant["user"], "select public.rollback_boarding_batch(%s, %s)", (batch, "erreur"))
        return real_apply(conn, *args)

    monkeypatch.setattr(match_job, "apply", rolled_back_first)
    with psycopg.connect(DB) as conn, conn.transaction():
        _match(tenant)(conn)
    _candidate, reason, _method, status = outcomes(statement)[line_ref("RB", 1)]
    assert (status, reason) == ("unmatched", "no_mandate")  # never « not tried yet » for ever


# -- bounded runs ----------------------------------------------------------------------------------


def _runs(tenant: dict[str, Any]) -> int:
    with psycopg.connect(DB) as conn:
        return int(
            one(
                conn,
                """select count(*) from pgmq.a_payments
                   where message ->> 'type' = 'match' and message ->> 'organization_id' = %s""",
                (str(tenant["servicer"]),),
            )
        )


def _queued(tenant: dict[str, Any], conn: psycopg.Connection[Any]) -> int:
    return int(
        one(
            conn,
            "select count(*) from pgmq.q_payments where message ->> 'organization_id' = %s",
            (str(tenant["servicer"]),),
        )
    )


def test_the_match_job_takes_bounded_chunks_and_queues_the_rest(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A backlog is never one unbounded transaction: CHUNK payments per run, the rest queued."""
    monkeypatch.setattr(match_job, "CHUNK", 2)
    tenant = bank_tenant()
    store = storage()
    a, _ = _two_files(tenant)
    statement = pay(tenant, store, [_rf_credit(a.rf, amount=1_000) for _ in range(5)], prefix="C1")
    assert {v[0] for v in outcomes(statement).values()} == {a.id}  # all five matched (R1)
    with psycopg.connect(DB) as conn:
        decisions = conn.execute(
            """select count(*), count(distinct m.payment_id) from public.payment_match m
               join public.payment p on p.id = m.payment_id
               join public.bank_transaction t on t.id = p.bank_transaction_id
               where t.statement_id = %s""",
            (statement,),
        ).fetchone()
    assert decisions == (5, 5)  # each once
    assert _runs(tenant) == 3  # 2 + 2 + 1

    # Payments the rules leave to ops stay targets of a rematch: the run still ends.
    unknown = pay(tenant, store, [_rf_credit(None, "X Y") for _ in range(5)], prefix="C2")
    assert {v[1] for v in outcomes(unknown).values()} == {"no_match"}
    runs = _runs(tenant)
    rematch = {"type": "match", "organization_id": str(tenant["servicer"]), "trigger": "rematch"}
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        match_job.run_match(conn, rematch)
        assert _queued(tenant, conn) == 1  # the continuation, in the run's own transaction ...
    with psycopg.connect(DB) as conn:
        assert _queued(tenant, conn) == 0  # ... goes with it if the run fails (redelivery replays)
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("select pgmq.send('payments', %s)", (Jsonb(rematch),))
    consumer = QueueConsumer(DB, "payments", make_handler(store))
    for _ in range(20):
        if not consumer.poll_once():
            break
    else:
        pytest.fail("the rematch never ends")
    assert _runs(tenant) - runs == 3  # the five payments left to ops, 2 + 2 + 1
