-- M2c-6b-3a-2, the switch-on prerequisites part 2 (docs/design/m2c-6b-3-plan.md §2 E–J, §4 T13–T18; ADR-0014
-- « M2c-6b-3a-2 »; COMPLIANCE OQ-80 (i), (m), OQ-82, CPCE-08). The switch STAYS OFF in the migration: each scenario
-- below turns private.feature_switch 'downloaded_file_cancellation' on inside its own subtransaction (pg_temp.isolated:
-- rolled back at its end, its outcomes kept), as 6b-3b's one-line migration will, and the file asserts at its end that
-- the switch is off. What each scenario pins:
--   * E (the late predecessor, LP): a payout cancelled out of a downloaded file whose run is still approved or sent is
--     that run's payout when the bank executes it late — proposed and booked as « Débit d'un reversement » of it (its
--     RMT id, a batch line of its PmtInf, a line without our references, a detail of an entry kept unsplit); its live
--     re-issue is cancelled (ordered), or withdrawn with its file (generated), or the booking refused
--     `reissue_in_downloaded_file` while that file is downloaded or sent; the cancelled transfer stays cancelled;
--   * F: every reader of « booked » takes such a transfer as the run's payout — I20, the R124-6 deadlines of its return,
--     the payout_returned alert, the client's « Reversements », the run page (its debit, its advances);
--   * G: its return is booked « Virement revenu » (its remittance reversed), the lot credit included;
--   * H: a downloaded file cancelled whole never re-issues a payout whose run is no longer in flight;
--   * I: the R124-6 in-flight rows of a re-issue and of a run whose payout was cancelled alone (coverage from the
--     chain's first execution, a possible late debit holding the row back);
--   * J: an item already netted after one late transfer is not netted again after another (OQ-82, Q3 (a));
--   * the low items of 6b-3a's review: a manual refund's link refused in the database beside a cancelled refund's late
--     debit; the queue's candidates carry their transfer's kind; cancel_remittance_run's hint;
--   * review round 1 (ADR-0014 « M2c-6b-3a-2 review fixes »): the late predecessor as a detail of an entry kept unsplit
--     (held, booked, never two payouts of one run), its return then a second execution (netted), the R124-6 rows held
--     to the chain's named debits (CPCE-08), and the clauses the review found untested (J2, T17d, tests-3, tests-4) and
--     the page facts (debit_pending, run_status, after_cancellation);
--   * review rounds 2 and 3: the copies of one run's payout (the copy that comes back closes the other), and a booked
--     run's R124-6 rows judged again at the date its client stayed paid — a batch line booked for several members, a
--     return kept unsplit or booked on a lot credit included (CPCE-08);
--   * review round 4: one rule for that date over the run's whole payout chain — every execution and every return, each
--     counted for the transfer it names (an unflagged return carrying our id included), a transfer paid while its
--     executions outnumber its returns — pinned by the verifiers' shapes and a seeded property against the rule
--     written here independently (CPCE-08).
begin;
select plan(84);



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


-- E: the late predecessor booked as its run's payout ------------------------------------------------------------------
-- E1, E7: x re-issued as y (ordered, held); x executed late under its RMT id: proposed and booked as its run's payout,
-- y cancelled, the run booked at the line's date, x still cancelled; a second execution of x is then unplanned (P = 0)
create or replace function pg_temp.sc_e1() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_p jsonb; v_r public.remittance_run; v_l uuid;
begin
  perform pg_temp.lp_prefix('e1');
  v_l := pg_temp.x_late('e2');
  v_p := pg_temp.op(v_l);
  insert into t select 'c0', pg_temp.chk(null);
  v := v || jsonb_build_object('hold_y', pg_temp.hold(pg_temp.v('y')),
    'proposal', v_p -> 'proposals' -> 0 -> 'request' = jsonb_build_array(pg_temp.pt('payout', pg_temp.v('m0'), 164000)),
    'action', v_p #>> '{proposals,0,action}', 'refusal', v_p ->> 'refusal',
    'lp', v_p #>> '{proposals,0,parts,0,late_predecessor}',
    'cancels', (v_p #>> '{proposals,0,parts,0,cancels_transfer_id}')::uuid = pg_temp.v('y'),
    'cancels_e2e', v_p #>> '{proposals,0,parts,0,cancels_end_to_end_id}' = pg_temp.e2e(pg_temp.v('y')),
    'p0_before', pg_temp.raised('c0', 'cancelled_transfer_debited'),
    'already_before', to_jsonb(pg_temp.already_debited('c0')),
    'settle_before', (select count(*) from public.ledger_entry e where e.idempotency_key = 'settle:' || pg_temp.v('r1')));
  v := v || jsonb_build_object('book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  select * into v_r from public.remittance_run where id = pg_temp.v('r1');
  v := v || jsonb_build_object(
    'run', jsonb_build_array(v_r.status, v_r.booked_on = private.paris_today(), v_r.transfer_id = pg_temp.v('y')),
    'x', (select jsonb_build_array(status, entry_id is null) from public.bank_transfer where id = pg_temp.v('m0')),
    'y_status', pg_temp.status(pg_temp.v('y')),
    'bookings', (select jsonb_agg(jsonb_build_array(k.kind, k.transfer_id = pg_temp.v('m0'), k.amount_minor) order by k.seq)
                 from public.bank_line_booking k where k.bank_transaction_id = v_l),
    'remit', (select count(*) from public.ledger_entry e where e.idempotency_key = 'remit:' || pg_temp.v('m0')
                and e.entry_type = 'remittance' and e.source_type = 'bank_transfer'
                and e.source_id = pg_temp.v('m0')::text and e.effective_date = private.paris_today()),
    'settle', (select count(*) from public.ledger_entry e where e.idempotency_key = 'settle:' || pg_temp.v('r1')),
    'breaches', pg_temp.breaches('r1'),
    'dirty', to_jsonb(pg_temp.dirty()));
  insert into t select 'c1', pg_temp.chk(null);
  v := v || jsonb_build_object('p0', pg_temp.raised('c1', 'cancelled_transfer_debited'),
                               'already', to_jsonb(pg_temp.already_debited('c1')));
  -- E7: x executed once more
  v_l := pg_temp.x_late('e3');
  v := v || jsonb_build_object('again', pg_temp.parts(v_l));
  return v;
end $$;
insert into j select 'e1', pg_temp.isolated('sc_e1');
select results_eq($$ select v ->> 'hold_y', (v ->> 'proposal')::boolean, v ->> 'action', v ->> 'refusal', v ->> 'lp',
                            (v ->> 'cancels')::boolean, (v ->> 'cancels_e2e')::boolean from j where k = 'e1' $$,
  $$ values ('already_debited'::text, true, 'payout'::text, null::text, 'true'::text, true, true) $$,
  'E1: x cancelled out of its downloaded file, its run still approved, executed late under its RMT id — « Comptabiliser… » proposes it as its run''s payout (late predecessor), the re-issue y held meanwhile and named as the transfer the booking cancels');
select results_eq($$ select (v ->> 'p0_before')::int, v -> 'already_before', (v ->> 'settle_before')::int
                     from j where k = 'e1' $$,
  $$ values (1, '["payout 164000 ordered"]'::jsonb, 0) $$,
  'E1: before the booking — the P0 cancelled_transfer_debited and the re-issue alerted (transfer_already_debited), the run not settled');
select results_eq($$ select v ->> 'book', v -> 'run', v -> 'x', v ->> 'y_status', v -> 'bookings' from j where k = 'e1' $$,
  $$ values ('ok'::text, '["booked", true, true]'::jsonb, '["cancelled", true]'::jsonb, 'cancelled'::text,
             '[["payout", true, 164000]]'::jsonb) $$,
  'E1: booked — the run booked at the line''s date (its transfer pointer stays y), x still cancelled with no entry of its own, y cancelled, the line booked as x''s payout');
select results_eq($$ select (v ->> 'remit')::int, (v ->> 'settle')::int, v -> 'breaches', v -> 'dirty', (v ->> 'p0')::int,
                            v -> 'already' from j where k = 'e1' $$,
  $$ values (1, 1, '[]'::jsonb, '[]'::jsonb, 0, '[]'::jsonb) $$,
  'E1: remit:<x> (source x) and settle:<run> posted at the line''s date, no breach row (on time), every ledger and funds invariant clean (I20, I9, I19, I13, I14), the alerts silent');
select is((select v -> 'again' from j where k = 'e1'),
  '[["unplanned_payout", true, "0", "164000", "none", null]]'::jsonb,
  'E7: a second execution of x after the booking is « Virement hors reversement » of it — its run booked, P = 0, the whole of it the servicer''s advance');

-- E2: y in a generated file F2 when x's late debit arrives: the booking withdraws F2 (its other payouts ordered again,
-- its sweep cancelled) and cancels y
create or replace function pg_temp.sc_e2() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb; v_l uuid; v_p jsonb;
begin
  perform pg_temp.lp_prefix('e2');
  g := pg_temp.gen('01', 'e2-g2');
  insert into t values ('f2', (g ->> 'file_id')::uuid);
  perform pg_temp.write(pg_temp.v('f2'));
  insert into t values ('s2', (pg_temp.sweep(pg_temp.v('f2'))).id);
  v_l := pg_temp.x_late('e3');
  v_p := pg_temp.op(v_l);
  v := v || jsonb_build_object('in_f2', jsonb_build_array(pg_temp.file_of(pg_temp.v('y')) = pg_temp.v('f2'),
                                                          pg_temp.file_of(pg_temp.v('yl')) = pg_temp.v('f2'),
                                                          pg_temp.v('s2') is not null),
    'supersedes', v_p #>> '{proposals,0,parts,0,supersedes_file_number}' = (pg_temp.fl(pg_temp.v('f2'))).number,
    'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  return v || jsonb_build_object('f2', (pg_temp.fl(pg_temp.v('f2'))).status, 'y', pg_temp.status(pg_temp.v('y')),
    'yl', jsonb_build_array(pg_temp.status(pg_temp.v('yl')), pg_temp.file_of(pg_temp.v('yl')) is null),
    's2', pg_temp.status(pg_temp.v('s2')), 'run', pg_temp.run_status('r1'), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'e2', pg_temp.isolated('sc_e2');
select results_eq($$ select v -> 'in_f2', (v ->> 'supersedes')::boolean, v ->> 'book', v ->> 'f2', v ->> 'y', v -> 'yl',
                            v ->> 's2', v ->> 'run', v -> 'dirty' from j where k = 'e2' $$,
  $$ values ('[true, true, true]'::jsonb, true, 'ok'::text, 'superseded'::text, 'cancelled'::text,
             '["ordered", true]'::jsonb, 'cancelled'::text, 'booked'::text, '[]'::jsonb) $$,
  'E2: y in a generated file — the booking withdraws that file (superseded: Lilas'' re-issue ordered again for the next file, its sweep cancelled), cancels y and books the run');

-- E3: y in a downloaded file F2 (then marked sent): refused reissue_in_downloaded_file, nothing changes; once F2 is
-- cancelled whole on evidence (y re-issued as y2, held), the late predecessor is booked and y2 cancelled
create or replace function pg_temp.sc_e3() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_p jsonb;
begin
  perform pg_temp.lp_prefix('e3');
  perform pg_temp.handed_out('f2', 'e3-g2', 2);
  v_l := pg_temp.x_late('e4');
  v_p := pg_temp.op(v_l);
  v := v || jsonb_build_object('refusal', v_p ->> 'refusal',
    'detail', v_p ->> 'refusal_detail' = (pg_temp.fl(pg_temp.v('f2'))).number,
    'proposals', jsonb_array_length(v_p -> 'proposals'),
    'command', pg_temp.bkx(v_l, jsonb_build_array(pg_temp.pt('payout', pg_temp.v('m0'), 164000))),
    'state', jsonb_build_array(pg_temp.run_status('r1'), pg_temp.status(pg_temp.v('y')),
                               (select count(*) from public.bank_line_booking k where k.bank_transaction_id = v_l)));
  v := v || jsonb_build_object('sent', pg_temp.try('01', pg_temp.sent('e3-sent-key', 'f2')),
    'refusal_sent', pg_temp.op(v_l) ->> 'refusal',
    'command_sent', pg_temp.bkx(v_l, jsonb_build_array(pg_temp.pt('payout', pg_temp.v('m0'), 164000))));
  v := v || jsonb_build_object('cancel_f2', pg_temp.cancel_whole('f2', 'e3f2', 'e5', 2));
  insert into t values ('y2', pg_temp.trid('r1'));
  v := v || jsonb_build_object('y2', jsonb_build_array(pg_temp.replaces(pg_temp.v('y2')) = pg_temp.v('y'),
                                                       pg_temp.hold(pg_temp.v('y2'))),
    'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  return v || jsonb_build_object('after', jsonb_build_array(pg_temp.status(pg_temp.v('y2')), pg_temp.run_status('r1')));
end $$;
insert into j select 'e3', pg_temp.isolated('sc_e3');
select results_eq($$ select v ->> 'refusal', (v ->> 'detail')::boolean, (v ->> 'proposals')::int, v ->> 'command',
                            v -> 'state' from j where k = 'e3' $$,
  $$ values ('reissue_in_downloaded_file'::text, true, 0, 'reissue_in_downloaded_file'::text,
             '["sent", "in_file", 0]'::jsonb) $$,
  'E3: y in a downloaded file — the options and the command refuse reissue_in_downloaded_file (y''s file number the detail); nothing changes');
select results_eq($$ select v ->> 'sent', v ->> 'refusal_sent', v ->> 'command_sent' from j where k = 'e3' $$,
  $$ values ('sent'::text, 'reissue_in_downloaded_file'::text, 'reissue_in_downloaded_file'::text) $$,
  'E3: and so once that file is marked sent');
select results_eq($$ select v ->> 'cancel_f2', v -> 'y2', v ->> 'book', v -> 'after' from j where k = 'e3' $$,
  $$ values ('requested/superseded'::text, '[true, "already_debited"]'::jsonb, 'ok'::text,
             '["cancelled", "booked"]'::jsonb) $$,
  'E3: that file cancelled whole on evidence by two people (y re-issued as y2, held) — the late predecessor is then booked, y2 cancelled');

-- E4: x cancelled alone out of its live downloaded file (refused by the bank), its run still sent: its late debit is
-- the run's payout, nothing else to cancel
create or replace function pg_temp.sc_e4() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_p jsonb;
begin
  perform pg_temp.g1c_prefix('e4', true);
  v_l := pg_temp.x_late('e6');
  v_p := pg_temp.op(v_l);
  v := v || jsonb_build_object('run_before', pg_temp.run_status('r1'),
    'proposal', v_p -> 'proposals' -> 0 -> 'request' = jsonb_build_array(pg_temp.pt('payout', pg_temp.v('m0'), 164000)),
    'lp', v_p #>> '{proposals,0,parts,0,late_predecessor}',
    'cancels', coalesce(v_p #>> '{proposals,0,parts,0,cancels_transfer_id}', 'none'),
    'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  return v || jsonb_build_object('run', jsonb_build_array(pg_temp.run_status('r1'),
                                                          pg_temp.trid('r1') = pg_temp.v('m0')),
                                 'x', pg_temp.status(pg_temp.v('m0')), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'e4', pg_temp.isolated('sc_e4');
select results_eq($$ select v ->> 'run_before', (v ->> 'proposal')::boolean, v ->> 'lp', v ->> 'cancels', v ->> 'book',
                            v -> 'run', v ->> 'x', v -> 'dirty' from j where k = 'e4' $$,
  $$ values ('sent'::text, true, 'true'::text, 'none'::text, 'ok'::text, '["booked", true]'::jsonb, 'cancelled'::text,
             '[]'::jsonb) $$,
  'E4: x cancelled alone (« Virement refusé par la banque »), its run still sent — its late debit books the run, nothing to cancel');

-- E4b: y cancelled alone out of its live downloaded file, then x executed late: the run booked by x; y executed late
-- after all is « Virement hors reversement » of it (P = 0: the run is booked — the client paid twice, Q4/OQ-82)
create or replace function pg_temp.sc_e4b() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid;
begin
  perform pg_temp.lp_prefix('e4b');
  perform pg_temp.handed_out('f2', 'e4b-g2', 2);
  insert into t values ('s2', (pg_temp.sweep(pg_temp.v('f2'))).id);
  perform pg_temp.lines('e7', pg_temp.d(3), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('yl')), 'day', pg_temp.d(2)),
    jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s2')), 'day', pg_temp.d(2))),
    pg_temp.d(2), pg_temp.after(3));
  v := v || jsonb_build_object('cancel_y', pg_temp.try('01', pg_temp.req_tr('e4b-rq', pg_temp.v('y'))) || '/'
                                           || pg_temp.try('04', pg_temp.conf_tr('e4b-cf', pg_temp.v('y'))),
                               'run_after_cancel', pg_temp.run_status('r1'));
  v_l := pg_temp.x_late('e8');
  v := v || jsonb_build_object('x_parts', pg_temp.parts(v_l), 'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)),
                               'run', pg_temp.run_status('r1'));
  perform pg_temp.lines('e9', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')))));
  return v || jsonb_build_object('y_parts', (select jsonb_agg(jsonb_build_array(p ->> 'kind', p ->> 'paid_minor',
                                                                                  p ->> 'advance_minor'))
                                             from jsonb_array_elements(pg_temp.pv(pg_temp.ln('e9'),
                                                                       pg_temp.prop(pg_temp.ln('e9'))) -> 'parts') p));
end $$;
insert into j select 'e4b', pg_temp.isolated('sc_e4b');
select results_eq($$ select v ->> 'cancel_y', v ->> 'run_after_cancel', v -> 'x_parts', v ->> 'book', v ->> 'run',
                            v -> 'y_parts' from j where k = 'e4b' $$,
  $$ values ('requested/cancelled'::text, 'sent'::text, '[["payout", true, "0", "0", null, "true"]]'::jsonb, 'ok'::text,
             'booked'::text, '[["unplanned_payout", "0", "164000"]]'::jsonb) $$,
  'E4b: the re-issue cancelled alone out of its live file, then x executed late — x books the run (nothing more to cancel); a later debit of the re-issue is « Virement hors reversement », P = 0, the servicer''s advance');

-- E5: x's late debit as a batch line of its PmtInf (class B), and as a line without our references (class N: rule 3b's
-- only candidate; L's hold on y first)
create or replace function pg_temp.sc_e5() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.lp_prefix('e5');
  perform pg_temp.lines('ea', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'pmt_inf', pg_temp.pmt('f1', 1))));
  return v || jsonb_build_object('parts', pg_temp.parts(pg_temp.ln('ea')),
    'book', pg_temp.bkx(pg_temp.ln('ea'), pg_temp.prop(pg_temp.ln('ea'))),
    'after', jsonb_build_array(pg_temp.status(pg_temp.v('y')), pg_temp.run_status('r1')));
end $$;
create or replace function pg_temp.sc_e5n() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.lp_prefix('e5n');
  perform pg_temp.lines('eb', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 164000)));
  v := v || jsonb_build_object('hold_y', pg_temp.hold(pg_temp.v('y')), 'parts', pg_temp.parts(pg_temp.ln('eb')),
    'book', pg_temp.bkx(pg_temp.ln('eb'), pg_temp.prop(pg_temp.ln('eb'))));
  return v || jsonb_build_object('after', jsonb_build_array(pg_temp.status(pg_temp.v('y')), pg_temp.run_status('r1')),
                                 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'e5', pg_temp.isolated('sc_e5');
insert into j select 'e5n', pg_temp.isolated('sc_e5n');
select results_eq($$ select v -> 'parts', v ->> 'book', v -> 'after' from j where k = 'e5' $$,
  $$ values ('[["payout", true, "0", "0", null, "true"]]'::jsonb, 'ok'::text, '["cancelled", "booked"]'::jsonb) $$,
  'E5 (class B): x''s late debit as a batch line of its PmtInf in the cancelled file is its run''s payout');
select results_eq($$ select v ->> 'hold_y', v -> 'parts', v ->> 'book', v -> 'after', v -> 'dirty' from j where k = 'e5n' $$,
  $$ values ('already_debited'::text, '[["payout", true, "0", "0", null, "true"]]'::jsonb, 'ok'::text,
             '["cancelled", "booked"]'::jsonb, '[]'::jsonb) $$,
  'E5 (class N): a line without our references at x''s amount holds y (L), and is booked as x''s run''s payout (rule 3b''s only candidate)');

-- E6: G1c's 583 840 variant — F1 downloaded, only the sweep's batch line on its day's statement, Martin cancelled alone
-- (refused by the bank) while Lilas stays live; then one batch line of the payouts' PmtInf at Lilas + Martin
create or replace function pg_temp.e6(p_key text, p_cancel_run boolean) returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f1', p_key || '-g1', 0);
  insert into t values ('m0', pg_temp.trid('r1')), ('l0', pg_temp.trid('r2'));
  perform pg_temp.lines('ec', pg_temp.d(1), jsonb_build_array(
    jsonb_build_object('amount', 12000, 'pmt_inf', pg_temp.pmt('f1', 2), 'day', pg_temp.d(0))), pg_temp.d(0),
    pg_temp.after(1));
  v := v || jsonb_build_object('cancel_m', pg_temp.try('01', pg_temp.req_tr(p_key || '-rq', pg_temp.v('m0'))) || '/'
                                           || pg_temp.try('04', pg_temp.conf_tr(p_key || '-cf', pg_temp.v('m0'))));
  if p_cancel_run then
    v := v || jsonb_build_object('cancel_run', pg_temp.try('04', pg_temp.cancel_run(p_key || '-run', 'r1')));
  end if;
  perform pg_temp.lines('ed', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 583840, 'pmt_inf', pg_temp.pmt('f1', 1))));
  v := v || jsonb_build_object('parts', pg_temp.parts(pg_temp.ln('ed')),
                               'book', pg_temp.bkx(pg_temp.ln('ed'), pg_temp.prop(pg_temp.ln('ed'))));
  return v || jsonb_build_object('runs', jsonb_build_array(pg_temp.run_status('r1'), pg_temp.run_status('r2')),
                                 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
create or replace function pg_temp.sc_e6() returns jsonb language sql as $$ select pg_temp.e6('e6', false) $$;
create or replace function pg_temp.sc_e6c() returns jsonb language sql as $$ select pg_temp.e6('e6c', true) $$;
insert into j select 'e6', pg_temp.isolated('sc_e6');
insert into j select 'e6c', pg_temp.isolated('sc_e6c');
select results_eq($$ select v ->> 'cancel_m', v -> 'parts', v ->> 'book', v -> 'runs', v -> 'dirty' from j where k = 'e6' $$,
  $$ values ('requested/cancelled'::text,
             '[["payout", false, "0", "0", null, null], ["payout", true, "0", "0", null, "true"]]'::jsonb, 'ok'::text,
             '["booked", "booked"]'::jsonb, '[]'::jsonb) $$,
  'E6 (G1c''s 583 840): one batch line of Lilas (live) and Martin (cancelled alone, his run still sent) — payout + payout (late predecessor), both runs booked');
select results_eq($$ select v ->> 'cancel_run', v -> 'parts', v ->> 'book', v -> 'runs' from j where k = 'e6c' $$,
  $$ values ('cancelled'::text,
             '[["payout", false, "0", "0", null, null], ["unplanned_payout", true, "164000", "0", "amount", null]]'::jsonb,
             'ok'::text, '["cancelled", "booked"]'::jsonb) $$,
  'E6: with Martin''s run cancelled instead — payout + « Virement hors reversement » (P = A from his released collection)');

-- E8: y's file generated again between the preview and the command (y back in the queue, held): the caller's compare
-- text names y's old file — split_changed; a new preview books it
create or replace function pg_temp.sc_e8() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; g jsonb; v_l uuid; v_text text;
begin
  perform pg_temp.lp_prefix('e8');
  g := pg_temp.gen('01', 'e8-g2');
  insert into t values ('f2', (g ->> 'file_id')::uuid);
  perform pg_temp.write(pg_temp.v('f2'));
  v_l := pg_temp.x_late('ee');
  v_text := pg_temp.pv(v_l, pg_temp.prop(v_l)) ->> 'expected_text';
  v := v || jsonb_build_object('text_names_f2', position(':lp:' || pg_temp.v('y') in v_text) > 0
                                                and position(pg_temp.v('f2')::text in v_text) > 0,
                               'regenerated', pg_temp.gen_try('e8-g3') ? 'file_id',
                               'y_back', jsonb_build_array(pg_temp.status(pg_temp.v('y')),
                                                           (pg_temp.fl(pg_temp.v('f2'))).status));
  v := v || jsonb_build_object('stale', pg_temp.bk_text(v_l, pg_temp.prop(v_l), v_text, 'e8-stale'),
                               'fresh', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  return v || jsonb_build_object('after', jsonb_build_array(pg_temp.status(pg_temp.v('y')), pg_temp.run_status('r1')));
end $$;
insert into j select 'e8', pg_temp.isolated('sc_e8');
select results_eq($$ select (v ->> 'text_names_f2')::boolean, (v ->> 'regenerated')::boolean, v -> 'y_back', v ->> 'stale',
                            v ->> 'fresh', v -> 'after' from j where k = 'e8' $$,
  $$ values (true, true, '["ordered", "superseded"]'::jsonb, 'split_changed'::text, 'ok'::text,
             '["cancelled", "booked"]'::jsonb) $$,
  'E8: the compare text names y and its file (:lp:); y''s file changed since the preview — split_changed, nothing booked; a new preview books it');


-- F: every reader of « booked » ---------------------------------------------------------------------------------------
-- F1: I20 — clean after E1 (above); a forged cancelled payout with a payout booking whose run is not booked is flagged
create or replace function pg_temp.sc_f1() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid;
begin
  perform pg_temp.lp_prefix('f1x');
  v_l := pg_temp.x_late('f2');
  v := v || jsonb_build_object('book', pg_temp.bkx(v_l, pg_temp.prop(v_l)), 'clean', to_jsonb(pg_temp.dirty()));
  alter table public.remittance_run disable trigger user;
  update public.remittance_run set status = 'approved', booked_on = null where id = pg_temp.v('r1');
  alter table public.remittance_run enable trigger user;
  return v || jsonb_build_object('forged', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'f1', pg_temp.isolated('sc_f1');
select results_eq($$ select v ->> 'book', v -> 'clean', v -> 'forged' ? 'transfer_booked_once' from j where k = 'f1' $$,
  $$ values ('ok'::text, '[]'::jsonb, true) $$,
  'F1: I20 takes a cancelled payout booked as its live run''s payout as booked (and the run with it); the same booking under a run not booked is still flagged');
-- F1b (defence in depth, found by its mutant): a cancelled payout is its run's late predecessor only while the chain of
-- the run's live transfer holds it — x's run forged onto another client's run (approved, its chain without x), x is no
-- longer one (no state the commands reach: a payout's run never changes)
create or replace function pg_temp.sc_f1b() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.lp_prefix('f1y');
  v := jsonb_build_object('lp', private.transfer_late_predecessor(pg_temp.v('m0')));
  alter table public.bank_transfer disable trigger user;
  update public.bank_transfer set run_id = pg_temp.v('r2') where id = pg_temp.v('m0');
  alter table public.bank_transfer enable trigger user;
  return v || jsonb_build_object('forged', private.transfer_late_predecessor(pg_temp.v('m0')),
                                 'r2', pg_temp.run_status('r2'));
end $$;
insert into j select 'f1b', pg_temp.isolated('sc_f1b');
select results_eq($$ select v -> 'lp', v -> 'forged', v ->> 'r2' in ('approved', 'sent') from j where k = 'f1b' $$,
  $$ values ('true'::jsonb, 'false'::jsonb, true) $$,
  'F1b (defence in depth): a cancelled payout is its run''s late predecessor only while the chain of that run''s live transfer holds it');
-- F5b: a late predecessor whose debit goes beyond what the client was owed (a collection reversed after the approval):
-- its payout_overrun advance on the run page
create or replace function pg_temp.sc_f5b() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_page jsonb;
begin
  perform pg_temp.lp_prefix('f5b');
  perform private.ledger_reverse((select id from public.ledger_entry where payment_id = pg_temp.pay('01')
                                    and entry_type = 'allocation'), 'rev-f5b-0001', 'Retour du paiement (test)',
                                 private.paris_today());
  v_l := pg_temp.x_late('f3');
  v := v || jsonb_build_object('book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  v_page := pg_temp.read(format('select public.remittance_run_payout(%L)', pg_temp.v('r1')));
  return v || jsonb_build_object(
    'advance', (select jsonb_agg(jsonb_build_array(a.cause, a.amount_minor > 0)) from public.client_advance a
                where a.transfer_id = pg_temp.v('m0')),
    'page', (select jsonb_agg(jsonb_build_array(a ->> 'cause', (a ->> 'amount_minor')::bigint
                                                = (select amount_minor from public.client_advance
                                                   where transfer_id = pg_temp.v('m0'))))
             from jsonb_array_elements(v_page -> 'advances') a));
end $$;
insert into j select 'f5b', pg_temp.isolated('sc_f5b');
select results_eq($$ select v ->> 'book', v -> 'advance', v -> 'page' from j where k = 'f5b' $$,
  $$ values ('ok'::text, '[["payout_overrun", true]]'::jsonb, '[["payout_overrun", true]]'::jsonb) $$,
  'F5b: the servicer''s advance at a late predecessor''s debit (payout_overrun) is listed on the run page with its amount');


-- G (and F2–F5, F7): the return of a late predecessor --------------------------------------------------------------------
-- G1: after E1, the client's bank returns x (a credit carrying x's id as its original id): « Virement revenu » of x
create or replace function pg_temp.sc_g1() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_r uuid; v_remit uuid; v_rev uuid; v_page jsonb; v_sum jsonb;
begin
  perform pg_temp.lp_prefix('g1');
  v_l := pg_temp.x_late('a2');
  perform pg_temp.bkx(v_l, pg_temp.prop(v_l));
  perform pg_temp.lines('a3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')))));
  v_r := pg_temp.ln('a3');
  v := v || jsonb_build_object('proposal', pg_temp.prop(v_r) = jsonb_build_array(
                                 pg_temp.pt('payout_returned', pg_temp.v('m0'), 164000)),
                               'book', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  select id into v_remit from public.ledger_entry where idempotency_key = 'remit:' || pg_temp.v('m0');
  select id into v_rev from public.ledger_entry where reverses_entry_id = v_remit;
  insert into t select 'c1', pg_temp.chk(null);
  v_page := pg_temp.read(format('select public.remittance_run_payout(%L)', pg_temp.v('r1')));
  v_sum := pg_temp.read(format('select public.client_remittance_summary(%L)', '00000000-0000-0000-0000-0000000000a1'));
  v := v || jsonb_build_object(
    'x', pg_temp.status(pg_temp.v('m0')),
    'reversal', (select jsonb_build_array(e.idempotency_key = 'return:' || v_r || ':' || pg_temp.v('m0'),
                                          e.effective_date = private.paris_today())
                 from public.ledger_entry e where e.id = v_rev),
    'account', (select a.status from public.client_payout_account a
                where a.id = (select payout_account_id from public.remittance_run where id = pg_temp.v('r1'))),
    'dirty', to_jsonb(pg_temp.dirty()),
    -- F2: the payout_returned item has the run's R124-6 date
    'deadline', (select jsonb_build_array(d.monitored, d.deadline is not null) from private.pending_item_deadlines(
                   '00000000-0000-0000-0000-0000000000aa') d where d.ledger_entry_id = v_rev),
    -- F3: the payout_returned alert
    'alert', (select count(*) from public.payment_check_result r where r.run_id = pg_temp.v('c1')
                and r.code = 'payout_returned' and r.subject_id = pg_temp.v('r1')),
    -- F4: the client's « Reversements »: the run's payout came back
    'returned_runs', (select jsonb_agg(jsonb_build_array((x ->> 'returned_on')::date = private.paris_today(),
                                                         x ->> 'amount_minor', x ->> 'repaid_by'))
                      from jsonb_array_elements(v_sum -> 'returned_runs') x
                      where (x ->> 'run_id')::uuid = pg_temp.v('r1')),
    -- F5: the run page: x debited and returned, the late predecessor flagged
    'page', (select jsonb_agg(jsonb_build_array(x ->> 'status', (x ->> 'debited_on')::date = private.paris_today(),
                                                (x ->> 'returned_on')::date = private.paris_today(),
                                                x ->> 'late_predecessor') order by x ->> 'status')
             from jsonb_array_elements(v_page -> 'transfers') x where (x ->> 'id')::uuid = pg_temp.v('m0')));
  return v;
end $$;
insert into j select 'g1', pg_temp.isolated('sc_g1');
select results_eq($$ select (v ->> 'proposal')::boolean, v ->> 'book', v ->> 'x', v -> 'reversal', v ->> 'account',
                            v -> 'dirty' from j where k = 'g1' $$,
  $$ values (true, 'ok'::text, 'cancelled'::text, '[true, true]'::jsonb, 'returned'::text, '[]'::jsonb) $$,
  'G1: the late predecessor''s return is « Virement revenu » of it — its remittance reversed at the return''s date, x still cancelled, the payout account returned, every invariant clean');
select results_eq($$ select v -> 'deadline', (v ->> 'alert')::int from j where k = 'g1' $$,
  $$ values ('[true, true]'::jsonb, 1) $$,
  'F2, F3: its payout_returned item keeps the run''s R124-6 date (monitored, a deadline), and the P0 payout_returned is raised');
select results_eq($$ select v -> 'returned_runs', v -> 'page' from j where k = 'g1' $$,
  $$ values ('[[true, "164000", null]]'::jsonb, '[["cancelled", true, true, "true"]]'::jsonb) $$,
  'F4, F5: the client''s « Reversements » lists the run''s payout as returned; the run page shows x debited and returned (late predecessor)');
-- G2: a flagged return short of N (the bank's charge deducted); G3: a lot credit naming x's PmtInf, its file still live
-- (x refused by the bank, cancelled alone; its run still sent when its late debit came)
create or replace function pg_temp.sc_g2() returns jsonb language plpgsql as $$
declare v_l uuid;
begin
  perform pg_temp.lp_prefix('g2');
  v_l := pg_temp.x_late('a4');
  perform pg_temp.bkx(v_l, pg_temp.prop(v_l));
  perform pg_temp.lines('a5', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 163500, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')))));
  return jsonb_build_object(
    'short', (select jsonb_agg(jsonb_build_array(p ->> 'kind', p ->> 'amount') order by p ->> 'kind' desc)
              from jsonb_array_elements(pg_temp.prop(pg_temp.ln('a5'))) p),
    'book', pg_temp.bkx(pg_temp.ln('a5'), pg_temp.prop(pg_temp.ln('a5'))),
    'dirty', to_jsonb(pg_temp.dirty()));
end $$;
create or replace function pg_temp.sc_g3() returns jsonb language plpgsql as $$
declare v_l uuid;
begin
  perform pg_temp.g1c_prefix('g3', true);
  v_l := pg_temp.x_late('a4');
  perform pg_temp.bkx(v_l, pg_temp.prop(v_l));
  perform pg_temp.lines('a6', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'pmt_inf', pg_temp.pmt('f1', 1))));
  return jsonb_build_object(
    'run', pg_temp.run_status('r1'), 'class', private.transfer_line_class(pg_temp.ln('a6')),
    'lot', pg_temp.prop(pg_temp.ln('a6')) = jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('m0'), 164000)),
    'book_lot', pg_temp.bkx(pg_temp.ln('a6'), pg_temp.prop(pg_temp.ln('a6'))),
    'x', pg_temp.status(pg_temp.v('m0')), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'g2', pg_temp.isolated('sc_g2');
