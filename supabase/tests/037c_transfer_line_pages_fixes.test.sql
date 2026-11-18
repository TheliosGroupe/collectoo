-- M2c-6b-2d, what 6b-2c left (ADR-0014 « M2c-6b-2c review fixes », « Left open after round 3 »; ADR-0014 « M2c-6b-2c
-- carry-overs (in 6b-2d) »): two of its three low items, on 037's fixtures (copied: the servicer aa, its accounts cf/c0,
-- clients a1–a9, the other servicer bb, and 037's base — x1 booked by the job and debited a second time today, x2 in
-- flight) and 037's P helpers (copied):
--   R. refund-link-blocked-by-returned-payout-twin: « Lier »'s refund link on a reference-less debit of a refund's amount
--      treats the other candidates as round 3 treats them for a payment's return — refused payout_candidate only for
--      another payout in flight (i), another refund in a file (ii), or a cancelled payout whose run is still approved or
--      sent; never for a payout only returned, or cancelled with its run ended (iii: COMPLIANCE OQ-86's trade-off).
--      public.debit_link_options lists what the guard lets through. {ii, iii} listed and linked; {ii, i} refused;
--      {ii, a cancelled payout whose run is sent} refused, then linked once that run is cancelled.
--   E. suppression-e0-names-our-other-lot: a debit with a foreign end-to-end id and the TF PmtInfId of another lot of
--      ours on the account (class E0), of an in-flight payout's amount to its payee's IBAN, neither holds that payout's
--      breach row back (private.transfer_debit_suppression) nor is booked as its debit (the check's pre-read refuses
--      names_other_lot whenever rule 3b finds a transfer of ours outside the lot the line names) — rule 3b's candidates
--      themselves unchanged, so the guards of « Lier » keep refusing what they refused; the same line naming that
--      payout's own lot, or a TF PmtInfId of no lot of ours, still holds it back and is still proposed.
-- (The third item, ended-twin-return-sentence-without-payment, is the page's: vitest.)
-- run_payment_checks is asserted free of violations in each scenario and after the groups. Cancellation after download
-- stays off (033 and 034 unchanged): the scenario that needs a payout cancelled after its file was handed out switches
-- it on inside its own rolled-back subtransaction.
begin;
select plan(9);


-- Fixtures (as 034: the servicer aa, its dedicated account cf and own account c0; Martin a1, Lilas a2, Cyprès a3;
-- and Lambert a4, Roux a5, Dupont a6, Durand a7, Petit a8, Moreau a9, all with French payout IBANs) ---------------------
insert into public.organization (id, kind, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo SAS', '732829320'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Autre cabinet SAS', null);
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren)
select ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, 'creditor_client', '00000000-0000-0000-0000-0000000000aa',
       x.name, '552100554'
from (values ('a1', 'Martin SAS'), ('a2', 'Lilas Finance'), ('a3', 'Cyprès SA'), ('a4', 'Lambert SA'),
             ('a5', 'Roux SA'), ('a6', 'Dupont SA'), ('a7', 'Durand SARL'), ('a8', 'Petit SAS'),
             ('a9', 'Moreau SA')) x (c, name);
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@book.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '07', '08', '10', '13']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a8', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a8', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000a2', 'client_admin'),
  ('10000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-0000000000aa', 'ops_manager');
insert into public.portfolio (id, organization_id, client_organization_id, name)
select ('20000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'P' || c
from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c;
-- the restricted viewer of Petit (a portfolio access row: not the whole client)
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-0000000000a8');
insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000cf', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
   'FR3430001007940000000001001', 'TESTFRPPXXX', 'EUR', 'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000c0', '00000000-0000-0000-0000-0000000000aa', 'own',
   'FR7610107001011234567890129', null, 'EUR', 'Compte propre', null, '2026-01-01');
insert into public.servicer_billing_settings (organization_id, own_bank_account_id)
values ('00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000c0');
insert into public.billing_identity (organization_id, legal_form, share_capital_minor, rcs_city, registered_office,
                                     vat_number, is_professional)
select o.id, case when o.kind = 'servicer' then 'SAS' end, case when o.kind = 'servicer' then 1000000 end,
       case when o.kind = 'servicer' then 'Paris' end,
       '{"line1": "1 rue de la Paix", "postcode": "75002", "city": "Paris", "country": "FR"}',
       case when o.kind = 'servicer'
            then 'FR' || lpad(((12 + 3 * (o.siren::bigint % 97)) % 97)::text, 2, '0') || o.siren end, true
from public.organization o
where o.id = '00000000-0000-0000-0000-0000000000aa' or o.servicer_organization_id = '00000000-0000-0000-0000-0000000000aa';
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-000000000' || x.n || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || x.c || '.pdf',
       repeat('a', 64), 'application/pdf'
from (select c, n, case n when '1' then 'mandate_document' else 'payout_rib' end as kind
      from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c
      cross join unnest(array['1', '2']) n) x;
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on,
                            insurance_clause_ref)
select ('70000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'MAND-' || c, 'mandate_amicable', '2026-01-01', 'art. 9'
from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c;
insert into public.mandate_terms (id, mandate_id, valid_from, commission_schedule, commission_clause_ref, remittance_terms,
                                  remittance_clause_ref, document_id)
select ('71000000-0000-0000-0000-0000000000' || c)::uuid, ('70000000-0000-0000-0000-0000000000' || c)::uuid,
       '2026-01-01',
       '{"schema": "commission-1", "basis": {"families": "all", "forwards": {"file_recalled": false,
         "before_servicing_start": false, "client_ratification": false}, "on_reversal": "credit"},
         "rules": [{"id": "tout", "tier_key": "tout", "label_fr": "Toutes créances", "match": {},
                    "rate": {"kind": "flat", "rate": "0.15"}}]}',
       'art. 6', '{"schema": "remittance-1", "frequency": "twice_monthly", "netting": {"clause_ref": "art. 7.2"},
                   "clawback": null, "invoice_payment_days": 30}', 'art. 7',
       ('d0000000-0000-0000-0000-0000000001' || c)::uuid
from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c;
update public.portfolio set mandate_id = ('70000000-0000-0000-0000-0000000000' || right(id::text, 2))::uuid
where organization_id = '00000000-0000-0000-0000-0000000000aa';
insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                          evidence_document_id, proposed_by)
select ('90000000-0000-0000-0000-0000000000' || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, 'EUR', x.iban, x.holder,
       ('d0000000-0000-0000-0000-0000000002' || x.c)::uuid, '10000000-0000-0000-0000-000000000004'
from (values ('a1', 'FR7630004000031234567890143', 'MARTIN SAS'),
             ('a2', 'FR1420041010050500013M02606', 'LILAS FINANCE'),
             ('a3', 'FR7630006000011234567890189', 'CYPRES SA'),
             ('a4', 'FR7688685684899121950048661', 'LAMBERT SA'),
             ('a5', 'FR7674816825839554342314455', 'ROUX SA'),
             ('a6', 'FR7627523466751211650709822', 'DUPONT SA'),
             ('a7', 'FR7640105632892063255029835', 'DURAND SARL'),
             ('a8', 'FR7662603642123444042514350', 'PETIT SAS'),
             ('a9', 'FR7692640312371024797365028', 'MOREAU SA')) x (c, iban, holder);
update public.client_payout_account set status = 'active', confirmed_at = now(), confirmed_via = 'second_admin',
  confirmed_by = '10000000-0000-0000-0000-000000000001'
where organization_id = '00000000-0000-0000-0000-0000000000aa';

create or replace function pg_temp.f(p_n text) returns uuid language sql as $$
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.it(p_n text) returns uuid language sql as $$
  select ('c1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.pay(p_n text) returns uuid language sql as $$
  select ('f1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.file(p_n text, p_portfolio uuid, p_amount bigint) returns void language plpgsql as $$
begin
  insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                              legal_regime, currency, status)
  select pg_temp.f(p_n), p.organization_id, p.client_organization_id, p.id, 'b2b_invoice', 'D-' || p_n,
         'commercial_b2b', 'EUR', 'in_collection'
  from public.portfolio p where p.id = p_portfolio;
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type,
                                             valid_from)
  select pg_temp.f(p_n), p.client_organization_id, p.organization_id, 'mandate_amicable', '2026-09-30'
  from public.portfolio p where p.id = p_portfolio;
  insert into public.claim_item (id, account_id, kind, ref, due_date, original_minor)
  values (pg_temp.it(p_n), pg_temp.f(p_n), 'invoice', 'F-' || p_n, '2026-09-01', p_amount);
  perform private.ledger_post('00000000-0000-0000-0000-0000000000aa', 'adjustment', '2026-09-30', 'tf-owe-' || p_n,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', pg_temp.it(p_n), 'component', 'principal'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', 'principal')),
    jsonb_build_object('account_id', pg_temp.f(p_n), 'reason', 'ouverture (test)'));
