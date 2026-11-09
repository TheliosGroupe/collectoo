"""Job `payments.allocate` (M2-09, design §8.5 and §9): allocate the payments ready for it.

Queued whenever a payment becomes ready (matched to a file with nothing left to decide): the
payment trigger of migration 20261109190000 sends one message per servicer after a match, a hold
lifted or an ops decision. One transaction (the queue's, exactly once):

1. take the servicer's allocation lock (design §5.2): no allocation, reversal, forward, netting or
   correction of a receivable of this servicer runs meanwhile;
2. read the ready payments in processing order (booking date, statement, line), at most `CHUNK`;
   lock their files FOR KEY SHARE (as the match gating: a hold placed meanwhile waits for this run,
   or this run sees it), then the payments FOR UPDATE SKIP LOCKED (a payment an ops command holds is
   left to that command; the run is queued again a little later). When the chunk is full the job
   queues its continuation (`after`: where it ended) in the same transaction;
3. load the files: status, currency, regime, servicing start, blocking holds, allocation policies,
   each receivable's postings summed per date, and the credit-note proposals of files with a credit;
4. gate each payment (`gate`: closed file, other currency, hold, before the servicing start, credit
   note to apply; every gate ops released is passed), then plan it with the pure waterfall
   (`payments.allocation`), in order, on in-memory balances: a later payment of the same file sees
   what an earlier one took, as the ledger will;
5. COPY the plans and call `private.post_allocations`, which re-checks them and posts set-based (one
   `allocation` entry per payment and file, the client notification, the payment's state).

No model, no LLM: amounts come from the ledger and the waterfall only (CLAUDE.md).
"""

from __future__ import annotations

import logging
import os
import time
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from datetime import date
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.payments.allocation import (
    ENGINE_VERSION,
    Allocation,
    Component,
    Family,
    FileBalances,
    Policy,
    inputs_hash,
)

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.payments")
# Payments per run (one transaction). The design (§8.5) posts in chunks of 10k: the allocation lock
# is held for one chunk at a time, so ops commands wait seconds, not minutes.
CHUNK = int(os.environ.get("ALLOCATION_CHUNK", "10000"))
RETRY_DELAY_S = 5  # a payment an ops command held: the run is queued again this much later
CLOSED = frozenset({"closed_paid", "closed_settled", "closed_uncollectable", "closed_recalled"})
STATEMENT = "coalesce(t.statement_id, '00000000-0000-0000-0000-000000000000'::uuid)"
LINE = "coalesce(t.line_no, 0)"
ORDER_COLUMNS = f"p.booking_date, {STATEMENT}, {LINE}, p.id"
ORDER_KEY = f"({ORDER_COLUMNS})"
READY = (
    "p.status in ('matched', 'partially_allocated') and p.review_reason is null"
    " and p.account_id is not null"
)

Cursor = tuple[date, str, int, str]  # (booking date, statement, line, payment): processing order


@dataclass(frozen=True, slots=True)
class Target:
    """A ready payment and the file it is allocated to."""

    id: str
    amount_minor: int  # what is left of it (U)
    currency: str
    booking_date: date
    account_id: str  # the payment's file, or the other file ops named for an overpayment (#8)
    own_file: bool
    designation: tuple[str, ...]
    # the gates ops let it pass (payment.allocation_instruction.releases): a set, each decision
    # added to it, so a payment behind two gates passes both (review fix)
    releases: frozenset[str] = frozenset()
    # M2b-6: the latest date at which one of its allocations was reversed after its own date (a
    # bank return reverses at the return date, design §2 #3): what is left is free from then on
    not_before: date | None = None


@dataclass
class FileFacts:
    id: str
    status: str
    currency: str
    legal_regime: str
    client_id: str
    portfolio_id: str
    servicing_start: date | None
    holds: int
    credit_note: bool = False
    balances: FileBalances = field(default_factory=FileBalances)


@dataclass(frozen=True, slots=True)
class PolicyRow:
    id: str
    client_id: str | None
    portfolio_id: str | None
    version: int
    effective_from: date
    accessory_rank: str
    unclassified: str


@dataclass(frozen=True, slots=True)
class Plan:
    target: Target
    outcome: str  # allocate | a gate | nothing_due | credit_note_to_apply
    effective_date: date | None = None
    policy: Policy | None = None
    allocation: Allocation | None = None
    hash: str | None = None


