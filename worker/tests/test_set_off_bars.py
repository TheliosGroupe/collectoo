"""M2c-7d-2 « set-off bars » (plan docs/design/m2c-7-plan.md §6.2.4 to §6.2.6, §6.2.11 (a) 8 and 8b,
§6.4; ADR-0014 « M2c-7d-2 »): what the run's plan may set off, and the run's own invoice, once the
client's status is read — the opening (a liquidation recorded alone opens it), each claim's birth
(never its issue date), the bars per kind (liquidation, mandate end, a standing seizure, an advance
while a proceeding stands); the withheld settlement's queue item; the schedule's trigger. Every rule
the law does not fix is the servicer's default (founder Q9, Q11, Q12, Q18, Q19; OQ-41, OQ-92)."""

from __future__ import annotations

from dataclasses import replace
from datetime import date, timedelta
from typing import Any

from document_cases import invoice_payload
from hypothesis import given, settings
from hypothesis import strategies as st
from test_remittance_run import (
    NETTING,
    TERMS,
    TERMS_CLAW,
    _advance_item,
    _alloc,
    _at,
    _facts,
    _open,
    _rv3,
)

from collectoo_worker.jobs.remittances import _schedule_trigger
from collectoo_worker.remittance.calendar import conservative
from collectoo_worker.remittance.commission import NEVER_COMMISSIONED, LineKind
from collectoo_worker.remittance.invoice import InvoiceDocument, _payment_line
from collectoo_worker.remittance.run import (
    Item,
    OpenInvoiceRow,
    PendingLine,
    SetOffBar,
    prepare_run,
)
from collectoo_worker.remittance.settlement import NO_MANDATE
from collectoo_worker.remittance.statement import NATURE

OPENING = date(2026, 10, 15)
TODAY = date(2026, 11, 16)


def _inv(
    ref: str, born: date, open_minor: int = 12_000, issued: date | None = None
) -> OpenInvoiceRow:
    return OpenInvoiceRow(
        ref,
        "M",
        "invoice",
        f"FC-2026-{ref}",
        issued or date(2026, 10, 20),
        (2026, int(ref[-2:]) if ref[-2:].isdigit() else 1),
        open_minor,
        open_minor // 6,
        born_on=born,
    )


def _bars(invoice: str | None, advance: str | None, since: date = OPENING) -> dict[str, SetOffBar]:
    out = {}
    if invoice:
        out["invoice"] = SetOffBar(invoice, since)
    if advance:
        out["advance"] = SetOffBar(advance, since)
    return out


def _settled(d: Any) -> list[tuple[str, str]]:
    return [(s.ref, s.kind) for s in d.plan.settles]


def _new_invoice(d: Any) -> dict[str, Any]:
    return next(x for x in d.documents if x["kind"] == "invoice")


# -- the birth, not the issue date (§6.2.4 to §6.2.5; LEX-07 (1))
# ---------------------------------------------------


def test_an_invoice_issued_after_the_opening_for_collections_before_it_is_not_set_off() -> None:
    """FC10 issued 20/10, after the opening of 15/10, charges collections of 01/10: born before it,
    never set off (the old criterion — the issue date — would net it); FC11 born 16/10 is set
    off."""
    facts = _facts(
        [_alloc("E1", 100_000, date(2026, 11, 2))],
        open_documents=[_inv("FC10", date(2026, 10, 1)), _inv("FC11", date(2026, 10, 16))],
        proceeding_opened_on=OPENING,
        set_off_bars=_bars(None, "proceeding"),
        set_off_state="-/proceeding",
    )
    d = prepare_run(facts)
    assert ("FC10", "compensation") not in _settled(d)
    assert ("FC11", "compensation") in _settled(d)


def test_without_a_birth_the_issue_date_stands_in() -> None:
    """A row the facts carry no birth for (no opening: the prepare reads none) is born at its
    issue."""
    row = replace(_inv("FC12", date(2026, 10, 1)), born_on=None)
    assert row.born == row.issue_date


# -- the bars (§6.2.6)
# --------------------------------------------------------------------------------------------


