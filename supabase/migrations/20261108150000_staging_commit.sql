-- M1d staging, commit, rollback and confirmation of boarding batches.

create table private.boarding_staging (
  id bigint generated always as identity primary key,
  batch_id uuid not null references public.boarding_batch (id) on delete cascade,
  entity text not null,
  key text,
  data jsonb not null
);
create index boarding_staging_batch_idx on private.boarding_staging (batch_id, entity);
alter table private.boarding_staging enable row level security;

alter table public.boarding_batch add column staging_digest jsonb, add column commit_override_reason text;
alter table public.party add column boarding_batch_id uuid references public.boarding_batch (id);
create index party_boarding_batch_idx on public.party (boarding_batch_id);
create index account_boarding_batch_idx on public.account (boarding_batch_id);
alter table public.account
  add constraint account_boarding_batch_fk foreign key (boarding_batch_id) references public.boarding_batch (id);
alter table public.claim_item add column seller_paid_minor bigint not null default 0
  check (seller_paid_minor >= 0);
comment on column public.claim_item.seller_paid_minor is
  'Amount the seller/client reported as already paid at boarding (opening position; ledger in M2).';
alter table public.claim_item drop constraint claim_item_kind_check;
alter table public.claim_item add constraint claim_item_kind_check
  check (kind in ('instalment', 'invoice', 'credit_note', 'rent_period', 'judgment_head', 'loan_principal'));

-- The Layer-1 tables a batch writes to (all EU-template tables).
create or replace function private.eba_tables()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['t1_counterparty', 't2_1_borrower_loan', 't2_2_mortgage_loan_protection',
               't2_3_loan_protection', 't2_4_protection_provider', 't3_loan', 't4_1_protection',
               't4_2_mortgage', 't5_collection']
$$;

do $$
declare t text;
begin
  foreach t in array private.eba_tables() loop
    execute format('alter table eba.%I add constraint %I foreign key (boarding_batch_id)
                    references public.boarding_batch (id)', t, t || '_batch_fk');
  end loop;
end $$;

-- Documents linked from a boarding zip remember their batch (removed on rollback).
alter table public.document add column boarding_batch_id uuid references public.boarding_batch (id);
create index document_boarding_batch_idx on public.document (boarding_batch_id);
create index document_account_idx on public.document (account_id);

-- Validated batches are staged by the worker (same queue).
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
  elsif new.status = 'committed' and old.status is distinct from 'committed'
        and exists (select 1 from public.boarding_file where batch_id = new.id and format = 'zip') then
    perform pgmq.send('boarding', jsonb_build_object('type', 'documents', 'batch_id', new.id));
  end if;
  return new;
end;
$$;

------------------------------------------------------------------------------------------
-- Commit: staging -> Layer 2 (+ Layer 1) in one transaction. Accounts stay `staged`
-- (no outbound activity, founder decision) until the batch is confirmed.
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
  t text;
begin
  select * into v from public.boarding_batch where id = p_batch_id for update;
  if not found or not private.can_board(v.portfolio_id) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if v.status <> 'staged' then
    raise exception 'batch is %, expected staged', v.status using errcode = 'check_violation';
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
  analyze public.party;  -- the joins below must see this batch's parties (hash joins, not loops)

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

  -- Debtor links: civil files link the account to the debtor with the same reference.
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

  insert into public.claim_item (account_id, kind, ref, issue_date, due_date, original_minor,
                                 seller_paid_minor, currency)
  select a.id, d ->> 'kind', d ->> 'ref', (d ->> 'issue_date')::date, (d ->> 'due_date')::date,
         (d ->> 'original_minor')::bigint, coalesce((d ->> 'seller_paid_minor')::bigint, 0),
         coalesce(d ->> 'currency', 'EUR')
  from (select data as d from private.boarding_staging where batch_id = p_batch_id and entity = 'claim_item') s
  join public.account a on a.portfolio_id = v.portfolio_id and a.external_ref = s.d ->> 'account_key'
    and a.boarding_batch_id = p_batch_id
  on conflict (account_id, kind, ref) do nothing;

  select coalesce(m.mandate_type, 'mandate_amicable') into v_mandate_type
  from public.portfolio p left join public.mandate m on m.id = p.mandate_id where p.id = v.portfolio_id;
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id,
                                             mandate_type, valid_from)
  select a.id, v.client_organization_id, v.organization_id, v_mandate_type,
         coalesce(v.cut_off_date, current_date)
  from public.account a where a.boarding_batch_id = p_batch_id;

  -- Layer 1: the EU-template rows as boarded.
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

  perform private.transition_batch(p_batch_id, 'committed', coalesce(nullif(btrim(p_override_reason), ''), 'committed'));
end;
$$;

-- Rollback: remove what the batch created, before confirmation only. The change log keeps the
-- audit trail of everything that was inserted and deleted.
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
  -- Documents from the batch's zip (or linked to its accounts): index rows now, files by the worker.
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

-- Confirmation: servicer staff only, with an active mandate covering the portfolio (R124-3).
-- Accounts become `awaiting_first_letter`: the R124-4 first letter is the first possible contact.
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
  if not exists (
    select 1 from public.portfolio p
    join public.mandate m on m.id = p.mandate_id
    join public.mandate_terms mt on mt.mandate_id = m.id
    where p.id = v.portfolio_id and mt.valid_from <= current_date
      and (mt.valid_to is null or mt.valid_to > current_date)
  ) then
    raise exception 'no active client mandate covers this portfolio (CPCE R124-3)'
      using errcode = 'check_violation';
  end if;
  update public.account set status = 'awaiting_first_letter'
  where boarding_batch_id = p_batch_id and status = 'staged';
  perform private.transition_batch(p_batch_id, 'confirmed', 'confirmed');
end;
$$;

grant execute on function public.commit_boarding_batch(uuid, text) to authenticated;
grant execute on function public.rollback_boarding_batch(uuid, text) to authenticated;
grant execute on function public.confirm_boarding_batch(uuid) to authenticated;