# -- pure decisions ------------------------------------------------------------------------------


def gate(t: Target, f: FileFacts) -> str | None:
    """What keeps a payment from allocation on this file now (design §8.4, first that applies),
    unless ops let it pass that gate (the judge's authorisation, the cut-off checked with the
    client, a credit note not invoked); every gate ops released is passed. The hold comes before
    the cut-off: a payment booked before the servicing start on a held file is reported held, and
    the client told (founder #12, #17). Mirrors private.gate_assignments and the backstop in
    private.post_allocations."""
    if f.status in CLOSED:
        return "account_closed"
    if t.currency != f.currency:
        return "currency_mismatch"  # 1343-3: never converted (founder #9)
    if f.holds and "hold_blocks_allocation" not in t.releases:
        return "hold_blocks_allocation"  # L722-5, L622-7 (founder #12)
    if f.servicing_start is None or (
        t.booking_date < f.servicing_start and "before_servicing_start" not in t.releases
    ):
        return "before_servicing_start"  # founder #10
    if f.credit_note and "credit_note_to_apply" not in t.releases:
        return "credit_note_to_apply"  # 1347: ops invoke compensation first (founder #7)
    return None


def resolve_policy(rows: Sequence[PolicyRow], f: FileFacts, at: date) -> Policy:
    """The most specific scope with a version in force at `at` (portfolio, client, servicer); in a
    scope, the version that took effect last (then the higher version). None: the built-in default.
    Consumer regimes then force `held` (founder #6)."""
    for client, portfolio in ((f.client_id, f.portfolio_id), (f.client_id, None), (None, None)):
        found = [
            r
            for r in rows
            if r.client_id == client and r.portfolio_id == portfolio and r.effective_from <= at
        ]
        if found:
            r = max(found, key=lambda r: (r.effective_from, r.version))
            policy = Policy(r.accessory_rank, r.unclassified, r.id, r.version)
            return policy.for_regime(f.legal_regime)
    return Policy().for_regime(f.legal_regime)


def plan_all(
    targets: Sequence[Target], files: dict[str, FileFacts], policies: Sequence[PolicyRow]
) -> list[Plan]:
    """Each payment in processing order: gated, or allocated on its file's balances at its date."""
    plans = []
    for t in targets:
        f = files[t.account_id]
        reason = gate(t, f)
        if reason is not None:
            plans.append(Plan(t, reason))
            continue
        start = f.servicing_start or t.booking_date  # never None here: the gate checked it
        at = max(t.booking_date, start, t.not_before or t.booking_date)
        policy = resolve_policy(policies, f, at)
        designation = t.designation if t.own_file else ()
        result, slots = f.balances.plan(t.amount_minor, policy, designation, at=at)
        if not result.lines:
            plans.append(Plan(t, "nothing_due"))
            continue
        digest = inputs_hash(
            payment_id=t.id,
            account_id=t.account_id,
            amount_minor=t.amount_minor,
            effective_date=at,
            policy=policy,
            designation=designation,
            slots=slots,
        )
        plans.append(Plan(t, "allocate", at, policy, result, digest))
    return plans


# -- the job -------------------------------------------------------------------------------------


def run_allocate(conn: Conn, payload: dict[str, Any]) -> dict[str, Any]:
    org = str(payload["organization_id"])
    after = _cursor(payload.get("after"))
    started = time.monotonic()
    conn.execute("select pg_advisory_xact_lock(hashtext('payments:' || %s))", (org,))
    targets, last, skipped = load_targets(conn, org, after=after, limit=CHUNK)
    if last is not None:
        # The chunk is full: the rest follows in the next job (same transaction: exactly once).
        follow = {
            "type": "allocate",
            "organization_id": org,
            "trigger": "continuation",
            "after": [last[0].isoformat(), last[1], last[2], last[3]],
        }
        conn.execute("select pgmq.send('payments', %s)", (Jsonb(follow),))
    if skipped:
        # Payments an ops command held: they are ready again (or not) once it commits; look again.
        conn.execute(
            "select pgmq.send('payments', %s, %s)",
            (Jsonb({"type": "allocate", "organization_id": org}), RETRY_DELAY_S),
        )
    if not targets:
        return {"payments": 0}
    files = load_files(conn, org, {t.account_id for t in targets})
    policies = load_policies(conn, org)
    loaded = time.monotonic()
    plans = plan_all(targets, files, policies)
    planned = time.monotonic()
    summary = post(conn, org, plans, "continuation" if after is not None else "ready")
    log.info(
        "allocate %s: %d payments%s, %d allocated; load %.1fs, plan %.1fs, post %.1fs",
        org,
        len(targets),
        " (chunk full: the rest is queued)" if last is not None else "",
        sum(1 for p in plans if p.outcome == "allocate"),
        loaded - started,
        planned - loaded,
        time.monotonic() - planned,
    )
    return summary


