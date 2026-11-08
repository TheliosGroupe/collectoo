-- M2a ledger core (M2-01 … M2-04): double-entry, append-only, integer minor units.
-- Design: docs/design/m2a-ledger.md; decisions: docs/adr/0012-ledger-implementation.md.
-- Structural invariants are ENABLE ALWAYS triggers: they hold for the table owner (the worker's
-- login role) and under session_replication_role = replica. Writes only through the SECURITY
-- DEFINER functions private.ledger_post / private.ledger_reverse (service_role only).

------------------------------------------------------------------------------------------
-- Reference data
------------------------------------------------------------------------------------------

create table public.currency (
  code char(3) primary key check (code ~ '^[A-Z]{3}$'),
  minor_exponent smallint not null check (minor_exponent between 0 and 4),
  label_fr text not null
);
insert into public.currency values
  ('EUR', 2, 'Euro'), ('USD', 2, 'Dollar des États-Unis'), ('GBP', 2, 'Livre sterling'), ('CHF', 2, 'Franc suisse');
comment on table public.currency is 'Currencies accepted for claims (boarding converts amounts with x100: exponent 2 only).';

create table public.ledger_book (
  code text primary key,
  account_number text not null unique,
  label_fr text not null,
  dimension text not null check (dimension in ('claim', 'owner', 'client', 'pooled')),
  money_of text not null check (money_of in ('owner', 'client', 'servicer')),
  normal_side smallint not null check (normal_side in (1, -1)),
  client_visible boolean not null
);
insert into public.ledger_book values
  ('debtor_receivable',   '1100', 'Créance sur le débiteur',  'claim',  'owner',     1, true),
  ('owner_claim',         '3100', 'Créance du titulaire',     'owner',  'owner',    -1, true),
  ('unallocated_payment', '4710', 'Encaissements à imputer',  'client', 'client',   -1, true),
  ('client_payable',      '4670', 'Sommes dues au mandant',   'client', 'client',   -1, true),
  ('servicer_revenue',    '7060', 'Commissions',              'client', 'servicer', -1, true);
comment on table public.ledger_book is
  'Chart of accounts (ARCHITECTURE §8). Cash books (5120/5121/5122, 6270) arrive with M2b payments.';

create table public.ledger_component (
  code text primary key,
  family text not null check (family in ('principal', 'interest', 'indemnity', 'charge', 'cost', 'unclassified')),
  eba_field text,
  sort_order smallint not null unique,
  label_fr text not null,
  reference text not null
);
insert into public.ledger_component values
  ('principal',        'principal',    '3.09', 10, 'Principal',                              'claim_item amount; EU template 3.09'),
  ('accrued_interest', 'interest',     '3.10', 20, 'Intérêts échus déclarés par le cédant',  'EU template 3.10'),
  ('other_balances',   'unclassified', '3.11', 30, 'Autres sommes déclarées par le cédant',  'EU template 3.11'),
  ('balancing_line',   'unclassified', '3.12', 90, 'Écart au solde légal déclaré',           'EU template 3.12; founder decision 2026-11-07 #6');
comment on table public.ledger_component is
  'Balance components. Late interest, indemnities and fees arrive with M3 and their guards (CPCE-09, INT-05).';

create table public.ledger_entry_type (
  code text primary key,
  label_fr text not null,
  allowed_books text[],  -- null: a reversal, same books as the reversed entry
  requires_reason boolean not null
);
insert into public.ledger_entry_type values
  ('opening',    'Solde d''ouverture', array['debtor_receivable', 'owner_claim'], false),
  ('adjustment', 'Correction',         array['debtor_receivable', 'owner_claim', 'unallocated_payment', 'client_payable'], true),
  ('reversal',   'Contre-passation',   null, true);
comment on table public.ledger_entry_type is
  'Entry types and the books each may touch (servicer_revenue only through M2c commission entries, CPCE-02).';

-- Keys the ledger needs on existing tables (they freeze a claim account''s tenant and currency).
alter table public.account add constraint account_ledger_key
  unique (id, organization_id, client_organization_id, portfolio_id, currency);
alter table public.claim_item add constraint claim_item_account_key unique (id, account_id);

