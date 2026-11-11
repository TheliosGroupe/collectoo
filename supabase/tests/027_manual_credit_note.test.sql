-- M2c-5b: the manual credit note (issue_credit_note; design §14.1, risk R2) and the waiver per (invoice, file, tier key).
--   * who: an admin of the servicer at aal2 — not an ops manager, a collector, a client, an admin at aal1, another
--     servicer's admin (another tenant's invoice);
--   * refusals: a credit note on a credit note, more than the invoice's remaining HT, a file the invoice does not charge,
--     an invoice whose own run is in flight (`run_in_flight`: still cancellable; review ledger-vat#0), an invoice a run
--     in flight sets off (`in_flight`), a missing amount / reason / category, an invoice changed since the page read it
--     (compare and set);
--   * idempotency key and request hash (the same request replays, another is refused);
--   * the document: the next number of the gapless series (approvals interleaved), dated today, its entry −4111 TTC /
--     +7060 HT / +44574 v₁ / +44571 v₂ (the invoice's pending VAT first) balanced, VAT by cumulative difference at the
--     invoice's rate, applied to the invoice's open part at once, the rest a refund owed; the reason category in its
--     line, the staff's free text in a table clients cannot read; its PDF queued;
--   * the spread over the invoice's (file, tier key) in proportion (largest remainder), or one file's;
--   * the waiver: commission_waiver and the key states (V unchanged, waived grown), Σ open + Σ waived = V, the guard;
--   * RLS (staff, client A/B, a restricted viewer, a collector, another servicer), the nightly checks (I16–I18, I22);
--   * review fixes: every credit note's payload names each rectified invoice's HT and VAT after it (legal#1); a refund
--     owed still unpaid 30 days on is alerted (`credit_refund_owed`, legal#0); the invoice page's files a page at a
--     time (`commission_invoice_files`, tests-ui#2) and a credit note's own page names what it rectifies (tests-ui#3);
--     a manual credit note issued between a draft's prepare and its approval sends it back (`history_changed`,
--     tests-ui#0), and so is one prepared while a credit note committed, whatever the engine made of its mixed reads
--     (security-concurrency#0); a draft the engine could not price for good (`commission_input_error`) is approvable,
--     its commission pending (M2c-4's rule, review round 2: no `engine_error`).
-- Design docs/design/m2c-remittances.md §4, §14.1, §16, §20 R2; ADR-0014 M2c-5b.
begin;
select plan(78);

-- Fixtures (as 026: Martin (a1), Lilas (a2) and Cyprès (a3) of the servicer aa; Bleu (b1) of another servicer bb) ----
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
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Bleu SARL', null);
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@credit.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '06', '07', '08']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000bb', 'admin'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a1', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000a2', 'client_admin');
insert into public.portfolio (id, organization_id, client_organization_id, name)
select ('20000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'P' || c
from unnest(array['a1', 'a2', 'a3']) c;
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
                                          '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3');
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-0000000000' || x.n)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || '.pdf', repeat('a', 64),
       'application/pdf'
from (values ('01', 'a1', 'mandate_document'), ('02', 'a2', 'mandate_document'), ('03', 'a1', 'payout_rib'),
             ('04', 'a2', 'payout_rib'), ('05', 'a3', 'mandate_document'), ('06', 'a3', 'payout_rib')) x (n, c, kind);
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on,
                            insurance_clause_ref)
select ('70000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'MAND-' || c, 'mandate_amicable', '2026-01-01', 'art. 9'
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
where organization_id = '00000000-0000-0000-0000-0000000000aa';
insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                          evidence_document_id, proposed_by)
select ('90000000-0000-0000-0000-0000000000' || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, 'EUR', x.iban, x.holder,
       ('d0000000-0000-0000-0000-0000000000' || x.d)::uuid, '10000000-0000-0000-0000-000000000004'
from (values ('a1', '03', 'FR7630004000031234567890143', 'MARTIN SAS'),
             ('a2', '04', 'FR1420041010050500013M02606', 'LILAS FINANCE'),
             ('a3', '06', 'FR7630006000011234567890189', 'CYPRES SA')) x (c, d, iban, holder);
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
  perform private.ledger_post('00000000-0000-0000-0000-0000000000aa', 'adjustment', '2026-09-30', 'mcn-owe-' || p_n,
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
-- What the prepare job writes (emulated, as 026): one draft line per reserved item, charged what the key states
-- give its file, the documents, key states and plan given, then the header.
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
-- The run's invoice: per file of the client given, p_num / p_den of what it collected.
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
-- the plan: `p_take` of the run's own invoice set off, the rest transferred
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
-- one run of a client: requested by an ops manager, prepared as given, approved, its approval job run
create or replace function pg_temp.run(p_c text, p_files jsonb, p_take bigint, p_vat_moved bigint,
                                       p_num bigint default 15, p_den bigint default 100) returns uuid
language plpgsql as $$
declare v_run uuid; v_gross bigint; v_ht bigint;
begin
  select sum((x.value)::bigint), sum((x.value)::bigint * p_num / p_den) into v_gross, v_ht
  from jsonb_each_text(p_files) x;
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_run := (public.request_remittance_run('rq-mcn-' || p_c, ('00000000-0000-0000-0000-0000000000' || p_c)::uuid)
            ->> 'run_id')::uuid;
  reset role;
  perform pg_temp.prepare(v_run, pg_temp.doc(p_c, p_files, p_num, p_den), pg_temp.keys(p_c, p_files, p_num, p_den),
                          pg_temp.plan(p_c, v_gross, v_ht, p_take, p_vat_moved));
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs('ap-mcn-' || p_c, pg_temp.item(v_run));
  reset role;
  perform private.approve_remittance_run(v_run, (select job_token from public.remittance_run where id = v_run));
  return v_run;
end $$;
create or replace function pg_temp.bal(p_book text, p_client text default null) returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.organization_id = '00000000-0000-0000-0000-0000000000aa' and la.book = p_book
    and (p_client is null or la.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_client)::uuid);
$$;
-- issue_credit_note as user p_user, its result
create or replace function pg_temp.credit(p_user text, p_key text, p_invoice uuid, p_amount text, p_remaining text,
                                          p_account uuid default null, p_code text default 'terms_error',
                                          p_reason text default 'taux erroné sur le dossier D-01 (négocié à 10 %)',
                                          p_aal text default 'aal2')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.issue_credit_note(p_key, p_invoice, p_amount, p_code, p_reason, p_remaining, p_account);
  reset role;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
create temporary table t (k text primary key, v uuid) on commit drop;
grant all on t to authenticated;
create temporary table j (k text primary key, v jsonb) on commit drop;
grant all on j to authenticated;

select pg_temp.file('01', '20000000-0000-0000-0000-0000000000a1', 200000);
select pg_temp.file('09', '20000000-0000-0000-0000-0000000000a1', 100000);
select pg_temp.file('02', '20000000-0000-0000-0000-0000000000a2', 360000);
select pg_temp.file('03', '20000000-0000-0000-0000-0000000000a3', 300000);
select pg_temp.collect('01', 200000, private.paris_today() - 3);
select pg_temp.collect('09', 100000, private.paris_today() - 3);
select pg_temp.collect('02', 360000, private.paris_today() - 3);
select pg_temp.collect('03', 300000, private.paris_today() - 3);

-- Martin: two files, nothing set off on its payout (the plan defers its invoice); Cyprès: its invoice set off on its
-- payout (in flight until the debit)
insert into t select 'r1', pg_temp.run('a1', '{"01": "200000", "09": "100000"}', 0, 0);
insert into t select 'r3', pg_temp.run('a3', '{"03": "300000"}', 20000, 3333);
insert into t select 'i1', id from public.commission_invoice where run_id = (select v from t where k = 'r1');
insert into t select 'i3', id from public.commission_invoice where run_id = (select v from t where k = 'r3');
select results_eq($$ select i.number, i.ht_minor, i.vat_minor, private.document_open(i.id),
                            private.document_pending_vat(i.id)
                     from public.commission_invoice i where i.id = (select v from t where k = 'i1') $$,
  $$ values ('FC-' || extract(year from private.paris_today()) || '-000001', 45000::bigint, 9000::bigint, 54000::bigint,
             9000::bigint) $$,
  'fixture: Martin''s invoice FC-…-000001, 450,00 € HT on two files, all open');

-- A run still in flight (approved, its payout not debited: cancellable): its own invoice takes no manual credit note
-- (review ledger-vat#0: the cancellation would credit the invoice in full and the run again bill its lines anew, the
-- rectification billed again)
select throws_ok($$ select pg_temp.credit('04', 'mcn-flight-1', (select v from t where k = 'i1'), '10', '45000') $$,
  '23514', 'credit note refused: run_in_flight', 'the invoice of a run in flight: refused (run_in_flight)');
select pg_temp.as_user('04');
set local role authenticated;
select is(public.credit_note_preview((select v from t where k = 'i1'), '10') ->> 'refusal', 'run_in_flight',
  '… the effect sheet says so');
reset role;
-- … creditable once the run is debited (emulating M2c-6's booking of the payout, as 024 does)
update public.remittance_run set status = 'booked', booked_on = private.paris_today()
where id = (select v from t where k = 'r1');

-- Schema -----------------------------------------------------------------------------------------------------------
select has_column('public', 'remittance_key_state', 'waived_minor', 'a key state carries its waiver');
select ok((select relrowsecurity from pg_class where oid = 'public.commission_waiver'::regclass)
          and (select relrowsecurity from pg_class where oid = 'public.manual_credit_note'::regclass),
  'RLS on the waivers and the manual credit notes');
select is((select count(*)::int from information_schema.role_routine_grants
           where routine_name = 'issue_credit_note' and grantee in ('anon', 'public')), 0,
  'the command is not the anonymous role''s');

-- Who ---------------------------------------------------------------------------------------------------------------
select throws_ok($$ select pg_temp.credit('01', 'mcn-who-01', (select v from t where k = 'i1'), '10', '45000') $$,
  '42501', 'not allowed', 'an ops manager cannot issue a manual credit note');
select throws_ok($$ select pg_temp.credit('02', 'mcn-who-02', (select v from t where k = 'i1'), '10', '45000') $$,
  '42501', 'not allowed', 'nor a collector');
select throws_ok($$ select pg_temp.credit('03', 'mcn-who-03', (select v from t where k = 'i1'), '10', '45000') $$,
  '42501', 'not allowed', 'nor the client''s administrator');
select throws_ok($$ select pg_temp.credit('04', 'mcn-who-04', (select v from t where k = 'i1'), '10', '45000',
                                          null, 'terms_error', 'x', 'aal1') $$,
  '42501', 'not allowed', 'nor an admin at aal1');
select throws_ok($$ select pg_temp.credit('06', 'mcn-who-06', (select v from t where k = 'i1'), '10', '45000') $$,
  '42501', 'not allowed', 'nor another servicer''s admin: another tenant''s invoice');

-- Refusals ----------------------------------------------------------------------------------------------------------
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-1', (select v from t where k = 'i1'), '450,01', '45000') $$,
  '23514', 'credit note refused: more_than_remaining', 'never more than the invoice''s remaining HT');
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-2', (select v from t where k = 'i1'), '0', '45000') $$,
  '22023', 'credit note refused: amount_required', 'an amount is required');
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-3', (select v from t where k = 'i1'), '12,345', '45000') $$,
  '22023', 'credit note refused: amount_required', 'at most two decimals');
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-4', (select v from t where k = 'i1'), '10', '45000', null,
                                          'gesture') $$,
  '22023', 'credit note refused: reason_code', 'a reason category of the list');
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-5', (select v from t where k = 'i1'), '10', '45000', null,
                                          'terms_error', '  ') $$,
  '22023', 'credit note refused: reason_required', 'and a reason');
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-6', (select v from t where k = 'i1'), '10', '44000') $$,
  '23514', 'credit note refused: invoice_changed', 'compare and set: the remaining HT the page showed');
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-7', (select v from t where k = 'i1'), '10', '45000',
                                          pg_temp.f('02')) $$,
  '23514', 'credit note refused: file_not_on_invoice', 'a file the invoice does not charge');
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-8', (select v from t where k = 'i3'), '10', '45000') $$,
  '23514', 'credit note refused: run_in_flight', 'an invoice its own run in flight sets off (its payout not debited)');
