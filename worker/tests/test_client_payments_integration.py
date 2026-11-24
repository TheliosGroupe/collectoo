"""M2c-7c-1 through the real commands (needs `make up`; plan docs/design/m2c-7-plan.md
§5.2.4-§5.2.6, §5.7 « Worker »; design §7.3; ADR-0014 « M2c-7c-1 »).

* §7.3 (ii): no netting clause — the run's invoice is due; the client pays it to the own account
  (« Règlement du client »): its pending VAT moves (44574 → 44571), the invoice is closed and
  `invoice_overdue` stays silent after its due date; the nightly checks stay clean.
* §7.3 (iii): the same payment received on the dedicated account — the statement's credit from the
  client's confirmed payout IBAN, labelled with the invoice's number (the client's designation),
  waits in « Débits et retours » (`client_credit`); « Règlement d'une facture ou d'une avance du
  cabinet » books it (+5120 / -4679 ‖ +4689 / -4111 / -419 ‖ VAT), and the next file's sweep takes
  the servicer's share it added, the surplus refunded later from the own account.
* [critic] F7, two sessions: book_client_payment_line and link_debit (« Classer sans
  comptabiliser ») on the same line, each first — no deadlock, the line decided once.
* Hypothesis, the ledger effects: random payments (amount, designation) through
  record_client_payment on a client's open invoices and advance, each in a rolled-back
  transaction — what it settles is the pure twin's plan (`plan_client_payment`), and after it
  4111[c] = its open invoices, 4112[c] = its open advances, -419[c] = its credits owed back, 44574 =
  the pending VAT, the entry balanced in the servicer's fund."""

from __future__ import annotations

import json
import threading
import time
import uuid
from datetime import date, timedelta
from typing import Any

import psycopg
import pytest
from debit_helpers import checks, violations
from explain_helpers import ADMIN
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st
from integration_helpers import DB, TERMS, as_user, one, storage
from reconciliation_helpers import pay
from remittance_helpers import (
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
)
from test_debit_bookings_integration import _session, _waits

from collectoo_worker.remittance.client_payments import (
    PayableDocument,
    entry_lines,
    plan_client_payment,
)
from collectoo_worker.synth.reconciliation import Credit

pytestmark = pytest.mark.integration
NO_NETTING = {**TERMS, "netting": None}
REASON = "Virement reçu du client (test)"


def _evidence(tenant: dict[str, Any], kind: str) -> str:
    """A document of the client of `kind` (as « Joindre un document » registers it)."""
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        return str(
            one(
                conn,
                """insert into public.document (organization_id, client_organization_id, kind,
                     storage_path, sha256, mime_type)
                   values (%s, %s, %s, %s, repeat('c', 64), 'application/pdf') returning id""",
                (tenant["servicer"], tenant["client"], kind, f"client/test/{uuid.uuid4()}.pdf"),
            )
        )


def _invoice_due(tenant: dict[str, Any], amount: int = 200_000) -> str:
    """A collection of `amount` remitted in a run without a netting clause: its invoice (15 % HT,
    20 % VAT) is due by the mandate's 30 days; the run approved and its payout booked. The
    invoice."""
    paid_file(tenant, amount)
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]
    book_payout(run)
    with psycopg.connect(DB) as conn:
        return str(
            one(
                conn,
                "select id from public.commission_invoice where run_id = %s and kind = 'invoice'",
                (run,),
            )
        )


def _invoice(invoice: str) -> tuple[str, int, int, date | None]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select number, private.document_open(id), private.document_pending_vat(id), due_date
               from public.commission_invoice where id = %s""",
            (invoice,),
        ).fetchone()
    assert row is not None
    return str(row[0]), int(row[1]), int(row[2]), row[3]


def _remittance_codes(tenant: dict[str, Any], today: date) -> set[str]:
    """The remittance checks' codes of the servicer as of `today` (invoice_overdue among them)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        run = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (tenant["servicer"],),
        )
        conn.execute(
            "select private.run_remittance_checks(%s, %s, %s)", (run, tenant["servicer"], today)
        )
        rows = conn.execute(
            "select distinct code from public.payment_check_result where run_id = %s", (run,)
        ).fetchall()
    return {str(r[0]) for r in rows}