def _cursor(value: Any) -> Cursor | None:
    if not value:
        return None
    day, statement, line, payment = value
    return date.fromisoformat(str(day)), str(statement), int(line), str(payment)


def load_targets(
    conn: Conn, org: str, *, after: Cursor | None = None, limit: int = CHUNK
) -> tuple[list[Target], Cursor | None, int]:
    """The ready payments, in processing order, at most `limit` after `after`; their files locked
    FOR KEY SHARE first, then the payments FOR UPDATE SKIP LOCKED. Returns them, where a full chunk
    ends, and how many were skipped (held by an ops command, or changed meanwhile)."""
    where = READY
    params: list[Any] = [org]
    if after is not None:
        where += f" and {ORDER_KEY} > (%s::date, %s::uuid, %s::integer, %s::uuid)"
        params += [*after]
    rows = conn.execute(
        f"""select p.id::text, p.booking_date, {STATEMENT}::text, {LINE},
                   coalesce(p.allocation_instruction ->> 'account_id', p.account_id::text)
            from public.payment p
            left join public.bank_transaction t on t.id = p.bank_transaction_id
            where p.organization_id = %s and {where}
            order by {ORDER_COLUMNS}
            limit %s""",  # noqa: S608 - fixed fragments, values bound
        (*params, limit),
    ).fetchall()
    if not rows:
        return [], None, 0
    end = rows[-1]
    last = (end[1], str(end[2]), int(end[3]), str(end[0])) if len(rows) >= limit else None
    files = sorted({str(r[4]) for r in rows})
    conn.execute(
        "select 1 from public.account a where a.id = any(%s::uuid[]) order by a.id for key share",
        (files,),
    )
    locked = conn.execute(
        f"""select p.id::text, p.currency, p.booking_date, p.account_id::text,
                   coalesce(p.allocation_instruction ->> 'account_id', p.account_id::text),
                   p.designation, p.allocation_instruction -> 'releases',
                   (select max(e.effective_date) from public.ledger_entry e
                    join public.ledger_entry r on r.id = e.reverses_entry_id
                    where e.payment_id = p.id and e.effective_date > r.effective_date)
            from public.payment p
            where p.id = any(%s::uuid[]) and {READY}
            for update of p skip locked""",  # noqa: S608 - fixed fragment
        ([r[0] for r in rows],),
    ).fetchall()
    by_id = {r[0]: r for r in locked if r[4] in files}
    left = dict(
        conn.execute(
            "select payment_id::text, unallocated_minor from private.payment_positions(%s::uuid[])",
            (list(by_id),),
        ).fetchall()
    )
    targets = []
    for r in rows:
        x = by_id.get(r[0])
        if x is None or int(left.get(r[0], 0)) <= 0:
            continue
        items = (x[5] or {}).get("item_ids") or []
        targets.append(
            Target(
                id=x[0],
                amount_minor=int(left[r[0]]),
                currency=str(x[1]).strip(),
                booking_date=x[2],
                account_id=str(x[4]),
                own_file=x[4] == x[3],
                designation=tuple(str(i) for i in items),
                releases=frozenset(str(r) for r in (x[6] or ())),
                not_before=x[7],
            )
        )
    return targets, last, len(rows) - len(by_id)


def _temp_keys(conn: Conn, table: str, values: Iterable[str]) -> None:
    """A working table of our own with the ids, analysed (the joins then plan on facts)."""
    conn.execute(f"drop table if exists pg_temp.{table}")
    conn.execute(f"create temp table {table} (id uuid primary key) on commit drop")
    with conn.cursor() as cur, cur.copy(f"copy pg_temp.{table} (id) from stdin") as copy:
        for v in values:
            copy.write_row((v,))
    conn.execute(f"analyze pg_temp.{table}")


