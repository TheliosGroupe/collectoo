-- M2c-6b-2b « the ops command » (plan docs/design/m2c-6b-2-plan.md §3, §8.1 037; ADR-0014 « M2c-6b-2b »). Ops book the
-- lines of our own transfers the debit job leaves to them, one line at a time, from what the database proposes
-- (public.book_transfer_line, public.transfer_line_options, public.transfer_line_preview):
--   A. roles, the request, the tenants (CSO-5, CSO2-10, CSO2-11), and the re-import of OQ-84 (j);
--   B. the line's state and the replay (CSO-12);
--   C. planned parts: S08 (E and the ISO shape on U), the fee rule (L2, F7, ML-6, ML-10), S09 lots, rule 3b (S12),
--      the late breach, the entry reason (CSO-1), parity with the job;
--   D. unplanned payouts (Q4): P per item (F2, F3, F4, also within one call), the draft requeued (CSO-6, CSO-7), F6,
--      ML-4, S13; since the review fixes (round 1) F5 and the queue shared within one call, ML-1's signed pool and its own
--      rows, a returned booking's attributions, ML-8, F13's payout not handed out, the bookings of one transfer bounded
--      by its amount (money-2);
--   E. sweeps (S14, S15) and the first download's sweep re-check end to end (CSO-2);
--   F. returns (S16, F1, ML-3, S20);
--   G. unplanned returns (S27, S28; F11, L4, ML-2, L3, ML-11);
--   H. unsplit entries (S21/S22; F8, F7, ML-5, CSO2-3; review money-1: an entry holding nothing of ours, our lot's
--      counts);
--   I. compare and set (CSO-12); K. the booking guard; L. alerts. (J, every read's tenant isolation beyond A's, and M,
--      the funds pass after an ops booking beyond G's and E's sweeps, are left: ADR-0014 « M2c-6b-2b ».)
-- The review fixes (round 1: ADR-0014 « M2c-6b-2b review fixes ») add, in their groups, the cases named « review … ».
-- run_payment_checks is asserted free of violations after each group (I8′, I12, I13, I14, I19, I20, bank_line_booked).
-- Cancellation after download stays off (033 and 034 unchanged): the scenarios that need a payout cancelled after its
-- file was handed out switch it on inside their own rolled-back subtransaction.
begin;
select plan(71);


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
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
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


-- A. Roles, the request, the tenants (plan §3.2, §3.4.0, §3.4.1; critic CSO-5; critic2 CSO2-10, CSO2-11) ----------------
create or replace function pg_temp.s03() returns jsonb language sql as $$
  select jsonb_build_array(pg_temp.pt('unplanned_payout', pg_temp.v('x1'), 164000)) $$;
select is(array[pg_temp.bkx(pg_temp.l2('b2', 1), pg_temp.s03(), 'key-r-02', '02'),
                pg_temp.bkx(pg_temp.l2('b2', 1), pg_temp.s03(), 'key-r-03', '03'),
                pg_temp.bkx(pg_temp.l2('b2', 1), pg_temp.s03(), 'key-r-05', '05'),
                pg_temp.bkx(pg_temp.l2('b2', 1), pg_temp.s03(), 'key-r-07', '07'),
                pg_temp.bkx(pg_temp.l2('b2', 1), pg_temp.s03(), 'key-r-04', '04', null, 'motif', 'aal1'),
                pg_temp.bkx('e6000000-0000-0000-0000-0000000000ff', pg_temp.s03(), 'key-r-00', '01')],
          array['not allowed', 'not allowed', 'not allowed', 'not allowed', 'not allowed', 'not allowed'],
  'A: a collector, a client admin, another servicer''s ops manager, a read-only member and an admin at aal1 are refused '
  '(42501), as is a line that does not exist');
select is(array[pg_temp.pv(pg_temp.l2('b2', 1), pg_temp.s03(), '02')::text,
                pg_temp.op(pg_temp.l2('b2', 1), '03')::text, pg_temp.op(pg_temp.l2('b2', 1), '05')::text,
                pg_temp.pv(pg_temp.l2('b2', 1), pg_temp.s03(), '04', 'aal1')::text],
          array[null, null, null, null]::text[],
  'A: the preview and the options are null for them');
select is(pg_temp.bkx(pg_temp.l2('b2', 1), pg_temp.s03(), 'r-reason', '01', null, '   '), 'a reason is required',
  'A: an empty motif → a reason is required');
select is(array[
    pg_temp.bkx(pg_temp.l2('b2', 1), '{"kind": "fee"}', 'key-br-01'),
    pg_temp.bkx(pg_temp.l2('b2', 1), '[]', 'key-br-02'),
    pg_temp.bkx(pg_temp.l2('b2', 1), (select jsonb_agg(pg_temp.pt('fee', null, 1)) from generate_series(1, 501)),
                'key-br-03'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('refund', pg_temp.v('x1'), 164000)), 'key-br-04'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', pg_temp.v('x1'), 0)), 'key-br-05'),
    pg_temp.bkx(pg_temp.l2('b2', 1), ('[{"kind": "unplanned_payout", "transfer_id": "' || pg_temp.v('x1')
                                      || '", "amount": "1640.00"}]')::jsonb, 'key-br-06'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('payout', null, 164000)), 'key-br-07'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', pg_temp.v('x1'), 164000,
                                                                  pg_temp.c('a1'))), 'key-br-08'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x1'), 164000, null,
                                                                  pg_temp.l2('b1', 1))), 'key-br-09'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('fee', null, 1), pg_temp.pt('fee', null, 2)), 'key-br-10'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x1'), 1),
                                                       pg_temp.pt('unplanned_payout', pg_temp.v('x1'), 1)), 'key-br-11'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', pg_temp.v('x1'), 164000) || '{"x": 1}'),
                'key-br-12'),
    pg_temp.bkx(pg_temp.l2('b2', 1), pg_temp.s03(), 'key-br-13', '01', '')],
  array_fill('bad_request'::text, array[13]),
  'A: bad_request — not an array, none, 501 parts, an unknown kind, a nil amount, an amount with decimals, a payout '
  'without its transfer, an unplanned payout with both a transfer and a client, a returned line on a payout, two fees, '
  'one transfer twice, an unknown key, an empty expected text');
select is(array[
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout',
                                                                  'b0000000-0000-0000-0000-0000000000b1', 164000)),
                'key-tn-01'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout',
                                                                  'b0000000-0000-0000-0000-00000000dead', 164000)),
                'key-tn-02'),
    pg_temp.why(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout',
                                                                  'b0000000-0000-0000-0000-0000000000b1', 164000))),
    pg_temp.why(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout',
                                                                  'b0000000-0000-0000-0000-00000000dead', 164000))),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 164000,
                                                                  pg_temp.c('b1'))), 'key-tn-03'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 164000,
                                                                  '00000000-0000-0000-0000-0000000000ee')), 'key-tn-04'),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout_returned', pg_temp.v('x1'), 164000,
                                                                  null, 'e6000000-0000-0000-0000-0000000000b2')),
                'key-tn-05')],
  array['transfer_unknown', 'transfer_unknown', 'transfer_unknown', 'transfer_unknown', 'client_unknown',
        'client_unknown', 'transfer_unknown'],
  'A (CSO-5): another servicer''s transfer, client and line are refused as an absent one is — transfer_unknown, '
  'client_unknown — in the command and the preview alike');
-- (review LT-6) the line's direction is read before its kind: a debit part on a credit line, or a return part on a
-- debit line → wrong_direction (the label of not_a_transfer_line would be false for our own payout's flagged return);
-- a part whose kind is not its transfer's (a sweep part naming one of our payouts) → transfer_kind_differs; a return
-- part on a credit that is not coming back → not_a_return
select pg_temp.stmt2('a2', private.paris_today(), jsonb_build_array(
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 419840, 'orig', pg_temp.e2e(pg_temp.v('x2'))),
  jsonb_build_object('dir', 'credit', 'kind', 'batch_unsplit', 'amount', 419840, 'pmt', 'LOT-ETRANGER-1')));
select is(array[
    pg_temp.why(pg_temp.l2('a2', 1), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'), 419840))),
    pg_temp.bkx(pg_temp.l2('a2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', pg_temp.v('x2'), 419840)),
                'key-wd-01'),
    pg_temp.why(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('x1'), 164000))),
    pg_temp.why(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('sweep', pg_temp.v('x1'), 164000))),
    pg_temp.bkx(pg_temp.l2('b2', 1), jsonb_build_array(pg_temp.pt('unplanned_sweep', pg_temp.v('x1'), 164000)),
                'key-wd-02'),
    pg_temp.why(pg_temp.l2('a2', 1), jsonb_build_array(pg_temp.pt('sweep_returned', pg_temp.v('x2'), 419840))),
    pg_temp.why(pg_temp.l2('a2', 2), jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('x2'), 419840)))],
  array['wrong_direction', 'wrong_direction', 'wrong_direction', 'transfer_kind_differs', 'transfer_kind_differs',
        'transfer_kind_differs', 'not_a_return'],
  'A (review LT-6): a debit part on our payout''s flagged return, or a return part on its debit → wrong_direction; a '
  'sweep part or a sweep''s return naming one of our payouts → transfer_kind_differs; a return part on a credit that '
  'is not coming back → not_a_return');
-- CSO2-10: an entry kept unsplit whose stored detail carries the other servicer's RMT id, and one carrying an RMT-shaped
-- id that names nothing: the same answers, nothing of BB in them
select pg_temp.stmt2('a1', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 164000, 'kind', 'batch_unsplit', 'unsplit', 1, 'count', 1,
                     'details', jsonb_build_array(jsonb_build_object('id', 'RMT00000000BB01', 'direction', 'debit',
                                                                     'amount_minor', '164000'))),
  jsonb_build_object('amount', 164000, 'kind', 'batch_unsplit', 'unsplit', 1, 'count', 1,
                     'details', jsonb_build_array(jsonb_build_object('id', 'RMT0000000000EE', 'direction', 'debit',
                                                                     'amount_minor', '164000')))));
select is(array[pg_temp.op(pg_temp.l2('a1', 1)) ->> 'refusal', pg_temp.op(pg_temp.l2('a1', 2)) ->> 'refusal',
                pg_temp.bkx(pg_temp.l2('a1', 1), jsonb_build_array(pg_temp.pt('payout',
                                                                  'b0000000-0000-0000-0000-0000000000b1', 164000)),
                            'key-cs-01'),
                (pg_temp.op(pg_temp.l2('a1', 1))::text like '%b0000000-0000-0000-0000-0000000000b1%')::text,
                (pg_temp.op(pg_temp.l2('a1', 1)) = pg_temp.op(pg_temp.l2('a1', 2)))::text],
          array['unsplit_not_bookable', 'unsplit_not_bookable', 'transfer_unknown', 'false', 'true'],
  'A (CSO2-10): a stored detail naming another servicer''s transfer and one naming nothing get the same answer '
  '(unsplit_not_bookable), nothing of the other servicer in the options, and its id is refused by the tenant filter');
select is(array[has_table_privilege('anon', 'private.unplanned_paid_item', 'select'),
                has_table_privilege('authenticated', 'private.unplanned_paid_item', 'select'),
                has_table_privilege('service_role', 'private.unplanned_paid_item', 'insert'),
                has_function_privilege('anon', 'public.book_transfer_line(text, uuid, jsonb, text, text)', 'execute'),
                has_function_privilege('authenticated', 'private.transfer_line_check(uuid, boolean)', 'execute'),
                has_function_privilege('authenticated', 'private.transfer_line_post(uuid, text)', 'execute'),
                has_function_privilege('service_role', 'private.remittance_draft_requeue(uuid)', 'execute'),
                has_function_privilege('authenticated', 'public.book_transfer_line(text, uuid, jsonb, text, text)',
                                       'execute'),
                has_function_privilege('authenticated', 'public.transfer_line_options(uuid)', 'execute')],
          array[false, false, false, false, false, false, false, true, true],
  'A (CSO2-11): private.unplanned_paid_item is out of reach of anon, authenticated and service_role; the internals are '
  'executable by none of them; the command and its reads by authenticated (checked inside)');
create or replace function pg_temp.a_insert_as_service() returns text language plpgsql as $$
begin
  set local role service_role;
  insert into private.unplanned_paid_item (booking_entry_id, ledger_entry_id, organization_id, client_organization_id,
                                           currency, amount_minor)
  values (gen_random_uuid(), gen_random_uuid(), '00000000-0000-0000-0000-0000000000aa',
          '00000000-0000-0000-0000-0000000000a1', 'EUR', 1);
  reset role;
  return 'inserted';
exception when others then
  reset role;
  return sqlerrm;
end $$;
select is(pg_temp.a_insert_as_service(), 'permission denied for table unplanned_paid_item',
  'A (CSO2-11): an insert into private.unplanned_paid_item as service_role is refused');

-- E. Sweeps (plan §3.4.5, §3.4.7, §3.4.8; critic CSO-2, F10, F13) ------------------------------------------------------
create or replace function pg_temp.e_sweeps() returns jsonb language plpgsql as $$
declare v_t uuid; v_s uuid; v jsonb;
begin
  v_t := pg_temp.inflight('a4', '04', 40000, 'e-sw');
  v_s := (pg_temp.sweep(pg_temp.v('file-e-sw'))).id;
  perform pg_temp.exec_on(pg_temp.v('file-e-sw'), private.paris_today() - 1);
  perform pg_temp.stmt2('e1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 10000, 'kind', 'transfer_out', 'iban', 'FR7610107001011234567890129'),
    jsonb_build_object('amount', pg_temp.amt(v_s), 'kind', 'transfer_out', 'iban', 'FR7610107001011234567890129'),
    jsonb_build_object('amount', 10000, 'kind', 'transfer_out', 'iban', 'FR8130004000039876543210134'),
    jsonb_build_object('amount', pg_temp.amt(v_s), 'e2e', pg_temp.e2e(v_s)),
    jsonb_build_object('amount', pg_temp.amt(v_s), 'e2e', pg_temp.e2e(v_s))));
  v := jsonb_build_object(
    'own', pg_temp.prop(pg_temp.l2('e1', 1)),
    'own_booked', pg_temp.bkx(pg_temp.l2('e1', 1), pg_temp.prop(pg_temp.l2('e1', 1))));
  v := v || jsonb_build_object('own_bank', (select la.bank_account_id from public.ledger_posting p join public.ledger_account la
                   on la.id = p.ledger_account_id
                 where p.entry_id = pg_temp.ek('sweep:line:' || pg_temp.l2('e1', 1) || ':1') and la.book = 'own_cash'));
  v := v || jsonb_build_object('in_flight', pg_temp.bkx(pg_temp.l2('e1', 2), jsonb_build_array(pg_temp.pt('unplanned_sweep', null,
                                                                               pg_temp.amt(v_s)))),
    'sweep_booked', pg_temp.bkx(pg_temp.l2('e1', 2), jsonb_build_array(pg_temp.pt('sweep', v_s, pg_temp.amt(v_s)))),
    'unknown_own', pg_temp.bkx(pg_temp.l2('e1', 3), jsonb_build_array(pg_temp.pt('unplanned_sweep', null, 10000))),
    -- S15: the sweep's SWP debit twice (the first now booked by rule 3b above)
    's15', pg_temp.prop(pg_temp.l2('e1', 4)) = jsonb_build_array(pg_temp.pt('unplanned_sweep', v_s,
                                                                            pg_temp.amt(v_s))),
    's15_booked', pg_temp.bkx(pg_temp.l2('e1', 4), pg_temp.prop(pg_temp.l2('e1', 4))),
    'dirty', pg_temp.dirty());
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('e_sweeps'),
  '{"own": [{"kind": "unplanned_sweep", "amount": "10000"}], "own_booked": "ok",
    "own_bank": "80000000-0000-0000-0000-0000000000c0", "in_flight": "sweep_in_flight_matches", "sweep_booked": "ok",
    "unknown_own": "own_account_unknown", "s15": true, "s15_booked": "ok", "dirty": []}'::jsonb,
  'E (S14, S15; F13): a debit to our own IBAN we did not order is an unplanned sweep to that account; one of a sweep '
  'in flight''s amount is refused sweep_in_flight_matches and booked as that sweep''s debit (rule 3b); an IBAN not ours '
  '→ own_account_unknown; the sweep''s second SWP debit is its unplanned sweep');
-- CSO-2 end to end: a generated file holding a sweep, then an advance-bearing unplanned payout (S03 of x1, booked in
-- the base) lowered the share: the preview said so, and the first download supersedes the file
create or replace function pg_temp.e_supersede() returns jsonb language plpgsql as $$
declare v_f uuid; v_d jsonb;
begin
  perform pg_temp.queued('a4', '04', 40000, 'e-sup');
  v_f := (pg_temp.gen('01', 'gen-e-sup') ->> 'file_id')::uuid;
  perform pg_temp.write(v_f);
  perform pg_temp.stmt2('e2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 10000, 'kind', 'other_debit', 'iban', pg_temp.iban('a3'))));
  v_d := pg_temp.pv(pg_temp.l2('e2', 1), pg_temp.prop(pg_temp.l2('e2', 1)));
  perform pg_temp.bk(pg_temp.l2('e2', 1), pg_temp.prop(pg_temp.l2('e2', 1)));
  return jsonb_build_object(
    'sweep_in_file', (pg_temp.sweep(v_f)).amount_minor > 0,
    'supersedes', v_d -> 'supersedes_file' ->> 'file_id' = v_f::text,
    'download', pg_temp.download('01', v_f) -> 'blocked' -> 0 ->> 'reason',
    'file', (pg_temp.fl(v_f)).status);
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('e_supersede'),
  '{"sweep_in_file": true, "supersedes": true, "download": "sweep_exceeds_share", "file": "superseded"}'::jsonb,
  'E (CSO-2, CSO2-4): an advance booked by ops after a file''s generation lowers the share under its sweep — the preview '
  'names the file, and its first download supersedes it (sweep_exceeds_share)');