end $$;
-- A payment on the dedicated account (its line, the payment, its cash_in); matched to the file and allocated unless
-- p_allocate is false (an unidentified payment ops may refund).
create or replace function pg_temp.collect(p_n text, p_amount bigint, p_day date, p_allocate boolean default true)
returns void language plpgsql as $$
declare s uuid := ('e1000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 'r.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, counterparty_iban,
                                       counterparty_name)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, 1, 't:' || s, 'credit',
          p_amount, 'EUR', p_day, 'debtor_credit', 'E2E-' || p_n, 'FR7630004000031234567890143', 'PAYEUR ' || p_n);
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, payer_name, payer_iban, end_to_end_id)
  values (pg_temp.pay(p_n), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s,
          'camt053', 'sct', p_amount, 'EUR', p_day, 'PAYEUR ' || p_n, 'FR7630004000031234567890143', 'E2E-' || p_n);
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_in', p_day, 'cash_in:' || s || ':' || p_day,
          'bank_statement', s::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cf'),
    (1, 2, 'unallocated_payment', -p_amount, 'EUR', null);
  perform private.ledger_post_set();
  if not p_allocate then
    return;
  end if;
  update public.payment set account_id = pg_temp.f(p_n), status = 'matched', match_method = 'rf_structured',
                            matched_at = now()
  where id = pg_temp.pay(p_n);
  perform private.allocation_begin();
  insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy, inputs_hash)
  values (pg_temp.pay(p_n), 1, pg_temp.f(p_n), 'allocate', p_day,
          '{"accessory_rank": "before_principal", "unclassified": "last"}', repeat('0', 64));
  insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
  values (pg_temp.pay(p_n), 1, pg_temp.it(p_n), 'principal', p_amount);
  perform private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1');
end $$;
-- An imported statement of the dedicated account (p_from, default p_to, to p_to, closing p_closing) with debit lines
-- [{e2e, amount, kind, pmt_inf}] booked on p_to, uploaded at p_uploaded_at (default now), camt.053 unless p_format,
-- created by the bank at p_created_at (default: its upload; its sections as given by p_sections).
create or replace function pg_temp.statement(p_n text, p_to date, p_closing bigint, p_debits jsonb default '[]',
                                             p_from date default null, p_uploaded_at timestamptz default null,
                                             p_format text default 'camt053', p_created_at timestamptz default null,
                                             p_sections jsonb default null, p_opening bigint default 0)
returns uuid language plpgsql as $$
declare s uuid := ('e2000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', p_format, 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = coalesce(p_uploaded_at, now()) where id = s;
  insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       original_end_to_end_id)
  select '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, d.ord, 't:' || s || d.ord,
         coalesce(d.v ->> 'dir', 'debit'), (d.v ->> 'amount')::bigint, 'EUR', p_to,
         coalesce(d.v ->> 'kind', 'transfer_out'), d.v ->> 'e2e', d.v ->> 'pmt_inf', d.v ->> 'orig_e2e'
  from jsonb_array_elements(p_debits) with ordinality d (v, ord);
  -- a camt.053's sections as the parser gives them (review round 4, G3): its period, the whole days it shows, its
  -- balances and the bank's creation time (Stmt/CreDtTm), by default its upload's; or as given (p_sections)
  update public.bank_statement set status = 'imported',
    from_date = coalesce((select min((v ->> 'from_date')::date) from jsonb_array_elements(p_sections) v), p_from, p_to),
    to_date = coalesce((select max((v ->> 'to_date')::date) from jsonb_array_elements(p_sections) v), p_to),
    opening_booked_minor = p_opening, closing_booked_minor = p_closing, counts = '{}', finished_at = clock_timestamp(),
    sections = case when p_format = 'camt053'
                    then coalesce(p_sections, jsonb_build_array(jsonb_build_object(
                           'from_date', coalesce(p_from, p_to), 'to_date', p_to,
                           'covers_from', coalesce(p_from, p_to), 'covers_to', p_to,
                           'opening_minor', p_opening::text, 'closing_minor', p_closing::text,
                           'created_at', coalesce(p_created_at, p_uploaded_at, now())))) end
  where id = s;
  return s;
end $$;
-- What the prepare job writes (emulated, as 027).
create or replace function pg_temp.prepare(p_run uuid, p_docs jsonb, p_keys jsonb, p_plan jsonb) returns integer
language plpgsql as $$
declare r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         pf.mandate_id, ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid, e.payment_id,
         e.effective_date, e.effective_date, q.posted_at, e.effective_date + 30, e.effective_date + 27, q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text),
         (select (k ->> 'commission')::bigint from jsonb_array_elements(p_keys) k
          where (k ->> 'account_id')::uuid = e.account_id), 'charged', '[]', true
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  join public.account a on a.id = e.account_id
  join public.portfolio pf on pf.id = a.portfolio_id
  where q.draft_run_id = p_run;
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', (select sum(amount_minor)::text from private.remittance_draft_line where run_id = p_run),
    'invoice_ht', p_plan ->> 'invoice_ht', 'invoice_vat', p_plan ->> 'invoice_vat', 'invoice_ttc', p_plan ->> 'invoice_ttc',
    'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0', 'taken', p_plan ->> 'dc', 'advances', '0', 'refunds', '0',
    'settlement', p_plan ->> 'settlement', 'net', p_plan ->> 'net', 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || p_plan::text, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', p_docs, 'key_states', p_keys, 'plan', p_plan));
  return (select version from public.remittance_run where id = p_run);
end $$;
create or replace function pg_temp.doc(p_c text, p_files jsonb, p_num bigint, p_den bigint) returns jsonb
language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'ref', 'new:70000000-0000-0000-0000-0000000000' || p_c, 'kind', 'invoice',
    'mandate_id', '70000000-0000-0000-0000-0000000000' || p_c, 'ht', ht::text, 'vat', (ht / 5)::text,
    'ttc', (ht + ht / 5)::text, 'vat_rate', '0.2', 'settlement', 'netted', 'clause_ref', 'art. 7.2',
    'lines', jsonb_build_array(jsonb_build_object('kind', 'commission', 'designation_fr', 'Commission (test)',
      'claim_type', 'b2b_invoice', 'rule_id', 'tout', 'families', '["principal"]'::jsonb,
      'tiers', '[]'::jsonb, 'ht', ht::text, 'vat_rate', '0.2')),
    'charges', (select jsonb_agg(jsonb_build_object('account_id', pg_temp.f(x.key), 'tier_key', 'tout',
                                                    'amount', ((x.value)::bigint * p_num / p_den)::text))
                from jsonb_each_text(p_files) x)))
  from (select sum((x.value)::bigint * p_num / p_den)::bigint as ht from jsonb_each_text(p_files) x) s;
$$;
create or replace function pg_temp.keys(p_c text, p_files jsonb, p_num bigint, p_den bigint) returns jsonb
language sql as $$
  select jsonb_agg(jsonb_build_object('account_id', pg_temp.f(x.key), 'tier_key', 'tout',
    'basis', jsonb_build_array(jsonb_build_array('71000000-0000-0000-0000-0000000000' || p_c, x.value)),
    'kept_basis', '0', 'kept', '0', 'commission', ((x.value)::bigint * p_num / p_den)::text))
  from jsonb_each_text(p_files) x;
$$;
create or replace function pg_temp.plan(p_c text, p_gross bigint, p_ht bigint, p_take bigint, p_vat_moved bigint)
returns jsonb language sql as $$
  select jsonb_build_object('settles', case when p_take > 0 then jsonb_build_array(jsonb_build_object(
           'ref', 'new:70000000-0000-0000-0000-0000000000' || p_c, 'kind', 'compensation',
           'mandate_id', '70000000-0000-0000-0000-0000000000' || p_c, 'amount', p_take::text,
           'vat_moved', p_vat_moved::text, 'open_before', (p_ht + p_ht / 5)::text)) else '[]'::jsonb end,
         'net', (p_gross - p_take)::text, 'settlement', p_take::text, 'dc', p_take::text,
         'da', '0', 'vat_moved', p_vat_moved::text, 'deferred', p_take = 0, 'invoice_ht', p_ht::text,
         'invoice_vat', (p_ht / 5)::text, 'invoice_ttc', (p_ht + p_ht / 5)::text);
$$;
create or replace function pg_temp.item(p_run uuid) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('run_id', r.id, 'inputs_hash', r.inputs_hash, 'net_text', r.net_minor::text))
  from public.remittance_run r where r.id = p_run;
$$;
create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
-- one run of a client: requested, prepared as given (its invoice set off by p_take), approved, its job run
create or replace function pg_temp.run(p_c text, p_files jsonb, p_take bigint, p_vat_moved bigint,
                                       p_num bigint default 15, p_den bigint default 100) returns uuid
language plpgsql as $$
declare v_run uuid; v_gross bigint; v_ht bigint;
begin
  select sum((x.value)::bigint), sum((x.value)::bigint * p_num / p_den) into v_gross, v_ht
  from jsonb_each_text(p_files) x;
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_run := (public.request_remittance_run('rq-tf-' || p_c, ('00000000-0000-0000-0000-0000000000' || p_c)::uuid)
            ->> 'run_id')::uuid;
  reset role;
  perform pg_temp.prepare(v_run, pg_temp.doc(p_c, p_files, p_num, p_den), pg_temp.keys(p_c, p_files, p_num, p_den),
                          pg_temp.plan(p_c, v_gross, v_ht, p_take, p_vat_moved));
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs('ap-tf-' || p_c, pg_temp.item(v_run));
  reset role;
  perform private.approve_remittance_run(v_run, (select job_token from public.remittance_run where id = v_run));
  return v_run;
