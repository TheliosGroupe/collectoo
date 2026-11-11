-- M2c-6a review fixes, round 2 (the skeptics' scenarios A, A2, B, C, C2, D and security#3's s5, s5b; design §9.7,
-- §11, §12; ADR-0014 « M2c-6a review fixes », round 2; COMPLIANCE OQ-80). 028 holds the slice's cases, 029 the first
-- review's; this file the second round's:
--   * D1 a day counts as covered by an imported statement only once it is over: the window ends before today, each of
--     its business days in a statement uploaded after that day, a CSV's last booking day never (money#1, security#1);
--   * D2 one transfer of a downloaded file is cancelled only when the bank executed something of the file — else the
--     file's own cancellation is the exit (`file_not_executed`); a file holding a cancelled transfer and nothing debited
--     is never marked as sent nor alerted as not marked (money#2);
--   * D3 a batch debit with no end-to-end id is evidence for one transfer only when no other open transfer of its
--     PmtInf, alone or combined, makes up its amount (`batch_ambiguous`; pain001#1);
--   * D4 a payout or refund whose end-to-end id is already debited is held (`already_debited`) at generation and at
--     download, and alerted; no sweep while a cancelled sweep's debit is seen and not returned (T1);
--   * S1 an open payee check follows the client's IBAN: the same IBAN proposed and confirmed again stays blocked,
--     listed and alerted, and none of who vouched for that IBAN clears it (security#3, tests-ui#7).
-- No ledger entry is posted by any of it.
begin;
select plan(60);


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
-- [{e2e, amount, kind, pmt_inf}] booked on p_to, uploaded at p_uploaded_at (default now), camt.053 unless p_format.
create or replace function pg_temp.statement(p_n text, p_to date, p_closing bigint, p_debits jsonb default '[]',
                                             p_from date default null, p_uploaded_at timestamptz default null,
                                             p_format text default 'camt053')
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
  update public.bank_statement set status = 'imported', from_date = coalesce(p_from, p_to), to_date = p_to,
    opening_booked_minor = 0, closing_booked_minor = p_closing, counts = '{}', finished_at = clock_timestamp(),
    -- the bank's creation time the import keeps (review round 3, E4): here its upload's
    sections = case when p_format = 'camt053'
                    then jsonb_build_array(jsonb_build_object('created_at', coalesce(p_uploaded_at, now()))) end
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

-- D1 the evidence window must be over (money#1, security#1: scenario D) ------------------------------------------
insert into t select 'f1', (pg_temp.gen('01', 'r2-gen-0001') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f1'));
select pg_temp.download('01', pg_temp.v('f1'));
select is(pg_temp.try('01', pg_temp.sent('r2-sent-0001', 'f1')), 'sent', 'D: a file downloaded and marked as sent today');
-- today's statement, no line, its period written up to the day after tomorrow (camt FrToDt/ToDtTm); and one stamped as
-- uploaded after those days (a clock ahead): the window itself must be over
select pg_temp.statement('d1', pg_temp.n(), null, '[]', private.paris_today());
select pg_temp.statement('d0', pg_temp.n(), null, '[]', private.paris_today(), now() + interval '5 days');
select results_eq($$ select pg_temp.ev('f1', null, 'refusal'), pg_temp.ev('f1', null, 'window_over'),
                            pg_temp.ev('f1', null, 'covered'), pg_temp.ev('f1', null, 'available_from')::date = pg_temp.n() + 1 $$,
  $$ values ('no_statement_evidence'::text, 'false'::text, 'false'::text, true) $$,
  'D1: a period reaching days not over yet proves nothing of them; asked from the day after the next business day');
select is(pg_temp.try('01', pg_temp.req_file('r2-rq-0001', 'f1')), 'transfer file refused: no_statement_evidence',
  'D1: the file''s cancellation is not asked the day it was handed out (scenario D)');
select is(pg_temp.try('01', pg_temp.req_tr('r2-rq-0002', pg_temp.trid('r1'))), 'transfer refused: no_statement_evidence',
  'D1: nor one of its transfers''');
insert into t select 'q1', pg_temp.ask(pg_temp.v('f1'), null, '01');
insert into t select 'q2', pg_temp.ask(pg_temp.v('f1'), pg_temp.trid('r2'), '01');
select is(pg_temp.try('04', pg_temp.conf_file('r2-cf-0001', 'f1')), 'transfer file refused: no_statement_evidence',
  'D1: a request recorded on such evidence is not confirmed while the window is not over');
select is(pg_temp.try('04', pg_temp.conf_tr('r2-cf-0002', pg_temp.trid('r2'))), 'transfer refused: no_statement_evidence',
  'D1: nor one transfer''s');
-- time moves on: the file was for X, the next business day Y; statements exported and imported during Y
select pg_temp.backdate(pg_temp.v('f1'), pg_temp.x());
select pg_temp.statement('d2', pg_temp.y(), null, '[]', pg_temp.x(), (pg_temp.y() + time '15:00') at time zone 'Europe/Paris');
select results_eq($$ select pg_temp.ev('f1', null, 'refusal'), pg_temp.ev('f1', null, 'window_over') $$,
  $$ values ('no_statement_evidence'::text, 'true'::text) $$,
  'D1: a statement uploaded on Y does not cover Y (the bank may still debit later that day)');
select pg_temp.statement('d5', pg_temp.y(), null, '[{"amount": 100, "kind": "other_debit"}]', pg_temp.x(),
                         (pg_temp.y() + time '16:00') at time zone 'Europe/Paris', 'csv');
select is(pg_temp.ev('f1', null, 'refusal'), 'no_statement_evidence',
  'D1: nor a CSV whose last line is booked on Y, imported on Y');
select pg_temp.statement('d3', pg_temp.y(), null, '[]', pg_temp.y(), (pg_temp.y() + 1 + time '09:00') at time zone 'Europe/Paris',
                         'csv');
select is(pg_temp.ev('f1', null, 'refusal'), 'no_statement_evidence',
  'D1: nor a CSV''s last booking day, whenever it is imported (its export time is unknown)');
select is(pg_temp.try('04', pg_temp.conf_file('r2-cf-0003', 'f1')), 'transfer file refused: no_statement_evidence',
  'D1: so the request is still not confirmed');
select pg_temp.statement('d4', pg_temp.y(), null, '[]', pg_temp.y(), (pg_temp.y() + 1 + time '09:00') at time zone 'Europe/Paris');
select results_eq($$ select pg_temp.ev('f1', null, 'refusal'), pg_temp.ev('f1', null, 'covered') $$,
  $$ values (null::text, 'true'::text) $$,
  'D1: covered once each business day of the window is in a statement uploaded after it (Y''s camt.053, the next day)');
select is(pg_temp.try('04', pg_temp.conf_file('r2-cf-0004', 'f1')), 'superseded', 'then the file''s cancellation is confirmed');
select results_eq($$ select pg_temp.status(pg_temp.trid('r1')), pg_temp.status(pg_temp.trid('r2')),
                            (pg_temp.sweep(pg_temp.v('f1'))).status $$,
  $$ values ('ordered'::text, 'ordered'::text, 'cancelled'::text) $$, 'its payouts back for the next file, its sweep cancelled');

-- D2 one transfer is cancelled only from an executed file (money#2: scenario B) ------------------------------------
insert into j select 'rf1', pg_temp.refund('11', 5000);
insert into t select 'f2', (pg_temp.gen('01', 'r2-gen-0002') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f2'));
select pg_temp.download('01', pg_temp.v('f2'));
select pg_temp.backdate(pg_temp.v('f2'), pg_temp.x());
select results_eq($$ select pg_temp.ev('f2', pg_temp.trid('r1'), 'covered'), pg_temp.ev('f2', pg_temp.trid('r1'), 'debit_seen'),
                            pg_temp.ev('f2', pg_temp.trid('r1'), 'file_executed'), pg_temp.ev('f2', pg_temp.trid('r1'), 'refusal') $$,
  $$ values ('true'::text, 'false'::text, 'false'::text, 'file_not_executed'::text) $$,
  'D2: the window covered and no debit of Martin''s transfer — but none of the file''s either: the bank executed nothing of it');
select is(pg_temp.try('01', pg_temp.req_tr('r2-rq-0003', pg_temp.trid('r1'))), 'transfer refused: file_not_executed',
  'D2: so it is not cancelled alone (the file, still live, would pay it): the file''s cancellation is the exit');
select is(pg_temp.try('01', pg_temp.req_tr('r2-rq-0004', pg_temp.rf('rf1'))), 'transfer refused: file_not_executed',
  'D2: nor its refund');
insert into t select 'q3', pg_temp.ask(pg_temp.v('f2'), pg_temp.trid('r1'), '01');
select is(pg_temp.try('04', pg_temp.conf_tr('r2-cf-0005', pg_temp.trid('r1'))), 'transfer refused: file_not_executed',
  'D2: nor confirmed');
-- a transfer of it cancelled before this round (scenario B's state: the refund cancelled, the file live)
update public.bank_transfer set status = 'cancelled', cancelled_at = now(),
  cancelled_by = '10000000-0000-0000-0000-000000000004', cancel_reason = 'Annulé avant la correction (test)'
where id = pg_temp.rf('rf1');
select is(pg_temp.try('01', pg_temp.sent('r2-sent-0002', 'f2')), 'transfer file refused: holds_cancelled_transfer',
  'D2: a downloaded file holding a cancelled transfer, nothing of it debited, is never marked as sent (never uploaded)');
insert into t select 'c1', pg_temp.chk(null);
select is((select count(*)::int from public.payment_check_result r
           where r.run_id = pg_temp.v('c1') and r.code = 'file_not_marked_sent' and r.subject_id = pg_temp.v('f2')), 0,
  'D2: nor alerted as not marked sent past its cut-off');
select is(pg_temp.try('01', pg_temp.req_file('r2-rq-0005', 'f2')), 'requested', 'D2: its own cancellation is asked …');
select is(pg_temp.try('04', pg_temp.conf_file('r2-cf-0006', 'f2')), 'superseded', '… and confirmed');
select results_eq($$ select pg_temp.status(pg_temp.trid('r1')), pg_temp.status(pg_temp.trid('r2')), pg_temp.status(pg_temp.rf('rf1')) $$,
  $$ values ('ordered'::text, 'ordered'::text, 'cancelled'::text) $$, 'D2: the payouts back for the next file, the refund cancelled');

-- D4 a re-queued transfer whose id is debited since: held (T1: scenarios A, A2) ----------------------------------
insert into t select 'f3', (pg_temp.gen('01', 'r2-gen-0003') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f3'));
select pg_temp.download('01', pg_temp.v('f3'));
select pg_temp.backdate(pg_temp.v('f3'), pg_temp.x());
select is(pg_temp.try('01', pg_temp.req_file('r2-rq-0006', 'f3')), 'requested', 'A: a file cancelled on evidence …');
select is(pg_temp.try('04', pg_temp.conf_file('r2-cf-0007', 'f3')), 'superseded', '… by two people');
insert into t select 'f4', (pg_temp.gen('01', 'r2-gen-0004') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f4'));
-- the old file executed after all (a colleague uploaded it, or the bank held it): Lilas's payout and its sweep debited,
-- by the ids that file carried (review round 3: its payouts were re-issued under new ones, E1)
select pg_temp.statement('a1', pg_temp.z(), null, jsonb_build_array(
  jsonb_build_object('amount', 419840, 'e2e', (select x.end_to_end_id from public.transfer_file_item i
                                               join public.bank_transfer x on x.id = i.transfer_id
                                               where i.file_id = pg_temp.v('f3') and x.run_id = pg_temp.v('r2'))),
  jsonb_build_object('amount', 12000, 'e2e', (pg_temp.sweep(pg_temp.v('f3'))).end_to_end_id)));
select results_eq($$ select private.transfer_hold_reason(pg_temp.trid('r2'), private.paris_today(), pg_temp.e(), null),
                            private.transfer_hold_reason(pg_temp.trid('r1'), private.paris_today(), pg_temp.e(), null) $$,
  $$ values ('already_debited'::text, null::text) $$,
  'D4: a payout whose end-to-end id a statement shows debited is held (already_debited); Martin''s, not debited, is not');
insert into j select 'd4', pg_temp.download('01', pg_temp.v('f4'));
select results_eq($$ select v ->> 'refused', (select array_agg((b ->> 'transfer_id') || ' ' || (b ->> 'reason'))
                                              from jsonb_array_elements(v -> 'blocked') b),
                            (pg_temp.fl(pg_temp.v('f4'))).status from j where k = 'd4' $$,
  $$ values ('file_blocked'::text, array[pg_temp.trid('r2') || ' already_debited'], 'superseded'::text) $$,
  'D4: the file holding it, generated before the debit was imported, is superseded at download, not served');
insert into j select 'g5', pg_temp.gen('01', 'r2-gen-0005');
insert into t select 'f5', (v ->> 'file_id')::uuid from j where k = 'g5';
select results_eq($$ select (v ->> 'nb_of_txs')::int, v ->> 'ctrl_sum_minor', v ->> 'sweep_minor', v ->> 'sweep_hold',
                            (select array_agg((h ->> 'transfer_id') || ' ' || (h ->> 'reason')) from jsonb_array_elements(v -> 'held') h)
                     from j where k = 'g5' $$,
  $$ values (1, '164000'::text, '0'::text, 'cancelled_sweep_debited'::text, array[pg_temp.trid('r2') || ' already_debited']) $$,
  'D4: the next file holds Lilas''s payout out, and no new sweep while the cancelled one''s debit is seen (A2)');
select pg_temp.as_user('01');
set local role authenticated;
select results_eq($$ select o #>> '{accounts,0,sweep_preview_minor}', o #>> '{accounts,0,sweep_hold}',
                            (select c ->> 'hold' from jsonb_array_elements(o #> '{accounts,0,to_file}') c
                             where c ->> 'transfer_id' = pg_temp.trid('r2')::text)
                     from (select public.transfer_overview() o) x $$,
  $$ values ('0'::text, 'cancelled_sweep_debited'::text, 'already_debited'::text) $$,
  'D4: « Virements » says so (no sweep proposed, the payout held with its reason)');
reset role;
insert into t select 'c2', pg_temp.chk(null);
select results_eq($$ select r.subject_type, r.subject_id, r.details ->> 'kind', r.details ->> 'status'
                     from public.payment_check_result r
                     where r.run_id = pg_temp.v('c2') and r.code = 'transfer_already_debited' order by r.details ->> 'kind' $$,
  $$ values ('bank_transfer'::text, pg_temp.trid('r2'), 'payout'::text, 'ordered'::text),
            ('bank_transfer', (pg_temp.sweep(pg_temp.v('f3'))).id, 'sweep', 'cancelled') $$,
  'D4: both alerted every night (transfer_already_debited) until M2c-6b books or ops link them');
select pg_temp.write(pg_temp.v('f5'));
select pg_temp.download('01', pg_temp.v('f5'));
select results_eq($$ select pg_temp.cash('in_flight_minor'), pg_temp.cash('in_flight_count')::int $$,
  $$ values ('164000'::text, 1) $$,
  'D4: in flight, only what can still be debited (nothing re-filed under an id already debited, A)');
-- the bank returns the old sweep: the servicer's share is back on the account
select pg_temp.statement('a2', pg_temp.z(), null, jsonb_build_array(jsonb_build_object(
  'dir', 'credit', 'kind', 'return', 'amount', 12000, 'orig_e2e', (pg_temp.sweep(pg_temp.v('f3'))).end_to_end_id)));
select pg_temp.as_user('01');
set local role authenticated;
select results_eq($$ select o #>> '{accounts,0,sweep_preview_minor}', o #>> '{accounts,0,sweep_hold}'
                     from (select public.transfer_overview() o) x $$,
  $$ values ('12000'::text, null::text) $$, 'D4: once that sweep came back, the share is proposed again');
reset role;

-- D3 a batch debit some other transfers could make up (pain001#1: scenarios C, C2) --------------------------------
insert into j select 'rf2', pg_temp.refund('12', 7000);
insert into j select 'rf3', pg_temp.refund('13', 7000);
insert into j select 'rf4', pg_temp.refund('14', 2000);
insert into t select 'f6', (pg_temp.gen('01', 'r2-gen-0006') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f6'));
select pg_temp.download('01', pg_temp.v('f6'));
select pg_temp.backdate(pg_temp.v('f6'), pg_temp.x());
-- one batch line for PmtInf -1 of 90,00 €: two of the three refunds, one 70,00 € refused (which one: not on the statement)
select pg_temp.statement('c1', pg_temp.y(), null,
  jsonb_build_array(jsonb_build_object('amount', 9000, 'pmt_inf', (pg_temp.fl(pg_temp.v('f6'))).number || '-1')));
select results_eq($$ select pg_temp.ev('f6', pg_temp.rf('rf2'), 'refusal'), pg_temp.ev('f6', pg_temp.rf('rf2'), 'batch_ambiguous'),
                            pg_temp.ev('f6', pg_temp.rf('rf3'), 'refusal'), pg_temp.ev('f6', pg_temp.rf('rf4'), 'refusal') $$,
  $$ values ('batch_ambiguous'::text, 'true'::text, 'batch_ambiguous'::text, 'debit_seen'::text) $$,
  'D3: either 70,00 € refund may be the one refused: neither is proven unpaid (the 20,00 € one is debited)');
select is(pg_temp.try('01', pg_temp.req_tr('r2-rq-0007', pg_temp.rf('rf2'))), 'transfer refused: batch_ambiguous',
  'D3: so neither is cancelled — the first …');
select is(pg_temp.try('09', pg_temp.req_tr('r2-rq-0008', pg_temp.rf('rf3'))), 'transfer refused: batch_ambiguous',
  '… nor the other (scenario C2, the other order)');
select is(pg_temp.cash('in_flight_count'), '5', 'D3: the batch books none of them: all three in flight (with the sweep, Martin)');
insert into j select 'rf5', pg_temp.refund('15', 7000);
insert into j select 'rf6', pg_temp.refund('16', 3000);
insert into j select 'rf7', pg_temp.refund('17', 4000);
insert into t select 'f7', (pg_temp.gen('01', 'r2-gen-0007') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f7'));
select pg_temp.download('01', pg_temp.v('f7'));
select pg_temp.backdate(pg_temp.v('f7'), pg_temp.x());
select pg_temp.statement('c2', pg_temp.y(), null,
  jsonb_build_array(jsonb_build_object('amount', 7000, 'pmt_inf', (pg_temp.fl(pg_temp.v('f7'))).number || '-1')));
select is(pg_temp.try('01', pg_temp.req_tr('r2-rq-0009', pg_temp.rf('rf5'))), 'transfer refused: batch_ambiguous',
  'D3: nor when two others combined (30,00 € + 40,00 €) make up its 70,00 €');
insert into j select 'rf8', pg_temp.refund('18', 6000);
insert into j select 'rf9', pg_temp.refund('19', 1000);
insert into t select 'f8', (pg_temp.gen('01', 'r2-gen-0008') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f8'));
select pg_temp.download('01', pg_temp.v('f8'));
select pg_temp.backdate(pg_temp.v('f8'), pg_temp.x());
select pg_temp.statement('c3', pg_temp.y(), null,
  jsonb_build_array(jsonb_build_object('amount', 1000, 'pmt_inf', (pg_temp.fl(pg_temp.v('f8'))).number || '-1')));
select is(pg_temp.try('01', pg_temp.req_tr('r2-rq-0010', pg_temp.rf('rf8'))), 'requested',
  'D3: a batch debit nothing else can make up but the others: the 60,00 € refund was left out — asked');
select is(pg_temp.try('04', pg_temp.conf_tr('r2-cf-0008', pg_temp.rf('rf8'))), 'cancelled', 'and confirmed');
select is(pg_temp.try('01', pg_temp.sent('r2-sent-0003', 'f8')), 'sent',
  'D2: a file holding a cancelled transfer that the bank executed is marked as sent (it was uploaded)');
-- a file the bank executed, shown by the return of one of its transfers only (no debit line of it imported)
insert into j select 'rf10', pg_temp.refund('1a', 4000);
insert into j select 'rf11', pg_temp.refund('1b', 2500);
insert into t select 'f9', (pg_temp.gen('01', 'r2-gen-0009') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f9'));
select pg_temp.download('01', pg_temp.v('f9'));
select pg_temp.backdate(pg_temp.v('f9'), pg_temp.x());
select pg_temp.statement('c4', pg_temp.y(), null, jsonb_build_array(jsonb_build_object(
  'dir', 'credit', 'kind', 'return', 'amount', 4000,
  'orig_e2e', (select end_to_end_id from public.bank_transfer where id = pg_temp.rf('rf10')))));
select results_eq($$ select pg_temp.try('01', pg_temp.req_tr('r2-rq-0011', pg_temp.rf('rf11'))),
                            pg_temp.try('01', pg_temp.req_tr('r2-rq-0012', pg_temp.rf('rf10'))) $$,
  $$ values ('requested'::text, 'requested'::text) $$,
  'D2: a return of one transfer shows the file was executed: the other one, not debited, may be cancelled (and the returned one)');
select results_eq($$ select private.amounts_make_up(a, n) from (values ('{5,7}'::bigint[], 13::bigint, 1), ('{5,8}', 13, 2),
                                                                     ('{13}', 13, 3), ('{20,1}', 13, 4), ('{}', 5, 5),
                                                                     ('{9,4,3,1}', 8, 6)) x (a, n, o) order by o $$,
  $$ values (false), (true), (true), (false), (false), (true) $$,
  'D3: whether some of the other amounts make up this one (alone or combined)');
select is(private.amounts_make_up(array(select (2 ^ g)::bigint from generate_series(0, 14) g), 32768), true,
  'D3: past 10,000 partial sums it gives up and answers « ambiguous » (refused: never a guess)');

-- S1 a payee check follows the client's IBAN (security#3, tests-ui#7 regression) ---------------------------------
select pg_temp.as_user('09');
set local role authenticated;
insert into j select 'pc', public.record_payee_name_mismatch('r2-vop-0001', pg_temp.trid('r1'), 'no_match', null,
                                                             'VoP : aucune concordance');
reset role;
create or replace function pg_temp.clr(p_key text) returns text language sql as $$
  select format($q$ select public.clear_payee_name_mismatch(%L, %L, 'Titulaire vérifié') ->> 'cleared' $q$, p_key,
                (select (v ->> 'check_id')::uuid from j where k = 'pc')) $$;
create or replace function pg_temp.propose(p_key text) returns text language sql as $$
  select format($q$ select public.propose_payout_account(%L, '00000000-0000-0000-0000-0000000000a1', 'EUR',
                     'FR7630004000031234567890143', 'MARTIN SAS', null, 'd0000000-0000-0000-0000-000000000003')
                     ->> 'payout_account_id' $q$, p_key) $$;
create or replace function pg_temp.confirm(p_key text, p_account text) returns text language sql as $$
  select format($q$ select public.confirm_payout_account(%L, %L, 'FR7630004000031234567890143') ->> 'status' $q$, p_key,
                p_account) $$;
create or replace function pg_temp.checks_listed(p_user text) returns integer language plpgsql as $$
declare v integer;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  select count(*)::int into v from jsonb_array_elements(public.transfer_overview() -> 'payee_checks') c
  where c ->> 'client_id' = '00000000-0000-0000-0000-0000000000a1';
  reset role;
  return v;
end $$;
create or replace function pg_temp.can_clear(p_user text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  select c ->> 'can_clear' into v from jsonb_array_elements(public.transfer_overview() -> 'payee_checks') c
  where c ->> 'client_id' = '00000000-0000-0000-0000-0000000000a1';
  reset role;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(private.remittance_payout_blockers('00000000-0000-0000-0000-0000000000a1', 'EUR', private.paris_today()),
  array['payee_name_mismatch'], 'S1: the bank''s no-match on Martin''s IBAN blocks his payouts');
select results_eq($$ select pg_temp.try('04', pg_temp.clr('r2-clr-0001')), pg_temp.try('10', pg_temp.clr('r2-clr-0002')) $$,
  $$ values ('payee check refused: same_person'::text, 'payee check refused: same_person'::text) $$,
  'S1: neither who proposed (04) nor who confirmed (10) the flagged IBAN clears it');
-- the same two propose and confirm the same IBAN again (s5b)
insert into j select 'pa1', to_jsonb(pg_temp.try('04', pg_temp.propose('r2-pa-0001')));
select is(pg_temp.try('10', pg_temp.confirm('r2-pa-0002', (select v #>> '{}' from j where k = 'pa1'))), 'active',
  'S1: the same IBAN, proposed by one and confirmed by the other, replaces the flagged account (retired)');
select is(private.remittance_payout_blockers('00000000-0000-0000-0000-0000000000a1', 'EUR', private.paris_today()),
  array['payee_name_mismatch'], 'S1: still blocked: the check follows the IBAN, not the account row');
insert into t select 'c3', pg_temp.chk(null);
select results_eq($$ select pg_temp.checks_listed('11'),
                            (select count(*)::int from public.payment_check_result r
                             where r.run_id = pg_temp.v('c3') and r.code = 'payee_name_mismatch'),
                            private.transfer_card(pg_temp.trid('r1'), null) ->> 'payee_check_open' $$,
  $$ values (1, 1, 'true'::text) $$, 'S1: still listed on « Virements », alerted every night, shown on the transfer');
select results_eq($$ select pg_temp.try('04', pg_temp.clr('r2-clr-0003')), pg_temp.try('10', pg_temp.clr('r2-clr-0004')) $$,
  $$ values ('payee check refused: same_person'::text, 'payee check refused: same_person'::text) $$,
  'S1: and still not cleared by either');
-- proposed once more by ops (01), confirmed in the client space by Martin's administrator (s5)
insert into j select 'pa2', to_jsonb(pg_temp.try('01', pg_temp.propose('r2-pa-0003')));
select is(pg_temp.try('03', pg_temp.confirm('r2-pa-0004', (select v #>> '{}' from j where k = 'pa2'))), 'active',
  'S1: the client confirms it (client space)');
select results_eq($$ select pg_temp.try('01', pg_temp.clr('r2-clr-0005')), pg_temp.can_clear('01'), pg_temp.can_clear('11') $$,
  $$ values ('payee check refused: same_person'::text, 'false'::text, 'true'::text) $$,
  'S1: who proposed that IBAN this time cannot clear it either; a third person can (the page says which)');
-- review round 3 (E5): who proposed that IBAN, even rejected since, is a party (the documented « proposed »)
insert into j select 'pa3', to_jsonb(pg_temp.try('13', pg_temp.propose('r2-pa-0005')));
select is(pg_temp.try('04', format($q$ select public.reject_payout_account('r2-pa-0006', %L, 'RIB illisible') ->> 'status' $q$,
                                   (select v #>> '{}' from j where k = 'pa3'))), 'rejected',
  'S1 (round 3): ops (13) propose the flagged IBAN once more; the proposal is rejected');
select is(pg_temp.try('13', pg_temp.clr('r2-clr-0007')), 'payee check refused: same_person',
  'S1 (round 3): who proposed it, though rejected since, does not clear the check');
-- a new admin (12), who never recorded the check nor touched the flagged row, confirms a same-IBAN replacement 13 proposed
insert into j select 'pa4', to_jsonb(pg_temp.try('13', pg_temp.propose('r2-pa-0007')));
select is(pg_temp.try('12', pg_temp.confirm('r2-pa-0008', (select v #>> '{}' from j where k = 'pa4'))), 'active',
  'S1 (round 3): a new admin confirms the same IBAN proposed again');
select results_eq($$ select pg_temp.try('12', pg_temp.clr('r2-clr-0008')), pg_temp.can_clear('12') $$,
  $$ values ('payee check refused: same_person'::text, 'false'::text) $$,
  'S1 (round 3): who only confirmed a same-IBAN replacement cannot clear the check (nor is offered to)');
-- the account carrying the flagged IBAN comes back « returned » (a payout returned, M2c-7): the check stays open
update public.client_payout_account set status = 'returned' where id = (select (v #>> '{}')::uuid from j where k = 'pa4');
insert into t select 'c5', pg_temp.chk(null);
select results_eq($$ select private.remittance_payout_blockers('00000000-0000-0000-0000-0000000000a1', 'EUR', private.paris_today()),
                            pg_temp.checks_listed('11'),
                            (select count(*)::int from public.payment_check_result r
                             where r.run_id = pg_temp.v('c5') and r.code = 'payee_name_mismatch'),
                            private.transfer_card(pg_temp.trid('r1'), null) ->> 'payee_check_open' $$,
  $$ values ('{payout_account_returned}'::text[], 1, 1, 'true'::text) $$,
  'S1 (round 3): a returned account carrying the flagged IBAN keeps the check open — listed, alerted, on the transfer');
-- that IBAN confirmed once more replaces the returned account: still flagged (the check follows the IBAN)
insert into j select 'pa5', to_jsonb(pg_temp.try('13', pg_temp.propose('r2-pa-0009')));
select is(pg_temp.try('04', pg_temp.confirm('r2-pa-0010', (select v #>> '{}' from j where k = 'pa5'))), 'active',
  'S1 (round 3): the same IBAN confirmed again replaces the returned account');
select is(pg_temp.try('11', pg_temp.clr('r2-clr-0006')), 'true', 'S1: a third person clears it …');
insert into t select 'c4', pg_temp.chk(null);
select results_eq($$ select private.remittance_payout_blockers('00000000-0000-0000-0000-0000000000a1', 'EUR', private.paris_today()),
                            pg_temp.checks_listed('11'),
                            (select count(*)::int from public.payment_check_result r
                             where r.run_id = pg_temp.v('c4') and r.code = 'payee_name_mismatch') $$,
  $$ values ('{}'::text[], 0, 0) $$, 'S1: … then the IBAN is paid again, the check no longer listed nor alerted');

select results_eq($$ select count(*) filter (where entry_type in ('remittance', 'servicer_sweep'))::int
                     from public.ledger_entry where organization_id = '00000000-0000-0000-0000-0000000000aa' $$,
  $$ values (0) $$, 'no remittance nor sweep booked by any of it (M2c-6b books the debits)');

select * from finish();
rollback;
