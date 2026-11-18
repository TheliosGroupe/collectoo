"""M2c-6b-2b, the command against every other writer of its rows, two connections at a time
(needs `make up`; plan docs/design/m2c-6b-2-plan.md §3.8, §8.2 « Concurrency (6b-2b) »;
ADR-0014 « M2c-6b-2b deferred tests »). In each pair one call waits or is refused, no deadlock
(40P01) occurs, the line is booked once, and the nightly checks stay clean:

* another servicer's rows are never locked by the command (critic CSO-5): its ids refused before any
  lock; a line whose bank-given PmtInfId is another servicer's lot locks none of that servicer's
  files, transfers, runs or accounts (probed FOR UPDATE NOWAIT from a second connection while the
  command's transaction is open);
* cancel_remittance_run and the command on the client's run, each first;
* two commands naming one transfer on two lines (its RMT line and a reference-less one): booked
  once, the other refused;
* link_debit « Frais bancaires » and « Classer sans comptabiliser » and the command on the same
  reference-less line, each first (M2c-6b-2c: on a line a payout of ours may be, « Lier » refuses
  both before any lock, payout_candidate; the pair runs on a reference-less debit to our own
  account, which the command books « Virement au compte propre »);
* a refund holding the late line's payment FOR UPDATE (as the M2b pass's post_debit_links does)
  and the command's payout part, which key-share locks it before the allocation lock — staged as
  6b-1's concurrency-2: a third session holds the allocation lock;
* the prepare job of the client's draft (its facts read under the old token) and the command's
  requeue: the old token's write is skipped, the new token's job prepares the draft;
* approve_remittance_runs and the command on the client's draft, each first: the approval job of a
  token the command replaced does nothing;
* retire_payout_account / confirm_payout_account and an unplanned return marking the payout account
  returned, each first;
* the debit job's funds pass and the command on the same line;
* generate_transfer_file (a sweep of the servicer's share) and the command lowering the share,
  each first: the sweep never exceeds the share (a file generated first is superseded at its first
  download, 6b-2a's re-check).
"""

from __future__ import annotations

import hashlib
import json
import threading
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

import psycopg
import pytest
from debit_helpers import api
from integration_helpers import DB, as_user, storage
from psycopg.types.json import Jsonb
from remittance_helpers import (
    add_admin,
    approve,
    paris_today,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)
from remittance_helpers import drain as drain_remittances
from statement_helpers import drain as drain_payments
from test_debit_bookings_integration import (
    COMMANDS,
    DEADLOCK_TIMEOUT_MS,
    REQUEST_REFUND,
    _downloaded,
    _lock_timeout_ms,
    _no_violation,
    _refund_args,
    _retried,
    _run_transfer,
    _session,
    _transfer,
    _waits,
    late_run,  # noqa: F401 - the fixture
)
from test_transfer_files_integration import _bytes, _file_row, _own_account, _two_runs
from test_transfer_line_foundations_integration import (
    _booked,
    _day,
    _return_entries,
    _started,
    _statement,
)
from test_transfer_line_ops_integration import (
    REASON,
    _book,
    _client_line,
    _debit_again,
    _options,
)
from test_transfer_line_ops_more_integration import _executed_on, _line_bookings, _lines

from collectoo_worker.jobs.remittances import load_facts, write_draft
from collectoo_worker.remittance import pain001
from collectoo_worker.remittance.run import prepare_run

pytestmark = pytest.mark.integration
BOOK = "select public.book_transfer_line(%s, %s, %s, %s, %s)"


def _proposal(tenant: dict[str, Any], line: str, action: str) -> dict[str, Any]:
    (p,) = [p for p in _options(tenant, line)["proposals"] if p["action"] == action]
    return dict(p)


def _booker(tenant: dict[str, Any], line: str, proposal: dict[str, Any]) -> Callable[..., Any]:
    """The command as the page sends it, in the caller's transaction (as the ops manager, aal2)."""
    args = (str(uuid.uuid4()), line, Jsonb(proposal["request"]),
            proposal["preview"]["expected_text"], REASON)  # fmt: skip

    def book(conn: psycopg.Connection[Any]) -> Any:
        as_user(conn, tenant["staff"], "aal2")
        row = conn.execute(BOOK, args).fetchone()
        conn.execute("reset role")
        return [b["kind"] for b in row[0]["bookings"]] if row else None

    return book