select is((select refusal from (select public.credit_note_preview((select v from t where k = 'i3'), '10') ->> 'refusal'
                                         as refusal) x), 'run_in_flight', '… the effect sheet says so');
-- an invoice of a debited run that a later run in flight sets off (its plan's `settles`): `in_flight` — the refusal
-- read for Cyprès's invoice as if its own run were not in flight (its run cleared on the row read)
create or replace function pg_temp.refusal_as_debited(p_invoice uuid) returns text language plpgsql as $$
declare v public.commission_invoice;
begin
  select * into v from public.commission_invoice where id = p_invoice;
  v.run_id := null;
  return private.manual_credit_refusal(v, 1);
end $$;
select is(pg_temp.refusal_as_debited((select v from t where k = 'i3')), 'in_flight',
  'an invoice a run in flight sets off (in_flight)');

-- The effect sheet, then the credit note: 100,00 € on Martin's invoice --------------------------------------------
select pg_temp.as_user('04');
set local role authenticated;
insert into j select 'pv', public.credit_note_preview((select v from t where k = 'i1'), '100');
reset role;
select results_eq($$ select v ->> 'ht', v ->> 'vat', v ->> 'ttc', v ->> 'vat_pending', v ->> 'vat_collected',
                            v ->> 'applied', v ->> 'excess', v ->> 'remaining_after', v ->> 'open_after'
                     from j where k = 'pv' $$,
  $$ values ('10000', '2000', '12000', '2000', '0', '12000', '0', '35000', '42000') $$,
  'the effect sheet: 100,00 € HT, 20,00 € VAT (the pending VAT first), 120,00 € off what it owes, 350,00 € HT left');
select results_eq($$ select a ->> 'account_id', a ->> 'ht' from j, jsonb_array_elements(j.v -> 'allocations') a
                     where j.k = 'pv' order by a ->> 'account_id' $$,
  $$ values (pg_temp.f('01')::text, '6667'), (pg_temp.f('09')::text, '3333') $$,
  'spread over the files in proportion to what each still charges (66,666… → 66,67: the largest remainder)');
select lives_ok($$ insert into j select 'c1', pg_temp.credit('04', 'mcn-ok-1', (select v from t where k = 'i1'), '100',
                                                          '45000') $$,
  'an admin at aal2 issues it');
insert into t select 'cn1', (v ->> 'credit_note_id')::uuid from j where k = 'c1';
select results_eq($$ select i.kind, i.reason, i.run_id, i.number, i.issue_date, i.ht_minor, i.vat_minor, i.ttc_minor,
                            i.settlement, i.vat_rate
                     from public.commission_invoice i where i.id = (select v from t where k = 'cn1') $$,
  $$ values ('credit_note'::text, 'manual'::text, null::uuid,
             'FC-' || extract(year from private.paris_today()) || '-000003', private.paris_today(), -10000::bigint,
             -2000::bigint, -12000::bigint, 'netted'::text, null::numeric) $$,
  'a credit note of the servicer''s series, the next number (after Cyprès''s invoice), dated today, no run');
select results_eq($$ select la.book, p.amount_minor from public.commission_invoice i
                     join public.ledger_posting p on p.entry_id = i.ledger_entry_id
                     join public.ledger_account la on la.id = p.ledger_account_id
                     where i.id = (select v from t where k = 'cn1') order by la.book $$,
  $$ values ('commission_receivable'::text, -12000::bigint), ('servicer_revenue', 10000), ('vat_pending', 2000) $$,
  'its entry: −4111 TTC / +7060 HT / +44574 (the invoice''s pending VAT first)');
select results_eq($$ select e.entry_type, e.effective_date, e.client_organization_id, e.source_type,
                            (select sum(p.amount_minor) from public.ledger_posting p where p.entry_id = e.id)
                     from public.commission_invoice i join public.ledger_entry e on e.id = i.ledger_entry_id
                     where i.id = (select v from t where k = 'cn1') $$,
  $$ values ('commission_credit_note'::text, private.paris_today(), '00000000-0000-0000-0000-0000000000a1'::uuid,
             'commission_invoice'::text, 0::numeric) $$,
  'a commission_credit_note entry of the client, of the credit note, balanced');
select results_eq($$ select l.kind, l.original_invoice_id, l.ht_minor,
                            l.designation_fr like 'Avoir rectifiant la facture FC-%-000001 du __/__/____ — rectification '
                                                  || 'd''une erreur de conditions de rémunération (taux, paliers ou minimum)',
                            position('négocié' in i.payload::text) = 0
                     from public.commission_invoice_line l join public.commission_invoice i on i.id = l.invoice_id
                     where l.invoice_id = (select v from t where k = 'cn1') $$,
  $$ values ('credit'::text, (select v from t where k = 'i1'), -10000::bigint, true, true) $$,
  'one line naming the invoice it rectifies and its date (289 I 5) and the reason category — never the free text');
select results_eq($$ select private.document_open((select v from t where k = 'i1')),
                            private.document_pending_vat((select v from t where k = 'i1')),
                            private.document_open((select v from t where k = 'cn1')) $$,
  $$ values (42000::bigint, 7000::bigint, 0::bigint) $$,
  'the invoice owes 420,00 € TTC now (a price correction applied at once), 70,00 € of VAT pending; no refund owed');
select results_eq($$ select w.account_id, w.amount_minor, w.cause from public.commission_waiver w
                     where w.credit_note_id = (select v from t where k = 'cn1') order by w.account_id $$,
  $$ values (pg_temp.f('01'), 6667::bigint, 'credit_note'::text), (pg_temp.f('09'), 3333, 'credit_note') $$,
  'the waiver per (invoice, file, tier key)');
select results_eq($$ select s.account_id, s.cause, s.commission_minor, s.waived_minor
                     from private.remittance_key_states(array[pg_temp.f('01'), pg_temp.f('09')], array['tout', 'tout']) x
                     join lateral (select k.* from public.remittance_key_state k
                                   where k.account_id = x.account_id and k.tier_key = x.tier_key
                                   order by k.seq desc limit 1) s on true
                     order by s.account_id $$,
  $$ values (pg_temp.f('01'), 'credit_note'::text, 30000::bigint, 6667::bigint),
            (pg_temp.f('09'), 'credit_note', 15000, 3333) $$,
  'each key''s state: the commission charged unchanged (no telescoping), its waiver grown');
select results_eq($$ select o.open_minor + o.waived_minor, o.waived_minor
                     from private.commission_key_open(pg_temp.f('01'), 'tout') o $$,
  $$ values (30000::bigint, 6667::bigint) $$,
  'open charges + waived = the commission charged');
select results_eq($$ select m.invoice_id, m.amount_minor, m.reason_code, m.reason, m.issued_by from public.manual_credit_note m
                     where m.credit_note_id = (select v from t where k = 'cn1') $$,
  $$ values ((select v from t where k = 'i1'), 10000::bigint, 'terms_error'::text,
             'taux erroné sur le dossier D-01 (négocié à 10 %)'::text, '10000000-0000-0000-0000-000000000004'::uuid) $$,
  'the reason staff keep');
select ok(exists (select 1 from private.remittance_document_todo d
                  where d.kind = 'invoice' and d.ref_id = (select v from t where k = 'cn1')),
  'its PDF is due (the documents job draws it)');

-- Idempotency ------------------------------------------------------------------------------------------------------
select is((pg_temp.credit('04', 'mcn-ok-1', (select v from t where k = 'i1'), '100', '45000')) ->> 'credit_note_id',
  (select v::text from t where k = 'cn1'), 'the same request replays its result');
select is((select count(*)::int from public.commission_invoice where reason = 'manual'), 1, '… and issues nothing more');
select throws_ok($$ select pg_temp.credit('04', 'mcn-ok-1', (select v from t where k = 'i1'), '101', '45000') $$,
  '22023', 'idempotency key mcn-ok-1 was used for a different request', 'the same key for another request: refused');

-- A credit note on a credit note ----------------------------------------------------------------------------------
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-9', (select v from t where k = 'cn1'), '1', '0') $$,
  '23514', 'credit note refused: credit_note', 'a credit note is never corrected by a manual one');

