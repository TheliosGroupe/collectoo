-- M2c-6b-2a « foundations » (plan docs/design/m2c-6b-2-plan.md §2, §8.1 036; ADR-0014 « M2c-6b-2a »). What the job and
-- the import keep for the ops booking of our transfer lines (6b-2b), and the gaps of 6b-1 it closes:
--   A. the statement's own detail of an entry kept unsplit, stored at import (private.ingest_statement): the details of
--      ours in the file's order with their directions and amounts, the entry's detail count and NbOfTxs, the charges the
--      statement records for a line that is its entry's only line; a malformed one refused (line_invalid); a re-import
--      skips a known line when the bank tells the same, refuses it when its details, counts or charges differ
--      (entry_detail_differs), and neither compares nor fills a line imported before 6b-2a (null);
--   B. the job never books a return of a transfer that has an open unplanned booking (`unplanned_payout_return`), nor
--      one whose second or late debit is on a statement and not booked (`return_debit_pending`): the unplanned booking
--      is seeded as 6b-2b posts it for S03 (P = 0: the remittance, the booking, the −A pending row, the double_payout
--      advance);
--   C. a generated file's sweep is re-checked against the servicer's share at its first download (`sweep_exceeds_share`:
--      the file refused `file_blocked` and superseded, its sweep cancelled, its payouts ordered again);
--   D. private.unique_subset (6b-2b's lots): the only subset, its complement side, its bounds (the lot cap, the partial
--      sums, the stored paths, the work), the worst saturating input;
--   privileges of the new internal functions;
--   E. the alerts: transfer_unknown (P0, debits and credits), double_payout_open, bank_line_unbooked's new members,
--      own_transfer_payment (P0), the M2b pass's own reason own_transfer_line;
--   F. the S23 texts: « ne peut pas encore », no screen promised.
-- run_payment_checks is asserted free of violations after each group (I8′, I12, I13, I14, I19, I20, bank_line_booked).
-- Review M2c-6b-2a (ADR-0014 « M2c-6b-2a review fixes »): a debit held as a suspected duplicate and decided a duplicate is
-- no pending debit (M1, B); a held credit released as a return is counted by bank_line_unbooked (M2, T1, E); the
-- unplanned_sweep arm (T2), the order of the two return rules (T4), the newer-sweep clause (T5), the charges' stored null
-- and a CSV charge (T3), the helpers' privileges (CS-4).
-- Cancellation after download stays off (033 and 034 unchanged).
begin;
select plan(44);


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
-- Cyprès 12 000, all set off (N = 0: settled at approval, 120,00 € of the servicer now on 4679, swept in F1)
select pg_temp.file(x.n, ('20000000-0000-0000-0000-0000000000' || x.c)::uuid, x.amount)
from (values ('01', 'a1', 200000), ('02', 'a2', 512000), ('03', 'a3', 12000), ('04', 'a4', 40000),
             ('05', 'a5', 30000), ('06', 'a6', 100000), ('07', 'a7', 50000), ('08', 'a8', 100000),
             ('09', 'a9', 30000), ('11', 'a5', 10000), ('12', 'a2', 40000)) x (n, c, amount);
select pg_temp.collect(x.n, x.amount, private.paris_today() - 3)
from (values ('01', 200000), ('02', 512000), ('03', 12000), ('04', 40000), ('05', 30000), ('06', 100000),
             ('07', 50000), ('08', 100000), ('09', 30000), ('11', 10000)) x (n, amount);
select pg_temp.collect('10', 5000, private.paris_today() - 3, false);
-- an unidentified payment of 10 000,00 € (the account's cash, for the files of the scenarios below)
select pg_temp.collect('13', 1000000, private.paris_today() - 3, false);
insert into t select 'r1', pg_temp.run('a1', '{"01": "200000"}', 36000, 6000);
insert into t select 'r2', pg_temp.run('a2', '{"02": "512000"}', 92160, 15360);
insert into t select 'r3', pg_temp.run('a3', '{"03": "12000"}', 12000, 2000, 10, 12);
-- the account's statement of yesterday: what the bank holds (the cash check's closing balance)
select pg_temp.stmt('00', private.paris_today() - 1);


-- A. The statement's own detail of an entry kept unsplit, stored at import (plan §2.1–§2.2; critic F8, L11; critic2 ML-5,
-- ML-6, ML-10, CSO2-8) --------------------------------------------------------------------------------------------------
-- a camt.053 statement of the dedicated account imported through private.ingest_statement, its lines staged as the worker
-- stages them ([{ref, dir, kind, amount, e2e, orig, unsplit, details, count, nb, charges}]; an entry kept unsplit has
-- `unsplit`, its batch entry reference the entry's), opened with the ledger cash: the number of new lines
create or replace function pg_temp.imp_id(p_n text) returns uuid language sql as $$
  select ('e5000000-0000-0000-0000-0000000000' || p_n)::uuid $$;
create or replace function pg_temp.imp(p_n text, p_lines jsonb) returns text language plpgsql as $$
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
                                         unsplit_batch_count, charges_minor)
  select s, l.ord, 1, 'e:' || (l.v ->> 'ref') || '#1', coalesce(l.v ->> 'dir', 'debit'), (l.v ->> 'amount')::bigint,
         'EUR', private.paris_today(), l.v ->> 'e2e', l.v ->> 'orig', case when l.v ? 'unsplit' then l.v ->> 'ref' end,
         l.v ->> 'ref', coalesce(l.v ->> 'kind', 'batch_unsplit'), 'sct', (l.v ->> 'unsplit')::smallint, l.v -> 'details',
         (l.v ->> 'count')::integer, (l.v ->> 'nb')::integer, (l.v ->> 'charges')::bigint
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  select coalesce(sum(case coalesce(l.v ->> 'dir', 'debit') when 'credit' then 1 else -1 end
                      * (l.v ->> 'amount')::bigint), 0)
  into v_moved from jsonb_array_elements(p_lines) l (v);
  return private.ingest_statement(s, jsonb_build_object('format', 'camt053', 'version', '08',
           'line_count', jsonb_array_length(p_lines), 'skipped_not_booked', 0,
           'sections', jsonb_build_array(jsonb_build_object('stmt_id', 'A' || p_n, 'seq', 1,
             'from_date', private.paris_today(), 'to_date', private.paris_today(), 'opening_minor', v_open::text,
             'closing_minor', (v_open + v_moved)::text)))) ->> 'new_lines';
end $$;
-- what a statement's lines keep: by entry reference, [details, detail count, NbOfTxs, charges, unsplit_ours]
create or replace function pg_temp.kept(p_n text) returns jsonb language sql as $$
  select coalesce(jsonb_object_agg(t.entry_ref, jsonb_build_array(t.unsplit_details, t.unsplit_detail_count,
                                                                  t.unsplit_batch_count, t.charges_minor, t.unsplit_ours)),
                  '{}')
  from public.bank_transaction t where t.statement_id = pg_temp.imp_id(p_n) $$;
-- the round-5 netted credit (our payout's return netted with another payout's debit), d03 (two debits of ours), an
-- entry with our detail and two others (ML-5), a detail without its amount, a line of its own with the statement's
-- charges (ML-6) and one without
create or replace function pg_temp.a_lines() returns jsonb language sql as $$
  select '[{"ref": "NA1", "dir": "credit", "kind": "return", "amount": 387040, "orig": "RMT0000000000A1", "unsplit": 2,
            "count": 2, "nb": 2,
            "details": [{"id": "RMT0000000000A1", "direction": "credit", "amount_minor": "419840"},
                        {"id": "RMT0000000000A2", "direction": "debit", "amount_minor": "32800"}]},
           {"ref": "NA2", "amount": 70000, "unsplit": 2, "count": 2,
            "details": [{"id": "RMT0000000000A3", "direction": "debit", "amount_minor": "30000"},
                        {"id": "SWP0000000000A4", "direction": "debit", "amount_minor": "40000"}]},
           {"ref": "NA3", "amount": 50000, "unsplit": 1, "count": 3, "nb": 3,
            "details": [{"id": "RMT0000000000A5", "direction": "debit", "amount_minor": "20000"}]},
           {"ref": "NA4", "amount": 9000, "unsplit": 1, "count": 1,
            "details": [{"id": "RFD0000000000A6", "direction": "debit", "amount_minor": null}]},
           {"ref": "NA5", "kind": "transfer_out", "e2e": "RMT0000000000A7", "amount": 32920, "charges": 120},
           {"ref": "NA6", "kind": "other_debit", "amount": 1000}]'::jsonb $$;
create or replace function pg_temp.a_store() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  v := jsonb_build_object('new', pg_temp.imp('01', pg_temp.a_lines()), 'kept', pg_temp.kept('01'));
  -- the same file again: every line known, skipped; the stored lines untouched
  return v || jsonb_build_object('again', pg_temp.imp('02', pg_temp.a_lines()), 'kept_after', pg_temp.kept('01'));