-- (review TESTS-7) a sweep's two debits (planned, then unplanned: S15) and both copies coming back unflagged as own
-- credits carrying its SWP id: the first back is the unplanned sweep's return, the second the planned one's; their
-- books, keys, the sweep's status and the funds pass queued per call
create or replace function pg_temp.f_sweeps() returns jsonb language plpgsql as $$
declare v_t uuid; v_s uuid; v jsonb; a bigint; m bigint;
begin
  v_t := pg_temp.inflight('a4', '04', 40000, 'f-sw');
  v_s := (pg_temp.sweep(pg_temp.v('file-f-sw'))).id;
  a := pg_temp.amt(v_s);
  perform pg_temp.exec_on(pg_temp.v('file-f-sw'), private.paris_today() - 1);
  perform pg_temp.stmt2('ca1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', a, 'e2e', pg_temp.e2e(v_s)),
    jsonb_build_object('amount', a, 'e2e', pg_temp.e2e(v_s))));
  m := pg_temp.funds_msgs();
  v := jsonb_build_object('sweep', jsonb_build_array(pg_temp.prop(pg_temp.l2('ca1', 1)) -> 0 ->> 'kind',
                                                     pg_temp.bkx(pg_temp.l2('ca1', 1), pg_temp.prop(pg_temp.l2('ca1', 1))),
                                                     pg_temp.funds_msgs() - m));
  m := pg_temp.funds_msgs();
  v := v || jsonb_build_object('unplanned', jsonb_build_array(
                                 pg_temp.prop(pg_temp.l2('ca1', 2)) -> 0 ->> 'kind',
                                 pg_temp.bkx(pg_temp.l2('ca1', 2), pg_temp.prop(pg_temp.l2('ca1', 2))),
                                 pg_temp.funds_msgs() - m));
  perform pg_temp.stmt2('ca2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'own_transfer_in', 'amount', a, 'orig', pg_temp.e2e(v_s),
                       'iban', 'FR7610107001011234567890129'),
    jsonb_build_object('dir', 'credit', 'kind', 'own_transfer_in', 'amount', a, 'orig', pg_temp.e2e(v_s),
                       'iban', 'FR7610107001011234567890129')));
  m := pg_temp.funds_msgs();
  v := v || jsonb_build_object('first_back', jsonb_build_array(
                                 pg_temp.prop(pg_temp.l2('ca2', 1)) -> 0 ->> 'kind',
                                 pg_temp.bkx(pg_temp.l2('ca2', 1), pg_temp.prop(pg_temp.l2('ca2', 1))),
                                 pg_temp.funds_msgs() - m));
  m := pg_temp.funds_msgs();
  v := v || jsonb_build_object('second_back', jsonb_build_array(
                                 pg_temp.prop(pg_temp.l2('ca2', 2)) -> 0 ->> 'kind',
                                 pg_temp.bkx(pg_temp.l2('ca2', 2), pg_temp.prop(pg_temp.l2('ca2', 2))),
                                 pg_temp.funds_msgs() - m));
  return v || jsonb_build_object(
    'keys', jsonb_build_array(pg_temp.keys(pg_temp.l2('ca2', 1)), pg_temp.keys(pg_temp.l2('ca2', 2))),
    'books', (select jsonb_agg(pg_temp.books(k.entry_id) = jsonb_build_object('client_money_cash', a,
                                 'due_to_servicer', -a, 'due_from_client_funds', a, 'own_cash', -a)
                               order by k.bank_transaction_id)
              from public.bank_line_booking k where k.bank_transaction_id in (pg_temp.l2('ca2', 1), pg_temp.l2('ca2', 2))),
    's', pg_temp.status(v_s), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('f_sweeps'),
  '{"sweep": ["sweep", "ok", 1], "unplanned": ["unplanned_sweep", "ok", 1],
    "first_back": ["unplanned_sweep_returned", "ok", 1], "second_back": ["sweep_returned", "ok", 0],
    "keys": [["return:·:1"], ["return:·:·"]], "books": [true, true], "s": "returned", "dirty": []}'::jsonb,
  'E, F, G (review TESTS-7; CSO2-7): a sweep debited twice, both copies back as own credits carrying its SWP id — the first '
  'is the unplanned sweep''s return (return:<line>:1, the funds pass queued), the second the planned sweep''s '
  '(return:<line>:<t>, the sweep returned, no funds pass); each reverses +5120 / −4679 ‖ +4689 / −5122');


-- A (COMPLIANCE OQ-84 (j)): a re-import compares a stored value only against one the new file gives --------------------
create or replace function pg_temp.imp_id(p_n text) returns uuid language sql as $$
  select ('e5000000-0000-0000-0000-0000000000' || p_n)::uuid $$;
create or replace function pg_temp.imp2(p_n text, p_lines jsonb) returns text language plpgsql as $$
declare
  s uuid := pg_temp.imp_id(p_n);
  v_open bigint := pg_temp.cash() + (select u.minor from private.bank_unposted('80000000-0000-0000-0000-0000000000cf',
                                                                               'infinity'::date) u);
  v_moved bigint;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 'a.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into private.bank_import_stage (statement_id, line_no, section_no, dedup_key, direction, amount_minor, currency,
                                         booking_date, end_to_end_id, original_end_to_end_id, batch_entry_ref, entry_ref,
                                         kind, method, unsplit_ours, unsplit_details, unsplit_detail_count,
                                         unsplit_batch_count, charges_minor, charges_read, unsplit_direction_given)
  select s, l.ord, 1, 'e:' || (l.v ->> 'ref') || '#1', coalesce(l.v ->> 'dir', 'debit'), (l.v ->> 'amount')::bigint,
         'EUR', private.paris_today(), l.v ->> 'e2e', l.v ->> 'orig', case when l.v ? 'unsplit' then l.v ->> 'ref' end,
         l.v ->> 'ref', coalesce(l.v ->> 'kind', 'batch_unsplit'), 'sct', (l.v ->> 'unsplit')::smallint, l.v -> 'details',
         (l.v ->> 'count')::integer, (l.v ->> 'nb')::integer, (l.v ->> 'charges')::bigint, (l.v ->> 'read')::boolean,
         (select array_agg(g::boolean order by o) from jsonb_array_elements_text(l.v -> 'given') with ordinality g (g, o))
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  select coalesce(sum(case coalesce(l.v ->> 'dir', 'debit') when 'credit' then 1 else -1 end
                      * (l.v ->> 'amount')::bigint), 0)
  into v_moved from jsonb_array_elements(p_lines) l (v);
  return private.ingest_statement(s, jsonb_build_object('format', 'camt053', 'version', '08',
           'line_count', jsonb_array_length(p_lines), 'skipped_not_booked', 0,
           'sections', jsonb_build_array(jsonb_build_object('stmt_id', 'J' || p_n, 'seq', 1,
             'from_date', private.paris_today(), 'to_date', private.paris_today(), 'opening_minor', v_open::text,
             'closing_minor', (v_open + v_moved)::text)))) ->> 'new_lines';
end $$;
create or replace function pg_temp.j_again(p_lines jsonb) returns text language sql as $$
  select split_part(pg_temp.attempt(format('select pg_temp.imp2(%L, %L::jsonb)', '14', p_lines)), ':', 1) $$;
create or replace function pg_temp.j_nj2(p_dir text, p_amount text, p_given text) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('ref', 'NJ2', 'amount', 50000, 'unsplit', 1, 'count', 2, 'nb', 2,
    'given', jsonb_build_array(p_given),
    'details', jsonb_build_array(jsonb_build_object('id', 'RMT0000000000D2', 'direction', p_dir,
                                                    'amount_minor', p_amount)))) $$;
-- (review CSR-4) an entry kept unsplit of one detail of ours: its ref and id, the detail's direction, amount and flag
create or replace function pg_temp.j_nj(p_ref text, p_id text, p_dir text, p_amount text, p_given text)
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('ref', p_ref, 'amount', 50000, 'unsplit', 1, 'count', 2, 'nb', 2,
    'given', jsonb_build_array(p_given),
    'details', jsonb_build_array(jsonb_build_object('id', p_id, 'direction', p_dir, 'amount_minor', p_amount)))) $$;
create or replace function pg_temp.j_reimport() returns jsonb language plpgsql as $$
begin
  perform pg_temp.imp2('12', '[{"ref": "NJ1", "kind": "transfer_out", "e2e": "RMT0000000000D1", "amount": 32920,
                                "charges": 120, "read": true},
                               {"ref": "NJ3", "kind": "transfer_out", "e2e": "RMT0000000000D3", "amount": 32800,
                                "read": true},
                               {"ref": "NJ8", "kind": "transfer_out", "e2e": "RMT0000000000D8", "amount": 32920,
                                "read": false}]'::jsonb || pg_temp.j_nj2('debit', '20000', 'true')
                       || pg_temp.j_nj('NJ5', 'RMT0000000000D5', 'debit', '20000', 'false')
                       || pg_temp.j_nj('NJ7', 'RMT0000000000D7', 'debit', null, 'true'));
  return jsonb_build_object(
    -- (review CSR-4) a value the new file gives is compared with the stored one, even when the stored one was not given:
    -- a direction the stored file left to the entry's, an amount it did not give, charges it did not read
    'given_now', pg_temp.j_again(pg_temp.j_nj('NJ5', 'RMT0000000000D5', 'credit', '20000', 'true')),
    'given_now_same', pg_temp.j_again(pg_temp.j_nj('NJ5', 'RMT0000000000D5', 'debit', '20000', 'true')),
    'amount_now', pg_temp.j_again(pg_temp.j_nj('NJ7', 'RMT0000000000D7', 'debit', '29000', 'true')),
    'read_now', pg_temp.j_again('[{"ref": "NJ8", "kind": "transfer_out", "e2e": "RMT0000000000D8", "amount": 32920,
                                   "charges": 120, "read": true}]'),
    'stored_unread', (select jsonb_build_array(t.charges_minor, t.charges_read) from public.bank_transaction t
                      where t.dedup_key = 'e:NJ8#1'),
    -- v08 stored, v02 again: its charges block is never read, its details give no CdtDbtInd
    'v02_charges', pg_temp.j_again('[{"ref": "NJ1", "kind": "transfer_out", "e2e": "RMT0000000000D1", "amount": 32920,
                                      "read": false}]'),
    'v02_details', pg_temp.j_again(pg_temp.j_nj2('credit', '20000', 'false')),
    'no_amount', pg_temp.j_again(pg_temp.j_nj2('debit', null, 'true')),
    -- what both files give is still compared
    'direction', pg_temp.j_again(pg_temp.j_nj2('credit', '20000', 'true')),
    'amount', pg_temp.j_again(pg_temp.j_nj2('debit', '20001', 'false')),
    'charges', pg_temp.j_again('[{"ref": "NJ1", "kind": "transfer_out", "e2e": "RMT0000000000D1", "amount": 32920,
                                  "charges": 130, "read": true}]'),
    'read_none', pg_temp.j_again('[{"ref": "NJ3", "kind": "transfer_out", "e2e": "RMT0000000000D3", "amount": 32800,
                                    "charges": 120, "read": true}]'),
    'bad_flag', pg_temp.j_again('[{"ref": "NJ9", "kind": "transfer_out", "e2e": "RMT0000000000D9", "amount": 100,
                                   "charges": 1, "read": false}]'),
    'stored', (select jsonb_build_array(t.charges_minor, t.charges_read, t.unsplit_direction_given)
               from public.bank_transaction t where t.dedup_key = 'e:NJ1#1'));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('j_reimport'),
  '{"v02_charges": "0", "v02_details": "0", "no_amount": "0", "direction": "entry_detail_differs",
    "amount": "entry_detail_differs", "charges": "entry_detail_differs", "read_none": "entry_detail_differs",
    "bad_flag": "line_invalid", "stored": [120, true, null], "given_now": "entry_detail_differs",
    "given_now_same": "0", "amount_now": "entry_detail_differs", "read_now": "entry_detail_differs",
    "stored_unread": [null, false]}'::jsonb,
  'A (OQ-84 (j); review CSR-4): a re-import compares a stored value with every value the new file gives — v02 charges '
  'never read, details without CdtDbtInd or without an amount are skipped; a direction, an amount or a charge the new '
  'file gives refuses entry_detail_differs when it differs from the stored one, whether or not the stored file gave it '
  '(a direction left to the entry''s, no amount, charges not read); a charge beside « not read » is line_invalid');


-- B. The line's state and the replay (plan §3.4.2, §3.9; critic CSO-12, F16) --------------------------------------------
create or replace function pg_temp.b_state() returns jsonb language plpgsql as $$
begin
  -- a held duplicate, a line the job booked, a line linked (explained), a payment's line
  perform pg_temp.stmt2('b3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'kind', 'suspected_duplicate', 'e2e', pg_temp.e2e(pg_temp.v('x1'))),
    jsonb_build_object('amount', 1000, 'kind', 'other_debit', 'iban', 'FR7630004000031234567890143')));
  perform pg_temp.link('key-ex-b3-2', pg_temp.l2('b3', 2), 'explained', null, null, null);
  return jsonb_build_object(
    'held', pg_temp.bkx(pg_temp.l2('b3', 1), pg_temp.s03()),
    'booked', pg_temp.bkx(pg_temp.l2('b1', 1), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x1'), 164000))),
    'linked', pg_temp.bkx(pg_temp.l2('b3', 2), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 1000,
                                                                          pg_temp.c('a1')))),
    'payment', pg_temp.bkx('e1000000-0000-0000-0000-000000000001'::uuid,
                           jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('x1'), 200000))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('b_state'),
  '{"held": "held_duplicate", "booked": "already_booked", "linked": "already_linked", "payment": "line_is_payment"}',
  'B: a held duplicate, a line already booked (by the job), a line explained, a payment''s line are refused');
-- S03 booked by ops (P = 0): the options propose it, the command books it; the same key and request replays
select is(pg_temp.prop(pg_temp.l2('b2', 1)), pg_temp.s03(), 'B: the options propose S03 as x1''s unplanned payout');
insert into j select 'b2', pg_temp.bk(pg_temp.l2('b2', 1), pg_temp.s03(), 'bk-s03-0001');
select is(array[(j.v -> 'bookings' -> 0 ->> 'kind'), (j.v -> 'bookings' -> 0 ->> 'paid_minor'),
                (j.v -> 'bookings' -> 0 ->> 'advance_minor'), (j.v ->> 'funds_pass_queued')],
          array['unplanned_payout', '0', '164000', 'true'],
  'B: booked — x1''s unplanned payout, P = 0, an advance of 164 000, the funds pass queued')
from j where j.k = 'b2';
select is(array[pg_temp.bk(pg_temp.l2('b2', 1), pg_temp.s03(), 'bk-s03-0001', '01',
                           (select v ->> 'expected_text' from j where k = 'b2')) = (select v from j where k = 'b2'),
                (select count(*) from public.ledger_entry where idempotency_key like 'remit:line:' || pg_temp.l2('b2', 1)
                   || ':%') = 1],
          array[true, true],
  'B (CSO-12): the same key and request return the first result, nothing posted twice');
select is(array[pg_temp.bkx(pg_temp.l2('b2', 1), pg_temp.s03(), 'bk-s03-0001', '01', 'another text'),
                pg_temp.bkx(pg_temp.l2('b2', 1), pg_temp.s03(), 'bk-s03-0002')],
          array['idempotency key bk-s03-0001 was used for a different request', 'already_booked'],
  'B: the same key with another request gets command_replay''s refusal; a new key on the booked line already_booked');
-- (review LT-4, critic2 ML-9) the bound that set P comes back with the booking and stays on its advance
select is(array[(select v -> 'bookings' -> 0 ->> 'p_bound' from j where k = 'b2'),
                (select to_jsonb(a) ->> 'p_bound' from public.client_advance a
                 where a.bank_transaction_id = pg_temp.l2('b2', 1))],
          array['none', 'none'],
  'B (review LT-4): the booking result carries each unplanned part''s p_bound (none: S03 has no items), and its '
  'double_payout advance keeps it');
-- (review CSR-2) the idempotency key's lock is in a namespace of its own: a key whose hash is another servicer's
-- `payments:` lock (found offline: hashtext('cmd:book_transfer_line:probe-c18d78c9a') = hashtext('payments:' || bb))
-- never takes that servicer's allocation lock
create or replace function pg_temp.b_key_ns() returns jsonb language plpgsql as $$
begin
  perform pg_temp.stmt2('b5', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 5000, 'kind', 'other_debit', 'iban', pg_temp.iban('a3'))));
  return jsonb_build_object(
    'collides', hashtext('cmd:book_transfer_line:probe-c18d78c9a')
                = hashtext('payments:00000000-0000-0000-0000-0000000000bb'),
    'booked', pg_temp.bkx(pg_temp.l2('b5', 1), pg_temp.prop(pg_temp.l2('b5', 1)), 'probe-c18d78c9a'),
    'holds_bb', pg_temp.holds_advisory(hashtext('payments:00000000-0000-0000-0000-0000000000bb')),
    'holds_aa', pg_temp.holds_advisory(hashtext('payments:00000000-0000-0000-0000-0000000000aa')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('b_key_ns'), '{"collides": true, "booked": "ok", "holds_bb": false, "holds_aa": true}'::jsonb,
  'B (review CSR-2): a key whose hash is another servicer''s allocation lock books without taking that lock (the key '
  'lock is a two-key advisory lock of its own class); the servicer''s own allocation lock is held');
-- CSO2-12: S03's rows are what 036 B's seed helper posts (the remittance and the advance, the −A pending row and the
-- advance's +A, the cause)
select is(pg_temp.unplanned_rows(pg_temp.l2('b2', 1)),
  jsonb_build_object('entries', jsonb_build_array('client_advance:adv:line:·:1', 'remittance:remit:line:·:1'),
                     'pending', jsonb_build_array('client_advance:164000', 'unplanned_payout:-164000'),
                     'advance', jsonb_build_array('double_payout:164000')),
  'B, D (CSO2-12): S03''s rows — remit:line:<line>:1 and adv:line:<line>:1, the −A pending row and the advance''s +A, '
  'the advance double_payout — are 036 B''s seed helper''s');
select is(array[pg_temp.queued_minor('a1'), pg_temp.owed('a1')], array[0::bigint, 0::bigint],
  'D: S03 (P = 0): Martin''s queue nets to 0, its 4670 at 0');
-- (critic F16) a client part on our refund's RFD debit is not a transfer line of this command
create or replace function pg_temp.b_refund_out() returns jsonb language plpgsql as $$
begin
  perform pg_temp.stmt2('b4', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 5000, 'kind', 'refund_out', 'iban', pg_temp.iban('a3'))));
  return to_jsonb(pg_temp.bkx(pg_temp.l2('b4', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 5000,
                                                                                pg_temp.c('a3')))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('b_refund_out') #>> '{}', 'not_a_transfer_line',
  'B (F16): a client part on a refund_out line → not_a_transfer_line');
select is(pg_temp.dirty(), '{}'::text[], 'A, B: clean (I8′, I12, I13, I14, I19, I20, bank_line_booked)');


-- C. Planned parts (plan §3.4.3–§3.4.5, §3.4.10, §3.5; critic L2, F7, F9, F12, CSO-1; critic2 ML-4, ML-6, ML-8, ML-10) ---
-- S08: Lambert's payout t4 (32 800) debited with the bank's 1,20 € on its own line (no charge recorded)
create or replace function pg_temp.c_s08() returns jsonb language plpgsql as $$
declare v_t uuid := pg_temp.inflight('a4', '04', 40000, 'c-s08'); v jsonb;
begin
  perform pg_temp.stmt2('c1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32920, 'e2e', pg_temp.e2e(v_t)),
    jsonb_build_object('amount', 32920, 'e2e', pg_temp.e2e(v_t), 'charges', 100),
    jsonb_build_object('amount', 32700, 'e2e', pg_temp.e2e(v_t)),
    jsonb_build_object('amount', 65600, 'e2e', pg_temp.e2e(v_t)),
    jsonb_build_object('amount', 196800, 'e2e', pg_temp.e2e(v_t))));
  v := jsonb_build_object(
    'proposed', (select jsonb_agg(p - 'transfer_id') from jsonb_array_elements(pg_temp.prop(pg_temp.l2('c1', 1))) p),
    'unexplained_proposal', pg_temp.op(pg_temp.l2('c1', 4)) -> 'refusal',
    'no_fee', pg_temp.bkx(pg_temp.l2('c1', 1), jsonb_build_array(pg_temp.pt('payout', v_t, 32920))),
    'short', pg_temp.bkx(pg_temp.l2('c1', 3), jsonb_build_array(pg_temp.pt('payout', v_t, 32700))),
    'charges_differ', pg_temp.bkx(pg_temp.l2('c1', 2), jsonb_build_array(pg_temp.pt('payout', v_t, 32800),
                                                                          pg_temp.pt('fee', null, 120))),
    'twice', pg_temp.bkx(pg_temp.l2('c1', 4), jsonb_build_array(pg_temp.pt('payout', v_t, 32800),
                                                                 pg_temp.pt('fee', null, 32800))),
    'another_payout', pg_temp.bkx(pg_temp.l2('c1', 5), jsonb_build_array(pg_temp.pt('payout', v_t, 32800),
                                                                          pg_temp.pt('fee', null, 164000))),
    'booked', pg_temp.bkx(pg_temp.l2('c1', 1), pg_temp.prop(pg_temp.l2('c1', 1))));
  return v || jsonb_build_object(
    'bookings', pg_temp.bookings(pg_temp.l2('c1', 1)), 'keys', pg_temp.keys(pg_temp.l2('c1', 1)),
    'run', (select status from public.remittance_run where id = pg_temp.v('run-c-s08')),
    'transfer', pg_temp.status(v_t), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_s08'),
  '{"proposed": [{"kind": "payout", "amount": "32800"}, {"kind": "fee", "amount": "120"}],
    "unexplained_proposal": "fee_unexplained", "no_fee": "amount_differs", "short": "amount_differs",
    "charges_differ": "amount_differs", "twice": "fee_unexplained", "another_payout": "fee_unexplained", "booked": "ok",
    "bookings": ["1 payout 32800", "2 fee 120"], "keys": ["remit:·", "fee:·"], "run": "booked", "transfer": "booked",
    "dirty": []}'::jsonb,
  'C (S08, ML-10): a payout debited with the bank''s charge on its own line is proposed and booked as payout + fee '
  '(remit:<t>, fee:<line>, seqs 1–2, run and transfer booked); without the fee part, or short of the payout → '
  'amount_differs; a fee other than the statement''s recorded charge → amount_differs; with none recorded, a « fee » of '
  'the amount of one of our filed transfers (the payout itself, or another payout) → fee_unexplained, and no proposal');

