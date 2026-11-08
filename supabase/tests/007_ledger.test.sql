-- Ledger (M2-01, M2-02): deferred balance check, guards, append-only even for the owner, post/reverse.
-- pgTAP never commits: "fails at commit" is shown with SET CONSTRAINTS ... IMMEDIATE inside a DO block
-- (throws_ok rolls the block back, so a failing entry leaves no pending check behind).
begin;
select plan(57);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client B');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'PA'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'PB');
insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                            legal_regime, currency, status) values
  ('30000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   '20000000-0000-0000-0000-0000000000a1', 'b2b_invoice', 'C-1', 'commercial_b2b', 'EUR', 'awaiting_first_letter'),
  ('30000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2',
   '20000000-0000-0000-0000-0000000000a2', 'b2b_invoice', 'C-2', 'commercial_b2b', 'EUR', 'awaiting_first_letter'),
  ('30000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   '20000000-0000-0000-0000-0000000000a1', 'b2b_invoice', 'C-3', 'commercial_b2b', 'EUR', 'staged');
insert into public.claim_item (id, account_id, kind, ref, original_minor) values
  ('40000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'invoice', 'F-1', 125000),
  ('40000000-0000-0000-0000-0000000000a2', '30000000-0000-0000-0000-0000000000a1', 'invoice', 'F-2', 50000),
  ('40000000-0000-0000-0000-0000000000b1', '30000000-0000-0000-0000-0000000000a2', 'invoice', 'G-1', 9000),
  ('40000000-0000-0000-0000-0000000000c1', '30000000-0000-0000-0000-0000000000a3', 'invoice', 'H-1', 7000);
insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type, valid_from)
select id, case when id = '30000000-0000-0000-0000-0000000000a1' then '00000000-0000-0000-0000-0000000000a2'::uuid
                else client_organization_id end,
       organization_id, 'mandate_amicable', '2026-01-01' from public.account
where id in ('30000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a2', '30000000-0000-0000-0000-0000000000a3');

-- Ledger accounts used by the raw-SQL tests (the definer functions create their own).
insert into public.ledger_account (id, organization_id, book, currency, client_organization_id, portfolio_id,
                                   account_id, claim_item_id, component) values
  ('50000000-0000-0000-0000-000000001100', '00000000-0000-0000-0000-00000000000a', 'debtor_receivable', 'EUR',
   '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1',
   '30000000-0000-0000-0000-0000000000a1', '40000000-0000-0000-0000-0000000000a1', 'principal');
insert into public.ledger_account (id, organization_id, book, currency, client_organization_id, owner_organization_id,
                                   portfolio_id, component) values
  ('50000000-0000-0000-0000-000000003100', '00000000-0000-0000-0000-00000000000a', 'owner_claim', 'EUR',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1',
   '20000000-0000-0000-0000-0000000000a1', 'principal');
insert into public.ledger_account (id, organization_id, book, currency, client_organization_id) values
  ('50000000-0000-0000-0000-000000004670', '00000000-0000-0000-0000-00000000000a', 'client_payable', 'USD',
   '00000000-0000-0000-0000-0000000000a1'),
  ('50000000-0000-0000-0000-000000004671', '00000000-0000-0000-0000-00000000000a', 'client_payable', 'EUR',
   '00000000-0000-0000-0000-0000000000a1'),
  ('50000000-0000-0000-0000-000000004672', '00000000-0000-0000-0000-00000000000a', 'client_payable', 'EUR',
   '00000000-0000-0000-0000-0000000000a2'),
  ('50000000-0000-0000-0000-000000007060', '00000000-0000-0000-0000-00000000000a', 'servicer_revenue', 'EUR',
   '00000000-0000-0000-0000-0000000000a1');
insert into public.ledger_account (id, organization_id, book, currency) values
  ('50000000-0000-0000-0000-000000004710', '00000000-0000-0000-0000-00000000000a', 'unallocated_payment', 'EUR');

create temporary table t (k text primary key, v uuid) on commit drop;

-- M2-01: structure ----------------------------------------------------------------------------------
select col_type_is('public', 'ledger_posting', 'amount_minor', 'bigint', 'amounts are bigint minor units');
select col_type_is('public', 'ledger_posting', 'currency', 'character(3)', 'every line carries its currency');
select is((select tgdeferrable and tginitdeferred from pg_trigger where tgname = 'ledger_entry_balanced'), true,
  'the balance check is deferred to commit');
select is((select count(*)::int from pg_trigger
           where tgrelid in ('public.ledger_account'::regclass, 'public.ledger_entry'::regclass, 'public.ledger_posting'::regclass)
             and not tgisinternal and tgenabled <> 'A'), 0,
  'every ledger trigger fires ALWAYS (also for the owner and in replica mode)');
select is(current_user::text, (select tableowner::text from pg_tables where tablename = 'ledger_posting'),
  'these tests run as the table owner (the worker''s login role)');

-- M2-01: balance at commit ----------------------------------------------------------------------------
select lives_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, reason)
  values ('60000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          '20000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'adjustment', '2026-03-01', 2,
          'raw-balanced-0001', repeat('0', 64), 'test');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000001', 1, '50000000-0000-0000-0000-000000001100', 100, 'EUR', '2026-03-01'),
    ('60000000-0000-0000-0000-000000000001', 2, '50000000-0000-0000-0000-000000003100', -100, 'EUR', '2026-03-01');
  set constraints public.ledger_entry_balanced immediate;
  set constraints public.ledger_entry_balanced deferred;
end $d$ $$, 'a balanced entry passes the commit-time check');