end $$;
select is(pg_temp.isolated('a_store'),
  jsonb_build_object('new', '6', 'again', '0',
    'kept', jsonb_build_object(
      'NA1', jsonb_build_array(pg_temp.a_lines() -> 0 -> 'details', 2, 2, null, 2),
      'NA2', jsonb_build_array(pg_temp.a_lines() -> 1 -> 'details', 2, null, null, 2),
      'NA3', jsonb_build_array(pg_temp.a_lines() -> 2 -> 'details', 3, 3, null, 1),
      'NA4', jsonb_build_array(pg_temp.a_lines() -> 3 -> 'details', 1, null, null, 1),
      'NA5', '[null, null, null, 120, null]'::jsonb,
      'NA6', '[null, null, null, null, null]'::jsonb))
  || jsonb_build_object('kept_after', jsonb_build_object(
      'NA1', jsonb_build_array(pg_temp.a_lines() -> 0 -> 'details', 2, 2, null, 2),
      'NA2', jsonb_build_array(pg_temp.a_lines() -> 1 -> 'details', 2, null, null, 2),
      'NA3', jsonb_build_array(pg_temp.a_lines() -> 2 -> 'details', 3, 3, null, 1),
      'NA4', jsonb_build_array(pg_temp.a_lines() -> 3 -> 'details', 1, null, null, 1),
      'NA5', '[null, null, null, 120, null]'::jsonb,
      'NA6', '[null, null, null, null, null]'::jsonb)),
  'A: the details of ours an unsplit entry gives are stored in the file''s order with their directions and amounts '
  '(null when the detail gives none), with the entry''s detail count and NbOfTxs (an entry with our detail and two others: '
  'count 3, unsplit_ours 1); a line of its own keeps the statement''s charges (null without); the same file again skips '
  'every line and leaves them untouched');
-- a malformed staged line refuses the file (the first offending line named): line_invalid
create or replace function pg_temp.a_bad(p_line jsonb) returns text language sql as $$
  select split_part(pg_temp.attempt(format('select pg_temp.imp(%L, %L::jsonb)', '09', jsonb_build_array(p_line))), ':', 1)
$$;
select is(jsonb_build_array(
    pg_temp.a_bad('{"ref": "NB1", "amount": 1000, "unsplit": 2, "count": 2,
                    "details": [{"id": "RMT0000000000B1", "direction": "debit", "amount_minor": "1000"}]}'),
    pg_temp.a_bad('{"ref": "NB1", "amount": 1000, "unsplit": 1, "count": 1,
                    "details": [{"id": "XYZ0000000000B1", "direction": "debit", "amount_minor": "1000"}]}'),
    pg_temp.a_bad('{"ref": "NB1", "amount": 1000, "unsplit": 1, "count": 1,
                    "details": [{"id": "RMT0000000000B1", "direction": "debit", "amount_minor": "0"}]}'),
    pg_temp.a_bad('{"ref": "NB1", "amount": 1000, "unsplit": 1, "count": 1,
                    "details": [{"id": "RMT0000000000B1", "direction": "debit", "amount_minor": "12.5"}]}'),
    pg_temp.a_bad('{"ref": "NB1", "amount": 1000, "unsplit": 1, "count": 1,
                    "details": [{"id": "RMT0000000000B1", "direction": "out", "amount_minor": "1000"}]}'),
    pg_temp.a_bad('{"ref": "NB1", "amount": 1000, "count": 1,
                    "details": [{"id": "RMT0000000000B1", "direction": "debit", "amount_minor": "1000"}]}'),
    pg_temp.a_bad('{"ref": "NB1", "amount": 1000, "unsplit": 2, "count": 1,
                    "details": [{"id": "RMT0000000000B1", "direction": "debit", "amount_minor": "400"},
                                {"id": "RMT0000000000B2", "direction": "debit", "amount_minor": "600"}]}'),
    pg_temp.a_bad('{"ref": "NB1", "kind": "other_debit", "amount": 1000, "charges": 0}'),
    pg_temp.a_bad('{"ref": "NB1", "amount": 1000, "unsplit": 1, "count": 1,
                    "details": [{"id": "RMT0000000000B1", "direction": "debit", "amount_minor": "1000", "x": 1}]}'),
    pg_temp.a_bad('{"ref": "NB1", "amount": 1000, "unsplit": 1, "count": 1,
                    "details": {"id": "RMT0000000000B1", "direction": "debit", "amount_minor": "1000"}}'),
    pg_temp.a_bad('{"ref": "NB1", "amount": 1000, "unsplit": 1, "count": 1}')),
  to_jsonb(array_fill('line_invalid'::text, array[11])),
  'A: refused line_invalid — a count of details other than unsplit_ours, an id we do not issue, an amount that is not '
  'positive digits, a direction that is neither debit nor credit, details without unsplit_ours, a detail count below '
  'unsplit_ours, a charge that is not positive, a detail of another shape, details that are not an array, counts without '
  'details');
-- CSO2-8: a known line (same account and key) comes back with other details, counts or charges: the file is refused,
-- as an entry that comes back split another way; a line imported before 6b-2a (no details kept) is neither compared nor
-- filled
create or replace function pg_temp.a_nc1(p_detail jsonb, p_count integer default 2, p_nb integer default 2) returns jsonb
language sql as $$
  select jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('ref', 'NC1', 'amount', 50000, 'unsplit', 1,
           'count', p_count, 'nb', p_nb, 'details', jsonb_build_array(p_detail)))) $$;
create or replace function pg_temp.a_again(p_lines jsonb) returns text language sql as $$
  select split_part(pg_temp.attempt(format('select pg_temp.imp(%L, %L::jsonb)', '04', p_lines)), ':', 1) $$;
-- an import kept when it passes (its refusal's code otherwise, the file going on)
create or replace function pg_temp.a_kept_imp(p_n text, p_lines jsonb) returns text language plpgsql as $$
begin
  return pg_temp.imp(p_n, p_lines);
exception when others then
  return split_part(sqlerrm, ':', 1);
end $$;
create or replace function pg_temp.a_reimport() returns jsonb language plpgsql as $$
declare
  d jsonb := '{"id": "RMT0000000000C1", "direction": "debit", "amount_minor": "20000"}';
  v jsonb;
begin
  perform pg_temp.imp('03', pg_temp.a_nc1(d) || '[{"ref": "NC2", "kind": "transfer_out", "e2e": "RMT0000000000C2",
                                                   "amount": 32920, "charges": 120},
                                                  {"ref": "NC3", "amount": 40000, "unsplit": 1},
                                                  {"ref": "NC4", "kind": "transfer_out", "e2e": "RMT0000000000C4",
                                                   "amount": 32920}]'::jsonb);
  v := jsonb_build_object(
    'same', pg_temp.a_again(pg_temp.a_nc1(d) || '[{"ref": "NC2", "kind": "transfer_out", "e2e": "RMT0000000000C2",
                                                   "amount": 32920, "charges": 120}]'::jsonb),
    'id', pg_temp.a_again(pg_temp.a_nc1(d || '{"id": "RMT0000000000C9"}')),
    'direction', pg_temp.a_again(pg_temp.a_nc1(d || '{"direction": "credit"}')),
    'amount', pg_temp.a_again(pg_temp.a_nc1(d || '{"amount_minor": "20001"}')),
    'count', pg_temp.a_again(pg_temp.a_nc1(d, 3)),
    'nb', pg_temp.a_again(pg_temp.a_nc1(d, 2, null)),
    'charges', pg_temp.a_again('[{"ref": "NC2", "kind": "transfer_out", "e2e": "RMT0000000000C2", "amount": 32920,
                                  "charges": 130}]'),
    'charges_dropped', pg_temp.a_again('[{"ref": "NC2", "kind": "transfer_out", "e2e": "RMT0000000000C2",
                                          "amount": 32920}]'));
  -- NC3 imported with no details (as before 6b-2a): the details of a re-import are not compared, nor kept; review
  -- M2c-6b-2a (T3): nor are the charges of NC4, a line of its own imported with none (every line before 6b-2a)
  return v || jsonb_build_object(
    'filled', pg_temp.a_kept_imp('05', '[{"ref": "NC3", "amount": 40000, "unsplit": 1, "count": 1,
                                          "details": [{"id": "RMT0000000000C3", "direction": "debit",
                                                       "amount_minor": "40000"}]}]'),
    'nc3', pg_temp.kept('03') -> 'NC3',
    'charges_added', pg_temp.a_kept_imp('06', '[{"ref": "NC4", "kind": "transfer_out", "e2e": "RMT0000000000C4",
                                                 "amount": 32920, "charges": 120}]'),
    'nc4', pg_temp.kept('03') -> 'NC4');
end $$;
select is(pg_temp.isolated('a_reimport'),
  '{"same": "0", "id": "entry_detail_differs", "direction": "entry_detail_differs", "amount": "entry_detail_differs",
    "count": "entry_detail_differs", "nb": "entry_detail_differs", "charges": "entry_detail_differs",
    "charges_dropped": "entry_detail_differs", "filled": "0", "nc3": [null, null, null, null, 1],
    "charges_added": "0", "nc4": [null, null, null, null, null]}'::jsonb,
  'A (CSO2-8): a known line with the same details is skipped; with another id, direction or amount of a detail of ours, '
  'another detail count or NbOfTxs, other or no charges, the file is refused entry_detail_differs; a line imported '
  'without details, or without charges, is neither compared nor filled');
-- review M2c-6b-2a (T3): a CSV export never stages a charge (the bank's record is the camt.053's): line_invalid
create or replace function pg_temp.a_csv_charge() returns text language plpgsql as $$
declare s uuid := pg_temp.imp_id('07');
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'csv', 'a.csv',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into private.bank_import_stage (statement_id, line_no, section_no, dedup_key, direction, amount_minor, currency,
                                         booking_date, kind, method, charges_minor)
  values (s, 1, 0, 'h:' || s, 'debit', 1000, 'EUR', private.paris_today(), 'other_debit', 'other', 120);
  return private.ingest_statement(s, jsonb_build_object('format', 'csv', 'line_count', 1, 'skipped_not_booked', 0,
                                                        'sections', '[]'::jsonb)) ->> 'new_lines';
