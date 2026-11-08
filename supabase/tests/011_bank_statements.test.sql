-- M2b-2 (M2-07): bank statements, statement lines, the import and the cash_in of each statement day.
-- Design docs/design/m2b-payments.md §6–§9, §13; ADR-0013 (M2b-2 addendum). The worker's part is played
-- here by inserting the parsed lines into private.bank_import_stage and calling private.ingest_statement,
-- as the import job does in one transaction.
begin;
select plan(109);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo'),
  ('00000000-0000-0000-0000-00000000000b', 'servicer', 'Other servicer');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A');
insert into auth.users (id, email, aud, role) values
  ('10000000-0000-0000-0000-000000000001', 'ops@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000002', 'collector@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000003', 'admin@a.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000004', 'admin@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000005', 'admin@b.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-00000000000a', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-00000000000b', 'admin');
insert into public.bank_account (id, organization_id, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'FR3430001007940000000001001', 'EUR',
   'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'FR7030001007940000000002002', 'EUR',
   'Fonds de tiers CSV', 'csv', '2026-01-01'),
  ('80000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000b', 'FR0930001007940000000003003', 'EUR',
   'Autre servicer', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-00000000000a', 'FR7630004000031234567890143', 'EUR',
   'Bientôt clôturé', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-00000000000a', 'FR1420041010050500013M02606', 'EUR',
   'Clôturé', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-00000000000a', 'FR7652911690573468086161054', 'EUR',
   'Fonds de tiers 2', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-00000000000a', 'FR7658954489556714560695353', 'EUR',
   'Fonds de tiers 3', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-00000000000a', 'FR7666662613887206717771879', 'EUR',
   'Fonds de tiers CSV 2', 'csv', '2026-01-01');
update public.bank_account set status = 'closed', closed_on = '2026-02-01', closed_reason = 'replaced'
where id = '80000000-0000-0000-0000-000000000005';

create temporary table t (k text primary key, v jsonb) on commit drop;
grant all on t to authenticated;

create or replace function pg_temp.as_user(p_user uuid, p_aal text) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
-- A statement whose file is stored and whose import job runs (what submit_statement_import leaves).
create or replace function pg_temp.sha(p_id uuid) returns text language sql as $$
  select encode(sha256(convert_to(p_id::text, 'UTF8')), 'hex');
$$;
create or replace function pg_temp.statement(p_id uuid, p_bank uuid, p_sha text default null) returns void
language plpgsql as $$
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  select p_id, b.organization_id, b.id, b.currency, b.feed, 'releve.' || case b.feed when 'csv' then 'csv' else 'xml' end,
         coalesce(p_sha, pg_temp.sha(p_id)), 10, 'test/' || p_id
  from public.bank_account b where b.id = p_bank;
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = p_id;
end $$;
-- The parsed lines, as the job COPYs them: {n, key, ref?, dir, amount, date, kind?, s?, ccy?, name?, text?}
-- (ref: the bank entry's own reference, Ntry/AcctSvcrRef).
create or replace function pg_temp.stage(p_statement uuid, p_lines jsonb) returns void language sql as $$
  insert into private.bank_import_stage (statement_id, line_no, section_no, dedup_key, entry_ref, direction, amount_minor,
                                         currency, booking_date, counterparty_name, remittance_text, kind, method)
  select p_statement, (l ->> 'n')::int, coalesce((l ->> 's')::int, 1), l ->> 'key', l ->> 'ref', l ->> 'dir',
         (l ->> 'amount')::bigint, coalesce(l ->> 'ccy', 'EUR'), (l ->> 'date')::date, l ->> 'name', l ->> 'text',
         coalesce(l ->> 'kind', 'debtor_credit'), 'sct'
  from jsonb_array_elements(p_lines) l;
$$;
create or replace function pg_temp.camt(p_count int, p_opening bigint, p_closing bigint, p_from date, p_to date,
                                        p_seq int default 1)
returns jsonb language sql as $$
  select jsonb_build_object('format', 'camt053', 'version', '08', 'line_count', p_count, 'skipped_not_booked', 1,
    'sections', jsonb_build_array(jsonb_build_object('stmt_id', 'STMT', 'seq', p_seq, 'from_date', p_from, 'to_date', p_to,
      'opening_minor', p_opening::text, 'closing_minor', p_closing::text)));
$$;
create or replace function pg_temp.csv(p_count int) returns jsonb language sql as $$
  select jsonb_build_object('format', 'csv', 'version', null, 'line_count', p_count, 'skipped_not_booked', 0,
                            'sections', '[]'::jsonb);
$$;
create or replace function pg_temp.balance(p_book text, p_bank uuid default null) returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.organization_id = '00000000-0000-0000-0000-00000000000a' and la.book = p_book
    and (p_bank is null or la.bank_account_id = p_bank);
$$;

-- Structure ---------------------------------------------------------------------------------------
select has_table('public', 'bank_statement', 'bank statements');
select has_table('public', 'bank_transaction', 'statement lines');
select is((select array_agg(relrowsecurity order by relname) from pg_class
           where oid in ('public.bank_statement'::regclass, 'public.bank_transaction'::regclass)),
  array[true, true], 'RLS on both tables');
select ok(exists (select 1 from pg_constraint where conname = 'payment_bank_transaction_fk'
                  and conrelid = 'public.payment'::regclass and contype = 'f'),
  'a payment has a foreign key to its bank line (amount, date, bank account and currency included)');

-- Import of a camt.053 statement -------------------------------------------------------------------
-- S1: two days; two payments and an unsplit batch credited; a fee and a return debited.
-- Opening 0, closing 0 + 10000 + 2500 + 7000 - 150 - 2500 = 16850.
select pg_temp.statement('a0000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001');
select pg_temp.stage('a0000000-0000-0000-0000-000000000001', '[
  {"n": 1, "key": "t:A1", "dir": "credit", "amount": 10000, "date": "2026-10-01", "name": "MARTIN SAS", "text": "REGLT F-1"},
  {"n": 2, "key": "t:A2", "dir": "credit", "amount": 2500, "date": "2026-10-01"},
  {"n": 3, "key": "e:N3#1", "ref": "N3", "dir": "credit", "amount": 7000, "date": "2026-10-02", "kind": "batch_unsplit"},
  {"n": 4, "key": "e:N4#1", "ref": "N4", "dir": "debit", "amount": 150, "date": "2026-10-02", "kind": "other_debit"},
  {"n": 5, "key": "t:A5", "dir": "debit", "amount": 2500, "date": "2026-10-02", "kind": "return"}]');
insert into t select 's1', private.ingest_statement('a0000000-0000-0000-0000-000000000001',
  pg_temp.camt(5, 0, 16850, '2026-10-01', '2026-10-02'));
select is((select array[status, format_version, from_date::text, to_date::text, closing_booked_minor::text]
           from public.bank_statement where id = 'a0000000-0000-0000-0000-000000000001'),
  array['imported', '08', '2026-10-01', '2026-10-02', '16850'], 'the statement is imported with what the file says');
select is((select array[v ->> 'lines', v ->> 'new_lines', v ->> 'known_lines', v ->> 'skipped_not_booked'] from t where k = 's1'),
  array['5', '5', '0', '1'], 'every line is new; the pending entry is counted');
select is((select v -> 'payments' from t where k = 's1'), '{"count": 3, "minor": "19500"}'::jsonb,
  'three payments: the credits debtors paid, the unsplit batch included (amounts as text)');
select is((select v -> 'unposted' from t where k = 's1'), '{"lines": 2, "minor": "-2650"}'::jsonb,
  'the fee and the return are recorded, not booked (M2b-6, decision #20)');
select is((select array_agg(kind order by line_no) from public.bank_transaction
           where statement_id = 'a0000000-0000-0000-0000-000000000001'),
  array['debtor_credit', 'debtor_credit', 'batch_unsplit', 'other_debit', 'return'], 'the lines keep their kinds');
select is((select array_agg(array[p.status, p.channel, p.amount_minor::text, p.booking_date::text,
                                  coalesce(p.payer_name, ''), coalesce(p.remittance_text, '')] order by t2.line_no)
           from public.payment p join public.bank_transaction t2 on t2.id = p.bank_transaction_id
           where t2.statement_id = 'a0000000-0000-0000-0000-000000000001'),
  array[array['unmatched', 'camt053', '10000', '2026-10-01', 'MARTIN SAS', 'REGLT F-1'],
        array['unmatched', 'camt053', '2500', '2026-10-01', '', ''],
        array['unmatched', 'camt053', '7000', '2026-10-02', '', '']],
  'each payment copies its bank line and waits to be matched');
select is((select array_agg(array[e.effective_date::text, e.source_type, e.source_id, lp.amount_minor::text]
                            order by e.effective_date)
           from public.ledger_entry e join public.ledger_posting lp on lp.entry_id = e.id
           join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'client_money_cash'
           where e.entry_type = 'cash_in' and e.organization_id = '00000000-0000-0000-0000-00000000000a'
             and la.bank_account_id = '80000000-0000-0000-0000-000000000001'),
  array[array['2026-10-01', 'bank_statement', 'a0000000-0000-0000-0000-000000000001', '12500'],
        array['2026-10-02', 'bank_statement', 'a0000000-0000-0000-0000-000000000001', '7000']],
  'one cash_in per statement day, each = the day''s payments (I11)');
select is((select v -> 'cash_in' -> 1 ->> 'minor' from t where k = 's1'), '7000', 'the import reports what it booked per day');
select is(array[pg_temp.balance('client_money_cash', '80000000-0000-0000-0000-000000000001'),
                pg_temp.balance('unallocated_payment')], array[19500::bigint, -19500],
  'Dr 5120 bank account / Cr 4710 pool: money booked at import, before anyone knows whose it is (decision #1)');
select is((select bank_check from public.bank_statement where id = 'a0000000-0000-0000-0000-000000000001'),
  jsonb_build_object('as_of', '2026-10-02', 'closing_minor', '16850', 'cash_minor', '19500', 'unposted_minor', '-2650',
                     'unposted_lines', 2, 'difference_minor', '0'),
  'I9: the bank''s closing balance = cash booked + lines not booked');
select is((select count(*)::int from private.bank_import_stage where statement_id = 'a0000000-0000-0000-0000-000000000001'),
  0, 'the staged lines are gone');
select is(private.ingest_statement('a0000000-0000-0000-0000-000000000001', pg_temp.camt(5, 0, 16850, '2026-10-01', '2026-10-02')),
  '{"skipped": "imported"}'::jsonb, 'a redelivered job does nothing');

-- Importing twice creates nothing ------------------------------------------------------------------
select pg_temp.statement('a0000000-0000-0000-0000-000000000002', '80000000-0000-0000-0000-000000000001');
select pg_temp.stage('a0000000-0000-0000-0000-000000000002', '[
  {"n": 1, "key": "t:A1", "dir": "credit", "amount": 10000, "date": "2026-10-01", "name": "MARTIN SAS", "text": "REGLT F-1"},
  {"n": 2, "key": "t:A2", "dir": "credit", "amount": 2500, "date": "2026-10-01"},
  {"n": 3, "key": "e:N3#1", "ref": "N3", "dir": "credit", "amount": 7000, "date": "2026-10-02", "kind": "batch_unsplit"},
  {"n": 4, "key": "e:N4#1", "ref": "N4", "dir": "debit", "amount": 150, "date": "2026-10-02", "kind": "other_debit"},
  {"n": 5, "key": "t:A5", "dir": "debit", "amount": 2500, "date": "2026-10-02", "kind": "return"}]');
insert into t select 's2', private.ingest_statement('a0000000-0000-0000-0000-000000000002',
  pg_temp.camt(5, 0, 16850, '2026-10-01', '2026-10-02'));
select is((select array[v ->> 'new_lines', v ->> 'known_lines', v -> 'payments' ->> 'count', v ->> 'cash_in_entries']
           from t where k = 's2'), array['0', '5', '0', '0'], 'the same lines again: nothing new');
select is((select count(*)::int from public.bank_transaction where bank_account_id = '80000000-0000-0000-0000-000000000001'),
  5, 'no line twice');
select is((select count(*)::int from public.payment where bank_account_id = '80000000-0000-0000-0000-000000000001'),
  3, 'no payment twice');
select is((select count(*)::int from public.ledger_entry where entry_type = 'cash_in'
           and organization_id = '00000000-0000-0000-0000-00000000000a'), 2, 'no cash twice');
select is((select warnings from public.bank_statement where id = 'a0000000-0000-0000-0000-000000000002'),
  '[{"code": "overlap", "statements": 1}]'::jsonb, 'the page says it repeats an imported statement');
select is((select bank_check ->> 'difference_minor' from public.bank_statement where id = 'a0000000-0000-0000-0000-000000000002'),
  '0', 'and the bank balance still reconciles');

-- An overlapping statement: the last day again, then a new day ----------------------------------------
-- Opening 12500 (end of 10-01); + 7000 - 150 - 2500 (known) + 4000 + 300 (new) = 21150.
select pg_temp.statement('a0000000-0000-0000-0000-000000000003', '80000000-0000-0000-0000-000000000001');
select pg_temp.stage('a0000000-0000-0000-0000-000000000003', '[
  {"n": 1, "key": "e:N3#1", "ref": "N3", "dir": "credit", "amount": 7000, "date": "2026-10-02", "kind": "batch_unsplit"},
  {"n": 2, "key": "e:N4#1", "ref": "N4", "dir": "debit", "amount": 150, "date": "2026-10-02", "kind": "other_debit"},
  {"n": 3, "key": "t:A5", "dir": "debit", "amount": 2500, "date": "2026-10-02", "kind": "return"},
  {"n": 4, "key": "t:A6", "dir": "credit", "amount": 4000, "date": "2026-10-03"},
  {"n": 5, "key": "h:0f0f#1", "dir": "credit", "amount": 300, "date": "2026-10-03", "text": "COTISATION"}]');
insert into t select 's3', private.ingest_statement('a0000000-0000-0000-0000-000000000003',
  pg_temp.camt(5, 12500, 21150, '2026-10-02', '2026-10-03'));
select is((select array[v ->> 'new_lines', v ->> 'known_lines', v -> 'payments' ->> 'minor', v ->> 'cash_in_entries']
           from t where k = 's3'), array['2', '3', '4300', '1'], 'only the new lines are booked');
select is(pg_temp.balance('client_money_cash', '80000000-0000-0000-0000-000000000001'), 23800::bigint,
  'cash = every payment once');
select is((select bank_check ->> 'difference_minor' from public.bank_statement where id = 'a0000000-0000-0000-0000-000000000003'),
  '0', 'the bank balance reconciles at the new closing');

-- Continuity: a later statement whose opening is not the last closing (« relevé manquant »)
select pg_temp.statement('a0000000-0000-0000-0000-000000000004', '80000000-0000-0000-0000-000000000001');
select pg_temp.stage('a0000000-0000-0000-0000-000000000004', '[
  {"n": 1, "key": "t:A7", "dir": "credit", "amount": 100, "date": "2026-10-06"}]');
select private.ingest_statement('a0000000-0000-0000-0000-000000000004', pg_temp.camt(1, 25000, 25100, '2026-10-06', '2026-10-06'));
select is((select array[warnings -> 0 ->> 'code', warnings -> 0 ->> 'expected_minor', bank_check ->> 'difference_minor']
           from public.bank_statement where id = 'a0000000-0000-0000-0000-000000000004'),
  array['opening_differs', '21150', '3850'], 'a gap with the previous statement is a warning, and I9 shows the difference');

-- Continuity is checked against the statement that covers the day before (review #1): a re-download
-- that overlaps the last statement is not compared with an older one.
-- K0 01/10 (seq 7) 0 -> 1000; K1 02/10–05/10 (seq 8) 1000 -> 1700; K2 04/10–06/10 (seq 9) re-download,
-- opening 1500 (end of 03/10) -> 1800; K3 08/10 (seq 11) 1800 -> 1850.
select pg_temp.statement('d0000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000007');
select pg_temp.stage('d0000000-0000-0000-0000-000000000001', '[
  {"n": 1, "key": "t:K0", "dir": "credit", "amount": 1000, "date": "2026-10-01"}]');
select private.ingest_statement('d0000000-0000-0000-0000-000000000001', pg_temp.camt(1, 0, 1000, '2026-10-01', '2026-10-01', 7));
select pg_temp.statement('d0000000-0000-0000-0000-000000000002', '80000000-0000-0000-0000-000000000007');
select pg_temp.stage('d0000000-0000-0000-0000-000000000002', '[
  {"n": 1, "key": "t:K1", "dir": "credit", "amount": 500, "date": "2026-10-02"},
  {"n": 2, "key": "t:K2", "dir": "credit", "amount": 200, "date": "2026-10-04"}]');
select private.ingest_statement('d0000000-0000-0000-0000-000000000002', pg_temp.camt(2, 1000, 1700, '2026-10-02', '2026-10-05', 8));
select is((select warnings from public.bank_statement where id = 'd0000000-0000-0000-0000-000000000002'), '[]'::jsonb,
  'the next statement follows the previous one: no warning');
select pg_temp.statement('d0000000-0000-0000-0000-000000000003', '80000000-0000-0000-0000-000000000007');
select pg_temp.stage('d0000000-0000-0000-0000-000000000003', '[
  {"n": 1, "key": "t:K2", "dir": "credit", "amount": 200, "date": "2026-10-04"},
  {"n": 2, "key": "t:K3", "dir": "credit", "amount": 100, "date": "2026-10-06"}]');
select private.ingest_statement('d0000000-0000-0000-0000-000000000003', pg_temp.camt(2, 1500, 1800, '2026-10-04', '2026-10-06', 9));
select is((select warnings from public.bank_statement where id = 'd0000000-0000-0000-0000-000000000003'),
  '[{"code": "overlap", "statements": 1}]'::jsonb,
  'a re-download overlapping the last statement: « chevauche », never « relevé manquant » against an older one');
select pg_temp.statement('d0000000-0000-0000-0000-000000000004', '80000000-0000-0000-0000-000000000007');
select pg_temp.stage('d0000000-0000-0000-0000-000000000004', '[
  {"n": 1, "key": "t:K4", "dir": "credit", "amount": 50, "date": "2026-10-08"}]');
select private.ingest_statement('d0000000-0000-0000-0000-000000000004', pg_temp.camt(1, 1800, 1850, '2026-10-08', '2026-10-08', 11));
select is((select warnings from public.bank_statement where id = 'd0000000-0000-0000-0000-000000000004'),
  jsonb_build_array(jsonb_build_object('code', 'sequence_gap', 'previous_statement_id', 'd0000000-0000-0000-0000-000000000003',
                                       'previous_seq', '9', 'seq', '11')),
  'after it, the latest statement is the previous one: same balance, but statement 10 is missing');

-- One bank entry is booked once, whatever detail the file gives (review #0) ----------------------------
-- REM1 imported as one unsplit line, REM2 with its two details (references of their own).
select pg_temp.statement('a0000000-0000-0000-0000-000000000011', '80000000-0000-0000-0000-000000000006');
select pg_temp.stage('a0000000-0000-0000-0000-000000000011', '[
  {"n": 1, "key": "e:REM1#1", "ref": "REM1", "dir": "credit", "amount": 15000, "date": "2026-10-01", "kind": "batch_unsplit"},
  {"n": 2, "key": "t:T3", "ref": "REM2", "dir": "credit", "amount": 6000, "date": "2026-10-01"},
  {"n": 3, "key": "t:T4", "ref": "REM2", "dir": "credit", "amount": 4000, "date": "2026-10-01"}]');
select private.ingest_statement('a0000000-0000-0000-0000-000000000011', pg_temp.camt(3, 0, 25000, '2026-10-01', '2026-10-01'));
select is((select array_agg(entry_ref order by line_no) from public.bank_transaction
           where statement_id = 'a0000000-0000-0000-0000-000000000011'), array['REM1', 'REM2', 'REM2'],
  'every camt.053 line keeps the reference of its bank entry');
-- REM1 again, now with its details
select pg_temp.statement('a0000000-0000-0000-0000-000000000012', '80000000-0000-0000-0000-000000000006');
select pg_temp.stage('a0000000-0000-0000-0000-000000000012', '[
  {"n": 1, "key": "t:T3", "ref": "REM2", "dir": "credit", "amount": 6000, "date": "2026-10-01"},
  {"n": 2, "key": "t:T4", "ref": "REM2", "dir": "credit", "amount": 4000, "date": "2026-10-01"},
  {"n": 3, "key": "t:T1", "ref": "REM1", "dir": "credit", "amount": 10000, "date": "2026-10-01"},
  {"n": 4, "key": "t:T2", "ref": "REM1", "dir": "credit", "amount": 5000, "date": "2026-10-01"}]');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000012',
  pg_temp.camt(4, 0, 25000, '2026-10-01', '2026-10-01')) $$, 'entry_detail_differs: line 3 %',
  'an entry imported unsplit comes back with its details: the file is refused, the money is never booked twice');
-- REM2 again, now unsplit
select pg_temp.statement('a0000000-0000-0000-0000-000000000013', '80000000-0000-0000-0000-000000000006');
select pg_temp.stage('a0000000-0000-0000-0000-000000000013', '[
  {"n": 1, "key": "e:REM1#1", "ref": "REM1", "dir": "credit", "amount": 15000, "date": "2026-10-01", "kind": "batch_unsplit"},
  {"n": 2, "key": "e:REM2#1", "ref": "REM2", "dir": "credit", "amount": 10000, "date": "2026-10-01", "kind": "batch_unsplit"}]');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000013',
  pg_temp.camt(2, 0, 25000, '2026-10-01', '2026-10-01')) $$, 'entry_detail_differs: line 2 %', 'and the other way round');