def test_a_due_invoice_paid_to_the_own_account_moves_its_vat_and_is_never_overdue() -> None:
    """§7.3 (ii)."""
    tenant = remittance_tenant(terms=NO_NETTING)
    invoice = _invoice_due(tenant)
    number, open_minor, pending, due = _invoice(invoice)
    assert (open_minor, pending) == (36_000, 6_000) and due is not None
    own_account(tenant)
    evidence = _evidence(tenant, "client_payment_evidence")
    out = staff(
        tenant,
        """select public.record_client_payment(%s, %s, 'EUR', '360,00', private.paris_today(), %s,
                                               null, null, null, '36000', %s)""",
        str(uuid.uuid4()),
        tenant["client"],
        evidence,
        REASON,
    )
    assert [(s["number"], s["amount_minor"], s["vat_moved_minor"]) for s in out["settled"]] == [
        (number, "36000", "6000")
    ], out
    assert out["credit_minor"] == "0"
    assert entry_books(out["entry_id"]) == {
        "own_cash": 36_000,
        "commission_receivable": -36_000,
        "vat_pending": 6_000,
        "vat_collected": -6_000,
    }
    assert _invoice(invoice)[1:3] == (0, 0)
    assert "invoice_overdue" not in _remittance_codes(tenant, due + timedelta(days=1))
    assert violations(checks(tenant)["run_id"]) == []


def _client_iban(tenant: dict[str, Any]) -> str:
    with psycopg.connect(DB) as conn:
        return str(
            one(
                conn,
                "select iban from public.client_payout_account where id = %s",
                (tenant["payout"],),
            )
        )


def _client_credit_line(tenant: dict[str, Any], amount: int, label: str) -> str:
    """The client's credit on a statement of the dedicated account, from its confirmed payout IBAN:
    imported (client_transfer_in) and left by the debit job to ops (review client_credit)."""
    prefix = f"C{uuid.uuid4().hex[:6].upper()}"
    credit = Credit(
        amount, "CLIENT SAS", _client_iban(tenant), (label,), None, None, "no_match", "client"
    )
    sid = pay(tenant, storage(), [credit], prefix=prefix, start=paris_today(), days=1)
    with psycopg.connect(DB) as conn:
        line, kind, review = conn.execute(
            """select t.id::text, t.kind,
                      (select v.reason from public.bank_debit_review v
                       where v.bank_transaction_id = t.id)
               from public.bank_transaction t where t.statement_id = %s""",
            (sid,),
        ).fetchone() or (None, None, None)
    assert (kind, review) == ("client_transfer_in", "client_credit"), (kind, review)
    return str(line)


def test_the_same_payment_received_on_the_dedicated_account_is_booked_then_swept() -> None:
    """§7.3 (iii)."""
    tenant = remittance_tenant(terms=NO_NETTING)
    invoice = _invoice_due(tenant)
    number = _invoice(invoice)[0]
    own_account(tenant)
    line = _client_credit_line(tenant, 36_500, f"Reglement {number}")
    shown = staff(tenant, "select public.client_payment_line(%s, %s, null)", line, [invoice])
    assert (shown["client_id"], shown["amount_minor"], shown["refusal"]) == (
        str(tenant["client"]),
        "36500",
        None,
    ), shown
    assert shown["named_documents"] == [str(invoice)]
    out = staff(
        tenant,
        "select public.book_client_payment_line(%s, %s, %s, null, null, %s, %s)",
        str(uuid.uuid4()),
        line,
        [invoice],
        shown["preview"]["open_minor"],
        REASON,
    )
    assert [(s["amount_minor"], s["vat_moved_minor"]) for s in out["settled"]] == [
        ("36000", "6000")
    ]
    assert out["credit_minor"] == "500"
    assert entry_books(out["entry_id"]) == {
        "client_money_cash": 36_500,
        "due_to_servicer": -36_500,
        "due_from_client_funds": 36_500,
        "commission_receivable": -36_000,
        "client_credit_owed": -500,
        "vat_pending": 6_000,
        "vat_collected": -6_000,
    }
    with psycopg.connect(DB) as conn:
        booked = conn.execute(
            """select kind, amount_minor, method from public.bank_line_booking
               where bank_transaction_id = %s""",
            (line,),
        ).fetchall()
        review = conn.execute(
            "select count(*) from public.bank_debit_review where bank_transaction_id = %s", (line,)
        ).fetchone()
        share = one(
            conn,
            """select coalesce(-sum(p.amount_minor), 0) from public.ledger_account a
               join public.ledger_posting p on p.ledger_account_id = a.id
               where a.organization_id = %s and a.book = 'due_to_servicer'""",
            (tenant["servicer"],),
        )
    assert booked == [("client_payment", 36_500, "ops")]
    assert review == (0,)
    assert int(share) >= 36_500  # the servicer's share on the dedicated account grew by it
    assert violations(checks(tenant)["run_id"]) == []
    swept = book_sweep(tenant)  # the next file's sweep takes it
    assert swept == int(share)
    assert violations(checks(tenant)["run_id"]) == []


