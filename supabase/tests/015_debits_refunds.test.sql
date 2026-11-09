-- M2b-6: money leaving the client-funds account (bank returns, refunds, refunds that bounce, lines ops explain), payments
-- made to the client directly, CSV suspected duplicates, the nightly checks. Design docs/design/m2b-payments.md §2 #3,
-- §6, §7, §8.1, §9, §11, §13; ADR-0013 (M2b-6 addendum). The worker's debit job is played here through ops' link_debit
-- (same posting function) and private.apply_debit_decisions; the direct-payment job through private.post_direct_payment.
begin;
select plan(169);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo SAS'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Other servicer');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Martin SAS'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Lilas Finance');
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@debits.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', 'P1'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2', 'P2');
insert into public.portfolio_access (user_id, portfolio_id) values  -- the collector works P2 only
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a2');
insert into public.bank_account (id, organization_id, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000aa', 'FR3430001007940000000001001', 'EUR',
   'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000ab', '00000000-0000-0000-0000-0000000000aa', 'FR7630004000031234567890143', 'EUR',
   'Fonds de tiers CSV', 'csv', '2026-01-01');

create or replace function pg_temp.f(p_n text) returns uuid language sql as $$
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.it(p_n text, p_i text) returns uuid language sql as $$
  select ('c1000000-0000-0000-0000-000000000' || p_n || p_i)::uuid;
$$;
create or replace function pg_temp.pay(p_n text) returns uuid language sql as $$
  select ('f1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.file(p_n text, p_portfolio uuid, p_name text) returns void language sql as $$
  insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                              legal_regime, currency, status)
  select pg_temp.f(p_n), p.organization_id, p.client_organization_id, p.id, 'b2b_invoice', 'D-' || p_n,
         'commercial_b2b', 'EUR', 'in_collection'
  from public.portfolio p where p.id = p_portfolio;
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type,
                                             valid_from)
  select pg_temp.f(p_n), p.client_organization_id, p.organization_id, 'mandate_amicable', '2026-09-30'
  from public.portfolio p where p.id = p_portfolio;
  insert into public.party (id, organization_id, client_organization_id, kind, display_name)
  select ('b1000000-0000-0000-0000-0000000000' || p_n)::uuid, p.organization_id, p.client_organization_id,
         'legal_entity', p_name
  from public.portfolio p where p.id = p_portfolio;
  insert into public.account_party (account_id, party_id, role, capacity)
  values (pg_temp.f(p_n), ('b1000000-0000-0000-0000-0000000000' || p_n)::uuid, 'borrower', 'legal_entity');
$$;
create or replace function pg_temp.item(p_n text, p_i text, p_due date, p_amount bigint) returns void language sql as $$
  insert into public.claim_item (id, account_id, kind, ref, due_date, original_minor)
  values (pg_temp.it(p_n, p_i), pg_temp.f(p_n), 'invoice', 'F-' || p_n || p_i, p_due, p_amount);
  select entry_id from private.ledger_post(
    '00000000-0000-0000-0000-0000000000aa', 'adjustment', '2026-09-30', 'debit-owe-' || p_n || p_i,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', pg_temp.it(p_n, p_i), 'component', 'principal'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', 'principal')),
    jsonb_build_object('account_id', pg_temp.f(p_n), 'reason', 'ouverture (test)'));
$$;
-- A statement being imported (one per line here) of a bank account.
create or replace function pg_temp.stmt(p_id uuid, p_bank uuid) returns void language plpgsql as $$
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  select p_id, b.organization_id, b.id, 'EUR', b.feed, 'r', encode(sha256(convert_to(p_id::text, 'UTF8')), 'hex'), 1,
         'test/' || p_id
  from public.bank_account b where b.id = p_bank;
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = p_id;
end $$;
-- A credit line, its payment (payer IBAN given), and the cash_in of its statement day (as the import books it).
create or replace function pg_temp.payment(p_n text, p_amount bigint, p_iban text default null)
returns void language plpgsql as $$
declare s uuid := ('e1000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  perform pg_temp.stmt(s, '80000000-0000-0000-0000-0000000000aa');
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, tx_id)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000aa', s, 1, 't:' || s, 'credit',
          p_amount, 'EUR', '2026-10-05', 'debtor_credit', 'E2E-' || p_n, 'TX-' || p_n);
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, payer_name, payer_iban, end_to_end_id)
  values (pg_temp.pay(p_n), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000aa', s,
          'camt053', 'sct', p_amount, 'EUR', '2026-10-05', 'PAYEUR ' || p_n, p_iban, 'E2E-' || p_n);
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_in', '2026-10-05', 'cash_in:' || s || ':2026-10-05',
          'bank_statement', s::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', p_amount, 'EUR', '80000000-0000-0000-0000-0000000000aa'),
    (1, 2, 'unallocated_payment', -p_amount, 'EUR', null);
  perform private.ledger_post_set();
end $$;
-- A bank line (debit, or a credit undoing one) on a statement of its own; returns its id.
create or replace function pg_temp.line(p_n text, p_direction text, p_kind text, p_amount bigint, p_date date,
                                        p_e2e text default null, p_bank uuid default '80000000-0000-0000-0000-0000000000aa',
                                        p_text text default null)
returns uuid language plpgsql as $$
declare s uuid := md5('debit-line-' || p_n)::uuid;
begin
  perform pg_temp.stmt(s, p_bank);
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, original_end_to_end_id,
                                       return_reason, remittance_text)
  values (s, '00000000-0000-0000-0000-0000000000aa', p_bank, s, 1, 'h:' || s || '#1', p_direction, p_amount, 'EUR', p_date,
          p_kind, p_e2e, case when p_kind = 'return' then p_e2e end, case when p_kind = 'return' then 'MD06' end, p_text);
  return s;
end $$;
create or replace function pg_temp.ln(p_n text) returns uuid language sql as $$
  select md5('debit-line-' || p_n)::uuid;
$$;
create or replace function pg_temp.match(p_n text, p_file text, p_reason text default null) returns void language sql as $$
  update public.payment set account_id = pg_temp.f(p_file), status = 'matched', match_method = 'rf_structured',
                            matched_at = now(), review_reason = p_reason
  where id = pg_temp.pay(p_n);
$$;
create or replace function pg_temp.allocate(p_n text, p_file text, p_lines jsonb, p_date date default '2026-10-05')
returns jsonb language plpgsql as $$
begin
  perform private.allocation_begin();
  insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy, inputs_hash)
  values (pg_temp.pay(p_n), 1, pg_temp.f(p_file), 'allocate', p_date,
          '{"accessory_rank": "before_principal", "unclassified": "last"}', repeat('0', 64));
  insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
  select pg_temp.pay(p_n), x.ord::integer, pg_temp.it(p_file, x.l ->> 0), 'principal', (x.l ->> 1)::bigint
  from jsonb_array_elements(p_lines) with ordinality as x (l, ord);
  return private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1');
end $$;
-- The allocation job's decision for a payment its gates stop (no lines): what the worker posts for it.
create or replace function pg_temp.gate(p_n text, p_file text, p_outcome text) returns jsonb language plpgsql as $$
begin
  perform private.allocation_begin();
  insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome) values (pg_temp.pay(p_n), 1, pg_temp.f(p_file), p_outcome);
  return private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1');
end $$;
create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
create or replace function pg_temp.state(p_n text) returns text language sql as $$
  select status || '/' || coalesce(review_reason, '-') from public.payment where id = pg_temp.pay(p_n);
$$;
create or replace function pg_temp.left_of(p_n text) returns text language sql as $$
  select unallocated_minor::text from private.payment_positions(array[pg_temp.pay(p_n)]);
$$;
create or replace function pg_temp.balance(p_n text, p_i text) returns bigint language sql as $$
  select coalesce(sum(lp.amount_minor), 0)::bigint from public.ledger_account la
  join public.ledger_posting lp on lp.ledger_account_id = la.id
  where la.claim_item_id = pg_temp.it(p_n, p_i) and la.component = 'principal';
$$;
create or replace function pg_temp.entries(p_n text) returns text language sql as $$
  select string_agg(e.entry_type || coalesce('(' || t.entry_type || ')', '') || '@' || e.effective_date, ' '
                    order by e.posted_at, e.id)
  from public.ledger_entry e left join public.ledger_entry t on t.id = e.reverses_entry_id
  where e.payment_id = pg_temp.pay(p_n);
$$;
create or replace function pg_temp.refund_of(p_n text) returns uuid language sql as $$
  select id from public.refund_request where payment_id = pg_temp.pay(p_n)
  order by status = 'requested' desc, status = 'cancelled', requested_at desc, id limit 1;
$$;
create or replace function pg_temp.rfd_of(p_n text) returns text language sql as $$
  select end_to_end_id from public.refund_request where id = pg_temp.refund_of(p_n);