-- REM1 split by details without references of their own: its first key comes back with another amount
select pg_temp.statement('a0000000-0000-0000-0000-000000000014', '80000000-0000-0000-0000-000000000006');
select pg_temp.stage('a0000000-0000-0000-0000-000000000014', '[
  {"n": 1, "key": "e:REM1#1", "ref": "REM1", "dir": "credit", "amount": 10000, "date": "2026-10-01"},
  {"n": 2, "key": "e:REM1#2", "ref": "REM1", "dir": "credit", "amount": 5000, "date": "2026-10-01"}]');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000014',
  pg_temp.camt(2, 0, 15000, '2026-10-01', '2026-10-01')) $$, 'reference_conflict: line 1 %',
  'details without references of their own: the unsplit line''s key comes back with another amount');
select is(array[(select count(*) from public.payment where bank_account_id = '80000000-0000-0000-0000-000000000006'),
                pg_temp.balance('client_money_cash', '80000000-0000-0000-0000-000000000006')],
  array[3::bigint, 25000], 'nothing of the refused files is booked: three payments, 250,00 € once');
-- The same entries at the same level of detail: known, nothing new, not refused
select pg_temp.statement('a0000000-0000-0000-0000-000000000015', '80000000-0000-0000-0000-000000000006');
select pg_temp.stage('a0000000-0000-0000-0000-000000000015', '[
  {"n": 1, "key": "e:REM1#1", "ref": "REM1", "dir": "credit", "amount": 15000, "date": "2026-10-01", "kind": "batch_unsplit"},
  {"n": 2, "key": "t:T3", "ref": "REM2", "dir": "credit", "amount": 6000, "date": "2026-10-01"},
  {"n": 3, "key": "t:T4", "ref": "REM2", "dir": "credit", "amount": 4000, "date": "2026-10-01"},
  {"n": 4, "key": "e:REM5#1", "ref": "REM5", "dir": "credit", "amount": 700, "date": "2026-10-02"}]');
