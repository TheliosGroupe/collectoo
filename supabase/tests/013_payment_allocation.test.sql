-- M2b-4 (M2-09, data half of M2-11): allocation. Design docs/design/m2b-payments.md §6–§9, §12; ADR-0013 (M2b-4
-- addendum). The worker's waterfall is played here by writing plans into pg_temp._alloc_target / _alloc_line and calling
-- private.post_allocations, as the payments.allocate job does in one transaction.
begin;
select plan(167);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Other servicer');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Client A1'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Client A2'),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Client B1');
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@alloc.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '06', '07']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000a2', 'client_admin'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000b1', 'client_admin');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', 'P1'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2', 'P2'),
  ('20000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000b1', 'PB');
insert into public.portfolio_access (user_id, portfolio_id) values  -- the collector works P1 only
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1');
insert into public.bank_account (id, organization_id, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000aa', 'FR3430001007940000000001001', 'EUR',
   'Fonds de tiers', 'camt053', '2026-01-01');

-- Files (servicing starts at the cut-off 2026-09-30, openings posted then); items (file, item, ref, kind, due date).
create or replace function pg_temp.file(p_n text, p_portfolio uuid, p_status text, p_regime text, p_name text,
                                        p_start date default '2026-09-30')
returns void language sql as $$
  insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                              legal_regime, currency, status)
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid, p.organization_id, p.client_organization_id, p.id,
         case when p_regime = 'commercial_b2b' then 'b2b_invoice' else 'consumer_instalment_loan' end, 'D-' || p_n,
         p_regime, 'EUR', p_status
  from public.portfolio p where p.id = p_portfolio;
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type,
                                             valid_from)
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid, p.client_organization_id, p.organization_id,
         'mandate_amicable', p_start
  from public.portfolio p where p.id = p_portfolio;
  insert into public.party (id, organization_id, client_organization_id, kind, display_name)
  select ('b1000000-0000-0000-0000-0000000000' || p_n)::uuid, p.organization_id, p.client_organization_id,
         'legal_entity', p_name
  from public.portfolio p where p.id = p_portfolio;
  insert into public.account_party (account_id, party_id, role, capacity)
  values (('a1000000-0000-0000-0000-0000000000' || p_n)::uuid, ('b1000000-0000-0000-0000-0000000000' || p_n)::uuid,
          'borrower', 'legal_entity');
$$;
create or replace function pg_temp.item(p_n text, p_i text, p_kind text, p_due date) returns void language sql as $$
  insert into public.claim_item (id, account_id, kind, ref, due_date, original_minor)
  values (('c1000000-0000-0000-0000-000000000' || p_n || p_i)::uuid, ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid,
          p_kind, 'I-' || p_n || p_i, p_due, 1);
$$;
create or replace function pg_temp.it(p_n text, p_i text) returns uuid language sql as $$
  select ('c1000000-0000-0000-0000-000000000' || p_n || p_i)::uuid;
$$;
create or replace function pg_temp.f(p_n text) returns uuid language sql as $$
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.owe_at(p_n text, p_i text, p_component text, p_amount bigint, p_date date)
returns void language sql as $$
  select entry_id from private.ledger_post(
    (select organization_id from public.account where id = pg_temp.f(p_n)), 'adjustment', p_date,
    'alloc-owe-' || p_n || p_i || p_component || p_date,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', pg_temp.it(p_n, p_i), 'component', p_component),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', p_component)),
    jsonb_build_object('account_id', pg_temp.f(p_n), 'reason', 'ouverture (test)'));
$$;
create or replace function pg_temp.owe(p_n text, p_i text, p_component text, p_amount bigint) returns void language sql as $$
  select pg_temp.owe_at(p_n, p_i, p_component, p_amount, '2026-09-30');
$$;
select pg_temp.file('01', '20000000-0000-0000-0000-0000000000a1', 'in_collection', 'commercial_b2b', 'Durand SA');
select pg_temp.item('01', '1', 'invoice', '2026-08-01');
select pg_temp.item('01', '2', 'invoice', '2026-08-01');
select pg_temp.owe('01', '1', 'principal', 50000);
select pg_temp.owe('01', '2', 'principal', 30000);
select pg_temp.file('02', '20000000-0000-0000-0000-0000000000a2', 'in_collection', 'commercial_b2b', 'Lilas SARL');
select pg_temp.item('02', '1', 'invoice', '2026-08-01');
select pg_temp.owe('02', '1', 'principal', 20000);
select pg_temp.file('03', '20000000-0000-0000-0000-0000000000a1', 'in_collection', 'consumer_credit_ccd2', 'Jean Prêt');
select pg_temp.item('03', '1', 'loan_principal', null);
select pg_temp.owe('03', '1', 'accrued_interest', 1000);
select pg_temp.owe('03', '1', 'principal', 9000);
select pg_temp.file('04', '20000000-0000-0000-0000-0000000000a1', 'in_collection', 'commercial_b2b', 'Rappel SA');
select pg_temp.item('04', '1', 'invoice', '2026-08-01');
select pg_temp.owe('04', '1', 'principal', 10000);
update public.account set status = 'closed_recalled' where id = pg_temp.f('04');
select pg_temp.file('05', '20000000-0000-0000-0000-0000000000a1', 'in_collection', 'commercial_b2b', 'Avoir SA');
select pg_temp.item('05', '1', 'invoice', '2026-08-01');
select pg_temp.item('05', '2', 'invoice', '2026-08-15');
select pg_temp.item('05', '3', 'credit_note', null);
select pg_temp.owe('05', '1', 'principal', 40000);
select pg_temp.owe('05', '2', 'principal', 20000);
select pg_temp.owe('05', '3', 'principal', -50000);
select pg_temp.file('06', '20000000-0000-0000-0000-0000000000a1', 'in_collection', 'commercial_b2b', 'Bloqué SA');
select pg_temp.item('06', '1', 'invoice', '2026-08-01');
select pg_temp.owe('06', '1', 'principal', 10000);
insert into public.document (id, organization_id, client_organization_id, account_id, kind, storage_path, sha256, mime_type)
values ('d1000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
        pg_temp.f('06'), 'evidence', 'test/alloc-jugement.pdf', repeat('a', 64), 'application/pdf'),
       ('d1000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
        pg_temp.f('01'), 'evidence', 'test/alloc-autre.pdf', repeat('b', 64), 'application/pdf');
insert into public.account_hold (organization_id, client_organization_id, portfolio_id, account_id, kind, scope,
                                 evidence_document_id, reason)
values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1',
        pg_temp.f('06'), 'surendettement', array['outbound', 'payment_requests'], 'd1000000-0000-0000-0000-000000000006',
        'recevabilité');

