"""M2c-7a: remitted reversals covered by an advance of the servicer (needs `make up`; plan
docs/design/m2c-7-plan.md §2.1, §3.3, §3.9 « Worker »; design §7.2; ADR-0014 « M2c-7a »).

* §7.2 from 12/11 through the real debit job: P1's return line (its end-to-end id, a camt.053 of
  the day) reverses E2 — remitted in RV-1, whose payout was debited — and posts A1 in the same
  transaction (adv:<R>, the file's mandate); 4670 Martin -300 000 (P6 owed in full), 4679 up
  by 200 000, 5120 = the bank; (M2c-7b) the top-up, RV-3 through the real prepare with the
  claw-back clause (N 82 000, D 218 000), its debit, the sweep, the positions and the servicer
  fund to the end, Martin's 246 000;
* two connections, no deadlock and exactly one cover (`adv:<R>` or `adv:<R>:<run>`), never LG009:
  « Désimputer » of a remitted allocation against generate_transfer_file (which holds the remit
  lock) and against the client's approval job, each first; « Désimputer » and the funds pass
  booking the run's payout, each first (critic F14); (review round 1, tests-ui-6) ops' strict link
  of the bank's return of that collection and the same funds pass, each first; « Couvrir » and the
  at-booking cover of the same reversal;
* (review round 1, CC-3) « Vérification complète des avances »: a double submit replays, and a
  request while a check run holds the open one's take is refused at once.
"""

from __future__ import annotations

import json
import uuid
from typing import Any

