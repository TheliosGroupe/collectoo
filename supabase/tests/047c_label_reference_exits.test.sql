-- M2c-7e-3 « our references in CSV labels: the three exits » (plan docs/design/m2c-7-plan.md §7.3's exits (a), (b) and
-- (c), §7.4's actions, §7.5's 047c with [check 2] gap 1 (1), (2), (4); founder Q15's added question, default a: the
-- fourth exit; ADR-0014 « M2c-7e-3 »). A CSV credit held `label_reference` because its label cites one of our
-- transfers (7e-2) leaves review only by one of its exits, each through the existing command and its rights:
--   a     the return of exactly that transfer (public.book_transfer_line, class L: a payout or a sweep its label cites,
--         at exactly its amount, no fee part — label_reference_amount, label_reference_transfer); a2 our sweep; a3 a
--         held duplicate released as label_reference;
--   v     the return counts: private.remittance_chain_events reads the booked line (paid_on, run paid, entry_remitted,
--         request_advance_repayment's payout_not_received), never the line in review;
--   b     a client's payment (public.book_client_payment_line with the client ops name: client_required,
--         client_unknown, client_mismatch);
--   c     a debtor's payment (public.release_own_credit: its release row, the payment and its cash_in; its payer);
--   d     the fourth exit: our own top-up's credit with no counterparty IBAN (public.book_top_up_credit naming the TOP
--         its label cites, at exactly its amount);
--   g     the guards still refuse (bank_line_booking_guard, bank_own_credit_release_guard, payment_insert_guard);
--   i     tenant isolation and the rights; p the privileges.
-- After each exit the review is gone, the debit job no longer fetches the line, label_reference_waiting no longer lists
-- it, and every other exit is refused. Each scenario runs in its own rolled-back subtransaction, again with the switch
-- on (pg_temp.iso(…, true)), equal to its switch-off twin (no rule of 7e-3 reads it); a guard at the end checks it is
-- off. 033 is unchanged.
begin;
select plan(22);

-- Fixtures and helpers (047b's, copied: 047a's, 046c's, 045's, 044's, 037's fixture, 035's, 043's, 045b's, 046a's,
-- 046b's, 046c's, 047a's and 047b's helpers) ---------------------------------------------------------------------------
-- Fixtures and helpers (047a's, copied: 046c's, 045's, 044's, 037's fixture, 035's, 043's, 045's, 045b's, 046a's, 046b's,
-- 046c's and 047a's helpers) ------------------------------------------------------------------------------------------
-- Fixtures and helpers (046c's, copied: 045's, 044's, 037's fixture, 035's, 043's, 045's, 045b's, 046a's, 046b's and 046c's helpers) ------
-- Fixtures and helpers (045's, copied: 044's, 037's fixture, 035's, 043's and 045's helpers) ----------------------------
-- Fixtures and helpers (044's, copied: 037's fixture, 035's, 043's and 044's helpers) -----------------------------------

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
select ('d0000000-0000-0000-0000-000000000' || x.n || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa'::uuid,
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
-- (review 6b-2c money-3) and the items of an account whose mandate's delay cannot be met (`unmeetable_acct`: the job
-- marks them unmeetable, held to one month after their collection)
create temporary table unmeetable_acct (account_id uuid primary key) on commit drop;
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
  update private.remittance_draft_line l set unmeetable = true
  from unmeetable_acct u where l.run_id = p_run and l.account_id = u.account_id;
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
    'unmeetable', (select count(*) from private.remittance_draft_line where run_id = p_run and unmeetable),
    'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
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



-- 037's own helpers ---------------------------------------------------------------------------------------------------
-- an imported camt.053 of an account (the dedicated one by default) for p_day with its lines [{dir, kind, amount, e2e,
-- orig, pmt, iban, unsplit, details, count, nb, charges, read}], opened with the ledger cash and closed with it moved:
-- line k of statement n is pg_temp.l2(n, k) (n up to 6 hex digits)
create or replace function pg_temp.l2(p_n text, p_k integer) returns uuid language sql as $$
  select ('e4' || lpad(p_n, 6, '0') || '-0000-0000-0001-' || lpad(p_k::text, 12, '0'))::uuid $$;
create or replace function pg_temp.stmt2(p_n text, p_day date, p_lines jsonb,
                                         p_account uuid default '80000000-0000-0000-0000-0000000000cf')
returns uuid language plpgsql as $$
declare
  s uuid := ('e4' || lpad(p_n, 6, '0') || '-0000-0000-0000-000000000000')::uuid;
  v_open bigint := case when p_account = '80000000-0000-0000-0000-0000000000cf'
                        then pg_temp.cash() + (select u.minor from private.bank_unposted(
                                                 '80000000-0000-0000-0000-0000000000cf', 'infinity'::date) u)
                        else 0 end;
  v_close bigint;
begin
  select v_open + coalesce(sum(case coalesce(l.v ->> 'dir', 'debit') when 'credit' then 1 else -1 end
                               * (l.v ->> 'amount')::bigint), 0)
  into v_close from jsonb_array_elements(p_lines) l (v);
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', p_account, 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       original_end_to_end_id, counterparty_iban, batch_entry_ref, unsplit_ours,
                                       unsplit_details, unsplit_detail_count, unsplit_batch_count, charges_minor,
                                       charges_read)
  select pg_temp.l2(p_n, l.ord::integer), '00000000-0000-0000-0000-0000000000aa', p_account, s, l.ord,
         't:' || s || l.ord, coalesce(l.v ->> 'dir', 'debit'), (l.v ->> 'amount')::bigint, 'EUR', p_day,
         coalesce(l.v ->> 'kind', 'transfer_out'), l.v ->> 'e2e', l.v ->> 'pmt', l.v ->> 'orig', l.v ->> 'iban',
         case when l.v ? 'unsplit' then 'E-' || s || '-' || l.ord end, (l.v ->> 'unsplit')::smallint, l.v -> 'details',
         (l.v ->> 'count')::integer, (l.v ->> 'nb')::integer, (l.v ->> 'charges')::bigint, (l.v ->> 'read')::boolean
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  update public.bank_statement set status = 'imported', from_date = p_day, to_date = p_day,
    opening_booked_minor = v_open, closing_booked_minor = v_close, counts = '{}', finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object('from_date', p_day, 'to_date', p_day, 'covers_from', p_day,
                                                    'covers_to', p_day, 'opening_minor', v_open::text,
                                                    'closing_minor', v_close::text, 'created_at', now()))
  where id = s;
  return s;
end $$;
-- a part, as the sheets send it
create or replace function pg_temp.pt(p_kind text, p_transfer uuid, p_amount bigint, p_client uuid default null,
                                      p_returns uuid default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('kind', p_kind, 'transfer_id', p_transfer, 'client_id', p_client,
                                              'returns_line_id', p_returns, 'amount', p_amount::text)) $$;
create or replace function pg_temp.pv(p_line uuid, p_parts jsonb, p_user text default '01', p_aal text default 'aal2')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.transfer_line_preview(p_line, p_parts);
  reset role;
  return v;
end $$;
create or replace function pg_temp.op(p_line uuid, p_user text default '01', p_aal text default 'aal2')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.transfer_line_options(p_line);
  reset role;
  return v;
end $$;
-- the parts the options propose for a line (its first proposal's request)
create or replace function pg_temp.prop(p_line uuid) returns jsonb language sql as $$
  select pg_temp.op(p_line) -> 'proposals' -> 0 -> 'request' $$;
-- « Comptabiliser » by ops (user 01 by default) with the preview's text (as the sheet sends it)
create or replace function pg_temp.bk(p_line uuid, p_parts jsonb, p_key text default null, p_user text default '01',
                                      p_text text default null, p_reason text default 'motif de test',
                                      p_aal text default 'aal2') returns jsonb language plpgsql as $$
declare v jsonb; v_text text := p_text;
begin
  if v_text is null then
    v_text := coalesce(pg_temp.pv(p_line, p_parts) ->> 'expected_text', 'none');
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.book_transfer_line(coalesce(p_key, 'bk-' || md5(p_line::text || coalesce(p_parts::text, ''))), p_line,
                                 p_parts, v_text, p_reason);
  reset role;
  return v;
end $$;
-- the same, its refusal's code (or ok), its effects kept only when it books
create or replace function pg_temp.bkx(p_line uuid, p_parts jsonb, p_key text default null, p_user text default '01',
                                       p_text text default null, p_reason text default 'motif de test',
                                       p_aal text default 'aal2') returns text language plpgsql as $$
begin
  perform pg_temp.bk(p_line, p_parts, p_key, p_user, p_text, p_reason, p_aal);
  return 'ok';
exception when others then
  return regexp_replace(sqlerrm, '^transfer line booking refused: ', '');
end $$;
-- the preview's refusal (or ok)
create or replace function pg_temp.why(p_line uuid, p_parts jsonb) returns text language sql as $$
  select coalesce(pg_temp.pv(p_line, p_parts) ->> 'why', 'ok') $$;
-- a payout in flight: client c's collection n of p_amount (three days ago), its run (its commission set off: N = 82 %),
-- the file generated and handed out (every ordered payout and the sweep in it); returns the payout
create or replace function pg_temp.inflight(p_c text, p_n text, p_amount bigint, p_key text) returns uuid
language plpgsql as $$
declare v_run uuid; v_file uuid;
begin
  perform pg_temp.queued(p_c, p_n, p_amount, p_key);
  v_file := (pg_temp.gen('01', 'gen-' || p_key) ->> 'file_id')::uuid;
  insert into t values ('file-' || p_key, v_file) on conflict (k) do update set v = excluded.v;
  perform pg_temp.write(v_file);
  perform pg_temp.download('01', v_file);
  return pg_temp.v('tr-' || p_key);
end $$;
-- the same up to the approval (the payout ordered, in no file)
create or replace function pg_temp.queued(p_c text, p_n text, p_amount bigint, p_key text) returns uuid
language plpgsql as $$
declare v_run uuid;
begin
  perform pg_temp.file(p_n, ('20000000-0000-0000-0000-0000000000' || p_c)::uuid, p_amount);
  perform pg_temp.collect(p_n, p_amount, private.paris_today() - 3);
  v_run := pg_temp.runk(p_c, jsonb_build_object(p_n, p_amount::text), p_amount * 18 / 100, p_amount * 3 / 100, p_key);
  insert into t values ('run-' || p_key, v_run) on conflict (k) do update set v = excluded.v;
  insert into t values ('tr-' || p_key, (select transfer_id from public.remittance_run where id = v_run))
  on conflict (k) do update set v = excluded.v;
  return pg_temp.v('tr-' || p_key);
end $$;
-- (test only) the items of a file executed on p_day: its execution dates moved back (files generated today execute on
-- the next business day after the account's cut-off, and a statement line is never dated in the future)
create or replace function pg_temp.exec_on(p_file uuid, p_day date) returns void language plpgsql as $$
begin
  alter table public.transfer_file_item disable trigger transfer_file_item_append_only;
  update public.transfer_file_item set execution_date = p_day where file_id = p_file;
  alter table public.transfer_file_item enable always trigger transfer_file_item_append_only;
end $$;
-- a client's waiting queue (its pending items, reserved or not), its returned-payout items, its payout account
create or replace function pg_temp.queued_minor(p_c text) returns bigint language sql as $$
  select coalesce(sum(q.amount_minor), 0)::bigint from private.remittance_pending q
  where q.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.returned_items(p_c text) returns bigint language sql as $$
  select count(*) from private.remittance_pending q
  where q.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid and q.kind = 'payout_returned' $$;
create or replace function pg_temp.payout_account(p_c text) returns text language sql as $$
  select status from public.client_payout_account
  where client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid order by created_at limit 1 $$;
create or replace function pg_temp.iban(p_c text) returns text language sql as $$
  select iban from public.client_payout_account
  where client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid order by created_at limit 1 $$;
create or replace function pg_temp.c(p_c text) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.amt(p_transfer uuid) returns bigint language sql as $$
  select amount_minor from public.bank_transfer where id = p_transfer $$;
-- a line's bookings, its entries' keys
create or replace function pg_temp.keys(p_line uuid) returns text[] language sql as $$
  select coalesce(array_agg(regexp_replace(e.idempotency_key, '[0-9a-f-]{36}', '·', 'g') order by k.seq), '{}')
  from public.bank_line_booking k join public.ledger_entry e on e.id = k.entry_id
  where k.bank_transaction_id = p_line $$;
-- the advance and pending rows an unplanned booking of line p_line posted
create or replace function pg_temp.unplanned_rows(p_line uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'entries', (select jsonb_agg(e.entry_type || ':' || regexp_replace(e.idempotency_key, '[0-9a-f-]{36}', '·', 'g')
                                 order by e.idempotency_key)
                from public.ledger_entry e
                where e.organization_id = '00000000-0000-0000-0000-0000000000aa'
                  and (e.idempotency_key like 'remit:line:' || p_line || ':%'
                       or e.idempotency_key like 'adv:line:' || p_line || ':%')),
    'pending', (select jsonb_agg(q.kind || ':' || q.amount_minor order by q.kind)
                from private.remittance_pending q
                join public.ledger_entry e on e.id = q.ledger_entry_id
                where e.idempotency_key like 'remit:line:' || p_line || ':%'
                   or e.idempotency_key like 'adv:line:' || p_line || ':%'),
    'advance', (select jsonb_agg(a.cause || ':' || a.amount_minor) from public.client_advance a
                where a.bank_transaction_id = p_line)) $$;
-- the funds pass messages queued (process_debits with funds_after)
create or replace function pg_temp.funds_msgs() returns bigint language sql as $$
  select count(*) from pgmq.q_payments m
  where m.message ->> 'type' = 'process_debits' and m.message ? 'funds_after' and m.message -> 'funds_after' = 'null' $$;
-- (review CSR-2) whether this session holds the one-bigint advisory lock of key k, as pg_advisory_xact_lock(bigint) takes
-- it (pg_locks: classid the high 32 bits, objid the low 32 bits, objsubid 1)
create or replace function pg_temp.holds_advisory(p_key bigint) returns boolean language sql as $$
  select exists (select 1 from pg_locks k where k.locktype = 'advisory' and k.pid = pg_backend_pid() and k.granted
                   and k.objsubid = 1 and k.classid = ((p_key >> 32) & 4294967295)::text::oid
                   and k.objid = (p_key & 4294967295)::text::oid) $$;
-- a client's returned payout account retired and its IBAN confirmed again (as a client who gives its RIB again after the
-- return: the payout_account_returned blocker lifts)
create or replace function pg_temp.reconfirm(p_c text) returns void language plpgsql as $$
begin
  update public.client_payout_account set status = 'retired', closed_by = '10000000-0000-0000-0000-000000000001',
    closed_at = now(), closed_reason = 'Reconfirmé après le retour du virement (test)'
  where client_organization_id = pg_temp.c(p_c) and status = 'returned';
  insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                            evidence_document_id, proposed_by)
  select gen_random_uuid(), a.organization_id, a.client_organization_id, a.currency, a.iban, a.holder_name,
         a.evidence_document_id, '10000000-0000-0000-0000-000000000004'
  from public.client_payout_account a where a.client_organization_id = pg_temp.c(p_c)
  order by a.created_at limit 1;
  update public.client_payout_account set status = 'active', confirmed_at = now(), confirmed_via = 'second_admin',
    confirmed_by = '10000000-0000-0000-0000-000000000001'
  where client_organization_id = pg_temp.c(p_c) and confirmed_at is null;
end $$;
-- a part's facts in a preview: [kind, paid, advance, bound]
create or replace function pg_temp.pp(p_preview jsonb, p_n integer default 0) returns jsonb language sql as $$
  select jsonb_build_array(p_preview -> 'parts' -> p_n ->> 'kind', p_preview -> 'parts' -> p_n ->> 'paid_minor',
                           p_preview -> 'parts' -> p_n ->> 'advance_minor', p_preview -> 'parts' -> p_n ->> 'p_bound') $$;
grant execute on all functions in schema pg_temp to authenticated;


-- (037's plain prepare and approval, its cancellation helpers)
create or replace function pg_temp.prepare_plain(p_run uuid) returns integer language plpgsql as $$
declare r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         pf.mandate_id, case when pf.mandate_id is not null
                             then ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid end,
         e.payment_id, e.effective_date, e.effective_date, q.posted_at,
         case when q.amount_minor > 0 then e.effective_date + 30 end,
         case when q.amount_minor > 0 then e.effective_date + 27 end, q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text), 0, 'none', '[]', false
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  left join public.account a on a.id = e.account_id
  left join public.portfolio pf on pf.id = a.portfolio_id
  where q.draft_run_id = p_run;
  -- (M2c-7b) an advance's item on its advance's mandate, as the job reads it (the line insert guard checks it)
  update private.remittance_draft_line l set mandate_id = ca.mandate_id
  from public.ledger_entry e, public.client_advance ca
  where l.run_id = p_run and l.kind in ('client_advance', 'client_advance_reversal') and e.id = l.ledger_entry_id
    and ca.entry_id = case l.kind when 'client_advance' then e.id else e.reverses_entry_id end;
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', (select sum(amount_minor)::text from private.remittance_draft_line where run_id = p_run),
    'invoice_ht', '0', 'invoice_vat', '0', 'invoice_ttc', '0', 'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0',
    'taken', '0', 'advances', '0', 'refunds', '0', 'settlement', '0',
    'net', (select sum(amount_minor)::text from private.remittance_draft_line where run_id = p_run), 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || 'plain', 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', '[]'::jsonb, 'key_states', '[]'::jsonb,
    'plan', '{"settles": [], "net": "0", "settlement": "0", "dc": "0", "da": "0", "vat_moved": "0", "deferred": true}'));
  return (select version from public.remittance_run where id = p_run);
