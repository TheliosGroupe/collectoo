-- M2c-6b-3a, the switch-on prerequisites that 034 does not hold (docs/design/m2c-6b-3-plan.md §2 A–D, K–N; ADR-0014
-- « M2c-6b-3a »; COMPLIANCE OQ-80 (k), (n), (p), OQ-81, OQ-82). The switch STAYS OFF in the migration: each scenario
-- below turns private.feature_switch 'downloaded_file_cancellation' on inside its own subtransaction (pg_temp.isolated:
-- rolled back at its end, its outcomes kept), as 6b-3b's one-line migration will, and the file asserts at its end that
-- the switch is off. What each scenario pins:
--   * A (SW2/SW3 beyond 034): a sweep made after a sweep cancelled out of a downloaded file whose late debit is open, or
--     booked after it was made, is held (`cancelled_sweep_debited`) and alerted; one made after that booking is not; a
--     second late line holds again; A′: servicer-wide over every dedicated account of the currency, whatever its status;
--     the late debit as a batch line of the cancelled sweep's PmtInf;
--   * B: once ops book the cancelled sweep's late debit (`unplanned_sweep`), generation proposes the servicer's new share
--     again and the cancelled sweep is no longer alerted; a second late line stops it again;
--   * C (G1c): a cancelled payout or refund that was in a downloaded file, debited late and its line not booked nor
--     linked, is alerted whatever its run's or refund's state — but while the live end of its chain is alerted instead;
--   * D (H-PAY): a debit with no reference does not execute a refund in a downloaded file while a cancelled refund of
--     the account at its amount (any payment) may be its late execution — the hint by the account's feed; the link
--     options follow; an ordered refund is executed by it;
--   * K: rule 3b's (iv), a refund or a sweep cancelled out of a downloaded file: the line is ambiguous beside another
--     candidate; alone, a sweep is booked as its late debit (`unplanned_sweep` of it), a refund is refused
--     `cancelled_transfer_matches`;
--   * L: a debit carrying none of our references at a cancelled transfer's amount (its payee's IBAN or none), from its
--     execution date, not booked nor linked, is a possible late execution: the re-issue is held, the run's and the
--     refund's cancellation refused, the alert raised; the lines that do not count;
--   * M: the client's other payouts, the payment's other refunds, held while a cancelled one shows an open late debit;
--   * N: the cancellation evidence refuses `unreferenced_debit_open` on such lines (file and one-transfer branches, the
--     PmtInf's sum, a line imported before the confirmation);
--   * the new helpers are internal; public.cancellation_after_download answers the flag to a servicer's members only.
-- E–J of the plan (the late predecessor booked as its run's payout, its readers and return, the release's defence, the
-- R124-6 rows of a re-issue, P across transfers) are 6b-3a-2's (ADR-0014 « M2c-6b-3a », deviations).
begin;
select plan(68);


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
grant execute on all functions in schema pg_temp to authenticated;


-- A: a sweep made after a cancelled sweep the bank debited late (SW2/SW3 beyond 034) --------------------------------
-- F1 (the payouts, the sweep S1) downloaded and cancelled whole on evidence; F2 (the re-issues, a new sweep S2: S1 being
-- cancelled), downloaded; then S1 executed late after all, under its own SWP id
create or replace function pg_temp.sw_prefix(p_key text) returns void language plpgsql as $$
begin
  perform pg_temp.handed_out('f1', p_key || '-g1', 0);
  insert into t values ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
  perform pg_temp.cancel_whole('f1', p_key, 'b1');
  perform pg_temp.handed_out('f2', p_key || '-g2', 2);
  insert into t values ('s2', (pg_temp.sweep(pg_temp.v('f2'))).id);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s1')))));
end $$;
-- A1, A4: ops book S1's late debit (« Virement au compte propre » of S1) after S2 was made: S2 stays held, alerted
create or replace function pg_temp.sc_a1() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.sw_prefix('a1');
  v := v || jsonb_build_object('hold_before', pg_temp.hold(pg_temp.v('s2')),
    'book', pg_temp.bkx(pg_temp.ln('b2'), jsonb_build_array(pg_temp.pt('unplanned_sweep', pg_temp.v('s1'), 12000))));
  v := v || jsonb_build_object('hold_after', pg_temp.hold(pg_temp.v('s2')), 'redownload', pg_temp.redownload('f2'));
  insert into t select 'c1', pg_temp.chk(null);
  v := v || jsonb_build_object('alerts', to_jsonb(pg_temp.already_debited('c1')),
                               'alert_status', (select r.details ->> 'status' from public.payment_check_result r
                                                where r.run_id = pg_temp.v('c1') and r.code = 'transfer_already_debited'
                                                  and r.subject_id = pg_temp.v('s2')));
  return v;
end $$;
insert into j select 'a1', pg_temp.isolated('sc_a1');
select results_eq($$ select v ->> 'hold_before', v ->> 'book', v ->> 'hold_after', v ->> 'redownload' from j where k = 'a1' $$,
  $$ values ('cancelled_sweep_debited'::text, 'ok'::text, 'cancelled_sweep_debited'::text,
             'transfer file refused: holds_debited_transfer'::text) $$,
  'A1: a sweep made before ops booked the cancelled sweep''s late debit stays held after the booking (its share left once already), its file refused at a re-download');
select results_eq($$ select v -> 'alerts', v ->> 'alert_status' from j where k = 'a1' $$,
  $$ values ('["sweep 12000 in_file"]'::jsonb, 'in_file'::text) $$,
  'A4: alerted (transfer_already_debited, kind sweep, its status); the cancelled sweep, its debit booked, is not');
-- A2, A3: once that booking is made, a sweep made after it is not held (the share already reflects the debit); a second
-- late line of S1 holds it again
create or replace function pg_temp.sc_a2() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb;
begin
  perform pg_temp.sw_prefix('a2');
  perform pg_temp.bkx(pg_temp.ln('b2'), jsonb_build_array(pg_temp.pt('unplanned_sweep', pg_temp.v('s1'), 12000)));
  -- F2 never to be served (its sweep held): cancelled whole on its own evidence, S2 cancelled with it
  perform pg_temp.lines('b3', pg_temp.d(3), '[]', pg_temp.d(2), pg_temp.after(3));
  v := v || jsonb_build_object('cancel_f2', pg_temp.try('01', pg_temp.req_file('a2-rq2', 'f2')) || '/'
                                            || pg_temp.try('04', pg_temp.conf_file('a2-cf2', 'f2')));
  perform pg_temp.cypres_again('a2-cy');
  g := pg_temp.gen('01', 'a2-g3');
  insert into t values ('f3', (g ->> 'file_id')::uuid);
  perform pg_temp.write(pg_temp.v('f3'));
  insert into t values ('s3', (pg_temp.sweep(pg_temp.v('f3'))).id);
  v := v || jsonb_build_object('sweep3', g ->> 'sweep_minor', 'hold3', pg_temp.hold(pg_temp.v('s3')),
                               'first3', pg_temp.dl_try(pg_temp.v('f3')) ->> 'download');
  -- S1 executed once more
  perform pg_temp.lines('b4', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s1')))));
  v := v || jsonb_build_object('hold3_again', pg_temp.hold(pg_temp.v('s3')), 'redownload3', pg_temp.redownload('f3'));
  return v;
end $$;
insert into j select 'a2', pg_temp.isolated('sc_a2');
select results_eq($$ select v ->> 'cancel_f2', v ->> 'sweep3', coalesce(v ->> 'hold3', 'none'), v ->> 'first3'
                     from j where k = 'a2' $$,
  $$ values ('requested/superseded'::text, '12000'::text, 'none'::text, '1'::text) $$,
  'A2: a sweep made after ops booked the cancelled sweep''s late debit is proposed (the servicer''s new share), not held, its first download served');
select results_eq($$ select v ->> 'hold3_again', v ->> 'redownload3' from j where k = 'a2' $$,
  $$ values ('cancelled_sweep_debited'::text, 'transfer file refused: holds_debited_transfer'::text) $$,
  'A3: a second late line of the cancelled sweep holds the next one again');

-- A′: servicer-wide — a second dedicated EUR account (B) beside the main one (A)
-- (review round 1, tests-3) what « Virements » says of an account's sweep, as ops
create or replace function pg_temp.overview_of(p_account uuid) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.transfer_overview();
  reset role;
  return (select jsonb_build_object('sweep_hold', a ->> 'sweep_hold', 'sweep_preview_minor', a ->> 'sweep_preview_minor')
          from jsonb_array_elements(v -> 'accounts') a where (a ->> 'bank_account_id')::uuid = p_account);
end $$;
grant execute on all functions in schema pg_temp to authenticated;
create or replace function pg_temp.second_account(p_status text default 'active') returns void language plpgsql as $$
begin
  insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on)
  values (pg_temp.cg(), '00000000-0000-0000-0000-0000000000aa', 'client_funds', 'FR7630001007941234567890185',
          'TESTFRPPXXX', 'EUR', 'Fonds de tiers 2', 'camt053', '2026-01-01');
  perform pg_temp.lines('c9', private.paris_today(), '[]', null, null, 'camt053', pg_temp.cg(), 5000000);
end $$;
-- A′1, A′3: S1 of account A cancelled (its file cancelled whole), debited late; B's generation sweeps nothing — and so
-- once account A is closed
create or replace function pg_temp.sc_ap1() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.second_account();
  perform pg_temp.handed_out('f1', 'ap1-g1', 0);
  insert into t values ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
  perform pg_temp.cancel_whole('f1', 'ap1', 'b1');
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s1')))));
  v := v || jsonb_build_object('gen_b', pg_temp.gen_try('ap1-gb', pg_temp.cg()), 'ov_b', pg_temp.overview_of(pg_temp.cg()));
  update public.bank_account set status = 'closed', closed_on = private.paris_today(), closed_reason = 'compte clos (test)'
  where id = pg_temp.cf();
  v := v || jsonb_build_object('gen_b_closed', pg_temp.gen_try('ap1-gbc', pg_temp.cg()),
                               'ov_b_closed', pg_temp.overview_of(pg_temp.cg()));
  return v;
end $$;
insert into j select 'ap1', pg_temp.isolated('sc_ap1');
select results_eq($$ select v #>> '{gen_b,error}', v #>> '{gen_b,detail,sweep_hold}' from j where k = 'ap1' $$,
  $$ values ('transfer file refused: nothing_to_file'::text, 'cancelled_sweep_debited'::text) $$,
  'A′1: a cancelled sweep of one dedicated account debited late stops the servicer''s next sweep from another account (the share is servicer-wide)');
select results_eq($$ select v #>> '{gen_b_closed,error}', v #>> '{gen_b_closed,detail,sweep_hold}' from j where k = 'ap1' $$,
  $$ values ('transfer file refused: nothing_to_file'::text, 'cancelled_sweep_debited'::text) $$,
  'A′3: and so once that account is closed (its sweep can still be executed late)');
select results_eq($$ select v -> 'ov_b', v -> 'ov_b_closed' from j where k = 'ap1' $$,
  $$ values ('{"sweep_hold": "cancelled_sweep_debited", "sweep_preview_minor": "0"}'::jsonb,
             '{"sweep_hold": "cancelled_sweep_debited", "sweep_preview_minor": "0"}'::jsonb) $$,
  'A′4 (review round 1, tests-3): « Virements » proposes no sweep on the other account either (the hold generation applies), also once that account is closed');
-- A′2: the SW3 shape across the accounts: S2 of account B generated after S1 of A was cancelled, then S1 debited late
create or replace function pg_temp.sc_ap2() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb;
begin
  perform pg_temp.second_account();
  perform pg_temp.handed_out('f1', 'ap2-g1', 0);
  insert into t values ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
  perform pg_temp.cancel_whole('f1', 'ap2', 'b1');
  g := pg_temp.gen('01', 'ap2-gb', null, 'aal2', pg_temp.cg());
  insert into t values ('fb', (g ->> 'file_id')::uuid);
  perform pg_temp.write(pg_temp.v('fb'));
  insert into t values ('s2', (pg_temp.sweep(pg_temp.v('fb'))).id);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s1')))));
  insert into t select 'c1', pg_temp.chk(null);
  v := v || jsonb_build_object('sweep_b', g ->> 'sweep_minor', 'alerts', to_jsonb(pg_temp.already_debited('c1')),
                               'first', pg_temp.dl_try(pg_temp.v('fb')), 's2_after', pg_temp.status(pg_temp.v('s2')));
  return v;
end $$;
insert into j select 'ap2', pg_temp.isolated('sc_ap2');
select results_eq($$ select v ->> 'sweep_b', v -> 'alerts' @> '["sweep 12000 in_file"]', v #>> '{first,refused}',
                            coalesce(v #> '{first,blocked}', '[]') @> '[{"kind": "sweep", "reason": "cancelled_sweep_debited"}]',
                            v ->> 's2_after' from j where k = 'ap2' $$,
  $$ values ('12000'::text, true, 'file_blocked'::text, true, 'cancelled'::text) $$,
  'A′2: a sweep of another dedicated account made after that cancellation is alerted, and its file refused at its first download (file_blocked, cancelled_sweep_debited)');
-- A-batch: S1 cancelled alone out of its live file (the bank executed the payouts), then executed late as a batch line
-- of its own PmtInf (no SWP id) after its cancellation's window; S2 made meanwhile
create or replace function pg_temp.sc_ab() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb;
begin
  perform pg_temp.handed_out('f1', 'ab-g1', 0);
  insert into t values ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
  perform pg_temp.lines('b1', pg_temp.d(1), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.trid('r1')), 'day', pg_temp.d(0)),
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.trid('r2')), 'day', pg_temp.d(0))),
    pg_temp.d(0), pg_temp.after(1));
  v := v || jsonb_build_object('cancel_s1', pg_temp.try('01', pg_temp.req_tr('ab-rq', pg_temp.v('s1'))) || '/'
                                            || pg_temp.try('04', pg_temp.conf_tr('ab-cf', pg_temp.v('s1'))));
  g := pg_temp.gen('01', 'ab-g2');
  insert into t values ('f2', (g ->> 'file_id')::uuid);
  perform pg_temp.write(pg_temp.v('f2'));
  insert into t values ('s2', (pg_temp.sweep(pg_temp.v('f2'))).id);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'pmt_inf', pg_temp.pmt('f1', 2))));
  v := v || jsonb_build_object('sweep2', g ->> 'sweep_minor', 'first', pg_temp.dl_try(pg_temp.v('f2')));
  return v;
