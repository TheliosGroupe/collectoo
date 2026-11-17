"""M2c-6b-2b, the ops command through the database, the worker, storage and the real parsers (needs
`make up`; plan docs/design/m2c-6b-2-plan.md §3, §8.2 « Integration (6b-2b) » and « Concurrency »):

* a payout booked by the job from the real camt.053, returned (the job books payout_returned),
  then executed again: the job reviews the second debit, ops read the options and book their
  proposal as an aal2 API session — the unplanned payout pays the return item (P = A, the Python
  twin's P), the client's draft is re-prepared by the prepare job and approved by the approval
  job; the second copy comes back: the job reviews unplanned_payout_return, ops book the
  proposal, the re-owed item waits; the next run's prepare job holds it to the frozen return
  item's line (jobs/remittances.py _held_to = private.pending_item_deadlines' third branch,
  critic2 ML-2);
* a second debit of a booked payout: ops book the proposal (P = 0, the advance A, Q8), the funds
  pass queued; the same key twice returns the first result;
* CS-1, the interleaved two-connection order (review M2c-6b-2a CS-1; plan §3.8): the first
  connection holds only the run row the second needs, then calls its own command — the download
  waits on the run row holding nothing and no deadlock occurs (a download taking the allocation
  and remit locks before its runs deadlocks, 40P01: the mutant this test kills), and the same for
  book_transfer_line against refresh_remittance_run on the client's draft;
* the same key submitted twice at once: the second waits on the key lock beyond the 2 s
  lock_timeout and returns the first result (critic2 CSO2-6); a command waiting on the allocation
  lock held by an allocation chunk is refused allocation_busy, not busy;
* review fixes (round 1): the worker's _held_to and the SQL give a returned second debit's item
  (P = 0) no deadline, and _held_to's query one row per item (TESTS-4); the command's P is the
  twin's where the client's queue binds (TESTS-1); the debit job's funds pass on a batch holding a
  sweep's return alone takes the allocation lock before its line, the command's order, so the two
  never deadlock (CSR-1).
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import psycopg
import pytest
from allocation_helpers import credit as bank_credit
from allocation_helpers import statement
from debit_helpers import API_DB, api, return_entry
from integration_helpers import DB, as_user, storage
from psycopg.types.json import Jsonb
from remittance_helpers import (
    approve,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)
from remittance_helpers import drain as drain_remittances
from test_debit_bookings_integration import (
    _bank,
    _bookings,
    _deadline_cols,
    _replace_payout_account,
    _reviews,
    _run_transfer,
    _session,
    _transfer,
    _waits,
)
from test_transfer_files_integration import (
    _bytes,
    _file,
    _file_row,
    _generate,
    _own_account,
    _two_runs,
)
from test_transfer_line_foundations_integration import (
    _booked,
    _day,
    _line_of,
    _return_entries,
    _started,
    _statement,
    _with_sweep,
)

from collectoo_worker.jobs.remittances import HELD_TO_SQL, _held_to
from collectoo_worker.payments.transfer_lines import PoolItem, UnplannedAsk, unplanned_p
from collectoo_worker.synth.camt053 import TRANSFER_DEBIT_CODE, Entry, Tx
from collectoo_worker.synth.reconciliation import credit_entries

pytestmark = pytest.mark.integration

REASON = "Vu au relevé de la banque (test)"


def _options(tenant: dict[str, Any], line: str) -> dict[str, Any]:
    return dict(api(tenant, "select public.transfer_line_options(%s)", line))


def _book(
    tenant: dict[str, Any], line: str, proposal: dict[str, Any], key: str | None = None
) -> dict[str, Any]:
    """The options' proposal booked as the page will: its parts as the preview returned them, its
    expected text and a motif, a fresh key (or `key`)."""
    preview = proposal["preview"]
    assert preview["ok"], preview
    return dict(
        api(
            tenant,
            "select public.book_transfer_line(%s, %s, %s, %s, %s)",
            key or str(uuid.uuid4()),
            line,
            Jsonb(proposal["request"]),
            preview["expected_text"],
            REASON,
        )
    )


def _debit_again(tenant: dict[str, Any], e2e: str, amount: int) -> tuple[str, str]:
    """Our transfer debited again, on a camt.053 imported and run by the job: (statement, line)."""
    day = _day(tenant)
    ref = f"D{uuid.uuid4().hex[:6].upper()}"
    entry = Entry(
        amount,
        False,
        day,
        day,
        ref=f"{ref}1",
        code=TRANSFER_DEBIT_CODE,
        txs=(Tx(amount, end_to_end_id=e2e),),
    )
    sid = _statement(tenant, [entry])
    return sid, _line_of(sid)


def _come_back(tenant: dict[str, Any], data: bytes, e2e: str) -> tuple[str, str]:
    """Our transfer coming back (flagged return), on a camt.053 imported and run by the job."""
    sid = _statement(tenant, _return_entries(data, e2e, _day(tenant)))
    return sid, _line_of(sid)


def _pool_item(conn: psycopg.Connection[Any], entry: str) -> PoolItem:
    """The SQL facts of one pool item, as the Python twin reads them (parity)."""
    row = conn.execute(
        """select e.posted_at, q.amount_minor, e.reverses_entry_id::text,
                  coalesce((select y.amount_minor from private.remittance_pending y
                            join public.ledger_entry z on z.id = y.ledger_entry_id
                            where z.reverses_entry_id = e.id), 0),
                  coalesce((select sum(u.amount_minor) from private.unplanned_paid_item u
                            where u.ledger_entry_id = e.id
                              and not exists (select 1 from public.ledger_entry r
                                              where r.reverses_entry_id = u.booking_entry_id)), 0),
                  private.unplanned_own_item(e.id)
           from public.ledger_entry e
           left join private.remittance_pending q on q.ledger_entry_id = e.id
           where e.id = %s""",
        (entry,),
    ).fetchone()
    assert row is not None
    return PoolItem(entry, row[0], row[1], row[2], int(row[3]), int(row[4]), bool(row[5]))


def _queue(conn: psycopg.Connection[Any], client: str) -> int:
    row = conn.execute(
        """select coalesce(sum(amount_minor), 0) from private.remittance_pending
           where client_organization_id = %s and currency = 'EUR'""",
        (client,),
    ).fetchone()
    return int(row[0]) if row else 0


# -- through the jobs: a return item paid by a late execution, then that execution returned ----


def test_a_payout_returned_then_executed_again_then_returned_again(  # noqa: PLR0915 - one scenario
    tmp_path: Path,
) -> None:
    """S03r (F2), F1 and ML-2 through the real import, jobs and command."""
    tenant, _other, r1, _r2 = _two_runs()
    data, _paid = _booked(tenant, tmp_path)
    x = _run_transfer(r1)
    e2e, a = str(x["end_to_end_id"]), int(x["amount_minor"])
    client = str(tenant["client"])
    # the bank returns it: the job books payout_returned, its item is owed again
    _bank(tenant, data, returns=[e2e], return_date=_day(tenant), only_back=True)
    x = _transfer(e2e)
    assert x["status"] == "returned"
    rho = str(x["return_entry_id"])
    _replace_payout_account(tenant)
    draft = request_run(tenant)  # the client's draft holds the return item (prepared by the job)
    assert run_row(draft)["prepared_at"] is not None
    version = run_row(draft)["version"]

    # the bank executes it again: the job cannot book it (returned), ops book the proposal
    sid, line = _debit_again(tenant, e2e, a)
    assert _bookings(sid) == [] and _reviews(sid) != []
    opts = _options(tenant, line)
    (proposal,) = [p for p in opts["proposals"] if p["action"] == "unplanned_payout"]
    (part,) = proposal["preview"]["parts"]
    with psycopg.connect(DB) as conn:
        twin = unplanned_p(
            [UnplannedAsk(a, client, (rho,))],
            {rho: _pool_item(conn, rho)},
            {client: _queue(conn, client)},
        )
    assert (
        (int(part["paid_minor"]), int(part["advance_minor"]), part["p_bound"])
        == (
            twin[0].p,
            twin[0].advance,
            twin[0].bound,
        )
        == (a, 0, "amount")
    )
    res = _book(tenant, line, proposal)
    assert res["drafts_requeued"] == [draft] and res["funds_pass_queued"] is True
    assert [(b["kind"], int(b["amount_minor"]), int(b["paid_minor"])) for b in res["bookings"]] == [
        ("unplanned_payout", a, a)
    ]
    head = run_row(draft)
    assert (head["job"], head["last_failure"], head["version"] > version) == ("prepare", None, True)
    drain_remittances()  # the prepare job under the new token: the return item and the -A row
    head = run_row(draft)
    assert head["job"] is None and head["prepared_at"] is not None
    assert int(head["gross_minor"]) == 0
    approve(tenant, draft)
    drain_remittances()
    assert run_row(draft)["status"] in ("approved", "booked")

    # the second copy comes back: the job reviews it, ops book the options' proposal
    sid2, back = _come_back(tenant, data, e2e)
    assert _bookings(sid2) == [] and _reviews(sid2) == ["unplanned_payout_return"]
    opts = _options(tenant, back)
    (proposal,) = [p for p in opts["proposals"] if p["action"] == "returned"]
    assert [x["kind"] for x in proposal["parts"]] == ["unplanned_payout_returned"], json.dumps(
        opts, default=str
    )
    res = _book(tenant, back, proposal)
    assert [b["kind"] for b in res["bookings"]] == ["unplanned_payout_returned"]
    with psycopg.connect(DB) as conn:
        owed = conn.execute(
            """select q.ledger_entry_id::text from private.remittance_pending q
               join public.ledger_entry e on e.id = q.ledger_entry_id
               join public.ledger_entry r on r.id = e.reverses_entry_id
               where q.client_organization_id = %s and q.kind = 'payout_returned'
                 and r.entry_type = 'remittance' and r.idempotency_key like 'remit:line:%%'""",
            (client,),
        ).fetchone()
    assert owed is not None
    item = str(owed[0])
    # ML-2: held to the frozen return item's line (its E and delay), in SQL and in the worker
    frozen = _deadline_cols("public.remittance_line", "ledger_entry_id = %s and not released", rho)
    queue = _deadline_cols(
        "private.pending_item_deadlines(%s)", "ledger_entry_id = %s", tenant["servicer"], item
    )
    assert queue[0] == frozen[0]
    rerun = request_run(tenant)
    with psycopg.connect(DB) as conn:
        held = _held_to(conn, rerun)
        rows = [str(r[0]) for r in conn.execute(HELD_TO_SQL, (rerun, rerun)).fetchall()]
    assert held[item][0] == frozen[0]
    # review TESTS-4: one row per item (a planned branch not keyed on the transfer's own remittance
    # would also give the re-owed item x's run's line, which the dict hides)
    assert rows.count(item) == 1 and len(rows) == len(set(rows)), rows
    drafted = _deadline_cols(
        "private.remittance_draft_line", "run_id = %s and ledger_entry_id = %s", rerun, item
    )
    assert drafted == queue


def test_a_second_debit_booked_by_ops_is_the_servicer_s_advance(tmp_path: Path) -> None:
    """Q8, Q4: a payout booked and never returned, debited again — P = 0 (no items), the advance
    A; the funds pass queued; the same key returns the first result and books nothing more."""
    tenant, _other, r1, _r2 = _two_runs()
    _booked(tenant, tmp_path)
    x = _run_transfer(r1)
    e2e, a = str(x["end_to_end_id"]), int(x["amount_minor"])
    sid, line = _debit_again(tenant, e2e, a)
    assert _reviews(sid) == ["transfer_debited_twice"]
    opts = _options(tenant, line)
    assert opts["class"] == "E"
    (proposal,) = [p for p in opts["proposals"] if p["action"] == "unplanned_payout"]
    (part,) = proposal["preview"]["parts"]
    assert (int(part["paid_minor"]), int(part["advance_minor"]), part["p_bound"]) == (0, a, "none")
    key = str(uuid.uuid4())
    res = _book(tenant, line, proposal, key)
    again = _book(tenant, line, proposal, key)
    assert again == res and res["funds_pass_queued"] is True
    assert _bookings(sid) == [("unplanned_payout", e2e, a)]
    with psycopg.connect(DB) as conn:
        adv = conn.execute(
            """select cause, amount_minor from public.client_advance
               where bank_transaction_id = %s""",
            (line,),
        ).fetchall()
        refused = conn.execute(
            "select count(*) from public.bank_debit_review where bank_transaction_id = %s", (line,)
        ).fetchone()
    assert adv == [("double_payout", a)] and refused == (0,)


# -- concurrency (plan §3.8; review M2c-6b-2a CS-1) -------------------------------------------


def _interleaved(
    first_lock: str, args: tuple[Any, ...], second: Any, first_command: Any
) -> dict[str, Any]:
    """CS-1's interleaved order: connection A takes only `first_lock` (a run row FOR UPDATE); B
    starts `second` and waits on that row; A then calls `first_command` and commits. Returns B's
    and A's outcomes (a psycopg error as its SQLSTATE and message)."""
    out: dict[str, Any] = {}
    pids: dict[str, int] = {}

    def run_b() -> None:
        try:
            with _session() as conn, conn.transaction():
                pids["b"] = conn.info.backend_pid
                out["b"] = second(conn)
        except psycopg.Error as exc:
            out["b"] = (exc.sqlstate, exc.diag.message_primary)

    with _session() as conn:
        try:
            with conn.transaction():
                conn.execute(first_lock, args)
                t = threading.Thread(target=run_b)
                t.start()
                _started(pids, "b")
                assert _waits(pids["b"], None)  # on the run row, holding nothing the command needs
                out["a"] = first_command(conn)
        except psycopg.Error as exc:
            out["a"] = (exc.sqlstate, exc.diag.message_primary)
        t.join(30)
    return out


