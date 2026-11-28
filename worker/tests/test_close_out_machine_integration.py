"""M2c-7f-2, the full property machine (needs `make up`; plan docs/design/m2c-7f-plan.md §3 M1-M6,
docs/design/m2c-7-plan.md §8.2; ADR-0014 « M2c-7f-2 »).

A Hypothesis RuleBasedStateMachine drives one servicer (its dedicated and own accounts) and three
clients — Martin under two mandates (netting and claw-back; netting only), Lilas (netting), Durand
(no netting) — through the product's own paths (`close_out_world`), against the funds model of
`ledger_machine.FundsModel`, which computes what it expects from its own model of the queues, the
runs and their lines, the payouts, the advances, the settlements, the credits and the top-ups —
never from a SQL helper it checks (M7-MONEY-1).

Two classes:

* switch off: each step commits, as the back-office's sessions do (aal2 API sessions, the
  queues' jobs);
* switch on (`downloaded_file_cancellation`): each example runs in ONE transaction rolled back at
  its end (`close_out_world.one_transaction`: the commands as `authenticated` with the claims set
  locally, the jobs through their Python functions on that connection, the nightly with `p_today`
  advanced); the switch is never committed on, and is asserted off before and after each example.

Rules (each a no-op when it does not apply; picks follow the model's own order so that a replayed
example draws the same):

* a collection (a statement credit paying a file's invoice by its RF, matched and allocated by the
  jobs; sometimes overpaid), « Désimputer », a payment returned by the payer's bank (the debit job),
  a refund to the payer of what a payment left unallocated (in a file, debited);
* a run requested, prepared and approved (`request_remittance_run`, the prepare and approval jobs),
  cancelled before its file is handed out; the next file generated and downloaded; the bank
  debiting a payout, a refund or the sweep (its own line, or the whole file as batch lines), and
  returning a payout; a bank fee; the hourly top-up and its credit; the nightly checks.

After every step, keyed reads compare the books with the model: each client's 4670 (I14: its
pending items and its runs in flight, I13: never in debit), its queue item by item, 4111 and 4112
(I18), each reversal's covers (M2: an advance after a covering reversal, none for a same-run pair,
the at-booking cover when its run is booked), 4679, 5122, 44574 and 44571 (MONEY-11), 4710, 5120
against the bank, no live repayment request naming a reversed advance (M6). Each approval is
checked against the model's settlement plan (§9.6; M3: invoices first, then the advances oldest
first on their own mandate's money, under the claw-back clause only, never one a request names —
rules 7, 8, 13). At the end of each example the machine quiesces (every file executed and booked,
every top-up credited, the last sweep debited) and checks: the nightly checks clean, 5120 = the
bank's closing, Σ4679 = 0, each client's payouts received = its items remitted less what was set
off plus the refunds paid with them (M7-MONEY-1), every open advance alerted 30 days on (MONEY-10
`advance_open`), 5122 = what the model moved through the own account.

Macros chain the rules into the states the mutants are about, in one step each: a collection
remitted end to end, a reversal in flight (covered at the booking), a same-run pair, a claw-back
cycle, a sweep in flight then an advance, one run over two mandates (MARTIN-2 at 25 %), a client
paying part of an invoice (its VAT pro rata), a set-off barred at the debit (a liquidation recorded
between the file and the debit), and 038's f_partial (a run approved between a payout's debit and
its return: M4). The examples record what they reached (`event`, printed per class with `-s`),
among them 038's d_queue / d_twice shape (M4) and a late predecessor's return re-queued in a later
run (M5).

`test_every_check_can_fail` shows each check able to fail: after a short fixed scenario (switch on,
rolled back) it plants, one at a time, a state that breaks one check — a raw posting or reversal in
the database (rolled back to a savepoint) or one figure of the model moved — and sees that check
fail with its own message (the probes' refusals are shown failing by the X1 mutants instead).

Size from the environment: MACHINE_EXAMPLES (default 8) and MACHINE_STEPS (default 20) per class.
The switch-on class's one transaction keeps every lock its steps take until its rollback (each
call of the ledger's posting core creates its working tables anew, and a dropped table's lock is
held to the transaction's end): with Postgres's default lock table (max_locks_per_transaction 64,
100 connections) an example of 60 steps, all collections, ran out of it at about step 51 (« out of
shared memory »; ADR-0014 « M2c-7f-2 »). The PR's 20 steps and the 25 x 40 job fit; the long local
run takes the switch-on class at 40 steps.
"""

from __future__ import annotations

import contextlib
import copy
import dataclasses
import json
import os
import uuid
from collections import Counter
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import timedelta
from typing import Any

import psycopg
import pytest
from close_out_world import (
    World,
    advance_checks,
    approve,
    bank_statement,
    board_file,
    book_line,
    build_world,
    business_days_back,
    checks,
    credit_entry,
    download,
    drain_remittances,
    evidence_statement,
    fee_entry,
    file_dated_back,
    file_entries,
    live_allocations,
    one_transaction,
    own_credit_entry,
    payment_of_line,
    payment_return_entry,
    q,
    ref,
    replace_payout_account,
    request_run,
    reversal_of,
    switch_is_off,
    today,
    transfer_debit_entry,
    v,
)
from debit_helpers import refund_request
from hypothesis import HealthCheck, Phase, settings
from hypothesis import event as _hypothesis_event
from hypothesis import strategies as st
from hypothesis.errors import InvalidArgument
from hypothesis.stateful import (
    RuleBasedStateMachine,
    initialize,
    invariant,
    rule,
    run_state_machine_as_test,
)
from integration_helpers import DB
from ledger_machine import (
    FCredit,
    FDocument,
    FItem,
    FMandate,
    FPayment,
    FRun,
    FTransfer,
    FundsModel,
)
from remittance_helpers import run_row

pytestmark = pytest.mark.integration

EXAMPLES = int(os.environ.get("MACHINE_EXAMPLES", "8"))
STEPS = int(os.environ.get("MACHINE_STEPS", "20"))
CLIENTS = ("martin", "lilas", "durand")
SEEN: Counter[str] = Counter()  # what the examples reached (printed at the end: pytest -s)


def event(what: str) -> None:
    SEEN[what] += 1
    with contextlib.suppress(InvalidArgument):  # outside a Hypothesis test (the plants)
        _hypothesis_event(what)


def _books(w: World) -> dict[str, Any]:
    """The books the model is compared with, in one keyed read: per client its 4670, 4111, 4112
    and pending items; the servicer's 5120, 4710, 4679, 5122, 44574, 44571."""
    row = v(
        """select jsonb_build_object(
             'books', (select coalesce(jsonb_object_agg(x.k, x.total), '{}') from (
                 select la.book || coalesce(':' || la.client_organization_id::text, '') as k,
                        sum(p.amount_minor)::text as total
                 from public.ledger_account la
                 join public.ledger_posting p on p.ledger_account_id = la.id
                 where la.organization_id = %s
                   and la.book in ('client_payable', 'commission_receivable',
                                   'client_advance_receivable', 'client_money_cash',
                                   'client_credit_owed',
                                   'unallocated_payment', 'due_to_servicer', 'own_cash',
                                   'vat_pending', 'vat_collected')
                 group by 1) x),
             'pending', (select coalesce(jsonb_agg(jsonb_build_array(q.client_organization_id,
                                                                     q.ledger_entry_id,
                                                                     q.amount_minor)), '[]')
                         from private.remittance_pending q where q.organization_id = %s),
             'covers', (select coalesce(jsonb_object_agg(a.cause_entry_id, a.amount), '{}') from (
                 select a.cause_entry_id, sum(a.amount_minor)::text as amount
                 from public.client_advance a
                 where a.organization_id = %s and a.cause = 'remitted_reversal'
                   and not exists (select 1 from public.ledger_entry z
                                   where z.reverses_entry_id = a.entry_id)
                 group by a.cause_entry_id) a),
             'advances', (select coalesce(jsonb_object_agg(a.id, private.advance_open(a.id)), '{}')
                          from public.client_advance a where a.organization_id = %s),
             'documents', (select coalesce(jsonb_object_agg(d.id, private.document_open(d.id)),
                                           '{}')
                           from public.commission_invoice d
                           where d.organization_id = %s and d.kind = 'invoice'),
             'requested_reversed', (select count(*) from public.advance_repayment_request r
                                    join public.advance_repayment_request_item x
                                      on x.request_id = r.id
                                    join public.client_advance a on a.id = x.advance_id
                                    where r.organization_id = %s and r.withdrawn_at is null
                                      and exists (select 1 from public.ledger_entry z
                                                  where z.reverses_entry_id = a.entry_id)))""",
        w.org, w.org, w.org, w.org, w.org, w.org,
    )  # fmt: skip
    return dict(row)


def _book(b: dict[str, Any], book: str, client: str | None = None) -> int:
    key = f"{book}:{client}" if client else book
    if client is None:
        return sum(int(x) for k, x in b["books"].items() if k.split(":")[0] == book)
    return int(b["books"].get(key, 0))