@pytest.mark.parametrize("first", ["payment", "link"])
def test_a_client_payment_and_an_explanation_of_the_same_line_each_first(first: str) -> None:
    """[critic] F7: book_client_payment_line takes the allocation lock, then the line, then the
    remit lock — the funds pass's order, as link_debit's post_debit_links: whichever comes second
    waits, then finds the line decided (no deadlock), and the line is decided once."""
    tenant = remittance_tenant(terms=NO_NETTING)
    own_account(tenant)
    line = _client_credit_line(tenant, 1_000, "Virement")
    calls = {
        "payment": (
            "select public.book_client_payment_line(%s, %s, null, null, null, '0', %s)",
            (str(uuid.uuid4()), line, REASON),
        ),
        "link": (
            "select public.link_debit(%s, %s, 'explained', null, null, null, %s)",
            (str(uuid.uuid4()), line, REASON),
        ),
    }
    second = "link" if first == "payment" else "payment"
    a, b = _session(), _session()
    errors: dict[str, BaseException] = {}
    try:
        a.execute("begin")
        as_user(a, tenant["staff"], "aal2")
        a.execute(calls[first][0], calls[first][1])
        b_pid = one(b, "select pg_backend_pid()")

        def run_second() -> None:
            try:
                with b.transaction():
                    as_user(b, tenant["staff"], "aal2")
                    b.execute(calls[second][0], calls[second][1])
            except BaseException as exc:  # kept for the assertion
                errors[second] = exc

        t = threading.Thread(target=run_second)
        t.start()
        assert _waits(int(b_pid), None), "the second command never waited"
        a.execute("commit")
        t.join(30)
        assert not t.is_alive()
    finally:
        a.close()
        b.close()
    exc = errors.get(second)
    assert exc is not None, "the second command decided the line too"
    assert not isinstance(exc, psycopg.errors.DeadlockDetected), exc
    message = str(getattr(exc, "diag", None) and exc.diag.message_primary)  # type: ignore[attr-defined]
    assert message in (
        "client payment refused: line_booked",
        "debit link refused: already_booked",
    ), message
    with psycopg.connect(DB) as conn:
        decided = conn.execute(
            """select (select count(*) from public.bank_line_booking b
                       where b.bank_transaction_id = %s),
                      (select count(*) from public.bank_debit_link l
                       where l.bank_transaction_id = %s)""",
            (line, line),
        ).fetchone()
    assert decided == ((1, 0) if first == "payment" else (0, 1)), decided


def test_a_client_payment_queued_behind_an_explanation_of_its_line_never_deadlocks() -> None:
    """[critic] F7, staged on three sessions: a third session holds the allocation lock; link_debit
    (« Classer sans comptabiliser ») queues on it, then book_client_payment_line on the same line.
    The payment takes no lock before the allocation lock, so it queues behind link_debit, which
    then takes the line and the remit lock and decides it; the payment follows and finds the line
    decided. Mutant: the line locked before the allocation lock (the payment holds the line while
    it waits; link_debit, granted the allocation lock, waits for the line) — a deadlock (40P01)."""
    tenant = remittance_tenant(terms=NO_NETTING)
    own_account(tenant)
    line = _client_credit_line(tenant, 1_000, "Virement")
    calls = {
        "link": (
            "select public.link_debit(%s, %s, 'explained', null, null, null, %s)",
            (str(uuid.uuid4()), line, REASON),
        ),
        "payment": (
            "select public.book_client_payment_line(%s, %s, null, null, null, '0', %s)",
            (str(uuid.uuid4()), line, REASON),
        ),
    }
    pids: dict[str, int] = {}
    errors: dict[str, BaseException] = {}

    def run(name: str) -> None:
        conn = _session()
        try:
            pids[name] = conn.info.backend_pid
            with conn.transaction():
                as_user(conn, tenant["staff"], "aal2")
                conn.execute(calls[name][0], calls[name][1])
        except BaseException as exc:  # kept for the assertions
            errors[name] = exc
        finally:
            conn.close()

    threads = {name: threading.Thread(target=run, args=(name,)) for name in calls}
    with psycopg.connect(DB) as holder, holder.transaction():
        holder.execute(
            "select pg_advisory_xact_lock(hashtext('payments:' || %s))", (tenant["servicer"],)
        )
        for name in ("link", "payment"):
            threads[name].start()
            for _ in range(1500):
                if name in pids:
                    break
                time.sleep(0.01)
            assert _waits(pids[name], None), f"{name} never waited"
    for t in threads.values():
        t.join(60)
        assert not t.is_alive()
    deadlocks = [e for e in errors.values() if isinstance(e, psycopg.errors.DeadlockDetected)]
    assert deadlocks == [], deadlocks
    assert "link" not in errors, errors["link"]
    exc = errors.get("payment")
    assert exc is not None, "the payment decided the line too"
    message = str(getattr(exc, "diag", None) and exc.diag.message_primary)  # type: ignore[attr-defined]
    assert message == "client payment refused: line_booked", message
    with psycopg.connect(DB) as conn:
        decided = conn.execute(
            """select (select count(*) from public.bank_line_booking b
                       where b.bank_transaction_id = %s),
                      (select count(*) from public.bank_debit_link l
                       where l.bank_transaction_id = %s)""",
            (line, line),
        ).fetchone()
    assert decided == (0, 1), decided


