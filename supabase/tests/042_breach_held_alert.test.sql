-- M2c-6b-3b part 2, the held-rows alert (ADR-0014 « M2c-6b-3b part 2 »; COMPLIANCE CPCE-08; founder question 2 of
-- « M2c-6b-3b part 1 », its default). The switch STAYS OFF in the migration: each scenario below turns
-- private.feature_switch 'downloaded_file_cancellation' on inside its own subtransaction (pg_temp.isolated: rolled back
-- at its end, its outcomes kept), as 6b-3b part 3's one-line migration will, and the file asserts at its end that the
-- switch is off. What each scenario pins — « remittance_breach_held », an alert of the nightly checks (an operational
-- safeguard, not a legal deadline): every booked run whose payout chain holds another transfer, its payout standing,
-- with a line late at the chain's paid date (one month for a delay that cannot be met) and no R124-6 row because the
-- holds of private.remittance_chain_holds fail — the paying account's statements not covering [least(e0, L), L] (the
-- days named; a break in the balances said), or a line that may be another transfer's debit waiting (the line named) —
-- gets one alert, subject the run, from each check that leaves it held; it resolves itself (the next check raises none)
-- once the row is written, or once the statements show the client paid on time:
--   * H1 (not covered: the earlier statement missing), its two ends (the row written; the client shown paid on time),
--     the next night, and the tenant (the other servicer's check raises none, its ops manager reads none);
--   * H2 (a possible debit waiting, offering x's booking), its ends (classified not ours: the row; booked as x: paid on
--     time); H2y (a young possible debit offering none); HB (a break in the balances, every day covered);
--   * none where the row is written (at the booking, or « bloqué : débit possible non comptabilisé » at the nightly
--     check), for a line of a delay that cannot be met before its one-month date (and one after it: held), for a run
--     whose payout came back (its sums' rows the queue's), nor for a run whose chain holds no other transfer (forged:
--     its row taken out);
--   * the functions' settings and privileges, private.bank_line_booking_guard() under enable_seqscan off (PR #38's known
--     limit; its integration test in worker/tests/test_debit_bookings_batch_rules_integration.py);
--   * the switch off at the end.
-- The fixtures and helpers are 041's (themselves 040's: F1 downloaded on d(0) and cancelled whole on evidence, Martin's
-- payout x re-issued as y, L = d(4)).
begin;
select plan(20);





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



-- 6b-3b part 2's helpers -------------------------------------------------------------------------------------------
create or replace function pg_temp.k(p_key text) returns text language sql as $$ select 'k6b3b2-' || p_key $$;
-- the transfer a line named in the alert may be the debit of, by its end-to-end id: x (m0), y, l0, or the id itself
create or replace function pg_temp.tk(p_e2e text) returns text language sql as $$
  select case when p_e2e = pg_temp.e2e(pg_temp.v('m0')) then 'x' when p_e2e = pg_temp.e2e(pg_temp.v('y')) then 'y'
              when p_e2e = pg_temp.e2e(pg_temp.v('l0')) then 'l0' else coalesce(p_e2e, 'null') end $$;
-- the « remittance_breach_held » results of the check run keyed p_key in t, each as [its run (r1, r2, r3), severity,
-- subject type, count, amount, the days no statement covers (as dk), the break in the balances, the waiting lines as
-- [day, amount, the transfer it may be]], in the runs' order
create or replace function pg_temp.alerts(p_key text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(
           coalesce((select t.k from t where t.v = r.subject_id and t.k in ('r1', 'r2', 'r3')), 'other'),
           r.severity, r.subject_type, r.count, r.amount_minor::text,
           (select coalesce(jsonb_agg(pg_temp.dk(d.v::date) order by d.o), '[]')
            from jsonb_array_elements_text(r.details -> 'uncovered_days') with ordinality d (v, o)),
           r.details -> 'balance_break',
           (select coalesce(jsonb_agg(jsonb_build_array(pg_temp.dk((w.v ->> 'booking_date')::date),
                                                        w.v ->> 'amount_minor', pg_temp.tk(w.v ->> 'end_to_end_id'))
                                      order by w.o), '[]')
            from jsonb_array_elements(r.details -> 'waiting') with ordinality w (v, o)))
         order by r.subject_id), '[]')
  from public.payment_check_result r
  where r.run_id = pg_temp.v(p_key) and r.code = 'remittance_breach_held' $$;
-- the alert's other facts, each against what it states: its run's number, the date the run is judged at, the earliest
-- date its held lines are held to, Q14's bound, the held lines' ledger entries, the oldest days, the currency, the
-- number of days and of lines that hold them
create or replace function pg_temp.alert_facts(p_key text) returns jsonb language sql as $$
  select jsonb_build_object(
    'number', r.details ->> 'number' = (select x.number from public.remittance_run x where x.id = r.subject_id),
    'judged_on', pg_temp.dk((r.details ->> 'judged_on')::date),
    'earliest', pg_temp.dk((r.details ->> 'earliest_latest_execution_date')::date),
    'bound_days', r.details -> 'bound_days',
    'ids', r.details -> 'ids' = (select jsonb_agg(l.ledger_entry_id order by l.ledger_entry_id)
                                 from public.remittance_line l
                                 where l.run_id = r.subject_id and not l.released and l.amount_minor > 0),
    'oldest', r.oldest_days = private.paris_today() - (r.details ->> 'earliest_latest_execution_date')::date,
    'currency', r.currency, 'uncovered_count', r.details -> 'uncovered_count',
    'waiting_count', r.details -> 'waiting_count')
  from public.payment_check_result r
  where r.run_id = pg_temp.v(p_key) and r.code = 'remittance_breach_held' $$;
