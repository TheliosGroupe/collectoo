-- M2b-3 (M2-08): reconciliation. Design docs/design/m2b-payments.md §6–§9, §12.2; ADR-0013 (M2b-3 addendum).
-- The worker's rules are played here by writing decisions into pg_temp._mr_decision and calling
-- private.apply_match_results, as the payments.match job does in one transaction.
begin;
select plan(110);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo'),
  ('00000000-0000-0000-0000-00000000000b', 'servicer', 'Other servicer');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A'),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-00000000000b', 'Client B');
insert into auth.users (id, email, aud, role) values
  ('10000000-0000-0000-0000-000000000001', 'ops@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000002', 'collector@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000003', 'admin@a.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000004', 'admin@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000005', 'ops@b.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-00000000000a', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-00000000000b', 'ops_manager');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'P1'),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'P2'),
  ('20000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000b1', 'PB');
-- the collector works portfolio P1 only
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001');
insert into public.bank_account (id, organization_id, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'FR3430001007940000000001001', 'EUR',
   'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000b', 'FR0930001007940000000003003', 'EUR',
   'Autre servicer', 'camt053', '2026-01-01');

-- Files: (id suffix, portfolio, ref, status, currency, servicing start); items (file, item suffix, ref).
create or replace function pg_temp.file(p_n text, p_portfolio uuid, p_ref text, p_status text, p_currency text,
                                        p_start date, p_name text) returns void language sql as $$
  insert into public.account (id, portfolio_id, claim_type_code, external_ref, legal_regime, currency, status)
  values (('a0000000-0000-0000-0000-0000000000' || p_n)::uuid, p_portfolio, 'b2b_invoice', p_ref, 'commercial_b2b',
          p_currency, p_status);
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type,
                                             valid_from)
  select ('a0000000-0000-0000-0000-0000000000' || p_n)::uuid, p.client_organization_id, p.organization_id,
         'mandate_amicable', p_start
  from public.portfolio p where p.id = p_portfolio;
  insert into public.party (id, organization_id, client_organization_id, kind, display_name)
  select ('b0000000-0000-0000-0000-0000000000' || p_n)::uuid, p.organization_id, p.client_organization_id,
         'legal_entity', p_name
  from public.portfolio p where p.id = p_portfolio;
  insert into public.account_party (account_id, party_id, role, capacity)
  values (('a0000000-0000-0000-0000-0000000000' || p_n)::uuid, ('b0000000-0000-0000-0000-0000000000' || p_n)::uuid,
          'borrower', 'legal_entity');
$$;
create or replace function pg_temp.item(p_n text, p_i text, p_ref text) returns void language sql as $$
  insert into public.claim_item (id, account_id, kind, ref, original_minor)
  values (('c0000000-0000-0000-0000-000000000' || p_n || p_i)::uuid, ('a0000000-0000-0000-0000-0000000000' || p_n)::uuid,
          'invoice', p_ref, 100000);
$$;
create or replace function pg_temp.owe(p_n text, p_i text, p_amount bigint) returns void language sql as $$
  select entry_id from private.ledger_post(
    (select organization_id from public.account where id = ('a0000000-0000-0000-0000-0000000000' || p_n)::uuid),
    'adjustment', '2026-09-30', 'owe-file-' || p_n || p_i,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', ('c0000000-0000-0000-0000-000000000' || p_n || p_i)::uuid, 'component', 'principal'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', 'principal')),
    jsonb_build_object('account_id', ('a0000000-0000-0000-0000-0000000000' || p_n)::uuid, 'reason', 'test'));
