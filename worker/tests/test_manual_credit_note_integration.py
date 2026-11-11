"""M2c-5b: the manual credit note through the database and the real prepare and approval jobs (needs
`make up`; design §14.1, risk R2; ADR-0014 M2c-5b).

* a manual credit note on a debited run's invoice (`public.issue_credit_note`, an admin at aal2):
  the next collection on the file invoices only what it adds (the waived amount is never charged
  again); undoing the collection the invoice charged is absorbed by its waiver first (recorded, no
  document), the rest credited on it — the invoice credited in full by the two credit notes, its VAT
  exactly; the nightly checks clean (I16 with what the waiver absorbed, I18, I22);
* while that run is in flight its own invoice takes no manual credit note (`run_in_flight`, review
  ledger-vat#0); its credit note names FC-1 after it (`ht_after`, `vat_after`: review legal#1);
* that run cancelled: a corrective invoice charges again what it credited and holds, as its
  waiver, what it absorbed (review math#0), the key back to its state before the run; the run
  again takes back on the corrective invoice what the cancelled run took for the reversal there —
  the same net effect; its statement names the manual credit note (review legal#4);
* two reversals, the one the waiver absorbs first, and a later invoice still live on the file: the
  run cancelled and run again gives each reversal its own share of the pooled corrective invoice,
  the live invoice is never credited and no waiver is left behind (review math#0);
* a manual credit note issued between a draft's prepare and its approval sends the draft back
  (`history_changed`, review tests-ui#0), and so does one committing while the prepare reads the
  history, whatever the engine made of its mixed reads (review security-concurrency#0); a draft the
  engine cannot price for good (a key I22 flags) is approved, its commission pending and the run
  remitted gross — M2c-4's rule (review round 2: no `engine_error` refusal);
* a reversal whose run took from its own invoice at 20 % and LIFO from one at 10 %, cancelled: its
  chain takes first the corrective invoice holding its own invoice's share, though the 10 % one
  bears the lower number (review round 2, math#0);
* parity: the spread `private.manual_credit_plan` computes over an invoice's files is the worker's
  `documents.manual_credit`, to the cent, for random amounts, on the whole invoice or one file.
"""

from __future__ import annotations

import random
import uuid
from datetime import date
from decimal import Decimal
from types import SimpleNamespace
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
    vat_rate_from_today,
)

from collectoo_worker.remittance.commission import Retake
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
    # RV-2 in flight (approved, its payout not debited): its own invoice takes no manual credit note
    rv2_invoice = str(
        _value(
            "select id from public.commission_invoice where run_id = %s and kind = 'invoice'", rv2
        )
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="run_in_flight"):
        _credit_note(tenant, rv2_invoice, "10")
    # its credit note states FC-1 after it: nothing left (legal#1)
    assert _value(
        """select jsonb_agg(jsonb_build_array(c ->> 'ht_after', c ->> 'vat_after'))
           from public.commission_invoice n, jsonb_array_elements(n.payload -> 'corrections') c
           where n.run_id = %s and n.kind = 'credit_note'""",
        rv2,
    ) == [["0", "0"]]
    # its statement names what FC-1's waiver absorbed (the lines' commission -150,00, the documents)
    totals = _value(
        "select payload -> 'totals' from public.remittance_statement where run_id = %s", rv2
    )
    assert (totals["waived_absorbed_minor"], totals["waived_absorbed_invoices"]) == (
        "9000",
        [fc1["number"]],
    )
    issued_number = _value(
        "select number from public.commission_invoice where id = %s", issued["credit_note_id"]
    )
    assert totals["waived_absorbed_credit_notes"] == [
        {"number": issued_number, "invoice": fc1["number"]}
    ]
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
    with psycopg.connect(DB) as conn:
        corrective = conn.execute(
            """select number, ht_minor, vat_minor from public.commission_invoice
               where run_id = %s and reason = 'run_cancelled' and kind = 'invoice'""",
            (rv2,),
        ).fetchone()
    assert corrective is not None and corrective[1:] == (21_000, 4_200)
    # what RV-2 absorbed is restored as the corrective invoice's waiver (math#0): it holds again
    # all RV-2 took at FC-1's rate, 210,00 € charged and 90,00 € waived, with the reversal's line
    assert _absorbed(rv2) == [
        (fc1["number"], -9_000, "absorbed"),
        (corrective[0], 9_000, "restored"),
    ]
    assert (
        _value(
            "select entry_id::text from public.commission_waiver where run_id = %s"
            " and cause = 'restored'",
            rv2,
        )
        == reversal
    )
    assert _state(f.id) == (30_000, 9_000, "cancelled")  # as before RV-2
    assert _violations(tenant) == []

    rv3 = _approved(tenant)
    assert [(d["kind"], d["ht_minor"], d["vat_minor"]) for d in documents(rv3)] == [
        ("invoice", 45_000, 9_000),
        ("credit_note", -21_000, -4_200),
    ]
    # the reversal takes back on the corrective invoice what RV-2 took for it: 90,00 € absorbed by
    # its waiver, 210,00 € credited — it is credited in full, FC-1 untouched
    assert _credits(rv3) == [(corrective[0], -21_000, -4_200)]
    assert _absorbed(rv3) == [(corrective[0], -9_000, "absorbed")]
    assert _state(f.id) == (45_000, 0, "approved")
    totals = _value(
        "select payload -> 'totals' from public.remittance_statement where run_id = %s", rv3
    )
    assert totals["waived_absorbed_credit_notes"] == [
        {"number": issued_number, "invoice": fc1["number"]}
    ]  # followed back from the corrective invoice to the manual credit note (legal#4)
    assert _violations(tenant) == []


