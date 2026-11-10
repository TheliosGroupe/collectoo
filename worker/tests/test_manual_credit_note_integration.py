"""M2c-5b: the manual credit note through the database and the real prepare and approval jobs (needs
`make up`; design §14.1, risk R2; ADR-0014 M2c-5b).

* a manual credit note on a debited run's invoice (`public.issue_credit_note`, an admin at aal2):
  the next collection on the file invoices only what it adds (the waived amount is never charged
  again); undoing the collection the invoice charged is absorbed by its waiver first (recorded, no
  document), the rest credited on it — the invoice credited in full by the two credit notes, its VAT
  exactly; the nightly checks clean (I16 with what the waiver absorbed, I18, I22);
* that run cancelled: its credit note restored by a corrective invoice of what it credited, what it
  absorbed restored as the invoice's waiver, the key back to its state before the run; the run
  again credits the reversal on the corrective invoice first, then absorbs the waiver on the
  original invoice — the same net effect;
* parity: the spread `private.manual_credit_plan` computes over an invoice's files is the worker's
  `documents.manual_credit`, to the cent, for random amounts, on the whole invoice or one file.
"""

from __future__ import annotations

import random
import uuid
from datetime import date
from decimal import Decimal
from typing import Any

import psycopg
import pytest
from allocation_helpers import File, Item, create_file, credit, statement
from debit_helpers import checks
from integration_helpers import DB, one, storage
from remittance_helpers import (
    approve,
    book_payout,
    documents,
    drain,
    paid_file,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)

from collectoo_worker.remittance.documents import EarlierInvoice, manual_credit

pytestmark = pytest.mark.integration
RATE = Decimal("0.2")


def _value(sql: str, *params: Any) -> Any:
    with psycopg.connect(DB) as conn:
        return one(conn, sql, params)


def _approved(tenant: dict[str, Any]) -> str:
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    row = run_row(run)
    assert row["status"] == "approved", row["last_failure"]
    return run


def _credit_note(
    tenant: dict[str, Any], invoice: str, amount: str, account: str | None = None
) -> Any:
    remaining = str(
        _value(
            """select i.ht_minor + coalesce((select sum(c.ht_minor)
                 from public.commission_credit_correction c where c.original_invoice_id = i.id), 0)
               from public.commission_invoice i where i.id = %s""",
            invoice,
        )
    )
    return staff(
        tenant,
        "select public.issue_credit_note(%s, %s, %s, %s, %s, %s, %s)",
        str(uuid.uuid4()),
        invoice,
        amount,
        "terms_error",
        "taux négocié à 12 % non saisi",
        remaining,
        account,
        user=tenant["admin"],
    )


def _undo(tenant: dict[str, Any], payment: str, file_id: str) -> str:
    entry = _value(
        "select id from public.ledger_entry where payment_id = %s and entry_type = 'allocation'",
        payment,
    )
    staff(
        tenant,
        "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        str(uuid.uuid4()),
        payment,
        file_id,
        [str(entry)],
        "paiement repris par la banque",
    )
    return str(_value("select id from public.ledger_entry where reverses_entry_id = %s", entry))


def _violations(tenant: dict[str, Any]) -> list[str]:
    run = checks(tenant)
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select code from public.payment_check_result
               where run_id = %s and severity = 'violation' order by code""",
            (run["run_id"],),
        ).fetchall()
    # (the emulated debits have no bank line: I19 flags them; M2c-6 books from the statement)
    return [r[0] for r in rows if r[0] != "bank_cash_identity"]


def _state(file_id: str) -> tuple[int, int, str]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select commission_minor, waived_minor, cause from public.remittance_key_state
               where account_id = %s order by seq desc limit 1""",
            (file_id,),
        ).fetchone()
    assert row is not None
    return int(row[0]), int(row[1]), str(row[2])


