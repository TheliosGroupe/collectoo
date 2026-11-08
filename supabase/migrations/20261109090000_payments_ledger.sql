-- M2b-1 (M2-06): the ledger learns about payments, bank accounts and RF creditor references.
-- Design: docs/design/m2b-payments.md §5–§6; decisions: docs/adr/0013-payments-allocation-client-money.md.
-- Forward-only: functions of 20261108170000 / 180000 / 190000 are redefined here, never edited.
--
-- What changes for money:
--   * book 5120 `client_money_cash` (one ledger account per dedicated bank account, R124-2);
--   * entry types cash_in, allocation, forward, cash_out, netting (posted only by the set-based
--     private.ledger_post_set, called from other definer functions in M2b-2 … M2b-6);
--   * `adjustment` can no longer touch client money (4710, 4670);
--   * per entry, at commit: client-money books closed (I2), shapes (I3), per-payment remainder never
--     negative (I4, LG007), no receivable overdrawn after an allocation or a netting (I6, LG007);
--   * client-money ledger rows readable by admins and ops managers only (clients: their own 4670).

------------------------------------------------------------------------------------------
-- Check-digit helpers (ISO 7064 MOD 97-10: IBAN ISO 13616, RF creditor reference ISO 11649).
-- Python twin: collectoo_worker.payments.rf (a parity test compares them on random strings).
------------------------------------------------------------------------------------------

-- Remainder mod 97 of an upper-case alphanumeric string, letters as two digits (A = 10 … Z = 35).
-- The caller checks the alphabet first (anything else fails the numeric cast).
create or replace function private.mod97(p text)
returns integer
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  select (replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
          replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
            p, 'A', '10'), 'B', '11'), 'C', '12'), 'D', '13'), 'E', '14'), 'F', '15'), 'G', '16'), 'H', '17'),
            'I', '18'), 'J', '19'), 'K', '20'), 'L', '21'), 'M', '22'), 'N', '23'), 'O', '24'), 'P', '25'),
            'Q', '26'), 'R', '27'), 'S', '28'), 'T', '29'), 'U', '30'), 'V', '31'), 'W', '32'), 'X', '33'),
            'Y', '34'), 'Z', '35')::numeric % 97)::integer;
$$;