------------------------------------------------------------------------------------------
-- Ledger tables
------------------------------------------------------------------------------------------

create table public.ledger_account (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,                 -- servicer tenant
  book text not null,
  currency char(3) not null,
  client_organization_id uuid,
  owner_organization_id uuid,                    -- owner_claim only
  portfolio_id uuid,
  account_id uuid,
  claim_item_id uuid,
  component text,
  created_at timestamptz not null default now(),
  -- A claim ledger account keeps its account''s tenant and currency forever, and an account or
  -- item with ledger history can never be deleted (rollback safety).
  constraint ledger_account_claim_fk foreign key (account_id, organization_id, client_organization_id, portfolio_id, currency)
    references public.account (id, organization_id, client_organization_id, portfolio_id, currency),
  constraint ledger_account_item_fk foreign key (claim_item_id, account_id) references public.claim_item (id, account_id),
  constraint ledger_account_shape check (case book
    when 'debtor_receivable' then account_id is not null and claim_item_id is not null and component is not null
      and client_organization_id is not null and portfolio_id is not null and owner_organization_id is null
    when 'owner_claim' then account_id is null and claim_item_id is null and component is not null
      and client_organization_id is not null and owner_organization_id is not null and portfolio_id is not null
    when 'client_payable' then client_organization_id is not null and portfolio_id is null and account_id is null
      and claim_item_id is null and component is null and owner_organization_id is null
    when 'unallocated_payment' then portfolio_id is null and account_id is null and claim_item_id is null
      and component is null and owner_organization_id is null
    when 'servicer_revenue' then client_organization_id is not null and portfolio_id is null and account_id is null
      and claim_item_id is null and component is null and owner_organization_id is null
    else false end)
);
create unique index ledger_account_receivable_uq on public.ledger_account (claim_item_id, component);
create unique index ledger_account_pooled_uq on public.ledger_account
  (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component)
  nulls not distinct where claim_item_id is null;
create index ledger_account_account_idx on public.ledger_account (account_id);
create index ledger_account_client_idx on public.ledger_account (client_organization_id, book) where portfolio_id is null;
create index ledger_account_portfolio_idx on public.ledger_account (portfolio_id);
comment on table public.ledger_account is
  'Ledger accounts: debtor receivable per (claim item, component); owner claim pooled per owner x portfolio x component.';

create table public.ledger_entry (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid references public.organization (id),
  portfolio_id uuid references public.portfolio (id),
  account_id uuid references public.account (id),
  entry_type text not null references public.ledger_entry_type (code),
  effective_date date not null,                 -- business date (Europe/Paris)
  posted_at timestamptz not null default now(),
  line_count integer not null check (line_count between 2 and 100000),
  idempotency_key text not null check (idempotency_key ~ '^[A-Za-z0-9:._#-]{8,200}$'),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  reverses_entry_id uuid references public.ledger_entry (id),
  boarding_batch_id uuid references public.boarding_batch (id),
  source_type text,
  source_id text,
  reason text check (reason is null or length(btrim(reason)) between 1 and 2000),
  engine_version text,
  rule_pack_version_id uuid,
  inputs_hash text check (inputs_hash ~ '^[0-9a-f]{64}$'),
  actor_id uuid default auth.uid(),
  actor_label text default nullif(current_setting('app.actor', true), ''),
  constraint ledger_entry_idempotency_uq unique (organization_id, idempotency_key),
  constraint ledger_entry_reversal_shape check ((entry_type = 'reversal') = (reverses_entry_id is not null)),
  constraint ledger_entry_reason check (entry_type not in ('adjustment', 'reversal') or reason is not null),
  constraint ledger_entry_opening_shape check (entry_type <> 'opening' or (account_id is not null and boarding_batch_id is not null)),
  constraint ledger_entry_scope check ((account_id is null or portfolio_id is not null)
                                       and (portfolio_id is null or client_organization_id is not null)),
  constraint ledger_entry_engine check ((engine_version is null) = (inputs_hash is null))
);
create unique index ledger_entry_reversed_once_uq on public.ledger_entry (reverses_entry_id) where reverses_entry_id is not null;
create unique index ledger_entry_one_opening_uq on public.ledger_entry (account_id) where entry_type = 'opening';
create index ledger_entry_account_idx on public.ledger_entry (account_id, effective_date);
create index ledger_entry_batch_idx on public.ledger_entry (boarding_batch_id) where boarding_batch_id is not null;
create index ledger_entry_client_idx on public.ledger_entry (client_organization_id, effective_date);
create index ledger_entry_portfolio_idx on public.ledger_entry (portfolio_id);
comment on table public.ledger_entry is 'Journal entries (header). Immutable; corrections by reversal.';

