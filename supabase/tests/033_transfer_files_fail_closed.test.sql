-- M2c-6a review fixes, round 5: fail-closed (ADR-0014 « M2c-6a review fixes », round 5; design §9.7; COMPLIANCE SEPA-01,
-- OQ-80, OQ-81). Four rounds kept finding ways a transfer cancelled out of a file the bank already has could be paid
-- late and then paid again, and the statements alone can never prove a transfer will not be executed later. So once a
-- file is downloaded nothing in it is cancelled, re-issued or re-queued until M2c-6b books its debits from the
-- statements: the cancellation machinery of rounds 1–4 stays, tested by 028–032 with the switch on, behind
-- private.feature_switch 'downloaded_file_cancellation', off in production. This file runs with the switch as the
-- migration leaves it (off):
--   * the switch: its row is there and off; anon and authenticated neither read nor write it, nor call
--     private.switch_on; an unknown key is off;
--   * for a downloaded file and for a sent one, each of the five commands (cancel_transfer_file,
--     request_/confirm_transfer_file_cancellation, request_/confirm_transfer_cancellation) refuses
--     `bank_booking_required` although the statements would allow it, and nothing changes (the files' status and
--     version, their transfers in_file, no cancellation request, the runs, the refunds, the pending lines);
--   * cancel_remittance_run and cancel_refund on a payout or refund of a downloaded or sent file still refuse;
--   * the guards refuse a downloaded file's cancellation and its transfers' leaving the file, whoever writes them;
--   * a generated file is still superseded by cancel_transfer_file (its transfers back to « à mettre dans un fichier »);
--   * a request opened while the switch was on is not confirmed once it is off;
--   * the pages' reads say the switch is off (`cancellation_after_download`) and carry no cancellation card.
-- Review round 6 (round 5's verifiers): the run guard refuses a run's cancellation while its payout is in a downloaded
-- file, whoever writes it (postgres, service_role); a file the bank executed, in full or in part, is not served again
-- (`file_executed`, whatever the switch); a refund whose transfer is in a downloaded file is executed only by that
-- transfer's own end-to-end id or a batch line of its own PmtInf in that file (round 4's G2 rule, now).
-- Review round 7 (round 6's verifiers; the founder's decision on N1, option (b)): the run guard holds once the file is
-- marked as sent too; a line naming neither an end-to-end id nor a PmtInf (a CSV feed without the reference column)
-- executes such a refund again, as in M2b, while its transfer re-issues none; a batch line of another PmtInf of the
-- same file (the sweep's) does not; the refusal names the file and says why, never « a second time » here.
-- No ledger entry is posted by any of it but the refund's own debit.
begin;
select plan(43);


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


-- The switch, as the migration leaves it -----------------------------------------------------------------------------
select results_eq($$ select key, enabled, note ~ 'ADR-0014' and note ~ 'round 5' from private.feature_switch order by key $$,
  $$ values ('downloaded_file_cancellation'::text, false, true) $$,
  'the switch is seeded by the migration, off, its note naming ADR-0014 M2c-6a round 5');
select results_eq($$ select private.switch_on('downloaded_file_cancellation'), private.switch_on('no_such_switch'),
                            private.switch_on(null) $$,
  $$ values (false, false, false) $$, 'private.switch_on: off, and off for an unknown key');
select ok((select p.prosecdef and p.provolatile = 's' and array_to_string(p.proconfig, ',') ~ 'search_path=""'
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'private' and p.proname = 'switch_on'),
  'private.switch_on is a stable definer function with its search_path pinned');
-- what a role gets when it touches the switch: the SQLSTATE, or « ok »
create or replace function pg_temp.as_role(p_role text, p_sql text) returns text language plpgsql as $$
begin
  perform pg_temp.as_user('01');
  execute format('set local role %I', p_role);
  begin
    execute p_sql;
  exception when others then
    reset role;
    return sqlstate;
  end;
  reset role;
  return 'ok';
end $$;
create or replace function pg_temp.touches() returns table (r text, s text, o bigint) language sql as $$
  select r, s, o from unnest(array['anon', 'authenticated']) r
  cross join unnest(array['select * from private.feature_switch',
                          'insert into private.feature_switch (key, enabled, note) values (''x'', true, ''x'')',
                          'update private.feature_switch set enabled = true',
                          'delete from private.feature_switch',
                          'select private.switch_on(''downloaded_file_cancellation'')']) with ordinality x (s, o) $$;
select results_eq($$ select r, s, pg_temp.as_role(r, s) from pg_temp.touches() order by r, o $$,
  $$ select r, s, '42501'::text from pg_temp.touches() order by r, o $$,
  'anon and authenticated can neither read nor write the switch, nor ask private.switch_on');
select is((select enabled from private.feature_switch where key = 'downloaded_file_cancellation'), false,
  'the switch is still off');

-- A downloaded file (F1) and a sent one (F2), each of which the statements would let be cancelled ----------------------
-- F1 holds Martin (M) and Lilas (L) in its first PmtInf, the sweep (S) in its second, downloaded and dated d(0); the
-- statement of d(0)–d(1), produced after them, shows nothing of it: two people could have cancelled it whole.
select pg_temp.handed_out('f1', 'r5-gen-0001', 0);
insert into t values ('m1', pg_temp.trid('r1')), ('l1', pg_temp.trid('r2')), ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
select pg_temp.statement('b1', pg_temp.d(1), null, '[]', pg_temp.d(0), pg_temp.after(1));
-- F2 holds two refunds (50,00 € and 90,00 €) in one PmtInf, downloaded, marked as sent, dated d(4); the bank booked the
-- PmtInf as one line of 90,00 €: the 50,00 € one could have been cancelled alone, the bank having refused it.
insert into j select 'rq', pg_temp.refund('31', 5000);
insert into j select 'rp', pg_temp.refund('32', 9000);
select pg_temp.handed_out('f2', 'r5-gen-0002', 4);
insert into t values ('q1', pg_temp.rft('rq')), ('q2', pg_temp.rft('rp'));
select is(pg_temp.try('01', pg_temp.sent('r5-sent-0002', 'f2')), 'sent', 'F2 is marked as sent (that stays allowed)');
select pg_temp.statement('b2', pg_temp.d(5), null, jsonb_build_array(
  jsonb_build_object('amount', 9000, 'pmt_inf', pg_temp.pmt('f2', 1))), pg_temp.d(4), pg_temp.after(5));
select results_eq($$ select (pg_temp.fl(pg_temp.v('f1'))).status, (pg_temp.fl(pg_temp.v('f2'))).status,
                            pg_temp.status(pg_temp.v('m1')), pg_temp.status(pg_temp.v('l1')), pg_temp.status(pg_temp.v('s1')),
                            pg_temp.status(pg_temp.v('q1')), pg_temp.status(pg_temp.v('q2')),
                            pg_temp.ev('f1', null, 'refusal'), pg_temp.ev('f2', pg_temp.v('q1'), 'refusal') $$,
  $$ values ('downloaded'::text, 'sent'::text, 'in_file'::text, 'in_file'::text, 'in_file'::text, 'in_file'::text,
             'in_file'::text, null::text, null::text) $$,
  'fixture: F1 downloaded, F2 sent, their transfers in_file; the statements would allow F1''s and the refund''s cancellation');
-- what the commands must not change
create or replace function pg_temp.snapshot() returns text language sql as $$
  select format('files=%s transfers=%s requests=%s runs=%s refunds=%s payments=%s pending=%s entries=%s',
    (select string_agg(f.number || ':' || f.status || ':v' || f.version, ',' order by f.number)
     from public.transfer_file f where f.organization_id = '00000000-0000-0000-0000-0000000000aa'),
    (select string_agg(x.kind || ':' || x.amount_minor || ':' || x.status || ':' || coalesce(f.number, '-'), ','
                       order by x.kind, x.amount_minor, x.end_to_end_id)
     from public.bank_transfer x left join public.transfer_file f on f.id = x.transfer_file_id
     where x.organization_id = '00000000-0000-0000-0000-0000000000aa'),
    (select count(*) || '/' || count(q.confirmed_at) from public.transfer_cancellation_request q),
    (select string_agg(r.number || ':' || r.status || ':v' || r.version, ',' order by r.number)
     from public.remittance_run r where r.organization_id = '00000000-0000-0000-0000-0000000000aa'),
    (select string_agg(q.amount_minor || ':' || q.status, ',' order by q.amount_minor)
     from public.refund_request q where q.organization_id = '00000000-0000-0000-0000-0000000000aa'),
    (select string_agg(p.status, ',' order by p.id) from public.payment p
     where p.organization_id = '00000000-0000-0000-0000-0000000000aa'),
    (select count(*) from private.remittance_pending q where q.organization_id = '00000000-0000-0000-0000-0000000000aa'),
    (select count(*) from public.ledger_entry e where e.organization_id = '00000000-0000-0000-0000-0000000000aa')) $$;
create or replace function pg_temp.cancel_file(p_key text, p_file text) returns text language sql as $$
  select format($q$ select public.cancel_transfer_file(%L, %L, %s, 'Fichier non déposé') ->> 'status' $q$, p_key,
                pg_temp.v(p_file), (pg_temp.fl(pg_temp.v(p_file))).version) $$;
-- the five commands on a file and one of its transfers, each by whoever could otherwise do it (01 asks, 04 confirms)
create or replace function pg_temp.five(p_file text, p_transfer text, p_n text) returns text[] language plpgsql as $$
declare v text[] := '{}';
begin
  v := v || pg_temp.try('01', pg_temp.cancel_file('r5-cnf-' || p_n, p_file));
  v := v || pg_temp.try('01', pg_temp.req_file('r5-rqf-' || p_n, p_file));
  v := v || pg_temp.try('04', pg_temp.conf_file('r5-cff-' || p_n, p_file));
  v := v || pg_temp.try('01', pg_temp.req_tr('r5-rqt-' || p_n, pg_temp.v(p_transfer)));
  v := v || pg_temp.try('04', pg_temp.conf_tr('r5-cft-' || p_n, pg_temp.v(p_transfer)));
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'before', to_jsonb(pg_temp.snapshot());

select is(pg_temp.five('f1', 'm1', '0001'),
  array['transfer file refused: bank_booking_required', 'transfer file refused: bank_booking_required',
        'transfer file refused: bank_booking_required', 'transfer refused: bank_booking_required',
        'transfer refused: bank_booking_required'],
  'a downloaded file: none of the five commands cancels it, nor one of its transfers (bank_booking_required)');
select is(pg_temp.snapshot(), (select v #>> '{}' from j where k = 'before'),
  'a downloaded file: nothing changed — the files'' status and version, their transfers in_file, no request, the runs, the refunds, the pending lines');
select is(pg_temp.five('f2', 'q1', '0002'),
  array['transfer file refused: bank_booking_required', 'transfer file refused: bank_booking_required',
        'transfer file refused: bank_booking_required', 'transfer refused: bank_booking_required',
        'transfer refused: bank_booking_required'],
  'a sent file: none of the five commands cancels it, nor the refund the bank left out of its PmtInf''s line');
select is(pg_temp.snapshot(), (select v #>> '{}' from j where k = 'before'), 'a sent file: nothing changed either');
select results_eq($$ select pg_temp.try('04', pg_temp.cancel_run('r5-run-0001', 'r1')),
                            pg_temp.try('04', pg_temp.cancel_run('r5-run-0002', 'r2')),
                            pg_temp.try('01', pg_temp.cancel_refund('r5-crf-0001', 'rq')),
                            pg_temp.try('01', pg_temp.cancel_refund('r5-crf-0002', 'rp')) $$,
  $$ values ('remittance run refused: payout_in_downloaded_file'::text,
             'remittance run refused: payout_in_downloaded_file'::text,
             'refund refused: in_downloaded_file'::text, 'refund refused: in_downloaded_file'::text) $$,
  'a run or a refund whose transfer is in a downloaded or sent file is still not cancelled');
-- review round 7 (round 6's verifier, N3): what those refusals say a downloaded file's transfers wait for — their
-- debits booked from the statement, which a refund's is once linked and a payout's or the sweep's cannot be yet
-- (M2c-6b books them); never « read from the statement » (a payout's debit read changes nothing today)
create or replace function pg_temp.hint(p_user text, p_sql text) returns text language plpgsql as $$
declare v_hint text;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    reset role;
    return coalesce(v_hint, '');
  end;
  reset role;
  return 'no refusal';
end $$;
create or replace function pg_temp.waits(p_hint text) returns text language sql as $$
  select concat_ws(',',
    case when p_hint ~ 'comptabilisés? depuis le relevé' then 'booked' end,
    case when p_hint ~ 'ceux des reversements et de la quote-part du cabinet ne peuvent pas encore l''être'
           or p_hint ~ 'pas encore possible pour un reversement ni pour la quote-part du cabinet'
           or p_hint ~ 'ce qui n''est pas encore disponible pour un reversement' then 'payout_not_yet' end,
    case when p_hint ~ 'lus? sur le relevé' then 'read' end) $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(array[pg_temp.waits(pg_temp.hint('01', pg_temp.cancel_file('r7-cnf-0001', 'f1'))),
                pg_temp.waits(pg_temp.hint('01', pg_temp.req_file('r7-rqf-0001', 'f1'))),
                pg_temp.waits(pg_temp.hint('04', pg_temp.conf_file('r7-cff-0001', 'f1'))),
                pg_temp.waits(pg_temp.hint('01', pg_temp.req_tr('r7-rqt-0001', pg_temp.v('m1')))),
                pg_temp.waits(pg_temp.hint('04', pg_temp.conf_tr('r7-cft-0001', pg_temp.v('m1')))),
                pg_temp.waits(pg_temp.hint('04', pg_temp.cancel_run('r7-run-0001', 'r1')))],
  array_fill('booked,payout_not_yet'::text, array[6]),
  'the refusals'' hints: a downloaded file''s transfers wait for their debits booked from the statement, not yet possible for a payout or the sweep');
select is(pg_temp.snapshot(), (select v #>> '{}' from j where k = 'before'), 'and nothing changed');

-- Whoever writes it: the guards --------------------------------------------------------------------------------------
select throws_like($$ update public.transfer_file set status = 'superseded', closed_at = clock_timestamp(),
                        close_reason = 'test' where id = pg_temp.v('f1') $$,
  '%cancellation after download is switched off%',
  'the file guard: a downloaded file is not closed while the switch is off');
select throws_like($$ update public.transfer_file set status = 'rejected', closed_at = clock_timestamp(),
                        close_reason = 'test' where id = pg_temp.v('f2') $$,
  '%cancellation after download is switched off%', 'nor a sent one');
select throws_like($$ update public.bank_transfer set status = 'cancelled', cancelled_at = clock_timestamp(),
                        cancel_reason = 'test' where id = pg_temp.v('m1') $$,
  '%cancellation after download is switched off%',
  'the transfer guard: a payout of a downloaded file does not leave it cancelled');
select throws_like($$ select private.transfer_file_release(pg_temp.v('f2'), 'superseded', 'test', 'not_uploaded', null) $$,
  '%cancellation after download is switched off%', 'nor through the release of its file (a re-issue, a re-queue)');
-- review round 6 (defence in depth): nor the run whose payout is in a downloaded file, written straight to its table —
-- by the owner, and by the worker's role (service_role), which can write runs
select throws_like($$ update public.remittance_run set status = 'cancelled', cancelled_at = clock_timestamp(),
                        cancel_reason = 'test' where id = pg_temp.v('r1') $$,
  '%cancellation after download is switched off%',
  'the run guard: a sent run whose payout is in a downloaded file is not cancelled (as the owner)');
create or replace function pg_temp.as_service(p_sql text) returns text language plpgsql as $$
begin
  set local role service_role;
  begin
    execute p_sql;
  exception when others then
    reset role;
    return sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  return 'ok';
end $$;
select matches(pg_temp.as_service(format($q$ update public.remittance_run set status = 'cancelled',
                                               cancelled_at = clock_timestamp(), cancel_reason = 'test' where id = %L $q$,
                                             pg_temp.v('r2'))),
  '^23514 .*cancellation after download is switched off',
  'nor by the worker''s role (service_role)');
select is(pg_temp.snapshot(), (select v #>> '{}' from j where k = 'before'), 'nothing changed');

-- A generated file is still superseded -------------------------------------------------------------------------------
create or replace function pg_temp.file_of(p_transfer uuid) returns uuid language sql as $$
  select transfer_file_id from public.bank_transfer where id = p_transfer $$;
insert into j select 'rz', pg_temp.refund('35', 7000);
insert into t select 'f3', (pg_temp.gen('01', 'r5-gen-0003') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f3'));
select results_eq($$ select (pg_temp.fl(pg_temp.v('f3'))).status, pg_temp.try('01', pg_temp.cancel_file('r5-cnf-0003', 'f3')),
                            (pg_temp.fl(pg_temp.v('f3'))).status, pg_temp.status(pg_temp.rft('rz')),
                            pg_temp.file_of(pg_temp.rft('rz')) is null $$,
  $$ values ('generated'::text, 'superseded'::text, 'superseded'::text, 'ordered'::text, true) $$,
  'a generated file is still cancelled (superseded): its refund back « à mettre dans un fichier »');

-- A request opened while the switch was on is not confirmed once it is off --------------------------------------------
update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
select results_eq($$ select pg_temp.try('01', pg_temp.req_file('r5-rqf-0101', 'f1')),
                            pg_temp.try('01', pg_temp.req_tr('r5-rqt-0102', pg_temp.v('q1'))) $$,
  $$ values ('requested'::text, 'requested'::text) $$,
  'switched on (as M2c-6b will), F1''s cancellation and the refused refund''s are asked …');
update private.feature_switch set enabled = false where key = 'downloaded_file_cancellation';
insert into j select 'asked', to_jsonb(pg_temp.snapshot());
select results_eq($$ select pg_temp.try('04', pg_temp.conf_file('r5-cff-0101', 'f1')),
                            pg_temp.try('04', pg_temp.conf_tr('r5-cft-0102', pg_temp.v('q1'))) $$,
  $$ values ('transfer file refused: bank_booking_required'::text, 'transfer refused: bank_booking_required'::text) $$,
  '… and, switched off again, neither is confirmed');
select results_eq($$ select pg_temp.snapshot() = (select v #>> '{}' from j where k = 'asked'),
                            (select count(*)::int from public.transfer_cancellation_request where confirmed_at is null),
                            (pg_temp.fl(pg_temp.v('f1'))).status, pg_temp.status(pg_temp.v('q1')) $$,
  $$ values (true, 2, 'downloaded'::text, 'in_file'::text) $$,
  'nothing changed: both requests still open, F1 downloaded, the refund''s transfer in its file');

-- The pages' reads ---------------------------------------------------------------------------------------------------
create or replace function pg_temp.read(p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  execute p_sql into v;
  reset role;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select results_eq($$ select x ->> 'cancellation_after_download', jsonb_typeof(x -> 'cancellation'),
                            (select count(*)::int from jsonb_array_elements(x -> 'items') i
                             where jsonb_typeof(i -> 'cancellation') <> 'null'),
                            jsonb_array_length(x -> 'items')
                     from (select pg_temp.read(format('select public.transfer_file_detail(%L)', pg_temp.v('f1'))) x) d $$,
  $$ values ('false'::text, 'null'::text, 0, 3) $$,
  'the file''s page: the switch off, no cancellation card for the file nor its transfers (the open request not offered)');
select results_eq($$ select x ->> 'cancellation_after_download',
                            (select count(*)::int from jsonb_array_elements(x -> 'accounts') a
                             cross join lateral jsonb_array_elements(a -> 'files') f
                             where jsonb_typeof(f -> 'cancellation') <> 'null')
                     from (select pg_temp.read('select public.transfer_overview()') x) d $$,
  $$ values ('false'::text, 0) $$, '« Virements »: the switch off, no cancellation card on the files');

-- Review round 6: a file the bank executed, in full or in part, is not served again, whatever the switch ----------------
-- (round 5's verifier, p_redl: served past the warning, it could be uploaded again and pay everything twice)
create or replace function pg_temp.redl(p_file text, p_ack boolean) returns text language sql as $$
  select format($q$ select public.transfer_file_download(%L, %L, %L) ->> 'download' $q$, pg_temp.v(p_file),
                pg_temp.sha(pg_temp.v(p_file)), p_ack) $$;
grant execute on all functions in schema pg_temp to authenticated;
-- F2: the bank booked its PmtInf as one batch line of 90,00 € (above)
select results_eq($$ select private.transfer_file_executed(pg_temp.v('f2')), pg_temp.try('01', pg_temp.redl('f2', true)),
                            pg_temp.try('04', pg_temp.redl('f2', false)) $$,
  $$ values (true, 'transfer file refused: file_executed'::text, 'transfer file refused: file_executed'::text) $$,
  'a sent file the bank executed in part (a batch line of its PmtInf) is not served again, warning acknowledged or not');
-- F1: nothing of it on a statement yet — served again past the warning, as before …
select results_eq($$ select private.transfer_file_executed(pg_temp.v('f1')), pg_temp.try('01', pg_temp.redl('f1', false)),
                            pg_temp.try('01', pg_temp.redl('f1', true)) $$,
  $$ values (false, 'transfer file refused: already_downloaded'::text, '2'::text) $$,
  'a downloaded file the bank executed nothing of is still served again once the warning is acknowledged');
-- … until a statement shows its payouts and its sweep debited under their own end-to-end ids
select pg_temp.statement('b3', pg_temp.d(3), null, jsonb_build_array(
  jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m1'))),
  jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('l1'))),
  jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s1')))), pg_temp.d(2), pg_temp.after(3));
select results_eq($$ select private.transfer_file_executed(pg_temp.v('f1')), private.transfer_debited_before(pg_temp.v('m1')),
                            pg_temp.try('01', pg_temp.redl('f1', true)), pg_temp.try('04', pg_temp.redl('f1', false)) $$,
  $$ values (true, false, 'transfer file refused: file_executed'::text, 'transfer file refused: file_executed'::text) $$,
  'executed in full by its own debits (none of its transfers debited before): not served again, acknowledged or not');
select results_eq($$ select pg_temp.try('01', pg_temp.sent('r6-sent-0001', 'f1')), pg_temp.try('04', pg_temp.redl('f1', true)) $$,
  $$ values ('sent'::text, 'transfer file refused: file_executed'::text) $$,
  'it can still be marked as sent, and is not served once sent either');
-- review round 7 (round 6's verifier): the run guard holds once the file is marked as sent too — it keys on a download
-- recorded, not on the file's status (F1 sent, its payouts still in it: nothing books them before M2c-6b)
create or replace function pg_temp.direct_cancel(p_run uuid, p_role text) returns text language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  begin
    update public.remittance_run set status = 'cancelled', cancelled_at = clock_timestamp(), cancel_reason = 'test'
    where id = p_run;
  exception when others then
    reset role;
    return sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  return 'ok';
end $$;
create or replace function pg_temp.run_status(p_run uuid) returns text language sql as $$
  select status from public.remittance_run where id = p_run $$;
select results_eq($$ select (pg_temp.fl(pg_temp.v('f1'))).status, pg_temp.status(pg_temp.v('m1')),
                            pg_temp.status(pg_temp.v('l1')),
                            pg_temp.direct_cancel(pg_temp.v('r1'), 'postgres')
                              ~ '^23514 .*its payout stays in its downloaded file: cancellation after download is switched off',
                            pg_temp.direct_cancel(pg_temp.v('r2'), 'service_role')
                              ~ '^23514 .*its payout stays in its downloaded file: cancellation after download is switched off',
                            pg_temp.run_status(pg_temp.v('r1')), pg_temp.run_status(pg_temp.v('r2')) $$,
  $$ values ('sent'::text, 'in_file'::text, 'in_file'::text, true, true, 'sent'::text, 'sent'::text) $$,
  'the run guard: a run whose payout is in a file marked as sent is not cancelled either, by the owner nor by service_role');
update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
select is(pg_temp.try('04', pg_temp.redl('f1', true)), 'transfer file refused: file_executed',
  'nor with cancellation after download switched on');
update private.feature_switch set enabled = false where key = 'downloaded_file_cancellation';
select results_eq($$ select (pg_temp.fl(pg_temp.v('f1'))).download_count,
                            (select count(*)::int from public.transfer_file_download where file_id = pg_temp.v('f1')),
                            (pg_temp.fl(pg_temp.v('f2'))).download_count $$,
  $$ values (2, 2, 1) $$, 'the refusals record no download (F1: the first and the one served past the warning)');

-- Review round 6 (round 4's G2 rule, now): a refund whose transfer is in a downloaded file is executed only by a debit
-- carrying that transfer's own end-to-end id, or by a batch line of its own PmtInf in that file (round 5's verifier,
-- p_link: a batch line of another PmtInf booked it while the file still carried it)
insert into j select 'rl', pg_temp.refund('36', 6000);
select pg_temp.handed_out('f4', 'r6-gen-0004', 6);
insert into t values ('q4', pg_temp.rft('rl'));
-- lines: another end-to-end id; a batch line of another PmtInf; a batch line of its own; the other refund of its PmtInf
-- (its own end-to-end id, the PmtInf's id)
select pg_temp.statement('b4', private.paris_today(), null, jsonb_build_array(
  jsonb_build_object('amount', 6000, 'e2e', 'RFDOTHER00000001', 'kind', 'refund_out'),
  jsonb_build_object('amount', 6000, 'pmt_inf', 'TF-2099-999999-1', 'kind', 'other_debit'),
  jsonb_build_object('amount', 6000, 'pmt_inf', pg_temp.pmt('f4', 1), 'kind', 'other_debit'),
  jsonb_build_object('amount', 6000, 'e2e', pg_temp.e2e(pg_temp.rft('rz')), 'pmt_inf', pg_temp.pmt('f4', 1),
                     'kind', 'refund_out')));
create or replace function pg_temp.line(p_statement text, p_no integer) returns uuid language sql as $$
  select id from public.bank_transaction
  where statement_id = ('e2000000-0000-0000-0000-0000000000' || p_statement)::uuid and line_no = p_no $$;
create or replace function pg_temp.link_refund(p_key text, p_line uuid, p_rf text) returns text language sql as $$
  select format($q$ select public.link_debit(%L, %L, 'refund', null, %L, null, 'lien (test)') -> 'result' ->> 'refunds' $q$,
                p_key, p_line, pg_temp.rq(p_rf)) $$;
-- the refund's status now (a function: read after the link in the same statement)
create or replace function pg_temp.rstatus(p_rf text) returns text language sql as $$
  select status from public.refund_request where id = pg_temp.rq(p_rf) $$;
grant execute on all functions in schema pg_temp to authenticated;
select results_eq($$ select (pg_temp.fl(pg_temp.v('f4'))).status, pg_temp.file_of(pg_temp.v('q4')) = pg_temp.v('f4'),
                            pg_temp.try('01', pg_temp.link_refund('r6-link-0001', pg_temp.line('b4', 1), 'rl'))
                              ~ 'refund refused: reissue_in_downloaded_file',
                            pg_temp.try('01', pg_temp.link_refund('r6-link-0002', pg_temp.line('b4', 2), 'rl'))
                              ~ 'refund refused: reissue_in_downloaded_file',
                            pg_temp.try('01', pg_temp.link_refund('r6-link-0004', pg_temp.line('b4', 4), 'rl'))
                              ~ 'refund refused: reissue_in_downloaded_file',
                            pg_temp.file_of(pg_temp.rft('rz')) = pg_temp.v('f4') $$,
  $$ values ('downloaded'::text, true, true, true, true, true) $$,
  'a refund in a downloaded file: neither a debit of another end-to-end id, a batch line of another PmtInf, nor the other refund''s debit of its PmtInf executes it');
select results_eq($$ select pg_temp.rstatus('rl'), pg_temp.status(pg_temp.v('q4')),
                            (select count(*)::int from public.bank_debit_link
                             where bank_transaction_id in (pg_temp.line('b4', 1), pg_temp.line('b4', 2),
                                                           pg_temp.line('b4', 4))) $$,
  $$ values ('requested'::text, 'in_file'::text, 0) $$, 'the refund stays requested, its transfer in the file, nothing linked');
-- review round 7: what the refusal says (the refund's trigger, as the debit posting meets it; written straight to the
-- refund, rolled back either way): the line names another transfer or batch, the file it is in — never that the file
-- would refund it a second time, never to cancel the file first (off)
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
create or replace function pg_temp.says(p_text text) returns text language sql as $$
  select concat_ws(',',
    case when p_text ~ '^refund refused: reissue_in_downloaded_file \| ' then 'refused' end,
    case when p_text ~ 'porte la référence d''un autre virement' then 'other_transfer' end,
    case when p_text ~ 'porte la référence d''un autre lot' then 'other_batch' end,
    case when p_text ~ 'ne porte aucune référence' then 'no_reference' end,
    case when p_text ~ 'il ne peut pas exécuter ce remboursement, dont le virement est dans le fichier TF-[0-9]{4}-[0-9]{6}, déjà téléchargé'
         then 'its_file' end,
    case when p_text ~ 'Ne le rattachez pas à ce remboursement' then 'do_not_link' end,
    case when p_text ~ 'seconde fois' then 'twice' end,
    case when p_text ~ 'annuler ce fichier' then 'cancel_file' end) $$;
grant execute on all functions in schema pg_temp to authenticated;
select results_eq($$ select pg_temp.says(pg_temp.follow('rl', pg_temp.line('b4', 1))),
                            pg_temp.says(pg_temp.follow('rl', pg_temp.line('b4', 2))),
                            pg_temp.says(pg_temp.follow('rl', pg_temp.line('b4', 4))),
                            pg_temp.follow('rl', pg_temp.line('b4', 1)) ~ (pg_temp.fl(pg_temp.v('f4'))).number,
                            pg_temp.rstatus('rl') $$,
  $$ values ('refused,other_transfer,its_file,do_not_link'::text, 'refused,other_batch,its_file,do_not_link'::text,
             'refused,other_transfer,its_file,do_not_link'::text, true, 'requested'::text) $$,
  'the refusal says the line names another transfer (or batch), so it cannot execute this refund whose transfer is in that file (its number), already downloaded; not to link it; never « a second time »');
select results_eq($$ select pg_temp.try('01', pg_temp.link_refund('r6-link-0003', pg_temp.line('b4', 3), 'rl')),
                            pg_temp.rstatus('rl'),
                            pg_temp.status(pg_temp.v('q4')), (pg_temp.fl(pg_temp.v('f4'))).status $$,
  $$ values ('1'::text, 'executed'::text, 'booked'::text, 'downloaded'::text) $$,
  'a batch line of its own PmtInf in that file executes it: the refund executed, its transfer booked');

-- Review round 7 (the founder's decision on round 6's N1, option (b)): a line naming neither an end-to-end id nor a
-- PmtInf — every line of a CSV feed without the « référence de bout en bout » column — executes a refund whose transfer
-- is in a downloaded or sent file, as in M2b, while that transfer re-issues none (always so with the switch off); a batch
-- line of another PmtInf of the same file (the servicer's sweep, of the same amount) still does not (round 6's verifier,
-- p_sibling). Omega's 60,00 €, all set off (N = 0), puts 60,00 € more of the servicer's on the dedicated account.
select pg_temp.file('04', '20000000-0000-0000-0000-0000000000a4', 6000);
select pg_temp.collect('04', 6000, private.paris_today() - 3);
insert into t select 'r4', pg_temp.run('a4', '{"04": "6000"}', 6000, 1000, 10, 12);
insert into j select 'rs', pg_temp.refund('37', 6000);
select pg_temp.handed_out('f5', 'r7-gen-0005', 8);
insert into t values ('q5', pg_temp.rft('rs'));
select results_eq($$ select pg_temp.try('01', pg_temp.sent('r7-sent-0005', 'f5')),
                            (select string_agg(x.kind || ' ' || x.amount_minor || ' ' || right(i.pmt_inf_id, 2), ', '
                                               order by i.pmt_inf_id, x.kind)
                             from public.transfer_file_item i join public.bank_transfer x on x.id = i.transfer_id
                             where i.file_id = pg_temp.v('f5')),
                            pg_temp.replaces(pg_temp.v('q5')) is null $$,
  $$ values ('sent'::text, 'refund 6000 -1, sweep 6000 -2'::text, true) $$,
  'fixture: F5 sent, a refund of 60,00 € in its first PmtInf, the servicer''s sweep of the same amount in its second; the refund''s transfer re-issues none');
select pg_temp.statement('b5', private.paris_today(), null, jsonb_build_array(
  jsonb_build_object('amount', 6000, 'pmt_inf', pg_temp.pmt('f5', 2), 'kind', 'other_debit'),
  jsonb_build_object('amount', 6000, 'kind', 'other_debit')));
select results_eq($$ select pg_temp.try('01', pg_temp.link_refund('r7-link-0001', pg_temp.line('b5', 1), 'rs'))
                              ~ 'refund refused: reissue_in_downloaded_file',
                            pg_temp.says(pg_temp.follow('rs', pg_temp.line('b5', 1))),
                            pg_temp.rstatus('rs'), pg_temp.status(pg_temp.v('q5')),
                            (select count(*)::int from public.bank_debit_link
                             where bank_transaction_id = pg_temp.line('b5', 1)) $$,
  $$ values (true, 'refused,other_batch,its_file,do_not_link'::text, 'requested'::text, 'in_file'::text, 0) $$,
  'a batch line of another PmtInf of the same file (the sweep''s, the same amount) does not execute the refund');
select results_eq($$ select pg_temp.follow('rs', pg_temp.line('b5', 2)),
                            pg_temp.try('01', pg_temp.link_refund('r7-link-0002', pg_temp.line('b5', 2), 'rs')),
                            pg_temp.rstatus('rs'), pg_temp.status(pg_temp.v('q5')), (pg_temp.fl(pg_temp.v('f5'))).status,
                            pg_temp.status((pg_temp.sweep(pg_temp.v('f5'))).id) $$,
  $$ values ('ok'::text, '1'::text, 'executed'::text, 'booked'::text, 'sent'::text, 'in_file'::text) $$,
  'a line naming neither an end-to-end id nor a PmtInf (a CSV feed without the reference column) executes it, as in M2b: the refund executed, its transfer booked, the file and its sweep as they were');

select results_eq($$ select count(*) filter (where entry_type in ('remittance', 'servicer_sweep'))::int
                     from public.ledger_entry where organization_id = '00000000-0000-0000-0000-0000000000aa' $$,
  $$ values (0) $$, 'no remittance nor sweep booked by any of it (M2c-6b books the debits)');

select * from finish();
rollback;
