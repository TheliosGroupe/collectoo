"""The `remittances` queue (M2c-4; design §9.3 to §9.5, §16; ADR-0014 M2c-4 addendum).

- `schedule` (hourly, pg_cron, one message per servicer with work): once per Paris business date
  from 05:00, a draft for each (client, currency) with collections waiting and no pending run when
  (a) one of the client's mandates schedules a run today (the 1st and 16th, or its weekday, moved to
  the next business day), (b) the deadline guard is due (the earliest latest execution date of its
  positive items 5 business days away or less), or (c) a payout came back — `remittance.schedule`
  decides, `private.create_remittance_run` reserves the items under the allocation lock (key
  `sched:<client>:<currency>:<date>`). It also sends back to draft an approval stuck for more than
  10 minutes and queues again a stuck prepare.
- `prepare {run, token}`: loads the facts of the items the draft reserved, prices them
  (`remittance.run.prepare_run`: deadlines, commission, documents, settlement plan, hash) and writes
  the draft (COPY of the lines, then `private.remittance_record_draft`); a later « Actualiser »
  makes an earlier job a no-op (its token). A data error leaves the draft unprepared, with why.
- `approve {run, token}`: one run per transaction (`private.approve_remittance_run`): the run's
  checks, its lines frozen, its invoices and credit notes numbered and posted, its payout ordered or
  its settlement posted (N = 0). A data error (22xxx, 23xxx, LGxxx) sends the run back to draft with
  its reason at once; other errors are retried by the queue, then the dead-letter hook sends it
  back.
- `documents {organization_id}` (M2c-5): the statements and the invoice PDFs due for one servicer
  (`jobs.remittance_documents`), each under its own savepoint: one that cannot be drawn is recorded
  and retried, the others go on; the nightly alerts are `remittance_document_failed` and
  `remittance_document_missing` (still due after 24 hours).

No model, no LLM: every amount comes from the ledger and the engines (CLAUDE.md).
"""

from __future__ import annotations

import logging
import time
from collections import defaultdict
from dataclasses import replace
from datetime import date, datetime
from decimal import Decimal
from typing import Any
from zoneinfo import ZoneInfo

import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.jobs.remittance_documents import run_documents
from collectoo_worker.remittance.calendar import Calendar, CalendarHorizonError, conservative
from collectoo_worker.remittance.commission import FileFacts, KeyState, LineKind, Part
from collectoo_worker.remittance.documents import EarlierCharge, EarlierInvoice
from collectoo_worker.remittance.run import (
    Draft,
    Facts,
    Item,
    OpenInvoiceRow,
    PendingLine,
    Terms,
    prepare_run,
)
from collectoo_worker.remittance.schedule import guard_due, is_scheduled
from collectoo_worker.remittance.settlement import SettlementInputError, SettlementPlan
from collectoo_worker.remittance.terms import RemittanceTerms
from collectoo_worker.runtime.storage import Storage

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.remittances")
PARIS = ZoneInfo("Europe/Paris")
SCHEDULE_FROM_HOUR = (
    5  # the schedule acts once per Paris business date from 05:00 (ops critique #30)
)
DRAFT_COLUMNS = (
    "run_id",
    "line_no",
    "ledger_entry_id",
    "kind",
    "account_id",
    "portfolio_id",
    "mandate_id",
    "mandate_terms_id",
    "payment_id",
    "encaissement_date",
    "effective_date",
    "posted_at",
    "deadline",
    "latest_execution_date",
    "unmeetable",
    "amount_minor",
    "basis",
    "commission_minor",
    "commission_state",
    "commission_reason",
    "parts",
    "original_entry_id",
    "invoiced",
)


def deterministic(exc: psycopg.Error) -> bool:
    """Data, constraint and ledger errors fail the same way on every retry (see jobs.boarding)."""
    return (exc.sqlstate or "").startswith(("LG", "22", "23"))


