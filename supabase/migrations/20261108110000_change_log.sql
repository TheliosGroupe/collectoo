-- M0-12 change history: one row per insert/update/delete on core tables (BRIEF §7).
-- Cheap, append-only, and enough to answer "who changed what, when" in a dispute.

create table private.change_log (
  id bigint generated always as identity primary key,
  table_name text not null,
  row_id text not null,
  op text not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
  changed jsonb not null,          -- INSERT: full row; UPDATE: {col: [old, new]} for changed cols; DELETE: old row
  actor_id uuid,                   -- auth user, when the change comes through the Data API
  actor_label text,                -- worker/job name, from the app.actor setting
  txid bigint not null default txid_current(),
  at timestamptz not null default now()
);
create index change_log_row_idx on private.change_log (table_name, row_id, at);
alter table private.change_log enable row level security;
comment on table private.change_log is 'Append-only change history of core tables (trigger private.log_change).';

-- Nobody updates or deletes history, not even the worker.
revoke update, delete, truncate on private.change_log from service_role;

create or replace function private.log_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_changed jsonb;
  v_key text;
begin
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_object_agg(n.key, jsonb_build_array(v_old -> n.key, n.value)), '{}')
    into v_changed
    from jsonb_each(v_new) n
    where n.key <> 'updated_at' and (v_old -> n.key) is distinct from n.value;
    if v_changed = '{}'::jsonb then
      return new;  -- no real change, nothing to record
    end if;
  else
    v_changed := coalesce(v_new, v_old);
  end if;

  -- Key columns come from the trigger arguments (default: id).
  if tg_nargs = 0 then
    v_key := coalesce(v_new, v_old) ->> 'id';
  else
    select string_agg(coalesce(v_new, v_old) ->> a, ':' order by i)
    into v_key
    from unnest(tg_argv) with ordinality as t (a, i);
  end if;
  insert into private.change_log (table_name, row_id, op, changed, actor_id, actor_label)
  values (
    tg_table_schema || '.' || tg_table_name,
    v_key,
    tg_op,
    v_changed,
    auth.uid(),
    nullif(current_setting('app.actor', true), '')
  );
  return coalesce(new, old);
end;
$$;

-- Attach to the tenancy tables created in M0b.
create trigger organization_change_log after insert or update or delete on public.organization
  for each row execute function private.log_change();
create trigger membership_change_log after insert or update or delete on public.membership
  for each row execute function private.log_change('user_id', 'organization_id');
create trigger portfolio_change_log after insert or update or delete on public.portfolio
  for each row execute function private.log_change();
create trigger portfolio_access_change_log after insert or update or delete on public.portfolio_access
  for each row execute function private.log_change('user_id', 'portfolio_id');