insert into t select 'same_detail', private.ingest_statement('a0000000-0000-0000-0000-000000000015',
  pg_temp.camt(4, 0, 25700, '2026-10-01', '2026-10-02'));
select is((select array[v ->> 'new_lines', v ->> 'known_lines'] from t where k = 'same_detail'), array['1', '3'],
  'the same entries at the same level of detail are known; a new entry is booked');
-- The entry reference is the one an e: key names.
select pg_temp.statement('a0000000-0000-0000-0000-000000000016', '80000000-0000-0000-0000-000000000006');
select pg_temp.stage('a0000000-0000-0000-0000-000000000016', '[
  {"n": 1, "key": "e:REM9#1", "ref": "REM8", "dir": "credit", "amount": 100, "date": "2026-10-03"}]');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000016',
  pg_temp.camt(1, 25700, 25800, '2026-10-03', '2026-10-03')) $$, 'line_invalid: line 1 %',
  'an entry key names the entry reference the line carries');

-- Refusals: the whole import is undone, the job records the code -------------------------------------
select pg_temp.statement('a0000000-0000-0000-0000-000000000005', '80000000-0000-0000-0000-000000000001');
select pg_temp.stage('a0000000-0000-0000-0000-000000000005', '[
  {"n": 1, "key": "t:A1", "dir": "credit", "amount": 9999, "date": "2026-10-01"},
  {"n": 2, "key": "t:B2", "dir": "credit", "amount": 1, "date": "2026-10-07"}]');
