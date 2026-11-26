# ruff: noqa: E501 - SQL fixtures read better unwrapped
"""M2c-7e-1 (needs `make up`; plan docs/design/m2c-7-plan.md §7.1, §7.2, §7.5; ADR-0014
« M2c-7e-1 »): top-ups through the real jobs.

- The hourly `top_ups` job (one servicer per message, in its own transaction) orders what the
  servicer owes its dedicated account after a bank charge booked by the debit job; the own
  account's file is generated, written by the `transfer_file` job (its bytes those the writer gives
  for the frozen body: byte-stable; the debtor the own account; checked as every file), downloaded;
  the bank's credit carrying the TOP id is booked by the debit job's funds pass (the filed top-up
  booked from in_file: [critic] M7-MONEY-4); the next hour closes the shortfall period; the file is
  then refused file_executed.
- A downloaded own-account file cancelled (« Annuler le fichier », the switch off), then its
  top-up's late credit: the job itself writes the review `top_up_cancelled_credit`; ops book it
  with no transfer.
- decide_line (the worker's twin) and the SQL re-check agree on every top-up state a credit can
  name (ordered, in_file of an own-account file, cancelled, booked; its amount).
- [critic] F8, two sessions: another session holds servicer B's remit lock; the job orders A's
  top-up and, while B's message still waits, A's « Désimputer » completes at once (review round 1:
  A's locks were never held to the end of B's wait); B is skipped after its 2 s (a miss recorded),
  then ordered at the next run once the lock is free."""

from __future__ import annotations

import hashlib
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, one, storage
from psycopg.types.json import Jsonb
from remittance_helpers import (
    drain,
    drain_payments_queue,
    own_account,
    paid_file,
    recent_business_day,
    remittance_tenant,
    staff,
)
from statement_helpers import upload

from collectoo_worker.jobs.debits import filed_top_ups, funds_lines
from collectoo_worker.jobs.payments import make_handler, record_dead_job
from collectoo_worker.jobs.transfer_files import write_file
from collectoo_worker.payments.debits import TOP_UP_CANCELLED_CREDIT, decide_line
from collectoo_worker.remittance import pain001
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.synth.camt053 import Entry, Tx, make_doc, render_camt053

pytestmark = pytest.mark.integration


def _last_statement(tenant: dict[str, Any]) -> tuple[int, Any]:
    """The account's last closing balance and day (none yet: 0, the last business day)."""
    with psycopg.connect(DB) as conn:
        last = conn.execute(
            """select closing_booked_minor, to_date from public.bank_statement
               where bank_account_id = %s order by to_date desc, created_at desc limit 1""",
            (tenant["bank"],),
        ).fetchone()
    return (int(last[0]), last[1]) if last else (0, recent_business_day(1))


def _statement(tenant: dict[str, Any], entries: list[Entry]) -> None:
    """A one-day camt.053 of the dedicated account chained to its last closing balance, imported
    and the payments queue drained (the debit job and its funds pass)."""
    opening, day = _last_statement(tenant)
    ref = f"S{uuid.uuid4().hex[:10].upper()}"
    doc = make_doc(
        entries, iban=tenant["iban"], from_date=day, to_date=day, opening_minor=opening, stmt_id=ref
    )
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{ref}.xml")
    drain_payments_queue()


def _fee(tenant: dict[str, Any], amount: int) -> None:
    """A bank charge on the dedicated account (CHRG): booked by the debit job (+4679)."""
    _, day = _last_statement(tenant)
    _statement(tenant, [Entry(amount, False, day, day, ref=f"F{uuid.uuid4().hex[:8]}",
                              code="ACMT/MDOP/CHRG")])  # fmt: skip


def _credit(tenant: dict[str, Any], amount: int, e2e: str | None, iban: str) -> str:
    """A credit on the dedicated account from `iban`, carrying `e2e`: its line."""
    _, day = _last_statement(tenant)
    ref = f"C{uuid.uuid4().hex[:10].upper()}"
    tx = Tx(amount, ref=f"L{ref}", end_to_end_id=e2e, iban=iban, name="COLLECTOO")
    _statement(tenant, [Entry(amount, True, day, day, ref=ref, txs=(tx,))])
    with psycopg.connect(DB) as conn:
        return str(one(conn, """select id from public.bank_transaction where bank_account_id = %s
                                 and entry_ref = %s""", (tenant["bank"], ref)))  # fmt: skip


