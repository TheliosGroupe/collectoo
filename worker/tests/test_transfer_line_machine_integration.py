"""M2c-6b-2b, the stateful bank model (needs `make up`; plan docs/design/m2c-6b-2-plan.md §8.2
« Stateful (6b-2b) »; ADR-0014 « M2c-6b-2b deferred tests »).

A Hypothesis RuleBasedStateMachine drives one servicer, two clients and their runs through the real
imports, jobs and the command (as an aal2 API session), against a model of what the bank did:

* rules: a collection paid and the client's run requested, prepared and approved (the jobs); the
  next file generated, written and downloaded (refused cash_not_covered once the bank's second
  executions left the account short of it, or nothing_to_file when it would hold only payouts of
  clients whose payout account a return blocked); a run cancelled before its file (the switch
  off: no cancellation after download); the bank executes a handed-out payout on its RMT id
  (once, then late again: twice), executes a whole PmtInf as one batch line or short of its last
  member, executes a payout cancelled before its file anyway (never handed out), and returns a
  debited copy — flagged by the bank or not; no rule has a precondition (each is a no-op when
  nothing applies);
* after each bank statement the debit job runs, then ops book every line it left through the
  options' proposal (`transfer_line_options` → `book_transfer_line` with its request and expected
  text), and the funds passes the command queued run; a line « Comptabiliser… » is offered on
  (`bookable_as`) that the options propose nothing for gives its refusal (review 6b-2c T9);
* invariants after each step: every bank line is booked, linked or reviewed; the nightly checks
  are clean — 5120 equals the bank (I9/I19: the ledger cash plus the lines not booked is the last
  statement's closing), each transfer booked once, each client's 4670 never in debit (I13: no client
  is paid more than it is owed plus its open advances, no client's money pays another's), I14, I20;
  every double_payout advance is A - P of its unplanned booking, P its attributions; no item is
  attributed more than its own amount (P never above what the items still owed); and the model's
  count of debits and returns of each transfer bounds the ledger's (booked, unplanned, returned) —
  from below too (review 6b-2c T9): a payout debited on its own RMT id is booked as its payout.
"""

from __future__ import annotations

import hashlib
import json
import tempfile
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import psycopg
import pytest
from allocation_helpers import credit as bank_credit
from debit_helpers import api
from hypothesis import HealthCheck, event, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, initialize, invariant, rule
from integration_helpers import DB, storage
from psycopg.types.json import Jsonb
from remittance_helpers import approve, request_run, run_row, staff
from remittance_helpers import drain as drain_remittances
from statement_helpers import drain as drain_payments
from test_debit_bookings_integration import _replace_payout_account
from test_transfer_files_integration import _bytes, _file, _file_row, _generate, _two_runs
from test_transfer_line_foundations_integration import _day, _statement
from test_transfer_line_ops_integration import REASON

from collectoo_worker.remittance import pain001
from collectoo_worker.synth.camt053 import TRANSFER_DEBIT_CODE, Entry, Tx, debits_of
from collectoo_worker.synth.reconciliation import credit_entries

pytestmark = pytest.mark.integration

DIRTY = (
    "client_money_identity", "own_fund_identity", "fund_mirror", "client_payable_debit",
    "remittance_completeness", "bank_cash_identity", "bank_line_booked", "transfer_booked_once",
    "bank_balance_gap", "remittance_item_twice", "remittance_run_totals", "settlement_ledger",
    "vat_pending_ledger",
)  # fmt: skip


@dataclass
class Paid:
    """What the bank did with one of our payouts (the model)."""

    id: str
    e2e: str
    amount: int
    client: str
    payee_iban: str
    file: str | None = None
    executed: int = 0
    returned: int = 0
    rmt: int = 0  # how many of the executions carried its own RMT id (the `execute` rule)


@dataclass
class World:
    tenant: dict[str, Any]
    clients: list[dict[str, Any]]
    tmp: Path
    payouts: dict[str, Paid] = field(default_factory=dict)
    # file id → its bytes, in the order handed out. The picks follow the model's own order, never
    # random ids, and no rule has a precondition (each is a no-op when nothing applies): what the
    # database answers (execution dates and holds read from the clock, ids) never changes which
    # values Hypothesis draws, so a replayed choice sequence draws the same (its data tree)
    files: dict[str, bytes] = field(default_factory=dict)
    lines: list[str] = field(default_factory=list)


def _q(sql: str, *params: Any) -> list[tuple[Any, ...]]:
    with psycopg.connect(DB) as conn:
        return [tuple(r) for r in conn.execute(sql, params).fetchall()]


