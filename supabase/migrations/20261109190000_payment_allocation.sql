-- M2b-4 (M2-09, data half of M2-11): allocation — which debts each payment pays, in the legal order.
-- Design: docs/design/m2b-payments.md §6 (allocation_policy, client_notification), §7 (payment states), §8 (postings,
-- worked example, waterfall, job), §9 (commands), §12 (pages); decisions: docs/adr/0013-payments-allocation-client-money.md
-- (founder #4–#12, #16–#18; M2b-4 addendum). Forward-only: nothing of 20261109090000 / 120000 / 150000 is edited;
-- private.regate_account and public.payment_queue are redefined.
--
-- What changes for money:
--   * the allocation job (worker, collectoo_worker.jobs.allocation) computes each ready payment's lines with the pure
--     Python waterfall (designation, then due debts oldest first, pro rata on ties, then debts not yet due; interest
--     first inside each debt) and posts them here, set-based: one `allocation` entry per (payment, file) through
--     private.ledger_post_set (Dr 4710 pool / Cr 4670 client; Cr 1100 per item × component / Dr 3100), re-checked
--     set-based (readiness, gates, money left on the payment, 1343-1) under the allocation lock;
--   * what a payment does not use stays in pooled 4710, tagged by the payment (overpayment: never passed to the
--     client, founder #8); consumer loans keep the seller's unclassified amounts out (founder #6);
--   * ops commands: reverse an allocation (reversal at its date), allocate again or on another file of the same
--     debtor at his written request, release a held payment on the judge's authorisation, forward a payment to the
--     client (recall, before the cut-off, ratification), apply a credit note (netting, compensation invoked: 1347);
--   * the client is told of every allocation, forward, reversal and held payment (client_notification, R124-5).

------------------------------------------------------------------------------------------
-- Payments: a new review reason, the ops decision the allocation job follows next, the job's index
------------------------------------------------------------------------------------------

-- 'allocation_reversed': ops undid an allocation; the payment waits for their next decision (never re-allocated
-- the same way by itself).
alter table public.payment drop constraint payment_review_reason_check,
  add constraint payment_review_reason_check check (review_reason in (
    'no_match', 'ambiguous', 'overpayment', 'account_not_confirmed', 'no_mandate', 'account_closed',
    'currency_mismatch', 'before_servicing_start', 'hold_blocks_allocation', 'nothing_due',
    'credit_note_to_apply', 'partial_return', 'allocation_reversed'));

-- What ops decided for the next allocation of this payment: the gate it may pass (`release`: a judge's authorisation
-- for a held payment, the cut-off checked with the client, a credit note not invoked…), or another file of the same
-- debtor for an overpayment (`account_id`, on his written request: founder #8). Consumed by the allocation job.
alter table public.payment add column allocation_instruction jsonb check (
  allocation_instruction is null
  or (jsonb_typeof(allocation_instruction) = 'object'
      and allocation_instruction ->> 'release' in ('allocation_reversed', 'nothing_due', 'credit_note_to_apply',
                                                   'before_servicing_start', 'hold_blocks_allocation', 'overpayment')));

-- A decision about one file is void once the payment leaves that file.
create or replace function private.payment_instruction_reset()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.account_id is distinct from old.account_id then
    new.allocation_instruction := null;
  end if;
  return new;
end;
$$;
create trigger payment_instruction_reset before update of account_id on public.payment
  for each row execute function private.payment_instruction_reset();
alter table public.payment enable always trigger payment_instruction_reset;

-- The allocation job's targets (ready payments), in processing order, led by the servicer.
create index payment_allocate_idx on public.payment (organization_id, booking_date, id)
  where status in ('matched', 'partially_allocated') and review_reason is null and account_id is not null;
-- « Rapprochés »: every payment with a file and nothing to decide (ready, allocated, forwarded).
create index payment_with_file_idx on public.payment (organization_id, matched_at desc, booking_date, id)
  where account_id is not null and review_reason is null;

------------------------------------------------------------------------------------------
-- Allocation policy (design §6; founder #5): what a client or a portfolio may set. Interest before principal
-- (1343-1), the debtor's designation and due before not due (1342-10) have no column: they cannot be changed
-- (OQ-19). Immutable versions; the most specific scope in force at the effective date wins (portfolio, client,
-- servicer default, then the built-in default: accessories before principal — CALCULATION_RULES, OQ-7 — and
-- unclassified amounts last). Consumer regimes force `held` in the engine (founder #6, OQ-18).
------------------------------------------------------------------------------------------

create table public.allocation_policy (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid references public.organization (id),
  portfolio_id uuid references public.portfolio (id),
  version integer not null check (version >= 1),
  effective_from date not null,
  -- indemnity, charge and cost families (none exists before M3; the B2B €40 is OQ-7)
  accessory_rank text not null check (accessory_rank in ('before_principal', 'after_principal')),
  -- the seller's unclassified amounts (EU 3.11, balancing line)
  unclassified text not null check (unclassified in ('last', 'held')),
  reason text not null check (length(btrim(reason)) between 1 and 2000),
  created_by uuid references public.app_user (id),
  created_at timestamptz not null default now(),
  constraint allocation_policy_scope check (portfolio_id is null or client_organization_id is not null),
  constraint allocation_policy_version_uq unique nulls not distinct (organization_id, client_organization_id,
                                                                     portfolio_id, version)
);
create index allocation_policy_client_idx on public.allocation_policy (client_organization_id);
comment on table public.allocation_policy is
  'Allocation settings a client or portfolio may choose (accessory rank, unclassified amounts). Legal order fixed.';

create or replace function private.allocation_policy_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(n.id::text) into v_bad from new_rows n
  where not exists (select 1 from public.organization o where o.id = n.organization_id and o.kind = 'servicer')
     or (n.client_organization_id is not null and not exists (
           select 1 from public.organization o
           where o.id = n.client_organization_id and o.servicer_organization_id = n.organization_id))
     or (n.portfolio_id is not null and not exists (
           select 1 from public.portfolio p
           where p.id = n.portfolio_id and p.organization_id = n.organization_id
             and p.client_organization_id = n.client_organization_id));
  if v_bad is not null then
    raise exception 'allocation policy %: its client or portfolio is not of this servicer', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger allocation_policy_guard after insert on public.allocation_policy
  referencing new table as new_rows for each statement execute function private.allocation_policy_guard();
alter table public.allocation_policy enable always trigger allocation_policy_guard;
create trigger allocation_policy_append_only before update or delete or truncate on public.allocation_policy
  for each statement execute function private.refuse_change();
alter table public.allocation_policy enable always trigger allocation_policy_append_only;
create trigger allocation_policy_change_log after insert or update or delete on public.allocation_policy
  for each row execute function private.log_change();

------------------------------------------------------------------------------------------
-- Allocation runs (one per job transaction) and the plan of each posted entry (for M3's re-run by date:
-- founder #16; the lines themselves are the entry's postings)
------------------------------------------------------------------------------------------

create table public.allocation_run (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  trigger text not null check (trigger in ('ready', 'continuation')),
  summary jsonb not null default '{}' check (jsonb_typeof(summary) = 'object'),
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
create index allocation_run_org_idx on public.allocation_run (organization_id, started_at desc);
comment on table public.allocation_run is 'One allocation job transaction: what it allocated, held or left (summary).';

create table private.allocation_plan (
  entry_id uuid primary key references public.ledger_entry (id),
  run_id uuid not null references public.allocation_run (id),
  payment_id uuid not null,
  account_id uuid not null,
  effective_date date not null,
  policy jsonb not null check (jsonb_typeof(policy) = 'object'),
  designation jsonb,
  inputs_hash text not null check (inputs_hash ~ '^[0-9a-f]{64}$'),
  engine_version text not null,
  created_at timestamptz not null default now()
);
create index allocation_plan_payment_idx on private.allocation_plan (payment_id);
create trigger allocation_plan_append_only before update or delete or truncate on private.allocation_plan
  for each statement execute function private.refuse_change();
alter table private.allocation_plan enable always trigger allocation_plan_append_only;

------------------------------------------------------------------------------------------
-- Creditor notifications (R124-5, CPCE-06; design §6, §10; founder #17): one row per allocation, forward and
-- allocation reversal entry (unique ledger_entry_id: exactly once), and one per (payment, file) held. Amounts are
-- not copied: the feed (M2b-5) reads them from the entry's postings, which never change. Delivery is M7.
------------------------------------------------------------------------------------------

-- No foreign keys (as ledger_posting): one set-based ALWAYS guard checks every reference against the payment, the
-- entry and the file, whose rows are never deleted once they carry money; five key checks per row cost seconds at 50k.
create table public.client_notification (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  client_organization_id uuid not null,
  portfolio_id uuid,
  account_id uuid,
  payment_id uuid not null,
  ledger_entry_id uuid unique,
  kind text not null check (kind in ('payment_allocated', 'payment_forwarded', 'payment_allocation_reversed',
                                     'payment_held')),
  reason text check (length(btrim(reason)) between 1 and 2000),
  created_at timestamptz not null default now(),
  delivered_at timestamptz,
  constraint client_notification_entry check ((kind = 'payment_held') = (ledger_entry_id is null)),
  constraint client_notification_held check (kind <> 'payment_held' or account_id is not null)
);
create unique index client_notification_held_uq on public.client_notification (payment_id, account_id)
  where kind = 'payment_held';
create index client_notification_client_idx on public.client_notification (client_organization_id, created_at desc);
create index client_notification_payment_idx on public.client_notification (payment_id);
comment on table public.client_notification is
  'R124-5: the client is told of every payment allocated, forwarded, reversed or held for its file (one row each).';

-- Each row says what its entry did, to the entry's client (set-based over the new rows).
create or replace function private.client_notification_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
set enable_bitmapscan = off
as $$
declare v_bad text;
begin
  select min(n.id::text) into v_bad
  from new_rows n
  left join public.payment p on p.id = n.payment_id
  left join public.ledger_entry e on e.id = n.ledger_entry_id
  left join public.ledger_entry t on t.id = e.reverses_entry_id
  left join public.account a on a.id = n.account_id
  where p.id is null or p.organization_id <> n.organization_id
     or (n.ledger_entry_id is not null and e.id is null)
     or (n.portfolio_id is not null and n.account_id is null
         and not exists (select 1 from public.portfolio x where x.id = n.portfolio_id
                           and x.client_organization_id = n.client_organization_id))
     or (n.account_id is not null and (a.id is null or a.organization_id <> n.organization_id
                                       or a.client_organization_id <> n.client_organization_id
                                       or a.portfolio_id is distinct from n.portfolio_id))
     or (n.kind <> 'payment_held' and (e.payment_id is distinct from n.payment_id
                                       or e.client_organization_id is distinct from n.client_organization_id))
     or (n.kind = 'payment_allocated' and (e.entry_type <> 'allocation' or e.account_id is distinct from n.account_id))
     or (n.kind = 'payment_allocation_reversed'
         and (e.entry_type <> 'reversal' or t.entry_type <> 'allocation' or e.account_id is distinct from n.account_id))
     or (n.kind = 'payment_forwarded' and e.entry_type <> 'forward');
  if v_bad is not null then
    raise exception 'client notification %: it does not match its payment, entry or file', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger client_notification_guard after insert on public.client_notification
  referencing new table as new_rows for each statement execute function private.client_notification_guard();
alter table public.client_notification enable always trigger client_notification_guard;

-- Only the delivery time is ever written (once, M7); never deleted.
create or replace function private.client_notification_update_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.id, new.organization_id, new.client_organization_id, new.portfolio_id, new.account_id, new.payment_id,
      new.ledger_entry_id, new.kind, new.reason, new.created_at)
     is distinct from (old.id, old.organization_id, old.client_organization_id, old.portfolio_id, old.account_id,
                       old.payment_id, old.ledger_entry_id, old.kind, old.reason, old.created_at)
     or old.delivered_at is not null or new.delivered_at is null then
    raise exception 'client notification %: only its delivery is recorded, once', old.id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger client_notification_update_guard before update on public.client_notification
  for each row execute function private.client_notification_update_guard();
alter table public.client_notification enable always trigger client_notification_update_guard;
create trigger client_notification_no_delete before delete or truncate on public.client_notification
  for each statement execute function private.refuse_delete();
alter table public.client_notification enable always trigger client_notification_no_delete;

------------------------------------------------------------------------------------------
-- After payment updates (set-based, one firing per statement): a payment newly held for its file tells the client
-- (founder #12, #17); a payment newly ready for allocation queues the allocation job (one message per servicer).
-- Whatever makes a payment ready (a match, a hold lifted, an ops decision) is covered without each command knowing.
------------------------------------------------------------------------------------------

create or replace function private.payment_after_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id, payment_id,
                                          kind, reason)
  select n.organization_id, n.client_organization_id, n.portfolio_id, n.account_id, n.id, 'payment_held',
         'hold_blocks_allocation'
  from new_rows n join old_rows o on o.id = n.id
  where n.review_reason = 'hold_blocks_allocation' and n.account_id is not null
    and (o.review_reason is distinct from 'hold_blocks_allocation' or o.account_id is distinct from n.account_id)
  on conflict (payment_id, account_id) where kind = 'payment_held' do nothing;

  perform pgmq.send('payments', jsonb_build_object('type', 'allocate', 'organization_id', x.organization_id))
  from (select distinct n.organization_id
        from new_rows n join old_rows o on o.id = n.id
        where n.status in ('matched', 'partially_allocated') and n.review_reason is null and n.account_id is not null
          and (o.status, o.review_reason, o.account_id, o.allocation_instruction)
              is distinct from (n.status, n.review_reason, n.account_id, n.allocation_instruction)) x;
  return null;
end;
$$;
create trigger payment_after_update after update on public.payment
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.payment_after_update();
alter table public.payment enable always trigger payment_after_update;

------------------------------------------------------------------------------------------
-- Balances over time (design §2 #6): what a receivable has available from a date on. Index lookups on
-- ledger_posting_balance_idx (a receivable has a handful of dates).
------------------------------------------------------------------------------------------

-- min over t >= p_from of the running balance (the running balance at p_from included).
create or replace function private.receivable_low(p_ledger_account_id uuid, p_from date)
returns bigint
language sql
stable
set search_path = ''
as $$
  select least(coalesce(sum(x.s) filter (where x.d <= p_from), 0), min(x.bal) filter (where x.d > p_from))::bigint
  from (select g.d, g.s, sum(g.s) over (order by g.d) as bal
        from (select q.effective_date as d, sum(q.amount_minor) as s from public.ledger_posting q
              where q.ledger_account_id = p_ledger_account_id group by q.effective_date) g) x;
$$;

-- max over t >= p_from of the running balance (a credit item stays at or below zero: I6).
create or replace function private.receivable_high(p_ledger_account_id uuid, p_from date)
returns bigint
language sql
stable
set search_path = ''
as $$
  select greatest(coalesce(sum(x.s) filter (where x.d <= p_from), 0), max(x.bal) filter (where x.d > p_from))::bigint
  from (select g.d, g.s, sum(g.s) over (order by g.d) as bal
        from (select q.effective_date as d, sum(q.amount_minor) as s from public.ledger_posting q
              where q.ledger_account_id = p_ledger_account_id group by q.effective_date) g) x;
$$;

-- Position of payments from their tagged entries (I5: amount = allocated + unallocated + returned): allocated =
-- allocation and forward entries (net of reversals), returned = cash_out entries (M2b-6). One index lookup per payment
-- (lateral, on ledger_entry_payment_idx): no plan rests on the statistics of entries posted a moment ago.
create or replace function private.payment_positions(p_payment_ids uuid[])
returns table (payment_id uuid, amount_minor bigint, allocated_minor bigint, returned_minor bigint,
               unallocated_minor bigint)
language sql
stable
set search_path = ''
as $$
  select p.id, p.amount_minor, coalesce(s.a, 0)::bigint, coalesce(s.r, 0)::bigint,
         (p.amount_minor - coalesce(s.a, 0) - coalesce(s.r, 0))::bigint
  from (select distinct x from unnest(p_payment_ids) x) ids
  join public.payment p on p.id = ids.x
  left join lateral (
    select sum(lp.amount_minor) filter (where coalesce(t.entry_type, e.entry_type) in ('allocation', 'forward')) as a,
           sum(lp.amount_minor) filter (where coalesce(t.entry_type, e.entry_type) = 'cash_out') as r
    from public.ledger_entry e
    left join public.ledger_entry t on t.id = e.reverses_entry_id
    join public.ledger_posting lp on lp.entry_id = e.id
    join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment'
    where e.payment_id = p.id) s on true;
$$;

------------------------------------------------------------------------------------------
-- Credit notes (founder #7; design §2 #4, §8.1): compensation « s'opère, sous réserve d'être invoquée, à due
-- concurrence, à la date où ses conditions se trouvent réunies » (C. civ. 1347), between debts « certaines, liquides
-- et exigibles » (1347-1); « S'il y a plusieurs dettes compensables, les règles d'imputation des paiements sont
-- transposables » (1347-4). Proposed here, applied by one ops tap (apply_credit_note).
--
-- Per file, the first credit (a principal receivable below zero: credit note, overpaid invoice), oldest first, against
-- the first group of due receivables in the legal order (due date, then issue date; equal ones pro rata, largest
-- remainder, ties by id), dated when both were due (not before servicing started). Principal only (I3; no interest on
-- these items before M3). One proposal per file at a time: the next one shows once this one is applied.
------------------------------------------------------------------------------------------

create or replace function private.credit_note_proposals(p_account_ids uuid[])
returns table (account_id uuid, credit_item_id uuid, netting_date date, target_item_id uuid, amount_minor bigint,
               proposal_key text)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_today date := private.paris_today();
  v_acc uuid;
  v_start date;
  c record;
  v_credit bigint;
begin
  for v_acc in select a.id from public.account a
               where a.id = any (p_account_ids) and a.status <> 'staged' order by a.id loop
    select min(o.valid_from) into v_start from public.claim_ownership_period o where o.account_id = v_acc;
    continue when v_start is null;
    for c in
      select i.id as item_id, i.ref, la.id as la_id, greatest(v_start, coalesce(i.due_date, i.issue_date, v_start)) as d
      from public.claim_item i
      join public.ledger_account la on la.claim_item_id = i.id and la.component = 'principal'
      where i.account_id = v_acc
      order by coalesce(i.due_date, i.issue_date, v_start), i.ref, i.id
    loop
      continue when c.d > v_today;
      -- what can still be netted from the credit: it stays at or below zero from its date on (I6)
      v_credit := -private.receivable_high(c.la_id, c.d);
      continue when v_credit <= 0;
      return query
      with t as (
        select i.id as item_id, i.due_date, i.issue_date, greatest(c.d, coalesce(i.due_date, v_start)) as d,
               private.receivable_low(la.id, greatest(c.d, coalesce(i.due_date, v_start))) as avail
        from public.claim_item i
        join public.ledger_account la on la.claim_item_id = i.id and la.component = 'principal'
        where i.account_id = v_acc and i.id <> c.item_id and (i.due_date is null or i.due_date <= v_today)
      ), g as (
        select x.* from (select t.*, dense_rank() over (order by t.due_date is null, t.due_date,
                                                                   t.issue_date is null, t.issue_date) as rk
                         from t where t.avail > 0) x
        where x.rk = 1
      ), tot as (
        select sum(g.avail) as demand, least(sum(g.avail), v_credit) as amount from g
      ), s as (
        select g.item_id, g.d, g.avail, tot.demand, tot.amount,
               case when tot.amount = tot.demand then g.avail
                    else floor(tot.amount::numeric * g.avail / tot.demand)::bigint end as base,
               case when tot.amount = tot.demand then 0::numeric
                    else (tot.amount::numeric * g.avail) % tot.demand end as rem
        from g, tot
      ), r as (
        select s.*, row_number() over (order by s.rem desc, s.item_id) as rn,
               s.amount - sum(s.base) over () as leftover
        from s
      ), f as (
        select r.item_id, r.d, r.base + case when r.rn <= r.leftover then 1 else 0 end as share from r
      )
      select v_acc, c.item_id, f.d, f.item_id, f.share,
             (select encode(sha256(convert_to(v_acc || '|' || c.item_id || '|' || f2.d || '|'
                                              || string_agg(f2.item_id || ':' || f2.share, ',' order by f2.item_id),
                                              'UTF8')), 'hex')
              from f f2 group by f2.d)
      from f where f.share > 0;
      if found then
        exit;  -- one proposal per file
      end if;
    end loop;
  end loop;
end;
$$;

------------------------------------------------------------------------------------------
-- Gating again on hold changes (redefined from 20261109150000): the M2b-4 states are left alone (an allocation ops
-- reversed, a credit note to apply), and an ops release lets a payment pass the gate it names.
------------------------------------------------------------------------------------------

create or replace function private.regate_account(p_account_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform private.assign_begin();
  insert into pg_temp._assign (ord, payment_id, account_id, method, rule_version)
  select row_number() over (order by p.booking_date, p.created_at, p.id), p.id, p.account_id, p.match_method, 'regate'
  from public.payment p
  where p.account_id = p_account_id and p.status = 'matched'
    and (p.review_reason is null or p.review_reason in ('account_closed', 'currency_mismatch', 'before_servicing_start',
                                                        'hold_blocks_allocation', 'nothing_due'));
  perform private.gate_assignments();
  update pg_temp._assign g set review_reason = null
  from public.payment p
  where p.id = g.payment_id and g.review_reason = p.allocation_instruction ->> 'release';
  update public.payment p set review_reason = g.review_reason
  from pg_temp._assign g
  where p.id = g.payment_id and p.review_reason is distinct from g.review_reason;
end;
$$;

------------------------------------------------------------------------------------------
-- The allocation job (worker): plans computed by collectoo_worker.payments.allocation, posted set-based here
------------------------------------------------------------------------------------------

-- The worker fills pg_temp._alloc_target (one row per payment of the run, with what the engine decided) and
-- pg_temp._alloc_line (the lines of each allocation, in the waterfall's order).
create or replace function private.allocation_begin()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._alloc_line;
  drop table if exists pg_temp._alloc_target;
  create temp table _alloc_target (
    payment_id uuid primary key,
    ord bigint not null unique,
    account_id uuid not null,       -- the file allocated to: the payment's, or the one ops named (founder #8)
    outcome text not null check (outcome in ('allocate', 'nothing_due', 'credit_note_to_apply', 'account_closed',
                                             'currency_mismatch', 'before_servicing_start', 'hold_blocks_allocation')),
    effective_date date,
    policy jsonb,
    designation jsonb,
    inputs_hash text,
    check ((outcome = 'allocate') = (effective_date is not null and policy is not null and inputs_hash is not null))
  ) on commit drop;
  create temp table _alloc_line (
    payment_id uuid not null,
    seq integer not null check (seq >= 1),
    claim_item_id uuid not null,
    component text not null,
    amount_minor bigint not null check (amount_minor > 0),
    primary key (payment_id, seq)
  ) on commit drop;
end;
$$;

-- Posts the run's plans (one allocation_run row): set-based checks (LG006 not ready / gated / bad line, LG007 more than is left of a
-- payment, LG006 1343-1 order), one allocation entry per (payment, file) through ledger_post_set (which re-checks I2,
-- I3, I4, I6 at once), the plan of each entry, one client notification per entry, the payments' states. Returns the
-- run's summary. Plans rest on no statistics of the tables written in this transaction: every lookup is keyed.
create or replace function private.post_allocations(p_organization_id uuid, p_trigger text, p_engine_version text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p_run_id uuid;
  v_bad text;
  v_today date := private.paris_today();
  v_interest text[];
  v_principal text[];
  v_summary jsonb;
begin
  if p_engine_version is null or p_engine_version !~ '^[a-z0-9.-]{1,40}$' then
    raise exception 'allocation: engine version required' using errcode = 'LG006';
  end if;
  if p_trigger is null or p_trigger not in ('ready', 'continuation') then
    raise exception 'allocation: unknown trigger %', p_trigger using errcode = 'LG006';
  end if;
  -- the allocation lock (design §5.2): the caller holds it already when it read the balances
  perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  insert into public.allocation_run (organization_id, trigger) values (p_organization_id, p_trigger)
  returning id into p_run_id;
  analyze pg_temp._alloc_target;
  analyze pg_temp._alloc_line;

  drop table if exists pg_temp._alloc_t;
  create temp table _alloc_t on commit drop as
  select t.payment_id, t.ord, t.account_id, t.outcome, t.effective_date, t.policy, t.designation, t.inputs_hash,
         p.organization_id as payment_org, p.amount_minor, p.currency as payment_currency, p.booking_date, p.status,
         p.review_reason, coalesce((p.allocation_instruction ->> 'account_id')::uuid, p.account_id) as payment_target,
         p.allocation_instruction ->> 'release' as released,
         a.organization_id as account_org, a.client_organization_id, a.portfolio_id, a.status as account_status,
         a.currency as account_currency, s.start as servicing_start, coalesce(h.n, 0) as holds,
         row_number() over (order by t.ord)::integer as entry_no
  from pg_temp._alloc_target t
  left join public.payment p on p.id = t.payment_id
  left join public.account a on a.id = t.account_id
  left join lateral (select min(o.valid_from) as start from public.claim_ownership_period o
                     where o.account_id = t.account_id) s on true
  left join lateral (select count(*) as n from public.account_hold x
                     where x.account_id = t.account_id and x.ended_at is null
                       and x.kind in ('surendettement', 'collective_proceeding')) h on true;
  alter table pg_temp._alloc_t add primary key (payment_id);
  analyze pg_temp._alloc_t;

  -- The run's payments: this servicer's, still ready, on the file the engine planned for.
  select min(t.payment_id::text) into v_bad from pg_temp._alloc_t t
  where t.payment_org is distinct from p_organization_id or t.account_org is distinct from p_organization_id
     or t.status not in ('matched', 'partially_allocated') or t.review_reason is not null
     or t.payment_target is distinct from t.account_id;
  if v_bad is not null then
    raise exception 'allocation: payment % is not ready for allocation on this file', v_bad using errcode = 'LG006';
  end if;
  -- Gates (design §8.4; the job read the same facts under the same locks): a confirmed open file, the payment's
  -- currency (1343-3), not before servicing started unless ops checked it (#10), no surendettement or collective
  -- proceeding unless a judge authorised it (#12); dated greatest(booking date, servicing start), never in the future.
  select min(t.payment_id::text) into v_bad from pg_temp._alloc_t t
  where t.outcome = 'allocate'
    and (t.account_status = 'staged' or t.account_status like 'closed%'
         or t.account_currency <> t.payment_currency
         or t.servicing_start is null or t.effective_date <> greatest(t.booking_date, t.servicing_start)
         or t.effective_date > v_today
         or (t.booking_date < t.servicing_start and t.released is distinct from 'before_servicing_start')
         or (t.holds > 0 and t.released is distinct from 'hold_blocks_allocation'));
  if v_bad is not null then
    raise exception 'allocation: payment % may not be allocated on this file now', v_bad using errcode = 'LG006';
  end if;
  -- Lines: only for allocations, on items of the planned file, with an allocation per line.
  select min(l.payment_id::text) into v_bad
  from pg_temp._alloc_line l
  left join pg_temp._alloc_t t on t.payment_id = l.payment_id
  left join public.claim_item i on i.id = l.claim_item_id
  left join public.ledger_component c on c.code = l.component
  where t.payment_id is null or t.outcome <> 'allocate' or i.account_id is distinct from t.account_id or c.code is null;
  if v_bad is not null then
    raise exception 'allocation: payment % has lines outside its plan or its file', v_bad using errcode = 'LG006';
  end if;
  select min(t.payment_id::text) into v_bad from pg_temp._alloc_t t
  where t.outcome = 'allocate' and not exists (select 1 from pg_temp._alloc_line l where l.payment_id = t.payment_id);
  if v_bad is not null then
    raise exception 'allocation: payment % has no line', v_bad using errcode = 'LG006';
  end if;

  -- What is left of each payment (I4 before posting; ledger_entry_verify re-checks every date).
  drop table if exists pg_temp._alloc_u;
  create temp table _alloc_u on commit drop as
  select t.payment_id, t.amount_minor, x.allocated_minor as allocated,
         x.allocated_minor + x.returned_minor as moved
  from pg_temp._alloc_t t
  join private.payment_positions(array(select y.payment_id from pg_temp._alloc_t y)) x on x.payment_id = t.payment_id;
  alter table pg_temp._alloc_u add primary key (payment_id);
  select min(x.payment_id::text) into v_bad
  from (select l.payment_id, sum(l.amount_minor) as s from pg_temp._alloc_line l group by l.payment_id) x
  join pg_temp._alloc_u u on u.payment_id = x.payment_id
  where x.s > u.amount_minor - u.moved;
  if v_bad is not null then
    raise exception 'allocation: payment % would allocate more than is left of it', v_bad using errcode = 'LG007';
  end if;

  -- 1343-1 « Le paiement partiel s'impute d'abord sur les intérêts »: no principal of an item while that item's
  -- interest still has something available at the date, after this run's earlier plans (same file: date order) and
  -- this entry's own interest lines.
  select coalesce(array_agg(c.code) filter (where c.family = 'interest'), '{}'),
         coalesce(array_agg(c.code) filter (where c.family = 'principal'), '{}')
  into v_interest, v_principal from public.ledger_component c;
  drop table if exists pg_temp._alloc_int;
  create temp table _alloc_int on commit drop as
  select x.payment_id, x.ord, x.effective_date, la.id as ledger_account_id
  from (select distinct t.payment_id, t.ord, t.effective_date, l.claim_item_id
        from pg_temp._alloc_t t join pg_temp._alloc_line l on l.payment_id = t.payment_id
        where l.component = any (v_principal)) x
  join public.ledger_account la on la.claim_item_id = x.claim_item_id and la.component = any (v_interest);
  if exists (select from pg_temp._alloc_int) then
    analyze pg_temp._alloc_int;
    drop table if exists pg_temp._alloc_cum;
    create temp table _alloc_cum on commit drop as
    select y.ledger_account_id, y.ord, sum(y.amount) over (partition by y.ledger_account_id order by y.ord) as cum
    from (select la.id as ledger_account_id, t.ord, sum(l.amount_minor) as amount
          from pg_temp._alloc_t t
          join pg_temp._alloc_line l on l.payment_id = t.payment_id and l.component = any (v_interest)
          join public.ledger_account la on la.claim_item_id = l.claim_item_id and la.component = l.component
          group by la.id, t.ord) y;
    create index on pg_temp._alloc_cum (ledger_account_id, ord);
    analyze pg_temp._alloc_cum;
    select min(z.payment_id::text) into v_bad
    from (select i.payment_id,
                 private.receivable_low(i.ledger_account_id, i.effective_date)
                 - coalesce((select c.cum from pg_temp._alloc_cum c
                             where c.ledger_account_id = i.ledger_account_id and c.ord <= i.ord
                             order by c.ord desc limit 1), 0) as left_over
          from pg_temp._alloc_int i) z
    where z.left_over > 0;
    if v_bad is not null then
      raise exception 'allocation: payment % pays principal while interest of the same debt is due (1343-1)', v_bad
        using errcode = 'LG006';
    end if;
  end if;

  -- One allocation entry per (payment, file): 4710 pool debit, 4670 credit to the file's client, one 1100 credit per
  -- (item, component) in the waterfall's order, one 3100 debit per component.
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, account_id,
                                  payment_id, source_type, source_id, engine_version, inputs_hash)
  select t.entry_no, p_organization_id, 'allocation', t.effective_date,
         'alloc:' || p_run_id || ':' || t.payment_id || ':' || t.account_id, t.account_id, t.payment_id,
         'allocation_run', p_run_id::text, p_engine_version, t.inputs_hash
  from pg_temp._alloc_t t where t.outcome = 'allocate';
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, claim_item_id, component)
  select t.entry_no, 1, 'unallocated_payment', s.total, t.account_currency, null::uuid, null::text
  from pg_temp._alloc_t t
  join (select l.payment_id, sum(l.amount_minor) as total from pg_temp._alloc_line l group by l.payment_id) s
    on s.payment_id = t.payment_id
  union all
  select t.entry_no, 2, 'client_payable', -s.total, t.account_currency, null, null
  from pg_temp._alloc_t t
  join (select l.payment_id, sum(l.amount_minor) as total from pg_temp._alloc_line l group by l.payment_id) s
    on s.payment_id = t.payment_id
  union all
  select t.entry_no, 2 + row_number() over (partition by l.payment_id order by l.seq), 'debtor_receivable',
         -l.amount_minor, t.account_currency, l.claim_item_id, l.component
  from pg_temp._alloc_t t join pg_temp._alloc_line l on l.payment_id = t.payment_id
  union all
  select t.entry_no, 2 + n.lines + row_number() over (partition by c.payment_id order by c.component), 'owner_claim',
         c.total, t.account_currency, null, c.component
  from (select l.payment_id, l.component, sum(l.amount_minor) as total from pg_temp._alloc_line l
        group by l.payment_id, l.component) c
  join pg_temp._alloc_t t on t.payment_id = c.payment_id
  join (select l.payment_id, count(*)::integer as lines from pg_temp._alloc_line l group by l.payment_id) n
    on n.payment_id = c.payment_id;

  drop table if exists pg_temp._alloc_posted;
  create temp table _alloc_posted on commit drop as
  select x.entry_no, x.entry_id, x.created from private.ledger_post_set() x;

  insert into private.allocation_plan (entry_id, run_id, payment_id, account_id, effective_date, policy, designation,
                                       inputs_hash, engine_version)
  select x.entry_id, p_run_id, t.payment_id, t.account_id, t.effective_date, t.policy, t.designation, t.inputs_hash,
         p_engine_version
  from pg_temp._alloc_posted x join pg_temp._alloc_t t on t.entry_no = x.entry_no
  where x.created;

  -- R124-5: the client is told of each allocation (exactly once: unique entry).
  insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id,
                                          payment_id, ledger_entry_id, kind)
  select p_organization_id, t.client_organization_id, t.portfolio_id, t.account_id, t.payment_id, x.entry_id,
         'payment_allocated'
  from pg_temp._alloc_posted x join pg_temp._alloc_t t on t.entry_no = x.entry_no
  where x.created;

  -- The payments' states (design §7): allocated (nothing left), partially allocated (an overpayment, kept in 4710:
  -- founder #8), or still matched with the reason the engine gave (gated, nothing due, credit note to apply).
  update public.payment p set
    status = case when u.allocated + coalesce(s.total, 0) = 0 then 'matched'
                  when u.amount_minor - u.moved - coalesce(s.total, 0) = 0 then 'allocated'
                  else 'partially_allocated' end,
    review_reason = case when t.outcome <> 'allocate' then t.outcome
                         when u.amount_minor - u.moved - coalesce(s.total, 0) = 0 then null
                         else 'overpayment' end,
    allocation_instruction = null
  from pg_temp._alloc_t t
  join pg_temp._alloc_u u on u.payment_id = t.payment_id
  left join (select l.payment_id, sum(l.amount_minor) as total from pg_temp._alloc_line l group by l.payment_id) s
    on s.payment_id = t.payment_id
  where p.id = t.payment_id;

  select jsonb_build_object(
    'run_id', p_run_id,
    'payments', count(*),
    'entries', (select count(*) from pg_temp._alloc_posted where created),
    'allocated_minor', coalesce((select sum(l.amount_minor) from pg_temp._alloc_line l), 0)::text,
    'outcomes', coalesce((select jsonb_object_agg(o.outcome, o.n) from (
                  select t.outcome, count(*) as n from pg_temp._alloc_t t group by t.outcome) o), '{}'),
    'overpayments', count(*) filter (where t.outcome = 'allocate'
                                      and u.amount_minor - u.moved > (select sum(l.amount_minor) from pg_temp._alloc_line l
                                                                       where l.payment_id = t.payment_id)))
  into v_summary
  from pg_temp._alloc_t t join pg_temp._alloc_u u on u.payment_id = t.payment_id;
  update public.allocation_run set summary = v_summary, finished_at = now() where id = p_run_id;
  return v_summary;
end;
$$;

------------------------------------------------------------------------------------------
-- Commands (admins and ops managers at aal2, decision #18): idempotency key + request hash, French copy in the web
-- app. Each acts on what the page showed (compare and set) and takes milliseconds; a running allocation holds the
-- allocation lock: they wait at most 2 s, then ask to retry (lock_timeout).
------------------------------------------------------------------------------------------

-- The payment's file and the documents of it that may serve as evidence.
create or replace function private.document_of_file(p_document_id uuid, p_account_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from public.document d join public.account a on a.id = p_account_id
                 where d.id = p_document_id and d.organization_id = a.organization_id
                   and d.client_organization_id = a.client_organization_id and d.account_id = a.id);
$$;

-- « Imputer » (design §12.3): send a matched payment to allocation again — after ops reversed an allocation, once
-- something is due again, without invoking a credit note, or at the cut-off when the client's balance does not count
-- it (#10) — or use an overpayment for another file of the same debtor on his written request (founder #8; same
-- client: debtors are not shared across clients). The allocation job allocates it; nothing is posted here.
create or replace function public.allocate_payment(p_idempotency_key text, p_payment_id uuid, p_expected_reason text,
                                                   p_account_id uuid, p_evidence_document_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  p public.payment;
  src public.account;
  dst public.account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_instruction jsonb;
  v_left bigint;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'expected_reason', p_expected_reason,
                                  'account_id', p_account_id, 'evidence_document_id', p_evidence_document_id,
                                  'reason', v_reason);
  v_result := private.command_replay('allocate_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p.review_reason is distinct from p_expected_reason or p.account_id is null then
    raise exception 'the payment changed: reload the page' using errcode = 'check_violation';
  end if;
  select * into src from public.account where id = p.account_id;
  if p_account_id is null or p_account_id = p.account_id then
    if p.status <> 'matched' or p.review_reason is null
       or p.review_reason not in ('allocation_reversed', 'nothing_due', 'credit_note_to_apply', 'before_servicing_start') then
      raise exception 'this payment cannot be sent to allocation from here' using errcode = 'check_violation';
    end if;
    v_instruction := jsonb_build_object('release', p.review_reason, 'reason', v_reason, 'decided_by', auth.uid(),
                                        'decided_at', now());
  else
    -- An overpayment (or a payment with nothing due on its file) for another file of the same debtor, on his
    -- written request, filed as evidence.
    if not ((p.status = 'partially_allocated' and p.review_reason = 'overpayment')
            or (p.status = 'matched' and p.review_reason = 'nothing_due')) then
      raise exception 'only what is left of a payment over its file can go to another file' using errcode = 'check_violation';
    end if;
    select * into dst from public.account where id = p_account_id;
    if not found or dst.organization_id <> p.organization_id or dst.client_organization_id <> src.client_organization_id
       or dst.status = 'staged' or dst.status like 'closed%' or dst.currency <> p.currency then
      raise exception 'the other file must be an open file of the same client, in the payment''s currency'
        using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.account_party x join public.account_party y on y.party_id = x.party_id
                   where x.account_id = src.id and y.account_id = dst.id
                     and x.role in ('borrower', 'co_borrower') and y.role in ('borrower', 'co_borrower')) then
      raise exception 'the other file is not a file of the same debtor' using errcode = 'check_violation';
    end if;
    if p_evidence_document_id is null
       or not (private.document_of_file(p_evidence_document_id, src.id)
               or private.document_of_file(p_evidence_document_id, dst.id)) then
      raise exception 'the debtor''s written request is required, filed on one of the two files'
        using errcode = 'check_violation';
    end if;
    select unallocated_minor into v_left from private.payment_positions(array[p.id]);
    if v_left <= 0 then
      raise exception 'nothing is left of this payment' using errcode = 'check_violation';
    end if;
    v_instruction := jsonb_build_object('release', 'overpayment', 'account_id', dst.id,
                                        'evidence_document_id', p_evidence_document_id, 'reason', v_reason,
                                        'decided_by', auth.uid(), 'decided_at', now());
  end if;
  update public.payment set allocation_instruction = v_instruction, review_reason = null where id = p.id;
  v_result := jsonb_build_object('payment_id', p.id, 'account_id', coalesce(p_account_id, p.account_id),
                                 'queued', true);
  perform private.command_record('allocate_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Lever le blocage » (founder #12, HOLD-01/02): a payment held by surendettement or a collective proceeding is
-- allocated with the judge's (or juge-commissaire's) authorisation, filed on the file as evidence. The hold stays.
create or replace function public.release_hold_payment(p_idempotency_key text, p_payment_id uuid,
                                                       p_evidence_document_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  p public.payment;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'evidence_document_id', p_evidence_document_id,
                                  'reason', v_reason);
  v_result := private.command_replay('release_hold_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p.status <> 'matched' or p.review_reason is distinct from 'hold_blocks_allocation' then
    raise exception 'the payment is not held: reload the page' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null or not private.document_of_file(p_evidence_document_id, p.account_id) then
    raise exception 'the judge''s authorisation is required, filed on this file' using errcode = 'check_violation';
  end if;
  update public.payment
  set allocation_instruction = jsonb_build_object('release', 'hold_blocks_allocation',
                                                  'evidence_document_id', p_evidence_document_id, 'reason', v_reason,
                                                  'decided_by', auth.uid(), 'decided_at', now()),
      review_reason = null
  where id = p.id;
  v_result := jsonb_build_object('payment_id', p.id, 'queued', true);
  perform private.command_record('release_hold_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Désimputer » (design §8.1: a mistaken allocation is reversed at its own date): every live allocation entry of the
-- payment on that file — exactly those the page showed (compare and set) — reversed; the receivables are restored, the
-- money is back in 4710 for this payment, the client is told; the payment waits for ops (allocation_reversed): unassign
-- it, or send it to allocation again. The file's other payments with nothing due are gated again.
create or replace function public.reverse_allocation(p_idempotency_key text, p_payment_id uuid, p_account_id uuid,
                                                     p_entry_ids uuid[], p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  p public.payment;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_live uuid[];
  v_shown uuid[];
  e record;
  v_rev uuid;
  v_reversals uuid[] := '{}';
  pos record;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_shown from unnest(p_entry_ids) x;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'account_id', p_account_id, 'entry_ids', to_jsonb(v_shown),
                                  'reason', v_reason);
  v_result := private.command_replay('reverse_allocation', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  select coalesce(array_agg(x.id order by x.id), '{}') into v_live
  from public.ledger_entry x
  where x.payment_id = p.id and x.entry_type = 'allocation' and x.account_id = p_account_id
    and not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = x.id);
  if cardinality(v_live) = 0 then
    raise exception 'nothing of this payment is allocated on this file' using errcode = 'check_violation';
  end if;
  if v_live <> v_shown then
    raise exception 'the allocation changed: reload the page' using errcode = 'check_violation';
  end if;
  for e in select x.id, x.client_organization_id, x.portfolio_id from public.ledger_entry x
           where x.id = any (v_live) order by x.effective_date, x.id loop
    select r.entry_id into v_rev from private.ledger_reverse(e.id, 'unalloc:' || e.id, v_reason) r;
    v_reversals := v_reversals || v_rev;
    insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id,
                                            payment_id, ledger_entry_id, kind, reason)
    values (p.organization_id, e.client_organization_id, e.portfolio_id, p_account_id, p.id, v_rev,
            'payment_allocation_reversed', v_reason);
  end loop;
  select * into pos from private.payment_positions(array[p.id]);
  update public.payment
  set status = case when pos.allocated_minor = 0 then 'matched'
                    when pos.unallocated_minor = 0 then 'allocated' else 'partially_allocated' end,
      review_reason = 'allocation_reversed', allocation_instruction = null
  where id = p.id;
  perform private.regate_account(p_account_id);  -- the file's other payments may find something due again
  v_result := jsonb_build_object('payment_id', p.id, 'account_id', p_account_id, 'reversals', to_jsonb(v_reversals));
  perform private.command_record('reverse_allocation', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Reverser au client » (design §8.1 `forward`): what is left of a payment that nothing was allocated from goes to
-- the client without touching the debt — a file the client recalled (founder 2026-11-07), a payment before the cut-off
-- that the client's balance already counts (#10), or a payment on a rolled-back batch the client ratified (1342-2, #11;
-- the ratification filed as evidence, OQ-29). Never an overpayment (#8). The amount the page showed must still be what
-- is left (compare and set).
create or replace function public.forward_payment(p_idempotency_key text, p_payment_id uuid,
                                                  p_client_organization_id uuid, p_expected_minor text,
                                                  p_evidence_document_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  p public.payment;
  a public.account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_client uuid;
  pos record;
  v_entry uuid;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'client_organization_id', p_client_organization_id,
                                  'expected_minor', p_expected_minor, 'evidence_document_id', p_evidence_document_id,
                                  'reason', v_reason);
  v_result := private.command_replay('forward_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  select * into pos from private.payment_positions(array[p.id]);
  if pos.allocated_minor <> 0 or pos.unallocated_minor <= 0 then
    raise exception 'only a payment nothing was allocated from can be forwarded' using errcode = 'check_violation';
  end if;
  if p_expected_minor is distinct from pos.unallocated_minor::text then
    raise exception 'the amount changed: reload the page' using errcode = 'check_violation';
  end if;
  if p.account_id is not null then
    select * into a from public.account where id = p.account_id;
    if not (p.status = 'matched' and (a.status = 'closed_recalled' or p.review_reason = 'before_servicing_start')) then
      raise exception 'a payment on a file is forwarded only when the client recalled the file or for a payment before the cut-off'
        using errcode = 'check_violation';
    end if;
    if p_client_organization_id is not null and p_client_organization_id <> a.client_organization_id then
      raise exception 'the client is the file''s' using errcode = 'check_violation';
    end if;
    v_client := a.client_organization_id;
    if p_evidence_document_id is not null and not private.document_of_file(p_evidence_document_id, a.id) then
      raise exception 'the evidence is not a document of this file' using errcode = 'check_violation';
    end if;
  else
    if p.status <> 'unmatched' or p.review_reason is distinct from 'no_mandate' then
      raise exception 'a payment without a file is forwarded only on a client''s ratification (rolled-back batch)'
        using errcode = 'check_violation';
    end if;
    v_client := p_client_organization_id;
    if v_client is null or not exists (select 1 from public.organization o
                                       where o.id = v_client and o.servicer_organization_id = p.organization_id) then
      raise exception 'a client of this servicer is required' using errcode = 'check_violation';
    end if;
    if p_evidence_document_id is null or not exists (
         select 1 from public.document d where d.id = p_evidence_document_id and d.organization_id = p.organization_id
           and d.client_organization_id = v_client) then
      raise exception 'the client''s ratification is required (a document of that client)' using errcode = 'check_violation';
    end if;
  end if;
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, payment_id, source_type, source_id, reason)
  values (1, p.organization_id, 'forward', private.paris_today(), 'forward:' || p.id || ':' || md5(p_idempotency_key),
          v_client, p.id, 'payment', p.id::text, v_reason);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency) values
    (1, 1, 'unallocated_payment', pos.unallocated_minor, p.currency),
    (1, 2, 'client_payable', -pos.unallocated_minor, p.currency);
  select x.entry_id into v_entry from private.ledger_post_set() x;
  insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id, payment_id,
                                          ledger_entry_id, kind, reason)
  values (p.organization_id, v_client, p.portfolio_id, p.account_id, p.id, v_entry, 'payment_forwarded', v_reason);
  update public.payment set status = 'allocated', review_reason = null, allocation_instruction = null where id = p.id;
  v_result := jsonb_build_object('payment_id', p.id, 'entry_id', v_entry, 'amount_minor', pos.unallocated_minor::text);
  perform private.command_record('forward_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Appliquer l'avoir » (founder #7): the proposal the page showed (its key), applied as one `netting` entry; the
-- reason records that compensation is invoked (1347). The file's payments that waited for it go to allocation once
-- nothing else is proposed.
create or replace function public.apply_credit_note(p_idempotency_key text, p_account_id uuid, p_proposal_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  a public.account;
  v_request jsonb := jsonb_build_object('account_id', p_account_id, 'proposal_key', p_proposal_key);
  v_result jsonb;
  v_credit uuid;
  v_date date;
  v_total bigint;
  v_entry uuid;
begin
  select * into a from public.account where id = p_account_id;
  if not found or not private.has_role(a.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('apply_credit_note', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  -- the allocation lock first, as the allocation job: the proposal reads balances that allocations change
  perform pg_advisory_xact_lock(hashtext('payments:' || a.organization_id::text));
  drop table if exists pg_temp._cn;
  create temp table _cn on commit drop as select * from private.credit_note_proposals(array[a.id]);
  if not exists (select from pg_temp._cn) then
    raise exception 'no credit note to apply on this file' using errcode = 'check_violation';
  end if;
  if (select min(c.proposal_key) from pg_temp._cn c) is distinct from p_proposal_key then
    raise exception 'the proposal changed: reload the page' using errcode = 'check_violation';
  end if;
  select min(c.credit_item_id::text)::uuid, min(c.netting_date), sum(c.amount_minor)
  into v_credit, v_date, v_total from pg_temp._cn c;
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, account_id,
                                  source_type, source_id, reason)
  values (1, a.organization_id, 'netting', v_date, 'netting:' || v_credit || ':' || md5(p_idempotency_key), a.id,
          'claim_item', v_credit::text, 'compensation invoquée (art. 1347 C. civ.)');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, claim_item_id, component)
  select 1, 1, 'debtor_receivable', v_total, a.currency, v_credit, 'principal'
  union all
  select 1, 1 + row_number() over (order by c.target_item_id), 'debtor_receivable', -c.amount_minor, a.currency,
         c.target_item_id, 'principal'
  from pg_temp._cn c;
  select x.entry_id into v_entry from private.ledger_post_set() x;
  if not exists (select from private.credit_note_proposals(array[a.id])) then
    update public.payment set review_reason = null
    where account_id = a.id and status in ('matched', 'partially_allocated') and review_reason = 'credit_note_to_apply';
  end if;
  v_result := jsonb_build_object('account_id', a.id, 'entry_id', v_entry, 'netting_date', v_date,
                                 'amount_minor', v_total::text);
  perform private.command_record('apply_credit_note', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- A new version of the allocation policy of the servicer, a client or a portfolio (admins). Never retroactive:
-- it applies from today or a later date.
create or replace function public.set_allocation_policy(p_idempotency_key text, p_organization_id uuid,
                                                        p_client_organization_id uuid, p_portfolio_id uuid,
                                                        p_accessory_rank text, p_unclassified text,
                                                        p_effective_from date, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_version integer;
  v_id uuid;
begin
  if not private.has_role(p_organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('organization_id', p_organization_id, 'client_organization_id', p_client_organization_id,
                                  'portfolio_id', p_portfolio_id, 'accessory_rank', p_accessory_rank,
                                  'unclassified', p_unclassified, 'effective_from', p_effective_from, 'reason', v_reason);
  v_result := private.command_replay('set_allocation_policy', p_idempotency_key, v_request);
  if v_result is not null then
    return (v_result ->> 'policy_id')::uuid;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p_effective_from is null or p_effective_from < private.paris_today() then
    raise exception 'a policy applies from today or a later date (never retroactively)' using errcode = 'check_violation';
  end if;
  perform pg_advisory_xact_lock(hashtext('allocation_policy:' || p_organization_id::text));
  select coalesce(max(x.version), 0) + 1 into v_version from public.allocation_policy x
  where x.organization_id = p_organization_id and x.client_organization_id is not distinct from p_client_organization_id
    and x.portfolio_id is not distinct from p_portfolio_id;
  insert into public.allocation_policy (organization_id, client_organization_id, portfolio_id, version, effective_from,
                                        accessory_rank, unclassified, reason, created_by)
  values (p_organization_id, p_client_organization_id, p_portfolio_id, v_version, p_effective_from, p_accessory_rank,
          p_unclassified, v_reason, auth.uid())
  returning id into v_id;
  perform private.command_record('set_allocation_policy', p_idempotency_key, v_request, jsonb_build_object('policy_id', v_id));
  return v_id;
end;
$$;

------------------------------------------------------------------------------------------
-- Reads for the back-office pages (bounded; amounts as text: no JS number ever holds one)
------------------------------------------------------------------------------------------

-- The payment page (design §12.3): bank facts, position, file, match decisions, entries with their lines, what the
-- client was told, the file's documents (evidence for the actions). Admins and ops managers.
create or replace function public.payment_detail(p_payment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p public.payment;
  v jsonb;
begin
  select * into p from public.payment where id = p_payment_id and organization_id = any (private.money_staff_org_ids());
  if not found then
    return null;
  end if;
  select jsonb_build_object(
    'payment', jsonb_build_object(
      'id', p.id, 'amount_minor', p.amount_minor::text, 'currency', p.currency, 'booking_date', p.booking_date,
      'value_date', p.value_date, 'payer_name', p.payer_name, 'payer_iban_end', right(p.payer_iban, 4),
      'remittance_text', p.remittance_text, 'creditor_reference', p.creditor_reference, 'end_to_end_id', p.end_to_end_id,
      'status', p.status, 'review_reason', p.review_reason, 'account_id', p.account_id, 'match_method', p.match_method,
      'matched_at', p.matched_at, 'designation', p.designation, 'instruction', p.allocation_instruction,
      'channel', p.channel, 'method', p.method),
    'position', (select jsonb_build_object('allocated_minor', x.allocated_minor::text,
                                           'unallocated_minor', x.unallocated_minor::text,
                                           'returned_minor', x.returned_minor::text)
                 from private.payment_positions(array[p.id]) x),
    'file', (select jsonb_build_object('account_id', a.id, 'external_ref', a.external_ref, 'status', a.status,
                                       'client_organization_id', a.client_organization_id, 'client_name', c.legal_name,
                                       'currency', a.currency, 'legal_regime', a.legal_regime,
                                       'debtor_name', (select min(pa.display_name) from public.account_party ap
                                                       join public.party pa on pa.id = ap.party_id
                                                       where ap.account_id = a.id and ap.role = 'borrower'))
             from public.account a join public.organization c on c.id = a.client_organization_id
             where a.id = p.account_id),
    'matches', coalesce((select jsonb_agg(jsonb_build_object('action', m.action, 'account_id', m.account_id,
                                                             'external_ref', a.external_ref, 'method', m.method,
                                                             'rule', m.rule, 'trigger', m.trigger, 'reason', m.reason,
                                                             'review_reason', m.review_reason, 'decided_at', m.decided_at,
                                                             'by_ops', m.decided_by is not null)
                                          order by m.decided_at, m.id)
                         from public.payment_match m join public.account a on a.id = m.account_id
                         where m.payment_id = p.id), '[]'),
    'entries', coalesce((select jsonb_agg(jsonb_build_object(
                           'entry_id', e.id, 'entry_type', e.entry_type, 'effective_date', e.effective_date,
                           'posted_at', e.posted_at, 'reason', e.reason, 'account_id', e.account_id,
                           'external_ref', (select a.external_ref from public.account a where a.id = e.account_id),
                           'reverses_entry_id', e.reverses_entry_id,
                           'reversed_by', (select r.id from public.ledger_entry r where r.reverses_entry_id = e.id),
                           'amount_minor', (select sum(lp.amount_minor) from public.ledger_posting lp
                                            join public.ledger_account la on la.id = lp.ledger_account_id
                                            where lp.entry_id = e.id and la.book = 'unallocated_payment')::text,
                           'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                                              'claim_item_id', la.claim_item_id, 'item_ref', i.ref, 'item_kind', i.kind,
                                              'due_date', i.due_date, 'component', la.component,
                                              'amount_minor', (-lp.amount_minor)::text)
                                            order by lp.line_no), '[]')
                                     from public.ledger_posting lp
                                     join public.ledger_account la on la.id = lp.ledger_account_id
                                     join public.claim_item i on i.id = la.claim_item_id
                                     where lp.entry_id = e.id and la.book = 'debtor_receivable'))
                         order by e.posted_at, e.id)
                         from public.ledger_entry e where e.payment_id = p.id), '[]'),
    'notifications', coalesce((select jsonb_agg(jsonb_build_object('kind', n.kind, 'created_at', n.created_at,
                                                                   'client_name', c.legal_name, 'reason', n.reason,
                                                                   'ledger_entry_id', n.ledger_entry_id)
                                                order by n.created_at, n.id)
                               from public.client_notification n
                               join public.organization c on c.id = n.client_organization_id
                               where n.payment_id = p.id), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'created_at', d.created_at)
                                            order by d.created_at desc, d.id)
                           from public.document d where p.account_id is not null and d.account_id = p.account_id), '[]'),
    'other_files', coalesce((select jsonb_agg(jsonb_build_object('account_id', o.id, 'external_ref', o.external_ref)
                                              order by o.external_ref)
                             from public.account o
                             where p.account_id is not null and o.id <> p.account_id
                               and o.status not in ('staged', 'closed_paid', 'closed_settled', 'closed_uncollectable',
                                                    'closed_recalled')
                               and o.currency = p.currency
                               and exists (select 1 from public.account_party x
                                           join public.account_party y on y.party_id = x.party_id
                                           where x.account_id = p.account_id and y.account_id = o.id
                                             and x.role in ('borrower', 'co_borrower')
                                             and y.role in ('borrower', 'co_borrower'))), '[]')
  ) into v;
  return v;
end;
$$;

-- The file page (design §12.4, read-only but for « Appliquer l'avoir »): reference, client, debtor, RF, servicing
-- start, balances per item and component, holds, payments, the credit-note proposal. Staff who read the portfolio.
create or replace function public.account_detail(p_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.account;
  v jsonb;
  v_money boolean;
begin
  select * into a from public.account where id = p_account_id;
  if not found or not (a.organization_id = any (private.staff_org_ids())) or not private.can_read_portfolio(a.portfolio_id) then
    return null;
  end if;
  v_money := a.organization_id = any (private.money_staff_org_ids());
  select jsonb_build_object(
    'account', jsonb_build_object('id', a.id, 'external_ref', a.external_ref, 'status', a.status, 'currency', a.currency,
                                  'legal_regime', a.legal_regime, 'claim_type', a.claim_type_code,
                                  'client_name', (select o.legal_name from public.organization o
                                                  where o.id = a.client_organization_id),
                                  'portfolio_name', (select x.name from public.portfolio x where x.id = a.portfolio_id),
                                  'servicing_start', (select min(o.valid_from) from public.claim_ownership_period o
                                                      where o.account_id = a.id)),
    'can_act', v_money,
    'parties', coalesce((select jsonb_agg(jsonb_build_object('name', pa.display_name, 'role', ap.role)
                                          order by ap.role, pa.display_name)
                         from public.account_party ap join public.party pa on pa.id = ap.party_id
                         where ap.account_id = a.id), '[]'),
    'rf', (select r.rf from public.payment_reference r where r.account_id = a.id and r.status = 'active'),
    'balances', coalesce((select jsonb_agg(jsonb_build_object('claim_item_id', i.id, 'item_ref', i.ref, 'kind', i.kind,
                                                              'due_date', i.due_date, 'component', b.component,
                                                              'balance_minor', b.balance_minor::text)
                                           order by i.due_date nulls last, i.ref, c.sort_order)
                          from private.account_balances(a.id, private.paris_today(), null) b
                          join public.claim_item i on i.id = b.claim_item_id
                          join public.ledger_component c on c.code = b.component), '[]'),
    'holds', coalesce((select jsonb_agg(jsonb_build_object('kind', h.kind, 'started_at', h.started_at,
                                                           'legal_basis', h.legal_basis, 'reason', h.reason)
                                        order by h.started_at)
                       from public.account_hold h where h.account_id = a.id and h.ended_at is null), '[]'),
    'payments', coalesce((select jsonb_agg(x.j order by x.booking_date desc, x.id) from (
                            select p.id, p.booking_date,
                                   jsonb_build_object('id', p.id, 'amount_minor', p.amount_minor::text,
                                                      'currency', p.currency, 'booking_date', p.booking_date,
                                                      'status', p.status, 'review_reason', p.review_reason,
                                                      'payer_name', p.payer_name) as j
                            from public.payment p
                            where p.account_id = a.id or p.id in (select e.payment_id from public.ledger_entry e
                                                                   where e.account_id = a.id and e.payment_id is not null)
                            order by p.booking_date desc, p.id limit 50) x), '[]'),
    'proposal', case when v_money then (
                  select jsonb_build_object(
                    'credit_item_id', min(c.credit_item_id::text), 'credit_ref', min(ci.ref),
                    'netting_date', min(c.netting_date), 'proposal_key', min(c.proposal_key),
                    'amount_minor', sum(c.amount_minor)::text,
                    'targets', jsonb_agg(jsonb_build_object('item_id', c.target_item_id, 'item_ref', ti.ref,
                                                            'amount_minor', c.amount_minor::text)
                                         order by ti.ref))
                  from private.credit_note_proposals(array[a.id]) c
                  join public.claim_item ci on ci.id = c.credit_item_id
                  join public.claim_item ti on ti.id = c.target_item_id
                  having count(*) > 0) end
  ) into v;
  return v;
end;
$$;

-- « Rapprochés » (redefined from 20261109150000): every payment with a file and nothing left to decide — matched and
-- waiting for the allocation, allocated, forwarded — latest first (ops reverse a wrong one from its page). The other
-- tab is unchanged.
create or replace function public.payment_queue(p_tab text default 'a-traiter', p_reason text default null,
                                                p_client uuid default null, p_min_minor bigint default null,
                                                p_max_minor bigint default null, p_min_days integer default null,
                                                p_offset integer default 0, p_limit integer default 20)
returns table (payment_id uuid, amount_minor text, currency char(3), booking_date date, age_days integer,
               payer_name text, payer_iban_end text, remittance_text text, creditor_reference text, status text,
               review_reason text, match_method text, matched_at timestamptz, account_id uuid,
               candidate_account_id uuid, client_organization_id uuid, total bigint)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_orgs uuid[] := private.money_staff_org_ids();
  v_today date := (now() at time zone 'Europe/Paris')::date;
  v_before date := (now() at time zone 'Europe/Paris')::date - p_min_days;
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_total bigint;
begin
  if p_tab = 'rapproches' then
    select count(*) into v_total
    from public.payment p
    where p.organization_id = any (v_orgs) and p.account_id is not null and p.review_reason is null
      and (p_client is null or p.client_organization_id = p_client)
      and (p_min_minor is null or p.amount_minor >= p_min_minor)
      and (p_max_minor is null or p.amount_minor <= p_max_minor)
      and (v_before is null or p.booking_date <= v_before);
    return query
    select p.id, p.amount_minor::text, p.currency, p.booking_date, (v_today - p.booking_date)::integer, p.payer_name,
           right(p.payer_iban, 4), p.remittance_text, p.creditor_reference, p.status, p.review_reason, p.match_method,
           p.matched_at, p.account_id, p.candidate_account_id, p.client_organization_id, v_total
    from public.payment p
    where p.organization_id = any (v_orgs) and p.account_id is not null and p.review_reason is null
      and (p_client is null or p.client_organization_id = p_client)
      and (p_min_minor is null or p.amount_minor >= p_min_minor)
      and (p_max_minor is null or p.amount_minor <= p_max_minor)
      and (v_before is null or p.booking_date <= v_before)
    order by p.matched_at desc, p.booking_date, p.id
    offset v_offset limit v_limit;
    return;
  end if;

  select count(*) into v_total
  from public.payment p
  where p.organization_id = any (v_orgs) and (p.status = 'unmatched' or p.review_reason is not null)
    and (p_reason is null or p.review_reason = p_reason or (p_reason = 'waiting' and p.review_reason is null))
    and (p_client is null
         or coalesce(p.client_organization_id,
                     (select c.client_organization_id from public.account c where c.id = p.candidate_account_id))
            = p_client)
    and (p_min_minor is null or p.amount_minor >= p_min_minor)
    and (p_max_minor is null or p.amount_minor <= p_max_minor)
    and (v_before is null or p.booking_date <= v_before);
  return query
  select p.id, p.amount_minor::text, p.currency, p.booking_date, (v_today - p.booking_date)::integer, p.payer_name,
         right(p.payer_iban, 4), p.remittance_text, p.creditor_reference, p.status, p.review_reason, p.match_method,
         p.matched_at, p.account_id, p.candidate_account_id, coalesce(p.client_organization_id, c.client_organization_id),
         v_total
  from (select p.* from public.payment p
        where p.organization_id = any (v_orgs) and (p.status = 'unmatched' or p.review_reason is not null)
          and (p_reason is null or p.review_reason = p_reason or (p_reason = 'waiting' and p.review_reason is null))
          and (p_client is null
               or coalesce(p.client_organization_id,
                           (select c.client_organization_id from public.account c where c.id = p.candidate_account_id))
                  = p_client)
          and (p_min_minor is null or p.amount_minor >= p_min_minor)
          and (p_max_minor is null or p.amount_minor <= p_max_minor)
          and (v_before is null or p.booking_date <= v_before)
        order by p.booking_date, p.id
        offset v_offset limit v_limit) p
  left join public.account c on c.id = p.candidate_account_id
  order by p.booking_date, p.id;
end;
$$;

------------------------------------------------------------------------------------------
-- Read access (decision #18): policies by staff and the client of their scope; runs by money staff; notifications by
-- the client's members (their readable portfolios) and money staff. No write policy: definer functions only.
------------------------------------------------------------------------------------------

alter table public.allocation_policy enable row level security;
alter table public.allocation_run enable row level security;
alter table public.client_notification enable row level security;
alter table private.allocation_plan enable row level security;
revoke all on public.allocation_policy, public.allocation_run, public.client_notification
  from public, anon, authenticated;
revoke all on private.allocation_plan from public, anon, authenticated;
grant select on public.allocation_policy, public.allocation_run, public.client_notification to authenticated;

create policy allocation_policy_read on public.allocation_policy for select to authenticated using (
  organization_id = any ((select private.staff_org_ids())::uuid[])
  or client_organization_id = any ((select private.client_org_ids())::uuid[]));
create policy allocation_run_read on public.allocation_run for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy client_notification_read on public.client_notification for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or (client_organization_id = any ((select private.client_org_ids())::uuid[])
      and (portfolio_id is null or portfolio_id = any ((select private.readable_portfolio_ids())::uuid[]))));

------------------------------------------------------------------------------------------
-- Privileges
------------------------------------------------------------------------------------------

revoke execute on function private.payment_instruction_reset(), private.allocation_policy_guard(),
  private.client_notification_guard(), private.client_notification_update_guard(), private.payment_after_update(),
  private.receivable_low(uuid, date), private.receivable_high(uuid, date), private.payment_positions(uuid[]),
  private.credit_note_proposals(uuid[]), private.regate_account(uuid), private.allocation_begin(),
  private.post_allocations(uuid, text, text), private.document_of_file(uuid, uuid)
  from public, anon, authenticated, service_role;
-- The worker (service_role) runs the allocation job.
grant execute on function private.allocation_begin(), private.post_allocations(uuid, text, text),
  private.credit_note_proposals(uuid[]), private.receivable_low(uuid, date), private.receivable_high(uuid, date),
  private.payment_positions(uuid[])
  to service_role;
revoke execute on function public.allocate_payment(text, uuid, text, uuid, uuid, text),
  public.release_hold_payment(text, uuid, uuid, text), public.reverse_allocation(text, uuid, uuid, uuid[], text),
  public.forward_payment(text, uuid, uuid, text, uuid, text), public.apply_credit_note(text, uuid, text),
  public.set_allocation_policy(text, uuid, uuid, uuid, text, text, date, text), public.payment_detail(uuid),
  public.account_detail(uuid)
  from public, anon;
grant execute on function public.allocate_payment(text, uuid, text, uuid, uuid, text),
  public.release_hold_payment(text, uuid, uuid, text), public.reverse_allocation(text, uuid, uuid, uuid[], text),
  public.forward_payment(text, uuid, uuid, text, uuid, text), public.apply_credit_note(text, uuid, text),
  public.set_allocation_policy(text, uuid, uuid, uuid, text, text, date, text), public.payment_detail(uuid),
  public.account_detail(uuid)
  to authenticated;

------------------------------------------------------------------------------------------
-- Payments already matched before this migration: held ones tell their client now; ready ones get one allocation
-- job per servicer.
------------------------------------------------------------------------------------------

insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id, payment_id,
                                        kind, reason)
select p.organization_id, p.client_organization_id, p.portfolio_id, p.account_id, p.id, 'payment_held',
       'hold_blocks_allocation'
from public.payment p
where p.review_reason = 'hold_blocks_allocation' and p.account_id is not null
on conflict (payment_id, account_id) where kind = 'payment_held' do nothing;

select pgmq.send('payments', jsonb_build_object('type', 'allocate', 'organization_id', x.organization_id))
from (select distinct p.organization_id from public.payment p
      where p.status in ('matched', 'partially_allocated') and p.review_reason is null and p.account_id is not null) x;