def make_handler(storage: Storage | None = None) -> Any:
    def handle(payload: dict[str, Any], conn: Conn) -> None:
        kind = payload.get("type")
        if kind == "documents":
            if storage is None:
                raise RuntimeError("the documents job needs the storage")
            run_documents(conn, storage, payload)
        elif kind == "schedule":
            run_schedule(conn, payload)
        elif kind == "prepare":
            run_prepare(conn, payload)
        elif kind == "approve":
            run_approve(conn, payload)
        else:
            raise ValueError(f"unknown remittances job type: {kind!r}")

    return handle


def record_dead_job(payload: dict[str, Any], error: str, conn: Conn) -> None:
    """A job failed for good: its run says so (back to draft, or not prepared) and waits for ops; a
    servicer's schedule is recorded for the nightly checks (`remittance_schedule_failed`)."""
    if payload.get("type") == "schedule":
        org = payload.get("organization_id")
        if org:
            _schedule_failed(conn, str(org), None, "dead", error)
        return
    run, token = payload.get("run_id"), payload.get("token")
    if not run or not token:
        return
    if payload.get("type") == "approve":
        conn.execute(
            "select private.remittance_back_to_draft(%s, %s, 'approval_failed', %s)",
            (str(run), str(token), error[:500]),
        )
    elif payload.get("type") == "prepare":
        conn.execute(
            "select private.remittance_prepare_failed(%s, %s, 'prepare_failed', %s)",
            (str(run), str(token), error[:500]),
        )


# -- schedule -------------------------------------------------------------------------------------


def run_schedule(conn: Conn, payload: dict[str, Any], now: datetime | None = None) -> list[str]:
    """The drafts the schedule creates for one servicer now (Paris time); `now` for tests.

    One client's data error never stops the others (review nc#0): the recovery of stuck jobs, the
    candidates' read and each client's draft run in their own savepoint; a data error is logged and
    recorded for the nightly checks (`remittance_schedule_failed`), and the job goes on, so what was
    done is committed with it. Any other error (a lock timeout) fails the job, which the queue
    retries."""
    org = str(payload["organization_id"])
    conn.execute("set local lock_timeout = '5s'")
    with conn.transaction():
        conn.execute("select private.remittance_stuck_jobs(%s)", (org,))
    at = (now or datetime.now(PARIS)).astimezone(PARIS)
    today = at.date()
    if at.hour < SCHEDULE_FROM_HOUR:
        return []
    cal = conservative()
    business = cal.is_business_day(today)
    try:
        with conn.transaction():
            rows = conn.execute(
                "select * from private.remittance_schedule_candidates(%s, %s)", (org, today)
            ).fetchall()
    except psycopg.Error as exc:
        if not deterministic(exc):
            raise
        log.warning("schedule %s: candidates not read (%s %s)", org, exc.sqlstate, exc)
        _schedule_failed(conn, org, None, "candidates", f"{exc.sqlstate}: {exc}")
        return []
    created = []
    for client, currency, terms_docs, payout_returned, latest in rows:
        key = f"sched:{client}:{currency}:{today.isoformat()}"
        try:
            trigger = _schedule_trigger(terms_docs, payout_returned, latest, today, business, cal)
            if trigger is None:
                continue
            with conn.transaction():
                row = conn.execute(
                    "select private.create_remittance_run(%s, %s, %s, %s, %s, null)",
                    (org, client, currency, trigger, key),
                ).fetchone()
        except psycopg.Error as exc:
            if not deterministic(exc):
                raise
            log.warning("schedule %s: no draft for %s (%s %s)", org, client, exc.sqlstate, exc)
            _schedule_failed(conn, org, str(client), "client", f"{exc.sqlstate}: {exc}")
            continue
        except ValueError as exc:  # its terms do not validate (pydantic), a calendar horizon
            log.warning("schedule %s: no draft for %s (%s)", org, client, exc)
            _schedule_failed(conn, org, str(client), "client", str(exc))
            continue
        if row and row[0]:
            created.append(str(row[0]))
    if created:
        log.info("schedule %s: %d drafts", org, len(created))
    return created