-- No foreign keys on postings: one set-based ALWAYS guard checks the references (parents are
-- append-only, so an FK''s delete protection would add nothing; it would cost seconds at 50k).
create table public.ledger_posting (
  entry_id uuid not null,
  line_no integer not null check (line_no between 1 and 100000),
  ledger_account_id uuid not null,
  amount_minor bigint not null check (amount_minor <> 0
    and amount_minor between -1000000000000000 and 1000000000000000),  -- + debit / - credit
  currency char(3) not null,
  effective_date date not null,                 -- = entry.effective_date (guard), for index-only as_of scans
  primary key (entry_id, line_no)
);
create index ledger_posting_balance_idx on public.ledger_posting (ledger_account_id, effective_date) include (amount_minor);
comment on table public.ledger_posting is 'Journal lines: signed integer minor units (+ debit, - credit). Immutable.';

------------------------------------------------------------------------------------------
-- Append-only (statement level: one firing per statement, also for TRUNCATE and ON CONFLICT DO UPDATE)
------------------------------------------------------------------------------------------

create or replace function private.ledger_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'ledger: % on % refused (append-only; correct with a reversal)', tg_op, tg_table_name
    using errcode = 'LG000';
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['ledger_account', 'ledger_entry', 'ledger_posting'] loop
    execute format('create trigger %I before update or delete or truncate on public.%I
                    for each statement execute function private.ledger_append_only()', t || '_append_only', t);
    execute format('alter table public.%I enable always trigger %I', t, t || '_append_only');
  end loop;
  -- Reference data: labels may change by migration, keys never.
  foreach t in array array['currency', 'ledger_book', 'ledger_component', 'ledger_entry_type'] loop
    execute format('create trigger %I before delete or truncate or update of code on public.%I
                    for each statement execute function private.ledger_append_only()', t || '_keys_frozen', t);
    execute format('alter table public.%I enable always trigger %I', t, t || '_keys_frozen');
    execute format('create trigger %I after insert or update or delete on public.%I
                    for each row execute function private.log_change(''code'')', t || '_change_log', t);
  end loop;
end $$;

------------------------------------------------------------------------------------------
-- Set-based guards (AFTER INSERT ... FOR EACH STATEMENT over the transition table)
------------------------------------------------------------------------------------------

create or replace function private.ledger_account_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select coalesce(n.id::text, '?') into v_bad from new_rows n
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
  limit 1;
  if found then
    raise exception 'ledger: ledger account % is not coherent (book, currency, component, tenant or item)', v_bad
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
  select n.id::text into v_bad from new_rows n
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
  limit 1;
  if found then
    raise exception 'ledger: entry % is outside its tenant (organization, client, portfolio, account)', v_bad
      using errcode = 'LG002';
  end if;
  select n.id::text into v_bad from new_rows n
  left join public.ledger_entry t on t.id = n.reverses_entry_id
  where n.reverses_entry_id is not null
    and (t.id is null or t.reverses_entry_id is not null
         or t.organization_id <> n.organization_id
         or t.client_organization_id is distinct from n.client_organization_id
         or t.portfolio_id is distinct from n.portfolio_id
         or t.account_id is distinct from n.account_id
         or t.line_count <> n.line_count
         or n.effective_date < t.effective_date)
  limit 1;
  if found then
    raise exception 'ledger: reversal % does not match the entry it reverses', v_bad using errcode = 'LG003';
  end if;
  return null;
end;
$$;

create or replace function private.ledger_posting_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select n.entry_id || ':' || n.line_no into v_bad
  from new_rows n
  left join public.ledger_entry e on e.id = n.entry_id
  left join public.ledger_account la on la.id = n.ledger_account_id
  left join public.ledger_entry_type t on t.code = e.entry_type
  where e.id is null or la.id is null
     or n.line_no > e.line_count
     or n.currency <> la.currency
     or n.effective_date <> e.effective_date
     or la.organization_id <> e.organization_id
     or (la.client_organization_id is not null and la.client_organization_id is distinct from e.client_organization_id)
     or (la.portfolio_id is not null and la.portfolio_id is distinct from e.portfolio_id)
     or (la.account_id is not null and la.account_id is distinct from e.account_id)
     or (t.allowed_books is not null and not (la.book = any (t.allowed_books)))
  limit 1;
  if found then
    raise exception 'ledger: posting % does not fit its entry (closed entry, account, currency, date, tenant or book)', v_bad
      using errcode = 'LG002';
  end if;
  return null;
end;
$$;

create trigger ledger_account_guard after insert on public.ledger_account
  referencing new table as new_rows for each statement execute function private.ledger_account_guard();
create trigger ledger_entry_guard after insert on public.ledger_entry
  referencing new table as new_rows for each statement execute function private.ledger_entry_guard();
create trigger ledger_posting_guard after insert on public.ledger_posting
  referencing new table as new_rows for each statement execute function private.ledger_posting_guard();
alter table public.ledger_account enable always trigger ledger_account_guard;
alter table public.ledger_entry enable always trigger ledger_entry_guard;
alter table public.ledger_posting enable always trigger ledger_posting_guard;

------------------------------------------------------------------------------------------
-- Balance check: one deferred event per entry, at commit (or SET CONSTRAINTS ... IMMEDIATE)
------------------------------------------------------------------------------------------

create or replace function private.ledger_entry_verify()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_lines bigint;
  v_cur text;
  v_bad text;
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
  select la.component || ' ' || p.currency into v_bad
  from public.ledger_posting p join public.ledger_account la on la.id = p.ledger_account_id
  where p.entry_id = new.id and la.book in ('debtor_receivable', 'owner_claim')
  group by la.component, p.currency having sum(p.amount_minor) <> 0
  limit 1;
  if found then
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
  return null;
end;
$$;

create constraint trigger ledger_entry_balanced after insert on public.ledger_entry
  deferrable initially deferred for each row execute function private.ledger_entry_verify();
alter table public.ledger_entry enable always trigger ledger_entry_balanced;

------------------------------------------------------------------------------------------
-- Write path (service_role only)
------------------------------------------------------------------------------------------

create or replace function private.paris_today()
returns date
language sql
stable
set search_path = ''
as $$ select (now() at time zone 'Europe/Paris')::date $$;

-- Post an entry. Lines: [{book, amount_minor, currency, claim_item_id?, component?, client_organization_id?}].
-- The scope (client, portfolio, owner) is derived from the account and the ownership history,
-- never trusted from the caller. Same idempotency key + same request = same entry.
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
  if not found or p_entry_type in ('opening', 'reversal') then
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

  -- Lines, parsed once.
  create temp table if not exists _ledger_lines (
    line_no integer, book text, amount_minor bigint, currency char(3), claim_item_id uuid,
    component text, client_organization_id uuid, owner_organization_id uuid, portfolio_id uuid,
    ledger_account_id uuid) on commit drop;
  truncate _ledger_lines;
  insert into _ledger_lines (line_no, book, amount_minor, currency, claim_item_id, component, client_organization_id)
  select ord::integer, l ->> 'book', (l ->> 'amount_minor')::bigint, l ->> 'currency',
         nullif(l ->> 'claim_item_id', '')::uuid, nullif(l ->> 'component', ''),
         nullif(l ->> 'client_organization_id', '')::uuid
  from jsonb_array_elements(p_lines) with ordinality as t (l, ord);

  if exists (select 1 from _ledger_lines l where not exists (select 1 from public.ledger_book b where b.code = l.book)
                                                 or not (l.book = any (v_type.allowed_books))) then
    raise exception 'ledger: a line uses a book not allowed for a % entry', p_entry_type using errcode = 'LG002';
  end if;

  v_has_claim := exists (select 1 from _ledger_lines where book in ('debtor_receivable', 'owner_claim'));
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
      select 1 from _ledger_lines l
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
    select 1 from _ledger_lines l
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
        union all select client_organization_id from _ledger_lines where client_organization_id is not null) c) > 1 then
    raise exception 'ledger: an entry concerns one client at most' using errcode = 'LG002';
  end if;
  v_client := coalesce(v_client, (select min(client_organization_id::text)::uuid from _ledger_lines));

  -- Fail fast (the deferred check is the backstop).
  select currency into v_bad from _ledger_lines group by currency having sum(amount_minor) <> 0 limit 1;
  if found then
    raise exception 'ledger: entry is not balanced in %', v_bad using errcode = 'LG001';
  end if;
  select component || ' ' || currency into v_bad from _ledger_lines
  where book in ('debtor_receivable', 'owner_claim') group by component, currency having sum(amount_minor) <> 0 limit 1;
  if found then
    raise exception 'ledger: entry breaks the receivable/owner-claim mirror (%)', v_bad using errcode = 'LG001';
  end if;

  -- Get or create the ledger accounts.
  update _ledger_lines set client_organization_id = v_client where book in ('debtor_receivable', 'owner_claim');
  update _ledger_lines set portfolio_id = v_account.portfolio_id where book in ('debtor_receivable', 'owner_claim');
  update _ledger_lines set owner_organization_id = v_owner where book = 'owner_claim';
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, portfolio_id,
                                     account_id, claim_item_id, component)
  select distinct p_organization_id, 'debtor_receivable', l.currency, l.client_organization_id, l.portfolio_id,
         v_account_id, l.claim_item_id, l.component
  from _ledger_lines l where l.book = 'debtor_receivable'
  on conflict (claim_item_id, component) do nothing;
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, owner_organization_id,
                                     portfolio_id, component)
  select distinct p_organization_id, l.book, l.currency, l.client_organization_id, l.owner_organization_id,
         l.portfolio_id, l.component
  from _ledger_lines l where l.book <> 'debtor_receivable'
  on conflict (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component)
    where claim_item_id is null do nothing;
  update _ledger_lines l set ledger_account_id = la.id
  from public.ledger_account la
  where (l.book = 'debtor_receivable' and la.claim_item_id = l.claim_item_id and la.component = l.component)
     or (l.book <> 'debtor_receivable' and la.claim_item_id is null and la.organization_id = p_organization_id
         and la.book = l.book and la.currency = l.currency
         and la.client_organization_id is not distinct from l.client_organization_id
         and la.owner_organization_id is not distinct from l.owner_organization_id
         and la.portfolio_id is not distinct from l.portfolio_id
         and la.component is not distinct from l.component);

  -- Canonical request hash: line order does not matter.
  v_hash := encode(sha256(convert_to(jsonb_build_object(
    'type', p_entry_type,
    'effective_date', p_effective_date,
    'account_id', v_account_id,
    'source', jsonb_build_array(p_meta ->> 'source_type', p_meta ->> 'source_id'),
    'reason', v_reason,
    'engine', jsonb_build_array(p_meta ->> 'engine_version', p_meta ->> 'rule_pack_version_id', p_meta ->> 'inputs_hash'),
    'lines', (select jsonb_agg(jsonb_build_array(ledger_account_id, currency, amount_minor)
                               order by ledger_account_id, amount_minor) from _ledger_lines)
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
  select v_id, line_no, ledger_account_id, amount_minor, currency, p_effective_date from _ledger_lines;
  return query select v_id, true;
end;
$$;

-- Reverse an entry: a mirror entry (same ledger accounts, amounts negated), never an edit.
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
  select * into v_existing from public.ledger_entry
  where organization_id = v_target.organization_id and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.reverses_entry_id = p_entry_id then
      return query select v_existing.id, false;
      return;
    end if;
    raise exception 'ledger: idempotency key % was used for a different request', p_idempotency_key
      using errcode = 'LG004';
  end if;
  if v_target.reverses_entry_id is not null then
    raise exception 'ledger: entry % is a reversal; post a new entry instead', p_entry_id using errcode = 'LG003';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'ledger: a reversal needs a reason' using errcode = 'LG006';
  end if;
  v_date := coalesce(p_effective_date, v_target.effective_date);
  if v_date < v_target.effective_date then
    raise exception 'ledger: a reversal cannot be dated before the entry it reverses' using errcode = 'LG003';
  end if;
  if v_date > private.paris_today() then
    raise exception 'ledger: effective date % is in the future', v_date using errcode = 'LG006';
  end if;
  begin
    insert into public.ledger_entry (organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                     effective_date, line_count, idempotency_key, request_hash, reverses_entry_id,
                                     boarding_batch_id, source_type, source_id, reason)
    values (v_target.organization_id, v_target.client_organization_id, v_target.portfolio_id, v_target.account_id,
            'reversal', v_date, v_target.line_count, p_idempotency_key,
            encode(sha256(convert_to('reversal|' || p_entry_id || '|' || v_date, 'UTF8')), 'hex'),
            p_entry_id, v_target.boarding_batch_id, 'ledger_entry', p_entry_id::text, btrim(p_reason))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'ledger: entry % is already reversed', p_entry_id using errcode = 'LG003';
  end;
  insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency, effective_date)
  select v_id, line_no, ledger_account_id, -amount_minor, currency, v_date
  from public.ledger_posting where entry_id = p_entry_id;
  return query select v_id, true;
end;
$$;

------------------------------------------------------------------------------------------
-- Balances (M2-03): sums of postings with effective_date <= as_of (and, optionally, known by known_at)
------------------------------------------------------------------------------------------

create or replace function private.ledger_balance(p_ledger_account_id uuid, p_as_of date, p_known_at timestamptz default null)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(p.amount_minor), 0)::bigint
  from public.ledger_posting p
  where p.ledger_account_id = p_ledger_account_id and p.effective_date <= p_as_of
    and (p_known_at is null or exists (
          select 1 from public.ledger_entry e where e.id = p.entry_id and e.posted_at <= p_known_at));
$$;

create or replace function private.account_balances(p_account_id uuid, p_as_of date, p_known_at timestamptz default null)
returns table (claim_item_id uuid, component text, currency char(3), balance_minor bigint)
language sql
stable
set search_path = ''
as $$
  select la.claim_item_id, la.component, la.currency, coalesce(sum(p.amount_minor), 0)::bigint
  from public.ledger_account la
  join public.ledger_posting p on p.ledger_account_id = la.id and p.effective_date <= p_as_of
  where la.account_id = p_account_id and la.book = 'debtor_receivable'
    and (p_known_at is null or exists (
          select 1 from public.ledger_entry e where e.id = p.entry_id and e.posted_at <= p_known_at))
  group by la.claim_item_id, la.component, la.currency;
$$;

-- Client money held for a client (CPCE R124-2), shown positive: unallocated receipts + payable.
create or replace function private.client_money_balances(p_client_organization_id uuid, p_as_of date,
                                                         p_known_at timestamptz default null)
returns table (currency char(3), unallocated_minor bigint, payable_minor bigint, held_minor bigint)
language sql
stable
set search_path = ''
as $$
  select la.currency,
         (-coalesce(sum(p.amount_minor) filter (where la.book = 'unallocated_payment'), 0))::bigint,
         (-coalesce(sum(p.amount_minor) filter (where la.book = 'client_payable'), 0))::bigint,
         (-coalesce(sum(p.amount_minor), 0))::bigint
  from public.ledger_account la
  join public.ledger_book b on b.code = la.book and b.money_of = 'client'
  join public.ledger_posting p on p.ledger_account_id = la.id and p.effective_date <= p_as_of
  where la.client_organization_id = p_client_organization_id
    and (p_known_at is null or exists (
          select 1 from public.ledger_entry e where e.id = p.entry_id and e.posted_at <= p_known_at))
  group by la.currency;
$$;

-- Same, for signed-in users: explicit access check first (ADR-0011), as_of defaults to Paris today.
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
           or (la.portfolio_id is null and la.organization_id = any (private.staff_org_ids()))
           or (la.portfolio_id is null and la.client_organization_id = any (private.client_org_ids())
               and exists (select 1 from public.ledger_book b where b.code = la.book and b.client_visible)))
  ) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return private.ledger_balance(p_ledger_account_id, coalesce(p_as_of, private.paris_today()), p_known_at);