end $$;
insert into j select 'ab', pg_temp.isolated('sc_ab');
select results_eq($$ select v ->> 'cancel_s1', v ->> 'sweep2', v #>> '{first,refused}',
                            coalesce(v #> '{first,blocked}', '[]') @> '[{"kind": "sweep", "reason": "cancelled_sweep_debited"}]'
                     from j where k = 'ab' $$,
  $$ values ('requested/cancelled'::text, '12000'::text, 'file_blocked'::text, true) $$,
  'A (batch line): the cancelled sweep executed late as a batch line of its PmtInf holds the sweep made meanwhile');

-- B: the servicer's share proposed again once ops book the cancelled sweep's late debit ------------------------------
create or replace function pg_temp.sc_b() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb;
begin
  perform pg_temp.handed_out('f1', 'b-g1', 0);
  insert into t values ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
  perform pg_temp.cancel_whole('f1', 'b', 'b1');
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s1')))));
  g := pg_temp.gen('01', 'b-g2');
  v := v || jsonb_build_object('before', jsonb_build_array(g ->> 'sweep_minor', g ->> 'sweep_hold'),
    'book', pg_temp.bkx(pg_temp.ln('b2'), jsonb_build_array(pg_temp.pt('unplanned_sweep', pg_temp.v('s1'), 12000))));
  perform pg_temp.cypres_again('b-cy');
  g := pg_temp.gen('01', 'b-g3');
  insert into t select 'c1', pg_temp.chk(null);
  v := v || jsonb_build_object('after', jsonb_build_array(g ->> 'sweep_minor', g ->> 'sweep_hold'),
                               'alerts', to_jsonb(pg_temp.already_debited('c1')));
  -- S1 executed once more: no sweep again
  perform pg_temp.lines('b3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s1')))));
  g := pg_temp.gen('01', 'b-g4');
  v := v || jsonb_build_object('again', jsonb_build_array(g ->> 'sweep_minor', g ->> 'sweep_hold'));
  return v;
end $$;
insert into j select 'b', pg_temp.isolated('sc_b');
select results_eq($$ select v -> 'before', v ->> 'book', v -> 'after' from j where k = 'b' $$,
  $$ values ('["0", "cancelled_sweep_debited"]'::jsonb, 'ok'::text, '["12000", null]'::jsonb) $$,
  'B1: no sweep while the cancelled sweep''s late debit is open; once ops booked it, the servicer''s new share is proposed (−Σ 4679, less what is in flight)');
select is((select v -> 'alerts' from j where k = 'b'), '[]'::jsonb,
  'B2: the cancelled sweep, its late debit booked, is no longer alerted (nor the new sweep)');
select is((select v -> 'again' from j where k = 'b'), '["0", "cancelled_sweep_debited"]'::jsonb,
  'B3: a second late line of the cancelled sweep stops the next sweep again');
-- K3, B4, L4: the cancelled sweep executed late with no reference (a debit to our own account at its amount): it holds
-- the sweep made meanwhile and the next one; the options book it as that sweep's late debit, never as a new sweep
create or replace function pg_temp.sc_k3() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb;
begin
  perform pg_temp.handed_out('f1', 'k3-g1', 0);
  insert into t values ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
  perform pg_temp.cancel_whole('f1', 'k3', 'b1');
  g := pg_temp.gen('01', 'k3-g2');
  insert into t values ('f2', (g ->> 'file_id')::uuid);
  perform pg_temp.write(pg_temp.v('f2'));
  insert into t values ('s2', (pg_temp.sweep(pg_temp.v('f2'))).id);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'iban', pg_temp.own_iban())));
  v := v || jsonb_build_object('dcs', pg_temp.dcs() = jsonb_build_array(pg_temp.v('s1')),
    'hold_s2', pg_temp.hold(pg_temp.v('s2')),
    'proposal', pg_temp.prop(pg_temp.ln('b2')) = jsonb_build_array(jsonb_build_object(
                  'kind', 'unplanned_sweep', 'transfer_id', pg_temp.v('s1'), 'amount', '12000')),
    'no_transfer', pg_temp.why(pg_temp.ln('b2'), jsonb_build_array(pg_temp.pt('unplanned_sweep', null, 12000))));
  v := v || jsonb_build_object('book', pg_temp.bkx(pg_temp.ln('b2'), pg_temp.prop(pg_temp.ln('b2'))));
  v := v || jsonb_build_object('booked', (select jsonb_agg(jsonb_build_array(k.kind, k.transfer_id = pg_temp.v('s1')))
                                          from public.bank_line_booking k where k.bank_transaction_id = pg_temp.ln('b2')));
  perform pg_temp.cypres_again('k3-cy');
  g := pg_temp.gen('01', 'k3-g3');
  insert into t select 'c1', pg_temp.chk(null);
  v := v || jsonb_build_object('after', jsonb_build_array(g ->> 'sweep_minor', g ->> 'sweep_hold'),
                               'alerts', to_jsonb(pg_temp.already_debited('c1')));
  return v;
end $$;
insert into j select 'k3', pg_temp.isolated('sc_k3');
select results_eq($$ select (v ->> 'dcs')::boolean, v ->> 'hold_s2' from j where k = 'k3' $$,
  $$ values (true, 'cancelled_sweep_debited'::text) $$,
  'L4: a debit to our own account at a cancelled sweep''s amount, without our reference, is its possible late execution: no new sweep, the one made meanwhile held');
select results_eq($$ select (v ->> 'proposal')::boolean, v ->> 'no_transfer', v ->> 'book', v -> 'booked' from j where k = 'k3' $$,
  $$ values (true, 'sweep_in_flight_matches'::text, 'ok'::text, '[["unplanned_sweep", true]]'::jsonb) $$,
  'K3: rule 3b''s only candidate is that cancelled sweep: booked as its late debit (« Virement au compte propre » of it), never as a sweep without an order');
select results_eq($$ select v -> 'after', v -> 'alerts' from j where k = 'k3' $$,
  $$ values ('["12000", null]'::jsonb, '[]'::jsonb) $$,
  'B4: then the servicer''s new share is proposed again, nothing alerted');

-- C: G1c, a cancelled payout or refund debited late whatever its run's or refund's state -----------------------------
-- C1: the refused payout of the G1c state, its run cancelled, executed late as a batch line of its PmtInf: alerted until
-- ops book that line (« Virement hors reversement » of it)
create or replace function pg_temp.sc_c1() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.g1c_prefix('c1');
  perform pg_temp.lines('b2', pg_temp.d(3), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'pmt_inf', pg_temp.pmt('f1', 1))), pg_temp.d(2), pg_temp.after(3));
  insert into t select 'c1', pg_temp.chk(null);
  v := v || jsonb_build_object('before', to_jsonb(pg_temp.already_debited('c1')),
    'book', pg_temp.bkx(pg_temp.ln('b2'), jsonb_build_array(pg_temp.pt('unplanned_payout', pg_temp.v('m0'), 164000))));
  insert into t select 'c2', pg_temp.chk(null);
  v := v || jsonb_build_object('after', to_jsonb(pg_temp.already_debited('c2')),
                               'p0_after', pg_temp.raised('c2', 'cancelled_transfer_debited'));
  return v;
end $$;
insert into j select 'c1', pg_temp.isolated('sc_c1');
select results_eq($$ select v -> 'before', v ->> 'book', v -> 'after', (v ->> 'p0_after')::int from j where k = 'c1' $$,
  $$ values ('["payout 164000 cancelled"]'::jsonb, 'ok'::text, '[]'::jsonb, 0) $$,
  'C1: the refused payout executed late is alerted, its run cancelled; the alert stops once ops book that line');