-- ISO 11649: "RF", two check digits (02-98), 1 to 21 characters among 0-9 A-Z; valid when the
-- string with its first four characters moved to the end is ≡ 1 (mod 97). Upper case, no spaces
-- (private.rf_normalise first for text typed by a person).
create or replace function private.rf_valid(p text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case when p ~ '^RF(0[2-9]|[1-8][0-9]|9[0-8])[0-9A-Z]{1,21}$'
              then private.mod97(substr(p, 5) || substr(p, 1, 4)) = 1
              else false end;
$$;

-- ASCII spaces and line breaks removed, ASCII letters upper-cased (anything else is kept, so it fails).
create or replace function private.rf_normalise(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select translate(regexp_replace(p, '[ \t\n\r\f\v]', '', 'g'), 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')
$$;

-- RF reference for a body: check digits = 98 - (body || "RF00" mod 97).
create or replace function private.rf_make(p_body text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_body is null or p_body !~ '^[0-9A-Z]{1,21}$' then
    raise exception 'an RF reference body has 1 to 21 characters among 0-9 and A-Z' using errcode = '22023';
  end if;
  return 'RF' || lpad((98 - private.mod97(p_body || 'RF00'))::text, 2, '0') || p_body;
end;
$$;

-- 12 random digits (no sequence: a reference says nothing about the size of a portfolio). The 60
-- bits come from the random part of a v4 UUID (pg_strong_random), past its version and variant bits.
create or replace function private.rf_random_body()
returns text
language sql
volatile
set search_path = ''
as $$
  select lpad((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 18, 15))::bit(60)::bigint
               % 1000000000000)::text, 12, '0');
$$;

-- IBAN (ISO 13616): country, check digits 02-98, 11 to 30 characters; ≡ 1 (mod 97) once rearranged.
create or replace function private.iban_valid(p text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case when p ~ '^[A-Z]{2}(0[2-9]|[1-8][0-9]|9[0-8])[0-9A-Z]{11,30}$'
              then private.mod97(substr(p, 5) || substr(p, 1, 4)) = 1
              else false end;
$$;

------------------------------------------------------------------------------------------
-- Who handles client money: admins and ops managers of the servicer, at aal2 (ADR-0013).
------------------------------------------------------------------------------------------

create or replace function private.money_staff_org_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.organization_id), '{}')
  from public.membership m
  join public.organization o on o.id = m.organization_id and o.kind = 'servicer'
  where m.user_id = (select auth.uid())
    and m.role in ('admin', 'ops_manager')
    and (select private.is_aal2());
$$;

------------------------------------------------------------------------------------------
-- Commands: idempotency key + request hash (a key reused for another request is refused).
------------------------------------------------------------------------------------------

alter table private.command_log add column request_hash text check (request_hash ~ '^[0-9a-f]{64}$');

create or replace function private.command_replay(p_command text, p_key text, p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v private.command_log;
begin
  if p_key is null or length(p_key) not between 8 and 200 then
    raise exception 'an idempotency key has 8 to 200 characters' using errcode = '22023';
  end if;
  select * into v from private.command_log where command = p_command and idempotency_key = p_key;
  if not found then
    return null;
  end if;
  if v.request_hash is distinct from encode(sha256(convert_to(p_request::text, 'UTF8')), 'hex')
     or v.actor_id is distinct from auth.uid() then
    raise exception 'idempotency key % was used for a different request', p_key using errcode = '22023';
  end if;
  return v.result;
end;
$$;

create or replace function private.command_record(p_command text, p_key text, p_request jsonb, p_result jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into private.command_log (command, idempotency_key, actor_id, result, request_hash)
  values (p_command, p_key, auth.uid(), p_result, encode(sha256(convert_to(p_request::text, 'UTF8')), 'hex'));
$$;

-- Facts kept for the record: never deleted (closing or retiring is a status).
create or replace function private.refuse_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% on % refused: these rows are kept for the record', tg_op, tg_table_name
    using errcode = 'check_violation';
end;
$$;

------------------------------------------------------------------------------------------
-- Bank accounts (CPCE R124-2: the dedicated account for funds collected for creditors)
------------------------------------------------------------------------------------------

create table public.bank_account (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  purpose text not null default 'client_funds' check (purpose = 'client_funds'),  -- 'own' with M2c
  iban text not null check (private.iban_valid(iban)),
  bic text check (bic ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$'),
  currency char(3) not null references public.currency (code),
  label text not null check (length(btrim(label)) between 1 and 100),
  feed text not null check (feed in ('camt053', 'csv')),
  csv_profile jsonb check (csv_profile is null or jsonb_typeof(csv_profile) = 'object'),
  status text not null default 'active' check (status in ('active', 'closed')),
  opened_on date not null,
  closed_on date check (closed_on >= opened_on),
  closed_reason text check (length(btrim(closed_reason)) between 1 and 2000),
  created_by uuid references public.app_user (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bank_account_closed check ((status = 'closed') = (closed_on is not null)
                                        and (status = 'closed') = (closed_reason is not null)),
  constraint bank_account_iban_uq unique (organization_id, iban, currency),
  constraint bank_account_ledger_key unique (id, organization_id, currency)
);
comment on table public.bank_account is
  'Bank accounts of the servicer. purpose client_funds = the account dedicated to funds collected for creditors (R124-2).';

-- The servicer owns it; purpose, IBAN and currency never change; a closed account stays closed.
create or replace function private.bank_account_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if not exists (select 1 from public.organization o where o.id = new.organization_id and o.kind = 'servicer') then
      raise exception 'a bank account belongs to a servicer organization' using errcode = 'check_violation';
    end if;
  elsif (new.id, new.organization_id, new.purpose, new.iban, new.currency, new.opened_on, new.created_by, new.created_at)
        is distinct from (old.id, old.organization_id, old.purpose, old.iban, old.currency, old.opened_on, old.created_by,
                          old.created_at)
     or (old.status = 'closed' and new.status <> 'closed') then
    raise exception 'bank account %: purpose, IBAN, currency and opening date are fixed; a closed account stays closed',
      old.id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger bank_account_guard before insert or update on public.bank_account
  for each row execute function private.bank_account_guard();
alter table public.bank_account enable always trigger bank_account_guard;
create trigger bank_account_no_delete before delete or truncate on public.bank_account
  for each statement execute function private.refuse_delete();
alter table public.bank_account enable always trigger bank_account_no_delete;
create trigger bank_account_touch before update on public.bank_account
  for each row execute function private.touch_updated_at();
create trigger bank_account_change_log after insert or update or delete on public.bank_account
  for each row execute function private.log_change();

------------------------------------------------------------------------------------------
-- Payments (sub-ledger; the bank facts are immutable). bank_transaction arrives in M2b-2,
-- which adds the foreign key on bank_transaction_id.
------------------------------------------------------------------------------------------

-- Client and portfolio of a payment or a reference are copied from the account and checked by FK.
alter table public.account add constraint account_tenant_key unique (id, organization_id, client_organization_id, portfolio_id);

create table public.payment (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  bank_account_id uuid,
  bank_transaction_id uuid unique,
  channel text not null check (channel in ('camt053', 'csv', 'psp')),
  method text not null check (method in ('sct', 'sdd', 'card', 'cheque', 'other')),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  currency char(3) not null references public.currency (code),
  booking_date date not null,           -- « encaissement » date for R124-6 (M2c)
  value_date date,
  payer_name text,
  payer_iban text,
  end_to_end_id text,
  remittance_text text,
  creditor_reference text,
  status text not null default 'unmatched' check (status in (
    'unmatched', 'matched', 'partially_allocated', 'allocated', 'refund_pending', 'refunded', 'returned')),
  review_reason text check (review_reason in (
    'no_match', 'ambiguous', 'overpayment', 'account_not_confirmed', 'no_mandate', 'account_closed',
    'currency_mismatch', 'before_servicing_start', 'hold_blocks_allocation', 'nothing_due',
    'credit_note_to_apply', 'partial_return')),
  account_id uuid,                      -- null until matched; never a staged account
  candidate_account_id uuid,            -- soft link, no FK (may be a staged account)
  client_organization_id uuid,          -- copied from the account (RLS)
  portfolio_id uuid,                    -- copied from the account (RLS)
  designation jsonb check (designation is null or jsonb_typeof(designation) = 'object'),
  match_method text check (match_method in (
    'rf_structured', 'rf_text', 'rf_body', 'item_ref', 'iban_memory', 'manual', 'rematch')),
  matched_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payment_bank_fk foreign key (bank_account_id, organization_id, currency)
    references public.bank_account (id, organization_id, currency),
  constraint payment_account_fk foreign key (account_id, organization_id, client_organization_id, portfolio_id)
    references public.account (id, organization_id, client_organization_id, portfolio_id),
  constraint payment_bank_channel check (channel = 'psp' or bank_account_id is not null),
  constraint payment_scope check ((account_id is null) = (portfolio_id is null)
                                  and (account_id is null) = (client_organization_id is null)),
  constraint payment_match check ((account_id is null) or (match_method is not null and matched_at is not null)),
  constraint payment_unmatched check (status <> 'unmatched' or account_id is null)
);
create index payment_review_idx on public.payment (organization_id, review_reason, booking_date) where review_reason is not null;
create index payment_account_idx on public.payment (account_id);
create index payment_portfolio_idx on public.payment (portfolio_id);
create index payment_payer_iban_idx on public.payment (payer_iban);
create index payment_end_to_end_idx on public.payment (end_to_end_id);
create index payment_status_idx on public.payment (organization_id, status);
comment on table public.payment is
  'One row per debtor credit on a client_funds account (or PSP event, M5). Bank facts immutable; status summarises the ledger.';

create or replace function private.payment_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v public.account;
begin
  if tg_op = 'UPDATE' and (new.id, new.organization_id, new.bank_account_id, new.bank_transaction_id, new.channel,
       new.method, new.amount_minor, new.currency, new.booking_date, new.value_date, new.payer_name, new.payer_iban,
       new.end_to_end_id, new.remittance_text, new.creditor_reference, new.created_at)
     is distinct from (old.id, old.organization_id, old.bank_account_id, old.bank_transaction_id, old.channel,
       old.method, old.amount_minor, old.currency, old.booking_date, old.value_date, old.payer_name, old.payer_iban,
       old.end_to_end_id, old.remittance_text, old.creditor_reference, old.created_at) then
    raise exception 'payment %: the bank facts are immutable', old.id using errcode = 'check_violation';
  end if;
  if new.account_id is null then
    new.client_organization_id := null;
    new.portfolio_id := null;
    return new;
  end if;
  select * into v from public.account where id = new.account_id;
  if not found or v.organization_id <> new.organization_id then
    raise exception 'payment %: account % is not in this organization', new.id, new.account_id
      using errcode = 'check_violation';
  end if;
  if v.status = 'staged' and (tg_op = 'INSERT' or new.account_id is distinct from old.account_id) then
    raise exception 'payment %: account % is not confirmed yet', new.id, new.account_id using errcode = 'check_violation';
  end if;
  new.client_organization_id := v.client_organization_id;
  new.portfolio_id := v.portfolio_id;
  return new;
end;
$$;
create trigger payment_guard before insert or update on public.payment
  for each row execute function private.payment_guard();
alter table public.payment enable always trigger payment_guard;
create trigger payment_no_delete before delete or truncate on public.payment
  for each statement execute function private.refuse_delete();
alter table public.payment enable always trigger payment_no_delete;
create trigger payment_touch before update on public.payment
  for each row execute function private.touch_updated_at();
create trigger payment_change_log after insert or update or delete on public.payment
  for each row execute function private.log_change();

------------------------------------------------------------------------------------------
-- Payment references: one active RF creditor reference per workable account (ISO 11649)
------------------------------------------------------------------------------------------

create table public.payment_reference (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  client_organization_id uuid not null,
  portfolio_id uuid not null,
  account_id uuid not null,
  -- RF + 2 check digits + 12 digits; the ISO 11649 check written out for a digits-only body ("RF" is
  -- 2715), inline: a function call per row costs seconds at 50k (pgTAP: same answer as rf_valid).
  rf text not null check (case when rf ~ '^RF(0[2-9]|[1-8][0-9]|9[0-8])[0-9]{12}$'
                               then (substr(rf, 5) || '2715' || substr(rf, 3, 2))::numeric % 97 = 1
                               else false end),
  status text not null default 'active' check (status in ('active', 'retired')),
  created_at timestamptz not null default now(),
  retired_at timestamptz,
  retired_reason text check (length(btrim(retired_reason)) between 1 and 2000),
  constraint payment_reference_account_fk foreign key (account_id, organization_id, client_organization_id, portfolio_id)
    references public.account (id, organization_id, client_organization_id, portfolio_id),
  constraint payment_reference_rf_uq unique (organization_id, rf),
  constraint payment_reference_retired check ((status = 'retired') = (retired_at is not null)
                                              and (status = 'retired') = (retired_reason is not null))
);
create unique index payment_reference_one_active_uq on public.payment_reference (account_id) where status = 'active';
create index payment_reference_portfolio_idx on public.payment_reference (portfolio_id);
comment on table public.payment_reference is
  'RF creditor references (RF + 2 check digits + 12 random digits). One active per account; retired ones keep resolving.';

-- Only workable accounts get one (aggregate over the new rows, not LIMIT 1: see 20261108180000).
create or replace function private.payment_reference_insert_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(n.account_id::text) into v_bad
  from new_rows n join public.account a on a.id = n.account_id
  where a.status = 'staged' or n.status <> 'active';
  if v_bad is not null then
    raise exception 'payment reference: account % is not confirmed yet, or the reference is not issued active', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger payment_reference_insert_guard after insert on public.payment_reference
  referencing new table as new_rows for each statement execute function private.payment_reference_insert_guard();
alter table public.payment_reference enable always trigger payment_reference_insert_guard;

-- A reference is only ever retired (with when and why); nothing else changes.
create or replace function private.payment_reference_update_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.id, new.organization_id, new.client_organization_id, new.portfolio_id, new.account_id, new.rf, new.created_at)
     is distinct from (old.id, old.organization_id, old.client_organization_id, old.portfolio_id, old.account_id, old.rf,
                       old.created_at)
     or old.status <> 'active' or new.status <> 'retired' then
    raise exception 'payment reference %: it can only be retired', old.id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger payment_reference_update_guard before update on public.payment_reference
  for each row execute function private.payment_reference_update_guard();
alter table public.payment_reference enable always trigger payment_reference_update_guard;
create trigger payment_reference_no_delete before delete or truncate on public.payment_reference
  for each statement execute function private.refuse_delete();
alter table public.payment_reference enable always trigger payment_reference_no_delete;
create trigger payment_reference_change_log after insert or update or delete on public.payment_reference
  for each row execute function private.log_change();

-- Issue one reference to every workable account of a batch (or, with null, of every batch) that has
-- none. Set-based; a random body that collides is drawn again in the next round.
create or replace function private.issue_payment_references(p_batch_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_missing bigint;
  v_n bigint;
  v_total bigint := 0;
  v_round integer := 0;
begin
  loop
    -- count(*), not EXISTS: the planner then plans for reading every row (no nested-loop bet).
    if p_batch_id is null then
      select count(*) into v_missing from public.account a
      where a.status <> 'staged'
        and not exists (select 1 from public.payment_reference r where r.account_id = a.id and r.status = 'active');
    else
      select count(*) into v_missing from public.account a
      where a.boarding_batch_id = p_batch_id and a.status <> 'staged'
        and not exists (select 1 from public.payment_reference r where r.account_id = a.id and r.status = 'active');
    end if;
    exit when v_missing = 0;
    v_round := v_round + 1;
    if v_round > 5 then
      raise exception 'payment reference: % accounts still without a reference after 5 rounds', v_missing;
    end if;
    -- rf_make(rf_random_body()) written out inline (no function call per row): the body is drawn
    -- per row in the subquery's select list, the check digits are 98 - (body || "RF00" mod 97).
    if p_batch_id is null then
      insert into public.payment_reference (organization_id, client_organization_id, portfolio_id, account_id, rf)
      select x.organization_id, x.client_organization_id, x.portfolio_id, x.id,
             'RF' || lpad((98 - (x.body || '271500')::numeric % 97)::text, 2, '0') || x.body
      from (select a.organization_id, a.client_organization_id, a.portfolio_id, a.id,
                   lpad((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 18, 15))::bit(60)::bigint
                         % 1000000000000)::text, 12, '0') as body
            from public.account a
            where a.status <> 'staged'
              and not exists (select 1 from public.payment_reference r where r.account_id = a.id and r.status = 'active')
            offset 0) x
      on conflict do nothing;
    else
      insert into public.payment_reference (organization_id, client_organization_id, portfolio_id, account_id, rf)
      select x.organization_id, x.client_organization_id, x.portfolio_id, x.id,
             'RF' || lpad((98 - (x.body || '271500')::numeric % 97)::text, 2, '0') || x.body
      from (select a.organization_id, a.client_organization_id, a.portfolio_id, a.id,
                   lpad((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 18, 15))::bit(60)::bigint
                         % 1000000000000)::text, 12, '0') as body
            from public.account a
            where a.boarding_batch_id = p_batch_id and a.status <> 'staged'
              and not exists (select 1 from public.payment_reference r where r.account_id = a.id and r.status = 'active')
            offset 0) x
      on conflict do nothing;
    end if;
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
  end loop;
  return v_total;
end;
$$;

------------------------------------------------------------------------------------------
-- Ledger extension (§5.1): cash book 5120 per bank account, payment entry types
------------------------------------------------------------------------------------------

alter table public.ledger_book drop constraint ledger_book_dimension_check,
  add constraint ledger_book_dimension_check check (dimension in ('claim', 'owner', 'client', 'pooled', 'bank'));
insert into public.ledger_book values
  ('client_money_cash', '5120', 'Compte dédié aux fonds de tiers (R124-2)', 'bank', 'client', 1, false);
-- 5121 PSP clearing (M5), 5122 own cash and 6270 fees (M2c): still refused until seeded (fail closed).
comment on table public.ledger_book is
  'Chart of accounts (ARCHITECTURE §8). 5120 per client_funds bank account since M2b; 5121/5122/6270 not seeded yet.';

insert into public.ledger_entry_type values
  ('cash_in',    'Encaissement',                            array['client_money_cash', 'unallocated_payment'], false),
  ('allocation', 'Imputation',                              array['unallocated_payment', 'client_payable', 'debtor_receivable', 'owner_claim'], false),
  ('forward',    'Reversement au mandant sans imputation',  array['unallocated_payment', 'client_payable'], true),
  ('cash_out',   'Retour ou restitution',                   array['unallocated_payment', 'client_money_cash'], true),
  ('netting',    'Application d''un avoir',                 array['debtor_receivable'], true);
-- Client money no longer moves through a generic correction (M2-12, CPCE-02).
update public.ledger_entry_type set allowed_books = array['debtor_receivable', 'owner_claim'] where code = 'adjustment';

alter table public.ledger_account add column bank_account_id uuid,
  add constraint ledger_account_bank_fk foreign key (bank_account_id, organization_id, currency)
    references public.bank_account (id, organization_id, currency);
alter table public.ledger_account drop constraint ledger_account_shape,
  add constraint ledger_account_shape check (case book
    when 'debtor_receivable' then account_id is not null and claim_item_id is not null and component is not null
      and client_organization_id is not null and portfolio_id is not null and owner_organization_id is null
      and bank_account_id is null
    when 'owner_claim' then account_id is null and claim_item_id is null and component is not null
      and client_organization_id is not null and owner_organization_id is not null and portfolio_id is not null
      and bank_account_id is null
    when 'client_payable' then client_organization_id is not null and portfolio_id is null and account_id is null
      and claim_item_id is null and component is null and owner_organization_id is null and bank_account_id is null
    when 'unallocated_payment' then portfolio_id is null and account_id is null and claim_item_id is null
      and component is null and owner_organization_id is null and bank_account_id is null
    when 'servicer_revenue' then client_organization_id is not null and portfolio_id is null and account_id is null
      and claim_item_id is null and component is null and owner_organization_id is null and bank_account_id is null
    when 'client_money_cash' then bank_account_id is not null and client_organization_id is null
      and owner_organization_id is null and portfolio_id is null and account_id is null and claim_item_id is null
      and component is null
    else false end);
drop index public.ledger_account_pooled_uq;
create unique index ledger_account_pooled_uq on public.ledger_account
  (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component, bank_account_id)
  nulls not distinct where claim_item_id is null;
create index ledger_account_bank_idx on public.ledger_account (bank_account_id) where bank_account_id is not null;

alter table public.ledger_entry add column payment_id uuid references public.payment (id),
  add constraint ledger_entry_payment_req check (entry_type not in ('allocation', 'forward', 'cash_out') or payment_id is not null),
  add constraint ledger_entry_payment_only check (payment_id is null or entry_type in ('allocation', 'forward', 'cash_out', 'reversal')),
  add constraint ledger_entry_cash_in_src check (entry_type <> 'cash_in' or (source_type = 'bank_statement' and source_id is not null));
  -- M5 widens the last one to source_type 'psp_event' (one cash_in per PSP event, book 5121).
create index ledger_entry_payment_idx on public.ledger_entry (payment_id) where payment_id is not null;

------------------------------------------------------------------------------------------
-- Guards (redefined; min() instead of LIMIT 1, see 20261108180000)
------------------------------------------------------------------------------------------

create or replace function private.ledger_account_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(coalesce(n.id::text, '?')) into v_bad from new_rows n
  where not exists (select 1 from public.ledger_book b where b.code = n.book)
     or not exists (select 1 from public.currency c where c.code = n.currency)
     or (n.component is not null and not exists (select 1 from public.ledger_component c where c.code = n.component))
     -- the servicer is a servicer; clients, owners and portfolios belong to it
     or not exists (select 1 from public.organization o where o.id = n.organization_id and o.kind = 'servicer')
     or (n.client_organization_id is not null and not exists (
           select 1 from public.organization o
           where o.id = n.client_organization_id and o.servicer_organization_id = n.organization_id))
     or (n.owner_organization_id is not null and not exists (
           select 1 from public.organization o where o.id = n.owner_organization_id))
     or (n.portfolio_id is not null and not exists (
           select 1 from public.portfolio p
           where p.id = n.portfolio_id and p.organization_id = n.organization_id
             and p.client_organization_id = n.client_organization_id))
     or (n.claim_item_id is not null and not exists (
           select 1 from public.claim_item i where i.id = n.claim_item_id and i.currency = n.currency))
     -- debtor cash lands only on an active account dedicated to client funds (R124-2, CPCE-02)
     or (n.bank_account_id is not null and not exists (
           select 1 from public.bank_account b
           where b.id = n.bank_account_id and b.organization_id = n.organization_id and b.currency = n.currency
             and b.purpose = 'client_funds' and b.status = 'active'));
  if v_bad is not null then
    raise exception 'ledger: ledger account % is not coherent (book, currency, component, tenant, item or bank account)', v_bad
      using errcode = 'LG002';
  end if;
  return null;
end;
$$;

create or replace function private.ledger_entry_guard()
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
             and p.client_organization_id = n.client_organization_id))
     or (n.account_id is not null and not exists (
           select 1 from public.account a
           where a.id = n.account_id and a.portfolio_id = n.portfolio_id and a.organization_id = n.organization_id))
     or (n.payment_id is not null and not exists (
           select 1 from public.payment p where p.id = n.payment_id and p.organization_id = n.organization_id));
  if v_bad is not null then
    raise exception 'ledger: entry % is outside its tenant (organization, client, portfolio, account, payment)', v_bad
      using errcode = 'LG002';
  end if;
  -- A reversal keeps the reversed entry's scope and payment; a cash_in is never reversed (a wrong
  -- statement line is corrected by a payment-tagged cash_out).
  select min(n.id::text) into v_bad from new_rows n
  left join public.ledger_entry t on t.id = n.reverses_entry_id
  where n.reverses_entry_id is not null
    and (t.id is null or t.reverses_entry_id is not null
         or t.entry_type = 'cash_in'
         or t.organization_id <> n.organization_id
         or t.client_organization_id is distinct from n.client_organization_id
         or t.portfolio_id is distinct from n.portfolio_id
         or t.account_id is distinct from n.account_id
         or t.payment_id is distinct from n.payment_id
         or t.line_count <> n.line_count
         or n.effective_date < t.effective_date);
  if v_bad is not null then
    raise exception 'ledger: reversal % does not match the entry it reverses', v_bad using errcode = 'LG003';
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- Commit-time check per entry (redefined): M2a checks, then I2, I3, I4, I6 of the design.
-- Runs once per entry at commit, often right after a bulk insert no ANALYZE has seen, and its plans
-- are cached for the session: key lookups only, whatever the statistics say.
------------------------------------------------------------------------------------------