def _as(user: str, sql: str, *params: Any) -> Callable[..., Any]:
    def call(conn: psycopg.Connection[Any]) -> Any:
        as_user(conn, user, "aal2")
        row = conn.execute(sql, params).fetchone()
        conn.execute("reset role")
        return row[0] if row else None

    return call


def _outcome(exc: psycopg.Error) -> tuple[str | None, str | None]:
    return (exc.sqlstate, exc.diag.message_primary)


def _hold(
    first: Callable[..., Any], second: Callable[..., Any], *, wait_s: float = 3.0
) -> dict[str, Any]:
    """A runs `first` in its transaction and keeps it open; B runs `second` in its own meanwhile;
    once B waits on a lock (or after `wait_s`), A commits; B is joined. Each outcome: its value, or
    its error's SQLSTATE and message; `b_waited`: whether B waited on a lock A held."""
    out: dict[str, Any] = {}
    pids: dict[str, int] = {}

    def run_b() -> None:
        try:
            with _session() as conn, conn.transaction():
                pids["b"] = conn.info.backend_pid
                out["b"] = second(conn)
        except psycopg.Error as exc:
            out["b"] = _outcome(exc)

    t = threading.Thread(target=run_b)
    with _session() as conn:
        try:
            with conn.transaction():
                out["a"] = first(conn)
                t.start()
                _started(pids, "b")
                out["b_waited"] = _waits(pids["b"], None, timeout_s=wait_s)
        except psycopg.Error as exc:
            out["a"] = _outcome(exc)
    if t.is_alive() or "b" in pids:
        t.join(60)
    assert not t.is_alive() and "b" in pids, out
    assert "40P01" not in json.dumps(out, default=str), out
    return out


def _refused(out: Any, code: str | None = None) -> bool:
    """A command's refusal (23514 « transfer line booking refused: <code> », or a 55P03 retry)."""
    return (
        isinstance(out, tuple)
        and out[0] in ("23514", "55P03")
        and (code is None or out[1] == f"transfer line booking refused: {code}")
    )


# -- another servicer's rows are never locked ---------------------------------------------------


def _foreign_line(tenant: dict[str, Any], pmt_inf_id: str, iban: str, amount: int) -> str:
    """A debit on the tenant's statement whose bank-given PmtInfId is `pmt_inf_id`, to `iban`
    (inserted, committed; the debit job not run on it)."""
    org, day = str(tenant["servicer"]), paris_today()
    with psycopg.connect(DB) as conn:
        st = conn.execute(
            """insert into public.bank_statement (organization_id, bank_account_id, currency,
                 format, file_name, file_sha256, size_bytes, storage_path)
               values (%s, %s, 'EUR', 'camt053', 'f.xml', %s, 1, %s) returning id""",
            (org, tenant["bank"], uuid.uuid4().hex * 2, f"test/{uuid.uuid4()}"),
        ).fetchone()
        assert st is not None
        conn.execute(
            """update public.bank_statement set status = 'uploaded', uploaded_at = now()
               where id = %s""",
            (st[0],),
        )
        line = conn.execute(
            """insert into public.bank_transaction (organization_id, bank_account_id, statement_id,
                 line_no, dedup_key, direction, amount_minor, currency, booking_date, kind,
                 payment_info_id, counterparty_iban)
               values (%s, %s, %s, 1, %s, 'debit', %s, 'EUR', %s, 'other_debit', %s, %s)
               returning id""",
            (org, tenant["bank"], st[0], f"t:{st[0]}:1", amount, day, pmt_inf_id, iban),
        ).fetchone()
        assert line is not None
        conn.execute(
            """update public.bank_statement set status = 'imported', from_date = %s, to_date = %s,
                 opening_booked_minor = 0, closing_booked_minor = 0, counts = '{}',
                 finished_at = now() where id = %s""",
            (day, day, st[0]),
        )
    return str(line[0])


def _nowait(table: str, ids: list[Any]) -> list[str]:
    """The rows of `table` another session holds a lock on (FOR UPDATE NOWAIT, each probed in its
    own transaction)."""
    held = []
    with psycopg.connect(DB, autocommit=True) as conn:
        for i in ids:
            try:
                with conn.transaction():
                    conn.execute(
                        f"select 1 from public.{table} where id = %s for update nowait",  # noqa: S608
                        (i,),
                    )
            except psycopg.errors.LockNotAvailable:
                held.append(str(i))
    return held


