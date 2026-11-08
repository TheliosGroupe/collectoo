-- M0b foundations: schemas, extensions, deny-by-default privileges.
-- Forward-only. See docs/ARCHITECTURE.md §4–5 and ADR-0011.

-- Internal schemas: never exposed through the Data API.
create schema if not exists private;
create schema if not exists eba;
revoke all on schema private, eba from public, anon, authenticated;
grant usage on schema private, eba to service_role;

-- Extensions used by the flow engine and queues (ADR-0004).
create extension if not exists pg_cron;
create extension if not exists pgmq;

-- Deny by default in the exposed schema. Supabase's defaults grant every new table and
-- function to anon/authenticated; we revoke that and grant explicitly per object:
--   * tables: authenticated gets SELECT only (rows filtered by RLS); writes go through the
--     worker (service_role) or SECURITY DEFINER command functions.
--   * functions: EXECUTE is granted one by one.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;

-- Same for objects created later in private/eba.
alter default privileges for role postgres in schema private
  revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema eba
  revoke all on tables from anon, authenticated;

-- updated_at helper.
create or replace function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