-- An approval in between: Lilas's run, all set off (N = 0: its commission, 5/6, is what it collected), its invoice
-- settled ------------------------------------------------------------------------------------------------------------
insert into t select 'r2', pg_temp.run('a2', '{"02": "360000"}', 360000, 60000, 5, 6);
insert into t select 'i2', id from public.commission_invoice where run_id = (select v from t where k = 'r2');
select results_eq($$ select i.number, private.document_open(i.id), private.document_pending_vat(i.id)
                     from public.commission_invoice i where i.id = (select v from t where k = 'i2') $$,
  $$ values ('FC-' || extract(year from private.paris_today()) || '-000004', 0::bigint, 0::bigint) $$,
  'Lilas''s invoice FC-…-000004 (after the manual credit note), settled in full at approval (N = 0)');

-- 50,00 € on one file of Martin's invoice ------------------------------------------------------------------------
select lives_ok($$ insert into j select 'c2', pg_temp.credit('04', 'mcn-ok-2', (select v from t where k = 'i1'), '50,00',
                                                          '35000', pg_temp.f('09'), 'basis_error',
                                                          'encaissement de frais non commissionnable') $$,
  'one limited to a file');
insert into t select 'cn2', (v ->> 'credit_note_id')::uuid from j where k = 'c2';
select results_eq($$ select i.number, i.ht_minor, i.vat_minor from public.commission_invoice i
                     where i.id = (select v from t where k = 'cn2') $$,
  $$ values ('FC-' || extract(year from private.paris_today()) || '-000005', -5000::bigint, -1000::bigint) $$,
  'FC-…-000005: its VAT by cumulative difference, R(150,00 × 20 %) − R(100,00 × 20 %)');