$$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.file('01', '20000000-0000-0000-0000-0000000000a1', 'Durand SA');
select pg_temp.item('01', '1', '2026-08-01', 50000);
select pg_temp.item('01', '2', '2026-09-01', 30000);
select pg_temp.file('02', '20000000-0000-0000-0000-0000000000a2', 'Lilas SARL');
select pg_temp.item('02', '1', '2026-08-01', 20000);
insert into public.document (id, organization_id, client_organization_id, account_id, kind, storage_path, sha256, mime_type)
values ('d1000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
        pg_temp.f('01'), 'evidence', 'test/debit-releve-client.pdf', repeat('a', 64), 'application/pdf'),
       ('d1000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
        pg_temp.f('02'), 'evidence', 'test/debit-autre.pdf', repeat('b', 64), 'application/pdf');
select pg_temp.payment('01', 40000, 'FR7630006000011234567890189');
select pg_temp.payment('02', 25000, 'FR7630006000011234567890189');
select pg_temp.payment('03', 7000);
select pg_temp.payment('04', 10000);
select pg_temp.match('01', '01');
select pg_temp.allocate('01', '01', '[["1", 40000]]');
select pg_temp.match('02', '02');
select pg_temp.allocate('02', '02', '[["1", 20000]]');
update public.payment set review_reason = 'no_match' where id = pg_temp.pay('03');
select pg_temp.match('04', '01');
select pg_temp.allocate('04', '01', '[["2", 10000]]');

-- Structure ---------------------------------------------------------------------------------------
select ok((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where (n.nspname, c.relname) in (('public', 'refund_request'), ('public', 'bank_debit_link'),
                                           ('public', 'bank_debit_review'), ('public', 'bank_duplicate_resolution'),
                                           ('private', 'bank_line_held_kind'), ('public', 'direct_payment'),
                                           ('public', 'payment_check_run'), ('public', 'payment_check_result'))),
  'RLS is on for every new table');
select is((select count(*)::int from pg_policies where tablename in ('refund_request', 'bank_debit_link',
           'bank_debit_review', 'bank_duplicate_resolution', 'direct_payment', 'payment_check_run',
           'payment_check_result') and cmd <> 'SELECT'), 0, 'read policies only: no user writes');
select is((select count(*)::int from pg_trigger
           where tgrelid in ('public.refund_request'::regclass, 'public.bank_debit_link'::regclass,
                             'public.bank_duplicate_resolution'::regclass, 'public.direct_payment'::regclass,
                             'public.payment_check_result'::regclass)
             and not tgisinternal and tgname not like '%change_log' and tgname not like '%touch' and tgenabled <> 'A'), 0,
  'the guards of the new tables fire ALWAYS');
select ok(exists (select 1 from pg_trigger where tgrelid = 'public.refund_request'::regclass and tgname = 'refund_request_change_log')
          and exists (select 1 from pg_trigger where tgrelid = 'public.direct_payment'::regclass and tgname = 'direct_payment_change_log'),
  'refund requests and direct payments are in the change log (design §6)');
select ok(not has_function_privilege('authenticated', 'private.post_debit_links(uuid, boolean)', 'execute')
          and not has_function_privilege('authenticated', 'private.debit_post_rows(uuid)', 'execute')
          and not has_function_privilege('service_role', 'private.debit_post_rows(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'private.apply_debit_decisions(uuid)', 'execute')
          and has_function_privilege('service_role', 'private.apply_debit_decisions(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'private.run_payment_checks(uuid)', 'execute')
          and has_function_privilege('service_role', 'private.run_payment_checks(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'private.post_direct_payment(uuid, jsonb, text, text)', 'execute'),
  'only the worker posts debits, direct payments and runs the checks');
select ok(not has_function_privilege('anon', 'public.request_refund(text, uuid, text, text, text, text, text, text, text)', 'execute')
          and not has_function_privilege('anon', 'public.link_debit(text, uuid, text, uuid, uuid, text, text)', 'execute')
          and not has_function_privilege('anon', 'public.resolve_duplicate(text, uuid, boolean, text)', 'execute')
          and not has_function_privilege('anon', 'public.record_direct_payment(text, uuid, uuid[], text, date, uuid, text)', 'execute')
          and not has_function_privilege('anon', 'public.debit_queue(text, integer, integer)', 'execute'),
  'anon cannot act on money leaving the account');
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname in ('public', 'private')
             and p.proname in ('post_debit_links', 'debit_post_rows', 'debit_candidates', 'apply_debit_decisions',
                               'request_refund',
                               'cancel_refund', 'link_debit', 'resolve_duplicate', 'record_direct_payment',
                               'post_direct_payment', 'run_payment_checks', 'debit_queue', 'debit_link_options',
                               'bank_unposted')
             and (pg_get_functiondef(p.oid) ~* 'not\s+in\s*\(\s*select'
                  or (p.prosecdef and coalesce(array_to_string(p.proconfig, ','), '') !~ 'search_path=""'))),
  null, 'no NOT IN over a subquery; every definer function pins its search_path');
select ok((select count(*) from cron.job where jobname = 'payments-invariants') = 1, 'the nightly checks are scheduled (pg_cron)');

set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$insert into public.refund_request (organization_id, payment_id, bank_account_id, currency, amount_minor,
  payee_iban, payee_name, payee_is_payer, end_to_end_id, reason_code, reason, prior_status, requested_by)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.pay('03'), '80000000-0000-0000-0000-0000000000aa', 'EUR', 1,
          'FR7630006000011234567890189', 'X', true, 'RFD000000000000', 'other', 'x', 'unmatched',
          '10000000-0000-0000-0000-000000000001')$$, '42501', null, 'users cannot write refund requests');