-- the other servicer's check run of today: its « remittance_breach_held » results; then what the servicer's ops manager
-- (01) and the other servicer's (05) read of them (RLS)
create or replace function pg_temp.tenant() returns jsonb language plpgsql as $$
declare v uuid; v_bb integer; v_01 integer; v_05 integer;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000bb')
  returning id into v;
  perform private.run_remittance_checks(v, '00000000-0000-0000-0000-0000000000bb', private.paris_today());
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  select count(*) into v_bb from public.payment_check_result r where r.run_id = v and r.code = 'remittance_breach_held';
  perform pg_temp.as_user('01');
  set local role authenticated;
  select count(*) into v_01 from public.payment_check_result r where r.code = 'remittance_breach_held';
  reset role;
  perform pg_temp.as_user('05');
  set local role authenticated;
  select count(*) into v_05 from public.payment_check_result r where r.code = 'remittance_breach_held';
  reset role;
  return jsonb_build_array(v_bb, v_01, v_05);
end $$;
-- a run's lines held to L = d(p_l), their deadline two business days later
create or replace function pg_temp.hold_to(p_run text, p_l integer) returns void language plpgsql as $$
begin
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(p_l), deadline = pg_temp.d(p_l + 2)
  where run_id = pg_temp.v(p_run);
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
end $$;
grant execute on all functions in schema pg_temp to authenticated;


-- H1 (not covered; CPCE-08): S1's shape — y's own debit after L (d6) booked by the import, the statement of d2 … d3 not
-- imported yet (d0 … d1 are, the cancellation's evidence; d4 … d7 the re-issue's): no row, and the nightly check raises
-- the alert on Martin's run naming d2 and d3, its only result of the kind — the other servicer's check raises none, its
-- ops manager reads none. Then the statement of d2 … d3: showing nothing of x (h1n), the row at y's date and the alert
-- gone; showing x's on-time debit (h1x), no row (the client paid on time) and the alert gone; neither back the next night
create or replace function pg_temp.h1(p_key text, p_x boolean) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_ly uuid;
begin
  perform pg_temp.chain_prefix(p_key);
  perform pg_temp.st('c3', 4, 7, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 6)));
  v_ly := pg_temp.ln('c3');
  v := v || jsonb_build_object('job', pg_temp.import_y(v_ly), 'booked', pg_temp.breaches('r1'),
                               'nightly0', pg_temp.nightly(p_key || 'a'));
  v := v || jsonb_build_object('alert0', pg_temp.alerts(p_key || 'a'), 'facts0', pg_temp.alert_facts(p_key || 'a'),
                               'tenant', pg_temp.tenant());
  perform pg_temp.st('c4', 2, 3, case when p_x then jsonb_build_array(pg_temp.own(pg_temp.v('m0'), 3)) else '[]' end);
  v := v || jsonb_build_object('nightly1', pg_temp.nightly(p_key || 'b'), 'alert1', pg_temp.alerts(p_key || 'b'));
  v := v || jsonb_build_object('nightly2', pg_temp.nightly(p_key || 'c'), 'alert2', pg_temp.alerts(p_key || 'c'));
  return v || jsonb_build_object('paid', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))),
                                 'dirty', pg_temp.clean('c9'));
end $$;
create or replace function pg_temp.sc_h1n() returns jsonb language sql as $$ select pg_temp.h1('h1n', false) $$;
create or replace function pg_temp.sc_h1x() returns jsonb language sql as $$ select pg_temp.h1('h1x', true) $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'h1n', pg_temp.isolated('sc_h1n');
insert into j select 'h1x', pg_temp.isolated('sc_h1x');
select results_eq($$ select (v ->> 'job')::int, v -> 'booked', v -> 'nightly0', v -> 'alert0', v -> 'tenant',
                            v -> 'nightly1', v -> 'alert1', v -> 'nightly2', v -> 'alert2', v ->> 'paid', v -> 'dirty'
                     from j where k = 'h1n' $$,
  $$ values (1, '[]'::jsonb, '[]'::jsonb,
             '[["r1", "alert", "remittance_run", 1, "200000", ["d2", "d3"], false, []]]'::jsonb, '[0, 1, 0]'::jsonb,
             '["none"]'::jsonb, '[]'::jsonb, '["none"]'::jsonb, '[]'::jsonb, 'd6'::text, '[]'::jsonb) $$,
  'H1 (CPCE-08): a booked chained run whose row the statements hold back (d2 … d3 on no statement) — the alert on the run names those days, the servicer''s own (the other servicer raises and reads none); once the statement shows nothing of x, the row at y''s date and the alert gone, the next night too');
select is((select v -> 'facts0' from j where k = 'h1n'),
  jsonb_build_object('number', true, 'judged_on', 'd6', 'earliest', 'd4', 'bound_days', 5, 'ids', true,
                     'oldest', true, 'currency', 'EUR', 'uncovered_count', 2, 'waiting_count', 0),
  'H1''s alert states its run''s number, the date the run is judged at (y''s), the date its lines are held to (L), Q14''s bound, the held lines'' entries, their age and currency, and how many days and lines hold them');
