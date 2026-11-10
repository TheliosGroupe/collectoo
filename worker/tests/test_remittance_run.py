"""A run's draft from its facts (`remittance.run.prepare_run`, design §9.4; ADR-0014 M2c-4), pure:
the worked example's RV-1 and RV-3 (§7.2: a credit note on an invoice already settled, a refund
owed), the commission kept pending (a reason, or an engine input error: a same-run reversal that
does not mirror its collection), the lines of an earlier run left pending priced with this run's,
the proceeding-opened rule (no set-off of earlier documents), deadlines per (E, delay), the French
designation (a credit's cause: a collection undone, or a change of terms re-tiering), what the plan
assumed for the approval to re-check (VAT on debits, the proceeding), and the inputs hash."""

from __future__ import annotations

from dataclasses import replace
from datetime import UTC, date, datetime
from decimal import Decimal
from typing import Any

from collectoo_worker.remittance.commission import FileFacts, KeyState, LineKind
from collectoo_worker.remittance.documents import EarlierCharge, EarlierInvoice
from collectoo_worker.remittance.run import (
    Facts,
    Item,
    OpenInvoiceRow,
    PendingLine,
    Terms,
    percent,
    prepare_run,
)

SCHEDULE: dict[str, Any] = {
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
            "rate": {"kind": "flat", "rate": "0.15"},
        }
    ],
}
NETTING = {
    "schema": "remittance-1",
    "frequency": "twice_monthly",
    "netting": {"clause_ref": "art. 7.2"},
    "clawback": None,
    "invoice_payment_days": 30,
}
TERMS = Terms("T1", "M", date(2026, 1, 1), None, 30, SCHEDULE, NETTING, "art. 6", "art. 7")
TAU = Decimal("0.2")


def _at(day: date, hour: int = 12) -> datetime:
    return datetime(day.year, day.month, day.day, hour, tzinfo=UTC)


def _alloc(entry: str, amount: int, e: date, account: str = "F42") -> Item:
    return Item(
        entry_id=entry,
        kind=LineKind.ALLOCATION,
        amount_minor=amount,
        posted_at=_at(e),
        effective_date=e,
        account_id=account,
        payment_id=f"P-{entry}",
        encaissement_date=e,
        basis={"principal": amount},
    )


def _undo(entry: str, of: Item, day: date) -> Item:
    return Item(
        entry_id=entry,
        kind=LineKind.ALLOCATION_REVERSAL,
        amount_minor=-of.amount_minor,
        posted_at=_at(day, 13),
        effective_date=day,
        account_id=of.account_id,
        payment_id=of.payment_id,
        encaissement_date=of.encaissement_date,
        basis={k: -v for k, v in of.basis.items()},
        original_entry_id=of.entry_id,
    )


def _facts(items: list[Item], **kw: Any) -> Facts:
    files = {
        a: FileFacts(a, "M", "b2b_invoice", "PF")
        for a in {i.account_id for i in items if i.account_id} | set(kw.pop("accounts", ()))
    }
    base: dict[str, Any] = {
        "run_id": "RUN-1",
        "number": "RV-2026-000001",
        "client_id": "C",
        "currency": "EUR",
        "known_at": _at(date(2026, 11, 2), 5),
        "today": date(2026, 11, 2),
        "service_from": date(2026, 10, 21),
        "service_to": date(2026, 11, 2),
        "vat_rate": TAU,
        "vat_on_debits": False,
        "items": items,
        "pending_lines": [],
        "files": files,
        "mandate_refs": {"M": "MAND-MARTIN-2026"},
        "terms": {"M": [TERMS]},
        "history": {},
        "history_seq": 0,
        "charges": {},
        "invoices": {},
        "invoice_numbers": {},
        "line_invoices": {},
        "open_documents": [],
        "payout_blockers": [],
        "commission_blockers": [],
        "payout_account_id": "PA",
    }
    base.update(kw)
    return Facts(**base)


