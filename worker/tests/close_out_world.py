"""The close-out machine's world and the product's paths it drives (M2c-7f-2; plan
docs/design/m2c-7f-plan.md §3 M1, docs/design/m2c-7-plan.md §8.2). Needs `make up`.

One servicer with its dedicated account (5120) and its own account (5122); Martin under two
mandates (MARTIN-1: netting and claw-back, MARTIN-2: netting only), Lilas (netting, no claw-back),
Durand (no netting). Every step goes through the product: files and their debtors are boarding
data (written as the boarding commit writes them, `allocation_helpers.create_file`), everything
else through the commands as an aal2 session (`remittance_helpers.staff`, `debit_helpers.api`), the
camt.053 import and the queues' jobs (`statement_helpers.drain`, `remittance_helpers.drain`).

The bank is the model's: each statement opens with the bank's own closing balance (the world keeps
it, never the ledger's 5120) and its booking day is today. In a switch-on example everything runs
in one transaction (`one_transaction`), where `now()` stands still: two statements of one day
would tie on (to_date, finished_at), and « the last statement » (the cash check, the balance gap)
would be any of them — so there each statement's period ends one day after the previous one's
(its lines still booked today; only the period's end moves), which keeps the last one last.
"""

from __future__ import annotations

import hashlib
import json
import tempfile
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field, replace
from datetime import date, timedelta
from pathlib import Path
from typing import Any

import psycopg
from allocation_helpers import File, Item, create_file
from integration_helpers import DB, SCHEDULE, one, ready_mandate, storage
from psycopg.types.json import Jsonb
from remittance_helpers import (
    TERMS,
    USER_SQL,
    add_client,
    confirm_payout,
    own_account,
    paris_today,
    remittance_tenant,
    run_row,
    staff,
)
from statement_helpers import upload

from collectoo_worker.jobs import payments as payment_jobs
from collectoo_worker.jobs import remittances as remittance_jobs
from collectoo_worker.remittance import pain001
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.synth.camt053 import (
    FEE_CODE,
    TRANSFER_DEBIT_CODE,
    Entry,
    Tx,
    debits_of,
    make_doc,
    render_camt053,
)

SWITCH = "downloaded_file_cancellation"
CLAWBACK = {"clause_ref": "art. 7.4"}


# -- the switch-on harness: one connection, one transaction rolled back at its end ---------------


class _Shared:
    """What `psycopg.connect()` returns inside `one_transaction`: the example's one connection. A
    `with` block is a savepoint (an error rolls back to it, as a transaction would); on leaving it,
    what a block set locally for its own session (the role, the JWT claims, the statement and lock
    timeouts, the worker's actor) is set back, as the end of that block's transaction would. An
    outermost block left without an error first runs the checks its commit would fire (every
    deferred constraint trigger: LG009, LG008, a barred settlement's reversal…; review round 1,
    MACH-6), then defers them again (all of them are initially deferred): a step production refuses
    at its commit fails at that step, its savepoint rolled back."""

    def __init__(self, real: psycopg.Connection[Any], blocks: list[Any]) -> None:
        self._real = real
        self._blocks = blocks  # every _Shared of the example's one: the outermost is the last open

    def __enter__(self) -> _Shared:
        block = self._real.transaction()
        block.__enter__()
        self._blocks.append(block)
        return self

    def __exit__(self, et: Any, ev: Any, tb: Any) -> None:
        block = self._blocks.pop()
        try:
            if et is None and not self._blocks:
                try:
                    self._real.execute("set constraints all immediate")
                    self._real.execute("set constraints all deferred")
                except Exception as exc:
                    block.__exit__(type(exc), exc, exc.__traceback__)
                    raise
            block.__exit__(et, ev, tb)
        finally:
            self._real.execute("reset role")
            self._real.execute(
                "select set_config('request.jwt.claims', '', true),"
                " set_config('app.actor', '', true)"
            )
            self._real.execute("set local statement_timeout to default")
            self._real.execute("set local lock_timeout to default")

    def close(self) -> None:
        return None

    @property
    def autocommit(self) -> bool:
        return False

    @autocommit.setter
    def autocommit(self, value: bool) -> None:
        return None

    def __getattr__(self, name: str) -> Any:
        return getattr(self._real, name)