def _schedule_trigger(  # noqa: PLR0913, PLR0917 - one candidate row, the day, the calendar
    terms_docs: list[dict[str, Any]] | None,
    payout_returned: bool,
    latest: list[date] | None,
    today: date,
    business: bool,
    cal: Calendar,
) -> str | None:
    """Why a client's draft is due today, if it is (§9.3: a payout come back, a scheduled day of
    one of its mandates, the deadline guard)."""
    terms = [RemittanceTerms.model_validate(t) for t in terms_docs or ()]
    if payout_returned:
        return "payout_returned"
    if business and any(is_scheduled(t, today, cal) for t in terms):
        return "schedule"
    if guard_due(today, latest or (), cal):
        return "deadline"
    return None


def _schedule_failed(conn: Conn, org: str, client: str | None, code: str, error: str) -> None:
    conn.execute(
        "select private.record_remittance_schedule_failure(%s, %s, %s, %s)",
        (org, client, code, (error or "unknown error")[:2000]),
    )


# -- prepare --------------------------------------------------------------------------------------


def run_prepare(conn: Conn, payload: dict[str, Any]) -> str:
    run, token = str(payload["run_id"]), str(payload["token"])
    started = time.monotonic()
    try:
        with conn.transaction():
            facts = load_facts(conn, run, token)
            if facts is None:
                return "skipped"
            loaded = time.monotonic()
            draft = prepare_run(facts)
            priced = time.monotonic()
            written = write_draft(conn, run, token, draft)
    except (SettlementInputError, CalendarHorizonError, ValueError) as exc:
        _prepare_failed(conn, run, token, "prepare_failed", str(exc))
        return "failed"
    except psycopg.Error as exc:
        if not deterministic(exc):
            raise
        _prepare_failed(
            conn, run, token, f"data_error:{exc.sqlstate}", exc.diag.message_primary or ""
        )
        return "failed"
    log.info(
        "prepare %s: %d lines, load %.2fs, price %.2fs, write %.2fs",
        run,
        len(draft.lines),
        loaded - started,
        priced - loaded,
        time.monotonic() - priced,
    )
    return "prepared" if written else "skipped"


def _prepare_failed(conn: Conn, run: str, token: str, code: str, detail: str) -> None:
    conn.execute(
        "select private.remittance_prepare_failed(%s, %s, %s, %s)", (run, token, code, detail[:500])
    )


def _uuid(v: Any) -> str | None:
    return None if v is None else str(v)