select results_eq($$ select v -> 'alert0', v -> 'nightly1', v -> 'alert1', v -> 'nightly2', v -> 'alert2', v ->> 'paid',
                            v -> 'dirty' from j where k = 'h1x' $$,
  $$ values ('[["r1", "alert", "remittance_run", 1, "200000", ["d2", "d3"], false, []]]'::jsonb, '[]'::jsonb,
             '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, 'd3'::text, '[]'::jsonb) $$,
  'H1''s other end: the statement shows x''s on-time debit — no row (the client was paid on time) and the alert gone, the next night too');

-- H2 (a possible debit waiting; CPCE-08): S2's shapes — x's on-time execution (d3) on a line without our references,
-- y's own debit after L (d6), one statement (d2 … d7): no row while that line waits (it offers x's booking), and the
-- alert names it (d3, 164 000, x; the line by its id, one line, no day). Then ops book it « Virement hors reversement » of x (h2c: paid on time, no row) or
-- classify it not ours (h2l: the row at y's date): the alert gone either way. A line that may be x's debit and offers no
-- booking of it, past the bound days (h2e): the row « bloqué : débit possible non comptabilisé », no alert
create or replace function pg_temp.h2(p_key text, p_mode text) returns jsonb language plpgsql as $$
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
  v := v || jsonb_build_object('job', pg_temp.import_y(v_ly), 'booked', pg_temp.breaches('r1'),
                               'nightly0', pg_temp.nightly(p_key || 'a'));
  v := v || jsonb_build_object('alert0', pg_temp.alerts(p_key || 'a'),
    'line', coalesce((select (r.details #>> '{waiting,0,line_id}')::uuid = v_lx
                             and r.details -> 'waiting_count' = '1' and r.details -> 'uncovered_count' = '0'
                      from public.payment_check_result r
                      where r.run_id = pg_temp.v(p_key || 'a') and r.code = 'remittance_breach_held'), false));
  if p_mode = 'book' then
    v := v || jsonb_build_object('x', pg_temp.bkx(v_lx, pg_temp.prop(v_lx)));
  elsif p_mode = 'classified' then
    v := v || jsonb_build_object('x', pg_temp.try('01', format(
      $q$ select public.link_debit(%L, %L, 'return', %L, null, '164000', 'retour du payeur (test)') ->> 'kind' $q$,
      pg_temp.k(p_key || '-link'), v_lx, pg_temp.pay('81'))));
  end if;
  v := v || jsonb_build_object('nightly1', pg_temp.nightly(p_key || 'b'), 'alert1', pg_temp.alerts(p_key || 'b'));
  return v || jsonb_build_object('paid', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))),
                                 'dirty', pg_temp.clean('c9'));
end $$;
create or replace function pg_temp.sc_h2c() returns jsonb language sql as $$ select pg_temp.h2('h2c', 'book') $$;
create or replace function pg_temp.sc_h2l() returns jsonb language sql as $$ select pg_temp.h2('h2l', 'classified') $$;
create or replace function pg_temp.sc_h2e() returns jsonb language sql as $$ select pg_temp.h2('h2e', 'expired') $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'h2c', pg_temp.isolated('sc_h2c');
insert into j select 'h2l', pg_temp.isolated('sc_h2l');
insert into j select 'h2e', pg_temp.isolated('sc_h2e');
select results_eq($$ select k, v -> 'booked', v -> 'nightly0', v -> 'alert0', (v ->> 'line')::boolean, v ->> 'x',
                            v -> 'nightly1', v -> 'alert1', v ->> 'paid', v -> 'dirty'
                     from j where k in ('h2c', 'h2l') order by k $$,
  $$ values ('h2c'::text, '[]'::jsonb, '[]'::jsonb,
             '[["r1", "alert", "remittance_run", 1, "200000", [], false, [["d3", "164000", "x"]]]]'::jsonb, true,
             'ok'::text, '[]'::jsonb, '[]'::jsonb, 'd3'::text, '[]'::jsonb),
            ('h2l', '[]', '[]', '[["r1", "alert", "remittance_run", 1, "200000", [], false, [["d3", "164000", "x"]]]]',
             true, 'return', '["none"]', '[]', 'd6', '[]') $$,
  'H2 (CPCE-08): a possible debit of x waiting holds the row — the alert on the run names that line; booked « Virement hors reversement » of x (paid on time: no row) or classified not ours (the row at y''s date), the alert is gone');

-- H2y (a young possible debit; CPCE-08): S2y's shape — L recent (d15), a batch line of x's PmtInf no subset makes (d14),
-- younger than the bound days and offering no booking of x, y's own debit after L (d16): no row, the alert names it.
-- HB (a break in the balances; CPCE-08): the statement of d2 … d3 closes at 0,01 € and the next (d4 … d7) opens at 0 —
-- every day is on a statement, but one is missing between them: no row, the alert names no day and says the break
create or replace function pg_temp.sc_h2y() returns jsonb language plpgsql as $$
declare v_ly uuid;
begin
  perform pg_temp.chain_prefix('h2y');
  perform pg_temp.hold_to('r1', 15);
  perform pg_temp.st('c3', 2, 16, jsonb_build_array(
    jsonb_build_object('amount', 1000, 'pmt_inf', pg_temp.pmt('f1', 1), 'day', pg_temp.d(14)),
    pg_temp.own(pg_temp.v('y'), 16)));
  v_ly := pg_temp.ln('c3', 2);
  return jsonb_build_object('job', pg_temp.import_y(v_ly), 'booked', pg_temp.breaches('r1'),
    'supp', private.transfer_debit_suppression(pg_temp.v('m0'), pg_temp.d(15), private.paris_today()),
    'nightly', pg_temp.nightly('h2ya'), 'alert', pg_temp.alerts('h2ya'));