end $$;
create or replace function pg_temp.approve_plain(p_run uuid, p_key text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs('ap-' || p_key, pg_temp.item(p_run));
  reset role;
  v := private.approve_remittance_run(p_run, (select job_token from public.remittance_run where id = p_run)) ->> 'status';
  return coalesce(v, '?') || ':' || (select status from public.remittance_run where id = p_run);
end $$;
create or replace function pg_temp.request(p_c text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := (public.request_remittance_run('rq-' || p_key, pg_temp.c(p_c)) ->> 'run_id')::uuid;
  reset role;
  return v;
end $$;
create or replace function pg_temp.cancel_run(p_run uuid, p_key text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user('04');
  set local role authenticated;
  v := public.cancel_remittance_run('cancel-' || p_key, p_run, (select version from public.remittance_run where id = p_run),
                                    'annulé (test)') ->> 'status';
  reset role;
  return v;
end $$;
-- a payout cancelled after its file was handed out (the switch on, as 6b-3 will do it), its run cancelled
create or replace function pg_temp.cancelled_late(p_c text, p_n text, p_amount bigint, p_key text,
                                                  p_cancel_run boolean default true) returns uuid language plpgsql as $$
declare v_t uuid;
begin
  v_t := pg_temp.inflight(p_c, p_n, p_amount, p_key);
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_t;
  if p_cancel_run then
    perform pg_temp.cancel_run(pg_temp.v('run-' || p_key), p_key);
  end if;
  return v_t;
end $$;

-- 043's own helpers -----------------------------------------------------------------------------------------------------
-- another servicer's admin (06): the full check's refusal
insert into auth.users (id, email, aud, role)
values ('10000000-0000-0000-0000-000000000006', 'u06@book.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role)
values ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000bb', 'admin');
create or replace function pg_temp.pf(p_c text) returns uuid language sql as $$
  select ('20000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.mandate(p_c text) returns uuid language sql as $$
  select ('70000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.alloc(p_n text) returns uuid language sql as $$
  select id from public.ledger_entry where payment_id = pg_temp.pay(p_n) and entry_type = 'allocation'
  order by posted_at, id limit 1 $$;
create or replace function pg_temp.rev(p_entry uuid) returns uuid language sql as $$
  select id from public.ledger_entry where reverses_entry_id = p_entry $$;
create or replace function pg_temp.adv_of(p_r uuid) returns public.client_advance language sql as $$
  select a.* from public.client_advance a where a.cause_entry_id = p_r order by a.created_at, a.id limit 1 $$;
-- a client's advances [cause:amount] (in a fixed order), and those whose entry is not reversed
create or replace function pg_temp.advs(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(a.cause || ':' || a.amount_minor order by a.cause, a.amount_minor desc), '[]')
  from public.client_advance a where a.client_organization_id = pg_temp.c(p_c) $$;
create or replace function pg_temp.live_advs(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(a.cause || ':' || a.amount_minor order by a.cause, a.amount_minor desc), '[]')
  from public.client_advance a where a.client_organization_id = pg_temp.c(p_c)
    and not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = a.entry_id) $$;
-- a client's pending queue [kind:amount] and its total
create or replace function pg_temp.queue(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(q.kind || ':' || q.amount_minor order by q.kind, q.amount_minor), '[]')
  from private.remittance_pending q where q.client_organization_id = pg_temp.c(p_c) $$;
-- a book of the servicer (a client's when p_c is given) as of p_on
create or replace function pg_temp.bal(p_book text, p_c text, p_on date) returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.organization_id = '00000000-0000-0000-0000-0000000000aa' and la.book = p_book
    and (p_c is null or la.client_organization_id = pg_temp.c(p_c)) and p.effective_date <= p_on $$;
create or replace function pg_temp.edate(p_entry uuid) returns date language sql as $$
  select effective_date from public.ledger_entry where id = p_entry $$;
create or replace function pg_temp.ekey(p_entry uuid) returns text language sql as $$
  select idempotency_key from public.ledger_entry where id = p_entry $$;
create or replace function pg_temp.rnum(p_run uuid) returns text language sql as $$
  select number from public.remittance_run where id = p_run $$;
create or replace function pg_temp.rstatus(p_run uuid) returns text language sql as $$
  select status from public.remittance_run where id = p_run $$;
create or replace function pg_temp.rtransfer(p_run uuid) returns uuid language sql as $$
  select transfer_id from public.remittance_run where id = p_run $$;
-- the SQLSTATE a statement raises ('ok' when none), in a rolled-back subtransaction
create or replace function pg_temp.state(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'state rolled back' using errcode = 'TR003';
  exception when sqlstate 'TR003' then
    v := 'ok';
  when others then
    get stacked diagnostics v = returned_sqlstate;
  end;
  return v;
end $$;
-- a scenario in a rolled-back subtransaction, the switch on when p_on, its outcome kept (or its error's text)
create or replace function pg_temp.iso(p_scenario text, p_on boolean default false) returns jsonb language plpgsql as $$
declare v jsonb; v_msg text; v_state text;
begin
  begin
    if p_on then
      update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
    end if;
    execute format('select pg_temp.%I()', p_scenario) into v;
    raise exception 'scenario % rolled back', p_scenario using errcode = 'TR001';
  exception when sqlstate 'TR001' then
    null;
  when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    v := jsonb_build_object('error', v_state || ': ' || v_msg);
  end;
  reset role;
  return v;
end $$;
-- a client's collection n of p_amount on its file (p_day, three days ago by default): pending
create or replace function pg_temp.pending(p_c text, p_n text, p_amount bigint, p_day date default null)
returns void language plpgsql as $$
begin
  perform pg_temp.file(p_n, pg_temp.pf(p_c), p_amount);
  perform pg_temp.collect(p_n, p_amount, coalesce(p_day, private.paris_today() - 3));
end $$;
-- the client's run: requested, prepared without commission, approved; the run
create or replace function pg_temp.flight(p_c text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := pg_temp.request(p_c, 'run-' || p_key);
  perform pg_temp.prepare_plain(v);
  perform pg_temp.approve_plain(v, 'run-' || p_key);
  return v;
end $$;
-- (test only) a transfer executed from p_day: its execution dates moved back (a statement line is never dated in the
-- future, and a debit counts for its chain only from the transfer's execution date)
create or replace function pg_temp.exec_back(p_transfer uuid, p_day date) returns void language plpgsql as $$
begin
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = p_day where id = p_transfer;
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  alter table public.transfer_file_item disable trigger transfer_file_item_append_only;
  update public.transfer_file_item set execution_date = p_day where transfer_id = p_transfer;
  alter table public.transfer_file_item enable always trigger transfer_file_item_append_only;
end $$;
-- the run's payout debited on p_day (yesterday by default): its file handed out if it is not, its debit on statement
-- p_s (hex), booked by the job's funds pass; the debit line
create or replace function pg_temp.debit(p_run uuid, p_s text, p_day date default null) returns uuid
language plpgsql as $$
declare v_t uuid := pg_temp.rtransfer(p_run); v_day date := coalesce(p_day, private.paris_today() - 1);
begin
  if pg_temp.status(v_t) = 'ordered' then
    perform pg_temp.handed_out('file-' || p_s, 'gen-file-' || p_s);
  end if;
  perform pg_temp.exec_back(v_t, v_day);
  perform pg_temp.stmt2(p_s, v_day, jsonb_build_array(jsonb_build_object('amount', pg_temp.amt(v_t),
                                                                         'e2e', pg_temp.e2e(v_t))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2(p_s, 1), 'payout', v_t)));
  return pg_temp.l2(p_s, 1);
end $$;
-- a client's collection n of p_amount (collected on p_coll, three days ago by default) remitted in a run whose payout is
-- debited on p_day; the run
create or replace function pg_temp.remitted(p_c text, p_n text, p_amount bigint, p_s text, p_day date default null,
                                            p_coll date default null) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount, p_coll);
  v := pg_temp.flight(p_c, 'rm-' || p_s);
  perform pg_temp.debit(v, p_s, p_day);
  return v;
end $$;
-- the run's payout returned by the client's bank on p_day (statement p_s), booked by the job's funds pass
create or replace function pg_temp.bounce(p_run uuid, p_s text, p_day date default null) returns void
language plpgsql as $$
declare v_t uuid := pg_temp.rtransfer(p_run);
begin
  perform pg_temp.stmt2(p_s, coalesce(p_day, private.paris_today()), jsonb_build_array(jsonb_build_object(
    'dir', 'credit', 'kind', 'return', 'amount', pg_temp.amt(v_t), 'orig', pg_temp.e2e(v_t))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2(p_s, 1), 'payout_returned', v_t)));
end $$;
-- « Désimputer » as p_user: the payment's live allocations on its file (or p_entries); the result, or its error
create or replace function pg_temp.unalloc(p_n text, p_key text default null, p_user text default '01',
                                           p_aal text default 'aal2', p_entries uuid[] default null)
returns jsonb language plpgsql as $$
declare v jsonb; v_state text; v_msg text;
        v_e uuid[] := coalesce(p_entries, array(
          select x.id from public.ledger_entry x where x.payment_id = pg_temp.pay(p_n) and x.entry_type = 'allocation'
            and not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = x.id)));
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.reverse_allocation(coalesce(p_key, 'unalloc-' || p_n), pg_temp.pay(p_n), pg_temp.f(p_n), v_e,
                                   'motif de test');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v := jsonb_build_object('error', v_state, 'message', v_msg);
  end;
  reset role;
  return v;
end $$;
-- « Couvrir » as p_user (an admin by default): its result, or its error's message
create or replace function pg_temp.cover(p_key text, p_r uuid, p_expected text, p_user text default '04',
                                         p_aal text default 'aal2') returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.cover_remitted_reversal(p_key, p_r, p_expected);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Vérification complète des avances » as p_user for servicer p_org: its result, or its error's message
create or replace function pg_temp.full_req(p_key text, p_user text default '04', p_aal text default 'aal2',
                                            p_org uuid default '00000000-0000-0000-0000-0000000000aa')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.request_full_advance_check(p_key, p_org);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- a public read as p_user (aal2 unless said): its jsonb, or its error's message
create or replace function pg_temp.read_as(p_user text, p_sql text, p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    execute p_sql into v;
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- the run page's advances [[cause, amount]] (as ops)
create or replace function pg_temp.page_advances(p_run uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(x ->> 'cause', x ->> 'amount_minor') order by x ->> 'cause'), '[]')
  from jsonb_array_elements(pg_temp.read_as('01', format('select public.remittance_run_payout(%L)', p_run))
                              -> 'advances') x $$;
-- the advance checks alone into a check run of their own (finished), as of p_today, full pass or not; the run
create or replace function pg_temp.adv_run(p_today date default null, p_full boolean default false) returns uuid
language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_advance_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today, p_full);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return v;
end $$;
-- a check run's rows of a code: [subject is p_subject, amount]
create or replace function pg_temp.rows_of(p_run uuid, p_code text, p_subject uuid default null) returns jsonb
language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(c.subject_id = p_subject, c.amount_minor)
                            order by c.amount_minor, c.subject_id), '[]')
  from public.payment_check_result c where c.run_id = p_run and c.code = p_code $$;
-- (test only) a completed check run started p_days from now (the delta window's start), with its listed reversals
-- a finished check run of the servicer started at p_at, listing nothing
create or replace function pg_temp.prior_run_at(p_at timestamptz) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id, started_at)
  values ('00000000-0000-0000-0000-0000000000aa', p_at) returning id into v;
  update public.payment_check_run set finished_at = p_at, violations = 0, alerts = 0, summary = '{}' where id = v;
  return v;
end $$;
create or replace function pg_temp.prior_run(p_days integer, p_listed uuid[] default '{}') returns uuid
language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id, started_at)
  values ('00000000-0000-0000-0000-0000000000aa', now() + make_interval(days => p_days))
  returning id into v;
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count)
  select v, '00000000-0000-0000-0000-0000000000aa', 'remitted_reversal_uncovered', 'violation', 'ledger_entry', x, 'EUR',
         1, 1
  from unnest(p_listed) x;
  update public.payment_check_run set finished_at = now() + make_interval(days => p_days), violations = 0, alerts = 0,
    summary = '{}' where id = v;
  return v;
end $$;
-- (switch on) client c's collection n of p_amount in a run whose payout, handed out, is cancelled after the download and
-- its run cancelled (the item back in the queue); the payout
create or replace function pg_temp.late_cancel(p_c text, p_n text, p_amount bigint, p_s text) returns uuid
language plpgsql as $$
declare v_run uuid; v_t uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount);
  v_run := pg_temp.flight(p_c, 'lc-' || p_s);
  perform pg_temp.handed_out('file-' || p_s, 'gen-file-' || p_s);
  v_t := pg_temp.rtransfer(v_run);
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_t;
  perform pg_temp.cancel_run(v_run, 'lc-' || p_s);
  return v_t;
end $$;
-- (switch on) transfer x executed late, on statement p_s today: booked « hors reversement » for its whole amount
create or replace function pg_temp.late_exec(p_x uuid, p_s text) returns text language plpgsql as $$
begin
  perform pg_temp.stmt2(p_s, private.paris_today(), jsonb_build_array(jsonb_build_object(
    'amount', pg_temp.amt(p_x), 'e2e', pg_temp.e2e(p_x))));
  return pg_temp.bkx(pg_temp.l2(p_s, 1), jsonb_build_array(pg_temp.pt('unplanned_payout', p_x, pg_temp.amt(p_x))));
end $$;
-- transfer x coming back today (statement p_s), booked as the options propose (its refusal's code, or ok)
create or replace function pg_temp.late_return(p_x uuid, p_s text) returns text language plpgsql as $$
begin
  perform pg_temp.stmt2(p_s, private.paris_today(), jsonb_build_array(jsonb_build_object(
    'dir', 'credit', 'kind', 'return', 'amount', pg_temp.amt(p_x), 'orig', pg_temp.e2e(p_x))));
  return pg_temp.bkx(pg_temp.l2(p_s, 1), pg_temp.prop(pg_temp.l2(p_s, 1)));
end $$;
-- payment n of p_amount on a file owing p_file_amount: p_file_amount allocated, the rest forwarded to the client (as
-- « Reverser au client » posts it: +4710 / −4670[c]), three days ago
create or replace function pg_temp.split_pay(p_c text, p_n text, p_amount bigint, p_file_amount bigint)
returns void language plpgsql as $$
declare d date := private.paris_today() - 3;
begin
  perform pg_temp.file(p_n, pg_temp.pf(p_c), p_file_amount);
  perform pg_temp.collect(p_n, p_amount, d, false);
  update public.payment set account_id = pg_temp.f(p_n), status = 'matched', match_method = 'rf_structured',
                            matched_at = now()
  where id = pg_temp.pay(p_n);
  perform private.allocation_begin();
  insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy, inputs_hash)
  values (pg_temp.pay(p_n), 1, pg_temp.f(p_n), 'allocate', d,
          '{"accessory_rank": "before_principal", "unclassified": "last"}', repeat('0', 64));
  insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
  values (pg_temp.pay(p_n), 1, pg_temp.it(p_n), 'principal', p_file_amount);
  perform private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-' || p_n);
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, payment_id, source_type, source_id, reason)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'forward', d, 'forward:test-' || p_n, pg_temp.c(p_c),
          pg_temp.pay(p_n), 'payment', pg_temp.pay(p_n)::text, 'Reversement sans imputation (test)');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency) values
    (1, 1, 'unallocated_payment', p_amount - p_file_amount, 'EUR'),
    (1, 2, 'client_payable', -(p_amount - p_file_amount), 'EUR');
  perform private.ledger_post_set();
end $$;
-- the job's mode: return links (method auto) of [line, payment n] through private.apply_debit_decisions
create or replace function pg_temp.job_returns(p_links jsonb) returns jsonb language plpgsql as $$
begin
  perform private.debit_link_begin();
  insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, method)
  select x.ord, (x.v ->> 0)::uuid, 'return', pg_temp.pay(x.v ->> 1), 'auto'
  from jsonb_array_elements(p_links) with ordinality x (v, ord);
  return private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
end $$;
-- a planted settlement of an advance (a claw-back or a payment of 7b/7c, which do not exist yet)
create or replace function pg_temp.plant_settlement(p_advance uuid, p_amount bigint) returns void language sql as $$
  insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id, kind,
                                            amount_minor, settled_on)
  select a.organization_id, a.client_organization_id, 'advance', a.id, 'compensation', p_amount, private.paris_today()
  from public.client_advance a where a.id = p_advance $$;
-- advances read as p_user
create or replace function pg_temp.n_advances(p_user text, p_aal text default 'aal2') returns integer
language plpgsql as $$
declare n integer;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  select count(*) into n from public.client_advance;
  reset role;
  return n;
end $$;
-- a late predecessor (switch on): client c's run (collection n) handed out, its transfer x1 cancelled after the
-- download and re-issued as x2 (ordered), the run in flight again on x2; x1 then executed late (statement p_s, on p_day),
-- booked from « Débits et retours » as its run's payout (x2 withdrawn). The run
create or replace function pg_temp.late_pred(p_c text, p_n text, p_amount bigint, p_s text, p_unalloc boolean,
                                             p_day date default null) returns uuid language plpgsql as $$
declare v_run uuid; v_x1 uuid; v_x2 uuid; v_day date := coalesce(p_day, private.paris_today() - 1);
begin
  perform pg_temp.pending(p_c, p_n, p_amount, private.paris_today() - 6);
  v_run := pg_temp.flight(p_c, 'lp-' || p_s);
  perform pg_temp.handed_out('file-' || p_s, 'gen-file-' || p_s);
  v_x1 := pg_temp.rtransfer(v_run);
  perform pg_temp.exec_back(v_x1, v_day);
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_x1;
  insert into public.bank_transfer (organization_id, client_organization_id, kind, debtor_bank_account_id, currency,
                                    amount_minor, payee_name, payee_iban, payee_bic, end_to_end_id, remittance_info,
                                    requested_execution_date, run_id, ordered_by, replaces_transfer_id)
  select x.organization_id, x.client_organization_id, 'payout', x.debtor_bank_account_id, x.currency, x.amount_minor,
         x.payee_name, x.payee_iban, x.payee_bic, 'RMT' || upper(substr(md5(gen_random_uuid()::text), 1, 12)),
         x.remittance_info, x.requested_execution_date, x.run_id, x.ordered_by, x.id
  from public.bank_transfer x where x.id = v_x1
  returning id into v_x2;
  alter table public.remittance_run disable trigger remittance_run_guard;
  update public.remittance_run set transfer_id = v_x2, status = 'approved', version = version + 1 where id = v_run;
  alter table public.remittance_run enable always trigger remittance_run_guard;
  insert into t values ('x1-' || p_s, v_x1), ('x2-' || p_s, v_x2);
  if p_unalloc then
    perform pg_temp.unalloc(p_n);
  end if;
  perform pg_temp.stmt2(p_s, v_day, jsonb_build_array(jsonb_build_object('amount', pg_temp.amt(v_x1),
                                                                         'e2e', pg_temp.e2e(v_x1))));
  insert into t values ('lp-booked-' || p_s, null);
  update t set v = case pg_temp.bkx(pg_temp.l2(p_s, 1), pg_temp.prop(pg_temp.l2(p_s, 1))) when 'ok' then v_run end
  where k = 'lp-booked-' || p_s;
  return v_run;
end $$;
-- (review round 1) a run of client c prepared from its whole queue, its invoice (p_num / p_den of file n's collection,
-- 20 % VAT) set off for the whole gross — the caller sizes it so that the invoice's TTC is the gross: N = 0, booked at
-- approval with its settlement; the version
create or replace function pg_temp.prepare_off(p_run uuid, p_c text, p_n text, p_num bigint, p_den bigint)
returns integer language plpgsql as $$
declare r public.remittance_run; v_files jsonb; v_keys jsonb; v_gross bigint; v_ht bigint; v_plan jsonb;
begin
  select * into r from public.remittance_run where id = p_run;
  v_files := jsonb_build_object(p_n, (select amount_minor from public.payment where id = pg_temp.pay(p_n))::text);
  v_keys := pg_temp.keys(p_c, v_files, p_num, p_den);
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         pf.mandate_id, case when pf.mandate_id is not null
                             then ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid end,
         e.payment_id, e.effective_date, e.effective_date, q.posted_at,
         case when q.amount_minor > 0 then e.effective_date + 30 end,
         case when q.amount_minor > 0 then e.effective_date + 27 end, q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text),
         coalesce((select (k ->> 'commission')::bigint from jsonb_array_elements(v_keys) k
                   where (k ->> 'account_id')::uuid = e.account_id), 0),
         case when e.account_id is not distinct from pg_temp.f(p_n) then 'charged' else 'none' end, '[]',
         e.account_id is not distinct from pg_temp.f(p_n)
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  left join public.account a on a.id = e.account_id
  left join public.portfolio pf on pf.id = a.portfolio_id
  where q.draft_run_id = p_run;
  v_gross := (select sum(amount_minor) from private.remittance_draft_line where run_id = p_run);
  v_ht := (select sum((x.value)::bigint * p_num / p_den) from jsonb_each_text(v_files) x);
  if v_ht + v_ht / 5 <> v_gross then
    raise exception 'prepare_off: the invoice''s TTC % is not the gross %', v_ht + v_ht / 5, v_gross;
  end if;
  v_plan := pg_temp.plan(p_c, v_gross, v_ht, v_gross, v_ht / 5);
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', v_gross::text,
    'invoice_ht', v_plan ->> 'invoice_ht', 'invoice_vat', v_plan ->> 'invoice_vat', 'invoice_ttc', v_plan ->> 'invoice_ttc',
    'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0', 'taken', v_plan ->> 'dc', 'advances', '0', 'refunds', '0',
    'settlement', v_plan ->> 'settlement', 'net', v_plan ->> 'net', 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || v_plan::text, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', pg_temp.doc(p_c, v_files, p_num, p_den), 'key_states', v_keys, 'plan', v_plan));
  return (select version from public.remittance_run where id = p_run);
end $$;
-- (review round 1, tests-ui-5) the nightly's two violations of the advances after a scenario (a full pass of
-- run_advance_checks): [code, amount] — none expected wherever the scenario posts, releases or re-posts a cover
create or replace function pg_temp.nightly() returns jsonb language plpgsql as $$
declare c uuid := pg_temp.adv_run(null, true);
begin
  return (select coalesce(jsonb_agg(jsonb_build_array(x.code, x.amount_minor) order by x.code, x.amount_minor), '[]')
          from public.payment_check_result x
          where x.run_id = c and x.code in ('remitted_reversal_uncovered', 'advance_ledger'));
end $$;
-- (review round 2) the sequential scans of the tables an item's settlement reads, so far in this transaction
create or replace function pg_temp.seqs() returns bigint language sql as $$
  select coalesce(sum(x.seq_scan), 0)::bigint from pg_stat_xact_user_tables x
  where x.relid in ('private.unplanned_paid_item'::regclass, 'public.remittance_line'::regclass,
                    'public.remittance_run'::regclass, 'public.bank_line_booking'::regclass,
                    'public.ledger_entry'::regclass) $$;
-- (review round 1, CC-2) the rows a table's index scans fetched so far in this transaction
create or replace function pg_temp.fetched(p_table regclass) returns bigint language sql as $$
  select coalesce((select x.idx_tup_fetch from pg_stat_xact_user_tables x where x.relid = p_table), 0) $$;
grant execute on all functions in schema pg_temp to authenticated;


-- 044's own helpers ---------------------------------------------------------------------------------------------------
-- the write-off evidence of Martin (a1), Lilas (a2) and Petit (a8): d…3<client>
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-0000000003' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'advance_write_off_evidence', 'client/test/3' || c || '.pdf',
       repeat('a', 64), 'application/pdf'
from unnest(array['a1', 'a2', 'a8']) c;
-- « Passer en perte » as p_user (an admin at aal2 by default): its result, or its error's message
create or replace function pg_temp.wo(p_key text, p_adv uuid, p_amount text, p_expected text,
                                      p_reason text default 'Client liquidé, créance irrécouvrable (test)',
                                      p_evidence uuid default 'd0000000-0000-0000-0000-0000000003a1',
                                      p_user text default '04', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.write_off_advance('woff-044-' || p_key, p_adv, p_amount, p_expected, p_reason, p_evidence);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- a forged 4670 debit of client c (a planted overrun before its payout's booking, as 043 #39)
create or replace function pg_temp.forge(p_c text, p_amount bigint, p_tag text) returns void language plpgsql as $$
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'remittance', private.paris_today() - 1, 'remit:test-forged-' || p_tag,
          pg_temp.c(p_c), 'bank_transaction', 'e1000000-0000-0000-0000-000000000013');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_payable', p_amount, 'EUR', null),
    (1, 2, 'client_money_cash', -p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cf');
  perform private.ledger_post_set();
end $$;
-- client c's second portfolio (20…b<c's last digit>) on a second mandate (70…b<…>, its terms 71…b<…>)
create or replace function pg_temp.pf2(p_c text) returns uuid language sql as $$
  select ('20000000-0000-0000-0000-0000000000b' || right(p_c, 1))::uuid $$;
create or replace function pg_temp.second_mandate(p_c text) returns void language plpgsql as $$
declare v_m uuid := ('70000000-0000-0000-0000-0000000000b' || right(p_c, 1))::uuid;
begin
  insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on,
                              insurance_clause_ref)
  values (v_m, '00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_c), 'MAND-b' || right(p_c, 1), 'mandate_amicable',
          '2026-01-01', 'art. 9');
  insert into public.mandate_terms (id, mandate_id, valid_from, commission_schedule, commission_clause_ref,
                                    remittance_terms, remittance_clause_ref, document_id)
  select ('71000000-0000-0000-0000-0000000000b' || right(p_c, 1))::uuid, v_m, t.valid_from, t.commission_schedule,
         t.commission_clause_ref, t.remittance_terms, t.remittance_clause_ref, t.document_id
  from public.mandate_terms t where t.mandate_id = pg_temp.mandate(p_c);
  insert into public.portfolio (id, organization_id, client_organization_id, name, mandate_id)
  values (pg_temp.pf2(p_c), '00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_c), 'P2' || p_c, v_m);
end $$;
-- (test only) the claw-back clause in client c's terms (its version immutable once in force: the guard set aside)
create or replace function pg_temp.clawback(p_c text, p_ref text) returns void language plpgsql as $$
begin
  alter table public.mandate_terms disable trigger mandate_terms_guard;
  update public.mandate_terms
  set remittance_terms = jsonb_set(remittance_terms, '{clawback}', jsonb_build_object('clause_ref', p_ref))
  where mandate_id = pg_temp.mandate(p_c);
  alter table public.mandate_terms enable always trigger mandate_terms_guard;
end $$;
-- What the prepare job writes for a run that takes advances back (emulated): its whole queue as lines, a remitted
-- reversal's cover's item on its advance's mandate and any other advance's on none (as the job reads them; review round
-- 1, M7B-MONEY-1), no commission; its plan settles each [advance, amount] of p_takes
-- (kind advance, open_before its open as the job reads it), N = gross − Σ, D = Da = Σ
create or replace function pg_temp.prepare_adv(p_run uuid, p_takes jsonb) returns integer language plpgsql as $$
declare r public.remittance_run; v_gross bigint; v_take bigint; v_settles jsonb; v_plan jsonb;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         coalesce(pf.mandate_id, case when ca.cause = 'remitted_reversal' then ca.mandate_id end),
         case when pf.mandate_id is not null
              then ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid end,
         e.payment_id, e.effective_date, e.effective_date, q.posted_at,
         case when q.amount_minor > 0 then e.effective_date + 30 end,
         case when q.amount_minor > 0 then e.effective_date + 27 end, q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text), 0, 'none', '[]', false
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  left join public.account a on a.id = e.account_id
  left join public.portfolio pf on pf.id = a.portfolio_id
  left join public.client_advance ca on ca.entry_id = case q.kind when 'client_advance' then e.id
                                                                  when 'client_advance_reversal' then e.reverses_entry_id end
  where q.draft_run_id = p_run;
  v_gross := (select sum(amount_minor) from private.remittance_draft_line where run_id = p_run);
  select coalesce(sum((x ->> 1)::bigint), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'ref', x ->> 0, 'kind', 'advance', 'mandate_id', ca.mandate_id, 'amount', x ->> 1, 'vat_moved', '0',
           'open_before', (ca.amount_minor - coalesce((select sum(s.amount_minor) from public.commission_settlement s
                                                       where s.document_kind = 'advance' and s.document_id = ca.id),
                                                      0))::text)), '[]')
  into v_take, v_settles
  from jsonb_array_elements(p_takes) x
  join public.client_advance ca on ca.id = (x ->> 0)::uuid;
  v_plan := jsonb_build_object('settles', v_settles, 'net', (v_gross - v_take)::text, 'settlement', v_take::text,
                               'dc', '0', 'da', v_take::text, 'vat_moved', '0', 'deferred', v_take = 0);
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', v_gross::text,
    'invoice_ht', '0', 'invoice_vat', '0', 'invoice_ttc', '0', 'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0',
    'taken', '0', 'advances', v_take::text, 'refunds', '0', 'settlement', v_take::text,
    'net', (v_gross - v_take)::text, 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || v_plan::text, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', '[]'::jsonb, 'key_states', '[]'::jsonb, 'plan', v_plan));
  return (select version from public.remittance_run where id = p_run);
