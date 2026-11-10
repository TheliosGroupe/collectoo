-- M2c-5 (M2-14 statement, M2-15 PDF): the documents of a run. An approval queues the statement and the invoice PDF
-- (private.remittance_document_todo, a `documents` message); the statement's payload is built in SQL from the run's
-- frozen facts and agrees with the run (CSV = PDF = run start here: lines, files and natures add up to its gross and
-- commission; the position before the payout is what the ledger owed the client at K); the job's record step stores the
-- files' documents and rows once, append-only; the buyer's electronic acceptance at issue decides whether the client
-- reads an invoice's PDF (CGI 289 VI); read access — the rows, the document rows and the objects of the private bucket —
-- for money staff and the client's members with access to the whole client only (clients A/B, a portfolio-restricted
-- viewer, a collector, aal1); the client space's summary and the accountant's export. Design
-- docs/design/m2c-remittances.md §10, §14, §17, §18; ADR-0014 M2c-5.
begin;
select plan(42);

-- Fixtures (as 021: Martin (a1) and Lilas (a2) of the servicer aa, each with a file paid; Martin accepted electronic
-- invoices in its mandate, Lilas did not) ----------------------------------------------------------------
-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo SAS', '732829320'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Autre cabinet SAS', null);
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Martin SAS',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Lilas Finance',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Bleu SARL', null);
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@runs.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '06', '07', '08']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a1', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000a2', 'client_admin');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', 'P1'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2', 'P2');
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-0000000000a1');  -- a client viewer of P1 only
insert into public.bank_account (id, organization_id, purpose, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000cf', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
   'FR3430001007940000000001001', 'EUR', 'Fonds de tiers', 'camt053', '2026-01-01');
insert into public.billing_identity (organization_id, legal_form, share_capital_minor, rcs_city, registered_office,
                                     vat_number, is_professional)
select o.id, case when o.kind = 'servicer' then 'SAS' end, case when o.kind = 'servicer' then 1000000 end,
       case when o.kind = 'servicer' then 'Paris' end,
       '{"line1": "1 rue de la Paix", "postcode": "75002", "city": "Paris", "country": "FR"}',
       case when o.kind = 'servicer'
            then 'FR' || lpad(((12 + 3 * (o.siren::bigint % 97)) % 97)::text, 2, '0') || o.siren end, true
from public.organization o where o.id in ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
                                          '00000000-0000-0000-0000-0000000000a2');
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-0000000000' || x.n)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || '.pdf', repeat('a', 64),
       'application/pdf'