def test_another_servicer_s_rows_are_never_locked_by_the_command(tmp_path: Path) -> None:
    other, _c2, r1, r2 = _two_runs()
    f, data = _downloaded(other, tmp_path)  # the other servicer's lot, handed out
    (pmt,) = {p.pmt_inf_id for p in pain001.read(data).payment_infos}
    theirs = {
        "transfer_file": [f["id"]],
        "bank_transfer": [_run_transfer(r)["id"] for r in (r1, r2)],
        "remittance_run": [r1, r2],
        "bank_account": [other["bank"]],
    }
    tenant = remittance_tenant()
    _own_account(tenant)
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select iban from public.client_payout_account where id = %s", (tenant["payout"],)
        ).fetchone()
    assert row is not None
    line = _foreign_line(tenant, pmt, str(row[0]), 1_234)
    opts = _options(tenant, line)
    assert opts["class"] == "E0" and opts["members"] is None, opts
    assert str(f["id"]) not in json.dumps(opts) and str(r1) not in json.dumps(opts)
    proposal = _proposal(tenant, line, "unplanned_payout")
    # the command books the line (its client part) and keeps its transaction open meanwhile
    with psycopg.connect(DB) as conn:
        with conn.transaction():
            assert _booker(tenant, line, proposal)(conn) == ["unplanned_payout"]
            held = {table: _nowait(table, ids) for table, ids in theirs.items()}
        assert held == {table: [] for table in theirs}, held
    # the other servicer's ids, refused before any lock (the transaction left open on its error)
    with psycopg.connect(DB) as conn:
        as_user(conn, tenant["staff"], "aal2")
        with pytest.raises(psycopg.Error) as exc:
            conn.execute(
                BOOK,
                (str(uuid.uuid4()), line,
                 Jsonb([{"kind": "unplanned_payout", "transfer_id": str(theirs["bank_transfer"][0]),
                         "amount": "1234"}]), "x", REASON),
            )  # fmt: skip
        assert _outcome(exc.value) == ("23514", "transfer line booking refused: transfer_unknown")
        held = {table: _nowait(table, ids) for table, ids in theirs.items()}
        conn.rollback()
    assert held == {table: [] for table in theirs}, held


# -- cancel_remittance_run and the command on the client's run ----------------------------------


@pytest.mark.parametrize("first", ["command", "cancel"])
def test_cancel_and_the_command_on_the_client_s_run_never_deadlock(first: str) -> None:
    tenant, _other, r1, _r2 = _two_runs()  # Martin's run approved, no file yet
    _sid, line = _client_line(tenant, 1_234)  # S13: locks Martin's live run first
    book = _booker(tenant, line, _proposal(tenant, line, "unplanned_payout"))
    cancel = _as(tenant["admin"], "select public.cancel_remittance_run(%s, %s, %s, %s)",
                 str(uuid.uuid4()), r1, run_row(r1)["version"], "annulé (test)")  # fmt: skip
    out = _hold(book, cancel) if first == "command" else _hold(cancel, book)
    command, other = (out["a"], out["b"]) if first == "command" else (out["b"], out["a"])
    assert out["b_waited"], out
    assert command == ["unplanned_payout"], out
    assert other["status"] == "cancelled", out
    assert run_row(r1)["status"] == "cancelled" and _line_bookings(line) == [
        ("unplanned_payout", 1_234)
    ]
    drain_payments(storage())
    _no_violation(tenant)


# -- two commands naming one transfer on two lines ----------------------------------------------


def test_two_commands_naming_one_transfer_on_two_lines_book_it_once(tmp_path: Path) -> None:
    tenant, other, _r1, r2 = _two_runs()
    f, _data = _downloaded(tenant, tmp_path)
    x2 = _run_transfer(r2)
    _executed_on(str(f["id"]), _day(tenant))
    with psycopg.connect(DB) as conn:
        iban = conn.execute(
            "select payee_iban from public.bank_transfer where id = %s", (x2["id"],)
        ).fetchone()
    assert iban is not None
    rmt = _debit_line(tenant, int(x2["amount_minor"]), e2e=str(x2["end_to_end_id"]))
    bare = _debit_line(tenant, int(x2["amount_minor"]), iban=str(iban[0]))
    assert _options(tenant, bare)["class"] == "N"
    first = _booker(tenant, rmt, _proposal(tenant, rmt, "payout"))
    second = _booker(tenant, bare, _proposal(tenant, bare, "payout"))
    out = _hold(first, second)
    assert out["a"] == ["payout"], out
    assert out["b_waited"] and _refused(out["b"]), out
    assert _line_bookings(rmt) == [("payout", int(x2["amount_minor"]))]
    assert _line_bookings(bare) == []
    assert _transfer(str(x2["end_to_end_id"]))["status"] == "booked"
    assert run_row(r2)["status"] == "booked"
    del other
    drain_payments(storage())
    _no_violation(tenant)