-- C2, C3: a payout re-issued with its file (the re-issue ordered), then its run cancelled (the re-issue cancelled, never
-- filed), then the old one executed late — under its RMT id (C2), or with no reference at its amount (C3)
create or replace function pg_temp.c23(p_key text, p_line jsonb) returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f1', p_key || '-g1', 0);
  insert into t values ('m0', pg_temp.trid('r1'));
  v := v || jsonb_build_object('cancel', pg_temp.cancel_whole('f1', p_key, 'b1'),
                               'cancel_run', pg_temp.try('04', pg_temp.cancel_run(p_key || '-run', 'r1')));
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(p_line));
  insert into t select 'c1', pg_temp.chk(null);
  return v || jsonb_build_object('alerts', to_jsonb(pg_temp.already_debited('c1')));
end $$;
create or replace function pg_temp.sc_c2() returns jsonb language sql as $$
  select pg_temp.c23('c2', jsonb_build_object('amount', 164000, 'e2e', (select end_to_end_id from public.bank_transfer
                                                                         where id = pg_temp.trid('r1')))) $$;
create or replace function pg_temp.sc_c3() returns jsonb language sql as $$
  select pg_temp.c23('c3', jsonb_build_object('amount', 164000)) $$;
insert into j select 'c2', pg_temp.isolated('sc_c2');
insert into j select 'c3', pg_temp.isolated('sc_c3');
select results_eq($$ select v ->> 'cancel', v ->> 'cancel_run', v -> 'alerts' from j where k = 'c2' $$,
  $$ values ('requested/superseded'::text, 'cancelled'::text, '["payout 164000 cancelled"]'::jsonb) $$,
  'C2: a payout re-issued, its run then cancelled, executed late under its RMT id: alerted (the live end of its chain is gone)');
select is((select v -> 'alerts' from j where k = 'c3'), '["payout 164000 cancelled"]'::jsonb,
  'C3: and so when the late line carries none of our references (its amount, from its execution date)');
-- C4: a refund cancelled with its downloaded file, its request then cancelled, executed late under its RFD id
create or replace function pg_temp.sc_c4() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f0', 'c4-g0', 0);
  insert into j select 'rq', pg_temp.refund('71', 5000);
  perform pg_temp.handed_out('f1', 'c4-g1', 0);
  insert into t values ('q0', pg_temp.rft('rq'));
  v := v || jsonb_build_object('cancel', pg_temp.cancel_whole('f1', 'c4', 'b1'),
                               'cancel_refund', pg_temp.try('01', pg_temp.cancel_refund('c4-crf', 'rq')));
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 5000, 'e2e', pg_temp.e2e(pg_temp.v('q0')), 'kind', 'refund_out')));
  insert into t select 'c1', pg_temp.chk(null);
  return v || jsonb_build_object('alerts', to_jsonb(pg_temp.already_debited('c1')));
end $$;
insert into j select 'c4', pg_temp.isolated('sc_c4');
select results_eq($$ select v ->> 'cancel', v ->> 'cancel_refund', v -> 'alerts' from j where k = 'c4' $$,
  $$ values ('requested/superseded'::text, 'unmatched'::text, '["refund 5000 cancelled"]'::jsonb) $$,
  'C4: a refund cancelled with its file, its request cancelled, then executed late: alerted');

-- D: H-PAY — a debit with no reference and a refund in a downloaded file ---------------------------------------------
-- what the trigger's hint says (as 034's pg_temp.says)
create or replace function pg_temp.hpay_says(p_text text) returns text language sql as $$
  select concat_ws(',',
    case when p_text ~ '^refund refused: reissue_in_downloaded_file \| ' then 'refused' end,
    case when p_text ~ 'Ce débit ne porte aucune référence, et un remboursement de ce montant était dans le fichier TF-[0-9]{4}-[0-9]{6}, annulé après téléchargement : il peut en être l''exécution tardive'
         then 'may_be_cancelled' end,
    case when p_text ~ 'Il ne peut pas exécuter ce remboursement, dont le virement est dans le fichier TF-[0-9]{4}-[0-9]{6}, déjà téléchargé'
         then 'its_file' end,
    case when p_text ~ 'Ne le rattachez pas : attendez la ligne qui porte sa référence RFD ou celle de son lot, ou voyez avec la banque'
         then 'camt' end,
    case when p_text ~ 'Ce relevé ne porte pas nos références : demandez à la banque le détail de ce débit et prévenez le support'
         then 'csv' end) $$;
-- D1–D3: the old refund's file cancelled whole, a second refund of the payment in a downloaded file; a line with no
-- reference at the amount: the hint (camt.053 feed, then CSV), the link options, the second refund's own RFD line
create or replace function pg_temp.sc_d1() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.hpay_prefix('d1');
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 5000)));
  v := v || jsonb_build_object('camt', pg_temp.hpay_says(pg_temp.follow('r2', pg_temp.ln('b2'))));
  update public.bank_account set feed = 'csv' where id = pg_temp.cf();
  v := v || jsonb_build_object('csv', pg_temp.hpay_says(pg_temp.follow('r2', pg_temp.ln('b2'))));
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := v || jsonb_build_object('options', (select coalesce(jsonb_agg(r ->> 'refund_request_id'), '[]')
                                          from jsonb_array_elements(public.debit_link_options(pg_temp.ln('b2')) -> 'refunds') r));
  reset role;
  perform pg_temp.lines('b3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 5000, 'e2e', pg_temp.e2e(pg_temp.rft('r2')), 'kind', 'refund_out')));
  v := v || jsonb_build_object('own_line', pg_temp.follow('r2', pg_temp.ln('b3')));
  return v;
end $$;
insert into j select 'd1', pg_temp.isolated('sc_d1');
select results_eq($$ select v ->> 'camt', v ->> 'csv' from j where k = 'd1' $$,
  $$ values ('refused,may_be_cancelled,its_file,camt'::text, 'refused,may_be_cancelled,its_file,csv'::text) $$,
  'D1: the refusal says the line may be the cancelled refund''s late execution, and what to do by the account''s feed');
select is((select v -> 'options' from j where k = 'd1'), '[]'::jsonb,
  'D2: « Lier » does not offer that refund for such a line (the trigger would refuse it)');
select is((select v ->> 'own_line' from j where k = 'd1'), 'ok',
  'D3: the second refund''s own RFD line still executes it');
-- D4: the cancelled refund of payment 71 blocks a refund of another payment at its amount, never one at another amount
create or replace function pg_temp.sc_d4() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f0', 'd4-g0', 0);
  insert into j select 'rq', pg_temp.refund('71', 5000);
  perform pg_temp.handed_out('f1', 'd4-g1', 0);
  perform pg_temp.cancel_whole('f1', 'd4', 'b1');
  perform pg_temp.try('01', pg_temp.cancel_refund('d4-crf', 'rq'));
  insert into j select 'r3', pg_temp.refund('72', 5000);
  insert into j select 'r4', pg_temp.refund('73', 6000);
  perform pg_temp.handed_out('f2', 'd4-g2', 2);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 5000),
                                                                       jsonb_build_object('amount', 6000)));
  v := jsonb_build_object('same_amount', pg_temp.link('d4-l1', pg_temp.ln('b2', 1), 'refund', pg_temp.rq('r3')),
                          'other_amount', pg_temp.link('d4-l2', pg_temp.ln('b2', 2), 'refund', pg_temp.rq('r4')));
  return v || jsonb_build_object('r3', (select status from public.refund_request where id = pg_temp.rq('r3')),
                                 'r4', (select status from public.refund_request where id = pg_temp.rq('r4')));
end $$;
insert into j select 'd4', pg_temp.isolated('sc_d4');
select results_eq($$ select v ->> 'same_amount' ~ 'refund refused: reissue_in_downloaded_file', v ->> 'r3',
                            v ->> 'other_amount', v ->> 'r4' from j where k = 'd4' $$,
  $$ values (true, 'requested'::text, 'refund'::text, 'executed'::text) $$,
  'D4: a cancelled refund of the account at the line''s amount, of any payment, blocks the link (the debtor may be refunded twice); at another amount it does not');
-- D5: the first refund cancelled alone out of its live downloaded file (the bank executed the other refund of it)
create or replace function pg_temp.sc_d5() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f0', 'd5-g0', 0);
  insert into j select 'rq', pg_temp.refund('71', 5000);
  insert into j select 'r7', pg_temp.refund('72', 7000);
  perform pg_temp.handed_out('f1', 'd5-g1', 0);
  insert into t values ('q0', pg_temp.rft('rq'));
  perform pg_temp.lines('b1', pg_temp.d(1), jsonb_build_array(
    jsonb_build_object('amount', 7000, 'e2e', pg_temp.e2e(pg_temp.rft('r7')), 'kind', 'refund_out', 'day', pg_temp.d(0))),
    pg_temp.d(0), pg_temp.after(1));
  v := v || jsonb_build_object('cancel_q0', pg_temp.try('01', pg_temp.req_tr('d5-rq', pg_temp.v('q0'))) || '/'
                                            || pg_temp.try('04', pg_temp.conf_tr('d5-cf', pg_temp.v('q0'))),
                               'cancel_refund', pg_temp.try('01', pg_temp.cancel_refund('d5-crf', 'rq')));
  perform pg_temp.refund_again('r2', '71', 5000, 'd5-rfd2');
  perform pg_temp.handed_out('f2', 'd5-g2', 2);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 5000)));
  return v || jsonb_build_object('link', pg_temp.link('d5-l', pg_temp.ln('b2'), 'refund', pg_temp.rq('r2')),
                                 'f1', (pg_temp.fl(pg_temp.v('f1'))).status);
end $$;
insert into j select 'd5', pg_temp.isolated('sc_d5');
select results_eq($$ select v ->> 'cancel_q0', v ->> 'cancel_refund', v ->> 'f1',
                            v ->> 'link' ~ 'refund refused: reissue_in_downloaded_file' from j where k = 'd5' $$,
  $$ values ('requested/cancelled'::text, 'unmatched'::text, 'downloaded'::text, true) $$,
  'D5: so too when the first refund was cancelled alone out of its live downloaded file');
-- D6: an earlier refund whose file was never downloaded does not block (033's rule); D7: a refund whose transfer is
-- ordered (never filed) is executed by such a line, its transfer booked
create or replace function pg_temp.sc_d6() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f0', 'd6-g0', 0);
  insert into j select 'rq', pg_temp.refund('71', 5000);
  perform pg_temp.gen('01', 'd6-g1');
  v := v || jsonb_build_object('cancel_refund', pg_temp.try('01', pg_temp.cancel_refund('d6-crf', 'rq')));
  perform pg_temp.refund_again('r2', '71', 5000, 'd6-rfd2');
  perform pg_temp.handed_out('f2', 'd6-g2', 2);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 5000)));
  return v || jsonb_build_object('link', pg_temp.link('d6-l', pg_temp.ln('b2'), 'refund', pg_temp.rq('r2')));
end $$;
create or replace function pg_temp.sc_d7() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.hpay_prefix('d7', false);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 5000)));
  -- (review round 1, tests-5) « Lier » lists it
  v := jsonb_build_object('options', pg_temp.listed(pg_temp.ln('b2'), array['rq', 'r2']));
  v := v || jsonb_build_object('link', pg_temp.link('d7-l', pg_temp.ln('b2'), 'refund', pg_temp.rq('r2')));
  return v || jsonb_build_object('r2', (select status from public.refund_request where id = pg_temp.rq('r2')),
                                 'r2_transfer', pg_temp.status(pg_temp.rft('r2')));
