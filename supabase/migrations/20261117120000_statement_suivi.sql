-- M2c-6b-2d « Suivi » (plan docs/design/m2c-6b-2-plan.md §5, the 6b-2d parts of §6–§12; ADR-0014 « M2c-6b-2d »). The
-- client statement's section « Suivi de vos reversements précédents » says what became of the payouts of the client's
-- earlier runs, as of this run's K, and a late line an unplanned payout paid says when (template
-- `releve-reversement-fr-3`, worker `remittance/statement.py`):
--   * the payload drops M2c-5's `follow_up` (the previous run's transfer as it stands when the statement is drawn, not
--     as of K) and adds `previous_payouts` {since, events}: the events of the client's earlier approved runs of the
--     currency (critic L7: approved_at set — a draft discarded with its RV number is never listed nor bounds the
--     window; N > 0: a run with a payout) posted in the window from the K of the client's previous approved run of
--     the currency (critic L17: not its statement, drawn asynchronously; −∞ for none) to this run's K, time per ADR-0012
--     (ledger_entry.posted_at, remittance_run.cancelled_at against K); `since` names that previous run and its K;
--   * the events, one each, ordered by date (effective dates), then run number: `debited` (the planned debit of a
--     transfer of the run's chain), `returned` (its return; `repaid` here / run / pending), `cancelled` (the run
--     cancelled in the window, unless the same window holds its `executed_after_cancellation`),
--     `executed_after_cancellation` / `debited_again` (an unplanned booking of a transfer of the run's chain — critic2
--     ML-12 — after the run's cancellation / otherwise, with its amount, the advance and `p_bound` read from the
--     booking's advance, critic2 ML-9), `unplanned_returned` (the return of an unplanned booking, P owed again — critic
--     L4) and `executed_outside` (an unplanned payout to the client with no transfer, S13/S07 — critic L16 — with the
--     last four characters of the IBAN it went to);
--   * a late line whose item an unplanned payout's P paid (private.unplanned_paid_item of a booking posted at or before
--     K with no reversal posted by then — critic2 ML-9) carries the amount attributed and that booking's date (two new
--     line columns, appended: paid_by_unplanned_minor, paid_by_unplanned_on), and takes late_cause `paid_by_unplanned`
--     when that amount is all of the line (review round 1 legal-texts-3: paid in part, it keeps its own cause).
-- Review round 1 (ADR-0014 « M2c-6b-2d review fixes »): an unplanned booking of a run's chain carries its rank among the
-- chain's executions (`execution_no`), and a debited_again the planned debit's date and whether it came first
-- (`debited_on`, `before_debit`); events of a day keep their posting order; an S13 is listed before its same-day
-- return; the chain's transfers and live lines are read by key alone. private.remittance_documents_record refuses a
-- statement drawn by a template other than `releve-reversement-fr-3` (review SR-2: a worker deployed after this
-- migration never stores a « Suivi » it cannot word).
-- A payout_returned line reversing an unplanned remittance already carries nature_reason `unplanned` (6b-2b review LT-2,
-- critic L4, brought forward): unchanged. The cancellation-after-download switch stays OFF; pgTAP 033 and 034 unchanged.
--
-- New: bank_line_booking_unplanned_client_idx (the servicer's unplanned payouts with no transfer, a small partial index
-- as bank_line_booking_unplanned_return_idx), private.remittance_statement_previous_payouts,
-- private.remittance_statement_paid_by_unplanned (both internal, keyed, sequential scans off).
-- Redefined, each copied from its latest definition and changed only as its comment says, with its settings and grants
-- restated: private.remittance_statement_line_columns (20261113090000, its only definition),
-- private.remittance_statement_build (20261117100000), private.remittance_documents_record (20261113090000, its only
-- definition).

------------------------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------------------------

-- The servicer's unplanned payouts with no transfer of ours (S13, S07's client part: a debit to a client's payout IBAN
-- booked by ops), by servicer: « Suivi » reads a client's in its window by this small partial index, each entry by key
-- (the client and the time are the entry's). Rows are rare, as the unplanned returns' index they mirror.
create index bank_line_booking_unplanned_client_idx on public.bank_line_booking (organization_id)
  where kind = 'unplanned_payout' and transfer_id is null;

------------------------------------------------------------------------------------------
-- The statement's line columns (redefined from 20261113090000: two columns appended)
------------------------------------------------------------------------------------------

-- The names of a statement line's fields, in the payload's order. M2c-6b-2d: paid_by_unplanned_minor and
-- paid_by_unplanned_on appended (a late line an unplanned payout paid: how much, and when); the CSV's columns do not
-- change (the renderer reads the fields by name).
create or replace function private.remittance_statement_line_columns()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '["line_no", "mandate", "portfolio", "file", "debtor", "items", "components", "nature", "nature_reason",
           "from_run", "encaissement_date", "effective_date", "deadline", "amount_minor", "rules", "rates",
           "basis_minor", "commission_minor", "commission_state", "invoice", "receipt", "late", "late_cause",
           "paid_by_unplanned_minor", "paid_by_unplanned_on"]'::jsonb;
$$;

------------------------------------------------------------------------------------------
-- What an unplanned payout paid of an item, as of K (critic L9, critic2 ML-9)
------------------------------------------------------------------------------------------

-- The amount unplanned payouts' P attributed to the item of entry p_entry_id (private.unplanned_paid_item) and the
-- latest such booking's date, counting only the bookings whose remittance entry was posted at or before p_known_at and
-- has no reversal posted at or before it (an unplanned return after K does not change a statement of K; one before K
-- does: those items were owed again by K). No row when none counts. Keyed: the attributions by
-- unplanned_paid_item_entry_idx, each booking's entry and its reversal by key (ledger_entry_reversed_once_uq).
-- Internal: read by the statement build only.
create or replace function private.remittance_statement_paid_by_unplanned(p_entry_id uuid, p_known_at timestamptz)
returns table (paid_minor bigint, paid_on date)
language sql
stable
set search_path = ''
set enable_seqscan = off
set enable_hashjoin = off
set enable_mergejoin = off
as $$
  select sum(u.amount_minor)::bigint, max(b.effective_date)
  from (select q.booking_entry_id, q.amount_minor from private.unplanned_paid_item q
        where q.ledger_entry_id = p_entry_id offset 0) u
  cross join lateral (select q.posted_at, q.effective_date from public.ledger_entry q
                      where q.id = u.booking_entry_id offset 0) b
  where b.posted_at <= p_known_at
    and not exists (select 1 from public.ledger_entry z
                    where z.reverses_entry_id = u.booking_entry_id and z.posted_at <= p_known_at)
  having count(*) > 0;
$$;

------------------------------------------------------------------------------------------
-- « Suivi »: the earlier runs' payouts in the window, as of K (plan §5; critic L4, L7, L16, L17, critic2 ML-9, ML-12)
------------------------------------------------------------------------------------------

