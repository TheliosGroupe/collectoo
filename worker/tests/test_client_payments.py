"""M2c-7c-1 (plan docs/design/m2c-7-plan.md §5.2.3; ADR-0014 « M2c-7c-1 »): what a client's payment
to the servicer settles — the pure twin of private.client_payment_plan (the parity with the SQL is
test_client_payment_plan_parity_integration.py).

* With the client's designation (C. civ. 1342-10 al. 1; [critic] L16): the documents it names, in
  its order, each up to its open part; a named document it may not pay (before its proceeding,
  L622-7 I) becomes a credit held for the procedure; then the written-off advances it names
  ([critic] M7-MONEY-10), each up to what is left to recover; the rest a credit owed back.
* Without it: the default order, our reading of 1342-10 al. 2 (founder Q4, OQ-89) — invoices due
  on or before the payment's date, by (due date, year, number); advances by (birth, recording);
  the other invoices — skipping what the client may not pay ([check 1] gap 11); the rest a credit
  owed back ([critic] M7-MONEY-10: never refused), of cause `procedure` while a proceeding stands.
* VAT moved on an invoice part: R(pending x part / open), all of it when the part closes it.

Then Hypothesis: Σ parts = the amount; each part within its document; VAT within its pending VAT
and all of it when the document closes; the default order never pays a later document while an
earlier one stays open; never a document the client may not pay without its designation; and the
entry the parts make balances in the servicer's fund (5122 = 4111 + 4112 + 419 + 7714; the VAT
pair nets to 0)."""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from collectoo_worker.remittance.client_payments import (
    ClientPaymentInputError,
    PayableDocument,
    PaymentPart,
    WrittenOff,
    considered_open,
    default_order,
    entry_lines,
    plan_client_payment,
)

ON = date(2026, 11, 20)
T0 = datetime(2026, 11, 1, 9, tzinfo=UTC)


def inv(  # noqa: PLR0913 - a test document's facts
    n: str,
    open_minor: int,
    *,
    pending: int = 0,
    due: date | None = None,
    seq: int = 1,
    payable: bool = True,
) -> PayableDocument:
    return PayableDocument(
        kind="invoice",
        id=f"00000000-0000-0000-0000-0000000000{n}",
        open_minor=open_minor,
        pending_vat_minor=pending,
        payable=payable,
        due_date=due,
        year=2026,
        seq=seq,
    )


def adv(
    n: str, open_minor: int, *, born: date, at: int = 0, payable: bool = True
) -> PayableDocument:
    return PayableDocument(
        kind="advance",
        id=f"00000000-0000-0000-0000-0000000000{n}",
        open_minor=open_minor,
        payable=payable,
        born_on=born,
        created_at=T0 + timedelta(minutes=at),
    )


def parts(rows: list[PaymentPart]) -> list[tuple[str, str | None, int, int, str | None]]:
    return [
        (r.document_kind, r.document_id[-2:] if r.document_id else None, r.amount_minor,
         r.vat_moved_minor, r.cause)
        for r in rows
    ]  # fmt: skip


# FC-1 due on the 10th (36 000 TTC, 6 000 VAT pending), an advance born on the 12th (20 000), FC-2
# due on the 30th (12 000, 2 000 VAT)
FC1 = inv("01", 36_000, pending=6_000, due=date(2026, 11, 10), seq=1)
A1 = adv("a1", 20_000, born=date(2026, 11, 12))
FC2 = inv("02", 12_000, pending=2_000, due=date(2026, 11, 30), seq=2)
DOCS = [FC2, A1, FC1]


def test_the_default_order_is_due_invoices_then_advances_then_the_others() -> None:
    assert [d.id[-2:] for d in default_order(DOCS, ON)] == ["01", "a1", "02"]
    out = plan_client_payment(DOCS, 60_000, [], [], procedure=False, on=ON)
    assert parts(out) == [
        ("invoice", "01", 36_000, 6_000, None),
        ("advance", "a1", 20_000, 0, None),
        ("invoice", "02", 4_000, 667, None),  # R(2 000 x 4 000 / 12 000) = R(666.67)
    ]


