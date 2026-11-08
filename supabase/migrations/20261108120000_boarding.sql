-- M1a boarding: batches, files, events, state machine, upload commands, queue.
-- State machine: docs/DOMAIN.md §4.4 (plus a `draft` state while files are uploaded).

------------------------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------------------------

create table public.boarding_batch (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  portfolio_id uuid not null references public.portfolio (id),
  version integer not null check (version > 0),
  status text not null default 'draft' check (status in (
    'draft', 'uploaded', 'profiled', 'mapping_proposed', 'mapping_approved', 'transformed',
    'needs_fix', 'validated', 'staged', 'committed', 'confirmed', 'rolled_back', 'abandoned')),
  cut_off_date date,
  conformance text not null default 'servicing' check (conformance in ('servicing', 'regulatory')),
  seller_control_totals jsonb not null default '{}',
  art4_exemptions jsonb not null default '{}',
  created_by uuid references public.app_user (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (portfolio_id, version)
);
create index boarding_batch_client_idx on public.boarding_batch (client_organization_id);
comment on table public.boarding_batch is 'One boarding of one or more tape files into a portfolio.';

create table public.boarding_file (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.boarding_batch (id) on delete cascade,
  file_name text not null check (length(file_name) between 1 and 255 and file_name !~ '[/\\]'),
  format text not null check (format in ('csv', 'xlsx', 'fixed_width', 'zip')),
  role text,
  storage_bucket text not null default 'boarding-uploads',
  storage_path text not null unique,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes bigint not null check (size_bytes > 0),
  duplicate_of_file_id uuid references public.boarding_file (id),
  status text not null default 'awaiting_upload'
    check (status in ('awaiting_upload', 'uploaded', 'profiled', 'failed')),
  row_count bigint,
  profile jsonb,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (batch_id, file_name)
);
create index boarding_file_sha_idx on public.boarding_file (sha256);

create table public.boarding_event (
  id bigint generated always as identity primary key,
  batch_id uuid not null references public.boarding_batch (id) on delete cascade,
  from_status text,
  to_status text not null,
  reason text,
  actor_id uuid,
  actor_label text,
  at timestamptz not null default now()
);
create index boarding_event_batch_idx on public.boarding_event (batch_id, at);

-- Queue jobs processed by the worker: one row per (queue, message), so a redelivered message
-- whose job already finished is acknowledged without running again.
create table private.job_run (
  queue text not null,
  msg_id bigint not null,
  status text not null check (status in ('running', 'done', 'failed', 'dead')),
  attempts integer not null default 1,
  last_error text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  primary key (queue, msg_id)
);
alter table private.job_run enable row level security;

create trigger boarding_batch_touch before update on public.boarding_batch
  for each row execute function private.touch_updated_at();
create trigger boarding_file_touch before update on public.boarding_file
  for each row execute function private.touch_updated_at();
create trigger boarding_batch_change_log after insert or update or delete on public.boarding_batch
  for each row execute function private.log_change();
create trigger boarding_file_change_log after insert or update or delete on public.boarding_file
  for each row execute function private.log_change();

select pgmq.create('boarding');
select pgmq.create('boarding_dlq');

------------------------------------------------------------------------------------------
-- State machine
------------------------------------------------------------------------------------------

create or replace function private.boarding_transition_allowed(p_from text, p_to text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select (p_from, p_to) in (
    ('draft', 'uploaded'), ('draft', 'abandoned'),
    ('uploaded', 'profiled'), ('uploaded', 'abandoned'),
    ('profiled', 'mapping_proposed'),
    ('mapping_proposed', 'mapping_approved'),
    ('mapping_approved', 'transformed'),
    ('transformed', 'validated'), ('transformed', 'needs_fix'),
    ('needs_fix', 'mapping_proposed'), ('needs_fix', 'abandoned'),
    ('validated', 'staged'),
    ('staged', 'committed'), ('staged', 'abandoned'),
    ('committed', 'confirmed'), ('committed', 'rolled_back')
  );
$$;

-- The only way to change a batch status (worker and commands). Logs a boarding_event.
create or replace function private.transition_batch(
  p_batch_id uuid, p_to text, p_reason text default null, p_actor_label text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from text;
begin
  select status into v_from from public.boarding_batch where id = p_batch_id for update;
  if not found then
    raise exception 'unknown boarding batch %', p_batch_id using errcode = 'no_data_found';
  end if;
  if not private.boarding_transition_allowed(v_from, p_to) then
    raise exception 'illegal boarding transition % -> %', v_from, p_to using errcode = 'check_violation';
  end if;
  update public.boarding_batch set status = p_to where id = p_batch_id;
  insert into public.boarding_event (batch_id, from_status, to_status, reason, actor_id, actor_label)
  values (p_batch_id, v_from, p_to, p_reason, auth.uid(),
          coalesce(p_actor_label, nullif(current_setting('app.actor', true), '')));
end;
$$;
grant execute on function private.transition_batch(uuid, text, text, text) to service_role;

-- Status changes only through transition_batch (direct updates of status are refused).
create or replace function private.guard_batch_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status is distinct from old.status
     and not private.boarding_transition_allowed(old.status, new.status) then
    raise exception 'illegal boarding transition % -> %', old.status, new.status
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger boarding_batch_status_guard before update of status on public.boarding_batch
  for each row execute function private.guard_batch_status();

------------------------------------------------------------------------------------------
-- Who may board: servicer admins/ops (aal2) and the client's own admins (SMB self-serve).
------------------------------------------------------------------------------------------

create or replace function private.can_board(p_portfolio_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.portfolio p
    where p.id = p_portfolio_id
      and (private.has_role(p.organization_id, array['admin', 'ops_manager'])
           or private.has_role(p.client_organization_id, array['client_admin']))
  );
$$;
grant execute on function private.can_board(uuid) to authenticated;

------------------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------------------

create or replace function public.create_boarding_batch(
  p_idempotency_key text,
  p_portfolio_id uuid,
  p_cut_off_date date default null,
  p_conformance text default 'servicing'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing jsonb;
  v_id uuid;
  v_portfolio public.portfolio;
begin
  select result into v_existing from private.command_log
  where command = 'create_boarding_batch' and idempotency_key = p_idempotency_key;
  if found then
    return (v_existing ->> 'batch_id')::uuid;
  end if;
  if not private.can_board(p_portfolio_id) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select * into v_portfolio from public.portfolio where id = p_portfolio_id;
  -- Serialise version numbering per portfolio.
  perform 1 from public.portfolio where id = p_portfolio_id for update;
  insert into public.boarding_batch (
    organization_id, client_organization_id, portfolio_id, version, cut_off_date, conformance, created_by)
  values (
    v_portfolio.organization_id, v_portfolio.client_organization_id, p_portfolio_id,
    coalesce((select max(version) from public.boarding_batch where portfolio_id = p_portfolio_id), 0) + 1,
    p_cut_off_date, p_conformance, auth.uid())
  returning id into v_id;
  insert into public.boarding_event (batch_id, to_status, actor_id) values (v_id, 'draft', auth.uid());
  insert into private.command_log (command, idempotency_key, actor_id, result)
  values ('create_boarding_batch', p_idempotency_key, auth.uid(), jsonb_build_object('batch_id', v_id));
  return v_id;
end;
$$;

-- Registers a file and returns where to upload it. Flags a file already boarded for this client.
create or replace function public.add_boarding_file(
  p_batch_id uuid, p_file_name text, p_sha256 text, p_size_bytes bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.boarding_batch;
  v_id uuid := gen_random_uuid();
  v_format text;
  v_path text;
  v_dup uuid;
begin
  select * into v_batch from public.boarding_batch where id = p_batch_id;
  if not found or not private.can_board(v_batch.portfolio_id) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if v_batch.status <> 'draft' then
    raise exception 'files can only be added to a draft batch' using errcode = 'check_violation';
  end if;
  v_format := case lower(substring(p_file_name from '\.([A-Za-z0-9]+)$'))
    when 'csv' then 'csv' when 'txt' then 'csv' when 'tsv' then 'csv'
    when 'xlsx' then 'xlsx' when 'dat' then 'fixed_width' when 'prn' then 'fixed_width'
    when 'zip' then 'zip' end;
  if v_format is null then
    raise exception 'unsupported file type: %', p_file_name using errcode = 'check_violation';
  end if;
  select f.id into v_dup
  from public.boarding_file f join public.boarding_batch b on b.id = f.batch_id
  where f.sha256 = lower(p_sha256) and b.client_organization_id = v_batch.client_organization_id
    and b.status not in ('rolled_back', 'abandoned')
  order by f.created_at limit 1;
  v_path := v_batch.client_organization_id || '/' || p_batch_id || '/' || v_id || '/' || p_file_name;
  insert into public.boarding_file (id, batch_id, file_name, format, storage_path, sha256, size_bytes, duplicate_of_file_id)
  values (v_id, p_batch_id, p_file_name, v_format, v_path, lower(p_sha256), p_size_bytes, v_dup);
  return jsonb_build_object(
    'file_id', v_id, 'bucket', 'boarding-uploads', 'storage_path', v_path,
    'format', v_format, 'duplicate_of_file_id', v_dup);
end;
$$;

-- All files uploaded: the batch moves to `uploaded` and one profiling job is queued.
create or replace function public.submit_boarding_batch(p_batch_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.boarding_batch;
  v_missing int;
  v_msg bigint;
begin
  select * into v_batch from public.boarding_batch where id = p_batch_id;
  if not found or not private.can_board(v_batch.portfolio_id) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if v_batch.status = 'uploaded' then
    return null;  -- already submitted: idempotent
  end if;
  if not exists (select 1 from public.boarding_file where batch_id = p_batch_id) then
    raise exception 'the batch has no file' using errcode = 'check_violation';
  end if;
  select count(*) into v_missing from public.boarding_file f
  where f.batch_id = p_batch_id
    and not exists (select 1 from storage.objects o where o.bucket_id = f.storage_bucket and o.name = f.storage_path);
  if v_missing > 0 then
    raise exception '% file(s) not uploaded yet', v_missing using errcode = 'check_violation';
  end if;
  update public.boarding_file set status = 'uploaded' where batch_id = p_batch_id;
  perform private.transition_batch(p_batch_id, 'uploaded', 'files uploaded');
  select pgmq.send('boarding', jsonb_build_object('type', 'profile', 'batch_id', p_batch_id)) into v_msg;
  return v_msg;
end;
$$;

grant execute on function public.create_boarding_batch(text, uuid, date, text) to authenticated;
grant execute on function public.add_boarding_file(uuid, text, text, bigint) to authenticated;
grant execute on function public.submit_boarding_batch(uuid) to authenticated;

------------------------------------------------------------------------------------------
-- RLS
------------------------------------------------------------------------------------------

alter table public.boarding_batch enable row level security;
alter table public.boarding_file enable row level security;
alter table public.boarding_event enable row level security;
grant select on public.boarding_batch, public.boarding_file, public.boarding_event to authenticated;

create policy boarding_batch_read on public.boarding_batch for select to authenticated
  using ((select private.can_read_portfolio(portfolio_id)));
create policy boarding_file_read on public.boarding_file for select to authenticated
  using (exists (select 1 from public.boarding_batch b where b.id = boarding_file.batch_id
    and (select private.can_read_portfolio(b.portfolio_id))));
create policy boarding_event_read on public.boarding_event for select to authenticated
  using (exists (select 1 from public.boarding_batch b where b.id = boarding_event.batch_id
    and (select private.can_read_portfolio(b.portfolio_id))));

-- Storage: a user may upload only to the exact path of a file registered in a draft batch they
-- may board. No read or delete for users: the worker reads with the service role.
create or replace function private.can_upload_boarding_object(p_bucket text, p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.boarding_file f join public.boarding_batch b on b.id = f.batch_id
    where f.storage_bucket = p_bucket and f.storage_path = p_name
      and f.status = 'awaiting_upload' and b.status = 'draft'
      and private.can_board(b.portfolio_id)
  );
$$;
grant execute on function private.can_upload_boarding_object(text, text) to authenticated;

create policy boarding_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'boarding-uploads'
              and (select private.can_upload_boarding_object(bucket_id, name)));