def test_rv1_the_first_run_of_the_worked_example() -> None:
    """E2 +200 000 on M-0042 at 15 %: 30 000 HT, FC 36 000 TTC netted, N 164 000; E 12/10 → the
    deadline Wed 11/11 (a holiday) → latest execution Mon 09/11."""
    e2 = _alloc("E2", 200_000, date(2026, 10, 12))
    d = prepare_run(_facts([e2]))
    (line,) = d.lines
    assert (line.commission_minor, line.state, line.invoiced) == (30_000, "charged", True)
    assert line.deadline is not None
    assert (line.deadline.deadline, line.deadline.latest_execution) == (
        date(2026, 11, 11),
        date(2026, 11, 9),
    )
    (doc,) = d.documents
    assert (doc["kind"], doc["ht"], doc["vat"], doc["ttc"], doc["settlement"]) == (
        "invoice",
        "30000",
        "6000",
        "36000",
        "netted",
    )
    assert doc["lines"][0]["designation_fr"] == (
        "Commission de recouvrement amiable — Toutes créances — 15\u00a0% sur 2\u202f000,00\u00a0€"
        " encaissés du 21/10/2026 au 02/11/2026 (mandat MAND-MARTIN-2026, relevé RV-2026-000001)"
    )
    assert doc["charges"] == [{"account_id": "F42", "tier_key": "tout", "amount": "30000"}]
    h = d.header
    assert (h["gross"], h["net"], h["settlement"], h["invoice_ttc"]) == (
        "200000",
        "164000",
        "36000",
        "36000",
    )
    assert h["earliest_latest_execution_date"] == date(2026, 11, 9)
    assert d.key_states == (
        {
            "account_id": "F42",
            "tier_key": "tout",
            "basis": [["T1", "200000"]],
            "kept_basis": "0",
            "kept": "0",
            "commission": "30000",
            "waived": "0",  # M2c-5b: no manual credit note's waiver on the key, none absorbed
            "absorbed": [],
        },
    )


def test_rv3_a_credit_note_on_a_settled_invoice_is_a_refund_owed() -> None:
    """After RV-1 (FC-1 settled), E10 +300 000 on M-0077 and R(E2) -200 000: FC-3 54 000 TTC and a
    credit note on FC-1 of 36 000 TTC whose VAT was already due (44571); FC-1 is settled, so the
    36 000 is a refund owed, paid with the payout: N = 100 000 + 36 000 - 54 000 = 82 000."""
    e2 = _alloc("E2", 200_000, date(2026, 10, 12))
    e10 = _alloc("E10", 300_000, date(2026, 11, 10), account="F77")
    r_e2 = _undo("RE2", e2, date(2026, 11, 12))
    facts = _facts(
        [e10, r_e2],
        number="RV-2026-000003",
        today=date(2026, 11, 16),
        history={("F42", "tout"): KeyState((("T1", 200_000),), commission_minor=30_000)},
        history_seq=1,
        charges={("F42", "tout"): [EarlierCharge("FC1", (2026, 1), 30_000, vat_rate=TAU)]},
        invoices={"FC1": EarlierInvoice("FC1", 30_000, TAU)},
        invoice_numbers={"FC1": ("FC-2026-000001", date(2026, 11, 2))},
        line_invoices={"E2": "FC1"},
        open_documents=[],  # FC-1 settled at the payout's debit
    )
    d = prepare_run(facts)
    kinds = [(doc["kind"], doc["ht"], doc["vat"], doc["ttc"]) for doc in d.documents]
    assert kinds == [
        ("invoice", "45000", "9000", "54000"),
        ("credit_note", "-30000", "-6000", "-36000"),
    ]
    (corr,) = d.documents[1]["corrections"]
    assert (corr["original_invoice_id"], corr["vat_pending"], corr["vat_collected"]) == (
        "FC1",
        "0",
        "6000",
    )
    assert (corr["applied"], corr["excess"], corr["open_before"]) == ("0", "36000", "0")
    assert d.documents[1]["lines"][0]["designation_fr"].startswith(
        "Avoir rectifiant la facture FC-2026-000001 du 02/11/2026"
    )
    h = d.header
    assert (h["gross"], h["refunds"], h["taken"], h["net"], h["settlement"]) == (
        "100000",
        "36000",
        "54000",
        "82000",
        "18000",
    )
    by_entry = {ln.item.entry_id: ln for ln in d.lines}
    assert (by_entry["E10"].commission_minor, by_entry["RE2"].commission_minor) == (45_000, -30_000)
    assert by_entry["RE2"].deadline is None  # a negative line has no deadline