select results_eq($$ select w.account_id, w.amount_minor from public.commission_waiver w
                     where w.credit_note_id = (select v from t where k = 'cn2') $$,
  $$ values (pg_temp.f('09'), 5000::bigint) $$,
  'all of it on that file''s charge');
select is((select l.designation_fr like '% — rectification d''une erreur d''assiette (encaissement non commissionnable)'
           from public.commission_invoice_line l where l.invoice_id = (select v from t where k = 'cn2')), true,
  'its reason category');
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-10', (select v from t where k = 'i1'), '100,01', '30000',
                                          pg_temp.f('09')) $$,
  '23514', 'credit note refused: more_than_remaining', 'never more than the file''s charge (66,67 € left on it)');

-- On a settled invoice: a refund owed (44571: its VAT was due) ------------------------------------------------------
select lives_ok($$ insert into j select 'c3', pg_temp.credit('04', 'mcn-ok-3', (select v from t where k = 'i2'),
                                                          '3 000,00', '300000', null, 'billing_error',
                                                          'facturé deux fois') $$,
  'on Lilas''s settled invoice, all of it');
insert into t select 'cn3', (v ->> 'credit_note_id')::uuid from j where k = 'c3';
select results_eq($$ select c.vat_pending_minor, c.vat_collected_minor, c.applied_minor, c.excess_minor,
                            private.document_open((select v from t where k = 'cn3'))
                     from public.commission_credit_correction c where c.credit_note_id = (select v from t where k = 'cn3') $$,
  $$ values (0::bigint, 60000::bigint, 0::bigint, 360000::bigint, 360000::bigint) $$,
  'nothing left to apply: the whole TTC is a refund owed; its VAT off the VAT already due (44571)');