def _file_paid(tenant: dict[str, Any], store: Any, amount: int, back: int) -> tuple[File, str]:
    f = create_file(
        tenant,
        File(
            f"F-{uuid.uuid4().hex[:8]}",
            "b2b",
            "Débiteur SARL",
            [Item("INV-1", {"principal": 900_000}, date(2026, 9, 1))],
        ),
    )
    (pay,) = statement(
        tenant,
        store,
        [credit(amount, rf=f.rf)],
        f"M{uuid.uuid4().hex[:5]}",
        recent_business_day(back),
    ).values()
    return f, pay


def _pay_again(tenant: dict[str, Any], store: Any, f: File, amount: int, back: int) -> str:
    (pay,) = statement(
        tenant,
        store,
        [credit(amount, rf=f.rf)],
        f"M{uuid.uuid4().hex[:5]}",
        recent_business_day(back),
    ).values()
    return str(pay)


def _invoice_of(run: str) -> tuple[str, str]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select id::text, number from public.commission_invoice"
            " where run_id = %s and kind = 'invoice' and reason = 'commission'",
            (run,),
        ).fetchone()
    assert row is not None
    return str(row[0]), str(row[1])


def _open_and_waived(invoice: str, file_id: str) -> tuple[int, int]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select ch.charged_minor + coalesce((select sum(a.ht_minor)
                 from public.commission_credit_alloc a where a.original_invoice_id = ch.invoice_id
                   and a.account_id = ch.account_id and a.tier_key = ch.tier_key), 0),
                      coalesce((select sum(w.amount_minor) from public.commission_waiver w
                 where w.invoice_id = ch.invoice_id and w.account_id = ch.account_id
                   and w.tier_key = ch.tier_key), 0)
               from public.commission_invoice_charge ch
               where ch.invoice_id = %s and ch.account_id = %s""",
            (invoice, file_id),
        ).fetchone()
    return (0, 0) if row is None else (int(row[0]), int(row[1]))


def test_a_cancelled_run_again_gives_each_reversal_its_own_share() -> None:
    """Review math#0 (p1_cancel.py through the database and the jobs). 15 % flat: A, B and D,
    1 000 € each on file F, in three debited runs (FC-1, FC-2, FC-3, 150,00 € each); a manual
    credit note of 40,00 € on FC-1. A then B undone in one run, with 5 000 € on file G: A's 150,00 €
    — 40,00 € absorbed by FC-1's waiver, 110,00 € credited on FC-1 —, B's 150,00 € on FC-2.
    Cancelled: the corrective invoice charges F again 260,00 € and holds the 40,00 € as its waiver.
    The run again: A takes its 150,00 € there (40,00 € absorbed), B its 150,00 €; FC-3, whose D was
    never undone, keeps its 150,00 € and FC-1 holds no waiver — before the fix A took B's share of
    the pooled invoice and B's credit fell on FC-3, 40,00 € under-billed for good."""
    tenant = remittance_tenant()
    store = storage()
    f, pa = _file_paid(tenant, store, 100_000, 9)
    fcs = []
    for n, pay in enumerate((None, 100_000, 100_000)):
        if pay is not None:
            _pay_again(tenant, store, f, pay, 8 - n)
        run = _approved(tenant)
        book_payout(run)
        fcs.append(_invoice_of(run))
    (fc1_id, fc1), (fc2_id, _), (fc3_id, _) = fcs
    pb = str(
        _value(
            """select e.payment_id from public.ledger_entry e
               where e.account_id = %s and e.entry_type = 'allocation' and e.payment_id <> %s
               order by e.posted_at limit 1""",
            f.id,
            pa,
        )
    )
    issued = _credit_note(tenant, fc1_id, "40")
    assert _state(f.id) == (45_000, 4_000, "credit_note")
    g, _ = _file_paid(tenant, store, 500_000, 5)
    ra = _undo(tenant, pa, f.id)
    rb = _undo(tenant, pb, f.id)
    rv4 = _approved(tenant)
    assert _credits(rv4) == [(fc1, -11_000, -2_200), (fcs[1][1], -15_000, -3_000)]
    assert _absorbed(rv4) == [(fc1, -4_000, "absorbed")]
    assert (
        _value("select entry_id::text from public.commission_waiver where run_id = %s", rv4) == ra
    )
    after_rv4 = {i: _open_and_waived(i, f.id) for i in (fc1_id, fc2_id, fc3_id)}
    assert after_rv4 == {fc1_id: (0, 0), fc2_id: (0, 0), fc3_id: (15_000, 0)}

    staff(
        tenant,
        "select public.cancel_remittance_run(%s, %s, %s, %s)",
        str(uuid.uuid4()),
        rv4,
        run_row(rv4)["version"],
        "à vérifier",
        user=tenant["admin"],
    )
    with psycopg.connect(DB) as conn:
        corrective = conn.execute(
            """select id::text, number, ht_minor from public.commission_invoice
               where run_id = %s and reason = 'run_cancelled' and kind = 'invoice'""",
            (rv4,),
        ).fetchone()
    assert corrective is not None and corrective[2] == 26_000
    assert _open_and_waived(corrective[0], f.id) == (26_000, 4_000)  # all RV-4 took at 20 %
    assert _state(f.id) == (45_000, 4_000, "cancelled")
    assert _violations(tenant) == []

    rv5 = _approved(tenant)
    assert _credits(rv5) == [(corrective[1], -26_000, -5_200)]  # the corrective only
    assert _absorbed(rv5) == [(corrective[1], -4_000, "absorbed")]
    with psycopg.connect(DB) as conn:
        takes = conn.execute(
            """select a.entry_id::text, -sum(a.ht_minor) from public.commission_credit_alloc a
               join public.commission_invoice n on n.id = a.credit_note_id
               where n.run_id = %s group by a.entry_id order by 1""",
            (rv5,),
        ).fetchall()
    absorbed_by = _value(
        "select entry_id::text from public.commission_waiver where run_id = %s", rv5
    )
    assert absorbed_by == ra  # A's 40,00 € on the corrective's waiver, its 110,00 € credited
    assert dict(takes) == {ra: 11_000, rb: 15_000}
    assert {i: _open_and_waived(i, f.id) for i in (fc1_id, fc2_id, fc3_id)} == after_rv4
    assert _open_and_waived(corrective[0], f.id) == (0, 0)
    assert _state(f.id) == (15_000, 0, "approved")
    assert g.id != f.id and _state(g.id)[0] == 75_000
    totals = _value(
        "select payload -> 'totals' from public.remittance_statement where run_id = %s", rv5
    )
    issued_number = _value(
        "select number from public.commission_invoice where id = %s", issued["credit_note_id"]
    )
    assert totals["waived_absorbed_credit_notes"] == [{"number": issued_number, "invoice": fc1}]
    assert _violations(tenant) == []


