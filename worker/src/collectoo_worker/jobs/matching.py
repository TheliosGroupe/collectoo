"""Job `payments.match` (M2-08, design §8.4 and §9): match the payments waiting for a file.

Queued by the import (`trigger: import`, every payment never tried), by a batch confirmation
(`rematch`: the payments left to ops are matched again, founder #11) and by `unassign_payment`
(`ops`: fresh suggestions for that payment). One transaction (the queue's, exactly once):

1. lock the target payments (skip those an ops command holds right now);
2. read their signals (`payments.matching.read_signals`) and load only what they point to: the
   references, invoice and file numbers, IBANs, then those files (items, balances, parties) —
   set-based, through temporary tables analysed before they are joined (no plan rests on the
   statistics of tables just loaded);
3. run rules R1-R4; for the payments left, load files whose balance equals the amount and files
   whose party names are close (trigram index), then R5-R6;
4. COPY the decisions and call `private.apply_match_results`, which gates and records them.

Nothing is posted: allocation is M2b-4. The rules decide; no model, no LLM (CLAUDE.md).
"""

from __future__ import annotations

import logging
import time
from collections.abc import Iterable, Sequence
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.payments.matching import (
    MAX_PER_AMOUNT,
    RULE_VERSION,
    AccountInfo,
    Decision,
    Directory,
    ItemInfo,
    PaymentIn,
    Signals,
    match_all,
    read_signals,
)

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.payments")
TRIGGERS = ("import", "rematch", "ops")
QUEUED = ("no_match", "ambiguous", "account_not_confirmed")
NAME_SEARCH_THRESHOLD = 0.5  # pg_trgm: what the name search returns (the rules then score it)
NAME_SEARCH_MAX = 20_000  # payments searched by name in one run (the rest keep their other hints)


def run_match(conn: Conn, payload: dict[str, Any]) -> dict[str, Any]:
    org = str(payload["organization_id"])
    trigger = str(payload.get("trigger") or "import")
    if trigger not in TRIGGERS:
        raise ValueError(f"unknown match trigger: {trigger!r}")
    ids = [str(x) for x in payload.get("payment_ids") or []]
    started = time.monotonic()
    # One match run per servicer at a time: two runs never decide the same payment twice.
    conn.execute("select pg_advisory_xact_lock(hashtext('payments_match:' || %s))", (org,))
    payments = load_targets(conn, org, trigger, ids)
    if not payments:
        return {"decided": 0}
    signals = [read_signals(p) for p in payments]
    directory = load_directory(conn, org, signals)
    loaded = time.monotonic()
    remainder_s = 0.0

    def remainder(rest: Sequence[tuple[PaymentIn, Signals]]) -> None:
        nonlocal remainder_s
        t = time.monotonic()
        load_remainder(conn, org, rest, directory)
        remainder_s = time.monotonic() - t

    decisions = match_all(payments, directory, remainder, signals)
    decided = time.monotonic()
    result = apply(conn, org, trigger, payments, decisions)
    log.info(
        "match %s (%s): %d payments, %d automatic; load %.1fs, rules %.1fs (remainder load %.1fs),"
        " apply %.1fs",
        org,
        trigger,
        len(payments),
        sum(1 for d in decisions if d.automatic),
        loaded - started,
        decided - loaded - remainder_s,
        remainder_s,
        time.monotonic() - decided,
    )
    return dict(result)


# -- targets ------------------------------------------------------------------------------------


def load_targets(conn: Conn, org: str, trigger: str, ids: list[str]) -> list[PaymentIn]:
    """Payments waiting for a file, in processing order (booking date, statement line). Locked;
    a payment an ops command holds is skipped (that command decides it)."""
    if trigger == "ops":
        where, params = "p.id = any(%s::uuid[])", [ids]
    elif trigger == "rematch":
        where, params = "(p.review_reason is null or p.review_reason = any(%s))", [list(QUEUED)]
    else:
        where, params = "p.review_reason is null", []
    locked = conn.execute(
        f"""select p.id from public.payment p
            where p.organization_id = %s and p.status = 'unmatched' and p.account_id is null
              and {where}
            order by p.id
            for update skip locked""",  # noqa: S608 - fixed fragments, values bound
        (org, *params),
    ).fetchall()
    if not locked:
        return []
    rows = conn.execute(
        """select p.id::text, p.amount_minor, p.currency, p.booking_date, p.payer_name,
                  p.payer_iban, p.remittance_text, p.creditor_reference,
                  t.ultimate_counterparty_name,
                  coalesce(h.by_ops, false), coalesce(h.left_files, '{}')
           from public.payment p
           left join public.bank_transaction t on t.id = p.bank_transaction_id
           left join (select m.payment_id, bool_or(m.decided_by is not null) as by_ops,
                             array_agg(m.account_id::text) filter (where m.action = 'unassign')
                               as left_files
                      from public.payment_match m where m.payment_id = any(%s::uuid[])
                      group by m.payment_id) h on h.payment_id = p.id
           where p.id = any(%s::uuid[])
           order by p.booking_date, t.statement_id, t.line_no, p.id""",
        ([r[0] for r in locked], [r[0] for r in locked]),
    ).fetchall()
    return [
        PaymentIn(
            id=r[0],
            amount_minor=int(r[1]),
            currency=str(r[2]).strip(),
            booking_date=r[3],
            payer_name=r[4],
            payer_iban=r[5],
            remittance_text=r[6],
            creditor_reference=r[7],
            other_names=(r[8],) if r[8] and r[8] != r[4] else (),
            suggest_only=bool(r[9]),
            excluded=frozenset(r[10] or ()),
        )
        for r in rows
    ]


