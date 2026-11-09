"""Jobs `payments.process_debits`, `payments.direct_payment` and `payments.invariants` (M2b-6).

`process_debits` (design §8.3 step 7; queued by the import, a refund request, a released
duplicate): one transaction (the queue's, exactly once) under the servicer's debit lock:

1. `private.debit_candidates`: the lines not linked yet (returns, our RFD refunds, credits undoing
   a debit; released duplicates as what they were), at most `CHUNK` after `after`, each with the
   payments or refund requests its references name and their positions (from the ledger);
2. `payments.debits.decide_all`: return / refund / refund that came back, or left to ops with why;
3. COPY the links and reviews and call `private.apply_debit_decisions`, which locks (files,
   payments, requests, bank accounts, then the allocation lock), re-checks, reverses the payment's
   allocations at the return date, books the cash_out, the payment's state, the client's
   notification, and replaces the reviews. A link refused on re-check (a command changed the
   payment meanwhile) is retried by a later run (`RETRIES` times at most, then left to ops). A
   link the posting itself refuses (a ledger check) is left to ops (`posting_failed`) and the
   others are posted: one bad line never stops a servicer's returns and refunds.

`CHUNK` lines per transaction (2,000 by default): the transaction holds the servicer's allocation
lock while it posts (~21 ms a return, docs/benchmarks/payments.md: ~45 s for a chunk, twice that
if one line fails and the chunk is posted line by line), far below the queue's 300 s visibility
timeout; the rest follows in a continuation message.

`direct_payment` (design §8.1, §9): a payment the debtor made to the client directly, as the
client's statement says: the waterfall (`payments.allocation`, the debts the client names as the
designation) splits it at its date and `private.post_direct_payment` books one adjustment
(-1100 / +3100), or the request is refused with a code (more than is due, nothing due, before the
servicing start, file closed; `failed` when the ledger refuses the plan, or when the job is
dead-lettered: `jobs.payments.record_dead_job`) — never left « en cours » for good.

`invariants` (design §9; pg_cron nightly, or « Lancer les contrôles »):
`private.run_payment_checks`.
"""

from __future__ import annotations

import logging
import os
import time
from collections import defaultdict
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.jobs.allocation import CLOSED, load_files, load_policies, resolve_policy
from collectoo_worker.payments.allocation import ENGINE_VERSION, inputs_hash
from collectoo_worker.payments.debits import (
    DebitLine,
    Decision,
    PaymentCandidate,
    RefundCandidate,
    decide_all,
)

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.payments")
CHUNK = int(os.environ.get("DEBIT_CHUNK", "2000"))
RETRY_DELAY_S = 5
RETRIES = 5  # runs re-queued for lines skipped on re-check; then they wait for ops (`changed`)


def run_process_debits(conn: Conn, payload: dict[str, Any]) -> dict[str, Any]:
    org = str(payload["organization_id"])
    after = payload.get("after")
    started = time.monotonic()
    conn.execute("select pg_advisory_xact_lock(hashtext('debits:' || %s))", (org,))
    rows = conn.execute(
        "select * from private.debit_candidates(%s, %s, %s, %s)",
        (org, after[0] if after else None, after[1] if after else None, CHUNK),
    ).fetchall()
    lines, payments, refunds = _group(rows)
    if len(lines) >= CHUNK:
        last = lines[-1]
        conn.execute(
            "select pgmq.send('payments', %s)",
            (
                Jsonb(
                    {
                        "type": "process_debits",
                        "organization_id": org,
                        "after": [last.booking_date.isoformat(), last.id],
                    }
                ),
            ),
        )
    if not lines:
        return {"lines": 0}
    decisions = decide_all(lines, payments, refunds)
    summary = apply(conn, org, decisions)
    retry = int(payload.get("retry", 0))
    if int(summary.get("skipped", 0)) and retry < RETRIES:
        conn.execute(
            "select pgmq.send('payments', %s, %s)",
            (
                Jsonb({"type": "process_debits", "organization_id": org, "retry": retry + 1}),
                RETRY_DELAY_S,
            ),
        )
    log.info(
        "process_debits %s: %d lines, %d linked, %d to ops, %s skipped, %s refused by the posting,"
        " %.1fs",
        org,
        len(lines),
        sum(1 for d in decisions if d.linked),
        sum(1 for d in decisions if not d.linked),
        summary.get("skipped", 0),
        summary.get("failed", 0),
        time.monotonic() - started,
    )
    return summary


