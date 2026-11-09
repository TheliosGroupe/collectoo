-- M2b-4 (M2-09, data half of M2-11): allocation. Design docs/design/m2b-payments.md §6–§9, §12; ADR-0013 (M2b-4
-- addendum). The worker's waterfall is played here by writing plans into pg_temp._alloc_target / _alloc_line and calling
-- private.post_allocations, as the payments.allocate job does in one transaction.
begin;
select plan(114);

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
create or replace function pg_temp.file(p_n text, p_portfolio uuid, p_status text, p_regime text, p_name text)
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
         'mandate_amicable', '2026-09-30'
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
create or replace function pg_temp.owe(p_n text, p_i text, p_component text, p_amount bigint) returns void language sql as $$
  select entry_id from private.ledger_post(
    (select organization_id from public.account where id = pg_temp.f(p_n)), 'adjustment', '2026-09-30',
    'alloc-owe-' || p_n || p_i || p_component,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', pg_temp.it(p_n, p_i), 'component', p_component),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', p_component)),
    jsonb_build_object('account_id', pg_temp.f(p_n), 'reason', 'ouverture (test)'));
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
select is((select allocation_instruction ->> 'release' from public.payment where id = pg_temp.pay('01')),
  'allocation_reversed', 'with the ops decision the job follows');
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

select * from finish();
rollback;