end $$;
create or replace function pg_temp.sc_hb() returns jsonb language plpgsql as $$
declare v_ly uuid;
begin
  perform pg_temp.chain_prefix('hb');
  perform pg_temp.lines('c4', pg_temp.d(3), '[]', pg_temp.d(2), pg_temp.after(3), 'camt053', pg_temp.cf(), 1);
  perform pg_temp.st('c3', 4, 7, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 6)));
  v_ly := pg_temp.ln('c3');
  return jsonb_build_object('covers', jsonb_build_array(pg_temp.covers(0, 1), pg_temp.covers(2, 3),
                                                        pg_temp.covers(4, 4), pg_temp.covers(0, 4)),
    'job', pg_temp.import_y(v_ly), 'booked', pg_temp.breaches('r1'), 'nightly', pg_temp.nightly('hba'),
    'alert', pg_temp.alerts('hba'));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'h2y', pg_temp.isolated('sc_h2y');
insert into j select 'hb', pg_temp.isolated('sc_hb');
select results_eq($$ select (v ->> 'job')::int, v -> 'booked', v ->> 'supp', v -> 'nightly', v -> 'alert'
                     from j where k = 'h2y' $$,
  $$ values (1, '[]'::jsonb, 'waiting'::text, '[]'::jsonb,
             '[["r1", "alert", "remittance_run", 1, "200000", [], false, [["d14", "1000", "x"]]]]'::jsonb) $$,
  'H2y (CPCE-08, Q14''s rule): a possible debit of x younger than the bound days, offering no booking of it, holds the row — the alert names it');
select results_eq($$ select v -> 'covers', (v ->> 'job')::int, v -> 'booked', v -> 'nightly', v -> 'alert'
                     from j where k = 'hb' $$,
  $$ values ('[true, true, true, false]'::jsonb, 1, '[]'::jsonb, '[]'::jsonb,
             '[["r1", "alert", "remittance_run", 1, "200000", [], true, []]]'::jsonb) $$,
  'HB (CPCE-08): every day on a statement but the balances of two do not follow (a statement missing between them) — the row is held, the alert names no day and says the break');

-- None where the row is written (CPCE-08): at the booking (S1c: the earlier statement first, nothing of x), and at the
-- nightly check « bloqué : débit possible non comptabilisé » (h2e, above). Nor for a line whose delay cannot be met
-- before the one-month date of its collection (S5 with the statement of d2 … d4 missing: y's debit on d6 is on time,
-- whatever the statements) — but after it (d5) the row is held to that date and the alert names d2 … d4. Nor for a run
-- whose payout came back (S7: its sums' rows are the queue's), x's late debit on a statement of d6 only
create or replace function pg_temp.sc_h1c() returns jsonb language plpgsql as $$
declare v_ly uuid;
begin
  perform pg_temp.chain_prefix('h1c');
  perform pg_temp.st('c4', 2, 4);
  perform pg_temp.st('c3', 5, 7, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 6)));
  v_ly := pg_temp.ln('c3');
  return jsonb_build_object('job', pg_temp.import_y(v_ly), 'booked', pg_temp.breaches('r1'),
                            'nightly', pg_temp.nightly('h1ca'), 'alert', pg_temp.alerts('h1ca'));
end $$;
create or replace function pg_temp.h5(p_key text, p_month integer) returns jsonb language plpgsql as $$
declare v_ly uuid; v_e date;
begin
  perform pg_temp.chain_prefix(p_key);
  select min(e::date) into v_e from generate_series(pg_temp.d(0) - 70, pg_temp.d(0), interval '1 day') e
  where (select d.latest_execution_date from private.remittance_deadline_or_null(e::date, 30) d)
        >= pg_temp.d(p_month);
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set unmeetable = true, encaissement_date = v_e where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  perform pg_temp.st('c3', 5, 9, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 6)));
  v_ly := pg_temp.ln('c3');
  return jsonb_build_object('month', pg_temp.dk((select d.latest_execution_date
                                                 from private.remittance_deadline_or_null(v_e, 30) d)),
    'job', pg_temp.import_y(v_ly), 'booked', pg_temp.breaches('r1'), 'nightly', pg_temp.nightly(p_key || 'a'),
    'alert', pg_temp.alerts(p_key || 'a'));