end $$;
-- a command as user p_user (aal2 unless said)
create or replace function pg_temp.gen(p_user text, p_key text, p_late text default null, p_aal text default 'aal2',
                                       p_account uuid default '80000000-0000-0000-0000-0000000000cf')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.generate_transfer_file(p_key, p_account, p_late);
  reset role;
  return v;
end $$;
-- what the worker job does with a file (emulated: no bytes; their hash stands for them)
create or replace function pg_temp.write(p_file uuid) returns jsonb language plpgsql as $$
declare f public.transfer_file;
begin
  select * into f from public.transfer_file where id = p_file;
  return private.transfer_file_record(f.id, f.job_token, encode(sha256(convert_to(f.id::text, 'UTF8')), 'hex'), 1234,
                                      f.organization_id || '/' || f.id || '/' || f.number || '.xml', false, 'pain001-1',
                                      f.nb_of_txs, f.ctrl_sum_minor);
end $$;
create or replace function pg_temp.sha(p_file uuid) returns text language sql as $$
  select encode(sha256(convert_to(p_file::text, 'UTF8')), 'hex');
$$;
create or replace function pg_temp.download(p_user text, p_file uuid, p_ack boolean default false) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  v := public.transfer_file_download(p_file, pg_temp.sha(p_file), p_ack);
  reset role;
  return v;
end $$;
create or replace function pg_temp.tr(p_run uuid) returns public.bank_transfer language sql as $$
  select t.* from public.bank_transfer t where t.id = (select transfer_id from public.remittance_run where id = p_run);
$$;
create or replace function pg_temp.fl(p_file uuid) returns public.transfer_file language sql as $$
  select * from public.transfer_file where id = p_file;
$$;
grant execute on all functions in schema pg_temp to authenticated;
create temporary table t (k text primary key, v uuid) on commit drop;
grant all on t to authenticated;
create temporary table j (k text primary key, v jsonb) on commit drop;

-- The prepare (as 034's) with two knobs for the R124-6 cases: a line's latest execution date per file (`dated`), and the
-- header's earliest one per run (`earliest_hdr`; a header later than its lines lets a run be approved on time while a
-- line is already late at its debit — the booking-time breach, which no single test day reaches otherwise).
create temporary table dated (account_id uuid primary key, latest date not null) on commit drop;
create temporary table earliest_hdr (client text primary key, d date not null) on commit drop;
-- (review 6b-2c money-3) and the items of an account whose mandate's delay cannot be met (`unmeetable_acct`: the job
-- marks them unmeetable, held to one month after their collection)
create temporary table unmeetable_acct (account_id uuid primary key) on commit drop;
create or replace function pg_temp.prepare(p_run uuid, p_docs jsonb, p_keys jsonb, p_plan jsonb) returns integer
language plpgsql as $$
declare r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         pf.mandate_id, ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid, e.payment_id,
         e.effective_date, e.effective_date, q.posted_at, coalesce(d.latest + 3, e.effective_date + 30),
         coalesce(d.latest, e.effective_date + 27), q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text),
         (select (k ->> 'commission')::bigint from jsonb_array_elements(p_keys) k
          where (k ->> 'account_id')::uuid = e.account_id), 'charged', '[]', true
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  join public.account a on a.id = e.account_id
  join public.portfolio pf on pf.id = a.portfolio_id
  left join dated d on d.account_id = e.account_id
  where q.draft_run_id = p_run;
  update private.remittance_draft_line l set unmeetable = true
  from unmeetable_acct u where l.run_id = p_run and l.account_id = u.account_id;
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', (select sum(amount_minor)::text from private.remittance_draft_line where run_id = p_run),
    'invoice_ht', p_plan ->> 'invoice_ht', 'invoice_vat', p_plan ->> 'invoice_vat', 'invoice_ttc', p_plan ->> 'invoice_ttc',
    'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0', 'taken', p_plan ->> 'dc', 'advances', '0', 'refunds', '0',
    'settlement', p_plan ->> 'settlement', 'net', p_plan ->> 'net', 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date',
      coalesce((select h.d from earliest_hdr h where h.client = right(r.client_organization_id::text, 2)),
               (select min(latest_execution_date) from private.remittance_draft_line where run_id = p_run)),
    'unmeetable', (select count(*) from private.remittance_draft_line where run_id = p_run and unmeetable),
    'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || p_plan::text, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', p_docs, 'key_states', p_keys, 'plan', p_plan));
  return (select version from public.remittance_run where id = p_run);
end $$;

create or replace function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
create or replace function pg_temp.trid(p_run text) returns uuid language sql as $$
  select transfer_id from public.remittance_run where id = pg_temp.v(p_run) $$;
create or replace function pg_temp.e2e(p_transfer uuid) returns text language sql as $$
  select end_to_end_id from public.bank_transfer where id = p_transfer $$;
create or replace function pg_temp.status(p_transfer uuid) returns text language sql as $$
  select status from public.bank_transfer where id = p_transfer $$;
create or replace function pg_temp.pmt(p_transfer uuid) returns text language sql as $$
  select i.pmt_inf_id from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
  where t.id = p_transfer and i.file_id = t.transfer_file_id $$;
create or replace function pg_temp.sweep(p_file uuid) returns public.bank_transfer language sql as $$
  select t.* from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
  where i.file_id = p_file and t.kind = 'sweep' $$;
-- a file generated by ops (user 01), written by the job, downloaded (its runs sent)
create or replace function pg_temp.handed_out(p_k text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := (pg_temp.gen('01', p_key) ->> 'file_id')::uuid;
  insert into t values (p_k, v);
  perform pg_temp.write(v);
  perform pg_temp.download('01', v);
  return v;
end $$;
-- the dedicated account's cash in the ledger (every line before booked, it is the bank's balance)
create or replace function pg_temp.cash() returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.book = 'client_money_cash' and la.bank_account_id = '80000000-0000-0000-0000-0000000000cf' $$;
-- line k of statement n
create or replace function pg_temp.ln(p_n text, p_k integer) returns uuid language sql as $$
  select ('e3' || lpad(p_n, 6, '0') || '-0000-0000-0000-' || lpad(p_k::text, 12, '0'))::uuid $$;
-- an imported camt.053 of the dedicated account for p_day (a whole day, produced now) with its lines
-- [{dir, kind, amount, e2e, orig, pmt, iban, code, unsplit}]: opened with the ledger cash, closed with it moved by the
-- lines (review round 6: `unsplit`, a line read from an entry kept unsplit and how many of its details are ours)
create or replace function pg_temp.stmt(p_n text, p_day date, p_lines jsonb default '[]') returns uuid
language plpgsql as $$
declare
  s uuid := ('e3000000-0000-0000-0000-0000000000' || p_n)::uuid;
  -- the bank's balance before this statement: the ledger's cash and the lines not booked yet
  v_open bigint := pg_temp.cash() + (select u.minor from private.bank_unposted('80000000-0000-0000-0000-0000000000cf',
                                                                               'infinity'::date) u);
  v_close bigint;
begin
  select v_open + coalesce(sum(case coalesce(l.v ->> 'dir', 'debit') when 'credit' then 1 else -1 end
                               * (l.v ->> 'amount')::bigint), 0)
  into v_close from jsonb_array_elements(p_lines) l (v);
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       original_end_to_end_id, counterparty_iban, bank_tx_code, batch_entry_ref,
                                       unsplit_ours)
  select pg_temp.ln(p_n, l.ord::integer), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
         s, l.ord, 't:' || s || l.ord, coalesce(l.v ->> 'dir', 'debit'), (l.v ->> 'amount')::bigint, 'EUR', p_day,
         coalesce(l.v ->> 'kind', 'transfer_out'), l.v ->> 'e2e', l.v ->> 'pmt', l.v ->> 'orig', l.v ->> 'iban',
         l.v ->> 'code', case when l.v ? 'unsplit' then 'E-' || s || '-' || l.ord end, (l.v ->> 'unsplit')::smallint
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  update public.bank_statement set status = 'imported', from_date = p_day, to_date = p_day,
    opening_booked_minor = v_open, closing_booked_minor = v_close, counts = '{}', finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object('from_date', p_day, 'to_date', p_day, 'covers_from', p_day,
                                                    'covers_to', p_day, 'opening_minor', v_open::text,
                                                    'closing_minor', v_close::text, 'created_at', now()))
  where id = s;
  return s;
