-- M2c-6b-3b part 1, the last switch-on prerequisites (ADR-0014 « M2c-6b-3a-2 review fixes » « Open after round 4 », «
-- M2c-6b-3b part 1 »; COMPLIANCE CPCE-08). The switch STAYS OFF in the migration: each scenario below turns
-- private.feature_switch 'downloaded_file_cancellation' on inside its own subtransaction (pg_temp.isolated: rolled back
-- at its end, its outcomes kept), as 6b-3b's one-line migration will, and the file asserts at its end that the switch
-- is off. What each scenario pins:
--   * booking-rows-skip-chain-coverage-and-waiting-lines (CPCE-08): the booking of a run whose payout chain holds
--     another transfer writes its R124-6 rows only once the paying account's statements cover [least(e0, L), L] and no
--     other transfer of the chain handed out has a line that may be its debit by L that the chain's rule does not count
--     yet; the nightly check's booked branch judges such a run once both hold, at the chain's paid date — S1 (an earlier
--     statement imported after the re-issue's), S2c (a line without our references waiting), their controls (the
--     earlier statement shows no debit of x; the line classified not ours; a possible debit past the bound days), S3
--     (the late predecessor booked after L), and 040's property with the lines arriving on several statements over time;
--   * the three mutants round 4 left alive (a line booked or linked otherwise, the previewed line, the requested
--     execution date's bound);
--   * the switch off at the end.
-- The fixtures and helpers are 040's (each scenario builds on its states: F1 downloaded on d(0) and cancelled whole on
-- evidence, Martin's payout x re-issued as y).
begin;
select plan(14);




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




-- 6b-3a's helpers ------------------------------------------------------------------------------------------------------
-- the commands' idempotency keys of this file (8 characters at least): its scenarios' short keys, prefixed
create or replace function pg_temp.k(p_key text) returns text language sql as $$ select 'k6b3a-' || p_key $$;
create or replace function pg_temp.gen(p_user text, p_key text, p_late text default null, p_aal text default 'aal2',
                                       p_account uuid default '80000000-0000-0000-0000-0000000000cf')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.generate_transfer_file(pg_temp.k(p_key), p_account, p_late);
  reset role;
  return v;
end $$;
create or replace function pg_temp.req_file(p_key text, p_file text) returns text language sql as $$
  select format($q$ select public.request_transfer_file_cancellation(%L, %L, %s, 'Fichier non déposé', 'not_uploaded')
                     ->> 'status' $q$, pg_temp.k(p_key), pg_temp.v(p_file), (pg_temp.fl(pg_temp.v(p_file))).version) $$;
create or replace function pg_temp.conf_file(p_key text, p_file text) returns text language sql as $$
  select format($q$ select public.confirm_transfer_file_cancellation(%L, %L, %s) ->> 'status' $q$, pg_temp.k(p_key),
                pg_temp.v(p_file), (pg_temp.fl(pg_temp.v(p_file))).version) $$;
create or replace function pg_temp.req_tr(p_key text, p_transfer uuid) returns text language sql as $$
  select format($q$ select public.request_transfer_cancellation(%L, %L, 'Refusé par la banque') ->> 'status' $q$,
                pg_temp.k(p_key), p_transfer) $$;
create or replace function pg_temp.conf_tr(p_key text, p_transfer uuid) returns text language sql as $$
  select format($q$ select public.confirm_transfer_cancellation(%L, %L) ->> 'status' $q$, pg_temp.k(p_key), p_transfer) $$;
create or replace function pg_temp.cancel_run(p_key text, p_run text) returns text language sql as $$
  select format($q$ select public.cancel_remittance_run(%L, %L, %s, 'à refaire') ->> 'status' $q$, pg_temp.k(p_key),
                pg_temp.v(p_run), (select version from public.remittance_run where id = pg_temp.v(p_run))) $$;
create or replace function pg_temp.cancel_refund(p_key text, p_rf text) returns text language sql as $$
  select format($q$ select public.cancel_refund(%L, %L, 'annulé') ->> 'status' $q$, pg_temp.k(p_key), pg_temp.rq(p_rf)) $$;
create or replace function pg_temp.cf() returns uuid language sql as $$ select '80000000-0000-0000-0000-0000000000cf'::uuid $$;
create or replace function pg_temp.cg() returns uuid language sql as $$ select '80000000-0000-0000-0000-0000000000cd'::uuid $$;
create or replace function pg_temp.own_iban() returns text language sql as $$ select 'FR7610107001011234567890129' $$;
create or replace function pg_temp.martin_iban() returns text language sql as $$ select 'FR7630004000031234567890143' $$;
create or replace function pg_temp.lilas_iban() returns text language sql as $$ select 'FR1420041010050500013M02606' $$;
-- A statement of an account (cf unless p_account) from p_from (default p_to) to p_to, uploaded at p_uploaded_at (default
-- now), camt.053 unless p_format, its closing p_closing (none by default), with lines [{amount, e2e, pmt_inf, iban, kind,
-- dir, orig_e2e, day}]: a debit by default, of kind other_debit when it names no reference (transfer_out otherwise),
-- booked on p_to unless its day says
create or replace function pg_temp.lines(p_n text, p_to date, p_lines jsonb default '[]', p_from date default null,
                                         p_uploaded_at timestamptz default null, p_format text default 'camt053',
                                         p_account uuid default '80000000-0000-0000-0000-0000000000cf',
                                         p_closing bigint default null)
returns uuid language plpgsql as $$
declare s uuid := ('e3000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', p_account, 'EUR', p_format, 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = coalesce(p_uploaded_at, now()) where id = s;
  insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       original_end_to_end_id, counterparty_iban)
  select '00000000-0000-0000-0000-0000000000aa', p_account, s, d.ord, 't:' || s || d.ord,
         coalesce(d.v ->> 'dir', 'debit'), (d.v ->> 'amount')::bigint, 'EUR', coalesce((d.v ->> 'day')::date, p_to),
         coalesce(d.v ->> 'kind', case when coalesce(d.v ->> 'dir', 'debit') = 'credit' then 'return'
                                       when d.v ->> 'e2e' is null and d.v ->> 'pmt_inf' is null then 'other_debit'
                                       else 'transfer_out' end),
         d.v ->> 'e2e', d.v ->> 'pmt_inf', d.v ->> 'orig_e2e', d.v ->> 'iban'
  from jsonb_array_elements(p_lines) with ordinality d (v, ord);
  update public.bank_statement set status = 'imported', from_date = coalesce(p_from, p_to), to_date = p_to,
    opening_booked_minor = 0, closing_booked_minor = p_closing, counts = '{}', finished_at = clock_timestamp(),
    sections = case when p_format = 'camt053'
                    then jsonb_build_array(jsonb_build_object(
                           'from_date', coalesce(p_from, p_to), 'to_date', p_to, 'covers_from', coalesce(p_from, p_to),
                           'covers_to', p_to, 'opening_minor', '0', 'closing_minor', p_closing::text,
                           'created_at', coalesce(p_uploaded_at, now()))) end
  where id = s;
  return s;
end $$;
create or replace function pg_temp.ln(p_statement text, p_no integer default 1) returns uuid language sql as $$
  select id from public.bank_transaction
  where statement_id = ('e3000000-0000-0000-0000-0000000000' || p_statement)::uuid and line_no = p_no $$;
-- a file cancelled whole on evidence by two people: the statements of its day (the p_day-th business day of the
-- timeline) and the next show nothing of it (a CSV export, ending a day later, when p_format says)
create or replace function pg_temp.cancel_whole(p_file text, p_key text, p_n text, p_day integer default 0,
                                                p_format text default 'camt053') returns text language plpgsql as $$
declare v_to integer := p_day + case when p_format = 'csv' then 2 else 1 end;
begin
  perform pg_temp.lines(p_n, pg_temp.d(v_to), '[]', pg_temp.d(p_day), pg_temp.after(v_to), p_format);
  return pg_temp.try('01', pg_temp.req_file(p_key || '-rq', p_file)) || '/'
         || pg_temp.try('04', pg_temp.conf_file(p_key || '-cf', p_file));
end $$;
-- a SQL text's single value as text, or its error's message (dynamic: the bodies name functions this slice adds)
create or replace function pg_temp.q(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  execute p_sql into v;
  return coalesce(v, 'null');
exception when others then
  return sqlerrm;
end $$;
-- a generation, or its refusal (message and detail)
create or replace function pg_temp.gen_try(p_key text, p_account uuid default '80000000-0000-0000-0000-0000000000cf')
returns jsonb language plpgsql as $$
declare v jsonb; v_msg text; v_detail text;
begin
  begin
    v := pg_temp.gen('01', p_key, null, 'aal2', p_account);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    v := jsonb_build_object('error', v_msg, 'detail', v_detail::jsonb);
  end;
  return v;
end $$;
-- a first download, or its refusal
create or replace function pg_temp.dl_try(p_file uuid, p_ack boolean default false) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  begin
    v := pg_temp.download('01', p_file, p_ack);
  exception when others then
    reset role;
    v := jsonb_build_object('error', sqlerrm);
  end;
  return v;
end $$;
create or replace function pg_temp.redownload(p_file text) returns text language sql as $$
  select pg_temp.try('01', format($q$ select public.transfer_file_download(%L, %L, true) ->> 'download' $q$,
                                  pg_temp.v(p_file), pg_temp.sha(pg_temp.v(p_file)))) $$;
-- one run of a client as pg_temp.run, under its own idempotency keys (a client's second run)
create or replace function pg_temp.run2(p_c text, p_files jsonb, p_take bigint, p_vat_moved bigint, p_num bigint,
                                        p_den bigint, p_key text) returns uuid
language plpgsql as $$
declare v_run uuid; v_gross bigint; v_ht bigint;
begin
  select sum((x.value)::bigint), sum((x.value)::bigint * p_num / p_den) into v_gross, v_ht
  from jsonb_each_text(p_files) x;
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_run := (public.request_remittance_run(pg_temp.k('rq-' || p_key), ('00000000-0000-0000-0000-0000000000' || p_c)::uuid)
            ->> 'run_id')::uuid;
  reset role;
  perform pg_temp.prepare(v_run, pg_temp.doc(p_c, p_files, p_num, p_den), pg_temp.keys(p_c, p_files, p_num, p_den),
                          pg_temp.plan(p_c, v_gross, v_ht, p_take, p_vat_moved));
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs(pg_temp.k('ap-' || p_key), pg_temp.item(v_run));
  reset role;
  perform private.approve_remittance_run(v_run, (select job_token from public.remittance_run where id = v_run));
  return v_run;
end $$;
-- the servicer's new share: a second collection of Cyprès (12 000), its commission set off whole at approval (N = 0)
create or replace function pg_temp.cypres_again(p_key text) returns void language plpgsql as $$
begin
  perform pg_temp.file('04', '20000000-0000-0000-0000-0000000000a3', 12000);
  perform pg_temp.collect('04', 12000, private.paris_today() - 2);
  perform pg_temp.run2('a3', '{"04": "12000"}', 12000, 2000, 10, 12, p_key);
end $$;
-- « Comptabiliser… » (as 037b): a part, the preview, the options, the command and its refusal's code
create or replace function pg_temp.pt(p_kind text, p_transfer uuid, p_amount bigint, p_client uuid default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('kind', p_kind, 'transfer_id', p_transfer, 'client_id', p_client,
                                              'amount', p_amount::text)) $$;
create or replace function pg_temp.pv(p_line uuid, p_parts jsonb) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.transfer_line_preview(p_line, p_parts);
  reset role;
  return v;
end $$;
create or replace function pg_temp.op(p_line uuid) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.transfer_line_options(p_line);
  reset role;
  return v;
end $$;
create or replace function pg_temp.prop(p_line uuid) returns jsonb language sql as $$
  select pg_temp.op(p_line) -> 'proposals' -> 0 -> 'request' $$;
create or replace function pg_temp.why(p_line uuid, p_parts jsonb) returns text language sql as $$
  select coalesce(pg_temp.pv(p_line, p_parts) ->> 'why', 'ok') $$;
create or replace function pg_temp.bkx(p_line uuid, p_parts jsonb, p_key text default null) returns text
language plpgsql as $$
declare v_text text;
begin
  v_text := coalesce(pg_temp.pv(p_line, p_parts) ->> 'expected_text', 'none');
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.book_transfer_line(coalesce(p_key, 'bk-' || md5(p_line::text || p_parts::text)), p_line, p_parts,
                                    v_text, 'motif de test');
  reset role;
  return 'ok';
exception when others then
  reset role;
  return regexp_replace(sqlerrm, '^transfer line booking refused: ', '');
end $$;
-- « Lier » (link_debit) by ops: its result's kind, or the refusal's message
create or replace function pg_temp.link(p_key text, p_line uuid, p_kind text, p_refund uuid, p_payment uuid default null)
returns text language sql as $$
  select pg_temp.try('01', format($q$ select public.link_debit(%L, %L, %L, %L, %L, null, 'motif de test') ->> 'kind' $q$,
                                  pg_temp.k(p_key), p_line, p_kind, p_payment, p_refund)) $$;
-- what the nightly check raised, by code: « kind amount status » rows of transfer_already_debited (pg_temp.already_debited)
-- and the count of rows of another code
create or replace function pg_temp.raised(p_run text, p_code text) returns integer language sql as $$
  select count(*)::integer from public.payment_check_result r where r.run_id = pg_temp.v(p_run) and r.code = p_code $$;
-- a refund of payment p_n of p_amount asked again (its earlier refund cancelled), to the payer's IBAN
create or replace function pg_temp.refund_again(p_k text, p_n text, p_amount bigint, p_key text) returns void
language plpgsql as $$
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  insert into j select p_k, public.request_refund(pg_temp.k(p_key), pg_temp.pay(p_n), p_amount::text,
    'FR7630004000031234567890143', 'Payeur Nouveau', 'other', null, p_amount::text, 'second remboursement');
  reset role;
end $$;
-- the G1c state (034): F1 downloaded, Lilas' payout and the sweep booked from its day's statement as batch lines of their
-- PmtInfs, Martin's refused: cancelled alone (two people, on that evidence), then its run unless p_keep_run
create or replace function pg_temp.g1c_prefix(p_key text, p_keep_run boolean default false) returns void
language plpgsql as $$
begin
  perform pg_temp.handed_out('f1', p_key || '-g1', 0);
  insert into t values ('m0', pg_temp.trid('r1'));
  perform pg_temp.lines('b1', pg_temp.d(1), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'pmt_inf', pg_temp.pmt('f1', 1), 'day', pg_temp.d(0)),
    jsonb_build_object('amount', 12000, 'pmt_inf', pg_temp.pmt('f1', 2), 'day', pg_temp.d(0))), pg_temp.d(0),
    pg_temp.after(1));
  perform pg_temp.try('01', pg_temp.req_tr(p_key || '-rq', pg_temp.v('m0')));
  perform pg_temp.try('04', pg_temp.conf_tr(p_key || '-cf', pg_temp.v('m0')));
  if not p_keep_run then
    perform pg_temp.try('04', pg_temp.cancel_run(p_key || '-run', 'r1'));
  end if;
end $$;
-- the H-PAY state (034): F0 the payouts and the sweep, downloaded; a refund of payment 71 alone in F1, downloaded,
-- cancelled whole and the refund cancelled; a second refund of the payment (re-issuing none), downloaded in F2 unless
-- p_file is false
create or replace function pg_temp.hpay_prefix(p_key text, p_file boolean default true, p_format text default 'camt053',
                                               p_paid date default null)
returns void language plpgsql as $$
begin
  perform pg_temp.handed_out('f0', p_key || '-g0', 0);
  if p_paid is null then
    insert into j select 'rq', pg_temp.refund('71', 5000);
  else
    -- the payment received earlier (a debit line dated before it cannot be linked to its refund)
    perform pg_temp.collect('71', 5000, p_paid, false);
    perform pg_temp.as_user('01');
    set local role authenticated;
    insert into j select 'rq', public.request_refund(pg_temp.k(p_key || '-rfd1'), pg_temp.pay('71'), '5000', null,
                                                     null, 'other', null, '5000', 'payeur inconnu');
    reset role;
  end if;
  perform pg_temp.handed_out('f1', p_key || '-g1', 0);
  insert into t values ('q0', pg_temp.rft('rq'));
  perform pg_temp.cancel_whole('f1', p_key, 'b1', 0, p_format);
  perform pg_temp.try('01', pg_temp.cancel_refund(p_key || '-crf', 'rq'));
  perform pg_temp.refund_again('r2', '71', 5000, p_key || '-rfd2');
  if p_file then
    perform pg_temp.handed_out('f2', p_key || '-g2', 2);
  end if;
end $$;
-- the switch on for the scenario only (6b-3b's migration will switch it): rolled back with it, its outcome kept
create or replace function pg_temp.isolated(p_scenario text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  begin
    update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
    execute format('select pg_temp.%I()', p_scenario) into v;
    raise exception 'scenario % rolled back', p_scenario using errcode = 'TR001';
  exception when sqlstate 'TR001' then
    null;
  end;
  return v;
end $$;
-- what a generation held out (as 034's pg_temp.held), also when it filed nothing (its refusal's detail)
create or replace function pg_temp.held(p_gen text) returns text[] language sql as $$
  select array_agg((h ->> 'kind') || ' ' || (h ->> 'amount_minor') || ' ' || (h ->> 'reason')
                   order by h ->> 'kind', (h ->> 'amount_minor')::bigint)
  from j cross join lateral jsonb_array_elements(coalesce(j.v -> 'held', j.v #> '{detail,held}')) h
  where j.k = p_gen $$;
create or replace function pg_temp.dcs() returns jsonb language sql as $$
  select coalesce(jsonb_agg(x order by x), '[]')
  from private.debited_cancelled_sweeps('80000000-0000-0000-0000-0000000000cf') x $$;
create or replace function pg_temp.file_of(p_transfer uuid) returns uuid language sql as $$
  select transfer_file_id from public.bank_transfer where id = p_transfer $$;
-- review round 7 (as 034): what the refund's trigger says (message | hint) when a debit line executes it, rolled back
create or replace function pg_temp.follow(p_rf text, p_line uuid) returns text language plpgsql as $$
declare v_msg text; v_hint text;
begin
  begin
    update public.refund_request set status = 'executed', bank_transaction_id = p_line,
      executed_on = private.paris_today(),
      cash_out_entry_id = (select e.id from public.ledger_entry e
                           where e.organization_id = '00000000-0000-0000-0000-0000000000aa'
                             and not exists (select 1 from public.refund_request q where q.cash_out_entry_id = e.id)
                           order by e.id limit 1)
    where id = pg_temp.rq(p_rf);
    raise exception 'executed' using errcode = 'TR002';
  exception when sqlstate 'TR002' then
    return 'ok';
  when others then
    get stacked diagnostics v_msg = message_text, v_hint = pg_exception_hint;
    return v_msg || ' | ' || coalesce(v_hint, '');
  end;
end $$;
-- (review round 1) the refunds « Lier » lists for a line (public.debit_link_options as ops), by their keys in j
create or replace function pg_temp.listed(p_line uuid, p_keys text[]) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.debit_link_options(p_line) -> 'refunds';
  reset role;
  return (select coalesce(jsonb_agg(k.k order by k.k), '[]')
          from jsonb_array_elements(v) r join unnest(p_keys) k (k) on pg_temp.rq(k.k) = (r ->> 'refund_request_id')::uuid);
end $$;
-- (review round 1) a file-mode refund of an unidentified payment p_n of p_amount to p_iban (the payer's when null)
create or replace function pg_temp.refund_to(p_n text, p_amount bigint, p_iban text, p_key text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.collect(p_n, p_amount, private.paris_today() - 1, false);
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.request_refund(pg_temp.k(p_key), pg_temp.pay(p_n), p_amount::text, p_iban,
                             case when p_iban is not null then 'Payeur ' || p_n end, 'other', null, p_amount::text,
                             'payeur inconnu');
  reset role;
  return v;
end $$;
-- (review round 1) an imported camt.053 of the dedicated account holding one debit of an entry the bank kept unsplit
-- (unsplit_ours 0: no detail of ours), booked today
create or replace function pg_temp.unsplit_line(p_n text, p_amount bigint) returns uuid language plpgsql as $$
declare s uuid := ('e3000000-0000-0000-0000-0000000000' || p_n)::uuid; v uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, unsplit_ours)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), s, 1, 't:' || s || '1', 'debit', p_amount, 'EUR',
          private.paris_today(), 'batch_unsplit', 0)
  returning id into v;
  update public.bank_statement set status = 'imported', from_date = private.paris_today(), to_date = private.paris_today(),
    opening_booked_minor = 0, counts = '{}', finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object(
      'from_date', private.paris_today(), 'to_date', private.paris_today(), 'covers_from', private.paris_today(),
      'covers_to', private.paris_today(), 'opening_minor', '0', 'closing_minor', null, 'created_at', now()))
  where id = s;
  return v;
end $$;



-- 6b-3a-2's helpers ----------------------------------------------------------------------------------------------------
create or replace function pg_temp.k(p_key text) returns text language sql as $$ select 'k6b3a2-' || p_key $$;
-- the ledger and funds invariants of the nightly payment checks (as 037's pg_temp.dirty)
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
-- the E state: F1 (the payouts and the sweep) downloaded on d(0) and cancelled whole on evidence by two people —
-- Martin's payout x (m0) and Lilas' (l0) cancelled, each re-issued (y, yl: ordered), the sweep cancelled
create or replace function pg_temp.lp_prefix(p_key text) returns void language plpgsql as $$
begin
  perform pg_temp.handed_out('f1', p_key || '-g1', 0);
  insert into t values ('m0', pg_temp.trid('r1')), ('l0', pg_temp.trid('r2'));
  insert into t values ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
  perform pg_temp.cancel_whole('f1', p_key, 'b1');
  insert into t values ('y', pg_temp.trid('r1')), ('yl', pg_temp.trid('r2'));
end $$;
-- a line executing x late under its own RMT id, on p_day (today by default)
create or replace function pg_temp.x_late(p_n text, p_day date default null) returns uuid language plpgsql as $$
begin
  perform pg_temp.lines(p_n, coalesce(p_day, private.paris_today()), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')))));
  return pg_temp.ln(p_n);
end $$;
-- the command with a compare text of the caller's (a preview taken earlier), its refusal's code or 'ok'
create or replace function pg_temp.bk_text(p_line uuid, p_parts jsonb, p_text text, p_key text) returns text
language plpgsql as $$
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.book_transfer_line(pg_temp.k(p_key), p_line, p_parts, p_text, 'motif de test');
  reset role;
  return 'ok';
exception when others then
  reset role;
  return regexp_replace(sqlerrm, '^transfer line booking refused: ', '');
end $$;
-- the parts of the line's first proposal as [kind, x?, P, advance, p_bound, late_predecessor], in their order
create or replace function pg_temp.parts(p_line uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(p ->> 'kind', (p ->> 'transfer_id')::uuid = pg_temp.v('m0'),
                                              p ->> 'paid_minor', p ->> 'advance_minor', p ->> 'p_bound',
                                              p ->> 'late_predecessor')
                            order by (p ->> 'transfer_id')::uuid = pg_temp.v('m0'), p ->> 'kind'), '[]')
  from jsonb_array_elements(pg_temp.pv(p_line, pg_temp.prop(p_line)) -> 'parts') p $$;
create or replace function pg_temp.run_status(p_run text) returns text language sql as $$
  select status from public.remittance_run where id = pg_temp.v(p_run) $$;
create or replace function pg_temp.breaches(p_run text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(coalesce(b.blocked_reason, 'none') order by b.ledger_entry_id), '[]')
  from public.remittance_deadline_breach b where b.run_id = pg_temp.v(p_run) $$;
-- a public read as ops (user 01, aal2), its jsonb
create or replace function pg_temp.read(p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  execute p_sql into v;
  reset role;
  return v;
end $$;
-- a statement's error hint as user p_user at aal2 (the command refused), or 'ok'
create or replace function pg_temp.try_hint(p_user text, p_sql text) returns text language plpgsql as $$
declare v_msg text; v_hint text;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_hint = pg_exception_hint;
    reset role;
    return v_msg || ' | ' || coalesce(v_hint, '');
  end;
  reset role;
  return 'ok';
end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- an imported camt.053 of the dedicated account holding one debit line of an entry the bank kept unsplit: its details of
-- ours p_details ({id, direction, amount_minor}, as the parser stores them), its own end-to-end id p_e2e (one detail of
-- ours that is not the whole entry), its PmtInfId p_pmt and the statement's charges p_charges; the line booked on p_day,
-- the statement covering p_from..p_to (default p_day), produced at p_created_at (default now)
create or replace function pg_temp.uline(p_n text, p_day date, p_amount bigint, p_details jsonb, p_e2e text default null,
                                         p_charges bigint default null, p_pmt text default null,
                                         p_from date default null, p_to date default null,
                                         p_created_at timestamptz default null) returns uuid language plpgsql as $$
declare s uuid := ('e3000000-0000-0000-0000-0000000000' || p_n)::uuid; v uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = coalesce(p_created_at, now()) where id = s;
  insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       batch_entry_ref, unsplit_ours, unsplit_details, unsplit_detail_count,
                                       charges_minor, charges_read)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), s, 1, 't:' || s || '1', 'debit', p_amount, 'EUR',
          p_day, 'batch_unsplit', p_e2e, p_pmt, 'E-' || s, jsonb_array_length(p_details), p_details,
          jsonb_array_length(p_details), p_charges, case when p_charges is not null then true end)
  returning id into v;
  update public.bank_statement set status = 'imported', from_date = coalesce(p_from, p_day),
    to_date = coalesce(p_to, p_day), opening_booked_minor = 0, counts = '{}', finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object(
      'from_date', coalesce(p_from, p_day), 'to_date', coalesce(p_to, p_day), 'covers_from', coalesce(p_from, p_day),
      'covers_to', coalesce(p_to, p_day), 'opening_minor', '0', 'closing_minor', null,
      'created_at', coalesce(p_created_at, now())))
  where id = s;
  return v;
end $$;
-- one detail of ours: a debit of a transfer at its amount (or p_amount)
create or replace function pg_temp.det(p_transfer uuid, p_amount bigint default null) returns jsonb language sql as $$
  select jsonb_build_object('id', t.end_to_end_id, 'direction', 'debit',
                            'amount_minor', coalesce(p_amount, t.amount_minor)::text)
  from public.bank_transfer t where t.id = p_transfer $$;
-- what a generation held out, as « kind amount reason », sorted (its refusal's detail when it filed nothing)
create or replace function pg_temp.held_of(p jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_agg((h ->> 'kind') || ' ' || (h ->> 'amount_minor') || ' ' || (h ->> 'reason')
                            order by h ->> 'kind', (h ->> 'amount_minor')::bigint), '[]')
  from jsonb_array_elements(coalesce(p -> 'held', p #> '{detail,held}')) h $$;
-- the first proposal's request as [kind, amount] pairs, in its order
create or replace function pg_temp.req(p_line uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(p ->> 'kind', p ->> 'amount') order by o), '[]')
  from jsonb_array_elements(pg_temp.prop(p_line)) with ordinality x (p, o) $$;
-- the client's pending queue
create or replace function pg_temp.queue_of(p_c text) returns bigint language sql volatile as $$
  select coalesce(sum(q.amount_minor), 0)::bigint from private.remittance_pending q
  where q.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
-- the debit job's funds pass, emulated as 037 does (its pure rules' rows and reviews, then the SQL re-check and posting)
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
grant execute on all functions in schema pg_temp to authenticated;

-- ri8's state (LD-2) with the two debits on days p_x (the predecessor x) and p_y (its re-issue y, in a downloaded file
-- F2) of one statement, L d(4): the import books y's own debit as the run's payout, x's line reviewed
-- cancelled_transfer_debited (as the job does). The two lines' ids in t (lx, ly). Without p_x_ref, x's line carries
-- none of our references (to Martin's IBAN: rule 3b's only candidate is x).
create or replace function pg_temp.ld2_prefix(p_key text, p_x integer, p_y integer, p_x_ref boolean default true)
returns void language plpgsql as $$
begin
  perform pg_temp.lp_prefix(p_key);
  perform pg_temp.handed_out('f2', p_key || '-g2', 2);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0) where id in (pg_temp.v('m0'), pg_temp.v('y'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(4), deadline = pg_temp.d(6)
  where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  perform pg_temp.lines('c3', pg_temp.d(7), jsonb_build_array(
    case when p_x_ref
         then jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', pg_temp.d(p_x))
         else jsonb_build_object('amount', 164000, 'iban', pg_temp.martin_iban(), 'day', pg_temp.d(p_x)) end,
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')), 'day', pg_temp.d(p_y))), pg_temp.d(2),
    pg_temp.after(7));
  insert into t values ('lx', pg_temp.ln('c3', 1)), ('ly', pg_temp.ln('c3', 2));
  perform pg_temp.book(jsonb_build_array(jsonb_build_object('line', pg_temp.v('ly'), 'kind', 'payout',
                                                            'transfer', pg_temp.v('y'))),
                       jsonb_build_array(jsonb_build_object('line', pg_temp.v('lx'),
                                                            'reason', 'cancelled_transfer_debited')));
end $$;
-- a credit returning transfer p_transfer (its id as the original id) on a statement p_n of the k-th business day,
-- produced the morning after; its line
create or replace function pg_temp.ret_line(p_n text, p_transfer uuid, p_day integer) returns uuid
language plpgsql as $$
begin
  perform pg_temp.lines(p_n, pg_temp.d(p_day), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(p_transfer))), null,
    pg_temp.after(p_day));
  return pg_temp.ln(p_n);
end $$;
-- Martin's double_payout advances still open (their entry not reversed), as their amounts
create or replace function pg_temp.adv_open() returns jsonb language sql as $$
  select coalesce(jsonb_agg(a.amount_minor order by a.created_at), '[]') from public.client_advance a
  where a.client_organization_id = '00000000-0000-0000-0000-0000000000a1' and a.cause = 'double_payout'
    and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id) $$;
