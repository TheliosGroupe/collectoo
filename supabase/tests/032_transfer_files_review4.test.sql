-- M2c-6a review fixes, round 4 (the skeptics' NEW-G1, NEW-G2, NEW-G3 and residual (b) of round 3; design §9.7, §11,
-- §12; ADR-0014 « M2c-6a review fixes », round 4; COMPLIANCE OQ-80). 028 holds the slice's cases, 029–031 the first
-- three reviews'; this file the fourth round's:
--   * G1 a payout, refund or sweep cancelled alone out of a live downloaded file (the bank refused it, the batch line of
--     its PmtInf left it out) and executed late after all as a batch line of that PmtInf, booked after its
--     cancellation's window, has left the account: its run or refund is not cancelled, no sweep is issued, and it is
--     alerted (H1a, H1b);
--   * G2 a debit of the end-to-end id of a transfer a refund's transfer re-issues is not linked to that refund while the
--     re-issue sits in a downloaded file: that file would pay the refund again — cancel it on evidence first (H16);
--   * G3 a camt.053 covers a day only within one section's own whole days (`covers_from` … `covers_to`, as the parser
--     reads FrToDt in Paris time), never across a break in the balances (an opening that is not the previous
--     section's closing);
--   * G4 a downloaded file holding a transfer that left the account already (a predecessor's debit) is not served again
--     (`holds_debited_transfer`).
-- No ledger entry is posted by any of it.
begin;
select plan(25);
-- Review round 5 (fail-closed; ADR-0014 « M2c-6a review fixes », round 5): cancellation after download is off until
-- M2c-6b (private.feature_switch). This file exercises the machinery behind it, so it turns it on in its own
-- transaction (rolled back with it); 033 tests it off.
update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';

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
    and c.day > private.paris_today() - 90
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
-- the k-th business day of the timeline: d(0) (eighteen business days ago), d(1), …, d(17) the last before today
create or replace function pg_temp.d(p_k integer) returns date language sql as $$ select pg_temp.bd(18 - p_k) $$;
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


-- G1 (NEW-G1, H1a) a payout and the sweep refused out of a live file, executed late as batch lines ------------------
-- F1 holds Martin (M) and Lilas (L) in its first PmtInf, the sweep (S) in its second. The bank books the first PmtInf
-- as one line of Lilas's amount alone and nothing of the second: M and S are cancelled on that evidence by two people
-- (the file stays live: Lilas was paid). Two days later the bank releases what it held, the same way: one line per
-- PmtInf, no end-to-end id.
select pg_temp.handed_out('f1', 'r4-gen-0001', 0);
insert into t values ('m1', pg_temp.trid('r1')), ('l1', pg_temp.trid('r2')), ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
select pg_temp.statement('b1', pg_temp.d(1), null, jsonb_build_array(
  jsonb_build_object('amount', 419840, 'pmt_inf', pg_temp.pmt('f1', 1))), pg_temp.d(0), pg_temp.after(1));
select results_eq($$ select pg_temp.try('01', pg_temp.req_tr('r4-rq-0001', pg_temp.v('m1'))),
                            pg_temp.try('04', pg_temp.conf_tr('r4-cf-0001', pg_temp.v('m1'))),
                            pg_temp.try('01', pg_temp.req_tr('r4-rq-0002', pg_temp.v('s1'))),
                            pg_temp.try('04', pg_temp.conf_tr('r4-cf-0002', pg_temp.v('s1'))),
                            private.transfer_debited_before(pg_temp.v('m1')) $$,
  $$ values ('requested'::text, 'cancelled'::text, 'requested'::text, 'cancelled'::text, false) $$,
  'G1 (H1a): Martin and the sweep, left out of their PmtInfs'' lines in a live file, are cancelled on that evidence');
select pg_temp.statement('b2', pg_temp.d(3), null, jsonb_build_array(
  jsonb_build_object('amount', 164000, 'pmt_inf', pg_temp.pmt('f1', 1)),
  jsonb_build_object('amount', 12000, 'pmt_inf', pg_temp.pmt('f1', 2))), pg_temp.d(2), pg_temp.after(3));
select results_eq($$ select private.transfer_debited_before(pg_temp.v('m1')),
                            (select array_agg(x) from private.debited_cancelled_sweeps('80000000-0000-0000-0000-0000000000cf') x)
                              = array[pg_temp.v('s1')],
                            private.transfer_debited_before(pg_temp.v('l1')) $$,
  $$ values (true, true, false) $$,
  'G1 (H1a): a later batch line of their PmtInf, booked after their cancellation''s window, that can be them: they left the account');
select results_eq($$ select pg_temp.try('04', pg_temp.cancel_run('r4-run-0001', 'r1')),
                            (select status from public.remittance_run where id = pg_temp.v('r1')),
                            (select count(*)::int from private.remittance_pending
                             where client_organization_id = '00000000-0000-0000-0000-0000000000a1') $$,
  $$ values ('remittance run refused: transfer_already_debited'::text, 'sent'::text, 0) $$,
  'G1 (H1a): so Martin''s run is not cancelled (its lines would be paid again)');
select is(pg_temp.try('01', $q$ select public.generate_transfer_file('r4-gen-0002', '80000000-0000-0000-0000-0000000000cf',
                                                                     null)::text $q$),
  'transfer file refused: nothing_to_file', 'G1 (H1a): and no new sweep is issued (the servicer''s share would leave twice)');

-- G1 (NEW-G1, H1b) a refund refused out of a live file, executed late as a batch line ------------------------------
insert into j select 'rq', pg_temp.refund('31', 5000);
insert into j select 'rp', pg_temp.refund('32', 9000);
select pg_temp.handed_out('f3', 'r4-gen-0003', 4);
insert into t values ('q1', pg_temp.rft('rq'));
select pg_temp.statement('b3', pg_temp.d(5), null, jsonb_build_array(
  jsonb_build_object('amount', 9000, 'pmt_inf', pg_temp.pmt('f3', 1))), pg_temp.d(4), pg_temp.after(5));
select results_eq($$ select pg_temp.try('01', pg_temp.req_tr('r4-rq-0003', pg_temp.v('q1'))),
                            pg_temp.try('04', pg_temp.conf_tr('r4-cf-0003', pg_temp.v('q1'))),
                            private.transfer_debited_before(pg_temp.v('q1')) $$,
  $$ values ('requested'::text, 'cancelled'::text, false) $$,
  'G1 (H1b): the 50,00 € refund, left out of its PmtInf''s line, is cancelled — that line, within the window, is not it');
select pg_temp.statement('b4', pg_temp.d(7), null, jsonb_build_array(
  jsonb_build_object('amount', 5000, 'pmt_inf', pg_temp.pmt('f3', 1))), pg_temp.d(6), pg_temp.after(7));
select results_eq($$ select private.transfer_debited_before(pg_temp.v('q1')),
                            pg_temp.try('01', pg_temp.cancel_refund('r4-crf-0001', 'rq')),
                            (select status from public.refund_request where id = pg_temp.rq('rq')),
                            (select status from public.payment where id = pg_temp.pay('31')) $$,
  $$ values (true, 'refund refused: already_debited'::text, 'requested'::text, 'refund_pending'::text) $$,
  'G1 (H1b): a later 50,00 € line of its PmtInf: the refund is not cancelled (it would be refunded twice)');
insert into t select 'c1', pg_temp.chk(null);
select is(pg_temp.already_debited('c1'), array['payout 164000 cancelled', 'refund 5000 cancelled', 'sweep 12000 cancelled'],
  'G1: each one alerted (transfer_already_debited): the payout and the refund while their run and refund are live');

-- G2 (NEW-G2, H16) the old RFD id debited while the refund's re-issue sits in a downloaded file ---------------------
-- a refund of a payment received before the timeline (a debit is never linked before its payment)
create or replace function pg_temp.refund_on(p_n text, p_amount bigint, p_day date) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.collect(p_n, p_amount, p_day, false);
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.request_refund('r4-rfd-' || p_n, pg_temp.pay(p_n), p_amount::text, null, null, 'other', null,
                             p_amount::text, 'payeur inconnu');
  reset role;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'rr', pg_temp.refund_on('41', 6000, pg_temp.d(0) - 7);
select pg_temp.handed_out('f5', 'r4-gen-0005', 8);
insert into t values ('rf0', pg_temp.rft('rr'));
select pg_temp.statement('b5', pg_temp.d(9), null, '[]', pg_temp.d(8), pg_temp.after(9));
select results_eq($$ select pg_temp.try('01', pg_temp.req_file('r4-rq-0005', 'f5')),
                            pg_temp.try('04', pg_temp.conf_file('r4-cf-0005', 'f5')),
                            pg_temp.replaces(pg_temp.rft('rr')) = pg_temp.v('rf0') $$,
  $$ values ('requested'::text, 'superseded'::text, true) $$,
  'G2 (H16): a file holding the refund cancelled whole on evidence: the refund re-issued under a fresh RFD id');
insert into t values ('rf1', pg_temp.rft('rr'));
select pg_temp.handed_out('f6', 'r4-gen-0006', 10);
select results_eq($$ select (select i.transfer_id from public.transfer_file_item i where i.file_id = pg_temp.v('f6')) = pg_temp.v('rf1'),
                            pg_temp.download('01', pg_temp.v('f6'), true) ->> 'download' $$,
  $$ values (true, '2'::text) $$, 'G4: the re-issue''s file, downloaded once, can be downloaded again (warning acknowledged)');
-- the cancelled file executed late after all: a debit of the old RFD id
select pg_temp.statement('b6', pg_temp.d(11), null, jsonb_build_array(
  jsonb_build_object('amount', 6000, 'e2e', pg_temp.e2e(pg_temp.v('rf0')), 'kind', 'refund_out')), pg_temp.d(10),
  pg_temp.after(11));
select is(pg_temp.try('01', format($q$ select public.transfer_file_download(%L, %L, true)::text $q$, pg_temp.v('f6'),
                                   pg_temp.sha(pg_temp.v('f6')))),
  'transfer file refused: holds_debited_transfer',
  'G4: once a transfer it holds has left the account (its predecessor''s debit), the file is not served again');
select matches(pg_temp.try('01', format($q$ select public.link_debit('r4-link-0001', %L, 'refund', null, %L, null,
                                                                    'ancien fichier exécuté')::text $q$,
                                        (select x.id from public.bank_transaction x
                                         where x.end_to_end_id = pg_temp.e2e(pg_temp.v('rf0'))), pg_temp.rq('rr'))),
  'refund refused: reissue_in_downloaded_file',
  'G2 (H16): that debit is not linked to the refund while its re-issue is in a downloaded file (it would pay it again)');
select results_eq($$ select (select status from public.refund_request where id = pg_temp.rq('rr')), pg_temp.status(pg_temp.v('rf1')),
                            (select transfer_file_id = pg_temp.v('f6') from public.bank_transfer where id = pg_temp.v('rf1')) $$,
  $$ values ('requested'::text, 'in_file'::text, true) $$, 'G2: the refund stays requested, its re-issue in the file');
-- the safe order: that file cancelled first, on its own evidence, then the debit linked
select results_eq($$ select pg_temp.try('01', pg_temp.req_file('r4-rq-0006', 'f6')),
                            pg_temp.try('04', pg_temp.conf_file('r4-cf-0006', 'f6')) $$,
  $$ values ('requested'::text, 'superseded'::text) $$, 'G2: the re-issue''s file is cancelled on its own evidence');
insert into t values ('rf2', pg_temp.rft('rr'));
select is(pg_temp.hold(pg_temp.v('rf2')), 'already_debited', 'G2: the next re-issue is held (its chain was debited)');
select is(pg_temp.try('01', format($q$ select public.link_debit('r4-link-0002', %L, 'refund', null, %L, null,
                                                              'ancien fichier exécuté') -> 'result' ->> 'refunds' $q$,
                                   (select x.id from public.bank_transaction x
                                    where x.end_to_end_id = pg_temp.e2e(pg_temp.v('rf0'))), pg_temp.rq('rr'))),
  '1', 'G2: then the debit is linked …');
select results_eq($$ select (select status from public.refund_request where id = pg_temp.rq('rr')), pg_temp.status(pg_temp.v('rf2')) $$,
  $$ values ('executed'::text, 'booked'::text) $$,
  'G2: … the refund executed by it, its transfer booked (no file carries it any more)');

-- G3 (NEW-G3) a statement covers only its sections' own whole days, never across a break in the balances -------------
-- one camt.053 with a <Stmt> of d(12) and one of d(14), none of d(13), produced after d(14); the second's opening is not
-- the first's closing
select pg_temp.statement('d1', pg_temp.d(14), null, '[]', pg_temp.d(12), pg_temp.after(14), 'camt053', null,
  jsonb_build_array(
    jsonb_build_object('from_date', pg_temp.d(12), 'to_date', pg_temp.d(12), 'covers_from', pg_temp.d(12),
                       'covers_to', pg_temp.d(12), 'opening_minor', '100', 'closing_minor', '100',
                       'created_at', pg_temp.after(14)),
    jsonb_build_object('from_date', pg_temp.d(14), 'to_date', pg_temp.d(14), 'covers_from', pg_temp.d(14),
                       'covers_to', pg_temp.d(14), 'opening_minor', '-500', 'closing_minor', '-500',
                       'created_at', pg_temp.after(14))));
select results_eq($$ select pg_temp.covers(12, 12), pg_temp.covers(13, 13), pg_temp.covers(14, 14), pg_temp.covers(12, 14) $$,
  $$ values (true, false, true, false) $$,
  'G3 (H8c): a file of two sections covers each one''s own days, not the day between them');
-- two statements one after the other whose balances do not follow (« relevé manquant »)
select pg_temp.statement('d2', pg_temp.d(15), 1000, '[]', pg_temp.d(15), pg_temp.after(15));
select pg_temp.statement('d3', pg_temp.d(16), 0, '[]', pg_temp.d(16), pg_temp.after(16));
select results_eq($$ select pg_temp.covers(15, 15), pg_temp.covers(16, 16), pg_temp.covers(15, 16) $$,
  $$ values (true, true, false) $$,
  'G3: each day covered, but never a window across a break: the second opens with what the first did not close with');
select pg_temp.statement('d4', pg_temp.d(16), 1000, '[]', pg_temp.d(15), pg_temp.after(16), 'camt053', null, null, 1000);
select is(pg_temp.covers(15, 16), false, 'G3: nor once a statement of both days is imported too (the break stays)');
-- a statement of part of a day only (FrDtTm in the afternoon, ToDtTm at the next midnight: no whole day)
select pg_temp.statement('d5', pg_temp.d(17), null, '[]', pg_temp.d(17), pg_temp.after(17), 'camt053', null,
  jsonb_build_array(jsonb_build_object('from_date', pg_temp.d(17), 'to_date', pg_temp.d(17), 'covers_from', null,
                                       'covers_to', null, 'opening_minor', '0', 'closing_minor', '0',
                                       'created_at', pg_temp.after(17))));
select is(pg_temp.covers(17, 17), false, 'G3 (H8a): a statement of the afternoon of a day covers no day');
select pg_temp.statement('d6', pg_temp.d(17), null, '[]', pg_temp.d(17), pg_temp.after(17, '10:00'));
select is(pg_temp.covers(17, 17), true, 'G3: the statement of the whole day does');
select throws_ok($$ select pg_temp.statement('d7', pg_temp.d(17), null, '[]', null, null, 'camt053', null,
                                             '[{"covers_from": "29/10/2026", "covers_to": "2026-10-29"}]') $$, '22023',
  'header_invalid: a statement''s whole days are not two dates in order',
  'G3: whole days that are not two dates in order refuse the import');
select throws_ok($$ select pg_temp.statement('d8', pg_temp.d(17), null, '[]', null, null, 'camt053', null,
                                             '[{"covers_from": "2026-10-29", "covers_to": "2026-10-28"}]') $$, '22023',
  'header_invalid: a statement''s whole days are not two dates in order',
  'G3: nor a last whole day before the first');

select results_eq($$ select count(*) filter (where entry_type in ('remittance', 'servicer_sweep'))::int
                     from public.ledger_entry where organization_id = '00000000-0000-0000-0000-0000000000aa' $$,
  $$ values (0) $$, 'no remittance nor sweep booked by any of it (M2c-6b books the debits)');

select * from finish();
rollback;