end;
$$;

create or replace function public.account_balances(p_account_id uuid, p_as_of date default null,
                                                   p_known_at timestamptz default null)
returns table (claim_item_id uuid, component text, currency char(3), balance_minor bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.account a where a.id = p_account_id and private.can_read_portfolio(a.portfolio_id)) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query select * from private.account_balances(p_account_id, coalesce(p_as_of, private.paris_today()), p_known_at);
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
      and private.can_read_client_data(o.servicer_organization_id, o.id)
  ) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query select * from private.client_money_balances(p_client_organization_id,
                                                           coalesce(p_as_of, private.paris_today()), p_known_at);
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges and RLS (read only; no write policies)
------------------------------------------------------------------------------------------

revoke all on public.currency, public.ledger_book, public.ledger_component, public.ledger_entry_type,
  public.ledger_account, public.ledger_entry, public.ledger_posting from public, anon, authenticated, service_role;
grant select on public.currency, public.ledger_book, public.ledger_component, public.ledger_entry_type,
  public.ledger_account, public.ledger_entry, public.ledger_posting to authenticated, service_role;
-- The owner keeps INSERT (definer functions) and UPDATE (foreign-key row locks need it; the
-- ALWAYS trigger refuses every UPDATE). DELETE and TRUNCATE are revoked even from the owner.
revoke delete, truncate on public.ledger_account, public.ledger_entry, public.ledger_posting from postgres;