-- a line's first proposal's parts as [kind, the part's transfer is p_transfer, the other transfer the sheet names
-- besides it is p_other (null when it names none)]
create or replace function pg_temp.ret_parts(p_line uuid, p_transfer uuid, p_other uuid) returns jsonb
language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(p ->> 'kind', (p ->> 'transfer_id')::uuid = p_transfer,
                                              coalesce(p ->> 'closes_end_to_end_id', p ->> 'returned_end_to_end_id')
                                                = pg_temp.e2e(p_other))
                            order by (p ->> 'n')::integer), '[]')
  from jsonb_array_elements(pg_temp.pv(p_line, pg_temp.prop(p_line)) -> 'parts') p $$;
grant execute on all functions in schema pg_temp to authenticated;

-- (private.remittance_run_paid_on) counts a batch line booked as the payouts of several of its PmtInf's members, and a
-- transfer's return known from the bookings and the statement details (private.transfer_return_known) — never only from
-- the line's own end-to-end id.
-- An imported camt.053 of the dedicated account holding one credit line, of kind return, of an entry the bank kept
-- unsplit: its details of ours p_details ({id, direction, amount_minor}, as the parser stores them), its PmtInfId p_pmt
-- (our lot: the parser then keeps no original id) and its original id p_orig (else the parser's first RMT id of the
-- details), booked on the p_day-th business day, produced the morning after
create or replace function pg_temp.uret(p_n text, p_day integer, p_amount bigint, p_details jsonb,
                                        p_pmt text default null, p_orig text default null) returns uuid