-- Payments: credit lines of an imported statement (booked 2026-10-05), then matched to a file.
create or replace function pg_temp.payment(p_n text, p_amount bigint) returns void language plpgsql as $$
declare s uuid := ('e1000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000aa', 'EUR', 'camt053', 'r.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000aa', s, 1, 't:' || s, 'credit',
          p_amount, 'EUR', '2026-10-05', 'debtor_credit');
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date)
  values (('f1000000-0000-0000-0000-0000000000' || p_n)::uuid, '00000000-0000-0000-0000-0000000000aa',
          '80000000-0000-0000-0000-0000000000aa', s, 'camt053', 'sct', p_amount, 'EUR', '2026-10-05');
end $$;
create or replace function pg_temp.pay(p_n text) returns uuid language sql as $$
  select ('f1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.match(p_n text, p_file text, p_reason text default null) returns void language sql as $$
  update public.payment set account_id = pg_temp.f(p_file), status = 'matched', match_method = 'rf_structured',
                            matched_at = now(), review_reason = p_reason
  where id = pg_temp.pay(p_n);
$$;
create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
create or replace function pg_temp.state(p_n text) returns text language sql as $$
  select status || '/' || coalesce(review_reason, '-') from public.payment where id = pg_temp.pay(p_n);
$$;
create or replace function pg_temp.balance(p_n text, p_i text, p_component text default 'principal') returns bigint
language sql as $$
  select coalesce(sum(lp.amount_minor), 0)::bigint from public.ledger_account la
  join public.ledger_posting lp on lp.ledger_account_id = la.id
  where la.claim_item_id = pg_temp.it(p_n, p_i) and la.component = p_component;
$$;
-- The job, played: one target and its lines.
create or replace function pg_temp.plan(p_n text, p_file text, p_outcome text, p_lines jsonb default '[]',
                                        p_date date default '2026-10-05') returns void language plpgsql as $$
begin
  perform private.allocation_begin();
  insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy, inputs_hash)
  values (pg_temp.pay(p_n), 1, pg_temp.f(p_file), p_outcome,
          case when p_outcome = 'allocate' then p_date end,
          case when p_outcome = 'allocate' then '{"accessory_rank": "before_principal", "unclassified": "last"}'::jsonb end,
          case when p_outcome = 'allocate' then repeat('0', 64) end);
  insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
  select pg_temp.pay(p_n), x.ord::integer, pg_temp.it(p_file, x.l ->> 0), x.l ->> 1, (x.l ->> 2)::bigint
  from jsonb_array_elements(p_lines) with ordinality as x (l, ord);
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select pg_temp.payment(n, a) from (values ('01', 20000), ('02', 50000), ('03', 4000), ('04', 3000), ('05', 5000),
                                          ('06', 2000), ('07', 1000)) v (n, a);

-- Structure ---------------------------------------------------------------------------------------
select ok((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where (n.nspname, c.relname) in (('public', 'allocation_policy'), ('public', 'allocation_run'),
                                           ('public', 'client_notification'), ('private', 'allocation_plan'))),
  'RLS is on for every new table');
select is((select count(*)::int from pg_policies where tablename in ('allocation_policy', 'allocation_run',
           'client_notification', 'allocation_plan') and cmd <> 'SELECT'), 0, 'read policies only: no user writes');
select ok(not has_function_privilege('authenticated', 'private.post_allocations(uuid, text, text)', 'execute')
          and has_function_privilege('service_role', 'private.post_allocations(uuid, text, text)', 'execute'),
  'only the worker posts allocations');
select ok(not has_function_privilege('anon', 'public.reverse_allocation(text, uuid, uuid, uuid[], text)', 'execute')
          and not has_function_privilege('anon', 'public.forward_payment(text, uuid, uuid, text, uuid, text)', 'execute')
          and not has_function_privilege('anon', 'public.apply_credit_note(text, uuid, text)', 'execute'),
  'anon cannot act on allocations');
select is((select count(*)::int from pg_trigger
           where tgrelid in ('public.allocation_policy'::regclass, 'public.client_notification'::regclass,
                             'private.allocation_plan'::regclass)
             and not tgisinternal and tgname not like '%change_log' and tgenabled <> 'A'), 0,
  'the guards of the new tables fire ALWAYS');
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname in ('public', 'private')
             and p.proname in ('post_allocations', 'credit_note_proposals', 'payment_positions', 'regate_account',
                               'allocate_payment', 'release_hold_payment', 'reverse_allocation', 'forward_payment',
                               'apply_credit_note', 'payment_detail', 'account_detail', 'payment_after_update')
             and pg_get_functiondef(p.oid) ~* 'not\s+in\s*\(\s*select'),
  null, 'no NOT IN over a subquery in allocation (anti-joins at any size)');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$insert into public.client_notification (organization_id, client_organization_id, payment_id, kind)
  values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', pg_temp.pay('01'), 'payment_held')$$,
  '42501', null, 'users cannot write notifications');
select throws_ok($$insert into public.allocation_policy (organization_id, version, effective_from, accessory_rank, unclassified,
  reason) values ('00000000-0000-0000-0000-0000000000aa', 9, '2027-01-01', 'after_principal', 'last', 'x')$$,
  '42501', null, 'users cannot write policies directly');
select throws_ok($$insert into public.allocation_run (organization_id, trigger) values ('00000000-0000-0000-0000-0000000000aa', 'ready')$$,
  '42501', null, 'users cannot write runs');
reset role;