select throws_ok($$insert into public.bank_debit_link (bank_transaction_id, organization_id, bank_account_id, kind, method,
  reason, decided_by) values (pg_temp.pay('03'), '00000000-0000-0000-0000-0000000000aa',
  '80000000-0000-0000-0000-0000000000aa', 'explained', 'ops', 'x', '10000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'users cannot write debit links');
select throws_ok($$insert into public.bank_duplicate_resolution (bank_transaction_id, organization_id, bank_account_id,
  decision, reason, decided_by) values (pg_temp.pay('03'), '00000000-0000-0000-0000-0000000000aa',
  '80000000-0000-0000-0000-0000000000aa', 'duplicate', 'x', '10000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'users cannot write duplicate decisions');
select throws_ok($$insert into public.direct_payment (organization_id, client_organization_id, portfolio_id, account_id,
  currency, amount_minor, paid_on, evidence_document_id, reason, requested_by) values
  ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1',
   pg_temp.f('01'), 'EUR', 1, '2026-10-10', 'd1000000-0000-0000-0000-000000000001', 'x',
   '10000000-0000-0000-0000-000000000001')$$, '42501', null, 'users cannot write direct payments');
select throws_ok($$insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')$$,
  '42501', null, 'users cannot write check runs');
select throws_ok($$insert into public.bank_debit_review (bank_transaction_id, organization_id, reason) values
  (pg_temp.pay('03'), '00000000-0000-0000-0000-0000000000aa', 'no_candidate')$$, '42501', null, 'users cannot write reviews');
reset role;

-- Refunds (founder #8, #9, #11; 1302-1): ops ask, nothing booked until the bank's debit ---------------------------
set local role authenticated;
select pg_temp.as_user('02');
select throws_ok($$select public.request_refund('k-refund-0000', pg_temp.pay('02'), '5000', null, null, 'overpayment',
  'overpayment', '5000', 'trop perçu')$$, '42501', null, 'a collector cannot refund');
select pg_temp.as_user('01', 'aal1');
select throws_ok($$select public.request_refund('k-refund-0000', pg_temp.pay('02'), '5000', null, null, 'overpayment',
  'overpayment', '5000', 'trop perçu')$$, '42501', null, 'nor an ops manager without MFA (aal2)');
select pg_temp.as_user('01');
select throws_ok($$select public.request_refund('k-refund-0001', pg_temp.pay('02'), '5000', null, null, 'overpayment',
  'overpayment', '4999', 'trop perçu')$$, '23514', 'the payment changed: reload the page',
  'compare and set: what is left as the page showed it');
select throws_ok($$select public.request_refund('k-refund-0002', pg_temp.pay('02'), '5000', null, null,
  'currency_mismatch', 'overpayment', '5000', 'trop perçu')$$, '23514',
  'refund: the reason does not match the payment''s state', 'the reason code matches the payment''s state');
select throws_ok($$select public.request_refund('k-refund-0003', pg_temp.pay('02'), '5001', null, null, 'overpayment',
  'overpayment', '5000', 'trop perçu')$$, '23514', 'refund: more than what is left of the payment',
  'never more than what is left of the payment');
select throws_ok($$select public.request_refund('k-refund-0004', pg_temp.pay('02'), '5000', 'FR7630006000011234567890188',
  null, 'overpayment', 'overpayment', '5000', 'trop perçu')$$, '23514', 'refund: invalid IBAN',
  'the payee''s IBAN is checked (ISO 13616)');
select throws_ok($$select public.request_refund('k-refund-0005', pg_temp.pay('03'), '7000', null, 'X', 'unidentified',
  'no_match', '7000', 'inconnu')$$, '23514', 'refund: the payee''s IBAN is required (the bank gave none)',
  'no IBAN from the bank: ops give one');
select throws_ok($$select public.request_refund('k-refund-0006', pg_temp.pay('02'), '5000', null, null, 'overpayment',
  'overpayment', '5000', ' ')$$, '23514', 'a reason is required', 'a motif is required');
select ok((public.request_refund('k-refund-0010', pg_temp.pay('02'), '5000', null, null, 'overpayment', 'overpayment',
           '5000', 'trop perçu') ->> 'end_to_end_id') ~ '^RFD[0-9A-F]{12}$',
  'a refund of the overpayment to the payer''s IBAN: our end-to-end id RFD…');
select is(public.request_refund('k-refund-0010', pg_temp.pay('02'), '5000', null, null, 'overpayment', 'overpayment',
          '5000', 'trop perçu') ->> 'refund_request_id', pg_temp.refund_of('02')::text, 'the same request replays');
select throws_ok($$select public.request_refund('k-refund-0010', pg_temp.pay('02'), '4000', null, null, 'overpayment',
  'overpayment', '5000', 'trop perçu')$$, '22023', null, 'the same key for another request is refused');
reset role;
select is(pg_temp.state('02'), 'refund_pending/-', 'the payment waits for its refund');
select results_eq($$select status, prior_status, prior_review_reason, payee_is_payer, amount_minor
                    from public.refund_request where id = pg_temp.refund_of('02')$$,
  $$values ('requested'::text, 'partially_allocated'::text, 'overpayment'::text, true, 5000::bigint)$$,
  'requested, with the state it came from');
select is((select count(*)::int from public.ledger_entry e where e.payment_id = pg_temp.pay('02') and e.entry_type = 'cash_out'),
  0, 'nothing is booked when a refund is asked');
select ok(exists (select 1 from pgmq.q_payments where message ->> 'type' = 'process_debits'
                  and message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000aa'),
  'a refund request queues the debit job (its debit may be on a statement already)');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.request_refund('k-refund-0011', pg_temp.pay('02'), '5000', null, null, 'overpayment',
  null, '5000', 'encore')$$, '23514', null, 'one pending refund per payment');
select throws_ok(format($$select public.reverse_allocation('k-rev-0001', pg_temp.pay('02'), pg_temp.f('02'), %L::uuid[],
  'erreur')$$, (select array_agg(id) from public.ledger_entry where payment_id = pg_temp.pay('02') and entry_type = 'allocation')),
  '23514', null, 'an allocation is not reversed while a refund is pending (cancel it first)');
select is(public.cancel_refund('k-cancel-0001', pg_temp.refund_of('02'), 'IBAN à confirmer') ->> 'status', 'partially_allocated',
  'a refund cancelled before execution');
reset role;
select is(pg_temp.state('02'), 'partially_allocated/overpayment', 'the payment is back where it was');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.cancel_refund('k-cancel-0002', pg_temp.refund_of('02'), 'encore')$$, '23514',
  'refund: no longer pending: reload the page', 'a refund is cancelled once');
select lives_ok($$select public.request_refund('k-refund-0020', pg_temp.pay('02'), '5000', null, 'PAYEUR 02',
  'overpayment', 'overpayment', '5000', 'trop perçu')$$, 'asked again');
reset role;

-- The refund executed: the bank's RFD debit linked (by the job, or by ops) → cash_out at its date -----------------
select pg_temp.line('r1', 'debit', 'refund_out', 5000, '2026-10-21', pg_temp.rfd_of('02'));
select is((select minor from private.bank_unposted('80000000-0000-0000-0000-0000000000aa', '2026-10-21')), -5000::bigint,
  'not linked yet: an open gap (I9)');
select private.debit_link_begin();
insert into pg_temp._debit_link (ord, bank_transaction_id, kind, refund_request_id, method)
values (1, pg_temp.ln('r1'), 'refund', pg_temp.refund_of('02'), 'auto');
select is(private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa') ->> 'refunds', '1',
  'the debit job links our refund and books it');
select is(pg_temp.entries('02'), 'allocation@2026-10-05 cash_out@2026-10-21', 'a cash_out at the debit''s booking date');
select results_eq($$select la.book, lp.amount_minor from public.ledger_entry e join public.ledger_posting lp on lp.entry_id = e.id
                    join public.ledger_account la on la.id = lp.ledger_account_id
                    where e.payment_id = pg_temp.pay('02') and e.entry_type = 'cash_out' order by lp.line_no$$,
  $$values ('unallocated_payment'::text, 5000::bigint), ('client_money_cash'::text, -5000::bigint)$$,
  'Dr 4710 pool / Cr 5120 (design §8.1)');
select is(pg_temp.state('02'), 'allocated/-', 'what is left was refunded: allocated');
select results_eq($$select status, executed_on from public.refund_request where id = pg_temp.refund_of('02')$$,
  $$values ('executed'::text, '2026-10-21'::date)$$, 'the request executed');
select results_eq($$select kind, method from public.bank_debit_link where bank_transaction_id = pg_temp.ln('r1')$$,
  $$values ('refund'::text, 'auto'::text)$$, 'the line is linked');
select is((select minor from private.bank_unposted('80000000-0000-0000-0000-0000000000aa', '2026-10-21')), 0::bigint,
  'booked: no gap left (I9)');
select throws_ok($$update public.bank_debit_link set reason = 'x'$$, '23514', null, 'links are facts (append-only)');
select throws_ok($$update public.refund_request set status = 'cancelled', cancelled_at = now(), cancel_reason = 'x'
                   where id = pg_temp.refund_of('02')$$, '23514', null, 'an executed refund is never cancelled');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.link_debit('k-link-0001', pg_temp.ln('r1'), 'explained', null, null, null, 'x')$$, '23514',
  'debit link refused: already_linked', 'a line is linked once');
reset role;

-- The refund came back unpaid: its cash_out reversed at the credit's date -------------------------------------------
select pg_temp.line('b1', 'credit', 'return', 5000, '2026-10-23', pg_temp.rfd_of('02'));
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.link_debit('k-link-0002', pg_temp.ln('b1'), 'refund_returned', null, pg_temp.refund_of('02'),
  null, ' ')$$, '23514', 'a reason is required', 'ops give a motif');
select lives_ok($$select public.link_debit('k-link-0003', pg_temp.ln('b1'), 'refund_returned', null, pg_temp.refund_of('02'),
  null, 'IBAN clôturé')$$, 'ops link the refund that came back');
reset role;
select is(pg_temp.entries('02'), 'allocation@2026-10-05 cash_out@2026-10-21 reversal(cash_out)@2026-10-23',
  'the refund''s cash_out reversed at the credit''s date');
select is(pg_temp.state('02'), 'partially_allocated/-',
  'the payment''s state from its facts now: on its file, for the allocation job to gate again (not the reason of the refund)');
select ok(exists (select 1 from pgmq.q_payments where message ->> 'type' = 'allocate'
                  and message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000aa'),
  'the allocation job is queued for it');
select is((select status from public.refund_request where id = pg_temp.refund_of('02')), 'bounced', 'the request bounced');
select is(pg_temp.left_of('02'), '5000', 'its 5 000 left again');
select pg_temp.gate('02', '02', 'nothing_due');
select is(pg_temp.state('02'), 'partially_allocated/nothing_due', 'the job finds nothing more due on the file: for ops again');

-- A partial return while a refund is pending waits for ops to cancel the refund first ---------------------------------
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.request_refund('k-refund-0030', pg_temp.pay('02'), '1000', null, null, 'overpayment',
  'nothing_due', '5000', 'remboursement partiel')$$, 'a partial refund asked');
reset role;
select pg_temp.line('t4', 'debit', 'return', 1000, '2026-11-05', 'E2E-02');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.link_debit('k-link-0050', pg_temp.ln('t4'), 'return', pg_temp.pay('02'), null, '25000',
  'retour partiel')$$, '23514', 'debit link refused: refund_pending', 'a partial return waits while a refund is pending');
select lives_ok($$select public.cancel_refund('k-cancel-0030', pg_temp.refund_of('02'), 'retour bancaire en cours')$$,
  'ops cancel the refund');
select lives_ok($$select public.link_debit('k-link-0051', pg_temp.ln('t4'), 'return', pg_temp.pay('02'), null, '25000',
  'retour partiel')$$, 'then link the partial return');
reset role;
select is(pg_temp.state('02'), 'matched/partial_return', 'every allocation undone, the rest (24 000) waits for ops');
select is(pg_temp.left_of('02'), '24000', 'what is left: 25 000 − 1 000 returned');

-- A bank return (founder #13; design §2 #3): allocations reversed at the RETURN date, cash_out, returned ----------
select pg_temp.line('t1', 'debit', 'return', 40000, '2026-11-03', 'E2E-01');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.link_debit('k-link-0010', pg_temp.ln('t1'), 'return', pg_temp.pay('01'), null, '39999',
  'retour')$$, '23514', 'debit link refused: payment_changed', 'compare and set: what is left as the page showed it');
select throws_ok($$select public.link_debit('k-link-0011', pg_temp.ln('t1'), 'return', pg_temp.pay('03'), null, '7000',
  'retour')$$, '23514', 'debit link refused: amount_exceeds', 'never more than what is left of the payment');