# -- directory -----------------------------------------------------------------------------------


def _temp_keys(conn: Conn, table: str, column: str, kind: str, values: Iterable[str]) -> None:
    """A working table of our own with the values, analysed (the joins then plan on facts)."""
    conn.execute(f"drop table if exists pg_temp.{table}")
    conn.execute(f"create temp table {table} ({column} {kind} primary key) on commit drop")
    with conn.cursor() as cur, cur.copy(f"copy pg_temp.{table} ({column}) from stdin") as copy:
        for v in values:
            copy.write_row((v,))
    conn.execute(f"analyze pg_temp.{table}")


def load_directory(conn: Conn, org: str, signals: Sequence[Signals]) -> Directory:
    d = Directory()
    refs = set().union(*(s.wanted_references() for s in signals))
    if refs:
        rows = conn.execute(
            """select r.rf, r.account_id::text from public.payment_reference r
               where r.organization_id = %s and r.rf = any(%s)""",
            (org, sorted(refs)),
        ).fetchall()
        d.references = {r[0]: r[1] for r in rows}
    tokens = {t for s in signals for t in s.tokens}
    if tokens:
        _temp_keys(conn, "_match_token", "key", "text", tokens)
        rows = conn.execute(
            """select k.key, i.account_id::text
               from pg_temp._match_token k
               join public.claim_item i on private.ref_key(i.ref) = k.key
               join public.account a on a.id = i.account_id and a.organization_id = %s
               union
               select k.key, a.id::text
               from pg_temp._match_token k
               join public.account a
                 on a.organization_id = %s and private.ref_key(a.external_ref) = k.key""",
            (org, org),
        ).fetchall()
        hits: dict[str, set[str]] = {}
        for key, account in rows:
            hits.setdefault(key, set()).add(account)
        d.tokens = {k: frozenset(v) for k, v in hits.items()}
    ibans = {s.iban for s in signals if s.iban}
    if ibans:
        rows = conn.execute(
            """select l.payer_iban, l.account_id::text, l.confirmed_count
               from private.payer_account_link l
               where l.organization_id = %s and l.payer_iban = any(%s)""",
            (org, sorted(ibans)),
        ).fetchall()
        for iban, account, n in rows:
            d.iban_links.setdefault(iban, {})[account] = int(n)
    wanted = set(d.references.values()) | {a for v in d.tokens.values() for a in v}
    wanted |= {a for v in d.iban_links.values() for a in v}
    load_accounts(conn, d, wanted)
    return d


def load_accounts(conn: Conn, d: Directory, ids: Iterable[str]) -> None:
    """Files as the rules see them: status, currency, parties, items with their open balances,
    open balance, and payments already matched to them and not allocated."""
    todo = sorted(set(ids) - set(d.accounts))
    if not todo:
        return
    _temp_keys(conn, "_match_file", "id", "uuid", todo)
    files = {
        r[0]: r
        for r in conn.execute(
            """select a.id::text, a.external_ref, a.status, a.currency
               from pg_temp._match_file f join public.account a on a.id = f.id"""
        ).fetchall()
    }
    items: dict[str, list[ItemInfo]] = {}
    for item, account, ref, balance in conn.execute(
        """select i.id::text, i.account_id::text, i.ref, coalesce(b.balance, 0)
           from pg_temp._match_file f
           join public.claim_item i on i.account_id = f.id
           left join (select la.claim_item_id, sum(lp.amount_minor) as balance
                      from pg_temp._match_file f2
                      join public.ledger_account la on la.account_id = f2.id
                       and la.book = 'debtor_receivable'
                      join public.ledger_posting lp on lp.ledger_account_id = la.id
                      group by la.claim_item_id) b on b.claim_item_id = i.id
           order by i.account_id, i.due_date nulls last, i.ref"""
    ).fetchall():
        items.setdefault(account, []).append(ItemInfo(item, ref, int(balance)))
    names: dict[str, list[str]] = {}
    for account, name in conn.execute(
        """select ap.account_id::text, pa.display_name
           from pg_temp._match_file f
           join public.account_party ap on ap.account_id = f.id
           join public.party pa on pa.id = ap.party_id
           order by ap.account_id, ap.role, pa.display_name"""
    ).fetchall():
        names.setdefault(account, []).append(name)
    pending = dict(
        conn.execute(
            """select p.account_id::text, sum(p.amount_minor)
               from pg_temp._match_file f
               join public.payment p on p.account_id = f.id and p.status = 'matched'
               group by p.account_id"""
        ).fetchall()
    )
    for aid, (_, ref, status, currency) in files.items():
        its = tuple(items.get(aid, ()))
        d.accounts[aid] = AccountInfo(
            aid,
            ref,
            status,
            str(currency).strip(),
            tuple(dict.fromkeys(names.get(aid, ()))),
            its,
            sum(i.balance_minor for i in its),
            int(pending.get(aid) or 0),
        )