def test_in_liquidation_nothing_is_set_off_and_credit_notes_still_apply() -> None:
    """Founder Q11 (a): no invoice and no advance set off, before or after the judgment; the run's
    credit note still corrects the invoice it rectifies (a price correction, not a set-off)."""
    base = prepare_run(_rv3())
    assert base.plan.applications
    d = prepare_run(
        _rv3(
            open_documents=[_inv("FC11", date(2026, 11, 1))],
            proceeding_opened_on=date(2026, 10, 1),
            set_off_bars=_bars("liquidation", "liquidation", date(2026, 10, 1)),
            set_off_state="liquidation/liquidation",
        )
    )
    assert [
        s for s in d.plan.settles if s.kind in ("compensation", "advance") and s.amount_minor
    ] == []
    assert d.plan.applications == base.plan.applications
    assert d.header["advances"] == "0"


def test_after_a_mandate_end_nothing_is_set_off_and_the_new_invoice_is_due_with_its_term() -> None:
    """Founder Q9 (a): the netting and claw-back clauses belonged to the mandate that ended; the
    run's invoice is due to the own account with the terms' L441-10 term, its ordinary payment
    line."""
    d = prepare_run(
        _rv3(
            open_documents=[_inv("FC11", date(2026, 11, 1))],
            set_off_bars=_bars("mandate_ended", "mandate_ended", date(2026, 11, 3)),
            set_off_state="mandate_ended/mandate_ended",
        )
    )
    assert [
        s for s in d.plan.settles if s.kind in ("compensation", "advance") and s.amount_minor
    ] == []
    inv = _new_invoice(d)
    assert (inv["settlement"], inv["due_days"], inv.get("payment_note")) == ("due", 30, None)


def test_under_a_seizure_nothing_is_set_off_and_the_invoice_says_why() -> None:
    """[critic] L14 (founder Q12 a): while a seizure stands nothing is set off; the run's invoice is
    due with « Compensation suspendue : saisie entre les mains du cabinet du JJ/MM/AAAA. » before
    its ordinary payment line."""
    d = prepare_run(
        _facts(
            [_alloc("E1", 100_000, date(2026, 11, 2))],
            open_documents=[_inv("FC11", date(2026, 11, 1))],
            set_off_bars=_bars("seizure", "seizure", date(2026, 11, 1)),
            set_off_state="seizure/seizure",
        )
    )
    assert [s.ref for s in d.plan.settles if s.amount_minor] == []
    inv = _new_invoice(d)
    assert inv["settlement"] == "due"
    assert inv["payment_note"] == {
        "text": "Compensation suspendue : saisie entre les mains du cabinet du 01/11/2026.",
        "pay": True,
    }


def test_in_a_proceeding_no_advance_is_taken_and_post_opening_invoices_are() -> None:
    """[critic] L4 (founder Q18 a): while a proceeding stands no advance is taken, born after the
    opening too (L622-7 I al. 1, second sentence; OQ-92); an invoice born after the opening stays
    nettable."""
    facts = _rv3(
        open_documents=[_inv("FC11", date(2026, 11, 1), 10_000)],
        proceeding_opened_on=date(2026, 11, 1),
        set_off_bars=_bars(None, "proceeding", date(2026, 11, 1)),
        set_off_state="-/proceeding",
    )
    d = prepare_run(facts)
    assert d.header["advances"] == "0"
    assert ("FC11", "compensation") in _settled(d)
    assert ("A1", "advance") not in _settled(d)
    # the same facts without the bar take the advance (born 12/11, after the opening)
    assert prepare_run(replace(facts, set_off_bars={})).header["advances"] == "200000"


