-- M2c-2 (CPCE-03, M2-13 data): identities and terms. Who bills whom, where the client is paid, the money terms of each
-- mandate, the gate that keeps a portfolio out of servicing until they are complete, and the issuer block on receipts.
-- Design: docs/design/m2c-remittances.md §3 (R123-237/238, L441-9, CGI ann. II 242 nonies A), §6.1–§6.2, §8.1–§8.2,
-- §8.5, §9.1, §10, §14.2, §16, §17, §21 (M2c-2), §22, §24 (founder decisions, all accepted 2026-11-09: #5 the grids,
-- #10 a payout IBAN confirmed by a second person, #13 mainland-France professional clients in EUR); founder 2026-11-09:
-- receipts show the issuer's address (a new template version; old receipts keep their bytes).
-- Decisions: docs/adr/0014-remittances-commission-invoices-own-cash.md (M2c-2 addendum).
-- Forward-only: nothing of 20261111090000 or earlier is edited; the functions below are redefined with their SET
-- clauses, SECURITY DEFINER and grants restated.
--
-- What it adds:
--   * `billing_identity` (one per organization: the servicer and each client): legal form and capital, RCS city,
--     registered office and billing address, VAT number (French key checked against the SIREN), professional or not,
--     where it is established (derived from the registered office: mainland France or not), in liquidation, EI,
--     the client's acceptance of PDF invoices (289 VI). Legal name and SIREN stay on `organization`;
--   * `servicer_billing_settings`: invoice prefix, the own account invoices are paid to, VAT on debits (242 nonies A
--     11° bis), the late-payment penalty text (L441-10 II), the bank cut-offs;
--   * client documents (the RIB, the signed mandate or its amendment, the evidence of a client event): uploaded by
--     money staff to the private bucket `documents` under `client/<servicer>/<client>/`, then registered;
--   * `client_payout_account`: the client's payout IBAN with its RIB, proposed by money staff and confirmed by a
--     SECOND person (founder #10): the client's administrator in the client space at aal2, or another servicer admin;
--     the confirmer types the IBAN read on the RIB (compare and set). A confirmed account replaces the previous one.
--     private.registered_client_ibans() (an M2c-1 stub) now returns every confirmed payout IBAN, so a credit from one
--     is read as `client_transfer_in` at import;
--   * `client_status_event` (append-only): proceeding opened, liquidation, death, guardianship, mandate ended (2003),
--     each with its evidence;
--   * `mandate.insurance_clause_ref` (R124-3 2°) and the money terms of each `mandate_terms` version: the commission
--     schedule (`commission-1`, R124-3 3°) and the remittance terms (`remittance-1`, R124-3 4°), each with its clause
--     reference, the signed document, the schedule's SHA-256; validators in SQL (Python twin
--     collectoo_worker.remittance.terms, parity test on 5,000 generated cases); a version is immutable once in force
--     (only its end may move, never into the past), a new version never starts before today (Paris), and a mandate
--     with versions is never deleted (ON DELETE RESTRICT); the existing versions are back-filled with one flat rule
--     at their commission_rate and no clause references, so they read « incomplete »;
--   * the confirmation gate: confirm_boarding_batch (and its job) refuses a portfolio whose mandate version in force
--     lacks its schedule, terms, clause references (2°, 3°, 4°) or document, a servicer whose billing identity is
--     incomplete, a client that is not a professional established in mainland France, and accounts outside EUR
--     (founder #13; COMPLIANCE OQ-42);
--   * receipts: the issuer block (SIREN, RCS city, registered office, legal form and capital, liquidation, EI;
--     C. com. R123-237, R123-238) in the payload of every new version, template `quittance-fr-3`; a version is still
--     issued only when what the receipt says about the payment changes (the issuer block is not compared), so stored
--     receipts are not re-issued and keep their bytes.
-- Redefined: public.confirm_boarding_batch, private.complete_batch_confirmation, private.receipt_prepare,
-- private.registered_client_ibans, public.close_bank_account.

------------------------------------------------------------------------------------------
-- Small pure helpers (also used by the Python twin's tests through the database)
------------------------------------------------------------------------------------------

-- A postal address as the forms send it: {line1, line2?, postcode, city, country}; country ISO 3166 alpha-2; a French
-- postcode has five digits. Unknown keys are refused.
create or replace function private.postal_address_valid(p jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'object'
    and not exists (select 1 from jsonb_object_keys(p) k where k not in ('line1', 'line2', 'postcode', 'city', 'country'))
    and jsonb_typeof(p -> 'line1') = 'string' and length(btrim(p ->> 'line1')) between 1 and 140
    and (p -> 'line2' is null or jsonb_typeof(p -> 'line2') = 'null'
         or (jsonb_typeof(p -> 'line2') = 'string' and length(p ->> 'line2') <= 140))
    and jsonb_typeof(p -> 'postcode') = 'string' and length(btrim(p ->> 'postcode')) between 1 and 16
    and jsonb_typeof(p -> 'city') = 'string' and length(btrim(p ->> 'city')) between 1 and 80
    and jsonb_typeof(p -> 'country') = 'string' and (p ->> 'country') ~ '^[A-Z]{2}$'
    and ((p ->> 'country') <> 'FR' or (p ->> 'postcode') ~ '^[0-9]{5}$'), false);
$$;

-- Where an organization is established, from its registered office (design §6.1, ops critique #27): mainland France
-- is a French address whose postcode is not an overseas one (97x: overseas departments and collectivities; 98x:
-- Monaco's and the Pacific collectivities' codes). Corsica (20xxx) is mainland. Used for founder #13 (OQ-42).
create or replace function private.establishment_of(p_registered_office jsonb)
returns jsonb
language sql
immutable
parallel safe
set search_path = ''
as $$
  select jsonb_build_object(
    'country', p_registered_office ->> 'country',
    'mainland_france', coalesce(p_registered_office ->> 'country' = 'FR'
                                and (p_registered_office ->> 'postcode') ~ '^[0-9]{5}$'
                                and (p_registered_office ->> 'postcode') !~ '^9[78]', false));
$$;

-- The legal forms whose mention we know how to print (C. com. R123-238 1°–4°, R123-237 9° for EI), and whether the
-- capital must follow the name (R123-238 3° SARL, 4° b sociétés par actions). OTHER: a form we do not print (a
-- client's, never printed on our documents; a servicer with another form is OQ-71).
create or replace function private.legal_form_mention(p_form text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case p_form
    when 'SNC' then 'SNC' when 'SCS' then 'SCS' when 'SARL' then 'SARL' when 'SA' then 'SA'
    when 'SA_DIRECTOIRE' then 'société anonyme à directoire et conseil de surveillance'
    when 'SAS' then 'SAS' when 'SCA' then 'SCA' when 'SE' then 'SE' when 'EI' then 'EI' end;
$$;

create or replace function private.legal_form_states_capital(p_form text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(p_form in ('SARL', 'SA', 'SA_DIRECTOIRE', 'SAS', 'SCA', 'SE'), false);
$$;

-- French VAT number: FR + key + SIREN, key = (12 + 3 × (SIREN mod 97)) mod 97 (design §6.1).
create or replace function private.fr_vat_number_valid(p_vat text, p_siren text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(p_vat ~ '^FR[0-9]{11}$' and p_siren ~ '^[0-9]{9}$' and substr(p_vat, 5) = p_siren
                  and substr(p_vat, 3, 2)::integer = (12 + 3 * (p_siren::bigint % 97)) % 97, false);
$$;

------------------------------------------------------------------------------------------
-- Billing identity (§6.1): printed on invoices, credit notes, statements and receipts (242 nonies A 1°–2°,
-- R123-237/238). Legal name and SIREN are the organization's. Invoices freeze a copy (M2c-4/5).
------------------------------------------------------------------------------------------

create table public.billing_identity (
  organization_id uuid primary key references public.organization (id),
  legal_form text check (legal_form in ('SNC', 'SCS', 'SARL', 'SA', 'SA_DIRECTOIRE', 'SAS', 'SCA', 'SE', 'EI', 'OTHER')),
  share_capital_minor bigint check (share_capital_minor > 0 and share_capital_minor <= 100000000000000000),
  rcs_city text check (length(btrim(rcs_city)) between 1 and 80),
  registered_office jsonb not null check (private.postal_address_valid(registered_office)),
  billing_address jsonb check (billing_address is null or private.postal_address_valid(billing_address)),   -- null: the registered office
  vat_number text check (vat_number ~ '^FR[0-9]{11}$'),
  is_professional boolean not null,
  established_in jsonb not null generated always as (private.establishment_of(registered_office)) stored,
  in_liquidation boolean not null default false,                                  -- R123-237 4°
  entrepreneur_individuel boolean not null generated always as (coalesce(legal_form = 'EI', false)) stored,  -- 9°
  invoice_acceptance_ref text check (length(btrim(invoice_acceptance_ref)) between 1 and 200),  -- 289 VI
  version integer not null default 1 check (version >= 1),                         -- compare and set
  updated_by uuid references public.app_user (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.billing_identity is
  'Billing identity of an organization (servicer or client): legal form, capital, RCS, registered office, VAT, '
  'professional, establishment (derived), liquidation, EI, PDF-invoice acceptance. Name and SIREN on organization.';

-- The VAT number belongs to the organization's SIREN; the row is the organization's; nothing but set_billing_identity
-- moves the version.
create or replace function private.billing_identity_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_siren text;
begin
  select o.siren into v_siren from public.organization o where o.id = new.organization_id;
  if new.vat_number is not null and not private.fr_vat_number_valid(new.vat_number, v_siren) then
    raise exception 'billing identity: the VAT number does not match the SIREN' using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE' and (new.organization_id <> old.organization_id or new.created_at <> old.created_at) then
    raise exception 'billing identity: its organization is fixed' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger billing_identity_guard before insert or update on public.billing_identity
  for each row execute function private.billing_identity_guard();
alter table public.billing_identity enable always trigger billing_identity_guard;
create trigger billing_identity_no_delete before delete or truncate on public.billing_identity
  for each statement execute function private.refuse_delete();
alter table public.billing_identity enable always trigger billing_identity_no_delete;
create trigger billing_identity_touch before update on public.billing_identity
  for each row execute function private.touch_updated_at();
create trigger billing_identity_change_log after insert or update or delete on public.billing_identity
  for each row execute function private.log_change('organization_id');

-- What is missing before the identity can be printed (field codes, in form order; empty: complete). The servicer:
-- SIREN, a legal form we can print, the capital when the form states it (R123-238), the RCS city (R123-237 2°), the
-- registered office (3°), the VAT number (242 nonies A 2°). A client: SIREN (242 nonies A 1°), the registered office,
-- professional (L441-9; founder #13), established in mainland France (founder #13, OQ-42).
create or replace function private.billing_identity_gaps(p_organization_id uuid)
returns text[]
language sql
stable
set search_path = ''
as $$
  select case when o.id is null then array['organization']
         when b.organization_id is null then
           array_remove(array['identity', case when o.siren is null then 'siren' end], null)
         when o.kind = 'servicer' then array_remove(array[
           case when o.siren is null then 'siren' end,
           case when b.legal_form is null or b.legal_form = 'OTHER' then 'legal_form' end,
           case when private.legal_form_states_capital(b.legal_form) and b.share_capital_minor is null
                then 'share_capital' end,
           case when b.rcs_city is null then 'rcs_city' end,
           case when b.vat_number is null then 'vat_number' end,
           case when not b.is_professional then 'professional' end], null)
         else array_remove(array[
           case when o.siren is null then 'siren' end,
           case when not b.is_professional then 'professional' end,
           case when not (b.established_in ->> 'mainland_france')::boolean then 'mainland_france' end], null) end
  from (select p_organization_id as id) x
  left join public.organization o on o.id = x.id
  left join public.billing_identity b on b.organization_id = o.id;
$$;

-- « Identité de facturation » (admin of the servicer at aal2): the servicer's own, or one of its clients'. Compare and
-- set on the version the page showed (null: the first). p_identity: {legal_name, siren, legal_form, share_capital_minor
-- (text), rcs_city, registered_office, billing_address, vat_number, is_professional, in_liquidation,
-- invoice_acceptance_ref}. The legal name and SIREN are written on the organization.
create or replace function public.set_billing_identity(p_idempotency_key text, p_organization_id uuid,
                                                       p_identity jsonb, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  o public.organization;
  b public.billing_identity;
  v_servicer uuid;
  v_request jsonb := jsonb_build_object('organization_id', p_organization_id, 'identity', p_identity,
                                        'expected_version', p_expected_version);
  v_result jsonb;
  v_name text := btrim(coalesce(p_identity ->> 'legal_name', ''));
  v_siren text := nullif(btrim(coalesce(p_identity ->> 'siren', '')), '');
  v_form text := nullif(btrim(coalesce(p_identity ->> 'legal_form', '')), '');
  v_capital text := nullif(btrim(coalesce(p_identity ->> 'share_capital_minor', '')), '');
  v_rcs text := nullif(btrim(coalesce(p_identity ->> 'rcs_city', '')), '');
  v_vat text := nullif(upper(replace(coalesce(p_identity ->> 'vat_number', ''), ' ', '')), '');
  v_accept text := nullif(btrim(coalesce(p_identity ->> 'invoice_acceptance_ref', '')), '');
  v_office jsonb := p_identity -> 'registered_office';
  v_billing jsonb := nullif(p_identity -> 'billing_address', 'null'::jsonb);
begin
  select * into o from public.organization where id = p_organization_id for update;
  v_servicer := coalesce(o.servicer_organization_id, o.id);
  if o.id is null or not private.has_role(v_servicer, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('set_billing_identity', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if jsonb_typeof(p_identity) is distinct from 'object' then
    raise exception 'billing identity: invalid' using errcode = 'check_violation';
  end if;
  select * into b from public.billing_identity where organization_id = o.id for update;
  if (b.organization_id is null and p_expected_version is not null)
     or (b.organization_id is not null and b.version is distinct from p_expected_version) then
    raise exception 'billing identity changed since it was read' using errcode = 'serialization_failure';
  end if;
  if v_name = '' or length(v_name) > 200 then
    raise exception 'billing identity: a legal name is required' using errcode = 'check_violation';
  end if;
  if v_siren is not null and v_siren !~ '^[0-9]{9}$' then
    raise exception 'billing identity: invalid SIREN' using errcode = 'check_violation';
  end if;
  if v_form is not null and v_form not in ('SNC', 'SCS', 'SARL', 'SA', 'SA_DIRECTOIRE', 'SAS', 'SCA', 'SE', 'EI',
                                           'OTHER') then
    raise exception 'billing identity: invalid legal form' using errcode = 'check_violation';
  end if;
  if v_capital is not null and (v_capital !~ '^[0-9]{1,17}$' or v_capital::bigint <= 0) then
    raise exception 'billing identity: invalid share capital' using errcode = 'check_violation';
  end if;
  if not private.postal_address_valid(v_office) then
    raise exception 'billing identity: invalid registered office' using errcode = 'check_violation';
  end if;
  if v_billing is not null and not private.postal_address_valid(v_billing) then
    raise exception 'billing identity: invalid billing address' using errcode = 'check_violation';
  end if;
  if v_vat is not null and not private.fr_vat_number_valid(v_vat, v_siren) then
    raise exception 'billing identity: the VAT number does not match the SIREN' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_identity -> 'is_professional') is distinct from 'boolean'
     or coalesce(jsonb_typeof(p_identity -> 'in_liquidation'), 'boolean') <> 'boolean' then
    raise exception 'billing identity: invalid' using errcode = 'check_violation';
  end if;
  if length(v_accept) > 200 or length(v_rcs) > 80 then
    raise exception 'billing identity: a text is too long' using errcode = 'check_violation';
  end if;
  -- The servicer prints every mention: its identity is saved complete or not at all (receipts read it as it is).
  if o.kind = 'servicer' and (v_siren is null or v_form is null or v_form = 'OTHER' or v_rcs is null or v_vat is null
                              or (private.legal_form_states_capital(v_form) and v_capital is null)
                              or not (p_identity ->> 'is_professional')::boolean) then
    raise exception 'billing identity: the servicer''s identity is incomplete (SIREN, legal form, capital, RCS, VAT number)'
      using errcode = 'check_violation';
  end if;
  if (o.legal_name, o.siren) is distinct from (v_name, v_siren) then
    update public.organization set legal_name = v_name, siren = v_siren where id = o.id;
  end if;
  insert into public.billing_identity as t (organization_id, legal_form, share_capital_minor, rcs_city,
                                            registered_office, billing_address, vat_number, is_professional,
                                            in_liquidation, invoice_acceptance_ref, updated_by)
  values (o.id, v_form, v_capital::bigint, v_rcs, v_office, v_billing, v_vat,
          (p_identity ->> 'is_professional')::boolean, coalesce((p_identity ->> 'in_liquidation')::boolean, false),
          v_accept, auth.uid())
  on conflict (organization_id) do update
  set legal_form = excluded.legal_form, share_capital_minor = excluded.share_capital_minor,
      rcs_city = excluded.rcs_city, registered_office = excluded.registered_office,
      billing_address = excluded.billing_address, vat_number = excluded.vat_number,
      is_professional = excluded.is_professional, in_liquidation = excluded.in_liquidation,
      invoice_acceptance_ref = excluded.invoice_acceptance_ref, updated_by = excluded.updated_by,
      version = t.version + 1
  returning * into b;
  v_result := jsonb_build_object('organization_id', o.id, 'version', b.version,
                                 'gaps', to_jsonb(private.billing_identity_gaps(o.id)));
  perform private.command_record('set_billing_identity', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- The gaps of an identity the caller may read (staff of the servicer, members of the client or of its servicer's
-- clients reading the servicer's), for the pages.
create or replace function public.billing_identity_gaps(p_organization_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.can_read_billing_identity(p_organization_id) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return private.billing_identity_gaps(p_organization_id);
end;
$$;

-- Who reads a billing identity (§6.2): staff of the servicer (its own and its clients'), a client's members (their
-- own and their servicer's).
create or replace function private.can_read_billing_identity(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.organization o
    where o.id = p_organization_id
      and (coalesce(o.servicer_organization_id, o.id) = any (private.staff_org_ids())
           or o.id = any (private.client_org_ids())
           or (o.kind = 'servicer' and exists (select 1 from public.organization c
                                               where c.id = any (private.client_org_ids())
                                                 and c.servicer_organization_id = o.id))));
$$;

------------------------------------------------------------------------------------------
-- Servicer billing settings (§6.1): money staff read, admins write.
------------------------------------------------------------------------------------------

create table public.servicer_billing_settings (
  organization_id uuid primary key references public.organization (id),
  invoice_prefix text not null default 'FC' check (invoice_prefix ~ '^[A-Z]{2,6}$'),
  own_bank_account_id uuid references public.bank_account (id),       -- where due invoices are paid (M2c-4)
  vat_on_debits boolean not null default false,                        -- 242 nonies A 11° bis
  -- L441-10 II: absent a rate agreed, the ECB rate + 10 points; an agreed rate is at least three times the legal rate
  -- (checked by ops; OQ-72: no legal-rate table yet)
  penalty_text text not null default 'Pénalités de retard : taux d''intérêt appliqué par la Banque centrale européenne '
    'à son opération de refinancement la plus récente, majoré de 10 points de pourcentage.'
    check (length(btrim(penalty_text)) between 1 and 500),
  bank_cutoff jsonb not null default '{}' check (jsonb_typeof(bank_cutoff) = 'object'),  -- {bank_account_id: "HH:MM"}
  version integer not null default 1 check (version >= 1),
  updated_by uuid references public.app_user (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.servicer_billing_settings is
  'Invoice prefix, own account for due invoices, VAT on debits, late-payment penalty text, bank cut-offs (Paris time).';

-- The servicer's, its own account (active, purpose own), cut-offs of its client_funds accounts as HH:MM.
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
                                 and b.organization_id = new.organization_id and b.purpose = 'client_funds')) then
    raise exception 'billing settings: a cut-off is an HH:MM time for a client_funds account of the servicer'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger servicer_billing_settings_guard before insert or update on public.servicer_billing_settings
  for each row execute function private.servicer_billing_settings_guard();
alter table public.servicer_billing_settings enable always trigger servicer_billing_settings_guard;
create trigger servicer_billing_settings_no_delete before delete or truncate on public.servicer_billing_settings
  for each statement execute function private.refuse_delete();
alter table public.servicer_billing_settings enable always trigger servicer_billing_settings_no_delete;
create trigger servicer_billing_settings_touch before update on public.servicer_billing_settings
  for each row execute function private.touch_updated_at();
create trigger servicer_billing_settings_change_log after insert or update or delete on public.servicer_billing_settings
  for each row execute function private.log_change('organization_id');

-- « Paramètres de facturation » (admin at aal2, compare and set on the version shown; null: the first).
-- p_settings: {invoice_prefix, own_bank_account_id, vat_on_debits, penalty_text, bank_cutoff}.
create or replace function public.set_servicer_billing_settings(p_idempotency_key text, p_organization_id uuid,
                                                                p_settings jsonb, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  s public.servicer_billing_settings;
  v_request jsonb := jsonb_build_object('organization_id', p_organization_id, 'settings', p_settings,
                                        'expected_version', p_expected_version);
  v_result jsonb;
  v_prefix text := upper(btrim(coalesce(p_settings ->> 'invoice_prefix', 'FC')));
  v_own uuid;
  v_penalty text := btrim(coalesce(p_settings ->> 'penalty_text', ''));
begin
  if not private.has_role(p_organization_id, array['admin'])
     or not exists (select 1 from public.organization o where o.id = p_organization_id and o.kind = 'servicer') then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('set_servicer_billing_settings', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if jsonb_typeof(p_settings) is distinct from 'object'
     or coalesce(jsonb_typeof(p_settings -> 'vat_on_debits'), 'boolean') <> 'boolean'
     or coalesce(jsonb_typeof(p_settings -> 'bank_cutoff'), 'object') <> 'object'
     or coalesce(p_settings ->> 'own_bank_account_id', '') !~
        '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$' then
    raise exception 'billing settings: invalid' using errcode = 'check_violation';
  end if;
  if v_prefix !~ '^[A-Z]{2,6}$' then
    raise exception 'billing settings: the invoice prefix has 2 to 6 capital letters' using errcode = 'check_violation';
  end if;
  v_own := nullif(p_settings ->> 'own_bank_account_id', '')::uuid;
  select * into s from public.servicer_billing_settings where organization_id = p_organization_id for update;
  if (s.organization_id is null and p_expected_version is not null)
     or (s.organization_id is not null and s.version is distinct from p_expected_version) then
    raise exception 'billing settings changed since they were read' using errcode = 'serialization_failure';
  end if;
  -- the own account is locked (as close_bank_account locks it) before the guard reads it
  perform 1 from public.bank_account b where b.id = v_own for share;
  insert into public.servicer_billing_settings as t (organization_id, invoice_prefix, own_bank_account_id,
                                                     vat_on_debits, penalty_text, bank_cutoff, updated_by)
  values (p_organization_id, v_prefix, v_own, coalesce((p_settings ->> 'vat_on_debits')::boolean, false),
          case when v_penalty = '' then
            'Pénalités de retard : taux d''intérêt appliqué par la Banque centrale européenne à son opération de '
            'refinancement la plus récente, majoré de 10 points de pourcentage.' else v_penalty end,
          coalesce(p_settings -> 'bank_cutoff', '{}'), auth.uid())
  on conflict (organization_id) do update
  set invoice_prefix = excluded.invoice_prefix, own_bank_account_id = excluded.own_bank_account_id,
      vat_on_debits = excluded.vat_on_debits, penalty_text = excluded.penalty_text,
      bank_cutoff = excluded.bank_cutoff, updated_by = excluded.updated_by, version = t.version + 1
  returning * into s;
  v_result := jsonb_build_object('organization_id', s.organization_id, 'version', s.version);
  perform private.command_record('set_servicer_billing_settings', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- Client documents (the RIB of a payout account, the signed mandate or its amendment, the evidence of a client event):
-- money staff upload the file to the private bucket `documents` at client/<servicer>/<client>/<uuid>.<pdf|png|jpg>,
-- then register it. Read by money staff; the RIB and the mandate also by the client's administrators (whole client).
------------------------------------------------------------------------------------------

-- Client administrators with access to the whole client (no portfolio restriction, OQ-48 default).
create or replace function private.client_admin_whole_org_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.organization_id), '{}')
  from public.membership m
  join public.organization o on o.id = m.organization_id and o.kind <> 'servicer'
  where m.user_id = (select auth.uid()) and m.role = 'client_admin'
    and not exists (select 1 from public.portfolio_access a where a.user_id = (select auth.uid()));
$$;

-- The servicer and client a client-document key names, when it is one (else nulls).
create or replace function private.client_document_key(p_name text)
returns table (servicer_id uuid, client_id uuid)
language sql
immutable
set search_path = ''
as $$
  select (regexp_match(p_name, '^client/([0-9a-f-]{36})/([0-9a-f-]{36})/[0-9a-f-]{36}\.(pdf|png|jpg|jpeg)$'))[1]::uuid,
         (regexp_match(p_name, '^client/([0-9a-f-]{36})/([0-9a-f-]{36})/[0-9a-f-]{36}\.(pdf|png|jpg|jpeg)$'))[2]::uuid
  where p_name ~ '^client/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(pdf|png|jpg|jpeg)$';
$$;

-- A user may upload only a new client-document key of a client of a servicer where they are money staff.
create or replace function private.can_upload_client_document_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from private.client_document_key(p_name) k
    join public.organization c on c.id = k.client_id and c.servicer_organization_id = k.servicer_id
    where k.servicer_id = any (private.money_staff_org_ids())
      and not exists (select 1 from public.document d where d.storage_bucket = 'documents' and d.storage_path = p_name));
$$;
create policy client_document_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and name like 'client/%'
              and (select private.can_upload_client_document_object(name)));

-- Who reads a client document (row and file): money staff; the RIB and the mandate, the client's administrators too.
create or replace function private.can_read_client_document(p_organization_id uuid, p_client_organization_id uuid,
                                                            p_kind text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_organization_id = any (private.money_staff_org_ids())
      or (p_kind in ('payout_rib', 'mandate_document')
          and p_client_organization_id = any (private.client_admin_whole_org_ids()));
$$;
create or replace function private.can_read_client_document_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.document d
                 where d.storage_bucket = 'documents' and d.storage_path = p_name
                   and d.kind in ('payout_rib', 'mandate_document', 'client_status_evidence')
                   and private.can_read_client_document(d.organization_id, d.client_organization_id, d.kind));
$$;
create policy client_document_object_read on storage.objects for select to authenticated
  using (bucket_id = 'documents' and name like 'client/%' and (select private.can_read_client_document_object(name)));

-- document_read lets every staff member and every member of the client read its documents; these kinds are narrower.
create policy document_client_money_scope on public.document as restrictive for select to authenticated
  using (kind not in ('payout_rib', 'mandate_document', 'client_status_evidence')
         or private.can_read_client_document(organization_id, client_organization_id, kind));

-- « Joindre un document » (admin or ops manager at aal2): the file is already at its key; registered once.
create or replace function public.register_client_document(p_idempotency_key text, p_client_organization_id uuid,
                                                           p_kind text, p_storage_path text, p_file_name text,
                                                           p_sha256 text, p_mime_type text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.organization;
  v_request jsonb := jsonb_build_object('client_organization_id', p_client_organization_id, 'kind', p_kind,
                                        'storage_path', p_storage_path, 'file_name', p_file_name,
                                        'sha256', lower(p_sha256), 'mime_type', p_mime_type);
  v_result jsonb;
  v_id uuid;
begin
  select * into c from public.organization where id = p_client_organization_id;
  if c.id is null or c.servicer_organization_id is null
     or not private.has_role(c.servicer_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('register_client_document', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_kind is null or p_kind not in ('payout_rib', 'mandate_document', 'client_status_evidence') then
    raise exception 'document: invalid kind' using errcode = 'check_violation';
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-fA-F]{64}$' or p_file_name is null
     or length(p_file_name) not between 1 and 255 or p_file_name ~ '[/\\[:cntrl:]]'
     or p_mime_type is null or p_mime_type not in ('application/pdf', 'image/png', 'image/jpeg') then
    raise exception 'document: invalid file' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from private.client_document_key(p_storage_path) k
                 where k.servicer_id = c.servicer_organization_id and k.client_id = c.id) then
    raise exception 'document: the file is not at a key of this client' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'documents' and o.name = p_storage_path) then
    raise exception 'document: the file is not uploaded yet' using errcode = 'check_violation';
  end if;
  insert into public.document (organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                               mime_type, file_name)
  values (c.servicer_organization_id, c.id, p_kind, 'documents', p_storage_path, lower(p_sha256), p_mime_type,
          p_file_name)
  returning id into v_id;
  v_result := jsonb_build_object('document_id', v_id);
  perform private.command_record('register_client_document', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- A registered document of this client of this kind.
create or replace function private.client_document_of(p_document_id uuid, p_client_organization_id uuid, p_kind text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.document d
                 where d.id = p_document_id and d.client_organization_id = p_client_organization_id
                   and d.account_id is null and d.kind = p_kind);
$$;

------------------------------------------------------------------------------------------
-- Payout accounts (§6.1; founder #10; design §2.2 #16): the client's IBAN, as on its RIB, proposed by money staff and
-- confirmed by a second person — the client's administrator in the client space at aal2, or another admin of the
-- servicer. The confirmer types the IBAN read on the RIB: it must be the one proposed. One current account (active
-- or returned) and one pending proposal per client and currency; a confirmed proposal replaces the current account.
-- States: proposed → active | rejected; active → retired | returned (M2c-6, a payout came back); returned → retired.
------------------------------------------------------------------------------------------

create table public.client_payout_account (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  currency char(3) not null references public.currency (code),
  iban text not null check (private.iban_valid(iban)),
  bic text check (bic ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$'),
  holder_name text not null check (length(btrim(holder_name)) between 1 and 70),   -- the payee name the bank checks
  evidence_document_id uuid not null references public.document (id),             -- the RIB
  kind text not null default 'client' check (kind in ('client', 'court_appointed')),  -- L641-9: the liquidator's
  status text not null default 'proposed' check (status in ('proposed', 'active', 'returned', 'retired', 'rejected')),
  proposed_by uuid not null references public.app_user (id),
  proposed_at timestamptz not null default now(),
  confirmed_by uuid references public.app_user (id),
  confirmed_at timestamptz,
  confirmed_via text check (confirmed_via in ('client_portal', 'second_admin')),
  closed_by uuid references public.app_user (id),              -- who rejected or retired it
  closed_at timestamptz,
  closed_reason text check (length(btrim(closed_reason)) between 1 and 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint client_payout_account_second_person check (confirmed_by is distinct from proposed_by),
  constraint client_payout_account_confirmed check (
    (confirmed_by is null) = (confirmed_at is null) and (confirmed_at is null) = (confirmed_via is null)
    and (status in ('active', 'returned', 'retired')) = (confirmed_at is not null)),
  constraint client_payout_account_closed check (
    (status in ('retired', 'rejected')) = (closed_at is not null)
    and (closed_at is null) = (closed_by is null) and (closed_at is null) = (closed_reason is null))
);
create unique index client_payout_account_current_uq on public.client_payout_account (client_organization_id, currency)
  where status in ('active', 'returned');
create unique index client_payout_account_proposed_uq on public.client_payout_account (client_organization_id, currency)
  where status = 'proposed';
create index client_payout_account_confirmed_idx on public.client_payout_account (organization_id)
  where confirmed_at is not null;
create index client_payout_account_iban_idx on public.client_payout_account (organization_id, iban);
comment on table public.client_payout_account is
  'Client payout IBAN with its RIB; proposed by money staff, confirmed by a second person (founder #10).';

-- What was proposed never changes; the status moves only along the state machine; a client of the servicer, its
-- RIB a document of that client.
create or replace function private.client_payout_account_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'proposed' then
      raise exception 'payout account: starts proposed' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.organization c where c.id = new.client_organization_id
                     and c.servicer_organization_id = new.organization_id)
       or not private.client_document_of(new.evidence_document_id, new.client_organization_id, 'payout_rib') then
      raise exception 'payout account: a client of the servicer, with that client''s RIB' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.client_organization_id, new.currency, new.iban, new.bic, new.holder_name,
      new.evidence_document_id, new.kind, new.proposed_by, new.proposed_at, new.created_at)
     is distinct from
     (old.id, old.organization_id, old.client_organization_id, old.currency, old.iban, old.bic, old.holder_name,
      old.evidence_document_id, old.kind, old.proposed_by, old.proposed_at, old.created_at)
     or (old.confirmed_at is not null and (new.confirmed_by, new.confirmed_at, new.confirmed_via)
                                          is distinct from (old.confirmed_by, old.confirmed_at, old.confirmed_via))
     or (old.closed_at is not null and (new.closed_by, new.closed_at, new.closed_reason)
                                       is distinct from (old.closed_by, old.closed_at, old.closed_reason))
     or (new.status <> old.status and not (
           (old.status = 'proposed' and new.status in ('active', 'rejected'))
           or (old.status = 'active' and new.status in ('retired', 'returned'))
           or (old.status = 'returned' and new.status = 'retired'))) then
    raise exception 'payout account %: what was proposed never changes, and its status only moves forward', old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger client_payout_account_guard before insert or update on public.client_payout_account
  for each row execute function private.client_payout_account_guard();
alter table public.client_payout_account enable always trigger client_payout_account_guard;
create trigger client_payout_account_no_delete before delete or truncate on public.client_payout_account
  for each statement execute function private.refuse_delete();
alter table public.client_payout_account enable always trigger client_payout_account_no_delete;
create trigger client_payout_account_touch before update on public.client_payout_account
  for each row execute function private.touch_updated_at();
create trigger client_payout_account_change_log after insert or update or delete on public.client_payout_account
  for each row execute function private.log_change();

-- « Proposer un IBAN de reversement » (admin or ops manager at aal2): the IBAN and holder as on the client's RIB.
-- Refused: an IBAN of the servicer's own bank accounts (dedicated or own), one already proposed or current for another
-- client of the servicer, a second pending proposal.
create or replace function public.propose_payout_account(p_idempotency_key text, p_client_organization_id uuid,
                                                         p_currency text, p_iban text, p_holder_name text,
                                                         p_bic text, p_evidence_document_id uuid,
                                                         p_kind text default 'client')
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  c public.organization;
  v_iban text := private.rf_normalise(coalesce(p_iban, ''));
  v_bic text := nullif(private.rf_normalise(coalesce(p_bic, '')), '');
  v_holder text := btrim(coalesce(p_holder_name, ''));
  v_request jsonb;
  v_result jsonb;
  v_id uuid;
begin
  select * into c from public.organization where id = p_client_organization_id;
  if c.id is null or c.servicer_organization_id is null
     or not private.has_role(c.servicer_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('client_organization_id', c.id, 'currency', p_currency, 'iban', v_iban,
                                  'holder_name', v_holder, 'bic', v_bic, 'evidence_document_id', p_evidence_document_id,
                                  'kind', p_kind);
  v_result := private.command_replay('propose_payout_account', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if not private.iban_valid(v_iban) then
    raise exception 'invalid IBAN' using errcode = 'check_violation';
  end if;
  if v_bic is not null and v_bic !~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$' then
    raise exception 'invalid BIC' using errcode = 'check_violation';
  end if;
  if v_holder = '' or length(v_holder) > 70 then
    raise exception 'payout account: the holder''s name is required (70 characters at most)'
      using errcode = 'check_violation';
  end if;
  if p_kind is null or p_kind not in ('client', 'court_appointed') then
    raise exception 'payout account: invalid kind' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.currency where code = p_currency) then
    raise exception 'unsupported currency' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, c.id, 'payout_rib') then
    raise exception 'payout account: the client''s RIB is required' using errcode = 'check_violation';
  end if;
  -- one decision at a time per servicer's payout accounts (the uniqueness checks below see every earlier one)
  perform pg_advisory_xact_lock(hashtext('payout_accounts:' || c.servicer_organization_id::text));
  if exists (select 1 from public.bank_account b where b.organization_id = c.servicer_organization_id
               and b.iban = v_iban) then
    raise exception 'payout account: this IBAN is one of the servicer''s own bank accounts'
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.client_payout_account a
             where a.organization_id = c.servicer_organization_id and a.iban = v_iban
               and a.client_organization_id <> c.id and a.status in ('proposed', 'active', 'returned')) then
    raise exception 'payout account: this IBAN is another client''s payout account' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.client_payout_account a where a.client_organization_id = c.id
               and a.currency = p_currency and a.status = 'proposed') then
    raise exception 'payout account: a proposal already waits for confirmation' using errcode = 'check_violation';
  end if;
  insert into public.client_payout_account (organization_id, client_organization_id, currency, iban, bic, holder_name,
                                            evidence_document_id, kind, proposed_by)
  values (c.servicer_organization_id, c.id, p_currency, v_iban, v_bic, v_holder, p_evidence_document_id, p_kind,
          auth.uid())
  returning id into v_id;
  v_result := jsonb_build_object('payout_account_id', v_id, 'status', 'proposed');
  perform private.command_record('propose_payout_account', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Confirmer l'IBAN » (founder #10): the client's administrator (whole client) at aal2, in the client space, or an
-- admin of the servicer who did not propose it, at aal2. The IBAN typed from the RIB must be the one proposed (compare
-- and set). The current account of that client and currency, if any, is retired: the new one replaces it.
create or replace function public.confirm_payout_account(p_idempotency_key text, p_payout_account_id uuid,
                                                         p_iban_typed text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  a public.client_payout_account;
  v_via text;
  v_request jsonb := jsonb_build_object('payout_account_id', p_payout_account_id,
                                        'iban', private.rf_normalise(coalesce(p_iban_typed, '')));
  v_result jsonb;
begin
  select * into a from public.client_payout_account where id = p_payout_account_id;
  if a.id is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if a.client_organization_id = any (private.client_admin_whole_org_ids()) and private.is_aal2() then
    v_via := 'client_portal';
  elsif private.has_role(a.organization_id, array['admin']) then
    v_via := 'second_admin';
  else
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('confirm_payout_account', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  perform pg_advisory_xact_lock(hashtext('payout_accounts:' || a.organization_id::text));
  select * into a from public.client_payout_account where id = p_payout_account_id for update;
  if a.status <> 'proposed' then
    raise exception 'payout account: no longer waiting for confirmation' using errcode = 'check_violation';
  end if;
  if a.proposed_by = auth.uid() then
    raise exception 'payout account: the person who proposed it cannot confirm it (a second person confirms)'
      using errcode = 'check_violation';
  end if;
  if private.rf_normalise(coalesce(p_iban_typed, '')) <> a.iban then
    raise exception 'payout account: the IBAN typed is not the one proposed' using errcode = 'check_violation';
  end if;
  update public.client_payout_account
  set status = 'retired', closed_by = auth.uid(), closed_at = now(), closed_reason = 'Remplacé par ' || a.iban
  where client_organization_id = a.client_organization_id and currency = a.currency
    and status in ('active', 'returned');
  update public.client_payout_account
  set status = 'active', confirmed_by = auth.uid(), confirmed_at = now(), confirmed_via = v_via
  where id = a.id and status = 'proposed';
  v_result := jsonb_build_object('payout_account_id', a.id, 'status', 'active', 'confirmed_via', v_via);
  perform private.command_record('confirm_payout_account', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Refuser » a proposal: money staff of the servicer, or the client's administrator at aal2. A reason is required.
create or replace function public.reject_payout_account(p_idempotency_key text, p_payout_account_id uuid,
                                                        p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  a public.client_payout_account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('payout_account_id', p_payout_account_id, 'reason', btrim(coalesce(p_reason, '')));
  v_result jsonb;
begin
  select * into a from public.client_payout_account where id = p_payout_account_id for update;
  if a.id is null or not (private.has_role(a.organization_id, array['admin', 'ops_manager'])
                          or (a.client_organization_id = any (private.client_admin_whole_org_ids())
                              and private.is_aal2())) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('reject_payout_account', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if a.status <> 'proposed' then
    raise exception 'payout account: no longer waiting for confirmation' using errcode = 'check_violation';
  end if;
  update public.client_payout_account
  set status = 'rejected', closed_by = auth.uid(), closed_at = now(), closed_reason = v_reason
  where id = a.id and status = 'proposed';
  v_result := jsonb_build_object('payout_account_id', a.id, 'status', 'rejected');
  perform private.command_record('reject_payout_account', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Retirer » the current account (admin at aal2, with a reason): payouts wait for a new confirmed account.
create or replace function public.retire_payout_account(p_idempotency_key text, p_payout_account_id uuid,
                                                        p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  a public.client_payout_account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('payout_account_id', p_payout_account_id, 'reason', btrim(coalesce(p_reason, '')));
  v_result jsonb;
begin
  select * into a from public.client_payout_account where id = p_payout_account_id for update;
  if a.id is null or not private.has_role(a.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('retire_payout_account', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if a.status not in ('active', 'returned') then
    raise exception 'payout account: not the current account' using errcode = 'check_violation';
  end if;
  update public.client_payout_account
  set status = 'retired', closed_by = auth.uid(), closed_at = now(), closed_reason = v_reason
  where id = a.id and status in ('active', 'returned');
  v_result := jsonb_build_object('payout_account_id', a.id, 'status', 'retired');
  perform private.command_record('retire_payout_account', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- The IBANs of the clients' payout accounts (redefined from 20261111090000, where it was empty): every IBAN a second
-- person confirmed (current, returned or retired: a credit from it is still the client's money), read as
-- `client_transfer_in` at import (design §12) — never a debtor payment by itself. A proposal is not yet the client's.
create or replace function private.registered_client_ibans(p_organization_id uuid)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct a.iban order by a.iban), '{}')
  from public.client_payout_account a
  where a.organization_id = p_organization_id and a.confirmed_at is not null;
$$;

------------------------------------------------------------------------------------------
-- Client status events (§6.1, §13 #9; C. civ. 2003, C. com. L622-7, L641-9): append-only, each with its evidence.
-- Their effects on runs and payouts come with M2c-4 / M2c-7 (OQ-41).
------------------------------------------------------------------------------------------

create table public.client_status_event (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  kind text not null check (kind in ('proceeding_opened', 'liquidation', 'death', 'guardianship', 'mandate_ended')),
  effective_date date not null,
  evidence_document_id uuid not null references public.document (id),
  payout_account_id uuid references public.client_payout_account (id),   -- liquidation: the liquidator's account
  note text check (length(btrim(note)) between 1 and 2000),
  recorded_by uuid not null references public.app_user (id),
  recorded_at timestamptz not null default now()
);
create index client_status_event_client_idx on public.client_status_event (client_organization_id, effective_date);
comment on table public.client_status_event is
  'Events ending or restricting a client''s mandate (proceeding, liquidation, death, guardianship, end), with evidence.';

create or replace function private.client_status_event_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.organization c where c.id = new.client_organization_id
                   and c.servicer_organization_id = new.organization_id)
     or not private.client_document_of(new.evidence_document_id, new.client_organization_id, 'client_status_evidence')
     or (new.payout_account_id is not null and not exists (
           select 1 from public.client_payout_account a where a.id = new.payout_account_id
             and a.client_organization_id = new.client_organization_id and a.kind = 'court_appointed')) then
    raise exception 'client event: a client of the servicer, its evidence, and only a court-appointed payout account'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger client_status_event_guard before insert on public.client_status_event
  for each row execute function private.client_status_event_guard();
alter table public.client_status_event enable always trigger client_status_event_guard;
create trigger client_status_event_append_only before update or delete or truncate on public.client_status_event
  for each statement execute function private.refuse_change();
alter table public.client_status_event enable always trigger client_status_event_append_only;
create trigger client_status_event_change_log after insert or update or delete on public.client_status_event
  for each row execute function private.log_change();

-- « Enregistrer un événement » (admin at aal2): kind, date, evidence; for a liquidation the liquidator's payout account
-- may be named (it goes through the same dual control).
create or replace function public.record_client_status_event(p_idempotency_key text, p_client_organization_id uuid,
                                                             p_kind text, p_effective_date date,
                                                             p_evidence_document_id uuid, p_note text,
                                                             p_payout_account_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.organization;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_request jsonb := jsonb_build_object('client_organization_id', p_client_organization_id, 'kind', p_kind,
                                        'effective_date', p_effective_date,
                                        'evidence_document_id', p_evidence_document_id,
                                        'note', nullif(btrim(coalesce(p_note, '')), ''),
                                        'payout_account_id', p_payout_account_id);
  v_result jsonb;
  v_id uuid;
begin
  select * into c from public.organization where id = p_client_organization_id;
  if c.id is null or c.servicer_organization_id is null
     or not private.has_role(c.servicer_organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('record_client_status_event', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_kind is null or p_kind not in ('proceeding_opened', 'liquidation', 'death', 'guardianship', 'mandate_ended') then
    raise exception 'client event: invalid kind' using errcode = 'check_violation';
  end if;
  if p_effective_date is null or p_effective_date > private.paris_today() then
    raise exception 'client event: the date cannot be in the future' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, c.id, 'client_status_evidence') then
    raise exception 'client event: the evidence is required' using errcode = 'check_violation';
  end if;
  if length(v_note) > 2000 then
    raise exception 'client event: the note is too long' using errcode = 'check_violation';
  end if;
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, payout_account_id, note, recorded_by)
  values (c.servicer_organization_id, c.id, p_kind, p_effective_date, p_evidence_document_id, p_payout_account_id,
          v_note, auth.uid())
  returning id into v_id;
  v_result := jsonb_build_object('client_status_event_id', v_id);
  perform private.command_record('record_client_status_event', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- Money terms of a mandate (§8.1, §8.2, §8.5; R124-3 2°–4°). Validators: the SQL twin of
-- collectoo_worker.remittance.terms (pydantic), same answer on every case of the parity test (5,000 generated
-- schedules and terms, valid and invalid). Each returns the first error (a code) or null. The clause references are
-- columns of the version (commission_clause_ref, remittance_clause_ref), not repeated inside the documents; the
-- netting and claw-back clauses are named inside the remittance terms. Amounts and rates are strings (M1e rule).
------------------------------------------------------------------------------------------

-- An object whose keys are among `p_allowed` and include `p_required`.
create or replace function private.json_object_keys_ok(p jsonb, p_allowed text[], p_required text[])
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'object'
    and not exists (select 1 from jsonb_object_keys(p) k where k <> all (p_allowed))
    and not exists (select 1 from unnest(p_required) r where not (p ? r)), false);
$$;

-- A non-blank string of at most p_max characters (blank: only spaces, tabs and line breaks).
create or replace function private.json_text_ok(p jsonb, p_max integer)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'string' and length(p #>> '{}') between 1 and p_max
                  and translate(p #>> '{}', E' \t\n\r', '') <> '', false);
$$;

-- A rate: a decimal string 0 ≤ r ≤ 1 with at most 4 decimals ("0.15", "1", "0.0600").
create or replace function private.json_rate_ok(p jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'string' and (p #>> '{}') ~ '^(0(\.[0-9]{1,4})?|1(\.0{1,4})?)$', false);
$$;

-- A non-negative integer string of at most 15 digits, no leading zero ("0", "500000").
create or replace function private.json_minor_ok(p jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'string' and (p #>> '{}') ~ '^(0|[1-9][0-9]{0,14})$', false);
$$;

-- A JSON integer (not a boolean, not a decimal) between the bounds.
create or replace function private.json_int_between(p jsonb, p_min integer, p_max integer)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'number' and (p::text) ~ '^-?[0-9]{1,9}$'
                  and (p::text)::integer between p_min and p_max, false);
$$;

-- An array of 1..p_max distinct strings, each matching p_pattern or among p_values.
create or replace function private.json_string_set_ok(p jsonb, p_max integer, p_pattern text, p_values text[])
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'array' and jsonb_array_length(p) between 1 and p_max
    and not exists (select 1 from jsonb_array_elements(p) e
                    where jsonb_typeof(e) <> 'string'
                       or (p_pattern is not null and (e #>> '{}') !~ p_pattern)
                       or (p_values is not null and (e #>> '{}') <> all (p_values)))
    and (select count(distinct e #>> '{}') from jsonb_array_elements(p) e) = jsonb_array_length(p), false);
$$;

-- Tiers or brackets: 1..20 objects {<bound key>: string > 0 | null, rate}, bounds strictly increasing, only the last
-- unbounded (null).
create or replace function private.json_bands_ok(p jsonb, p_bound text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'array' and jsonb_array_length(p) between 1 and 20
    and not exists (
      select 1 from jsonb_array_elements(p) with ordinality e (v, n)
      where not private.json_object_keys_ok(e.v, array[p_bound, 'rate'], array[p_bound, 'rate'])
         or not private.json_rate_ok(e.v -> 'rate')
         or (e.n < jsonb_array_length(p) and not (private.json_minor_ok(e.v -> p_bound) and (e.v ->> p_bound) <> '0'))
         or (e.n = jsonb_array_length(p) and jsonb_typeof(e.v -> p_bound) <> 'null'))
    and not exists (
      select 1 from jsonb_array_elements(p) with ordinality a (v, n)
      join jsonb_array_elements(p) with ordinality b (v, n) on b.n = a.n + 1
      where b.n < jsonb_array_length(p) and (b.v ->> p_bound)::numeric <= (a.v ->> p_bound)::numeric), false);
$$;

-- The rate of a rule: flat {kind, rate}; marginal {kind, tiers [{up_to_minor, rate}]} (tiers on what the file brought
-- in under the rule's tier key); bracket {kind, attribute, brackets [{up_to, rate}]} (one rate chosen by a file
-- attribute fixed at boarding). Whole-rate tiers on cumulative collections are not a kind: refused (§8.1).
create or replace function private.commission_rate_ok(p jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(case p ->> 'kind'
    when 'flat' then jsonb_typeof(p -> 'kind') = 'string'
                     and private.json_object_keys_ok(p, array['kind', 'rate'], array['kind', 'rate'])
                     and private.json_rate_ok(p -> 'rate')
    when 'marginal' then jsonb_typeof(p -> 'kind') = 'string'
                     and private.json_object_keys_ok(p, array['kind', 'tiers'], array['kind', 'tiers'])
                     and private.json_bands_ok(p -> 'tiers', 'up_to_minor')
    when 'bracket' then jsonb_typeof(p -> 'kind') = 'string'
                     and private.json_object_keys_ok(p, array['kind', 'attribute', 'brackets'],
                                                     array['kind', 'attribute', 'brackets'])
                     and jsonb_typeof(p -> 'attribute') = 'string'
                     and (p ->> 'attribute') in ('boarded_amount', 'age_days_at_boarding')
                     and private.json_bands_ok(p -> 'brackets', 'up_to')
    else false end, false);
$$;

-- `commission-1` (§8.1): the first error, or null when the schedule is valid.
create or replace function private.commission_schedule_error(p jsonb)
returns text
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  v_families constant text[] := array['principal', 'interest', 'indemnity', 'charge', 'cost', 'unclassified'];
  v_id constant text := '^[a-z0-9][a-z0-9_-]{0,39}$';
  r jsonb;
  n integer;
begin
  if not private.json_object_keys_ok(p, array['schema', 'basis', 'rules'], array['schema', 'basis', 'rules']) then
    return 'keys';
  end if;
  if jsonb_typeof(p -> 'schema') <> 'string' or p ->> 'schema' <> 'commission-1' then
    return 'schema';
  end if;
  if not private.json_object_keys_ok(p -> 'basis', array['families', 'forwards', 'on_reversal'],
                                     array['families', 'forwards', 'on_reversal']) then
    return 'basis';
  end if;
  if not (p #> '{basis,families}' = '"all"'::jsonb
          or private.json_string_set_ok(p #> '{basis,families}', 6, null, v_families)) then
    return 'basis.families';
  end if;
  if not private.json_object_keys_ok(p #> '{basis,forwards}',
                                     array['file_recalled', 'before_servicing_start', 'client_ratification'],
                                     array['file_recalled', 'before_servicing_start', 'client_ratification'])
     or exists (select 1 from jsonb_each(p #> '{basis,forwards}') f where jsonb_typeof(f.value) <> 'boolean') then
    return 'basis.forwards';
  end if;
  if jsonb_typeof(p #> '{basis,on_reversal}') <> 'string' or p #>> '{basis,on_reversal}' not in ('credit', 'keep') then
    return 'basis.on_reversal';
  end if;
  if jsonb_typeof(p -> 'rules') <> 'array' or jsonb_array_length(p -> 'rules') not between 1 and 50 then
    return 'rules';
  end if;
  n := jsonb_array_length(p -> 'rules');
  for r in select e from jsonb_array_elements(p -> 'rules') e loop
    if not private.json_object_keys_ok(r, array['id', 'tier_key', 'label_fr', 'match', 'rate', 'min_per_file_minor'],
                                       array['id', 'tier_key', 'label_fr', 'match', 'rate']) then
      return 'rule.keys';
    end if;
    if jsonb_typeof(r -> 'id') <> 'string' or r ->> 'id' !~ v_id then
      return 'rule.id';
    end if;
    if jsonb_typeof(r -> 'tier_key') <> 'string' or r ->> 'tier_key' !~ v_id then
      return 'rule.tier_key';
    end if;
    if not private.json_text_ok(r -> 'label_fr', 200) then
      return 'rule.label_fr';
    end if;
    if not private.json_object_keys_ok(r -> 'match', array['claim_types', 'families', 'portfolio_ids'], '{}')
       or (r -> 'match' ? 'claim_types'
           and not private.json_string_set_ok(r #> '{match,claim_types}', 20, '^[a-z][a-z0-9_]{0,39}$', null))
       or (r -> 'match' ? 'families' and not private.json_string_set_ok(r #> '{match,families}', 6, null, v_families))
       or (r -> 'match' ? 'portfolio_ids'
           and not private.json_string_set_ok(r #> '{match,portfolio_ids}', 50,
                                              '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', null)) then
      return 'rule.match';
    end if;
    if not private.commission_rate_ok(r -> 'rate') then
      return 'rule.rate';
    end if;
    if r ? 'min_per_file_minor' and not private.json_minor_ok(r -> 'min_per_file_minor') then
      return 'rule.min_per_file_minor';
    end if;
  end loop;
  if (select count(distinct e ->> 'id') from jsonb_array_elements(p -> 'rules') e) <> n then
    return 'rules.duplicate_id';
  end if;
  if (select count(distinct e ->> 'tier_key') from jsonb_array_elements(p -> 'rules') e) <> n then
    return 'rules.duplicate_tier_key';
  end if;
  if p #> array['rules', (n - 1)::text, 'match'] <> '{}'::jsonb then  -- the last rule must match everything
    return 'rules.last_not_catch_all';
  end if;
  return null;
end;
$$;

create or replace function private.commission_schedule_valid(p jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select private.commission_schedule_error(p) is null;
$$;

-- `remittance-1` (§8.2): the first error, or null.
create or replace function private.remittance_terms_error(p jsonb)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case
    when not private.json_object_keys_ok(p, array['schema', 'frequency', 'weekday', 'netting', 'clawback',
                                                  'invoice_payment_days', 'holdback'],
                                         array['schema', 'frequency', 'netting', 'clawback', 'invoice_payment_days'])
      then 'keys'
    when jsonb_typeof(p -> 'schema') <> 'string' or p ->> 'schema' <> 'remittance-1' then 'schema'
    when jsonb_typeof(p -> 'frequency') <> 'string' or p ->> 'frequency' not in ('twice_monthly', 'weekly')
      then 'frequency'
    when (p ->> 'frequency' = 'weekly') <> (p ? 'weekday')
         or (p ? 'weekday' and not private.json_int_between(p -> 'weekday', 1, 5)) then 'weekday'
    when not (jsonb_typeof(p -> 'netting') = 'null'
              or (private.json_object_keys_ok(p -> 'netting', array['clause_ref'], array['clause_ref'])
                  and private.json_text_ok(p #> '{netting,clause_ref}', 200))) then 'netting'
    when not (jsonb_typeof(p -> 'clawback') = 'null'
              or (private.json_object_keys_ok(p -> 'clawback', array['clause_ref'], array['clause_ref'])
                  and private.json_text_ok(p #> '{clawback,clause_ref}', 200))) then 'clawback'
    -- due invoices: at most 45 days after issue (L441-10 I, periodic invoices)
    when not private.json_int_between(p -> 'invoice_payment_days', 0, 45) then 'invoice_payment_days'
    -- reserved for hold-backs (M5; « sauf convention contraire », R124-6): empty until then
    when p ? 'holdback' and p -> 'holdback' <> '[]'::jsonb then 'holdback'
  end;
$$;

create or replace function private.remittance_terms_valid(p jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select private.remittance_terms_error(p) is null;
$$;

-- The schedule the back-fill gives a version of before M2c-2: one flat rule at its commission_rate on everything
-- allocated (no forward, credit on reversal: founder #4, #6). Without clause references the version is incomplete.
create or replace function private.legacy_commission_schedule(p_rate numeric)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'schema', 'commission-1',
    'basis', jsonb_build_object('families', 'all',
                                'forwards', jsonb_build_object('file_recalled', false, 'before_servicing_start', false,
                                                               'client_ratification', false),
                                'on_reversal', 'credit'),
    'rules', jsonb_build_array(jsonb_build_object(
      'id', 'taux-unique', 'tier_key', 'taux-unique', 'label_fr', 'Taux unique (repris de l''ancien taux de commission)',
      'match', '{}'::jsonb,
      'rate', jsonb_build_object('kind', 'flat', 'rate', trim_scale(p_rate)::text))));
$$;

------------------------------------------------------------------------------------------
-- mandate / mandate_terms columns (§6.1)
------------------------------------------------------------------------------------------

alter table public.mandate add column insurance_clause_ref text
  check (length(btrim(insurance_clause_ref)) between 1 and 200);                     -- R124-3 2°
comment on column public.mandate.insurance_clause_ref is
  'Clause of the convention on the guarantee (CPCE R124-3 2°).';

alter table public.mandate_terms
  add column commission_schedule jsonb
    check (commission_schedule is null or private.commission_schedule_valid(commission_schedule)),
  add column commission_clause_ref text check (length(btrim(commission_clause_ref)) between 1 and 200),   -- 3°
  add column remittance_terms jsonb
    check (remittance_terms is null or private.remittance_terms_valid(remittance_terms)),
  add column remittance_clause_ref text check (length(btrim(remittance_clause_ref)) between 1 and 200),   -- 4°
  add column document_id uuid references public.document (id),
  add column schedule_sha256 text check (schedule_sha256 ~ '^[0-9a-f]{64}$'),
  add column created_by uuid references public.app_user (id),
  alter column commission_rate drop not null;
comment on column public.mandate_terms.commission_rate is
  'Superseded by commission_schedule (M2c-2): kept for the versions written before it.';
comment on column public.mandate_terms.commission_schedule is
  'Commission schedule (commission-1, R124-3 3°; design §8.1), with commission_clause_ref.';
comment on column public.mandate_terms.remittance_terms is
  'Remittance terms (remittance-1, R124-3 4°; design §8.2), with remittance_clause_ref; the delay is remittance_max_days.';
comment on column public.mandate_terms.schedule_sha256 is
  'SHA-256 of the commission schedule and remittance terms (jsonb text): what a run''s inputs hash names (M2c-4).';

-- A mandate with versions is never deleted (§6.1): the versions are its history.
alter table public.mandate_terms drop constraint mandate_terms_mandate_id_fkey,
  add constraint mandate_terms_mandate_id_fkey foreign key (mandate_id) references public.mandate (id) on delete restrict;

-- One-off back-fill (documented, ADR-0014 M2c-2): the versions written before M2c-2 get one flat rule at their rate;
-- their clause references stay empty, so the mandate reads « incomplete » until set_mandate_terms gives it terms.
update public.mandate_terms set commission_schedule = private.legacy_commission_schedule(commission_rate)
where commission_schedule is null and commission_rate is not null;

create or replace function private.terms_sha256(p_schedule jsonb, p_terms jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_schedule is not null or p_terms is not null then
    encode(sha256(convert_to(jsonb_build_object('commission_schedule', p_schedule,
                                                'remittance_terms', p_terms)::text, 'UTF8')), 'hex') end;
$$;

create or replace function private.mandate_terms_hash()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.schedule_sha256 := private.terms_sha256(new.commission_schedule, new.remittance_terms);
  return new;
end;
$$;
create trigger mandate_terms_hash before insert or update on public.mandate_terms
  for each row execute function private.mandate_terms_hash();
alter table public.mandate_terms enable always trigger mandate_terms_hash;
update public.mandate_terms set schedule_sha256 = private.terms_sha256(commission_schedule, remittance_terms);

-- A version is immutable once in force (valid_from ≤ Paris today): only its end may move, from a date not yet passed
-- to another not in the past (ending it, or extending it); never deleted. A version not yet in force may be changed
-- or deleted (it is superseded before it applies). A new version of a mandate that already has one never starts
-- before today (never retroactive, §8.1); a mandate's first version may start at its signature. After the row checks
-- (the exclusion constraint answers an overlap first). A remittance line references only versions in force (M2c-4).
create or replace function private.mandate_terms_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_today date := private.paris_today();
begin
  if tg_op = 'INSERT' then
    if new.valid_from < v_today
       and exists (select 1 from public.mandate_terms t where t.mandate_id = new.mandate_id and t.id <> new.id) then
      raise exception 'mandate terms: a new version never starts before today (%)', v_today
        using errcode = 'check_violation';
    end if;
    return null;
  end if;
  if tg_op = 'DELETE' then
    if old.valid_from <= v_today then
      raise exception 'mandate terms %: a version in force is never deleted', old.id using errcode = 'check_violation';
    end if;
    return null;
  end if;
  if old.valid_from <= v_today then
    if (new.id, new.mandate_id, new.valid_from, new.commission_rate, new.remittance_max_days, new.plan_envelope,
        new.settlement_authority, new.terms, new.created_at, new.commission_schedule, new.commission_clause_ref,
        new.remittance_terms, new.remittance_clause_ref, new.document_id, new.created_by)
       is distinct from
       (old.id, old.mandate_id, old.valid_from, old.commission_rate, old.remittance_max_days, old.plan_envelope,
        old.settlement_authority, old.terms, old.created_at, old.commission_schedule, old.commission_clause_ref,
        old.remittance_terms, old.remittance_clause_ref, old.document_id, old.created_by)
       or (new.valid_to is distinct from old.valid_to
           and ((old.valid_to is not null and old.valid_to < v_today)
                or (new.valid_to is not null and new.valid_to < v_today))) then
      raise exception 'mandate terms %: a version in force is immutable (only its end may move, never into the past)',
        old.id using errcode = 'check_violation';
    end if;
  elsif new.valid_from < v_today then
    raise exception 'mandate terms: a new version never starts before today (%)', v_today
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger mandate_terms_guard after insert or update or delete on public.mandate_terms
  for each row execute function private.mandate_terms_guard();
alter table public.mandate_terms enable always trigger mandate_terms_guard;
create trigger mandate_terms_no_truncate before truncate on public.mandate_terms
  for each statement execute function private.refuse_delete();
alter table public.mandate_terms enable always trigger mandate_terms_no_truncate;

-- « Nouvelles conditions financières » (admin at aal2): a version from p_valid_from (≥ Paris today) with its schedule,
-- terms, clause references and the signed document (a mandate document of the client). The version covering that
-- day ends then; versions not yet in force that would start on or after it are superseded (deleted: they never
-- applied); the new one keeps the mandate's end (the last version's, when later than its start) and the covering
-- version's other settings
-- (payment plans, settlement authority). Claim types named by the schedule must exist; portfolios it names must be
-- the mandate's.
create or replace function public.set_mandate_terms(p_idempotency_key text, p_mandate_id uuid, p_valid_from date,
                                                    p_commission_schedule jsonb, p_commission_clause_ref text,
                                                    p_remittance_terms jsonb, p_remittance_clause_ref text,
                                                    p_document_id uuid, p_remittance_max_days integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  m public.mandate;
  cov public.mandate_terms;
  v_today date := private.paris_today();
  v_commission_ref text := btrim(coalesce(p_commission_clause_ref, ''));
  v_remittance_ref text := btrim(coalesce(p_remittance_clause_ref, ''));
  v_request jsonb := jsonb_build_object('mandate_id', p_mandate_id, 'valid_from', p_valid_from,
                                        'commission_schedule', p_commission_schedule,
                                        'commission_clause_ref', btrim(coalesce(p_commission_clause_ref, '')),
                                        'remittance_terms', p_remittance_terms,
                                        'remittance_clause_ref', btrim(coalesce(p_remittance_clause_ref, '')),
                                        'document_id', p_document_id, 'remittance_max_days', p_remittance_max_days);
  v_result jsonb;
  v_error text;
  v_superseded integer;
  v_end date;
  v_id uuid;
begin
  select * into m from public.mandate where id = p_mandate_id for update;
  if m.id is null or not private.has_role(m.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('set_mandate_terms', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_valid_from is null or p_valid_from < v_today then
    raise exception 'mandate terms: a new version never starts before today (%)', v_today
      using errcode = 'check_violation';
  end if;
  v_error := private.commission_schedule_error(p_commission_schedule);
  if v_error is not null then
    raise exception 'mandate terms: invalid commission schedule (%)', v_error using errcode = 'check_violation';
  end if;
  v_error := private.remittance_terms_error(p_remittance_terms);
  if v_error is not null then
    raise exception 'mandate terms: invalid remittance terms (%)', v_error using errcode = 'check_violation';
  end if;
  if v_commission_ref = '' or length(v_commission_ref) > 200 or v_remittance_ref = '' or length(v_remittance_ref) > 200
  then
    raise exception 'mandate terms: the clause references are required (R124-3 3° and 4°)'
      using errcode = 'check_violation';
  end if;
  if p_remittance_max_days is null or p_remittance_max_days not between 1 and 30 then
    raise exception 'mandate terms: the remittance delay is 1 to 30 days (R124-6)' using errcode = 'check_violation';
  end if;
  if p_document_id is null or not private.client_document_of(p_document_id, m.client_organization_id,
                                                             'mandate_document') then
    raise exception 'mandate terms: the signed document is required' using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(p_commission_schedule -> 'rules') r
             cross join lateral jsonb_array_elements_text(coalesce(r #> '{match,claim_types}', '[]')) c
             where not exists (select 1 from public.claim_type t where t.code = c)) then
    raise exception 'mandate terms: unknown claim type' using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(p_commission_schedule -> 'rules') r
             cross join lateral jsonb_array_elements_text(coalesce(r #> '{match,portfolio_ids}', '[]')) x
             where not exists (select 1 from public.portfolio p where p.id = x::uuid and p.mandate_id = m.id)) then
    raise exception 'mandate terms: a portfolio of another mandate' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.mandate_terms t where t.mandate_id = m.id and t.valid_from >= p_valid_from
               and t.valid_from <= v_today) then
    raise exception 'mandate terms: a version in force already starts that day' using errcode = 'check_violation';
  end if;
  -- the mandate's end (the last version's; null: open), and the version covering the day, before the later ones go
  select t.valid_to into v_end from public.mandate_terms t where t.mandate_id = m.id
  order by t.valid_from desc limit 1;
  select * into cov from public.mandate_terms t
  where t.mandate_id = m.id and t.valid_from < p_valid_from and (t.valid_to is null or t.valid_to > p_valid_from)
  for update;
  delete from public.mandate_terms t where t.mandate_id = m.id and t.valid_from >= p_valid_from;
  get diagnostics v_superseded = row_count;
  if cov.id is not null then
    update public.mandate_terms set valid_to = p_valid_from where id = cov.id;
  end if;
  insert into public.mandate_terms (mandate_id, valid_from, valid_to, remittance_max_days, plan_envelope,
                                    settlement_authority, terms, commission_schedule, commission_clause_ref,
                                    remittance_terms, remittance_clause_ref, document_id, created_by)
  values (m.id, p_valid_from, case when v_end > p_valid_from then v_end end, p_remittance_max_days, coalesce(cov.plan_envelope, '{}'),
          coalesce(cov.settlement_authority, '{}'), coalesce(cov.terms, '{}'), p_commission_schedule, v_commission_ref,
          p_remittance_terms, v_remittance_ref, p_document_id, auth.uid())
  returning id into v_id;
  v_result := jsonb_build_object('mandate_terms_id', v_id, 'valid_from', p_valid_from,
                                 'ended_version_id', cov.id, 'superseded', v_superseded);
  perform private.command_record('set_mandate_terms', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Clause de garantie » (R124-3 2°; admin at aal2): the clause reference of the mandate, compare and set on the value
-- the page showed.
create or replace function public.set_mandate_insurance_clause(p_idempotency_key text, p_mandate_id uuid,
                                                               p_clause_ref text, p_expected text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  m public.mandate;
  v_ref text := btrim(coalesce(p_clause_ref, ''));
  v_request jsonb := jsonb_build_object('mandate_id', p_mandate_id, 'clause_ref', btrim(coalesce(p_clause_ref, '')),
                                        'expected', p_expected);
  v_result jsonb;
begin
  select * into m from public.mandate where id = p_mandate_id for update;
  if m.id is null or not private.has_role(m.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('set_mandate_insurance_clause', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_ref = '' or length(v_ref) > 200 then
    raise exception 'mandate: the clause reference is required (200 characters at most)'
      using errcode = 'check_violation';
  end if;
  if m.insurance_clause_ref is distinct from nullif(btrim(coalesce(p_expected, '')), '') then
    raise exception 'mandate changed since it was read' using errcode = 'serialization_failure';
  end if;
  update public.mandate set insurance_clause_ref = v_ref where id = m.id;
  v_result := jsonb_build_object('mandate_id', m.id, 'insurance_clause_ref', v_ref);
  perform private.command_record('set_mandate_insurance_clause', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The confirmation gate (§9.1; ops critique #3, compliance critique B8): a portfolio enters servicing only when what
-- remitting and invoicing need is in place, so a paperwork gap never becomes a late remittance (R124-6). Reasons, in
-- the order the page lists them:
--   no_active_mandate (R124-3), insurance_clause_missing (2°), commission_schedule_missing, commission_clause_missing
--   (3°), remittance_terms_missing, remittance_clause_missing (4°), terms_document_missing (the signed convention),
--   servicer_identity_incomplete (R123-237/238, 242 nonies A 1°–2°), client_identity_incomplete (SIREN, registered
--   office), client_not_professional, client_not_mainland_france (founder #13, OQ-42), currency_not_eur (the batch's
--   accounts; founder #13).
------------------------------------------------------------------------------------------

create or replace function private.portfolio_confirmation_blockers(p_portfolio_id uuid, p_on date)
returns text[]
language sql
stable
set search_path = ''
as $$
  select array_remove(array[
    case when mt.id is null then 'no_active_mandate' end,
    case when m.id is not null and m.insurance_clause_ref is null then 'insurance_clause_missing' end,
    case when mt.id is not null and mt.commission_schedule is null then 'commission_schedule_missing' end,
    case when mt.id is not null and mt.commission_clause_ref is null then 'commission_clause_missing' end,
    case when mt.id is not null and mt.remittance_terms is null then 'remittance_terms_missing' end,
    case when mt.id is not null and mt.remittance_clause_ref is null then 'remittance_clause_missing' end,
    case when mt.id is not null and mt.document_id is null then 'terms_document_missing' end,
    case when cardinality(private.billing_identity_gaps(p.organization_id)) > 0 then 'servicer_identity_incomplete' end,
    case when private.billing_identity_gaps(p.client_organization_id) && array['identity', 'siren']
         then 'client_identity_incomplete' end,
    case when 'professional' = any (private.billing_identity_gaps(p.client_organization_id))
         then 'client_not_professional' end,
    case when 'mainland_france' = any (private.billing_identity_gaps(p.client_organization_id))
         then 'client_not_mainland_france' end], null)
  from public.portfolio p
  left join public.mandate m on m.id = p.mandate_id
  left join lateral (select t.* from public.mandate_terms t
                     where t.mandate_id = m.id and t.valid_from <= p_on and (t.valid_to is null or t.valid_to > p_on)
                     limit 1) mt on true
  where p.id = p_portfolio_id;
$$;

create or replace function private.batch_confirmation_blockers(p_batch_id uuid)
returns text[]
language sql
stable
set search_path = ''
as $$
  select private.portfolio_confirmation_blockers(b.portfolio_id, private.paris_today())
         || case when exists (select 1 from public.account a where a.boarding_batch_id = b.id and a.currency <> 'EUR')
                 then array['currency_not_eur'] else '{}'::text[] end
  from public.boarding_batch b where b.id = p_batch_id;
$$;

-- What the batch page lists before « Confirmer » (staff of the batch's servicer).
create or replace function public.boarding_batch_readiness(p_batch_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
begin
  select * into v from public.boarding_batch where id = p_batch_id;
  if v.id is null or not (v.organization_id = any (private.staff_org_ids())) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return private.batch_confirmation_blockers(p_batch_id);
end;
$$;

-- What a client's page lists per portfolio (staff of the servicer).
create or replace function public.client_readiness(p_client_organization_id uuid)
returns table (portfolio_id uuid, portfolio_name text, blockers text[])
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.organization o where o.id = p_client_organization_id
                   and o.servicer_organization_id = any (private.staff_org_ids())) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query
  select p.id, p.name, private.portfolio_confirmation_blockers(p.id, private.paris_today())
  from public.portfolio p where p.client_organization_id = p_client_organization_id
  order by p.name, p.id;
end;
$$;

-- Confirmation request (redefined from 20261108180000): the gate above, after the M2a checks.
create or replace function public.confirm_boarding_batch(p_batch_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
  v_blockers text[];
begin
  select * into v from public.boarding_batch where id = p_batch_id for update;
  if not found or not private.has_role(v.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if v.status <> 'committed' then
    raise exception 'batch is %, expected committed', v.status using errcode = 'check_violation';
  end if;
  if v.opening_plan is null then  -- committed before openings existed: it cannot be posted
    raise exception 'ledger: batch % was committed without an opening plan; roll it back and board the file again',
      p_batch_id using errcode = 'LG005';
  end if;
  if not private.has_active_mandate(v.portfolio_id, private.paris_today()) then
    raise exception 'no active client mandate covers this portfolio (CPCE R124-3)'
      using errcode = 'check_violation';
  end if;
  v_blockers := private.batch_confirmation_blockers(p_batch_id);
  if cardinality(v_blockers) > 0 then
    raise exception 'the portfolio is not ready for confirmation: %', array_to_string(v_blockers, ', ')
      using errcode = 'check_violation', hint = array_to_string(v_blockers, ',');
  end if;
  -- A new request clears the previous confirmation failure only (a documents failure stays shown).
  update public.boarding_batch
  set confirm_requested_by = auth.uid(), confirm_requested_at = now(),
      failed_job = case when failed_job ->> 'type' = 'confirm' then null else failed_job end
  where id = p_batch_id;
  perform private.transition_batch(p_batch_id, 'confirming', 'confirmation requested');
end;
$$;

-- The worker's confirmation job (redefined from 20261109150000): the gate again (the terms or an identity may have
-- changed since the request): not ready → back to committed with the reasons, nothing posted.
create or replace function private.complete_batch_confirmation(p_batch_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
  v_blockers text[];
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
  v_blockers := private.batch_confirmation_blockers(p_batch_id);
  if cardinality(v_blockers) > 0 then
    update public.boarding_batch
    set failed_job = jsonb_build_object('type', 'confirm', 'error', 'not_ready', 'blockers', to_jsonb(v_blockers),
                                        'at', now())
    where id = p_batch_id and coalesce(failed_job ->> 'type', '') not in ('documents', 'purge_documents');
    perform private.transition_batch(p_batch_id, 'committed',
                                     'conditions de confirmation incomplètes : ' || array_to_string(v_blockers, ', '),
                                     'worker:boarding');
    return 'not_ready';
  end if;
  perform private.post_opening_balances(p_batch_id);
  update public.account set status = 'awaiting_first_letter'
  where boarding_batch_id = p_batch_id and status = 'staged';
  perform private.issue_payment_references(p_batch_id);  -- M2-06: one RF reference per workable account
  -- M2-08: payments left to ops (waiting for these files, or unmatched) are matched again (founder #11).
  perform pgmq.send('payments', jsonb_build_object('type', 'match', 'organization_id', v.organization_id,
                                                   'trigger', 'rematch', 'batch_id', p_batch_id));
  perform private.transition_batch(p_batch_id, 'confirmed', 'confirmed', 'worker:boarding');
  return 'confirmed';
end;
$$;

------------------------------------------------------------------------------------------
-- Receipts: the issuer block (C. com. R123-237 1°–4°, 9°; R123-238; founder 2026-11-09), template quittance-fr-3.
-- Every new version carries the servicer's block as it is when the version is issued; a version is issued only when
-- what the receipt says about the payment changes (the block is not compared), so the stored receipts are not
-- re-issued and keep their bytes. A servicer without an identity (none in production) prints its name only.
------------------------------------------------------------------------------------------

create or replace function private.receipt_issuer(p_organization_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('name', o.legal_name)
         || case when b.organization_id is null then '{}'::jsonb else jsonb_build_object(
              'siren', o.siren,
              'legal_form', private.legal_form_mention(b.legal_form),
              'share_capital_minor', b.share_capital_minor::text,
              'currency', 'EUR',
              'rcs_city', b.rcs_city,
              'registered_office', b.registered_office,
              'in_liquidation', b.in_liquidation,
              'entrepreneur_individuel', b.entrepreneur_individuel) end
  from public.organization o
  left join public.billing_identity b on b.organization_id = o.id
  where o.id = p_organization_id;
$$;

-- Redefined from 20261110090000: the payload carries the issuer block; « the payload differs from the current
-- version's » now leaves the issuer out (a new block alone never issues a version). Same settings and grants.
create or replace function private.receipt_prepare(p_organization_id uuid, p_payment_ids uuid[])
returns table (payment_id uuid, number text, version integer, kind text, known_at timestamptz, storage_path text,
               payload jsonb)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_year integer := extract(year from (now() at time zone 'Europe/Paris'))::integer;
  v_new bigint;
  v_last bigint;
  v_issuer jsonb;
begin
  if p_organization_id is null then
    raise exception 'receipts: servicer required' using errcode = '22023';
  end if;
  v_issuer := jsonb_build_object('issuer', private.receipt_issuer(p_organization_id));
  insert into pg_temp._receipt_new (payment_id, organization_id, client_organization_id, portfolio_id, account_id,
                                    recipient_party_id, number, version, kind, payload, payload_sha256, known_at, ord)
  select y.payment_id, p_organization_id, y.client, y.portfolio, y.account, y.recipient, y.cur_number,
         coalesce(y.cur_version, 0) + 1,
         case when y.cur_version is null then 'original' when y.state = 'void' then 'void' else 'update' end,
         y.payload, y.sha, now(), row_number() over (order by y.booking_date, y.payment_id)
  from (select x.*, encode(sha256(convert_to(x.payload::text, 'UTF8')), 'hex') as sha
        from (select p.id as payment_id, p.booking_date, s.state, cur.version as cur_version, cur.number as cur_number,
                     cur.payload as cur_payload,
                     case when s.state = 'issued' then a.client_organization_id else cur.client_organization_id end
                       as client,
                     case when s.state = 'issued' then a.portfolio_id else cur.portfolio_id end as portfolio,
                     case when s.state = 'issued' then a.id else cur.account_id end as account,
                     case when s.state = 'issued' then b.recipient_party_id else cur.recipient_party_id end as recipient,
                     case when s.state = 'issued' then b.payload else private.receipt_void_payload(cur.payload) end
                       || v_issuer as payload
              from (select distinct u.id from unnest(p_payment_ids) u (id)) ids
              join public.payment p on p.id = ids.id and p.organization_id = p_organization_id
              left join public.account a on a.id = p.account_id
              left join lateral (select r.version, r.number, r.kind, r.payload, r.payload_sha256, r.account_id,
                                        r.client_organization_id, r.portfolio_id, r.recipient_party_id
                                 from public.receipt r where r.payment_id = p.id
                                 order by r.version desc limit 1) cur on true
              cross join lateral (
                select case
                  -- a version in force about another file than the payment's: void it first, whatever the payment's
                  -- state now (it left its file, came back from the bank, or was moved to another file before this
                  -- job ran: review #1)
                  when cur.kind is not null and cur.kind <> 'void'
                       and (p.account_id is null or p.status = 'returned' or cur.account_id is distinct from p.account_id)
                    then 'void'
                  when p.account_id is not null and p.status <> 'returned'
                       and not (p.status in ('matched', 'partially_allocated') and p.review_reason is null)
                    then 'issued'
                end as state) s
              left join lateral private.receipt_payload(p.id) b on s.state = 'issued'
              where s.state is not null) x) y
  where (y.payload - 'issuer') is distinct from (y.cur_payload - 'issuer');

  -- A payment voided on a file it left while it is already on another: queued again, so the next run issues its new
  -- file's version (one version per payment and run). Ready for allocation there, the next run skips it and its
  -- allocation queues it.
  perform private.queue_receipts(coalesce(jsonb_agg(jsonb_build_object('organization_id', p_organization_id,
                                                                       'payment_id', r.payment_id)), '[]'))
  from pg_temp._receipt_new r
  join public.payment p on p.id = r.payment_id
  where r.kind = 'void' and p.account_id is not null and p.status <> 'returned';

  select count(*) into v_new from pg_temp._receipt_new r where r.number is null;
  if v_new > 0 then
    insert into private.receipt_counter (organization_id, year, last_number) values (p_organization_id, v_year, 0)
    on conflict on constraint receipt_counter_pkey do nothing;
    update private.receipt_counter c set last_number = c.last_number + v_new
    where c.organization_id = p_organization_id and c.year = v_year
    returning c.last_number - v_new into v_last;
    update pg_temp._receipt_new r
    set number = 'Q-' || v_year || '-' || lpad((v_last + z.n)::text, greatest(6, length((v_last + z.n)::text)), '0')
    from (select q.payment_id, row_number() over (order by q.ord) as n from pg_temp._receipt_new q
          where q.number is null) z
    where r.payment_id = z.payment_id;
  end if;
  update pg_temp._receipt_new r
  set storage_path = 'receipts/' || r.organization_id || '/' || substr(r.number, 3, 4) || '/' || r.number || '-v'
                     || r.version || '.pdf';
  return query
  select r.payment_id, r.number, r.version, r.kind, r.known_at, r.storage_path, r.payload
  from pg_temp._receipt_new r order by r.ord;
end;
$$;

------------------------------------------------------------------------------------------
-- close_bank_account (redefined from 20261111090000): an own account named in the billing settings (where due invoices
-- are paid) is not closed; choose another first.
------------------------------------------------------------------------------------------

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
  if v.purpose = 'client_funds'
     and (select coalesce(sum(p.amount_minor), 0) from public.ledger_account la
          join public.ledger_posting p on p.ledger_account_id = la.id
          where la.bank_account_id = v.id and la.book = 'client_money_cash') <> 0 then
    raise exception 'the bank account still holds client money' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_transfer t
             where (t.debtor_bank_account_id = v.id or t.creditor_bank_account_id = v.id)
               and t.status in ('ordered', 'in_file')) then
    raise exception 'transfers from or to this bank account are in flight' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.servicer_billing_settings s where s.own_bank_account_id = v.id) then
    raise exception 'the own account is named in the billing settings: choose another one first'
      using errcode = 'check_violation';
  end if;
  update public.bank_account
  set status = 'closed', closed_on = private.paris_today(), closed_reason = btrim(p_reason)
  where id = v.id;
  perform private.command_record('close_bank_account', p_idempotency_key, v_request, jsonb_build_object('closed', true));
end;
$$;

------------------------------------------------------------------------------------------
-- Reads for the pages
------------------------------------------------------------------------------------------

-- A client's payout accounts for the client space and the back-office: the IBAN masked for client members (the last
-- four characters), whether a payout already went to it (a new IBAN is flagged, founder #10), who proposed and
-- confirmed it. Money staff of the servicer, or the client's administrators.
create or replace function public.payout_accounts(p_client_organization_id uuid)
returns table (id uuid, currency char(3), iban_masked text, iban_last4 text, bic text, holder_name text, kind text,
               status text, proposed_at timestamptz, proposed_by_name text, proposed_by_me boolean,
               confirmed_at timestamptz, confirmed_via text, confirmed_by_name text, closed_at timestamptz,
               closed_reason text, evidence_document_id uuid, paid_before boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (exists (select 1 from public.organization o where o.id = p_client_organization_id
                    and o.servicer_organization_id = any (private.money_staff_org_ids()))
          or p_client_organization_id = any (private.client_admin_whole_org_ids())) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query
  select a.id, a.currency,
         left(a.iban, 4) || ' •••• •••• ' || right(a.iban, 4), right(a.iban, 4), a.bic, a.holder_name, a.kind,
         a.status, a.proposed_at,
         (select coalesce(u.display_name, u.email) from public.app_user u where u.id = a.proposed_by),
         a.proposed_by = auth.uid(), a.confirmed_at, a.confirmed_via,
         (select coalesce(u.display_name, u.email) from public.app_user u where u.id = a.confirmed_by),
         a.closed_at, a.closed_reason, a.evidence_document_id,
         exists (select 1 from public.bank_transfer t where t.organization_id = a.organization_id and t.kind = 'payout'
                   and t.payee_iban = a.iban and t.status in ('booked', 'returned'))
  from public.client_payout_account a
  where a.client_organization_id = p_client_organization_id
  order by case a.status when 'proposed' then 0 when 'active' then 1 when 'returned' then 2 else 3 end,
           a.proposed_at desc, a.id;
end;
$$;

------------------------------------------------------------------------------------------
-- Read access (§6.2) and privileges
------------------------------------------------------------------------------------------

alter table public.billing_identity enable row level security;
alter table public.servicer_billing_settings enable row level security;
alter table public.client_payout_account enable row level security;
alter table public.client_status_event enable row level security;
revoke all on public.billing_identity, public.servicer_billing_settings, public.client_payout_account,
  public.client_status_event from public, anon, authenticated;
grant select on public.billing_identity, public.servicer_billing_settings, public.client_status_event to authenticated;
-- the IBAN in full: money staff only (client members read it masked through payout_accounts)
grant select on public.client_payout_account to authenticated;

create policy billing_identity_read on public.billing_identity for select to authenticated
  using ((select private.can_read_billing_identity(organization_id)));
create policy servicer_billing_settings_read on public.servicer_billing_settings for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy client_payout_account_read on public.client_payout_account for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy client_status_event_read on public.client_status_event for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));

-- Pure helpers and validators (no table read) stay executable by everyone: CHECK constraints, generated columns and
-- triggers call them whoever writes. The functions that read tables are the API's or the worker's only.
revoke execute on function
  private.billing_identity_guard(), private.billing_identity_gaps(uuid), private.can_read_billing_identity(uuid),
  private.servicer_billing_settings_guard(), private.client_admin_whole_org_ids(),
  private.can_upload_client_document_object(text), private.can_read_client_document(uuid, uuid, text),
  private.can_read_client_document_object(text), private.client_document_of(uuid, uuid, text),
  private.client_payout_account_guard(), private.client_status_event_guard(), private.mandate_terms_hash(),
  private.mandate_terms_guard(), private.portfolio_confirmation_blockers(uuid, date),
  private.batch_confirmation_blockers(uuid), private.receipt_issuer(uuid), private.receipt_prepare(uuid, uuid[]),
  private.registered_client_ibans(uuid), private.complete_batch_confirmation(uuid)
  from public, anon, authenticated;
-- the RLS helpers and storage policies run as the caller
grant execute on function private.can_read_billing_identity(uuid), private.client_admin_whole_org_ids(),
  private.can_upload_client_document_object(text), private.can_read_client_document(uuid, uuid, text),
  private.can_read_client_document_object(text) to authenticated;
-- the worker and the test fixtures (service role): the receipts and confirmation jobs, the guards' lookups
grant execute on function private.receipt_prepare(uuid, uuid[]), private.complete_batch_confirmation(uuid),
  private.client_document_of(uuid, uuid, text), private.billing_identity_gaps(uuid),
  private.portfolio_confirmation_blockers(uuid, date), private.batch_confirmation_blockers(uuid),
  private.receipt_issuer(uuid) to service_role;

revoke execute on function
  public.set_billing_identity(text, uuid, jsonb, integer), public.billing_identity_gaps(uuid),
  public.set_servicer_billing_settings(text, uuid, jsonb, integer),
  public.register_client_document(text, uuid, text, text, text, text, text),
  public.propose_payout_account(text, uuid, text, text, text, text, uuid, text),
  public.confirm_payout_account(text, uuid, text), public.reject_payout_account(text, uuid, text),
  public.retire_payout_account(text, uuid, text),
  public.record_client_status_event(text, uuid, text, date, uuid, text, uuid),
  public.set_mandate_terms(text, uuid, date, jsonb, text, jsonb, text, uuid, integer),
  public.set_mandate_insurance_clause(text, uuid, text, text), public.boarding_batch_readiness(uuid),
  public.client_readiness(uuid), public.payout_accounts(uuid), public.confirm_boarding_batch(uuid),
  public.close_bank_account(text, uuid, text)
  from public, anon;
grant execute on function
  public.set_billing_identity(text, uuid, jsonb, integer), public.billing_identity_gaps(uuid),
  public.set_servicer_billing_settings(text, uuid, jsonb, integer),
  public.register_client_document(text, uuid, text, text, text, text, text),
  public.propose_payout_account(text, uuid, text, text, text, text, uuid, text),
  public.confirm_payout_account(text, uuid, text), public.reject_payout_account(text, uuid, text),
  public.retire_payout_account(text, uuid, text),
  public.record_client_status_event(text, uuid, text, date, uuid, text, uuid),
  public.set_mandate_terms(text, uuid, date, jsonb, text, jsonb, text, uuid, integer),
  public.set_mandate_insurance_clause(text, uuid, text, text), public.boarding_batch_readiness(uuid),
  public.client_readiness(uuid), public.payout_accounts(uuid), public.confirm_boarding_batch(uuid),
  public.close_bank_account(text, uuid, text)
  to authenticated;