create or replace function private.ledger_entry_verify()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_lines bigint;
  v_cur text;
  v_bad text;
  v_pay public.payment;
  v_ok boolean;
  v_shape record;
begin
  select coalesce(sum(n), 0), min(currency) filter (where s <> 0) into v_lines, v_cur
  from (select currency, count(*) n, sum(amount_minor) s from public.ledger_posting
        where entry_id = new.id group by currency) x;
  if v_lines <> new.line_count then
    raise exception 'ledger: entry % has % of its % lines', new.id, v_lines, new.line_count using errcode = 'LG001';
  end if;
  if v_cur is not null then
    raise exception 'ledger: entry % is not balanced in %', new.id, v_cur using errcode = 'LG001';
  end if;
  -- Receivable and owner claim move by opposite amounts per (component, currency).
  -- One key lookup per line (a hash join would scan every ledger account for every entry).
  select min(y.k) into v_bad from (
    select x.component || ' ' || x.currency as k
    from (select p.currency, p.amount_minor,
                 (select la.component from public.ledger_account la
                  where la.id = p.ledger_account_id and la.book in ('debtor_receivable', 'owner_claim')) as component
          from public.ledger_posting p where p.entry_id = new.id) x
    where x.component is not null
    group by x.component, x.currency having sum(x.amount_minor) <> 0) y;
  if v_bad is not null then
    raise exception 'ledger: entry % breaks the receivable/owner-claim mirror (%)', new.id, v_bad using errcode = 'LG001';
  end if;
  -- A reversal negates the reversed entry line by line, on the same ledger accounts.
  if new.reverses_entry_id is not null and exists (
    select 1
    from (select line_no, ledger_account_id, amount_minor from public.ledger_posting where entry_id = new.id) r
    full join (select line_no, ledger_account_id, amount_minor from public.ledger_posting
               where entry_id = new.reverses_entry_id) o using (line_no)
    where r.ledger_account_id is distinct from o.ledger_account_id or r.amount_minor is distinct from -o.amount_minor
  ) then
    raise exception 'ledger: reversal % does not mirror entry %', new.id, new.reverses_entry_id using errcode = 'LG003';
  end if;
  if new.entry_type = 'opening' then
    return null;  -- claim books only, on new ledger accounts: nothing below applies
  end if;

  -- I2: client-money books (5120, 4710, 4670) are closed in every entry, per currency.
  select min(y.currency) into v_bad from (
    select p.currency from public.ledger_posting p
    where p.entry_id = new.id
      and (select b.money_of from public.ledger_account la join public.ledger_book b on b.code = la.book
           where la.id = p.ledger_account_id) = 'client'
    group by p.currency having sum(p.amount_minor) <> 0) y;
  if v_bad is not null then
    raise exception 'ledger: entry % moves client money in % without its counterpart (closure)', new.id, v_bad
      using errcode = 'LG001';
  end if;

  -- I3: the shape of each payment entry type (4710 lines are on the pooled account).
  if new.entry_type in ('cash_in', 'allocation', 'forward', 'cash_out', 'netting') then
    select count(*) as n,
           count(*) filter (where x.book = 'client_money_cash' and x.amount_minor > 0) as cash_dr,
           count(*) filter (where x.book = 'client_money_cash' and x.amount_minor < 0) as cash_cr,
           count(*) filter (where x.book = 'unallocated_payment') as pool_n,
           count(*) filter (where x.book = 'unallocated_payment' and x.client_organization_id is null
                            and x.amount_minor > 0) as pool_dr,
           count(*) filter (where x.book = 'unallocated_payment' and x.client_organization_id is null
                            and x.amount_minor < 0) as pool_cr,
           count(*) filter (where x.book = 'client_payable') as pay_n,
           count(*) filter (where x.book = 'client_payable' and x.amount_minor < 0) as pay_cr,
           count(*) filter (where x.book = 'debtor_receivable' and x.amount_minor < 0) as rec_cr,
           count(*) filter (where x.book = 'debtor_receivable' and x.amount_minor > 0) as rec_dr,
           count(*) filter (where x.book = 'owner_claim' and x.amount_minor > 0) as own_dr,
           count(*) filter (where x.component is distinct from 'principal') as not_principal
    into v_shape
    from (select p.amount_minor, la.book, la.client_organization_id, la.component
          from public.ledger_posting p
          cross join lateral (select l.book, l.client_organization_id, l.component
                              from public.ledger_account l where l.id = p.ledger_account_id) la
          where p.entry_id = new.id) x;
    v_ok := case new.entry_type
      when 'cash_in' then v_shape.n = 2 and v_shape.cash_dr = 1 and v_shape.pool_cr = 1
      when 'cash_out' then v_shape.n = 2 and v_shape.pool_dr = 1 and v_shape.cash_cr = 1
      when 'forward' then v_shape.n = 2 and v_shape.pool_dr = 1 and v_shape.pay_cr = 1
      when 'allocation' then v_shape.pool_n = 1 and v_shape.pool_dr = 1 and v_shape.pay_n = 1 and v_shape.pay_cr = 1 and v_shape.rec_cr >= 1
        and v_shape.rec_dr = 0 and v_shape.n = 2 + v_shape.rec_cr + v_shape.own_dr
      when 'netting' then v_shape.not_principal = 0
    end;
    if not v_ok then
      raise exception 'ledger: entry % does not have the shape of a % entry', new.id, new.entry_type using errcode = 'LG001';
    end if;
  end if;

  -- I4: per payment, at every date, what is left of it is never negative; per (payment, account),
  -- the net amount allocated is never negative. A payment has a handful of entries.
  if new.payment_id is not null then
    select * into v_pay from public.payment where id = new.payment_id;
    select min(p.currency) into v_bad from public.ledger_posting p
    where p.entry_id = new.id and p.currency <> v_pay.currency;
    if v_bad is not null then
      raise exception 'ledger: entry % moves % for a payment in %', new.id, v_bad, v_pay.currency using errcode = 'LG002';
    end if;
    with t as (
      select e.effective_date as d, e.account_id,
             coalesce((select sum(x.amount_minor) from public.ledger_posting x
                       where x.entry_id = e.id
                         and (select la.book from public.ledger_account la where la.id = x.ledger_account_id)
                             = 'unallocated_payment'), 0) as pool
      from public.ledger_entry e where e.payment_id = new.payment_id
    ),
    per_day as (select d, sum(pool) as pool from t group by d),
    per_account as (select d, account_id, sum(pool) as pool from t group by d, account_id),
    left_over as (
      select d, case when d >= v_pay.booking_date then v_pay.amount_minor else 0 end
                - sum(pool) over (order by d) as u
      from per_day),
    net as (select d, sum(pool) over (partition by account_id order by d) as allocated from per_account)
    select min(z.d)::text into v_bad
    from (select d from left_over where u < 0 union all select d from net where allocated < 0) z;
    if v_bad is not null then
      raise exception 'ledger: payment % would be overdrawn on % (entry %)', new.payment_id, v_bad, new.id
        using errcode = 'LG007';
    end if;
  end if;

  -- I6: a receivable credited by an allocation or a netting dated D never goes below zero from D
  -- on; a credit item debited by a netting dated D never goes above zero from D on. Checked for
  -- every entry that moves such a receivable (corrections and reversals included), so it holds
  -- after any sequence of entries.
  if new.entry_type in ('allocation', 'netting', 'adjustment', 'reversal') then
    select min(x.ledger_account_id::text) into v_bad
    from (
      select a.ledger_account_id, a.has_cr, a.has_dr,
             (select min(q.effective_date) from public.ledger_posting q
              where q.ledger_account_id = a.ledger_account_id and q.amount_minor < 0
                and (select e.entry_type from public.ledger_entry e where e.id = q.entry_id)
                    in ('allocation', 'netting')) as d_cr,
             (select min(q.effective_date) from public.ledger_posting q
              where q.ledger_account_id = a.ledger_account_id and q.amount_minor > 0
                and (select e.entry_type from public.ledger_entry e where e.id = q.entry_id) = 'netting') as d_dr
      from (select p.ledger_account_id, bool_or(p.amount_minor < 0) as has_cr, bool_or(p.amount_minor > 0) as has_dr
            from public.ledger_posting p
            where p.entry_id = new.id
              and (select la.book from public.ledger_account la where la.id = p.ledger_account_id) = 'debtor_receivable'
            group by p.ledger_account_id) a
    ) x
    cross join lateral (
      select min(r.bal) filter (where r.d >= x.d_cr) as low, max(r.bal) filter (where r.d >= x.d_dr) as high
      from (select g.d, sum(g.s) over (order by g.d) as bal
            from (select q.effective_date as d, sum(q.amount_minor) as s from public.ledger_posting q
                  where q.ledger_account_id = x.ledger_account_id group by q.effective_date) g) r
    ) w
    where (x.has_cr and x.d_cr is not null and w.low < 0)
       or (x.has_dr and x.d_dr is not null and w.high > 0);
    if v_bad is not null then
      raise exception 'ledger: entry % would overdraw receivable %', new.id, v_bad using errcode = 'LG007';
    end if;
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- Write path (redefined): new ON CONFLICT target; payment types refused by ledger_post; reversal
-- keeps the payment; the allocation lock (§5.2) for whatever can lower a payment or a receivable.
------------------------------------------------------------------------------------------