end $$;
create or replace function pg_temp.sc_h5() returns jsonb language sql as $$ select pg_temp.h5('h5', 8) $$;
create or replace function pg_temp.sc_h5b() returns jsonb language sql as $$ select pg_temp.h5('h5b', 5) $$;
-- (tests-ui-3-unmeetable-boundary-untested) its one-month date the very date the run is judged at (d6): on time, as
-- private.remittance_chain_rows reads it (only a month date before the run's is late) — no row, no alert; nor once the
-- statement of d2 … d4 (nothing of x) covers the window the next night: the row a line paid on its date would
-- falsely get (private.remittance_chain_rows' own « before », pinned here too)
create or replace function pg_temp.sc_h5c() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  v := pg_temp.h5('h5c', 6);
  perform pg_temp.st('c4', 2, 4);
  v := v || jsonb_build_object('nightly1', pg_temp.nightly('h5cb'));
  return v || jsonb_build_object('alert1', pg_temp.alerts('h5cb'));
end $$;
create or replace function pg_temp.sc_h7() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_ly uuid; v_lr uuid;
begin
  perform pg_temp.chain_prefix('h7');
  perform pg_temp.st('c3', 2, 4, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 3)));
  v_ly := pg_temp.ln('c3');
  v := v || jsonb_build_object('job', pg_temp.import_y(v_ly));
  perform pg_temp.st('c4', 5, 5, jsonb_build_array(jsonb_build_object('dir', 'credit', 'amount', 164000,
                                                                      'orig_e2e', pg_temp.e2e(pg_temp.v('y')),
                                                                      'day', pg_temp.d(5))));
  v_lr := pg_temp.ln('c4');
  v := v || jsonb_build_object('ret', pg_temp.bkx(v_lr, pg_temp.prop(v_lr)));
  perform pg_temp.st('c5', 6, 6, jsonb_build_array(pg_temp.own(pg_temp.v('m0'), 6)));
  return v || jsonb_build_object('nightly', pg_temp.nightly('h7a'), 'alert', pg_temp.alerts('h7a'),
                                 'paid', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'h1c', pg_temp.isolated('sc_h1c');
insert into j select 'h5', pg_temp.isolated('sc_h5');
insert into j select 'h5b', pg_temp.isolated('sc_h5b');
insert into j select 'h5c', pg_temp.isolated('sc_h5c');
insert into j select 'h7', pg_temp.isolated('sc_h7');
select results_eq($$ select k, v -> 'booked', v -> 'nightly0', v -> 'alert0', v -> 'nightly1', v -> 'alert1'
                     from j where k = 'h2e'
                     union all
                     select k, v -> 'booked', v -> 'nightly', v -> 'alert', v -> 'nightly', v -> 'alert'
                     from j where k = 'h1c' $$,
  $$ values ('h2e'::text, '[]'::jsonb, '["debit_unbooked"]'::jsonb, '[]'::jsonb, '["debit_unbooked"]'::jsonb,
             '[]'::jsonb),
            ('h1c', '["none"]', '["none"]', '[]', '["none"]', '[]') $$,
  'no alert where the row is written: « bloqué : débit possible non comptabilisé » at the nightly check (a possible debit past the bound days offering none), or at the booking (the statements covering, nothing of x)');
select results_eq($$ select k, v ->> 'month', (v ->> 'job')::int, v -> 'booked', v -> 'nightly', v -> 'alert'
                     from j where k in ('h5', 'h5b', 'h5c') order by k $$,
  $$ values ('h5'::text, 'd8'::text, 1, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb),
            ('h5b', 'd5', 1, '[]', '[]',
             '[["r1", "alert", "remittance_run", 1, "200000", ["d2", "d3", "d4"], false, []]]'),
            ('h5c', 'd6', 1, '[]', '[]', '[]') $$,
  'a delay that cannot be met: y''s debit before the one-month date of the collection, or on it, is on time whatever the statements — no alert; after it, the row held to that date waits for d2 … d4, and the alert names them');
select is((select jsonb_build_array(v -> 'nightly1', v -> 'alert1') from j where k = 'h5c'), '[[], []]'::jsonb,
  'a delay that cannot be met, y''s debit on the one-month date of the collection: on time — no row and no alert once the statements cover every day either');
select results_eq($$ select (v ->> 'job')::int, v ->> 'ret', v -> 'nightly', v -> 'alert', v ->> 'paid'
                     from j where k = 'h7' $$,
  $$ values (1, 'ok'::text, '[]'::jsonb, '[]'::jsonb, 'd6'::text) $$,
  'no alert for a run whose payout came back (« Virement revenu » booked): the chain paid after L, but the run''s sums are owed again — their rows are the queue''s');

-- H3 (two dates, forged; CPCE-08): Martin's run given a second line (forged, the insert guard off: no command adds a
-- line to an approved run) of 10,00 € held to d1 — a day the cancellation's evidence covers — beside its line held to
-- d4: y's booking after L writes the row of the line held to d1 (its window [d0, d1] covered, nothing of x by then) and
-- holds the other (d2 … d3 on no statement): the alert counts and names the held line alone (1, 200 000), never the one
-- whose row is written
create or replace function pg_temp.sc_h3() returns jsonb language plpgsql as $$
declare v jsonb; v_ly uuid; v_e uuid;
begin
  perform pg_temp.chain_prefix('h3');
  select e.id into v_e from public.ledger_entry e
  where e.organization_id = '00000000-0000-0000-0000-0000000000aa' and e.idempotency_key = 'tf-owe-01';
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_insert_guard;
  insert into public.remittance_line
  select (jsonb_populate_record(null::public.remittance_line, to_jsonb(l) || jsonb_build_object(
            'line_no', l.line_no + 1, 'ledger_entry_id', v_e, 'payment_id', null, 'amount_minor', 1000,
            'commission_minor', 0, 'latest_execution_date', pg_temp.d(1), 'deadline', pg_temp.d(3)))).*
  from public.remittance_line l where l.run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_insert_guard;
  set constraints all deferred;
  perform pg_temp.st('c3', 4, 7, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 6)));
  v_ly := pg_temp.ln('c3');
  -- (each read in its own statement: a subquery does not see what a function its statement called wrote)
  v := jsonb_build_object('lines', (select count(*) from public.remittance_line where run_id = pg_temp.v('r1')),
                          'job', pg_temp.import_y(v_ly));
  v := v || jsonb_build_object('booked', (select coalesce(jsonb_agg(pg_temp.dk(b.latest_execution_date)), '[]')
                                          from public.remittance_deadline_breach b where b.run_id = pg_temp.v('r1')));
  v := v || jsonb_build_object('nightly', pg_temp.nightly('h3a'));
  return v || jsonb_build_object('alert', pg_temp.alerts('h3a'),
    'ids', (select r.details -> 'ids' = jsonb_build_array(
                     (select l.ledger_entry_id from public.remittance_line l
                      where l.run_id = pg_temp.v('r1') and l.ledger_entry_id <> v_e))
            from public.payment_check_result r
            where r.run_id = pg_temp.v('h3a') and r.code = 'remittance_breach_held'));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'h3', pg_temp.isolated('sc_h3');