-- A payment that becomes ready queues the allocation job ---------------------------------------------
select pg_temp.match('01', '01');
select is((select count(*)::int from pgmq.q_payments where message ->> 'type' = 'allocate'
           and message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000aa'), 1,
  'a payment ready for allocation queues the allocation job of its servicer');
select pg_temp.match('02', '02');
select pg_temp.match('03', '04', 'account_closed');
select pg_temp.match('04', '06', 'hold_blocks_allocation');
select pg_temp.match('05', '03');
select pg_temp.match('06', '05');

-- Held payments tell the client, once per payment and file (R124-5, founder #12, #17) -----------------
select results_eq($$select kind, client_organization_id, account_id, ledger_entry_id from public.client_notification
                    where payment_id = pg_temp.pay('04')$$,
  $$values ('payment_held'::text, '00000000-0000-0000-0000-0000000000a1'::uuid, pg_temp.f('06'), null::uuid)$$,
  'a payment held for its file tells the client');
update public.payment set review_reason = null where id = pg_temp.pay('04');
update public.payment set review_reason = 'hold_blocks_allocation' where id = pg_temp.pay('04');
select is((select count(*)::int from public.client_notification where payment_id = pg_temp.pay('04')), 1,
  'held again: still one notification for that payment and file');

-- post_allocations: what it refuses (backstops of the engine) -----------------------------------------
select pg_temp.plan('07', '01', 'allocate', '[["1", "principal", 100]]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG006', null, 'a payment not matched is not allocated');
select pg_temp.plan('01', '02', 'allocate', '[["1", "principal", 100]]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG006', null, 'nor on another file than its own');
select pg_temp.plan('01', '01', 'allocate', '[["1", "principal", 100]]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000bb', 'ready', 'alloc-1')$$,
  'LG006', null, 'nor by another servicer');
select pg_temp.plan('01', '01', 'allocate', '[["1", "principal", 15000], ["2", "principal", 6000]]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG007', null, 'never more than is left of the payment (I4)');
select pg_temp.plan('02', '02', 'allocate', '[["1", "principal", 20001]]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG007', null, 'never more than a component''s balance (I6, M2-09)');
select pg_temp.plan('05', '03', 'allocate', '[["1", "principal", 5000]]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG006', null, 'no principal while the same debt''s interest is due (1343-1)');
select pg_temp.plan('05', '03', 'allocate', '[["1", "accrued_interest", 500], ["1", "principal", 4500]]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG006', null, 'nor after part of the interest only');
select pg_temp.plan('03', '04', 'allocate', '[["1", "principal", 4000]]');
update public.payment set review_reason = null where id = pg_temp.pay('03');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG006', null, 'nothing is allocated on a closed (recalled) file');
update public.payment set review_reason = 'account_closed' where id = pg_temp.pay('03');
select pg_temp.plan('04', '06', 'allocate', '[["1", "principal", 3000]]');
update public.payment set review_reason = null where id = pg_temp.pay('04');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG006', null, 'nor while surendettement holds the file, without the judge''s authorisation (L722-5)');
update public.payment set review_reason = 'hold_blocks_allocation' where id = pg_temp.pay('04');
select pg_temp.plan('01', '01', 'allocate', '[["1", "principal", 1000]]', '2026-10-04');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG006', null, 'dated at the booking date (or the servicing start), never before');
select pg_temp.plan('01', '01', 'allocate', '[]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG006', null, 'an allocation has lines');
-- 7060 is not a book of any payment entry (M2-12, CPCE-02)
select private.ledger_post_set_begin();
insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, account_id, payment_id)
values (1, '00000000-0000-0000-0000-0000000000aa', 'allocation', '2026-10-05', 'alloc-test-7060', pg_temp.f('01'), pg_temp.pay('01'));
insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, claim_item_id, component) values
  (1, 1, 'unallocated_payment', 100, 'EUR', null, null), (1, 2, 'servicer_revenue', -100, 'EUR', null, null);
select throws_ok($$select * from private.ledger_post_set()$$, 'LG002', null,
  'an allocation line on 7060 (commission) is refused: collections never reach the servicer''s revenue');

-- post_allocations: one entry per (payment, file); states; plan; notification ------------------------
select pg_temp.plan('01', '01', 'allocate', '[["1", "principal", 12500], ["2", "principal", 7500]]');
select is((select (x ->> 'payments')::int * 10 + (x ->> 'entries')::int
           from private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1') x), 11,
  'one payment, one entry');
select results_eq($$select la.book, lp.amount_minor from public.ledger_entry e
                    join public.ledger_posting lp on lp.entry_id = e.id
                    join public.ledger_account la on la.id = lp.ledger_account_id
                    where e.payment_id = pg_temp.pay('01') order by lp.line_no$$,
  $$values ('unallocated_payment'::text, 20000::bigint), ('client_payable', -20000), ('debtor_receivable', -12500),
           ('debtor_receivable', -7500), ('owner_claim', 20000)$$,
  'Dr 4710 pool / Cr 4670 client; Cr 1100 per item; Dr 3100 per component (design §8.1)');
select results_eq($$select e.entry_type, e.effective_date, e.engine_version, e.source_type, e.account_id
                    from public.ledger_entry e where e.payment_id = pg_temp.pay('01')$$,
  $$values ('allocation'::text, '2026-10-05'::date, 'alloc-1'::text, 'allocation_run'::text, pg_temp.f('01'))$$,
  'an allocation entry of the run, dated at the booking date, with the engine version');
select is(pg_temp.state('01'), 'allocated/-', 'nothing left: allocated');
select is(array[pg_temp.balance('01', '1'), pg_temp.balance('01', '2')], array[37500, 22500]::bigint[],
  'the receivables went down by the money allocated');
select results_eq($$select kind, client_organization_id, portfolio_id, account_id from public.client_notification
                    where payment_id = pg_temp.pay('01')$$,
  $$values ('payment_allocated'::text, '00000000-0000-0000-0000-0000000000a1'::uuid,
            '20000000-0000-0000-0000-0000000000a1'::uuid, pg_temp.f('01'))$$,
  'the client is told of the allocation (M2-11)');
select is((select count(*)::int from private.allocation_plan where payment_id = pg_temp.pay('01')), 1,
  'the plan of the entry is kept (policy, inputs hash: M3 re-runs by date)');
select is((select summary ->> 'entries' from public.allocation_run where id =
             (select run_id from private.allocation_plan where payment_id = pg_temp.pay('01'))), '1',
  'the run keeps its summary');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG006', null, 'the same plan again: the payment is no longer ready (idempotent)');
select throws_ok($$insert into public.client_notification (organization_id, client_organization_id, portfolio_id,
  account_id, payment_id, ledger_entry_id, kind) select organization_id, client_organization_id, portfolio_id, account_id,
  payment_id, ledger_entry_id, kind from public.client_notification where payment_id = pg_temp.pay('01')$$,
  '23505', null, 'one notification per allocation entry, exactly');
select throws_ok($$update public.client_notification set reason = 'x' where payment_id = pg_temp.pay('01')$$,
  '23514', null, 'a notification is never rewritten');
select lives_ok($$update public.client_notification set delivered_at = now() where payment_id = pg_temp.pay('01')$$,
  'its delivery is recorded once (M7)');
select throws_ok($$delete from public.client_notification where payment_id = pg_temp.pay('01')$$,
  '23514', null, 'and it is never deleted');

-- Overpayment: what is over stays in 4710 for the payment (founder #8) ----------------------------------
select pg_temp.plan('02', '02', 'allocate', '[["1", "principal", 20000]]');
select lives_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'an allocation of less than the payment');
select is(pg_temp.state('02'), 'partially_allocated/overpayment', 'an overpayment: partially allocated, in the queue');
select results_eq($$select allocated_minor, unallocated_minor from private.payment_positions(array[pg_temp.pay('02')])$$,
  $$values (20000::bigint, 30000::bigint)$$, 'amount = allocated + unallocated (I5)');
-- Engine outcomes without lines: the reason is kept for ops
select pg_temp.plan('06', '05', 'credit_note_to_apply');
select lives_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'a payment waiting for a credit note');
select is(pg_temp.state('06'), 'matched/credit_note_to_apply', 'stays matched, waiting for ops (1347: invoked)');

