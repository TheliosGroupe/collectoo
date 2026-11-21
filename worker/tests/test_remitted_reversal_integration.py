"""M2c-7a: remitted reversals covered by an advance of the servicer (needs `make up`; plan
docs/design/m2c-7-plan.md §2.1, §3.3, §3.9 « Worker »; design §7.2; ADR-0014 « M2c-7a »).

* §7.2 from 12/11 through the real debit job: P1's return line (its end-to-end id, a camt.053 of
  the day) reverses E2 — remitted in RV-1, whose payout was debited — and posts A1 in the same
  transaction (adv:<R>, the file's mandate); 4670 Martin -300 000 (P6 owed in full), 4679 up
  by 200 000, 5120 = the bank; RV-3 prepared before the claw-back (7b): gross 300 000, refund
  36 000, N 282 000, D 18 000 (design §7.3's first variant);
* two connections, no deadlock and exactly one cover (`adv:<R>` or `adv:<R>:<run>`), never LG009:
  « Désimputer » of a remitted allocation against generate_transfer_file (which holds the remit
  lock) and against the client's approval job, each first; « Désimputer » and the funds pass
  booking the run's payout, each first (critic F14); « Couvrir » and the at-booking cover of the
  same reversal.
"""

from __future__ import annotations

import json
import uuid
from typing import Any

import psycopg
import pytest
from debit_helpers import import_entries, line_id, link_of, return_entry
from integration_helpers import DB, as_user, one, storage
from remittance_helpers import (
    add_client,
    approve,
    book_payout,
    drain,
    paid_file,
    paris_today,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)
from test_transfer_line_concurrency_integration import _hold

from collectoo_worker.jobs.payments import make_handler, record_dead_job
from collectoo_worker.runtime.queue import QueueConsumer

pytestmark = pytest.mark.integration


def _value(sql: str, *params: Any) -> Any:
    with psycopg.connect(DB) as conn:
        return one(conn, sql, params)


def _allocation(payment: str) -> str:
    return str(
        _value(
            """select id from public.ledger_entry
               where payment_id = %s and entry_type = 'allocation' order by posted_at limit 1""",
            payment,
        )
    )


def _covers(client: str) -> list[tuple[str, int, str]]:
    """(cause, amount, key) of the client's advances."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select a.cause, a.amount_minor, e.idempotency_key from public.client_advance a
               join public.ledger_entry e on e.id = a.entry_id
               where a.client_organization_id = %s order by a.created_at""",
            (client,),
        ).fetchall()
    return [(r[0], int(r[1]), str(r[2])) for r in rows]


def _book(tenant: dict[str, Any], account: str, client: str | None = None) -> int:
    """A book of the servicer (a client's when given)."""
    return int(
        _value(
            """select coalesce(sum(p.amount_minor), 0) from public.ledger_account la
               join public.ledger_posting p on p.ledger_account_id = la.id
               where la.organization_id = %s and la.book = %s
                 and (%s::uuid is null or la.client_organization_id = %s::uuid)""",
            tenant["servicer"],
            account,
            client,
            client,
        )
    )


def _cash(tenant: dict[str, Any]) -> int:
    return int(
        _value(
            """select coalesce(sum(p.amount_minor), 0) from public.ledger_account la
               join public.ledger_posting p on p.ledger_account_id = la.id
               where la.book = 'client_money_cash' and la.bank_account_id = %s""",
            tenant["bank"],
        )
    )


def _unalloc(tenant: dict[str, Any], payment: str, account: str) -> Any:
    entry = _allocation(payment)
    return staff(
        tenant,
        "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        str(uuid.uuid4()),
        payment,
        account,
        [entry],
        "paiement repris (test)",
    )