$$;
select pg_temp.file('01', '20000000-0000-0000-0000-000000000001', 'M-0001', 'in_collection', 'EUR', '2026-01-01', 'Durand SA');
select pg_temp.item('01', '1', 'F-1');
select pg_temp.item('01', '2', 'F-2');
select pg_temp.owe('01', '1', 50000);
select pg_temp.owe('01', '2', 30000);
select pg_temp.file('02', '20000000-0000-0000-0000-000000000002', 'M-0002', 'in_collection', 'EUR', '2026-01-01', 'Lilas SARL');
select pg_temp.item('02', '1', 'G-1');
select pg_temp.owe('02', '1', 20000);
select pg_temp.file('03', '20000000-0000-0000-0000-000000000001', 'M-0003', 'in_collection', 'EUR', '2026-01-01', 'Rappel SA');
select pg_temp.item('03', '1', 'R-1');
select pg_temp.owe('03', '1', 10000);
update public.account set status = 'closed_recalled' where id = 'a0000000-0000-0000-0000-000000000003';
select pg_temp.file('04', '20000000-0000-0000-0000-000000000001', 'M-0004', 'in_collection', 'EUR', '2026-12-01', 'Tard SA');
select pg_temp.file('05', '20000000-0000-0000-0000-000000000001', 'M-0005', 'in_collection', 'EUR', '2026-01-01', 'Zero SA');
select pg_temp.item('05', '1', 'Z-1');
select pg_temp.file('06', '20000000-0000-0000-0000-000000000001', 'M-0006', 'in_collection', 'USD', '2026-01-01', 'Dollar Inc');
select pg_temp.file('07', '20000000-0000-0000-0000-000000000001', 'M-0007', 'staged', 'EUR', '2026-01-01', 'Pas confirmé');
select pg_temp.file('08', '20000000-0000-0000-0000-0000000000b1', 'B-0001', 'in_collection', 'EUR', '2026-01-01', 'Chez B');
select pg_temp.file('09', '20000000-0000-0000-0000-000000000001', 'M-0009', 'staged', 'EUR', '2026-01-01', 'Lot annulé');
-- documents: of file 01; of file 02 (same client); of the client, on no file
insert into public.document (id, organization_id, client_organization_id, account_id, kind, storage_path, sha256, mime_type)
values ('d0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
        'a0000000-0000-0000-0000-000000000001', 'evidence', 'test/recevabilite.pdf', repeat('a', 64), 'application/pdf'),
       ('d0000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
        'a0000000-0000-0000-0000-000000000002', 'evidence', 'test/courrier-lilas.pdf', repeat('b', 64), 'application/pdf'),
       ('d0000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
        null, 'evidence', 'test/client.pdf', repeat('c', 64), 'application/pdf');

-- Payments: each the credit line of a statement being imported (as the import job leaves them).
create or replace function pg_temp.payment(p_n text, p_bank uuid, p_amount bigint, p_iban text default null)
returns void language plpgsql as $$
declare s uuid := ('e0000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  select s, b.organization_id, b.id, 'EUR', 'camt053', 'releve.xml', encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1,
         'test/' || s
  from public.bank_account b where b.id = p_bank;
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, counterparty_iban)
  select s, b.organization_id, b.id, s, 1, 't:' || s, 'credit', p_amount, 'EUR', '2026-10-05', 'debtor_credit', p_iban
  from public.bank_account b where b.id = p_bank;
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, payer_iban)
  select ('f0000000-0000-0000-0000-0000000000' || p_n)::uuid, b.organization_id, b.id, s, 'camt053', 'sct', p_amount,
         'EUR', '2026-10-05', p_iban
  from public.bank_account b where b.id = p_bank;
end $$;
select pg_temp.payment(n, '80000000-0000-0000-0000-000000000001', a, i)
from (values ('01', 50000, 'FR7630004000031234567890143'), ('02', 1000, null), ('03', 1000, null), ('04', 1000, null),
             ('05', 1000, null), ('06', 30000, null), ('07', 15000, null), ('08', 1000, null), ('09', 20000, null),
             ('10', 1000, null), ('11', 1000, null), ('12', 1000, null), ('13', 1000, null), ('14', 1000, null)) v (n, a, i);
select pg_temp.payment('20', '80000000-0000-0000-0000-00000000000b', 1000);

create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
create or replace function pg_temp.split(p_n text) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('account_id', 'a0000000-0000-0000-0000-0000000000' || p_n));
$$;
create or replace function pg_temp.pay(p_n text) returns uuid language sql as $$
  select ('f0000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.reason(p_n text) returns text language sql as $$
  select review_reason from public.payment where id = pg_temp.pay(p_n);
$$;
-- a payment and the file the page showed for it (accept_suggestions)
create or replace function pg_temp.shown(p_n text, p_file text) returns jsonb language sql as $$
  select jsonb_build_object('payment_id', pg_temp.pay(p_n), 'account_id', 'a0000000-0000-0000-0000-0000000000' || p_file);
$$;
grant execute on all functions in schema pg_temp to authenticated;

-- Payments imported before matching existed (M2b-2 is live): the migration queues one match job per servicer
-- that has payments never tried (review fix: they would otherwise wait for the next import).
select ok(private.queue_waiting_matches() >= 2, 'a match job is queued for every servicer with payments never tried');
select is((select array_agg(message ->> 'organization_id' order by message ->> 'organization_id') from pgmq.q_payments
           where message ->> 'type' = 'match' and message ->> 'trigger' = 'import'
             and message ->> 'organization_id' in ('00000000-0000-0000-0000-00000000000a',
                                                   '00000000-0000-0000-0000-00000000000b')),
  array['00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b'],
  'one per servicer (trigger import: every payment never tried)');
select ok(not has_function_privilege('authenticated', 'private.queue_waiting_matches()', 'execute'),
  'users cannot queue match jobs');

-- Structure ---------------------------------------------------------------------------------------
select ok((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where (n.nspname, c.relname) in (('public', 'payment_match'), ('public', 'payment_match_candidate'),
                                           ('public', 'account_hold'), ('private', 'payer_account_link'))),
  'RLS is on for every new table');
select is((select count(*)::int from pg_policies where tablename in ('payment_match', 'payment_match_candidate',
           'account_hold', 'payer_account_link') and cmd <> 'SELECT'), 0, 'read policies only: no user writes');
select ok(not has_function_privilege('authenticated', 'private.apply_match_results(uuid, text)', 'execute')
          and has_function_privilege('service_role', 'private.apply_match_results(uuid, text)', 'execute'),
  'only the worker applies match decisions');
select ok(not has_function_privilege('anon', 'public.assign_payment(text, uuid, jsonb, jsonb, text)', 'execute'),
  'anon cannot assign');
-- NOT IN over a subquery is a plain subplan (one scan of the subquery per row) once its rows outgrow hash memory:
-- quadratic at a large run. NOT EXISTS is an anti-join at any size, whatever the statistics.
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname in ('public', 'private')
             and p.proname in ('gate_assignments', 'record_assignments', 'apply_match_results', 'regate_account',
                               'assign_payment', 'accept_suggestions', 'unassign_payment', 'payment_queue',
                               'match_queue_accounts', 'search_payment_files', 'account_deleted_payments')
             and pg_get_functiondef(p.oid) ~* 'not\s+in\s*\(\s*select'),
  null, 'no NOT IN over a subquery in matching (anti-joins at any size)');

