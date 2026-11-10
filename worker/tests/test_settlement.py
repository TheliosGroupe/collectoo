"""The settlement plan of a run (design §9.6, §7.2 worked example; founder #3, #7): the worked
example's runs RV-1 … RV-3 and its variants, then Hypothesis properties — N + D = gross; nothing
taken without its clause; every settled part within its document's open part, VAT moved within its
pending VAT and all of it when the document closes; N ≥ 0 whenever the client's money allows it;
a credit note applied within the invoice's open part, its VAT off the pending part first."""

from __future__ import annotations

from collections import defaultdict

from hypothesis import given, settings
from hypothesis import strategies as st

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
