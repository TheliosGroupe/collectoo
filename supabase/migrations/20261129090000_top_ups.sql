-- M2c-7e-1 « top-ups and the own-account file » (plan docs/design/m2c-7-plan.md §7.1, §7.2, §7.3's S23 texts, §7.4,
-- §7.5's 047a; design §13 #4; ADR-0014 « M2c-7e-1 »). Forward-only. The cancellation-after-download switch stays OFF:
-- nothing here writes private.feature_switch.
--
-- What the servicer owes the dedicated account (Σ 4679 > 0: advances, fees, losses) is ordered back from its own account
-- every hour, one servicer per transaction ([critic] F8: pg_cron `servicer-top-ups` queues one `top_ups` message per
-- servicer; the worker runs private.order_due_top_up in that message's own transaction under lock_timeout 2 s, a miss
-- recorded, top_up_order_failed after three); the amount is design §13 #4's formula (private.top_up_needed); the
-- shortfall periods are logged (C. civ. 1996, OQ-38 « durations logged »). The own account's ordered top-ups go in an
-- own-account pain.001 (public.generate_top_up_file; the transfer_file job writes it), downloaded and, before or after
-- download and whatever the switch, cancelled (public.cancel_top_up_file: never a payout file, [critic] F13). The two
-- fail-closed guards get one exemption each, for a file whose debtor is an own account, and a new item guard makes
-- « debtor an own account » mean « only top-ups » ([check 1] gap 4). A filed (in_file) top-up's credit books
-- ([critic] M7-MONEY-4: the re-check, its worker twin payments/debits.py decide_line, and ops' « Comptabiliser comme
-- approvisionnement »), a cancelled one's credit waits for ops (top_up_cancelled_credit); a credit with no TOP id is
-- matched to an open top-up by ops (public.book_top_up_credit, [check 1] gap 12) and a filed top-up is cancelled alone
-- (public.cancel_top_up). S23's hints stop promising M2c-7 (D10).
--
-- Redefined (each a whole copy of its latest definition, its header naming the file and line, only the change):
-- private.transfer_file_guard, private.bank_transfer_guard (20261115090000), public.transfer_file_download
-- (20261118090000), private.bank_booking_recheck (20261119090000), private.apply_bank_bookings,
-- public.assign_payment, public.resolve_duplicate (20261117090000), public.link_debit (20261117110000),
-- public.cancel_top_up (20261111090000), private.servicer_billing_settings_guard (20261111120000),
-- private.run_advance_checks (20261128090000, 7d-3's), the constraint bank_debit_review_reason_check (20261117090000);
-- review round 1: public.cancel_transfer_file (20261116090000), private.transfer_file_failed (20261115090000).
-- Review round 2 (ADR-0014 « M2c-7e-1 review fixes », round 2) redefines nothing more: the overview's owed with the
-- sweeps in flight, top_up_order_failed only with an active dedicated account, the own account's ordered top-ups read
-- with the status in the fence, a file's transfers read through its items.

------------------------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------------------------

-- The shortfall log (plan §7.1; C. civ. 1996, OQ-38): a period opens when the hourly job sees the servicer owe the
-- dedicated account (Σ 4679 > 0 — other clients' money covers it meanwhile), keeps its peak, and closes when the job sees
-- it ≤ 0. The times are the job's observations (it runs at minute 37); `since_at` is the job's previous run for that
-- servicer (an hour before the opening when there was none): what was posted from then to the close caused the period.
create table private.servicer_shortfall_period (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  currency char(3) not null,
  since_at timestamptz not null,
  opened_at timestamptz not null,
  closed_at timestamptz,
  peak_minor bigint not null check (peak_minor > 0),
  last_minor bigint not null,          -- Σ 4679 when the job last saw it
  updated_at timestamptz not null default now(),
  constraint servicer_shortfall_period_since check (since_at <= opened_at),
  constraint servicer_shortfall_period_closed check (closed_at is null or closed_at >= opened_at)
);
create unique index servicer_shortfall_period_open_uq on private.servicer_shortfall_period (organization_id, currency)
  where closed_at is null;
create index servicer_shortfall_period_org_idx on private.servicer_shortfall_period (organization_id, opened_at desc);
comment on table private.servicer_shortfall_period is
  'The periods the servicer owed the dedicated account (Σ 4679 > 0), as the hourly top-up job saw them (OQ-38).';

-- What a period may become: opened owing (its peak its first amount), its peak only rising while open, closed once; what
-- was logged never changes.
create or replace function private.servicer_shortfall_period_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.closed_at is not null or new.last_minor <= 0 or new.peak_minor <> new.last_minor then
      raise exception 'shortfall period: opened while the servicer owes the dedicated account, its peak that amount'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.currency, new.since_at, new.opened_at)
     is distinct from (old.id, old.organization_id, old.currency, old.since_at, old.opened_at)
     or old.closed_at is not null
     or new.peak_minor <> (case when new.closed_at is null then greatest(old.peak_minor, new.last_minor)
                                else old.peak_minor end) then
    raise exception 'shortfall period %: what was logged never changes; its peak only rises until it closes', old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger servicer_shortfall_period_guard before insert or update on private.servicer_shortfall_period
  for each row execute function private.servicer_shortfall_period_guard();
alter table private.servicer_shortfall_period enable always trigger servicer_shortfall_period_guard;
create trigger servicer_shortfall_period_no_delete before delete or truncate on private.servicer_shortfall_period
  for each statement execute function private.refuse_delete();
alter table private.servicer_shortfall_period enable always trigger servicer_shortfall_period_no_delete;
create trigger servicer_shortfall_period_touch before update on private.servicer_shortfall_period
  for each row execute function private.touch_updated_at();
create trigger servicer_shortfall_period_change_log after insert or update or delete on private.servicer_shortfall_period
  for each row execute function private.log_change();
alter table private.servicer_shortfall_period enable row level security;
revoke all on private.servicer_shortfall_period from public, anon, authenticated, service_role;

-- The hourly job's last outcome per servicer ([critic] F8): `done` (it ran: what was needed is ordered), `missed` (the
-- servicer's lock was held past 2 s: skipped until the next hour), `failed` (any other error). The nightly's
-- top_up_order_failed reads it: three consecutive misses, or a failure.
create table private.top_up_order_state (
  organization_id uuid primary key references public.organization (id),
  last_outcome text not null check (last_outcome in ('done', 'missed', 'failed')),
  consecutive_misses integer not null default 0 check (consecutive_misses >= 0),
  last_ordered integer not null default 0 check (last_ordered >= 0),
  last_error text check (length(last_error) <= 2000),
  last_run_at timestamptz not null,
  updated_at timestamptz not null default now()
);
comment on table private.top_up_order_state is
  'The hourly top-up job''s last outcome per servicer (done, missed under the lock timeout, failed) for the nightly.';
create trigger top_up_order_state_no_delete before delete or truncate on private.top_up_order_state
  for each statement execute function private.refuse_delete();
alter table private.top_up_order_state enable always trigger top_up_order_state_no_delete;
create trigger top_up_order_state_touch before update on private.top_up_order_state
  for each row execute function private.touch_updated_at();
create trigger top_up_order_state_change_log after insert or update or delete on private.top_up_order_state
  for each row execute function private.log_change('organization_id');
alter table private.top_up_order_state enable row level security;
revoke all on private.top_up_order_state from public, anon, authenticated, service_role;

-- Keyed reads (ARCHITECTURE §4): the servicer's sweeps and top-ups in flight (top_up_needed, every call of the hourly
-- job and of the pages), an own account's top-ups newest first (« Approvisionnements du compte dédié »), the servicer's
-- advances, fees and losses by their recording time (the periods' entries).
create index bank_transfer_servicer_flight_idx on public.bank_transfer (organization_id, currency, kind)
  where kind in ('sweep', 'top_up') and status in ('ordered', 'in_file');
create index bank_transfer_top_up_idx on public.bank_transfer (debtor_bank_account_id, created_at desc)
  where kind = 'top_up';
create index ledger_entry_servicer_debt_posted_idx on public.ledger_entry (organization_id, posted_at)
  where entry_type in ('client_advance', 'bank_fee', 'servicer_loss');

-- Why a line waits for ops (constraint redefined from 20261117090000_transfer_line_foundations.sql line 52): M2c-7e-1
-- ([critic] M7-MONEY-4) a credit naming a cancelled top-up, executed by the bank all the same
-- (« Approvisionnement annulé puis exécuté par la banque »: ops book it with no transfer). Nothing else changes.
alter table public.bank_debit_review drop constraint bank_debit_review_reason_check,
  add constraint bank_debit_review_reason_check check (reason in ('no_candidate', 'ambiguous', 'amount_differs',
    'partial_return', 'refund_not_pending', 'already_returned', 'changed', 'payment_returned', 'before_previous_return',
    'posting_failed', 'top_up_not_found', 'top_up_differs', 'client_credit', 'own_transfer_out',
    'cancelled_transfer_debited', 'transfer_debited_twice', 'transfer_not_handed_out', 'transfer_unknown',
    'transfer_differs', 'run_not_in_flight', 'batch_partial', 'batch_mixed', 'return_differs', 'return_before_debit',
    'own_transfer_line', 'unplanned_payout_return', 'return_debit_pending', 'top_up_cancelled_credit'));

------------------------------------------------------------------------------------------
-- What is needed, and the hourly order (plan §7.1; design §13 #4; [critic] F8)
------------------------------------------------------------------------------------------

-- An amount as French text (« 1 500,00 € »): the top-up's reason. Integer minor units, no float.
create or replace function private.amount_fr(p_minor bigint, p_currency char(3))
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case when p_minor < 0 then '-' else '' end
         || regexp_replace((abs(p_minor) / 100)::text, '(\d)(?=(\d{3})+$)', '\1 ', 'g')
         || ',' || lpad((abs(p_minor) % 100)::text, 2, '0')
         || case when p_currency = 'EUR' then ' €' else ' ' || p_currency end;
$$;

-- Σ 4679 of the servicer in the currency (> 0: the servicer owes the dedicated account; < 0: its share not yet swept).
-- Keyed: its due_to_servicer accounts by ledger_account_org_book_idx, their postings by ledger_posting_balance_idx (an
-- index-only read of the servicer's own postings, never another servicer's), whatever the statistics.
create or replace function private.servicer_owed_minor(p_organization_id uuid, p_currency char(3))
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(sum(p.amount_minor), 0)::bigint
  from (select la.id from public.ledger_account la
        where la.organization_id = p_organization_id and la.book = 'due_to_servicer' and la.currency = p_currency
        offset 0) la
  cross join lateral (select q.amount_minor from public.ledger_posting q where q.ledger_account_id = la.id offset 0) p;
$$;

-- What the servicer must top up now (design §13 #4): max(0, Σ 4679 + the sweeps ordered or in a file − the top-ups
-- ordered or in a file). While 4679 holds the servicer's money awaiting the sweep (Σ 4679 < 0), an advance or a fee only
-- reduces it (ops critique #16). A filed top-up leaves the formula when its credit is booked ([critic] M7-MONEY-4).
-- Keyed: the sweeps and top-ups in flight by bank_transfer_servicer_flight_idx (constants prove its predicate).
create or replace function private.top_up_needed(p_organization_id uuid, p_currency char(3))
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select greatest(0, private.servicer_owed_minor(p_organization_id, p_currency)
                     + coalesce((select sum(x.amount_minor) from public.bank_transfer x
                                 where x.organization_id = p_organization_id and x.currency = p_currency
                                   and x.kind = 'sweep' and x.status in ('ordered', 'in_file')), 0)
                     - coalesce((select sum(x.amount_minor) from public.bank_transfer x
                                 where x.organization_id = p_organization_id and x.currency = p_currency
                                   and x.kind = 'top_up' and x.status in ('ordered', 'in_file')), 0))::bigint;
$$;

-- A top-up in_file of an own-account file of its servicer: the file is the one it is in, its debtor the top-up's own
-- account (purpose own) of the same servicer, and the file holds it. The one predicate both twins read (the SQL
-- re-check, cancel_top_up, and the debit job's loader for decide_line's `transfer_filed_own`). Keyed: the transfer, its
-- file, the file's account, the item — each by its key.
create or replace function private.top_up_in_own_file(p_transfer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce((
    select true
    from (select t.id, t.organization_id, t.kind, t.status, t.debtor_bank_account_id, t.transfer_file_id
          from public.bank_transfer t where t.id = p_transfer_id offset 0) t
    cross join lateral (select f.organization_id, f.debtor_bank_account_id from public.transfer_file f
                        where f.id = t.transfer_file_id offset 0) f
    cross join lateral (select a.organization_id, a.purpose from public.bank_account a
                        where a.id = f.debtor_bank_account_id offset 0) a
    where t.kind = 'top_up' and t.status = 'in_file' and f.organization_id = t.organization_id
      and f.debtor_bank_account_id = t.debtor_bank_account_id and a.purpose = 'own'
      and a.organization_id = t.organization_id
      and exists (select 1 from public.transfer_file_item i where i.file_id = t.transfer_file_id and i.transfer_id = t.id)),
    false);
$$;

-- The bank executed this top-up: a credit carrying its TOP id on the account it credits (bank_transaction_end_to_end_idx
-- by the id, the account and the direction checked on the lines found).
create or replace function private.top_up_credit_seen(p_transfer_id uuid)
returns boolean
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select count(*) > 0
  from (select t.end_to_end_id, t.creditor_bank_account_id from public.bank_transfer t
        where t.id = p_transfer_id offset 0) t
  cross join lateral (select x.bank_account_id, x.direction from public.bank_transaction x
                      where x.end_to_end_id = t.end_to_end_id offset 0) x
  where x.bank_account_id = t.creditor_bank_account_id and x.direction = 'credit';
$$;

-- The shortfall log's step for one servicer and currency, Σ 4679 as the job sees it now (under the remit lock).
create or replace function private.shortfall_log(p_organization_id uuid, p_currency char(3), p_owed bigint,
                                                 p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  p private.servicer_shortfall_period;
  v_since timestamptz;
begin
  select * into p from private.servicer_shortfall_period s
  where s.organization_id = p_organization_id and s.currency = p_currency and s.closed_at is null
  for update;
  if p_owed > 0 then
    if p.id is null then
      select greatest(least(s.last_run_at, p_now), p_now - interval '1 day') into v_since
      from private.top_up_order_state s where s.organization_id = p_organization_id;
      insert into private.servicer_shortfall_period (organization_id, currency, since_at, opened_at, peak_minor,
                                                     last_minor)
      values (p_organization_id, p_currency, coalesce(v_since, p_now - interval '1 hour'), p_now, p_owed, p_owed);
    elsif p.last_minor <> p_owed then
      update private.servicer_shortfall_period set last_minor = p_owed, peak_minor = greatest(peak_minor, p_owed)
      where id = p.id;
    end if;
  elsif p.id is not null then
    update private.servicer_shortfall_period set closed_at = p_now, last_minor = p_owed where id = p.id;
  end if;
end;
$$;

-- The hourly job's step for one servicer (the worker's `top_ups` message, in that message's own transaction: [critic] F8
-- — the advisory locks of one servicer never wait on another's). lock_timeout 2 s: a servicer whose lock is held (a
-- generation, a « Désimputer », the debit job) raises 55P03 and the worker records a miss, the next hour tries again.
-- Per active dedicated account (one per currency, founder #14): the shortfall log, then — when something is needed and
-- the servicer's own account (servicer_billing_settings) is active in that currency — one top-up of exactly what is
-- needed, as request_top_up builds it (debtor own, creditor dedicated, the servicer's legal name as payee, a TOP id,
-- « APPROVISIONNEMENT COMPTE DEDIE TOP… », requested today, ordered by nobody, the automatic reason). Idempotent by the
-- formula (an ordered top-up lowers what is needed); never cancels an order (ops may have typed it at their bank); any
-- amount above zero (founder Q3). The number of top-ups ordered.
create or replace function private.order_due_top_up(p_organization_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  c public.bank_account;
  o public.bank_account;
  v_own uuid;
  v_owed bigint;
  v_need bigint;
  v_n integer := 0;
  v_name text;
  v_e2e text;
  v_now timestamptz;
begin
  select s.own_bank_account_id into v_own from public.servicer_billing_settings s
  where s.organization_id = p_organization_id;
  -- lock order (ADR-0014): the rows (the servicer's dedicated accounts and its own account, in id order, as
  -- request_top_up), then the allocation and remit locks — every writer of 4679 holds the remit lock
  perform 1 from public.bank_account b
  where b.organization_id = p_organization_id and b.status = 'active'
    and (b.purpose = 'client_funds' or b.id = v_own)
  order by b.id for share;
  perform private.remittance_command_locks(p_organization_id, true);
  v_now := clock_timestamp();
  select left(btrim(legal_name), 70) into v_name from public.organization where id = p_organization_id;
  for c in select b.* from public.bank_account b
           where b.organization_id = p_organization_id and b.purpose = 'client_funds' and b.status = 'active'
           order by b.currency, b.id loop
    v_owed := private.servicer_owed_minor(p_organization_id, c.currency);
    perform private.shortfall_log(p_organization_id, c.currency, v_owed, v_now);
    v_need := private.top_up_needed(p_organization_id, c.currency);
    continue when v_need <= 0;
    o := null;
    select a.* into o from public.bank_account a
    where a.id = v_own and a.organization_id = p_organization_id and a.purpose = 'own' and a.status = 'active'
      and a.currency = c.currency;
    continue when o.id is null;     -- the nightly's top_up_account_missing says so
    v_e2e := 'TOP' || upper(substr(md5(gen_random_uuid()::text), 1, 12));
    insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id, creditor_bank_account_id, currency,
                                      amount_minor, payee_name, payee_iban, payee_bic, end_to_end_id, remittance_info,
                                      requested_execution_date, reason, ordered_by, created_at)
    values (p_organization_id, 'top_up', o.id, c.id, c.currency, v_need, v_name, c.iban, c.bic, v_e2e,
            'APPROVISIONNEMENT COMPTE DEDIE ' || v_e2e, private.paris_today(),
            'Approvisionnement automatique : le cabinet doit ' || private.amount_fr(v_need, c.currency)
              || ' au compte dédié (avances, frais, pertes)', null, clock_timestamp());
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- The worker records each run's outcome (after the step's own savepoint, so a miss is recorded although the step was
-- rolled back): `done` resets the misses, `missed` counts one more, `failed` keeps them; the error's text kept.
create or replace function private.record_top_up_order(p_organization_id uuid, p_outcome text, p_ordered integer,
                                                       p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_outcome is null or p_outcome not in ('done', 'missed', 'failed') then
    raise exception 'top-up order: its outcome is done, missed or failed' using errcode = 'check_violation';
  end if;
  insert into private.top_up_order_state as s (organization_id, last_outcome, consecutive_misses, last_ordered,
                                               last_error, last_run_at)
  values (p_organization_id, p_outcome, case when p_outcome = 'missed' then 1 else 0 end,
          greatest(coalesce(p_ordered, 0), 0), left(p_error, 2000), clock_timestamp())
  on conflict (organization_id) do update
    set last_outcome = excluded.last_outcome,
        consecutive_misses = case excluded.last_outcome when 'done' then 0
                                                        when 'missed' then s.consecutive_misses + 1
                                                        else s.consecutive_misses end,
        last_ordered = excluded.last_ordered, last_error = excluded.last_error, last_run_at = excluded.last_run_at;
end;
$$;

-- pg_cron `servicer-top-ups` (minute 37 of every hour): one `top_ups` message per servicer with an active dedicated
-- account (the remittances-schedule pattern, 20261112090000 line 2405).
create or replace function private.queue_top_ups()
returns integer
language sql
security definer
set search_path = ''
as $$
  with orgs as (
    select o.id from public.organization o
    where o.kind = 'servicer'
      and exists (select 1 from public.bank_account b where b.organization_id = o.id and b.purpose = 'client_funds'
                    and b.status = 'active')),
  sent as (select pgmq.send('remittances', jsonb_build_object('type', 'top_ups', 'organization_id', id)) as m
           from orgs)
  select count(*)::integer from sent;
$$;
select cron.schedule('servicer-top-ups', '37 * * * *', 'select private.queue_top_ups()');

------------------------------------------------------------------------------------------
-- The two fail-closed guards, one exemption each ([check 1] gap 4)
------------------------------------------------------------------------------------------

-- private.transfer_file_guard, redefined from 20261115090000_transfers_files.sql (line 559; same signature and settings,
-- its trigger and grants unchanged). M2c-7e-1 ([check 1] gap 4): on INSERT the debtor may also be an active own account
-- of the file's servicer (same IBAN rule); the fail-closed rule on closing a downloaded or sent file is skipped only when
-- the file's debtor is an own account (private.transfer_file_item_guard: such a file holds only top-ups). Every other
-- rule unchanged.
create or replace function private.transfer_file_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'pending' or new.download_count <> 0 then
      raise exception 'transfer file: starts pending, never downloaded' using errcode = 'check_violation';
    end if;
    -- M2c-7e-1 ([check 1] gap 4): or an active own account of the file's servicer (the own account's top-up file; the
    -- account's servicer is the file's by the foreign key), the same IBAN rule
    if not exists (select 1 from public.bank_account b where b.id = new.debtor_bank_account_id
                     and b.purpose in ('client_funds', 'own') and b.status = 'active' and b.iban = new.debtor_iban) then
      raise exception 'transfer file: from an active client_funds account, or an active own account, of the servicer'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.debtor_bank_account_id, new.currency, new.number, new.msg_id, new.pain_version,
      new.created_at_iso, new.initiating_party, new.debtor_name, new.debtor_iban, new.debtor_bic, new.nb_of_txs,
      new.ctrl_sum_minor, new.first_execution_date, new.last_execution_date, new.late_reason, new.cash_check, new.held,
      new.job_token, new.created_by, new.created_at)
     is distinct from
     (old.id, old.organization_id, old.debtor_bank_account_id, old.currency, old.number, old.msg_id, old.pain_version,
      old.created_at_iso, old.initiating_party, old.debtor_name, old.debtor_iban, old.debtor_bic, old.nb_of_txs,
      old.ctrl_sum_minor, old.first_execution_date, old.last_execution_date, old.late_reason, old.cash_check, old.held,
      old.job_token, old.created_by, old.created_at)
     or (old.file_sha256 is not null and (new.file_sha256, new.size_bytes, new.storage_path, new.xsd_validated,
                                          new.renderer_version, new.generated_at)
                                         is distinct from (old.file_sha256, old.size_bytes, old.storage_path,
                                                           old.xsd_validated, old.renderer_version, old.generated_at))
     or new.download_count < old.download_count
     or (old.first_downloaded_at is not null and (new.first_downloaded_at, new.first_downloaded_by)
                                                 is distinct from (old.first_downloaded_at, old.first_downloaded_by))
     or (old.sent_marked_at is not null and (new.sent_marked_at, new.sent_marked_by)
                                            is distinct from (old.sent_marked_at, old.sent_marked_by))
     or (old.closed_at is not null and (new.closed_at, new.closed_by, new.close_reason, new.close_attestation,
                                        new.superseded_by)
                                       is distinct from (old.closed_at, old.closed_by, old.close_reason,
                                                         old.close_attestation, old.superseded_by))
     or (new.status <> old.status and not (
           (old.status = 'pending' and new.status in ('generated', 'superseded', 'failed'))
           or (old.status = 'generated' and new.status in ('downloaded', 'superseded'))
           or (old.status = 'downloaded' and new.status in ('sent', 'superseded', 'rejected'))
           or (old.status = 'sent' and new.status in ('superseded', 'rejected'))))
     or (new.status = old.status and old.status in ('superseded', 'rejected', 'failed')) then
    raise exception 'transfer file %: what was generated never changes, its status only moves forward', old.number
      using errcode = 'check_violation';
  end if;
  -- review round 5 (fail-closed): a file handed out to ops is not closed while cancellation after download is off,
  -- whoever writes it (public.confirm_transfer_file_cancellation refuses first: `bank_booking_required`)
  -- M2c-7e-1 ([check 1] gap 4): skipped only for a file whose debtor is an own account, which holds only top-ups
  -- (private.transfer_file_item_guard): a top-up executed after its file's cancellation only adds the servicer's own
  -- money to the dedicated account; no client is paid twice
  if old.status in ('downloaded', 'sent') and new.status in ('superseded', 'rejected')
     and not private.switch_on('downloaded_file_cancellation')
     and not exists (select 1 from public.bank_account b where b.id = old.debtor_bank_account_id and b.purpose = 'own') then
    raise exception 'transfer file %: no cancellation of a downloaded file: cancellation after download is switched off until M2c-6b',
      old.number using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

-- private.bank_transfer_guard, redefined from 20261115090000_transfers_files.sql (line 742; same signature and settings,
-- its trigger and grants unchanged). M2c-7e-1 ([check 1] gap 4): the fail-closed rule on leaving a downloaded file is
-- skipped only for kind top_up whose file's debtor is an own account (« Annuler le fichier » of an own-account file,
-- whatever the switch; cancel_top_up of a filed top-up). Every other rule unchanged.
create or replace function private.bank_transfer_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'ordered' or new.transfer_file_id is not null then
      raise exception 'bank transfer: starts ordered' using errcode = 'check_violation';
    end if;
    if new.kind = 'top_up' and not (
         exists (select 1 from public.bank_account b where b.id = new.debtor_bank_account_id and b.purpose = 'own'
                   and b.status = 'active')
         and exists (select 1 from public.bank_account b where b.id = new.creditor_bank_account_id
                       and b.purpose = 'client_funds' and b.status = 'active'
                       and b.iban = new.payee_iban)) then
      raise exception 'bank transfer: a top-up goes from an active own account to an active client_funds account'
        using errcode = 'check_violation';
    end if;
    if new.kind = 'sweep' and not (
         exists (select 1 from public.bank_account b where b.id = new.debtor_bank_account_id
                   and b.purpose = 'client_funds' and b.status = 'active')
         and exists (select 1 from public.bank_account b where b.id = new.creditor_bank_account_id
                       and b.purpose = 'own' and b.status = 'active' and b.iban = new.payee_iban)) then
      raise exception 'bank transfer: a sweep goes from an active client_funds account to an active own account'
        using errcode = 'check_violation';
    end if;
    if new.kind = 'payout' and not exists (select 1 from public.organization c where c.id = new.client_organization_id
                                             and c.servicer_organization_id = new.organization_id) then
      raise exception 'bank transfer: a payout goes to a client of the servicer' using errcode = 'check_violation';
    end if;
    if new.run_id is not null and not exists (select 1 from public.remittance_run r where r.id = new.run_id
                                             and r.client_organization_id = new.client_organization_id
                                             and r.currency = new.currency) then
      raise exception 'bank transfer: a payout belongs to a run of its client' using errcode = 'check_violation';
    end if;
    if new.kind = 'refund' and not exists (select 1 from public.bank_account b where b.id = new.debtor_bank_account_id
                                             and b.purpose = 'client_funds') then
      raise exception 'bank transfer: a refund goes out of a client_funds account' using errcode = 'check_violation';
    end if;
    -- review round 3 (E1): a re-issue orders again exactly what the cancelled payout or refund ordered, under a new id
    if new.replaces_transfer_id is not null and not exists (
         select 1 from public.bank_transfer o where o.id = new.replaces_transfer_id and o.status = 'cancelled'
           and o.kind in ('payout', 'refund') and o.transfer_file_id is not null
           and (o.organization_id, o.client_organization_id, o.kind, o.debtor_bank_account_id, o.currency, o.run_id,
                o.amount_minor, o.payee_name, o.payee_iban, o.payee_bic, o.requested_execution_date)
               is not distinct from
               (new.organization_id, new.client_organization_id, new.kind, new.debtor_bank_account_id, new.currency,
                new.run_id, new.amount_minor, new.payee_name, new.payee_iban, new.payee_bic,
                new.requested_execution_date)
           and o.end_to_end_id <> new.end_to_end_id) then
      raise exception 'bank transfer: a re-issue orders again what a cancelled payout or refund of a file ordered'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.client_organization_id, new.kind, new.debtor_bank_account_id,
      new.creditor_bank_account_id, new.currency, new.run_id,
      new.amount_minor, new.payee_name, new.payee_iban, new.payee_bic, new.end_to_end_id, new.remittance_info,
      new.requested_execution_date, new.reason, new.ordered_by, new.created_at, new.replaces_transfer_id)
     is distinct from
     (old.id, old.organization_id, old.client_organization_id, old.kind, old.debtor_bank_account_id,
      old.creditor_bank_account_id, old.currency, old.run_id,
      old.amount_minor, old.payee_name, old.payee_iban, old.payee_bic, old.end_to_end_id, old.remittance_info,
      old.requested_execution_date, old.reason, old.ordered_by, old.created_at, old.replaces_transfer_id)
     or (old.entry_id is not null and new.entry_id is distinct from old.entry_id)
     or (old.return_entry_id is not null and new.return_entry_id is distinct from old.return_entry_id)
     or (new.status <> old.status and not (
           (old.status = 'ordered' and new.status in ('in_file', 'booked', 'cancelled'))
           or (old.status = 'in_file' and new.status in ('ordered', 'booked', 'cancelled'))
           or (old.status = 'booked' and new.status = 'returned')))
     -- the file: set when it goes in one, cleared when it comes back, kept after
     or (new.transfer_file_id is distinct from old.transfer_file_id and not (
           (old.status = 'ordered' and new.status = 'in_file' and old.transfer_file_id is null)
           or (old.status = 'in_file' and new.status = 'ordered' and new.transfer_file_id is null)))
     or (old.status = 'in_file' and new.status = 'ordered' and not exists (
           select 1 from public.transfer_file f where f.id = old.transfer_file_id
             and f.status in ('superseded', 'rejected', 'failed'))) then
    raise exception 'bank transfer %: what was ordered never changes, and its status only moves forward', old.id
      using errcode = 'check_violation';
  end if;
  -- review round 5 (fail-closed): a transfer of a file downloaded at least once does not leave it — cancelled, or back
  -- to ordered — while cancellation after download is off, whoever writes it (booked by its debit, it does)
  -- M2c-7e-1 ([check 1] gap 4): skipped only for a top-up whose file's debtor is an own account (such a file holds only
  -- top-ups: private.transfer_file_item_guard); payouts, refunds and sweeps stay fail-closed
  if old.status = 'in_file' and new.status in ('ordered', 'cancelled')
     and exists (select 1 from public.transfer_file f where f.id = old.transfer_file_id and f.download_count > 0)
     and not private.switch_on('downloaded_file_cancellation')
     and not (old.kind = 'top_up'
              and exists (select 1 from public.transfer_file f join public.bank_account b on b.id = f.debtor_bank_account_id
                          where f.id = old.transfer_file_id and b.purpose = 'own')) then
    raise exception 'bank transfer %: it stays in its downloaded file: cancellation after download is switched off until M2c-6b',
      old.id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

------------------------------------------------------------------------------------------
-- The own-account top-up file (plan §7.2; founder Q14 default a)
------------------------------------------------------------------------------------------

-- [check 1] gap 4: what an own-account file may hold. An item of a file whose debtor is an own account names a top-up
-- of that account and of the file's servicer; an item of a dedicated account's file never names a top-up. With it,
-- « the file's debtor is an own account » means « the file holds only top-ups », which the two exemptions of
-- private.transfer_file_guard and private.bank_transfer_guard rely on. A statement trigger (the item table had none),
-- every statement's new items read once by their keys.
create or replace function private.transfer_file_item_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
begin
  if exists (select 1
             from (select n.file_id, n.transfer_id, n.organization_id from new_items n) n
             cross join lateral (select f.organization_id, f.debtor_bank_account_id from public.transfer_file f
                                 where f.id = n.file_id offset 0) f
             cross join lateral (select a.purpose from public.bank_account a where a.id = f.debtor_bank_account_id
                                 offset 0) a
             cross join lateral (select t.kind, t.organization_id, t.debtor_bank_account_id from public.bank_transfer t
                                 where t.id = n.transfer_id offset 0) t
             where (a.purpose = 'own' and (t.kind <> 'top_up' or t.debtor_bank_account_id <> f.debtor_bank_account_id
                                           or t.organization_id <> f.organization_id
                                           or n.organization_id <> f.organization_id))
                or (a.purpose <> 'own' and t.kind = 'top_up')) then
    raise exception 'transfer file item: a top-up only in an own-account file, and only top-ups there'
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger transfer_file_item_guard after insert on public.transfer_file_item
  referencing new table as new_items for each statement execute function private.transfer_file_item_guard();
alter table public.transfer_file_item enable always trigger transfer_file_item_guard;

-- An own-account file closed (superseded with its reason): its top-ups still in it ordered again (a file not
-- downloaded, superseded by the next one or refused at its first download; after « Annuler le fichier » none is left in
-- it); review round 1 (CC-2): or failed, when the transfer_file job could not write it (private.transfer_file_failed). Only top-ups (private.transfer_file_item_guard): no run, payout, refund or sweep to follow, unlike
-- private.transfer_file_release, whose run update reads every transfer of a run when the statistics are stale
-- (test_top_up_reads_integration.py: 6,745 rows for a file of two top-ups). Keyed: the file, its top-ups by
-- bank_transfer_file_idx.
create or replace function private.top_up_file_close(p_file_id uuid, p_reason text, p_superseded_by uuid,
                                                     p_status text default 'superseded')
returns integer
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  f public.transfer_file;
  v_n integer;
  v_id uuid;
begin
  if p_status is null or p_status not in ('superseded', 'failed') then
    raise exception 'top-up file close: superseded, or failed (the file job)' using errcode = 'check_violation';
  end if;
  select * into f from public.transfer_file where id = p_file_id for update;
  if not found or f.status in ('superseded', 'rejected', 'failed') then
    return 0;
  end if;
  update public.transfer_file set status = p_status, closed_at = clock_timestamp(), closed_by = auth.uid(),
    close_reason = p_reason, superseded_by = p_superseded_by, version = version + 1
  where id = f.id;
  -- the file's items by its key, each one's transfer by its own key with its file, status and kind checked on the row,
  -- then updated by its key with its status re-checked (a statement naming the status or the kind could be planned
  -- with the in-flight indexes, every servicer's top-ups in flight read under stale statistics). Review round 2: not
  -- by bank_transfer_file_idx — under the planted statistics the planner may serve `transfer_file_id = f.id` from
  -- bank_transfer_filed_amount_idx instead (its predicate, transfer_file_id is not null, is implied), every filed
  -- transfer of every servicer read (test_top_up_reads_integration.py, once the table's indexes hold dead entries)
  v_n := 0;
  for v_id in select t.id
              from public.transfer_file_item i
              cross join lateral (select q.id, q.status, q.kind, q.transfer_file_id from public.bank_transfer q
                                  where q.id = i.transfer_id offset 0) t
              where i.file_id = f.id and t.transfer_file_id = f.id and t.status = 'in_file' and t.kind = 'top_up'
              order by t.id loop
    update public.bank_transfer set status = 'ordered', transfer_file_id = null
    where id = v_id and status = 'in_file' and kind = 'top_up';
    v_n := v_n + case when found then 1 else 0 end;
  end loop;
  return v_n;
end;
$$;

-- « Générer le fichier (compte propre) » (plan §7.2): admins and ops managers at aal2; an active own account in EUR
-- (`not_an_own_account`, `not_eur`); one live top-up file per own account (a pending or generated one not downloaded yet
-- is superseded: its top-ups come in this one, a new MsgId); its items, every `ordered` top-up of that account
-- (`nothing_to_file`), in one PmtInf per execution date: ReqdExctnDt today before the account's cut-off
-- (servicer_billing_settings.bank_cutoff), else the next business day (private.transfer_earliest_execution_date); never
-- one whose credit is already on a statement (review round 1, MONEY-BANK-2); no
-- cash check (the own account's statements are not imported, design R12), no sweep, no per-client cap. The
-- `transfer_file {file}` job writes it (Dbtr the own account: the writer takes the debtor from the file). Lock order: the
-- account row, the allocation then remit locks, then the files and transfers (generate_transfer_file's). Idempotency key
-- and request hash.
create or replace function public.generate_top_up_file(p_idempotency_key text, p_own_bank_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set enable_seqscan = off
as $$
declare
  b public.bank_account;
  v_request jsonb := jsonb_build_object('own_bank_account_id', p_own_bank_account_id);
  v_result jsonb;
  v_now timestamptz;
  v_today date;
  v_earliest date;
  v_file uuid := gen_random_uuid();
  v_token uuid := gen_random_uuid();
  v_number text;
  v_name text;
  v_superseded uuid[];
  v_sum bigint;
  v_n integer;
  v_offset integer;
begin
  select * into b from public.bank_account where id = p_own_bank_account_id;
  if not found or not private.has_role(b.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('generate_top_up_file', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if b.purpose <> 'own' or b.status <> 'active' then
    raise exception 'top-up file refused: not_an_own_account' using errcode = 'check_violation';
  end if;
  if b.currency <> 'EUR' then
    raise exception 'top-up file refused: not_eur' using errcode = 'check_violation';
  end if;
  perform 1 from public.bank_account x where x.id = b.id for share;
  perform private.remittance_command_locks(b.organization_id, true);
  v_now := clock_timestamp();
  v_today := (v_now at time zone 'Europe/Paris')::date;
  v_earliest := private.transfer_earliest_execution_date(b.id, v_now);

  select coalesce(array_agg(f.id order by f.id), '{}') into v_superseded from public.transfer_file f
  where f.debtor_bank_account_id = b.id and f.status in ('pending', 'generated');
  perform private.top_up_file_close(x, 'Remplacé par un nouveau fichier', v_file) from unnest(v_superseded) x;

  -- the account's ordered transfers by its key (fenced: whatever the statistics, never another account's; the kind
  -- outside the fence, never planned with the in-flight indexes). Review round 2 (own-account-history-reads): the
  -- status inside the fence — every index it can use holds ordered transfers only (bank_transfer_to_file_idx,
  -- bank_transfer_debtor_idx), never the account's booked past (test_top_up_reads_integration.py: 10,033 rows read
  -- for a file of two beside 5,000 booked top-ups)
  perform 1 from public.bank_transfer t
  where t.id = any (array(select q.id from (select x.id, x.kind from public.bank_transfer x
                                           where x.debtor_bank_account_id = b.id and x.status = 'ordered'
                                           offset 0) q
                          where q.kind = 'top_up'))
  order by t.id for update;
  drop table if exists pg_temp._tuf;
  -- (review round 1, MONEY-BANK-2) never one whose credit (its TOP id) is already on a statement of the dedicated
  -- account: the bank executed it, the funds pass (or ops) books it — filed again, it would be executed twice
  create temp table _tuf on commit drop as
  select t.id, t.amount_minor, t.created_at, greatest(t.requested_execution_date, v_earliest) as execution_date
  from (select q.* from public.bank_transfer q where q.debtor_bank_account_id = b.id and q.status = 'ordered'
        offset 0) t
  where t.kind = 'top_up' and t.currency = b.currency and not private.top_up_credit_seen(t.id);
  select coalesce(sum(x.amount_minor), 0), count(*) into v_sum, v_n from pg_temp._tuf x;
  if v_n = 0 then
    raise exception 'top-up file refused: nothing_to_file' using errcode = 'check_violation';
  end if;

  select legal_name into v_name from public.organization where id = b.organization_id;
  v_number := private.transfer_file_number(v_today, nextval('private.transfer_file_number_seq'));
  -- CreDtTm frozen now, Paris time with its offset
  v_offset := (extract(epoch from (v_now at time zone 'Europe/Paris') - (v_now at time zone 'UTC')) / 60)::integer;
  insert into public.transfer_file (id, organization_id, debtor_bank_account_id, currency, number, msg_id, pain_version,
                                    created_at_iso, initiating_party, debtor_name, debtor_iban, debtor_bic, nb_of_txs,
                                    ctrl_sum_minor, first_execution_date, last_execution_date, late_reason, cash_check,
                                    held, job_token, created_by)
  select v_file, b.organization_id, b.id, b.currency, v_number, v_number, b.pain_version,
         to_char(v_now at time zone 'Europe/Paris', 'YYYY-MM-DD"T"HH24:MI:SS')
           || case when v_offset < 0 then '-' else '+' end
           || lpad((abs(v_offset) / 60)::text, 2, '0') || ':' || lpad((abs(v_offset) % 60)::text, 2, '0'),
         v_name, v_name, b.iban, b.bic, count(*), sum(x.amount_minor), min(x.execution_date), max(x.execution_date),
         null, '{"own_account": true}'::jsonb, '[]'::jsonb, v_token, auth.uid()
  from pg_temp._tuf x;
  insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id, pmt_inf_id, execution_date, late)
  select v_file, row_number() over (order by x.execution_date, x.created_at, x.id), x.id, b.organization_id,
         v_number || '-' || dense_rank() over (order by x.execution_date), x.execution_date, false
  from pg_temp._tuf x;
  -- (by our locked ids: a join with the temporary table, which has no statistics, read the table's whole primary key)
  update public.bank_transfer t set status = 'in_file', transfer_file_id = v_file
  where t.id = any (array(select x.id from pg_temp._tuf x));
  perform pgmq.send('remittances', jsonb_build_object('type', 'transfer_file', 'file_id', v_file, 'token', v_token));

  v_result := jsonb_build_object('file_id', v_file, 'number', v_number, 'status', 'pending', 'nb_of_txs', v_n,
                                 'ctrl_sum_minor', v_sum::text,
                                 'first_execution_date', (select min(x.execution_date) from pg_temp._tuf x),
                                 'superseded', to_jsonb(v_superseded));
  perform private.command_record('generate_top_up_file', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Annuler le fichier » of an own-account file (plan §7.2): before or after download, WHATEVER THE SWITCH — a top-up
-- executed after its cancellation only adds the servicer's own money to the dedicated account (booked as an
-- approvisionnement by ops, then swept back); no client is paid twice, which is what the switch guards. [critic] F13
-- first: `not_a_top_up_file` unless the file's debtor is an active own account of its servicer and every item a top-up
-- (a payout file never passes here: private.transfer_file_release would return a downloaded file's payouts to the
-- queue). Its top-ups still in_file → cancelled (the exemption of private.bank_transfer_guard), the file superseded with
-- the reason (private.top_up_file_close; the exemption of private.transfer_file_guard); `nothing_to_cancel` once none
-- is left; the next hour orders again what is still needed. Lock order: the account row, the allocation then remit locks, then the file and its transfers — the
-- download's order (transfer_file_download), so that the two never deadlock. Idempotency key and request hash.
create or replace function public.cancel_top_up_file(p_idempotency_key text, p_file_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set enable_seqscan = off
as $$
declare
  f public.transfer_file;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('file_id', p_file_id, 'reason', btrim(coalesce(p_reason, '')));
  v_result jsonb;
  v_n integer;
  v_ids uuid[];
begin
  select * into f from public.transfer_file where id = p_file_id;
  if not found or not private.has_role(f.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('cancel_top_up_file', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.bank_account a where a.id = f.debtor_bank_account_id
                   and a.organization_id = f.organization_id and a.purpose = 'own' and a.status = 'active')
     or exists (select 1 from public.transfer_file_item i
                cross join lateral (select t.kind from public.bank_transfer t where t.id = i.transfer_id offset 0) t
                where i.file_id = f.id and t.kind <> 'top_up') then
    raise exception 'top-up file refused: not_a_top_up_file' using errcode = 'check_violation';
  end if;
  perform 1 from public.bank_account x where x.id = f.debtor_bank_account_id for share;
  perform private.remittance_command_locks(f.organization_id, true);
  select * into f from public.transfer_file where id = p_file_id for update;
  -- the file's transfers (locked: every transfer its items name, by their ids), then those still in it: each item's
  -- transfer by its key, its file, status and kind checked on the row (a statement naming the status or the kind
  -- could be planned with the in-flight indexes under stale statistics; review round 2: and `transfer_file_id = f.id`
  -- may be served from bank_transfer_filed_amount_idx, every filed transfer read — private.top_up_file_close's note)
  perform 1 from public.bank_transfer t
  where t.id = any (array(select i.transfer_id from public.transfer_file_item i where i.file_id = f.id))
  order by t.id for update;
  select coalesce(array_agg(t.id order by t.id), '{}') into v_ids
  from public.transfer_file_item i
  cross join lateral (select q.id, q.status, q.kind, q.transfer_file_id from public.bank_transfer q
                      where q.id = i.transfer_id offset 0) t
  where i.file_id = f.id and t.transfer_file_id = f.id and t.status = 'in_file' and t.kind = 'top_up';
  if f.status not in ('pending', 'generated', 'downloaded', 'sent') or cardinality(v_ids) = 0 then
    raise exception 'top-up file refused: nothing_to_cancel' using errcode = 'check_violation';
  end if;
  update public.bank_transfer t set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
    cancel_reason = 'Fichier ' || f.number || ' annulé : ' || v_reason
  where t.id = any (v_ids);
  get diagnostics v_n = row_count;
  perform private.top_up_file_close(f.id, v_reason, null);
  v_result := jsonb_build_object('file_id', f.id, 'status', 'superseded', 'cancelled', v_n);
  perform private.command_record('cancel_top_up_file', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- public.cancel_transfer_file, redefined from 20261116090000_debit_bookings.sql (line 4758; same signature and settings,
-- its grants restated below). M2c-7e-1 review round 1 (CC-2): an own-account file is refused `not_a_payout_file` (its
-- cancellation is « Annuler le fichier », whatever its status), before any lock. Nothing else changes.
create or replace function public.cancel_transfer_file(p_idempotency_key text, p_file_id uuid,
                                                       p_expected_version integer, p_reason text,
                                                       p_attestation text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  f public.transfer_file;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('file_id', p_file_id, 'expected_version', p_expected_version,
                                        'reason', btrim(coalesce(p_reason, '')), 'attestation', p_attestation);
  v_result jsonb;
  v_n integer;
begin
  select * into f from public.transfer_file where id = p_file_id;
  if not found or not private.has_role(f.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('cancel_transfer_file', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  -- M2c-7e-1 review round 1 (CC-2): an own-account file (its debtor the servicer's own account: only top-ups) is
  -- cancelled by « Annuler le fichier » (public.cancel_top_up_file), never here — transfer_file_release re-queues payouts
  -- and reads runs, which such a file has none of
  if exists (select 1 from public.bank_account b where b.id = f.debtor_bank_account_id and b.purpose = 'own') then
    raise exception 'transfer file refused: not_a_payout_file' using errcode = 'check_violation',
      hint = 'Fichier d''approvisionnement du compte propre : annulez-le par « Annuler le fichier ».';
  end if;
  perform private.transfer_file_lock_runs(f.id);
  perform private.remittance_command_locks(f.organization_id, true);
  select * into f from public.transfer_file where id = p_file_id for update;
  if p_expected_version is distinct from f.version then
    raise exception 'transfer file refused: version_changed' using errcode = 'check_violation';
  end if;
  -- review round 5 (fail-closed): a file handed out is not cancelled while cancellation after download is off
  if f.status in ('downloaded', 'sent') and not private.switch_on('downloaded_file_cancellation') then
    raise exception 'transfer file refused: bank_booking_required' using errcode = 'check_violation',
      hint = 'Fichier téléchargé : son annulation n''est pas encore disponible dans Collectoo. Gardez le fichier tel quel ; ses virements restent en cours jusqu''à ce que leurs débits soient comptabilisés depuis le relevé, à leur arrivée (de même, ensuite, le retour d''un virement que la banque du bénéficiaire renvoie). Un virement que la banque refuse avant son exécution, ou un fichier jamais déposé, n''apparaît sur aucun relevé : il reste « en cours » jusqu''à ce que l''annulation après téléchargement soit disponible. Vérifiez le relevé, voyez avec la banque et prévenez le support.';
  elsif f.status in ('downloaded', 'sent') then
    raise exception 'transfer file refused: cancellation_request_required' using errcode = 'check_violation',
      hint = 'Fichier téléchargé : demandez son annulation, relevé à l''appui ; une autre personne la confirme.';
  elsif f.status not in ('pending', 'generated') then
    raise exception 'transfer file refused: not_live' using errcode = 'check_violation';
  end if;
  if p_attestation is not null then
    raise exception 'transfer file refused: not_downloaded' using errcode = 'check_violation';
  end if;
  v_n := private.transfer_file_release(f.id, 'superseded', v_reason, null, null);
  v_result := jsonb_build_object('file_id', f.id, 'number', f.number, 'status', 'superseded', 'transfers_back', v_n);
  perform private.command_record('cancel_transfer_file', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


-- private.transfer_file_failed, redefined from 20261115090000_transfers_files.sql (line 1994; same signature and
-- settings, its grants restated below). M2c-7e-1 review round 1 (CC-2): an own-account file the job could not write is
-- closed `failed` by private.top_up_file_close (its top-ups ordered again, by key). Nothing else changes.
create or replace function private.transfer_file_failed(p_file_id uuid, p_token uuid, p_error text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.transfer_file;
begin
  select * into f from public.transfer_file where id = p_file_id;
  if not found or f.job_token <> p_token then
    return jsonb_build_object('status', 'skipped');
  end if;
  perform private.remittance_command_locks(f.organization_id, true);
  select * into f from public.transfer_file where id = p_file_id for update;
  if f.status <> 'pending' then
    return jsonb_build_object('status', 'skipped');
  end if;
  update public.transfer_file set error = left(coalesce(p_error, 'unknown error'), 2000) where id = f.id;
  -- M2c-7e-1 review round 1 (CC-2): an own-account file (only top-ups) by private.top_up_file_close, keyed — not
  -- transfer_file_release, whose run update reads every transfer in flight under stale statistics
  if exists (select 1 from public.bank_account b where b.id = f.debtor_bank_account_id and b.purpose = 'own') then
    perform private.top_up_file_close(f.id, 'Le fichier n''a pas pu être écrit', null, 'failed');
  else
    perform private.transfer_file_release(f.id, 'failed', 'Le fichier n''a pas pu être écrit', null, null);
  end if;
  return jsonb_build_object('status', 'failed', 'number', f.number);
end;
$$;


-- « Rattacher à TOP… » ([check 1] gap 12; plan §7.2): a credit from the own account that carries no TOP id (the bank
-- dropped the reference) booked as that top-up, so that no top-up stays ordered or in_file for ever (Collectoo would
-- order too little). Admins and ops managers at aal2; idempotency key and request hash. The line: an `own_transfer_in`
-- credit (as read, or released so) neither linked nor booked nor released (`not_an_own_credit`, `line_booked`) whose
-- end-to-end id is no TOP id (`carries_top_up_id`: that one books itself through the funds pass); the transfer: a top-up
-- of the line's servicer, ordered or in_file of an own-account file (`top_up_not_open`), of the line's amount and
-- currency, ordered to the line's account (`amount_differs`), from the own account the credit came from
-- (`not_its_own_account`, review round 1). Then one `_bank_booking` row (kind top_up, that transfer)
-- through private.post_bank_bookings(org, true): its re-check, under link_debit's top-up branch's locks, is the rule
-- (« bank booking refused: <code> » if anything changed since).
create or replace function public.book_top_up_credit(p_idempotency_key text, p_bank_transaction_id uuid,
                                                     p_transfer_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  x public.bank_transfer;
  v_kind text;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_out jsonb;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'transfer_id', p_transfer_id,
                                  'reason', v_reason);
  v_result := private.command_replay('book_top_up_credit', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  select coalesce((select r.released_kind from public.bank_duplicate_resolution r
                   where r.bank_transaction_id = t.id and r.decision = 'released'), t.kind) into v_kind;
  if t.direction <> 'credit' or v_kind <> 'own_transfer_in' then
    raise exception 'top-up credit refused: not_an_own_credit' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id) then
    raise exception 'top-up credit refused: line_booked' using errcode = 'check_violation';
  end if;
  if coalesce(t.end_to_end_id ~ '^TOP[0-9A-F]{12}$', false) then
    raise exception 'top-up credit refused: carries_top_up_id' using errcode = 'check_violation';
  end if;
  select * into x from public.bank_transfer where id = p_transfer_id;
  if not found or x.organization_id <> t.organization_id or x.kind <> 'top_up'
     or not (x.status = 'ordered' or (x.status = 'in_file' and private.top_up_in_own_file(x.id))) then
    raise exception 'top-up credit refused: top_up_not_open' using errcode = 'check_violation';
  end if;
  if x.amount_minor <> t.amount_minor or x.currency <> t.currency or x.creditor_bank_account_id <> t.bank_account_id then
    raise exception 'top-up credit refused: amount_differs' using errcode = 'check_violation';
  end if;
  -- review round 1 (MONEY-BANK-1): the credit came from the own account the top-up is ordered from (its IBAN the line's
  -- counterparty's) — a credit of own account A booked as the top-up of own account B would post −5122[B] and close
  -- B's top-up although B never paid it (the re-check refuses it too)
  if not exists (select 1 from public.bank_account a where a.id = x.debtor_bank_account_id
                   and a.iban = t.counterparty_iban) then
    raise exception 'top-up credit refused: not_its_own_account' using errcode = 'check_violation';
  end if;
  perform private.bank_booking_begin();
  insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method, decided_by, reason)
  values (1, t.id, 'top_up', x.id, 'ops', auth.uid(), v_reason);
  v_out := private.post_bank_bookings(t.organization_id, true);
  v_result := jsonb_build_object('status', 'booked', 'kind', 'top_up', 'result', v_out);
  perform private.command_record('book_top_up_credit', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The reads (« Virements » › Approvisionnements, « Débits et retours » › Rattacher, « Comptes bancaires » › Périodes)
------------------------------------------------------------------------------------------

-- « Approvisionnements du compte dédié » (plan §7.4): money staff of the servicer (aal2). What the servicer owes the
-- dedicated account now per currency (Σ 4679 and design §13 #4's need), and per active own account: its top-ups, newest
-- first (50: ordered automatically or by whom, their file), its files (20), whether a file can be generated. Keyed:
-- the accounts by the servicer, each one's top-ups by bank_transfer_top_up_idx, its files by transfer_file_account_idx.
create or replace function public.top_up_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_org uuid := (private.money_staff_org_ids())[1];
  v_needed jsonb;
  v_accounts jsonb;
begin
  if v_org is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'currency', c.currency, 'owed_minor', v.owed::text,
           -- (review round 2, needed-line-sweep-in-flight) what the servicer owes once its sweeps in flight are
           -- executed (design §13 #4's Σ4679 + sweeps ordered or in a file): « Virements » says « ne doit rien » only
           -- when it is ≤ 0 — Σ4679 alone may be < 0 while a sweep in a file takes that share and more away
           'owed_with_sweeps_minor', (v.owed + v.sweeps)::text,
           'needed_minor', private.top_up_needed(v_org, c.currency)::text,
           -- (review round 1, TUI-2) the top-ups in flight beyond what the servicer owes once its sweeps in flight are
           -- executed (a cancelled top-up's late credit booked while its re-order waits): executed, they come back
           -- with the next sweep. design §13 #4's terms, by bank_transfer_servicer_flight_idx
           'surplus_minor', greatest(0, v.tops - greatest(0, v.owed + v.sweeps))::text,
           'own_account', (select jsonb_build_object('id', a.id, 'label', a.label, 'iban_last4', right(a.iban, 4))
                           from public.servicer_billing_settings s join public.bank_account a on a.id = s.own_bank_account_id
                           where s.organization_id = v_org and a.status = 'active' and a.purpose = 'own'
                             and a.currency = c.currency))
         order by c.currency), '[]')
  into v_needed
  from (select distinct b.currency from public.bank_account b
        where b.organization_id = v_org and b.purpose = 'client_funds' and b.status = 'active') c
  -- (review round 2) Σ4679 and the sweeps and top-ups in flight read once per currency (fenced: never inlined into
  -- each use), the in-flight ones by bank_transfer_servicer_flight_idx (its constants prove the index's predicate)
  cross join lateral (
    select private.servicer_owed_minor(v_org, c.currency) as owed,
           coalesce((select sum(x.amount_minor) from public.bank_transfer x
                     where x.organization_id = v_org and x.currency = c.currency
                       and x.kind = 'sweep' and x.status in ('ordered', 'in_file')), 0)::bigint as sweeps,
           coalesce((select sum(x.amount_minor) from public.bank_transfer x
                     where x.organization_id = v_org and x.currency = c.currency
                       and x.kind = 'top_up' and x.status in ('ordered', 'in_file')), 0)::bigint as tops
    offset 0) v;
  select coalesce(jsonb_agg(jsonb_build_object(
           'bank_account_id', a.id, 'label', a.label, 'iban_last4', right(a.iban, 4), 'bic', a.bic,
           'currency', a.currency, 'pain_version', a.pain_version,
           'earliest_execution_date', private.transfer_earliest_execution_date(a.id, clock_timestamp()),
           -- the ordered top-ups a file would take (o, below), counted once
           'ordered_count', o.n,
           'can_generate', a.currency = 'EUR' and o.n > 0,
           'top_ups', coalesce((select jsonb_agg(jsonb_build_object(
                                  'transfer_id', t.id, 'end_to_end_id', t.end_to_end_id,
                                  'amount_minor', t.amount_minor::text, 'currency', t.currency, 'status', t.status,
                                  'requested_execution_date', t.requested_execution_date, 'created_at', t.created_at,
                                  'automatic', t.ordered_by is null,
                                  'ordered_by', (select coalesce(u.display_name, u.email) from public.app_user u
                                                 where u.id = t.ordered_by),
                                  'reason', t.reason, 'cancel_reason', t.cancel_reason, 'cancelled_at', t.cancelled_at,
                                  'file_id', t.transfer_file_id,
                                  'file_number', (select f.number from public.transfer_file f
                                                  where f.id = t.transfer_file_id),
                                  'cancellable', t.status = 'ordered'
                                                 or (t.status = 'in_file' and private.top_up_in_own_file(t.id)))
                                order by t.created_at desc, t.id)
                                -- the account's latest 50 (bank_transfer_top_up_idx, in its order)
                                from (select q.* from public.bank_transfer q
                                      where q.debtor_bank_account_id = a.id and q.kind = 'top_up'
                                      order by q.created_at desc limit 50) t), '[]'),
           'files', coalesce((select jsonb_agg(jsonb_build_object(
                                'id', f.id, 'number', f.number, 'status', f.status, 'nb_of_txs', f.nb_of_txs,
                                'ctrl_sum_minor', f.ctrl_sum_minor::text, 'currency', f.currency,
                                'first_execution_date', f.first_execution_date,
                                'last_execution_date', f.last_execution_date, 'created_at', f.created_at,
                                'pain_version', f.pain_version, 'xsd_validated', f.xsd_validated,
                                'download_count', f.download_count, 'first_downloaded_at', f.first_downloaded_at,
                                'first_downloaded_by', (select coalesce(u.display_name, u.email) from public.app_user u
                                                        where u.id = f.first_downloaded_by),
                                'sent_marked_at', f.sent_marked_at, 'closed_at', f.closed_at,
                                'close_reason', f.close_reason, 'error', f.error, 'version', f.version,
                                -- the file's items, each one's transfer by its key (never a status scan; review
                                -- round 2: never `transfer_file_id = f.id`, which may be served from
                                -- bank_transfer_filed_amount_idx — private.top_up_file_close's note)
                                'top_ups_open', (select count(*)
                                                 from (select q.transfer_id from public.transfer_file_item q
                                                       where q.file_id = f.id offset 0) i
                                                 cross join lateral (select q.status, q.transfer_file_id
                                                                     from public.bank_transfer q
                                                                     where q.id = i.transfer_id offset 0) t
                                                 where t.status = 'in_file' and t.transfer_file_id = f.id),
                                'top_ups_booked', (select count(*)
                                                   from (select q.transfer_id from public.transfer_file_item q
                                                         where q.file_id = f.id offset 0) i
                                                   cross join lateral (select q.status from public.bank_transfer q
                                                                       where q.id = i.transfer_id offset 0) t
                                                   where t.status = 'booked'))
                              order by f.created_at desc, f.id)
                              -- the account's latest 20 files (transfer_file_account_idx, in its order)
                              from (select q.* from public.transfer_file q where q.debtor_bank_account_id = a.id
                                    order by q.created_at desc limit 20) f), '[]'))
         order by a.label, a.id), '[]')
  into v_accounts
  from public.bank_account a
  -- the account's ordered transfers by its key (an own account is the debtor of top-ups only), the kind filtered
  -- outside the fence: a statement naming the kind could be planned with the in-flight indexes
  -- (bank_transfer_servicer_flight_idx: every servicer's sweeps and top-ups in flight); (review round 1, MONEY-BANK-2)
  -- the ones a file takes: not those whose credit is already on a statement. Review round 2
  -- (own-account-history-reads): the status inside the fence — every index keyed by the account it can use then holds
  -- ordered transfers only (bank_transfer_to_file_idx, bank_transfer_debtor_idx), never the account's booked past —
  -- and counted once, never as an EXISTS (planned for its first row, it walked bank_transfer_org_idx by the status
  -- alone, every servicer's ordered transfers read: test_top_up_reads_integration.py)
  cross join lateral (select count(*)::integer as n
                      from (select q.id, q.kind from public.bank_transfer q
                            where q.debtor_bank_account_id = a.id and q.status = 'ordered' offset 0) t
                      where t.kind = 'top_up' and not private.top_up_credit_seen(t.id)) o
  where a.organization_id = v_org and a.purpose = 'own' and a.status = 'active';
  return jsonb_build_object('today', private.paris_today(), 'needed', v_needed, 'accounts', v_accounts,
                            'can_admin', private.has_role(v_org, array['admin']));
end;
$$;

-- « Rattacher à TOP… » (« Débits et retours »): for an own credit with no TOP id, the open top-ups (ordered, or in_file
-- of an own-account file) of its servicer, of its amount and currency, ordered to its account — money staff (aal2).
-- Review round 1: (MONEY-BANK-1) only those ordered from the own account the credit came from (its IBAN the line's
-- counterparty's; book_top_up_credit refuses any other: not_its_own_account), each with that account's label;
-- (CC-1) read through the servicer's in-flight top-ups (bank_transfer_servicer_flight_idx: its constants prove the
-- index's predicate, keyed by the servicer and currency), never a scan of every servicer's transfers of that amount.
create or replace function public.top_up_credit_options(p_bank_transaction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object('bank_transaction_id', t.id, 'top_ups', coalesce((
    select jsonb_agg(jsonb_build_object('transfer_id', x.id, 'end_to_end_id', x.end_to_end_id,
                                        'amount_minor', x.amount_minor::text, 'currency', x.currency,
                                        'status', x.status, 'created_at', x.created_at,
                                        'automatic', x.ordered_by is null,
                                        'file_number', (select f.number from public.transfer_file f
                                                        where f.id = x.transfer_file_id),
                                        'debtor_label', a.label, 'debtor_iban_last4', right(a.iban, 4))
                     order by x.created_at, x.id)
    from (select q.* from public.bank_transfer q
          where q.organization_id = t.organization_id and q.currency = t.currency and q.kind = 'top_up'
            and q.status in ('ordered', 'in_file') offset 0) x
    cross join lateral (select o.label, o.iban from public.bank_account o where o.id = x.debtor_bank_account_id
                        offset 0) a
    where x.creditor_bank_account_id = t.bank_account_id and x.amount_minor = t.amount_minor
      and a.iban = t.counterparty_iban
      and (x.status = 'ordered' or (x.status = 'in_file' and private.top_up_in_own_file(x.id)))), '[]'));
end;
$$;

-- « Périodes où le cabinet devait de l'argent au compte dédié » (« Comptes bancaires »; plan §7.1, OQ-38): money staff
-- of the servicer (aal2). Its periods, newest first (p_limit, 50 by default, at most 200), each with the advances, fees
-- and losses recorded from the job's previous run to its close (100 at most, and how many): their 4679 amount.
-- Keyed: the periods by servicer_shortfall_period_org_idx, the entries by ledger_entry_servicer_debt_posted_idx, each
-- one's postings by its key.
create or replace function public.servicer_shortfall_periods(p_organization_id uuid, p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  if p_organization_id is null or not private.has_role(p_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object('periods', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'currency', p.currency, 'since_at', p.since_at, 'opened_at', p.opened_at,
             'closed_at', p.closed_at, 'peak_minor', p.peak_minor::text, 'last_minor', p.last_minor::text,
             'entries', coalesce((select jsonb_agg(jsonb_build_object('entry_id', e.id, 'entry_type', e.entry_type,
                                                                      'posted_at', e.posted_at,
                                                                      'effective_date', e.effective_date,
                                                                      'amount_minor', e.amount_minor::text)
                                                   order by e.posted_at, e.id)
                                  from (select x.id, x.entry_type, x.posted_at, x.effective_date, d.amount_minor
                                        from (select q.id, q.entry_type, q.posted_at, q.effective_date
                                              from public.ledger_entry q
                                              where q.organization_id = p.organization_id
                                                and q.entry_type in ('client_advance', 'bank_fee', 'servicer_loss')
                                                and q.posted_at >= p.since_at
                                                and q.posted_at <= coalesce(p.closed_at, 'infinity'::timestamptz)
                                              order by q.posted_at, q.id limit 100) x
                                        cross join lateral (
                                          select sum(lp.amount_minor)::bigint as amount_minor
                                          from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                                                where q.entry_id = x.id offset 0) lp
                                          cross join lateral (select la.book, la.currency from public.ledger_account la
                                                              where la.id = lp.ledger_account_id offset 0) la
                                          where la.book = 'due_to_servicer' and la.currency = p.currency) d
                                        where d.amount_minor is not null) e), '[]'),
             'entry_count', (select count(*) from public.ledger_entry q
                             where q.organization_id = p.organization_id
                               and q.entry_type in ('client_advance', 'bank_fee', 'servicer_loss')
                               and q.posted_at >= p.since_at
                               and q.posted_at <= coalesce(p.closed_at, 'infinity'::timestamptz)))
           order by p.opened_at desc, p.id)
    from (select q.* from private.servicer_shortfall_period q where q.organization_id = p_organization_id
          order by q.opened_at desc limit v_limit) p), '[]'));
end;
$$;

-- public.transfer_file_download, redefined from 20261118090000_switch_on_prerequisites.sql (line 2296; same signature
-- and settings, its grants restated below). M2c-7e-1 (plan §7.2): a file whose debtor is an own account skips the cash
-- and sweep re-checks at its first download (a top-up of it cancelled or booked since its generation blocks it:
-- `file_blocked`, the file superseded, its other top-ups ordered again; review round 1, MONEY-BANK-2: so does one whose
-- credit is already on a statement, not booked yet: `top_up_credited`); the hash check, the download log, the
-- second-download warning and `file_executed` stay — for such a file, one of its top-ups booked or its TOP id credited
-- (private.top_up_credit_seen). And `set enable_seqscan = off` (test_top_up_reads_integration.py: under the statistics
-- the scale files leave, its keyed reads of the file's items — its own and private.transfer_file_lock_runs', which runs
-- under this setting — scanned every file's items: 20,048 rows for a file of two). Nothing else changes.
create or replace function public.transfer_file_download(p_file_id uuid, p_sha256 text,
                                                         p_acknowledged boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set enable_seqscan = off
as $$
declare
  f public.transfer_file;
  v_n integer;
  v_first text;
  v_now timestamptz;
  v_earliest date;
  v_blocked jsonb;
  v_cash jsonb;
  v_refused text;
  v_sweep_id uuid;
  v_sweep_minor bigint;
  v_share bigint;
  v_own boolean;
  v_run uuid;
begin
  select * into f from public.transfer_file where id = p_file_id;
  if not found or not private.has_role(f.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  -- the generation's locks (the account row, the allocation then remit locks), the file's runs first (ADR-0014 order)
  perform private.transfer_file_lock_runs(f.id);
  perform 1 from public.bank_account x where x.id = f.debtor_bank_account_id for share;
  perform private.remittance_command_locks(f.organization_id, true);
  select * into f from public.transfer_file where id = p_file_id for update;
  -- M2c-7e-1 (plan §7.2): an own-account file (its debtor the servicer's own account: only top-ups)
  v_own := exists (select 1 from public.bank_account b where b.id = f.debtor_bank_account_id and b.purpose = 'own');
  if f.status = 'pending' then
    raise exception 'transfer file refused: not_ready' using errcode = 'check_violation';
  end if;
  if f.status not in ('generated', 'downloaded', 'sent') then
    raise exception 'transfer file refused: not_downloadable' using errcode = 'check_violation';
  end if;
  if p_sha256 is distinct from f.file_sha256 then
    raise exception 'transfer file refused: hash_mismatch' using errcode = 'check_violation';
  end if;
  if f.status = 'generated' then
    v_now := clock_timestamp();
    v_earliest := private.transfer_earliest_execution_date(f.debtor_bank_account_id, v_now);
    select coalesce(jsonb_agg(jsonb_build_object('transfer_id', x.id, 'kind', x.kind, 'end_to_end_id', x.end_to_end_id,
                                                 'amount_minor', x.amount_minor::text, 'reason', x.hold)
                              order by x.seq), '[]')
    into v_blocked
    from (select i.seq, t.id, t.kind, t.end_to_end_id, t.amount_minor,
                 private.transfer_hold_reason(t.id, (v_now at time zone 'Europe/Paris')::date, i.execution_date,
                                              f.late_reason) as hold
          from public.transfer_file_item i
          cross join lateral (select t.id, t.kind, t.end_to_end_id, t.amount_minor from public.bank_transfer t
                              where t.id = i.transfer_id offset 0) t
          where i.file_id = f.id and t.kind in ('payout', 'refund', 'sweep')) x
    where x.hold is not null;
    -- M2c-7e-1 (plan §7.2): an own-account file skips the cash re-check (the own account's statements are not imported,
    -- design R12) and its sweep's (it holds none); a top-up of it cancelled or booked since the generation blocks it
    if not v_own then
      v_cash := private.transfer_cash_position(f.debtor_bank_account_id);
      if v_cash is null or (v_cash ->> 'available_minor')::bigint < f.ctrl_sum_minor then
        v_blocked := v_blocked || jsonb_build_array(jsonb_build_object(
          'transfer_id', null, 'reason', case when v_cash is null then 'no_closing_balance' else 'cash_not_covered' end,
          'available_minor', v_cash ->> 'available_minor', 'needed_minor', f.ctrl_sum_minor::text));
      end if;
    else
      -- (review round 1, MONEY-BANK-2) or still in it whose credit (its TOP id) is on a statement of the account it
      -- credits, not booked yet (imported before the funds pass, or the line in review): the bank executed it
      v_blocked := v_blocked || coalesce((
        select jsonb_agg(jsonb_build_object('transfer_id', t.id, 'kind', t.kind, 'end_to_end_id', t.end_to_end_id,
                                            'amount_minor', t.amount_minor::text,
                                            'reason', case t.status when 'cancelled' then 'transfer_cancelled'
                                                                    when 'booked' then 'top_up_booked'
                                                                    else 'top_up_credited' end)
                         order by i.seq)
        from public.transfer_file_item i
        cross join lateral (select t.id, t.kind, t.end_to_end_id, t.amount_minor, t.status from public.bank_transfer t
                            where t.id = i.transfer_id offset 0) t
        where i.file_id = f.id
          and (t.status in ('cancelled', 'booked')
               or (t.status = 'in_file' and private.top_up_credit_seen(t.id)))), '[]');
    end if;
    -- M2c-6b-2a (plan §2.4; critic CSO-2, F10, CSO-10): the file's sweep against the servicer's share now — read under
    -- the remit lock held above (every writer of 4679 holds it), by generate_transfer_file's own formula: −Σ 4679 of the
    -- servicer and currency, less the other sweeps ordered or in a file. A cover, a fee or an advance booked since the
    -- generation may have lowered it: such a file is not served (its sweep is cancelled and recomputed by the next file,
    -- its payouts ordered again)
    select t.id, t.amount_minor into v_sweep_id, v_sweep_minor
    from public.transfer_file_item i
    cross join lateral (select t.id, t.kind, t.status, t.amount_minor, t.transfer_file_id from public.bank_transfer t
                        where t.id = i.transfer_id offset 0) t
    where i.file_id = f.id and t.kind = 'sweep' and t.status = 'in_file' and t.transfer_file_id = f.id and not v_own;
    if v_sweep_id is not null then
      select -coalesce(sum(lp.amount_minor), 0) into v_share
      from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
      where la.organization_id = f.organization_id and la.book = 'due_to_servicer' and la.currency = f.currency;
      v_share := v_share - (select coalesce(sum(x.amount_minor), 0) from public.bank_transfer x
                            where x.organization_id = f.organization_id and x.kind = 'sweep' and x.currency = f.currency
                              and x.status in ('ordered', 'in_file') and x.id <> v_sweep_id);
      if v_sweep_minor > v_share then
        v_blocked := v_blocked || jsonb_build_array(jsonb_build_object(
          'transfer_id', v_sweep_id, 'kind', 'sweep', 'reason', 'sweep_exceeds_share',
          'sweep_minor', v_sweep_minor::text, 'share_minor', v_share::text));
      end if;
    end if;
    v_refused := case when f.first_execution_date < v_earliest then 'file_stale'
                      when jsonb_array_length(v_blocked) > 0 then 'file_blocked' end;
    if v_refused is not null then
      -- (M2c-7e-1: an own-account file by private.top_up_file_close — only top-ups, its reads keyed)
      if v_own then
        perform private.top_up_file_close(f.id,
          case v_refused when 'file_stale' then 'Date d''exécution dépassée avant le téléchargement : fichier à régénérer'
                         else 'Contrôles changés depuis la génération : fichier à régénérer' end, null);
      else
        perform private.transfer_file_release(f.id, 'superseded',
          case v_refused when 'file_stale' then 'Date d''exécution dépassée avant le téléchargement : fichier à régénérer'
                         else 'Contrôles changés depuis la génération : fichier à régénérer' end, null, null);
      end if;
      return jsonb_build_object('file_id', f.id, 'number', f.number, 'refused', v_refused, 'status', 'superseded',
                                'first_execution_date', f.first_execution_date,
                                'earliest_execution_date', v_earliest, 'blocked', v_blocked, 'cash', v_cash);
    end if;
  elsif exists (select 1 from public.transfer_file_item i
                cross join lateral (select t.status from public.bank_transfer t where t.id = i.transfer_id offset 0) t
                where i.file_id = f.id and t.status = 'cancelled') then
    raise exception 'transfer file refused: holds_cancelled_transfer' using errcode = 'check_violation',
      hint = 'Un virement de ce fichier a été annulé depuis son téléchargement : ne le déposez plus.';
  elsif exists (select 1 from public.transfer_file_item i
                cross join lateral (select t.id, t.kind, t.status, t.transfer_file_id from public.bank_transfer t
                                    where t.id = i.transfer_id offset 0) t
                where i.file_id = f.id and t.status = 'in_file' and t.transfer_file_id = f.id
                  and ((t.kind in ('payout', 'refund')
                        and (private.transfer_debited_before(t.id)
                             or private.transfer_sibling_debited_late(t.id) is not null))
                       or (t.kind = 'sweep' and private.sweep_after_debited_cancelled(t.id)))) then
    raise exception 'transfer file refused: holds_debited_transfer' using errcode = 'check_violation',
      detail = (select jsonb_agg(jsonb_build_object('transfer_id', x.id, 'kind', x.kind, 'reason', x.reason)
                                 order by x.seq)
                from (select i.seq, t.id, t.kind,
                             case when t.kind = 'sweep' then
                                    case when private.sweep_after_debited_cancelled(t.id)
                                         then 'cancelled_sweep_debited' end
                                  when private.transfer_debited_before(t.id) then 'already_debited'
                                  else private.transfer_sibling_debited_late(t.id) end as reason
                      from public.transfer_file_item i
                      cross join lateral (select t.id, t.kind, t.status, t.transfer_file_id from public.bank_transfer t
                                          where t.id = i.transfer_id offset 0) t
                      where i.file_id = f.id and t.status = 'in_file' and t.transfer_file_id = f.id
                        and t.kind in ('payout', 'refund', 'sweep')) x
                where x.reason is not null)::text,
      hint = 'Un virement de ce fichier a peut-être déjà quitté le compte (débité sous la référence du virement qu''il remplace, dans une ligne groupée de son lot ou sans référence), ou un virement annulé du même client ou du même paiement a été débité en retard, ou la quote-part du cabinet de ce fichier a déjà été virée par une quote-part annulée exécutée en retard : ne déposez pas ce fichier ; s''il l''a été, demandez à la banque de ne pas l''exécuter.';
  -- review round 6 (round 5's verifier, p_redl): the bank executed the file, in full or in part — a debit of one of its
  -- PmtInfIds or its transfers' end-to-end ids, or a return (private.transfer_file_executed), or one of its payouts,
  -- refunds or sweeps shows its own debit (private.transfer_debit_seen: its id, or a batch line of its PmtInf) —:
  -- uploaded again, it would pay it all a second time. Whatever the switch; acknowledged or not. Review round 7 (N5):
  -- also when one of them is booked or returned already — a refund booked by a line with no reference (a CSV feed)
  -- leaves no debit of the file to read, yet it left the account.
  elsif private.transfer_file_executed(f.id)
        or exists (select 1 from public.transfer_file_item i
                   cross join lateral (select t.id, t.kind, t.status, t.transfer_file_id from public.bank_transfer t
                                       where t.id = i.transfer_id offset 0) t
                   where i.file_id = f.id and t.kind in ('payout', 'refund', 'sweep') and t.transfer_file_id = f.id
                     and (t.status in ('booked', 'returned') or private.transfer_debit_seen(t.id)))
        -- M2c-7e-1 (plan §7.2): an own-account file one of whose top-ups is booked or whose credit (its TOP id) is on a
        -- statement of the account it credits
        or (v_own and exists (select 1 from public.transfer_file_item i
                              cross join lateral (select t.id, t.kind, t.status, t.transfer_file_id
                                                  from public.bank_transfer t where t.id = i.transfer_id offset 0) t
                              where i.file_id = f.id and t.kind = 'top_up' and t.transfer_file_id = f.id
                                and (t.status = 'booked' or private.top_up_credit_seen(t.id)))) then
    raise exception 'transfer file refused: file_executed' using errcode = 'check_violation',
      hint = 'La banque a déjà exécuté ce fichier, en tout ou partie : ne le déposez plus.';
  end if;
  if f.download_count > 0 and not coalesce(p_acknowledged, false) then
    select coalesce(u.display_name, u.email, 'un utilisateur') into v_first from public.app_user u
    where u.id = f.first_downloaded_by;
    raise exception 'transfer file refused: already_downloaded' using errcode = 'check_violation',
      detail = jsonb_build_object('by', v_first, 'at', f.first_downloaded_at)::text;
  end if;
  v_n := f.download_count + 1;
  insert into public.transfer_file_download (file_id, organization_id, n, downloaded_by, warning_acknowledged, sha256)
  values (f.id, f.organization_id, v_n, auth.uid(), f.download_count > 0, p_sha256);
  update public.transfer_file set download_count = v_n,
    first_downloaded_by = coalesce(first_downloaded_by, auth.uid()),
    first_downloaded_at = coalesce(first_downloaded_at, clock_timestamp()),
    status = case when status = 'generated' then 'downloaded' else status end, version = version + 1
  where id = f.id;
  -- (M2c-7e-1: the file's transfers by their keys, then each run by its key — the join read every transfer with a
  -- run, and every pending run, under stale statistics: test_top_up_reads_integration.py. Review round 2: through the
  -- file's items, each one's transfer by its key, its file checked on the row — `transfer_file_id = f.id` may be served
  -- from bank_transfer_filed_amount_idx, every filed transfer read: private.top_up_file_close's note)
  for v_run in select distinct t.run_id
               from (select q.transfer_id from public.transfer_file_item q where q.file_id = f.id offset 0) i
               cross join lateral (select q.run_id, q.status, q.transfer_file_id from public.bank_transfer q
                                   where q.id = i.transfer_id offset 0) t
               where t.status = 'in_file' and t.transfer_file_id = f.id and t.run_id is not null loop
    update public.remittance_run set status = 'sent', version = version + 1 where id = v_run and status = 'approved';
  end loop;
  return jsonb_build_object('file_id', f.id, 'number', f.number, 'download', v_n, 'status',
                            case when f.status = 'generated' then 'downloaded' else f.status end,
                            'storage_path', f.storage_path, 'file_name', f.number || '.xml');
end;
$$;

------------------------------------------------------------------------------------------
-- The filed top-up's credit booked ([critic] M7-MONEY-4), the cancelled one's reviewed
------------------------------------------------------------------------------------------

-- private.bank_booking_recheck, redefined from 20261119090000_switch_on_prerequisites_3.sql (line 2062; same signature
-- and settings, its grants restated below). M2c-7e-1 ([critic] M7-MONEY-4), its top-up rule: a credit naming its TOP
-- books as servicer_top_up when the top-up is ordered or in_file of an own-account file of the same servicer
-- (private.top_up_in_own_file; same amount, currency and creditor as before); one naming a cancelled top-up is
-- `top_up_cancelled_credit` (its own review, private.apply_bank_bookings). The `names_our_lot` / `TF-` rules stay aimed
-- at the dedicated account's own lots (an own-account file's lot is the own account's, never the dedicated account's).
-- Review round 1 (MONEY-BANK-1): a top-up named for a credit that does not carry its TOP id (ops' « Rattacher à TOP… »)
-- must be one of the own account the credit came from (`not_its_own_account`; the job never names one so, the twins
-- agree). Its twin is payments/debits.py decide_line. Nothing else changes.
create or replace function private.bank_booking_recheck(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
begin
  -- The keys first (what a transfer pays, its file history and its run never change): the transfers the rows name and
  -- every member of the PmtInf a batch line names — read once per LINE (review round 3, M3: once per row of the line,
  -- a batch line of N members read its PmtInf's N items N times, N² rows sorted for the distinct: 16 million rows and
  -- 766 MB of temporary files at 2,000 members).
  drop table if exists pg_temp._bb_keys;
  create temp table _bb_keys on commit drop as
  select distinct k.transfer_id, x.run_id, x.debtor_bank_account_id, x.creditor_bank_account_id
  from (select b.transfer_id from pg_temp._bank_booking b where b.transfer_id is not null
        union
        select i.transfer_id
        from (select distinct b.bank_transaction_id from pg_temp._bank_booking b where b.kind in ('payout', 'sweep')) l
        cross join lateral (select q.direction, q.end_to_end_id, q.payment_info_id from public.bank_transaction q
                            where q.id = l.bank_transaction_id offset 0) t
        cross join lateral (select y.transfer_id from public.transfer_file_item y
                            where y.pmt_inf_id = t.payment_info_id offset 0) i
        where t.direction = 'debit' and t.end_to_end_id is null and t.payment_info_id is not null) k
  cross join lateral (select q.run_id, q.debtor_bank_account_id, q.creditor_bank_account_id from public.bank_transfer q
                      where q.id = k.transfer_id offset 0) x;

  drop table if exists pg_temp._bb_cover;
  create temp table _bb_cover (ord integer) on commit drop;   -- (the advances posted: bank_booking_post_rows)

  perform 1 from public.remittance_run r
  where r.id = any (array(select k.run_id from pg_temp._bb_keys k where k.run_id is not null))
  order by r.id for update;
  perform 1 from public.client_payout_account a
  where a.id = any (array(select r.payout_account_id from public.remittance_run r
                          where r.id = any (array(select k.run_id from pg_temp._bb_keys k
                                                  join pg_temp._bank_booking b on b.transfer_id = k.transfer_id
                                                  where b.kind = 'payout_returned' and k.run_id is not null))
                            and r.payout_account_id is not null))
  order by a.id for no key update;
  perform 1 from public.bank_account a
  where a.id = any (array(
          select t.bank_account_id from pg_temp._bank_booking b
          cross join lateral (select q.bank_account_id from public.bank_transaction q
                              where q.id = b.bank_transaction_id offset 0) t
          union
          select k.debtor_bank_account_id from pg_temp._bb_keys k
          union
          select k.creditor_bank_account_id from pg_temp._bb_keys k where k.creditor_bank_account_id is not null))
  order by a.id for share;
  drop table if exists pg_temp._bb_pay_locks;
  create temp table _bb_pay_locks on commit drop as
  select distinct y.payment_id
  from pg_temp._bank_booking b
  join pg_temp._bb_keys k on k.transfer_id = b.transfer_id
  cross join lateral (select q.booking_date from public.bank_transaction q where q.id = b.bank_transaction_id offset 0) t
  cross join lateral (select x.payment_id from public.remittance_line x
                      where x.run_id = k.run_id and x.amount_minor > 0 and not x.released and x.payment_id is not null
                        and x.latest_execution_date < t.booking_date offset 0) y
  where b.kind = 'payout' and k.run_id is not null;
  perform 1 from public.payment p
  where p.id = any (array(select l.payment_id from pg_temp._bb_pay_locks l))
  order by p.id for key share;
  -- M2c-6b-2b (review CSR-1): a sweep's return too — every row whose posting reverses an entry (private.ledger_reverse
  -- always takes `payments:`) takes it here, before the lines and `remit:`, the order every other writer takes them
  if exists (select 1 from pg_temp._bank_booking b
             where b.kind in ('payout', 'payout_returned', 'sweep_returned', 'unplanned_payout')) then
    perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  end if;
  perform 1 from public.bank_transaction t
  where t.id = any (array(select b.bank_transaction_id from pg_temp._bank_booking b))
  order by t.id for no key update;
  if exists (select 1 from pg_temp._bank_booking) then
    perform pg_advisory_xact_lock(hashtext('remit:' || p_organization_id::text));
  end if;
  perform 1 from public.transfer_file f
  where f.id = any (array(select q.transfer_file_id from pg_temp._bb_keys k
                          cross join lateral (select y.transfer_file_id from public.bank_transfer y
                                              where y.id = k.transfer_id offset 0) q
                          where q.transfer_file_id is not null))
  order by f.id for share;
  perform 1 from public.bank_transfer x
  where x.id = any (array(select k.transfer_id from pg_temp._bb_keys k))
  order by x.id for update;

  -- The facts, read under the locks (one keyed lookup per row: laterals holding only the key).
  drop table if exists pg_temp._bb;
  create temp table _bb on commit drop as
  select b.*, t.organization_id as line_org, t.bank_account_id as line_bank, t.direction, t.currency,
         t.amount_minor as line_minor, t.booking_date as line_date, coalesce(dr.released_kind, t.kind) as line_kind,
         (t.kind = 'suspected_duplicate' and dr.decision is distinct from 'released') as held,
         t.counterparty_iban, t.end_to_end_id, coalesce(t.original_end_to_end_id, t.end_to_end_id) as returned_id,
         t.payment_info_id, t.unsplit_ours,
         (t.direction = 'debit' and t.end_to_end_id is null and t.payment_info_id is not null) as batch_line,
         -- booked in the funds, or an own credit released as a relayed debtor payment (booked by its cash_in)
         (exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = b.bank_transaction_id offset 0)
          or exists (select 1 from public.bank_own_credit_release c
                     where c.bank_transaction_id = b.bank_transaction_id offset 0)) as booked,
         (select l.kind from public.bank_debit_link l where l.bank_transaction_id = b.bank_transaction_id) as link_kind,
         coalesce((select -sum(p.amount_minor) from public.bank_debit_link l
                   join public.ledger_posting p on p.entry_id = l.cash_entry_id
                   where l.bank_transaction_id = b.bank_transaction_id and l.kind = 'return'
                     and (select la.book from public.ledger_account la where la.id = p.ledger_account_id)
                         = 'client_money_cash'), 0)::bigint as linked_minor,
         x.organization_id as tr_org, x.kind as tr_kind, x.status as tr_status, x.creditor_bank_account_id as tr_creditor,
         x.debtor_bank_account_id as tr_debtor, x.amount_minor as tr_minor, x.currency as tr_currency,
         x.end_to_end_id as tr_e2e, x.transfer_file_id as tr_file, x.run_id as tr_run,
         x.client_organization_id as tr_client, x.entry_id as tr_entry,
         f.status as file_status, f.download_count as file_downloads,
         (select i.pmt_inf_id from public.transfer_file_item i
          where i.file_id = x.transfer_file_id and i.transfer_id = x.id) as tr_pmt_inf,
         exists (select 1 from public.bank_line_booking k where k.transfer_id = b.transfer_id
                   and k.kind in ('payout', 'sweep', 'top_up') offset 0) as tr_debit_booked,
         exists (select 1 from public.bank_line_booking k where k.transfer_id = b.transfer_id
                   and k.kind in ('payout_returned', 'sweep_returned') offset 0) as tr_return_booked,
         -- M2c-6b-2a (plan §2.3; critic F1, L5; critic2 ML-3): for a return of a transfer of this servicer, an unplanned
         -- booking of it whose entry is not reversed, and a debit line of it on a statement not booked beyond its booked
         -- debit (each by key)
         case when b.kind in ('payout_returned', 'sweep_returned') and x.organization_id = p_organization_id
              then private.transfer_unplanned_open(b.transfer_id) end as tr_unplanned_open,
         case when b.kind in ('payout_returned', 'sweep_returned') and x.organization_id = p_organization_id
              then exists (select 1 from private.transfer_late_lines(b.transfer_id)) end as tr_debit_pending,
         (select e.effective_date from public.ledger_entry e where e.id = x.entry_id) as tr_entry_date,
         ru.status as run_status, ru.transfer_id as run_transfer, ru.payout_account_id as run_payout_account,
         null::uuid as own_bank, null::bigint as book_minor, null::text as why
  from pg_temp._bank_booking b
  left join lateral (select q.organization_id, q.bank_account_id, q.direction, q.currency, q.amount_minor,
                            q.booking_date, q.kind, q.counterparty_iban, q.end_to_end_id, q.original_end_to_end_id,
                            q.payment_info_id, q.unsplit_ours
                     from public.bank_transaction q where q.id = b.bank_transaction_id offset 0) t on true
  left join lateral (select q.decision, q.released_kind from public.bank_duplicate_resolution q
                     where q.bank_transaction_id = b.bank_transaction_id offset 0) dr on true
  left join lateral (select q.organization_id, q.kind, q.status, q.creditor_bank_account_id, q.debtor_bank_account_id,
                            q.amount_minor, q.currency, q.end_to_end_id, q.transfer_file_id, q.run_id,
                            q.client_organization_id, q.entry_id, q.id
                     from public.bank_transfer q where q.id = b.transfer_id offset 0) x on true
  left join lateral (select q.status, q.download_count from public.transfer_file q where q.id = x.transfer_file_id
                     offset 0) f on true
  left join lateral (select q.status, q.transfer_id, q.payout_account_id from public.remittance_run q
                     where q.id = x.run_id offset 0) ru on true;
  -- review round 3 (M3): its size known to the planner (a temporary table is never analysed by autovacuum: unanalysed,
  -- the rules' joins of _bb to itself were planned as nested loops over every pair of a batch line's rows)
  analyze pg_temp._bb;
  -- a top-up's own account: its transfer's, or (ops, no transfer) the registered own account the credit came from
  update pg_temp._bb b set own_bank = coalesce(b.tr_debtor, (
    select o.id from public.bank_account o
    where o.organization_id = b.line_org and o.purpose = 'own' and o.status = 'active' and o.iban = b.counterparty_iban
      and o.currency = b.currency))
  where b.kind = 'top_up';
  update pg_temp._bb b set book_minor = case when b.kind = 'loss' then b.amount_minor
                                             when b.kind in ('payout', 'sweep', 'payout_returned', 'sweep_returned')
                                               then b.tr_minor
                                             else b.line_minor end
  where b.bank_transaction_id is not null;

  update pg_temp._bb b set why = case
    when b.line_org is distinct from p_organization_id then 'line_unknown'
    when b.held then 'held_duplicate'
    when b.booked then 'already_booked'
    when b.method = 'ops' and nullif(btrim(b.reason), '') is null then 'reason_required'
    when b.kind = 'fee' then case
      when b.link_kind is not null then 'already_linked'
      -- an other debit only: our own transfers out are booked as sweeps and payouts or left to ops, never as fees
      -- (M2c-1 review: a withdrawal to the own account read as a bank fee); M2c-6b-1: nor a line carrying our RMT/SWP
      -- id or one of our PmtInfIds (plan §2.2)
      when b.direction <> 'debit' or b.line_kind <> 'other_debit' then 'not_a_fee'
      -- (review round 3, M2: its OWN id only, never the original it names — a bank charge naming our payout or sweep,
      -- e.g. the payee's bank's charge on a payout it sent back, is a charge on our account, the servicer's cost, booked
      -- as a fee as the job books every coded charge (CHRG/FEES) whatever its original id; ADR-0014)
      when b.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$'
           or (b.batch_line and b.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$') then 'not_a_fee'
      when b.transfer_id is not null or b.amount_minor is not null then 'bad_request' end
    when b.kind = 'top_up' then case
      -- review round 3 (M2, round 2's L4): never one of our payouts' or sweeps' lines — a credit carrying our RMT/SWP
      -- id as its own or as the original it returns (a sweep back from the own IBAN that the feed did not flag as a
      -- return: a CSV label missing RETURN_RE reads it own_transfer_in), as the loss rule below; such a credit is
      -- booked from the statement as that transfer's return (sweep_returned), never as a top-up. Nor (integration of
      -- round 3, as public.release_own_credit reads a credit) a line naming one of our PmtInfIds without an end-to-end
      -- id, whatever its direction: our batch line, or a lot of one of our files coming back as one credit (a top-up is
      -- never in a file of the dedicated account: an own-account top-up file's lots are the own account's — M2c-7e-1)
      -- Review round 7: (S3, verdict new:own-client-credit-naming-our-lot-relay-top-up) nor a credit naming one of our
      -- lots of its account (private.names_our_lot: a file of that account handed out) whatever its end-to-end id — our
      -- outgoing transfer coming back (a top-up is never in a file of this dedicated account: its lot would be a file of
      -- the own account); (S2) nor a line of an entry kept unsplit holding a detail of ours
      when coalesce(b.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or coalesce(b.returned_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or (b.end_to_end_id is null and coalesce(b.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$', false))
           or coalesce(b.unsplit_ours, 0) > 0
           or (b.direction = 'credit' and private.names_our_lot(b.line_bank, b.payment_info_id))
        then 'own_transfer_line'
      when b.link_kind is not null then 'already_linked'
      when b.direction <> 'credit' or b.line_kind <> 'own_transfer_in' then 'not_an_own_credit'
      when b.amount_minor is not null then 'bad_request'
      when b.transfer_id is not null and (b.tr_org is distinct from p_organization_id or b.tr_kind <> 'top_up'
                                          or b.tr_creditor is distinct from b.line_bank) then 'transfer_unknown'
      -- M2c-7e-1 ([critic] M7-MONEY-4): a credit naming a cancelled top-up waits for ops (top_up_cancelled_credit:
      -- booked with no transfer, the servicer's own money); a top-up books from ordered, or in_file of an own-account
      -- file of this servicer (filing puts it in_file; its credit closes it: private.top_up_in_own_file)
      when b.transfer_id is not null and b.tr_status = 'cancelled' then 'top_up_cancelled_credit'
      when b.transfer_id is not null and b.tr_status <> 'ordered'
           and not (b.tr_status = 'in_file' and private.top_up_in_own_file(b.transfer_id)) then 'transfer_not_pending'
      when b.transfer_id is not null and (b.tr_minor <> b.line_minor or b.tr_currency <> b.currency) then 'amount_differs'
      -- M2c-7e-1 review round 1 (MONEY-BANK-1): a top-up picked for a credit that does not carry its TOP id
      -- (« Rattacher à TOP… ») is one ordered from the own account the credit came from (its IBAN the line's
      -- counterparty's); a credit carrying the id is its top-up whatever account sent it (the job's rule, unchanged)
      when b.transfer_id is not null and b.end_to_end_id is distinct from b.tr_e2e
           and not exists (select 1 from public.bank_account o where o.id = b.tr_debtor
                             and o.iban = b.counterparty_iban)
        then 'not_its_own_account'
      when b.own_bank is null then 'own_account_unknown' end
    when b.kind = 'loss' then case
      -- review round 2 (L4, money-1's defence in depth): never one of our payouts' or sweeps' lines — a line carrying our
      -- RMT/SWP id as its own or as the original it returns, or a batch line of one of our PmtInfIds — whatever kind the
      -- statement gives it: as for every other link (private.post_debit_links), such a line is only booked
      -- (review round 7, S2: or a line of an entry kept unsplit holding a detail of ours, whose ids are not on its line)
      when coalesce(b.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or coalesce(b.returned_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or (b.batch_line and b.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
           or coalesce(b.unsplit_ours, 0) > 0 then 'own_transfer_line'
      when b.direction <> 'debit' or b.line_kind <> 'return' then 'not_a_return'
      when b.link_kind is not null and b.link_kind <> 'return' then 'already_linked'
      when b.transfer_id is not null or b.amount_minor is null or b.amount_minor <= 0 then 'bad_request'
      when b.amount_minor + b.linked_minor <> b.line_minor then 'amount_differs' end
    when b.kind in ('payout', 'sweep') then case
      when b.amount_minor is not null or b.client_organization_id is not null then 'bad_request'
      when b.link_kind is not null then 'already_linked'
      when b.direction <> 'debit' or b.line_kind not in ('transfer_out', 'other_debit', 'batch_unsplit')
        then 'not_a_transfer_line'
      when b.transfer_id is null or b.tr_org is distinct from p_organization_id or b.tr_kind is distinct from b.kind
        then 'transfer_unknown'
      -- own id first (plan §2.4 rule 1): a line carrying an end-to-end id is that id's transfer only — a re-issue is
      -- never booked by its predecessor's id; a batch line names the transfer's PmtInf in its current file (rule 2)
      when not coalesce(b.end_to_end_id = b.tr_e2e or (b.batch_line and b.payment_info_id = b.tr_pmt_inf), false)
        then 'not_its_line'
      when b.tr_status = 'cancelled' then 'cancelled_transfer_debited'
      when b.tr_status in ('booked', 'returned') or b.tr_debit_booked then 'transfer_debited_twice'
      when b.tr_status <> 'in_file' or coalesce(b.file_downloads, 0) = 0
           or b.file_status not in ('downloaded', 'sent') then 'transfer_not_handed_out'
      when b.tr_debtor is distinct from b.line_bank or b.tr_currency is distinct from b.currency then 'transfer_differs'
      when not b.batch_line and b.tr_minor <> b.line_minor then 'transfer_differs'
      when b.kind = 'payout' and (b.run_status is null or b.run_status not in ('approved', 'sent')
                                  or b.run_transfer is distinct from b.transfer_id) then 'run_not_in_flight'
      -- review round 7 (S2, verdict new:debit-entry-unsplit-with-our-details-explainable): never from an entry the bank
      -- kept unsplit holding a detail of ours — by the id its one detail gives (one shown of several: the entry's total)
      -- nor as a batch line whose details are given but do not add up (payments.debits; COMPLIANCE OQ-84 (h)); a batch
      -- line the bank sent with no details (a count of 0) keeps the batch rule
      when coalesce(b.unsplit_ours, 0) > 0 or (not b.batch_line and b.unsplit_ours is not null) then 'batch_partial' end
    when b.kind in ('payout_returned', 'sweep_returned') then case
      when b.amount_minor is not null or b.client_organization_id is not null then 'bad_request'
      when b.link_kind is not null then 'already_linked'
      when b.direction <> 'credit' or b.line_kind <> 'return' then 'not_a_return'
      when b.transfer_id is null or b.tr_org is distinct from p_organization_id
           or b.tr_kind is distinct from case b.kind when 'payout_returned' then 'payout' else 'sweep' end
        then 'transfer_unknown'
      when b.returned_id is distinct from b.tr_e2e then 'not_its_line'
      when b.tr_status in ('ordered', 'in_file') then 'return_before_debit'
      -- M2c-6b-2a (critic F1, L5): a copy coming back of a transfer that has an open unplanned booking (a booked or
      -- returned transfer executed again, a cancelled one executed late) is that unplanned payout's return, booked by ops
      -- (6b-2b): booked here as the planned payout's, it would pay the client again
      when b.tr_unplanned_open then 'unplanned_payout_return'
      -- (critic2 ML-3) a second or late debit of it on a statement, not booked yet: that debit is booked first
      when b.tr_debit_pending then 'return_debit_pending'
      when b.tr_status = 'returned' or b.tr_return_booked then 'already_returned'
      when b.tr_status <> 'booked' or not b.tr_debit_booked or b.tr_entry is null then 'return_differs'
      when b.tr_debtor is distinct from b.line_bank or b.tr_currency is distinct from b.currency then 'transfer_differs'
      when b.line_minor > b.tr_minor then 'return_differs'
      -- review round 6 (R1, a regression of round 5): a line read from a camt.053 entry kept unsplit carries the
      -- entry's total, not this transfer's return — less than the transfer is never its return with the rest as the
      -- bank's charge (the round-5 verifier's netted entry: our payout's return beside another payout's debit booked
      -- that debit as our bank fee; or a chargeback), nor any amount with several details of ours (the first one's id
      -- only what the refusals read). Review round 7 (S1, verdict new:unsplit-exact-total-other-details): nor with one
      -- detail of ours for the transfer's exact amount — the entry's other details (a debtor's credit, netting debits),
      -- a detail of ours short of the entry or shown alone of several, are not ours to read: never booked
      -- (payments.debits). A detail of ours that is the whole entry is a line of its own (payments.camt053)
      when b.unsplit_ours is not null then 'return_differs'
      when b.line_date < b.tr_entry_date then 'return_before_debit' end
    -- the unplanned kinds are ops' (M2c-6b-2: public.book_transfer_line)
    else 'bad_request'
  end
  where b.bank_transaction_id is not null;  -- (every row: PostgREST sessions refuse an UPDATE without WHERE)

  -- A line is one kind of booking (the job's): a payout, sweep or return line holds nothing else. Review round 3 (M3):
  -- per line, aggregated once (two kinds or more, one of them ours) — the same lines as « another row of the line of
  -- another kind, one of the two ours », which, as a correlated EXISTS, hashed a batch line's N rows into one bucket
  -- and compared every pair (25 million join-filter rows at 5,000 members).
  update pg_temp._bb b set why = 'bad_request'
  from (select o.bank_transaction_id from pg_temp._bb o
        group by o.bank_transaction_id
        having count(distinct o.kind) > 1
           and bool_or(o.kind in ('payout', 'sweep', 'payout_returned', 'sweep_returned'))) k
  where b.why is null and b.bank_transaction_id = k.bank_transaction_id;
  -- A batch line (plan §2.3 row 3, §2.4 rule 2): booked only for exactly the in_file members of the PmtInf it names, in
  -- its file of the line's account (the members that file holds), none cancelled (but returned), of one kind, adding up
  -- to the line — never a « best subset ». The members are read under their locks.
  -- Linear whatever the line's size (review round 2, P1): each step is MATERIALIZED, so it runs once — the lines, the
  -- rows each line holds, the members of each line's PmtInf by keyed laterals (each item, file and transfer read
  -- once), then the verdict per line. (As one grouped subquery joined to the rows, the planner re-ran it once per row
  -- of the line: 150 members read 23,250 items and ~25,000 transfers.) Review round 3 (M3): the members aggregated per
  -- line first (a), then compared with the line's rows (w) — never an array growing with the line in a sort or group
  -- key (grouped by the array of the line's N transfer ids, each of the N joined rows carried it into the sort: N² bytes,
  -- 392 MB of temporary files at 5,000 members).
  with l as materialized (
    select distinct o.bank_transaction_id, o.line_bank, o.payment_info_id, o.line_minor from pg_temp._bb o
    where o.batch_line and o.kind in ('payout', 'sweep') and o.why is null),
  r as materialized (   -- every row the line holds (the job's, whatever their verdict)
    select o.bank_transaction_id, array_agg(o.transfer_id order by o.transfer_id) as ids
    from pg_temp._bb o
    where o.bank_transaction_id in (select l.bank_transaction_id from l)
    group by o.bank_transaction_id),
  m as materialized (
    select l.bank_transaction_id, t.id, t.kind, t.status, t.amount_minor, fl.download_count, fl.status as file_status,
           case when t.status = 'cancelled' then private.transfer_return_seen(t.id) else false end as returned
    from l
    cross join lateral (select y.file_id, y.transfer_id from public.transfer_file_item y
                        where y.pmt_inf_id = l.payment_info_id offset 0) i
    cross join lateral (select q.debtor_bank_account_id, q.status, q.download_count from public.transfer_file q
                        where q.id = i.file_id offset 0) fl
    cross join lateral (select q.id, q.kind, q.status, q.amount_minor, q.transfer_file_id from public.bank_transfer q
                        where q.id = i.transfer_id offset 0) t
    where fl.debtor_bank_account_id = l.line_bank and t.transfer_file_id = i.file_id),
  a as materialized (   -- each line's members, aggregated once (grouped by the line's key only)
    select l.bank_transaction_id, l.line_minor, count(m.id) as members,
           bool_or(m.status = 'cancelled' and not m.returned) as cancelled_unreturned,
           bool_and(m.status = 'in_file' and (coalesce(m.download_count, 0) = 0
                                              or m.file_status not in ('downloaded', 'sent'))) as none_handed_out,
           count(m.id) filter (where m.status = 'in_file') as live,
           count(distinct m.kind) filter (where m.status = 'in_file') as live_kinds,
           bool_or(m.status = 'in_file' and m.kind = 'refund') as live_refund,
           coalesce(sum(m.amount_minor) filter (where m.status = 'in_file'), 0) as live_minor,
           array_agg(m.id order by m.id) filter (where m.status = 'in_file') as live_ids
    from l
    left join m on m.bank_transaction_id = l.bank_transaction_id
    group by l.bank_transaction_id, l.line_minor),
  w as materialized (   -- the verdict per line: one row of a, compared with the one row of r
    select a.bank_transaction_id,
           case
             when a.members = 0 then 'transfer_unknown'
             when a.cancelled_unreturned then 'cancelled_transfer_debited'
             when a.none_handed_out then 'transfer_not_handed_out'
             when a.live = 0 then 'transfer_debited_twice'
             when a.live_kinds > 1 or a.live_refund then 'batch_mixed'
             when a.live_minor <> a.line_minor then 'batch_partial'
             when a.live_ids is distinct from r.ids then 'batch_incomplete'
           end as why
    from a
    left join r on r.bank_transaction_id = a.bank_transaction_id)
  update pg_temp._bb b set why = w.why
  from w
  where b.bank_transaction_id = w.bank_transaction_id and b.why is null and w.why is not null;
  -- a transfer booked once per call (a later line waits: ops, or the next run): a row whose transfer an earlier row
  -- still accepted, of another line, books the same way (a debit, or a return). Review round 3 (M3): counted by a
  -- window over the accepted rows, by the transfer's key (as a correlated EXISTS over the unanalysed _bb, a nested loop
  -- compared every pair of a batch line's rows: 25 million at 5,000 members).
  update pg_temp._bb b set why = 'transfer_twice'
  from (select o.ord,
               count(*) over (partition by o.transfer_id, o.returns order by o.ord
                              rows between unbounded preceding and 1 preceding) as before_any,
               count(*) over (partition by o.transfer_id, o.returns, o.bank_transaction_id order by o.ord
                              rows between unbounded preceding and 1 preceding) as before_here
        from (select x.ord, x.transfer_id, x.bank_transaction_id,
                     x.kind in ('payout_returned', 'sweep_returned') as returns
              from pg_temp._bb x where x.why is null and x.transfer_id is not null) o) w
  where b.ord = w.ord and w.before_any > w.before_here and b.why is null;
  -- one refused row refuses its line (a line is booked whole)
  update pg_temp._bb b set why = w.why
  from (select distinct on (o.bank_transaction_id) o.bank_transaction_id, o.why from pg_temp._bb o
        where o.why is not null order by o.bank_transaction_id, o.ord) w
  where b.bank_transaction_id = w.bank_transaction_id and b.why is null;
end;
$$;

-- private.apply_bank_bookings, redefined from 20261117090000_transfer_line_foundations.sql (line 1500; same signature
-- and settings, its grants restated below). M2c-7e-1 ([critic] M7-MONEY-4): a row the re-check refused
-- `top_up_cancelled_credit` — the line's own state, as the job's rules review it (payments/debits.py) — is reviewed under
-- that reason, as `return_before_debit` is, not `changed`. Nothing else changes.
create or replace function private.apply_bank_bookings(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb;
begin
  update pg_temp._bank_booking set method = 'auto', decided_by = null where bank_transaction_id is not null;
  v := private.post_bank_bookings(p_organization_id, false);
  insert into pg_temp._booking_review (bank_transaction_id, reason, detail)
  select f.bank_transaction_id, 'posting_failed', f.detail from pg_temp._booking_failed f
  on conflict (bank_transaction_id) do update set reason = excluded.reason, detail = excluded.detail;
  insert into pg_temp._booking_review (bank_transaction_id, reason, detail)
  select s.bank_transaction_id,
         case when s.why in ('return_before_debit', 'unplanned_payout_return', 'return_debit_pending',
                             'top_up_cancelled_credit') then s.why
              else 'changed' end,
         case when s.why in ('return_before_debit', 'unplanned_payout_return', 'return_debit_pending',
                             'top_up_cancelled_credit') then null
              else s.why end
  from pg_temp._booking_skipped s
  on conflict (bank_transaction_id) do nothing;
  delete from public.bank_debit_review v using pg_temp._booking_review r where v.bank_transaction_id = r.bank_transaction_id;
  insert into public.bank_debit_review (bank_transaction_id, organization_id, reason, candidates, detail)
  select r.bank_transaction_id, p_organization_id, r.reason, r.candidates, r.detail
  from pg_temp._booking_review r
  cross join lateral (select q.organization_id from public.bank_transaction q
                      where q.id = r.bank_transaction_id offset 0) t
  where t.organization_id = p_organization_id
    and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_own_credit_release c
                    where c.bank_transaction_id = r.bank_transaction_id offset 0);
  return v || jsonb_build_object('reviews', (select count(*) from pg_temp._booking_review));
end;
$$;

-- public.link_debit, redefined from 20261117110000_transfer_line_pages.sql (line 2518; same signature and settings, its
-- grants restated below). M2c-7e-1 ([critic] M7-MONEY-4): « Comptabiliser comme approvisionnement » on a credit carrying
-- the TOP id of a filed (in_file) top-up books it with that top-up, as the funds pass does — without it the top-up
-- would stay in_file and private.top_up_needed would keep subtracting it (Collectoo ordering too little). Nothing else
-- changes (a cancelled top-up's credit still books with no transfer: its review top_up_cancelled_credit's exit).
create or replace function public.link_debit(p_idempotency_key text, p_bank_transaction_id uuid, p_kind text,
                                             p_payment_id uuid, p_refund_request_id uuid, p_expected_left_minor text,
                                             p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_out jsonb;
  v_left bigint;
  v_transfer uuid;
  v_guard text;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'kind', p_kind, 'payment_id', p_payment_id,
                                  'refund_request_id', p_refund_request_id, 'expected_left_minor', p_expected_left_minor,
                                  'reason', v_reason);
  v_result := private.command_replay('link_debit', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p_kind is null or p_kind not in ('return', 'refund', 'refund_returned', 'explained', 'fee', 'own_credit', 'loss') then
    raise exception 'debit link refused: bad_request' using errcode = 'check_violation';
  end if;
  if (p_kind in ('return', 'loss')) <> (p_expected_left_minor is not null)
     or (p_expected_left_minor is not null and p_expected_left_minor !~ '^[0-9]{1,16}$')
     or (p_kind in ('return', 'loss')) <> (p_payment_id is not null)
     or (p_kind in ('refund', 'refund_returned')) <> (p_refund_request_id is not null) then
    raise exception 'debit link refused: bad_request' using errcode = 'check_violation';
  end if;
  -- M2c-6b-2c (plan §4.1): never a fee, an explanation or another refund on a line the screen books as ours
  v_guard := private.link_debit_guard(t.id, p_kind, p_refund_request_id);
  if v_guard is not null then
    raise exception 'debit link refused: %', v_guard using errcode = 'check_violation';
  end if;

  if p_kind in ('return', 'refund', 'refund_returned', 'explained') then
    perform private.debit_link_begin();
    insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, refund_request_id, method, decided_by,
                                     reason, expected_left_minor)
    values (1, t.id, p_kind, p_payment_id, p_refund_request_id, 'ops', auth.uid(), v_reason,
            p_expected_left_minor::bigint);
    v_out := private.post_debit_links(t.organization_id, true);
  elsif p_kind = 'loss' then
    v_left := p_expected_left_minor::bigint;
    if v_left >= t.amount_minor then
      raise exception 'debit link refused: not_a_loss' using errcode = 'check_violation';
    end if;
    v_out := '{}';
    if v_left > 0 then
      -- the payment's return of what is left of it (the M2b path: its allocations reversed at the return date)
      perform private.debit_link_begin();
      insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, method, decided_by, reason,
                                       expected_left_minor, amount_minor)
      values (1, t.id, 'return', p_payment_id, 'ops', auth.uid(), v_reason, v_left, v_left);
      v_out := private.post_debit_links(t.organization_id, true);
    elsif not exists (select 1 from private.payment_positions(array[p_payment_id]) x
                      join public.payment p on p.id = x.payment_id
                      where p.organization_id = t.organization_id and p.bank_account_id = t.bank_account_id
                        and x.amount_minor - x.returned_minor = 0) then
      -- nothing is left of the payment (as the page showed): the whole line is the servicer's loss
      raise exception 'debit link refused: payment_changed' using errcode = 'check_violation';
    end if;
    perform private.bank_booking_begin();
    insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, amount_minor, method, decided_by, reason)
    values (1, t.id, 'loss', t.amount_minor - v_left, 'ops', auth.uid(), v_reason);
    v_out := v_out || jsonb_build_object('booking', private.post_bank_bookings(t.organization_id, true));
  else
    -- a credit carrying the TOP id of a pending top-up is that top-up — M2c-7e-1 ([critic] M7-MONEY-4): ordered, or in
    -- a file (the re-check books it only in_file of an own-account file of the servicer, private.top_up_in_own_file)
    if p_kind = 'own_credit' then
      select x.id into v_transfer from public.bank_transfer x
      where x.end_to_end_id = t.end_to_end_id and x.organization_id = t.organization_id and x.kind = 'top_up'
        and x.status in ('ordered', 'in_file');
    end if;
    perform private.bank_booking_begin();
    insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method, decided_by, reason)
    values (1, t.id, case p_kind when 'fee' then 'fee' else 'top_up' end, v_transfer, 'ops', auth.uid(), v_reason);
    v_out := jsonb_build_object('booking', private.post_bank_bookings(t.organization_id, true));
  end if;
  v_result := jsonb_build_object('bank_transaction_id', t.id, 'kind', p_kind, 'result', v_out);
  perform private.command_record('link_debit', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- public.cancel_top_up, redefined from 20261111090000_remittance_funds.sql (line 1621; same signature and settings, its
-- grants restated below). M2c-7e-1 ([check 1] gap 12): « Annuler » also a top-up in_file of an own-account file (a
-- generated file then refuses its download, a downloaded one is never served again: holds_cancelled_transfer). Nothing
-- else changes.
create or replace function public.cancel_top_up(p_idempotency_key text, p_transfer_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  t public.bank_transfer;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('transfer_id', p_transfer_id, 'reason', btrim(coalesce(p_reason, '')));
  v_result jsonb;
begin
  select * into t from public.bank_transfer where id = p_transfer_id for update;
  if not found or t.kind <> 'top_up' or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('cancel_top_up', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  -- M2c-7e-1 ([check 1] gap 12): also a top-up in_file of an own-account file (private.bank_transfer_guard's exemption,
  -- whatever the switch), so that a filed TOP whose credit was booked without it is closed alone, its file kept
  if not (t.status = 'ordered' or (t.status = 'in_file' and private.top_up_in_own_file(t.id))) then
    raise exception 'the top-up is no longer pending' using errcode = 'check_violation';
  end if;
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(),
                                  cancel_reason = v_reason
  where id = t.id and status in ('ordered', 'in_file');
  v_result := jsonb_build_object('transfer_id', t.id, 'status', 'cancelled');
  perform private.command_record('cancel_top_up', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- S23 (plan §7.3, D10): no undo path; the hints stop promising M2c-7
------------------------------------------------------------------------------------------

-- public.assign_payment, redefined from 20261117090000_transfer_line_foundations.sql (line 2097; same signature and
-- settings, its grants restated below). M2c-7e-1 (plan §7.3, D10): its own_transfer_line hint no longer promises a
-- later release — a payment made of our own transfer coming back is never undone (founder Q16: none in production);
-- the P0 alert own_transfer_payment stays the tripwire. Nothing else changes.
create or replace function public.assign_payment(p_idempotency_key text, p_payment_id uuid, p_splits jsonb,
                                                 p_designation jsonb, p_reason text)
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
  v_account uuid;
  v_items uuid[];
  v_source text;
  v_doc uuid;
  v_designation jsonb;
  v_suggested jsonb;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'splits', p_splits, 'designation', p_designation,
                                  'reason', v_reason);
  v_result := private.command_replay('assign_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  -- review M2c-6b-1 round 4 (N1, in depth): a payment whose bank line carries one of our transfers' ids (made before
  -- round 4 read such a credit as a return) is our own money coming back, never a debtor's payment
  if exists (select 1 from public.bank_transaction t
             where t.id = p.bank_transaction_id
               and (private.names_our_transfer(t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id)
                    -- review round 8 (T1): a handed-out lot of its account named, whatever its end-to-end id
                    or case when t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
                            then private.names_our_lot(t.bank_account_id, t.payment_info_id) else false end)) then
    raise exception 'payment assignment refused: own_transfer_line' using errcode = 'check_violation',
      hint = 'Ce paiement vient d''une ligne qui porte la référence de l''un de nos propres virements (reversement, '
             'quote-part du cabinet, lot de notre fichier) : c''est ce virement qui revient, pas le paiement d''un '
             'débiteur. Il ne s''affecte à aucun dossier, et Collectoo ne le comptabilise pas comme le retour de ce '
             'virement (un paiement enregistré ne se défait pas) : prévenez le support.';
  end if;
  if p.status <> 'unmatched' or p.account_id is not null then
    raise exception 'the payment is already matched: unassign it first' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_splits) is distinct from 'array' or jsonb_array_length(p_splits) <> 1
     or jsonb_typeof(p_splits -> 0) <> 'object' or (p_splits -> 0) ? 'amount_text'
     or coalesce(p_splits -> 0 ->> 'account_id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'one file for the whole payment (splitting comes with allocation)' using errcode = 'check_violation';
  end if;
  v_account := (p_splits -> 0 ->> 'account_id')::uuid;
  select * into a from public.account where id = v_account;
  if not found or a.organization_id <> p.organization_id then
    raise exception 'unknown file' using errcode = 'check_violation';
  end if;
  if a.status = 'staged' then
    raise exception 'the file is not confirmed yet' using errcode = 'check_violation';
  end if;
  if p_designation is not null then
    -- The debtor's own indication « lorsqu'il paie » (1342-10): invoices of this file only.
    v_source := p_designation ->> 'source';
    if jsonb_typeof(p_designation -> 'item_ids') is distinct from 'array'
       or v_source is null or v_source not in ('remittance_text', 'document', 'portal') then
      raise exception 'invalid designation' using errcode = 'check_violation';
    end if;
    select array_agg(distinct x.v::uuid) into v_items
    from jsonb_array_elements_text(p_designation -> 'item_ids') x (v)
    where x.v ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    if coalesce(cardinality(v_items), 0) = 0 or cardinality(v_items) <> jsonb_array_length(p_designation -> 'item_ids')
       or (select count(*) from public.claim_item i where i.account_id = a.id and i.id = any (v_items))
          <> cardinality(v_items) then
      raise exception 'invalid designation: invoices of this file only' using errcode = 'check_violation';
    end if;
    if v_source = 'document' then
      -- the debtor's letter or e-mail, filed on this file (not any document of the client)
      v_doc := nullif(p_designation ->> 'evidence_document_id', '')::uuid;
      if v_doc is null or not exists (select 1 from public.document d where d.id = v_doc
                                        and d.organization_id = a.organization_id
                                        and d.client_organization_id = a.client_organization_id
                                        and d.account_id = a.id) then
        raise exception 'invalid designation: the document is required, filed on this file'
          using errcode = 'check_violation';
      end if;
    end if;
    v_designation := jsonb_build_object('item_ids', to_jsonb(v_items), 'source', v_source,
                                        'evidence_document_id', v_doc, 'captured_at', now());
  end if;
  -- what ops saw proposed, kept with the decision
  select jsonb_agg(jsonb_build_object('rank', c.rank, 'account_id', c.account_id, 'rule', c.rule) order by c.rank)
  into v_suggested from public.payment_match_candidate c where c.payment_id = p.id;
  perform private.assign_begin();
  insert into pg_temp._assign (ord, payment_id, account_id, method, rule, rule_version, evidence, designation, teaches)
  values (1, p.id, a.id, 'manual', null, 'ops',
          jsonb_strip_nulls(jsonb_build_object('suggested', v_suggested)), v_designation, true);
  perform private.record_assignments(p.organization_id, 'ops', auth.uid(), v_reason);
  select jsonb_build_object('payment_id', x.id, 'account_id', a.id, 'review_reason', x.review_reason)
  into v_result from public.payment x where x.id = p.id;
  perform private.command_record('assign_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- public.resolve_duplicate, redefined from 20261117090000_transfer_line_foundations.sql (line 2212; same signature and
-- settings, its grants restated below). M2c-7e-1 (plan §7.3, D10): its own_transfer_line hint says « ni comptabilisée »
-- (not « ni encore »): no undo path is planned. Nothing else changes.
create or replace function public.resolve_duplicate(p_idempotency_key text, p_bank_transaction_id uuid,
                                                    p_is_duplicate boolean, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  k record;
  v_payment uuid;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'is_duplicate', p_is_duplicate,
                                  'reason', v_reason);
  v_result := private.command_replay('resolve_duplicate', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if t.kind <> 'suspected_duplicate' or p_is_duplicate is null then
    raise exception 'duplicate: this line is not held as a suspected duplicate' using errcode = 'check_violation';
  end if;
  perform pg_advisory_xact_lock(hashtext('bank_import:' || t.bank_account_id::text));
  if exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id) then
    raise exception 'duplicate: already decided: reload the page' using errcode = 'check_violation';
  end if;
  if p_is_duplicate then
    insert into public.bank_duplicate_resolution (bank_transaction_id, organization_id, bank_account_id, decision,
                                                  reason, decided_by)
    values (t.id, t.organization_id, t.bank_account_id, 'duplicate', v_reason, auth.uid());
    -- review M2c-6b-2a (M1): a debit decided a duplicate is no late debit of our transfer any more
    -- (private.transfer_late_lines): a return it kept waiting (return_debit_pending) is read again now
    if t.direction = 'debit' then
      perform pgmq.send('payments', jsonb_build_object('type', 'process_debits', 'organization_id', t.organization_id));
    end if;
    v_result := jsonb_build_object('bank_transaction_id', t.id, 'decision', 'duplicate');
  else
    select * into k from private.held_line_kind(t.id);
    -- review round 4 (N1, in depth): a line carrying one of our transfers' ids is never released as a payment (a reading
    -- recorded before round 4 may say debtor_credit; read from its facts it is a return)
    if k.kind in ('debtor_credit', 'batch_unsplit')
       and private.names_our_transfer(t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id) then
      raise exception 'duplicate release refused: own_transfer_line' using errcode = 'check_violation',
        hint = 'Cette ligne porte la référence de l''un de nos propres virements (reversement, quote-part du cabinet, '
               'lot de notre fichier) : c''est ce virement qui revient, jamais le paiement d''un débiteur. Lue ainsi '
               'avant la correction de l''import, elle ne peut être ni libérée comme un paiement ni comptabilisée '
               'comme ce retour : elle reste dans « Doublons possibles ». Prévenez le support.';
    end if;
    insert into public.bank_duplicate_resolution (bank_transaction_id, organization_id, bank_account_id, decision,
                                                  released_kind, reason, decided_by)
    values (t.id, t.organization_id, t.bank_account_id, 'released', k.kind, v_reason, auth.uid());
    if k.kind in ('debtor_credit', 'batch_unsplit') then
      v_payment := private.book_credit_payment(t.id, k.method,
                                               coalesce(t.counterparty_name, t.ultimate_counterparty_name),
                                               t.counterparty_iban, null);
      perform pgmq.send('payments', jsonb_build_object('type', 'match', 'organization_id', t.organization_id,
                                                       'trigger', 'import'));
    elsif k.kind in ('return', 'refund_out') then
      perform pgmq.send('payments', jsonb_build_object('type', 'process_debits', 'organization_id', t.organization_id));
    end if;
    v_result := jsonb_build_object('bank_transaction_id', t.id, 'decision', 'released', 'kind', k.kind,
                                   'payment_id', v_payment);
  end if;
  perform private.command_record('resolve_duplicate', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The own account's cut-off (plan §7.2: « ReqdExctnDt today before the account's cut-off »)
------------------------------------------------------------------------------------------

-- private.servicer_billing_settings_guard, redefined from 20261111120000_identities_terms.sql (line 387; same settings,
-- its trigger unchanged). M2c-7e-1 (plan §7.2): a cut-off may also be the own account's (the top-up file's requested
-- date, private.transfer_earliest_execution_date, reads it); before, only a dedicated account's was accepted, so a
-- top-up file could never be dated today. Nothing else changes.
create or replace function private.servicer_billing_settings_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.organization o where o.id = new.organization_id and o.kind = 'servicer') then
    raise exception 'billing settings belong to a servicer' using errcode = 'check_violation';
  end if;
  if new.own_bank_account_id is not null
     and (tg_op = 'INSERT' or new.own_bank_account_id is distinct from old.own_bank_account_id)
     and not exists (select 1 from public.bank_account b where b.id = new.own_bank_account_id
                       and b.organization_id = new.organization_id and b.purpose = 'own' and b.status = 'active') then
    raise exception 'billing settings: the own account must be an active own account of the servicer'
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_each(new.bank_cutoff) c
             where jsonb_typeof(c.value) <> 'string' or (c.value #>> '{}') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
                or c.key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                or not exists (select 1 from public.bank_account b where b.id = c.key::uuid
                                 and b.organization_id = new.organization_id
                                 and b.purpose in ('client_funds', 'own'))) then
    raise exception 'billing settings: a cut-off is an HH:MM time for a client_funds or own account of the servicer'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

------------------------------------------------------------------------------------------
-- The nightly (plan §7.1)
------------------------------------------------------------------------------------------

-- private.run_advance_checks, redefined from 20261128090000_declarations_statement.sql (line 828, 7d-3's: 7d-2's body
-- with the declarations' checks; same signature and settings, its grants restated below). M2c-7e-1 (plan §7.1): two
-- checks after the others — top_up_account_missing (the servicer owes the dedicated account and has no own account to
-- order from; review round 1: as old as the open shortfall period) and top_up_order_failed (the hourly job missed
-- three times in a row, or failed; review round 1: or no longer runs; review round 2: only while an active dedicated
-- account exists). `servicer_shortfall`
-- keeps its formula in run_payment_checks until 7f (D7). Its other statements are unchanged.
create or replace function private.run_advance_checks(p_check_run_id uuid, p_organization_id uuid,
                                                      p_today date default null, p_full boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_today date := coalesce(p_today, private.paris_today());
  v_prev uuid;
  v_since timestamptz;
  v_since_date date;
  v_full boolean := coalesce(p_full, false);
  v_from_ts timestamptz;
  v_from_date date;
  v_proc uuid[];
  v_curr char(3);
  v_need bigint;
begin
  select r.id, r.started_at - interval '1 day' into v_prev, v_since
  from public.payment_check_run r
  where r.organization_id = p_organization_id and r.finished_at is not null and r.id <> p_check_run_id
  order by r.started_at desc limit 1;
  if v_prev is null then
    v_full := true;
  end if;
  v_since_date := (v_since at time zone 'Europe/Paris')::date;
  -- (review round 1, CC-2) the window's lower bounds, -infinity for the full pass: a key range in every plan — a
  -- « v_full or … » predicate is a filter under the generic plan PL/pgSQL caches after five calls in one backend, and
  -- the delta pass would then read every booked run, attribution and cover of the servicer
  v_from_ts := case when v_full then '-infinity'::timestamptz else v_since end;
  v_from_date := case when v_full then '-infinity'::date else v_since_date end;
  -- (M2c-7d-3, plan §6.3) the servicer's clients with a proceeding or a liquidation in effect today — the clients of the
  -- declarations' checks below, whose advances advance_open leaves out: the servicer's clients by
  -- organization_servicer_idx, each one's events by client_status_event_client_idx (a probe per client, fenced)
  select coalesce(array_agg(o.id order by o.id), '{}') into v_proc
  from (select q.id from public.organization q where q.servicer_organization_id = p_organization_id offset 0) o
  where exists (select 1
                from (select e.kind from public.client_status_event e
                      where e.client_organization_id = o.id and e.effective_date <= v_today offset 0) e
                where e.kind in ('proceeding_opened', 'liquidation'));

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with day_rev as materialized (     -- the reversals posted since (ledger_entry_reversal_posted_idx)
    select x.id, x.reverses_entry_id from public.ledger_entry x
    where not v_full and x.organization_id = p_organization_id and x.entry_type = 'reversal' and x.posted_at >= v_since),
  booked as materialized (           -- the runs booked since (remittance_run_booked_idx), every one in the full pass
    select q.id from public.remittance_run q
    where q.organization_id = p_organization_id and q.status = 'booked' and q.booked_on >= v_from_date
    union
    -- (review round 1, CC-1) and the runs whose payout booking was recorded since, whatever their booked_on (the
    -- debit's date: a statement imported late, a late predecessor): bank_line_booking_org_idx, each transfer's run by key
    select t.run_id
    from (select b.transfer_id from public.bank_line_booking b
          where not v_full and b.organization_id = p_organization_id and b.decided_at >= v_from_ts
            and b.kind = 'payout' offset 0) b
    cross join lateral (select t.run_id from public.bank_transfer t
                        where t.id = b.transfer_id and t.run_id is not null offset 0) t),
  cand as materialized (
    select d.id as reversal_id from day_rev d
    union
    select a.cause_entry_id from day_rev d
    cross join lateral (select q.cause_entry_id from public.client_advance q
                        where q.entry_id = d.reverses_entry_id and q.cause = 'remitted_reversal' offset 0) a
    union
    select z.id from day_rev d
    cross join lateral (select u.ledger_entry_id from private.unplanned_paid_item u
                        where u.booking_entry_id = d.reverses_entry_id offset 0) u
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = u.ledger_entry_id offset 0) z
    union
    select z.id
    from booked r
    -- (CI round, main) each run's lines by the run's key alone, their conditions outside the fence
    cross join lateral (select l.ledger_entry_id, l.released, l.kind from public.remittance_line l
                        where l.run_id = r.id offset 0) l
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = l.ledger_entry_id offset 0) z
    where not l.released and l.kind in ('allocation', 'forward')
    union
    select z.id
    from (select u.ledger_entry_id from private.unplanned_paid_item u
          where u.organization_id = p_organization_id and u.created_at >= v_from_ts offset 0) u
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = u.ledger_entry_id offset 0) z
    union
    select a.cause_entry_id from public.client_advance a
    where a.organization_id = p_organization_id and a.cause = 'remitted_reversal' and a.created_at >= v_from_ts
    union
    select c.subject_id from public.payment_check_result c
    where c.run_id = v_prev and c.code = 'remitted_reversal_uncovered' and c.subject_id is not null)
  select p_check_run_id, p_organization_id, 'remitted_reversal_uncovered', 'violation', 'ledger_entry', c.reversal_id,
         f.currency, f.target - f.held, 1, v_today - (e.posted_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', f.client_organization_id, 'reversed_entry_id', e.reverses_entry_id,
                            'run_id', f.run_id, 'target', f.target::text, 'held', f.held::text,
                            'recorded_on', (e.posted_at at time zone 'Europe/Paris')::date)
  from cand c
  cross join lateral private.remitted_cover_fact(c.reversal_id) f
  cross join lateral (select q.posted_at, q.reverses_entry_id from public.ledger_entry q
                      where q.id = c.reversal_id offset 0) e
  where f.target <> f.held;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with adv as materialized (
    select a.client_organization_id, a.currency, sum(a.amount_minor - coalesce(s.settled, 0))::bigint as open_minor
    from (select q.id, q.client_organization_id, q.currency, q.amount_minor, q.entry_id from public.client_advance q
          where q.organization_id = p_organization_id offset 0) a
    left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                       where c.document_kind = 'advance' and c.document_id = a.id) s on true
    where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id)
    group by a.client_organization_id, a.currency),
  led as materialized (
    select la.client_organization_id, la.currency, coalesce(sum(p.s), 0)::bigint as balance_minor
    from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'client_advance_receivable' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.client_organization_id, la.currency)
  select p_check_run_id, p_organization_id, 'advance_ledger', 'violation', 'client',
         coalesce(a.client_organization_id, l.client_organization_id), coalesce(a.currency, l.currency),
         coalesce(l.balance_minor, 0) - coalesce(a.open_minor, 0), 1, null,
         jsonb_build_object('client_id', coalesce(a.client_organization_id, l.client_organization_id),
                            'advances_open', coalesce(a.open_minor, 0)::text,
                            'receivable', coalesce(l.balance_minor, 0)::text)
  from adv a
  full join led l on l.client_organization_id = a.client_organization_id and l.currency = a.currency
  where coalesce(a.open_minor, 0) <> coalesce(l.balance_minor, 0);

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'advance_open', 'alert', 'client_advance', a.id, a.currency,
         a.amount_minor - coalesce(s.settled, 0), 1, v_today - (a.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', a.client_organization_id, 'cause', a.cause, 'mandate_id', a.mandate_id,
                            'created_on', (a.created_at at time zone 'Europe/Paris')::date,
                            -- (M2c-7b) how it is recovered (review round 1: barred_proceeding when it was born before
                            -- the client's proceeding opened)
                            'recovery', (select r.recovery
                                         from private.advance_recovery_of(a.mandate_id, a.client_organization_id,
                                                                          private.advance_born_on(a.id), v_today) r))
         -- (M2c-7c-2, plan §5.2.8) the day it was last requested (a request not withdrawn), when it is
         || coalesce((select jsonb_build_object('requested_on', q.issue_date)
                      from private.advance_live_request(a.id) q), '{}'::jsonb)
         || case when a.cause = 'remitted_reversal'
                      and exists (select 1
                                  from (select z.reverses_entry_id from public.ledger_entry z
                                        where z.id = a.cause_entry_id offset 0) z
                                  cross join lateral (select l.run_id from public.remittance_line l
                                                      where l.ledger_entry_id = z.reverses_entry_id and not l.released
                                                      offset 0) l
                                  cross join lateral private.item_settled_at(z.reverses_entry_id, l.run_id, 0) t
                                  where t.too_deep)
                 then jsonb_build_object('settled_on_depth', true) else '{}'::jsonb end
  from (select q.id, q.client_organization_id, q.currency, q.amount_minor, q.cause, q.mandate_id, q.created_at,
               q.entry_id, q.cause_entry_id
        from public.client_advance q
        where q.organization_id = p_organization_id
          and q.created_at < ((v_today - 30)::timestamp at time zone 'Europe/Paris') offset 0) a
  left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                     where c.document_kind = 'advance' and c.document_id = a.id) s on true
  where a.amount_minor > coalesce(s.settled, 0)
    and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id)
    -- (M2c-7d-3, plan §6.2.10 [critic] L4; carried item 1) never an advance of a client with a proceeding or a
    -- liquidation in effect: claims_to_declare lists it (each such advance in one alert; none once declared)
    and not (a.client_organization_id = any (v_proc));

  -- (M2c-7c-1, plan §5.2.8) [critic] client_credit_owed (alert): what the servicer owes a client back, still open more
  -- than 15 days after it was recorded — at once (P0, `p0` in its details) for a sum held for the client's collective
  -- proceeding (cause procedure: ops and counsel decide, OQ-98). The servicer's credits by client_credit_org_idx, each
  -- one's refunds by commission_settlement_document_idx.
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'client_credit_owed', 'alert', 'client_credit', c.id, c.currency, o.open_minor,
         1, v_today - (c.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', c.client_organization_id, 'cause', c.cause,
                            'created_on', (c.created_at at time zone 'Europe/Paris')::date, 'p0', c.cause = 'procedure')
  from (select q.id, q.client_organization_id, q.currency, q.cause, q.created_at from public.client_credit q
        where q.organization_id = p_organization_id offset 0) c
  cross join lateral (select private.client_credit_open(c.id) as open_minor) o
  where o.open_minor > 0
    and (c.cause = 'procedure' or c.created_at < ((v_today - 15)::timestamp at time zone 'Europe/Paris'));

  -- (M2c-7c-1, plan §5.0 (7)) [check 1] client_credit_ledger (violation, per client): Σ the open parts of its credits
  -- owed back = −Σ its 419 postings
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with cc as materialized (
    select c.client_organization_id, c.currency, sum(c.amount_minor - coalesce(r.refunded, 0))::bigint as open_minor
    from (select q.id, q.client_organization_id, q.currency, q.amount_minor from public.client_credit q
          where q.organization_id = p_organization_id offset 0) c
    left join lateral (select sum(s.amount_minor) as refunded from public.commission_settlement s
                       where s.document_id = c.id and s.document_kind = 'client_credit') r on true
    group by c.client_organization_id, c.currency),
  led as materialized (
    select la.client_organization_id, la.currency, coalesce(-sum(p.s), 0)::bigint as owed_minor
    from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'client_credit_owed' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.client_organization_id, la.currency)
  select p_check_run_id, p_organization_id, 'client_credit_ledger', 'violation', 'client',
         coalesce(c.client_organization_id, l.client_organization_id), coalesce(c.currency, l.currency),
         coalesce(l.owed_minor, 0) - coalesce(c.open_minor, 0), 1, null,
         jsonb_build_object('client_id', coalesce(c.client_organization_id, l.client_organization_id),
                            'credits_open', coalesce(c.open_minor, 0)::text, 'ledger', coalesce(l.owed_minor, 0)::text)
  from cc c
  full join led l on l.client_organization_id = c.client_organization_id and l.currency = c.currency
  where coalesce(c.open_minor, 0) <> coalesce(l.owed_minor, 0);

  -- (M2c-7c-1, plan §5.0 (7)) [check 1] written_off_recovery_ledger (violation, the servicer): Σ the recoveries of its
  -- advances passed as a loss = −Σ its 7714 postings, per currency
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with rec as materialized (
    select r.currency, sum(r.amount_minor)::bigint as recovered_minor
    from (select q.currency, q.amount_minor from public.advance_write_off_recovery q
          where q.organization_id = p_organization_id offset 0) r
    group by r.currency),
  led as materialized (
    select la.currency, coalesce(-sum(p.s), 0)::bigint as income_minor
    from (select l.id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'written_off_recovered' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.currency)
  select p_check_run_id, p_organization_id, 'written_off_recovery_ledger', 'violation', 'servicer', null,
         coalesce(r.currency, l.currency), coalesce(l.income_minor, 0) - coalesce(r.recovered_minor, 0), 1, null,
         jsonb_build_object('recovered', coalesce(r.recovered_minor, 0)::text, 'ledger', coalesce(l.income_minor, 0)::text)
  from rec r
  full join led l on l.currency = r.currency
  where coalesce(r.recovered_minor, 0) <> coalesce(l.income_minor, 0);

  -- (M2c-7c-2, plan §5.2.8) repayment_request_document_missing (alert): a request not withdrawn whose letter is not
  -- drawn one hour after it was recorded (its job failing, or dead). The servicer's undrawn requests by
  -- advance_repayment_request_undrawn_idx (its predicate stated literally here: never every request); (review round 1,
  -- NIGHT-1, CC-1) a withdrawn one gets no letter (its job draws none): never alerted — withdrawing and requesting again
  -- (the remedy for a dead job) leaves no alert behind.
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'repayment_request_document_missing', 'alert', 'advance_repayment_request',
         q.id, q.currency, q.total_minor, 1, v_today - (q.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', q.client_organization_id, 'number', q.number,
                            'created_on', (q.created_at at time zone 'Europe/Paris')::date)
  from (select r.id, r.client_organization_id, r.currency, r.total_minor, r.number, r.created_at
        from public.advance_repayment_request r
        where r.organization_id = p_organization_id and r.document_id is null and r.withdrawn_at is null
          and r.created_at < now() - interval '1 hour' offset 0) q;

  -- (M2c-7d-1, plan §6.3; [critic] L17) protection_event_to_qualify (alert): an old « Tutelle ou curatelle » row
  -- (qualified_at null) ops have not yet said to be a tutelle or a curatelle — its payouts held meanwhile. The
  -- servicer's rows still to qualify by client_status_event_to_qualify_idx (its predicate stated literally), each one's
  -- qualification by its key (offset 0: a correlated probe, never an anti-join reading the qualifications whole).
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'protection_event_to_qualify', 'alert', 'client_status_event', e.id, null,
         null, 1, v_today - (e.recorded_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', e.client_organization_id, 'effective_date', e.effective_date,
                            'recorded_on', (e.recorded_at at time zone 'Europe/Paris')::date)
  from (select x.id, x.client_organization_id, x.effective_date, x.recorded_at from public.client_status_event x
        where x.organization_id = p_organization_id and x.kind = 'guardianship' and x.qualified_at is null offset 0) e
  where not exists (select 1 from public.client_status_event_qualification q where q.event_id = e.id offset 0);

  -- (M2c-7d-1, plan §6.3; [critic] L14, [check 2] gap 6) seizure_standing (alert; P0 for 15 days after its recording,
  -- `p0` in its details): a seizure served on the servicer that no release naming it lifts by today — payouts and
  -- set-off stay blocked; the declaration to the bailiff and the payment of the causes are ops' and counsel's (CPCE
  -- L211-3, R211-4, R211-5). (M2c-7d-2) The servicer's clients by organization_servicer_idx, each one's seizures by
  -- client_status_event_client_seizure_idx (7d-1's index of the servicer's seizures dropped above), each seizure's
  -- release by client_status_event_release_uq (offset 0: a correlated probe per seizure — as an anti-join it read the
  -- release index whole under stale statistics).
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'seizure_standing', 'alert', 'client_status_event', e.id, null, null, 1,
         v_today - (e.recorded_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', e.client_organization_id, 'effective_date', e.effective_date,
                            'recorded_on', (e.recorded_at at time zone 'Europe/Paris')::date,
                            'p0', v_today - (e.recorded_at at time zone 'Europe/Paris')::date < 15)
  from (select o.id from public.organization o where o.servicer_organization_id = p_organization_id offset 0) o
  cross join lateral (select x.id, x.organization_id, x.client_organization_id, x.effective_date, x.recorded_at
                      from public.client_status_event x
                      where x.client_organization_id = o.id and x.kind = 'seizure' offset 0) e
  where e.organization_id = p_organization_id and e.effective_date <= v_today
    and not exists (select 1 from public.client_status_event r
                    where r.refers_to_event_id = e.id and r.kind = 'seizure_released' and r.effective_date <= v_today
                    offset 0);

  -- (M2c-7d-2, plan §6.3 [critic] M7-MONEY-5) set_off_after_bar (alert, P0): a run's settlement posted on or after a
  -- bar's date that set off a document barred that day — an event recorded after the debit, which the debit's
  -- withholding could not see; its amount the barred documents' settlements (private.set_off_after_bar_rows). Counsel
  -- says what follows (kept, or given back): it stays alerted meanwhile.
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'set_off_after_bar', 'alert', 'ledger_entry', x.entry_id, x.currency,
         x.amount_minor, 1, v_today - x.settled_on,
         jsonb_build_object('client_id', x.client_organization_id, 'run_id', x.run_id, 'settled_on', x.settled_on,
                            'bar', x.bar, 'bar_on', x.bar_on, 'documents', x.documents, 'p0', true)
  from private.set_off_after_bar_rows(p_organization_id, v_today) x
  -- (M2c-7d-3; carried item 2) until its outcome is recorded (public.record_set_off_outcome: kept), by its key
  where not exists (select 1 from public.set_off_outcome o where o.entry_id = x.entry_id);

  -- (M2c-7d-3, plan §6.3 [critic] L8, L4; [check 2]) claims_to_declare (alert; P0 from 15 days before its deadline): per
  -- document of a client with a proceeding or a liquidation, an open invoice born before the opening or an open advance,
  -- not named by a declaration (private.client_claims_to_declare): its open part, its birth, its deadline (two months
  -- after the BODACC publication for a claim born before the opening, R622-24 al. 1; after its exigibility for one born
  -- after, L622-24 al. 6) — `publication_missing` without a publication date (then no P0: the deadline is unknown)
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'claims_to_declare', 'alert',
         case x.document_kind when 'invoice' then 'commission_invoice' else 'client_advance' end, x.document_id,
         x.currency, x.open_minor, 1, v_today - x.opening_on,
         jsonb_build_object('client_id', c.id, 'document_kind', x.document_kind, 'number', x.number,
                            'born_on', x.born_on, 'pre_opening', x.pre_opening, 'opening_on', x.opening_on,
                            'opening_kind', x.opening_kind, 'publication_date', x.publication_date,
                            'liquidation_on', x.liquidation_on, 'deadline', x.deadline,
                            'deadline_basis', x.deadline_basis,
                            'p0', coalesce(x.deadline - v_today <= 15, false))
  from unnest(v_proc) c (id)
  cross join lateral private.client_claims_to_declare(c.id, v_today) x;

  -- (M2c-7d-3, plan §6.3 [critic] L8) post_opening_unpaid (alert): an invoice of a client with a proceeding or a
  -- liquidation, born on or after the opening, unpaid at its due date and not declared
  -- (private.client_post_opening_unpaid); no deadline computed (L622-17 IV: the end of the observation period is not
  -- modelled; L641-13 III in liquidation). (Review round 2) an invoice its run set off in full, whose set-off the debit
  -- withheld: from that day (`withheld_on`, standing for its due date); (review round 3) one whose run is in flight
  -- while the client's invoice bar applies: from the day the bar was recorded (`barred_on`, its code `bar`)
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'post_opening_unpaid', 'alert', 'commission_invoice', x.document_id,
         x.currency, x.open_minor, 1, v_today - coalesce(x.due_date, x.withheld_on, x.barred_on),
         jsonb_build_object('client_id', c.id, 'number', x.number, 'due_date', x.due_date, 'born_on', x.born_on,
                            'opening_on', x.opening_on, 'opening_kind', x.opening_kind,
                            'publication_date', x.publication_date, 'liquidation_on', x.liquidation_on,
                            'withheld_on', x.withheld_on, 'barred_on', x.barred_on, 'bar', x.bar)
  from unnest(v_proc) c (id)
  cross join lateral private.client_post_opening_unpaid(c.id, v_today) x;

  -- (M2c-7d-3, plan §6.3 [critic] L11, [check 1] gap 9) payout_after_liquidation (alert, P0): a payout made to the
  -- client after its liquidation, to an account that is not its liquidator's — in its file (`cancellable` while the
  -- file is not downloaded, or once downloaded with the cancellation-after-download switch on) or debited — until a
  -- disposition is recorded (private.client_payouts_after_liquidation), never by elapsed time
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'payout_after_liquidation', 'alert', 'bank_transfer', x.transfer_id,
         x.currency, x.amount_minor, 1, v_today - x.liquidation_on,
         jsonb_build_object('client_id', c.id, 'run_id', x.run_id, 'run_number', x.run_number, 'status', x.status,
                            'requested_execution_date', x.requested_execution_date, 'debited_on', x.debited_on,
                            'liquidation_on', x.liquidation_on, 'downloaded', x.downloaded,
                            'cancellable', case when x.status = 'in_file'
                                                then not x.downloaded or public.cancellation_after_download() end,
                            'p0', true)
  from unnest(v_proc) c (id)
  cross join lateral private.client_payouts_after_liquidation(c.id, v_today) x
  where not x.disposed;

  -- (M2c-7e-1, plan §7.1) top_up_account_missing (alert): the servicer owes the dedicated account (design §13 #4's
  -- need > 0) and no active own account of that currency is in its billing settings — the hourly job orders nothing
  for v_curr in select distinct b.currency from public.bank_account b
                where b.organization_id = p_organization_id and b.purpose = 'client_funds' and b.status = 'active'
                order by b.currency loop
    v_need := private.top_up_needed(p_organization_id, v_curr);
    if v_need > 0 and not exists (select 1 from public.servicer_billing_settings s
                                  join public.bank_account a on a.id = s.own_bank_account_id
                                  where s.organization_id = p_organization_id and a.purpose = 'own'
                                    and a.status = 'active' and a.currency = v_curr) then
      -- (review round 1, TUI-9) as old as the open shortfall period (the Paris date of its opening; none before the
      -- hourly job opened one: no age), by servicer_shortfall_period_open_uq
      insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id,
                                               currency, amount_minor, count, oldest_days, details)
      values (p_check_run_id, p_organization_id, 'top_up_account_missing', 'alert', 'organization', p_organization_id,
              v_curr, v_need, 1,
              v_today - (select (q.opened_at at time zone 'Europe/Paris')::date
                         from private.servicer_shortfall_period q
                         where q.organization_id = p_organization_id and q.currency = v_curr and q.closed_at is null),
              jsonb_build_object('currency', v_curr, 'needed_minor', v_need::text));
    end if;
  end loop;

  -- (M2c-7e-1, plan §7.1 [critic] F8) top_up_order_failed (alert): the hourly job missed the servicer three times in a
  -- row (its lock held past 2 s) or failed (any other error) — what is needed is not ordered meanwhile. Review round 1
  -- (MONEY-BANK-4): or it no longer runs — its last run more than three hours back, or none for a servicer whose
  -- active dedicated account is older than that (pg_cron disabled, the remittances queue not consumed): `stale`.
  -- Review round 2 (stale-alert-no-dedicated-account): only while the servicer has an active dedicated account — the
  -- job is queued for no other (private.queue_top_ups) and orders nothing without one, so a state row left by its last
  -- run before the account's closure is never refreshed and would raise the alert every night for ever
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'top_up_order_failed', 'alert', 'organization', p_organization_id, null,
         null, greatest(coalesce(s.consecutive_misses, 0), 1),
         v_today - (coalesce(s.last_run_at, a.since) at time zone 'Europe/Paris')::date,
         jsonb_build_object('outcome', s.last_outcome, 'misses', coalesce(s.consecutive_misses, 0),
                            'error', s.last_error, 'last_run_at', s.last_run_at,
                            'stale', coalesce(s.last_run_at, a.since) < clock_timestamp() - interval '3 hours')
  from (select min(b.created_at) as since from public.bank_account b
        where b.organization_id = p_organization_id and b.purpose = 'client_funds' and b.status = 'active') a
  left join private.top_up_order_state s on s.organization_id = p_organization_id
  where a.since is not null
    and (s.last_outcome = 'failed' or (s.last_outcome = 'missed' and s.consecutive_misses >= 3)
         or coalesce(s.last_run_at, a.since) < clock_timestamp() - interval '3 hours');
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new ones internal, the worker's or the callers')
------------------------------------------------------------------------------------------

-- the new internals (PostgreSQL grants EXECUTE to PUBLIC by default): only the SECURITY DEFINER functions above call them
revoke execute on function private.amount_fr(bigint, character), private.servicer_owed_minor(uuid, character),
  private.top_up_needed(uuid, character), private.top_up_credit_seen(uuid),
  private.shortfall_log(uuid, character, bigint, timestamptz), private.queue_top_ups(),
  private.servicer_shortfall_period_guard(), private.transfer_file_item_guard(),
  private.top_up_file_close(uuid, text, uuid, text)
  from public, anon, authenticated, service_role;
-- the worker's: the hourly step and its record (jobs.top_ups), the loader's own-file fact (jobs.debits)
revoke execute on function private.order_due_top_up(uuid), private.record_top_up_order(uuid, text, integer, text),
  private.top_up_in_own_file(uuid)
  from public, anon, authenticated, service_role;
grant execute on function private.order_due_top_up(uuid), private.record_top_up_order(uuid, text, integer, text),
  private.top_up_in_own_file(uuid)
  to service_role;
-- the commands and reads: authenticated (money staff at aal2, checked inside); never anon
revoke execute on function public.generate_top_up_file(text, uuid), public.cancel_top_up_file(text, uuid, text),
  public.book_top_up_credit(text, uuid, uuid, text), public.top_up_overview(), public.top_up_credit_options(uuid),
  public.servicer_shortfall_periods(uuid, integer)
  from public, anon;
grant execute on function public.generate_top_up_file(text, uuid), public.cancel_top_up_file(text, uuid, text),
  public.book_top_up_credit(text, uuid, uuid, text), public.top_up_overview(), public.top_up_credit_options(uuid),
  public.servicer_shortfall_periods(uuid, integer)
  to authenticated;

-- the redefined, as their latest migrations left them
-- (20261119090000) the re-check: internal (private.post_bank_bookings only)
revoke execute on function private.bank_booking_recheck(uuid) from public, anon, authenticated, service_role;
-- (20261117090000) the funds pass's posting: the worker's
revoke execute on function private.apply_bank_bookings(uuid) from public, anon, authenticated, service_role;
grant execute on function private.apply_bank_bookings(uuid) to service_role;
-- (20261117090000, 20261117110000, 20261111090000) the back office's commands: authenticated; never anon
revoke execute on function public.transfer_file_download(uuid, text, boolean),
  public.assign_payment(text, uuid, jsonb, jsonb, text), public.resolve_duplicate(text, uuid, boolean, text),
  public.link_debit(text, uuid, text, uuid, uuid, text, text), public.cancel_top_up(text, uuid, text)
  from public, anon;
grant execute on function public.transfer_file_download(uuid, text, boolean),
  public.assign_payment(text, uuid, jsonb, jsonb, text), public.resolve_duplicate(text, uuid, boolean, text),
  public.link_debit(text, uuid, text, uuid, uuid, text, text), public.cancel_top_up(text, uuid, text)
  to authenticated;
-- (20261116090000, 20261115090000; review round 1) « Annuler » of the payout files: authenticated; the file job's failure:
-- the worker's
revoke execute on function public.cancel_transfer_file(text, uuid, integer, text, text) from public, anon;
grant execute on function public.cancel_transfer_file(text, uuid, integer, text, text) to authenticated;
revoke execute on function private.transfer_file_failed(uuid, uuid, text) from public, anon, authenticated;
grant execute on function private.transfer_file_failed(uuid, uuid, text) to service_role;
-- (20261128090000) the advance checks: internal
revoke execute on function private.run_advance_checks(uuid, uuid, date, boolean)
  from public, anon, authenticated, service_role;
-- (20261115090000, 20261111120000) the trigger functions: internal, as granted there
revoke execute on function private.transfer_file_guard(), private.bank_transfer_guard(),
  private.servicer_billing_settings_guard()
  from public, anon, authenticated;