def test_cs1_the_download_waits_on_its_run_holding_nothing(tmp_path: Path) -> None:
    """CS-1: A holds only the run row of a generated file; B's first download waits on it; A then
    cancels the run (its own allocation and remit locks). No deadlock: the cancellation commits,
    the download finds its file superseded. (A download taking the allocation and remit locks
    before its runs holds them while it waits: A's cancellation waits on B, 40P01 — killed.)"""
    tenant, _client, r1, _r2 = _two_runs()
    res = _generate(tenant)
    drain_remittances()
    f = _file_row(res["file_id"])
    sha = hashlib.sha256(_bytes(f["storage_path"], tmp_path)).hexdigest()
    version = run_row(r1)["version"]

    def download(conn: psycopg.Connection[Any]) -> Any:
        as_user(conn, tenant["admin"], "aal2")
        row = conn.execute(
            "select public.transfer_file_download(%s, %s)", (f["id"], sha)
        ).fetchone()
        return row[0] if row else None

    def cancel(conn: psycopg.Connection[Any]) -> Any:
        as_user(conn, tenant["admin"], "aal2")
        row = conn.execute(
            "select public.cancel_remittance_run(%s, %s, %s, %s)",
            (str(uuid.uuid4()), r1, version, "test"),
        ).fetchone()
        return row[0] if row else None

    out = _interleaved(
        "select 1 from public.remittance_run where id = %s for update", (r1,), download, cancel
    )
    assert not (isinstance(out["a"], tuple) and out["a"][0] == "40P01"), out
    assert not (isinstance(out["b"], tuple) and out["b"][0] == "40P01"), out
    assert out["a"]["status"] == "cancelled", out
    assert out["b"] == ("23514", "transfer file refused: not_downloadable"), out
    assert run_row(r1)["status"] == "cancelled"


