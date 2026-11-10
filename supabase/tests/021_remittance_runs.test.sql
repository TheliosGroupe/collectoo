-- M2c-4 (M2-14 core, M2-15 numbering): remittance runs and their documents. A draft reserves the client's pending items
-- under the allocation lock, the prepare job's writes (emulated here: the lines and the header it records), approval
-- (one approver at aal2, compare and set on the inputs hash and the net), the approval job's transaction — refusals
-- that send a run back to draft, the lines frozen (each item in exactly one live line), the invoice numbered in the
-- servicer's yearly series and its entry, the payout ordered (N > 0), the settlement posted at once (N = 0) — the
-- cancellation before the transfer is in a file (a full credit note, the lines released, the items back), the frozen
-- facts, the nightly checks I14–I18 and R124-6, the reads and the read policies (clients A/B, a restricted client
-- viewer, a collector, another servicer). Design docs/design/m2c-remittances.md §6, §9, §14, §15, §18; ADR-0014 M2c-4.
begin;
select plan(106);

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

select pg_temp.file('01', '20000000-0000-0000-0000-0000000000a1', 200000);
select pg_temp.file('02', '20000000-0000-0000-0000-0000000000a2', 512000);
select pg_temp.collect('01', 200000, private.paris_today() - 3);   -- Martin's file paid
select pg_temp.collect('02', 512000, private.paris_today() - 3);   -- Lilas's file paid
insert into t select 'e1', id from public.ledger_entry where payment_id = pg_temp.pay('01') and entry_type = 'allocation';
insert into t select 'e2', id from public.ledger_entry where payment_id = pg_temp.pay('02') and entry_type = 'allocation';

-- Drafts: « Préparer maintenant » ----------------------------------------------------------------------
select is((select count(*)::int from private.remittance_pending
           where organization_id = '00000000-0000-0000-0000-0000000000aa' and draft_run_id is null), 2,
  'the two allocations wait in the pending queue');
