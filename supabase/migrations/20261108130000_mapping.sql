-- M1b mapping: LLM call log, mapping proposals, reusable mapping profiles, approval command.

alter table public.boarding_batch add column join_keys jsonb not null default '[]';
comment on column public.boarding_batch.join_keys is
  'Columns linking the files of a multi-file batch, proposed with the mapping.';

-- Every LLM call (real or mock) is logged: prompt version, model, input hash, output (BRIEF §5).
create table private.llm_call (
  id bigint generated always as identity primary key,
  prompt_id text not null,
  prompt_version integer not null,
  provider text not null,
  model text not null,
  input_sha256 text not null check (input_sha256 ~ '^[0-9a-f]{64}$'),
  output jsonb,
  status text not null check (status in ('ok', 'invalid_output', 'error')),
  error text,
  latency_ms integer not null check (latency_ms >= 0),
  batch_id uuid references public.boarding_batch (id) on delete set null,
  created_at timestamptz not null default now()
);
create index llm_call_batch_idx on private.llm_call (batch_id);
alter table private.llm_call enable row level security;

-- Proposed (then reviewed) mapping of each source column of a boarding file.
create table public.mapping_proposal (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.boarding_batch (id) on delete cascade,
  file_id uuid not null references public.boarding_file (id) on delete cascade,
  source_column text not null,
  target text,  -- null: not mapped (kept in source_attributes)
  confidence numeric(4, 3) not null check (confidence between 0 and 1),
  rationale text not null,
  needs_review boolean not null,
  origin text not null check (origin in ('llm', 'mock', 'profile', 'human')),
  status text not null default 'proposed' check (status in ('proposed', 'accepted', 'overridden')),
  reviewed_by uuid references public.app_user (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (file_id, source_column)
);
create index mapping_proposal_batch_idx on public.mapping_proposal (batch_id);

-- Approved mappings saved per client and file layout (header signature), versioned and reused.
create table public.mapping_profile (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  header_signature text not null check (header_signature ~ '^[0-9a-f]{64}$'),
  version integer not null check (version > 0),
  headers jsonb not null,
  mapping jsonb not null,  -- {source_column: target | null}
  created_by uuid references public.app_user (id),
  created_at timestamptz not null default now(),
  unique (client_organization_id, header_signature, version)
);

create trigger mapping_proposal_touch before update on public.mapping_proposal
  for each row execute function private.touch_updated_at();
create trigger mapping_proposal_change_log after insert or update or delete on public.mapping_proposal
  for each row execute function private.log_change();
create trigger mapping_profile_change_log after insert or update or delete on public.mapping_profile
  for each row execute function private.log_change();

alter table public.mapping_proposal enable row level security;
alter table public.mapping_profile enable row level security;
grant select on public.mapping_proposal, public.mapping_profile to authenticated;

create policy mapping_proposal_read on public.mapping_proposal for select to authenticated
  using (exists (select 1 from public.boarding_batch b where b.id = mapping_proposal.batch_id
    and (select private.can_read_portfolio(b.portfolio_id))));
create policy mapping_profile_read on public.mapping_profile for select to authenticated
  using ((select private.can_read_client_data(organization_id, client_organization_id)));

-- Review: accept the proposals, with optional overrides {file_id: {source_column: target|null}}.
-- Saves one mapping profile version per file layout and moves the batch to mapping_approved.
create or replace function public.approve_mapping(p_batch_id uuid, p_overrides jsonb default '{}')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.boarding_batch;
  v_file record;
  v_mapping jsonb;
  v_headers jsonb;
  v_signature text;
begin
  select * into v_batch from public.boarding_batch where id = p_batch_id for update;
  if not found or not private.can_board(v_batch.portfolio_id) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if v_batch.status <> 'mapping_proposed' then
    raise exception 'batch is %, expected mapping_proposed', v_batch.status using errcode = 'check_violation';
  end if;

  -- Overrides: validate the columns exist, then apply.
  if exists (
    select 1 from jsonb_each(p_overrides) f, jsonb_each(f.value) c
    where not exists (select 1 from public.mapping_proposal m
                      where m.batch_id = p_batch_id and m.file_id::text = f.key and m.source_column = c.key)
  ) then
    raise exception 'override for an unknown file or column' using errcode = 'check_violation';
  end if;
  update public.mapping_proposal m
  set target = nullif(c.value #>> '{}', ''), status = 'overridden', reviewed_by = auth.uid(),
      needs_review = false
  from jsonb_each(p_overrides) f, jsonb_each(f.value) c
  where m.batch_id = p_batch_id and m.file_id::text = f.key and m.source_column = c.key
    and m.target is distinct from nullif(c.value #>> '{}', '');
  update public.mapping_proposal
  set status = 'accepted', reviewed_by = auth.uid(), needs_review = false
  where batch_id = p_batch_id and status = 'proposed';

  if exists (
    select 1 from public.mapping_proposal
    where batch_id = p_batch_id and target is not null
    group by file_id, target having count(*) > 1
  ) then
    raise exception 'two columns of one file map to the same target' using errcode = 'check_violation';
  end if;

  for v_file in select id, profile from public.boarding_file where batch_id = p_batch_id loop
    select jsonb_object_agg(source_column, target), jsonb_agg(source_column order by source_column collate "C")
    into v_mapping, v_headers
    from public.mapping_proposal where file_id = v_file.id;
    continue when v_mapping is null;
    v_signature := encode(extensions.digest(convert_to(v_headers::text, 'UTF8'), 'sha256'), 'hex');
    insert into public.mapping_profile (
      organization_id, client_organization_id, header_signature, version, headers, mapping, created_by)
    select v_batch.organization_id, v_batch.client_organization_id, v_signature,
           coalesce(max(p.version), 0) + 1, v_headers, v_mapping, auth.uid()
    from public.mapping_profile p
    where p.client_organization_id = v_batch.client_organization_id and p.header_signature = v_signature
    having coalesce((array_agg(p.mapping order by p.version desc))[1], 'null'::jsonb) is distinct from v_mapping;
  end loop;

  perform private.transition_batch(p_batch_id, 'mapping_approved', 'mapping reviewed');
end;
$$;
grant execute on function public.approve_mapping(uuid, jsonb) to authenticated;

-- Header signature used by both the worker (profile lookup) and approve_mapping.
comment on column public.mapping_profile.header_signature is
  'sha256 of the JSON array of source column names sorted ascending (jsonb text form)';