select results_eq($$ select la.book, p.amount_minor from public.commission_invoice i
                     join public.ledger_posting p on p.entry_id = i.ledger_entry_id
                     join public.ledger_account la on la.id = p.ledger_account_id
                     where i.id = (select v from t where k = 'cn3') order by la.book $$,
  $$ values ('commission_receivable'::text, -360000::bigint), ('servicer_revenue', 300000), ('vat_collected', 60000) $$,
  'its entry: −4111 / +7060 / +44571');
select throws_ok($$ select pg_temp.credit('04', 'mcn-no-11', (select v from t where k = 'i2'), '1', '0') $$,
  '23514', 'credit note refused: nothing_left', 'nothing left to credit on it');

-- Numbering with approvals interleaved -------------------------------------------------------------------------------
select results_eq($$ select i.seq, i.kind, i.reason from public.commission_invoice i
                     where i.organization_id = '00000000-0000-0000-0000-0000000000aa' order by i.seq $$,
  $$ values (1, 'invoice'::text, 'commission'::text), (2, 'invoice', 'commission'), (3, 'credit_note', 'manual'),
            (4, 'invoice', 'commission'), (5, 'credit_note', 'manual'), (6, 'credit_note', 'manual') $$,
  'one gapless series: approvals and manual credit notes interleaved');
select is((select c.last_seq from private.invoice_counter c
           where c.organization_id = '00000000-0000-0000-0000-0000000000aa'), 6, 'the counter at the last number');