def test_the_run_s_own_invoice_born_before_the_opening_is_due_with_the_procedure_line() -> None:
    """[critic] L1: the run's new invoice charges collections of 02/11, before the opening of 05/11:
    born then, it is not set off — due, its payment line the procedure's (never « par compensation
    »); born after an opening of 15/10 it is netted as before."""
    item = _alloc("E1", 100_000, date(2026, 11, 2))
    late = prepare_run(
        _facts(
            [item],
            today=TODAY,
            proceeding_opened_on=date(2026, 11, 5),
            set_off_bars=_bars(None, "proceeding", date(2026, 11, 5)),
            set_off_state="-/proceeding",
        )
    )
    inv = _new_invoice(late)
    assert inv["settlement"] == "due"
    assert inv["payment_note"] == {
        "text": (
            "Créance née avant l'ouverture de la procédure collective du client (jugement du "
            "05/11/2026) : à déclarer au mandataire judiciaire (au liquidateur en liquidation) ; "
            "ni payée ni compensée hors de la procédure."
        ),
        "pay": False,
    }
    assert late.header["taken"] == "0" and late.header["net"] == "100000"
    early = prepare_run(
        _facts(
            [item],
            today=TODAY,
            proceeding_opened_on=OPENING,
            set_off_bars=_bars(None, "proceeding"),
            set_off_state="-/proceeding",
        )
    )
    assert _new_invoice(early)["settlement"] == "netted"
    assert early.header["taken"] == "18000"


def test_the_run_s_own_invoice_is_born_at_the_earliest_line_it_reprices_too() -> None:
    """Review round 1 (MLAW-1; plan §6.2.4 [critic] L1, OQ-92): the run's own invoice also charges
    an earlier run's line left pending (E0, collected 20/10) that it reprices — born then, as
    private.document_born_on counts it (the repriced lines by remittance_line_repricing), not at
    this run's own collection (02/11). Before an opening of 25/10 it is due with the procedure's
    payment line and nothing of it is set off; without E0 it is born 02/11 and netted."""
    opening = date(2026, 10, 25)
    kw: dict[str, Any] = {
        "proceeding_opened_on": opening,
        "set_off_bars": _bars(None, "proceeding", opening),
        "set_off_state": "-/proceeding",
    }
    now = _alloc("E1", 10_000, date(2026, 11, 2))
    earlier = PendingLine("RUN-0", 1, _alloc("E0", 100_000, date(2026, 10, 20)))
    d = prepare_run(_facts([now], pending_lines=[earlier], **kw))
    ((pl, _lc, invoiced),) = d.repricing
    assert (pl.item.entry_id, invoiced) == ("E0", True)
    inv = _new_invoice(d)
    assert (inv["settlement"], inv["due_days"]) == ("due", 30)
    assert inv["payment_note"]["pay"] is False
    assert inv["payment_note"]["text"].startswith(
        "Créance née avant l'ouverture de la procédure collective du client "
        "(jugement du 25/10/2026)"
    )
    assert [s for s in d.plan.settles if s.ref == "new:M" and s.amount_minor] == []
    assert (d.header["taken"], d.header["net"]) == ("0", "10000")
    alone = prepare_run(_facts([now], **kw))
    assert _new_invoice(alone)["settlement"] == "netted"
    assert alone.header["taken"] != "0"


def test_a_seizure_or_a_liquidation_on_a_mandate_without_netting_says_no_compensation() -> None:
    """Review round 1 (TUI-9): a mandate with no netting clause never sets its invoice off, so its
    invoice carries no « Compensation suspendue » and no « non compensée » wording — only what the
    procedure changes (the liquidator's rights); with the clause the notes stand."""
    no_net = replace(TERMS, remittance_terms={**NETTING, "netting": None})
    item = _alloc("E1", 100_000, date(2026, 11, 2))
    seized = prepare_run(
        _facts(
            [item],
            terms={"M": [no_net]},
            set_off_bars=_bars("seizure", "seizure", date(2026, 11, 1)),
            set_off_state="seizure/seizure",
        )
    )
    inv = _new_invoice(seized)
    assert (inv["settlement"], inv.get("payment_note")) == ("due", None)
    liq = _new_invoice(
        prepare_run(
            _facts(
                [item],
                terms={"M": [no_net]},
                proceeding_opened_on=OPENING,
                set_off_bars=_bars("liquidation", "liquidation"),
                set_off_state="liquidation/liquidation",
            )
        )
    )
    assert liq["settlement"] == "due"
    assert liq["payment_note"]["pay"] is False
    assert "compens" not in liq["payment_note"]["text"]
    assert liq["payment_note"]["text"].startswith(
        "Client en liquidation judiciaire (jugement du 15/10/2026)"
    )
    # a claim born before the opening is to declare whatever the clause
    before = _new_invoice(
        prepare_run(
            _facts(
                [item],
                terms={"M": [no_net]},
                proceeding_opened_on=date(2026, 11, 5),
                set_off_bars=_bars(None, "proceeding", date(2026, 11, 5)),
                set_off_state="-/proceeding",
            )
        )
    )
    assert before["payment_note"]["text"].startswith("Créance née avant l'ouverture")