end $$;
insert into j select 'd6', pg_temp.isolated('sc_d6');
insert into j select 'd7', pg_temp.isolated('sc_d7');
select results_eq($$ select v ->> 'cancel_refund', v ->> 'link' from j where k = 'd6' $$,
  $$ values ('unmatched'::text, 'refund'::text) $$,
  'D6: an earlier refund whose file was never downloaded does not block the line (never handed out: it cannot be executed)');
select results_eq($$ select v ->> 'link', v ->> 'r2', v ->> 'r2_transfer' from j where k = 'd7' $$,
  $$ values ('refund'::text, 'executed'::text, 'booked'::text) $$,
  'D7: a refund whose transfer is not handed out yet is executed by such a line, its transfer booked (no file to execute it again)');
select is((select v -> 'options' from j where k = 'd7'), '["r2"]'::jsonb,
  'D7 (review round 1, tests-5): « Lier » lists that refund of the same payment for the line (never the cancelled one''s request)');
-- D8: the cancelled refund's execution date is its downloaded file's: an earlier file superseded before download (an
-- earlier date) does not make a line before that date its execution
create or replace function pg_temp.sc_d8() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb;
begin
  perform pg_temp.handed_out('f0', 'd8-g0', 0);
  perform pg_temp.collect('71', 5000, pg_temp.d(0), false);
  perform pg_temp.as_user('01');
  set local role authenticated;
  insert into j select 'rq', public.request_refund(pg_temp.k('d8-rfd1'), pg_temp.pay('71'), '5000', null, null, 'other',
                                                   null, '5000', 'payeur inconnu');
  reset role;
  g := pg_temp.gen('01', 'd8-ga');
  insert into t values ('fa', (g ->> 'file_id')::uuid);
  perform pg_temp.backdate(pg_temp.v('fa'), pg_temp.d(1));
  perform pg_temp.handed_out('f1', 'd8-g1', 4);
  insert into t values ('q0', pg_temp.rft('rq'));
  v := v || jsonb_build_object('fa', (pg_temp.fl(pg_temp.v('fa'))).status,
                               'cancel', pg_temp.cancel_whole('f1', 'd8', 'b1', 4),
                               'cancel_refund', pg_temp.try('01', pg_temp.cancel_refund('d8-crf', 'rq')));
  perform pg_temp.refund_again('r2', '71', 5000, 'd8-rfd2');
  perform pg_temp.handed_out('f2', 'd8-g2', 2);
  perform pg_temp.lines('b2', pg_temp.d(3), jsonb_build_array(jsonb_build_object('amount', 5000)), pg_temp.d(3),
                        pg_temp.after(3));
  return v || jsonb_build_object('link', pg_temp.link('d8-l', pg_temp.ln('b2'), 'refund', pg_temp.rq('r2')));
end $$;
insert into j select 'd8', pg_temp.isolated('sc_d8');
select results_eq($$ select v ->> 'fa', v ->> 'cancel', v ->> 'cancel_refund', v ->> 'link' from j where k = 'd8' $$,
  $$ values ('superseded'::text, 'requested/superseded'::text, 'unmatched'::text, 'refund'::text) $$,
  'D8: a line dated before the cancelled refund''s execution date in its downloaded file is not its execution (an earlier file superseded before download does not count)');
-- D9: the CSV feed's stuck state: the line refused for good, the second refund's file not cancellable, both alerted
create or replace function pg_temp.sc_d9() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  update public.bank_account set feed = 'csv' where id = pg_temp.cf();
  perform pg_temp.hpay_prefix('d9', true, 'csv', pg_temp.d(0));
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 5000, 'day', pg_temp.d(15))), pg_temp.d(15), null, 'csv');
  insert into t select 'c1', pg_temp.chk(null);
  return v || jsonb_build_object('link', pg_temp.link('d9-l', pg_temp.ln('b2'), 'refund', pg_temp.rq('r2')),
                                 'cancel_f2', pg_temp.try('01', pg_temp.req_file('d9-rq2', 'f2')),
                                 'unbooked', pg_temp.raised('c1', 'bank_line_unbooked'),
                                 'alerts', to_jsonb(pg_temp.already_debited('c1')));
end $$;
insert into j select 'd9', pg_temp.isolated('sc_d9');
select results_eq($$ select v ->> 'link' ~ 'refund refused: reissue_in_downloaded_file', v ->> 'cancel_f2',
                            (v ->> 'unbooked')::int > 0, v -> 'alerts' @> '["refund 5000 cancelled"]' from j where k = 'd9' $$,
  $$ values (true, 'transfer file refused: unreferenced_debit_open'::text, true, true) $$,
  'D9: on a feed without our references, the line and the second refund''s file stay « en cours » — unbooked (alerted) and the cancelled refund alerted, until the bank details the debit');

-- K: rule 3b's (iv) — a refund or a sweep cancelled out of a downloaded file is a candidate ---------------------------
-- a refund of payment 71 of p_amount alone in F1 (the payouts and the sweep in F0, downloaded before), F1 cancelled
-- whole, the refund cancelled; then a line with no reference at its amount
create or replace function pg_temp.k_prefix(p_key text, p_amount bigint) returns void language plpgsql as $$
begin
  perform pg_temp.handed_out('f0', p_key || '-g0', 0);
  insert into j select 'rq', pg_temp.refund('71', p_amount);
  perform pg_temp.handed_out('f1', p_key || '-g1', 0);
  insert into t values ('q0', pg_temp.rft('rq'));
  perform pg_temp.cancel_whole('f1', p_key, 'b1');
  perform pg_temp.try('01', pg_temp.cancel_refund(p_key || '-crf', 'rq'));
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', p_amount)));
end $$;
-- K1: beside Martin's payout in flight at that amount: ambiguous
create or replace function pg_temp.sc_k1() returns jsonb language plpgsql as $$
declare o jsonb;
begin
  perform pg_temp.k_prefix('k1', 164000);
  o := pg_temp.op(pg_temp.ln('b2'));
  return jsonb_build_object('refusal', o ->> 'refusal', 'proposals', jsonb_array_length(o -> 'proposals'),
    'payout', pg_temp.why(pg_temp.ln('b2'), jsonb_build_array(pg_temp.pt('payout', pg_temp.trid('r1'), 164000))));
end $$;
-- K2: alone: nothing proposed (no booking kind for a cancelled refund's late debit yet: S25), « Frais » and « Classer »
-- refused; a debtor payment's return and its loss still allowed (OQ-86)
create or replace function pg_temp.sc_k2() returns jsonb language plpgsql as $$
declare o jsonb;
begin
  perform pg_temp.k_prefix('k2', 5000);
  -- the same debit to the refund's payee IBAN (the payer's, which is also Martin's payout IBAN)
  perform pg_temp.lines('b3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 5000, 'iban', pg_temp.martin_iban())));
  o := pg_temp.op(pg_temp.ln('b2'));
  return jsonb_build_object('refusal', o ->> 'refusal', 'proposals', jsonb_array_length(o -> 'proposals'),
    'unplanned', pg_temp.why(pg_temp.ln('b3'), jsonb_build_array(
                   pg_temp.pt('unplanned_payout', null, 5000, '00000000-0000-0000-0000-0000000000a1'))),
    'fee', coalesce(private.link_debit_guard(pg_temp.ln('b2'), 'fee', null), 'ok'),
    'explained', coalesce(private.link_debit_guard(pg_temp.ln('b2'), 'explained', null), 'ok'),
    'return', coalesce(private.link_debit_guard(pg_temp.ln('b2'), 'return', null), 'ok'),
    'loss', coalesce(private.link_debit_guard(pg_temp.ln('b2'), 'loss', null), 'ok'));
end $$;
insert into j select 'k1', pg_temp.isolated('sc_k1');
insert into j select 'k2', pg_temp.isolated('sc_k2');
select results_eq($$ select v ->> 'refusal', (v ->> 'proposals')::int, v ->> 'payout' from j where k = 'k1' $$,
  $$ values ('line_ambiguous'::text, 0, 'line_ambiguous'::text) $$,
  'K1: a debit with no reference at a payout''s amount, beside a refund cancelled out of a downloaded file at that amount: ambiguous (not booked as the payout)');
select results_eq($$ select v ->> 'refusal', (v ->> 'proposals')::int, v ->> 'unplanned', v ->> 'fee', v ->> 'explained',
                            v ->> 'return', v ->> 'loss' from j where k = 'k2' $$,
  $$ values ('cancelled_transfer_matches'::text, 0, 'cancelled_transfer_matches'::text, 'payout_candidate'::text,
             'payout_candidate'::text, 'ok'::text, 'ok'::text) $$,
  'K2: the cancelled refund alone: nothing proposed (cancelled_transfer_matches), never a fee nor classified; a debtor payment''s return and loss still allowed');

-- L: a debit carrying none of our references, a possible late execution of a cancelled transfer -----------------------
-- L1: CSV feed, F1 cancelled whole (Martin's payout re-issued, ordered), a line with no reference at its amount
create or replace function pg_temp.sc_l1() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb;
begin
  update public.bank_account set feed = 'csv' where id = pg_temp.cf();
  perform pg_temp.handed_out('f1', 'l1-g1', 0);
  insert into t values ('m0', pg_temp.trid('r1'));
  v := v || jsonb_build_object('cancel', pg_temp.cancel_whole('f1', 'l1', 'b1', 0, 'csv'));
  insert into t values ('m1', pg_temp.trid('r1'));
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 164000)),
                        pg_temp.d(10), null, 'csv');
  insert into j select 'g', pg_temp.gen('01', 'l1-g2');
  insert into t select 'c1', pg_temp.chk(null);
  v := v || jsonb_build_object('held', to_jsonb(pg_temp.held('g')),
                               'cancel_run', pg_temp.try('04', pg_temp.cancel_run('l1-run', 'r1')),
                               'alerts', to_jsonb(pg_temp.already_debited('c1')));
  return v;
end $$;
insert into j select 'l1', pg_temp.isolated('sc_l1');
select results_eq($$ select v ->> 'cancel', v -> 'held', v ->> 'cancel_run', v -> 'alerts' @> '["payout 164000 ordered"]'
                     from j where k = 'l1' $$,
  $$ values ('requested/superseded'::text, '["payout 164000 already_debited"]'::jsonb,
             'remittance run refused: transfer_already_debited'::text, true) $$,
  'L1: on a feed without our references, a line at the cancelled payout''s amount holds its re-issue, refuses its run''s cancellation and is alerted');
-- L2: that line decided a duplicate of another: no longer a debit, the hold lifts
create or replace function pg_temp.sc_l2() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f1', 'l2-g1', 0);
  perform pg_temp.cancel_whole('f1', 'l2', 'b1');
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'kind', 'suspected_duplicate')));
  v := v || jsonb_build_object('before', pg_temp.hold(pg_temp.trid('r1')));
  insert into public.bank_duplicate_resolution (bank_transaction_id, organization_id, bank_account_id, decision, reason,
                                                decided_by)
  values (pg_temp.ln('b2'), '00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), 'duplicate', 'doublon (test)',
          '10000000-0000-0000-0000-000000000001');
  return v || jsonb_build_object('after', coalesce(pg_temp.hold(pg_temp.trid('r1')), 'none'));
