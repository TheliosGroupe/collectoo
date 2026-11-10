-- M2c-4 review fixes (runs, approval, cancellation, numbering, invoices): a late approval recorded per line with its
-- reason and date even when the nightly breach row came first (C3), an N = 0 run approved after its latest execution
-- date needs the reason and leaves its breach (money #3), the approval re-checks the VAT book (money #1) and the
-- client's proceeding (money #2) the plan assumed, a document is never numbered on a day the transaction did not begin
-- on (numbering #1), the invoice payload freezes the L441-9 mentions (legal #4), the cancellation restores the run's
-- credit notes on earlier invoices by a corrective invoice at their own VAT rate (money #0, the VAT rate changed
-- meanwhile), the line guard as a column comparison (performance #1), and the read policies of the late approvals
-- (clients A/B, a restricted viewer, a collector, another servicer). Design docs/design/m2c-remittances.md §9.5–§9.7,
-- §14; ADR-0014 M2c-4.
begin;
select plan(56);

-- Fixtures (as 021, with a third client) ----------------------------------------------------------------
insert into public.organization (id, kind, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo SAS', '732829320'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Autre cabinet SAS', null);
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Martin SAS',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Lilas Finance',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000a3', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Cèdre SA',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Bleu SARL', null);
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@review.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '07', '08']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a1', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000a2', 'client_admin');
insert into public.portfolio (id, organization_id, client_organization_id, name)
select ('20000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'P-' || c
from unnest(array['a1', 'a2', 'a3']) c;
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-0000000000a1');  -- a client viewer of P-a1 only
insert into public.bank_account (id, organization_id, purpose, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000cf', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
   'FR3430001007940000000001001', 'EUR', 'Fonds de tiers', 'camt053', '2026-01-01');
insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000aa', 'own',
   'FR7630006000011234567890189', 'AGRIFRPPXXX', 'EUR', 'Compte propre', null, '2026-01-01');
insert into public.billing_identity (organization_id, legal_form, share_capital_minor, rcs_city, registered_office,
                                     vat_number, is_professional)
select o.id, case when o.kind = 'servicer' then 'SAS' end, case when o.kind = 'servicer' then 1000000 end,
       case when o.kind = 'servicer' then 'Paris' end,
       '{"line1": "1 rue de la Paix", "postcode": "75002", "city": "Paris", "country": "FR"}',
       case when o.kind = 'servicer'
            then 'FR' || lpad(((12 + 3 * (o.siren::bigint % 97)) % 97)::text, 2, '0') || o.siren end, true
from public.organization o where o.id in ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
                                          '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3');
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-0000000000' || x.n)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || '.pdf', repeat('a', 64),
       'application/pdf'
from (values ('01', 'a1', 'mandate_document'), ('02', 'a2', 'mandate_document'), ('03', 'a1', 'payout_rib'),
             ('04', 'a2', 'payout_rib'), ('05', 'a3', 'mandate_document'), ('06', 'a3', 'payout_rib'),
             ('07', 'a3', 'client_status_evidence')) x (n, c, kind);
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on,
                            insurance_clause_ref)
