-- M1c transformation, validation and data-quality report.

alter table public.boarding_batch
  add column dq_report jsonb,
  add column transform_spec_version integer,
  add column validation_spec_version integer,
  add column claim_type_spec_version integer;

create table public.validation_issue (
  id bigint generated always as identity primary key,
  batch_id uuid not null references public.boarding_batch (id) on delete cascade,
  file_id uuid not null references public.boarding_file (id) on delete cascade,
  row_number integer check (row_number > 0),  -- 1-based data row; null = file-level
  source_column text,
  target text,
  code text not null,
  severity text not null check (severity in ('blocking', 'warning')),
  message text not null,
  raw_value text,
  created_at timestamptz not null default now()
);
create index validation_issue_batch_idx on public.validation_issue (batch_id, severity, code);
alter table public.validation_issue enable row level security;
grant select on public.validation_issue to authenticated;
create policy validation_issue_read on public.validation_issue for select to authenticated
  using (exists (select 1 from public.boarding_batch b where b.id = validation_issue.batch_id
    and (select private.can_read_portfolio(b.portfolio_id))));

-- Address normalisation cache (BAN or mock), keyed by provider + normalised query.
create table private.address_cache (
  query_hash text primary key check (query_hash ~ '^[0-9a-f]{64}$'),
  provider text not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
alter table private.address_cache enable row level security;

-- Seller control totals for the reconciliation in the data-quality report.
create or replace function public.set_control_totals(p_batch_id uuid, p_total_minor bigint, p_rows integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_portfolio uuid;
begin
  select portfolio_id into v_portfolio from public.boarding_batch where id = p_batch_id;
  if v_portfolio is null or not private.can_board(v_portfolio) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  update public.boarding_batch
  set seller_control_totals = jsonb_build_object('total_minor', p_total_minor, 'rows', p_rows)
  where id = p_batch_id;
end;
$$;
grant execute on function public.set_control_totals(uuid, bigint, integer) to authenticated;

-- Approval now queues the transformation and validation job (same transaction).
create or replace function private.queue_transform_after_approval()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'mapping_approved' and old.status is distinct from 'mapping_approved' then
    perform pgmq.send('boarding', jsonb_build_object('type', 'transform', 'batch_id', new.id));
  end if;
  return new;
end;
$$;
create trigger boarding_batch_queue_transform after update of status on public.boarding_batch
  for each row execute function private.queue_transform_after_approval();
