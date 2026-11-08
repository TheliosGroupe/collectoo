-- Ledger balances and read access (M2-03): balance at D = sum of postings with effective_date <= D.
begin;
select plan(21);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client B');
insert into auth.users (id, email, aud, role) values
  ('10000000-0000-0000-0000-000000000001', 'ops@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000002', 'collector@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000003', 'admin@a.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000005', 'admin@b.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000a2', 'client_admin');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'PA'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'PB');
-- The collector is restricted to client B's portfolio.
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a2');
insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                            legal_regime, currency, status) values
  ('30000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   '20000000-0000-0000-0000-0000000000a1', 'b2b_invoice', 'C-1', 'commercial_b2b', 'EUR', 'awaiting_first_letter'),
  ('30000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2',
   '20000000-0000-0000-0000-0000000000a2', 'b2b_invoice', 'C-2', 'commercial_b2b', 'EUR', 'awaiting_first_letter');
insert into public.claim_item (id, account_id, kind, ref, original_minor) values
  ('40000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a1', 'invoice', 'F-1', 125000),
  ('40000000-0000-0000-0000-0000000000b1', '30000000-0000-0000-0000-0000000000a2', 'invoice', 'G-1', 9000);
insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type, valid_from)
select id, client_organization_id, organization_id, 'mandate_amicable', '2026-01-01' from public.account
where id in ('30000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a2');

create temporary table t (k text primary key, v uuid, at timestamptz) on commit drop;
grant all on t to authenticated;

create or replace function pg_temp.claim(p_account uuid, p_item uuid, p_amount bigint, p_date date, p_key text)
returns uuid language sql as $$
  select entry_id from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', p_date, p_key,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', p_item, 'component', 'principal'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', 'principal')),
    jsonb_build_object('account_id', p_account, 'reason', 'test'));
$$;

-- D1 = 2026-02-01 +1000, D2 = 2026-03-01 +250, D3 = 2026-04-01 -400; the D2 entry is reversed on D2.
insert into t (k, v) values ('d1', pg_temp.claim('30000000-0000-0000-0000-0000000000a1', '40000000-0000-0000-0000-0000000000a1', 1000, '2026-02-01', 'balance-d1-key'));
insert into t (k, v) values ('d2', pg_temp.claim('30000000-0000-0000-0000-0000000000a1', '40000000-0000-0000-0000-0000000000a1', 250, '2026-03-01', 'balance-d2-key'));
insert into t (k, v) values ('d3', pg_temp.claim('30000000-0000-0000-0000-0000000000a1', '40000000-0000-0000-0000-0000000000a1', -400, '2026-04-01', 'balance-d3-key'));
insert into t (k, v) select 'r2', entry_id from private.ledger_reverse((select v from t where k = 'd2'), 'balance-r2-key', 'double entry');
insert into t (k, v) values ('b1', pg_temp.claim('30000000-0000-0000-0000-0000000000a2', '40000000-0000-0000-0000-0000000000b1', 9000, '2026-02-01', 'balance-b1-key'));
-- known_at (books as known at a time) needs entries posted in different transactions: tested in
-- worker/tests/test_ledger_integration.py.

-- M2-03 acceptance: every date, every ledger account ------------------------------------------------
select is(
  (select count(*)::int
   from generate_series('2026-01-31'::date, '2026-04-02'::date, '1 day') d,
        public.ledger_account la
   where la.organization_id = '00000000-0000-0000-0000-00000000000a'
     and private.ledger_balance(la.id, d::date) <>
         (select coalesce(sum(p.amount_minor), 0) from public.ledger_posting p
          where p.ledger_account_id = la.id and p.effective_date <= d::date)),
  0, 'ledger_balance at D = sum of postings with effective_date <= D, for every account and date');
select is(
  (select count(*)::int
   from generate_series('2026-01-31'::date, '2026-04-02'::date, '1 day') d,
        lateral private.account_balances('30000000-0000-0000-0000-0000000000a1', d::date) b
   where b.balance_minor <> (select coalesce(sum(p.amount_minor), 0) from public.ledger_posting p
                             join public.ledger_account la on la.id = p.ledger_account_id
                             where la.claim_item_id = b.claim_item_id and la.component = b.component
                               and p.effective_date <= d::date)),
  0, 'account_balances agrees per item and component');
select is((select balance_minor from private.account_balances('30000000-0000-0000-0000-0000000000a1', '2026-01-31')), null,
  'nothing before the first entry');
select is((select balance_minor from private.account_balances('30000000-0000-0000-0000-0000000000a1', '2026-03-15')), 1000::bigint,
  'a reversed entry nets to zero from its date');
select is((select balance_minor from private.account_balances('30000000-0000-0000-0000-0000000000a1', '2026-04-01')), 600::bigint,
  'later entries count from their date');
select is(
  (select private.ledger_balance(la.id, '2026-04-01') from public.ledger_account la
   where la.book = 'owner_claim' and la.portfolio_id = '20000000-0000-0000-0000-0000000000a1'),
  -600::bigint, 'the owner claim mirrors the receivable');

-- Client money (M2b): a credit on the dedicated account, forwarded to client A ------------------------
insert into public.bank_account (id, organization_id, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'FR3430001007940000000001001', 'EUR',
   'Fonds de tiers', 'camt053', '2026-01-01');
insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                   size_bytes, storage_path) values
  ('a0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001',
   'EUR', 'camt053', 'releve.xml', repeat('a', 64), 1, 'test/releve.xml');
update public.bank_statement set status = 'uploaded', uploaded_at = now();
insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind) values
  ('b0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000001', 1, 't:P1', 'credit', 100, 'EUR', '2026-03-10', 'debtor_credit');
insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor, currency,
                            booking_date) values
  ('90000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001',
   'b0000000-0000-0000-0000-000000000001', 'camt053', 'sct', 100, 'EUR', '2026-03-10');
create or replace function pg_temp.post1(p_type text, p_date date, p_key text, p_lines jsonb, p_meta jsonb)
returns uuid language plpgsql as $$
declare v uuid;
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, account_id,
                                  client_organization_id, payment_id, source_type, source_id, reason)
  values (1, '00000000-0000-0000-0000-00000000000a', p_type, p_date, p_key, (p_meta ->> 'account_id')::uuid,
          (p_meta ->> 'client_organization_id')::uuid, (p_meta ->> 'payment_id')::uuid, p_meta ->> 'source_type',
          p_meta ->> 'source_id', p_meta ->> 'reason');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, claim_item_id, component, bank_account_id)
  select 1, ord::integer, l ->> 'book', (l ->> 'amount_minor')::bigint, l ->> 'currency', (l ->> 'claim_item_id')::uuid,
         l ->> 'component', (l ->> 'bank_account_id')::uuid
  from jsonb_array_elements(p_lines) with ordinality as x (l, ord);
  select r.entry_id into v from private.ledger_post_set() r;
  return v;
end $$;
select pg_temp.post1('cash_in', '2026-03-10', 'cash-in-0001-key',
  '[{"book": "client_money_cash", "amount_minor": 100, "currency": "EUR", "bank_account_id": "80000000-0000-0000-0000-000000000001"},
    {"book": "unallocated_payment", "amount_minor": -100, "currency": "EUR"}]',
  '{"source_type": "bank_statement", "source_id": "stmt-1"}');
select pg_temp.post1('forward', '2026-03-10', 'client-money-0001',
  '[{"book": "unallocated_payment", "amount_minor": 100, "currency": "EUR"},
    {"book": "client_payable", "amount_minor": -100, "currency": "EUR"}]',
  '{"client_organization_id": "00000000-0000-0000-0000-0000000000a1", "payment_id": "90000000-0000-0000-0000-000000000001",
    "reason": "ratified by the client"}');
select is((select held_minor from private.client_money_balances('00000000-0000-0000-0000-0000000000a1', '2026-03-10')),
  100::bigint, 'money owed to client A is held for it');
select is((select count(*)::int from private.client_money_balances('00000000-0000-0000-0000-0000000000a1', '2026-03-09')),
  0, 'not before its date');
select is((select count(*)::int from private.client_money_balances('00000000-0000-0000-0000-0000000000a2', '2026-03-10')),
  0, 'and never for client B');

-- Read access -----------------------------------------------------------------------------------------
-- Expected value computed before switching role (the private function is service_role only).
select set_config('test.a1_balance',
  (select balance_minor::text from private.account_balances('30000000-0000-0000-0000-0000000000a1', private.paris_today())), true);
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(distinct client_organization_id)::int from public.ledger_account), 1,
  'client A''s admin sees only client A''s ledger accounts');
select is((select count(*)::int from public.ledger_posting p join public.ledger_account la on la.id = p.ledger_account_id
           where la.client_organization_id = '00000000-0000-0000-0000-0000000000a2'), 0, 'and no line of client B');
select is((select count(*)::int from public.ledger_account where client_organization_id is null), 0,
  'unidentified receipts are not shown to a client');
select is((select balance_minor from public.account_balances('30000000-0000-0000-0000-0000000000a1')),
  current_setting('test.a1_balance')::bigint,
  'client A reads its own balances; as_of defaults to the Paris date');
select throws_ok($$ select * from public.account_balances('30000000-0000-0000-0000-0000000000a2') $$, '42501', null,
  'but not client B''s');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select is((select count(*)::int from public.ledger_entry), 0, 'staff below two-factor see no entry');
select throws_ok($$ select * from public.account_balances('30000000-0000-0000-0000-0000000000a1') $$, '42501', null,
  'nor balances');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select is((select count(distinct client_organization_id)::int from public.ledger_entry), 2, 'staff at aal2 see both clients');
reset role;

select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000002", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select throws_ok($$ select * from public.account_balances('30000000-0000-0000-0000-0000000000a1') $$, '42501', null,
  'a collector restricted to another portfolio cannot read this account');
select is(
  (select count(*)::int from public.ledger_account where portfolio_id = '20000000-0000-0000-0000-0000000000a1')
  + (select count(*)::int from public.ledger_entry where portfolio_id = '20000000-0000-0000-0000-0000000000a1')
  + (select count(*)::int from public.ledger_posting p join public.ledger_entry e on e.id = p.entry_id
     where e.portfolio_id = '20000000-0000-0000-0000-0000000000a1'),
  0, 'nor any ledger row of that portfolio (RLS)');
select ok((select count(*) from public.ledger_entry where portfolio_id = '20000000-0000-0000-0000-0000000000a2') > 0,
  'but sees its own portfolio''s entries');
reset role;

-- readable_portfolio_ids (used by the policies) = the portfolios can_read_portfolio allows, per user.
create or replace function pg_temp.portfolio_sets_agree(p_user uuid, p_aal text) returns boolean language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  return (select coalesce(array_agg(x order by x), '{}') from unnest(private.readable_portfolio_ids()) x)
       = (select coalesce(array_agg(p.id order by p.id), '{}') from public.portfolio p where private.can_read_portfolio(p.id));
end $$;
select ok(bool_and(pg_temp.portfolio_sets_agree(u.id, a)), 'readable_portfolio_ids matches can_read_portfolio for every user')
from auth.users u cross join (values ('aal1'), ('aal2')) v (a) where u.id::text like '10000000-%';

select * from finish();
rollback;