-- (ML-6, CSO2-1) S08 in the ISO shape: an entry kept unsplit holding our one detail at N, the entry N + F, F in Chrgs
create or replace function pg_temp.c_iso() returns jsonb language plpgsql as $$
declare v_t uuid := pg_temp.inflight('a4', '04', 40000, 'c-iso'); d jsonb;
begin
  d := jsonb_build_array(jsonb_build_object('id', pg_temp.e2e(v_t), 'direction', 'debit', 'amount_minor', '32800'));
  perform pg_temp.stmt2('c2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32920, 'kind', 'batch_unsplit', 'unsplit', 1, 'count', 1, 'details', d,
                       'charges', 120),
    jsonb_build_object('amount', 32920, 'kind', 'batch_unsplit', 'unsplit', 1, 'count', 1, 'details', d),
    jsonb_build_object('amount', 32920, 'kind', 'batch_unsplit', 'unsplit', 1, 'count', 1, 'details', d,
                       'charges', 100)));
  return jsonb_build_object(
    'no_charges', pg_temp.bkx(pg_temp.l2('c2', 2), jsonb_build_array(pg_temp.pt('payout', v_t, 32800),
                                                                     pg_temp.pt('fee', null, 120))),
    'other_charges', pg_temp.bkx(pg_temp.l2('c2', 3), jsonb_build_array(pg_temp.pt('payout', v_t, 32800),
                                                                        pg_temp.pt('fee', null, 120))),
    'proposed', (select jsonb_agg(p - 'transfer_id') from jsonb_array_elements(pg_temp.prop(pg_temp.l2('c2', 1))) p),
    'booked', pg_temp.bkx(pg_temp.l2('c2', 1), pg_temp.prop(pg_temp.l2('c2', 1))),
    'bookings', pg_temp.bookings(pg_temp.l2('c2', 1)), 'transfer', pg_temp.status(v_t));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_iso'),
  '{"no_charges": "unsplit_detail_missing", "other_charges": "amount_differs",
    "proposed": [{"kind": "payout", "amount": "32800"}, {"kind": "fee", "amount": "120"}], "booked": "ok",
    "bookings": ["1 payout 32800", "2 fee 120"], "transfer": "booked"}'::jsonb,
  'C (ML-6, CSO2-1): S08 in the ISO shape (one detail of ours at N, the entry N + F, Chrgs F) is proposed and booked as '
  'payout + fee; with no charge recorded → unsplit_detail_missing; with another one → amount_differs');
-- (L2, F7) a fee only on our transfer's own line: refused on a lot, a line without our reference, an entry of two
-- details, a client's credit; the critics' scenarios
create or replace function pg_temp.c_fee_not_allowed() returns jsonb language plpgsql as $$
declare v_t uuid := pg_temp.inflight('a4', '04', 40000, 'c-fna');
begin
  perform pg_temp.stmt2('c3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32920, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_t)),
    jsonb_build_object('amount', 32920, 'kind', 'other_debit', 'iban', pg_temp.iban('a4')),
    jsonb_build_object('amount', 1640, 'kind', 'other_debit', 'iban', pg_temp.iban('a3')),
    jsonb_build_object('dir', 'credit', 'kind', 'client_transfer_in', 'amount', 5000, 'iban', pg_temp.iban('a1'),
                       'orig', pg_temp.e2e(pg_temp.v('x1')))));
  return jsonb_build_object(
    'lot', pg_temp.bkx(pg_temp.l2('c3', 1), jsonb_build_array(pg_temp.pt('payout', v_t, 32800),
                                                              pg_temp.pt('fee', null, 120))),
    'no_reference', pg_temp.bkx(pg_temp.l2('c3', 2), jsonb_build_array(pg_temp.pt('payout', v_t, 32800),
                                                                       pg_temp.pt('fee', null, 120))),
    -- (F15) a client part and a fee: two parts without a transfer, refused by the parse
    'client_part', pg_temp.bkx(pg_temp.l2('c3', 3), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 40,
                                                                                 pg_temp.c('a3')),
                                                                      pg_temp.pt('fee', null, 1600))),
    'client_credit', pg_temp.bkx(pg_temp.l2('c3', 4), jsonb_build_array(pg_temp.pt('payout_returned',
                                                                                   pg_temp.v('x1'), 164000),
                                                                        pg_temp.pt('fee', null, 159000))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_fee_not_allowed'),
  '{"lot": "fee_not_allowed", "no_reference": "fee_not_allowed", "client_part": "bad_request",
    "client_credit": "fee_not_allowed"}'::jsonb,
  'C (L2, F7, F15): a fee is refused on our lot, on a line without our reference and on a client''s credit (a return of '
  '1 640 less 1 590) — fee_not_allowed; beside a client part (40 + 1 600) the parse refuses two parts without a transfer '
  '(bad_request, §3.4.0)');
-- S09: a lot of three payouts debited short of one; equal amounts; a member of another PmtInf
create or replace function pg_temp.c_lot() returns jsonb language plpgsql as $$
declare v_5 uuid; v_6 uuid; v_7 uuid; v_9 uuid; v_f uuid; v jsonb;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 'c-l5');   -- 24 600
  v_6 := pg_temp.queued('a6', '06', 100000, 'c-l6');  -- 82 000
  v_7 := pg_temp.queued('a7', '07', 50000, 'c-l7');   -- 41 000
  v_9 := pg_temp.queued('a9', '09', 30000, 'c-l9');   -- 24 600
  v_f := pg_temp.handed_out('fl', 'gen-c-lot');
  perform pg_temp.stmt2('c4', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 131200, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5)),
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  v := jsonb_build_object(
    'ambiguous', pg_temp.op(pg_temp.l2('c4', 2)) ->> 'refusal',
    'ambiguous_cmd', pg_temp.bkx(pg_temp.l2('c4', 2), jsonb_build_array(pg_temp.pt('payout', v_5, 24600),
                                                                         pg_temp.pt('payout', v_6, 82000))),
    'other_pmtinf', pg_temp.bkx(pg_temp.l2('c4', 1), jsonb_build_array(pg_temp.pt('payout', v_5, 24600),
                                                                       pg_temp.pt('payout', v_6, 82000),
                                                                       pg_temp.pt('payout', pg_temp.v('x2'), 41000))),
    'members', jsonb_array_length(pg_temp.op(pg_temp.l2('c4', 1)) -> 'members'),
    'proposed', (select jsonb_agg(p ->> 'kind' || ':' || (p ->> 'amount') order by p ->> 'amount')
                 from jsonb_array_elements(pg_temp.prop(pg_temp.l2('c4', 1))) p),
    'booked', pg_temp.bkx(pg_temp.l2('c4', 1), pg_temp.prop(pg_temp.l2('c4', 1))));
  return v || jsonb_build_object('left_out', jsonb_build_array(pg_temp.status(v_7),
                                  (select status from public.remittance_run where id = pg_temp.v('run-c-l7'))),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_lot'),
  '{"ambiguous": "batch_ambiguous", "ambiguous_cmd": "batch_ambiguous", "other_pmtinf": "not_its_line", "members": 4,
    "proposed": ["payout:24600", "payout:24600", "payout:82000"], "booked": "ok",
    "left_out": ["in_file", "sent"], "dirty": []}'::jsonb,
  'C (S09, §3.5): a lot of four payouts debited short of one is proposed and booked as the only subset making it (the '
  'member left out stays in its file, its run sent); a line two subsets make (two members of equal amount) → '
  'batch_ambiguous in the options and the command; a member of another PmtInf → not_its_line');
-- (review CSR-3) the options search the lot's only subset once: their own pre-read serves the preview of the proposal
-- (private.transfer_line_preview_of without its pre-read); the preview alone searches once. The searches counted by a
-- counting private.unique_subset, redefined inside the rolled-back scenario (the same subset)
create or replace function pg_temp.c_one_search() returns jsonb language plpgsql as $$
declare v_5 uuid; v_6 uuid; v_9 uuid; v jsonb; n_options bigint;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 'c-l5');   -- 24 600
  v_6 := pg_temp.queued('a6', '06', 100000, 'c-l6');  -- 82 000
  perform pg_temp.queued('a7', '07', 50000, 'c-l7');  -- 41 000
  v_9 := pg_temp.queued('a9', '09', 30000, 'c-l9');   -- 24 600
  perform pg_temp.handed_out('fl', 'gen-c-lot');
  perform pg_temp.stmt2('c4', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 131200, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  create temp sequence _subset_searches;
  create or replace function private.unique_subset(p_amounts bigint[], p_target bigint) returns integer[]
  language plpgsql set search_path = '' as $f$
  begin
    perform nextval('pg_temp._subset_searches');
    return (select x.indexes from private.unique_subset_trace(p_amounts, p_target) x);
  end $f$;
  v := pg_temp.op(pg_temp.l2('c4', 1));
  select case when is_called then last_value else 0 end into n_options from pg_temp._subset_searches;
  perform pg_temp.pv(pg_temp.l2('c4', 1), v -> 'proposals' -> 0 -> 'request');
  return jsonb_build_object(
    'proposed', (select jsonb_agg(p ->> 'kind' || ':' || (p ->> 'amount') order by p ->> 'amount')
                 from jsonb_array_elements(v -> 'proposals' -> 0 -> 'request') p),
    'preview_ok', v -> 'proposals' -> 0 -> 'preview' ->> 'ok',
    'options_searches', n_options,
    'preview_searches', (select case when is_called then last_value else 0 end from pg_temp._subset_searches)
                        - n_options);
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_one_search'),
  '{"proposed": ["payout:24600", "payout:24600", "payout:82000"], "preview_ok": "true", "options_searches": 1,
    "preview_searches": 1}'::jsonb,
  'C (review CSR-3): the options of a lot line search its only subset once — the preview of their proposal reuses '
  'their own pre-read — and the preview alone searches once');

-- S12, rule 3b (F9, F12, L12; ML-4): a debit without our reference of x2's amount to Lilas' IBAN, x2 in flight
create or replace function pg_temp.c_rule3b() returns jsonb language plpgsql as $$
declare v_exec date := (select i.execution_date from public.transfer_file_item i
                        where i.transfer_id = pg_temp.v('x2'));
  v jsonb;
begin
  perform pg_temp.stmt2('c5', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'kind', 'other_debit', 'iban', pg_temp.iban('a2')),
    jsonb_build_object('amount', 419840, 'kind', 'other_debit', 'iban', 'FR8130004000039876543210134'),
    jsonb_build_object('amount', 419840, 'kind', 'other_debit', 'e2e', 'BANK-REF-0001', 'iban', pg_temp.iban('a2')),
    jsonb_build_object('amount', 419840, 'kind', 'other_debit', 'e2e', 'BANK-REF-0002')));
  -- x2 executed tomorrow: today's line is dated before its execution
  perform pg_temp.exec_on(pg_temp.v('fa'), private.paris_today() + 1);
  v := jsonb_build_object('before_execution', pg_temp.bkx(pg_temp.l2('c5', 1),
                                                          jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'),
                                                                                       419840))));
  perform pg_temp.exec_on(pg_temp.v('fa'), private.paris_today() - 1);
  v := v || jsonb_build_object(
    'other_iban', pg_temp.bkx(pg_temp.l2('c5', 2), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'), 419840))),
    'other_iban_options', pg_temp.op(pg_temp.l2('c5', 2)) -> 'proposals',
    'class_o_no_iban', pg_temp.bkx(pg_temp.l2('c5', 4), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'),
                                                                                     419840))),
    'class_n', pg_temp.op(pg_temp.l2('c5', 1)) ->> 'class', 'class_o', pg_temp.op(pg_temp.l2('c5', 3)) ->> 'class',
    'proposed', pg_temp.prop(pg_temp.l2('c5', 3)) = jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'), 419840)),
    -- (F13) the client part is refused while a transfer of ours may be this debit
    'client_part', pg_temp.bkx(pg_temp.l2('c5', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 419840,
                                                                                 pg_temp.c('a2')))),
    'booked_o', pg_temp.bkx(pg_temp.l2('c5', 3), pg_temp.prop(pg_temp.l2('c5', 3))));
  return v || jsonb_build_object('x2', pg_temp.status(pg_temp.v('x2')),
                                 'run', (select status from public.remittance_run where id = pg_temp.v('r2')),
                                 'breach_rows', (select count(*) from public.remittance_deadline_breach
                                                 where run_id = pg_temp.v('r2')),
                                 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_rule3b'),
  '{"other_iban": "not_its_line", "other_iban_options": [], "before_execution": "not_its_line",
    "class_o_no_iban": "not_its_line", "class_n": "N", "class_o": "O", "proposed": true,
    "client_part": "payout_in_flight_matches", "booked_o": "ok", "x2": "booked", "run": "booked", "breach_rows": 0,
    "dirty": []}'::jsonb,
  'C (S12, rule 3b; F13, L12, Q16): a debit without our reference of x2''s amount, to Lilas'' IBAN, is x2''s debit when '
  'x2 is the only candidate — class O (a bank''s own id) booked as payout(x2), on time: no breach row; to another IBAN, '
  'dated before x2''s execution, or class O without an IBAN: not_its_line and no proposal; the client part is refused '
  'payout_in_flight_matches');
-- (rule 3b's uniqueness) a CSV line without the IBAN column of an amount two payouts in flight have: line_ambiguous
create or replace function pg_temp.c_ambiguous() returns jsonb language plpgsql as $$
declare v_5 uuid; v_9 uuid;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 'c-a5');
  v_9 := pg_temp.queued('a9', '09', 30000, 'c-a9');
  perform pg_temp.handed_out('fm', 'gen-c-amb');
  perform pg_temp.exec_on(pg_temp.v('fm'), private.paris_today() - 1);
  perform pg_temp.stmt2('c7', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 24600, 'kind', 'other_debit'),
    jsonb_build_object('amount', 24600, 'kind', 'other_debit', 'iban', pg_temp.iban('a9'))));
  return jsonb_build_object(
    'options', pg_temp.op(pg_temp.l2('c7', 1)) ->> 'refusal',
    'command', pg_temp.bkx(pg_temp.l2('c7', 1), jsonb_build_array(pg_temp.pt('payout', v_5, 24600))),
    'with_iban', pg_temp.bkx(pg_temp.l2('c7', 2), pg_temp.prop(pg_temp.l2('c7', 2))),
    'a9', pg_temp.status(v_9), 'a5', pg_temp.status(v_5));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_ambiguous'),
  '{"options": "line_ambiguous", "command": "line_ambiguous", "with_iban": "ok", "a9": "booked", "a5": "in_file"}'::jsonb,
  'C (rule 3b): a line without our reference nor IBAN two payouts in flight may be → line_ambiguous (options and '
  'command); with the IBAN, the one candidate is booked');
-- a late ops payout writes its breach rows (its lines' latest execution date before the debit); the status rules
create or replace function pg_temp.c_late_and_status() returns jsonb language plpgsql as $$
declare v_t uuid; v_o uuid; v jsonb;
begin
  -- the run approved on time (its header's earliest date later than its line's), its line already late at its debit
  insert into dated values (pg_temp.f('04'), private.paris_today() - 1);
  insert into earliest_hdr values ('a4', private.paris_today() + 10);
  v_t := pg_temp.inflight('a4', '04', 40000, 'c-late');
  v_o := pg_temp.queued('a6', '06', 100000, 'c-ord');   -- approved, its payout ordered (no file)
  perform pg_temp.stmt2('c8', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(v_t)),
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_o)),
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1')))));
  -- a second dedicated account of the servicer: a line there carrying x2's id
  insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on) values
    ('80000000-0000-0000-0000-0000000000cd', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
     'FR0630004000039876543210999', 'TESTFRPPXXX', 'EUR', 'Fonds de tiers 2', 'camt053', '2026-01-01');
  perform pg_temp.stmt2('c9', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('x2')))),
    '80000000-0000-0000-0000-0000000000cd');
  v := jsonb_build_object(
    'late', (pg_temp.pv(pg_temp.l2('c8', 1), pg_temp.prop(pg_temp.l2('c8', 1))) -> 'parts' -> 0 ->> 'late'),
    'booked', pg_temp.bkx(pg_temp.l2('c8', 1), pg_temp.prop(pg_temp.l2('c8', 1))));
  v := v || jsonb_build_object('breach_rows', (select count(*) from public.remittance_deadline_breach
                                               where run_id = pg_temp.v('run-c-late')));
  return v || jsonb_build_object(
    'already_debited', pg_temp.bkx(pg_temp.l2('c8', 3), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x1'),
                                                                                     164000)), 'key-st-1'),
    'not_handed_out', pg_temp.bkx(pg_temp.l2('c8', 2), jsonb_build_array(pg_temp.pt('payout', v_o, 82000))),
    'transfer_differs', pg_temp.bkx(pg_temp.l2('c9', 1), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'),
                                                                                      419840))),
    'not_cancelled', pg_temp.bkx(pg_temp.l2('c8', 2), jsonb_build_array(pg_temp.pt('unplanned_payout', v_o, 82000))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_late_and_status'),
  '{"late": "true", "booked": "ok", "breach_rows": 1, "already_debited": "already_debited",
    "not_handed_out": "not_handed_out", "transfer_differs": "transfer_differs",
    "not_cancelled": "not_cancelled_nor_booked"}'::jsonb,
  'C: a late ops payout is flagged late and writes its breach row; a debited payout → already_debited; one never handed '
  'out → not_handed_out; a line of another account → transfer_differs; an unplanned payout of an ordered payout → '
  'not_cancelled_nor_booked');
