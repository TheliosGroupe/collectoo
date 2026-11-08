-- Boarding batches: permissions, upload path policy, submission, queue, state machine (M1-01, M1-02).
begin;
select plan(22);

-- Fixtures ----------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client B');
insert into auth.users (id, email, aud, role) values
  ('10000000-0000-0000-0000-000000000001', 'ops@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000002', 'collector@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000003', 'admin@a.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000004', 'viewer@a.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000005', 'admin@b.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000a1', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000a2', 'client_admin');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'A');

create temporary table t (k text primary key, v jsonb) on commit drop;
grant all on t to authenticated;

-- Client admin creates a batch (SMB self-serve) -----------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
insert into t values ('batch', to_jsonb(public.create_boarding_batch(
  'batch-key-0001', '20000000-0000-0000-0000-0000000000a1', '2026-09-30')));
select is(public.create_boarding_batch('batch-key-0001', '20000000-0000-0000-0000-0000000000a1'),
  (select (v #>> '{}')::uuid from t where k = 'batch'), 'same idempotency key returns the same batch');
select is((select status from public.boarding_batch), 'draft', 'a new batch is a draft');

insert into t values ('f1', public.add_boarding_file((select (v #>> '{}')::uuid from t where k = 'batch'),
  'factures.csv', repeat('a', 64), 1200));
select matches((select v ->> 'storage_path' from t where k = 'f1'),
  '^00000000-0000-0000-0000-0000000000a1/[0-9a-f-]{36}/[0-9a-f-]{36}/factures\.csv$',
  'upload path is client/batch/file/name');
select is((select v ->> 'format' from t where k = 'f1'), 'csv', 'format detected from the extension');
select throws_ok(
  $$select public.add_boarding_file((select (v #>> '{}')::uuid from t where k = 'batch'), 'x.exe', repeat('b', 64), 10)$$,
  '23514', null, 'unsupported file types are refused');
insert into t values ('f2', public.add_boarding_file((select (v #>> '{}')::uuid from t where k = 'batch'),
  'debiteurs.xlsx', repeat('c', 64), 900));

-- Storage policy: only registered paths of a draft batch.
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values ('boarding-uploads', 'somewhere/else.csv')$$,
  '42501', null, 'cannot upload to an unregistered path');
select lives_ok(
  format($$insert into storage.objects (bucket_id, name) values ('boarding-uploads', %L)$$,
         (select v ->> 'storage_path' from t where k = 'f1')),
  'can upload to the registered path');
select throws_ok(
  $$select public.submit_boarding_batch((select (v #>> '{}')::uuid from t where k = 'batch'))$$,
  '23514', '1 file(s) not uploaded yet', 'cannot submit while a file is missing');
select lives_ok(
  format($$insert into storage.objects (bucket_id, name) values ('boarding-uploads', %L)$$,
         (select v ->> 'storage_path' from t where k = 'f2')),
  'second file uploaded');
insert into t values ('msg', to_jsonb(public.submit_boarding_batch((select (v #>> '{}')::uuid from t where k = 'batch'))));
select isnt((select v from t where k = 'msg'), 'null'::jsonb, 'submission queues a profiling job');
select is(public.submit_boarding_batch((select (v #>> '{}')::uuid from t where k = 'batch')), null,
  'submitting twice queues nothing more');
select is((select status from public.boarding_batch), 'uploaded', 'the batch is uploaded');
select is((select array_agg(status order by file_name) from public.boarding_file), array['uploaded', 'uploaded'],
  'files are marked uploaded');
select is((select array_agg(to_status order by id) from public.boarding_event), array['draft', 'uploaded'],
  'every status change is an event');
select throws_ok(
  $$select public.add_boarding_file((select (v #>> '{}')::uuid from t where k = 'batch'), 'late.csv', repeat('d', 64), 5)$$,
  '23514', null, 'no file can be added after submission');
reset role;

select is((select count(*)::int from pgmq.q_boarding), 1, 'exactly one message on the boarding queue');

-- State machine ---------------------------------------------------------------------------------
select throws_ok(
  $$update public.boarding_batch set status = 'committed'$$,
  '23514', null, 'a batch cannot jump from uploaded to committed');
select throws_ok(
  $$select private.transition_batch((select (v #>> '{}')::uuid from t where k = 'batch'), 'confirmed')$$,
  '23514', null, 'transition_batch refuses illegal transitions');

-- Permissions and isolation -------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000004", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok(
  $$select public.create_boarding_batch('batch-key-0002', '20000000-0000-0000-0000-0000000000a1')$$,
  '42501', null, 'a client viewer cannot board');
select is((select count(*)::int from public.boarding_file), 2, 'a client viewer can see their batch files');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000005", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*)::int from public.boarding_batch), 0, 'another client sees no batch');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
insert into t values ('batch2', to_jsonb(public.create_boarding_batch(
  'batch-key-0003', '20000000-0000-0000-0000-0000000000a1')));
select is(
  (select version from public.boarding_batch where id = (select (v #>> '{}')::uuid from t where k = 'batch2')),
  2, 'staff ops can board too and the version increments');
reset role;

select * from finish();
rollback;