def test_the_commission_kept_pending_by_a_reason() -> None:
    """The client no longer a mainland professional (§9.1): the run remits gross, its lines keep
    state `pending`, no document is drawn."""
    d = prepare_run(
        _facts(
            [_alloc("E1", 100_000, date(2026, 11, 2))],
            commission_blockers=["client_identity_changed"],
        )
    )
    assert [(ln.state, ln.reason, ln.commission_minor) for ln in d.lines] == [
        ("pending", "client_identity_changed", 0)
    ]
    assert d.documents == ()
    assert (d.header["net"], d.header["settlement"]) == ("100000", "0")
    assert d.header["commission_blockers"] == ["client_identity_changed"]


def test_a_same_run_reversal_that_does_not_mirror_keeps_the_commission_pending() -> None:
    """ADR-0014 M2c-3 « For M2c-4 »: the engine refuses it (CommissionInputError); the run's
    commission stays pending, the money is remitted."""
    e1 = _alloc("E1", 100_000, date(2026, 11, 2))
    bad = replace(_undo("R1", e1, date(2026, 11, 3)), basis={"principal": -90_000})
    d = prepare_run(_facts([e1, bad]))
    assert {ln.state for ln in d.lines} == {"pending"}
    assert all(ln.reason and ln.reason.startswith("commission_input_error") for ln in d.lines)
    assert d.documents == () and d.header["gross"] == "0"


def test_lines_left_pending_by_an_earlier_run_are_priced_with_this_runs() -> None:
    """A line of RV-1 left pending is priced now with the run's own collection: one invoice of
    both, the earlier line's pricing returned apart (its money was remitted with RV-1)."""
    earlier = _alloc("E0", 100_000, date(2026, 10, 20))
    now = _alloc("E1", 50_000, date(2026, 11, 2))
    d = prepare_run(_facts([now], pending_lines=[PendingLine("RUN-0", 1, earlier)]))
    assert [ln.item.entry_id for ln in d.lines] == ["E1"]
    ((pl, lc, invoiced),) = d.repricing
    assert (pl.item.entry_id, lc.commission_minor, invoiced) == ("E0", 15_000, True)
    (doc,) = d.documents
    assert doc["ht"] == "22500"
    assert (d.header["gross"], d.header["net"]) == ("50000", str(50_000 - 27_000))


def test_documents_before_a_proceeding_are_not_set_off() -> None:
    """L622-7 I (OQ-41 default): an invoice dated before the client's proceeding opened stays due;
    the run's own invoice is netted."""
    old = OpenInvoiceRow(
        "FC0", "M", "invoice", "FC-2026-000009", date(2026, 10, 1), (2026, 9), 12_000, 2_000
    )
    facts = _facts([_alloc("E1", 100_000, date(2026, 11, 2))], open_documents=[old])
    netted = prepare_run(facts)
    assert netted.header["taken"] == str(12_000 + 18_000)
    held = prepare_run(replace(facts, proceeding_opened_on=date(2026, 10, 15)))
    assert held.header["taken"] == "18000"


def test_the_inputs_hash_names_the_inputs_not_their_order() -> None:
    a = _alloc("E1", 100_000, date(2026, 11, 2))
    b = _alloc("E2", 40_000, date(2026, 11, 3), account="F77")
    h1 = prepare_run(_facts([a, b])).header["inputs_hash"]
    assert prepare_run(_facts([b, a])).header["inputs_hash"] == h1
    assert prepare_run(_facts([a, replace(b, amount_minor=40_001)])).header["inputs_hash"] != h1
    assert prepare_run(_facts([a, b], payout_account_id="PB")).header["inputs_hash"] != h1


DESCENDING: dict[str, Any] = {
    **SCHEDULE,
    "rules": [
        {
            "id": "tout",
            "tier_key": "tout",
            "label_fr": "Toutes créances",
            "match": {},
            "rate": {
                "kind": "marginal",
                "tiers": [
                    {"up_to_minor": "500000", "rate": "0.20"},
                    {"up_to_minor": None, "rate": "0.05"},
                ],
            },
        }
    ],
}
FLAT_10: dict[str, Any] = {
    **SCHEDULE,
    "rules": [{**SCHEDULE["rules"][0], "rate": {"kind": "flat", "rate": "0.10"}}],
}