end $$;
-- the debit job's funds pass, emulated: its pure rules' rows (line, kind, transfer) and reviews, then the SQL's
-- re-check under its locks and the posting (private.apply_bank_bookings)
create or replace function pg_temp.row(p_line uuid, p_kind text, p_transfer uuid default null) returns jsonb
language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('line', p_line, 'kind', p_kind, 'transfer', p_transfer)) $$;
create or replace function pg_temp.book(p_rows jsonb, p_reviews jsonb default '[]') returns jsonb language plpgsql as $$
begin
  perform private.bank_booking_begin();
  insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method)
  select r.ord, (r.v ->> 'line')::uuid, r.v ->> 'kind', (r.v ->> 'transfer')::uuid, 'auto'
  from jsonb_array_elements(p_rows) with ordinality r (v, ord);
  insert into pg_temp._booking_review (bank_transaction_id, reason, candidates)
  select (r.v ->> 'line')::uuid, r.v ->> 'reason', coalesce(r.v -> 'candidates', '[]')
  from jsonb_array_elements(p_reviews) r (v);
  return private.apply_bank_bookings('00000000-0000-0000-0000-0000000000aa');
end $$;
select private.bank_booking_begin();   -- (its working tables exist, for the helpers below)
create or replace function pg_temp.skipped(p_line uuid) returns text language sql as $$
  select why from pg_temp._booking_skipped where bank_transaction_id = p_line $$;
create or replace function pg_temp.review(p_line uuid) returns text language sql as $$
  select reason || coalesce(':' || detail, '') from public.bank_debit_review where bank_transaction_id = p_line $$;
create or replace function pg_temp.bookings(p_line uuid) returns text[] language sql as $$
  select coalesce(array_agg(b.seq || ' ' || b.kind || ' ' || b.amount_minor order by b.seq), '{}')
  from public.bank_line_booking b where b.bank_transaction_id = p_line $$;
create or replace function pg_temp.ek(p_key text) returns uuid language sql as $$
  select id from public.ledger_entry
  where organization_id = '00000000-0000-0000-0000-0000000000aa' and idempotency_key = p_key $$;
create or replace function pg_temp.books(p_entry uuid) returns jsonb language sql as $$
  select coalesce(jsonb_object_agg(x.book, x.s), '{}')
  from (select la.book, sum(p.amount_minor)::bigint as s from public.ledger_posting p
        join public.ledger_account la on la.id = p.ledger_account_id
        where p.entry_id = p_entry group by la.book) x $$;
create or replace function pg_temp.owed(p_c text) returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.book = 'client_payable' and la.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.share() returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.book = 'due_to_servicer' and la.organization_id = '00000000-0000-0000-0000-0000000000aa' $$;
-- the invariants this slice keeps, after a step: none of these violations (I8′, I12, the servicer's fund, I13, I14, I15,
-- I16, I18, I19 and its per-line twin, I20) nor the statement gap of I9
create or replace function pg_temp.dirty() returns text[] language plpgsql as $$
declare v uuid;
begin
  v := (private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'run_id')::uuid;
  return coalesce((select array_agg(distinct c.code order by c.code) from public.payment_check_result c
                   where c.run_id = v
                     and c.code in ('client_money_identity', 'own_fund_identity', 'fund_mirror', 'client_payable_debit',
                                    'remittance_completeness', 'bank_cash_identity', 'bank_line_booked',
                                    'transfer_booked_once', 'bank_balance_gap', 'remittance_item_twice',
                                    'remittance_run_totals', 'settlement_ledger', 'vat_pending_ledger')), '{}');
end $$;
-- the transfer checks' rows of a code (P0 alerts), as their subject and amount
create or replace function pg_temp.alerts(p_code text) returns jsonb language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_transfer_checks(v, '00000000-0000-0000-0000-0000000000aa', null);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return coalesce((select jsonb_agg(jsonb_build_array(c.subject_id, c.amount_minor) order by c.amount_minor, c.subject_id)
                   from public.payment_check_result c where c.run_id = v and c.code = p_code), '[]');