select throws_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, reason)
  values ('60000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          '20000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'adjustment', '2026-03-01', 2,
          'raw-unbalanced-01', repeat('0', 64), 'test');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000002', 1, '50000000-0000-0000-0000-000000001100', 100, 'EUR', '2026-03-01'),
    ('60000000-0000-0000-0000-000000000002', 2, '50000000-0000-0000-0000-000000003100', -99, 'EUR', '2026-03-01');
  set constraints public.ledger_entry_balanced immediate;
end $d$ $$, 'LG001', null, 'an unbalanced entry fails at commit');

select throws_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, entry_type, effective_date, line_count,
                                   idempotency_key, request_hash, reason)
  values ('60000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          'adjustment', '2026-03-01', 2, 'raw-currencies-1', repeat('0', 64), 'test');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000003', 1, '50000000-0000-0000-0000-000000004710', 100, 'EUR', '2026-03-01'),
    ('60000000-0000-0000-0000-000000000003', 2, '50000000-0000-0000-0000-000000004670', -100, 'USD', '2026-03-01');
  set constraints public.ledger_entry_balanced immediate;
end $d$ $$, 'LG001', null, 'balanced in total but not per currency fails');

select throws_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, reason)
  values ('60000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          '20000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'adjustment', '2026-03-01', 3,
          'raw-incomplete-1', repeat('0', 64), 'test');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000004', 1, '50000000-0000-0000-0000-000000001100', 100, 'EUR', '2026-03-01'),
    ('60000000-0000-0000-0000-000000000004', 2, '50000000-0000-0000-0000-000000003100', -100, 'EUR', '2026-03-01');
  set constraints public.ledger_entry_balanced immediate;
end $d$ $$, 'LG001', null, 'an entry with fewer lines than announced fails');

select throws_ok($$ insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000001', 2, '50000000-0000-0000-0000-000000003100', -1, 'EUR', '2026-03-01') $$,
  '23505', null, 'a closed entry cannot take another line (every slot is taken)');
select throws_ok($$ insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000001', 3, '50000000-0000-0000-0000-000000003100', -1, 'EUR', '2026-03-01') $$,
  'LG002', null, 'nor a line beyond its line count');

select throws_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, reason)
  values ('60000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          '20000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'adjustment', '2026-03-01', 2,
          'raw-zero-amount', repeat('0', 64), 'test');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000005', 1, '50000000-0000-0000-0000-000000001100', 0, 'EUR', '2026-03-01');
