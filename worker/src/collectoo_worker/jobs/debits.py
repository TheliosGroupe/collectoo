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

4. M2c-1 (design m2c-remittances §12): the lines booked in the funds — the bank's charges
   (`bank_fee`) and the credits carrying the TOP id of a top-up we ordered (`servicer_top_up`);
   M2c-6b-1 (plan docs/design/m2c-6b-plan.md §2.2-§2.5): our payouts' and sweeps' debits (by their
   own id, or a batch line of their PmtInf: one booking per member), their returns (the bank's
   charge on one booked as a fee), each payout's run settlement and, when a payout went beyond what
   the client was owed, its cover (`client_advance`): `private.bank_booking_candidates` (one row
   per line and transfer it names), `payments.debits.decide_bookings`, then
   `private.apply_bank_bookings` (runs → payout accounts → bank accounts → allocation lock → lines →
   remit lock → files → transfers; every row re-checked under them); the rest is left to ops with
   why (a debit of a cancelled transfer, a second debit, a transfer never handed out: P0). **The
   funds pass runs in its own transaction** (plan §2.5 [critic]): the first message runs steps 1-3,
   then queues `{"funds_after": null}`; a funds message runs step 4 only. Run after the M2b pass in
   one transaction, the funds pass would wait for a run row while holding the allocation lock the
   M2b pass took, and the commands that hold a run row and wait for that lock
   (transfer_file_download, cancel_remittance_run, the cancellations) would deadlock with it. A
   continuation pages the funds' lines (`funds_after`); the chunk counts lines, never splitting a
   batch line; a return whose debit the same chunk books is decided again by a follow-up pass.

`CHUNK` lines per transaction (2,000 by default): the transaction holds the servicer's allocation
lock while it posts. Measured on the 50k scale data (4 vCPU): 2,000 full returns posted in 5.7 s;
with one line the posting refuses, the chunk's try, a try of each line on its own and the post of
the others take 83 s — both far below the queue's 300 s visibility timeout (20,000 lines would
have taken ~1 min, and ~14 min with one refused line). The rest follows in a continuation message.

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
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from collectoo_worker.jobs.allocation import CLOSED, load_files, load_policies, resolve_policy
from collectoo_worker.payments.allocation import ENGINE_VERSION, inputs_hash
from collectoo_worker.payments.debits import (
    Booking,
    DebitLine,
    Decision,
    FundsLine,
    PaymentCandidate,
    RefundCandidate,
    TransferFact,
    decide_all,
    decide_bookings,
    deferred_returns,
)

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.payments")
CHUNK = int(os.environ.get("DEBIT_CHUNK", "2000"))
RETRY_DELAY_S = 5
RETRIES = 5  # runs re-queued for lines skipped on re-check; then they wait for ops (`changed`)


def run_process_debits(conn: Conn, payload: dict[str, Any]) -> dict[str, Any]:
    org = str(payload["organization_id"])
    conn.execute("select pg_advisory_xact_lock(hashtext('debits:' || %s))", (org,))
    if "funds_after" in payload:  # the funds pass, in its own transaction (and its pages)
        return {"funds": _process_funds_lines(conn, org, payload.get("funds_after"))}
    summary = _process_debit_lines(conn, org, payload)
    if "after" not in payload:  # the first run of a chain (or a retry): the funds pass follows
        _queue_funds(conn, org, None)
    return summary


def _queue_funds(conn: Conn, org: str, after: list[str] | None, delay_s: int = 0) -> None:
    conn.execute(
        "select pgmq.send('payments', %s, %s)",
        (Jsonb({"type": "process_debits", "organization_id": org, "funds_after": after}), delay_s),
    )


def _process_debit_lines(conn: Conn, org: str, payload: dict[str, Any]) -> dict[str, Any]:
    """Steps 1-3: returns, our refunds, refunds that came back (M2b-6)."""
    after = payload.get("after")
    started = time.monotonic()
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


def _fact(row: dict[str, Any]) -> TransferFact | None:
    if row["transfer_id"] is None or row["role"] is None:
        return None
    return TransferFact(
        id=str(row["transfer_id"]),
        role=str(row["role"]),
        kind=str(row["transfer_kind"]),
        status=str(row["transfer_status"]),
        amount_minor=int(row["transfer_amount_minor"]),
        currency=str(row["transfer_currency"]),
        debtor_bank_account_id=_str(row["transfer_debtor_bank_account_id"]),
        creditor_bank_account_id=_str(row["transfer_creditor_bank_account_id"]),
        file_id=_str(row["transfer_file_id"]),
        file_status=row["file_status"],
        file_download_count=int(row["file_download_count"] or 0),
        pmt_inf_id=row["pmt_inf_id"],
        batch_file_id=_str(row["batch_file_id"]),
        batch_file_status=row["batch_file_status"],
        batch_file_download_count=int(row["batch_file_download_count"] or 0),
        run_status=row["run_status"],
        run_transfer_id=_str(row["run_transfer_id"]),
        replaces_transfer_id=_str(row["replaces_transfer_id"]),
        debit_booked=bool(row["debit_booked"]),
        return_booked=bool(row["return_booked"]),
        return_seen=bool(row["return_seen"]),
        debit_date=row.get("debit_date"),
    )