end $$;
-- a statement as user p_user at aal2: its single value as text, or the error's message
create or replace function pg_temp.try(p_user text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  begin
    execute p_sql into v;
  exception when others then
    reset role;
    return sqlerrm;
  end;
  reset role;
  return coalesce(v, 'null');
end $$;
create or replace function pg_temp.isolated(p_scenario text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  begin
    execute format('select pg_temp.%I()', p_scenario) into v;
    raise exception 'scenario % rolled back', p_scenario using errcode = 'TR001';
  exception when sqlstate 'TR001' then
    null;
  end;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- a run with its own idempotency keys (a client's second run)
create or replace function pg_temp.runk(p_c text, p_files jsonb, p_take bigint, p_vat_moved bigint, p_key text)
returns uuid language plpgsql as $$
declare v_run uuid; v_gross bigint; v_ht bigint;
begin
  select sum((x.value)::bigint), sum((x.value)::bigint * 15 / 100) into v_gross, v_ht from jsonb_each_text(p_files) x;
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_run := (public.request_remittance_run('rq-run-' || p_key, ('00000000-0000-0000-0000-0000000000' || p_c)::uuid)
            ->> 'run_id')::uuid;
  reset role;
  perform pg_temp.prepare(v_run, pg_temp.doc(p_c, p_files, 15, 100), pg_temp.keys(p_c, p_files, 15, 100),
                          pg_temp.plan(p_c, v_gross, v_ht, p_take, p_vat_moved));
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs('ap-run-' || p_key, pg_temp.item(v_run));
  reset role;
  perform private.approve_remittance_run(v_run, (select job_token from public.remittance_run where id = v_run));
  return v_run;
end $$;
-- Review round 1 (M2c-6b-1): the n-th business day after today (the checks' clocks, whatever day the suite runs)
create or replace function pg_temp.bd_after(p_n integer) returns date language sql as $$
  select c.day from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day > private.paris_today()
  order by c.day offset p_n - 1 limit 1 $$;
-- the transfer checks' codes as of p_today
create or replace function pg_temp.tcodes(p_today date) returns text[] language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa') returning id into v;
  perform private.run_transfer_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return coalesce((select array_agg(distinct c.code order by c.code) from public.payment_check_result c
                   where c.run_id = v), '{}');
end $$;
-- the payment checks' rows, as [code, subject]
create or replace function pg_temp.pchecks() returns jsonb language plpgsql as $$
declare v uuid;
begin
  v := (private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'run_id')::uuid;
  return coalesce((select jsonb_agg(distinct jsonb_build_array(c.code, c.subject_id)) from public.payment_check_result c
                   where c.run_id = v), '[]');
end $$;
-- « Lier » by ops (user 01), its refusal raised
create or replace function pg_temp.link(p_key text, p_line uuid, p_kind text, p_payment uuid, p_refund uuid,
                                        p_expected text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.link_debit(p_key, p_line, p_kind, p_payment, p_refund, p_expected, 'motif de test') ->> 'kind';
  reset role;
  return v;
end $$;
-- a statement in a subtransaction always rolled back: its value as text, or the error's message and hint
create or replace function pg_temp.attempt(p_sql text) returns text language plpgsql as $$
declare v text; h text;
begin
  begin
    execute p_sql into v;
    raise exception 'attempt rolled back' using errcode = 'TR002';
  exception when sqlstate 'TR002' then
    null;
  when others then
    get stacked diagnostics v = message_text, h = pg_exception_hint;
    v := v || coalesce(' | ' || nullif(h, ''), '');
  end;
  reset role;
  return coalesce(v, 'null');
end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- Collections (three days ago) and the first runs: Martin 200 000 → net 164 000; Lilas 512 000 → net 419 840;

-- 037's own helpers ---------------------------------------------------------------------------------------------------
-- an imported camt.053 of an account (the dedicated one by default) for p_day with its lines [{dir, kind, amount, e2e,
-- orig, pmt, iban, unsplit, details, count, nb, charges, read}], opened with the ledger cash and closed with it moved:
-- line k of statement n is pg_temp.l2(n, k) (n up to 6 hex digits)
create or replace function pg_temp.l2(p_n text, p_k integer) returns uuid language sql as $$
  select ('e4' || lpad(p_n, 6, '0') || '-0000-0000-0001-' || lpad(p_k::text, 12, '0'))::uuid $$;
create or replace function pg_temp.stmt2(p_n text, p_day date, p_lines jsonb,
                                         p_account uuid default '80000000-0000-0000-0000-0000000000cf')
returns uuid language plpgsql as $$
declare
  s uuid := ('e4' || lpad(p_n, 6, '0') || '-0000-0000-0000-000000000000')::uuid;
  v_open bigint := case when p_account = '80000000-0000-0000-0000-0000000000cf'
                        then pg_temp.cash() + (select u.minor from private.bank_unposted(
                                                 '80000000-0000-0000-0000-0000000000cf', 'infinity'::date) u)
                        else 0 end;
  v_close bigint;
begin
  select v_open + coalesce(sum(case coalesce(l.v ->> 'dir', 'debit') when 'credit' then 1 else -1 end
                               * (l.v ->> 'amount')::bigint), 0)
  into v_close from jsonb_array_elements(p_lines) l (v);
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', p_account, 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       original_end_to_end_id, counterparty_iban, batch_entry_ref, unsplit_ours,
                                       unsplit_details, unsplit_detail_count, unsplit_batch_count, charges_minor,
                                       charges_read)
  select pg_temp.l2(p_n, l.ord::integer), '00000000-0000-0000-0000-0000000000aa', p_account, s, l.ord,
         't:' || s || l.ord, coalesce(l.v ->> 'dir', 'debit'), (l.v ->> 'amount')::bigint, 'EUR', p_day,
         coalesce(l.v ->> 'kind', 'transfer_out'), l.v ->> 'e2e', l.v ->> 'pmt', l.v ->> 'orig', l.v ->> 'iban',
         case when l.v ? 'unsplit' then 'E-' || s || '-' || l.ord end, (l.v ->> 'unsplit')::smallint, l.v -> 'details',
         (l.v ->> 'count')::integer, (l.v ->> 'nb')::integer, (l.v ->> 'charges')::bigint, (l.v ->> 'read')::boolean
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  update public.bank_statement set status = 'imported', from_date = p_day, to_date = p_day,
    opening_booked_minor = v_open, closing_booked_minor = v_close, counts = '{}', finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object('from_date', p_day, 'to_date', p_day, 'covers_from', p_day,
                                                    'covers_to', p_day, 'opening_minor', v_open::text,
                                                    'closing_minor', v_close::text, 'created_at', now()))
  where id = s;
  return s;
end $$;
-- a part, as the sheets send it
create or replace function pg_temp.pt(p_kind text, p_transfer uuid, p_amount bigint, p_client uuid default null,
                                      p_returns uuid default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('kind', p_kind, 'transfer_id', p_transfer, 'client_id', p_client,
                                              'returns_line_id', p_returns, 'amount', p_amount::text)) $$;
create or replace function pg_temp.pv(p_line uuid, p_parts jsonb, p_user text default '01', p_aal text default 'aal2')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.transfer_line_preview(p_line, p_parts);
  reset role;
  return v;
end $$;
create or replace function pg_temp.op(p_line uuid, p_user text default '01', p_aal text default 'aal2')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.transfer_line_options(p_line);
  reset role;
  return v;
end $$;
-- the parts the options propose for a line (its first proposal's request)
create or replace function pg_temp.prop(p_line uuid) returns jsonb language sql as $$
  select pg_temp.op(p_line) -> 'proposals' -> 0 -> 'request' $$;
-- « Comptabiliser » by ops (user 01 by default) with the preview's text (as the sheet sends it)
create or replace function pg_temp.bk(p_line uuid, p_parts jsonb, p_key text default null, p_user text default '01',
                                      p_text text default null, p_reason text default 'motif de test',
                                      p_aal text default 'aal2') returns jsonb language plpgsql as $$
declare v jsonb; v_text text := p_text;
begin
  if v_text is null then
    v_text := coalesce(pg_temp.pv(p_line, p_parts) ->> 'expected_text', 'none');
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.book_transfer_line(coalesce(p_key, 'bk-' || md5(p_line::text || coalesce(p_parts::text, ''))), p_line,
                                 p_parts, v_text, p_reason);
  reset role;
  return v;
end $$;
-- the same, its refusal's code (or ok), its effects kept only when it books
create or replace function pg_temp.bkx(p_line uuid, p_parts jsonb, p_key text default null, p_user text default '01',
                                       p_text text default null, p_reason text default 'motif de test',
                                       p_aal text default 'aal2') returns text language plpgsql as $$
begin
  perform pg_temp.bk(p_line, p_parts, p_key, p_user, p_text, p_reason, p_aal);
  return 'ok';
exception when others then
  return regexp_replace(sqlerrm, '^transfer line booking refused: ', '');
end $$;
-- the preview's refusal (or ok)
create or replace function pg_temp.why(p_line uuid, p_parts jsonb) returns text language sql as $$
  select coalesce(pg_temp.pv(p_line, p_parts) ->> 'why', 'ok') $$;
-- a payout in flight: client c's collection n of p_amount (three days ago), its run (its commission set off: N = 82 %),
-- the file generated and handed out (every ordered payout and the sweep in it); returns the payout
create or replace function pg_temp.inflight(p_c text, p_n text, p_amount bigint, p_key text) returns uuid
language plpgsql as $$
declare v_run uuid; v_file uuid;
begin
  perform pg_temp.queued(p_c, p_n, p_amount, p_key);
  v_file := (pg_temp.gen('01', 'gen-' || p_key) ->> 'file_id')::uuid;
  insert into t values ('file-' || p_key, v_file) on conflict (k) do update set v = excluded.v;
  perform pg_temp.write(v_file);
  perform pg_temp.download('01', v_file);
  return pg_temp.v('tr-' || p_key);
end $$;
-- the same up to the approval (the payout ordered, in no file)
create or replace function pg_temp.queued(p_c text, p_n text, p_amount bigint, p_key text) returns uuid
language plpgsql as $$
declare v_run uuid;
begin
  perform pg_temp.file(p_n, ('20000000-0000-0000-0000-0000000000' || p_c)::uuid, p_amount);
  perform pg_temp.collect(p_n, p_amount, private.paris_today() - 3);
  v_run := pg_temp.runk(p_c, jsonb_build_object(p_n, p_amount::text), p_amount * 18 / 100, p_amount * 3 / 100, p_key);
  insert into t values ('run-' || p_key, v_run) on conflict (k) do update set v = excluded.v;
  insert into t values ('tr-' || p_key, (select transfer_id from public.remittance_run where id = v_run))
  on conflict (k) do update set v = excluded.v;
  return pg_temp.v('tr-' || p_key);
end $$;
-- (test only) the items of a file executed on p_day: its execution dates moved back (files generated today execute on
-- the next business day after the account's cut-off, and a statement line is never dated in the future)
create or replace function pg_temp.exec_on(p_file uuid, p_day date) returns void language plpgsql as $$
begin
  alter table public.transfer_file_item disable trigger transfer_file_item_append_only;
  update public.transfer_file_item set execution_date = p_day where file_id = p_file;
  alter table public.transfer_file_item enable always trigger transfer_file_item_append_only;
end $$;
-- a client's waiting queue (its pending items, reserved or not), its returned-payout items, its payout account
create or replace function pg_temp.queued_minor(p_c text) returns bigint language sql as $$
  select coalesce(sum(q.amount_minor), 0)::bigint from private.remittance_pending q
  where q.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.returned_items(p_c text) returns bigint language sql as $$
  select count(*) from private.remittance_pending q
  where q.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid and q.kind = 'payout_returned' $$;
create or replace function pg_temp.payout_account(p_c text) returns text language sql as $$
  select status from public.client_payout_account
  where client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid order by created_at limit 1 $$;
create or replace function pg_temp.iban(p_c text) returns text language sql as $$
  select iban from public.client_payout_account
  where client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid order by created_at limit 1 $$;
create or replace function pg_temp.c(p_c text) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.amt(p_transfer uuid) returns bigint language sql as $$
  select amount_minor from public.bank_transfer where id = p_transfer $$;
-- a line's bookings, its entries' keys
create or replace function pg_temp.keys(p_line uuid) returns text[] language sql as $$
  select coalesce(array_agg(regexp_replace(e.idempotency_key, '[0-9a-f-]{36}', '·', 'g') order by k.seq), '{}')
  from public.bank_line_booking k join public.ledger_entry e on e.id = k.entry_id
  where k.bank_transaction_id = p_line $$;
-- the advance and pending rows an unplanned booking of line p_line posted
create or replace function pg_temp.unplanned_rows(p_line uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'entries', (select jsonb_agg(e.entry_type || ':' || regexp_replace(e.idempotency_key, '[0-9a-f-]{36}', '·', 'g')
                                 order by e.idempotency_key)
                from public.ledger_entry e
                where e.organization_id = '00000000-0000-0000-0000-0000000000aa'
                  and (e.idempotency_key like 'remit:line:' || p_line || ':%'
                       or e.idempotency_key like 'adv:line:' || p_line || ':%')),
    'pending', (select jsonb_agg(q.kind || ':' || q.amount_minor order by q.kind)
                from private.remittance_pending q
                join public.ledger_entry e on e.id = q.ledger_entry_id
                where e.idempotency_key like 'remit:line:' || p_line || ':%'
                   or e.idempotency_key like 'adv:line:' || p_line || ':%'),
    'advance', (select jsonb_agg(a.cause || ':' || a.amount_minor) from public.client_advance a
                where a.bank_transaction_id = p_line)) $$;
-- the funds pass messages queued (process_debits with funds_after)
create or replace function pg_temp.funds_msgs() returns bigint language sql as $$
  select count(*) from pgmq.q_payments m
  where m.message ->> 'type' = 'process_debits' and m.message ? 'funds_after' and m.message -> 'funds_after' = 'null' $$;
-- (review CSR-2) whether this session holds the one-bigint advisory lock of key k, as pg_advisory_xact_lock(bigint) takes
-- it (pg_locks: classid the high 32 bits, objid the low 32 bits, objsubid 1)
create or replace function pg_temp.holds_advisory(p_key bigint) returns boolean language sql as $$
  select exists (select 1 from pg_locks k where k.locktype = 'advisory' and k.pid = pg_backend_pid() and k.granted
                   and k.objsubid = 1 and k.classid = ((p_key >> 32) & 4294967295)::text::oid
                   and k.objid = (p_key & 4294967295)::text::oid) $$;
-- a client's returned payout account retired and its IBAN confirmed again (as a client who gives its RIB again after the
-- return: the payout_account_returned blocker lifts)
create or replace function pg_temp.reconfirm(p_c text) returns void language plpgsql as $$
begin
  update public.client_payout_account set status = 'retired', closed_by = '10000000-0000-0000-0000-000000000001',
    closed_at = now(), closed_reason = 'Reconfirmé après le retour du virement (test)'
  where client_organization_id = pg_temp.c(p_c) and status = 'returned';
  insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                            evidence_document_id, proposed_by)
  select gen_random_uuid(), a.organization_id, a.client_organization_id, a.currency, a.iban, a.holder_name,
         a.evidence_document_id, '10000000-0000-0000-0000-000000000004'
  from public.client_payout_account a where a.client_organization_id = pg_temp.c(p_c)
  order by a.created_at limit 1;
  update public.client_payout_account set status = 'active', confirmed_at = now(), confirmed_via = 'second_admin',
    confirmed_by = '10000000-0000-0000-0000-000000000001'
  where client_organization_id = pg_temp.c(p_c) and confirmed_at is null;
end $$;
-- a part's facts in a preview: [kind, paid, advance, bound]
create or replace function pg_temp.pp(p_preview jsonb, p_n integer default 0) returns jsonb language sql as $$
  select jsonb_build_array(p_preview -> 'parts' -> p_n ->> 'kind', p_preview -> 'parts' -> p_n ->> 'paid_minor',
                           p_preview -> 'parts' -> p_n ->> 'advance_minor', p_preview -> 'parts' -> p_n ->> 'p_bound') $$;
grant execute on all functions in schema pg_temp to authenticated;

-- The base: Martin's and Lilas' collections and runs; FA handed out (x1 Martin 164 000, x2 Lilas 419 840: no sweep, the
-- servicer's share nil before their debits); x1's debit booked by the job yesterday, x2 still in flight
select pg_temp.file(x.n, ('20000000-0000-0000-0000-0000000000' || x.c)::uuid, x.amount)
from (values ('01', 'a1', 200000), ('02', 'a2', 512000)) x (n, c, amount);
select pg_temp.collect(x.n, x.amount, private.paris_today() - 3)
from (values ('01', 200000), ('02', 512000)) x (n, amount);
select pg_temp.collect('13', 1000000, private.paris_today() - 3, false);
insert into t select 'r1', pg_temp.run('a1', '{"01": "200000"}', 36000, 6000);
insert into t select 'r2', pg_temp.run('a2', '{"02": "512000"}', 92160, 15360);
select pg_temp.stmt('00', private.paris_today() - 1);
select pg_temp.handed_out('fa', 'gen-file-a');
insert into t values ('x1', pg_temp.trid('r1')), ('x2', pg_temp.trid('r2'));
select pg_temp.stmt2('b1', private.paris_today() - 1, jsonb_build_array(
  jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1')))));
select pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('b1', 1), 'payout', pg_temp.v('x1'))));
-- S03: x1 debited a second time today (E: its RMT id), reviewed transfer_debited_twice by the job
select pg_temp.stmt2('b2', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1')))));
select pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.l2('b2', 1),
                                                               'reason', 'transfer_debited_twice')));
-- another servicer, bb: its client, its accounts, a payout of its own and a line (the tenant filter's foreign ids)
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Client de BB',
   '552100554');
insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000bf', '00000000-0000-0000-0000-0000000000bb', 'client_funds',
   'FR8130004000039876543210134', 'TESTFRPPXXX', 'EUR', 'Fonds BB', 'camt053', '2026-01-01');