def load_remainder(
    conn: Conn, org: str, rest: Sequence[tuple[PaymentIn, Signals]], d: Directory
) -> None:
    """For R5/R6: files whose open balance, or one of whose invoices', equals a payment's amount
    (an amount shared by more than 20 files says nothing), and files whose party names are close
    to the payer's (trigram index on party.display_name)."""
    amounts = sorted({p.amount_minor for p, _ in rest})
    rows = conn.execute(
        """with b as (
             select la.account_id, la.claim_item_id, sum(lp.amount_minor) as balance
             from public.ledger_account la
             join public.ledger_posting lp on lp.ledger_account_id = la.id
             where la.organization_id = %s and la.book = 'debtor_receivable'
             group by la.account_id, la.claim_item_id)
           select x.balance, x.account_id::text from (
             select account_id, sum(balance) as balance from b group by account_id
             union
             select account_id, balance from b) x
           where x.balance = any(%s)""",
        (org, amounts),
    ).fetchall()
    by_amount: dict[int, set[str]] = {}
    for amount, account in rows:
        by_amount.setdefault(int(amount), set()).add(account)
    d.by_amount = {k: frozenset(v) for k, v in by_amount.items() if len(v) <= MAX_PER_AMOUNT}
    named = [(p.id, p.payer_name) for p, _ in rest if p.payer_name][:NAME_SEARCH_MAX]
    if named:
        conn.execute(
            "select set_config('pg_trgm.similarity_threshold', %s, true)",
            (str(NAME_SEARCH_THRESHOLD),),
        )
        found = conn.execute(
            """select n.pid, x.account_id::text
               from unnest(%s::text[], %s::text[]) as n (pid, name)
               cross join lateral (
                 select ap.account_id, max(extensions.similarity(pa.display_name, n.name)) as sim
                 from public.party pa join public.account_party ap on ap.party_id = pa.id
                 where pa.organization_id = %s and pa.display_name operator(extensions.%%) n.name
                 group by ap.account_id order by sim desc, ap.account_id limit 5) x""",
            ([n[0] for n in named], [n[1] for n in named], org),
        ).fetchall()
        by_name: dict[str, list[str]] = {}
        for pid, account in found:
            by_name.setdefault(pid, []).append(account)
        d.by_name = {k: tuple(v) for k, v in by_name.items()}
    wanted = {a for v in d.by_amount.values() for a in v} | {
        a for v in d.by_name.values() for a in v
    }
    load_accounts(conn, d, wanted)


# -- decisions -----------------------------------------------------------------------------------


def _designation(p: PaymentIn, d: Decision) -> Jsonb | None:
    if not d.designation:
        return None
    return Jsonb(
        {
            "item_ids": list(d.designation),
            "source": "remittance_text",
            "captured_at": p.booking_date.isoformat(),
        }
    )


def apply(
    conn: Conn, org: str, trigger: str, payments: Sequence[PaymentIn], decisions: Sequence[Decision]
) -> dict[str, Any]:
    conn.execute("select private.match_results_begin()")
    with (
        conn.cursor() as cur,
        cur.copy(
            """copy pg_temp._mr_decision (payment_id, ord, outcome, rule, method, account_id,
                 rule_version, designation, evidence, teaches, review_reason, candidate_account_id)
               from stdin"""
        ) as copy,
    ):
        for n, (p, d) in enumerate(zip(payments, decisions, strict=True), start=1):
            top = d.candidates[0].account_id if d.candidates and d.acceptable else None
            copy.write_row(
                (
                    p.id,
                    n,
                    d.outcome,
                    d.rule,
                    d.method,
                    d.account_id,
                    RULE_VERSION,
                    _designation(p, d),
                    Jsonb(d.evidence),
                    d.teaches_iban,
                    d.review_reason,
                    top,
                )
            )
    with (
        conn.cursor() as cur,
        cur.copy(
            """copy pg_temp._mr_candidate (payment_id, rank, account_id, rule, acceptable, signals)
               from stdin"""
        ) as copy,
    ):
        for d in decisions:
            if d.automatic:
                continue
            for rank, c in enumerate(d.candidates, start=1):
                signals = {**c.signals, "similarity": f"{c.similarity:.2f}"}
                copy.write_row(
                    (
                        d.payment_id,
                        rank,
                        c.account_id,
                        c.rule,
                        rank == 1 and d.acceptable,
                        Jsonb(signals),
                    )
                )
    row = conn.execute("select private.apply_match_results(%s, %s)", (org, trigger)).fetchone()
    return dict(row[0]) if row else {}