create or replace function private.ledger_post(
  p_organization_id uuid,
  p_entry_type text,
  p_effective_date date,
  p_idempotency_key text,
  p_lines jsonb,
  p_meta jsonb default '{}'
)
returns table (entry_id uuid, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_type public.ledger_entry_type;
  v_account public.account;
  v_account_id uuid := nullif(p_meta ->> 'account_id', '')::uuid;
  v_reason text := nullif(btrim(p_meta ->> 'reason'), '');
  v_client uuid;
  v_owner uuid;
  v_n integer;
  v_has_claim boolean;
  v_bad text;
  v_hash text;
  v_id uuid;
  v_existing_hash text;
begin
  select * into v_type from public.ledger_entry_type where code = p_entry_type;
  if not found or p_entry_type in ('opening', 'reversal', 'cash_in', 'allocation', 'forward', 'cash_out', 'netting') then
    raise exception 'ledger: entry type % cannot be posted here', p_entry_type using errcode = 'LG006';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception 'ledger: lines must be an array' using errcode = 'LG006';
  end if;
  v_n := jsonb_array_length(p_lines);
  if v_n < 2 or v_n > 100000 then
    raise exception 'ledger: an entry has 2 to 100000 lines (got %)', v_n using errcode = 'LG006';
  end if;
  if p_effective_date is null or p_effective_date > private.paris_today() then
    raise exception 'ledger: effective date % is missing or in the future', p_effective_date using errcode = 'LG006';
  end if;
  if v_type.requires_reason and v_reason is null then
    raise exception 'ledger: a % needs a reason', p_entry_type using errcode = 'LG006';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_lines) l
    where jsonb_typeof(l) <> 'object'
       or jsonb_typeof(l -> 'amount_minor') is distinct from 'number'
       or (l ->> 'amount_minor') !~ '^-?[0-9]{1,16}$'
       or (l ->> 'amount_minor')::bigint = 0
       or coalesce(l ->> 'currency', '') !~ '^[A-Z]{3}$'
       or (l ->> 'book') is null
  ) then
    raise exception 'ledger: every line needs a book, a non-zero integer amount_minor and a currency'
      using errcode = 'LG006';
  end if;

  -- Lines, parsed once. Never reuse a relation the caller created under this name (it could carry
  -- triggers that would run with the definer's rights): drop it and create our own.
  drop table if exists pg_temp._ledger_lines;
  create temp table _ledger_lines (
    line_no integer, book text, amount_minor bigint, currency char(3), claim_item_id uuid,
    component text, client_organization_id uuid, owner_organization_id uuid, portfolio_id uuid,
    ledger_account_id uuid) on commit drop;
  insert into pg_temp._ledger_lines (line_no, book, amount_minor, currency, claim_item_id, component, client_organization_id)
  select ord::integer, l ->> 'book', (l ->> 'amount_minor')::bigint, l ->> 'currency',
         nullif(l ->> 'claim_item_id', '')::uuid, nullif(l ->> 'component', ''),
         nullif(l ->> 'client_organization_id', '')::uuid
  from jsonb_array_elements(p_lines) with ordinality as t (l, ord);

  if exists (select 1 from pg_temp._ledger_lines l where not exists (select 1 from public.ledger_book b where b.code = l.book)
                                                 or not (l.book = any (v_type.allowed_books))) then
    raise exception 'ledger: a line uses a book not allowed for a % entry', p_entry_type using errcode = 'LG002';
  end if;

  v_has_claim := exists (select 1 from pg_temp._ledger_lines where book in ('debtor_receivable', 'owner_claim'));
  if v_has_claim then
    if v_account_id is null then
      raise exception 'ledger: claim lines need meta.account_id' using errcode = 'LG006';
    end if;
    select * into v_account from public.account where id = v_account_id;
    if not found or v_account.organization_id <> p_organization_id then
      raise exception 'ledger: account % is not in this organization', v_account_id using errcode = 'LG002';
    end if;
    if v_account.status = 'staged' then
      raise exception 'ledger: account % is not confirmed yet (staged)', v_account_id using errcode = 'LG006';
    end if;
    if p_effective_date < (select min(valid_from) from public.claim_ownership_period where account_id = v_account_id) then
      raise exception 'ledger: % is before the servicing of account % started', p_effective_date, v_account_id
        using errcode = 'LG006';
    end if;
    select o.owner_organization_id into v_owner from public.claim_ownership_period o
    where o.account_id = v_account_id and o.valid_from <= p_effective_date
      and (o.valid_to is null or o.valid_to > p_effective_date);
    if v_owner is null then
      raise exception 'ledger: no owner of account % on %', v_account_id, p_effective_date using errcode = 'LG006';
    end if;
    v_client := v_account.client_organization_id;
    if exists (
      select 1 from pg_temp._ledger_lines l
      where (l.book = 'debtor_receivable' and (l.claim_item_id is null or l.component is null
              or l.currency <> v_account.currency
              or not exists (select 1 from public.claim_item i where i.id = l.claim_item_id and i.account_id = v_account_id)))
         or (l.book = 'owner_claim' and (l.component is null or l.claim_item_id is not null or l.currency <> v_account.currency))
    ) then
      raise exception 'ledger: claim lines must name an item of account %, a component and its currency', v_account_id
        using errcode = 'LG002';
    end if;
  elsif v_account_id is not null then
    raise exception 'ledger: meta.account_id given without claim lines' using errcode = 'LG006';
  end if;

  -- Client lines: the client must be a client of this servicer; one client per entry.
  if exists (
    select 1 from pg_temp._ledger_lines l
    where l.book not in ('debtor_receivable', 'owner_claim')
      and (l.claim_item_id is not null or l.component is not null
           or (l.client_organization_id is null and l.book <> 'unallocated_payment')
           or (l.client_organization_id is not null and not exists (
                 select 1 from public.organization o
                 where o.id = l.client_organization_id and o.servicer_organization_id = p_organization_id)))
  ) then
    raise exception 'ledger: client lines must name a client of this servicer' using errcode = 'LG002';
  end if;
  if (select count(distinct x) from (
        select v_client as x where v_client is not null
        union all select client_organization_id from pg_temp._ledger_lines where client_organization_id is not null) c) > 1 then
    raise exception 'ledger: an entry concerns one client at most' using errcode = 'LG002';
  end if;
  v_client := coalesce(v_client, (select min(client_organization_id::text)::uuid from pg_temp._ledger_lines));

  -- Fail fast (the deferred check is the backstop).
  select currency into v_bad from pg_temp._ledger_lines group by currency having sum(amount_minor) <> 0 limit 1;
  if found then
    raise exception 'ledger: entry is not balanced in %', v_bad using errcode = 'LG001';
  end if;
  select component || ' ' || currency into v_bad from pg_temp._ledger_lines
  where book in ('debtor_receivable', 'owner_claim') group by component, currency having sum(amount_minor) <> 0 limit 1;
  if found then
    raise exception 'ledger: entry breaks the receivable/owner-claim mirror (%)', v_bad using errcode = 'LG001';
  end if;

  -- A correction that lowers a receivable waits for running allocations of this servicer (§5.2).
  if exists (select 1 from pg_temp._ledger_lines where book = 'debtor_receivable' and amount_minor < 0) then
    perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  end if;

  -- Get or create the ledger accounts.
  update pg_temp._ledger_lines set client_organization_id = v_client where book in ('debtor_receivable', 'owner_claim');
  update pg_temp._ledger_lines set portfolio_id = v_account.portfolio_id where book in ('debtor_receivable', 'owner_claim');
  update pg_temp._ledger_lines set owner_organization_id = v_owner where book = 'owner_claim';
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, portfolio_id,
                                     account_id, claim_item_id, component)
  select distinct p_organization_id, 'debtor_receivable', l.currency, l.client_organization_id, l.portfolio_id,
         v_account_id, l.claim_item_id, l.component
  from pg_temp._ledger_lines l where l.book = 'debtor_receivable'
  on conflict (claim_item_id, component) do nothing;
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, owner_organization_id,
                                     portfolio_id, component)
  select distinct p_organization_id, l.book, l.currency, l.client_organization_id, l.owner_organization_id,
         l.portfolio_id, l.component
  from pg_temp._ledger_lines l where l.book <> 'debtor_receivable'
  on conflict (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component,
               bank_account_id)
    where claim_item_id is null do nothing;
  update pg_temp._ledger_lines l set ledger_account_id = la.id
  from public.ledger_account la
  where (l.book = 'debtor_receivable' and la.claim_item_id = l.claim_item_id and la.component = l.component)
     or (l.book <> 'debtor_receivable' and la.claim_item_id is null and la.organization_id = p_organization_id
         and la.book = l.book and la.currency = l.currency
         and la.client_organization_id is not distinct from l.client_organization_id
         and la.owner_organization_id is not distinct from l.owner_organization_id
         and la.portfolio_id is not distinct from l.portfolio_id
         and la.component is not distinct from l.component
         and la.bank_account_id is null);

  -- Canonical request hash: line order does not matter.
  v_hash := encode(sha256(convert_to(jsonb_build_object(
    'type', p_entry_type,
    'effective_date', p_effective_date,
    'account_id', v_account_id,
    'source', jsonb_build_array(p_meta ->> 'source_type', p_meta ->> 'source_id'),
    'reason', v_reason,
    'engine', jsonb_build_array(p_meta ->> 'engine_version', p_meta ->> 'rule_pack_version_id', p_meta ->> 'inputs_hash'),
    'lines', (select jsonb_agg(jsonb_build_array(ledger_account_id, currency, amount_minor)
                               order by ledger_account_id, amount_minor) from pg_temp._ledger_lines)
  )::text, 'UTF8')), 'hex');

  insert into public.ledger_entry (organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, source_type, source_id,
                                   reason, engine_version, rule_pack_version_id, inputs_hash)
  values (p_organization_id, v_client, case when v_has_claim then v_account.portfolio_id end, v_account_id,
          p_entry_type, p_effective_date, v_n, p_idempotency_key, v_hash, p_meta ->> 'source_type',
          p_meta ->> 'source_id', v_reason, p_meta ->> 'engine_version',
          nullif(p_meta ->> 'rule_pack_version_id', '')::uuid, p_meta ->> 'inputs_hash')
  on conflict (organization_id, idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then
    select e.id, e.request_hash into v_id, v_existing_hash from public.ledger_entry e
    where e.organization_id = p_organization_id and e.idempotency_key = p_idempotency_key;
    if v_existing_hash <> v_hash then
      raise exception 'ledger: idempotency key % was used for a different request', p_idempotency_key
        using errcode = 'LG004';
    end if;
    return query select v_id, false;
    return;
  end if;

  insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency, effective_date)
  select v_id, line_no, ledger_account_id, amount_minor, currency, p_effective_date from pg_temp._ledger_lines;
  return query select v_id, true;