select results_eq($$ select (v ->> 'lines')::int, (v ->> 'job')::int, v -> 'booked', v -> 'nightly', v -> 'alert',
                            (v ->> 'ids')::boolean from j where k = 'h3' $$,
  $$ values (2, 1, '["d1"]'::jsonb, '["none"]'::jsonb,
             '[["r1", "alert", "remittance_run", 1, "200000", ["d2", "d3"], false, []]]'::jsonb, true) $$,
  'H3 (forged, two dates): the line whose row is written (held to d1, covered) is not in the alert — it counts, sums and names the held line alone');

-- Review round 1 of part 2 (dt-1-uncovered-day-already-imported; CPCE-08): a day counts as covered only in a statement
-- produced after its end (private.statement_covers) — a camt.053 the bank produced during that very day (sdc: d2 … d3,
-- produced on d3 at 18:00), or a CSV ending on it (sdv: d2 … d3, uploaded the morning after: a CSV never covers its last
-- booking day), is imported yet proves nothing of it: the alert names d3 all the same, and its help asks for a statement
-- of that day established after its end (breach-held.test.ts), never for one « missing »
create or replace function pg_temp.sd(p_key text, p_format text) returns jsonb language plpgsql as $$
declare v jsonb; v_s uuid; v_ly uuid;
begin
  perform pg_temp.chain_prefix(p_key);
  v_s := pg_temp.lines('c4', pg_temp.d(3), '[]', pg_temp.d(2),
                       case when p_format = 'camt053' then (pg_temp.d(3) + time '18:00') at time zone 'Europe/Paris'
                            else pg_temp.after(3) end, p_format);
  perform pg_temp.st('c3', 4, 7, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 6)));
  v_ly := pg_temp.ln('c3');
  v := jsonb_build_object(
    'imported', (select jsonb_build_array(s.format, s.status, pg_temp.dk(s.from_date), pg_temp.dk(s.to_date))
                 from public.bank_statement s where s.id = v_s),
    'covers', jsonb_build_array(pg_temp.covers(2, 2), pg_temp.covers(3, 3)),
    'job', pg_temp.import_y(v_ly));
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'), 'nightly', pg_temp.nightly(p_key || 'a'));
  return v || jsonb_build_object('alert', pg_temp.alerts(p_key || 'a'));
end $$;
create or replace function pg_temp.sc_sdc() returns jsonb language sql as $$ select pg_temp.sd('sdc', 'camt053') $$;
create or replace function pg_temp.sc_sdv() returns jsonb language sql as $$ select pg_temp.sd('sdv', 'csv') $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'sdc', pg_temp.isolated('sc_sdc');
insert into j select 'sdv', pg_temp.isolated('sc_sdv');
select results_eq($$ select k, v -> 'imported', v -> 'covers', (v ->> 'job')::int, v -> 'booked', v -> 'nightly',
                            v -> 'alert' from j where k in ('sdc', 'sdv') order by k $$,
  $$ values ('sdc'::text, '["camt053", "imported", "d2", "d3"]'::jsonb, '[true, false]'::jsonb, 1, '[]'::jsonb,
             '[]'::jsonb, '[["r1", "alert", "remittance_run", 1, "200000", ["d3"], false, []]]'::jsonb),
            ('sdv', '["csv", "imported", "d2", "d3"]', '[true, false]', 1, '[]', '[]',
             '[["r1", "alert", "remittance_run", 1, "200000", ["d3"], false, []]]') $$,
  'a statement of the day imported but produced during it (camt.053), or ending on it (CSV), covers nothing of it: the alert names that day all the same (its help asks for a statement established after the day''s end)');

-- (tests-ui-2-multi-date-aggregates-untested; CPCE-08) H4 (two dates, forged as H3): Martin's run held to d15 and given
-- a second line of 10,00 € held to d10, y's debit after L (d16) on a statement of d16 alone: both lines held — d2 … d10
-- and d2 … d15 on no statement, two windows that overlap. The alert counts and sums both (2, 201 000), names each
-- uncovered day once (d2 … d15) and counts them once each (14, not 9 + 14), its age the older date's (today − d10) and
-- its earliest date held to d10
create or replace function pg_temp.sc_h4() returns jsonb language plpgsql as $$
declare v jsonb; v_ly uuid; v_e uuid;
begin
  perform pg_temp.chain_prefix('h4');
  perform pg_temp.hold_to('r1', 15);
  select e.id into v_e from public.ledger_entry e
  where e.organization_id = '00000000-0000-0000-0000-0000000000aa' and e.idempotency_key = 'tf-owe-01';
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_insert_guard;
  insert into public.remittance_line
  select (jsonb_populate_record(null::public.remittance_line, to_jsonb(l) || jsonb_build_object(
            'line_no', l.line_no + 1, 'ledger_entry_id', v_e, 'payment_id', null, 'amount_minor', 1000,
            'commission_minor', 0, 'latest_execution_date', pg_temp.d(10), 'deadline', pg_temp.d(12)))).*
  from public.remittance_line l where l.run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_insert_guard;
  set constraints all deferred;
  perform pg_temp.st('c3', 16, 16, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 16)));
  v_ly := pg_temp.ln('c3');
  -- (each read in its own statement: a subquery does not see what a function its statement called wrote)
  v := jsonb_build_object('lines', (select count(*) from public.remittance_line where run_id = pg_temp.v('r1')),
                          'job', pg_temp.import_y(v_ly));
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'));
  v := v || jsonb_build_object('nightly', pg_temp.nightly('h4a'));
  return v || jsonb_build_object('alert', pg_temp.alerts('h4a'), 'facts', pg_temp.alert_facts('h4a'),
    'oldest_days', (select r.oldest_days = private.paris_today() - pg_temp.d(10) from public.payment_check_result r
                    where r.run_id = pg_temp.v('h4a') and r.code = 'remittance_breach_held'));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'h4', pg_temp.isolated('sc_h4');