def _drafted() -> tuple[dict[str, Any], str]:
    """Martin 2 000,00 € paid; his run requested and prepared by the job (a draft): its tenant, the
    run."""
    tenant = remittance_tenant()
    _own_account(tenant)
    f = _file(tenant, 200_000)
    statement(
        tenant,
        storage(),
        [bank_credit(200_000, rf=f.rf)],
        f"T{uuid.uuid4().hex[:6].upper()}",
        recent_business_day(),
    )
    draft = request_run(tenant)
    assert run_row(draft)["status"] == "draft" and run_row(draft)["prepared_at"] is not None
    return tenant, draft


def _client_line(tenant: dict[str, Any], amount: int) -> tuple[str, str]:
    """A debit to the client's registered payout IBAN that names nothing of ours (S13, class N),
    imported and run by the job: (statement, line)."""
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select iban from public.client_payout_account
               where client_organization_id = %s and status = 'active'""",
            (tenant["client"],),
        ).fetchone()
    assert row is not None
    day = _day(tenant)
    entry = Entry(
        amount,
        False,
        day,
        day,
        ref=f"N{uuid.uuid4().hex[:7].upper()}",
        code=TRANSFER_DEBIT_CODE,
        txs=(Tx(amount, iban=row[0], name="MARTIN SAS"),),
    )
    sid = _statement(tenant, [entry])
    return sid, _line_of(sid)


def test_cs1_the_command_waits_on_the_client_s_draft_holding_nothing() -> None:
    """CS-1 for book_transfer_line: A holds only the client's draft row; B's command (a client part
    of an unplanned payout: it locks that draft first) waits on it; A then refreshes the draft (its
    allocation lock). No deadlock: the refresh commits, then B books and re-prepares the draft. (A
    command taking the allocation lock before the runs deadlocks, 40P01 — killed.)"""
    tenant, draft = _drafted()
    _sid, line = _client_line(tenant, 1_234)
    opts = _options(tenant, line)
    (proposal,) = [p for p in opts["proposals"] if p["action"] == "unplanned_payout"]
    preview = proposal["preview"]
    version = run_row(draft)["version"]

    def book(conn: psycopg.Connection[Any]) -> Any:
        as_user(conn, tenant["staff"], "aal2")
        row = conn.execute(
            "select public.book_transfer_line(%s, %s, %s, %s, %s)",
            (str(uuid.uuid4()), line, Jsonb(proposal["request"]), preview["expected_text"], REASON),
        ).fetchone()
        return row[0] if row else None

    def refresh(conn: psycopg.Connection[Any]) -> Any:
        as_user(conn, tenant["staff"], "aal2")
        row = conn.execute(
            "select public.refresh_remittance_run(%s, %s, %s)", (str(uuid.uuid4()), draft, version)
        ).fetchone()
        return row[0] if row else None

    out = _interleaved(
        "select 1 from public.remittance_run where id = %s for update", (draft,), book, refresh
    )
    assert not (isinstance(out["b"], tuple) and out["b"][0] == "40P01"), out
    assert not (isinstance(out["a"], tuple) and out["a"][0] == "40P01"), out
    assert out["a"]["status"] == "draft", out
    assert [b["kind"] for b in out["b"]["bookings"]] == ["unplanned_payout"], out
    assert out["b"]["drafts_requeued"] == [draft], out


def test_the_same_key_twice_at_once_returns_the_first_result() -> None:
    """CSO2-6: the second call waits on the key lock beyond the command's 2 s lock_timeout (the key
    lock is taken under 7 s) and returns the first call's result, never busy."""
    tenant, _other, _r1, _r2 = _two_runs()
    _sid, line = _client_line(tenant, 2_345)
    (proposal,) = [
        p for p in _options(tenant, line)["proposals"] if p["action"] == "unplanned_payout"
    ]
    preview = proposal["preview"]
    key = str(uuid.uuid4())
    args = (key, line, Jsonb(proposal["request"]), preview["expected_text"], REASON)
    sql = "select public.book_transfer_line(%s, %s, %s, %s, %s)"
    out: dict[str, Any] = {}
    pids: dict[str, int] = {}

    def second() -> None:
        try:
            with _session() as conn, conn.transaction():
                pids["b"] = conn.info.backend_pid
                as_user(conn, tenant["staff"], "aal2")
                row = conn.execute(sql, args).fetchone()
                out["b"] = row[0] if row else None
        except psycopg.Error as exc:
            out["b"] = (exc.sqlstate, exc.diag.message_primary)

    with _session() as conn, conn.transaction():
        as_user(conn, tenant["staff"], "aal2")
        row = conn.execute(sql, args).fetchone()
        out["a"] = row[0] if row else None
        t = threading.Thread(target=second)
        t.start()
        _started(pids, "b")
        assert _waits(pids["b"])  # the key lock (advisory)
        time.sleep(2.5)  # past the command's lock_timeout of 2 s
    t.join(30)
    assert out["b"] == out["a"], out
    assert len(_bookings(_sid)) == 1