-- Credit-note proposals and apply_credit_note (founder #7; 1347, 1347-1, 1347-4) ---------------------------
select results_eq($$select credit_item_id, netting_date, target_item_id, amount_minor
                    from private.credit_note_proposals(array[pg_temp.f('05')])$$,
  $$values (pg_temp.it('05', '3'), '2026-09-30'::date, pg_temp.it('05', '1'), 40000::bigint)$$,
  'the credit note against the oldest due invoice, at the date both were due (not before servicing start)');
set local role authenticated;
select pg_temp.as_user('02');
select throws_ok($$select public.apply_credit_note('key-alloc-cn-0001', pg_temp.f('05'), 'x')$$, '42501', null,
  'a collector cannot apply a credit note');
select pg_temp.as_user('01', 'aal1');
select throws_ok($$select public.apply_credit_note('key-alloc-cn-0001', pg_temp.f('05'), 'x')$$, '42501', null,
  'staff need two-factor (aal2)');
select pg_temp.as_user('01');
select throws_ok($$select public.apply_credit_note('key-alloc-cn-0001', pg_temp.f('05'), 'not-the-proposal')$$, '23514',
  'the proposal changed: reload the page', 'only the proposal the page showed is applied (compare and set)');
select is((public.account_detail(pg_temp.f('05')) -> 'proposal' -> 'targets' -> 0 ->> 'amount_minor'), '40000',
  'the file page shows the proposal');
select ok((public.apply_credit_note('key-alloc-cn-0002', pg_temp.f('05'),
            public.account_detail(pg_temp.f('05')) -> 'proposal' ->> 'proposal_key') ->> 'amount_minor') = '40000',
  'one tap applies it');
reset role;
select results_eq($$select e.entry_type, e.effective_date, e.reason from public.ledger_entry e
                    where e.account_id = pg_temp.f('05') and e.entry_type = 'netting'$$,
  $$values ('netting'::text, '2026-09-30'::date, 'compensation invoquée (art. 1347 C. civ.)'::text)$$,
  'a netting entry at that date, compensation invoked');
select is(array[pg_temp.balance('05', '1'), pg_temp.balance('05', '3')], array[0, -10000]::bigint[],
  'the invoice is paid by the credit note; 100,00 € of credit left');
select results_eq($$select target_item_id, amount_minor from private.credit_note_proposals(array[pg_temp.f('05')])$$,
  $$values (pg_temp.it('05', '2'), 10000::bigint)$$, 'then the next due invoice is proposed');
select is(pg_temp.state('06'), 'matched/credit_note_to_apply', 'the payment still waits: a credit note is proposed');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.apply_credit_note('key-alloc-cn-0003', pg_temp.f('05'),
  public.account_detail(pg_temp.f('05')) -> 'proposal' ->> 'proposal_key')$$, 'the second one');
reset role;
select is((select count(*)::int from private.credit_note_proposals(array[pg_temp.f('05')])), 0, 'nothing more to propose');
select is(pg_temp.state('06'), 'matched/-', 'the waiting payment is ready for allocation again');

-- Reverse an allocation (design §8.1: at its date; compare and set) -----------------------------------------
set local role authenticated;
select pg_temp.as_user('02');
select throws_ok($$select public.reverse_allocation('key-alloc-rev-0001', pg_temp.pay('01'), pg_temp.f('01'),
  array(select id from public.ledger_entry where payment_id = pg_temp.pay('01')), 'erreur')$$, '42501', null,
  'a collector cannot reverse an allocation');
select pg_temp.as_user('05');
select throws_ok($$select public.reverse_allocation('key-alloc-rev-0001', pg_temp.pay('01'), pg_temp.f('01'),
  array['00000000-0000-0000-0000-000000000000'::uuid], 'erreur')$$, '42501', null, 'nor another servicer');
select pg_temp.as_user('01');
select throws_ok($$select public.reverse_allocation('key-alloc-rev-0001', pg_temp.pay('01'), pg_temp.f('01'),
  array['00000000-0000-0000-0000-000000000000'::uuid], 'erreur')$$, '23514', 'the allocation changed: reload the page',
  'only the allocation the page showed is reversed');
select throws_ok($$select public.reverse_allocation('key-alloc-rev-0001', pg_temp.pay('01'), pg_temp.f('01'),
  array(select id from public.ledger_entry where payment_id = pg_temp.pay('01')), ' ')$$, '23514', 'a reason is required',
  'a reason is required');
reset role;
create temp table _rev as select id from public.ledger_entry where payment_id = pg_temp.pay('01');
grant select on _rev to authenticated;
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.reverse_allocation('key-alloc-rev-0002', pg_temp.pay('01'), pg_temp.f('01'),
  array(select id from _rev), 'mauvais dossier')$$, 'ops reverse it');
select lives_ok($$select public.reverse_allocation('key-alloc-rev-0002', pg_temp.pay('01'), pg_temp.f('01'),
  array(select id from _rev), 'mauvais dossier')$$, 'the same request replays');
select throws_ok($$select public.reverse_allocation('key-alloc-rev-0002', pg_temp.pay('01'), pg_temp.f('01'),
  array(select id from _rev), 'autre motif')$$, '22023', null, 'the same key for another request is refused');
reset role;
select results_eq($$select e.entry_type, e.effective_date, e.reverses_entry_id from public.ledger_entry e
                    where e.payment_id = pg_temp.pay('01') and e.entry_type = 'reversal'$$,
  $$select 'reversal'::text, '2026-10-05'::date, id from _rev$$, 'a reversal at the allocation''s date');
select is(array[pg_temp.balance('01', '1'), pg_temp.balance('01', '2')], array[50000, 30000]::bigint[],
  'the receivables are restored');
select is(pg_temp.state('01'), 'matched/allocation_reversed', 'the payment waits for ops (never re-allocated by itself)');
select is((select array_agg(kind order by created_at, kind) from public.client_notification
           where payment_id = pg_temp.pay('01')), array['payment_allocated', 'payment_allocation_reversed'],
  'the client is told of the reversal');
-- Allocate again (« Imputer »)
create temp table _queued as select count(*) as n from pgmq.q_payments where message ->> 'type' = 'allocate';
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.allocate_payment('key-alloc-imp-0001', pg_temp.pay('01'), 'nothing_due', null, null, 'x')$$,
  '23514', 'the payment changed: reload the page', 'acts on the state the page showed');
select lives_ok($$select public.allocate_payment('key-alloc-imp-0002', pg_temp.pay('01'), 'allocation_reversed', null, null,
  'désignation vérifiée')$$, 'ops send it to allocation again');
reset role;
select is(pg_temp.state('01'), 'matched/-', 'ready again');
select is((select allocation_instruction -> 'releases' from public.payment where id = pg_temp.pay('01')),
  '["allocation_reversed"]'::jsonb, 'with the ops decision the job follows');