-- Reference keys: ASCII letters and digits, upper case
select is(private.ref_key('fa-2026/00042 é°'), 'FA202600042', 'ref_key keeps ASCII letters and digits, upper-cased');

-- Assign (admins and ops managers at aal2) ----------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('02');
select throws_ok($$select public.assign_payment('key-assign-0001', pg_temp.pay('01'), pg_temp.split('01'), null, 'x')$$,
  '42501', null, 'a collector cannot assign a payment');
select pg_temp.as_user('03', 'aal1');
select throws_ok($$select public.assign_payment('key-assign-0001', pg_temp.pay('01'), pg_temp.split('01'), null, 'x')$$,
  '42501', null, 'a client cannot assign a payment');
select pg_temp.as_user('01', 'aal1');
select throws_ok($$select public.assign_payment('key-assign-0001', pg_temp.pay('01'), pg_temp.split('01'), null, 'x')$$,
  '42501', null, 'staff need two-factor (aal2)');
select pg_temp.as_user('05');
select throws_ok($$select public.assign_payment('key-assign-0001', pg_temp.pay('01'), pg_temp.split('01'), null, 'x')$$,
  '42501', null, 'another servicer cannot assign it');
select pg_temp.as_user('01');
select throws_ok($$select public.assign_payment('key-assign-0002', pg_temp.pay('01'), pg_temp.split('01'), null, ' ')$$,
  '23514', 'a reason is required', 'a reason is required');
select throws_ok($$select public.assign_payment('key-assign-0002', pg_temp.pay('01'), pg_temp.split('01') || pg_temp.split('02'),
  null, 'x')$$, '23514', null, 'one file per payment (splitting comes with allocation)');
select throws_ok($$select public.assign_payment('key-assign-0002', pg_temp.pay('01'),
  '[{"account_id": "a0000000-0000-0000-0000-000000000001", "amount_text": "100,00"}]', null, 'x')$$,
  '23514', null, 'no partial amount yet');
select throws_ok($$select public.assign_payment('key-assign-0002', pg_temp.pay('01'), pg_temp.split('07'), null, 'x')$$,
  '23514', 'the file is not confirmed yet', 'a file not confirmed yet cannot be assigned');
select throws_ok($$select public.assign_payment('key-assign-0002', pg_temp.pay('01'), pg_temp.split('08'), null, 'x')$$,
  '23514', 'unknown file', 'a file of another servicer is unknown');
select throws_ok($$select public.assign_payment('key-assign-0002', pg_temp.pay('01'), pg_temp.split('01'),
  '{"item_ids": ["c0000000-0000-0000-0000-000000000021"], "source": "remittance_text"}', 'x')$$,
  '23514', null, 'a designation names invoices of the file only');
select throws_ok($$select public.assign_payment('key-assign-0002', pg_temp.pay('01'), pg_temp.split('01'),
  '{"item_ids": ["c0000000-0000-0000-0000-000000000011"], "source": "document"}', 'x')$$,
  '23514', null, 'a designation from a document needs the document');
select throws_ok($$select public.assign_payment('key-assign-0002', pg_temp.pay('01'), pg_temp.split('01'),
  '{"item_ids": ["c0000000-0000-0000-0000-000000000011"], "source": "document",
    "evidence_document_id": "d0000000-0000-0000-0000-000000000002"}', 'x')$$,
  '23514', 'invalid designation: the document is required, filed on this file',
  'the evidence of a designation is a document of the chosen file, not of another file of the client');