select results_eq($$ select (v ->> 'lines')::int, (v ->> 'job')::int, v -> 'booked', v -> 'nightly', v -> 'alert'
                     from j where k = 'h4' $$,
  $$ values (2, 1, '[]'::jsonb, '[]'::jsonb,
             '[["r1", "alert", "remittance_run", 2, "201000",
                ["d2", "d3", "d4", "d5", "d6", "d7", "d8", "d9", "d10", "d11", "d12", "d13", "d14", "d15"], false,
                []]]'::jsonb) $$,
  'H4 (forged, two dates both held, their windows overlapping): the alert counts and sums both lines and names each uncovered day once');
select is((select v -> 'facts' || jsonb_build_object('oldest_days', v -> 'oldest_days') from j where k = 'h4'),
  jsonb_build_object('number', true, 'judged_on', 'd16', 'earliest', 'd10', 'bound_days', 5, 'ids', true,
                     'oldest', true, 'currency', 'EUR', 'uncovered_count', 14, 'waiting_count', 0,
                     'oldest_days', true),
  'H4''s alert: its earliest date the earlier one held to (d10), its age that date''s (the older line''s), its days counted once each (14), both lines'' entries');

-- (tests-ui-2) The caps: the row names the first 31 days and the first 10 lines, and counts them all.
-- HD (forged): x's execution in F1 set back to the 45th business day before today (the file item's date, its
-- append-only guard off: no command moves it), L = d15, y's debit after L (d16) on a statement of d16 alone — the window
-- [e0, d15] holds 41 business days on no statement (all but d0 … d1, the cancellation's evidence): the first 31 named,
-- from e0 to d5, 41 counted.
-- HW: L = d15, eleven batch lines of x's PmtInf that no subset makes (10,00 € … 10,10 €) on d14, younger than the bound
-- days and offering no booking of x, y's own debit after L (d16), one statement (d2 … d16): the first 10 lines by date
-- and id named, each as x's possible debit, 11 counted
create or replace function pg_temp.sc_hd() returns jsonb language plpgsql as $$
declare v jsonb; v_ly uuid;
begin
  perform pg_temp.chain_prefix('hd');
  perform pg_temp.hold_to('r1', 15);
  alter table public.transfer_file_item disable trigger transfer_file_item_append_only;
  update public.transfer_file_item set execution_date = pg_temp.bd(45)
  where transfer_id = pg_temp.v('m0') and file_id = pg_temp.v('f1');
  alter table public.transfer_file_item enable always trigger transfer_file_item_append_only;
  perform pg_temp.st('c3', 16, 16, jsonb_build_array(pg_temp.own(pg_temp.v('y'), 16)));
  v_ly := pg_temp.ln('c3');
  v := jsonb_build_object('job', pg_temp.import_y(v_ly));
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'), 'nightly', pg_temp.nightly('hda'));
  return v || (select jsonb_build_object(
                 'named', jsonb_array_length(r.details -> 'uncovered_days'),
                 'first', (r.details ->> 'uncovered_days')::jsonb ->> 0 = pg_temp.bd(45)::text,
                 'last', pg_temp.dk((r.details -> 'uncovered_days' ->> 30)::date),
                 'count', r.details -> 'uncovered_count', 'lines', r.count, 'waiting', r.details -> 'waiting')
               from public.payment_check_result r
               where r.run_id = pg_temp.v('hda') and r.code = 'remittance_breach_held');
end $$;
create or replace function pg_temp.sc_hw() returns jsonb language plpgsql as $$
declare v jsonb; v_s uuid; v_ly uuid;
begin
  perform pg_temp.chain_prefix('hw');
  perform pg_temp.hold_to('r1', 15);
  v_s := pg_temp.st('c3', 2, 16,
    (select jsonb_agg(jsonb_build_object('amount', 1000 + k, 'pmt_inf', pg_temp.pmt('f1', 1), 'day', pg_temp.d(14))
                      order by k)
     from generate_series(0, 10) k) || jsonb_build_array(pg_temp.own(pg_temp.v('y'), 16)));
  v_ly := pg_temp.ln('c3', 12);
  v := jsonb_build_object('job', pg_temp.import_y(v_ly));
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'), 'nightly', pg_temp.nightly('hwa'));
  return v || (select jsonb_build_object(
                 'days', r.details -> 'uncovered_days', 'lines', r.count,
                 'named', jsonb_array_length(r.details -> 'waiting'), 'count', r.details -> 'waiting_count',
                 'first10', (select jsonb_agg((w.v ->> 'line_id')::uuid order by w.o)
                             from jsonb_array_elements(r.details -> 'waiting') with ordinality w (v, o))
                            = (select jsonb_agg(x.id order by x.id)
                               from (select q.id from public.bank_transaction q
                                     where q.statement_id = v_s and q.amount_minor between 1000 and 1010
                                     order by q.id limit 10) x),
                 'all_x', (select bool_and(pg_temp.tk(w.v ->> 'end_to_end_id') = 'x'
                                           and pg_temp.dk((w.v ->> 'booking_date')::date) = 'd14')
                           from jsonb_array_elements(r.details -> 'waiting') w (v)))
               from public.payment_check_result r
               where r.run_id = pg_temp.v('hwa') and r.code = 'remittance_breach_held');
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'hd', pg_temp.isolated('sc_hd');
insert into j select 'hw', pg_temp.isolated('sc_hw');
select results_eq($$ select k, v - 'job' - 'booked' - 'nightly', (v ->> 'job')::int, v -> 'booked', v -> 'nightly'
                     from j where k in ('hd', 'hw') order by k $$,
  $$ values ('hd'::text, '{"named": 31, "first": true, "last": "d5", "count": 41, "lines": 1, "waiting": []}'::jsonb,
             1, '[]'::jsonb, '[]'::jsonb),
            ('hw', '{"days": [], "lines": 1, "named": 10, "count": 11, "first10": true, "all_x": true}', 1, '[]',
             '[]') $$,
  'the caps: 41 uncovered days — the first 31 named (from e0), 41 counted; 11 lines that may be x''s debit — the first 10 by date and id named, 11 counted');

-- HU (forged; CPCE-08): a run whose chain holds no other transfer — Lilas' payout l0 in F1, downloaded on d(0) and
-- never cancelled, booked by the import after L (d6) on a statement of d4 … d7 only: its row at the booking, whatever
-- the statements (as since 6b-2c), no alert; its row then taken out (the append-only guard off, as no command can): the
-- nightly check neither writes it again nor raises the alert — the alert is the chained runs' holds', not a check of
-- every booked run's rows
create or replace function pg_temp.sc_hu() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid;
begin
  perform pg_temp.handed_out('f1', 'hu-g1', 0);
  insert into t values ('l0', pg_temp.trid('r2'));
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0) where id = pg_temp.v('l0');
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  perform pg_temp.hold_to('r2', 4);
  perform pg_temp.st('c3', 4, 7, jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('l0')), 'day', pg_temp.d(6))));
  v_l := pg_temp.ln('c3');
  v := v || jsonb_build_object(
    'job', (pg_temp.book(jsonb_build_array(jsonb_build_object('line', v_l, 'kind', 'payout',
                                                              'transfer', pg_temp.v('l0')))) ->> 'payouts')::integer,
    'chain', (select count(*) from private.transfer_chain(pg_temp.v('l0'))),
    'booked', pg_temp.breaches('r2'));
  perform pg_temp.nightly('hua');
  v := v || jsonb_build_object('nightly0', pg_temp.breaches('r2'), 'alert0', pg_temp.alerts('hua'));
  alter table public.remittance_deadline_breach disable trigger remittance_deadline_breach_append_only;
  delete from public.remittance_deadline_breach where run_id = pg_temp.v('r2');
  alter table public.remittance_deadline_breach enable always trigger remittance_deadline_breach_append_only;
  perform pg_temp.nightly('hub');
  return v || jsonb_build_object('nightly1', pg_temp.breaches('r2'), 'alert1', pg_temp.alerts('hub'),
                                 'run', pg_temp.run_status('r2'));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'hu', pg_temp.isolated('sc_hu');
