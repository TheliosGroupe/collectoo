-- 20261110130000 plan robustness: the redefined functions keep their owner, privileges, settings and kind; only
-- their plans change (their results are checked where their fixtures are: 011 imports, 012 and 013 unassign and
-- positions, 013 and 015 the payment page, 014 receipt payloads and golden hashes, 015 the debit job's candidates). The statement-import lookups are
-- checked here, in the states that made them slow, by what they read (pg_stat_xact_user_tables: this transaction's
-- scans), which does not depend on the machine's speed.
begin;
select plan(20);

create temp table _fn (sig regprocedure primary key, config text[], secdef boolean, volatility "char",
                       grantees text[]);
insert into _fn values
  ('private.bank_import_entry_known(uuid)',
   array['search_path=""', 'enable_hashjoin=off', 'enable_mergejoin=off', 'enable_bitmapscan=off',
         'enable_seqscan=off'], false, 's', '{}'),
  ('private.bank_import_lines_elsewhere(uuid, uuid)',
   array['search_path=""', 'enable_nestloop=off', 'enable_mergejoin=off'], false, 's', '{}'),
  ('private.payment_positions(uuid[])', array['search_path=""', 'enable_seqscan=off'], false, 's',
   array['service_role']),
  ('private.receipt_payload(uuid)', array['search_path=""', 'enable_hashjoin=off', 'enable_mergejoin=off'], false,
   's', '{}'),
  ('public.unassign_payment(text, uuid, text)', array['search_path=""', 'lock_timeout=2s'], true, 'v',
   array['authenticated', 'service_role']),
  ('public.payment_detail(uuid)', array['search_path=""'], true, 's', array['authenticated', 'service_role']),
  ('private.debit_candidates(uuid, date, uuid, integer)',
   array['search_path=""', 'enable_hashjoin=off', 'enable_mergejoin=off'], true, 'v', array['service_role']);

select is((select count(*)::int from _fn f join pg_proc p on p.oid = f.sig), 7, 'the seven redefined functions exist');
select is((select array_agg(f.sig::text order by f.sig::text) from _fn f join pg_proc p on p.oid = f.sig
           where pg_get_userbyid(p.proowner) <> 'postgres'), null, 'they are still owned by postgres');
select is((select array_agg(f.sig::text order by f.sig::text) from _fn f join pg_proc p on p.oid = f.sig
           where p.proconfig is distinct from f.config), null,
  'each has its SET clauses (entry_known and payment_positions add enable_seqscan = off; lines_elsewhere forbids '
  'nested loops and merge joins instead of hash and merge joins)');
select is((select array_agg(f.sig::text order by f.sig::text) from _fn f join pg_proc p on p.oid = f.sig
           where p.prosecdef <> f.secdef or p.provolatile <> f.volatility), null,
  'and its security (definer or invoker) and volatility');
select is((select array_agg(f.sig::text || ' ' || r.rolname order by f.sig::text, r.rolname)
           from _fn f cross join pg_roles r
           where r.rolname in ('anon', 'authenticated', 'service_role')
             and has_function_privilege(r.rolname, f.sig, 'execute') <> (r.rolname = any (f.grantees))), null,
  'who may execute each is unchanged (anon never; authenticated: unassign_payment and payment_detail; service_role: '
  'payment_positions and debit_candidates too)');
select is((select array_agg(f.sig::text order by f.sig::text) from _fn f join pg_proc p on p.oid = f.sig
           where exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)), null,
  'none is executable by PUBLIC');
select is((select array_agg(f.sig::text order by f.sig::text) from _fn f join pg_proc p on p.oid = f.sig
           where exists (select 1 from aclexplode(p.proacl) a
                         where a.grantee <> p.proowner and a.privilege_type = 'EXECUTE' and a.is_grantable)), null,
  'no grant option given to anyone');
-- the result types are those of the functions they replace (same signature, same columns)
select is(pg_get_function_result('private.payment_positions(uuid[])'::regprocedure),
  'TABLE(payment_id uuid, amount_minor bigint, allocated_minor bigint, returned_minor bigint, unallocated_minor bigint)',
  'payment_positions returns the same columns');