def _hourly(tenant: dict[str, Any]) -> None:
    """The servicer's `top_ups` message (as private.queue_top_ups sends it), run by the worker."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select pgmq.send('remittances', %s)",
            (Jsonb({"type": "top_ups", "organization_id": str(tenant["servicer"])}),),
        )
    drain()


def _tops(tenant: dict[str, Any]) -> list[tuple[str, str, int, str | None]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select id::text, status, amount_minor, end_to_end_id from public.bank_transfer
               where organization_id = %s and kind = 'top_up' order by created_at, id""",
            (tenant["servicer"],),
        ).fetchall()
    return [(str(r[0]), str(r[1]), int(r[2]), r[3]) for r in rows]


def _owed(tenant: dict[str, Any]) -> int:
    with psycopg.connect(DB) as conn:
        return int(
            one(conn, "select private.servicer_owed_minor(%s, 'EUR')", (tenant["servicer"],))
        )


def _periods(tenant: dict[str, Any]) -> list[tuple[bool, int]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select closed_at is null, peak_minor from private.servicer_shortfall_period
               where organization_id = %s order by opened_at""",
            (tenant["servicer"],),
        ).fetchall()
    return [(bool(r[0]), int(r[1])) for r in rows]


def _file_out(tenant: dict[str, Any], own: str) -> tuple[str, bytes, bytes]:
    """« Générer le fichier (compte propre) », the job writes it, « Télécharger »: the file, the
    bytes the writer gives for the body frozen at generation, the bytes the job stored."""
    result = staff(tenant, "select public.generate_top_up_file(%s, %s)", str(uuid.uuid4()), own)
    file_id = str(result["file_id"])
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        token = one(conn, "select job_token from public.transfer_file where id = %s", (file_id,))
        body = one(conn, "select private.transfer_file_begin(%s, %s)", (file_id, token))
    expected, _facts, _validated = write_file(dict(body))
    drain()
    with psycopg.connect(DB) as conn:
        path = one(conn, "select storage_path from public.transfer_file where id = %s", (file_id,))
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "f.xml"
        storage().download("transfer-files", path, dest)
        stored = dest.read_bytes()
    staff(tenant, "select public.transfer_file_download(%s, %s)", file_id,
          hashlib.sha256(stored).hexdigest())  # fmt: skip
    return file_id, expected, stored


def test_the_hourly_order_the_own_account_file_and_its_credit_booked() -> None:
    tenant = remittance_tenant()
    own, own_iban = own_account(tenant)
    _fee(tenant, 1_234)
    assert _owed(tenant) == 1_234
    _hourly(tenant)
    tops = _tops(tenant)
    assert [(t[1], t[2]) for t in tops] == [("ordered", 1_234)]
    assert _periods(tenant) == [(True, 1_234)]
    _hourly(tenant)  # the next hour: nothing more (an ordered top-up lowers what is needed)
    assert len(_tops(tenant)) == 1
    with psycopg.connect(DB) as conn:
        state = conn.execute(
            """select last_outcome, consecutive_misses, last_ordered from private.top_up_order_state
               where organization_id = %s""",
            (tenant["servicer"],),
        ).fetchone()
    assert state == ("done", 0, 0)

    file_id, expected, stored = _file_out(tenant, own)
    assert stored == expected  # byte-stable: the writer's bytes for the frozen body
    facts = pain001.check(stored, pain001.DEFAULT_VERSION)
    assert (facts["nb_of_txs"], facts["ctrl_sum_minor"]) == (1, 1_234)
    text = stored.decode()
    assert f"<IBAN>{own_iban}</IBAN>" in text.split("<CdtTrfTxInf>")[0]  # the debtor: own account
    assert f"<EndToEndId>{tops[0][3]}</EndToEndId>" in text
    assert f"<IBAN>{tenant['iban']}</IBAN>" in text.split("<CdtTrfTxInf>")[1]
    assert "<BtchBookg>false</BtchBookg>" in text
    assert _tops(tenant)[0][1] == "in_file"

    # the bank executes it: the credit carrying the TOP id, from the own account, booked by the job
    line = _credit(tenant, 1_234, tops[0][3], own_iban)
    assert _tops(tenant)[0][1] == "booked"
    with psycopg.connect(DB) as conn:
        booked = conn.execute(
            """select b.kind, b.transfer_id::text, e.entry_type from public.bank_line_booking b
               join public.ledger_entry e on e.id = b.entry_id where b.bank_transaction_id = %s""",
            (line,),
        ).fetchall()
        review = conn.execute(
            "select reason from public.bank_debit_review where bank_transaction_id = %s", (line,)
        ).fetchone()
    assert booked == [("top_up", tops[0][0], "servicer_top_up")]
    assert review is None
    assert _owed(tenant) == 0
    _hourly(tenant)
    assert _periods(tenant) == [(False, 1_234)]
    assert len(_tops(tenant)) == 1
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("select set_config('request.jwt.claims', %s, true)",
                     (f'{{"sub": "{tenant["staff"]}", "role": "authenticated", "aal": "aal2"}}',))  # fmt: skip
        conn.execute("set local role authenticated")
        with pytest.raises(psycopg.errors.CheckViolation, match="file_executed"):
            conn.execute("select public.transfer_file_download(%s, %s, true)",
                         (file_id, hashlib.sha256(stored).hexdigest()))  # fmt: skip


def test_a_cancelled_top_up_s_late_credit_waits_for_ops() -> None:
    tenant = remittance_tenant()
    own, own_iban = own_account(tenant)
    _fee(tenant, 2_000)
    _hourly(tenant)
    file_id, _expected, _stored = _file_out(tenant, own)
    top = _tops(tenant)[0]
    out = staff(tenant, "select public.cancel_top_up_file(%s, %s, %s)", str(uuid.uuid4()), file_id,
                "Fichier non déposé (test)")  # fmt: skip
    assert (out["status"], out["cancelled"]) == ("superseded", 1)
    assert _tops(tenant)[0][1] == "cancelled"
    line = _credit(tenant, 2_000, top[3], own_iban)
    with psycopg.connect(DB) as conn:
        review = one(conn, "select reason from public.bank_debit_review where bank_transaction_id = %s",
                     (line,))  # fmt: skip
        booked = one(conn, "select count(*) from public.bank_line_booking where bank_transaction_id = %s",
                     (line,))  # fmt: skip
    assert (review, booked) == (TOP_UP_CANCELLED_CREDIT, 0)
    staff(tenant, "select public.link_debit(%s, %s, 'own_credit', null, null, null, %s)",
          str(uuid.uuid4()), line, "Approvisionnement annulé puis exécuté par la banque")  # fmt: skip
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select b.kind, b.transfer_id from public.bank_line_booking b
               where b.bank_transaction_id = %s""",
            (line,),
        ).fetchone()
    assert row == ("top_up", None)
    assert _tops(tenant)[0][1] == "cancelled"
    assert _owed(tenant) == 0


