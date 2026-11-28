"""The settlement plan of a run (design §9.6, §7.2 worked example; founder #3, #7): the worked
example's runs RV-1 … RV-3 and its variants, then Hypothesis properties — N + D = gross; nothing
taken without its clause; every settled part within its document's open part, VAT moved within its
pending VAT and all of it when the document closes; N ≥ 0 whenever the client's money allows it;
a credit note applied within the invoice's open part, its VAT off the pending part first."""

from __future__ import annotations

from collections import defaultdict
from datetime import UTC, date, datetime
from decimal import Decimal

from hypothesis import given, settings
from hypothesis import strategies as st

from collectoo_worker.remittance.commission import FileFacts, LineKind
from collectoo_worker.remittance.run import (
    Facts,
    Item,
    OpenAdvanceRow,
    Terms,
    UnplannedPaid,
    prepare_run,
)
from collectoo_worker.remittance.settlement import (
    NO_MANDATE,
    Clauses,
    OpenDocument,
    RunCredit,
    check,
    new_credit_note_ref,
    new_invoice_ref,
    plan,
)

NET_CLAW = Clauses(netting=True, clawback=True)
NET_ONLY = Clauses(netting=True, clawback=False)
NEITHER = Clauses(netting=False, clawback=False)
LATE = (1 << 30,)  # the run's own invoice: after every earlier document


def _new_invoice(mandate: str, ttc: int, vat: int) -> OpenDocument:
    return OpenDocument(new_invoice_ref(mandate), mandate, LATE, ttc, vat)


def test_rv1_and_rv2_of_the_worked_example() -> None:
    """RV-1 Martin: 200 000 collected, FC-1 36 000 TTC netted → N 164 000, D 36 000, its VAT
    6 000 due at the debit. RV-2 Lilas: 512 000, FC-2 60 864 TTC → N 451 136."""
    p = plan({"M": 200_000}, [_new_invoice("M", 36_000, 6_000)], [], [], [], {"M": NET_ONLY})
    check(p)
    assert (p.net_minor, p.settlement_minor, p.vat_moved_minor) == (164_000, 36_000, 6_000)
    assert [(s.ref, s.kind, s.amount_minor, s.vat_moved_minor) for s in p.settles] == [
        ("new:M", "compensation", 36_000, 6_000)
    ]
    p = plan({"L": 512_000}, [_new_invoice("L", 60_864, 10_144)], [], [], [], {"L": NET_ONLY})
    assert (p.net_minor, p.settlement_minor, p.vat_moved_minor) == (451_136, 60_864, 10_144)


def test_rv3_credit_note_on_a_settled_invoice_and_the_advance() -> None:
    """RV-3 Martin: gross 300 000 (E10 +300 000, R(E2) -200 000, A1 +200 000); FC-3 54 000 TTC;
    FC-4 credits FC-1 (settled: open 0) by 36 000 TTC of which 6 000 VAT, all off the VAT already
    due; the claw-back clause takes the 200 000 advance: N 82 000, D 218 000 (Dc 18 000, Da
    200 000), FC-3's 9 000 VAT moved."""
    fc1 = OpenDocument("FC-1", "M", (2026, 1), 0, 0)
    adv = OpenDocument("A1", "M", (2026, 11), 200_000)
    credit = RunCredit(new_credit_note_ref("M"), "FC-1", "M", 36_000, 6_000)
    p = plan(
        {"M": 300_000},
        [fc1, _new_invoice("M", 54_000, 9_000)],
        [],
        [adv],
        [credit],
        {"M": NET_CLAW},
    )
    check(p)
    assert (p.net_minor, p.settlement_minor) == (82_000, 218_000)
    assert (p.commission_settled_minor, p.advances_taken_minor) == (18_000, 200_000)
    assert p.vat_moved_minor == 9_000
    (app,) = p.applications
    assert (app.applied_minor, app.excess_minor) == (0, 36_000)
    assert (app.vat_pending_minor, app.vat_collected_minor) == (0, 6_000)
    kinds = sorted((s.ref, s.kind, s.amount_minor) for s in p.settles)
    assert kinds == [
        ("A1", "advance", 200_000),
        ("new:M", "compensation", 54_000),
        ("new_cn:M", "refund", 36_000),
    ]