end;
$$;

create or replace function private.ledger_reverse(
  p_entry_id uuid,
  p_idempotency_key text,
  p_reason text,
  p_effective_date date default null
)
returns table (entry_id uuid, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_target public.ledger_entry;
  v_existing public.ledger_entry;
  v_date date;
  v_id uuid;
begin
  select * into v_target from public.ledger_entry where id = p_entry_id;
  if not found then
    raise exception 'ledger: entry % does not exist', p_entry_id using errcode = 'LG003';
  end if;
  v_date := coalesce(p_effective_date, v_target.effective_date);
  select * into v_existing from public.ledger_entry
  where organization_id = v_target.organization_id and idempotency_key = p_idempotency_key;
  if found then
    -- A replay must be the same request: same target, date and reason.
    if v_existing.reverses_entry_id = p_entry_id and v_existing.effective_date = v_date
       and v_existing.reason = btrim(p_reason) then
      return query select v_existing.id, false;
      return;
    end if;
    raise exception 'ledger: idempotency key % was used for a different request', p_idempotency_key
      using errcode = 'LG004';
  end if;
  if v_target.reverses_entry_id is not null then
    raise exception 'ledger: entry % is a reversal; post a new entry instead', p_entry_id using errcode = 'LG003';
  end if;
  if v_target.entry_type = 'cash_in' then
    raise exception 'ledger: entry % is a cash_in; correct a statement line with a payment-tagged cash_out', p_entry_id
      using errcode = 'LG003';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'ledger: a reversal needs a reason' using errcode = 'LG006';
  end if;
  if v_date < v_target.effective_date then
    raise exception 'ledger: a reversal cannot be dated before the entry it reverses' using errcode = 'LG003';
  end if;
  if v_date > private.paris_today() then
    raise exception 'ledger: effective date % is in the future', v_date using errcode = 'LG006';
  end if;
  -- A reversal can lower a receivable (reversing a debit): serialised with allocations (§5.2).
  perform pg_advisory_xact_lock(hashtext('payments:' || v_target.organization_id::text));
  begin
    insert into public.ledger_entry (organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                     effective_date, line_count, idempotency_key, request_hash, reverses_entry_id,
                                     boarding_batch_id, payment_id, source_type, source_id, reason)
    values (v_target.organization_id, v_target.client_organization_id, v_target.portfolio_id, v_target.account_id,
            'reversal', v_date, v_target.line_count, p_idempotency_key,
            encode(sha256(convert_to('reversal|' || p_entry_id || '|' || v_date, 'UTF8')), 'hex'),
            p_entry_id, v_target.boarding_batch_id, v_target.payment_id, 'ledger_entry', p_entry_id::text, btrim(p_reason))
    returning id into v_id;
  exception when unique_violation then
    -- A concurrent call won the race: a replay of the same request gets its reversal back.
    select * into v_existing from public.ledger_entry
    where organization_id = v_target.organization_id and idempotency_key = p_idempotency_key;
    if found and v_existing.reverses_entry_id = p_entry_id and v_existing.effective_date = v_date
       and v_existing.reason = btrim(p_reason) then
      return query select v_existing.id, false;
      return;
    elsif found then
      raise exception 'ledger: idempotency key % was used for a different request', p_idempotency_key
        using errcode = 'LG004';
    end if;
    raise exception 'ledger: entry % is already reversed', p_entry_id using errcode = 'LG003';
  end;
  insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency, effective_date)
  select v_id, line_no, ledger_account_id, -amount_minor, currency, v_date
  from public.ledger_posting where entry_id = p_entry_id;
  return query select v_id, true;
end;
$$;