end $$;
select is(split_part(pg_temp.attempt('select pg_temp.a_csv_charge()'), ':', 1), 'line_invalid',
  'A (T3): a CSV line staging a charge refuses the file line_invalid');


-- D. private.unique_subset (plan §2.5; critic2 CSO2-2) ------------------------------------------------------------------
select is(private.transfer_line_lot_cap(), 500, 'the lot cap: one constant, 500');
select is(jsonb_build_array(private.unique_subset('{100,100}', 100), private.unique_subset('{100,250,300}', 350),
                            private.unique_subset('{100,200,400}', 600), private.unique_subset('{100,200,300}', 300),
                            private.unique_subset('{100,200}', 400), private.unique_subset('{100,200}', 0),
                            private.unique_subset('{100,200}', 300),
                            private.unique_subset((select array_agg((2 ^ i)::bigint order by i)
                                                   from generate_series(0, 19) i), 1048574)),
          '[null, [1, 2], [2, 3], null, null, [], [1, 2],
            [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]]'::jsonb,
  'D: two equal amounts → null; the only subset → its 1-based indexes; on the complement side (t'' = Σ − target) the '
  'complement of the only subset of t''; two subsets → null; past the total → null; 0 → the empty subset; the total → all; '
  'twenty powers of two and Σ − 1: searched as its complement {1} (Σ − 1 itself would pass the partial-sum bound)');
-- the bounds, read on the trace: the lot cap (at once), the partial sums, the stored paths (lowered here: no input under
-- the partial-sum bound reaches 200,000), the work
create or replace function pg_temp.trace(p_amounts bigint[], p_target bigint, p_paths integer default 200000)
returns jsonb language sql as $$
  select to_jsonb(x) from private.unique_subset_trace(p_amounts, p_target, 10000, p_paths, 1000000) x $$;
create temporary table worst (k text primary key, v jsonb, ms numeric) on commit drop;
create or replace function pg_temp.timed_worst() returns void language plpgsql as $$
declare t0 timestamptz := clock_timestamp(); v jsonb;
begin
  v := pg_temp.trace(array(select (500 + (g * 7919) % 8501)::bigint from generate_series(1, 500) g), 8000);
  insert into worst values ('worst', v, extract(epoch from clock_timestamp() - t0) * 1000);
end $$;
select pg_temp.timed_worst();
select is(jsonb_build_array(
    pg_temp.trace(array_fill(100::bigint, array[501]), 100),
    pg_temp.trace(array_fill(100::bigint, array[500]), 50000) -> 'bound',
    jsonb_array_length(pg_temp.trace(array_fill(100::bigint, array[500]), 50000) -> 'indexes'),
    pg_temp.trace(array(select (2 ^ g)::bigint from generate_series(0, 13) g) || 1000000::bigint, 12345),
    pg_temp.trace(array(select (2 ^ g)::bigint from generate_series(0, 9) g) || 1000000::bigint, 1000, 100),
    pg_temp.trace(array(select (2 ^ g)::bigint from generate_series(0, 9) g) || 1000000::bigint, 1000)),
  '[{"indexes": null, "tripped_at": 0, "bound": "cap"}, null, 500,
    {"indexes": null, "tripped_at": 14, "bound": "sums"},
    {"indexes": null, "tripped_at": 6, "bound": "paths"},
    {"indexes": [4, 6, 7, 8, 9, 10], "tripped_at": null, "bound": null}]'::jsonb,
  'D: more amounts than the cap → null at once; 500 amounts are not past it; past 10,000 partial sums → null; past the '
  'stored paths → null; under every bound the only subset (1 000 = 8 + 32 + 64 + 128 + 256 + 512)');
select is((select v ->> 'bound' from worst), 'work',
  'D (CSO2-2): the worst saturating input (500 amounts of 5–90 €, t'' = 8 000) trips the work bound: null');
select cmp_ok((select ms from worst), '<', 500::numeric, 'D (CSO2-2): … in less than 0.5 s');

-- privileges (critic2 CSO2-11): the new functions are internal
select is(array[has_function_privilege('anon', 'private.unique_subset(bigint[], bigint)', 'execute'),
                has_function_privilege('authenticated', 'private.unique_subset(bigint[], bigint)', 'execute'),
                has_function_privilege('anon', 'private.unique_subset_trace(bigint[], bigint, integer, integer, bigint)',
                                       'execute'),
                has_function_privilege('authenticated',
                                       'private.unique_subset_trace(bigint[], bigint, integer, integer, bigint)',
                                       'execute'),
                has_function_privilege('anon', 'private.transfer_line_lot_cap()', 'execute'),
                has_function_privilege('authenticated', 'private.transfer_line_lot_cap()', 'execute'),
                has_function_privilege('anon', 'private.own_transfer_line_hint(text)', 'execute'),
                has_function_privilege('authenticated', 'private.own_transfer_line_hint(text)', 'execute'),
                -- review M2c-6b-2a (CS-4): the two other new helpers, and transfer_late_lines (redefined, M1)
                has_function_privilege('anon', 'private.unsplit_details_valid(jsonb, integer)', 'execute'),
                has_function_privilege('authenticated', 'private.unsplit_details_valid(jsonb, integer)', 'execute'),
                has_function_privilege('anon', 'private.transfer_unplanned_open(uuid)', 'execute'),
                has_function_privilege('authenticated', 'private.transfer_unplanned_open(uuid)', 'execute'),
                has_function_privilege('anon', 'private.transfer_late_lines(uuid)', 'execute'),
                has_function_privilege('authenticated', 'private.transfer_late_lines(uuid)', 'execute')],
          array_fill(false, array[14]),
  'neither anon nor authenticated may execute unique_subset, its trace, the lot cap, the own-line hint, the details''s '
  'shape check, the unplanned-open fact or the late lines');


