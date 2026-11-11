"""A remittance run's draft from its facts (design §9.4 step 2; ADR-0014 M2c-4). Pure.

The prepare job loads the facts — the items the draft reserved, their payments, files and terms, the
tier history and the invoices' open charges, the client's open documents — and this module prices
them: R124-6 deadlines (`deadline`), commission (`commission.compute`), documents
(`documents.run_documents`) with their French designations, the settlement plan (`settlement.plan`),
the totals, the payout and commission blockers and the inputs hash. The job writes the result as
the run's draft; the approval freezes it.

* **The commission is pending** for the whole run when a reason keeps it (the servicer's identity
  incomplete, the client no longer a mainland professional, a version without its clause references)
  or when the engine cannot price the lines (`CommissionInputError`, e.g. a same-run reversal that
  does not mirror its collection; ADR-0014 M2c-3 « For M2c-4 »): the run remits gross, its lines
  keep state `pending` and a later run prices them with its own lines (their pricing is that run's).
  The approval takes such a draft (M2c-5b review round 2: no refusal of its own); one prepared while
  a manual credit note committed is sent back by `history_changed` (the history's position is read
  first), so only a persistent data error — e.g. a key I22 flags — remits gross this way.
* **Lines of earlier runs left pending** are priced with the run's own lines (posting order) and
  their pricing is returned apart (`Draft.repricing`): their money was remitted already.
* **Deadlines**: one per distinct (E, delay), for the positive collections (allocations and
  forwards); E the payment's (a reversal carries its collection's); the delay the mandate version's
  on E, one month without one.
* **A paired line** (a collection undone in its own run under `credit`) is stored with commission 0
  and no parts; the engine never prices it.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal
from typing import Any

from collectoo_worker.payments.receipts import format_date, format_money
from collectoo_worker.remittance.calendar import Calendar, conservative
from collectoo_worker.remittance.commission import (
    ENGINE_VERSION,
    NEVER_COMMISSIONED,
    REGULARISATION_LABEL_FR,
    CommissionInputError,
    FileFacts,
    KeyState,
    Line,
    LineCommission,
    LineInvoices,
    LineKind,
    Part,
    TermsVersion,
    compute,
)
from collectoo_worker.remittance.deadline import RemittanceDeadline, remittance_deadline
from collectoo_worker.remittance.documents import (
    REVERSAL,
    CreditCause,
    EarlierCharge,
    EarlierInvoice,
    InvoiceLine,
    MandateDocuments,
    run_documents,
)
from collectoo_worker.remittance.settlement import (
    NO_MANDATE,
    Clauses,
    OpenDocument,
    RunCredit,
    SettlementPlan,
    check,
    new_credit_note_ref,
    new_invoice_ref,
    plan,
)
from collectoo_worker.remittance.terms import CommissionSchedule

NBSP = "\u00a0"
ONE_MONTH_DAYS = 30  # no terms on E: R124-6's « un mois » (the delay is at most 30 days anyway)
COLLECTIONS = frozenset({LineKind.ALLOCATION, LineKind.FORWARD})
LATE = (1 << 30,)  # the run's own documents come after every earlier one


@dataclass(frozen=True)
class Item:
    """A remittance item: one entry that moved the client's 4670 (design §9.1)."""

    entry_id: str
    kind: LineKind
    amount_minor: int
    posted_at: datetime
    effective_date: date
    account_id: str | None = None
    portfolio_id: str | None = None
    payment_id: str | None = None
    encaissement_date: date | None = None
    basis: Mapping[str, int] = field(default_factory=dict)
    forward_reason: str | None = None
    original_entry_id: str | None = None


@dataclass(frozen=True)
class PendingLine:
    """A line of an earlier run whose commission was left pending."""

    run_id: str
    line_no: int
    item: Item


@dataclass(frozen=True)
class Terms:
    """A `mandate_terms` version as the run reads it."""

    id: str
    mandate_id: str
    valid_from: date
    valid_to: date | None
    max_days: int
    schedule: Mapping[str, Any] | None
    remittance_terms: Mapping[str, Any] | None
    commission_clause_ref: str | None
    remittance_clause_ref: str | None

    def covers(self, day: date) -> bool:
        return self.valid_from <= day and (self.valid_to is None or day < self.valid_to)

    @property
    def complete(self) -> bool:
        return bool(self.schedule and self.commission_clause_ref and self.remittance_clause_ref)


