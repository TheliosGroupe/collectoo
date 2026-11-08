-- Layer 1/2 schema, change history and client isolation (ROADMAP M0-12 … M0-14).
begin;
select plan(24);

-- Fixtures --------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client B');
insert into auth.users (id, email, aud, role) values
  ('10000000-0000-0000-0000-000000000001', 'staff@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000003', 'viewer@a.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000005', 'viewer@b.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000a2', 'client_viewer');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'A'),
  ('20000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'B');

insert into public.party (id, organization_id, client_organization_id, kind, display_name) values
  ('30000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'legal_entity', 'Debtor of A'),
  ('30000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'legal_entity', 'Debtor of B');

-- Tenant columns are derived from the portfolio, whatever the caller sends.
insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref, legal_regime)
values ('40000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2',
        '20000000-0000-0000-0000-0000000000a1', 'b2b_invoice', 'A-001', 'commercial_b2b');
insert into public.account (id, portfolio_id, claim_type_code, external_ref, legal_regime, organization_id, client_organization_id)
values ('40000000-0000-0000-0000-0000000000b1', '20000000-0000-0000-0000-0000000000b1', 'b2b_invoice', 'B-001', 'commercial_b2b',
        '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2');

select is(
  (select client_organization_id from public.account where id = '40000000-0000-0000-0000-0000000000a1'),
  '00000000-0000-0000-0000-0000000000a1'::uuid,
  'account tenant columns come from its portfolio, not from the caller');
select is((select status from public.account where id = '40000000-0000-0000-0000-0000000000a1'), 'staged',
  'new accounts start staged');
select is((select count(*)::int from public.claim_type), 11, 'the 11 claim types are seeded');

-- Integrity --------------------------------------------------------------------------------
select throws_ok(
  $$insert into public.account_party (account_id, party_id, role, capacity)
    values ('40000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000b1', 'borrower', 'legal_entity')$$,
  '23514', null, 'a debtor of client B cannot be attached to an account of client A');
select lives_ok(
  $$insert into public.account_party (account_id, party_id, role, capacity)
    values ('40000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'borrower', 'legal_entity')$$,
  'same-client debtor can be attached');
select throws_ok(
  $$insert into public.party_identifier (party_id, scheme, value)
    values ('30000000-0000-0000-0000-0000000000a1', 'siren', '12345')$$,
  '23514', null, 'SIREN must have 9 digits');

insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type, valid_from, valid_to)
values ('40000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a',
        'mandate_amicable', '2026-01-01', '2026-07-01');
select throws_ok(
  $$insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type, valid_from)
    values ('40000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a',
            'owned', '2026-06-01')$$,
  '23P01', null, 'ownership periods of one account cannot overlap');
select lives_ok(
  $$insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type, valid_from)
    values ('40000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a',
            'owned', '2026-07-01')$$,
  'a new owner can start the day the previous period ends');

insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on) values
  ('50000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'M-A-1', 'mandate_amicable', '2026-01-01');
insert into public.mandate_terms (mandate_id, valid_from, commission_rate) values
  ('50000000-0000-0000-0000-0000000000a1', '2026-01-01', 0.15);
select throws_ok(
  $$insert into public.mandate_terms (mandate_id, valid_from, commission_rate)
    values ('50000000-0000-0000-0000-0000000000a1', '2026-06-01', 0.12)$$,
  '23P01', null, 'mandate terms versions cannot overlap');
select throws_ok(
  $$insert into public.mandate_terms (mandate_id, valid_from, valid_to, commission_rate, remittance_max_days)
    values ('50000000-0000-0000-0000-0000000000a1', '2025-01-01', '2025-12-31', 0.1, 45)$$,
  '23514', null, 'remittance delay is capped at 30 days (R124-6)');

-- Change history ----------------------------------------------------------------------------
select set_config('app.actor', 'boarding-worker', true);
update public.account set seller_limitation_date = '2028-01-01' where id = '40000000-0000-0000-0000-0000000000a1';
select is(
  (select changed from private.change_log
   where table_name = 'public.account' and row_id = '40000000-0000-0000-0000-0000000000a1' and op = 'UPDATE'),
  '{"seller_limitation_date": [null, "2028-01-01"]}'::jsonb,
  'an update logs only the changed column with old and new values');
select is(
  (select actor_label from private.change_log
   where table_name = 'public.account' and row_id = '40000000-0000-0000-0000-0000000000a1' and op = 'UPDATE'),
  'boarding-worker', 'the worker''s actor label is recorded');
update public.account set seller_limitation_date = '2028-01-01' where id = '40000000-0000-0000-0000-0000000000a1';
select is(
  (select count(*)::int from private.change_log
   where table_name = 'public.account' and row_id = '40000000-0000-0000-0000-0000000000a1' and op = 'UPDATE'),
  1, 'an update that changes nothing is not logged');
select is(
  (select count(*)::int from private.change_log where table_name = 'public.account_party' and op = 'INSERT'
     and row_id = '40000000-0000-0000-0000-0000000000a1:30000000-0000-0000-0000-0000000000a1:borrower'),
  1, 'composite keys are logged as key1:key2:key3');
set local role service_role;
select throws_ok($$delete from private.change_log$$, '42501', null, 'even the worker cannot delete history');
reset role;

-- Layer 1 (EU template) -----------------------------------------------------------------------
select is(
  (select count(*)::int from eba.field_catalogue fc
   where not exists (select 1 from information_schema.columns c
                     where c.table_schema = 'eba' and c.column_name = fc.column_name)),
  0, 'every catalogue field has a column in the eba tables');
select is((select count(*)::int from eba.field_catalogue), 135, 'the catalogue holds the 135 EUR-Lex fields');

-- Isolation --------------------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select array_agg(external_ref) from public.account), array['A-001'], 'client A sees only its account');
select is((select count(*)::int from public.party), 1, 'client A sees only its debtor');
select is((select count(*)::int from public.claim_ownership_period), 2, 'client A sees its account''s ownership history');
select throws_ok($$select * from eba.t3_loan$$, '42501', null, 'Layer-1 staging is not readable from the API');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000005", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*)::int from public.mandate), 0, 'client B cannot see client A''s mandate');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*)::int from public.account), 2, 'staff (aal2) see accounts of all clients of their tenant');
reset role;
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*)::int from public.party), 0, 'staff without MFA see no debtor');
reset role;

select * from finish();
rollback;