def test_a_liquidation_s_own_invoice_born_after_the_judgment_says_so() -> None:
    """In liquidation an invoice born after the judgment is not set off either (founder Q11): its
    payment line says why, never « née avant »."""
    d = prepare_run(
        _facts(
            [_alloc("E1", 100_000, date(2026, 11, 2))],
            proceeding_opened_on=OPENING,
            set_off_bars=_bars("liquidation", "liquidation"),
            set_off_state="liquidation/liquidation",
        )
    )
    note = _new_invoice(d)["payment_note"]
    assert note["pay"] is False
    assert note["text"].startswith("Client en liquidation judiciaire (jugement du 15/10/2026)")
    assert "née avant" not in note["text"]


def test_the_draft_records_the_opening_and_the_bars_it_assumed() -> None:
    """What the approval and the hold before download compare (§6.2.9, §6.2.11 (b))."""
    plain = prepare_run(_facts([_alloc("E1", 100_000, date(2026, 11, 2))]))
    assert (plain.header["opening_on"], plain.header["set_off_barred"]) == (None, None)
    held = prepare_run(
        _facts(
            [_alloc("E1", 100_000, date(2026, 11, 2))],
            proceeding_opened_on=OPENING,
            set_off_bars=_bars(None, "proceeding"),
            set_off_state="-/proceeding",
        )
    )
    assert (held.header["opening_on"], held.header["proceeding_opened_on"]) == (OPENING, OPENING)
    assert held.header["set_off_barred"] == "-/proceeding"
    assert held.header["inputs_hash"] != plain.header["inputs_hash"]


def test_the_inputs_hash_of_a_draft_without_a_bar_is_unchanged_by_the_bars_fields() -> None:
    """The hash names the bars only when the client has some (drafts of other clients keep
    theirs)."""
    facts = _facts([_alloc("E1", 100_000, date(2026, 11, 2))])
    assert (
        prepare_run(facts).header["inputs_hash"]
        == prepare_run(replace(facts, set_off_bars={}, set_off_state=None)).header["inputs_hash"]
    )


# -- the withheld settlement's item (§6.2.11 (a) 8)
# ------------------------------------------------------------------


def _withheld(entry: str, amount: int, e: date) -> Item:
    return Item(
        entry_id=entry,
        kind=LineKind.SETTLEMENT_WITHHELD,
        amount_minor=amount,
        posted_at=_at(TODAY, 9),
        effective_date=TODAY - timedelta(days=1),
        encaissement_date=e,
        held_terms_id="T1",
        held_days=30,
    )


def test_a_withheld_settlement_is_paid_outside_every_mandate_without_commission() -> None:
    """Like a returned payout: no file, no commission, outside every mandate's gross (never netted),
    held to the R124-6 date of the run it was withheld from (its E and that line's delay)."""
    assert LineKind.SETTLEMENT_WITHHELD in NEVER_COMMISSIONED
    w = _withheld("W1", 30_000, date(2026, 10, 20))
    d = prepare_run(
        _facts(
            [_alloc("E1", 10_000, date(2026, 11, 2)), w],
            today=TODAY,
            open_documents=[_inv("FC11", date(2026, 11, 1), 50_000)],
        )
    )
    line = next(x for x in d.lines if x.item.entry_id == "W1")
    assert (line.mandate_id, line.commission_minor, line.state, line.terms_id) == (
        None,
        0,
        "none",
        "T1",
    )
    assert line.deadline is not None
    plain = prepare_run(_facts([_alloc("E9", 1, date(2026, 10, 20))], today=TODAY)).lines[0]
    assert plain.deadline is not None
    assert line.deadline.deadline == plain.deadline.deadline
    gross = {m.mandate_id: m.gross_minor for m in d.plan.mandates}
    assert gross[NO_MANDATE] == 30_000
    # FC11 is set off only from M's own money (E1's 10 000 less its own invoice): never from W
    taken = sum(s.amount_minor for s in d.plan.settles if s.ref == "FC11")
    assert taken <= 10_000


