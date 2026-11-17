"""M2c-6b-2b, the ops command (plan docs/design/m2c-6b-2-plan.md §3; §8.2 « Hypothesis » and the
parser part of COMPLIANCE OQ-84 (j)), without the database:

* P per item (§3.6.1; critic F2, F3, F4, F5, L1; critic2 ML-1, ML-9): the pure twin of
  private.transfer_line_check's P loop — P ≤ A, P ≤ the queue's net, P ≤ the signed net still
  owed of x's items (floored once); the attribution of P over the items in (posted_at, id) order,
  each up to what it can still take; the bound that set P; several parts of one call share the
  queue and the attributions;
* the entries an unplanned payout posts (§3.6.2-§3.6.3, §3.7): each balances, 4670 nets to -P
  in the client's queue (the -A pending row and the advance's +(A - P));
* OQ-84 (j): the parser says, for a line that is its entry's only line, whether its charges were
  read, and for each detail of ours of an entry kept unsplit whether its CdtDbtInd was given — so
  a re-import compares a stored value only against one the new file gives; the stage writes
  both."""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta
from pathlib import Path

from hypothesis import given, settings
from hypothesis import strategies as st
from test_camt053_details import RMT_A, RMT_B, _chrgs, _ntry, _parse, _tx, _xml

from collectoo_worker.jobs.payments import stage_row
from collectoo_worker.payments.statement import STAGE_COLUMNS, StatementLine, UnsplitDetail
from collectoo_worker.payments.transfer_lines import (
    PoolItem,
    UnplannedAsk,
    unplanned_entries,
    unplanned_p,
)

T0 = datetime(2026, 11, 1, 9, tzinfo=UTC)


def _item(  # noqa: PLR0913 - one keyword per fact of an item a test sets
    n: int,
    pending: int | None,
    *,
    reverses: str | None = None,
    reversal_pending: int = 0,
    paid: int = 0,
    own: bool = False,
) -> PoolItem:
    return PoolItem(
        entry_id=f"i{n:03d}",
        posted_at=T0 + timedelta(minutes=n),
        pending=pending,
        reverses=reverses,
        reversal_pending=reversal_pending,
        paid=paid,
        own=own,
    )


def _one(amount: int, items: list[PoolItem], queue: int) -> tuple[int, str, list[tuple[str, int]]]:
    ask = UnplannedAsk(amount=amount, client="c", pool=tuple(i.entry_id for i in items))
    (res,) = unplanned_p([ask], {i.entry_id: i for i in items}, {"c": queue})
    return res.p, res.bound, list(res.attribution)


# -- P: examples from the plan ------------------------------------------------------------------


def test_p_is_what_was_meant_to_be_paid_and_still_waits() -> None:
    """§3.6.1: P = least(A, queue, cap); each bound named (ML-9)."""
    items = [_item(1, 1_000), _item(2, 600)]
    assert _one(1_600, items, 5_000) == (1_600, "amount", [("i001", 1_000), ("i002", 600)])
    assert _one(2_000, items, 5_000) == (1_600, "items", [("i001", 1_000), ("i002", 600)])
    assert _one(1_600, items, 700) == (700, "queue", [("i001", 700)])
    assert _one(1_600, [], 5_000) == (0, "none", [])
    # a negative queue nets nothing
    assert _one(1_600, items, -50) == (0, "queue", [])


def test_ml1_the_cap_is_the_signed_net_floored_once() -> None:
    """Critic2 ML-1's example: +1 000, r -300 (a reversal released by the cancelled run) and v +300
    (its cover): the signed net is 1 000 - 300 + 300 = … with a's own bounce -1 000 in its chain,
    0: P = 0 and the whole late payout is the servicer's advance."""
    a = _item(1, 1_000, reversal_pending=-1_000)
    r = _item(2, -300)
    v = _item(3, 300)
    assert _one(1_000, [a, r, v], 2_000) == (0, "items", [])
    # the draft's per-item floor would have taken v's 300
    assert sum(max(0, i.net) for i in (a, r, v)) == 300