select pg_temp.as_user('02');
set local role authenticated;
select throws_ok($$ select public.request_remittance_run('rq-collector-1', '00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'a collector does not prepare runs');
select pg_temp.as_user('03');
select throws_ok($$ select public.request_remittance_run('rq-client-0001', '00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'nor does the client');
select pg_temp.as_user('01', 'aal1');
select throws_ok($$ select public.request_remittance_run('rq-aal1-00001', '00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'nor an ops manager at aal1');
select pg_temp.as_user('01');
insert into j select 'rq1', public.request_remittance_run('rq-martin-0001', '00000000-0000-0000-0000-0000000000a1');
select is((select v from j where k = 'rq1'), public.request_remittance_run('rq-martin-0001',
                                                                          '00000000-0000-0000-0000-0000000000a1'),
  'the same key returns the same draft');
select throws_ok($$ select public.request_remittance_run('rq-martin-0002', '00000000-0000-0000-0000-0000000000a1') $$,
  '23505', 'remittance run refused: run_pending', 'one pending run per (client, currency)');
insert into j select 'rq2', public.request_remittance_run('rq-lilas-00001', '00000000-0000-0000-0000-0000000000a2');
reset role;
insert into t select 'r1', (v ->> 'run_id')::uuid from j where k = 'rq1';
insert into t select 'r2', (v ->> 'run_id')::uuid from j where k = 'rq2';
select results_eq($$ select status, trigger, job, item_count, number ~ '^RV-[0-9]{4}-[0-9]{6}$'
                     from public.remittance_run where id = (select v from t where k = 'r1') $$,
  $$ values ('draft'::text, 'manual'::text, 'prepare'::text, 1, true) $$,
  'a draft, its prepare job in flight, one item reserved, numbered RV-AAAA-NNNNNN');
select is((select draft_run_id from private.remittance_pending where ledger_entry_id = (select v from t where k = 'e1')),
  (select v from t where k = 'r1'), 'the item is reserved by the draft');
select ok(exists (select 1 from pgmq.q_remittances m where m.message ->> 'type' = 'prepare'
                    and m.message ->> 'run_id' = (select v from t where k = 'r1')::text),
  'its prepare job is queued');
select ok((select known_at from public.remittance_run where id = (select v from t where k = 'r1')) is not null,
  'K is recorded');

-- The prepare job's writes ---------------------------------------------------------------------------
select throws_ok($$ select private.remittance_record_draft((select v from t where k = 'r1'), gen_random_uuid(), '{}') $$,
  '40001', null, 'a job that is no longer the run''s writes nothing');
select throws_ok($$ select private.remittance_record_draft((select v from t where k = 'r1'),
                     (select job_token from public.remittance_run where id = (select v from t where k = 'r1')),
                     '{"gross": "0", "line_count": 0}') $$,
  '23514', null, 'a draft whose lines are not the items reserved is refused');
insert into j values ('doc1', jsonb_build_array(jsonb_build_object(
  'ref', 'new:70000000-0000-0000-0000-0000000000a1', 'kind', 'invoice',
  'mandate_id', '70000000-0000-0000-0000-0000000000a1', 'ht', '30000', 'vat', '6000', 'ttc', '36000', 'vat_rate', '0.2',
  'settlement', 'netted', 'clause_ref', 'art. 7.2',
  'lines', jsonb_build_array(jsonb_build_object('kind', 'commission', 'designation_fr',
    'Commission de recouvrement amiable — Toutes créances — 15 % sur 2 000,00 € (mandat MAND-MARTIN)',
    'claim_type', 'b2b_invoice', 'rule_id', 'tout', 'families', '["principal"]'::jsonb,
    'tiers', '[["0.15", "200000"]]'::jsonb, 'ht', '30000', 'vat_rate', '0.2')),
  'charges', jsonb_build_array(jsonb_build_object('account_id', pg_temp.f('01'), 'tier_key', 'tout', 'amount', '30000')))));
insert into j values ('plan1', '{"settles": [{"ref": "new:70000000-0000-0000-0000-0000000000a1", "kind": "compensation",
  "mandate_id": "70000000-0000-0000-0000-0000000000a1", "amount": "36000", "vat_moved": "6000", "open_before": "36000"}],
  "net": "164000", "settlement": "36000", "dc": "36000", "da": "0", "vat_moved": "6000", "deferred": false,
  "invoice_ht": "30000", "invoice_vat": "6000", "invoice_ttc": "36000"}');
select is(pg_temp.prepare((select v from t where k = 'r1'), 30000, (select v from j where k = 'doc1'),
                          jsonb_build_array(jsonb_build_object('account_id', pg_temp.f('01'), 'tier_key', 'tout',
                            'basis', jsonb_build_array(jsonb_build_array('71000000-0000-0000-0000-0000000000a1', '200000')),
                            'kept_basis', '0', 'kept', '0', 'commission', '30000')),
                          (select v from j where k = 'plan1')), 2,
  'the draft recorded (version 1 → 2)');
insert into j select 'item1', pg_temp.item((select v from t where k = 'r1'));
select results_eq($$ select job, prepared_at is not null, gross_minor, net_minor, settlement_minor, invoice_ttc_minor,
                            line_count
                     from public.remittance_run where id = (select v from t where k = 'r1') $$,
  $$ values (null::text, true, 200000::bigint, 164000::bigint, 36000::bigint, 36000::bigint, 1) $$,
  'prepared: gross 200 000, commission 36 000 TTC netted, N 164 000');

-- Approval: the command ------------------------------------------------------------------------------
select pg_temp.as_user('02');
set local role authenticated;
select throws_ok($$ select public.approve_remittance_runs('ap-collector-1', (select v from j where k = 'item1')) $$,
  '42501', null, 'a collector approves nothing');
select pg_temp.as_user('01');
select is(public.approve_remittance_runs('ap-stale-00001',
            jsonb_build_array(jsonb_build_object('run_id', (select v from t where k = 'r1'), 'inputs_hash', repeat('0', 64),
                                                 'net_text', '164000'))) #>> '{results,0,reason}',
  'stale', 'a page showing another inputs hash is refused (compare and set)');
select is(public.approve_remittance_runs('ap-net-000001',
            jsonb_build_array(jsonb_build_object('run_id', (select v from t where k = 'r1'),
              'inputs_hash', (select inputs_hash from public.remittance_run where id = (select v from t where k = 'r1')),
              'net_text', '164001'))) #>> '{results,0,reason}',
  'stale', 'or another net');
select is(public.approve_remittance_runs('ap-martin-0001', pg_temp.item((select v from t where k = 'r1'))) #>> '{results,0,status}',
  'queued', 'the draft as shown is queued for approval');
select is(public.approve_remittance_runs('ap-martin-0002', pg_temp.item((select v from t where k = 'r1'))) #>> '{results,0,reason}',
  'approval_in_progress', 'twice: the second request finds its job in flight');
reset role;
select results_eq($$ select job, requested_execution_date, approval_requested_by from public.remittance_run
                     where id = (select v from t where k = 'r1') $$,
  $$ values ('approve'::text, private.next_business_day(private.paris_today()),
             '10000000-0000-0000-0000-000000000001'::uuid) $$,
  'the job in flight, the execution requested for the next business day, the approver');
select is((private.approve_remittance_run((select v from t where k = 'r1'), gen_random_uuid())) ->> 'status', 'skipped',
  'a job that is not the run''s does nothing');

-- Approval: the job's transaction ------------------------------------------------------------------
insert into j select 'ok1', private.approve_remittance_run((select v from t where k = 'r1'),
                                                           (select job_token from public.remittance_run
                                                            where id = (select v from t where k = 'r1')));
select is((select v ->> 'status' from j where k = 'ok1'), 'approved', 'approved');
set constraints all immediate;
select pass('the deferred checks hold (ledger, client money, the lines'' invoice)');
set constraints all deferred;
insert into t select 'i1', id from public.commission_invoice where run_id = (select v from t where k = 'r1');
select results_eq($$ select kind, number, seq, issue_date, ht_minor, vat_minor, ttc_minor, vat_rate, vat_book, settlement
                     from public.commission_invoice where run_id = (select v from t where k = 'r1') $$,
  $$ values ('invoice'::text, 'FC-' || extract(year from private.paris_today()) || '-000001', 1, private.paris_today(),
             30000::bigint, 6000::bigint, 36000::bigint, 0.2000::numeric, 'vat_pending'::text, 'netted'::text) $$,
  'FC-AAAA-000001: 30 000 HT + 6 000 VAT, netted, its VAT pending');
select results_eq($$ select la.book, p.amount_minor from public.commission_invoice i
                     join public.ledger_posting p on p.entry_id = i.ledger_entry_id
                     join public.ledger_account la on la.id = p.ledger_account_id
                     where i.id = (select v from t where k = 'i1') order by p.line_no $$,
  $$ values ('commission_receivable'::text, 36000::bigint), ('servicer_revenue', -30000::bigint),
            ('vat_pending', -6000::bigint) $$,
  'its entry: +4111 TTC / −7060 HT / −44574 VAT');
select results_eq($$ select ledger_entry_id, amount_minor, commission_minor, invoice_id, released
                     from public.remittance_line where run_id = (select v from t where k = 'r1') $$,
  $$ values ((select v from t where k = 'e1'), 200000::bigint, 30000::bigint, (select v from t where k = 'i1'), false) $$,
  'the line frozen, naming its invoice');
select is((select count(*)::int from private.remittance_pending where ledger_entry_id = (select v from t where k = 'e1')),
  0, 'its item left the pending queue');
select results_eq($$ select kind, status, amount_minor, left(end_to_end_id, 3), requested_execution_date,
                            remittance_info like 'REVERSEMENT RV-%FACTURE FC-%', payee_name
                     from public.bank_transfer where run_id = (select v from t where k = 'r1') $$,
  $$ values ('payout'::text, 'ordered'::text, 164000::bigint, 'RMT', private.next_business_day(private.paris_today()), true,
             'MARTIN SAS'::text) $$,
  'the payout ordered (RMT, N, the RIB holder): nothing leaves 5120 before the bank''s debit');
select results_eq($$ select status, approved_by, transfer_id is not null, payout_snapshot ->> 'iban',
                            settlement_plan #>> '{settles,0,document_id}'
                     from public.remittance_run where id = (select v from t where k = 'r1') $$,
  $$ values ('approved'::text, '10000000-0000-0000-0000-000000000001'::uuid, true, 'FR7630004000031234567890143',
             (select v from t where k = 'i1')::text) $$,
  'the run approved by its one approver, the payee frozen, the plan naming its invoice');
select results_eq($$ select account_id, tier_key, cause, commission_minor from public.remittance_key_state
                     where run_id = (select v from t where k = 'r1') $$,
  $$ values (pg_temp.f('01'), 'tout'::text, 'approved'::text, 30000::bigint) $$,
  'the tier history after the run');
select is(pg_temp.bal('client_money_cash'), 712000::bigint, '5120 untouched by the approval');
select is(pg_temp.bal('commission_receivable', 'a1'), 36000::bigint, '4111[Martin] = the invoice');

-- Frozen facts --------------------------------------------------------------------------------------
select throws_ok($$ update public.remittance_line set amount_minor = 1 where run_id = (select v from t where k = 'r1') $$,
  '23514', null, 'a line never changes');
select throws_ok($$ delete from public.remittance_line where run_id = (select v from t where k = 'r1') $$,
  '23514', null, 'nor is deleted');
select throws_ok($$ update public.commission_invoice set ht_minor = 1 where id = (select v from t where k = 'i1') $$,
  '23514', null, 'an invoice never changes');
select throws_ok($$ delete from public.commission_invoice where id = (select v from t where k = 'i1') $$,
  '23514', null, 'nor is deleted');
select throws_ok($$ update public.remittance_run set status = 'draft' where id = (select v from t where k = 'r1') $$,
  '23514', null, 'a run''s status only moves forward');
select throws_ok($$ update public.remittance_run set net_minor = 1 where id = (select v from t where k = 'r1') $$,
  '23514', null, 'an approved run''s amounts never change');
select throws_ok($$ insert into public.remittance_line (run_id, line_no, organization_id, client_organization_id, currency,
                      ledger_entry_id, kind, effective_date, posted_at, amount_minor, commission_state)
                    select (select v from t where k = 'r2'), 9, '00000000-0000-0000-0000-0000000000aa',
                           '00000000-0000-0000-0000-0000000000a1', 'EUR', (select v from t where k = 'e1'), 'allocation',
                           current_date, now(), 200000, 'none' $$,
  '23505', null, 'an item is in at most one live line');
select throws_ok($$ insert into public.remittance_line (run_id, line_no, organization_id, client_organization_id, currency,
                      ledger_entry_id, kind, effective_date, posted_at, amount_minor, commission_state)
                    select (select v from t where k = 'r2'), 9, '00000000-0000-0000-0000-0000000000aa',
                           '00000000-0000-0000-0000-0000000000a2', 'EUR', (select v from t where k = 'e2'), 'allocation',
                           current_date, now(), 1, 'none' $$,
  '23514', null, 'a line is its entry''s 4670 posting');

-- Approval refusals: back to draft with the reason -------------------------------------------------------
insert into j values ('doc2', jsonb_build_array(jsonb_build_object(
  'ref', 'new:70000000-0000-0000-0000-0000000000a2', 'kind', 'invoice',
  'mandate_id', '70000000-0000-0000-0000-0000000000a2', 'ht', '426667', 'vat', '85333', 'ttc', '512000',
  'vat_rate', '0.2', 'settlement', 'netted',
  'lines', jsonb_build_array(jsonb_build_object('kind', 'commission', 'designation_fr', 'Commission (test N = 0)',
    'claim_type', 'b2b_invoice', 'rule_id', 'tout', 'families', '["principal"]'::jsonb,
    'tiers', '[["0.15", "512000"]]'::jsonb, 'ht', '426667', 'vat_rate', '0.2')),
  'charges', jsonb_build_array(jsonb_build_object('account_id', pg_temp.f('02'), 'tier_key', 'tout',
                                                  'amount', '426667')))));
insert into j values ('plan2', '{"settles": [{"ref": "new:70000000-0000-0000-0000-0000000000a2", "kind": "compensation",
  "mandate_id": "70000000-0000-0000-0000-0000000000a2", "amount": "512000", "vat_moved": "85333",
  "open_before": "512000"}], "net": "0", "settlement": "512000", "dc": "512000", "da": "0", "vat_moved": "85333",
  "deferred": false, "invoice_ht": "426667", "invoice_vat": "85333", "invoice_ttc": "512000"}');
select pg_temp.prepare((select v from t where k = 'r2'), 426667, (select v from j where k = 'doc2'),
                       jsonb_build_array(jsonb_build_object('account_id', pg_temp.f('02'), 'tier_key', 'tout',
                         'basis', jsonb_build_array(jsonb_build_array('71000000-0000-0000-0000-0000000000a2', '512000')),
                         'kept_basis', '0', 'kept', '0', 'commission', '426667')),
                       (select v from j where k = 'plan2'), 0.1);
select pg_temp.as_user('01');
set local role authenticated;
select is(public.approve_remittance_runs('ap-lilas-00001', pg_temp.item((select v from t where k = 'r2'))) #>> '{results,0,status}',
  'queued', 'Lilas''s draft (N = 0) queued');
reset role;
select is(private.approve_remittance_run((select v from t where k = 'r2'),
                                         (select job_token from public.remittance_run where id = (select v from t where k = 'r2')))
          ->> 'reason', 'vat_rate_changed', 'a draft priced at another VAT rate than today''s goes back to draft');
select results_eq($$ select status, job, last_failure ->> 'code', requested_execution_date
                     from public.remittance_run where id = (select v from t where k = 'r2') $$,
  $$ values ('draft'::text, null::text, 'vat_rate_changed'::text, null::date) $$,
  'back to draft, with the reason, the reservation kept');
select is((select count(*)::int from public.commission_invoice where run_id = (select v from t where k = 'r2')), 0,
  'nothing numbered');
update private.remittance_draft set vat_rate = 0.2 where run_id = (select v from t where k = 'r2');
update private.client_payable_balance set balance_minor = -511999
where client_organization_id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_user('01');
set local role authenticated;
select is(public.approve_remittance_runs('ap-lilas-00002', pg_temp.item((select v from t where k = 'r2'))) #>> '{results,0,status}',
  'queued', 'queued again');
reset role;
select is(private.approve_remittance_run((select v from t where k = 'r2'),
                                         (select job_token from public.remittance_run where id = (select v from t where k = 'r2')))
          ->> 'reason', 'balance_changed', 'the cap: gross above what the client is owed → back to draft');
update private.client_payable_balance set balance_minor = -512000
where client_organization_id = '00000000-0000-0000-0000-0000000000a2';

-- N = 0: booked at approval, the settlement posted at once ----------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
select is(public.approve_remittance_runs('ap-lilas-00003', pg_temp.item((select v from t where k = 'r2'))) #>> '{results,0,status}',
  'queued', 'queued a third time');
reset role;
-- a rolled-back approval numbers nothing for good: the counter is back
savepoint before_rollback;
select private.approve_remittance_run((select v from t where k = 'r2'),
                                      (select job_token from public.remittance_run where id = (select v from t where k = 'r2')));
select is((select last_seq from private.invoice_counter where organization_id = '00000000-0000-0000-0000-0000000000aa'),
  2, '(inside: the counter at 2)');
rollback to savepoint before_rollback;
select is((select last_seq from private.invoice_counter where organization_id = '00000000-0000-0000-0000-0000000000aa'),
  1, 'rolled back: the counter at 1, no gap');
insert into j select 'ok2', private.approve_remittance_run((select v from t where k = 'r2'),
                                                           (select job_token from public.remittance_run
                                                            where id = (select v from t where k = 'r2')));
select is((select v ->> 'status' from j where k = 'ok2'), 'booked', 'N = 0: booked at approval');
set constraints all immediate;
select pass('the deferred checks hold');
set constraints all deferred;
select results_eq($$ select status, booked_on, transfer_id, settlement_plan ->> 'entry_id' is not null
                     from public.remittance_run where id = (select v from t where k = 'r2') $$,
  $$ values ('booked'::text, private.paris_today(), null::uuid, true) $$,
  'no transfer; the settlement entry recorded on the run');
select results_eq($$ select la.book, p.amount_minor from public.ledger_posting p
                     join public.ledger_account la on la.id = p.ledger_account_id
                     where p.entry_id = (select (settlement_plan ->> 'entry_id')::uuid from public.remittance_run
                                         where id = (select v from t where k = 'r2'))
                     order by p.line_no $$,
  $$ values ('client_payable'::text, 512000::bigint), ('due_to_servicer', -512000::bigint),
            ('due_from_client_funds', 512000::bigint), ('commission_receivable', -512000::bigint),
            ('vat_pending', 85333::bigint), ('vat_collected', -85333::bigint) $$,
  'the settlement: +4670 D / −4679 D ‖ +4689 D / −4111 Dc ‖ +44574 v / −44571 v');
select results_eq($$ select kind, amount_minor, vat_moved_minor, settled_on from public.commission_settlement
                     where run_id = (select v from t where k = 'r2') $$,
  $$ values ('compensation'::text, 512000::bigint, 85333::bigint, private.paris_today()) $$,
  'the invoice settled by compensation, its VAT due (290 A data)');
select is(private.document_open((select id from public.commission_invoice where run_id = (select v from t where k = 'r2'))),
  0::bigint, 'its open part 0');
select is(pg_temp.bal('client_payable', 'a2'), 0::bigint, 'Lilas owed nothing now; −4679 holds the servicer''s money');
select is(pg_temp.bal('due_to_servicer'), -512000::bigint, '4679: the commission on the dedicated account, to sweep');
select results_eq($$ select seq, kind from public.commission_invoice
                     where organization_id = '00000000-0000-0000-0000-0000000000aa' order by seq $$,
  $$ values (1, 'invoice'::text), (2, 'invoice'::text) $$,
  'one series across clients: 1, 2');

-- Cancellation before the transfer is in a file ------------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok($$ select public.cancel_remittance_run('cn-ops-000001', (select v from t where k = 'r1'),
                     (select version from public.remittance_run where id = (select v from t where k = 'r1')), 'test') $$,
  '42501', null, 'only an admin cancels an approved run');
select pg_temp.as_user('04');
select throws_ok($$ select public.cancel_remittance_run('cn-version-01', (select v from t where k = 'r1'), 1, 'test') $$,
  '23514', 'remittance run refused: version_changed', 'compare and set on the version shown');
select throws_ok($$ select public.cancel_remittance_run('cn-booked-001', (select v from t where k = 'r2'),
                     (select version from public.remittance_run where id = (select v from t where k = 'r2')), 'test') $$,
  '23514', 'remittance run refused: not_cancellable', 'a booked run is never cancelled');
insert into j select 'cn1', public.cancel_remittance_run('cn-martin-001', (select v from t where k = 'r1'),
                     (select version from public.remittance_run where id = (select v from t where k = 'r1')),
                     'IBAN à vérifier');
reset role;
select is((select v ->> 'status' from j where k = 'cn1'), 'cancelled', 'cancelled');
insert into t select 'c1', id from public.commission_invoice
where run_id = (select v from t where k = 'r1') and kind = 'credit_note';
select results_eq($$ select number, seq, ht_minor, vat_minor, ttc_minor, reason from public.commission_invoice
                     where id = (select v from t where k = 'c1') $$,
  $$ values ('FC-' || extract(year from private.paris_today()) || '-000003', 3, -30000::bigint, -6000::bigint,
             -36000::bigint, 'run_cancelled'::text) $$,
  'one full credit note of the invoice, the next number (never reused)');
select results_eq($$ select original_invoice_id, ht_minor, vat_minor, vat_pending_minor, vat_collected_minor,
                            applied_minor, excess_minor
                     from public.commission_credit_correction where credit_note_id = (select v from t where k = 'c1') $$,
  $$ values ((select v from t where k = 'i1'), -30000::bigint, -6000::bigint, 6000::bigint, 0::bigint, 36000::bigint,
             0::bigint) $$,
  'it names the invoice it corrects (289 I 5), its VAT off the pending VAT, applied in full');
select results_eq($$ select la.book, p.amount_minor from public.commission_invoice i
                     join public.ledger_posting p on p.entry_id = i.ledger_entry_id
                     join public.ledger_account la on la.id = p.ledger_account_id
                     where i.id = (select v from t where k = 'c1') order by p.line_no $$,
  $$ values ('commission_receivable'::text, -36000::bigint), ('servicer_revenue', 30000::bigint),
            ('vat_pending', 6000::bigint) $$,
  'its entry: −4111 / +7060 / +44574');
select is(pg_temp.bal('commission_receivable', 'a1'), 0::bigint, '4111[Martin] back to 0');
select is(private.document_open((select v from t where k = 'i1')), 0::bigint, 'the invoice closed by the credit note');
select results_eq($$ select released, (select count(*)::int from private.remittance_pending q
                                       where q.ledger_entry_id = l.ledger_entry_id and q.draft_run_id is null)
                     from public.remittance_line l where l.run_id = (select v from t where k = 'r1') $$,
  $$ values (true, 1) $$,
  'the line released, its item back in the queue');
select is((select status from public.bank_transfer where run_id = (select v from t where k = 'r1')), 'cancelled',
  'the transfer cancelled');
select results_eq($$ select cause, commission_minor, basis from public.remittance_key_state
                     where account_id = pg_temp.f('01') order by seq desc limit 1 $$,
  $$ values ('cancelled'::text, 0::bigint, '[]'::jsonb) $$,
  'the tier history as before the run');

-- The nightly checks ---------------------------------------------------------------------------------
insert into j select 'chk', private.run_payment_checks('00000000-0000-0000-0000-0000000000aa');
select is((select count(*)::int from public.payment_check_result r where r.run_id = (select (v ->> 'run_id')::uuid from j where k = 'chk')
             and r.severity = 'violation'), 0,
  'the books hold: I14 (with the runs in flight), I15, I16, I17, I18');
select is((select (v ->> 'violations')::int from j where k = 'chk'), 0, 'and the run''s count says so');
update private.invoice_counter set last_seq = 5 where organization_id = '00000000-0000-0000-0000-0000000000aa';
insert into j select 'chk2', private.run_payment_checks('00000000-0000-0000-0000-0000000000aa');
select is((select string_agg(r.code, ',') from public.payment_check_result r
           where r.run_id = (select (v ->> 'run_id')::uuid from j where k = 'chk2') and r.severity = 'violation'),
  'invoice_numbering', 'a counter ahead of its documents is found (I17)');
update private.invoice_counter set last_seq = 3 where organization_id = '00000000-0000-0000-0000-0000000000aa';
-- an old collection never remitted: a breach row and the violation (I21)
select pg_temp.file('03', '20000000-0000-0000-0000-0000000000a1', 9000);
select pg_temp.collect('03', 9000, '2026-10-05');
insert into j select 'chk3', private.run_payment_checks('00000000-0000-0000-0000-0000000000aa');
select results_eq($$ select r.code, r.subject_id from public.payment_check_result r
                     where r.run_id = (select (v ->> 'run_id')::uuid from j where k = 'chk3') and r.severity = 'violation' $$,
  $$ values ('remittance_deadline_breached'::text, '00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'E 05/10 not paid by its latest execution date: the violation');
select results_eq($$ select latest_execution_date, blocked_reason from public.remittance_deadline_breach
                     where payment_id = pg_temp.pay('03') $$,
  $$ values ('2026-11-03'::date, null::text) $$,
  'and a breach row, once');
select ok(exists (select 1 from public.payment_check_result r
                  where r.run_id = (select (v ->> 'run_id')::uuid from j where k = 'chk3')
                    and r.code = 'payout_blocked') is false, 'no draft is blocked');

-- Schedule reads -----------------------------------------------------------------------------------------
select results_eq($$ select client_organization_id, currency, payout_returned, cardinality(latest_execution_dates)
                     from private.remittance_schedule_candidates('00000000-0000-0000-0000-0000000000aa',
                                                                 private.paris_today()) $$,
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid, 'EUR'::char(3), false, 2) $$,
  'the schedule''s candidates: Martin (two items waiting, no pending run), not Lilas (booked, nothing waiting)');
select ok((select cardinality(terms) = 1 from private.remittance_schedule_candidates(
             '00000000-0000-0000-0000-0000000000aa', private.paris_today())), 'with its remittance terms in force');

-- Discard and refresh ------------------------------------------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'rq3', public.request_remittance_run('rq-martin-0003', '00000000-0000-0000-0000-0000000000a1');
reset role;
insert into t select 'r3', (v ->> 'run_id')::uuid from j where k = 'rq3';
select is((select item_count from public.remittance_run where id = (select v from t where k = 'r3')), 2,
  'a new draft takes the released item and the old one');
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok($$ select public.discard_remittance_run('ds-martin-001', (select v from t where k = 'r3'), 1, '') $$,
  '23514', 'a reason is required', 'an abandon needs a reason');
select is(public.refresh_remittance_run('rf-martin-001', (select v from t where k = 'r3'), 1) ->> 'items', '2',
  '« Actualiser »: reserved again, prepared again');
select throws_ok($$ select public.refresh_remittance_run('rf-martin-002', (select v from t where k = 'r3'), 1) $$,
  '23514', 'remittance run refused: version_changed', 'compare and set');
select is(public.discard_remittance_run('ds-martin-002', (select v from t where k = 'r3'), 2, 'reprise demain') ->> 'status',
  'cancelled', '« Abandonner »');
reset role;
select is((select count(*)::int from private.remittance_pending
           where client_organization_id = '00000000-0000-0000-0000-0000000000a1' and draft_run_id is null), 2,
  'its items back in the queue, unreserved');

-- Reads and read policies --------------------------------------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
select is(jsonb_array_length(public.remittance_overview('termines') -> 'runs'), 3,
  '« Terminés »: the cancelled, the booked and the abandoned run');
select is(public.remittance_overview('a-valider') #>> '{to_prepare,0,owed_minor}', '209000',
  '« Préparer maintenant »: Martin, 2 090,00 € waiting');
select is(public.remittance_run_detail((select v from t where k = 'r1')) #>> '{documents,1,number}',
  'FC-' || extract(year from private.paris_today()) || '-000003', 'the run''s page: its invoice and credit note');
select is((select count(*)::int from public.remittance_run), 3, 'money staff read the servicer''s runs');
select pg_temp.as_user('02');
select throws_ok($$ select public.remittance_overview() $$, '42501', null, 'a collector reads no remittance');
select is((select count(*)::int from public.remittance_run), 0, 'nor any run');
select is((select count(*)::int from public.commission_invoice), 0, 'nor any invoice');
select pg_temp.as_user('03');
select is((select count(*)::int from public.remittance_run), 1, 'Martin''s admin reads its approved run (not drafts)');
select is((select count(*)::int from public.commission_invoice), 2, 'its invoice and credit note');
select is((select count(*)::int from public.remittance_line), 1, 'its run''s line');
select is((select count(*)::int from public.remittance_key_state), 0, 'not the tier history');
select is((select count(*)::int from public.remittance_deadline_breach), 0, 'nor the breach rows');
select throws_ok($$ select public.remittance_run_detail((select v from t where k = 'r1')) $$, '42501', null,
  'nor the back office''s page');
select pg_temp.as_user('07');
select is((select count(*)::int from public.remittance_run) + (select count(*)::int from public.commission_invoice), 0,
  'a client viewer restricted to some portfolios reads none (OQ-48)');
select pg_temp.as_user('08');
select is((select string_agg(number, ',') from public.commission_invoice),
  'FC-' || extract(year from private.paris_today()) || '-000002', 'Lilas''s admin reads only Lilas''s invoice');
select pg_temp.as_user('05');
select is((select count(*)::int from public.remittance_run) + (select count(*)::int from public.commission_invoice)
          + (select count(*)::int from public.commission_settlement), 0, 'another servicer reads nothing');
select pg_temp.as_user('01');
select throws_ok($$ insert into public.commission_invoice (id) values (gen_random_uuid()) $$, '42501', null,
  'no direct write by the API');
select throws_ok($$ update public.remittance_run set cancel_reason = 'x' $$, '42501', null, 'nor an update');
select throws_ok($$ select private.approve_remittance_run((select v from t where k = 'r1'), gen_random_uuid()) $$,
  '42501', null, 'the job''s function is the worker''s');
reset role;
select ok(not has_function_privilege('authenticated', 'private.issue_commission_documents(uuid,uuid,uuid,jsonb,text)',
                                     'execute'), 'issuing documents is internal');
select ok(has_function_privilege('service_role', 'private.approve_remittance_run(uuid,uuid)', 'execute'),
  'the worker approves');
select ok((select count(*) from private.change_log where table_name = 'public.remittance_run') > 0,
  'the runs are change-logged');

select * from finish();
rollback;
