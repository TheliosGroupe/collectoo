-- M0-14 Layer 2 (operational) core, first slice. Model: docs/DOMAIN.md §3.1–3.3.
-- Every row carries the servicer tenant (organization_id) and the client organization
-- (client_organization_id): a client's debtor data never mixes with another client's
-- (each client is controller of its own debtor data), and RLS stays a cheap equality check.
-- Writes: worker (service_role) only. Reads: RLS.

create extension if not exists btree_gist;

------------------------------------------------------------------------------------------
-- Reference data
------------------------------------------------------------------------------------------

create table public.claim_type (
  code text primary key,
  family text not null check (family in ('bank_credit', 'civil_commercial')),
  label_fr text not null
);
comment on table public.claim_type is 'Claim types (docs/CALCULATION_RULES.md). Rule packs attach in M3.';
insert into public.claim_type (code, family, label_fr) values
  ('consumer_instalment_loan', 'bank_credit', 'Crédit à la consommation amortissable'),
  ('revolving_credit', 'bank_credit', 'Crédit renouvelable'),
  ('overdraft', 'bank_credit', 'Découvert'),
  ('bnpl', 'bank_credit', 'Paiement fractionné / différé'),
  ('consumer_mortgage', 'bank_credit', 'Crédit immobilier'),
  ('professional_loan', 'bank_credit', 'Prêt professionnel'),
  ('b2b_invoice', 'civil_commercial', 'Facture entre professionnels'),
  ('b2c_invoice', 'civil_commercial', 'Facture ou abonnement particulier'),
  ('rent', 'civil_commercial', 'Loyers et charges'),
  ('private_loan', 'civil_commercial', 'Prêt entre particuliers'),
  ('judgment_debt', 'civil_commercial', 'Créance constatée par un titre exécutoire');

------------------------------------------------------------------------------------------
-- Client mandate (R124-3: written agreement with each creditor)
------------------------------------------------------------------------------------------

create table public.mandate (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  reference text not null,
  mandate_type text not null check (mandate_type in ('mandate_amicable', 'servicing_agreement')),
  signed_on date not null,
  signed_document_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, reference)
);

create table public.mandate_terms (
  id uuid primary key default gen_random_uuid(),
  mandate_id uuid not null references public.mandate (id) on delete cascade,
  valid_from date not null,
  valid_to date,
  commission_rate numeric(7, 4) not null check (commission_rate >= 0 and commission_rate <= 1),
  remittance_max_days integer not null default 30 check (remittance_max_days between 1 and 30),
  plan_envelope jsonb not null default '{}',
  settlement_authority jsonb not null default '{}',
  terms jsonb not null default '{}',
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  exclude using gist (mandate_id with =, daterange(valid_from, valid_to, '[)') with &&)
);
comment on column public.mandate_terms.remittance_max_days is
  'Funds remitted to the client within this many days of collection (CPCE R124-6: one month max).';

alter table public.portfolio add column mandate_id uuid references public.mandate (id);

------------------------------------------------------------------------------------------
-- Parties and contact points
------------------------------------------------------------------------------------------

create table public.party (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  kind text not null check (kind in ('natural_person', 'legal_entity')),
  display_name text not null,
  first_name text,
  last_name text,
  birth_date date,
  legal_form text,
  seller_ref text,
  source_attributes jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (kind = 'natural_person' or (first_name is null and birth_date is null))
);
create index party_client_idx on public.party (client_organization_id);
create unique index party_seller_ref_uq on public.party (client_organization_id, seller_ref)
  where seller_ref is not null;

create table public.party_identifier (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.party (id) on delete cascade,
  scheme text not null check (scheme in ('siren', 'siret', 'lei', 'national_id', 'vat', 'seller_ref')),
  value text not null,
  source text not null default 'seller',
  created_at timestamptz not null default now(),
  unique (party_id, scheme, value),
  check (scheme <> 'siren' or value ~ '^[0-9]{9}$'),
  check (scheme <> 'siret' or value ~ '^[0-9]{14}$')
);

