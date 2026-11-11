-- M2c-6a review fixes, round 3 (the skeptics' scenarios N1–N6 of round 2; design §9.7, §11, §12; ADR-0014 « M2c-6a
-- review fixes », round 3; COMPLIANCE OQ-80). 028 holds the slice's cases, 029 the first review's, 030 the second's;
-- this file the third round's:
--   * E1 a downloaded file cancelled whole has its payouts and refunds re-issued as new transfers under fresh
--     end-to-end ids (the old ones cancelled, the run's and the refund's transfer repointed, a `replaces` link kept;
--     the sweep recomputed as before): an old id then belongs only to a cancelled transfer, and a file's evidence reads
--     only the transfers it holds (N3);
--   * E2 a transfer is debited already when it, or a predecessor in its chain, shows a debit of its own end-to-end id,
--     or a batch line of an earlier downloaded file's PmtInf that can contain it: held, alerted, and its run or refund
--     not cancelled (N1, N2);
--   * E3 a transfer of a batch whose return is seen was in the batch: it stays in the sum once cancelled and stands in
--     for no other (N4, N5);
--   * E4 a camt.053 covers a day only once the bank produced it after that day (Stmt/CreDtTm kept; N6).
-- No ledger entry is posted by any of it.
begin;
select plan(38);



-- Fixtures (as 028: Martin (a1), Lilas (a2), Cyprès (a3), Omega (a4: a RIB holder in Greek letters), Tunis Trading
-- (a5: a Tunisian IBAN) of the servicer aa; Bleu (b1) of another servicer bb) --------------------------------------
insert into public.organization (id, kind, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo SAS', '732829320'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Autre cabinet SAS', null);
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Martin SAS',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Lilas Finance',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000a3', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Cyprès SA',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000a4', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Omega AE',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000a5', 'creditor_client', '00000000-0000-0000-0000-0000000000aa',
   'Tunis Trading SARL', '552100554'),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Bleu SARL', null);
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@files.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11', '12', '13']) n;
update public.app_user set display_name = 'Léa' where id = '10000000-0000-0000-0000-000000000001';
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000bb', 'admin'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a1', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000a2', 'client_admin'),
  ('10000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-0000000000aa', 'ops_manager');
insert into public.portfolio (id, organization_id, client_organization_id, name)
select ('20000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'P' || c
from unnest(array['a1', 'a2', 'a3', 'a4', 'a5']) c;
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-0000000000a1');
insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000cf', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
   'FR3430001007940000000001001', 'TESTFRPPXXX', 'EUR', 'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000c0', '00000000-0000-0000-0000-0000000000aa', 'own',
   'FR7610107001011234567890129', null, 'EUR', 'Compte propre', null, '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000bf', '00000000-0000-0000-0000-0000000000bb', 'client_funds',
   'FR7630006000011234567890189', null, 'EUR', 'Fonds de tiers B', 'camt053', '2026-01-01');
insert into public.servicer_billing_settings (organization_id, own_bank_account_id)
values ('00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000c0');
insert into public.billing_identity (organization_id, legal_form, share_capital_minor, rcs_city, registered_office,
                                     vat_number, is_professional)
select o.id, case when o.kind = 'servicer' then 'SAS' end, case when o.kind = 'servicer' then 1000000 end,
       case when o.kind = 'servicer' then 'Paris' end,
       '{"line1": "1 rue de la Paix", "postcode": "75002", "city": "Paris", "country": "FR"}',
       case when o.kind = 'servicer'
            then 'FR' || lpad(((12 + 3 * (o.siren::bigint % 97)) % 97)::text, 2, '0') || o.siren end, true
from public.organization o where o.id in ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
                                          '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3',
                                          '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a5');
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-0000000000' || x.n)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || '.pdf', repeat('a', 64),
       'application/pdf'
from (values ('01', 'a1', 'mandate_document'), ('02', 'a2', 'mandate_document'), ('03', 'a1', 'payout_rib'),
             ('04', 'a2', 'payout_rib'), ('05', 'a3', 'mandate_document'), ('06', 'a3', 'payout_rib'),
             ('07', 'a4', 'mandate_document'), ('08', 'a4', 'payout_rib'), ('09', 'a5', 'mandate_document'),
             ('10', 'a5', 'payout_rib'), ('11', 'a5', 'payout_rib')) x (n, c, kind);
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on,
                            insurance_clause_ref)
select ('70000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'MAND-' || c, 'mandate_amicable', '2026-01-01', 'art. 9'
from unnest(array['a1', 'a2', 'a3', 'a4', 'a5']) c;
insert into public.mandate_terms (id, mandate_id, valid_from, commission_schedule, commission_clause_ref, remittance_terms,
                                  remittance_clause_ref, document_id)
select ('71000000-0000-0000-0000-0000000000' || x.c)::uuid, ('70000000-0000-0000-0000-0000000000' || x.c)::uuid,
       '2026-01-01',
       '{"schema": "commission-1", "basis": {"families": "all", "forwards": {"file_recalled": false,
         "before_servicing_start": false, "client_ratification": false}, "on_reversal": "credit"},
         "rules": [{"id": "tout", "tier_key": "tout", "label_fr": "Toutes créances", "match": {},
                    "rate": {"kind": "flat", "rate": "0.15"}}]}',
       'art. 6', '{"schema": "remittance-1", "frequency": "twice_monthly", "netting": {"clause_ref": "art. 7.2"},
                   "clawback": null, "invoice_payment_days": 30}', 'art. 7',
       ('d0000000-0000-0000-0000-0000000000' || x.d)::uuid