from (values ('01', 'a1', 'mandate_document'), ('02', 'a2', 'mandate_document'), ('03', 'a1', 'payout_rib'),
             ('04', 'a2', 'payout_rib')) x (n, c, kind);
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on,
                            insurance_clause_ref) values
  ('70000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
   'MAND-MARTIN', 'mandate_amicable', '2026-01-01', 'art. 9'),
  ('70000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
   'MAND-LILAS', 'mandate_amicable', '2026-01-01', 'art. 9');
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
from (values ('a1', '01'), ('a2', '02')) x (c, d);
update public.portfolio set mandate_id = ('70000000-0000-0000-0000-0000000000' || right(id::text, 2))::uuid
where id in ('20000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a2');
insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                          evidence_document_id, proposed_by)
select ('90000000-0000-0000-0000-0000000000' || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, 'EUR', x.iban, x.holder,
       ('d0000000-0000-0000-0000-0000000000' || x.d)::uuid, '10000000-0000-0000-0000-000000000004'
from (values ('a1', '03', 'FR7630004000031234567890143', 'MARTIN SAS'),
             ('a2', '04', 'FR1420041010050500013M02606', 'LILAS FINANCE')) x (c, d, iban, holder);
update public.client_payout_account set status = 'active', confirmed_at = now(), confirmed_via = 'client_portal',
  confirmed_by = case client_organization_id when '00000000-0000-0000-0000-0000000000a1'
                   then '10000000-0000-0000-0000-000000000003'::uuid else '10000000-0000-0000-0000-000000000008'::uuid end
where id in ('90000000-0000-0000-0000-0000000000a1', '90000000-0000-0000-0000-0000000000a2');

create or replace function pg_temp.f(p_n text) returns uuid language sql as $$
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.it(p_n text) returns uuid language sql as $$
  select ('c1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.pay(p_n text) returns uuid language sql as $$
  select ('f1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
-- A file with one invoice owed (opening as an adjustment).
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
  perform private.ledger_post('00000000-0000-0000-0000-0000000000aa', 'adjustment', '2026-09-30', 'runs-owe-' || p_n,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', pg_temp.it(p_n), 'component', 'principal'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', 'principal')),
    jsonb_build_object('account_id', pg_temp.f(p_n), 'reason', 'ouverture (test)'));
end $$;
-- A payment on the dedicated account (its line, the payment, its cash_in), matched to the file and allocated.
create or replace function pg_temp.collect(p_n text, p_amount bigint, p_day date) returns void language plpgsql as $$
declare s uuid := ('e1000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 'r.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, 1, 't:' || s, 'credit',
          p_amount, 'EUR', p_day, 'debtor_credit', 'E2E-' || p_n);
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, payer_name, end_to_end_id)
  values (pg_temp.pay(p_n), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s,
          'camt053', 'sct', p_amount, 'EUR', p_day, 'PAYEUR ' || p_n, 'E2E-' || p_n);
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_in', p_day, 'cash_in:' || s || ':' || p_day,
          'bank_statement', s::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cf'),
    (1, 2, 'unallocated_payment', -p_amount, 'EUR', null);
  perform private.ledger_post_set();
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
-- What the prepare job writes (emulated): one draft line per reserved item, commission `p_commission` on each, the
-- documents, key states and plan given, then the header. Returns the run's new version.
create or replace function pg_temp.prepare(p_run uuid, p_commission bigint, p_docs jsonb, p_keys jsonb, p_plan jsonb,
                                           p_vat numeric default 0.2)
returns integer language plpgsql as $$
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
         jsonb_build_object('principal', q.amount_minor::text), p_commission, 'charged', '[]', true
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
    'settlement', p_plan ->> 'settlement', 'net', p_plan ->> 'net', 'vat_rate', p_vat::text,
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
-- The draft as the page shows it, for approve_remittance_runs.
create or replace function pg_temp.item(p_run uuid) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('run_id', r.id, 'inputs_hash', r.inputs_hash, 'net_text', r.net_minor::text))
  from public.remittance_run r where r.id = p_run;
$$;
create or replace function pg_temp.bal(p_book text, p_client text default null) returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.organization_id = '00000000-0000-0000-0000-0000000000aa' and la.book = p_book
    and (p_client is null or la.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_client)::uuid);
$$;
create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
grant execute on all functions in schema pg_temp to authenticated;
create temporary table t (k text primary key, v uuid) on commit drop;
grant all on t to authenticated;
create temporary table j (k text primary key, v jsonb) on commit drop;
grant all on j to authenticated;
update public.billing_identity set invoice_acceptance_ref = 'art. 11 du mandat'
where organization_id = '00000000-0000-0000-0000-0000000000a1';

select pg_temp.file('01', '20000000-0000-0000-0000-0000000000a1', 200000);
select pg_temp.file('02', '20000000-0000-0000-0000-0000000000a2', 512000);
select pg_temp.collect('01', 200000, private.paris_today() - 3);
select pg_temp.collect('02', 512000, private.paris_today() - 3);

-- Martin's run and Lilas's run, prepared (emulated) and approved by the job's function ------------------
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'rq1', public.request_remittance_run('rq-doc-martin-1', '00000000-0000-0000-0000-0000000000a1');
insert into j select 'rq2', public.request_remittance_run('rq-doc-lilas-01', '00000000-0000-0000-0000-0000000000a2');
reset role;
insert into t select 'r1', (v ->> 'run_id')::uuid from j where k = 'rq1';
insert into t select 'r2', (v ->> 'run_id')::uuid from j where k = 'rq2';
create or replace function pg_temp.doc(p_c text, p_ht bigint) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'ref', 'new:70000000-0000-0000-0000-0000000000' || p_c, 'kind', 'invoice',
    'mandate_id', '70000000-0000-0000-0000-0000000000' || p_c, 'ht', p_ht::text, 'vat', (p_ht / 5)::text,
    'ttc', (p_ht * 6 / 5)::text, 'vat_rate', '0.2', 'settlement', 'netted', 'clause_ref', 'art. 7.2',
    'lines', jsonb_build_array(jsonb_build_object('kind', 'commission', 'designation_fr', 'Commission (test)',
      'claim_type', 'b2b_invoice', 'rule_id', 'tout', 'families', '["principal"]'::jsonb,
      'tiers', jsonb_build_array(jsonb_build_array('0.15', (p_ht * 20 / 3)::text)), 'ht', p_ht::text, 'vat_rate', '0.2')),
    'charges', jsonb_build_array(jsonb_build_object('account_id', pg_temp.f('0' || right(p_c, 1)),
                                                    'tier_key', 'tout', 'amount', p_ht::text))));