select throws_ok($$select public.assign_payment('key-assign-0002', pg_temp.pay('01'), pg_temp.split('01'),
  '{"item_ids": ["c0000000-0000-0000-0000-000000000011"], "source": "document",
    "evidence_document_id": "d0000000-0000-0000-0000-000000000003"}', 'x')$$,
  '23514', 'invalid designation: the document is required, filed on this file',
  'nor a document of the client filed on no file');
select is(public.assign_payment('key-assign-0003', pg_temp.pay('01'), pg_temp.split('01'),
  '{"item_ids": ["c0000000-0000-0000-0000-000000000012"], "source": "remittance_text"}', 'courriel du débiteur'),
  jsonb_build_object('payment_id', pg_temp.pay('01'), 'account_id', 'a0000000-0000-0000-0000-000000000001', 'review_reason', null),
  'ops assign a payment to a file');
select is(public.assign_payment('key-assign-0003', pg_temp.pay('01'), pg_temp.split('01'),
  '{"item_ids": ["c0000000-0000-0000-0000-000000000012"], "source": "remittance_text"}', 'courriel du débiteur') ->> 'account_id',
  'a0000000-0000-0000-0000-000000000001', 'the same key and request replay the result');
select throws_ok($$select public.assign_payment('key-assign-0003', pg_temp.pay('02'), pg_temp.split('01'), null, 'x')$$,
  '22023', null, 'the same key for another request is refused');
select throws_ok($$select public.assign_payment('key-assign-0004', pg_temp.pay('01'), pg_temp.split('02'), null, 'x')$$,
  '23514', 'the payment is already matched: unassign it first', 'a matched payment is unassigned first');
reset role;
select results_eq($$select status, match_method, account_id::text, portfolio_id::text, designation -> 'item_ids'
                    from public.payment where id = pg_temp.pay('01')$$,
  $$values ('matched', 'manual', 'a0000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
            '["c0000000-0000-0000-0000-000000000012"]'::jsonb)$$, 'the payment has its file, portfolio and designation');
select results_eq($$select action, method, trigger, decided_by::text, reason, iban_link from public.payment_match
                    where payment_id = pg_temp.pay('01')$$,
  $$values ('assign', 'manual', 'ops', '10000000-0000-0000-0000-000000000001', 'courriel du débiteur', true)$$,
  'one decision recorded, by whom and why');
select is((select confirmed_count from private.payer_account_link where payer_iban = 'FR7630004000031234567890143'
           and account_id = 'a0000000-0000-0000-0000-000000000001'), 1, 'the payer''s IBAN now knows this file');

-- Gating, first that applies (design §8.4) ----------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('01');
select is(public.assign_payment('key-gate-00002', pg_temp.pay('02'), pg_temp.split('03'), null, 'x') ->> 'review_reason',
  'account_closed', 'a closed (recalled) file: ops forward or refund');
select is(public.assign_payment('key-gate-00003', pg_temp.pay('03'), pg_temp.split('04'), null, 'x') ->> 'review_reason',
  'before_servicing_start', 'paid before servicing started');
select is(public.assign_payment('key-gate-00004', pg_temp.pay('04'), pg_temp.split('05'), null, 'x') ->> 'review_reason',
  'nothing_due', 'nothing left to pay');
select is(public.assign_payment('key-gate-00005', pg_temp.pay('05'), pg_temp.split('06'), null, 'x') ->> 'review_reason',
  'currency_mismatch', 'another currency than the file''s (no conversion)');
select is(public.assign_payment('key-gate-00006', pg_temp.pay('06'), pg_temp.split('01'),
  '{"item_ids": ["c0000000-0000-0000-0000-000000000011"], "source": "document",
    "evidence_document_id": "d0000000-0000-0000-0000-000000000001"}', 'lettre du débiteur') ->> 'review_reason',
  null, 'still due on the file after the earlier payment (800 - 500 = 300 > 0); designated by a letter on the file');
select is(public.assign_payment('key-gate-00007', pg_temp.pay('07'), pg_temp.split('01'), null, 'x') ->> 'review_reason',
  'nothing_due', 'nothing left once the earlier payments are counted (800 - 500 - 300 <= 0)');
reset role;
select is((select status from public.payment where id = pg_temp.pay('02')), 'matched', 'a gated payment keeps its file');

-- Holds (minimal): surendettement and collective proceedings block allocation ------------------------
set local role authenticated;
select pg_temp.as_user('02');
select throws_ok($$select public.place_account_hold('key-hold-00001', 'a0000000-0000-0000-0000-000000000001', 'dispute', null,
  null, 'x')$$, '42501', null, 'a collector cannot place a hold');
select pg_temp.as_user('01');
select throws_ok($$select public.place_account_hold('key-hold-00002', 'a0000000-0000-0000-0000-000000000001', 'surendettement',
  'L722-5', null, 'recevabilité')$$, '23514', 'evidence is required for this hold', 'surendettement only on proof');
select throws_ok($$select public.place_account_hold('key-hold-00002', 'a0000000-0000-0000-0000-000000000007', 'dispute', null,
  null, 'x')$$, '23514', null, 'no hold on a file not confirmed');