def _group(
    rows: list[tuple[Any, ...]],
) -> tuple[list[DebitLine], dict[str, list[PaymentCandidate]], dict[str, list[RefundCandidate]]]:
    lines: dict[str, DebitLine] = {}
    payments: dict[str, list[PaymentCandidate]] = defaultdict(list)
    refunds: dict[str, list[RefundCandidate]] = defaultdict(list)
    for (
        line_id,
        kind,
        direction,
        bank,
        amount,
        booking,
        payment_id,
        refund_id,
        via,
        cand_bank,
        cand_amount,
        cand_left,
        cand_unallocated,
        cand_pending,
        cand_status,
        cand_date,
        cand_payment_status,
        cand_free_from,
    ) in rows:
        key = str(line_id)
        lines.setdefault(key, DebitLine(key, kind, direction, str(bank), int(amount), booking))
        if refund_id is not None:
            refunds[key].append(
                RefundCandidate(
                    str(refund_id),
                    str(payment_id),
                    str(cand_bank),
                    int(cand_amount),
                    str(cand_status),
                    int(cand_unallocated or 0),
                    cand_date,
                    str(cand_payment_status),
                    cand_free_from,
                )
            )
        elif payment_id is not None:
            payments[key].append(
                PaymentCandidate(
                    str(payment_id),
                    str(cand_bank),
                    int(cand_amount),
                    int(cand_left or 0),
                    int(cand_pending or 0),
                    str(cand_status),
                    cand_date,
                    str(via),
                    cand_free_from,
                )
            )
    ordered = sorted(lines.values(), key=lambda x: (x.booking_date, x.id))
    return ordered, payments, refunds


def apply(conn: Conn, org: str, decisions: list[Decision]) -> dict[str, Any]:
    conn.execute("select private.debit_link_begin()")
    with (
        conn.cursor() as cur,
        cur.copy(
            """copy pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id,
                 refund_request_id, method) from stdin"""
        ) as copy,
    ):
        for n, d in enumerate((d for d in decisions if d.linked), start=1):
            copy.write_row((n, d.line_id, d.kind, d.payment_id, d.refund_request_id, "auto"))
    with (
        conn.cursor() as cur,
        cur.copy(
            "copy pg_temp._debit_review (bank_transaction_id, reason, candidates) from stdin"
        ) as copy,
    ):
        for d in decisions:
            if not d.linked:
                copy.write_row((d.line_id, d.review_reason, Jsonb(list(d.candidates))))
    row = conn.execute("select private.apply_debit_decisions(%s)", (org,)).fetchone()
    return dict(row[0]) if row else {}


# -- direct payments ----------------------------------------------------------------------------


def run_direct_payment(conn: Conn, payload: dict[str, Any]) -> str:
    """Plan a payment made to the client directly and book it, or refuse it with a code."""
    org = str(payload["organization_id"])
    ident = str(payload["direct_payment_id"])
    conn.execute("select pg_advisory_xact_lock(hashtext('payments:' || %s))", (org,))
    row = conn.execute(
        """select status, account_id::text, amount_minor, paid_on, item_ids::text[]
           from public.direct_payment where id = %s and organization_id = %s for update""",
        (ident, org),
    ).fetchone()
    if row is None or row[0] != "requested":
        return "skipped"
    _status, account, amount, paid_on, items = row
    files = load_files(conn, org, [account])
    f = files.get(account)
    if f is None or f.status in CLOSED or f.status == "staged":
        return _refuse(conn, ident, "file_closed")
    if f.servicing_start is None or paid_on < f.servicing_start:
        return _refuse(conn, ident, "before_servicing_start")
    policy = resolve_policy(load_policies(conn, org), f, paid_on)
    designation = tuple(str(i) for i in (items or ()))
    result, slots = f.balances.plan(int(amount), policy, designation, at=paid_on)
    if not result.lines:
        return _refuse(conn, ident, "nothing_due")
    if result.remainder_minor > 0:
        return _refuse(conn, ident, "more_than_due")
    digest = inputs_hash(
        payment_id=ident,
        account_id=account,
        amount_minor=int(amount),
        effective_date=paid_on,
        policy=policy,
        designation=designation,
        slots=slots,
    )
    lines = [
        {"claim_item_id": x.item_id, "component": x.component, "amount_minor": str(x.amount_minor)}
        for x in result.lines
    ]
    return _post(conn, ident, lines, digest)


def _post(conn: Conn, ident: str, lines: list[dict[str, str]], digest: str) -> str:
    from collectoo_worker.jobs.payments import deterministic  # noqa: PLC0415 - it imports this module

    try:
        with conn.transaction():  # savepoint: a plan the ledger refuses leaves nothing behind
            conn.execute(
                "select private.post_direct_payment(%s, %s, %s, %s)",
                (ident, Jsonb(lines), ENGINE_VERSION, digest),
            )
    except psycopg.Error as exc:
        if not deterministic(exc):
            raise  # the machine, a lock: retried by the queue (then `failed` when dead-lettered)
        # the ledger refuses this plan (an owner gap on the date, a receivable check): it would
        # fail the same way on every retry; ops see it refused and record it again once fixed
        log.warning("direct payment %s: refused by the ledger: %s", ident, exc)
        return _refuse(conn, ident, "failed")
    return "posted"


def _refuse(conn: Conn, ident: str, code: str) -> str:
    conn.execute("select private.refuse_direct_payment(%s, %s)", (ident, code))
    return code


# -- nightly checks -----------------------------------------------------------------------------


def run_invariants(conn: Conn, payload: dict[str, Any]) -> dict[str, Any]:
    org = str(payload["organization_id"])
    started = time.monotonic()
    row = conn.execute("select private.run_payment_checks(%s)", (org,)).fetchone()
    summary = dict(row[0]) if row else {}
    log.info(
        "invariants %s: %s violations, %s alerts, %.1fs",
        org,
        summary.get("violations"),
        summary.get("alerts"),
        time.monotonic() - started,
    )
    return summary