def _debit_line(
    tenant: dict[str, Any], amount: int, *, e2e: str | None = None, iban: str | None = None
) -> str:
    """A debit of `amount` on the tenant's statement (inserted, committed; the job not run): our
    RMT id when `e2e`, else no reference (class N) to `iban`."""
    org, day = str(tenant["servicer"]), _day(tenant)
    with psycopg.connect(DB) as conn:
        st = conn.execute(
            """insert into public.bank_statement (organization_id, bank_account_id, currency,
                 format, file_name, file_sha256, size_bytes, storage_path)
               values (%s, %s, 'EUR', 'camt053', 'd.xml', %s, 1, %s) returning id""",
            (org, tenant["bank"], uuid.uuid4().hex * 2, f"test/{uuid.uuid4()}"),
        ).fetchone()
        assert st is not None
        conn.execute(
            """update public.bank_statement set status = 'uploaded', uploaded_at = now()
               where id = %s""",
            (st[0],),
        )
        line = conn.execute(
            """insert into public.bank_transaction (organization_id, bank_account_id, statement_id,
                 line_no, dedup_key, direction, amount_minor, currency, booking_date, kind,
                 end_to_end_id, counterparty_iban)
               values (%s, %s, %s, 1, %s, 'debit', %s, 'EUR', %s, %s, %s, %s) returning id""",
            (org, tenant["bank"], st[0], f"t:{st[0]}:1", amount, day,
             "transfer_out" if e2e else "other_debit", e2e, iban),
        ).fetchone()  # fmt: skip
        assert line is not None
        conn.execute(
            """update public.bank_statement set status = 'imported', from_date = %s, to_date = %s,
                 opening_booked_minor = 0, closing_booked_minor = 0, counts = '{}',
                 finished_at = now() where id = %s""",
            (day, day, st[0]),
        )
    return str(line[0])


# -- link_debit and the command on one line -----------------------------------------------------


LINK = "select public.link_debit(%s, %s, %s, null, null, null, %s)"


LINK_CASES = [("fee", "link"), ("fee", "command"), ("explained", "link"), ("explained", "command")]


@pytest.mark.parametrize(("kind", "first"), LINK_CASES)
def test_link_debit_and_the_command_on_one_line_never_deadlock(
    tmp_path: Path, kind: str, first: str
) -> None:
    """M2c-6b-2c (plan §4.1): on a reference-less debit a payout of ours in a downloaded file may be
    (rule 3b's candidate, to its payee IBAN), « Lier » refuses a fee and an explanation
    (payout_candidate) before it takes any lock — the screen books that line — so the pair cannot
    meet there. It meets on a reference-less debit to our own account, which the guards leave to
    both: the command books it « Virement au compte propre » (unplanned_sweep), the link books a
    fee or explains it. Each first: no 40P01, the line booked or linked once."""
    tenant, _other, _r1, r2 = _two_runs()
    f, _data = _downloaded(tenant, tmp_path)
    x2 = _run_transfer(r2)
    _executed_on(str(f["id"]), _day(tenant))
    with psycopg.connect(DB) as conn:
        iban = conn.execute(
            "select payee_iban from public.bank_transfer where id = %s", (x2["id"],)
        ).fetchone()
    assert iban is not None
    bare = _debit_line(tenant, int(x2["amount_minor"]), iban=str(iban[0]))
    refused = _as(tenant["staff"], LINK, str(uuid.uuid4()), bare, kind, "classé par ops (test)")
    with _session() as conn:
        with pytest.raises(psycopg.Error) as exc, conn.transaction():
            refused(conn)
        assert exc.value.sqlstate == "23514", exc.value
        assert exc.value.diag.message_primary == "debit link refused: payout_candidate"
    assert _line_bookings(bare) == []
    with psycopg.connect(DB) as conn:  # the servicer's own account (_downloaded's sweep made it)
        own_iban = conn.execute(
            """select iban from public.bank_account where organization_id = %s and purpose = 'own'
                 and status = 'active'""",
            (tenant["servicer"],),
        ).fetchone()
    assert own_iban is not None
    amount = int(x2["amount_minor"]) + 1_234
    line = _debit_line(tenant, amount, iban=str(own_iban[0]))
    book = _booker(tenant, line, _proposal(tenant, line, "unplanned_sweep"))
    link = _as(tenant["staff"], LINK, str(uuid.uuid4()), line, kind, "classé par ops (test)")
    out = _hold(link, book) if first == "link" else _hold(book, link)
    command, other = (out["b"], out["a"]) if first == "link" else (out["a"], out["b"])
    if first == "link":
        assert isinstance(other, dict) and other["kind"] == kind, out
        assert _refused(command, "already_booked" if kind == "fee" else "already_linked"), out
        assert [k for k, _a in _line_bookings(line)] == (["fee"] if kind == "fee" else []), out
    else:
        assert command == ["unplanned_sweep"], out
        assert isinstance(other, tuple) and other[0] in ("23514", "55P03"), out
        assert _line_bookings(line) == [("unplanned_sweep", amount)]
    assert _transfer(str(x2["end_to_end_id"]))["status"] == "in_file"
    drain_payments(storage())
    _no_violation(tenant)