select throws_ok($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000005',
  pg_temp.camt(2, 0, 10000, '2026-10-01', '2026-10-07')) $$, '22023', null,
  'a known bank reference with another amount refuses the file (a line is never dropped as known)');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000005',
  pg_temp.camt(2, 0, 10000, '2026-10-01', '2026-10-07')) $$, 'reference_conflict: line 1 %',
  'with a stable code and the line');
select is((select array[status, (select count(*) from public.bank_transaction where statement_id = s.id)::text]
           from public.bank_statement s where id = 'a0000000-0000-0000-0000-000000000005'),
  array['uploaded', '0'], 'nothing of a refused import is written');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000005',
  pg_temp.camt(2, 0, 9999, '2026-10-01', '2026-10-07')) $$, 'unbalanced: %', 'opening + lines must equal the closing balance');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000005',
  pg_temp.camt(3, 0, 10000, '2026-10-01', '2026-10-07')) $$, 'header_invalid: %', 'every staged line is the file''s');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000005',
  pg_temp.csv(2)) $$, 'header_invalid: %', 'a camt.053 statement is read as camt.053');

select pg_temp.statement('a0000000-0000-0000-0000-000000000006', '80000000-0000-0000-0000-000000000001');
select pg_temp.stage('a0000000-0000-0000-0000-000000000006', '[
  {"n": 1, "key": "t:C1", "dir": "credit", "amount": 100, "date": "2026-10-01", "ccy": "USD"}]');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000006',
  pg_temp.camt(1, 0, 100, '2026-10-01', '2026-10-01')) $$, 'currency_mismatch: %', 'lines are in the account''s currency');