select is(array[pg_get_function_result('private.bank_import_entry_known(uuid)'::regprocedure),
                pg_get_function_result('private.bank_import_lines_elsewhere(uuid, uuid)'::regprocedure),
                pg_get_function_result('private.receipt_payload(uuid)'::regprocedure),
                pg_get_function_result('public.unassign_payment(text, uuid, text)'::regprocedure),
                pg_get_function_result('public.payment_detail(uuid)'::regprocedure),
                pg_get_function_result('private.debit_candidates(uuid, date, uuid, integer)'::regprocedure)],
  array['integer', 'TABLE(line_no integer, dedup_key text)', 'TABLE(recipient_party_id uuid, payload jsonb)', 'jsonb',
        'jsonb',
        'TABLE(line_id uuid, line_kind text, direction text, bank_account_id uuid, amount_minor bigint, '
        'booking_date date, payment_id uuid, refund_request_id uuid, via text, cand_bank_account_id uuid, '
        'cand_amount_minor bigint, cand_left_minor bigint, cand_unallocated_minor bigint, cand_pending_minor bigint, '
        'cand_status text, cand_date date, cand_payment_status text, cand_free_from date)'],
  'and so do the others');

-- Statement-import lookups in the states that made them slow ------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-0000000000fa', 'servicer', 'Plan robustness'),
  ('00000000-0000-0000-0000-0000000000fb', 'servicer', 'Other servicer');
insert into public.bank_account (id, organization_id, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000fa', 'FR3430001007940000000001001', 'EUR',
   'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000fa', 'FR7030001007940000000002002', 'EUR',
   'Fonds de tiers 2', 'csv', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000fa', 'FR7652911690573468086161054', 'EUR',
   'Fonds de tiers 3', 'csv', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000000fb', 'FR7658954489556714560695353', 'EUR',
   'Autre servicer', 'csv', '2026-01-01');
insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                   size_bytes, storage_path)
select ('a0000000-0000-0000-0000-0000000000f' || n)::uuid, b.organization_id, b.id, 'EUR',
       case when n = 1 then 'camt053' else 'csv' end, 'releve-' || n, repeat(n::text, 64), 1, 'test/robust-' || n
from generate_series(1, 4) n join public.bank_account b on b.id = ('80000000-0000-0000-0000-0000000000f' || n)::uuid;
update public.bank_statement set status = 'uploaded', uploaded_at = now()
where organization_id in ('00000000-0000-0000-0000-0000000000fa', '00000000-0000-0000-0000-0000000000fb');
-- Account 1: 6000 lines booked as 3 bank entries (batch bookings: an SDD collection run, a camt Ntry with TxDtls).
-- Accounts 2 and 3 (same servicer) and 4 (another servicer): 2000, 1000 and 2000 lines keyed h:K<n>#1, 1 € + n cents,
-- 10 March.
insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind, entry_ref)
select '00000000-0000-0000-0000-0000000000fa', '80000000-0000-0000-0000-0000000000f1',
       'a0000000-0000-0000-0000-0000000000f1', g, 'e:N' || g % 3 || '#' || g, 'credit', 100 + g, 'EUR', '2026-03-10',
       'debtor_credit', 'N' || g % 3
from generate_series(1, 6000) g;
insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind)
select b.organization_id, b.id, ('a0000000-0000-0000-0000-0000000000f' || n)::uuid, g, 'h:K' || g || '#1', 'credit',
       100 + g, 'EUR', '2026-03-10', 'debtor_credit'
from generate_series(2, 4) n join public.bank_account b on b.id = ('80000000-0000-0000-0000-0000000000f' || n)::uuid
cross join generate_series(1, 2000) g
where n <> 3 or g <= 1000;
-- The state right after an import: analysed (in this transaction), pages not all-visible yet (no vacuum).
analyze public.bank_transaction;
select ok((select s.n_distinct between 1 and 3 from pg_stats s
           where s.schemaname = 'public' and s.tablename = 'bank_transaction' and s.attname = 'entry_ref')
          and (select c.relallvisible = 0 and c.reltuples >= 11000 from pg_class c
               where c.oid = 'public.bank_transaction'::regclass),
  'the statistics know the lines: few distinct bank entries, no page all-visible');

-- what this transaction has read of bank_transaction since the last mark
create temp table _mark (seq_scan bigint, seq_tup_read bigint, idx_scan bigint);
create function pg_temp.mark() returns void language sql as $$
  delete from _mark;
  insert into _mark select x.seq_scan, x.seq_tup_read, x.idx_scan from pg_stat_xact_user_tables x
  where x.relid = 'public.bank_transaction'::regclass;
$$;
create function pg_temp.read_since_mark() returns table (seq_scan bigint, seq_tup_read bigint, idx_scan bigint)
language sql as $$
  select x.seq_scan - m.seq_scan, x.seq_tup_read - m.seq_tup_read, x.idx_scan - m.idx_scan
  from pg_stat_xact_user_tables x, _mark m where x.relid = 'public.bank_transaction'::regclass;
$$;

-- An import's new lines (the pg_temp._bi_new of private.ingest_statement, analysed as it is there).
create temp table _bi_new (line_no integer primary key, dedup_key text not null, entry_ref text, direction text not null,
                           amount_minor bigint not null, booking_date date not null);