-- (CSO-1) the remittance entry of an ops payout keeps the job's reason (none), read by the client's whole-client
-- member; the motif only on the booking (staff); and the job's posting of a twin line gives the same entries
create or replace function pg_temp.c_reason_parity() returns jsonb language plpgsql as $$
declare v_t uuid; v_u uuid; v_ops text[]; v_job text[];
begin
  v_t := pg_temp.queued('a8', '08', 100000, 'c-ops');   -- Petit (its client admin: user 03)
  v_u := pg_temp.queued('a6', '06', 100000, 'c-job');
  perform pg_temp.handed_out('fp', 'gen-c-par');
  perform pg_temp.stmt2('ca', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_t)),
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_u))));
  perform pg_temp.bk(pg_temp.l2('ca', 1), pg_temp.prop(pg_temp.l2('ca', 1)), 'bk-ops-par', '01', null,
                     'Vu au relevé, voir le mail de M. Untel');
  insert into j values ('bb_ops', (select jsonb_agg(a.attname order by a.attnum) from pg_attribute a
                                   where a.attrelid = 'pg_temp._bb'::regclass and a.attnum > 0 and not a.attisdropped));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('ca', 2), 'payout', v_u)));
  insert into j values ('bb_job', (select jsonb_agg(a.attname order by a.attnum) from pg_attribute a
                                   where a.attrelid = 'pg_temp._bb'::regclass and a.attnum > 0 and not a.attisdropped));
  select array_agg(e.entry_type || ':' || coalesce(e.reason, '∅') || ':' || e.source_type order by e.entry_type)
  into v_ops from public.ledger_entry e
  where e.organization_id = '00000000-0000-0000-0000-0000000000aa'
    and e.idempotency_key in ('remit:' || v_t, 'settle:' || pg_temp.v('run-c-ops'));
  select array_agg(e.entry_type || ':' || coalesce(e.reason, '∅') || ':' || e.source_type order by e.entry_type)
  into v_job from public.ledger_entry e
  where e.organization_id = '00000000-0000-0000-0000-0000000000aa'
    and e.idempotency_key in ('remit:' || v_u, 'settle:' || pg_temp.v('run-c-job'));
  return jsonb_build_object(
    'client_reads_reason', pg_temp.try('03', format($q$ select coalesce(reason, '∅') from public.ledger_entry
                                                      where idempotency_key = %L $q$, 'remit:' || v_t)),
    'other_client', pg_temp.try('08', format($q$ select count(*)::text from public.ledger_entry
                                               where idempotency_key = %L $q$, 'remit:' || v_t)),
    'motif', (select k.reason from public.bank_line_booking k where k.bank_transaction_id = pg_temp.l2('ca', 1)),
    'parity', v_ops = v_job, 'entries', to_jsonb(v_ops),
    'states', jsonb_build_array(pg_temp.status(v_t), pg_temp.status(v_u),
                                (select status from public.remittance_run where id = pg_temp.v('run-c-ops')),
                                (select status from public.remittance_run where id = pg_temp.v('run-c-job'))),
    'bb_same_columns', (select j1.v = j2.v from j j1, j j2 where j1.k = 'bb_ops' and j2.k = 'bb_job'));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_reason_parity'),
  '{"client_reads_reason": "∅", "other_client": "0", "motif": "Vu au relevé, voir le mail de M. Untel", "parity": true,
    "entries": ["client_settlement:∅:remittance_run", "remittance:∅:bank_transfer"],
    "states": ["booked", "booked", "booked", "booked"], "bb_same_columns": true}'::jsonb,
  'C (CSO-1, parity): an ops payout''s remittance entry has no reason (the job''s), as its client''s member reads it '
  '(another client sees nothing); the motif is on the booking only; its entries, reasons and states are the job''s for a '
  'twin line, and the two pg_temp._bb builds have the same columns in the same order');
-- (review LT-3) S08 on a line whose statement had a charges block that was not read (camt.053.001.02's `Chrgs`): the
-- fee is never booked as « no charges recorded »
create or replace function pg_temp.c_unread() returns jsonb language plpgsql as $$
declare v_t uuid := pg_temp.inflight('a4', '04', 40000, 'c-unr');
begin
  perform pg_temp.stmt2('cb', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32920, 'e2e', pg_temp.e2e(v_t), 'read', false),
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(v_t), 'read', false)));
  return jsonb_build_object(
    'options', pg_temp.op(pg_temp.l2('cb', 1)) ->> 'refusal',
    'proposals', pg_temp.op(pg_temp.l2('cb', 1)) -> 'proposals',
    'command', pg_temp.bkx(pg_temp.l2('cb', 1), jsonb_build_array(pg_temp.pt('payout', v_t, 32800),
                                                                  pg_temp.pt('fee', null, 120))),
    -- without a fee part the line is booked as the payout's debit
    'exact', pg_temp.bkx(pg_temp.l2('cb', 2), pg_temp.prop(pg_temp.l2('cb', 2))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_unread'),
  '{"options": "unsplit_detail_missing", "proposals": [], "command": "unsplit_detail_missing", "exact": "ok"}'::jsonb,
  'C (review LT-3): a fee on a line whose charges block was not read → unsplit_detail_missing, no proposal (never the '
  'uncapped fee of a line that records none); the same line at the payout''s exact amount is its debit');
-- (review TESTS-3, critic F9) rule 3b's (ii): a refund in flight of the line's amount is a candidate — a reference-less
-- debit that a payout and a refund in flight may both be is line_ambiguous, without an IBAN and with the IBAN both share
create or replace function pg_temp.c_f9() returns jsonb language plpgsql as $$
declare v_t uuid; v_r uuid; v_reason text; v_left text; v_f uuid;
begin
  v_t := pg_temp.queued('a5', '05', 30000, 'c-f9');   -- 24 600 to Roux
  perform pg_temp.collect('c5', 24600, private.paris_today() - 3, false);
  select p.review_reason, x.unallocated_minor::text into v_reason, v_left
  from public.payment p cross join lateral private.payment_positions(array[p.id]) x where p.id = pg_temp.pay('c5');
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_r := (public.request_refund('c-f9-refund', pg_temp.pay('c5'), '24600', pg_temp.iban('a5'), 'ROUX SA', 'other',
                                v_reason, v_left, 'payeur inconnu') ->> 'refund_request_id')::uuid;
  reset role;
  v_f := pg_temp.handed_out('fcf9', 'gen-c-f9');
  perform pg_temp.exec_on(v_f, private.paris_today() - 1);
  perform pg_temp.stmt2('cc1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 24600, 'kind', 'other_debit'),
    jsonb_build_object('amount', 24600, 'kind', 'other_debit', 'iban', pg_temp.iban('a5'))));
  return jsonb_build_object(
    'refund_in_file', (select t.status || ':' || (t.transfer_file_id = v_f) from public.bank_transfer t
                       join public.refund_request q on q.transfer_id = t.id where q.id = v_r),
    'payout_in_file', pg_temp.status(v_t),
    'options', jsonb_build_array(pg_temp.op(pg_temp.l2('cc1', 1)) ->> 'refusal',
                                 pg_temp.op(pg_temp.l2('cc1', 2)) ->> 'refusal'),
    'command', jsonb_build_array(pg_temp.bkx(pg_temp.l2('cc1', 1), jsonb_build_array(pg_temp.pt('payout', v_t, 24600))),
                                 pg_temp.bkx(pg_temp.l2('cc1', 2), jsonb_build_array(pg_temp.pt('payout', v_t, 24600)))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_f9'),
  '{"refund_in_file": "in_file:true", "payout_in_file": "in_file", "options": ["line_ambiguous", "line_ambiguous"],
    "command": ["line_ambiguous", "line_ambiguous"]}'::jsonb,
  'C (review TESTS-3, F9): a reference-less debit a payout and a refund in flight of its amount may both be is '
  'line_ambiguous — without an IBAN, and with the IBAN they share — in the options and the command');
-- (review TESTS-8) a payout whose run is no longer in flight with it → run_not_in_flight; a lot holding a refund → batch_mixed
create or replace function pg_temp.c_rnif_mixed() returns jsonb language plpgsql as $$
declare v_t uuid; v_5 uuid; v_6 uuid; v_r uuid; v_reason text; v_left text; v jsonb;
begin
  v_t := pg_temp.inflight('a4', '04', 40000, 'c-rnif');
  update public.remittance_run set status = 'booked', booked_on = private.paris_today()
  where id = pg_temp.v('run-c-rnif');
  perform pg_temp.stmt2('ce1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(v_t))));
  v := jsonb_build_object('run_not_in_flight', pg_temp.bkx(pg_temp.l2('ce1', 1),
                                                           jsonb_build_array(pg_temp.pt('payout', v_t, 32800))));
  -- a refund put in the PmtInf of a lot of two payouts
  v_5 := pg_temp.queued('a5', '05', 30000, 'c-mx5');
  v_6 := pg_temp.queued('a6', '06', 100000, 'c-mx6');
  perform pg_temp.handed_out('fce', 'gen-c-mixed');
  perform pg_temp.collect('c6', 1000, private.paris_today() - 3, false);
  select p.review_reason, x.unallocated_minor::text into v_reason, v_left
  from public.payment p cross join lateral private.payment_positions(array[p.id]) x where p.id = pg_temp.pay('c6');
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_r := (public.request_refund('c-mx-refund', pg_temp.pay('c6'), '1000', null, null, 'other', v_reason, v_left,
                                'payeur inconnu') ->> 'refund_request_id')::uuid;
  reset role;
  v_r := (select transfer_id from public.refund_request where id = v_r);
  update public.bank_transfer set status = 'in_file', transfer_file_id = pg_temp.v('fce') where id = v_r;
  insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id, pmt_inf_id, execution_date)
  select i.file_id, 99, v_r, i.organization_id, i.pmt_inf_id, i.execution_date
  from public.transfer_file_item i where i.file_id = pg_temp.v('fce') and i.transfer_id = v_5;
  perform pg_temp.stmt2('ce2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  return v || jsonb_build_object(
    'mixed', pg_temp.bkx(pg_temp.l2('ce2', 1), jsonb_build_array(pg_temp.pt('payout', v_5, 24600),
                                                                 pg_temp.pt('payout', v_6, 82000))),
    'mixed_options', pg_temp.op(pg_temp.l2('ce2', 1)) ->> 'refusal');
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_rnif_mixed'),
  '{"run_not_in_flight": "run_not_in_flight", "mixed": "batch_mixed", "mixed_options": "batch_mixed"}'::jsonb,
  'C (review TESTS-8): a payout in a downloaded file whose run is no longer in flight with it → run_not_in_flight; a lot '
  'whose PmtInf holds a refund beside the payouts → batch_mixed (options and command)');
select is(pg_temp.dirty(), '{}'::text[], 'C: clean');


-- D. Unplanned payouts (plan §3.4.6, §3.6; Q4's default; critic F2, F3, F4, F6, CSO-6, CSO-7; critic2 ML-4) -------------
-- the prepare of a draft holding unplanned items (no account: no commission), as the job writes it; then its approval
create or replace function pg_temp.prepare_plain(p_run uuid) returns integer language plpgsql as $$
declare r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         pf.mandate_id, case when pf.mandate_id is not null
                             then ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid end,
         e.payment_id, e.effective_date, e.effective_date, q.posted_at,
         case when q.amount_minor > 0 then e.effective_date + 30 end,
         case when q.amount_minor > 0 then e.effective_date + 27 end, q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text), 0, 'none', '[]', false
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  left join public.account a on a.id = e.account_id
  left join public.portfolio pf on pf.id = a.portfolio_id
  where q.draft_run_id = p_run;
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', (select sum(amount_minor)::text from private.remittance_draft_line where run_id = p_run),
    'invoice_ht', '0', 'invoice_vat', '0', 'invoice_ttc', '0', 'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0',
    'taken', '0', 'advances', '0', 'refunds', '0', 'settlement', '0',
    'net', (select sum(amount_minor)::text from private.remittance_draft_line where run_id = p_run), 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || 'plain', 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', '[]'::jsonb, 'key_states', '[]'::jsonb,
    'plan', '{"settles": [], "net": "0", "settlement": "0", "dc": "0", "da": "0", "vat_moved": "0", "deferred": true}'));
  return (select version from public.remittance_run where id = p_run);
end $$;
create or replace function pg_temp.approve_plain(p_run uuid, p_key text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs('ap-' || p_key, pg_temp.item(p_run));
  reset role;
  v := private.approve_remittance_run(p_run, (select job_token from public.remittance_run where id = p_run)) ->> 'status';
  return coalesce(v, '?') || ':' || (select status from public.remittance_run where id = p_run);
end $$;
create or replace function pg_temp.request(p_c text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := (public.request_remittance_run('rq-' || p_key, pg_temp.c(p_c)) ->> 'run_id')::uuid;
  reset role;
  return v;
end $$;
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
grant execute on all functions in schema pg_temp to authenticated;

-- S01 (switch on): Roux's payout x (24 600) cancelled after download, its run cancelled (its item 30 000 back, then
-- reserved by Roux's draft), x executed late → P = A, no advance, the item attributed; the draft re-prepared; the next
-- run prepared and approved, its gross 30 000 − 24 600; a later second execution of x counts the first's items: P = 0
create or replace function pg_temp.d_s01() returns jsonb language plpgsql as $$
declare v_x uuid; v_d uuid; v_before integer; v jsonb; r jsonb;
begin
  v_x := pg_temp.cancelled_late('a5', '05', 30000, 'd-s01');
  v_d := pg_temp.request('a5', 'd-s01-draft');
  perform pg_temp.prepare_plain(v_d);
  -- (F4) another collection of Roux's waits, unreserved: the queue does not bound the second execution's P below
  perform pg_temp.file('b5', '20000000-0000-0000-0000-0000000000a5', 50000);
  perform pg_temp.collect('b5', 50000, private.paris_today() - 2);
  v_before := (select version from public.remittance_run where id = v_d);
  perform pg_temp.stmt2('d1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 24600, 'e2e', pg_temp.e2e(v_x)),
    jsonb_build_object('amount', 24600, 'e2e', pg_temp.e2e(v_x))));
  v := pg_temp.pv(pg_temp.l2('d1', 1), pg_temp.prop(pg_temp.l2('d1', 1)));
  r := pg_temp.bk(pg_temp.l2('d1', 1), pg_temp.prop(pg_temp.l2('d1', 1)));
  return pg_temp.d_s01_after(v_x, v_d, v_before, v, r);
end $$;
create or replace function pg_temp.d_s01_after(v_x uuid, v_d uuid, v_before integer, v jsonb, r jsonb)
returns jsonb language plpgsql as $$
declare w jsonb;
begin
  w := jsonb_build_object(
    'preview', jsonb_build_array(v -> 'parts' -> 0 ->> 'kind', v -> 'parts' -> 0 ->> 'paid_minor',
                                 v -> 'parts' -> 0 ->> 'advance_minor', v -> 'parts' -> 0 ->> 'p_bound',
                                 jsonb_array_length(v -> 'drafts')),
    'requeued', r -> 'drafts_requeued' = jsonb_build_array(v_d),
    'attributed', (select jsonb_agg(u.amount_minor) from private.unplanned_paid_item u
                   where u.booking_entry_id = (r -> 'bookings' -> 0 ->> 'entry_id')::uuid),
    'draft', (select jsonb_build_array(q.job, q.last_failure is null, q.requested_execution_date is null,
                                       q.prepared_at is null, q.version > v_before, q.item_count,
                                       exists (select 1 from private.remittance_draft_line l where l.run_id = q.id))
              from public.remittance_run q where q.id = v_d),
    'advance', (select count(*) from public.client_advance a where a.bank_transaction_id = pg_temp.l2('d1', 1)),
    'queue', pg_temp.queued_minor('a5'),
    'x', pg_temp.status(v_x));
  w := w || jsonb_build_object(
    'second', (select jsonb_build_array(z -> 'parts' -> 0 ->> 'paid_minor', z -> 'parts' -> 0 ->> 'advance_minor',
                                        z -> 'parts' -> 0 ->> 'p_bound')
               from (select pg_temp.pv(pg_temp.l2('d1', 2), pg_temp.prop(pg_temp.l2('d1', 2))) z) ww),
    'prepared', pg_temp.prepare_plain(v_d) > 0);
  w := w || jsonb_build_object('gross', (select gross_minor from public.remittance_run where id = v_d));
  w := w || jsonb_build_object('approved', pg_temp.approve_plain(v_d, 'd-s01'));
  return w || jsonb_build_object('dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_s01'),
  '{"preview": ["unplanned_payout", "24600", "0", "amount", 1], "requeued": true, "attributed": [24600],
    "draft": ["prepare", true, true, true, true, 3, true], "advance": 0, "queue": 55400, "x": "cancelled",
    "second": ["0", "24600", "items"], "prepared": true, "gross": 55400, "approved": "approved:approved",
    "dirty": []}'::jsonb,
  'D (S01, Q4; F4, CSO-6, CSO-7; review money-2, LT-1): a payout cancelled after download and executed late pays what '
  'its cancelled run had released, still waiting — P = A (24 600), no advance, the item attributed; the client''s draft '
  're-prepared (job prepare under a new token, no last_failure, its approval''s request reset, its prepared lines kept '
  'until the job starts, its items with another collection of 50 000 waiting unreserved); prepared and approved, its '
  'gross 30 000 + 50 000 − 24 600; a second execution of the same payout pays nothing more (its unplanned bookings '
  'together never net more than its amount: the 5 400 left of the item is the commission its run set off, never '
  'netted against the other collection), the whole of it an advance');
-- (F4) one item released by two cancelled runs (R1's payout x1 cancelled after download, its item back, then reserved
-- by R2, whose payout x2 is cancelled after download too); both executed late in one entry kept unsplit, another
-- collection waiting: the second part counts the first part's attribution of this call — P2 = 30 000 - 24 600
create or replace function pg_temp.d_f4_call() returns jsonb language plpgsql as $$
declare v_x1 uuid; v_r2 uuid; v_x2 uuid; v_f uuid; v jsonb;
begin
  v_x1 := pg_temp.cancelled_late('a5', '05', 30000, 'd-f4');
  v_r2 := pg_temp.request('a5', 'd-f4-r2');
  perform pg_temp.prepare_plain(v_r2);
  perform pg_temp.approve_plain(v_r2, 'd-f4-r2');
  v_x2 := (select transfer_id from public.remittance_run where id = v_r2);
  v_f := (pg_temp.gen('01', 'gen-d-f4-r2') ->> 'file_id')::uuid;
  perform pg_temp.write(v_f);
  perform pg_temp.download('01', v_f);
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_x2;
  perform pg_temp.cancel_run(v_r2, 'd-f4-r2');
  perform pg_temp.file('b5', '20000000-0000-0000-0000-0000000000a5', 50000);
  perform pg_temp.collect('b5', 50000, private.paris_today() - 2);
  perform pg_temp.stmt2('de', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 24600 + (select amount_minor from public.bank_transfer where id = v_x2),
                       'kind', 'batch_unsplit', 'unsplit', 2, 'count', 2,
                       'details', jsonb_build_array(
                         jsonb_build_object('id', pg_temp.e2e(v_x1), 'direction', 'debit', 'amount_minor', '24600'),
                         jsonb_build_object('id', pg_temp.e2e(v_x2), 'direction', 'debit',
                                            'amount_minor', (select amount_minor::text from public.bank_transfer
                                                             where id = v_x2))))));
  v := pg_temp.pv(pg_temp.l2('de', 1), pg_temp.prop(pg_temp.l2('de', 1)));
  v := jsonb_build_object(
    'x2', (select amount_minor from public.bank_transfer where id = v_x2),
    'parts', (select jsonb_agg(jsonb_build_array(p ->> 'kind', p ->> 'paid_minor', p ->> 'advance_minor',
                                                 p ->> 'p_bound') order by (p ->> 'n')::integer)
              from jsonb_array_elements(v -> 'parts') p),
    'booked', pg_temp.bkx(pg_temp.l2('de', 1), pg_temp.prop(pg_temp.l2('de', 1))));
  return v || jsonb_build_object(
    'attributed', (select jsonb_agg(jsonb_build_array(u.amount_minor, x.n) order by u.amount_minor desc)
                   from (select count(distinct u2.ledger_entry_id) as n from private.unplanned_paid_item u2
                         where u2.booking_entry_id in (select k.entry_id from public.bank_line_booking k
                                                       where k.bank_transaction_id = pg_temp.l2('de', 1))) x,
                        private.unplanned_paid_item u
                   where u.booking_entry_id in (select k.entry_id from public.bank_line_booking k
                                                where k.bank_transaction_id = pg_temp.l2('de', 1))),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_f4_call'),
  '{"x2": 30000, "parts": [["unplanned_payout", "24600", "0", "amount"], ["unplanned_payout", "5400", "24600", "items"]],
    "booked": "ok", "attributed": [[24600, 1], [5400, 1]], "dirty": []}'::jsonb,
  'D (F4): one item released by two cancelled runs, both payouts executed late in one entry kept unsplit, another '
  'collection waiting: the first part pays 24 600 of it, the second counts that attribution of the same call (only '
  'the 5 400 left, the rest an advance); one item attributed 24 600 + 5 400, never more than it was owed');