select is((select count(*)::int from pgmq.q_payments where message ->> 'type' = 'allocate'
           and message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000aa') - (select n from _queued)::int, 1,
  'and the allocation job is queued');
update public.payment set account_id = pg_temp.f('02'), review_reason = 'nothing_due' where id = pg_temp.pay('01');
select is((select allocation_instruction from public.payment where id = pg_temp.pay('01')), null,
  'a decision about one file is void once the payment leaves it');
update public.payment set account_id = pg_temp.f('01') where id = pg_temp.pay('01');

-- Release a held payment (founder #12: the judge's authorisation as evidence) -----------------------------
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.release_hold_payment('key-alloc-rel-0001', pg_temp.pay('04'), null, 'autorisation')$$,
  '23514', 'the judge''s authorisation is required, filed on this file', 'evidence is required');
select throws_ok($$select public.release_hold_payment('key-alloc-rel-0001', pg_temp.pay('04'),
  'd1000000-0000-0000-0000-000000000001', 'autorisation')$$,
  '23514', 'the judge''s authorisation is required, filed on this file', 'a document of this file');
select lives_ok($$select public.release_hold_payment('key-alloc-rel-0002', pg_temp.pay('04'),
  'd1000000-0000-0000-0000-000000000006', 'autorisation du JCP')$$, 'released with the judge''s authorisation');
reset role;
select is(pg_temp.state('04'), 'matched/-', 'ready for allocation; the hold stays');
select pg_temp.plan('04', '06', 'allocate', '[["1", "principal", 3000]]');
select lives_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'allocated despite the hold, as authorised');
select is((select count(*)::int from public.account_hold where account_id = pg_temp.f('06') and ended_at is null), 1,
  'the hold is still active');

-- Forward (recall; founder 2026-11-07) ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.forward_payment('key-alloc-fwd-0001', pg_temp.pay('02'), null, '30000', null, 'x')$$,
  '23514', 'only a payment nothing was allocated from can be forwarded',
  'an overpayment is never passed to the client (founder #8)');
select throws_ok($$select public.forward_payment('key-alloc-fwd-0001', pg_temp.pay('03'), null, '3999', null, 'rappel')$$,
  '23514', 'the amount changed: reload the page', 'forwards only the amount the page showed');
select throws_ok($$select public.forward_payment('key-alloc-fwd-0001', pg_temp.pay('03'),
  '00000000-0000-0000-0000-0000000000a2', '4000', null, 'rappel')$$, '23514', 'the client is the file''s',
  'to the file''s client only');
select lives_ok($$select public.forward_payment('key-alloc-fwd-0002', pg_temp.pay('03'), null, '4000', null,
  'dossier rappelé par le client')$$, 'a payment on a recalled file is forwarded');
reset role;
select results_eq($$select la.book, lp.amount_minor from public.ledger_entry e
                    join public.ledger_posting lp on lp.entry_id = e.id
                    join public.ledger_account la on la.id = lp.ledger_account_id
                    where e.payment_id = pg_temp.pay('03') and e.entry_type = 'forward' order by lp.line_no$$,
  $$values ('unallocated_payment'::text, 4000::bigint), ('client_payable', -4000)$$,
  'Dr 4710 pool / Cr 4670 client; the debt is not touched');
select is(pg_temp.state('03'), 'allocated/-', 'nothing left of it');
select is((select kind from public.client_notification where payment_id = pg_temp.pay('03')), 'payment_forwarded',
  'the client is told');

-- Policy (founder #5): versions, never retroactive, the legal order not expressible -----------------------------
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.set_allocation_policy('key-alloc-pol-0001', '00000000-0000-0000-0000-0000000000aa',
  null, null, 'after_principal', 'last', '2099-01-01', 'x')$$, '42501', null, 'only admins set the policy');
select pg_temp.as_user('04');
select throws_ok($$select public.set_allocation_policy('key-alloc-pol-0001', '00000000-0000-0000-0000-0000000000aa',
  null, null, 'after_principal', 'last', '2020-01-01', 'x')$$, '23514', null, 'never retroactive');
select throws_ok($$select public.set_allocation_policy('key-alloc-pol-0001', '00000000-0000-0000-0000-0000000000aa',
  null, null, 'principal_first', 'last', '2099-01-01', 'x')$$, '23514', null, 'only accessory ranks the law leaves open');
select lives_ok($$select public.set_allocation_policy('key-alloc-pol-0002', '00000000-0000-0000-0000-0000000000aa',
  '00000000-0000-0000-0000-0000000000a1', null, 'after_principal', 'held', '2099-01-01', 'convention client A1')$$,
  'a client''s version');
select lives_ok($$select public.set_allocation_policy('key-alloc-pol-0003', '00000000-0000-0000-0000-0000000000aa',
  '00000000-0000-0000-0000-0000000000a1', null, 'before_principal', 'held', '2099-02-01', 'avenant')$$, 'and the next');
select throws_ok($$select public.set_allocation_policy('key-alloc-pol-0004', '00000000-0000-0000-0000-0000000000aa',
  '00000000-0000-0000-0000-0000000000b1', null, 'before_principal', 'held', '2099-02-01', 'x')$$, '23514', null,
  'a client of another servicer is refused');
reset role;
select is((select array_agg(version order by version) from public.allocation_policy
           where client_organization_id = '00000000-0000-0000-0000-0000000000a1'), array[1, 2], 'versions of the scope');
select throws_ok($$update public.allocation_policy set unclassified = 'last'$$, '23514', null, 'versions are immutable');
select is((select count(*)::int from information_schema.columns where table_schema = 'public'
           and table_name = 'allocation_policy' and column_name ~ 'interest|order|principal_first'), 0,
  'interest before principal and the legal order have no column: a policy cannot change them (1343-1, OQ-19)');