select lives_ok($$select public.link_debit('k-link-0012', pg_temp.ln('t1'), 'return', pg_temp.pay('01'), null, '40000',
  'retour bancaire')$$, 'ops link the return');
reset role;
select is(pg_temp.entries('01'), 'allocation@2026-10-05 reversal(allocation)@2026-11-03 cash_out@2026-11-03',
  'the allocation is reversed on the return date (never back-dated), then the cash_out');
select is(pg_temp.state('01'), 'returned/-', 'the payment is returned');
select is(pg_temp.balance('01', '1'), 50000::bigint, 'the debt reopens');
select results_eq($$select kind, reason, account_id from public.client_notification where payment_id = pg_temp.pay('01')
                    and kind <> 'payment_allocated' order by kind$$,
  $$values ('payment_allocation_reversed'::text, 'bank_return'::text, pg_temp.f('01')),
           ('payment_returned'::text, 'bank_return'::text, pg_temp.f('01'))$$,
  'the client is told: the allocation undone and the return (founder #13)');
select ok(exists (select 1 from pgmq.q_payments where message ->> 'type' = 'receipts'
                  and message -> 'payment_ids' ? pg_temp.pay('01')::text),
  'the receipts job is queued (its void version is final for a returned payment)');
select throws_ok($$update public.payment set status = 'matched' where id = pg_temp.pay('01')$$, '23514', null,
  'a returned payment stays returned');
select throws_ok($$insert into public.client_notification (organization_id, client_organization_id, account_id, payment_id,
  ledger_entry_id, kind, reason) values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
  pg_temp.f('01'), pg_temp.pay('01'), (select id from public.ledger_entry where payment_id = pg_temp.pay('01')
  and entry_type = 'reversal'), 'payment_returned', 'bank_return')$$, '23505', null,
  'a return notification names the cash_out entry, once');

-- A partial return: everything reversed at the return date, the rest waits for ops, allocated again from then on -----
select pg_temp.line('t2', 'debit', 'return', 4000, '2026-11-02', 'E2E-04');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.link_debit('k-link-0020', pg_temp.ln('t2'), 'return', pg_temp.pay('04'), null, '10000',
  'retour partiel')$$, 'ops link a partial return');
reset role;
select is(pg_temp.state('04'), 'matched/partial_return', 'what is left waits for ops');
select is(pg_temp.left_of('04'), '6000', '6 000 left of 10 000');
select is(pg_temp.balance('01', '2'), 30000::bigint, 'the whole allocation was undone');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.allocate_payment('k-alloc-0001', pg_temp.pay('04'), 'partial_return', null, null,
  'le débiteur confirme')$$, '« Imputer » from partial_return');
reset role;
select throws_ok($$select pg_temp.allocate('04', '01', '[["2", 6000]]', '2026-10-05')$$, 'LG006', null,
  'not at the booking date: the money was allocated until the return');
select lives_ok($$select pg_temp.allocate('04', '01', '[["2", 6000]]', '2026-11-02')$$, 'allocated again from the return date');
select is(pg_temp.state('04'), 'allocated/-', 'allocated');

-- A forwarded payment the bank takes back: the forward undone at the return date, the client told ------------------
select pg_temp.file('03', '20000000-0000-0000-0000-0000000000a1', 'Rappel SA');
select pg_temp.item('03', '1', '2026-08-01', 9000);
update public.account set status = 'closed_recalled' where id = pg_temp.f('03');
select pg_temp.payment('05', 3000);
select pg_temp.match('05', '03', 'account_closed');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.forward_payment('k-fwd-0001', pg_temp.pay('05'), null, '3000', null, 'dossier rappelé')$$,
  'a recalled file''s payment forwarded to the client');
reset role;
select pg_temp.line('t3', 'debit', 'return', 3000, '2026-11-04', 'E2E-05');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.link_debit('k-link-0040', pg_temp.ln('t3'), 'return', pg_temp.pay('05'), null, '3000',
  'retour bancaire')$$, 'its return linked');
reset role;
select is(pg_temp.entries('05'), format('forward@%1$s reversal(forward)@%1$s cash_out@2026-11-04', private.paris_today()),
  'returned before the forward''s date: the forward reversed at its own date, the cash_out at the return date (I4 holds)');
select results_eq($$select kind, reason from public.client_notification where payment_id = pg_temp.pay('05') order by kind$$,
  $$values ('payment_forward_reversed'::text, 'bank_return'::text), ('payment_forwarded'::text, 'file_recalled'::text),
           ('payment_returned'::text, 'bank_return'::text)$$,
  'the client is told the forward is undone and the payment returned');

-- Lines ops explain (founder #20: not booked) -------------------------------------------------------------------------
select pg_temp.line('x1', 'credit', 'return', 290, '2026-11-04', null, '80000000-0000-0000-0000-0000000000aa', 'FRAIS REPRIS');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.link_debit('k-link-0030', pg_temp.ln('x1'), 'return', pg_temp.pay('03'), null, '7000',
  'x')$$, '23514', 'debit link refused: not_a_return', 'a credit is not a payment''s return');
select lives_ok($$select public.link_debit('k-link-0031', pg_temp.ln('x1'), 'explained', null, null, null,
  'frais repris par la banque')$$, 'ops explain it');
reset role;
select is((select minor from private.bank_unposted('80000000-0000-0000-0000-0000000000aa', '2026-11-04')), 290::bigint,
  'explained, still not booked: the explained gap (I9)');

-- 20261110130000 (plan robustness) redefines private.debit_candidates (keyed lookups that hold the key alone); the
-- rows must be those of the function it replaced (20261110120000 as merged, copied below), with multiplicity.
create function pg_temp.debit_candidates_applied(p_organization_id uuid, p_after_date date, p_after_id uuid,
                                                    p_limit integer)
returns table (line_id uuid, line_kind text, direction text, bank_account_id uuid, amount_minor bigint,
               booking_date date, payment_id uuid, refund_request_id uuid, via text, cand_bank_account_id uuid,
               cand_amount_minor bigint, cand_left_minor bigint, cand_unallocated_minor bigint,
               cand_pending_minor bigint, cand_status text, cand_date date, cand_payment_status text,
               cand_free_from date)
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
#variable_conflict use_column
begin
  drop table if exists pg_temp._dc_line;
  create temp table _dc_line on commit drop as
  select x.* from (
    select t.id, coalesce(r.released_kind, t.kind) as kind, t.direction, t.bank_account_id, t.amount_minor,
           t.booking_date, t.end_to_end_id, t.original_end_to_end_id, t.tx_id
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = p_organization_id
      and t.kind in ('return', 'refund_out', 'suspected_duplicate')
      and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
      and (t.kind <> 'suspected_duplicate' or r.decision = 'released')
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
    order by t.booking_date, t.id) x
  where (x.direction = 'debit' and x.kind in ('return', 'refund_out')) or (x.direction = 'credit' and x.kind = 'return')
  order by x.booking_date, x.id
  limit greatest(coalesce(p_limit, 10000), 1);
  analyze pg_temp._dc_line;

  drop table if exists pg_temp._dc_cand;
  create temp table _dc_cand on commit drop as
  -- a return of a credit: the payment that carries its end-to-end id, or whose line carries its bank transaction id
  select x.id as line_id, c.payment_id, null::uuid as refund_request_id, c.via
  from pg_temp._dc_line x
  cross join lateral (
    select p.id as payment_id, 'end_to_end_id'::text as via from public.payment p
    where p.end_to_end_id = coalesce(x.original_end_to_end_id, x.end_to_end_id) and p.bank_account_id = x.bank_account_id
    union
    select p.id, 'tx_id' from public.bank_transaction o join public.payment p on p.bank_transaction_id = o.id
    where x.tx_id is not null and o.bank_account_id = x.bank_account_id and o.tx_id = x.tx_id and o.direction = 'credit'
  ) c
  where x.direction = 'debit' and x.kind = 'return'
  union all
  -- our refund: the request whose RFD id the debit carries; a refund that came back: the one the credit names
  select x.id, q.payment_id, q.id, 'end_to_end_id'
  from pg_temp._dc_line x
  join public.refund_request q
    on q.end_to_end_id = case when x.direction = 'debit' then x.end_to_end_id
                              else coalesce(x.original_end_to_end_id, x.end_to_end_id) end
   and q.organization_id = p_organization_id and q.bank_account_id = x.bank_account_id   -- never another tenant's
  where x.kind = 'refund_out' or (x.direction = 'credit' and x.kind = 'return');
  create index on pg_temp._dc_cand (line_id);
  analyze pg_temp._dc_cand;

  -- Each payment named, once: its position, its pending refunds, its free-from date (keyed lookups per payment).
  drop table if exists pg_temp._dc_pos;
  create temp table _dc_pos on commit drop as
  select x.payment_id, x.amount_minor - x.returned_minor as left_minor, x.unallocated_minor,
         coalesce((select sum(z.amount_minor) from public.refund_request z
                   where z.payment_id = x.payment_id and z.status = 'requested'), 0)::bigint as pending_minor,
         (select max(e.effective_date) from public.ledger_entry e
          join public.ledger_entry v on v.id = e.reverses_entry_id
          where e.payment_id = x.payment_id and e.effective_date > v.effective_date) as free_from
  from private.payment_positions(array(select distinct y.payment_id from pg_temp._dc_cand y
                                       where y.payment_id is not null)) x;
  alter table pg_temp._dc_pos add primary key (payment_id);
  analyze pg_temp._dc_pos;

  return query
  select x.id, x.kind, x.direction, x.bank_account_id, x.amount_minor, x.booking_date, c.payment_id, c.refund_request_id,
         c.via, coalesce(q.bank_account_id, p.bank_account_id), coalesce(q.amount_minor, p.amount_minor),
         pos.left_minor, pos.unallocated_minor, pos.pending_minor,
         coalesce(q.status, p.status), coalesce(q.executed_on, p.booking_date), p.status, pos.free_from
  from pg_temp._dc_line x
  left join pg_temp._dc_cand c on c.line_id = x.id
  left join public.payment p on p.id = c.payment_id
  left join public.refund_request q on q.id = c.refund_request_id
  left join pg_temp._dc_pos pos on pos.payment_id = c.payment_id
  order by x.booking_date, x.id, c.payment_id;