create table public.contact_point (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.party (id) on delete cascade,
  type text not null check (type in ('postal', 'email', 'phone', 'messaging')),
  value_raw text not null,
  value_normalised text,
  source text not null check (source in ('seller', 'debtor', 'enrichment', 'collector')),
  status text not null default 'unverified'
    check (status in ('unverified', 'valid', 'invalid', 'opted_out')),
  valid_from date not null default current_date,
  valid_to date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index contact_point_party_idx on public.contact_point (party_id);

-- Per-channel consent and its legal basis (e.g. LRE needs prior consent of a non-professional,
-- CPCE L100; email tracking needs consent, Loi 78-17 art. 82).
create table public.contact_consent (
  id uuid primary key default gen_random_uuid(),
  contact_point_id uuid not null references public.contact_point (id) on delete cascade,
  channel text not null,
  purpose text not null,
  basis text not null check (basis in ('consent', 'legal_obligation', 'legitimate_interest', 'contract')),
  given_at timestamptz not null,
  withdrawn_at timestamptz,
  evidence_document_id uuid,
  created_at timestamptz not null default now(),
  check (withdrawn_at is null or withdrawn_at >= given_at)
);

------------------------------------------------------------------------------------------
-- Accounts (claims)
------------------------------------------------------------------------------------------

create table public.account (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  portfolio_id uuid not null references public.portfolio (id),
  claim_type_code text not null references public.claim_type (code),
  external_ref text not null,
  currency char(3) not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  legal_regime text not null check (legal_regime in (
    'consumer_credit_pre_ccd2', 'consumer_credit_ccd2', 'consumer_mortgage', 'professional_credit',
    'commercial_b2b', 'consumer_b2c', 'civil', 'judgment')),
  status text not null default 'staged' check (status in (
    'staged', 'awaiting_first_letter', 'in_collection', 'arrangement', 'legal', 'on_hold',
    'closed_paid', 'closed_settled', 'closed_uncollectable', 'closed_recalled')),
  contract_date date,
  boarding_batch_id uuid,
  seller_limitation_date date,
  source_attributes jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (portfolio_id, external_ref)
);
create index account_client_idx on public.account (client_organization_id);
create index account_portfolio_idx on public.account (portfolio_id);
comment on column public.account.source_attributes is
  'Seller fields with no operational column yet (kept so a tape can be re-exported).';

create table public.account_party (
  account_id uuid not null references public.account (id) on delete cascade,
  party_id uuid not null references public.party (id),
  role text not null check (role in ('borrower', 'co_borrower', 'guarantor', 'protection_provider', 'heir')),
  capacity text not null check (capacity in ('consumer', 'professional', 'legal_entity')),
  liability text not null default 'joint_several' check (liability in ('joint_several', 'several', 'capped')),
  cap_minor bigint check (cap_minor is null or cap_minor >= 0),
  created_at timestamptz not null default now(),
  primary key (account_id, party_id, role),
  check ((liability = 'capped') = (cap_minor is not null))
);
create index account_party_party_idx on public.account_party (party_id);

create table public.claim_item (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.account (id) on delete cascade,
  kind text not null check (kind in ('instalment', 'invoice', 'rent_period', 'judgment_head', 'loan_principal')),
  ref text not null,
  issue_date date,
  due_date date,
  original_minor bigint not null check (original_minor >= 0),
  currency char(3) not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  created_at timestamptz not null default now(),
  unique (account_id, kind, ref)
);

-- Owner and servicer over time (phase C ready: servicer ≠ owner). No overlapping periods.
create table public.claim_ownership_period (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.account (id) on delete cascade,
  owner_organization_id uuid not null references public.organization (id),
  servicer_organization_id uuid not null references public.organization (id),
  mandate_type text not null check (mandate_type in ('mandate_amicable', 'servicing_agreement', 'owned')),
  valid_from date not null,
  valid_to date,
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  exclude using gist (account_id with =, daterange(valid_from, valid_to, '[)') with &&)
);

create table public.document (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  account_id uuid references public.account (id),
  party_id uuid references public.party (id),
  kind text not null,
  storage_bucket text not null default 'documents',
  storage_path text not null,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  mime_type text not null,
  created_at timestamptz not null default now(),
  unique (storage_bucket, storage_path)
);

------------------------------------------------------------------------------------------
-- Consistency: tenant columns are derived from the parent, never trusted from the caller
------------------------------------------------------------------------------------------

create or replace function private.account_inherit_tenant()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  select p.organization_id, p.client_organization_id
  into new.organization_id, new.client_organization_id
  from public.portfolio p where p.id = new.portfolio_id;
  if new.organization_id is null then
    raise exception 'unknown portfolio %', new.portfolio_id using errcode = 'foreign_key_violation';
  end if;
  return new;
end;
$$;
create trigger account_inherit_tenant before insert or update of portfolio_id on public.account
  for each row execute function private.account_inherit_tenant();

-- An account's parties must belong to the same client organization.
create or replace function private.account_party_same_client()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.account a join public.party p on p.client_organization_id = a.client_organization_id
    where a.id = new.account_id and p.id = new.party_id
  ) then
    raise exception 'party and account belong to different clients' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger account_party_same_client before insert or update on public.account_party
  for each row execute function private.account_party_same_client();

create trigger mandate_touch before update on public.mandate
  for each row execute function private.touch_updated_at();
create trigger party_touch before update on public.party
  for each row execute function private.touch_updated_at();
