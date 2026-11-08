-- M1e review fixes: retry-safe file registration, ASCII storage keys, abandon command,
-- failed worker jobs visible on the batch, original names of documents kept.

-- Storage object keys must be ASCII (storage-api rejects accents, `#`, `%`; `?` cuts the URL).
-- Keys are built from server-generated ids only; the original name stays in file_name.
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
  v_existing public.boarding_file;
  v_id uuid := gen_random_uuid();
  v_ext text;
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
  -- Retry-safe: registering the same file again returns its first registration.
  select * into v_existing from public.boarding_file where batch_id = p_batch_id and file_name = p_file_name;
  if found then
    if v_existing.sha256 = lower(p_sha256) and v_existing.size_bytes = p_size_bytes then
      return jsonb_build_object(
        'file_id', v_existing.id, 'bucket', v_existing.storage_bucket, 'storage_path', v_existing.storage_path,
        'format', v_existing.format, 'duplicate_of_file_id', v_existing.duplicate_of_file_id,
        'uploaded', v_existing.status <> 'awaiting_upload'
          or exists (select 1 from storage.objects o
                     where o.bucket_id = v_existing.storage_bucket and o.name = v_existing.storage_path));
    end if;
    raise exception 'another file with this name is already in the batch' using errcode = 'unique_violation';
  end if;
  v_ext := lower(substring(p_file_name from '\.([A-Za-z0-9]+)$'));
  v_format := case v_ext
    when 'csv' then 'csv' when 'txt' then 'csv' when 'tsv' then 'csv'
    when 'xlsx' then 'xlsx' when 'dat' then 'fixed_width' when 'prn' then 'fixed_width'
    when 'zip' then 'zip' end;
  if v_format is null then
    raise exception 'unsupported file type: %', p_file_name using errcode = 'check_violation';
  end if;
  select f.id into v_dup
  from public.boarding_file f join public.boarding_batch b on b.id = f.batch_id
  where f.sha256 = lower(p_sha256) and b.client_organization_id = v_batch.client_organization_id
    and b.status not in ('draft', 'rolled_back', 'abandoned')  -- unsubmitted attempts do not count
  order by f.created_at limit 1;
  v_path := v_batch.client_organization_id || '/' || p_batch_id || '/' || v_id || '.' || v_ext;
  insert into public.boarding_file (id, batch_id, file_name, format, storage_path, sha256, size_bytes, duplicate_of_file_id)
  values (v_id, p_batch_id, p_file_name, v_format, v_path, lower(p_sha256), p_size_bytes, v_dup);
  return jsonb_build_object(
    'file_id', v_id, 'bucket', 'boarding-uploads', 'storage_path', v_path,
    'format', v_format, 'duplicate_of_file_id', v_dup, 'uploaded', false);
end;
$$;

-- A batch can be abandoned at any step before commit (after commit: rollback).
create or replace function private.boarding_transition_allowed(p_from text, p_to text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select (p_from, p_to) in (
    ('draft', 'uploaded'), ('draft', 'abandoned'),
    ('uploaded', 'profiled'), ('uploaded', 'abandoned'),
    ('profiled', 'mapping_proposed'), ('profiled', 'abandoned'),
    ('mapping_proposed', 'mapping_approved'), ('mapping_proposed', 'abandoned'),
    ('mapping_approved', 'transformed'), ('mapping_approved', 'abandoned'),
    ('transformed', 'validated'), ('transformed', 'needs_fix'), ('transformed', 'abandoned'),
    ('needs_fix', 'mapping_proposed'), ('needs_fix', 'abandoned'),
    ('validated', 'staged'), ('validated', 'abandoned'),
    ('staged', 'committed'), ('staged', 'abandoned'),
    ('committed', 'confirmed'), ('committed', 'rolled_back')
  );
$$;

create or replace function public.abandon_boarding_batch(p_batch_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
begin
  select * into v from public.boarding_batch where id = p_batch_id for update;
  if not found or not private.can_board(v.portfolio_id) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if not private.boarding_transition_allowed(v.status, 'abandoned') then
    raise exception 'batch is %, it cannot be abandoned', v.status using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  delete from private.boarding_staging where batch_id = p_batch_id;
  perform private.transition_batch(p_batch_id, 'abandoned', p_reason);
end;
$$;
grant execute on function public.abandon_boarding_batch(uuid, text) to authenticated;

-- A worker job that failed for good (dead-lettered) is recorded on its batch, so the
-- back-office stops waiting and shows the error.
alter table public.boarding_batch add column failed_job jsonb;
comment on column public.boarding_batch.failed_job is
  'Last worker job dead-lettered for this batch: {type, error, at}. Set by the worker.';

-- Documents keep their original name; the storage key is built from the content hash.
alter table public.document add column file_name text;