end;
$$;
create function pg_temp.dc_same(p_org uuid) returns boolean language plpgsql as $$
declare v boolean;
begin
  drop table if exists pg_temp._dc_new;
  drop table if exists pg_temp._dc_old;
  create temp table _dc_new as select * from private.debit_candidates(p_org, null, null, 100);
  create temp table _dc_old as select * from pg_temp.debit_candidates_applied(p_org, null, null, 100);
  select not exists (select * from pg_temp._dc_new except all select * from pg_temp._dc_old)
     and not exists (select * from pg_temp._dc_old except all select * from pg_temp._dc_new)
     and exists (select 1 from pg_temp._dc_new)
    into v;
  return v;
end $$;

-- The job's reviews: what it leaves to ops ------------------------------------------------------------------------
select pg_temp.line('u1', 'debit', 'return', 1234, '2026-11-05', 'E2E-INCONNU');
select private.debit_link_begin();
insert into pg_temp._debit_review (bank_transaction_id, reason, candidates) values (pg_temp.ln('u1'), 'no_candidate', '[]');
select is(private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa') ->> 'reviews', '1', 'left to ops');
select is((select reason from public.bank_debit_review where bank_transaction_id = pg_temp.ln('u1')), 'no_candidate',
  'with why');
select is((select count(*)::int from private.debit_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 100)
           where line_id = pg_temp.ln('u1')), 1, 'the job looks at it again at each run');
select is((select count(*)::int from private.debit_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 100)
           where line_id in (pg_temp.ln('t1'), pg_temp.ln('r1'), pg_temp.ln('x1'))), 0, 'linked lines are done');
select ok(pg_temp.dc_same('00000000-0000-0000-0000-0000000000aa'),
  'debit candidates: the rows of the function they replaced (a line without any, linked lines left out)');

-- CSV suspected duplicates (design §8.3 step 5): released or confirmed ---------------------------------------------
select pg_temp.line('d1', 'credit', 'suspected_duplicate', 15000, '2026-10-06', null, '80000000-0000-0000-0000-0000000000ab',
                    'VIR SEPA DUPONT LOYER');
select pg_temp.line('d2', 'credit', 'suspected_duplicate', 8000, '2026-10-06', null, '80000000-0000-0000-0000-0000000000ab',
                    'VIR SEPA MARTIN LOYER');
select throws_ok($$insert into public.payment (organization_id, bank_account_id, bank_transaction_id, channel, method,
  amount_minor, currency, booking_date) values ('00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000ab',
  pg_temp.ln('d1'), 'csv', 'sct', 15000, 'EUR', '2026-10-06')$$, '23514', null,
  'a held line is not a payment until ops release it');
set local role authenticated;
select pg_temp.as_user('02');
select throws_ok($$select public.resolve_duplicate('k-dup-0001', pg_temp.ln('d1'), false, 'x')$$, '42501', null,
  'a collector cannot decide');
select pg_temp.as_user('01');
select is((select held_kind from public.debit_queue('doublons', 0, 100) where bank_transaction_id = pg_temp.ln('d1')),
  'debtor_credit', 'the duplicates tab says how the import read a held line (the « Libérer » sheet names one outcome)');
select is(public.resolve_duplicate('k-dup-0002', pg_temp.ln('d1'), false, 'deux loyers') ->> 'kind', 'debtor_credit',
  'released as the credit it was');
select is(public.resolve_duplicate('k-dup-0003', pg_temp.ln('d2'), true, 'même opération') ->> 'decision', 'duplicate',
  'confirmed as a duplicate');
select throws_ok($$select public.resolve_duplicate('k-dup-0004', pg_temp.ln('d2'), false, 'x')$$, '23514',
  'duplicate: already decided: reload the page', 'decided once');
reset role;
select results_eq($$select p.status, p.channel, p.amount_minor from public.payment p where p.bank_transaction_id = pg_temp.ln('d1')$$,
  $$values ('unmatched'::text, 'csv'::text, 15000::bigint)$$, 'the released line is a payment');
select is((select sum(lp.amount_minor) from public.ledger_entry e join public.ledger_posting lp on lp.entry_id = e.id
           join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'client_money_cash'
           where e.entry_type = 'cash_in' and e.source_id = pg_temp.ln('d1')::text), 15000::numeric,
  'its cash_in, on its statement day');
select is((select count(*)::int from public.payment where bank_transaction_id = pg_temp.ln('d2')), 0,
  'a duplicate is never booked');
select ok(exists (select 1 from pgmq.q_payments where message ->> 'type' = 'match'
                  and message ->> 'trigger' = 'import'), 'the released payment is matched by the next job');

-- Payments made to the client directly (design §8.1): the client's statement, the waterfall, an adjustment ---------
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.record_direct_payment('k-direct-0001', pg_temp.f('01'), '{}', '5000', '2026-10-15',
  'd1000000-0000-0000-0000-000000000002', 'relevé')$$, '23514',
  'direct payment: the client''s statement is required, filed on this file', 'the evidence is a document of the file');
select throws_ok($$select public.record_direct_payment('k-direct-0002', pg_temp.f('01'), '{}', '5000', '2026-09-01',
  'd1000000-0000-0000-0000-000000000001', 'relevé')$$, '23514',
  'direct payment: the date is in the future or before the servicing started', 'not before the servicing start');
select throws_ok(format($$select public.record_direct_payment('k-direct-0003', pg_temp.f('01'), %L, '5000', '2026-10-15',
  'd1000000-0000-0000-0000-000000000001', 'relevé')$$, array[pg_temp.it('02', '1')]), '23514',
  'direct payment: invoices of this file only', 'the debts named are the file''s');
select ok((public.record_direct_payment('k-direct-0004', pg_temp.f('01'), array[pg_temp.it('01', '2')], '5000',
           '2026-10-15', 'd1000000-0000-0000-0000-000000000001', 'relevé du client') ->> 'queued')::boolean,
  'recorded, for the worker''s waterfall');
reset role;
select ok(exists (select 1 from pgmq.q_payments where message ->> 'type' = 'direct_payment'), 'the job is queued');
select throws_ok($$select private.post_direct_payment((select id from public.direct_payment where account_id = pg_temp.f('01')),
  jsonb_build_array(jsonb_build_object('claim_item_id', pg_temp.it('01', '2'), 'component', 'principal', 'amount_minor', '4000')),
  'alloc-1', repeat('0', 64))$$, '22023', null, 'the plan adds up to the amount');
select isnt(private.post_direct_payment((select id from public.direct_payment where account_id = pg_temp.f('01')),
  jsonb_build_array(jsonb_build_object('claim_item_id', pg_temp.it('01', '2'), 'component', 'principal', 'amount_minor', '5000')),
  'alloc-1', repeat('0', 64)), null, 'the worker''s plan is booked');
select results_eq($$select e.entry_type, e.effective_date, e.source_type from public.direct_payment d
                    join public.ledger_entry e on e.id = d.entry_id where d.account_id = pg_temp.f('01')$$,
  $$values ('adjustment'::text, '2026-10-15'::date, 'direct_payment'::text)$$, 'an adjustment at the client''s date');
select is(pg_temp.balance('01', '2'), 19000::bigint, 'the debt goes down: 30 000 − 6 000 allocated − 5 000 paid directly');
select is((select count(*)::int from public.ledger_posting lp join public.ledger_account la on la.id = lp.ledger_account_id
           join public.direct_payment d on d.entry_id = lp.entry_id
           where la.book in ('client_money_cash', 'unallocated_payment', 'client_payable')), 0,
  'no client money moves (M2-12)');
select throws_ok($$update public.direct_payment set reason = 'x' where account_id = pg_temp.f('01')$$, '23514', null,
  'decided once, nothing else changes');