-- (F6) the items x paid are frozen in an approved run of the client not handed out: that run is cancelled first; then
-- P = A. (ML-4) x cancelled alone while its run is still sent → run_still_live
create or replace function pg_temp.d_f6_ml4() returns jsonb language plpgsql as $$
declare v_x uuid; v_r2 uuid; v_y uuid; v jsonb;
begin
  v_x := pg_temp.cancelled_late('a5', '05', 30000, 'd-f6');
  v_y := pg_temp.cancelled_late('a6', '06', 100000, 'd-ml4', false);
  v_r2 := pg_temp.request('a5', 'd-f6-r2');
  perform pg_temp.prepare_plain(v_r2);
  perform pg_temp.approve_plain(v_r2, 'd-f6-r2');
  perform pg_temp.stmt2('d2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 24600, 'e2e', pg_temp.e2e(v_x)),
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_y))));
  v := jsonb_build_object(
    'cancellable', pg_temp.bkx(pg_temp.l2('d2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', v_x, 24600))),
    'detail', pg_temp.pv(pg_temp.l2('d2', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', v_x, 24600)))
                ->> 'detail' = (select number from public.remittance_run where id = v_r2),
    'still_live', pg_temp.bkx(pg_temp.l2('d2', 2), jsonb_build_array(pg_temp.pt('unplanned_payout', v_y, 82000))),
    'still_live_options', pg_temp.op(pg_temp.l2('d2', 2)) ->> 'refusal');
  perform pg_temp.cancel_run(v_r2, 'd-f6-r2');
  return v || jsonb_build_object(
    'after_cancel', (select jsonb_build_array(z -> 'parts' -> 0 ->> 'paid_minor', z -> 'parts' -> 0 ->> 'advance_minor')
                     from (select pg_temp.pv(pg_temp.l2('d2', 1), pg_temp.prop(pg_temp.l2('d2', 1))) z) w));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_f6_ml4'),
  '{"cancellable": "client_run_cancellable", "detail": true, "still_live": "run_still_live",
    "still_live_options": "run_still_live", "after_cancel": ["24600", "0"]}'::jsonb,
  'D (F6): the items x was meant to pay sit in an approved run of the client not handed out → client_run_cancellable '
  '(its number in the detail); once that run is cancelled P = A. (ML-4) a cancelled payout whose run is still sent → '
  'run_still_live, in the command and the options');
-- S03r (F2): a payout booked, returned (its item queued again and reserved by the client's draft), then executed again
-- → P = A on its return item, no advance; (F3) an item reversed since its run was cancelled counts net: P = 0
create or replace function pg_temp.d_s03r_f3() returns jsonb language plpgsql as $$
declare v_x uuid; v_d uuid; v_y uuid; v jsonb; w jsonb;
begin
  v_x := pg_temp.inflight('a7', '07', 50000, 'd-s03r');   -- 41 000
  perform pg_temp.stmt2('d3', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('d3', 1), 'payout', v_x)));
  perform pg_temp.stmt2('d4', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('d4', 1), 'payout_returned', v_x)));
  v_d := pg_temp.request('a7', 'd-s03r');
  -- then the bank executes x again
  perform pg_temp.stmt2('d4b', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  v := pg_temp.pv(pg_temp.l2('d4b', 1), pg_temp.prop(pg_temp.l2('d4b', 1)));
  -- F3: Durand's payout cancelled after download, its run cancelled, then its collection reversed (bounced)
  v_y := pg_temp.cancelled_late('a6', '06', 100000, 'd-f3');
  perform private.ledger_reverse((select id from public.ledger_entry where payment_id = pg_temp.pay('06')
                                    and entry_type = 'allocation'), 'rev-test-d-06', 'Retour du paiement (test)',
                                 private.paris_today());
  perform pg_temp.stmt2('d5', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_y))));
  w := pg_temp.pv(pg_temp.l2('d5', 1), pg_temp.prop(pg_temp.l2('d5', 1)));
  return jsonb_build_object(
    's03r', jsonb_build_array(v -> 'parts' -> 0 ->> 'kind', v -> 'parts' -> 0 ->> 'paid_minor',
                              v -> 'parts' -> 0 ->> 'advance_minor', v -> 'parts' -> 0 ->> 'p_bound',
                              v -> 'drafts' -> 0 ->> 'run_id' = v_d::text),
    'booked', pg_temp.bkx(pg_temp.l2('d4b', 1), pg_temp.prop(pg_temp.l2('d4b', 1))),
    'queue', pg_temp.queued_minor('a7'),
    'f3', jsonb_build_array(w -> 'parts' -> 0 ->> 'paid_minor', w -> 'parts' -> 0 ->> 'advance_minor',
                            w -> 'parts' -> 0 ->> 'p_bound'),
    'f3_booked', pg_temp.bkx(pg_temp.l2('d5', 1), pg_temp.prop(pg_temp.l2('d5', 1))),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_s03r_f3'),
  '{"s03r": ["unplanned_payout", "41000", "0", "amount", true], "booked": "ok", "queue": 0,
    "f3": ["0", "82000", "items"], "f3_booked": "ok", "dirty": []}'::jsonb,
  'D (F2): a returned payout executed again pays its return item — P = A, no advance, the client''s draft re-prepared, '
  'its queue net 0; (F3) a payout cancelled after download whose collection was reversed since: P = 0 (its items net '
  'of their reversal), the advance all of it');
-- S13, S07: a debit to a client's registered payout IBAN matching nothing of ours (class N), one carrying an unknown
-- RMT-shaped id (E0): the client's, P = 0, the advance all of it, the line its document; an IBAN registered for none
-- of the servicer's clients, or for two
create or replace function pg_temp.d_s13() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.stmt2('d6', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 5000, 'kind', 'other_debit', 'iban', pg_temp.iban('a3')),
    jsonb_build_object('amount', 6000, 'kind', 'transfer_out', 'e2e', 'RMT0000000000EF', 'iban', pg_temp.iban('a3')),
    jsonb_build_object('amount', 7000, 'kind', 'other_debit', 'iban', 'FR8130004000039876543210134'),
    jsonb_build_object('amount', 8000, 'kind', 'other_debit', 'iban', pg_temp.iban('a9'))));
  -- Moreau's IBAN proposed for Petit too (registered for two clients of the servicer)
  insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                            evidence_document_id, proposed_by)
  values ('90000000-0000-0000-0000-0000000000f9', '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a8'), 'EUR',
          pg_temp.iban('a9'), 'PETIT SAS', 'd0000000-0000-0000-0000-0000000002a8',
          '10000000-0000-0000-0000-000000000004');
  v := jsonb_build_object(
    'proposed', pg_temp.prop(pg_temp.l2('d6', 1)) = jsonb_build_array(pg_temp.pt('unplanned_payout', null, 5000,
                                                                                 pg_temp.c('a3'))),
    'preview', (select jsonb_build_array(z -> 'parts' -> 0 ->> 'paid_minor', z -> 'parts' -> 0 ->> 'advance_minor',
                                         z -> 'parts' -> 0 ->> 'p_bound')
                from (select pg_temp.pv(pg_temp.l2('d6', 1), pg_temp.prop(pg_temp.l2('d6', 1))) z) w),
    's13', pg_temp.bkx(pg_temp.l2('d6', 1), pg_temp.prop(pg_temp.l2('d6', 1))));
  v := v || jsonb_build_object('source', (select e.source_type || ':' || (e.source_id = pg_temp.l2('d6', 1)::text) from public.ledger_entry e
               where e.idempotency_key = 'remit:line:' || pg_temp.l2('d6', 1) || ':1'));
  v := v || jsonb_build_object('s07', pg_temp.bkx(pg_temp.l2('d6', 2), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 6000,
                                                                         pg_temp.c('a3')))),
    'mismatch', pg_temp.bkx(pg_temp.l2('d6', 3), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 7000,
                                                                              pg_temp.c('a3')))),
    'ambiguous', pg_temp.bkx(pg_temp.l2('d6', 4), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 8000,
                                                                               pg_temp.c('a9')))));
  v := v || jsonb_build_object('advances', (select jsonb_agg(a.amount_minor order by a.amount_minor) from public.client_advance a
                 where a.client_organization_id = pg_temp.c('a3')),
    'dirty', pg_temp.dirty());
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_s13'),
  '{"proposed": true, "preview": ["0", "5000", "none"], "s13": "ok", "source": "bank_transaction:true", "s07": "ok",
    "mismatch": "client_iban_mismatch", "ambiguous": "client_ambiguous", "advances": [5000, 6000], "dirty": []}'::jsonb,
  'D (S13, S07; Q8''s default): a debit to a client''s payout IBAN matching nothing of ours is that client''s unplanned '
  'payout, P = 0 and the advance all of it, the line its document; an unknown RMT-shaped id the same; an IBAN of none '
  'of the clients → client_iban_mismatch; of two → client_ambiguous');
-- S05: a lot holding a live member's debit and a booked member's second → payout + unplanned payout; class N, the late
-- execution of a cancelled payout of a downloaded file (F12): its unplanned payout, the client part refused
create or replace function pg_temp.d_s05_n() returns jsonb language plpgsql as $$
declare v_5 uuid; v_6 uuid; v_x uuid;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 'd-l5');
  v_6 := pg_temp.queued('a6', '06', 100000, 'd-l6');
  perform pg_temp.handed_out('fq', 'gen-d-s05');
  perform pg_temp.stmt2('d7', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_6))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('d7', 1), 'payout', v_6)));
  perform pg_temp.stmt2('d8', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  v_x := pg_temp.cancelled_late('a9', '09', 30000, 'd-cancel-n');
  perform pg_temp.exec_on(pg_temp.v('file-d-cancel-n'), private.paris_today() - 1);
  perform pg_temp.stmt2('d9', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 24600, 'kind', 'other_debit', 'iban', pg_temp.iban('a9'))));
  return jsonb_build_object(
    's05', (select jsonb_agg(p ->> 'kind' order by p ->> 'kind') from jsonb_array_elements(pg_temp.prop(pg_temp.l2('d8', 1))) p),
    's05_booked', pg_temp.bkx(pg_temp.l2('d8', 1), pg_temp.prop(pg_temp.l2('d8', 1))),
    'n_proposed', pg_temp.prop(pg_temp.l2('d9', 1)) = jsonb_build_array(pg_temp.pt('unplanned_payout', v_x, 24600)),
    'n_client', pg_temp.bkx(pg_temp.l2('d9', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 24600,
                                                                              pg_temp.c('a9')))),
    'n_booked', pg_temp.bkx(pg_temp.l2('d9', 1), pg_temp.prop(pg_temp.l2('d9', 1))),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_s05_n'),
  '{"s05": ["payout", "unplanned_payout"], "s05_booked": "ok", "n_proposed": true,
    "n_client": "cancelled_payout_matches", "n_booked": "ok", "dirty": []}'::jsonb,
  'D (S05, F12): a lot of a live member''s debit and a booked member''s second is booked payout + unplanned payout; a '
  'line without our reference of a cancelled payout''s amount to its IBAN is that payout''s unplanned payout, the '
  'client part refused cancelled_payout_matches');
-- (review TESTS-8, critic2 ML-8) a returned payout is not a candidate while the run re-paying its return item to the
-- same IBAN is in flight: a reference-less debit of that amount is that run's payout
create or replace function pg_temp.c_ml8() returns jsonb language plpgsql as $$
declare v_x uuid; v_d uuid; v_t2 uuid; v_f uuid; v jsonb;
begin
  v_x := pg_temp.inflight('a7', '07', 50000, 'c-ml8');   -- 41 000 to Durand
  perform pg_temp.stmt2('cd1', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('cd1', 1), 'payout', v_x)));
  perform pg_temp.stmt2('cd2', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('cd2', 1), 'payout_returned', v_x)));
  -- the IBAN reconfirmed, the return item re-paid by the next run (the same amount to the same IBAN)
  perform pg_temp.reconfirm('a7');
  v_d := pg_temp.request('a7', 'c-ml8-r2');
  perform pg_temp.prepare_plain(v_d);
  perform pg_temp.approve_plain(v_d, 'c-ml8-r2');
  v_t2 := (select transfer_id from public.remittance_run where id = v_d);
  v_f := pg_temp.handed_out('fcd', 'gen-c-ml8-r2');
  perform pg_temp.exec_on(v_f, private.paris_today() - 1);
  perform pg_temp.exec_on(pg_temp.v('file-c-ml8'), private.paris_today() - 1);
  perform pg_temp.stmt2('cd3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 41000, 'kind', 'other_debit', 'iban', pg_temp.iban('a7'))));
  v := jsonb_build_object(
    't2', jsonb_build_array(pg_temp.amt(v_t2), pg_temp.status(v_t2)), 'x', pg_temp.status(v_x),
    'proposed', pg_temp.prop(pg_temp.l2('cd3', 1)) = jsonb_build_array(pg_temp.pt('payout', v_t2, 41000)),
    'booked', pg_temp.bkx(pg_temp.l2('cd3', 1), pg_temp.prop(pg_temp.l2('cd3', 1))));
  return v || jsonb_build_object('run', (select status from public.remittance_run where id = v_d), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_ml8'),
  '{"t2": [41000, "in_file"], "x": "returned", "proposed": true, "booked": "ok", "run": "booked", "dirty": []}'::jsonb,
  'C, D (review TESTS-8, ML-8): a reference-less debit to the client''s IBAN of a returned payout''s amount, while the run '
  're-paying its return item to that IBAN is in flight, is that run''s payout (the returned one is not a candidate)');
-- (review TESTS-1, critic F5) P is bounded by what the client's queue can net: Durand's R0 (c7, 10 000) remitted, R1's
-- payout x (41 000) booked and returned (its item 41 000 owed again), R2 (41 000) in flight; c7 bounces (−10 000): the
-- queue nets 31 000; x executed again → P 31 000 (queue), a double_payout advance of 10 000, the queue at 0; R2's own
-- debit then needs no payout_overrun cover
create or replace function pg_temp.d_f5() returns jsonb language plpgsql as $$
declare v_t0 uuid; v_x uuid; v_t2 uuid; v jsonb; q0 bigint; b text; w jsonb;
begin
  v_t0 := pg_temp.inflight('a7', 'c7', 10000, 'd-f5-r0');
  perform pg_temp.stmt2('c70', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', pg_temp.amt(v_t0), 'e2e', pg_temp.e2e(v_t0))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c70', 1), 'payout', v_t0)));
  v_x := pg_temp.inflight('a7', '07', 50000, 'd-f5');
  perform pg_temp.stmt2('c71', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c71', 1), 'payout', v_x)));
  v_t2 := pg_temp.inflight('a7', 'b7', 50000, 'd-f5-r2');
  perform pg_temp.stmt2('c72', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c72', 1), 'payout_returned', v_x)));
  perform private.ledger_reverse((select id from public.ledger_entry where payment_id = pg_temp.pay('c7')
                                    and entry_type = 'allocation'), 'rev-d-f5-c7', 'Retour du paiement (test)',
                                 private.paris_today());
  q0 := pg_temp.queued_minor('a7');
  perform pg_temp.stmt2('c73', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  v := pg_temp.pv(pg_temp.l2('c73', 1), pg_temp.prop(pg_temp.l2('c73', 1)));
  b := pg_temp.bkx(pg_temp.l2('c73', 1), pg_temp.prop(pg_temp.l2('c73', 1)));
  w := jsonb_build_object('queue_after', pg_temp.queued_minor('a7'));
  perform pg_temp.stmt2('c74', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', pg_temp.amt(v_t2), 'e2e', pg_temp.e2e(v_t2))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c74', 1), 'payout', v_t2)));
  return w || jsonb_build_object(
    'queue_before', q0, 'part', pg_temp.pp(v), 'booked', b, 't2', pg_temp.status(v_t2),
    'advances', (select jsonb_agg(a.cause || ':' || a.amount_minor order by a.cause) from public.client_advance a
                 where a.client_organization_id = pg_temp.c('a7')),
    'queue_end', pg_temp.queued_minor('a7'), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_f5'),
  '{"queue_before": 31000, "part": ["unplanned_payout", "31000", "10000", "queue"], "booked": "ok", "queue_after": 0,
    "t2": "booked", "advances": ["double_payout:10000"], "queue_end": 0, "dirty": []}'::jsonb,
  'D (review TESTS-1, F5): a returned payout executed again while the client''s queue nets less than its item (a '
  'remitted collection bounced) pays what the queue can net — P = 31 000 (queue), a double_payout advance of 10 000 — '
  'and the run in flight''s own debit then needs no payout_overrun cover');
