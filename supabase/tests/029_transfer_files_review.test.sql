-- M2c-6a review fixes (findings pain001#0–#4, money#0–#3, security#0–#3, concurrency-perf#0–#3, tests-ui#0–#10;
-- design §9.7, §11, §12, §15; ADR-0014 M2c-6a; risk R4). 028 holds the slice's own cases; this file the review's:
--   * T7 file numbers never cut; T3 a payee name with no EPC letter, an IBAN outside the SEPA schemes: held out (not
--     failing the file), alerted, refunds by hand;
--   * T2 the first download re-runs the generation checks: a passed date (file_stale), a payee check, the cash short
--     by debits imported since (tests-ui#4), the payout account changed (file_blocked): superseded, never served;
--   * T5 a payee check cleared by none of who recorded it, proposed or confirmed the IBAN; closed with its account;
--   * T1 a downloaded file cancelled, or one transfer of it, only on the statements' evidence and by two people
--     (no_statement_evidence, already_requested, same_person, a request made stale by a download, a batch debit by
--     PmtInfId read by design §12's rule — pain001#3 —, a return as evidence); a run, a refund, a sweep after it;
--   * T6 file_not_marked_sent at the cut-off and through the hourly schedule, transfer_file_pending,
--     file_not_downloaded; tests-ui#3 the per-client cap counts the client's other runs in flight;
--   * tests-ui#0 no caller outside the servicer's money staff at aal2 runs any command; T4 the bucket.
-- Since round 2 (D1, 030) a cancellation needs its days over: a file whose cancellation is asked is set back to a past
-- business day once downloaded (pg_temp.backdate: « time moves on »), its evidence statements dated then.
-- No ledger entry is posted by any of it.
begin;
select plan(96);

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
from unnest(array['01', '02', '03', '04', '05', '06', '07', '08', '09', '10']) n;
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
  ('10000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-0000000000aa', 'admin');
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
-- [{e2e, amount, kind, pmt_inf}] booked on p_to.
create or replace function pg_temp.statement(p_n text, p_to date, p_closing bigint, p_debits jsonb default '[]',
                                             p_from date default null)
returns uuid language plpgsql as $$
declare s uuid := ('e2000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       original_end_to_end_id)
  select '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, d.ord, 't:' || s || d.ord,
         coalesce(d.v ->> 'dir', 'debit'), (d.v ->> 'amount')::bigint, 'EUR', p_to,
         coalesce(d.v ->> 'kind', 'transfer_out'), d.v ->> 'e2e', d.v ->> 'pmt_inf', d.v ->> 'orig_e2e'
  from jsonb_array_elements(p_debits) with ordinality d (v, ord);
  update public.bank_statement set status = 'imported', from_date = coalesce(p_from, p_to), to_date = p_to,
    opening_booked_minor = 0, closing_booked_minor = p_closing, counts = '{}', finished_at = clock_timestamp(),
    -- the bank's creation time the import keeps (review round 3, E4): here its upload's; the section's period, the
    -- whole days it shows and its balances, as the parser gives them (review round 4, G3: its opening, the previous
    -- statement's closing — the balances follow, no « relevé manquant »)
    sections = jsonb_build_array(jsonb_build_object(
      'from_date', coalesce(p_from, p_to), 'to_date', p_to, 'covers_from', coalesce(p_from, p_to), 'covers_to', p_to,
      'opening_minor', coalesce((select p.closing_booked_minor from public.bank_statement p
                                 where p.bank_account_id = '80000000-0000-0000-0000-0000000000cf'
                                   and p.status = 'imported' and p.format = 'camt053'
                                   and p.to_date < coalesce(p_from, p_to)
                                 order by p.to_date desc, p.finished_at desc limit 1), 0)::text,
      'closing_minor', p_closing::text, 'created_at', now()))
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
create temporary table _entries on commit drop as select count(*) as n from public.ledger_entry;
select results_eq($$ select r.status, r.net_minor, t.status, t.kind, left(t.end_to_end_id, 3), t.amount_minor
                     from public.remittance_run r left join public.bank_transfer t on t.id = r.transfer_id
                     where r.id in (select v from t where k in ('r1', 'r2', 'r3')) order by r.number $$,
  $$ values ('approved'::text, 164000::bigint, 'ordered'::text, 'payout'::text, 'RMT'::text, 164000::bigint),
            ('approved', 419840, 'ordered', 'payout', 'RMT', 419840),
            ('booked', 0, null, null, null, null) $$,
  'fixture: two payouts ordered at approval, Cyprès settled at approval (N = 0)');
select is((select -sum(lp.amount_minor) from public.ledger_posting lp join public.ledger_account la
           on la.id = lp.ledger_account_id where la.book = 'due_to_servicer'
             and la.organization_id = '00000000-0000-0000-0000-0000000000aa'), 12000::numeric,
  'fixture: 120,00 € of the servicer on the dedicated account (−4679)');

-- Omega 100 000 → net 82 000 (its RIB holder ΩΜΕΓΑ ΑΕ); Tunis Trading 50 000 → net 41 000 (a TN IBAN)
select pg_temp.file('04', '20000000-0000-0000-0000-0000000000a4', 100000);
select pg_temp.file('05', '20000000-0000-0000-0000-0000000000a5', 50000);
select pg_temp.collect('04', 100000, private.paris_today() - 3);
select pg_temp.collect('05', 50000, private.paris_today() - 3);
insert into t select 'r4', pg_temp.run('a4', '{"04": "100000"}', 18000, 3000);
insert into t select 'r5', pg_temp.run('a5', '{"05": "50000"}', 9000, 1500);
create or replace function pg_temp.e() returns date language sql as $$ select private.next_business_day(private.paris_today()) $$;
create or replace function pg_temp.n() returns date language sql as $$ select private.next_business_day(pg_temp.e()) $$;
-- review round 2 (D1): a cancellation needs its days over — time moves on: a file whose cancellation is asked is set
-- back, after its download, to X, a past business day (its next business day Y), before the fixture's statements
create or replace function pg_temp.x() returns date language sql as $$
  select c.day from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day < private.paris_today()
    and c.day > private.paris_today() - 60
  order by c.day desc offset 9 limit 1 $$;
create or replace function pg_temp.y() returns date language sql as $$ select private.next_business_day(pg_temp.x()) $$;
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
create or replace function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
create or replace function pg_temp.trid(p_run text) returns uuid language sql as $$
  select transfer_id from public.remittance_run where id = pg_temp.v(p_run) $$;
create or replace function pg_temp.sweep(p_file uuid) returns public.bank_transfer language sql as $$
  select t.* from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
  where i.file_id = p_file and t.kind = 'sweep' $$;
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
-- the SQLSTATE a statement ends with as user p_user (or 'ok')
create or replace function pg_temp.state(p_user text, p_aal text, p_sql text) returns text language plpgsql as $$
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    execute p_sql;
  exception when others then
    reset role;
    return sqlstate;
  end;
  reset role;
  return 'ok';
end $$;
-- as the collector, Martin's administrator, another servicer's ops manager, and our ops manager at aal1
create or replace function pg_temp.outsiders(p_sql text) returns text[] language sql as $$
  select array[pg_temp.state('02', 'aal2', p_sql), pg_temp.state('03', 'aal2', p_sql), pg_temp.state('05', 'aal2', p_sql),
               pg_temp.state('01', 'aal1', p_sql)] $$;
grant execute on all functions in schema pg_temp to authenticated;
select pg_temp.statement('01', private.paris_today() - 2, 1000000);

-- T7 file numbers (concurrency-perf#3) ---------------------------------------------------------------------------
select is(private.transfer_file_number('2026-11-11', 97) || ' ' || private.transfer_file_number('2026-11-11', 1000000),
  'TF-2026-000097 TF-2026-1000000', 'a file number grows past 999 999 instead of being cut (no duplicate MsgId)');
select is((select count(distinct private.transfer_file_number('2026-11-11', n)) from generate_series(999995, 1000015) n),
  21::bigint, 'every sequence value its own number');
select ok(length(private.transfer_file_number('2026-11-11', 9223372036854775807)) <= 35
          and private.transfer_file_number('2026-11-11', 9223372036854775807) ~ '^TF-[0-9]{4}-[0-9]{6,}$',
  'any bigint gives a MsgId of 35 characters at most, as the file''s checks want');

-- T3 the EPC set and the SEPA schemes' countries (pain001#2, #4, concurrency-perf#1) -------------------------------
select results_eq($$ select private.epc_name_empty(x) from unnest(array['Иван Петров', '王伟', 'Γιώργος Παπαδόπουλος', 'محمد',
                                                                       '@@@', '', ' ', 'Société Œuvres', 'L’Oréal', 'ẞ', 'Ａ'])
                       with ordinality u (x, o) order by o $$,
  $$ values (true), (true), (true), (true), (true), (true), (true), (false), (false), (false), (false) $$,
  'a name with no EPC letter once transliterated (the writer''s epc_text gives nothing), and names it can write');
select results_eq($$ select private.iban_in_sepa(x) from unnest(array['FR7630004000031234567890143', 'CH9300762011623852957',
                                                                     'GB29NWBK60161331926819', 'TN5910006035183598478831',
                                                                     'TR330006100519786457841326', 'BR1800360305000010009795493C1',
                                                                     'AE070331234567890123456'])
                       with ordinality u (x, o) order by o $$,
  $$ values (true), (true), (true), (false), (false), (false), (false) $$,
  'the SEPA schemes'' countries (EPC409-09): France, Switzerland, the United Kingdom; not Tunisia, Turkey, Brazil, the UAE');
select is((select count(*)::int from private.sepa_scheme_country where area in ('eu', 'eea', 'non_eea')), 41,
  'the list: 27 EU, 3 other EEA and 11 non-EEA countries (EPC409-09 v8.0)');

-- Generation: such transfers are held out, the file goes (not failed for everyone); alerted ----------------------
insert into j select 'g1', pg_temp.gen('01', 'rv-gen-0001');
insert into t select 'f1', (v ->> 'file_id')::uuid from j where k = 'g1';
select results_eq($$ select (v ->> 'nb_of_txs')::int,
                            (select array_agg((h ->> 'transfer_id') || ' ' || (h ->> 'reason') order by h ->> 'reason')
                             from jsonb_array_elements(v -> 'held') h)
                     from j where k = 'g1' $$,
  $$ values (3, array[pg_temp.trid('r5') || ' iban_not_sepa', pg_temp.trid('r4') || ' payee_name_not_epc']) $$,
  'Tunis Trading''s IBAN and Omega''s Greek holder held out with their reasons; the others and the sweep go in the file');
-- T6 (tests-ui#10): a file the job has not written 15 minutes after its generation
select results_eq($$ select private.transfer_checks_due('00000000-0000-0000-0000-0000000000aa', now() + interval '10 minutes'),
                            private.transfer_checks_due('00000000-0000-0000-0000-0000000000aa', now() + interval '20 minutes') $$,
  $$ values (false, true) $$,
  'the hourly schedule runs the checks once a file is still pending 15 minutes after its generation');
insert into t select 'c0', pg_temp.chk(null);
insert into t select 'c0b', pg_temp.chk(private.paris_today() + 14);
select results_eq($$ select r.run_id = pg_temp.v('c0b'), r.code, r.subject_type, r.subject_id from public.payment_check_result r
                     where r.run_id in (pg_temp.v('c0'), pg_temp.v('c0b'))
                       and r.code in ('payee_name_not_epc', 'iban_not_sepa', 'transfer_file_pending')
                     order by 1, 2 $$,
  $$ values (false, 'iban_not_sepa'::text, 'bank_transfer'::text, pg_temp.trid('r5')),
            (false, 'payee_name_not_epc', 'bank_transfer', pg_temp.trid('r4')),
            (true, 'iban_not_sepa', 'bank_transfer', pg_temp.trid('r5')),
            (true, 'payee_name_not_epc', 'bank_transfer', pg_temp.trid('r4')),
            (true, 'transfer_file_pending', 'transfer_file', pg_temp.v('f1')) $$,
  'alerted: each transfer held for its name or IBAN at once; a file still pending, once 15 minutes have passed');
-- refunds by hand by default for such a payee; asked in a file: refused
select pg_temp.collect('06', 5000, private.paris_today() - 1, false);
select pg_temp.collect('07', 5000, private.paris_today() - 1, false);
select pg_temp.collect('08', 5000, private.paris_today() - 1, false);
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'rf6', public.request_refund('rv-rfd-0006', pg_temp.pay('06'), '5000', 'TN5910006035183598478831',
                                                  null, 'other', null, '5000', 'payeur en Tunisie');
insert into j select 'rf7', public.request_refund('rv-rfd-0007', pg_temp.pay('07'), '5000', null, 'Иван Петров', 'other',
                                                  null, '5000', 'payeur');
select results_eq($$ select v ->> 'execution_mode' from j where k in ('rf6', 'rf7') order by k $$,
  $$ values ('manual'::text), ('manual') $$, 'a refund to a non-SEPA IBAN or a non-Latin name is executed by hand by default');
select throws_ok(format($$ select public.request_refund('rv-rfd-0008', %L, '5000', 'TN5910006035183598478831', null, 'other',
                                                       null, '5000', 'payeur', 'file') $$, pg_temp.pay('08')),
  '23514', 'refund refused: iban_not_sepa', 'a file cannot pay an IBAN outside the SEPA schemes');
select throws_ok(format($$ select public.request_refund('rv-rfd-0009', %L, '5000', null, 'Иван Петров', 'other', null, '5000',
                                                       'payeur', 'file') $$, pg_temp.pay('08')),
  '23514', 'refund refused: payee_name_not_epc', 'nor a name with no EPC letter');
reset role;

-- T2 a passed date (pain001#0, money#0, concurrency-perf#0, tests-ui#1) --------------------------------------------
select pg_temp.write(pg_temp.v('f1'));
select is(private.transfer_file_card(pg_temp.fl(pg_temp.v('f1'))) ->> 'stale', null, 'a file generated today is current');
set constraints public.transfer_file_superseded_by_fkey immediate;
alter table public.transfer_file disable trigger transfer_file_guard;
update public.transfer_file set first_execution_date = private.paris_today() - 1,
                                last_execution_date = private.paris_today() - 1
where id = pg_temp.v('f1');
alter table public.transfer_file enable always trigger transfer_file_guard;
set constraints public.transfer_file_superseded_by_fkey deferred;
select is(private.transfer_file_card(pg_temp.fl(pg_temp.v('f1'))) ->> 'stale', 'execution_date_passed',
  'its date passed (time moved on, here: set aside): the page offers « Régénérer »');
insert into j select 'd1', pg_temp.download('01', pg_temp.v('f1'));
select results_eq($$ select v ->> 'refused', v ->> 'status', (pg_temp.fl(pg_temp.v('f1'))).status,
                            (pg_temp.fl(pg_temp.v('f1'))).download_count,
                            (select count(*)::int from public.transfer_file_download where file_id = pg_temp.v('f1'))
                     from j where k = 'd1' $$,
  $$ values ('file_stale'::text, 'superseded'::text, 'superseded'::text, 0, 0) $$,
  'downloading it: not served, superseded (design §11: regenerated with a new MsgId), no download recorded');
select results_eq($$ select array_agg(r.status order by r.number), array_agg(x.status order by r.number)
                     from public.remittance_run r join public.bank_transfer x on x.id = r.transfer_id
                     where r.id in (pg_temp.v('r1'), pg_temp.v('r2')) $$,
  $$ values (array['approved', 'approved'], array['ordered', 'ordered']) $$,
  'its runs not sent, its transfers back for the next file');

-- T2 a payee check since generation (security#0); T5 who may clear it (security#3) -------------------------------
insert into t select 'f2', (pg_temp.gen('01', 'rv-gen-0002') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f2'));
select pg_temp.as_user('09');
set local role authenticated;
insert into j select 'pc', public.record_payee_name_mismatch('rv-vop-0001', pg_temp.trid('r2'), 'no_match', null,
                                                             'La banque ne reconnaît pas le titulaire');
reset role;
insert into j select 'd2', pg_temp.download('01', pg_temp.v('f2'));
select results_eq($$ select v ->> 'refused',
                            (select array_agg((b ->> 'transfer_id') || ' ' || (b ->> 'reason'))
                             from jsonb_array_elements(v -> 'blocked') b),
                            (pg_temp.fl(pg_temp.v('f2'))).status
                     from j where k = 'd2' $$,
  $$ values ('file_blocked'::text, array[pg_temp.trid('r2') || ' payout_blocked:payee_name_mismatch'], 'superseded'::text) $$,
  'a payee check recorded after generation: the file is superseded and not served (file_blocked, the transfer named)');
select pg_temp.as_user('04');
set local role authenticated;
select is(public.transfer_overview() #>> '{payee_checks,0,can_clear}', 'false', 'the page: not for who proposed the IBAN');
select throws_ok($$ select public.clear_payee_name_mismatch('rv-vop-0002', (select (v ->> 'check_id')::uuid from j where k = 'pc'),
                                                            'vérifié') $$,
  '23514', 'payee check refused: same_person', 'who proposed the flagged IBAN cannot clear its check');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok($$ select public.clear_payee_name_mismatch('rv-vop-0003', (select (v ->> 'check_id')::uuid from j where k = 'pc'),
                                                            'vérifié') $$,
  '23514', 'payee check refused: same_person', 'nor who confirmed it');
reset role;
select pg_temp.as_user('09');
set local role authenticated;
select throws_ok($$ select public.clear_payee_name_mismatch('rv-vop-0004', (select (v ->> 'check_id')::uuid from j where k = 'pc'),
                                                            'vérifié') $$,
  '23514', 'payee check refused: same_person', 'nor who recorded it');
reset role;
select pg_temp.as_user('10');
set local role authenticated;
select is(public.transfer_overview() #>> '{payee_checks,0,can_clear}', 'true', 'the page: a third person may');
select is(public.clear_payee_name_mismatch('rv-vop-0005', (select (v ->> 'check_id')::uuid from j where k = 'pc'),
                                           'Titulaire vérifié avec le client') ->> 'cleared', 'true', 'and clears it');
reset role;

-- T2 the cash since generation; the « debits imported since » term (tests-ui#4) ------------------------------------
insert into t select 'f3', (pg_temp.gen('01', 'rv-gen-0003') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f3'));
-- yesterday's statement, without a closing balance, shows a debit of 5 000,00 € (the manual refunds: 100,00 €)
select pg_temp.statement('02', private.paris_today() - 1, null,
                         jsonb_build_array(jsonb_build_object('amount', 500000, 'kind', 'other_debit')));
select results_eq($$ select pg_temp.cash('closing_minor'), pg_temp.cash('debits_since_minor'), pg_temp.cash('manual_refunds_minor'),
                            pg_temp.cash('available_minor') $$,
  $$ values ('1000000'::text, '500000'::text, '10000'::text, '490000'::text) $$,
  'the cash check: the last closing balance less the debits imported since (tests-ui#4) and the manual refunds');
insert into j select 'd3', pg_temp.download('01', pg_temp.v('f3'));
select results_eq($$ select v ->> 'refused', (select array_agg(b ->> 'reason') from jsonb_array_elements(v -> 'blocked') b
                                              where b ->> 'transfer_id' is null),
                            (pg_temp.fl(pg_temp.v('f3'))).status
                     from j where k = 'd3' $$,
  $$ values ('file_blocked'::text, array['cash_not_covered'], 'superseded'::text) $$,
  'the account no longer covers the file: superseded, not served');
select throws_ok($$ select pg_temp.gen('01', 'rv-gen-0004') $$, '23514', 'transfer file refused: cash_not_covered',
  'nor is a new file generated: 4 900,00 € available for 5 838,40 € of payouts');
select pg_temp.statement('03', private.paris_today(), 2000000);

-- T1 a downloaded file: cancelled only on the statements' evidence, by two people (money#1, security#1) -----------
insert into t select 'f4', (pg_temp.gen('01', 'rv-gen-0005') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f4'));
select is(pg_temp.download('01', pg_temp.v('f4')) ->> 'download', '1', 'a file still passing today''s checks is served');
select pg_temp.as_user('01');
set local role authenticated;
select is(public.mark_transfer_file_sent('rv-sent-0001', pg_temp.v('f4'), (pg_temp.fl(pg_temp.v('f4'))).version) ->> 'status',
  'sent', 'marked as sent');
select throws_ok(format($$ select public.cancel_transfer_file('rv-cancel-0001', %L, %s, 'non déposé') $$, pg_temp.v('f4'),
                        (pg_temp.fl(pg_temp.v('f4'))).version),
  '23514', 'transfer file refused: cancellation_request_required', 'not in one step');
select throws_ok(format($$ select public.request_transfer_file_cancellation('rv-cancel-0002', %L, %s, 'non déposé',
                                                                            'not_uploaded') $$,
                        pg_temp.v('f4'), (pg_temp.fl(pg_temp.v('f4'))).version),
  '23514', 'transfer file refused: no_statement_evidence',
  'not on the same day: no statement covers its execution date and the next business day yet (security#1)');
reset role;
-- time moves on (round 2, D1): the file's execution day X and the next business day Y are over, a statement of them
select pg_temp.backdate(pg_temp.v('f4'), pg_temp.x());
select pg_temp.statement('04', pg_temp.y(), 2000000, '[]', pg_temp.x());
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'q1', public.request_transfer_file_cancellation('rv-cancel-0003', pg_temp.v('f4'),
                                                                     (pg_temp.fl(pg_temp.v('f4'))).version,
                                                                     'Fichier non déposé : erreur de compte', 'not_uploaded');
reset role;
select results_eq($$ select v ->> 'status', v #>> '{evidence,covered}', v #>> '{evidence,debit_seen}',
                            (v #>> '{evidence,needed_to_date}')::date = pg_temp.y()
                     from j where k = 'q1' $$,
  $$ values ('requested'::text, 'true'::text, 'false'::text, true) $$,
  'asked once a statement covers its execution date to the next business day and shows none of its debits');
select pg_temp.as_user('01');
set local role authenticated;
select is(public.transfer_file_detail(pg_temp.v('f4')) #>> '{cancellation,request,requested_by_me}', 'true',
  'the file''s page shows the request (and who asked)');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok(format($$ select public.request_transfer_file_cancellation('rv-cancel-0004', %L, %s, 'x', 'not_uploaded') $$,
                        pg_temp.v('f4'), (pg_temp.fl(pg_temp.v('f4'))).version),
  '23514', 'transfer file refused: already_requested', 'one open request per file');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.confirm_transfer_file_cancellation('rv-cancel-0005', %L, %s) $$,
                        pg_temp.v('f4'), (pg_temp.fl(pg_temp.v('f4'))).version),
  '23514', 'transfer file refused: same_person', 'who asked cannot confirm');
reset role;
select is(pg_temp.download('04', pg_temp.v('f4'), true) ->> 'download', '2', 'downloaded again meanwhile');
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok(format($$ select public.confirm_transfer_file_cancellation('rv-cancel-0006', %L, %s) $$,
                        pg_temp.v('f4'), (pg_temp.fl(pg_temp.v('f4'))).version),
  '23514', 'transfer file refused: not_requested', 'a request made before a download is stale: never confirmed');
select is(public.request_transfer_file_cancellation('rv-cancel-0007', pg_temp.v('f4'), (pg_temp.fl(pg_temp.v('f4'))).version,
                                                    'Fichier non déposé : vérifié avec la banque', 'not_uploaded') ->> 'status',
  'requested', 'asked again');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select is(public.confirm_transfer_file_cancellation('rv-cancel-0008', pg_temp.v('f4'),
                                                    (pg_temp.fl(pg_temp.v('f4'))).version) ->> 'status',
  'superseded', 'another person confirms: the file is cancelled');
reset role;
select results_eq($$ select array_agg(r.status order by r.number), array_agg(x.status order by r.number),
                            (pg_temp.sweep(pg_temp.v('f4'))).status,
                            (select confirmed_by from public.transfer_cancellation_request
                             where file_id = pg_temp.v('f4') and confirmed_at is not null)
                     from public.remittance_run r join public.bank_transfer x on x.id = r.transfer_id
                     where r.id in (pg_temp.v('r1'), pg_temp.v('r2')) $$,
  $$ values (array['approved', 'approved'], array['ordered', 'ordered'], 'cancelled'::text,
             '10000000-0000-0000-0000-000000000001'::uuid) $$,
  'its payouts back for the next file, their runs approved again, its sweep recomputed; who confirmed kept');

-- T1 one transfer refused in an executed file, a batch debit (pain001#1, pain001#3, money#2) -------------------
insert into t select 'f5', (pg_temp.gen('01', 'rv-gen-0006') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f5'));
select pg_temp.download('01', pg_temp.v('f5'));
-- T6 alerts (concurrency-perf#2, tests-ui#5), on this file for tomorrow, before time moves on below
insert into t select 'c1', pg_temp.chk(pg_temp.e());
insert into t select 'c2', pg_temp.chk(null);
select results_eq($$ select r.run_id = pg_temp.v('c1'), r.subject_id from public.payment_check_result r
                     where r.run_id in (pg_temp.v('c1'), pg_temp.v('c2')) and r.code = 'file_not_marked_sent'
                     order by 1, 2 $$,
  $$ values (true, pg_temp.v('f5')) $$,
  'file_not_marked_sent from the cut-off of its execution day (none recorded: its start), not before');
select is(private.transfer_checks_due('00000000-0000-0000-0000-0000000000aa',
                                      (pg_temp.e() + time '12:00') at time zone 'Europe/Paris'), true,
  'the hourly schedule runs the checks once that cut-off passed (not the night after)');
insert into public.payment_check_run (organization_id, started_at)
values ('00000000-0000-0000-0000-0000000000aa', (pg_temp.e() + time '13:00') at time zone 'Europe/Paris');
select is(private.transfer_checks_due('00000000-0000-0000-0000-0000000000aa',
                                      (pg_temp.e() + time '14:00') at time zone 'Europe/Paris'), false,
  '… once: not after a run started since');
select ok((select prosrc from pg_proc where oid = 'private.queue_remittance_schedule()'::regprocedure)
          ~ 'transfer_checks_due',
  'the hourly cron (remittances-schedule) asks it');
-- time moves on (round 2, D1): the file was for X; the statements below are of X to Y, both over
select pg_temp.backdate(pg_temp.v('f5'), pg_temp.x());
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok(format($$ select public.cancel_remittance_run('rv-run-0001', %L, %s, 'refusé') $$, pg_temp.v('r1'),
                        (select version from public.remittance_run where id = pg_temp.v('r1'))),
  '23514', 'remittance run refused: payout_in_downloaded_file',
  'a run whose payout is in a downloaded file waits for that transfer''s cancellation (money#2)');
reset role;
select is(pg_temp.cash('in_flight_minor'), '595840', 'the file stays in flight meanwhile (the cash check counts it)');
-- the bank booked one debit for the PmtInf (it ignored BtchBookg): Lilas's 4 198,40 € only, Martin's refused
select pg_temp.statement('05', pg_temp.y(), 2000000 - 419840,
  jsonb_build_array(jsonb_build_object('amount', 419840, 'pmt_inf', (pg_temp.fl(pg_temp.v('f5'))).number || '-1')));
select results_eq($$ select private.transfer_debit_seen(pg_temp.trid('r1')), private.transfer_debit_seen(pg_temp.trid('r2')),
                            pg_temp.cash('in_flight_minor') $$,
  $$ values (false, false, '595840'::text) $$,
  'a batch debit books the PmtInf''s transfers only when it is their sum (design §12): 4 198,40 € is not 5 838,40 €');
select pg_temp.as_user('01');
set local role authenticated;
select is(public.request_transfer_cancellation('rv-tc-0001', pg_temp.trid('r1'), 'La banque a refusé ce virement') ->> 'status',
  'requested', 'Martin''s transfer: the batch is exactly the others'' — the bank left it out');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select is(public.confirm_transfer_cancellation('rv-tc-0002', pg_temp.trid('r1')) ->> 'status', 'cancelled',
  'confirmed by another person: cancelled');
reset role;
select results_eq($$ select private.transfer_debit_seen(pg_temp.trid('r2')), pg_temp.cash('in_flight_minor') $$,
  $$ values (true, '12000'::text) $$, 'the batch then books Lilas''s transfer: only the sweep is in flight');
select pg_temp.as_user('04');
set local role authenticated;
select is(public.cancel_remittance_run('rv-run-0002', pg_temp.v('r1'),
                                       (select version from public.remittance_run where id = pg_temp.v('r1')),
                                       'La banque a refusé le virement') ->> 'status',
  'cancelled', 'then Martin''s run is cancelled');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.request_transfer_cancellation('rv-tc-0003', %L, 'x') $$, pg_temp.trid('r2')),
  '23514', 'transfer refused: debit_seen', 'never Lilas''s, debited');
select throws_ok(format($$ select public.request_transfer_file_cancellation('rv-cancel-0009', %L, %s, 'x', 'not_uploaded') $$,
                        pg_temp.v('f5'), (pg_temp.fl(pg_temp.v('f5'))).version),
  '23514', 'transfer file refused: debit_seen', 'nor the file: a debit carries its PmtInfId');
reset role;
select throws_ok(format($$ select pg_temp.download('04', %L, true) $$, pg_temp.v('f5')),
  '23514', 'transfer file refused: holds_cancelled_transfer', 'nor is the file served again (it holds a cancelled transfer)');
-- the sweep: debited, then returned by the bank
select pg_temp.statement('06', pg_temp.y(), 2000000 - 419840 - 12000,
  jsonb_build_array(jsonb_build_object('amount', 12000, 'e2e', (pg_temp.sweep(pg_temp.v('f5'))).end_to_end_id)));
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.request_transfer_cancellation('rv-tc-0004', %L, 'x') $$,
                        (pg_temp.sweep(pg_temp.v('f5'))).id),
  '23514', 'transfer refused: debit_seen', 'the sweep, debited: not cancelled');
reset role;
select pg_temp.statement('07', pg_temp.y(), 2000000 - 419840,
  jsonb_build_array(jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 12000,
                                       'orig_e2e', (pg_temp.sweep(pg_temp.v('f5'))).end_to_end_id)));
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'q3', public.request_transfer_cancellation('rv-tc-0005', (pg_temp.sweep(pg_temp.v('f5'))).id,
                                                                'Virement retourné par la banque');
select results_eq($$ select v ->> 'status', v #>> '{evidence,returned}' from j where k = 'q3' $$,
  $$ values ('requested'::text, 'true'::text) $$, 'its return on a statement is the evidence: asked');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select is(public.confirm_transfer_cancellation('rv-tc-0006', (pg_temp.sweep(pg_temp.v('f5'))).id) ->> 'status', 'cancelled',
  'the returned sweep cancelled');
select is(public.transfer_overview() #>> '{accounts,0,sweep_preview_minor}', '12000',
  'and recomputed for the next file (ledger critique #16)');
reset role;

-- A file-mode refund the bank refused (pain001#1): its transfer cancelled first, then the refund -----------------
select pg_temp.collect('09', 5000, private.paris_today() - 1, false);
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'rf9', public.request_refund('rv-rfd-0010', pg_temp.pay('09'), '5000', null, null, 'other', null,
                                                  '5000', 'payeur inconnu');
reset role;
insert into t select 'f6', (pg_temp.gen('01', 'rv-gen-0007') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f6'));
select pg_temp.download('01', pg_temp.v('f6'));
-- time moves on: the file for X executed (its sweep debited on Y), the refund in it refused
select pg_temp.backdate(pg_temp.v('f6'), pg_temp.x());
select pg_temp.statement('08', pg_temp.y(), null,
  jsonb_build_array(jsonb_build_object('amount', 12000, 'e2e', (pg_temp.sweep(pg_temp.v('f6'))).end_to_end_id)));
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok($$ select public.cancel_refund('rv-rfd-0011', (select (v ->> 'refund_request_id')::uuid from j where k = 'rf9'),
                                               'refusé') $$,
  '23514', 'refund refused: in_downloaded_file', 'a refund in a downloaded file: not cancelled while its transfer may be paid');
select is(public.request_transfer_cancellation('rv-tc-0007', (select (v ->> 'transfer_id')::uuid from j where k = 'rf9'),
                                               'IBAN du payeur clôturé') ->> 'status', 'requested',
  'its transfer''s cancellation asked (no debit of it on the statements)');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select is(public.confirm_transfer_cancellation('rv-tc-0008', (select (v ->> 'transfer_id')::uuid from j where k = 'rf9'))
            ->> 'refund_request_id', (select v ->> 'refund_request_id' from j where k = 'rf9'), 'and confirmed');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select lives_ok($$ select public.cancel_refund('rv-rfd-0012', (select (v ->> 'refund_request_id')::uuid from j where k = 'rf9'),
                                              'IBAN du payeur clôturé') $$, 'then the refund is cancelled');
reset role;
select results_eq($$ select q.status, p.status from public.refund_request q join public.payment p on p.id = q.payment_id
                     where q.id = (select (v ->> 'refund_request_id')::uuid from j where k = 'rf9') $$,
  $$ values ('cancelled'::text, 'unmatched'::text) $$, 'the payment is back as it was, to refund again or allocate');

-- T6 (tests-ui#5): file_not_downloaded (file_not_marked_sent and the hourly schedule: above, on f5)
select pg_temp.collect('10', 3000, private.paris_today() - 1, false);
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'rf10', public.request_refund('rv-rfd-0013', pg_temp.pay('10'), '3000', null, null, 'other', null,
                                                   '3000', 'payeur inconnu');
reset role;
insert into t select 'f7', (pg_temp.gen('01', 'rv-gen-0008') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f7'));
insert into t select 'c3', pg_temp.chk(private.paris_today() + 14);
select is((select string_agg(r.subject_id::text, ' ') from public.payment_check_result r
           where r.run_id = pg_temp.v('c3') and r.code = 'file_not_downloaded'), pg_temp.v('f7')::text,
  'file_not_downloaded: a file generated more than one business day ago (tests-ui#5)');

-- T5 a payee check closes with its payout account; payout_account_changed (tests-ui#3, tests-ui#7) ----------------
select pg_temp.as_user('09');
set local role authenticated;
insert into j select 'pc5', public.record_payee_name_mismatch('rv-vop-0010', pg_temp.trid('r5'), 'close_match',
                                                              'TUNIS TRADING CO', 'Nom proche');
reset role;
select is(private.transfer_hold_reason(pg_temp.trid('r5'), private.paris_today(), pg_temp.e(), null),
  'payout_blocked:payee_name_mismatch', 'Tunis Trading''s payout blocked by the check');
select pg_temp.as_user('04');
set local role authenticated;
insert into j select 'pa5', public.propose_payout_account('rv-pa-0001', '00000000-0000-0000-0000-0000000000a5', 'EUR',
                                                          'FR7688654272501505380528112', 'TUNIS TRADING', null,
                                                          'd0000000-0000-0000-0000-000000000011');
reset role;
select pg_temp.as_user('10');
set local role authenticated;
select is(public.confirm_payout_account('rv-pa-0002', (select (v ->> 'payout_account_id')::uuid from j where k = 'pa5'),
                                        'FR7688654272501505380528112') ->> 'status', 'active',
  'a new payout account confirmed by a second admin (the old one retired)');
select is((select count(*)::int from jsonb_array_elements(public.transfer_overview() -> 'payee_checks') c
           where c ->> 'client_id' = '00000000-0000-0000-0000-0000000000a5'), 0,
  'the check on the retired account is closed: no longer on the page');
reset role;
insert into t select 'c4', pg_temp.chk(null);
select is((select count(*)::int from public.payment_check_result r
           where r.run_id = pg_temp.v('c4') and r.code = 'payee_name_mismatch'), 0, 'nor alerted every night');
select is(private.transfer_card(pg_temp.trid('r5'), null) ->> 'payee_check_open', 'false', 'nor shown on its transfer');
select is(private.transfer_hold_reason(pg_temp.trid('r5'), private.paris_today(), pg_temp.e(), null),
  'payout_account_changed', 'the payout froze the old IBAN: held (payout_account_changed)');
insert into j select 'g8', pg_temp.gen('01', 'rv-gen-0009');
insert into t select 'f8', (v ->> 'file_id')::uuid from j where k = 'g8';
select is((select h ->> 'reason' from j cross join lateral jsonb_array_elements(j.v -> 'held') h
           where j.k = 'g8' and h ->> 'transfer_id' = pg_temp.trid('r5')::text), 'payout_account_changed',
  'and generation lists it among the held');

-- tests-ui#3 the per-client cap counts the client's other runs in flight (today one live run per client —
-- remittance_run_pending_uq, OQ-73 — so a second one is set up with that index dropped in this transaction: the term
-- guards the day OQ-73 lets a second run be drafted while a payout is in flight) ------------------------------
drop index public.remittance_run_pending_uq;
insert into public.remittance_run (id, organization_id, client_organization_id, currency, number, trigger, known_at)
values ('66000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa',
        '00000000-0000-0000-0000-0000000000a4', 'EUR', 'RV-2026-990001', 'manual', now());
update public.remittance_run set status = 'approved', prepared_at = now(), gross_minor = 1, net_minor = 1,
                                 settlement_minor = 0, approved_at = now()
where id = '66000000-0000-0000-0000-000000000001';
select is(private.transfer_hold_reason(pg_temp.trid('r4'), private.paris_today(), pg_temp.e(), null),
  'payout_not_covered', 'with another run of Omega in flight, its payout no longer fits what Omega is owed');
update public.remittance_run set status = 'cancelled', cancelled_at = now(), cancel_reason = 'test'
where id = '66000000-0000-0000-0000-000000000001';
select is(private.transfer_hold_reason(pg_temp.trid('r4'), private.paris_today(), pg_temp.e(), null),
  'payee_name_not_epc', 'without it, the cap holds and its name keeps it out');

-- tests-ui#0 no command for anyone but the servicer's money staff at aal2 -------------------------------------
select pg_temp.write(pg_temp.v('f8'));
select is(pg_temp.outsiders(format($$ select public.mark_transfer_file_sent('rv-x-01', %L, 1) $$, pg_temp.v('f6'))),
  array['42501', '42501', '42501', '42501'], 'mark_transfer_file_sent: not a collector, a client, another servicer, aal1');
select is(pg_temp.outsiders(format($$ select public.cancel_transfer_file('rv-x-02', %L, 1, 'x') $$, pg_temp.v('f8'))),
  array['42501', '42501', '42501', '42501'], 'cancel_transfer_file of a generated file: nor them');
select is(pg_temp.outsiders(format($$ select public.cancel_transfer_file('rv-x-03', %L, 1, 'x', 'not_uploaded') $$,
                                   pg_temp.v('f6'))),
  array['42501', '42501', '42501', '42501'], 'cancel_transfer_file of a downloaded file: nor them');
select is(pg_temp.outsiders(format($$ select public.clear_payee_name_mismatch('rv-x-04', %L, 'x') $$,
                                   (select (v ->> 'check_id')::uuid from j where k = 'pc5'))),
  array['42501', '42501', '42501', '42501'], 'clear_payee_name_mismatch: nor them');
select is(pg_temp.outsiders(format($$ select public.request_transfer_file_cancellation('rv-x-05', %L, 1, 'x', 'not_uploaded') $$,
                                   pg_temp.v('f6'))),
  array['42501', '42501', '42501', '42501'], 'request_transfer_file_cancellation: nor them');
select is(pg_temp.outsiders(format($$ select public.confirm_transfer_file_cancellation('rv-x-06', %L, 1) $$, pg_temp.v('f6'))),
  array['42501', '42501', '42501', '42501'], 'confirm_transfer_file_cancellation: nor them');
select is(pg_temp.outsiders(format($$ select public.request_transfer_cancellation('rv-x-07', %L, 'x') $$,
                                   (pg_temp.sweep(pg_temp.v('f6'))).id)),
  array['42501', '42501', '42501', '42501'], 'request_transfer_cancellation: nor them');
select is(pg_temp.outsiders(format($$ select public.confirm_transfer_cancellation('rv-x-08', %L) $$,
                                   (pg_temp.sweep(pg_temp.v('f6'))).id)),
  array['42501', '42501', '42501', '42501'], 'confirm_transfer_cancellation: nor them');
select is(pg_temp.outsiders(format($$ select public.transfer_file_download(%L, %L) $$, pg_temp.v('f8'),
                                   pg_temp.sha(pg_temp.v('f8')))),
  array['42501', '42501', '42501', '42501'], 'transfer_file_download: nor them');
select is(pg_temp.outsiders(format($$ select public.record_payee_name_mismatch('rv-x-09', %L, 'no_match', null, 'x') $$,
                                   pg_temp.trid('r2'))),
  array['42501', '42501', '42501', '42501'], 'record_payee_name_mismatch: nor them');
select is(pg_temp.outsiders($$ select public.generate_transfer_file('rv-x-10', '80000000-0000-0000-0000-0000000000cf') $$),
  array['42501', '42501', '42501', '42501'], 'generate_transfer_file: nor them');
select is(pg_temp.outsiders(format($$ select public.transfer_file_detail(%L) $$, pg_temp.v('f6'))),
  array['42501', '42501', '42501', '42501'], 'transfer_file_detail: nor them');
select is(pg_temp.outsiders($$ select count(*) from public.transfer_cancellation_request having count(*) > 0 $$),
  array['ok', 'ok', 'ok', 'ok'], 'the cancellation requests: none visible to them (RLS: the query runs, no row)');
select is((select count(*)::int from public.transfer_cancellation_request where confirmed_at is not null), 4,
  'four confirmed so far (a file, Martin''s transfer, the sweep, the refund), one left stale by a download');

-- T4 the bucket (money#3, security#2) ----------------------------------------------------------------------------
insert into storage.objects (bucket_id, name)
select 'transfer-files', (pg_temp.fl(x)).storage_path from unnest(array[pg_temp.v('f1'), pg_temp.v('f8')]) x;
select pg_temp.as_user('10');
set local role authenticated;
select is((select count(*)::int from storage.objects where bucket_id = 'transfer-files'), 0,
  'no money-staff member reads a transfer file in the bucket directly: not a live one before its download');
reset role;
select is(pg_temp.download('10', pg_temp.v('f8')) ->> 'download', '1', 'the command records the download …');
-- (time moves on: its cancellation below needs its execution day and the next one over, D1)
select pg_temp.backdate(pg_temp.v('f8'), pg_temp.x());
select pg_temp.as_user('10');
set local role authenticated;
select is((select array_agg(name) from storage.objects where bucket_id = 'transfer-files'),
  array[(pg_temp.fl(pg_temp.v('f8'))).storage_path], '… then its bytes, for that member only; never a superseded file''s');
select is(public.request_transfer_file_cancellation('rv-cancel-0010', pg_temp.v('f8'), (pg_temp.fl(pg_temp.v('f8'))).version,
                                                    'Fichier non déposé', 'not_uploaded') ->> 'status', 'requested',
  'that file''s cancellation asked …');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select is(public.confirm_transfer_file_cancellation('rv-cancel-0011', pg_temp.v('f8'),
                                                    (pg_temp.fl(pg_temp.v('f8'))).version) ->> 'status', 'superseded',
  '… and confirmed');
reset role;
select pg_temp.as_user('10');
set local role authenticated;
select is((select count(*)::int from storage.objects where bucket_id = 'transfer-files'), 0,
  'a cancelled file is never served, even to who just downloaded it (money#3)');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select is((select count(*)::int from storage.objects where bucket_id = 'transfer-files'), 0,
  'nor for another member who did not download it');
reset role;

select results_eq($$ select count(*) filter (where entry_type in ('remittance', 'servicer_sweep'))::int
                     from public.ledger_entry where organization_id = '00000000-0000-0000-0000-0000000000aa' $$,
  $$ values (0) $$, 'no remittance nor sweep booked by any of it (M2c-6b books the debits)');

select * from finish();
rollback;