def test_a_credit_note_between_prepare_and_approval_sends_the_draft_back() -> None:
    """Review tests-ui#0: a draft is prepared on a history; a manual credit note issued before its
    approval changes that history (its key state, no run): the approval job sends the draft back
    (`history_changed`) and writes nothing; « Actualiser » prices it again — the waiver now in its
    inputs — and the approval then writes a key state whose waiver is the waivers' sum."""
    tenant = remittance_tenant()
    store = storage()
    f, _ = _file_paid(tenant, store, 200_000, 6)
    rv1 = _approved(tenant)
    book_payout(rv1)
    fc1_id, _ = _invoice_of(rv1)
    _pay_again(tenant, store, f, 100_000, 4)
    rv2 = request_run(tenant)  # prepared on the history before the credit note
    assert run_row(rv2)["prepared_at"] is not None
    _credit_note(tenant, fc1_id, "50")
    approve(tenant, rv2)
    drain()
    row = run_row(rv2)
    assert (row["status"], row["last_failure"]["code"]) == ("draft", "history_changed")
    assert _value("select count(*) from public.remittance_key_state where run_id = %s", rv2) == 0
    staff(
        tenant,
        "select public.refresh_remittance_run(%s, %s, %s)",
        str(uuid.uuid4()),
        rv2,
        row["version"],
    )
    drain()
    approve(tenant, rv2)
    drain()
    assert run_row(rv2)["status"] == "approved"
    assert _state(f.id) == (45_000, 5_000, "approved")
    assert (
        _value("select sum(amount_minor) from public.commission_waiver where account_id = %s", f.id)
        == 5_000
    )
    assert _violations(tenant) == []