end $d$ $$, '23514', null, 'a zero amount is refused');

select throws_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, reason)
  values ('60000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          '20000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'adjustment', '2026-03-01', 2,
          'raw-currency-xx', repeat('0', 64), 'test');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000006', 1, '50000000-0000-0000-0000-000000001100', 100, 'USD', '2026-03-01');
end $d$ $$, 'LG002', null, 'a line in another currency than its ledger account is refused');

select throws_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, reason)
  values ('60000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          '20000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'adjustment', '2026-03-01', 2,
          'raw-date-differs', repeat('0', 64), 'test');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000007', 1, '50000000-0000-0000-0000-000000001100', 100, 'EUR', '2026-03-02');
end $d$ $$, 'LG002', null, 'a line dated differently from its entry is refused');

select throws_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, entry_type, effective_date, line_count,
                                   idempotency_key, request_hash, reason)
  values ('60000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          'adjustment', '2026-03-01', 2, 'raw-other-client', repeat('0', 64), 'test');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000008', 1, '50000000-0000-0000-0000-000000004710', 100, 'EUR', '2026-03-01'),
    ('60000000-0000-0000-0000-000000000008', 2, '50000000-0000-0000-0000-000000004672', -100, 'EUR', '2026-03-01');
end $d$ $$, 'LG002', null, 'an entry of client A cannot touch a ledger account of client B');

select throws_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, reason)
  values ('60000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          '20000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'adjustment', '2026-03-01', 2,
          'raw-mirror-broken', repeat('0', 64), 'test');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000009', 1, '50000000-0000-0000-0000-000000001100', 100, 'EUR', '2026-03-01'),
    ('60000000-0000-0000-0000-000000000009', 2, '50000000-0000-0000-0000-000000004671', -100, 'EUR', '2026-03-01');
  set constraints public.ledger_entry_balanced immediate;
end $d$ $$, 'LG001', null, 'the receivable cannot move without the owner claim (mirror)');

select throws_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, entry_type, effective_date, line_count,
                                   idempotency_key, request_hash, reason)
  values ('60000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          'adjustment', '2026-03-01', 2, 'raw-revenue-book', repeat('0', 64), 'test');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000010', 1, '50000000-0000-0000-0000-000000004671', 100, 'EUR', '2026-03-01'),
    ('60000000-0000-0000-0000-000000000010', 2, '50000000-0000-0000-0000-000000007060', -100, 'EUR', '2026-03-01');
end $d$ $$, 'LG002', null, 'an adjustment cannot touch commission revenue (book not allowed)');