-- Openings: unchanged except the ON CONFLICT target of the pooled owner-claim accounts.
create or replace function private.post_opening_balances(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
  v_bad text;
  v_posted jsonb;
  v_summary jsonb;
begin
  select * into v from public.boarding_batch where id = p_batch_id for update;
  if v.status is distinct from 'confirming' then
    raise exception 'ledger: batch % is %, expected confirming', p_batch_id, v.status using errcode = 'LG006';
  end if;
  if v.cut_off_date is null or v.cut_off_date > private.paris_today() then
    raise exception 'ledger: batch % needs a cut-off date that is not in the future', p_batch_id using errcode = 'LG006';
  end if;
  if exists (select 1 from public.ledger_entry where boarding_batch_id = p_batch_id) then
    raise exception 'ledger: batch % already has ledger entries', p_batch_id using errcode = 'LG006';
  end if;
  perform private.check_opening_sources(p_batch_id);
  set constraints public.ledger_entry_balanced deferred;

  drop table if exists pg_temp._open_src;
  create temp table _open_src on commit drop as
  select l.account_id, l.claim_item_id, l.component, l.currency, l.amount_minor, l.sort_key, c.sort_order,
         a.organization_id, a.client_organization_id, a.portfolio_id, o.owner_organization_id
  from private.opening_lines(p_batch_id) l
  join public.account a on a.id = l.account_id
  join public.ledger_component c on c.code = l.component
  left join public.claim_ownership_period o on o.account_id = a.id and o.valid_from <= v.cut_off_date
    and (o.valid_to is null or o.valid_to > v.cut_off_date)
  where l.amount_minor <> 0;
  select min(account_id::text) into v_bad from _open_src where owner_organization_id is null;
  if v_bad is not null then
    raise exception 'ledger: account % has no owner on the cut-off date', v_bad using errcode = 'LG006';
  end if;
  analyze _open_src;

  insert into public.ledger_account (organization_id, book, currency, client_organization_id, portfolio_id,
                                     account_id, claim_item_id, component)
  select distinct organization_id, 'debtor_receivable', currency, client_organization_id, portfolio_id,
         account_id, claim_item_id, component
  from _open_src
  on conflict (claim_item_id, component) do nothing;
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, owner_organization_id,
                                     portfolio_id, component)
  select distinct organization_id, 'owner_claim', currency, client_organization_id, owner_organization_id,
         portfolio_id, component
  from _open_src
  on conflict (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component,
               bank_account_id)
    where claim_item_id is null do nothing;

  -- Each line with its two ledger accounts, built in one pass (no rewrite of a large temp table).
  drop table if exists pg_temp._open;
  create temp table _open on commit drop as
  select s.*, r.id as la_receivable, w.id as la_owner
  from _open_src s
  join public.ledger_account r on r.claim_item_id = s.claim_item_id and r.component = s.component
  join public.ledger_account w on w.claim_item_id is null and w.book = 'owner_claim'
    and w.organization_id = s.organization_id and w.currency = s.currency
    and w.client_organization_id = s.client_organization_id and w.owner_organization_id = s.owner_organization_id
    and w.portfolio_id = s.portfolio_id and w.component = s.component;
  if (select count(*) from _open) <> (select count(*) from _open_src) then
    raise exception 'ledger: batch % has opening lines without their ledger accounts', p_batch_id using errcode = 'LG006';
  end if;
  drop table _open_src;
  analyze _open;

  -- Owner-claim lines: one per (account, component) with a non-zero total.
  drop table if exists pg_temp._open_owner;
  create temp table _open_owner on commit drop as
  select account_id, component, min(sort_order) as sort_order, min(currency) as currency,
         (array_agg(la_owner))[1] as la_owner, sum(amount_minor) as total
  from _open group by account_id, component having sum(amount_minor) <> 0;

  drop table if exists pg_temp._open_entry;
  create temp table _open_entry on commit drop as
  select x.account_id, gen_random_uuid() as entry_id, x.organization_id, x.client_organization_id, x.portfolio_id,
         x.n_receivable, x.n_receivable + coalesce(w.n_owner, 0) as line_count, x.hash_lines
  from (select account_id, organization_id, client_organization_id, portfolio_id, count(*) as n_receivable,
               jsonb_agg(jsonb_build_array(la_receivable, currency, amount_minor) order by la_receivable, amount_minor) as hash_lines
        from _open group by account_id, organization_id, client_organization_id, portfolio_id) x
  left join (select account_id, count(*) as n_owner from _open_owner group by account_id) w using (account_id);

  insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, boarding_batch_id,
                                   source_type, source_id, actor_id, actor_label)
  select e.entry_id, e.organization_id, e.client_organization_id, e.portfolio_id, e.account_id, 'opening',
         v.cut_off_date, e.line_count, 'opening:' || p_batch_id || ':' || e.account_id,
         encode(sha256(convert_to(jsonb_build_object('type', 'opening', 'effective_date', v.cut_off_date,
                                                     'account_id', e.account_id, 'lines', e.hash_lines)::text, 'UTF8')), 'hex'),
         p_batch_id, 'boarding_batch', p_batch_id::text, v.confirm_requested_by, 'worker:boarding'
  from _open_entry e;

  insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency, effective_date)
  select e.entry_id,
         row_number() over (partition by o.account_id order by o.sort_key, o.sort_order, o.claim_item_id),
         o.la_receivable, o.amount_minor, o.currency, v.cut_off_date
  from _open o join _open_entry e using (account_id)
  union all
  select e.entry_id, e.n_receivable + row_number() over (partition by w.account_id order by w.sort_order),
         w.la_owner, -w.total, w.currency, v.cut_off_date
  from _open_owner w join _open_entry e using (account_id);

  -- What was posted = the plan = the staged report, to the cent.
  v_posted := private.opening_totals(p_batch_id, true);
  perform private.assert_opening_matches(p_batch_id, v_posted);
  if private.opening_normal(v_posted) is distinct from private.opening_normal(v.opening_plan) then
    raise exception 'ledger: posted opening balances differ from the plan computed at commit' using errcode = 'LG005';
  end if;
  set constraints public.ledger_entry_balanced immediate;
  set constraints public.ledger_entry_balanced deferred;

  v_summary := jsonb_build_object(
    'effective_date', v.cut_off_date,
    'entries', (select count(*) from _open_entry),
    'postings', (select count(*) from _open) + (select count(*) from _open_owner),
    'totals', v_posted);
  update public.boarding_batch set opening_summary = v_summary where id = p_batch_id;
  return v_summary;
end;
$$;

------------------------------------------------------------------------------------------
-- Set-based posting of payment entries (cash_in, allocation, forward, cash_out, netting).
-- Callers are other SECURITY DEFINER functions (M2b-2 … M2b-6): they call
-- private.ledger_post_set_begin() (drops and recreates the two input tables, ADR-0012 temp-schema
-- rule), fill pg_temp._lps_entry / pg_temp._lps_line, then call private.ledger_post_set().
-- Scope comes from the account, the payment and the bank account, never from the caller.
------------------------------------------------------------------------------------------

create or replace function private.ledger_post_set_begin()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._lps_line;
  drop table if exists pg_temp._lps_entry;
  create temp table _lps_entry (
    entry_no integer primary key,
    organization_id uuid not null,
    entry_type text not null,
    effective_date date,
    idempotency_key text not null,
    account_id uuid,                  -- entries with claim lines (allocation, netting)
    client_organization_id uuid,      -- entries without an account that pay a client (forward)
    payment_id uuid,                  -- allocation, forward, cash_out
    source_type text,
    source_id text,
    reason text,
    engine_version text,
    inputs_hash text
  ) on commit drop;
  create temp table _lps_line (
    entry_no integer not null,
    line_no integer not null,
    book text not null,
    amount_minor bigint not null,
    currency char(3) not null,
    claim_item_id uuid,               -- debtor_receivable
    component text,                   -- debtor_receivable, owner_claim
    bank_account_id uuid,             -- client_money_cash
    primary key (entry_no, line_no)
  ) on commit drop;
end;
$$;

