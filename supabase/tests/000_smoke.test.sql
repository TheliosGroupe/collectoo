-- Smoke test: pgTAP runs against the local stack. Real suites arrive with M0b (tenancy + RLS).
begin;
select plan(2);
select has_schema('public', 'public schema exists');
select is((select current_setting('server_version_num')::int >= 170000), true, 'Postgres 17 or later');
select * from finish();
rollback;
