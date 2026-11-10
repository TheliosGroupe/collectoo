"""The settlement plan of a remittance run (design §9.6; founder #3, #7; ADR-0014 M2c-4). Pure.

Computed at prepare, re-checked at approval (each document's open amount as the plan assumed it),
posted at the payout's debit (M2c-6) — or at approval when nothing is transferred (N = 0).

Per mandate m of the client:

    gross_m    = Σ the run's lines of m (signed)
    excess_m   = refunds owed to the client on m: what the run's credit notes take back beyond the
                 open part of the invoices they correct, plus earlier refunds not yet paid
    avail_m    = gross_m + excess_m
    take_m     = netting clause ? min(open invoices of m after the credit notes, oldest first;
                                      max(0, avail_m)) : 0
    take_adv_m = claw-back clause ? min(open advances of m, oldest first;
                                        max(0, avail_m - take_m)) : 0
    net_m      = avail_m - take_m - take_adv_m
    D_m        = take_m + take_adv_m - excess_m
    N = Σ net_m ; D = Σ D_m ; N + D = gross

* **A credit note first reduces the invoices it corrects** (a price correction, CGI 289 I 5, not a
  compensation): on each corrected invoice it applies up to the invoice's open part; the rest is a
  refund owed, always paid with the payout. Its VAT comes off the invoice's pending VAT first
  (44574), the rest off the VAT already due (44571) — « the pending part of the corrected invoices
  first » (§5.2).
* **VAT moved** to due (44571) on a settled part = R(pending VAT x part / open part); the part that
  closes a document moves all of its pending VAT. A document closed with VAT still pending (a cent
  of rounding between the credit note's and the invoice's VAT) moves it with the next settlement.
* **Across mandates** a mandate's commission or advance is taken only from its own money
  (max(0, avail_m)); a mandate whose reversals exceed what it brought in draws on the client's
  other money, so the takes are then reduced (advances first, last mandate first) until N ≥ 0.
* **Nothing to settle through client money** (D = 0, e.g. a refund owed equal to the invoice it
  would compensate): no settlement entry can carry a VAT move alone, so the run settles nothing
  (takes and refunds left for the next run, N = gross); the credit notes still apply.
* A run whose gross (with the refunds owed) is negative is not approved (`negative_net`: wait for a
  later collection or, from M2c-6, the payout in flight).

Amounts are integer minor units; refs name documents: an earlier one by its id, the run's own as
`new:<mandate>` (its invoice) or `new_cn:<mandate>` (its credit note), resolved at approval.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Literal

from collectoo_worker.remittance.vat import div_half_up

NO_MANDATE = ""  # lines with no mandate (a forward of a payment on no file): remitted gross


def new_invoice_ref(mandate_id: str) -> str:
    return f"new:{mandate_id}"


def new_credit_note_ref(mandate_id: str) -> str:
    return f"new_cn:{mandate_id}"


@dataclass(frozen=True)
class OpenDocument:
    """An invoice, a refund owed on a credit note, or an advance, with what is still open."""

    ref: str
    mandate_id: str
    order: tuple[int, ...]  # oldest first (the run's new invoice after every earlier one)
    open_minor: int  # TTC not yet settled (≥ 0)
    pending_vat_minor: int = 0  # an invoice: the VAT of the open part still pending (44574)
    nettable: bool = True  # False: not set off (dated before the client's proceeding, L622-7 I)


@dataclass(frozen=True)
class RunCredit:
    """What a credit note of the run takes back from one earlier invoice (magnitudes)."""

    credit_ref: str
    invoice_ref: str
    mandate_id: str
    ttc_minor: int
    vat_minor: int


@dataclass(frozen=True)
class Clauses:
    netting: bool  # the mandate's netting clause (founder #3)
    clawback: bool  # its claw-back clause (founder #7)


@dataclass(frozen=True)
class Application:
    """A credit note of the run applied to an invoice it corrects."""

    credit_ref: str
    invoice_ref: str
    mandate_id: str
    applied_minor: int  # TTC off the invoice's open part
    excess_minor: int  # TTC beyond it: a refund owed to the client
    vat_pending_minor: int  # VAT taken back from 44574 (v₁)
    vat_collected_minor: int  # and from 44571 (v₂)


@dataclass(frozen=True)
class Settle:
    """A document settled by the run (one `commission_settlement` row)."""

    ref: str
    mandate_id: str
    kind: Literal["compensation", "refund", "advance"]
    amount_minor: int  # TTC (≥ 0; 0 only to move a closed document's pending VAT)
    vat_moved_minor: int  # VAT moved from pending to due (44574 → 44571)
    open_before_minor: int  # the document's open part the plan assumed (checked at approval)


@dataclass(frozen=True)
class MandatePlan:
    mandate_id: str
    gross_minor: int
    excess_minor: int
    take_minor: int
    take_advance_minor: int
    net_minor: int
    settlement_minor: int  # D_m


@dataclass(frozen=True)
class SettlementPlan:
    mandates: tuple[MandatePlan, ...]
    applications: tuple[Application, ...]
    settles: tuple[Settle, ...]
    gross_minor: int
    net_minor: int  # N
    settlement_minor: int  # D
    commission_taken_minor: int  # Σ take (TTC)
    advances_taken_minor: int  # Σ take_adv
    refunds_paid_minor: int  # Σ excess
    vat_moved_minor: int
    deferred: bool = False  # D = 0: nothing settled this run
    blockers: tuple[str, ...] = ()

    @property
    def commission_settled_minor(self) -> int:
        """Dc: what the settlement credits 4111 (negative: a refund owed paid)."""
        return self.commission_taken_minor - self.refunds_paid_minor


@dataclass
class _Doc:
    doc: OpenDocument
    open_minor: int
    pending: int
    taken: list[tuple[int, int]] = field(default_factory=list)


class SettlementInputError(ValueError):
    """Inputs the plan cannot settle (a data error)."""


def vat_part(pending: int, open_minor: int, take: int) -> int:
    """The pending VAT a settled part moves: all of it when the part closes the document."""
    if take >= open_minor:
        return pending
    return div_half_up(pending * take, open_minor) if open_minor else 0


def plan(  # noqa: PLR0913, PLR0917 - the run's gross and the client's open documents
    gross: Mapping[str, int],
    invoices: Sequence[OpenDocument],
    refunds: Sequence[OpenDocument],
    advances: Sequence[OpenDocument],
    credits: Sequence[RunCredit],
    clauses: Mapping[str, Clauses],
) -> SettlementPlan:
    """The plan of one run. `gross` per mandate (NO_MANDATE for lines with none); `invoices` the
    client's open invoices, the run's own included (`new:<mandate>`); `refunds` earlier credit
    notes' refunds not yet paid; `advances` open advances; `credits` what the run's credit notes
    take back per corrected invoice; `clauses` per mandate (absent: neither clause)."""
    for d in (*invoices, *refunds, *advances):
        if (
            d.open_minor < 0
            or d.pending_vat_minor < 0
            or (d.open_minor and d.pending_vat_minor > d.open_minor)
        ):
            raise SettlementInputError(f"{d.ref}: an open part and its pending VAT are ≥ 0")
    docs = {d.ref: _Doc(d, d.open_minor, d.pending_vat_minor) for d in invoices}
    applications, owed = _apply_credits(docs, refunds, credits)
    excess: dict[str, int] = defaultdict(int)
    for r in owed:
        excess[r.mandate_id] += r.open_minor
    mandates = sorted(set(gross) | set(excess))
    take, take_adv = _takes(mandates, gross, excess, docs, advances, clauses)
    taken = sum(t for m in mandates for _, t in take[m])
    taken_adv = sum(t for m in mandates for _, t in take_adv[m])
    deferred = taken + taken_adv == sum(excess.values()) and bool(taken or taken_adv or owed)
    if deferred:  # nothing moves through client money: settle nothing now
        take = {m: [] for m in mandates}
        take_adv = {m: [] for m in mandates}
        taken = taken_adv = 0
        excess = defaultdict(int)
        owed = []
    settles = _settles(mandates, take, take_adv, owed, docs, any_entry=not deferred)
    out = []
    for m in mandates:
        g, e = gross.get(m, 0), excess.get(m, 0)
        t = sum(x for _, x in take[m])
        a = sum(x for _, x in take_adv[m])
        out.append(MandatePlan(m, g, e, t, a, g + e - t - a, t + a - e))
    net = sum(p.net_minor for p in out)
    return SettlementPlan(
        mandates=tuple(out),
        applications=tuple(applications),
        settles=tuple(settles),
        gross_minor=sum(gross.values()),
        net_minor=net,
        settlement_minor=sum(p.settlement_minor for p in out),
        commission_taken_minor=taken,
        advances_taken_minor=taken_adv,
        refunds_paid_minor=sum(excess.values()),
        vat_moved_minor=sum(s.vat_moved_minor for s in settles),
        deferred=deferred,
        blockers=("negative_net",) if net < 0 else (),
    )


def _apply_credits(
    docs: dict[str, _Doc], refunds: Sequence[OpenDocument], credits: Sequence[RunCredit]
) -> tuple[list[Application], list[OpenDocument]]:
    """Each credit of the run on the invoice it corrects (up to its open part, VAT off the pending
    part first); what is beyond is owed to the client. Returns the applications and every refund
    owed (earlier ones and the run's credit notes'), oldest first."""
    applications = []
    owed: dict[str, OpenDocument] = {r.ref: r for r in refunds}
    for c in credits:
        if c.ttc_minor < 0 or c.vat_minor < 0 or c.vat_minor > c.ttc_minor:
            raise SettlementInputError(f"{c.credit_ref}: a credit's TTC and VAT are magnitudes")
        inv = docs.get(c.invoice_ref)
        applied = min(c.ttc_minor, inv.open_minor if inv else 0)
        v1 = min(c.vat_minor, inv.pending if inv else 0)
        if inv is not None:
            inv.open_minor -= applied
            inv.pending -= v1
        rest = c.ttc_minor - applied
        applications.append(
            Application(
                c.credit_ref, c.invoice_ref, c.mandate_id, applied, rest, v1, c.vat_minor - v1
            )
        )
        if rest:
            prev = owed.get(c.credit_ref)
            owed[c.credit_ref] = OpenDocument(
                c.credit_ref, c.mandate_id, (1 << 30,), rest + (prev.open_minor if prev else 0)
            )
    return applications, sorted(owed.values(), key=lambda r: (r.order, r.ref))


Takes = dict[str, list[tuple[_Doc, int]]]


def _takes(  # noqa: PLR0913, PLR0917 - per mandate: its money, its documents, its clauses
    mandates: Sequence[str],
    gross: Mapping[str, int],
    excess: Mapping[str, int],
    docs: Mapping[str, _Doc],
    advances: Sequence[OpenDocument],
    clauses: Mapping[str, Clauses],
) -> tuple[Takes, Takes]:
    take: Takes = {}
    take_adv: Takes = {}
    adv_docs = [_Doc(d, d.open_minor, 0) for d in advances]
    for m in mandates:
        terms = clauses.get(m, Clauses(netting=False, clawback=False))
        room = max(0, gross.get(m, 0) + excess.get(m, 0))
        take[m] = _walk(docs.values(), m, room) if terms.netting and m != NO_MANDATE else []
        room -= sum(t for _, t in take[m])
        take_adv[m] = _walk(adv_docs, m, room) if terms.clawback and m != NO_MANDATE else []
    _cap_to_pool(mandates, gross, excess, take, take_adv)
    return take, take_adv


def _settles(  # noqa: PLR0913 - what the run settles
    mandates: Sequence[str],
    take: Takes,
    take_adv: Takes,
    owed: Sequence[OpenDocument],
    docs: Mapping[str, _Doc],
    *,
    any_entry: bool,
) -> list[Settle]:
    settles: list[Settle] = []
    for m in mandates:
        for doc, t in take[m]:
            vat = vat_part(doc.pending, doc.open_minor, t)
            settles.append(Settle(doc.doc.ref, m, "compensation", t, vat, doc.doc.open_minor))
        for doc, t in take_adv[m]:
            settles.append(Settle(doc.doc.ref, m, "advance", t, 0, doc.doc.open_minor))
    for r in owed:
        settles.append(Settle(r.ref, r.mandate_id, "refund", r.open_minor, 0, r.open_minor))
    if settles and any_entry:
        # a document closed with VAT still pending (a credit note's rounding): moved with it
        moved = {s.ref for s in settles}
        for doc in sorted(docs.values(), key=lambda x: (x.doc.order, x.doc.ref)):
            if doc.open_minor == 0 and doc.pending and doc.doc.ref not in moved:
                settles.append(
                    Settle(
                        doc.doc.ref, doc.doc.mandate_id, "compensation", 0, doc.pending,
                        doc.doc.open_minor,
                    )
                )  # fmt: skip
    return settles


def _walk(docs: Iterable[_Doc], mandate: str, room: int) -> list[tuple[_Doc, int]]:
    """Take up to `room` from the mandate's open documents, oldest first."""
    out: list[tuple[_Doc, int]] = []
    for doc in sorted(
        (d for d in docs if d.doc.mandate_id == mandate and d.open_minor > 0 and d.doc.nettable),
        key=lambda d: (d.doc.order, d.doc.ref),
    ):
        if room <= 0:
            break
        t = min(doc.open_minor, room)
        out.append((doc, t))
        room -= t
    return out