language plpgsql as $$
declare s uuid := ('e3000000-0000-0000-0000-0000000000' || p_n)::uuid; v uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = pg_temp.after(p_day) where id = s;
  insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, payment_info_id,
                                       original_end_to_end_id, batch_entry_ref, unsplit_ours, unsplit_details,
                                       unsplit_detail_count)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), s, 1, 't:' || s || '1', 'credit', p_amount, 'EUR',
          pg_temp.d(p_day), 'return', p_pmt, p_orig, 'E-' || s, jsonb_array_length(p_details), p_details,
          jsonb_array_length(p_details))
  returning id into v;
  update public.bank_statement set status = 'imported', from_date = pg_temp.d(p_day), to_date = pg_temp.d(p_day),
    opening_booked_minor = 0, counts = '{}', finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object(
      'from_date', pg_temp.d(p_day), 'to_date', pg_temp.d(p_day), 'covers_from', pg_temp.d(p_day),
      'covers_to', pg_temp.d(p_day), 'opening_minor', '0', 'closing_minor', null,
      'created_at', pg_temp.after(p_day)))
  where id = s;
  return v;
end $$;
-- one credit detail of ours: a transfer coming back at its amount
create or replace function pg_temp.cdet(p_transfer uuid) returns jsonb language sql as $$
  select jsonb_build_object('id', t.end_to_end_id, 'direction', 'credit', 'amount_minor', t.amount_minor::text)
  from public.bank_transfer t where t.id = p_transfer $$;
