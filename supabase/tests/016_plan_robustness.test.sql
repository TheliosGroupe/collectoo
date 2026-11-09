-- 20261110130000 plan robustness: the redefined functions keep their owner, privileges, settings and kind; only
-- their plans change (their results are checked where their fixtures are: 011 imports, 012 and 013 unassign and
-- positions, 014 receipt payloads and golden hashes).
begin;
select plan(9);

create temp table _fn (sig regprocedure primary key, config text[], secdef boolean, volatility "char",
                       grantees text[]);
insert into _fn values
  ('private.bank_import_entry_known(uuid)',
   array['search_path=""', 'enable_hashjoin=off', 'enable_mergejoin=off', 'enable_bitmapscan=off'], false, 's', '{}'),
  ('private.bank_import_lines_elsewhere(uuid, uuid)',
   array['search_path=""', 'enable_hashjoin=off', 'enable_mergejoin=off', 'enable_bitmapscan=off'], false, 's', '{}'),
  ('private.payment_positions(uuid[])', array['search_path=""', 'enable_seqscan=off'], false, 's',
   array['service_role']),
  ('private.receipt_payload(uuid)', array['search_path=""', 'enable_hashjoin=off', 'enable_mergejoin=off'], false,
   's', '{}'),
  ('public.unassign_payment(text, uuid, text)', array['search_path=""', 'lock_timeout=2s'], true, 'v',
   array['authenticated', 'service_role']);

select is((select count(*)::int from _fn f join pg_proc p on p.oid = f.sig), 5, 'the five redefined functions exist');
select is((select array_agg(f.sig::text order by f.sig::text) from _fn f join pg_proc p on p.oid = f.sig
           where pg_get_userbyid(p.proowner) <> 'postgres'), null, 'they are still owned by postgres');
select is((select array_agg(f.sig::text order by f.sig::text) from _fn f join pg_proc p on p.oid = f.sig
           where p.proconfig is distinct from f.config), null,
  'each keeps the SET clauses it had (payment_positions adds enable_seqscan = off)');
select is((select array_agg(f.sig::text order by f.sig::text) from _fn f join pg_proc p on p.oid = f.sig
           where p.prosecdef <> f.secdef or p.provolatile <> f.volatility), null,
  'and its security (definer or invoker) and volatility');
select is((select array_agg(f.sig::text || ' ' || r.rolname order by f.sig::text, r.rolname)
           from _fn f cross join pg_roles r
           where r.rolname in ('anon', 'authenticated', 'service_role')
             and has_function_privilege(r.rolname, f.sig, 'execute') <> (r.rolname = any (f.grantees))), null,
  'who may execute each is unchanged (anon never; authenticated: unassign_payment; service_role: payment_positions)');
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
                pg_get_function_result('public.unassign_payment(text, uuid, text)'::regprocedure)],
  array['integer', 'TABLE(line_no integer, dedup_key text)', 'TABLE(recipient_party_id uuid, payload jsonb)', 'jsonb'],
  'and so do the others');

select * from finish();
rollback;