$$;
create or replace function pg_temp.plan(p_c text, p_gross bigint, p_ht bigint) returns jsonb language sql as $$
  select jsonb_build_object('settles', jsonb_build_array(jsonb_build_object(
           'ref', 'new:70000000-0000-0000-0000-0000000000' || p_c, 'kind', 'compensation',
           'mandate_id', '70000000-0000-0000-0000-0000000000' || p_c, 'amount', (p_ht * 6 / 5)::text,
           'vat_moved', (p_ht / 5)::text, 'open_before', (p_ht * 6 / 5)::text)),
         'net', (p_gross - p_ht * 6 / 5)::text, 'settlement', (p_ht * 6 / 5)::text, 'dc', (p_ht * 6 / 5)::text,
         'da', '0', 'vat_moved', (p_ht / 5)::text, 'deferred', false, 'invoice_ht', p_ht::text,
         'invoice_vat', (p_ht / 5)::text, 'invoice_ttc', (p_ht * 6 / 5)::text);
$$;
create or replace function pg_temp.keys(p_c text, p_gross bigint, p_ht bigint) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('account_id', pg_temp.f('0' || right(p_c, 1)),
    'tier_key', 'tout', 'basis', jsonb_build_array(jsonb_build_array('71000000-0000-0000-0000-0000000000' || p_c,
                                                                     p_gross::text)),
    'kept_basis', '0', 'kept', '0', 'commission', p_ht::text));
$$;
select pg_temp.prepare((select v from t where k = 'r1'), 30000, pg_temp.doc('a1', 30000), pg_temp.keys('a1', 200000, 30000),
                       pg_temp.plan('a1', 200000, 30000));
select pg_temp.prepare((select v from t where k = 'r2'), 76800, pg_temp.doc('a2', 76800), pg_temp.keys('a2', 512000, 76800),
                       pg_temp.plan('a2', 512000, 76800));
select pg_temp.as_user('01');
set local role authenticated;
select public.approve_remittance_runs('ap-doc-martin-1', pg_temp.item((select v from t where k = 'r1')));
select public.approve_remittance_runs('ap-doc-lilas-01', pg_temp.item((select v from t where k = 'r2')));
reset role;
select is(private.approve_remittance_run((select v from t where k = 'r1'),
                                         (select job_token from public.remittance_run where id = (select v from t where k = 'r1'))) ->> 'status',
  'approved', 'Martin''s run approved');
select is(private.approve_remittance_run((select v from t where k = 'r2'),
                                         (select job_token from public.remittance_run where id = (select v from t where k = 'r2'))) ->> 'status',
  'approved', 'Lilas''s run approved');
insert into t select 'i1', id from public.commission_invoice where run_id = (select v from t where k = 'r1');
insert into t select 'i2', id from public.commission_invoice where run_id = (select v from t where k = 'r2');

-- The approval queues the documents -------------------------------------------------------------------
select results_eq($$ select kind, count(*)::int from private.remittance_document_todo
                     where organization_id = '00000000-0000-0000-0000-0000000000aa' group by kind order by kind $$,
  $$ values ('invoice'::text, 2), ('statement', 2) $$,
  'each approval queues its statement and its invoice''s PDF');