def test_the_worked_example_s_return_of_12_11_is_covered_in_its_transaction() -> None:
    """§7.2 from 12/11: RV-1 (E2 200 000) debited; P6 300 000 allocated since; P1 taken back by the
    bank (a camt.053 return naming its end-to-end id), the debit job links it: R(E2), the cash_out
    and A1 in one transaction; P6 owed in full; RV-3 prepared before 7b: N 282 000, D 18 000."""
    tenant = remittance_tenant()
    _f42, p1 = paid_file(tenant, 200_000)
    rv1 = request_run(tenant)
    approve(tenant, rv1)
    drain()
    book_payout(rv1)
    assert run_row(rv1)["status"] == "booked"
    paid_file(tenant, 300_000)
    share_before = _book(tenant, "due_to_servicer")
    e2 = _allocation(p1)
    e2e = str(_value("select end_to_end_id from public.payment where id = %s", p1))
    ref = f"RT{uuid.uuid4().hex[:8].upper()}"
    statement = import_entries(
        tenant,
        storage(),
        [return_entry(200_000, e2e, ref, paris_today())],
        day=paris_today(),
        opening=_cash(tenant),
    )
    line = line_id(tenant, ref)
    assert link_of(line) is not None and link_of(line)[0] == "return"  # type: ignore[index]
    with psycopg.connect(DB) as conn:
        rev = conn.execute(
            """select id, effective_date from public.ledger_entry
               where reverses_entry_id = %s""",
            (e2,),
        ).fetchone()
        assert rev is not None
        adv = conn.execute(
            """select a.amount_minor, a.cause, e.idempotency_key, e.effective_date,
                      a.mandate_id = %s
               from public.client_advance a join public.ledger_entry e on e.id = a.entry_id
               where a.cause_entry_id = %s""",
            (tenant["mandate"], rev[0]),
        ).fetchone()
        closing = conn.execute(
            "select closing_booked_minor from public.bank_statement where id = %s", (statement,)
        ).fetchone()
    assert adv is not None and closing is not None
    assert adv[:3] == (200_000, "remitted_reversal", f"adv:{rev[0]}")
    # A1 commits with the return or not at all: the deferred LG009 check (I23) refuses a commit
    # that leaves the reversal of a remitted entry uncovered (pgTAP 043 #18); its gap is 0 once
    # committed. (The entries' xmin differ: the job posts each link in a savepoint, the cover
    # after it.)
    assert _value("select private.remitted_cover_gap(%s)", rev[0]) == 0
    assert adv[3] == rev[1] == paris_today() and adv[4] is True
    assert _book(tenant, "client_payable", tenant["client"]) == -300_000
    assert _book(tenant, "due_to_servicer") - share_before == 200_000
    assert _cash(tenant) == int(closing[0])
    rv3 = request_run(tenant)
    draft = run_row(rv3)
    assert (
        draft["gross_minor"],
        draft["refund_minor"],
        draft["net_minor"],
        draft["settlement_minor"],
    ) == (300_000, 36_000, 282_000, 18_000), draft["last_failure"]


# -- two connections ----------------------------------------------------------------------------


def _as(user: str, sql: str, *params: Any) -> Any:
    def call(conn: psycopg.Connection[Any]) -> Any:
        as_user(conn, user, "aal2")
        row = conn.execute(sql, params).fetchone()
        conn.execute("reset role")
        return row[0] if row else None

    return call


def _reverse_call(tenant: dict[str, Any], payment: str, account: str) -> Any:
    entry = _allocation(payment)
    return _as(
        tenant["staff"],
        "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        str(uuid.uuid4()),
        payment,
        account,
        [entry],
        "paiement repris (test)",
    )


def _one_cover(client: str, reversal_of: str) -> list[str]:
    """The keys of the covers of the reversal of `reversal_of` (exactly one expected)."""
    rev = _value("select id from public.ledger_entry where reverses_entry_id = %s", reversal_of)
    assert rev is not None
    return [k for cause, _a, k in _covers(client) if cause == "remitted_reversal" and str(rev) in k]