-- (review TESTS-1) the queue shared by the parts of one call: R0's payout t0 (8 200) and R1's x (41 000) of Durand both
-- booked and returned (39 200 queued once c7 bounces), then both executed again in one entry the bank kept unsplit —
-- the first part pays 8 200, the second only the 31 000 the queue still nets
create or replace function pg_temp.d_queue_call() returns jsonb language plpgsql as $$
declare v_t0 uuid; v_x uuid; v jsonb; q0 bigint;
begin
  v_t0 := pg_temp.inflight('a7', 'c7', 10000, 'd-qc-r0');
  perform pg_temp.stmt2('c75', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', pg_temp.amt(v_t0), 'e2e', pg_temp.e2e(v_t0))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c75', 1), 'payout', v_t0)));
  v_x := pg_temp.inflight('a7', '07', 50000, 'd-qc-r1');
  perform pg_temp.stmt2('c76', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c76', 1), 'payout', v_x)));
  perform pg_temp.stmt2('c77', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', pg_temp.amt(v_t0), 'orig', pg_temp.e2e(v_t0)),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c77', 1), 'payout_returned', v_t0),
                                         pg_temp.row(pg_temp.l2('c77', 2), 'payout_returned', v_x)));
  perform private.ledger_reverse((select id from public.ledger_entry where payment_id = pg_temp.pay('c7')
                                    and entry_type = 'allocation'), 'rev-d-qc-c7', 'Retour du paiement (test)',
                                 private.paris_today());
  q0 := pg_temp.queued_minor('a7');
  perform pg_temp.stmt2('c78', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', pg_temp.amt(v_t0) + 41000, 'kind', 'batch_unsplit', 'unsplit', 2, 'count', 2,
                       'details', jsonb_build_array(
                         jsonb_build_object('id', pg_temp.e2e(v_t0), 'direction', 'debit',
                                            'amount_minor', pg_temp.amt(v_t0)::text),
                         jsonb_build_object('id', pg_temp.e2e(v_x), 'direction', 'debit', 'amount_minor', '41000')))));
  v := pg_temp.pv(pg_temp.l2('c78', 1), pg_temp.prop(pg_temp.l2('c78', 1)));
  return jsonb_build_object(
    'queue_before', q0, 'parts', jsonb_build_array(pg_temp.pp(v, 0), pg_temp.pp(v, 1)),
    'booked', pg_temp.bkx(pg_temp.l2('c78', 1), pg_temp.prop(pg_temp.l2('c78', 1))),
    'queue_after', pg_temp.queued_minor('a7'), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_queue_call'),
  '{"queue_before": 39200, "parts": [["unplanned_payout", "8200", "0", "amount"],
                                     ["unplanned_payout", "31000", "10000", "queue"]],
    "booked": "ok", "queue_after": 0, "dirty": []}'::jsonb,
  'D (review TESTS-1): two unplanned parts of one client in one call share its queue — the second part counts the P of '
  'the first (8 200) and pays only the 31 000 left, the rest an advance; the queue ends at 0, never below');
-- (review TESTS-2, critic F13) a debit matching a payout of the client not handed out (approved, ordered, in no file) is
-- never the client's unplanned payout: class N, E0 (an RMT-shaped id naming nothing) and O, options and command
create or replace function pg_temp.d_pnho() returns jsonb language plpgsql as $$
declare v_t uuid; v_a bigint;
begin
  v_t := pg_temp.queued('a3', '03', 30000, 'd-pnho');
  v_a := pg_temp.amt(v_t);
  perform pg_temp.stmt2('c81', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', v_a, 'kind', 'other_debit', 'iban', pg_temp.iban('a3')),
    jsonb_build_object('amount', v_a, 'kind', 'transfer_out', 'e2e', 'RMT0000000000E1', 'iban', pg_temp.iban('a3')),
    jsonb_build_object('amount', v_a, 'kind', 'other_debit', 'e2e', 'BANQUE-REF-77', 'iban', pg_temp.iban('a3'))));
  return jsonb_build_object(
    't', pg_temp.status(v_t),
    'classes', jsonb_build_array(pg_temp.op(pg_temp.l2('c81', 1)) ->> 'class', pg_temp.op(pg_temp.l2('c81', 2)) ->> 'class',
                                 pg_temp.op(pg_temp.l2('c81', 3)) ->> 'class'),
    'options', (select jsonb_agg(pg_temp.op(pg_temp.l2('c81', k)) ->> 'refusal' order by k) from generate_series(1, 3) k),
    'proposals', (select jsonb_agg(jsonb_array_length(pg_temp.op(pg_temp.l2('c81', k)) -> 'proposals') order by k)
                  from generate_series(1, 3) k),
    'command', (select jsonb_agg(pg_temp.bkx(pg_temp.l2('c81', k), jsonb_build_array(pg_temp.pt('unplanned_payout', null,
                                                                                    v_a, pg_temp.c('a3')))) order by k)
                from generate_series(1, 3) k));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_pnho'),
  '{"t": "ordered", "classes": ["N", "E0", "O"],
    "options": ["payout_not_handed_out_matches", "payout_not_handed_out_matches", "payout_not_handed_out_matches"],
    "proposals": [0, 0, 0],
    "command": ["payout_not_handed_out_matches", "payout_not_handed_out_matches", "payout_not_handed_out_matches"]}'::jsonb,
  'D (review TESTS-2, F13): a debit of a client''s payout not handed out yet, to that client''s IBAN, is never booked as '
  'the client''s unplanned payout (class N, E0 and O; options and command) — else the client is paid twice once that '
  'payout is executed');
-- (review TESTS-5, critic2 ML-1) the pool's own unplanned rows are not items: Durand's x booked, returned (ρ) and
-- executed again (P = A on ρ, its −A row); then a collection a (50 000) and Durand's run R1 holding a, ρ and that −A
-- row, approved, its payout y (50 000) handed out, cancelled after download with R1; y executed late: P = A (the −A
-- row, already netted by its own booking's attribution, never lowers the cap)
create or replace function pg_temp.d_ml1_own() returns jsonb language plpgsql as $$
declare v_x uuid; v_r1 uuid; v_y uuid; v_f uuid;
begin
  v_x := pg_temp.inflight('a7', '07', 50000, 'd-own');   -- 41 000
  perform pg_temp.stmt2('c82', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c82', 1), 'payout', v_x)));
  perform pg_temp.stmt2('c83', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c83', 1), 'payout_returned', v_x)));
  perform pg_temp.stmt2('c8c', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.bk(pg_temp.l2('c8c', 1), pg_temp.prop(pg_temp.l2('c8c', 1)));
  perform pg_temp.file('17', '20000000-0000-0000-0000-0000000000a7', 50000);
  perform pg_temp.collect('17', 50000, private.paris_today() - 1);
  perform pg_temp.reconfirm('a7');
  v_r1 := pg_temp.request('a7', 'd-own-r1');
  perform pg_temp.prepare_plain(v_r1);
  perform pg_temp.approve_plain(v_r1, 'd-own-r1');
  v_y := (select transfer_id from public.remittance_run where id = v_r1);
  v_f := (pg_temp.gen('01', 'gen-d-own-r1') ->> 'file_id')::uuid;
  perform pg_temp.write(v_f);
  perform pg_temp.download('01', v_f);
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_y;
  perform pg_temp.cancel_run(v_r1, 'd-own-r1');
  perform pg_temp.stmt2('c84', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', pg_temp.amt(v_y), 'e2e', pg_temp.e2e(v_y))));
  return jsonb_build_object(
    'y', pg_temp.amt(v_y), 'released', (select count(*) from public.remittance_line where run_id = v_r1 and released),
    'part', pg_temp.pp(pg_temp.pv(pg_temp.l2('c84', 1), pg_temp.prop(pg_temp.l2('c84', 1)))),
    'booked', pg_temp.bkx(pg_temp.l2('c84', 1), pg_temp.prop(pg_temp.l2('c84', 1))), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_ml1_own'),
  '{"y": 50000, "released": 3, "part": ["unplanned_payout", "50000", "0", "amount"], "booked": "ok", "dirty": []}'::jsonb,
  'D (review TESTS-5, ML-1): a cancelled run''s released lines holding an earlier unplanned booking''s −A row: that row '
  'is the booking''s own and never an item of the pool — the late execution pays the run''s items in full, P = A');
-- (review TESTS-5, critic2 ML-1) the pool's signed net, floored once: Durand's R0 (c7 10 000) remitted, c7 bounces
-- (r −10 000 waits); collections a (50 000) and b (10 000); Durand's R1 holds a, b and r (y = 50 000), handed out, then
-- cancelled after download with y; a bounces (its chain nets 0) and n (20 000) arrives; y executed late: P = 0 (the
-- signed net of y's items is 0 + 10 000 − 10 000), the whole of it an advance, n still owed
create or replace function pg_temp.d_ml1_signed() returns jsonb language plpgsql as $$
declare v_t0 uuid; v_r1 uuid; v_y uuid; v_f uuid;
begin
  v_t0 := pg_temp.inflight('a7', 'c7', 10000, 'd-sg-r0');
  perform pg_temp.stmt2('c85', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', pg_temp.amt(v_t0), 'e2e', pg_temp.e2e(v_t0))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c85', 1), 'payout', v_t0)));
  perform private.ledger_reverse((select id from public.ledger_entry where payment_id = pg_temp.pay('c7')
                                    and entry_type = 'allocation'), 'rev-d-sg-c7', 'Retour du paiement (test)',
                                 private.paris_today() - 1);
  perform pg_temp.file('07', '20000000-0000-0000-0000-0000000000a7', 50000);
  perform pg_temp.collect('07', 50000, private.paris_today() - 1);
  perform pg_temp.file('17', '20000000-0000-0000-0000-0000000000a7', 10000);
  perform pg_temp.collect('17', 10000, private.paris_today() - 1);
  v_r1 := pg_temp.request('a7', 'd-sg-r1');
  perform pg_temp.prepare_plain(v_r1);
  perform pg_temp.approve_plain(v_r1, 'd-sg-r1');
  v_y := (select transfer_id from public.remittance_run where id = v_r1);
  v_f := (pg_temp.gen('01', 'gen-d-sg') ->> 'file_id')::uuid;
  perform pg_temp.write(v_f);
  perform pg_temp.download('01', v_f);
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_y;
  perform pg_temp.cancel_run(v_r1, 'd-sg-r1');
  perform private.ledger_reverse((select id from public.ledger_entry where payment_id = pg_temp.pay('07')
                                    and entry_type = 'allocation'), 'rev-d-sg-07', 'Retour du paiement (test)',
                                 private.paris_today());
  perform pg_temp.file('27', '20000000-0000-0000-0000-0000000000a7', 20000);
  perform pg_temp.collect('27', 20000, private.paris_today());
  perform pg_temp.stmt2('c86', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', pg_temp.amt(v_y), 'e2e', pg_temp.e2e(v_y))));
  return jsonb_build_object(
    'y', pg_temp.amt(v_y), 'queue', pg_temp.queued_minor('a7'),
    'part', pg_temp.pp(pg_temp.pv(pg_temp.l2('c86', 1), pg_temp.prop(pg_temp.l2('c86', 1)))),
    'booked', pg_temp.bkx(pg_temp.l2('c86', 1), pg_temp.prop(pg_temp.l2('c86', 1))),
    'queue_after', pg_temp.queued_minor('a7'), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_ml1_signed'),
  '{"y": 50000, "queue": 20000, "part": ["unplanned_payout", "0", "50000", "items"], "booked": "ok",
    "queue_after": 20000, "dirty": []}'::jsonb,
  'D (review TESTS-5, ML-1): the cap is the signed net of the items the late payout was meant to pay, floored once — a '
  'negative item (a remitted collection bounced) offsets a positive one: P = 0 and the advance all of it; the new '
  'collection n is still owed');
-- (review TESTS-5) a returned unplanned booking's attributions stop counting: Durand's x booked, returned (ρ), executed
-- again (U1: P = A on ρ), that copy returned (U1 reversed: ρ owed again), then executed a third time → P = A on ρ again
create or replace function pg_temp.d_paid_reversed() returns jsonb language plpgsql as $$
declare v_x uuid;
begin
  v_x := pg_temp.inflight('a7', '07', 50000, 'd-pr');   -- 41 000
  perform pg_temp.stmt2('c87', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c87', 1), 'payout', v_x)));
  perform pg_temp.stmt2('c88', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c88', 1), 'payout_returned', v_x)));
  perform pg_temp.stmt2('c89', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x)),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.bk(pg_temp.l2('c89', 1), pg_temp.prop(pg_temp.l2('c89', 1)));
  perform pg_temp.bk(pg_temp.l2('c89', 2), pg_temp.prop(pg_temp.l2('c89', 2)));
  perform pg_temp.stmt2('c8a', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  return jsonb_build_object(
    'u1_returned', pg_temp.bookings(pg_temp.l2('c89', 2)),
    'third', pg_temp.pp(pg_temp.pv(pg_temp.l2('c8a', 1), pg_temp.prop(pg_temp.l2('c8a', 1)))),
    'booked', pg_temp.bkx(pg_temp.l2('c8a', 1), pg_temp.prop(pg_temp.l2('c8a', 1))),
    'queue', pg_temp.queued_minor('a7'), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_paid_reversed'),
  '{"u1_returned": ["1 unplanned_payout_returned 41000"], "third": ["unplanned_payout", "41000", "0", "amount"],
    "booked": "ok", "queue": 0, "dirty": []}'::jsonb,
  'D (review TESTS-5): once an unplanned booking''s copy has come back, the items it paid are owed again — a third '
  'execution pays the return item again (P = A), the queue nets 0');
select is(pg_temp.dirty(), '{}'::text[], 'D: clean');




-- F. Returns (plan §3.4.11, §3.5; critic F1, L2; critic2 ML-3) --------------------------------------------------------
-- S16: a payout booked comes back unflagged as a client's credit carrying its RMT id; short, flagged short with the
-- bank's charge, more; before its debit; twice
create or replace function pg_temp.f_returns() returns jsonb language plpgsql as $$
declare v_x uuid; v_y uuid; v jsonb;
begin
  v_x := pg_temp.inflight('a4', '04', 40000, 'f-ret');   -- 32 800
  v_y := pg_temp.inflight('a6', '06', 100000, 'f-ret2');  -- 82 000, left in flight
  perform pg_temp.stmt2('f1', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('f1', 1), 'payout', v_x)));
  perform pg_temp.stmt2('f2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'client_transfer_in', 'amount', 32800, 'iban', pg_temp.iban('a4'),
                       'orig', pg_temp.e2e(v_x)),
    jsonb_build_object('dir', 'credit', 'kind', 'client_transfer_in', 'amount', 32700, 'iban', pg_temp.iban('a4'),
                       'orig', pg_temp.e2e(v_x)),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 32680, 'orig', pg_temp.e2e(v_x)),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 33000, 'orig', pg_temp.e2e(v_x)),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 82000, 'orig', pg_temp.e2e(v_y))));
  v := jsonb_build_object(
    'short_unflagged', pg_temp.bkx(pg_temp.l2('f2', 2), jsonb_build_array(pg_temp.pt('payout_returned', v_x, 32700))),
    'more', pg_temp.bkx(pg_temp.l2('f2', 4), jsonb_build_array(pg_temp.pt('payout_returned', v_x, 33000))),
    'before_debit', pg_temp.bkx(pg_temp.l2('f2', 5), jsonb_build_array(pg_temp.pt('payout_returned', v_y, 82000))),
    'flagged_short', pg_temp.op(pg_temp.l2('f2', 3)) -> 'proposals' -> 0 -> 'request',
    'funds_before', pg_temp.funds_msgs(),
    'unflagged', pg_temp.bkx(pg_temp.l2('f2', 1), pg_temp.prop(pg_temp.l2('f2', 1))));
  return v || jsonb_build_object(
    'funds_after', pg_temp.funds_msgs(),
    'keys', pg_temp.keys(pg_temp.l2('f2', 1)), 'item', pg_temp.returned_items('a4'),
    'account', pg_temp.payout_account('a4'), 'x', pg_temp.status(v_x),
    'again', pg_temp.bkx(pg_temp.l2('f2', 3), jsonb_build_array(pg_temp.pt('payout_returned', v_x, 32800),
                                                                pg_temp.pt('fee', null, 120))),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('f_returns') - 'flagged_short' - 'funds_before' - 'funds_after',
  '{"short_unflagged": "amount_differs", "more": "return_differs", "before_debit": "return_before_debit",
    "unflagged": "ok", "keys": ["return:·:·"], "item": 1, "account": "returned", "x": "returned",
    "again": "already_returned", "dirty": []}'::jsonb,
  'F (S16, L2): a payout coming back unflagged as a client''s credit carrying its id is booked its return at the exact '
  'amount (return:<line>:<t>, its item queued again, its payout account returned); short of it unflagged → '
  'amount_differs; more → return_differs; before its debit → return_before_debit; again → already_returned');
select is((select jsonb_build_array(v -> 'flagged_short' -> 1, (v ->> 'funds_after')::integer - (v ->> 'funds_before')::integer)
           from (select pg_temp.isolated('f_returns') v) w),
  jsonb_build_array(jsonb_build_object('kind', 'fee', 'amount', '120'), 0),
  'F (L2, CSO2-7): a flagged return short of the payout is proposed with the bank''s charge as a fee part; a booking of '
  'planned returns only queues no funds pass');
-- F1: x1's return once its second execution is booked unplanned (S03, in the base) → unplanned_open, and the options
-- propose the unplanned booking's return; ML-3: a payout whose second debit waits unbooked → debit_pending
create or replace function pg_temp.f_f1_ml3() returns jsonb language plpgsql as $$
declare v_x uuid; v jsonb;
begin
  perform pg_temp.stmt2('f3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1')))));
  v_x := pg_temp.inflight('a4', '04', 40000, 'f-ml3');
  perform pg_temp.stmt2('f4', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('f4', 1), 'payout', v_x)));
  perform pg_temp.stmt2('f5', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(v_x)),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 32800, 'orig', pg_temp.e2e(v_x))));
  v := jsonb_build_object(
    'unplanned_open', pg_temp.bkx(pg_temp.l2('f3', 1), jsonb_build_array(pg_temp.pt('payout_returned',
                                                                                    pg_temp.v('x1'), 164000))),
    'proposed', pg_temp.prop(pg_temp.l2('f3', 1)) = jsonb_build_array(pg_temp.pt('unplanned_payout_returned',
                                                                                 pg_temp.v('x1'), 164000, null,
                                                                                 pg_temp.l2('b2', 1))),
    'debit_pending', pg_temp.bkx(pg_temp.l2('f5', 2), jsonb_build_array(pg_temp.pt('payout_returned', v_x, 32800))),
    'pending_line', pg_temp.op(pg_temp.l2('f5', 2)) ->> 'pending_line_id' = pg_temp.l2('f5', 1)::text,
    'd2', pg_temp.bkx(pg_temp.l2('f5', 1), pg_temp.prop(pg_temp.l2('f5', 1))),
    'then', pg_temp.prop(pg_temp.l2('f5', 2)) -> 0 ->> 'kind',
    'then_booked', pg_temp.bkx(pg_temp.l2('f5', 2), pg_temp.prop(pg_temp.l2('f5', 2))),
    'reowed', pg_temp.queued_minor('a4'), 'dirty', pg_temp.dirty());
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('f_f1_ml3'),
  '{"unplanned_open": "unplanned_open", "proposed": true, "debit_pending": "debit_pending", "pending_line": true,
    "d2": "ok", "then": "unplanned_payout_returned", "then_booked": "ok", "reowed": 0, "dirty": []}'::jsonb,
  'F (F1, ML-3): a return of a payout whose second execution was booked unplanned → unplanned_open, the options propose '
  'that booking''s return; a return whose second debit waits unbooked → debit_pending, the options name that line; once '
  'it is booked, the return is its unplanned return and nothing is owed again');