create trigger contact_point_touch before update on public.contact_point
  for each row execute function private.touch_updated_at();
create trigger account_touch before update on public.account
  for each row execute function private.touch_updated_at();

------------------------------------------------------------------------------------------
-- Change history (M0-12)
------------------------------------------------------------------------------------------

create trigger mandate_change_log after insert or update or delete on public.mandate
  for each row execute function private.log_change();
create trigger mandate_terms_change_log after insert or update or delete on public.mandate_terms
  for each row execute function private.log_change();
create trigger party_change_log after insert or update or delete on public.party
  for each row execute function private.log_change();
create trigger party_identifier_change_log after insert or update or delete on public.party_identifier
  for each row execute function private.log_change();
create trigger contact_point_change_log after insert or update or delete on public.contact_point
  for each row execute function private.log_change();
create trigger contact_consent_change_log after insert or update or delete on public.contact_consent
  for each row execute function private.log_change();
create trigger account_change_log after insert or update or delete on public.account
  for each row execute function private.log_change();
create trigger account_party_change_log after insert or update or delete on public.account_party
  for each row execute function private.log_change('account_id', 'party_id', 'role');
create trigger claim_item_change_log after insert or update or delete on public.claim_item
  for each row execute function private.log_change();
create trigger claim_ownership_period_change_log after insert or update or delete on public.claim_ownership_period
  for each row execute function private.log_change();
create trigger document_change_log after insert or update or delete on public.document
  for each row execute function private.log_change();

------------------------------------------------------------------------------------------
-- RLS: read-only for authenticated users
------------------------------------------------------------------------------------------

-- Staff of the servicer (aal2) or members of the client organization.
create or replace function private.can_read_client_data(p_organization_id uuid, p_client_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_organization_id = any (private.staff_org_ids())
      or p_client_organization_id = any (private.client_org_ids());
$$;
grant execute on function private.can_read_client_data(uuid, uuid) to authenticated;

alter table public.claim_type enable row level security;
alter table public.mandate enable row level security;
alter table public.mandate_terms enable row level security;
alter table public.party enable row level security;
alter table public.party_identifier enable row level security;
alter table public.contact_point enable row level security;
alter table public.contact_consent enable row level security;
alter table public.account enable row level security;
alter table public.account_party enable row level security;
alter table public.claim_item enable row level security;
alter table public.claim_ownership_period enable row level security;
alter table public.document enable row level security;

grant select on public.claim_type, public.mandate, public.mandate_terms, public.party,
  public.party_identifier, public.contact_point, public.contact_consent, public.account,
  public.account_party, public.claim_item, public.claim_ownership_period, public.document
  to authenticated;

create policy claim_type_read on public.claim_type for select to authenticated
  using ((select auth.uid()) is not null);

create policy mandate_read on public.mandate for select to authenticated
  using ((select private.can_read_client_data(organization_id, client_organization_id)));
create policy mandate_terms_read on public.mandate_terms for select to authenticated
  using (exists (select 1 from public.mandate m where m.id = mandate_terms.mandate_id
    and (select private.can_read_client_data(m.organization_id, m.client_organization_id))));

create policy party_read on public.party for select to authenticated
  using ((select private.can_read_client_data(organization_id, client_organization_id)));
create policy party_identifier_read on public.party_identifier for select to authenticated
  using (exists (select 1 from public.party p where p.id = party_identifier.party_id
    and (select private.can_read_client_data(p.organization_id, p.client_organization_id))));
create policy contact_point_read on public.contact_point for select to authenticated
  using (exists (select 1 from public.party p where p.id = contact_point.party_id
    and (select private.can_read_client_data(p.organization_id, p.client_organization_id))));
create policy contact_consent_read on public.contact_consent for select to authenticated
  using (exists (select 1 from public.contact_point c join public.party p on p.id = c.party_id
    where c.id = contact_consent.contact_point_id
    and (select private.can_read_client_data(p.organization_id, p.client_organization_id))));

create policy account_read on public.account for select to authenticated
  using ((select private.can_read_portfolio(portfolio_id)));
create policy account_party_read on public.account_party for select to authenticated
  using (exists (select 1 from public.account a where a.id = account_party.account_id
    and (select private.can_read_portfolio(a.portfolio_id))));
create policy claim_item_read on public.claim_item for select to authenticated
  using (exists (select 1 from public.account a where a.id = claim_item.account_id
    and (select private.can_read_portfolio(a.portfolio_id))));
create policy claim_ownership_period_read on public.claim_ownership_period for select to authenticated
  using (exists (select 1 from public.account a where a.id = claim_ownership_period.account_id
    and (select private.can_read_portfolio(a.portfolio_id))));
create policy document_read on public.document for select to authenticated
  using ((select private.can_read_client_data(organization_id, client_organization_id)));