def test_a_command_waiting_on_the_allocation_lock_is_allocation_busy() -> None:
    """CSO2-6: an allocation chunk holds the servicer's `payments:` lock; the command waits its 2 s
    and is refused allocation_busy (55P03), not busy; nothing is booked."""
    tenant, _draft = _drafted()
    sid, line = _client_line(tenant, 3_456)
    (proposal,) = [
        p for p in _options(tenant, line)["proposals"] if p["action"] == "unplanned_payout"
    ]
    with psycopg.connect(DB) as holder, holder.transaction():
        holder.execute(
            "select pg_advisory_xact_lock(hashtext('payments:' || %s))", (tenant["servicer"],)
        )
        started = datetime.now(UTC)
        with pytest.raises(psycopg.Error) as exc:
            _book(tenant, line, proposal)
        waited = (datetime.now(UTC) - started).total_seconds()
    assert exc.value.sqlstate == "55P03"
    assert exc.value.diag.message_primary == "transfer line booking refused: allocation_busy"
    assert 1.5 < waited < 7
    assert _bookings(sid) == []


# -- review fixes (round 1) ---------------------------------------------------------------------


def test_a_returned_second_debit_s_item_has_no_deadline_in_the_worker_nor_the_sql(
    tmp_path: Path,
) -> None:
    """Review TESTS-4 (critic F11, L4): x booked by the job, debited again (S03: ops book it, P = 0,
    the advance A), that copy back (the job reviews unplanned_payout_return, ops book its return):
    the item it re-owes is in the client's next draft with no deadline — absent from the worker's
    _held_to and from private.pending_item_deadlines, as for every payout_returned item of the
    draft the two agree; _held_to's query gives one row per item."""
    tenant, _other, r1, _r2 = _two_runs()
    data, _paid = _booked(tenant, tmp_path)
    x = _run_transfer(r1)
    e2e, a = str(x["end_to_end_id"]), int(x["amount_minor"])
    sid, line = _debit_again(tenant, e2e, a)
    assert _reviews(sid) == ["transfer_debited_twice"]
    (proposal,) = [
        p for p in _options(tenant, line)["proposals"] if p["action"] == "unplanned_payout"
    ]
    res = _book(tenant, line, proposal)
    assert [(int(b["paid_minor"]), b["p_bound"]) for b in res["bookings"]] == [(0, "none")]
    sid2, back = _come_back(tenant, data, e2e)
    assert _reviews(sid2) == ["unplanned_payout_return"]
    (proposal,) = [p for p in _options(tenant, back)["proposals"] if p["action"] == "returned"]
    _book(tenant, back, proposal)
    draft = request_run(tenant)
    with psycopg.connect(DB) as conn:
        item = conn.execute(
            """select q.ledger_entry_id::text from private.remittance_pending q
               join public.ledger_entry e on e.id = q.ledger_entry_id
               join public.ledger_entry r on r.id = e.reverses_entry_id
               where q.draft_run_id = %s and q.kind = 'payout_returned'
                 and r.idempotency_key like 'remit:line:%%'""",
            (draft,),
        ).fetchone()
        assert item is not None
        returned = [
            str(r[0])
            for r in conn.execute(
                """select ledger_entry_id from private.remittance_pending
                   where draft_run_id = %s and kind = 'payout_returned' and amount_minor > 0""",
                (draft,),
            ).fetchall()
        ]
        held = _held_to(conn, draft)
        rows = [str(r[0]) for r in conn.execute(HELD_TO_SQL, (draft, draft)).fetchall()]
        sql = {
            str(r[0]): r[1]
            for r in conn.execute(
                """select ledger_entry_id, encaissement_date from private.pending_item_deadlines(%s)
                   where encaissement_date is not null""",
                (tenant["servicer"],),
            ).fetchall()
        }
    assert item[0] not in held and item[0] not in sql
    assert len(rows) == len(set(rows)), rows
    for entry in returned:
        assert (held[entry][0] if entry in held else None) == sql.get(entry), entry


