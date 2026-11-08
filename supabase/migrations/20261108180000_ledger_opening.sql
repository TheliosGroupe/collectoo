-- M2a-2 opening balances (M2-05, ADR-0012): posted at batch confirmation, by a worker job.
-- Commit computes the same opening plan and checks it against the data-quality report; the
-- ledger then holds only claims under an active mandate, and rollback stays a hard delete.

alter table public.boarding_batch
  add column opening_plan jsonb,
  add column opening_summary jsonb,
  add column confirm_requested_by uuid references public.app_user (id),
  add column confirm_requested_at timestamptz;
comment on column public.boarding_batch.opening_plan is
  'Opening balances to post at confirmation, computed at commit: {currencies: {EUR: {accounts, accounts_without_balance, outstanding_minor, components}}}.';
comment on column public.boarding_batch.opening_summary is 'What the confirmation posted (amounts as text).';

alter table public.boarding_batch drop constraint boarding_batch_status_check;
alter table public.boarding_batch add constraint boarding_batch_status_check check (status in (
  'draft', 'uploaded', 'profiled', 'mapping_proposed', 'mapping_approved', 'transformed', 'needs_fix',
  'validated', 'staged', 'committed', 'confirming', 'confirmed', 'rolled_back', 'abandoned'));

create or replace function private.boarding_transition_allowed(p_from text, p_to text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select (p_from, p_to) in (
    ('draft', 'uploaded'), ('draft', 'abandoned'),
    ('uploaded', 'profiled'), ('uploaded', 'abandoned'),
    ('profiled', 'mapping_proposed'), ('profiled', 'abandoned'),
    ('mapping_proposed', 'mapping_approved'), ('mapping_proposed', 'abandoned'),
    ('mapping_approved', 'transformed'), ('mapping_approved', 'abandoned'),
    ('transformed', 'validated'), ('transformed', 'needs_fix'), ('transformed', 'abandoned'),
    ('needs_fix', 'mapping_proposed'), ('needs_fix', 'abandoned'),
    ('validated', 'staged'), ('validated', 'abandoned'),
    ('staged', 'committed'), ('staged', 'abandoned'),
    ('committed', 'confirming'), ('committed', 'rolled_back'),
    ('confirming', 'confirmed'), ('confirming', 'committed')
  );
$$;

-- Status changes queue the next worker job (same transaction as the change).
create or replace function private.queue_transform_after_approval()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'mapping_approved' and old.status is distinct from 'mapping_approved' then
    perform pgmq.send('boarding', jsonb_build_object('type', 'transform', 'batch_id', new.id));
  elsif new.status = 'validated' and old.status is distinct from 'validated' then
    perform pgmq.send('boarding', jsonb_build_object('type', 'stage', 'batch_id', new.id));
  elsif new.status = 'committed' and old.status = 'staged'
        and exists (select 1 from public.boarding_file where batch_id = new.id and format = 'zip') then
    perform pgmq.send('boarding', jsonb_build_object('type', 'documents', 'batch_id', new.id));
  elsif new.status = 'confirming' and old.status is distinct from 'confirming' then
    perform pgmq.send('boarding', jsonb_build_object('type', 'confirm', 'batch_id', new.id));
  end if;
  return new;
end;
$$;

-- The source of an opening balance is frozen once its account is workable.
create or replace function private.claim_item_frozen()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from public.account a
             where a.id in (old.account_id, new.account_id) and a.status <> 'staged') then
    raise exception 'ledger: claim item % is the source of a posted opening balance; correct it with a ledger entry',
      old.id using errcode = 'LG002';
  end if;
  return new;
end;
$$;
create trigger claim_item_frozen before update of account_id, kind, ref, original_minor, seller_paid_minor, currency
  on public.claim_item for each row execute function private.claim_item_frozen();

------------------------------------------------------------------------------------------
-- Opening balances: one SQL definition, used by commit (plan) and confirmation (posting)
------------------------------------------------------------------------------------------