@pytest.mark.parametrize("first", ["generate", "reverse"])
def test_unalloc_and_a_file_generation_never_deadlock(first: str) -> None:
    """generate_transfer_file holds the remit lock while it files; « Désimputer » of a remitted
    allocation posts its cover under that lock: one waits, no deadlock, one cover."""
    tenant = remittance_tenant()
    f, p = paid_file(tenant, 100_000)
    rv1 = request_run(tenant)
    approve(tenant, rv1)
    drain()
    book_payout(rv1)
    other = add_client(tenant)
    paid_file(other, 40_000)
    rv2 = request_run(other)
    approve(other, rv2)
    drain()
    e = _allocation(p)
    generate = _as(
        tenant["staff"],
        "select public.generate_transfer_file(%s, %s, null)",
        str(uuid.uuid4()),
        tenant["bank"],
    )
    reverse = _reverse_call(tenant, p, f.id)
    out = _hold(generate, reverse) if first == "generate" else _hold(reverse, generate)
    assert "40P01" not in json.dumps(out, default=str), out
    assert len(_one_cover(tenant["client"], e)) == 1, out


@pytest.mark.parametrize("first", ["approval", "reverse"])
def test_unalloc_and_the_client_s_approval_job_never_deadlock(first: str) -> None:
    """The approval job holds the run's row, then the allocation and remit locks; « Désimputer »
    holds the payment's row, then the same locks in the same order: one waits, one cover."""
    tenant = remittance_tenant()
    f, p = paid_file(tenant, 100_000)
    rv1 = request_run(tenant)
    approve(tenant, rv1)
    drain()
    book_payout(rv1)
    paid_file(tenant, 50_000)
    rv2 = request_run(tenant)
    approve(tenant, rv2)  # queued, not run
    token = run_row(rv2)["job_token"]
    e = _allocation(p)
    job = _job("select private.approve_remittance_run(%s, %s)", rv2, token)
    reverse = _reverse_call(tenant, p, f.id)
    out = _hold(job, reverse) if first == "approval" else _hold(reverse, job)
    assert "40P01" not in json.dumps(out, default=str), out
    assert len(_one_cover(tenant["client"], e)) == 1, out


def _job(sql: str, *params: Any) -> Any:
    def call(conn: psycopg.Connection[Any]) -> Any:
        row = conn.execute(sql, params).fetchone()
        return row[0] if row else None

    return call


def _in_flight_run(tenant: dict[str, Any]) -> tuple[Any, str, str, str]:
    """The client's run with one collection, approved and handed out (sent), and its payout's debit
    on a statement imported without the debit job; (file, payment, run, debit line)."""
    from remittance_helpers import _bank_catch_up  # noqa: PLC0415

    from collectoo_worker.synth.camt053 import Entry, Tx  # noqa: PLC0415

    f, p = paid_file(tenant, 100_000)
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    _bank_catch_up(tenant)
    file_id = staff(
        tenant,
        "select public.generate_transfer_file(%s, %s, null)",
        str(uuid.uuid4()),
        tenant["bank"],
    )["file_id"]
    drain()
    _download(tenant, str(file_id))
    with psycopg.connect(DB) as conn:
        t = conn.execute(
            """select id, end_to_end_id, amount_minor from public.bank_transfer
               where run_id = %s and kind = 'payout'""",
            (run,),
        ).fetchone()
        assert t is not None
        conn.execute("alter table public.bank_transfer disable trigger bank_transfer_guard")
        conn.execute(
            "update public.bank_transfer set requested_execution_date = %s where id = %s",
            (paris_today(), t[0]),
        )
        conn.execute("alter table public.bank_transfer enable always trigger bank_transfer_guard")
    ref = f"PO{uuid.uuid4().hex[:8].upper()}"
    tx = Tx(int(t[2]), ref=ref, end_to_end_id=str(t[1]), name="CLIENT", ustrd=("REVERSEMENT",))
    entry = Entry(int(t[2]), False, paris_today(), paris_today(), ref=f"N{ref}",
                  code="PMNT/ICDT/ESCT", txs=(tx,))  # fmt: skip
    _import_quiet(tenant, [entry])
    return f, p, run, line_id(tenant, ref)


def _download(tenant: dict[str, Any], file_id: str) -> None:
    sha = _value("select file_sha256 from public.transfer_file where id = %s", file_id)
    staff(tenant, "select public.transfer_file_download(%s, %s, false)", file_id, sha)


