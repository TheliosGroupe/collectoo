-- M2c-7d-1 « client events, payees and recipients » (plan docs/design/m2c-7-plan.md §6.1 but the withheld kind and the
-- disposition table, §6.2.1, §6.2.3, §6.2.7, §6.2.8's gate and forward, §6.2.10's 7d-1 part, §6.2.12, §6.2.13, §6.3's
-- protection_event_to_qualify and seizure_standing; design docs/design/m2c-remittances.md §13 #9; ADR-0014
-- « M2c-7d-1 »). Forward-only.
--
-- What happens to a client's payouts, payments and letters after an event the servicer records. Every rule the law does
-- not fix is the servicer's default, open with its question (founder Q8, Q10, Q12, Q21; OQ-41, OQ-91, OQ-93, OQ-94):
--   * the events: + curatorship (a payout hold by our rule: C. civ. 2003 names only « la tutelle des majeurs »),
--     claims_declared (the servicer's declaration of its claims, with the documents and amounts it names:
--     public.claims_declared_item), seizure (a saisie-attribution served on the servicer as tiers saisi: CPCE L211-2) and
--     seizure_released (naming the seizure it lifts: refers_to_event_id; one release per seizure); publication_date (the
--     BODACC publication, R622-24); qualified_at, set at insert from now on (added without a default: the rows from
--     before keep null — the old « Tutelle ou curatelle » rows ops qualify, public.qualify_protection_event). The event
--     table stays append-only: who acts for the client (public.client_status_event_representative, the latest row in
--     force) and the qualification of an old row (public.client_status_event_qualification) are side tables;
--   * private.client_event_effective: the one place that says what an event counts as (an old row to qualify, a row
--     qualified as a curatelle counting as nothing: its curatorship event counts);
--   * the payee after each event ([critic] F16, L2, L10; C. civ. 427 al. 5, 1309): estate (a death: the notary's account,
--     or one every heir designates), protected_adult (a tutelle or a curatelle: an account in the client's name, the
--     holder's name compared as the pain.001 writer spells it, private.epc_name_key, or explained), court_appointed (a
--     liquidation, whatever else), client (a mandate end) — the strictest, confirmed by a second admin after the
--     recording of each event, with the authority evidence (payout_authority_evidence); a standing seizure blocks
--     whatever the account ([critic] L14). private.remittance_payout_blockers reads them; codes client_status:<kind>;
--   * after an end of the mandate (a death, a tutelle, a mandate end: private.client_end_event), payments booked on or
--     after it are held client_mandate_ended (private.gate_assignments), forwarded with the reason mandate_ended (no
--     schedule key: no commission) or restored to the payer (founder Q10);
--   * who receives the letters (private.client_addressee; [critic] L12, [check 1] gap 7): after a liquidation, a death or
--     a tutelle the person recorded who acts for the client (C. civ. 473 al. 1, L641-9 I); after a curatelle the client
--     with a copy to its curator (our rule by analogy with 467 al. 3, which governs significations; OQ-94); none while
--     unknown — the repayment request then refuses recipient_unknown (narrowed: a mandate end no longer refuses) and its
--     letter's payload names the addressees;
--   * the nightly: protection_event_to_qualify, seizure_standing (P0 for 15 days).
-- New: the two side tables and public.claims_declared_item (RLS: money staff of the servicer only — the names and
-- addresses are personal data; append-only; change log; insert guards), the commands public.set_client_representative and
-- public.qualify_protection_event, the read public.client_events_view (the client's page), the helpers
-- private.epc_name_key (+ epc_spelled), client_event_effective, client_seizures_standing, client_end_event,
-- client_payee_rule, client_addressee, representative_clean, representative_fits, declared_items, address_lines.
-- Columns for 7d-2 (plan §6.1, written and read from 7d-2): private.remittance_draft.set_off_barred, opening_on; the
-- index remittance_line_repricing_invoice_idx.
-- Redefined, each copied whole from its latest definition across every migration file (indexed: the last
-- `create or replace function` / `create function` of each name wins; the change only; settings, search_path '' and
-- SECURITY DEFINER where they were, grants restated): private.client_payout_account_guard (20261111120000:692),
-- public.propose_payout_account (20261111120000:742, dropped and recreated: two parameters more),
-- private.client_status_event_guard (20261111120000:1031), private.payout_court_appointed (20261111120000:1062),
-- public.record_client_status_event (20261111120000:1076, dropped and recreated: four parameters more),
-- private.remittance_payout_blockers (20261115090000:900), private.gate_assignments (20261109190000:506) and
-- private.allocation_begin (20261109190000:618; the job's gate holds client_mandate_ended too),
-- public.forward_payment (20261109190000:1161), public.register_client_document (20261124090000:2501),
-- private.can_read_client_document_object (20261124090000:2557) with the policy document_client_money_scope
-- (20261124090000:2574), private.run_advance_checks (20261125090000:896, 7c-2's),
-- private.advance_repayment_client_refusal (20261125090000:311), private.advance_repayment_payload
-- (20261125090000:428); the checks client_status_event_kind_check, client_payout_account_kind_check,
-- payment_review_reason_check (20261109190000:30), client_notification_reason_check (20261110120000:442).
-- Review round 1 (ADR-0014 « M2c-7d-1 review fixes »): an old row to qualify holds the payouts whatever account is
-- confirmed (client_payee_rule: 'to_qualify', code client_status:guardianship_to_qualify; MONEY-LAW-1); a letter
-- addressed to the person who acts for the client is not the client's members' to read (MONEY-LAW-2, TUI-3:
-- private.can_read_remittance_document (20261113090000:1537), the policy advance_repayment_request_read
-- (20261125090000:176), public.client_repayment_requests (20261125090000:740) redefined; the index
-- advance_repayment_request_document_idx); the portfolio confirmation gate reads what an event counts as
-- (private.portfolio_confirmation_blockers, 20261111120000:1705; client_protection_to_qualify; TUI-2); the blockers read
-- the payee rule and the seizures only for a client with events (CC-1); an event stamped under the lock (CC-2);
-- lock_timeout 2s on the three event commands (CC-3); client_end_event and client_event_effective executable by
-- service_role (CC-4).
-- The cancellation-after-download switch stays off: nothing here writes private.feature_switch, and no rule here reads it.

------------------------------------------------------------------------------------------
-- The events (plan §6.1)
------------------------------------------------------------------------------------------

alter table public.client_status_event drop constraint client_status_event_kind_check,
  add constraint client_status_event_kind_check check (kind in (
    'proceeding_opened', 'liquidation', 'death', 'guardianship', 'mandate_ended', 'curatorship', 'claims_declared',
    'seizure', 'seizure_released'));
-- [check 2] (gap 6) a release names the seizure it lifts; the BODACC publication of a judgment (R622-24); [critic] L17
-- qualified_at added without a default (the rows from before keep null: no missing value written), then now() for every
-- row recorded from here on (the guard refuses a null)
alter table public.client_status_event
  add column refers_to_event_id uuid references public.client_status_event (id),
  add column publication_date date,
  add column qualified_at timestamptz;
alter table public.client_status_event alter column qualified_at set default now();
alter table public.client_status_event
  add constraint client_status_event_release_refers
    check ((kind = 'seizure_released') = (refers_to_event_id is not null)),
  add constraint client_status_event_publication
    check (publication_date is null
           or (kind in ('proceeding_opened', 'liquidation') and publication_date >= effective_date));
-- one release per seizure, race-safe (two admins releasing one seizure: one row, the other a unique_violation the
-- command maps to release_without_seizure)
create unique index client_status_event_release_uq on public.client_status_event (refers_to_event_id)
  where kind = 'seizure_released';
-- the nightly's reads (their predicates stated literally): a servicer's seizures, its old rows still to qualify
create index client_status_event_seizure_idx on public.client_status_event (organization_id) where kind = 'seizure';
-- a client's seizures (private.client_seizures_standing, read on every blocker check): keyed by the client, so that the
-- servicer's index above is never read whole for one client however stale the statistics
create index client_status_event_client_seizure_idx
  on public.client_status_event (client_organization_id, effective_date) where kind = 'seizure';
create index client_status_event_to_qualify_idx on public.client_status_event (organization_id)
  where kind = 'guardianship' and qualified_at is null;
comment on column public.client_status_event.refers_to_event_id is
  'A seizure_released names the seizure it lifts (one release per seizure).';
comment on column public.client_status_event.publication_date is
  'The BODACC publication of a proceeding''s or a liquidation''s judgment (R622-24: the declarations run from it).';
comment on column public.client_status_event.qualified_at is
  'Set when the row is recorded (from M2c-7d-1); null on the « Tutelle ou curatelle » rows recorded before, to qualify.';

-- the payout accounts' kinds ([critic] L2, L10) and the document that proves who may receive; the explanation of a RIB
-- spelt otherwise than the client's name ([check 1] gap 10), set at insert, never changed (the guard)
alter table public.client_payout_account drop constraint client_payout_account_kind_check,
  add constraint client_payout_account_kind_check check (kind in ('client', 'court_appointed', 'estate', 'protected_adult'));
alter table public.client_payout_account
  add column authority_document_id uuid references public.document (id),
  add column holder_attestation text check (length(btrim(holder_attestation)) between 1 and 500);
-- a client's accounts by its key (the events' page reads them; the plain index the partial ones are not)
create index client_payout_account_client_idx on public.client_payout_account (client_organization_id);

-- (§6.2.8) a payment received after the end of the client's mandate, held for ops
alter table public.payment drop constraint payment_review_reason_check,
  add constraint payment_review_reason_check check (review_reason in (
    'no_match', 'ambiguous', 'overpayment', 'account_not_confirmed', 'no_mandate', 'account_closed',
    'currency_mismatch', 'before_servicing_start', 'hold_blocks_allocation', 'nothing_due',
    'credit_note_to_apply', 'partial_return', 'allocation_reversed', 'client_mandate_ended'));
-- its forward's reason, as the client reads it
alter table public.client_notification drop constraint client_notification_reason_check,
  add constraint client_notification_reason_check check (reason in (
    'hold_blocks_allocation', 'ops_correction', 'file_recalled', 'before_servicing_start', 'client_ratification',
    'bank_return', 'mandate_ended'));

-- (plan §6.1, 7d-2's to write and read: what the prepare assumed, re-checked at approval and before download) and the
-- invoices' birth read of 7d-2 (private.document_born_on)
alter table private.remittance_draft add column set_off_barred text, add column opening_on date;
create index remittance_line_repricing_invoice_idx on public.remittance_line_repricing (invoice_id)
  where invoice_id is not null;

------------------------------------------------------------------------------------------
-- Pure helpers: the name key ([check 1] gap 10, [check 2] gap 4), a representative's shape, an address's lines
------------------------------------------------------------------------------------------

-- The pain.001 writer's spellings (remittance/pain001.py `_SPELLED`): the eight multi-letter ones, then the rest of the
-- map in one translate (ø Ø đ Đ ð Ð ł Ł ı, the four apostrophes, the four dashes, the two no-break spaces)
create function private.epc_spelled(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select translate(replace(replace(replace(replace(replace(replace(replace(replace(p_text,
           'œ', 'oe'), 'Œ', 'OE'), 'æ', 'ae'), 'Æ', 'AE'), 'ß', 'ss'), 'ẞ', 'SS'), 'þ', 'th'), 'Þ', 'TH'),
           'øØđĐðÐłŁı' || chr(8217) || chr(8216) || chr(700) || chr(180) || chr(8211) || chr(8212) || chr(8208)
           || chr(8209) || chr(160) || chr(8239),
           'oOdDdDlLi''''''''----  ');
$$;

-- The name as the pain.001 writer spells it (plan §6.2.7, step by step as pain001.epc_text): the spellings, NFKD, the
-- marks of U+0300–U+036F but U+034F dropped (its combining class is 0: the writer keeps it), the spellings again; null
-- when a character outside Basic Latin is left (another script, another mark): never compared, never a false match;
-- upper-cased, every run of characters outside A–Z and 0–9 one space, trimmed (no length cut); null when nothing is
-- left. Twin: remittance.pain001.name_key (test_name_key_parity_integration.py).
create function private.epc_name_key(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when s ~ '[^\x01-\x7f]' then null
              else nullif(btrim(regexp_replace(upper(s), '[^A-Z0-9]+', ' ', 'g')), '') end
  from (select private.epc_spelled(regexp_replace(normalize(private.epc_spelled(p_name), nfkd),
                                                  '[̀-͎͐-ͯ]', '', 'g')) as s) x;
$$;

-- Who acts for the client ([check 1] gap 3): {role, name (1–140), address_lines (1–4 of 1–70)}, nothing else, trimmed;
-- null when it is not that shape
create function private.representative_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_lines jsonb := '[]';
  l jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object'
     or (select array_agg(k order by k) from jsonb_object_keys(p) k) <> array['address_lines', 'name', 'role']
     or jsonb_typeof(p -> 'role') <> 'string'
     or p ->> 'role' not in ('notary', 'heirs', 'tutor', 'curator', 'liquidator', 'administrator')
     or jsonb_typeof(p -> 'name') <> 'string' or length(btrim(p ->> 'name')) not between 1 and 140
     or jsonb_typeof(p -> 'address_lines') <> 'array' or jsonb_array_length(p -> 'address_lines') not between 1 and 4 then
    return null;
  end if;
  for l in select x from jsonb_array_elements(p -> 'address_lines') x loop
    if jsonb_typeof(l) <> 'string' or length(btrim(l #>> '{}')) not between 1 and 70 then
      return null;
    end if;
    v_lines := v_lines || to_jsonb(btrim(l #>> '{}'));
  end loop;
  return jsonb_build_object('role', p ->> 'role', 'name', btrim(p ->> 'name'), 'address_lines', v_lines);
end;
$$;

-- The roles each event takes: notary or heirs for a death, tutor for a tutelle, curator for a curatelle, liquidator for
-- a liquidation, administrator for a proceeding
create function private.representative_fits(p_kind text, p_role text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(case p_kind when 'death' then p_role in ('notary', 'heirs')
                              when 'guardianship' then p_role = 'tutor'
                              when 'curatorship' then p_role = 'curator'
                              when 'liquidation' then p_role = 'liquidator'
                              when 'proceeding_opened' then p_role = 'administrator' end, false);
$$;

-- A billing address's lines (line1, line2, postcode and city, the country outside France)
create function private.address_lines(p_address jsonb)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array_remove(array[nullif(p_address ->> 'line1', ''), nullif(p_address ->> 'line2', ''),
                            nullif(btrim(coalesce(p_address ->> 'postcode', '') || ' ' || coalesce(p_address ->> 'city', '')), ''),
                            case when coalesce(p_address ->> 'country', 'FR') <> 'FR' then p_address ->> 'country' end],
                      null);
$$;

------------------------------------------------------------------------------------------
-- The side tables ([check 1] gap 3, [critic] L8): append-only, money staff only, logged
------------------------------------------------------------------------------------------

-- Who acts for the client after an event (the notary or the heirs, the tutor, the curator, the liquidator, the
-- administrator): its name and address are personal data, stored as the plan lists them and nothing more. The one in
-- force is the event's latest row; a correction is a new row, the history kept.
create table public.client_status_event_representative (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  event_id uuid not null references public.client_status_event (id),
  representative jsonb not null check (private.representative_clean(representative) = representative),
  evidence_document_id uuid not null references public.document (id),
  recorded_by uuid not null references public.app_user (id),
  recorded_at timestamptz not null default clock_timestamp()
);
create index client_status_event_representative_event_idx on public.client_status_event_representative
  (event_id, recorded_at desc);
comment on table public.client_status_event_representative is
  'Who acts for the client after an event (append-only; the latest row of an event is in force). Personal data.';

-- an event of that client and servicer that takes a representative of that role; the evidence a document of that client
-- (the event's, or the authority evidence)
create function private.client_status_event_representative_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.client_status_event e
                 where e.id = new.event_id and e.organization_id = new.organization_id
                   and e.client_organization_id = new.client_organization_id
                   and private.representative_fits(private.client_event_effective(e.id),
                                                   new.representative ->> 'role'))
     or not (private.client_document_of(new.evidence_document_id, new.client_organization_id, 'client_status_evidence')
             or private.client_document_of(new.evidence_document_id, new.client_organization_id,
                                           'payout_authority_evidence')) then
    raise exception 'client representative: an event of the client that takes this role, with its evidence'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger client_status_event_representative_guard before insert on public.client_status_event_representative
  for each row execute function private.client_status_event_representative_guard();
alter table public.client_status_event_representative enable always trigger client_status_event_representative_guard;
create trigger client_status_event_representative_append_only before update or delete or truncate
  on public.client_status_event_representative for each statement execute function private.refuse_change();
alter table public.client_status_event_representative enable always trigger client_status_event_representative_append_only;
create trigger client_status_event_representative_change_log after insert or update or delete
  on public.client_status_event_representative for each row execute function private.log_change();

-- ([critic] L17) What an old « Tutelle ou curatelle » row was: a tutelle, or a curatelle (then the curatorship event
-- recorded with it counts instead). One per old row.
create table public.client_status_event_qualification (
  event_id uuid primary key references public.client_status_event (id),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  kind text not null check (kind in ('guardianship', 'curatorship')),
  curatorship_event_id uuid references public.client_status_event (id),
  evidence_document_id uuid not null references public.document (id),
  recorded_by uuid not null references public.app_user (id),
  recorded_at timestamptz not null default clock_timestamp(),
  constraint client_status_event_qualification_curatorship
    check ((kind = 'curatorship') = (curatorship_event_id is not null))
);
comment on table public.client_status_event_qualification is
  'An old « Tutelle ou curatelle » row said to be a tutelle or a curatelle (append-only, its evidence kept).';

create function private.client_status_event_qualification_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.client_status_event e
                 where e.id = new.event_id and e.kind = 'guardianship' and e.qualified_at is null
                   and e.organization_id = new.organization_id and e.client_organization_id = new.client_organization_id)
     or (new.curatorship_event_id is not null and not exists (
           select 1 from public.client_status_event e
           where e.id = new.curatorship_event_id and e.kind = 'curatorship'
             and e.client_organization_id = new.client_organization_id))
     or not private.client_document_of(new.evidence_document_id, new.client_organization_id,
                                       'client_status_evidence') then
    raise exception 'protection qualification: an old guardianship row of the client, its curatorship event, its evidence'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger client_status_event_qualification_guard before insert on public.client_status_event_qualification
  for each row execute function private.client_status_event_qualification_guard();
alter table public.client_status_event_qualification enable always trigger client_status_event_qualification_guard;
create trigger client_status_event_qualification_append_only before update or delete or truncate
  on public.client_status_event_qualification for each statement execute function private.refuse_change();
alter table public.client_status_event_qualification enable always trigger client_status_event_qualification_append_only;
create trigger client_status_event_qualification_change_log after insert or update or delete
  on public.client_status_event_qualification for each row execute function private.log_change('event_id');

-- ([critic] L8, [check 2]) The documents a declaration of claims names, each with its amount (7d-3's claims_to_declare
-- reads them)
create table public.claims_declared_item (
  event_id uuid not null references public.client_status_event (id),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  document_kind text not null check (document_kind in ('invoice', 'advance')),
  document_id uuid not null,
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  primary key (event_id, document_kind, document_id)
);
comment on table public.claims_declared_item is
  'The invoices and advances a declaration of the servicer''s claims names, with their amounts (append-only).';

create function private.claims_declared_item_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.client_status_event e
                 where e.id = new.event_id and e.kind = 'claims_declared' and e.organization_id = new.organization_id
                   and e.client_organization_id = new.client_organization_id)
     or (new.document_kind = 'invoice' and not exists (
           select 1 from public.commission_invoice i where i.id = new.document_id
             and i.client_organization_id = new.client_organization_id and i.kind = 'invoice'))
     or (new.document_kind = 'advance' and not exists (
           select 1 from public.client_advance a where a.id = new.document_id
             and a.client_organization_id = new.client_organization_id)) then
    raise exception 'claims declared: a declaration of the client naming an invoice or an advance of that client'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger claims_declared_item_guard before insert on public.claims_declared_item
  for each row execute function private.claims_declared_item_guard();
alter table public.claims_declared_item enable always trigger claims_declared_item_guard;
create trigger claims_declared_item_append_only before update or delete or truncate on public.claims_declared_item
  for each statement execute function private.refuse_change();
alter table public.claims_declared_item enable always trigger claims_declared_item_append_only;
create trigger claims_declared_item_change_log after insert or update or delete on public.claims_declared_item
  for each row execute function private.log_change('event_id', 'document_kind', 'document_id');

alter table public.client_status_event_representative enable row level security;
alter table public.client_status_event_qualification enable row level security;
alter table public.claims_declared_item enable row level security;
revoke all on public.client_status_event_representative, public.client_status_event_qualification,
  public.claims_declared_item from public, anon, authenticated;
grant select on public.client_status_event_representative, public.client_status_event_qualification,
  public.claims_declared_item to authenticated;
-- money staff of the servicer only: never the client's users, its restricted viewers or a collector
create policy client_status_event_representative_read on public.client_status_event_representative for select
  to authenticated using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy client_status_event_qualification_read on public.client_status_event_qualification for select
  to authenticated using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy claims_declared_item_read on public.claims_declared_item for select
  to authenticated using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));

------------------------------------------------------------------------------------------
-- What an event counts as; standing seizures; the end of the mandate; the payee; the addressees (plan §6.1–§6.2.12)
------------------------------------------------------------------------------------------

-- ([critic] L17, [check 1]) The kind an event counts as — the one place every reader asks: its kind; for a guardianship,
-- 'guardianship' when recorded from 7d-1 on (qualified_at set) or qualified as a tutelle, null when qualified as a
-- curatelle (its curatorship event counts instead), 'guardianship_to_qualify' for an old « Tutelle ou curatelle » row
-- not yet qualified (payouts held whatever the account, and — review round 1 — its own reason at the portfolio
-- confirmation gate; no mandate end, no addressee). The event by its key, its qualification by its key.
create function private.client_event_effective(p_event_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case when e.kind <> 'guardianship' then e.kind
              when q.kind = 'curatorship' then null
              when q.kind = 'guardianship' or e.qualified_at is not null then 'guardianship'
              else 'guardianship_to_qualify' end
  from (select x.id, x.kind, x.qualified_at from public.client_status_event x where x.id = p_event_id offset 0) e
  left join lateral (select y.kind from public.client_status_event_qualification y where y.event_id = e.id offset 0) q
    on true;
$$;

-- ([check 2] gap 6) The seizures of a client standing on p_on: effective by then, and no release naming it effective by
-- then. The one place that reads « standing » — the blockers, the client's users' rights over its accounts, the nightly,
-- the events' page (7d-2: the set-off bar and the approval). The client's seizures by
-- client_status_event_client_seizure_idx (its predicate stated literally), each one's release by
-- client_status_event_release_uq — a probe per seizure (the offset 0 keeps the NOT EXISTS a correlated probe: an
-- anti-join could read the release index whole).
create function private.client_seizures_standing(p_client_organization_id uuid, p_on date)
returns setof uuid
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select s.id
  from (select e.id from public.client_status_event e
        where e.client_organization_id = p_client_organization_id and e.effective_date <= p_on and e.kind = 'seizure'
        offset 0) s
  where not exists (select 1 from public.client_status_event r
                    where r.refers_to_event_id = s.id and r.kind = 'seizure_released' and r.effective_date <= p_on
                    offset 0);
$$;

-- (§6.2.3) The end of the client's mandate on or before p_on (C. civ. 2003: « la mort, la tutelle des majeurs », a
-- revocation or a renunciation — a mandate_ended), the earliest, with when the servicer recorded it (2008: what it did
-- before is valid). A curatelle, a proceeding or a liquidation is no end (L622-13 I, L641-11-1 I); an old row still to
-- qualify, or qualified as a curatelle, is none (client_event_effective).
create function private.client_end_event(p_client_organization_id uuid, p_on date)
returns table (event_id uuid, kind text, effective_date date, recorded_at timestamptz)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select e.id, k.kind, e.effective_date, e.recorded_at
  from (select x.id, x.effective_date, x.recorded_at from public.client_status_event x
        where x.client_organization_id = p_client_organization_id and x.effective_date <= p_on
          and x.kind in ('death', 'guardianship', 'mandate_ended') offset 0) e
  cross join lateral (select private.client_event_effective(e.id) as kind) k
  where k.kind in ('death', 'guardianship', 'mandate_ended')
  order by e.effective_date, e.recorded_at, e.id
  limit 1;
$$;

-- (§6.2.7; [critic] F16) The payee the client's events in effect on p_on require, the strictest of them: a liquidation
-- the liquidator's account whatever else (court_appointed: L641-9 I), else a death the estate's (the notary's, or one
-- every heir designates: founder Q8, C. civ. 1309), else a tutelle or a curatelle an account in the client's name
-- (protected_adult: C. civ. 427 al. 5), else a mandate end the client's own re-confirmed; the event that requires it
-- (the earliest of that kind) and the latest recording among them all (the account is confirmed after it). No row:
-- nothing required. A proceeding opened requires nothing (L622-13 I: the contract goes on). (Review round 1,
-- MONEY-LAW-1; plan §6.1, §6.2.13 « until then the row keeps today's effect (payouts held) ») an old « Tutelle ou
-- curatelle » row still to qualify requires 'to_qualify', a kind no payout account has: the payouts stay held,
-- whatever account is confirmed, until ops qualify it (before 7d-1 no account lifted such a row's hold) — its code
-- client_status:guardianship_to_qualify, first whatever else is in effect.
create function private.client_payee_rule(p_client_organization_id uuid, p_on date)
returns table (kind text, event_kind text, known_at timestamptz)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with ev as (
    select e.id, e.effective_date, e.recorded_at, k.kind,
           case k.kind when 'guardianship_to_qualify' then 5 when 'liquidation' then 4 when 'death' then 3
                       when 'mandate_ended' then 1 else 2 end as rank
    from (select x.id, x.effective_date, x.recorded_at from public.client_status_event x
          where x.client_organization_id = p_client_organization_id and x.effective_date <= p_on
            and x.kind in ('liquidation', 'death', 'guardianship', 'curatorship', 'mandate_ended') offset 0) e
    cross join lateral (select private.client_event_effective(e.id) as kind) k
    where k.kind in ('liquidation', 'death', 'guardianship', 'guardianship_to_qualify', 'curatorship', 'mandate_ended'))
  select case max(ev.rank) when 5 then 'to_qualify' when 4 then 'court_appointed' when 3 then 'estate'
                           when 2 then 'protected_adult' else 'client' end,
         (array_agg(ev.kind order by ev.rank desc, ev.effective_date, ev.recorded_at, ev.id))[1],
         max(ev.recorded_at)
  from ev
  having count(*) > 0;
$$;

-- ([critic] L12, [check 1] gap 7) Who receives the client's letters on p_on: the event that governs — a liquidation
-- (L641-9 I), else a death, else a tutelle (C. civ. 473 al. 1: « le tuteur la représente dans tous les actes de la vie
-- civile »), else a curatelle, the earliest of its kind (our order) — and its representative in force (its latest row):
-- the liquidator, the notary or the heirs, the tutor, one row; after a curatelle the client at its billing address and
-- its curator in copy (440 al. 1: the curator assists, it does not represent; the copy is our rule by analogy with 467
-- al. 3, which governs significations: OQ-94); no event: the client. No row while the governing event has nobody
-- recorded, or is an old row still to qualify (the letter would go to the wrong person).
create function private.client_addressee(p_client_organization_id uuid, p_on date)
returns table (role text, name text, address_lines text[], copy boolean)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with ev as (
    select e.id, e.effective_date, e.recorded_at, k.kind,
           case k.kind when 'liquidation' then 1 when 'death' then 2 when 'curatorship' then 4 else 3 end as rank
    from (select x.id, x.effective_date, x.recorded_at from public.client_status_event x
          where x.client_organization_id = p_client_organization_id and x.effective_date <= p_on
            and x.kind in ('liquidation', 'death', 'guardianship', 'curatorship') offset 0) e
    cross join lateral (select private.client_event_effective(e.id) as kind) k
    where k.kind in ('liquidation', 'death', 'guardianship', 'guardianship_to_qualify', 'curatorship')),
  gov as (select ev.id, ev.kind from ev order by ev.rank, ev.effective_date, ev.recorded_at, ev.id limit 1),
  rep as (select g.kind, r.representative
          from gov g
          cross join lateral (select x.representative from public.client_status_event_representative x
                              where x.event_id = g.id order by x.recorded_at desc, x.id desc limit 1) r),
  cl as (select o.legal_name, coalesce(b.billing_address, b.registered_office) as address
         from public.organization o left join public.billing_identity b on b.organization_id = o.id
         where o.id = p_client_organization_id)
  select 'client'::text, cl.legal_name, private.address_lines(cl.address), false
  from cl where not exists (select 1 from gov) or exists (select 1 from rep where rep.kind = 'curatorship')
  union all
  select rep.representative ->> 'role', rep.representative ->> 'name',
         array(select jsonb_array_elements_text(rep.representative -> 'address_lines')),
         rep.kind = 'curatorship'
  from rep where rep.kind in ('liquidation', 'death', 'guardianship', 'curatorship');
$$;

-- ([critic] L8, [check 2]) A declaration's items, checked: 1–200 objects {document_kind invoice | advance, document_id,
-- amount_minor (text, > 0)}, each an invoice (never a credit note) or an advance of this client, none twice; null
-- otherwise (not_declarable). Each document by its key.
create function private.declared_items(p_client_organization_id uuid, p_declared jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v jsonb := '[]';
  x jsonb;
  v_kind text;
  v_id uuid;
  v_amount bigint;
begin
  if p_declared is null or jsonb_typeof(p_declared) <> 'array' or jsonb_array_length(p_declared) not between 1 and 200 then
    return null;
  end if;
  for x in select y from jsonb_array_elements(p_declared) y loop
    if jsonb_typeof(x) <> 'object' then
      return null;
    end if;
    v_kind := x ->> 'document_kind';
    if v_kind is null or v_kind not in ('invoice', 'advance')
       or coalesce(x ->> 'document_id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(x ->> 'amount_minor', '') !~ '^[0-9]{1,16}$' then
      return null;
    end if;
    v_id := (x ->> 'document_id')::uuid;
    v_amount := (x ->> 'amount_minor')::bigint;
    if v_amount <= 0 or v_amount > 1000000000000000
       or (v_kind = 'invoice' and not exists (select 1 from public.commission_invoice i where i.id = v_id
                                                and i.client_organization_id = p_client_organization_id
                                                and i.kind = 'invoice'))
       or (v_kind = 'advance' and not exists (select 1 from public.client_advance a where a.id = v_id
                                                and a.client_organization_id = p_client_organization_id))
       or v @> jsonb_build_array(jsonb_build_object('document_kind', v_kind, 'document_id', v_id)) then
      return null;
    end if;
    v := v || jsonb_build_array(jsonb_build_object('document_kind', v_kind, 'document_id', v_id,
                                                   'amount_minor', v_amount::text));
  end loop;
  return v;
end;
$$;

------------------------------------------------------------------------------------------
-- The events' guard and the payout accounts' (redefined)
------------------------------------------------------------------------------------------

-- private.client_status_event_guard, redefined from 20261111120000_identities_terms.sql (line 1031; same signature and
-- settings, its grants restated below). M2c-7d-1 ([critic] L17, [check 1], [check 2] gap 6): qualified_at set at insert;
-- a release names a seizure of the same client and servicer, effective on or before it. Nothing else changes.
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
  -- (M2c-7d-1, [critic] L17, [check 1]) every row recorded from 7d-1 on says when it was qualified (the column's
  -- default); the rows from before keep null (an old « Tutelle ou curatelle » to qualify)
  if new.qualified_at is null then
    raise exception 'client event: qualified_at is set when the event is recorded' using errcode = 'check_violation';
  end if;
  -- ([check 2] gap 6) a release names a seizure of the same client and servicer, effective on or before it
  if new.kind = 'seizure_released' and not exists (
       select 1 from public.client_status_event s
       where s.id = new.refers_to_event_id and s.kind = 'seizure'
         and s.client_organization_id = new.client_organization_id and s.organization_id = new.organization_id
         and s.effective_date <= new.effective_date) then
    raise exception 'client event: a release names a seizure of the client, on or before it'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

-- private.client_payout_account_guard, redefined from 20261111120000_identities_terms.sql (line 692; same signature and
-- settings, its grants restated below). M2c-7d-1: the authority evidence a document of that client of its kind; it and
-- the holder's explanation never change once proposed. Nothing else changes.
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
    -- (M2c-7d-1) the authority evidence, when given, is a document of that client of its kind
    if new.authority_document_id is not null
       and not private.client_document_of(new.authority_document_id, new.client_organization_id,
                                          'payout_authority_evidence') then
      raise exception 'payout account: the authority evidence is a document of that client'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.client_organization_id, new.currency, new.iban, new.bic, new.holder_name,
      new.evidence_document_id, new.kind, new.proposed_by, new.proposed_at, new.created_at,
      new.authority_document_id, new.holder_attestation)
     is distinct from
     (old.id, old.organization_id, old.client_organization_id, old.currency, old.iban, old.bic, old.holder_name,
      old.evidence_document_id, old.kind, old.proposed_by, old.proposed_at, old.created_at,
      old.authority_document_id, old.holder_attestation)
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

-- private.payout_court_appointed, redefined from 20261111120000_identities_terms.sql (line 1062; same signature, its
-- grants restated below; + `set enable_seqscan = off`: the client's events by its key whatever the statistics).
-- M2c-7d-1 (plan §6.2.7): the client's own users act on no account of an estate, a protected adult or a court-appointed
-- payee, nor on any account of a client with a death, a tutelle (qualified or not), a curatelle or a mandate end recorded,
-- or a seizure standing today — a second admin of the servicer does (their own rights may have ended: C. civ. 2003; the
-- servicer's rule, OQ-41, OQ-93, OQ-94). Nothing else changes.
create or replace function private.payout_court_appointed(p_kind text, p_client_organization_id uuid)
returns boolean
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select p_kind in ('court_appointed', 'estate', 'protected_adult')
      or exists (select 1 from public.client_status_event e
                 where e.client_organization_id = p_client_organization_id
                   and (e.kind in ('liquidation', 'death', 'guardianship', 'curatorship', 'mandate_ended')
                        or e.payout_account_id is not null))
      or exists (select 1 from private.client_seizures_standing(p_client_organization_id, private.paris_today()));
$$;

------------------------------------------------------------------------------------------
-- The commands
------------------------------------------------------------------------------------------

-- public.record_client_status_event (« Enregistrer un événement »), dropped and recreated from
-- 20261111120000_identities_terms.sql (line 1076; four parameters more, last and defaulted; + `set enable_seqscan =
-- off`; + (review round 1, CC-3) `set lock_timeout = '2s'`, as the other commands on the payout_accounts: lock; its
-- grants restated below). M2c-7d-1 (plan §6.2.1): the new kinds; the BODACC publication date
-- (bad_publication_date); a release names its seizure under the payout_accounts: lock (release_without_seizure, the
-- unique index the backstop; refers_to_not_allowed otherwise); a declaration with its items (not_declarable,
-- claims_declared_without_proceeding); who acts for the client, given with the event (its first side-table row; the
-- refusals of set_client_representative). The event row is only ever inserted.
drop function public.record_client_status_event(text, uuid, text, date, uuid, text, uuid);
create function public.record_client_status_event(p_idempotency_key text, p_client_organization_id uuid,
                                                             p_kind text, p_effective_date date,
                                                             p_evidence_document_id uuid, p_note text,
                                                             p_payout_account_id uuid default null,
                                                             p_publication_date date default null,
                                                             p_representative jsonb default null,
                                                             p_refers_to uuid default null,
                                                             p_declared jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
set lock_timeout = '2s'
as $$
declare
  c public.organization;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_request jsonb := jsonb_build_object('client_organization_id', p_client_organization_id, 'kind', p_kind,
                                        'effective_date', p_effective_date,
                                        'evidence_document_id', p_evidence_document_id,
                                        'note', nullif(btrim(coalesce(p_note, '')), ''),
                                        'payout_account_id', p_payout_account_id,
                                        'publication_date', p_publication_date,
                                        'representative', p_representative, 'refers_to', p_refers_to,
                                        'declared', p_declared);
  v_result jsonb;
  v_id uuid;
  v_rep jsonb;
  v_rep_id uuid;
  v_items jsonb;
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
  if p_kind is null or p_kind not in ('proceeding_opened', 'liquidation', 'death', 'guardianship', 'mandate_ended',
                                     'curatorship', 'claims_declared', 'seizure', 'seizure_released') then
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
  -- (M2c-7d-1, plan §6.2.1) the BODACC publication of a judgment (R622-24: the declarations' two months run from it)
  if p_publication_date is not null
     and (p_kind not in ('proceeding_opened', 'liquidation') or p_publication_date < p_effective_date
          or p_publication_date > private.paris_today()) then
    raise exception 'client event refused: bad_publication_date' using errcode = 'check_violation';
  end if;
  -- ([check 2] gap 6) only a release names another event: the seizure it lifts
  if p_refers_to is not null and p_kind <> 'seizure_released' then
    raise exception 'client event refused: refers_to_not_allowed' using errcode = 'check_violation';
  end if;
  if p_kind = 'seizure_released' and p_refers_to is null then
    raise exception 'client event refused: release_without_seizure' using errcode = 'check_violation';
  end if;
  -- ([critic] L8, [check 2]) a declaration names its documents and amounts; nothing else does
  if (p_kind = 'claims_declared') <> (p_declared is not null) then
    raise exception 'client event refused: not_declarable' using errcode = 'check_violation';
  end if;
  if p_kind = 'claims_declared' and not exists (
       select 1 from public.client_status_event e
       where e.client_organization_id = c.id and e.kind in ('proceeding_opened', 'liquidation')
         and e.effective_date <= p_effective_date) then
    raise exception 'client event refused: claims_declared_without_proceeding' using errcode = 'check_violation';
  end if;
  if p_kind = 'claims_declared' then
    v_items := private.declared_items(c.id, p_declared);
    if v_items is null then
      raise exception 'client event refused: not_declarable' using errcode = 'check_violation';
    end if;
  end if;
  -- ([check 1] gap 3) who acts for the client, given with the event (its first row in the side table)
  if p_representative is not null then
    if p_kind not in ('death', 'guardianship', 'curatorship', 'liquidation', 'proceeding_opened') then
      raise exception 'client event refused: not_an_event_with_representative' using errcode = 'check_violation';
    end if;
    v_rep := private.representative_clean(p_representative);
    if v_rep is null then
      raise exception 'client event refused: bad_representative' using errcode = 'check_violation';
    end if;
    if not private.representative_fits(p_kind, v_rep ->> 'role') then
      raise exception 'client event refused: role_mismatch' using errcode = 'check_violation';
    end if;
  end if;
  -- the lock the payout-account decisions take: a client's confirmation or refusal in flight sees the event, or
  -- finishes before it is recorded (private.payout_court_appointed)
  perform pg_advisory_xact_lock(hashtext('payout_accounts:' || c.servicer_organization_id::text));
  -- ([check 2] gap 6) under that lock: the seizure named is the client's, effective on or before the release, and not
  -- released yet (client_status_event_release_uq is the backstop: its unique_violation is the same refusal)
  if p_kind = 'seizure_released' and not exists (
       select 1 from public.client_status_event s
       where s.id = p_refers_to and s.kind = 'seizure' and s.client_organization_id = c.id
         and s.organization_id = c.servicer_organization_id and s.effective_date <= p_effective_date
         and not exists (select 1 from public.client_status_event r
                         where r.refers_to_event_id = s.id and r.kind = 'seizure_released')) then
    raise exception 'client event refused: release_without_seizure' using errcode = 'check_violation';
  end if;
  -- (review round 1, CC-2) stamped now that it holds the lock, not at its transaction's start: a confirmation that took
  -- the lock first (and so never saw this event) is before it, and does not count as confirmed after it
  begin
    insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                            evidence_document_id, payout_account_id, note, recorded_by,
                                            publication_date, refers_to_event_id, recorded_at)
    values (c.servicer_organization_id, c.id, p_kind, p_effective_date, p_evidence_document_id, p_payout_account_id,
            v_note, auth.uid(), p_publication_date, p_refers_to, clock_timestamp())
    returning id into v_id;
  exception when unique_violation then
    raise exception 'client event refused: release_without_seizure' using errcode = 'check_violation';
  end;
  v_result := jsonb_build_object('client_status_event_id', v_id);
  if v_rep is not null then
    insert into public.client_status_event_representative (organization_id, client_organization_id, event_id,
                                                           representative, evidence_document_id, recorded_by)
    values (c.servicer_organization_id, c.id, v_id, v_rep, p_evidence_document_id, auth.uid())
    returning id into v_rep_id;
    v_result := v_result || jsonb_build_object('representative_id', v_rep_id);
  end if;
  if v_items is not null then
    insert into public.claims_declared_item (event_id, organization_id, client_organization_id, document_kind,
                                             document_id, amount_minor)
    select v_id, c.servicer_organization_id, c.id, x ->> 'document_kind', (x ->> 'document_id')::uuid,
           (x ->> 'amount_minor')::bigint
    from jsonb_array_elements(v_items) x;
    v_result := v_result || jsonb_build_object('declared', jsonb_array_length(v_items));
  end if;
  perform private.command_record('record_client_status_event', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- ([check 1] gap 3) « Personne qui agit pour le client » (admin at aal2): a new row for an event that takes one (a death:
-- the notary or the heirs; a tutelle: the tutor; a curatelle: the curator; a liquidation: the liquidator; a proceeding:
-- the administrator), with its evidence (the event's kind or the authority evidence, of that client); the latest row is
-- in force, the history kept. Refusals « client representative refused: <code> »: not_an_event_with_representative,
-- bad_representative, role_mismatch, evidence_required. Returns {representative_id, event_id}. (Review round 1, CC-3)
-- lock_timeout 2s, as the commands beside it (it takes no advisory lock).
create function public.set_client_representative(p_idempotency_key text, p_event_id uuid, p_representative jsonb,
                                                 p_evidence_document_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
set lock_timeout = '2s'
as $$
declare
  e public.client_status_event;
  v_request jsonb := jsonb_build_object('event_id', p_event_id, 'representative', p_representative,
                                        'evidence_document_id', p_evidence_document_id);
  v_result jsonb;
  v_kind text;
  v_rep jsonb;
  v_id uuid;
begin
  select * into e from public.client_status_event where id = p_event_id;
  if not found or not private.has_role(e.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('set_client_representative', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  v_kind := private.client_event_effective(e.id);
  if v_kind is null or v_kind not in ('death', 'guardianship', 'curatorship', 'liquidation', 'proceeding_opened') then
    raise exception 'client representative refused: not_an_event_with_representative' using errcode = 'check_violation';
  end if;
  v_rep := private.representative_clean(p_representative);
  if v_rep is null then
    raise exception 'client representative refused: bad_representative' using errcode = 'check_violation';
  end if;
  if not private.representative_fits(v_kind, v_rep ->> 'role') then
    raise exception 'client representative refused: role_mismatch' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not (private.client_document_of(p_evidence_document_id, e.client_organization_id, 'client_status_evidence')
             or private.client_document_of(p_evidence_document_id, e.client_organization_id,
                                           'payout_authority_evidence')) then
    raise exception 'client representative refused: evidence_required' using errcode = 'check_violation';
  end if;
  insert into public.client_status_event_representative (organization_id, client_organization_id, event_id,
                                                         representative, evidence_document_id, recorded_by)
  values (e.organization_id, e.client_organization_id, e.id, v_rep, p_evidence_document_id, auth.uid())
  returning id into v_id;
  v_result := jsonb_build_object('representative_id', v_id, 'event_id', e.id);
  perform private.command_record('set_client_representative', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- ([critic] L17, §6.2.13) « Préciser : tutelle ou curatelle » (admin at aal2), once per « Tutelle ou curatelle » row
-- recorded before 7d-1 (qualified_at null). No UPDATE (the event table is append-only): its qualification row, and for a
-- curatelle a curatorship event (same client, effective date and evidence; qualified_at set) whose id it keeps — from
-- then the old row counts as that kind (private.client_event_effective). Refusals « protection qualification refused:
-- <code> »: bad_kind, not_an_old_guardianship, evidence_required (the judgment, a status evidence of that client),
-- already_qualified (under the payout_accounts: lock; the primary key the backstop). Returns {event_id, kind,
-- curatorship_event_id}. (Review round 1, CC-3) that lock waited for 2 s at most (lock_timeout).
create function public.qualify_protection_event(p_idempotency_key text, p_event_id uuid, p_kind text,
                                                p_evidence_document_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
set lock_timeout = '2s'
as $$
declare
  e public.client_status_event;
  v_request jsonb := jsonb_build_object('event_id', p_event_id, 'kind', p_kind,
                                        'evidence_document_id', p_evidence_document_id);
  v_result jsonb;
  v_cu uuid;
begin
  select * into e from public.client_status_event where id = p_event_id;
  if not found or not private.has_role(e.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('qualify_protection_event', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_kind is null or p_kind not in ('guardianship', 'curatorship') then
    raise exception 'protection qualification refused: bad_kind' using errcode = 'check_violation';
  end if;
  if e.kind <> 'guardianship' or e.qualified_at is not null then
    raise exception 'protection qualification refused: not_an_old_guardianship' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, e.client_organization_id, 'client_status_evidence') then
    raise exception 'protection qualification refused: evidence_required' using errcode = 'check_violation';
  end if;
  perform pg_advisory_xact_lock(hashtext('payout_accounts:' || e.organization_id::text));
  if exists (select 1 from public.client_status_event_qualification q where q.event_id = e.id) then
    raise exception 'protection qualification refused: already_qualified' using errcode = 'check_violation';
  end if;
  -- (review round 1, CC-2) the curatorship event stamped under the lock, as « Enregistrer un événement » stamps one
  if p_kind = 'curatorship' then
    insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                            evidence_document_id, note, recorded_by, recorded_at)
    values (e.organization_id, e.client_organization_id, 'curatorship', e.effective_date, e.evidence_document_id,
            e.note, auth.uid(), clock_timestamp())
    returning id into v_cu;
  end if;
  insert into public.client_status_event_qualification (event_id, organization_id, client_organization_id, kind,
                                                        curatorship_event_id, evidence_document_id, recorded_by)
  values (e.id, e.organization_id, e.client_organization_id, p_kind, v_cu, p_evidence_document_id, auth.uid());
  v_result := jsonb_build_object('event_id', e.id, 'kind', p_kind, 'curatorship_event_id', v_cu);
  perform private.command_record('qualify_protection_event', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- public.propose_payout_account (« Proposer un IBAN de reversement »), dropped and recreated from
-- 20261111120000_identities_terms.sql (line 742; two parameters more, last and defaulted; its grants restated below).
-- M2c-7d-1 (plan §6.2.7; [critic] L2, L10, [check 1] gap 10): the kinds estate and protected_adult and the authority
-- evidence (estate_without_death, protected_adult_without_measure, authority_evidence_required — estate,
-- protected_adult, court_appointed —, holder_not_client, bad_attestation). Nothing else changes.
drop function public.propose_payout_account(text, uuid, text, text, text, text, uuid, text);
create function public.propose_payout_account(p_idempotency_key text, p_client_organization_id uuid,
                                                         p_currency text, p_iban text, p_holder_name text,
                                                         p_bic text, p_evidence_document_id uuid,
                                                         p_kind text default 'client',
                                                         p_authority_document_id uuid default null,
                                                         p_holder_attestation text default null)
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
  v_att text := nullif(btrim(coalesce(p_holder_attestation, '')), '');
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
                                  'kind', p_kind, 'authority_document_id', p_authority_document_id,
                                  'holder_attestation', v_att);
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
  if p_kind is null or p_kind not in ('client', 'court_appointed', 'estate', 'protected_adult') then
    raise exception 'payout account: invalid kind' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.currency where code = p_currency) then
    raise exception 'unsupported currency' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, c.id, 'payout_rib') then
    raise exception 'payout account: the client''s RIB is required' using errcode = 'check_violation';
  end if;
  -- (M2c-7d-1, plan §6.2.7; [critic] L2, L10, [check 1] gap 10; founder Q8, Q21) the payee after an event: an estate's
  -- account (the notary's, or one every heir designates) needs a death recorded; a protected adult's account a tutelle
  -- or a curatelle, and the client's name as the writer spells it (C. civ. 427 al. 5: « au moyen des comptes ouverts
  -- au nom de celle-ci ») unless the RIB's other spelling is explained (checked by the second admin who confirms); each
  -- with the document that proves who may receive (the notary's attestation, the judgment naming the tutor, curator or
  -- liquidator)
  if length(v_att) > 500 then
    raise exception 'payout account refused: bad_attestation' using errcode = 'check_violation';
  end if;
  if p_kind = 'estate' and not exists (
       select 1 from public.client_status_event e
       where e.client_organization_id = c.id and e.kind = 'death' and e.effective_date <= private.paris_today()) then
    raise exception 'payout account refused: estate_without_death' using errcode = 'check_violation';
  end if;
  if p_kind = 'protected_adult' and not exists (
       select 1 from public.client_status_event e
       where e.client_organization_id = c.id and e.kind in ('guardianship', 'curatorship')
         and e.effective_date <= private.paris_today()) then
    raise exception 'payout account refused: protected_adult_without_measure' using errcode = 'check_violation';
  end if;
  if (p_kind in ('estate', 'protected_adult', 'court_appointed') and p_authority_document_id is null)
     or (p_authority_document_id is not null
         and not private.client_document_of(p_authority_document_id, c.id, 'payout_authority_evidence')) then
    raise exception 'payout account refused: authority_evidence_required' using errcode = 'check_violation';
  end if;
  if p_kind = 'protected_adult' and v_att is null
     and not coalesce(private.epc_name_key(v_holder) = private.epc_name_key(c.legal_name), false) then
    raise exception 'payout account refused: holder_not_client' using errcode = 'check_violation';
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
                                            evidence_document_id, kind, proposed_by, authority_document_id,
                                            holder_attestation)
  values (c.servicer_organization_id, c.id, p_currency, v_iban, v_bic, v_holder, p_evidence_document_id, p_kind,
          auth.uid(), p_authority_document_id, v_att)
  returning id into v_id;
  v_result := jsonb_build_object('payout_account_id', v_id, 'status', 'proposed');
  perform private.command_record('propose_payout_account', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The payout's blockers, the allocation gate, « Reverser au client » (plan §6.2.7, §6.2.8)
------------------------------------------------------------------------------------------

-- private.remittance_payout_blockers, redefined from 20261115090000_transfers_files.sql (line 900; same signature; +
-- `set enable_seqscan = off`: read per run at approval and per payout at the file's generation and download, by keys
-- whatever the statistics; its grants restated below). M2c-7d-1 ([critic] F16, L14): every event in effect, the
-- strictest payee (private.client_payee_rule), confirmed by a second admin after each was recorded, with its authority
-- evidence; a standing seizure whatever the account. The draft read only the earliest event. Nothing else changes.
create or replace function private.remittance_payout_blockers(p_client_organization_id uuid, p_currency char(3),
                                                              p_on date)
returns text[]
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select array_remove(array[
    case (select count(*) from public.bank_account b
          where b.organization_id = o.servicer_organization_id and b.purpose = 'client_funds' and b.status = 'active'
            and b.currency = p_currency)
      when 0 then 'client_funds_account_missing' when 1 then null else 'several_client_funds_accounts' end,
    case when pa.id is null then
           case when exists (select 1 from public.client_payout_account x
                             where x.client_organization_id = o.id and x.currency = p_currency and x.status = 'proposed')
                then 'payout_account_unconfirmed' else 'payout_account_missing' end
         when pa.status = 'returned' then 'payout_account_returned'
         when exists (select 1 from public.payee_name_check c
                      join public.client_payout_account x on x.id = c.payout_account_id
                      where c.client_organization_id = o.id and c.cleared_at is null and x.iban = pa.iban)
           then 'payee_name_mismatch' end,
    -- (M2c-7d-1, plan §6.2.7; [critic] F16) every event in effect states the payee it requires; the strictest
    -- (private.client_payee_rule) lifts the block only when the current account is of that kind, confirmed by a second
    -- admin after the recording of each event, with its authority evidence (the client's own account: none needed).
    -- (Review round 1, CC-1) read only for a client with an event in effect (one keyed probe of
    -- client_status_event_client_idx): no event, no rule — the nested function, parsed and planned at every call, is
    -- not paid per payout by the clients without events
    case when exists (select 1 from public.client_status_event q
                      where q.client_organization_id = o.id and q.effective_date <= p_on) then
      (select 'client_status:' || r.event_kind from private.client_payee_rule(o.id, p_on) r
       where not coalesce(pa.kind = r.kind and pa.confirmed_via = 'second_admin' and pa.confirmed_at > r.known_at
                          and (r.kind = 'client' or pa.authority_document_id is not null), false)) end,
    -- ([critic] L14) a seizure standing blocks whatever the account (CPCE L211-2, C. civ. 1347-7); (review round 1,
    -- CC-1) read only for a client with a seizure in effect (client_status_event_client_seizure_idx, its predicate
    -- stated literally)
    case when exists (select 1 from public.client_status_event q
                      where q.client_organization_id = o.id and q.effective_date <= p_on and q.kind = 'seizure')
              and exists (select 1 from private.client_seizures_standing(o.id, p_on)) then 'client_status:seizure' end
    ], null)
  from public.organization o
  left join public.client_payout_account pa on pa.client_organization_id = o.id and pa.currency = p_currency
    and pa.status in ('active', 'returned')
  where o.id = p_client_organization_id;
$$;

-- private.gate_assignments, redefined from 20261109190000_payment_allocation.sql (line 506; same signature and settings,
-- its grants restated below). M2c-7d-1 (plan §6.2.8): a payment of a file of a client whose mandate ended (a death, a
-- tutelle, a mandate end: private.client_end_event) on or before its booking date is held client_mandate_ended (the
-- servicer's « pouvoir de recevoir pour son compte » lapsed, R124-3) — never allocated automatically, never released:
-- ops forward it to the client's payee or restore it to the payer (founder Q10). Nothing else changes.
create or replace function private.gate_assignments()
returns void
language plpgsql
set search_path = ''
as $$
begin
  analyze pg_temp._assign;
  drop table if exists pg_temp._gate_file;
  create temp table _gate_file (
    account_id uuid primary key,
    status text,
    currency char(3),
    servicing_start date,
    holds bigint not null default 0,
    balance bigint not null default 0,
    pending bigint not null default 0,
    client_id uuid,                -- (M2c-7d-1) the file's client
    ended_on date                  -- its mandate's end (C. civ. 2003), if any
  ) on commit drop;
  insert into pg_temp._gate_file (account_id) select distinct g.account_id from pg_temp._assign g;
  analyze pg_temp._gate_file;
  perform 1 from pg_temp._gate_file f join public.account a on a.id = f.account_id
  order by a.id for key share of a;

  update pg_temp._assign g set review_reason = 'no_mandate'
  where not exists (select 1 from public.account a where a.id = g.account_id);
  delete from pg_temp._gate_file f where not exists (select 1 from public.account a where a.id = f.account_id);
  update pg_temp._gate_file f set status = a.status, currency = a.currency, client_id = a.client_organization_id
  from public.account a where a.id = f.account_id;
  -- (M2c-7d-1, plan §6.2.8) the earliest end of each client's mandate (a death, a tutelle, a mandate end:
  -- private.client_end_event), one keyed read per client of the files
  update pg_temp._gate_file f set ended_on = x.ended_on
  from (select c.client_id, (select e.effective_date from private.client_end_event(c.client_id, 'infinity') e)
                              as ended_on
        from (select distinct g.client_id from pg_temp._gate_file g where g.client_id is not null) c) x
  where x.client_id = f.client_id and x.ended_on is not null;
  update pg_temp._gate_file f set servicing_start = s.valid_from
  from (select o.account_id, min(o.valid_from) as valid_from
        from pg_temp._gate_file x join public.claim_ownership_period o on o.account_id = x.account_id
        group by o.account_id) s
  where s.account_id = f.account_id;
  update pg_temp._gate_file f set holds = h.n
  from (select h.account_id, count(*) as n
        from pg_temp._gate_file x join public.account_hold h on h.account_id = x.account_id
        where h.ended_at is null and h.kind in ('surendettement', 'collective_proceeding')
        group by h.account_id) h
  where h.account_id = f.account_id;
  update pg_temp._gate_file f set balance = b.balance
  from (select la.account_id, sum(lp.amount_minor) as balance
        from pg_temp._gate_file x
        join public.ledger_account la on la.account_id = x.account_id and la.book = 'debtor_receivable'
        join public.ledger_posting lp on lp.ledger_account_id = la.id
        group by la.account_id) b
  where b.account_id = f.account_id;
  -- (NOT EXISTS, never NOT IN: NOT IN over a subquery is a plain subplan once _assign outgrows hash
  -- memory, one scan of it per matched payment; NOT EXISTS is an anti-join at any size)
  update pg_temp._gate_file f set pending = d.pending
  from (select p.account_id, sum(p.amount_minor) as pending
        from pg_temp._gate_file x join public.payment p on p.account_id = x.account_id and p.status = 'matched'
        where not exists (select 1 from pg_temp._assign y where y.payment_id = p.id)
        group by p.account_id) d
  where d.account_id = f.account_id;
  analyze pg_temp._gate_file;

  update pg_temp._assign g set review_reason = case
      when f.status = 'staged' then 'account_not_confirmed'
      -- (M2c-7d-1) received on or after the end of the client's mandate: the servicer's « pouvoir de recevoir »
      -- (R124-3) lapsed — held for ops (forwarded to the client's payee or restored to the payer), never allocated
      when f.ended_on <= p.booking_date then 'client_mandate_ended'
      when f.status in ('closed_paid', 'closed_settled', 'closed_uncollectable', 'closed_recalled') then 'account_closed'
      when p.currency <> f.currency then 'currency_mismatch'
      when f.holds > 0 and not ('hold_blocks_allocation' = any (g.releases)) then 'hold_blocks_allocation'
      when f.servicing_start is null
           or (p.booking_date < f.servicing_start and not ('before_servicing_start' = any (g.releases)))
        then 'before_servicing_start'
    end
  from pg_temp._gate_file f, public.payment p
  where f.account_id = g.account_id and p.id = g.payment_id;

  update pg_temp._assign g set review_reason = 'nothing_due'
  from (select x.payment_id,
               f.balance - f.pending - coalesce(sum(p.amount_minor) over (
                 partition by x.account_id order by x.ord rows between unbounded preceding and 1 preceding), 0) as due
        from pg_temp._assign x
        join pg_temp._gate_file f on f.account_id = x.account_id
        join public.payment p on p.id = x.payment_id
        where x.review_reason is null) y
  where g.payment_id = y.payment_id and y.due <= 0 and not ('nothing_due' = any (g.releases));
end;
$$;

-- private.allocation_begin (the allocation job's temporary tables), redefined from 20261109190000_payment_allocation.sql
-- (line 618; same signature and settings, its grants restated below). M2c-7d-1 (plan §6.2.8): the job's own gate (the
-- Python twin of private.gate_assignments, collectoo_worker.jobs.allocation.gate) may hold a payment
-- client_mandate_ended — an end recorded after the payment was gated ready, before the job ran. Nothing else changes.
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
                                             'currency_mismatch', 'before_servicing_start', 'hold_blocks_allocation',
                                             'client_mandate_ended')),
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

-- public.forward_payment (« Reverser au client »), redefined from 20261109190000_payment_allocation.sql (line 1161; same
-- signature and settings, its grants restated below). M2c-7d-1 (plan §6.2.8): a payment held client_mandate_ended is
-- forwarded; a payment received on or after the end of the client's mandate (read again here) is forwarded with the
-- reason mandate_ended — no schedule key names it, so it earns no commission — and the client reads « Reversement sans
-- imputation : paiement reçu après la fin du mandat ». Nothing else changes.
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
  v_code text;
  v_ended boolean;
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
    -- KEY SHARE: a hold placed meanwhile (place_account_hold locks the file FOR UPDATE) waits for this command, or
    -- this command sees it
    select * into a from public.account where id = p.account_id for key share;
    -- (M2c-7d-1) coalesce: a payment ready for allocation (no review reason) is not forwarded either — the bare
    -- comparison read null there and let it through
    if not (p.status = 'matched'
            and (a.status = 'closed_recalled'
                 or coalesce(p.review_reason in ('before_servicing_start', 'client_mandate_ended'), false))) then
      raise exception 'a payment on a file is forwarded only when the client recalled the file, for a payment before the cut-off or for one received after the end of the mandate'
        using errcode = 'check_violation';
    end if;
    -- Surendettement or a collective proceeding: paying a prior debt needs the judge's authorisation (L722-5,
    -- L622-7); a held payment is refunded, or allocated on that authorisation (founder #12), never forwarded (review
    -- fix: the hold may hide behind the recall or the cut-off gate).
    if exists (select 1 from public.account_hold h where h.account_id = a.id and h.ended_at is null
                 and h.kind in ('surendettement', 'collective_proceeding')) then
      raise exception 'the file is held (surendettement or collective proceeding): its payments are not forwarded'
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
  -- Why, as the client reads it (the entry and its notification): a fixed wording and a code; ops' motif stays
  -- internal (review fix).
  -- (M2c-7d-1, plan §6.2.8; founder Q10) received on or after the end of the client's mandate (read again here: an
  -- end recorded after the payment was gated counts): its own reason, which no schedule prices
  v_ended := exists (select 1 from private.client_end_event(v_client, p.booking_date));
  v_code := case when v_ended then 'mandate_ended'
                 when p.account_id is null then 'client_ratification'
                 when a.status = 'closed_recalled' then 'file_recalled'
                 else 'before_servicing_start' end;
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, payment_id, source_type, source_id, reason)
  values (1, p.organization_id, 'forward', private.paris_today(), 'forward:' || p.id || ':' || md5(p_idempotency_key),
          v_client, p.id, 'payment', p.id::text,
          case v_code when 'file_recalled' then 'Reversement sans imputation : dossier rappelé'
                      when 'mandate_ended' then 'Reversement sans imputation : paiement reçu après la fin du mandat'
                      when 'before_servicing_start' then 'Reversement sans imputation : paiement antérieur à la reprise'
                      else 'Reversement sans imputation : ratification du client' end);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency) values
    (1, 1, 'unallocated_payment', pos.unallocated_minor, p.currency),
    (1, 2, 'client_payable', -pos.unallocated_minor, p.currency);
  select x.entry_id into v_entry from private.ledger_post_set() x;
  insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id, payment_id,
                                          ledger_entry_id, kind, reason)
  values (p.organization_id, v_client, p.portfolio_id, p.account_id, p.id, v_entry, 'payment_forwarded', v_code);
  insert into private.payment_ops_note (entry_id, payment_id, command, note, decided_by)
  values (v_entry, p.id, 'forward_payment', v_reason, auth.uid());
  update public.payment set status = 'allocated', review_reason = null, allocation_instruction = null where id = p.id;
  v_result := jsonb_build_object('payment_id', p.id, 'entry_id', v_entry, 'amount_minor', pos.unallocated_minor::text);
  perform private.command_record('forward_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The authority evidence (plan §4.1.11: 7d's kind)
------------------------------------------------------------------------------------------

-- public.register_client_document, redefined from 20261124090000_client_payments.sql (line 2501, 7c-1's; same signature
-- and settings, its grants restated below). M2c-7d-1 (§6.1): the kind payout_authority_evidence (the notary's
-- attestation, the heirs' designation, the judgment naming the tutor, curator or liquidator), read by money staff only.
-- Nothing else changes.
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
  if p_kind is null or p_kind not in ('payout_rib', 'mandate_document', 'client_status_evidence',
                                     'advance_write_off_evidence', 'client_payment_evidence',
                                     'client_refund_evidence', 'payment_designation_evidence',
                                     'payout_authority_evidence') then
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

-- private.can_read_client_document_object, redefined from 20261124090000_client_payments.sql (line 2557, 7c-1's; same
-- signature and settings, its grants restated below): that kind's files too, for money staff only
-- (private.can_read_client_document, unchanged). Nothing else changes.
create or replace function private.can_read_client_document_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.document d
                 where d.storage_bucket = 'documents' and d.storage_path = p_name
                   and d.kind in ('payout_rib', 'mandate_document', 'client_status_evidence',
                                  'advance_write_off_evidence', 'client_payment_evidence', 'client_refund_evidence',
                                  'payment_designation_evidence', 'payout_authority_evidence')
                   and private.can_read_client_document(d.organization_id, d.client_organization_id, d.kind));
$$;

-- the policy document_client_money_scope, recreated from 20261124090000_client_payments.sql (line 2574) with that kind
drop policy document_client_money_scope on public.document;
create policy document_client_money_scope on public.document as restrictive for select to authenticated
  using (kind not in ('payout_rib', 'mandate_document', 'client_status_evidence', 'advance_write_off_evidence',
                      'client_payment_evidence', 'client_refund_evidence', 'payment_designation_evidence',
                      'payout_authority_evidence')
         or private.can_read_client_document(organization_id, client_organization_id, kind));

------------------------------------------------------------------------------------------
-- The portfolio confirmation gate (review round 1, TUI-2)
------------------------------------------------------------------------------------------

-- private.portfolio_confirmation_blockers, redefined from 20261111120000_identities_terms.sql (line 1705; same signature
-- and settings, its grants restated below). M2c-7d-1 review round 1 (TUI-2): the client's events read through
-- private.client_event_effective, the one place that says what an event counts as — client_mandate_ended for a mandate
-- end or a tutelle (C. civ. 2003: « la tutelle des majeurs »), recorded since 7d-1 or an old row qualified as one; an old
-- « Tutelle ou curatelle » row qualified as a curatelle ends nothing and blocks nothing here (its curatorship event
-- holds the payouts only: plan §6.6 « curatorship blocks payouts but not the confirmation gate »); an old row still to
-- qualify is its own reason, client_protection_to_qualify:<its date> (no new portfolio until it is qualified, the
-- servicer's rule: it may be a tutelle) — never « Mandat terminé » for what may be a curatelle. Nothing else changes.
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
    -- (M2c-7d-1 review round 1, TUI-2) an old « Tutelle ou curatelle » row still to qualify
    'client_protection_to_qualify:' || to_char(ev.to_qualify, 'YYYY-MM-DD'),
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
  -- (M2c-7d-1 review round 1, TUI-2) what each event counts as (private.client_event_effective), not its kind
  cross join lateral (select min(e.effective_date) filter (where k.kind in ('mandate_ended', 'guardianship'))
                               as mandate_ended,
                             min(e.effective_date) filter (where k.kind = 'death') as deceased,
                             min(e.effective_date) filter (where k.kind = 'liquidation') as liquidation,
                             min(e.effective_date) filter (where k.kind = 'guardianship_to_qualify') as to_qualify
                      from public.client_status_event e
                      cross join lateral (select private.client_event_effective(e.id) as kind) k
                      where e.client_organization_id = p.client_organization_id and e.effective_date <= p_on
                        and e.kind in ('mandate_ended', 'guardianship', 'death', 'liquidation')) ev
  where p.id = p_portfolio_id;
$$;

------------------------------------------------------------------------------------------
-- Who reads a letter addressed to the person who acts for the client (review round 1, MONEY-LAW-2, TUI-3)
------------------------------------------------------------------------------------------

-- A request's letter by its document (the read below; one document per request, drawn once)
create index advance_repayment_request_document_idx on public.advance_repayment_request (document_id)
  where document_id is not null;

-- private.can_read_remittance_document (the remittance documents' row and object rule), redefined from
-- 20261113090000_remittance_documents.sql (line 1537; same signature, + `set enable_seqscan = off`: the request by
-- its document's key whatever the statistics; its grants restated below). M2c-7d-1 review round 1 (MONEY-LAW-2,
-- TUI-3; plan §6.1: the names and addresses of who acts for the client are « never the client's users, restricted
-- viewers or collectors »): the letter of a repayment request addressed to such a person (its payload's recipient has a
-- role: the notary, the heirs, the tutor, the liquidator — private.client_addressee) is read by money staff only, not by
-- the client's whole-client members; a letter addressed to the client (a curatelle's, its curator in copy as plan
-- §6.2.12 designs it) is theirs as before. Nothing else changes.
create or replace function private.can_read_remittance_document(p_document_id uuid, p_kind text,
                                                               p_organization_id uuid,
                                                               p_client_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select p_organization_id = any (private.money_staff_org_ids())
      or (p_client_organization_id = any (private.client_whole_org_ids())
          and (p_kind <> 'commission_invoice_pdf'
               or exists (select 1 from public.commission_invoice_document d
                          where d.document_id = p_document_id and d.electronic))
          -- (M2c-7d-1 review round 1) not a letter addressed to the person who acts for the client
          and not (p_kind = 'advance_repayment_request_pdf'
                   and exists (select 1 from public.advance_repayment_request r
                               where r.document_id = p_document_id and r.payload -> 'recipient' ? 'role')));
$$;

-- the policy advance_repayment_request_read, recreated from 20261125090000_repayment_requests.sql (line 176): the
-- client's whole-client members read their requests but those addressed to the person who acts for the client (its
-- payload names that person); money staff read every one
drop policy advance_repayment_request_read on public.advance_repayment_request;
create policy advance_repayment_request_read on public.advance_repayment_request for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or (client_organization_id = any ((select private.client_whole_org_ids())::uuid[])
      and not coalesce(payload -> 'recipient' ? 'role', false)));

-- public.client_repayment_requests, redefined from 20261125090000_repayment_requests.sql (line 740; same signature and
-- settings, its grants restated below). M2c-7d-1 review round 1 (MONEY-LAW-2, TUI-3): each request says whether its
-- letter is addressed to the person who acts for the client (`to_representative`); for the client's members such a
-- letter's document is not listed (null) — staff see it. Nothing else changes.
create or replace function public.client_repayment_requests(p_client_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_org uuid;
  v_staff boolean;
begin
  select c.servicer_organization_id into v_org from public.organization c
  where c.id = p_client_organization_id and c.kind <> 'servicer';
  -- (review round 1) whether the caller reads as the servicer's money staff (else as the client's member)
  v_staff := v_org is not null and private.has_role(v_org, array['admin', 'ops_manager']);
  if v_org is null
     or not (p_client_organization_id = any (private.client_whole_org_ids()) or v_staff) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object('rows', (
    select coalesce(jsonb_agg(jsonb_build_object(
             'request_id', q.id, 'number', q.number, 'issue_date', q.issue_date, 'currency', q.currency,
             'total_minor', q.total_minor::text,
             'withdrawn_on', (q.withdrawn_at at time zone 'Europe/Paris')::date,
             'document_id', case when v_staff or not q.to_representative then q.document_id end,
             'to_representative', q.to_representative,
             'advance_ids', (select coalesce(jsonb_agg(i.advance_id order by i.advance_id), '[]')
                             from public.advance_repayment_request_item i where i.request_id = q.id))
           order by q.created_at desc, q.id desc), '[]')
    from (select r.id, r.number, r.issue_date, r.currency, r.total_minor, r.withdrawn_at, r.document_id, r.created_at,
                 r.organization_id, coalesce(r.payload -> 'recipient' ? 'role', false) as to_representative
          from public.advance_repayment_request r where r.client_organization_id = p_client_organization_id
          order by r.created_at desc limit 200) q
    where q.organization_id = v_org));
end;
$$;

------------------------------------------------------------------------------------------
-- The repayment request's recipient (plan §6.2.12, 7c-2's narrowed)
------------------------------------------------------------------------------------------

-- private.advance_repayment_client_refusal, redefined from 20261125090000_repayment_requests.sql (line 311, 7c-2's; same
-- signature and settings, its grants restated below). M2c-7d-1: recipient_unknown only while nobody is recorded to
-- receive the letter (private.client_addressee: no row). Nothing else changes.
create or replace function private.advance_repayment_client_refusal(p_organization_id uuid, p_client_organization_id uuid,
                                                                    p_currency char(3), p_today date)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case
    when not exists (select 1 from public.servicer_billing_settings s
                     join public.bank_account b on b.id = s.own_bank_account_id
                     where s.organization_id = p_organization_id and b.purpose = 'own' and b.status = 'active'
                       and b.currency = p_currency) then 'no_own_account'
    when cardinality(private.billing_identity_gaps(p_organization_id)) > 0 then 'identity_incomplete'
    -- (M2c-7d-1, plan §6.2.12) nobody to address it to: a death, a tutelle or a liquidation with nobody recorded who
    -- acts for the client, a curatelle without its curator, an old row still to qualify (private.client_addressee
    -- returns no row); after a mandate end the letter goes to the client
    when not exists (select 1 from private.client_addressee(p_client_organization_id, p_today)) then 'recipient_unknown'
  end;
$$;

-- private.advance_repayment_payload, redefined from 20261125090000_repayment_requests.sql (line 428, 7c-2's; same
-- signature and settings, its grants restated below). M2c-7d-1 ([check 1] gap 7): the recipient from
-- private.client_addressee (a person who acts for the client: its role, name, address and the client's name), and the
-- curator's copy (`copies`) after a curatelle. A plain client's payload is 7c-2's, byte for byte. Nothing else changes.
create or replace function private.advance_repayment_payload(p_request public.advance_repayment_request,
                                                             p_advance_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select jsonb_build_object(
    'template', p_request.template_version,
    'number', p_request.number,
    'issue_date', p_request.issue_date,
    'currency', p_request.currency,
    'issuer', private.receipt_issuer(p_request.organization_id),
    -- (M2c-7d-1, plan §6.2.12) the addressee (private.client_addressee): the client at its billing address, as before;
    -- after a death, a tutelle or a liquidation the person who acts for it (its role, its name and address, for the
    -- client)
    'recipient', (select case when a.role = 'client'
                              then jsonb_build_object('name', o.legal_name,
                                                      'address', coalesce(b.billing_address, b.registered_office))
                              else jsonb_build_object('role', a.role, 'name', a.name,
                                                      'address_lines', to_jsonb(a.address_lines),
                                                      'client_name', o.legal_name) end
                  from private.client_addressee(p_request.client_organization_id, p_request.issue_date) a
                  cross join public.organization o left join public.billing_identity b on b.organization_id = o.id
                  where o.id = p_request.client_organization_id and not a.copy limit 1),
    'own_account', (select jsonb_build_object('holder', o.legal_name, 'iban', ba.iban, 'bic', ba.bic)
                    from public.servicer_billing_settings s
                    join public.bank_account ba on ba.id = s.own_bank_account_id
                    join public.organization o on o.id = s.organization_id
                    where s.organization_id = p_request.organization_id),
    'total_minor', p_request.total_minor::text,
    'rows', (select coalesce(jsonb_agg(private.advance_repayment_row(x.id) order by x.created_at, x.id), '[]')
             from (select q.id, q.created_at from public.client_advance q where q.id = any (p_advance_ids)) x))
    -- (M2c-7d-1, [check 1] gap 7) after a curatelle, the copy to the curator (its key only then: a plain client's
    -- payload is 7c-2's)
    || coalesce((select jsonb_build_object('copies', jsonb_agg(jsonb_build_object(
                                                     'role', a.role, 'name', a.name,
                                                     'address_lines', to_jsonb(a.address_lines)) order by a.name))
                 from private.client_addressee(p_request.client_organization_id, p_request.issue_date) a
                 where a.copy having count(*) > 0), '{}'::jsonb);
$$;

------------------------------------------------------------------------------------------
-- The nightly (plan §6.3)
------------------------------------------------------------------------------------------

-- private.run_advance_checks, redefined from 20261125090000_repayment_requests.sql (line 896, 7c-2's: 7c-1's body with
-- requested_on and repayment_request_document_missing; same signature and settings, its grants restated below).
-- M2c-7d-1 (plan §6.3; [critic] L14, L17): two checks after repayment_request_document_missing —
-- protection_event_to_qualify (alert) and seizure_standing (alert, P0 for 15 days). Its other statements are unchanged.
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
    and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id);

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
  -- L211-3, R211-4, R211-5). The servicer's seizures by client_status_event_seizure_idx (its predicate stated
  -- literally), each one's release by client_status_event_release_uq (offset 0: a correlated probe per seizure — as an
  -- anti-join it read the release index whole under stale statistics).
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'seizure_standing', 'alert', 'client_status_event', e.id, null, null, 1,
         v_today - (e.recorded_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', e.client_organization_id, 'effective_date', e.effective_date,
                            'recorded_on', (e.recorded_at at time zone 'Europe/Paris')::date,
                            'p0', v_today - (e.recorded_at at time zone 'Europe/Paris')::date < 15)
  from (select x.id, x.client_organization_id, x.effective_date, x.recorded_at from public.client_status_event x
        where x.organization_id = p_organization_id and x.kind = 'seizure' offset 0) e
  where e.effective_date <= v_today
    and not exists (select 1 from public.client_status_event r
                    where r.refers_to_event_id = e.id and r.kind = 'seizure_released' and r.effective_date <= v_today
                    offset 0);
end;
$$;

------------------------------------------------------------------------------------------
-- The client's events, as its page reads them
------------------------------------------------------------------------------------------

-- « Événements du client » (money staff of the servicer): each event (what it counts as, a seizure standing or released,
-- an old row to qualify and its qualification, who acts for the client in force and how many rows were recorded, a
-- declaration's documents and amounts), the payee the events require today, whether a seizure stands, who receives the
-- letters, and each payout account's names compared as the writer spells them (the holder's and the client's) with its
-- explanation and authority evidence — for the second admin who confirms. Every rule SQL's; the page words it.
create function public.client_events_view(p_client_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  c public.organization;
  v_today date := private.paris_today();
begin
  select * into c from public.organization where id = p_client_organization_id and kind <> 'servicer';
  if not found or c.servicer_organization_id is null
     or not (c.servicer_organization_id = any (private.money_staff_org_ids())) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'events', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', e.id, 'kind', e.kind, 'effective_kind', private.client_event_effective(e.id),
               'effective_date', e.effective_date, 'recorded_on', (e.recorded_at at time zone 'Europe/Paris')::date,
               'publication_date', e.publication_date, 'note', e.note, 'evidence_document_id', e.evidence_document_id,
               'refers_to_event_id', e.refers_to_event_id,
               'standing', case when e.kind = 'seizure' then exists (
                             select 1 from private.client_seizures_standing(c.id, v_today) s (id) where s.id = e.id) end,
               'released_on', case when e.kind = 'seizure' then (
                                select r.effective_date from public.client_status_event r
                                where r.refers_to_event_id = e.id and r.kind = 'seizure_released') end,
               'to_qualify', e.kind = 'guardianship' and e.qualified_at is null and q.event_id is null,
               'qualification', case when q.event_id is not null then jsonb_build_object(
                                  'kind', q.kind, 'curatorship_event_id', q.curatorship_event_id,
                                  'evidence_document_id', q.evidence_document_id,
                                  'recorded_on', (q.recorded_at at time zone 'Europe/Paris')::date) end,
               'representative', (select jsonb_build_object('role', x.representative ->> 'role',
                                                            'name', x.representative ->> 'name',
                                                            'address_lines', x.representative -> 'address_lines',
                                                            'recorded_on', (x.recorded_at at time zone 'Europe/Paris')::date,
                                                            'evidence_document_id', x.evidence_document_id)
                                  from public.client_status_event_representative x where x.event_id = e.id
                                  order by x.recorded_at desc, x.id desc limit 1),
               'representatives', (select count(*) from public.client_status_event_representative x
                                   where x.event_id = e.id),
               'declared', (select coalesce(jsonb_agg(jsonb_build_object(
                                     'document_kind', i.document_kind, 'document_id', i.document_id,
                                     'number', (select ci.number from public.commission_invoice ci
                                                where i.document_kind = 'invoice' and ci.id = i.document_id),
                                     'amount_minor', i.amount_minor::text) order by i.document_kind, i.document_id),
                                   '[]')
                            from public.claims_declared_item i where i.event_id = e.id))
             order by e.effective_date desc, e.recorded_at desc, e.id), '[]')
      from (select x.* from public.client_status_event x where x.client_organization_id = c.id offset 0) e
      left join lateral (select y.* from public.client_status_event_qualification y where y.event_id = e.id offset 0) q
        on true),
    'payee', (select jsonb_build_object('kind', r.kind, 'event_kind', r.event_kind)
              from private.client_payee_rule(c.id, v_today) r),
    'seizure_standing', exists (select 1 from private.client_seizures_standing(c.id, v_today)),
    'addressees', (select coalesce(jsonb_agg(jsonb_build_object('role', a.role, 'name', a.name,
                                                                'address_lines', to_jsonb(a.address_lines),
                                                                'copy', a.copy) order by a.copy, a.role), '[]')
                   from private.client_addressee(c.id, v_today) a),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object(
                          'payout_account_id', p.id, 'kind', p.kind, 'holder_name', p.holder_name,
                          'client_name', c.legal_name,
                          'names_match', private.epc_name_key(p.holder_name) = private.epc_name_key(c.legal_name),
                          'holder_attestation', p.holder_attestation,
                          'authority_document_id', p.authority_document_id) order by p.proposed_at desc, p.id), '[]')
                 from (select y.* from public.client_payout_account y where y.client_organization_id = c.id offset 0) p));
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (the new internals revoked; every redefined function's grants restated)
------------------------------------------------------------------------------------------

-- the pure helpers (representative_clean in a CHECK constraint, representative_fits, address_lines) stay executable by
-- everyone, as the M2c-2 validators: they read no table. The new internals: the SECURITY DEFINER paths and the guards
-- use them
revoke execute on function private.client_event_effective(uuid), private.client_seizures_standing(uuid, date),
  private.client_end_event(uuid, date), private.client_payee_rule(uuid, date), private.client_addressee(uuid, date),
  private.declared_items(uuid, jsonb), private.client_status_event_representative_guard(),
  private.client_status_event_qualification_guard(), private.claims_declared_item_guard()
  from public, anon, authenticated, service_role;
-- (review round 1, CC-4) the end of a client's mandate, read by the allocation job (jobs.allocation.load_files) as the
-- service role it is to log in as (ADR-0012), with what an event counts as (the confirmation gate, which that role
-- executes, reads it): read-only, by keys
grant execute on function private.client_end_event(uuid, date), private.client_event_effective(uuid) to service_role;
-- the name key and its spellings: the worker's parity test compares them with the writer (as epc_name_empty)
revoke execute on function private.epc_name_key(text), private.epc_spelled(text) from public, anon, authenticated;
grant execute on function private.epc_name_key(text), private.epc_spelled(text) to service_role;
-- the commands and the read: authenticated (each checks the caller inside); never anon
revoke execute on function public.set_client_representative(text, uuid, jsonb, uuid),
  public.qualify_protection_event(text, uuid, text, uuid), public.client_events_view(uuid),
  public.record_client_status_event(text, uuid, text, date, uuid, text, uuid, date, jsonb, uuid, jsonb),
  public.propose_payout_account(text, uuid, text, text, text, text, uuid, text, uuid, text)
  from public, anon;
grant execute on function public.set_client_representative(text, uuid, jsonb, uuid),
  public.qualify_protection_event(text, uuid, text, uuid), public.client_events_view(uuid),
  public.record_client_status_event(text, uuid, text, date, uuid, text, uuid, date, jsonb, uuid, jsonb),
  public.propose_payout_account(text, uuid, text, text, text, text, uuid, text, uuid, text)
  to authenticated;

-- (20261111120000) the guards and the client's users' rights over its accounts: internal
revoke execute on function private.client_status_event_guard(), private.client_payout_account_guard(),
  private.payout_court_appointed(text, uuid)
  from public, anon, authenticated;
-- (20261115090000) the payout's blockers: internal, and the worker's prepare (M2c-4)
revoke execute on function private.remittance_payout_blockers(uuid, char, date) from public, anon, authenticated;
grant execute on function private.remittance_payout_blockers(uuid, char, date) to service_role;
-- (20261109190000) the gate: internal; « Reverser au client »: authenticated (it checks the caller inside)
revoke execute on function private.gate_assignments() from public, anon, authenticated, service_role;
revoke execute on function private.allocation_begin() from public, anon, authenticated, service_role;
grant execute on function private.allocation_begin() to service_role;
revoke execute on function public.forward_payment(text, uuid, uuid, text, uuid, text) from public, anon;
grant execute on function public.forward_payment(text, uuid, uuid, text, uuid, text) to authenticated;
-- (20261124090000) « Joindre un document » and the storage policy's helper
revoke execute on function public.register_client_document(text, uuid, text, text, text, text, text) from public, anon;
grant execute on function public.register_client_document(text, uuid, text, text, text, text, text) to authenticated;
revoke execute on function private.can_read_client_document_object(text) from public, anon, authenticated;
grant execute on function private.can_read_client_document_object(text) to authenticated;
-- (20261125090000) the request's client refusal and payload, the advance checks: internal
revoke execute on function private.advance_repayment_client_refusal(uuid, uuid, char, date),
  private.advance_repayment_payload(public.advance_repayment_request, uuid[])
  from public, anon, authenticated, service_role;
revoke execute on function private.run_advance_checks(uuid, uuid, date, boolean)
  from public, anon, authenticated, service_role;
-- (review round 1) (20261111120000) the portfolio confirmation gate: internal, and the worker's confirmation job
revoke execute on function private.portfolio_confirmation_blockers(uuid, date) from public, anon, authenticated;
grant execute on function private.portfolio_confirmation_blockers(uuid, date) to service_role;
-- (20261113090000) the remittance documents' row and object rule: the policies run it as the caller
revoke execute on function private.can_read_remittance_document(uuid, text, uuid, uuid) from public, anon, authenticated;
grant execute on function private.can_read_remittance_document(uuid, text, uuid, uuid) to authenticated;
-- (20261125090000) the client's requests: authenticated (it checks the caller inside); never anon
revoke execute on function public.client_repayment_requests(uuid) from public, anon;
grant execute on function public.client_repayment_requests(uuid) to authenticated;