def test_due_invoices_by_due_date_then_advances_oldest_born_first_in_recording_order() -> None:
    """045 d's case: due invoices by due date whatever their numbers, then the advances by birth,
    two born the same day by recording."""
    older = adv("a2", 5_000, born=date(2026, 11, 2), at=60 * 24 * 14)  # recorded last, born first
    same_day = adv("a3", 5_000, born=A1.born_on or ON, at=-60)  # born with A1, recorded before it
    fc3 = inv("03", 1_000, due=date(2026, 11, 15), seq=0)  # numbered before FC-1, due after it
    order = default_order([FC2, A1, same_day, older, fc3, FC1], ON)
    assert [d.id[-2:] for d in order] == ["01", "03", "a2", "a3", "a1", "02"]
    out = plan_client_payment([A1, same_day, older], 8_000, [], [], procedure=False, on=ON)
    assert parts(out) == [("advance", "a2", 5_000, 0, None), ("advance", "a3", 3_000, 0, None)]


def test_an_invoice_not_yet_due_on_the_payment_s_date_comes_after_the_advances() -> None:
    early = date(2026, 11, 9)  # FC-1 not due yet either: both invoices after the advance
    assert [d.id[-2:] for d in default_order(DOCS, early)] == ["a1", "01", "02"]


def test_vat_moves_pro_rata_and_in_full_on_the_part_that_closes_the_invoice() -> None:
    first = plan_client_payment([FC1], 10_000, [], [], procedure=False, on=ON)
    assert parts(first) == [("invoice", "01", 10_000, 1_667, None)]  # R(6 000 x 10 000 / 36 000)
    rest = inv("01", 26_000, pending=6_000 - 1_667, due=FC1.due_date)
    closing = plan_client_payment([rest], 26_000, [], [], procedure=False, on=ON)
    assert parts(closing) == [("invoice", "01", 26_000, 4_333, None)]  # all that is left


def test_what_exceeds_what_is_open_is_a_credit_owed_back_never_refused() -> None:
    out = plan_client_payment([FC1], 36_500, [], [], procedure=False, on=ON)
    assert parts(out) == [
        ("invoice", "01", 36_000, 6_000, None),
        ("client_credit", None, 500, 0, "overpayment"),
    ]
    nothing = plan_client_payment([], 20_000, [], [], procedure=False, on=ON)
    assert parts(nothing) == [("client_credit", None, 20_000, 0, "overpayment")]


def test_the_client_s_designation_is_followed_in_its_order() -> None:
    out = plan_client_payment(DOCS, 30_000, [FC2.id, A1.id], [], procedure=False, on=ON)
    assert parts(out) == [
        ("invoice", "02", 12_000, 2_000, None),
        ("advance", "a1", 18_000, 0, None),
    ]
    # with a designation, what is left after what the client named is a credit, never another
    # document
    more = plan_client_payment(DOCS, 40_000, [FC2.id], [], procedure=False, on=ON)
    assert parts(more) == [
        ("invoice", "02", 12_000, 2_000, None),
        ("client_credit", None, 28_000, 0, "overpayment"),
    ]


def test_a_written_off_advance_the_client_repays_is_a_recovery_capped_at_what_was_written_off() -> (
    None
):
    w = WrittenOff(id="00000000-0000-0000-0000-0000000000w1", available_minor=15_000)
    out = plan_client_payment([], 20_000, [], [w], procedure=False, on=ON)
    assert parts(out) == [
        ("written_off", "w1", 15_000, 0, None),
        ("client_credit", None, 5_000, 0, "overpayment"),
    ]


def test_a_written_off_advance_the_client_may_not_repay_is_held_for_the_procedure() -> None:
    """(review round 1, MONEY-1; L622-7 I al. 1, founder Q4 a) a client in a proceeding repays an
    advance passed as a loss that was born before the opening: never a recovery (no 7714) — the
    part it meant for it is held for the procedure, naming the advance; a payable one beside it
    is still a recovery."""
    before = WrittenOff(
        id="00000000-0000-0000-0000-0000000000w1", available_minor=15_000, payable=False
    )
    after = WrittenOff(id="00000000-0000-0000-0000-0000000000w2", available_minor=4_000)
    out = plan_client_payment([], 20_000, [], [before, after], procedure=True, on=ON)
    assert parts(out) == [
        ("client_credit", "w1", 15_000, 0, "procedure"),
        ("written_off", "w2", 4_000, 0, None),
        ("client_credit", None, 1_000, 0, "procedure"),
    ]
    assert entry_lines(out)["written_off_recovered"] == -4_000
    assert entry_lines(out)["client_credit_owed"] == -16_000
    assert considered_open([], [], [before, after]) == 19_000