def _import_quiet(tenant: dict[str, Any], entries: list[Any]) -> None:
    """A statement of `entries` uploaded and imported, the debit job not run on it (its messages
    purged after the import)."""
    from statement_helpers import upload  # noqa: PLC0415

    from collectoo_worker.synth.camt053 import make_doc, render_camt053  # noqa: PLC0415

    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(entries, iban=tenant["iban"], from_date=paris_today(), to_date=paris_today(),
                   opening_minor=_cash(tenant), stmt_id=stmt)  # fmt: skip
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{stmt}.xml")
    handle = make_handler(storage())

    def handler(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        if payload.get("type") not in ("process_debits", "allocate", "receipts"):
            handle(payload, conn)

    consumer = QueueConsumer(DB, "payments", handler, on_dead=record_dead_job)
    while consumer.poll_once():
        pass


def _funds_pass(tenant: dict[str, Any], line: str, transfer: str) -> Any:
    def call(conn: psycopg.Connection[Any]) -> Any:
        conn.execute("select private.bank_booking_begin()")
        conn.execute(
            """insert into pg_temp._bank_booking
                 (ord, bank_transaction_id, kind, transfer_id, method)
               values (1, %s, 'payout', %s, 'auto')""",
            (line, transfer),
        )
        row = conn.execute(
            "select private.apply_bank_bookings(%s)", (tenant["servicer"],)
        ).fetchone()
        return row[0] if row else None

    return call


@pytest.mark.parametrize("first", ["booking", "reverse"])
def test_unalloc_and_the_payout_s_booking_cover_the_reversal_once(first: str) -> None:
    """(critic F14) « Désimputer » of a line of run X and the funds pass booking X's payout, each
    first: reversed before the booking, the booking covers it (adv:<R>:<X>); booked first, the
    reversal covers it (adv:<R>); exactly one advance, never LG009."""
    tenant = remittance_tenant()
    f, p, run, line = _in_flight_run(tenant)
    transfer = str(_value("select transfer_id from public.remittance_run where id = %s", run))
    e = _allocation(p)
    booking = _funds_pass(tenant, line, transfer)
    reverse = _reverse_call(tenant, p, f.id)
    out = _hold(booking, reverse) if first == "booking" else _hold(reverse, booking)
    assert "40P01" not in json.dumps(out, default=str) and "LG009" not in json.dumps(
        out, default=str
    ), out
    assert run_row(run)["status"] == "booked", out
    keys = _one_cover(tenant["client"], e)
    assert len(keys) == 1, out
    assert keys[0].endswith(f":{run}") == (first == "reverse"), keys


def test_couvrir_and_the_at_booking_cover_of_one_reversal_post_one_advance() -> None:
    """A line of run X reversed in flight (raw: no cover is due yet), then X's payout booked by the
    funds pass while « Couvrir » is asked for the gap the booking makes: one waits on the other's
    locks; one advance (the booking's), « Couvrir » refused nothing_to_cover or gap_changed."""
    tenant = remittance_tenant()
    _f, p, run, line = _in_flight_run(tenant)
    transfer = str(_value("select transfer_id from public.remittance_run where id = %s", run))
    e = _allocation(p)
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select private.ledger_reverse(%s, %s, 'Retour (test)', private.paris_today())",
            (e, f"raw-{uuid.uuid4().hex[:12]}"),
        )
    rev = str(_value("select id from public.ledger_entry where reverses_entry_id = %s", e))
    booking = _funds_pass(tenant, line, transfer)
    cover = _as(
        tenant["admin"],
        "select public.cover_remitted_reversal(%s, %s, %s)",
        str(uuid.uuid4()),
        rev,
        "100000",
    )
    out = _hold(booking, cover)
    assert "40P01" not in json.dumps(out, default=str), out
    assert isinstance(out["b"], tuple) and out["b"][1] in (
        "remitted cover refused: nothing_to_cover",
        "remitted cover refused: gap_changed",
    ), out
    assert len(_one_cover(tenant["client"], e)) == 1, out
    assert int(_value("select private.remitted_cover_gap(%s)", rev)) == 0