def _str(value: Any) -> str | None:
    return None if value is None else str(value)


def funds_lines(rows: list[dict[str, Any]]) -> list[FundsLine]:
    """private.bank_booking_candidates' rows (one per line and transfer it names) as lines."""
    lines: dict[str, FundsLine] = {}
    facts: dict[str, list[TransferFact]] = defaultdict(list)
    for r in rows:
        key = str(r["line_id"])
        if key not in lines:
            top_up = r["role"] == "top_up" and r["transfer_id"] is not None
            lines[key] = FundsLine(
                id=key,
                kind=str(r["line_kind"]),
                direction=str(r["direction"]),
                bank_account_id=str(r["bank_account_id"]),
                amount_minor=int(r["amount_minor"]),
                booking_date=r["booking_date"],
                bank_tx_code=r["bank_tx_code"],
                transfer_id=str(r["transfer_id"]) if top_up else None,
                transfer_status=r["transfer_status"] if top_up else None,
                transfer_amount_minor=int(r["transfer_amount_minor"]) if top_up else None,
                transfer_creditor=_str(r["transfer_creditor_bank_account_id"]) if top_up else None,
                currency=str(r["currency"]),
                end_to_end_id=r["end_to_end_id"],
                original_end_to_end_id=r["original_end_to_end_id"],
                payment_info_id=r["payment_info_id"],
                unsplit_ours=r["unsplit_ours"],
                names_our_lot=bool(r["names_our_lot"]),
            )
        f = _fact(r)
        if f is not None:
            facts[key].append(f)
    out = [FundsLine(**{**_fields(x), "facts": tuple(facts.get(x.id, ()))}) for x in lines.values()]
    return sorted(out, key=lambda x: (x.booking_date, x.id))


def _fields(line: FundsLine) -> dict[str, Any]:
    return {k: getattr(line, k) for k in FundsLine.__dataclass_fields__}


def _process_funds_lines(conn: Conn, org: str, after: list[str] | None) -> dict[str, Any]:
    """Step 4: our transfers' debits and returns, the bank's charges and our top-ups booked in the
    funds; the rest to ops."""
    started = time.monotonic()
    with conn.cursor(row_factory=dict_row) as cur:
        rows = cur.execute(
            "select * from private.bank_booking_candidates(%s, %s, %s, %s)",
            (org, after[0] if after else None, after[1] if after else None, CHUNK),
        ).fetchall()
    debit_dates(conn, rows)
    lines = funds_lines(rows)
    if len(lines) >= CHUNK:
        last = lines[-1]
        _queue_funds(conn, org, [last.booking_date.isoformat(), last.id])
    bookings = decide_bookings(lines)
    later = deferred_returns(lines, bookings)
    if later:  # a return whose debit this pass books: read again once it is
        _queue_funds(conn, org, None, RETRY_DELAY_S)
    if not bookings:
        return {"lines": len(lines), "deferred": len(later)}
    summary = apply_bookings(conn, org, bookings)
    log.info(
        "process_debits %s (funds): %d lines, %d bookings, %d to ops, %d deferred, %s refused,"
        " %.1fs",
        org,
        len(lines),
        sum(1 for b in bookings if b.booked),
        sum(1 for b in bookings if not b.booked),
        len(later),
        summary.get("failed", 0),
        time.monotonic() - started,
    )
    return summary


def debit_dates(conn: Conn, rows: list[dict[str, Any]]) -> None:
    """Each returned transfer's debit date (`debit_date` on its rows): the date of the entry its
    debit booked — what private.post_bank_bookings compares a return's date with (review T4, K5:
    a return dated before its debit is `return_before_debit`). Keyed by the transfer, then its
    entry."""
    ids = sorted(
        {str(r["transfer_id"]) for r in rows if r["role"] == "return" and r["debit_booked"]}
    )
    if not ids:
        return
    dates = dict(
        conn.execute(
            """select t.id::text, e.effective_date
               from unnest(%s::uuid[]) u (id)
               cross join lateral (select q.id, q.entry_id from public.bank_transfer q
                                   where q.id = u.id offset 0) t
               cross join lateral (select le.effective_date from public.ledger_entry le
                                   where le.id = t.entry_id offset 0) e""",
            (ids,),
        ).fetchall()
    )
    for r in rows:
        if r["role"] == "return" and r["transfer_id"] is not None:
            r["debit_date"] = dates.get(str(r["transfer_id"]))


def apply_bookings(conn: Conn, org: str, bookings: list[Booking]) -> dict[str, Any]:
    conn.execute("select private.bank_booking_begin()")
    with (
        conn.cursor() as cur,
        cur.copy(
            """copy pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method)
               from stdin"""
        ) as copy,
    ):
        for n, b in enumerate((b for b in bookings if b.booked), start=1):
            copy.write_row((n, b.line_id, b.kind, b.transfer_id, "auto"))
    with (
        conn.cursor() as cur,
        cur.copy(
            "copy pg_temp._booking_review (bank_transaction_id, reason, candidates) from stdin"
        ) as copy,
    ):
        for b in bookings:
            if not b.booked:
                copy.write_row((b.line_id, b.review_reason, Jsonb(list(b.candidates))))
    row = conn.execute("select private.apply_bank_bookings(%s)", (org,)).fetchone()
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