def _credits(run: str) -> list[tuple[str, int, int]]:
    """The run's credit notes per corrected invoice: (its number, HT, VAT)."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select o.number, c.ht_minor, c.vat_minor from public.commission_invoice n
               join public.commission_credit_correction c on c.credit_note_id = n.id
               join public.commission_invoice o on o.id = c.original_invoice_id
               where n.run_id = %s and n.reason = 'commission' order by o.seq""",
            (run,),
        ).fetchall()
    return [(r[0], int(r[1]), int(r[2])) for r in rows]


def _absorbed(run: str) -> list[tuple[str, int, str]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select i.number, w.amount_minor, w.cause from public.commission_waiver w
               join public.commission_invoice i on i.id = w.invoice_id
               where w.run_id = %s order by w.id""",
            (run,),
        ).fetchall()
    return [(r[0], int(r[1]), r[2]) for r in rows]


def test_a_waiver_is_never_charged_again_and_a_reversal_meets_it_first() -> None:
    """15 % flat. A 2 000 € on file F: FC-1 300,00 € HT, debited. A manual credit note of 90,00 €
    on FC-1. Then B 3 000 € on F and A undone in one run: B invoiced 450,00 € — nothing of the
    90,00 € again; A's 300,00 € to credit on FC-1, whose waiver absorbs 90,00 €, the credit note
    credits 210,00 € (VAT R(300 x 20 %) - R(90 x 20 %) = 42,00 €), so FC-1 is credited in full with
    its VAT exactly. Then that run cancelled and run again: the same documents."""
    tenant = remittance_tenant()
    f = create_file(
        tenant,
        File(
            f"F-{uuid.uuid4().hex[:8]}",
            "b2b",
            "Débiteur SARL",
            [Item("INV-1", {"principal": 700_000}, date(2026, 9, 1))],
        ),
    )
    store = storage()
    (pa,) = statement(
        tenant, store, [credit(200_000, rf=f.rf)], "MA", recent_business_day(8)
    ).values()
    rv1 = _approved(tenant)
    book_payout(rv1)
    (fc1,) = documents(rv1)
    assert fc1["ht_minor"] == 30_000
    fc1_id = str(
        _value(
            "select id from public.commission_invoice where number = %s and run_id = %s",
            fc1["number"],
            rv1,
        )
    )

    issued = _credit_note(tenant, fc1_id, "90,00")
    assert (issued["ht"], issued["vat"], issued["applied"], issued["excess"]) == (
        "9000",
        "1800",
        "0",
        "10800",
    )  # FC-1 was set off on RV-1's payout: the whole credit note is a refund owed
    assert _state(f.id) == (30_000, 9_000, "credit_note")

    # B 3 000 € on F (the client's money covers the undo) and A undone, in one run
    statement(tenant, store, [credit(300_000, rf=f.rf)], "MB", recent_business_day(6))
    reversal = _undo(tenant, pa, f.id)
    rv2 = _approved(tenant)
    assert [(d["kind"], d["ht_minor"], d["vat_minor"]) for d in documents(rv2)] == [
        ("invoice", 45_000, 9_000),  # B's 15 %: nothing of the 90,00 € charged again
        ("credit_note", -21_000, -4_200),  # A's 300,00 €, less the 90,00 € FC-1's waiver absorbs
    ]
    assert _credits(rv2) == [(fc1["number"], -21_000, -4_200)]
    assert _absorbed(rv2) == [(fc1["number"], -9_000, "absorbed")]
    assert (
        _value("select entry_id::text from public.commission_waiver where run_id = %s", rv2)
        == reversal
    )
    assert _state(f.id) == (45_000, 0, "approved")
    # its statement names what FC-1's waiver absorbed (the lines' commission -150,00 vs the documents)
    totals = _value(
        "select payload -> 'totals' from public.remittance_statement where run_id = %s", rv2
    )
    assert (totals["waived_absorbed_minor"], totals["waived_absorbed_invoices"]) == (
        "9000",
        [fc1["number"]],
    )
    with psycopg.connect(DB) as conn:
        closed = conn.execute(
            """select i.ht_minor + (select sum(c.ht_minor)
                                    from public.commission_credit_correction c
                                    where c.original_invoice_id = i.id),
                      i.vat_minor + (select sum(c.vat_minor)
                                     from public.commission_credit_correction c
                                     where c.original_invoice_id = i.id),
                      private.document_open(i.id), private.document_pending_vat(i.id)
               from public.commission_invoice i where i.id = %s""",
            (fc1_id,),
        ).fetchone()
    # FC-1 credited in full by the manual credit note and RV-2's, its VAT exactly
    assert closed == (0, 0, 0, 0)
    assert _violations(tenant) == []

    # RV-2 cancelled before its file: its credit note restored, what it absorbed restored
    cancelled = staff(
        tenant,
        "select public.cancel_remittance_run(%s, %s, %s, %s)",
        str(uuid.uuid4()),
        rv2,
        run_row(rv2)["version"],
        "à vérifier",
        user=tenant["admin"],
    )
    assert cancelled["status"] == "cancelled"
    assert _absorbed(rv2) == [
        (fc1["number"], -9_000, "absorbed"),
        (fc1["number"], 9_000, "restored"),
    ]
    with psycopg.connect(DB) as conn:
        corrective = conn.execute(
            """select number, ht_minor, vat_minor from public.commission_invoice
               where run_id = %s and reason = 'run_cancelled' and kind = 'invoice'""",
            (rv2,),
        ).fetchone()
    assert corrective is not None and corrective[1:] == (21_000, 4_200)
    assert _state(f.id) == (30_000, 9_000, "cancelled")  # as before RV-2
    assert _violations(tenant) == []

    rv3 = _approved(tenant)
    assert [(d["kind"], d["ht_minor"], d["vat_minor"]) for d in documents(rv3)] == [
        ("invoice", 45_000, 9_000),
        ("credit_note", -21_000, -4_200),
    ]
    assert _credits(rv3) == [(corrective[0], -21_000, -4_200)]  # the corrective invoice first
    assert _absorbed(rv3) == [(fc1["number"], -9_000, "absorbed")]  # then FC-1's waiver
    assert _state(f.id) == (45_000, 0, "approved")
    assert _violations(tenant) == []


def test_the_spread_in_sql_is_the_workers() -> None:
    """Five files on one invoice (15 % of 1 000,01 € … 5 000,05 €): for 60 random amounts, on the
    whole invoice or on one file, `private.manual_credit_plan` spreads the HT exactly as
    `documents.manual_credit` does (proportional, the cents to the largest remainders, ties by
    file), with the same VAT."""
    tenant = remittance_tenant()
    files = [paid_file(tenant, 100_001 * (n + 1), recent_business_day(4))[0] for n in range(5)]
    run = _approved(tenant)
    book_payout(
        run
    )  # (its plan set off the invoice: no manual credit while the payout is in flight)
    (inv,) = documents(run)
    inv_id = str(_value("select id from public.commission_invoice where run_id = %s", run))
    with psycopg.connect(DB) as conn:
        opened = {
            (str(a), t): int(o)
            for a, t, o in conn.execute(
                "select account_id, tier_key, charged_minor from public.commission_invoice_charge"
                " where invoice_id = %s",
                (inv_id,),
            ).fetchall()
        }
        rng = random.Random(20261114)
        for _ in range(60):
            account = rng.choice([None, *(f.id for f in files)])
            total = sum(o for k, o in opened.items() if account is None or k[0] == account)
            amount = rng.randint(1, total)
            plan = one(
                conn, "select private.manual_credit_plan(%s, %s, %s)", (inv_id, amount, account)
            )
            assert plan["refusal"] is None, plan
            mine = manual_credit(
                EarlierInvoice(inv_id, inv["ht_minor"], RATE), opened, amount, account
            )
            assert {
                (a["account_id"], a["tier_key"]): int(a["ht"]) for a in plan["allocations"]
            } == dict(mine.allocations)
            assert int(plan["vat"]) == mine.vat_minor