def test_variants_without_claw_back_and_without_netting() -> None:
    """§7.3: without the claw-back clause the advance stays open (N 282 000); without the netting
    clause the gross is remitted and the invoice stays due (N 200 000, nothing settled)."""
    fc1 = OpenDocument("FC-1", "M", (2026, 1), 0, 0)
    adv = OpenDocument("A1", "M", (2026, 11), 200_000)
    credit = RunCredit(new_credit_note_ref("M"), "FC-1", "M", 36_000, 6_000)
    p = plan(
        {"M": 300_000},
        [fc1, _new_invoice("M", 54_000, 9_000)],
        [],
        [adv],
        [credit],
        {"M": NET_ONLY},
    )
    assert (p.net_minor, p.settlement_minor) == (282_000, 18_000)
    p = plan({"M": 200_000}, [_new_invoice("M", 36_000, 6_000)], [], [], [], {"M": NEITHER})
    assert (p.net_minor, p.settlement_minor, p.settles) == (200_000, 0, ())


def test_a_credit_on_an_open_invoice_takes_its_pending_vat() -> None:
    """A credit note on an invoice not settled yet is a price correction: it takes 18 000 off
    the 36 000 still open and 3 000 off its 6 000 pending VAT; the rest is then netted."""
    fc1 = OpenDocument("FC-1", "M", (2026, 1), 36_000, 6_000)
    credit = RunCredit(new_credit_note_ref("M"), "FC-1", "M", 18_000, 3_000)
    p = plan({"M": 100_000}, [fc1], [], [], [credit], {"M": NET_ONLY})
    (app,) = p.applications
    assert (app.applied_minor, app.excess_minor, app.vat_pending_minor) == (18_000, 0, 3_000)
    assert [(s.ref, s.amount_minor, s.vat_moved_minor) for s in p.settles] == [
        ("FC-1", 18_000, 3_000)
    ]
    assert (p.net_minor, p.settlement_minor) == (82_000, 18_000)


def test_a_take_in_part_moves_its_vat_pro_rata() -> None:
    """(M2c-7f-2, X1's « VAT pro rata off ») An earlier invoice, 36 000 TTC with 6 000 VAT pending,
    met by a gross of 10 000: 10 000 is taken and R(6 000 x 10 000 / 36 000) = 1 667 of its VAT
    moves to due — not the 6 000, which moves only with the part that closes it."""
    fc1 = OpenDocument("FC-1", "M", (2026, 1), 36_000, 6_000)
    p = plan({"M": 10_000}, [fc1], [], [], [], {"M": NET_ONLY})
    check(p)
    assert [(s.ref, s.amount_minor, s.vat_moved_minor) for s in p.settles] == [
        ("FC-1", 10_000, 1_667)
    ]
    assert (p.net_minor, p.settlement_minor, p.vat_moved_minor) == (0, 10_000, 1_667)


def test_nothing_to_settle_through_client_money_is_deferred() -> None:
    """A refund owed equal to the invoice it would compensate: D = 0 and no entry could move the
    VAT, so nothing is settled this run (N = gross); the credit note still applies."""
    fc1 = OpenDocument("FC-1", "M", (2026, 1), 0, 0)
    credit = RunCredit(new_credit_note_ref("M"), "FC-1", "M", 12_000, 2_000)
    p = plan({"M": 0}, [fc1, _new_invoice("M", 12_000, 2_000)], [], [], [credit], {"M": NET_ONLY})
    assert p.deferred
    assert (p.net_minor, p.settlement_minor, p.settles) == (0, 0, ())
    assert len(p.applications) == 1