select lives_ok($$select public.place_account_hold('key-hold-00003', 'a0000000-0000-0000-0000-000000000001', 'surendettement',
  'C. conso L722-5', 'd0000000-0000-0000-0000-000000000001', 'décision de recevabilité')$$, 'a hold is placed on proof');
select throws_ok($$select public.place_account_hold('key-hold-00004', 'a0000000-0000-0000-0000-000000000001', 'surendettement',
  'C. conso L722-5', 'd0000000-0000-0000-0000-000000000001', 'encore')$$, '23514', 'the file already has this hold',
  'one active hold of a kind per file');
select is(pg_temp.reason('06'), 'hold_blocks_allocation', 'payments matched to the file are held');
select is(public.assign_payment('key-gate-00008', pg_temp.pay('08'), pg_temp.split('01'), null, 'x') ->> 'review_reason',
  'hold_blocks_allocation', 'a payment assigned to a held file is held');
reset role;
select is((select scope from public.account_hold where account_id = 'a0000000-0000-0000-0000-000000000001'),
  array['outbound', 'payment_requests'], 'surendettement: outbound and payment requests (DOMAIN §4)');
select throws_ok($$update public.account_hold set reason = 'autre' where account_id = 'a0000000-0000-0000-0000-000000000001'$$,
  '23514', null, 'a hold is never rewritten');
select throws_ok($$delete from public.account_hold$$, '23514', null, 'a hold is never deleted');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.lift_account_hold('key-lift-00001',
  (select id from public.account_hold where account_id = 'a0000000-0000-0000-0000-000000000001'), 'plan homologué')$$,
  'ops lift the hold');
select is(pg_temp.reason('06'), null, 'the held payments are gated again: allocatable');
select is(pg_temp.reason('08'), 'nothing_due', 'in their order (the last one finds nothing left)');
select throws_ok($$select public.lift_account_hold('key-lift-00002',
  (select id from public.account_hold where account_id = 'a0000000-0000-0000-0000-000000000001'), 'encore')$$,
  '23514', 'the hold is already lifted', 'a hold is lifted once');
reset role;

-- Unassign: the payment goes back to the queue, a match job is queued, what it taught is forgotten ----
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.unassign_payment('key-unassign-01', pg_temp.pay('09'), 'x')$$,
  '23514', 'the payment is not matched', 'only a matched payment is unassigned');
select throws_ok($$select public.unassign_payment('key-unassign-01', pg_temp.pay('01'), ' ')$$,
  '23514', 'a reason is required', 'with a reason');
select is(public.unassign_payment('key-unassign-02', pg_temp.pay('01'), 'mauvais dossier') ->> 'unassigned_from',
  'a0000000-0000-0000-0000-000000000001', 'ops unassign a payment');
reset role;
select results_eq($$select status, account_id, review_reason, match_method, designation from public.payment
                    where id = pg_temp.pay('01')$$,
  $$values ('unmatched', null::uuid, 'no_match', null::text, null::jsonb)$$, 'back in the queue, without file');
select results_eq($$select action, reason from public.payment_match where payment_id = pg_temp.pay('01') order by decided_at, action$$,
  $$values ('assign', 'courriel du débiteur'), ('unassign', 'mauvais dossier')$$, 'both decisions are kept');
select is((select confirmed_count from private.payer_account_link where payer_iban = 'FR7630004000031234567890143'
           and account_id = 'a0000000-0000-0000-0000-000000000001'), 0, 'the IBAN memory forgets what that decision taught');
select is(array[pg_temp.reason('07'), pg_temp.reason('08')], array[null, null]::text[],
  'the file''s other payments are gated again: something is left to pay');
select is((select count(*)::int from pgmq.q_payments where message ->> 'type' = 'match' and message ->> 'trigger' = 'ops'
           and message -> 'payment_ids' ? pg_temp.pay('01')::text), 1, 'a match job is queued for fresh suggestions');
select throws_ok($$update public.payment_match set reason = 'autre'$$, '23514', null, 'decisions are append-only');
select throws_ok($$delete from public.payment_match$$, '23514', null, 'and never deleted');
select throws_ok($$insert into public.payment_match (organization_id, payment_id, action, account_id, client_organization_id,
    portfolio_id, method, rule_version, trigger, reason)
  values ('00000000-0000-0000-0000-00000000000a', pg_temp.pay('10'), 'assign', 'a0000000-0000-0000-0000-000000000002',
          '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-000000000002', 'manual', 'ops', 'ops', 'x')$$,
  '23514', null, 'a manual decision names who decided');