def test_f3_an_item_reversed_since_counts_net_of_its_reversal_once() -> None:
    """F3: the reversal of a pool item is counted in that item's chain, once — even when the pool
    also lists the reversal itself (both lines released by the cancelled run)."""
    a = _item(1, 1_000, reversal_pending=-400)
    rev = _item(2, -400, reverses="i001")
    assert _one(1_000, [a, rev], 9_000) == (600, "items", [("i001", 600)])


def test_f4_earlier_attributions_are_not_owed_twice() -> None:
    """F4: an item released by two cancelled runs is paid once: what an earlier unplanned booking
    (not reversed) attributed to it is deducted; so is what an earlier part of this call did."""
    a = _item(1, 1_000, paid=700)
    assert _one(1_000, [a], 9_000) == (300, "items", [("i001", 300)])
    asks = [
        UnplannedAsk(amount=800, client="c", pool=("i001",)),
        UnplannedAsk(amount=800, client="c", pool=("i001",)),
    ]
    first, second = unplanned_p(asks, {"i001": _item(1, 1_000)}, {"c": 9_000})
    assert (first.p, second.p) == (800, 200)
    assert list(second.attribution) == [("i001", 200)]


def test_money2_bookings_of_one_transfer_never_net_more_than_its_amount() -> None:
    """Review money-2, LT-1 (037 D S01): x (24 600) of a cancelled run whose item was 30 000 (its
    run set off 5 400 of commission) executed late twice: the first booking nets 24 600 of the
    item; the second finds 5 400 of the item's gross left — the commission the next run takes on
    it — and nets nothing (its prior bookings netted all of x), the whole of it an advance."""
    item = _item(1, 30_000)
    (first,) = unplanned_p([UnplannedAsk(24_600, "c", ("i001",))], {"i001": item}, {"c": 80_000})
    assert (first.p, first.bound) == (24_600, "amount")
    again = _item(1, 30_000, paid=24_600)
    (second,) = unplanned_p(
        [UnplannedAsk(24_600, "c", ("i001",), prior=24_600)], {"i001": again}, {"c": 55_400}
    )
    assert (second.p, second.advance, second.bound, second.attribution) == (0, 24_600, "items", ())
    # a first booking the queue bound to 10 000: the second may still net the rest of x
    (rest,) = unplanned_p(
        [UnplannedAsk(24_600, "c", ("i001",), prior=10_000)],
        {"i001": _item(1, 30_000, paid=10_000)},
        {"c": 80_000},
    )
    assert (rest.p, rest.bound) == (14_600, "items")


def test_parts_of_one_call_share_the_client_s_queue() -> None:
    """The queue is the client's, under the allocation lock: earlier parts' P come off it."""
    asks = [
        UnplannedAsk(amount=500, client="c", pool=("i001",)),
        UnplannedAsk(amount=500, client="c", pool=("i002",)),
        UnplannedAsk(amount=500, client="d", pool=("i003",)),
    ]
    items = {i.entry_id: i for i in (_item(1, 500), _item(2, 500), _item(3, 500))}
    res = unplanned_p(asks, items, {"c": 700, "d": 100})
    assert [(r.p, r.bound) for r in res] == [(500, "amount"), (200, "queue"), (100, "queue")]


def test_ml1_own_unplanned_rows_are_not_items() -> None:
    """ML-1: the -A rows of earlier unplanned bookings and their advances are not x's items (the
    attributions count what they netted); an item without a pending row is not waiting."""
    items = [_item(1, -1_000, own=True), _item(2, 400, own=True), _item(3, None), _item(4, 300)]
    assert _one(1_000, items, 9_000) == (300, "items", [("i004", 300)])