@dataclass(frozen=True)
class OpenInvoiceRow:
    """An earlier document of the client with what is still open (settlement sub-ledger)."""

    id: str
    mandate_id: str
    kind: str  # invoice | credit_note
    number: str
    issue_date: date
    order: tuple[int, int]  # (year, seq)
    open_minor: int  # an invoice's TTC not settled; a credit note's refund still owed
    pending_vat_minor: int = 0


@dataclass(frozen=True)
class Facts:
    run_id: str
    number: str
    client_id: str
    currency: str
    known_at: datetime
    today: date
    service_from: date | None
    service_to: date | None
    vat_rate: Decimal
    vat_on_debits: bool
    items: Sequence[Item]
    pending_lines: Sequence[PendingLine]
    files: Mapping[str, FileFacts]
    mandate_refs: Mapping[str, str]
    terms: Mapping[str, Sequence[Terms]]  # per mandate
    history: Mapping[tuple[str, str], KeyState]
    history_seq: int
    charges: Mapping[tuple[str, str], Sequence[EarlierCharge]]
    invoices: Mapping[str, EarlierInvoice]
    invoice_numbers: Mapping[str, tuple[str, date]]  # earlier invoice → (number, issue date)
    line_invoices: LineInvoices  # an earlier line → the invoice(s) charging it (corrective first)
    open_documents: Sequence[OpenInvoiceRow]
    payout_blockers: Sequence[str]
    commission_blockers: Sequence[str]
    payout_account_id: str | None = None
    proceeding_opened_on: date | None = None  # §9.6: documents before it are not netted


@dataclass(frozen=True)
class DraftLine:
    line_no: int
    item: Item
    mandate_id: str | None
    terms_id: str | None
    deadline: RemittanceDeadline | None
    commission_minor: int
    state: str  # charged | pending | none
    reason: str | None
    parts: tuple[Part, ...]
    invoiced: bool


@dataclass(frozen=True)
class Draft:
    lines: tuple[DraftLine, ...]
    repricing: tuple[tuple[PendingLine, LineCommission, bool], ...]  # (line, its pricing, invoiced)
    documents: tuple[dict[str, Any], ...]
    key_states: tuple[dict[str, Any], ...]
    plan: SettlementPlan
    header: dict[str, Any]


class _Calendar:
    """Deadlines cached per (E, delay)."""

    def __init__(self, cal: Calendar) -> None:
        self.cal = cal
        self.cache: dict[tuple[date, int], RemittanceDeadline] = {}

    def deadline(self, e: date, days: int) -> RemittanceDeadline:
        k = (e, days)
        found = self.cache.get(k)
        if found is None:
            found = self.cache[k] = remittance_deadline(e, days, self.cal)
        return found


def _terms_on(facts: Facts, mandate: str | None, day: date | None) -> Terms | None:
    if mandate is None or day is None:
        return None
    return next((t for t in facts.terms.get(mandate, ()) if t.covers(day)), None)


def _line(item: Item, files: Mapping[str, FileFacts]) -> Line:
    """The engine's line; a file with no mandate is no file for the commission (`none`)."""
    return Line(
        entry_id=item.entry_id,
        kind=item.kind,
        account_id=item.account_id if item.account_id in files else None,
        encaissement_date=item.encaissement_date or item.effective_date,
        effective_date=item.effective_date,
        posted_at=item.posted_at,
        amount_minor=item.amount_minor,
        basis=dict(item.basis),
        forward_reason=item.forward_reason,
        original_entry_id=item.original_entry_id,
    )


def _versions(facts: Facts) -> dict[str, list[TermsVersion]]:
    out: dict[str, list[TermsVersion]] = {}
    for mandate, rows in facts.terms.items():
        out[mandate] = [
            TermsVersion(
                t.id,
                mandate,
                t.valid_from,
                t.valid_to,
                CommissionSchedule.model_validate(t.schedule),
            )
            for t in rows
            if t.schedule is not None
        ]
    return out