# Hypothesis: the ledger effects of a payment through the real command ---------------------------


@pytest.fixture(scope="module")
def owing() -> dict[str, Any]:
    """A client owing the servicer two invoices (no netting clause: due by 30 days; the first made
    due today) and an advance (a remitted collection taken back: its cover), with its evidence
    and its designation's."""
    tenant = remittance_tenant(terms=NO_NETTING)
    first = _invoice_due(tenant, 200_000)
    second = _invoice_due(tenant, 100_000)
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        conn.execute(
            "alter table public.commission_invoice disable trigger commission_invoice_append_only"
        )
        conn.execute(
            "update public.commission_invoice set due_date = private.paris_today() where id = %s",
            (first,),
        )
        conn.execute(
            "alter table public.commission_invoice"
            " enable always trigger commission_invoice_append_only"
        )
    # a collection remitted, then taken back (« Désimputer »): the cover advance
    _f, payment = paid_file(tenant, 50_000)
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    book_payout(run)
    with psycopg.connect(DB) as conn:
        account, entries = conn.execute(
            """select x.account_id, array_agg(x.id) from public.ledger_entry x
               where x.payment_id = %s and x.entry_type = 'allocation' group by x.account_id""",
            (payment,),
        ).fetchone() or (None, None)
    taken = staff(
        tenant,
        "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        str(uuid.uuid4()),
        payment,
        account,
        entries,
        "Imputation erronée (test)",
    )
    assert len(taken["advances"]) == 1, taken
    own_account(tenant)
    return {
        "tenant": tenant,
        "documents": [first, second],
        "evidence": _evidence(tenant, "client_payment_evidence"),
        "designation": _evidence(tenant, "payment_designation_evidence"),
    }


def _open_documents(conn: psycopg.Connection[Any], client: str, on: date) -> list[PayableDocument]:
    """The client's documents the plan considers, as the twin takes them (from the ledger)."""
    out = [
        PayableDocument("invoice", str(i), int(o), int(v), bool(p), due, int(y), int(s))
        for i, o, v, p, due, y, s in conn.execute(
            """select i.id, private.document_open(i.id), private.document_pending_vat(i.id),
                      private.document_client_payable(i.id, %s), i.due_date, i.year, i.seq
               from public.commission_invoice i
               where i.client_organization_id = %s and i.kind = 'invoice'
                 and private.document_open(i.id) > 0""",
            (on, client),
        ).fetchall()
    ]
    out += [
        PayableDocument("advance", str(a), int(o), 0, bool(p), born_on=b, created_at=c)
        for a, o, p, b, c in conn.execute(
            """select a.id, private.advance_open(a.id), private.document_client_payable(a.id, %s),
                      private.advance_born_on(a.id), a.created_at
               from public.client_advance a
               where a.client_organization_id = %s and private.advance_open(a.id) > 0""",
            (on, client),
        ).fetchall()
    ]
    return out


def _ledger(conn: psycopg.Connection[Any], tenant: dict[str, Any]) -> dict[str, int]:
    rows = conn.execute(
        """select a.book, coalesce(sum(p.amount_minor), 0) from public.ledger_account a
           join public.ledger_posting p on p.ledger_account_id = a.id
           where a.organization_id = %s
             and (a.client_organization_id = %s or a.book = 'vat_pending')
             and a.book in ('commission_receivable', 'client_advance_receivable',
                            'client_credit_owed', 'vat_pending')
           group by a.book""",
        (tenant["servicer"], tenant["client"]),
    ).fetchall()
    return {str(b): int(s) for b, s in rows}


