-- M2c-5 review fixes: the documents' figures and wording that the review found wrong, through the database.
--   * legal#4, figures#4 — an approval's invoice names what the run's plan sets off on its payout and the remainder's
--     latest date (also its due_date, and invoice_overdue once it passes); legal#5 — N = 0 frozen as « no transfer »;
--   * legal#6 — a late line's cause in the payload, never the approver's free text;
--   * figures#2, legal#3, figures#3 — the money not remitted as of K: payments after K left out, a refund that came
--     back before K held again (not « restitué »), one that came back after K still refunded at K;
--   * tests-ui#5 (K2) — the client summary's in-flight runs per currency; perf#4 — the statement's list columns;
--   * legal#2, figures#0, figures#6 — a run cancelled before its statement is drawn: nothing set off, the gross owed;
--   * perf#2 (K4) — a failed document recorded and retried, the others drawn; the nightly alerts; the hourly queue;
--   * perf#0 (K1), perf#1, figures#7 — the accountant's export by keyed pages, sources by key, settled as of the end;
--   * legal#0 — the 40 € flat indemnity frozen as applying to a professional buyer, a proceeding kept beside it.
-- Design docs/design/m2c-remittances.md §9.6, §10, §14, §15; ADR-0014 M2c-5 (review fixes).
begin;
select plan(39);

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
                                           p_vat numeric default 0.2, p_latest_days integer default 27)
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
         e.effective_date, e.effective_date, q.posted_at, e.effective_date + 30, e.effective_date + p_latest_days, q.amount_minor,
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
-- A payment received on a file (its line, the payment, its cash_in) and matched to it, not allocated (held on 4710).
create or replace function pg_temp.receive(p_n text, p_file text, p_amount bigint, p_reason text default null)
returns void language plpgsql as $$
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
          p_amount, 'EUR', private.paris_today() - 2, 'debtor_credit', 'E2E-' || p_n);
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, payer_name, payer_iban, end_to_end_id, created_at)
  values (pg_temp.pay(p_n), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s,
          'camt053', 'sct', p_amount, 'EUR', private.paris_today() - 2, 'PAYEUR ' || p_n, 'FR7630006000011234567890189',
          'E2E-' || p_n, clock_timestamp());
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_in', private.paris_today() - 2,
          'cash_in:' || s || ':' || (private.paris_today() - 2), 'bank_statement', s::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cf'),
    (1, 2, 'unallocated_payment', -p_amount, 'EUR', null);
  perform private.ledger_post_set();
  update public.payment set account_id = pg_temp.f(p_file), status = 'matched', match_method = 'rf_structured',
                            matched_at = clock_timestamp(), review_reason = p_reason
  where id = pg_temp.pay(p_n);
end $$;
-- A bank line on the dedicated account (a statement of its own).
create or replace function pg_temp.line(p_n text, p_direction text, p_kind text, p_amount bigint, p_e2e text)
returns uuid language plpgsql as $$
declare s uuid := md5('doc-line-' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 'r',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, original_end_to_end_id,
                                       return_reason)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, 1, 'h:' || s || '#1',
          p_direction, p_amount, 'EUR', private.paris_today() - 1, p_kind, p_e2e,
          case when p_kind = 'return' then p_e2e end, case when p_kind = 'return' then 'MD06' end);
  return s;
end $$;
create or replace function pg_temp.refund_of(p_n text) returns uuid language sql as $$
  select id from public.refund_request where payment_id = pg_temp.pay(p_n) order by requested_at desc, id limit 1;
$$;
-- A payment's overpayment refunded to the payer: asked by ops, its RFD debit linked by the debit job (cash_out).
create or replace function pg_temp.refund(p_n text, p_amount bigint) returns void language plpgsql as $$
declare v_line uuid;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.request_refund('k-doc-refund-' || p_n, pg_temp.pay(p_n), p_amount::text, null, null, 'overpayment',
                                'overpayment', p_amount::text, 'trop perçu');
  reset role;
  v_line := pg_temp.line('r' || p_n, 'debit', 'refund_out', p_amount,
                         (select end_to_end_id from public.refund_request where id = pg_temp.refund_of(p_n)));
  perform private.debit_link_begin();
  insert into pg_temp._debit_link (ord, bank_transaction_id, kind, refund_request_id, method)
  values (1, v_line, 'refund', pg_temp.refund_of(p_n), 'auto');
  perform private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