def test_a_retiering_credit_says_so_and_a_reversal_credit_says_collections_undone() -> None:
    """Legal review M2c-4 #6 (289 I 5, 272 1): 20 % then 5 % from 16/11; B 5 000 € on 20/11 was
    invoiced 1 000 € (FC-1); A 5 000 € dated 10/11 booked on 25/11 (10 %) moves B into the 5 %
    band: A's 500 € invoiced, and B's 750 € taken back on FC-1 as a « Régularisation de paliers »,
    not « encaissements annulés »; undoing a collection still says so."""
    t1 = Terms(
        "T1", "M", date(2026, 1, 1), date(2026, 11, 16), 30, FLAT_10, NETTING, "art. 6", "art. 7"
    )
    t2 = Terms("T2", "M", date(2026, 11, 16), None, 30, DESCENDING, NETTING, "art. 6", "art. 7")
    a = replace(
        _alloc("A", 500_000, date(2026, 11, 10)),
        effective_date=date(2026, 11, 25),
        posted_at=_at(date(2026, 11, 25)),
    )
    b = _alloc("B", 500_000, date(2026, 11, 20))
    earlier: dict[str, Any] = {
        "terms": {"M": [t1, t2]},
        "today": date(2026, 11, 26),
        "number": "RV-2026-000002",
        "history": {("F42", "tout"): KeyState((("T2", 500_000),), commission_minor=100_000)},
        "history_seq": 1,
        "charges": {("F42", "tout"): [EarlierCharge("FC1", (2026, 1), 100_000, vat_rate=TAU)]},
        "invoices": {"FC1": EarlierInvoice("FC1", 100_000, TAU)},
        "invoice_numbers": {"FC1": ("FC-2026-000001", date(2026, 11, 20))},
        "line_invoices": {"B": "FC1"},
    }
    d = prepare_run(_facts([a], **earlier))
    inv, crn = d.documents
    assert (inv["kind"], inv["ht"], crn["kind"], crn["ht"], crn["vat"]) == (
        "invoice",
        "50000",
        "credit_note",
        "-75000",
        "-15000",
    )
    assert "10\u00a0% sur 5\u202f000,00\u00a0€" in inv["lines"][0]["designation_fr"]
    (line,) = crn["lines"]
    assert line["designation_fr"] == (
        "Avoir rectifiant la facture FC-2026-000001 du 20/11/2026 — Régularisation de paliers"
        " (changement de conditions) (relevé RV-2026-000002)"
    )
    assert line["ht"] == "-75000"
    undone = prepare_run(_facts([_undo("RB", b, date(2026, 11, 26))], **earlier))
    (only,) = undone.documents
    (line,) = only["lines"]
    assert line["designation_fr"] == (
        "Avoir rectifiant la facture FC-2026-000001 du 20/11/2026 — encaissements annulés"
        " (relevé RV-2026-000002)"
    )


def test_the_draft_records_what_its_plan_assumed() -> None:
    """Money review #1, #2: the VAT book of the run's invoices (VAT on debits) and the client's
    proceeding are in the header (the approval sends the draft back when either changed) and in
    the inputs hash."""
    e1 = _alloc("E1", 100_000, date(2026, 11, 2))
    base = prepare_run(_facts([e1]))
    assert (base.header["vat_on_debits"], base.header["proceeding_opened_on"]) == (False, None)
    on_debits = prepare_run(_facts([e1], vat_on_debits=True))
    assert on_debits.header["vat_on_debits"] is True
    assert on_debits.plan.vat_moved_minor == 0 and base.plan.vat_moved_minor == 3_000
    held = prepare_run(_facts([e1], proceeding_opened_on=date(2026, 10, 15)))
    assert held.header["proceeding_opened_on"] == date(2026, 10, 15)
    hashes = {d.header["inputs_hash"] for d in (base, on_debits, held)}
    assert len(hashes) == 3


def test_percent_is_french() -> None:
    assert [percent(r) for r in ("0.15", "0.0550", "1", "0.1000")] == [
        "15\u00a0%",
        "5,5\u00a0%",
        "100\u00a0%",
        "10\u00a0%",
    ]
