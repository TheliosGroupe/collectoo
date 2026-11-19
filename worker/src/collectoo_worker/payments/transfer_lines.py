"""M2c-6b-2b, the ops command's arithmetic (plan docs/design/m2c-6b-2-plan.md §3.6, §3.7), pure.

`unplanned_p` is the twin of private.transfer_line_check's P loop (migration
20261117100000_transfer_line_ops.sql; the property tests read it as the oracle and the integration
test compares it with the command's result): for each unplanned payout part of one call, in its
order, what the late or second payout paid of the items x was meant to pay that are still owed and
still waiting (Q4's default, COMPLIANCE OQ-82; critic F2, F3, F4, F5, L1; critic2 ML-1, ML-9):

    eligible  = the part's pool items with a pending row, less the pool's own unplanned rows (the
                -A rows of earlier unplanned bookings, their double_payout advances and those
                advances' reversals), a reversal folded into the item it reverses
    net(i)    = pending(i) + pending(the reversal of i)            -- signed (a reversal is never
                                                                   -- reversed: one level)
    paid(i)   = what unreversed unplanned bookings attributed to i + what earlier parts did
    cap       = greatest(0, Σ net - Σ paid)                        -- floored once (ML-1)
              , and at most A - prior: the P earlier unreversed unplanned bookings of the same
                transfer netted (review money-2, LT-1: together they never net more than x's
                amount, all its run would have paid the client of its items — their gross left is
                the commission that run set off, which the next run takes on them)
    J         = (M2c-6b-3a-2, COMPLIANCE OQ-82, Q3 (a)) an item another transfer's late execution
                already netted — an unreversed unplanned booking of another transfer attributed it
                (`paid_by_other`), or an earlier part of this call for another transfer — counts
                nothing more: its net - paid is floored at 0 from above (min(0, ...)), never netted
                again
    queue(c)  = greatest(0, Σ pending of (c, currency)) - the P of earlier parts for c
    P         = greatest(0, least(A, queue(c), cap))
    attribute P over the items with net - paid > 0 in (posted_at, id) order, each up to that.

`unplanned_entries` is what the command posts for one unplanned payout (all at the line's
booking date): the remittance +4670[c] A / -5120 A and, when A - P > 0, the client advance
+4679 X / -4670[c] X ‖ +4112[c] X / -4689 X, with the pending queue's -A row (the 4670 trigger
skips remittance entries) and the advance's +X row: net -P (I14). No amount is ever estimated:
every input is read from the ledger and the queue."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime


@dataclass(frozen=True, slots=True)
class PoolItem:
    """One ledger entry of a part's pool (a cancelled run's released line, a returned x's
    payout_returned item, or — review M2c-6b-3a-2 round 1, DP-3 — the payout_returned item of a
    transfer of its run's payout chain, a late predecessor's return among them: the pool is built in
    SQL and given here), as the queue holds it now."""

    entry_id: str
    posted_at: datetime
    pending: int | None  # its private.remittance_pending row's amount; None when it has none
    reverses: str | None  # the entry it reverses, when it is a reversal
    reversal_pending: int  # the pending row of the entry reversing it (0: none)
    paid: int  # Σ private.unplanned_paid_item of unreversed bookings
    own: bool  # private.unplanned_own_item: an unplanned row or its advance (ML-1)
    # M2c-6b-3a-2 (J): an unreversed unplanned booking of another transfer attributed it
    paid_by_other: bool = False

    @property
    def eligible(self) -> bool:
        return self.pending is not None and not self.own

    @property
    def net(self) -> int:
        return (self.pending or 0) + self.reversal_pending


@dataclass(frozen=True, slots=True)
class UnplannedAsk:
    """One unplanned payout part of a call: its amount A, its client, and its transfer's pool
    (None: a client part, Q8 — no items, P = 0); `prior`, what the earlier unreversed unplanned
    bookings of the same transfer netted (their A - advance; review money-2)."""

    amount: int
    client: str
    pool: tuple[str, ...] | None
    prior: int = 0
    # M2c-6b-3a-2 (J): the part's transfer (another transfer's attributions count 0)
    transfer: str | None = None


@dataclass(frozen=True, slots=True)
class PartP:
    p: int
    advance: int
    bound: str  # none | amount | items | queue (ML-9)
    attribution: tuple[tuple[str, int], ...]


def unplanned_p(
    asks: Sequence[UnplannedAsk], items: Mapping[str, PoolItem], queue: Mapping[str, int]
) -> list[PartP]:
    """P, the advance, the bound and the attribution of each part, in the parts' order."""
    attributed: dict[str, int] = {}
    by: dict[str, set[str | None]] = {}  # the transfers of this call's parts that attributed each
    used: dict[str, int] = {}
    out: list[PartP] = []
    for ask in asks:
        if ask.pool is None:
            out.append(PartP(0, ask.amount, "none", ()))
            continue
        el = [items[i] for i in dict.fromkeys(ask.pool) if items[i].eligible]
        ids = {i.entry_id for i in el}
        el = [i for i in el if not (i.reverses is not None and i.reverses in ids)]
        left = {i.entry_id: i.net - i.paid - attributed.get(i.entry_id, 0) for i in el}
        for i in el:
            if i.paid_by_other or any(t != ask.transfer for t in by.get(i.entry_id, ())):
                left[i.entry_id] = min(0, left[i.entry_id])  # J: netted by another transfer already
        cap = min(max(0, sum(left.values())), max(0, ask.amount - ask.prior))
        q = max(0, queue.get(ask.client, 0)) - used.get(ask.client, 0)
        p = max(0, min(ask.amount, q, cap))
        shares: list[tuple[str, int]] = []
        rest = p
        for i in sorted(el, key=lambda i: (i.posted_at, i.entry_id)):
            if rest <= 0:
                break
            if left[i.entry_id] > 0:
                take = min(left[i.entry_id], rest)
                shares.append((i.entry_id, take))
                rest -= take
        for e, a in shares:
            attributed[e] = attributed.get(e, 0) + a
            by.setdefault(e, set()).add(ask.transfer)
        used[ask.client] = used.get(ask.client, 0) + p
        bound = "none" if not el else "amount" if p == ask.amount else None
        bound = bound or ("items" if p == cap else "queue")
        out.append(PartP(p, ask.amount - p, bound, tuple(shares)))
    return out


@dataclass(frozen=True, slots=True)
class Posted:
    entries: dict[str, list[tuple[str, int]]]  # entry → (book, + debit / - credit)
    pending_net: int  # what the client's pending queue moves by


def unplanned_entries(amount: int, p: int) -> Posted:
    """The entries one unplanned payout of A posts with this P (§3.6.2, §3.6.3, §3.7)."""
    x = amount - p
    entries = {
        "remittance": [("client_payable", amount), ("client_money_cash", -amount)],
    }
    if x > 0:
        entries["client_advance"] = [
            ("due_to_servicer", x),
            ("client_payable", -x),
            ("client_advance_receivable", x),
            ("due_from_client_funds", -x),
        ]
    return Posted(entries, -amount + x)