-- C. A generated file's sweep re-checked at its first download (plan §2.4; critic CSO-2, F10, CSO-10; critic2 CSO2-4) ---
-- Petit's run (net 820,00 €), filed with Martin's and Lilas' runs and the sweep of Cyprès' 120,00 € in FA, downloaded;
-- then Moreau's run set off whole (N = 0: settled at approval, 300,00 € more of the servicer's on 4679) and Lambert's
-- run (net 328,00 €): FC, generated and written, sweeps 300,00 € (FA's 120,00 € is in flight)
insert into t select 'r8', pg_temp.run('a8', '{"08": "100000"}', 18000, 3000);
select pg_temp.handed_out('fa', 'gen-file-a');
insert into t select 'sa', (pg_temp.sweep(pg_temp.v('fa'))).id;
insert into t select 'rz', pg_temp.run('a9', '{"09": "30000"}', 30000, 5000, 10, 12);
insert into t select 'r4', pg_temp.run('a4', '{"04": "40000"}', 7200, 1200);
insert into t select 'fc', (pg_temp.gen('01', 'gen-file-c') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('fc'));
insert into t select 'sc', (pg_temp.sweep(pg_temp.v('fc'))).id;
select is(array[(pg_temp.sweep(pg_temp.v('fa'))).amount_minor, (pg_temp.sweep(pg_temp.v('fc'))).amount_minor,
                (pg_temp.tr(pg_temp.v('r4'))).amount_minor],
          array[12000, 30000, 32800]::bigint[],
  'C: FA sweeps Cyprès'' 120,00 €; FC sweeps Moreau''s 300,00 € (the share less FA''s sweep in flight) beside Lambert''s '
  '328,00 €');
-- the download's answer and what it left: the file, its sweep, its payout (and its date) and run
create or replace function pg_temp.c_after(p_v jsonb) returns jsonb language sql as $$
  select jsonb_build_object('refused', p_v ->> 'refused', 'status', (pg_temp.fl(pg_temp.v('fc'))).status,
    'blocked', p_v -> 'blocked', 'sweep', pg_temp.status(pg_temp.v('sc')),
    'payout', pg_temp.status(pg_temp.trid('r4')),
    'run', (select status from public.remittance_run where id = pg_temp.v('r4'))) $$;
create or replace function pg_temp.c_regenerate() returns jsonb language plpgsql as $$
declare f uuid;
begin
  f := (pg_temp.gen('01', 'gen-file-c-again') ->> 'file_id')::uuid;
  return jsonb_build_object('sweep', (pg_temp.sweep(f)).amount_minor, 'late_reason', (pg_temp.fl(f)).late_reason,
                            'payout_in', exists (select 1 from public.transfer_file_item i
                                                 where i.file_id = f and i.transfer_id = pg_temp.trid('r4')));
end $$;
create or replace function pg_temp.c_served() returns jsonb language plpgsql as $$
begin
  return pg_temp.c_after(pg_temp.download('01', pg_temp.v('fc')));
end $$;
-- a bank charge booked by the job between generation and download (the share 7,00 € below FC's sweep)
create or replace function pg_temp.c_fee_scenario() returns jsonb language plpgsql as $$
declare d date := (select requested_execution_date from public.bank_transfer where id = pg_temp.trid('r4'));
  v jsonb;
begin
  perform pg_temp.stmt('c1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 700, 'kind', 'other_debit', 'code', 'PMNT/CCRD/CHRG')));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('c1', 1), 'fee')));
  v := pg_temp.c_after(pg_temp.download('01', pg_temp.v('fc')));
  return v || jsonb_build_object(
    'date_unchanged', (select requested_execution_date from public.bank_transfer where id = pg_temp.trid('r4')) = d,
    'regenerated', pg_temp.c_regenerate());
end $$;
-- Petit's collection reversed after its run's approval, then its payout's debit booked by the job: the booking-time
-- cover (+4679 1 000,00 €) and the settlement (−4679 180,00 €) leave the share at −520,00 € (FA's sweep in flight)
create or replace function pg_temp.c_overrun() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform private.ledger_reverse((select id from public.ledger_entry where payment_id = pg_temp.pay('08')
                                    and entry_type = 'allocation'), 'rev-test-c-08', 'Retour du paiement (test)',
                                 private.paris_today());
  perform pg_temp.stmt('c2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(pg_temp.trid('r8')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('c2', 1), 'payout', pg_temp.trid('r8'))));
  v := pg_temp.c_after(pg_temp.download('01', pg_temp.v('fc')));
  return v || jsonb_build_object('advance', (select a.cause from public.client_advance a
                                             where a.transfer_id = pg_temp.trid('r8')),
                                 'regenerated', pg_temp.c_regenerate());
end $$;
-- a file not written yet (status pending) is never served
create or replace function pg_temp.c_pending() returns jsonb language plpgsql as $$
declare f uuid;
begin
  f := (pg_temp.gen('01', 'gen-file-c-pending') ->> 'file_id')::uuid;
  return to_jsonb(pg_temp.attempt(format('select pg_temp.download(%L, %L)', '01', f)));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_served'),
  jsonb_build_object('refused', null, 'status', 'downloaded', 'blocked', null, 'sweep', 'in_file', 'payout', 'in_file',
                     'run', 'sent'),
  'C: a share still at FC''s sweep (300,00 €) → served, the sweep and the payout handed out');
select is(pg_temp.isolated('c_fee_scenario'),
  jsonb_build_object('refused', 'file_blocked', 'status', 'superseded',
    'blocked', jsonb_build_array(jsonb_build_object('transfer_id', pg_temp.v('sc'), 'kind', 'sweep',
                                                    'reason', 'sweep_exceeds_share', 'sweep_minor', '30000',
                                                    'share_minor', '29300')),
    'sweep', 'cancelled', 'payout', 'ordered', 'run', 'approved', 'date_unchanged', true,
    'regenerated', jsonb_build_object('sweep', 29300, 'late_reason', null, 'payout_in', true)),
  'C: a bank charge booked after generation → the download refuses file_blocked (sweep_exceeds_share, the sweep and the '
  'share named), the file superseded, its sweep cancelled, its payout ordered with its date, its run still approved; '
  'regenerated the same day without a late reason, the sweep is the share now and the payout is back in');
select is(pg_temp.isolated('c_overrun'),
  jsonb_build_object('refused', 'file_blocked', 'status', 'superseded',
    'blocked', jsonb_build_array(jsonb_build_object('transfer_id', pg_temp.v('sc'), 'kind', 'sweep',
                                                    'reason', 'sweep_exceeds_share', 'sweep_minor', '30000',
                                                    'share_minor', '-52000')),
    -- M2c-7a (ADR-0014 « M2c-7a », R3): the reversed line in flight is covered at the booking for itself (cause
    -- remitted_reversal), same amount: the share is the same, the file refused the same way
    'sweep', 'cancelled', 'payout', 'ordered', 'run', 'approved', 'advance', 'remitted_reversal',
    'regenerated', jsonb_build_object('sweep', null, 'late_reason', null, 'payout_in', true)),
  'C: a payout_overrun cover posted by the job between generation and download → refused the same way (the share '
  'negative); regenerated, the file carries no sweep');
select is(pg_temp.isolated('c_pending'), to_jsonb('transfer file refused: not_ready'::text),
  'C (CSO-10): a file still pending is never served (not_ready)');
select is(pg_temp.dirty(), '{}'::text[], 'C: clean (I8′, I12, I13, I14, I19, I20, bank_line_booked)');


-- B. The job's return rule (plan §2.3; critic F1, L5; critic2 ML-3, CSO2-12) ----------------------------------------------
-- FA's debits booked from yesterday's statement: Martin's, Lilas' and Petit's payouts, the sweep
select pg_temp.stmt('b1', private.paris_today() - 1, jsonb_build_array(
  jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.trid('r1'))),
  jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.trid('r2'))),
  jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(pg_temp.trid('r8'))),
  jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('sa')), 'iban', 'FR7610107001011234567890129')));
select is(pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('b1', 1), 'payout', pg_temp.trid('r1')),
                                         pg_temp.row(pg_temp.ln('b1', 2), 'payout', pg_temp.trid('r2')),
                                         pg_temp.row(pg_temp.ln('b1', 3), 'payout', pg_temp.trid('r8')),
                                         pg_temp.row(pg_temp.ln('b1', 4), 'sweep', pg_temp.v('sa')))) ->> 'payouts',
          '3', 'B: FA''s three payouts booked (and its sweep)');
insert into t values ('x1', pg_temp.trid('r1')), ('x2', pg_temp.trid('r2'));
-- What 6b-2b posts for an unplanned payout of transfer p_tr on line p_line (S03; P = p_p), seeded as postgres: the
-- `remittance` (+4670[c] A / −5120 A, key remit:line:<line>:1, its document the transfer), its booking (ops, a motif),
-- the −A pending row, and the double_payout advance of A − P (+4679 / −4670[c] ‖ +4112[c] / −4689, key adv:line:<line>:1)
-- whose posting queues +(A − P) through the trigger (CSO2-12: without it, 4670[c] in debit, LG008)
create or replace function pg_temp.unplanned(p_line uuid, p_tr uuid, p_c text, p_p bigint default 0) returns uuid
language plpgsql as $$
declare
  l public.bank_transaction;
  v_client uuid := ('00000000-0000-0000-0000-0000000000' || p_c)::uuid;
  v_entry uuid;
  v_adv uuid := gen_random_uuid();
begin
  select * into l from public.bank_transaction where id = p_line;
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason)
  values (1, l.organization_id, 'remittance', l.booking_date, 'remit:line:' || p_line || ':1', v_client,
          'bank_transfer', p_tr::text, 'Virement exécuté hors reversement (relevé du ' || to_char(l.booking_date,
                                                                                              'DD/MM/YYYY') || ')');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_payable', l.amount_minor, l.currency, null),
    (1, 2, 'client_money_cash', -l.amount_minor, l.currency, l.bank_account_id);
  perform private.ledger_post_set();
  v_entry := pg_temp.ek('remit:line:' || p_line || ':1');
  insert into private.remittance_pending (ledger_entry_id, organization_id, client_organization_id, currency, kind,
                                          amount_minor, posted_at)
  select v_entry, l.organization_id, v_client, l.currency, 'unplanned_payout', -l.amount_minor, e.posted_at
  from public.ledger_entry e where e.id = v_entry;
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method, reason, decided_by)
  values (p_line, 1, l.organization_id, l.bank_account_id, 'unplanned_payout', p_tr, v_entry, l.amount_minor, 'ops',
          'motif de test', '10000000-0000-0000-0000-000000000001');
  if l.amount_minor > p_p then
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                    client_organization_id, source_type, source_id, reason)
    values (1, l.organization_id, 'client_advance', l.booking_date, 'adv:line:' || p_line || ':1', v_client,
            'client_advance', v_adv::text, 'Virement hors reversement : avance du cabinet');
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
      (1, 1, 'due_to_servicer', l.amount_minor - p_p, l.currency, null),
      (1, 2, 'client_payable', -(l.amount_minor - p_p), l.currency, null),
      (1, 3, 'client_advance_receivable', l.amount_minor - p_p, l.currency, null),
      (1, 4, 'due_from_client_funds', -(l.amount_minor - p_p), l.currency, null);
    perform private.ledger_post_set();
    insert into public.client_advance (id, organization_id, client_organization_id, currency, amount_minor, cause,
                                       cause_entry_id, entry_id, bank_transaction_id, transfer_id)
    values (v_adv, l.organization_id, v_client, l.currency, l.amount_minor - p_p, 'double_payout', v_entry,
            pg_temp.ek('adv:line:' || p_line || ':1'), p_line, p_tr);
  end if;
  perform private.ledger_check_now();
  return v_entry;
end $$;
-- a client's waiting queue (its pending items, reserved or not)
create or replace function pg_temp.queued_minor(p_c text) returns bigint language sql as $$
  select coalesce(sum(q.amount_minor), 0)::bigint from private.remittance_pending q
  where q.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.returned_items(p_c text) returns bigint language sql as $$
  select count(*) from private.remittance_pending q
  where q.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid and q.kind = 'payout_returned' $$;
create or replace function pg_temp.payout_account(p_c text) returns text language sql as $$
  select status from public.client_payout_account
  where client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
-- the return facts the funds pass reads for a line (its return row)
create or replace function pg_temp.return_facts(p_line uuid) returns jsonb language sql as $$
  select jsonb_build_object('role', c.role, 'unplanned_open', c.unplanned_open, 'debit_pending', c.debit_pending)
  from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 1000) c
  where c.line_id = p_line and c.role = 'return' $$;
grant execute on all functions in schema pg_temp to authenticated;

-- S03: a second debit of Martin's booked payout x1, left to ops by the job, then booked by ops as an unplanned payout
-- (seeded, P = 0: the advance is all of it)
select pg_temp.stmt('b2', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1')))));
select pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.ln('b2', 1),
                                                               'reason', 'transfer_debited_twice')));