-- S20: a credit naming our lot of two booked payouts → two reversals on one line; the same lot's credit a fee short
create or replace function pg_temp.f_lot() returns jsonb language plpgsql as $$
declare v_5 uuid; v_6 uuid;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 'f-l5');
  v_6 := pg_temp.queued('a6', '06', 100000, 'f-l6');
  perform pg_temp.handed_out('fr', 'gen-f-lot');
  perform pg_temp.stmt2('f6', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  perform pg_temp.bk(pg_temp.l2('f6', 1), pg_temp.prop(pg_temp.l2('f6', 1)));
  perform pg_temp.stmt2('f7', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 106600, 'pmt', pg_temp.pmt(v_5)),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 106480, 'pmt', pg_temp.pmt(v_5))));
  return jsonb_build_object(
    'class', pg_temp.op(pg_temp.l2('f7', 1)) ->> 'class',
    'fee', pg_temp.bkx(pg_temp.l2('f7', 2), jsonb_build_array(pg_temp.pt('payout_returned', v_5, 24600),
                                                              pg_temp.pt('payout_returned', v_6, 82000),
                                                              pg_temp.pt('fee', null, 120))),
    'booked', pg_temp.bkx(pg_temp.l2('f7', 1), pg_temp.prop(pg_temp.l2('f7', 1))),
    'bookings', (select jsonb_agg(split_part(b, ' ', 2) || ' ' || split_part(b, ' ', 3)
                                  order by split_part(b, ' ', 3)::bigint)
                 from unnest(pg_temp.bookings(pg_temp.l2('f7', 1))) b),
    'seqs', (select jsonb_agg(split_part(b, ' ', 1)::integer order by split_part(b, ' ', 1)::integer)
             from unnest(pg_temp.bookings(pg_temp.l2('f7', 1))) b),
    'keys', pg_temp.keys(pg_temp.l2('f7', 1)),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('f_lot'),
  '{"class": "B", "fee": "fee_not_allowed", "booked": "ok",
    "bookings": ["payout_returned 24600", "payout_returned 82000"], "seqs": [1, 2],
    "keys": ["return:·:·", "return:·:·"],
    "dirty": []}'::jsonb,
  'F (S20; §1.3 item 12): a credit naming our lot of two booked payouts is the only subset of its returnable members: two '
  'reversals on one line, seq 1–2, one key per transfer; a fee on a lot → fee_not_allowed');
-- (review TESTS-8) a return dated before the debit it returns is refused, by its date: Lambert's payout booked today, its
-- return on yesterday's statement
create or replace function pg_temp.f_dates() returns jsonb language plpgsql as $$
declare v_x uuid;
begin
  v_x := pg_temp.inflight('a4', '04', 40000, 'f-dt');   -- 32 800
  perform pg_temp.stmt2('fa1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('fa1', 1), 'payout', v_x)));
  perform pg_temp.stmt2('fa2', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 32800, 'orig', pg_temp.e2e(v_x))));
  return jsonb_build_object(
    'x', pg_temp.status(v_x),
    'options', pg_temp.op(pg_temp.l2('fa2', 1)) ->> 'refusal',
    'command', pg_temp.bkx(pg_temp.l2('fa2', 1), jsonb_build_array(pg_temp.pt('payout_returned', v_x, 32800))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('f_dates'),
  '{"x": "booked", "options": "return_before_debit", "command": "return_before_debit"}'::jsonb,
  'F (review TESTS-8): a return dated before its payout''s debit entry → return_before_debit (options and command)');


-- G. Unplanned returns (plan §3.4.13, §3.12; critic F1, F11, L3, L4; critic2 ML-2, ML-11) ------------------------------
-- S03 then one copy back, flagged (the job reviewed it unplanned_payout_return): the unplanned booking's return — +A and
-- −(A − P), net +P = 0; the advance closed; the re-owed item monitored by no deadline; again → already_returned. An
-- unreferenced client's credit is refused; a flagged one from the IBAN (class N) books
create or replace function pg_temp.g_returns() returns jsonb language plpgsql as $$
declare v jsonb; v_rev uuid;
begin
  perform pg_temp.stmt2('9a', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1'))),
    jsonb_build_object('dir', 'credit', 'kind', 'client_transfer_in', 'amount', 164000, 'iban', pg_temp.iban('a1')),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'iban', pg_temp.iban('a1')),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('9a', 1), 'payout_returned', pg_temp.v('x1'))));
  v := jsonb_build_object(
    'reviewed', pg_temp.review(pg_temp.l2('9a', 1)),
    'unreferenced', pg_temp.bkx(pg_temp.l2('9a', 2), jsonb_build_array(pg_temp.pt('unplanned_payout_returned',
                                                                                  pg_temp.v('x1'), 164000, null,
                                                                                  pg_temp.l2('b2', 1)))),
    'flagged_n_proposed', pg_temp.prop(pg_temp.l2('9a', 3)) = jsonb_build_array(pg_temp.pt(
                            'unplanned_payout_returned', pg_temp.v('x1'), 164000, null, pg_temp.l2('b2', 1))),
    'open_before', pg_temp.alerts('double_payout_open'),
    'funds_before', pg_temp.funds_msgs(),
    'booked', pg_temp.bkx(pg_temp.l2('9a', 1), pg_temp.prop(pg_temp.l2('9a', 1))));
  v_rev := (select r.id from public.ledger_entry r
            where r.reverses_entry_id = pg_temp.ek('remit:line:' || pg_temp.l2('b2', 1) || ':1'));
  return v || jsonb_build_object(
    'funds_queued', pg_temp.funds_msgs() - (v ->> 'funds_before')::bigint,
    'queue', pg_temp.queued_minor('a1'),
    'pending', (select jsonb_agg(q.kind || ':' || q.amount_minor order by q.kind) from private.remittance_pending q
                where q.ledger_entry_id = v_rev
                   or q.ledger_entry_id = (select r.id from public.ledger_entry r where r.reverses_entry_id =
                                           pg_temp.ek('adv:line:' || pg_temp.l2('b2', 1) || ':1'))),
    'deadline_rows', (select count(*) from private.pending_item_deadlines('00000000-0000-0000-0000-0000000000aa') d
                      where d.ledger_entry_id = v_rev),
    'open_after', pg_temp.alerts('double_payout_open'),
    'again', pg_temp.bkx(pg_temp.l2('9a', 4), jsonb_build_array(pg_temp.pt('unplanned_payout_returned',
                                                                           pg_temp.v('x1'), 164000, null,
                                                                           pg_temp.l2('b2', 1)))),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('g_returns') - 'open_before' - 'funds_before',
  '{"reviewed": "unplanned_payout_return", "unreferenced": "not_its_line", "flagged_n_proposed": true,
    "booked": "ok", "funds_queued": 1, "queue": 0,
    "pending": ["client_advance_reversal:-164000", "payout_returned:164000"], "deadline_rows": 0, "open_after": [],
    "again": "already_returned", "dirty": []}'::jsonb,
  'G (S28, F1, F11, L3, ML-11, CSO2-7): the copy that comes back of a payout executed twice (the job reviewed it '
  'unplanned_payout_return) is booked as the unplanned booking''s return — +A and −(A − P) queued, net 0, the advance '
  'closed (double_payout_open gone), the re-owed item under no deadline, the funds pass queued; an unreferenced client''s '
  'credit → not_its_line; a flagged return from the IBAN without our reference is proposed the same booking; again → '
  'already_returned');
-- ML-11, the client part (S13) and its flagged return without our reference; two open bookings of one transfer: only
-- the largest advance's (ties: the earliest line) is accepted; an advance settled → advance_settled
create or replace function pg_temp.g_client_and_order() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.stmt2('9b', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 5000, 'kind', 'other_debit', 'iban', pg_temp.iban('a3')),
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1')))));
  perform pg_temp.bk(pg_temp.l2('9b', 1), pg_temp.prop(pg_temp.l2('9b', 1)));
  perform pg_temp.bk(pg_temp.l2('9b', 2), pg_temp.prop(pg_temp.l2('9b', 2)));
  perform pg_temp.stmt2('9c', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 5000, 'iban', pg_temp.iban('a3')),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1')))));
  v := jsonb_build_object(
    'client_proposed', pg_temp.prop(pg_temp.l2('9c', 1)) = jsonb_build_array(pg_temp.pt(
                         'unplanned_payout_returned', null, 5000, pg_temp.c('a3'), pg_temp.l2('9b', 1))),
    'later_named', pg_temp.bkx(pg_temp.l2('9c', 2), jsonb_build_array(pg_temp.pt('unplanned_payout_returned',
                                                                                 pg_temp.v('x1'), 164000, null,
                                                                                 pg_temp.l2('9b', 2)))),
    'earliest_proposed', pg_temp.prop(pg_temp.l2('9c', 2)) -> 0 ->> 'returns_line_id'
                         = pg_temp.l2('b2', 1)::text);
  insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id,
                                            entry_id, kind, amount_minor, vat_moved_minor, settled_on, run_id)
  select '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'), 'advance', a.id,
         pg_temp.ek('adv:line:' || pg_temp.l2('b2', 1) || ':1'), 'compensation', 100, 0, private.paris_today(),
         pg_temp.v('r1')
  from public.client_advance a where a.cause_entry_id = pg_temp.ek('remit:line:' || pg_temp.l2('b2', 1) || ':1');
  v := v || jsonb_build_object(
    'settled', pg_temp.bkx(pg_temp.l2('9c', 2), jsonb_build_array(pg_temp.pt('unplanned_payout_returned',
                                                                          pg_temp.v('x1'), 164000, null,
                                                                          pg_temp.l2('b2', 1)))),
    'settled_options', pg_temp.op(pg_temp.l2('9c', 2)) ->> 'refusal',
    'client_booked', pg_temp.bkx(pg_temp.l2('9c', 1), pg_temp.prop(pg_temp.l2('9c', 1))));
  return v || jsonb_build_object(
    'client_advance_open', (select count(*) from public.ledger_entry r
                            where r.reverses_entry_id = pg_temp.ek('adv:line:' || pg_temp.l2('9b', 1) || ':1')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('g_client_and_order'),
  '{"client_proposed": true, "later_named": "return_differs", "earliest_proposed": true,
    "settled": "advance_settled", "settled_options": "advance_settled", "client_booked": "ok",
    "client_advance_open": 1}'::jsonb,
  'G (ML-11, F1): a client part''s flagged return from its IBAN without our reference is proposed and booked as its '
  'return (its advance reversed); of two open unplanned bookings of x1 of equal advances, only the earliest line''s is '
  'accepted (return_differs) and proposed; an advance with a settlement → advance_settled');
-- (ML-2) x booked and returned (ρ), executed again: P = A on ρ; the client's net-0 draft approved and booked at approval,
-- ρ frozen in its line; then the second copy returned: the re-owed item is held to ρ's line's date (the third branch)
create or replace function pg_temp.g_ml2() returns jsonb language plpgsql as $$
declare v_x uuid; v_d uuid; v_rho uuid; v_rev uuid; v jsonb;
begin
  v_x := pg_temp.inflight('a7', '07', 50000, 'g-ml2');   -- 41 000
  perform pg_temp.stmt2('da', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('da', 1), 'payout', v_x)));
  perform pg_temp.stmt2('db', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('db', 1), 'payout_returned', v_x)));
  v_rho := (select return_entry_id from public.bank_transfer where id = v_x);
  v_d := pg_temp.request('a7', 'g-ml2-draft');
  perform pg_temp.stmt2('dc', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x)),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.bk(pg_temp.l2('dc', 1), pg_temp.prop(pg_temp.l2('dc', 1)));
  perform pg_temp.prepare_plain(v_d);
  v := jsonb_build_object('approved', pg_temp.approve_plain(v_d, 'g-ml2-draft'));
  -- the date the planned branch would hold ρ to: its frozen line's E and delay (a month: no mandate on this emulated
  -- line)
  v := v || jsonb_build_object('frozen', (select d.latest_execution_date
                                          from public.remittance_line l
                                          cross join lateral private.remittance_deadline_or_null(l.encaissement_date, 30) d
                                          where l.ledger_entry_id = v_rho and not l.released));
  perform pg_temp.bk(pg_temp.l2('dc', 2), pg_temp.prop(pg_temp.l2('dc', 2)));
  v_rev := (select r.id from public.ledger_entry r
            where r.reverses_entry_id = pg_temp.ek('remit:line:' || pg_temp.l2('dc', 1) || ':1'));
  return v || jsonb_build_object(
    'held_to', (select d.latest_execution_date from private.pending_item_deadlines('00000000-0000-0000-0000-0000000000aa') d
                where d.ledger_entry_id = v_rev),
    'monitored', (select d.monitored from private.pending_item_deadlines('00000000-0000-0000-0000-0000000000aa') d
                  where d.ledger_entry_id = v_rev),
    'queue', pg_temp.queued_minor('a7'), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is((select jsonb_build_array(v ->> 'approved', v ->> 'held_to' is not null,
                                    (v ->> 'held_to') = (v ->> 'frozen'), v -> 'queue', v -> 'dirty')
           from (select pg_temp.isolated('g_ml2') v) w),
  '["booked:booked", true, true, 41000, []]'::jsonb,
  'G (ML-2): a payout booked, returned and executed again (P = A on its return item), its client''s net-0 run approved '
  'and booked, then the second copy returned: the re-owed item is held to the frozen return item''s line date '
  '(pending_item_deadlines'' third branch: its E and delay)');
-- (review TESTS-8) an unplanned booking's return dated before its unplanned entry: S03 booked today (the base), x1's copy
-- back on yesterday's statement
create or replace function pg_temp.g_dates() returns jsonb language plpgsql as $$
begin
  perform pg_temp.stmt2('9d', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1')))));
  return jsonb_build_object(
    'options', pg_temp.op(pg_temp.l2('9d', 1)) ->> 'refusal',
    'command', pg_temp.bkx(pg_temp.l2('9d', 1), jsonb_build_array(pg_temp.pt('unplanned_payout_returned',
                                                                             pg_temp.v('x1'), 164000, null,
                                                                             pg_temp.l2('b2', 1)))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('g_dates'), '{"options": "return_before_debit", "command": "return_before_debit"}'::jsonb,
  'G (review TESTS-8, §3.4.13 rule 5): an unplanned booking''s return dated before its unplanned entry → '
  'return_before_debit (options and command)');
-- (review LT-2, critic L4) the client's statement: the item an unplanned payout's return re-owes is « Virement exécuté hors
-- reversement revenu » (nature_reason unplanned), never « Virement revenu impayé — reversé à nouveau »; a planned return
-- keeps its nature. Martin's next run holds S03's −A row and advance (the base) and the return's +A and −A: net 0,
-- booked at its approval
create or replace function pg_temp.g_statement() returns jsonb language plpgsql as $$
declare v_d uuid; v_p jsonb; v_x uuid; v_e uuid; k integer; r integer; v jsonb;
begin
  perform pg_temp.stmt2('9e', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1')))));
  perform pg_temp.bk(pg_temp.l2('9e', 1), pg_temp.prop(pg_temp.l2('9e', 1)));
  v_d := pg_temp.request('a1', 'g-st-a1');
  perform pg_temp.prepare_plain(v_d);
  v := jsonb_build_object('approved', pg_temp.approve_plain(v_d, 'g-st-a1'));
  v_p := private.remittance_statement_build(v_d);
  select (x.o - 1)::integer into k from jsonb_array_elements_text(v_p -> 'line_columns') with ordinality x (c, o)
  where x.c = 'nature';
  select (x.o - 1)::integer into r from jsonb_array_elements_text(v_p -> 'line_columns') with ordinality x (c, o)
  where x.c = 'nature_reason';
  v := v || jsonb_build_object(
    'unplanned', (select jsonb_agg(jsonb_build_array(l ->> k, l ->> r) order by l ->> k) from jsonb_array_elements(v_p -> 'lines') l),
    'natures', (select jsonb_agg(jsonb_build_array(n ->> 'kind', n ->> 'reason') order by n ->> 'kind')
                from jsonb_array_elements(v_p -> 'natures') n));
  -- a planned return: Lambert's payout booked, returned, its item in Lambert's next run
  v_x := pg_temp.inflight('a4', '04', 40000, 'g-st');
  perform pg_temp.stmt2('9f', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('9f', 1), 'payout', v_x)));
  perform pg_temp.stmt2('a0', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 32800, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('a0', 1), 'payout_returned', v_x)));
  perform pg_temp.reconfirm('a4');
  v_d := pg_temp.request('a4', 'g-st-a4');
  perform pg_temp.prepare_plain(v_d);
  perform pg_temp.approve_plain(v_d, 'g-st-a4');
  v_p := private.remittance_statement_build(v_d);
  return v || jsonb_build_object(
    'planned', (select jsonb_agg(jsonb_build_array(l ->> k, l ->> r)) from jsonb_array_elements(v_p -> 'lines') l));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('g_statement'),
  '{"approved": "booked:booked",
    "unplanned": [["client_advance", null], ["client_advance_reversal", null], ["payout_returned", "unplanned"],
                  ["unplanned_payout", null]],
    "natures": [["client_advance", null], ["client_advance_reversal", null], ["payout_returned", "unplanned"],
                ["unplanned_payout", null]],
    "planned": [["payout_returned", null]]}'::jsonb,
  'G (review LT-2, L4): the item an unplanned payout''s return re-owes is marked unplanned on the client''s statement '
  '(its line and its nature total), so it is worded « Virement exécuté hors reversement revenu »; a planned return''s '
  'item is not');
select is(pg_temp.dirty(), '{}'::text[], 'E, F, G: clean');


-- H. Unsplit entries (plan §3.4.12; critic F8, F7, L11; critic2 ML-5, CSO2-3) -----------------------------------------
create or replace function pg_temp.h_unsplit() returns jsonb language plpgsql as $$
declare v_4 uuid; v_5 uuid; v_9 uuid; v_6 uuid;
  d_net jsonb; v jsonb;