_REAL_CONNECT = psycopg.connect


def switch_is_off() -> None:
    """The switch as committed (a fresh session, never the example's): off."""
    with _REAL_CONNECT(DB) as conn:
        assert one(conn, "select private.switch_on(%s)", (SWITCH,)) is False


@contextmanager
def one_transaction() -> Iterator[psycopg.Connection[Any]]:
    """Every connection the product's paths open is the one connection of this block, in one
    transaction rolled back at its end; the switch is turned on inside it, never committed. The
    switch is off (committed) before and after."""
    switch_is_off()
    real = _REAL_CONNECT(DB)
    outer = real.transaction()
    outer.__enter__()
    blocks: list[Any] = []
    psycopg.connect = lambda *a, **k: _Shared(real, blocks)  # type: ignore[assignment]
    try:
        real.execute("update private.feature_switch set enabled = true where key = %s", (SWITCH,))
        assert one(real, "select private.switch_on(%s)", (SWITCH,)) is True
        yield real
    finally:
        psycopg.connect = _REAL_CONNECT
        try:
            outer.__exit__(psycopg.Rollback, psycopg.Rollback(), None)
        finally:
            real.close()
        switch_is_off()


# -- reads ---------------------------------------------------------------------------------------


def q(sql: str, *params: Any) -> list[tuple[Any, ...]]:
    with psycopg.connect(DB) as conn:
        return [tuple(r) for r in conn.execute(sql, params).fetchall()]


def v(sql: str, *params: Any) -> Any:
    rows = q(sql, *params)
    assert rows, sql
    return rows[0][0]


# -- the world -----------------------------------------------------------------------------------


@dataclass
class Slot:
    """One mandate of one client: what its files are boarded under."""

    name: str
    client: str
    mandate: str
    portfolio: str
    netting: bool
    clawback: bool
    tenant: dict[str, Any]


@dataclass
class World:
    tenant: dict[str, Any]  # the servicer, its dedicated account, its ops manager and admin
    slots: list[Slot]
    clients: dict[str, dict[str, Any]]  # name -> a tenant dict of the client (its first mandate)
    own: str
    own_iban: str
    admin2: str
    shifted: bool  # one transaction: each statement's period ends one day later (module doc)
    bank: int = 0  # the bank's own closing balance of the dedicated account
    statements: int = 0
    day: date = field(default_factory=date.today)  # the booking day of the last statement's lines
    tmp: Path = field(default_factory=lambda: Path(tempfile.mkdtemp(prefix="close-out-")))
    files: dict[str, bytes] = field(default_factory=dict)  # transfer file id -> its bytes

    @property
    def org(self) -> str:
        return str(self.tenant["servicer"])

    def client_names(self) -> list[str]:
        return list(self.clients)