def _transfers(w: World) -> None:
    """The model's payouts refreshed from the servicer's transfers (new ones added)."""
    rows = _q(
        """select t.id::text, t.end_to_end_id, t.amount_minor, t.client_organization_id::text,
                  t.payee_iban, t.transfer_file_id::text
           from public.bank_transfer t where t.organization_id = %s and t.kind = 'payout'
           order by t.created_at, t.amount_minor, t.id""",
        w.tenant["servicer"],
    )
    for tid, e2e, amount, client, iban, file in rows:
        p = w.payouts.setdefault(tid, Paid(tid, e2e, int(amount), client, iban))
        p.file = file or p.file


def _status(tid: str) -> str:
    return str(_q("select status from public.bank_transfer where id = %s", tid)[0][0])


def _ops_book(w: World, statement_id: str) -> None:
    """The debit job has run on the statement; ops book each line it left through the options'
    proposal; the funds passes the command queued then run."""
    lines = [
        str(r[0])
        for r in _q(
            "select id::text from public.bank_transaction where statement_id = %s order by line_no",
            statement_id,
        )
    ]
    w.lines += lines
    for line in lines:
        if _q("select 1 from public.bank_line_booking where bank_transaction_id = %s", line):
            continue
        opts = api(w.tenant, "select public.transfer_line_options(%s)", line)
        assert opts is not None
        if not opts["proposals"]:
            # (review 6b-2c T9) a line « Comptabiliser… » is offered on (the queue's bookable_as)
            # proposes a booking or says why not: never left unbooked with neither — an options
            # read that proposed nothing would otherwise pass the model (a review counts as seen)
            (bookable,) = _q("select private.transfer_line_bookable_as(%s)", line)[0]
            assert bookable is None or opts["refusal"] is not None, (line, bookable, opts)
            continue
        p = opts["proposals"][0]
        res = api(
            w.tenant,
            "select public.book_transfer_line(%s, %s, %s, %s, %s)",
            str(uuid.uuid4()),
            line,
            Jsonb(p["request"]),
            p["preview"]["expected_text"],
            REASON,
        )
        assert res is not None and res["bookings"], res
        event("ops booked: " + "+".join(sorted(b["kind"] for b in res["bookings"])))
    drain_payments(storage())
    drain_remittances()


def _debit(p: Paid, ref: str, day: Any) -> Entry:
    """The bank's debit of one payout on its own RMT id."""
    return Entry(p.amount, False, day, day, ref=ref, code=TRANSFER_DEBIT_CODE,
                 txs=(Tx(p.amount, end_to_end_id=p.e2e),))  # fmt: skip