-- The match job: decisions applied, gated, queued with their candidates -----------------------------
select private.match_results_begin();
insert into pg_temp._mr_decision (payment_id, ord, outcome, rule, method, account_id, rule_version, evidence, teaches,
                                  review_reason, candidate_account_id) values
  (pg_temp.pay('10'), 1, 'auto', 'R1', 'rf_structured', 'a0000000-0000-0000-0000-000000000002', 'match-1', '{"rule": "R1"}', true, null, null),
  (pg_temp.pay('11'), 2, 'auto', 'R3', 'item_ref', 'a0000000-0000-0000-0000-000000000007', 'match-1', '{"rule": "R3"}', true, null, null),
  (pg_temp.pay('12'), 3, 'ambiguous', 'R3', null, null, 'match-1', '{"rule": "R3"}', false, 'ambiguous', null),
  (pg_temp.pay('13'), 4, 'suggestion', 'R5', null, null, 'match-1', '{"rule": "R5"}', false, 'no_match',
   'a0000000-0000-0000-0000-000000000002'),
  (pg_temp.pay('06'), 5, 'auto', 'R1', 'rf_structured', 'a0000000-0000-0000-0000-000000000002', 'match-1', '{}', true, null, null),
  (pg_temp.pay('14'), 6, 'auto', 'R3', 'item_ref', 'a0000000-0000-0000-0000-000000000009', 'match-1', '{"rule": "R3"}', true, null, null);
insert into pg_temp._mr_candidate (payment_id, rank, account_id, rule, acceptable, signals) values
  (pg_temp.pay('12'), 1, 'a0000000-0000-0000-0000-000000000001', 'R3', false, '{"tokens": ["X1"]}'),
  (pg_temp.pay('12'), 2, 'a0000000-0000-0000-0000-000000000002', 'R3', false, '{"tokens": ["X1"]}'),
  (pg_temp.pay('13'), 1, 'a0000000-0000-0000-0000-000000000002', 'R5', true, '{"similarity": "0.90"}'),
  (pg_temp.pay('12'), 3, 'a0000000-0000-0000-0000-000000000008', 'R3', false, '{}');
-- the batch of file 09 is rolled back while the rules ran (the worker read the file, then it was deleted)
delete from public.account_party where account_id = 'a0000000-0000-0000-0000-000000000009';
delete from public.claim_ownership_period where account_id = 'a0000000-0000-0000-0000-000000000009';
delete from public.account where id = 'a0000000-0000-0000-0000-000000000009';
select is(private.apply_match_results('00000000-0000-0000-0000-00000000000a', 'import') -> 'decided', '5'::jsonb,
  'a payment ops already decided is left alone');
select results_eq($$select status, account_id, candidate_account_id::text, review_reason from public.payment
                    where id = pg_temp.pay('14')$$,
  $$values ('unmatched', null::uuid, 'a0000000-0000-0000-0000-000000000009', 'no_mandate')$$,
  'a file rolled back during the run: no mandate (1342-2), never "waiting" or "not tried"');
select is((select count(*)::int from public.payment_match where payment_id = pg_temp.pay('14')), 0,
  'and no decision on a file that is gone');
select results_eq($$select status, account_id::text, match_method, review_reason from public.payment where id = pg_temp.pay('10')$$,
  $$values ('matched', 'a0000000-0000-0000-0000-000000000002', 'rf_structured', null::text)$$, 'a rule''s match is recorded');
select results_eq($$select method, rule, trigger, decided_by from public.payment_match where payment_id = pg_temp.pay('10')$$,
  $$values ('rf_structured', 'R1', 'import', null::uuid)$$, 'with its rule, and no person');
select results_eq($$select status, account_id, candidate_account_id::text, review_reason from public.payment
                    where id = pg_temp.pay('11')$$,
  $$values ('unmatched', null::uuid, 'a0000000-0000-0000-0000-000000000007', 'account_not_confirmed')$$,
  'a payment for a file not confirmed waits for it (founder #11)');
select is((select count(*)::int from public.payment_match where payment_id = pg_temp.pay('11')), 0,
  'no decision until the file is confirmed');
select is(pg_temp.reason('12'), 'ambiguous', 'two files named: ops decide');
select is((select array_agg(account_id::text order by rank) from public.payment_match_candidate where payment_id = pg_temp.pay('12')),
  array['a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002'],
  'with the candidates of this servicer only');
select results_eq($$select review_reason, candidate_account_id::text from public.payment where id = pg_temp.pay('13')$$,
  $$values ('no_match', 'a0000000-0000-0000-0000-000000000002')$$, 'a suggestion keeps its best file as candidate');

-- Accept suggestions (bulk) ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.accept_suggestions('key-accept-001',
  jsonb_build_array(pg_temp.shown('13', '02'), pg_temp.shown('20', '08')))$$,
  '42501', null, 'payments of one servicer only');
select throws_ok($$select public.accept_suggestions('key-accept-001',
  jsonb_build_array(jsonb_build_object('payment_id', pg_temp.pay('13'))))$$,
  '23514', 'between 1 and 200 payments, each with the file shown', 'each payment comes with the file ops were shown');