select pg_temp.statement('a0000000-0000-0000-0000-000000000007', '80000000-0000-0000-0000-000000000001');
select pg_temp.stage('a0000000-0000-0000-0000-000000000007', jsonb_build_array(jsonb_build_object(
  'n', 1, 'key', 't:C2', 'dir', 'credit', 'amount', 100, 'date', private.paris_today() + 1)));
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000007',
  pg_temp.camt(1, 0, 100, '2026-10-01', '2026-10-01')) $$, 'future_booking_date: %', 'nothing is booked in the future');
select pg_temp.statement('a0000000-0000-0000-0000-000000000008', '80000000-0000-0000-0000-000000000001');
select pg_temp.stage('a0000000-0000-0000-0000-000000000008', '[
  {"n": 1, "key": "t:C3", "dir": "credit", "amount": 100, "date": "2026-10-01"},
  {"n": 2, "key": "t:C3", "dir": "credit", "amount": 100, "date": "2026-10-01"}]');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000008',
  pg_temp.camt(2, 0, 200, '2026-10-01', '2026-10-01')) $$, 'duplicate_reference_in_file: %',
  'a bank reference twice in one file refuses it');
select pg_temp.statement('a0000000-0000-0000-0000-000000000009', '80000000-0000-0000-0000-000000000001');
select pg_temp.stage('a0000000-0000-0000-0000-000000000009', '[
  {"n": 1, "key": "t:C4", "dir": "debit", "amount": 100, "date": "2026-10-01", "kind": "debtor_credit"}]');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000009',
  pg_temp.camt(1, 100, 0, '2026-10-01', '2026-10-01')) $$, 'line_invalid: %', 'a debit is never a debtor''s payment');
select pg_temp.statement('a0000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000004');
update public.bank_account set status = 'closed', closed_on = '2026-11-01', closed_reason = 'moved'
where id = '80000000-0000-0000-0000-000000000004';
select pg_temp.stage('a0000000-0000-0000-0000-00000000000a', '[
  {"n": 1, "key": "t:C5", "dir": "credit", "amount": 100, "date": "2026-10-01"}]');
select throws_like($$ select private.ingest_statement('a0000000-0000-0000-0000-00000000000a',
  pg_temp.camt(1, 0, 100, '2026-10-01', '2026-10-01')) $$, 'bank_account_closed: %',
  'a statement of a closed account is not imported (R124-2)');

-- CSV: no balance proof; lines already imported under another label are held -----------------------
select pg_temp.statement('c0000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000002');
select pg_temp.stage('c0000000-0000-0000-0000-000000000001', '[
  {"n": 1, "s": 0, "key": "c:OP1", "dir": "credit", "amount": 5000, "date": "2026-10-01",
   "text": "VIR SEPA RECU /DE DUPONT /MOTIF FACTURE 12"},
  {"n": 2, "s": 0, "key": "h:aa#1", "dir": "credit", "amount": 3000, "date": "2026-10-01",
   "text": "VIR SEPA RECU /DE MARTIN /MOTIF LOYER OCTOBRE"}]');
insert into t select 'c1', private.ingest_statement('c0000000-0000-0000-0000-000000000001', pg_temp.csv(2));
select is((select array[v -> 'payments' ->> 'count', v ->> 'cash_in_entries'] from t where k = 'c1'), array['2', '1'],
  'a CSV import books its payments the same way');
select is((select array[(bank_check is null)::text, (sections is null)::text, from_date::text] from public.bank_statement
           where id = 'c0000000-0000-0000-0000-000000000001'), array['true', 'true', '2026-10-01'],
  'a CSV proves no balance: no check, dates from its lines');
