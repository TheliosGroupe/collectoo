-- Tenant isolation and role matrix for the tenancy tables (ROADMAP M0-09…M0-11).
begin;
select plan(34);

-- Fixtures (as postgres) ---------------------------------------------------------------
-- Servicer S with clients A and B; a second servicer S2 with client C.
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo'),
  ('00000000-0000-0000-0000-00000000000b', 'servicer', 'Other servicer');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client B'),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-00000000000b', 'Client C');

insert into auth.users (id, email, aud, role) values
  ('10000000-0000-0000-0000-000000000001', 'admin@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000002', 'collector@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000003', 'admin@a.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000004', 'viewer@a.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000005', 'admin@b.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000006', 'admin@s2.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000007', 'nobody@x.test', 'authenticated', 'authenticated');

select is((select count(*)::int from public.app_user where email like '%.test'), 7,
  'an app_user profile is created for every auth user');

insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'admin'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000a1', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000a2', 'client_admin'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-00000000000b', 'admin');

insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'A invoices'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'A rents'),
  ('20000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'B invoices'),
  ('20000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000b1', 'C loans');

-- The collector is restricted to one portfolio.
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1');

-- Integrity rules ----------------------------------------------------------------------
select throws_ok(
  $$insert into public.membership (user_id, organization_id, role) values
    ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-00000000000a', 'client_admin')$$,
  '23514', null, 'client roles are refused in a servicer organization');
select throws_ok(
  $$insert into public.membership (user_id, organization_id, role) values
    ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a1', 'collector')$$,
  '23514', null, 'staff roles are refused in a client organization');
select throws_ok(
  $$insert into public.portfolio (organization_id, client_organization_id, name) values
    ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000b1', 'cross')$$,
  '23514', null, 'a portfolio cannot pair a servicer with another servicer''s client');
select throws_ok(
  $$insert into public.organization (kind, legal_name) values ('creditor_client', 'orphan')$$,
  '23514', null, 'a client organization must belong to a servicer');

-- Access token hook ---------------------------------------------------------------------
select is(
  public.custom_access_token_hook(
    '{"user_id": "10000000-0000-0000-0000-000000000001", "claims": {"aal": "aal1"}}'::jsonb)
    -> 'claims' -> 'is_internal',
  'true'::jsonb, 'hook marks staff as internal');
select is(
  public.custom_access_token_hook(
    '{"user_id": "10000000-0000-0000-0000-000000000003", "claims": {}}'::jsonb)
    -> 'claims' -> 'org_ids',
  '["00000000-0000-0000-0000-0000000000a1"]'::jsonb, 'hook lists the client user''s organizations');
select is(
  public.custom_access_token_hook(
    '{"user_id": "10000000-0000-0000-0000-000000000001", "claims": {"aal": "aal1"}}'::jsonb)
    -> 'claims' ->> 'aal',
  'aal1', 'hook keeps existing claims');

-- Anonymous ------------------------------------------------------------------------------
set local role anon;
select throws_ok($$select * from public.portfolio$$, '42501', null, 'anon cannot read portfolios');
select throws_ok($$select * from public.organization$$, '42501', null, 'anon cannot read organizations');
reset role;

-- Staff admin of S at aal2 ---------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*)::int from public.portfolio), 3, 'S admin (aal2) sees S''s 3 portfolios');
select is((select count(*)::int from public.organization), 3, 'S admin sees S and its 2 clients');
select is((select count(*)::int from public.portfolio
  where organization_id = '00000000-0000-0000-0000-00000000000b'), 0, 'S admin sees nothing of S2');
select is((select count(*)::int from public.membership), 5, 'S admin sees memberships across S''s tenant');
select throws_ok(
  $$insert into public.portfolio (organization_id, client_organization_id, name) values
    ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'direct')$$,
  '42501', null, 'even staff cannot insert directly into a table');
select throws_ok($$update public.portfolio set name = 'x'$$, '42501', null, 'no direct update');
select throws_ok($$delete from public.portfolio$$, '42501', null, 'no direct delete');

-- Command function: idempotent, role-checked.
select isnt(
  public.create_portfolio('key-0001-abcdef', '00000000-0000-0000-0000-0000000000a2', 'B rents'),
  null, 'S admin can create a portfolio through the command function');
select is(
  public.create_portfolio('key-0001-abcdef', '00000000-0000-0000-0000-0000000000a2', 'B rents'),
  (select id from public.portfolio where name = 'B rents'),
  'same idempotency key returns the same portfolio');
select is((select count(*)::int from public.portfolio where name = 'B rents'), 1,
  'the repeated command did not create a duplicate');
select throws_ok(
  $$select public.create_portfolio('key-0002-abcdef', '00000000-0000-0000-0000-0000000000b1', 'C x')$$,
  '42501', null, 'S admin cannot create a portfolio for another servicer''s client');
reset role;

-- Staff admin of S at aal1 (no MFA) -------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*)::int from public.portfolio), 0, 'staff without MFA (aal1) sees no portfolio');
select is((select count(*)::int from public.organization), 0, 'staff without MFA sees no organization');
select throws_ok(
  $$select public.create_portfolio('key-0003-abcdef', '00000000-0000-0000-0000-0000000000a1', 'aal1')$$,
  '42501', null, 'staff without MFA cannot run commands');
reset role;

-- Collector restricted by portfolio_access ------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000002", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*)::int from public.portfolio), 1, 'restricted collector sees only granted portfolio');
select throws_ok(
  $$select public.create_portfolio('key-0004-abcdef', '00000000-0000-0000-0000-0000000000a1', 'coll')$$,
  '42501', null, 'a collector cannot create portfolios');
reset role;

-- Client A viewer ------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000004", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*)::int from public.portfolio), 2, 'client A viewer sees A''s 2 portfolios');
select is((select count(*)::int from public.organization), 1, 'client A viewer sees only A');
select is((select count(*)::int from public.membership), 1, 'client viewer sees only their own membership');
select throws_ok(
  $$select public.create_portfolio('key-0005-abcdef', '00000000-0000-0000-0000-0000000000a1', 'v')$$,
  '42501', null, 'a client user cannot create portfolios');
reset role;

-- Client A admin --------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*)::int from public.membership), 2, 'client admin sees members of their organization');
select is((select count(*)::int from public.app_user), 2, 'client admin sees profiles of their members');
reset role;

-- Client B admin and user without membership ----------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000005", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*)::int from public.portfolio
  where client_organization_id = '00000000-0000-0000-0000-0000000000a1'), 0,
  'client B admin sees nothing of client A');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000007", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(*)::int from public.portfolio) + (select count(*)::int from public.organization),
  0, 'a user without membership sees nothing');
reset role;

select * from finish();
rollback;