def load_facts(conn: Conn, run: str, token: str) -> Facts | None:  # noqa: PLR0915
    """Everything the run's draft depends on, read in the job's transaction."""
    head = conn.execute(
        """select r.organization_id, r.client_organization_id, r.currency, r.number, r.known_at,
                  r.service_from, r.service_to, r.status, r.job, r.job_token, private.paris_today(),
                  coalesce(s.vat_on_debits, false)
           from public.remittance_run r
           left join public.servicer_billing_settings s on s.organization_id = r.organization_id
           where r.id = %s""",
        (run,),
    ).fetchone()
    if head is None or head[7] != "draft" or head[8] != "prepare" or str(head[9]) != token:
        return None
    _, client, currency, number, known_at, s_from, s_to, _, _, _, today, on_debits = head
    vat = conn.execute("select private.vat_rate_on(%s)", (today,)).fetchone()
    if vat is None:  # pragma: no cover (vat_rate_on raises instead)
        raise ValueError("no VAT rate today")
    vat_rate = Decimal(vat[0])

    raw = conn.execute(
        """select q.ledger_entry_id, q.kind, q.amount_minor, q.posted_at, e.effective_date,
                  coalesce(e.account_id, p.account_id), coalesce(e.payment_id, oe.payment_id),
                  private.encaissement_date(p.booking_date, p.value_date), e.reverses_entry_id
           from private.remittance_pending q
           join public.ledger_entry e on e.id = q.ledger_entry_id
           left join public.ledger_entry oe on oe.id = e.reverses_entry_id
           left join public.payment p on p.id = coalesce(e.payment_id, oe.payment_id)
           where q.draft_run_id = %s""",
        (run,),
    ).fetchall()
    pending_raw = conn.execute(
        """select l.run_id, l.line_no, l.ledger_entry_id, l.kind, l.amount_minor, l.posted_at,
                  l.effective_date, l.account_id, l.payment_id, l.encaissement_date, l.basis,
                  l.original_entry_id
           from public.remittance_line l
           where l.client_organization_id = %s and l.currency = %s
             and l.commission_state = 'pending' and not l.released
             and not exists (select 1 from public.remittance_line_repricing rp
                             join public.remittance_run pr on pr.id = rp.pricing_run_id
                               and pr.status <> 'cancelled'
                             where rp.run_id = l.run_id and rp.line_no = l.line_no)""",
        (client, currency),
    ).fetchall()
    with_basis = [str(r[0]) for r in raw if r[1] in ("allocation", "allocation_reversal")]
    basis: dict[str, dict[str, int]] = defaultdict(dict)
    for entry, family, amount in conn.execute(
        """select p.entry_id, c.family, -sum(p.amount_minor)
           from public.ledger_posting p
           join public.ledger_account la on la.id = p.ledger_account_id
             and la.book = 'debtor_receivable'
           join public.ledger_component c on c.code = la.component
           where p.entry_id = any(%s::uuid[])
           group by p.entry_id, c.family""",
        (with_basis,),
    ).fetchall():
        basis[str(entry)][family] = int(amount)
    forwards = [str(r[0]) for r in raw if r[1] == "forward"]
    forwards += [str(r[8]) for r in raw if r[1] == "forward_reversal" and r[8]]
    forwards += [str(r[2]) for r in pending_raw if r[3] == "forward"]
    forwards += [str(r[11]) for r in pending_raw if r[3] == "forward_reversal" and r[11]]
    reasons = dict(
        conn.execute(
            """select n.ledger_entry_id::text, n.reason from public.client_notification n
               where n.ledger_entry_id = any(%s::uuid[]) and n.kind = 'payment_forwarded'""",
            (forwards,),
        ).fetchall()
    )

    def reason_of(kind: str, entry: str, original: str | None) -> str | None:
        if kind == "forward":
            return reasons.get(entry)
        if kind == "forward_reversal" and original:
            return reasons.get(original)
        return None

    items = [
        Item(
            entry_id=str(r[0]),
            kind=LineKind(r[1]),
            amount_minor=int(r[2]),
            posted_at=r[3],
            effective_date=r[4],
            account_id=_uuid(r[5]),
            payment_id=_uuid(r[6]),
            encaissement_date=r[7],
            basis=basis.get(str(r[0]), {}),
            forward_reason=reason_of(r[1], str(r[0]), _uuid(r[8])),
            original_entry_id=_uuid(r[8]),
        )
        for r in raw
    ]
    pending_lines = [
        PendingLine(
            str(r[0]),
            int(r[1]),
            Item(
                entry_id=str(r[2]),
                kind=LineKind(r[3]),
                amount_minor=int(r[4]),
                posted_at=r[5],
                effective_date=r[6],
                account_id=_uuid(r[7]),
                payment_id=_uuid(r[8]),
                encaissement_date=r[9],
                basis={k: int(v) for k, v in (r[10] or {}).items()},
                forward_reason=reason_of(r[3], str(r[2]), _uuid(r[11])),
                original_entry_id=_uuid(r[11]),
            ),
        )
        for r in pending_raw
    ]
    accounts = sorted(
        {i.account_id for i in items if i.account_id}
        | {p.item.account_id for p in pending_lines if p.item.account_id}
    )
    file_rows = conn.execute(
        """select a.id, a.claim_type_code, a.portfolio_id, pf.mandate_id
           from public.account a join public.portfolio pf on pf.id = a.portfolio_id
           where a.id = any(%s::uuid[])""",
        (accounts,),
    ).fetchall()
    mandates = sorted({str(r[3]) for r in file_rows if r[3]})
    terms: dict[str, list[Terms]] = defaultdict(list)
    for t in conn.execute(
        """select id, mandate_id, valid_from, valid_to, remittance_max_days, commission_schedule,
                  remittance_terms, commission_clause_ref, remittance_clause_ref
           from public.mandate_terms where mandate_id = any(%s::uuid[]) order by valid_from""",
        (mandates,),
    ).fetchall():
        terms[str(t[1])].append(
            Terms(str(t[0]), str(t[1]), t[2], t[3], int(t[4]), t[5], t[6], t[7], t[8])
        )
    brackets = any(
        (rule.get("rate") or {}).get("kind") == "bracket"
        for rows in terms.values()
        for t in rows
        for rule in (t.schedule or {}).get("rules", [])
    )
    attrs: dict[str, tuple[int | None, int | None]] = {}
    if brackets:  # the attributes fixed at boarding (bracket rules only)
        for a, boarded, age in conn.execute(
            """select a.id,
                      (select sum(lp.amount_minor) from public.ledger_entry e
                       join public.ledger_posting lp on lp.entry_id = e.id
                       join public.ledger_account la on la.id = lp.ledger_account_id
                         and la.book = 'debtor_receivable'
                       where e.account_id = a.id and e.entry_type = 'opening'),
                      (select min(o.valid_from) from public.claim_ownership_period o
                       where o.account_id = a.id)
                      - (select min(i.due_date) from public.claim_item i where i.account_id = a.id)
               from public.account a where a.id = any(%s::uuid[])""",
            (accounts,),
        ).fetchall():
            attrs[str(a)] = (None if boarded is None else int(boarded), age)
    files = {
        str(r[0]): FileFacts(
            account_id=str(r[0]),
            mandate_id=str(r[3]),
            claim_type=r[1],
            portfolio_id=str(r[2]),
            boarded_amount_minor=attrs.get(str(r[0]), (None, None))[0],
            age_days_at_boarding=attrs.get(str(r[0]), (None, None))[1],
        )
        for r in file_rows
        if r[3]
    }
    portfolio = {str(r[0]): str(r[2]) for r in file_rows}
    items = [replace(i, portfolio_id=portfolio.get(i.account_id or "")) for i in items]
    refs = dict(
        conn.execute(
            "select id::text, reference from public.mandate where id = any(%s::uuid[])", (mandates,)
        ).fetchall()
    )
    # the latest state of each (file, tier key) its mandate's terms can price — one keyed read per
    # key, however many runs wrote the key before (append-only history; review perf#7)
    keys = sorted(
        {
            (account, str(rule["tier_key"]))
            for account, f in files.items()
            for t in terms.get(f.mandate_id, ())
            for rule in (t.schedule or {}).get("rules", [])
            if rule.get("tier_key")
        }
    )
    history: dict[tuple[str, str], KeyState] = {}
    for a, tier, b, kept_basis, kept, commission, waived in conn.execute(
        "select * from private.remittance_key_states(%s::uuid[], %s::text[])",
        ([a for a, _ in keys], [t for _, t in keys]),
    ).fetchall():
        history[(str(a), tier)] = KeyState(
            basis=tuple(sorted((str(v), int(x)) for v, x in b if int(x))),
            kept_basis_minor=int(kept_basis),
            kept_minor=int(kept),
            commission_minor=int(commission),
            waived_minor=int(waived),
        )
    seq_row = conn.execute("select private.remittance_history_seq(%s)", (client,)).fetchone()
    # what each earlier invoice still charges each key (every credit note's allocations off, a
    # manual one's included) and what manual credit notes left waived on it (M2c-5b): the engine's
    # capacity is their sum
    charges: dict[tuple[str, str], list[EarlierCharge]] = defaultdict(list)
    for a, tier, inv, year, seq, charged, credited, rate, waived in conn.execute(
        """select ch.account_id, ch.tier_key, ch.invoice_id, i.year, i.seq, ch.charged_minor,
                  coalesce((select -sum(x.ht_minor) from public.commission_credit_alloc x
                            where x.original_invoice_id = ch.invoice_id
                              and x.account_id = ch.account_id and x.tier_key = ch.tier_key), 0),
                  i.vat_rate,
                  coalesce((select sum(w.amount_minor) from public.commission_waiver w
                            where w.invoice_id = ch.invoice_id
                              and w.account_id = ch.account_id and w.tier_key = ch.tier_key), 0)
           from public.commission_invoice_charge ch
           join public.commission_invoice i on i.id = ch.invoice_id
           where ch.account_id = any(%s::uuid[])""",
        (accounts,),
    ).fetchall():
        charges[(str(a), tier)].append(
            EarlierCharge(
                str(inv),
                (int(year), int(seq)),
                int(charged),
                int(credited),
                Decimal(rate),
                waived_minor=int(waived),
            )
        )
    invoice_ids = sorted({c.invoice_id for cs in charges.values() for c in cs})
    invoices: dict[str, EarlierInvoice] = {}
    numbers: dict[str, tuple[str, date]] = {}
    for inv, ht, rate, credited, num, issued in conn.execute(
        """select i.id, i.ht_minor, i.vat_rate,
                  coalesce((select -sum(c.ht_minor) from public.commission_credit_correction c
                            where c.original_invoice_id = i.id), 0), i.number, i.issue_date
           from public.commission_invoice i where i.id = any(%s::uuid[])""",
        (invoice_ids,),
    ).fetchall():
        invoices[str(inv)] = EarlierInvoice(str(inv), int(ht), Decimal(rate), int(credited))
        numbers[str(inv)] = (num, issued)
    # each reversal's original: the invoices that charge it now — its line's (or its live
    # repricing's) invoice and, when a cancelled run had credited this reversal, first the
    # corrective invoice that cancellation issued to charge it again (money review #0: credited
    # there, once;
    # M2c-5b: then on the line's own invoice, where the cancellation restored what the run's credit
    # had absorbed of a manual credit note's waiver)
    undone = sorted(
        {(i.entry_id, i.original_entry_id) for i in items if i.original_entry_id}
        | {
            (p.item.entry_id, p.item.original_entry_id)
            for p in pending_lines
            if p.item.original_entry_id
        }
    )
    line_invoices: dict[str, str | tuple[str, ...]] = {}
    for e, corrective, own in conn.execute(
        """select l.ledger_entry_id,
                 (select j.id from public.commission_credit_alloc a
                  join public.commission_invoice cn on cn.id = a.credit_note_id
                    and cn.reason = 'commission'
                  join public.remittance_run cr on cr.id = cn.run_id
                    and cr.status = 'cancelled'
                  join public.commission_invoice o on o.id = a.original_invoice_id
                  join public.commission_invoice j on j.run_id = cn.run_id
                    and j.kind = 'invoice' and j.reason = 'run_cancelled'
                    and j.mandate_id = cn.mandate_id and j.vat_rate = o.vat_rate
                  where a.entry_id = u.reversal
                  order by cn.year desc, cn.seq desc limit 1),
                 coalesce((select rp.invoice_id from public.remittance_line_repricing rp
                           join public.remittance_run pr on pr.id = rp.pricing_run_id
                             and pr.status <> 'cancelled'
                           where rp.run_id = l.run_id and rp.line_no = l.line_no limit 1),
                          l.invoice_id)
           from unnest(%s::uuid[], %s::uuid[]) u (reversal, original)
           join public.remittance_line l on l.ledger_entry_id = u.original
             and not l.released""",
        ([r for r, _ in undone], [o for _, o in undone]),
    ).fetchall():
        chain_of = tuple(str(x) for x in (corrective, own) if x is not None)
        if chain_of:
            line_invoices[str(e)] = chain_of[0] if len(chain_of) == 1 else chain_of
    open_docs = [
        OpenInvoiceRow(str(i), str(m), kind, num, issued, (int(y), int(s)), int(o), int(v))
        for i, m, kind, num, issued, y, s, o, v in conn.execute(
            """select i.id, i.mandate_id, i.kind, i.number, i.issue_date, i.year, i.seq,
                      private.document_open(i.id), private.document_pending_vat(i.id)
               from public.commission_invoice i where i.client_organization_id = %s""",
            (client,),
        ).fetchall()
        if int(o) > 0 or int(v) > 0
    ]
    blockers_row = conn.execute(
        """select private.remittance_payout_blockers(%s, %s, %s),
                  private.remittance_commission_blockers(%s),
                  (select pa.id from public.client_payout_account pa
                   where pa.client_organization_id = %s and pa.currency = %s
                     and pa.status = 'active'),
                  (select min(e.effective_date) from public.client_status_event e
                   where e.client_organization_id = %s and e.kind = 'proceeding_opened'
                     and e.effective_date <= %s)""",
        (client, currency, today, client, client, currency, client, today),
    ).fetchone()
    if blockers_row is None or seq_row is None:  # pragma: no cover (aggregates: one row)
        raise ValueError("no row")
    return Facts(
        run_id=run,
        number=number,
        client_id=str(client),
        currency=currency,
        known_at=known_at,
        today=today,
        service_from=s_from,
        service_to=s_to,
        vat_rate=vat_rate,
        vat_on_debits=bool(on_debits),
        items=items,
        pending_lines=pending_lines,
        files=files,
        mandate_refs=refs,
        terms=terms,
        history=history,
        history_seq=int(seq_row[0]),
        charges=charges,
        invoices=invoices,
        invoice_numbers=numbers,
        line_invoices=line_invoices,
        open_documents=open_docs,
        payout_blockers=list(blockers_row[0] or ()),
        commission_blockers=list(blockers_row[1] or ()),
        payout_account_id=_uuid(blockers_row[2]),
        proceeding_opened_on=blockers_row[3],
    )