end $$;
insert into j select 'l2', pg_temp.isolated('sc_l2');
select results_eq($$ select v ->> 'before', v ->> 'after' from j where k = 'l2' $$,
  $$ values ('already_debited'::text, 'none'::text) $$,
  'L2: held while the line is unresolved; decided a duplicate, it is no movement: the hold lifts');
-- L3: the refund twin: the re-issued refund held, the refund not cancellable, the line linked to it executes it
create or replace function pg_temp.sc_l3() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f0', 'l3-g0', 0);
  insert into j select 'rq', pg_temp.refund('71', 5000);
  perform pg_temp.handed_out('f1', 'l3-g1', 0);
  perform pg_temp.cancel_whole('f1', 'l3', 'b1');
  insert into t values ('q1', pg_temp.rft('rq'));
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 5000)));
  v := v || jsonb_build_object('hold', pg_temp.hold(pg_temp.v('q1')),
                               'cancel_refund', pg_temp.try('01', pg_temp.cancel_refund('l3-crf', 'rq')));
  v := v || jsonb_build_object('link', pg_temp.link('l3-l', pg_temp.ln('b2'), 'refund', pg_temp.rq('rq')));
  v := v || jsonb_build_object('refund', (select status from public.refund_request where id = pg_temp.rq('rq')),
                               'q1', pg_temp.status(pg_temp.v('q1')));
  -- (review round 1, tests-2) the line linked: no longer the cancelled refund's open late debit
  insert into t select 'c1', pg_temp.chk(null);
  v := v || jsonb_build_object('alerts_after', to_jsonb(pg_temp.already_debited('c1')));
  return v;
end $$;
insert into j select 'l3', pg_temp.isolated('sc_l3');
select results_eq($$ select v ->> 'hold', v ->> 'cancel_refund', v ->> 'link', v ->> 'refund', v ->> 'q1' from j where k = 'l3' $$,
  $$ values ('already_debited'::text, 'refund refused: already_debited'::text, 'refund'::text, 'executed'::text,
             'booked'::text) $$,
  'L3: the refund''s re-issue held, the refund not cancelled (the debtor may have it); the line linked to the refund executes it, its re-issue booked');
select is((select v -> 'alerts_after' from j where k = 'l3'), '[]'::jsonb,
  'L7 (review round 1, tests-2): once linked to the chain''s refund, the line is no longer the cancelled refund''s open late debit (nothing alerted)');
-- L5: the lines that do not count, and the two that do
create or replace function pg_temp.sc_l5() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f1', 'l5-g1', 0);
  insert into t values ('m0', pg_temp.trid('r1'));
  perform pg_temp.cancel_whole('f1', 'l5', 'b1');
  perform pg_temp.handed_out('f2', 'l5-g2', 2);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'day', pg_temp.bd(19)),
    jsonb_build_object('amount', 164001),
    jsonb_build_object('amount', 164000, 'iban', pg_temp.lilas_iban()),
    jsonb_build_object('amount', 164000, 'e2e', 'FOREIGN-E2E-0001', 'iban', pg_temp.lilas_iban()),
    jsonb_build_object('amount', 164000, 'e2e', 'FOREIGN-E2E-0002', 'pmt_inf', pg_temp.pmt('f2', 1),
                       'iban', pg_temp.martin_iban())), pg_temp.bd(19));
  v := v || jsonb_build_object('none', pg_temp.q(format(
    'select count(*) from private.transfer_unreferenced_lines(%L)', pg_temp.v('m0'))));
  perform pg_temp.lines('b3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', 'FOREIGN-E2E-0003', 'iban', pg_temp.martin_iban()),
    jsonb_build_object('amount', 164000, 'e2e', 'FOREIGN-E2E-0004', 'pmt_inf', pg_temp.pmt('f1', 1),
                       'iban', pg_temp.martin_iban())));
  return v || jsonb_build_object('two', pg_temp.q(format(
    'select count(*) from private.transfer_unreferenced_lines(%L)', pg_temp.v('m0'))));
end $$;
insert into j select 'l5', pg_temp.isolated('sc_l5');
select results_eq($$ select v ->> 'none', v ->> 'two' from j where k = 'l5' $$,
  $$ values ('0'::text, '2'::text) $$,
  'L5: before its execution date, at another amount, to another IBAN (with or without a foreign id), naming another lot of ours: not its debit; a foreign id to its payee, or naming its own lot: possibly it');
-- L6: a transfer in its live downloaded file executed by such a line: not « debited before » (that line is its own
-- execution); its re-download as today
create or replace function pg_temp.sc_l6() returns jsonb language plpgsql as $$
begin
  perform pg_temp.handed_out('f1', 'l6-g1', 0);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 164000)));
  return jsonb_build_object('debited_before', private.transfer_debited_before(pg_temp.trid('r1')),
                            'redownload', pg_temp.redownload('f1'));
end $$;
insert into j select 'l6', pg_temp.isolated('sc_l6');
select results_eq($$ select (v ->> 'debited_before')::boolean, v ->> 'redownload' from j where k = 'l6' $$,
  $$ values (false, '2'::text) $$,
  'L6: a transfer still in its live downloaded file, executed by a line with no reference, is not held; its file''s re-download is served as before');

-- M: holds beyond the replaces chain ---------------------------------------------------------------------------------
-- M1, M6: the G1c state, then Martin's next run (its collection again, z ordered); the refused payout executed late as
-- a batch line: z held and alerted (Lilas' payout not); ops cancel that run, then book the line: the debit no longer open
create or replace function pg_temp.sc_m1() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.g1c_prefix('m1');
  insert into t select 'r1b', pg_temp.run2('a1', '{"01": "200000"}', 36000, 6000, 15, 100, 'm1-r2');
  insert into t values ('z', pg_temp.trid('r1b'));
  perform pg_temp.lines('b2', pg_temp.d(3), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'pmt_inf', pg_temp.pmt('f1', 1))), pg_temp.d(2), pg_temp.after(3));
  insert into j select 'g', pg_temp.gen_try('m1-g2');
  insert into t select 'c1', pg_temp.chk(null);
  v := v || jsonb_build_object('z', pg_temp.status(pg_temp.v('z')), 'held', to_jsonb(pg_temp.held('g')),
    'alert', (select r.details ->> 'reason' from public.payment_check_result r
              where r.run_id = pg_temp.v('c1') and r.code = 'transfer_already_debited' and r.subject_id = pg_temp.v('z')),
    'lilas', coalesce(pg_temp.hold(pg_temp.trid('r2')), 'none'));
  v := v || jsonb_build_object('cancel_r2', pg_temp.try('04', pg_temp.cancel_run('m1-run2', 'r1b')),
    'book', pg_temp.bkx(pg_temp.ln('b2'), jsonb_build_array(pg_temp.pt('unplanned_payout', pg_temp.v('m0'), 164000))));
  return v || jsonb_build_object('open_after', pg_temp.q(format('select private.transfer_late_debit_open(%L)',
                                                                pg_temp.v('m0'))));
end $$;
insert into j select 'm1', pg_temp.isolated('sc_m1');
select results_eq($$ select v ->> 'z', v -> 'held', v ->> 'alert' from j where k = 'm1' $$,
  $$ values ('ordered'::text, '["payout 164000 client_payout_debited_late"]'::jsonb, 'client_payout_debited_late'::text) $$,
  'M1: a cancelled payout of the client (its run ended) shows an open late debit: the client''s next payout is held and alerted (its collections may be paid twice)');
select results_eq($$ select v ->> 'cancel_r2', v ->> 'book', v ->> 'open_after' from j where k = 'm1' $$,
  $$ values ('cancelled'::text, 'ok'::text, 'false'::text) $$,
  'M1: the exit — that run cancelled, the late line booked (« Virement hors reversement »): the debit is no longer open');
select isnt((select v ->> 'lilas' from j where k = 'm1'), 'client_payout_debited_late',
  'M6: another client''s payout is not held');
-- M2: the same with the late line carrying none of our references
create or replace function pg_temp.sc_m2() returns jsonb language plpgsql as $$
begin
  perform pg_temp.g1c_prefix('m2');
  insert into t select 'r1b', pg_temp.run2('a1', '{"01": "200000"}', 36000, 6000, 15, 100, 'm2-r2');
  perform pg_temp.lines('b2', pg_temp.d(3), jsonb_build_array(jsonb_build_object('amount', 164000)), pg_temp.d(2),
                        pg_temp.after(3));
  insert into j select 'g', pg_temp.gen_try('m2-g2');
  return jsonb_build_object('held', to_jsonb(pg_temp.held('g')));
end $$;
insert into j select 'm2', pg_temp.isolated('sc_m2');
select is((select v -> 'held' from j where k = 'm2'), '["payout 164000 client_payout_debited_late"]'::jsonb,
  'M2: and so when the late line carries none of our references');
-- M4: z already in a generated file when the late debit arrives (its first download supersedes it, z held again), or in
-- a downloaded one (its re-download refused, z alerted in_file)
create or replace function pg_temp.m4(p_key text, p_download boolean) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb;
begin
  perform pg_temp.g1c_prefix(p_key);
  insert into t select 'r1b', pg_temp.run2('a1', '{"01": "200000"}', 36000, 6000, 15, 100, p_key || '-r2');
  insert into t values ('z', pg_temp.trid('r1b'));
  g := pg_temp.gen('01', p_key || '-g2');
  insert into t values ('f2', (g ->> 'file_id')::uuid);
  perform pg_temp.write(pg_temp.v('f2'));
  if p_download then
    perform pg_temp.download('01', pg_temp.v('f2'));
  end if;
  perform pg_temp.lines('b2', pg_temp.d(3), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'pmt_inf', pg_temp.pmt('f1', 1))), pg_temp.d(2), pg_temp.after(3));
  if not p_download then
    v := v || jsonb_build_object('first', pg_temp.dl_try(pg_temp.v('f2')));
    return v || jsonb_build_object('z_after', pg_temp.status(pg_temp.v('z')), 'hold', pg_temp.hold(pg_temp.v('z')));
  end if;
  insert into t select 'c1', pg_temp.chk(null);
  return v || jsonb_build_object('redownload', pg_temp.redownload('f2'),
    'alert', (select (r.details ->> 'status') || ' ' || (r.details ->> 'reason') from public.payment_check_result r
              where r.run_id = pg_temp.v('c1') and r.code = 'transfer_already_debited' and r.subject_id = pg_temp.v('z')));