def _import_only() -> None:
    """The payments queue drained but for the debit job (its funds pass would book the lines)."""
    handle = make_handler(storage())

    def handler(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        if payload.get("type") not in ("process_debits", "allocate", "receipts"):
            handle(payload, conn)

    consumer = QueueConsumer(DB, "payments", handler, on_dead=record_dead_job)
    while consumer.poll_once():
        pass


def _python(conn: psycopg.Connection[Any], org: str, line: str) -> str:
    """decide_line's verdict on the line, from the job's own reads (candidates, the loader)."""
    with conn.cursor(row_factory=psycopg.rows.dict_row) as cur:
        rows = cur.execute(
            "select * from private.bank_booking_candidates(%s, null, null, 2000)", (org,)
        ).fetchall()
    rows = [r for r in rows if str(r["line_id"]) == line]
    filed_top_ups(conn, rows)
    (fl,) = funds_lines(rows)
    out = decide_line(fl)
    return "booked" if out[0].booked else str(out[0].review_reason)


def _sql(conn: psycopg.Connection[Any], org: str, line: str, transfer: str) -> str:
    """The SQL re-check's verdict on the job's top-up row for (line, transfer), rolled back."""
    with conn.transaction(force_rollback=True):
        conn.execute("select private.bank_booking_begin()")
        conn.execute(
            """insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method)
               values (1, %s, 'top_up', %s, 'auto')""",
            (line, transfer),
        )
        conn.execute("select private.post_bank_bookings(%s, false)", (org,))
        why = conn.execute(
            "select why from pg_temp._booking_skipped where bank_transaction_id = %s", (line,)
        ).fetchone()
    return "booked" if why is None else str(why[0])


def test_decide_line_and_the_sql_re_check_agree_on_top_up_credits() -> None:
    """[critic] the twins' parity over the states a TOP credit can name: the same booking, and the
    same review where the SQL's refusal is the line's own state (top_up_cancelled_credit); any other
    refusal is the worker's top_up_differs."""
    tenant = remittance_tenant()
    own, own_iban = own_account(tenant)
    org = str(tenant["servicer"])
    ordered = staff(tenant, "select public.request_top_up(%s, %s, %s, '700', 'test')",
                    str(uuid.uuid4()), own, tenant["bank"])  # fmt: skip
    filed = staff(tenant, "select public.request_top_up(%s, %s, %s, '800', 'test')",
                  str(uuid.uuid4()), own, tenant["bank"])  # fmt: skip
    staff(tenant, "select public.generate_top_up_file(%s, %s)", str(uuid.uuid4()), own)
    drain()  # (both ordered top-ups in the file: the 700 one ordered again below)
    cancelled = staff(tenant, "select public.request_top_up(%s, %s, %s, '900', 'test')",
                      str(uuid.uuid4()), own, tenant["bank"])  # fmt: skip
    staff(tenant, "select public.cancel_top_up(%s, %s, 'test')", str(uuid.uuid4()),
          cancelled["transfer_id"])  # fmt: skip
    again = staff(tenant, "select public.request_top_up(%s, %s, %s, '600', 'test')",
                  str(uuid.uuid4()), own, tenant["bank"])  # fmt: skip
    cases = [
        (ordered, 700, "booked"),  # in_file of the own-account file
        (filed, 800, "booked"),
        (filed, 801, "top_up_differs"),
        (cancelled, 900, TOP_UP_CANCELLED_CREDIT),
        (again, 600, "booked"),  # ordered
    ]
    with psycopg.connect(DB) as conn:
        _, day = _last_statement(tenant)
    lines = []
    for top, amount, _want in cases:
        ref = f"P{uuid.uuid4().hex[:10].upper()}"
        tx = Tx(amount, ref=f"L{ref}", end_to_end_id=top["end_to_end_id"], iban=own_iban)
        lines.append(Entry(amount, True, day, day, ref=ref, txs=(tx,)))
    # imported without the payments queue: the job's verdicts are compared before any booking
    opening, _ = _last_statement(tenant)
    ref = f"S{uuid.uuid4().hex[:10].upper()}"
    doc = make_doc(lines, iban=tenant["iban"], from_date=day, to_date=day, opening_minor=opening,
                   stmt_id=ref)  # fmt: skip
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{ref}.xml")
    _import_only()
    with psycopg.connect(DB) as conn:
        ids = {
            str(r[1]): str(r[0])
            for r in conn.execute(
                "select id, entry_ref from public.bank_transaction where statement_id = (select id "
                "from public.bank_statement where bank_account_id = %s order by created_at desc "
                "limit 1)",
                (tenant["bank"],),
            ).fetchall()
        }
        for (top, _amount, want), entry in zip(cases, lines, strict=True):
            line = ids[str(entry.ref)]
            py, sql = _python(conn, org, line), _sql(conn, org, line, str(top["transfer_id"]))
            assert py == want, (top, py, sql)
            assert sql == py or (
                py == "top_up_differs" and sql not in ("booked", TOP_UP_CANCELLED_CREDIT)
            )


def _lock_waiter(timeout: float) -> bool:
    """Whether a session waits for an advisory lock (B's message for B's remit lock), polled up to
    `timeout` seconds (once when 0)."""
    deadline = time.monotonic() + timeout
    with psycopg.connect(DB, autocommit=True) as conn:
        while True:
            waiting = conn.execute(
                "select count(*) from pg_locks where locktype = 'advisory' and not granted"
            ).fetchone()
            if waiting and int(waiting[0]) > 0:
                return True
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.05)