def part_json(p: Part) -> dict[str, Any]:
    return {
        "account_id": p.account_id,
        "tier_key": p.tier_key,
        "rule_id": p.rule_id,
        "label_fr": p.label_fr,
        "families": list(p.families),
        "basis": str(p.basis_minor),
        "basis_before": str(p.basis_before),
        "basis_after": str(p.basis_after),
        "commission": str(p.commission_minor),
        "tiers": [[r, str(b)] for r, b in p.tiers],
        "retiering": [[r, str(b)] for r, b in p.retiering],
        "minimum": p.minimum_applied,
        "capped": p.capped,
        "held": str(p.held_minor),
        "kept": p.kept,
    }


def plan_json(p: SettlementPlan) -> dict[str, Any]:
    return {
        "mandates": [
            {
                "mandate_id": m.mandate_id or None,
                "gross": str(m.gross_minor),
                "excess": str(m.excess_minor),
                "take": str(m.take_minor),
                "take_advance": str(m.take_advance_minor),
                "net": str(m.net_minor),
                "settlement": str(m.settlement_minor),
            }
            for m in p.mandates
        ],
        "settles": [
            {
                "ref": s.ref,
                "mandate_id": s.mandate_id,
                "kind": s.kind,
                "amount": str(s.amount_minor),
                "vat_moved": str(s.vat_moved_minor),
                "open_before": str(s.open_before_minor),
            }
            for s in p.settles
        ],
        "net": str(p.net_minor),
        "settlement": str(p.settlement_minor),
        "dc": str(p.commission_settled_minor),
        "da": str(p.advances_taken_minor),
        "vat_moved": str(p.vat_moved_minor),
        "deferred": p.deferred,
    }