insert into t select 'u1', pg_temp.unplanned(pg_temp.ln('b2', 1), pg_temp.v('x1'), 'a1');
select is(array[pg_temp.dirty()::text, pg_temp.queued_minor('a1')::text, pg_temp.owed('a1')::text],
          array['{}', '0', '0'],
  'B (CSO2-12): the seeded unplanned booking (remittance, −A pending row, double_payout advance) keeps every invariant: '
  'Martin''s queue nets to 0 (−P), its 4670 at 0');
-- then a copy comes back, flagged by the bank (AC04), carrying x1's id
select pg_temp.stmt('b3', private.paris_today(), jsonb_build_array(
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1')))));
select is(pg_temp.return_facts(pg_temp.ln('b3', 1)),
          '{"role": "return", "unplanned_open": true, "debit_pending": false}'::jsonb,
  'B: the funds pass reads the return with its transfer''s open unplanned booking');
-- the job's row as a stale fact would send it (the twin reviews it itself): the re-check under the locks reviews it
select pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('b3', 1), 'payout_returned', pg_temp.v('x1'))));
select is(jsonb_build_object('why', pg_temp.skipped(pg_temp.ln('b3', 1)), 'review', pg_temp.review(pg_temp.ln('b3', 1)),
                             'bookings', pg_temp.bookings(pg_temp.ln('b3', 1)), 'x1', pg_temp.status(pg_temp.v('x1')),
                             'queue', pg_temp.queued_minor('a1'), 'account', pg_temp.payout_account('a1')),
          '{"why": "unplanned_payout_return", "review": "unplanned_payout_return", "bookings": [], "x1": "booked",
            "queue": 0, "account": "active"}'::jsonb,
  'B (F1, L5): a flagged return of a transfer with an open unplanned booking is never booked by the job — reviewed '
  'unplanned_payout_return, x1 still booked, nothing queued for Martin, its payout account active');
select pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.ln('b3', 1),
                                                               'reason', 'unplanned_payout_return')));
select is(pg_temp.review(pg_temp.ln('b3', 1)), 'unplanned_payout_return', 'B: the reason the twin writes is accepted');
-- once the unplanned booking is reversed (its remittance and its advance), the next return is the planned payout's
create or replace function pg_temp.b_reversed() returns jsonb language plpgsql as $$
begin
  perform private.ledger_reverse(pg_temp.ek('adv:line:' || pg_temp.ln('b2', 1) || ':1'), 'test-rev-adv-u1',
                                 'Avance annulée (test)', private.paris_today());
  perform private.ledger_reverse(pg_temp.v('u1'), 'test-rev-u1', 'Virement hors reversement revenu (test)',
                                 private.paris_today());
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('b3', 1), 'payout_returned', pg_temp.v('x1'))));
  return jsonb_build_object('facts', pg_temp.return_facts(pg_temp.ln('b3', 1)),
                            'bookings', pg_temp.bookings(pg_temp.ln('b3', 1)), 'x1', pg_temp.status(pg_temp.v('x1')),
                            'returned_items', pg_temp.returned_items('a1'),
                            'double_payout_open', pg_temp.alerts('double_payout_open'));
end $$;
select is(pg_temp.isolated('b_reversed'),
          jsonb_build_object('facts', null, 'bookings', jsonb_build_array('1 payout_returned 164000'), 'x1', 'returned',
                             'returned_items', 2, 'double_payout_open', '[]'::jsonb),
  'B: the unplanned booking reversed, the return books payout_returned(x1) as today (x1 returned, its item queued '
  'again beside the unplanned one''s), and the double payout''s advance is no longer open');

-- a cancelled transfer (Roux's run cancelled while its file was generated, never downloaded) executed late after all,
-- that late debit booked by ops as an unplanned payout (seeded), then a return of it
insert into t select 'r9', pg_temp.run('a5', '{"05": "30000", "11": "10000"}', 7200, 1200);
insert into t select 'x9', pg_temp.trid('r9');
insert into t select 'f3', (pg_temp.gen('01', 'gen-file-3') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f3'));
select is(pg_temp.try('04', format($q$ select public.cancel_remittance_run('cancel-r9-b', %L, %s, 'à refaire') ->> 'status' $q$,
                                   pg_temp.v('r9'), (select version from public.remittance_run where id = pg_temp.v('r9')))),
          'cancelled', 'B: Roux''s run cancelled before its file was downloaded');
select pg_temp.stmt('b4', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(pg_temp.v('x9')))));
select pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.ln('b4', 1),
                                                               'reason', 'cancelled_transfer_debited')));
insert into t select 'u9', pg_temp.unplanned(pg_temp.ln('b4', 1), pg_temp.v('x9'), 'a5');
select pg_temp.stmt('b5', private.paris_today(), jsonb_build_array(
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 32800, 'orig', pg_temp.e2e(pg_temp.v('x9')))));
select pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('b5', 1), 'payout_returned', pg_temp.v('x9'))));
select is(array[pg_temp.status(pg_temp.v('x9')), pg_temp.skipped(pg_temp.ln('b5', 1)), pg_temp.review(pg_temp.ln('b5', 1))],
          array['cancelled', 'unplanned_payout_return', 'unplanned_payout_return'],
  'B: a cancelled transfer executed late, with an open unplanned booking: its return is reviewed '
  'unplanned_payout_return, not return_differs');

-- ML-3: a second debit of Lilas' booked payout x2, left to ops (not booked), then a return of x2: never booked
select pg_temp.stmt('b6', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('x2')))));
select pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.ln('b6', 1),
                                                               'reason', 'transfer_debited_twice')));
select pg_temp.stmt('b7', private.paris_today(), jsonb_build_array(
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 419840, 'orig', pg_temp.e2e(pg_temp.v('x2')))));
select is(pg_temp.return_facts(pg_temp.ln('b7', 1)),
          '{"role": "return", "unplanned_open": false, "debit_pending": true}'::jsonb,
  'B (ML-3): the funds pass reads the return with its transfer''s debit pending on a statement');
select pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('b7', 1), 'payout_returned', pg_temp.v('x2'))));
select is(jsonb_build_object('why', pg_temp.skipped(pg_temp.ln('b7', 1)), 'review', pg_temp.review(pg_temp.ln('b7', 1)),
                             'bookings', pg_temp.bookings(pg_temp.ln('b7', 1)), 'x2', pg_temp.status(pg_temp.v('x2')),
                             'returned_items', pg_temp.returned_items('a2'), 'account', pg_temp.payout_account('a2')),
          '{"why": "return_debit_pending", "review": "return_debit_pending", "bookings": [], "x2": "booked",
            "returned_items": 0, "account": "active"}'::jsonb,
  'B (ML-3): a return of a transfer whose second debit is on a statement, not booked, is reviewed return_debit_pending: '
  'nothing booked, x2 still booked, no payout_returned item queued, the payout account active');
-- ML-3: a cancelled transfer (Durand's run cancelled while its file was generated) with its late debit unbooked, then
-- its return
insert into t select 'r7', pg_temp.run('a7', '{"07": "50000"}', 9000, 1500);
insert into t select 'x7', pg_temp.trid('r7');
insert into t select 'f4', (pg_temp.gen('01', 'gen-file-4') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f4'));
select is(pg_temp.try('04', format($q$ select public.cancel_remittance_run('cancel-r7-b', %L, %s, 'à refaire') ->> 'status' $q$,
                                   pg_temp.v('r7'), (select version from public.remittance_run where id = pg_temp.v('r7')))),
          'cancelled', 'B: Durand''s run cancelled before its file was downloaded');
select pg_temp.stmt('b8', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(pg_temp.v('x7')))));
select pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.ln('b8', 1),
                                                               'reason', 'cancelled_transfer_debited')));
select pg_temp.stmt('b9', private.paris_today(), jsonb_build_array(
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(pg_temp.v('x7')))));
select pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('b9', 1), 'payout_returned', pg_temp.v('x7'))));
select is(array[pg_temp.status(pg_temp.v('x7')), pg_temp.skipped(pg_temp.ln('b9', 1)), pg_temp.review(pg_temp.ln('b9', 1))],
          array['cancelled', 'return_debit_pending', 'return_debit_pending'],
  'B (ML-3): a cancelled transfer whose late debit is unbooked: its return is reviewed return_debit_pending');
select pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.ln('b9', 1),
                                                               'reason', 'return_debit_pending')));
select is(pg_temp.review(pg_temp.ln('b9', 1)), 'return_debit_pending', 'B: the reason the twin writes is accepted');

-- Review M2c-6b-2a (M1): a CSV export overlapping FA's debits holds Petit's debit (x8) as a suspected duplicate (same
-- day, amount and direction, a similar label, another fingerprint). While held it may be a second movement: the return
-- of x8 waits (return_debit_pending). Once ops decide it is a duplicate it is no movement: x8's return is booked as
-- before 6b-2a (x8 returned, its item queued again). The other servicer's ops cannot decide it.
create or replace function pg_temp.b_duplicate() returns jsonb language plpgsql as $$
declare
  v jsonb;
  v_x8 uuid := pg_temp.trid('r8');
  v_d8 uuid;
  v_q bigint;