import psycopg
import pytest
from debit_helpers import import_entries, line_id, link_of, return_entry
from integration_helpers import DB, as_user, one, ready_mandate, storage
from remittance_helpers import (
    TERMS,
    add_client,
    approve,
    book_payout,
    book_sweep,
    drain,
    entry_books,
    own_account,
    paid_file,
    paris_today,
    remittance_tenant,
    request_run,
    run_row,
    staff,
    top_up,
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


def _positions(tenant: dict[str, Any]) -> dict[str, int]:
    """The client fund's positions (design §7.2): 5120, 4710, 4670 of the client, 4679, and I8 (5120
    + 4710 + every client's 4670 + 4679 = 0)."""
    p = {
        "5120": _book(tenant, "client_money_cash"),
        "4710": _book(tenant, "unallocated_payment"),
        "4670": _book(tenant, "client_payable", tenant["client"]),
        "4679": _book(tenant, "due_to_servicer"),
    }
    p["I8"] = p["5120"] + p["4710"] + _book(tenant, "client_payable") + p["4679"]
    return p


def _last_closing(tenant: dict[str, Any]) -> int:
    return int(
        _value(
            """select closing_booked_minor from public.bank_statement where bank_account_id = %s
               order by to_date desc, created_at desc limit 1""",
            tenant["bank"],
        )
    )


def _run_entry(run: str, entry_type: str) -> dict[str, int]:
    """The books of the run's entry of that type (its settlement: the run is its document; its
    remittance: its payout transfer is)."""
    entry = _value(
        """select e.id from public.ledger_entry e
           where e.entry_type = %s and e.source_id = case %s
             when 'client_settlement' then %s::text
             else (select r.transfer_id::text from public.remittance_run r where r.id = %s) end""",
        entry_type,
        entry_type,
        run,
        run,
    )
    return entry_books(str(entry))


def test_the_worked_example_from_12_11_to_the_end_with_the_claw_back() -> None:  # noqa: PLR0915
    """§7.2 end to end from 12/11 (plan §4.5): Martin's mandate has the claw-back clause (art. 7.4).
    RV-1 (E2 200 000) debited and its share swept; P6 300 000 allocated since; P1 taken back by the
    bank (a camt.053 return naming its end-to-end id): R(E2), the cash_out and A1 in one
    transaction, P6 owed in full; the top-up T1; RV-3 through the real prepare (`run._plan` with the
    facts as loaded: A1's item in its mandate's money) — N 82 000, D 218 000 (the 7a assertions, N
    282 000 / D 18 000 before the claw-back, flip to these, house rule R3); E11, E12 at its debit,
    the sweep E13; the positions row by row; the servicer fund at the end; Martin got 246 000."""
    tenant = remittance_tenant(terms={**TERMS, "clawback": {"clause_ref": "art. 7.4"}})
    own, own_iban = own_account(tenant)
    _f42, p1 = paid_file(tenant, 200_000)
    rv1 = request_run(tenant)
    assert (run_row(rv1)["net_minor"], run_row(rv1)["settlement_minor"]) == (164_000, 36_000)
    approve(tenant, rv1)
    drain()
    book_payout(rv1)
    assert run_row(rv1)["status"] == "booked"
    assert book_sweep(tenant) == 36_000  # E9
    paid_file(tenant, 300_000)  # P6, E10
    assert _positions(tenant)["4670"] == -300_000 and _positions(tenant)["4679"] == 0
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
                      a.mandate_id = %s, a.id
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
    a1 = str(adv[5])
    # 12/11 (the return, A1): P6 owed in full, the servicer owes the account A1; 5120 = the bank
    bank = int(closing[0])
    assert _positions(tenant) == {
        "5120": bank,
        "4710": 0,
        "4670": -300_000,
        "4679": 200_000,
        "I8": 0,
    }
    # 13/11 (T1): the top-up brings 4679 back to 0
    top_up(tenant, own, own_iban, 200_000)
    bank += 200_000
    assert _positions(tenant) == {"5120": bank, "4710": 0, "4670": -300_000, "4679": 0, "I8": 0}
    assert _cash(tenant) == _last_closing(tenant)
    # RV-3 (16/11) through the real prepare: gross 300 000 (E10, R(E2), A1), FC-3 54 000 TTC
    # set off, FC-4's 36 000 refunded, A1 taken back by the claw-back clause
    rv3 = request_run(tenant)
    draft = run_row(rv3)
    assert (
        draft["gross_minor"],
        draft["refund_minor"],
        draft["advance_recovered_minor"],
        draft["net_minor"],
        draft["settlement_minor"],
    ) == (300_000, 36_000, 200_000, 82_000, 218_000), draft["last_failure"]
    with psycopg.connect(DB) as conn:
        a1_line = conn.execute(
            """select kind, mandate_id = %s, commission_minor, deadline
               from private.remittance_draft_line
               where run_id = %s and ledger_entry_id = (select entry_id from public.client_advance
                                                         where id = %s)""",
            (tenant["mandate"], rv3, a1),
        ).fetchone()
    assert a1_line == ("client_advance", True, 0, None)  # A1's item in its mandate's money
    approve(tenant, rv3)
    drain()
    assert run_row(rv3)["status"] == "approved"
    book_payout(rv3)
    # 17/11 (E11, E12)
    assert run_row(rv3)["status"] == "booked"
    assert _run_entry(rv3, "remittance") == {"client_payable": 82_000, "client_money_cash": -82_000}
    assert _run_entry(rv3, "client_settlement") == {
        "client_payable": 218_000, "due_to_servicer": -218_000, "due_from_client_funds": 218_000,
        "commission_receivable": -18_000, "client_advance_receivable": -200_000,
        "vat_pending": 9_000, "vat_collected": -9_000,
    }  # fmt: skip
    bank -= 82_000
    assert _positions(tenant) == {"5120": bank, "4710": 0, "4670": 0, "4679": -218_000, "I8": 0}
    assert _cash(tenant) == _last_closing(tenant)
    with psycopg.connect(DB) as conn:
        settled = conn.execute(
            """select document_kind, kind, amount_minor from public.commission_settlement
               where document_id = %s""",
            (a1,),
        ).fetchall()
    assert [tuple(r) for r in settled] == [("advance", "compensation", 200_000)]
    assert _value("select private.advance_open(%s)", a1) == 0
    # 18/11 (E13): the servicer's share swept
    assert book_sweep(tenant) == 218_000
    bank -= 218_000
    assert _positions(tenant) == {"5120": bank, "4710": 0, "4670": 0, "4679": 0, "I8": 0}
    assert _cash(tenant) == _last_closing(tenant)
    # the servicer fund at the end (Martin's part of design §7.2's: 5122 = 36 000 - 200 000 +
    # 218 000; 7060 -45 000; 44571 -9 000; 4111, 4112, 4689, 44574 at 0)
    fund = {
        b: _book(tenant, b)
        for b in ("own_cash", "servicer_revenue", "vat_collected", "commission_receivable",
                  "client_advance_receivable", "due_from_client_funds", "vat_pending")
    }  # fmt: skip
    assert fund == {"own_cash": 54_000, "servicer_revenue": -45_000, "vat_collected": -9_000,
                    "commission_receivable": 0, "client_advance_receivable": 0,
                    "due_from_client_funds": 0, "vat_pending": 0}  # fmt: skip
    # Martin received 164 000 + 82 000 = 246 000: net collections 300 000 less 54 000 TTC
    received = _value(
        """select coalesce(sum(p.amount_minor), 0) from public.ledger_entry e
           join public.ledger_posting p on p.entry_id = e.id
           join public.ledger_account la on la.id = p.ledger_account_id
             and la.book = 'client_payable'
           where e.entry_type = 'remittance' and e.client_organization_id = %s""",
        tenant["client"],
    )
    assert int(received) == 246_000


def test_an_overrun_advance_s_row_is_no_mandate_s_money() -> None:
    """M2c-7b review round 1 (M7B-MONEY-1; ADR-0014 « M2c-7b review fixes », R3: 7b's version of
    this test took the advance back from its own row, N 0 / D 70 000 — the bug). An overrun
    advance on M (+A 70 000, planted as the debit's booking posts it) is a document of M, but its
    queue row pairs with rows of no file (whatever left 4670 in debit): it counts outside every
    mandate. Under M's claw-back clause and with a collection of 70 000 on the client's second
    mandate M2 (netting only), the real prepare takes nothing of the advance — not from its own
    row, not from M2's collection: gross 140 000, M2's own invoice 12 600 set off, N 127 400; the
    advance's draft line carries no mandate, and the approval's line insert guard accepts it."""
    tenant = remittance_tenant(terms={**TERMS, "clawback": {"clause_ref": "art. 7.4"}})
    with psycopg.connect(DB) as conn, conn.transaction():
        portfolio = one(
            conn,
            """insert into public.portfolio (organization_id, client_organization_id, name)
               values (%s, %s, 'P2') returning id""",
            (tenant["servicer"], tenant["client"]),
        )
        second = {**tenant, "portfolio": portfolio}
        second["mandate"] = ready_mandate(conn, second, f"MAND-{uuid.uuid4().hex[:6]}")
    paid_file(second, 70_000)
    adv_id = uuid.uuid4()
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("select private.ledger_post_set_begin()")
        conn.execute(
            """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type,
                 effective_date, idempotency_key, client_organization_id, source_type, source_id)
               values (1, %s, 'client_advance', private.paris_today(), %s, %s, 'client_advance',
                       %s)""",
            (tenant["servicer"], f"adv:test-{uuid.uuid4()}", tenant["client"], str(adv_id)),
        )
        conn.execute(
            """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
                 values (1, 1, 'due_to_servicer', 70000, 'EUR'),
                 (1, 2, 'client_payable', -70000, 'EUR'),
                 (1, 3, 'client_advance_receivable', 70000, 'EUR'),
                 (1, 4, 'due_from_client_funds', -70000, 'EUR')"""
        )
        entry = one(conn, "select entry_id from private.ledger_post_set()")
        conn.execute(
            """insert into public.client_advance (id, organization_id, client_organization_id,
                 mandate_id, currency, amount_minor, cause, cause_entry_id, entry_id)
               values (%s, %s, %s, %s, 'EUR', 70000, 'payout_overrun', %s, %s)""",
            # (its cause: its own entry stands for the debit's remittance it would cover)
            (adv_id, tenant["servicer"], tenant["client"], tenant["mandate"], entry, entry),
        )
    run = request_run(tenant)
    draft = run_row(run)
    assert (
        draft["gross_minor"],
        draft["advance_recovered_minor"],
        draft["commission_taken_minor"],
        draft["net_minor"],
        draft["settlement_minor"],
    ) == (140_000, 0, 12_600, 127_400, 12_600), draft["last_failure"]
    assert (
        _value(
            """select count(*) from private.remittance_draft_line
           where run_id = %s and kind = 'client_advance' and mandate_id is null""",
            run,
        )
        == 1
    )
    approve(tenant, run)
    drain()
    approved = run_row(run)
    assert approved["status"] == "approved", approved["last_failure"]
    assert {m["mandate_id"]: m["gross"] for m in approved["settlement_plan"]["mandates"]} == {
        None: "70000",
        str(second["mandate"]): "70000",
    }


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


def _in_flight_run(
    tenant: dict[str, Any], return_ref: str | None = None
) -> tuple[Any, str, str, str]:
    """The client's run with one collection, approved and handed out (sent), and its payout's debit
    on a statement imported without the debit job; (file, payment, run, debit line). With
    `return_ref`, the same statement also carries the bank's return of that collection (a debit
    naming the payment's end-to-end id, bank reference `return_ref`), not linked either."""
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
    entries = [entry]
    if return_ref is not None:
        e2e = str(_value("select end_to_end_id from public.payment where id = %s", p))
        entries.append(return_entry(100_000, e2e, return_ref, paris_today()))
    _import_quiet(tenant, entries)
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


@pytest.mark.parametrize("first", ["booking", "link"])
def test_a_return_link_and_the_payout_s_booking_cover_the_reversal_once(first: str) -> None:
    """(review round 1, tests-ui-6; plan §3.9 « Worker », critic F14) the M2b return path: ops'
    strict link of the bank's return of a collection of run X (« Débits et retours », link_debit
    'return') and the funds pass booking X's payout, each first. Linked first, the reversal is
    posted while X is in flight and the booking covers it (adv:<R>:<X>); booked first, the link
    covers it (adv:<R>); never a deadlock nor LG009, exactly one advance, X booked."""
    tenant = remittance_tenant()
    ret_ref = f"RT{uuid.uuid4().hex[:8].upper()}"
    _f, p, run, line = _in_flight_run(tenant, return_ref=ret_ref)
    ret_line = line_id(tenant, ret_ref)
    transfer = str(_value("select transfer_id from public.remittance_run where id = %s", run))
    e = _allocation(p)
    booking = _funds_pass(tenant, line, transfer)
    link = _as(
        tenant["staff"],
        "select public.link_debit(%s, %s, 'return', %s, null, %s, %s)",
        str(uuid.uuid4()),
        ret_line,
        p,
        "100000",
        "retour du paiement (test)",
    )
    out = _hold(booking, link) if first == "booking" else _hold(link, booking)
    seen = json.dumps(out, default=str)
    assert "40P01" not in seen and "LG009" not in seen, out
    assert link_of(ret_line) is not None and link_of(ret_line)[0] == "return", out  # type: ignore[index]
    assert run_row(run)["status"] == "booked", out
    keys = _one_cover(tenant["client"], e)
    assert len(keys) == 1, out
    assert keys[0].endswith(f":{run}") == (first == "link"), keys


# -- « Vérification complète des avances »: its double submit, a running take ----------------------


def _request_full(tenant: dict[str, Any], key: str) -> Any:
    return _as(
        tenant["admin"],
        "select public.request_full_advance_check(%s, %s)",
        key,
        tenant["servicer"],
    )


def test_a_double_submit_of_the_full_check_request_replays() -> None:
    """(review round 1, CC-3) the same key sent twice at once: the second waits for the first and
    returns its recorded result — never the « already requested » refusal its own row would get."""
    tenant = remittance_tenant()
    key = str(uuid.uuid4())
    out = _hold(_request_full(tenant, key), _request_full(tenant, key))
    assert isinstance(out["a"], dict) and out["a"].get("queued") is True, out
    assert out["b"] == out["a"], out
    assert (
        _value(
            "select count(*) from private.advance_full_check_request where organization_id = %s",
            tenant["servicer"],
        )
        == 1
    )


def test_a_full_check_request_while_a_check_run_takes_the_open_one_is_refused_at_once() -> None:
    """(review round 1, CC-3) a check run has taken the open request and is still running: a new
    request is answered « already requested » at once (the open request read under the servicer's
    lock), never left waiting on the unique index until the check run commits."""
    tenant = remittance_tenant()
    with psycopg.connect(DB) as conn:
        as_user(conn, tenant["admin"], "aal2")
        conn.execute(
            "select public.request_full_advance_check(%s, %s)",
            (str(uuid.uuid4()), tenant["servicer"]),
        )
        conn.execute("reset role")

    def take(conn: psycopg.Connection[Any]) -> Any:
        run = conn.execute(
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (tenant["servicer"],),
        ).fetchone()
        assert run is not None
        row = conn.execute(
            "select private.advance_full_check_take(%s, %s)", (tenant["servicer"], run[0])
        ).fetchone()
        return row[0] if row else None

    out = _hold(take, _request_full(tenant, str(uuid.uuid4())))
    assert out["a"] is True, out
    assert out["b"] == ("23514", "advance check refused: already_requested"), out
    assert out["b_waited"] is False, out


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