# -- a refund holding the late line's payment FOR UPDATE and the command's payout part ----------


def test_a_refund_holding_the_late_line_s_payment_and_the_command_never_deadlock(
    late_run: dict[str, Any],  # noqa: F811 - the fixture
) -> None:
    """Staged as 6b-1's concurrency-2 with the command in place of the funds pass: a third session
    holds the allocation lock; the command (the late payout's part on its own RMT line, the job's
    message taken off unrun) queues on it holding the late line's payment's key share (step 4,
    before the allocation lock); request_refund then waits for that payment (FOR UPDATE, as the M2b
    pass's post_debit_links takes a payment); the lock is released: the command books, the refund
    follows. A command taking the key share after the allocation lock would wait for the payment
    under it while the refund waits for the allocation lock: 40P01."""
    x = late_run
    assert _lock_timeout_ms(COMMANDS["refund"]) > DEADLOCK_TIMEOUT_MS
    proposal = _proposal(x["tenant"], x["line"], "payout")
    book = _booker(x["tenant"], x["line"], proposal)
    args = _refund_args(x["payment"], 10_000)
    pids: dict[str, int] = {}
    out: dict[str, Any] = {}

    def command() -> None:
        try:
            with psycopg.connect(DB, autocommit=True) as conn:
                conn.execute(f"set deadlock_timeout = '{DEADLOCK_TIMEOUT_MS}ms'")
                pids["command"] = conn.info.backend_pid
                with conn.transaction():
                    conn.execute("set local lock_timeout = '30s'")
                    out["command"] = book(conn)
        except psycopg.Error as exc:
            out["command"] = _outcome(exc)

    def refund() -> None:
        try:
            with _session() as conn:
                pids["refund"] = conn.info.backend_pid

                def run() -> None:
                    with conn.transaction():
                        as_user(conn, x["tenant"]["staff"], "aal2")
                        conn.execute("set local statement_timeout = '60s'")
                        conn.execute(REQUEST_REFUND, args)

                done, _n = _retried(run, None, None)
                out["refund"] = done
        except psycopg.Error as exc:
            out["refund"] = _outcome(exc)

    tc, tr = threading.Thread(target=command), threading.Thread(target=refund)
    with psycopg.connect(DB) as holder, holder.transaction():
        holder.execute("select pg_advisory_xact_lock(hashtext('payments:' || %s))", (x["org"],))
        tc.start()
        _started(pids, "command")
        assert _waits(pids["command"]), "the command never queued on the allocation lock"
        tr.start()
        _started(pids, "refund")
        assert _waits(pids["refund"], None), "the refund never waited"
    tc.join(120)
    tr.join(120)
    assert "40P01" not in json.dumps(out, default=str), out
    assert out == {"command": ["payout"], "refund": "done"}, out
    assert run_row(x["run"])["status"] == "booked"
    with psycopg.connect(DB) as conn:
        breach = conn.execute(
            "select payment_id::text from public.remittance_deadline_breach where run_id = %s",
            (x["run"],),
        ).fetchall()
    assert [r[0] for r in breach] == [x["payment"]]
    _no_violation(x["tenant"])


