"""M2c-6b-1 bookings core through the database, the worker, storage and the real camt.053 parser
(needs `make up`; plan docs/design/m2c-6b-plan.md §2, §6; design m2c-remittances §7, §12, §13).

A file of two payouts is generated, written by the job, downloaded; its bytes are read back
(`pain001.read`) and the bank's statement of its debits is synthesised (`synth camt053
--debits-of`), imported and the payments queue drained: the M2b pass, then the funds pass in its
own message (plan §2.5 [critic]).

* §7.2 E5-E8: each payout booked from its debit (by its RMT id, or one batch line of its PmtInf),
  its run settled (`client_settlement`), transfer and run `booked`; E9: the sweep the next file
  carries, booked from its debit (`servicer_sweep`); I9, I19 and I20 hold;
* a batch line missing a member, a second debit of a payout: never booked, left to ops with why;
* §7.3: a payout returned (charges deducted: the full reversal, the difference a `bank_fee`), the
  payout account `returned`, a `payout_returned` item; a bank fee on its own;
* concurrency: the funds pass and a run's cancellation on two connections never deadlock.
"""

from __future__ import annotations

import hashlib
import threading
import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from debit_helpers import checks, violations
from integration_helpers import DB, storage
from remittance_helpers import drain as drain_remittances
from remittance_helpers import paris_today, run_row, staff
from statement_helpers import drain as drain_payments
from statement_helpers import upload
from test_transfer_files_integration import _bytes, _file_row, _generate, _two_runs

from collectoo_worker.jobs.debits import run_process_debits
from collectoo_worker.remittance import pain001
from collectoo_worker.synth.camt053 import FEE_CODE, debits_of, make_doc, render_camt053

pytestmark = pytest.mark.integration


def _downloaded(tenant: dict[str, Any], tmp_path: Path) -> tuple[dict[str, Any], bytes]:
    """The next file of the account generated, written by the job, downloaded; its bytes."""
    res = _generate(tenant)
    drain_remittances()
    f = _file_row(res["file_id"])
    assert f["status"] == "generated"
    data = _bytes(f["storage_path"], tmp_path)
    staff(
        tenant,
        "select public.transfer_file_download(%s, %s)",
        f["id"],
        hashlib.sha256(data).hexdigest(),
    )
    return f, data


def _last_closing(tenant: dict[str, Any]) -> tuple[int, date]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select closing_booked_minor, to_date from public.bank_statement
               where bank_account_id = %s order by to_date desc, created_at desc limit 1""",
            (tenant["bank"],),
        ).fetchone()
    assert row is not None
    return int(row[0]), row[1]


def _bank(tenant: dict[str, Any], data: bytes, *, only_back: bool = False, **kw: Any) -> str:
    """The statement of the file's debits (and what else `kw` asks), imported; the queue drained.
    `only_back`: the returns and the fee alone (the debits were on an earlier statement)."""
    opening, last = _last_closing(tenant)
    day = max(paris_today(), last)
    kw.setdefault("booking_date", day)
    entries = debits_of(pain001.read(data), ref_prefix=f"D{uuid.uuid4().hex[:6].upper()}", **kw)
    if only_back:
        entries = [e for e in entries if e.credit or e.code == FEE_CODE]
    days = [e.booking_date for e in entries]
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        entries,
        iban=tenant["iban"],
        from_date=min(days),
        to_date=max(days),
        opening_minor=opening,
        stmt_id=stmt,
    )
    target = upload(tenant, storage(), render_camt053(doc, "08"), name=f"{stmt}.xml")
    drain_payments(storage())
    return str(target["statement_id"])


def _bookings(statement_id: str) -> list[tuple[str, str | None, int]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select b.kind, t.end_to_end_id, b.amount_minor
               from public.bank_line_booking b
               join public.bank_transaction l on l.id = b.bank_transaction_id
               left join public.bank_transfer t on t.id = b.transfer_id
               where l.statement_id = %s order by l.line_no, b.seq""",
            (statement_id,),
        ).fetchall()
    return [(r[0], r[1], int(r[2])) for r in rows]