select pg_temp.statement('c0000000-0000-0000-0000-000000000002', '80000000-0000-0000-0000-000000000002');
select pg_temp.stage('c0000000-0000-0000-0000-000000000002', '[
  {"n": 1, "s": 0, "key": "h:bb#1", "dir": "credit", "amount": 5000, "date": "2026-10-01",
   "text": "VIR SEPA RECU /DE DUPONT /MOTIF FACTURE 12 SEPA"},
  {"n": 2, "s": 0, "key": "c:OP9", "dir": "credit", "amount": 3000, "date": "2026-10-01",
   "text": "VIR SEPA RECU /DE MARTIN /MOTIF LOYER OCTOBRE"},
  {"n": 3, "s": 0, "key": "c:OP7", "dir": "credit", "amount": 5000, "date": "2026-10-01",
   "text": "VIR SEPA RECU /DE DUPONT /MOTIF FACTURE 12"},
  {"n": 4, "s": 0, "key": "h:cc#1", "dir": "credit", "amount": 3000, "date": "2026-10-01",
   "text": "PRLV SEPA ASSURANCE HABITATION"}]');
insert into t select 'c2', private.ingest_statement('c0000000-0000-0000-0000-000000000002', pg_temp.csv(4));
select is((select array_agg(kind order by line_no) from public.bank_transaction
           where statement_id = 'c0000000-0000-0000-0000-000000000002'),
  array['suspected_duplicate', 'suspected_duplicate', 'debtor_credit', 'debtor_credit'],
  'same day, amount and a similar label as an earlier line: held (two lines with the bank''s own ids are distinct)');
select is((select array[v -> 'payments' ->> 'count', v ->> 'suspected_duplicates', v -> 'unposted' ->> 'minor']
           from t where k = 'c2'), array['2', '2', '8000'], 'held lines get no payment and no cash');
select is(pg_temp.balance('client_money_cash', '80000000-0000-0000-0000-000000000002'), 16000::bigint,
  'cash = the payments only');
select pg_temp.statement('c0000000-0000-0000-0000-000000000003', '80000000-0000-0000-0000-000000000002');
select pg_temp.stage('c0000000-0000-0000-0000-000000000003', '[
  {"n": 1, "s": 1, "key": "t:X", "dir": "credit", "amount": 5, "date": "2026-10-01"}]');
select throws_like($$ select private.ingest_statement('c0000000-0000-0000-0000-000000000003', pg_temp.csv(1)) $$,
  'line_invalid: %', 'CSV lines carry CSV keys and no statement section');
select pg_temp.statement('c0000000-0000-0000-0000-000000000004', '80000000-0000-0000-0000-000000000002');
select pg_temp.stage('c0000000-0000-0000-0000-000000000004', '[
  {"n": 1, "s": 0, "key": "c:X", "ref": "N1", "dir": "credit", "amount": 5, "date": "2026-10-01"}]');
select throws_like($$ select private.ingest_statement('c0000000-0000-0000-0000-000000000004', pg_temp.csv(1)) $$,
  'line_invalid: %', 'and no bank entry reference');

-- The same money is never booked on two bank accounts (review #2): a CSV export uploaded on the wrong
-- client-funds account, then on the right one.
select pg_temp.statement('c0000000-0000-0000-0000-000000000005', '80000000-0000-0000-0000-000000000008',
                         pg_temp.sha('c0000000-0000-0000-0000-000000000001'));
select pg_temp.stage('c0000000-0000-0000-0000-000000000005', '[
  {"n": 1, "s": 0, "key": "c:Q1", "dir": "credit", "amount": 5000, "date": "2026-10-01"}]');
select throws_like($$ select private.ingest_statement('c0000000-0000-0000-0000-000000000005', pg_temp.csv(1)) $$,
  'imported_on_other_account: %', 'a file already imported on another bank account of the servicer is refused');
select pg_temp.statement('c0000000-0000-0000-0000-000000000006', '80000000-0000-0000-0000-000000000008');
select pg_temp.stage('c0000000-0000-0000-0000-000000000006', '[
  {"n": 1, "s": 0, "key": "c:Q2", "dir": "credit", "amount": 100, "date": "2026-10-02"},
  {"n": 2, "s": 0, "key": "c:OP1", "dir": "credit", "amount": 5000, "date": "2026-10-01",
   "text": "VIR SEPA RECU /DE DUPONT /MOTIF FACTURE 12"}]');
select throws_like($$ select private.ingest_statement('c0000000-0000-0000-0000-000000000006', pg_temp.csv(2)) $$,
  'imported_on_other_account: line 2 %',
  'another export with a bank operation of another account (same id, day, amount and direction) is refused');
select pg_temp.statement('c0000000-0000-0000-0000-000000000007', '80000000-0000-0000-0000-000000000008');
select pg_temp.stage('c0000000-0000-0000-0000-000000000007', '[
  {"n": 1, "s": 0, "key": "c:OP1", "dir": "credit", "amount": 4999, "date": "2026-10-01"},
  {"n": 2, "s": 0, "key": "h:aa#1", "dir": "credit", "amount": 3000, "date": "2026-10-01",
   "text": "VIR SEPA RECU /DE MARTIN /MOTIF LOYER OCTOBRE"},
  {"n": 3, "s": 0, "key": "h:dd#1", "dir": "credit", "amount": 3000, "date": "2026-10-01",
   "text": "VIR SEPA RECU /DE MARTIN /MOTIF LOYER OCTOBRE"}]');
insert into t select 'c7', private.ingest_statement('c0000000-0000-0000-0000-000000000007', pg_temp.csv(3));
select is((select array_agg(kind order by line_no) from public.bank_transaction
           where statement_id = 'c0000000-0000-0000-0000-000000000007'),
  array['debtor_credit', 'suspected_duplicate', 'debtor_credit'],
  'a bank id of another account with other facts is another operation; a line whose fingerprint is on another account is held');

-- Facts are append-only; a payment is its bank line ------------------------------------------------
select throws_ok($$ update public.bank_transaction set amount_minor = 1 $$, '23514', null, 'bank lines never change');
select throws_ok($$ delete from public.bank_transaction $$, '23514', null, 'nor disappear');
select throws_ok($$ delete from public.bank_statement $$, '23514', null, 'statements are kept');
select throws_ok($$ update public.bank_statement set status = 'uploaded'
  where id = 'a0000000-0000-0000-0000-000000000001' $$, '23514', null, 'a finished statement never changes');
select throws_ok($$ update public.bank_statement set file_sha256 = repeat('0', 64)
  where id = 'a0000000-0000-0000-0000-000000000005' $$, '23514', null, 'nor does its file');
select throws_ok($$ insert into public.bank_statement (organization_id, bank_account_id, currency, format, file_name,
  file_sha256, size_bytes, storage_path) values ('00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000005',
  'EUR', 'camt053', 'x.xml', repeat('9', 64), 1, 'test/closed') $$, '23514', null,
  'no statement for a closed bank account');
select throws_ok($$ insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no,
  dedup_key, direction, amount_minor, currency, booking_date, kind) values ('00000000-0000-0000-0000-00000000000a',
  '80000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 9, 't:LATE', 'credit', 1, 'EUR',
  '2026-10-01', 'debtor_credit') $$, '23514', null, 'no line is added to an imported statement');
