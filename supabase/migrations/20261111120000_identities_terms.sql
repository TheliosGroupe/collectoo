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
--     (only its end may move, never into the past), a new version starts tomorrow (Paris) at the earliest, and a mandate
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
-- Review fixes: a client's own users never act on a court-appointed payout account, nor on any payout account once the
-- client's liquidation is recorded (L641-9 I); the gate also stops on a recorded mandate end, death or liquidation; a
-- new terms version starts tomorrow at the earliest; a credit from a client's IBAN can be released as a debtor payment
-- the client relays; payouts name their client (the « Nouvel IBAN » flag per client, returned payouts excluded); the
-- import joins the clients' IBANs once (not a list scan per line); the first save of the billing settings is
-- serialised; documents are indexed by client and kind.
-- Redefined: public.confirm_boarding_batch, private.complete_batch_confirmation, private.receipt_prepare,
-- private.registered_client_ibans, public.close_bank_account, private.held_line_kind, private.ingest_statement,
-- private.bank_own_credit_release_guard, public.release_own_credit, private.payment_insert_guard,
-- private.bank_transfer_guard.

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
-- client's, never printed on our documents; a servicer of another form cannot save its identity: its mentions are
-- not built).
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
  -- (free text for now: the floor is checked when invoices print it, M2c-5, with M3's legal-rate table)
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
  -- one save at a time per servicer, the first one included (FOR UPDATE locks no row before it exists: two first
  -- saves would both pass the compare and set, the second overwriting the first unseen)
  perform pg_advisory_xact_lock(hashtext('servicer_billing_settings:' || p_organization_id::text));
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
-- A client's documents of some kinds, newest first (the client page lists them; receipts make the table grow). Plain,
-- not partial: the kinds come as a parameter, so a partial index's predicate could not be proved under a generic plan.
create index document_client_kind_idx on public.document (client_organization_id, kind, created_at desc);

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
-- A court-appointed account (the liquidator's), and any account of a client whose liquidation or court-appointed payee
-- is recorded, is never confirmed by the client's own users (L641-9 I: from the judgment the debtor is divested of the
-- administration of its assets, its rights exercised by the liquidator): a second admin of the servicer confirms it
-- (OQ-41 default). Refused to them: « payout account refused: court_appointed » (42501), checked again under the lock
-- record_client_status_event takes.
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
  v_client_side boolean;
  v_request jsonb := jsonb_build_object('payout_account_id', p_payout_account_id,
                                        'iban', private.rf_normalise(coalesce(p_iban_typed, '')));
  v_result jsonb;
begin
  select * into a from public.client_payout_account where id = p_payout_account_id;
  if a.id is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_client_side := a.client_organization_id = any (private.client_admin_whole_org_ids());
  if v_client_side and private.is_aal2()
     and not private.payout_court_appointed(a.kind, a.client_organization_id) then
    v_via := 'client_portal';
  elsif private.has_role(a.organization_id, array['admin']) then
    v_via := 'second_admin';
  elsif v_client_side and private.payout_court_appointed(a.kind, a.client_organization_id) then
    raise exception 'payout account refused: court_appointed' using errcode = 'insufficient_privilege';
  else
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('confirm_payout_account', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  perform pg_advisory_xact_lock(hashtext('payout_accounts:' || a.organization_id::text));
  select * into a from public.client_payout_account where id = p_payout_account_id for update;
  if v_via = 'client_portal' and private.payout_court_appointed(a.kind, a.client_organization_id) then
    raise exception 'payout account refused: court_appointed' using errcode = 'insufficient_privilege';
  end if;
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

-- « Refuser » a proposal: money staff of the servicer, or the client's administrator at aal2 (never a court-appointed
-- account, nor once the client's liquidation is recorded: « payout account refused: court_appointed »). A reason is
-- required.
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
  v_staff boolean;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('payout_account_id', p_payout_account_id, 'reason', btrim(coalesce(p_reason, '')));
  v_result jsonb;
begin
  select * into a from public.client_payout_account where id = p_payout_account_id;
  if a.id is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_staff := private.has_role(a.organization_id, array['admin', 'ops_manager']);
  if not v_staff then
    if not (a.client_organization_id = any (private.client_admin_whole_org_ids())) then
      raise exception 'not allowed' using errcode = 'insufficient_privilege';
    elsif private.payout_court_appointed(a.kind, a.client_organization_id) then
      raise exception 'payout account refused: court_appointed' using errcode = 'insufficient_privilege';
    elsif not private.is_aal2() then
      raise exception 'not allowed' using errcode = 'insufficient_privilege';
    end if;
  end if;
  v_result := private.command_replay('reject_payout_account', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  -- the lock confirm_payout_account takes, then the row (the same order: never a deadlock between the two)
  perform pg_advisory_xact_lock(hashtext('payout_accounts:' || a.organization_id::text));
  select * into a from public.client_payout_account where id = p_payout_account_id for update;
  if not v_staff and private.payout_court_appointed(a.kind, a.client_organization_id) then
    raise exception 'payout account refused: court_appointed' using errcode = 'insufficient_privilege';
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

-- « Retirer » the current account (admin at aal2, with a reason): payouts wait for a new confirmed account. Never the
-- client's users (once the client's liquidation is recorded they read « payout account refused: court_appointed »).
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
  if a.id is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if not private.has_role(a.organization_id, array['admin']) then
    if a.client_organization_id = any (private.client_admin_whole_org_ids())
       and private.payout_court_appointed(a.kind, a.client_organization_id) then
      raise exception 'payout account refused: court_appointed' using errcode = 'insufficient_privilege';
    end if;
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
-- Now: a mandate end, a death or a liquidation stops the confirmation gate, and after a liquidation the client's own
-- users act on no payout account (private.payout_court_appointed). Their effects on runs and payouts come with M2c-4 /
-- M2c-7 (OQ-41).
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

-- A payout account the client's own users no longer act on (confirm, reject, retire): a court-appointed one (the
-- liquidator's), or any account of a client for which a liquidation, or an event naming a court-appointed payee, is
-- recorded (L641-9 I: the debtor's rights over its assets are exercised by the liquidator). Only a second admin of
-- the servicer acts on it then.
create or replace function private.payout_court_appointed(p_kind text, p_client_organization_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_kind = 'court_appointed'
      or exists (select 1 from public.client_status_event e
                 where e.client_organization_id = p_client_organization_id
                   and (e.kind = 'liquidation' or e.payout_account_id is not null));
$$;

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
  -- the lock the payout-account decisions take: a client's confirmation or refusal in flight sees the event, or
  -- finishes before it is recorded (private.payout_court_appointed)
  perform pg_advisory_xact_lock(hashtext('payout_accounts:' || c.servicer_organization_id::text));
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
-- or deleted (it is superseded before it applies). A new version of a mandate that already has one starts tomorrow
-- (Paris) at the earliest — never today, so it never applies to money encaissé earlier that day (never retroactive,
-- §8.1; founder #5: new rates only for the future); refused: « mandate terms refused: starts_too_early ». A mandate's
-- first version may start at its signature (nothing was collected under the mandate before it). After the row checks
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
    if new.valid_from <= v_today
       and exists (select 1 from public.mandate_terms t where t.mandate_id = new.mandate_id and t.id <> new.id) then
      raise exception 'mandate terms refused: starts_too_early' using errcode = 'check_violation',
        detail = format('a new version starts on %s at the earliest', v_today + 1);
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
    -- every column but the end, including any column added later
    if (to_jsonb(new) - 'valid_to') is distinct from (to_jsonb(old) - 'valid_to')
       or (new.valid_to is distinct from old.valid_to
           and ((old.valid_to is not null and old.valid_to < v_today)
                or (new.valid_to is not null and new.valid_to < v_today))) then
      raise exception 'mandate terms %: a version in force is immutable (only its end may move, never into the past)',
        old.id using errcode = 'check_violation';
    end if;
  elsif new.valid_from < v_today
        or (new.valid_from = v_today and exists (select 1 from public.mandate_terms t
                                                  where t.mandate_id = new.mandate_id and t.id <> new.id)) then
    raise exception 'mandate terms refused: starts_too_early' using errcode = 'check_violation',
      detail = format('a new version starts on %s at the earliest', v_today + 1);
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

-- « Nouvelles conditions financières » (admin at aal2): a version from p_valid_from (> Paris today; a mandate's first
-- version ≥ today) with its schedule,
-- terms, clause references and the signed document (a mandate document of the client). The version covering that
-- day ends then; versions not yet in force that would start on or after it are superseded (deleted: they never
-- applied); the new one keeps the mandate's end (the last version's, when later than its start) and the covering
-- version's other settings
-- (payment plans, settlement authority). Claim types named by the schedule must exist; portfolios it names must be
-- the mandate's. Compare and set: p_expected_latest_id is the mandate's latest version (by start) as the page showed
-- it (null: none), so two admins never supersede each other's terms unseen.
create or replace function public.set_mandate_terms(p_idempotency_key text, p_mandate_id uuid, p_valid_from date,
                                                    p_commission_schedule jsonb, p_commission_clause_ref text,
                                                    p_remittance_terms jsonb, p_remittance_clause_ref text,
                                                    p_document_id uuid, p_remittance_max_days integer,
                                                    p_expected_latest_id uuid)
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
                                        'document_id', p_document_id, 'remittance_max_days', p_remittance_max_days,
                                        'expected_latest_id', p_expected_latest_id);
  v_result jsonb;
  v_error text;
  v_latest uuid;
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
  select t.id into v_latest from public.mandate_terms t where t.mandate_id = m.id
  order by t.valid_from desc limit 1;
  if v_latest is distinct from p_expected_latest_id then
    raise exception 'mandate terms changed since they were read' using errcode = 'serialization_failure';
  end if;
  -- tomorrow at the earliest when the mandate has a version (never today: never retroactive); its first, today
  if p_valid_from is null or p_valid_from < v_today or (v_latest is not null and p_valid_from <= v_today) then
    raise exception 'mandate terms refused: starts_too_early' using errcode = 'check_violation',
      detail = format('a new version starts on %s at the earliest',
                      case when v_latest is null then v_today else v_today + 1 end);
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
--   no_active_mandate (R124-3), the client's recorded events (each code followed by « : » and the event's date,
--   YYYY-MM-DD, the earliest of its kind on or before the day asked): client_mandate_ended (mandate_ended or
--   guardianship: C. civ. 2003, the mandate ends by revocation, renunciation, « la tutelle des majeurs »),
--   client_deceased (death: 2003), client_in_liquidation (liquidation: a product choice, not a rule of law — the
--   client's rights are the liquidator's, L641-9 I, and no new files are boarded for it; a proceeding opened does not
--   block: servicing goes on, design §13 #9), insurance_clause_missing (2°), commission_schedule_missing,
--   commission_clause_missing (3°), remittance_terms_missing, remittance_clause_missing (4°), terms_document_missing
--   (the signed convention), servicer_identity_incomplete (R123-237/238, 242 nonies A 1°–2°),
--   client_identity_incomplete (SIREN, registered office), client_not_professional, client_not_mainland_france
--   (founder #13, OQ-42), currency_not_eur (the batch's accounts; founder #13).
------------------------------------------------------------------------------------------

create or replace function private.portfolio_confirmation_blockers(p_portfolio_id uuid, p_on date)
returns text[]
language sql
stable
set search_path = ''
as $$
  select array_remove(array[
    case when mt.id is null then 'no_active_mandate' end,
    'client_mandate_ended:' || to_char(ev.mandate_ended, 'YYYY-MM-DD'),
    'client_deceased:' || to_char(ev.deceased, 'YYYY-MM-DD'),
    'client_in_liquidation:' || to_char(ev.liquidation, 'YYYY-MM-DD'),
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
  cross join lateral (select min(e.effective_date) filter (where e.kind in ('mandate_ended', 'guardianship'))
                               as mandate_ended,
                             min(e.effective_date) filter (where e.kind = 'death') as deceased,
                             min(e.effective_date) filter (where e.kind = 'liquidation') as liquidation
                      from public.client_status_event e
                      where e.client_organization_id = p.client_organization_id and e.effective_date <= p_on) ev
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
-- Statement import with the clients' IBANs (review fix): the import classified each line against the servicer's
-- whole list of confirmed client IBANs (an array scan per line: 8 s for 50,000 lines × 5,000 IBANs). The lines and
-- the IBANs are now joined once; a held line looks its IBAN up by key.
------------------------------------------------------------------------------------------

-- This import's lines (pg_temp._bi_stage, private.ingest_statement) whose kind changes once our own transfers and the
-- clients' credits are recognised. One pass: the lines and the servicer's confirmed client IBANs are hash-joined
-- (nested loops and merge joins off: linear in lines + IBANs whatever the estimates), and each line hands the
-- classifier its own IBAN when it is a client's, so no line scans the list. Same answer as before (the classifier
-- and its Python twin are unchanged).
create or replace function private.stage_refined_kinds(p_organization_id uuid, p_own_ibans text[])
returns table (line_no integer, kind text)
language plpgsql
stable
set search_path = ''
set enable_nestloop = off
set enable_mergejoin = off
as $$
begin
  return query
  select y.line_no, y.kind from (
    select x.line_no, x.kind as old_kind,
           private.bank_line_refined_kind(x.kind, x.direction, x.end_to_end_id, x.counterparty_iban, p_own_ibans,
                                          case when c.iban is null then '{}'::text[] else array[c.iban] end) as kind
    from pg_temp._bi_stage x
    left join (select distinct a.iban from public.client_payout_account a
               where a.organization_id = p_organization_id and a.confirmed_at is not null) c
      on c.iban = x.counterparty_iban) y
  where y.kind is distinct from y.old_kind;
end;
$$;

-- What a held line is without a recorded reading (redefined from 20261111090000): its IBAN looked up among the
-- clients' confirmed IBANs by key (client_payout_account_iban_idx), not the servicer's list rebuilt per line.
create or replace function private.held_line_kind(p_bank_transaction_id uuid)
returns table (kind text, method text)
language sql
stable
set search_path = ''
as $$
  select coalesce(h.kind, private.bank_line_refined_kind(case
           when t.return_reason is not null or t.reversal_indicator or t.original_end_to_end_id is not null then 'return'
           when t.direction = 'credit' then 'debtor_credit'
           when t.end_to_end_id like 'RFD%' then 'refund_out'
           else 'other_debit' end, t.direction, t.end_to_end_id, t.counterparty_iban,
           array(select o.iban from public.bank_account o where o.organization_id = t.organization_id and o.purpose = 'own'),
           case when exists (select 1 from public.client_payout_account a
                             where a.organization_id = t.organization_id and a.iban = t.counterparty_iban
                               and a.confirmed_at is not null)
                then array[t.counterparty_iban] else '{}'::text[] end)),
         coalesce(h.method, 'other')
  from public.bank_transaction t
  left join private.bank_line_held_kind h on h.bank_transaction_id = t.id
  where t.id = p_bank_transaction_id;
$$;

-- Statement import (redefined from 20261111090000): the clients' IBANs through private.stage_refined_kinds. Nothing
-- else changes.
create or replace function private.ingest_statement(p_statement_id uuid, p_header jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.bank_statement;
  b public.bank_account;
  prev public.bank_statement;
  v_sections jsonb := coalesce(p_header -> 'sections', '[]');
  v_bad text;
  v_n bigint;
  v_new bigint;
  v_entries bigint := 0;
  v_cash_in jsonb;
  v_counts jsonb;
  v_warnings jsonb := '[]';
  v_check jsonb;
  v_from date;
  v_to date;
  v_cash bigint;
  v_unposted record;
  v_own text[];
begin
  select * into s from public.bank_statement where id = p_statement_id for update;
  if not found then
    raise exception 'statement_unknown: statement % does not exist', p_statement_id using errcode = '22023';
  end if;
  if s.status <> 'uploaded' then
    return jsonb_build_object('skipped', s.status);  -- a redelivered job: already done
  end if;
  -- One import at a time per bank account: dedup, overlaps and suspected duplicates see every earlier line.
  perform pg_advisory_xact_lock(hashtext('bank_import:' || s.bank_account_id::text));
  select * into b from public.bank_account where id = s.bank_account_id for share;  -- a closure waits
  if b.status <> 'active' or b.purpose <> 'client_funds' then
    raise exception 'bank_account_closed: bank account % is not an active client_funds account', b.id
      using errcode = '22023';
  end if;
  -- A file is the statement of one bank account: imported for another account of the servicer (the
  -- wrong one chosen first), it is refused, so its money is never booked on two accounts. Imports of
  -- the same file are serialised across the servicer's accounts.
  perform pg_advisory_xact_lock(hashtext('bank_import_file:' || s.organization_id::text || ':' || s.file_sha256));
  select min(p.bank_account_id::text) into v_bad from public.bank_statement p
  where p.organization_id = s.organization_id and p.file_sha256 = s.file_sha256
    and p.bank_account_id <> s.bank_account_id and p.status = 'imported';
  if v_bad is not null then
    raise exception 'imported_on_other_account: this file was imported for bank account %', v_bad using errcode = '22023';
  end if;
  if coalesce(p_header ->> 'format', '') <> s.format or jsonb_typeof(v_sections) <> 'array'
     or (s.format = 'camt053' and jsonb_array_length(v_sections) = 0)
     or (s.format = 'csv' and jsonb_array_length(v_sections) <> 0)
     or coalesce(p_header ->> 'version', '00') !~ '^[0-9]{2}$' then
    raise exception 'header_invalid: the parsed header does not describe a % statement', s.format using errcode = '22023';
  end if;

  -- This statement's lines, in a working table of our own (ADR-0012 temp-schema rule), analysed: every
  -- later query starts from it, so no plan depends on the statistics of the tables loaded below.
  drop table if exists pg_temp._bi_stage;
  create temp table _bi_stage on commit drop as
  select * from private.bank_import_stage where statement_id = p_statement_id;
  alter table pg_temp._bi_stage add primary key (line_no);
  analyze pg_temp._bi_stage;
  -- M2c-1 (§12): our own transfers and credits are classified here whatever the parser knew (the registered own IBANs
  -- may be newer than the job's list): a credit carrying our TOP id or from a registered own IBAN is ours, never a
  -- debtor payment; one from a client's payout IBAN goes to ops; a debit carrying our RMT/SWP id or to our own IBAN
  -- is a transfer out. The stage rows are kept in step (a line held as a duplicate keeps this reading).
  v_own := array(select o.iban from public.bank_account o
                 where o.organization_id = s.organization_id and o.purpose = 'own');
  -- M2c-2: the clients' IBANs in one pass over the lines (private.stage_refined_kinds), never a scan of the servicer's
  -- whole list per line
  drop table if exists pg_temp._bi_refined;
  create temp table _bi_refined on commit drop as
  select r.line_no, r.kind from private.stage_refined_kinds(s.organization_id, v_own) r;
  if exists (select 1 from pg_temp._bi_refined) then
    update pg_temp._bi_stage x set kind = r.kind from pg_temp._bi_refined r where r.line_no = x.line_no;
    update private.bank_import_stage x set kind = r.kind from pg_temp._bi_refined r
    where x.statement_id = p_statement_id and x.line_no = r.line_no;
  end if;
  select count(*) into v_n from pg_temp._bi_stage;
  if v_n <> coalesce((p_header ->> 'line_count')::bigint, -1) then
    raise exception 'header_invalid: % staged lines, % announced', v_n, p_header ->> 'line_count' using errcode = '22023';
  end if;

  -- Lines are well formed (first offending line named).
  select min(x.line_no)::text into v_bad from pg_temp._bi_stage x where x.currency <> s.currency;
  if v_bad is not null then
    raise exception 'currency_mismatch: line % is not in %', v_bad, s.currency using errcode = '22023';
  end if;
  select min(x.line_no)::text into v_bad from pg_temp._bi_stage x where x.booking_date > private.paris_today();
  if v_bad is not null then
    raise exception 'future_booking_date: line % is booked after today', v_bad using errcode = '22023';
  end if;
  select min(x.line_no)::text into v_bad from pg_temp._bi_stage x
  where x.direction is null or x.direction not in ('credit', 'debit')
     or x.amount_minor is null or x.amount_minor <= 0 or x.amount_minor > 1000000000000000
     or x.booking_date is null or x.dedup_key is null or x.dedup_key !~ '^[tech]:' or length(x.dedup_key) > 300
     or x.method is null or x.method not in ('sct', 'sdd', 'card', 'cheque', 'other')
     or x.kind is null or x.kind not in ('debtor_credit', 'return', 'refund_out', 'other_debit', 'batch_unsplit',
                                         'transfer_out', 'own_transfer_in', 'client_transfer_in')
     or (x.direction = 'credit' and x.kind not in ('debtor_credit', 'return', 'batch_unsplit', 'own_transfer_in',
                                                   'client_transfer_in'))
     or (x.direction = 'debit' and x.kind in ('debtor_credit', 'own_transfer_in', 'client_transfer_in'))
     or length(x.payment_info_id) not between 1 and 35
     or (s.format = 'csv' and (x.section_no <> 0 or x.dedup_key !~ '^[ch]:' or x.entry_ref is not null))
     or (s.format = 'camt053' and (x.section_no < 1 or x.section_no > jsonb_array_length(v_sections)
                                   or x.dedup_key !~ '^[teh]:'))
     or length(x.entry_ref) not between 1 and 300
     -- an entry key is e:<the line's entry reference>#<n>, n from 1
     or (x.dedup_key ~ '^e:' and not coalesce(left(x.dedup_key, length(x.entry_ref) + 3) = 'e:' || x.entry_ref || '#'
                                              and substr(x.dedup_key, length(x.entry_ref) + 4) ~ '^[1-9][0-9]*$', false));
  if v_bad is not null then
    raise exception 'line_invalid: line % is not a well-formed bank line', v_bad using errcode = '22023';
  end if;
  select min(d.dedup_key) into v_bad
  from (select x.dedup_key from pg_temp._bi_stage x group by x.dedup_key having count(*) > 1) d;
  if v_bad is not null then
    raise exception 'duplicate_reference_in_file: % appears twice in the file', v_bad using errcode = '22023';
  end if;

  -- camt.053: per <Stmt>, opening + credits - debits = closing (the parser checked it already).
  if s.format = 'camt053' then
    select min(sec.ord)::text into v_bad
    from jsonb_array_elements(v_sections) with ordinality as sec (v, ord)
    left join (select x.section_no,
                      sum(case x.direction when 'credit' then x.amount_minor else -x.amount_minor end) as moved
               from pg_temp._bi_stage x group by x.section_no) m on m.section_no = sec.ord
    where sec.v ->> 'opening_minor' is null or sec.v ->> 'closing_minor' is null
       or (sec.v ->> 'opening_minor')::numeric + coalesce(m.moved, 0) <> (sec.v ->> 'closing_minor')::numeric;
    if v_bad is not null then
      raise exception 'unbalanced: statement % of the file: opening + lines <> closing balance', v_bad
        using errcode = '22023';
    end if;
  end if;

  -- 1. Lines this bank account reported already (the same file again, an overlapping statement): skipped,
  --    but only when the bank tells the same facts. A known reference with another amount, direction or
  --    date refuses the file: a line is never dropped because its reference was reused.
  drop table if exists pg_temp._bi_known;
  create temp table _bi_known on commit drop as
  select x.line_no, (x.direction, x.amount_minor, x.booking_date) is distinct from
                    (t.direction, t.amount_minor, t.booking_date) as conflict
  from pg_temp._bi_stage x
  join public.bank_transaction t on t.bank_account_id = s.bank_account_id and t.dedup_key = x.dedup_key;
  select min(k.line_no)::text into v_bad from pg_temp._bi_known k where k.conflict;
  if v_bad is not null then
    raise exception 'reference_conflict: line % has the bank reference of an earlier line with another amount, direction or date',
      v_bad using errcode = '22023';
  end if;
  drop table if exists pg_temp._bi_new;
  create temp table _bi_new on commit drop as
  select x.* from pg_temp._bi_stage x
  where not exists (select 1 from pg_temp._bi_known k where k.line_no = x.line_no);
  alter table pg_temp._bi_new add primary key (line_no);
  analyze pg_temp._bi_new;

  -- A camt.053 entry (Ntry/AcctSvcrRef) is booked once, at the level of detail of its first import: a new
  -- line of an entry this bank account already has means the entry comes back split another way (unsplit
  -- then detailed, or the reverse, or other detail references). Refused: the money would be booked twice.
  v_bad := private.bank_import_entry_known(s.bank_account_id)::text;
  if v_bad is not null then
    raise exception 'entry_detail_differs: line % is part of a bank entry imported earlier with other details', v_bad
      using errcode = '22023';
  end if;

  -- 2. CSV safety net (design §8.3 step 5): same day, amount and direction as a line of another import,
  --    with a similar label -> held as a suspected duplicate (no payment, no cash) until ops decide. Two
  --    lines that both carry the bank's own id are different transactions by the bank's word.
  if s.format = 'csv' then
    -- The same operation on another bank account of the servicer (an export uploaded on the wrong
    -- account first): with the bank's id and the same day, amount and direction, the bank says it is the
    -- same operation and the file is refused; with the same fingerprint (no bank id), the line is held.
    drop table if exists pg_temp._bi_elsewhere;
    create temp table _bi_elsewhere on commit drop as
    select * from private.bank_import_lines_elsewhere(s.organization_id, s.bank_account_id);
    select min(e.line_no)::text into v_bad from pg_temp._bi_elsewhere e where e.dedup_key like 'c:%';
    if v_bad is not null then
      raise exception 'imported_on_other_account: line % was imported for another bank account', v_bad
        using errcode = '22023';
    end if;
    update pg_temp._bi_new n set kind = 'suspected_duplicate'
    from pg_temp._bi_elsewhere e where e.line_no = n.line_no;

    update pg_temp._bi_new n set kind = 'suspected_duplicate'
    from (select distinct x.line_no
          from pg_temp._bi_new x
          join public.bank_transaction t on t.bank_account_id = s.bank_account_id and t.booking_date = x.booking_date
            and t.amount_minor = x.amount_minor and t.direction = x.direction
          where not (x.dedup_key like 'c:%' and t.dedup_key like 'c:%')
            and extensions.similarity(upper(coalesce(t.counterparty_name, '') || ' ' || coalesce(t.remittance_text, '')),
                                      upper(coalesce(x.counterparty_name, '') || ' ' || coalesce(x.remittance_text, '')))
                >= 0.5) d
    where n.line_no = d.line_no;
  end if;

  -- 3. The facts.
  drop table if exists pg_temp._bi_ins;
  create temp table _bi_ins (id uuid primary key, line_no integer not null unique) on commit drop;
  with ins as (
    insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
      amount_minor, currency, booking_date, value_date, reversal_indicator, bank_tx_code, acct_svcr_ref, end_to_end_id,
      tx_id, mandate_ref, counterparty_name, ultimate_counterparty_name, counterparty_iban, remittance_text,
      creditor_reference, return_reason, original_end_to_end_id, batch_entry_ref, entry_ref, kind, payment_info_id)
    select s.organization_id, s.bank_account_id, s.id, n.line_no, n.dedup_key, n.direction, n.amount_minor, s.currency,
           n.booking_date, n.value_date, coalesce(n.reversal_indicator, false), n.bank_tx_code, n.acct_svcr_ref,
           n.end_to_end_id, n.tx_id, n.mandate_ref, n.counterparty_name, n.ultimate_counterparty_name,
           n.counterparty_iban, n.remittance_text, n.creditor_reference, n.return_reason, n.original_end_to_end_id,
           n.batch_entry_ref, n.entry_ref, n.kind, n.payment_info_id
    from pg_temp._bi_new n
    order by n.line_no
    on conflict (bank_account_id, dedup_key) do nothing
    returning id, line_no
  )
  insert into pg_temp._bi_ins select ins.id, ins.line_no from ins;
  analyze pg_temp._bi_ins;
  select count(*) into v_new from pg_temp._bi_ins;
  if v_new <> (select count(*) from pg_temp._bi_new) then
    -- cannot happen under the per-account lock; retried by the queue if it ever does
    raise exception 'statement %: lines were imported concurrently', s.id using errcode = '40001';
  end if;

  -- 4. One payment per credit a debtor paid (bank facts copied; unmatched until M2b-3 matches it).
  drop table if exists pg_temp._bi_pay;
  create temp table _bi_pay on commit drop as
  select i.id as bank_transaction_id, n.line_no, n.booking_date, n.amount_minor
  from pg_temp._bi_ins i join pg_temp._bi_new n on n.line_no = i.line_no
  where n.direction = 'credit' and n.kind in ('debtor_credit', 'batch_unsplit');
  analyze pg_temp._bi_pay;
  insert into public.payment (organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, value_date, payer_name, payer_iban, end_to_end_id,
                              remittance_text, creditor_reference)
  select s.organization_id, s.bank_account_id, p.bank_transaction_id, s.format, n.method, n.amount_minor, s.currency,
         n.booking_date, n.value_date, coalesce(n.counterparty_name, n.ultimate_counterparty_name), n.counterparty_iban,
         n.end_to_end_id, n.remittance_text, n.creditor_reference
  from pg_temp._bi_pay p join pg_temp._bi_new n on n.line_no = p.line_no
  order by p.line_no;

  -- 5. cash_in: one entry per booking date of this statement (design §2 #1), Dr 5120 / Cr 4710 pool.
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  select (row_number() over (order by d.booking_date))::integer, s.organization_id, 'cash_in', d.booking_date,
         'cash_in:' || s.id::text || ':' || d.booking_date::text, 'bank_statement', s.id::text
  from (select distinct p.booking_date from pg_temp._bi_pay p) d;
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
  select e.entry_no, l.line_no, l.book, l.sign * t.total, s.currency,
         case when l.book = 'client_money_cash' then s.bank_account_id end
  from pg_temp._lps_entry e
  join (select p.booking_date, sum(p.amount_minor) as total from pg_temp._bi_pay p group by p.booking_date) t
    on t.booking_date = e.effective_date
  cross join (values (1, 'client_money_cash', 1), (2, 'unallocated_payment', -1)) as l (line_no, book, sign);
  if exists (select 1 from pg_temp._lps_entry) then
    select count(*) into v_entries from private.ledger_post_set() r where r.created;
  end if;

  -- 6. I11, from the tables: for each booking date, the cash booked for this statement = Σ of its payments.
  select coalesce(jsonb_agg(jsonb_build_object('date', y.d, 'entry_id', y.entry_id, 'minor', y.total::text)
                            order by y.d), '[]')
  into v_cash_in
  from (select e.effective_date as d, e.id as entry_id, sum(lp.amount_minor) as total
        from (select distinct p.booking_date from pg_temp._bi_pay p) k
        join public.ledger_entry e on e.organization_id = s.organization_id
          and e.idempotency_key = 'cash_in:' || s.id::text || ':' || k.booking_date::text
        join public.ledger_posting lp on lp.entry_id = e.id
        join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'client_money_cash'
        group by e.effective_date, e.id) y;
  select min(coalesce(x.d, (y.v ->> 'date')::date)::text) into v_bad
  from (select p.booking_date as d, sum(p.amount_minor) as total
        from pg_temp._bi_pay k join public.payment p on p.bank_transaction_id = k.bank_transaction_id
        group by p.booking_date) x
  full join jsonb_array_elements(v_cash_in) y (v) on (y.v ->> 'date')::date = x.d
  where x.total is distinct from (y.v ->> 'minor')::bigint;
  if v_bad is not null then
    raise exception 'statement %: the cash booked on % differs from its payments (I11)', s.id, v_bad using errcode = 'LG001';
  end if;

  -- 7. What the import did (amounts as text).
  select jsonb_build_object(
    'lines', v_n,
    'new_lines', v_new,
    'known_lines', v_n - v_new,
    'skipped_not_booked', coalesce((p_header ->> 'skipped_not_booked')::bigint, 0),
    'credits', jsonb_build_object('lines', count(*) filter (where n.direction = 'credit'),
                                  'minor', coalesce(sum(n.amount_minor) filter (where n.direction = 'credit'), 0)::text),
    'debits', jsonb_build_object('lines', count(*) filter (where n.direction = 'debit'),
                                 'minor', coalesce(sum(n.amount_minor) filter (where n.direction = 'debit'), 0)::text),
    'payments', jsonb_build_object('count', count(p.line_no), 'minor', coalesce(sum(p.amount_minor), 0)::text),
    'unposted', jsonb_build_object(
      'lines', count(*) filter (where p.line_no is null),
      'minor', coalesce(sum(case n.direction when 'credit' then n.amount_minor else -n.amount_minor end)
                        filter (where p.line_no is null), 0)::text),
    'cash_in', v_cash_in,
    'cash_in_entries', v_entries,
    'returns', count(*) filter (where n.kind = 'return'),
    'refunds_out', count(*) filter (where n.kind = 'refund_out'),
    'other_debits', count(*) filter (where n.kind = 'other_debit'),
    'batch_unsplit', count(*) filter (where n.kind = 'batch_unsplit'),
    'suspected_duplicates', count(*) filter (where n.kind = 'suspected_duplicate'),
    'transfers_out', count(*) filter (where n.kind = 'transfer_out'),
    'own_transfers_in', count(*) filter (where n.kind = 'own_transfer_in'),
    'client_transfers_in', count(*) filter (where n.kind = 'client_transfer_in'))
  into v_counts
  from pg_temp._bi_new n left join pg_temp._bi_pay p on p.line_no = n.line_no;

  -- 8. Dates and balances of the file; continuity with the previous statement (« relevé manquant »).
  if s.format = 'camt053' then
    select min((v ->> 'from_date')::date), max((v ->> 'to_date')::date) into v_from, v_to
    from jsonb_array_elements(v_sections) v;
    -- within the file
    select coalesce(jsonb_agg(jsonb_build_object('code', 'opening_differs', 'stmt_id', cur.v ->> 'stmt_id',
                                                 'expected_minor', pre.v ->> 'closing_minor',
                                                 'actual_minor', cur.v ->> 'opening_minor') order by cur.ord), '[]')
    into v_warnings
    from jsonb_array_elements(v_sections) with ordinality as cur (v, ord)
    join jsonb_array_elements(v_sections) with ordinality as pre (v, ord) on pre.ord = cur.ord - 1
    where (cur.v ->> 'opening_minor')::bigint <> (pre.v ->> 'closing_minor')::bigint;
    -- with the statement that covers the day before this one: of the imported statements starting before
    -- it, the one that ends last (an index scan). If it ends on or after this one's first day, the day
    -- before is covered already (the overlap warning says so): nothing to compare. Only the closing at
    -- its last day is known, so an older statement is never compared.
    select * into prev from public.bank_statement p
    where p.bank_account_id = s.bank_account_id and p.status = 'imported' and p.format = 'camt053'
      and p.from_date < v_from
    order by p.to_date desc, p.finished_at desc
    limit 1;
    if found and prev.to_date < v_from then
      if prev.closing_booked_minor is distinct from (v_sections -> 0 ->> 'opening_minor')::bigint then
        v_warnings := v_warnings || jsonb_build_object('code', 'opening_differs', 'previous_statement_id', prev.id,
          'expected_minor', prev.closing_booked_minor::text, 'actual_minor', v_sections -> 0 ->> 'opening_minor');
      end if;
      if (prev.sections -> -1 ->> 'seq') is not null and (v_sections -> 0 ->> 'seq') is not null
         and (v_sections -> 0 ->> 'seq')::bigint not in ((prev.sections -> -1 ->> 'seq')::bigint + 1, 1) then
        v_warnings := v_warnings || jsonb_build_object('code', 'sequence_gap', 'previous_statement_id', prev.id,
          'previous_seq', prev.sections -> -1 ->> 'seq', 'seq', v_sections -> 0 ->> 'seq');
      end if;
    end if;
  else
    select min(x.booking_date), max(x.booking_date) into v_from, v_to from pg_temp._bi_stage x;
  end if;
  select count(*) into v_n from public.bank_statement p
  where p.bank_account_id = s.bank_account_id and p.status = 'imported' and p.from_date <= v_to and p.to_date >= v_from;
  if v_n > 0 then
    v_warnings := v_warnings || jsonb_build_object('code', 'overlap', 'statements', v_n);
  end if;

  -- 9. I9 at import: closing balance = 5120[bank] + lines not booked (camt.053 only: a CSV has no balance).
  if s.format = 'camt053' then
    select coalesce(sum(lp.amount_minor), 0)::bigint into v_cash
    from public.ledger_account la
    join public.ledger_posting lp on lp.ledger_account_id = la.id and lp.effective_date <= v_to
    where la.bank_account_id = s.bank_account_id and la.book = 'client_money_cash';
    select * into v_unposted from private.bank_unposted(s.bank_account_id, v_to);
    v_check := jsonb_build_object(
      'as_of', v_to,
      'closing_minor', v_sections -> -1 ->> 'closing_minor',
      'cash_minor', v_cash::text,
      'unposted_minor', v_unposted.minor::text,
      'unposted_lines', v_unposted.lines,
      'difference_minor', ((v_sections -> -1 ->> 'closing_minor')::bigint - v_cash - v_unposted.minor)::text);
  end if;

  update public.bank_statement
  set status = 'imported', finished_at = now(),
      format_version = case when s.format = 'camt053' then p_header ->> 'version' end,
      stmt_id = v_sections -> 0 ->> 'stmt_id',
      electronic_seq_no = (v_sections -> 0 ->> 'seq')::bigint,
      from_date = v_from, to_date = v_to,
      opening_booked_minor = (v_sections -> 0 ->> 'opening_minor')::bigint,
      closing_booked_minor = (v_sections -> -1 ->> 'closing_minor')::bigint,
      sections = case when s.format = 'camt053' then v_sections end,
      counts = v_counts, warnings = v_warnings, bank_check = v_check
  where id = s.id;
  delete from private.bank_import_stage where statement_id = s.id;
  return v_counts;
end;
$$;

------------------------------------------------------------------------------------------
-- A credit from a client's IBAN released as a debtor payment (review fix): a credit from a client's confirmed payout
-- IBAN is read as `client_transfer_in` (the client's money, design §12), with no way back to a payment, while it may
-- be a debtor's payment the client relays (the client paid for its debtor, or forwards what the debtor paid it). Ops
-- release it as for an own credit (public.release_own_credit, « Paiement d'un débiteur relayé par le client »): a
-- payment of the dedicated account, payer « Versement relayé par le client » (never the client's IBAN as the payer: a
-- refund goes to the IBAN ops give), unmatched, for ops to assign. Same refusals.
------------------------------------------------------------------------------------------

comment on table public.bank_own_credit_release is
  'Credits from the servicer''s own account or a client''s payout IBAN that ops released as debtor payments relayed by '
  'the servicer or the client (each became a payment of the dedicated account, unmatched, for ops to assign).';

-- (redefined from 20261111090000: a client's credit too)
create or replace function private.bank_own_credit_release_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare v_bad text;
begin
  select min(n.bank_transaction_id::text) into v_bad
  from new_rows n
  left join lateral (select q.organization_id, q.bank_account_id, q.direction, q.kind from public.bank_transaction q
                     where q.id = n.bank_transaction_id offset 0) t on true
  left join lateral (select q.decision, q.released_kind from public.bank_duplicate_resolution q
                     where q.bank_transaction_id = n.bank_transaction_id offset 0) r on true
  where t.organization_id is distinct from n.organization_id or t.bank_account_id is distinct from n.bank_account_id
     or t.direction <> 'credit'
     or not coalesce(t.kind in ('own_transfer_in', 'client_transfer_in')
                     or (t.kind = 'suspected_duplicate' and r.decision = 'released'
                         and r.released_kind in ('own_transfer_in', 'client_transfer_in')), false)
     or exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = n.bank_transaction_id offset 0)
     or exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = n.bank_transaction_id offset 0);
  if v_bad is not null then
    raise exception 'own credit release %: not a credit from our own account or a client''s of its bank account, '
                    'or already booked or linked', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

-- « Versement relayé par le cabinet » / « Paiement d'un débiteur relayé par le client » (redefined from 20261111090000:
-- an own credit, or a client's credit — as read, or a held duplicate released as one —, neither booked in the funds
-- nor linked, becomes a debtor payment; refusals unchanged: « own credit release refused: not_own_credit |
-- already_booked | already_linked | reason_required » (23514)).
create or replace function public.release_own_credit(p_idempotency_key text, p_bank_transaction_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('bank_transaction_id', p_bank_transaction_id,
                                        'reason', btrim(coalesce(p_reason, '')));
  v_result jsonb;
  v_kind text;
  v_held boolean;
  v_payment uuid;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('release_own_credit', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'own credit release refused: reason_required' using errcode = 'check_violation';
  end if;
  perform 1 from public.bank_account b where b.id = t.bank_account_id for share;
  perform 1 from public.bank_transaction x where x.id = t.id for no key update;
  -- the facts, read under the locks
  select coalesce(r.released_kind, t.kind), (t.kind = 'suspected_duplicate' and r.decision is distinct from 'released')
  into v_kind, v_held
  from (select 1) d
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id;
  if t.direction <> 'credit' or v_kind not in ('own_transfer_in', 'client_transfer_in') or v_held then
    raise exception 'own credit release refused: not_own_credit' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id) then
    raise exception 'own credit release refused: already_linked' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
     or exists (select 1 from public.payment p where p.bank_transaction_id = t.id) then
    raise exception 'own credit release refused: already_booked' using errcode = 'check_violation';
  end if;
  insert into public.bank_own_credit_release (bank_transaction_id, organization_id, bank_account_id, reason, decided_by)
  values (t.id, t.organization_id, t.bank_account_id, v_reason, auth.uid());
  v_payment := private.book_credit_payment(t.id, 'other',
                                           case v_kind when 'client_transfer_in' then 'Versement relayé par le client'
                                                       else 'Versement relayé par le cabinet' end, null, 'no_match');
  delete from public.bank_debit_review v where v.bank_transaction_id = t.id;
  v_result := jsonb_build_object('payment_id', v_payment, 'status', 'unmatched');
  perform private.command_record('release_own_credit', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- (redefined from 20261111090000: a client's credit released is a payment too)
create or replace function private.payment_insert_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(n.id::text) into v_bad
  from new_rows n
  join public.bank_transaction t on t.id = n.bank_transaction_id
  join public.bank_statement s on s.id = t.statement_id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
  where t.direction <> 'credit' or s.format <> n.channel
     or not (t.kind in ('debtor_credit', 'batch_unsplit')
             or (t.kind = 'suspected_duplicate' and coalesce(r.decision = 'released'
                                                              and r.released_kind in ('debtor_credit', 'batch_unsplit'),
                                                              false))
             or (coalesce(r.released_kind, t.kind) in ('own_transfer_in', 'client_transfer_in')
                 and exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id
                             offset 0)));
  if v_bad is not null then
    raise exception 'payment %: its bank line is not a debtor credit of a statement in this channel', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- Payouts name their client (founder #10, review fix): the « Nouvel IBAN » flag reads the payouts booked to that IBAN
-- for that client, not any payout of the servicer, and not one that came back. Set on every payout (M2c-4 writes
-- them), on no other kind; what was ordered never changes.
------------------------------------------------------------------------------------------

alter table public.bank_transfer add column client_organization_id uuid references public.organization (id),
  add constraint bank_transfer_payout_client check ((kind = 'payout') = (client_organization_id is not null));
comment on column public.bank_transfer.client_organization_id is 'A payout: the client paid (its payout IBAN).';
create index bank_transfer_payout_iban_idx on public.bank_transfer (client_organization_id, payee_iban)
  where kind = 'payout' and status = 'booked';

-- (redefined from 20261111090000: the client of a payout is the servicer's, and never changes)
create or replace function private.bank_transfer_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'ordered' then
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
    if new.kind = 'payout' and not exists (select 1 from public.organization c where c.id = new.client_organization_id
                                             and c.servicer_organization_id = new.organization_id) then
      raise exception 'bank transfer: a payout goes to a client of the servicer' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.client_organization_id, new.kind, new.debtor_bank_account_id,
      new.creditor_bank_account_id, new.currency,
      new.amount_minor, new.payee_name, new.payee_iban, new.payee_bic, new.end_to_end_id, new.remittance_info,
      new.requested_execution_date, new.reason, new.ordered_by, new.created_at)
     is distinct from
     (old.id, old.organization_id, old.client_organization_id, old.kind, old.debtor_bank_account_id,
      old.creditor_bank_account_id, old.currency,
      old.amount_minor, old.payee_name, old.payee_iban, old.payee_bic, old.end_to_end_id, old.remittance_info,
      old.requested_execution_date, old.reason, old.ordered_by, old.created_at)
     or (old.entry_id is not null and new.entry_id is distinct from old.entry_id)
     or (old.return_entry_id is not null and new.return_entry_id is distinct from old.return_entry_id)
     or (new.status <> old.status and not (
           (old.status = 'ordered' and new.status in ('in_file', 'booked', 'cancelled'))
           or (old.status = 'in_file' and new.status in ('booked', 'cancelled'))
           or (old.status = 'booked' and new.status = 'returned'))) then
    raise exception 'bank transfer %: what was ordered never changes, and its status only moves forward', old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;


------------------------------------------------------------------------------------------
-- Reads for the pages
------------------------------------------------------------------------------------------

-- A client's payout accounts for the client space and the back-office: the IBAN masked for client members (the last
-- four characters), whether a payout of that client was booked to that exact IBAN and did not come back (until then
-- the IBAN is flagged « Nouvel IBAN », founder #10: looked up once per IBAN of the client, by key), who proposed and
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
declare
  v_paid text[];
begin
  if not (exists (select 1 from public.organization o where o.id = p_client_organization_id
                    and o.servicer_organization_id = any (private.money_staff_org_ids()))
          or p_client_organization_id = any (private.client_admin_whole_org_ids())) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_paid := array(select i.iban
                  from (select distinct a.iban from public.client_payout_account a
                        where a.client_organization_id = p_client_organization_id) i
                  cross join lateral (select 1 from public.bank_transfer t
                                      where t.client_organization_id = p_client_organization_id
                                        and t.payee_iban = i.iban and t.kind = 'payout' and t.status = 'booked'
                                      limit 1) t);
  return query
  select a.id, a.currency,
         left(a.iban, 4) || ' •••• •••• ' || right(a.iban, 4), right(a.iban, 4), a.bic, a.holder_name, a.kind,
         a.status, a.proposed_at,
         (select coalesce(u.display_name, u.email) from public.app_user u where u.id = a.proposed_by),
         a.proposed_by = auth.uid(), a.confirmed_at, a.confirmed_via,
         (select coalesce(u.display_name, u.email) from public.app_user u where u.id = a.confirmed_by),
         a.closed_at, a.closed_reason, a.evidence_document_id, a.iban = any (v_paid)
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
  private.registered_client_ibans(uuid), private.complete_batch_confirmation(uuid),
  private.payout_court_appointed(text, uuid), private.stage_refined_kinds(uuid, text[])
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
  public.set_mandate_terms(text, uuid, date, jsonb, text, jsonb, text, uuid, integer, uuid),
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
  public.set_mandate_terms(text, uuid, date, jsonb, text, jsonb, text, uuid, integer, uuid),
  public.set_mandate_insurance_clause(text, uuid, text, text), public.boarding_batch_readiness(uuid),
  public.client_readiness(uuid), public.payout_accounts(uuid), public.confirm_boarding_batch(uuid),
  public.close_bank_account(text, uuid, text)
  to authenticated;