end $$;
-- The refund came back unpaid: ops link the credit (its cash_out reversed, the money held again).
create or replace function pg_temp.bounce(p_n text, p_amount bigint) returns void language plpgsql as $$
declare v_line uuid;
begin
  v_line := pg_temp.line('b' || p_n, 'credit', 'return', p_amount,
                         (select end_to_end_id from public.refund_request where id = pg_temp.refund_of(p_n)));
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.link_debit('k-doc-bounce-' || p_n, v_line, 'refund_returned', null, pg_temp.refund_of(p_n), null,
                            'IBAN clôturé');
  reset role;
end $$;
grant execute on all functions in schema pg_temp to authenticated;

update public.billing_identity set invoice_acceptance_ref = 'art. 11 du mandat'
where organization_id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.file('01', '20000000-0000-0000-0000-0000000000a1', 200000);
select pg_temp.file('02', '20000000-0000-0000-0000-0000000000a2', 512000);
select pg_temp.collect('01', 200000, private.paris_today() - 3);
select pg_temp.collect('02', 512000, private.paris_today() - 3);
-- before K, on Martin's file: 70,00 € matched and waiting; 50,00 € refunded then back unpaid; 40,00 € refunded
select pg_temp.receive('03', '01', 7000);
select pg_temp.receive('05', '01', 5000, 'overpayment');
select pg_temp.refund('05', 5000);
select pg_temp.bounce('05', 5000);
select pg_temp.receive('06', '01', 4000, 'overpayment');
select pg_temp.refund('06', 4000);
select is((select string_agg(status, ',' order by payment_id) from public.refund_request
           where payment_id in (pg_temp.pay('05'), pg_temp.pay('06'))),
  'bounced,executed', 'fixture: one refund came back before K, one is out');

-- K: Martin's run and Lilas's run
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'rq1', public.request_remittance_run('rq-doc26-martin', '00000000-0000-0000-0000-0000000000a1');
insert into j select 'rq2', public.request_remittance_run('rq-doc26-lilas', '00000000-0000-0000-0000-0000000000a2');
reset role;
insert into t select 'r1', (v ->> 'run_id')::uuid from j where k = 'rq1';
insert into t select 'r2', (v ->> 'run_id')::uuid from j where k = 'rq2';
-- after K: the 40,00 € refund comes back unpaid; 90,00 € more is received on the file
select pg_temp.bounce('06', 4000);
select pg_temp.receive('04', '01', 9000);

create or replace function pg_temp.doc(p_c text, p_ht bigint) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'ref', 'new:70000000-0000-0000-0000-0000000000' || p_c, 'kind', 'invoice',
    'mandate_id', '70000000-0000-0000-0000-0000000000' || p_c, 'ht', p_ht::text, 'vat', (p_ht / 5)::text,
    'ttc', (p_ht + p_ht / 5)::text, 'vat_rate', '0.2', 'settlement', 'netted', 'clause_ref', 'art. 7.2',
    'lines', jsonb_build_array(jsonb_build_object('kind', 'commission', 'designation_fr', 'Commission (test)',
      'claim_type', 'b2b_invoice', 'rule_id', 'tout', 'families', '["principal"]'::jsonb,
      'tiers', jsonb_build_array(jsonb_build_array('0.15', (p_ht * 20 / 3)::text)), 'ht', p_ht::text, 'vat_rate', '0.2')),
    'charges', jsonb_build_array(jsonb_build_object('account_id', pg_temp.f('0' || right(p_c, 1)),
                                                    'tier_key', 'tout', 'amount', p_ht::text))));
$$;
-- the plan: `p_take` of the run's own invoice set off (all of it, part, or none), the rest transferred
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
create or replace function pg_temp.keys(p_c text, p_gross bigint, p_ht bigint) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('account_id', pg_temp.f('0' || right(p_c, 1)),
    'tier_key', 'tout', 'basis', jsonb_build_array(jsonb_build_array('71000000-0000-0000-0000-0000000000' || p_c,
                                                                     p_gross::text)),
    'kept_basis', '0', 'kept', '0', 'commission', p_ht::text));
