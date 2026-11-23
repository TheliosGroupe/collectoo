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

from collectoo_worker.remittance.calendar import conservative
from collectoo_worker.remittance.commission import FileFacts, KeyState, LineKind
from collectoo_worker.remittance.deadline import remittance_deadline
from collectoo_worker.remittance.documents import EarlierCharge, EarlierInvoice
from collectoo_worker.remittance.run import (
    Facts,
    Item,
    OpenAdvanceRow,
    OpenInvoiceRow,
    PendingLine,
    Terms,
    UnplannedPaid,
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


def test_a_returned_payout_keeps_the_deadline_of_the_line_it_came_from() -> None:
    """Design §9.2, Q7 (M2c-6b-1 review legal-texts#1, money-2): a payout that came back is held to
    the R124-6 date of the returned run's line it came from — that line's E and its mandate's delay
    (15 days here: never the one-month default for want of a file). It stays uncommissioned and
    outside any mandate's gross; the line carries E and the terms version, and the header's dates
    count it (the approval's late reason, the file's late flag). With no dated line to hold it to,
    no date, as before."""
    e = date(2026, 10, 12)
    back = Item(
        entry_id="RT",
        kind=LineKind.PAYOUT_RETURNED,
        amount_minor=164_000,
        posted_at=_at(date(2026, 11, 2), 9),
        effective_date=date(2026, 11, 2),
        encaissement_date=e,
        held_terms_id="T1",
        held_days=15,
    )
    d = prepare_run(_facts([back]))
    (line,) = d.lines
    want = remittance_deadline(e, 15, conservative())
    assert line.deadline == want and want != remittance_deadline(e, 30, conservative())
    assert (line.commission_minor, line.state, line.reason) == (0, "none", "not_commissionable")
    assert (line.mandate_id, line.terms_id, line.item.encaissement_date) == (None, "T1", e)
    assert d.header["earliest_deadline"] == want.deadline
    assert d.header["earliest_latest_execution_date"] == want.latest_execution
    assert d.plan.net_minor == 164_000  # no mandate's gross: nothing netted against it
    # unmeetable (a 1-5 day delay, OQ-71): flagged on the line, held to the month by the checks
    short = prepare_run(_facts([replace(back, held_days=1)]))
    assert short.lines[0].deadline is not None and short.lines[0].deadline.unmeetable
    # no dated line found for it: no date (the SQL queue drops it too)
    bare = prepare_run(_facts([replace(back, held_terms_id=None, held_days=None)]))
    assert bare.lines[0].deadline is None and bare.header["earliest_deadline"] is None


def test_percent_is_french() -> None:
    assert [percent(r) for r in ("0.15", "0.0550", "1", "0.1000")] == [
        "15\u00a0%",
        "5,5\u00a0%",
        "100\u00a0%",
        "10\u00a0%",
    ]


# -- M2c-7b: the advances in the plan, with their mandate's money (plan §4.1.9, §4.2) -----------

CLAWBACK = {**NETTING, "clawback": {"clause_ref": "art. 7.4"}}
TERMS_CLAW = Terms("T1", "M", date(2026, 1, 1), None, 30, SCHEDULE, CLAWBACK, "art. 6", "art. 7")


def _advance_item(entry: str, amount: int, day: date, mandate: str | None) -> Item:
    """A remitted reversal's cover's queue item as the prepare loads it: no file, its advance's
    mandate and cause (review round 1: the facts carry the cause)."""
    return Item(
        entry_id=entry,
        kind=LineKind.CLIENT_ADVANCE,
        amount_minor=amount,
        posted_at=_at(day, 14),
        effective_date=day,
        advance_mandate_id=mandate,
        advance_cause="remitted_reversal",
    )


def _open(ref: str, mandate: str | None, born: date, open_minor: int) -> OpenAdvanceRow:
    return OpenAdvanceRow(ref, mandate, "remitted_reversal", born, _at(born, 14), open_minor)


def _rv3(mandate: str | None = "M", **kw: Any) -> Facts:
    """§7.2 RV-3 (16/11) with the facts as loaded: E10 +300 000 (F77), R(E2) -200 000 (F42), A1
    +200 000 (the cover of R(E2), dated 12/11, on its line's mandate) and A1 open for 200 000."""
    e2 = _alloc("E2", 200_000, date(2026, 10, 12))
    e10 = _alloc("E10", 300_000, date(2026, 11, 10), account="F77")
    r_e2 = _undo("RE2", e2, date(2026, 11, 12))
    a1 = _advance_item("A1", 200_000, date(2026, 11, 12), mandate)
    base: dict[str, Any] = {
        "number": "RV-2026-000003",
        "today": date(2026, 11, 16),
        "terms": {"M": [TERMS_CLAW]},
        "history": {("F42", "tout"): KeyState((("T1", 200_000),), commission_minor=30_000)},
        "history_seq": 1,
        "charges": {("F42", "tout"): [EarlierCharge("FC1", (2026, 1), 30_000, vat_rate=TAU)]},
        "invoices": {"FC1": EarlierInvoice("FC1", 30_000, TAU)},
        "invoice_numbers": {"FC1": ("FC-2026-000001", date(2026, 11, 2))},
        "line_invoices": {"E2": "FC1"},
        "open_advances": [_open("A1", mandate, date(2026, 11, 12), 200_000)],
    }
    base.update(kw)
    items = base.pop("items", [e10, r_e2, a1])
    return _facts(items, **base)


def test_rv3_takes_the_advance_back_from_its_mandate_s_money() -> None:
    """Design §7.2 RV-3 through `_plan` with the facts as loaded ([critic] M7-MONEY-7): A1 has
    no file and counts in its advance's mandate, so the claw-back takes all of it: N 82 000, D
    218 000 (Dc 18 000, Da 200 000). With A1's item outside M (NO_MANDATE) the take would be capped
    at M's room: N 200 000, D 100 000, 118 000 left open."""
    d = prepare_run(_rv3())
    h = d.header
    assert (h["gross"], h["refunds"], h["taken"], h["advances"], h["net"], h["settlement"]) == (
        "300000",
        "36000",
        "54000",
        "200000",
        "82000",
        "218000",
    )
    by_entry = {ln.item.entry_id: ln for ln in d.lines}
    a1 = by_entry["A1"]
    assert (a1.mandate_id, a1.commission_minor, a1.state, a1.deadline, a1.terms_id) == (
        "M",
        0,
        "none",
        None,
        None,
    )
    advances = [s for s in d.plan.settles if s.kind == "advance"]
    assert [(s.ref, s.mandate_id, s.amount_minor, s.open_before_minor) for s in advances] == [
        ("A1", "M", 200_000, 200_000)
    ]
    (m,) = d.plan.mandates
    assert (m.mandate_id, m.gross_minor, m.take_advance_minor) == ("M", 300_000, 200_000)


def test_without_the_claw_back_clause_the_advance_stays_open() -> None:
    """§7.3's first variant: no claw-back clause, nothing taken (N 282 000); A1 stays in M."""
    d = prepare_run(_rv3(terms={"M": [TERMS]}))
    assert (d.header["net"], d.header["advances"]) == ("282000", "0")
    assert {ln.item.entry_id: ln.mandate_id for ln in d.lines}["A1"] == "M"
    assert not [s for s in d.plan.settles if s.kind == "advance"]


def test_an_advance_of_no_mandate_is_paid_gross_and_never_taken() -> None:
    """Founder Q2's default: an advance on no mandate (a run of several mandates, a client part) is
    recovered by a request only; its item is remitted gross outside every mandate's money."""
    d = prepare_run(_rv3(mandate=None))
    assert {ln.item.entry_id: ln.mandate_id for ln in d.lines}["A1"] is None
    assert not [s for s in d.plan.settles if s.kind == "advance"]
    gross = {m.mandate_id: m.gross_minor for m in d.plan.mandates}
    assert gross == {"": 200_000, "M": 100_000}
    assert d.header["net"] == "282000"


def test_an_advance_born_before_the_client_s_proceeding_is_not_set_off() -> None:
    """L622-7 I (the plan's nettable rule): an advance born before the opening is not taken; one
    born on or after it is (7d changes the rule)."""
    before = prepare_run(_rv3(proceeding_opened_on=date(2026, 11, 13)))
    assert (before.header["net"], before.header["advances"]) == ("282000", "0")
    same_day = prepare_run(_rv3(proceeding_opened_on=date(2026, 11, 12)))
    assert (same_day.header["net"], same_day.header["advances"]) == ("82000", "200000")


def test_advances_are_taken_oldest_first_within_their_mandate_s_room() -> None:
    """Two open advances of M (the older born first) and less room than both: the older is taken
    in full, the newer in part (N 0)."""
    older = OpenAdvanceRow(
        "A0", "M", "payout_overrun", date(2026, 11, 3), _at(date(2026, 11, 3)), 250_000
    )
    d = prepare_run(_rv3(open_advances=[_open("A1", "M", date(2026, 11, 12), 200_000), older]))
    taken = [(s.ref, s.amount_minor) for s in d.plan.settles if s.kind == "advance"]
    assert taken == [("A0", 250_000), ("A1", 32_000)]
    assert d.header["net"] == "0"


def test_an_advance_reversal_s_item_counts_in_its_advance_s_mandate() -> None:
    """A released cover (its entry reversed) re-queues -A: that item counts in the advance's
    mandate, as its +A did."""
    base = _rv3(open_advances=[])
    rev = replace(
        _advance_item("RA1", -200_000, date(2026, 11, 13), "M"),
        kind=LineKind.CLIENT_ADVANCE_REVERSAL,
    )
    d = prepare_run(replace(base, items=[*base.items, rev]))
    assert {ln.item.entry_id: ln.mandate_id for ln in d.lines}["RA1"] == "M"
    assert {m.mandate_id: m.gross_minor for m in d.plan.mandates} == {"M": 100_000}


def test_the_inputs_hash_names_the_open_advances() -> None:
    """An advance's open or mandate changed since the prepare changes the hash (the approval also
    re-reads its open: documents_changed)."""
    base = _rv3()
    h = prepare_run(base).header["inputs_hash"]
    less = [replace(base.open_advances[0], open_minor=150_000)]
    assert prepare_run(replace(base, open_advances=less)).header["inputs_hash"] != h
    other = [replace(base.open_advances[0], mandate_id="M2")]
    assert prepare_run(replace(base, open_advances=other)).header["inputs_hash"] != h
    # (even when the plan takes none of it: no claw-back clause, the same settles either way)
    plain = _rv3(terms={"M": [TERMS]})
    h = prepare_run(plain).header["inputs_hash"]
    less = [replace(plain.open_advances[0], open_minor=150_000)]
    assert prepare_run(replace(plain, open_advances=less)).header["inputs_hash"] != h


def test_advances_born_the_same_day_are_taken_in_the_order_they_were_recorded() -> None:
    """Two advances of M born on 12/11 (the one recorded first is taken first): the room left after
    the invoice (282 000) takes the first in full and the second in part."""
    first = OpenAdvanceRow(
        "A9", "M", "payout_overrun", date(2026, 11, 12), _at(date(2026, 11, 12), 9), 250_000
    )
    d = prepare_run(_rv3(open_advances=[_open("A1", "M", date(2026, 11, 12), 200_000), first]))
    taken = [(s.ref, s.amount_minor) for s in d.plan.settles if s.kind == "advance"]
    assert taken == [("A9", 250_000), ("A1", 32_000)]


# -- M2c-7b review round 1 (M7B-MONEY-1): each pair in one bucket ------------------------------
# A double payout's queue rows are its unplanned payout's -U (no file) and its advance's +(U - P):
# both count outside every mandate, so the advance (a document of its mandate M) is taken back only
# from M's own collections — never from another mandate's money, never from a re-queued payout. And
# what an unplanned payout of the run already paid of a line (its live attributions, the switch on)
# is no mandate's money any more: it counts with that payout's row.

NO_CLAUSE = {**NETTING, "netting": None}


def _terms(mandate: str, remittance_terms: dict[str, Any]) -> Terms:
    return Terms(
        f"T-{mandate}", mandate, date(2026, 1, 1), None, 30, SCHEDULE, remittance_terms, "art. 6",
        "art. 7",
    )  # fmt: skip


def _unplanned(entry: str, amount: int, day: date) -> Item:
    """An unplanned payout's -U row as the prepare loads it: no file, no payment."""
    return Item(entry, LineKind.UNPLANNED_PAYOUT, -amount, _at(day, 15), day)


def _double_payout_item(entry: str, amount: int, day: date, mandate: str | None) -> Item:
    """Its double_payout advance's +(U - P) row: no file, the advance's mandate and cause."""
    return Item(
        entry, LineKind.CLIENT_ADVANCE, amount, _at(day, 15), day, advance_mandate_id=mandate,
        advance_cause="double_payout",
    )  # fmt: skip


def _m_m2(items: list[Item], m_terms: dict[str, Any], m2_terms: dict[str, Any], **kw: Any) -> Facts:
    """Roux's two mandates: M (file F1) and M2 (file F2), each with its own terms; the double
    payout's advance V (50 000, born 20/11) open on M."""
    base: dict[str, Any] = {
        "today": date(2026, 11, 23),
        "files": {
            "F1": FileFacts("F1", "M", "b2b_invoice", "PF1"),
            "F2": FileFacts("F2", "M2", "b2b_invoice", "PF2"),
        },
        "mandate_refs": {"M": "MAND-ROUX-1", "M2": "MAND-ROUX-2"},
        "terms": {"M": [_terms("M", m_terms)], "M2": [_terms("M2", m2_terms)]},
        "open_advances": [
            OpenAdvanceRow(
                "V", "M", "double_payout", date(2026, 11, 20), _at(date(2026, 11, 20), 15), 50_000
            )
        ],
    }
    base.update(kw)
    return _facts(items, **base)


def _settled(d: Any) -> list[tuple[str, str, int]]:
    return [(s.ref, s.kind, s.amount_minor) for s in d.plan.settles]


def test_a_double_payout_s_advance_is_never_taken_from_another_mandate_s_money() -> None:
    """The review's M/M2 case: X's payout paid again, the bank executes X again (-50 000, no file;
    its advance V +50 000 on X's mandate M, claw-back art. 7.4); a new collection of 70 000 on M2
    (netting only). M brings no money of its own: V stays open, M2 sets off only its own invoice
    (12 600), N 57 400. With V's row in M (7b), M's room took V out of M2's collection (N 7 400)."""
    day = date(2026, 11, 20)
    items = [
        _unplanned("U", 50_000, day),
        _double_payout_item("V", 50_000, day, "M"),
        _alloc("E5", 70_000, date(2026, 11, 21), account="F2"),
    ]
    d = prepare_run(_m_m2(items, CLAWBACK, NETTING))
    h = d.header
    assert (h["gross"], h["advances"], h["taken"], h["net"]) == ("70000", "0", "12600", "57400")
    assert {ln.item.entry_id: ln.mandate_id for ln in d.lines}["V"] is None
    assert {m.mandate_id: m.gross_minor for m in d.plan.mandates} == {"": 0, "M2": 70_000}
    assert _settled(d) == [("new:M2", "compensation", 12_600)]


def test_a_double_payout_s_advance_is_never_taken_from_a_re_queued_payout() -> None:
    """The review's first variant: the client's only money a payout that came back (+60 000, no
    file, never netted: Q17's default) beside the double payout: V is not taken (N 60 000)."""
    day = date(2026, 11, 20)
    items = [
        Item("PR", LineKind.PAYOUT_RETURNED, 60_000, _at(day, 9), day),
        _unplanned("U", 50_000, day),
        _double_payout_item("V", 50_000, day, "M"),
    ]
    d = prepare_run(_m_m2(items, CLAWBACK, NETTING))
    assert (d.header["advances"], d.header["net"]) == ("0", "60000")
    assert not _settled(d)


def test_a_mandate_s_netting_never_reaches_another_mandate_s_money_through_a_double_payout() -> (
    None
):
    """The review's second variant: M with netting and no claw-back, an open invoice of M of
    40 000, the money on M2 only (no clause): M's invoice is not set off (N 70 000)."""
    day = date(2026, 11, 20)
    items = [
        _unplanned("U", 50_000, day),
        _double_payout_item("V", 50_000, day, "M"),
        _alloc("E5", 70_000, date(2026, 11, 21), account="F2"),
    ]
    invoice = OpenInvoiceRow(
        "FM", "M", "invoice", "FC-2026-000040", date(2026, 11, 2), (2026, 40), 40_000, 6_667
    )
    d = prepare_run(_m_m2(items, NETTING, NO_CLAUSE, open_documents=[invoice]))
    assert (d.header["taken"], d.header["advances"], d.header["net"]) == ("0", "0", "70000")
    assert not _settled(d)


def test_a_double_payout_s_advance_is_taken_from_its_own_mandate_s_collections() -> None:
    """The same double payout and a collection of 70 000 on M itself: V is taken from M's money
    under M's clause after M's own invoice (12 600): 50 000, N 7 400."""
    day = date(2026, 11, 20)
    items = [
        _unplanned("U", 50_000, day),
        _double_payout_item("V", 50_000, day, "M"),
        _alloc("E5", 70_000, date(2026, 11, 21), account="F1"),
    ]
    d = prepare_run(_m_m2(items, CLAWBACK, NETTING))
    assert (d.header["taken"], d.header["advances"], d.header["net"]) == ("12600", "50000", "7400")
    assert _settled(d) == [("new:M", "compensation", 12_600), ("V", "advance", 50_000)]


def test_an_overrun_advance_s_item_counts_outside_every_mandate() -> None:
    """A payout_overrun advance's +A row pairs with whatever left 4670 in debit (no file of it by
    construction): outside every mandate, as a double payout's; only a remitted reversal's cover
    pairs with its reversal on the cover's mandate."""
    day = date(2026, 11, 20)
    over = replace(_double_payout_item("O", 30_000, day, "M"), advance_cause="payout_overrun")
    d = prepare_run(_m_m2([over], CLAWBACK, NETTING, open_advances=[]))
    assert {ln.item.entry_id: ln.mandate_id for ln in d.lines}["O"] is None
    assert {m.mandate_id: m.gross_minor for m in d.plan.mandates} == {"": 30_000}


def test_what_an_unplanned_payout_paid_of_a_line_is_no_mandate_s_money() -> None:
    """The switch on: a run cancelled after download released E1 (100 000 on M), the bank executed
    its payout late (U -82 000, which paid 82 000 of E1: its attribution); a new collection of
    70 000 on M2 (no clause); M's claw-back and an advance of 50 000 open on M. What U paid is the
    client's already: M's money is 18 000, which its own invoice takes (18 000); the advance is not
    taken from M2's collection (N 70 000). Without the attribution M's room was 100 000 (N
    20 000)."""
    day = date(2026, 11, 20)
    items = [
        _alloc("E1", 100_000, date(2026, 11, 10), account="F1"),
        _unplanned("U", 82_000, day),
        _alloc("E5", 70_000, date(2026, 11, 21), account="F2"),
    ]
    v = OpenAdvanceRow(
        "V", "M", "payout_overrun", date(2026, 11, 3), _at(date(2026, 11, 3)), 50_000
    )
    d = prepare_run(
        _m_m2(items, CLAWBACK, NO_CLAUSE, open_advances=[v],
              unplanned_paid=[UnplannedPaid("U", "E1", 82_000)])
    )  # fmt: skip
    h = d.header
    assert (h["taken"], h["advances"], h["net"]) == ("18000", "0", "70000")
    assert {m.mandate_id: m.gross_minor for m in d.plan.mandates} == {
        "": 0,
        "M": 18_000,
        "M2": 70_000,
    }
    # an attribution of a booking that is not a line of this run moves nothing
    other = prepare_run(
        _m_m2(items, CLAWBACK, NO_CLAUSE, open_advances=[v],
              unplanned_paid=[UnplannedPaid("U-old", "E1", 82_000)])
    )  # fmt: skip
    assert {m.mandate_id: m.gross_minor for m in other.plan.mandates}["M"] == 100_000