def test_a_mandate_in_reversal_draws_on_the_clients_other_money() -> None:
    """Mandate A's reversals exceed its collections; B's commission is taken only as far as the
    client's money allows (N never below 0)."""
    p = plan(
        {"A": -100, "B": 100},
        [_new_invoice("B", 100, 0)],
        [],
        [],
        [],
        {"A": NET_ONLY, "B": NET_ONLY},
    )
    check(p)
    assert (p.net_minor, p.settlement_minor) == (0, 0)
    assert p.blockers == ()


# -- properties -----------------------------------------------------------------------------------

MANDATES = ("A", "B", NO_MANDATE)


@st.composite
def worlds(draw: st.DrawFn) -> dict[str, object]:
    mandates = draw(st.lists(st.sampled_from(MANDATES), min_size=1, max_size=3, unique=True))
    gross = {m: draw(st.integers(-50_000, 500_000)) for m in mandates}
    invoices = []
    for n in range(draw(st.integers(0, 5))):
        m = draw(st.sampled_from(("A", "B")))
        ttc = draw(st.integers(0, 100_000))
        vat = draw(st.integers(0, ttc // 5)) if ttc else draw(st.integers(0, 2))
        invoices.append(OpenDocument(f"I{n}", m, (2026, n), ttc, vat))
    for m in ("A", "B"):
        if draw(st.booleans()):
            ttc = draw(st.integers(1, 100_000))
            invoices.append(_new_invoice(m, ttc, ttc // 6))
    credits = []
    for n, inv in enumerate(invoices):
        if inv.ref.startswith("I") and draw(st.booleans()):
            ttc = draw(st.integers(0, 120_000))
            credits.append(
                RunCredit(new_credit_note_ref(inv.mandate_id), inv.ref, inv.mandate_id, ttc,
                          draw(st.integers(0, ttc // 5)))
            )  # fmt: skip
        del n
    refunds = [
        OpenDocument(f"R{n}", draw(st.sampled_from(("A", "B"))), (2026, 50 + n),
                     draw(st.integers(1, 30_000)))
        for n in range(draw(st.integers(0, 2)))
    ]  # fmt: skip
    advances = [
        OpenDocument(f"V{n}", draw(st.sampled_from(("A", "B"))), (2026, 80 + n),
                     draw(st.integers(1, 300_000)))
        for n in range(draw(st.integers(0, 2)))
    ]  # fmt: skip
    clauses = {
        m: Clauses(netting=draw(st.booleans()), clawback=draw(st.booleans())) for m in ("A", "B")
    }
    return {
        "gross": gross,
        "invoices": invoices,
        "refunds": refunds,
        "advances": advances,
        "credits": credits,
        "clauses": clauses,
    }


@settings(max_examples=1000, deadline=None)
@given(w=worlds())
def test_the_plan_holds_its_invariants(w: dict[str, object]) -> None:
    gross = w["gross"]
    invoices = w["invoices"]
    clauses = w["clauses"]
    assert isinstance(gross, dict)
    assert isinstance(invoices, list)
    assert isinstance(clauses, dict)
    p = plan(gross, invoices, w["refunds"], w["advances"], w["credits"], clauses)  # type: ignore[arg-type]
    check(p)
    assert p.net_minor + p.settlement_minor == p.gross_minor == sum(gross.values())
    assert p.settlement_minor == (
        p.commission_taken_minor + p.advances_taken_minor - p.refunds_paid_minor
    )
    by_ref = {d.ref: d for d in invoices}
    applied: dict[str, int] = defaultdict(int)
    taken_vat: dict[str, int] = defaultdict(int)
    for a in p.applications:
        inv = by_ref[a.invoice_ref]
        applied[a.invoice_ref] += a.applied_minor
        taken_vat[a.invoice_ref] += a.vat_pending_minor
        assert a.applied_minor + a.excess_minor >= 0
        assert a.vat_pending_minor >= 0 and a.vat_collected_minor >= 0
    for ref, total in applied.items():
        assert total <= by_ref[ref].open_minor
        assert taken_vat[ref] <= by_ref[ref].pending_vat_minor
    moved: dict[str, int] = defaultdict(int)
    for s in p.settles:
        assert 0 <= s.amount_minor <= s.open_before_minor
        if s.kind == "compensation":
            assert clauses.get(s.mandate_id, NEITHER).netting or s.amount_minor == 0
            moved[s.ref] += s.vat_moved_minor
        if s.kind == "advance":
            assert clauses.get(s.mandate_id, NEITHER).clawback
    for ref, vat in moved.items():
        inv = by_ref[ref]
        left_open = inv.open_minor - applied[ref]
        left_vat = inv.pending_vat_minor - taken_vat[ref]
        assert vat <= left_vat
        settled = sum(s.amount_minor for s in p.settles if s.ref == ref)
        if settled == left_open:
            assert vat == left_vat  # the part that closes a document moves all its pending VAT
    pool = p.gross_minor + sum(m.excess_minor for m in p.mandates)
    if pool >= 0 and not p.deferred:
        assert p.net_minor >= 0
    if all(g >= 0 for g in gross.values()):
        assert all(m.net_minor >= 0 for m in p.mandates)
    if p.deferred:
        assert p.settles == () and p.settlement_minor == 0
    assert (p.net_minor < 0) == ("negative_net" in p.blockers)


# -- M2c-7b: the claw-back through run._plan, with the facts as the prepare loads them ------------
# ([critic] M7-MONEY-7: an advance's queue item has no file and counts in its advance's mandate;
# never settlement.plan alone, which the draft's tests fed `{'M': 300 000}`)

_SCHEDULE = {
    "schema": "commission-1",
    "basis": {
        "families": "all",
        "forwards": {"file_recalled": False, "before_servicing_start": False,
                     "client_ratification": False},
        "on_reversal": "credit",
    },
    "rules": [{"id": "tout", "tier_key": "tout", "label_fr": "Toutes créances", "match": {},
               "rate": {"kind": "flat", "rate": "0.15"}}],
}  # fmt: skip
_DAY = date(2026, 11, 16)


def _at(day: date) -> datetime:
    return datetime(day.year, day.month, day.day, 12, tzinfo=UTC)


@st.composite
def loaded_runs(draw: st.DrawFn) -> tuple[Facts, dict[str, OpenAdvanceRow]]:
    """A run of a client of two mandates A and B: collections on a file of each, advance items (each
    on its advance's mandate, A, B or none), the client's open advances (some of them the run's own
    items), each mandate's netting and claw-back clauses, a proceeding opened or not."""
    terms: dict[str, list[Terms]] = {}
    for m in ("A", "B"):
        rt = {
            "schema": "remittance-1",
            "frequency": "twice_monthly",
            "netting": {"clause_ref": "art. 7.2"} if draw(st.booleans()) else None,
            "clawback": {"clause_ref": "art. 7.4"} if draw(st.booleans()) else None,
            "invoice_payment_days": 30,
        }
        terms[m] = [
            Terms(f"T{m}", m, date(2026, 1, 1), None, 30, _SCHEDULE, rt, "art. 6", "art. 7")
        ]
    items: list[Item] = []
    for n in range(draw(st.integers(0, 4))):
        day = date(2026, 11, draw(st.integers(1, 15)))
        amount = draw(st.integers(1, 200_000))
        account = draw(st.sampled_from(("FA", "FB")))
        items.append(
            Item(
                f"E{n}",
                LineKind.ALLOCATION,
                amount,
                _at(day),
                day,
                account_id=account,
                payment_id=f"P{n}",
                encaissement_date=day,
                basis={"principal": amount},
            )
        )
    advances: dict[str, OpenAdvanceRow] = {}
    for n in range(draw(st.integers(0, 4))):
        born = date(2026, 11, draw(st.integers(1, 15)))
        mandate = draw(st.sampled_from(("A", "B", None)))
        amount = draw(st.integers(1, 300_000))
        open_minor = draw(st.integers(1, amount))
        row = OpenAdvanceRow(f"V{n}", mandate, "remitted_reversal", born, _at(born), open_minor)
        advances[row.id] = row
        if draw(st.booleans()):  # its +A item is in this run (an advance posted since the last run)
            items.append(Item(row.id, LineKind.CLIENT_ADVANCE, amount, _at(born), born,
                              advance_mandate_id=mandate,
                              advance_cause="remitted_reversal"))  # fmt: skip
    opening = draw(st.sampled_from((None, date(2026, 11, 8))))
    facts = Facts(
        run_id="RUN", number="RV-2026-000009", client_id="C", currency="EUR",
        known_at=_at(_DAY), today=_DAY, service_from=date(2026, 11, 1), service_to=_DAY,
        vat_rate=Decimal("0.2"), vat_on_debits=False, items=items, pending_lines=[],
        files={"FA": FileFacts("FA", "A", "b2b_invoice", "PA"),
               "FB": FileFacts("FB", "B", "b2b_invoice", "PB")},
        mandate_refs={"A": "MAND-A", "B": "MAND-B"}, terms=terms, history={}, history_seq=0,
        charges={}, invoices={}, invoice_numbers={}, line_invoices={}, open_documents=[],
        payout_blockers=[], commission_blockers=[], payout_account_id="PA",
        proceeding_opened_on=opening, open_advances=list(advances.values()),
    )  # fmt: skip
    return facts, advances


@settings(max_examples=500, deadline=None)
@given(w=loaded_runs())
def test_the_claw_back_never_takes_beyond_its_open_its_mandate_or_its_clause(
    w: tuple[Facts, dict[str, OpenAdvanceRow]],
) -> None:
    """Through prepare_run (its `_plan`), with the facts as loaded: an advance is taken only under
    its own mandate's claw-back clause, never one of no mandate, never beyond its open, never one
    born before the client's proceeding; a mandate's advances are taken only from its own money
    (its gross with the advance items it holds, its refunds, less its invoices); N + D = gross; an
    advance item's line carries its advance's mandate."""
    facts, advances = w
    d = prepare_run(facts)
    p = d.plan
    check(p)
    assert (
        p.net_minor + p.settlement_minor
        == p.gross_minor
        == sum(i.amount_minor for i in facts.items)
    )
    taken: dict[str, int] = defaultdict(int)
    for s in p.settles:
        if s.kind != "advance":
            continue
        adv = advances[s.ref]
        assert adv.mandate_id is not None and s.mandate_id == adv.mandate_id != NO_MANDATE
        assert facts.terms[adv.mandate_id][0].remittance_terms["clawback"] is not None  # type: ignore[index]
        assert facts.proceeding_opened_on is None or adv.born_on >= facts.proceeding_opened_on
        assert s.open_before_minor == adv.open_minor
        taken[s.ref] += s.amount_minor
    for ref, amount in taken.items():
        assert amount <= advances[ref].open_minor
    for m in p.mandates:
        assert m.take_advance_minor <= max(0, m.gross_minor + m.excess_minor - m.take_minor)
        assert m.take_advance_minor == sum(
            t for ref, t in taken.items() if advances[ref].mandate_id == (m.mandate_id or None)
        )
    lines = {ln.item.entry_id: ln for ln in d.lines}
    for ref, adv in advances.items():
        if ref in lines:
            assert lines[ref].mandate_id == adv.mandate_id
            assert (lines[ref].commission_minor, lines[ref].deadline) == (0, None)


# -- M2c-7b review round 1 (M7B-MONEY-1): a mandate's own money, with the run's other rows ---------
# A remitted reversal R(E) on its file and its cover on the same mandate (they net to nothing); a
# double payout's -U row (no file) and its advance's +(U - P) row (on its mandate as a document, its
# row outside every mandate); what U paid of the run's collections (its attributions, the switch
# on); a payout that came back (no file); earlier advances of either mandate or none. A mandate's
# own money is its collections less what the run's unplanned payouts paid of them — never a row of
# a double payout, of an overrun or of a returned payout.


@st.composite
def runs_with_unplanned(
    draw: st.DrawFn,
) -> tuple[Facts, dict[str, OpenAdvanceRow], dict[str, int]]:
    terms: dict[str, list[Terms]] = {}
    for m in ("A", "B"):
        rt = {
            "schema": "remittance-1",
            "frequency": "twice_monthly",
            "netting": {"clause_ref": "art. 7.2"} if draw(st.booleans()) else None,
            "clawback": {"clause_ref": "art. 7.4"} if draw(st.booleans()) else None,
            "invoice_payment_days": 30,
        }
        terms[m] = [
            Terms(f"T{m}", m, date(2026, 1, 1), None, 30, _SCHEDULE, rt, "art. 6", "art. 7")
        ]
    mandate_of = {"FA": "A", "FB": "B"}
    items: list[Item] = []
    collections: list[Item] = []
    for n in range(draw(st.integers(0, 4))):
        day = date(2026, 11, draw(st.integers(1, 15)))
        amount = draw(st.integers(1, 200_000))
        e = Item(f"E{n}", LineKind.ALLOCATION, amount, _at(day), day,
                 account_id=draw(st.sampled_from(("FA", "FB"))), payment_id=f"P{n}",
                 encaissement_date=day, basis={"principal": amount})  # fmt: skip
        collections.append(e)
    items.extend(collections)
    advances: dict[str, OpenAdvanceRow] = {}
    # remitted reversals of earlier runs' collections, each with its cover on its file's mandate
    for n in range(draw(st.integers(0, 2))):
        day = date(2026, 11, draw(st.integers(1, 15)))
        amount = draw(st.integers(1, 100_000))
        file = draw(st.sampled_from(("FA", "FB")))
        items.append(Item(f"R{n}", LineKind.ALLOCATION_REVERSAL, -amount, _at(day), day,
                          account_id=file, payment_id=f"PR{n}", encaissement_date=date(2026, 10, 1),
                          basis={"principal": -amount},
                          original_entry_id=f"OLD{n}"))  # fmt: skip
        cover = OpenAdvanceRow(
            f"C{n}", mandate_of[file], "remitted_reversal", day, _at(day), amount
        )
        advances[cover.id] = cover
        items.append(Item(cover.id, LineKind.CLIENT_ADVANCE, amount, _at(day), day,
                          advance_mandate_id=cover.mandate_id,
                          advance_cause="remitted_reversal"))  # fmt: skip
    # double payouts: U paid P of the run's collections (attributions), its advance U - P
    paid_of: dict[str, int] = defaultdict(int)
    attributions: list[UnplannedPaid] = []
    for n in range(draw(st.integers(0, 2))):
        day = date(2026, 11, draw(st.integers(1, 15)))
        p = 0
        for e in collections:
            left = e.amount_minor - paid_of[e.entry_id]
            if left > 0 and draw(st.booleans()):
                part = draw(st.integers(1, left))
                paid_of[e.entry_id] += part
                attributions.append(UnplannedPaid(f"U{n}", e.entry_id, part))
                p += part
        u = p + draw(st.integers(0 if p else 1, 100_000))
        items.append(Item(f"U{n}", LineKind.UNPLANNED_PAYOUT, -u, _at(day), day))
        if u > p:
            mandate = draw(st.sampled_from(("A", "B", None)))
            row = OpenAdvanceRow(f"V{n}", mandate, "double_payout", day, _at(day), u - p)
            advances[row.id] = row
            items.append(Item(row.id, LineKind.CLIENT_ADVANCE, u - p, _at(day), day,
                              advance_mandate_id=mandate,
                              advance_cause="double_payout"))  # fmt: skip
    # a payout that came back, re-queued (no file)
    if draw(st.booleans()):
        day = date(2026, 11, draw(st.integers(1, 15)))
        items.append(Item("PR", LineKind.PAYOUT_RETURNED, draw(st.integers(1, 100_000)), _at(day),
                          day))  # fmt: skip
    # earlier advances still open (their rows in earlier runs)
    for n in range(draw(st.integers(0, 3))):
        born = date(2026, 11, draw(st.integers(1, 15)))
        row = OpenAdvanceRow(
            f"W{n}", draw(st.sampled_from(("A", "B", None))),
            draw(st.sampled_from(("remitted_reversal", "payout_overrun", "double_payout"))), born,
            _at(born), draw(st.integers(1, 300_000)),
        )  # fmt: skip
        advances[row.id] = row
    own: dict[str, int] = defaultdict(int)
    for e in collections:
        own[mandate_of[str(e.account_id)]] += e.amount_minor - paid_of[e.entry_id]
    facts = Facts(
        run_id="RUN", number="RV-2026-000010", client_id="C", currency="EUR",
        known_at=_at(_DAY), today=_DAY, service_from=date(2026, 11, 1), service_to=_DAY,
        vat_rate=Decimal("0.2"), vat_on_debits=False, items=items, pending_lines=[],
        files={"FA": FileFacts("FA", "A", "b2b_invoice", "PA"),
               "FB": FileFacts("FB", "B", "b2b_invoice", "PB")},
        mandate_refs={"A": "MAND-A", "B": "MAND-B"}, terms=terms, history={}, history_seq=0,
        charges={}, invoices={}, invoice_numbers={}, line_invoices={}, open_documents=[],
        payout_blockers=[], commission_blockers=[], payout_account_id="PA",
        proceeding_opened_on=draw(st.sampled_from((None, date(2026, 11, 8)))),
        open_advances=list(advances.values()), unplanned_paid=attributions,
    )  # fmt: skip
    return facts, advances, dict(own)


@settings(max_examples=500, deadline=None)
@given(w=runs_with_unplanned())
def test_a_mandate_takes_only_from_its_own_money_whatever_the_run_s_other_rows(
    w: tuple[Facts, dict[str, OpenAdvanceRow], dict[str, int]],
) -> None:
    """Through prepare_run with the facts as loaded: each mandate's money in the plan is its
    collections less what the run's unplanned payouts paid of them (a remitted reversal and its
    cover net to nothing; a double payout's two rows, a returned payout and every advance row but a
    cover's count outside every mandate); what a mandate takes (its invoices, then its advances)
    stays within that money; an advance is taken only under its own mandate's claw-back clause,
    within its open, never born before the proceeding; N + D = gross; an advance row's line is on
    its advance's mandate only for a remitted reversal's cover."""
    facts, advances, own = w
    d = prepare_run(facts)
    p = d.plan
    check(p)
    assert (
        p.net_minor + p.settlement_minor
        == p.gross_minor
        == sum(i.amount_minor for i in facts.items)
    )
    for m in p.mandates:
        if m.mandate_id == NO_MANDATE:
            assert m.take_minor == m.take_advance_minor == 0
            continue
        assert m.gross_minor == own.get(m.mandate_id, 0), (m, own)
        assert m.take_minor + m.take_advance_minor <= max(
            0, own.get(m.mandate_id, 0) + m.excess_minor
        )
    for s in p.settles:
        if s.kind != "advance":
            continue
        adv = advances[s.ref]
        assert adv.mandate_id is not None and s.mandate_id == adv.mandate_id
        assert facts.terms[adv.mandate_id][0].remittance_terms["clawback"] is not None  # type: ignore[index]
        assert facts.proceeding_opened_on is None or adv.born_on >= facts.proceeding_opened_on
        assert s.amount_minor <= adv.open_minor == s.open_before_minor
    for ln in d.lines:
        if ln.item.kind in (LineKind.CLIENT_ADVANCE, LineKind.CLIENT_ADVANCE_REVERSAL):
            adv = advances[ln.item.entry_id]
            assert ln.mandate_id == (adv.mandate_id if adv.cause == "remitted_reversal" else None)
        elif ln.item.kind in (LineKind.UNPLANNED_PAYOUT, LineKind.PAYOUT_RETURNED):
            assert ln.mandate_id is None