-- Read access (founder #18) ---------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('01');
select ok((select count(*) from public.refund_request) = 3 and (select count(*) from public.bank_debit_link) = 7
          and (select count(*) from public.bank_debit_review) = 1 and (select count(*) from public.bank_duplicate_resolution) = 2,
  'money staff read the refunds, links, reviews and duplicate decisions of their servicer');
select is((select count(*)::int from public.debit_queue('a-classer')), 1, 'the queue lists the line left to ops');
select is((select count(*)::int from public.debit_queue('traites')), 9, 'and the lines decided');
select pg_temp.as_user('05');
select ok((select count(*) from public.refund_request) + (select count(*) from public.bank_debit_link)
          + (select count(*) from public.bank_debit_review) + (select count(*) from public.direct_payment)
          + (select count(*) from public.debit_queue('a-classer')) = 0, 'another servicer reads none of it');
select pg_temp.as_user('02');
select ok((select count(*) from public.refund_request) + (select count(*) from public.bank_debit_link)
          + (select count(*) from public.bank_duplicate_resolution) + (select count(*) from public.debit_queue('a-classer')) = 0,
  'a collector reads no bank lines nor refunds (third-party payer data)');
select is((select count(*)::int from public.direct_payment), 0, 'nor direct payments outside its portfolios');
select pg_temp.as_user('03');
select ok((select count(*) from public.refund_request) + (select count(*) from public.direct_payment)
          + (select count(*) from public.payment_check_run) = 0, 'a client reads none of it');
select pg_temp.as_user('01', 'aal1');
select is((select count(*)::int from public.refund_request), 0, 'nor staff without MFA');
reset role;

-- The nightly checks (design §9): a clean servicer, then a planted inconsistency -------------------------------------
select is((private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'violations')::int, 0,
  'the books of the servicer hold: I4, I5, I6, I8, I11, owner mirror, notifications');
update public.payment set status = 'allocated', review_reason = null where id = pg_temp.pay('03');
select is(private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') -> 'by_code' ->> 'payment_position', '1',
  'a status that does not say what the ledger does is found');
select results_eq($$select r.code, r.subject_id from public.payment_check_result r
                    join public.payment_check_run x on x.id = r.run_id
                    where x.organization_id = '00000000-0000-0000-0000-0000000000aa' and r.severity = 'violation'$$,
  $$values ('payment_position'::text, pg_temp.pay('03'))$$, 'the payment named');
update public.payment set status = 'unmatched', review_reason = 'no_match' where id = pg_temp.pay('03');
select is(private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') -> 'by_code' ->> 'unmatched_ageing', '1',
  'and the ageing alert of money not matched 20 days after its booking');
select results_eq($$select r.subject_type, r.details -> 'ids' ? pg_temp.pay('03')::text from public.payment_check_result r
                    join public.payment_check_run x on x.id = r.run_id
                    where x.organization_id = '00000000-0000-0000-0000-0000000000aa' and r.code = 'unmatched_ageing'
                    order by x.started_at desc limit 1$$,
  $$values ('servicer'::text, true)$$, 'it names the payment (booked 2026-10-05)');
select throws_ok($$insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type)
  select id, organization_id, 'x', 'alert', 'servicer' from public.payment_check_run
  where organization_id = '00000000-0000-0000-0000-0000000000aa' limit 1$$, '23514', null,
  'results are written by their run only, before it finishes');
set local role authenticated;
select pg_temp.as_user('01');
select ok((select count(*) from public.payment_check_run) >= 2, 'money staff read the runs');
select pg_temp.as_user('05');
select is((select count(*)::int from public.payment_check_result), 0, 'another servicer does not');
select pg_temp.as_user('02');
select throws_ok($$select public.request_payment_checks('00000000-0000-0000-0000-0000000000aa')$$, '42501', null,
  'a collector cannot run the checks');
reset role;


-- Review fixes: a bad line never stops the debit job; what cannot be booked stays to classify ---------------------------
select pg_temp.file('04', '20000000-0000-0000-0000-0000000000a1', 'Revue SA');
select pg_temp.item('04', '1', '2026-08-01', 100000);

-- A refund that comes back to a payment the bank took back since: never booked (where it goes: open question)
select pg_temp.payment('06', 25000, 'FR7630006000011234567890189');
select pg_temp.match('06', '04');
select pg_temp.allocate('06', '04', '[["1", 20000]]');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.request_refund('k-refund-0060', pg_temp.pay('06'), '5000', null, null, 'overpayment',
  'overpayment', '5000', 'trop perçu')$$, 'review fixes: the overpayment refunded');
reset role;
select pg_temp.line('r6', 'debit', 'refund_out', 5000, '2026-10-21', pg_temp.rfd_of('06'));
select private.debit_link_begin();
insert into pg_temp._debit_link (ord, bank_transaction_id, kind, refund_request_id, method)
values (1, pg_temp.ln('r6'), 'refund', pg_temp.refund_of('06'), 'auto');
select private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
select pg_temp.line('t6', 'debit', 'return', 20000, '2026-10-25', 'E2E-06');
select private.debit_link_begin();
insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, method)
values (1, pg_temp.ln('t6'), 'return', pg_temp.pay('06'), 'auto');
select private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
select is(pg_temp.state('06'), 'returned/-', 'then the bank takes the rest back');
select pg_temp.line('b6', 'credit', 'return', 5000, '2026-10-27', pg_temp.rfd_of('06'));
select results_eq($$select refund_request_id, cand_status, cand_payment_status
                    from private.debit_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 100)
                    where line_id = pg_temp.ln('b6')$$,
  $$values (pg_temp.refund_of('06'), 'executed'::text, 'returned'::text)$$,
  'the job sees the refund the credit names, and that its payment was returned since (payments.debits: to ops)');
select ok(pg_temp.dc_same('00000000-0000-0000-0000-0000000000aa'),
  'debit candidates: the same rows with a refund that came back (its request by RFD id)');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.link_debit('k-link-0060', pg_temp.ln('b6'), 'refund_returned', null, pg_temp.refund_of('06'),
  null, 'retour du remboursement')$$, '23514', 'debit link refused: payment_returned',
  'ops get a clear refusal, not the returned payment''s guard');
reset role;
select private.debit_link_begin();
insert into pg_temp._debit_link (ord, bank_transaction_id, kind, refund_request_id, method)
values (1, pg_temp.ln('b6'), 'refund_returned', pg_temp.refund_of('06'), 'auto');
select is(private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa') ->> 'skipped', '1',
  'the job''s re-check skips it: the run goes on');
select is(pg_temp.state('06'), 'returned/-', 'nothing booked on the returned payment');

-- A return dated before a later-dated reversal of the payment (its money was allocated that day: I4)
select pg_temp.payment('07', 10000);
select pg_temp.match('07', '04');
select pg_temp.allocate('07', '04', '[["1", 10000]]');
select pg_temp.line('t7a', 'debit', 'return', 6000, '2026-11-01', 'E2E-07');
select pg_temp.line('t7b', 'debit', 'return', 4000, '2026-11-02', 'E2E-07');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.link_debit('k-link-0070', pg_temp.ln('t7b'), 'return', pg_temp.pay('07'), null, '10000',
  'retour partiel')$$, 'ops link the later partial return first');
reset role;
select results_eq($$select cand_left_minor, cand_free_from
                    from private.debit_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 100)
                    where line_id = pg_temp.ln('t7a')$$,
  $$values (6000::bigint, '2026-11-02'::date)$$,
  'the earlier line is exactly what is left now, but dated before the payment''s free-from date');
select ok(pg_temp.dc_same('00000000-0000-0000-0000-0000000000aa'),
  'debit candidates: the same rows with returns of a payment by its end-to-end id');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.link_debit('k-link-0071', pg_temp.ln('t7a'), 'return', pg_temp.pay('07'), null, '6000',
  'retour partiel')$$, '23514', 'debit link refused: before_previous_return',
  'never out of the payment on a day its money was allocated: a clear refusal, not LG007');
reset role;
select private.debit_link_begin();
insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, method)
values (1, pg_temp.ln('t7a'), 'return', pg_temp.pay('07'), 'auto');
select is(private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa') ->> 'skipped', '1',
  'the job''s re-check skips it: the run goes on');
select is(pg_temp.state('07'), 'matched/partial_return', 'nothing booked');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.request_refund('k-refund-0070', pg_temp.pay('07'), '1000', 'FR7630006000011234567890189',
  'PAYEUR 07', 'partial_return', 'partial_return', '6000', 'reste remboursé')$$, 'a refund of what is left');
reset role;
select pg_temp.line('r7', 'debit', 'refund_out', 1000, '2026-11-01', pg_temp.rfd_of('07'));
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.link_debit('k-link-0072', pg_temp.ln('r7'), 'refund', null, pg_temp.refund_of('07'), null,
  'virement fait avant la saisie')$$, '23514', 'debit link refused: before_previous_return',
  'a refund the bank booked before that date neither');
select lives_ok($$select public.cancel_refund('k-cancel-0070', pg_temp.refund_of('07'), 'date à vérifier')$$, 'cancelled');
reset role;