$$;
-- Martin: 2 000,00 € collected, invoice 360,00 € TTC of which the plan sets off 200,00 € only (older invoices first,
-- the pool's cap: review legal#4)
select pg_temp.prepare((select v from t where k = 'r1'), 30000, pg_temp.doc('a1', 30000), pg_temp.keys('a1', 200000, 30000),
                       pg_temp.plan('a1', 200000, 30000, 20000, 3333));
-- Lilas: 5 120,00 € collected, all of it set off (N = 0), its line past its latest execution date (approved late)
select pg_temp.prepare((select v from t where k = 'r2'), 426667, pg_temp.doc('a2', 426667),
                       pg_temp.keys('a2', 512000, 426667), pg_temp.plan('a2', 512000, 426667, 512000, 85333), 0.2, 2);
select pg_temp.as_user('01');
set local role authenticated;
select public.approve_remittance_runs('ap-doc26-martin', pg_temp.item((select v from t where k = 'r1')));
select public.approve_remittance_runs('ap-doc26-lilas', pg_temp.item((select v from t where k = 'r2')), null,
                                      'motif libre confidentiel du valideur');
reset role;
select is(private.approve_remittance_run((select v from t where k = 'r1'),
                                         (select job_token from public.remittance_run where id = (select v from t where k = 'r1'))) ->> 'status',
  'approved', 'Martin''s run approved');
select is(private.approve_remittance_run((select v from t where k = 'r2'),
                                         (select job_token from public.remittance_run where id = (select v from t where k = 'r2'))) ->> 'status',
  'booked', 'Lilas''s run booked at approval (N = 0)');
insert into t select 'i1', id from public.commission_invoice where run_id = (select v from t where k = 'r1');
insert into t select 'i2', id from public.commission_invoice where run_id = (select v from t where k = 'r2');

-- legal#4, figures#4: the payment reference states what the plan sets off on the run, and the remainder's date ------
select results_eq($$ select i.payload #>> '{payment_reference,mode}', i.payload #>> '{payment_reference,amount_minor}',
                            i.payload #>> '{payment_reference,remainder_minor}',
                            (i.payload #>> '{payment_reference,latest_date}')::date,
                            (i.payload #>> '{payment_reference,transfer}')::boolean, i.settlement, i.due_date
                     from public.commission_invoice i where i.id = (select v from t where k = 'i1') $$,
  $$ values ('run'::text, '20000'::text, '16000'::text, private.paris_today() + 30, true, 'netted'::text,
             private.paris_today() + 30) $$,
  'the run sets off 200,00 € on its payout; the remainder by the mandate''s 30 days, also the invoice''s date');
insert into j select 'p1', private.remittance_statement_build((select v from t where k = 'r1'));
select results_eq($$ select v #>> '{documents,0,settles_minor}', v #>> '{documents,0,payment_reference,remainder_minor}',
                            (v #>> '{documents,0,due_date}')::date
                     from j where k = 'p1' $$,
  $$ values ('20000'::text, '16000'::text, private.paris_today() + 30) $$,
  'the statement states the same set-off and the same remainder');
with x as (insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
           returning id)
insert into t select 'cr1', x.id from x;
select private.run_remittance_checks((select v from t where k = 'cr1'), '00000000-0000-0000-0000-0000000000aa',
                                     private.paris_today() + 31);
select results_eq($$ select c.subject_id, c.amount_minor, c.oldest_days from public.payment_check_result c
                     where c.run_id = (select v from t where k = 'cr1') and c.code = 'invoice_overdue' $$,
  $$ values ((select v from t where k = 'i1'), 36000::bigint, 1) $$,
  'still open after that date: invoice_overdue (L441-10 II), the remainder included');

-- legal#5: N = 0 — no transfer, the plan posted at approval -------------------------------------------------------
select results_eq($$ select i.payload #>> '{payment_reference,mode}', (i.payload #>> '{payment_reference,transfer}')::boolean,
                            (i.payload #>> '{payment_reference,execution_date}')::date,
                            i.payload #>> '{payment_reference,amount_minor}', i.due_date
                     from public.commission_invoice i where i.id = (select v from t where k = 'i2') $$,
  $$ values ('run'::text, false, private.paris_today(), '512000'::text, null::date) $$,
  'N = 0: set off at approval in full, no transfer');
insert into j select 'p2', private.remittance_statement_build((select v from t where k = 'r2'));
select results_eq($$ select v ->> 'status', (v ->> 'settled_on')::date, v -> 'payout' = 'null'::jsonb
                     from j where k = 'p2' $$,
  $$ values ('booked'::text, private.paris_today(), true) $$,
  'the statement: settled on the approval day, no payout');

-- legal#6: a late line states a cause from the data, never the approver's text ------------------------------------
select results_eq($$ select (l ->> 21)::boolean, l ->> 22 from j, jsonb_array_elements(j.v -> 'lines') l where j.k = 'p2' $$,
  $$ values (true, 'identified_late'::text) $$,
  'the late line: queued after its J-5 date (the guard''s margin), so « encaissement identifié tardivement »');
select is((select v -> 'line_columns' ->> 22 from j where k = 'p2'), 'late_cause', 'the column is the cause''s');
select ok((select position('motif libre' in v::text) = 0 from j where k = 'p2'),
  'the approver''s free text is nowhere in the client''s statement');
select is((select late_reason from public.remittance_late_approval where run_id = (select v from t where k = 'r2')),
  'motif libre confidentiel du valideur', 'it stays in the back office''s record');

-- figures#2, legal#3, figures#3: the money not remitted, as of K ---------------------------------------------------
select results_eq($$ select h ->> 'file', h ->> 'reason', h ->> 'amount_minor', h ->> 'count'
                     from j, jsonb_array_elements(j.v #> '{not_remitted,held}') h where j.k = 'p1' $$,
  $$ values ('D-01'::text, 'pending'::text, '12000'::text, '2'::text) $$,
  'held at K: the 70,00 € waiting and the 50,00 € back unpaid before K — not the 90,00 € received after K, nor the '
  '40,00 € refunded at K');
select results_eq($$ select h ->> 'file', h ->> 'reason', h ->> 'amount_minor'
                     from j, jsonb_array_elements(j.v #> '{not_remitted,refunded}') h where j.k = 'p1' $$,
  $$ values ('D-01'::text, 'overpayment'::text, '4000'::text) $$,
  'refunded at K: the 40,00 € (back unpaid only after K), never the refund that came back before K');

-- tests-ui#5: what the client is owed and what the run in flight already covers ------------------------------------
select pg_temp.as_user('03');
set local role authenticated;
select results_eq($$ select o ->> 'owed_minor', o ->> 'in_flight_gross_minor', o #>> '{in_flight_runs,0,number}',
                            o #>> '{in_flight_runs,0,gross_minor}', o #>> '{in_flight_runs,0,net_minor}',
                            o #>> '{in_flight_runs,0,commission_minor}'
                     from jsonb_array_elements(public.client_remittance_summary('00000000-0000-0000-0000-0000000000a1')
                                               -> 'owed') o $$,
  $$ select '200000'::text, '200000'::text, r.number, '200000'::text, '180000'::text, '20000'::text
     from public.remittance_run r where r.id = (select v from t where k = 'r1') $$,
  'owed today 2 000,00 €, all of it in the run ordered: 1 800,00 € to transfer, 200,00 € set off');
reset role;

-- perf#4: the record step keeps the list's figures as scalars -------------------------------------------------------
create temporary table due on commit drop as
select * from private.remittance_documents_begin('00000000-0000-0000-0000-0000000000aa', 0, 0);
select private.remittance_statement_prepare((select v from t where k = 'r2'));
insert into pg_temp._rd_statement_files values ((select v from t where k = 'r2'), repeat('b', 64), repeat('c', 64));
select is(private.remittance_documents_record('00000000-0000-0000-0000-0000000000aa', 'releve-reversement-fr-2',
                                              'facture-commission-fr-2', 'test') ->> 'statements', '1',
  'Lilas''s statement recorded');
select results_eq($$ select gross_minor, net_minor, drawn_status from public.remittance_statement
                     where run_id = (select v from t where k = 'r2') $$,
  $$ values (512000::bigint, 0::bigint, 'booked'::text) $$,
  'its gross, net and status as drawn, as columns: a list reads no payload');
select is((select count(*)::int from pg_temp._rd_statement), 0, 'and the work tables are empty for the next item');

-- legal#2, figures#0, figures#6: a run cancelled before its statement is drawn ----------------------------------------
select pg_temp.as_user('04');
set local role authenticated;
select public.cancel_remittance_run('cn-doc26-martin', (select v from t where k = 'r1'),
                                    (select version from public.remittance_run where id = (select v from t where k = 'r1')),
                                    'erreur de saisie');
reset role;
insert into j select 'p1c', private.remittance_statement_build((select v from t where k = 'r1'));
select results_eq($$ select v ->> 'status', (select bool_and(d ->> 'settles_minor' = '0')
                                             from jsonb_array_elements(v -> 'documents') d),
                            jsonb_array_length(v -> 'documents'), v -> 'earlier_settled',
                            v #>> '{position,owed_after_minor}', v #>> '{position,owed_before_minor}',
                            v #>> '{position,advances_after_minor}' = v #>> '{position,advances_before_minor}',
                            v #>> '{documents,0,cancelled_by,0,number}'
                     from j where k = 'p1c' $$,
  $$ select 'cancelled'::text, true, 2, '[]'::jsonb, '200000'::text, '200000'::text, true, cn.number
     from public.commission_invoice cn
     where cn.run_id = (select v from t where k = 'r1') and cn.reason = 'run_cancelled' $$,
  'nothing set off, the gross still owed, the invoice annulled by the cancellation''s credit note');
select is((select (v #>> '{position,receivable_after_minor}')::bigint from j where k = 'p1c'),
  (select (v #>> '{position,receivable_before_minor}')::bigint
          + (select sum(i.ttc_minor)::bigint from public.commission_invoice i
             where i.run_id = (select v from t where k = 'r1'))
   from j where k = 'p1c'),
  '4111 after = at K + every document of the run (the approval''s and the cancellation''s), nothing settled');
select ok((select position('FOR SHARE' in upper(pg_get_functiondef('private.remittance_statement_build(uuid)'::regprocedure))) > 0),
  'the build holds the run row to the commit (one state: a cancellation waits or is read)');

-- perf#2: one document that cannot be drawn never blocks the others ------------------------------------------------
insert into j select 'fail', private.remittance_document_failed('00000000-0000-0000-0000-0000000000aa', 'statement',
                               (select v from t where k = 'r1'), 'StorageError: text/csv refused');
select results_eq($$ select (j.v ->> 'attempts')::int, d.attempts, d.last_error, d.next_attempt_at > clock_timestamp()
                     from j, private.remittance_document_todo d
                     where j.k = 'fail' and d.kind = 'statement' and d.ref_id = (select v from t where k = 'r1') $$,
  $$ values (1, 1, 'StorageError: text/csv refused'::text, true) $$,
  'a failed statement: its attempt recorded on its row, retried later');
select is((select count(*)::int from private.remittance_documents_begin('00000000-0000-0000-0000-0000000000aa', 10, 10)
           where kind = 'statement'), 0, 'the next job draws the others meanwhile (no head-of-line block)');
select ok(private.remittance_documents_due('00000000-0000-0000-0000-0000000000aa'), 'the invoice PDFs are still due');
with x as (insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
           returning id)
insert into t select 'cr2', x.id from x;
update private.remittance_document_todo set created_at = clock_timestamp() - interval '25 hours'
where kind = 'statement' and ref_id = (select v from t where k = 'r1');
select private.run_remittance_checks((select v from t where k = 'cr2'), '00000000-0000-0000-0000-0000000000aa');
select results_eq($$ select c.code, c.count, c.details ->> 'statements', c.details ->> 'last_error'
                     from public.payment_check_result c
                     where c.run_id = (select v from t where k = 'cr2') and c.code = 'remittance_document_failed' $$,
  $$ values ('remittance_document_failed'::text, 1, '1'::text, 'StorageError: text/csv refused'::text) $$,
  'the nightly alert names the failure until it is drawn');
select results_eq($$ select c.code, c.details ->> 'statements', c.details -> 'numbers' ? r.number
                     from public.payment_check_result c, public.remittance_run r
                     where c.run_id = (select v from t where k = 'cr2') and c.code = 'remittance_document_missing'
                       and r.id = (select v from t where k = 'r1') $$,
  $$ values ('remittance_document_missing'::text, '1'::text, true) $$,
  'and what is still due after 24 hours (§15 document_missing)');
create temporary table q0 on commit drop as
select count(*) as n from pgmq.q_remittances m
where m.message ->> 'type' = 'documents' and m.message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000aa';
select ok(private.queue_remittance_schedule() >= 1, 'the hourly schedule runs');
select is((select count(*) from pgmq.q_remittances m
           where m.message ->> 'type' = 'documents'
             and m.message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000aa') - (select n from q0), 1::bigint,
  'and queues the documents job of a servicer with documents due');
select private.remittance_document_failed(t2.organization_id, t2.kind, t2.ref_id, 'down')
from private.remittance_document_todo t2 where t2.organization_id = '00000000-0000-0000-0000-0000000000aa';
select ok(not private.remittance_documents_due('00000000-0000-0000-0000-0000000000aa'),
  'every document waiting for its retry: nothing due now');

-- K1 (perf#0, tests-ui#0), perf#1, figures#7: the accountant's export, by pages of at most 1,000 rows ---------------
select private.issue_commission_documents('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
  null, (select jsonb_agg(jsonb_build_object('id', gen_random_uuid(), 'ref', 'exp:' || n, 'key', 'inv-exp:' || n,
                                             'kind', 'invoice', 'mandate_id', '70000000-0000-0000-0000-0000000000a2',
                                             'ht', '100', 'vat', '20', 'ttc', '120', 'vat_rate', '0.2',
                                             'settlement', 'netted', 'lines', '[]'::jsonb) order by n)
         from generate_series(1, 1001) n), 'commission');
-- a settlement after the period's end (figures#7)
insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id, kind,
                                          amount_minor, settled_on)
select '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2', 'invoice', i.id, 'payment_own',
       120, private.paris_today() + 10
from public.commission_invoice i
where i.organization_id = '00000000-0000-0000-0000-0000000000aa' and i.ht_minor = 100 order by i.seq limit 1;
create or replace function pg_temp.pages(p_kind text, p_from date, p_to date)
returns table (pages integer, total integer, distinct_keys integer, ordered boolean) language plpgsql as $$
declare
  v_after text;
  v_page text[];
  v_keys text[] := '{}';
  v_pages integer := 0;
begin
  loop
    if p_kind = 'documents' then
      select array_agg(x.page_key order by x.ordinality) into v_page
      from public.accounting_export_documents(p_from, p_to, v_after, 1000) with ordinality x;
    else
      select array_agg(x.page_key order by x.ordinality) into v_page
      from public.accounting_export_entries(p_from, p_to, v_after, 1000) with ordinality x;
    end if;
    v_pages := v_pages + 1;
    v_keys := v_keys || coalesce(v_page, '{}');
    exit when coalesce(cardinality(v_page), 0) < 1000;
    v_after := v_page[cardinality(v_page)];
  end loop;
  return query select v_pages, cardinality(v_keys), (select count(distinct k)::integer from unnest(v_keys) k),
                      v_keys = array(select k from unnest(v_keys) k order by k collate "C");
end $$;
grant execute on all functions in schema pg_temp to authenticated;
create temporary table totals on commit drop as
select (select count(*)::integer from public.commission_invoice i
        where i.organization_id = '00000000-0000-0000-0000-0000000000aa'
          and i.issue_date between private.paris_today() - 1 and private.paris_today()) as documents,
       (select count(*)::integer from public.ledger_posting p join public.ledger_account la on la.id = p.ledger_account_id
        where la.organization_id = '00000000-0000-0000-0000-0000000000aa'
          and la.book in ('servicer_revenue', 'vat_collected', 'vat_pending', 'bank_fees', 'servicer_losses',
                          'commission_receivable', 'client_advance_receivable', 'own_cash')
          and p.effective_date between private.paris_today() - 1 and private.paris_today()) as entries;
grant select on totals to authenticated;
select pg_temp.as_user('01');
set local role authenticated;
select ok((select documents > 1000 and entries > 3000 from totals), 'fixture: more than one page of each');
select results_eq($$ select pages, total, distinct_keys, ordered
                     from pg_temp.pages('documents', private.paris_today() - 1, private.paris_today()) $$,
  $$ select 2, documents, documents, true from totals $$,
  'every document of the period, once, in order, over pages of 1,000 (never cut at the API''s max_rows)');
select results_eq($$ select pages, total, distinct_keys, ordered
                     from pg_temp.pages('entries', private.paris_today() - 1, private.paris_today()) $$,
  $$ select (entries / 1000) + 1, entries, entries, true from totals $$,
  'and every posting of the servicer''s books');
select is((select count(*)::int from public.accounting_export_entries(private.paris_today() - 1, private.paris_today(),
                                                                        null, 5000)), 1000, 'a page is 1,000 rows at most');
select throws_ok($$ select * from public.accounting_export_documents(private.paris_today() - 1, private.paris_today(),
                                                                     'not a key', 10) $$,
  '22023', 'accounting export refused: page', 'a key it did not give is refused');
select results_eq($$ select x.settled_minor, x.open_minor
                     from public.accounting_export_documents(private.paris_today() - 1, private.paris_today(), null, 1000) x
                     where x.number = (select min(i.number) from public.commission_invoice i where i.ht_minor = 100) $$,
  $$ values (0::bigint, 120::bigint) $$,
  'what was settled after the period''s end is not in it: the figures of a closed period do not move');
select results_eq($$ select x.settled_minor, x.open_minor
                     from public.accounting_export_documents(private.paris_today() - 1, private.paris_today() + 10, null,
                                                             1000) x
                     where x.number = (select min(i.number) from public.commission_invoice i where i.ht_minor = 100) $$,
  $$ values (120::bigint, 0::bigint) $$, 'a period that includes it has it');
reset role;
create temporary table _mark on commit drop as
select x.relid, x.seq_scan from pg_stat_xact_user_tables x
where x.relid in ('public.commission_invoice'::regclass, 'public.remittance_run'::regclass);
select pg_temp.as_user('01');
set local role authenticated;
select count(*) from public.accounting_export_entries(private.paris_today() - 1, private.paris_today(), null, 1000);
reset role;
select is((select sum(x.seq_scan - m.seq_scan)::int from pg_stat_xact_user_tables x join _mark m on m.relid = x.relid), 0,
  'the entries name their document and run by key: no scan of the invoices or the runs (perf#1)');
select is((select count(*)::int from public.accounting_export_entries(private.paris_today() - 1, private.paris_today(),
                                                                        null, 1000) e
           where e.source_type = 'commission_invoice' and e.source_ref !~ '^FC-'), 0, 'each with its number');

-- legal#0: the 40 € flat indemnity is stated to a professional buyer whatever proceeding is recorded ----------------
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
values ('d0000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-0000000000aa',
        '00000000-0000-0000-0000-0000000000a2', 'client_status_evidence', 'client/test/09.pdf', repeat('a', 64),
        'application/pdf');
insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                        evidence_document_id, recorded_by)
values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2', 'proceeding_opened',
        private.paris_today() - 5, 'd0000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000004');
insert into j select 'ind', private.issue_commission_documents('00000000-0000-0000-0000-0000000000aa',
  '00000000-0000-0000-0000-0000000000a2', null,
  jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'ref', 'ind', 'key', 'inv-ind:1', 'kind', 'invoice',
                                       'mandate_id', '70000000-0000-0000-0000-0000000000a2', 'ht', '100', 'vat', '20',
                                       'ttc', '120', 'vat_rate', '0.2', 'settlement', 'due', 'due_days', 30,
                                       'lines', '[]'::jsonb)), 'commission');
select results_eq($$ select (i.payload #>> '{flat_indemnity,applies}')::boolean, i.payload #>> '{flat_indemnity,amount_minor}',
                            i.payload #>> '{flat_indemnity,proceeding,kind}',
                            (i.payload #>> '{flat_indemnity,proceeding,effective_date}')::date
                     from j, public.commission_invoice i where j.k = 'ind' and i.id = (j.v #>> '{documents,ind,id}')::uuid $$,
  $$ values (true, '4000'::text, 'proceeding_opened'::text, private.paris_today() - 5) $$,
  'stated (L441-9 I): 40 €; the proceeding kept beside it for the dunning step (L441-10 II), not removing it');

select * from finish();
rollback;