class _CommitsMidway:
    """The prepare's connection, with another session committing right after the statement that
    names `marker` (READ COMMITTED: every later statement of the prepare sees it)."""

    def __init__(self, conn: psycopg.Connection[Any], marker: str, action: Any) -> None:
        self._conn, self._marker, self._action, self.done = conn, marker, action, False

    def execute(self, query: Any, params: Any = None, **kw: Any) -> Any:
        cur = self._conn.execute(query, params, **kw)
        if not self.done and self._marker in str(query):
            self.done = True
            self._action()
        return cur

    def __getattr__(self, name: str) -> Any:
        return getattr(self._conn, name)


@pytest.mark.parametrize(
    ("marker", "mixed"),
    [("remittance_history_seq", False), ("remittance_key_states", True)],
)
def test_a_credit_note_committing_mid_prepare_never_gives_an_approvable_draft(
    marker: str, mixed: bool
) -> None:
    """Review security-concurrency#0: a manual credit note commits while the prepare reads its
    facts, each statement in its own snapshot. The history's position is read first: whatever
    commits after it raises it, so the approval sends the draft back (`history_changed`) — right
    after that read (the later reads see the waiver, the inputs agree) as right after the key
    states (the charges read later carry the waiver the states lack: the engine refused the inputs,
    `commission_input_error`). No refusal of its own is needed for the engine's error (review round
    2). Before the fix the second draft was approved with every line's commission left pending."""
    from collectoo_worker.jobs.remittances import run_prepare  # noqa: PLC0415

    tenant = remittance_tenant()
    store = storage()
    f, _ = _file_paid(tenant, store, 200_000, 6)
    rv1 = _approved(tenant)
    book_payout(rv1)
    fc1_id, _ = _invoice_of(rv1)
    _pay_again(tenant, store, f, 100_000, 4)
    created = staff(
        tenant,
        "select public.request_remittance_run(%s, %s, 'EUR')",
        str(uuid.uuid4()),
        tenant["client"],
    )
    run = str(created["run_id"])
    token = str(run_row(run)["job_token"])
    with psycopg.connect(DB) as conn:
        proxy = _CommitsMidway(conn, marker, lambda: _credit_note(tenant, fc1_id, "50"))
        assert run_prepare(proxy, {"run_id": run, "token": token}) == "prepared"  # type: ignore[arg-type]
        assert proxy.done
    drain()  # the queued prepare finds its run prepared: a no-op
    blockers = run_row(run)["commission_blockers"]
    assert any(b.startswith("commission_input_error") for b in blockers) == mixed, blockers
    approve(tenant, run)
    drain()
    row = run_row(run)
    assert (row["status"], row["last_failure"]["code"]) == ("draft", "history_changed")
    assert _value("select count(*) from public.remittance_key_state where run_id = %s", run) == 0


def test_a_draft_the_engine_cannot_price_for_good_is_approved_gross() -> None:
    """Review round 2 (security-concurrency#0, option a): a key whose state disagrees with its
    invoices (I22: its commission one cent above what they charge, as pgTAP 027 builds) — every
    prepare reads the same data and the engine refuses it every time (`commission_input_error`).
    M2c-4's rule holds: the draft is approvable, its lines' commission pending, and the run remits
    the gross (R124-6's month); the nightly check flags the key. Under the integrated fix's
    `engine_error` refusal no gross payout could leave."""
    tenant = remittance_tenant()
    store = storage()
    f, _ = _file_paid(tenant, store, 200_000, 6)
    rv1 = _approved(tenant)
    book_payout(rv1)
    with psycopg.connect(DB) as conn:
        conn.execute(
            """insert into public.remittance_key_state (organization_id, client_organization_id,
                 account_id, tier_key, run_id, cause, basis, kept_basis_minor, kept_minor,
                 commission_minor, waived_minor)
               select organization_id, client_organization_id, account_id, tier_key, run_id,
                      'approved', basis, kept_basis_minor, kept_minor, commission_minor + 1,
                      waived_minor
               from public.remittance_key_state where account_id = %s order by seq desc limit 1""",
            (f.id,),
        )
    _pay_again(tenant, store, f, 100_000, 4)
    run = request_run(tenant)
    draft = run_row(run)
    assert any(b.startswith("commission_input_error") for b in draft["commission_blockers"])
    approve(tenant, run)
    drain()
    row = run_row(run)
    assert row["status"] == "approved", row["last_failure"]
    assert row["net_minor"] == row["gross_minor"] == 100_000  # remitted gross
    assert row["invoice_ht_minor"] == 0 and documents(run) == []
    with psycopg.connect(DB) as conn:
        states = conn.execute(
            "select commission_state, commission_minor from public.remittance_line"
            " where run_id = %s",
            (run,),
        ).fetchall()
    assert states == [("pending", 0)]
    assert "commission_key_state" in _violations(tenant)