create or replace function private.ledger_post_set()
returns table (entry_no integer, entry_id uuid, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_bad text;
begin
  -- Entries with their derived scope, in our own working table.
  drop table if exists pg_temp._lps_e;
  create temp table _lps_e on commit drop as
  select e.entry_no, e.organization_id, e.entry_type, e.effective_date, e.idempotency_key, e.account_id,
         e.client_organization_id as given_client, coalesce(a.client_organization_id, e.client_organization_id) as client_organization_id,
         e.payment_id, e.source_type, e.source_id, nullif(btrim(e.reason), '') as reason, e.engine_version, e.inputs_hash,
         a.organization_id as account_organization_id, a.status as account_status, a.portfolio_id,
         a.currency as account_currency, own.servicing_start, o.owner_organization_id,
         t.allowed_books, t.requires_reason, p.organization_id as payment_organization_id, p.currency as payment_currency,
         gen_random_uuid() as id
  from pg_temp._lps_entry e
  left join public.account a on a.id = e.account_id
  left join (select o.account_id, min(o.valid_from) as servicing_start from public.claim_ownership_period o
             where o.account_id in (select x.account_id from pg_temp._lps_entry x where x.account_id is not null)
             group by o.account_id) own on own.account_id = e.account_id
  left join public.claim_ownership_period o on o.account_id = e.account_id and o.valid_from <= e.effective_date
    and (o.valid_to is null or o.valid_to > e.effective_date)
  left join public.ledger_entry_type t on t.code = e.entry_type
  left join public.payment p on p.id = e.payment_id;
  analyze pg_temp._lps_e;

  drop table if exists pg_temp._lps_l;
  create temp table _lps_l on commit drop as
  select l.entry_no, l.line_no, l.book, l.amount_minor, l.currency, l.claim_item_id, l.component, l.bank_account_id,
         e.organization_id, e.entry_type,
         case when l.book in ('debtor_receivable', 'owner_claim', 'client_payable') then e.client_organization_id end
           as client_organization_id,
         case when l.book = 'owner_claim' then e.owner_organization_id end as owner_organization_id,
         case when l.book in ('debtor_receivable', 'owner_claim') then e.portfolio_id end as portfolio_id,
         case when l.book = 'debtor_receivable' then e.account_id end as account_id
  from pg_temp._lps_line l join pg_temp._lps_e e on e.entry_no = l.entry_no;
  analyze pg_temp._lps_l;

  -- Request: types, dates, reasons, keys, lines (LG006).
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.entry_type not in ('cash_in', 'allocation', 'forward', 'cash_out', 'netting') or e.allowed_books is null;
  if v_bad is not null then
    raise exception 'ledger: entry % has a type that cannot be posted here', v_bad using errcode = 'LG006';
  end if;
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.effective_date is null or e.effective_date > private.paris_today()
     or (e.requires_reason and e.reason is null)
     or e.idempotency_key !~ '^[A-Za-z0-9:._#-]{8,200}$'
     or (e.entry_type in ('allocation', 'forward', 'cash_out')) <> (e.payment_id is not null)
     or (e.account_id is not null) <> (e.entry_type in ('allocation', 'netting'))
     or (e.given_client is not null and e.entry_type <> 'forward');
  if v_bad is not null then
    raise exception 'ledger: entry % needs a past date, its reason, a valid key, and the account or payment its type requires',
      v_bad using errcode = 'LG006';
  end if;
  select min(k) into v_bad from (select e.organization_id::text || ' ' || e.idempotency_key as k from pg_temp._lps_e e
                                 group by e.organization_id, e.idempotency_key having count(*) > 1) d;
  if v_bad is not null then
    raise exception 'ledger: idempotency key % appears twice in one request', v_bad using errcode = 'LG006';
  end if;
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  left join (select l.entry_no, count(*) as n, min(l.line_no) as lo, max(l.line_no) as hi
             from pg_temp._lps_l l group by l.entry_no) c on c.entry_no = e.entry_no
  where c.n is null or c.n < 2 or c.n > 100000 or c.lo <> 1 or c.hi <> c.n;
  if v_bad is not null then
    raise exception 'ledger: entry % needs 2 to 100000 lines numbered from 1', v_bad using errcode = 'LG006';
  end if;
  select min(l.entry_no || ':' || l.line_no) into v_bad from pg_temp._lps_l l
  where l.amount_minor = 0 or abs(l.amount_minor) > 1000000000000000 or l.currency !~ '^[A-Z]{3}$'
     or (l.claim_item_id is not null) <> (l.book = 'debtor_receivable')
     or (l.component is not null) <> (l.book in ('debtor_receivable', 'owner_claim'))
     or (l.bank_account_id is not null) <> (l.book = 'client_money_cash');
  if v_bad is not null then
    raise exception 'ledger: line % needs a non-zero amount, a currency, and only the item, component or bank account of its book',
      v_bad using errcode = 'LG006';
  end if;

  -- Books allowed for the type (LG002).
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l join pg_temp._lps_e e on e.entry_no = l.entry_no
  where not (l.book = any (e.allowed_books));
  if v_bad is not null then
    raise exception 'ledger: line % uses a book not allowed for its entry type', v_bad using errcode = 'LG002';
  end if;

  -- Claims: a confirmed account of this servicer, servicing started, an owner on the date.
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.account_id is not null and (e.account_organization_id is distinct from e.organization_id
                                      or (e.given_client is not null and e.given_client <> e.client_organization_id));
  if v_bad is not null then
    raise exception 'ledger: entry % names an account outside this organization', v_bad using errcode = 'LG002';
  end if;
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.account_id is not null and (e.account_status = 'staged' or e.servicing_start is null
                                      or e.effective_date < e.servicing_start or e.owner_organization_id is null);
  if v_bad is not null then
    raise exception 'ledger: entry % is on an account not confirmed yet, before its servicing started, or without an owner',
      v_bad using errcode = 'LG006';
  end if;
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l join pg_temp._lps_e e on e.entry_no = l.entry_no
  left join public.claim_item i on i.id = l.claim_item_id
  where l.book in ('debtor_receivable', 'owner_claim')
    and (l.currency <> e.account_currency
         or (l.book = 'debtor_receivable' and i.account_id is distinct from e.account_id));
  if v_bad is not null then
    raise exception 'ledger: claim line % must name an item of its entry''s account, in the account''s currency', v_bad
      using errcode = 'LG002';
  end if;

  -- Clients, bank accounts and payments belong to the servicer (LG002).
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where (e.client_organization_id is not null and not exists (
           select 1 from public.organization o
           where o.id = e.client_organization_id and o.servicer_organization_id = e.organization_id))
     or (exists (select 1 from pg_temp._lps_l l where l.entry_no = e.entry_no and l.book = 'client_payable')
         and e.client_organization_id is null)
     or (e.payment_id is not null and e.payment_organization_id is distinct from e.organization_id);
  if v_bad is not null then
    raise exception 'ledger: entry % pays no client of this servicer, or names a payment of another one', v_bad
      using errcode = 'LG002';
  end if;
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l join pg_temp._lps_e e on e.entry_no = l.entry_no
  where e.payment_id is not null and l.currency <> e.payment_currency;
  if v_bad is not null then
    raise exception 'ledger: line % is not in the currency of its payment', v_bad using errcode = 'LG002';
  end if;
  -- Debtor cash only on an active account dedicated to client funds; a concurrent closure waits.
  perform 1 from public.bank_account b
  where b.id in (select l.bank_account_id from pg_temp._lps_l l where l.bank_account_id is not null)
  order by b.id for share;
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l left join public.bank_account b on b.id = l.bank_account_id
  where l.book = 'client_money_cash'
    and (b.id is null or b.organization_id <> l.organization_id or b.currency <> l.currency
         or b.purpose <> 'client_funds' or b.status <> 'active');
  if v_bad is not null then
    raise exception 'ledger: line % is not on an active client_funds bank account of this servicer (R124-2)', v_bad
      using errcode = 'LG002';
  end if;

  -- Fail fast (the deferred check is the backstop): balanced, mirror, client-money closure (LG001).
  select min(k) into v_bad from (
    select l.entry_no || ' ' || l.currency as k from pg_temp._lps_l l
    group by l.entry_no, l.currency having sum(l.amount_minor) <> 0
    union all
    select l.entry_no || ' ' || l.component || ' ' || l.currency from pg_temp._lps_l l
    where l.book in ('debtor_receivable', 'owner_claim')
    group by l.entry_no, l.component, l.currency having sum(l.amount_minor) <> 0
    union all
    select l.entry_no || ' ' || l.currency from pg_temp._lps_l l
    where l.book in ('client_money_cash', 'unallocated_payment', 'client_payable')
    group by l.entry_no, l.currency having sum(l.amount_minor) <> 0) x;
  if v_bad is not null then
    raise exception 'ledger: entry % is not balanced, breaks the mirror, or leaves client money open', v_bad
      using errcode = 'LG001';
  end if;

  -- Whatever lowers a payment's remainder or a receivable waits for the servicer's allocation lock.
  perform pg_advisory_xact_lock(hashtext('payments:' || x.org))
  from (select distinct e.organization_id::text as org from pg_temp._lps_e e
        where e.entry_type in ('allocation', 'forward', 'cash_out', 'netting') order by 1) x;

  -- Get or create the ledger accounts.
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, portfolio_id,
                                     account_id, claim_item_id, component)
  select distinct l.organization_id, 'debtor_receivable', l.currency, l.client_organization_id, l.portfolio_id,
         l.account_id, l.claim_item_id, l.component
  from pg_temp._lps_l l where l.book = 'debtor_receivable'
  on conflict (claim_item_id, component) do nothing;
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, owner_organization_id,
                                     portfolio_id, component, bank_account_id)
  select distinct l.organization_id, l.book, l.currency, l.client_organization_id, l.owner_organization_id,
         l.portfolio_id, l.component, l.bank_account_id
  from pg_temp._lps_l l where l.book <> 'debtor_receivable'
  on conflict (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component,
               bank_account_id)
    where claim_item_id is null do nothing;

  -- Pooled ledger accounts: a few distinct dimensions, each found by the unique index prefix.
  drop table if exists pg_temp._lps_dim;
  create temp table _lps_dim on commit drop as
  select d.*, (select la.id from public.ledger_account la
               where la.organization_id = d.organization_id and la.book = d.book and la.currency = d.currency
                 and la.claim_item_id is null
                 and la.client_organization_id is not distinct from d.client_organization_id
                 and la.owner_organization_id is not distinct from d.owner_organization_id
                 and la.portfolio_id is not distinct from d.portfolio_id
                 and la.component is not distinct from d.component
                 and la.bank_account_id is not distinct from d.bank_account_id) as ledger_account_id
  from (select distinct l.organization_id, l.book, l.currency, l.client_organization_id, l.owner_organization_id,
               l.portfolio_id, l.component, l.bank_account_id
        from pg_temp._lps_l l where l.book <> 'debtor_receivable') d;

  drop table if exists pg_temp._lps_x;
  create temp table _lps_x on commit drop as
  select l.entry_no, l.line_no, l.amount_minor, l.currency, coalesce(r.id, d.ledger_account_id) as ledger_account_id
  from pg_temp._lps_l l
  left join public.ledger_account r on l.book = 'debtor_receivable' and r.claim_item_id = l.claim_item_id
    and r.component = l.component
  left join pg_temp._lps_dim d on l.book <> 'debtor_receivable' and d.organization_id = l.organization_id
    and d.book = l.book and d.currency = l.currency
    and d.client_organization_id is not distinct from l.client_organization_id
    and d.owner_organization_id is not distinct from l.owner_organization_id
    and d.portfolio_id is not distinct from l.portfolio_id
    and d.component is not distinct from l.component
    and d.bank_account_id is not distinct from l.bank_account_id;
  if exists (select 1 from pg_temp._lps_x where ledger_account_id is null)
     or (select count(*) from pg_temp._lps_x) <> (select count(*) from pg_temp._lps_l) then
    raise exception 'ledger: lines without their ledger accounts' using errcode = 'LG006';
  end if;
  analyze pg_temp._lps_x;

  -- Canonical request hash per entry: line order does not matter.
  drop table if exists pg_temp._lps_h;
  create temp table _lps_h on commit drop as
  select e.entry_no, c.line_count,
         encode(sha256(convert_to(jsonb_build_object(
           'type', e.entry_type,
           'effective_date', e.effective_date,
           'account_id', e.account_id,
           'client_organization_id', e.client_organization_id,
           'payment_id', e.payment_id,
           'source', jsonb_build_array(e.source_type, e.source_id),
           'reason', e.reason,
           'engine', jsonb_build_array(e.engine_version, e.inputs_hash),
           'lines', c.lines)::text, 'UTF8')), 'hex') as request_hash
  from pg_temp._lps_e e
  join (select x.entry_no, count(*)::integer as line_count,
               jsonb_agg(jsonb_build_array(x.ledger_account_id, x.currency, x.amount_minor)
                         order by x.ledger_account_id, x.amount_minor) as lines
        from pg_temp._lps_x x group by x.entry_no) c on c.entry_no = e.entry_no;

  drop table if exists pg_temp._lps_new;
  create temp table _lps_new (id uuid primary key) on commit drop;
  with ins as (
    insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                     effective_date, line_count, idempotency_key, request_hash, payment_id, source_type,
                                     source_id, reason, engine_version, inputs_hash)
    select e.id, e.organization_id, e.client_organization_id, e.portfolio_id, e.account_id, e.entry_type,
           e.effective_date, h.line_count, e.idempotency_key, h.request_hash, e.payment_id, e.source_type,
           e.source_id, e.reason, e.engine_version, e.inputs_hash
    from pg_temp._lps_e e join pg_temp._lps_h h on h.entry_no = e.entry_no
    order by e.entry_no
    on conflict (organization_id, idempotency_key) do nothing
    returning id
  )
  insert into pg_temp._lps_new select ins.id from ins;

  -- A key already used: the same request returns its entry, another request is refused.
  select min(e.idempotency_key) into v_bad
  from pg_temp._lps_e e
  join pg_temp._lps_h h on h.entry_no = e.entry_no
  join public.ledger_entry x on x.organization_id = e.organization_id and x.idempotency_key = e.idempotency_key
  where not exists (select 1 from pg_temp._lps_new n where n.id = e.id) and x.request_hash <> h.request_hash;
  if v_bad is not null then
    raise exception 'ledger: idempotency key % was used for a different request', v_bad using errcode = 'LG004';
  end if;

  insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency, effective_date)
  select e.id, x.line_no, x.ledger_account_id, x.amount_minor, x.currency, e.effective_date
  from pg_temp._lps_e e
  join pg_temp._lps_new n on n.id = e.id
  join pg_temp._lps_x x on x.entry_no = e.entry_no;

  -- Every pending check now (balance, mirror, closure, shapes, payments, receivables): a refused
  -- request fails here, inside the caller's call, with its SQLSTATE.
  set constraints public.ledger_entry_balanced immediate;
  set constraints public.ledger_entry_balanced deferred;

  return query
  select e.entry_no, coalesce(n.id, x.id), n.id is not null
  from pg_temp._lps_e e
  left join pg_temp._lps_new n on n.id = e.id
  left join public.ledger_entry x on n.id is null and x.organization_id = e.organization_id
    and x.idempotency_key = e.idempotency_key
  order by e.entry_no;
end;
$$;

------------------------------------------------------------------------------------------
-- Confirmation issues the references (redefined: one line added)
------------------------------------------------------------------------------------------