begin
  perform pg_temp.statement('d1', private.paris_today() - 1, 0, jsonb_build_array(
    jsonb_build_object('e2e', pg_temp.e2e(v_x8), 'amount', 82000, 'kind', 'suspected_duplicate')), p_format => 'csv');
  select id into v_d8 from public.bank_transaction where statement_id = 'e2000000-0000-0000-0000-0000000000d1';
  perform pg_temp.stmt('ba', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 82000, 'orig', pg_temp.e2e(v_x8))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('ba', 1), 'payout_returned', v_x8)));
  v := jsonb_build_object('held', jsonb_build_object(
    'late', array(select private.transfer_late_lines(v_x8)) = array[v_d8],
    'facts', pg_temp.return_facts(pg_temp.ln('ba', 1)), 'review', pg_temp.review(pg_temp.ln('ba', 1))));
  v := v || jsonb_build_object('other_servicer', pg_temp.try('05', format(
    $q$ select public.resolve_duplicate('dup-b-05', %L, true, 'même débit') ->> 'decision' $q$, v_d8)));
  select coalesce(max(q.msg_id), 0) into v_q from pgmq.q_payments q;
  v := v || jsonb_build_object('decision', pg_temp.try('01', format(
    $q$ select public.resolve_duplicate('dup-b-d8', %L, true, 'même débit que le relevé camt') ->> 'decision' $q$,
    v_d8)));
  -- the decision queues the debit job (its return read again at once)
  v := v || jsonb_build_object('queued', (select jsonb_agg(q.message order by q.msg_id) from pgmq.q_payments q
                                           where q.msg_id > v_q));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('ba', 1), 'payout_returned', v_x8)));
  return v || jsonb_build_object('decided', jsonb_build_object(
    'late', array(select private.transfer_late_lines(v_x8)), 'facts', pg_temp.return_facts(pg_temp.ln('ba', 1)),
    'bookings', pg_temp.bookings(pg_temp.ln('ba', 1)), 'x8', pg_temp.status(v_x8),
    'returned_items', pg_temp.returned_items('a8')));
end $$;
select is(pg_temp.isolated('b_duplicate'),
  '{"held": {"late": true, "facts": {"role": "return", "unplanned_open": false, "debit_pending": true},
             "review": "return_debit_pending"},
    "other_servicer": "not allowed", "decision": "duplicate",
    "queued": [{"type": "process_debits", "organization_id": "00000000-0000-0000-0000-0000000000aa"}],
    "decided": {"late": [], "facts": null, "bookings": ["1 payout_returned 82000"], "x8": "returned",
                "returned_items": 1}}'::jsonb,
  'B (review M1): a debit held as a suspected duplicate keeps a return waiting (return_debit_pending); decided a '
  'duplicate, it is no movement and the debit job is queued — the return is booked payout_returned as before 6b-2a; '
  'another servicer''s ops may not decide it');

-- Review M2c-6b-2a (T4): the order of the two rules. Both facts true (an open unplanned booking and a debit pending):
-- unplanned_payout_return first. A transfer returned, executed again and that copy booked by ops (S03r), then the copy
-- returned: unplanned_payout_return, never already_returned.
create or replace function pg_temp.b_both() returns jsonb language plpgsql as $$
begin
  perform pg_temp.stmt('bb', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('b3', 1), 'payout_returned', pg_temp.v('x1'))));
  return jsonb_build_object('facts', pg_temp.return_facts(pg_temp.ln('b3', 1)), 'why', pg_temp.skipped(pg_temp.ln('b3', 1)),
                            'bookings', pg_temp.bookings(pg_temp.ln('b3', 1)));
end $$;
create or replace function pg_temp.b_returned_again() returns jsonb language plpgsql as $$
declare v_status text;
begin
  perform private.ledger_reverse(pg_temp.ek('adv:line:' || pg_temp.ln('b2', 1) || ':1'), 'test-rev-adv-u1',
                                 'Avance annulée (test)', private.paris_today());
  perform private.ledger_reverse(pg_temp.v('u1'), 'test-rev-u1', 'Virement hors reversement revenu (test)',
                                 private.paris_today());
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('b3', 1), 'payout_returned', pg_temp.v('x1'))));
  v_status := pg_temp.status(pg_temp.v('x1'));
  perform pg_temp.stmt('bc', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1')))));
  perform pg_temp.unplanned(pg_temp.ln('bc', 1), pg_temp.v('x1'), 'a1');
  perform pg_temp.stmt('bd', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('bd', 1), 'payout_returned', pg_temp.v('x1'))));
  return jsonb_build_object('returned', v_status, 'facts', pg_temp.return_facts(pg_temp.ln('bd', 1)),
                            'why', pg_temp.skipped(pg_temp.ln('bd', 1)), 'bookings', pg_temp.bookings(pg_temp.ln('bd', 1)),
                            'x1', pg_temp.status(pg_temp.v('x1')));
end $$;
select is(jsonb_build_array(pg_temp.isolated('b_both'), pg_temp.isolated('b_returned_again')),
  '[{"facts": {"role": "return", "unplanned_open": true, "debit_pending": true}, "why": "unplanned_payout_return",
     "bookings": []},
    {"returned": "returned", "facts": {"role": "return", "unplanned_open": true, "debit_pending": false},
     "why": "unplanned_payout_return", "bookings": [], "x1": "returned"}]'::jsonb,
  'B (review T4): an open unplanned booking comes before a pending debit, and before already_returned (S03r: a returned '
  'transfer executed again, that copy booked by ops, then returned)');

-- Review M2c-6b-2a (T2): the unplanned_sweep arm — FA's booked sweep executed again, that copy booked by ops as an
-- unplanned sweep (seeded: its servicer_sweep entry and booking), then a flagged return of the sweep: reviewed, never
-- booked by the job, the sweep still booked
create or replace function pg_temp.b_sweep_again() returns jsonb language plpgsql as $$
declare v_entry uuid;
begin
  perform pg_temp.stmt('be', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('sa')), 'iban', 'FR7610107001011234567890129')));
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id, reason)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'servicer_sweep', private.paris_today(), 'test-unplanned-sweep-b',
          'bank_transfer', pg_temp.v('sa')::text, 'Quote-part exécutée deux fois (test)');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'due_to_servicer', 12000, 'EUR', null),
    (1, 2, 'client_money_cash', -12000, 'EUR', '80000000-0000-0000-0000-0000000000cf'),
    (1, 3, 'own_cash', 12000, 'EUR', '80000000-0000-0000-0000-0000000000c0'),
    (1, 4, 'due_from_client_funds', -12000, 'EUR', null);
  perform private.ledger_post_set();
  v_entry := pg_temp.ek('test-unplanned-sweep-b');
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method, reason, decided_by)
  values (pg_temp.ln('be', 1), 1, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
          'unplanned_sweep', pg_temp.v('sa'), v_entry, 12000, 'ops', 'motif de test',
          '10000000-0000-0000-0000-000000000001');
  perform pg_temp.stmt('bf', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 12000, 'orig', pg_temp.e2e(pg_temp.v('sa')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('bf', 1), 'sweep_returned', pg_temp.v('sa'))));
  return jsonb_build_object('facts', pg_temp.return_facts(pg_temp.ln('bf', 1)), 'why', pg_temp.skipped(pg_temp.ln('bf', 1)),
                            'review', pg_temp.review(pg_temp.ln('bf', 1)), 'bookings', pg_temp.bookings(pg_temp.ln('bf', 1)),
                            'sweep', pg_temp.status(pg_temp.v('sa')));
end $$;
select is(pg_temp.isolated('b_sweep_again'),
  '{"facts": {"role": "return", "unplanned_open": true, "debit_pending": false}, "why": "unplanned_payout_return",
    "review": "unplanned_payout_return", "bookings": [], "sweep": "booked"}'::jsonb,
  'B (review T2): a return of a sweep with an open unplanned sweep booking is reviewed unplanned_payout_return, never '
  'booked by the job, the sweep still booked');
select is(pg_temp.dirty(), '{}'::text[], 'B: clean (I8′, I12, I13, I14, I19, I20, bank_line_booked)');


-- E. Alerts (plan §2.6; critic L10, L14) -----------------------------------------------------------------------------------
-- the transfer checks' rows of a code as of p_today, as their subject and amount
create or replace function pg_temp.alerts_at(p_code text, p_today date) returns jsonb language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_transfer_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return coalesce((select jsonb_agg(jsonb_build_array(c.subject_id, c.amount_minor) order by c.amount_minor, c.subject_id)
                   from public.payment_check_result c where c.run_id = v and c.code = p_code), '[]');
end $$;
-- the lines bank_line_unbooked counts as of p_today (its ids)
create or replace function pg_temp.unbooked_at(p_today date) returns jsonb language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_transfer_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return coalesce((select c.details -> 'ids' from public.payment_check_result c
                   where c.run_id = v and c.code = 'bank_line_unbooked'), '[]');
end $$;
-- transfer_unknown (P0, L14): a debit and a credit carrying an RMT id no transfer of ours has, reviewed so by the job
select pg_temp.stmt('e1', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 5000, 'e2e', 'RMT0000000000E1'),
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 6000, 'orig', 'RMT0000000000E2')));
select pg_temp.book('[]', jsonb_build_array(
  jsonb_build_object('line', pg_temp.ln('e1', 1), 'reason', 'transfer_unknown'),
  jsonb_build_object('line', pg_temp.ln('e1', 2), 'reason', 'transfer_unknown')));
select is(pg_temp.alerts('transfer_unknown'),
          jsonb_build_array(jsonb_build_array(pg_temp.ln('e1', 1), 5000), jsonb_build_array(pg_temp.ln('e1', 2), 6000)),
  'E (L14): transfer_unknown, P0, on the debit and on the credit the job reviewed so');