# -- the prepare job's old token and the command's requeue --------------------------------------


def test_the_prepare_job_of_an_old_token_never_writes_over_the_requeue() -> None:
    """The prepare job reads the draft's facts under its token T1; the command re-prepares the
    draft (T2) and commits; the job's write under T1 is then refused (skipped: the run is no longer
    T1's, or 40001 from record_draft) — never a draft priced on facts the command changed; the T2
    job prepares it."""
    tenant = remittance_tenant()
    _own_account(tenant)
    from allocation_helpers import credit as bank_credit  # noqa: PLC0415
    from allocation_helpers import statement  # noqa: PLC0415
    from remittance_helpers import recent_business_day  # noqa: PLC0415
    from test_transfer_files_integration import _file  # noqa: PLC0415

    f = _file(tenant, 200_000)
    statement(tenant, storage(), [bank_credit(200_000, rf=f.rf)],
              f"T{uuid.uuid4().hex[:6].upper()}", recent_business_day())  # fmt: skip
    draft = request_run(tenant)
    # refresh queues a prepare under a new token T1, its message left on the queue unrun
    staff(tenant, "select public.refresh_remittance_run(%s, %s, %s)", str(uuid.uuid4()), draft,
          run_row(draft)["version"])  # fmt: skip
    t1 = str(run_row(draft)["job_token"])
    _sid, line = _client_line(tenant, 1_234)
    proposal = _proposal(tenant, line, "unplanned_payout")
    with psycopg.connect(DB) as job:
        with job.transaction():
            facts = load_facts(job, draft, t1)
            assert facts is not None
            priced = prepare_run(facts)
            res = api(tenant, BOOK, str(uuid.uuid4()), line, Jsonb(proposal["request"]),
                      proposal["preview"]["expected_text"], REASON)  # fmt: skip
            assert res["drafts_requeued"] == [draft]
            try:
                written: bool | str = write_draft(job, draft, t1, priced)
            except psycopg.errors.SerializationFailure:
                written = "40001"
        assert written in (False, "40001"), written
    t2 = str(run_row(draft)["job_token"])
    assert t2 != t1 and run_row(draft)["job"] == "prepare"
    drain_remittances()
    head = run_row(draft)
    assert head["job"] is None and head["prepared_at"] is not None
    with psycopg.connect(DB) as conn:
        kinds = sorted(
            str(r[0])
            for r in conn.execute(
                "select kind from private.remittance_draft_line where run_id = %s", (draft,)
            ).fetchall()
        )
    assert kinds == ["allocation", "client_advance", "unplanned_payout"], kinds
    drain_payments(storage())
    _no_violation(tenant)


# -- approve_remittance_runs and the command on the client's draft ------------------------------


@pytest.mark.parametrize("first", ["approve", "command"])
def test_an_approval_and_the_command_on_the_client_s_draft(first: str) -> None:
    from allocation_helpers import credit as bank_credit  # noqa: PLC0415
    from allocation_helpers import statement  # noqa: PLC0415
    from remittance_helpers import recent_business_day  # noqa: PLC0415
    from test_transfer_files_integration import _file  # noqa: PLC0415

    tenant = remittance_tenant()
    _own_account(tenant)
    f = _file(tenant, 200_000)
    statement(tenant, storage(), [bank_credit(200_000, rf=f.rf)],
              f"T{uuid.uuid4().hex[:6].upper()}", recent_business_day())  # fmt: skip
    draft = request_run(tenant)
    head = run_row(draft)
    _sid, line = _client_line(tenant, 1_234)
    book = _booker(tenant, line, _proposal(tenant, line, "unplanned_payout"))
    items = json.dumps([{"run_id": draft, "inputs_hash": head["inputs_hash"],
                         "net_text": str(head["net_minor"])}])  # fmt: skip
    approve_cmd = _as(tenant["staff"], "select public.approve_remittance_runs(%s, %s)",
                      str(uuid.uuid4()), Jsonb(json.loads(items)))  # fmt: skip
    out = _hold(approve_cmd, book) if first == "approve" else _hold(book, approve_cmd)
    command, approval = (out["b"], out["a"]) if first == "approve" else (out["a"], out["b"])
    # the command waits on the draft the approval holds; the approval, on the draft the command
    # holds, waits or is answered busy at once (its own lock order)
    busy = isinstance(approval, dict) and [r["reason"] for r in approval["results"]] == ["busy"]
    assert out["b_waited"] or (first == "command" and busy), out
    # approval first: it queued its job under a token; the command found the run still a draft and
    # re-prepared it (a new token): the approval job does nothing. Command first: the approval read
    # a draft in prepare, its request stale: not approved. Either way the draft is prepared again
    assert command == ["unplanned_payout"], out
    del approval
    drain_remittances()
    after = run_row(draft)
    assert after["status"] == "draft" and after["job"] is None and after["prepared_at"] is not None
    with psycopg.connect(DB) as conn:
        kinds = sorted(
            str(r[0])
            for r in conn.execute(
                "select kind from private.remittance_draft_line where run_id = %s", (draft,)
            ).fetchall()
        )
    assert kinds == ["allocation", "client_advance", "unplanned_payout"], kinds
    approve(tenant, draft)
    drain_remittances()
    assert run_row(draft)["status"] == "approved"
    drain_payments(storage())
    _no_violation(tenant)