select results_eq($$ select (v ->> 'job')::int, (v ->> 'chain')::int, v -> 'booked', v -> 'nightly0', v -> 'alert0',
                            v -> 'nightly1', v -> 'alert1', v ->> 'run' from j where k = 'hu' $$,
  $$ values (1, 1, '["none"]'::jsonb, '["none"]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, 'booked'::text) $$,
  'HU (forged): a run whose chain holds no other transfer gets its row at the booking whatever the statements, and no alert — nor once its row is taken out (the alert is the chained runs'' holds'')');

-- The functions (PR #38's treatment for the booking guard and, review round 1 (tests-ui-1), the funds pass's posting;
-- the alert's helpers internal) -----------------------------------------------------------------------------------
select is((select jsonb_agg(jsonb_build_array(p.proname, p.prosecdef, p.provolatile,
                                               (select jsonb_agg(c order by c) from unnest(p.proconfig) c))
                           order by p.proname)
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'private'
             and p.proname in ('bank_booking_post_rows', 'bank_line_booking_guard', 'remittance_booked_chain_runs',
                               'remittance_breach_held', 'run_remittance_runs_checks')),
  '[["bank_booking_post_rows", true, "v", ["enable_seqscan=off", "search_path=\"\""]],
    ["bank_line_booking_guard", false, "v",
     ["enable_hashjoin=off", "enable_mergejoin=off", "enable_seqscan=off", "search_path=\"\""]],
    ["remittance_booked_chain_runs", false, "s", ["enable_seqscan=off", "search_path=\"\""]],
    ["remittance_breach_held", false, "s", ["enable_seqscan=off", "search_path=\"\""]],
    ["run_remittance_runs_checks", true, "v", ["enable_seqscan=off", "search_path=\"\""]]]'::jsonb,
  'the booking guard and the funds pass''s posting read every row by its key whatever the statistics (enable_seqscan off: PR #38''s known limit; the posting SECURITY DEFINER as before); the alert''s helpers keyed the same; the nightly checks SECURITY DEFINER as before');
select is((select count(*)::integer from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           cross join (values ('public'), ('anon'), ('authenticated'), ('service_role')) r (role)
           where n.nspname = 'private'
             and p.proname in ('bank_booking_post_rows', 'bank_line_booking_guard', 'remittance_booked_chain_runs',
                               'remittance_breach_held', 'run_remittance_runs_checks')
             and has_function_privilege(r.role, p.oid, 'execute')), 0,
  'no role but the owner executes the funds pass''s posting, the booking guard, the alert''s helpers or the runs'' checks');

select is(private.switch_on('downloaded_file_cancellation'), false,
  'the switch is off as the migration leaves it (6b-3b part 3 switches it on)');

select * from finish();
rollback;