-- double_payout_open: the double payouts' advances, open
select is(pg_temp.alerts('double_payout_open'),
          jsonb_build_array(
            jsonb_build_array((select a.id from public.client_advance a
                               where a.bank_transaction_id = pg_temp.ln('b4', 1)), 32800),
            jsonb_build_array((select a.id from public.client_advance a
                               where a.bank_transaction_id = pg_temp.ln('b2', 1)), 164000)),
  'E: double_payout_open on each double payout''s advance while open (gone once its entry is reversed: B)');
-- bank_line_unbooked's new members (left to ops more than one business day): an unsplit debit holding ours, a credit
-- naming our lot, a client's credit carrying our RMT id (S16), the lines reviewed unplanned_payout_return and
-- return_debit_pending
select pg_temp.stmt('e2', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 7000, 'kind', 'batch_unsplit', 'unsplit', 1),
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 8000, 'pmt', pg_temp.pmt(pg_temp.v('x1'))),
  jsonb_build_object('dir', 'credit', 'kind', 'client_transfer_in', 'amount', 9000, 'e2e', pg_temp.e2e(pg_temp.v('x2')),
                     'iban', 'FR1420041010050500013M02606')));
select pg_temp.book('[]', jsonb_build_array(
  jsonb_build_object('line', pg_temp.ln('e2', 1), 'reason', 'batch_partial'),
  jsonb_build_object('line', pg_temp.ln('e2', 2), 'reason', 'return_differs'),
  jsonb_build_object('line', pg_temp.ln('e2', 3), 'reason', 'client_credit')));
create temporary table unb (k text primary key, v jsonb) on commit drop;
insert into unb values ('today', pg_temp.unbooked_at(private.paris_today())), ('later', pg_temp.unbooked_at(pg_temp.bd_after(2)));
select is(jsonb_build_array(
            (select v from unb where k = 'later') @> jsonb_build_array(pg_temp.ln('e2', 1), pg_temp.ln('e2', 2),
                                                                      pg_temp.ln('e2', 3), pg_temp.ln('b3', 1),
                                                                      pg_temp.ln('b5', 1), pg_temp.ln('b7', 1),
                                                                      pg_temp.ln('b9', 1)),
            (select v from unb where k = 'today') ?| array[pg_temp.ln('e2', 1)::text, pg_temp.ln('e2', 2)::text,
                                                         pg_temp.ln('e2', 3)::text, pg_temp.ln('b3', 1)::text,
                                                         pg_temp.ln('b7', 1)::text]),
          '[true, false]'::jsonb,
  'E: bank_line_unbooked counts, after one business day and not before, an unsplit debit holding ours, a credit naming '
  'our lot, a client''s credit carrying our id, and the lines reviewed unplanned_payout_return or return_debit_pending');
-- own_transfer_payment (P0, L10): a payment made of an RMT credit before round 4 (seeded), unassigned
create or replace function pg_temp.own_payment(p_n text, p_e2e text, p_amount bigint, p_pmt text default null)
returns uuid language plpgsql as $$
declare s uuid := ('e6000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 'o.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, 1, 't:' || s, 'credit',
          p_amount, 'EUR', private.paris_today(), 'debtor_credit', p_e2e, p_pmt);
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, payer_name, end_to_end_id)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, 'camt053', 'sct',
          p_amount, 'EUR', private.paris_today(), 'RETOUR', p_e2e);
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_in', private.paris_today(),
          'cash_in:' || s || ':' || private.paris_today(), 'bank_statement', s::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cf'),
    (1, 2, 'unallocated_payment', -p_amount, 'EUR', null);
  perform private.ledger_post_set();
  update public.bank_statement set status = 'imported', from_date = private.paris_today(),
    to_date = private.paris_today(), counts = '{}', finished_at = clock_timestamp()
  where id = s;
  return s;
end $$;
insert into t select 'op', pg_temp.own_payment('01', pg_temp.e2e(pg_temp.v('x2')), 5500);
-- and one made of a credit naming one of our lots (FA's PmtInf of x1) under an end-to-end id that is not ours (round 8
-- T1's shape: private.names_our_lot, not names_our_transfer, reads it)
insert into t select 'ol', pg_temp.own_payment('02', 'VIR-CLIENT-0042', 5600, pg_temp.pmt(pg_temp.v('x1')));
create or replace function pg_temp.e_refunded() returns jsonb language plpgsql as $$
begin
  update public.payment set status = 'refunded' where id in (pg_temp.v('op'), pg_temp.v('ol'));
  return pg_temp.alerts_at('own_transfer_payment', pg_temp.bd_after(2));
end $$;
select is(jsonb_build_array(pg_temp.alerts_at('own_transfer_payment', private.paris_today()),
                            pg_temp.alerts_at('own_transfer_payment', pg_temp.bd_after(2)),
                            pg_temp.isolated('e_refunded')),
          jsonb_build_array('[]'::jsonb, jsonb_build_array(jsonb_build_array(pg_temp.v('op'), 5500),
                                                           jsonb_build_array(pg_temp.v('ol'), 5600)), '[]'::jsonb),
  'E (L10): own_transfer_payment, P0, on a payment made of a credit carrying our RMT id or naming one of our lots, '
  'unassigned for more than one business day; not before; gone once it is no longer unassigned');
-- payout_returned and sweep_returned on the returns of an unplanned payout and sweep (6b-2b's
-- unplanned_payout_returned and unplanned_sweep_returned, seeded: no rule of the booking guard admits them before
-- 6b-2b, so the seed sets it aside inside the rolled-back scenario): each alerted once, by its booking — an unplanned
-- payout's return never also as its transfer's planned one
create or replace function pg_temp.e_unplanned_returns() returns jsonb language plpgsql as $$
declare
  v_before jsonb := pg_temp.alerts('payout_returned');
  v_sweeps jsonb := pg_temp.alerts('sweep_returned');
  v_rev uuid;
  v_sw uuid;
  v_srev uuid;
  v_after jsonb;
  v_safter jsonb;
begin
  -- the guard's rules for these kinds come with 6b-2b: set aside here, restored by the scenario's rollback
  create or replace function private.bank_line_booking_guard() returns trigger language plpgsql as $f$
  begin
    return null;
  end $f$;
  -- ops book b3 as u1's return: u1's remittance reversed (its item owed again, queued by the reversal)
  select r.entry_id into v_rev from private.ledger_reverse(pg_temp.v('u1'), 'test-rev-u1-returned',
                                                           'Retour du virement hors reversement (test)',
                                                           private.paris_today()) r;
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method, reason, decided_by)
  values (pg_temp.ln('b3', 1), 1, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
          'unplanned_payout_returned', pg_temp.v('x1'), v_rev, 164000, 'ops', 'motif de test',
          '10000000-0000-0000-0000-000000000001');
  -- FA's sweep executed again (an unplanned sweep, its entry only), then that copy returned and booked by ops
  perform pg_temp.stmt('e9', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 12000, 'orig', pg_temp.e2e(pg_temp.v('sa')))));
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id, reason)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'servicer_sweep', private.paris_today(), 'test-unplanned-sweep',
          'bank_transfer', pg_temp.v('sa')::text, 'Quote-part exécutée hors fichier (test)');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'due_to_servicer', 12000, 'EUR', null),
    (1, 2, 'client_money_cash', -12000, 'EUR', '80000000-0000-0000-0000-0000000000cf'),
    (1, 3, 'own_cash', 12000, 'EUR', '80000000-0000-0000-0000-0000000000c0'),
    (1, 4, 'due_from_client_funds', -12000, 'EUR', null);
  perform private.ledger_post_set();
  v_sw := pg_temp.ek('test-unplanned-sweep');
  select r.entry_id into v_srev from private.ledger_reverse(v_sw, 'test-rev-unplanned-sweep',
                                                            'Retour de la quote-part (test)', private.paris_today()) r;
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method, reason, decided_by)
  values (pg_temp.ln('e9', 1), 1, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
          'unplanned_sweep_returned', pg_temp.v('sa'), v_srev, 12000, 'ops', 'motif de test',
          '10000000-0000-0000-0000-000000000001');
  v_after := pg_temp.alerts('payout_returned');
  v_safter := pg_temp.alerts('sweep_returned');
  -- review M2c-6b-2a (T5): once the share is ordered swept again (a newer sweep, not cancelled), that return is no
  -- longer alerted (the sweep's row seeded as the generation writes it, created after the return was booked)
  insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id, creditor_bank_account_id, currency,
                                    amount_minor, payee_name, payee_iban, end_to_end_id, remittance_info,
                                    requested_execution_date, created_at)
  values ('00000000-0000-0000-0000-0000000000aa', 'sweep', '80000000-0000-0000-0000-0000000000cf',
          '80000000-0000-0000-0000-0000000000c0', 'EUR', 12000, 'Collectoo SAS', 'FR7610107001011234567890129',
          'SWP0000000000E9', 'VIREMENT AU COMPTE PROPRE (test)', private.paris_today(), clock_timestamp());
  return jsonb_build_object(
    'payout_returned', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(v_after) x
                        where not v_before @> jsonb_build_array(x)),
    'payout_returned_gone', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(v_before) x
                             where not v_after @> jsonb_build_array(x)),
    'sweep_returned', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(v_safter) x
                       where not v_sweeps @> jsonb_build_array(x)),
    'swept_again', pg_temp.alerts('sweep_returned') @> jsonb_build_array(jsonb_build_array(pg_temp.ln('e9', 1), 12000)));