class BankModel(RuleBasedStateMachine):
    w: World

    @initialize()
    def servicer(self) -> None:
        tenant, other, _r1, _r2 = _two_runs()  # Martin's and Lilas' runs approved
        self.w = World(tenant, [tenant, other], Path(tempfile.mkdtemp(prefix="bank-model-")))
        _transfers(self.w)
        self._file()

    # -- the servicer's side ------------------------------------------------------------------

    @rule(c=st.integers(0, 1), amount=st.sampled_from([50_000, 120_000, 200_000]))
    def collect_and_approve(self, c: int, amount: int) -> None:
        client = self.w.clients[c]
        live = _q(
            """select 1 from public.remittance_run where client_organization_id = %s
                 and status in ('draft', 'approved', 'sent')""",
            client["client"],
        )
        if live:
            return
        if _q(
            """select 1 from public.client_payout_account where client_organization_id = %s
                 and status = 'returned'""",
            client["client"],
        ):
            _replace_payout_account(client)
        f = _file(client, amount)
        # on the account's next statement (opened with the last closing: the bank's balance chains)
        _statement(client, credit_entries([bank_credit(amount, rf=f.rf)], start=_day(client),
                                          prefix=f"M{uuid.uuid4().hex[:6].upper()}"))  # fmt: skip
        run = request_run(client)
        if run_row(run)["blockers"]:
            return
        approve(client, run)
        drain_remittances()
        event("servicer: a run approved")
        _transfers(self.w)

    @rule()
    def file_and_download(self) -> None:
        if not any(_status(p.id) == "ordered" for p in self.w.payouts.values()):
            return
        event("servicer: file handed out")
        self._file()

    def _file(self) -> None:
        try:
            res = _generate(self.w.tenant)
        except psycopg.errors.CheckViolation as e:
            detail = json.loads(e.diag.message_detail or "{}")
            if "nothing_to_file" in str(e):
                # (6b-2c review round 2) a run approved before its client's earlier payout came
                # back: the return blocks that client's payout account (« returned », until it is
                # replaced or confirmed again), so the next file holds the run's payout — and,
                # holding every ordered transfer, is refused. Only so: each held item is a payout
                # of a client one of whose payouts the model returned
                held = detail["held"]
                returned = {q.client for q in self.w.payouts.values() if q.returned > 0}
                assert held, detail
                for h in held:
                    assert h["reason"] == "payout_blocked:payout_account_returned", detail
                    assert self.w.payouts[h["transfer_id"]].client in returned, (detail, returned)
                event("servicer: file refused, every payout held by a returned account")
                return
            # the bank paid payouts twice: the account may hold less than the next file needs —
            # the file is refused (the servicer covers its advances first), never made short
            assert "cash_not_covered" in str(e), e
            assert int(detail["needed_minor"]) > int(detail["available_minor"]), detail
            event("servicer: file refused, cash not covered")
            return
        drain_remittances()
        if not res or not res.get("file_id"):
            return
        f = _file_row(res["file_id"])
        if f["status"] != "generated":
            return
        data = _bytes(f["storage_path"], self.w.tmp)
        staff(self.w.tenant, "select public.transfer_file_download(%s, %s)", f["id"],
              hashlib.sha256(data).hexdigest())  # fmt: skip
        self.w.files[str(f["id"])] = data
        _transfers(self.w)

    @rule(i=st.integers(0, 99))
    def cancel_before_download(self, i: int) -> None:
        runs = _q(
            """select r.id::text, r.version from public.remittance_run r
               join public.bank_transfer t on t.id = r.transfer_id
               where r.organization_id = %s and r.status = 'approved' and t.status = 'ordered'
               order by r.created_at, r.id""",
            self.w.tenant["servicer"],
        )
        if not runs:
            return
        run, version = runs[i % len(runs)]
        event("servicer: a run cancelled before its file")
        staff(self.w.tenant, "select public.cancel_remittance_run(%s, %s, %s, %s)",
              str(uuid.uuid4()), run, version, "annulé (machine)",
              user=self.w.tenant["admin"])  # fmt: skip
        _transfers(self.w)

    # -- the bank's side ----------------------------------------------------------------------

    def _pick(self, i: int, ok: Any) -> Paid | None:
        cands = [p for p in self.w.payouts.values() if ok(p)]  # the order the model met them
        return cands[i % len(cands)] if cands else None

    @rule(i=st.integers(0, 99))
    def execute(self, i: int) -> None:
        """The bank debits a handed-out payout on its RMT id (a second time: twice, late)."""
        p = self._pick(i, lambda p: p.executed < 2 and p.file in self.w.files)
        if p is None:
            return
        day = _day(self.w.tenant)
        entry = _debit(p, f"X{uuid.uuid4().hex[:7].upper()}", day)
        p.executed += 1
        p.rmt += 1
        event(f"bank: debit {p.executed}")
        _ops_book(self.w, _statement(self.w.tenant, [entry]))

    @rule(i=st.integers(0, 99), partial=st.booleans())
    def execute_lot(self, i: int, partial: bool) -> None:
        """The bank debits a whole file's PmtInf as one batch line (or short of its last member)."""
        fresh = [
            f for f in self.w.files
            if all(p.executed == 0 for p in self.w.payouts.values() if p.file == f)
        ]  # fmt: skip
        if not fresh:
            return
        f = fresh[i % len(fresh)]
        data = self.w.files[f]
        read = pain001.read(data)
        entries = debits_of(read, booking_date=_day(self.w.tenant),
                            mode="partial" if partial else "batch",
                            ref_prefix=f"B{uuid.uuid4().hex[:6].upper()}")  # fmt: skip
        for pmt in read.payment_infos:
            kept = (
                pmt.transactions[:-1] if partial and len(pmt.transactions) > 1 else pmt.transactions
            )
            for t in kept:
                q = next((p for p in self.w.payouts.values() if p.e2e == t.end_to_end_id), None)
                if q is not None:
                    q.executed += 1
        event("bank: lot" + (" short" if partial else ""))
        _ops_book(self.w, _statement(self.w.tenant, entries))

    @rule(i=st.integers(0, 99))
    def execute_never_handed_out(self, i: int) -> None:
        """The bank debits a payout cancelled before its file anyway: nothing of ours handed it
        out — the line is never booked as it (it waits, reviewed)."""
        p = self._pick(i, lambda p: p.executed == 0 and _status(p.id) == "cancelled")
        if p is None:
            return
        day = _day(self.w.tenant)
        entry = _debit(p, f"Y{uuid.uuid4().hex[:7].upper()}", day)
        p.executed += 1
        event("bank: a cancelled payout executed")
        _ops_book(self.w, _statement(self.w.tenant, [entry]))

    @rule(i=st.integers(0, 99), flagged=st.booleans())
    def come_back(self, i: int, flagged: bool) -> None:
        """One debited copy comes back, flagged by the bank or as a credit from the payee."""
        p = self._pick(i, lambda p: p.executed > p.returned and p.file in self.w.files)
        if p is None:
            return
        assert p.file is not None
        entries = [
            e
            for e in debits_of(
                pain001.read(self.w.files[p.file]),
                returns=[p.e2e],
                return_date=_day(self.w.tenant),
                unflagged_returns=not flagged,
                ref_prefix=f"R{uuid.uuid4().hex[:6].upper()}",
            )
            if e.credit
        ]
        p.returned += 1
        event("bank: return " + ("flagged" if flagged else "unflagged"))
        _ops_book(self.w, _statement(self.w.tenant, entries))

    # -- invariants ---------------------------------------------------------------------------

    @invariant()
    def every_line_is_booked_linked_or_reviewed(self) -> None:
        if not hasattr(self, "w"):
            return
        for line in self.w.lines:
            seen = _q(
                """select (select count(*) from public.bank_line_booking b
                           where b.bank_transaction_id = t.id)
                        + (select count(*) from public.bank_debit_link k
                           where k.bank_transaction_id = t.id)
                        + (select count(*) from public.bank_debit_review v
                           where v.bank_transaction_id = t.id)
                        + (select count(*) from public.payment p where p.bank_transaction_id = t.id)
                   from public.bank_transaction t where t.id = %s""",
                line,
            )
            assert seen and int(seen[0][0]) >= 1, line

    @invariant()
    def the_nightly_checks_are_clean(self) -> None:
        if not hasattr(self, "w"):
            return
        with psycopg.connect(DB) as conn, conn.transaction():
            row = conn.execute(
                "select private.run_payment_checks(%s)", (self.w.tenant["servicer"],)
            ).fetchone()
            assert row is not None
            bad = conn.execute(
                """select code, subject_id::text from public.payment_check_result
                   where run_id = %s and code = any(%s)""",
                (row[0]["run_id"], list(DIRTY)),
            ).fetchall()
        assert bad == [], bad

    @invariant()
    def each_advance_is_a_less_p_and_p_within_the_items(self) -> None:
        if not hasattr(self, "w"):
            return
        wrong = _q(
            """select k.bank_transaction_id::text, k.amount_minor, a.amount_minor,
                      coalesce((select sum(u.amount_minor) from private.unplanned_paid_item u
                                where u.booking_entry_id = k.entry_id), 0)
               from public.bank_line_booking k
               left join public.client_advance a on a.cause_entry_id = k.entry_id
                 and a.cause = 'double_payout'
               where k.organization_id = %s and k.kind = 'unplanned_payout'
                 and k.amount_minor - coalesce(a.amount_minor, 0)
                     <> coalesce((select sum(u.amount_minor) from private.unplanned_paid_item u
                                  where u.booking_entry_id = k.entry_id), 0)""",
            self.w.tenant["servicer"],
        )
        assert wrong == [], wrong
        over = _q(
            """select u.ledger_entry_id::text, sum(u.amount_minor),
                      (select sum(abs(p.amount_minor)) from public.ledger_posting p
                       join public.ledger_account a on a.id = p.ledger_account_id
                       where p.entry_id = u.ledger_entry_id and a.book = 'client_payable')
               from private.unplanned_paid_item u
               where u.organization_id = %s
                 and not exists (select 1 from public.ledger_entry r
                                 where r.reverses_entry_id = u.booking_entry_id)
               group by u.ledger_entry_id
               having sum(u.amount_minor) > (select sum(abs(p.amount_minor))
                                             from public.ledger_posting p
                                             join public.ledger_account a
                                               on a.id = p.ledger_account_id
                                             where p.entry_id = u.ledger_entry_id
                                               and a.book = 'client_payable')""",
            self.w.tenant["servicer"],
        )
        assert over == [], over

    @invariant()
    def the_ledger_counts_what_the_bank_did(self) -> None:
        """Each payout's debits and returns as the ledger books them never exceed the bank's, and a
        payout the job or ops booked is booked once (planned) — its other copies unplanned. Review
        6b-2c (T9), a lower bound: a payout handed out that the bank debited on its own RMT id is
        booked as its payout (by the job, or by ops through the options) — never left unbooked."""
        if not hasattr(self, "w"):
            return
        for p in self.w.payouts.values():
            (debits, returns, planned), = _q(
                """select count(*) filter (where kind in ('payout', 'unplanned_payout')),
                          count(*) filter (where kind in ('payout_returned',
                                                          'unplanned_payout_returned')),
                          count(*) filter (where kind = 'payout')
                   from public.bank_line_booking where transfer_id = %s""",
                p.id,
            )  # fmt: skip
            assert int(debits) <= p.executed, (p, debits)
            assert int(returns) <= p.returned, (p, returns)
            assert int(planned) <= 1, (p, planned)
            if p.rmt:
                assert int(planned) == 1, (p, planned)


BankModel.TestCase.settings = settings(
    max_examples=10,
    stateful_step_count=20,
    deadline=None,
    suppress_health_check=list(HealthCheck),
)
test_the_bank_model = BankModel.TestCase