-- RLS -------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
select results_eq($$ select (select count(*)::int from public.commission_waiver),
                            (select count(*)::int from public.manual_credit_note) $$,
  $$ values (4, 3) $$, 'money staff read the waivers and the reasons');
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select results_eq($$ select (select count(*)::int from public.commission_waiver),
                            (select count(*)::int from public.manual_credit_note),
                            (select count(*)::int from public.commission_invoice where reason = 'manual'),
                            (select count(*)::int from public.commission_invoice_line l
                             join public.commission_invoice i on i.id = l.invoice_id where i.reason = 'manual'),
                            (select count(*)::int from public.commission_credit_correction c
                             join public.commission_invoice i on i.id = c.credit_note_id where i.reason = 'manual') $$,
  $$ values (0, 0, 2, 2, 2) $$,
  'Martin''s administrator: its two credit notes, their lines and corrections; never the waivers nor the reasons');
reset role;
select pg_temp.as_user('08');
set local role authenticated;
select is((select count(*)::int from public.commission_invoice where reason = 'manual'), 1,
  'Lilas''s administrator: its own one only');
reset role;
select pg_temp.as_user('07');
set local role authenticated;
select is((select count(*)::int from public.commission_invoice), 0, 'a restricted client viewer: none');
reset role;
select pg_temp.as_user('02');
set local role authenticated;
select results_eq($$ select (select count(*)::int from public.commission_invoice),
                            (select count(*)::int from public.commission_waiver),
                            (select count(*)::int from public.manual_credit_note) $$,
  $$ values (0, 0, 0) $$, 'a collector: none');
reset role;
select pg_temp.as_user('05');
set local role authenticated;
select results_eq($$ select (select count(*)::int from public.commission_invoice),
                            (select count(*)::int from public.commission_waiver),
                            (select count(*)::int from public.manual_credit_note) $$,
  $$ values (0, 0, 0) $$, 'another servicer: none');
select throws_ok($$ select public.commission_invoice_detail((select v from t where k = 'i1')) $$, '42501',
  'not allowed', '… nor its invoice page');
reset role;
select pg_temp.as_user('01', 'aal1');
set local role authenticated;
select is((select count(*)::int from public.manual_credit_note), 0, 'staff at aal1: none');
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select throws_ok($$ insert into public.commission_waiver (organization_id, client_organization_id, invoice_id,
                      account_id, tier_key, amount_minor, cause, credit_note_id)
                    values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
                            (select v from t where k = 'i1'), pg_temp.f('01'), 'tout', 1, 'credit_note',
                            (select v from t where k = 'cn1')) $$,
  '42501', null, 'the API never writes a waiver');
reset role;

-- The invoice page ----------------------------------------------------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'd1', public.commission_invoice_detail((select v from t where k = 'i1'));
reset role;
select results_eq($$ select v ->> 'remaining_ht', v ->> 'open_ttc', v ->> 'pending_vat', (v ->> 'file_count')::int,
                            jsonb_array_length(v -> 'credit_notes'), v #>> '{credit_notes,0,reason_fr}',
                            v ->> 'refusal', (v ->> 'can_credit')::boolean
                     from j where k = 'd1' $$,
  $$ values ('30000', '36000', '6000', 2, 2, 'erreur de conditions de rémunération (taux, paliers ou minimum)',
             null::text, false) $$,
  'the page: 300,00 € HT left, 360,00 € TTC owed, its two credit notes with their category; an ops manager cannot credit');

-- The guards ------------------------------------------------------------------------------------------------------
select throws_ok($$ insert into public.commission_waiver (organization_id, client_organization_id, invoice_id,
                      account_id, tier_key, amount_minor, cause, run_id, entry_id)
                    select '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
                           (select v from t where k = 'i1'), pg_temp.f('01'), 'tout', -6668, 'absorbed',
                           (select v from t where k = 'r1'), (select ledger_entry_id from public.commission_invoice
                                                              where id = (select v from t where k = 'i1')) $$,
  '23514', 'commission waiver: an invoice of its client charging the key, between 0 and what manual credit notes took back',
  'a waiver never below 0');
select throws_ok($$ insert into public.commission_waiver (organization_id, client_organization_id, invoice_id,
                      account_id, tier_key, amount_minor, cause, credit_note_id)
                    values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
                            (select v from t where k = 'i1'), pg_temp.f('01'), 'tout', 1, 'credit_note',
                            (select v from t where k = 'cn1')) $$,
  '23514', 'commission waiver: an invoice of its client charging the key, between 0 and what manual credit notes took back',
  'nor above what was waived, nor another client''s');
select throws_ok($$ update public.commission_waiver set amount_minor = 1 $$, '23514', null, 'append-only');
select throws_ok($$ insert into public.remittance_key_state (organization_id, client_organization_id, account_id,
                      tier_key, cause, credit_note_id)
                    values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
                            pg_temp.f('01'), 'tout', 'credit_note', (select v from t where k = 'cn1')) $$,
  '23514', 'remittance key state: its credit note''s servicer and client', 'a key state is its credit note''s client''s');

-- The nightly checks stay true with the waivers (I16–I18, I22) -------------------------------------------------------
with x as (insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
           returning id)
insert into t select 'cr1', x.id from x;
select private.run_remittance_checks((select v from t where k = 'cr1'), '00000000-0000-0000-0000-0000000000aa');
select is((select string_agg(c.code, ',' order by c.code) from public.payment_check_result c
           where c.run_id = (select v from t where k = 'cr1') and c.severity = 'violation'
             and c.code not in ('remittance_payout_overdue')), null,
  'no violation: run totals, numbering, ledger, settlements and pending VAT, key states');