def _set_terms(mandate: str, terms: dict[str, Any]) -> None:
    """The version's remittance terms, before any use (as remittance_tenant sets them)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("alter table public.mandate_terms disable trigger mandate_terms_guard")
        conn.execute(
            "update public.mandate_terms set remittance_terms = %s where mandate_id = %s",
            (json.dumps(terms), mandate),
        )
        conn.execute("alter table public.mandate_terms enable trigger mandate_terms_guard")


# MARTIN-2's schedule: 25 % (MARTIN-1's is 15 %): one client's run prices each mandate's invoice by
# its own schedule, and the model takes the documents' prices from the engine either way.
_RULE: dict[str, Any] = dict(SCHEDULE["rules"][0])  # type: ignore[index]
SCHEDULE_25 = {**SCHEDULE, "rules": [{**_RULE, "rate": {"kind": "flat", "rate": "0.25"}}]}


def _set_schedule(mandate: str, schedule: dict[str, Any]) -> None:
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("alter table public.mandate_terms disable trigger mandate_terms_guard")
        conn.execute(
            "update public.mandate_terms set commission_schedule = %s where mandate_id = %s",
            (json.dumps(schedule), mandate),
        )
        conn.execute("alter table public.mandate_terms enable trigger mandate_terms_guard")


def build_world(*, shifted: bool) -> World:
    martin = remittance_tenant(terms={**TERMS, "clawback": CLAWBACK})
    own, own_iban = own_account(martin)
    with psycopg.connect(DB) as conn, conn.transaction():
        portfolio = one(
            conn,
            """insert into public.portfolio (organization_id, client_organization_id, name)
               values (%s, %s, 'P2') returning id""",
            (martin["servicer"], martin["client"]),
        )
        second = {**martin, "portfolio": str(portfolio)}
        second["mandate"] = ready_mandate(conn, second, f"MARTIN-2-{uuid.uuid4().hex[:6]}")
        admin2 = uuid.uuid4()
        conn.execute(USER_SQL, (admin2, f"{admin2}@s.test"))
        conn.execute(
            "insert into public.membership (user_id, organization_id, role)"
            " values (%s, %s, 'admin')",
            (admin2, martin["servicer"]),
        )
    _set_schedule(str(second["mandate"]), SCHEDULE_25)
    lilas = add_client(martin, "Lilas")
    durand = add_client(martin, "Durand")
    _set_terms(str(durand["mandate"]), {**TERMS, "netting": None})
    slots = [
        Slot("MARTIN-1", str(martin["client"]), str(martin["mandate"]), str(martin["portfolio"]),
             True, True, martin),
        Slot("MARTIN-2", str(martin["client"]), str(second["mandate"]), str(second["portfolio"]),
             True, False, second),
        Slot("LILAS", str(lilas["client"]), str(lilas["mandate"]), str(lilas["portfolio"]),
             True, False, lilas),
        Slot("DURAND", str(durand["client"]), str(durand["mandate"]), str(durand["portfolio"]),
             False, False, durand),
    ]  # fmt: skip
    return World(
        martin,
        slots,
        {"martin": martin, "lilas": lilas, "durand": durand},
        own,
        own_iban,
        str(admin2),
        shifted,
    )


# -- the queues ----------------------------------------------------------------------------------

# What the machine drives itself is never left to the clock: pg_cron's hourly `schedule` and
# `top_ups` messages (and the nightly `invariants`) may land in the queues while an example runs;
# its drains skip them (and the documents' and receipts' renderings, which move no money), so the
# hourly jobs run when a rule says so, with a message of its own (`machine`).
SKIPPED = frozenset({"schedule", "documents", "invariants", "receipts", "receipts_sweep"})


def _only_ours(handle: Any) -> Any:
    def handler(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        kind = payload.get("type")
        if kind in SKIPPED and not payload.get("machine"):
            return
        if kind == "top_ups" and not payload.get("machine"):
            return
        handle(payload, conn)

    return handler


def drain_payments() -> None:
    consumer = QueueConsumer(DB, "payments", _only_ours(payment_jobs.make_handler(storage())),
                             on_dead=payment_jobs.record_dead_job)  # fmt: skip
    while consumer.poll_once():
        pass


def drain_remittances() -> None:
    consumer = QueueConsumer(DB, "remittances",
                             _only_ours(remittance_jobs.make_handler(storage())),
                             on_dead=remittance_jobs.record_dead_job)  # fmt: skip
    while consumer.poll_once():
        pass


def drain() -> None:
    drain_payments()
    drain_remittances()


def request_run(tenant: dict[str, Any]) -> str:
    """« Préparer maintenant »: the client's draft, prepared by the job."""
    out = staff(tenant, "select public.request_remittance_run(%s, %s, 'EUR')", str(uuid.uuid4()),
                tenant["client"])  # fmt: skip
    drain_remittances()
    return str(out["run_id"])