create or replace function private.complete_batch_confirmation(p_batch_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
begin
  select * into v from public.boarding_batch where id = p_batch_id for update;
  if not found or v.status <> 'confirming' then
    return 'skipped';
  end if;
  if not private.has_active_mandate(v.portfolio_id, private.paris_today()) then
    update public.boarding_batch
    set failed_job = jsonb_build_object('type', 'confirm', 'error', 'mandate_inactive', 'at', now())
    where id = p_batch_id and coalesce(failed_job ->> 'type', '') not in ('documents', 'purge_documents');
    perform private.transition_batch(p_batch_id, 'committed', 'mandat inactif (CPCE R124-3)', 'worker:boarding');
    return 'mandate_inactive';
  end if;
  perform private.post_opening_balances(p_batch_id);
  update public.account set status = 'awaiting_first_letter'
  where boarding_batch_id = p_batch_id and status = 'staged';
  perform private.issue_payment_references(p_batch_id);  -- M2-06: one RF reference per workable account
  perform private.transition_batch(p_batch_id, 'confirmed', 'confirmed', 'worker:boarding');
  return 'confirmed';
end;
$$;

------------------------------------------------------------------------------------------
-- Commands (French copy is in the web app; errors here are stable English codes)
------------------------------------------------------------------------------------------

create or replace function public.register_bank_account(
  p_idempotency_key text,
  p_organization_id uuid,
  p_label text,
  p_iban text,
  p_currency text,
  p_feed text,
  p_bic text default null,
  p_opened_on date default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_iban text := private.rf_normalise(coalesce(p_iban, ''));
  v_bic text := nullif(private.rf_normalise(coalesce(p_bic, '')), '');
  v_label text := btrim(coalesce(p_label, ''));
  v_opened date := coalesce(p_opened_on, private.paris_today());
  v_request jsonb;
  v_result jsonb;
  v_id uuid;
begin
  if not private.has_role(p_organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('organization_id', p_organization_id, 'label', v_label, 'iban', v_iban,
                                  'currency', p_currency, 'feed', p_feed, 'bic', v_bic, 'opened_on', p_opened_on);
  v_result := private.command_replay('register_bank_account', p_idempotency_key, v_request);
  if v_result is not null then
    return (v_result ->> 'bank_account_id')::uuid;
  end if;
  if v_label = '' or length(v_label) > 100 then
    raise exception 'a label is required (100 characters at most)' using errcode = 'check_violation';
  end if;
  if not private.iban_valid(v_iban) then
    raise exception 'invalid IBAN' using errcode = 'check_violation';
  end if;
  if v_bic is not null and v_bic !~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$' then
    raise exception 'invalid BIC' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.currency where code = p_currency) then
    raise exception 'unsupported currency' using errcode = 'check_violation';
  end if;
  if p_feed is null or p_feed not in ('camt053', 'csv') then
    raise exception 'invalid statement feed' using errcode = 'check_violation';
  end if;
  if v_opened > private.paris_today() then
    raise exception 'the opening date cannot be in the future' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_account
             where organization_id = p_organization_id and iban = v_iban and currency = p_currency) then
    raise exception 'this IBAN is already registered' using errcode = 'unique_violation';
  end if;
  insert into public.bank_account (organization_id, purpose, iban, bic, currency, label, feed, opened_on, created_by)
  values (p_organization_id, 'client_funds', v_iban, v_bic, p_currency, v_label, p_feed, v_opened, auth.uid())
  returning id into v_id;
  perform private.command_record('register_bank_account', p_idempotency_key, v_request,
                                 jsonb_build_object('bank_account_id', v_id));
  return v_id;
end;
$$;

-- Closing needs a zero cash balance: client money never stays on a closed account.
create or replace function public.close_bank_account(p_idempotency_key text, p_bank_account_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.bank_account;
  v_request jsonb := jsonb_build_object('bank_account_id', p_bank_account_id, 'reason', btrim(coalesce(p_reason, '')));
begin
  select * into v from public.bank_account where id = p_bank_account_id for update;
  if not found or not private.has_role(v.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if private.command_replay('close_bank_account', p_idempotency_key, v_request) is not null then
    return;
  end if;
  if v.status = 'closed' then
    raise exception 'the bank account is already closed' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if (select coalesce(sum(p.amount_minor), 0) from public.ledger_account la
      join public.ledger_posting p on p.ledger_account_id = la.id
      where la.bank_account_id = v.id and la.book = 'client_money_cash') <> 0 then
    raise exception 'the bank account still holds client money' using errcode = 'check_violation';
  end if;
  update public.bank_account
  set status = 'closed', closed_on = private.paris_today(), closed_reason = btrim(p_reason)
  where id = v.id;
  perform private.command_record('close_bank_account', p_idempotency_key, v_request, jsonb_build_object('closed', true));
end;
$$;

-- Retire a reference (for instance printed on a wrong letter) and issue a new one; the retired one
-- keeps resolving to its account.
create or replace function public.retire_payment_reference(p_idempotency_key text, p_reference_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.payment_reference;
  v_request jsonb := jsonb_build_object('reference_id', p_reference_id, 'reason', btrim(coalesce(p_reason, '')));
  v_result jsonb;
  v_id uuid;
  v_round integer := 0;
begin
  select * into r from public.payment_reference where id = p_reference_id for update;
  if not found or not private.has_role(r.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('retire_payment_reference', p_idempotency_key, v_request);
  if v_result is not null then
    return (v_result ->> 'payment_reference_id')::uuid;
  end if;
  if r.status <> 'active' then
    raise exception 'the reference is already retired' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  update public.payment_reference set status = 'retired', retired_at = now(), retired_reason = btrim(p_reason)
  where id = r.id;
  loop
    insert into public.payment_reference (organization_id, client_organization_id, portfolio_id, account_id, rf)
    values (r.organization_id, r.client_organization_id, r.portfolio_id, r.account_id,
            private.rf_make(private.rf_random_body()))
    on conflict do nothing
    returning id into v_id;
    exit when v_id is not null;
    v_round := v_round + 1;
    if v_round >= 5 then
      raise exception 'payment reference: no free reference after 5 draws';
    end if;
  end loop;
  perform private.command_record('retire_payment_reference', p_idempotency_key, v_request,
                                 jsonb_build_object('payment_reference_id', v_id));
  return v_id;
end;
$$;

------------------------------------------------------------------------------------------
-- Read access (redefined for client-money books; closes M2a risk #6)
------------------------------------------------------------------------------------------

drop policy ledger_account_read on public.ledger_account;
create policy ledger_account_read on public.ledger_account for select to authenticated using (
  portfolio_id = any ((select private.readable_portfolio_ids())::uuid[])
  -- client money (cash, unallocated, payable): admins and ops managers; clients their own payable
  or (portfolio_id is null and book in ('client_money_cash', 'unallocated_payment', 'client_payable')
      and organization_id = any ((select private.money_staff_org_ids())::uuid[]))
  or (portfolio_id is null and book = 'client_payable'
      and client_organization_id = any ((select private.client_org_ids())::uuid[]))
  -- other books without a portfolio (commission revenue): unchanged
  or (portfolio_id is null and book not in ('client_money_cash', 'unallocated_payment', 'client_payable')
      and (organization_id = any ((select private.staff_org_ids())::uuid[])
           or (client_organization_id = any ((select private.client_org_ids())::uuid[])
               and book in (select b.code from public.ledger_book b where b.client_visible)))));

-- Entries without a portfolio move client money (cash_in, forward, cash_out and their reversals).
drop policy ledger_entry_read on public.ledger_entry;
create policy ledger_entry_read on public.ledger_entry for select to authenticated using (
  portfolio_id = any ((select private.readable_portfolio_ids())::uuid[])
  or (portfolio_id is null and organization_id = any ((select private.money_staff_org_ids())::uuid[]))
  or (portfolio_id is null and client_organization_id = any ((select private.client_org_ids())::uuid[])));

create or replace function public.ledger_balance(p_ledger_account_id uuid, p_as_of date default null,
                                                 p_known_at timestamptz default null)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.ledger_account la
    where la.id = p_ledger_account_id
      and ((la.portfolio_id is not null and private.can_read_portfolio(la.portfolio_id))
           or (la.portfolio_id is null and la.book in ('client_money_cash', 'unallocated_payment', 'client_payable')
               and la.organization_id = any (private.money_staff_org_ids()))
           or (la.portfolio_id is null and la.book = 'client_payable'
               and la.client_organization_id = any (private.client_org_ids()))
           or (la.portfolio_id is null and la.book not in ('client_money_cash', 'unallocated_payment', 'client_payable')
               and (la.organization_id = any (private.staff_org_ids())
                    or (la.client_organization_id = any (private.client_org_ids())
                        and exists (select 1 from public.ledger_book b where b.code = la.book and b.client_visible)))))
  ) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return private.ledger_balance(p_ledger_account_id, coalesce(p_as_of, private.paris_today()), p_known_at);
end;
$$;

create or replace function public.client_money_balances(p_client_organization_id uuid, p_as_of date default null,
                                                        p_known_at timestamptz default null)
returns table (currency char(3), unallocated_minor bigint, payable_minor bigint, held_minor bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.organization o
    where o.id = p_client_organization_id and o.servicer_organization_id is not null
      and (o.servicer_organization_id = any (private.money_staff_org_ids()) or o.id = any (private.client_org_ids()))
  ) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query select * from private.client_money_balances(p_client_organization_id,
                                                           coalesce(p_as_of, private.paris_today()), p_known_at);
end;
$$;

alter table public.bank_account enable row level security;
alter table public.payment enable row level security;
alter table public.payment_reference enable row level security;
revoke all on public.bank_account, public.payment, public.payment_reference from public, anon, authenticated;
grant select on public.bank_account, public.payment, public.payment_reference to authenticated;

-- Third-party payer data and the bank: admins and ops managers.
create policy bank_account_read on public.bank_account for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
-- Payments: admins and ops managers; collectors those of their portfolios (never unmatched ones).
create policy payment_read on public.payment for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or (portfolio_id = any ((select private.readable_portfolio_ids())::uuid[])
      and organization_id = any ((select private.staff_org_ids())::uuid[])));
-- References are printed on letters: whoever reads the portfolio (clients included).
create policy payment_reference_read on public.payment_reference for select to authenticated
  using (portfolio_id = any ((select private.readable_portfolio_ids())::uuid[]));

------------------------------------------------------------------------------------------
-- Privileges
------------------------------------------------------------------------------------------

revoke execute on function private.mod97(text), private.rf_valid(text), private.rf_normalise(text), private.rf_make(text),
  private.rf_random_body(), private.iban_valid(text), private.money_staff_org_ids(),
  private.command_replay(text, text, jsonb), private.command_record(text, text, jsonb, jsonb),
  private.issue_payment_references(uuid), private.ledger_post_set_begin(), private.ledger_post_set()
  from public, anon, authenticated, service_role;
grant execute on function private.money_staff_org_ids() to authenticated;
-- The worker (service_role) validates references and IBANs read from statements (M2b-2, M2b-3).
grant execute on function private.mod97(text), private.rf_valid(text), private.rf_normalise(text),
  private.iban_valid(text) to service_role;
revoke execute on function public.register_bank_account(text, uuid, text, text, text, text, text, date),
  public.close_bank_account(text, uuid, text), public.retire_payment_reference(text, uuid, text) from public, anon;
grant execute on function public.register_bank_account(text, uuid, text, text, text, text, text, date),
  public.close_bank_account(text, uuid, text), public.retire_payment_reference(text, uuid, text) to authenticated;

------------------------------------------------------------------------------------------
-- Backfill: accounts confirmed before M2b get their reference now (set-based).
------------------------------------------------------------------------------------------

select private.issue_payment_references(null);