def test_p_is_the_twin_s_when_the_client_s_queue_binds(tmp_path: Path) -> None:
    """Review TESTS-1 (critic F5), the parity point where the queue binds (P < A): Martin's payout x
    booked and returned (its item owed again, A), a new collection of Martin's (500,00 €)
    allocated, then the collection that x's run remitted comes back unpaid (its allocation
    reversed: -2 000,00 € queued, the client money now covering it); x executed again — the queue
    nets less than A: P is the queue's, the rest an advance, p_bound queue, as the twin gives it
    on the SQL facts."""
    tenant, _other, r1, _r2 = _two_runs()
    data, _paid = _booked(tenant, tmp_path)
    x = _run_transfer(r1)
    e2e, a = str(x["end_to_end_id"]), int(x["amount_minor"])
    client = str(tenant["client"])
    _bank(tenant, data, returns=[e2e], return_date=_day(tenant), only_back=True)
    rho = str(_transfer(e2e)["return_entry_id"])
    with psycopg.connect(DB) as conn:
        paid = conn.execute(
            """select p.end_to_end_id from public.payment p
               join public.account c on c.id = p.account_id
               where c.client_organization_id = %s and p.amount_minor = 200000""",
            (client,),
        ).fetchone()
    assert paid is not None and paid[0]
    more = _file(tenant, 50_000)
    _statement(
        tenant,
        credit_entries(
            [bank_credit(50_000, rf=more.rf)],
            start=_day(tenant),
            prefix=f"Q{uuid.uuid4().hex[:6].upper()}",
        ),
    )
    _statement(
        tenant,
        [return_entry(200_000, str(paid[0]), f"R{uuid.uuid4().hex[:8].upper()}", _day(tenant))],
    )
    with psycopg.connect(DB) as conn:
        assert 0 < _queue(conn, client) < a
    _sid, line = _debit_again(tenant, e2e, a)
    (proposal,) = [
        p for p in _options(tenant, line)["proposals"] if p["action"] == "unplanned_payout"
    ]
    (part,) = proposal["preview"]["parts"]
    with psycopg.connect(DB) as conn:
        twin = unplanned_p(
            [UnplannedAsk(a, client, (rho,))],
            {rho: _pool_item(conn, rho)},
            {client: _queue(conn, client)},
        )
    got = (int(part["paid_minor"]), int(part["advance_minor"]), part["p_bound"])
    assert got == (twin[0].p, twin[0].advance, twin[0].bound)
    assert twin[0].bound == "queue" and 0 < twin[0].p < a and twin[0].p + twin[0].advance == a
    res = _book(tenant, line, proposal)
    assert [
        (int(b["paid_minor"]), int(b["advance_minor"]), b["p_bound"]) for b in res["bookings"]
    ] == [got]