select ok(exists (select 1 from pgmq.q_remittances m where m.message ->> 'type' = 'documents'
                    and m.message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000aa'),
  'and a documents job for the servicer');

-- The statement payload (§10): built from the run's frozen facts ---------------------------------------
insert into j select 'p1', private.remittance_statement_build((select v from t where k = 'r1'));
select results_eq($$ select v ->> 'number', v ->> 'status', (v ->> 'issue_date')::date, v #>> '{totals,gross_minor}',
                            v #>> '{totals,net_minor}', v #>> '{totals,invoice_ttc_minor}',
                            v #>> '{totals,commission_taken_minor}', (v #>> '{totals,line_count}')::int
                     from j where k = 'p1' $$,
  $$ select r.number, 'approved'::text, private.paris_today(), r.gross_minor::text, r.net_minor::text,
            r.invoice_ttc_minor::text, r.commission_taken_minor::text, r.line_count
     from public.remittance_run r where r.id = (select v from t where k = 'r1') $$,
  'its number, issue date and totals are the run''s');
select is((select sum((l ->> 13)::bigint)::bigint from j, jsonb_array_elements(j.v -> 'lines') l where j.k = 'p1'),
  (select gross_minor from public.remittance_run where id = (select v from t where k = 'r1')),
  'CSV = run: its lines add up to the gross');
select is((select sum((l ->> 17)::bigint)::bigint from j, jsonb_array_elements(j.v -> 'lines') l where j.k = 'p1'),
  (select sum(ht_minor)::bigint from public.commission_invoice where run_id = (select v from t where k = 'r1')),
  'and their commission to the documents'' HT');
select is((select sum((f ->> 'amount_minor')::bigint)::bigint from j, jsonb_array_elements(j.v -> 'files') f
           where j.k = 'p1'), 200000::bigint, 'PDF = run: its per-file table adds up to the gross');
select is((select sum((n ->> 'amount_minor')::bigint)::bigint from j, jsonb_array_elements(j.v -> 'natures') n
           where j.k = 'p1'),
  200000::bigint, 'and so do its natures');
select is((select v #>> '{position,owed_before_minor}' from j where k = 'p1'),
  (select (-private.ledger_balance(la.id, '9999-12-31', r.known_at))::text from public.remittance_run r
   join public.ledger_account la on la.organization_id = r.organization_id and la.book = 'client_payable'
    and la.client_organization_id = r.client_organization_id and la.currency = r.currency
   where r.id = (select v from t where k = 'r1')),
  'the position before the payout is what the ledger owed the client at K');
select results_eq($$ select l ->> 3, l ->> 7, l ->> 19, (l ->> 21)::boolean
                     from j, jsonb_array_elements(j.v -> 'lines') l where j.k = 'p1' $$,
  $$ values ('D-01'::text, 'allocation'::text, 'FC-' || extract(year from private.paris_today()) || '-000001', false) $$,
  'each line names its file, nature and invoice');
select results_eq($$ select v #>> '{issuer,siren}', v #>> '{client,name}', v #>> '{payout,iban}',
                            v #>> '{payout,status}', v #>> '{documents,0,settles_minor}',
                            v #>> '{mandates,0,netting_clause_ref}'
                     from j where k = 'p1' $$,
  $$ values ('732829320'::text, 'Martin SAS'::text, 'FR76 •••• •••• •••• 0143'::text, 'ordered'::text, '36000'::text,
             'art. 7.2'::text) $$,
  'the issuer, the client, the payout as ordered (masked IBAN), the compensation and the clause');
select is(private.remittance_statement_build((select v from t where k = 'r1')), (select v from j where k = 'p1'),
  'the same facts build the same payload');
select throws_ok($$ select private.remittance_statement_build(gen_random_uuid()) $$, '23514', null,
  'only an approved run has a statement');

-- The job: prepare, render (emulated), record — once ----------------------------------------------------
create temporary table due on commit drop as
select * from private.remittance_documents_begin('00000000-0000-0000-0000-0000000000aa', 10, 10);
select results_eq($$ select kind, number, pdf_path ~ ('^(statements|invoices)/00000000-0000-0000-0000-0000000000aa/'
                                                     || '00000000-0000-0000-0000-0000000000a[12]/[0-9]{4}/' || number
                                                     || '\.pdf$')
                     from due order by kind, number $$,
  $$ select 'invoice'::text, i.number, true from public.commission_invoice i
     where i.id in ((select v from t where k = 'i1'), (select v from t where k = 'i2'))
     union all select 'statement', r.number, true from public.remittance_run r
     where r.id in ((select v from t where k = 'r1'), (select v from t where k = 'r2'))
     order by 1, 2 $$,
  'what is due, each at its key');
select results_eq($$ select kind, count(*)::int from private.remittance_documents_missing(
                       '00000000-0000-0000-0000-0000000000aa', '0 seconds') group by kind order by kind $$,
  $$ values ('invoice'::text, 2), ('statement', 2) $$,
  'documents still due are listed with their age (the input of the future document_missing alert)');
select private.remittance_statement_prepare(d.ref_id) from due d where d.kind = 'statement';
insert into pg_temp._rd_statement_files select d.ref_id, repeat('b', 64), repeat('c', 64) from due d
where d.kind = 'statement';
insert into pg_temp._rd_invoice_pdf select d.ref_id, repeat('d', 64) from due d where d.kind = 'invoice';
select is(private.remittance_documents_record('00000000-0000-0000-0000-0000000000aa', 'releve-reversement-fr-1',
                                              'facture-commission-fr-1', 'test'),
  '{"statements": 2, "invoices": 2, "more": false}'::jsonb, 'recorded: two statements, two invoice PDFs');
select results_eq($$ select s.number, s.line_count, s.file_count, s.payload_sha256 = encode(sha256(convert_to(s.payload::text,
                            'UTF8')), 'hex'), dp.kind, dp.sha256, dc.kind, dc.mime_type
                     from public.remittance_statement s
                     join public.document dp on dp.id = s.pdf_document_id join public.document dc on dc.id = s.csv_document_id
                     where s.run_id = (select v from t where k = 'r1') $$,
  $$ select r.number, 1, 1, true, 'remittance_statement_pdf'::text, repeat('b', 64), 'remittance_statement_csv'::text,
            'text/csv'::text
     from public.remittance_run r where r.id = (select v from t where k = 'r1') $$,
  'the statement row: its payload''s hash, its PDF and CSV documents');
select is((select payload from public.remittance_statement where run_id = (select v from t where k = 'r1')),
  (select v from j where k = 'p1'), 'the stored payload is the one built');
select results_eq($$ select i.number, d.electronic, d.pdf_sha256 from public.commission_invoice_document d
                     join public.commission_invoice i on i.id = d.invoice_id
                     where d.organization_id = '00000000-0000-0000-0000-0000000000aa' order by i.seq $$,
  $$ select i.number, i.client_organization_id = '00000000-0000-0000-0000-0000000000a1', repeat('d', 64)
     from public.commission_invoice i where i.organization_id = '00000000-0000-0000-0000-0000000000aa' order by i.seq $$,
  'each invoice''s PDF; electronic only for the buyer who accepted it at issue (289 VI)');
select is((select count(*)::int from private.remittance_document_todo
           where organization_id = '00000000-0000-0000-0000-0000000000aa'), 0, 'nothing left to draw');
select is((select count(*)::int from private.remittance_documents_begin('00000000-0000-0000-0000-0000000000aa', 10, 10)), 0,
  'a second job finds nothing');
insert into pg_temp._rd_invoice_pdf values ((select v from t where k = 'i1'), repeat('e', 64));
select throws_ok($$ select private.remittance_documents_record('00000000-0000-0000-0000-0000000000aa', 'x', 'y', 'z') $$,
  '23505', null, 'a document is recorded once');
select throws_ok($$ update public.remittance_statement set pdf_sha256 = repeat('f', 64) $$, '23514', null,
  'a statement never changes');
select throws_ok($$ delete from public.commission_invoice_document $$, '23514', null, 'nor an invoice''s PDF row');

-- Read access (OQ-48): rows, document rows and objects --------------------------------------------------
insert into storage.objects (bucket_id, name)
select 'documents', d.storage_path from public.document d
where d.organization_id = '00000000-0000-0000-0000-0000000000aa'
  and d.kind in ('remittance_statement_pdf', 'remittance_statement_csv', 'commission_invoice_pdf');
create or replace function pg_temp.seen(p_user text, p_aal text default 'aal2') returns int[] language plpgsql as $$
declare v int[];
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  select array[(select count(*)::int from public.remittance_statement),
               (select count(*)::int from public.commission_invoice_document),
               (select count(*)::int from public.document
                where kind in ('remittance_statement_pdf', 'remittance_statement_csv', 'commission_invoice_pdf')),
               (select count(*)::int from storage.objects
                where bucket_id = 'documents' and (name like 'statements/%' or name like 'invoices/%'))]
  into v;
  reset role;
  return v;
end $$;
select is(pg_temp.seen('01'), array[2, 2, 6, 6], 'money staff read every statement, PDF and object');
select is(pg_temp.seen('01', 'aal1'), array[0, 0, 0, 0], 'not at aal1');
select is(pg_temp.seen('03'), array[1, 1, 3, 3], 'Martin''s administrator reads its statement and its invoice');
select is(pg_temp.seen('08'), array[1, 0, 2, 2],
  'Lilas''s administrator reads its statement, not the PDF of an invoice it did not accept electronically');
select is(pg_temp.seen('07'), array[0, 0, 0, 0], 'a viewer restricted to some portfolios reads none (OQ-48)');
select is(pg_temp.seen('02'), array[0, 0, 0, 0], 'a collector reads none');
select is(pg_temp.seen('05'), array[0, 0, 0, 0], 'another servicer''s staff read none');
select pg_temp.as_user('03');
set local role authenticated;
select throws_ok($$ insert into public.remittance_statement (run_id) values (gen_random_uuid()) $$, '42501', null,
  'the API writes no statement');
select throws_ok($$ select private.remittance_statement_build((select v from t where k = 'r1')) $$, '42501', null,
  'nor builds one');

-- The client space's summary (§17.7) ------------------------------------------------------------------
select results_eq($$ select (public.client_remittance_summary('00000000-0000-0000-0000-0000000000a1')
                             -> 'in_flight' -> 0) ->> 'number',
                            public.client_remittance_summary('00000000-0000-0000-0000-0000000000a1') #>> '{owed,0,owed_minor}' $$,
  $$ select r.number, '200000'::text from public.remittance_run r where r.id = (select v from t where k = 'r1') $$,
  'the client reads its run in flight and what it is owed until the debit');
select ok((public.client_remittance_summary('00000000-0000-0000-0000-0000000000a1') ->> 'next_run_day')::date
          > private.paris_today(), 'and the next scheduled run day');
select throws_ok($$ select public.client_remittance_summary('00000000-0000-0000-0000-0000000000a2') $$, '42501', null,
  'not another client''s');
reset role;
select pg_temp.as_user('07');
set local role authenticated;
select throws_ok($$ select public.client_remittance_summary('00000000-0000-0000-0000-0000000000a1') $$, '42501', null,
  'nor does a restricted viewer');

-- The accountant's export (§14.2) ---------------------------------------------------------------------
select throws_ok($$ select * from public.accounting_export_documents('2026-01-01', '2026-12-31') $$, '42501', null,
  'a client exports nothing');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select results_eq($$ select number, kind, client_name, client_siren, ht_minor, vat_minor, ttc_minor, settled_minor,
                            open_minor
                     from public.accounting_export_documents(private.paris_today() - 1, private.paris_today()) $$,
  $$ select i.number, 'invoice'::text, o.legal_name, o.siren, i.ht_minor, i.vat_minor, i.ttc_minor, 0::bigint, i.ttc_minor
     from public.commission_invoice i join public.organization o on o.id = i.client_organization_id
     where i.organization_id = '00000000-0000-0000-0000-0000000000aa' order by i.seq $$,
  'the invoices of the period, open until the payout''s debit settles them');
select results_eq($$ select account_number, sum(debit_minor)::bigint, sum(credit_minor)::bigint
                     from public.accounting_export_entries(private.paris_today() - 1, private.paris_today())
                     group by account_number order by account_number $$,
  $$ values ('4111'::text, 128160::bigint, 0::bigint), ('44574', 0, 21360), ('7060', 0, 106800) $$,
  'the entries of the servicer''s books: 4111, 44574, 7060');
select throws_ok($$ select * from public.accounting_export_entries('2025-01-01', '2026-12-31') $$, '22023', null,
  'one year at most');
reset role;

select * from finish();
rollback;