select throws_ok($$select public.accept_suggestions('key-accept-001',
  jsonb_build_array(pg_temp.shown('13', '02'), pg_temp.shown('13', '01')))$$,
  '23514', 'one file per payment', 'one file per payment');
-- Compare and set: the page showed file 01 for payment 13, a rematch has proposed file 02 since.
select is(public.accept_suggestions('key-accept-003', jsonb_build_array(pg_temp.shown('13', '01'))),
  jsonb_build_object('accepted', 0, 'skipped', jsonb_build_array(
    jsonb_build_object('payment_id', pg_temp.pay('13'), 'reason', 'suggestion_changed'))),
  'a suggestion that changed since the page was drawn is not accepted: skipped and said so');
select results_eq($$select status, account_id from public.payment where id = pg_temp.pay('13')$$,
  $$values ('unmatched', null::uuid)$$, 'the payment still waits for ops');
select is(public.accept_suggestions('key-accept-002',
  jsonb_build_array(pg_temp.shown('13', '02'), pg_temp.shown('12', '01'), pg_temp.shown('10', '02'))),
  jsonb_build_object('accepted', 1, 'skipped', jsonb_build_array(
    jsonb_build_object('payment_id', pg_temp.pay('10'), 'reason', 'not_waiting'),
    jsonb_build_object('payment_id', pg_temp.pay('12'), 'reason', 'no_suggestion'))),
  'the one-tap suggestion ops saw is accepted; the others are skipped and said so');
select throws_ok($$select public.accept_suggestions('key-accept-002', jsonb_build_array(pg_temp.shown('13', '01'),
  pg_temp.shown('12', '01'), pg_temp.shown('10', '02')))$$,
  '22023', null, 'the request hash covers the files shown');
reset role;
select results_eq($$select status, account_id::text, match_method from public.payment where id = pg_temp.pay('13')$$,
  $$values ('matched', 'a0000000-0000-0000-0000-000000000002', 'manual')$$, 'the accepted suggestion assigns the payment');
select is((select evidence -> 'accepted' ->> 'rule' from public.payment_match where payment_id = pg_temp.pay('13')), 'R5',
  'the decision keeps what ops accepted');
select is((select count(*)::int from public.payment_match_candidate where payment_id = pg_temp.pay('13')), 0,
  'its candidates are gone');

-- Read access ------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('01');
select is((select count(*)::int from public.payment_match), 11, 'ops read the decisions of their servicer');
select is((select count(*)::int from public.payment_match_candidate), 2, 'and the candidates');
select is((select count(*)::int from public.payment_match m where m.organization_id = '00000000-0000-0000-0000-00000000000b'),
  0, 'nothing of another servicer');
select results_eq($$select external_ref, balance_minor, pending_minor from public.match_queue_accounts(
    array['a0000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000008'::uuid])$$,
  $$values ('M-0001', '80000', '46000')$$, 'the queue reads its candidates'' balances as text (own servicer only)');
select is((select array_agg(found_by) from public.search_payment_files(pg_temp.pay('12'), 'f2')), null,
  'a search under 3 characters finds nothing');
select is((select array_agg(external_ref || ':' || found_by) from public.search_payment_files(pg_temp.pay('12'), 'F-2')),
  array['M-0001:invoice'], 'ops find a file by an invoice number');
select is((select array_agg(external_ref) from public.search_payment_files(pg_temp.pay('12'), 'm 0002')),
  array['M-0002'], 'or by its reference, however typed');
select ok((select count(*) from public.statement_match_counts(array[('e0000000-0000-0000-0000-000000000010')::uuid])) = 1,
  'statement counts for ops');
select pg_temp.as_user('02');
select results_eq($$select count(*)::int, bool_and(portfolio_id = '20000000-0000-0000-0000-000000000001')
                    from public.payment_match$$, $$values (7, true)$$,
  'a collector reads only decisions of payments now in its portfolios');
select is((select count(*)::int from public.payment_match where payment_id = pg_temp.pay('01')), 0,
  'not those of a payment taken off its portfolio (now unmatched)');
select is((select count(*)::int from public.payment_match_candidate), 0, 'a collector reads no candidate');
select is((select count(*)::int from public.match_queue_accounts(array['a0000000-0000-0000-0000-000000000001'::uuid])), 0,
  'nor the queue''s balances');
select is((select count(*)::int from public.statement_match_counts(array[('e0000000-0000-0000-0000-000000000010')::uuid])), 0,
  'nor the statement counts (bank lines)');