insert into public.bank_transfer (id, organization_id, kind, debtor_bank_account_id, currency, amount_minor, payee_name,
                                  payee_iban, end_to_end_id, requested_execution_date, client_organization_id)
values ('b0000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000bb', 'payout',
        '80000000-0000-0000-0000-0000000000bf', 'EUR', 164000, 'CLIENT DE BB', 'FR7630004000031234567890143',
        'RMT00000000BB01', private.paris_today(), '00000000-0000-0000-0000-0000000000b1');
insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                   size_bytes, storage_path)
values ('e6000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000bb',
        '80000000-0000-0000-0000-0000000000bf', 'EUR', 'camt053', 'b.xml', repeat('b', 64), 1, 'test/bb');
update public.bank_statement set status = 'uploaded', uploaded_at = now()
where id = 'e6000000-0000-0000-0000-0000000000b1';
insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind, end_to_end_id)
values ('e6000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000bb',
        '80000000-0000-0000-0000-0000000000bf', 'e6000000-0000-0000-0000-0000000000b1', 1, 't:bb1', 'debit', 164000,
        'EUR', private.paris_today(), 'transfer_out', 'RMT00000000BB01');



-- 037's P helpers (copied) ---------------------------------------------------------------------------------------------
-- « Lier » by ops (user 01): ok, or the refusal's code
create or replace function pg_temp.lk(p_line uuid, p_kind text, p_refund uuid default null) returns text
language plpgsql as $$
begin
  perform pg_temp.link('lk-' || md5(p_line::text || p_kind || coalesce(p_refund::text, '')), p_line, p_kind, null,
                       p_refund, null);
  return 'ok';
exception when others then
  return regexp_replace(sqlerrm, '^(debit link refused|bank booking refused): ', '');
end $$;
-- (review 6b-2c money-1) « Retour du paiement … » or its loss by ops: ok, or the refusal's code
create or replace function pg_temp.lkp(p_line uuid, p_kind text, p_payment uuid, p_left text) returns text
language plpgsql as $$
begin
  perform pg_temp.link('lkp-' || md5(p_line::text || p_kind || p_payment::text), p_line, p_kind, p_payment, null, p_left);
  return 'ok';
exception when others then
  return regexp_replace(sqlerrm, '^(debit link refused|bank booking refused): ', '');
end $$;
-- the queue's rows of tab p_tab as ops (user 01): {line: [review_reason, bookable_as, first candidate]}
create or replace function pg_temp.dq(p_tab text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  select coalesce(jsonb_object_agg(q.bank_transaction_id::text,
                                   jsonb_build_array(q.review_reason, to_jsonb(q) ->> 'bookable_as',
                                                     q.candidates -> 0)), '{}')
  into v from public.debit_queue(p_tab, 0, 100) q;
  reset role;
  return v;
end $$;
-- private.transfer_line_offers(line, transfer), or null before this slice
create or replace function pg_temp.offers(p_line uuid, p_transfer uuid) returns boolean language plpgsql as $$
declare v boolean;
begin
  if to_regprocedure('private.transfer_line_offers(uuid,uuid)') is null then
    return null;
  end if;
  execute 'select private.transfer_line_offers($1, $2)' into v using p_line, p_transfer;
  return v;
end $$;
-- whether the options of a line propose a booking containing this transfer
create or replace function pg_temp.proposes(p_line uuid, p_transfer uuid) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(coalesce(pg_temp.op(p_line) -> 'proposals', '[]')) p
                 cross join lateral jsonb_array_elements(p -> 'request') x
                 where x ->> 'transfer_id' = p_transfer::text) $$;
-- a CSV statement of the dedicated account (lines [{day, kind, amount, e2e, pmt, iban}], line k is pg_temp.l2(n, k)),
-- its period p_from … p_to, uploaded at p_uploaded (a CSV covers a day uploaded after it, its period ending after it)
create or replace function pg_temp.csv2(p_n text, p_lines jsonb, p_from date, p_to date, p_uploaded timestamptz)
returns uuid language plpgsql as $$
declare s uuid := ('e4' || lpad(p_n, 6, '0') || '-0000-0000-0000-000000000000')::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'csv', 'r.csv',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = p_uploaded where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       counterparty_iban)
  select pg_temp.l2(p_n, l.ord::integer), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
         s, l.ord, 'c:' || s || l.ord, 'debit', (l.v ->> 'amount')::bigint, 'EUR', (l.v ->> 'day')::date,
         l.v ->> 'kind', l.v ->> 'e2e', l.v ->> 'pmt', l.v ->> 'iban'
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  update public.bank_statement set status = 'imported', from_date = p_from, to_date = p_to, counts = '{}',
    finished_at = clock_timestamp()
  where id = s;
  return s;
end $$;
-- the runs' nightly checks as of p_today; then each run's breach rows' blocked reasons (coalesced to 'none')
create or replace function pg_temp.runs_check(p_today date) returns void language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_remittance_runs_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
end $$;
create or replace function pg_temp.breaches(p_run uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(coalesce(b.blocked_reason, 'none') order by b.ledger_entry_id), '[]')
  from public.remittance_deadline_breach b where b.run_id = p_run $$;
-- the transfer checks' bank_line_unbooked row as of p_today: [its line ids, its p0 flag]
create or replace function pg_temp.unbooked(p_today date) returns jsonb language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_transfer_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return coalesce((select jsonb_build_array(c.details -> 'ids', c.details -> 'p0') from public.payment_check_result c
                   where c.run_id = v and c.code = 'bank_line_unbooked'), '[null, null]');