select is(pg_temp.bal('commission_receivable', 'a1'),
  (select sum(private.document_open(i.id) * case i.kind when 'invoice' then 1 else -1 end)::bigint
   from public.commission_invoice i where i.client_organization_id = '00000000-0000-0000-0000-0000000000a1'),
  'I18: Martin''s 4111 = its open documents');
select is(-pg_temp.bal('vat_pending'),
  (select sum(private.document_pending_vat(i.id))::bigint from public.commission_invoice i
   where i.organization_id = '00000000-0000-0000-0000-0000000000aa' and i.kind = 'invoice'),
  'I18: 44574 = the documents'' pending VAT');
-- a key state that disagrees with its documents is a violation (I22)
insert into public.remittance_key_state (organization_id, client_organization_id, account_id, tier_key, run_id, cause,
                                         basis, kept_basis_minor, kept_minor, commission_minor, waived_minor)
select organization_id, client_organization_id, account_id, tier_key, run_id, 'approved', basis, kept_basis_minor,
       kept_minor, commission_minor + 1, waived_minor
from public.remittance_key_state where account_id = pg_temp.f('03') order by seq desc limit 1;
with x as (insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
           returning id)
insert into t select 'cr2', x.id from x;
select private.run_remittance_checks((select v from t where k = 'cr2'), '00000000-0000-0000-0000-0000000000aa');
select results_eq($$ select c.subject_id, c.amount_minor from public.payment_check_result c
                     where c.run_id = (select v from t where k = 'cr2') and c.code = 'commission_key_state' $$,
  $$ values (pg_temp.f('03'), -1::bigint) $$,
  'I22: a key whose open charges and waivers are not its commission is flagged');

-- Review legal#1: every credit note freezes each rectified invoice's HT and VAT after it ----------------------------
select results_eq($$ select (select v from t where k = x.k), c ->> 'ht_after', c ->> 'vat_after'
                     from (values ('cn1', 1), ('cn2', 2), ('cn3', 3)) x (k, o)
                     cross join lateral jsonb_array_elements((select i.payload -> 'corrections' from public.commission_invoice i
                                                              where i.id = (select v from t where k = x.k))) c
                     order by x.o $$,
  $$ values ((select v from t where k = 'cn1'), '35000', '7000'), ((select v from t where k = 'cn2'), '30000', '6000'),
            ((select v from t where k = 'cn3'), '0', '0') $$,
  'each credit note: the invoice it rectifies after it, all its credit notes included (BOI-TVA-DECLA-30-20-20-20 §260)');

-- Review tests-ui#2/#3: the invoice page's files a page at a time; a credit note's page names what it rectifies ----
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'p1', jsonb_agg(to_jsonb(f)) from public.commission_invoice_files((select v from t where k = 'i1'),
                                                                                        null, 1) f;