def _pending_reasons(facts: Facts, items: Sequence[Item]) -> list[str]:
    reasons = list(facts.commission_blockers)
    for item in items:
        file = facts.files.get(item.account_id) if item.account_id else None
        t = _terms_on(facts, file.mandate_id if file else None, item.encaissement_date)
        if t is not None and not t.complete:
            reasons.append("commission_terms_incomplete")
            break
    return reasons


def prepare_run(facts: Facts, cal: Calendar | None = None) -> Draft:
    """The draft of a run from its facts (see the module's docstring)."""
    deadlines = _Calendar(cal or conservative())
    items = sorted(facts.items, key=lambda i: (i.posted_at, i.entry_id))
    repriced = sorted(facts.pending_lines, key=lambda p: (p.item.posted_at, p.item.entry_id))
    all_items = [p.item for p in repriced] + items
    versions = _versions(facts)
    reasons = _pending_reasons(facts, all_items)
    results: dict[str, LineCommission] = {}
    docs: dict[str, MandateDocuments] = {}
    history_after: dict[tuple[str, str], KeyState] = {}
    engine_hash = ""
    if not reasons:
        try:
            result = compute(
                [_line(i, facts.files) for i in all_items],
                facts.files,
                versions,
                facts.history,
                facts.vat_rate,
                charges=facts.charges,
                line_invoices=facts.line_invoices,
            )
            docs = run_documents(
                result.lines,
                facts.files,
                facts.charges,
                facts.invoices,
                facts.vat_rate,
                facts.line_invoices,
            )
            results = {lc.entry_id: lc for lc in result.lines}
            history_after = result.history
            engine_hash = result.inputs_hash
        except CommissionInputError as exc:
            reasons = [f"commission_input_error: {exc}"[:200]]
            results, docs, history_after = {}, {}, {}
    invoiced = {e for d in docs.values() if d.invoice for e in d.invoice.entries}

    def priced(item: Item) -> tuple[int, str, str | None, tuple[Part, ...], str | None, str | None]:
        file = facts.files.get(item.account_id) if item.account_id else None
        mandate = file.mandate_id if file else None
        lc = results.get(item.entry_id)
        if lc is None:  # the commission is pending (or the line never earns any)
            t = _terms_on(facts, mandate, item.encaissement_date)
            if item.kind in NEVER_COMMISSIONED:
                return 0, "none", "not_commissionable", (), mandate, t.id if t else None
            return 0, "pending", reasons[0] if reasons else None, (), mandate, t.id if t else None
        state = "charged" if lc.state == "charged" else "none"
        return (
            lc.commission_minor,
            state,
            lc.reason,
            lc.parts,
            lc.mandate_id or mandate,
            lc.terms_id,
        )

    lines = []
    for n, item in enumerate(items, start=1):
        commission, state, reason, parts, mandate, terms_id = priced(item)
        dl = None
        if (
            item.kind in COLLECTIONS
            and item.amount_minor > 0
            and item.encaissement_date is not None
        ):
            t = _terms_on(facts, mandate, item.encaissement_date)
            dl = deadlines.deadline(item.encaissement_date, t.max_days if t else ONE_MONTH_DAYS)
        lines.append(
            DraftLine(
                n,
                item,
                mandate,
                terms_id,
                dl,
                commission,
                state,
                reason,
                parts,
                item.entry_id in invoiced,
            )
        )
    repricing = []
    if results:
        for p in repriced:
            lc = results[p.item.entry_id]
            repricing.append((p, lc, p.item.entry_id in invoiced))

    documents = _documents(facts, docs)
    the_plan = _plan(facts, lines, repriced, docs, documents)
    check(the_plan)
    _apply_plan(facts, documents, the_plan)
    touched = {(p.account_id, p.tier_key) for lc in results.values() for p in lc.parts}
    # what the waivers of manual credit notes absorb of the run's credits, per key (M2c-5b): written
    # with the key's state at approval (no document carries it)
    absorbed: dict[tuple[str, str], list[list[str]]] = {}
    for d in docs.values():
        for w in d.absorbed:
            absorbed.setdefault((w.account_id, w.tier_key), []).append(
                [w.invoice_id, str(w.amount_minor), w.entry_id]
            )
    key_states = tuple(
        {
            "account_id": k[0],
            "tier_key": k[1],
            "basis": [[vid, str(b)] for vid, b in history_after[k].basis],
            "kept_basis": str(history_after[k].kept_basis_minor),
            "kept": str(history_after[k].kept_minor),
            "commission": str(history_after[k].commission_minor),
            "waived": str(history_after[k].waived_minor),
            "absorbed": absorbed.get(k, []),
        }
        for k in sorted(touched)
        if k in history_after
    )
    header = _header(facts, lines, documents, the_plan, reasons, engine_hash, key_states)
    return Draft(tuple(lines), tuple(repricing), tuple(documents), key_states, the_plan, header)