def test_the_job_skips_a_servicer_whose_lock_is_held() -> None:  # noqa: PLR0915
    """[critic] F8: one servicer per transaction — B's remit lock held by another session. A's
    message (sent first) orders A's top-up; while B's message still waits for B's lock, A's own
    « Désimputer » (public.reverse_allocation, its 2 s lock timeout) completes at once: A's
    allocation and remit locks went with A's own transaction, never held until B's wait ends (review
    round 1, TUI-5: one transaction for every servicer, each in a savepoint, would hold them). B's
    message waits its 2 s, is skipped (a miss recorded), then B is ordered by the next run once the
    lock is free."""
    a, b = remittance_tenant(), remittance_tenant()
    own_a, _ = own_account(a)
    own_account(b)
    _fee(a, 500)
    _fee(b, 700)
    _, payment = paid_file(a, 40_000)
    with psycopg.connect(DB) as conn:
        entry = str(one(conn, """select id from public.ledger_entry where payment_id = %s
                                  and entry_type = 'allocation'""", (payment,)))  # fmt: skip
        account = str(
            one(conn, "select account_id from public.ledger_entry where id = %s", (entry,))
        )
    held = threading.Event()
    release = threading.Event()

    def hold() -> None:
        with psycopg.connect(DB) as conn, conn.transaction():
            conn.execute(
                "select pg_advisory_xact_lock(hashtext('remit:' || %s))", (str(b["servicer"]),)
            )
            held.set()
            release.wait(30)

    t = threading.Thread(target=hold)
    t.start()
    try:
        assert held.wait(10)
        with psycopg.connect(DB) as conn, conn.transaction():
            for tenant in (a, b):
                conn.execute(
                    "select pgmq.send('remittances', %s)",
                    (Jsonb({"type": "top_ups", "organization_id": str(tenant["servicer"])}),),
                )
        drainer = threading.Thread(target=drain)
        started = time.monotonic()
        drainer.start()
        # B's message waits for B's remit lock (A's was handled first): A's command now
        assert _lock_waiter(10)
        a_started = time.monotonic()
        staff(a, "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)", str(uuid.uuid4()),
              payment, account, [entry], "erreur d'imputation")  # fmt: skip
        a_elapsed = time.monotonic() - a_started
        during = _lock_waiter(0)  # B still waiting: A's command ran inside B's wait
        drainer.join(30)
        elapsed = time.monotonic() - started
        assert during
        assert a_elapsed < 1.5, a_elapsed
        assert [(x[1], x[2]) for x in _tops(a)] == [("ordered", 500)]
        assert _tops(b) == []
        assert elapsed < 8, elapsed  # B waited its 2 s, no more
        # A's file too (it takes A's remit lock)
        started = time.monotonic()
        staff(a, "select public.generate_top_up_file(%s, %s)", str(uuid.uuid4()), own_a)
        assert time.monotonic() - started < 2
        with psycopg.connect(DB) as conn:
            state = conn.execute(
                """select last_outcome, consecutive_misses from private.top_up_order_state
                   where organization_id = %s""",
                (b["servicer"],),
            ).fetchone()
        assert state == ("missed", 1)
    finally:
        release.set()
        t.join()
    _hourly(b)
    assert [(x[1], x[2]) for x in _tops(b)] == [("ordered", 700)]
    with psycopg.connect(DB) as conn:
        assert conn.execute(
            "select last_outcome, consecutive_misses from private.top_up_order_state "
            "where organization_id = %s",
            (b["servicer"],),
        ).fetchone() == ("done", 0)
