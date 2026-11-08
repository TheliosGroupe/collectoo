-- M2a-3: the batch commit runs as a worker job, like the confirmation (ADR-0012). At 50k loans it
-- takes ~20 s, above the 8 s a request through the API may last. The command only checks the
-- request and moves the batch to `committing`; the worker writes the rows and the opening plan in
-- one transaction, then moves it to `committed` (or back to `staged`, with the reason, on failure).

alter table public.boarding_batch
  add column commit_requested_by uuid references public.app_user (id),
  add column commit_requested_at timestamptz;

alter table public.boarding_batch drop constraint boarding_batch_status_check;
alter table public.boarding_batch add constraint boarding_batch_status_check check (status in (
  'draft', 'uploaded', 'profiled', 'mapping_proposed', 'mapping_approved', 'transformed', 'needs_fix',
  'validated', 'staged', 'committing', 'committed', 'confirming', 'confirmed', 'rolled_back', 'abandoned'));

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
    ('staged', 'committing'), ('staged', 'abandoned'),
    ('committing', 'committed'), ('committing', 'staged'),
    ('committed', 'confirming'), ('committed', 'rolled_back'),
    ('confirming', 'confirmed'), ('confirming', 'committed')
  );
$$;

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
  elsif new.status = 'committing' and old.status is distinct from 'committing' then
    perform pgmq.send('boarding', jsonb_build_object('type', 'commit', 'batch_id', new.id));
  elsif new.status = 'committed' and old.status = 'committing'
        and exists (select 1 from public.boarding_file where batch_id = new.id and format = 'zip') then
    perform pgmq.send('boarding', jsonb_build_object('type', 'documents', 'batch_id', new.id));
  elsif new.status = 'confirming' and old.status is distinct from 'confirming' then
    perform pgmq.send('boarding', jsonb_build_object('type', 'confirm', 'batch_id', new.id));
  end if;
  return new;
end;
$$;

-- The request (web, as the user): permission, state, cut-off date, reason when totals differ.
create or replace function public.commit_boarding_batch(p_batch_id uuid, p_override_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
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
  -- A new request clears the previous commit failure only.
  update public.boarding_batch
  set commit_override_reason = nullif(btrim(p_override_reason), ''),
      commit_requested_by = auth.uid(), commit_requested_at = now(),
      failed_job = case when failed_job ->> 'type' = 'commit' then null else failed_job end
  where id = p_batch_id;
  perform private.transition_batch(p_batch_id, 'committing', 'commit requested');
end;
$$;

-- The worker's commit job: writes the batch's rows and the opening plan in its transaction.
create or replace function private.complete_batch_commit(p_batch_id uuid)
returns text
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
  if not found or v.status <> 'committing' then
    return 'skipped';  -- a redelivered job, or a batch sent back meanwhile
  end if;
  if v.cut_off_date is null or v.cut_off_date > private.paris_today() then
    raise exception 'the cut-off date is required and cannot be in the future' using errcode = 'check_violation';
  end if;
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
      -- In FROM, the record is built once per row ("(f(x)).*" in the select list calls f once
      -- per column: 49 times per EU loan).
      $sql$insert into eba.%1$I
           select r.* from private.boarding_staging s
           cross join lateral jsonb_populate_record(null::eba.%1$I,
             s.data || jsonb_build_object('id', gen_random_uuid(), 'organization_id', $2,
               'boarding_batch_id', $1, 'created_at', now())) r
           where s.batch_id = $1 and s.entity = %2$L$sql$,
      t, 'eba.' || t)
    using p_batch_id, v.organization_id;
  end loop;

  -- The opening balances that confirmation will post, checked now against the report.
  analyze public.claim_item;  -- the plan joins this batch's rows: statistics must include them
  analyze eba.t3_loan;
  perform private.check_opening_sources(p_batch_id);
  v_plan := private.opening_totals(p_batch_id, false);
  perform private.assert_opening_matches(p_batch_id, v_plan);
  update public.boarding_batch set opening_plan = v_plan where id = p_batch_id;

  perform private.transition_batch(p_batch_id, 'committed', coalesce(v.commit_override_reason, 'committed'),
                                   'worker:boarding');
  return 'committed';
end;
$$;

revoke execute on function private.complete_batch_commit(uuid) from public, anon, authenticated;
grant execute on function private.complete_batch_commit(uuid) to service_role;