end $$;
create or replace function pg_temp.sc_m4a() returns jsonb language sql as $$ select pg_temp.m4('m4a', false) $$;
create or replace function pg_temp.sc_m4b() returns jsonb language sql as $$ select pg_temp.m4('m4b', true) $$;
insert into j select 'm4', pg_temp.isolated('sc_m4a');
insert into j select 'm4b', pg_temp.isolated('sc_m4b');
select results_eq($$ select v #>> '{first,refused}',
                            coalesce(v #> '{first,blocked}', '[]') @> '[{"kind": "payout", "reason": "client_payout_debited_late"}]',
                            v ->> 'z_after', v ->> 'hold' from j where k = 'm4' $$,
  $$ values ('file_blocked'::text, true, 'ordered'::text, 'client_payout_debited_late'::text) $$,
  'M4: in a generated file, its first download refuses the file (file_blocked), the payout re-queued, held');
select results_eq($$ select v ->> 'redownload', v ->> 'alert' from j where k = 'm4b' $$,
  $$ values ('transfer file refused: holds_debited_transfer'::text, 'in_file client_payout_debited_late'::text) $$,
  'M4: in a downloaded file, its re-download is refused and it is alerted');
-- M5: the refund twin — the payment's first refund cancelled with its downloaded file and cancelled, its second refund
-- ordered; the first one executed late (its RFD id, or no reference): the second held
create or replace function pg_temp.m5(p_key text, p_rfd boolean) returns jsonb language plpgsql as $$
begin
  perform pg_temp.hpay_prefix(p_key, false);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(case when p_rfd
    then jsonb_build_object('amount', 5000, 'e2e', pg_temp.e2e(pg_temp.v('q0')), 'kind', 'refund_out')
    else jsonb_build_object('amount', 5000) end));
  insert into j select 'g', pg_temp.gen_try(p_key || '-g2');
  return jsonb_build_object('hold', pg_temp.hold(pg_temp.rft('r2')), 'held', to_jsonb(pg_temp.held('g')));
end $$;
create or replace function pg_temp.sc_m5a() returns jsonb language sql as $$ select pg_temp.m5('m5a', true) $$;
create or replace function pg_temp.sc_m5b() returns jsonb language sql as $$ select pg_temp.m5('m5b', false) $$;
insert into j select 'm5a', pg_temp.isolated('sc_m5a');
insert into j select 'm5b', pg_temp.isolated('sc_m5b');
select results_eq($$ select a.v ->> 'hold', a.v -> 'held', b.v ->> 'hold' from j a, j b where a.k = 'm5a' and b.k = 'm5b' $$,
  $$ values ('payment_refund_debited_late'::text, '["refund 5000 payment_refund_debited_late"]'::jsonb,
             'payment_refund_debited_late'::text) $$,
  'M5: a payment''s cancelled refund executed late (its RFD id, or no reference) holds the payment''s other refund (the debtor may be refunded twice)');

-- N: the cancellation evidence sees debits carrying none of our references -------------------------------------------
-- N1–N3, N7: a CSV-fed file the bank executed by lines with no reference (one per transfer), its window covered
create or replace function pg_temp.sc_n1() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  update public.bank_account set feed = 'csv' where id = pg_temp.cf();
  perform pg_temp.handed_out('f1', 'n1-g1', 0);
  perform pg_temp.lines('b1', pg_temp.d(2), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'day', pg_temp.d(0)), jsonb_build_object('amount', 419840, 'day', pg_temp.d(0)),
    jsonb_build_object('amount', 12000, 'day', pg_temp.d(0))), pg_temp.d(0), pg_temp.after(2), 'csv');
  v := v || jsonb_build_object('request', pg_temp.try('01', pg_temp.req_file('n1-rq', 'f1')),
    'rejected', pg_temp.try('01', format($q$ select public.request_transfer_file_cancellation(%L, %L, %s, 'Rejeté', 'rejected_by_bank') ->> 'status' $q$,
                                         pg_temp.k('n1-rq2'), pg_temp.v('f1'), (pg_temp.fl(pg_temp.v('f1'))).version)),
    'from', pg_temp.ev('f1', null, 'unreferenced_from'), 'martin', pg_temp.status(pg_temp.trid('r1')));
  -- N2: Martin's line booked as his payout (rule 3b (i)): his transfer booked
  v := v || jsonb_build_object('book', pg_temp.bkx(pg_temp.ln('b1', 1), pg_temp.prop(pg_temp.ln('b1', 1))));
  return v || jsonb_build_object('request_booked', pg_temp.try('01', pg_temp.req_file('n1-rq3', 'f1')));
end $$;
insert into j select 'n1', pg_temp.isolated('sc_n1');
select results_eq($$ select v ->> 'request', v ->> 'from', v ->> 'martin' from j where k = 'n1' $$,
  $$ values ('transfer file refused: unreferenced_debit_open'::text, pg_temp.d(0)::text, 'in_file'::text) $$,
  'N1: a file the bank executed by lines with no reference (a CSV feed) is not cancelled on evidence: unreferenced_debit_open, nothing re-issued; the card says from when');
select is((select v ->> 'rejected' from j where k = 'n1'), 'transfer file refused: unreferenced_debit_open',
  'N7: whatever the attestation (rejected by the bank)');
select results_eq($$ select v ->> 'book', v ->> 'request_booked' from j where k = 'n1' $$,
  $$ values ('ok'::text, 'transfer file refused: debit_seen'::text) $$,
  'N2: once one of those lines is booked as its payout, the file shows a debit: debit_seen');
create or replace function pg_temp.sc_n3() returns jsonb language plpgsql as $$
begin
  update public.bank_account set feed = 'csv' where id = pg_temp.cf();
  perform pg_temp.handed_out('f1', 'n3-g1', 0);
  -- (review round 1, tests-5) and a line at the payouts' PmtInf sum (583 840) dated before the file's execution date
  perform pg_temp.lines('b1', pg_temp.d(2), jsonb_build_array(
    jsonb_build_object('amount', 164001, 'day', pg_temp.d(0)), jsonb_build_object('amount', 164000, 'day', pg_temp.bd(19)),
    jsonb_build_object('amount', 583840, 'day', pg_temp.bd(19))),
    pg_temp.bd(19), pg_temp.after(2), 'csv');
  return jsonb_build_object('request', pg_temp.try('01', pg_temp.req_file('n3-rq', 'f1')));
end $$;
insert into j select 'n3', pg_temp.isolated('sc_n3');
select is((select v ->> 'request' from j where k = 'n3'), 'requested',
  'N3: a line at another amount, or before the file''s execution date (one transfer''s amount or a PmtInf''s sum), does not block it');
-- N4: one transfer of a file executed in part (a camt.053 entry without references at its amount): refused
create or replace function pg_temp.sc_n4() returns jsonb language plpgsql as $$
begin
  perform pg_temp.handed_out('f1', 'n4-g1', 0);
  perform pg_temp.lines('b1', pg_temp.d(1), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.trid('r2')), 'day', pg_temp.d(0)),
    jsonb_build_object('amount', 164000, 'day', pg_temp.d(0))), pg_temp.d(0), pg_temp.after(1));
  return jsonb_build_object('request', pg_temp.try('01', pg_temp.req_tr('n4-rq', pg_temp.trid('r1'))));
end $$;
insert into j select 'n4', pg_temp.isolated('sc_n4');
select is((select v ->> 'request' from j where k = 'n4'), 'transfer refused: unreferenced_debit_open',
  'N4: one transfer is not cancelled while a line without our references at its amount may be its execution');
-- N5: a line with no reference at the sum of a PmtInf of the file (a bank ignoring BtchBookg false)
create or replace function pg_temp.sc_n5() returns jsonb language plpgsql as $$
begin
  perform pg_temp.handed_out('f1', 'n5-g1', 0);
  perform pg_temp.lines('b1', pg_temp.d(1), jsonb_build_array(jsonb_build_object('amount', 583840, 'day', pg_temp.d(0))),
                        pg_temp.d(0), pg_temp.after(1));
  return jsonb_build_object('request', pg_temp.try('01', pg_temp.req_file('n5-rq', 'f1')));
end $$;
insert into j select 'n5', pg_temp.isolated('sc_n5');
select is((select v ->> 'request' from j where k = 'n5'), 'transfer file refused: unreferenced_debit_open',
  'N5: nor while a line with no reference at the sum of one of its PmtInfs may be its batch');
-- N6: a line imported between the request and its confirmation: the confirmation refused
create or replace function pg_temp.sc_n6() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f1', 'n6-g1', 0);
  perform pg_temp.lines('b1', pg_temp.d(1), '[]', pg_temp.d(0), pg_temp.after(1));
  v := v || jsonb_build_object('request', pg_temp.try('01', pg_temp.req_file('n6-rq', 'f1')));
  perform pg_temp.lines('b2', pg_temp.d(1), jsonb_build_array(jsonb_build_object('amount', 164000)), pg_temp.d(1),
                        pg_temp.after(1));
  return v || jsonb_build_object('confirm', pg_temp.try('04', pg_temp.conf_file('n6-cf', 'f1')));
end $$;
insert into j select 'n6', pg_temp.isolated('sc_n6');
select results_eq($$ select v ->> 'request', v ->> 'confirm' from j where k = 'n6' $$,
  $$ values ('requested'::text, 'transfer file refused: unreferenced_debit_open'::text) $$,
  'N6: the confirmation reads the evidence again: a line imported since refuses it');

-- Review round 1 (ADR-0014 « M2c-6b-3a review fixes ») ----------------------------------------------------------------
-- RF1 (DP-1): a refund of payment 71 cancelled with its downloaded file (q0, re-issued q1, ordered), a refund of another
-- payment (72) at its amount, ordered; a debit with no reference at that amount may be q0's late execution: it never
-- executes the other payment's refund (its payer would be shown refunded, q1 released and the first payer paid twice);
-- it still executes the same payment's (M's exit). RF1b: each refund to its payer's own IBAN, the line naming q0's.
create or replace function pg_temp.rf1(p_key text, p_iban_q text, p_iban_r text, p_line_iban text) returns jsonb
language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f0', p_key || '-g0', 0);
  insert into j select 'rq', pg_temp.refund_to('71', 5000, p_iban_q, p_key || '-rfd1');
  perform pg_temp.handed_out('f1', p_key || '-g1', 0);
  insert into t values ('q0', pg_temp.rft('rq'));
  perform pg_temp.cancel_whole('f1', p_key, 'b1');
  insert into t values ('q1', pg_temp.rft('rq'));
  insert into j select 'r3', pg_temp.refund_to('72', 5000, p_iban_r, p_key || '-rfd3');
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_strip_nulls(jsonb_build_object('amount', 5000, 'iban', p_line_iban))));
  v := v || jsonb_build_object('q1', pg_temp.status(pg_temp.v('q1')), 'r3', pg_temp.status(pg_temp.rft('r3')),
                               'listed', pg_temp.listed(pg_temp.ln('b2'), array['rq', 'r3']),
                               'link_r3', pg_temp.link(p_key || '-l3', pg_temp.ln('b2'), 'refund', pg_temp.rq('r3')));
  v := v || jsonb_build_object('r3_after', (select status from public.refund_request where id = pg_temp.rq('r3')),
                               'hold_q1', pg_temp.hold(pg_temp.v('q1')),
                               'link_rq', pg_temp.link(p_key || '-lq', pg_temp.ln('b2'), 'refund', pg_temp.rq('rq')));
  return v || jsonb_build_object('rq_after', (select status from public.refund_request where id = pg_temp.rq('rq')),
                                 'q1_after', pg_temp.status(pg_temp.v('q1')));
end $$;
create or replace function pg_temp.sc_rf1() returns jsonb language sql as $$ select pg_temp.rf1('rf1', null, null, null) $$;
create or replace function pg_temp.sc_rf1b() returns jsonb language sql as $$
  select pg_temp.rf1('rf1b', 'DE89370400440532013000', 'NL91ABNA0417164300', 'DE89370400440532013000') $$;