# -- documents ------------------------------------------------------------------------------------


def percent(rate: str) -> str:
    """« 15 % », « 5,5 % » from a rate as written ("0.1500", "0.055")."""
    pct = (Decimal(rate) * 100).normalize()
    text = f"{pct:f}".replace(".", ",")
    return f"{text}{NBSP}%"


def _money(minor: int) -> str:
    return format_money(minor, 2, "EUR")


def designation(facts: Facts, mandate: str, line: InvoiceLine) -> str:
    """The precise designation of an invoice line (CGI ann. II 242 nonies A 8°): the service, the
    rule, the base collected in each band and its rate, the period, the mandate and the run."""
    period = f"du {format_date(facts.service_from)} au {format_date(facts.service_to)}"
    ref = f"(mandat {facts.mandate_refs.get(mandate, mandate)}, relevé {facts.number})"
    if line.kind == "regularisation":
        return f"{line.label_fr} — encaissements {period} {ref}"
    bands = " puis ".join(f"{percent(r)} sur {_money(b)}" for r, b in line.tiers) or "—"
    return (
        f"Commission de recouvrement amiable — {line.label_fr} — {bands} encaissés {period} {ref}"
    )


def _clauses(facts: Facts, mandate: str) -> tuple[Clauses, str | None, int]:
    t = _terms_on(facts, mandate, facts.today)
    rt = (t.remittance_terms if t else None) or {}
    netting = rt.get("netting")
    clawback = rt.get("clawback")
    return (
        Clauses(netting=netting is not None, clawback=clawback is not None),
        netting["clause_ref"] if netting else None,
        int(rt.get("invoice_payment_days", 30)),
    )