def test_the_default_order_skips_what_the_client_may_not_pay() -> None:
    """[check 1] gap 11 (plan 045 (l)): a client in a proceeding opened on the 15th, FC-3 issued
    before it (not payable), FC-5 after: a payment of FC-5's amount with no designation pays FC-5;
    a larger one pays FC-5 and the rest is held for the procedure, never FC-3."""
    fc3 = inv("03", 24_000, pending=4_000, due=date(2026, 11, 5), seq=3, payable=False)
    fc5 = inv("05", 12_000, pending=2_000, due=date(2026, 11, 19), seq=5)
    assert parts(plan_client_payment([fc3, fc5], 12_000, [], [], procedure=True, on=ON)) == [
        ("invoice", "05", 12_000, 2_000, None)
    ]
    assert parts(plan_client_payment([fc3, fc5], 20_000, [], [], procedure=True, on=ON)) == [
        ("invoice", "05", 12_000, 2_000, None),
        ("client_credit", None, 8_000, 0, "procedure"),
    ]
    # designated, FC-3 is held for the procedure (the part the client meant for it), FC-3 still open
    assert parts(plan_client_payment([fc3, fc5], 24_000, [fc3.id], [], procedure=True, on=ON)) == [
        ("client_credit", "03", 24_000, 0, "procedure")
    ]


def test_a_named_document_the_plan_does_not_hold_is_a_data_error() -> None:
    with pytest.raises(ClientPaymentInputError):
        plan_client_payment(
            [FC1], 1_000, ["00000000-0000-0000-0000-0000000000ff"], [], procedure=False, on=ON
        )
    with pytest.raises(ClientPaymentInputError):
        plan_client_payment([FC1], 0, [], [], procedure=False, on=ON)
    with pytest.raises(ClientPaymentInputError):
        plan_client_payment([inv("09", 0)], 1_000, [], [], procedure=False, on=ON)


def test_what_is_considered_open_is_what_the_plan_may_settle() -> None:
    w = WrittenOff(id="00000000-0000-0000-0000-0000000000w1", available_minor=15_000)
    fc3 = inv("03", 24_000, payable=False)
    assert considered_open([*DOCS, fc3], [], []) == 68_000  # the payable ones
    assert considered_open([*DOCS, fc3], [fc3.id, A1.id], [w]) == 59_000  # the named ones


def test_the_entry_lines_of_a_payment() -> None:
    out = plan_client_payment(DOCS, 70_000, [], [], procedure=False, on=ON)
    assert entry_lines(out) == {
        "commission_receivable": -48_000,
        "client_advance_receivable": -20_000,
        "client_credit_owed": -2_000,
        "written_off_recovered": 0,
        "vat_pending": 8_000,
        "vat_collected": -8_000,
    }


# Hypothesis ---------------------------------------------------------------------------------------