insert into j select 'g3', pg_temp.isolated('sc_g3');
select results_eq($$ select v -> 'short', v ->> 'book', v -> 'dirty' from j where k = 'g2' $$,
  $$ values ('[["payout_returned", "164000"], ["fee", "500"]]'::jsonb, 'ok'::text, '[]'::jsonb) $$,
  'G2: a flagged return of the late predecessor short of N is « Virement revenu » of it + the bank''s charge');
select results_eq($$ select v ->> 'run', v ->> 'class', (v ->> 'lot')::boolean, v ->> 'book_lot', v ->> 'x', v -> 'dirty'
                     from j where k = 'g3' $$,
  $$ values ('booked'::text, 'B'::text, true, 'ok'::text, 'cancelled'::text, '[]'::jsonb) $$,
  'G3: a lot credit naming the late predecessor''s PmtInf (its file still live) is its return: it is the lot''s returnable member');
-- F7: the next run's statement follows x's debit in « Suivi »
create or replace function pg_temp.sc_f7() returns jsonb language plpgsql as $$
declare v_l uuid; v_run uuid; v_ev jsonb;
begin
  perform pg_temp.lp_prefix('f7');
  v_l := pg_temp.x_late('f8');
  perform pg_temp.bkx(v_l, pg_temp.prop(v_l));
  if pg_temp.run_status('r1') <> 'booked' then
    return jsonb_build_object('debited', null);   -- (the run still live: no other run of the client)
  end if;
  perform pg_temp.file('05', '20000000-0000-0000-0000-0000000000a1', 50000);
  perform pg_temp.collect('05', 50000, private.paris_today() - 1);
  v_run := pg_temp.run2('a1', '{"05": "50000"}', 9000, 1500, 15, 100, 'f7-r2');
  v_ev := private.remittance_statement_previous_payouts(v_run) -> 'events';
  return jsonb_build_object('debited', (select jsonb_agg(jsonb_build_array(e ->> 'kind', e ->> 'amount_minor',
                                                                           (e ->> 'on')::date = private.paris_today()))
                                        from jsonb_array_elements(v_ev) e
                                        where e ->> 'run_number' = (select number from public.remittance_run
                                                                    where id = pg_temp.v('r1'))));
end $$;
insert into j select 'f7', pg_temp.isolated('sc_f7');
select is((select v -> 'debited' from j where k = 'f7'), '[["debited", "164000", true]]'::jsonb,
  'F7: the next run''s « Suivi » follows the run''s payout as debited on the late predecessor''s line date');


-- H: a downloaded file cancelled whole never re-issues a payout whose run is no longer in flight ------------------------
create or replace function pg_temp.sc_h() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f1', 'h-g1', 0);
  insert into t values ('m0', pg_temp.trid('r1')), ('l0', pg_temp.trid('r2'));
  -- (forged: no path reaches it) Martin's run booked while its payout is still in the downloaded file
  update public.remittance_run set status = 'booked', booked_on = private.paris_today(), version = version + 1
  where id = pg_temp.v('r1');
  v := v || jsonb_build_object('cancel', pg_temp.cancel_whole('f1', 'h', 'b1'));
  return v || jsonb_build_object(
    'm0', jsonb_build_array(pg_temp.status(pg_temp.v('m0')),
                            exists (select 1 from public.bank_transfer y where y.replaces_transfer_id = pg_temp.v('m0')),
                            pg_temp.run_status('r1'), pg_temp.trid('r1') = pg_temp.v('m0')),
    'l0', jsonb_build_array(pg_temp.status(pg_temp.v('l0')),
                            exists (select 1 from public.bank_transfer y where y.replaces_transfer_id = pg_temp.v('l0')),
                            pg_temp.run_status('r2')),
    'reason', (select cancel_reason from public.bank_transfer where id = pg_temp.v('m0')) like '%non réémis%');
end $$;
insert into j select 'h', pg_temp.isolated('sc_h');
select results_eq($$ select v ->> 'cancel', v -> 'm0', v -> 'l0', (v ->> 'reason')::boolean from j where k = 'h' $$,
  $$ values ('requested/superseded'::text, '["cancelled", false, "booked", true]'::jsonb,
             '["cancelled", true, "approved"]'::jsonb, true) $$,
  'H: a payout whose run is already booked is cancelled with its file, not re-issued (its reason says so); the file''s other payouts are re-issued as before');


-- I: the R124-6 in-flight rows of a re-issue and of a run whose payout was cancelled alone ------------------------------
-- (L, Martin's line's latest execution date, is the fixture's — a month after his collection, ahead of today: the
-- nightly checks below run on the business days after it, p_today, and the statements that cover [e0, L] were produced
-- after L)
create or replace function pg_temp.lx() returns date language sql as $$
  select min(latest_execution_date) from public.remittance_line where run_id = pg_temp.v('r1') $$;
create or replace function pg_temp.after_l(p_k integer) returns date language sql as $$
  select c.day from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day > pg_temp.lx()
  order by c.day offset p_k - 1 limit 1 $$;
-- an empty statement covering p_from..p_to, produced the morning after p_to
create or replace function pg_temp.cover_to(p_n text, p_from date, p_to date) returns uuid language sql as $$
  select pg_temp.lines(p_n, p_to, '[]', p_from, ((p_to + 1) + time '09:00') at time zone 'Europe/Paris') $$;