-- {since: {number, known_at} of the client's previous approved run of the currency (null: none), events: [...]}.
-- The window is (since's K, this run's K] on ledger_entry.posted_at and remittance_run.cancelled_at (ADR-0012). The
-- events (amounts as text, dates the entries' effective dates, ordered by date, then run number, then kind, then
-- posting):
--   debited                      {run_number, amount_minor, end_to_end_id, on}: a planned debit booking (`payout`) of a
--                                transfer of the run's chain (private.transfer_chain: the run's transfer, then each one
--                                it re-issues);
--   returned                     {…, debited_on, on, repaid, repaid_by}: its return booking; `repaid` here when this run
--                                holds its payout_returned item in a live line, run when a run approved by K holds it
--                                (repaid_by its number), else pending (this run cancelled since: its items are back in
--                                the queue);
--   cancelled                    {run_number, on}: the run cancelled in the window — not listed when the same window
--                                holds its executed_after_cancellation;
--   executed_after_cancellation  {run_number, cancelled_on, unplanned_minor, advance_minor, p_bound, execution_no, on,
--                                here}: an unplanned booking of a transfer of the chain posted after the run's
--                                cancellation;
--   debited_again                {run_number, unplanned_minor, advance_minor, p_bound, execution_no, debited_on,
--                                before_debit, on, here}: any other unplanned booking of the chain (a booked or returned
--                                payout executed again; a re-issued payout's old transfer executed although the run was
--                                booked);
--   unplanned_returned           {run_number (null: no transfer), unplanned_minor, advance_minor, owed_minor, executed_on,
--                                on, here}: the return of an unplanned booking (its advance reversed, P owed again);
--   executed_outside             {run_number: null, amount_minor, advance_minor, iban_last4, on, here}: an unplanned
--                                payout to the client with no transfer (S13, S07).
-- advance_minor is the booking's double_payout advance (A − P; 0 when P = A), p_bound the bound its booking recorded
-- (6b-2b review LT-4: items, queue, none; `amount` when there is no advance, P = A). `here`: this run holds the
-- booking's (or the return's) entry in a live line. Review M2c-6b-2d round 1 (statement-money, legal-texts-1): an
-- unplanned booking's `execution_no` is its rank among the chain's executions booked by K — its planned debit and every
-- unplanned one, at any time before K, by date, then posting — and a debited_again carries the planned debit's date
-- (`debited_on`, by the chain's `payout` booking, bank_line_booking_debit_uq's) and whether it was executed before it
-- (`before_debit`: a debit the bank made first but booked after the planned one): the renderer says « une seconde fois »
-- only of the second execution. Keyed (sequential and bitmap scans off): the client's runs by
-- remittance_run_client_idx, each chain transfer by its key alone (review round 1 SR-1: the servicer checked on the row
-- read), the bookings by bank_line_booking_transfer_idx, entries and advances by key, the transfer-less bookings by the
-- servicer's small partial indexes; a live line by its entry (remittance_line_live_uq) in its own subquery, the run
-- tested on the row read — with empty statistics the planner may still read remittance_line_account_idx whole for it,
-- whose predicate the probe implies (ADR-0014 « M2c-6b-2d review fixes », left open: only a non-partial index on the
-- entry keys it whatever the statistics). Internal: read by the statement build only.
create or replace function private.remittance_statement_previous_payouts(p_run_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
set enable_bitmapscan = off
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare
  r public.remittance_run;
  v_prev public.remittance_run;
  v_from timestamptz;
  v_events jsonb;
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found then
    return null;
  end if;
  -- the window's start (critic L17, L7): the K of the client's previous approved run of the currency
  select * into v_prev from public.remittance_run x
  where x.client_organization_id = r.client_organization_id and x.currency = r.currency
    and x.organization_id = r.organization_id and x.approved_at is not null and x.known_at < r.known_at
  order by x.known_at desc, x.id desc limit 1;
  v_from := coalesce(v_prev.known_at, '-infinity'::timestamptz);

  with runs as materialized (
    -- the client's earlier approved runs of the currency that ordered a payout (critic L7; N > 0)
    select x.id, x.number, x.status, x.cancelled_at, x.transfer_id
    from public.remittance_run x
    where x.client_organization_id = r.client_organization_id and x.currency = r.currency
      and x.organization_id = r.organization_id and x.approved_at is not null and x.known_at < r.known_at
      and x.transfer_id is not null),
  ab as materialized (
    -- the bookings of each run's chain (critic2 ML-12) posted by K, each transfer by its key alone (review round 1 SR-1:
    -- a tenant predicate beside the key let the planner read every transfer of the servicer by bank_transfer_org_idx;
    -- the servicer is checked on the row read), each entry by key
    select x.id as run_id, x.number as run_number, x.status as run_status, x.cancelled_at as run_cancelled_at,
           t.end_to_end_id, k.kind, k.entry_id, k.amount_minor, e.posted_at, e.effective_date, e.reverses_entry_id
    from runs x
    cross join lateral private.transfer_chain(x.transfer_id) c
    cross join lateral (select y.id, y.end_to_end_id, y.organization_id from public.bank_transfer y
                        where y.id = c.transfer_id offset 0) t
    cross join lateral (select q.kind, q.entry_id, q.amount_minor from public.bank_line_booking q
                        where q.transfer_id = t.id offset 0) k
    cross join lateral (select q.posted_at, q.effective_date, q.reverses_entry_id from public.ledger_entry q
                        where q.id = k.entry_id offset 0) e
    where t.organization_id = r.organization_id
      and k.kind in ('payout', 'payout_returned', 'unplanned_payout', 'unplanned_payout_returned')
      and e.posted_at <= r.known_at),
  xn as materialized (
    -- (review round 1: statement-money, legal-texts-1) the chain's executions booked by K — its planned debit and every
    -- unplanned one, whenever posted — ranked by date, then posting: the second is « une seconde fois », a later one is
    -- not, one dated before the planned debit is neither
    select a.run_id, a.kind, a.entry_id, a.effective_date,
           row_number() over (partition by a.run_id order by a.effective_date, a.posted_at, a.entry_id) as execution_no
    from ab a
    where a.kind in ('payout', 'unplanned_payout')),
  pd as materialized (
    -- each chain's planned debit (one `payout` booking per transfer, bank_line_booking_debit_uq; the first by rank)
    select distinct on (n.run_id) n.run_id, n.effective_date as debited_on, n.execution_no
    from xn n where n.kind = 'payout'
    order by n.run_id, n.execution_no),
  bk as materialized (
    -- the chain bookings posted in the window
    select a.* from ab a where a.posted_at > v_from),
  ev as (
    -- the run's planned debit
    select b.effective_date as on_date, b.run_number, 1 as rank, b.posted_at as posted, b.entry_id as tie,
           jsonb_build_object('kind', 'debited', 'run_number', b.run_number, 'amount_minor', b.amount_minor::text,
                              'end_to_end_id', b.end_to_end_id, 'on', b.effective_date) as event
    from bk b
    where b.kind = 'payout'
    union all
    -- its return, and the run that holds its item again
    select b.effective_date, b.run_number, 2, b.posted_at, b.entry_id,
           jsonb_build_object('kind', 'returned', 'run_number', b.run_number, 'amount_minor', b.amount_minor::text,
                              'end_to_end_id', b.end_to_end_id, 'debited_on', d.effective_date, 'on', b.effective_date,
                              'repaid', case when h.run_id = r.id then 'here' when h.number is not null then 'run'
                                             else 'pending' end,
                              'repaid_by', h.number)
    from bk b
    left join lateral (select q.effective_date from public.ledger_entry q where q.id = b.reverses_entry_id offset 0) d
      on true
    left join lateral (select l.run_id, case when l.run_id <> r.id then y.number end as number
                       from (select q.run_id from public.remittance_line q
                             where q.ledger_entry_id = b.entry_id and not q.released offset 0) l
                       cross join lateral (select q.number, q.approved_at from public.remittance_run q
                                           where q.id = l.run_id offset 0) y
                       where l.run_id = r.id or y.approved_at <= r.known_at) h on true
    where b.kind = 'payout_returned'
    union all
    -- the run cancelled, unless this window also holds its payout executed after the cancellation
    select (x.cancelled_at at time zone 'Europe/Paris')::date, x.number, 3, x.cancelled_at, x.id,
           jsonb_build_object('kind', 'cancelled', 'run_number', x.number,
                              'on', (x.cancelled_at at time zone 'Europe/Paris')::date)
    from runs x
    where x.status = 'cancelled' and x.cancelled_at > v_from and x.cancelled_at <= r.known_at
      and not exists (select 1 from bk b where b.run_id = x.id and b.kind = 'unplanned_payout'
                        and b.run_cancelled_at <= b.posted_at)
    union all
    -- an unplanned booking of a transfer of the chain: after the run's cancellation, or executed again — with its rank
    -- among the chain's executions and (executed again) the planned debit it repeats
    select b.effective_date, b.run_number, case when z.after_cancellation then 4 else 5 end, b.posted_at, b.entry_id,
           case when z.after_cancellation
                then jsonb_build_object('kind', 'executed_after_cancellation', 'run_number', b.run_number,
                                        'cancelled_on', (b.run_cancelled_at at time zone 'Europe/Paris')::date,
                                        'unplanned_minor', b.amount_minor::text,
                                        'advance_minor', coalesce(a.amount_minor, 0)::text,
                                        'p_bound', case when a.amount_minor is null then 'amount' else a.p_bound end,
                                        'execution_no', n.execution_no, 'on', b.effective_date, 'here', h.here)
                else jsonb_build_object('kind', 'debited_again', 'run_number', b.run_number,
                                        'unplanned_minor', b.amount_minor::text,
                                        'advance_minor', coalesce(a.amount_minor, 0)::text,
                                        'p_bound', case when a.amount_minor is null then 'amount' else a.p_bound end,
                                        'execution_no', n.execution_no, 'debited_on', p.debited_on,
                                        'before_debit', coalesce(n.execution_no < p.execution_no, false),
                                        'on', b.effective_date, 'here', h.here) end
    from bk b
    cross join lateral (select b.run_status = 'cancelled' and b.run_cancelled_at <= b.posted_at as after_cancellation) z
    left join lateral (select q.amount_minor, q.p_bound from public.client_advance q
                       where q.cause_entry_id = b.entry_id and q.cause = 'double_payout' offset 0) a on true
    left join lateral (select y.execution_no from xn y where y.entry_id = b.entry_id) n on true
    left join lateral (select y.debited_on, y.execution_no from pd y where y.run_id = b.run_id) p on true
    cross join lateral (select exists (select 1 from (select q.run_id from public.remittance_line q
                                                      where q.ledger_entry_id = b.entry_id and not q.released
                                                      offset 0) l
                                       where l.run_id = r.id) as here) h
    where b.kind = 'unplanned_payout'
    union all
    -- the return of such a booking (critic L4): its advance reversed, P owed again
    select b.effective_date, b.run_number, 6, b.posted_at, b.entry_id,
           jsonb_build_object('kind', 'unplanned_returned', 'run_number', b.run_number,
                              'unplanned_minor', u.amount_minor::text, 'advance_minor', coalesce(a.amount_minor, 0)::text,
                              'owed_minor', (u.amount_minor - coalesce(a.amount_minor, 0))::text,
                              'executed_on', u.effective_date, 'on', b.effective_date, 'here', h.here)
    from bk b
    cross join lateral (select q.amount_minor, e.effective_date
                        from (select y.amount_minor from public.bank_line_booking y
                              where y.entry_id = b.reverses_entry_id and y.kind = 'unplanned_payout' offset 0) q
                        cross join lateral (select y.effective_date from public.ledger_entry y
                                            where y.id = b.reverses_entry_id offset 0) e) u
    left join lateral (select q.amount_minor from public.client_advance q
                       where q.cause_entry_id = b.reverses_entry_id and q.cause = 'double_payout' offset 0) a on true
    cross join lateral (select exists (select 1 from (select q.run_id from public.remittance_line q
                                                      where q.ledger_entry_id = b.entry_id and not q.released
                                                      offset 0) l
                                       where l.run_id = r.id) as here) h
    where b.kind = 'unplanned_payout_returned'
    union all
    -- (critic L16) an unplanned payout to the client with no transfer of ours (S13, S07); ranked with the other
    -- unplanned executions (review round 1 legal-texts-2: before every return, its own included, on the same day)
    select e.effective_date, null::text, 5, e.posted_at, k.entry_id,
           jsonb_build_object('kind', 'executed_outside', 'run_number', null, 'amount_minor', k.amount_minor::text,
                              'advance_minor', coalesce(a.amount_minor, 0)::text,
                              'iban_last4', right(l.counterparty_iban, 4), 'on', e.effective_date, 'here', h.here)
    from (select q.entry_id, q.amount_minor, q.bank_transaction_id from public.bank_line_booking q
          where q.organization_id = r.organization_id and q.kind = 'unplanned_payout' and q.transfer_id is null
          offset 0) k
    cross join lateral (select q.posted_at, q.effective_date, q.client_organization_id from public.ledger_entry q
                        where q.id = k.entry_id offset 0) e
    cross join lateral (select q.counterparty_iban, q.currency from public.bank_transaction q
                        where q.id = k.bank_transaction_id offset 0) l
    left join lateral (select q.amount_minor from public.client_advance q
                       where q.cause_entry_id = k.entry_id and q.cause = 'double_payout' offset 0) a on true
    cross join lateral (select exists (select 1 from (select q.run_id from public.remittance_line q
                                                      where q.ledger_entry_id = k.entry_id and not q.released
                                                      offset 0) z
                                       where z.run_id = r.id) as here) h
    where e.client_organization_id = r.client_organization_id and l.currency = r.currency
      and e.posted_at > v_from and e.posted_at <= r.known_at
    union all
    -- its return (the servicer's unplanned returns, bank_line_booking_unplanned_return_idx)
    select e.effective_date, null::text, 6, e.posted_at, k.entry_id,
           jsonb_build_object('kind', 'unplanned_returned', 'run_number', null,
                              'unplanned_minor', u.amount_minor::text, 'advance_minor', coalesce(a.amount_minor, 0)::text,
                              'owed_minor', (u.amount_minor - coalesce(a.amount_minor, 0))::text,
                              'executed_on', u.effective_date, 'on', e.effective_date, 'here', h.here)
    from (select q.entry_id, q.kind, q.transfer_id, q.bank_transaction_id from public.bank_line_booking q
          where q.organization_id = r.organization_id
            and q.kind in ('unplanned_payout_returned', 'unplanned_sweep_returned') offset 0) k
    cross join lateral (select q.posted_at, q.effective_date, q.reverses_entry_id, q.client_organization_id
                        from public.ledger_entry q where q.id = k.entry_id offset 0) e
    cross join lateral (select q.currency from public.bank_transaction q where q.id = k.bank_transaction_id offset 0) l
    cross join lateral (select q.amount_minor, y.effective_date
                        from (select z.amount_minor from public.bank_line_booking z
                              where z.entry_id = e.reverses_entry_id and z.kind = 'unplanned_payout'
                                and z.transfer_id is null offset 0) q
                        cross join lateral (select z.effective_date from public.ledger_entry z
                                            where z.id = e.reverses_entry_id offset 0) y) u
    left join lateral (select q.amount_minor from public.client_advance q
                       where q.cause_entry_id = e.reverses_entry_id and q.cause = 'double_payout' offset 0) a on true
    cross join lateral (select exists (select 1 from (select q.run_id from public.remittance_line q
                                                      where q.ledger_entry_id = k.entry_id and not q.released
                                                      offset 0) z
                                       where z.run_id = r.id) as here) h
    where k.kind = 'unplanned_payout_returned' and k.transfer_id is null
      and e.client_organization_id = r.client_organization_id and l.currency = r.currency
      and e.posted_at > v_from and e.posted_at <= r.known_at)
  select coalesce(jsonb_agg(v.event order by v.on_date, v.run_number nulls last, v.rank, v.posted, v.tie), '[]')
  into v_events from ev v;

  return jsonb_build_object(
    'since', case when v_prev.id is not null
                  then jsonb_build_object('number', v_prev.number,
                                          'known_at', to_char(v_prev.known_at at time zone 'UTC',
                                                              'YYYY-MM-DD"T"HH24:MI:SS"Z"')) end,
    'events', v_events);
end;
$$;

------------------------------------------------------------------------------------------
-- The statement's payload (redefined from 20261117100000)
------------------------------------------------------------------------------------------

-- private.remittance_statement_build, redefined from 20261117100000 (same signature and settings: SECURITY DEFINER,
-- search_path '', enable_hashjoin and enable_mergejoin off; its grants restated below). M2c-6b-2d (plan §5): the payload
-- drops `follow_up` and adds `previous_payouts` (private.remittance_statement_previous_payouts, as of K); a late line
-- whose item an unplanned payout paid, as of K, carries the amount attributed and the booking's date
-- (paid_by_unplanned_minor, paid_by_unplanned_on: the two line columns appended) and takes late_cause
-- `paid_by_unplanned` first when that amount is all of the line (review round 1 legal-texts-3). Nothing else changes.
create or replace function private.remittance_statement_build(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare
  r public.remittance_run;
  v_cancelled boolean;
  v_exp integer;
  v_lines jsonb;
  v_files jsonb;
  v_natures jsonb;
  v_totals jsonb;
  v_docs jsonb;
  v_earlier jsonb;
  v_mandates jsonb;
  v_payout jsonb;
  v_suivi jsonb;
  v_held jsonb;
  v_refunded jsonb;
  v_position jsonb;
  v_prev public.remittance_run;
  v_k_day date;
  v_issue date;
  v_payload jsonb;
  v_receivable bigint;
  v_advances bigint;
  v_docs_ttc bigint;
  v_issuer jsonb;
  v_client jsonb;
begin
  select * into r from public.remittance_run where id = p_run_id for share;
  if not found or r.approved_at is null then
    raise exception 'statement of %: not an approved run', p_run_id using errcode = 'check_violation';
  end if;
  v_cancelled := r.status = 'cancelled';
  select c.minor_exponent into v_exp from public.currency c where c.code = r.currency;
  v_k_day := (r.known_at at time zone 'Europe/Paris')::date;
  v_issue := (r.approved_at at time zone 'Europe/Paris')::date;

  -- the run's lines, then the earlier lines whose commission this run priced (amount 0: remitted then)
  drop table if exists pg_temp._rd_line;
  create temp table _rd_line on commit drop as
  select 0 as section, l.line_no, l.line_no as source_line_no, null::text as from_run, l.kind, l.ledger_entry_id,
         l.account_id, l.portfolio_id, l.mandate_id, l.payment_id, l.encaissement_date, l.effective_date, l.deadline,
         l.amount_minor, l.commission_minor, l.commission_state, l.parts, l.invoice_id, l.posted_at,
         l.latest_execution_date, l.unmeetable
  from public.remittance_line l where l.run_id = r.id
  union all
  select 1, 0, l.line_no, (select x.number from public.remittance_run x where x.id = l.run_id), l.kind,
         l.ledger_entry_id, l.account_id, l.portfolio_id, l.mandate_id, l.payment_id, l.encaissement_date,
         l.effective_date, l.deadline, 0, rp.commission_minor, rp.commission_state, rp.parts, rp.invoice_id,
         l.posted_at, l.latest_execution_date, l.unmeetable
  from public.remittance_line_repricing rp
  cross join lateral (select y.* from public.remittance_line y where y.run_id = rp.run_id and y.line_no = rp.line_no
                      offset 0) l
  where rp.pricing_run_id = r.id;

  drop table if exists pg_temp._rd_fact;
  create temp table _rd_fact on commit drop as
  select x.section, x.line_no, x.source_line_no, x.from_run, x.kind, x.account_id, x.amount_minor, x.commission_minor,
         a.external_ref as file, d.name as debtor, m.reference as mandate, pf.name as portfolio,
         coalesce(it.items, '[]'::jsonb) as items, coalesce(it.components, '[]'::jsonb) as components,
         -- M2c-6b-2b (review LT-2, critic L4): the item an unplanned payout's return re-owes is marked `unplanned`: the
         -- renderer words it « Virement exécuté hors reversement revenu », never « Virement revenu impayé — reversé à
         -- nouveau »
         case when un.unplanned then 'unplanned' else n.reason end as nature_reason,
         x.encaissement_date, x.effective_date, x.deadline, x.commission_state,
         coalesce(pt.rules, '[]'::jsonb) as rules, coalesce(pt.rates, '[]'::jsonb) as rates,
         coalesce(pt.basis, 0) as basis, coalesce(inv.number, cn.number) as invoice, rc.number as receipt,
         la.ledger_entry_id is not null as late, lc.cause as late_cause,
         -- M2c-6b-2d (critic L9, critic2 ML-9): what unplanned payouts paid of a late line, as of K, and when
         pu.paid_minor as paid_by_unplanned_minor, pu.paid_on as paid_by_unplanned_on
  from pg_temp._rd_line x
  left join lateral (select q.external_ref from public.account q where q.id = x.account_id offset 0) a on true
  left join lateral (
    select (array_agg(pa.display_name order by pa.display_name, pa.id))[1] as name
    from public.account_party ap
    cross join lateral (select q.id, q.display_name from public.party q where q.id = ap.party_id offset 0) pa
    where ap.account_id = x.account_id and ap.role = 'borrower') d on true
  left join lateral (select q.reference from public.mandate q where q.id = x.mandate_id offset 0) m on true
  left join lateral (select q.name from public.portfolio q where q.id = x.portfolio_id offset 0) pf on true
  -- the items and components the entry moved (its 1100 postings), each item once, in a total order
  left join lateral (
    with y as (
      select q.claim_item_id, q.component
      from public.ledger_posting lp
      cross join lateral (select v.claim_item_id, v.component from public.ledger_account v
                          where v.id = lp.ledger_account_id and v.book = 'debtor_receivable' offset 0) q
      where lp.entry_id = x.ledger_entry_id)
    select (select jsonb_agg(jsonb_build_array(z.kind, z.ref) order by z.due_date nulls last, z.ref, z.kind, z.id)
            from (select distinct ci.id, ci.kind, ci.ref, ci.due_date
                  from y cross join lateral (select c.id, c.kind, c.ref, c.due_date from public.claim_item c
                                             where c.id = y.claim_item_id offset 0) ci) z) as items,
           (select jsonb_agg(z.component order by z.sort_order)
            from (select distinct y.component, lc.sort_order
                  from y cross join lateral (select c.sort_order from public.ledger_component c
                                             where c.code = y.component offset 0) lc) z) as components) it on true
  left join lateral (select q.reason from public.client_notification q where q.ledger_entry_id = x.ledger_entry_id
                     offset 0) n on true
  -- M2c-6b-2b (review LT-2): a payout_returned line reversing an unplanned remittance (the reversed entry's booking is an
  -- unplanned_payout), by key: the line's entry, then the reversed entry's booking by its entry
  left join lateral (select exists (select 1 from public.bank_line_booking k
                                    where k.entry_id = e.reverses_entry_id and k.kind = 'unplanned_payout') as unplanned
                     from (select q.reverses_entry_id from public.ledger_entry q where q.id = x.ledger_entry_id
                           offset 0) e
                     where x.kind = 'payout_returned') un on true
  -- the rules and band rates of the line's parts, and the basis they priced
  left join lateral (
    select (select jsonb_agg(distinct p ->> 'label_fr') from jsonb_array_elements(x.parts) p
            where p ->> 'label_fr' is not null) as rules,
           (select jsonb_agg(distinct t ->> 0) from jsonb_array_elements(x.parts) p
            cross join lateral jsonb_array_elements(coalesce(p -> 'tiers', '[]')) t) as rates,
           (select sum((p ->> 'basis')::bigint) from jsonb_array_elements(x.parts) p) as basis) pt on true
  left join lateral (select q.number from public.commission_invoice q where q.id = x.invoice_id offset 0) inv on true
  -- a reversal's negative commission is on the run's credit note, which names its entry (review figures#5)
  left join lateral (select q.number
                     from public.commission_credit_alloc ca
                     cross join lateral (select y.number, y.seq from public.commission_invoice y
                                         where y.id = ca.credit_note_id and y.run_id = r.id
                                           and y.kind = 'credit_note' and y.reason = 'commission' offset 0) q
                     where x.invoice_id is null and ca.entry_id = x.ledger_entry_id
                     order by q.seq limit 1) cn on true
  left join lateral (select q.number from public.receipt q where q.payment_id = x.payment_id
                     order by q.version limit 1) rc on true
  left join lateral (select q.ledger_entry_id from public.remittance_late_approval q
                     where q.run_id = r.id and q.ledger_entry_id = x.ledger_entry_id and x.section = 0
                     offset 0) la on true
  -- M2c-6b-2d (critic L9, critic2 ML-9; Q15's default: the item keeps its own clock): a late line an unplanned payout's
  -- P paid (private.unplanned_paid_item) — its booking posted at or before K and not reversed by then — states that
  -- payout's date and the amount attributed (all of the line, or part of it). Read for the late lines only, by key
  -- (private.remittance_statement_paid_by_unplanned). `offset 0` keeps the subquery whole: pulled up, the late test
  -- would filter the helper's rows after calling it for every line (50 000 calls for a run with none late, 0.7 s);
  -- kept, it is a one-time filter and the helper is never called for a line that is not late
  left join lateral (select u.paid_minor, u.paid_on
                     from private.remittance_statement_paid_by_unplanned(x.ledger_entry_id, r.known_at) u
                     where la.ledger_entry_id is not null
                     offset 0) pu on true
  -- why a line was paid after its latest execution date, from the data (review legal#6; the approver's reason stays
  -- in the back office): a payout of it that came back unpaid, paid again (M2c-6b-1 review round 2, L1: the line keeps
  -- the date of the run line it came from, K2), the mandate's delay could not be met (held to one month, R124-6), the
  -- collection reached the queue after its J-5 date (the deadline guard's margin, 5 business days before its latest
  -- execution date), or the approval came late
  -- (M2c-6b-2b, review LT-2: the item an unplanned payout's return re-owes, held to the date of the items its P paid,
  -- critic2 ML-2 — the unplanned payout came back unpaid, never « reversé à nouveau »)
  -- (M2c-6b-2d, critic L9: an item an unplanned payout paid, as of K — first: the date it was paid is the fact; review
  -- round 1 legal-texts-3: only when it paid all of the line — one it paid in part keeps its own cause for the rest,
  -- the attribution carried beside it in paid_by_unplanned_minor / _on)
  left join lateral (select case when pu.paid_minor > 0 and pu.paid_minor >= x.amount_minor then 'paid_by_unplanned'
                                 when x.kind = 'payout_returned' and un.unplanned then 'unplanned_payout_returned'
                                 when x.kind = 'payout_returned' then 'payout_returned'
                                 when x.unmeetable then 'unmeetable'
                                 when private.business_days_between((x.posted_at at time zone 'Europe/Paris')::date,
                                                                    x.latest_execution_date) < 5
                                 then 'identified_late'
                                 else 'approved_late' end as cause
                     where la.ledger_entry_id is not null offset 0) lc on true;

  select coalesce(jsonb_agg(jsonb_build_array(
           f.source_line_no, f.mandate, f.portfolio, f.file, f.debtor, f.items, f.components, f.kind, f.nature_reason,
           f.from_run, f.encaissement_date, f.effective_date, f.deadline, f.amount_minor::text, f.rules, f.rates,
           f.basis::text, f.commission_minor::text, f.commission_state, f.invoice, f.receipt, f.late, f.late_cause,
           f.paid_by_unplanned_minor::text, f.paid_by_unplanned_on)
           order by f.section, f.from_run, f.source_line_no), '[]')
  into v_lines from pg_temp._rd_fact f;

  -- per file (the PDF's table): the run's lines and the commission priced on the file in this run (a file with only
  -- earlier lines priced now has 0 lines: counted apart in the totals, review tests-ui#4)
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', g.file, 'debtor', g.debtor, 'lines', g.n::text, 'amount_minor', g.amount::text,
           'commission_minor', g.commission::text, 'late', g.late::text)
           order by g.file nulls last, g.account_id), '[]')
  into v_files
  from (select f.account_id, min(f.file) as file, min(f.debtor) as debtor,
               count(*) filter (where f.section = 0) as n, sum(f.amount_minor) as amount,
               sum(f.commission_minor) as commission, count(*) filter (where f.late) as late
        from pg_temp._rd_fact f group by f.account_id) g;

  -- per nature (the run's lines by kind and reason; the earlier lines priced now as one row)
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', n.kind, 'reason', n.reason, 'count', n.c::text, 'amount_minor', n.amount::text,
           'commission_minor', n.commission::text) order by n.section, n.kind, n.reason nulls first), '[]')
  into v_natures
  from (select f.section, case when f.section = 1 then 'repricing' else f.kind end as kind,
               case when f.section = 0 and f.kind in ('forward', 'allocation_reversal', 'forward_reversal')
                    then f.nature_reason
                    -- M2c-6b-2b (review LT-2): the unplanned returns' items apart from the planned returns'
                    when f.section = 0 and f.kind = 'payout_returned' and f.nature_reason = 'unplanned'
                    then 'unplanned' end as reason,
               count(*) as c, sum(f.amount_minor) as amount, sum(f.commission_minor) as commission
        from pg_temp._rd_fact f group by 1, 2, 3) n;

  select jsonb_build_object(
           'line_count', count(*) filter (where f.section = 0),
           'repriced_count', count(*) filter (where f.section = 1),
           'file_count', count(distinct f.account_id) filter (where f.section = 0),
           'repriced_only_file_count',
             (select count(*) from (select g.account_id from pg_temp._rd_fact g group by g.account_id
                                    having bool_and(g.section = 1)) o),
           'collected_minor', coalesce(sum(f.amount_minor) filter (where f.amount_minor > 0), 0)::text,
           'reversed_minor', coalesce(sum(f.amount_minor) filter (where f.amount_minor < 0), 0)::text,
           'commission_ht_minor', coalesce(sum(f.commission_minor), 0)::text,
           'late_count', count(*) filter (where f.late))
         || jsonb_build_object(
           'gross_minor', r.gross_minor::text,
           'invoice_ht_minor', coalesce(r.invoice_ht_minor, 0)::text,
           'invoice_vat_minor', coalesce(r.invoice_vat_minor, 0)::text,
           'invoice_ttc_minor', coalesce(r.invoice_ttc_minor, 0)::text,
           'credit_ht_minor', coalesce(r.credit_ht_minor, 0)::text,
           'credit_vat_minor', coalesce(r.credit_vat_minor, 0)::text,
           'credit_ttc_minor', coalesce(r.credit_ttc_minor, 0)::text,
           'commission_taken_minor', coalesce(r.commission_taken_minor, 0)::text,
           'advance_recovered_minor', coalesce(r.advance_recovered_minor, 0)::text,
           'refund_minor', coalesce(r.refund_minor, 0)::text,
           'settlement_minor', r.settlement_minor::text,
           'net_minor', r.net_minor::text)
         -- M2c-5b: what the run's credits absorbed of manual credit notes' waivers (lines with no document: a
         -- manual credit note credited it already), named with the invoices it was on and the manual credit notes
         -- that waived it (review legal#4: « avoir n° … rectifiant la facture … », followed back through a
         -- cancellation's corrective invoice); absent when nothing was (payloads drawn before keep their bytes)
         || coalesce((select jsonb_build_object('waived_absorbed_minor', (-sum(w.amount_minor))::text,
                                                'waived_absorbed_invoices',
                                                jsonb_agg(distinct i.number order by i.number),
                                                'waived_absorbed_credit_notes',
                                                private.absorbed_credit_notes(r.id))
                      from public.commission_waiver w
                      cross join lateral (select q.number from public.commission_invoice q
                                          where q.id = w.invoice_id offset 0) i
                      where w.run_id = r.id and w.cause = 'absorbed'
                      having count(*) > 0), '{}'::jsonb)
  into v_totals from pg_temp._rd_fact f;

  -- the run's documents (its approval's; a cancellation's too when the run was cancelled before this was drawn), each
  -- with the invoices it corrects, the credit notes of the cancellation that annul it, and what this payout sets off
  -- (nothing once cancelled)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'kind', i.kind, 'number', i.number, 'issue_date', i.issue_date, 'reason', i.reason,
           'mandate', (select m.reference from public.mandate m where m.id = i.mandate_id),
           'ht_minor', i.ht_minor::text, 'vat_minor', i.vat_minor::text, 'ttc_minor', i.ttc_minor::text,
           'vat_rate', i.vat_rate::text, 'settlement', i.settlement, 'due_date', i.due_date,
           'clause_ref', i.payload #>> '{settlement,clause_ref}',
           'payment_reference', i.payload -> 'payment_reference',
           'own_account', case when i.payload -> 'own_account' is not null
                               and jsonb_typeof(i.payload -> 'own_account') = 'object'
                               then jsonb_build_object('iban', private.iban_masked(i.payload #>> '{own_account,iban}'),
                                                       'holder', i.payload #>> '{own_account,holder}') end,
           'corrects', (select coalesce(jsonb_agg(jsonb_build_object('number', o.number, 'issue_date', o.issue_date,
                                                                     'ht_minor', c.ht_minor::text,
                                                                     'vat_minor', c.vat_minor::text)
                                                  order by o.seq), '[]')
                        from public.commission_credit_correction c
                        cross join lateral (select q.number, q.issue_date, q.seq from public.commission_invoice q
                                            where q.id = c.original_invoice_id offset 0) o
                        where c.credit_note_id = i.id),
           'cancelled_by', (select coalesce(jsonb_agg(jsonb_build_object('number', o.number,
                                                                         'issue_date', o.issue_date)
                                                      order by o.seq), '[]')
                            from public.commission_credit_correction c
                            cross join lateral (select q.number, q.issue_date, q.seq from public.commission_invoice q
                                                where q.id = c.credit_note_id and q.run_id = r.id
                                                  and q.reason = 'run_cancelled' offset 0) o
                            where c.original_invoice_id = i.id),
           'settles_minor', case when v_cancelled then '0'
                                 else (select coalesce(sum((s ->> 'amount')::bigint), 0)::text
                                       from jsonb_array_elements(coalesce(r.settlement_plan -> 'settles', '[]')) s
                                       where s ->> 'document_id' = i.id::text) end)
           order by i.seq), '[]')
  into v_docs
  from public.commission_invoice i where i.run_id = r.id;

  -- what this payout sets off from documents of earlier runs (compensation, a refund owed, an advance); nothing once
  -- the run is cancelled
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', s ->> 'kind', 'document_kind', i.kind, 'number', i.number, 'issue_date', i.issue_date,
           'amount_minor', s ->> 'amount') order by i.seq nulls last, s ->> 'document_id'), '[]')
  into v_earlier
  from jsonb_array_elements(case when v_cancelled then '[]'::jsonb
                                 else coalesce(r.settlement_plan -> 'settles', '[]') end) s
  left join lateral (select q.kind, q.number, q.issue_date, q.seq, q.run_id from public.commission_invoice q
                     where q.id = (s ->> 'document_id')::uuid offset 0) i on true
  where i.run_id is distinct from r.id and (s ->> 'amount')::bigint <> 0;

  -- the mandates the statement covers, with the clause references of their terms on K's day (R124-3 3°, 4°)
  select coalesce(jsonb_agg(jsonb_build_object(
           'reference', m.reference, 'signed_on', m.signed_on,
           'commission_clause_ref', t.commission_clause_ref, 'remittance_clause_ref', t.remittance_clause_ref,
           'netting_clause_ref', t.remittance_terms #>> '{netting,clause_ref}',
           'clawback_clause_ref', t.remittance_terms #>> '{clawback,clause_ref}')
           order by m.reference, m.id), '[]')
  into v_mandates
  from (select distinct x.mandate_id from pg_temp._rd_line x where x.mandate_id is not null
        union select i.mandate_id from public.commission_invoice i where i.run_id = r.id) mm
  cross join lateral (select q.* from public.mandate q where q.id = mm.mandate_id offset 0) m
  left join lateral (select q.commission_clause_ref, q.remittance_clause_ref, q.remittance_terms
                     from public.mandate_terms q
                     where q.mandate_id = m.id and q.valid_from <= v_k_day
                     order by q.valid_from desc limit 1) t on true;

  -- the payout as ordered (never « payé » before the bank's debit: M2c-6 books it)
  select jsonb_build_object('amount_minor', t.amount_minor::text, 'ordered_on', v_issue,
                            'requested_execution_date', t.requested_execution_date,
                            'iban', private.iban_masked(t.payee_iban), 'holder', t.payee_name,
                            'end_to_end_id', t.end_to_end_id, 'status', t.status)
  into v_payout from public.bank_transfer t where t.id = r.transfer_id;

  -- (M2c-6b-2d) « Suivi »: the events of the client's earlier approved runs of the currency posted in the window from
  -- the previous approved run's K to this run's K, as of K (private.remittance_statement_previous_payouts; plan §5).
  -- M2c-5's follow_up (the previous run's current state, not as of K) is dropped.
  v_suivi := private.remittance_statement_previous_payouts(r.id);
  -- the run this one follows (the refunds' window below)
  select * into v_prev from public.remittance_run x where x.id = r.previous_run_id;

  -- money received on the client's files and not remitted, as of K (C. civ. 1993, OQ-40; review figures#2): per file
  -- and reason, what each payment matched to one of them by K still held on 4710 at K — its amount less what its
  -- other entries posted by K moved (allocations, forwards, refunds, returns, and their reversals: a refund that came
  -- back by K is held again, review legal#3). The payments that can have held money at K: those holding some now,
  -- those refunded or returned since K, and those allocated or forwarded since K (their entries are the client's
  -- pending items posted after K). No payer data.
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', h.file, 'reason', h.reason, 'currency', h.currency, 'amount_minor', h.amount::text,
           'first_date', h.first_date, 'last_date', h.last_date, 'count', h.n::text)
           order by h.file, h.reason, h.currency), '[]')
  into v_held
  from (select a.external_ref as file,
               coalesce(p.review_reason, case when p.status in ('refund_pending', 'refunded') then 'refund_pending'
                                              else 'pending' end) as reason,
               p.currency, sum(u.unallocated) as amount, min(p.booking_date) as first_date,
               max(p.booking_date) as last_date, count(*) as n
        from (select distinct c.id
              from (select y.id from public.payment y
                    where y.organization_id = r.organization_id
                      and y.status in ('matched', 'partially_allocated', 'refund_pending')
                      and y.client_organization_id = r.client_organization_id
                    union all
                    select y.id from public.payment y
                    where y.organization_id = r.organization_id and y.status in ('refunded', 'returned')
                      and y.client_organization_id = r.client_organization_id and y.updated_at > r.known_at
                    union all
                    select e.payment_id from private.remittance_pending q
                    cross join lateral (select y.payment_id from public.ledger_entry y where y.id = q.ledger_entry_id
                                        offset 0) e
                    where q.organization_id = r.organization_id
                      and q.client_organization_id = r.client_organization_id
                      and q.posted_at > r.known_at and e.payment_id is not null) c) c
        cross join lateral (select y.* from public.payment y where y.id = c.id offset 0) p
        cross join lateral (
          select (p.amount_minor - coalesce(sum(lp.amount_minor), 0))::bigint as unallocated
          from (select e.id from public.ledger_entry e
                where e.payment_id = p.id and e.entry_type <> 'cash_in' and e.posted_at <= r.known_at offset 0) e
          cross join lateral (select y.amount_minor from public.ledger_posting y
                              where y.entry_id = e.id
                                and (select la.book from public.ledger_account la where la.id = y.ledger_account_id)
                                    = 'unallocated_payment'
                              offset 0) lp) u
        cross join lateral (select q.external_ref from public.account q where q.id = p.account_id offset 0) a
        where p.client_organization_id = r.client_organization_id and p.created_at <= r.known_at
          and p.matched_at <= r.known_at and u.unallocated > 0
        group by 1, 2, 3) h;

  -- refunded to payers between the previous K and this K, and not back by K (a refund that bounced by K is money held
  -- again, above: review legal#3, figures#3)
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', h.file, 'reason', h.reason, 'currency', h.currency, 'amount_minor', h.amount::text,
           'first_date', h.first_date, 'last_date', h.last_date, 'count', h.n::text)
           order by h.file, h.reason, h.currency), '[]')
  into v_refunded
  from (select a.external_ref as file, q.reason_code as reason, q.currency, sum(q.amount_minor) as amount,
               min(q.executed_on) as first_date, max(q.executed_on) as last_date, count(*) as n
        from public.refund_request q
        cross join lateral (select y.account_id, y.client_organization_id from public.payment y
                            where y.id = q.payment_id offset 0) p
        cross join lateral (select y.external_ref from public.account y where y.id = p.account_id offset 0) a
        cross join lateral (select y.posted_at from public.ledger_entry y where y.id = q.cash_out_entry_id offset 0) e
        left join lateral (select y.posted_at from public.ledger_entry y where y.id = q.bounce_entry_id offset 0) b
          on true
        where q.organization_id = r.organization_id and q.status in ('executed', 'bounced')
          and p.client_organization_id = r.client_organization_id
          and e.posted_at <= r.known_at and (v_prev.known_at is null or e.posted_at > v_prev.known_at)
          and (q.status = 'executed' or b.posted_at > r.known_at)
        group by a.external_ref, q.reason_code, q.currency) h;

  -- the position (§10.7): owed to the client at K — every item pending then is this run's (one live run per client
  -- and currency, I14) — and after this payout (still owed once the run is cancelled); what the client owes the
  -- servicer (4111 + 4112) as known at K and after this statement's documents and the settlement at the payout's debit
  -- (none once cancelled: every document of the run counts, the approval's and the cancellation's)
  select coalesce(sum(private.ledger_balance(la.id, '9999-12-31'::date, r.known_at)), 0)
  into v_receivable
  from public.ledger_account la
  where la.organization_id = r.organization_id and la.book = 'commission_receivable'
    and la.client_organization_id = r.client_organization_id and la.currency = r.currency;
  select coalesce(sum(private.ledger_balance(la.id, '9999-12-31'::date, r.known_at)), 0)
  into v_advances
  from public.ledger_account la
  where la.organization_id = r.organization_id and la.book = 'client_advance_receivable'
    and la.client_organization_id = r.client_organization_id and la.currency = r.currency;
  select coalesce(sum(i.ttc_minor), 0) into v_docs_ttc
  from public.commission_invoice i where i.run_id = r.id and (v_cancelled or i.reason <> 'run_cancelled');
  v_position := jsonb_build_object(
    'owed_before_minor', r.gross_minor::text,
    'owed_after_minor', case when v_cancelled then r.gross_minor else 0 end::text,
    'receivable_before_minor', v_receivable::text,
    'receivable_after_minor',
      (v_receivable + v_docs_ttc
       - case when v_cancelled then 0 else coalesce((r.settlement_plan ->> 'dc')::bigint, 0) end)::text,
    'advances_before_minor', v_advances::text,
    'advances_after_minor',
      (v_advances - case when v_cancelled then 0 else coalesce((r.settlement_plan ->> 'da')::bigint, 0) end)::text);

  -- the parties as the run's invoices froze them at approval (review figures#2), else as they stand
  select i.payload -> 'seller', i.payload -> 'buyer' into v_issuer, v_client
  from public.commission_invoice i where i.run_id = r.id and i.reason = 'commission'
  order by i.seq limit 1;

  v_payload := jsonb_build_object(
    'schema', 1,
    'number', r.number,
    'issue_date', v_issue,
    'known_at', to_char(r.known_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'currency', r.currency,
    'exponent', v_exp,
    'status', r.status,
    'cancelled_on', case when v_cancelled then (r.cancelled_at at time zone 'Europe/Paris')::date end,
    -- N = 0: the settlement was posted at approval, nothing is transferred (review legal#5)
    'settled_on', case when r.status = 'booked' and r.transfer_id is null then r.booked_on end,
    'issuer', coalesce(v_issuer, private.invoice_party(r.organization_id)),
    'client', coalesce(v_client, private.invoice_party(r.client_organization_id)),
    'mandates', v_mandates,
    'service_period', jsonb_build_object('from', r.service_from, 'to', r.service_to),
    'totals', v_totals,
    'files', v_files,
    'natures', v_natures,
    'line_columns', private.remittance_statement_line_columns(),
    'lines', v_lines,
    'documents', v_docs,
    'earlier_settled', v_earlier,
    'payout', v_payout,
    'requested_execution_date', r.requested_execution_date,
    'previous_payouts', v_suivi,
    'not_remitted', jsonb_build_object('held', v_held, 'refunded', v_refunded),
    'position', v_position);

  return v_payload;
end;
$$;

------------------------------------------------------------------------------------------
-- The record step (redefined from 20261113090000, its only definition: one guard added)
------------------------------------------------------------------------------------------

-- Records what the job rendered (pg_temp._rd_statement_files, _rd_invoice_pdf, filled by the worker after its
-- uploads): one document per file (private bucket `documents`, SHA-256), the statement rows with the payload prepared
-- in this transaction, the invoice document rows; the work done leaves the queue and the work tables (the worker
-- records each statement and each chunk of invoices under its own savepoint: review perf#2). Every prepared statement
-- was rendered, nothing else. Returns {statements, invoices, more} (more: documents due now, not waiting for a retry).
-- Redefined from 20261113090000 (same signature and settings: SECURITY DEFINER, search_path ''; its grants restated
-- below). Review M2c-6b-2d round 1 (SR-2): a statement drawn by a template other than `releve-reversement-fr-3` is
-- refused (the payload changed shape: `follow_up` dropped, `previous_payouts` added, two line columns appended, and a
-- template drawn before cannot tell). Nothing else changes.
create or replace function private.remittance_documents_record(p_organization_id uuid, p_statement_template text,
                                                              p_invoice_template text, p_renderer_version text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bad text;
  v_s integer;
  v_i integer;
begin
  -- review M2c-6b-2d round 1 (SR-2): this payload's « Suivi » (`previous_payouts`, line columns appended) is drawn by
  -- `releve-reversement-fr-3` alone; a worker of an older template (deployed after this migration) would store a
  -- statement with a false « Suivi » forever (stored statements are never drawn again). Refused inside the item's
  -- savepoint: the attempt is recorded failed and retried until the new worker draws it. Invoices are unaffected.
  if p_statement_template is distinct from 'releve-reversement-fr-3'
     and exists (select 1 from pg_temp._rd_statement) then
    raise exception 'statements drawn by template %: this payload is drawn by releve-reversement-fr-3 only',
      p_statement_template using errcode = 'check_violation';
  end if;
  select min(coalesce(s.run_id, f.run_id)::text) into v_bad
  from pg_temp._rd_statement s full join pg_temp._rd_statement_files f on f.run_id = s.run_id
  where s.run_id is null or f.run_id is null;
  if v_bad is not null then
    raise exception 'statement of run %: prepared and rendered statements differ', v_bad
      using errcode = 'check_violation';
  end if;

  drop table if exists pg_temp._rd_new_statement;
  create temp table _rd_new_statement on commit drop as
  select r.id as run_id, r.organization_id, r.client_organization_id, r.currency, r.number, r.known_at,
         (r.approved_at at time zone 'Europe/Paris')::date as issue_date, s.payload, s.payload_sha256, s.line_count,
         s.file_count, f.pdf_sha256, f.csv_sha256, gen_random_uuid() as pdf_id, gen_random_uuid() as csv_id,
         private.remittance_statement_path(r.organization_id, r.client_organization_id, r.number) as path
  from pg_temp._rd_statement s
  join pg_temp._rd_statement_files f on f.run_id = s.run_id
  cross join lateral (select x.* from public.remittance_run x where x.id = s.run_id offset 0) r
  where r.organization_id = p_organization_id;
  if (select count(*) from pg_temp._rd_new_statement) <> (select count(*) from pg_temp._rd_statement) then
    raise exception 'statements: a run of another servicer' using errcode = 'check_violation';
  end if;
  insert into public.document (id, organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                               mime_type, file_name)
  select n.pdf_id, n.organization_id, n.client_organization_id, 'remittance_statement_pdf', 'documents',
         n.path || '.pdf', n.pdf_sha256, 'application/pdf', n.number || '.pdf'
  from pg_temp._rd_new_statement n
  union all
  select n.csv_id, n.organization_id, n.client_organization_id, 'remittance_statement_csv', 'documents',
         n.path || '.csv', n.csv_sha256, 'text/csv', n.number || '.csv'
  from pg_temp._rd_new_statement n;
  insert into public.remittance_statement (run_id, organization_id, client_organization_id, currency, number,
                                           issue_date, known_at, line_count, file_count, gross_minor, net_minor,
                                           drawn_status, payload, payload_sha256, template_version, renderer_version,
                                           pdf_document_id, pdf_sha256, csv_document_id, csv_sha256)
  select n.run_id, n.organization_id, n.client_organization_id, n.currency, n.number, n.issue_date, n.known_at,
         n.line_count, n.file_count, (n.payload #>> '{totals,gross_minor}')::bigint,
         (n.payload #>> '{totals,net_minor}')::bigint, n.payload ->> 'status', n.payload, n.payload_sha256,
         p_statement_template, p_renderer_version, n.pdf_id, n.pdf_sha256, n.csv_id, n.csv_sha256
  from pg_temp._rd_new_statement n;
  get diagnostics v_s = row_count;

  drop table if exists pg_temp._rd_new_invoice;
  create temp table _rd_new_invoice on commit drop as
  select i.id as invoice_id, i.organization_id, i.client_organization_id, i.number, f.pdf_sha256,
         gen_random_uuid() as document_id,
         private.commission_invoice_path(i.organization_id, i.client_organization_id, i.year, i.number) as path,
         nullif(btrim(coalesce(i.payload #>> '{buyer,invoice_acceptance_ref}', '')), '') is not null as electronic
  from pg_temp._rd_invoice_pdf f
  cross join lateral (select x.* from public.commission_invoice x where x.id = f.invoice_id offset 0) i
  where i.organization_id = p_organization_id;
  if (select count(*) from pg_temp._rd_new_invoice) <> (select count(*) from pg_temp._rd_invoice_pdf) then
    raise exception 'invoice documents: an invoice of another servicer, or unknown' using errcode = 'check_violation';
  end if;
  insert into public.document (id, organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                               mime_type, file_name)
  select n.document_id, n.organization_id, n.client_organization_id, 'commission_invoice_pdf', 'documents', n.path,
         n.pdf_sha256, 'application/pdf', n.number || '.pdf'
  from pg_temp._rd_new_invoice n;
  insert into public.commission_invoice_document (invoice_id, organization_id, client_organization_id, document_id,
                                                  pdf_sha256, template_version, renderer_version, electronic)
  select n.invoice_id, n.organization_id, n.client_organization_id, n.document_id, n.pdf_sha256, p_invoice_template,
         p_renderer_version, n.electronic
  from pg_temp._rd_new_invoice n;
  get diagnostics v_i = row_count;

  delete from private.remittance_document_todo t
  where (t.kind = 'statement' and t.ref_id in (select n.run_id from pg_temp._rd_new_statement n))
     or (t.kind = 'invoice' and t.ref_id in (select n.invoice_id from pg_temp._rd_new_invoice n));
  delete from pg_temp._rd_statement;
  delete from pg_temp._rd_statement_files;
  delete from pg_temp._rd_invoice_pdf;
  return jsonb_build_object('statements', v_s, 'invoices', v_i,
                            'more', private.remittance_documents_due(p_organization_id));
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new ones internal)
------------------------------------------------------------------------------------------

-- critic2 CSO2-11: the new internals (PostgreSQL grants EXECUTE to PUBLIC by default); only the statement build calls
-- them (SECURITY DEFINER, as its owner)
revoke execute on function private.remittance_statement_previous_payouts(uuid),
  private.remittance_statement_paid_by_unplanned(uuid, timestamptz)
  from public, anon, authenticated, service_role;
-- the redefined ones, as granted by 20261113090000 (the line columns: internal) and 20261117100000 (the build: the
-- documents job's)
revoke execute on function private.remittance_statement_line_columns() from public, anon, authenticated;
revoke execute on function private.remittance_statement_build(uuid) from public, anon, authenticated;
grant execute on function private.remittance_statement_build(uuid) to service_role;
-- the record step, as 20261113090000 granted it (the documents job's)
revoke execute on function private.remittance_documents_record(uuid, text, text, text) from public, anon, authenticated;
grant execute on function private.remittance_documents_record(uuid, text, text, text) to service_role;