def test_a_reversal_cancelled_again_takes_back_its_own_invoices_share_first() -> None:
    """Review round 2 (math#0) through the database: marginal 5 % up to 1 000,00 €, 20 % beyond. A
    1 000,00 € at 20 % VAT (FC-1, 50,00 €), B 500,00 € at 10 % (FC-2, 100,00 €). Undoing A gives
    back 125,00 € (B moves down into the 5 % band): 50,00 € on FC-1, its own, then 75,00 € LIFO on
    FC-2. Cancelled: the 10 % corrective invoice (75,00 €) is issued before the 20 % one (50,00 €).
    The chain the next prepare builds for A takes first the one holding FC-1's share — the order the
    cancelled run took it, never the numbers' (when another rate shrinks the credit, it comes off
    where the run never approved takes it) — and the run again credits both in full."""
    from collectoo_worker.jobs.remittances import _line_invoices  # noqa: PLC0415

    schedule = {
        "schema": "commission-1",
        "basis": {
            "families": "all",
            "forwards": {
                "file_recalled": False,
                "before_servicing_start": False,
                "client_ratification": False,
            },
            "on_reversal": "credit",
        },
        "rules": [
            {
                "id": "tout",
                "tier_key": "tout",
                "label_fr": "Toutes créances",
                "match": {},
                "rate": {
                    "kind": "marginal",
                    "tiers": [
                        {"up_to_minor": "100000", "rate": "0.05"},
                        {"up_to_minor": None, "rate": "0.20"},
                    ],
                },
            }
        ],
    }
    tenant = remittance_tenant(schedule=schedule)
    store = storage()
    f, pa = _file_paid(tenant, store, 100_000, 9)
    rv1 = _approved(tenant)
    book_payout(rv1)
    fc1_id, _ = _invoice_of(rv1)
    with vat_rate_from_today("0.1000"):
        _pay_again(tenant, store, f, 50_000, 7)
        rv2 = _approved(tenant)
        book_payout(rv2)
    fc2_id, _ = _invoice_of(rv2)
    _file_paid(tenant, store, 500_000, 5)  # client money to cover the reversal (another file)
    ra = _undo(tenant, pa, f.id)
    rv3 = _approved(tenant)
    assert {c[0]: c[1] for c in _credits(rv3)} == {
        _invoice_of(rv1)[1]: -5_000,
        _invoice_of(rv2)[1]: -7_500,
    }
    staff(
        tenant,
        "select public.cancel_remittance_run(%s, %s, %s, %s)",
        str(uuid.uuid4()),
        rv3,
        run_row(rv3)["version"],
        "à vérifier",
        user=tenant["admin"],
    )
    with psycopg.connect(DB) as conn:
        correctives = conn.execute(
            """select vat_rate::text, id::text, seq, ht_minor from public.commission_invoice
               where run_id = %s and kind = 'invoice' and reason = 'run_cancelled'""",
            (rv3,),
        ).fetchall()
        by_rate = {r[0]: (r[1], int(r[2]), int(r[3])) for r in correctives}
        assert by_rate["0.1000"][2] == 7_500 and by_rate["0.2000"][2] == 5_000
        assert by_rate["0.1000"][1] < by_rate["0.2000"][1]  # the 10 % one numbered first
        original = str(
            _value("select reverses_entry_id from public.ledger_entry where id = %s", ra)
        )
        item = SimpleNamespace(entry_id=ra, original_entry_id=original)
        chain = _line_invoices(conn, [item], [])  # type: ignore[list-item]
    key = (f.id, "tout")
    assert chain == {
        original: (
            Retake(by_rate["0.2000"][0], ((key, 5_000),)),
            Retake(by_rate["0.1000"][0], ((key, 7_500),)),
            fc1_id,
        )
    }
    rv4 = _approved(tenant)
    assert sorted(c[1] for c in _credits(rv4)) == [-7_500, -5_000]  # both correctives, in full
    assert _open_and_waived(fc2_id, f.id) == (2_500, 0)  # B's 25,00 € at 5 %
    assert _state(f.id) == (2_500, 0, "approved")


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