@st.composite
def cases(draw: st.DrawFn) -> tuple[list[PayableDocument], int, list[str], list[WrittenOff], bool]:
    n = draw(st.integers(0, 7))
    docs: list[PayableDocument] = []
    for k in range(n):
        open_minor = draw(st.integers(1, 50_000))
        payable = draw(st.booleans()) if draw(st.integers(0, 3)) == 0 else True
        if draw(st.booleans()):
            due = draw(st.one_of(st.none(), st.dates(date(2026, 10, 1), date(2026, 12, 31))))
            docs.append(
                inv(
                    f"{k:02d}",
                    open_minor,
                    pending=draw(st.integers(0, open_minor // 5)),
                    due=due,
                    seq=draw(st.integers(1, 9)) * 10 + k,
                    payable=payable,
                )
            )
        else:
            docs.append(
                adv(
                    f"{k:02d}",
                    open_minor,
                    born=draw(st.dates(date(2026, 10, 1), date(2026, 11, 30))),
                    at=draw(st.integers(0, 3)),
                    payable=payable,
                )
            )
    designated = draw(st.booleans())
    named = (
        [d.id for d in draw(st.permutations(docs))][: draw(st.integers(0, n))] if designated else []
    )
    recover = (
        [
            WrittenOff(
                f"00000000-0000-0000-0000-00000000w{k:03d}",
                draw(st.integers(1, 30_000)),
                draw(st.integers(0, 3)) > 0,
            )
            for k in range(draw(st.integers(0, 2)))
        ]
        if designated
        else []
    )
    amount = draw(st.integers(1, 200_000))
    return docs, amount, named, recover, draw(st.booleans())


@settings(max_examples=1000, deadline=None)
@given(cases())
def test_the_plan_settles_exactly_the_amount_within_each_document(
    case: tuple[list[PayableDocument], int, list[str], list[WrittenOff], bool],
) -> None:
    docs, amount, named, recover, procedure = case
    out = plan_client_payment(docs, amount, named, recover, procedure=procedure, on=ON)
    by_id = {d.id: d for d in docs}
    assert sum(r.amount_minor for r in out) == amount
    assert all(r.amount_minor > 0 for r in out)
    assert [r.ord for r in out] == list(range(1, len(out) + 1))
    for r in out:
        if r.document_kind in ("invoice", "advance"):
            d = by_id[r.document_id or ""]
            assert d.payable and r.amount_minor <= d.open_minor
            if r.document_kind == "advance":
                assert r.vat_moved_minor == 0
            elif r.amount_minor == d.open_minor:
                assert r.vat_moved_minor == d.pending_vat_minor  # closes it: all of its VAT
            else:
                assert 0 <= r.vat_moved_minor <= d.pending_vat_minor
        elif r.document_kind == "written_off":
            w = next(x for x in recover if x.id == r.document_id)
            assert r.amount_minor <= w.available_minor and r.vat_moved_minor == 0
            assert w.payable  # never income for a loss the client may not repay (MONEY-1)
        else:
            assert r.document_kind == "client_credit" and r.vat_moved_minor == 0
            assert r.cause in ("overpayment", "procedure")
    # each document at most once; a credit for the surplus last, of its cause
    keyed = [(r.document_kind, r.document_id) for r in out if r.document_id]
    assert len(keyed) == len(set(keyed))
    surplus = [r for r in out if r.document_kind == "client_credit" and r.document_id is None]
    assert len(surplus) <= 1
    if surplus:
        assert out[-1] is surplus[0]
        assert surplus[0].cause == ("procedure" if procedure else "overpayment")
    # the entry balances in the servicer's fund: 5122 (or 4689) P = the credits of 4111, 4112, 419
    # and 7714; the VAT pair nets to 0
    lines = entry_lines(out)
    assert -sum(v for k, v in lines.items() if not k.startswith("vat_")) == amount
    assert lines["vat_pending"] + lines["vat_collected"] == 0


@settings(max_examples=1000, deadline=None)
@given(cases())
def test_without_a_designation_the_default_order_is_followed_and_never_what_the_client_may_not_pay(
    case: tuple[list[PayableDocument], int, list[str], list[WrittenOff], bool],
) -> None:
    docs, amount, _named, _recover, procedure = case
    out = plan_client_payment(docs, amount, [], [], procedure=procedure, on=ON)
    order = default_order([d for d in docs if d.payable], ON)
    paid = {r.document_id: r.amount_minor for r in out if r.document_kind in ("invoice", "advance")}
    # every document the client may not pay stays untouched (gap 11)
    assert all(d.payable for d in docs if d.id in paid)
    # in the default order: paid in full up to the first one paid in part (or not at all), nothing
    # after
    seen_short = False
    for d in order:
        got = paid.get(d.id, 0)
        if seen_short:
            assert got == 0, (d, out)
        elif got < d.open_minor:
            seen_short = True
    # a credit only once everything payable is paid
    if any(r.document_kind == "client_credit" for r in out):
        assert all(paid.get(d.id, 0) == d.open_minor for d in order)
    assert considered_open(docs, [], []) == sum(d.open_minor for d in order)


@settings(max_examples=500, deadline=None)
@given(cases())
def test_with_a_designation_only_what_the_client_named_is_paid_in_its_order(
    case: tuple[list[PayableDocument], int, list[str], list[WrittenOff], bool],
) -> None:
    docs, amount, named, recover, procedure = case
    if not named and not recover:
        return
    out = plan_client_payment(docs, amount, named, recover, procedure=procedure, on=ON)
    by_id = {d.id: d for d in docs}
    recovered = {w.id: w for w in recover}
    meant = [r for r in out if r.document_id in by_id]
    assert [r.document_id for r in meant] == named[: len(meant)]  # the client's order
    for r in meant:
        d = by_id[r.document_id or ""]
        # a document named that the client may not pay is held for the procedure, never settled
        assert (r.document_kind == "client_credit") == (not d.payable)
        assert r.document_kind != "client_credit" or r.cause == "procedure"
    # then its recoveries, in its order: income only for what it may repay, else held for the
    # procedure (review round 1, MONEY-1)
    repaid = [r for r in out if r.document_id in recovered]
    assert [r.document_id for r in repaid] == [w.id for w in recover][: len(repaid)]
    assert all(out.index(a) < out.index(b) for a in meant for b in repaid)
    for r in repaid:
        w = recovered[r.document_id or ""]
        assert (r.document_kind, r.cause) == (
            ("written_off", None) if w.payable else ("client_credit", "procedure")
        )