def approve(tenant: dict[str, Any], run: str, late_reason: str | None = None) -> None:
    """« Valider » the draft as the page shows it; the approval job run."""
    row = run_row(run)
    items = [{"run_id": run, "inputs_hash": row["inputs_hash"], "net_text": str(row["net_minor"])}]
    staff(tenant, "select public.approve_remittance_runs(%s, %s, %s, %s)", str(uuid.uuid4()),
          json.dumps(items), None, late_reason)  # fmt: skip
    drain_remittances()


# -- the bank ------------------------------------------------------------------------------------


def today() -> date:
    return paris_today()


def bank_statement(w: World, entries: list[Entry]) -> str:
    """A camt.053 of these entries (booked today), opening with the bank's last closing balance,
    imported; the payments queue drained (the import, matching, allocation, the debit job and its
    funds pass). The bank's balance moves by what the entries move."""
    day = today()
    to = day + timedelta(days=w.statements) if w.shifted else day
    w.statements += 1
    # the day the bank booked the lines (the entries' own, built before), else the statement's
    w.day = entries[0].booking_date if entries else day
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        entries, iban=w.tenant["iban"], from_date=day, to_date=to, opening_minor=w.bank,
        stmt_id=stmt,
    )  # fmt: skip
    target = upload(w.tenant, storage(), render_camt053(doc, "08"), name=f"{stmt}.xml")
    drain()
    w.bank += sum(e.signed for e in entries)
    status = v("select status from public.bank_statement where id = %s", target["statement_id"])
    assert status == "imported", (status, target)
    return str(target["statement_id"])


def ref(prefix: str) -> str:
    return f"{prefix}{uuid.uuid4().hex[:10].upper()}"


def credit_entry(amount: int, rf: str, e2e: str) -> Entry:
    r = ref("C")
    tx = Tx(amount, ref=r, end_to_end_id=e2e, name="PAYEUR", ustrd=("VIREMENT",), creditor_ref=rf)
    return Entry(amount, True, today(), today(), ref=f"N{r}", txs=(tx,))


def payment_return_entry(amount: int, e2e: str) -> Entry:
    """The payer's bank takes a payment back (a debit with the return sub-family, its end-to-end
    id)."""
    r = ref("R")
    tx = Tx(amount, ref=r, end_to_end_id=e2e, ustrd=("RETOUR MD06",), return_reason="MD06")
    return Entry(amount, False, today(), today(), reversal=True, ref=f"N{r}",
                 code="PMNT/RCDT/RRTN", txs=(tx,))  # fmt: skip


def transfer_debit_entry(amount: int, e2e: str) -> Entry:
    """The bank executes one of our transfers on its own line (its end-to-end id)."""
    return Entry(amount, False, today(), today(), ref=ref("D"), code=TRANSFER_DEBIT_CODE,
                 txs=(Tx(amount, end_to_end_id=e2e),))  # fmt: skip


def fee_entry(amount: int) -> Entry:
    return Entry(amount, False, today(), today(), ref=ref("F"), code=FEE_CODE)


def own_credit_entry(w: World, amount: int, e2e: str | None) -> Entry:
    """A credit from the servicer's own account (a top-up: its TOP id)."""
    r = ref("T")
    tx = Tx(amount, ref=f"L{r}", end_to_end_id=e2e, iban=w.own_iban, name="COLLECTOO")
    return Entry(amount, True, today(), today(), ref=r, txs=(tx,))


def file_entries(data: bytes, *, mode: str = "individual", returns: tuple[str, ...] = (),
                 only_returns: bool = False) -> list[Entry]:  # fmt: skip
    """What the bank did with a whole file, today (`synth.camt053.debits_of`)."""
    entries = debits_of(
        pain001.read(data), booking_date=today(), mode=mode, returns=list(returns),
        return_date=today(), ref_prefix=ref("B")[:8],
    )  # fmt: skip
    return [e for e in entries if e.credit] if only_returns else entries