create or replace function pg_temp.pmt_of(p_transfer uuid) returns text language sql as $$
  select i.pmt_inf_id from public.transfer_file_item i where i.transfer_id = p_transfer $$;
-- the lot state: ld2_prefix's, the re-issues y and yl executed as one batch line of F2's PmtInf (583 840: the bank

-- and the nightly booked branch all read it.
-- the k-th business day of the timeline as 'dk' (pg_temp.d's inverse), 'null', or 'other'
create or replace function pg_temp.dk(p_date date) returns text language sql as $$
  select coalesce((select 'd' || k from generate_series(0, 17) k where pg_temp.d(k) = p_date),
                  case when p_date is null then 'null' else 'other' end) $$;
-- a credit returning transfer p_transfer that the bank did not flag as a return: from Martin's payout IBAN, our RMT id
-- as its own end-to-end id, of the kind the import gives it (private.bank_line_refined_kind: client_transfer_in), on
-- the p_day-th business day, in statement p_n produced the morning after; its line
create or replace function pg_temp.ctin(p_n text, p_transfer uuid, p_day integer) returns uuid language plpgsql as $$
begin
  perform pg_temp.lines(p_n, pg_temp.d(p_day), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'e2e', pg_temp.e2e(p_transfer), 'iban', pg_temp.martin_iban(),
                       'kind', private.bank_line_refined_kind('debtor_credit', 'credit', pg_temp.e2e(p_transfer), null,
                                                              null, pg_temp.martin_iban(), array[pg_temp.own_iban()],
                                                              array[pg_temp.martin_iban(), pg_temp.lilas_iban()]))),
    null, pg_temp.after(p_day));
  return pg_temp.ln(p_n);
end $$;

-- the events in date order, executions first on a date, numbered (o)
create or replace function pg_temp.pc_ev(p_ev jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_agg(x.v || jsonb_build_object('o', x.o) order by x.o), '[]')
  from (select v, row_number() over (order by (v ->> 'd')::integer, v ->> 'k', ord) as o
        from jsonb_array_elements(p_ev) with ordinality a (v, ord)) x $$;
create or replace function pg_temp.pc(p_key text, p_ev jsonb) returns jsonb language plpgsql as $$
declare
  v_ev jsonb := pg_temp.pc_ev(p_ev); e jsonb; v_simple jsonb := '[]'; v_lines jsonb := '{}'; v_no integer := 0;
  v_i integer := 0; v_l uuid; v_first text; v_out jsonb := '[]'; v_none jsonb := '[]'; v_left jsonb; v_o text;
  v_job jsonb; v_p jsonb;