@settings(
    max_examples=25, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture]
)
@given(
    amount=st.integers(1, 120_000),
    designation=st.one_of(st.none(), st.permutations([0, 1, 2])),
    keep=st.integers(1, 3),
)
def test_a_payment_s_ledger_effects_are_its_plan_s(
    owing: dict[str, Any], amount: int, designation: list[int] | None, keep: int
) -> None:
    tenant = owing["tenant"]
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        today = one(conn, "select private.paris_today()")
        docs = _open_documents(conn, tenant["client"], today)
        ids = sorted(d.id for d in docs)
        named = (
            [ids[k] for k in designation[:keep] if k < len(ids)] if designation is not None else []
        )
        expected = plan_client_payment(docs, amount, named, [], procedure=False, on=today)
        considered = (
            sum(d.open_minor for d in docs if d.id in named)
            if named
            else sum(d.open_minor for d in docs if d.payable)
        )
        before = _ledger(conn, tenant)
        as_user(conn, tenant["staff"], "aal2")
        out = one(
            conn,
            """select public.record_client_payment(%s, %s, 'EUR', %s, private.paris_today(), %s,
                                                   %s, %s, null, %s, %s)""",
            (
                str(uuid.uuid4()),
                tenant["client"],
                f"{amount // 100},{amount % 100:02d}",
                owing["evidence"],
                named or None,
                owing["designation"] if named else None,
                str(considered),
                REASON,
            ),
        )
        conn.execute("reset role")
        settled = [
            (
                s["document_kind"],
                s["document_id"],
                int(s["amount_minor"]),
                int(s["vat_moved_minor"]),
            )
            for s in out["settled"]
        ]
        assert settled == [
            (r.document_kind, r.document_id, r.amount_minor, r.vat_moved_minor)
            for r in expected
            if r.document_kind in ("invoice", "advance")
        ]
        lines = entry_lines(expected)
        assert int(out["credit_minor"]) == -lines["client_credit_owed"]
        after = _ledger(conn, tenant)
        delta = {k: after.get(k, 0) - before.get(k, 0) for k in set(after) | set(before)}
        assert delta.get("commission_receivable", 0) == lines["commission_receivable"]
        assert delta.get("client_advance_receivable", 0) == lines["client_advance_receivable"]
        assert delta.get("client_credit_owed", 0) == lines["client_credit_owed"]
        assert delta.get("vat_pending", 0) == lines["vat_pending"]
        # and the identities the nightly checks: 4111 = the open invoices, 4112 = the open
        # advances, -419 = the credits owed back, 44574 = the pending VAT
        ident = conn.execute(
            """select (select coalesce(sum(private.document_open(i.id)), 0)
                       from public.commission_invoice i
                       where i.client_organization_id = %(c)s and i.kind = 'invoice'),
                      (select coalesce(sum(private.advance_open(a.id)), 0)
                       from public.client_advance a where a.client_organization_id = %(c)s),
                      (select coalesce(sum(private.client_credit_open(x.id)), 0)
                       from public.client_credit x where x.client_organization_id = %(c)s),
                      (select coalesce(sum(private.document_pending_vat(i.id)), 0)
                       from public.commission_invoice i where i.organization_id = %(o)s)""",
            {"c": tenant["client"], "o": tenant["servicer"]},
        ).fetchone()
        assert ident is not None
        assert after.get("commission_receivable", 0) == int(ident[0])
        assert after.get("client_advance_receivable", 0) == int(ident[1])
        assert -after.get("client_credit_owed", 0) == int(ident[2])
        assert -after.get("vat_pending", 0) == int(ident[3])
        entry = conn.execute(
            """select coalesce(sum(p.amount_minor) filter (where b.money_of = 'servicer'), 0),
                      count(*) filter (where a.book = 'own_cash' and p.amount_minor = %s)
               from public.ledger_posting p
               join public.ledger_account a on a.id = p.ledger_account_id
               join public.ledger_book b on b.code = a.book
               where p.entry_id = %s""",
            (amount, out["entry_id"]),
        ).fetchone()
        assert entry == (0, 1), entry
    assert json.dumps(out)  # (the result is JSON: amounts as text)