# -- the servicer's side -------------------------------------------------------------------------


def board_file(slot: Slot, amount: int) -> File:
    """A B2B file with one invoice of `amount` (principal) on the slot's portfolio."""
    return create_file(
        slot.tenant,
        File(f"F-{uuid.uuid4().hex[:8]}", "b2b", "Débiteur SARL",
             [Item("INV-1", {"principal": amount}, today() - timedelta(days=30))]),
    )  # fmt: skip


def payment_of_line(statement: str) -> tuple[str, str]:
    """The statement's one payment: (payment, its end-to-end id)."""
    (pid, e2e), = q(
        """select p.id::text, p.end_to_end_id from public.payment p
           join public.bank_transaction t on t.id = p.bank_transaction_id
           where t.statement_id = %s""",
        statement,
    )  # fmt: skip
    return str(pid), str(e2e)


def live_allocations(payment: str) -> list[tuple[str, int]]:
    """The payment's allocation entries not reversed: (entry, what it credits 4670)."""
    rows = q(
        """select e.id::text, -coalesce((select sum(lp.amount_minor) from public.ledger_posting lp
                                         join public.ledger_account la
                                           on la.id = lp.ledger_account_id
                                         where lp.entry_id = e.id
                                           and la.book = 'client_payable'), 0)
           from public.ledger_entry e
           where e.payment_id = %s and e.entry_type = 'allocation'
             and not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = e.id)
           order by e.posted_at, e.id""",
        payment,
    )
    return [(str(r[0]), int(r[1])) for r in rows]


def reversal_of(entry: str) -> str | None:
    rows = q("select id::text from public.ledger_entry where reverses_entry_id = %s", entry)
    return str(rows[0][0]) if rows else None


def ops(w: World, sql: str, *params: Any, user: str | None = None) -> Any:
    """A command as the ops manager (or `user`) at aal2, within the API's 8 s."""
    return staff(w.tenant, sql, *params, user=user)


def download(w: World, file_id: str) -> bytes:
    """The generated file's bytes from the storage, then « Télécharger » (its sha256)."""
    path = v("select storage_path from public.transfer_file where id = %s", file_id)
    dest = w.tmp / f"{uuid.uuid4().hex}.xml"
    storage().download("transfer-files", path, dest)
    data = dest.read_bytes()
    ops(w, "select public.transfer_file_download(%s, %s)", file_id,
        hashlib.sha256(data).hexdigest())  # fmt: skip
    w.files[file_id] = data
    return data


def replace_payout_account(slot: Slot, staff_user: str) -> None:
    """The client's returned payout account retired and a new one confirmed (a new RIB)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            """update public.client_payout_account set status = 'retired', closed_by = %s,
                 closed_at = now(), closed_reason = 'Remplacé après le retour du virement'
               where client_organization_id = %s and currency = 'EUR' and status = 'returned'""",
            (staff_user, slot.client),
        )
        confirm_payout(conn, slot.tenant, slot.client)


def send_top_ups(w: World) -> None:
    """The servicer's hourly `top_ups` message (as private.queue_top_ups sends it), run."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select pgmq.send('remittances', %s)",
            (Jsonb({"type": "top_ups", "organization_id": w.org, "machine": True}),),
        )
    drain_remittances()