def write_draft(conn: Conn, run: str, token: str, draft: Draft) -> bool:
    """The draft lines (COPY) and the header, if the run is still this job's."""
    row = conn.execute("select private.remittance_prepare_begin(%s, %s)", (run, token)).fetchone()
    if not row or not row[0]:
        return False
    cols = ", ".join(DRAFT_COLUMNS)
    with conn.cursor().copy(f"copy private.remittance_draft_line ({cols}) from stdin") as copy:
        for ln in draft.lines:
            i = ln.item
            dl = ln.deadline
            copy.write_row(
                (
                    run,
                    ln.line_no,
                    i.entry_id,
                    i.kind.value,
                    i.account_id,
                    i.portfolio_id,
                    ln.mandate_id,
                    ln.terms_id,
                    i.payment_id,
                    i.encaissement_date,
                    i.effective_date,
                    i.posted_at,
                    dl.deadline if dl else None,
                    dl.latest_execution if dl else None,
                    bool(dl and dl.unmeetable),
                    i.amount_minor,
                    Jsonb({k: str(v) for k, v in sorted(i.basis.items()) if v}),
                    ln.commission_minor,
                    ln.state,
                    ln.reason,
                    Jsonb([part_json(p) for p in ln.parts]),
                    i.original_entry_id,
                    ln.invoiced,
                )
            )
    payload = {
        **draft.header,
        "documents": list(draft.documents),
        "key_states": list(draft.key_states),
        "plan": plan_json(draft.plan),
        "repricing": [
            {
                "run_id": p.run_id,
                "line_no": p.line_no,
                "ledger_entry_id": p.item.entry_id,
                "commission": str(lc.commission_minor),
                "state": "charged" if lc.state == "charged" else "none",
                "reason": lc.reason,
                "parts": [part_json(x) for x in lc.parts],
                "invoiced": invoiced,
            }
            for p, lc, invoiced in draft.repricing
        ],
    }
    conn.execute(
        "select private.remittance_record_draft(%s, %s, %s)",
        (run, token, Jsonb(payload, dumps=_dumps)),
    )
    return True