class CloseOutMachine(RuleBasedStateMachine):
    """The rules and invariants of both classes (the switch-on one adds its own rules)."""

    shared = False  # one transaction per example (the switch-on class)

    def __init__(self) -> None:
        super().__init__()
        self._tx: Any = None
        self.w: World | None = None
        self.m = FundsModel()
        self.pay_files: dict[str, tuple[Any, int]] = {}  # payment -> (its file, its slot)
        self.last_file = ""  # what the last « Générer le fichier » did
        self.proof_order: list[str] = []  # the proofs' sha256, as recorded (the picks' order)
        self.failed = False  # a rule raised: teardown does not quiesce (MACH-7)
        self.collections: list[str] = []  # allocation entries, in the model's order
        self.payment_of: dict[str, str] = {}  # allocation entry -> its payment

    # -- the world ------------------------------------------------------------------------------

    @initialize()
    def world(self) -> None:
        if self.shared:
            self._tx = one_transaction()
            self._tx.__enter__()
        else:
            switch_is_off()
        self.w = build_world(shifted=self.shared)
        bank_statement(self.w, [])  # the account's first statement: its balance is known
        for s in self.w.slots:
            self.m.mandates[s.mandate] = FMandate(s.mandate, s.client, s.netting, s.clawback)
        self.clients = {n: str(self.w.clients[n]["client"]) for n in CLIENTS}
        self.slot_of_client = {
            str(t["client"]): next(s for s in self.w.slots if s.client == str(t["client"]))
            for t in self.w.clients.values()
        }

    def teardown(self) -> None:
        try:
            # (review round 1, MACH-7) after a failing rule the model is half-updated: quiescing
            # would raise another check's message and hide the real one
            if self.w is not None and not self.failed:
                self._quiesce()
        finally:
            if self._tx is not None:
                self._tx.__exit__(None, None, None)
                self._tx = None
            switch_is_off()

    # -- helpers --------------------------------------------------------------------------------

    @property
    def ww(self) -> World:
        assert self.w is not None
        return self.w

    def _sync_documents(self) -> None:
        """The documents the engine issued since (a run's, a cancellation's), into the model with
        their credit notes' applications (engine pricing: the model's input)."""
        rows = q(
            """select d.id::text, d.client_organization_id::text, d.mandate_id::text, d.kind,
                      d.ttc_minor, d.vat_minor, d.due_date, d.year, d.seq,
                      coalesce((select jsonb_agg(jsonb_build_array(s.document_id, s.amount_minor,
                                                                   s.vat_moved_minor))
                                from public.commission_settlement s
                                where s.credit_note_id = d.id and s.kind = 'credit_note'), '[]')
               from public.commission_invoice d where d.organization_id = %s
               order by d.year, d.seq, d.kind""",
            self.ww.org,
        )
        for did, client, mandate, kind, ttc, vat, due, year, seq, apps in rows:
            if did in self.m.documents:
                continue
            doc = FDocument(did, client, mandate, "invoice" if kind == "invoice" else "credit_note",
                            int(ttc), int(vat), self.m._next(),
                            due=due if kind == "invoice" and due is not None else None,
                            number=(int(year), int(seq)))  # fmt: skip
            self.m.issue(doc, [(str(a), int(b), int(c)) for a, b, c in apps])

    def _register_advances(self, reversal: str, collection: str) -> None:
        """The covers the database posted for R: into the model (their entry is a queue item)."""
        rows = q(
            """select a.id::text, a.entry_id::text, a.amount_minor, a.mandate_id::text
               from public.client_advance a
               where a.cause_entry_id = %s and a.cause = 'remitted_reversal'
               order by a.created_at""",
            reversal,
        )
        for aid, entry, amount, mandate in rows:
            if aid not in self.m.advances:
                expected = self.m.items[collection].mandate
                assert mandate == expected, ("the cover's mandate", mandate, expected)
                self.m.cover(aid, entry, reversal, int(amount), mandate)

    # -- the servicer's side --------------------------------------------------------------------

    def collect(self, slot: int, amount: int, over: int) -> None:
        w = self.ww
        s = w.slots[slot]
        f = board_file(s, amount)
        e2e = ref("E2E")
        sid = bank_statement(w, [credit_entry(amount + over, f.rf, e2e)])
        self.m.bank += amount + over
        pid, _ = payment_of_line(sid)
        allocs = live_allocations(pid)
        assert [a for _, a in allocs] == [amount], allocs
        entry = allocs[0][0]
        self.m.collect(FPayment(pid, amount + over, e2e), entry, s.client, s.mandate, amount)
        self.pay_files[pid] = (f, slot)
        self.collections.append(entry)
        self.payment_of[entry] = pid
        event(f"collect{' overpaid' if over else ''}")

    def _preferring_remitted(self, keys: list[str], i: int) -> list[str]:
        """Mostly the collections a run took (remitted, or one time in four in flight) when there
        are any: the reversals the covers are about."""
        remitted = [k for k in keys if self.m.remitted(k)]
        flight = [k for k in keys if self.m.items[k].run is not None and not self.m.remitted(k)]
        if i % 4 == 1 and flight:
            return flight
        if i % 4 == 0:
            return keys
        return remitted or flight or keys

    def _live_collections(self) -> list[str]:
        return [
            e for e in self.collections
            if not any(i.origin == e and i.kind == "reversal" for i in self.m.items.values())
        ]  # fmt: skip

    def desimputer(self, i: int) -> None:
        """« Désimputer » a collection, remitted or not (the payment's money back in 4710)."""
        cands = self._preferring_remitted(self._live_collections(), i)
        if not cands:
            return
        self._desimputer(cands[i % len(cands)])

    def _desimputer(self, e: str) -> None:
        pid = self.payment_of[e]
        f, _slot = self.pay_files[pid]
        refunding = any(t.payment == pid and t.status not in ("debited", "cancelled")
                        for t in self.m.transfers.values())  # fmt: skip
        try:
            res = self._ops("select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
                            str(uuid.uuid4()), pid, f.id, [e], "désimputé (machine)")  # fmt: skip
        except psycopg.errors.CheckViolation as exc:
            # its payment's refund is pending: the money cannot come back to 4710 under it
            assert refunding and "a refund is pending" in str(exc), (refunding, exc)
            event("désimputer: refused, a refund pending")
            return
        assert not refunding, "« Désimputer » under a pending refund"
        (r,) = res["reversals"]
        expected = self.m.reverse(str(r), e, returned=False)
        self.m.payments[pid].allocated -= self.m.items[e].amount
        got = sum(int(a["amount_minor"]) for a in res.get("advances") or [])
        assert got == expected, ("covered at « Désimputer »", got, expected)
        self._register_advances(str(r), e)
        event("désimputer: covered" if expected else "désimputer: not remitted")

    def payment_returned(self, i: int) -> None:
        """The payer's bank takes a payment back in full: the debit job reverses its allocations."""
        cands = [p for p in self.m.payments.values()
                 if p.out == 0 and p.allocated > 0
                 and not any(t.payment == p.id for t in self.m.transfers.values())]  # fmt: skip
        if not cands:
            return
        p = cands[i % len(cands)]
        live = [e for e in self._live_collections() if self.payment_of[e] == p.id]
        bank_statement(self.ww, [payment_return_entry(p.amount, p.e2e)])
        self.m.bank -= p.amount
        covered = 0
        for e in live:
            r = reversal_of(e)
            assert r is not None, ("the return reversed", e)
            covered += self.m.reverse(r, e, returned=True)
            self._register_advances(r, e)
        p.allocated = 0
        p.out = p.amount
        event("payment returned: covered" if covered else "payment returned")

    def refund_to_payer(self, i: int) -> None:
        """What a payment left unallocated (an overpayment, a « Désimputer ») refunded to the payer:
        a refund transfer in the next file."""
        cands = [p for p in self.m.payments.values() if p.unallocated > 0
                 and not any(t.payment == p.id and t.status != "cancelled"
                             for t in self.m.transfers.values())]  # fmt: skip
        if not cands:
            return
        p = cands[i % len(cands)]
        reason = v("select review_reason from public.payment where id = %s", p.id)
        code = "overpayment" if reason in ("overpayment", "nothing_due") else "other"
        out = refund_request(self.ww.tenant, p.id, p.unallocated, code)
        t = FTransfer(str(out["transfer_id"]), "refund", p.unallocated, str(out["end_to_end_id"]),
                      payment=p.id)  # fmt: skip
        self.m.transfers[t.id] = t
        event("refund requested")

    def _ops(self, sql: str, *params: Any, user: str | None = None) -> Any:
        from close_out_world import ops  # noqa: PLC0415 - one name for the machine's commands

        return ops(self.ww, sql, *params, user=user)

    # -- the client's side: payments, credits, requests, write-offs ------------------------------

    def _document(self, client: str, kind: str, sha: str | None = None) -> str:
        """A document of the client (as « Joindre un document » registers it): a proof."""
        return str(v(
            """insert into public.document (organization_id, client_organization_id, kind,
                 storage_path, sha256, mime_type)
               values (%s, %s, %s, %s, %s, 'application/pdf') returning id""",
            self.ww.org, client, kind, f"client/test/{uuid.uuid4()}.pdf",
            sha or uuid.uuid4().hex * 2,
        ))  # fmt: skip

    def raw_reversal(self, i: int) -> None:
        """M2 (7a): a remitted collection reversed raw (the ledger's own reversal, no cover) fails
        at
        commit (LG009); one the model holds not remitted commits. Rolled back either way."""
        cands = self._preferring_remitted(self._live_collections(), i)
        if not cands:
            return
        e = cands[i % len(cands)]
        remitted = self.m.remitted(e)
        with psycopg.connect(DB) as conn:
            try:
                with conn.transaction() as tx:
                    conn.execute("select private.ledger_reverse(%s, %s, 'brut (machine)', %s)",
                                 (e, f"raw:{uuid.uuid4()}", today()))  # fmt: skip
                    conn.execute("select private.ledger_check_now()")
                    raise psycopg.Rollback(tx)
            except psycopg.Error as exc:
                assert remitted and exc.sqlstate == "LG009", ("raw reversal", remitted, exc)
                event("raw reversal: LG009")
                return
        assert not remitted, "a remitted collection reversed raw committed without its cover"
        event("raw reversal: not remitted, commits")

    def client_payment(self, i: int) -> None:
        """« Règlement du client » to the own account (rule 12): what is open, part of it, or more
        (a credit owed back), designated or not, with its proof."""
        client = self.clients[CLIENTS[i % len(CLIENTS)]]
        if client in self.m.bars:
            return  # what a barred client may pay is the procedure's (046b): not modelled
        named: list[str] | None = None
        if i % 4 == 3:
            open_docs = [d.id for d in sorted(self.m.documents.values(), key=lambda d: d.number)
                         if d.client == client and d.kind == "invoice" and d.open > 0
                         and d.in_flight is None]  # fmt: skip
            named = open_docs[:1] or None
        considered = self.m.considered(client, named)
        amount = {0: considered, 1: considered // 2, 2: considered + 5_000}[(i // 4) % 3]
        if amount <= 0:
            return
        sha = uuid.uuid4().hex * 2
        proof = self._document(client, "client_payment_evidence", sha)
        designation = self._document(client, "payment_designation_evidence") if named else None
        out = self._ops(
            """select public.record_client_payment(%s, %s, 'EUR', %s, private.paris_today(), %s,
                                                   %s, %s, null, %s, %s)""",
            str(uuid.uuid4()), client, f"{amount // 100},{amount % 100:02d}", proof, named,
            designation, str(considered), "Virement reçu du client (machine)",
        )  # fmt: skip
        parts, rest = self.m.client_payment_parts(client, amount, today(), named)
        if any(k in self.m.documents and p < self.m.documents[k].open for k, p, _ in parts):
            event("a client payment settles a document in part (its VAT pro rata)")
        got = [(str(x["document_id"]), int(x["amount_minor"]), int(x["vat_moved_minor"]))
               for x in out["settled"]]  # fmt: skip
        assert got == parts, ("rule 12: what the payment settles", got, parts)
        assert int(out["credit_minor"]) == rest, ("the rest owed back", out, rest)
        credit = None
        if rest:
            cid = str(v("""select id from public.client_credit where client_organization_id = %s
                           and amount_minor = %s order by created_at desc limit 1""",
                        client, rest))  # fmt: skip
            credit = FCredit(cid, client, rest)
        self.m.client_paid(parts, credit, own=True, amount=amount)
        self.m.proofs.add(sha)
        self.proof_order.append(sha)
        event("client payment" + (" designated" if named else "") + (" surplus" if rest else ""))

    def same_proof_twice(self, i: int) -> None:
        """MONEY-2 (H11): the same proof (its content) recorded again for another payment is
        refused `evidence_already_used`, however it was uploaded."""
        if not self.proof_order:
            return
        sha = self.proof_order[i % len(self.proof_order)]  # in the order they were recorded
        client = self.clients[CLIENTS[i % len(CLIENTS)]]
        client = str(v("select client_organization_id from public.document where sha256 = %s"
                       " and organization_id = %s limit 1", sha, self.ww.org))  # fmt: skip
        proof = self._document(client, "client_payment_evidence", sha)
        try:
            self._ops(
                """select public.record_client_payment(%s, %s, 'EUR', '1,00',
                                                       private.paris_today(), %s, null, null,
                                                       null, %s, %s)""",
                str(uuid.uuid4()), client, proof, str(self.m.considered(client, None)),
                "Virement reçu du client (machine)",
            )  # fmt: skip
        except psycopg.errors.CheckViolation as exc:
            assert "evidence_already_used" in str(exc), exc
            event("the same proof twice: refused")
            return
        raise AssertionError("MONEY-2: one proof recorded twice")

    def refund_credit(self, i: int) -> None:
        """A credit owed back refunded from the own account, on its proof."""
        cands = [c for c in self.m.credits.values() if c.open > 0]
        if not cands:
            return
        c = cands[i % len(cands)]
        part = c.open if i % 2 else max(1, c.open // 2)
        proof = self._document(c.client, "client_refund_evidence")
        self._ops("select public.record_client_refund(%s, %s, %s, private.paris_today(), %s, %s,"
                  " %s)",
                  str(uuid.uuid4()), c.id, f"{part // 100},{part % 100:02d}", proof, str(c.open),
                  "Remboursement du trop-perçu (machine)")  # fmt: skip
        c.refunded += part
        self.m.own_cash -= part
        event("credit refunded")

    def repayment_request(self, i: int) -> None:
        """« Demande de remboursement d'avance » for a client's open advances no request names."""
        client = self.clients[CLIENTS[i % len(CLIENTS)]]
        cands = [a for a in sorted(self.m.advances.values(), key=lambda a: a.seq)
                 if a.client == client and a.open > 0 and not a.requested_by
                 and a.in_flight is None]  # fmt: skip
        clawed = [a for a in cands if a.mandate and self.m.mandates[a.mandate].clawback]
        if clawed and i % 5 == 0 and client not in self.m.bars:
            # an advance a claw-back clause takes back is never requested (it would be both)
            try:
                self._ops(
                    "select public.request_advance_repayment(%s, %s, 'EUR', %s::uuid[], %s)",
                    str(uuid.uuid4()),
                    client,
                    [clawed[0].id],
                    str(clawed[0].open),
                )
            except psycopg.errors.CheckViolation as exc:
                assert "clawback_applies" in str(exc), exc
                event("repayment request refused: the claw-back clause applies")
                return
            raise AssertionError("an advance under a claw-back clause requested")
        cands = [a for a in cands if a not in clawed]
        if not cands:
            return
        named = cands[: 1 + i % len(cands)]
        unpaid = [a for a in named if self._payout_not_received(a)]
        try:
            out = self._ops(
                "select public.request_advance_repayment(%s, %s, 'EUR', %s::uuid[], %s)",
                str(uuid.uuid4()),
                client,
                [a.id for a in named],
                str(sum(a.open for a in named)),
            )
        except psycopg.errors.CheckViolation as exc:
            if client in self.m.bars:
                # rule 17: no advance is requested while a proceeding (or a liquidation) stands
                assert "refused" in str(exc), exc
                event("repayment request refused under a bar")
                return
            # nor one whose reversed collection went out in a payout the client never received
            # (it came back and was not paid again since: [check 2] « the client was paid »)
            assert unpaid and "payout_not_received" in str(exc), (unpaid, exc)
            event("repayment request refused: the payout never received")
            return
        assert client not in self.m.bars, "an advance requested while a proceeding stands"
        assert not unpaid, ("an advance requested whose payout never reached the client", unpaid)
        req = str(out["request_id"])
        self.m.requests[req] = {a.id for a in named}
        for a in named:
            a.requested_by.add(req)
        event("repayment requested")

    def _payout_not_received(self, a: Any) -> bool:
        """The model's « payout not received »: a cover whose reversed collection's run is not
        settled ([check 2], `settled_on`: its payout came back and was not paid again)."""
        if a.cause != "remitted_reversal" or a.cover_of is None:
            return False
        collection = self.m.items[a.cover_of].origin
        run = self.m.items[collection].run if collection else None
        return run is not None and self.m.settled_on(run) is None

    def withdraw_request(self, i: int) -> None:
        if not self.m.requests:
            return
        req = list(self.m.requests)[i % len(self.m.requests)]  # in the order they were made
        self._ops("select public.withdraw_advance_repayment_request(%s, %s, %s)",
                  str(uuid.uuid4()), req, "retirée (machine)")  # fmt: skip
        for aid in self.m.requests.pop(req):
            self.m.advances[aid].requested_by.discard(req)
        event("request withdrawn")

    def write_off(self, i: int) -> None:
        """« Passer en perte » an open advance, in full or in part (an admin; rule 11)."""
        cands = [a for a in sorted(self.m.advances.values(), key=lambda a: a.seq)
                 if a.open > 0 and a.in_flight is None and not a.requested_by]  # fmt: skip
        if not cands:
            return
        a = cands[i % len(cands)]
        part = a.open if i % 2 else max(1, a.open // 3)
        proof = self._document(a.client, "advance_write_off_evidence")
        self._ops("select public.write_off_advance(%s, %s, %s, %s, %s, %s)", str(uuid.uuid4()),
                  a.id, f"{part // 100},{part % 100:02d}", str(a.open), "Perte (machine)", proof,
                  user=self.ww.tenant["admin"])  # fmt: skip
        a.written_off += part
        event("advance written off")

    def client_event(self, i: int) -> None:
        """« Enregistrer un événement » (an admin, on its evidence): a collective proceeding opened
        today, or a liquidation, for a client with none yet. A payout ordered for a run prepared
        before it is held out of every file (client_status_changed); one already handed out is
        booked at its debit with the barred set-off withheld (rules 17, 27)."""
        free = [c for c in self.clients.values() if c not in self.m.bars]
        if not free:
            return
        self._client_event(free[i % len(free)], "proceeding_opened" if i % 2 else "liquidation")

    def _client_event(self, client: str, kind: str) -> None:
        proof = self._document(client, "client_status_evidence")
        self._ops("""select public.record_client_status_event(%s, %s, %s, %s, %s,
                     'Événement (machine)', null, %s, null, null, null)""",
                  str(uuid.uuid4()), client, kind, today(), proof, today(),
                  user=self.ww.tenant["admin"])  # fmt: skip
        self.m.bars[client] = ("proceeding" if kind == "proceeding_opened" else "liquidation",
                               today())  # fmt: skip
        for t in self.m.transfers.values():
            if (
                t.kind == "payout"
                and t.status == "ordered"
                and t.run
                and self.m.runs[t.run].client == client
                and self._held_by_event(t.run)
            ):
                t.held = True
        event(f"client event: {kind}")

    def _held_by_event(self, run: str) -> bool:
        """Whether the client's event holds the run's payout out of every file: a liquidation
        always (the payee rule: the liquidator's account, to confirm); a proceeding only when the
        run sets something off (its frozen set-off no longer holds: client_status_changed) — a
        proceeding blocks no payout (design §13 #9; the 200 x 60 run, seed 71303)."""
        r = self.m.runs[run]
        bar = self.m.bars.get(r.client, ("", None))[0]
        sets_off = any(v > 0 for v in r.takes.values())
        return bar == "liquidation" or (bar == "proceeding" and sets_off)

    def settlement_reversal_probe(self, i: int) -> None:
        """LG003: a run's settlement is never reversed — the one exception, its barred part under
        its own run's keys, does not cover the settlement itself (rolled back either way)."""
        cands = [r for r in self.m.runs.values() if r.status == "booked" and r.settlement > 0]
        if not cands:
            return
        r = cands[i % len(cands)]
        entry = q("""select id from public.ledger_entry where organization_id = %s
                     and idempotency_key = %s""", self.ww.org, f"settle:{r.id}")  # fmt: skip
        if not entry:
            return
        with psycopg.connect(DB) as conn:
            try:
                with conn.transaction() as tx:
                    conn.execute("select private.ledger_reverse(%s, %s, 'brut (machine)', %s)",
                                 (entry[0][0], f"return:barred:{r.id}", today()))  # fmt: skip
                    raise psycopg.Rollback(tx)
            except psycopg.Error as exc:
                assert exc.sqlstate == "LG003", exc
                event("a settlement reversed raw: LG003")
                return
        raise AssertionError("LG003: a run's settlement reversed")

    # -- runs -----------------------------------------------------------------------------------

    def run(self, c: int) -> None:
        """« Préparer maintenant » for a client with items waiting (or, one time in ten, any
        client: the refusals), then « Valider »."""
        waiting = [x for x in self.clients.values() if self.m.pending(x)]
        if waiting and c % 10:
            client = waiting[c % len(waiting)]
        else:
            client = self.clients[CLIENTS[c % len(CLIENTS)]]
        self._run_client(client)

    def _run_client(self, client: str) -> str:
        """« Préparer maintenant » then « Valider » for the client: what became of it — « approved »
        (its payout ordered), « booked » (N = 0), « refused » (the approval refused it, as the model
        says), « in flight » (a run of the client in flight already), « nothing pending »."""
        slot = self.slot_of_client[client]
        if client in self.m.returned_accounts:
            replace_payout_account(slot, str(self.ww.tenant["staff"]))
            self.m.returned_accounts.discard(client)
            self.m.account_gen[client] = self.m.account_gen.get(client, 0) + 1
            # a payout ordered to the old account stays out of every file (payout_account_changed)
            for t in self.m.transfers.values():
                if (
                    t.kind == "payout"
                    and t.status == "ordered"
                    and t.run
                    and self.m.runs[t.run].client == client
                ):
                    t.held = True
        pending = self.m.pending(client)
        live = [r for r in self.m.runs.values() if r.client == client and r.status == "approved"]
        try:
            run = request_run(slot.tenant)
        except psycopg.errors.UniqueViolation as exc:
            assert live and "run_pending" in str(exc), ("refused run_pending", str(exc), live)
            event("run: one in flight already")
            return "in flight"
        except psycopg.errors.CheckViolation as exc:
            assert not pending and not live, ("a run refused with items pending", str(exc))
            assert "nothing_pending" in str(exc), exc
            event("run: nothing pending")
            return "nothing pending"
        assert not live, ("a second live run of the client", live)
        return self._approve_run(run, client, pending)

    def remit(self, slot: int, amount: int, i: int) -> None:
        """One collection taken to the client end to end — collected, its client's run approved,
        the file handed out and every payout in it debited: the remitted state the covers are about,
        reached in one step."""
        self.collect(slot, amount, 0)
        e = self.collections[-1]
        outcome = self._run_client(self.ww.slots[slot].client)
        self.file_and_download()
        while any(t.status == "downloaded" and t.kind in ("payout", "refund", "sweep")
                  for t in self.m.transfers.values()):  # fmt: skip
            self.bank_debits(i, False)
        # (review round 1, MACH-1) remitted, unless the model says why not: the client's run in
        # flight already, refused as the model refuses it, or its payout held or not covered (the
        # file says so: checked there) or the account short of the file (cash_not_covered)
        if outcome in ("approved", "booked"):
            t = next((t for t in self.m.transfers.values()
                      if t.kind == "payout" and t.run == self.m.items[e].run), None)  # fmt: skip
            if t is not None and t.status == "ordered":
                assert t.held or self._short(t) or self.last_file == "cash_not_covered", (
                    "remit: a payout ordered, the model's to file", t, self.last_file)  # fmt: skip
            else:
                assert self.m.remitted(e), ("remit: the collection not remitted", e, outcome)
            if self.m.remitted(e):
                event("remit: one step end to end")
        if i % 3 == 0:
            self.settlement_reversal_probe(i)  # LG003, on a run just booked

    def _approve_run(self, run: str, client: str, pending: list[Any]) -> str:  # noqa: PLR0915
        drafted = {str(r[0]): int(r[1]) for r in q(
            "select ledger_entry_id, amount_minor from private.remittance_draft_line"
            " where run_id = %s", run)}  # fmt: skip
        want = {i.key: i.amount for i in pending}
        assert drafted == want, ("the draft's lines are the queue", drafted, want)
        gross = sum(want.values())
        slot = self.slot_of_client[client]
        approve(slot.tenant, run)
        drain_remittances()
        row = run_row(run)
        if row["status"] == "draft":
            # (review round 1, MACH-2) the refusal is the model's: `negative_net` exactly when the
            # model's N is below 0 (§9.6: the takes cut to nothing, the client's money still short),
            # or the liquidation's payee to confirm (the payee rule); nothing else refuses here
            code = (row["last_failure"] or {}).get("code")
            blocked = self.m.bars.get(client, ("", None))[0] == "liquidation"
            model = self.m.expected_plan(client, [self.m.items[k] for k in want],
                                         self.m.refunds_owed(client), [])  # fmt: skip
            model_net = sum(x["net"] for x in model.values())
            if code == "negative_net":
                assert model_net < 0, ("refused negative_net, the model's N", model_net, model)
            else:
                assert blocked and "client_status:liquidation" in (row["blockers"] or []), (
                    "a run refused that the model approves", code, row["blockers"], model_net,
                    model)  # fmt: skip
            code = code or ",".join(row["blockers"] or [])
            self._ops("select public.discard_remittance_run(%s, %s, %s, %s)", str(uuid.uuid4()),
                      run, row["version"], "écarté (machine)")  # fmt: skip
            event(f"run refused: {code}")
            return "refused"
        assert row["status"] in ("approved", "booked"), row
        self._sync_documents()
        plan = row["settlement_plan"] or {}
        excess = self.m.refunds_owed(client)  # the model's, never the engine's
        lines = [self.m.items[k] for k in want]
        late = {t.run for t in self.m.transfers.values() if t.late}
        if any(i.kind == "payout_returned" and i.origin in late for i in lines):
            # what a late predecessor carried, owed again, in a later run: its plan (below) is the
            # model's (not M5's state, a cover's release re-queued: not modelled, ADR « M2c-7f-2
            # review fixes »)
            event("a late predecessor's return re-queued in a later run")
        expected = self.m.expected_plan(client, lines, excess, [])
        got = {m["mandate_id"]: m for m in plan.get("mandates", [])}
        for mandate, x in expected.items():
            g = got.get(mandate)
            assert g is not None, ("a mandate of the run's lines has no plan", mandate, plan)
            assert (int(g["gross"]), int(g["excess"]), int(g["take"]), int(g["take_advance"]),
                    int(g["net"])) == (x["gross"], x["excess"], x["take"], x["take_advance"],
                                       x["net"]), ("the run's plan", mandate, g, x)  # fmt: skip
        if any(x.get("deferred") for x in expected.values()):
            assert plan.get("deferred") is True, ("D = 0: the run settles nothing now", plan)
            event("a run settles nothing (D = 0): its takes and refunds left for a later run")
        takes = {str(s["document_id"]): int(s["amount"]) for s in plan.get("settles", [])
                 if s["kind"] in ("compensation", "advance")}  # fmt: skip
        want_takes = {k: t for x in expected.values() for k, t in x["takes"].items()}
        assert takes == want_takes, ("each take, oldest first", takes, want_takes)
        refunds = {str(s["document_id"]): int(s["amount"]) for s in plan.get("settles", [])
                   if s["kind"] == "refund"}  # fmt: skip
        net = sum(x["net"] for x in expected.values())
        d = sum(x["take"] + x["take_advance"] - x["excess"] for x in expected.values())
        assert (int(row["net_minor"]), int(row["settlement_minor"])) == (net, d), (row, net, d)
        if any(k in self.m.documents and t < self.m.documents[k].open
               for k, t in want_takes.items()):  # fmt: skip
            event("a run takes a document in part (its VAT pro rata)")
        fr = FRun(run, client, tuple(want), gross, net=net, settlement=d, takes=want_takes,
                  refunds=refunds, account=self.m.account_gen.get(client, 0))  # fmt: skip
        self.m.approve(fr)
        if row["status"] == "booked":
            # N = 0: booked at its approval, on the approval's Paris day (never a later today())
            self._booked(
                run,
                v(
                    "select (approved_at at time zone 'Europe/Paris')::date"
                    " from public.remittance_run where id = %s",
                    run,
                ),
                net_zero=True,
            )
            event("run approved, N = 0")
            return "booked"
        x = v("select transfer_id::text from public.remittance_run where id = %s", run)
        e2e, amount = q("select end_to_end_id, amount_minor from public.bank_transfer"
                        " where id = %s", x)[0]  # fmt: skip
        assert int(amount) == net
        self.m.transfers[str(x)] = FTransfer(str(x), "payout", net, str(e2e), run=run)
        event("run approved")
        return "approved"

    def _booked(self, run: str, on: Any, *, net_zero: bool = False) -> None:
        moves = self.m.expected_vat_moves(run)
        withheld = q(
            """select q.ledger_entry_id::text from private.remittance_pending q
               join public.ledger_entry e on e.id = q.ledger_entry_id
               where q.kind = 'settlement_withheld' and e.idempotency_key = %s""",
            f"return:barred:{run}",
        )  # fmt: skip
        got = {str(r[0]): int(r[1]) for r in q(
            """select document_id, vat_moved_minor from public.commission_settlement
               where run_id = %s and kind = 'compensation' and document_kind = 'invoice'""",
            run)}  # fmt: skip
        r = self.m.runs[run]
        barred = any(self.m.barred(r.client, k) for k in r.takes)
        assert bool(withheld) == barred, (
            "a barred set-off withheld at the debit",
            withheld,
            barred,
        )
        due = self.m.book(run, on, withheld[0][0] if withheld else None)
        if barred:
            event("a set-off withheld at the debit")
        assert got == {k: x for k, x in moves.items()}, ("VAT moved pro rata", got, moves)
        for rev in due:
            self._register_advances(rev, self.m.items[rev].origin or "")
        if due:
            event("covers at the booking")

    def cancel_before_download(self, i: int, only: FTransfer | None = None) -> None:
        """« Annuler le reversement » before its file is handed out (an admin): a held payout's
        first, when there is one (its run is to be prepared again)."""
        cands = [t for t in self.m.transfers.values()
                 if t.kind == "payout" and t.status in ("ordered", "in_file")]  # fmt: skip
        held = [t for t in cands if t.held]
        if only is not None:
            cands = [only]
        elif held and i % 2:
            cands = held
        if not cands:
            return
        t = cands[i % len(cands)]
        assert t.run is not None
        version = run_row(t.run)["version"]
        out = self._ops("select public.cancel_remittance_run(%s, %s, %s, %s)", str(uuid.uuid4()),
                        t.run, version, "annulé (machine)",
                        user=self.ww.tenant["admin"])  # fmt: skip
        assert out["status"] == "cancelled", out
        t.status = "cancelled"
        self.m.cancel(t.run)
        self._sync_documents()
        event("run cancelled before its file")

    # -- files and the bank ---------------------------------------------------------------------

    def _hold_returned(self) -> None:
        """A payout ordered before its client's last payout came back is held out of every file
        (its account returned, or replaced since: its run is to be cancelled and prepared again)."""
        for t in self.m.transfers.values():
            if (
                t.kind == "payout"
                and t.status == "ordered"
                and t.run
                and self.m.runs[t.run].client in self.m.returned_accounts
            ):
                t.held = True

    def file_and_download(self, *, always: bool = True) -> None:
        w = self.ww
        self._hold_returned()
        due = any(t.status == "ordered" and t.kind in ("payout", "refund") and not t.held
                  for t in self.m.transfers.values()) or self.m.due_to_servicer < 0  # fmt: skip
        if not (due or always):
            return
        self._file(w)

    def _short(self, t: FTransfer) -> bool:
        """A payout its client's queue no longer covers (the per-client cap: a line of its run
        reversed since leaves the queue in debit — gross > -4670[c] - the others in flight)."""
        return (
            t.kind == "payout"
            and t.status == "ordered"
            and t.run is not None
            and sum(x.amount for x in self.m.pending(self.m.runs[t.run].client)) < 0
        )

    def _file(self, w: World) -> None:
        # held for now: a payout its client's queue no longer covers; (the 200 x 60 run, seed
        # 71306) one the model holds for another reason too — the file names the first reason that
        # applies, so not covered may be the one it gives
        short = {t.id for t in self.m.transfers.values() if self._short(t)}
        # (review round 1, MACH-1) what the model has to file: every payout or refund ordered,
        # neither held nor short
        to_file = {t.id for t in self.m.transfers.values()
                   if t.kind in ("payout", "refund") and t.status == "ordered" and not t.held
                   and t.id not in short}  # fmt: skip
        try:
            res = self._ops("select public.generate_transfer_file(%s, %s, null)",
                            str(uuid.uuid4()), w.tenant["bank"])  # fmt: skip
        except psycopg.errors.CheckViolation as exc:
            if "nothing_to_file" in str(exc):
                detail = json.loads(exc.diag.message_detail or "{}")
                for h in detail.get("held", []):
                    t = self.m.transfers.get(str(h["transfer_id"]))
                    assert t is not None, ("held out of the file", h)
                    if h["reason"] == "payout_not_covered":
                        assert t.id in short, ("held out of the file: not covered", h)
                    else:
                        # a client with a status event: its payee to be confirmed again (the payee
                        # rule, 7d-1: not modelled) blocks its payouts as well
                        barred = t.run is not None and self.m.runs[t.run].client in self.m.bars
                        assert t.held and (h["reason"] in (
                            "client_status_changed", "payout_blocked:payout_account_returned",
                            "payout_account_changed") or (barred and h["reason"].startswith(
                                "payout_blocked:client_status:"))), (
                            "held out of the file", h)  # fmt: skip
                held_ids = {str(h["transfer_id"]) for h in detail.get("held", [])}
                assert held_ids >= short, (
                    "the payouts the queue no longer covers held",
                    short,
                    detail,
                )
                # nothing filed: each transfer the model has to file is held, the file says why
                # (a barred client's payee to confirm: the payee rule, not modelled)
                assert held_ids >= to_file, ("nothing to file, the model's to file",
                                             to_file - held_ids, detail)  # fmt: skip
                self.last_file = "nothing_to_file"
                event("file: nothing to file")
                return
            assert "cash_not_covered" in str(exc), exc
            detail = json.loads(exc.diag.message_detail or "{}")
            flight = sum(t.amount for t in self.m.transfers.values()
                         if t.status == "downloaded" and t.kind != "top_up")  # fmt: skip
            # the account holds less than the file needs: refused, never filed short — the cash
            # the check reads is the bank's, less what is in flight (the model's own)
            assert int(detail["available_minor"]) == self.m.bank - flight, (detail, self.m.bank)
            assert int(detail["needed_minor"]) > int(detail["available_minor"]), detail
            self.last_file = "cash_not_covered"
            event("file: cash not covered")
            return
        drain_remittances()
        fid = str(res["file_id"])
        assert v("select status from public.transfer_file where id = %s", fid) == "generated"
        download(w, fid)
        for tid, kind, amount, e2e in q(
            """select id::text, kind, amount_minor, end_to_end_id from public.bank_transfer
               where transfer_file_id = %s""", fid):  # fmt: skip
            t = self.m.transfers.get(tid)
            assert t is None or not (t.held or t.id in short), ("a held payout filed", t)
            if t is None:
                assert kind == "sweep", (kind, tid)
                share = -self.m.due_to_servicer - sum(
                    x.amount
                    for x in self.m.transfers.values()
                    if x.kind == "sweep" and x.status in ("in_file", "downloaded")
                )
                assert 0 < int(amount) <= share, ("the sweep within the servicer's share",
                                                  amount, share)  # fmt: skip
                t = FTransfer(tid, "sweep", int(amount), str(e2e))
                self.m.transfers[tid] = t
            assert t.amount == int(amount), (t, amount)
            t.status, t.file = "downloaded", fid
        self.last_file = "downloaded"
        event("file downloaded")

    def _debited(self, t: FTransfer) -> None:
        status = v("select status from public.bank_transfer where id = %s", t.id)
        assert status == "booked", ("the bank's debit booked", t, status)
        t.status = "debited"
        self.m.bank -= t.amount
        if t.kind == "payout":
            assert t.run is not None
            self._booked(t.run, self.ww.day)  # the bank's booking day of its line
        elif t.kind == "refund":
            assert t.payment is not None
            self.m.payments[t.payment].out += t.amount
        elif t.kind == "sweep":
            self.m.due_to_servicer += t.amount
            self.m.own_cash += t.amount

    def bank_debits(self, i: int, batch: bool) -> None:
        """The bank executes a handed-out transfer on its own line, or a whole file as one batch
        line per PmtInf."""
        cands = [
            t
            for t in self.m.transfers.values()
            if t.status == "downloaded" and t.kind in ("payout", "refund", "sweep")
        ]
        if not cands:
            return
        t = cands[i % len(cands)]
        if batch:
            assert t.file is not None
            members = [x for x in self.m.transfers.values() if x.file == t.file]
            if all(x.status == "downloaded" for x in members):
                bank_statement(self.ww, file_entries(self.ww.files[t.file], mode="batch"))
                for x in members:
                    self._debited(x)
                event("bank: a file as batch lines")
                return
        bank_statement(self.ww, [transfer_debit_entry(t.amount, t.e2e)])
        self._debited(t)
        event(f"bank: {t.kind} debited")

    def payout_back(self, i: int) -> None:
        cands = [t for t in self.m.transfers.values()
                 if t.kind == "payout" and t.status == "debited"]  # fmt: skip
        if not cands:
            return
        self._payout_back(cands[i % len(cands)])

    def _payout_back(self, t: FTransfer) -> None:
        assert t.file is not None and t.run is not None
        client = self.m.runs[t.run].client
        if any(r.client == client and r.status == "approved" for r in self.m.runs.values()):
            # 038's f_partial, its reachable form: a run approved between the payout's debit and
            # its return, over two statements (M4)
            event("M4 f_partial: a run approved between a payout's debit and its return")
        bank_statement(self.ww, file_entries(self.ww.files[t.file], returns=(t.e2e,),
                                             only_returns=True))  # fmt: skip
        self.m.bank += t.amount
        t.status = "returned"
        item = v(
            """select q.ledger_entry_id::text from private.remittance_pending q
               join public.ledger_entry e on e.id = q.ledger_entry_id
               join public.ledger_entry r on r.id = e.reverses_entry_id
               where q.kind = 'payout_returned' and r.idempotency_key = %s""",
            f"remit:{t.id}",
        )
        self.m.payout_returned(t.run, item)
        event("bank: payout returned")

    def bank_fee(self, amount: int) -> None:
        bank_statement(self.ww, [fee_entry(amount)])
        self.m.bank -= amount
        self.m.due_to_servicer += amount
        event("bank fee")

    def hourly_top_up(self) -> None:
        need = self.m.top_up_needed()
        before = {r[0] for r in q("select id::text from public.bank_transfer where organization_id"
                                  " = %s and kind = 'top_up'", self.ww.org)}  # fmt: skip
        from close_out_world import send_top_ups  # noqa: PLC0415

        send_top_ups(self.ww)
        new = [r for r in q("""select id::text, amount_minor, end_to_end_id
                               from public.bank_transfer
                               where organization_id = %s and kind = 'top_up'""", self.ww.org)
               if r[0] not in before]  # fmt: skip
        assert sum(int(r[1]) for r in new) == need, ("the hourly top-up orders", new, need)
        for tid, amount, e2e in new:
            self.m.transfers[tid] = FTransfer(tid, "top_up", int(amount), str(e2e))
        event("top-up ordered" if need else "top-up: nothing owed")

    def top_up_credited(self, i: int) -> None:
        cands = [t for t in self.m.transfers.values()
                 if t.kind == "top_up" and t.status in ("ordered", "in_file")]  # fmt: skip
        if not cands:
            return
        t = cands[i % len(cands)]
        bank_statement(self.ww, [own_credit_entry(self.ww, t.amount, t.e2e)])
        status = v("select status from public.bank_transfer where id = %s", t.id)
        assert status == "booked", ("the top-up's credit booked", status)
        t.status = "debited"
        self.m.bank += t.amount
        self.m.due_to_servicer -= t.amount
        self.m.own_cash -= t.amount
        event("top-up credited")

    def nightly(self) -> None:
        _run, rows = checks(self.ww)
        bad = [r for r in rows if r[1] == "violation"]
        assert bad == [], bad
        # H2: « Contrôles »' shortfall is the hourly order's own amount (4679 + the sweeps in
        # flight - the top-ups ordered or filed), or no row
        short = [int(r[3] or 0) for r in rows if r[0] == "servicer_shortfall"]
        need = self.m.top_up_needed()
        assert short == ([need] if need > 0 else []), ("servicer_shortfall", short, need)

    # -- the paths the mutants are about, in one step each (the machine's own rules, chained) --

    def reversal_in_flight(self, slot: int, amount: int) -> None:
        """Rule 2: a collection whose run's file is handed out, reversed before the bank debits it:
        covered at the booking (`adv:<R>:<run>`), never before."""
        self.collect(slot, amount, 0)
        e = self.collections[-1]
        self._run_client(self.ww.slots[slot].client)
        self.file_and_download()
        if self.m.items[e].run is None or self.m.remitted(e):
            return
        self._desimputer(e)
        while any(t.status == "downloaded" and t.kind in ("payout", "refund", "sweep")
                  for t in self.m.transfers.values()):  # fmt: skip
            self.bank_debits(0, False)
        event("macro: a reversal in flight, covered at the booking")

    def same_run_pair(self, slot: int, amount: int) -> None:
        """Rule 2a: a collection and its reversal both waiting at the prepare — one run takes the
        pair, nets it to nothing and never covers it."""
        self.collect(slot, amount, 0)
        self._desimputer(self.collections[-1])
        self._run_client(self.ww.slots[slot].client)
        self.file_and_download()
        while any(t.status == "downloaded" and t.kind in ("payout", "refund", "sweep")
                  for t in self.m.transfers.values()):  # fmt: skip
            self.bank_debits(0, False)
        event("macro: a same-run pair")

    def clawback_cycle(self, amount: int, slot: int) -> None:
        """Rules 7, 8 (M3): MARTIN-1's remitted collection reversed (its cover an advance on that
        mandate), then a collection on MARTIN-1 or MARTIN-2 and Martin's run: the plan takes the
        advance back from MARTIN-1's own money only, oldest first, never from MARTIN-2's."""
        self.remit(0, amount, 1)
        e = self.collections[-1]
        if self.m.remitted(e):
            self._desimputer(e)
        self.collect(slot % 2, amount // 2 + 5_000, 0)
        self._run_client(self.ww.slots[0].client)
        event("macro: a claw-back cycle")

    def two_mandates_run(self, amount: int) -> None:
        """One run, two mandates, two schedules: MARTIN-1's remitted collection reversed (covered in
        full on MARTIN-1: its credit note's refund owed) while MARTIN-2's (at 25 %) waits — the
        run takes MARTIN-2's invoice from MARTIN-2's money only and pays MARTIN-1's refund with
        the payout (each mandate's room its own: §9.6)."""
        self.remit(0, amount, 1)
        e = self.collections[-1]
        if not self.m.remitted(e):
            return
        self.collect(1, amount + amount // 12, 0)
        self._desimputer(e)
        self._run_client(self.ww.slots[0].client)
        self.file_and_download()
        while any(t.status == "downloaded" and t.kind in ("payout", "refund", "sweep")
                  for t in self.m.transfers.values()):  # fmt: skip
            self.bank_debits(0, False)
        event("macro: one run, two mandates")

    def client_pays_part(self, amount: int) -> None:
        """Rule 12's pro rata: Durand's invoice (no netting) paid in part by the client — its VAT
        moved on the part paid, pro rata (`private.vat_part`); then rule 13: Lilas pays while her
        run is in flight."""
        self.remit(3, amount, 0)
        self.client_payment(5)  # Durand, half of what is open, no designation
        # rule 13: Lilas pays while her run (its invoice to be set off) is in flight — the payment
        # never settles a document a run in flight holds (what it pays beyond the rest is owed back)
        self.collect(2, amount, 0)
        self._run_client(self.ww.slots[2].client)
        self.client_payment(10)  # Lilas, all that is open and 50 EUR more
        event("macro: a client pays part")

    def f_partial(self, slot: int, amount: int) -> None:
        """038's f_partial (M4): a payout debited, then its client's next run approved, then the
        payout back on a later statement."""
        self.remit(slot, amount, 1)
        client = self.ww.slots[slot].client
        mine = [t for t in self.m.transfers.values() if t.kind == "payout" and t.status ==
                "debited" and t.run and self.m.runs[t.run].client == client]  # fmt: skip
        if not mine:
            return
        self.collect(slot, amount // 2 + 5_000, 0)
        self._run_client(client)
        self._payout_back(mine[-1])
        event("macro: f_partial")

    def sweep_in_flight(self, amount: int) -> None:
        """Rule 19 (H2): the servicer's share swept in a file not yet debited, then an advance owed
        to the dedicated account: the hourly top-up (and « Contrôles ») count the sweep in
        flight. (Review round 1, MACH-4) what the servicer owes the account is paid in first, so
        that the commission Lilas's run settles leaves 4679 in credit and the next file sweeps it;
        the state is recorded only when a sweep is in flight at the « Désimputer »."""
        if self.m.top_up_needed() > 0:
            self.hourly_top_up()
            while any(t.kind == "top_up" and t.status in ("ordered", "in_file")
                      for t in self.m.transfers.values()):  # fmt: skip
                self.top_up_credited(0)
        self.remit(2, amount, 1)
        self.file_and_download()
        swept = [t for t in self.m.transfers.values()
                 if t.kind == "sweep" and t.status == "downloaded"]  # fmt: skip
        remitted = [k for k in self._live_collections() if self.m.remitted(k)]
        if not swept or not remitted:
            return
        self._desimputer(remitted[-1])
        self.nightly()  # « Contrôles » before the hourly order: the sweep in flight counted (H2)
        self.hourly_top_up()
        self.nightly()
        event("macro: a sweep in flight, then an advance")

    def barred_at_debit(self, amount: int) -> None:
        """Rules 17, 27: a run of Martin's or Lilas's approved and its file handed out, then the
        client's liquidation recorded, then the bank debits the payout — the run's set-off is
        withheld at the debit (`settlement_withheld`), re-read then, not at the approval."""
        # MARTIN-2 or LILAS: no claw-back clause, so the run leaves a payout to debit
        free = [s for s in (1, 2) if self.ww.slots[s].client not in self.m.bars]
        if not free:
            return
        slot = free[amount % len(free)]
        client = self.ww.slots[slot].client
        self.collect(slot, amount, 0)
        self._run_client(client)
        self.file_and_download()
        if not any(t.kind == "payout" and t.status == "downloaded" and t.run
                   and self.m.runs[t.run].client == client
                   for t in self.m.transfers.values()):  # fmt: skip
            return
        self._client_event(client, "liquidation")
        while any(t.status == "downloaded" and t.kind in ("payout", "refund", "sweep")
                  for t in self.m.transfers.values()):  # fmt: skip
            self.bank_debits(0, False)
        event("macro: a set-off barred at the debit")

    # -- the one rule ---------------------------------------------------------------------------

    # One Hypothesis rule draws the action (weighted by repetition) and its arguments: with one
    # rule Hypothesis's swarm testing (each example enabling a random subset of the rules) does not
    # apply, so each example mixes every action, as the few examples a PR run affords need.
    ACTIONS: tuple[str, ...] = (
        "collect", "collect", "collect", "remit", "remit", "desimputer", "desimputer",
        "desimputer", "payment_returned", "payment_returned", "refund_to_payer", "run", "run",
        "cancel_before_download", "file_and_download", "file_and_download", "bank_debits",
        "bank_debits", "bank_debits", "payout_back", "bank_fee", "hourly_top_up", "hourly_top_up",
        "top_up_credited", "nightly", "raw_reversal", "client_payment", "client_payment",
        "same_proof_twice", "refund_credit", "repayment_request", "withdraw_request", "write_off",
        "client_event", "settlement_reversal_probe", "reversal_in_flight", "same_run_pair",
        "clawback_cycle", "sweep_in_flight", "two_mandates_run", "client_pays_part", "f_partial",
        "barred_at_debit",
    )  # fmt: skip

    @rule(data=st.data())
    def step(self, data: st.DataObject) -> None:
        # a wide integer modulo the actions: near uniform (Hypothesis favours a sampled_from's first
        # elements and small integers; it still shrinks towards the first action)
        action = self.ACTIONS[
            data.draw(st.integers(0, 2**16 - 1), label="pick") % len(self.ACTIONS)
        ]
        event(f"action {action}")
        try:
            self._do(action, data)
        except Exception:
            self.failed = True
            raise

    def _do(self, action: str, data: st.DataObject) -> None:  # noqa: PLR0911 - one per action
        i = data.draw(st.integers(0, 99), label="i")
        if action == "collect":
            slot = data.draw(st.integers(0, 3), label="slot")
            amount = data.draw(st.integers(5_000, 300_000), label="amount")
            over = data.draw(st.sampled_from([0, 0, 0, 7_500]), label="over")
            return self.collect(slot, amount, over)
        if action == "run":
            return self.run(i)
        if action == "remit":
            slot = data.draw(st.integers(0, 3), label="slot")
            amount = data.draw(st.integers(5_000, 300_000), label="amount")
            return self.remit(slot, amount, i)
        if action in ("reversal_in_flight", "same_run_pair", "f_partial"):
            slot = data.draw(st.integers(0, 3), label="slot")
            amount = data.draw(st.integers(5_000, 300_000), label="amount")
            return getattr(self, action)(slot, amount)  # type: ignore[no-any-return]
        if action == "clawback_cycle":
            amount = data.draw(st.integers(20_000, 300_000), label="amount")
            return self.clawback_cycle(amount, i)
        if action in (
            "sweep_in_flight",
            "two_mandates_run",
            "client_pays_part",
            "barred_at_debit",
        ):
            amount = data.draw(st.integers(20_000, 300_000), label="amount")
            return getattr(self, action)(amount)  # type: ignore[no-any-return]
        if action == "bank_debits":
            return self.bank_debits(i, data.draw(st.booleans(), label="batch"))
        if action == "bank_fee":
            return self.bank_fee(data.draw(st.integers(100, 5_000), label="amount"))
        if action == "file_and_download":
            return self.file_and_download(always=i < 10)
        if action in ("hourly_top_up", "nightly"):
            return getattr(self, action)()  # type: ignore[no-any-return]
        return getattr(self, action)(i)  # type: ignore[no-any-return]

    # -- invariants -----------------------------------------------------------------------------

    @invariant()
    def the_books_are_the_models(self) -> None:
        try:
            self.check_books()
        except Exception:
            self.failed = True
            raise

    CHECKS = (
        "I13", "I14", "4111", "4112", "419", "queue", "covers", "MONEY-5", "advance unknown",
        "advance open", "5120", "4710", "4679", "5122", "44574", "44571", "M6", "check 2",
    )  # fmt: skip

    def check_books(self, only: str | None = None) -> None:  # noqa: PLR0912, PLR0915 - one per check
        """The books against the model after every step (module docstring); `only` runs one check
        (the non-vacuity test plants a state that breaks it)."""
        if self.w is None:
            return
        b = _books(self.w)
        m = self.m

        def on(label: str) -> bool:
            return only is None or only == label

        for name, client in self.clients.items():
            payable = _book(b, "client_payable", client)
            if on("I13"):
                assert payable <= 0, ("I13", name, payable)
            if on("I14"):
                assert payable == m.payable(client), ("I14 from the model", name, payable,
                                                      m.payable(client))  # fmt: skip
            if on("4111"):
                assert _book(b, "commission_receivable", client) == m.documents_open(client), (
                    "4111", name, _book(b, "commission_receivable", client),
                    m.documents_open(client))  # fmt: skip
            if on("4112"):
                assert _book(b, "client_advance_receivable", client) == m.advances_open(client), (
                    "4112", name)  # fmt: skip
            if on("419"):
                assert _book(b, "client_credit_owed", client) == -m.credits_open(client), (
                    "419", name, _book(b, "client_credit_owed", client),
                    m.credits_open(client))  # fmt: skip
        if on("queue"):
            pending = {(str(c), str(k), int(a)) for c, k, a in b["pending"]}
            want = {(i.client, i.key, i.amount) for i in m.items.values() if i.run is None}
            assert pending == want, ("the queue, item by item", pending ^ want)
        if only is None and self.shared:
            # 038's d_queue / d_twice shape (M4): an uncovered negative item in the queue of a
            # client whose payout cancelled after download the bank executed late or has still to
            # execute (its re-issue not out yet), the queue in debit (its bound) — recorded when
            # reached (7a found no path under I23; review round 1, MACH-5: no longer any negative
            # queue after a cancellation)
            late_or_out = {
                self.m.runs[t.run].client
                for t in m.transfers.values()
                if t.replaced_by
                and t.run
                and (t.late or m.transfers[t.replaced_by].status in ("ordered", "in_file"))
            }
            for c in late_or_out:
                queue_c = m.pending(c)
                uncovered = [
                    i
                    for i in queue_c
                    if i.amount < 0
                    and i.kind == "reversal"
                    and i.key not in m.covers
                    and i.key not in m.cover_at_booking
                ]
                if uncovered and sum(i.amount for i in queue_c) < 0:
                    event(
                        "M4 d_queue/d_twice shape: an uncovered negative item, the queue in debit,"
                        " beside a payout executed after its cancellation"
                    )
        if on("covers"):
            covers = {str(k): int(x) for k, x in b["covers"].items()}
            assert covers == m.covers, ("the covers", covers, m.covers)
        if on("MONEY-5"):
            docs = {str(k): int(x) for k, x in b["documents"].items()}
            want_docs = {d.id: d.open for d in m.documents.values() if d.kind == "invoice"}
            assert docs == want_docs, ("MONEY-5 / I18: each invoice's open part",
                                       {k: (docs.get(k), want_docs.get(k))
                                        for k in docs.keys() | want_docs
                                        if docs.get(k) != want_docs.get(k)})  # fmt: skip
        for aid, open_minor in b["advances"].items():
            a = m.advances.get(str(aid))
            if on("advance unknown"):
                assert a is not None, ("an advance the model does not know", aid)
            if on("advance open") and a is not None:
                assert int(open_minor) == a.open, ("advance open", aid, open_minor, a.open)
        if on("5120"):
            assert _book(b, "client_money_cash") == m.bank, (
                "5120 = the bank", _book(b, "client_money_cash"), m.bank)  # fmt: skip
        if on("4710"):
            assert _book(b, "unallocated_payment") == -sum(
                p.unallocated for p in m.payments.values()), "4710"  # fmt: skip
        if on("4679"):
            assert _book(b, "due_to_servicer") == m.due_to_servicer, (
                "4679", _book(b, "due_to_servicer"), m.due_to_servicer)  # fmt: skip
        if on("5122"):
            assert _book(b, "own_cash") == m.own_cash, ("5122", _book(b, "own_cash"), m.own_cash)
        if on("44574"):
            assert _book(b, "vat_pending") == -m.vat_pending, (
                "44574", _book(b, "vat_pending"), m.vat_pending)  # fmt: skip
        if on("44571"):
            assert _book(b, "vat_collected") == -m.vat_due, (
                "44571", _book(b, "vat_collected"), m.vat_due)  # fmt: skip
        if on("M6"):
            assert int(b["requested_reversed"]) == 0, (
                "M6: a live request names a reversed advance")  # fmt: skip
        booked = [r for r in m.runs.values() if r.status == "booked"]
        if booked and on("check 2"):
            paid = {str(r[0]): r[1] for r in q(
                """select r.id, (select s.on_date from private.run_settled_on(r.id) s)
                   from public.remittance_run r where r.id = any(%s::uuid[])""",
                [r.id for r in booked])}  # fmt: skip
            expected = {r.id: m.settled_on(r.id) for r in booked}
            assert paid == expected, ("[check 2] the client was paid (run_settled_on)", paid,
                                      expected)  # fmt: skip

    # -- quiescence -----------------------------------------------------------------------------

    def _quiesce(self) -> None:
        """Every transfer filed, executed and booked, every top-up credited, the last sweep
        debited; then the end-of-example checks."""
        # (review round 2, MACH-1) the hold rule first, as `file_and_download` applies it: a payout
        # ordered to an account that came back since (its client not run again) is held, so its run
        # is cancelled below with the others (the first file would otherwise hold it for good)
        self._hold_returned()
        for t in [t for t in self.m.transfers.values() if t.kind == "payout" and t.status ==
                  "ordered" and (t.held or (t.run and sum(x.amount for x in self.m.pending(
                      self.m.runs[t.run].client)) < 0))]:  # fmt: skip
            # held for good, or not covered: ops cancel its run (prepared again later)
            self.cancel_before_download(0, only=t)
        for _ in range(6):
            self.hourly_top_up()
            while any(t.kind == "top_up" and t.status in ("ordered", "in_file")
                      for t in self.m.transfers.values()):  # fmt: skip
                self.top_up_credited(0)
            self.file_and_download()
            while any(t.status == "downloaded" for t in self.m.transfers.values()):
                self.bank_debits(0, False)
            self.the_books_are_the_models()
            flight = [t for t in self.m.transfers.values()
                      if t.status in ("ordered", "in_file", "downloaded")]  # fmt: skip
            if not flight and self.m.due_to_servicer == 0:
                break
        # (review round 1, MACH-1) every transfer left the bank: none still ordered, in a file or
        # handed out (held payouts were cancelled above)
        flight = [t for t in self.m.transfers.values()
                  if t.status in ("ordered", "in_file", "downloaded")]  # fmt: skip
        assert not flight, ("quiescence: transfers that never left the bank", flight)
        assert self.m.due_to_servicer == 0, ("Σ4679 at quiescence", self.m.due_to_servicer)
        assert self.ww.bank == self.m.bank
        self.nightly()
        self.final_checks()

    def final_checks(self, only: str | None = None) -> None:
        """M7-MONEY-1 (what each client received), MONEY-10 (every open advance and credit owed
        back alerted 30 days on), the advance checks clean; `only` runs one."""
        w = self.ww
        for name, client in self.clients.items():
            if only not in (None, "received"):
                break
            received = int(v(
                """select coalesce(sum(p.amount_minor), 0) from public.ledger_entry e
                   join public.ledger_posting p on p.entry_id = e.id
                   join public.ledger_account la on la.id = p.ledger_account_id
                     and la.book = 'client_payable'
                   where e.organization_id = %s and e.client_organization_id = %s
                     and (e.entry_type = 'remittance'
                          or (e.entry_type = 'reversal' and exists (
                                select 1 from public.ledger_entry o
                                where o.id = e.reverses_entry_id
                                  and o.entry_type = 'remittance')))""",
                w.org, client))  # fmt: skip
            assert received == self.m.received.get(client, 0), (
                "M7-MONEY-1 received",
                name,
                received,
                self.m.received,
            )
        if only == "received":
            return
        on = today() + timedelta(days=31)
        rows = advance_checks(w, on, full=True)
        alerted = {r[2] for r in rows if r[0] == "advance_open"}
        declared = {r[2] for r in rows if r[0] == "claims_to_declare"}
        open_ids = {a.id for a in self.m.advances.values()
                    if a.open > 0 and a.client not in self.m.bars}  # fmt: skip
        assert open_ids <= alerted, ("MONEY-10: every open advance alerted 30 days on",
                                     open_ids - alerted)  # fmt: skip
        # a client in a proceeding or a liquidation: its open advances are claims to declare
        barred = {a.id for a in self.m.advances.values() if a.open > 0 and a.client in self.m.bars}
        assert barred <= declared | alerted, ("MONEY-10: a barred client's open advance listed",
                                              barred - declared - alerted)  # fmt: skip
        owed = {r[2] for r in rows if r[0] == "client_credit_owed"}
        open_credits = {c.id for c in self.m.credits.values() if c.open > 0}
        assert open_credits <= owed, ("MONEY-10: every credit owed back alerted 15 days on",
                                      open_credits - owed)  # fmt: skip
        assert not [r for r in rows if r[1] == "violation"], rows


class SwitchOffMachine(CloseOutMachine):
    shared = False


class SwitchOnMachine(CloseOutMachine):
    """The switch on, in one transaction: the cancellation after download (two people, on the
    evidence of the statements), the bank executing a cancelled payout late (a late predecessor:
    booked as its run's payout, its re-issue cancelled), and its return."""

    shared = True
    ACTIONS = (*CloseOutMachine.ACTIONS, "cancel_after_download", "cancel_after_download",
               "late_execution", "late_execution", "late_return", "late_cycle")  # fmt: skip

    def _do(self, action: str, data: st.DataObject) -> None:
        if action == "late_cycle":
            return self.late_cycle(data.draw(st.integers(20_000, 300_000), label="amount"))
        if action in ("cancel_after_download", "late_execution", "late_return"):
            i = data.draw(st.integers(0, 99), label="i")
            return getattr(self, action)(i)  # type: ignore[no-any-return]
        return super()._do(action, data)

    def cancel_after_download(self, i: int) -> None:
        """A downloaded file of payouts the bank never executed, cancelled whole once the
        statements of its days show nothing of it: asked by the ops manager, confirmed by an admin
        (each at aal2). Its payouts cancelled and re-issued under fresh ids (ordered again)."""
        files = list(dict.fromkeys(t.file for t in self.m.transfers.values()
                                   if t.file and t.status == "downloaded"))  # fmt: skip
        cands = [f for f in files
                 if all(t.status == "downloaded" and t.kind == "payout"
                        for t in self.m.transfers.values() if t.file == f)]  # fmt: skip
        if not cands:
            return
        fid = cands[i % len(cands)]
        day, after = business_days_back(2)
        file_dated_back(fid, day)
        evidence_statement(self.ww, day, after)
        version = v("select version from public.transfer_file where id = %s", fid)
        asked = self._ops("select public.request_transfer_file_cancellation(%s, %s, %s, %s, %s)",
                          str(uuid.uuid4()), fid, version, "Fichier non déposé (machine)",
                          "not_uploaded")  # fmt: skip
        assert asked["status"] == "requested", asked
        done = self._ops("select public.confirm_transfer_file_cancellation(%s, %s, %s)",
                         str(uuid.uuid4()), fid, version, user=self.ww.tenant["admin"])  # fmt: skip
        assert done["status"] == "superseded", done
        for t in [t for t in self.m.transfers.values() if t.file == fid]:
            new = q("""select id::text, end_to_end_id, amount_minor, status
                       from public.bank_transfer
                       where replaces_transfer_id = %s""", t.id)  # fmt: skip
            assert len(new) == 1, ("re-issued once", t, new)
            nid, e2e, amount, status = new[0]
            assert (int(amount), status) == (t.amount, "ordered"), new
            t.status, t.replaced_by = "cancelled", str(nid)
            self.m.transfers[str(nid)] = FTransfer(
                str(nid), t.kind, t.amount, str(e2e), run=t.run,
                held=bool(t.run) and self._held_by_event(t.run or ""),
            )  # fmt: skip
        event("cancelled after download, re-issued")

    def late_execution(self, i: int) -> None:
        """The bank executes a payout cancelled after download anyway, on its old RMT id, while
        its re-issue is not handed out: the debit job never books it (reviewed); « Comptabiliser… »
        books it as its run's payout (a late predecessor) and cancels the re-issue."""
        cands = [t for t in self.m.transfers.values()
                 if t.kind == "payout" and t.status == "cancelled" and t.replaced_by
                 and not t.late and self.m.transfers[t.replaced_by].status == "ordered"
                 and t.run and self.m.runs[t.run].status == "approved"]  # fmt: skip
        if not cands:
            return
        t = cands[i % len(cands)]
        sid = bank_statement(self.ww, [transfer_debit_entry(t.amount, t.e2e)])
        (line,) = (str(r[0]) for r in q(
            "select id from public.bank_transaction where statement_id = %s", sid))  # fmt: skip
        assert q("select reason from public.bank_debit_review where bank_transaction_id = %s",
                 line) == [("cancelled_transfer_debited",)]  # fmt: skip
        res = book_line(self.ww, line, "payout")
        part = res["proposal"]["preview"]["parts"][0]
        assert (part["transfer_id"], part["late_predecessor"]) == (t.id, True), part
        t.late, t.status = True, "debited"
        self.m.transfers[t.replaced_by or ""].status = "cancelled"
        self.m.bank -= t.amount
        assert t.run is not None
        self._booked(t.run, self.ww.day)  # the bank's booking day of its line
        event("late predecessor booked as its run's payout")

    def late_cycle(self, amount: int) -> None:
        """M5 in one step: a payout-only file handed out and cancelled after download, the bank
        executing the cancelled payout anyway (booked as its run's payout), then returning it — what
        it carried owed again, taken by the client's next run, paid at its debit ([check 2]'s rule
        3: the first run paid on the later run's day)."""
        free = [s for s in (1, 2) if self.ww.slots[s].client not in self.m.bars]
        if not free:
            return
        slot = free[amount % len(free)]
        client = self.ww.slots[slot].client
        self.file_and_download()  # what is due out first (the sweep, other payouts), debited
        while any(t.status == "downloaded" and t.kind in ("payout", "refund", "sweep")
                  for t in self.m.transfers.values()):  # fmt: skip
            self.bank_debits(0, False)
        self.collect(slot, amount, 0)
        self._run_client(client)
        self.file_and_download()
        mine = [t for t in self.m.transfers.values() if t.kind == "payout" and t.status ==
                "downloaded" and t.run and self.m.runs[t.run].client == client]  # fmt: skip
        if not mine:
            return
        self.cancel_after_download(0)
        late = [t for t in self.m.transfers.values() if t.id == mine[0].id and t.replaced_by]
        if not late:
            return
        self.late_execution(0)
        self.late_return(0)
        self._run_client(client)
        self.file_and_download()
        while any(t.status == "downloaded" and t.kind in ("payout", "refund", "sweep")
                  for t in self.m.transfers.values()):  # fmt: skip
            self.bank_debits(0, False)
        event("macro: a late cycle")

    def late_return(self, i: int) -> None:
        """The late predecessor comes back: the job reviews it (it differs from what was filed);
        « Comptabiliser… » books it as the payout's return — what it carried is owed again."""
        cands = [t for t in self.m.transfers.values() if t.late and t.status == "debited"]
        if not cands:
            return
        t = cands[i % len(cands)]
        assert t.file is not None and t.run is not None
        sid = bank_statement(self.ww, file_entries(self.ww.files[t.file], returns=(t.e2e,),
                                                   only_returns=True))  # fmt: skip
        (line,) = (str(r[0]) for r in q(
            "select id from public.bank_transaction where statement_id = %s", sid))  # fmt: skip
        self.m.bank += t.amount
        if not q("select 1 from public.bank_line_booking where bank_transaction_id = %s", line):
            book_line(self.ww, line, "returned")
        t.status = "returned"
        item = v(
            """select q.ledger_entry_id::text from private.remittance_pending q
               join public.ledger_entry e on e.id = q.ledger_entry_id
               join public.ledger_entry r on r.id = e.reverses_entry_id
               where q.kind = 'payout_returned' and r.idempotency_key = %s""",
            f"remit:{t.id}",
        )
        self.m.payout_returned(t.run, item)
        event("late predecessor returned")


_SETTINGS = settings(
    max_examples=EXAMPLES,
    stateful_step_count=STEPS,
    deadline=None,
    # each step runs the product (commands, jobs, statements) while Hypothesis draws: generating an
    # example is slow (too_slow) and an example of 20-60 steps draws much (data_too_large,
    # large_base_example: _min_steps makes the smallest one long on purpose)
    suppress_health_check=[
        HealthCheck.too_slow,
        HealthCheck.data_too_large,
        HealthCheck.large_base_example,
    ],
    print_blob=True,
    # a failing example is printed whole (its blob replays it); shrinking it through the database
    # takes minutes per attempt, so it is opt-in (MACHINE_SHRINK=1), never in the PR's budget
    phases=tuple(Phase)
    if os.environ.get("MACHINE_SHRINK")
    else tuple(p for p in Phase if p not in (Phase.shrink, Phase.explain)),
)


def test_the_close_out_machine_switch_off() -> None:
    """Switch off: every step committed (each example its own servicer). Every example runs its
    MACHINE_STEPS steps (`_min_steps`: Hypothesis would otherwise try short ones first)."""
    SEEN.clear()
    try:
        run_state_machine_as_test(SwitchOffMachine, settings=_SETTINGS, _min_steps=STEPS - 1)
    finally:
        print("\nswitch off reached:", json.dumps(dict(sorted(SEEN.items())), indent=1))


def test_the_close_out_machine_switch_on() -> None:
    """Switch on: each example in one transaction, rolled back at its end; run last (V4)."""
    SEEN.clear()
    try:
        run_state_machine_as_test(SwitchOnMachine, settings=_SETTINGS, _min_steps=STEPS - 1)
    finally:
        print("\nswitch on reached:", json.dumps(dict(sorted(SEEN.items())), indent=1))


# -- every check can fail ------------------------------------------------------------------------


@contextmanager
def _planted(machine: CloseOutMachine) -> Iterator[psycopg.Connection[Any]]:
    """A state planted for one check: the database's in a savepoint of the example's one
    transaction (rolled back), the model's on a copy (put back)."""
    model, world = copy.deepcopy(machine.m), copy.deepcopy(machine.w)
    try:
        with psycopg.connect(DB) as conn, conn.transaction() as tx:
            yield conn
            raise psycopg.Rollback(tx)
    finally:
        machine.m, machine.w = model, world


def _raw_remittance(conn: psycopg.Connection[Any], machine: CloseOutMachine, client: str,
                    amount: int) -> None:  # fmt: skip
    """(planted) a payout booked beyond what the client is owed, posted raw: 4670 in debit (LG008
    would refuse it at commit; the savepoint never commits)."""
    w = machine.ww
    conn.execute("select private.ledger_post_set_begin()")
    conn.execute(
        """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date,
             idempotency_key, client_organization_id, source_type, source_id)
           values (1, %s, 'remittance', private.paris_today(), %s, %s, 'bank_transfer', %s)""",
        (w.org, f"plant:{uuid.uuid4()}", client, str(uuid.uuid4())),
    )
    conn.execute(
        """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency,
             bank_account_id)
           values (1, 1, 'client_payable', %s, 'EUR', null),
                  (1, 2, 'client_money_cash', %s, 'EUR', %s)""",
        (amount, -amount, w.tenant["bank"]),
    )
    conn.execute("select private.ledger_post_set()")


def _need_plus_one(f: FundsModel) -> None:
    """(planted) the model's top-up need one cent above what it is (rule 19's floor lifted)."""
    base = f.top_up_needed()
    f.due_to_servicer = 10**12
    flight = f.top_up_needed() - 10**12  # the sweeps in flight less the top-ups ordered or filed
    f.due_to_servicer = base + 1 - flight


def test_every_check_can_fail() -> None:  # noqa: PLR0915 - one plant per check
    """None of the machine's checks is vacuous: after a short fixed scenario (switch on, one
    transaction rolled back), each check passes, then fails on a state planted to break it — in
    the database (a raw posting, a raw reversal, rolled back to a savepoint) or in the model (one
    figure moved, put back after) — with its own message. The probes' own refusals (LG009, LG003,
    MONEY-2, the withheld set-off) are shown failing by the mutants instead (ADR-0014 « M2c-7f-2 »,
    the X1 table)."""
    m = SwitchOnMachine()
    m.world()
    try:
        lilas, martin, durand = (m.clients[n] for n in ("lilas", "martin", "durand"))
        m.remit(2, 120_000, 1)
        m.remit(2, 80_000, 1)
        for e in [k for k in m.collections if m.m.items[k].client == lilas]:
            m._desimputer(e)  # remitted: two covers, Lilas's open advances
        m.repayment_request(1)  # Lilas (no claw-back clause): both advances requested
        m.remit(3, 100_000, 1)  # Durand (no netting): an invoice the client pays
        m.client_payment(8)  # all of it and 50 EUR more: a credit owed back
        m.remit(3, 60_000, 1)  # Durand's next invoice, left open
        m.remit(0, 150_000, 1)  # MARTIN-1, remitted, then reversed: an advance on MARTIN-1
        m._desimputer(m.collections[-1])
        m.check_books()
        m.nightly()
        m.final_checks()
        failed: list[str] = []

        def fails(label: str, check: Any) -> None:
            with pytest.raises(AssertionError) as info:
                check()
            assert label in str(info.value), (label, str(info.value)[:400])
            failed.append(label)

        message = {"queue": "the queue, item by item", "advance unknown": "does not know",
                   "check 2": "[check 2]"}  # fmt: skip

        planted: set[str] = set()

        def moved(only: str, move: Any) -> None:
            """The books' check `only` on the model with one figure moved."""
            planted.add(only)
            with _planted(m):
                move(m.m)
                fails(message.get(only, only), lambda: m.check_books(only))

        advance = next(a for a in m.m.advances.values() if a.client == lilas)
        invoice = next(d for d in m.m.documents.values() if d.kind == "invoice" and d.open > 0)
        credit = next(iter(m.m.credits.values()))
        item = next(i for i in m.m.items.values() if i.run is None)
        booked = next(r for r in m.m.runs.values() if r.status == "booked" and not r.returned)
        moved("I14", lambda f: f.items.__setitem__("x", FItem("x", lilas, None, 1, "collection")))
        moved("4111", lambda f: setattr(f.documents[invoice.id], "open", invoice.open + 1))
        moved("4112", lambda f: setattr(f.advances[advance.id], "settled", advance.settled - 1))
        moved("419", lambda f: setattr(f.credits[credit.id], "refunded", credit.refunded + 1))
        moved("queue", lambda f: f.items.__setitem__(
            "y", dataclasses.replace(f.items.pop(item.key), key="y")))  # fmt: skip
        moved("covers", lambda f: f.covers.__setitem__(next(iter(f.covers)), 1))
        moved("MONEY-5", lambda f: setattr(f.documents[invoice.id], "open", invoice.open - 1))
        moved("advance unknown", lambda f: f.advances.__setitem__("z", f.advances.pop(advance.id)))
        moved("advance open", lambda f: setattr(f.advances[advance.id], "written_off", 1))
        moved("5120", lambda f: setattr(f, "bank", f.bank + 1))
        moved("4710", lambda f: setattr(next(iter(f.payments.values())), "out", 1))
        moved("4679", lambda f: setattr(f, "due_to_servicer", f.due_to_servicer + 1))
        moved("5122", lambda f: setattr(f, "own_cash", f.own_cash + 1))
        moved("44574", lambda f: setattr(f, "vat_pending", f.vat_pending + 1))
        moved("44571", lambda f: setattr(f, "vat_due", f.vat_due + 1))
        moved("check 2", lambda f: setattr(f.runs[booked.id], "booked_on", None))

        # I13 and the nightly: a payout posted raw beyond what Lilas is owed (4670 in debit)
        with _planted(m) as conn:
            _raw_remittance(conn, m, lilas, -m.m.payable(lilas) + 1)
            fails("I13", lambda: m.check_books("I13"))
            planted.add("I13")
            fails("client_payable_debit", m.nightly)
        # M6: a requested advance's entry reversed raw (the product's paths refuse it)
        with _planted(m) as conn:
            entry = v("select entry_id from public.client_advance where id = %s", advance.id)
            conn.execute("select private.ledger_reverse(%s, %s, 'brut', private.paris_today())",
                         (entry, f"raw:{uuid.uuid4()}"))  # fmt: skip
            fails("M6", lambda: m.check_books("M6"))
            planted.add("M6")
        assert planted == set(CloseOutMachine.CHECKS), set(CloseOutMachine.CHECKS) ^ planted
        # the end-of-example checks (MONEY-1, MONEY-10) and rule 19 (H2)
        with _planted(m):
            m.m.received[lilas] = m.m.received.get(lilas, 0) + 1
            fails("M7-MONEY-1 received", lambda: m.final_checks("received"))
        with _planted(m):
            m.m.advances["ghost"] = dataclasses.replace(advance, id="ghost", settled=0)
            fails("every open advance alerted", m.final_checks)
        with _planted(m):
            m.m.credits["ghost"] = FCredit("ghost", lilas, 1)
            fails("every credit owed back alerted", m.final_checks)
        with _planted(m):
            _need_plus_one(m.m)
            fails("servicer_shortfall", m.nightly)
        with _planted(m):
            _need_plus_one(m.m)
            fails("the hourly top-up orders", m.hourly_top_up)
        # the steps' own checks: the plan (M3), the draft, the payment's parts, the covers, VAT
        with _planted(m):
            for a in m.m.advances.values():
                if a.mandate == m.ww.slots[0].mandate:
                    a.requested_by.add("planted")  # the model holds it requested: not taken
            m.collect(0, 90_000, 0)
            fails("the run's plan", lambda: m._run_client(martin))
        with _planted(m):
            m.collect(1, 30_000, 0)
            m.m.items["x"] = FItem("x", martin, None, 1, "collection")
            fails("the draft's lines are the queue", lambda: m._run_client(martin))
        with _planted(m):
            m.remit(3, 40_000, 1)  # two open invoices of Durand: their order swapped in the model
            b, c = sorted((d for d in m.m.documents.values()
                           if d.client == durand and d.kind == "invoice" and d.open > 0),
                          key=lambda d: d.number)  # fmt: skip
            b.number, c.number = c.number, b.number
            fails("rule 12", lambda: m.client_payment(2))
        with _planted(m):
            m.remit(2, 50_000, 1)
            e = m.collections[-1]
            m.m.runs[m.m.items[e].run or ""].status = "approved"  # the model: still in flight
            fails("covered at", lambda: m._desimputer(e))
        with _planted(m):
            m.remit(2, 45_000, 1)
            e = m.collections[-1]
            m.m.items[e].mandate = m.ww.slots[0].mandate  # the model: another mandate's money
            fails("the cover's mandate", lambda: m._desimputer(e))
        with _planted(m):
            m.collect(2, 70_000, 0)  # Lilas: her advances requested, so a payout
            m._run_client(lilas)
            m.file_and_download()
            t = next(t for t in m.m.transfers.values()
                     if t.kind == "payout" and t.status == "downloaded")  # fmt: skip
            for doc in m.m.documents.values():
                if doc.in_flight == t.run:
                    doc.pending_vat += 1
            fails("VAT moved pro rata", lambda: m.bank_debits(0, False))
        with _planted(m):
            m.collect(2, 60_000, 0)
            m._run_client(lilas)
            for t in m.m.transfers.values():
                if t.kind == "payout" and t.status == "ordered":
                    t.held = True  # the model: held, yet the file takes it
            fails("a held payout filed", m.file_and_download)
        with _planted(m):
            m.remit(2, 80_000, 1)  # Lilas's credit notes refunded with it: 4679 in debit
            m.hourly_top_up()  # what the servicer owes the account, paid in
            while any(t.kind == "top_up" and t.status == "ordered" for t in m.m.transfers.values()):
                m.top_up_credited(0)
            m.remit(2, 100_000, 1)  # its commission, owed to the servicer: swept by the next file
            m.m.due_to_servicer = 0  # the model: nothing to sweep
            fails("the sweep within the servicer's share", m.file_and_download)
        print("\nevery check failed on its plant:", failed)
    finally:
        m.teardown()


def test_a_sweep_in_flight_then_an_advance() -> None:
    """X1's H2 (`servicer_shortfall`'s sweeps term), its state reached whatever the seed (review
    round 1, MACH-4): from a fresh world (switch on, one transaction rolled back), what the
    servicer owes the account paid in, Lilas's collection remitted (its commission swept by the
    next file, not yet debited), then a remitted collection « désimputée » (an advance owed to the
    account): the nightly's shortfall is the hourly order's own amount, the sweep in flight counted
    (rule 19), before and after the hourly top-up."""
    m = SwitchOnMachine()
    m.world()
    try:
        reached = "macro: a sweep in flight, then an advance"
        before = SEEN[reached]
        m.sweep_in_flight(100_000)
        assert SEEN[reached] == before + 1, ("the sweep in flight not reached", dict(SEEN))
        m.check_books()
    finally:
        m.teardown()