def checks(w: World) -> tuple[str, list[tuple[str, str, str | None, int | None]]]:
    """The nightly checks now (the job's SQL): the check run and its rows (code, severity, subject,
    amount)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        out = one(conn, "select private.run_payment_checks(%s)", (w.org,))
        rows = conn.execute(
            """select code, severity, subject_id::text, amount_minor
               from public.payment_check_result where run_id = %s order by code, subject_id""",
            (out["run_id"],),
        ).fetchall()
    return str(out["run_id"]), [(r[0], r[1], r[2], r[3]) for r in rows]


def advance_checks(w: World, on: date, *, full: bool) -> list[tuple[str, str, str | None, int]]:
    """The advance checks alone as of `on` (the nightly with p_today advanced), as pgTAP's adv_run
    runs them: their rows."""
    with psycopg.connect(DB) as conn, conn.transaction():
        run = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (w.org,),
        )
        conn.execute("select private.run_advance_checks(%s, %s, %s, %s)", (run, w.org, on, full))
        conn.execute(
            "update public.payment_check_run set finished_at = clock_timestamp() where id = %s",
            (run,),
        )
        rows = conn.execute(
            """select code, severity, subject_id::text, amount_minor
               from public.payment_check_result where run_id = %s""",
            (run,),
        ).fetchall()
    return [(r[0], r[1], r[2], int(r[3] or 0)) for r in rows]


# -- the switch-on paths -------------------------------------------------------------------------


def business_days_back(n: int) -> list[date]:
    """The last `n` business days before today, oldest first."""
    rows = q(
        """select c.day from public.business_calendar c
           where c.scope = 'FR-conservative' and not c.closed and c.day < private.paris_today()
           order by c.day desc limit %s""",
        n,
    )
    return sorted(r[0] for r in rows)


def file_dated_back(file_id: str, day: date) -> None:
    """(test only, as pgTAP's backdate) the downloaded file's execution dates set back to `day`:
    « time moved on », its execution day and the next are over. In the example's one transaction
    the pending deferred checks are run first (an ALTER TABLE refuses pending trigger events), then
    every deferrable constraint is deferred again (all of them are initially deferred)."""
    with psycopg.connect(DB) as conn:
        conn.execute("set constraints all immediate")
        conn.execute("alter table public.transfer_file disable trigger transfer_file_guard")
        conn.execute(
            """update public.transfer_file set first_execution_date = %s, last_execution_date = %s
               where id = %s""",
            (day, day, file_id),
        )
        conn.execute("alter table public.transfer_file enable always trigger transfer_file_guard")
        conn.execute(
            "alter table public.transfer_file_item disable trigger transfer_file_item_append_only"
        )
        conn.execute(
            "update public.transfer_file_item set execution_date = %s where file_id = %s",
            (day, file_id),
        )
        conn.execute(
            "alter table public.transfer_file_item enable always trigger"
            " transfer_file_item_append_only"
        )
        conn.execute("set constraints all deferred")


def evidence_statement(w: World, first: date, last: date) -> None:
    """An empty camt.053 of the dedicated account covering `first` … `last`, produced by the bank
    today (after those days): the statements show nothing of the file."""
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc([], iban=w.tenant["iban"], from_date=first, to_date=last, opening_minor=w.bank,
                   stmt_id=stmt)  # fmt: skip
    doc = replace(doc, created=f"{today().isoformat()}T00:00:01")
    upload(w.tenant, storage(), render_camt053(doc, "08"), name=f"{stmt}.xml")
    drain()


def book_line(w: World, line: str, action: str | None = None) -> dict[str, Any]:
    """« Comptabiliser… » a line the debit job left to ops: the options' proposal (of `action`),
    booked as the page books it (its request, its expected text, a motif)."""
    from debit_helpers import api  # noqa: PLC0415

    opts = api(w.tenant, "select public.transfer_line_options(%s)", line)
    assert opts is not None and opts["proposals"], ("no proposal", opts)
    props = [p for p in opts["proposals"] if action is None or p["action"] == action]
    assert props, (action, opts)
    p = props[0]
    assert p["preview"]["ok"], p
    out = api(w.tenant, "select public.book_transfer_line(%s, %s, %s, %s, %s)", str(uuid.uuid4()),
              line, Jsonb(p["request"]), p["preview"]["expected_text"],
              "Vu au relevé de la banque (machine)")  # fmt: skip
    drain()
    return {"proposal": p, "booked": out}