select is((select count(*)::int from public.account_hold), 1, 'a collector reads the holds of its portfolios');
select pg_temp.as_user('03', 'aal1');
select is((select count(*)::int from public.payment_match), 0, 'a client reads no decision (bank data)');
select is((select count(*)::int from public.payment_match_candidate), 0, 'nor any candidate');
select is((select count(*)::int from public.account_hold), 1, 'but reads the holds of its portfolios');
select pg_temp.as_user('05');
select is((select count(*)::int from public.account_hold), 0, 'another servicer reads none of them');
select throws_ok($$select * from private.payer_account_link$$, '42501', null, 'the IBAN memory is never exposed');
select throws_ok($$insert into public.payment_match_candidate (payment_id, rank, organization_id, account_id, rule)
  values (pg_temp.pay('14'), 1, '00000000-0000-0000-0000-00000000000a', 'a0000000-0000-0000-0000-000000000001', 'R5')$$,
  '42501', null, 'users never write candidates');
select throws_ok($$insert into public.account_hold (organization_id, client_organization_id, portfolio_id, account_id, kind,
  scope, reason) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
  '20000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'dispute', '{outbound}', 'x')$$,
  '42501', null, 'nor holds (commands only)');
reset role;

-- A file rolled back: the payment that waited for it needs ratification or a refund (no_mandate) -------
delete from public.account_party where account_id = 'a0000000-0000-0000-0000-000000000007';
delete from public.claim_ownership_period where account_id = 'a0000000-0000-0000-0000-000000000007';
delete from public.account where id = 'a0000000-0000-0000-0000-000000000007';
select is(pg_temp.reason('11'), 'no_mandate', 'a payment waiting for a rolled-back file has no mandate (1342-2)');

-- The queue (design §12.2) reads the queue, never the payment history (review fix) --------------------------
-- 5,000 payments matched earlier on file 10; no statistics are gathered (a page must not depend on them).
select pg_temp.file('10', '20000000-0000-0000-0000-000000000001', 'M-0010', 'in_collection', 'EUR', '2026-01-01',
                    'Historique SA');
insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                   size_bytes, storage_path)
values ('e0000000-0000-0000-0000-0000000000ff', '00000000-0000-0000-0000-00000000000a',
        '80000000-0000-0000-0000-000000000001', 'EUR', 'camt053', 'historique.xml', repeat('f', 64), 1, 'test/historique');
update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = 'e0000000-0000-0000-0000-0000000000ff';
insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind)
select ('e1000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '00000000-0000-0000-0000-00000000000a',
       '80000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-0000000000ff', n, 'h:' || n, 'credit', 1000, 'EUR',
       '2026-09-01', 'debtor_credit'
from generate_series(1, 5000) n;
insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                            currency, booking_date, account_id, status, match_method, matched_at)
select ('f1000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '00000000-0000-0000-0000-00000000000a',
       '80000000-0000-0000-0000-000000000001', ('e1000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'camt053',
       'sct', 1000, 'EUR', '2026-09-01', 'a0000000-0000-0000-0000-000000000010', 'matched', 'manual', now()
from generate_series(1, 5000) n;
-- shared buffers a page of a tab touches (after a first call: plan cache and catalogs warm)
create or replace function pg_temp.queue_buffers(p_tab text) returns bigint language plpgsql as $$
declare v jsonb;
begin
  perform * from public.payment_queue(p_tab);
  execute format('explain (analyze, buffers, format json) select * from public.payment_queue(%L)', p_tab) into v;
  return (v -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint + (v -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint;
end $$;
grant execute on function pg_temp.queue_buffers(text) to authenticated;
set local role authenticated;
select pg_temp.as_user('01');
-- (the 5,000 payments take ~140 pages: a scan of the history read 343 buffers, the queue's index ~30)
select cmp_ok(pg_temp.queue_buffers('a-traiter'), '<', 100::bigint,
  'a page of « à traiter » reads the queue, not the payment history');
select is((select max(total) from public.payment_queue('a-traiter')),
  (select count(*) from public.payment p where p.organization_id = '00000000-0000-0000-0000-00000000000a'
     and (p.status = 'unmatched' or p.review_reason is not null)), 'its total counts the whole queue of the servicer');
select is((select max(total) from public.payment_queue('rapproches')),
  (select count(*) from public.payment p where p.organization_id = '00000000-0000-0000-0000-00000000000a'
     and p.status = 'matched' and p.review_reason is null), '« Rapprochés »: every matched payment ready for allocation');
select is((select array_agg(payment_id) from public.payment_queue('a-traiter', 'no_mandate')),
  array[pg_temp.pay('11'), pg_temp.pay('14')], 'filtered by reason, oldest first');
select is((select count(*)::int from public.payment_queue('a-traiter', null, null, null, null, null, 1000, 20)), 0,
  'a page past the end is empty (the page then asks for the total again)');
select pg_temp.as_user('02');
select is((select count(*)::int from public.payment_queue('rapproches')), 0, 'the queue is for admins and ops managers');
reset role;

-- The rematch at confirmation is queued by the confirmation job (worker integration test: end to end)
select ok(pg_get_functiondef('private.complete_batch_confirmation(uuid)'::regprocedure) like '%''trigger'', ''rematch''%',
  'confirmation queues the rematch');

select * from finish();
rollback;