-- Who reads what (decision #18) -------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('03', 'aal1');
select is((select array_agg(distinct client_organization_id::text) from public.client_notification),
  array['00000000-0000-0000-0000-0000000000a1'], 'a client reads its own notifications only');
select ok((select count(*) from public.client_notification) >= 4, 'all of them');
select is((select count(*)::int from public.allocation_run), 0, 'not the runs');
select is((select count(*)::int from public.allocation_policy), 2, 'its own policy versions');
select is(public.payment_detail(pg_temp.pay('01')), null, 'not the payment page');
select pg_temp.as_user('06', 'aal1');
select is((select array_agg(distinct client_organization_id::text) from public.client_notification),
  array['00000000-0000-0000-0000-0000000000a2'], 'client A2 reads only A2''s notifications');
select is((select count(*)::int from public.allocation_policy), 0, 'and no policy of client A1');
select pg_temp.as_user('07', 'aal1');
select is((select count(*)::int from public.client_notification), 0, 'a client of another servicer reads none');
select pg_temp.as_user('05');
select is((select count(*)::int from public.client_notification), 0, 'nor another servicer''s staff');
select is((select count(*)::int from public.allocation_run), 0, 'nor its runs');
select pg_temp.as_user('01');
select ok((select count(*) from public.client_notification) >= 5, 'ops read every notification of the servicer');
select ok((select count(*) from public.allocation_run) >= 1, 'and the runs');
select is((public.payment_detail(pg_temp.pay('02')) -> 'position' ->> 'unallocated_minor'), '30000',
  'the payment page reads the position from the ledger, as text');
select is((public.payment_detail(pg_temp.pay('02')) -> 'entries' -> 0 -> 'lines' -> 0 ->> 'amount_minor'), '20000',
  'and the allocation per item and component');
select is((public.account_detail(pg_temp.f('05')) ->> 'proposal'), null, 'no proposal once the credit notes are applied');
select is((select count(*)::int from public.payment_queue('rapproches') q where q.payment_id = pg_temp.pay('03')), 1,
  '« Rapprochés » lists payments with a file and nothing to decide, allocated or forwarded included');
select pg_temp.as_user('02');
select ok(public.account_detail(pg_temp.f('01')) is not null, 'a collector reads a file of its portfolio');
select is(public.account_detail(pg_temp.f('02')), null, 'not a file outside it');
select is((public.account_detail(pg_temp.f('01')) ->> 'can_act')::boolean, false, 'and cannot act on payments');
select is((select count(*)::int from public.client_notification), 0, 'collectors do not read client notifications');
reset role;

-- Review fixes (M2b-4 review) -------------------------------------------------------------------------------------

-- An item as a whole is never taken below zero (#0): its components summed, a negative balancing line included (the
-- seller's components above the legal balance 3.12), at every date from the allocation's on; the rest of the payment
-- stays an overpayment (founder #8).
select pg_temp.file('07', '20000000-0000-0000-0000-0000000000a1', 'in_collection', 'commercial_b2b', 'Écart SA');
select pg_temp.item('07', '1', 'invoice', '2026-07-01');
select pg_temp.owe('07', '1', 'principal', 10000);
select pg_temp.owe('07', '1', 'balancing_line', -2000);
select pg_temp.item('07', '2', 'invoice', '2026-08-01');
select pg_temp.owe('07', '2', 'principal', 5000);
select pg_temp.owe_at('07', '2', 'balancing_line', -1000, '2026-10-20');
select pg_temp.payment(n, a) from (values ('08', 10000), ('09', 5000)) v (n, a);
select pg_temp.match('08', '07');
select pg_temp.match('09', '07');
select pg_temp.plan('08', '07', 'allocate', '[["1", "principal", 10000]]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG007', null, 'never more than an item owes as a whole: a negative balancing line counts (3.12)');
select pg_temp.plan('09', '07', 'allocate', '[["2", "principal", 5000]]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG007', null, 'nor what the item will owe at a later date (a negative line dated after the payment)');
select private.allocation_begin();
insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy, inputs_hash) values
  (pg_temp.pay('08'), 1, pg_temp.f('07'), 'allocate', '2026-10-05', '{"unclassified": "last"}', repeat('0', 64)),
  (pg_temp.pay('09'), 2, pg_temp.f('07'), 'allocate', '2026-10-05', '{"unclassified": "last"}', repeat('0', 64));
insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor) values
  (pg_temp.pay('08'), 1, pg_temp.it('07', '1'), 'principal', 5000),
  (pg_temp.pay('09'), 1, pg_temp.it('07', '1'), 'principal', 5000);
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG007', null, 'two payments of a run together: never more than the item owes');
select pg_temp.plan('08', '07', 'allocate', '[["1", "principal", 8000]]');
select lives_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'up to what the item owes as a whole');
select is(pg_temp.state('08'), 'partially_allocated/overpayment', 'the rest is an overpayment, never the client''s');
select is(pg_temp.balance('07', '1') + pg_temp.balance('07', '1', 'balancing_line'), 0::bigint,
  'the item owes nothing more');
select pg_temp.plan('09', '07', 'allocate', '[["2", "principal", 4000]]');
select lives_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'up to what the item still owes at every later date');
-- The same definition as the waterfall's cap: every component counts, the held ones too (a consumer loan's
-- unclassified amounts, never paid by allocation, founder #6): principal 100,00 + other balances 30,00 (held) −
-- balancing line 50,00 = 80,00 owed; 80,00 of principal may be allocated, not a cent more.
select pg_temp.file('12', '20000000-0000-0000-0000-0000000000a1', 'in_collection', 'consumer_credit_ccd2', 'Paul Écart');
select pg_temp.item('12', '1', 'loan_principal', null);
select pg_temp.owe('12', '1', 'principal', 10000);
select pg_temp.owe('12', '1', 'other_balances', 3000);
select pg_temp.owe('12', '1', 'balancing_line', -5000);
select pg_temp.payment('15', 9000);
select pg_temp.match('15', '12');
select pg_temp.plan('15', '12', 'allocate', '[["1", "principal", 8001]]');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG007', null, 'a held component counts in what the item owes, a negative line too: not a cent above it');
select pg_temp.plan('15', '12', 'allocate', '[["1", "principal", 8000]]');
select lives_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'what the waterfall caps the item at (held amounts included) is allocated');

-- A held file's payments are never forwarded (#2): surendettement, collective proceeding (L722-5, L622-7; founder #12:
-- refunded, or allocated on the judge's authorisation).
select pg_temp.payment(n, a) from (values ('10', 2500), ('11', 1500)) v (n, a);
select pg_temp.match('10', '06', 'before_servicing_start');
select pg_temp.file('08', '20000000-0000-0000-0000-0000000000a1', 'in_collection', 'commercial_b2b', 'Rappel Bloqué SA');
select pg_temp.item('08', '1', 'invoice', '2026-08-01');
select pg_temp.owe('08', '1', 'principal', 10000);
select pg_temp.file('09', '20000000-0000-0000-0000-0000000000a1', 'in_collection', 'commercial_b2b', 'Avoir Bloqué SA');
select pg_temp.file('10', '20000000-0000-0000-0000-0000000000a1', 'in_collection', 'commercial_b2b', 'Deux Portes SA',
                    '2026-10-10');
insert into public.document (id, organization_id, client_organization_id, account_id, kind, storage_path, sha256, mime_type)
select ('d1000000-0000-0000-0000-0000000000' || n)::uuid, '00000000-0000-0000-0000-0000000000aa',
       '00000000-0000-0000-0000-0000000000a1', pg_temp.f(n), 'evidence', 'test/alloc-' || n || '.pdf', repeat('c', 64),
       'application/pdf'
from unnest(array['08', '09', '10']) n;
insert into public.account_hold (organization_id, client_organization_id, portfolio_id, account_id, kind, scope,
                                 evidence_document_id, reason)
select '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1',
       pg_temp.f(n), k, array['outbound', 'payment_requests'], ('d1000000-0000-0000-0000-0000000000' || n)::uuid,
       'jugement ou recevabilité'
from (values ('08', 'collective_proceeding'), ('09', 'surendettement'), ('10', 'surendettement')) v (n, k);
update public.account set status = 'closed_recalled' where id = pg_temp.f('08');
select pg_temp.match('11', '08', 'account_closed');
set local role authenticated;
select pg_temp.as_user('01');
select is(public.payment_detail(pg_temp.pay('10')) -> 'file' -> 'holds', '["surendettement"]'::jsonb,
  'the payment page knows the file is held');
select throws_ok($$select public.forward_payment('key-alloc-fwd-0101', pg_temp.pay('10'), null, '2500', null, 'antérieur')$$,
  '23514', 'the file is held (surendettement or collective proceeding): its payments are not forwarded',
  'a payment before the cut-off on a held file is not forwarded to the client');
