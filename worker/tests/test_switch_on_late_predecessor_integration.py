"""M2c-6b-3b part 1, the late predecessor through the real paths (needs `make up`; plan
docs/design/m2c-6b-3-plan.md §2 E, G, §3.5; ADR-0014 « M2c-6b-3b part 1 »). The switch
(`private.feature_switch` 'downloaded_file_cancellation') is turned on only inside the one
transaction that asks and confirms a downloaded file's cancellation — two people, as 6b-3b will
let them — and turned off again before it commits; each test asserts it is off at its end. Every
other step is the product's own: the camt.053 import and the debit job, « Comptabiliser… » as an
aal2 API session, the remittance jobs:

* the late predecessor (LP): F1 (Martin's x, Lilas' xl) downloaded, cancelled whole on the
  evidence of the statements of its days, x and xl re-issued (y, yl: ordered); x executed late
  under its RMT id — the debit job reviews it `cancelled_transfer_debited` (never automatic),
  « Comptabiliser… » proposes and books it as its run's payout: the run booked, y cancelled, x
  still cancelled with no entry of its own, the nightly checks clean;
* G4: x's return through the import — the job reviews it `return_differs` and books nothing;
  ops book the proposal (« Virement revenu » of x, its payout booking's entry reversed): the run's
  sums owed again;
* `HELD_TO_SQL`'s parity on an LP: the item x's return put back in the queue is held, in the
  worker as in `private.pending_item_deadlines`, to x's run's line (its planned branch reads the
  LP's payout booking: x keeps no entry of its own) — the draft's line says the same;
* two connections, the LP against `generate_transfer_file`: a generation holding the remit lock
  files y and yl into F2 while the LP waits; once it commits, the LP locks every transfer of y's
  new file (a key-share lock on yl, held by a third session, makes it wait: the re-read after
  the remit lock, `transfer_line_locks`) and is refused `split_changed` (its sheet showed y
  ordered); a fresh preview books it, F2 withdrawn;
* two connections, the LP against `transfer_file_download` of y's generated file, each first:
  one wins — the download first, the LP is refused `reissue_in_downloaded_file`; the LP first,
  the download is refused and F2 superseded — never y handed out and cancelled.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import uuid
from dataclasses import replace
from datetime import date
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, as_user, one, storage
from psycopg.types.json import Jsonb
from remittance_helpers import drain as drain_remittances
from remittance_helpers import paris_today, request_run, run_row
from statement_helpers import drain as drain_payments
from statement_helpers import upload
from test_debit_bookings_integration import (
    _deadline_cols,
    _downloaded,
    _last_closing,
    _no_violation,
    _replace_payout_account,
    _reviews,
    _run_transfer,
    _session,
    _transfer,
)
from test_transfer_files_integration import _bytes, _file_row, _generate, _two_runs
from test_transfer_line_foundations_integration import _return_entries, _started, _statement
from test_transfer_line_ops_integration import REASON, _book, _options, _queue
from test_transfer_line_ops_more_integration import _line_bookings, _lines

from collectoo_worker.jobs.remittances import HELD_TO_SQL, _held_to
from collectoo_worker.synth.camt053 import TRANSFER_DEBIT_CODE, Entry, Tx, make_doc, render_camt053

pytestmark = pytest.mark.integration

BOOK = "select public.book_transfer_line(%s, %s, %s, %s, %s)"
SWITCH = "update private.feature_switch set enabled = %s where key = 'downloaded_file_cancellation'"


def _switch_is_off() -> None:
    with psycopg.connect(DB) as conn:
        assert one(conn, "select private.switch_on('downloaded_file_cancellation')") is False


@pytest.fixture(autouse=True)
def _switch_off_after() -> Any:
    """Whatever a test does, the switch is off once it ends (it is only ever turned on inside one
    transaction that turns it off again before committing)."""
    yield
    with psycopg.connect(DB) as conn:
        conn.execute(SWITCH, (False,))
    _switch_is_off()


def _business_days_back(n: int) -> list[date]:
    """The last `n` business days before today, oldest first."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select c.day from public.business_calendar c
               where c.scope = 'FR-conservative' and not c.closed and c.day < private.paris_today()
               order by c.day desc limit %s""",
            (n,),
        ).fetchall()
    return sorted(r[0] for r in rows)


def _file_dated(file_id: str, day: date) -> None:
    """(test only, as pgTAP's backdate) the downloaded file's execution dates set back to `day`:
    « time moved on » — its execution day and the next are over."""
    with psycopg.connect(DB) as conn, conn.transaction():
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


def _evidence(tenant: dict[str, Any], first: date, last: date) -> str:
    """An empty camt.053 of the account covering `first` … `last`, produced by the bank today
    (after those days), imported and run by the jobs: the statements show nothing of the file."""
    opening, _day = _last_closing(tenant)
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        [], iban=tenant["iban"], from_date=first, to_date=last, opening_minor=opening, stmt_id=stmt
    )
    doc = replace(doc, created=f"{paris_today().isoformat()}T00:00:01")
    target = upload(tenant, storage(), render_camt053(doc, "08"), name=f"{stmt}.xml")
    drain_payments(storage())
    return str(target["statement_id"])


def _cancel_whole(tenant: dict[str, Any], file_id: str) -> dict[str, Any]:
    """The downloaded file cancelled whole on the evidence, as two people do it once the switch is
    on (6b-3b): asked by the ops manager, confirmed by an admin — the switch on for this one
    transaction only, off again before it commits. The confirmation's result."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(SWITCH, (True,))
        version = one(conn, "select version from public.transfer_file where id = %s", (file_id,))
        as_user(conn, tenant["staff"], "aal2")
        asked = one(
            conn,
            "select public.request_transfer_file_cancellation(%s, %s, %s, %s, %s)",
            (str(uuid.uuid4()), file_id, version, "Fichier non déposé (test)", "not_uploaded"),
        )
        assert asked["status"] == "requested", asked
        conn.execute("reset role")
        as_user(conn, tenant["admin"], "aal2")
        done = one(
            conn,
            "select public.confirm_transfer_file_cancellation(%s, %s, %s)",
            (str(uuid.uuid4()), file_id, version),
        )
        conn.execute("reset role")
        conn.execute(SWITCH, (False,))
    _switch_is_off()
    return dict(done)


def _lp_state(tmp_path: Path) -> dict[str, Any]:
    """F1 (Martin's x, Lilas' xl) downloaded, dated back two business days, the statements of its
    days showing nothing of it, cancelled whole: x and xl cancelled, re-issued as y and yl
    (ordered). The tenant, the runs, the transfers and F1's bytes."""
    tenant, other, r1, r2 = _two_runs()
    x, xl = _run_transfer(r1), _run_transfer(r2)
    f, data = _downloaded(tenant, tmp_path)
    day, after = _business_days_back(2)
    _file_dated(str(f["id"]), day)
    _evidence(tenant, day, after)
    done = _cancel_whole(tenant, str(f["id"]))
    assert done["status"] == "superseded", done  # cancelled whole, its transfers re-issued
    y, yl = _run_transfer(r1), _run_transfer(r2)
    assert _transfer(str(x["end_to_end_id"]))["status"] == "cancelled"
    assert (y["status"], y["replaces_transfer_id"]) == ("ordered", x["id"])
    assert (yl["status"], yl["replaces_transfer_id"]) == ("ordered", xl["id"])
    return {"tenant": tenant, "other": other, "r1": r1, "r2": r2, "x": x, "xl": xl, "y": y,
            "yl": yl, "f1": f, "data": data}  # fmt: skip


def _late_debit(tenant: dict[str, Any], transfer: dict[str, Any]) -> tuple[str, str]:
    """`transfer` executed late by the bank under its RMT id, today, on a camt.053 imported and
    run by the jobs: (statement, line)."""
    day = max(paris_today(), _last_closing(tenant)[1])
    amount, e2e = int(transfer["amount_minor"]), str(transfer["end_to_end_id"])
    entry = Entry(amount, False, day, day, ref=f"L{uuid.uuid4().hex[:7].upper()}",
                  code=TRANSFER_DEBIT_CODE, txs=(Tx(amount, end_to_end_id=e2e),))  # fmt: skip
    sid = _statement(tenant, [entry])
    (line,) = _lines(sid)
    return sid, line


def _lp_proposal(tenant: dict[str, Any], line: str) -> dict[str, Any]:
    opts = _options(tenant, line)
    assert opts["refusal"] is None, json.dumps(opts, default=str)
    (proposal,) = opts["proposals"]
    assert proposal["action"] == "payout", json.dumps(opts, default=str)
    return dict(proposal)


def _x_of(state: dict[str, Any]) -> dict[str, Any]:
    return _transfer(str(state["x"]["end_to_end_id"]))


# -- the late predecessor through the debit job, G4, HELD_TO_SQL ---------------------------------


def test_a_late_predecessor_through_the_job_then_its_return_and_its_held_item(  # noqa: PLR0915
    tmp_path: Path,
) -> None:
    s = _lp_state(tmp_path)
    tenant, r1, x, y = s["tenant"], s["r1"], s["x"], s["y"]
    client = str(tenant["client"])
    # x executed late under its RMT id: the job reviews it (a cancelled transfer's debit is never
    # booked automatically), the re-issue is held meanwhile
    sid, line = _late_debit(tenant, x)
    assert _reviews(sid) == ["cancelled_transfer_debited"] and _line_bookings(line) == []
    proposal = _lp_proposal(tenant, line)
    (part,) = proposal["preview"]["parts"]
    assert (part["kind"], part["transfer_id"], part["late_predecessor"]) == (
        "payout",
        str(x["id"]),
        True,
    )
    assert part["cancels_transfer_id"] == str(y["id"])
    res = _book(tenant, line, proposal)
    assert [b["kind"] for b in res["bookings"]] == ["payout"]
    assert _line_bookings(line) == [("payout", int(x["amount_minor"]))]
    head = run_row(r1)
    assert head["status"] == "booked" and str(head["transfer_id"]) == str(y["id"])
    xs = _x_of(s)
    assert (xs["status"], xs["entry_id"]) == ("cancelled", None)
    assert _transfer(str(y["end_to_end_id"]))["status"] == "cancelled"
    drain_payments(storage())
    _no_violation(tenant)

    # G4: x's return through the import — reviewed return_differs, never booked by the job
    data = s["data"]
    day = max(paris_today(), _last_closing(tenant)[1])
    sid2 = _statement(tenant, _return_entries(data, str(x["end_to_end_id"]), day))
    (back,) = _lines(sid2)
    assert _reviews(sid2) == ["return_differs"] and _line_bookings(back) == []
    with psycopg.connect(DB) as conn:
        before = _queue(conn, client)
    opts = _options(tenant, back)
    (ret,) = [p for p in opts["proposals"] if p["action"] == "returned"]
    assert [(p["kind"], p["transfer_id"]) for p in ret["request"]] == [
        ("payout_returned", str(x["id"]))
    ]
    _book(tenant, back, ret)
    assert _line_bookings(back) == [("payout_returned", int(x["amount_minor"]))]
    assert _x_of(s)["status"] == "cancelled"
    with psycopg.connect(DB) as conn:
        assert _queue(conn, client) == before + int(x["amount_minor"])  # the run's sums owed again
        owed = one(
            conn,
            """select q.ledger_entry_id::text from private.remittance_pending q
               join public.ledger_entry e on e.id = q.ledger_entry_id
               join public.ledger_entry r on r.id = e.reverses_entry_id
               where q.client_organization_id = %s and q.kind = 'payout_returned'
                 and r.idempotency_key = %s""",
            (client, f"remit:{x['id']}"),
        )
    drain_payments(storage())
    _no_violation(tenant)

    # HELD_TO_SQL on an LP: the item is held to x's run's line, in the worker as in the SQL queue,
    # and the draft's line says the same (its planned branch reads x's payout booking)
    frozen = _deadline_cols(
        "public.remittance_line",
        "run_id = %s and amount_minor > 0 and not released order by latest_execution_date limit 1",
        r1,
    )
    queue = _deadline_cols(
        "private.pending_item_deadlines(%s)", "ledger_entry_id = %s", tenant["servicer"], owed
    )
    assert queue[0] == frozen[0]
    _replace_payout_account(tenant)
    draft = request_run(tenant)
    with psycopg.connect(DB) as conn:
        held = _held_to(conn, draft)
        rows = [str(r[0]) for r in conn.execute(HELD_TO_SQL, (draft, draft)).fetchall()]
    assert owed in held, rows
    assert held[owed][0] == frozen[0]
    assert rows.count(owed) == 1 and len(rows) == len(set(rows)), rows
    drafted = _deadline_cols(
        "private.remittance_draft_line", "run_id = %s and ledger_entry_id = %s", draft, owed
    )
    assert drafted == queue
    _switch_is_off()


# -- two connections: the LP against generate_transfer_file ---------------------------------------


def _late_line_inserted(tenant: dict[str, Any], transfer: dict[str, Any]) -> str:
    """`transfer`'s late debit under its RMT id, inserted on the account's statement of today
    (committed; the debit job not run on it): a line the generation's hold does not see yet."""
    org, day = str(tenant["servicer"]), paris_today()
    with psycopg.connect(DB) as conn, conn.transaction():
        st = one(
            conn,
            """insert into public.bank_statement (organization_id, bank_account_id, currency,
                 format, file_name, file_sha256, size_bytes, storage_path)
               values (%s, %s, 'EUR', 'camt053', 'l.xml', %s, 1, %s) returning id""",
            (org, tenant["bank"], uuid.uuid4().hex * 2, f"test/{uuid.uuid4()}"),
        )
        conn.execute(
            "update public.bank_statement set status = 'uploaded', uploaded_at = now()"
            " where id = %s",
            (st,),
        )
        line = one(
            conn,
            """insert into public.bank_transaction (organization_id, bank_account_id, statement_id,
                 line_no, dedup_key, direction, amount_minor, currency, booking_date, kind,
                 end_to_end_id)
               values (%s, %s, %s, 1, %s, 'debit', %s, 'EUR', %s, 'transfer_out', %s)
               returning id""",
            (
                org,
                tenant["bank"],
                st,
                f"t:{st}:1",
                int(transfer["amount_minor"]),
                day,
                transfer["end_to_end_id"],
            ),
        )
    return str(line)


def _booking_args(line: str, proposal: dict[str, Any]) -> tuple[Any, ...]:
    return (str(uuid.uuid4()), line, Jsonb(proposal["request"]),
            proposal["preview"]["expected_text"], REASON)  # fmt: skip


def _outcome(exc: psycopg.Error) -> tuple[str | None, str | None]:
    return (exc.sqlstate, exc.diag.message_primary)


def _blocked(pid: int) -> bool:
    with psycopg.connect(DB, autocommit=True) as conn:
        row = conn.execute(
            "select wait_event_type from pg_stat_activity where pid = %s", (pid,)
        ).fetchone()
    return row is not None and row[0] == "Lock"


def _blockers(pid: int) -> list[int]:
    """The backends `pid` waits on (pg_blocking_pids): which session holds the lock it waits
    for, not only that it waits."""
    with psycopg.connect(DB, autocommit=True) as conn:
        row = conn.execute("select pg_blocking_pids(%s)", (pid,)).fetchone()
    return sorted(row[0]) if row is not None and row[0] is not None else []


def _until(cond: Any, timeout_s: float = 15.0) -> bool:
    end = time.monotonic() + timeout_s
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


def test_the_late_predecessor_against_a_generation_locks_the_new_file_s_transfers(  # noqa: PLR0915
    tmp_path: Path,
) -> None:
    s = _lp_state(tmp_path)
    tenant, x, y, yl = s["tenant"], s["x"], s["y"], s["yl"]
    out: dict[str, Any] = {}
    pids: dict[str, int] = {}
    gen, line_holder, yl_holder = _session(), _session(), _session()
    t: threading.Thread | None = None
    try:
        # a generation of the account, holding its locks (the allocation and remit locks): it files
        # y and yl into F2 — x's late debit is not on a statement yet, so nothing holds y
        gen.execute("begin")
        as_user(gen, tenant["staff"], "aal2")
        res = one(
            gen,
            "select public.generate_transfer_file(%s, %s, null)",
            (str(uuid.uuid4()), tenant["bank"]),
        )
        f2 = str(res["file_id"])
        # x's late debit lands meanwhile; the sheet is read: y still ordered (the generation has not
        # committed), the late predecessor's text names y ordered
        line = _late_line_inserted(tenant, x)
        proposal = _lp_proposal(tenant, line)
        assert proposal["preview"]["parts"][0]["cancels_transfer_id"] == str(y["id"])
        # a second session holds x's line FOR SHARE (step 6 of the booking's locks waits on it)
        line_holder.execute("begin")
        line_holder.execute(
            "select 1 from public.bank_transaction where id = %s for share", (line,)
        )
        args = _booking_args(line, proposal)

        def run_b() -> None:
            try:
                with _session() as conn, conn.transaction():
                    pids["b"] = conn.info.backend_pid
                    as_user(conn, tenant["staff"], "aal2")
                    out["b"] = one(conn, BOOK, args)
            except psycopg.Error as exc:
                out["b"] = _outcome(exc)

        t = threading.Thread(target=run_b)
        t.start()
        _started(pids, "b")
        assert _until(lambda: _blocked(pids["b"])), "the booking waits on the generation's locks"
        gen.execute("commit")
        assert _transfer(str(y["end_to_end_id"]))["status"] == "in_file"
        assert _transfer(str(yl["end_to_end_id"]))["transfer_file_id"] is not None
        # the generation committed: the booking now waits on x's line; a third session key-share
        # locks yl, filed into F2 (as a booking or a link referencing it does); x's line let go
        assert _until(lambda: _blocked(pids["b"]))
        yl_holder.execute("begin")
        yl_holder.execute(
            "select 1 from public.bank_transfer where id = %s for key share", (yl["id"],)
        )
        line_holder.execute("rollback")
        # past the remit lock the booking re-reads y, finds it in F2 (not downloaded) and locks
        # every transfer of F2 FOR UPDATE: it waits on yl's key-share lock — the yl holder's
        # session itself, not any other lock (review round 1, tests-4)
        time.sleep(1.5)
        out["blockers"] = _blockers(pids["b"])
        out["yl_holder"] = yl_holder.info.backend_pid
        out["waited_on_yl"] = t.is_alive() and out["blockers"] == [out["yl_holder"]]
        yl_holder.execute("rollback")
        t.join(60)
        assert not t.is_alive()
    finally:
        for c in (gen, line_holder, yl_holder):
            if not c.closed:
                c.execute("rollback")
                c.close()
        if t is not None and t.is_alive():
            t.join(60)
    assert out["waited_on_yl"] is True, out
    assert out["b"] == ("23514", "transfer line booking refused: split_changed"), out
    assert _line_bookings(line) == [] and run_row(s["r1"])["status"] == "approved"
    # a fresh sheet names F2: booked, F2 withdrawn (superseded), y cancelled, yl back in the queue
    proposal = _lp_proposal(tenant, line)
    (part,) = proposal["preview"]["parts"]
    assert part["supersedes_file_number"] == _file_row(f2)["number"]
    _book(tenant, line, proposal)
    assert run_row(s["r1"])["status"] == "booked"
    assert _file_row(f2)["status"] == "superseded"
    assert _transfer(str(y["end_to_end_id"]))["status"] == "cancelled"
    assert _transfer(str(yl["end_to_end_id"]))["status"] == "ordered"
    drain_payments(storage())
    drain_remittances()
    _no_violation(tenant)
    _switch_is_off()


# -- two connections: the LP against transfer_file_download of y's generated file ----------------


def _y_filed(s: dict[str, Any], tmp_path: Path) -> tuple[dict[str, Any], bytes]:
    """y and yl filed into F2, written by the job (generated, not downloaded): F2 and its bytes."""
    res = _generate(s["tenant"])
    drain_remittances()
    f2 = _file_row(res["file_id"])
    assert f2["status"] == "generated"
    return f2, _bytes(f2["storage_path"], tmp_path)


def _in_thread(tenant: dict[str, Any], sql: str, args: tuple[Any, ...], out: dict[str, Any],
               pids: dict[str, int]) -> threading.Thread:  # fmt: skip
    """`sql` as the ops manager (aal2) in its own session and transaction, in a thread: its
    value, or its error's SQLSTATE and message, in out["b"]."""

    def run() -> None:
        try:
            with _session() as conn, conn.transaction():
                pids["b"] = conn.info.backend_pid
                as_user(conn, tenant["staff"], "aal2")
                out["b"] = one(conn, sql, args)
        except psycopg.Error as exc:
            out["b"] = _outcome(exc)

    t = threading.Thread(target=run)
    t.start()
    _started(pids, "b")
    return t


def test_the_download_of_the_re_issue_s_file_first_then_the_late_predecessor(
    tmp_path: Path,
) -> None:
    """The download holds its locks (the file's runs, the remit lock, the file) and hands y out —
    its re-check read the statements before x's late debit landed; the late predecessor's sheet,
    read meanwhile, shows y in F2: the booking waits on the download's run lock, then is refused
    reissue_in_downloaded_file, as a fresh sheet says. y stays handed out, never
    cancelled; nothing is booked."""
    s = _lp_state(tmp_path)
    tenant, x, y = s["tenant"], s["x"], s["y"]
    f2, data2 = _y_filed(s, tmp_path)
    out: dict[str, Any] = {}
    pids: dict[str, int] = {}
    t: threading.Thread | None = None
    with _session() as conn, conn.transaction():
        as_user(conn, tenant["staff"], "aal2")
        out["a"] = one(conn, "select public.transfer_file_download(%s, %s)",
                       (f2["id"], hashlib.sha256(data2).hexdigest()))  # fmt: skip
        conn.execute("reset role")
        line = _late_line_inserted(tenant, x)
        proposal = _lp_proposal(tenant, line)
        assert proposal["preview"]["parts"][0]["supersedes_file_number"] == f2["number"]
        t = _in_thread(tenant, BOOK, _booking_args(line, proposal), out, pids)
        out["b_waited"] = _until(lambda: _blocked(pids["b"]))
    t.join(60)
    assert not t.is_alive() and "40P01" not in json.dumps(out, default=str), out
    assert out["a"]["status"] == "downloaded" and out["b_waited"] is True, out
    assert out["b"] == ("23514", "transfer line booking refused: reissue_in_downloaded_file"), out
    opts = _options(tenant, line)
    assert opts["refusal"] == "reissue_in_downloaded_file", json.dumps(opts, default=str)
    assert _file_row(str(f2["id"]))["status"] == "downloaded"
    assert _transfer(str(y["end_to_end_id"]))["status"] == "in_file"
    assert (
        _line_bookings(line) == [] and run_row(s["r1"])["status"] == "sent"
    )  # its file handed out
    _switch_is_off()


def test_the_late_predecessor_first_then_the_download_of_the_re_issue_s_file(
    tmp_path: Path,
) -> None:
    """The late predecessor's booking holds its locks and withdraws F2 (superseded), y cancelled;
    the download waits on its run lock, then is refused: y is never handed out."""
    s = _lp_state(tmp_path)
    tenant, x, y = s["tenant"], s["x"], s["y"]
    f2, data2 = _y_filed(s, tmp_path)
    _sid, line = _late_debit(tenant, x)
    proposal = _lp_proposal(tenant, line)
    assert proposal["preview"]["parts"][0]["supersedes_file_number"] == f2["number"]
    out: dict[str, Any] = {}
    pids: dict[str, int] = {}
    t: threading.Thread | None = None
    with _session() as conn, conn.transaction():
        as_user(conn, tenant["staff"], "aal2")
        out["a"] = one(conn, BOOK, _booking_args(line, proposal))
        t = _in_thread(tenant, "select public.transfer_file_download(%s, %s)",
                       (f2["id"], hashlib.sha256(data2).hexdigest()), out, pids)  # fmt: skip
        out["b_waited"] = _until(lambda: _blocked(pids["b"]))
    t.join(60)
    assert not t.is_alive() and "40P01" not in json.dumps(out, default=str), out
    assert out["b_waited"] is True, out
    assert [b["kind"] for b in out["a"]["bookings"]] == ["payout"], out
    assert isinstance(out["b"], tuple) and out["b"][0] is not None, out
    assert _file_row(str(f2["id"]))["status"] == "superseded"
    assert _transfer(str(y["end_to_end_id"]))["status"] == "cancelled"
    assert _line_bookings(line) == [("payout", int(x["amount_minor"]))]
    assert run_row(s["r1"])["status"] == "booked"
    drain_payments(storage())
    drain_remittances()
    _no_violation(tenant)
    _switch_is_off()