revoke execute on function private.ledger_post(uuid, text, date, text, jsonb, jsonb),
  private.ledger_reverse(uuid, text, text, date),
  private.ledger_balance(uuid, date, timestamptz), private.account_balances(uuid, date, timestamptz),
  private.client_money_balances(uuid, date, timestamptz) from public, anon, authenticated;
grant execute on function private.ledger_post(uuid, text, date, text, jsonb, jsonb),
  private.ledger_reverse(uuid, text, text, date),
  private.ledger_balance(uuid, date, timestamptz), private.account_balances(uuid, date, timestamptz),
  private.client_money_balances(uuid, date, timestamptz) to service_role;
grant execute on function public.ledger_balance(uuid, date, timestamptz),
  public.account_balances(uuid, date, timestamptz),
  public.client_money_balances(uuid, date, timestamptz) to authenticated;

alter table public.currency enable row level security;
alter table public.ledger_book enable row level security;
alter table public.ledger_component enable row level security;
alter table public.ledger_entry_type enable row level security;
alter table public.ledger_account enable row level security;
alter table public.ledger_entry enable row level security;
alter table public.ledger_posting enable row level security;

create policy currency_read on public.currency for select to authenticated using ((select auth.uid()) is not null);
create policy ledger_book_read on public.ledger_book for select to authenticated using ((select auth.uid()) is not null);
create policy ledger_component_read on public.ledger_component for select to authenticated
  using ((select auth.uid()) is not null);