def _reviews(statement_id: str) -> list[str]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select r.reason from public.bank_debit_review r
               join public.bank_transaction l on l.id = r.bank_transaction_id
               where l.statement_id = %s order by l.line_no""",
            (statement_id,),
        ).fetchall()
    return [r[0] for r in rows]


def _transfer(e2e: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute("select * from public.bank_transfer where end_to_end_id = %s", (e2e,))
        row = cur.fetchone()
        assert row is not None and cur.description is not None
        return {d.name: v for d, v in zip(cur.description, row, strict=True)}


def _entries(source_id: str) -> list[tuple[str, int]]:
    """The entries posted for a transfer or a run: type and the 5120 / 4679 movement."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select e.entry_type,
                      coalesce(sum(p.amount_minor) filter (where a.book = 'client_money_cash'), 0)
               from public.ledger_entry e
               join public.ledger_posting p on p.entry_id = e.id
               join public.ledger_account a on a.id = p.ledger_account_id
               where e.source_id = %s group by e.id, e.entry_type order by min(e.posted_at)""",
            (source_id,),
        ).fetchall()
    return [(r[0], int(r[1])) for r in rows]


def _no_violation(tenant: dict[str, Any]) -> None:
    result = checks(tenant)
    bad = violations(str(result["run_id"])) if "run_id" in result else []
    assert [
        v
        for v in bad
        if v[0]
        in ("bank_cash_identity", "transfer_booked_once", "bank_line_booked", "bank_balance_gap")
    ] == []


def _payouts(data: bytes) -> list[tuple[str, int]]:
    f = pain001.read(data)
    return [(t.end_to_end_id, t.amount_minor) for p in f.payment_infos for t in p.transactions]


@pytest.mark.parametrize("mode", ["individual", "batch", "batch-details"])
def test_e5_to_e9_payouts_settlements_and_the_sweep_booked_from_the_bank(
    tmp_path: Path, mode: str
) -> None:
    tenant, _other, r1, r2 = _two_runs()
    f, data = _downloaded(tenant, tmp_path)
    paid = _payouts(data)
    assert len(paid) == 2
    sid = _bank(tenant, data, mode=mode)
    assert sorted(_bookings(sid)) == sorted(("payout", e2e, n) for e2e, n in paid)
    assert _reviews(sid) == []
    for e2e, n in paid:
        t = _transfer(e2e)
        assert t["status"] == "booked"
        assert _entries(str(t["id"])) == [("remittance", -n)]  # E5 / E7: -N on 5120
    for r in (r1, r2):
        run = run_row(r)
        assert run["status"] == "booked" and run["booked_on"] is not None
        assert [k for k, _ in _entries(r)][-1:] == ["client_settlement"]  # E6 / E8
    _no_violation(tenant)
    # E9: the next file carries the sweep of the servicer's share (4679), booked from its debit
    f2, data2 = _downloaded(tenant, tmp_path)
    assert f2["id"] != f["id"]
    swept = _payouts(data2)
    assert len(swept) == 1 and swept[0][0].startswith("SWP")
    commission = sum(
        int(run_row(r)["gross_minor"]) - int(run_row(r)["net_minor"]) for r in (r1, r2)
    )
    assert swept[0][1] == commission
    sid2 = _bank(tenant, data2)
    assert _bookings(sid2) == [("sweep", swept[0][0], commission)]
    s = _transfer(swept[0][0])
    assert s["status"] == "booked" and _entries(str(s["id"])) == [("servicer_sweep", -commission)]
    _no_violation(tenant)


def test_a_partial_batch_and_a_second_debit_are_left_to_ops(tmp_path: Path) -> None:
    tenant, _other, r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    sid = _bank(tenant, data, mode="partial")  # one member missing: not booked, never in part
    assert _bookings(sid) == []
    assert _reviews(sid) != []
    assert run_row(r1)["status"] != "booked"
    tenant2, _o2, _a, _b = _two_runs()
    _f2, data2 = _downloaded(tenant2, tmp_path)
    # each debited again the next day (today: a statement is never dated in the future)
    sid2 = _bank(tenant2, data2, mode="twice", booking_date=paris_today() - timedelta(days=1))
    assert len(_bookings(sid2)) == 2
    assert _reviews(sid2) == ["transfer_debited_twice", "transfer_debited_twice"]


def test_a_payout_returned_less_the_bank_s_charge_and_a_fee(tmp_path: Path) -> None:
    tenant, _other, r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    paid = _payouts(data)
    _bank(tenant, data)
    e2e, _n = paid[0]
    sid = _bank(
        tenant,
        data,
        mode="batch",
        returns=[e2e],
        charges_minor=150,
        fee_minor=1_200,
        return_date=max(paris_today(), _last_closing(tenant)[1]),
        only_back=True,
    )
    kinds = [k for k, _, _ in _bookings(sid)]
    assert "payout_returned" in kinds and kinds.count("fee") == 2  # the charge and the fee
    t = _transfer(e2e)
    assert t["status"] == "returned"
    assert [k for k, _ in _entries(str(t["id"]))] == ["remittance"]
    with psycopg.connect(DB) as conn:  # E5 reversed in full (the charge is the fee)
        rev = conn.execute(
            """select e.entry_type, e.reverses_entry_id = t.entry_id
               from public.bank_line_booking b join public.ledger_entry e on e.id = b.entry_id
               join public.bank_transfer t on t.id = b.transfer_id
               where b.transfer_id = %s and b.kind = 'payout_returned'""",
            (t["id"],),
        ).fetchone()
    assert rev == ("reversal", True)
    with psycopg.connect(DB) as conn:
        acct = conn.execute(
            "select status from public.client_payout_account where id = %s",
            (t["creditor_bank_account_id"] or t.get("payout_account_id"),),
        ).fetchone()
        pending = conn.execute(
            """select count(*) from private.remittance_pending
               where organization_id = %s and kind = 'payout_returned'""",
            (tenant["servicer"],),
        ).fetchone()
    assert acct is None or acct[0] == "returned"
    assert pending is not None and pending[0] >= 1
    assert run_row(r1)["status"] == "booked"  # E6 stays: the compensation took place
    _no_violation(tenant)


def test_the_funds_pass_and_a_cancellation_never_deadlock(tmp_path: Path) -> None:
    tenant, _other, r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    opening, last = _last_closing(tenant)
    day = max(paris_today(), last)
    entries = debits_of(
        pain001.read(data), booking_date=day, ref_prefix=f"C{uuid.uuid4().hex[:6].upper()}"
    )
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        entries,
        iban=tenant["iban"],
        from_date=day,
        to_date=day,
        opening_minor=opening,
        stmt_id=stmt,
    )
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{stmt}.xml")
    # the import and the M2b pass; the funds message is left on the queue and run by hand below
    drain_payments(storage(), allocate=True)
    errors: list[BaseException] = []
    started = threading.Event()

    def funds() -> None:
        try:
            with psycopg.connect(DB) as conn, conn.transaction():
                run_process_debits(
                    conn, {"organization_id": tenant["servicer"], "funds_after": None}
                )
                started.set()
                conn.execute("select pg_sleep(1)")
        except BaseException as exc:
            errors.append(exc)
            started.set()

    def cancel() -> None:
        started.wait(10)
        try:
            staff(
                tenant,
                "select public.cancel_remittance_run(%s, %s, %s)",
                str(uuid.uuid4()),
                r1,
                "test de concurrence",
            )
        except psycopg.errors.DeadlockDetected as exc:
            errors.append(exc)
        except psycopg.Error:
            pass  # refused once the run is booked: what is expected

    a, b = threading.Thread(target=funds), threading.Thread(target=cancel)
    a.start()
    b.start()
    a.join(30)
    b.join(30)
    assert not [e for e in errors if isinstance(e, psycopg.errors.DeadlockDetected)]
    assert run_row(r1)["status"] in ("booked", "cancelled")