insert into j select 'rf1', pg_temp.isolated('sc_rf1');
insert into j select 'rf1b', pg_temp.isolated('sc_rf1b');
select results_eq($$ select v ->> 'q1', v ->> 'r3', v -> 'listed', v ->> 'link_r3' ~ 'refund refused: cancelled_transfer_matches',
                            v ->> 'r3_after', v ->> 'hold_q1', v ->> 'link_rq', v ->> 'rq_after', v ->> 'q1_after'
                     from j where k = 'rf1' $$,
  $$ values ('ordered'::text, 'ordered'::text, '["rq"]'::jsonb, true, 'requested'::text, 'already_debited'::text,
             'refund'::text, 'executed'::text, 'booked'::text) $$,
  'RF1 (DP-1): a debit with no reference that may be a cancelled refund''s late execution never executes a refund of another payment, even one not handed out (not listed, refused); the re-issue stays held; the same payment''s refund still takes it');
select results_eq($$ select v -> 'listed', v ->> 'link_r3' ~ 'refund refused: cancelled_transfer_matches', v ->> 'r3_after',
                            v ->> 'link_rq' from j where k = 'rf1b' $$,
  $$ values ('["rq"]'::jsonb, true, 'requested'::text, 'refund'::text) $$,
  'RF1b (DP-1): and so when the line names the cancelled refund''s payee IBAN (never the other refund''s)');
-- RF2 (DP-2): the G1c state (Martin's payout m0 cancelled after download, its run cancelled), a refund of another payment
-- of m0's amount in a downloaded file, Martin's next run (z ordered); a debit with no reference at that amount may be
-- m0's late execution: « Lier » never takes it as that refund (z would be released: the client paid twice)
create or replace function pg_temp.sc_rf2() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.g1c_prefix('rf2');
  insert into j select 'rf', pg_temp.refund('75', 164000);
  perform pg_temp.handed_out('f2', 'rf2-g2', 2);
  insert into t select 'r1b', pg_temp.run2('a1', '{"01": "200000"}', 36000, 6000, 15, 100, 'rf2-r2');
  insert into t values ('z', pg_temp.trid('r1b'));
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 164000)));
  v := v || jsonb_build_object('rf_in_f2', pg_temp.file_of(pg_temp.rft('rf')) = pg_temp.v('f2'),
    'listed', pg_temp.listed(pg_temp.ln('b2'), array['rf']),
    'follow', pg_temp.follow('rf', pg_temp.ln('b2')),
    'link', pg_temp.link('rf2-l', pg_temp.ln('b2'), 'refund', pg_temp.rq('rf')));
  return v || jsonb_build_object('rf', (select status from public.refund_request where id = pg_temp.rq('rf')),
                                 'hold_z', pg_temp.hold(pg_temp.v('z')),
                                 'open', pg_temp.q(format('select private.transfer_late_debit_open(%L)', pg_temp.v('m0'))));
end $$;
insert into j select 'rf2', pg_temp.isolated('sc_rf2');
select results_eq($$ select (v ->> 'rf_in_f2')::boolean, v -> 'listed',
                            v ->> 'follow' ~ '^refund refused: reissue_in_downloaded_file \| Ce débit ne porte aucune référence, et un reversement de ce montant était dans le fichier TF-',
                            v ->> 'link', v ->> 'rf', v ->> 'hold_z', v ->> 'open' from j where k = 'rf2' $$,
  $$ values (true, '[]'::jsonb, true, 'debit link refused: payout_candidate'::text, 'requested'::text,
             'client_payout_debited_late'::text, 'true'::text) $$,
  'RF2 (DP-2): a payout cancelled after download, its run ended: a debit with no reference at its amount is never a refund''s (not listed, payout_candidate; the trigger refuses it too), the client''s next payout stays held');
-- RF3 (DP-2): the sweep S1 cancelled with its downloaded file, then a debit with no reference at its amount (no new
-- sweep since); a refund of that amount in the next downloaded file: never linked to that debit
create or replace function pg_temp.sc_rf3() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f1', 'rf3-g1', 0);
  insert into t values ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
  perform pg_temp.cancel_whole('f1', 'rf3', 'b1');
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 12000)));
  insert into j select 'rf', pg_temp.refund('76', 12000);
  perform pg_temp.handed_out('f2', 'rf3-g2', 2);
  v := v || jsonb_build_object('no_sweep', (pg_temp.sweep(pg_temp.v('f2'))).id is null,
    'rf_in_f2', pg_temp.file_of(pg_temp.rft('rf')) = pg_temp.v('f2'),
    'listed', pg_temp.listed(pg_temp.ln('b2'), array['rf']),
    'follow', pg_temp.follow('rf', pg_temp.ln('b2')),
    'link', pg_temp.link('rf3-l', pg_temp.ln('b2'), 'refund', pg_temp.rq('rf')));
  return v || jsonb_build_object('rf', (select status from public.refund_request where id = pg_temp.rq('rf')),
                                 'dcs', pg_temp.dcs() = jsonb_build_array(pg_temp.v('s1')));
end $$;
insert into j select 'rf3', pg_temp.isolated('sc_rf3');
select results_eq($$ select (v ->> 'no_sweep')::boolean, (v ->> 'rf_in_f2')::boolean, v -> 'listed',
                            v ->> 'follow' ~ '^refund refused: reissue_in_downloaded_file \| Ce débit ne porte aucune référence, et un virement au compte propre de ce montant était dans le fichier TF-',
                            v ->> 'link', v ->> 'rf', (v ->> 'dcs')::boolean from j where k = 'rf3' $$,
  $$ values (true, true, '[]'::jsonb, true, 'debit link refused: payout_candidate'::text, 'requested'::text, true) $$,
  'RF3 (DP-2): a sweep cancelled after download: a debit with no reference at its amount is never a refund''s while no sweep made since may be it (not listed, refused); the servicer''s next share stays stopped');

-- LD1a (LD-1): a CSV feed (no end-to-end column); F1 cancelled whole, Martin's payout m0 re-issued (m1) in F2,
-- downloaded; the bank executes m1: a debit of its amount with no reference. m0 is in m1's chain: the line is m1's
-- (booked, the run booked: no R124-6 breach), never ambiguous with it
create or replace function pg_temp.sc_ld1a() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  update public.bank_account set feed = 'csv' where id = pg_temp.cf();
  perform pg_temp.handed_out('f1', 'ld1a-g1', 0);
  insert into t values ('m0', pg_temp.trid('r1'));
  v := v || jsonb_build_object('cancel', pg_temp.cancel_whole('f1', 'ld1a', 'b1', 0, 'csv'));
  insert into t values ('m1', pg_temp.trid('r1'));
  perform pg_temp.handed_out('f2', 'ld1a-g2', 3);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 164000)),
                        pg_temp.d(10), null, 'csv');
  v := v || jsonb_build_object('m1_in_f2', pg_temp.file_of(pg_temp.v('m1')) = pg_temp.v('f2'),
    'candidates', (select jsonb_agg(c.cand order by c.cand)
                   from private.transfer_line_candidates(pg_temp.ln('b2'), 'N') c),
    'proposal', pg_temp.prop(pg_temp.ln('b2')) = jsonb_build_array(pg_temp.pt('payout', pg_temp.v('m1'), 164000)),
    'book', pg_temp.bkx(pg_temp.ln('b2'), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('m1'), 164000))));
  return v || jsonb_build_object('m1', pg_temp.status(pg_temp.v('m1')),
                                 'run', (select status from public.remittance_run where id = pg_temp.v('r1')),
                                 'open', pg_temp.q(format('select private.transfer_late_debit_open(%L)', pg_temp.v('m0'))));
end $$;
insert into j select 'ld1a', pg_temp.isolated('sc_ld1a');
select results_eq($$ select v ->> 'cancel', (v ->> 'm1_in_f2')::boolean, v -> 'candidates', (v ->> 'proposal')::boolean,
                            v ->> 'book', v ->> 'm1', v ->> 'run', v ->> 'open' from j where k = 'ld1a' $$,
  $$ values ('requested/superseded'::text, true, '["i"]'::jsonb, true, 'ok'::text, 'booked'::text, 'booked'::text,
             'false'::text) $$,
  'LD1a (LD-1): on a feed without our references, a re-issued payout''s own debit is its (its cancelled predecessor is no candidate beside it): proposed and booked, the run booked');
-- LD1b (LD-1): the re-run shape — m0 refused and cancelled alone, its run cancelled, Martin's collection run again (z,
-- in F2, downloaded); the bank executes z: a debit of its amount with no reference is z's
create or replace function pg_temp.sc_ld1b() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.g1c_prefix('ld1b');
  update public.bank_account set feed = 'csv' where id = pg_temp.cf();
  insert into t select 'r1b', pg_temp.run2('a1', '{"01": "200000"}', 36000, 6000, 15, 100, 'ld1b-r2');
  insert into t values ('z', pg_temp.trid('r1b'));
  perform pg_temp.handed_out('f2', 'ld1b-g2', 3);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 164000)),
                        pg_temp.d(10), null, 'csv');
  v := v || jsonb_build_object('z_in_f2', pg_temp.file_of(pg_temp.v('z')) = pg_temp.v('f2'),
    'candidates', (select jsonb_agg(c.cand order by c.cand)
                   from private.transfer_line_candidates(pg_temp.ln('b2'), 'N') c),
    'proposal', pg_temp.prop(pg_temp.ln('b2')) = jsonb_build_array(pg_temp.pt('payout', pg_temp.v('z'), 164000)),
    'book', pg_temp.bkx(pg_temp.ln('b2'), jsonb_build_array(pg_temp.pt('payout', pg_temp.v('z'), 164000))));
  return v || jsonb_build_object('z', pg_temp.status(pg_temp.v('z')),
                                 'run', (select status from public.remittance_run where id = pg_temp.v('r1b')));
end $$;
insert into j select 'ld1b', pg_temp.isolated('sc_ld1b');
select results_eq($$ select (v ->> 'z_in_f2')::boolean, v -> 'candidates', (v ->> 'proposal')::boolean, v ->> 'book',
                            v ->> 'z', v ->> 'run' from j where k = 'ld1b' $$,
  $$ values (true, '["i"]'::jsonb, true, 'ok'::text, 'booked'::text, 'booked'::text) $$,
  'LD1b (LD-1): and so for the payout of the run that took the cancelled run''s collections again');
-- LD2 (LD-2): a CSV feed; the sweep S1 cancelled with F1, D4 makes S2 at its amount in F2, downloaded; the bank executes
-- S2: its debit with no reference is S2's (booked), and the servicer's next share is proposed again
create or replace function pg_temp.sc_ld2() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb;
begin
  update public.bank_account set feed = 'csv' where id = pg_temp.cf();
  perform pg_temp.handed_out('f1', 'ld2-g1', 0);
  insert into t values ('s1', (pg_temp.sweep(pg_temp.v('f1'))).id);
  perform pg_temp.cancel_whole('f1', 'ld2', 'b1', 0, 'csv');
  perform pg_temp.handed_out('f2', 'ld2-g2', 3);
  insert into t values ('s2', (pg_temp.sweep(pg_temp.v('f2'))).id);
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 12000)),
                        pg_temp.d(10), null, 'csv');
  v := v || jsonb_build_object(
    'candidates', (select jsonb_agg(c.cand order by c.cand)
                   from private.transfer_line_candidates(pg_temp.ln('b2'), 'N') c),
    'proposal', pg_temp.prop(pg_temp.ln('b2')) = jsonb_build_array(pg_temp.pt('sweep', pg_temp.v('s2'), 12000)),
    'book', pg_temp.bkx(pg_temp.ln('b2'), jsonb_build_array(pg_temp.pt('sweep', pg_temp.v('s2'), 12000))));
  perform pg_temp.cypres_again('ld2-cy');
  g := pg_temp.gen_try('ld2-g3');
  return v || jsonb_build_object('s2', pg_temp.status(pg_temp.v('s2')), 'dcs', pg_temp.dcs(),
                                 'next', jsonb_build_array(g ->> 'sweep_minor', g ->> 'sweep_hold'));