select throws_ok($$select public.forward_payment('key-alloc-fwd-0102', pg_temp.pay('11'), null, '1500', null, 'rappel')$$,
  '23514', 'the file is held (surendettement or collective proceeding): its payments are not forwarded',
  'nor a payment on a recalled file under a collective proceeding');
reset role;

-- Compensation is not invoked on a held file (#5: L622-7 I allows compensation of connected claims only, which the
-- code cannot tell; L722-5): the credit note is shown, not applied.
select pg_temp.item('09', '1', 'invoice', '2026-08-01');
select pg_temp.item('09', '2', 'credit_note', null);
select pg_temp.owe('09', '1', 'principal', 10000);
select pg_temp.owe('09', '2', 'principal', -3000);
set local role authenticated;
select pg_temp.as_user('01');
select ok(public.account_detail(pg_temp.f('09')) -> 'proposal' is not null, 'the credit note of a held file is shown');
select throws_ok($$select public.apply_credit_note('key-alloc-cn-0101', pg_temp.f('09'),
  public.account_detail(pg_temp.f('09')) -> 'proposal' ->> 'proposal_key')$$, '23514',
  'the file is held (surendettement or collective proceeding): compensation is not invoked',
  'but not applied while surendettement or a collective proceeding holds the file');
reset role;
select is((select count(*)::int from public.ledger_entry where account_id = pg_temp.f('09') and entry_type = 'netting'), 0,
  'nothing is netted');

-- Two gates (#3, #4, #8): booked before the servicing start on a held file. The hold is reported first (the client is
-- told); each ops decision adds to the gates released, none is lost at the next gate.
select pg_temp.item('10', '1', 'invoice', '2026-08-01');
select pg_temp.owe_at('10', '1', 'principal', 10000, '2026-10-10');
select pg_temp.payment('12', 5000);
select pg_temp.match('12', '10');
select private.regate_account(pg_temp.f('10'));
select is(pg_temp.state('12'), 'matched/hold_blocks_allocation', 'before the cut-off on a held file: the hold is reported');
select is((select count(*)::int from public.client_notification where payment_id = pg_temp.pay('12') and kind = 'payment_held'),
  1, 'and the client is told the payment is held');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.release_hold_payment('key-alloc-rel-0101', pg_temp.pay('12'),
  'd1000000-0000-0000-0000-000000000010', 'autorisation du juge')$$, 'ops file the judge''s authorisation');
reset role;
select pg_temp.plan('12', '10', 'allocate', '[["1", "principal", 5000]]', '2026-10-10');
select throws_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'LG006', null, 'the cut-off is not checked yet: not allocated');
select pg_temp.plan('12', '10', 'before_servicing_start');
select lives_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'the job gates it at the cut-off');
select is(pg_temp.state('12'), 'matched/before_servicing_start', 'the next gate');
select is((select allocation_instruction -> 'releases' from public.payment where id = pg_temp.pay('12')),
  '["hold_blocks_allocation"]'::jsonb, 'the judge''s authorisation is kept');
set local role authenticated;
select pg_temp.as_user('01');
select lives_ok($$select public.allocate_payment('key-alloc-imp-0101', pg_temp.pay('12'), 'before_servicing_start', null,
  null, 'solde du cédant vérifié')$$, 'ops check the cut-off with the client');
reset role;
select is((select allocation_instruction -> 'releases' from public.payment where id = pg_temp.pay('12')),
  '["before_servicing_start", "hold_blocks_allocation"]'::jsonb, 'both gates are released');
select is((select jsonb_array_length(allocation_instruction -> 'decisions') from public.payment where id = pg_temp.pay('12')),
  2, 'each decision is kept (who, when, why, the evidence)');
select private.regate_account(pg_temp.f('10'));
select is(pg_temp.state('12'), 'matched/-', 'a hold command meanwhile honours both');
select pg_temp.plan('12', '10', 'allocate', '[["1", "principal", 5000]]', '2026-10-10');
select lives_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'allocated at the servicing start, as both decisions allow');
select is(pg_temp.state('12'), 'allocated/-', 'allocated');
select is((select allocation_instruction from public.payment where id = pg_temp.pay('12')), null,
  'the decisions are consumed by the allocation');

-- A payment sent to another file is gated there, by the job, never on its own file's facts (#9).
select pg_temp.payment('13', 1000);
select pg_temp.match('13', '10', 'nothing_due');
update public.payment
set review_reason = null,
    allocation_instruction = jsonb_build_object('releases', jsonb_build_array('overpayment'), 'account_id', pg_temp.f('01'))
where id = pg_temp.pay('13');
select private.regate_account(pg_temp.f('10'));
select is(pg_temp.state('13'), 'matched/-', 'a hold command on its own file leaves a payment sent to another file alone');
select is((select count(*)::int from public.client_notification where payment_id = pg_temp.pay('13')), 0,
  'its own file''s client is not told it is held');