begin
  perform pg_temp.lp_prefix(p_key);
  perform pg_temp.handed_out('f2', p_key || '-g2', 2);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0)
  where id in (pg_temp.v('m0'), pg_temp.v('y'), pg_temp.v('l0'), pg_temp.v('yl'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(4), deadline = pg_temp.d(6)
  where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  for e in select * from jsonb_array_elements(v_ev) loop
    v_i := v_i + 1;
    if e ->> 's' in ('det', 'udet', 'ulot') then
      v_l := case e ->> 's'
        when 'det' then pg_temp.uline('a' || v_i, pg_temp.d((e ->> 'd')::integer), 164050,
                                      jsonb_build_array(pg_temp.det(pg_temp.v('m0'))), null, 50, null, null, null,
                                      pg_temp.after((e ->> 'd')::integer))
        when 'udet' then pg_temp.uret('a' || v_i, (e ->> 'd')::integer, 164000,
                                      jsonb_build_array(pg_temp.cdet(pg_temp.v(case e ->> 'm' when 'x' then 'm0'
                                                                                               else 'y' end))))
        else pg_temp.uret('a' || v_i, (e ->> 'd')::integer, 583840,
                          jsonb_build_array(pg_temp.cdet(pg_temp.v('y')), pg_temp.cdet(pg_temp.v('yl'))),
                          pg_temp.pmt_of(pg_temp.v('y'))) end;
      v_lines := v_lines || jsonb_build_object(e ->> 'o', v_l);
    else
      v_no := v_no + 1;
      v_lines := v_lines || jsonb_build_object(e ->> 'o', 'c3:' || v_no);
      v_simple := v_simple || jsonb_build_array(case
        when e ->> 'k' = 'e' and e ->> 's' = 'lot' then
          jsonb_build_object('amount', 583840, 'pmt_inf', pg_temp.pmt_of(pg_temp.v('y')))
        when e ->> 'k' = 'e' and e ->> 's' = 'dup' then
          jsonb_build_object('amount', 164000, 'kind', 'suspected_duplicate',
                             'e2e', pg_temp.e2e(pg_temp.v(case e ->> 'm' when 'x' then 'm0' else 'y' end)))
        when e ->> 'k' = 'e' then
          jsonb_build_object('amount', 164000,
                             'e2e', pg_temp.e2e(pg_temp.v(case e ->> 'm' when 'x' then 'm0' else 'y' end)))
        when e ->> 's' = 'own' then
          jsonb_build_object('dir', 'credit', 'amount', 164000,
                             'orig_e2e', pg_temp.e2e(pg_temp.v(case e ->> 'm' when 'x' then 'm0' else 'y' end)))
        when e ->> 's' = 'ctin' then
          jsonb_build_object('dir', 'credit', 'amount', 164000, 'iban', pg_temp.martin_iban(),
                             'kind', 'client_transfer_in',
                             'e2e', pg_temp.e2e(pg_temp.v(case e ->> 'm' when 'x' then 'm0' else 'y' end)))
        when e ->> 's' = 'lotc' then
          jsonb_build_object('dir', 'credit', 'amount', 164000, 'pmt_inf', pg_temp.pmt_of(pg_temp.v('y')))
        else jsonb_build_object('dir', 'credit', 'amount', 164000, 'iban', pg_temp.martin_iban()) end
        || jsonb_build_object('day', pg_temp.d((e ->> 'd')::integer)));
    end if;
  end loop;
  if jsonb_array_length(v_simple) > 0 then
    perform pg_temp.lines('c3', pg_temp.d(9), v_simple, pg_temp.d(2), pg_temp.after(9));
  end if;
  -- each event's line id
  select jsonb_object_agg(k, case when l.v #>> '{}' like 'c3:%'
                                  then to_jsonb(pg_temp.ln('c3', split_part(l.v #>> '{}', ':', 2)::integer))
                                  else l.v end) into v_lines
  from jsonb_each(v_lines) l (k, v);
  -- the import: y's first execution, the run's payout
  select e2.v ->> 'o' into v_first from jsonb_array_elements(v_ev) e2 (v)
  where e2.v ->> 'm' = 'y' and e2.v ->> 'k' = 'e' order by (e2.v ->> 'o')::integer limit 1;
  v_job := pg_temp.book(case when (select e3.v ->> 's' from jsonb_array_elements(v_ev) e3 (v)
                                   where e3.v ->> 'o' = v_first) = 'lot'
                             then jsonb_build_array(
                                    jsonb_build_object('line', v_lines ->> v_first, 'kind', 'payout',
                                                       'transfer', pg_temp.v('yl')),
                                    jsonb_build_object('line', v_lines ->> v_first, 'kind', 'payout',
                                                       'transfer', pg_temp.v('y')))
                             else jsonb_build_array(jsonb_build_object('line', v_lines ->> v_first, 'kind', 'payout',
                                                                       'transfer', pg_temp.v('y'))) end);
  -- ops: every other line as proposed, in date order; a line « Comptabiliser… » proposes nothing for yet (its refusal
  -- says what to book first: debit_pending) taken up again on the next pass, until a pass books nothing more
  v_none := (select coalesce(jsonb_agg((x.v ->> 'o')::integer order by (x.v ->> 'o')::integer), '[]')
             from jsonb_array_elements(v_ev) x (v) where x.v ->> 'o' <> v_first);
  loop
    v_left := '[]';
    for e in select * from jsonb_array_elements(v_none) loop
      v_l := (v_lines ->> (e #>> '{}'))::uuid;
      v_p := pg_temp.prop(v_l);
      if v_p is null then
        v_left := v_left || e;
        continue;
      end if;
      v_o := pg_temp.bkx(v_l, v_p);
      if v_o <> 'ok' then
        v_out := v_out || jsonb_build_array(jsonb_build_array((e #>> '{}')::integer, v_o));
      end if;
    end loop;
    exit when v_left = v_none;
    v_none := v_left;
  end loop;
  perform pg_temp.lines('c9', private.paris_today(), '[]');
  insert into t select p_key || 'c', pg_temp.chk(private.paris_today());
  return jsonb_build_object('row', jsonb_array_length(pg_temp.breaches('r1')) > 0,
    'paid', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))), 'unbooked', v_none,
    'why', (select coalesce(jsonb_agg(jsonb_build_array(x, pg_temp.op((v_lines ->> (x #>> '{}'))::uuid) ->> 'refusal')),
                            '[]')
            from jsonb_array_elements(v_none) x),
    'refused', v_out,
    'stands', exists (select 1 from public.bank_line_booking k
                      where k.transfer_id in (pg_temp.v('m0'), pg_temp.v('y')) and k.kind = 'payout'
                        and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id)),
    'dirty', to_jsonb(pg_temp.dirty()));
end $$;
-- the rule, written here independently: the business day from which the run's client was paid and stayed paid, or
-- null — per transfer (x, y) its events in date order (executions first on a date), a return with nothing outstanding
-- undoing nothing, the transfer paid from the first day from which its count stays at one or more; the run from the
-- earliest such day. Not counted: a return without our references (noref: COMPLIANCE CPCE-08's default), a lot credit
-- left unbooked (p_skip: it names no member), and, as the import's booking sees the statement (p_at_booking), any lot
-- credit (none is booked yet)
create or replace function pg_temp.pc_rule(p_ev jsonb, p_skip jsonb default '[]', p_at_booking boolean default false)
returns integer language plpgsql as $$
declare m text; e record; n integer; f integer; best integer;
begin
  foreach m in array array['x', 'y'] loop
    n := 0; f := null;
    for e in select (a.v ->> 'd')::integer as d, a.v ->> 'k' as k
             from jsonb_array_elements(pg_temp.pc_ev(p_ev)) a (v)
             where a.v ->> 'm' = m and a.v ->> 's' not in ('noref', 'dup')
               and not (a.v ->> 's' = 'lotc' and (p_at_booking or p_skip @> to_jsonb((a.v ->> 'o')::integer)))
             order by (a.v ->> 'o')::integer loop
      n := greatest(n + case e.k when 'e' then 1 else -1 end, 0);
      if n = 0 then f := null; elsif f is null then f := e.d; end if;
    end loop;
    if n >= 1 then best := least(best, f); end if;
  end loop;
  return best;
end $$;
-- a case run (switch on, rolled back) against the rule: [] when they agree, else what differs. The paid date is the
-- rule's (P). The row: the import's booking of y judged the rows with the statement as it was then (B, the run's
-- payout's date when no copy stayed); the nightly check judges a booked run again at P once a return of its chain is
-- on the statements, while the run's payout stands (one that came back leaves its sums' rows to the queue) — a row iff
-- B is after L, or the payout stands and P is after L. Every line booked as proposed, but a return « Comptabiliser… »
-- refuses for what it is (left to the support): the partner of a copy closed by another's return, sent as an entry
-- kept unsplit (transfer_cancelled: ADR-0014 round 2's open low), a return dated before the copy it would close
-- (return_before_debit)
create or replace function pg_temp.pc_check(p_key text, p_ev jsonb) returns jsonb language plpgsql as $$
declare v jsonb; r jsonb; v_p integer; v_b integer; v_row boolean;
begin
  begin
    update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
    v := pg_temp.pc(p_key, p_ev);
    raise exception 'case rolled back' using errcode = 'TR001';
  exception when sqlstate 'TR001' then
    null;
  end;
  v_p := pg_temp.pc_rule(p_ev, v -> 'unbooked');
  v_b := coalesce(pg_temp.pc_rule(p_ev, v -> 'unbooked', true),
                  (select min((a.ev ->> 'd')::integer) from jsonb_array_elements(p_ev) a (ev)
                   where a.ev ->> 'm' = 'y' and a.ev ->> 'k' = 'e'));
  v_row := v_b > 4 or ((v ->> 'stands')::boolean and v_p > 4);
  r := jsonb_build_object('paid', coalesce('d' || v_p, 'null'), 'row', coalesce(v_row, false));
  return case when v ->> 'paid' = r ->> 'paid' and v -> 'row' = r -> 'row' and v -> 'refused' = '[]'
                   and v -> 'dirty' = '[]'
                   and not exists (select 1 from jsonb_array_elements(v -> 'why') w
                                   cross join lateral (select a.ev from jsonb_array_elements(pg_temp.pc_ev(p_ev)) a (ev)
                                                       where a.ev ->> 'o' = w ->> 0) a
                                   where (a.ev ->> 'k' = 'e' and a.ev ->> 's' <> 'dup')
                                      or (a.ev ->> 'k' = 'r'
                                          and coalesce(w ->> 1, 'none') not in ('transfer_cancelled',
                                                                                'return_before_debit')))
              then '[]'::jsonb
              else jsonb_build_array(jsonb_build_object('case', p_key, 'events', p_ev, 'got', v, 'rule', r)) end;
end $$;
-- random interleavings (seeded): 2–4 executions (x under its own id or as a detail of ours, y under its own id; y once at
-- least), 0–3 returns, each of a transfer with an execution not yet returned by its day (own, ctin or udet; a lot credit
-- for y as well), all within d2 … d9
create or replace function pg_temp.pc_gen() returns jsonb language plpgsql as $$
declare
  v jsonb := '[]'; n_e integer := 2 + floor(random() * 3)::integer; n_r integer := floor(random() * 4)::integer;
  i integer; m text; d integer; ys integer := 0; tries integer; ok boolean; s text;
begin
  for i in 1 .. n_e loop
    m := case when random() < 0.5 then 'x' else 'y' end;
    if i = n_e and ys = 0 then m := 'y'; end if;
    if m = 'y' then ys := ys + 1; end if;
    v := v || jsonb_build_object('m', m, 'k', 'e', 'd', 2 + floor(random() * 7)::integer,
                                 's', case when m = 'x' and random() < 0.3 then 'det' else 'own' end);
  end loop;
  for i in 1 .. n_r loop
    tries := 0; ok := false;
    while not ok and tries < 20 loop
      tries := tries + 1;
      m := case when random() < 0.5 then 'x' else 'y' end;
      d := 2 + floor(random() * 8)::integer;
      -- an execution of m by d not yet returned by then
      ok := (select count(*) filter (where a.v ->> 'k' = 'e') - count(*) filter (where a.v ->> 'k' = 'r')
             from jsonb_array_elements(v) a (v) where a.v ->> 'm' = m and (a.v ->> 'd')::integer <= d) > 0
            and not exists (select 1 from jsonb_array_elements(v) a (v)
                            where a.v ->> 'm' = m and a.v ->> 'k' = 'r' and (a.v ->> 'd')::integer > d);
    end loop;
    continue when not ok;
    s := (array['own', 'ctin', 'udet', 'lotc'])[1 + floor(random() * case m when 'y' then 4 else 3 end)::integer];
    v := v || jsonb_build_object('m', m, 'k', 'r', 'd', d, 's', s);
  end loop;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;



-- 6b-3b part 1's helpers -------------------------------------------------------------------------------------------
create or replace function pg_temp.k(p_key text) returns text language sql as $$ select 'k6b3b1-' || p_key $$;
-- ri8's state before its statement (040's pg_temp.ld2_prefix without its lines): F1 downloaded on d(0) and cancelled
-- whole on evidence, Martin's payout x (m0) re-issued as y, filed in F2, downloaded on d(2); x's and y's requested
-- execution date set back to d(0) (unless p_x_requested is false: x keeps the date of its approval, ahead of the
-- timeline); Martin's line held to L = d(4), its deadline d(6)
create or replace function pg_temp.chain_prefix(p_key text, p_x_requested boolean default true) returns void
language plpgsql as $$
begin
  perform pg_temp.lp_prefix(p_key);
  perform pg_temp.handed_out('f2', p_key || '-g2', 2);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0)
  where id = pg_temp.v('y') or (p_x_requested and id = pg_temp.v('m0'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(4), deadline = pg_temp.d(6)
  where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
end $$;
-- a camt.053 of the dedicated account covering d(p_from) … d(p_to), produced by the bank the morning after d(p_to),
-- imported now (whatever the order the statements arrive in), holding p_lines (pg_temp.lines' shapes)
create or replace function pg_temp.st(p_n text, p_from integer, p_to integer, p_lines jsonb default '[]') returns uuid
language sql as $$ select pg_temp.lines(p_n, pg_temp.d(p_to), p_lines, pg_temp.d(p_from), pg_temp.after(p_to)) $$;
-- a debit of p_transfer under its own RMT id on the p_day-th business day
create or replace function pg_temp.own(p_transfer uuid, p_day integer) returns jsonb language sql as $$
  select jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(p_transfer), 'day', pg_temp.d(p_day)) $$;
-- the debit job's booking of y's own debit as the run's payout (emulated as 040 does: its pure rule's row, then the SQL
-- re-check and posting); the number of payouts booked
create or replace function pg_temp.import_y(p_line uuid) returns integer language sql as $$
  select (pg_temp.book(jsonb_build_array(jsonb_build_object('line', p_line, 'kind', 'payout',
                                                            'transfer', pg_temp.v('y')))) ->> 'payouts')::integer $$;
-- the nightly check of today (keyed p_key in t), then Martin's run's R124-6 rows
create or replace function pg_temp.nightly(p_key text) returns jsonb language plpgsql as $$
begin
  insert into t select p_key, pg_temp.chk(private.paris_today());
  return pg_temp.breaches('r1');
end $$;
-- the sheet's word on a payout part of p_transfer on p_line: « late latest-execution-date » (the preview's late flag)
create or replace function pg_temp.late_of(p_line uuid, p_transfer uuid) returns text language sql as $$
  select (p ->> 'late') || ' ' || pg_temp.dk((p ->> 'latest_execution_date')::date)
  from (select pg_temp.pv(p_line, jsonb_build_array(pg_temp.pt('payout', p_transfer, 164000))) -> 'parts' -> 0 p) x $$;
-- the ledger and funds invariants with today's statement imported (its closing not given: the fixture's closing of
-- today predates the debits of these scenarios)
create or replace function pg_temp.clean(p_n text) returns jsonb language plpgsql as $$
begin
  perform pg_temp.lines(p_n, private.paris_today(), '[]');
  return to_jsonb(pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;


-- booking-rows-skip-chain-coverage-and-waiting-lines (ADR-0014 « Open after round 4 », « M2c-6b-3b part 1 »; CPCE-08) --
-- The re-issue's own debit booked as its run's payout writes no R124-6 row for a run whose chain holds another transfer
-- unless the paying account's statements cover [least(e0, L), L] and no other transfer of the chain handed out has a
-- line that may be its debit by L and is not yet counted by the chain's rule; the nightly check's booked branch judges
-- such a run once both hold, at the chain's paid date (rows append-only, written once).
-- S1: the statement holding x's on-time debit (d2 … d4) is imported after the re-issue's (d5 … d7, y after L on d6):
-- no row at y's booking, none at the nightly check while d2 … d4 are on no statement, none once the earlier statement
-- shows x on time (d3) — before x's line is booked and after. The control (p_x false): the earlier statement shows no
-- debit of x — the nightly check writes the row at y's date. The preview of y's line said « late » only once the
-- booking could write the row (s1c: the earlier statement first, the row at the booking)
create or replace function pg_temp.s1(p_key text, p_x boolean) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_ly uuid; v_lx uuid;
begin
  perform pg_temp.chain_prefix(p_key);
  perform pg_temp.st('c3', 5, 7, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 6)));
  v_ly := pg_temp.ln('c3');
  v := v || jsonb_build_object('preview', pg_temp.late_of(v_ly, pg_temp.v('y')), 'job', pg_temp.import_y(v_ly));
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'), 'nightly0', pg_temp.nightly(p_key || 'a'));
  perform pg_temp.st('c4', 2, 4, case when p_x then jsonb_build_array(pg_temp.own(pg_temp.v('m0'), 3)) else '[]' end);
  v := v || jsonb_build_object('nightly1', pg_temp.nightly(p_key || 'b'));
  if p_x then
    v_lx := pg_temp.ln('c4');
    v := v || jsonb_build_object('x_req', pg_temp.req(v_lx), 'x', pg_temp.bkx(v_lx, pg_temp.prop(v_lx)));
    v := v || jsonb_build_object('nightly2', pg_temp.nightly(p_key || 'c'));
  end if;
  return v || jsonb_build_object('paid', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))),
    'run', (select jsonb_build_array(r.status, pg_temp.dk(r.booked_on)) from public.remittance_run r
            where r.id = pg_temp.v('r1')),
    'dirty', pg_temp.clean('c9'));
end $$;
create or replace function pg_temp.sc_s1x() returns jsonb language sql as $$ select pg_temp.s1('s1x', true) $$;
create or replace function pg_temp.sc_s1n() returns jsonb language sql as $$ select pg_temp.s1('s1n', false) $$;
create or replace function pg_temp.sc_s1c() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_ly uuid;
begin
  perform pg_temp.chain_prefix('s1c');
  perform pg_temp.st('c4', 2, 4);
  perform pg_temp.st('c3', 5, 7, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 6)));
  v_ly := pg_temp.ln('c3');
  v := v || jsonb_build_object('preview', pg_temp.late_of(v_ly, pg_temp.v('y')), 'job', pg_temp.import_y(v_ly));
  return v || jsonb_build_object('booked', pg_temp.breaches('r1'), 'nightly', pg_temp.nightly('s1ca'),
                                 'dirty', pg_temp.clean('c9'));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 's1x', pg_temp.isolated('sc_s1x');
insert into j select 's1n', pg_temp.isolated('sc_s1n');
insert into j select 's1c', pg_temp.isolated('sc_s1c');
select results_eq($$ select v ->> 'preview', (v ->> 'job')::int, v -> 'booked', v -> 'nightly0', v -> 'nightly1',
                            v -> 'x_req', v ->> 'x', v -> 'nightly2', v ->> 'paid', v -> 'run', v -> 'dirty'
                     from j where k = 's1x' $$,
  $$ values ('false null'::text, 1, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[["unplanned_payout", "164000"]]'::jsonb,
             'ok'::text, '[]'::jsonb, 'd3'::text, '["booked", "d6"]'::jsonb, '[]'::jsonb) $$,
  'S1 (CPCE-08): the statement holding x''s on-time debit imported after the re-issue''s — no row at y''s booking (d2 … d4 on no statement), none at the nightly check before it arrives, none once it shows x on time, before x''s line is booked and after');
select results_eq($$ select v ->> 'preview', (v ->> 'job')::int, v -> 'booked', v -> 'nightly0', v -> 'nightly1',
                            v ->> 'paid', v -> 'dirty' from j where k = 's1n' $$,
  $$ values ('false null'::text, 1, '[]'::jsonb, '[]'::jsonb, '["none"]'::jsonb, 'd6'::text, '[]'::jsonb) $$,
  'S1''s control: the earlier statement shows no debit of x — the nightly check writes the row at y''s date (the client was paid after L), once');
select results_eq($$ select v ->> 'preview', (v ->> 'job')::int, v -> 'booked', v -> 'nightly', v -> 'dirty'
                     from j where k = 's1c' $$,
  $$ values ('true d4'::text, 1, '["none"]'::jsonb, '["none"]'::jsonb, '[]'::jsonb) $$,
  'S1''s control at the booking: the earlier statement first (nothing of x) — the sheet says late, y''s booking writes the row, the nightly check nothing more');

-- S2c: x's on-time execution (d3) on a line without our references (to Martin's IBAN: rule 3b's only candidate is x),
-- y's own debit after L (d6), one statement (d2 … d7): no row at y's booking nor at the nightly check while that line
-- waits (it offers « Virement hors reversement » of x), none once ops book it. The controls: the line, without any IBAN,
-- classified not ours (a payer's return, « Lier ») — the nightly check writes the row at y's date; a line that may be x's
-- debit but offers no booking of it (a batch line of x's PmtInf no subset makes, batch_ambiguous), past the bound days —
-- the row « bloqué : débit possible non comptabilisé »
create or replace function pg_temp.s2(p_key text, p_mode text) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_lx uuid; v_ly uuid;
begin
  perform pg_temp.chain_prefix(p_key);
  if p_mode = 'classified' then
    perform pg_temp.collect('81', 164000, pg_temp.d(1), false);
  end if;
  perform pg_temp.st('c3', 2, 7, jsonb_build_array(
    case p_mode when 'book' then jsonb_build_object('amount', 164000, 'iban', pg_temp.martin_iban(), 'day', pg_temp.d(3))
                when 'classified' then jsonb_build_object('amount', 164000, 'day', pg_temp.d(3))
                else jsonb_build_object('amount', 1000, 'pmt_inf', pg_temp.pmt('f1', 1), 'day', pg_temp.d(3)) end,
    pg_temp.own(pg_temp.v('y'), 6)));
  v_lx := pg_temp.ln('c3', 1); v_ly := pg_temp.ln('c3', 2);
  v := v || jsonb_build_object('preview', pg_temp.late_of(v_ly, pg_temp.v('y')), 'job', pg_temp.import_y(v_ly));
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'),
    'supp', private.transfer_debit_suppression(pg_temp.v('m0'), pg_temp.d(4), private.paris_today()),
    'nightly0', pg_temp.nightly(p_key || 'a'));
  if p_mode = 'book' then
    v := v || jsonb_build_object('x_req', pg_temp.req(v_lx), 'x', pg_temp.bkx(v_lx, pg_temp.prop(v_lx)));
  elsif p_mode = 'classified' then
    v := v || jsonb_build_object('x', pg_temp.try('01', format(
      $q$ select public.link_debit(%L, %L, 'return', %L, null, '164000', 'retour du payeur (test)') ->> 'kind' $q$,
      pg_temp.k(p_key || '-link'), v_lx, pg_temp.pay('81'))));
  end if;
  v := v || jsonb_build_object('nightly1', pg_temp.nightly(p_key || 'b'));
  return v || jsonb_build_object('paid', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))),
                                 'dirty', pg_temp.clean('c9'));
end $$;
create or replace function pg_temp.sc_s2c() returns jsonb language sql as $$ select pg_temp.s2('s2c', 'book') $$;
create or replace function pg_temp.sc_s2l() returns jsonb language sql as $$ select pg_temp.s2('s2l', 'classified') $$;
create or replace function pg_temp.sc_s2e() returns jsonb language sql as $$ select pg_temp.s2('s2e', 'expired') $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 's2c', pg_temp.isolated('sc_s2c');
insert into j select 's2l', pg_temp.isolated('sc_s2l');
insert into j select 's2e', pg_temp.isolated('sc_s2e');
select results_eq($$ select v ->> 'preview', (v ->> 'job')::int, v -> 'booked', v ->> 'supp', v -> 'nightly0',
                            v -> 'x_req', v ->> 'x', v -> 'nightly1', v ->> 'paid', v -> 'dirty'
                     from j where k = 's2c' $$,
  $$ values ('false null'::text, 1, '[]'::jsonb, 'waiting'::text, '[]'::jsonb,
             '[["unplanned_payout", "164000"]]'::jsonb, 'ok'::text, '[]'::jsonb, 'd3'::text, '[]'::jsonb) $$,
  'S2c (CPCE-08): x''s on-time execution on a line without our references waits — no row at y''s booking nor at the nightly check while it waits, none once ops book it « Virement hors reversement » of x (the client was paid on time)');
select results_eq($$ select k, v -> 'booked', v ->> 'supp', v -> 'nightly0', v ->> 'x', v -> 'nightly1', v ->> 'paid',
                            v -> 'dirty' from j where k in ('s2l', 's2e') order by k desc $$,
  $$ values ('s2l'::text, '[]'::jsonb, 'waiting'::text, '[]'::jsonb, 'return'::text, '["none"]'::jsonb, 'd6'::text,
             '[]'::jsonb),
            ('s2e', '[]', 'expired', '["debit_unbooked"]', null, '["debit_unbooked"]', 'd6', '[]') $$,
  'S2c''s controls: the waiting line classified not ours (a payer''s return) — the nightly check writes the row at y''s date; a line that may be x''s debit and offers no booking of it, past the bound days — the row « bloqué : débit possible non comptabilisé »');

-- S3 (the late predecessor booked after L, chain {y ordered, x}): x executed late under its own RMT id (d6) on a
-- statement of d5 … d7 while d2 … d4 are on none — its booking (« Comptabiliser… ») writes no row, nor the nightly
-- check; once they are covered, the nightly check writes it. S3c: covered first — the booking writes it
create or replace function pg_temp.s3(p_key text, p_covered boolean) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid;
begin
  perform pg_temp.lp_prefix(p_key);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0) where id in (pg_temp.v('m0'), pg_temp.v('y'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(4), deadline = pg_temp.d(6)
  where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  if p_covered then
    perform pg_temp.st('c4', 2, 4);
  end if;
  perform pg_temp.st('c3', 5, 7, jsonb_build_array(pg_temp.own(pg_temp.v('m0'), 6)));
  v_l := pg_temp.ln('c3');
  v := v || jsonb_build_object('lp', pg_temp.op(v_l) #>> '{proposals,0,parts,0,late_predecessor}',
                               'preview', pg_temp.late_of(v_l, pg_temp.v('m0')), 'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'), 'nightly0', pg_temp.nightly(p_key || 'a'),
                               'y', pg_temp.status(pg_temp.v('y')), 'run', pg_temp.run_status('r1'));
  if not p_covered then
    perform pg_temp.st('c4', 2, 4);
    v := v || jsonb_build_object('nightly1', pg_temp.nightly(p_key || 'b'));
  end if;
  return v || jsonb_build_object('dirty', pg_temp.clean('c9'));
end $$;
create or replace function pg_temp.sc_s3() returns jsonb language sql as $$ select pg_temp.s3('s3', false) $$;
create or replace function pg_temp.sc_s3c() returns jsonb language sql as $$ select pg_temp.s3('s3c', true) $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 's3', pg_temp.isolated('sc_s3');
insert into j select 's3c', pg_temp.isolated('sc_s3c');
select results_eq($$ select k, v ->> 'lp', v ->> 'preview', v ->> 'book', v -> 'booked', v -> 'nightly0', v -> 'nightly1',
                            v ->> 'y', v ->> 'run', v -> 'dirty' from j where k in ('s3', 's3c') order by k $$,
  $$ values ('s3'::text, 'true'::text, 'false null'::text, 'ok'::text, '[]'::jsonb, '[]'::jsonb, '["none"]'::jsonb,
             'cancelled'::text, 'booked'::text, '[]'::jsonb),
            ('s3c', 'true', 'true d4', 'ok', '["none"]', '["none"]', null, 'cancelled', 'booked', '[]') $$,
  'S3 (CPCE-08): the late predecessor booked after L while d2 … d4 are on no statement — no row at its booking nor at the nightly check, the row once they are covered; covered first, the booking writes it (the sheet says late then only)');


-- The three mutants round 4 left alive (ADR-0014 « M2c-6b-3a-2 review fixes », round 4) -----------------------------
-- (a) a line naming a transfer of the chain booked or linked otherwise is none of its executions (forged: no command
-- books or links such a line otherwise — classes E, B, U; link_debit_guard): x's own-id debit on time (d3) linked as a
-- payer's return, y's after L (d6) booked by the import — the client was paid by y, late: the row at the booking
create or replace function pg_temp.sc_m1() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_lx uuid; v_ly uuid;
begin
  perform pg_temp.chain_prefix('m1');
  perform pg_temp.collect('82', 164000, pg_temp.d(1), false);
  perform pg_temp.st('c3', 2, 7, jsonb_build_array(pg_temp.own(pg_temp.v('m0'), 3), pg_temp.own(pg_temp.v('y'), 6)));
  v_lx := pg_temp.ln('c3', 1); v_ly := pg_temp.ln('c3', 2);
  alter table public.bank_debit_link disable trigger bank_debit_link_guard;
  insert into public.bank_debit_link (bank_transaction_id, organization_id, bank_account_id, kind, payment_id,
                                      cash_entry_id, method, reason, decided_by)
  values (v_lx, '00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), 'return', pg_temp.pay('82'),
          (select e.id from public.ledger_entry e where e.idempotency_key like 'cash_in:e1000000-%82:%'), 'ops',
          'forgé (test)', '10000000-0000-0000-0000-000000000001');
  alter table public.bank_debit_link enable always trigger bank_debit_link_guard;
  v := v || jsonb_build_object('job', pg_temp.import_y(v_ly));
  return v || jsonb_build_object('booked', pg_temp.breaches('r1'),
                                 'paid', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))));
