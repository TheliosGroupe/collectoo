-- M2c-5b Manual credit note (design docs/design/m2c-remittances.md §14.1 « A manual credit note (issue_credit_note,
-- admin, reason) corrects an error (risk R2) », §4 entry row commission_credit_note, §16, §20 R2; ADR-0014 M2c-5b
-- addendum; CALCULATION_RULES §7 « The waiver »).
--
--   * the waiver: a manual credit note takes back part of what an invoice charges a (file, tier key) while no line
--     changes, so the commission engine's commission charged (V, remittance_key_state.commission_minor) does not
--     change: that part becomes a waiver on the same (invoice, file, tier key) (public.commission_waiver, a ledger of
--     signed movements) and the key's state carries its total (remittance_key_state.waived_minor). For every key,
--     Σ open charges + Σ waivers = V. A later collection never re-charges a waived amount (V is the engine's); a later
--     credit the engine allocates to an invoice is absorbed by that invoice's waiver first (cause 'absorbed', no
--     document), then credited, never beyond the invoice's remaining HT; a cancelled run clears its own invoices'
--     waivers and restores what its credits absorbed (worker `remittance.commission`, ADR-0014 M2c-5b);
--   * public.issue_credit_note (an admin at aal2, idempotency key and request hash, compare and set on the invoice's
--     remaining HT): the HT spread over what the invoice still charges each (file, tier key) — of one file when one is
--     named — in proportion to it, the cents left going to the largest remainders; numbered in the servicer's gapless
--     series under the counter lock (allocation lock → remit lock → counter, as approvals); entry −4111 TTC / +7060 HT
--     / +44574 v₁ / +44571 v₂ (the invoice's pending VAT first), VAT by cumulative difference at the invoice's own rate
--     (CGI 289 I 5, 272 1, 283 3); applied to the invoice's open part at once, the rest a refund owed; the reason
--     category on the document, the free text staff-side (public.manual_credit_note); its PDF drawn by the M2c-5
--     documents job (the queue trigger on commission_invoice);
--   * reads for the back-office invoice page: public.commission_invoice_detail, public.credit_note_preview.
--
-- Redefined with their settings and grants restated: private.remittance_key_state_insert_guard (a credit note's key
-- state), private.remittance_key_states (+ waived_minor: dropped and created, its return type changes),
-- private.remittance_approval_refusal (the credit notes' key states count in the history the draft assumed),
-- private.approve_remittance_run (the key states' waiver and what the run's credits absorb),
-- public.cancel_remittance_run (waivers cleared and restored, the key states' waiver), private.run_remittance_checks
-- (I16 with what waivers absorbed; I22 the key states), private.remittance_statement_build (its totals name what the
-- run's credits absorbed). Constraints relaxed: commission_invoice's reason ('manual'),
-- remittance_key_state's run (a credit note's key state has none) and cause ('credit_note').

------------------------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------------------------

alter table public.commission_invoice drop constraint commission_invoice_reason_check;
alter table public.commission_invoice add constraint commission_invoice_reason_check
  check (reason in ('commission', 'reversal', 'run_cancelled', 'manual'));

-- A key state is an approval's, a cancellation's or (M2c-5b) a manual credit note's: the waiver it holds.
alter table public.remittance_key_state alter column run_id drop not null;
alter table public.remittance_key_state add column credit_note_id uuid references public.commission_invoice (id);
alter table public.remittance_key_state
  add column waived_minor bigint not null default 0 check (waived_minor >= 0);
alter table public.remittance_key_state drop constraint remittance_key_state_cause_check;
alter table public.remittance_key_state add constraint remittance_key_state_cause_check
  check (cause in ('approved', 'cancelled', 'credit_note'));
alter table public.remittance_key_state add constraint remittance_key_state_source
  check (case cause when 'credit_note' then credit_note_id is not null and run_id is null
                    else run_id is not null and credit_note_id is null end);
create index remittance_key_state_changed_idx on public.remittance_key_state (organization_id, created_at);
comment on column public.remittance_key_state.waived_minor is
  'What manual credit notes took back from the key''s invoices and no later credit absorbed (M2c-5b): '
  'Σ open charges + waived = commission_minor.';

-- The waiver per (invoice, file, tier key) as signed movements (M2c-5b): + a manual credit note; − what a later
-- credit of a run absorbs (that run, the line it credits), − what a cancellation clears on its run's own invoices, + what
-- it restores of its run's absorptions. The balance is the waiver: never negative, never above what manual credit notes
-- took back from that (invoice, key). Append-only.
create table public.commission_waiver (
  id bigint generated always as identity primary key,
  organization_id uuid not null,
  client_organization_id uuid not null,
  invoice_id uuid not null references public.commission_invoice (id),
  account_id uuid not null references public.account (id),
  tier_key text not null,
  amount_minor bigint not null check (amount_minor <> 0),
  cause text not null check (cause in ('credit_note', 'absorbed', 'run_cancelled', 'restored')),
  credit_note_id uuid references public.commission_invoice (id),
  run_id uuid references public.remittance_run (id),
  entry_id uuid references public.ledger_entry (id),
  created_at timestamptz not null default clock_timestamp(),
  constraint commission_waiver_shape check (case cause
    when 'credit_note' then amount_minor > 0 and credit_note_id is not null and run_id is null
    when 'absorbed' then amount_minor < 0 and run_id is not null and entry_id is not null and credit_note_id is null
    when 'run_cancelled' then amount_minor < 0 and run_id is not null and credit_note_id is null
    else amount_minor > 0 and run_id is not null and credit_note_id is null end)
);
create index commission_waiver_key_idx on public.commission_waiver (invoice_id, account_id, tier_key);
create index commission_waiver_file_idx on public.commission_waiver (account_id, tier_key);
create index commission_waiver_run_idx on public.commission_waiver (run_id) where run_id is not null;
comment on table public.commission_waiver is
  'What manual credit notes waived per (invoice, file, tier key), and what later credits absorbed (M2c-5b).';

-- The manual credit note as staff record it (M2c-5b): the reason category the document states and the free text that
-- stays with money staff (GDPR minimisation, as the late approvals' reasons: review M2c-5 legal#6).
create table public.manual_credit_note (
  credit_note_id uuid primary key references public.commission_invoice (id),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  invoice_id uuid not null references public.commission_invoice (id),
  account_id uuid references public.account (id),               -- the file it was limited to, if one
  amount_minor bigint not null check (amount_minor > 0),        -- HT
  reason_code text not null check (reason_code in ('terms_error', 'basis_error', 'billing_error')),
  reason text not null check (length(btrim(reason)) between 1 and 2000),
  issued_by uuid references public.app_user (id),
  created_at timestamptz not null default clock_timestamp()
);
create index manual_credit_note_invoice_idx on public.manual_credit_note (invoice_id);
comment on table public.manual_credit_note is
  'Manual credit notes (issue_credit_note): the invoice corrected, the reason category and the staff''s reason.';

do $$
declare t text;
begin
  foreach t in array array['commission_waiver', 'manual_credit_note'] loop
    execute format('create trigger %I before update or delete or truncate on public.%I '
                   'for each statement execute function private.refuse_change()', t || '_append_only', t);
    execute format('alter table public.%I enable always trigger %I', t, t || '_append_only');
  end loop;
end;
$$;

-- A key state is its run's servicer's and client's, or its credit note's (once per run or credit note of the
-- statement, keyed). Redefined from 20261112090000 (M2c-5b: a manual credit note's key state has no run).
create or replace function private.remittance_key_state_insert_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
begin
  if exists (select 1 from (select distinct n.run_id, n.organization_id, n.client_organization_id from new_rows n
                            where n.run_id is not null) n
             left join lateral (select r.organization_id, r.client_organization_id
                                from public.remittance_run r where r.id = n.run_id offset 0) r on true
             where (r.organization_id, r.client_organization_id)
                   is distinct from (n.organization_id, n.client_organization_id)) then
    raise exception 'remittance key state: its run''s servicer and client' using errcode = 'check_violation';
  end if;
  if exists (select 1 from (select distinct n.credit_note_id, n.organization_id, n.client_organization_id
                            from new_rows n where n.credit_note_id is not null) n
             left join lateral (select c.organization_id, c.client_organization_id
                                from public.commission_invoice c
                                where c.id = n.credit_note_id and c.kind = 'credit_note' offset 0) c on true
             where (c.organization_id, c.client_organization_id)
                   is distinct from (n.organization_id, n.client_organization_id)) then
    raise exception 'remittance key state: its credit note''s servicer and client' using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

-- A waiver movement names an invoice of its servicer and client; each (invoice, key) it touches keeps a balance
-- between 0 and what manual credit notes took back from it (once per (invoice, key) of the statement, keyed).
create or replace function private.commission_waiver_insert_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
begin
  if exists (select 1 from (select distinct n.invoice_id, n.account_id, n.tier_key, n.organization_id,
                                            n.client_organization_id from new_rows n) n
             left join lateral (select i.kind, i.organization_id, i.client_organization_id
                                from public.commission_invoice i where i.id = n.invoice_id offset 0) i on true
             cross join lateral (select coalesce(sum(w.amount_minor), 0) as balance
                                 from public.commission_waiver w
                                 where w.invoice_id = n.invoice_id and w.account_id = n.account_id
                                   and w.tier_key = n.tier_key) b
             cross join lateral (select coalesce(-sum(a.ht_minor), 0) as waived
                                 from public.commission_credit_alloc a
                                 join lateral (select c.reason from public.commission_invoice c
                                               where c.id = a.credit_note_id offset 0) c on true
                                 where a.original_invoice_id = n.invoice_id and a.account_id = n.account_id
                                   and a.tier_key = n.tier_key and c.reason = 'manual') m
             where i.kind is distinct from 'invoice'
                or (i.organization_id, i.client_organization_id)
                   is distinct from (n.organization_id, n.client_organization_id)
                or b.balance < 0 or b.balance > m.waived) then
    raise exception 'commission waiver: an invoice of its client, between 0 and what manual credit notes took back'
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger commission_waiver_insert_guard after insert on public.commission_waiver
  referencing new table as new_rows for each statement execute function private.commission_waiver_insert_guard();
alter table public.commission_waiver enable always trigger commission_waiver_insert_guard;

------------------------------------------------------------------------------------------
-- The manual credit note (§14.1, risk R2)
------------------------------------------------------------------------------------------

-- The French words of a reason category, as the credit note states it (no free text on the client's document).
create or replace function private.manual_credit_reason_fr(p_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_code
           when 'terms_error' then 'erreur de conditions de rémunération (taux, paliers ou minimum)'
           when 'basis_error' then 'erreur d''assiette (encaissement non commissionnable)'
           when 'billing_error' then 'erreur de facturation' end;
$$;

-- Why an invoice cannot take a manual credit note now, or null: a credit note is never corrected by another; an
-- invoice with nothing left to credit (a cancelled run's are credited in full); an invoice a run in flight sets off
-- (approved or sent, its payout not debited: its stored settlement plan would set off more than is left — cancel the
-- run, or wait for its debit).
create or replace function private.manual_credit_refusal(p_invoice public.commission_invoice, p_remaining bigint)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case
           when p_invoice.kind <> 'invoice' then 'credit_note'
           when p_remaining <= 0 then 'nothing_left'
           when exists (select 1 from public.remittance_run r
                        where r.client_organization_id = p_invoice.client_organization_id
                          and r.currency = p_invoice.currency and r.status in ('approved', 'sent')
                          and exists (select 1 from jsonb_array_elements(coalesce(r.settlement_plan -> 'settles', '[]')) s
                                      where s ->> 'document_id' = p_invoice.id::text))
             then 'in_flight' end;
$$;

-- What a manual credit of p_amount HT on an invoice does (the command's plan and the page's effect sheet, from one
-- place): its spread over what the invoice still charges each (file, tier key) — only p_account_id's keys when given —
-- in proportion (integer shares, the cents left to the largest remainders, ties by file then tier key in code-point
-- order: the worker's `documents.manual_credit`), its VAT by cumulative difference at the invoice's own rate, the VAT
-- split (the invoice's pending VAT first: 44574, the rest 44571), what it applies to the invoice's open part and the
-- refund owed beyond it, and what the invoice still owes after. `refusal` when it cannot be issued.
create or replace function private.manual_credit_plan(p_invoice_id uuid, p_amount_minor bigint, p_account_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  i public.commission_invoice;
  v_credited bigint;     -- HT credited before by every credit note
  v_remaining bigint;    -- HT still charged
  v_selected bigint;     -- of the keys the credit may take (one file's, or all)
  v_open bigint;         -- TTC open
  v_pending bigint;      -- VAT pending (44574)
  v_vat bigint;
  v_vat_pending bigint;
  v_applied bigint;
  v_keys jsonb;          -- [{account_id, tier_key, open}] of the keys the credit may take, still charged
  v_allocs jsonb;
  v_why text;
begin
  select * into i from public.commission_invoice where id = p_invoice_id;
  if not found then
    return jsonb_build_object('refusal', 'unknown_invoice');
  end if;
  v_credited := coalesce((select -sum(c.ht_minor) from public.commission_credit_correction c
                          where c.original_invoice_id = i.id), 0);
  v_remaining := i.ht_minor - v_credited;
  v_open := private.document_open(i.id);
  v_pending := private.document_pending_vat(i.id);
  v_why := private.manual_credit_refusal(i, v_remaining);
  -- what the invoice still charges each key: its charge (by the invoice's key) less its credits (by theirs)
  select coalesce(jsonb_agg(jsonb_build_object('account_id', k.account_id, 'tier_key', k.tier_key,
                                               'open', k.open::text)), '[]'), coalesce(sum(k.open), 0)
  into v_keys, v_selected
  from (select ch.account_id, ch.tier_key,
               ch.charged_minor + coalesce((select sum(a.ht_minor) from public.commission_credit_alloc a
                                            where a.original_invoice_id = ch.invoice_id
                                              and a.account_id = ch.account_id and a.tier_key = ch.tier_key), 0)
                 as open
        from public.commission_invoice_charge ch
        where ch.invoice_id = i.id and (p_account_id is null or ch.account_id = p_account_id)) k
  where k.open > 0;
  if v_why is null and p_account_id is not null and v_selected = 0 then
    v_why := 'file_not_on_invoice';
  end if;
  if v_why is null and (p_amount_minor is null or p_amount_minor <= 0) then
    v_why := 'amount_required';
  end if;
  if v_why is null and (p_amount_minor > v_selected or p_amount_minor > v_remaining) then
    v_why := 'more_than_remaining';
  end if;
  if v_why is not null then
    return jsonb_build_object('refusal', v_why, 'remaining_ht', v_remaining::text, 'selected_ht', v_selected::text,
                              'open_ttc', v_open::text);
  end if;
  with k as (
    select (x ->> 'account_id')::uuid as account_id, x ->> 'tier_key' as tier_key, (x ->> 'open')::bigint as open
    from jsonb_array_elements(v_keys) x),
  s as (
    select k.account_id, k.tier_key, div(p_amount_minor::numeric * k.open, v_selected)::bigint as share,
           mod(p_amount_minor::numeric * k.open, v_selected) as frac
    from k),
  r as (
    select s.*, row_number() over (order by s.frac desc, s.account_id, s.tier_key collate "C") as rk,
           p_amount_minor - sum(s.share) over () as left_over
    from s)
  select jsonb_agg(jsonb_build_object('account_id', r.account_id, 'tier_key', r.tier_key,
                                      'ht', (r.share + case when r.rk <= r.left_over then 1 else 0 end)::text)
                   order by r.account_id, r.tier_key collate "C")
  into v_allocs
  from r where r.share + case when r.rk <= r.left_over then 1 else 0 end > 0;
  v_vat := (round((v_credited + p_amount_minor) * i.vat_rate) - round(v_credited * i.vat_rate))::bigint;
  v_vat_pending := least(v_vat, v_pending);
  v_applied := least(p_amount_minor + v_vat, v_open);
  return jsonb_build_object(
    'refusal', null, 'invoice_id', i.id, 'number', i.number, 'issue_date', i.issue_date,
    'vat_rate', i.vat_rate::text, 'ht', p_amount_minor::text, 'vat', v_vat::text,
    'ttc', (p_amount_minor + v_vat)::text, 'vat_pending', v_vat_pending::text,
    'vat_collected', (v_vat - v_vat_pending)::text, 'applied', v_applied::text,
    'excess', (p_amount_minor + v_vat - v_applied)::text, 'open_before', v_open::text,
    'open_after', (v_open - v_applied)::text, 'remaining_ht', v_remaining::text,
    'remaining_after', (v_remaining - p_amount_minor)::text, 'allocations', v_allocs);
end;
$$;

-- Amounts typed on the page: euros with a comma or a point and at most two decimals (« 30 », « 30,5 », « 1 234,56 »),
-- in minor units; null when not one.
create or replace function private.euros_to_minor(p_text text)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select case when t ~ '^[0-9]{1,12}([.,][0-9]{1,2})?$'
              then (replace(t, ',', '.')::numeric * 100)::bigint end
  from (select regexp_replace(btrim(coalesce(p_text, '')), '[\s  ]', '', 'g') as t) x;
$$;

-- Issue a manual credit note on an invoice (§14.1, §16; risk R2): an admin of the servicer at aal2. The amount HT as
-- typed (`p_amount_ht_text`, euros), the reason category on the document and the reason staff keep, the invoice's
-- remaining HT the page showed (compare and set), optionally the file it is limited to. Under the servicer's allocation
-- and remit locks (taken as an approval takes them), numbered last under the counter lock. Refusals (SQLSTATE 22023 or
-- 23514, French on the page): not an invoice (a credit note on a credit note), nothing left to credit, a run in flight
-- sets it off, the file has nothing on it, the amount missing or above what is left, the invoice changed since the page
-- read it. Another servicer's invoice is « not allowed » (42501).
create or replace function public.issue_credit_note(p_idempotency_key text, p_invoice_id uuid, p_amount_ht_text text,
                                                    p_reason_code text, p_reason text, p_expected_remaining_text text,
                                                    p_account_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  i public.commission_invoice;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_amount bigint := private.euros_to_minor(p_amount_ht_text);
  v_request jsonb := jsonb_build_object('invoice_id', p_invoice_id, 'amount', p_amount_ht_text,
                                        'reason_code', p_reason_code, 'reason', v_reason,
                                        'expected_remaining', p_expected_remaining_text, 'account_id', p_account_id);
  v_result jsonb;
  v_plan jsonb;
  v_id uuid := gen_random_uuid();
  v_docs jsonb;
  v_issued jsonb;
  v_label text := private.manual_credit_reason_fr(p_reason_code);
begin
  select * into i from public.commission_invoice where id = p_invoice_id;
  if not found or not private.has_role(i.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('issue_credit_note', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_label is null then
    raise exception 'credit note refused: reason_code' using errcode = '22023';
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'credit note refused: reason_required' using errcode = '22023';
  end if;
  if v_amount is null or v_amount <= 0 then
    raise exception 'credit note refused: amount_required' using errcode = '22023';
  end if;
  -- lock order (ADR-0014): allocation lock → remit lock → invoice counter (last, in issue_commission_documents)
  perform private.remittance_command_locks(i.organization_id, true);
  v_plan := private.manual_credit_plan(i.id, v_amount, p_account_id);
  if v_plan ->> 'refusal' is not null then
    raise exception 'credit note refused: %', v_plan ->> 'refusal' using errcode = 'check_violation';
  end if;
  if p_expected_remaining_text is distinct from v_plan ->> 'remaining_ht' then
    raise exception 'credit note refused: invoice_changed' using errcode = 'check_violation';
  end if;
  v_docs := jsonb_build_array(jsonb_build_object(
    'id', v_id, 'ref', 'manual', 'key', 'crn-manual:' || v_id, 'kind', 'credit_note', 'mandate_id', i.mandate_id,
    'ht', (-v_amount)::text, 'vat', (-(v_plan ->> 'vat')::bigint)::text,
    'ttc', (-(v_plan ->> 'ttc')::bigint)::text, 'settlement', 'netted',
    'service_from', i.service_from, 'service_to', i.service_to,
    'lines', jsonb_build_array(jsonb_build_object(
      'kind', 'credit',
      'designation_fr', 'Avoir rectifiant la facture ' || i.number || ' du ' || to_char(i.issue_date, 'DD/MM/YYYY')
                        || ' — rectification d''une ' || v_label,
      'ht', (-v_amount)::text, 'vat_rate', i.vat_rate::text, 'original_invoice_id', i.id)),
    'allocations', (select jsonb_agg(jsonb_build_object('original_invoice_id', i.id, 'account_id', a ->> 'account_id',
                                                        'tier_key', a ->> 'tier_key',
                                                        'ht', (-(a ->> 'ht')::bigint)::text))
                    from jsonb_array_elements(v_plan -> 'allocations') a),
    'corrections', jsonb_build_array(jsonb_build_object(
      'original_invoice_id', i.id, 'vat_rate', i.vat_rate::text, 'ht', (-v_amount)::text,
      'vat', (-(v_plan ->> 'vat')::bigint)::text, 'vat_pending', v_plan ->> 'vat_pending',
      'vat_collected', v_plan ->> 'vat_collected', 'applied', v_plan ->> 'applied', 'excess', v_plan ->> 'excess',
      'open_before', v_plan ->> 'open_before'))));
  v_issued := private.issue_commission_documents(i.organization_id, i.client_organization_id, null, v_docs, 'manual');
  -- the waiver per (invoice, key) and each key's state: V unchanged, its waiver grown (Σ open + Σ waived = V)
  insert into public.commission_waiver (organization_id, client_organization_id, invoice_id, account_id, tier_key,
                                        amount_minor, cause, credit_note_id)
  select i.organization_id, i.client_organization_id, i.id, (a ->> 'account_id')::uuid, a ->> 'tier_key',
         (a ->> 'ht')::bigint, 'credit_note', v_id
  from jsonb_array_elements(v_plan -> 'allocations') a;
  insert into public.remittance_key_state (organization_id, client_organization_id, account_id, tier_key, run_id, cause,
                                           credit_note_id, basis, kept_basis_minor, kept_minor, commission_minor,
                                           waived_minor)
  select i.organization_id, i.client_organization_id, (a ->> 'account_id')::uuid, a ->> 'tier_key', null,
         'credit_note', v_id, s.basis, s.kept_basis_minor, s.kept_minor, s.commission_minor,
         s.waived_minor + (a ->> 'ht')::bigint
  from jsonb_array_elements(v_plan -> 'allocations') a
  left join lateral (select x.basis, x.kept_basis_minor, x.kept_minor, x.commission_minor, x.waived_minor
                     from public.remittance_key_state x
                     where x.account_id = (a ->> 'account_id')::uuid and x.tier_key = a ->> 'tier_key'
                     order by x.seq desc limit 1) s on true;
  -- the engine's input check, per key credited: what the invoices still charge plus the waivers is the commission
  -- charged, the waivers the state's (keyed, per key)
  if exists (select 1 from jsonb_array_elements(v_plan -> 'allocations') a
             cross join lateral (select k.commission_minor, k.waived_minor from public.remittance_key_state k
                                 where k.account_id = (a ->> 'account_id')::uuid and k.tier_key = a ->> 'tier_key'
                                 order by k.seq desc limit 1) st
             cross join lateral private.commission_key_open((a ->> 'account_id')::uuid, a ->> 'tier_key') o
             where st.commission_minor is null or o.open_minor + o.waived_minor <> st.commission_minor
                or o.waived_minor <> st.waived_minor or o.negative) then
    raise exception 'credit note on %: the tier history and the documents disagree', i.number using errcode = '23514';
  end if;
  insert into public.manual_credit_note (credit_note_id, organization_id, client_organization_id, invoice_id,
                                         account_id, amount_minor, reason_code, reason, issued_by)
  values (v_id, i.organization_id, i.client_organization_id, i.id, p_account_id, v_amount, p_reason_code, v_reason,
          auth.uid());
  v_result := jsonb_build_object('credit_note_id', v_id, 'number', v_issued #>> '{documents,manual,number}',
                                 'issue_date', v_issued ->> 'issue_date', 'invoice_id', i.id,
                                 'invoice_number', i.number, 'ht', v_plan ->> 'ht', 'vat', v_plan ->> 'vat',
                                 'ttc', v_plan ->> 'ttc', 'applied', v_plan ->> 'applied',
                                 'excess', v_plan ->> 'excess', 'remaining_after', v_plan ->> 'remaining_after',
                                 'open_after', v_plan ->> 'open_after');
  perform private.command_record('issue_credit_note', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- What a (file, tier key)'s invoices still charge it and the waivers they hold (the engine's input: Σ open + Σ waived =
-- the commission charged); `negative` when an (invoice, key) waiver is below 0. Keyed: the key's charges by their index,
-- each charge's credits and waivers by theirs.
create or replace function private.commission_key_open(p_account_id uuid, p_tier_key text)
returns table (open_minor bigint, waived_minor bigint, negative boolean)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(sum(ch.charged_minor + c.credited), 0)::bigint, coalesce(sum(w.waived), 0)::bigint,
         coalesce(bool_or(w.waived < 0), false)
  from public.commission_invoice_charge ch
  cross join lateral (select coalesce(sum(a.ht_minor), 0) as credited from public.commission_credit_alloc a
                      where a.original_invoice_id = ch.invoice_id and a.account_id = ch.account_id
                        and a.tier_key = ch.tier_key) c
  cross join lateral (select coalesce(sum(x.amount_minor), 0) as waived from public.commission_waiver x
                      where x.invoice_id = ch.invoice_id and x.account_id = ch.account_id
                        and x.tier_key = ch.tier_key) w
  where ch.account_id = p_account_id and ch.tier_key = p_tier_key;
$$;

-- The page's effect sheet (« Émettre un avoir »): what the credit note would be, from the same plan as the command.
-- Money staff at aal2 (the page shows the form to admins only; the command refuses anyone else).
create or replace function public.credit_note_preview(p_invoice_id uuid, p_amount_ht_text text,
                                                      p_account_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  i public.commission_invoice;
  v_amount bigint := private.euros_to_minor(p_amount_ht_text);
begin
  select * into i from public.commission_invoice where id = p_invoice_id;
  if not found or not private.has_role(i.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if v_amount is null or v_amount <= 0 then
    return jsonb_build_object('refusal', 'amount_required');
  end if;
  return private.manual_credit_plan(i.id, v_amount, p_account_id);
end;
$$;

-- The back-office invoice page: the document, what it still charges (HT) and owes (TTC), its pending VAT, the files it
-- charges (by what is still open, at most 200, with their references), the credit notes that rectify it (a manual one's
-- reason category and, for staff, its reason), whether a manual credit note can be issued and why not. Money staff at
-- aal2; `can_credit` for admins.
create or replace function public.commission_invoice_detail(p_invoice_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  i public.commission_invoice;
  v_credited bigint;
  v_files jsonb;
  v_notes jsonb;
  v_file_count integer;
begin
  select * into i from public.commission_invoice where id = p_invoice_id;
  if not found or not private.has_role(i.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_credited := coalesce((select -sum(c.ht_minor) from public.commission_credit_correction c
                          where c.original_invoice_id = i.id), 0);
  select count(*), coalesce(jsonb_agg(jsonb_build_object('account_id', f.account_id, 'reference', f.reference,
                                                         'open_ht', f.open::text, 'waived_ht', f.waived::text)
                                      order by f.open desc, f.reference) filter (where f.n <= 200), '[]')
  into v_file_count, v_files
  from (select x.*, row_number() over (order by x.open desc, x.reference) as n
        from (select ch.account_id, min(a.reference) as reference, sum(ch.charged_minor + c.credited) as open,
                     sum(w.waived) as waived
              from public.commission_invoice_charge ch
              cross join lateral (select coalesce(sum(x.ht_minor), 0) as credited from public.commission_credit_alloc x
                                  where x.original_invoice_id = ch.invoice_id and x.account_id = ch.account_id
                                    and x.tier_key = ch.tier_key) c
              cross join lateral (select coalesce(sum(y.amount_minor), 0) as waived from public.commission_waiver y
                                  where y.invoice_id = ch.invoice_id and y.account_id = ch.account_id
                                    and y.tier_key = ch.tier_key) w
              cross join lateral (select q.external_ref as reference from public.account q
                                  where q.id = ch.account_id offset 0) a
              where ch.invoice_id = i.id
              group by ch.account_id) x) f;
  select coalesce(jsonb_agg(jsonb_build_object('id', cn.id, 'number', cn.number, 'issue_date', cn.issue_date,
                                               'reason', cn.reason, 'ht', c.ht_minor::text, 'vat', c.vat_minor::text,
                                               'run_number', r.number, 'reason_code', m.reason_code,
                                               'reason_text', m.reason,
                                               'reason_fr', private.manual_credit_reason_fr(m.reason_code))
                            order by cn.year, cn.seq), '[]')
  into v_notes
  from public.commission_credit_correction c
  join public.commission_invoice cn on cn.id = c.credit_note_id
  left join public.remittance_run r on r.id = cn.run_id
  left join public.manual_credit_note m on m.credit_note_id = cn.id
  where c.original_invoice_id = i.id;
  return jsonb_build_object(
    'id', i.id, 'number', i.number, 'kind', i.kind, 'reason', i.reason, 'issue_date', i.issue_date,
    'client_id', i.client_organization_id,
    'client_name', (select o.legal_name from public.organization o where o.id = i.client_organization_id),
    'mandate_reference', (select m.reference from public.mandate m where m.id = i.mandate_id),
    'run_id', i.run_id, 'run_number', (select r.number from public.remittance_run r where r.id = i.run_id),
    'service_from', i.service_from, 'service_to', i.service_to, 'settlement', i.settlement, 'due_date', i.due_date,
    'ht', i.ht_minor::text, 'vat', i.vat_minor::text, 'ttc', i.ttc_minor::text, 'vat_rate', i.vat_rate::text,
    'credited_ht', v_credited::text, 'remaining_ht', (i.ht_minor - v_credited)::text,
    'open_ttc', private.document_open(i.id)::text, 'pending_vat', private.document_pending_vat(i.id)::text,
    'files', v_files, 'file_count', v_file_count, 'credit_notes', v_notes,
    'refusal', private.manual_credit_refusal(i, i.ht_minor - v_credited),
    'can_credit', private.has_role(i.organization_id, array['admin']));
end;
$$;

------------------------------------------------------------------------------------------
-- Redefined (M2c-5b), with their settings and grants restated
------------------------------------------------------------------------------------------

-- The tier history the prepare continues from (review perf#7; M2c-5b: with the waiver): the latest state of each
-- (file, tier key) asked for, one keyed read per key. Dropped and created: its return type gains waived_minor.
drop function private.remittance_key_states(uuid[], text[]);
create function private.remittance_key_states(p_account_ids uuid[], p_tier_keys text[])
returns table (account_id uuid, tier_key text, basis jsonb, kept_basis_minor bigint, kept_minor bigint,
               commission_minor bigint, waived_minor bigint)
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select k.account_id, k.tier_key, s.basis, s.kept_basis_minor, s.kept_minor, s.commission_minor, s.waived_minor
  from unnest(p_account_ids, p_tier_keys) k (account_id, tier_key)
  cross join lateral (select x.basis, x.kept_basis_minor, x.kept_minor, x.commission_minor, x.waived_minor
                      from public.remittance_key_state x
                      where x.account_id = k.account_id and x.tier_key = k.tier_key
                      order by x.seq desc limit 1) s;
$$;

-- Redefined from 20261112090000 (M2c-5b): a manual credit note's key state (no run) counts in the history the draft
-- assumed, so a draft prepared before one is sent back (`history_changed`).
create or replace function private.remittance_approval_refusal(p_run public.remittance_run,
                                                               p_draft private.remittance_draft, p_today date)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owed bigint;
  v_inflight bigint;
  v_blockers text[];
  v_bad text;
begin
  if p_draft.run_id is null then
    return 'not_prepared';
  end if;
  if (select count(*) from private.remittance_pending q where q.draft_run_id = p_run.id) <> p_run.item_count then
    return 'items_changed';
  end if;
  if jsonb_array_length(p_draft.documents) > 0 and private.vat_rate_on(p_today) <> p_draft.vat_rate then
    return 'vat_rate_changed';
  end if;
  -- the VAT book the plan assumed for the run's invoices (money review #1): 44571 at once on debits, else 44574
  if jsonb_array_length(p_draft.documents) > 0
     and coalesce((select s.vat_on_debits from public.servicer_billing_settings s
                   where s.organization_id = p_run.organization_id), false) <> p_draft.vat_on_debits then
    return 'vat_option_changed';
  end if;
  if jsonb_array_length(p_draft.documents) > 0
     and cardinality(private.remittance_commission_blockers(p_run.client_organization_id)) > 0 then
    return 'commission_blocked';
  end if;
  -- the client's proceeding the plan's set-offs assumed (§9.6, L622-7 I; money review #2): recorded or in force since
  if exists (select 1 from jsonb_array_elements(coalesce(p_draft.plan -> 'settles', '[]')) s
             where s ->> 'kind' in ('compensation', 'advance'))
     and (select min(e.effective_date) from public.client_status_event e
          where e.client_organization_id = p_run.client_organization_id and e.kind = 'proceeding_opened'
            and e.effective_date <= p_today) is distinct from p_draft.proceeding_opened_on then
    return 'client_status_changed';
  end if;
  if p_run.net_minor > 0 then
    v_blockers := private.remittance_payout_blockers(p_run.client_organization_id, p_run.currency, p_today);
    if cardinality(v_blockers) > 0 then
      return 'payout_blocked:' || v_blockers[1];
    end if;
    if p_run.payout_account_id is distinct from (
         select pa.id from public.client_payout_account pa
         where pa.client_organization_id = p_run.client_organization_id and pa.currency = p_run.currency
           and pa.status = 'active') then
      return 'payout_account_changed';
    end if;
    v_bad := private.execution_date_refusal(p_run.organization_id, p_run.currency, p_run.requested_execution_date);
    if v_bad is not null then
      return v_bad;
    end if;
    if p_run.requested_execution_date > p_run.earliest_latest_execution_date and p_run.late_reason is null then
      return 'late_reason_required';
    end if;
  end if;
  -- N = 0 settles today: after the latest execution date, the reason too (money review #3)
  if p_run.net_minor = 0 and p_today > p_run.earliest_latest_execution_date and p_run.late_reason is null then
    return 'late_reason_required';
  end if;
  if p_run.net_minor < 0 then
    return 'negative_net';
  end if;
  -- the cap (§9.5, ledger critique #1): gross ≤ what the client is owed less the runs in flight
  select -b.balance_minor into v_owed from private.client_payable_balance b
  where b.client_organization_id = p_run.client_organization_id and b.currency = p_run.currency;
  select coalesce(sum(x.net_minor + x.settlement_minor), 0) into v_inflight from public.remittance_run x
  where x.client_organization_id = p_run.client_organization_id and x.currency = p_run.currency
    and x.status in ('approved', 'sent') and x.id <> p_run.id;
  if p_run.gross_minor > coalesce(v_owed, 0) - v_inflight then
    return 'balance_changed';
  end if;
  -- the tier history and the documents the plan continued from (the run's own key states, written before the locks
  -- in this transaction, excepted; a manual credit note's key state has no run and counts: M2c-5b)
  if coalesce((select max(k.seq) from public.remittance_key_state k
               where k.client_organization_id = p_run.client_organization_id
                 and k.run_id is distinct from p_run.id), 0)
     <> p_draft.history_seq then
    return 'history_changed';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_draft.plan -> 'settles', '[]')) s
             where (s ->> 'ref') !~ '^new' and private.document_open((s ->> 'ref')::uuid) <> (s ->> 'open_before')::bigint)
     or exists (select 1 from jsonb_array_elements(p_draft.documents) d
                cross join lateral jsonb_array_elements(coalesce(d -> 'corrections', '[]')) c
                where private.document_open((c ->> 'original_invoice_id')::uuid) <> (c ->> 'open_before')::bigint) then
    return 'documents_changed';
  end if;
  return null;
end;
$$;


-- Redefined from 20261112090000 (M2c-5b): the key states carry their waiver, and what the run's credits absorb of
-- manual credit notes' waivers is recorded with them.
create or replace function private.approve_remittance_run(p_run_id uuid, p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '10s'
as $$
declare
  r public.remittance_run;
  d private.remittance_draft;
  pa public.client_payout_account;
  v_today date;
  v_why text;
  v_docs jsonb;
  v_ids jsonb := '{}';
  v_issued jsonb;
  v_n integer;
  v_plan jsonb;
  v_bank uuid;
  v_transfer uuid;
  v_info text;
  v_entry uuid;
  v_late boolean;
begin
  select * into r from public.remittance_run where id = p_run_id for update;
  if not found or r.status <> 'draft' or r.job is distinct from 'approve' or r.job_token is distinct from p_token then
    return jsonb_build_object('status', 'skipped');
  end if;
  select * into d from private.remittance_draft where run_id = r.id;
  if r.net_minor > 0 then
    select * into pa from public.client_payout_account where id = r.payout_account_id for key share;
    v_bank := private.paying_account(r.organization_id, r.currency);
    perform 1 from public.bank_account b where b.id = v_bank for share;
  end if;
  -- the documents' ids first (the lines name their invoice; the foreign key is checked at commit)
  select coalesce(jsonb_agg(x.doc || jsonb_build_object('id', gen_random_uuid(),
                                                        'key', case x.doc ->> 'kind' when 'invoice' then 'inv:'
                                                                                     else 'crn:' end
                                                               || r.id || ':' || (x.doc ->> 'mandate_id'))
                            order by x.ord), '[]')
  into v_docs from jsonb_array_elements(coalesce(d.documents, '[]')) with ordinality x (doc, ord);
  select coalesce(jsonb_object_agg(x ->> 'ref', x ->> 'id'), '{}') into v_ids from jsonb_array_elements(v_docs) x;

  begin
    -- The frozen facts, written under the run's row lock only, before the allocation lock (performance review #4):
    -- the lines, their repricings, the tier history (with what the run's credits absorb of manual credit notes'
    -- waivers, M2c-5b: a manual credit note since the prepare is caught by `history_changed`) and the invoices'
    -- charges depend only on the draft and on
    -- immutable entries; the refusal below rolls them back with this block. Holding the allocation lock is then the
    -- checks, the queue, the numbering and posting of the documents and the payout (each item in exactly one live
    -- line, I15), then the deferred checks at commit: 5k lines, 0.09 s + 0.07 s of a 0.83 s job (all of it before).
    -- The row locks these inserts take on what the lines name are key-share locks, taken (as every command takes its
    -- row locks) before the advisory lock: no lock cycle with an allocation.
    insert into public.remittance_line (run_id, line_no, organization_id, client_organization_id, currency,
                                        ledger_entry_id, kind, account_id, portfolio_id, mandate_id, mandate_terms_id,
                                        payment_id, encaissement_date, effective_date, posted_at, deadline,
                                        latest_execution_date, unmeetable, amount_minor, basis, commission_minor,
                                        commission_state, commission_reason, parts, original_entry_id, invoice_id)
    select l.run_id, l.line_no, r.organization_id, r.client_organization_id, r.currency, l.ledger_entry_id, l.kind,
           l.account_id, l.portfolio_id, l.mandate_id, l.mandate_terms_id, l.payment_id, l.encaissement_date,
           l.effective_date, l.posted_at, l.deadline, l.latest_execution_date, l.unmeetable, l.amount_minor, l.basis,
           l.commission_minor, l.commission_state, l.commission_reason, l.parts, l.original_entry_id,
           case when l.invoiced then (v_ids ->> ('new:' || l.mandate_id))::uuid end
    from private.remittance_draft_line l where l.run_id = r.id;
    get diagnostics v_n = row_count;
    insert into public.remittance_line_repricing (pricing_run_id, run_id, line_no, ledger_entry_id, commission_minor,
                                                  commission_state, commission_reason, parts, invoice_id)
    select r.id, x.line_run_id, x.line_no, x.ledger_entry_id, x.commission_minor, x.commission_state,
           x.commission_reason, x.parts,
           case when x.invoiced then (v_ids ->> ('new:' || l.mandate_id))::uuid end
    from private.remittance_draft_repricing x
    join public.remittance_line l on l.run_id = x.line_run_id and l.line_no = x.line_no
    where x.run_id = r.id;
    insert into public.remittance_key_state (organization_id, client_organization_id, account_id, tier_key, run_id,
                                             cause, basis, kept_basis_minor, kept_minor, commission_minor,
                                             waived_minor)
    select r.organization_id, r.client_organization_id, (k ->> 'account_id')::uuid, k ->> 'tier_key', r.id, 'approved',
           coalesce(k -> 'basis', '[]'), (k ->> 'kept_basis')::bigint, (k ->> 'kept')::bigint,
           (k ->> 'commission')::bigint, coalesce((k ->> 'waived')::bigint, 0)
    from jsonb_array_elements(coalesce(d.key_states, '[]')) k;
    -- what the run's credits absorb of the waivers manual credit notes left on earlier invoices (M2c-5b): no document
    -- carries it; the waiver's guard keeps each (invoice, key) balance between 0 and what was waived
    insert into public.commission_waiver (organization_id, client_organization_id, invoice_id, account_id, tier_key,
                                          amount_minor, cause, run_id, entry_id)
    select r.organization_id, r.client_organization_id, (w ->> 0)::uuid, (k ->> 'account_id')::uuid, k ->> 'tier_key',
           -(w ->> 1)::bigint, 'absorbed', r.id, (w ->> 2)::uuid
    from jsonb_array_elements(coalesce(d.key_states, '[]')) k
    cross join lateral jsonb_array_elements(coalesce(k -> 'absorbed', '[]')) w;
    -- what the run's invoices charge each (file, tier key) (one row per file at 50k; the invoices numbered below)
    insert into public.commission_invoice_charge (invoice_id, account_id, tier_key, charged_minor)
    select (x.doc ->> 'id')::uuid, (c ->> 'account_id')::uuid, c ->> 'tier_key', (c ->> 'amount')::bigint
    from jsonb_array_elements(v_docs) x (doc)
    cross join lateral jsonb_array_elements(coalesce(x.doc -> 'charges', '[]')) c
    where x.doc ->> 'kind' = 'invoice';

    -- lock order (ADR-0014): the run row → allocation lock → remit lock → invoice counter (last, in
    -- issue_commission_documents)
    perform pg_advisory_xact_lock(hashtext('payments:' || r.organization_id::text));
    perform pg_advisory_xact_lock(hashtext('remit:' || r.organization_id::text));
    v_today := private.paris_today();
    v_why := private.remittance_approval_refusal(r, d, v_today);
    if v_why is not null then
      raise exception '%', v_why using errcode = 'RR001';
    end if;
    if v_n <> r.line_count then
      raise exception 'approval of %: % lines frozen for % prepared', r.number, v_n, r.line_count
        using errcode = '23514';
    end if;
    -- their items leave the pending queue
    delete from private.remittance_pending q where q.draft_run_id = r.id;

    -- invoices and credit notes, numbered (the counter locked last), their entries posted, in the VAT book the plan
    -- assumed (money review #1)
    v_issued := private.issue_commission_documents(r.organization_id, r.client_organization_id, r.id,
                                                   (select coalesce(jsonb_agg(x.doc - 'charges' order by x.ord), '[]')
                                                    from jsonb_array_elements(v_docs) with ordinality x (doc, ord)),
                                                   'commission', d.vat_on_debits);

    -- the plan with the run's documents named (M2c-6 posts it at the debit)
    select d.plan || jsonb_build_object('settles', coalesce(jsonb_agg(
             s || jsonb_build_object('document_id', coalesce(v_ids ->> (s ->> 'ref'), s ->> 'ref'))), '[]'))
    into v_plan from jsonb_array_elements(coalesce(d.plan -> 'settles', '[]')) s;

    v_late := private.business_days_between((r.known_at at time zone 'Europe/Paris')::date, v_today) > 2;
    if r.net_minor > 0 then
      select left('REVERSEMENT ' || r.number || coalesce(' FACTURE ' || string_agg(i.number, ' ' order by i.seq), ''),
                  140)
      into v_info from public.commission_invoice i where i.run_id = r.id and i.kind = 'invoice';
      insert into public.bank_transfer (organization_id, client_organization_id, kind, debtor_bank_account_id, currency,
                                        amount_minor, payee_name, payee_iban, payee_bic, end_to_end_id,
                                        remittance_info, requested_execution_date, run_id, ordered_by)
      values (r.organization_id, r.client_organization_id, 'payout', v_bank, r.currency, r.net_minor, pa.holder_name,
              pa.iban, pa.bic, 'RMT' || upper(substr(md5(gen_random_uuid()::text), 1, 12)), v_info,
              r.requested_execution_date, r.id, r.approval_requested_by)
      returning id into v_transfer;
      perform private.remittance_late_lines(r, r.requested_execution_date);
      update public.remittance_run set status = 'approved', approved_by = r.approval_requested_by,
        approved_at = clock_timestamp(), transfer_id = v_transfer, settlement_plan = v_plan, invoice_late = v_late,
        payout_snapshot = jsonb_build_object('payout_account_id', pa.id, 'holder_name', pa.holder_name,
                                             'iban', pa.iban, 'bic', pa.bic, 'kind', pa.kind,
                                             'confirmed_at', pa.confirmed_at),
        job = null, job_token = null, job_queued_at = null, version = version + 1
      where id = r.id;
      return jsonb_build_object('status', 'approved', 'transfer_id', v_transfer, 'documents', v_issued -> 'documents');
    end if;
    -- N = 0 (§9.5 step 5): nothing to transfer; the settlement is posted now and the run is booked — its date is the
    -- items' payment date (I21: « settled when N = 0 », money review #3)
    perform private.remittance_late_lines(r, v_today);
    v_entry := private.post_run_settlement(r.id, v_plan, v_today);
    update public.remittance_run set status = 'booked', booked_on = v_today, approved_by = r.approval_requested_by,
      approved_at = clock_timestamp(), settlement_plan = v_plan || jsonb_build_object('entry_id', v_entry),
      invoice_late = v_late, job = null, job_token = null, job_queued_at = null, version = version + 1
    where id = r.id;
    return jsonb_build_object('status', 'booked', 'entry_id', v_entry, 'documents', v_issued -> 'documents');
  exception when sqlstate 'RR001' then
    -- a business refusal: everything above rolled back, the locks released; back to draft with the reason
    perform private.remittance_back_to_draft(r.id, p_token, sqlerrm, null);
    return jsonb_build_object('status', 'back_to_draft', 'reason', sqlerrm);
  end;
end;
$$;


-- Redefined from 20261112090000 (M2c-5b): the run's own invoices' waivers cleared, what its credits absorbed
-- restored, the key states back to before the run with the waiver their invoices hold now, the engine's input check
-- with the waivers.
create or replace function public.cancel_remittance_run(p_idempotency_key text, p_run_id uuid,
                                                        p_expected_version integer, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  r public.remittance_run;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('run_id', p_run_id, 'expected_version', p_expected_version, 'reason', v_reason);
  v_result jsonb;
  v_docs jsonb;
  v_restore jsonb;
  v_issued jsonb;
  v_n integer;
  v_today date := private.paris_today();
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or not private.has_role(r.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('cancel_remittance_run', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  select * into r from public.remittance_run where id = p_run_id for update;
  perform private.remittance_command_locks(r.organization_id, true);
  if r.status <> 'approved' then
    raise exception 'remittance run refused: %', case r.status when 'draft' then 'draft_use_discard'
                                                               when 'sent' then 'already_sent'
                                                               else 'not_cancellable' end
      using errcode = 'check_violation';
  end if;
  if p_expected_version is distinct from r.version then
    raise exception 'remittance run refused: version_changed' using errcode = 'check_violation';
  end if;
  update public.bank_transfer set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = clock_timestamp(),
    cancel_reason = 'Reversement ' || r.number || ' annulé : ' || v_reason
  where run_id = r.id and kind = 'payout' and status = 'ordered';
  if exists (select 1 from public.bank_transfer t where t.run_id = r.id and t.status not in ('ordered', 'cancelled')) then
    raise exception 'remittance run refused: transfer_in_file' using errcode = 'check_violation';
  end if;

  -- 1. one full credit note per invoice of the run: what each still charges each key, its VAT by cumulative
  -- difference at the invoice's own rate, off its pending VAT first
  with inv as (
    select i.*, coalesce((select -sum(c.ht_minor) from public.commission_credit_correction c
                          where c.original_invoice_id = i.id), 0) as credited_before,
           private.document_open(i.id) as open_before, private.document_pending_vat(i.id) as pending_before
    from public.commission_invoice i where i.run_id = r.id and i.kind = 'invoice' and i.reason = 'commission'),
  keys as (
    select i.id as invoice_id, ch.account_id, ch.tier_key,
           ch.charged_minor + coalesce((select sum(a.ht_minor) from public.commission_credit_alloc a
                                        where a.original_invoice_id = ch.invoice_id and a.account_id = ch.account_id
                                          and a.tier_key = ch.tier_key), 0) as open
    from inv i join public.commission_invoice_charge ch on ch.invoice_id = i.id),
  amounts as (
    select i.*, k.ht, round((i.credited_before + k.ht) * i.vat_rate) - round(i.credited_before * i.vat_rate) as vat
    from inv i join (select invoice_id, sum(open) as ht from keys where open > 0 group by invoice_id) k
      on k.invoice_id = i.id)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', gen_random_uuid(), 'ref', 'cancel:' || a.id, 'key', 'crn-cancel:' || a.id, 'kind', 'credit_note',
           'mandate_id', a.mandate_id, 'ht', (-a.ht)::text, 'vat', (-a.vat)::bigint::text,
           'ttc', (-a.ht - a.vat)::bigint::text,
           'lines', jsonb_build_array(jsonb_build_object(
             'kind', 'credit', 'designation_fr', 'Annulation du reversement ' || r.number || ' — avoir rectifiant la '
                                                  || 'facture ' || a.number || ' du ' || to_char(a.issue_date, 'DD/MM/YYYY'),
             'ht', (-a.ht)::text, 'vat_rate', a.vat_rate::text, 'original_invoice_id', a.id)),
           'allocations', (select jsonb_agg(jsonb_build_object('original_invoice_id', k.invoice_id,
                                                               'account_id', k.account_id, 'tier_key', k.tier_key,
                                                               'ht', (-k.open)::text)
                                            order by k.account_id, k.tier_key)
                           from keys k where k.invoice_id = a.id and k.open > 0),
           'corrections', jsonb_build_array(jsonb_build_object(
             'original_invoice_id', a.id, 'vat_rate', a.vat_rate::text, 'ht', (-a.ht)::text,
             'vat', (-a.vat)::bigint::text,
             'vat_pending', least(a.vat::bigint, a.pending_before)::text,
             'vat_collected', (a.vat::bigint - least(a.vat::bigint, a.pending_before))::text,
             'applied', least(a.ht + a.vat::bigint, a.open_before)::text,
             'excess', (a.ht + a.vat::bigint - least(a.ht + a.vat::bigint, a.open_before))::text,
             'open_before', a.open_before::text))) order by a.seq), '[]')
  into v_docs from amounts a;

  -- 2. the run's own credit notes on earlier invoices undone (money review #0): per mandate and VAT rate, one corrective
  -- invoice charging again, per (file, tier key), the HT they took back, at each credited invoice's own rate — so that
  -- the tier history goes back exactly as before the run and the next run credits each reversal once (on this invoice:
  -- it charges the line now). Its VAT is its own HT's, R(HT × rate) half up as every invoice's (242 nonies A 11°) and
  -- as the engine assumes when it credits it (round 2: the sum of the VATs credited, each by cumulative difference on
  -- its own invoice, is not, and the re-run then credited a cent more than it charged, or left one pending); it differs
  -- from what was credited by under a cent per invoice credited, until the re-run credits it in full. Dated over the
  -- service periods of the invoices it charges again; settled as the mandate's terms say today — netted, set off on
  -- the next run at the latest by its due date, or due (legal review #4, round 2; OQ-72).
  with crd as (   -- per credit note of the run and invoice it corrected: what it took back
    select cn.mandate_id, cn.number as credit_number, c.original_invoice_id, o.number as original_number,
           o.issue_date as original_date, o.vat_rate, -c.ht_minor as ht, o.service_from, o.service_to, cn.seq
    from public.commission_invoice cn
    join public.commission_credit_correction c on c.credit_note_id = cn.id
    join public.commission_invoice o on o.id = c.original_invoice_id
    where cn.run_id = r.id and cn.kind = 'credit_note' and cn.reason = 'commission'),
  keys as (       -- per mandate, rate and (file, tier key): what they took back
    select cn.mandate_id, o.vat_rate, a.account_id, a.tier_key, -sum(a.ht_minor) as ht
    from public.commission_invoice cn
    join public.commission_credit_alloc a on a.credit_note_id = cn.id
    join public.commission_invoice o on o.id = a.original_invoice_id
    where cn.run_id = r.id and cn.kind = 'credit_note' and cn.reason = 'commission'
    group by cn.mandate_id, o.vat_rate, a.account_id, a.tier_key),
  docs as (
    select x.mandate_id, x.vat_rate, sum(x.ht) as ht, round(sum(x.ht) * x.vat_rate)::bigint as vat, m.reference,
           min(x.service_from) as service_from, max(x.service_to) as service_to,
           (select mt.remittance_terms from public.mandate_terms mt
            where mt.mandate_id = x.mandate_id and mt.valid_from <= v_today
              and (mt.valid_to is null or v_today < mt.valid_to)
            order by mt.valid_from desc limit 1) as terms
    from crd x join public.mandate m on m.id = x.mandate_id
    group by x.mandate_id, x.vat_rate, m.reference)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', gen_random_uuid(), 'ref', 'restore:' || d.mandate_id || ':' || d.vat_rate,
           'key', 'inv-restore:' || r.id || ':' || d.mandate_id || ':' || d.vat_rate, 'kind', 'invoice',
           'mandate_id', d.mandate_id, 'ht', d.ht::text, 'vat', d.vat::text, 'ttc', (d.ht + d.vat)::text,
           'vat_rate', d.vat_rate::text, 'service_from', d.service_from, 'service_to', d.service_to,
           'settlement', case when jsonb_typeof(d.terms -> 'netting') = 'object' then 'netted' else 'due' end,
           'payment', case when jsonb_typeof(d.terms -> 'netting') = 'object' then 'next_run' end,
           'due_days', coalesce((d.terms ->> 'invoice_payment_days')::integer, 30),
           'clause_ref', d.terms #>> '{netting,clause_ref}',
           'lines', (select jsonb_agg(jsonb_build_object(
                       'kind', 'commission',
                       'designation_fr', 'Annulation du reversement ' || r.number || ' — rétablissement de l''avoir '
                                         || x.credit_number || ' (facture ' || x.original_number || ' du '
                                         || to_char(x.original_date, 'DD/MM/YYYY') || ')',
                       'ht', x.ht::text, 'vat_rate', x.vat_rate::text) order by x.seq, x.original_number)
                     from crd x where x.mandate_id = d.mandate_id and x.vat_rate = d.vat_rate),
           'charges', (select jsonb_agg(jsonb_build_object('account_id', k.account_id, 'tier_key', k.tier_key,
                                                           'amount', k.ht::text) order by k.account_id, k.tier_key)
                       from keys k where k.mandate_id = d.mandate_id and k.vat_rate = d.vat_rate))
           order by d.reference, d.mandate_id, d.vat_rate), '[]')
  into v_restore from docs d;
  v_issued := private.issue_commission_documents(r.organization_id, r.client_organization_id, r.id,
                                                 v_docs || v_restore, 'run_cancelled');

  -- 3. the waivers (M2c-5b): the run's own invoices are credited in full above, so what manual credit notes left
  -- waived on them is cleared; what the run's credits absorbed of earlier invoices' waivers is restored on them (the
  -- corrective invoice charges again only what its credit notes credited)
  insert into public.commission_waiver (organization_id, client_organization_id, invoice_id, account_id, tier_key,
                                        amount_minor, cause, run_id)
  select r.organization_id, r.client_organization_id, w.invoice_id, w.account_id, w.tier_key, -sum(w.amount_minor),
         'run_cancelled', r.id
  from public.commission_invoice i
  join public.commission_waiver w on w.invoice_id = i.id
  where i.run_id = r.id and i.kind = 'invoice' and i.reason = 'commission'
  group by w.invoice_id, w.account_id, w.tier_key
  having sum(w.amount_minor) > 0;
  insert into public.commission_waiver (organization_id, client_organization_id, invoice_id, account_id, tier_key,
                                        amount_minor, cause, run_id)
  select r.organization_id, r.client_organization_id, w.invoice_id, w.account_id, w.tier_key, -sum(w.amount_minor),
         'restored', r.id
  from public.commission_waiver w
  where w.run_id = r.id and w.cause = 'absorbed'
  group by w.invoice_id, w.account_id, w.tier_key;

  -- 4. the lines released, their items back in the queue (posted when they were); the history exactly as before the
  -- run (its documents credited or restored: what the invoices still charge each key, plus the waivers, is that
  -- state's commission; the waiver the key's invoices hold now — manual credit notes since the run included)
  update public.remittance_line set released = true, released_at = clock_timestamp() where run_id = r.id;
  get diagnostics v_n = row_count;
  insert into private.remittance_pending (ledger_entry_id, organization_id, client_organization_id, currency, kind,
                                          amount_minor, posted_at)
  select l.ledger_entry_id, l.organization_id, l.client_organization_id, l.currency, l.kind, l.amount_minor, l.posted_at
  from public.remittance_line l where l.run_id = r.id;
  insert into public.remittance_key_state (organization_id, client_organization_id, account_id, tier_key, run_id, cause,
                                           basis, kept_basis_minor, kept_minor, commission_minor, waived_minor)
  select r.organization_id, r.client_organization_id, k.account_id, k.tier_key, r.id, 'cancelled',
         coalesce(p.basis, '[]'), coalesce(p.kept_basis_minor, 0), coalesce(p.kept_minor, 0),
         coalesce(p.commission_minor, 0), w.waived
  from public.remittance_key_state k
  left join lateral (select x.basis, x.kept_basis_minor, x.kept_minor, x.commission_minor
                     from public.remittance_key_state x
                     where x.account_id = k.account_id and x.tier_key = k.tier_key and x.seq < k.seq
                     order by x.seq desc limit 1) p on true
  cross join lateral (select coalesce(sum(y.amount_minor), 0) as waived from public.commission_waiver y
                      where y.account_id = k.account_id and y.tier_key = k.tier_key) w
  where k.run_id = r.id and k.cause = 'approved';
  -- (the engine's input check where the run credited earlier invoices or moved waivers — elsewhere the run's invoice
  -- is credited in full: what the invoices still charge each such key, plus their waivers, is the state's commission
  -- again, the waivers the state's; keyed, per such key)
  if exists (select 1
             from (select a.account_id, a.tier_key from public.commission_invoice cn
                   join public.commission_credit_alloc a on a.credit_note_id = cn.id
                   where cn.run_id = r.id and cn.kind = 'credit_note' and cn.reason = 'commission'
                   union
                   select w.account_id, w.tier_key from public.commission_waiver w where w.run_id = r.id
                   offset 0) x
             cross join lateral (select k.commission_minor, k.waived_minor from public.remittance_key_state k
                                 where k.account_id = x.account_id and k.tier_key = x.tier_key
                                 order by k.seq desc limit 1) st
             cross join lateral private.commission_key_open(x.account_id, x.tier_key) o
             where o.open_minor + o.waived_minor <> st.commission_minor or o.waived_minor <> st.waived_minor
                or o.negative) then
    raise exception 'cancellation of %: the tier history and the documents disagree', r.number using errcode = '23514';
  end if;
  update public.remittance_run set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = clock_timestamp(),
    cancel_reason = v_reason, version = version + 1
  where id = r.id;
  v_result := jsonb_build_object('run_id', r.id, 'status', 'cancelled', 'lines_released', v_n,
                                 'credit_notes', v_issued -> 'documents');
  perform private.command_record('cancel_remittance_run', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


-- Redefined from 20261113090000 (M2c-5b): I16 counts what the run's credits absorbed of waivers; I22 checks the
-- key states.
create or replace function private.run_remittance_checks(p_check_run_id uuid, p_organization_id uuid,
                                                         p_today date default null)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_today date := coalesce(p_today, private.paris_today());
  v_since timestamptz;      -- the previous check run of the servicer
  v_full boolean;           -- I16 over every run (Sundays, or the first check run), else over the runs changed lately
  v_failures timestamptz;   -- the schedule's failures reported from (at least the last 24 hours)
begin
  select max(c.started_at) into v_since from public.payment_check_run c
  where c.organization_id = p_organization_id and c.id <> p_check_run_id and c.finished_at is not null;
  v_full := v_since is null or extract(isodow from v_today) = 7;
  v_failures := least(coalesce(v_since, clock_timestamp()), clock_timestamp() - interval '24 hours');

  with dl as materialized (     -- the collections waiting, of files under a mandate with terms (review legal#2)
    select * from private.pending_item_deadlines(p_organization_id) d where d.monitored),
  ol as materialized (          -- the collections of runs approved or sent, not debited by their date (legal#3)
    select * from private.inflight_overdue_lines(p_organization_id, v_today)),
  ua as materialized (          -- money matched to a file, not allocated (legal#7, perf#0)
    select * from private.unallocated_payment_deadlines(p_organization_id)),
  -- I21: a positive collection not paid by its latest execution date — one month after E when its mandate's delay
  -- cannot be met (review legal#1) — writes a breach row, once; one the calendar cannot place has no date to hold it
  -- to (its alert below)
  waiting_breach as (
    insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                   run_id, deadline, latest_execution_date)
    select p_organization_id, d.client_organization_id, d.ledger_entry_id, d.payment_id, d.draft_run_id,
           d.check_deadline, d.check_latest_execution_date
    from dl d where not d.out_of_horizon and d.check_latest_execution_date < v_today
    on conflict (ledger_entry_id) do nothing),
  -- … and so does a collection whose run was approved but whose payout is not debited by then (§9.2: paid means
  -- debited; until M2c-6 books payouts, every approved run's collections are held to it)
  inflight_breach as (
    insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                   run_id, deadline, latest_execution_date, requested_execution_date,
                                                   late_reason)
    select p_organization_id, o.client_organization_id, o.ledger_entry_id, o.payment_id, o.run_id, o.deadline,
           o.latest_execution_date, o.requested_execution_date, o.late_reason
    from ol o where not o.out_of_horizon
    on conflict (ledger_entry_id) do nothing)
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, u.code, u.severity, u.subject_type, u.subject_id, u.currency,
         u.amount_minor, u.count, u.oldest_days, coalesce(u.details, '{}')
  from (
  -- (I14 is in run_payment_checks)
  -- I15: an item both waiting and in a live line
  select 'remittance_item_twice'::text, 'violation'::text, 'ledger_entry'::text, q.ledger_entry_id, q.currency::char(3),
         q.amount_minor::bigint, null::integer, null::integer, '{}'::jsonb
  from private.remittance_pending q
  join public.remittance_line l on l.ledger_entry_id = q.ledger_entry_id and not l.released
  where q.organization_id = p_organization_id
  union all
  -- I16: a run's arithmetic — gross = Σ lines, N + D = gross, N ≥ 0, the payout = N, documents' HT plus what the
  -- run's credits absorbed of manual credit notes' waivers (M2c-5b) = Σ line commissions. A run's lines and totals are frozen once approved: each run is read in one pass over its lines, the
  -- runs changed since the previous check run (with a day's margin), every run on Sundays (review perf#5).
  select 'remittance_run_totals', 'violation', 'remittance_run', r.id, r.currency, r.gross_minor, null, null,
         jsonb_build_object('number', r.number, 'lines_minor', l.gross::text, 'documents_ht_minor', s.docs::text,
                            'absorbed_minor', s.absorbed::text, 'commission_minor', (l.charged + s.repriced)::text)
  from public.remittance_run r
  cross join lateral (select coalesce(sum(x.amount_minor), 0) as gross, count(*) as n,
                             coalesce(sum(x.commission_minor) filter (where x.commission_state = 'charged'), 0)
                               as charged
                      from public.remittance_line x where x.run_id = r.id) l
  cross join lateral (
    select (select coalesce(sum(i.ht_minor), 0) from public.commission_invoice i
            where i.run_id = r.id and i.reason = 'commission') as docs,
           (select coalesce(sum(x.commission_minor), 0) from public.remittance_line_repricing x
            where x.pricing_run_id = r.id and x.commission_state = 'charged') as repriced,
           (select t.amount_minor from public.bank_transfer t where t.id = r.transfer_id) as payout,
           -- what the run's credits absorbed of manual credit notes' waivers (M2c-5b: lines with no document)
           (select coalesce(sum(w.amount_minor), 0) from public.commission_waiver w
            where w.run_id = r.id and w.cause = 'absorbed') as absorbed) s
  where r.organization_id = p_organization_id and r.status in ('approved', 'sent', 'booked', 'cancelled')
    and r.approved_at is not null and (v_full or r.updated_at > v_since - interval '1 day')
    and (l.gross <> r.gross_minor or l.n <> r.line_count or r.net_minor < 0
         or r.net_minor + r.settlement_minor <> r.gross_minor or s.docs + s.absorbed <> l.charged + s.repriced
         or (r.status <> 'cancelled' and r.net_minor > 0 and s.payout is distinct from r.net_minor)
         or (r.net_minor = 0 and r.transfer_id is not null))
  union all
  -- I22 (M2c-5b): each (file, tier key) whose state changed since the previous check run (with a day's margin): what
  -- its invoices still charge plus the waivers they hold is the commission charged, the waivers its state's, none below
  -- 0 (the engine's input: the prepare refuses a key that breaks it; keyed per key)
  select 'commission_key_state', 'violation', 'account', c.account_id, 'EUR',
         (o.open_minor + o.waived_minor - s.commission_minor)::bigint, null, null,
         jsonb_build_object('tier_key', c.tier_key, 'commission_minor', s.commission_minor::text,
                            'open_minor', o.open_minor::text, 'waived_minor', o.waived_minor::text,
                            'state_waived_minor', s.waived_minor::text)
  from (select distinct k.account_id, k.tier_key from public.remittance_key_state k
        where k.organization_id = p_organization_id
          and k.created_at > coalesce(v_since, '-infinity'::timestamptz) - interval '1 day') c
  cross join lateral (select k.commission_minor, k.waived_minor from public.remittance_key_state k
                      where k.account_id = c.account_id and k.tier_key = c.tier_key
                      order by k.seq desc limit 1) s
  cross join lateral private.commission_key_open(c.account_id, c.tier_key) o
  where o.open_minor + o.waived_minor <> s.commission_minor or o.waived_minor <> s.waived_minor or o.negative
  union all
  -- I17 numbering: per series and year, 1…n with no gap, the counter at n, dates never going back
  select 'invoice_numbering', 'violation', 'servicer', null, null, null, x.n::integer, null,
         jsonb_build_object('series', x.series, 'year', x.year, 'max_seq', x.mx, 'counter', c.last_seq,
                            'dates_back', x.back)
  from (select i.series, i.year, count(*) as n, max(i.seq) as mx, min(i.seq) as mn,
               bool_or(i.issue_date < i.prev_date) as back
        from (select y.*, lag(y.issue_date) over (partition by y.series, y.year order by y.seq) as prev_date
              from public.commission_invoice y where y.organization_id = p_organization_id) i
        group by i.series, i.year) x
  left join private.invoice_counter c on c.organization_id = p_organization_id and c.series = x.series
    and c.year = x.year
  where x.n <> x.mx or x.mn <> 1 or c.last_seq is distinct from x.mx or x.back
  union all
  -- I17 ledger: each document's entry is the document (4111 = TTC, 7060 = −HT)
  select 'invoice_ledger', 'violation', 'commission_invoice', i.id, i.currency, i.ttc_minor, null, null,
         jsonb_build_object('number', i.number, 'receivable_minor', e.receivable::text, 'revenue_minor', e.revenue::text)
  from public.commission_invoice i
  cross join lateral (
    -- the entry's postings by key first, then each one's account by key (plan robustness, ARCHITECTURE §4)
    select coalesce(sum(p.amount_minor) filter (where la.book = 'commission_receivable'), 0) as receivable,
           coalesce(sum(p.amount_minor) filter (where la.book = 'servicer_revenue'), 0) as revenue
    from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
          where q.entry_id = i.ledger_entry_id offset 0) p
    cross join lateral (select a.book from public.ledger_account a where a.id = p.ledger_account_id offset 0) la) e
  where i.organization_id = p_organization_id and (e.receivable <> i.ttc_minor or e.revenue <> -i.ht_minor)
  union all
  -- I18: per client, Σ open invoices − Σ refunds owed = 4111[c]; 44574 = Σ pending VAT of the documents (the client's
  -- and the servicer's pooled accounts by their indexes: 4111 has no portfolio, 44574 no claim item; review perf#2)
  select 'settlement_ledger', 'violation', 'client', y.client_organization_id, 'EUR', (y.ledger - y.docs)::bigint, null,
         null, jsonb_build_object('documents_minor', y.docs::text, 'ledger_minor', y.ledger::text)
  from (select c.client_organization_id,
               coalesce((select sum(private.document_open(i.id) * case i.kind when 'invoice' then 1 else -1 end)
                         from public.commission_invoice i where i.client_organization_id = c.client_organization_id),
                        0) as docs,
               coalesce((select sum(p.amount_minor) from public.ledger_account la
                         join public.ledger_posting p on p.ledger_account_id = la.id
                         where la.book = 'commission_receivable' and la.client_organization_id = c.client_organization_id
                           and la.portfolio_id is null),
                        0) as ledger
        from (select distinct i.client_organization_id from public.commission_invoice i
              where i.organization_id = p_organization_id) c) y
  where y.docs <> y.ledger
  union all
  select 'vat_pending_ledger', 'violation', 'servicer', null, 'EUR', (v.ledger - v.docs)::bigint, null, null,
         jsonb_build_object('documents_minor', v.docs::text, 'ledger_minor', v.ledger::text)
  from (select coalesce((select sum(private.document_pending_vat(i.id)) from public.commission_invoice i
                         where i.organization_id = p_organization_id and i.kind = 'invoice'), 0) as docs,
               coalesce((select -sum(p.amount_minor) from public.ledger_account la
                         join public.ledger_posting p on p.ledger_account_id = la.id
                         where la.organization_id = p_organization_id and la.book = 'vat_pending'
                           and la.claim_item_id is null), 0) as ledger) v
  where v.docs <> v.ledger
  union all
  -- I21: collections waiting past the date they are held to (violation, per client)
  select 'remittance_deadline_breached', 'violation', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, max(v_today - d.check_latest_execution_date),
         jsonb_build_object('earliest_latest_execution_date', min(d.check_latest_execution_date),
                            'unmeetable', count(*) filter (where d.unmeetable),
                            'ids', (array_agg(d.ledger_entry_id order by d.check_latest_execution_date))[1:50])
  from dl d where not d.out_of_horizon and d.check_latest_execution_date < v_today
  group by d.client_organization_id, d.currency
  union all
  -- … whose mandate's delay could not be met (OQ-71: « délai intenable », an alert) while the month still runs
  select 'remittance_delay_unmeetable', 'alert', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, max(v_today - d.latest_execution_date),
         jsonb_build_object('earliest_latest_execution_date', min(d.latest_execution_date),
                            'one_month_latest_execution_date', min(d.check_latest_execution_date),
                            'ids', (array_agg(d.ledger_entry_id order by d.latest_execution_date))[1:50])
  from dl d
  where d.unmeetable and not d.out_of_horizon and d.latest_execution_date < v_today
    and d.check_latest_execution_date >= v_today
  group by d.client_organization_id, d.currency
  union all
  -- due soon (D-5 business days) and critical (D-1): per client, the earliest date (one month's for an unmeetable
  -- delay)
  select case when min(d.check_alert_critical_date) <= v_today then 'remittance_due_critical'
              else 'remittance_due_soon' end,
         'alert', 'client', d.client_organization_id, d.currency, sum(d.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('earliest_latest_execution_date', min(d.check_latest_execution_date))
  from dl d
  where not d.out_of_horizon and d.check_latest_execution_date >= v_today and d.check_alert_soon_date <= v_today
  group by d.client_organization_id, d.currency
  union all
  -- collections the business calendar cannot place (E before its horizon: long past any deadline; review nc#0)
  select 'remittance_deadline_not_computable', 'alert', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('of', 'items', 'earliest_encaissement_date', min(d.encaissement_date),
                            'ids', (array_agg(d.ledger_entry_id order by d.encaissement_date))[1:50])
  from dl d where d.out_of_horizon
  group by d.client_organization_id, d.currency
  union all
  select 'remittance_deadline_not_computable', 'alert', 'remittance_run', o.run_id, o.currency,
         sum(o.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('of', 'lines', 'number', min(o.number),
                            'ids', (array_agg(o.ledger_entry_id order by o.ledger_entry_id))[1:50])
  from ol o where o.out_of_horizon
  group by o.run_id, o.currency
  union all
  select 'remittance_deadline_not_computable', 'alert', 'servicer', null, u.currency, sum(u.unallocated_minor)::bigint,
         count(*)::integer, null,
         jsonb_build_object('of', 'payments', 'earliest_encaissement_date', min(u.encaissement_date),
                            'ids', (array_agg(u.payment_id order by u.encaissement_date))[1:50])
  from ua u where u.out_of_horizon
  group by u.currency
  union all
  -- a run approved or sent whose payout is not debited by its lines' date (violation; review legal#3) …
  select 'remittance_payout_overdue', 'violation', 'remittance_run', o.run_id, o.currency, sum(o.amount_minor)::bigint,
         count(*)::integer, max(v_today - o.latest_execution_date),
         jsonb_build_object('number', min(o.number), 'earliest_latest_execution_date', min(o.latest_execution_date),
                            'requested_execution_date', min(o.requested_execution_date),
                            'ids', (array_agg(o.ledger_entry_id order by o.latest_execution_date))[1:50])
  from ol o where not o.out_of_horizon
  group by o.run_id, o.currency
  union all
  -- … or by the date it was ordered for (alert)
  select 'remittance_payout_not_executed', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null,
         v_today - r.requested_execution_date,
         jsonb_build_object('number', r.number, 'requested_execution_date', r.requested_execution_date,
                            'transfer_status', (select t.status from public.bank_transfer t where t.id = r.transfer_id))
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status in ('approved', 'sent')
    and r.requested_execution_date < v_today
    and not exists (select 1 from public.bank_transfer t where t.id = r.transfer_id and t.status = 'booked')
  union all
  -- a draft whose payout is blocked, with its reason and its deadline
  select 'payout_blocked', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null, null,
         jsonb_build_object('number', r.number, 'blockers', to_jsonb(r.blockers),
                            'earliest_latest_execution_date', r.earliest_latest_execution_date)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status = 'draft' and r.net_minor > 0
    and cardinality(r.blockers) > 0
  union all
  -- a draft waiting more than one business day; one whose preparation failed at once (nothing retries it before
  -- « Actualiser »; review tests-ui#3)
  select 'draft_waiting', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null,
         private.business_days_between((coalesce(r.prepared_at, (r.last_failure ->> 'at')::timestamptz, r.known_at)
                                        at time zone 'Europe/Paris')::date, v_today),
         jsonb_build_object('number', r.number)
         || case when r.prepared_at is null
                 then jsonb_build_object('prepare_failed', true, 'failure_code', r.last_failure ->> 'code')
                 else '{}'::jsonb end
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status = 'draft'
    and ((r.prepared_at is not null
          and private.business_days_between((r.prepared_at at time zone 'Europe/Paris')::date, v_today) > 1)
         or (r.prepared_at is null and r.job is null and r.last_failure ->> 'step' = 'prepare'))
  union all
  -- an approval more than 2 business days after K (invoice_late)
  select 'invoice_late', 'alert', 'remittance_run', r.id, r.currency, r.invoice_ttc_minor, null, null,
         jsonb_build_object('number', r.number, 'known_at', r.known_at, 'approved_at', r.approved_at)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.invoice_late and r.approved_at > clock_timestamp() - interval '30 days'
  union all
  -- an invoice still open after the date it is paid by (§15 invoice_overdue; L441-10 II: penalties run from the next
  -- day): a due invoice, a cancellation's corrective invoice the next run did not set off in time (legal review #4,
  -- round 2; OQ-72), or a run's netted invoice whose plan left a remainder for the next run by its date (M2c-5 review
  -- legal#4; what its own run sets off is held to that run's payout by the payout checks above)
  select 'invoice_overdue', 'alert', 'commission_invoice', i.id, i.currency, o.open, null, v_today - i.due_date,
         jsonb_build_object('number', i.number, 'client_id', i.client_organization_id, 'settlement', i.settlement,
                            'due_date', i.due_date)
  from public.commission_invoice i
  cross join lateral (select private.document_open(i.id) as open) o
  where i.organization_id = p_organization_id and i.due_date is not null and i.due_date < v_today and o.open > 0
  union all
  -- money matched to a client's file but not allocated (still in 4710) gets the same clock (OQ-26, compliance B7)
  select 'unallocated_deadline', 'alert', 'servicer', null, u.currency, sum(u.unallocated_minor)::bigint,
         count(*)::integer, null,
         jsonb_build_object('earliest_latest_execution_date', min(u.latest_execution_date),
                            'held', count(*) filter (where u.held),
                            'ids', (array_agg(u.payment_id order by u.latest_execution_date))[1:50])
  from ua u where not u.out_of_horizon and u.alert_soon_date <= v_today
  group by u.currency
  union all
  -- the hourly schedule could not create a client's draft, or read its candidates, or its job died (review nc#0)
  select 'remittance_schedule_failed', 'alert', 'servicer', null, null, null, count(*)::integer, null,
         jsonb_build_object('last_failed_at', max(f.failed_at),
                            'last_error', (array_agg(f.error order by f.failed_at desc))[1],
                            'codes', to_jsonb(array_agg(distinct f.code)),
                            'client_ids', to_jsonb(coalesce(array_agg(distinct f.client_organization_id)
                                                              filter (where f.client_organization_id is not null),
                                                            '{}')))
  from private.remittance_schedule_failure f
  where f.organization_id = p_organization_id and f.failed_at >= v_failures
  having count(*) > 0
  union all
  -- documents the job could not draw (M2c-5 review perf#2): each failure is recorded on its row and retried; until it
  -- is drawn, the alert names it with its last error
  select 'remittance_document_failed', 'alert', 'servicer', null, null, null, count(*)::integer,
         max(v_today - (t.created_at at time zone 'Europe/Paris')::date),
         jsonb_build_object('statements', count(*) filter (where t.kind = 'statement'),
                            'invoices', count(*) filter (where t.kind = 'invoice'),
                            'last_failed_at', max(t.last_attempt_at),
                            'last_error', (array_agg(t.last_error order by t.last_attempt_at desc, t.ref_id))[1],
                            'ids', to_jsonb((array_agg(t.ref_id order by t.created_at, t.ref_id))[1:50]))
  from private.remittance_document_todo t
  where t.organization_id = p_organization_id and t.attempts > 0
  having count(*) > 0
  union all
  -- … and the documents still due 24 hours after they were (§15 document_missing): a statement or a PDF the client
  -- space says « en préparation »
  select 'remittance_document_missing', 'alert', 'servicer', null, null, null, count(*)::integer,
         max(v_today - (m.due_since at time zone 'Europe/Paris')::date),
         jsonb_build_object('statements', count(*) filter (where m.kind = 'statement'),
                            'invoices', count(*) filter (where m.kind = 'invoice'),
                            'oldest_due_since', min(m.due_since),
                            'numbers', to_jsonb((array_agg(m.number order by m.due_since, m.ref_id))[1:50]))
  from private.remittance_documents_missing(p_organization_id, interval '24 hours') m
  having count(*) > 0
  union all
  -- reference data (M2c-3): the VAT pack's review, the calendar's horizon
  select a.code, 'alert', 'servicer', null, null, null, null, null, a.details
  from private.reference_data_alerts(v_today) a
  ) u (code, severity, subject_type, subject_id, currency, amount_minor, count, oldest_days, details);
end;
$$;


-- Redefined from 20261113090000 (M2c-5b): the statement's totals name what the run's credits absorbed of manual
-- credit notes' waivers, so its commission (the lines') and its documents' agree in words (CSV = PDF = run).
create or replace function private.remittance_statement_build(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare
  r public.remittance_run;
  v_cancelled boolean;
  v_exp integer;
  v_lines jsonb;
  v_files jsonb;
  v_natures jsonb;
  v_totals jsonb;
  v_docs jsonb;
  v_earlier jsonb;
  v_mandates jsonb;
  v_payout jsonb;
  v_follow jsonb;
  v_held jsonb;
  v_refunded jsonb;
  v_position jsonb;
  v_prev public.remittance_run;
  v_k_day date;
  v_issue date;
  v_payload jsonb;
  v_receivable bigint;
  v_advances bigint;
  v_docs_ttc bigint;
  v_issuer jsonb;
  v_client jsonb;
begin
  select * into r from public.remittance_run where id = p_run_id for share;
  if not found or r.approved_at is null then
    raise exception 'statement of %: not an approved run', p_run_id using errcode = 'check_violation';
  end if;
  v_cancelled := r.status = 'cancelled';
  select c.minor_exponent into v_exp from public.currency c where c.code = r.currency;
  v_k_day := (r.known_at at time zone 'Europe/Paris')::date;
  v_issue := (r.approved_at at time zone 'Europe/Paris')::date;

  -- the run's lines, then the earlier lines whose commission this run priced (amount 0: remitted then)
  drop table if exists pg_temp._rd_line;
  create temp table _rd_line on commit drop as
  select 0 as section, l.line_no, l.line_no as source_line_no, null::text as from_run, l.kind, l.ledger_entry_id,
         l.account_id, l.portfolio_id, l.mandate_id, l.payment_id, l.encaissement_date, l.effective_date, l.deadline,
         l.amount_minor, l.commission_minor, l.commission_state, l.parts, l.invoice_id, l.posted_at,
         l.latest_execution_date, l.unmeetable
  from public.remittance_line l where l.run_id = r.id
  union all
  select 1, 0, l.line_no, (select x.number from public.remittance_run x where x.id = l.run_id), l.kind,
         l.ledger_entry_id, l.account_id, l.portfolio_id, l.mandate_id, l.payment_id, l.encaissement_date,
         l.effective_date, l.deadline, 0, rp.commission_minor, rp.commission_state, rp.parts, rp.invoice_id,
         l.posted_at, l.latest_execution_date, l.unmeetable
  from public.remittance_line_repricing rp
  cross join lateral (select y.* from public.remittance_line y where y.run_id = rp.run_id and y.line_no = rp.line_no
                      offset 0) l
  where rp.pricing_run_id = r.id;

  drop table if exists pg_temp._rd_fact;
  create temp table _rd_fact on commit drop as
  select x.section, x.line_no, x.source_line_no, x.from_run, x.kind, x.account_id, x.amount_minor, x.commission_minor,
         a.external_ref as file, d.name as debtor, m.reference as mandate, pf.name as portfolio,
         coalesce(it.items, '[]'::jsonb) as items, coalesce(it.components, '[]'::jsonb) as components,
         n.reason as nature_reason, x.encaissement_date, x.effective_date, x.deadline, x.commission_state,
         coalesce(pt.rules, '[]'::jsonb) as rules, coalesce(pt.rates, '[]'::jsonb) as rates,
         coalesce(pt.basis, 0) as basis, coalesce(inv.number, cn.number) as invoice, rc.number as receipt,
         la.ledger_entry_id is not null as late, lc.cause as late_cause
  from pg_temp._rd_line x
  left join lateral (select q.external_ref from public.account q where q.id = x.account_id offset 0) a on true
  left join lateral (
    select (array_agg(pa.display_name order by pa.display_name, pa.id))[1] as name
    from public.account_party ap
    cross join lateral (select q.id, q.display_name from public.party q where q.id = ap.party_id offset 0) pa
    where ap.account_id = x.account_id and ap.role = 'borrower') d on true
  left join lateral (select q.reference from public.mandate q where q.id = x.mandate_id offset 0) m on true
  left join lateral (select q.name from public.portfolio q where q.id = x.portfolio_id offset 0) pf on true
  -- the items and components the entry moved (its 1100 postings), each item once, in a total order
  left join lateral (
    with y as (
      select q.claim_item_id, q.component
      from public.ledger_posting lp
      cross join lateral (select v.claim_item_id, v.component from public.ledger_account v
                          where v.id = lp.ledger_account_id and v.book = 'debtor_receivable' offset 0) q
      where lp.entry_id = x.ledger_entry_id)
    select (select jsonb_agg(jsonb_build_array(z.kind, z.ref) order by z.due_date nulls last, z.ref, z.kind, z.id)
            from (select distinct ci.id, ci.kind, ci.ref, ci.due_date
                  from y cross join lateral (select c.id, c.kind, c.ref, c.due_date from public.claim_item c
                                             where c.id = y.claim_item_id offset 0) ci) z) as items,
           (select jsonb_agg(z.component order by z.sort_order)
            from (select distinct y.component, lc.sort_order
                  from y cross join lateral (select c.sort_order from public.ledger_component c
                                             where c.code = y.component offset 0) lc) z) as components) it on true
  left join lateral (select q.reason from public.client_notification q where q.ledger_entry_id = x.ledger_entry_id
                     offset 0) n on true
  -- the rules and band rates of the line's parts, and the basis they priced
  left join lateral (
    select (select jsonb_agg(distinct p ->> 'label_fr') from jsonb_array_elements(x.parts) p
            where p ->> 'label_fr' is not null) as rules,
           (select jsonb_agg(distinct t ->> 0) from jsonb_array_elements(x.parts) p
            cross join lateral jsonb_array_elements(coalesce(p -> 'tiers', '[]')) t) as rates,
           (select sum((p ->> 'basis')::bigint) from jsonb_array_elements(x.parts) p) as basis) pt on true
  left join lateral (select q.number from public.commission_invoice q where q.id = x.invoice_id offset 0) inv on true
  -- a reversal's negative commission is on the run's credit note, which names its entry (review figures#5)
  left join lateral (select q.number
                     from public.commission_credit_alloc ca
                     cross join lateral (select y.number, y.seq from public.commission_invoice y
                                         where y.id = ca.credit_note_id and y.run_id = r.id
                                           and y.kind = 'credit_note' and y.reason = 'commission' offset 0) q
                     where x.invoice_id is null and ca.entry_id = x.ledger_entry_id
                     order by q.seq limit 1) cn on true
  left join lateral (select q.number from public.receipt q where q.payment_id = x.payment_id
                     order by q.version limit 1) rc on true
  left join lateral (select q.ledger_entry_id from public.remittance_late_approval q
                     where q.run_id = r.id and q.ledger_entry_id = x.ledger_entry_id and x.section = 0
                     offset 0) la on true
  -- why a line was paid after its latest execution date, from the data (review legal#6; the approver's reason stays
  -- in the back office): the mandate's delay could not be met (held to one month, R124-6), the collection reached the
  -- queue after its J-5 date (the deadline guard's margin, 5 business days before its latest execution date), or the
  -- approval came late
  left join lateral (select case when x.unmeetable then 'unmeetable'
                                 when private.business_days_between((x.posted_at at time zone 'Europe/Paris')::date,
                                                                    x.latest_execution_date) < 5
                                 then 'identified_late'
                                 else 'approved_late' end as cause
                     where la.ledger_entry_id is not null offset 0) lc on true;

  select coalesce(jsonb_agg(jsonb_build_array(
           f.source_line_no, f.mandate, f.portfolio, f.file, f.debtor, f.items, f.components, f.kind, f.nature_reason,
           f.from_run, f.encaissement_date, f.effective_date, f.deadline, f.amount_minor::text, f.rules, f.rates,
           f.basis::text, f.commission_minor::text, f.commission_state, f.invoice, f.receipt, f.late, f.late_cause)
           order by f.section, f.from_run, f.source_line_no), '[]')
  into v_lines from pg_temp._rd_fact f;

  -- per file (the PDF's table): the run's lines and the commission priced on the file in this run (a file with only
  -- earlier lines priced now has 0 lines: counted apart in the totals, review tests-ui#4)
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', g.file, 'debtor', g.debtor, 'lines', g.n::text, 'amount_minor', g.amount::text,
           'commission_minor', g.commission::text, 'late', g.late::text)
           order by g.file nulls last, g.account_id), '[]')
  into v_files
  from (select f.account_id, min(f.file) as file, min(f.debtor) as debtor,
               count(*) filter (where f.section = 0) as n, sum(f.amount_minor) as amount,
               sum(f.commission_minor) as commission, count(*) filter (where f.late) as late
        from pg_temp._rd_fact f group by f.account_id) g;

  -- per nature (the run's lines by kind and reason; the earlier lines priced now as one row)
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', n.kind, 'reason', n.reason, 'count', n.c::text, 'amount_minor', n.amount::text,
           'commission_minor', n.commission::text) order by n.section, n.kind, n.reason nulls first), '[]')
  into v_natures
  from (select f.section, case when f.section = 1 then 'repricing' else f.kind end as kind,
               case when f.section = 0 and f.kind in ('forward', 'allocation_reversal', 'forward_reversal')
                    then f.nature_reason end as reason,
               count(*) as c, sum(f.amount_minor) as amount, sum(f.commission_minor) as commission
        from pg_temp._rd_fact f group by 1, 2, 3) n;

  select jsonb_build_object(
           'line_count', count(*) filter (where f.section = 0),
           'repriced_count', count(*) filter (where f.section = 1),
           'file_count', count(distinct f.account_id) filter (where f.section = 0),
           'repriced_only_file_count',
             (select count(*) from (select g.account_id from pg_temp._rd_fact g group by g.account_id
                                    having bool_and(g.section = 1)) o),
           'collected_minor', coalesce(sum(f.amount_minor) filter (where f.amount_minor > 0), 0)::text,
           'reversed_minor', coalesce(sum(f.amount_minor) filter (where f.amount_minor < 0), 0)::text,
           'commission_ht_minor', coalesce(sum(f.commission_minor), 0)::text,
           'late_count', count(*) filter (where f.late))
         || jsonb_build_object(
           'gross_minor', r.gross_minor::text,
           'invoice_ht_minor', coalesce(r.invoice_ht_minor, 0)::text,
           'invoice_vat_minor', coalesce(r.invoice_vat_minor, 0)::text,
           'invoice_ttc_minor', coalesce(r.invoice_ttc_minor, 0)::text,
           'credit_ht_minor', coalesce(r.credit_ht_minor, 0)::text,
           'credit_vat_minor', coalesce(r.credit_vat_minor, 0)::text,
           'credit_ttc_minor', coalesce(r.credit_ttc_minor, 0)::text,
           'commission_taken_minor', coalesce(r.commission_taken_minor, 0)::text,
           'advance_recovered_minor', coalesce(r.advance_recovered_minor, 0)::text,
           'refund_minor', coalesce(r.refund_minor, 0)::text,
           'settlement_minor', r.settlement_minor::text,
           'net_minor', r.net_minor::text)
         -- M2c-5b: what the run's credits absorbed of manual credit notes' waivers (lines with no document: the
         -- client had it back already), named with the invoices it was on; absent when nothing was (payloads drawn
         -- before keep their bytes)
         || coalesce((select jsonb_build_object('waived_absorbed_minor', (-sum(w.amount_minor))::text,
                                                'waived_absorbed_invoices',
                                                jsonb_agg(distinct i.number order by i.number))
                      from public.commission_waiver w
                      cross join lateral (select q.number from public.commission_invoice q
                                          where q.id = w.invoice_id offset 0) i
                      where w.run_id = r.id and w.cause = 'absorbed'
                      having count(*) > 0), '{}'::jsonb)
  into v_totals from pg_temp._rd_fact f;

  -- the run's documents (its approval's; a cancellation's too when the run was cancelled before this was drawn), each
  -- with the invoices it corrects, the credit notes of the cancellation that annul it, and what this payout sets off
  -- (nothing once cancelled)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'kind', i.kind, 'number', i.number, 'issue_date', i.issue_date, 'reason', i.reason,
           'mandate', (select m.reference from public.mandate m where m.id = i.mandate_id),
           'ht_minor', i.ht_minor::text, 'vat_minor', i.vat_minor::text, 'ttc_minor', i.ttc_minor::text,
           'vat_rate', i.vat_rate::text, 'settlement', i.settlement, 'due_date', i.due_date,
           'clause_ref', i.payload #>> '{settlement,clause_ref}',
           'payment_reference', i.payload -> 'payment_reference',
           'own_account', case when i.payload -> 'own_account' is not null
                               and jsonb_typeof(i.payload -> 'own_account') = 'object'
                               then jsonb_build_object('iban', private.iban_masked(i.payload #>> '{own_account,iban}'),
                                                       'holder', i.payload #>> '{own_account,holder}') end,
           'corrects', (select coalesce(jsonb_agg(jsonb_build_object('number', o.number, 'issue_date', o.issue_date,
                                                                     'ht_minor', c.ht_minor::text,
                                                                     'vat_minor', c.vat_minor::text)
                                                  order by o.seq), '[]')
                        from public.commission_credit_correction c
                        cross join lateral (select q.number, q.issue_date, q.seq from public.commission_invoice q
                                            where q.id = c.original_invoice_id offset 0) o
                        where c.credit_note_id = i.id),
           'cancelled_by', (select coalesce(jsonb_agg(jsonb_build_object('number', o.number,
                                                                         'issue_date', o.issue_date)
                                                      order by o.seq), '[]')
                            from public.commission_credit_correction c
                            cross join lateral (select q.number, q.issue_date, q.seq from public.commission_invoice q
                                                where q.id = c.credit_note_id and q.run_id = r.id
                                                  and q.reason = 'run_cancelled' offset 0) o
                            where c.original_invoice_id = i.id),
           'settles_minor', case when v_cancelled then '0'
                                 else (select coalesce(sum((s ->> 'amount')::bigint), 0)::text
                                       from jsonb_array_elements(coalesce(r.settlement_plan -> 'settles', '[]')) s
                                       where s ->> 'document_id' = i.id::text) end)
           order by i.seq), '[]')
  into v_docs
  from public.commission_invoice i where i.run_id = r.id;

  -- what this payout sets off from documents of earlier runs (compensation, a refund owed, an advance); nothing once
  -- the run is cancelled
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', s ->> 'kind', 'document_kind', i.kind, 'number', i.number, 'issue_date', i.issue_date,
           'amount_minor', s ->> 'amount') order by i.seq nulls last, s ->> 'document_id'), '[]')
  into v_earlier
  from jsonb_array_elements(case when v_cancelled then '[]'::jsonb
                                 else coalesce(r.settlement_plan -> 'settles', '[]') end) s
  left join lateral (select q.kind, q.number, q.issue_date, q.seq, q.run_id from public.commission_invoice q
                     where q.id = (s ->> 'document_id')::uuid offset 0) i on true
  where i.run_id is distinct from r.id and (s ->> 'amount')::bigint <> 0;

  -- the mandates the statement covers, with the clause references of their terms on K's day (R124-3 3°, 4°)
  select coalesce(jsonb_agg(jsonb_build_object(
           'reference', m.reference, 'signed_on', m.signed_on,
           'commission_clause_ref', t.commission_clause_ref, 'remittance_clause_ref', t.remittance_clause_ref,
           'netting_clause_ref', t.remittance_terms #>> '{netting,clause_ref}',
           'clawback_clause_ref', t.remittance_terms #>> '{clawback,clause_ref}')
           order by m.reference, m.id), '[]')
  into v_mandates
  from (select distinct x.mandate_id from pg_temp._rd_line x where x.mandate_id is not null
        union select i.mandate_id from public.commission_invoice i where i.run_id = r.id) mm
  cross join lateral (select q.* from public.mandate q where q.id = mm.mandate_id offset 0) m
  left join lateral (select q.commission_clause_ref, q.remittance_clause_ref, q.remittance_terms
                     from public.mandate_terms q
                     where q.mandate_id = m.id and q.valid_from <= v_k_day
                     order by q.valid_from desc limit 1) t on true;

  -- the payout as ordered (never « payé » before the bank's debit: M2c-6 books it)
  select jsonb_build_object('amount_minor', t.amount_minor::text, 'ordered_on', v_issue,
                            'requested_execution_date', t.requested_execution_date,
                            'iban', private.iban_masked(t.payee_iban), 'holder', t.payee_name,
                            'end_to_end_id', t.end_to_end_id, 'status', t.status)
  into v_payout from public.bank_transfer t where t.id = r.transfer_id;

  -- the previous run's payout: what became of it (« Suivi »)
  select * into v_prev from public.remittance_run x where x.id = r.previous_run_id;
  if v_prev.id is not null then
    select jsonb_agg(jsonb_build_object(
             'number', v_prev.number, 'status', v_prev.status, 'net_minor', v_prev.net_minor::text,
             'transfer_status', t.status, 'requested_execution_date', t.requested_execution_date,
             'amount_minor', t.amount_minor::text,
             'debited_on', (select e.effective_date from public.ledger_entry e where e.id = t.entry_id),
             'returned_on', (select e.effective_date from public.ledger_entry e where e.id = t.return_entry_id),
             'booked_on', v_prev.booked_on))
    into v_follow
    from (select 1) one left join public.bank_transfer t on t.id = v_prev.transfer_id;
  end if;

  -- money received on the client's files and not remitted, as of K (C. civ. 1993, OQ-40; review figures#2): per file
  -- and reason, what each payment matched to one of them by K still held on 4710 at K — its amount less what its
  -- other entries posted by K moved (allocations, forwards, refunds, returns, and their reversals: a refund that came
  -- back by K is held again, review legal#3). The payments that can have held money at K: those holding some now,
  -- those refunded or returned since K, and those allocated or forwarded since K (their entries are the client's
  -- pending items posted after K). No payer data.
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', h.file, 'reason', h.reason, 'currency', h.currency, 'amount_minor', h.amount::text,
           'first_date', h.first_date, 'last_date', h.last_date, 'count', h.n::text)
           order by h.file, h.reason, h.currency), '[]')
  into v_held
  from (select a.external_ref as file,
               coalesce(p.review_reason, case when p.status in ('refund_pending', 'refunded') then 'refund_pending'
                                              else 'pending' end) as reason,
               p.currency, sum(u.unallocated) as amount, min(p.booking_date) as first_date,
               max(p.booking_date) as last_date, count(*) as n
        from (select distinct c.id
              from (select y.id from public.payment y
                    where y.organization_id = r.organization_id
                      and y.status in ('matched', 'partially_allocated', 'refund_pending')
                      and y.client_organization_id = r.client_organization_id
                    union all
                    select y.id from public.payment y
                    where y.organization_id = r.organization_id and y.status in ('refunded', 'returned')
                      and y.client_organization_id = r.client_organization_id and y.updated_at > r.known_at
                    union all
                    select e.payment_id from private.remittance_pending q
                    cross join lateral (select y.payment_id from public.ledger_entry y where y.id = q.ledger_entry_id
                                        offset 0) e
                    where q.organization_id = r.organization_id
                      and q.client_organization_id = r.client_organization_id
                      and q.posted_at > r.known_at and e.payment_id is not null) c) c
        cross join lateral (select y.* from public.payment y where y.id = c.id offset 0) p
        cross join lateral (
          select (p.amount_minor - coalesce(sum(lp.amount_minor), 0))::bigint as unallocated
          from (select e.id from public.ledger_entry e
                where e.payment_id = p.id and e.entry_type <> 'cash_in' and e.posted_at <= r.known_at offset 0) e
          cross join lateral (select y.amount_minor from public.ledger_posting y
                              where y.entry_id = e.id
                                and (select la.book from public.ledger_account la where la.id = y.ledger_account_id)
                                    = 'unallocated_payment'
                              offset 0) lp) u
        cross join lateral (select q.external_ref from public.account q where q.id = p.account_id offset 0) a
        where p.client_organization_id = r.client_organization_id and p.created_at <= r.known_at
          and p.matched_at <= r.known_at and u.unallocated > 0
        group by 1, 2, 3) h;

  -- refunded to payers between the previous K and this K, and not back by K (a refund that bounced by K is money held
  -- again, above: review legal#3, figures#3)
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', h.file, 'reason', h.reason, 'currency', h.currency, 'amount_minor', h.amount::text,
           'first_date', h.first_date, 'last_date', h.last_date, 'count', h.n::text)
           order by h.file, h.reason, h.currency), '[]')
  into v_refunded
  from (select a.external_ref as file, q.reason_code as reason, q.currency, sum(q.amount_minor) as amount,
               min(q.executed_on) as first_date, max(q.executed_on) as last_date, count(*) as n
        from public.refund_request q
        cross join lateral (select y.account_id, y.client_organization_id from public.payment y
                            where y.id = q.payment_id offset 0) p
        cross join lateral (select y.external_ref from public.account y where y.id = p.account_id offset 0) a
        cross join lateral (select y.posted_at from public.ledger_entry y where y.id = q.cash_out_entry_id offset 0) e
        left join lateral (select y.posted_at from public.ledger_entry y where y.id = q.bounce_entry_id offset 0) b
          on true
        where q.organization_id = r.organization_id and q.status in ('executed', 'bounced')
          and p.client_organization_id = r.client_organization_id
          and e.posted_at <= r.known_at and (v_prev.known_at is null or e.posted_at > v_prev.known_at)
          and (q.status = 'executed' or b.posted_at > r.known_at)
        group by a.external_ref, q.reason_code, q.currency) h;

  -- the position (§10.7): owed to the client at K — every item pending then is this run's (one live run per client
  -- and currency, I14) — and after this payout (still owed once the run is cancelled); what the client owes the
  -- servicer (4111 + 4112) as known at K and after this statement's documents and the settlement at the payout's debit
  -- (none once cancelled: every document of the run counts, the approval's and the cancellation's)
  select coalesce(sum(private.ledger_balance(la.id, '9999-12-31'::date, r.known_at)), 0)
  into v_receivable
  from public.ledger_account la
  where la.organization_id = r.organization_id and la.book = 'commission_receivable'
    and la.client_organization_id = r.client_organization_id and la.currency = r.currency;
  select coalesce(sum(private.ledger_balance(la.id, '9999-12-31'::date, r.known_at)), 0)
  into v_advances
  from public.ledger_account la
  where la.organization_id = r.organization_id and la.book = 'client_advance_receivable'
    and la.client_organization_id = r.client_organization_id and la.currency = r.currency;
  select coalesce(sum(i.ttc_minor), 0) into v_docs_ttc
  from public.commission_invoice i where i.run_id = r.id and (v_cancelled or i.reason <> 'run_cancelled');
  v_position := jsonb_build_object(
    'owed_before_minor', r.gross_minor::text,
    'owed_after_minor', case when v_cancelled then r.gross_minor else 0 end::text,
    'receivable_before_minor', v_receivable::text,
    'receivable_after_minor',
      (v_receivable + v_docs_ttc
       - case when v_cancelled then 0 else coalesce((r.settlement_plan ->> 'dc')::bigint, 0) end)::text,
    'advances_before_minor', v_advances::text,
    'advances_after_minor',
      (v_advances - case when v_cancelled then 0 else coalesce((r.settlement_plan ->> 'da')::bigint, 0) end)::text);

  -- the parties as the run's invoices froze them at approval (review figures#2), else as they stand
  select i.payload -> 'seller', i.payload -> 'buyer' into v_issuer, v_client
  from public.commission_invoice i where i.run_id = r.id and i.reason = 'commission'
  order by i.seq limit 1;

  v_payload := jsonb_build_object(
    'schema', 1,
    'number', r.number,
    'issue_date', v_issue,
    'known_at', to_char(r.known_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'currency', r.currency,
    'exponent', v_exp,
    'status', r.status,
    'cancelled_on', case when v_cancelled then (r.cancelled_at at time zone 'Europe/Paris')::date end,
    -- N = 0: the settlement was posted at approval, nothing is transferred (review legal#5)
    'settled_on', case when r.status = 'booked' and r.transfer_id is null then r.booked_on end,
    'issuer', coalesce(v_issuer, private.invoice_party(r.organization_id)),
    'client', coalesce(v_client, private.invoice_party(r.client_organization_id)),
    'mandates', v_mandates,
    'service_period', jsonb_build_object('from', r.service_from, 'to', r.service_to),
    'totals', v_totals,
    'files', v_files,
    'natures', v_natures,
    'line_columns', private.remittance_statement_line_columns(),
    'lines', v_lines,
    'documents', v_docs,
    'earlier_settled', v_earlier,
    'payout', v_payout,
    'requested_execution_date', r.requested_execution_date,
    'follow_up', coalesce(v_follow, '[]'),
    'not_remitted', jsonb_build_object('held', v_held, 'refunded', v_refunded),
    'position', v_position);

  return v_payload;
end;
$$;

------------------------------------------------------------------------------------------
-- Read access and privileges (§6.2): the waivers and the manual credit notes' reasons are money staff's; the credit
-- note itself is a commission_invoice row the client reads as any (its reason category is in its line, never the
-- staff's text). No write policy: the definer functions above and the worker write.
------------------------------------------------------------------------------------------

alter table public.commission_waiver enable row level security;
alter table public.manual_credit_note enable row level security;
revoke all on public.commission_waiver, public.manual_credit_note from public, anon, authenticated;
grant select on public.commission_waiver, public.manual_credit_note to authenticated;
create policy commission_waiver_read on public.commission_waiver for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy manual_credit_note_read on public.manual_credit_note for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[]));

revoke execute on function private.remittance_key_state_insert_guard(), private.commission_waiver_insert_guard(),
  private.manual_credit_reason_fr(text), private.manual_credit_refusal(public.commission_invoice, bigint),
  private.manual_credit_plan(uuid, bigint, uuid), private.euros_to_minor(text), private.commission_key_open(uuid, text),
  private.remittance_key_states(uuid[], text[]),
  private.remittance_approval_refusal(public.remittance_run, private.remittance_draft, date),
  private.approve_remittance_run(uuid, uuid), private.run_remittance_checks(uuid, uuid, date),
  private.remittance_statement_build(uuid)
  from public, anon, authenticated;
-- the worker (service role): the prepare's history, the approval job, the statement; the plan and the key check for
-- its tests
grant execute on function private.remittance_key_states(uuid[], text[]), private.approve_remittance_run(uuid, uuid),
  private.manual_credit_plan(uuid, bigint, uuid), private.commission_key_open(uuid, text),
  private.remittance_statement_build(uuid)
  to service_role;
revoke execute on function public.issue_credit_note(text, uuid, text, text, text, text, uuid),
  public.credit_note_preview(uuid, text, uuid), public.commission_invoice_detail(uuid),
  public.cancel_remittance_run(text, uuid, integer, text) from public, anon;
grant execute on function public.issue_credit_note(text, uuid, text, text, text, text, uuid),
  public.credit_note_preview(uuid, text, uuid), public.commission_invoice_detail(uuid),
  public.cancel_remittance_run(text, uuid, integer, text) to authenticated;
