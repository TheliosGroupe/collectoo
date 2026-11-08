-- Retry-safe file registration, ASCII storage keys, abandon command (M1e review fixes).
begin;
select plan(16);

insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client B');
insert into auth.users (id, email, aud, role) values
  ('10000000-0000-0000-0000-000000000003', 'admin@a.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000005', 'admin@b.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000a2', 'client_admin');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'A');

create temporary table t (k text primary key, v jsonb) on commit drop;
grant all on t to authenticated;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
insert into t values ('batch', to_jsonb(public.create_boarding_batch('review-fixes-key-0001', '20000000-0000-0000-0000-0000000000a1')));
insert into t values ('f1', public.add_boarding_file((select (v #>> '{}')::uuid from t where k = 'batch'),
  'Créances août #3.csv', repeat('a', 64), 1200));

select matches((select v ->> 'storage_path' from t where k = 'f1'),
  '^00000000-0000-0000-0000-0000000000a1/[0-9a-f-]{36}/[0-9a-f-]{36}\.csv$',
  'an accented file name gets an ASCII storage key');
select is((select file_name from public.boarding_file), 'Créances août #3.csv', 'the original name is kept');
select is(
  public.add_boarding_file((select (v #>> '{}')::uuid from t where k = 'batch'), 'Créances août #3.csv', repeat('a', 64), 1200) ->> 'file_id',
  (select v ->> 'file_id' from t where k = 'f1'),
  'registering the same file again returns the first registration (retry-safe)');
select is((select count(*)::int from public.boarding_file), 1, 'no second row for a retried file');
select throws_ok(
  $$select public.add_boarding_file((select (v #>> '{}')::uuid from t where k = 'batch'), 'Créances août #3.csv', repeat('b', 64), 900)$$,
  '23505', 'another file with this name is already in the batch',
  'a different file under the same name is refused');
select lives_ok(
  format($$insert into storage.objects (bucket_id, name) values ('boarding-uploads', %L)$$,
         (select v ->> 'storage_path' from t where k = 'f1')),
  'the ASCII key is accepted by the upload policy');
select is(
  (public.add_boarding_file((select (v #>> '{}')::uuid from t where k = 'batch'), 'Créances août #3.csv', repeat('a', 64), 1200) ->> 'uploaded')::boolean,
  true, 'a retry after the upload knows the file is already stored');
select isnt(
  public.add_boarding_file((select (v #>> '{}')::uuid from t where k = 'batch'), 'copie.csv', repeat('a', 64), 1200) ->> 'duplicate_of_file_id',
  null, 'the same content under another name in the same batch is flagged');
select lives_ok($$select public.set_control_totals((select (v #>> '{}')::uuid from t where k = 'batch'), 1234567, 1200)$$,
  'control totals can be set on a draft');
select lives_ok($$select public.set_control_totals((select (v #>> '{}')::uuid from t where k = 'batch'), null, null)$$,
  'and cleared');
select is((select seller_control_totals from public.boarding_batch), '{}'::jsonb, 'cleared totals mean no reconciliation');
reset role;

-- Abandon ------------------------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000005", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok($$select public.abandon_boarding_batch((select (v #>> '{}')::uuid from t where k = 'batch'), 'x')$$,
  '42501', null, 'another client cannot abandon the batch');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok($$select public.abandon_boarding_batch((select (v #>> '{}')::uuid from t where k = 'batch'), ' ')$$,
  '23514', 'a reason is required', 'abandoning needs a reason');
select lives_ok($$select public.abandon_boarding_batch((select (v #>> '{}')::uuid from t where k = 'batch'), 'wrong file')$$,
  'the client admin abandons a draft batch');
select is((select status from public.boarding_batch), 'abandoned', 'the batch is abandoned');
select throws_ok($$select public.abandon_boarding_batch((select (v #>> '{}')::uuid from t where k = 'batch'), 'again')$$,
  '23514', null, 'an abandoned batch cannot be abandoned again');
reset role;

select * from finish();
rollback;
