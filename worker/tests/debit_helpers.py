"""Helpers for the M2b-6 integration tests (need `make up`): statements with debits (a payment's
return, our refund, a refund that comes back), imported through the payments queue, and what the
ledger and the bank lines say afterwards."""

import random
import uuid
from collections.abc import Sequence
from datetime import date
from typing import Any

import psycopg
from integration_helpers import DB, as_user
from statement_helpers import drain, upload

from collectoo_worker.runtime.storage import Storage
from collectoo_worker.synth.camt053 import Entry, Tx, make_doc, render_camt053
from collectoo_worker.synth.ids import iban_fr


def return_entry(amount: int, e2e: str | None, ref: str, day: date, reason: str = "MD06") -> Entry:
    """A debit undoing a credit: reversal indicator, return sub-family, RtrInf reason."""
    tx = Tx(amount, ref=ref, end_to_end_id=e2e, ustrd=(f"RETOUR {reason}",), return_reason=reason)
    return Entry(
        amount, False, day, day, reversal=True, ref=f"N{ref}", code="PMNT/RCDT/RRTN", txs=(tx,)
    )


def refund_entry(amount: int, rfd: str, ref: str, day: date) -> Entry:
    """Our refund leaving the account (end-to-end id RFD...)."""
    tx = Tx(amount, ref=ref, end_to_end_id=rfd, name="PAYEUR", ustrd=("REMBOURSEMENT",))
    return Entry(amount, False, day, day, ref=f"N{ref}", code="PMNT/ICDT/ESCT", txs=(tx,))


def bounce_entry(amount: int, rfd: str, ref: str, day: date) -> Entry:
    """Our refund coming back unpaid: a credit undoing the debit."""
    tx = Tx(amount, ref=ref, end_to_end_id=rfd, ustrd=("RETOUR VIREMENT",), return_reason="AC04")
    return Entry(
        amount, True, day, day, reversal=True, ref=f"N{ref}", code="PMNT/ICDT/RRTN", txs=(tx,)
    )


def fee_entry(amount: int, ref: str, day: date) -> Entry:
    return Entry(amount, False, day, day, ref=f"N{ref}", code="PMNT/MDOP/FEES", info="FRAIS")


def import_entries(  # noqa: PLR0913 - the statement's identity
    tenant: dict[str, Any],
    store: Storage,
    entries: Sequence[Entry],
    *,
    day: date,
    opening: int,
    receipts: bool = False,
) -> str:
    """A one-day camt.053 statement of these entries, imported; the payments queue drained."""
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        entries,
        iban=tenant["iban"],
        from_date=day,
        to_date=day,
        opening_minor=opening,
        stmt_id=stmt,
    )
    target = upload(tenant, store, render_camt053(doc, "08"), name=f"{stmt}.xml")
    drain(store, receipts=receipts)
    return str(target["statement_id"])


def closing(statement_id: str) -> int:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select closing_booked_minor from public.bank_statement where id = %s", (statement_id,)
        ).fetchone()
    assert row is not None
    return int(row[0])


def line_id(tenant: dict[str, Any], ref: str) -> str:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select id::text from public.bank_transaction"
            " where organization_id = %s and acct_svcr_ref = %s",
            (tenant["servicer"], ref),
        ).fetchone()
    assert row is not None
    return str(row[0])


def link_of(line: str) -> tuple[str, str | None, str | None, str] | None:
    """(kind, payment, refund request, method) of a bank line's link, if any."""
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select kind, payment_id::text, refund_request_id::text, method
               from public.bank_debit_link where bank_transaction_id = %s""",
            (line,),
        ).fetchone()
    return None if row is None else (row[0], row[1], row[2], row[3])


def review_of(line: str) -> str | None:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select reason from public.bank_debit_review where bank_transaction_id = %s", (line,)
        ).fetchone()
    return None if row is None else str(row[0])


def entries_of(payment: str) -> list[tuple[str, str | None, date, int]]:
    """(entry type, reversed type, date, 4710 amount) of a payment's entries, in posting order."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select e.entry_type, t.entry_type, e.effective_date,
                      (select sum(lp.amount_minor) from public.ledger_posting lp
                       join public.ledger_account la on la.id = lp.ledger_account_id
                       where lp.entry_id = e.id and la.book = 'unallocated_payment')
               from public.ledger_entry e
               left join public.ledger_entry t on t.id = e.reverses_entry_id
               where e.payment_id = %s order by e.posted_at, e.id""",
            (payment,),
        ).fetchall()
    return [(r[0], r[1], r[2], int(r[3])) for r in rows]


def notifications(payment: str) -> list[tuple[str, str | None]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select kind, reason from public.client_notification where payment_id = %s
               order by created_at, id""",
            (payment,),
        ).fetchall()
    return [(r[0], r[1]) for r in rows]


def receipt_kinds(payment: str) -> list[str]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            "select kind from public.receipt where payment_id = %s order by version", (payment,)
        ).fetchall()
    return [str(r[0]) for r in rows]


def refund_request(
    tenant: dict[str, Any], payment: str, amount: int, reason_code: str
) -> dict[str, Any]:
    """request_refund as the ops manager (what the page shows: the payment's reason, what is
    left), to a synthetic IBAN (the test credits carry none)."""
    payee = iban_fr(random.Random(payment))
    with psycopg.connect(DB) as conn, conn.transaction():
        row = conn.execute(
            """select p.review_reason, x.unallocated_minor::text
               from public.payment p cross join lateral private.payment_positions(array[p.id]) x
               where p.id = %s""",
            (payment,),
        ).fetchone()
        assert row is not None
        as_user(conn, tenant["staff"], "aal2")
        conn.execute("set local statement_timeout = '8s'")
        out = conn.execute(
            "select public.request_refund(%s, %s, %s, %s, 'PAYEUR', %s, %s, %s, %s)",
            (
                str(uuid.uuid4()),
                payment,
                str(amount),
                payee,
                reason_code,
                row[0],
                row[1],
                "remboursement au payeur",
            ),
        ).fetchone()
    assert out is not None
    return dict(out[0])


def checks(tenant: dict[str, Any]) -> dict[str, Any]:
    """The nightly checks of the servicer, now (the job's SQL)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        row = conn.execute(
            "select private.run_payment_checks(%s)", (tenant["servicer"],)
        ).fetchone()
    assert row is not None
    return dict(row[0])


def violations(run_id: str) -> list[tuple[str, str | None]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select code, subject_id::text from public.payment_check_result
               where run_id = %s and severity = 'violation' order by code""",
            (run_id,),
        ).fetchall()
    return [(r[0], r[1]) for r in rows]