def test_q8_a_client_part_or_a_never_returned_transfer_has_no_items() -> None:
    """Q8: a client part (no transfer) has no items: P = 0, the whole amount is the advance."""
    (res,) = unplanned_p([UnplannedAsk(amount=900, client="c", pool=None)], {}, {"c": 9_000})
    assert (res.p, res.advance, res.bound, res.attribution) == (0, 900, "none", ())


# -- P: properties ------------------------------------------------------------------------------

AMOUNTS = st.integers(min_value=-5_000, max_value=5_000)


@st.composite
def pools(draw: st.DrawFn) -> tuple[list[UnplannedAsk], dict[str, PoolItem], dict[str, int]]:
    n = draw(st.integers(min_value=0, max_value=8))
    items: dict[str, PoolItem] = {}
    for k in range(n):
        reverses: str | None = None
        # a reversal is never reversed, an entry is reversed once (ledger_entry_reversed_once_uq)
        free = sorted(
            e
            for e, i in items.items()
            if i.reverses is None and all(j.reverses != e for j in items.values())
        )
        pick = draw(st.booleans())
        if free and pick:
            reverses = draw(st.sampled_from(free))
        # (review TESTS-6) mostly items still owed in part, so that P is often spread over several
        pending = (
            None
            if draw(st.integers(min_value=0, max_value=5)) == 0
            else draw(st.one_of(AMOUNTS, st.integers(min_value=1, max_value=5_000)))
        )
        it = _item(
            k,
            pending,
            reverses=reverses,
            reversal_pending=draw(
                st.one_of(st.just(0), st.integers(min_value=-5_000, max_value=0))
            ),
            paid=draw(st.one_of(st.just(0), st.integers(min_value=0, max_value=3_000))),
            own=draw(st.integers(min_value=0, max_value=9)) == 0,
        )
        items[it.entry_id] = it
    names = sorted(items)
    # review TESTS-6: often one client's parts only (the queue they share binds), the queue often
    # smaller than what the parts ask
    shared = draw(st.booleans())
    asks = [
        UnplannedAsk(
            amount=draw(st.integers(min_value=1, max_value=8_000)),
            client="c" if shared else draw(st.sampled_from(["c", "d"])),
            pool=(
                None
                if draw(st.integers(min_value=0, max_value=5)) == 0
                else tuple(
                    draw(st.lists(st.sampled_from(names), unique=True, min_size=len(names) // 2))
                )
                if names
                else ()
            ),
            prior=(
                draw(st.integers(min_value=0, max_value=9_000))
                if draw(st.integers(min_value=0, max_value=3)) == 0
                else 0
            ),
        )
        for _ in range(draw(st.integers(min_value=1, max_value=4)))
    ]
    top = draw(st.sampled_from([3_000, 20_000, 20_000]))
    queue = {"c": draw(st.integers(-3_000, top)), "d": draw(st.integers(-3_000, top))}
    return asks, items, queue


@settings(max_examples=600, deadline=None)
@given(pools())
def test_p_bounds_and_attribution(
    case: tuple[list[UnplannedAsk], dict[str, PoolItem], dict[str, int]],
) -> None:
    """[critic F3, critic2 ML-1; review TESTS-6, money-2] For every part, from the raw facts of its
    items (never the twin's own helpers): the eligible items are those with a pending row that are
    not an unplanned booking's own, a reversal folded into the item it reverses; net = the item's
    pending row + its reversal's; what each can still take = net - what unreversed bookings and
    earlier parts attributed to it; cap = that summed, floored once, and at most A less what
    earlier bookings of the same transfer netted; P = max(0, min(A, what the client's queue still
    nets after earlier parts, cap)) exactly; the bound that set it; the attribution is P spread over
    the items in (posted_at, id) order, each up to what it can still take."""
    asks, items, queue = case
    res = unplanned_p(asks, items, queue)
    taken: dict[str, int] = {}
    used = {"c": 0, "d": 0}
    for ask, r in zip(asks, res, strict=True):
        if ask.pool is None:
            assert (r.p, r.advance, r.bound, r.attribution) == (0, ask.amount, "none", ())
            continue
        pool = list(dict.fromkeys(ask.pool))
        el = [e for e in pool if items[e].pending is not None and not items[e].own]
        el = [e for e in el if items[e].reverses not in el]
        net = {e: (items[e].pending or 0) + items[e].reversal_pending for e in el}
        can = {e: net[e] - items[e].paid - taken.get(e, 0) for e in el}
        cap = min(max(0, sum(can.values())), max(0, ask.amount - ask.prior))
        left = max(0, queue[ask.client]) - used[ask.client]
        want = max(0, min(ask.amount, left, cap))
        assert r.p == want, (ask, r)
        assert r.advance == ask.amount - want
        if not el:
            bound = "none"
        elif want == ask.amount:
            bound = "amount"
        elif want == cap:
            bound = "items"
        else:
            bound = "queue"
        assert r.bound == bound
        rest, spread = want, []
        for e in sorted(el, key=lambda e: (items[e].posted_at, e)):
            if rest > 0 and can[e] > 0:
                share = min(can[e], rest)
                spread.append((e, share))
                rest -= share
        assert list(r.attribution) == spread
        for e, a in spread:
            taken[e] = taken.get(e, 0) + a
        used[ask.client] += want
    for e, total in taken.items():
        assert total <= max(0, items[e].net - items[e].paid)
    for c in ("c", "d"):
        assert used[c] <= max(0, queue[c])


# -- the entries ---------------------------------------------------------------------------------


@settings(max_examples=200, deadline=None)
@given(st.integers(min_value=1, max_value=10**9), st.data())
def test_an_unplanned_payout_s_entries_balance_and_net_p_in_the_queue(
    amount: int, data: st.DataObject
) -> None:
    """§3.6.2-§3.6.3, §3.7: the remittance (+4670[c] A / -5120 A) and, when A - P > 0, the
    advance (+4679 X / -4670[c] X ‖ +4112[c] X / -4689 X) each balance; 4670[c] moves by A - X = P
    (owed falls by P), the queue by -A + X = -P (I14: owed = pending + in flight); no 4670 line is
    ever a credit beyond what it debits (I13: 4670 never in debit at the end)."""
    p = data.draw(st.integers(min_value=0, max_value=amount))
    posted = unplanned_entries(amount, p)
    for lines in posted.entries.values():
        assert sum(m for _b, m in lines) == 0
    owed = sum(m for lines in posted.entries.values() for b, m in lines if b == "client_payable")
    assert owed == p
    assert posted.pending_net == -p
    assert ("client_advance" in posted.entries) == (amount > p)


# -- OQ-84 (j): what the parser says it was given ------------------------------------------------


def test_oq84j_the_line_says_whether_its_charges_were_read(tmp_path: Path) -> None:
    """A line that is its entry's only line: charges_read true when the statement had no charges
    block or every record was read (charges_minor the total, or none), false when a block was seen
    and not read (v02's `Chrgs`, a credit record, another currency, the entry's and its one
    detail's disagreeing); none on the lines of an entry split in several."""
    cases = [
        ("08", _ntry("10.00", charges=_chrgs("1.20")), (120, True)),
        ("08", _ntry("10.00"), (None, True)),
        ("08", _ntry("10.00", _tx(RMT_A, charges=_chrgs("1.20"))), (120, True)),
        (
            "08",
            _ntry("10.00", _tx(RMT_A, charges=_chrgs("1.20")), charges=_chrgs("1.30")),
            (None, False),
        ),
        ("08", _ntry("10.00", charges=_chrgs("1.20", ind="CRDT")), (None, False)),
        ("08", _ntry("10.00", charges=_chrgs("1.20", ccy="USD")), (None, False)),
        ("02", _ntry("10.00", charges=_chrgs("1.20", v02=True)), (None, False)),
        (
            "02",
            _ntry("101.20", _tx(RMT_A, tx_amt="100.00"), charges=_chrgs("1.20", v02=True)),
            (None, False),
        ),
        ("08", _ntry("101.20", _tx(RMT_A, tx_amt="100.00"), charges=_chrgs("1.20")), (120, True)),
    ]
    for version, entry, want in cases:
        (line,) = _parse(tmp_path, _xml([entry], version)).lines
        assert (line.charges_minor, line.charges_read) == want, (version, entry)
    # review TESTS-9: an entry kept unsplit of two details — a detail carrying Chrgs is not this
    # line's to read; the entry's own readable Chrgs are; an unreadable entry-level record is not
    a, b = _tx(RMT_A, amt="120.00"), _tx(RMT_B, amt="90.00")
    unsplit = [
        (_ntry("200.00", _tx(RMT_A, amt="120.00", charges=_chrgs("1.20")), b), (None, False)),
        (_ntry("200.00", a, b, charges=_chrgs("1.20")), (120, True)),
        (_ntry("200.00", a, b, charges=_chrgs("1.20", ind="CRDT")), (None, False)),
        (_ntry("200.00", a, b), (None, True)),
    ]
    for entry, want in unsplit:
        (line,) = _parse(tmp_path, _xml([entry])).lines
        assert line.unsplit_ours == 2, entry
        assert (line.charges_minor, line.charges_read) == want, entry
    split = _ntry(
        "50.00", _tx("E2E-1", amt="20.00"), _tx("E2E-2", amt="30.00"), side="CRDT", ref="N2"
    )
    assert [(x.charges_minor, x.charges_read) for x in _parse(tmp_path, _xml([split])).lines] == [
        (None, None),
        (None, None),
    ]


def test_oq84j_each_detail_of_ours_says_whether_its_direction_was_given(tmp_path: Path) -> None:
    """An entry kept unsplit: per detail of ours (the details' order), whether its CdtDbtInd was
    given (v08 with it) or the entry's was taken (v02, or a v08 export without it); none on every
    other line."""
    v08 = _ntry(
        "200.00",
        _tx(RMT_A, amt="120.00", side="DBIT"),
        _tx(RMT_B, amt="80.00"),
        _tx("E2E-X", amt="0.00"),
    )
    (line,) = _parse(tmp_path, _xml([v08])).lines
    assert line.unsplit_details is not None
    assert [d.id for d in line.unsplit_details] == [RMT_A, RMT_B]
    assert line.unsplit_direction_given == (True, False)
    v02 = _ntry("200.00", _tx(RMT_A, tx_amt="120.00"), _tx(RMT_B, tx_amt="90.00"))
    (line,) = _parse(tmp_path, _xml([v02], "02")).lines
    assert line.unsplit_direction_given == (False, False)
    (whole,) = _parse(tmp_path, _xml([_ntry("10.00", _tx(RMT_A))])).lines
    assert whole.unsplit_direction_given is None


def test_oq84j_the_stage_writes_both() -> None:
    """The stage's COPY row carries charges_read and unsplit_direction_given (as a list)."""
    assert {"charges_read", "unsplit_direction_given"} <= set(STAGE_COLUMNS)
    line = StatementLine(
        line_no=1,
        section_no=1,
        dedup_key="e:N1#1",
        direction="debit",
        amount_minor=20_000,
        currency="EUR",
        booking_date=date(2026, 10, 1),
        value_date=None,
        kind="batch_unsplit",
        method="sct",
        unsplit_ours=1,
        unsplit_details=(UnsplitDetail(RMT_A, "debit", 12_000),),
        unsplit_detail_count=2,
        charges_minor=None,
        charges_read=True,
        unsplit_direction_given=(False,),
    )
    row = dict(zip(("statement_id", *STAGE_COLUMNS), stage_row("s", line), strict=True))
    assert (row["charges_read"], row["unsplit_direction_given"]) == (True, [False])