# -- the payout account and an unplanned return -------------------------------------------------


def _unplanned_return(tmp_path: Path) -> dict[str, Any]:
    """x booked, debited again and booked unplanned by ops (S03), one copy back (the job reviews it
    unplanned_payout_return): its tenant, x, the return line, its proposal, x's run's payout
    account."""
    tenant, _other, r1, _r2 = _two_runs()
    data, _paid = _booked(tenant, tmp_path)
    x = _run_transfer(r1)
    e2e, a = str(x["end_to_end_id"]), int(x["amount_minor"])
    _sid, d2 = _debit_again(tenant, e2e, a)
    _book(tenant, d2, _proposal(tenant, d2, "unplanned_payout"))
    drain_payments(storage())
    sid = _statement(tenant, _return_entries(data, e2e, _day(tenant)))
    (back,) = _lines(sid)
    proposal = _proposal(tenant, back, "returned")
    return {"tenant": tenant, "x": x, "line": back, "proposal": proposal,
            "account": str(run_row(r1)["payout_account_id"]), "run": r1}  # fmt: skip


ACCOUNT_CASES = [
    ("retire", "account"),
    ("retire", "command"),
    ("confirm", "account"),
    ("confirm", "command"),
]


@pytest.mark.parametrize(("other", "first"), ACCOUNT_CASES)
def test_the_payout_account_and_an_unplanned_return_never_deadlock(
    tmp_path: Path, other: str, first: str
) -> None:
    s = _unplanned_return(tmp_path)
    tenant = s["tenant"]
    admin = add_admin(tenant)
    book = _booker(tenant, s["line"], s["proposal"])
    if other == "retire":
        account = _as(admin, "select public.retire_payout_account(%s, %s, %s)",
                      str(uuid.uuid4()), s["account"], "RIB clôturé (test)")  # fmt: skip
    else:
        with psycopg.connect(DB) as conn, conn.transaction():
            proposed = conn.execute(
                """insert into public.client_payout_account (organization_id,
                     client_organization_id, currency, iban, holder_name, evidence_document_id,
                     proposed_by)
                   select organization_id, client_organization_id, currency,
                          'FR7630006000011234567890189', holder_name, evidence_document_id, %s
                   from public.client_payout_account where id = %s returning id""",
                (tenant["staff"], s["account"]),
            ).fetchone()
        assert proposed is not None
        account = _as(admin, "select public.confirm_payout_account(%s, %s, %s)",
                      str(uuid.uuid4()), proposed[0], "FR7630006000011234567890189")  # fmt: skip
    out = _hold(account, book) if first == "account" else _hold(book, account)
    command, acct = (out["b"], out["a"]) if first == "account" else (out["a"], out["b"])
    assert command == ["unplanned_payout_returned"], out
    assert not (isinstance(acct, tuple) and acct[0] == "40P01"), out
    with psycopg.connect(DB) as conn:
        status = conn.execute(
            "select status from public.client_payout_account where id = %s", (s["account"],)
        ).fetchone()
    assert status is not None and status[0] in ("returned", "retired"), (status, out)
    drain_payments(storage())
    _no_violation(tenant)


# -- the funds pass and the command on the same line --------------------------------------------