end $$;
insert into j select 'ld2', pg_temp.isolated('sc_ld2');
select results_eq($$ select v -> 'candidates', (v ->> 'proposal')::boolean, v ->> 'book', v ->> 's2', v -> 'dcs',
                            v -> 'next' from j where k = 'ld2' $$,
  $$ values ('["i"]'::jsonb, true, 'ok'::text, 'booked'::text, '[]'::jsonb, '["12000", null]'::jsonb) $$,
  'LD2 (LD-2): on a feed without our references, the sweep made after a cancelled one, at its amount, is booked from its own debit (the cancelled one no candidate beside it); the next share proposed');

-- K4 (tests-4): a sweep cancelled with its file before download (superseded at generation) is no (iv) candidate: a debit
-- to our own account at its amount is never booked as its late debit
create or replace function pg_temp.sc_k4() returns jsonb language plpgsql as $$
declare g jsonb;
begin
  g := pg_temp.gen('01', 'k4-g1');
  insert into t values ('fa', (g ->> 'file_id')::uuid);
  insert into t values ('s1', (pg_temp.sweep(pg_temp.v('fa'))).id);
  perform pg_temp.backdate(pg_temp.v('fa'), pg_temp.d(0));
  perform pg_temp.gen('01', 'k4-g2');
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'iban', pg_temp.own_iban())));
  return jsonb_build_object('s1', pg_temp.status(pg_temp.v('s1')),
    'candidates', coalesce((select jsonb_agg(c.cand) from private.transfer_line_candidates(pg_temp.ln('b2'), 'N') c), '[]'),
    'proposal', pg_temp.prop(pg_temp.ln('b2')));
end $$;
insert into j select 'k4', pg_temp.isolated('sc_k4');
select results_eq($$ select v ->> 's1', v -> 'candidates', v -> 'proposal' from j where k = 'k4' $$,
  $$ values ('cancelled'::text, '[]'::jsonb, '[{"kind": "unplanned_sweep", "amount": "12000"}]'::jsonb) $$,
  'K4 (tests-4): a sweep cancelled before its file was downloaded is no candidate (the bank never had it): the debit is not proposed as its late debit');
-- K5 (tests-4): a cancelled refund whose return was seen is no candidate: a payout at its amount is still proposed
create or replace function pg_temp.sc_k5() returns jsonb language plpgsql as $$
begin
  perform pg_temp.k_prefix('k5', 164000);
  perform pg_temp.lines('b3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('q0')))));
  return jsonb_build_object(
    'candidates', (select jsonb_agg(c.cand order by c.cand)
                   from private.transfer_line_candidates(pg_temp.ln('b2'), 'N') c),
    'proposal', pg_temp.prop(pg_temp.ln('b2')) = jsonb_build_array(pg_temp.pt('payout', pg_temp.trid('r1'), 164000)));
end $$;
insert into j select 'k5', pg_temp.isolated('sc_k5');
select results_eq($$ select v -> 'candidates', (v ->> 'proposal')::boolean from j where k = 'k5' $$,
  $$ values ('["i"]'::jsonb, true) $$,
  'K5 (tests-4): a cancelled refund whose return the bank showed is no candidate: the payout in flight at its amount is proposed');

-- L8 (tests-2): the lines that never count as a cancelled payout's late execution — a debit the bank flags as a return,
-- an entry kept unsplit — and the one that still does (« Classer sans comptabiliser »); the payout's return seen lifts it
create or replace function pg_temp.sc_l8() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f1', 'l8-g1', 0);
  insert into t values ('m0', pg_temp.trid('r1'));
  perform pg_temp.cancel_whole('f1', 'l8', 'b1');
  insert into t values ('m1', pg_temp.trid('r1'));
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'kind', 'return')));
  v := v || jsonb_build_object('return', coalesce(pg_temp.hold(pg_temp.v('m1')), 'none'));
  perform pg_temp.unsplit_line('b3', 164000);
  v := v || jsonb_build_object('unsplit', coalesce(pg_temp.hold(pg_temp.v('m1')), 'none'));
  perform pg_temp.lines('b4', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 164000)));
  insert into public.bank_debit_link (bank_transaction_id, organization_id, bank_account_id, kind, method, reason,
                                      decided_by)
  values (pg_temp.ln('b4'), '00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), 'explained', 'ops', 'classé (test)',
          '10000000-0000-0000-0000-000000000001');
  v := v || jsonb_build_object('explained', coalesce(pg_temp.hold(pg_temp.v('m1')), 'none'));
  perform pg_temp.lines('b5', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')))));
  return v || jsonb_build_object('return_seen', coalesce(pg_temp.hold(pg_temp.v('m1')), 'none'));
end $$;
insert into j select 'l8', pg_temp.isolated('sc_l8');
select results_eq($$ select v ->> 'return', v ->> 'unsplit', v ->> 'explained', v ->> 'return_seen' from j where k = 'l8' $$,
  $$ values ('none'::text, 'none'::text, 'already_debited'::text, 'none'::text) $$,
  'L8 (tests-2): a debit flagged a return, or an entry kept unsplit, is no late execution; a line only classified still is (the re-issue held); the cancelled payout''s return seen lifts it');
-- L9 (tests-2): the cancelled payout's earlier file was superseded before download: a line dated before its downloaded
-- file's execution date is not its execution
create or replace function pg_temp.sc_l9() returns jsonb language plpgsql as $$
declare g jsonb;
begin
  g := pg_temp.gen('01', 'l9-ga');
  insert into t values ('fa', (g ->> 'file_id')::uuid);
  perform pg_temp.backdate(pg_temp.v('fa'), pg_temp.d(1));
  perform pg_temp.handed_out('f1', 'l9-g1', 4);
  insert into t values ('m0', pg_temp.trid('r1'));
  perform pg_temp.cancel_whole('f1', 'l9', 'b1', 4);
  perform pg_temp.lines('b2', pg_temp.d(3), jsonb_build_array(jsonb_build_object('amount', 164000)), pg_temp.d(3),
                        pg_temp.after(3));
  return jsonb_build_object('fa', (pg_temp.fl(pg_temp.v('fa'))).status, 'm0', pg_temp.status(pg_temp.v('m0')),
                            'hold', coalesce(pg_temp.hold(pg_temp.trid('r1')), 'none'));
end $$;
insert into j select 'l9', pg_temp.isolated('sc_l9');
select results_eq($$ select v ->> 'fa', v ->> 'm0', v ->> 'hold' from j where k = 'l9' $$,
  $$ values ('superseded'::text, 'cancelled'::text, 'none'::text) $$,
  'L9 (tests-2): only the execution date of a file the bank had counts (an earlier file superseded before download does not): a line before it holds nothing');

-- CM (tests-5): a re-issue both « debited before » (its own predecessor) and held for a cancelled payout of its client:
-- one alert, not two
create or replace function pg_temp.sc_cm() returns jsonb language plpgsql as $$
begin
  perform pg_temp.g1c_prefix('cm');
  insert into t select 'r1b', pg_temp.run2('a1', '{"01": "200000"}', 36000, 6000, 15, 100, 'cm-r2');
  insert into t values ('z', pg_temp.trid('r1b'));
  perform pg_temp.handed_out('f2', 'cm-g2', 3);
  perform pg_temp.cancel_whole('f2', 'cm2', 'b3', 3);
  insert into t values ('z1', pg_temp.trid('r1b'));
  perform pg_temp.lines('b2', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 164000)));
  insert into t select 'c1', pg_temp.chk(null);
  return jsonb_build_object('z1_replaces_z', pg_temp.replaces(pg_temp.v('z1')) = pg_temp.v('z'),
    'hold', pg_temp.hold(pg_temp.v('z1')),
    'sibling', pg_temp.q(format('select private.transfer_sibling_debited_late(%L)', pg_temp.v('z1'))),
    'rows', (select count(*) from public.payment_check_result r
             where r.run_id = pg_temp.v('c1') and r.code = 'transfer_already_debited' and r.subject_id = pg_temp.v('z1')));
end $$;
insert into j select 'cm', pg_temp.isolated('sc_cm');
select results_eq($$ select (v ->> 'z1_replaces_z')::boolean, v ->> 'hold', v ->> 'sibling', (v ->> 'rows')::int
                     from j where k = 'cm' $$,
  $$ values (true, 'already_debited'::text, 'client_payout_debited_late'::text, 1) $$,
  'CM (tests-5): a re-issue held both for its own predecessor and for a cancelled payout of its client is alerted once');

-- The new helpers are internal; the flag's read --------------------------------------------------------------------
select results_eq($$ select r.rolname::text, bool_or(has_function_privilege(r.rolname, p.oid, 'execute'))
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     cross join (values ('anon'), ('authenticated'), ('service_role')) r (rolname)
                     where n.nspname = 'private'
                       and p.proname in ('transfer_unreferenced_lines', 'transfer_late_debit_open',
                                         'sweep_after_debited_cancelled', 'refund_line_barred_by',
                                         'transfer_sibling_debited_late')
                     group by r.rolname having count(*) = 5 order by r.rolname $$,
  $$ values ('anon'::text, false), ('authenticated', false), ('service_role', false) $$,
  'the five new helpers exist and no API role may call them');
create or replace function pg_temp.flag_as(p_user text, p_aal text default 'aal2') returns text language plpgsql as $$
begin
  return pg_temp.try(p_user, 'select public.cancellation_after_download()::text');
end $$;
create or replace function pg_temp.sc_flag() returns jsonb language plpgsql as $$
begin
  return jsonb_build_object('admin', pg_temp.flag_as('04'), 'collector', pg_temp.flag_as('02'),
                            'client', pg_temp.flag_as('03'), 'other_servicer', pg_temp.flag_as('05'));
end $$;
insert into j select 'flag_on', pg_temp.isolated('sc_flag');
insert into j select 'flag_off', pg_temp.sc_flag();
select results_eq($$ select v ->> 'admin', v ->> 'collector', v ->> 'client', v ->> 'other_servicer' from j
                     where k in ('flag_on', 'flag_off') order by k desc $$,
  $$ values ('true'::text, 'true'::text, 'false'::text, 'true'::text), ('false', 'false', 'false', 'false') $$,
  'public.cancellation_after_download answers the switch to any member of a servicer (a collector too), false to a client''s user');
create or replace function pg_temp.as_role(p_role text, p_sql text) returns text language plpgsql as $$
begin
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
select is(pg_temp.as_role('anon', 'select public.cancellation_after_download()'), '42501', 'anon may not call it');
select is(private.switch_on('downloaded_file_cancellation'), false,
  'the switch is off as the migration leaves it (6b-3b switches it on)');

select * from finish();
rollback;
