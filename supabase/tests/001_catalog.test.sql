-- Catalog guarantees (ARCHITECTURE §5, ADR-0011): RLS everywhere, deny-by-default grants.
begin;
select plan(6);

select is(
  (select coalesce(array_agg(c.relname order by c.relname), '{}')
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity),
  '{}'::name[],
  'every table in public has RLS enabled'
);

select is(
  (select coalesce(array_agg(tablename || '.' || policyname), '{}')
   from pg_policies
   where schemaname = 'public'
     and (roles && array['anon', 'authenticated', 'public']::name[])
     and (coalesce(qual, '') = 'true' or coalesce(with_check, '') = 'true')),
  '{}'::text[],
  'no always-true policy for anon/authenticated'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
   where grantee = 'anon' and table_schema = 'public'),
  0,
  'anon has no table privileges in public'
);

select is(
  (select coalesce(array_agg(distinct table_name || ':' || privilege_type), '{}')
   from information_schema.role_table_grants
   where grantee = 'authenticated' and table_schema = 'public'
     and privilege_type <> 'SELECT'),
  '{}'::text[],
  'authenticated can only SELECT public tables (writes go through commands or the worker)'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
   where grantee in ('anon', 'authenticated') and table_schema in ('private', 'eba', 'pgmq')),
  0,
  'no table in private/eba/pgmq is granted to anon or authenticated'
);

select is(
  (select coalesce(array_agg(p.proname order by p.proname), '{}')
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef
     and not exists (
       select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')),
  '{}'::name[],
  'every SECURITY DEFINER function pins search_path'
);

select * from finish();
rollback;