-- bank_import_entry_known: 300 new bank entries, one entry account 1 has already, one line without an entry reference.
insert into pg_temp._bi_new
select g, 'e:M' || g || '#1', 'M' || g, 'credit', 100, '2026-03-11' from generate_series(1, 300) g;
insert into pg_temp._bi_new values (301, 'e:N1#9999', 'N1', 'credit', 1, '2026-03-10'),
                                   (302, 't:no-entry', null, 'credit', 1, '2026-03-10');
analyze pg_temp._bi_new;
select pg_temp.mark();
select is(private.bank_import_entry_known('80000000-0000-0000-0000-0000000000f1'), 301,
  'entry known: the line of an entry the account has already');
-- 55b594b's body (lateral LIMIT 1 without enable_seqscan = off) seq-scanned the account's lines once per new line
-- here: 301 seq scans, 1.8M rows read (4.2 s for 500 lines on a 50k-line account; 17 min for a 50k import).
select is((select array[r.seq_scan, r.seq_tup_read] from pg_temp.read_since_mark() r), array[0, 0]::bigint[],
  'and no line of the account is read by a seq scan, whatever few entries its lines share');
select ok((select r.idx_scan <= 301 from pg_temp.read_since_mark() r),
  'one index probe at most per new line with an entry reference');
select is(private.bank_import_entry_known('80000000-0000-0000-0000-0000000000f2'), null,
  'another account: none of those entries is known there');

-- bank_import_lines_elsewhere (a CSV import on account 1): lines 1..1500 and 1801..2000 have the key, day, amount and
-- direction of a line of account 2, lines 1..1000 of account 3 too; 1501..1600 another amount, 1601..1700 a debit,
-- 1701..1800 another day; 2001..2500 keys of account 4 only (another servicer) or of none.
truncate pg_temp._bi_new;
insert into pg_temp._bi_new
select g, 'h:K' || g || '#1', null,
       case when g between 1601 and 1700 then 'debit' else 'credit' end,
       case when g between 1501 and 1600 then 1 else 100 + g end,
       case when g between 1701 and 1800 then date '2026-03-11' else date '2026-03-10' end
from generate_series(1, 2500) g;
analyze pg_temp._bi_new;
select pg_temp.mark();
create temp table _found as
select * from private.bank_import_lines_elsewhere('00000000-0000-0000-0000-0000000000fa',
                                                  '80000000-0000-0000-0000-0000000000f1');
select ok((select r.seq_scan + r.idx_scan <= 4 from pg_temp.read_since_mark() r),
  'lines elsewhere: the stored lines are read in one pass, not once per new line (55b594b: 5000 index probes here)');
select is((select array[count(*), count(distinct line_no), count(*) filter (where line_no <= 1000)] from _found),
  array[2700, 1700, 2000]::bigint[], 'one row per line found on each other account (2 for a line on both)');
select is((select array_agg(distinct line_no order by line_no) from _found where line_no > 1500),
  array(select g from generate_series(1801, 2000) g), 'none with another amount, direction or day, or elsewhere only');
select is((select count(*)::int from _found f join pg_temp._bi_new x using (line_no) where f.dedup_key <> x.dedup_key), 0,
  'each with its key');
-- the same rows, with multiplicity, as the join of 20261109120000
select is((select count(*)::int from (
             (select * from _found
              except all
              select x.line_no, x.dedup_key from pg_temp._bi_new x
              join public.bank_account o on o.organization_id = '00000000-0000-0000-0000-0000000000fa'
                and o.id <> '80000000-0000-0000-0000-0000000000f1'
              join public.bank_transaction t on t.bank_account_id = o.id and t.dedup_key = x.dedup_key
              where (t.direction, t.amount_minor, t.booking_date) = (x.direction, x.amount_minor, x.booking_date))
             union all
             (select x.line_no, x.dedup_key from pg_temp._bi_new x
              join public.bank_account o on o.organization_id = '00000000-0000-0000-0000-0000000000fa'
                and o.id <> '80000000-0000-0000-0000-0000000000f1'
              join public.bank_transaction t on t.bank_account_id = o.id and t.dedup_key = x.dedup_key
              where (t.direction, t.amount_minor, t.booking_date) = (x.direction, x.amount_minor, x.booking_date)
              except all
              select * from _found)) d), 0,
  'the rows of the join it replaced, with multiplicity');
select is((select count(*)::int from private.bank_import_lines_elsewhere('00000000-0000-0000-0000-0000000000fb',
                                                                         '80000000-0000-0000-0000-0000000000f4')), 0,
  'a servicer with one bank account: nothing elsewhere');

select * from finish();
rollback;