def _documents(facts: Facts, docs: Mapping[str, MandateDocuments]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for mandate in sorted(docs, key=lambda m: (facts.mandate_refs.get(m, m), m)):
        d = docs[mandate]
        clauses, clause_ref, days = _clauses(facts, mandate)
        if d.invoice is not None:
            inv = d.invoice
            out.append(
                {
                    "ref": new_invoice_ref(mandate),
                    "kind": "invoice",
                    "mandate_id": mandate,
                    "ht": str(inv.ht_minor),
                    "vat": str(inv.vat_minor),
                    "ttc": str(inv.ttc_minor),
                    "vat_rate": str(inv.vat_rate),
                    "settlement": "netted" if clauses.netting else "due",
                    "due_days": None if clauses.netting else days,
                    "clause_ref": clause_ref,
                    "lines": [
                        {
                            "kind": line.kind,
                            "designation_fr": designation(facts, mandate, line),
                            "claim_type": line.claim_type,
                            "rule_id": line.rule_id,
                            "families": list(line.families),
                            "tiers": [[r, str(b)] for r, b in line.tiers],
                            "ht": str(line.ht_minor),
                            "vat_rate": str(inv.vat_rate),
                        }
                        for line in inv.lines
                    ],
                    "charges": [
                        {"account_id": k[0], "tier_key": k[1], "amount": str(a)}
                        for k, a in inv.charges
                    ],
                }
            )
        if d.credit_note is not None:
            cn = d.credit_note
            out.append(
                {
                    "ref": new_credit_note_ref(mandate),
                    "kind": "credit_note",
                    "mandate_id": mandate,
                    "ht": str(cn.ht_minor),
                    "vat": str(cn.vat_minor),
                    "ttc": str(cn.ttc_minor),
                    "vat_rate": None,
                    "settlement": "netted",
                    "clause_ref": clause_ref,
                    "lines": [  # one per corrected invoice and cause (289 I 5, 272 1)
                        {
                            "kind": "credit",
                            "designation_fr": _credit_designation(facts, c.invoice_id, cause),
                            "ht": str(ht),
                            "vat_rate": str(c.vat_rate),
                            "original_invoice_id": c.invoice_id,
                        }
                        for c in cn.corrected
                        for cause, ht in (c.causes or ((REVERSAL, c.ht_minor),))
                    ],
                    "allocations": [
                        {
                            "original_invoice_id": a.original_invoice_id,
                            "account_id": a.account_id,
                            "tier_key": a.tier_key,
                            "ht": str(a.ht_minor),
                            "entry_id": a.entry_id,
                        }
                        for a in cn.allocations
                    ],
                    "corrections": [
                        {
                            "original_invoice_id": c.invoice_id,
                            "vat_rate": str(c.vat_rate),
                            "ht": str(c.ht_minor),
                            "vat": str(c.vat_minor),
                        }
                        for c in cn.corrected
                    ],
                }
            )
    return out


def _credit_designation(facts: Facts, invoice_id: str, cause: CreditCause = REVERSAL) -> str:
    """A credit line names the invoice it corrects and why (289 I 5; 272 1): collections undone,
    or the tiers a change of terms moved (no collection undone: legal review M2c-4)."""
    number, issued = facts.invoice_numbers.get(invoice_id, (invoice_id, facts.today))
    why = "encaissements annulés" if cause == REVERSAL else REGULARISATION_LABEL_FR
    return (
        f"Avoir rectifiant la facture {number} du {format_date(issued)} — {why} "
        f"(relevé {facts.number})"
    )


# -- the settlement plan --------------------------------------------------------------------------


def _plan(
    facts: Facts,
    lines: Sequence[DraftLine],
    repriced: Sequence[PendingLine],
    docs: Mapping[str, MandateDocuments],
    documents: Sequence[Mapping[str, Any]],
) -> SettlementPlan:
    # the lines of earlier runs priced now: their money was remitted with their own runs
    gross: dict[str, int] = {}
    for line in lines:
        m = line.mandate_id or NO_MANDATE
        gross[m] = gross.get(m, 0) + line.item.amount_minor
    invoices: list[OpenDocument] = []
    refunds: list[OpenDocument] = []
    opening = facts.proceeding_opened_on
    for row in facts.open_documents:
        if row.kind == "invoice":
            # L622-7 I (OQ-41): a document dated before the client's proceeding opened is not set
            # off; it stays due for ops to declare (a credit note still corrects it)
            nettable = opening is None or row.issue_date >= opening
            invoices.append(
                OpenDocument(
                    row.id,
                    row.mandate_id,
                    row.order,
                    row.open_minor,
                    row.pending_vat_minor,
                    nettable,
                )
            )
        elif row.open_minor > 0:
            refunds.append(OpenDocument(row.id, row.mandate_id, row.order, row.open_minor))
    credits = []
    for doc in documents:
        mandate = str(doc["mandate_id"])
        if doc["kind"] == "invoice":
            vat = 0 if facts.vat_on_debits else int(doc["vat"])
            invoices.append(
                OpenDocument(new_invoice_ref(mandate), mandate, LATE, int(doc["ttc"]), vat)
            )
        else:
            for c in doc["corrections"]:
                credits.append(
                    RunCredit(
                        new_credit_note_ref(mandate),
                        str(c["original_invoice_id"]),
                        mandate,
                        -(int(c["ht"]) + int(c["vat"])),
                        -int(c["vat"]),
                    )
                )
    del docs, repriced
    clauses = {m: _clauses(facts, m)[0] for m in gross if m != NO_MANDATE}
    return plan(gross, invoices, refunds, [], credits, clauses)


def _apply_plan(facts: Facts, documents: Sequence[dict[str, Any]], p: SettlementPlan) -> None:
    """Each credit note's corrections get their VAT split and applied part (the plan's), and the
    corrected invoice's open part the plan assumed (the approval checks it is unchanged)."""
    apps = {(a.credit_ref, a.invoice_ref): a for a in p.applications}
    opened = {row.id: row.open_minor for row in facts.open_documents}
    for doc in documents:
        if doc["kind"] != "credit_note":
            continue
        ref = new_credit_note_ref(str(doc["mandate_id"]))
        for c in doc["corrections"]:
            a = apps[(ref, str(c["original_invoice_id"]))]
            c["vat_pending"] = str(a.vat_pending_minor)
            c["vat_collected"] = str(a.vat_collected_minor)
            c["applied"] = str(a.applied_minor)
            c["excess"] = str(a.excess_minor)
            c["open_before"] = str(opened.get(str(c["original_invoice_id"]), 0))


def _header(  # noqa: PLR0913, PLR0917 - the draft's totals and identity
    facts: Facts,
    lines: Sequence[DraftLine],
    documents: Sequence[Mapping[str, Any]],
    p: SettlementPlan,
    reasons: Sequence[str],
    engine_hash: str,
    key_states: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    inv = [d for d in documents if d["kind"] == "invoice"]
    cn = [d for d in documents if d["kind"] == "credit_note"]
    dated = [ln.deadline for ln in lines if ln.deadline is not None]
    blockers = list(facts.payout_blockers) + list(p.blockers)
    hashed = {
        "engine": engine_hash,
        "run": facts.run_id,
        "known_at": facts.known_at.isoformat(),
        "vat_rate": str(facts.vat_rate),
        "items": sorted(
            (i.entry_id, i.amount_minor, str(i.encaissement_date)) for i in facts.items
        ),
        "repriced": sorted(p.item.entry_id for p in facts.pending_lines),
        "documents": documents,
        "plan": {
            "net": p.net_minor,
            "settlement": p.settlement_minor,
            "settles": [(s.ref, s.kind, s.amount_minor, s.vat_moved_minor) for s in p.settles],
        },
        "open": sorted((d.id, d.open_minor, d.pending_vat_minor) for d in facts.open_documents),
        "blockers": blockers,
        "commission": list(reasons),
        "payout_account": facts.payout_account_id,
        "history_seq": facts.history_seq,
        "keys": list(key_states),
        "vat_on_debits": facts.vat_on_debits,
        "proceeding_opened_on": str(facts.proceeding_opened_on),
    }
    digest = hashlib.sha256(json.dumps(hashed, sort_keys=True, default=str).encode()).hexdigest()
    return {
        "line_count": len(lines),
        "gross": str(sum(ln.item.amount_minor for ln in lines)),
        "invoice_ht": str(sum(int(d["ht"]) for d in inv)),
        "invoice_vat": str(sum(int(d["vat"]) for d in inv)),
        "invoice_ttc": str(sum(int(d["ttc"]) for d in inv)),
        "credit_ht": str(-sum(int(d["ht"]) for d in cn)),
        "credit_vat": str(-sum(int(d["vat"]) for d in cn)),
        "credit_ttc": str(-sum(int(d["ttc"]) for d in cn)),
        "taken": str(p.commission_taken_minor),
        "advances": str(p.advances_taken_minor),
        "refunds": str(p.refunds_paid_minor),
        "settlement": str(p.settlement_minor),
        "net": str(p.net_minor),
        "vat_rate": str(facts.vat_rate),
        "earliest_deadline": min((d.deadline for d in dated), default=None),
        "earliest_latest_execution_date": min((d.latest_execution for d in dated), default=None),
        "unmeetable": sum(1 for d in dated if d.unmeetable),
        "blockers": blockers,
        "commission_blockers": list(reasons),
        "engine_version": ENGINE_VERSION,
        "inputs_hash": digest,
        "payout_account_id": facts.payout_account_id,
        "history_seq": facts.history_seq,
        # what the plan assumed: the approval sends the draft back when either changed
        "vat_on_debits": facts.vat_on_debits,
        "proceeding_opened_on": facts.proceeding_opened_on,
    }