def test_the_funds_pass_and_the_command_on_one_line_book_it_once(tmp_path: Path) -> None:
    """The command books x's second debit (held open); the debit job's funds pass, reading the
    same reviewed line, waits on it, then finds it booked and leaves it: one booking."""
    tenant, _other, r1, _r2 = _two_runs()
    _booked(tenant, tmp_path)
    x = _run_transfer(r1)
    _sid, line = _debit_again(tenant, str(x["end_to_end_id"]), int(x["amount_minor"]))
    book = _booker(tenant, line, _proposal(tenant, line, "unplanned_payout"))
    from collectoo_worker.jobs.debits import run_process_debits  # noqa: PLC0415

    def funds(conn: psycopg.Connection[Any]) -> Any:
        run_process_debits(conn, {"organization_id": str(tenant["servicer"]), "funds_after": None})
        return "done"

    out = _hold(book, funds)
    assert out["a"] == ["unplanned_payout"], out
    assert out["b"] == "done", out
    assert _line_bookings(line) == [("unplanned_payout", int(x["amount_minor"]))]
    drain_payments(storage())
    _no_violation(tenant)


# -- generate_transfer_file (a sweep) and the command lowering the share ------------------------


@pytest.mark.parametrize("first", ["command", "generate"])
def test_a_sweep_s_generation_and_the_command_lowering_the_share(
    tmp_path: Path, first: str
) -> None:
    tenant, _other, r1, _r2 = _two_runs()
    _booked(tenant, tmp_path)  # the share: the commission settled at the debits
    x = _run_transfer(r1)
    _sid, line = _debit_again(tenant, str(x["end_to_end_id"]), int(x["amount_minor"]))
    book = _booker(tenant, line, _proposal(tenant, line, "unplanned_payout"))  # an advance of A
    # a collection credited after the second debit: the account's balance covers the sweep again
    from allocation_helpers import credit as bank_credit  # noqa: PLC0415
    from test_transfer_files_integration import _file  # noqa: PLC0415

    from collectoo_worker.synth.reconciliation import credit_entries  # noqa: PLC0415

    more = _file(tenant, 500_000)
    _statement(tenant, credit_entries([bank_credit(500_000, rf=more.rf)], start=_day(tenant),
                                      prefix=f"C{uuid.uuid4().hex[:6].upper()}"))  # fmt: skip
    generate = _as(tenant["staff"], "select public.generate_transfer_file(%s, %s, %s)",
                   str(uuid.uuid4()), tenant["bank"], None)  # fmt: skip
    out = _hold(book, generate) if first == "command" else _hold(generate, book)
    command, gen = (out["a"], out["b"]) if first == "command" else (out["b"], out["a"])
    assert command == ["unplanned_payout"], out
    with psycopg.connect(DB) as conn:
        share = conn.execute(
            """select -coalesce(sum(p.amount_minor), 0) from public.ledger_posting p
               join public.ledger_account a on a.id = p.ledger_account_id
               where a.organization_id = %s and a.book = 'due_to_servicer'""",
            (tenant["servicer"],),
        ).fetchone()
        swept = conn.execute(
            """select coalesce(sum(t.amount_minor), 0) from public.bank_transfer t
               where t.organization_id = %s and t.kind = 'sweep'
                 and t.status in ('ordered', 'in_file')""",
            (tenant["servicer"],),
        ).fetchone()
    assert share is not None and swept is not None
    if isinstance(gen, dict) and gen.get("file_id"):
        drain_remittances()
        f = _file_row(gen["file_id"])
        data = _bytes(f["storage_path"], tmp_path)
        try:
            staff(tenant, "select public.transfer_file_download(%s, %s)", f["id"],
                  hashlib.sha256(data).hexdigest())  # fmt: skip
        except psycopg.Error as exc:
            # generated before the advance: its first download re-checks the sweep and refuses
            assert first == "generate", exc
            assert exc.diag.message_primary == "transfer file refused: file_blocked", exc
    # whatever the order, no sweep ordered or handed out exceeds the share
    with psycopg.connect(DB) as conn:
        live = conn.execute(
            """select coalesce(sum(t.amount_minor), 0) from public.bank_transfer t
               join public.transfer_file f on f.id = t.transfer_file_id
               where t.organization_id = %s and t.kind = 'sweep' and t.status = 'in_file'
                 and f.status in ('downloaded', 'sent')""",
            (tenant["servicer"],),
        ).fetchone()
    assert live is not None and int(live[0]) <= max(0, int(share[0])), (live, share, out)
    del swept
    drain_payments(storage())
    _no_violation(tenant)