select throws_ok($$ insert into public.ledger_account (organization_id, book, currency, client_organization_id, portfolio_id,
                                                         account_id, component)
  values ('00000000-0000-0000-0000-00000000000a', 'debtor_receivable', 'EUR', '00000000-0000-0000-0000-0000000000a1',
          '20000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'principal') $$,
  '23514', null, 'a receivable ledger account names its claim item');
select throws_ok($$ insert into public.ledger_account (organization_id, book, currency)
  values ('00000000-0000-0000-0000-00000000000a', 'client_money_cash', 'EUR') $$,
  '23514', null, 'books not seeded yet are refused (fail closed)');
select throws_ok($$ insert into public.ledger_account (organization_id, book, currency, client_organization_id, portfolio_id,
                                                         account_id, claim_item_id, component)
  values ('00000000-0000-0000-0000-00000000000a', 'debtor_receivable', 'USD', '00000000-0000-0000-0000-0000000000a1',
          '20000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1',
          '40000000-0000-0000-0000-0000000000a2', 'principal') $$,
  '23503', null, 'a receivable ledger account has its account''s currency');

-- M2-02: append-only, even for the owner -----------------------------------------------------------
select throws_ok($$ update public.ledger_entry set reason = 'edited' $$, 'LG000', null, 'entries cannot be updated');
select throws_ok($$ update public.ledger_posting set amount_minor = 1 $$, 'LG000', null, 'lines cannot be updated');
select throws_ok($$ update public.ledger_account set component = 'principal' $$, 'LG000', null, 'ledger accounts cannot be updated');
select throws_ok($$ delete from public.ledger_posting $$, '42501', null, 'the owner has no DELETE on lines');
select is(has_table_privilege('postgres', 'public.ledger_posting', 'DELETE'), false, 'DELETE is revoked from the owner');
grant delete, truncate on public.ledger_entry, public.ledger_posting to postgres;
select throws_ok($$ delete from public.ledger_posting $$, 'LG000', null, 'and the trigger refuses it even when granted');
select throws_ok($$ truncate public.ledger_entry cascade $$, 'LG000', null, 'TRUNCATE is refused');
revoke delete, truncate on public.ledger_entry, public.ledger_posting from postgres;
select throws_ok($$ insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000001', 1, '50000000-0000-0000-0000-000000001100', 100, 'EUR', '2026-03-01')
  on conflict (entry_id, line_no) do update set amount_minor = 7 $$, 'LG000', null, 'upserts cannot rewrite a line');
select throws_ok($$ delete from public.ledger_book where code = 'servicer_revenue' $$, 'LG000', null,
  'chart of accounts keys cannot be deleted');
select lives_ok($$ update public.ledger_book set label_fr = 'Commissions perçues' where code = 'servicer_revenue' $$,
  'labels may be updated');
select skip('session_replication_role cannot be set by this role (managed Postgres); ALWAYS triggers are checked above', 1)
  where not has_parameter_privilege('session_replication_role', 'SET');

create or replace function pg_temp.write_attempts() returns setof text language sql as $$
  values ($q$insert into public.ledger_entry (organization_id, entry_type, effective_date, line_count, idempotency_key, request_hash, reason)
           values ('00000000-0000-0000-0000-00000000000a', 'adjustment', '2026-03-01', 2, 'direct-write-01', repeat('0', 64), 'x')$q$),
         ($q$insert into public.ledger_posting values ('60000000-0000-0000-0000-000000000001', 9, '50000000-0000-0000-0000-000000001100', 1, 'EUR', '2026-03-01')$q$),
         ($q$insert into public.ledger_account (organization_id, book, currency) values ('00000000-0000-0000-0000-00000000000a', 'unallocated_payment', 'USD')$q$),
         ($q$update public.ledger_entry set reason = 'x'$q$), ($q$update public.ledger_posting set amount_minor = 1$q$),
         ($q$update public.ledger_account set currency = 'USD'$q$), ($q$delete from public.ledger_entry$q$),
         ($q$delete from public.ledger_posting$q$), ($q$delete from public.ledger_account$q$);
$$;
create or replace function pg_temp.refused_writes() returns integer language plpgsql as $$
declare q text; n integer := 0;
begin
  for q in select * from pg_temp.write_attempts() loop
    begin execute q; exception when insufficient_privilege then n := n + 1; end;
  end loop;
  return n;
end $$;
set local role service_role;
select is(pg_temp.refused_writes(), 9, 'service_role cannot insert, update or delete any ledger table');
reset role;
set local role authenticated;
select is(pg_temp.refused_writes(), 9, 'signed-in users cannot insert, update or delete any ledger table');
reset role;

-- private.ledger_post ---------------------------------------------------------------------------------
insert into t select 'p1', entry_id from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', '2026-04-01',
  'adjust-0001-key',
  '[{"book": "debtor_receivable", "amount_minor": 5000, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000a2", "component": "principal"},
    {"book": "owner_claim", "amount_minor": -5000, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "reason": "seller correction"}');
select is((select line_count from public.ledger_entry where id = (select v from t where k = 'p1')), 2, 'ledger_post writes the entry');
select is(
  (select owner_organization_id from public.ledger_account la join public.ledger_posting p on p.ledger_account_id = la.id
   where p.entry_id = (select v from t where k = 'p1') and la.book = 'owner_claim'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'the owner comes from the ownership history (here not the client)');
select is(
  (select array[entry_id::text, created::text] from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment',
     '2026-04-01', 'adjust-0001-key',
     '[{"book": "owner_claim", "amount_minor": -5000, "currency": "EUR", "component": "principal"},
       {"book": "debtor_receivable", "amount_minor": 5000, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000a2", "component": "principal"}]',
     '{"account_id": "30000000-0000-0000-0000-0000000000a1", "reason": "seller correction"}')),
  array[(select v::text from t where k = 'p1'), 'false'],
  'the same key and request (lines in any order) returns the same entry');
select throws_ok($$ select * from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', '2026-04-01',
  'adjust-0001-key',
  '[{"book": "debtor_receivable", "amount_minor": 6000, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000a2", "component": "principal"},
    {"book": "owner_claim", "amount_minor": -6000, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "reason": "seller correction"}') $$,
  'LG004', null, 'the same key with another request is refused');
select throws_ok($$ select * from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'opening', '2026-04-01',
  'opening-by-hand', '[]', '{}') $$, 'LG006', null, 'openings are only posted by the boarding confirmation');
select throws_ok($$ select * from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', '2026-04-01',
  'float-amount-01',
  '[{"book": "debtor_receivable", "amount_minor": 1.0, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000a2", "component": "principal"},
    {"book": "owner_claim", "amount_minor": -1, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "reason": "x"}') $$,
  'LG006', null, 'amounts must be JSON integers (no 1.0)');
select throws_ok($$ select * from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', '2026-04-01',
  'staged-account-1',
  '[{"book": "debtor_receivable", "amount_minor": 100, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000c1", "component": "principal"},
    {"book": "owner_claim", "amount_minor": -100, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a3", "reason": "x"}') $$,
  'LG006', null, 'no posting on an account that is not confirmed yet');
select throws_ok(format($$ select * from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', %L,
  'future-date-0001',
  '[{"book": "debtor_receivable", "amount_minor": 100, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000a2", "component": "principal"},
    {"book": "owner_claim", "amount_minor": -100, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "reason": "x"}') $$, private.paris_today() + 1),
  'LG006', null, 'no posting in the future (Paris date)');
select throws_ok($$ select * from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', '2026-04-01',
  'item-other-acct',
  '[{"book": "debtor_receivable", "amount_minor": 100, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000b1", "component": "principal"},
    {"book": "owner_claim", "amount_minor": -100, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "reason": "x"}') $$,
  'LG002', null, 'a claim line names an item of the entry''s account');
select throws_ok($$ select * from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', '2026-04-01',
  'no-reason-given',
  '[{"book": "debtor_receivable", "amount_minor": 100, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000a2", "component": "principal"},
    {"book": "owner_claim", "amount_minor": -100, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1"}') $$,
  'LG006', null, 'an adjustment needs a reason');

-- private.ledger_reverse ------------------------------------------------------------------------------
insert into t select 'r1', entry_id from private.ledger_reverse((select v from t where k = 'p1'), 'reverse-0001-key', 'duplicate');
select is(
  (select count(*)::int from public.ledger_posting r join public.ledger_posting o using (line_no, ledger_account_id)
   where r.entry_id = (select v from t where k = 'r1') and o.entry_id = (select v from t where k = 'p1')
     and r.amount_minor = -o.amount_minor),
  2, 'a reversal negates every line on the same ledger accounts');
select is((select reverses_entry_id from public.ledger_entry where id = (select v from t where k = 'r1')),
  (select v from t where k = 'p1'), 'and points to the reversed entry');
select is((select sum(amount_minor)::int from public.ledger_posting
           where entry_id in ((select v from t where k = 'p1'), (select v from t where k = 'r1'))
             and ledger_account_id in (select id from public.ledger_account where claim_item_id = '40000000-0000-0000-0000-0000000000a2')),
  0, 'the pair nets to zero');
select is((select array[entry_id::text, created::text] from private.ledger_reverse((select v from t where k = 'p1'), 'reverse-0001-key', 'duplicate')),
  array[(select v::text from t where k = 'r1'), 'false'], 'the same reversal request returns the same reversal');
select throws_ok(format($$ select * from private.ledger_reverse(%L, 'reverse-0001-key', 'another reason') $$, (select v from t where k = 'p1')),
  'LG004', null, 'the same reversal key with another request is refused');
select throws_ok(format($$ select * from private.ledger_reverse(%L, 'reverse-0002-key', 'again') $$, (select v from t where k = 'p1')),
  'LG003', null, 'an entry is reversed once');
select throws_ok(format($$ select * from private.ledger_reverse(%L, 'reverse-0003-key', 'undo') $$, (select v from t where k = 'r1')),
  'LG003', null, 'a reversal is not reversed (post a new entry)');
insert into t select 'p2', entry_id from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', '2026-04-10',
  'adjust-0002-key',
  '[{"book": "debtor_receivable", "amount_minor": 700, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000a1", "component": "principal"},
    {"book": "owner_claim", "amount_minor": -700, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "reason": "late fee waived back"}');
select throws_ok(format($$ select * from private.ledger_reverse(%L, 'reverse-0004-key', 'x', '2026-04-09') $$, (select v from t where k = 'p2')),
  'LG003', null, 'a reversal is not dated before the entry it reverses');
select throws_ok(format($$ select * from private.ledger_reverse(%L, 'reverse-0005-key', ' ') $$, (select v from t where k = 'p2')),
  'LG006', null, 'a reversal needs a reason');
select throws_ok(format($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, reverses_entry_id, reason)
  values ('60000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          '20000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'reversal', '2026-04-10', 2,
          'raw-bad-reversal', repeat('0', 64), %L, 'x');
  insert into public.ledger_posting select '60000000-0000-0000-0000-000000000011', line_no, ledger_account_id,
    -amount_minor * 2, currency, effective_date from public.ledger_posting where entry_id = %L;
  set constraints public.ledger_entry_balanced immediate;
end $d$ $$, (select v from t where k = 'p2'), (select v from t where k = 'p2')),
  'LG003', null, 'a hand-made reversal that does not mirror its entry fails at commit');

-- A caller's temp table under the function's working name is dropped, never used (its triggers
-- would run with the definer's rights).
drop table if exists pg_temp._ledger_lines;  -- left by an earlier call in this transaction
create temp table _ledger_lines (line_no integer, book text, amount_minor bigint, currency char(3), claim_item_id uuid,
  component text, client_organization_id uuid, owner_organization_id uuid, portfolio_id uuid, ledger_account_id uuid);
create temp table hijack_log (n integer);
create or replace function pg_temp.hijack() returns trigger language plpgsql as $$
begin insert into pg_temp.hijack_log values (1); return null; end $$;
create trigger hijack after insert on pg_temp._ledger_lines for each statement execute function pg_temp.hijack();
do $$ begin
  perform private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', '2026-04-02', 'hijack-attempt-1',
    '[{"book": "unallocated_payment", "amount_minor": 100, "currency": "EUR"},
      {"book": "client_payable", "amount_minor": -100, "currency": "EUR", "client_organization_id": "00000000-0000-0000-0000-0000000000a1"}]',
    '{"reason": "test"}');
end $$;
select is((select count(*)::int from pg_temp.hijack_log), 0, 'ledger_post never runs triggers of a caller''s temp table');

-- Catalog -------------------------------------------------------------------------------------------
select is(
  (select bool_and(p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.proname in ('ledger_post', 'ledger_reverse')),
  true, 'the write functions are SECURITY DEFINER with a pinned search_path');
select is(
  array[has_function_privilege('service_role', 'private.ledger_post(uuid, text, date, text, jsonb, jsonb)', 'execute'),
        has_function_privilege('authenticated', 'private.ledger_post(uuid, text, date, text, jsonb, jsonb)', 'execute'),
        has_function_privilege('anon', 'private.ledger_reverse(uuid, text, text, date)', 'execute')],
  array[true, false, false], 'only the worker (service_role) may post or reverse');
select lives_ok($$ set constraints all immediate $$, 'every entry written in this test is balanced');

select * from finish();
rollback;