end $$;
-- a new read of this slice as user p_user (aal p_aal): its value as jsonb, null when it does not exist yet
create or replace function pg_temp.read(p_user text, p_sql text, p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    execute p_sql into v;
  exception when undefined_function then
    v := to_jsonb('missing'::text);
  when insufficient_privilege then
    v := to_jsonb('not allowed'::text);
  end;
  reset role;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;

create or replace function pg_temp.cancel_run(p_run uuid, p_key text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user('04');
  set local role authenticated;
  v := public.cancel_remittance_run('cancel-' || p_key, p_run, (select version from public.remittance_run where id = p_run),
                                    'annulé (test)') ->> 'status';
  reset role;
  return v;
end $$;
-- a payout cancelled after its file was handed out (the switch on, as 6b-3 will do it), its run cancelled
create or replace function pg_temp.cancelled_late(p_c text, p_n text, p_amount bigint, p_key text,
                                                  p_cancel_run boolean default true) returns uuid language plpgsql as $$
declare v_t uuid;
begin
  v_t := pg_temp.inflight(p_c, p_n, p_amount, p_key);
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_t;
  if p_cancel_run then
    perform pg_temp.cancel_run(pg_temp.v('run-' || p_key), p_key);
  end if;
  return v_t;
end $$;

-- R. refund-link-blocked-by-returned-payout-twin (ADR-0014 « Left open after round 3 »; COMPLIANCE OQ-86) -------------
-- What « Lier » and its options say on a reference-less debit of a refund's amount: rule 3b's candidates, whether
-- debit_link_options lists the refund, the refund link, the fee and the explanation (each attempted and rolled back),
-- and the options' refusal
create or replace function pg_temp.r_reads(p_line uuid, p_refund uuid) returns jsonb language plpgsql as $$
begin
  return jsonb_build_object(
    'candidates', (select jsonb_agg(c.cand order by c.cand)
                   from private.transfer_line_candidates(p_line, private.transfer_line_class(p_line)) c),
    'listed', pg_temp.read('01', format(
      'select jsonb_path_query_array(public.debit_link_options(%L) -> ''refunds'', ''$[*].refund_request_id'')', p_line))
      = jsonb_build_array(p_refund),
    'refund', pg_temp.attempt(format('select pg_temp.lk(%L, ''refund'', %L)', p_line, p_refund)),
    'fee', pg_temp.attempt(format('select pg_temp.lk(%L, ''fee'')', p_line)),
    'explained', pg_temp.attempt(format('select pg_temp.lk(%L, ''explained'')', p_line)),
    'options', pg_temp.op(p_line) -> 'refusal');
end $$;
-- a refund of p_amount requested by ops on payment p_n (unallocated), to the payer's IBAN; its file generated, written
-- and downloaded (k), executed yesterday
create or replace function pg_temp.r_refund(p_n text, p_amount bigint, p_key text) returns uuid language plpgsql as $$
declare v_reason text; v_left text; v_r uuid;
begin
  perform pg_temp.collect(p_n, p_amount, private.paris_today() - 3, false);
  select p.review_reason, x.unallocated_minor::text into v_reason, v_left
  from public.payment p cross join lateral private.payment_positions(array[p.id]) x where p.id = pg_temp.pay(p_n);
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_r := (public.request_refund(p_key, pg_temp.pay(p_n), p_amount::text, 'FR7630004000031234567890143',
                                'PAYEUR ' || p_n, 'other', v_reason, v_left, 'payé deux fois (test)')
          ->> 'refund_request_id')::uuid;
  reset role;
  perform pg_temp.exec_on(pg_temp.handed_out('file-' || p_key, 'gen-' || p_key), private.paris_today() - 1);
  return v_r;
end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- Lilas' x2 (419 840) in flight; a refund R of 419 840 to a payer, in a file handed out; a reference-less debit of that
-- amount (a CSV: neither an end-to-end id nor an IBAN). While x2 is in flight (i) the line may be x2: the refund link is
-- refused payout_candidate and not listed. x2 then debited and returned by its payee's bank (iii for good): the line is
-- R's debit or a re-execution of the returned payout the bank was never asked for — the refund link is listed and
-- taken (OQ-86's trade-off), the fee and the explanation still refused; R executed, Lilas' returned item still queued
create or replace function pg_temp.r_returned_twin() returns jsonb language plpgsql as $$
declare v_x uuid := pg_temp.v('x2'); v_r uuid; v_line uuid := pg_temp.l2('cf1', 1); v_in jsonb; v jsonb;
begin
  perform pg_temp.exec_on(pg_temp.v('fa'), private.paris_today() - 2);
  v_r := pg_temp.r_refund('ce', 419840, 'r-twin-refund');
  perform pg_temp.stmt2('cf1', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 419840, 'kind', 'other_debit')));
  v_in := pg_temp.r_reads(v_line, v_r);
  -- x2 debited (the job's booking), then returned by the payee's bank (booked as its return): x2 returned
  perform pg_temp.stmt2('cf2', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('cf2', 1), 'payout', v_x)));
  perform pg_temp.stmt2('cf3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 419840, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.bk(pg_temp.l2('cf3', 1), pg_temp.prop(pg_temp.l2('cf3', 1)));
  v := jsonb_build_object(
    'in_flight', v_in, 'status', pg_temp.status(v_x), 'returned', pg_temp.r_reads(v_line, v_r),
    'linked', pg_temp.lk(v_line, 'refund', v_r));
  return v || jsonb_build_object(
    'refund_status', (select q.status from public.refund_request q where q.id = v_r),
    'lilas', jsonb_build_array(pg_temp.queued_minor('a2'), pg_temp.returned_items('a2')),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('r_returned_twin'),
  '{"in_flight": {"candidates": ["i", "ii"], "listed": false, "refund": "payout_candidate", "fee": "payout_candidate",
                  "explained": "payout_candidate", "options": "line_ambiguous"},
    "status": "returned",
    "returned": {"candidates": ["ii", "iii"], "listed": true, "refund": "ok", "fee": "payout_candidate",
                 "explained": "payout_candidate", "options": "line_ambiguous"},
    "linked": "ok", "refund_status": "executed", "lilas": [419840, 1], "dirty": []}'::jsonb,
  'R (6b-2d, refund-link-blocked-by-returned-payout-twin; COMPLIANCE OQ-86): a reference-less debit of a refund''s '
  'amount, the refund in a file handed out (ii), is refused that refund''s link while a payout of that amount is in '
  'flight (i) — not listed, payout_candidate —, and takes it once that payout was returned (iii only): listed by '
  'debit_link_options and linked, the refund executed; the fee and the explanation stay refused, the returned client''s '
  'item stays queued, the checks clean');

-- Dupont's payout (82 000) cancelled after its file was handed out (the switch on, as 6b-3 will), its run still sent: it
-- may still be that run's payout (critic2 ML-4) — the refund link of a refund of 82 000 on a reference-less debit of
-- that amount stays refused payout_candidate; the run cancelled, the payout is (iii) only and the refund link is taken
create or replace function pg_temp.r_cancelled_live() returns jsonb language plpgsql as $$
declare v_t uuid; v_r uuid; v_line uuid := pg_temp.l2('cf8', 1); v_live jsonb; v_runs jsonb; v jsonb;
begin
  v_t := pg_temp.cancelled_late('a6', '06', 100000, 'r-live', false);   -- 82 000, its run still sent
  perform pg_temp.exec_on(pg_temp.v('file-r-live'), private.paris_today() - 2);
  v_r := pg_temp.r_refund('cf', 82000, 'r-live-refund');
  perform pg_temp.stmt2('cf8', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 82000, 'kind', 'other_debit')));
  v_live := pg_temp.r_reads(v_line, v_r);
  v_runs := jsonb_build_array((select r.status from public.remittance_run r where r.id = pg_temp.v('run-r-live')));
  perform pg_temp.cancel_run(pg_temp.v('run-r-live'), 'r-live');
  v := jsonb_build_object(
    'runs', v_runs || jsonb_build_array((select r.status from public.remittance_run r
                                         where r.id = pg_temp.v('run-r-live'))),
    'transfer', pg_temp.status(v_t), 'live', v_live, 'ended', pg_temp.r_reads(v_line, v_r),
    'linked', pg_temp.lk(v_line, 'refund', v_r));
  return v || jsonb_build_object('refund_status', (select q.status from public.refund_request q where q.id = v_r));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('r_cancelled_live'),
  '{"runs": ["sent", "cancelled"], "transfer": "cancelled",
    "live": {"candidates": ["ii", "iii"], "listed": false, "refund": "payout_candidate", "fee": "payout_candidate",
             "explained": "payout_candidate", "options": "line_ambiguous"},
    "ended": {"candidates": ["ii", "iii"], "listed": true, "refund": "ok", "fee": "payout_candidate",
              "explained": "payout_candidate", "options": "line_ambiguous"},
    "linked": "ok", "refund_status": "executed"}'::jsonb,
  'R (6b-2d; critic2 ML-4): beside a cancelled payout of its amount whose run is still sent, a refund''s reference-less '
  'debit is refused that refund''s link (the debit may be the run''s payout); once the run is cancelled, it is listed '
  'and linked');