-- A line the posting itself refuses (a planted ledger refusal) goes to ops; the other lines of the run are booked
select pg_temp.payment('08', 3000);
select pg_temp.payment('09', 2000);
update public.payment set review_reason = 'no_match' where id in (pg_temp.pay('08'), pg_temp.pay('09'));
select pg_temp.line('t8', 'debit', 'return', 3000, '2026-11-03', 'E2E-08');
select pg_temp.line('t9', 'debit', 'return', 2000, '2026-11-03', 'E2E-09');
create function public.test_refuse_cash_out() returns trigger language plpgsql as $$
begin
  raise exception 'ledger: planted refusal' using errcode = 'LG007';
end $$;
create trigger test_refuse_cash_out before insert on public.ledger_entry for each row
  when (new.payment_id = 'f1000000-0000-0000-0000-000000000008' and new.entry_type = 'cash_out')
  execute function public.test_refuse_cash_out();
select private.debit_link_begin();
insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, method) values
  (1, pg_temp.ln('t8'), 'return', pg_temp.pay('08'), 'auto'),
  (2, pg_temp.ln('t9'), 'return', pg_temp.pay('09'), 'auto');
select results_eq($$select (x ->> 'returns')::int, (x ->> 'failed')::int, (x ->> 'skipped')::int, (x ->> 'reviews')::int
                    from (select private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa') as x) y$$,
  $$values (1, 1, 0, 1)$$, 'one line refused by the posting: the other is booked, the run does not fail');
select results_eq($$select reason, left(detail, 30), candidates from public.bank_debit_review
                    where bank_transaction_id = pg_temp.ln('t8')$$,
  $$values ('posting_failed'::text, 'LG007: ledger: planted refusal'::text,
            jsonb_build_array(jsonb_build_object('payment_id', pg_temp.pay('08'))))$$,
  'the refused line waits for ops, with why (support)');
select is(pg_temp.state('09'), 'returned/-', 'the other line of the run is booked');
select is((select count(*)::int from public.ledger_entry where payment_id = pg_temp.pay('08')), 0,
  'nothing of the refused one is left in the ledger');
set local role authenticated;
select pg_temp.as_user('01');
select throws_like($$select public.link_debit('k-link-0080', pg_temp.ln('t8'), 'return', pg_temp.pay('08'), null, '3000',
  'retour')$$, 'debit link refused: posting_failed (LG007: ledger: planted refusal%', 'ops get a clear refusal');
reset role;
drop trigger test_refuse_cash_out on public.ledger_entry;

-- The job links a return only for exactly what is left now (a payment that changed since it read it: re-decided)
select pg_temp.payment('10', 5000);
update public.payment set review_reason = 'no_match' where id = pg_temp.pay('10');
select pg_temp.line('t10', 'debit', 'return', 4000, '2026-11-03', 'E2E-10');
select private.debit_link_begin();
insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, method)
values (1, pg_temp.ln('t10'), 'return', pg_temp.pay('10'), 'auto');
select private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
select is((select why from pg_temp._debit_skipped where bank_transaction_id = pg_temp.ln('t10')), 'payment_changed',
  'an automatic partial return is refused on re-check (ops decide partial returns)');
select is(pg_temp.state('10'), 'unmatched/no_match', 'nothing booked');

-- Money that went out for a payment is booked, never only explained: it stays to classify
select pg_temp.line('r10', 'debit', 'refund_out', 777, '2026-11-03', 'RFD000000000099');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.link_debit('k-link-0100', pg_temp.ln('t10'), 'explained', null, null, null, 'inconnu')$$,
  '23514', 'debit link refused: not_explainable', 'a bank return cannot be « expliqué »');
select throws_ok($$select public.link_debit('k-link-0101', pg_temp.ln('r10'), 'explained', null, null, null, 'inconnu')$$,
  '23514', 'debit link refused: not_explainable', 'nor a debit carrying our RFD id');
select is((select count(*)::int from public.debit_queue('a-classer', 0, 100)
           where bank_transaction_id in (pg_temp.ln('t10'), pg_temp.ln('r10'))), 2, 'both stay to classify');
reset role;
-- a return whose references name none of our payments (a fee's direct debit the bank rejected) is explained, with a motif
select pg_temp.line('n10', 'debit', 'return', 5000, '2026-11-03', 'NOT-OURS-10');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.link_debit('k-link-0102', pg_temp.ln('n10'), 'explained', null, null, null,
  'rejet d''un prélèvement de frais, hors fonds de tiers')$$, 'a return naming none of our payments is explained');
reset role;

-- An other debit of a pending refund's amount on its bank account may be that refund (the bank dropped our RFD id)
select pg_temp.payment('11', 4000, 'FR7630006000011234567890189');
update public.payment set review_reason = 'no_match' where id = pg_temp.pay('11');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.request_refund('k-refund-0110', pg_temp.pay('11'), '4000', null, null, 'unidentified',
  'no_match', '4000', 'payeur inconnu')$$, 'a refund of an unidentified payment');
reset role;
select pg_temp.line('o11', 'debit', 'other_debit', 4000, '2026-11-05', null, '80000000-0000-0000-0000-0000000000aa',
                    'VIR SEPA EMIS');
select pg_temp.line('f11', 'debit', 'other_debit', 1234, '2026-11-05', null, '80000000-0000-0000-0000-0000000000aa', 'FRAIS');
set local role authenticated;
select pg_temp.as_user('01');
select results_eq($$select kind, review_reason, candidates -> 0 ->> 'refund_request_id', candidates -> 0 ->> 'end_to_end_id',
                           candidates -> 0 ->> 'payer_name'
                    from public.debit_queue('a-classer', 0, 100) where bank_transaction_id = pg_temp.ln('o11')$$,
  $$values ('other_debit'::text, 'refund_amount_match'::text, pg_temp.refund_of('11')::text, pg_temp.rfd_of('11'),
            'PAYEUR 11'::text)$$,
  'listed to classify, with the pending refund it may be');
select results_eq($$select bank_transaction_id from public.debit_queue('frais', 0, 100)
                    where bank_transaction_id in (pg_temp.ln('o11'), pg_temp.ln('f11'))$$,
  $$values (pg_temp.ln('f11'))$$, 'not among the fees (a fee of another amount is)');
reset role;
select private.run_payment_checks('00000000-0000-0000-0000-0000000000aa');
select ok((select r.details -> 'ids' ? pg_temp.ln('o11')::text from public.payment_check_result r
           join public.payment_check_run x on x.id = r.run_id
           where x.organization_id = '00000000-0000-0000-0000-0000000000aa' and r.code = 'debit_unclassified'
           order by x.started_at desc limit 1),
  'and in the ageing alert of lines to classify');

-- Tenant isolation: another servicer's line naming our RFD id, and candidate ids of ours in its review
insert into public.bank_account (id, organization_id, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000bb', 'FR7630006000011234567890189', 'EUR',
   'Autre', 'camt053', '2026-01-01');
select pg_temp.stmt(md5('bb-line')::uuid, '80000000-0000-0000-0000-0000000000bb');
insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind, end_to_end_id)
values (md5('bb-line')::uuid, '00000000-0000-0000-0000-0000000000bb', '80000000-0000-0000-0000-0000000000bb',
        md5('bb-line')::uuid, 1, 'h:bb#1', 'debit', 4000, 'EUR', '2026-11-05', 'refund_out', pg_temp.rfd_of('11'));
select is((select count(*)::int from private.debit_candidates('00000000-0000-0000-0000-0000000000bb', null, null, 100)
           where line_id = md5('bb-line')::uuid and refund_request_id is null), 1,
  'tenant isolation: another servicer''s line naming our RFD id finds none of our refunds');
select ok(pg_temp.dc_same('00000000-0000-0000-0000-0000000000bb'),
  'debit candidates: the same rows for another servicer''s line naming our RFD id');
select private.debit_link_begin();
insert into pg_temp._debit_review (bank_transaction_id, reason, candidates)
values (md5('bb-line')::uuid, 'no_candidate',
        jsonb_build_array(jsonb_build_object('refund_request_id', pg_temp.refund_of('11'), 'payment_id', pg_temp.pay('11'))));
select private.apply_debit_decisions('00000000-0000-0000-0000-0000000000bb');
set local role authenticated;
select pg_temp.as_user('05');
select results_eq($$select candidates -> 0 ? 'payer_name', candidates -> 0 ? 'file_reference',
                           candidates -> 0 ? 'end_to_end_id', candidates -> 0 ? 'refund_status'
                    from public.debit_queue('a-classer') where bank_transaction_id = md5('bb-line')::uuid$$,
  $$values (false, false, false, false)$$,
  'tenant isolation: ids of another servicer in a review are never enriched with its payer or refund');
select is((select count(*)::int from public.debit_queue('a-classer')), 1, 'it sees its own line only');
reset role;
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.link_debit('k-link-0110', pg_temp.ln('o11'), 'refund', null, pg_temp.refund_of('11'), null,
  'remboursement sans référence RFD')$$, 'ops link it to the refund');
reset role;
select is(pg_temp.state('11'), 'refunded/-', 'the refund is booked');

-- A direct payment the job could not book: refused, `failed` (never « en cours » for good)
set local role authenticated;
select pg_temp.as_user('01');
select public.record_direct_payment('k-direct-0005', pg_temp.f('01'), '{}', '1000', '2026-10-16',
                                    'd1000000-0000-0000-0000-000000000001', 'relevé du client');