end $$;
-- (b) the line previewed as a payout is counted as its execution: y's execution on time (d3) on a line without our
-- references (rule 3b's only candidate y), x's own-id debit after L (d6) — the sheet says on time, as the booking writes
-- no row (the client was paid by y on d3)
create or replace function pg_temp.sc_m2() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_lx uuid; v_ly uuid;
begin
  perform pg_temp.chain_prefix('m2');
  perform pg_temp.st('c3', 2, 7, jsonb_build_array(
    jsonb_build_object('amount', 164000, 'iban', pg_temp.martin_iban(), 'day', pg_temp.d(3)),
    pg_temp.own(pg_temp.v('m0'), 6)));
  v_ly := pg_temp.ln('c3', 1); v_lx := pg_temp.ln('c3', 2);
  v := v || jsonb_build_object('req', pg_temp.req(v_ly), 'preview', pg_temp.late_of(v_ly, pg_temp.v('y')),
                               'book', pg_temp.bkx(v_ly, pg_temp.prop(v_ly)));
  return v || jsonb_build_object('booked', pg_temp.breaches('r1'), 'nightly', pg_temp.nightly('m2a'));
end $$;
-- (c) a debit dated before its transfer's requested execution date is not its execution (forged dates: the bank never
-- executes one of our transfers before the date we asked): x keeps the date of its approval, its own-id debit dated d3
-- before it, y's after L (d6) booked by the import — the row at the booking
create or replace function pg_temp.sc_m3() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_ly uuid;
begin
  perform pg_temp.chain_prefix('m3', false);
  perform pg_temp.st('c3', 2, 7, jsonb_build_array(pg_temp.own(pg_temp.v('m0'), 3), pg_temp.own(pg_temp.v('y'), 6)));
  v_ly := pg_temp.ln('c3', 2);
  v := v || jsonb_build_object('before', (select requested_execution_date > pg_temp.d(3) from public.bank_transfer
                                          where id = pg_temp.v('m0')),
                               'job', pg_temp.import_y(v_ly));
  return v || jsonb_build_object('booked', pg_temp.breaches('r1'),
                                 'paid', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'm1', pg_temp.isolated('sc_m1');
insert into j select 'm2', pg_temp.isolated('sc_m2');
insert into j select 'm3', pg_temp.isolated('sc_m3');
select results_eq($$ select (v ->> 'job')::int, v -> 'booked', v ->> 'paid' from j where k = 'm1' $$,
  $$ values (1, '["none"]'::jsonb, 'd6'::text) $$,
  'round 4''s survivor (a), forged: a line naming x linked otherwise (a payer''s return) is no execution of x — the client was paid by y after L: the row at y''s booking');
select results_eq($$ select v -> 'req', v ->> 'preview', v ->> 'book', v -> 'booked', v -> 'nightly' from j where k = 'm2' $$,
  $$ values ('[["payout", "164000"]]'::jsonb, 'false null'::text, 'ok'::text, '[]'::jsonb, '[]'::jsonb) $$,
  'round 4''s survivor (b): y''s on-time execution without our references, previewed as its payout, is counted — the sheet says on time (x''s own debit after L notwithstanding), and the booking writes no row');
select results_eq($$ select (v ->> 'before')::boolean, (v ->> 'job')::int, v -> 'booked', v ->> 'paid' from j where k = 'm3' $$,
  $$ values (true, 1, '["none"]'::jsonb, 'd6'::text) $$,
  'round 4''s survivor (c), forged dates: x''s own-id debit dated before x''s requested execution date is not its execution — the row at y''s booking');


-- The property over time (CPCE-08): 040's r4 property (pg_temp.pc) with the case's lines arriving on several statements,
-- in an order of their own — each statement covering the business days p_ranges gives it ([from, to], in arrival
-- order; together d2 … d9), produced the morning after its last day, imported in turn. When a statement holds an
-- execution of y and the run is not booked yet, the import books the earliest of them as the run's payout (as the debit
-- job does: its own RMT id, or F2's batch line with Lilas' yl), and from then on the nightly check runs after each
-- statement; once every statement is in, ops book every other line as « Comptabiliser… » proposes (in date order, a line
-- refused debit_pending taken up again), then the nightly check. The case returns pg_temp.pc's facts, the statement the
-- run was booked at (booked_at, its index) and the event booked (booked, its o).
create or replace function pg_temp.pc2(p_key text, p_ev jsonb, p_ranges jsonb) returns jsonb language plpgsql as $$
declare
  v_ev jsonb := pg_temp.pc_ev(p_ev); e jsonb; rg jsonb; v_ri integer := 0; v_simple jsonb; v_no integer;
  v_lines jsonb := '{}'; v_here jsonb; v_i integer := 0; v_l uuid; v_booked text; v_at integer; v_first jsonb;
  v_out jsonb := '[]'; v_none jsonb; v_left jsonb; v_o text; v_p jsonb; v_s text;