def _sweep_return_line(tenant: dict[str, Any], sweep: dict[str, Any]) -> str:
    """The sweep's bank-flagged return on a statement of the dedicated account, inserted (committed)
    without the debit job running on it: the test runs the funds pass itself."""
    org, day = str(tenant["servicer"]), _day(tenant)
    with psycopg.connect(DB) as conn:
        st = conn.execute(
            """insert into public.bank_statement (organization_id, bank_account_id, currency,
                 format, file_name, file_sha256, size_bytes, storage_path)
               values (%s, %s, 'EUR', 'camt053', 'r.xml', %s, 1, %s) returning id""",
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
                 original_end_to_end_id)
               values (%s, %s, %s, 1, %s, 'credit', %s, 'EUR', %s, 'return', %s) returning id""",
            (org, tenant["bank"], st[0], f"t:{st[0]}:1", sweep["amount_minor"], day,
             sweep["end_to_end_id"]),
        ).fetchone()  # fmt: skip
        assert line is not None
        conn.execute(
            """update public.bank_statement set status = 'imported', from_date = %s, to_date = %s,
                 opening_booked_minor = 0, closing_booked_minor = 0, counts = '{}',
                 finished_at = now()
               where id = %s""",
            (day, day, st[0]),
        )
    return str(line[0])


def test_cs1_the_job_s_sweep_return_and_the_command_never_deadlock(  # noqa: PLR0915 - one race
    tmp_path: Path,
) -> None:
    """Review CSR-1: H holds only the command's line; C (book_transfer_line, a client part, as an
    aal2 API session) takes `payments:` and waits on that line; J (the funds pass's SQL with the
    job's row: a sweep's flagged return, alone in its batch) takes `payments:` first — the command's
    order — and waits on C; H commits: C books, then J books the return. (The funds pass taking its
    line and `remit:` first, and `payments:` only inside the reversal, deadlocks C or J, 40P01: the
    mutant this test kills.)"""
    tenant, f, data = _with_sweep(tmp_path)
    staff(
        tenant,
        "select public.transfer_file_download(%s, %s)",
        f["id"],
        hashlib.sha256(data).hexdigest(),
    )
    _bank(tenant, data)  # the sweep's debit, booked by the job
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select id::text, end_to_end_id, amount_minor from public.bank_transfer
               where transfer_file_id = %s and kind = 'sweep' and status = 'booked'""",
            (f["id"],),
        ).fetchone()
    assert row is not None
    sweep = {"id": row[0], "end_to_end_id": row[1], "amount_minor": row[2]}
    _csid, line = _client_line(tenant, 1_234)  # S13: the command's line
    (proposal,) = [
        p for p in _options(tenant, line)["proposals"] if p["action"] == "unplanned_payout"
    ]
    ret = _sweep_return_line(tenant, sweep)
    out: dict[str, Any] = {}
    pids: dict[str, int] = {}

    def command() -> None:
        try:
            with psycopg.connect(API_DB) as conn, conn.transaction():
                pids["c"] = conn.info.backend_pid
                claims = json.dumps(
                    {"sub": tenant["staff"], "role": "authenticated", "aal": "aal2"}
                )
                conn.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
                conn.execute("set local role authenticated")
                conn.execute("set local statement_timeout = '8s'")
                got = conn.execute(
                    "select public.book_transfer_line(%s, %s, %s, %s, %s)",
                    (str(uuid.uuid4()), line, Jsonb(proposal["request"]),
                     proposal["preview"]["expected_text"], REASON),
                ).fetchone()  # fmt: skip
                out["c"] = [b["kind"] for b in got[0]["bookings"]] if got else None
        except psycopg.Error as exc:
            out["c"] = (exc.sqlstate, exc.diag.message_primary)

    def job() -> None:
        try:
            with _session() as conn, conn.transaction():
                pids["j"] = conn.info.backend_pid
                conn.execute("select private.bank_booking_begin()")
                conn.execute(
                    """insert into pg_temp._bank_booking (ord, bank_transaction_id, kind,
                                                       transfer_id, method)
                       values (1, %s, 'sweep_returned', %s, 'auto')""",
                    (ret, sweep["id"]),
                )
                got = conn.execute(
                    "select private.apply_bank_bookings(%s)", (tenant["servicer"],)
                ).fetchone()
                out["j"] = got[0] if got else None
        except psycopg.Error as exc:
            out["j"] = (exc.sqlstate, exc.diag.message_primary)

    with _session() as holder:
        with holder.transaction():
            holder.execute(
                "select 1 from public.bank_transaction where id = %s for no key update", (line,)
            )
            tc = threading.Thread(target=command)
            tc.start()
            _started(pids, "c")
            assert _waits(pids["c"], None)  # past the key lock and `payments:`, on the line
            tj = threading.Thread(target=job)
            tj.start()
            _started(pids, "j")
            assert _waits(pids["j"], None)
        tc.join(30)
        tj.join(30)
    assert "40P01" not in json.dumps(out, default=str), out
    assert out["c"] == ["unplanned_payout"], out
    assert [b[0] for b in _bookings_of(ret)] == ["sweep_returned"], out
    assert _transfer(str(sweep["end_to_end_id"]))["status"] == "returned"


def _bookings_of(line: str) -> list[tuple[str, int]]:
    with psycopg.connect(DB) as conn:
        return [
            (str(r[0]), int(r[1]))
            for r in conn.execute(
                """select kind, amount_minor from public.bank_line_booking
                   where bank_transaction_id = %s order by seq""",
                (line,),
            ).fetchall()
        ]