end $$;
select is(pg_temp.isolated('e_unplanned_returns'),
          jsonb_build_object('payout_returned', jsonb_build_array(jsonb_build_array(pg_temp.ln('b3', 1), 164000)),
                             'payout_returned_gone', '[]'::jsonb,
                             'sweep_returned', jsonb_build_array(jsonb_build_array(pg_temp.ln('e9', 1), 12000)),
                             'swept_again', false),
  'E: the return of an unplanned payout (seeded as 6b-2b books it) is alerted payout_returned once, by its line — never '
  'also as its transfer''s planned return —, and the return of an unplanned sweep sweep_returned, by its line, until '
  'the share is ordered swept again');
-- Review M2c-6b-2a (M2, T1): a line held as a suspected duplicate keeps that kind; released by ops, the job reads it as
-- the kind it was released as (a credit returning x2 is reviewed return_debit_pending: x2's second debit is still
-- unbooked). bank_line_unbooked counts it after one business day, as the identical camt return b7, by that kind
create or replace function pg_temp.e_released_return() returns jsonb language plpgsql as $$
declare v jsonb; v_later jsonb;
begin
  -- ea: a second copy of x2's return; eb: a return carrying an id no transfer of ours has; ec: a copy of x2's debit;
  -- ed: a credit carrying x2's id from Lilas' payout IBAN — each held, then released by ops as what it is
  perform pg_temp.stmt('ea', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'suspected_duplicate', 'amount', 419840,
                       'orig', pg_temp.e2e(pg_temp.v('x2'))),
    jsonb_build_object('dir', 'credit', 'kind', 'suspected_duplicate', 'amount', 7700, 'orig', 'RMT0000000000E5'),
    jsonb_build_object('kind', 'suspected_duplicate', 'amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('x2'))),
    jsonb_build_object('dir', 'credit', 'kind', 'suspected_duplicate', 'amount', 7800, 'e2e', pg_temp.e2e(pg_temp.v('x2')),
                       'iban', 'FR1420041010050500013M02606')));
  v := jsonb_build_object('released', jsonb_build_array(
    pg_temp.try('01', format($q$ select public.resolve_duplicate('dup-e-ea', %L, false, 'second retour') ->> 'kind' $q$,
                             pg_temp.ln('ea', 1))),
    pg_temp.try('01', format($q$ select public.resolve_duplicate('dup-e-eb', %L, false, 'un retour') ->> 'kind' $q$,
                             pg_temp.ln('ea', 2))),
    pg_temp.try('01', format($q$ select public.resolve_duplicate('dup-e-ec', %L, false, 'second débit') ->> 'kind' $q$,
                             pg_temp.ln('ea', 3))),
    pg_temp.try('01', format($q$ select public.resolve_duplicate('dup-e-ed', %L, false, 'crédit du client') ->> 'kind' $q$,
                             pg_temp.ln('ea', 4)))));
  -- the job: ea's return reviewed under its re-check; the others' reviews as the job writes them
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('ea', 1), 'payout_returned', pg_temp.v('x2'))),
                       jsonb_build_array(jsonb_build_object('line', pg_temp.ln('ea', 2), 'reason', 'transfer_unknown'),
                                         jsonb_build_object('line', pg_temp.ln('ea', 3), 'reason', 'transfer_debited_twice'),
                                         jsonb_build_object('line', pg_temp.ln('ea', 4), 'reason', 'client_credit')));
  v_later := pg_temp.unbooked_at(pg_temp.bd_after(2));
  return v || jsonb_build_object(
    'reviews', jsonb_build_array(pg_temp.review(pg_temp.ln('ea', 1)), pg_temp.review(pg_temp.ln('ea', 2)),
                                 pg_temp.review(pg_temp.ln('ea', 3)), pg_temp.review(pg_temp.ln('ea', 4))),
    'today', pg_temp.unbooked_at(private.paris_today()) ?| array[pg_temp.ln('ea', 1)::text, pg_temp.ln('ea', 2)::text,
                                                               pg_temp.ln('ea', 3)::text, pg_temp.ln('ea', 4)::text],
    'later', jsonb_build_array(v_later ? pg_temp.ln('ea', 1)::text, v_later ? pg_temp.ln('ea', 2)::text,
                               v_later ? pg_temp.ln('ea', 3)::text, v_later ? pg_temp.ln('ea', 4)::text),
    'b7_later', v_later ? pg_temp.ln('b7', 1)::text);
end $$;
select is(pg_temp.isolated('e_released_return'),
  '{"released": ["return", "return", "transfer_out", "client_transfer_in"],
    "reviews": ["return_debit_pending", "transfer_unknown", "transfer_debited_twice", "client_credit"],
    "today": false, "later": [true, true, true, true], "b7_later": true}'::jsonb,
  'E (review M2, T1): a held line released by ops is read as the kind it was released as — a return (reviewed '
  'return_debit_pending or transfer_unknown), our transfer''s debit, a client''s credit carrying our id: '
  'bank_line_unbooked counts each after one business day, as the same lines imported as what they are');

-- the M2b pass: a link on one of our lines refused under its locks is reviewed own_transfer_line (S20, OQ-84 (i)), not
-- `changed`
select pg_temp.stmt('e3', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 1000, 'kind', 'return', 'e2e', pg_temp.e2e(pg_temp.v('x2')))));
create or replace function pg_temp.m2b(p_line uuid, p_kind text, p_payment uuid) returns jsonb language plpgsql as $$
begin
  perform private.debit_link_begin();
  insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, method)
  values (1, p_line, p_kind, p_payment, 'auto');
  return private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
end $$;
select pg_temp.m2b(pg_temp.ln('e3', 1), 'return', pg_temp.pay('13'));
select is(pg_temp.review(pg_temp.ln('e3', 1)), 'own_transfer_line',
  'E: the M2b pass reviews a link it refused on our own line own_transfer_line');
select is(pg_temp.dirty(), '{}'::text[], 'E: clean');


-- F. The S23 texts (plan §2.6; critic L10): « ne peut pas encore », no screen promised -------------------------------------
create or replace function pg_temp.hint(p_sql text) returns text language sql as $$
  select split_part(pg_temp.attempt(p_sql), ' | ', 2) $$;
create or replace function pg_temp.f_assign() returns text language plpgsql as $$
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.assign_payment('f-assign-0001', pg_temp.v('op'),
                                jsonb_build_array(jsonb_build_object('account_id', pg_temp.f('01'))), null, 'test');
  reset role;
  return 'assigned';
end $$;
-- a held duplicate carrying our RMT id, read as a debtor's credit before round 4 (its reading recorded)
create or replace function pg_temp.f_release() returns text language plpgsql as $$
declare s uuid := ('e6000000-0000-0000-0000-0000000000f2')::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'csv', 'h.csv',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, 1, 'h:' || s, 'credit',
          6600, 'EUR', private.paris_today(), 'suspected_duplicate', pg_temp.e2e(pg_temp.v('x2')));
  insert into private.bank_line_held_kind (bank_transaction_id, kind, method) values (s, 'debtor_credit', 'sct');
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.resolve_duplicate('f-release-0001', s, false, 'test');
  reset role;
  return 'released';
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(array[pg_temp.hint('select pg_temp.f_assign()'), pg_temp.hint('select pg_temp.f_release()')],
          array['Ce paiement vient d''une ligne qui porte la référence de l''un de nos propres virements (reversement, '
                'quote-part du cabinet, lot de notre fichier) : c''est ce virement qui revient, pas le paiement d''un '
                'débiteur. Il ne s''affecte à aucun dossier, et Collectoo ne peut pas encore le comptabiliser comme le '
                'retour de ce virement (un paiement enregistré ne se défait pas ; prévu avec M2c-7) : prévenez le '
                'support.',
                'Cette ligne porte la référence de l''un de nos propres virements (reversement, quote-part du cabinet, '
                'lot de notre fichier) : c''est ce virement qui revient, jamais le paiement d''un débiteur. Lue ainsi '
                'avant la correction de l''import, elle ne peut être ni libérée comme un paiement ni encore '
                'comptabilisée comme ce retour : elle reste dans « Doublons possibles ». Prévenez le support.'],
  'F (L10): « Affecter » and « Libérer » on our own transfer coming back say Collectoo cannot book it as that return yet '
  '(prévenez le support), and promise no screen');
select is(private.own_transfer_line_hint('bank_booking'),
  'Cette ligne est un débit ou un retour de nos propres virements (reversement, quote-part du cabinet, lot de notre '
  'fichier) : elle se comptabilise depuis le relevé, automatiquement à l''import ou par l''équipe dans « Débits et '
  'retours » (débit d''un reversement, virement hors reversement, virement au compte propre, virement revenu) ; sinon '
  'elle attend le détail de la banque : prévenez le support. Elle ne se rattache pas à un paiement et ne se classe pas '
  'sans comptabilisation.',
  'F: the funds pass''s own-line hint, now one place (6b-2c reworded it with the screen: « Débits et retours »)');
-- « Perte » by ops on our line (the funds pass's strict re-check), as 035's S2 case
create or replace function pg_temp.s2_loss(p_line uuid, p_amount bigint) returns text language plpgsql as $$
begin
  perform private.bank_booking_begin();
  insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, amount_minor, method, decided_by, reason)
  values (1, p_line, 'loss', p_amount, 'ops', '10000000-0000-0000-0000-000000000001', 'motif de test');
  return (private.post_bank_bookings('00000000-0000-0000-0000-0000000000aa', true) ->> 'losses');
end $$;
select is(split_part(pg_temp.attempt(format('select pg_temp.s2_loss(%L, 1000)', pg_temp.ln('e3', 1))), ' | ', 2),
          private.own_transfer_line_hint('bank_booking'),
  'F: the strict refusal own_transfer_line carries that hint');

select * from finish();
rollback;