begin
  perform pg_temp.lp_prefix(p_key);
  perform pg_temp.handed_out('f2', p_key || '-g2', 2);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0)
  where id in (pg_temp.v('m0'), pg_temp.v('y'), pg_temp.v('l0'), pg_temp.v('yl'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(4), deadline = pg_temp.d(6)
  where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  for rg in select * from jsonb_array_elements(p_ranges) loop
    v_ri := v_ri + 1;
    v_s := 'd' || v_ri;
    v_simple := '[]'; v_no := 0; v_here := '{}';
    for e in select x.v from jsonb_array_elements(v_ev) x (v)
             where (x.v ->> 'd')::integer between (rg ->> 0)::integer and (rg ->> 1)::integer
             order by (x.v ->> 'o')::integer loop
      v_i := v_i + 1;
      if e ->> 's' in ('det', 'udet', 'ulot') then
        v_l := case e ->> 's'
          when 'det' then pg_temp.uline('a' || v_i, pg_temp.d((e ->> 'd')::integer), 164050,
                                        jsonb_build_array(pg_temp.det(pg_temp.v('m0'))), null, 50, null, null, null,
                                        pg_temp.after((e ->> 'd')::integer))
          when 'udet' then pg_temp.uret('a' || v_i, (e ->> 'd')::integer, 164000,
                                        jsonb_build_array(pg_temp.cdet(pg_temp.v(case e ->> 'm' when 'x' then 'm0'
                                                                                                 else 'y' end))))
          else pg_temp.uret('a' || v_i, (e ->> 'd')::integer, 583840,
                            jsonb_build_array(pg_temp.cdet(pg_temp.v('y')), pg_temp.cdet(pg_temp.v('yl'))),
                            pg_temp.pmt_of(pg_temp.v('y'))) end;
        v_here := v_here || jsonb_build_object(e ->> 'o', v_l);
      else
        v_no := v_no + 1;
        v_here := v_here || jsonb_build_object(e ->> 'o', v_s || ':' || v_no);
        v_simple := v_simple || jsonb_build_array(case
          when e ->> 'k' = 'e' and e ->> 's' = 'lot' then
            jsonb_build_object('amount', 583840, 'pmt_inf', pg_temp.pmt_of(pg_temp.v('y')))
          when e ->> 'k' = 'e' then
            jsonb_build_object('amount', 164000,
                               'e2e', pg_temp.e2e(pg_temp.v(case e ->> 'm' when 'x' then 'm0' else 'y' end)))
          when e ->> 's' = 'own' then
            jsonb_build_object('dir', 'credit', 'amount', 164000,
                               'orig_e2e', pg_temp.e2e(pg_temp.v(case e ->> 'm' when 'x' then 'm0' else 'y' end)))
          when e ->> 's' = 'ctin' then
            jsonb_build_object('dir', 'credit', 'amount', 164000, 'iban', pg_temp.martin_iban(),
                               'kind', 'client_transfer_in',
                               'e2e', pg_temp.e2e(pg_temp.v(case e ->> 'm' when 'x' then 'm0' else 'y' end)))
          when e ->> 's' = 'lotc' then
            jsonb_build_object('dir', 'credit', 'amount', 164000, 'pmt_inf', pg_temp.pmt_of(pg_temp.v('y')))
          else jsonb_build_object('dir', 'credit', 'amount', 164000, 'iban', pg_temp.martin_iban()) end
          || jsonb_build_object('day', pg_temp.d((e ->> 'd')::integer)));
      end if;
    end loop;
    perform pg_temp.lines(v_s, pg_temp.d((rg ->> 1)::integer), v_simple, pg_temp.d((rg ->> 0)::integer),
                          pg_temp.after((rg ->> 1)::integer));
    select coalesce(jsonb_object_agg(k, case when l.v #>> '{}' like v_s || ':%'
                                             then to_jsonb(pg_temp.ln(v_s, split_part(l.v #>> '{}', ':', 2)::integer))
                                             else l.v end), '{}') into v_here
    from jsonb_each(v_here) l (k, v);
    v_lines := v_lines || v_here;
    -- the import: the earliest execution of y this statement brings, while the run waits for its payout
    if v_booked is null then
      select x.v into v_first from jsonb_array_elements(v_ev) x (v)
      where x.v ->> 'm' = 'y' and x.v ->> 'k' = 'e' and v_here ? (x.v ->> 'o')
      order by (x.v ->> 'o')::integer limit 1;
      if v_first is not null then
        v_booked := v_first ->> 'o';
        v_at := v_ri;
        perform pg_temp.book(case when v_first ->> 's' = 'lot'
                                  then jsonb_build_array(
                                         jsonb_build_object('line', v_lines ->> v_booked, 'kind', 'payout',
                                                            'transfer', pg_temp.v('yl')),
                                         jsonb_build_object('line', v_lines ->> v_booked, 'kind', 'payout',
                                                            'transfer', pg_temp.v('y')))
                                  else jsonb_build_array(jsonb_build_object('line', v_lines ->> v_booked,
                                                                            'kind', 'payout',
                                                                            'transfer', pg_temp.v('y'))) end);
      end if;
    end if;
    if v_booked is not null then
      insert into t select p_key || 'n' || v_ri, pg_temp.chk(private.paris_today());
    end if;
  end loop;
  -- ops: every other line as proposed, in date order (as pg_temp.pc)
  v_none := (select coalesce(jsonb_agg((x.v ->> 'o')::integer order by (x.v ->> 'o')::integer), '[]')
             from jsonb_array_elements(v_ev) x (v) where x.v ->> 'o' <> v_booked);
  loop
    v_left := '[]';
    for e in select * from jsonb_array_elements(v_none) loop
      v_l := (v_lines ->> (e #>> '{}'))::uuid;
      v_p := pg_temp.prop(v_l);
      if v_p is null then
        v_left := v_left || e;
        continue;
      end if;
      v_o := pg_temp.bkx(v_l, v_p);
      if v_o <> 'ok' then
        v_out := v_out || jsonb_build_array(jsonb_build_array((e #>> '{}')::integer, v_o));
      end if;
    end loop;
    exit when v_left = v_none;
    v_none := v_left;
  end loop;
  perform pg_temp.lines('c9', private.paris_today(), '[]');
  insert into t select p_key || 'c', pg_temp.chk(private.paris_today());
  return jsonb_build_object('row', jsonb_array_length(pg_temp.breaches('r1')) > 0,
    'rows', jsonb_array_length(pg_temp.breaches('r1')),
    'paid', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))), 'unbooked', v_none,
    'why', (select coalesce(jsonb_agg(jsonb_build_array(x, pg_temp.op((v_lines ->> (x #>> '{}'))::uuid) ->> 'refusal')),
                            '[]')
            from jsonb_array_elements(v_none) x),
    'refused', v_out, 'booked', v_booked::integer, 'booked_at', v_at,
    'stands', exists (select 1 from public.bank_line_booking k
                      where k.transfer_id in (pg_temp.v('m0'), pg_temp.v('y')) and k.kind = 'payout'
                        and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id)),
    'dirty', to_jsonb(pg_temp.dirty()));
end $$;
-- the rule over time, written here independently: whether the run ends with its R124-6 row. The statements that had
-- arrived by the k-th cover L when every business day of d2 … d4 (d0 … d1: the cancellation's evidence statement) is in
-- one of their ranges. The booking writes the row when they did at its statement and the paid date the booking saw (B:
-- pg_temp.pc_rule over the events then on the statements, no lot credit booked; the booked line's day when no copy
-- stayed) is after L (d4); each nightly check from the booking's statement on writes it when they did and the paid date
-- then (no lot credit booked: ops book at the end) is after L, the run's payout standing (it is until ops book); the last
-- one, every line booked as proposed, with the paid date of every event but the lot credits left unbooked and the
-- payout as it then stands. A row iff one of them wrote it — append-only, once.
create or replace function pg_temp.pc2_rule(p_ev jsonb, p_ranges jsonb, p_got jsonb) returns jsonb language plpgsql as $$
declare
  v_ev jsonb := pg_temp.pc_ev(p_ev); v_n integer := jsonb_array_length(p_ranges); v_at integer := (p_got ->> 'booked_at')::integer;
  k integer; v_cov boolean; v_seen jsonb; v_p integer; v_row boolean := false; v_final integer;
begin
  for k in v_at .. v_n loop
    -- the events on the statements arrived by the k-th
    select coalesce(jsonb_agg(x.v), '[]') into v_seen
    from jsonb_array_elements(v_ev) x (v)
    where exists (select 1 from jsonb_array_elements(p_ranges) with ordinality r (g, i)
                  where r.i <= k and (x.v ->> 'd')::integer between (r.g ->> 0)::integer and (r.g ->> 1)::integer);
    v_cov := (select bool_and(exists (select 1 from jsonb_array_elements(p_ranges) with ordinality r (g, i)
                                      where r.i <= k and d between (r.g ->> 0)::integer and (r.g ->> 1)::integer))
              from generate_series(2, 4) d);
    v_p := pg_temp.pc_rule(v_seen, '[]', true);
    if k = v_at then
      v_p := coalesce(v_p, (select (x.v ->> 'd')::integer from jsonb_array_elements(v_ev) x (v)
                            where x.v ->> 'o' = p_got ->> 'booked'));
    end if;
    v_row := v_row or coalesce(v_cov and v_p > 4, false);
  end loop;
  v_final := pg_temp.pc_rule(p_ev, p_got -> 'unbooked');
  v_row := v_row or coalesce((p_got ->> 'stands')::boolean and v_final > 4, false);
  return jsonb_build_object('paid', coalesce('d' || v_final, 'null'), 'row', v_row);
end $$;
-- a case run (switch on, rolled back) against the rule over time: [] when they agree, else what differs (as
-- pg_temp.pc_check: every line booked as proposed but the two returns « Comptabiliser… » refuses for what they are, the
-- invariants clean, at most one row)
create or replace function pg_temp.pc2_check(p_key text, p_ev jsonb, p_ranges jsonb) returns jsonb language plpgsql as $$
declare v jsonb; r jsonb;
begin
  begin
    update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
    v := pg_temp.pc2(p_key, p_ev, p_ranges);
    raise exception 'case rolled back' using errcode = 'TR001';
  exception when sqlstate 'TR001' then
    null;
  end;
  r := pg_temp.pc2_rule(p_ev, p_ranges, v);
  return case when v ->> 'paid' = r ->> 'paid' and v -> 'row' = r -> 'row' and (v ->> 'rows')::integer <= 1
                   and v -> 'refused' = '[]' and v -> 'dirty' = '[]'
                   and not exists (select 1 from jsonb_array_elements(v -> 'why') w
                                   cross join lateral (select a.ev from jsonb_array_elements(pg_temp.pc_ev(p_ev)) a (ev)
                                                       where a.ev ->> 'o' = w ->> 0) a
                                   where a.ev ->> 'k' = 'e'
                                      or coalesce(w ->> 1, 'none') not in ('transfer_cancelled', 'return_before_debit'))
              then '[]'::jsonb
              else jsonb_build_array(jsonb_build_object('case', p_key, 'events', p_ev, 'ranges', p_ranges, 'got', v,
                                                        'rule', r)) end;
end $$;
-- random statements over d2 … d9 (seeded): one or two cuts, in a random arrival order
create or replace function pg_temp.pc2_ranges() returns jsonb language plpgsql as $$
declare c1 integer := 2 + floor(random() * 7)::integer; c2 integer; v jsonb;
begin
  if random() < 0.5 then
    v := jsonb_build_array(jsonb_build_array(2, c1), jsonb_build_array(c1 + 1, 9));
  else
    c2 := least(8, c1 + 1 + floor(random() * (8 - c1))::integer);
    v := jsonb_build_array(jsonb_build_array(2, c1), jsonb_build_array(c1 + 1, c2), jsonb_build_array(c2 + 1, 9));
  end if;
  -- drop an empty range (a cut at 9), then shuffle
  select jsonb_agg(g order by random()) into v from jsonb_array_elements(v) g
  where (g ->> 0)::integer <= (g ->> 1)::integer;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
create temp table pc2_cases (k text primary key, ev jsonb, ranges jsonb) on commit drop;
-- the verifiers' shapes (040's, the suspected duplicate aside: its line is a debit that may be x's, which holds the
-- row back until its decision — S2c's rule), the later statement first (d5 … d9, then d2 … d4: S1's order), and S1
-- itself (x on time imported after y)
insert into pc2_cases
select c.k, c.ev::jsonb, '[[5, 9], [2, 4]]'::jsonb from (values
  ('n2b', '[{"m":"x","k":"e","s":"own","d":2},{"m":"x","k":"r","s":"own","d":3},{"m":"x","k":"e","s":"own","d":4},
            {"m":"y","k":"e","s":"own","d":6}]'),
  ('n2d', '[{"m":"x","k":"e","s":"own","d":2},{"m":"x","k":"e","s":"own","d":3},{"m":"x","k":"r","s":"own","d":5},
            {"m":"y","k":"e","s":"own","d":6}]'),
  ('n2f', '[{"m":"x","k":"e","s":"own","d":2},{"m":"y","k":"e","s":"own","d":5},{"m":"y","k":"e","s":"own","d":6},
            {"m":"y","k":"r","s":"own","d":7},{"m":"x","k":"r","s":"own","d":8}]'),
  ('fr1', '[{"m":"y","k":"e","s":"own","d":3},{"m":"x","k":"e","s":"own","d":6},{"m":"y","k":"e","s":"own","d":7},
            {"m":"y","k":"r","s":"own","d":8}]'),
  ('ldl1', '[{"m":"x","k":"e","s":"own","d":3},{"m":"y","k":"e","s":"lot","d":6},{"m":"x","k":"r","s":"own","d":8}]'),
  ('ldl2', '[{"m":"x","k":"e","s":"own","d":3},{"m":"y","k":"e","s":"lot","d":6},{"m":"y","k":"r","s":"own","d":8}]'),
  ('rs2', '[{"m":"x","k":"e","s":"own","d":3},{"m":"y","k":"e","s":"own","d":6},{"m":"x","k":"r","s":"udet","d":8}]'),
  ('rs5', '[{"m":"y","k":"e","s":"lot","d":3},{"m":"x","k":"e","s":"own","d":6},{"m":"y","k":"r","s":"ulot","d":8}]'),
  ('rs6', '[{"m":"y","k":"e","s":"own","d":3},{"m":"x","k":"e","s":"own","d":6},{"m":"y","k":"r","s":"lotc","d":8}]'),
  ('rs7', '[{"m":"x","k":"e","s":"own","d":3},{"m":"y","k":"e","s":"own","d":6},{"m":"x","k":"r","s":"noref","d":8}]'),
  ('rs8', '[{"m":"x","k":"e","s":"det","d":3},{"m":"y","k":"e","s":"own","d":6}]'),
  ('n1a', '[{"m":"x","k":"e","s":"own","d":3},{"m":"y","k":"e","s":"own","d":6},{"m":"x","k":"r","s":"ctin","d":8}]'),
  ('n1b', '[{"m":"x","k":"e","s":"own","d":6},{"m":"y","k":"e","s":"own","d":3},{"m":"y","k":"r","s":"ctin","d":8}]'),
  ('lifo', '[{"m":"x","k":"e","s":"own","d":3},{"m":"x","k":"e","s":"own","d":6},{"m":"y","k":"e","s":"own","d":7},
             {"m":"x","k":"r","s":"own","d":8}]'),
  ('early', '[{"m":"x","k":"r","s":"own","d":3},{"m":"x","k":"e","s":"own","d":5},{"m":"y","k":"e","s":"own","d":6}]'),
  ('s1', '[{"m":"x","k":"e","s":"own","d":3},{"m":"y","k":"e","s":"own","d":6}]'),
  ('s1n', '[{"m":"y","k":"e","s":"own","d":6}]')) c (k, ev);
select setseed(0.5151);
insert into pc2_cases select 'rnd' || lpad(g::text, 2, '0'), pg_temp.pc_gen(), pg_temp.pc2_ranges()
from generate_series(1, 12) g;
select is((select jsonb_agg(c.k || ':' || (pg_temp.pc2_rule(c.ev, c.ranges,
                                             jsonb_build_object('booked_at', 1, 'booked', 0, 'unbooked', '[]',
                                                                'stands', true)) ->> 'row')
                            order by c.k)
           from pc2_cases c where c.k in ('s1', 's1n', 'n2b', 'ldl2')),
  '["ldl2:false", "n2b:false", "s1:false", "s1n:true"]'::jsonb,
  'the rule over time (pg_temp.pc2_rule) on S1 and three shapes, y booked at the first statement: a row iff the client was paid after L by what the statements show once they cover L');
select is((select coalesce(jsonb_agg(x order by c.k), '[]') from pc2_cases c
           cross join lateral jsonb_array_elements(pg_temp.pc2_check(c.k, c.ev, c.ranges)) x where c.k not like 'rnd%'),
  '[]'::jsonb,
  'property over time (CPCE-08): the verifiers'' shapes and S1 with the later statement imported first — the R124-6 row and the paid date agree with the rule over time, at most one row, every line booked as proposed, the invariants clean');
select is((select coalesce(jsonb_agg(x order by c.k), '[]') from pc2_cases c
           cross join lateral jsonb_array_elements(pg_temp.pc2_check(c.k, c.ev, c.ranges)) x where c.k like 'rnd%'),
  '[]'::jsonb,
  'property over time (CPCE-08): 12 seeded interleavings on two or three statements arriving in a random order — the R124-6 row and the paid date agree with the rule over time');

select is(private.switch_on('downloaded_file_cancellation'), false,
  'the switch is off as the migration leaves it (6b-3b switches it on)');

select * from finish();
rollback;