# -- the schedule (§6.2.11 (a) 8b, [check 2] gap 3)
# ------------------------------------------------------------------


SATURDAY = date(2026, 11, 21)
MONDAY = date(2026, 11, 23)


def test_a_withheld_item_alone_makes_a_draft_at_the_next_hour_on_any_day() -> None:
    cal = conservative()
    assert _schedule_trigger([], False, True, [], SATURDAY, cal.is_business_day(SATURDAY), cal) == (
        "settlement_withheld"
    )
    assert _schedule_trigger([], True, True, [], SATURDAY, False, cal) == "payout_returned"
    assert _schedule_trigger([], False, False, [], SATURDAY, False, cal) is None
    assert _schedule_trigger(
        [dict(TERMS.remittance_terms or {})], False, False, [], MONDAY, True, cal
    ) in (
        None,
        "schedule",
    )


@settings(max_examples=200, deadline=None)
@given(
    returned=st.booleans(),
    withheld=st.booleans(),
    day=st.dates(min_value=date(2026, 3, 1), max_value=date(2030, 12, 31)),
    latest=st.lists(st.dates(min_value=date(2026, 3, 1), max_value=date(2031, 3, 1)), max_size=4),
)
def test_the_schedule_s_trigger_ranks_a_returned_payout_then_a_withheld_settlement(
    returned: bool, withheld: bool, day: date, latest: list[date]
) -> None:
    """The scheduler's property, extended with the flag: a returned payout first, then a withheld
    settlement — either makes a draft whatever the day (a business day is not required)."""
    cal = conservative()
    t = _schedule_trigger(
        [dict(TERMS_CLAW.remittance_terms or {})],
        returned,
        withheld,
        latest,
        day,
        cal.is_business_day(day),
        cal,
    )
    if returned:
        assert t == "payout_returned"
    elif withheld:
        assert t == "settlement_withheld"
    else:
        assert t in (None, "schedule", "deadline")


# -- texts ----------------------------------------------------------------------------------------


def test_the_statement_names_a_withheld_settlement_given_back() -> None:
    assert NATURE["settlement_withheld"] == "Compensation retenue au débit, rendue"


def test_an_invoice_s_payment_note_replaces_or_precedes_its_payment_line() -> None:
    due = invoice_payload(
        settlement={"mode": "due", "clause_ref": None, "due_days": 30},
        due_date="2026-12-02",
        payment_reference=None,
        own_account={"iban": "FR7610107001011234567890129", "bic": None, "holder": "Collectoo SAS"},
    )
    doc = InvoiceDocument("FC-1", "invoice", date(2026, 11, 2), due, {})
    plain = _payment_line(doc)
    assert plain.startswith("À régler au plus tard le 02/12/2026")
    procedure = {"text": "Créance née avant l'ouverture … hors de la procédure.", "pay": False}
    doc2 = InvoiceDocument(
        "FC-1", "invoice", date(2026, 11, 2), {**due, "payment_note": procedure}, {}
    )
    assert _payment_line(doc2) == procedure["text"]
    seizure = {
        "text": "Compensation suspendue : saisie entre les mains du cabinet du 01/11/2026.",
        "pay": True,
    }
    doc3 = InvoiceDocument(
        "FC-1", "invoice", date(2026, 11, 2), {**due, "payment_note": seizure}, {}
    )
    assert _payment_line(doc3) == f"{seizure['text']} {plain}"


# -- the plan's property with bars (Hypothesis)
# ------------------------------------------------------------------------


DAY0 = date(2026, 10, 1)