end $$;
-- a line planted into run p_run for entry p_entry (kind, amount, mandate), its line number or the refusal
create or replace function pg_temp.plant_line(p_run uuid, p_entry uuid, p_kind text, p_amount bigint, p_mandate uuid)
returns text language sql as $$
  select regexp_replace(pg_temp.attempt(format(
    'insert into public.remittance_line (run_id, line_no, organization_id, client_organization_id, currency, '
    'ledger_entry_id, kind, mandate_id, effective_date, posted_at, amount_minor, commission_state) '
    'select r.id, 99, r.organization_id, r.client_organization_id, r.currency, %L, %L, %L, current_date, now(), %s, '
    '''none'' from public.remittance_run r where r.id = %L returning line_no', p_entry, p_kind, p_mandate, p_amount,
    p_run)), '[0-9a-f-]{36}/', '') $$;
grant execute on all functions in schema pg_temp to authenticated;



-- The base (as 044's): the account's cash (an unidentified payment of 10 000,00 €) and its statement of yesterday
select pg_temp.collect('13', 1000000, private.paris_today() - 6, false);
select pg_temp.stmt('00', private.paris_today() - 1);

-- 045's own helpers ---------------------------------------------------------------------------------------------------
-- each client's evidence: a payment's (d…5<c>), a refund's (d…6<c>), a designation's (d…7<c>), a status event's
-- (d…8<c>); a write-off's (044's kind) for Dupont (a6)
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-000000000' || x.n || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa'::uuid,
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || x.c || '.pdf',
       repeat('a', 64), 'application/pdf'
from (select c, n, case n when '5' then 'client_payment_evidence' when '6' then 'client_refund_evidence'
                          when '7' then 'payment_designation_evidence' else 'client_status_evidence' end as kind
      from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c
      cross join unnest(array['5', '6', '7', '8']) n) x
union all
select 'd0000000-0000-0000-0000-0000000003a6'::uuid, '00000000-0000-0000-0000-0000000000aa'::uuid,
       '00000000-0000-0000-0000-0000000000a6'::uuid, 'advance_write_off_evidence', 'client/test/3a6.pdf', repeat('a', 64),
       'application/pdf';
create or replace function pg_temp.ev(p_n text, p_c text) returns uuid language sql as $$
  select ('d0000000-0000-0000-0000-000000000' || p_n || p_c)::uuid $$;
-- an invoice of client c: its collection n of p_amount (three days ago) in a run (key inv-<s>) whose plan sets off p_take
-- of it (VAT moved p_vat), approved, its payout debited on statement s (hex) unless p_debit is false; the invoice (the run
-- kept as run-<s>). Commission 15 %, VAT 20 %: 200 000 collected → 30 000 HT, 6 000 VAT, 36 000 TTC
create or replace function pg_temp.inv(p_c text, p_n text, p_amount bigint, p_s text, p_take bigint default 0,
                                       p_vat bigint default 0, p_debit boolean default true) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount);
  v := pg_temp.runk(p_c, jsonb_build_object(p_n, p_amount::text), p_take, p_vat, 'inv-' || p_s);
  insert into t values ('run-' || p_s, v) on conflict (k) do update set v = excluded.v;
  if p_debit then
    perform pg_temp.debit(v, p_s);
  end if;
  return (select i.id from public.commission_invoice i where i.run_id = v and i.kind = 'invoice');
end $$;
-- (test only) an invoice's due date, or its issue date, moved (its append-only guard, and its year check, set aside)
create or replace function pg_temp.due(p_inv uuid, p_day date) returns void language plpgsql as $$
begin
  alter table public.commission_invoice disable trigger commission_invoice_append_only;
  update public.commission_invoice set due_date = p_day where id = p_inv;
  alter table public.commission_invoice enable always trigger commission_invoice_append_only;
end $$;
create or replace function pg_temp.issued(p_inv uuid, p_day date) returns void language plpgsql as $$
begin
  alter table public.commission_invoice drop constraint if exists commission_invoice_year;
  alter table public.commission_invoice disable trigger commission_invoice_append_only;
  update public.commission_invoice set issue_date = p_day where id = p_inv;
  alter table public.commission_invoice enable always trigger commission_invoice_append_only;
end $$;
create or replace function pg_temp.num(p_inv uuid) returns text language sql as $$
  select number from public.commission_invoice where id = p_inv $$;
-- an advance of client c: its collection n of p_amount remitted (debited d − 2 on statement s), then taken back
-- (« Désimputer »): its cover
create or replace function pg_temp.adv(p_c text, p_n text, p_amount bigint, p_s text) returns public.client_advance
language plpgsql as $$
begin
  perform pg_temp.remitted(p_c, p_n, p_amount, p_s, private.paris_today() - 2, private.paris_today() - 3);
  perform pg_temp.unalloc(p_n);
  return pg_temp.adv_of(pg_temp.rev(pg_temp.alloc(p_n)));
end $$;
-- « Enregistrer un règlement » (own account) as p_user (ops 01 at aal2 by default): its result, or its error's message.
-- The open the page showed is the preview's unless given; the evidence the client's own (p_ev 'own'), none, or a uuid
create or replace function pg_temp.cpay(p_key text, p_c text, p_amount text, p_value date default null,
                                        p_docs uuid[] default null, p_desig uuid default null,
                                        p_recover uuid[] default null, p_expected text default null,
                                        p_ev text default 'own', p_user text default '01', p_aal text default 'aal2')
returns jsonb language plpgsql as $$
declare v jsonb; v_exp text := p_expected; v_on date := coalesce(p_value, private.paris_today());
begin
  if v_exp is null then
    v_exp := pg_temp.read_as('01', format('select public.client_payment_preview(%L, ''EUR'', %L, %L, %L, %L)',
                                          pg_temp.c(p_c), p_amount, p_docs, p_recover, v_on)) ->> 'open_minor';
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.record_client_payment('cpay-045-' || p_key, pg_temp.c(p_c), 'EUR', p_amount, v_on,
                                      case p_ev when 'own' then pg_temp.ev('5', p_c) when 'none' then null
                                                else p_ev::uuid end,
                                      p_docs, p_desig, p_recover, v_exp, 'Virement reçu (test)');
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Règlement d'une facture ou d'une avance du cabinet » on a dedicated-account line, as p_user (ops 01 at aal2)
create or replace function pg_temp.cline(p_key text, p_line uuid, p_docs uuid[] default null, p_desig uuid default null,
                                         p_recover uuid[] default null, p_expected text default null,
                                         p_user text default '01', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb; v_exp text := p_expected;
begin
  if v_exp is null then
    v_exp := pg_temp.read_as('01', format('select public.client_payment_line(%L, %L, %L)', p_line, p_docs, p_recover))
             #>> '{preview,open_minor}';
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.book_client_payment_line('cpayl-045-' || p_key, p_line, p_docs, p_desig, p_recover, v_exp,
                                         'Règlement du client (test)');
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Enregistrer le remboursement » (a credit note or a client credit) as p_user: the owed the page showed is today's
-- unless given; the evidence the client's (p_ev 'own'), none, or a uuid
create or replace function pg_temp.crfd(p_key text, p_doc uuid, p_amount text, p_paid date default null,
                                        p_expected text default null, p_ev text default 'own',
                                        p_user text default '01', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb; v_c uuid; v_exp text := p_expected;
begin
  v_c := coalesce((select i.client_organization_id from public.commission_invoice i where i.id = p_doc),
                  (select c.client_organization_id from public.client_credit c where c.id = p_doc));
  if v_exp is null then
    v_exp := coalesce(private.document_open(p_doc), private.client_credit_open(p_doc), 0)::text;
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.record_client_refund('crfd-045-' || p_key, p_doc, p_amount, coalesce(p_paid, private.paris_today()),
                                     case p_ev when 'own' then pg_temp.ev('6', right(v_c::text, 2))
                                               when 'none' then null else p_ev::uuid end,
                                     v_exp, 'Virement de remboursement (test)');
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- a document's settlements [[kind, amount, VAT moved]], in their order
create or replace function pg_temp.sets(p_doc uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(s.kind, s.amount_minor, s.vat_moved_minor) order by s.created_at, s.id),
                  '[]')
  from public.commission_settlement s where s.document_id = p_doc $$;
-- a client's credits owed back [[cause, amount, open]]
create or replace function pg_temp.ccs(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(c.cause, c.amount_minor, private.client_credit_open(c.id))
                            order by c.cause), '[]')
  from public.client_credit c where c.client_organization_id = pg_temp.c(p_c) $$;
-- the advance checks' rows of 7c-1's codes as of p_today (the full pass): [code, severity, amount, cause, p0]
create or replace function pg_temp.cchecks(p_today date default null) returns jsonb language plpgsql as $$
declare c uuid := pg_temp.adv_run(p_today, true);
begin
  return (select coalesce(jsonb_agg(jsonb_build_array(x.code, x.severity, x.amount_minor, x.details ->> 'cause',
                                                      x.details -> 'p0') order by x.code, x.amount_minor), '[]')
          from public.payment_check_result x
          where x.run_id = c and x.code in ('client_credit_owed', 'client_credit_ledger', 'written_off_recovery_ledger'));
end $$;
-- a book's balance as of today (a client's when p_c is given)
create or replace function pg_temp.bk0(p_book text, p_c text default null) returns bigint language sql as $$
  select pg_temp.bal(p_book, p_c, private.paris_today()) $$;
-- a credit line on the dedicated account (statement s, hex; yesterday unless p_day) of kind p_kind from p_iban,
-- labelled p_label, carrying p_e2e; and the debit job's review of it (client_credit for a client's credit); the line
create or replace function pg_temp.ctin(p_s text, p_amount bigint, p_iban text, p_label text default null,
                                        p_kind text default 'client_transfer_in', p_e2e text default null,
                                        p_day date default null) returns uuid language plpgsql as $$
declare
  v_day date := coalesce(p_day, private.paris_today() - 1);
  s uuid := ('e4' || lpad(p_s, 6, '0') || '-0000-0000-0000-000000000000')::uuid;
  v_open bigint := pg_temp.cash() + (select u.minor from private.bank_unposted('80000000-0000-0000-0000-0000000000cf',
                                                                               'infinity'::date) u);
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, counterparty_iban,
                                       counterparty_name, remittance_text)
  values (pg_temp.l2(p_s, 1), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, 1,
          't:' || s || '1', 'credit', p_amount, 'EUR', v_day, p_kind, p_e2e, p_iban, 'CLIENT (test)', p_label);
  update public.bank_statement set status = 'imported', from_date = v_day, to_date = v_day,
    opening_booked_minor = v_open, closing_booked_minor = v_open + p_amount, counts = '{}',
    finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object('from_date', v_day, 'to_date', v_day, 'covers_from', v_day,
                                                    'covers_to', v_day, 'opening_minor', v_open::text,
                                                    'closing_minor', (v_open + p_amount)::text, 'created_at', now()))
  where id = s;
  if p_kind = 'client_transfer_in' then
    perform pg_temp.book('[]'::jsonb, jsonb_build_array(jsonb_build_object('line', pg_temp.l2(p_s, 1),
                                                                           'reason', 'client_credit')));
  end if;
  return pg_temp.l2(p_s, 1);
end $$;
-- the IBAN of client c's confirmed payout account
create or replace function pg_temp.iban_of(p_c text) returns text language sql as $$
  select iban from public.client_payout_account where client_organization_id = pg_temp.c(p_c) and status = 'active' $$;
-- (test only) a run's plan made to pay p_doc as a refund (the run in flight, as an approval would freeze it)
create or replace function pg_temp.plan_refund(p_run uuid, p_doc uuid, p_amount bigint) returns void
language plpgsql as $$
begin
  alter table public.remittance_run disable trigger remittance_run_guard;
  update public.remittance_run
  set settlement_plan = jsonb_build_object('settles', jsonb_build_array(jsonb_build_object(
                          'kind', 'refund', 'document_id', p_doc, 'amount', p_amount::text, 'vat_moved', '0')))
  where id = p_run;
  alter table public.remittance_run enable always trigger remittance_run_guard;
end $$;
-- the remittance checks' rows of a code as of p_today: [subject, amount]
create or replace function pg_temp.rrc(p_code text, p_today date) returns jsonb language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa') returning id into v;
  perform private.run_remittance_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return coalesce((select jsonb_agg(jsonb_build_array(c.subject_id, c.amount_minor) order by c.amount_minor)
                   from public.payment_check_result c where c.run_id = v and c.code = p_code), '[]');
end $$;
-- a raw entry of the servicer's fund (lines [book, amount], a 5122 line on the own account, 5120 on the dedicated one)
-- of type p_type for client c, posted by the ledger's write path: 'ok', or the SQLSTATE it raised (rolled back)
create or replace function pg_temp.post(p_type text, p_key text, p_lines jsonb, p_c text default 'a1') returns text
language sql as $$
  select pg_temp.state(format(
    $q$
    do $d$
    begin
      perform private.ledger_post_set_begin();
      insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                      client_organization_id, source_type, source_id, reason)
      values (1, '00000000-0000-0000-0000-0000000000aa', %L, private.paris_today(), %L, %L,
              case when %L in ('client_payment_dedicated', 'client_settlement') then
                     case %L when 'client_settlement' then 'remittance_run' else 'bank_transaction' end
                   else 'document' end,
              'e1000000-0000-0000-0000-000000000013', 'Écriture de test');
      insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
      select 1, l.ord, l.v ->> 0, (l.v ->> 1)::bigint, 'EUR',
             case l.v ->> 0 when 'own_cash' then '80000000-0000-0000-0000-0000000000c0'::uuid
                            when 'client_money_cash' then '80000000-0000-0000-0000-0000000000cf'::uuid end
      from jsonb_array_elements(%L::jsonb) with ordinality l (v, ord);
      perform private.ledger_post_set();
      perform private.ledger_check_now();
    end $d$
    $q$, p_type, 'raw-045-' || p_key, pg_temp.c(p_c), p_type, p_type, p_lines)) $$;
-- the same, kept (a planted posting, for the nightly to see)
create or replace function pg_temp.plant(p_type text, p_key text, p_lines jsonb, p_c text default 'a1') returns void
language plpgsql as $$
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason)
  values (1, '00000000-0000-0000-0000-0000000000aa', p_type, private.paris_today(), 'raw-045-' || p_key, pg_temp.c(p_c),
          'document', 'e1000000-0000-0000-0000-000000000013', 'Écriture de test');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
  select 1, l.ord, l.v ->> 0, (l.v ->> 1)::bigint, 'EUR',
         case l.v ->> 0 when 'own_cash' then '80000000-0000-0000-0000-0000000000c0'::uuid end
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  perform private.ledger_post_set();
end $$;
grant execute on all functions in schema pg_temp to authenticated;


-- 045b's own helpers -------------------------------------------------------------------------------------------------
-- « Demander le remboursement » as p_user (ops 01 at aal2 by default) for client c's advances: its result, or its
-- error's message and detail. The total the sheet showed is the advances' open part now unless given.
create or replace function pg_temp.dra(p_key text, p_c text, p_advances uuid[], p_expected text default null,
                                       p_user text default '01', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb; v_msg text; v_detail text; v_exp text := p_expected;
begin
  if v_exp is null then
    v_exp := (select coalesce(sum(private.advance_open(a)), 0)::text from unnest(p_advances) a);
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.request_advance_repayment('dra-045b-' || p_key, pg_temp.c(p_c), 'EUR', p_advances, v_exp);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
    v := jsonb_build_object('error', v_msg)
         || case when coalesce(v_detail, '') <> '' then jsonb_build_object('detail', v_detail) else '{}'::jsonb end;
  end;
  reset role;
  return v;
end $$;
-- a request's refusal code (or 'ok'; another error's message as it is)
create or replace function pg_temp.why_not(p_r jsonb) returns text language sql as $$
  select case when p_r ? 'error' then coalesce(substring(p_r ->> 'error' from 'repayment request refused: (\w+)'),
                                               p_r ->> 'error')
              else 'ok' end $$;
-- « Retirer la demande » as p_user (ops 01 at aal2 by default): its result, or its error's message
create or replace function pg_temp.wd(p_key text, p_request uuid, p_reason text default 'Le client conteste la somme (test)',
                                      p_user text default '01', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.withdraw_advance_repayment_request('wd-045b-' || p_key, p_request, p_reason);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- the request a result names
create or replace function pg_temp.rq(p_r jsonb) returns public.advance_repayment_request language sql as $$
  select q.* from public.advance_repayment_request q where q.id = (p_r ->> 'request_id')::uuid $$;
-- its payload's first row's origin
create or replace function pg_temp.origin(p_r jsonb) returns jsonb language sql as $$
  select q.payload -> 'rows' -> 0 -> 'origin' from public.advance_repayment_request q
  where q.id = (p_r ->> 'request_id')::uuid $$;
-- the advances the worker's prepare reads as requested for client c (private.client_requested_advances)
create or replace function pg_temp.requested(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(x.advance_id order by x.advance_id), '[]')
  from private.client_requested_advances(pg_temp.c(p_c), 'EUR') x $$;
-- a request's storage key, and the worker's job emulated: the object stored there, then the document recorded
create or replace function pg_temp.dra_path(p_request uuid) returns text language sql as $$
  select 'repayment-requests/' || q.organization_id || '/' || q.id || '.pdf'
  from public.advance_repayment_request q where q.id = p_request $$;
create or replace function pg_temp.drawn(p_request uuid, p_sha text default repeat('c', 64)) returns uuid
language plpgsql as $$
begin
  if not exists (select 1 from storage.objects o where o.bucket_id = 'documents' and o.name = pg_temp.dra_path(p_request))
  then
    insert into storage.objects (bucket_id, name) values ('documents', pg_temp.dra_path(p_request));
  end if;
  return private.repayment_request_document_done(p_request, p_sha, 'reportlab-test');
end $$;
-- (test only) a request's issue date or recording time moved (its guard set aside)
create or replace function pg_temp.dra_back(p_request uuid, p_issue date, p_created timestamptz default null)
returns void language plpgsql as $$
begin
  alter table public.advance_repayment_request disable trigger advance_repayment_request_guard;
  update public.advance_repayment_request set issue_date = p_issue, created_at = coalesce(p_created, created_at)
  where id = p_request;
  alter table public.advance_repayment_request enable always trigger advance_repayment_request_guard;
end $$;
-- advance a of client c taken by a run whose file was handed out (its plan names it; emulated as 045's taking, with no
-- claw-back clause: a draft prepared before the terms changed): the run
create or replace function pg_temp.sent_taking(p_c text, p_adv uuid, p_n text, p_s text) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending(p_c, p_n, 100000);
  v := pg_temp.request(p_c, 'tk-' || p_s);
  perform pg_temp.prepare_adv(v, jsonb_build_array(jsonb_build_array(p_adv, private.advance_open(p_adv)::text)));
  perform pg_temp.approve_plain(v, 'tk-' || p_s);
  perform pg_temp.handed_out('file-tk' || p_s, 'gen-file-tk' || p_s);
  return v;
end $$;
-- the rows of a code in a full pass of the advance checks as of p_today: [subject is p_subject, amount, details]
create or replace function pg_temp.adv_rows(p_code text, p_subject uuid, p_today date default null) returns jsonb
language plpgsql as $$
declare c uuid := pg_temp.adv_run(p_today, true);
begin
  return (select coalesce(jsonb_agg(jsonb_build_array(x.subject_id = p_subject, x.amount_minor, x.severity)
                                    order by x.amount_minor), '[]')
          from public.payment_check_result x where x.run_id = c and x.code = p_code);
end $$;
grant execute on all functions in schema pg_temp to authenticated;



-- 046a's own helpers --------------------------------------------------------------------------------------------------
-- each client's second status evidence (d…9<c>), its authority evidence (d…b<c>: the notary's attestation, the
-- judgment naming the tutor, curator or liquidator), two more RIBs (d…c<c>, d…e<c>)
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-000000000' || x.n || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa'::uuid,
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || x.c || '.pdf',
       repeat('a', 64), 'application/pdf'
from (select c, n, case n when '9' then 'client_status_evidence' when 'b' then 'payout_authority_evidence'
                          else 'payout_rib' end as kind
      from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c
      cross join unnest(array['9', 'b', 'c', 'e']) n) x;
-- (test only) the current account of client c confirmed p_ago before now (before every event a scenario plants)
create or replace function pg_temp.confirmed_ago(p_c text, p_ago interval default '1 day') returns void
language plpgsql as $$
begin
  alter table public.client_payout_account disable trigger client_payout_account_guard;
  update public.client_payout_account set confirmed_at = now() - p_ago
  where client_organization_id = pg_temp.c(p_c) and status in ('active', 'returned');
  alter table public.client_payout_account enable always trigger client_payout_account_guard;
end $$;
-- (test only) an account's confirmation moved to p_at
create or replace function pg_temp.confirmed_at(p_account uuid, p_at timestamptz) returns void language plpgsql as $$
begin
  alter table public.client_payout_account disable trigger client_payout_account_guard;
  update public.client_payout_account set confirmed_at = p_at where id = p_account;
  alter table public.client_payout_account enable always trigger client_payout_account_guard;
end $$;
-- an event of client c as the command records it (the table is append-only: inserted), recorded p_ago before now — a
-- command records every event of one transaction at the same now(), the confirmations too; the order matters here
create or replace function pg_temp.evt(p_c text, p_kind text, p_on date, p_ago interval default '2 hours',
                                       p_refers uuid default null) returns uuid language sql as $$
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, recorded_by, recorded_at, refers_to_event_id)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_c), p_kind, p_on, pg_temp.ev('8', p_c),
          '10000000-0000-0000-0000-000000000004', now() - p_ago, p_refers)
  returning id $$;
-- an old « Tutelle ou curatelle » row, as recorded before 7d-1 (qualified_at null: no command can write one since, so
-- the guard is set aside)
create or replace function pg_temp.old_tutelle(p_c text, p_on date, p_ago interval default '2 days') returns uuid
language plpgsql as $$
declare v uuid;
begin
  alter table public.client_status_event disable trigger client_status_event_guard;
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, recorded_by, recorded_at, qualified_at)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_c), 'guardianship', p_on, pg_temp.ev('8', p_c),
          '10000000-0000-0000-0000-000000000004', now() - p_ago, null)
  returning id into v;
  alter table public.client_status_event enable always trigger client_status_event_guard;
  return v;
end $$;
-- a person who acts for a client (synthetic names, one address)
create or replace function pg_temp.person(p_role text, p_name text default null) returns jsonb language sql as $$
  select jsonb_build_object(
    'role', p_role,
    'name', coalesce(p_name, case p_role when 'notary' then 'Me Claire Lenoir, notaire'
                                         when 'heirs' then 'Les héritiers de M. Martin'
                                         when 'tutor' then 'UDAF du Rhône'
                                         when 'curator' then 'Association Tutélaire de Lyon'
                                         when 'liquidator' then 'SELARL MJ Synergie'
                                         else 'SCP Administrateurs Associés' end),
    'address_lines', jsonb_build_array('3 place du Palais', '69002 Lyon')) $$;
-- a command's refusal code (« … refused: <code> »), 'ok' for a result, the message otherwise
create or replace function pg_temp.code(p_r jsonb) returns text language sql as $$
  select case when p_r ? 'error' then coalesce(substring(p_r ->> 'error' from 'refused: (\w+)'), p_r ->> 'error')
              else 'ok' end $$;
create or replace function pg_temp.eid(p_r jsonb) returns uuid language sql as $$
  select (p_r ->> 'client_status_event_id')::uuid $$;
create or replace function pg_temp.pid(p_r jsonb) returns uuid language sql as $$
  select (p_r ->> 'payout_account_id')::uuid $$;
-- « Enregistrer un événement » as p_user (admin 04 at aal2 by default): its result, or its error's message
create or replace function pg_temp.rec(p_key text, p_c text, p_kind text, p_on date, p_rep jsonb default null,
                                       p_refers uuid default null, p_declared jsonb default null,
                                       p_publication date default null, p_user text default '04',
                                       p_aal text default 'aal2', p_ev uuid default null)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.record_client_status_event('evt-046a-' || p_key, pg_temp.c(p_c), p_kind, p_on,
                                           coalesce(p_ev, pg_temp.ev('8', p_c)), 'Événement (test)', null,
                                           p_publication, p_rep, p_refers, p_declared);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Personne qui agit pour le client » as p_user (admin 04 at aal2): its result, or its error's message (the evidence:
-- the client's second status evidence unless given)
create or replace function pg_temp.rep(p_key text, p_event uuid, p_rep jsonb, p_ev uuid default null,
                                       p_user text default '04', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb; v_c text;
begin
  v_c := (select right(e.client_organization_id::text, 2) from public.client_status_event e where e.id = p_event);
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.set_client_representative('rep-046a-' || p_key, p_event, p_rep,
                                          coalesce(p_ev, pg_temp.ev('9', coalesce(v_c, 'a1'))));
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Préciser : tutelle ou curatelle » as p_user (admin 04 at aal2): its result, or its error's message
create or replace function pg_temp.qual(p_key text, p_event uuid, p_kind text, p_ev uuid default null,
                                        p_user text default '04', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb; v_c text;
begin
  v_c := (select right(e.client_organization_id::text, 2) from public.client_status_event e where e.id = p_event);
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.qualify_protection_event('qual-046a-' || p_key, p_event, p_kind,
                                         coalesce(p_ev, pg_temp.ev('9', coalesce(v_c, 'a1'))));
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Proposer un IBAN de reversement » as p_user (ops 01 at aal2): kind, holder, the authority document (the client's
-- d…b<c> unless p_auth is false), the explanation; its result, or its error's message
create or replace function pg_temp.propose(p_key text, p_c text, p_iban text, p_holder text,
                                           p_kind text default 'client', p_auth boolean default true,
                                           p_att text default null, p_user text default '01', p_rib text default 'c')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  begin
    v := public.propose_payout_account('prop-046a-' || p_key, pg_temp.c(p_c), 'EUR', p_iban, p_holder, null,
                                       pg_temp.ev(p_rib, p_c), p_kind,
                                       case when p_auth then pg_temp.ev('b', p_c) end, p_att);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Confirmer l'IBAN » as p_user (admin 10 — a second admin: 01 and 04 propose — at aal2 unless said)
create or replace function pg_temp.confirm(p_key text, p_account uuid, p_user text default '10',
                                           p_aal text default 'aal2') returns jsonb language plpgsql as $$
declare v jsonb; v_iban text := (select a.iban from public.client_payout_account a where a.id = p_account);
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.confirm_payout_account('conf-046a-' || p_key, p_account, v_iban);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- proposed by ops and confirmed by the second admin: the account
create or replace function pg_temp.payee(p_key text, p_c text, p_iban text, p_holder text,
                                         p_kind text default 'client', p_auth boolean default true,
                                         p_att text default null) returns uuid language plpgsql as $$
declare r jsonb := pg_temp.propose(p_key, p_c, p_iban, p_holder, p_kind, p_auth, p_att);
begin
  if r ? 'error' then
    raise exception 'payee %: %', p_key, r ->> 'error';
  end if;
  r := pg_temp.confirm(p_key, pg_temp.pid(r));
  if r ? 'error' then
    raise exception 'payee % confirmed: %', p_key, r ->> 'error';
  end if;
  return pg_temp.pid(r);
end $$;
-- the payout blockers of client c (today unless said)
create or replace function pg_temp.blk(p_c text, p_on date default null) returns jsonb language sql as $$
  select to_jsonb(private.remittance_payout_blockers(pg_temp.c(p_c), 'EUR', coalesce(p_on, private.paris_today()))) $$;
-- who receives client c's letters today: [role, name, copy]
create or replace function pg_temp.addr(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(x.role, x.name, x.copy) order by x.copy, x.role), '[]')
  from private.client_addressee(pg_temp.c(p_c), private.paris_today()) x $$;
-- the seizures of client c standing on p_on, in effective order
create or replace function pg_temp.standing(p_c text, p_on date) returns uuid[] language sql as $$
  select coalesce(array_agg(x.id order by e.effective_date, e.id), '{}')
  from private.client_seizures_standing(pg_temp.c(p_c), p_on) x (id)
  join public.client_status_event e on e.id = x.id $$;
-- a payment of p_amount booked p_day on a new file n of client c, matched as the import's rules match it (the real
-- gate: private.record_assignments); its review reason ('ready' when none)
create or replace function pg_temp.match(p_c text, p_n text, p_amount bigint, p_day date) returns text
language plpgsql as $$
begin
  perform pg_temp.file(p_n, pg_temp.pf(p_c), p_amount);
  perform pg_temp.collect(p_n, p_amount, p_day, false);
  perform private.assign_begin();
  insert into pg_temp._assign (ord, payment_id, account_id, method, rule, rule_version)
  values (1, pg_temp.pay(p_n), pg_temp.f(p_n), 'rf_structured', 'R1', 'test');
  perform private.record_assignments('00000000-0000-0000-0000-0000000000aa', 'import', null, null);
  return coalesce((select p.review_reason from public.payment p where p.id = pg_temp.pay(p_n)), 'ready');
end $$;
-- « Reverser au client » as ops (01 at aal2) for payment n: its result, or its error's message
create or replace function pg_temp.fwd(p_key text, p_n text) returns jsonb language plpgsql as $$
declare v jsonb; v_left text := (select x.unallocated_minor::text from private.payment_positions(array[pg_temp.pay(p_n)]) x);
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  begin
    v := public.forward_payment('fwd-046a-' || p_key, pg_temp.pay(p_n), null, v_left, null,
                                'Reçu après la fin du mandat (test)');
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- the rows of a code in a full pass of the advance checks as of today: [subject is p_subject, p0]
create or replace function pg_temp.night(p_code text, p_subject uuid) returns jsonb language plpgsql as $$
declare c uuid := pg_temp.adv_run(null, true);
begin
  return (select coalesce(jsonb_agg(jsonb_build_array(x.subject_id = p_subject, coalesce((x.details ->> 'p0')::boolean,
                                                                                         false))
                                    order by x.subject_id = p_subject desc, x.oldest_days), '[]')
          from public.payment_check_result x where x.run_id = c and x.code = p_code);
end $$;
-- fresh valid IBANs (synthetic), by letter
create or replace function pg_temp.ib(p_k text) returns text language sql as $$
  select case p_k when 'A' then 'FR6430004424452125091990850' when 'B' then 'FR4330004853190879732321668'
                  when 'C' then 'FR4830004123377888003327207' when 'D' then 'FR6130004665100521708897211'
                  when 'E' then 'FR4730004568381038597033130' when 'F' then 'FR9730004118895820130478207'
                  when 'G' then 'FR2930004741158685814997780' when 'H' then 'FR7230004764140836534621773'
                  when 'I' then 'FR8330004767480599869698028' when 'J' then 'FR5030004061053922668714953'
                  when 'K' then 'FR3830004189071520713009273' when 'L' then 'FR1030004404332440401576413'
                  when 'M' then 'FR4230004762318835265008924' else 'FR8830004488107343290517091' end $$;
grant execute on all functions in schema pg_temp to authenticated;


-- 046b's own helpers ---------------------------------------------------------------------------------------------------
-- an invoice of client c for its collection n of p_amount collected on p_day (the claim's birth,
-- private.document_born_on), in a run (key inv-<s>) whose plan sets off p_take of it (VAT p_vat), approved today and
-- its payout debited yesterday on statement s; the invoice (the run kept as run-<s>)
create or replace function pg_temp.inv_on(p_c text, p_n text, p_amount bigint, p_s text, p_day date,
                                          p_take bigint default 0, p_vat bigint default 0) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount, p_day);
  v := pg_temp.runk(p_c, jsonb_build_object(p_n, p_amount::text), p_take, p_vat, 'inv-' || p_s);
  insert into t values ('run-' || p_s, v) on conflict (k) do update set v = excluded.v;
  perform pg_temp.debit(v, p_s);
  return (select i.id from public.commission_invoice i where i.run_id = v and i.kind = 'invoice');
end $$;
-- What the prepare job writes for a run that sets off earlier documents (emulated): its whole queue as lines (an
-- advance's item on its advance's mandate, as 044's), no commission, no documents; its plan settles each
-- {ref, kind (compensation | advance | refund), amount, vat} of p_settles, open_before the document's open part now;
-- D = Σ compensation + Σ advance − Σ refund, Dc and Da apart, N = gross − D. No set-off state written (as before 7d-2):
-- pg_temp.draft_state writes what 7d-2's prepare writes.
create or replace function pg_temp.prepare_set(p_run uuid, p_settles jsonb) returns integer language plpgsql as $$
declare r public.remittance_run; v_gross bigint; v_settles jsonb; v_d bigint; v_dc bigint; v_da bigint; v_v bigint; v_rf bigint;
        v_plan jsonb;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         coalesce(pf.mandate_id, case when ca.cause = 'remitted_reversal' then ca.mandate_id end),
         case when pf.mandate_id is not null
              then ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid end,
         e.payment_id, e.effective_date, e.effective_date, q.posted_at,
         case when q.amount_minor > 0 and q.kind in ('allocation', 'forward') then e.effective_date + 30 end,
         case when q.amount_minor > 0 and q.kind in ('allocation', 'forward') then e.effective_date + 27 end,
         q.amount_minor, jsonb_build_object('principal', q.amount_minor::text), 0, 'none', '[]', false
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  left join public.account a on a.id = e.account_id
  left join public.portfolio pf on pf.id = a.portfolio_id
  left join public.client_advance ca on ca.entry_id = case q.kind when 'client_advance' then e.id
                                                                  when 'client_advance_reversal' then e.reverses_entry_id end
  where q.draft_run_id = p_run;
  v_gross := (select sum(amount_minor) from private.remittance_draft_line where run_id = p_run);
  select coalesce(jsonb_agg(jsonb_build_object(
           'ref', x.v ->> 'ref', 'kind', x.v ->> 'kind',
           'mandate_id', coalesce((select i.mandate_id::text from public.commission_invoice i
                                   where i.id = (x.v ->> 'ref')::uuid),
                                  (select a.mandate_id::text from public.client_advance a
                                   where a.id = (x.v ->> 'ref')::uuid)),
           'amount', x.v ->> 'amount', 'vat_moved', coalesce(x.v ->> 'vat', '0'),
           'open_before', private.document_open((x.v ->> 'ref')::uuid)::text) order by x.n), '[]'),
         coalesce(sum(case x.v ->> 'kind' when 'refund' then -1 else 1 end * (x.v ->> 'amount')::bigint), 0),
         coalesce(sum(case x.v ->> 'kind' when 'compensation' then 1 when 'refund' then -1 else 0 end
                      * (x.v ->> 'amount')::bigint), 0),
         coalesce(sum(case x.v ->> 'kind' when 'advance' then (x.v ->> 'amount')::bigint else 0 end), 0),
         coalesce(sum(coalesce((x.v ->> 'vat')::bigint, 0)), 0),
         -- (review round 1, TUI-2) the refunds the plan pays, in the header as the prepare writes them
         coalesce(sum(case x.v ->> 'kind' when 'refund' then (x.v ->> 'amount')::bigint else 0 end), 0)
  into v_settles, v_d, v_dc, v_da, v_v, v_rf
  from jsonb_array_elements(p_settles) with ordinality x (v, n);
  v_plan := jsonb_build_object('settles', v_settles, 'net', (v_gross - v_d)::text, 'settlement', v_d::text,
                               'dc', v_dc::text, 'da', v_da::text, 'vat_moved', v_v::text, 'deferred', v_d = 0);
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', v_gross::text,
    'invoice_ht', '0', 'invoice_vat', '0', 'invoice_ttc', '0', 'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0',
    'taken', v_dc::text, 'advances', v_da::text, 'refunds', v_rf::text, 'settlement', v_d::text,
    'net', (v_gross - v_d)::text, 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || v_plan::text, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', '[]'::jsonb, 'key_states', '[]'::jsonb, 'plan', v_plan));
  return (select version from public.remittance_run where id = p_run);
end $$;
-- what 7d-2's prepare writes of the client's status into the draft (the opening and the bars of the day), as the job
-- reads them (private.client_opening_date, private.client_set_off_bars)
create or replace function pg_temp.draft_state(p_run uuid) returns void language plpgsql as $$
declare c uuid := (select client_organization_id from public.remittance_run where id = p_run);
        d date := private.paris_today();
begin
  update private.remittance_draft
  set proceeding_opened_on = private.client_opening_date(c, d), opening_on = private.client_opening_date(c, d),
      set_off_barred = private.client_set_off_bars(c, d)
  where run_id = p_run;
end $$;
-- a settle of p_settles
create or replace function pg_temp.st(p_ref uuid, p_kind text, p_amount bigint, p_vat bigint default 0) returns jsonb
language sql as $$
  select jsonb_build_object('ref', p_ref, 'kind', p_kind, 'amount', p_amount::text, 'vat', p_vat::text) $$;
-- a run's refusal at approval: [status, code]
create or replace function pg_temp.refused(p_run uuid) returns jsonb language sql as $$
  select jsonb_build_array(r.status, r.last_failure ->> 'code') from public.remittance_run r where r.id = p_run $$;
-- a run's settlements [[document kind, document is p_doc…, kind, amount, VAT moved]] in their order (the document by its
-- position in p_docs: 0-based, -1 when it is none of them)
create or replace function pg_temp.run_sets(p_run uuid, p_docs uuid[]) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(s.document_kind, coalesce(array_position(p_docs, s.document_id) - 1, -1),
                                              s.kind, s.amount_minor, s.vat_moved_minor) order by s.id), '[]')
  from public.commission_settlement s where s.run_id = p_run $$;
-- (review round 1) the run page's withheld set-off as ops read it: [W, its invoices' part, its advances' part, the refund
-- not paid, what the debit set off of invoices, the booked run that gave W back, the run in flight giving it back]
create or replace function pg_temp.withheld_read(p_run uuid) returns jsonb language sql as $$
  select jsonb_build_array(r ->> 'withheld_minor', r ->> 'commission_minor', r ->> 'advances_minor',
                           r ->> 'refund_unpaid_minor', r ->> 'set_off_commission_minor', r ->> 'given_back_by',
                           r ->> 'giving_back_by')
  from (select pg_temp.read_as('01', format('select public.remittance_run_withheld(%L)', p_run)) as r) z $$;
-- a planted barred settlement of run p_run for client c (lines +4670 / −4679 ‖ +4689 / −4111 of p_amount), never
-- reversed: what only a bug could leave; the entry
create or replace function pg_temp.plant_barred(p_run uuid, p_c text, p_amount bigint) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'client_settlement', private.paris_today(),
          'settle:' || p_run || ':barred', pg_temp.c(p_c), 'remittance_run', p_run::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency) values
    (1, 1, 'client_payable', p_amount, 'EUR'), (1, 2, 'due_to_servicer', -p_amount, 'EUR'),
    (1, 3, 'due_from_client_funds', p_amount, 'EUR'), (1, 4, 'commission_receivable', -p_amount, 'EUR');
  select x.entry_id into v from private.ledger_post_set() x;
  return v;
end $$;
-- the reversal of p_entry under key p_key (today), as a SQLSTATE ('ok' when posted), rolled back
create or replace function pg_temp.rev_as(p_entry uuid, p_key text) returns text language sql as $$
  select pg_temp.state(format('select private.ledger_reverse(%L, %L, %L, %L)', p_entry, p_key,
                              'Retour (test)', private.paris_today())) $$;
grant execute on all functions in schema pg_temp to authenticated;


-- 046c's own helpers ---------------------------------------------------------------------------------------------------
-- a proceeding or a liquidation of client c effective p_on, published p_pub (none when null), recorded p_ago before now
create or replace function pg_temp.opening(p_c text, p_kind text, p_on date, p_pub date default null,
                                           p_ago interval default '1 minute') returns uuid language sql as $$
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, recorded_by, recorded_at, publication_date)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_c), p_kind, p_on, pg_temp.ev('8', p_c),
          '10000000-0000-0000-0000-000000000004', now() - p_ago, p_pub)
  returning id $$;
-- an advance of client c born on p_day: its collection n of p_amount (the day before) remitted in a run debited p_day,
-- then « Désimputer »-ed (the cover dated at the payout it covers)
create or replace function pg_temp.adv_on(p_c text, p_n text, p_amount bigint, p_s text, p_day date)
returns public.client_advance language plpgsql as $$
begin
  perform pg_temp.remitted(p_c, p_n, p_amount, p_s, p_day, p_day - 1);
  perform pg_temp.unalloc(p_n);
  return pg_temp.adv_of(pg_temp.rev(pg_temp.alloc(p_n)));
end $$;
-- the remittance runs' checks alone into a check run of their own (finished) as of p_today; the run
create or replace function pg_temp.rr_run(p_today date) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_remittance_runs_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return v;
end $$;
-- a check run's rows of a code, each by the name p_names gives its subject ('other' for any other)
create or replace function pg_temp.names(p_run uuid, p_code text, p_names jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_agg(coalesce(n.key, 'other') order by coalesce(n.key, 'other')), '[]')
  from public.payment_check_result c
  left join lateral (select x.key from jsonb_each_text(p_names) x where x.value::uuid = c.subject_id limit 1) n on true
  where c.run_id = p_run and c.code = p_code $$;
-- claims_to_declare's rows by name: [amount, document kind, born before the opening, deadline basis, born (days from
-- p_d), deadline = its anchor + two months (null: none), p0]
create or replace function pg_temp.claims(p_run uuid, p_names jsonb, p_pub date, p_d date) returns jsonb
language sql as $$
  select coalesce(jsonb_object_agg(coalesce(n.key, 'other'), jsonb_build_array(
           c.amount_minor, c.details ->> 'document_kind', (c.details ->> 'pre_opening')::boolean,
           c.details ->> 'deadline_basis', (c.details ->> 'born_on')::date - p_d,
           case when c.details ->> 'deadline' is null then null
                else (c.details ->> 'deadline')::date
                       = (case when (c.details ->> 'pre_opening')::boolean then p_pub
                               else (c.details ->> 'born_on')::date end + interval '2 months')::date end,
           (c.details ->> 'p0')::boolean)), '{}')
  from public.payment_check_result c
  left join lateral (select x.key from jsonb_each_text(p_names) x where x.value::uuid = c.subject_id limit 1) n on true
  where c.run_id = p_run and c.code = 'claims_to_declare' $$;
-- the run's payout to its client: collection n of p_amount (three days ago) on client c's file, the run prepared without
-- commission or set-off (the client's status of the day recorded in its draft), approved, its file generated, written
-- and downloaded (ops 01); the payout (the run kept as run-<key>)
create or replace function pg_temp.out_plain(p_c text, p_n text, p_amount bigint, p_key text) returns uuid
language plpgsql as $$
declare v uuid; f uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount);
  v := pg_temp.request(p_c, 'op-' || p_key);
  perform pg_temp.prepare_plain(v);
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'op-' || p_key);
  insert into t values ('run-' || p_key, v) on conflict (k) do update set v = excluded.v;
  f := (pg_temp.gen('01', 'gen-op-' || p_key) ->> 'file_id')::uuid;
  insert into t values ('file-' || p_key, f) on conflict (k) do update set v = excluded.v;
  perform pg_temp.write(f);
  perform pg_temp.download('01', f);
  return pg_temp.rtransfer(v);
end $$;
-- a run of client c with nothing to pay (N = 0: its collection n and that collection's reversal, a same-run pair),
-- prepared with the client's status of the day in its draft and approved (booked at once: no payout, no blockers); the run
create or replace function pg_temp.zero_run(p_c text, p_n text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending(p_c, p_n, 100000);
  perform private.ledger_reverse(pg_temp.alloc(p_n), 'raw-046c-' || p_n, 'Retour (test)', private.paris_today());
  v := pg_temp.request(p_c, 'zr-' || p_key);
  perform pg_temp.prepare_plain(v);
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'zr-' || p_key);
  return v;
end $$;
-- payout_after_liquidation's rows by name: [status, amount, cancellable, downloaded]
create or replace function pg_temp.pal(p_run uuid, p_names jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_object_agg(coalesce(n.key, 'other'), jsonb_build_array(
           c.details ->> 'status', c.amount_minor, (c.details ->> 'cancellable')::boolean,
           (c.details ->> 'downloaded')::boolean)), '{}')
  from public.payment_check_result c
  left join lateral (select x.key from jsonb_each_text(p_names) x where x.value::uuid = c.subject_id limit 1) n on true
  where c.run_id = p_run and c.code = 'payout_after_liquidation' $$;
-- « Enregistrer la suite » of a payout after a liquidation as p_user (admin 04 at aal2), the evidence the client's status
-- evidence (d…8<c>) unless given: its result, or its error's message
create or replace function pg_temp.disp(p_key text, p_transfer uuid, p_kind text, p_ev uuid default null,
                                        p_note text default 'Ratifié par le liquidateur (test)',
                                        p_user text default '04', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
        v_c text := (select right(t.client_organization_id::text, 2) from public.bank_transfer t where t.id = p_transfer);
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.record_liquidation_payout_disposition('disp-046c-' || p_key, p_transfer, p_kind,
                                                      coalesce(p_ev, pg_temp.ev('8', coalesce(v_c, 'a1'))), p_note);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Compensation maintenue » of a set-off set_off_after_bar alerts, as p_user (admin 04 at aal2), the evidence the
-- client's status evidence unless given: its result, or its error's message
create or replace function pg_temp.outc(p_key text, p_entry uuid, p_kind text, p_ev uuid default null,
                                        p_note text default 'Avis de l''avocat : compensation maintenue (test)',
                                        p_user text default '04', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
        v_c text := (select right(e.client_organization_id::text, 2) from public.ledger_entry e where e.id = p_entry);
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.record_set_off_outcome('outc-046c-' || p_key, p_entry, p_kind,
                                       coalesce(p_ev, pg_temp.ev('8', coalesce(v_c, 'a1'))), p_note);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- the withheld read with the run its payout's return was repaid by: [given_back_by, giving_back_by, returned_by]
create or replace function pg_temp.withheld_back(p_run uuid) returns jsonb language sql as $$
  select jsonb_build_array(r ->> 'given_back_by', r ->> 'giving_back_by', r ->> 'returned_by')
  from (select pg_temp.read_as('01', format('select public.remittance_run_withheld(%L)', p_run)) as r) z $$;
-- the statement's payload of a run, as the documents job builds it
create or replace function pg_temp.stmt_of(p_run uuid) returns jsonb language sql as $$
  select private.remittance_statement_build(p_run) $$;
-- the record step for one statement drawn by p_template: 'recorded', or the error's message
create or replace function pg_temp.record_stmt(p_run uuid, p_template text) returns text language plpgsql as $$
declare v jsonb;
begin
  perform private.remittance_documents_begin('00000000-0000-0000-0000-0000000000aa', 10, 10);
  begin
    perform private.remittance_statement_prepare(p_run);
    insert into pg_temp._rd_statement_files (run_id, pdf_sha256, csv_sha256)
    values (p_run, repeat('b', 64), repeat('c', 64));
    v := private.remittance_documents_record('00000000-0000-0000-0000-0000000000aa', p_template,
                                             'facture-commission-fr-3', 'test');
    raise exception 'record rolled back: %', v using errcode = 'TR004';
  exception when sqlstate 'TR004' then
    return 'recorded';
  when others then
    return sqlerrm;
  end;
end $$;
grant execute on all functions in schema pg_temp to authenticated;




-- 047a's own helpers ---------------------------------------------------------------------------------------------------
-- what the servicer owes the dedicated account now, by the formula (EUR)
create or replace function pg_temp.need() returns bigint language plpgsql as $$
begin
  return private.top_up_needed('00000000-0000-0000-0000-0000000000aa', 'EUR');
end $$;
-- a bank charge of p_amount on statement s (hex, today), booked by the job's funds pass (+4679 / −5120): the line
create or replace function pg_temp.fee(p_s text, p_amount bigint) returns uuid language plpgsql as $$
begin
  perform pg_temp.stmt2(p_s, private.paris_today(),
                        jsonb_build_array(jsonb_build_object('amount', p_amount, 'kind', 'other_debit')));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2(p_s, 1), 'fee')));
  return pg_temp.l2(p_s, 1);
end $$;
-- the servicer's top-ups [status:amount], by status then amount
create or replace function pg_temp.tops() returns jsonb language sql as $$
  select coalesce(jsonb_agg(t.status || ':' || t.amount_minor order by t.status, t.amount_minor), '[]')
  from public.bank_transfer t where t.organization_id = '00000000-0000-0000-0000-0000000000aa' and t.kind = 'top_up' $$;
-- the servicer's top-up of that amount (and status)
create or replace function pg_temp.top_of(p_amount bigint, p_status text default null) returns public.bank_transfer
language sql as $$
  select t.* from public.bank_transfer t
  where t.organization_id = '00000000-0000-0000-0000-0000000000aa' and t.kind = 'top_up' and t.amount_minor = p_amount
    and (p_status is null or t.status = p_status)
  order by t.id limit 1 $$;
-- « Approvisionner le compte dédié » by ops (user 01): a top-up of p_amount typed in the bank; the transfer
create or replace function pg_temp.req_top(p_key text, p_amount bigint) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := (public.request_top_up(p_key, '80000000-0000-0000-0000-0000000000c0', '80000000-0000-0000-0000-0000000000cf',
                              p_amount::text, 'Approvisionnement (test)') ->> 'transfer_id')::uuid;
  reset role;
  return v;
end $$;
-- the hourly order of servicer p_org, as the worker's top_ups job runs it
create or replace function pg_temp.ord(p_org uuid default '00000000-0000-0000-0000-0000000000aa') returns integer
language sql as $$ select private.order_due_top_up(p_org) $$;
-- « Générer le fichier (compte propre) » as p_user: its result, or {error}
create or replace function pg_temp.topgen(p_user text, p_key text,
                                          p_account uuid default '80000000-0000-0000-0000-0000000000c0',
                                          p_aal text default 'aal2') returns jsonb language sql as $$
  select pg_temp.read_as(p_user, format('select public.generate_top_up_file(%L, %L)', p_key, p_account), p_aal) $$;
-- an own-account file generated by ops (01), written by the job (emulated) and downloaded; the file
create or replace function pg_temp.top_out(p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := (pg_temp.topgen('01', p_key) ->> 'file_id')::uuid;
  perform pg_temp.write(v);
  perform pg_temp.download('01', v);
  return v;
end $$;
-- « Télécharger » as ops (01): its result, or {error}
create or replace function pg_temp.dl(p_file uuid, p_ack boolean default false) returns jsonb language sql as $$
  select pg_temp.read_as('01', format('select public.transfer_file_download(%L, %L, %L)', p_file, pg_temp.sha(p_file),
                                      p_ack)) $$;
-- a credit of p_amount on the dedicated account (statement s, today), from the own IBAN unless said, carrying p_e2e
create or replace function pg_temp.own_credit(p_s text, p_amount bigint, p_e2e text default null,
                                              p_kind text default 'own_transfer_in',
                                              p_iban text default 'FR7610107001011234567890129') returns uuid
language plpgsql as $$
begin
  perform pg_temp.stmt2(p_s, private.paris_today(), jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
    'dir', 'credit', 'kind', p_kind, 'amount', p_amount, 'e2e', p_e2e, 'iban', p_iban))));
  return pg_temp.l2(p_s, 1);
end $$;
-- « Annuler le fichier » as p_user: its result, or {error}
create or replace function pg_temp.topcancel(p_key text, p_file uuid, p_user text default '01') returns jsonb
language sql as $$
  select pg_temp.read_as(p_user, format('select public.cancel_top_up_file(%L, %L, %L)', p_key, p_file,
                                        'Fichier non déposé à la banque (test)')) $$;
-- « Rattacher à TOP… » as p_user: its result, or {error}
create or replace function pg_temp.pick(p_key text, p_line uuid, p_transfer uuid, p_user text default '01')
returns jsonb language sql as $$
  select pg_temp.read_as(p_user, format('select public.book_top_up_credit(%L, %L, %L, %L)', p_key, p_line, p_transfer,
                                        'Crédit du compte propre arrivé sans sa référence (test)')) $$;
-- « Annuler » a top-up as ops (01): its result, or {error}
create or replace function pg_temp.cancel_top(p_key text, p_transfer uuid) returns jsonb language sql as $$
  select pg_temp.read_as('01', format('select public.cancel_top_up(%L, %L, %L)', p_key, p_transfer,
                                      'Annulé (test)')) $$;
-- the servicer's shortfall periods [open, peak], oldest first
create or replace function pg_temp.periods() returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(p.closed_at is null, p.peak_minor) order by p.opened_at, p.id), '[]')
  from private.servicer_shortfall_period p where p.organization_id = '00000000-0000-0000-0000-0000000000aa' $$;
-- a line's bookings [kind, its transfer is p_transfer]
create or replace function pg_temp.booked_as(p_line uuid, p_transfer uuid default null) returns jsonb
language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(b.kind, b.transfer_id is not distinct from p_transfer) order by b.seq),
                  '[]')
  from public.bank_line_booking b where b.bank_transaction_id = p_line $$;
-- the advance checks' rows of a code (a check run of their own, as of p_today): [amount, details]
create or replace function pg_temp.night_rows(p_code text, p_today date default null) returns jsonb
language plpgsql as $$
declare v uuid;
begin
  v := pg_temp.adv_run(p_today);
  return coalesce((select jsonb_agg(jsonb_build_array(c.amount_minor, c.details) order by c.amount_minor)
                   from public.payment_check_result c where c.run_id = v and c.code = p_code), '[]');
end $$;
-- a file's status and its top-ups [status:amount]
create or replace function pg_temp.file_tops(p_file uuid) returns jsonb language sql as $$
  select jsonb_build_array((select f.status from public.transfer_file f where f.id = p_file),
                           (select coalesce(jsonb_agg(t.status || ':' || t.amount_minor
                                                      order by t.status, t.amount_minor), '[]')
                            from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
                            where i.file_id = p_file)) $$;
-- a refusal's code (the text after « refused: »), or its whole message
create or replace function pg_temp.why_of(p_r jsonb) returns text language sql as $$
  select coalesce(substring(p_r ->> 'error' from 'refused: ([a-z_]+)'), p_r ->> 'error', 'ok') $$;
-- a statement in a rolled-back subtransaction: 'ok', or its error's SQLSTATE and message (« 23514: … »; review round 1
-- of 7e-1, TUI-4: the guards' refusals are check_violation, not only their text)
create or replace function pg_temp.try_sql(p_sql text) returns text language plpgsql as $$
declare v text; v_state text;
begin
  begin
    execute p_sql;
    raise exception 'try rolled back' using errcode = 'TR005';
  exception when sqlstate 'TR005' then
    v := 'ok';
  when others then
    get stacked diagnostics v = message_text, v_state = returned_sqlstate;
    v := v_state || ': ' || v;
  end;
  return v;
end $$;
-- (review round 1) « Rattacher à TOP… »'s booking row posted raw (service role, no command): the re-check's verdict
create or replace function pg_temp.raw_pick(p_line uuid, p_transfer uuid) returns jsonb language plpgsql as $$
begin
  perform private.bank_booking_begin();
  insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method, decided_by, reason)
  values (1, p_line, 'top_up', p_transfer, 'ops', null, 'Rattaché sans la commande (test)');
  return private.post_bank_bookings('00000000-0000-0000-0000-0000000000aa', true);
end $$;
-- (review round 1) a line's own-account posting [its bank account, amount] (the 5122 leg of servicer_top_up)
create or replace function pg_temp.own_leg(p_line uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(la.bank_account_id, p.amount_minor) order by p.line_no), '[]')
  from public.bank_line_booking b join public.ledger_posting p on p.entry_id = b.entry_id
  join public.ledger_account la on la.id = p.ledger_account_id
  where b.bank_transaction_id = p_line and la.book = 'own_cash' $$;
-- (review round 1) the advance checks' rows of a code for servicer p_org (a check run of its own):
-- [count, oldest_days, details without last_run_at]
create or replace function pg_temp.night_of(p_org uuid, p_code text) returns jsonb language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values (p_org) returning id into v;
  perform private.run_advance_checks(v, p_org);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return coalesce((select jsonb_agg(jsonb_build_array(c.count, c.oldest_days, c.details - 'last_run_at')
                                    order by c.currency nulls first)
                   from public.payment_check_result c where c.run_id = v and c.code = p_code), '[]');
end $$;
grant execute on all functions in schema pg_temp to authenticated;


-- 047b's own helpers --------------------------------------------------------------------------------------------------
-- the other servicer's (bb) dedicated account and own account, and its sweep (SWP…47B2): another account's transfer
insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000be', '00000000-0000-0000-0000-0000000000bb', 'client_funds',
   'FR0730001007940000000001002', 'TESTFRPPXXX', 'EUR', 'Fonds de tiers bb', 'csv', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000bb', 'own',
   'FR2730001007940000000047202', null, 'EUR', 'Compte propre bb', null, '2026-01-01');
-- a statement n (hex, up to 6 digits) of an account (the dedicated one by default), CSV unless said, for p_day: its lines
-- staged as the parser stages them [{dir, kind, amount, e2e, iban, name, text, ref, refs, code, key, day}] and imported
-- by private.ingest_statement — the label's candidates in label_references: `refs` (in the label's order; review round
-- 1, MB-1), else `ref` alone —; the import's counts, or {error}
create or replace function pg_temp.imp(p_n text, p_day date, p_lines jsonb,
                                       p_account uuid default '80000000-0000-0000-0000-0000000000cf',
                                       p_format text default 'csv') returns jsonb language plpgsql as $$
declare
  s uuid := ('e5' || lpad(p_n, 6, '0') || '-0000-0000-0000-000000000000')::uuid;
  v_total bigint;
  v jsonb;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, (select b.organization_id from public.bank_account b where b.id = p_account), p_account, 'EUR', p_format,
          'r.' || p_format, encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into private.bank_import_stage (statement_id, line_no, section_no, dedup_key, direction, amount_minor, currency,
                                         booking_date, end_to_end_id, counterparty_iban, counterparty_name,
                                         remittance_text, bank_tx_code, kind, method, label_references)
  select s, l.ord, case when p_format = 'csv' then 0 else 1 end,
         coalesce(l.v ->> 'key', case when p_format = 'csv' then 'c:' else 't:' end || p_n || '-' || l.ord),
         coalesce(l.v ->> 'dir', 'credit'), (l.v ->> 'amount')::bigint, 'EUR', coalesce((l.v ->> 'day')::date, p_day),
         l.v ->> 'e2e', l.v ->> 'iban', l.v ->> 'name', l.v ->> 'text', l.v ->> 'code',
         coalesce(l.v ->> 'kind', case coalesce(l.v ->> 'dir', 'credit') when 'credit' then 'debtor_credit'
                                                                       else 'other_debit' end),
         'sct',
         case when l.v ? 'refs' then array(select e.x from jsonb_array_elements_text(l.v -> 'refs') with ordinality e (x, o)
                                           order by e.o)
              when l.v ->> 'ref' is not null then array[l.v ->> 'ref'] end
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  select coalesce(sum(case coalesce(l.v ->> 'dir', 'credit') when 'credit' then 1 else -1 end * (l.v ->> 'amount')::bigint),
                  0)
  into v_total from jsonb_array_elements(p_lines) l (v);
  begin
    v := private.ingest_statement(s, case when p_format = 'csv'
      then jsonb_build_object('format', 'csv', 'line_count', jsonb_array_length(p_lines), 'skipped_not_booked', 0,
                              'sections', '[]'::jsonb)
      else jsonb_build_object('format', 'camt053', 'version', '08', 'line_count', jsonb_array_length(p_lines),
                              'skipped_not_booked', 0,
                              'sections', jsonb_build_array(jsonb_build_object(
                                'stmt_id', 'S' || p_n, 'seq', 1, 'from_date', p_day, 'to_date', p_day,
                                'opening_minor', '0', 'closing_minor', v_total::text))) end);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  return v;
end $$;
-- line k of statement n (imported by pg_temp.imp)
create or replace function pg_temp.li(p_n text, p_k integer) returns uuid language sql as $$
  select t.id from public.bank_transaction t
  where t.statement_id = ('e5' || lpad(p_n, 6, '0') || '-0000-0000-0000-000000000000')::uuid and t.line_no = p_k $$;
-- statement n's lines as [line, kind, a candidate kept, has a payment]
create or replace function pg_temp.kinds(p_n text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(t.line_no, t.kind, t.reference_from_label is not null,
                                              exists (select 1 from public.payment p where p.bank_transaction_id = t.id))
                            order by t.line_no), '[]')
  from public.bank_transaction t
  where t.statement_id = ('e5' || lpad(p_n, 6, '0') || '-0000-0000-0000-000000000000')::uuid $$;
-- statement n's cash_in, booked to 5120 (the sum of its entries' client_money_cash lines)
create or replace function pg_temp.cash_in(p_n text) returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_entry e
  join public.ledger_posting p on p.entry_id = e.id
  join public.ledger_account la on la.id = p.ledger_account_id and la.book = 'client_money_cash'
  where e.organization_id = '00000000-0000-0000-0000-0000000000aa' and e.entry_type = 'cash_in'
    and e.source_id = ('e5' || lpad(p_n, 6, '0') || '-0000-0000-0000-000000000000')::text $$;
-- the n-th business day before today (n = 0: today when it is one)
create or replace function pg_temp.bd_before(p_n integer) returns date language sql as $$
  select c.day from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day <= private.paris_today()
  order by c.day desc offset p_n limit 1 $$;
-- our transfers the labels cite: a booked run's payout of Martin (RMT), a sweep of the dedicated account (SWP…47B1), a
-- top-up ordered to it (TOP), a sweep of the other servicer's dedicated account (SWP…47B2: another account's), and a look-alike
-- (no transfer of ours); their ids in t (run, rmt_t, top_t)
create or replace function pg_temp.refs() returns jsonb language plpgsql as $$
declare v_run uuid; v_top uuid;
begin
  v_run := pg_temp.remitted('a1', 'b1', 100000, 'b71');
  insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id, creditor_bank_account_id, currency,
                                    amount_minor, payee_name, payee_iban, end_to_end_id, remittance_info,
                                    requested_execution_date)
  values ('00000000-0000-0000-0000-0000000000aa', 'sweep', '80000000-0000-0000-0000-0000000000cf',
          '80000000-0000-0000-0000-0000000000c0', 'EUR', 5000, 'Collectoo SAS', 'FR7610107001011234567890129',
          'SWP0000000047B1', 'VIREMENT AU COMPTE PROPRE (test)', private.paris_today()),
         ('00000000-0000-0000-0000-0000000000bb', 'sweep', '80000000-0000-0000-0000-0000000000be',
          '80000000-0000-0000-0000-0000000000b0', 'EUR', 6000, 'Autre cabinet SAS', 'FR2730001007940000000047202',
          'SWP0000000047B2', 'VIREMENT AU COMPTE PROPRE (test)', private.paris_today());
  v_top := pg_temp.req_top('k047b-top-1', 4700);
  insert into t values ('lr_run', v_run), ('lr_rmt', pg_temp.rtransfer(v_run)), ('lr_top', v_top)
  on conflict (k) do update set v = excluded.v;
  return jsonb_build_object('rmt', pg_temp.e2e(pg_temp.rtransfer(v_run)), 'swp', 'SWP0000000047B1',
                            'top', pg_temp.e2e(v_top), 'other', 'SWP0000000047B2', 'look', 'RMT0000000047BF');
end $$;
-- a label citing a reference, as a debtor or a client words it
create or replace function pg_temp.lbl(p_ref text) returns text language sql as $$
  select 'VIR SEPA RECU /DE DUPONT JEAN /MOTIF REMBOURSEMENT ' || coalesce(p_ref, '') || ' MERCI' $$;
-- the unregistered IBAN of a debtor (neither ours nor a client's payout account)
create or replace function pg_temp.dib() returns text language sql as $$ select 'FR7630001007941234567890185' $$;
-- the funds pass's candidates of the servicer: [line, line kind, role, transfer] of the label_reference lines
create or replace function pg_temp.cands() returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(c.line_id, c.line_kind, c.role, c.transfer_id) order by c.booking_date,
                                                                                                  c.line_id), '[]')
  from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 2000) c
  where c.line_kind = 'label_reference' $$;
-- whether the funds pass's candidates return a line
create or replace function pg_temp.cand_has(p_line uuid) returns boolean language sql as $$
  select exists (select 1 from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 2000) c
                 where c.line_id = p_line) $$;
-- « Débits et retours » as ops (01): a tab's rows of kind label_reference (as the page reads them)
create or replace function pg_temp.queue_lr(p_tab text default 'a-classer', p_user text default '01') returns jsonb
language sql as $$
  select pg_temp.read_as(p_user, format($q$
    select coalesce(jsonb_agg(jsonb_build_array(q.bank_transaction_id, q.kind, q.review_reason, q.reference_from_label,
                                                q.label_transfer - 'transfer_id', q.bookable_as, q.held_kind)
                              order by q.booking_date, q.bank_transaction_id), '[]')
    from public.debit_queue(%L, 0, 100) q
    where q.kind = 'label_reference' or q.held_kind = 'label_reference'$q$, p_tab)) $$;
-- « Lier » / « Classer » by ops (01) on a line, every kind with the shape link_debit takes: its refusal's code, or ok
create or replace function pg_temp.links(p_line uuid, p_payment uuid) returns jsonb language sql as $$
  select jsonb_object_agg(k.kind, pg_temp.why_of(pg_temp.read_as('01', format(
           'select public.link_debit(%L, %L, %L, %L, %L, %L, %L)', 'lnk-047b-' || k.kind || '-' || p_line, p_line,
           k.kind, case when k.kind in ('return', 'loss') then p_payment end,
           case when k.kind in ('refund', 'refund_returned') then 'f1000000-0000-0000-0000-0000000000ff'::uuid end,
           case when k.kind in ('return', 'loss') then '0' end, 'motif de test'))))
  from unnest(array['explained', 'fee', 'own_credit', 'return', 'loss', 'refund', 'refund_returned']) k (kind) $$;
-- a raw « explained » link written on a line (service role's path, no command): 'ok' or the SQLSTATE and message
create or replace function pg_temp.raw_explained(p_line uuid) returns text language sql as $$
  select pg_temp.try_sql(format($q$insert into public.bank_debit_link (bank_transaction_id, organization_id,
      bank_account_id, kind, method, reason, decided_by)
    select x.id, x.organization_id, x.bank_account_id, 'explained', 'ops', 'expliqué à la main (test)',
           '10000000-0000-0000-0000-000000000001'
    from public.bank_transaction x where x.id = %L$q$, p_line)) $$;
-- a raw booking row the job's re-check is handed on a line (the funds pass's rows, posted strict): its refusal, or ok
create or replace function pg_temp.raw_book(p_line uuid, p_kind text, p_transfer uuid default null,
                                            p_amount bigint default null) returns text language plpgsql as $$
declare v text;
begin
  begin
    perform private.bank_booking_begin();
    insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, amount_minor, method, decided_by,
                                       reason)
    values (1, p_line, p_kind, p_transfer, p_amount, 'ops', '10000000-0000-0000-0000-000000000001', 'motif de test');
    perform private.post_bank_bookings('00000000-0000-0000-0000-0000000000aa', true);
    raise exception 'raw booking rolled back' using errcode = 'TR006';
  exception when sqlstate 'TR006' then
    v := 'ok';
  when others then
    v := coalesce(substring(sqlerrm from 'refused: ([a-z_0-9]+)'), sqlerrm);
  end;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
-- the label_reference_waiting rows of a check run of the advance checks as of p_today:
-- [subject type, severity, amount, oldest_days, p0, details' reference and run number, its candidate is the RMT, details'
-- oldest_days, subject id (review round 1, TUI-4: « Contrôles » leads to the line by it)]
create or replace function pg_temp.waiting(p_today date default null) returns jsonb language plpgsql as $$
declare v uuid := pg_temp.adv_run(p_today);
begin
  return coalesce((select jsonb_agg(jsonb_build_array(c.subject_type, c.severity, c.amount_minor, c.oldest_days,
                                                      c.details -> 'p0', c.details ->> 'reference_from_label',
                                                      c.details ->> 'run_number',
                                                      (c.details ->> 'candidate_transfer_id')::uuid = pg_temp.v('lr_rmt'),
                                                      c.details -> 'oldest_days', c.subject_id)
                                    order by c.amount_minor)
                   from public.payment_check_result c where c.run_id = v and c.code = 'label_reference_waiting'), '[]');
end $$;




-- 047c's own helpers --------------------------------------------------------------------------------------------------
-- whether a line is listed label_reference_waiting by a check run of the advance checks as of ten days on (every line
-- imported today is then past the bound of two business days)
create or replace function pg_temp.waits(p_line uuid) returns boolean language plpgsql as $$
declare v uuid := pg_temp.adv_run(private.paris_today() + 10);
begin
  return exists (select 1 from public.payment_check_result c
                 where c.run_id = v and c.code = 'label_reference_waiting' and c.subject_id = p_line);
end $$;
-- « Paiement d'un débiteur » (public.release_own_credit) as p_user (ops 01 at aal2): its result, or {error}
create or replace function pg_temp.rel(p_key text, p_line uuid, p_user text default '01', p_aal text default 'aal2')
returns jsonb language sql as $$
  select pg_temp.read_as(p_user, format('select public.release_own_credit(%L, %L, %L)', 'rel-047c-' || p_key, p_line,
                                        'Le débiteur cite notre référence dans son virement (test)'), p_aal) $$;
-- « Règlement du client » (public.book_client_payment_line) on a line for client c (none when null; 'aa' the servicer
-- itself) as p_user: the open the sheet showed is the preview's for that client (public.client_payment_line); its
-- result, or {error}
create or replace function pg_temp.clr(p_key text, p_line uuid, p_c text, p_user text default '01',
                                       p_aal text default 'aal2') returns jsonb language plpgsql as $$
declare v_client uuid := case when p_c is not null then pg_temp.c(p_c) end; v_exp text;
begin
  v_exp := coalesce(pg_temp.read_as('01', format('select public.client_payment_line(%L, null, null, %L)', p_line,
                                                 v_client)) #>> '{preview,open_minor}', '0');
  return pg_temp.read_as(p_user, format(
    'select public.book_client_payment_line(%L, %L, null, null, null, %L, %L, %L)', 'clr-047c-' || p_key, p_line,
    v_exp, 'Le client rembourse en citant notre référence (test)', v_client), p_aal);
end $$;
-- the preview of « Règlement du client » for client c: [its client is c, its refusal]
create or replace function pg_temp.clp(p_line uuid, p_c text) returns jsonb language sql as $$
  select jsonb_build_array(x ->> 'client_id' = pg_temp.c(p_c)::text, x ->> 'refusal')
  from (select pg_temp.read_as('01', format('select public.client_payment_line(%L, null, null, %L)', p_line,
                                            case when p_c is not null then pg_temp.c(p_c) end)) x) z $$;
-- « Comptabiliser… » as ops: its result, or {error}
create or replace function pg_temp.bkj(p_line uuid, p_parts jsonb, p_key text) returns jsonb language plpgsql as $$
begin
  return pg_temp.bk(p_line, p_parts, p_key);
exception when others then
  reset role;
  return jsonb_build_object('error', sqlerrm);
end $$;
-- a command's result in a subtransaction always rolled back: its refusal's code, 'ok', or its error
create or replace function pg_temp.undone(p_sql text) returns text language plpgsql as $$
declare v jsonb; c text;
begin
  begin
    execute p_sql into v;
    c := pg_temp.why_of(v);
    raise exception 'undone' using errcode = 'TR007';
  exception when sqlstate 'TR007' then
    null;
  end;
  reset role;
  return c;
end $$;
-- the four exits tried again on a line (each rolled back): the return of p_parts, the client c's payment, a debtor's
-- payment, the top-up p_top — their refusals
create or replace function pg_temp.exits(p_line uuid, p_parts jsonb, p_c text, p_top uuid) returns jsonb
language sql as $$
  select jsonb_build_object(
    'return', pg_temp.undone(format('select pg_temp.bkj(%L, %L, %L)', p_line, p_parts, 'again-' || p_line)),
    'client', pg_temp.undone(format('select pg_temp.clr(%L, %L, %L)', 'again-' || p_line, p_line, p_c)),
    'debtor', pg_temp.undone(format('select pg_temp.rel(%L, %L)', 'again-' || p_line, p_line)),
    'top_up', pg_temp.undone(format('select pg_temp.pick(%L, %L, %L)', 'again-' || p_line, p_line, p_top))) $$;
-- a line's facts after an exit: [its review, a candidate of the debit job, listed label_reference_waiting]
create or replace function pg_temp.gone(p_line uuid) returns jsonb language sql as $$
  select jsonb_build_array(pg_temp.review(p_line), pg_temp.cand_has(p_line), pg_temp.waits(p_line)) $$;
-- the label of our own top-up's credit as the bank prints it (its motif, the TOP id)
create or replace function pg_temp.toplbl(p_ref text) returns text language sql as $$
  select 'VIR SEPA RECU /DE COLLECTOO SAS /MOTIF APPROVISIONNEMENT COMPTE DEDIE ' || p_ref $$;
-- a raw booking of kind p_kind (fee, top_up, loss) on a line, its entry posted first as the funds pass posts it (the
-- line's amount, source the line, dated the line's day), in a rolled-back subtransaction (service role's path, no
-- command): 'ok' or the SQLSTATE
create or replace function pg_temp.raw_fund(p_line uuid, p_kind text) returns text language plpgsql as $$
declare t public.bank_transaction; v text; e uuid; k text := 'raw-047c-' || p_kind || ':' || p_line;
begin
  select * into t from public.bank_transaction where id = p_line;
  begin
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                    source_id, reason)
    values (1, t.organization_id, case p_kind when 'fee' then 'bank_fee' when 'top_up' then 'servicer_top_up'
                                              else 'servicer_loss' end,
            t.booking_date, k, 'bank_transaction', t.id::text, 'Écriture brute (test)');
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
    select 1, x.n, x.book, x.sign * t.amount_minor, 'EUR',
           case x.book when 'client_money_cash' then t.bank_account_id
                       when 'own_cash' then '80000000-0000-0000-0000-0000000000c0'::uuid end
    from (values ('fee', 1, 'due_to_servicer', 1), ('fee', 2, 'client_money_cash', -1),
                 ('fee', 3, 'bank_fees', 1), ('fee', 4, 'due_from_client_funds', -1),
                 ('top_up', 1, 'client_money_cash', 1), ('top_up', 2, 'due_to_servicer', -1),
                 ('top_up', 3, 'due_from_client_funds', 1), ('top_up', 4, 'own_cash', -1),
                 ('loss', 1, 'due_to_servicer', 1), ('loss', 2, 'client_money_cash', -1),
                 ('loss', 3, 'servicer_losses', 1), ('loss', 4, 'due_from_client_funds', -1)) x (kind, n, book, sign)
    where x.kind = p_kind;
    perform private.ledger_post_set();
    e := pg_temp.ek(k);
    insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, entry_id,
                                          amount_minor, method, reason, decided_by)
    values (t.id, 1, t.organization_id, t.bank_account_id, p_kind, e, t.amount_minor, 'ops', 'motif de test',
            '10000000-0000-0000-0000-000000000001');
    raise exception 'raw rolled back' using errcode = 'TR008';
  exception when sqlstate 'TR008' then
    v := 'ok';
  when others then
    get stacked diagnostics v = returned_sqlstate;
  end;
  return v;
end $$;
-- a raw top-up booking naming the top-up p_transfer on a line (its servicer_top_up entry sourced to that top-up, as
-- book_top_up_credit posts it; rolled back): 'ok' or the SQLSTATE
create or replace function pg_temp.raw_top(p_line uuid, p_transfer uuid) returns text language plpgsql as $$
declare t public.bank_transaction; v text; e uuid; k text := 'raw-047c-top:' || p_line;
begin
  select * into t from public.bank_transaction where id = p_line;
  begin
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                    source_id, reason)
    values (1, t.organization_id, 'servicer_top_up', t.booking_date, k, 'bank_transfer', p_transfer::text,
            'Écriture brute (test)');
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
    select 1, x.n, x.book, x.sign * t.amount_minor, 'EUR',
           case x.book when 'client_money_cash' then t.bank_account_id
                       when 'own_cash' then '80000000-0000-0000-0000-0000000000c0'::uuid end
    from (values (1, 'client_money_cash', 1), (2, 'due_to_servicer', -1), (3, 'due_from_client_funds', 1),
                 (4, 'own_cash', -1)) x (n, book, sign);
    perform private.ledger_post_set();
    e := pg_temp.ek(k);
    insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, entry_id,
                                          amount_minor, method, reason, decided_by, transfer_id)
    values (t.id, 1, t.organization_id, t.bank_account_id, 'top_up', e, t.amount_minor, 'ops', 'motif de test',
            '10000000-0000-0000-0000-000000000001', p_transfer);
    raise exception 'raw rolled back' using errcode = 'TR008';
  exception when sqlstate 'TR008' then
    v := 'ok';
  when others then
    get stacked diagnostics v = returned_sqlstate;
  end;
  return v;
end $$;
-- a raw return booking of kind p_kind naming p_transfer (or none) on a line: the entry p_reverses reversed at the
-- line's day, then the booking (rolled back): 'ok' or the SQLSTATE
create or replace function pg_temp.raw_ret(p_line uuid, p_kind text, p_transfer uuid, p_reverses uuid) returns text
language plpgsql as $$
declare t public.bank_transaction; v text; e uuid;
begin
  select * into t from public.bank_transaction where id = p_line;
  begin
    select r.entry_id into e from private.ledger_reverse(p_reverses, 'raw-047c-ret:' || t.id || ':' || p_kind,
                                                         'Retour (test)', t.booking_date) r;
    insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                          entry_id, amount_minor, method, reason, decided_by)
    values (t.id, 1, t.organization_id, t.bank_account_id, p_kind, p_transfer, e, t.amount_minor, 'ops',
            'motif de test', '10000000-0000-0000-0000-000000000001');
    raise exception 'raw rolled back' using errcode = 'TR008';
  exception when sqlstate 'TR008' then
    v := 'ok';
  when others then
    get stacked diagnostics v = returned_sqlstate;
  end;
  return v;
end $$;
-- a raw client payment booking of client c on a line: its entry posted as « Règlement du client » posts it
-- (private.client_payment_post: the default order), then the booking (rolled back): 'ok' or the SQLSTATE
create or replace function pg_temp.raw_cpay(p_line uuid, p_c text) returns text language plpgsql as $$
declare t public.bank_transaction; v text; v_docs jsonb; r jsonb;
begin
  select * into t from public.bank_transaction where id = p_line;
  begin
    v_docs := private.client_payment_docs(pg_temp.c(p_c), 'EUR', t.booking_date);
    r := private.client_payment_post(
           'client_payment_dedicated', t.organization_id, pg_temp.c(p_c), 'EUR', t.amount_minor, t.booking_date,
           private.client_payment_rows(private.client_payment_free(v_docs), t.amount_minor, null,
                                       private.client_payment_recoveries(pg_temp.c(p_c), 'EUR', null, t.booking_date),
                                       false, t.booking_date),
           v_docs, 'cpayd:' || t.id, 'bank_transaction', t.id::text, 'Règlement du client (test)', t.bank_account_id);
    insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, entry_id,
                                          amount_minor, method, reason, decided_by)
    values (t.id, 1, t.organization_id, t.bank_account_id, 'client_payment', (r ->> 'entry_id')::uuid, t.amount_minor,
            'ops', 'motif de test', '10000000-0000-0000-0000-000000000001');
    raise exception 'raw rolled back' using errcode = 'TR008';
  exception when sqlstate 'TR008' then
    v := 'ok';
  when others then
    get stacked diagnostics v = returned_sqlstate;
  end;
  return v;
end $$;
-- a raw release row on a line (no command), with or without its payment (private.book_credit_payment), or the payment
-- alone (rolled back): 'ok' or the SQLSTATE
create or replace function pg_temp.raw_release(p_line uuid, p_release boolean, p_payment boolean) returns text
language plpgsql as $$
declare v text;
begin
  begin
    if p_release then
      insert into public.bank_own_credit_release (bank_transaction_id, organization_id, bank_account_id, reason,
                                                  decided_by)
      select t.id, t.organization_id, t.bank_account_id, 'Libéré à la main (test)', '10000000-0000-0000-0000-000000000001'
      from public.bank_transaction t where t.id = p_line;
    end if;
    if p_payment then
      perform private.book_credit_payment(p_line, 'other', 'Payeur (test)', null, 'no_match');
    end if;
    raise exception 'raw rolled back' using errcode = 'TR008';
  exception when sqlstate 'TR008' then
    v := 'ok';
  when others then
    get stacked diagnostics v = returned_sqlstate;
  end;
  return v;
end $$;
-- a line's payment: [payer name, payer IBAN, method, status, review reason, amount], and its cash_in (the line's own
-- entry, keyed by its line)
create or replace function pg_temp.paid(p_line uuid) returns jsonb language sql as $$
  select jsonb_build_array(p.payer_name, p.payer_iban, p.method, p.status, p.review_reason, p.amount_minor,
                           (select sum(q.amount_minor) from public.ledger_entry e
                            join public.ledger_posting q on q.entry_id = e.id
                            join public.ledger_account la on la.id = q.ledger_account_id and la.book = 'client_money_cash'
                            where e.entry_type = 'cash_in' and e.idempotency_key like '%:' || p_line),
                           exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = p_line))
  from public.payment p where p.bank_transaction_id = p_line $$;
-- a line's booking's entry: [its type, its client is c]
create or replace function pg_temp.entry_of(p_line uuid, p_c text) returns jsonb language sql as $$
  select jsonb_build_array(e.entry_type, e.client_organization_id = pg_temp.c(p_c))
  from public.bank_line_booking b join public.ledger_entry e on e.id = b.entry_id where b.bank_transaction_id = p_line $$;
-- the job's reviews of the held lines, as the worker's decide_line writes them (pure rules' rows, then
-- private.apply_bank_bookings: no booking, one review label_reference each)
create or replace function pg_temp.job_reviews() returns jsonb language sql as $$
  select pg_temp.book('[]'::jsonb, coalesce((select jsonb_agg(jsonb_build_object('line', c.line_id,
                                                                                 'reason', 'label_reference'))
                                             from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa',
                                                                                  null, null, 2000) c
                                             where c.line_kind = 'label_reference'), '[]')) $$;
grant execute on all functions in schema pg_temp to authenticated;


-- j. The job reaches it ([check 2] gap 1 (3)) ---------------------------------------------------------------------------
-- private.bank_booking_candidates returns each label_reference line — imported so (f1-1, f1-2, f1-3; f2-1) or held and
grant execute on all functions in schema pg_temp to authenticated;


-- a. Exit (a): the return of exactly that transfer (§7.3 [check 2] gap 1 (1); plan §7.5 047c) ---------------------------
-- A CSV of the dedicated account, imported today: 1 a debtor's IBAN citing Martin's booked payout (RMT, 1 000,00 €) at
-- exactly its amount; 2 the same at 999,99 €; 3 our top-up (TOP) cited from a debtor's IBAN. Held and reviewed by the
-- job, listed label_reference_waiting. « Comptabiliser… »'s options read class L and propose the payout's return of
-- exactly its amount; the line short of it, a fee part, another of our booked payouts (Lilas's) and a TOP candidate are
-- refused (label_reference_amount, label_reference_transfer; the TOP has no return exit). Booked: payout_returned, the
-- payout returned, the run's payout account returned, its +N re-queued, 5120 up by the line; the review gone, no
-- candidate of the debit job, no label_reference_waiting at the next check; every other exit refused.
create or replace function pg_temp.a1() returns jsonb language plpgsql as $$
declare r jsonb := pg_temp.refs(); x uuid := pg_temp.v('lr_rmt'); d date := private.paris_today(); v2 uuid; x2 uuid;
        l1 uuid; l2 uuid; l3 uuid; v jsonb; c0 bigint;
begin
  v2 := pg_temp.remitted('a2', 'b2', 100000, 'b72');
  x2 := pg_temp.rtransfer(v2);
  perform pg_temp.imp('c1', d, jsonb_build_array(
    jsonb_build_object('amount', 100000, 'iban', pg_temp.dib(), 'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt'),
    jsonb_build_object('amount', 99999, 'iban', pg_temp.dib(), 'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt'),
    jsonb_build_object('amount', 4700, 'iban', pg_temp.dib(), 'text', pg_temp.lbl(r ->> 'top'), 'ref', r ->> 'top')));
  l1 := pg_temp.li('c1', 1); l2 := pg_temp.li('c1', 2); l3 := pg_temp.li('c1', 3);
  perform pg_temp.job_reviews();
  v := jsonb_build_object(
    'kinds', pg_temp.kinds('c1'),
    'before', jsonb_build_array(pg_temp.review(l1), pg_temp.waits(l1), pg_temp.status(x)),
    'options', (select jsonb_build_array(o ->> 'class', o ->> 'refusal', o -> 'proposals' -> 0 ->> 'action',
                                         o -> 'proposals' -> 0 -> 'request'
                                           = jsonb_build_array(pg_temp.pt('payout_returned', x, 100000)))
                from (select pg_temp.op(l1) o) z),
    'smaller_options', pg_temp.op(l2) ->> 'refusal',
    'smaller', pg_temp.bkx(l2, jsonb_build_array(pg_temp.pt('payout_returned', x, 99999)), 'k047c-a1-s'),
    'fee_part', pg_temp.bkx(l2, jsonb_build_array(pg_temp.pt('payout_returned', x, 100000),
                                                  pg_temp.pt('fee', null, 1)), 'k047c-a1-f'),
    'other_transfer', pg_temp.bkx(l1, jsonb_build_array(pg_temp.pt('payout_returned', x2, 100000)), 'k047c-a1-o'),
    'top_options', pg_temp.op(l3) ->> 'refusal',
    'top', pg_temp.bkx(l3, jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('lr_top'), 4700)), 'k047c-a1-t'));
  c0 := pg_temp.cash();
  v := v || jsonb_build_object('book', pg_temp.bkx(l1, pg_temp.prop(l1), 'k047c-a1-b'));
  return v || jsonb_build_object(
    'after', jsonb_build_array(pg_temp.bookings(l1), pg_temp.status(x), pg_temp.payout_account('a1'),
                               pg_temp.returned_items('a1'), pg_temp.cash() - c0, pg_temp.status(x2)),
    'gone', pg_temp.gone(l1),
    'again', pg_temp.exits(l1, jsonb_build_array(pg_temp.pt('payout_returned', x, 100000)), 'a1', pg_temp.v('lr_top')),
    'others', jsonb_build_array(pg_temp.review(l2), pg_temp.bookings(l2), pg_temp.review(l3), pg_temp.bookings(l3)));
end $$;
create temporary table a1 (v jsonb) on commit drop;
insert into a1 select pg_temp.iso('a1');
select is((select v from a1),
  '{"kinds": [[1, "label_reference", true, false], [2, "label_reference", true, false],
              [3, "label_reference", true, false]],
    "before": ["label_reference", true, "booked"],
    "options": ["L", null, "returned", true],
    "smaller_options": "label_reference_amount", "smaller": "label_reference_amount",
    "fee_part": "label_reference_amount", "other_transfer": "label_reference_transfer",
    "top_options": "label_reference_transfer", "top": "label_reference_transfer",
    "book": "ok",
    "after": [["1 payout_returned 100000"], "returned", "returned", 1, 100000, "booked"],
    "gone": [null, false, false],
    "again": {"return": "already_booked", "client": "line_booked", "debtor": "already_booked",
              "top_up": "not_an_own_credit"},
    "others": ["label_reference", [], "label_reference", []]}'::jsonb,
  'a1: exit (a) — « Comptabiliser… » (class L) books the return of exactly the payout the label cites '
  '(payout_returned; the payout and the run''s payout account returned, +N re-queued, 5120 up by the line); a smaller '
  'amount or a fee part is label_reference_amount, another of our payouts and a TOP candidate label_reference_transfer; '
  'after it the review, the job''s candidate and label_reference_waiting are gone and every other exit is refused');
select is(pg_temp.iso('a1', true), (select v from a1), 'a1 (switch on): the same');

-- a2. Exit (a) of our sweep (SWP): Cyprès's share swept by a file of the dedicated account, debited yesterday and
-- booked by the job; a CSV credit citing it at exactly its amount → sweep_returned, the sweep
-- returned; the review and the alert gone; every other exit refused
create or replace function pg_temp.a2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); x uuid; sw public.bank_transfer; l uuid; v jsonb;
begin
  -- Cyprès's run, its commission set off (the servicer's share 180,00 €), handed out and debited two days ago: the share
  -- on 4679; the next file sweeps it (SWP…), handed out and debited yesterday, booked by the job
  perform pg_temp.queued('a3', 'c7', 100000, 'k047c-sw');
  perform pg_temp.handed_out('fsw1', 'gen-k047c-sw1');
  x := pg_temp.v('tr-k047c-sw');
  perform pg_temp.exec_back(x, d - 2);
  perform pg_temp.stmt2('c20', d - 2, jsonb_build_array(jsonb_build_object('amount', pg_temp.amt(x),
                                                                           'e2e', pg_temp.e2e(x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c20', 1), 'payout', x)));
  perform pg_temp.handed_out('fsw2', 'gen-k047c-sw2');
  sw := pg_temp.sweep(pg_temp.v('fsw2'));
  perform pg_temp.exec_back(sw.id, d - 1);
  perform pg_temp.stmt2('c21', d - 1, jsonb_build_array(jsonb_build_object('amount', sw.amount_minor,
                                                                           'e2e', sw.end_to_end_id)));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('c21', 1), 'sweep', sw.id)));
  perform pg_temp.imp('c2', d, jsonb_build_array(jsonb_build_object('amount', sw.amount_minor, 'iban', pg_temp.dib(),
    'text', pg_temp.lbl(sw.end_to_end_id), 'ref', sw.end_to_end_id)));
  l := pg_temp.li('c2', 1);
  perform pg_temp.job_reviews();
  v := jsonb_build_object(
    'before', jsonb_build_array(pg_temp.status(sw.id), (select t.kind from public.bank_transaction t where t.id = l),
                                pg_temp.review(l), pg_temp.waits(l)),
    'proposal', pg_temp.prop(l) = jsonb_build_array(pg_temp.pt('sweep_returned', sw.id, sw.amount_minor)),
    'book', pg_temp.bkx(l, pg_temp.prop(l), 'k047c-a2-b'));
  return v || jsonb_build_object(
    'after', jsonb_build_array(pg_temp.bookings(l) = array['1 sweep_returned ' || sw.amount_minor],
                               pg_temp.status(sw.id)),
    'gone', pg_temp.gone(l),
    'again', pg_temp.exits(l, jsonb_build_array(pg_temp.pt('sweep_returned', sw.id, sw.amount_minor)), 'a3', null));
end $$;
create temporary table a2 (v jsonb) on commit drop;
insert into a2 select pg_temp.iso('a2');
select is((select v from a2),
  '{"before": ["booked", "label_reference", "label_reference", true], "proposal": true, "book": "ok",
    "after": [true, "returned"], "gone": [null, false, false],
    "again": {"return": "already_booked", "client": "line_booked", "debtor": "already_booked",
              "top_up": "not_an_own_credit"}}'::jsonb,
  'a2: exit (a) of a sweep the label cites (SWP), at exactly its amount → sweep_returned, the sweep returned; the review '
  'and the alert gone, every other exit refused');
select is(pg_temp.iso('a2', true), (select v from a2), 'a2 (switch on): the same');

-- a3. Exit (a) on a held duplicate released as label_reference: two CSV exports holding the same credit citing
-- Martin's payout (same day, amount, direction and label, no bank id) — the second held; held, « Comptabiliser… » is
-- refused held_duplicate; released (« Libérer », its reading label_reference), it is the return of exactly that payout
-- (payout_returned); the first line's own return is then refused (already_returned: the payout came back once)
create or replace function pg_temp.a3() returns jsonb language plpgsql as $$
declare r jsonb := pg_temp.refs(); x uuid := pg_temp.v('lr_rmt'); d date := private.paris_today(); l1 uuid; l2 uuid;
        v jsonb;
begin
  perform pg_temp.imp('c3', d, jsonb_build_array(jsonb_build_object('amount', 100000, 'iban', pg_temp.dib(),
    'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt', 'key', 'h:c3-1#1')));
  perform pg_temp.imp('c4', d, jsonb_build_array(jsonb_build_object('amount', 100000, 'iban', pg_temp.dib(),
    'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt', 'key', 'h:c4-1#1')));
  l1 := pg_temp.li('c3', 1); l2 := pg_temp.li('c4', 1);
  v := jsonb_build_object(
    'kinds', jsonb_build_array((select t.kind from public.bank_transaction t where t.id = l1),
                               (select t.kind from public.bank_transaction t where t.id = l2),
                               (select h.kind from private.held_line_kind(l2) h)),
    'held', pg_temp.bkx(l2, jsonb_build_array(pg_temp.pt('payout_returned', x, 100000)), 'k047c-a3-h'));
  perform pg_temp.read_as('01', format('select public.resolve_duplicate(%L, %L, false, %L)', 'res-047c-a3', l2,
                                       'Deux opérations distinctes (test)'));
  perform pg_temp.job_reviews();
  v := v || jsonb_build_object(
    'released', (select q.released_kind from public.bank_duplicate_resolution q where q.bank_transaction_id = l2),
    'options', pg_temp.op(l2) ->> 'class',
    'book', pg_temp.bkx(l2, pg_temp.prop(l2), 'k047c-a3-b'));
  return v || jsonb_build_object(
    'after', jsonb_build_array(pg_temp.bookings(l2), pg_temp.status(x)),
    'gone', pg_temp.gone(l2),
    'first', pg_temp.bkx(l1, jsonb_build_array(pg_temp.pt('payout_returned', x, 100000)), 'k047c-a3-f'),
    'again', pg_temp.exits(l2, jsonb_build_array(pg_temp.pt('payout_returned', x, 100000)), 'a1', pg_temp.v('lr_top')));
end $$;
create temporary table a3 (v jsonb) on commit drop;
insert into a3 select pg_temp.iso('a3');
select is((select v from a3),
  '{"kinds": ["label_reference", "suspected_duplicate", "label_reference"], "held": "held_duplicate",
    "released": "label_reference", "options": "L", "book": "ok",
    "after": [["1 payout_returned 100000"], "returned"], "gone": [null, false, false],
    "first": "already_returned",
    "again": {"return": "already_booked", "client": "line_booked", "debtor": "already_booked",
              "top_up": "not_an_own_credit"}}'::jsonb,
  'a3: a held duplicate released as label_reference is the return of exactly the payout its label cites; held, it is '
  'refused held_duplicate; the other copy''s return is then already_returned');
select is(pg_temp.iso('a3', true), (select v from a3), 'a3 (switch on): the same');


-- v. The return counts ([check 2] gap 1 (4)): the chain's events read the booked line ---------------------------------
-- Martin's RV-1 debited (d − 5), its collection taken back (« Désimputer »: the cover A1, 7a); a CSV credit citing
-- RV-1's RMT at exactly its amount (d − 4), held. Before exit (a) the unbooked line never counts: the chain paid on the
-- execution date, the run paid, the collection paid, a repayment request of A1 accepted. After exit (a): the chain's
-- paid_on null and returned, the run not paid, the collection not paid (returned_via « run »: « revenu, à verser de
-- nouveau »), the request refused payout_not_received (the run named). Then RV-2 pays the re-queued +N (debited d − 3):
-- the collection paid on that date by RV-2, the request accepted
create or replace function pg_temp.v1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); v1 uuid; v2 uuid; x uuid; a public.client_advance; e uuid; l uuid; w jsonb;
        q jsonb;
begin
  v1 := pg_temp.remitted('a1', 'c1', 100000, 'bc1', d - 5, d - 6);
  x := pg_temp.rtransfer(v1);
  e := pg_temp.alloc('c1');
  perform pg_temp.unalloc('c1');
  a := pg_temp.adv_of(pg_temp.rev(e));
  perform pg_temp.imp('ad1', d - 4, jsonb_build_array(jsonb_build_object('amount', 100000, 'iban', pg_temp.dib(),
    'text', pg_temp.lbl(pg_temp.e2e(x)), 'ref', pg_temp.e2e(x))));
  l := pg_temp.li('ad1', 1);
  perform pg_temp.job_reviews();
  w := jsonb_build_object('before', jsonb_build_array(
    (select jsonb_build_array(p.paid_on = d - 5, p.returned) from private.remittance_chain_paid(x) p),
    private.remittance_run_paid_on(v1) = d - 5,
    (select jsonb_build_array(z.paid_on = d - 5, z.paid_how, z.returned_via) from private.entry_remitted(e) z),
    pg_temp.undone(format('select pg_temp.dra(%L, %L, array[%L]::uuid[])', 'k047c-v1-0', 'a1', a.id))));
  w := w || jsonb_build_object('book', pg_temp.bkx(l, pg_temp.prop(l), 'k047c-v1-b'));
  q := pg_temp.dra('k047c-v1-1', 'a1', array[a.id]);
  w := w || jsonb_build_object('after', jsonb_build_array(
    (select jsonb_build_array(p.paid_on, p.returned) from private.remittance_chain_paid(x) p),
    private.remittance_run_paid_on(v1),
    (select jsonb_build_array(z.paid_on, z.paid_how, z.returned_via) from private.entry_remitted(e) z),
    jsonb_build_array(pg_temp.why_not(q), q ->> 'detail' = pg_temp.rnum(v1) || ':run')));
  perform pg_temp.reconfirm('a1');
  v2 := pg_temp.request('a1', 'run-v2');
  perform pg_temp.prepare_plain(v2);
  perform pg_temp.approve_plain(v2, 'run-v2');
  perform pg_temp.debit(v2, 'bc2', d - 3);
  q := pg_temp.dra('k047c-v1-2', 'a1', array[a.id]);
  return w || jsonb_build_object('paid_again', jsonb_build_array(
    (select jsonb_build_array(z.paid_on = d - 3, z.paid_how, z.paid_run_number = pg_temp.rnum(v2), z.returned_via)
     from private.entry_remitted(e) z),
    pg_temp.why_not(q)));
end $$;
create temporary table v1 (v jsonb) on commit drop;
insert into v1 select pg_temp.iso('v1');
select is((select v from v1),
  '{"before": [[true, false], true, [true, "paid", null], "ok"], "book": "ok",
    "after": [[null, true], null, [null, null, "run"], ["payout_not_received", true]],
    "paid_again": [[true, "paid", true, "run"], "ok"]}'::jsonb,
  'v1: before exit (a) the held line never counts (paid on the execution date, a request accepted); booked, the return '
  'counts — the chain not paid and returned, the run not paid, the collection « revenu, à verser de nouveau », the '
  'request refused payout_not_received —; once RV-2 pays the re-queued +N, paid on its debit date and requestable');
select is(pg_temp.iso('v1', true), (select v from v1), 'v1 (switch on): the same');


-- b. Exit (b): a client's payment (§7.3 [check 2]; plan §7.4 « Règlement du client ») -----------------------------------
-- A CSV citing Martin's payout: 1 from a debtor's IBAN (no client's), 2 from Martin's confirmed payout IBAN, 3 from
-- Lilas's; and a client_transfer_in credit from Martin's IBAN citing nothing (a camt.053 line, 7c-1's case). Line 1
-- without the client → client_required (line 2 without it: Martin, its IBAN's client); the servicer itself named →
-- client_unknown; line 2 for Lilas, line 3 for Martin → client_mismatch;
-- the client_transfer_in line for Lilas → client_mismatch (null or the IBAN's client only). Line 1 for Martin → the
-- preview names Martin, booked: client_payment (client_payment_dedicated of Martin: nothing open, a credit owed back),
-- the review and the alert gone, every other exit refused; line 2 for Martin and the client_transfer_in line for Martin
-- (and with no client named) → booked as before
create or replace function pg_temp.b1() returns jsonb language plpgsql as $$
declare r jsonb := pg_temp.refs(); d date := private.paris_today(); l1 uuid; l2 uuid; l3 uuid; l4 uuid; l5 uuid; v jsonb;
begin
  perform pg_temp.imp('d1', d, jsonb_build_array(
    jsonb_build_object('amount', 30000, 'iban', pg_temp.dib(), 'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt'),
    jsonb_build_object('amount', 30001, 'iban', pg_temp.iban_of('a1'), 'kind', 'client_transfer_in',
                       'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt'),
    jsonb_build_object('amount', 30002, 'iban', pg_temp.iban_of('a2'), 'kind', 'client_transfer_in',
                       'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt')));
  l1 := pg_temp.li('d1', 1); l2 := pg_temp.li('d1', 2); l3 := pg_temp.li('d1', 3);
  l4 := pg_temp.ctin('d2', 30003, pg_temp.iban_of('a1'), 'VIREMENT MARTIN SAS');
  l5 := pg_temp.ctin('d3', 30004, pg_temp.iban_of('a1'), 'VIREMENT MARTIN SAS');
  perform pg_temp.job_reviews();
  v := jsonb_build_object(
    'kinds', pg_temp.kinds('d1'),
    'none', pg_temp.why_of(pg_temp.clr('b1-n', l1, null)),
    'none_preview', pg_temp.clp(l1, null),
    'unknown', pg_temp.why_of(pg_temp.clr('b1-u', l1, 'aa')),
    'mismatch_iban', pg_temp.why_of(pg_temp.clr('b1-m', l2, 'a2')),
    'mismatch_other', pg_temp.why_of(pg_temp.clr('b1-o', l3, 'a1')),
    'cti_other', pg_temp.why_of(pg_temp.clr('b1-c', l4, 'a2')),
    'preview', pg_temp.clp(l1, 'a1'),
    'book', pg_temp.why_of(pg_temp.clr('b1-b', l1, 'a1')));
  return v || jsonb_build_object(
    'after', jsonb_build_array(pg_temp.bookings(l1), pg_temp.entry_of(l1, 'a1'), pg_temp.ccs('a1')),
    'gone', pg_temp.gone(l1),
    'again', pg_temp.exits(l1, jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('lr_rmt'), 30000)), 'a1',
                           pg_temp.v('lr_top')),
    'own_iban', pg_temp.why_of(pg_temp.clr('b1-i', l2, null)),
    'own_iban_client', pg_temp.entry_of(l2, 'a1'),
    'cti_same', pg_temp.why_of(pg_temp.clr('b1-s', l4, 'a1')),
    'cti_none', pg_temp.why_of(pg_temp.clr('b1-z', l5, null)),
    'booked', jsonb_build_array(pg_temp.bookings(l2), pg_temp.bookings(l4), pg_temp.bookings(l5)));
end $$;
create temporary table b1 (v jsonb) on commit drop;
insert into b1 select pg_temp.iso('b1');
select is((select v from b1),
  '{"kinds": [[1, "label_reference", true, false], [2, "label_reference", true, false],
              [3, "label_reference", true, false]],
    "none": "client_required", "none_preview": [null, "client_required"], "unknown": "client_unknown",
    "mismatch_iban": "client_mismatch", "mismatch_other": "client_mismatch", "cti_other": "client_mismatch",
    "preview": [true, null], "book": "ok",
    "after": [["1 client_payment 30000"], ["client_payment_dedicated", true], [["overpayment", 30000, 30000]]],
    "gone": [null, false, false],
    "again": {"return": "already_booked", "client": "line_booked", "debtor": "already_booked",
              "top_up": "not_an_own_credit"},
    "own_iban": "ok", "own_iban_client": ["client_payment_dedicated", true], "cti_same": "ok", "cti_none": "ok",
    "booked": [["1 client_payment 30001"], ["1 client_payment 30003"], ["1 client_payment 30004"]]}'::jsonb,
  'b1: exit (b) — « Règlement du client » books a label_reference line as the payment of the client ops name '
  '(client_required without one, unless the line comes from a client''s confirmed payout IBAN: that client; '
  'client_unknown for a non-client; client_mismatch when the line comes from another client''s confirmed IBAN, and '
  'for a client_transfer_in line from another client); after it the review and the alert are gone and every other '
  'exit is refused; a client_transfer_in line books for its IBAN''s client as before');
select is(pg_temp.iso('b1', true), (select v from b1), 'b1 (switch on): the same');


-- c. Exit (c): a debtor's payment (§7.3 [check 2] gap 1 (2); plan §7.4 « Paiement d'un débiteur ») -----------------------
-- A CSV citing Martin's payout: 1 from a debtor's unregistered IBAN (name DUPONT JEAN), 2 from Martin's confirmed payout
-- IBAN. « Paiement d'un débiteur » on each: its release row and its payment (both statement guards admit them), its
-- cash_in on the line's day (5120 up by the line); the payer the debtor's name and IBAN (line 1), « Versement relayé par
-- le client » with no IBAN (line 2, a client's confirmed IBAN); unmatched, for ops to assign (no_match); the review and
-- the alert gone; every other exit refused
create or replace function pg_temp.c1() returns jsonb language plpgsql as $$
declare r jsonb := pg_temp.refs(); d date := private.paris_today(); l1 uuid; l2 uuid; c0 bigint; v jsonb;
begin
  perform pg_temp.imp('e1', d, jsonb_build_array(
    jsonb_build_object('amount', 20000, 'iban', pg_temp.dib(), 'name', 'DUPONT JEAN', 'text', pg_temp.lbl(r ->> 'rmt'),
                       'ref', r ->> 'rmt'),
    jsonb_build_object('amount', 20001, 'iban', pg_temp.iban_of('a1'), 'name', 'MARTIN SAS', 'kind', 'client_transfer_in',
                       'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt')));
  l1 := pg_temp.li('e1', 1); l2 := pg_temp.li('e1', 2);
  perform pg_temp.job_reviews();
  c0 := pg_temp.cash();
  v := jsonb_build_object(
    'release', jsonb_build_array(pg_temp.rel('c1-1', l1) - 'payment_id', pg_temp.rel('c1-2', l2) - 'payment_id'),
    'cash', pg_temp.cash() - c0,
    'paid', jsonb_build_array(pg_temp.paid(l1), pg_temp.paid(l2)));
  return v || jsonb_build_object(
    'gone', jsonb_build_array(pg_temp.gone(l1), pg_temp.gone(l2)),
    'again', pg_temp.exits(l1, jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('lr_rmt'), 20000)), 'a1',
                           pg_temp.v('lr_top')),
    'bookings', jsonb_build_array(pg_temp.bookings(l1), pg_temp.bookings(l2)));
end $$;
create temporary table c1 (v jsonb) on commit drop;
insert into c1 select pg_temp.iso('c1');
select is((select v from c1),
  '{"release": [{"status": "unmatched", "note": "Paiement d''un débiteur citant notre référence (vérifié par l''équipe)"},
                {"status": "unmatched", "note": "Paiement d''un débiteur citant notre référence (vérifié par l''équipe)"}],
    "cash": 40001,
    "paid": [["DUPONT JEAN", "FR7630001007941234567890185", "other", "unmatched", "no_match", 20000, 20000, true],
             ["Versement relayé par le client", null, "other", "unmatched", "no_match", 20001, 20001, true]],
    "gone": [[null, false, false], [null, false, false]],
    "again": {"return": "already_booked", "client": "line_booked", "debtor": "already_booked",
              "top_up": "not_an_own_credit"},
    "bookings": [[], []]}'::jsonb,
  'c1: exit (c) — « Paiement d''un débiteur » makes the line a payment to assign (its release row, the payment and its '
  'cash_in), its payer the line''s own name and IBAN, or « Versement relayé par le client » with no IBAN when it comes '
  'from a client''s confirmed IBAN, its result noting « Paiement d''un débiteur citant notre référence »; the review and '
  'the alert gone, every other exit refused');
select is(pg_temp.iso('c1', true), (select v from c1), 'c1 (switch on): the same');


-- d. The fourth exit (founder Q15's added question, default a; ADR-0014 « M2c-7e-2 » round 1, MB-3): our own top-up's
-- credit on a CSV export with no counterparty IBAN, its label our motif with the TOP id (held label_reference). « C'est
-- cet approvisionnement » (book_top_up_credit on the line, the TOP its label cites, at exactly its amount): booked as
-- servicer_top_up of that TOP, the TOP booked; refused when the line carries a counterparty IBAN (not_an_own_credit: an
-- own account's credit would be own_transfer_in), at another amount (amount_differs), for another TOP of the same amount
-- (label_reference_transfer); the review and the alert gone; every other exit refused
create or replace function pg_temp.d1() returns jsonb language plpgsql as $$
declare r jsonb := pg_temp.refs(); d date := private.paris_today(); top uuid := pg_temp.v('lr_top'); top2 uuid;
        l1 uuid; l2 uuid; l3 uuid; v jsonb;
begin
  top2 := pg_temp.req_top('k047c-top-2', 4700);
  perform pg_temp.imp('ab1', d, jsonb_build_array(
    jsonb_build_object('amount', 4700, 'text', pg_temp.toplbl(r ->> 'top'), 'ref', r ->> 'top'),
    jsonb_build_object('amount', 4700, 'iban', pg_temp.dib(), 'text', pg_temp.lbl(r ->> 'top'), 'ref', r ->> 'top'),
    jsonb_build_object('amount', 4701, 'text', pg_temp.toplbl(r ->> 'top'), 'ref', r ->> 'top')));
  l1 := pg_temp.li('ab1', 1); l2 := pg_temp.li('ab1', 2); l3 := pg_temp.li('ab1', 3);
  perform pg_temp.job_reviews();
  v := jsonb_build_object(
    'kinds', pg_temp.kinds('ab1'),
    'with_iban', pg_temp.why_of(pg_temp.pick('k047c-d1-i', l2, top)),
    'other_amount', pg_temp.why_of(pg_temp.pick('k047c-d1-a', l3, top)),
    'other_top', pg_temp.why_of(pg_temp.pick('k047c-d1-t', l1, top2)),
    'book', pg_temp.why_of(pg_temp.pick('k047c-d1-b', l1, top)));
  return v || jsonb_build_object(
    'after', jsonb_build_array(pg_temp.booked_as(l1, top), pg_temp.status(top), pg_temp.status(top2),
                               (select e.entry_type from public.bank_line_booking b
                                join public.ledger_entry e on e.id = b.entry_id where b.bank_transaction_id = l1)),
    'gone', pg_temp.gone(l1),
    'again', pg_temp.exits(l1, jsonb_build_array(pg_temp.pt('payout_returned', top, 4700)), 'a1', top),
    'others', jsonb_build_array(pg_temp.review(l2), pg_temp.review(l3)));
end $$;
create temporary table d1 (v jsonb) on commit drop;
insert into d1 select pg_temp.iso('d1');
select is((select v from d1),
  '{"kinds": [[1, "label_reference", true, false], [2, "label_reference", true, false],
              [3, "label_reference", true, false]],
    "with_iban": "not_an_own_credit", "other_amount": "amount_differs", "other_top": "label_reference_transfer",
    "book": "ok",
    "after": [[["top_up", true]], "booked", "ordered", "servicer_top_up"],
    "gone": [null, false, false],
    "again": {"return": "already_booked", "client": "line_booked", "debtor": "already_booked",
              "top_up": "line_booked"},
    "others": ["label_reference", "label_reference"]}'::jsonb,
  'd1: the fourth exit — « C''est cet approvisionnement » books a label_reference credit with no counterparty IBAN as '
  'the top-up its label cites, at exactly its amount (servicer_top_up, the TOP booked); refused with an IBAN, at '
  'another amount or for another TOP; the review and the alert gone, every other exit refused');
select is(pg_temp.iso('d1', true), (select v from d1), 'd1 (switch on): the same');


-- g. The guards still refuse ([check 2]; plan §7.5 047c): each a raw insert in a subtransaction (service role, the
-- entry posted to match), beside its control that the guard admits —
--   bank_line_booking_guard: a payout_returned on a label_reference line naming Lilas's payout, not the one its label
--   cites (control: naming that one); an unplanned_payout_returned with no transfer on such a line (control: on the
--   bank's return from Martin's IBAN); a fee, a top-up and a loss on such a line; the top-up its label cites, booked on
--   a line that gives a counterparty IBAN (the fourth exit's: control on the line with none); a client_payment on a
--   debtor_credit line (control: on the label_reference line);
--   bank_own_credit_release_guard: a release row on a debtor_credit line and on a debit (control: on the label_reference
--   line);
--   payment_insert_guard: a payment of a label_reference line with no release row (control: with it)
create or replace function pg_temp.g1() returns jsonb language plpgsql as $$
declare r jsonb := pg_temp.refs(); x uuid := pg_temp.v('lr_rmt'); d date := private.paris_today(); v2 uuid; x2 uuid;
        l uuid; u uuid; ret uuid; dc uuid; db uuid; ub uuid; tn uuid; ti uuid; top uuid := pg_temp.v('lr_top');
begin
  v2 := pg_temp.remitted('a2', 'b2', 100000, 'b72');
  x2 := pg_temp.rtransfer(v2);
  perform pg_temp.imp('ac1', d, jsonb_build_array(jsonb_build_object('amount', 100000, 'iban', pg_temp.dib(),
    'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt')));
  l := pg_temp.li('ac1', 1);
  -- an unplanned payout to Martin's IBAN with no transfer (S13, « Virement hors reversement »), booked yesterday by ops
  perform pg_temp.stmt2('ac2', d - 1, jsonb_build_array(jsonb_build_object('kind', 'other_debit', 'amount', 100000,
                                                                          'iban', pg_temp.iban_of('a1'))));
  u := pg_temp.l2('ac2', 1);
  perform pg_temp.bk(u, pg_temp.prop(u), 'k047c-g1-u');
  ub := (select b.entry_id from public.bank_line_booking b where b.bank_transaction_id = u);
  -- the bank's own return from Martin's IBAN (the control's line), a debtor_credit line with no payment, a debit
  perform pg_temp.stmt2('ac3', d, jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 100000, 'iban', pg_temp.iban_of('a1')),
    jsonb_build_object('dir', 'credit', 'kind', 'debtor_credit', 'amount', 100000, 'iban', pg_temp.dib()),
    jsonb_build_object('dir', 'debit', 'kind', 'other_debit', 'amount', 100000)));
  ret := pg_temp.l2('ac3', 1); dc := pg_temp.l2('ac3', 2); db := pg_temp.l2('ac3', 3);
  -- our top-up cited at its amount by a CSV credit with no counterparty IBAN, and by one with an IBAN
  perform pg_temp.imp('ac4', d, jsonb_build_array(
    jsonb_build_object('amount', 4700, 'text', pg_temp.toplbl(r ->> 'top'), 'ref', r ->> 'top'),
    jsonb_build_object('amount', 4700, 'iban', pg_temp.dib(), 'text', pg_temp.toplbl(r ->> 'top'), 'ref', r ->> 'top')));
  tn := pg_temp.li('ac4', 1); ti := pg_temp.li('ac4', 2);
  return jsonb_build_object(
    'booking', jsonb_build_object(
      'other_transfer', pg_temp.raw_ret(l, 'payout_returned', x2,
                                        (select y.entry_id from public.bank_transfer y where y.id = x2)),
      'cited_transfer', pg_temp.raw_ret(l, 'payout_returned', x,
                                        (select y.entry_id from public.bank_transfer y where y.id = x)),
      'unplanned_no_transfer', pg_temp.raw_ret(l, 'unplanned_payout_returned', null, ub),
      'unplanned_control', pg_temp.raw_ret(ret, 'unplanned_payout_returned', null, ub),
      'fee', pg_temp.raw_fund(l, 'fee'), 'top_up', pg_temp.raw_fund(l, 'top_up'), 'loss', pg_temp.raw_fund(l, 'loss'),
      'cited_top_up_with_iban', pg_temp.raw_top(ti, top), 'cited_top_up_control', pg_temp.raw_top(tn, top),
      'client_payment_debtor_credit', pg_temp.raw_cpay(dc, 'a1'),
      'client_payment_control', pg_temp.raw_cpay(l, 'a1')),
    'release', jsonb_build_object(
      'debtor_credit', pg_temp.raw_release(dc, true, false), 'debit', pg_temp.raw_release(db, true, false),
      'control', pg_temp.raw_release(l, true, false)),
    'payment', jsonb_build_object(
      'without_release', pg_temp.raw_release(l, false, true), 'with_release', pg_temp.raw_release(l, true, true)));
end $$;
create temporary table g1 (v jsonb) on commit drop;
insert into g1 select pg_temp.iso('g1');
select is((select v from g1),
  '{"booking": {"other_transfer": "23514", "cited_transfer": "ok", "unplanned_no_transfer": "23514",
                "unplanned_control": "ok", "fee": "23514", "top_up": "23514", "loss": "23514",
                "cited_top_up_with_iban": "23514", "cited_top_up_control": "ok",
                "client_payment_debtor_credit": "23514", "client_payment_control": "ok"},
    "release": {"debtor_credit": "23514", "debit": "23514", "control": "ok"},
    "payment": {"without_release": "23514", "with_release": "ok"}}'::jsonb,
  'g1: the guards still refuse what no exit books — a return of another transfer, or of no transfer, on a '
  'label_reference line; a fee, a top-up or a loss on it; the top-up its label cites on a line giving an IBAN; a client '
  'payment on a debtor''s credit; a release of a debtor''s credit or of a debit; a payment of such a line with no '
  'release row — each beside the case it admits');
select is(pg_temp.iso('g1', true), (select v from g1), 'g1 (switch on): the same');


-- r. (review round 1, TUI-4) The exits on held duplicates released as label_reference ([check 2]: both statement guards
-- admit the kind « as read, or released so »): three pairs of CSV exports holding the same credit (same day, amount,
-- direction and label, no bank id), the second copy of each held — (c) a debtor's credit citing Martin's payout
-- (DUPONT JEAN, a debtor's IBAN), (b) the same from another debtor at another amount, the fourth our top-up's credit
-- with no counterparty IBAN at exactly its amount. Held, each exit is refused; released (« Libérer », its reading
-- label_reference): « Paiement d'un débiteur » makes the copy a payment to assign (its release row, the payment, its
-- payer the line's own name and IBAN, its cash_in, the result's note); « Règlement du client » books it for the client
-- ops name; « C'est cet approvisionnement » books the cited TOP; each copy's review gone, no candidate of the debit job,
-- no label_reference_waiting; every other exit then refused
create or replace function pg_temp.r1() returns jsonb language plpgsql as $$
declare r jsonb := pg_temp.refs(); d date := private.paris_today(); top uuid := pg_temp.v('lr_top');
        c1 uuid; c2 uuid; b1 uuid; b2 uuid; t1 uuid; t2 uuid; c0 bigint; v jsonb;
begin
  perform pg_temp.imp('af1', d, jsonb_build_array(jsonb_build_object('amount', 20000, 'iban', pg_temp.dib(),
    'name', 'DUPONT JEAN', 'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt', 'key', 'h:af1-1#1')));
  perform pg_temp.imp('af2', d, jsonb_build_array(jsonb_build_object('amount', 20000, 'iban', pg_temp.dib(),
    'name', 'DUPONT JEAN', 'text', pg_temp.lbl(r ->> 'rmt'), 'ref', r ->> 'rmt', 'key', 'h:af2-1#1')));
  perform pg_temp.imp('af3', d, jsonb_build_array(jsonb_build_object('amount', 30000, 'iban', pg_temp.dib(),
    'name', 'DURAND LUC', 'text', pg_temp.lbl(r ->> 'rmt') || ' B', 'ref', r ->> 'rmt', 'key', 'h:af3-1#1')));
  perform pg_temp.imp('af4', d, jsonb_build_array(jsonb_build_object('amount', 30000, 'iban', pg_temp.dib(),
    'name', 'DURAND LUC', 'text', pg_temp.lbl(r ->> 'rmt') || ' B', 'ref', r ->> 'rmt', 'key', 'h:af4-1#1')));
  perform pg_temp.imp('af5', d, jsonb_build_array(jsonb_build_object('amount', 4700,
    'text', pg_temp.toplbl(r ->> 'top'), 'ref', r ->> 'top', 'key', 'h:af5-1#1')));
  perform pg_temp.imp('af6', d, jsonb_build_array(jsonb_build_object('amount', 4700,
    'text', pg_temp.toplbl(r ->> 'top'), 'ref', r ->> 'top', 'key', 'h:af6-1#1')));
  c1 := pg_temp.li('af1', 1); c2 := pg_temp.li('af2', 1);
  b1 := pg_temp.li('af3', 1); b2 := pg_temp.li('af4', 1);
  t1 := pg_temp.li('af5', 1); t2 := pg_temp.li('af6', 1);
  v := jsonb_build_object(
    'kinds', (select jsonb_agg(jsonb_build_array(t.kind, (select h.kind from private.held_line_kind(t.id) h))
                               order by x.ord)
              from unnest(array[c2, b2, t2]) with ordinality x (id, ord) join public.bank_transaction t on t.id = x.id),
    'held', jsonb_build_array(pg_temp.why_of(pg_temp.rel('r1-h', c2)), pg_temp.why_of(pg_temp.clr('r1-h', b2, 'a1')),
                              pg_temp.why_of(pg_temp.pick('k047c-r1-h', t2, top))));
  perform pg_temp.read_as('01', format('select public.resolve_duplicate(%L, %L, false, %L)', 'res-047c-r1-' || x, x,
                                       'Deux opérations distinctes (test)'))
  from unnest(array[c2, b2, t2]) x;
  perform pg_temp.job_reviews();
  c0 := pg_temp.cash();
  v := v || jsonb_build_object(
    'released', (select jsonb_agg(q.released_kind order by x.ord)
                 from unnest(array[c2, b2, t2]) with ordinality x (id, ord)
                 join public.bank_duplicate_resolution q on q.bank_transaction_id = x.id),
    'reviews', jsonb_build_array(pg_temp.review(c2), pg_temp.review(b2), pg_temp.review(t2)),
    'debtor', pg_temp.rel('r1-c', c2) - 'payment_id');
  -- (each read after its command, in a statement of its own: a statement's subqueries read its snapshot)
  v := v || jsonb_build_object(
    'debtor_cash', pg_temp.cash() - c0,
    'debtor_release', (select count(*) from public.bank_own_credit_release c where c.bank_transaction_id = c2),
    'debtor_paid', pg_temp.paid(c2),
    'client', pg_temp.why_of(pg_temp.clr('r1-b', b2, 'a1')));
  v := v || jsonb_build_object(
    'client_booked', jsonb_build_array(pg_temp.bookings(b2), pg_temp.entry_of(b2, 'a1')),
    'top_up', pg_temp.why_of(pg_temp.pick('k047c-r1-t', t2, top)));
  v := v || jsonb_build_object(
    'top_up_booked', jsonb_build_array(pg_temp.booked_as(t2, top), pg_temp.status(top)));
  return v || jsonb_build_object(
    'gone', jsonb_build_array(pg_temp.gone(c2), pg_temp.gone(b2), pg_temp.gone(t2)),
    'again', jsonb_build_array(
      pg_temp.exits(c2, jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('lr_rmt'), 20000)), 'a1', top),
      pg_temp.exits(b2, jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('lr_rmt'), 30000)), 'a1', top),
      pg_temp.exits(t2, jsonb_build_array(pg_temp.pt('payout_returned', top, 4700)), 'a1', top)),
    'firsts', jsonb_build_array(pg_temp.review(c1), pg_temp.review(b1), pg_temp.why_of(pg_temp.pick('k047c-r1-f', t1, top))));
end $$;
create temporary table r1 (v jsonb) on commit drop;
insert into r1 select pg_temp.iso('r1');
select is((select v from r1),
  '{"kinds": [["suspected_duplicate", "label_reference"], ["suspected_duplicate", "label_reference"],
              ["suspected_duplicate", "label_reference"]],
    "held": ["not_own_credit", "not_a_client_credit", "not_an_own_credit"],
    "released": ["label_reference", "label_reference", "label_reference"],
    "reviews": ["label_reference", "label_reference", "label_reference"],
    "debtor": {"status": "unmatched", "note": "Paiement d''un débiteur citant notre référence (vérifié par l''équipe)"},
    "debtor_cash": 20000, "debtor_release": 1,
    "debtor_paid": ["DUPONT JEAN", "FR7630001007941234567890185", "other", "unmatched", "no_match", 20000, 20000, true],
    "client": "ok", "client_booked": [["1 client_payment 30000"], ["client_payment_dedicated", true]],
    "top_up": "ok", "top_up_booked": [[["top_up", true]], "booked"],
    "gone": [[null, false, false], [null, false, false], [null, false, false]],
    "again": [{"return": "already_booked", "client": "line_booked", "debtor": "already_booked",
               "top_up": "not_an_own_credit"},
              {"return": "already_booked", "client": "line_booked", "debtor": "already_booked",
               "top_up": "not_an_own_credit"},
              {"return": "already_booked", "client": "line_booked", "debtor": "already_booked",
               "top_up": "line_booked"}],
    "firsts": ["label_reference", "label_reference", "top_up_not_open"]}'::jsonb,
  'r1: the exits on held duplicates released as label_reference — held, each refused; released, « Paiement d''un '
  'débiteur » (its release row, the payment with the line''s payer, its cash_in), « Règlement du client » and « C''est '
  'cet approvisionnement » book it; the review and the alert gone, every other exit refused');
select is(pg_temp.iso('r1', true), (select v from r1), 'r1 (switch on): the same');


-- i. Tenant isolation and the rights each exit needs: another servicer's ops (05), a collector (02), a client's admin
-- (03) and ops at aal1 take none of the four exits on a line of this servicer; nothing is booked
create or replace function pg_temp.i1() returns jsonb language plpgsql as $$
declare r jsonb := pg_temp.refs(); d date := private.paris_today(); l uuid; t uuid; v jsonb := '{}';
        u text; aal text;
begin
  perform pg_temp.imp('ae1', d, jsonb_build_array(jsonb_build_object('amount', 4700, 'text', pg_temp.toplbl(r ->> 'top'),
                                                                    'ref', r ->> 'top')));
  l := pg_temp.li('ae1', 1); t := pg_temp.v('lr_top');
  perform pg_temp.job_reviews();
  for u, aal in select * from (values ('05', 'aal2'), ('02', 'aal2'), ('03', 'aal2'), ('01', 'aal1')) z (u, a) loop
    v := v || jsonb_build_object(u || ':' || aal, jsonb_build_array(
      pg_temp.why_of(pg_temp.read_as(u, format('select public.book_transfer_line(%L, %L, %L, %L, %L)',
                                               'i1-' || u || aal, l, jsonb_build_array(pg_temp.pt('payout_returned', t,
                                                                                                  4700)),
                                               'x', 'x'), aal)),
      pg_temp.why_of(pg_temp.clr('i1-' || u || aal, l, 'a1', u, aal)),
      pg_temp.why_of(pg_temp.rel('i1-' || u || aal, l, u, aal)),
      pg_temp.why_of(pg_temp.read_as(u, format('select public.book_top_up_credit(%L, %L, %L, %L)', 'i1-' || u || aal, l,
                                               t, 'x'), aal))));
  end loop;
  return v || jsonb_build_object('booked', pg_temp.bookings(l), 'review', pg_temp.review(l),
                                 'paid', (select count(*) from public.payment p where p.bank_transaction_id = l));
end $$;
select is(pg_temp.iso('i1'),
  '{"05:aal2": ["not allowed", "not allowed", "not allowed", "not allowed"],
    "02:aal2": ["not allowed", "not allowed", "not allowed", "not allowed"],
    "03:aal2": ["not allowed", "not allowed", "not allowed", "not allowed"],
    "01:aal1": ["not allowed", "not allowed", "not allowed", "not allowed"],
    "booked": [], "review": "label_reference", "paid": 0}'::jsonb,
  'i1: another servicer''s staff, a collector, a client''s admin and ops at aal1 take no exit; nothing is booked');


-- p. The privileges of the redefined functions -------------------------------------------------------------------------
select is((select jsonb_agg(jsonb_build_array(f, has_function_privilege('anon', f, 'execute'),
                                              has_function_privilege('authenticated', f, 'execute'),
                                              has_function_privilege('service_role', f, 'execute')) order by f)
           from unnest(array['private.transfer_line_class(uuid)', 'private.transfer_line_pre(uuid)',
                             'private.transfer_line_check(uuid, boolean)', 'private.transfer_line_options_of(uuid)',
                             'private.bank_line_booking_guard()', 'private.remittance_chain_events(uuid, uuid, uuid)',
                             'private.client_line_facts(uuid)', 'private.client_line_facts(uuid, uuid)',
                             'public.client_payment_line(uuid, uuid[], uuid[], uuid)',
                             'public.book_client_payment_line(text, uuid, uuid[], uuid, uuid[], text, text, uuid)',
                             'public.release_own_credit(text, uuid, text)', 'private.bank_own_credit_release_guard()',
                             'private.payment_insert_guard()', 'public.book_top_up_credit(text, uuid, uuid, text)',
                             'private.bank_booking_recheck(uuid)']) f),
  '[["private.bank_booking_recheck(uuid)", false, false, false],
    ["private.bank_line_booking_guard()", false, false, false],
    ["private.bank_own_credit_release_guard()", false, false, false],
    ["private.client_line_facts(uuid, uuid)", false, false, false],
    ["private.client_line_facts(uuid)", false, false, false],
    ["private.payment_insert_guard()", false, false, false],
    ["private.remittance_chain_events(uuid, uuid, uuid)", false, false, false],
    ["private.transfer_line_check(uuid, boolean)", false, false, false],
    ["private.transfer_line_class(uuid)", false, false, false],
    ["private.transfer_line_options_of(uuid)", false, false, false],
    ["private.transfer_line_pre(uuid)", false, false, false],
    ["public.book_client_payment_line(text, uuid, uuid[], uuid, uuid[], text, text, uuid)", false, true, true],
    ["public.book_top_up_credit(text, uuid, uuid, text)", false, true, true],
    ["public.client_payment_line(uuid, uuid[], uuid[], uuid)", false, true, true],
    ["public.release_own_credit(text, uuid, text)", false, true, true]]'::jsonb,
  'p: the exits are the back office''s commands (authenticated, checked inside); their guards, checks and readers '
  'internal');
select is((select count(*)::integer from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('book_client_payment_line', 'client_payment_line')), 2,
  'p: one form of each client-payment command (the earlier signatures dropped)');


-- The switch is still off (no M2c-7 migration writes it) --------------------------------------------------------------
select is(private.switch_on('downloaded_file_cancellation'), false,
  'the cancellation-after-download switch is still off');

select * from finish();
rollback;
