-- Staging, commit, rollback and confirmation of a boarding batch (M1-17, M1-18).
begin;
select plan(22);

-- Fixtures ----------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client B');
insert into auth.users (id, email, aud, role) values
  ('10000000-0000-0000-0000-000000000001', 'ops@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000002', 'collector@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000003', 'admin@a.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000005', 'admin@b.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000a2', 'client_admin');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'A');

-- A batch walked to `staged`, with one civil account (debtor, contact, invoice) in staging.
insert into public.boarding_batch (id, organization_id, client_organization_id, portfolio_id, version, cut_off_date,
                                   dq_report) values
  ('30000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a',
   '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1', 1, '2026-09-30',
   '{"staging": {"opening": {"currencies": {"EUR": {"accounts": 1, "accounts_without_balance": 0,
     "outstanding_minor": "125000", "components": {"principal": "125000"}}}}}}');
select private.transition_batch('30000000-0000-0000-0000-000000000001', s, 'test')
from unnest(array['uploaded', 'profiled', 'mapping_proposed', 'mapping_approved', 'transformed',
                  'validated', 'staged']) with ordinality as x (s, n) order by n;
insert into private.boarding_staging (batch_id, entity, key, data) values
  ('30000000-0000-0000-0000-000000000001', 'party', 'C-1',
   '{"kind": "legal_entity", "display_name": "Boulangerie Test", "seller_ref": "C-1", "siren": "123456782"}'),
  ('30000000-0000-0000-0000-000000000001', 'contact', 'C-1:email',
   '{"party_key": "C-1", "type": "email", "value": "compta@example.test"}'),
  ('30000000-0000-0000-0000-000000000001', 'account', 'C-1',
   '{"external_ref": "C-1", "claim_type": "b2b_invoice", "legal_regime": "commercial_b2b", "capacity": "legal_entity"}'),
  ('30000000-0000-0000-0000-000000000001', 'claim_item', 'C-1:F-1',
   '{"account_key": "C-1", "kind": "invoice", "ref": "F-1", "issue_date": "2026-05-01", "due_date": "2026-05-31", "original_minor": 125000}');

create temporary table t (k text primary key, v jsonb) on commit drop;
grant all on t to authenticated;

-- Staging is internal ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok($$select count(*) from private.boarding_staging$$, '42501', null,
  'users cannot read the staging rows');
reset role;

-- Commit ----------------------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000005", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok($$select public.commit_boarding_batch('30000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'another client cannot commit the batch');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000002", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok($$select public.commit_boarding_batch('30000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'a collector cannot commit a batch');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select lives_ok($$select public.commit_boarding_batch('30000000-0000-0000-0000-000000000001')$$,
  'the client admin commits the staged batch');
select throws_ok($$select public.commit_boarding_batch('30000000-0000-0000-0000-000000000001')$$,
  '23514', null, 'a batch is committed once');
select throws_ok($$select public.abandon_boarding_batch('30000000-0000-0000-0000-000000000001', 'too late')$$,
  '23514', null, 'a batch being committed cannot be abandoned');
select throws_ok($$select private.complete_batch_commit('30000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'only the worker runs the commit job');
reset role;
select is((select message ->> 'type' from pgmq.q_boarding
           where message ->> 'batch_id' = '30000000-0000-0000-0000-000000000001' order by msg_id desc limit 1),
  'commit', 'the request queues the commit job');
select is(private.complete_batch_commit('30000000-0000-0000-0000-000000000001'), 'committed', 'the worker job commits it');
select is(private.complete_batch_commit('30000000-0000-0000-0000-000000000001'), 'skipped', 'a redelivered job does nothing');
set local role authenticated;
select is((select count(*)::int from public.account where status = 'staged'), 1,
  'the account is created, not yet workable');
select is((select original_minor from public.claim_item), 125000::bigint, 'the invoice amount is boarded as is');
select is((select count(*)::int from public.account_party), 1, 'the account is linked to its debtor');
select throws_ok($$select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'a client cannot confirm a batch');
reset role;

-- Confirmation: servicer staff, two-factor session, active mandate ----------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok($$select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'staff must use a two-factor session to confirm');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok($$select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000001')$$,
  '23514', 'no active client mandate covers this portfolio (CPCE R124-3)',
  'no confirmation without an active mandate');

-- Rollback -----------------------------------------------------------------------------------------
select throws_ok($$select public.rollback_boarding_batch('30000000-0000-0000-0000-000000000001', ' ')$$,
  '23514', 'a reason is required', 'a rollback needs a reason');
select lives_ok($$select public.rollback_boarding_batch('30000000-0000-0000-0000-000000000001', 'wrong portfolio')$$,
  'staff roll the batch back');
select is((select count(*)::int from public.account), 0, 'the accounts of the batch are removed');
select is((select count(*)::int from public.party), 0, 'debtors with no other account are removed');
select is((select status from public.boarding_batch), 'rolled_back', 'the batch is rolled back');
reset role;

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('commit_boarding_batch', 'rollback_boarding_batch', 'confirm_boarding_batch')
     and p.prosecdef and p.proconfig @> array['search_path=""']),
  3, 'the three commands are security definer with a pinned search_path');

select * from finish();
rollback;