def _dumps(obj: Any) -> str:
    import json  # noqa: PLC0415 - only to serialise dates

    return json.dumps(obj, default=lambda x: x.isoformat() if isinstance(x, date) else str(x))


# -- approve --------------------------------------------------------------------------------------


def run_approve(conn: Conn, payload: dict[str, Any]) -> dict[str, Any]:
    """One run, in its own transaction (the queue's): a data error sends it back to draft with its
    reason; the deferred checks (the ledger's, the invoices' foreign keys) run inside the
    attempt."""
    run, token = str(payload["run_id"]), str(payload["token"])
    try:
        with conn.transaction():
            row = conn.execute(
                "select private.approve_remittance_run(%s, %s)", (run, token)
            ).fetchone()
            conn.execute("set constraints all immediate")
            conn.execute("set constraints all deferred")
    except psycopg.Error as exc:
        if not deterministic(exc):
            raise
        detail = exc.diag.message_primary or str(exc)
        conn.execute(
            "select private.remittance_back_to_draft(%s, %s, %s, %s)",
            (run, token, f"data_error:{exc.sqlstate}", detail[:500]),
        )
        log.warning("approve %s: back to draft (%s %s)", run, exc.sqlstate, detail)
        return {"status": "back_to_draft", "reason": f"data_error:{exc.sqlstate}"}
    result = dict(row[0]) if row else {}
    log.info("approve %s: %s", run, result.get("status"))
    return result