def load_files(conn: Conn, org: str, ids: Iterable[str]) -> dict[str, FileFacts]:
    _temp_keys(conn, "_alloc_file", sorted(set(ids)))
    files: dict[str, FileFacts] = {}
    for r in conn.execute(
        """select a.id::text, a.status, a.currency, a.legal_regime, a.client_organization_id::text,
                  a.portfolio_id::text,
                  (select min(o.valid_from) from public.claim_ownership_period o
                   where o.account_id = a.id),
                  (select count(*) from public.account_hold h
                   where h.account_id = a.id and h.ended_at is null
                     and h.kind in ('surendettement', 'collective_proceeding'))
           from pg_temp._alloc_file f join public.account a on a.id = f.id
           where a.organization_id = %s""",
        (org,),
    ).fetchall():
        files[r[0]] = FileFacts(r[0], r[1], str(r[2]).strip(), r[3], r[4], r[5], r[6], int(r[7]))
    points: dict[tuple[str, str, str], dict[date, int]] = {}
    meta: dict[tuple[str, str, str], Component] = {}
    for account, item, comp, family, order, due, issue, day, amount in conn.execute(
        """select la.account_id::text, la.claim_item_id::text, la.component, c.family, c.sort_order,
                  i.due_date, i.issue_date, q.effective_date, sum(q.amount_minor)
           from pg_temp._alloc_file f
           join public.ledger_account la on la.account_id = f.id and la.book = 'debtor_receivable'
           join public.claim_item i on i.id = la.claim_item_id
           join public.ledger_component c on c.code = la.component
           join public.ledger_posting q on q.ledger_account_id = la.id
           group by la.account_id, la.claim_item_id, la.component, c.family, c.sort_order,
                    i.due_date, i.issue_date, q.effective_date"""
    ).fetchall():
        key = (account, item, comp)
        meta[key] = Component(item, comp, Family(family), int(order), due, issue)
        points.setdefault(key, {})[day] = int(amount)
    credits = set()
    for key, c in meta.items():
        account = key[0]
        if account in files:
            files[account].balances.add(c, points[key])
            if c.family is Family.PRINCIPAL and sum(points[key].values()) < 0:
                credits.add(account)
    if credits:
        rows = conn.execute(
            "select distinct account_id::text from private.credit_note_proposals(%s::uuid[])",
            (sorted(credits),),
        ).fetchall()
        for (account,) in rows:
            files[account].credit_note = True
    return files


def load_policies(conn: Conn, org: str) -> list[PolicyRow]:
    return [
        PolicyRow(r[0], r[1], r[2], int(r[3]), r[4], r[5], r[6])
        for r in conn.execute(
            """select id::text, client_organization_id::text, portfolio_id::text, version,
                      effective_from, accessory_rank, unclassified
               from public.allocation_policy where organization_id = %s""",
            (org,),
        ).fetchall()
    ]


def post(conn: Conn, org: str, plans: Sequence[Plan], trigger: str) -> dict[str, Any]:
    conn.execute("select private.allocation_begin()")
    with (
        conn.cursor() as cur,
        cur.copy(
            """copy pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date,
                 policy, designation, inputs_hash) from stdin"""
        ) as copy,
    ):
        for n, p in enumerate(plans, start=1):
            t = p.target
            designation = (
                Jsonb({"item_ids": list(t.designation)})
                if p.outcome == "allocate" and t.own_file and t.designation
                else None
            )
            copy.write_row(
                (
                    t.id,
                    n,
                    t.account_id,
                    p.outcome,
                    p.effective_date,
                    Jsonb(p.policy.as_json()) if p.policy else None,
                    designation,
                    p.hash,
                )
            )
    with (
        conn.cursor() as cur,
        cur.copy(
            """copy pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
               from stdin"""
        ) as copy,
    ):
        for p in plans:
            if p.allocation is None:
                continue
            for seq, line in enumerate(p.allocation.lines, start=1):
                copy.write_row((p.target.id, seq, line.item_id, line.component, line.amount_minor))
    row = conn.execute(
        "select private.post_allocations(%s, %s, %s)", (org, trigger, ENGINE_VERSION)
    ).fetchone()
    return dict(row[0]) if row else {}