reset role;
select private.refuse_direct_payment((select id from public.direct_payment where account_id = pg_temp.f('01')
                                      and status = 'requested'), 'failed');
select is((select count(*)::int from public.direct_payment where account_id = pg_temp.f('01') and status = 'refused'
             and refusal_code = 'failed'), 1, 'refused with the code the page shows');

select is((private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'violations')::int, 0,
  'after all of it, the books still hold');


-- 20261110130000 (plan robustness): payment_detail drives from the payment's entries and reaches every row it names by
-- key now; the page is that of the function it replaced (20261110120000 as merged, copied below), for every payment
-- (returns, refunds, bank lines linked, direct payments).
create function pg_temp.payment_detail_applied(p_payment_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  p public.payment;
  v jsonb;
begin
  select * into p from public.payment where id = p_payment_id and organization_id = any (private.money_staff_org_ids());
  if not found then
    return null;
  end if;
  select jsonb_build_object(
    'payment', jsonb_build_object(
      'id', p.id, 'amount_minor', p.amount_minor::text, 'currency', p.currency, 'booking_date', p.booking_date,
      'value_date', p.value_date, 'payer_name', p.payer_name, 'payer_iban_end', right(p.payer_iban, 4),
      'payer_iban_valid', coalesce(private.iban_valid(private.rf_normalise(p.payer_iban)), false),
      'remittance_text', p.remittance_text, 'creditor_reference', p.creditor_reference, 'end_to_end_id', p.end_to_end_id,
      'status', p.status, 'review_reason', p.review_reason, 'account_id', p.account_id, 'match_method', p.match_method,
      'matched_at', p.matched_at, 'designation', p.designation, 'instruction', p.allocation_instruction,
      'channel', p.channel, 'method', p.method),
    'position', (select jsonb_build_object('allocated_minor', x.allocated_minor::text,
                                           'unallocated_minor', x.unallocated_minor::text,
                                           'returned_minor', x.returned_minor::text,
                                           'left_minor', (x.amount_minor - x.returned_minor)::text,
                                           'forwarded_minor', (select coalesce(sum(lp.amount_minor), 0)
                                                               from public.ledger_entry e
                                                               left join public.ledger_entry t on t.id = e.reverses_entry_id
                                                               join public.ledger_posting lp on lp.entry_id = e.id
                                                               join public.ledger_account la on la.id = lp.ledger_account_id
                                                                 and la.book = 'unallocated_payment'
                                                               where e.payment_id = p.id
                                                                 and coalesce(t.entry_type, e.entry_type) = 'forward')::text)
                 from private.payment_positions(array[p.id]) x),
    'file', (select jsonb_build_object('account_id', a.id, 'external_ref', a.external_ref, 'status', a.status,
                                       'client_organization_id', a.client_organization_id, 'client_name', c.legal_name,
                                       'currency', a.currency, 'legal_regime', a.legal_regime,
                                       'debtor_name', (select min(pa.display_name) from public.account_party ap
                                                       join public.party pa on pa.id = ap.party_id
                                                       where ap.account_id = a.id and ap.role = 'borrower'),
                                       'holds', coalesce((select jsonb_agg(h.kind order by h.kind)
                                                          from public.account_hold h
                                                          where h.account_id = a.id and h.ended_at is null
                                                            and h.kind in ('surendettement', 'collective_proceeding')),
                                                         '[]'))
             from public.account a join public.organization c on c.id = a.client_organization_id
             where a.id = p.account_id),
    'matches', coalesce((select jsonb_agg(jsonb_build_object('action', m.action, 'account_id', m.account_id,
                                                             'external_ref', a.external_ref, 'method', m.method,
                                                             'rule', m.rule, 'trigger', m.trigger, 'reason', m.reason,
                                                             'review_reason', m.review_reason, 'decided_at', m.decided_at,
                                                             'by_ops', m.decided_by is not null)
                                          order by m.decided_at, m.id)
                         from public.payment_match m join public.account a on a.id = m.account_id
                         where m.payment_id = p.id), '[]'),
    'entries', coalesce((select jsonb_agg(jsonb_build_object(
                           'entry_id', e.id, 'entry_type', e.entry_type, 'effective_date', e.effective_date,
                           'posted_at', e.posted_at, 'reason', e.reason, 'account_id', e.account_id,
                           'ops_note', (select o.note from private.payment_ops_note o where o.entry_id = e.id),
                           'external_ref', (select a.external_ref from public.account a where a.id = e.account_id),
                           'reverses_entry_id', e.reverses_entry_id,
                           'reverses_type', (select t.entry_type from public.ledger_entry t where t.id = e.reverses_entry_id),
                           'reversed_by', (select r.id from public.ledger_entry r where r.reverses_entry_id = e.id),
                           'amount_minor', (select sum(lp.amount_minor) from public.ledger_posting lp
                                            join public.ledger_account la on la.id = lp.ledger_account_id
                                            where lp.entry_id = e.id and la.book = 'unallocated_payment')::text,
                           'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                                              'claim_item_id', la.claim_item_id, 'item_ref', i.ref, 'item_kind', i.kind,
                                              'due_date', i.due_date, 'component', la.component,
                                              'amount_minor', (-lp.amount_minor)::text)
                                            order by lp.line_no), '[]')
                                     from public.ledger_posting lp
                                     join public.ledger_account la on la.id = lp.ledger_account_id
                                     join public.claim_item i on i.id = la.claim_item_id
                                     where lp.entry_id = e.id and la.book = 'debtor_receivable'))
                         order by e.posted_at, e.id)
                         from public.ledger_entry e where e.payment_id = p.id), '[]'),
    'notifications', coalesce((select jsonb_agg(jsonb_build_object('kind', n.kind, 'created_at', n.created_at,
                                                                   'client_name', c.legal_name, 'reason', n.reason,
                                                                   'ledger_entry_id', n.ledger_entry_id,
                                                                   'delivered_at', n.delivered_at)
                                                order by n.created_at, n.id)
                               from public.client_notification n
                               join public.organization c on c.id = n.client_organization_id
                               where n.payment_id = p.id), '[]'),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object(
                           'id', q.id, 'amount_minor', q.amount_minor::text, 'payee_name', q.payee_name,
                           'payee_iban_end', right(q.payee_iban, 4), 'payee_is_payer', q.payee_is_payer,
                           'end_to_end_id', q.end_to_end_id, 'reason_code', q.reason_code, 'reason', q.reason,
                           'status', q.status, 'requested_at', q.requested_at, 'executed_on', q.executed_on,
                           'cancelled_at', q.cancelled_at, 'cancel_reason', q.cancel_reason)
                         order by q.requested_at, q.id)
                         from public.refund_request q where q.payment_id = p.id), '[]'),
    'bank_lines', coalesce((select jsonb_agg(jsonb_build_object(
                              'bank_transaction_id', l.bank_transaction_id, 'kind', l.kind, 'method', l.method,
                              'booking_date', t.booking_date, 'amount_minor', t.amount_minor::text,
                              'direction', t.direction, 'return_reason', t.return_reason,
                              'statement_id', t.statement_id, 'decided_at', l.decided_at, 'reason', l.reason)
                            order by t.booking_date, l.decided_at)
                            from public.bank_debit_link l join public.bank_transaction t on t.id = l.bank_transaction_id
                            where l.payment_id = p.id), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'created_at', d.created_at)
                                            order by d.created_at desc, d.id)
                           from public.document d where p.account_id is not null and d.account_id = p.account_id), '[]'),
    'other_files', coalesce((select jsonb_agg(jsonb_build_object('account_id', o.id, 'external_ref', o.external_ref)
                                              order by o.external_ref)
                             from public.account o
                             where p.account_id is not null and o.id <> p.account_id
                               and o.status not in ('staged', 'closed_paid', 'closed_settled', 'closed_uncollectable',
                                                    'closed_recalled')
                               and o.currency = p.currency
                               and exists (select 1 from public.account_party x
                                           join public.account_party y on y.party_id = x.party_id
                                           where x.account_id = p.account_id and y.account_id = o.id
                                             and x.role in ('borrower', 'co_borrower')
                                             and y.role in ('borrower', 'co_borrower'))), '[]')
  ) into v;
  return v;
end;
$$;

select pg_temp.as_user('01');
select is((select string_agg(p.id || ' ' || coalesce(public.payment_detail(p.id)::text, '-'), e'\n' order by p.id)
           from public.payment p),
          (select string_agg(p.id || ' ' || coalesce(pg_temp.payment_detail_applied(p.id)::text, '-'), e'\n'
                             order by p.id)
           from public.payment p),
  'the payment page: that of the function it replaced, for every payment');
select ok((select count(*) from public.payment p where (public.payment_detail(p.id) -> 'bank_lines') <> '[]') >= 1
          and (select count(*) from public.payment p where (public.payment_detail(p.id) -> 'refunds') <> '[]') >= 1,
  'bank lines linked and refunds among them');
select * from finish();
rollback;