grant execute on all functions in schema pg_temp to authenticated;
-- I1: y ordered (never handed out), x's late debit on a statement, dated on or before L (from x's requested execution
-- date: the fixture's files are dated back, its transfers' requested dates are not) — no row (the run may have been paid
-- on time; its booking at that date writes none, E1). I2: x's only debit dated after L — the row, once [e0, L] is covered
create or replace function pg_temp.sc_i1() returns jsonb language plpgsql as $$
begin
  perform pg_temp.lp_prefix('i1');
  perform pg_temp.lines('c2', pg_temp.lx(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', pg_temp.e())), pg_temp.d(2),
    ((pg_temp.lx() + 1) + time '09:00') at time zone 'Europe/Paris');
  insert into t select 'c1', pg_temp.chk(pg_temp.after_l(1));
  return jsonb_build_object('nightly', pg_temp.breaches('r1'), 'run', pg_temp.run_status('r1'),
                            'covered', private.statement_covers(pg_temp.cf(), pg_temp.d(0), pg_temp.lx()));
end $$;
create or replace function pg_temp.sc_i2() returns jsonb language plpgsql as $$
begin
  perform pg_temp.lp_prefix('i2');
  perform pg_temp.cover_to('c2', pg_temp.d(2), pg_temp.lx());
  perform pg_temp.x_late('c3', pg_temp.after_l(1));
  insert into t select 'c1', pg_temp.chk(pg_temp.after_l(2));
  return jsonb_build_object('nightly', pg_temp.breaches('r1'));
end $$;
insert into j select 'i1', pg_temp.isolated('sc_i1');
insert into j select 'i2', pg_temp.isolated('sc_i2');
select results_eq($$ select v -> 'nightly', v ->> 'run', (v ->> 'covered')::boolean from j where k = 'i1' $$,
  $$ values ('[]'::jsonb, 'approved'::text, true) $$,
  'I1: a re-issue never handed out while its predecessor''s late debit, dated on or before L, waits on a statement — no breach row, [e0, L] covered (the run may have been paid on time)');
select is((select v -> 'nightly' from j where k = 'i2'), '["none"]'::jsonb,
  'I2: the predecessor''s only debit dated after L — the row is written once [e0, L] is covered (the payment is certainly late)');
-- I3, I5: no debit of the chain — no row while a business day of [e0, L] has no statement; the row once covered
create or replace function pg_temp.sc_i35() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.lp_prefix('i35');
  insert into t select 'c1', pg_temp.chk(pg_temp.after_l(1));
  v := v || jsonb_build_object('gap', pg_temp.breaches('r1'));
  perform pg_temp.cover_to('c4', pg_temp.d(2), pg_temp.lx());
  insert into t select 'c2', pg_temp.chk(pg_temp.after_l(1));
  return v || jsonb_build_object('covered', pg_temp.breaches('r1'));
end $$;
insert into j select 'i35', pg_temp.isolated('sc_i35');
select results_eq($$ select v -> 'gap', v -> 'covered' from j where k = 'i35' $$,
  $$ values ('[]'::jsonb, '["none"]'::jsonb) $$,
  'I5, I3: a re-issue never handed out — no row while a business day of [e0, L] has no statement; the row once the statements cover it with no possible debit');
-- I4: a line of x's PmtInf that offers no booking of x (no subset of the lot makes it), dated on L: it holds the row back
-- within the bound days, then the row is written « bloqué : débit possible non comptabilisé »
create or replace function pg_temp.sc_i4() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.lp_prefix('i4');
  perform pg_temp.lines('c2', pg_temp.lx(), jsonb_build_array(
    jsonb_build_object('amount', 1000, 'pmt_inf', pg_temp.pmt('f1', 1), 'day', pg_temp.lx())), pg_temp.d(2),
    ((pg_temp.lx() + 1) + time '09:00') at time zone 'Europe/Paris');
  insert into t select 'c1', pg_temp.chk(pg_temp.after_l(1));
  v := v || jsonb_build_object('young', pg_temp.breaches('r1'));
  insert into t select 'c2', pg_temp.chk(pg_temp.after_l(8));
  return v || jsonb_build_object('old', pg_temp.breaches('r1'));
end $$;
insert into j select 'i4', pg_temp.isolated('sc_i4');
select results_eq($$ select v -> 'young', v -> 'old' from j where k = 'i4' $$,
  $$ values ('[]'::jsonb, '["debit_unbooked"]'::jsonb) $$,
  'I4: a line that may be the predecessor''s debit holds the re-issue''s row back within the bound days, then the row is written « bloqué : débit possible non comptabilisé »');
-- I6: a run whose payout was cancelled alone (refused by the bank, the run still sent): its row once [e0, L] is covered
-- with no possible debit of it (the file's other lines booked to their transfers)
create or replace function pg_temp.sc_i6() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.g1c_prefix('i6', true);
  v := v || jsonb_build_object('booked', jsonb_build_array(
    pg_temp.bkx(pg_temp.ln('b1', 1), pg_temp.prop(pg_temp.ln('b1', 1))),
    pg_temp.bkx(pg_temp.ln('b1', 2), pg_temp.prop(pg_temp.ln('b1', 2)))));
  insert into t select 'c1', pg_temp.chk(pg_temp.after_l(1));
  v := v || jsonb_build_object('gap', pg_temp.breaches('r1'));
  perform pg_temp.cover_to('c2', pg_temp.d(2), pg_temp.lx());
  insert into t select 'c3', pg_temp.chk(pg_temp.after_l(1));
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'run', pg_temp.run_status('r1'));
end $$;
insert into j select 'i6', pg_temp.isolated('sc_i6');
select results_eq($$ select v -> 'booked', v -> 'gap', v -> 'rows', v ->> 'run' from j where k = 'i6' $$,
  $$ values ('["ok", "ok"]'::jsonb, '[]'::jsonb, '["none"]'::jsonb, 'sent'::text) $$,
  'I6: a run whose payout was cancelled alone, still sent — no row while [e0, L] is not covered, its row once the statements cover it with no possible debit of it');


-- J: OQ-82's known limit — an item netted after one late transfer is not netted again after another -------------------
-- x1 (Martin's payout) cancelled alone out of F1, its run cancelled; its item re-run by R2, whose payout x2 is cancelled
-- with its downloaded file F2 and R2 cancelled; then both executed late
create or replace function pg_temp.sc_j() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.g1c_prefix('j');
  insert into t values ('rj', pg_temp.run2('a1', '{"01": "200000"}', 36000, 6000, 15, 100, 'j-r2'));
  insert into t values ('x2', pg_temp.trid('rj'));
  perform pg_temp.handed_out('f2', 'j-g2', 2);
  v := v || jsonb_build_object('cancel_f2', pg_temp.cancel_whole('f2', 'jf2', 'c6', 2),
                               'cancel_rj', pg_temp.try('04', pg_temp.cancel_run('j-rjc', 'rj')));
  perform pg_temp.lines('c7', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0'))),
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x2')))));
  v := v || jsonb_build_object('first', pg_temp.parts(pg_temp.ln('c7', 1)),
                               'book1', pg_temp.bkx(pg_temp.ln('c7', 1), pg_temp.prop(pg_temp.ln('c7', 1))));
  return v || jsonb_build_object(
    'second', (select jsonb_agg(jsonb_build_array(p ->> 'kind', p ->> 'paid_minor', p ->> 'advance_minor', p ->> 'p_bound'))
               from jsonb_array_elements(pg_temp.pv(pg_temp.ln('c7', 2), pg_temp.prop(pg_temp.ln('c7', 2))) -> 'parts') p),
    'book2', pg_temp.bkx(pg_temp.ln('c7', 2), pg_temp.prop(pg_temp.ln('c7', 2))),
    'attributed', (select jsonb_agg(u.amount_minor order by u.amount_minor) from private.unplanned_paid_item u
                   where u.client_organization_id = '00000000-0000-0000-0000-0000000000a1'),
    'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'j', pg_temp.isolated('sc_j');
select results_eq($$ select v ->> 'cancel_f2', v ->> 'cancel_rj', v -> 'first', v ->> 'book1' from j where k = 'j' $$,
  $$ values ('requested/superseded'::text, 'cancelled'::text,
             '[["unplanned_payout", true, "164000", "0", "amount", null]]'::jsonb, 'ok'::text) $$,
  'J: the first late transfer nets what its run was to pay (P = A from the released collection)');
select results_eq($$ select v -> 'second', v ->> 'book2', v -> 'attributed', v -> 'dirty' from j where k = 'j' $$,
  $$ values ('[["unplanned_payout", "0", "164000", "items"]]'::jsonb, 'ok'::text, '[164000]'::jsonb, '[]'::jsonb) $$,
  'J (OQ-82, Q3 (a)): the second, of another transfer for the same collection, nets nothing more — the collection already netted is left out (never the commission share taken from the client''s other collections), the whole of it the servicer''s advance');


-- T17: what the client space says of a cancelled run (client_remittance_summary's cancelled_runs) -------------------------
create or replace function pg_temp.outcome() returns text language sql as $$
  select x ->> 'transfer_outcome'
  from jsonb_array_elements(pg_temp.read(format('select public.client_remittance_summary(%L)',
                                                '00000000-0000-0000-0000-0000000000a1')) -> 'cancelled_runs') x
  where (x ->> 'run_id')::uuid = pg_temp.v('r1') $$;
grant execute on all functions in schema pg_temp to authenticated;
create or replace function pg_temp.sc_t17a() returns jsonb language plpgsql as $$
begin
  perform pg_temp.g1c_prefix('t17a');
  return jsonb_build_object('outcome', pg_temp.outcome());
end $$;
create or replace function pg_temp.sc_t17b() returns jsonb language plpgsql as $$
begin
  perform pg_temp.handed_out('f1', 't17b-g1', 0);
  perform pg_temp.cancel_whole('f1', 't17b', 'b1');
  perform pg_temp.try('04', pg_temp.cancel_run('t17b-run', 'r1'));
  return jsonb_build_object('outcome', pg_temp.outcome(), 'run', pg_temp.run_status('r1'));
end $$;
create or replace function pg_temp.sc_t17c() returns jsonb language plpgsql as $$
begin
  perform pg_temp.try('04', pg_temp.cancel_run('t17c-run', 'r1'));
  return jsonb_build_object('outcome', pg_temp.outcome(), 'run', pg_temp.run_status('r1'));
end $$;
insert into j select 't17a', pg_temp.isolated('sc_t17a');
insert into j select 't17b', pg_temp.isolated('sc_t17b');
insert into j select 't17c', pg_temp.isolated('sc_t17c');
select results_eq($$ select k, v ->> 'outcome', coalesce(v ->> 'run', 'cancelled') from j
                     where k in ('t17a', 't17b', 't17c') order by k $$,
  $$ values ('t17a'::text, 'not_executed'::text, 'cancelled'::text), ('t17b', 'never_handed_out', 'cancelled'),
            ('t17c', 'never_handed_out', 'cancelled') $$,
  'T17: a cancelled run whose payout was cancelled alone out of a live downloaded file reads « la banque n''a pas exécuté son virement » (not_executed); one whose file was closed « jamais déposé », or never downloaded, keeps « Annulé avant la remise de son virement à la banque »');


-- 6b-3a's lows -----------------------------------------------------------------------------------------------------------
-- a manual refund (no transfer of ours) linked to a debit with no reference while a refund of another payment at its
-- amount, cancelled out of a downloaded file, may be that debit: refused in the database too (« Lier » never offers it)
create or replace function pg_temp.sc_lw1() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f0', 'lw1-g0', 0);
  insert into j select 'rq', pg_temp.refund('71', 5000);
  perform pg_temp.handed_out('f1', 'lw1-g1', 0);
  perform pg_temp.cancel_whole('f1', 'lw1', 'b1');
  perform pg_temp.try('01', pg_temp.cancel_refund('lw1-crf', 'rq'));
  perform pg_temp.collect('73', 5000, private.paris_today() - 1, false);
  perform pg_temp.as_user('01');
  set local role authenticated;
  insert into j select 'rm', public.request_refund(pg_temp.k('lw1-rm'), pg_temp.pay('73'), '5000',
                                                   'FR7630004000031234567890143', 'Payeur Manuel', 'other', null,
                                                   '5000', 'remboursement manuel', 'manual');
  reset role;
  perform pg_temp.lines('c8', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 5000)));
  return v || jsonb_build_object('mode', (select execution_mode from public.refund_request where id = pg_temp.rq('rm')),
                                 'listed', pg_temp.listed(pg_temp.ln('c8'), array['rm']),
                                 'link', pg_temp.link('lw1-lk', pg_temp.ln('c8'), 'refund', pg_temp.rq('rm')),
                                 'status', (select status from public.refund_request where id = pg_temp.rq('rm')));
end $$;
insert into j select 'lw1', pg_temp.isolated('sc_lw1');
select results_eq($$ select v ->> 'mode', v -> 'listed', v ->> 'link', v ->> 'status' from j where k = 'lw1' $$,
  $$ values ('manual'::text, '[]'::jsonb, 'debit link refused: payout_candidate'::text, 'requested'::text) $$,
  'low (6b-3a review): a manual refund''s link to a debit without reference is refused beside a cancelled refund of another payment at its amount — not only hidden by « Lier »');
-- cancel_remittance_run's hint while the run's payout chain may have been debited (the switch on): the exit is
-- « Comptabiliser… » in « Débits et retours »
create or replace function pg_temp.sc_lw2() returns jsonb language plpgsql as $$
begin
  perform pg_temp.lp_prefix('lw2');
  perform pg_temp.x_late('c9');
  return jsonb_build_object('hint', pg_temp.try_hint('04', format(
    $q$ select public.cancel_remittance_run(%L, %L, %s, 'à refaire') $q$, pg_temp.k('lw2-run'), pg_temp.v('r1'),
    (select version from public.remittance_run where id = pg_temp.v('r1')))));
end $$;
insert into j select 'lw2', pg_temp.isolated('sc_lw2');
select results_eq($$ select split_part(v ->> 'hint', ' | ', 1),
                            split_part(v ->> 'hint', ' | ', 2) like '%Débits et retours%Comptabiliser%' from j
                     where k = 'lw2' $$,
  $$ values ('remittance run refused: transfer_already_debited'::text, true) $$,
  'low (6b-3a review, LD-3): cancel_remittance_run''s transfer_already_debited hint names the exit (« Comptabiliser… » in « Débits et retours »)');
-- Review round 1 (ADR-0014 « M2c-6b-3a-2 review fixes ») ---------------------------------------------------------------
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

-- DP-1, CSC-1: the late predecessors executed as two details of one entry the bank kept unsplit (no end-to-end id of
-- its own; the bank's charge taken from the entry, so no subset of the PmtInf makes it) — without a PmtInfId, and with
-- F1's: the re-issues are held already_debited (generation holds them), the P0 cancelled_transfer_debited raised for
-- the line, each re-issue alerted transfer_already_debited
create or replace function pg_temp.ru1(p_key text, p_pmt boolean) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; g jsonb;
begin
  perform pg_temp.lp_prefix(p_key);
  v_l := pg_temp.uline(case when p_pmt then 'd2' else 'd1' end, private.paris_today(),
                       case when p_pmt then 583890 else 584080 end,
                       jsonb_build_array(pg_temp.det(pg_temp.v('m0')), pg_temp.det(pg_temp.v('l0'))), null,
                       case when p_pmt then 50 else 240 end, case when p_pmt then pg_temp.pmt('f1', 1) end);
  v := v || jsonb_build_object('class', private.transfer_line_class(v_l),
    'holds', jsonb_build_array(pg_temp.hold(pg_temp.v('y')), pg_temp.hold(pg_temp.v('yl'))));
  insert into t select 'cu', pg_temp.chk(null);
  v := v || jsonb_build_object('p0', pg_temp.raised('cu', 'cancelled_transfer_debited'),
                               'alerted', to_jsonb(pg_temp.already_debited('cu')));
  g := pg_temp.gen_try(p_key || '-g2');
  return v || jsonb_build_object('held', pg_temp.held_of(g),
    'after', jsonb_build_array(pg_temp.status(pg_temp.v('y')), pg_temp.status(pg_temp.v('yl'))));
end $$;
create or replace function pg_temp.sc_ru1() returns jsonb language sql as $$ select pg_temp.ru1('ru1', false) $$;
create or replace function pg_temp.sc_ru1p() returns jsonb language sql as $$ select pg_temp.ru1('ru1p', true) $$;
insert into j select 'ru1', pg_temp.isolated('sc_ru1');
insert into j select 'ru1p', pg_temp.isolated('sc_ru1p');
select results_eq($$ select k, v ->> 'class', v -> 'holds', (v ->> 'p0')::int, v -> 'alerted', v -> 'held', v -> 'after'
                     from j where k in ('ru1', 'ru1p') order by k $$,
  $$ values ('ru1'::text, 'U'::text, '["already_debited", "already_debited"]'::jsonb, 1,
             '["payout 164000 ordered", "payout 419840 ordered"]'::jsonb,
             '["payout 164000 already_debited", "payout 419840 already_debited"]'::jsonb, '["ordered", "ordered"]'::jsonb),
            ('ru1p', 'U', '["already_debited", "already_debited"]', 1, '["payout 164000 ordered", "payout 419840 ordered"]',
             '["payout 164000 already_debited", "payout 419840 already_debited"]', '["ordered", "ordered"]') $$,
  'DP-1, CSC-1: two late predecessors executed as details of one entry kept unsplit (a charge taken, with or without a PmtInfId) — their re-issues held already_debited, generation holds them, the P0 raised and each re-issue alerted');

-- DP-1 (the evidence): a downloaded file whose two payouts the bank executed on time as details of one entry kept unsplit
-- (no PmtInfId): the evidence sees their debit — the file, and either transfer alone, cannot be cancelled on it
create or replace function pg_temp.sc_ru2() returns jsonb language plpgsql as $$
begin
  perform pg_temp.handed_out('f1', 'ru2-g1', 0);
  insert into t values ('m0', pg_temp.trid('r1')), ('l0', pg_temp.trid('r2'));
  perform pg_temp.uline('d3', pg_temp.d(0), 583840,
                        jsonb_build_array(pg_temp.det(pg_temp.v('m0')), pg_temp.det(pg_temp.v('l0'))), null, null, null,
                        pg_temp.d(0), pg_temp.d(1), pg_temp.after(1));
  return jsonb_build_object('file', pg_temp.ev('f1', null, 'refusal'), 'one', pg_temp.ev('f1', pg_temp.v('m0'), 'refusal'),
    'request', pg_temp.try('01', pg_temp.req_file('ru2-rq', 'f1')) like '%debit_seen%',
    'f1', (pg_temp.fl(pg_temp.v('f1'))).status);
end $$;
insert into j select 'ru2', pg_temp.isolated('sc_ru2');
select results_eq($$ select v ->> 'file', v ->> 'one', (v ->> 'request')::boolean, v ->> 'f1' from j where k = 'ru2' $$,
  $$ values ('debit_seen'::text, 'debit_seen'::text, true, 'downloaded'::text) $$,
  'DP-1 (evidence): a file executed as details of an entry kept unsplit, without PmtInfId — debit_seen, for the file and for one of its transfers; nothing cancelled');

-- DP-2, CSC-2: the late predecessor as an entry's detail (class U) — S08's ISO shape (one detail of ours at N, the entry
-- N + F with the bank's charge): proposed and booked payout (late predecessor) + the bank's fee; the re-issue cancelled
create or replace function pg_temp.sc_ru3() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_p jsonb;
begin
  perform pg_temp.lp_prefix('ru3');
  v_l := pg_temp.uline('d4', private.paris_today(), 164120, jsonb_build_array(pg_temp.det(pg_temp.v('m0'))),
                       pg_temp.e2e(pg_temp.v('m0')), 120);
  v_p := pg_temp.op(v_l);
  v := v || jsonb_build_object('class', private.transfer_line_class(v_l), 'refusal', v_p ->> 'refusal',
    'req', pg_temp.req(v_l), 'lp', v_p #>> '{proposals,0,parts,0,late_predecessor}',
    'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  return v || jsonb_build_object('after', jsonb_build_array(pg_temp.run_status('r1'), pg_temp.status(pg_temp.v('y')),
                                                            pg_temp.status(pg_temp.v('m0'))),
                                 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
-- two late predecessors (Martin's and Lilas') as the two details of one entry: both runs booked, both re-issues cancelled
create or replace function pg_temp.sc_ru4() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid;
begin
  perform pg_temp.lp_prefix('ru4');
  v_l := pg_temp.uline('d5', private.paris_today(), 583840,
                       jsonb_build_array(pg_temp.det(pg_temp.v('m0')), pg_temp.det(pg_temp.v('l0'))));
  v := v || jsonb_build_object('req', pg_temp.req(v_l),
    'lp', (select jsonb_agg(p ->> 'late_predecessor') from jsonb_array_elements(pg_temp.op(v_l) #> '{proposals,0,parts}') p),
    'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  return v || jsonb_build_object('after', jsonb_build_array(pg_temp.run_status('r1'), pg_temp.run_status('r2'),
                                                            pg_temp.status(pg_temp.v('y')), pg_temp.status(pg_temp.v('yl'))),
                                 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
-- two transfers of one run's chain (x, and its re-issue y cancelled with its own downloaded file) as two details of one
-- entry: never booked as two payouts of one run (a double settlement) — unsplit_not_bookable, nothing changes
create or replace function pg_temp.sc_ru5() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_p jsonb;
begin
  perform pg_temp.lp_prefix('ru5');
  perform pg_temp.handed_out('f2', 'ru5-g2', 2);
  v := v || jsonb_build_object('cancel_f2', pg_temp.cancel_whole('f2', 'ru5f2', 'e5', 2));
  v_l := pg_temp.uline('d6', private.paris_today(), 328000,
                       jsonb_build_array(pg_temp.det(pg_temp.v('m0')), pg_temp.det(pg_temp.v('y'))));
  v_p := pg_temp.op(v_l);
  return v || jsonb_build_object('refusal', v_p ->> 'refusal',
    'proposals', jsonb_array_length(coalesce(v_p -> 'proposals', '[]')),
    'command', pg_temp.bkx(v_l, jsonb_build_array(pg_temp.pt('payout', pg_temp.v('m0'), 164000),
                                                  pg_temp.pt('payout', pg_temp.v('y'), 164000))),
    'run', pg_temp.run_status('r1'));
end $$;
insert into j select 'ru3', pg_temp.isolated('sc_ru3');
insert into j select 'ru4', pg_temp.isolated('sc_ru4');
insert into j select 'ru5', pg_temp.isolated('sc_ru5');
select results_eq($$ select v ->> 'class', v ->> 'refusal', v -> 'req', v ->> 'lp', v ->> 'book', v -> 'after', v -> 'dirty'
                     from j where k = 'ru3' $$,
  $$ values ('U'::text, null::text, '[["payout", "164000"], ["fee", "120"]]'::jsonb, 'true'::text, 'ok'::text,
             '["booked", "cancelled", "cancelled"]'::jsonb, '[]'::jsonb) $$,
  'DP-2, CSC-2 (class U, S08''s shape): the late predecessor as an entry''s one detail with the bank''s charge — payout (late predecessor) + fee proposed and booked, the run booked, its re-issue cancelled');
select results_eq($$ select v -> 'req', v -> 'lp', v ->> 'book', v -> 'after', v -> 'dirty' from j where k = 'ru4' $$,
  $$ values ('[["payout", "164000"], ["payout", "419840"]]'::jsonb, '["true", "true"]'::jsonb, 'ok'::text,
             '["booked", "booked", "cancelled", "cancelled"]'::jsonb, '[]'::jsonb) $$,
  'DP-2, CSC-2 (class U, two details): both late predecessors booked as their runs'' payouts, both re-issues cancelled');
select results_eq($$ select v ->> 'cancel_f2', v ->> 'refusal', (v ->> 'proposals')::int, v ->> 'command', v ->> 'run'
                     from j where k = 'ru5' $$,
  $$ values ('requested/superseded'::text, 'unsplit_not_bookable'::text, 0, 'unsplit_not_bookable'::text,
             'approved'::text) $$,
  'CSC-2: two transfers of one run''s chain as two details of one entry — never two payouts of one run: unsplit_not_bookable, the run still approved');

-- DP-3: the late predecessor booked, returned by the client's bank (its return item owed again), then executed again by
-- the bank — « Virement hors reversement » netted against that return item (P = A), never paid a second time by the
-- client's next run; and (E4b's chain) the re-issue cancelled alone, the predecessor booked and returned, then the
-- re-issue executed late: the same
create or replace function pg_temp.sc_rg4() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_r uuid;
begin
  perform pg_temp.lp_prefix('rg4');
  v_l := pg_temp.x_late('a7');
  v := v || jsonb_build_object('lp', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  perform pg_temp.lines('a8', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')))));
  v_r := pg_temp.ln('a8');
  v := v || jsonb_build_object('ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)), 'queue_returned', pg_temp.queue_of('a1'));
  v_l := pg_temp.x_late('a9');
  return v || jsonb_build_object('again', pg_temp.parts(v_l), 'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)),
    'queue', pg_temp.queue_of('a1'),
    'advances', (select coalesce(jsonb_agg(a.cause), '[]') from public.client_advance a
                 where a.client_organization_id = '00000000-0000-0000-0000-0000000000a1'),
    'dirty', to_jsonb(pg_temp.dirty()));
end $$;
create or replace function pg_temp.sc_rg5() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_r uuid;
begin
  perform pg_temp.lp_prefix('rg5');
  perform pg_temp.handed_out('f2', 'rg5-g2', 2);
  insert into t values ('s2', (pg_temp.sweep(pg_temp.v('f2'))).id);
  perform pg_temp.lines('b7', pg_temp.d(3), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('yl')), 'day', pg_temp.d(2)),
    jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s2')), 'day', pg_temp.d(2))),
    pg_temp.d(2), pg_temp.after(3));
  v := v || jsonb_build_object('cancel_y', pg_temp.try('01', pg_temp.req_tr('rg5-rq', pg_temp.v('y'))) || '/'
                                           || pg_temp.try('04', pg_temp.conf_tr('rg5-cf', pg_temp.v('y'))));
  v_l := pg_temp.x_late('b8');
  v := v || jsonb_build_object('lp', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  perform pg_temp.lines('b9', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')))));
  v_r := pg_temp.ln('b9');
  v := v || jsonb_build_object('ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('ba', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')))));
  v_l := pg_temp.ln('ba');
  return v || jsonb_build_object(
    'y_parts', (select jsonb_agg(jsonb_build_array(p ->> 'kind', p ->> 'paid_minor', p ->> 'advance_minor', p ->> 'p_bound'))
                from jsonb_array_elements(pg_temp.pv(v_l, pg_temp.prop(v_l)) -> 'parts') p),
    'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)), 'queue', pg_temp.queue_of('a1'), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'rg4', pg_temp.isolated('sc_rg4');
insert into j select 'rg5', pg_temp.isolated('sc_rg5');
select results_eq($$ select v ->> 'lp', v ->> 'ret', (v ->> 'queue_returned')::bigint, v -> 'again', v ->> 'book',
                            (v ->> 'queue')::bigint, v -> 'advances', v -> 'dirty' from j where k = 'rg4' $$,
  $$ values ('ok'::text, 'ok'::text, 164000::bigint, '[["unplanned_payout", true, "164000", "0", "amount", null]]'::jsonb,
             'ok'::text, 0::bigint, '[]'::jsonb, '[]'::jsonb) $$,
  'DP-3: the late predecessor returned, then executed again — « Virement hors reversement » netted against its own return item (P = A): the client''s queue 0, no advance, nothing paid twice');
select results_eq($$ select v ->> 'cancel_y', v ->> 'lp', v ->> 'ret', v -> 'y_parts', v ->> 'book', (v ->> 'queue')::bigint,
                            v -> 'dirty' from j where k = 'rg5' $$,
  $$ values ('requested/cancelled'::text, 'ok'::text, 'ok'::text, '[["unplanned_payout", "164000", "0", "amount"]]'::jsonb,
             'ok'::text, 0::bigint, '[]'::jsonb) $$,
  'DP-3 (the chain): the re-issue cancelled alone, the predecessor booked and returned, then the re-issue executed late — netted against the chain''s return item (P = A), nothing paid twice');

-- LD-1 (CPCE-08): E3's state (the re-issue y in a downloaded file) while the predecessor's own-id debit, dated on or
-- before L, waits on a statement (the booking refused reissue_in_downloaded_file): the nightly check after L, past the
-- bound days, writes no row (that debit paid the client on time); y's file cancelled on evidence, the late predecessor
-- booked — still no row, the run booked on time
create or replace function pg_temp.sc_ri7() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid;
begin
  perform pg_temp.lp_prefix('ri7');
  perform pg_temp.handed_out('f2', 'ri7-g2', 2);
  -- (the transfers' requested execution dates set back with their files: x and y asked for d(0); x's debit today, on
  -- or before L)
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0) where id in (pg_temp.v('m0'), pg_temp.v('y'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  perform pg_temp.lines('c2', pg_temp.lx(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', private.paris_today())),
    pg_temp.d(2), ((pg_temp.lx() + 1) + time '09:00') at time zone 'Europe/Paris');
  v_l := pg_temp.ln('c2');
  v := v || jsonb_build_object('refusal', pg_temp.op(v_l) ->> 'refusal');
  insert into t select 'c1', pg_temp.chk(pg_temp.after_l(8));
  v := v || jsonb_build_object('nightly', pg_temp.breaches('r1'), 'cancel_f2', pg_temp.cancel_whole('f2', 'ri7f2', 'e5', 2),
                               'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  return v || jsonb_build_object('after', pg_temp.breaches('r1'),
    'run', (select jsonb_build_array(r.status, r.booked_on <= pg_temp.lx()) from public.remittance_run r
            where r.id = pg_temp.v('r1')));
end $$;
insert into j select 'ri7', pg_temp.isolated('sc_ri7');
select results_eq($$ select v ->> 'refusal', v -> 'nightly', v ->> 'cancel_f2', v ->> 'book', v -> 'after', v -> 'run'
                     from j where k = 'ri7' $$,
  $$ values ('reissue_in_downloaded_file'::text, '[]'::jsonb, 'requested/superseded'::text, 'ok'::text, '[]'::jsonb,
             '["booked", true]'::jsonb) $$,
  'LD-1 (CPCE-08): the predecessor''s own-id debit dated on or before L waits while its re-issue is in a downloaded file — no breach row after L past the bound days; that file cancelled, the late predecessor booked on time: still none');

-- LD-2 (CPCE-08): the re-issue y in a downloaded file; one statement holds the predecessor x's own-id debit on time and
-- y's own debit after L. The import books y's debit as the run's payout (x's is never automatic): the run's R124-6 rows
-- are held to x's earlier debit (the client was paid on time) — none; x's line is then « Virement hors reversement »
create or replace function pg_temp.sc_ri8() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_lx uuid; v_ly uuid;
begin
  perform pg_temp.lp_prefix('ri8');
  perform pg_temp.handed_out('f2', 'ri8-g2', 2);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0) where id in (pg_temp.v('m0'), pg_temp.v('y'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  -- « time moved on »: Martin's line's latest execution date L is d(4), its deadline two days later
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(4), deadline = pg_temp.d(6)
  where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  perform pg_temp.lines('c3', pg_temp.d(7), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', pg_temp.d(3)),
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')), 'day', pg_temp.d(6))), pg_temp.d(2),
    pg_temp.after(7));
  v_lx := pg_temp.ln('c3', 1);
  v_ly := pg_temp.ln('c3', 2);
  v := v || jsonb_build_object('y_late', pg_temp.pv(v_ly, pg_temp.prop(v_ly)) #>> '{parts,0,late}',
    'job', pg_temp.book(jsonb_build_array(jsonb_build_object('line', v_ly, 'kind', 'payout', 'transfer', pg_temp.v('y'))),
                        jsonb_build_array(jsonb_build_object('line', v_lx, 'reason', 'cancelled_transfer_debited'))) -> 'payouts');
  v := v || jsonb_build_object('run', (select jsonb_build_array(r.status, r.booked_on = pg_temp.d(6))
                                       from public.remittance_run r where r.id = pg_temp.v('r1')),
                               'rows', pg_temp.breaches('r1'),
                               'x_parts', pg_temp.parts(v_lx), 'book', pg_temp.bkx(v_lx, pg_temp.prop(v_lx)));
  -- (today's statement, its closing not given: the fixture's closing of today predates these debits)
  perform pg_temp.lines('c4', private.paris_today(), '[]');
  return v || jsonb_build_object('dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'ri8', pg_temp.isolated('sc_ri8');
select results_eq($$ select v ->> 'y_late', (v ->> 'job')::int, v -> 'run', v -> 'rows', v -> 'x_parts', v ->> 'book',
                            v -> 'dirty' from j where k = 'ri8' $$,
  $$ values ('false'::text, 1, '["booked", true]'::jsonb, '[]'::jsonb,
             '[["unplanned_payout", true, "0", "164000", "none", null]]'::jsonb, 'ok'::text, '[]'::jsonb) $$,
  'LD-2 (CPCE-08): the re-issue''s own debit after L booked by the import as the run''s payout while the predecessor''s own-id debit on time waits — no breach row (held to the earlier debit), the run booked at the re-issue''s date; the predecessor''s line « Virement hors reversement »');

-- LD-1 (the batch arm and the unsplit arm, CPCE-08): ri7's state with x's execution as a batch line of F1's payouts
-- PmtInf (no end-to-end id), or as a detail of an entry the bank kept unsplit (x's and Lilas' with the bank's charge),
-- dated on or before L — certainly x's: held as its own id is, no row; (forged) the PmtInf's other payout at x's amount,
-- the batch line no longer certainly x's — the row comes back after the bound days (« bloqué : débit possible non
-- comptabilisé », Q14's default for a line that only may be its debit)
create or replace function pg_temp.ri7b(p_key text, p_shape text) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid;
begin
  perform pg_temp.lp_prefix(p_key);
  perform pg_temp.handed_out('f2', p_key || '-g2', 2);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0) where id in (pg_temp.v('m0'), pg_temp.v('y'));
  -- (forged: Lilas' cancelled payout at Martin's amount, in the same PmtInf)
  update public.bank_transfer set amount_minor = 164000 where p_shape = 'ambiguous' and id = pg_temp.v('l0');
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  if p_shape = 'unsplit' then
    v_l := pg_temp.uline('c8', private.paris_today(), 583790,
                         jsonb_build_array(pg_temp.det(pg_temp.v('m0')), pg_temp.det(pg_temp.v('l0'))), null, 50, null,
                         pg_temp.d(2), pg_temp.lx(), ((pg_temp.lx() + 1) + time '09:00') at time zone 'Europe/Paris');
  else
    perform pg_temp.lines(case when p_shape = 'ambiguous' then 'c6' else 'c5' end, pg_temp.lx(), jsonb_build_array(
      jsonb_build_object('amount', 164000, 'pmt_inf', pg_temp.pmt('f1', 1), 'day', private.paris_today())),
      pg_temp.d(2), ((pg_temp.lx() + 1) + time '09:00') at time zone 'Europe/Paris');
    v_l := pg_temp.ln(case when p_shape = 'ambiguous' then 'c6' else 'c5' end);
  end if;
  v := v || jsonb_build_object('class', private.transfer_line_class(v_l),
                               'proposals', jsonb_array_length(coalesce(pg_temp.op(v_l) -> 'proposals', '[]')));
  insert into t select p_key, pg_temp.chk(pg_temp.after_l(8));
  return v || jsonb_build_object('nightly', pg_temp.breaches('r1'));
end $$;
create or replace function pg_temp.sc_ri7b() returns jsonb language sql as $$ select pg_temp.ri7b('ri7b', 'batch') $$;
create or replace function pg_temp.sc_ri7c() returns jsonb language sql as $$ select pg_temp.ri7b('ri7c', 'ambiguous') $$;
create or replace function pg_temp.sc_ri7d() returns jsonb language sql as $$ select pg_temp.ri7b('ri7d', 'unsplit') $$;
insert into j select 'ri7b', pg_temp.isolated('sc_ri7b');
insert into j select 'ri7c', pg_temp.isolated('sc_ri7c');
insert into j select 'ri7d', pg_temp.isolated('sc_ri7d');
select results_eq($$ select k, v ->> 'class', (v ->> 'proposals')::int, v -> 'nightly' from j
                     where k in ('ri7b', 'ri7c', 'ri7d') order by k $$,
  $$ values ('ri7b'::text, 'B'::text, 0, '[]'::jsonb), ('ri7c', 'B', 0, '["debit_unbooked"]'), ('ri7d', 'U', 0, '[]') $$,
  'LD-1 (the batch arm, the unsplit arm): x''s execution as a batch line of its PmtInf, or as a detail of an entry kept unsplit, dated on or before L, its re-issue in a downloaded file — held while certainly x''s (no row); once another transfer of the PmtInf can make the batch line (forged), the row after the bound days');

-- LD-2 (a returned predecessor): ri8's statement with x's return as well (the client's bank sent x back): x paid nothing,
-- so the run's rows are judged at y's debit, booked by the import after L — the row is written
create or replace function pg_temp.sc_ri8b() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_lx uuid; v_ly uuid;
begin
  perform pg_temp.lp_prefix('ri8b');
  perform pg_temp.handed_out('f2', 'ri8b-g2', 2);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0) where id in (pg_temp.v('m0'), pg_temp.v('y'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(4), deadline = pg_temp.d(6)
  where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  perform pg_temp.lines('c7', pg_temp.d(7), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', pg_temp.d(3)),
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', pg_temp.d(5)),
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')), 'day', pg_temp.d(6))), pg_temp.d(2),
    pg_temp.after(7));
  v_lx := pg_temp.ln('c7', 1);
  v_ly := pg_temp.ln('c7', 3);
  v := v || jsonb_build_object('y_late', pg_temp.pv(v_ly, pg_temp.prop(v_ly)) #>> '{parts,0,late}',
    'job', pg_temp.book(jsonb_build_array(jsonb_build_object('line', v_ly, 'kind', 'payout', 'transfer', pg_temp.v('y'))),
                        jsonb_build_array(jsonb_build_object('line', v_lx, 'reason', 'cancelled_transfer_debited'))) -> 'payouts');
  return v || jsonb_build_object('run', (select jsonb_build_array(r.status, r.booked_on = pg_temp.d(6))
                                         from public.remittance_run r where r.id = pg_temp.v('r1')),
                                 'rows', pg_temp.breaches('r1'));
end $$;
insert into j select 'ri8b', pg_temp.isolated('sc_ri8b');
select results_eq($$ select v ->> 'y_late', (v ->> 'job')::int, v -> 'run', v -> 'rows' from j where k = 'ri8b' $$,
  $$ values ('true'::text, 1, '["booked", true]'::jsonb, '["none"]'::jsonb) $$,
  'LD-2 (a returned predecessor): x''s on-time debit sent back by the client''s bank — the run''s rows judged at the re-issue''s debit after L: written (the client was not paid on time)');

-- tests-1 (J2): a netting that the first transfer's return reversed is not counted — x1 executed late and booked
-- « Virement hors reversement » (netting the collection), x1 returned (its booking reversed), then x2 (another cancelled
-- run's payout for the same collection) executed late: P = A again
create or replace function pg_temp.sc_jr() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid;
begin
  perform pg_temp.g1c_prefix('jr');
  insert into t values ('rj', pg_temp.run2('a1', '{"01": "200000"}', 36000, 6000, 15, 100, 'jr-r2'));
  insert into t values ('x2', pg_temp.trid('rj'));
  perform pg_temp.handed_out('f2', 'jr-g2', 2);
  v := v || jsonb_build_object('cancel_f2', pg_temp.cancel_whole('f2', 'jrf2', 'c6', 2),
                               'cancel_rj', pg_temp.try('04', pg_temp.cancel_run('jr-rjc', 'rj')));
  perform pg_temp.lines('c7', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')))));
  v := v || jsonb_build_object('book1', pg_temp.bkx(pg_temp.ln('c7', 1), pg_temp.prop(pg_temp.ln('c7', 1))));
  perform pg_temp.lines('c8', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')))));
  v_r := pg_temp.ln('c8');
  v := v || jsonb_build_object('ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c9', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x2')))));
  return v || jsonb_build_object(
    'second', (select jsonb_agg(jsonb_build_array(p ->> 'kind', p ->> 'paid_minor', p ->> 'advance_minor', p ->> 'p_bound'))
               from jsonb_array_elements(pg_temp.pv(pg_temp.ln('c9'), pg_temp.prop(pg_temp.ln('c9'))) -> 'parts') p),
    'book2', pg_temp.bkx(pg_temp.ln('c9'), pg_temp.prop(pg_temp.ln('c9'))), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'jr', pg_temp.isolated('sc_jr');
select results_eq($$ select v ->> 'book1', v ->> 'ret', v -> 'second', v ->> 'book2', v -> 'dirty' from j where k = 'jr' $$,
  $$ values ('ok'::text, 'ok'::text, '[["unplanned_payout", "164000", "0", "amount"]]'::jsonb, 'ok'::text, '[]'::jsonb) $$,
  'J2 (tests-1): a netting the first transfer''s return reversed is not counted — the second late transfer nets the collection again (P = A)');

-- tests-2 (T17d): a downloaded file cancelled whole, attested « rejeté par la banque », then its run cancelled: the
-- client space reads « la banque n'a pas exécuté son virement » (not_executed)
create or replace function pg_temp.sc_t17d() returns jsonb language plpgsql as $$
declare v jsonb := '{}';
begin
  perform pg_temp.handed_out('f1', 't17d-g1', 0);
  perform pg_temp.lines('b1', pg_temp.d(1), '[]', pg_temp.d(0), pg_temp.after(1));
  v := v || jsonb_build_object('cancel', pg_temp.try('01', format(
    $q$ select public.request_transfer_file_cancellation(%L, %L, %s, 'Rejeté par la banque', 'rejected_by_bank') ->> 'status' $q$,
    pg_temp.k('t17d-rq'), pg_temp.v('f1'), (pg_temp.fl(pg_temp.v('f1'))).version))
    || '/' || pg_temp.try('04', pg_temp.conf_file('t17d-cf', 'f1')));
  v := v || jsonb_build_object('attestation', (pg_temp.fl(pg_temp.v('f1'))).close_attestation,
                               'cancel_run', pg_temp.try('04', pg_temp.cancel_run('t17d-run', 'r1')));
  return v || jsonb_build_object('outcome', coalesce(pg_temp.outcome(), 'none'));
end $$;
insert into j select 't17d', pg_temp.isolated('sc_t17d');
select results_eq($$ select v ->> 'cancel', v ->> 'attestation', v ->> 'cancel_run', v ->> 'outcome' from j where k = 't17d' $$,
  $$ values ('requested/rejected'::text, 'rejected_by_bank'::text, 'cancelled'::text, 'not_executed'::text) $$,
  'T17d (tests-2): a downloaded file cancelled whole as rejected by the bank, then its run cancelled — not_executed');

-- tests-3: the late predecessor's defences in depth (forged states, as F1b): (a) x's RMT id on a line of another
-- dedicated account of the servicer —
-- transfer_differs; (b) the chain already debited — y forged booked, or a payout booking forged on y while the run is
-- still sent — already_debited; (c) a refund in a downloaded file whose request is no longer requested — cancelled with
-- its file, never re-issued (H's refund arm); (d) I20: a second payout booking forged in the chain, or x forged under
-- another booked run whose chain does not hold it — transfer_booked_once
create or replace function pg_temp.sc_rt3a() returns jsonb language plpgsql as $$
begin
  perform pg_temp.lp_prefix('rt3a');
  insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on)
  values (pg_temp.cg(), '00000000-0000-0000-0000-0000000000aa', 'client_funds', 'FR7630001007941234567890185',
          'TESTFRPPXXX', 'EUR', 'Fonds de tiers 2', 'camt053', '2026-01-01');
  perform pg_temp.lines('fa', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')))), null, null, 'camt053', pg_temp.cg());
  return jsonb_build_object('why', pg_temp.why(pg_temp.ln('fa'),
                                               jsonb_build_array(pg_temp.pt('payout', pg_temp.v('m0'), 164000))));
end $$;
create or replace function pg_temp.sc_rt3b() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_o uuid;
begin
  perform pg_temp.lp_prefix('rt3b');
  v_l := pg_temp.x_late('fb');
  alter table public.bank_transfer disable trigger user;
  update public.bank_transfer set status = 'booked',
    entry_id = (select id from public.ledger_entry where idempotency_key like 'cash_in:%' order by id limit 1)
  where id = pg_temp.v('y');
  alter table public.bank_transfer enable trigger user;
  v := v || jsonb_build_object('y_booked', pg_temp.why(v_l, jsonb_build_array(pg_temp.pt('payout', pg_temp.v('m0'), 164000))));
  alter table public.bank_transfer disable trigger user;
  update public.bank_transfer set status = 'ordered', entry_id = null where id = pg_temp.v('y');
  alter table public.bank_transfer enable trigger user;
  perform pg_temp.lines('fc', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 164000,
                                                                                         'kind', 'other_debit')));
  v_o := pg_temp.ln('fc');
  alter table public.bank_line_booking disable trigger user;
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method)
  values (v_o, 1, '00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), 'payout', pg_temp.v('y'),
          (select id from public.ledger_entry where idempotency_key like 'cash_in:%' order by id limit 1), 164000, 'auto');
  alter table public.bank_line_booking enable trigger user;
  return v || jsonb_build_object('y_payout_booking', pg_temp.why(v_l, jsonb_build_array(pg_temp.pt('payout', pg_temp.v('m0'), 164000))),
                                 'run', pg_temp.run_status('r1'));
end $$;
create or replace function pg_temp.sc_rt3c() returns jsonb language plpgsql as $$
begin
  perform pg_temp.handed_out('f0', 'rt3c-g0', 0);
  insert into j select 'rq', pg_temp.refund('71', 5000);
  perform pg_temp.handed_out('f1', 'rt3c-g1', 0);
  insert into t values ('q0', pg_temp.rft('rq'));
  alter table public.refund_request disable trigger user;
  update public.refund_request set status = 'cancelled', cancelled_at = now(),
    cancelled_by = '10000000-0000-0000-0000-000000000001', cancel_reason = 'forgé (test)'
  where id = pg_temp.rq('rq');
  alter table public.refund_request enable trigger user;
  return jsonb_build_object('cancel', pg_temp.cancel_whole('f1', 'rt3c', 'b1'),
    'q0', jsonb_build_array(pg_temp.status(pg_temp.v('q0')),
                            exists (select 1 from public.bank_transfer y where y.replaces_transfer_id = pg_temp.v('q0'))));
end $$;
create or replace function pg_temp.sc_rt3d() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_o uuid; v_y public.bank_transfer;
begin
  perform pg_temp.lp_prefix('rt3d');
  v_l := pg_temp.x_late('fd');
  v := v || jsonb_build_object('book', pg_temp.bkx(v_l, pg_temp.prop(v_l)), 'clean', to_jsonb(pg_temp.dirty()));
  perform pg_temp.lines('fe', private.paris_today(), jsonb_build_array(jsonb_build_object('amount', 164000,
                                                                                         'kind', 'other_debit')));
  v_o := pg_temp.ln('fe');
  alter table public.bank_line_booking disable trigger user;
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method)
  values (v_o, 1, '00000000-0000-0000-0000-0000000000aa', pg_temp.cf(), 'payout', pg_temp.v('y'),
          (select id from public.ledger_entry where idempotency_key like 'cash_in:%' order by id limit 1), 164000, 'auto');
  alter table public.bank_line_booking enable trigger user;
  v := v || jsonb_build_object('two_bookings', pg_temp.dirty() @> array['transfer_booked_once']);
  -- (and y forged booked by that payout booking too: y's own row is then whole, x's late predecessor is not)
  select * into v_y from public.bank_transfer where id = pg_temp.v('y');
  alter table public.bank_transfer disable trigger user;
  update public.bank_transfer set status = 'booked', cancelled_at = null, cancelled_by = null, cancel_reason = null,
    entry_id = (select id from public.ledger_entry where idempotency_key like 'cash_in:%' order by id limit 1)
  where id = pg_temp.v('y');
  alter table public.bank_transfer enable trigger user;
  v := v || jsonb_build_object('y_booked_too', pg_temp.dirty() @> array['transfer_booked_once']);
  alter table public.bank_transfer disable trigger user;
  update public.bank_transfer set status = v_y.status, entry_id = v_y.entry_id, cancelled_at = v_y.cancelled_at,
    cancelled_by = v_y.cancelled_by, cancel_reason = v_y.cancel_reason
  where id = pg_temp.v('y');
  alter table public.bank_transfer enable trigger user;
  alter table public.bank_line_booking disable trigger user;
  delete from public.bank_line_booking where bank_transaction_id = v_o;
  alter table public.bank_line_booking enable trigger user;
  alter table public.bank_transfer disable trigger user;
  update public.bank_transfer set run_id = pg_temp.v('r3') where id = pg_temp.v('m0');
  alter table public.bank_transfer enable trigger user;
  return v || jsonb_build_object('other_run', pg_temp.dirty() @> array['transfer_booked_once'],
                                 'r3', pg_temp.run_status('r3'));
end $$;
insert into j select 'rt3a', pg_temp.isolated('sc_rt3a');
insert into j select 'rt3b', pg_temp.isolated('sc_rt3b');
insert into j select 'rt3c', pg_temp.isolated('sc_rt3c');
insert into j select 'rt3d', pg_temp.isolated('sc_rt3d');
select results_eq($$ select (select v ->> 'why' from j where k = 'rt3a'),
                            (select v ->> 'y_booked' from j where k = 'rt3b'),
                            (select v ->> 'y_payout_booking' from j where k = 'rt3b'),
                            (select v ->> 'run' from j where k = 'rt3b') $$,
  $$ values ('transfer_differs'::text, 'already_debited'::text, 'already_debited'::text, 'approved'::text) $$,
  'tests-3 (a, b; forged): x''s RMT id on another account''s line — transfer_differs; the chain already debited (y forged booked, or a payout booking forged on y) — already_debited');
select results_eq($$ select (select v ->> 'cancel' from j where k = 'rt3c'), (select v -> 'q0' from j where k = 'rt3c'),
                            (select v ->> 'book' from j where k = 'rt3d'), (select v -> 'clean' from j where k = 'rt3d'),
                            (select (v ->> 'two_bookings')::boolean from j where k = 'rt3d'),
                            (select (v ->> 'y_booked_too')::boolean from j where k = 'rt3d'),
                            (select (v ->> 'other_run')::boolean from j where k = 'rt3d'),
                            (select v ->> 'r3' from j where k = 'rt3d') $$,
  $$ values ('requested/superseded'::text, '["cancelled", false]'::jsonb, 'ok'::text, '[]'::jsonb, true, true, true,
             'booked'::text) $$,
  'tests-3 (c, d; forged): a refund whose request is no longer requested is cancelled with its file, never re-issued; I20 flags a second payout booking in the chain (also when it books y whole), and a late predecessor under a booked run whose chain does not hold it');

-- tests-4 (F4, F5): the late predecessor booked, then returned (x keeps no return entry of its own: its return booking's
-- entry is the item owed again); the client's next run holds that payout_returned item and is booked — the run page's x
-- and the client's « Reversements » name that run as the one that paid it again (repaid_by)
create or replace function pg_temp.sc_rp() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_r uuid; v_run uuid; v_tr uuid; v_f uuid; r public.remittance_run;
  l public.remittance_line; v_page jsonb; v_sum jsonb;
begin
  perform pg_temp.lp_prefix('rp');
  v_l := pg_temp.x_late('d7');
  v := v || jsonb_build_object('lp', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  perform pg_temp.lines('d8', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')))));
  v_r := pg_temp.ln('d8');
  v := v || jsonb_build_object('ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  -- (Martin's payout account confirmed again by him: its return no longer blocks his payouts)
  alter table public.client_payout_account disable trigger user;
  update public.client_payout_account set status = 'active'
  where id = (select payout_account_id from public.remittance_run where id = pg_temp.v('r1'));
  alter table public.client_payout_account enable trigger user;
  -- his next run: the payout_returned item alone (the prepare job emulated as 035's pg_temp.prepare_returned), approved
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_run := (public.request_remittance_run(pg_temp.k('rp-r4'), '00000000-0000-0000-0000-0000000000a1') ->> 'run_id')::uuid;
  reset role;
  select * into r from public.remittance_run where id = v_run;
  select * into l from public.remittance_line x where x.run_id = pg_temp.v('r1') and x.amount_minor > 0
  order by x.latest_execution_date, x.line_no limit 1;
  perform private.remittance_prepare_begin(v_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, mandate_id, mandate_terms_id,
                                             encaissement_date, effective_date, posted_at, deadline,
                                             latest_execution_date, amount_minor, commission_state)
  select v_run, 1, q.ledger_entry_id, q.kind, l.mandate_id, l.mandate_terms_id, l.encaissement_date, e.effective_date,
         q.posted_at, private.paris_today() + 21, private.paris_today() + 20, q.amount_minor, 'none'
  from private.remittance_pending q join public.ledger_entry e on e.id = q.ledger_entry_id
  where q.draft_run_id = v_run;
  perform private.remittance_record_draft(v_run, r.job_token, jsonb_build_object(
    'line_count', 1, 'gross', '164000', 'invoice_ht', '0', 'invoice_vat', '0', 'invoice_ttc', '0', 'credit_ht', '0',
    'credit_vat', '0', 'credit_ttc', '0', 'taken', '0', 'advances', '0', 'refunds', '0', 'settlement', '0',
    'net', '164000', 'vat_rate', '0.2', 'earliest_deadline', private.paris_today() + 21,
    'earliest_latest_execution_date', private.paris_today() + 20, 'unmeetable', 0, 'blockers', '[]'::jsonb,
    'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(v_run::text, 'UTF8')), 'hex'),
    'payout_account_id', (select payout_account_id from public.remittance_run where id = pg_temp.v('r1')),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', '[]'::jsonb, 'key_states', '[]'::jsonb,
    'plan', jsonb_build_object('settles', '[]'::jsonb, 'net', '164000', 'settlement', '0', 'dc', '0', 'da', '0',
                               'vat_moved', '0', 'deferred', true, 'invoice_ht', '0', 'invoice_vat', '0',
                               'invoice_ttc', '0')));
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs(pg_temp.k('rp-ap4'), pg_temp.item(v_run));
  reset role;
  perform private.approve_remittance_run(v_run, (select job_token from public.remittance_run where id = v_run));
  v_tr := (select transfer_id from public.remittance_run where id = v_run);
  -- its payout in a file handed out, then debited and booked by the import
  v_f := (pg_temp.gen('01', 'rp-g2') ->> 'file_id')::uuid;
  perform pg_temp.write(v_f);
  perform pg_temp.download('01', v_f);
  perform pg_temp.lines('d9', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(v_tr))));
  v := v || jsonb_build_object('job', pg_temp.book(jsonb_build_array(
    jsonb_build_object('line', pg_temp.ln('d9'), 'kind', 'payout', 'transfer', v_tr))) -> 'payouts');
  v_page := pg_temp.read(format('select public.remittance_run_payout(%L)', pg_temp.v('r1')));
  v_sum := pg_temp.read(format('select public.client_remittance_summary(%L)', '00000000-0000-0000-0000-0000000000a1'));
  return v || jsonb_build_object(
    'run', (select status from public.remittance_run where id = v_run),
    'page', (select jsonb_agg(x ->> 'repaid_by' = r.number) from jsonb_array_elements(v_page -> 'transfers') x
             where (x ->> 'id')::uuid = pg_temp.v('m0')),
    'client', (select jsonb_agg(x ->> 'repaid_by' = r.number) from jsonb_array_elements(v_sum -> 'returned_runs') x
               where (x ->> 'run_id')::uuid = pg_temp.v('r1')),
    'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'rp', pg_temp.isolated('sc_rp');
select results_eq($$ select v ->> 'lp', v ->> 'ret', (v ->> 'job')::int, v ->> 'run', v -> 'page', v -> 'client', v -> 'dirty'
                     from j where k = 'rp' $$,
  $$ values ('ok'::text, 'ok'::text, 1, 'booked'::text, '[true]'::jsonb, '[true]'::jsonb, '[]'::jsonb) $$,
  'tests-4 (F4, F5): a returned late predecessor paid again by the client''s next run — the run page''s x and the client''s returned run name that run (repaid_by, through the return booking''s entry)');

-- pages-texts-4 (T17): a run cancelled after its payout was cancelled alone out of its live downloaded file; the bank's
-- late debit of that payout on a statement, not booked yet — the client space reads debit_pending (never « la banque
-- n'a pas exécuté son virement » while the statement shows a debit that may be it); once booked « Virement hors
-- reversement », not_executed again and the run listed as executed all the same (unplanned_runs, which the page shows
-- first)
create or replace function pg_temp.sc_t17e() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid;
begin
  perform pg_temp.g1c_prefix('t17e');
  v := v || jsonb_build_object('before', pg_temp.outcome());
  v_l := pg_temp.x_late('cb');
  v := v || jsonb_build_object('pending', pg_temp.outcome(), 'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  return v || jsonb_build_object('after', pg_temp.outcome(),
    'unplanned', (select jsonb_agg(x ->> 'run_id' = pg_temp.v('r1')::text)
                  from jsonb_array_elements(pg_temp.read(format('select public.client_remittance_summary(%L)',
                    '00000000-0000-0000-0000-0000000000a1')) -> 'unplanned_runs') x));
end $$;
-- pages-texts-5, DP-3: the late predecessor booked, then executed a second time — the sheet's part names its run booked
-- (run_status: the sums its return put back, not a cancelled run's), and the run page lists that second execution as
-- such (after_cancellation false: x paid the run)
create or replace function pg_temp.sc_p5() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid;
begin
  perform pg_temp.lp_prefix('p5');
  v_l := pg_temp.x_late('cc');
  v := v || jsonb_build_object('lp', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  v_l := pg_temp.x_late('cd');
  v := v || jsonb_build_object('part', (select jsonb_agg(jsonb_build_array(p ->> 'kind', p ->> 'run_status'))
                                        from jsonb_array_elements(pg_temp.pv(v_l, pg_temp.prop(v_l)) -> 'parts') p),
                               'book', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  return v || jsonb_build_object('unplanned', (select jsonb_agg(x ->> 'after_cancellation')
    from jsonb_array_elements(pg_temp.read(format('select public.remittance_run_payout(%L)', pg_temp.v('r1')))
                              -> 'unplanned') x));
end $$;
insert into j select 't17e', pg_temp.isolated('sc_t17e');
insert into j select 'p5', pg_temp.isolated('sc_p5');
select results_eq($$ select v ->> 'before', v ->> 'pending', v ->> 'book', v ->> 'after', v -> 'unplanned'
                     from j where k = 't17e' $$,
  $$ values ('not_executed'::text, 'debit_pending'::text, 'ok'::text, 'not_executed'::text, '[true]'::jsonb) $$,
  'pages-texts-4 (T17): a possible late debit of the cancelled run''s payout on a statement, not booked — debit_pending; booked « Virement hors reversement », not_executed and listed as executed all the same');
select results_eq($$ select v ->> 'lp', v -> 'part', v ->> 'book', v -> 'unplanned' from j where k = 'p5' $$,
  $$ values ('ok'::text, '[["unplanned_payout", "booked"]]'::jsonb, 'ok'::text, '["false"]'::jsonb) $$,
  'pages-texts-5, DP-3: the late predecessor executed a second time — its part names its run booked, and the run page lists a second execution (not one after the cancellation)');

-- Review round 2 (ADR-0014 « M2c-6b-3a-2 review fixes », round 2) ----------------------------------------------------
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

-- ld2-reissue-return-pays-twice (the run's payout chain executed twice: one copy is the run's payout, the other
-- « Virement hors reversement » with the servicer's advance): the copy that comes back closes the open unplanned one
-- (critic F1, over the run's chain) — never the run's payout re-queued while the client keeps the other copy. rr1: ri8's
-- state, y comes back (the client's bank returns the duplicate) while x's debit waits — debit_pending (unchanged); x
-- booked as proposed (its advance); y's return then closes x's « Virement hors reversement » (its advance reversed, the
-- queue 0, y still the run's payout, no breach row: x paid on time); then x comes back too — the return of the run's
-- payout (y's, booked on x's line: the client has nothing left of it, its sums owed again)
create or replace function pg_temp.sc_rr1() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid; v_rx uuid;
begin
  perform pg_temp.ld2_prefix('rr1', 3, 6);
  v_r := pg_temp.ret_line('c5', pg_temp.v('y'), 8);
  v := v || jsonb_build_object('first', pg_temp.op(v_r) ->> 'refusal',
    'x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))), 'adv_x', pg_temp.adv_open(),
    'ret_req', pg_temp.req(v_r), 'ret_parts', pg_temp.ret_parts(v_r, pg_temp.v('y'), pg_temp.v('m0')),
    'planned', pg_temp.bkx(v_r, jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('y'), 164000))));
  v := v || jsonb_build_object('ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select 'rr1c', pg_temp.chk(private.paris_today());
  v := v || jsonb_build_object('queue', pg_temp.queue_of('a1'), 'adv', pg_temp.adv_open(),
    'y', pg_temp.status(pg_temp.v('y')), 'run', pg_temp.run_status('r1'), 'rows', pg_temp.breaches('r1'),
    'dirty', to_jsonb(pg_temp.dirty()),
    'page', (select jsonb_agg(jsonb_build_array(x ->> 'returned',
                                                x ->> 'returned_by_end_to_end_id' = pg_temp.e2e(pg_temp.v('y'))))
             from jsonb_array_elements(pg_temp.read(format('select public.remittance_run_payout(%L)', pg_temp.v('r1')))
                                       -> 'unplanned') x));
  -- x comes back as well
  v_rx := pg_temp.ret_line('c7', pg_temp.v('m0'), 9);
  v := v || jsonb_build_object('x_req', pg_temp.req(v_rx),
                               'x_parts', pg_temp.ret_parts(v_rx, pg_temp.v('y'), pg_temp.v('m0')),
                               'x_ret', pg_temp.bkx(v_rx, pg_temp.prop(v_rx)));
  perform pg_temp.lines('c8', private.paris_today(), '[]');
  v := v || jsonb_build_object('x_queue', pg_temp.queue_of('a1'), 'x_y', pg_temp.status(pg_temp.v('y')),
                               'x_dirty', to_jsonb(pg_temp.dirty()));
  -- a further credit returning x (the bank's duplicate): nothing left of the run's payout to come back
  v_rx := pg_temp.ret_line('c9', pg_temp.v('m0'), 11);
  return v || jsonb_build_object('x_again', pg_temp.op(v_rx) ->> 'refusal');
end $$;
-- rr2 (the job): ri8's state, x's line booked by ops first; y's return on a later statement — its facts say an
-- unplanned booking of its chain is open, the job's planned row is refused by the SQL re-check and reviewed
-- unplanned_payout_return; ops book it as proposed
create or replace function pg_temp.sc_rr2() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid;
begin
  perform pg_temp.ld2_prefix('rr2', 3, 6);
  v := v || jsonb_build_object('x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  v_r := pg_temp.ret_line('c5', pg_temp.v('y'), 8);
  v := v || jsonb_build_object(
    'facts', (select jsonb_agg(jsonb_build_array(c.unplanned_open, c.debit_pending))
              from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 1000) c
              where c.line_id = v_r and c.role = 'return'),
    'job', pg_temp.book(jsonb_build_array(jsonb_build_object('line', v_r, 'kind', 'payout_returned',
                                                             'transfer', pg_temp.v('y')))) ->> 'returns');
  v := v || jsonb_build_object('review', (select reason from public.bank_debit_review where bank_transaction_id = v_r));
  v := v || jsonb_build_object('ret_req', pg_temp.req(v_r), 'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  return v || jsonb_build_object('queue', pg_temp.queue_of('a1'), 'adv', pg_temp.adv_open(),
                                 'y', pg_temp.status(pg_temp.v('y')), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
-- rr6 (the mirror: the late predecessor is the run's payout): E4b's state — y cancelled alone, x booked as the run's
-- payout, y executed late after all (« Virement hors reversement », its advance); x comes back: it closes y's open
-- unplanned booking (the client keeps y's copy), the queue 0; then y comes back too — the return of the run's payout
-- (x's, the late predecessor's, booked on y's line), its sums owed again
create or replace function pg_temp.sc_rr6() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_l uuid; v_r uuid;
begin
  perform pg_temp.lp_prefix('rr6');
  perform pg_temp.handed_out('f2', 'rr6-g2', 2);
  insert into t values ('s2', (pg_temp.sweep(pg_temp.v('f2'))).id);
  perform pg_temp.lines('e7', pg_temp.d(3), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('yl')), 'day', pg_temp.d(2)),
    jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s2')), 'day', pg_temp.d(2))),
    pg_temp.d(2), pg_temp.after(3));
  v := v || jsonb_build_object('cancel_y', pg_temp.try('01', pg_temp.req_tr('rr6-rq', pg_temp.v('y'))) || '/'
                                           || pg_temp.try('04', pg_temp.conf_tr('rr6-cf', pg_temp.v('y'))));
  v_l := pg_temp.x_late('e8');
  v := v || jsonb_build_object('lp', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  perform pg_temp.lines('e9', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')))));
  v_l := pg_temp.ln('e9');
  v := v || jsonb_build_object('y', pg_temp.bkx(v_l, pg_temp.prop(v_l)), 'adv_y', pg_temp.adv_open());
  perform pg_temp.lines('ea', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')))));
  v_r := pg_temp.ln('ea');
  v := v || jsonb_build_object('ret_parts', pg_temp.ret_parts(v_r, pg_temp.v('m0'), pg_temp.v('y')),
                               'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  v := v || jsonb_build_object('queue', pg_temp.queue_of('a1'), 'adv', pg_temp.adv_open(),
                               'run', pg_temp.run_status('r1'));
  perform pg_temp.lines('eb', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('y')))));
  v_r := pg_temp.ln('eb');
  v := v || jsonb_build_object('y_parts', pg_temp.ret_parts(v_r, pg_temp.v('m0'), pg_temp.v('y')),
                               'y_ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  return v || jsonb_build_object('y_queue', pg_temp.queue_of('a1'), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'rr1', pg_temp.isolated('sc_rr1');
insert into j select 'rr2', pg_temp.isolated('sc_rr2');
insert into j select 'rr6', pg_temp.isolated('sc_rr6');
select results_eq($$ select v ->> 'first', v ->> 'x', v -> 'adv_x', v -> 'ret_req', v -> 'ret_parts', v ->> 'planned',
                            v ->> 'ret' from j where k = 'rr1' $$,
  $$ values ('debit_pending'::text, 'ok'::text, '[164000]'::jsonb, '[["unplanned_payout_returned", "164000"]]'::jsonb,
             '[["unplanned_payout_returned", true, true]]'::jsonb, 'unplanned_open'::text, 'ok'::text) $$,
  'ld2-reissue-return-pays-twice: the re-issue y booked as the run''s payout and the predecessor x « Virement hors reversement » (its advance) — y''s return is proposed and booked as the return of x''s copy (naming x); as the run''s payout it is refused unplanned_open');
select results_eq($$ select (v ->> 'queue')::bigint, v -> 'adv', v ->> 'y', v ->> 'run', v -> 'rows', v -> 'dirty', v -> 'page'
                     from j where k = 'rr1' $$,
  $$ values (0::bigint, '[]'::jsonb, 'booked'::text, 'booked'::text, '[]'::jsonb, '[]'::jsonb,
             '[["true", true]]'::jsonb) $$,
  'ld2-reissue-return-pays-twice: after it — the client''s queue 0 (nothing paid twice), the advance reversed, y still the run''s payout, no breach row (x paid on time), every invariant clean; the run page says y''s return closed x''s copy');
select results_eq($$ select v -> 'x_req', v -> 'x_parts', v ->> 'x_ret', (v ->> 'x_queue')::bigint, v ->> 'x_y', v -> 'x_dirty',
                            v ->> 'x_again' from j where k = 'rr1' $$,
  $$ values ('[["payout_returned", "164000"]]'::jsonb, '[["payout_returned", true, true]]'::jsonb, 'ok'::text,
             164000::bigint, 'returned'::text, '[]'::jsonb, 'transfer_cancelled'::text) $$,
  'ld2-reissue-return-pays-twice: x comes back too — the return of the run''s payout (y''s, on x''s line, naming x): its sums owed again, y returned, every invariant clean (never left unbookable); a further credit returning x is refused');
select results_eq($$ select v ->> 'x', v -> 'facts', v ->> 'job', v ->> 'review', v -> 'ret_req', v ->> 'ret',
                            (v ->> 'queue')::bigint, v -> 'adv', v ->> 'y', v -> 'dirty' from j where k = 'rr2' $$,
  $$ values ('ok'::text, '[[true, false]]'::jsonb, null::text, 'unplanned_payout_return'::text,
             '[["unplanned_payout_returned", "164000"]]'::jsonb, 'ok'::text, 0::bigint, '[]'::jsonb, 'booked'::text,
             '[]'::jsonb) $$,
  'ld2-reissue-return-pays-twice (the job): x booked first, then y''s return — its facts unplanned_open, the job''s planned row refused and reviewed unplanned_payout_return (never re-queued by the import); booked by ops as x''s copy''s return, the queue 0');
select results_eq($$ select v ->> 'cancel_y', v ->> 'lp', v ->> 'y', v -> 'adv_y', v -> 'ret_parts', v ->> 'ret',
                            (v ->> 'queue')::bigint, v -> 'adv', v ->> 'run' from j where k = 'rr6' $$,
  $$ values ('requested/cancelled'::text, 'ok'::text, 'ok'::text, '[164000]'::jsonb,
             '[["unplanned_payout_returned", true, true]]'::jsonb, 'ok'::text, 0::bigint, '[]'::jsonb,
             'booked'::text) $$,
  'ld2-reissue-return-pays-twice (the mirror): the late predecessor x booked as the run''s payout, y « Virement hors reversement » — x''s return closes y''s copy (its advance reversed, the queue 0, the run still booked)');
select results_eq($$ select v -> 'y_parts', v ->> 'y_ret', (v ->> 'y_queue')::bigint, v -> 'dirty' from j where k = 'rr6' $$,
  $$ values ('[["payout_returned", true, true]]'::jsonb, 'ok'::text, 164000::bigint, '[]'::jsonb) $$,
  'ld2-reissue-return-pays-twice (the mirror): y comes back too — the return of the run''s payout (x''s, on y''s line, naming y), its sums owed again, every invariant clean');

-- rr3 (three copies): ri8's state, x booked « Virement hors reversement », y's return closes x's copy; then the bank
-- executes y once more (« Virement hors reversement » of y, its advance) and x comes back — x's return closes that open
-- copy (y's second execution), never the run's payout while a copy stays with the client: the queue 0, no advance
create or replace function pg_temp.sc_rr3() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid; v_l uuid;
begin
  perform pg_temp.ld2_prefix('rr3', 3, 6);
  v := v || jsonb_build_object('x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  v_r := pg_temp.ret_line('c5', pg_temp.v('y'), 8);
  v := v || jsonb_build_object('ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', pg_temp.d(9), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')))), null, pg_temp.after(9));
  v_l := pg_temp.ln('c6');
  v := v || jsonb_build_object('y2', pg_temp.req(v_l), 'y2_book', pg_temp.bkx(v_l, pg_temp.prop(v_l)),
                               'adv_y2', pg_temp.adv_open());
  v_r := pg_temp.ret_line('c7', pg_temp.v('m0'), 10);
  v := v || jsonb_build_object('x_parts', pg_temp.ret_parts(v_r, pg_temp.v('m0'), pg_temp.v('y')),
                               'x_ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c8', private.paris_today(), '[]');
  return v || jsonb_build_object('queue', pg_temp.queue_of('a1'), 'adv', pg_temp.adv_open(),
                                 'y', pg_temp.status(pg_temp.v('y')), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'rr3', pg_temp.isolated('sc_rr3');
select results_eq($$ select v ->> 'x', v ->> 'ret', v -> 'y2', v ->> 'y2_book', v -> 'adv_y2', v -> 'x_parts', v ->> 'x_ret',
                            (v ->> 'queue')::bigint, v -> 'adv', v ->> 'y', v -> 'dirty' from j where k = 'rr3' $$,
  $$ values ('ok'::text, 'ok'::text, '[["unplanned_payout", "164000"]]'::jsonb, 'ok'::text, '[164000]'::jsonb,
             '[["unplanned_payout_returned", true, true]]'::jsonb, 'ok'::text, 0::bigint, '[]'::jsonb, 'booked'::text,
             '[]'::jsonb) $$,
  'ld2-reissue-return-pays-twice (three copies): y''s return closed x''s copy, y executed once more, then x comes back — x''s return closes y''s open copy (naming y), never the run''s payout while a copy stays with the client: the queue 0, no advance');

-- rr7 (own copy first, critic F1): ri8's state, x booked « Virement hors reversement », y executed once more (its own
-- « Virement hors reversement »); y's return closes y's own open copy, not x's (the copy that comes back is the
-- transfer's own unplanned one first)
create or replace function pg_temp.sc_rr7() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid; v_l uuid;
begin
  perform pg_temp.ld2_prefix('rr7', 3, 6);
  v := v || jsonb_build_object('x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  perform pg_temp.lines('c5', pg_temp.d(7), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')))), null, pg_temp.after(7));
  v_l := pg_temp.ln('c5');
  v := v || jsonb_build_object('y2', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  v_r := pg_temp.ret_line('c6', pg_temp.v('y'), 8);
  return v || jsonb_build_object('ret_parts', pg_temp.ret_parts(v_r, pg_temp.v('y'), pg_temp.v('m0')),
    'returns_y2', (pg_temp.prop(v_r) #>> '{0,returns_line_id}')::uuid = v_l);
end $$;
-- rr8: y booked by the import, y returned (the import books the run's payout returned), then x executed after L
-- (« Virement hors reversement », netting the returned sums, P = A): the nightly check leaves the run's rows to the queue
-- (its payout came back: its sums' rows are the queue's, « bloqué : virement revenu impayé »), none on the run; a
-- further credit returning y (the bank's duplicate) is refused already_returned — never the return of x's copy
create or replace function pg_temp.sc_rr8() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_ly uuid; v_r uuid; v_lx uuid;
begin
  perform pg_temp.lp_prefix('rr8');
  perform pg_temp.handed_out('f2', 'rr8-g2', 2);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0) where id in (pg_temp.v('m0'), pg_temp.v('y'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(4), deadline = pg_temp.d(6)
  where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  perform pg_temp.lines('c3', pg_temp.d(3), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')))), pg_temp.d(2), pg_temp.after(3));
  v_ly := pg_temp.ln('c3');
  v := v || jsonb_build_object('job', pg_temp.book(jsonb_build_array(jsonb_build_object('line', v_ly, 'kind', 'payout',
                                                                    'transfer', pg_temp.v('y')))) -> 'payouts');
  v_r := pg_temp.ret_line('c5', pg_temp.v('y'), 5);
  v := v || jsonb_build_object('ret_job', pg_temp.book(jsonb_build_array(jsonb_build_object('line', v_r,
                                 'kind', 'payout_returned', 'transfer', pg_temp.v('y')))) -> 'returns');
  perform pg_temp.lines('c6', pg_temp.d(6), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')))), null, pg_temp.after(6));
  v_lx := pg_temp.ln('c6');
  v := v || jsonb_build_object('x_parts', pg_temp.parts(v_lx), 'x', pg_temp.bkx(v_lx, pg_temp.prop(v_lx)));
  perform pg_temp.lines('c7', private.paris_today(), '[]');
  insert into t select 'rr8c', pg_temp.chk(private.paris_today());
  v := v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'queue', pg_temp.queue_of('a1'),
                               'dirty', to_jsonb(pg_temp.dirty()));
  v_r := pg_temp.ret_line('c8', pg_temp.v('y'), 8);
  return v || jsonb_build_object('again', pg_temp.op(v_r) ->> 'refusal',
                                 'again_proposals', jsonb_array_length(pg_temp.op(v_r) -> 'proposals'));
end $$;
-- rr5n: rr5 with x's execution on a line carrying none of our references (to Martin's IBAN), booked « Virement hors
-- reversement » of x (rule 3b's only candidate); y's return closes x's copy — the client was paid by x, late: the row
create or replace function pg_temp.sc_rr5n() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid;
begin
  perform pg_temp.ld2_prefix('rr5n', 6, 3, false);
  v := v || jsonb_build_object('x_req', pg_temp.req(pg_temp.v('lx')),
                               'x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  v_r := pg_temp.ret_line('c5', pg_temp.v('y'), 8);
  v := v || jsonb_build_object('ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select 'rr5nc', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'queue', pg_temp.queue_of('a1'),
                                 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'rr7', pg_temp.isolated('sc_rr7');
insert into j select 'rr8', pg_temp.isolated('sc_rr8');
insert into j select 'rr5n', pg_temp.isolated('sc_rr5n');
select results_eq($$ select v ->> 'x', v ->> 'y2', v -> 'ret_parts', (v ->> 'returns_y2')::boolean from j where k = 'rr7' $$,
  $$ values ('ok'::text, 'ok'::text, '[["unplanned_payout_returned", true, null]]'::jsonb, true) $$,
  'ld2-reissue-return-pays-twice (own copy first): y executed once more besides x''s copy — y''s return closes y''s own « Virement hors reversement » (critic F1), naming no other transfer');
select results_eq($$ select (v ->> 'job')::int, (v ->> 'ret_job')::int, v -> 'x_parts', v ->> 'x', v -> 'rows',
                            (v ->> 'queue')::bigint, v -> 'dirty', v ->> 'again', (v ->> 'again_proposals')::int
                     from j where k = 'rr8' $$,
  $$ values (1, 1, '[["unplanned_payout", true, "164000", "0", "amount", null]]'::jsonb, 'ok'::text, '[]'::jsonb, 0::bigint,
             '[]'::jsonb, 'already_returned'::text, 0) $$,
  'ld2-reissue-return-pays-twice (the run''s payout back first): x netted against the returned sums (P = A); the nightly check writes no row on the run (its sums'' rows are the queue''s); a further credit returning y is refused already_returned, never x''s copy''s return');
select results_eq($$ select v -> 'x_req', v ->> 'x', v ->> 'ret', v -> 'rows', (v ->> 'queue')::bigint, v -> 'dirty'
                     from j where k = 'rr5n' $$,
  $$ values ('[["unplanned_payout", "164000"]]'::jsonb, 'ok'::text, 'ok'::text, '["none"]'::jsonb, 0::bigint, '[]'::jsonb) $$,
  'ld2-named-debit-returned-after-booking (a line without our references): x''s late execution to Martin''s IBAN booked « Virement hors reversement » of x; y''s return closes it — the client was paid by x, late: the row');

-- ld2-named-debit-returned-after-booking (CPCE-08): ri8's state (x's own-id debit on time held the run's rows back when
-- the import booked y after L), then x comes back on a later statement (the servicer recalls it) — x paid nothing: the
-- nightly check writes the run's row at y's debit; x then booked « Virement hors reversement » and its return: the row
-- stays, nothing else written. rr5: y's debit on time, x's after L (x booked « Virement hors reversement »), then y comes
-- back closing x's copy — the client was paid by x, late: the nightly check writes the row
create or replace function pg_temp.sc_rr4() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid;
begin
  perform pg_temp.ld2_prefix('rr4', 3, 6);
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'));
  insert into t select 'rr4a', pg_temp.chk(private.paris_today());
  v := v || jsonb_build_object('nightly', pg_temp.breaches('r1'));
  v_r := pg_temp.ret_line('c5', pg_temp.v('m0'), 8);
  insert into t select 'rr4b', pg_temp.chk(private.paris_today());
  v := v || jsonb_build_object('returned', pg_temp.breaches('r1'),
    'x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))), 'ret_req', pg_temp.req(v_r),
    'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select 'rr4c', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'queue', pg_temp.queue_of('a1'),
    'adv', pg_temp.adv_open(),
    'run', (select jsonb_build_array(r.status, r.booked_on = pg_temp.d(6)) from public.remittance_run r
            where r.id = pg_temp.v('r1')),
    'dirty', to_jsonb(pg_temp.dirty()));
end $$;
create or replace function pg_temp.sc_rr5() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid;
begin
  perform pg_temp.ld2_prefix('rr5', 6, 3);
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'),
    'x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  insert into t select 'rr5a', pg_temp.chk(private.paris_today());
  v := v || jsonb_build_object('nightly', pg_temp.breaches('r1'));
  v_r := pg_temp.ret_line('c5', pg_temp.v('y'), 8);
  v := v || jsonb_build_object('ret_req', pg_temp.req(v_r), 'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select 'rr5b', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'queue', pg_temp.queue_of('a1'),
                                 'adv', pg_temp.adv_open(), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'rr4', pg_temp.isolated('sc_rr4');
insert into j select 'rr5', pg_temp.isolated('sc_rr5');
select results_eq($$ select v -> 'booked', v -> 'nightly', v -> 'returned', v ->> 'x', v -> 'ret_req', v ->> 'ret',
                            v -> 'rows', (v ->> 'queue')::bigint, v -> 'adv', v -> 'run', v -> 'dirty'
                     from j where k = 'rr4' $$,
  $$ values ('[]'::jsonb, '[]'::jsonb, '["none"]'::jsonb, 'ok'::text, '[["unplanned_payout_returned", "164000"]]'::jsonb,
             'ok'::text, '["none"]'::jsonb, 0::bigint, '[]'::jsonb, '["booked", true]'::jsonb, '[]'::jsonb) $$,
  'ld2-named-debit-returned-after-booking (CPCE-08): x''s on-time debit held the run''s rows back at y''s booking; x''s return on a later statement — the nightly check writes the row at y''s debit (after L); x and its return booked after: the row stays, the run booked at y''s date');
select results_eq($$ select v -> 'booked', v ->> 'x', v -> 'nightly', v -> 'ret_req', v ->> 'ret', v -> 'rows',
                            (v ->> 'queue')::bigint, v -> 'adv', v -> 'dirty' from j where k = 'rr5' $$,
  $$ values ('[]'::jsonb, 'ok'::text, '[]'::jsonb, '[["unplanned_payout_returned", "164000"]]'::jsonb, 'ok'::text,
             '["none"]'::jsonb, 0::bigint, '[]'::jsonb, '[]'::jsonb) $$,
  'ld2-named-debit-returned-after-booking (CPCE-08, the other way): y on time booked as the run''s payout, x after L « Virement hors reversement »; y''s return closes x''s copy — the client was paid by x, late: the nightly check writes the row');

-- Review round 3 (ADR-0014 « M2c-6b-3a-2 review fixes », round 3; CPCE-08) -------------------------------------------
-- paid-on-misses-lot-lines-and-return-shapes: the date a booked run's client stayed paid
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
-- ignored BtchBookg false, OQ-83) on day p_y, x under its own id on day p_x, L d(4); the import books the batch line as
-- the payouts of yl and y (Lilas' run and Martin's), x's line reviewed cancelled_transfer_debited (as the job does)
create or replace function pg_temp.lot_prefix(p_key text, p_x integer, p_y integer) returns void language plpgsql as $$
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
  perform pg_temp.lines('c3', pg_temp.d(7), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', pg_temp.d(p_x)),
    jsonb_build_object('amount', 583840, 'pmt_inf', pg_temp.pmt_of(pg_temp.v('y')), 'day', pg_temp.d(p_y))),
    pg_temp.d(2), pg_temp.after(7));
  insert into t values ('lx', pg_temp.ln('c3', 1)), ('ly', pg_temp.ln('c3', 2));
  perform pg_temp.book(jsonb_build_array(
      jsonb_build_object('line', pg_temp.v('ly'), 'kind', 'payout', 'transfer', pg_temp.v('yl')),
      jsonb_build_object('line', pg_temp.v('ly'), 'kind', 'payout', 'transfer', pg_temp.v('y'))),
    jsonb_build_array(jsonb_build_object('line', pg_temp.v('lx'), 'reason', 'cancelled_transfer_debited')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- ldl1: x's own-id debit on time (d3), the batch line after L (d6) booked as the payouts of yl and y (the booking held
-- the rows back at x's named date); x booked as proposed (« Virement hors reversement »), then x comes back on its own
-- line and is booked as proposed — the client was paid by y alone, in the batch line, after L: the nightly check writes
-- the row at the batch line's date. ldl2 (the control): y comes back instead, closing x's copy — the client kept x, paid
-- on time: no row
create or replace function pg_temp.ldl(p_key text, p_ret text) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid;
begin
  perform pg_temp.lot_prefix(p_key, 3, 6);
  v := v || jsonb_build_object('class', private.transfer_line_class(pg_temp.v('ly')),
    'bookings', (select jsonb_agg(jsonb_build_array(k.kind, k.amount_minor) order by k.seq)
                 from public.bank_line_booking k where k.bank_transaction_id = pg_temp.v('ly')),
    'booked', pg_temp.breaches('r1'), 'x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  insert into t select p_key || 'a', pg_temp.chk(private.paris_today());
  v := v || jsonb_build_object('nightly', pg_temp.breaches('r1'));
  v_r := pg_temp.ret_line('c5', pg_temp.v(p_ret), 8);
  v := v || jsonb_build_object('ret_req', pg_temp.req(v_r), 'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select p_key || 'b', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'),
    'paid_on', (select case private.remittance_run_paid_on(pg_temp.v('r1'))
                       when pg_temp.d(3) then 'd3' when pg_temp.d(6) then 'd6' else 'other' end),
    'queue', pg_temp.queue_of('a1'), 'adv', pg_temp.adv_open(), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
create or replace function pg_temp.sc_ldl1() returns jsonb language sql as $$ select pg_temp.ldl('ldl1', 'm0') $$;
create or replace function pg_temp.sc_ldl2() returns jsonb language sql as $$ select pg_temp.ldl('ldl2', 'y') $$;
-- rs5: the batch line on time (d3), x's own-id debit after L (d6) booked as proposed (« Virement hors reversement »);
-- then the bank returns y and yl as one entry kept unsplit carrying F2's PmtInfId (the parser keeps no original id: two
-- credit details of ours), booked as proposed — y's return closing x's copy, yl's Lilas' run's payout returned — the
-- client was paid by x alone, after L: the nightly check writes the row on Martin's run (none on Lilas', whose sums are
-- owed again: the queue's)
create or replace function pg_temp.sc_rs5() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid;
begin
  perform pg_temp.lot_prefix('rs5', 6, 3);
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'),
    'x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  insert into t select 'rs5a', pg_temp.chk(private.paris_today());
  v := v || jsonb_build_object('nightly', pg_temp.breaches('r1'));
  v_r := pg_temp.uret('c5', 8, 583840, jsonb_build_array(pg_temp.cdet(pg_temp.v('y')), pg_temp.cdet(pg_temp.v('yl'))),
                      pg_temp.pmt_of(pg_temp.v('y')));
  v := v || jsonb_build_object('class', private.transfer_line_class(v_r), 'ret_req', pg_temp.req(v_r),
    'ret_parts', pg_temp.ret_parts(v_r, pg_temp.v('y'), pg_temp.v('m0')), 'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select 'rs5b', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'rows_lilas', pg_temp.breaches('r2'),
    'queue', pg_temp.queue_of('a1'), 'queue_lilas', pg_temp.queue_of('a2'), 'adv', pg_temp.adv_open(),
    'yl', pg_temp.status(pg_temp.v('yl')), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
-- rs6 (ld2_prefix's: y's own-id debit on time d3 booked by the import, x's after L d6 booked as proposed), y's return
-- arrives as a lot credit of F2's PmtInf (no end-to-end id), booked as proposed (closing x's copy): the client was paid
-- by x alone, after L — the row. rs2 (forged: the parser gives a single detail's id to its line): x on time, y after
-- L, x's return as the only detail of an entry kept unsplit with no id of its own — the row at y's debit
create or replace function pg_temp.rs(p_key text, p_x integer, p_y integer, p_shape text) returns jsonb
language plpgsql as $$
declare v jsonb := '{}'; v_r uuid;
begin
  perform pg_temp.ld2_prefix(p_key, p_x, p_y);
  v := v || jsonb_build_object('x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  if p_shape = 'lot' then
    perform pg_temp.lines('c5', pg_temp.d(8), jsonb_build_array(
      jsonb_build_object('dir', 'credit', 'amount', 164000, 'pmt_inf', pg_temp.pmt_of(pg_temp.v('y')))), null,
      pg_temp.after(8));
    v_r := pg_temp.ln('c5');
  else
    v_r := pg_temp.uret('c5', 8, 164000, jsonb_build_array(pg_temp.cdet(pg_temp.v('m0'))));
  end if;
  v := v || jsonb_build_object('class', private.transfer_line_class(v_r), 'ret_req', pg_temp.req(v_r),
    'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select p_key || 'c', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'queue', pg_temp.queue_of('a1'),
    'adv', pg_temp.adv_open(), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
create or replace function pg_temp.sc_rs6() returns jsonb language sql as $$ select pg_temp.rs('rs6', 6, 3, 'lot') $$;
create or replace function pg_temp.sc_rs2() returns jsonb language sql as $$ select pg_temp.rs('rs2', 3, 6, 'unsplit') $$;
-- rs7 (the documented default, COMPLIANCE CPCE-08): ld2_prefix's with x on time; a return carrying none of our
-- references (to Martin's IBAN: rule 3b) booked as proposed, closing x's copy — not a return known for the paid date
-- (it may be either copy's): x's on-time debit still counts, no row
create or replace function pg_temp.sc_rs7() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid;
begin
  perform pg_temp.ld2_prefix('rs7', 3, 6);
  v := v || jsonb_build_object('x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  perform pg_temp.lines('c5', pg_temp.d(8), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'iban', pg_temp.martin_iban())), null, pg_temp.after(8));
  v_r := pg_temp.ln('c5');
  v := v || jsonb_build_object('class', private.transfer_line_class(v_r), 'ret_req', pg_temp.req(v_r),
    'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select 'rs7c', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'),
    'paid_on', private.remittance_run_paid_on(pg_temp.v('r1')) = pg_temp.d(3), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
-- rs8 (a debit detail is no return): x executed on time as the only detail of ours of a debit entry the bank kept
-- unsplit (its charge taken), y's own-id debit after L booked by the import (the rows held back at x's named date);
-- the nightly check writes no row — x's detail is its execution, never its return
create or replace function pg_temp.sc_rs8() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_lx uuid; v_ly uuid;
begin
  perform pg_temp.lp_prefix('rs8');
  perform pg_temp.handed_out('f2', 'rs8-g2', 2);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0) where id in (pg_temp.v('m0'), pg_temp.v('y'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(4), deadline = pg_temp.d(6)
  where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  v_lx := pg_temp.uline('c4', pg_temp.d(3), 164050, jsonb_build_array(pg_temp.det(pg_temp.v('m0'))), null, 50, null,
                        null, null, pg_temp.after(3));
  perform pg_temp.lines('c3', pg_temp.d(7), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')), 'day', pg_temp.d(6))), pg_temp.d(4),
    pg_temp.after(7));
  v_ly := pg_temp.ln('c3');
  v := v || jsonb_build_object('class', private.transfer_line_class(v_lx),
    'job', pg_temp.book(jsonb_build_array(jsonb_build_object('line', v_ly, 'kind', 'payout',
                                                             'transfer', pg_temp.v('y'))),
                        jsonb_build_array(jsonb_build_object('line', v_lx, 'reason', 'cancelled_transfer_debited')))
           -> 'payouts',
    'booked', pg_temp.breaches('r1'), 'run', pg_temp.run_status('r1'));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select 'rs8c', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'),
    'paid_on', private.remittance_run_paid_on(pg_temp.v('r1')) = pg_temp.d(3), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
insert into j select 'ldl1', pg_temp.isolated('sc_ldl1');
insert into j select 'ldl2', pg_temp.isolated('sc_ldl2');
insert into j select 'rs8', pg_temp.isolated('sc_rs8');
insert into j select 'rs5', pg_temp.isolated('sc_rs5');
insert into j select 'rs6', pg_temp.isolated('sc_rs6');
insert into j select 'rs2', pg_temp.isolated('sc_rs2');
insert into j select 'rs7', pg_temp.isolated('sc_rs7');
select results_eq($$ select v ->> 'class', v -> 'bookings', v -> 'booked', v ->> 'x', v -> 'nightly', v -> 'ret_req',
                            v ->> 'ret', v -> 'rows', v ->> 'paid_on', (v ->> 'queue')::bigint, v -> 'adv', v -> 'dirty'
                     from j where k = 'ldl1' $$,
  $$ values ('B'::text, '[["payout", 419840], ["payout", 164000]]'::jsonb, '[]'::jsonb, 'ok'::text, '[]'::jsonb,
             '[["unplanned_payout_returned", "164000"]]'::jsonb, 'ok'::text, '["none"]'::jsonb, 'd6'::text, 0::bigint,
             '[]'::jsonb, '[]'::jsonb) $$,
  'paid-on (ldl1, a batch line of several members): the re-issue y debited after L in one batch line with Lilas'' yl (booked as both payouts), x''s on-time copy booked then returned — the client was paid by y alone: the nightly check writes the row at the batch line''s date');
select results_eq($$ select v -> 'rows', v ->> 'paid_on', (v ->> 'queue')::bigint, v -> 'adv', v -> 'dirty'
                     from j where k = 'ldl2' $$,
  $$ values ('[]'::jsonb, 'd3'::text, 0::bigint, '[]'::jsonb, '[]'::jsonb) $$,
  'paid-on (ldl2, the control): the same batch line, y''s own return closing x''s copy — the client kept x, paid on time: no row, the paid date x''s debit');
select results_eq($$ select v -> 'booked', v ->> 'x', v -> 'nightly', v ->> 'class', v -> 'ret_req', v -> 'ret_parts',
                            v ->> 'ret', v -> 'rows', v -> 'rows_lilas', (v ->> 'queue')::bigint,
                            (v ->> 'queue_lilas')::bigint, v -> 'adv', v ->> 'yl', v -> 'dirty'
                     from j where k = 'rs5' $$,
  $$ values ('[]'::jsonb, 'ok'::text, '[]'::jsonb, 'U'::text,
             '[["unplanned_payout_returned", "164000"], ["payout_returned", "419840"]]'::jsonb,
             '[["unplanned_payout_returned", true, true], ["payout_returned", false, null]]'::jsonb, 'ok'::text,
             '["none"]'::jsonb, '[]'::jsonb, 0::bigint, 419840::bigint, '[]'::jsonb, 'returned'::text, '[]'::jsonb) $$,
  'paid-on (rs5, a return kept unsplit): y and yl back in one entry kept unsplit (F2''s PmtInfId, no original id), booked as proposed — y''s return closes x''s late copy: the row on Martin''s run; Lilas'' sums owed again (no row on her run)');
select results_eq($$ select v ->> 'x', v ->> 'class', v -> 'ret_req', v ->> 'ret', v -> 'rows', (v ->> 'queue')::bigint,
                            v -> 'adv', v -> 'dirty' from j where k = 'rs6' $$,
  $$ values ('ok'::text, 'B'::text, '[["unplanned_payout_returned", "164000"]]'::jsonb, 'ok'::text, '["none"]'::jsonb,
             0::bigint, '[]'::jsonb, '[]'::jsonb) $$,
  'paid-on (rs6, a lot credit): y''s return as a lot credit of F2''s PmtInf, booked as proposed (closing x''s late copy) — the client was paid by x alone, after L: the row');
select results_eq($$ select v ->> 'x', v ->> 'class', v -> 'ret_req', v ->> 'ret', v -> 'rows', (v ->> 'queue')::bigint,
                            v -> 'adv', v -> 'dirty' from j where k = 'rs2' $$,
  $$ values ('ok'::text, 'U'::text, '[["unplanned_payout_returned", "164000"]]'::jsonb, 'ok'::text, '["none"]'::jsonb,
             0::bigint, '[]'::jsonb, '[]'::jsonb) $$,
  'paid-on (rs2, forged: a detail of an entry kept unsplit with no id of its own): x''s on-time copy back — the client was paid by y alone, after L: the row');
select results_eq($$ select v ->> 'x', v ->> 'class', v -> 'ret_req', v ->> 'ret', v -> 'rows', (v ->> 'paid_on')::boolean,
                            v -> 'dirty' from j where k = 'rs7' $$,
  $$ values ('ok'::text, 'N'::text, '[["unplanned_payout_returned", "164000"]]'::jsonb, 'ok'::text, '[]'::jsonb, true,
             '[]'::jsonb) $$,
  'paid-on (rs7, the documented default, COMPLIANCE CPCE-08): a return without our references closing x''s copy is not a return known for the paid date (either copy''s) — x''s on-time debit still counts, no row');
select results_eq($$ select v ->> 'class', (v ->> 'job')::int, v -> 'booked', v ->> 'run', v -> 'rows',
                            (v ->> 'paid_on')::boolean, v -> 'dirty' from j where k = 'rs8' $$,
  $$ values ('U'::text, 1, '[]'::jsonb, 'booked'::text, '[]'::jsonb, true, '[]'::jsonb) $$,
  'paid-on (rs8, a debit detail is no return): x executed on time as a detail of a debit entry kept unsplit, y''s debit after L booked by the import — the nightly check writes no row, the paid date x''s');

-- Review round 4 (ADR-0014 « M2c-6b-3a-2 review fixes », round 4; CPCE-08) -------------------------------------------
-- One rule for the date a run's client stayed paid (private.remittance_chain_paid): every execution and every return of
-- the run's payout chain, each counted for the transfer whose references it carries; a transfer stays paid from the
-- first date from which its executions outnumber its returns for the rest of the period, the run from the earliest
-- such date of its chain (none: no transfer of it stayed paid). The booking, the sheet's late flag, the chained branch
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
grant execute on all functions in schema pg_temp to authenticated;

-- new:return-known-misses-unflagged-own-id-return: a return the bank does not flag as one (no return reason, sub-family
-- or reversal), from the client's payout IBAN, carrying our RMT id as its own end-to-end id (client_transfer_in, class
-- E, booked as proposed) is that transfer's return. n1a: x on time (d3), y after L (d6) booked by the import as the
-- run's payout; x comes back unflagged and is booked as proposed — the client was paid by y alone, late: the row at y's
-- debit. n1b: the other way (x after L, y on time), y's unflagged return closing x's copy — paid by x alone, late
create or replace function pg_temp.n1(p_key text, p_x integer, p_y integer, p_ret text) returns jsonb
language plpgsql as $$
declare v jsonb := '{}'; v_r uuid;
begin
  perform pg_temp.ld2_prefix(p_key, p_x, p_y);
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'),
                               'x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  v_r := pg_temp.ctin('c5', pg_temp.v(p_ret), 8);
  v := v || jsonb_build_object('kind', (select kind from public.bank_transaction where id = v_r),
    'class', private.transfer_line_class(v_r), 'ret_req', pg_temp.req(v_r), 'refusal', pg_temp.op(v_r) ->> 'refusal',
    'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select p_key || 'c', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'queue', pg_temp.queue_of('a1'),
    'adv', pg_temp.adv_open(), 'paid_on', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))),
    'dirty', to_jsonb(pg_temp.dirty()));
end $$;
create or replace function pg_temp.sc_n1a() returns jsonb language sql as $$ select pg_temp.n1('n1a', 3, 6, 'm0') $$;
create or replace function pg_temp.sc_n1b() returns jsonb language sql as $$ select pg_temp.n1('n1b', 6, 3, 'y') $$;
-- n1c: one statement (d2 … d7) holding x's debit on time (d3), x's unflagged return (d5) and y's debit after L (d6): the
-- import books y as the run's payout — its booking writes the row at y's debit (x paid nothing); x and its return then
-- booked as proposed. n1d (the control): the same return flagged (kind return)
create or replace function pg_temp.n1c(p_key text, p_kind text) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_lx uuid; v_lr uuid; v_ly uuid;
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
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', pg_temp.d(3)),
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')),
                       'iban', pg_temp.martin_iban(), 'day', pg_temp.d(5),
                       'kind', coalesce(p_kind, private.bank_line_refined_kind('debtor_credit', 'credit',
                                 pg_temp.e2e(pg_temp.v('m0')), null, null, pg_temp.martin_iban(),
                                 array[pg_temp.own_iban()], array[pg_temp.martin_iban(), pg_temp.lilas_iban()]))),
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')), 'day', pg_temp.d(6))), pg_temp.d(2),
    pg_temp.after(7));
  v_lx := pg_temp.ln('c3', 1); v_lr := pg_temp.ln('c3', 2); v_ly := pg_temp.ln('c3', 3);
  v := v || jsonb_build_object('kind', (select kind from public.bank_transaction where id = v_lr),
    'job', pg_temp.book(jsonb_build_array(jsonb_build_object('line', v_ly, 'kind', 'payout', 'transfer', pg_temp.v('y'))),
                        jsonb_build_array(jsonb_build_object('line', v_lx, 'reason', 'cancelled_transfer_debited')))
           -> 'payouts');
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'), 'x', pg_temp.bkx(v_lx, pg_temp.prop(v_lx)),
                               'ret_req', pg_temp.req(v_lr));
  v := v || jsonb_build_object('ret', pg_temp.bkx(v_lr, pg_temp.prop(v_lr)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select p_key || 'c', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'queue', pg_temp.queue_of('a1'),
    'paid_on', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
create or replace function pg_temp.sc_n1c() returns jsonb language sql as $$ select pg_temp.n1c('n1c', null) $$;
create or replace function pg_temp.sc_n1d() returns jsonb language sql as $$ select pg_temp.n1c('n1d', 'return') $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'n1a', pg_temp.isolated('sc_n1a');
insert into j select 'n1b', pg_temp.isolated('sc_n1b');
insert into j select 'n1c', pg_temp.isolated('sc_n1c');
insert into j select 'n1d', pg_temp.isolated('sc_n1d');
select results_eq($$ select k, v ->> 'kind', v ->> 'class', v -> 'ret_req', v ->> 'refusal', v ->> 'x', v ->> 'ret',
                            v -> 'booked', v -> 'rows', v ->> 'paid_on', (v ->> 'queue')::bigint, v -> 'adv', v -> 'dirty'
                     from j where k in ('n1a', 'n1b') order by k $$,
  $$ values ('n1a'::text, 'client_transfer_in'::text, 'E'::text, '[["unplanned_payout_returned", "164000"]]'::jsonb,
             null::text, 'ok'::text, 'ok'::text, '[]'::jsonb, '["none"]'::jsonb, 'd6'::text, 0::bigint, '[]'::jsonb,
             '[]'::jsonb),
            ('n1b', 'client_transfer_in', 'E', '[["unplanned_payout_returned", "164000"]]', null, 'ok', 'ok', '[]',
             '["none"]', 'd6', 0, '[]', '[]') $$,
  'return-known-misses-unflagged-own-id-return (n1a, n1b): a return the bank did not flag, from Martin''s IBAN with our RMT id as its own (client_transfer_in, class E), booked as proposed, is that transfer''s return — the client was paid by the copy that was late alone: the row at the late copy''s date');
select results_eq($$ select k, v ->> 'kind', (v ->> 'job')::int, v -> 'booked', v ->> 'x', v -> 'ret_req', v ->> 'ret',
                            v -> 'rows', v ->> 'paid_on', (v ->> 'queue')::bigint, v -> 'dirty'
                     from j where k in ('n1c', 'n1d') order by k $$,
  $$ values ('n1c'::text, 'client_transfer_in'::text, 1, '["none"]'::jsonb, 'ok'::text,
             '[["unplanned_payout_returned", "164000"]]'::jsonb, 'ok'::text, '["none"]'::jsonb, 'd6'::text, 0::bigint,
             '[]'::jsonb),
            ('n1d', 'return', 1, '["none"]', 'ok', '[["unplanned_payout_returned", "164000"]]', 'ok', '["none"]',
             'd6', 0, '[]') $$,
  'return-known-misses-unflagged-own-id-return (n1c; n1d the control, flagged): x, its unflagged return and y after L on one statement — the import''s booking of y writes the row at y''s debit (x paid nothing), as for a flagged return');

-- new:paid-on-ignores-debits-outnumbering-returns: a transfer stays paid while its executions outnumber its returns —
-- the job reviews a further execution (transfer_debited_twice) and « Comptabiliser… » books it « Virement hors
-- reversement ». n2b (one statement): x debited on time (d2), returned (d3), executed again (d4 = L); y after L (d6)
-- booked by the import as the run's payout — the client kept x's d4 execution, on time: no row. n2d: x executed twice on
-- time (d2, d3), the duplicate returned (d5), y after L — no row
create or replace function pg_temp.n2b(p_key text, p_ret integer, p_again integer) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_lx uuid; v_lr uuid; v_la uuid; v_ly uuid;
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
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', pg_temp.d(2)),
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')),
                       'day', pg_temp.d(p_ret)),
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', pg_temp.d(p_again)),
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')), 'day', pg_temp.d(6))), pg_temp.d(2),
    pg_temp.after(7));
  v_lx := pg_temp.ln('c3', 1); v_lr := pg_temp.ln('c3', 2); v_la := pg_temp.ln('c3', 3); v_ly := pg_temp.ln('c3', 4);
  v := v || jsonb_build_object('job', pg_temp.book(
    jsonb_build_array(jsonb_build_object('line', v_ly, 'kind', 'payout', 'transfer', pg_temp.v('y'))),
    jsonb_build_array(jsonb_build_object('line', v_lx, 'reason', 'cancelled_transfer_debited'),
                      jsonb_build_object('line', v_la, 'reason', 'transfer_debited_twice'),
                      jsonb_build_object('line', v_lr, 'reason', 'return_debit_pending'))) -> 'payouts');
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'), 'x1_req', pg_temp.req(v_lx));
  v := v || jsonb_build_object('x1', pg_temp.bkx(v_lx, pg_temp.prop(v_lx)), 'x2_req', pg_temp.req(v_la));
  v := v || jsonb_build_object('x2', pg_temp.bkx(v_la, pg_temp.prop(v_la)), 'ret_req', pg_temp.req(v_lr));
  v := v || jsonb_build_object('ret', pg_temp.bkx(v_lr, pg_temp.prop(v_lr)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select p_key || 'c', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'queue', pg_temp.queue_of('a1'),
    'paid_on', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
create or replace function pg_temp.sc_n2b() returns jsonb language sql as $$ select pg_temp.n2b('n2b', 3, 4) $$;
create or replace function pg_temp.sc_n2d() returns jsonb language sql as $$ select pg_temp.n2b('n2d', 5, 3) $$;
-- n2a (the nightly): x on time (d2) booked « Virement hors reversement », y after L (d6) the run's payout (its booking
-- held the rows back at x's debit); x's return (d3) and its second execution (d4 = L) come on later statements and are
-- booked as proposed — the client kept x's d4 execution: the nightly check writes no row. n2c (the control): without
-- the second execution, the row at y's debit
create or replace function pg_temp.n2a(p_key text, p_again boolean) returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid; v_a uuid;
begin
  perform pg_temp.ld2_prefix(p_key, 2, 6);
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'),
                               'x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  insert into t select p_key || 'a', pg_temp.chk(private.paris_today());
  v := v || jsonb_build_object('nightly0', pg_temp.breaches('r1'));
  v_r := pg_temp.ret_line('c5', pg_temp.v('m0'), 3);
  v := v || jsonb_build_object('ret_req', pg_temp.req(v_r), 'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  if p_again then
    v_a := pg_temp.x_late('c8', pg_temp.d(4));
    v := v || jsonb_build_object('again_req', pg_temp.req(v_a), 'again', pg_temp.bkx(v_a, pg_temp.prop(v_a)));
  end if;
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select p_key || 'c', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'queue', pg_temp.queue_of('a1'),
    'paid_on', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))), 'dirty', to_jsonb(pg_temp.dirty()));
end $$;
create or replace function pg_temp.sc_n2a() returns jsonb language sql as $$ select pg_temp.n2a('n2a', true) $$;
create or replace function pg_temp.sc_n2c() returns jsonb language sql as $$ select pg_temp.n2a('n2c', false) $$;
-- n2f (the missing row): statement 1 (d2 … d5) x on time (d2), y after L (d5) booked by the import (the rows held back
-- at x's debit), x booked as proposed; statement 2 (d6 … d8): y executed a second time (d6), one y returned (d7), x
-- returned (d8), each booked as proposed — the client kept one y, paid after L: the nightly check writes the row at y's
-- first debit
create or replace function pg_temp.sc_n2f() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_lx uuid; v_ly uuid; v_ly2 uuid; v_lyr uuid; v_lr uuid;
begin
  perform pg_temp.lp_prefix('n2f');
  perform pg_temp.handed_out('f2', 'n2f-g2', 2);
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = pg_temp.d(0) where id in (pg_temp.v('m0'), pg_temp.v('y'));
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  set constraints all immediate;
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = pg_temp.d(4), deadline = pg_temp.d(6)
  where run_id = pg_temp.v('r1');
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  perform pg_temp.lines('c3', pg_temp.d(5), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('m0')), 'day', pg_temp.d(2)),
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')), 'day', pg_temp.d(5))),
    pg_temp.d(2), pg_temp.after(5));
  v_lx := pg_temp.ln('c3', 1); v_ly := pg_temp.ln('c3', 2);
  v := v || jsonb_build_object('job', pg_temp.book(
    jsonb_build_array(jsonb_build_object('line', v_ly, 'kind', 'payout', 'transfer', pg_temp.v('y'))),
    jsonb_build_array(jsonb_build_object('line', v_lx, 'reason', 'cancelled_transfer_debited'))) -> 'payouts');
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'), 'x', pg_temp.bkx(v_lx, pg_temp.prop(v_lx)));
  insert into t select 'n2fa', pg_temp.chk(private.paris_today());
  v := v || jsonb_build_object('nightly0', pg_temp.breaches('r1'));
  perform pg_temp.lines('c4', pg_temp.d(8), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')), 'day', pg_temp.d(6)),
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('y')), 'day', pg_temp.d(7)),
    jsonb_build_object('dir', 'credit', 'amount', 164000, 'orig_e2e', pg_temp.e2e(pg_temp.v('m0')),
                       'day', pg_temp.d(8))), pg_temp.d(6), pg_temp.after(8));
  v_ly2 := pg_temp.ln('c4', 1); v_lyr := pg_temp.ln('c4', 2); v_lr := pg_temp.ln('c4', 3);
  v := v || jsonb_build_object('y2_req', pg_temp.req(v_ly2));
  v := v || jsonb_build_object('y2', pg_temp.bkx(v_ly2, pg_temp.prop(v_ly2)), 'yr_req', pg_temp.req(v_lyr));
  v := v || jsonb_build_object('yr', pg_temp.bkx(v_lyr, pg_temp.prop(v_lyr)), 'xr_req', pg_temp.req(v_lr));
  v := v || jsonb_build_object('xr', pg_temp.bkx(v_lr, pg_temp.prop(v_lr)));
  perform pg_temp.lines('c6', private.paris_today(), '[]');
  insert into t select 'n2fc', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'), 'queue', pg_temp.queue_of('a1'),
    'paid_on', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))), 'run', pg_temp.run_status('r1'),
    'dirty', to_jsonb(pg_temp.dirty()));
end $$;
-- fr1 (verify round 2): y on time (d3) the run's payout, x after L (d6) « Virement hors reversement », y executed again
-- (d7, its own « Virement hors reversement »), y's return (d8) closing y's own copy — the client kept y's d3 execution
-- (and x): no row
create or replace function pg_temp.sc_fr1() returns jsonb language plpgsql as $$
declare v jsonb := '{}'; v_r uuid; v_l uuid;
begin
  perform pg_temp.ld2_prefix('fr1', 6, 3);
  v := v || jsonb_build_object('booked', pg_temp.breaches('r1'),
                               'x', pg_temp.bkx(pg_temp.v('lx'), pg_temp.prop(pg_temp.v('lx'))));
  perform pg_temp.lines('c5', pg_temp.d(7), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('y')))), null, pg_temp.after(7));
  v_l := pg_temp.ln('c5');
  v := v || jsonb_build_object('y2_req', pg_temp.req(v_l), 'y2', pg_temp.bkx(v_l, pg_temp.prop(v_l)));
  insert into t select 'fr1a', pg_temp.chk(private.paris_today());
  v := v || jsonb_build_object('rows_before_ret', pg_temp.breaches('r1'));
  v_r := pg_temp.ret_line('c6', pg_temp.v('y'), 8);
  v := v || jsonb_build_object('ret_returns_y2', (pg_temp.prop(v_r) #>> '{0,returns_line_id}')::uuid = v_l,
                               'ret', pg_temp.bkx(v_r, pg_temp.prop(v_r)));
  perform pg_temp.lines('c7', private.paris_today(), '[]');
  insert into t select 'fr1b', pg_temp.chk(private.paris_today());
  return v || jsonb_build_object('rows', pg_temp.breaches('r1'),
    'paid_on', pg_temp.dk(private.remittance_run_paid_on(pg_temp.v('r1'))), 'queue', pg_temp.queue_of('a1'),
    'dirty', to_jsonb(pg_temp.dirty()));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'n2b', pg_temp.isolated('sc_n2b');
insert into j select 'n2d', pg_temp.isolated('sc_n2d');
insert into j select 'n2a', pg_temp.isolated('sc_n2a');
insert into j select 'n2c', pg_temp.isolated('sc_n2c');
insert into j select 'n2f', pg_temp.isolated('sc_n2f');
insert into j select 'fr1', pg_temp.isolated('sc_fr1');
select results_eq($$ select k, (v ->> 'job')::int, v -> 'booked', v -> 'x1_req', v ->> 'x1', v -> 'x2_req', v ->> 'x2',
                            v -> 'ret_req', v ->> 'ret', v -> 'rows', v ->> 'paid_on', (v ->> 'queue')::bigint,
                            v -> 'dirty'
                     from j where k in ('n2b', 'n2d') order by k $$,
  $$ values ('n2b'::text, 1, '[]'::jsonb, '[["unplanned_payout", "164000"]]'::jsonb, 'ok'::text,
             '[["unplanned_payout", "164000"]]'::jsonb, 'ok'::text, '[["unplanned_payout_returned", "164000"]]'::jsonb,
             'ok'::text, '[]'::jsonb, 'd4'::text, 0::bigint, '[]'::jsonb),
            ('n2d', 1, '[]', '[["unplanned_payout", "164000"]]', 'ok', '[["unplanned_payout", "164000"]]', 'ok',
             '[["unplanned_payout_returned", "164000"]]', 'ok', '[]', 'd2', 0, '[]') $$,
  'paid-on-ignores-debits-outnumbering-returns (n2b, n2d): x executed again after its return, or twice with one execution returned — its executions outnumber its returns from an on-time date: the import''s booking of y after L writes no row, nor the nightly check');
select results_eq($$ select k, v -> 'nightly0', v ->> 'ret', v ->> 'again', v -> 'rows', v ->> 'paid_on', v -> 'dirty'
                     from j where k in ('n2a', 'n2c') order by k $$,
  $$ values ('n2a'::text, '[]'::jsonb, 'ok'::text, 'ok'::text, '[]'::jsonb, 'd4'::text, '[]'::jsonb),
            ('n2c', '[]', 'ok', null, '["none"]', 'd6', '[]') $$,
  'paid-on-ignores-debits-outnumbering-returns (n2a; n2c the control): x''s return and its second execution on time booked after y''s booking — the nightly check writes no row; without the second execution, the row at y''s debit');
select results_eq($$ select (v ->> 'job')::int, v -> 'booked', v ->> 'x', v -> 'nightly0', v -> 'y2_req', v ->> 'y2',
                            v -> 'yr_req', v ->> 'yr', v -> 'xr_req', v ->> 'xr', v -> 'rows', v ->> 'paid_on',
                            (v ->> 'queue')::bigint, v ->> 'run', v -> 'dirty'
                     from j where k = 'n2f' $$,
  $$ values (1, '[]'::jsonb, 'ok'::text, '[]'::jsonb, '[["unplanned_payout", "164000"]]'::jsonb, 'ok'::text,
             '[["unplanned_payout_returned", "164000"]]'::jsonb, 'ok'::text,
             '[["unplanned_payout_returned", "164000"]]'::jsonb, 'ok'::text, '["none"]'::jsonb, 'd5'::text, 0::bigint,
             'booked'::text, '[]'::jsonb) $$,
  'paid-on-ignores-debits-outnumbering-returns (n2f): x on time then returned, y after L executed twice and one y returned — the client kept one y, paid after L: the nightly check writes the row at y''s first debit');
select results_eq($$ select v -> 'booked', v ->> 'x', v ->> 'y2', v -> 'rows_before_ret', (v ->> 'ret_returns_y2')::boolean,
                            v ->> 'ret', v -> 'rows', v ->> 'paid_on', (v ->> 'queue')::bigint, v -> 'dirty'
                     from j where k = 'fr1' $$,
  $$ values ('[]'::jsonb, 'ok'::text, 'ok'::text, '[]'::jsonb, true, 'ok'::text, '[]'::jsonb, 'd3'::text, 0::bigint,
             '[]'::jsonb) $$,
  'paid-on-ignores-debits-outnumbering-returns (fr1): y on time and executed again, one y returned (closing its own copy) — y''s executions outnumber its returns from d3: no row');

-- r4-guidance, the property (CPCE-08): the R124-6 row of a booked run whose chain is x (cancelled with its downloaded
-- file F1) and its re-issue y (in F2, downloaded), against the rule written here independently (pg_temp.pc_rule): per
-- transfer, its executions and returns in date order (an execution before a return on one date; a return with nothing
-- outstanding undoes nothing), the transfer paid from the first date from which its count stays at one or more; the run
-- paid from the earliest such date of x and y; a row when none (no copy stayed with the client) or after L (d4). A
-- return without our references (rule 3b: either copy's) is not counted (COMPLIANCE CPCE-08's default). One case: its
-- events [{m: x | y, k: e (execution) | r (return), s: its shape, d: its business day}] on one statement (an entry kept
-- unsplit on its own) produced after d9, the import booking y's first execution as the run's payout (a batch line of
-- F2's PmtInf as the payouts of y and Lilas' yl), ops booking every other line as « Comptabiliser… » proposes, in date
-- order, then the nightly check. Shapes: an execution under its own RMT id (own), as the only detail of ours of a debit
-- entry kept unsplit, the bank's charge taken (det), as F2's batch line with yl (lot), a CSV line held as a suspected
-- duplicate of one, not decided (dup: no execution, left to the duplicate decision); a return flagged under its id as
-- the original (own), unflagged from Martin's IBAN under its id as its own (ctin), as the only credit detail of an entry
-- kept unsplit (udet), as a lot credit of F2's PmtInf (lotc), y's and yl's in one entry kept unsplit naming F2's
-- PmtInfId (ulot), without any reference of ours (noref). Each case returns whether the run has an R124-6 row, the paid
-- date (private.remittance_run_paid_on), the lines « Comptabiliser… » proposed nothing for (left to the support), the
-- bookings refused, whether the run's payout still stands (its payout booking's entry not reversed) and the invariants
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
-- the shapes the verifiers found, as cases
create temp table pc_cases (k text primary key, ev jsonb) on commit drop;
insert into pc_cases values
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
  -- forged (defence): a return of x the statements show before any execution of x undoes nothing — x's later execution
  -- stays paid
  ('early', '[{"m":"x","k":"r","s":"own","d":3},{"m":"x","k":"e","s":"own","d":5},{"m":"y","k":"e","s":"own","d":6}]'),
  -- a CSV line held as a suspected duplicate of x's execution (not decided) is no second execution: x's return leaves
  -- nothing of x with the client
  ('dup', '[{"m":"x","k":"e","s":"own","d":3},{"m":"x","k":"e","s":"dup","d":3},{"m":"x","k":"r","s":"own","d":5},
            {"m":"y","k":"e","s":"own","d":6}]');
select setseed(0.4242);
insert into pc_cases select 'rnd' || lpad(g::text, 2, '0'), pg_temp.pc_gen() from generate_series(1, 24) g;
select is((select jsonb_agg(c.k || ':' || coalesce('d' || pg_temp.pc_rule(c.ev), 'null') order by c.k)
           from pc_cases c where c.k not like 'rnd%'),
  '["dup:d6", "early:d5", "fr1:d3", "ldl1:d6", "ldl2:d3", "lifo:d3", "n1a:d6", "n1b:d6", "n2b:d4", "n2d:d2", "n2f:d5", "rs2:d6", "rs5:d6", "rs6:d6", "rs7:d3", "rs8:d3"]'::jsonb,
  'the rule (pg_temp.pc_rule) on the shapes the verifiers found: the paid date each case expects (a row when it is after L, d4)');
select is((select coalesce(jsonb_agg(x order by c.k), '[]') from pc_cases c
           cross join lateral jsonb_array_elements(pg_temp.pc_check(c.k, c.ev)) x where c.k not like 'rnd%'),
  '[]'::jsonb,
  'r4 property (CPCE-08): the shapes the verifiers found (n2b, n2d, n2f, fr1, ldl1, ldl2, rs2, rs5, rs6, rs7, rs8, n1a, n1b, two executions of x and one return, a return before any execution, a suspected duplicate) — the R124-6 row and the paid date agree with the rule, every line booked as proposed, the invariants clean');
select is((select coalesce(jsonb_agg(x order by c.k), '[]') from pc_cases c
           cross join lateral jsonb_array_elements(pg_temp.pc_check(c.k, c.ev)) x where c.k like 'rnd%'),
  '[]'::jsonb,
  'r4 property (CPCE-08): 24 seeded interleavings of 2–4 executions and 0–3 returns of x and y — the R124-6 row and the paid date agree with the rule, every line booked as proposed, the invariants clean');

select is(private.switch_on('downloaded_file_cancellation'), false,
  'the switch is off as the migration leaves it (6b-3b switches it on)');

select * from finish();
rollback;