-- A collector reads, on a file of his portfolios, only the payments of portfolios he reads (#7).
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', 'P3');
select pg_temp.file('11', '20000000-0000-0000-0000-0000000000a3', 'in_collection', 'commercial_b2b', 'Autre Portefeuille SA');
select pg_temp.item('11', '1', 'invoice', '2026-08-01');
select pg_temp.owe('11', '1', 'principal', 1000);
select pg_temp.payment('14', 3000);
select pg_temp.match('14', '11', 'nothing_due');
update public.payment
set review_reason = null,
    allocation_instruction = jsonb_build_object('releases', jsonb_build_array('overpayment'), 'account_id', pg_temp.f('01'))
where id = pg_temp.pay('14');
select pg_temp.plan('14', '01', 'allocate', '[["1", "principal", 1000]]');
select lives_ok($$select private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1')$$,
  'a payment of portfolio P3 pays a file of P1 (same client and debtor, on request)');
set local role authenticated;
select pg_temp.as_user('02');
select is((select count(*)::int from jsonb_array_elements(public.account_detail(pg_temp.f('01')) -> 'payments') x
           where x ->> 'id' = pg_temp.pay('14')::text), 0,
  'a collector does not see it on the P1 file: he does not read P3');
select pg_temp.as_user('01');
select is((select count(*)::int from jsonb_array_elements(public.account_detail(pg_temp.f('01')) -> 'payments') x
           where x ->> 'id' = pg_temp.pay('14')::text), 1, 'ops do');
reset role;
select ok(pg_get_functiondef('public.account_detail(uuid)'::regprocedure) !~* 'or\s+p\.id\s+in\s*\(',
  'the file page lists its payments by indexed lookups, never an OR over a subquery (a scan of every payment, #6)');

-- The client reads codes, never ops' motif (#12); staff keep the motif; the page tells delivery (#11) and a forward
-- from an allocation (#16).
select is((select reason from public.client_notification where payment_id = pg_temp.pay('01')
           and kind = 'payment_allocation_reversed'), 'ops_correction', 'a reversal tells the client a reason code');
select is((select count(*)::int from public.ledger_entry where payment_id = pg_temp.pay('01') and entry_type = 'reversal'
           and reason ~ 'mauvais dossier'), 0, 'ops'' motif is not in the reversal entry the client reads either');
select is((select reason from public.client_notification where payment_id = pg_temp.pay('03')), 'file_recalled',
  'a forward tells why with a code');
select throws_ok($$insert into public.client_notification (organization_id, client_organization_id, account_id, payment_id,
  kind, reason) values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', pg_temp.f('06'),
  pg_temp.pay('10'), 'payment_held', 'Homonyme : Jean Martin')$$, '23514', null, 'a notification''s reason is a code');
set local role authenticated;
select pg_temp.as_user('01');
select is((select x ->> 'ops_note' from jsonb_array_elements(public.payment_detail(pg_temp.pay('01')) -> 'entries') x
           where x ->> 'entry_type' = 'reversal'), 'mauvais dossier', 'ops read the motif on the payment page');
select ok(public.payment_detail(pg_temp.pay('01')) -> 'notifications' -> 0 ? 'delivered_at',
  'the payment page knows whether a notification was delivered');
select is(public.payment_detail(pg_temp.pay('03')) -> 'position' ->> 'forwarded_minor', '4000',
  'the payment page tells a forward from an allocation');
select is((public.account_detail(pg_temp.f('04')) -> 'payments' -> 0 ->> 'forwarded')::boolean, true,
  'and so does the file page');
select is((select q.forwarded from public.payment_queue('rapproches') q where q.payment_id = pg_temp.pay('03')), true,
  'and « Rapprochés »');
reset role;
select is((select count(*)::int from public.client_notification n where n.reason is not null
           and n.reason not in ('hold_blocks_allocation', 'ops_correction', 'file_recalled', 'before_servicing_start',
                                'client_ratification')), 0, 'every reason the client reads is a code');

-- 20261110130000 (plan robustness): payment_positions and unassign_payment reach a payment's 4710 postings from its
-- entries now; same results as the queries they replaced.
select is(
  (select jsonb_agg(jsonb_build_array(x.payment_id, x.amount_minor, x.allocated_minor, x.returned_minor,
                                      x.unallocated_minor) order by x.payment_id)
   from private.payment_positions(array(select id from public.payment)) x),
  (select jsonb_agg(jsonb_build_array(p.id, p.amount_minor, coalesce(s.a, 0), coalesce(s.r, 0),
                                      p.amount_minor - coalesce(s.a, 0) - coalesce(s.r, 0)) order by p.id)
   from public.payment p
   left join lateral (
     select sum(lp.amount_minor) filter (where coalesce(t.entry_type, e.entry_type) in ('allocation', 'forward')) as a,
            sum(lp.amount_minor) filter (where coalesce(t.entry_type, e.entry_type) = 'cash_out') as r
     from public.ledger_entry e
     left join public.ledger_entry t on t.id = e.reverses_entry_id
     join public.ledger_posting lp on lp.entry_id = e.id
     join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment'
     where e.payment_id = p.id) s on true),
  'payment positions: those of the query it replaced, for every payment');
select ok((select count(distinct e.entry_type) from public.ledger_entry e
           where e.payment_id is not null and e.entry_type in ('allocation', 'forward', 'reversal')) = 3,
  'allocations, forwards and reversals among them');
create temp table _rob as
select (select p.id from public.payment p where p.status in ('allocated', 'partially_allocated') and p.account_id is not null
        order by p.id limit 1) as allocated,
       (select p.id from public.payment p where p.status = 'matched' and p.account_id is not null
          and exists (select 1 from public.ledger_entry e where e.payment_id = p.id and e.entry_type = 'reversal')
          and not exists (select 1 from public.ledger_entry e where e.payment_id = p.id and e.entry_type = 'forward')
        order by p.id limit 1) as reversed;
grant select on _rob to authenticated;
select isnt((select allocated from _rob), null, 'a payment with money allocated');
select isnt((select reversed from _rob), null, 'a payment whose allocation was reversed (its entries net to zero on 4710)');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$select public.unassign_payment('key-rob-unassign-01', (select allocated from _rob), 'mauvais dossier')$$,
  '23514', 'money of this payment is allocated: reverse the allocation first', 'unassign: refused while money is allocated');
select is(public.unassign_payment('key-rob-unassign-02', (select reversed from _rob), 'mauvais dossier') ->> 'payment_id',
  (select reversed::text from _rob), 'unassign: allowed once its allocation is reversed');
reset role;


-- 20261110130000 (plan robustness): payment_detail drives from the payment's entries and reaches every row it names by
-- key now; the page is that of the function it replaced (20261110120000 as merged, copied below), for every payment
-- (allocations, forwards, reversals, notifications, another servicer's payments).
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
-- The borrower of payment 02's file is on other files: as borrower (D-21) and as co-borrower (D-22), listed; on a
-- closed file (D-23), on a staged one (D-24) and as guarantor only (D-25), not listed.
select pg_temp.file('21', '20000000-0000-0000-0000-0000000000a2', 'in_collection', 'commercial_b2b', 'Autre 21');
select pg_temp.file('22', '20000000-0000-0000-0000-0000000000a2', 'in_collection', 'commercial_b2b', 'Autre 22');
select pg_temp.file('23', '20000000-0000-0000-0000-0000000000a2', 'closed_paid', 'commercial_b2b', 'Autre 23');
select pg_temp.file('24', '20000000-0000-0000-0000-0000000000a2', 'staged', 'commercial_b2b', 'Autre 24');
select pg_temp.file('25', '20000000-0000-0000-0000-0000000000a2', 'in_collection', 'commercial_b2b', 'Autre 25');
insert into public.account_party (account_id, party_id, role, capacity)
select pg_temp.f(x.n), ap.party_id, x.role, 'legal_entity'
from public.account_party ap
cross join (values ('21', 'borrower'), ('22', 'co_borrower'), ('23', 'borrower'), ('24', 'borrower'),
                   ('25', 'guarantor')) x (n, role)
where ap.account_id = (select account_id from public.payment where id = pg_temp.pay('02')) and ap.role = 'borrower';

select pg_temp.as_user('01');
select is((select string_agg(p.id || ' ' || coalesce(public.payment_detail(p.id)::text, '-'), e'\n' order by p.id)
           from public.payment p),
          (select string_agg(p.id || ' ' || coalesce(pg_temp.payment_detail_applied(p.id)::text, '-'), e'\n'
                             order by p.id)
           from public.payment p),
  'the payment page: that of the function it replaced, for every payment');
select is(public.payment_detail(pg_temp.pay('02')) -> 'other_files',
  jsonb_build_array(jsonb_build_object('account_id', pg_temp.f('21'), 'external_ref', 'D-21'),
                    jsonb_build_object('account_id', pg_temp.f('22'), 'external_ref', 'D-22')),
  'the debtor''s other open files, from its parties (borrower or co-borrower; not closed, staged or as guarantor)');
select * from finish();
rollback;