-- Lines per account: civil items -> one principal line (credit notes negative, minus seller-paid);
-- EU loans -> 3.09 / 3.10 / 3.11 and a balancing line up to the legal balance 3.12 (founder #6).
create or replace function private.opening_lines(p_batch_id uuid)
returns table (account_id uuid, claim_item_id uuid, component text, currency char(3), amount_minor bigint, sort_key text)
language sql
stable
set search_path = ''
as $$
  select a.id, i.id, 'principal', a.currency,
         (case when i.kind = 'credit_note' then -i.original_minor else i.original_minor end) - i.seller_paid_minor,
         coalesce(i.due_date::text, '9999-12-31') || ':' || i.ref
  from public.account a
  join public.claim_item i on i.account_id = a.id
  where a.boarding_batch_id = p_batch_id and i.kind <> 'loan_principal'
  union all
  select a.id, i.id, x.component, a.currency, x.amount, '0000:' || x.component
  from public.account a
  join public.claim_item i on i.account_id = a.id and i.kind = 'loan_principal'
  join eba.t3_loan t on t.boarding_batch_id = p_batch_id and t.f3_01_loan_identifier = a.external_ref
  cross join lateral (values
    ('principal',        (coalesce(t.f3_09_principal_amount, 0) * 100)::bigint),
    ('accrued_interest', (coalesce(t.f3_10_accrued_interest, 0) * 100)::bigint),
    ('other_balances',   (coalesce(t.f3_11_other_balances, 0) * 100)::bigint),
    ('balancing_line',   i.original_minor - ((coalesce(t.f3_09_principal_amount, 0) + coalesce(t.f3_10_accrued_interest, 0)
                           + coalesce(t.f3_11_other_balances, 0)) * 100)::bigint)
  ) x (component, amount)
  where a.boarding_batch_id = p_batch_id;
$$;

-- Facts the opening relies on (each one makes the plan wrong if broken).
create or replace function private.check_opening_sources(p_batch_id uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare v_bad text;
begin
  select a.external_ref into v_bad from public.account a
  join public.claim_item i on i.account_id = a.id and i.kind = 'loan_principal'
  where a.boarding_batch_id = p_batch_id
    and (select count(*) from eba.t3_loan t
         where t.boarding_batch_id = p_batch_id and t.f3_01_loan_identifier = a.external_ref) <> 1
  limit 1;
  if found then
    raise exception 'ledger: EU loan % has no single T3 row in this batch', v_bad using errcode = 'LG006';
  end if;
  select a.external_ref into v_bad from public.account a
  join public.claim_item i on i.account_id = a.id and i.kind = 'loan_principal'
  join eba.t3_loan t on t.boarding_batch_id = p_batch_id and t.f3_01_loan_identifier = a.external_ref
  where a.boarding_batch_id = p_batch_id and i.original_minor <> (coalesce(t.f3_12_legal_balance, 0) * 100)::bigint
  limit 1;
  if found then
    raise exception 'ledger: EU loan % legal balance differs from its 3.12', v_bad using errcode = 'LG006';
  end if;
  select a.external_ref into v_bad from public.account a join public.claim_item i on i.account_id = a.id
  where a.boarding_batch_id = p_batch_id
    and (i.currency <> a.currency
         or not exists (select 1 from public.currency c where c.code = a.currency and c.minor_exponent = 2)
         or (i.kind = 'credit_note' and i.seller_paid_minor > 0))
  limit 1;
  if found then
    raise exception 'ledger: account % has an item in another or unsupported currency, or a paid credit note', v_bad
      using errcode = 'LG006';
  end if;
end;
$$;

-- Totals per currency, in the shape of dq_report.staging.opening: from the plan (committed rows)
-- or from what was posted to the ledger.
create or replace function private.opening_totals(p_batch_id uuid, p_posted boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with src as (
    select l.account_id, l.currency, l.component, l.amount_minor
    from private.opening_lines(p_batch_id) l
    where not p_posted and l.amount_minor <> 0
    union all
    select e.account_id, p.currency, la.component, p.amount_minor
    from public.ledger_entry e
    join public.ledger_posting p on p.entry_id = e.id
    join public.ledger_account la on la.id = p.ledger_account_id and la.book = 'debtor_receivable'
    where p_posted and e.boarding_batch_id = p_batch_id and e.entry_type = 'opening'
  ),
  accts as (select a.id, a.currency from public.account a where a.boarding_batch_id = p_batch_id),
  with_lines as (select distinct account_id from src),
  per_cur as (
    select ac.currency, count(w.account_id) as accounts, count(*) - count(w.account_id) as without
    from accts ac left join with_lines w on w.account_id = ac.id
    group by ac.currency
  ),
  comps as (select currency, component, sum(amount_minor) as total from src group by currency, component),
  outs as (select currency, sum(amount_minor) as total from src group by currency)
  select jsonb_build_object('currencies', coalesce(jsonb_object_agg(pc.currency, jsonb_build_object(
    'accounts', pc.accounts,
    'accounts_without_balance', pc.without,
    'outstanding_minor', coalesce(o.total, 0)::text,
    'components', coalesce((select jsonb_object_agg(c.component, c.total::text)
                            from comps c where c.currency = pc.currency and c.total <> 0), '{}'::jsonb)
  )), '{}'::jsonb))
  from per_cur pc left join outs o on o.currency = pc.currency;
$$;

-- Normal form for comparing opening totals (numbers as numeric, zero components dropped).
create or replace function private.opening_normal(p jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(c.key, jsonb_build_object(
    'accounts', (c.value ->> 'accounts')::numeric,
    'accounts_without_balance', coalesce((c.value ->> 'accounts_without_balance')::numeric, 0),
    'outstanding_minor', (c.value ->> 'outstanding_minor')::numeric,
    'components', coalesce((select jsonb_object_agg(k.key, (k.value #>> '{}')::numeric)
                            from jsonb_each(coalesce(c.value -> 'components', '{}'::jsonb)) k
                            where (k.value #>> '{}')::numeric <> 0), '{}'::jsonb))), '{}'::jsonb)
  from jsonb_each(coalesce(p -> 'currencies', '{}'::jsonb)) c;
$$;

-- Σ opening = the DQ report's reconciled total (as staged): a mismatch is a bug, never overridden.
create or replace function private.assert_opening_matches(p_batch_id uuid, p_totals jsonb)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare v_dq jsonb;
begin
  select dq_report #> '{staging,opening}' into v_dq from public.boarding_batch where id = p_batch_id;
  if v_dq is null then
    raise exception 'ledger: batch % was staged without an opening plan; abandon it and board the file again', p_batch_id
      using errcode = 'LG005';
  end if;
  if private.opening_normal(p_totals) is distinct from private.opening_normal(v_dq) then
    raise exception 'ledger: opening balances do not reconcile with the data-quality report (% vs %)',
      private.opening_normal(p_totals), private.opening_normal(v_dq) using errcode = 'LG005';
  end if;
end;
$$;

-- Active client mandate covering a portfolio on a Paris date (CPCE R124-3).
create or replace function private.has_active_mandate(p_portfolio_id uuid, p_on date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.portfolio p
    join public.mandate m on m.id = p.mandate_id
    join public.mandate_terms mt on mt.mandate_id = m.id
    where p.id = p_portfolio_id and mt.valid_from <= p_on and (mt.valid_to is null or mt.valid_to > p_on)
  );
$$;

-- Post one opening entry per account with a balance (set-based; called by the confirmation only).
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

  drop table if exists pg_temp._open;
  create temp table _open on commit drop as
  select l.account_id, l.claim_item_id, l.component, l.currency, l.amount_minor, l.sort_key, c.sort_order,
         a.organization_id, a.client_organization_id, a.portfolio_id, o.owner_organization_id,
         null::uuid as la_receivable, null::uuid as la_owner
  from private.opening_lines(p_batch_id) l
  join public.account a on a.id = l.account_id
  join public.ledger_component c on c.code = l.component
  left join public.claim_ownership_period o on o.account_id = a.id and o.valid_from <= v.cut_off_date
    and (o.valid_to is null or o.valid_to > v.cut_off_date)
  where l.amount_minor <> 0;
  select account_id::text into v_bad from _open where owner_organization_id is null limit 1;
  if found then
    raise exception 'ledger: account % has no owner on the cut-off date', v_bad using errcode = 'LG006';
  end if;
  analyze _open;

  insert into public.ledger_account (organization_id, book, currency, client_organization_id, portfolio_id,
                                     account_id, claim_item_id, component)
  select distinct organization_id, 'debtor_receivable', currency, client_organization_id, portfolio_id,
         account_id, claim_item_id, component
  from _open
  on conflict (claim_item_id, component) do nothing;
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, owner_organization_id,
                                     portfolio_id, component)
  select distinct organization_id, 'owner_claim', currency, client_organization_id, owner_organization_id,
         portfolio_id, component
  from _open
  on conflict (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component)
    where claim_item_id is null do nothing;
  update _open o set la_receivable = la.id from public.ledger_account la
  where la.claim_item_id = o.claim_item_id and la.component = o.component;
  update _open o set la_owner = la.id from public.ledger_account la
  where la.claim_item_id is null and la.book = 'owner_claim' and la.organization_id = o.organization_id
    and la.currency = o.currency and la.client_organization_id = o.client_organization_id
    and la.owner_organization_id = o.owner_organization_id and la.portfolio_id = o.portfolio_id
    and la.component = o.component;

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
-- Boarding commands
------------------------------------------------------------------------------------------

create or replace function public.commit_boarding_batch(p_batch_id uuid, p_override_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
  v_mandate_type text;
  v_has_links boolean;
  v_plan jsonb;
  t text;
begin
  select * into v from public.boarding_batch where id = p_batch_id for update;
  if not found or not private.can_board(v.portfolio_id) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if v.status <> 'staged' then
    raise exception 'batch is %, expected staged', v.status using errcode = 'check_violation';
  end if;
  if v.cut_off_date is null or v.cut_off_date > private.paris_today() then
    raise exception 'the cut-off date is required and cannot be in the future' using errcode = 'check_violation';
  end if;
  if coalesce(v.dq_report #>> '{reconciliation,status}', '') = 'mismatch'
     and coalesce(btrim(p_override_reason), '') = '' then
    raise exception 'totals do not reconcile with the seller''s control totals: a reason is required'
      using errcode = 'check_violation';
  end if;
  update public.boarding_batch set commit_override_reason = nullif(btrim(p_override_reason), '')
  where id = p_batch_id;
  analyze private.boarding_staging;  -- fresh statistics so the joins below use hash joins

  -- Parties (debtors): reuse a debtor already known for this client (same seller reference).
  insert into public.party (organization_id, client_organization_id, kind, display_name, first_name,
                            birth_date, seller_ref, boarding_batch_id)
  select v.organization_id, v.client_organization_id, d ->> 'kind', d ->> 'display_name',
         case when d ->> 'kind' = 'natural_person' then d ->> 'first_name' end,
         case when d ->> 'kind' = 'natural_person' then (d ->> 'birth_date')::date end,
         d ->> 'seller_ref', p_batch_id
  from (select data as d from private.boarding_staging where batch_id = p_batch_id and entity = 'party') s
  on conflict (client_organization_id, seller_ref) where seller_ref is not null do nothing;
  analyze public.party;

  insert into public.party_identifier (party_id, scheme, value, source)
  select p.id, x.scheme, x.value, 'seller'
  from private.boarding_staging s
  join public.party p on p.client_organization_id = v.client_organization_id and p.seller_ref = s.data ->> 'seller_ref'
  cross join lateral (values ('siren', s.data ->> 'siren'), ('siret', s.data ->> 'siret')) x (scheme, value)
  where s.batch_id = p_batch_id and s.entity = 'party' and x.value is not null
    and p.boarding_batch_id = p_batch_id
  on conflict do nothing;

  insert into public.contact_point (party_id, type, value_raw, value_normalised, source)
  select p.id, s.data ->> 'type', s.data ->> 'value',
         case when s.data ->> 'type' in ('email', 'phone') then s.data ->> 'value' end, 'seller'
  from private.boarding_staging s
  join public.party p on p.client_organization_id = v.client_organization_id and p.seller_ref = s.data ->> 'party_key'
  where s.batch_id = p_batch_id and s.entity = 'contact' and p.boarding_batch_id = p_batch_id;

  insert into public.account (portfolio_id, organization_id, client_organization_id, claim_type_code,
                              external_ref, legal_regime, currency, contract_date,
                              seller_limitation_date, status, boarding_batch_id)
  select v.portfolio_id, v.organization_id, v.client_organization_id, d ->> 'claim_type',
         d ->> 'external_ref', d ->> 'legal_regime', coalesce(d ->> 'currency', 'EUR'),
         (d ->> 'contract_date')::date, (d ->> 'seller_limitation_date')::date, 'staged', p_batch_id
  from (select data as d from private.boarding_staging where batch_id = p_batch_id and entity = 'account') s;
  analyze public.account;

  v_has_links := exists (select 1 from private.boarding_staging
                         where batch_id = p_batch_id and entity = 'account_party');
  insert into public.account_party (account_id, party_id, role, capacity)
  select a.id, p.id, coalesce(s.data ->> 'role', 'borrower'), coalesce(s.data ->> 'capacity', 'consumer')
  from private.boarding_staging s
  join public.account a on a.portfolio_id = v.portfolio_id and a.external_ref = s.data ->> 'account_key'
    and a.boarding_batch_id = p_batch_id
  join public.party p on p.client_organization_id = v.client_organization_id and p.seller_ref = s.data ->> 'party_key'
  where s.batch_id = p_batch_id and s.entity = 'account_party'
  on conflict do nothing;
  insert into public.account_party (account_id, party_id, role, capacity)
  select a.id, p.id, 'borrower', coalesce(s.data ->> 'capacity', 'consumer')
  from private.boarding_staging s
  join public.account a on a.portfolio_id = v.portfolio_id and a.external_ref = s.data ->> 'external_ref'
    and a.boarding_batch_id = p_batch_id
  join public.party p on p.client_organization_id = v.client_organization_id and p.seller_ref = s.data ->> 'external_ref'
  where s.batch_id = p_batch_id and s.entity = 'account' and not v_has_links
  on conflict do nothing;

  -- Claim items: a duplicate (account, kind, ref) now fails loudly (no row silently dropped).
  insert into public.claim_item (account_id, kind, ref, issue_date, due_date, original_minor,
                                 seller_paid_minor, currency)
  select a.id, d ->> 'kind', d ->> 'ref', (d ->> 'issue_date')::date, (d ->> 'due_date')::date,
         (d ->> 'original_minor')::bigint, coalesce((d ->> 'seller_paid_minor')::bigint, 0),
         coalesce(d ->> 'currency', 'EUR')
  from (select data as d from private.boarding_staging where batch_id = p_batch_id and entity = 'claim_item') s
  join public.account a on a.portfolio_id = v.portfolio_id and a.external_ref = s.d ->> 'account_key'
    and a.boarding_batch_id = p_batch_id;

  select coalesce(m.mandate_type, 'mandate_amicable') into v_mandate_type
  from public.portfolio p left join public.mandate m on m.id = p.mandate_id where p.id = v.portfolio_id;
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id,
                                             mandate_type, valid_from)
  select a.id, v.client_organization_id, v.organization_id, v_mandate_type, v.cut_off_date
  from public.account a where a.boarding_batch_id = p_batch_id;

  foreach t in array private.eba_tables() loop
    execute format(
      $sql$insert into eba.%1$I
           select (jsonb_populate_record(null::eba.%1$I,
                     s.data || jsonb_build_object('id', gen_random_uuid(), 'organization_id', $2,
                       'boarding_batch_id', $1, 'created_at', now()))).*
           from private.boarding_staging s where s.batch_id = $1 and s.entity = %2$L$sql$,
      t, 'eba.' || t)
    using p_batch_id, v.organization_id;
  end loop;

  -- The opening balances that confirmation will post, checked now against the report.
  perform private.check_opening_sources(p_batch_id);
  v_plan := private.opening_totals(p_batch_id, false);
  perform private.assert_opening_matches(p_batch_id, v_plan);
  update public.boarding_batch set opening_plan = v_plan where id = p_batch_id;

  perform private.transition_batch(p_batch_id, 'committed', coalesce(nullif(btrim(p_override_reason), ''), 'committed'));
end;
$$;

-- Rollback (before confirmation): unchanged deletes, refused if anything reached the ledger.
create or replace function public.rollback_boarding_batch(p_batch_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
  t text;
  v_objects jsonb;
begin
  select * into v from public.boarding_batch where id = p_batch_id for update;
  if not found or not private.can_board(v.portfolio_id) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if v.status <> 'committed' then
    raise exception 'only a committed, unconfirmed batch can be rolled back (batch is %)', v.status
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.ledger_entry where boarding_batch_id = p_batch_id) then
    raise exception 'ledger: batch % has ledger entries; correct them with reversals', p_batch_id using errcode = 'LG002';
  end if;
  with gone as (
    delete from public.document d
    where d.boarding_batch_id = p_batch_id
       or d.account_id in (select a.id from public.account a where a.boarding_batch_id = p_batch_id)
    returning d.storage_bucket, d.storage_path
  )
  select jsonb_agg(jsonb_build_object('bucket', storage_bucket, 'path', storage_path)) into v_objects
  from gone;
  if v_objects is not null then
    perform pgmq.send('boarding', jsonb_build_object('type', 'purge_documents', 'batch_id', p_batch_id,
                                                     'objects', v_objects));
  end if;
  delete from public.claim_ownership_period o using public.account a
    where o.account_id = a.id and a.boarding_batch_id = p_batch_id;
  delete from public.claim_item i using public.account a where i.account_id = a.id and a.boarding_batch_id = p_batch_id;
  delete from public.account_party l using public.account a where l.account_id = a.id and a.boarding_batch_id = p_batch_id;
  delete from public.account where boarding_batch_id = p_batch_id;
  delete from public.contact_point c using public.party p where c.party_id = p.id and p.boarding_batch_id = p_batch_id
    and not exists (select 1 from public.account_party l where l.party_id = p.id);
  delete from public.party_identifier i using public.party p where i.party_id = p.id and p.boarding_batch_id = p_batch_id
    and not exists (select 1 from public.account_party l where l.party_id = p.id);
  delete from public.party p where p.boarding_batch_id = p_batch_id
    and not exists (select 1 from public.account_party l where l.party_id = p.id);
  foreach t in array private.eba_tables() loop
    execute format('delete from eba.%I where boarding_batch_id = $1', t) using p_batch_id;
  end loop;
  perform private.transition_batch(p_batch_id, 'rolled_back', p_reason);
end;
$$;

-- Confirmation request (staff, two-factor, active mandate): returns at once; the worker posts.
create or replace function public.confirm_boarding_batch(p_batch_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
begin
  select * into v from public.boarding_batch where id = p_batch_id for update;
  if not found or not private.has_role(v.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if v.status <> 'committed' then
    raise exception 'batch is %, expected committed', v.status using errcode = 'check_violation';
  end if;
  if not private.has_active_mandate(v.portfolio_id, private.paris_today()) then
    raise exception 'no active client mandate covers this portfolio (CPCE R124-3)'
      using errcode = 'check_violation';
  end if;
  update public.boarding_batch
  set confirm_requested_by = auth.uid(), confirm_requested_at = now(), failed_job = null
  where id = p_batch_id;
  perform private.transition_batch(p_batch_id, 'confirming', 'confirmation requested');
end;
$$;

-- The worker's confirmation job (one queue transaction, so it happens exactly once).
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
    perform private.transition_batch(p_batch_id, 'committed', 'mandat inactif (CPCE R124-3)', 'worker:boarding');
    return 'mandate_inactive';
  end if;
  perform private.post_opening_balances(p_batch_id);
  update public.account set status = 'awaiting_first_letter'
  where boarding_batch_id = p_batch_id and status = 'staged';
  perform private.transition_batch(p_batch_id, 'confirmed', 'confirmed', 'worker:boarding');
  return 'confirmed';
end;
$$;

revoke execute on function private.complete_batch_confirmation(uuid), private.post_opening_balances(uuid),
  private.opening_lines(uuid), private.opening_totals(uuid, boolean), private.check_opening_sources(uuid),
  private.assert_opening_matches(uuid, jsonb) from public, anon, authenticated;
grant execute on function private.complete_batch_confirmation(uuid) to service_role;