@settings(max_examples=300, deadline=None)
@given(
    opening=st.one_of(st.none(), st.integers(0, 40)),
    invoice_bar=st.sampled_from([None, "liquidation", "mandate_ended", "seizure"]),
    advance_bar=st.sampled_from([None, "liquidation", "mandate_ended", "seizure", "proceeding"]),
    invoices=st.lists(st.tuples(st.integers(0, 45), st.integers(1, 50_000)), max_size=4),
    advances=st.lists(st.tuples(st.integers(30, 45), st.integers(1, 50_000)), max_size=3),
    collected=st.integers(0, 45),
    amount=st.integers(1_000, 400_000),
    pending=st.lists(st.tuples(st.integers(0, 45), st.integers(1_000, 100_000)), max_size=2),
)
def test_nothing_barred_is_ever_set_off(  # noqa: PLR0913, PLR0917 - the facts drawn
    opening: int | None,
    invoice_bar: str | None,
    advance_bar: str | None,
    invoices: list[tuple[int, int]],
    advances: list[tuple[int, int]],
    collected: int,
    amount: int,
    pending: list[tuple[int, int]],
) -> None:
    """For any opening, bars, earlier invoices (born any day), advances, collection and earlier
    runs' lines left pending (review round 1, MLAW-1: repriced onto the run's own invoice): no
    settle sets off a barred document (document_nettable: no bar for its kind, and born on or after
    the opening), the run's own invoice included — born at the earliest collection it charges,
    its repriced lines' included; N + D = gross; and (review round 1, TUI-5) with no bar and no
    opening the plan does not depend on the claims' births (7d-1's plan, every invoice born at its
    issue)."""
    open_on = None if opening is None else DAY0 + timedelta(days=opening)
    bars = _bars(invoice_bar, None, open_on or DAY0) | (
        {"advance": SetOffBar(advance_bar, open_on or DAY0)} if advance_bar else {}
    )
    if open_on is not None and advance_bar is None:
        bars["advance"] = SetOffBar("proceeding", open_on)  # SQL's: an opening bars every advance
    rows = [_inv(f"FC{i:02d}", DAY0 + timedelta(days=b), o) for i, (b, o) in enumerate(invoices)]
    adv = [_open(f"A{i}", "M", DAY0 + timedelta(days=b), o) for i, (b, o) in enumerate(advances)]
    e = DAY0 + timedelta(days=collected)
    earlier = [
        PendingLine("RUN-0", i + 1, _alloc(f"P{i}", a, DAY0 + timedelta(days=c), f"F{i}"))
        for i, (c, a) in enumerate(pending)
    ]
    facts = _facts(
        [_alloc("E1", amount, e), _advance_item("AI0", 1, e, "M")],
        today=TODAY,
        terms={"M": [TERMS_CLAW]},
        open_documents=rows,
        open_advances=adv,
        proceeding_opened_on=open_on,
        set_off_bars=bars,
        set_off_state=None if not bars else "x",
        pending_lines=earlier,
        accounts=[p.item.account_id for p in earlier],
    )
    d = prepare_run(facts)
    # the run's own invoice: born at the earliest collection it charges, this run's lines and the
    # earlier runs' lines it reprices (as the approval and document_born_on read them)
    charged = [ln.item.encaissement_date for ln in d.lines if ln.invoiced] + [
        p.item.encaissement_date for p, _lc, inv in d.repricing if inv
    ]
    own = min((c for c in charged if c is not None), default=e)
    born = {r.id: r.born for r in rows} | {a.id: a.born_on for a in adv}
    for s in d.plan.settles:
        if s.kind not in ("compensation", "advance") or not s.amount_minor:
            continue
        kind = "advance" if s.kind == "advance" else "invoice"
        assert kind not in bars, (s, bars)
        b = born.get(s.ref, own)
        assert open_on is None or b >= open_on, (s, open_on, b)
    assert d.plan.net_minor + d.plan.settlement_minor == d.plan.gross_minor
    if not bars and open_on is None:
        issued = replace(facts, open_documents=[replace(r, born_on=None) for r in rows])
        assert d.plan == prepare_run(issued).plan