from (values ('a1', '01'), ('a2', '02'), ('a3', '05'), ('a4', '07'), ('a5', '09')) x (c, d);
update public.portfolio set mandate_id = ('70000000-0000-0000-0000-0000000000' || right(id::text, 2))::uuid
where organization_id = '00000000-0000-0000-0000-0000000000aa';
insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                          evidence_document_id, proposed_by)
select ('90000000-0000-0000-0000-0000000000' || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, 'EUR', x.iban, x.holder,
       ('d0000000-0000-0000-0000-0000000000' || x.d)::uuid, '10000000-0000-0000-0000-000000000004'
from (values ('a1', '03', 'FR7630004000031234567890143', 'MARTIN SAS'),
             ('a2', '04', 'FR1420041010050500013M02606', 'LILAS FINANCE'),
             ('a3', '06', 'FR7630006000011234567890189', 'CYPRES SA'),
             ('a4', '08', 'FR7692640312371024797365028', 'ΩΜΕΓΑ ΑΕ'),
             ('a5', '10', 'TN5910006035183598478831', 'TUNIS TRADING')) x (c, d, iban, holder);
-- Martin's IBAN confirmed by admin 10 (review round 2, security#3: the pair who may not clear a check on it)
update public.client_payout_account set status = 'active', confirmed_at = now(), confirmed_via = 'second_admin',
  confirmed_by = case when client_organization_id = '00000000-0000-0000-0000-0000000000a1'
                      then '10000000-0000-0000-0000-000000000010'::uuid else '10000000-0000-0000-0000-000000000001'::uuid end
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
                                             p_sections jsonb default null)
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
  -- a camt.053's sections as the parser gives them: the bank's creation time (Stmt/CreDtTm), by default its upload's
  update public.bank_statement set status = 'imported', from_date = coalesce(p_from, p_to), to_date = p_to,
    opening_booked_minor = 0, closing_booked_minor = p_closing, counts = '{}', finished_at = clock_timestamp(),
    sections = case when p_format = 'camt053'
                    then coalesce(p_sections, jsonb_build_array(jsonb_build_object(
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
grant all on j to authenticated;

-- Martin 200 000 → net 164 000; Lilas 512 000 → net 419 840 (their invoices set off); Cyprès 12 000, all set off (N = 0:
-- settled at approval, the servicer's 12 000 now on the dedicated account: −4679)
select pg_temp.file('01', '20000000-0000-0000-0000-0000000000a1', 200000);
select pg_temp.file('02', '20000000-0000-0000-0000-0000000000a2', 512000);
select pg_temp.file('03', '20000000-0000-0000-0000-0000000000a3', 12000);
select pg_temp.collect('01', 200000, private.paris_today() - 3);
select pg_temp.collect('02', 512000, private.paris_today() - 3);
select pg_temp.collect('03', 12000, private.paris_today() - 3);
insert into t select 'r1', pg_temp.run('a1', '{"01": "200000"}', 36000, 6000);
insert into t select 'r2', pg_temp.run('a2', '{"02": "512000"}', 92160, 15360);
insert into t select 'r3', pg_temp.run('a3', '{"03": "12000"}', 12000, 2000, 10, 12);
select results_eq($$ select r.status, t.status, t.amount_minor
                     from public.remittance_run r left join public.bank_transfer t on t.id = r.transfer_id
                     where r.id in (select v from t where k in ('r1', 'r2', 'r3')) order by r.number $$,
  $$ values ('approved'::text, 'ordered'::text, 164000::bigint), ('approved', 'ordered', 419840),
            ('booked', null, null) $$,
  'fixture: two payouts ordered at approval, Cyprès settled at approval (N = 0, 120,00 € of the servicer on 4679)');

create or replace function pg_temp.e() returns date language sql as $$ select private.next_business_day(private.paris_today()) $$;
create or replace function pg_temp.n() returns date language sql as $$ select private.next_business_day(pg_temp.e()) $$;
create or replace function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
create or replace function pg_temp.trid(p_run text) returns uuid language sql as $$
  select transfer_id from public.remittance_run where id = pg_temp.v(p_run) $$;
create or replace function pg_temp.rf(p_k text) returns uuid language sql as $$
  select (v ->> 'transfer_id')::uuid from j where k = p_k $$;
create or replace function pg_temp.sweep(p_file uuid) returns public.bank_transfer language sql as $$
  select t.* from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
  where i.file_id = p_file and t.kind = 'sweep' $$;
create or replace function pg_temp.status(p_transfer uuid) returns text language sql as $$
  select status from public.bank_transfer where id = p_transfer $$;
create or replace function pg_temp.cash(p_key text) returns text language sql as $$
  select private.transfer_cash_position('80000000-0000-0000-0000-0000000000cf') ->> p_key $$;
create or replace function pg_temp.chk(p_today date) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_remittance_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return v;
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
-- the k-th business day before today; X, its next business day Y and the one after, Z: days well over, before the
-- fixture's statements (« time moved on »: the files whose cancellation is asked are dated X, set back after download)
create or replace function pg_temp.bd(p_k integer) returns date language sql as $$
  select c.day from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day < private.paris_today()
    and c.day > private.paris_today() - 60
  order by c.day desc offset p_k - 1 limit 1 $$;
create or replace function pg_temp.x() returns date language sql as $$ select pg_temp.bd(10) $$;
create or replace function pg_temp.y() returns date language sql as $$ select private.next_business_day(pg_temp.x()) $$;
create or replace function pg_temp.z() returns date language sql as $$ select private.next_business_day(pg_temp.y()) $$;
create or replace function pg_temp.backdate(p_file uuid, p_day date) returns void language plpgsql as $$
begin
  set constraints public.transfer_file_superseded_by_fkey immediate;
  alter table public.transfer_file disable trigger transfer_file_guard;
  update public.transfer_file set first_execution_date = p_day, last_execution_date = p_day where id = p_file;
  alter table public.transfer_file enable always trigger transfer_file_guard;
  alter table public.transfer_file_item disable trigger transfer_file_item_append_only;
  update public.transfer_file_item set execution_date = p_day where file_id = p_file;
  alter table public.transfer_file_item enable always trigger transfer_file_item_append_only;
  set constraints public.transfer_file_superseded_by_fkey deferred;
end $$;
-- a cancellation request recorded as the commands did before this round (its evidence as it reads now), by p_user
create or replace function pg_temp.ask(p_file uuid, p_transfer uuid, p_user text) returns uuid language sql as $$
  insert into public.transfer_cancellation_request (organization_id, kind, file_id, transfer_id, file_version, attestation,
                                                    reason, evidence, requested_by)
  select f.organization_id, case when p_transfer is null then 'file' else 'transfer' end, f.id, p_transfer, f.version,
         case when p_transfer is null then 'not_uploaded' end, 'Demandé avant la correction (test)',
         private.transfer_cancel_evidence(f.id, p_transfer), ('10000000-0000-0000-0000-0000000000' || p_user)::uuid
  from public.transfer_file f where f.id = p_file
  on conflict do nothing
  returning id $$;
create or replace function pg_temp.ev(p_file text, p_transfer uuid, p_key text) returns text language sql as $$
  select private.transfer_cancel_evidence(pg_temp.v(p_file), p_transfer) ->> p_key $$;
-- the four commands, as SQL text for pg_temp.try
create or replace function pg_temp.req_file(p_key text, p_file text) returns text language sql as $$
  select format($q$ select public.request_transfer_file_cancellation(%L, %L, %s, 'Fichier non déposé', 'not_uploaded')
                     ->> 'status' $q$, p_key, pg_temp.v(p_file), (pg_temp.fl(pg_temp.v(p_file))).version) $$;
create or replace function pg_temp.conf_file(p_key text, p_file text) returns text language sql as $$
  select format($q$ select public.confirm_transfer_file_cancellation(%L, %L, %s) ->> 'status' $q$, p_key, pg_temp.v(p_file),
                (pg_temp.fl(pg_temp.v(p_file))).version) $$;
create or replace function pg_temp.req_tr(p_key text, p_transfer uuid) returns text language sql as $$
  select format($q$ select public.request_transfer_cancellation(%L, %L, 'Refusé par la banque') ->> 'status' $q$, p_key,
                p_transfer) $$;
create or replace function pg_temp.conf_tr(p_key text, p_transfer uuid) returns text language sql as $$
  select format($q$ select public.confirm_transfer_cancellation(%L, %L) ->> 'status' $q$, p_key, p_transfer) $$;
create or replace function pg_temp.sent(p_key text, p_file text) returns text language sql as $$
  select format($q$ select public.mark_transfer_file_sent(%L, %L, %s) ->> 'status' $q$, p_key, pg_temp.v(p_file),
                (pg_temp.fl(pg_temp.v(p_file))).version) $$;
-- a file-mode refund of an unidentified payment of p_amount, asked by ops
create or replace function pg_temp.refund(p_n text, p_amount bigint) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.collect(p_n, p_amount, private.paris_today() - 1, false);
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.request_refund('r2-rfd-' || p_n, pg_temp.pay(p_n), p_amount::text, null, null, 'other', null,
                             p_amount::text, 'payeur inconnu');
  reset role;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
-- the account's cash: today's closing balance (the evidence statements below are for past days)
select pg_temp.statement('01', private.paris_today(), 5000000);
-- the k-th business day of the timeline: d(0) = X (ten business days ago), d(1) = Y, …, d(9) the last before today
create or replace function pg_temp.d(p_k integer) returns date language sql as $$ select pg_temp.bd(10 - p_k) $$;
-- a Paris time on the calendar day after the k-th business day (a statement of it produced the next morning)
create or replace function pg_temp.after(p_k integer, p_time time default '09:00') returns timestamptz language sql as $$
  select (pg_temp.d(p_k) + 1 + p_time) at time zone 'Europe/Paris' $$;
create or replace function pg_temp.e2e(p_transfer uuid) returns text language sql as $$
  select end_to_end_id from public.bank_transfer where id = p_transfer $$;
create or replace function pg_temp.rq(p_k text) returns uuid language sql as $$
  select (v ->> 'refund_request_id')::uuid from j where k = p_k $$;
-- a refund's transfer now (review round 3: re-issued with its downloaded file)
create or replace function pg_temp.rft(p_k text) returns uuid language sql as $$
  select transfer_id from public.refund_request where id = pg_temp.rq(p_k) $$;
create or replace function pg_temp.replaces(p_transfer uuid) returns uuid language sql as $$
  select (to_jsonb(t) ->> 'replaces_transfer_id')::uuid from public.bank_transfer t where t.id = p_transfer $$;
create or replace function pg_temp.hold(p_transfer uuid) returns text language sql as $$
  select private.transfer_hold_reason(p_transfer, private.paris_today(), pg_temp.e(), null) $$;
create or replace function pg_temp.covers(p_from integer, p_to integer) returns boolean language sql as $$
  select private.statement_covers('80000000-0000-0000-0000-0000000000cf', pg_temp.d(p_from), pg_temp.d(p_to)) $$;
-- a file generated by ops, written, downloaded, its dates set back to the k-th business day (« time moved on »)
create or replace function pg_temp.handed_out(p_k text, p_key text, p_day integer) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := (pg_temp.gen('01', p_key) ->> 'file_id')::uuid;
  insert into t values (p_k, v);
  perform pg_temp.write(v);
  perform pg_temp.download('01', v);
  perform pg_temp.backdate(v, pg_temp.d(p_day));
  return v;
end $$;
-- what a generation held out, as « kind amount reason », in order
create or replace function pg_temp.held(p_gen text) returns text[] language sql as $$
  select array_agg((h ->> 'kind') || ' ' || (h ->> 'amount_minor') || ' ' || (h ->> 'reason')
                   order by h ->> 'kind', (h ->> 'amount_minor')::bigint)
  from j cross join lateral jsonb_array_elements(j.v -> 'held') h where j.k = p_gen $$;
create or replace function pg_temp.gv(p_gen text, p_key text) returns text language sql as $$
  select v ->> p_key from j where k = p_gen $$;
create or replace function pg_temp.pmt(p_file text, p_n integer) returns text language sql as $$
  select (pg_temp.fl(pg_temp.v(p_file))).number || '-' || p_n $$;
create or replace function pg_temp.cancel_run(p_key text, p_run text) returns text language sql as $$
  select format($q$ select public.cancel_remittance_run(%L, %L, %s, 'à refaire') ->> 'status' $q$, p_key, pg_temp.v(p_run),
                (select version from public.remittance_run where id = pg_temp.v(p_run))) $$;
create or replace function pg_temp.cancel_refund(p_key text, p_rf text) returns text language sql as $$
  select format($q$ select public.cancel_refund(%L, %L, 'annulé') ->> 'status' $q$, p_key, pg_temp.rq(p_rf)) $$;
create or replace function pg_temp.already_debited(p_run text) returns text[] language sql as $$
  select coalesce(array_agg((r.details ->> 'kind') || ' ' || r.amount_minor || ' ' || (r.details ->> 'status')
                            order by r.details ->> 'kind', r.amount_minor), '{}')
  from public.payment_check_result r where r.run_id = pg_temp.v(p_run) and r.code = 'transfer_already_debited' $$;
grant execute on all functions in schema pg_temp to authenticated;

-- E4 (N6) a camt.053 covers a day only once the bank produced it after that day -----------------------------------
-- X and Y in a camt.053 the bank produced on Y at 18:00 (a ToDtTm written as the next midnight once read as Y),
-- imported days later
select pg_temp.statement('41', pg_temp.d(1), null, '[]', pg_temp.d(0), pg_temp.after(1, '10:00') + interval '2 days',
                         'camt053', (pg_temp.d(1) + time '18:00') at time zone 'Europe/Paris');
select results_eq($$ select pg_temp.covers(0, 0), pg_temp.covers(1, 1),
                            (to_jsonb(s) ->> 'bank_created_at')::timestamptz
                              = (pg_temp.d(1) + time '18:00') at time zone 'Europe/Paris'
                     from public.bank_statement s where s.id = 'e2000000-0000-0000-0000-000000000041' $$,
  $$ values (true, false, true) $$,
  'E4 (N6): a camt.053 produced on Y (its CreDtTm kept) covers X, never Y, whenever it is uploaded');
select pg_temp.statement('42', pg_temp.d(2), null, '[]', pg_temp.d(2), pg_temp.after(2), 'camt053', null, '[{}]');
select is(pg_temp.covers(2, 2), false, 'E4: a camt.053 whose creation time is not known covers no day');
select throws_ok($$ select pg_temp.statement('44', pg_temp.d(2), null, '[]', null, null, 'camt053', null,
                                             '[{"created_at": "29/10/2026 06:10"}]') $$, '22023',
  'header_invalid: a statement''s creation time is not a date-time with its offset',
  'E4: a creation time that is not a date-time with its offset refuses the import');
insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256, size_bytes,
                                   storage_path)
values ('e2000000-0000-0000-0000-000000000043', '00000000-0000-0000-0000-0000000000aa',
        '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 's.xml', repeat('4', 64), 1, 'test/43');
update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = 'e2000000-0000-0000-0000-000000000043';
select throws_ok($$ update public.bank_statement set status = 'rejected', error_code = 'xml_invalid', finished_at = now(),
                     bank_created_at = now() where id = 'e2000000-0000-0000-0000-000000000043' $$, '23514', null,
  'E4: the creation time is written by the import only');
select pg_temp.statement('45', pg_temp.d(1), null, '[]', pg_temp.d(1), pg_temp.after(1, '06:00'));
select is(pg_temp.covers(1, 1), true, 'E4: Y is covered by the statement the bank produced the next morning');

-- E1 (N3) a downloaded file cancelled whole: its payouts and refunds re-issued under fresh end-to-end ids ---------
insert into j select 'ra', pg_temp.refund('21', 5000);
select pg_temp.handed_out('f1', 'r3-gen-0001', 0);
insert into t values ('m1', pg_temp.trid('r1')), ('l1', pg_temp.trid('r2')), ('ra1', pg_temp.rft('ra')),
                     ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
select pg_temp.statement('b1', pg_temp.d(1), null, '[]', pg_temp.d(0), pg_temp.after(1));
select results_eq($$ select pg_temp.try('01', pg_temp.req_file('r3-rq-0001', 'f1')),
                            pg_temp.try('04', pg_temp.conf_file('r3-cf-0001', 'f1')) $$,
  $$ values ('requested'::text, 'superseded'::text) $$, 'E1: a downloaded file cancelled on evidence by two people');
select results_eq($$ select pg_temp.status(pg_temp.v('m1')), pg_temp.status(pg_temp.v('l1')), pg_temp.status(pg_temp.v('ra1')),
                            pg_temp.status(pg_temp.v('s1')) $$,
  $$ values ('cancelled'::text, 'cancelled'::text, 'cancelled'::text, 'cancelled'::text) $$,
  'E1: every transfer it held is cancelled — none is filed again under its end-to-end id');
select results_eq($$ select pg_temp.trid(r) <> pg_temp.v(o), pg_temp.replaces(pg_temp.trid(r)) = pg_temp.v(o),
                            pg_temp.status(pg_temp.trid(r)), left(pg_temp.e2e(pg_temp.trid(r)), 3),
                            pg_temp.e2e(pg_temp.trid(r)) <> pg_temp.e2e(pg_temp.v(o)),
                            (select x.amount_minor = y.amount_minor and x.payee_iban = y.payee_iban
                                    and x.requested_execution_date = y.requested_execution_date
                             from public.bank_transfer x, public.bank_transfer y
                             where x.id = pg_temp.trid(r) and y.id = pg_temp.v(o)),
                            (select status from public.remittance_run where id = pg_temp.v(r))
                     from (values ('r1', 'm1', 1), ('r2', 'l1', 2)) z (r, o, n) order by n $$,
  $$ values (true, true, 'ordered'::text, 'RMT'::text, true, true, 'approved'::text),
            (true, true, 'ordered', 'RMT', true, true, 'approved') $$,
  'E1: each payout re-issued as a new transfer — a fresh RMT id, the same order —, its run pointing at it, approved again');
select results_eq($$ select pg_temp.rft('ra') <> pg_temp.v('ra1'), pg_temp.replaces(pg_temp.rft('ra')) = pg_temp.v('ra1'),
                            pg_temp.status(pg_temp.rft('ra')),
                            (select q.end_to_end_id from public.refund_request q where q.id = pg_temp.rq('ra'))
                              = pg_temp.e2e(pg_temp.rft('ra')),
                            pg_temp.e2e(pg_temp.rft('ra')) <> pg_temp.e2e(pg_temp.v('ra1')),
                            (select remittance_info from public.bank_transfer where id = pg_temp.rft('ra'))
                              = 'REMBOURSEMENT ' || pg_temp.e2e(pg_temp.rft('ra')),
                            (select q.status from public.refund_request q where q.id = pg_temp.rq('ra')) $$,
  $$ values (true, true, 'ordered'::text, true, true, true, 'requested'::text) $$,
  'E1: the refund follows its re-issued transfer, and its RFD id with it (what the M2b link books it by)');
select is((select count(*)::int from public.bank_transfer x
           where (to_jsonb(x) ->> 'replaces_transfer_id')::uuid = pg_temp.v('s1')), 0,
  'E1: the sweep is not re-issued (cancelled, recomputed at the next file)');
select throws_ok(format($q$ update public.refund_request set end_to_end_id = 'RFD00000000000A' where id = %L $q$,
                        pg_temp.rq('ra')), '23514', null,
  'E1: a refund''s RFD id changes only with its re-issued transfer');
select throws_ok(format($q$ update public.remittance_run set transfer_id = %L where id = %L $q$, pg_temp.v('s1'),
                        pg_temp.v('r1')), '23514', null,
  'E1: a run''s transfer changes only to the one re-issuing it');
select throws_ok(format($q$ insert into public.bank_transfer (organization_id, client_organization_id, kind,
                              debtor_bank_account_id, creditor_bank_account_id, currency, amount_minor, payee_name,
                              payee_iban, payee_bic, end_to_end_id, remittance_info, requested_execution_date,
                              replaces_transfer_id)
                            select organization_id, client_organization_id, kind, debtor_bank_account_id,
                                   creditor_bank_account_id, currency, amount_minor, payee_name, payee_iban, payee_bic,
                                   'SWP00000000000A', remittance_info, requested_execution_date, id
                            from public.bank_transfer where id = %L $q$, pg_temp.v('s1')), '23514', null,
  'E1: a sweep is never re-issued');
insert into j select 'g2', pg_temp.gen('01', 'r3-gen-0002');
insert into t select 'f2', (v ->> 'file_id')::uuid from j where k = 'g2';
select results_eq($$ select (select count(*)::int from public.transfer_file_item i
                             join public.bank_transfer x on x.id = i.transfer_id
                             where i.file_id = pg_temp.v('f2')
                               and x.end_to_end_id in (pg_temp.e2e(pg_temp.v('m1')), pg_temp.e2e(pg_temp.v('l1')),
                                                       pg_temp.e2e(pg_temp.v('ra1')))),
                            (select array_agg(i.transfer_id order by i.transfer_id) from public.transfer_file_item i
                             join public.bank_transfer x on x.id = i.transfer_id
                             where i.file_id = pg_temp.v('f2') and x.kind <> 'sweep')
                              = (select array_agg(x order by x)
                                 from unnest(array[pg_temp.trid('r1'), pg_temp.trid('r2'), pg_temp.rft('ra')]) x) $$,
  $$ values (0, true) $$, 'E1: the next file carries the re-issued transfers, none of the cancelled file''s ids');
select throws_ok(format($q$ insert into public.bank_transfer (organization_id, client_organization_id, kind,
                              debtor_bank_account_id, currency, amount_minor, payee_name, payee_iban, payee_bic,
                              end_to_end_id, remittance_info, requested_execution_date, replaces_transfer_id)
                            select organization_id, client_organization_id, kind, debtor_bank_account_id, currency,
                                   amount_minor, payee_name, payee_iban, payee_bic, 'RFD00000000000B', remittance_info,
                                   requested_execution_date, id
                            from public.bank_transfer where id = %L $q$, pg_temp.rft('ra')), '23514', null,
  'E1: nor a transfer still live (in a file)');
select pg_temp.write(pg_temp.v('f2'));
select pg_temp.download('01', pg_temp.v('f2'));
select pg_temp.backdate(pg_temp.v('f2'), pg_temp.d(2));
-- the cancelled file executed late after all for Martin and the refund, by their (old) end-to-end ids, on W; F2, handed
-- out, was never uploaded
select pg_temp.statement('b2', pg_temp.d(3), null, jsonb_build_array(
  jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m1'))),
  jsonb_build_object('amount', 5000, 'e2e', pg_temp.e2e(pg_temp.v('ra1')))), pg_temp.d(2), pg_temp.after(3));
select results_eq($$ select private.transfer_file_executed(pg_temp.v('f2')), pg_temp.ev('f2', pg_temp.trid('r2'), 'refusal') $$,
  $$ values (false, 'file_not_executed'::text) $$,
  'N3: the old file''s late debit of an old id does not make the re-issued file look executed');
select is(pg_temp.try('01', pg_temp.req_tr('r3-rq-0002', pg_temp.trid('r2'))), 'transfer refused: file_not_executed',
  'N3: so Lilas''s transfer is not cancelled out of it alone (the file, still live, would pay her)');
insert into t select 'c1', pg_temp.chk(null);
select is(pg_temp.already_debited('c1'), array['payout 164000 in_file', 'refund 5000 in_file'],
  'N3: the re-issued payout and refund in the downloaded file whose predecessors were debited are alerted');
select results_eq($$ select pg_temp.try('01', pg_temp.req_file('r3-rq-0003', 'f2')),
                            pg_temp.try('09', pg_temp.conf_file('r3-cf-0003', 'f2')) $$,
  $$ values ('requested'::text, 'superseded'::text) $$,
  'N3: the re-issued file, of which nothing was executed, is cancelled whole on its own evidence');
select results_eq($$ select pg_temp.replaces(pg_temp.replaces(pg_temp.trid('r1'))) = pg_temp.v('m1'),
                            pg_temp.hold(pg_temp.trid('r1')), pg_temp.hold(pg_temp.trid('r2')),
                            pg_temp.hold(pg_temp.rft('ra')) $$,
  $$ values (true, 'already_debited'::text, null::text, 'already_debited'::text) $$,
  'E2: a transfer is held when any predecessor in its chain was debited (Martin, the refund), not otherwise (Lilas)');
-- N2: one person cannot cancel them out of it
select results_eq($$ select pg_temp.try('04', pg_temp.cancel_run('r3-run-0001', 'r1')),
                            pg_temp.try('01', pg_temp.cancel_refund('r3-crf-0001', 'ra')),
                            (select count(*)::int from private.remittance_pending
                             where client_organization_id = '00000000-0000-0000-0000-0000000000a1'),
                            (select status from public.refund_request where id = pg_temp.rq('ra')) $$,
  $$ values ('remittance run refused: transfer_already_debited'::text, 'refund refused: already_debited'::text, 0,
             'requested'::text) $$,
  'N2: a run or a refund whose transfer was debited already is not cancelled (it would be paid again)');

-- E2 (N1) a cancelled file executed late, booked as one line per PmtInf (no end-to-end id) --------------------------
insert into j select 'rb', pg_temp.refund('22', 7000);
insert into j select 'rc', pg_temp.refund('23', 2000);
insert into j select 'rd', pg_temp.refund('24', 3000);
insert into j select 'g3', pg_temp.gen('01', 'r3-gen-0003');
insert into t select 'f3', (v ->> 'file_id')::uuid from j where k = 'g3';
select results_eq($$ select pg_temp.held('g3'), pg_temp.gv('g3', 'nb_of_txs')::int, pg_temp.gv('g3', 'sweep_minor') $$,
  $$ values (array['payout 164000 already_debited', 'refund 5000 already_debited'], 5, '12000'::text) $$,
  'E2: the next file holds them out (Lilas, three refunds and a new sweep go in it)');
select pg_temp.write(pg_temp.v('f3'));
select pg_temp.download('01', pg_temp.v('f3'));
select pg_temp.backdate(pg_temp.v('f3'), pg_temp.d(4));
insert into t select 's3', (pg_temp.sweep(pg_temp.v('f3'))).id;
select pg_temp.statement('b3', pg_temp.d(5), null, '[]', pg_temp.d(4), pg_temp.after(5));
select results_eq($$ select pg_temp.try('01', pg_temp.req_file('r3-rq-0004', 'f3')),
                            pg_temp.try('04', pg_temp.conf_file('r3-cf-0004', 'f3')) $$,
  $$ values ('requested'::text, 'superseded'::text) $$, 'N1: that file cancelled on proper evidence');
-- it executes late: its first PmtInf as one line of 4 288,40 € (Lilas, 70,00 €, 20,00 €), its sweep's as 120,00 €
select pg_temp.statement('b4', pg_temp.d(6), null, jsonb_build_array(
  jsonb_build_object('amount', 428840, 'pmt_inf', pg_temp.pmt('f3', 1)),
  jsonb_build_object('amount', 12000, 'pmt_inf', pg_temp.pmt('f3', 2))), pg_temp.d(6), pg_temp.after(6));
select results_eq($$ select pg_temp.hold(pg_temp.trid('r2')), pg_temp.hold(pg_temp.rft('rb')), pg_temp.hold(pg_temp.rft('rc')),
                            pg_temp.hold(pg_temp.rft('rd')) $$,
  $$ values ('already_debited'::text, 'already_debited'::text, 'already_debited'::text, null::text) $$,
  'N1: a batch line of the cancelled file''s PmtInf holds each re-issued transfer it can contain — not the 30,00 € refund, which no part of that line can be');
select is((select array_agg(x) from private.debited_cancelled_sweeps('80000000-0000-0000-0000-0000000000cf') x),
  array[pg_temp.v('s3')], 'N1: the cancelled sweep debited by its PmtInf''s batch line counts as left the account');
insert into j select 'g4', pg_temp.gen('01', 'r3-gen-0004');
insert into t select 'f4', (v ->> 'file_id')::uuid from j where k = 'g4';
select results_eq($$ select pg_temp.gv('g4', 'nb_of_txs')::int, pg_temp.gv('g4', 'ctrl_sum_minor'), pg_temp.gv('g4', 'sweep_minor'),
                            pg_temp.gv('g4', 'sweep_hold'), pg_temp.held('g4') $$,
  $$ values (1, '3000'::text, '0'::text, 'cancelled_sweep_debited'::text,
             array['payout 164000 already_debited', 'payout 419840 already_debited', 'refund 2000 already_debited',
                   'refund 5000 already_debited', 'refund 7000 already_debited']) $$,
  'N1: nothing is filed again but the 30,00 € refund, and no new sweep');
insert into t select 'c2', pg_temp.chk(null);
select is(pg_temp.already_debited('c2'),
  array['payout 164000 ordered', 'payout 419840 ordered', 'refund 2000 ordered', 'refund 5000 ordered',
        'refund 7000 ordered', 'sweep 12000 cancelled'],
  'N1: each one alerted (transfer_already_debited), the cancelled sweep too');
select pg_temp.write(pg_temp.v('f4'));
select pg_temp.download('01', pg_temp.v('f4'));

-- E3 (N5) a returned transfer of a batch stays in its sum and stands in for no other --------------------------------
insert into j select 'rv', pg_temp.refund('25', 100000);
insert into j select 'rt', pg_temp.refund('26', 5000);
insert into j select 'rr', pg_temp.refund('27', 3000);
insert into j select 'ru', pg_temp.refund('28', 8000);
insert into j select 'rx', pg_temp.refund('29', 4000);
select pg_temp.handed_out('f5', 'r3-gen-0005', 6);
-- the bank refused U and booked V + T + R as one line; X was debited on its own; R and X then came back
select pg_temp.statement('b5', pg_temp.d(7), null, jsonb_build_array(
  jsonb_build_object('amount', 108000, 'pmt_inf', pg_temp.pmt('f5', 1)),
  jsonb_build_object('amount', 4000, 'e2e', pg_temp.e2e(pg_temp.rft('rx'))),
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 3000, 'orig_e2e', pg_temp.e2e(pg_temp.rft('rr'))),
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 4000, 'orig_e2e', pg_temp.e2e(pg_temp.rft('rx')))),
  pg_temp.d(6), pg_temp.after(7));
select results_eq($$ select pg_temp.ev('f5', pg_temp.rft('rt'), 'refusal'), pg_temp.ev('f5', pg_temp.rft('ru'), 'refusal'),
                            pg_temp.ev('f5', pg_temp.rft('ru'), 'batch_ambiguous'), pg_temp.ev('f5', pg_temp.rft('rr'), 'returned') $$,
  $$ values ('debit_seen'::text, null::text, 'false'::text, 'true'::text) $$,
  'E3 (N5): T is paid; U, refused, is singled out — R came back, so it was in the line and cannot stand in for U (50 + 30)');
select results_eq($$ select pg_temp.try('01', pg_temp.req_tr('r3-rq-0005', pg_temp.rft('rr'))),
                            pg_temp.try('04', pg_temp.conf_tr('r3-cf-0005', pg_temp.rft('rr'))) $$,
  $$ values ('requested'::text, 'cancelled'::text) $$, 'N5: R, returned, is cancelled');
select results_eq($$ select pg_temp.ev('f5', pg_temp.rft('rt'), 'refusal'), pg_temp.ev('f5', pg_temp.rft('rt'), 'debit_seen'),
                            pg_temp.ev('f5', pg_temp.rft('ru'), 'refusal'), private.transfer_debit_seen(pg_temp.rft('ru')) $$,
  $$ values ('debit_seen'::text, 'true'::text, null::text, false) $$,
  'N5: R stays in the line''s sum once cancelled: T, paid in it, still reads debited; U, refused, is not counted as paid');
select is(pg_temp.try('01', pg_temp.req_tr('r3-rq-0006', pg_temp.rft('ru'))), 'requested',
  'N5: U, the one the bank refused, is the one whose cancellation is asked');
select results_eq($$ select pg_temp.try('04', pg_temp.conf_tr('r3-cf-0006', pg_temp.rft('ru'))),
                            pg_temp.try('01', pg_temp.cancel_refund('r3-crf-0003', 'ru')) $$,
  $$ values ('cancelled'::text, 'unmatched'::text) $$,
  'N5: U is cancelled, then its refund: a line of its still-live file that left it out does not count it as paid');
select results_eq($$ select pg_temp.try('01', pg_temp.req_tr('r3-rq-0007', pg_temp.rft('rx'))),
                            pg_temp.try('04', pg_temp.conf_tr('r3-cf-0007', pg_temp.rft('rx'))),
                            pg_temp.try('01', pg_temp.cancel_refund('r3-crf-0002', 'rx')) $$,
  $$ values ('requested'::text, 'cancelled'::text, 'unmatched'::text) $$,
  'E2: a refund debited then returned is cancelled, then the refund itself (what came back was not paid)');
-- N4: W + A + B + C, the bank refused B and booked W + A + C as one line; A came back
insert into j select 'rw', pg_temp.refund('2a', 50000);
insert into j select 'ra2', pg_temp.refund('2b', 7000);
insert into j select 'rb2', pg_temp.refund('2c', 7000);
insert into j select 'rc2', pg_temp.refund('2d', 2000);
select pg_temp.handed_out('f6', 'r3-gen-0006', 7);
select pg_temp.statement('b6', pg_temp.d(8), null, jsonb_build_array(
  jsonb_build_object('amount', 59000, 'pmt_inf', pg_temp.pmt('f6', 1)),
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 7000, 'orig_e2e', pg_temp.e2e(pg_temp.rft('ra2')))),
  pg_temp.d(7), pg_temp.after(8));
select results_eq($$ select pg_temp.try('01', pg_temp.req_tr('r3-rq-0008', pg_temp.rft('ra2'))),
                            pg_temp.try('04', pg_temp.conf_tr('r3-cf-0008', pg_temp.rft('ra2'))) $$,
  $$ values ('requested'::text, 'cancelled'::text) $$, 'N4: A, returned, is cancelled');
select results_eq($$ select pg_temp.ev('f6', pg_temp.rft('rb2'), 'refusal'), private.transfer_debit_seen(pg_temp.rft('rb2')),
                            pg_temp.try('01', pg_temp.req_tr('r3-rq-0009', pg_temp.rft('rb2'))) $$,
  $$ values (null::text, false, 'requested'::text) $$,
  'N4: B, refused by the bank, is not booked by the line A stays in: still in flight, its cancellation asked');

-- E1 a file's evidence reads the transfers it holds now ------------------------------------------------------------
insert into j select 're', pg_temp.refund('2e', 1000);
insert into t select 'f7', (pg_temp.gen('01', 'r3-gen-0007') ->> 'file_id')::uuid;
insert into t select 'f8', (pg_temp.gen('01', 'r3-gen-0008') ->> 'file_id')::uuid;
select pg_temp.statement('b7', private.paris_today(), null,
  jsonb_build_array(jsonb_build_object('amount', 1000, 'e2e', pg_temp.e2e(pg_temp.rft('re')))));
select results_eq($$ select (pg_temp.fl(pg_temp.v('f7'))).status,
                            (select i.transfer_id from public.transfer_file_item i where i.file_id = pg_temp.v('f7'))
                              = pg_temp.rft('re'),
                            pg_temp.replaces(pg_temp.rft('re')) is null,
                            private.transfer_file_executed(pg_temp.v('f7')), private.transfer_file_executed(pg_temp.v('f8')) $$,
  $$ values ('superseded'::text, true, true, false, true) $$,
  'E1: a file superseded before download passes its transfers on under their ids; its evidence no longer reads them');

select results_eq($$ select count(*) filter (where entry_type in ('remittance', 'servicer_sweep'))::int
                     from public.ledger_entry where organization_id = '00000000-0000-0000-0000-0000000000aa' $$,
  $$ values (0) $$, 'no remittance nor sweep booked by any of it (M2c-6b books the debits)');

select * from finish();
rollback;