create policy ledger_entry_type_read on public.ledger_entry_type for select to authenticated
  using ((select auth.uid()) is not null);

-- One init-plan per query instead of a per-row function call.
create or replace function private.readable_portfolio_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(p.id), '{}') from public.portfolio p
  where (p.organization_id = any (private.staff_org_ids()) or p.client_organization_id = any (private.client_org_ids()))
    and private.can_read_portfolio(p.id);
$$;
grant execute on function private.readable_portfolio_ids() to authenticated;

create policy ledger_account_read on public.ledger_account for select to authenticated using (
  portfolio_id = any ((select private.readable_portfolio_ids())::uuid[])
  or (portfolio_id is null and organization_id = any ((select private.staff_org_ids())::uuid[]))
  or (portfolio_id is null and client_organization_id = any ((select private.client_org_ids())::uuid[])
      and book in (select b.code from public.ledger_book b where b.client_visible)));
create policy ledger_entry_read on public.ledger_entry for select to authenticated using (
  portfolio_id = any ((select private.readable_portfolio_ids())::uuid[])
  or (portfolio_id is null and organization_id = any ((select private.staff_org_ids())::uuid[]))
  or (portfolio_id is null and client_organization_id = any ((select private.client_org_ids())::uuid[])));
create policy ledger_posting_read on public.ledger_posting for select to authenticated using (
  exists (select 1 from public.ledger_account la where la.id = ledger_posting.ledger_account_id));