-- Two refunds of 5 300, each in a file handed out (ii, ii): a reference-less debit of that amount may be
-- either — each refund's link stays refused payout_candidate (another refund in a file), neither listed
create or replace function pg_temp.r_two_refunds() returns jsonb language plpgsql as $$
declare v_r1 uuid; v_r2 uuid; v_line uuid := pg_temp.l2('cf9', 1);
begin
  v_r1 := pg_temp.r_refund('c1', 5300, 'r-two-refunds-1');
  v_r2 := pg_temp.r_refund('c2', 5300, 'r-two-refunds-2');
  perform pg_temp.stmt2('cf9', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 5300, 'kind', 'other_debit')));
  return jsonb_build_object('first', pg_temp.r_reads(v_line, v_r1) - 'fee' - 'explained',
                            'second', pg_temp.r_reads(v_line, v_r2) - 'fee' - 'explained');
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('r_two_refunds'),
  '{"first": {"candidates": ["ii", "ii"], "listed": false, "refund": "payout_candidate", "options": "line_ambiguous"},
    "second": {"candidates": ["ii", "ii"], "listed": false, "refund": "payout_candidate", "options": "line_ambiguous"}}'::jsonb,
  'R (6b-2d): beside another refund of its amount in a file handed out, a refund''s reference-less debit is still '
  'refused each refund''s link (payout_candidate), neither listed');

-- E. suppression-e0-names-our-other-lot (ADR-0014 « Left open after round 3 »; COMPLIANCE OQ-83, CPCE-08) -----------
-- Petit's payout x (182 040) in its own file, debited and booked; Petit's next payout T (182 040, same payee IBAN) in
-- another file, in flight, its line late today; a debit today of that amount to Petit's IBAN with an end-to-end id that
-- is not ours and, as PmtInfId (p_pmt): x's lot (`other`: the bank executed x again, dropping our id and keeping its
-- lot), T's own lot (`own`), a TF PmtInfId naming no lot of ours (`unknown`), or one naming only another servicer's lot
-- (`servicer`). What the line is (class, whether the
-- options propose T's booking), what the suppression says of T two business days on, what the command does with T's
-- payout part and with a client part (attempted, rolled back), the fee's guard, and T's breach rows at that check
create or replace function pg_temp.e_lot(p_pmt text) returns jsonb language plpgsql as $$
declare v_today date := private.paris_today(); v_x uuid; v_t uuid; v_f uuid; v_line uuid := pg_temp.l2('ce6', 1);
        v jsonb;
begin
  v_x := pg_temp.inflight('a8', 'e6', 222000, 'e-lot-x');   -- 182 040
  perform pg_temp.exec_on(pg_temp.v('file-e-lot-x'), v_today - 2);
  perform pg_temp.stmt2('ce5', v_today - 2, jsonb_build_array(jsonb_build_object('amount', 182040, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('ce5', 1), 'payout', v_x)));
  insert into dated values (pg_temp.f('e7'), v_today);
  insert into earliest_hdr values ('a8', v_today + 10);
  v_t := pg_temp.queued('a8', 'e7', 222000, 'e-lot-t');      -- 182 040
  v_f := pg_temp.handed_out('file-e-lot-t', 'gen-e-lot-t');
  perform pg_temp.exec_on(v_f, v_today);
  alter table public.bank_transfer disable trigger user;
  update public.bank_transfer set requested_execution_date = v_today where id = v_t;
  alter table public.bank_transfer enable trigger user;
  if p_pmt = 'servicer' then
    -- the other servicer's file on its own account, whose lot has that PmtInfId (our PmtInfIds are unique per servicer;
    -- the lot is read whatever its file's status)
    insert into public.transfer_file (id, organization_id, debtor_bank_account_id, currency, number, msg_id, pain_version,
                                      created_at_iso, initiating_party, debtor_name, debtor_iban, nb_of_txs,
                                      ctrl_sum_minor, first_execution_date, last_execution_date, cash_check)
    values ('b0000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000bb',
            '80000000-0000-0000-0000-0000000000bf', 'EUR', 'TF-2026-999998', 'MSG-BB', 'pain.001.001.09',
            '2026-11-01T10:00:00+01:00', 'AUTRE CABINET', 'AUTRE CABINET', 'FR8130004000039876543210134', 1, 164000,
            v_today, v_today, '{}');
    insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id, pmt_inf_id, execution_date)
    values ('b0000000-0000-0000-0000-0000000000f1', 1, 'b0000000-0000-0000-0000-0000000000b1',
            '00000000-0000-0000-0000-0000000000bb', 'TF-2026-999998-1', v_today);
  end if;
  perform pg_temp.stmt2('ce6', v_today, jsonb_build_array(jsonb_build_object(
    'amount', 182040, 'e2e', 'E2E-AUTRE-BANQUE-0001', 'iban', pg_temp.iban('a8'),
    'pmt', case p_pmt when 'other' then pg_temp.pmt(v_x) when 'own' then pg_temp.pmt(v_t)
                      when 'servicer' then 'TF-2026-999998-1' else 'TF-2026-999999-1' end)));
  perform pg_temp.csv2('cea', '[]'::jsonb, v_today, pg_temp.bd_after(9),
                       (pg_temp.bd_after(9) + 1 + time '09:00') at time zone 'Europe/Paris');
  v := jsonb_build_object(
    'lots', jsonb_build_array(pg_temp.pmt(v_x) <> pg_temp.pmt(v_t), pg_temp.status(v_x), pg_temp.status(v_t)),
    'line', jsonb_build_array(private.transfer_line_class(v_line), pg_temp.offers(v_line, v_t),
                              pg_temp.proposes(v_line, v_t)),
    'refusal', pg_temp.op(v_line) -> 'refusal',
    'suppression', private.transfer_debit_suppression(v_t, v_today, pg_temp.bd_after(2)),
    'book_t', pg_temp.attempt(format('select pg_temp.bkx(%L, %L)', v_line,
                                     jsonb_build_array(pg_temp.pt('payout', v_t, 182040)))),
    'book_client', pg_temp.attempt(format('select pg_temp.bkx(%L, %L)', v_line,
                                          jsonb_build_array(pg_temp.pt('unplanned_payout', null, 182040, pg_temp.c('a8'))))),
    'fee', pg_temp.attempt(format('select pg_temp.lk(%L, ''fee'')', v_line)));
  perform pg_temp.runs_check(pg_temp.bd_after(2));
  return v || jsonb_build_object('rows', pg_temp.breaches(pg_temp.v('run-e-lot-t')), 'dirty', pg_temp.dirty());
end $$;
create or replace function pg_temp.e_other() returns jsonb language sql as $$ select pg_temp.e_lot('other') $$;
create or replace function pg_temp.e_own() returns jsonb language sql as $$ select pg_temp.e_lot('own') $$;
create or replace function pg_temp.e_unknown() returns jsonb language sql as $$ select pg_temp.e_lot('unknown') $$;
create or replace function pg_temp.e_servicer() returns jsonb language sql as $$ select pg_temp.e_lot('servicer') $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('e_other'),
  '{"lots": [true, "booked", "in_file"], "line": ["E0", false, false], "refusal": "names_other_lot",
    "suppression": null, "book_t": "names_other_lot", "book_client": "names_other_lot", "fee": "payout_candidate",
    "rows": ["none"], "dirty": []}'::jsonb,
  'E (6b-2d, suppression-e0-names-our-other-lot; CPCE-08, OQ-83): a debit with a foreign end-to-end id and another lot''s '
  'TF PmtInfId of ours, of an in-flight payout''s amount to its payee''s IBAN, does not hold that payout''s breach row '
  'back (written once its date has passed) and is not booked as its debit, nor as a payout outside a run '
  '(names_other_lot); « Lier » keeps refusing its fee');
select is(pg_temp.isolated('e_own'),
  '{"lots": [true, "booked", "in_file"], "line": ["E0", true, true], "refusal": null, "suppression": "waiting",
    "book_t": "ok", "book_client": "payout_in_flight_matches", "fee": "payout_candidate", "rows": [], "dirty": []}'::jsonb,
  'E (6b-2d): the same debit naming that payout''s own lot by its PmtInfId is still proposed as its debit and still holds '
  'its breach row back');
select is(pg_temp.isolated('e_unknown'),
  '{"lots": [true, "booked", "in_file"], "line": ["E0", true, true], "refusal": null, "suppression": "waiting",
    "book_t": "ok", "book_client": "payout_in_flight_matches", "fee": "payout_candidate", "rows": [], "dirty": []}'::jsonb,
  'E (6b-2d): the same debit with a TF PmtInfId naming no lot of ours is still proposed as the payout''s debit and still '
  'holds its breach row back');
select is(pg_temp.isolated('e_servicer'),
  '{"lots": [true, "booked", "in_file"], "line": ["E0", true, true], "refusal": null, "suppression": "waiting",
    "book_t": "ok", "book_client": "payout_in_flight_matches", "fee": "payout_candidate", "rows": [], "dirty": []}'::jsonb,
  'E (6b-2d): and so is one whose TF PmtInfId names a lot of another servicer only (on its own account), never ours');

select is(pg_temp.dirty(), '{}'::text[], 'R, E: clean');
select is(private.switch_on('downloaded_file_cancellation'), false, 'and the switch is off (033 and 034 unchanged)');

select * from finish();
rollback;