def _cap_to_pool(
    mandates: Sequence[str],
    gross: Mapping[str, int],
    excess: Mapping[str, int],
    take: dict[str, list[tuple[_Doc, int]]],
    take_adv: dict[str, list[tuple[_Doc, int]]],
) -> None:
    """When a mandate's reversals exceed what it brought in, the client's other money covers them:
    the takes are reduced (advances first, last mandate and newest document first) so that N ≥ 0
    whenever the client's money allows it."""
    pool = sum(gross.get(m, 0) + excess.get(m, 0) for m in mandates)
    over = sum(t for m in mandates for _, t in (*take[m], *take_adv[m])) - max(0, pool)
    for table in (take_adv, take):
        for m in reversed(mandates):
            kept: list[tuple[_Doc, int]] = list(table[m])
            while over > 0 and kept:
                doc, t = kept.pop()
                cut = min(t, over)
                over -= cut
                if t - cut:
                    kept.append((doc, t - cut))
                    break
            table[m] = kept
            if over <= 0:
                return


def check(p: SettlementPlan) -> None:
    """N + D = gross, every amount within its document (raises otherwise: an engine error)."""
    if p.net_minor + p.settlement_minor != p.gross_minor:
        raise SettlementInputError("N + D ≠ gross")
    for s in p.settles:
        if s.amount_minor > s.open_before_minor:
            raise SettlementInputError(f"{s.ref}: settled beyond its open part")