insert into j select 'p2', jsonb_agg(to_jsonb(f))
from public.commission_invoice_files((select v from t where k = 'i1'), (select v #>> '{0,page_key}' from j where k = 'p1'),
                                     1) f;
insert into j select 'p3', coalesce(jsonb_agg(to_jsonb(f)), '[]')
from public.commission_invoice_files((select v from t where k = 'i1'), (select v #>> '{0,page_key}' from j where k = 'p2'),
                                     1) f;
insert into j select 'dn', public.commission_invoice_detail((select v from t where k = 'cn1'));
reset role;
select results_eq($$ select (x.v -> 0 ->> 'file_id')::uuid, x.v -> 0 ->> 'file_ref', (x.v -> 0 ->> 'open_minor')::bigint,
                            jsonb_array_length(x.v)
                     from j x where x.k in ('p1', 'p2') order by x.k $$,
  $$ values (least(pg_temp.f('01'), pg_temp.f('09')), case when pg_temp.f('01') < pg_temp.f('09') then 'D-01' else 'D-09' end,
             case when pg_temp.f('01') < pg_temp.f('09') then 23333::bigint else 6667 end, 1),
            (greatest(pg_temp.f('01'), pg_temp.f('09')), case when pg_temp.f('01') < pg_temp.f('09') then 'D-09' else 'D-01' end,
             case when pg_temp.f('01') < pg_temp.f('09') then 6667::bigint else 23333 end, 1) $$,
  'the files a page at a time, in key order, with what the invoice still charges each');
select is((select jsonb_array_length(v) from j where k = 'p3'), 0, '… and after the last page, none');
select results_eq($$ select v #>> '{corrects,0,number}', v #>> '{corrects,0,ht}', v ->> 'reason_code',
                            jsonb_array_length(v -> 'credit_notes')
                     from j where k = 'dn' $$,
  $$ values ('FC-' || extract(year from private.paris_today()) || '-000001', '-10000', 'terms_error', 0) $$,
  'a credit note''s page: the invoice it rectifies, its reason category; no credit notes of its own');
select pg_temp.as_user('05');
set local role authenticated;
select throws_ok($$ select * from public.commission_invoice_files((select v from t where k = 'i1')) $$, '42501',
  'not allowed', 'another servicer cannot read the invoice''s files');
reset role;

-- Review legal#0: a refund owed still unpaid 30 days on is an alert -------------------------------------------------
with x as (insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
           returning id)
insert into t select 'cr4', x.id from x;
select private.run_remittance_checks((select v from t where k = 'cr4'), '00000000-0000-0000-0000-0000000000aa',
                                     private.paris_today() + 31);
with x as (insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
           returning id)
insert into t select 'cr5', x.id from x;
select private.run_remittance_checks((select v from t where k = 'cr5'), '00000000-0000-0000-0000-0000000000aa');
select results_eq($$ select c.run_id = (select v from t where k = 'cr4'), c.subject_id, c.amount_minor, c.severity,
                            c.details ->> 'reason', c.details ->> 'planned_run'
                     from public.payment_check_result c
                     where c.run_id in ((select v from t where k = 'cr4'), (select v from t where k = 'cr5'))
                       and c.code = 'credit_refund_owed' $$,
  $$ values (true, (select v from t where k = 'cn3'), 360000::bigint, 'alert'::text, 'manual'::text, null::text) $$,
  'credit_refund_owed: Lilas''s 3 600,00 € owed, 31 days on (not today); none for the notes applied in full');

-- Review tests-ui#0 / security-concurrency#0: a draft prepared before a manual credit note goes back to draft ------
select pg_temp.file('10', '20000000-0000-0000-0000-0000000000a1', 100000);
select pg_temp.collect('10', 100000, private.paris_today() - 2);
create or replace function pg_temp.prepared(p_c text, p_files jsonb, p_key text) returns uuid
language plpgsql as $$
declare v_run uuid; v_gross bigint; v_ht bigint;
begin
  select sum((x.value)::bigint), sum((x.value)::bigint * 15 / 100) into v_gross, v_ht from jsonb_each_text(p_files) x;
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_run := (public.request_remittance_run('rq-' || p_key, ('00000000-0000-0000-0000-0000000000' || p_c)::uuid)
            ->> 'run_id')::uuid;
  reset role;
  perform pg_temp.prepare(v_run, pg_temp.doc(p_c, p_files, 15, 100), pg_temp.keys(p_c, p_files, 15, 100),
                          pg_temp.plan(p_c, v_gross, v_ht, 0, 0));
  return v_run;
end $$;
insert into t select 'r5', pg_temp.prepared('a1', '{"10": "100000"}', 'mcn-hc');
select lives_ok($$ insert into j select 'c5', pg_temp.credit('04', 'mcn-hc-1', (select v from t where k = 'i1'), '10',
                                                          '30000') $$,
  'a manual credit note on Martin''s invoice while its next draft waits for approval');
select pg_temp.as_user('01');
set local role authenticated;
select public.approve_remittance_runs('ap-mcn-hc', pg_temp.item((select v from t where k = 'r5')));
reset role;
insert into j select 'a5', private.approve_remittance_run((select v from t where k = 'r5'),
                                                          (select job_token from public.remittance_run
                                                           where id = (select v from t where k = 'r5')));
select results_eq($$ select (select v ->> 'status' from j where k = 'a5'), (select v ->> 'reason' from j where k = 'a5'),
                            r.status, r.last_failure ->> 'code',
                            (select count(*)::int from public.remittance_key_state k where k.run_id = r.id),
                            (select count(*)::int from public.commission_invoice i where i.run_id = r.id)
                     from public.remittance_run r where r.id = (select v from t where k = 'r5') $$,
  $$ values ('back_to_draft'::text, 'history_changed'::text, 'draft'::text, 'history_changed'::text, 0, 0) $$,
  'the approval sends it back (history_changed): no key state, no document — « Actualiser » prices it again');
-- a draft the engine could not price (`commission_input_error`): prepared across the credit note (its mixed reads),
-- sent back by the history it assumed; prepared after it, for good (a key I22 flags), approvable as in M2c-4 — the
-- commission pending, the run remitted gross (review round 2: no `engine_error` refusal)
create or replace function pg_temp.refusal_with_input_error(p_run uuid, p_fresh boolean) returns text
language plpgsql as $$
declare r public.remittance_run; d private.remittance_draft;
begin
  select * into r from public.remittance_run where id = p_run;
  select * into d from private.remittance_draft where run_id = p_run;
  -- (sent back to draft: the date its approval asks for, as approve_remittance_runs sets it)
  r.requested_execution_date := private.next_business_day(private.paris_today());
  r.commission_blockers := array['commission_input_error: file F, tout: its invoices'' open charges and waivers are not'
                                 || ' the key''s commission'];
  if p_fresh then
    d.history_seq := private.remittance_history_seq(r.client_organization_id);
  end if;
  return private.remittance_approval_refusal(r, d, private.paris_today());
end $$;
select is(pg_temp.refusal_with_input_error((select v from t where k = 'r5'), false), 'history_changed',
  'a draft the engine could not price, prepared across a credit note: sent back (history_changed)');
select is(pg_temp.refusal_with_input_error((select v from t where k = 'r5'), true), null,
  'a draft the engine could not price for good: approvable, its commission pending (M2c-4), no engine_error');

select * from finish();
rollback;