select ('70000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'MAND-' || upper(c), 'mandate_amicable', '2026-01-01', 'art. 9'
from unnest(array['a1', 'a2', 'a3']) c;
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
from (values ('a1', '01'), ('a2', '02'), ('a3', '05')) x (c, d);
update public.portfolio set mandate_id = ('70000000-0000-0000-0000-0000000000' || right(id::text, 2))::uuid
where id::text like '20000000-0000-0000-0000-0000000000a%';
insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                          evidence_document_id, proposed_by)
select ('90000000-0000-0000-0000-0000000000' || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, 'EUR', x.iban, x.holder,
       ('d0000000-0000-0000-0000-0000000000' || x.d)::uuid, '10000000-0000-0000-0000-000000000004'
from (values ('a1', '03', 'FR7630004000031234567890143', 'MARTIN SAS'),
             ('a2', '04', 'FR1420041010050500013M02606', 'LILAS FINANCE'),
             ('a3', '06', 'FR7610107001011234567890129', 'CEDRE SA')) x (c, d, iban, holder);
update public.client_payout_account set status = 'active', confirmed_at = now(), confirmed_via = 'client_portal',
  confirmed_by = '10000000-0000-0000-0000-000000000003'
where id::text like '90000000-0000-0000-0000-0000000000a%';

create or replace function pg_temp.f(p_n text) returns uuid language sql as $$
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.it(p_n text) returns uuid language sql as $$
  select ('c1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.pay(p_n text) returns uuid language sql as $$
  select ('f1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.c(p_c text) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000000' || p_c)::uuid;
$$;
-- A file with one invoice owed (opening as an adjustment).
create or replace function pg_temp.file(p_n text, p_client text, p_amount bigint) returns void language plpgsql as $$
begin
  insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                              legal_regime, currency, status)
  values (pg_temp.f(p_n), '00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_client),
          ('20000000-0000-0000-0000-0000000000' || p_client)::uuid, 'b2b_invoice', 'D-' || p_n, 'commercial_b2b', 'EUR',
          'in_collection');
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type,
                                             valid_from)
  values (pg_temp.f(p_n), pg_temp.c(p_client), '00000000-0000-0000-0000-0000000000aa', 'mandate_amicable', '2026-09-01');
  insert into public.claim_item (id, account_id, kind, ref, due_date, original_minor)
  values (pg_temp.it(p_n), pg_temp.f(p_n), 'invoice', 'F-' || p_n, '2026-08-01', p_amount);
  perform private.ledger_post('00000000-0000-0000-0000-0000000000aa', 'adjustment', '2026-09-01', 'review-owe-' || p_n,
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
-- What the prepare job writes (emulated): one draft line per reserved item (its commission from `p_commissions` by
-- entry, else 0; charged and invoiced when not 0; its latest execution date 27 days after its date), the documents,
-- key states and plan given, then the header (`p_header` adds to it: vat_on_debits, proceeding_opened_on).
create or replace function pg_temp.prepare(p_run uuid, p_commissions jsonb, p_docs jsonb, p_keys jsonb, p_plan jsonb,
                                           p_header jsonb default '{}')
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
         e.effective_date, e.effective_date, q.posted_at,
         case when q.amount_minor > 0 then e.effective_date + 30 end,
         case when q.amount_minor > 0 then e.effective_date + 27 end, q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text),
         coalesce((p_commissions ->> q.ledger_entry_id::text)::bigint, 0),
         case when coalesce((p_commissions ->> q.ledger_entry_id::text)::bigint, 0) <> 0 then 'charged' else 'none' end,
         '[]', coalesce((p_commissions ->> q.ledger_entry_id::text)::bigint, 0) > 0
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
    'inputs_hash', encode(sha256(convert_to(p_run::text || p_plan::text || r.version, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', p_docs, 'key_states', p_keys, 'plan', p_plan) || p_header);
  return (select version from public.remittance_run where id = p_run);
end $$;
-- One invoice of a client's mandate, `p_ht` HT at 20 %, charging the file's key, netted or due in 30 days.
create or replace function pg_temp.invoice(p_client text, p_file text, p_ht bigint, p_settlement text default 'netted')
returns jsonb language sql as $$
  select jsonb_build_object(
    'ref', 'new:70000000-0000-0000-0000-0000000000' || p_client, 'kind', 'invoice',
    'mandate_id', '70000000-0000-0000-0000-0000000000' || p_client, 'ht', p_ht::text,
    'vat', round(p_ht * 0.2)::bigint::text, 'ttc', (p_ht + round(p_ht * 0.2)::bigint)::text, 'vat_rate', '0.2',
    'settlement', p_settlement, 'due_days', case when p_settlement = 'due' then 30 end, 'clause_ref', 'art. 7.2',
    'lines', jsonb_build_array(jsonb_build_object('kind', 'commission', 'designation_fr', 'Commission (test)',
      'claim_type', 'b2b_invoice', 'rule_id', 'tout', 'families', '["principal"]'::jsonb,
      'tiers', jsonb_build_array(jsonb_build_array('0.15', (p_ht / 0.15)::bigint::text)), 'ht', p_ht::text,
      'vat_rate', '0.2')),
    'charges', jsonb_build_array(jsonb_build_object('account_id', pg_temp.f(p_file), 'tier_key', 'tout',
                                                    'amount', p_ht::text)));
$$;
-- A plan that sets off the run's new invoice of `p_ttc` (its VAT `p_vat` moved unless on debits), N = gross − TTC.
create or replace function pg_temp.plan(p_client text, p_gross bigint, p_ht bigint, p_vat_moved boolean default true)
returns jsonb language sql as $$
  select jsonb_build_object('settles', jsonb_build_array(jsonb_build_object(
           'ref', 'new:70000000-0000-0000-0000-0000000000' || p_client, 'kind', 'compensation',
           'mandate_id', '70000000-0000-0000-0000-0000000000' || p_client,
           'amount', (p_ht + round(p_ht * 0.2)::bigint)::text,
           'vat_moved', case when p_vat_moved then round(p_ht * 0.2)::bigint else 0 end::text,
           'open_before', (p_ht + round(p_ht * 0.2)::bigint)::text)),
         'net', (p_gross - p_ht - round(p_ht * 0.2)::bigint)::text,
         'settlement', (p_ht + round(p_ht * 0.2)::bigint)::text, 'dc', (p_ht + round(p_ht * 0.2)::bigint)::text,
         'da', '0', 'vat_moved', case when p_vat_moved then round(p_ht * 0.2)::bigint else 0 end::text,
         'deferred', false, 'invoice_ht', p_ht::text, 'invoice_vat', round(p_ht * 0.2)::bigint::text,
         'invoice_ttc', (p_ht + round(p_ht * 0.2)::bigint)::text);
$$;
create or replace function pg_temp.key(p_file text, p_basis bigint, p_commission bigint) returns jsonb language sql as $$
  select jsonb_build_object('account_id', pg_temp.f(p_file), 'tier_key', 'tout',
    'basis', case when p_basis = 0 then '[]'::jsonb
                  else jsonb_build_array(jsonb_build_array('71000000-0000-0000-0000-0000000000a1', p_basis::text)) end,
    'kept_basis', '0', 'kept', '0', 'commission', p_commission::text);
$$;
create or replace function pg_temp.item(p_run uuid) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('run_id', r.id, 'inputs_hash', r.inputs_hash, 'net_text', r.net_minor::text))
  from public.remittance_run r where r.id = p_run;
$$;
create or replace function pg_temp.job(p_run uuid) returns jsonb language sql as $$
  select private.approve_remittance_run(p_run, (select job_token from public.remittance_run where id = p_run));
$$;
create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
create or replace function pg_temp.request(p_client text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := (public.request_remittance_run(p_key, pg_temp.c(p_client)) ->> 'run_id')::uuid;
  reset role;
  return v;
end $$;
create or replace function pg_temp.approve(p_key text, p_items jsonb, p_reason text default null) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.approve_remittance_runs(p_key, p_items, null, p_reason);
  reset role;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
create temporary table t (k text primary key, v uuid) on commit drop;
grant all on t to authenticated;
create temporary table j (k text primary key, v jsonb) on commit drop;
grant all on j to authenticated;

-- A late N > 0 approval: recorded per line with its reason, although the nightly breach row came first (C3) --------
select pg_temp.file('01', 'a1', 200000);
select pg_temp.collect('01', 200000, private.paris_today() - 40);    -- its latest execution date 13 days ago
insert into t select 'e1', id from public.ledger_entry where payment_id = pg_temp.pay('01') and entry_type = 'allocation';
insert into t values ('r1', pg_temp.request('a1', 'rq-r1-review'));
select pg_temp.prepare((select v from t where k = 'r1'), jsonb_build_object((select v from t where k = 'e1'), 30000),
                       jsonb_build_array(pg_temp.invoice('a1', '01', 30000)),
                       jsonb_build_array(pg_temp.key('01', 200000, 30000)), pg_temp.plan('a1', 200000, 30000));
-- the nightly check ran first: the item's breach row, without run, date or reason
insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                               deadline, latest_execution_date)
values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'), (select v from t where k = 'e1'), pg_temp.pay('01'),
        private.paris_today() - 10, private.paris_today() - 13);
select is(pg_temp.approve('ap-r1-1-review', pg_temp.item((select v from t where k = 'r1'))) #>> '{results,0,reason}',
  'late_reason_required', 'after the latest execution date the approval needs a reason');
select is(pg_temp.approve('ap-r1-2-review', pg_temp.item((select v from t where k = 'r1')),
                          'Encaissement identifié tardivement') #>> '{results,0,status}',
  'queued', 'with it, queued');
select is(pg_temp.job((select v from t where k = 'r1')) ->> 'status', 'approved', 'approved, paying late');
select results_eq($$ select ledger_entry_id, latest_execution_date, requested_execution_date, late_reason, approved_by
                     from public.remittance_late_approval where run_id = (select v from t where k = 'r1') $$,
  $$ values ((select v from t where k = 'e1'), private.paris_today() - 13,
             private.next_business_day(private.paris_today()), 'Encaissement identifié tardivement'::text,
             '10000000-0000-0000-0000-000000000001'::uuid) $$,
  'the late approval recorded: the line, its latest and requested execution dates, the reason, the approver');
select results_eq($$ select run_id, requested_execution_date, late_reason from public.remittance_deadline_breach
                     where ledger_entry_id = (select v from t where k = 'e1') $$,
  $$ values (null::uuid, null::date, null::text) $$,
  'the nightly''s breach row stays as written (append-only, one per item): the late approval is apart');

-- An N = 0 run approved after its latest execution date (money #3) ---------------------------------------------
select pg_temp.file('02', 'a2', 120000);
select pg_temp.collect('02', 120000, private.paris_today() - 40);
insert into t select 'e2', id from public.ledger_entry where payment_id = pg_temp.pay('02') and entry_type = 'allocation';
insert into t values ('r2', pg_temp.request('a2', 'rq-r2-review'));
select pg_temp.prepare((select v from t where k = 'r2'), jsonb_build_object((select v from t where k = 'e2'), 100000),
                       jsonb_build_array(pg_temp.invoice('a2', '02', 100000)),
                       jsonb_build_array(pg_temp.key('02', 120000, 100000)), pg_temp.plan('a2', 120000, 100000));
select is((select net_minor from public.remittance_run where id = (select v from t where k = 'r2')), 0::bigint,
  '(N = 0: the commission takes the whole gross)');
select is(pg_temp.approve('ap-r2-1-review', pg_temp.item((select v from t where k = 'r2'))) #>> '{results,0,reason}',
  'late_reason_required', 'N = 0 settles today: after the latest execution date it needs the reason too');
select is(pg_temp.approve('ap-r2-2-review', pg_temp.item((select v from t where k = 'r2')), 'Relevé importé tardivement')
          #>> '{results,0,status}', 'queued', 'with it, queued');
select results_eq($$ select late_reason, requested_execution_date from public.remittance_run
                     where id = (select v from t where k = 'r2') $$,
  $$ values ('Relevé importé tardivement'::text, null::date) $$,
  'its reason kept on the run (no transfer, no execution date)');
update public.remittance_run set late_reason = null where id = (select v from t where k = 'r2');
select is(pg_temp.job((select v from t where k = 'r2')) ->> 'reason', 'late_reason_required',
  'the job re-checks it (N = 0 and late without a reason: back to draft)');
select is(pg_temp.approve('ap-r2-3-review', pg_temp.item((select v from t where k = 'r2')), 'Relevé importé tardivement')
          #>> '{results,0,status}', 'queued', 'queued again');
select is(pg_temp.job((select v from t where k = 'r2')) ->> 'status', 'booked', 'booked: the settlement posted today');
select results_eq($$ select run_id, latest_execution_date, requested_execution_date, late_reason
                     from public.remittance_deadline_breach where ledger_entry_id = (select v from t where k = 'e2') $$,
  $$ values ((select v from t where k = 'r2'), private.paris_today() - 13, private.paris_today(),
             'Relevé importé tardivement'::text) $$,
  'the breach recorded, the settlement date as the execution date (I21: « settled when N = 0 »)');
select results_eq($$ select requested_execution_date, late_reason from public.remittance_late_approval
                     where run_id = (select v from t where k = 'r2') $$,
  $$ values (private.paris_today(), 'Relevé importé tardivement'::text) $$,
  'and its late approval');

-- The VAT book the plan assumed (money #1) ------------------------------------------------------------------------
select pg_temp.file('04', 'a2', 100000);
select pg_temp.collect('04', 100000, private.paris_today() - 3);
insert into t select 'e4', id from public.ledger_entry where payment_id = pg_temp.pay('04') and entry_type = 'allocation';
insert into t values ('r3', pg_temp.request('a2', 'rq-r3-review'));
select pg_temp.prepare((select v from t where k = 'r3'), jsonb_build_object((select v from t where k = 'e4'), 15000),
                       jsonb_build_array(pg_temp.invoice('a2', '04', 15000)),
                       jsonb_build_array(pg_temp.key('04', 100000, 15000)), pg_temp.plan('a2', 100000, 15000, false),
                       '{"vat_on_debits": true}');
select is((select vat_on_debits from private.remittance_draft where run_id = (select v from t where k = 'r3')), true,
  'the draft records the VAT book its plan assumed (VAT on debits: nothing moves from 44574)');
select is(pg_temp.approve('ap-r3-1-review', pg_temp.item((select v from t where k = 'r3'))) #>> '{results,0,status}', 'queued',
  'queued');
select is(pg_temp.job((select v from t where k = 'r3')) ->> 'reason', 'vat_option_changed',
  'the servicer is not on debits: the plan''s VAT book is not the invoice''s → back to draft');
insert into public.servicer_billing_settings (organization_id, vat_on_debits, own_bank_account_id)
values ('00000000-0000-0000-0000-0000000000aa', true, '80000000-0000-0000-0000-0000000000a0');
select is(pg_temp.approve('ap-r3-2-review', pg_temp.item((select v from t where k = 'r3'))) #>> '{results,0,status}', 'queued',
  'on debits now: queued again');
select is(pg_temp.job((select v from t where k = 'r3')) ->> 'status', 'approved', 'approved');
select results_eq($$ select i.vat_book, (select sum(p.amount_minor) from public.ledger_posting p
                                         join public.ledger_account la on la.id = p.ledger_account_id
                                         where p.entry_id = i.ledger_entry_id and la.book = 'vat_collected')
                     from public.commission_invoice i where i.run_id = (select v from t where k = 'r3') $$,
  $$ values ('vat_collected'::text, -3000::numeric) $$,
  'the invoice booked as the plan assumed: its VAT due at once (44571)');
update public.servicer_billing_settings set vat_on_debits = false
where organization_id = '00000000-0000-0000-0000-0000000000aa';

-- The client's proceeding the plan assumed (money #2) -------------------------------------------------------------
select pg_temp.file('05', 'a3', 100000);
select pg_temp.collect('05', 100000, private.paris_today() - 3);
insert into t select 'e5', id from public.ledger_entry where payment_id = pg_temp.pay('05') and entry_type = 'allocation';
insert into t values ('r4', pg_temp.request('a3', 'rq-r4-review'));
select pg_temp.prepare((select v from t where k = 'r4'), jsonb_build_object((select v from t where k = 'e5'), 15000),
                       jsonb_build_array(pg_temp.invoice('a3', '05', 15000)),
                       jsonb_build_array(pg_temp.key('05', 100000, 15000)), pg_temp.plan('a3', 100000, 15000));
select is(pg_temp.approve('ap-r4-1-review', pg_temp.item((select v from t where k = 'r4'))) #>> '{results,0,status}', 'queued',
  'Cèdre''s draft queued');
insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                        evidence_document_id, recorded_by)
values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a3'), 'proceeding_opened', private.paris_today(),
        'd0000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000004');
select is(pg_temp.job((select v from t where k = 'r4')) ->> 'reason', 'client_status_changed',
  'a proceeding recorded after the draft: its set-offs are prepared again (L622-7 I) → back to draft');
select is((select count(*)::int from public.commission_invoice where run_id = (select v from t where k = 'r4')), 0,
  'nothing numbered');

-- The day a document is numbered (numbering #1) -------------------------------------------------------------------
savepoint day_turned;
-- a transaction that began yesterday (Paris) and numbers after midnight
create or replace function private.paris_today() returns date language sql stable set search_path = '' as $$
  select (now() at time zone 'Europe/Paris')::date - 1 $$;
select throws_ok($$ select private.issue_commission_documents('00000000-0000-0000-0000-0000000000aa',
                     '00000000-0000-0000-0000-0000000000a3', null,
                     jsonb_build_array((pg_temp.invoice('a3', '05', 1000) - 'charges') || '{"id": "e3000000-0000-0000-0000-000000000001",
                                                                          "key": "day-turned-1"}'), 'commission') $$,
  '40001', null, 'numbered on another day than the transaction''s: retried in a fresh one, never refused as data');
rollback to savepoint day_turned;

-- The payload freezes the mentions in force at issue (legal #4) ----------------------------------------------------
select results_eq($$ select i.payload ->> 'penalty_text' like 'Pénalités de retard : %',
                            i.payload -> 'flat_indemnity', i.payload ->> 'due_date', i.payload -> 'payment_reference',
                            i.payload -> 'own_account'
                     from public.commission_invoice i where i.run_id = (select v from t where k = 'r1') $$,
  $$ values (true, '{"applies": true, "amount_minor": "4000"}'::jsonb, null::text,
             jsonb_build_object('run_number', (select number from public.remittance_run where id = (select v from t where k = 'r1')),
                                'execution_date', private.next_business_day(private.paris_today())),
             'null'::jsonb) $$,
  'a netted invoice: the penalty rate, the 40 € indemnity (professional buyer, L441-10 II), set off on the payout''s date');
select is((select payload -> 'payment_reference' ->> 'execution_date' from public.commission_invoice
           where run_id = (select v from t where k = 'r2')), private.paris_today()::text,
  'N = 0: paid by set-off on the approval date');
insert into j select 'due', private.issue_commission_documents('00000000-0000-0000-0000-0000000000aa',
  '00000000-0000-0000-0000-0000000000a1', null,
  jsonb_build_array((pg_temp.invoice('a1', '01', 2000, 'due') - 'charges') || '{"id": "e3000000-0000-0000-0000-000000000002",
                                                               "key": "due-invoice-0001"}'), 'commission');
select results_eq($$ select i.due_date, (i.payload ->> 'due_date')::date, i.payload -> 'own_account'
                     from public.commission_invoice i where i.id = 'e3000000-0000-0000-0000-000000000002' $$,
  $$ values (private.paris_today() + 30, private.paris_today() + 30,
             '{"iban": "FR7630006000011234567890189", "bic": "AGRIFRPPXXX", "holder": "Collectoo SAS"}'::jsonb) $$,
  'a due invoice: its date and the servicer''s own account to pay, read at issue');
select is((select payload_sha256 from public.commission_invoice where id = 'e3000000-0000-0000-0000-000000000002'),
  (select encode(sha256(convert_to(payload::text, 'UTF8')), 'hex') from public.commission_invoice
   where id = 'e3000000-0000-0000-0000-000000000002'), 'the hash covers them');
select private.issue_commission_documents('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a3',
  null, jsonb_build_array((pg_temp.invoice('a3', '05', 2000) - 'charges') || '{"id": "e3000000-0000-0000-0000-000000000003",
                                                              "key": "proceeding-0001"}'), 'commission');
select is((select payload -> 'flat_indemnity' from public.commission_invoice
           where id = 'e3000000-0000-0000-0000-000000000003'), '{"applies": false, "amount_minor": null}'::jsonb,
  'not claimed while the client''s proceeding is open');

-- The cancellation restores the run's credit notes on earlier invoices (money #0) ----------------------------------
-- Martin's first run debited (emulated M2c-6): FC-1 charges file 01 30 000; then file 01's collection undone and a
-- new collection on file 06: an invoice (06) and a credit note of 30 000 on FC-1 (01)
update public.remittance_run set status = 'booked', booked_on = private.paris_today()
where id = (select v from t where k = 'r1');
insert into t select 'i1', id from public.commission_invoice where run_id = (select v from t where k = 'r1');
select pg_temp.as_user('01');
set local role authenticated;
select public.reverse_allocation('rev-review-01', pg_temp.pay('01'), pg_temp.f('01'),
                                 array[(select v from t where k = 'e1')], 'paiement repris par la banque');
reset role;
insert into t select 'x1', id from public.ledger_entry where reverses_entry_id = (select v from t where k = 'e1');
select pg_temp.file('06', 'a1', 300000);
select pg_temp.collect('06', 300000, private.paris_today() - 2);
insert into t select 'e6', id from public.ledger_entry where payment_id = pg_temp.pay('06') and entry_type = 'allocation';
insert into t values ('r5', pg_temp.request('a1', 'rq-r5-review'));
insert into j values ('crn5', jsonb_build_object(
  'ref', 'crn:70000000-0000-0000-0000-0000000000a1', 'kind', 'credit_note',
  'mandate_id', '70000000-0000-0000-0000-0000000000a1', 'ht', '-30000', 'vat', '-6000', 'ttc', '-36000',
  'settlement', 'netted', 'clause_ref', 'art. 7.2',
  'lines', jsonb_build_array(jsonb_build_object('kind', 'credit', 'designation_fr', 'Avoir rectifiant (test)',
                                                'ht', '-30000', 'vat_rate', '0.2',
                                                'original_invoice_id', (select v from t where k = 'i1'))),
  'allocations', jsonb_build_array(jsonb_build_object('original_invoice_id', (select v from t where k = 'i1'),
                                                      'account_id', pg_temp.f('01'), 'tier_key', 'tout', 'ht', '-30000',
                                                      'entry_id', (select v from t where k = 'x1'))),
  'corrections', jsonb_build_array(jsonb_build_object('original_invoice_id', (select v from t where k = 'i1'),
                                                      'vat_rate', '0.2', 'ht', '-30000', 'vat', '-6000',
                                                      'vat_pending', '6000', 'vat_collected', '0', 'applied', '36000',
                                                      'excess', '0', 'open_before', '36000'))));
select pg_temp.prepare((select v from t where k = 'r5'),
                       jsonb_build_object((select v from t where k = 'e6'), 45000, (select v from t where k = 'x1'), -30000),
                       jsonb_build_array(pg_temp.invoice('a1', '06', 45000), (select v from j where k = 'crn5')),
                       jsonb_build_array(pg_temp.key('01', 0, 0), pg_temp.key('06', 300000, 45000)),
                       pg_temp.plan('a1', 100000, 45000));
select is(pg_temp.approve('ap-r5-1-review', pg_temp.item((select v from t where k = 'r5'))) #>> '{results,0,status}', 'queued',
  'Martin''s second run (a collection and a reversal) queued');
select is(pg_temp.job((select v from t where k = 'r5')) ->> 'status', 'approved', 'approved: an invoice and a credit note');
-- the VAT rate changes before the cancellation (10 % from today): the restoring invoice keeps the credited invoice's
alter table public.vat_rate disable trigger vat_rate_guard;
update public.vat_rate set valid_to = private.paris_today() where valid_from = '2014-01-01';
insert into public.vat_rate (code, territory, rate, valid_from, valid_to, legal_ref, legal_url)
values ('standard', 'FR-metro', 0.1000, private.paris_today(), '2027-01-01', 'test',
        'https://librejustice.fr/norm/fr/code-general-des-impots/278');
alter table public.vat_rate enable always trigger vat_rate_guard;
select pg_temp.as_user('04');
set local role authenticated;
insert into j select 'cn5', public.cancel_remittance_run('cn-r5-review', (select v from t where k = 'r5'),
                     (select version from public.remittance_run where id = (select v from t where k = 'r5')),
                     'IBAN à vérifier');
reset role;
select results_eq($$ select kind, reason, ht_minor, vat_minor, vat_rate from public.commission_invoice
                     where run_id = (select v from t where k = 'r5') order by seq $$,
  $$ values ('invoice'::text, 'commission'::text, 45000::bigint, 9000::bigint, 0.2000::numeric),
            ('credit_note', 'commission', -30000::bigint, -6000::bigint, null::numeric),
            ('credit_note', 'run_cancelled', -45000::bigint, -9000::bigint, null::numeric),
            ('invoice', 'run_cancelled', 30000::bigint, 6000::bigint, 0.2000::numeric) $$,
  'cancelled: its invoice credited in full, its credit note on FC-1 restored at FC-1''s own rate (not today''s 10 %)');
insert into t select 'j5', id from public.commission_invoice
where run_id = (select v from t where k = 'r5') and kind = 'invoice' and reason = 'run_cancelled';
select is((select designation_fr from public.commission_invoice_line where invoice_id = (select v from t where k = 'j5')),
  'Annulation du reversement ' || (select number from public.remittance_run where id = (select v from t where k = 'r5'))
  || ' — rétablissement de l''avoir ' || (select number from public.commission_invoice
                                         where run_id = (select v from t where k = 'r5') and kind = 'credit_note'
                                           and reason = 'commission')
  || ' (facture ' || (select number from public.commission_invoice where id = (select v from t where k = 'i1'))
  || ' du ' || to_char((select issue_date from public.commission_invoice where id = (select v from t where k = 'i1')),
                       'DD/MM/YYYY') || ')',
  'its line names the run cancelled, the credit note it restores and the invoice that credit note corrected');
select results_eq($$ select account_id, tier_key, charged_minor from public.commission_invoice_charge
                     where invoice_id = (select v from t where k = 'j5') $$,
  $$ values (pg_temp.f('01'), 'tout'::text, 30000::bigint) $$,
  'it charges the key again what the credit note took back');
select results_eq($$ select account_id, commission_minor from (
                       select distinct on (account_id) account_id, commission_minor, cause from public.remittance_key_state
                       where account_id in (pg_temp.f('01'), pg_temp.f('06')) order by account_id, seq desc) k
                     order by account_id $$,
  $$ values (pg_temp.f('01'), 30000::bigint), (pg_temp.f('06'), 0::bigint) $$,
  'the tier history exactly as before the run');
select is((select sum(ch.charged_minor + coalesce((select sum(a.ht_minor) from public.commission_credit_alloc a
                                                   where a.original_invoice_id = ch.invoice_id
                                                     and a.account_id = ch.account_id and a.tier_key = ch.tier_key), 0))
           from public.commission_invoice_charge ch where ch.account_id = pg_temp.f('01') and ch.tier_key = 'tout')::bigint,
  30000::bigint, 'and what the invoices still charge the key is that commission (Σ open charges = the state)');
select is((select sum(private.document_open(i.id) * case i.kind when 'invoice' then 1 else -1 end)
           from public.commission_invoice i where i.client_organization_id = pg_temp.c('a1')),
          (select sum(p.amount_minor) from public.ledger_account la
           join public.ledger_posting p on p.ledger_account_id = la.id
           where la.book = 'commission_receivable' and la.client_organization_id = pg_temp.c('a1')),
  'the open documents are 4111 (I18)');
select results_eq($$ select released, count(*)::int from public.remittance_line
                     where run_id = (select v from t where k = 'r5') group by released $$,
  $$ values (true, 2) $$, 'the lines released (the guard''s release path)');

-- The line guard (performance #1) ------------------------------------------------------------------------------------
select throws_ok($$ update public.remittance_line set released_at = now() where run_id = (select v from t where k = 'r5') $$,
  '23514', null, 'a released line never changes again');
select throws_ok($$ update public.remittance_line set parts = '[]' where run_id = (select v from t where k = 'r3') $$,
  '23514', null, 'a live line changes only by its release');
select throws_ok($$ update public.remittance_line set released = true, released_at = now(), amount_minor = 1
                    where run_id = (select v from t where k = 'r3') $$,
  '23514', null, 'nor with it');
select throws_ok($$ delete from public.remittance_line where run_id = (select v from t where k = 'r3') $$,
  '23514', null, 'nor is deleted');
-- what the per-row foreign keys checked, now once per run or pair of the statement (stronger: the run's own)
select throws_ok($$ insert into public.remittance_line (run_id, line_no, organization_id, client_organization_id, currency,
                      ledger_entry_id, kind, effective_date, posted_at, amount_minor, commission_state)
                    values ((select v from t where k = 'r4'), 99, '00000000-0000-0000-0000-0000000000bb',
                            '00000000-0000-0000-0000-0000000000a3', 'EUR', (select v from t where k = 'e5'), 'allocation',
                            current_date, now(), 100000, 'none') $$,
  '23514', 'remittance line: its run''s servicer, client and currency', 'a line is its run''s servicer''s');
select throws_ok($$ insert into public.remittance_key_state (organization_id, client_organization_id, account_id,
                      tier_key, run_id, cause)
                    values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
                            pg_temp.f('01'), 'tout', (select v from t where k = 'r1'), 'approved') $$,
  '23514', 'remittance key state: its run''s servicer and client', 'a key state is its run''s client''s');
select throws_ok($$ insert into public.commission_credit_alloc (credit_note_id, line_no, original_invoice_id, account_id,
                      tier_key, ht_minor)
                    values ((select v from t where k = 'i1'), 1, (select v from t where k = 'i1'), pg_temp.f('01'), 'tout',
                            -1) $$,
  '23514', 'commission credit allocation: a credit note on an invoice of its client',
  'a credit allocation is a credit note''s, on an invoice');
select is((select count(*)::int from information_schema.columns
           where table_schema = 'public' and table_name = 'remittance_line'), 28,
  'remittance_line has the 28 columns its guard compares (26) or releases (2)');

-- Who reads the late approvals -------------------------------------------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
select is((select count(*)::int from public.remittance_late_approval), 2, 'money staff read the servicer''s');
select throws_ok($$ insert into public.remittance_late_approval (run_id, ledger_entry_id, organization_id,
                      client_organization_id, latest_execution_date, requested_execution_date, late_reason)
                    values ((select v from t where k = 'r1'), (select v from t where k = 'e6'),
                            '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
                            '2026-01-01', '2026-01-02', 'x') $$,
  '42501', null, 'no direct write by the API');
select pg_temp.as_user('03');
select is((select count(*)::int from public.remittance_late_approval where run_id = (select v from t where k = 'r1')), 1,
  'Martin''s admin reads its own');
select is((select count(*)::int from public.remittance_late_approval where run_id = (select v from t where k = 'r2')), 0,
  'not Lilas''s');
select pg_temp.as_user('08');
select is((select string_agg(run_id::text, ',') from public.remittance_late_approval),
  (select v from t where k = 'r2')::text, 'Lilas''s admin reads only Lilas''s');
select pg_temp.as_user('07');
select is((select count(*)::int from public.remittance_late_approval), 0,
  'a client viewer restricted to some portfolios reads none (OQ-48)');
select pg_temp.as_user('02');
select is((select count(*)::int from public.remittance_late_approval), 0, 'nor a collector');
select pg_temp.as_user('05');
select is((select count(*)::int from public.remittance_late_approval), 0, 'nor another servicer');
reset role;
select throws_ok($$ update public.remittance_late_approval set late_reason = 'autre' $$, '23514', null,
  'a late approval never changes (append-only)');
select ok(not has_function_privilege('authenticated',
                                     'private.issue_commission_documents(uuid,uuid,uuid,jsonb,text,boolean)', 'execute'),
  'issuing documents is internal');

select * from finish();
rollback;