insert into t select 'debit_line', to_jsonb(id) from public.bank_transaction where dedup_key = 'e:N4#1';
insert into t select 'credit_line', to_jsonb(id) from public.bank_transaction where dedup_key = 't:A6';
insert into t select 'held_line', to_jsonb(id) from public.bank_transaction where dedup_key = 'h:bb#1';
select throws_ok(format($$ insert into public.payment (organization_id, bank_account_id, bank_transaction_id, channel, method,
  amount_minor, currency, booking_date) values ('00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001',
  %L, 'camt053', 'sct', 150, 'EUR', '2026-10-02') $$, (select v #>> '{}' from t where k = 'debit_line')),
  '23514', null, 'a debit is not a payment');
select throws_ok(format($$ insert into public.payment (organization_id, bank_account_id, bank_transaction_id, channel, method,
  amount_minor, currency, booking_date) values ('00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000002',
  %L, 'csv', 'sct', 5001, 'EUR', '2026-10-01') $$, (select v #>> '{}' from t where k = 'held_line')),
  '23503', null, 'a payment has its line''s amount');
select throws_ok(format($$ insert into public.payment (organization_id, bank_account_id, bank_transaction_id, channel, method,
  amount_minor, currency, booking_date) values ('00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000002',
  %L, 'csv', 'sct', 5000, 'EUR', '2026-10-01') $$, (select v #>> '{}' from t where k = 'held_line')),
  '23514', null, 'a line held as a suspected duplicate is not a payment (until ops release it)');
select throws_ok(format($$ insert into public.payment (organization_id, bank_account_id, bank_transaction_id, channel, method,
  amount_minor, currency, booking_date) values ('00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001',
  %L, 'camt053', 'sct', 4000, 'EUR', '2026-10-03') $$, (select v #>> '{}' from t where k = 'credit_line')),
  '23505', null, 'one payment per line');
select throws_ok($$ insert into public.payment (organization_id, bank_account_id, channel, method, amount_minor, currency,
  booking_date) values ('00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001', 'csv', 'sct', 100,
  'EUR', '2026-10-01') $$, '23514', null, 'a bank payment always has its line');

-- Commands: upload a statement (admins and ops managers at aal2) --------------------------------------
select pg_temp.as_user('10000000-0000-0000-0000-000000000001', 'aal2');
set local role authenticated;
insert into t select 'up', public.create_statement_upload('upload-key-0001', '80000000-0000-0000-0000-000000000001',
  'Relevé octobre.xml', repeat('E', 64), 2048);
select matches((select v ->> 'storage_path' from t where k = 'up'),
  '^00000000-0000-0000-0000-00000000000a/80000000-0000-0000-0000-000000000001/[0-9a-f-]{36}\.xml$',
  'the upload key is servicer/bank account/statement id (ASCII only)');
select is((select array[v ->> 'bucket', v ->> 'format', v ->> 'status', v ->> 'duplicate', v ->> 'uploaded'] from t where k = 'up'),
  array['bank-statements', 'camt053', 'awaiting_upload', 'false', 'false'], 'a statement waits for its file');
select is(public.create_statement_upload('upload-key-0001', '80000000-0000-0000-0000-000000000001',
  'Relevé octobre.xml', repeat('E', 64), 2048) ->> 'statement_id', (select v ->> 'statement_id' from t where k = 'up'),
  'a replay returns the same statement');
select throws_ok($$ select public.create_statement_upload('upload-key-0001', '80000000-0000-0000-0000-000000000001',
  'autre.xml', repeat('E', 64), 2048) $$, '22023', null, 'the same key for another request is refused');
select is(public.create_statement_upload('upload-key-0002', '80000000-0000-0000-0000-000000000001',
  'copie.xml', repeat('e', 64), 2048) ->> 'statement_id', (select v ->> 'statement_id' from t where k = 'up'),
  'the same file for the same account is one statement');
select throws_ok($$ select public.create_statement_upload('upload-key-0003', '80000000-0000-0000-0000-000000000001',
  'export.csv', repeat('1', 64), 10) $$, '23514', 'the file format does not match the bank account feed',
  'a CSV on a camt.053 account is refused (different dedup keys could book money twice)');
select throws_ok($$ select public.create_statement_upload('upload-key-0004', '80000000-0000-0000-0000-000000000001',
  'releve.pdf', repeat('2', 64), 10) $$, '23514', 'unsupported statement file type', 'only XML and CSV files');
select throws_ok($$ select public.create_statement_upload('upload-key-0005', '80000000-0000-0000-0000-000000000001',
  'a/b.xml', repeat('3', 64), 10) $$, '23514', 'invalid file', 'no path in a file name');
select throws_ok($$ select public.create_statement_upload('upload-key-0006', '80000000-0000-0000-0000-000000000001',
  'gros.xml', repeat('4', 64), 524288001) $$, '23514', 'the file is too large', 'files up to 500 MB');
select throws_ok($$ select public.create_statement_upload('upload-key-0007', '80000000-0000-0000-0000-000000000005',
  'clos.xml', repeat('5', 64), 10) $$, '23514', 'the bank account is closed', 'not for a closed account');
select throws_ok($$ select public.submit_statement_import('submit-key-0001', (select (v ->> 'statement_id')::uuid
  from t where k = 'up')) $$, '23514', 'the file is not uploaded yet', 'nothing is queued before the file is stored');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('bank-statements', 'somewhere/else.xml') $$,
  '42501', null, 'cannot upload to an unregistered path');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('bank-statements', %L) $$,
  (select v ->> 'storage_path' from t where k = 'up')), 'can upload to the statement''s key');
select is(public.submit_statement_import('submit-key-0001', (select (v ->> 'statement_id')::uuid from t where k = 'up')),
  'uploaded', 'the import is queued');
select is(public.submit_statement_import('submit-key-0002', (select (v ->> 'statement_id')::uuid from t where k = 'up')),
  'uploaded', 'submitting again queues nothing more');
select is((select array[v ->> 'duplicate', v ->> 'uploaded'] from (select public.create_statement_upload('upload-key-0008',
  '80000000-0000-0000-0000-000000000001', 'encore.xml', repeat('e', 64), 2048) as v) x), array['true', 'true'],
  'the same file once submitted: the page opens the statement already there');
reset role;
select is((select count(*)::int from pgmq.q_payments), 1, 'exactly one import job');
select is((select message from pgmq.q_payments), jsonb_build_object('type', 'import',
  'statement_id', (select v ->> 'statement_id' from t where k = 'up')), 'naming the statement');

select pg_temp.as_user('10000000-0000-0000-0000-000000000002', 'aal2');
set local role authenticated;
select throws_ok($$ select public.create_statement_upload('upload-key-0009', '80000000-0000-0000-0000-000000000001',
  'r.xml', repeat('6', 64), 10) $$, '42501', null, 'collectors do not import statements (decision #18)');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000003', 'aal1');
set local role authenticated;
select throws_ok($$ select public.create_statement_upload('upload-key-0010', '80000000-0000-0000-0000-000000000001',
  'r.xml', repeat('6', 64), 10) $$, '42501', null, 'nor do clients');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000005', 'aal2');
set local role authenticated;
select throws_ok($$ select public.create_statement_upload('upload-key-0011', '80000000-0000-0000-0000-000000000001',
  'r.xml', repeat('6', 64), 10) $$, '42501', null, 'nor another servicer');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000001', 'aal1');
set local role authenticated;
select throws_ok($$ select public.create_statement_upload('upload-key-0012', '80000000-0000-0000-0000-000000000001',
  'r.xml', repeat('6', 64), 10) $$, '42501', null, 'nor an ops manager without two-factor');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000004', 'aal2');
set local role authenticated;
select lives_ok($$ select public.create_statement_upload('upload-key-0013', '80000000-0000-0000-0000-000000000002',
  'export octobre.CSV', repeat('7', 64), 10) $$, 'an admin imports too (CSV on a CSV account)');
select throws_ok(format($$ select public.create_statement_upload('upload-key-0014', '80000000-0000-0000-0000-000000000008',
  'export.csv', %L, 10) $$, pg_temp.sha('c0000000-0000-0000-0000-000000000001')), '23514',
  'the file is already a statement of another bank account',
  'a file imported on one client-funds account is not uploaded on another (review #2)');
select lives_ok($$ select public.create_statement_upload('upload-key-0015', '80000000-0000-0000-0000-000000000008',
  'export octobre.CSV', repeat('7', 64), 10) $$, 'a file registered on another account but never sent does not block');
reset role;

-- Read access (RLS): third-party payer data, admins and ops managers of the servicer --------------------
-- A statement of the other servicer.
select pg_temp.statement('b0000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000003');
select pg_temp.stage('b0000000-0000-0000-0000-000000000001', '[
  {"n": 1, "key": "t:B1", "dir": "credit", "amount": 100, "date": "2026-10-01"}]');
select private.ingest_statement('b0000000-0000-0000-0000-000000000001', pg_temp.camt(1, 0, 100, '2026-10-01', '2026-10-01'));
insert into t select 'n_stmt', to_jsonb(count(*)) from public.bank_statement where organization_id = '00000000-0000-0000-0000-00000000000a';
insert into t select 'n_line', to_jsonb(count(*)) from public.bank_transaction where organization_id = '00000000-0000-0000-0000-00000000000a';

select pg_temp.as_user('10000000-0000-0000-0000-000000000001', 'aal2');
set local role authenticated;
select is((select count(*)::int from public.bank_statement), (select (v #>> '{}')::int from t where k = 'n_stmt'),
  'an ops manager reads the servicer''s statements');
select is((select count(*)::int from public.bank_transaction), (select (v #>> '{}')::int from t where k = 'n_line'),
  'and their lines');
select throws_ok($$ insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key,
  direction, amount_minor, currency, booking_date, kind) values ('00000000-0000-0000-0000-00000000000a',
  '80000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000005', 1, 't:Z', 'credit', 1, 'EUR', '2026-10-01',
  'debtor_credit') $$, '42501', null, 'but writes no line');
select throws_ok($$ update public.bank_statement set error = 'x' $$, '42501', null, 'and changes no statement');
select throws_ok($$ select private.ingest_statement('a0000000-0000-0000-0000-000000000005', '{}') $$, '42501', null,
  'nor runs an import');
select throws_ok($$ select count(*) from private.bank_import_stage $$, '42501', null, 'nor reads the staged lines');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000004', 'aal2');
set local role authenticated;
select is((select count(*)::int from public.bank_statement), (select (v #>> '{}')::int from t where k = 'n_stmt'),
  'an admin reads them too');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000001', 'aal1');
set local role authenticated;
select is((select count(*)::int from public.bank_statement), 0, 'not without two-factor');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000002', 'aal2');
set local role authenticated;
select is((select count(*)::int from public.bank_statement) + (select count(*)::int from public.bank_transaction), 0,
  'collectors read no bank line (third-party payer data)');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000003', 'aal1');
set local role authenticated;
select is((select count(*)::int from public.bank_statement) + (select count(*)::int from public.bank_transaction), 0,
  'nor clients (they get the payment feed, not bank lines)');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000005', 'aal2');
set local role authenticated;
select is((select array_agg(id::text) from public.bank_statement), array['b0000000-0000-0000-0000-000000000001'],
  'another servicer reads only its own statements');
select is((select count(*)::int from public.bank_transaction), 1, 'and its own lines');
reset role;
set local role anon;
select throws_ok($$ select count(*) from public.bank_statement $$, '42501', null, 'anonymous users read nothing');
reset role;

-- Ledger -------------------------------------------------------------------------------------------
select is(pg_temp.balance('client_money_cash') + pg_temp.balance('unallocated_payment') + pg_temp.balance('client_payable'),
  0::bigint, 'I8: Σ5120 + Σ4710 + Σ4670 = 0');
select lives_ok($$ set constraints all immediate $$, 'every entry written by the imports passes the commit-time checks');

select * from finish();
rollback;