begin
  v_4 := pg_temp.queued('a4', '04', 40000, 'h-4');     -- 32 800
  v_5 := pg_temp.queued('a5', '05', 30000, 'h-5');     -- 24 600
  v_9 := pg_temp.queued('a9', '09', 30000, 'h-9');     -- 24 600
  v_6 := pg_temp.queued('a6', '06', 100000, 'h-6');    -- 82 000
  perform pg_temp.handed_out('fu', 'gen-h-unsplit');
  -- the round-5 netted credit: x1 coming back (164 000) netted with t4's debit (32 800): one credit of 131 200
  d_net := jsonb_build_array(jsonb_build_object('id', pg_temp.e2e(pg_temp.v('x2')), 'direction', 'credit',
                                                'amount_minor', '419840'),
                             jsonb_build_object('id', pg_temp.e2e(v_4), 'direction', 'debit', 'amount_minor', '32800'));
  perform pg_temp.stmt2('8a', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('x2')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('8a', 1), 'payout', pg_temp.v('x2'))));
  perform pg_temp.stmt2('8b', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 387040, 'unsplit', 2, 'count', 2, 'nb', 2,
                       'details', d_net),
    jsonb_build_object('amount', 49200, 'kind', 'batch_unsplit', 'unsplit', 2, 'count', 2,
                       'details', jsonb_build_array(
                         jsonb_build_object('id', pg_temp.e2e(v_5), 'direction', 'debit', 'amount_minor', '24600'),
                         jsonb_build_object('id', pg_temp.e2e(v_6), 'direction', 'debit', 'amount_minor', '24600'))),
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'unsplit', 2, 'count', 2,
                       'details', jsonb_build_array(
                         jsonb_build_object('id', pg_temp.e2e(v_5), 'direction', 'debit', 'amount_minor', '24600'),
                         jsonb_build_object('id', pg_temp.e2e(v_6), 'direction', 'debit', 'amount_minor', '82000'))),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 30000, 'unsplit', 1, 'count', 1,
                       'details', jsonb_build_array(jsonb_build_object('id', pg_temp.e2e(v_4),
                                                                       'direction', 'credit',
                                                                       'amount_minor', '32800'))),
    jsonb_build_object('amount', 24600, 'kind', 'batch_unsplit', 'unsplit', 1),
    jsonb_build_object('amount', 24600, 'kind', 'batch_unsplit', 'unsplit', 1, 'count', 1,
                       'details', jsonb_build_array(jsonb_build_object('id', pg_temp.e2e(v_9), 'direction', 'debit',
                                                                       'amount_minor', null))),
    jsonb_build_object('amount', 24600, 'kind', 'batch_unsplit', 'unsplit', 1, 'count', 1,
                       'details', jsonb_build_array(jsonb_build_object('id', 'RFD000000000AB1', 'direction', 'debit',
                                                                       'amount_minor', '24600'))),
    jsonb_build_object('amount', 24600, 'kind', 'batch_unsplit', 'unsplit', 1, 'count', 3,
                       'details', jsonb_build_array(jsonb_build_object('id', pg_temp.e2e(v_9), 'direction', 'debit',
                                                                       'amount_minor', '24600'))),
    jsonb_build_object('amount', 24600, 'kind', 'batch_unsplit', 'unsplit', 1, 'count', 1, 'nb', 3,
                       'details', jsonb_build_array(jsonb_build_object('id', pg_temp.e2e(v_9), 'direction', 'debit',
                                                                       'amount_minor', '24600'))),
    jsonb_build_object('amount', 501, 'kind', 'batch_unsplit', 'unsplit', 501, 'count', 501,
                       'details', (select jsonb_agg(jsonb_build_object('id', 'RMT' || lpad(to_hex(g), 12, '0'),
                                                                       'direction', 'debit', 'amount_minor', '1'))
                                   from generate_series(1, 501) g))));
  v := jsonb_build_object(
    'netted', (select jsonb_agg(p ->> 'kind' || ':' || (p ->> 'amount') order by p ->> 'kind')
               from jsonb_array_elements(pg_temp.prop(pg_temp.l2('8b', 1))) p),
    'netted_booked', pg_temp.bkx(pg_temp.l2('8b', 1), pg_temp.prop(pg_temp.l2('8b', 1))),
    'netted_states', jsonb_build_array(pg_temp.status(pg_temp.v('x2')), pg_temp.status(v_4)),
    'parts_differ', pg_temp.bkx(pg_temp.l2('8b', 3), jsonb_build_array(pg_temp.pt('payout', v_9, 24600),
                                                                       pg_temp.pt('payout', v_6, 82000))),
    'd03', pg_temp.bkx(pg_temp.l2('8b', 3), pg_temp.prop(pg_temp.l2('8b', 3))),
    'chargeback', pg_temp.bkx(pg_temp.l2('8b', 4), jsonb_build_array(pg_temp.pt('payout_returned', v_4, 32800))),
    'chargeback_fee', pg_temp.bkx(pg_temp.l2('8b', 4), jsonb_build_array(pg_temp.pt('payout_returned', v_4, 32800),
                                                                         pg_temp.pt('fee', null, 2800))),
    'before_2a', pg_temp.op(pg_temp.l2('8b', 5)) ->> 'refusal',
    'no_amount', pg_temp.bkx(pg_temp.l2('8b', 6), jsonb_build_array(pg_temp.pt('payout', v_9, 24600))),
    'refund_detail', pg_temp.op(pg_temp.l2('8b', 7)) ->> 'refusal',
    'not_all_ours', pg_temp.bkx(pg_temp.l2('8b', 8), jsonb_build_array(pg_temp.pt('payout', v_9, 24600))),
    'not_all_ours_options', pg_temp.op(pg_temp.l2('8b', 8)) -> 'proposals',
    'nb_differs', pg_temp.bkx(pg_temp.l2('8b', 9), jsonb_build_array(pg_temp.pt('payout', v_9, 24600))),
    'too_large', jsonb_build_array(pg_temp.op(pg_temp.l2('8b', 10)) ->> 'refusal',
                                   pg_temp.why(pg_temp.l2('8b', 10), jsonb_build_array(pg_temp.pt('fee', null, 501))),
                                   pg_temp.bkx(pg_temp.l2('8b', 10), jsonb_build_array(pg_temp.pt('fee', null, 501)))),
    'dirty', pg_temp.dirty());
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('h_unsplit'),
  '{"netted": ["payout:32800", "payout_returned:419840"], "netted_booked": "ok", "netted_states": ["returned", "booked"],
    "parts_differ": "unsplit_parts_differ", "d03": "ok", "chargeback": "parts_do_not_add_up",
    "chargeback_fee": "fee_not_allowed", "before_2a": "unsplit_detail_missing", "no_amount": "unsplit_detail_missing",
    "refund_detail": "unsplit_not_bookable", "not_all_ours": "unsplit_not_bookable", "not_all_ours_options": [],
    "nb_differs": "unsplit_not_bookable", "too_large": ["lot_too_large", "lot_too_large", "lot_too_large"],
    "dirty": []}'::jsonb,
  'H (S21/S22; F8, F7, ML-5, CSO2-3): an entry kept unsplit is booked only from the statement''s own details — the '
  'netted credit (a return and a debit of ours) and two debits of ours, proposed and booked; other transfers named → '
  'unsplit_parts_differ; a chargeback inside → parts_do_not_add_up, and with a fee → fee_not_allowed; no details (before '
  '6b-2a) or a detail without amount → unsplit_detail_missing; a refund''s detail, a detail not ours in the entry, an '
  'NbOfTxs that differs → unsplit_not_bookable, no proposal; 501 details → lot_too_large (options, preview, command)');
-- (review money-1) an entry the bank kept unsplit holding no detail of ours (unsplit_ours 0, a detail count) is never
-- booked as one movement: two details that do not add up of x2's amount (in flight: rule 3b's one candidate), NbOfTxs 2
-- with one detail to Cyprès' payout IBAN (a client part), a flagged credit of NbOfTxs 2 from Martin's IBAN at S03's
-- amount (the open unplanned booking's return) — as the job (batch_partial, return_differs)
create or replace function pg_temp.h_not_ours() returns jsonb language plpgsql as $$
begin
  perform pg_temp.exec_on(pg_temp.v('fa'), private.paris_today() - 1);
  perform pg_temp.stmt2('8c', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'kind', 'batch_unsplit', 'unsplit', 0, 'count', 2, 'details', '[]'::jsonb),
    jsonb_build_object('amount', 50000, 'kind', 'batch_unsplit', 'unsplit', 0, 'count', 1, 'nb', 2,
                       'details', '[]'::jsonb, 'iban', pg_temp.iban('a3')),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'unsplit', 0, 'count', 1, 'nb', 2,
                       'details', '[]'::jsonb, 'iban', pg_temp.iban('a1'))));
  return jsonb_build_object(
    'classes', (select jsonb_agg(pg_temp.op(pg_temp.l2('8c', k)) ->> 'class' order by k) from generate_series(1, 3) k),
    'options', (select jsonb_agg(pg_temp.op(pg_temp.l2('8c', k)) ->> 'refusal' order by k) from generate_series(1, 3) k),
    'proposals', (select jsonb_agg(jsonb_array_length(pg_temp.op(pg_temp.l2('8c', k)) -> 'proposals') order by k)
                  from generate_series(1, 3) k),
    'payout', pg_temp.bkx(pg_temp.l2('8c', 1), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'), 419840))),
    'client', pg_temp.bkx(pg_temp.l2('8c', 2), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 50000,
                                                                            pg_temp.c('a3')))),
    'returned', pg_temp.bkx(pg_temp.l2('8c', 3), jsonb_build_array(pg_temp.pt('unplanned_payout_returned',
                                                                              pg_temp.v('x1'), 164000, null,
                                                                              pg_temp.l2('b2', 1)))),
    'x2', pg_temp.status(pg_temp.v('x2')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('h_not_ours'),
  '{"classes": ["N", "N", "N"],
    "options": ["unsplit_not_bookable", "unsplit_not_bookable", "unsplit_not_bookable"], "proposals": [0, 0, 0],
    "payout": "unsplit_not_bookable", "client": "unsplit_not_bookable", "returned": "unsplit_not_bookable",
    "x2": "in_file"}'::jsonb,
  'H (review money-1): an entry kept unsplit holding no detail of ours is never booked as one movement — not as rule '
  '3b''s one payout, not as a client''s double-payout advance, not as an unplanned payout''s return: '
  'unsplit_not_bookable, no proposal');
-- (review money-1) our lot kept unsplit: booked as its only subset only when the bank's count of its transactions, when
-- it gives one (NbOfTxs, its details), is the subset's
create or replace function pg_temp.h_lot_unsplit() returns jsonb language plpgsql as $$
declare v_5 uuid; v_6 uuid;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 'h-lu5');   -- 24 600
  v_6 := pg_temp.queued('a6', '06', 100000, 'h-lu6');  -- 82 000
  perform pg_temp.handed_out('fhl', 'gen-h-lu');
  perform pg_temp.stmt2('8d', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5), 'unsplit', 0, 'count', 0,
                       'nb', 3, 'details', '[]'::jsonb),
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5), 'unsplit', 0, 'count', 3,
                       'details', '[]'::jsonb),
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5), 'unsplit', 0, 'count', 0,
                       'nb', 2, 'details', '[]'::jsonb)));
  return jsonb_build_object(
    'nb_differs', jsonb_build_array(pg_temp.op(pg_temp.l2('8d', 1)) ->> 'refusal',
                                    pg_temp.bkx(pg_temp.l2('8d', 1), jsonb_build_array(pg_temp.pt('payout', v_5, 24600),
                                                                                       pg_temp.pt('payout', v_6, 82000)))),
    'details_differ', jsonb_build_array(pg_temp.op(pg_temp.l2('8d', 2)) ->> 'refusal',
                                        pg_temp.bkx(pg_temp.l2('8d', 2), jsonb_build_array(
                                          pg_temp.pt('payout', v_5, 24600), pg_temp.pt('payout', v_6, 82000)))),
    'booked', pg_temp.bkx(pg_temp.l2('8d', 3), pg_temp.prop(pg_temp.l2('8d', 3))))
    || jsonb_build_object('bookings', (select jsonb_agg(split_part(b, ' ', 2) || ' ' || split_part(b, ' ', 3)
                                                        order by split_part(b, ' ', 3)::bigint)
                                       from unnest(pg_temp.bookings(pg_temp.l2('8d', 3))) b));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('h_lot_unsplit'),
  '{"nb_differs": ["unsplit_not_bookable", "unsplit_not_bookable"],
    "details_differ": ["unsplit_not_bookable", "unsplit_not_bookable"], "booked": "ok",
    "bookings": ["payout 24600", "payout 82000"]}'::jsonb,
  'H (review money-1): our lot kept unsplit whose NbOfTxs, or whose details'' count, is not its only subset''s → '
  'unsplit_not_bookable (options and command); with NbOfTxs the subset''s, it is booked as that subset');


-- I. Compare and set (plan §3.9; critic CSO-12) -------------------------------------------------------------------------
create or replace function pg_temp.i_split() returns jsonb language plpgsql as $$
declare v_text text; v_text2 text;
begin
  perform pg_temp.stmt2('7a', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1'))),
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1')))));
  v_text := pg_temp.pv(pg_temp.l2('7a', 1), pg_temp.s03()) ->> 'expected_text';
  -- a draft created in between (Martin collects again, and ops prepare now)
  perform pg_temp.file('15', '20000000-0000-0000-0000-0000000000a1', 10000);
  perform pg_temp.collect('15', 10000, private.paris_today());
  perform pg_temp.request('a1', 'i-draft');
  v_text2 := pg_temp.pv(pg_temp.l2('7a', 2), pg_temp.s03()) ->> 'expected_text';
  -- (CSO-12) the check under the locks with a live draft the locks did not take
  perform private.transfer_line_parse(pg_temp.s03());
  perform private.transfer_line_pre(pg_temp.l2('7a', 2));
  drop table if exists pg_temp._tl_locked_runs;
  create temp table _tl_locked_runs (run_id uuid primary key) on commit drop;
  return jsonb_build_object(
    'stale', pg_temp.bkx(pg_temp.l2('7a', 1), pg_temp.s03(), 'key-split-1', '01', v_text),
    'text_names_draft', v_text2 like '%|drafts:' || (select id from public.remittance_run
                                                     where client_organization_id = pg_temp.c('a1')
                                                       and status = 'draft')::text,
    'not_locked', private.transfer_line_check(pg_temp.l2('7a', 2), true) ->> 'why',
    'fresh', pg_temp.bkx(pg_temp.l2('7a', 2), pg_temp.s03(), 'key-split-2', '01', v_text2));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('i_split'),
  '{"stale": "split_changed", "text_names_draft": true, "not_locked": "split_changed", "fresh": "ok"}'::jsonb,
  'I (§3.9, CSO-12): a draft created between the preview and the command → split_changed (the text names the draft to '
  're-prepare); a live draft the locks did not take → split_changed under the locks; the fresh text books');


-- K. The booking guard (plan §3.12), as the service role would write -----------------------------------------------------
create or replace function pg_temp.k_guard(p_case text) returns text language plpgsql as $$
declare v_e uuid; v_line uuid;
begin
  perform pg_temp.stmt2('6a', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('x2'))),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 1000, 'orig', 'BANK-OTHER')));
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason)
  select 1, '00000000-0000-0000-0000-0000000000aa', case p_case when 'payout_on_credit' then 'remittance'
                                                                else 'bank_fee' end,
         private.paris_today(), 'k-' || p_case, case when p_case = 'payout_on_credit' then pg_temp.c('a2') end,
         case when p_case = 'payout_on_credit' then 'bank_transfer' else 'bank_transaction' end,
         case when p_case = 'payout_on_credit' then pg_temp.v('x2')::text
              else pg_temp.l2('6a', case p_case when 'fee_alone' then 1 else 2 end)::text end, 'test';
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
  select 1, v.n, v.book, v.amount, 'EUR', case when v.book = 'client_money_cash'
                                                then '80000000-0000-0000-0000-0000000000cf'::uuid end
  from (values (1, case p_case when 'payout_on_credit' then 'client_payable' else 'due_to_servicer' end, 1000),
               (2, 'client_money_cash', -1000)) v (n, book, amount)
  union all
  select 1, v.n, v.book, v.amount, 'EUR', null
  from (values (3, 'bank_fees', 1000), (4, 'due_from_client_funds', -1000)) v (n, book, amount)
  where p_case <> 'payout_on_credit';
  v_e := (select x.entry_id from private.ledger_post_set() x);
  v_line := pg_temp.l2('6a', case p_case when 'fee_alone' then 1 else 2 end);
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method)
  values (v_line, 1, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
          case p_case when 'fee_alone' then 'fee' when 'payout_on_credit' then 'payout'
                      else 'unplanned_payout_returned' end,
          case when p_case = 'payout_on_credit' then pg_temp.v('x2') end, v_e, 1000, 'auto');
  set constraints public.bank_line_booking_complete immediate;
  return 'accepted';
exception when others then
  return sqlstate || ' ' || split_part(sqlerrm, ':', 1);
end $$;
select is(array[pg_temp.k_guard('fee_alone'), pg_temp.k_guard('unplanned_return'), pg_temp.k_guard('payout_on_credit')],
          array['LG001 bank line ' || pg_temp.l2('6a', 1), '23514 bank line booking ' || pg_temp.l2('6a', 2),
                '23514 bank line booking ' || pg_temp.l2('6a', 2)],
  'K (§3.12): a fee on our RMT line alone fails the line''s completeness (LG001) — the guard now admits a fee on a '
  'transfer_out; an unplanned_payout_returned row not reversing an unplanned booking''s entry, and a payout on a credit '
  'line not kept unsplit, are refused by the guard (check_violation)');


-- (§3.12) the guard's own rules beside the command's: an unplanned_payout_returned row on a reversal of a planned
-- payout's remittance (not an unplanned booking's), and a payout on a credit batch line holding nothing of ours
create or replace function pg_temp.k_guard2(p_case text) returns text language plpgsql as $$
declare v_e uuid; v_rev uuid;
begin
  perform pg_temp.stmt2('6b', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('x2'))),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 419840, 'orig', pg_temp.e2e(pg_temp.v('x2'))),
    jsonb_build_object('dir', 'credit', 'kind', 'batch_unsplit', 'amount', 419840, 'unsplit', 0, 'count', 2,
                       'details', '[]'::jsonb)));
  if p_case = 'unplanned_return_of_planned' then
    perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('6b', 1), 'payout', pg_temp.v('x2'))));
    v_e := (select entry_id from public.bank_transfer where id = pg_temp.v('x2'));
    v_rev := (select x.entry_id from private.ledger_reverse(v_e, 'k-rev-planned', 'test', private.paris_today()) x);
    insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind,
                                          transfer_id, entry_id, amount_minor, method)
    values (pg_temp.l2('6b', 2), 1, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
            'unplanned_payout_returned', pg_temp.v('x2'), v_rev, 419840, 'auto');
  else
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                    client_organization_id, source_type, source_id, reason)
    values (1, '00000000-0000-0000-0000-0000000000aa', 'remittance', private.paris_today(), 'k-batch-credit',
            pg_temp.c('a2'), 'bank_transfer', pg_temp.v('x2')::text, 'test');
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
      (1, 1, 'client_payable', 419840, 'EUR', null),
      (1, 2, 'client_money_cash', -419840, 'EUR', '80000000-0000-0000-0000-0000000000cf');
    v_e := (select x.entry_id from private.ledger_post_set() x);
    insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind,
                                          transfer_id, entry_id, amount_minor, method)
    values (pg_temp.l2('6b', 3), 1, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
            'payout', pg_temp.v('x2'), v_e, 419840, 'auto');
  end if;
  set constraints public.bank_line_booking_complete immediate;
  return 'accepted';
exception when others then
  return sqlstate || ' ' || split_part(sqlerrm, ':', 1);
end $$;
select is(array[pg_temp.k_guard2('unplanned_return_of_planned'), pg_temp.k_guard2('payout_on_credit_batch')],
          array['23514 bank line booking ' || pg_temp.l2('6b', 2), '23514 bank line booking ' || pg_temp.l2('6b', 3)],
  'K (§3.12): the guard refuses an unplanned_payout_returned row on a reversal of a planned payout''s remittance (the '
  'reversed booking is not unplanned), and a payout on a credit batch line holding nothing of ours (check_violation)');


-- L. Alerts: a P0 alert ends once its line is booked -------------------------------------------------------------------
create or replace function pg_temp.l_alerts() returns jsonb language plpgsql as $$
declare v_before boolean;
begin
  perform pg_temp.stmt2('5a', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 6000, 'kind', 'transfer_out', 'e2e', 'RMT0000000000EF', 'iban', pg_temp.iban('a3'))));
  perform pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.l2('5a', 1),
                                                                  'reason', 'transfer_unknown')));
  v_before := pg_temp.alerts('transfer_unknown')::text like '%' || pg_temp.l2('5a', 1) || '%';
  perform pg_temp.bk(pg_temp.l2('5a', 1), pg_temp.prop(pg_temp.l2('5a', 1)));
  return jsonb_build_object('before', v_before,
                            'after', pg_temp.alerts('transfer_unknown')::text like '%' || pg_temp.l2('5a', 1) || '%',
                            'review', pg_temp.review(pg_temp.l2('5a', 1)));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('l_alerts'), '{"before": true, "after": false, "review": null}'::jsonb,
  'L: the P0 transfer_unknown of a line carrying an RMT-shaped id ends once ops book it (its review deleted)');
select is(pg_temp.dirty(), '{}'::text[], 'H, I, K, L: clean');
select is(private.switch_on('downloaded_file_cancellation'), false, 'and the switch is off (033 and 034 unchanged)');

select * from finish();
rollback;
