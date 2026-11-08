-- M2b-1 (M2-06): payments in the ledger, bank accounts, payments, RF creditor references.
-- Design docs/design/m2b-payments.md §5–§6, §13; ADR-0013. pgTAP never commits: payment entries go
-- through private.ledger_post_set, which runs the commit-time checks itself (SET CONSTRAINTS ... IMMEDIATE).
begin;
select plan(125);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo'),
  ('00000000-0000-0000-0000-00000000000b', 'servicer', 'Other servicer');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client B');
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
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000a2', 'client_admin');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'PA'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'PB');
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a2');
insert into public.boarding_batch (id, organization_id, client_organization_id, portfolio_id, version) values
  ('70000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   '20000000-0000-0000-0000-0000000000a1', 1);
insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                            legal_regime, currency, status, boarding_batch_id) values
  ('30000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   '20000000-0000-0000-0000-0000000000a1', 'b2b_invoice', 'M-0042', 'commercial_b2b', 'EUR', 'awaiting_first_letter', null),
  ('30000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2',
   '20000000-0000-0000-0000-0000000000a2', 'b2b_invoice', 'L-9', 'commercial_b2b', 'EUR', 'awaiting_first_letter', null),
  ('30000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   '20000000-0000-0000-0000-0000000000a1', 'b2b_invoice', 'S-1', 'commercial_b2b', 'EUR', 'staged',
   '70000000-0000-0000-0000-000000000001'),
  ('30000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   '20000000-0000-0000-0000-0000000000a1', 'b2b_invoice', 'B-1', 'commercial_b2b', 'EUR', 'awaiting_first_letter',
   '70000000-0000-0000-0000-000000000001'),
  ('30000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   '20000000-0000-0000-0000-0000000000a1', 'b2b_invoice', 'B-2', 'commercial_b2b', 'EUR', 'awaiting_first_letter',
   '70000000-0000-0000-0000-000000000001');
insert into public.claim_item (id, account_id, kind, ref, due_date, original_minor) values
  ('40000000-0000-0000-0000-0000000000f1', '30000000-0000-0000-0000-0000000000a1', 'invoice', 'F-101', '2026-01-10', 100000),
  ('40000000-0000-0000-0000-0000000000f2', '30000000-0000-0000-0000-0000000000a1', 'invoice', 'F-102', '2026-01-15', 10000),
  ('40000000-0000-0000-0000-0000000000c1', '30000000-0000-0000-0000-0000000000a1', 'credit_note', 'AV-105', '2026-01-20', 20000),
  ('40000000-0000-0000-0000-0000000000b1', '30000000-0000-0000-0000-0000000000a2', 'invoice', 'G-1', '2026-01-10', 9000),
  ('40000000-0000-0000-0000-0000000000d1', '30000000-0000-0000-0000-0000000000a3', 'invoice', 'H-1', '2026-01-10', 7000);
insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type, valid_from)
select id, client_organization_id, organization_id, 'mandate_amicable', '2026-01-01' from public.account
where organization_id = '00000000-0000-0000-0000-00000000000a';
insert into public.bank_account (id, organization_id, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'FR3430001007940000000001001', 'EUR',
   'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'FR7030001007940000000002002', 'EUR',
   'Ancien compte', 'csv', '2026-01-01'),
  ('80000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000b', 'FR0930001007940000000003003', 'EUR',
   'Autre servicer', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-00000000000a', 'FR3430001007940000000001001', 'USD',
   'Fonds de tiers USD', 'camt053', '2026-01-01');
update public.bank_account set status = 'closed', closed_on = '2026-02-01', closed_reason = 'replaced'
where id = '80000000-0000-0000-0000-000000000002';
insert into public.payment (id, organization_id, bank_account_id, channel, method, amount_minor, currency, booking_date,
                            payer_name, remittance_text) values
  ('90000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001',
   'camt053', 'sct', 50000, 'EUR', '2026-03-10', 'Martin SAS', 'REGLT F-101'),
  ('90000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001',
   'camt053', 'sct', 30000, 'EUR', '2026-03-12', 'Inconnu', 'REMBOURSEMENT'),
  ('90000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000004',
   'camt053', 'sct', 700, 'USD', '2026-03-12', 'Inconnu', 'USD');

create temporary table t (k text primary key, v uuid) on commit drop;
grant all on t to authenticated;

-- One payment entry through private.ledger_post_set (what the M2b-2 … M2b-6 definer functions do).
create or replace function pg_temp.post1(p_type text, p_date date, p_key text, p_lines jsonb, p_meta jsonb default '{}')
returns uuid language plpgsql as $$
declare v uuid;
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, account_id,
                                  client_organization_id, payment_id, source_type, source_id, reason)
  values (1, coalesce((p_meta ->> 'organization_id')::uuid, '00000000-0000-0000-0000-00000000000a'), p_type, p_date, p_key,
          (p_meta ->> 'account_id')::uuid, (p_meta ->> 'client_organization_id')::uuid, (p_meta ->> 'payment_id')::uuid,
          p_meta ->> 'source_type', p_meta ->> 'source_id', p_meta ->> 'reason');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, claim_item_id, component, bank_account_id)
  select 1, ord::integer, l ->> 'book', (l ->> 'amount_minor')::bigint, l ->> 'currency', (l ->> 'claim_item_id')::uuid,
         l ->> 'component', (l ->> 'bank_account_id')::uuid
  from jsonb_array_elements(p_lines) with ordinality as x (l, ord);
  select r.entry_id into v from private.ledger_post_set() r;
  return v;
end $$;
-- An allocation of a payment to items of account M-0042 (principal), dated p_date.
create or replace function pg_temp.alloc(p_payment uuid, p_date date, p_key text, p_items jsonb)
returns uuid language sql as $$
  select pg_temp.post1('allocation', p_date, p_key,
    jsonb_build_array(
      jsonb_build_object('book', 'unallocated_payment', 'amount_minor', (select sum(value::bigint) from jsonb_each_text(p_items)), 'currency', 'EUR'),
      jsonb_build_object('book', 'client_payable', 'amount_minor', -(select sum(value::bigint) from jsonb_each_text(p_items)), 'currency', 'EUR'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', (select sum(value::bigint) from jsonb_each_text(p_items)), 'currency', 'EUR', 'component', 'principal'))
    || (select jsonb_agg(jsonb_build_object('book', 'debtor_receivable', 'amount_minor', -value::bigint, 'currency', 'EUR',
                                           'claim_item_id', key, 'component', 'principal'))
        from jsonb_each_text(p_items)),
    jsonb_build_object('account_id', '30000000-0000-0000-0000-0000000000a1', 'payment_id', p_payment));
$$;
create or replace function pg_temp.adjust(p_item uuid, p_amount bigint, p_date date, p_key text)
returns uuid language sql as $$
  select entry_id from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', p_date, p_key,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', p_item, 'component', 'principal'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', 'principal')),
    jsonb_build_object('account_id', (select account_id from public.claim_item where id = p_item), 'reason', 'test'));
$$;
-- The same, with the commit-time checks run at once (ledger_post leaves them to the commit).
create or replace function pg_temp.adjust_now(p_item uuid, p_amount bigint, p_date date, p_key text)
returns uuid language plpgsql as $$
declare v uuid;
begin
  v := pg_temp.adjust(p_item, p_amount, p_date, p_key);
  set constraints public.ledger_entry_balanced immediate;
  set constraints public.ledger_entry_balanced deferred;
  return v;
end $$;
create or replace function pg_temp.as_user(p_user uuid, p_aal text) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;

-- Openings stand-in (seller balances at the cut-off): F-101 1000.00, F-102 100.00, AV-105 −200.00, G-1 90.00.
select pg_temp.adjust('40000000-0000-0000-0000-0000000000f1', 100000, '2026-02-01', 'open-f101-key');
select pg_temp.adjust('40000000-0000-0000-0000-0000000000f2', 10000, '2026-02-01', 'open-f102-key');
select pg_temp.adjust('40000000-0000-0000-0000-0000000000c1', -20000, '2026-02-01', 'open-av105-key');
select pg_temp.adjust('40000000-0000-0000-0000-0000000000b1', 9000, '2026-02-01', 'open-g1-key');

-- Structure ---------------------------------------------------------------------------------------
select is((select array[account_number, dimension, money_of, client_visible::text] from public.ledger_book
           where code = 'client_money_cash'), array['5120', 'bank', 'client', 'false'],
  '5120 is the client-money cash book, one ledger account per bank account');
select is((select allowed_books from public.ledger_entry_type where code = 'adjustment'),
  array['debtor_receivable', 'owner_claim'], 'an adjustment no longer touches client money');
select is((select count(*)::int from public.ledger_entry_type
           where code in ('cash_in', 'allocation', 'forward', 'cash_out', 'netting')
             and 'servicer_revenue' = any (allowed_books)), 0, 'no payment entry type can reach 7060 (I10)');
select is((select count(*)::int from pg_trigger
           where tgrelid in ('public.bank_account'::regclass, 'public.payment'::regclass, 'public.payment_reference'::regclass)
             and not tgisinternal and tgname not like '%change_log' and tgname not like '%touch' and tgenabled <> 'A'), 0,
  'the guards of bank accounts, payments and references fire ALWAYS');
select is(
  (select bool_and(p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('private', 'public')
     and p.proname in ('ledger_post_set', 'issue_payment_references', 'register_bank_account', 'close_bank_account',
                       'retire_payment_reference', 'money_staff_org_ids')),
  true, 'the new definer functions pin their search_path');
select is(
  array[has_function_privilege('service_role', 'private.ledger_post_set()', 'execute'),
        has_function_privilege('authenticated', 'private.ledger_post_set()', 'execute'),
        has_function_privilege('service_role', 'private.issue_payment_references(uuid)', 'execute'),
        has_function_privilege('anon', 'public.register_bank_account(text, uuid, text, text, text, text, text, date)', 'execute'),
        has_function_privilege('authenticated', 'public.register_bank_account(text, uuid, text, text, text, text, text, date)', 'execute')],
  array[false, false, false, false, true],
  'set posting and reference issuance are internal; the bank-account command is for signed-in users');

-- RF creditor references (ISO 11649) and IBANs -----------------------------------------------------
select ok(private.rf_valid('RF18539007547034'), 'the ISO 11649 vector validates');
select ok(private.rf_valid('RF60482193057612') and private.rf_valid('RF72730261884529'), 'so do the design''s examples');
select is(private.rf_make('539007547034'), 'RF18539007547034', 'rf_make computes the check digits');
select is(array[private.rf_valid('RF18539007547035'), private.rf_valid('RF18539007457034'), private.rf_valid('RF81539007547034'),
                private.rf_valid('rf18539007547034'), private.rf_valid('RF18 5390 0754 7034'), private.rf_valid(null),
                private.rf_valid('RF18')],
  array[false, false, false, false, false, false, false],
  'a substituted or transposed digit, wrong check digits, lower case, spaces, null or no body are refused');
select is(private.rf_normalise('rf18 5390 0754' || chr(10) || '7034'), 'RF18539007547034', 'rf_normalise strips spaces and line breaks');
select is((select count(*)::int from (select private.rf_make(private.rf_random_body()) rf from generate_series(1, 2000)) x
           where x.rf !~ '^RF[0-9]{14}$' or not private.rf_valid(x.rf)), 0,
  'random references are RF + 14 digits and validate (2000 draws)');
select is((select count(*)::int from (
             select x, case when x ~ '^RF(0[2-9]|[1-8][0-9]|9[0-8])[0-9]{12}$'
                            then (substr(x, 5) || '2715' || substr(x, 3, 2))::numeric % 97 = 1 else false end as inline_check
             from (select 'RF' || lpad((random() * 99)::int::text, 2, '0') || lpad((random() * 999999999999)::bigint::text, 12, '0') as x
                   from generate_series(1, 5000)
                   union all select private.rf_make(private.rf_random_body()) from generate_series(1, 1000)) r) y
           where y.inline_check <> (y.x ~ '^RF[0-9]{14}$' and private.rf_valid(y.x))), 0,
  'the inline check of payment_reference.rf says what rf_valid says (6000 strings)');
select ok(private.iban_valid('FR3430001007940000000001001') and not private.iban_valid('FR3430001007940000000001002')
          and not private.iban_valid('FR34 3000 1007 9400 0000 0001 001'), 'IBANs are checked mod 97 (normalised first)');

-- Bank accounts -----------------------------------------------------------------------------------
select throws_ok($$ insert into public.bank_account (organization_id, iban, currency, label, feed, opened_on)
  values ('00000000-0000-0000-0000-00000000000a', 'FR3430001007940000000001002', 'EUR', 'x', 'csv', '2026-01-01') $$,
  '23514', null, 'an invalid IBAN is refused');
select throws_ok($$ insert into public.bank_account (organization_id, purpose, iban, currency, label, feed, opened_on)
  values ('00000000-0000-0000-0000-00000000000a', 'own', 'FR1420041010050500013M02606', 'EUR', 'x', 'csv', '2026-01-01') $$,
  '23514', null, 'only client_funds accounts exist before M2c');
select throws_ok($$ insert into public.bank_account (organization_id, iban, currency, label, feed, opened_on)
  values ('00000000-0000-0000-0000-0000000000a1', 'FR1420041010050500013M02606', 'EUR', 'x', 'csv', '2026-01-01') $$,
  '23514', null, 'a bank account belongs to a servicer');
select throws_ok($$ update public.bank_account set iban = 'FR1420041010050500013M02606'
  where id = '80000000-0000-0000-0000-000000000001' $$, '23514', null, 'the IBAN of a bank account never changes');
select throws_ok($$ update public.bank_account set status = 'active', closed_on = null, closed_reason = null
  where id = '80000000-0000-0000-0000-000000000002' $$, '23514', null, 'a closed account stays closed');
select throws_ok($$ delete from public.bank_account where id = '80000000-0000-0000-0000-000000000002' $$, '23514', null,
  'bank accounts are never deleted');

-- 5120 ledger accounts: only on an active client_funds account of the same servicer and currency
select throws_ok($$ insert into public.ledger_account (organization_id, book, currency, bank_account_id)
  values ('00000000-0000-0000-0000-00000000000a', 'client_money_cash', 'EUR', '80000000-0000-0000-0000-000000000002') $$,
  'LG002', null, 'no cash ledger account on a closed bank account');
select throws_ok($$ insert into public.ledger_account (organization_id, book, currency, bank_account_id)
  values ('00000000-0000-0000-0000-00000000000a', 'client_money_cash', 'EUR', '80000000-0000-0000-0000-000000000003') $$,
  '23503', null, 'nor on another servicer''s bank account');
select throws_ok($$ insert into public.ledger_account (organization_id, book, currency, bank_account_id)
  values ('00000000-0000-0000-0000-00000000000a', 'client_money_cash', 'USD', '80000000-0000-0000-0000-000000000001') $$,
  '23503', null, 'nor in another currency than the bank account''s');
select throws_ok($$ insert into public.ledger_account (organization_id, book, currency, client_organization_id, bank_account_id)
  values ('00000000-0000-0000-0000-00000000000a', 'client_payable', 'EUR', '00000000-0000-0000-0000-0000000000a1',
          '80000000-0000-0000-0000-000000000001') $$,
  '23514', null, 'only the cash book carries a bank account');

-- Cash in: the statement day is booked at once ------------------------------------------------------
insert into t select 'cash1', pg_temp.post1('cash_in', '2026-03-10', 'cash_in:stmt-1:2026-03-10',
  '[{"book": "client_money_cash", "amount_minor": 50000, "currency": "EUR", "bank_account_id": "80000000-0000-0000-0000-000000000001"},
    {"book": "unallocated_payment", "amount_minor": -50000, "currency": "EUR"}]',
  '{"source_type": "bank_statement", "source_id": "stmt-1"}');
insert into t select 'cash2', pg_temp.post1('cash_in', '2026-03-12', 'cash_in:stmt-2:2026-03-12',
  '[{"book": "client_money_cash", "amount_minor": 30000, "currency": "EUR", "bank_account_id": "80000000-0000-0000-0000-000000000001"},
    {"book": "unallocated_payment", "amount_minor": -30000, "currency": "EUR"}]',
  '{"source_type": "bank_statement", "source_id": "stmt-2"}');
select is((select array[e.entry_type, e.source_type, (e.client_organization_id is null)::text, (e.payment_id is null)::text]
           from public.ledger_entry e where e.id = (select v from t where k = 'cash1')),
  array['cash_in', 'bank_statement', 'true', 'true'], 'a cash_in is the statement''s, of no client and no payment');
select is((select count(*)::int from public.ledger_account where book = 'client_money_cash'
           and bank_account_id = '80000000-0000-0000-0000-000000000001'), 1, 'one cash ledger account per bank account');
select is((select count(*)::int from public.ledger_account where book = 'unallocated_payment'
           and organization_id = '00000000-0000-0000-0000-00000000000a' and client_organization_id is null), 1,
  'unallocated money is pooled (no client)');
select throws_ok($$ select pg_temp.post1('cash_in', '2026-03-10', 'cash_in:no-source-1',
  '[{"book": "client_money_cash", "amount_minor": 1, "currency": "EUR", "bank_account_id": "80000000-0000-0000-0000-000000000001"},
    {"book": "unallocated_payment", "amount_minor": -1, "currency": "EUR"}]') $$,
  '23514', null, 'a cash_in names its bank statement');
select throws_ok($$ select pg_temp.post1('cash_in', '2026-03-10', 'cash_in:closed-acct',
  '[{"book": "client_money_cash", "amount_minor": 1, "currency": "EUR", "bank_account_id": "80000000-0000-0000-0000-000000000002"},
    {"book": "unallocated_payment", "amount_minor": -1, "currency": "EUR"}]',
  '{"source_type": "bank_statement", "source_id": "stmt-x"}') $$,
  'LG002', null, 'no cash on a closed bank account (R124-2)');
select throws_ok($$ select pg_temp.post1('cash_in', '2026-03-10', 'cash_in:other-servicer',
  '[{"book": "client_money_cash", "amount_minor": 1, "currency": "EUR", "bank_account_id": "80000000-0000-0000-0000-000000000003"},
    {"book": "unallocated_payment", "amount_minor": -1, "currency": "EUR"}]',
  '{"source_type": "bank_statement", "source_id": "stmt-x"}') $$,
  'LG002', null, 'nor on another servicer''s account');
select throws_ok($$ select pg_temp.post1('cash_in', '2026-03-10', 'cash_in:three-lines',
  '[{"book": "client_money_cash", "amount_minor": 2, "currency": "EUR", "bank_account_id": "80000000-0000-0000-0000-000000000001"},
    {"book": "unallocated_payment", "amount_minor": -1, "currency": "EUR"},
    {"book": "unallocated_payment", "amount_minor": -1, "currency": "EUR"}]',
  '{"source_type": "bank_statement", "source_id": "stmt-x"}') $$,
  'LG001', null, 'a cash_in is one cash debit and one pooled credit (shape)');
select throws_ok(format($$ select * from private.ledger_reverse(%L, 'reverse-cash-in-1', 'wrong line') $$, (select v from t where k = 'cash1')),
  'LG003', null, 'a cash_in is never reversed (a wrong line is corrected by a cash_out)');

-- Allocation -----------------------------------------------------------------------------------------
insert into t select 'a1', pg_temp.alloc('90000000-0000-0000-0000-000000000001', '2026-03-10', 'alloc:run1:p1:m0042',
  '{"40000000-0000-0000-0000-0000000000f1": 40000}');
select is((select array[e.entry_type, e.payment_id::text, e.account_id::text, e.client_organization_id::text, e.line_count::text]
           from public.ledger_entry e where e.id = (select v from t where k = 'a1')),
  array['allocation', '90000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-0000000000a1',
        '00000000-0000-0000-0000-0000000000a1', '4'],
  'an allocation is tagged with its payment, on the claim''s account and client');
select is((select sum(p.amount_minor)::bigint from public.ledger_posting p join public.ledger_account la on la.id = p.ledger_account_id
           where p.entry_id = (select v from t where k = 'a1') and la.book in ('unallocated_payment', 'client_payable')),
  0::bigint, 'its client-money lines close (4710 debit = 4670 credit)');
select is(pg_temp.alloc('90000000-0000-0000-0000-000000000001', '2026-03-10', 'alloc:run1:p1:m0042',
  '{"40000000-0000-0000-0000-0000000000f1": 40000}'), (select v from t where k = 'a1'),
  'the same key and request return the same entry');
select throws_ok($$ select pg_temp.alloc('90000000-0000-0000-0000-000000000001', '2026-03-10', 'alloc:run1:p1:m0042',
  '{"40000000-0000-0000-0000-0000000000f1": 41000}') $$, 'LG004', null, 'the same key with another request is refused');
select throws_ok($$ select pg_temp.alloc('90000000-0000-0000-0000-000000000001', '2026-03-10', 'alloc:run2:p1:m0042',
  '{"40000000-0000-0000-0000-0000000000f1": 10001}') $$, 'LG007', null,
  'an allocation above what is left of the payment is refused (I4)');
select throws_ok($$ select pg_temp.alloc('90000000-0000-0000-0000-000000000002', '2026-03-12', 'alloc:run2:p2:m0042',
  '{"40000000-0000-0000-0000-0000000000f2": 10001}') $$, 'LG007', null,
  'an allocation above the component''s balance is refused (I6)');
select throws_ok($$ select pg_temp.alloc('90000000-0000-0000-0000-000000000002', '2026-03-11', 'alloc:run3:p2:m0042',
  '{"40000000-0000-0000-0000-0000000000f2": 100}') $$, 'LG007', null,
  'an allocation dated before the payment was booked is refused (I4, I7)');
select throws_ok($$ select pg_temp.alloc('90000000-0000-0000-0000-000000000002', '2026-03-12', 'alloc:run3:p2:av105',
  '{"40000000-0000-0000-0000-0000000000c1": 100}') $$, 'LG007', null, 'a credit note is never paid by an allocation');
select throws_ok($$ select pg_temp.post1('allocation', '2026-03-12', 'alloc:staged-acct',
  '[{"book": "unallocated_payment", "amount_minor": 100, "currency": "EUR"},
    {"book": "client_payable", "amount_minor": -100, "currency": "EUR"},
    {"book": "debtor_receivable", "amount_minor": -100, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000d1", "component": "principal"},
    {"book": "owner_claim", "amount_minor": 100, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a3", "payment_id": "90000000-0000-0000-0000-000000000002"}') $$,
  'LG006', null, 'no allocation on an account that is not confirmed');
select throws_ok($$ select pg_temp.post1('allocation', '2026-03-12', 'alloc:revenue-line',
  '[{"book": "unallocated_payment", "amount_minor": 100, "currency": "EUR"},
    {"book": "servicer_revenue", "amount_minor": -100, "currency": "EUR"},
    {"book": "debtor_receivable", "amount_minor": -100, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000f2", "component": "principal"},
    {"book": "owner_claim", "amount_minor": 100, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "payment_id": "90000000-0000-0000-0000-000000000002"}') $$,
  'LG002', null, 'an allocation line on 7060 is refused (M2-12)');
select throws_ok($$ select pg_temp.post1('allocation', '2026-03-12', 'alloc:receivable-dr',
  '[{"book": "unallocated_payment", "amount_minor": 100, "currency": "EUR"},
    {"book": "client_payable", "amount_minor": -100, "currency": "EUR"},
    {"book": "debtor_receivable", "amount_minor": -200, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000f1", "component": "principal"},
    {"book": "debtor_receivable", "amount_minor": 100, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000f2", "component": "principal"},
    {"book": "owner_claim", "amount_minor": 100, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "payment_id": "90000000-0000-0000-0000-000000000002"}') $$,
  'LG001', null, 'an allocation only credits receivables (shape)');
select throws_ok($$ select pg_temp.post1('allocation', '2026-03-12', 'alloc:usd-payment',
  '[{"book": "unallocated_payment", "amount_minor": 100, "currency": "EUR"},
    {"book": "client_payable", "amount_minor": -100, "currency": "EUR"},
    {"book": "debtor_receivable", "amount_minor": -100, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000f2", "component": "principal"},
    {"book": "owner_claim", "amount_minor": 100, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "payment_id": "90000000-0000-0000-0000-000000000003"}') $$,
  'LG002', null, 'a payment is never allocated in another currency (no FX in M2b)');
select throws_ok($$ select pg_temp.post1('allocation', '2026-03-12', 'alloc:no-payment',
  '[{"book": "unallocated_payment", "amount_minor": 100, "currency": "EUR"},
    {"book": "client_payable", "amount_minor": -100, "currency": "EUR"},
    {"book": "debtor_receivable", "amount_minor": -100, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000f2", "component": "principal"},
    {"book": "owner_claim", "amount_minor": 100, "currency": "EUR", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1"}') $$,
  'LG006', null, 'an allocation names its payment');
select throws_ok($$ select * from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'allocation', '2026-03-12',
  'alloc-by-hand-01', '[]', '{}') $$, 'LG006', null, 'payment entries are not posted through ledger_post');
select throws_ok($$ select * from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'adjustment', '2026-03-12',
  'adjust-4710-0001',
  '[{"book": "unallocated_payment", "amount_minor": 100, "currency": "EUR"},
    {"book": "client_payable", "amount_minor": -100, "currency": "EUR", "client_organization_id": "00000000-0000-0000-0000-0000000000a1"}]',
  '{"reason": "x"}') $$, 'LG002', null, 'an adjustment on 4710 is refused');

-- A correction cannot overdraw what was allocated (I6 holds after any entry) ---------------------
select throws_ok($$ select pg_temp.adjust_now('40000000-0000-0000-0000-0000000000f1', -60001, '2026-03-15', 'adjust-f101-down') $$,
  'LG007', null, 'a correction that takes an allocated receivable below zero is refused');
select lives_ok($$ select pg_temp.adjust_now('40000000-0000-0000-0000-0000000000f1', -1000, '2026-03-15', 'adjust-f101-small') $$,
  'a smaller correction is accepted');
select throws_ok($$ select pg_temp.adjust_now('40000000-0000-0000-0000-0000000000f1', -59001, '2026-02-15', 'adjust-f101-past') $$,
  'LG007', null, 'also when dated before the allocation (the balance after it would go negative)');

-- Netting a credit note (ops action) ----------------------------------------------------------------
select throws_ok($$ select pg_temp.post1('netting', '2026-02-01', 'netting:av105:f101:0',
  '[{"book": "debtor_receivable", "amount_minor": 20000, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000c1", "component": "principal"},
    {"book": "debtor_receivable", "amount_minor": -20000, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000f1", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1"}') $$, 'LG006', null, 'a netting needs a reason');
insert into t select 'n1', pg_temp.post1('netting', '2026-02-01', 'netting:av105:f101:1',
  '[{"book": "debtor_receivable", "amount_minor": 20000, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000c1", "component": "principal"},
    {"book": "debtor_receivable", "amount_minor": -20000, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000f1", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "reason": "avoir AV-105 sur F-101"}');
select is((select private.ledger_balance(la.id, '2026-03-31') from public.ledger_account la
           where la.claim_item_id = '40000000-0000-0000-0000-0000000000c1'), 0::bigint, 'the credit note is used up');
select throws_ok($$ select pg_temp.post1('netting', '2026-02-01', 'netting:av105:f102:2',
  '[{"book": "debtor_receivable", "amount_minor": 1, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000c1", "component": "principal"},
    {"book": "debtor_receivable", "amount_minor": -1, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000f2", "component": "principal"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "reason": "again"}') $$, 'LG007', null,
  'a credit note never goes above zero');
select throws_ok($$ select pg_temp.post1('netting', '2026-02-01', 'netting:interest:3',
  '[{"book": "debtor_receivable", "amount_minor": 1, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000c1", "component": "accrued_interest"},
    {"book": "debtor_receivable", "amount_minor": -1, "currency": "EUR", "claim_item_id": "40000000-0000-0000-0000-0000000000f2", "component": "accrued_interest"}]',
  '{"account_id": "30000000-0000-0000-0000-0000000000a1", "reason": "interest"}') $$, 'LG001', null,
  'a netting is on principal only (shape)');
select throws_ok($$ select pg_temp.adjust_now('40000000-0000-0000-0000-0000000000c1', 1, '2026-03-20', 'adjust-av105-up') $$,
  'LG007', null, 'nor does a correction take a netted credit note above zero');

-- Forward, cash out (refund) ---------------------------------------------------------------------------
select throws_ok($$ select pg_temp.post1('forward', '2026-03-12', 'forward:p2:no-reason',
  '[{"book": "unallocated_payment", "amount_minor": 5000, "currency": "EUR"},
    {"book": "client_payable", "amount_minor": -5000, "currency": "EUR"}]',
  '{"client_organization_id": "00000000-0000-0000-0000-0000000000a1", "payment_id": "90000000-0000-0000-0000-000000000002"}') $$,
  'LG006', null, 'a forward needs a reason');
insert into t select 'f1', pg_temp.post1('forward', '2026-03-12', 'forward:p2:clientA',
  '[{"book": "unallocated_payment", "amount_minor": 5000, "currency": "EUR"},
    {"book": "client_payable", "amount_minor": -5000, "currency": "EUR"}]',
  '{"client_organization_id": "00000000-0000-0000-0000-0000000000a1", "payment_id": "90000000-0000-0000-0000-000000000002",
    "reason": "dossier rappelé : reversement au mandant"}');
select throws_ok($$ select pg_temp.post1('forward', '2026-03-12', 'forward:p2:wrong-client',
  '[{"book": "unallocated_payment", "amount_minor": 1, "currency": "EUR"},
    {"book": "client_payable", "amount_minor": -1, "currency": "EUR"}]',
  '{"client_organization_id": "00000000-0000-0000-0000-00000000000b", "payment_id": "90000000-0000-0000-0000-000000000002",
    "reason": "x"}') $$, 'LG002', null, 'a forward pays a client of this servicer only');
insert into t select 'r1', pg_temp.post1('cash_out', '2026-03-20', 'cash_out:p1:refund',
  '[{"book": "unallocated_payment", "amount_minor": 10000, "currency": "EUR"},
    {"book": "client_money_cash", "amount_minor": -10000, "currency": "EUR", "bank_account_id": "80000000-0000-0000-0000-000000000001"}]',
  '{"payment_id": "90000000-0000-0000-0000-000000000001", "reason": "refund"}');
select throws_ok($$ select pg_temp.post1('cash_out', '2026-03-20', 'cash_out:p1:refund-again',
  '[{"book": "unallocated_payment", "amount_minor": 1, "currency": "EUR"},
    {"book": "client_money_cash", "amount_minor": -1, "currency": "EUR", "bank_account_id": "80000000-0000-0000-0000-000000000001"}]',
  '{"payment_id": "90000000-0000-0000-0000-000000000001", "reason": "refund"}') $$, 'LG007', null,
  'nothing is refunded beyond what is left of the payment');
select is(
  (select array_agg(x order by x) from (
     select 'P1:' || coalesce(sum(p.amount_minor) filter (where e.entry_type = 'allocation'), 0) || '/'
                  || coalesce(sum(p.amount_minor) filter (where e.entry_type = 'cash_out'), 0) as x
     from public.ledger_entry e join public.ledger_posting p on p.entry_id = e.id
     join public.ledger_account la on la.id = p.ledger_account_id and la.book = 'unallocated_payment'
     where e.payment_id = '90000000-0000-0000-0000-000000000001') y),
  array['P1:40000/10000'], 'P1 = 400.00 allocated + 100.00 refunded + 0 left (I5)');

-- Reversals keep the payment -------------------------------------------------------------------------
insert into t select 'ra1', entry_id from private.ledger_reverse((select v from t where k = 'a1'), 'reverse-alloc-p1', 'wrong account');
select is((select payment_id from public.ledger_entry where id = (select v from t where k = 'ra1')),
  '90000000-0000-0000-0000-000000000001'::uuid, 'a reversal keeps the payment of the entry it reverses');
select throws_ok(format($$ do $d$ begin
  insert into public.ledger_entry (organization_id, client_organization_id, entry_type, effective_date, line_count,
                                   idempotency_key, request_hash, reverses_entry_id, reason)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'reversal', '2026-03-12', 2,
          'raw-reversal-nopay', repeat('0', 64), %L, 'x');
end $d$ $$, (select v from t where k = 'f1')), 'LG003', null, 'a reversal that drops the payment is refused');
select lives_ok($$ select pg_temp.alloc('90000000-0000-0000-0000-000000000001', '2026-03-10', 'alloc:run4:p1:m0042',
  '{"40000000-0000-0000-0000-0000000000f2": 10000}') $$,
  'after the reversal P1 can be allocated again, at its original date (up to what was not refunded)');

-- Client-money closure backstop (I2): a type allowed to reach 7060 would still have to close ------------
update public.ledger_entry_type set allowed_books = allowed_books || array['servicer_revenue'] where code = 'forward';
insert into public.ledger_account (id, organization_id, book, currency, client_organization_id) values
  ('50000000-0000-0000-0000-000000007060', '00000000-0000-0000-0000-00000000000a', 'servicer_revenue', 'EUR',
   '00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ do $d$ begin
  insert into public.ledger_entry (id, organization_id, client_organization_id, entry_type, effective_date, line_count,
                                   idempotency_key, request_hash, payment_id, reason)
  values ('60000000-0000-0000-0000-000000000099', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          'forward', '2026-03-12', 2, 'raw-closure-0001', repeat('0', 64), '90000000-0000-0000-0000-000000000002', 'x');
  insert into public.ledger_posting values
    ('60000000-0000-0000-0000-000000000099', 1, (select id from public.ledger_account where book = 'unallocated_payment'
       and organization_id = '00000000-0000-0000-0000-00000000000a' and client_organization_id is null), 100, 'EUR', '2026-03-12'),
    ('60000000-0000-0000-0000-000000000099', 2, '50000000-0000-0000-0000-000000007060', -100, 'EUR', '2026-03-12');
  set constraints public.ledger_entry_balanced immediate;
end $d$ $$, 'LG001', null, 'client money never moves to commission revenue without closing (I2)');
update public.ledger_entry_type set allowed_books = array['unallocated_payment', 'client_payable'] where code = 'forward';

-- Client-money identity (I8) at every date: cash = unallocated + owed to clients ---------------------
select is(
  (select count(*)::int from generate_series('2026-03-01'::date, '2026-03-31'::date, '1 day') d
   where (select coalesce(sum(p.amount_minor), 0) from public.ledger_posting p
          join public.ledger_account la on la.id = p.ledger_account_id
          where la.organization_id = '00000000-0000-0000-0000-00000000000a' and p.currency = 'EUR'
            and la.book in ('client_money_cash', 'unallocated_payment', 'client_payable') and p.effective_date <= d::date) <> 0),
  0, 'Σ5120 + Σ4710 + Σ4670 = 0 at every date (I8)');
select is((select private.ledger_balance(la.id, '2026-03-31') from public.ledger_account la
           where la.book = 'client_money_cash' and la.bank_account_id = '80000000-0000-0000-0000-000000000001'),
  70000::bigint, 'the cash ledger = 800.00 received − 100.00 refunded');
select lives_ok($$ set constraints all immediate $$, 'every entry written in this test passes the commit-time checks');

-- Payments --------------------------------------------------------------------------------------------
select throws_ok($$ insert into public.payment (organization_id, bank_account_id, channel, method, amount_minor, currency, booking_date)
  values ('00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001', 'csv', 'sct', 0, 'EUR', '2026-03-01') $$,
  '23514', null, 'a payment is a positive amount');
select throws_ok($$ insert into public.payment (organization_id, bank_account_id, channel, method, amount_minor, currency, booking_date)
  values ('00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001', 'csv', 'sct', 100, 'USD', '2026-03-01') $$,
  '23503', null, 'in the bank account''s currency');
select throws_ok($$ update public.payment set amount_minor = 49999 where id = '90000000-0000-0000-0000-000000000001' $$,
  '23514', null, 'the bank facts of a payment never change');
select throws_ok($$ update public.payment set account_id = '30000000-0000-0000-0000-0000000000a3', status = 'matched',
  match_method = 'manual', matched_at = now() where id = '90000000-0000-0000-0000-000000000002' $$,
  '23514', null, 'a payment is never matched to a staged account');
update public.payment set account_id = '30000000-0000-0000-0000-0000000000a2', portfolio_id = '20000000-0000-0000-0000-0000000000a1',
  status = 'matched', match_method = 'manual', matched_at = now() where id = '90000000-0000-0000-0000-000000000002';
select is((select array[client_organization_id::text, portfolio_id::text] from public.payment
           where id = '90000000-0000-0000-0000-000000000002'),
  array['00000000-0000-0000-0000-0000000000a2', '20000000-0000-0000-0000-0000000000a2'],
  'client and portfolio come from the matched account, never from the caller');
select throws_ok($$ update public.payment set status = 'unmatched' where id = '90000000-0000-0000-0000-000000000002' $$,
  '23514', null, 'an unmatched payment has no account');
select throws_ok($$ delete from public.payment where id = '90000000-0000-0000-0000-000000000003' $$, '23514', null,
  'payments are never deleted');

-- Payment references (M2-06) ---------------------------------------------------------------------------
select throws_ok($$ insert into public.payment_reference (organization_id, client_organization_id, portfolio_id, account_id, rf)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', '20000000-0000-0000-0000-0000000000a2',
          '30000000-0000-0000-0000-0000000000a1', 'RF18539007547034') $$, '23503', null,
  'a reference carries its account''s client and portfolio');
select is(private.issue_payment_references('70000000-0000-0000-0000-000000000001'), 2::bigint,
  'issuing for a batch gives each workable account of it a reference');
select is(private.issue_payment_references('70000000-0000-0000-0000-000000000001'), 0::bigint, 'exactly one (idempotent)');
select is((select count(*)::int from public.payment_reference where account_id = '30000000-0000-0000-0000-0000000000a3'), 0,
  'staged accounts have none');
select ok(private.issue_payment_references(null) >= 2,
  'the backfill gives one to every other workable account (here M-0042 and L-9)');
select is((select count(*)::int from public.account a
           where a.organization_id = '00000000-0000-0000-0000-00000000000a' and a.status <> 'staged'
             and (select count(*) from public.payment_reference r where r.account_id = a.id and r.status = 'active') <> 1), 0,
  'every workable account has exactly one active reference');
select is((select count(*)::int from public.payment_reference where rf !~ '^RF[0-9]{14}$' or not private.rf_valid(rf)), 0,
  'issued references are RF + 14 digits and validate mod 97');
select throws_ok($$ insert into public.payment_reference (organization_id, client_organization_id, portfolio_id, account_id, rf)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1',
          '30000000-0000-0000-0000-0000000000a1', 'RF18539007547035') $$, '23514', null, 'an RF that fails mod 97 is refused');
select throws_ok($$ insert into public.payment_reference (organization_id, client_organization_id, portfolio_id, account_id, rf)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1',
          '30000000-0000-0000-0000-0000000000a1', 'RF62ABCD') $$, '23514', null,
  'a valid ISO reference that is not RF + 14 digits is refused');
select throws_ok($$ insert into public.payment_reference (organization_id, client_organization_id, portfolio_id, account_id, rf)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1',
          '30000000-0000-0000-0000-0000000000a1', 'RF18539007547034') $$, '23505', null,
  'a second active reference for an account is refused');
select throws_ok($$ insert into public.payment_reference (organization_id, client_organization_id, portfolio_id, account_id, rf)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1',
          '30000000-0000-0000-0000-0000000000a3', 'RF18539007547034') $$, '23514', null,
  'a staged account gets no reference');
select throws_ok($$ update public.payment_reference set rf = 'RF18539007547034'
  where account_id = '30000000-0000-0000-0000-0000000000a1' $$, '23514', null, 'a reference never changes');
select throws_ok($$ delete from public.payment_reference $$, '23514', null, 'references are never deleted');

insert into t select 'ref_old', id from public.payment_reference where account_id = '30000000-0000-0000-0000-0000000000a1';
select pg_temp.as_user('10000000-0000-0000-0000-000000000001', 'aal2');
set local role authenticated;
select throws_ok(format($$ select public.retire_payment_reference('retire-ref-0001', %L, 'printed on a wrong letter') $$,
  (select v from t where k = 'ref_old')), '42501', null, 'only an admin retires a reference');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000004', 'aal2');
set local role authenticated;
insert into t select 'ref_new', public.retire_payment_reference('retire-ref-0001', (select v from t where k = 'ref_old'),
  'printed on a wrong letter');
select is(public.retire_payment_reference('retire-ref-0001', (select v from t where k = 'ref_old'), 'printed on a wrong letter'),
  (select v from t where k = 'ref_new'), 'a replay returns the same new reference');
select throws_ok(format($$ select public.retire_payment_reference('retire-ref-0001', %L, 'another reason') $$,
  (select v from t where k = 'ref_old')), '22023', null, 'the same key for another request is refused');
reset role;
select is((select array[status, (retired_reason is not null)::text] from public.payment_reference
           where id = (select v from t where k = 'ref_old')), array['retired', 'true'], 'the old reference is retired, with why');
select is((select account_id from public.payment_reference
           where organization_id = '00000000-0000-0000-0000-00000000000a'
             and rf = (select rf from public.payment_reference where id = (select v from t where k = 'ref_old'))),
  '30000000-0000-0000-0000-0000000000a1'::uuid, 'and still resolves to its account');
select is((select count(*)::int from public.payment_reference
           where account_id = '30000000-0000-0000-0000-0000000000a1' and status = 'active'), 1,
  'the account has one active reference again');

-- Bank-account commands --------------------------------------------------------------------------------
select pg_temp.as_user('10000000-0000-0000-0000-000000000004', 'aal2');
set local role authenticated;
insert into t select 'ba', public.register_bank_account('register-ba-0001', '00000000-0000-0000-0000-00000000000a',
  'Compte séquestre', 'fr14 2004 1010 0505 0001 3m02 606', 'EUR', 'camt053', 'psstfrppxxx');
select is((select array[iban, bic, purpose, status] from public.bank_account where id = (select v from t where k = 'ba')),
  array['FR1420041010050500013M02606', 'PSSTFRPPXXX', 'client_funds', 'active'],
  'an admin registers a client_funds account (IBAN and BIC normalised)');
select is(public.register_bank_account('register-ba-0001', '00000000-0000-0000-0000-00000000000a',
  'Compte séquestre', 'fr14 2004 1010 0505 0001 3m02 606', 'EUR', 'camt053', 'psstfrppxxx'),
  (select v from t where k = 'ba'), 'a replay returns the same account');
select throws_ok($$ select public.register_bank_account('register-ba-0001', '00000000-0000-0000-0000-00000000000a',
  'Autre libellé', 'FR1420041010050500013M02606', 'EUR', 'camt053') $$, '22023', null,
  'the same key for another request is refused');
select throws_ok($$ select public.register_bank_account('register-ba-0002', '00000000-0000-0000-0000-00000000000a',
  'Faux', 'FR1420041010050500013M02607', 'EUR', 'camt053') $$, '23514', 'invalid IBAN', 'an invalid IBAN is refused');
select throws_ok($$ select public.register_bank_account('register-ba-0003', '00000000-0000-0000-0000-00000000000a',
  'Doublon', 'FR1420041010050500013M02606', 'EUR', 'csv') $$, '23505', 'this IBAN is already registered',
  'an IBAN is registered once per currency');
select throws_ok($$ select public.close_bank_account('close-ba-0001', '80000000-0000-0000-0000-000000000001', 'moved') $$,
  '23514', 'the bank account still holds client money', 'an account holding client money cannot be closed');
select throws_ok(format($$ select public.close_bank_account('close-ba-0002', %L, ' ') $$, (select v from t where k = 'ba')),
  '23514', 'a reason is required', 'closing needs a reason');
select lives_ok(format($$ select public.close_bank_account('close-ba-0003', %L, 'ouvert par erreur') $$, (select v from t where k = 'ba')),
  'an empty account is closed');
reset role;
select is((select array[status, (closed_on = private.paris_today())::text] from public.bank_account
           where id = (select v from t where k = 'ba')), array['closed', 'true'], 'closed today');
select pg_temp.as_user('10000000-0000-0000-0000-000000000001', 'aal2');
set local role authenticated;
select throws_ok($$ select public.register_bank_account('register-ba-0004', '00000000-0000-0000-0000-00000000000a',
  'Ops', 'FR7630004000031234567890143', 'EUR', 'csv') $$, '42501', null, 'ops managers do not register bank accounts');
reset role;
select pg_temp.as_user('10000000-0000-0000-0000-000000000004', 'aal1');
set local role authenticated;
select throws_ok($$ select public.register_bank_account('register-ba-0005', '00000000-0000-0000-0000-00000000000a',
  'Admin aal1', 'FR7630004000031234567890143', 'EUR', 'csv') $$, '42501', null, 'nor admins without two-factor');
reset role;

-- Read access (RLS) ---------------------------------------------------------------------------------------
-- A payment of portfolio B for the collector; payment 1 stays on portfolio A.
select pg_temp.as_user('10000000-0000-0000-0000-000000000001', 'aal2');
set local role authenticated;
select is((select count(*)::int from public.bank_account), 4, 'ops managers see the servicer''s bank accounts');
select is((select count(*)::int from public.payment), 3, 'and every payment, unmatched ones included');
select is((select count(*)::int from public.ledger_account
           where book in ('client_money_cash', 'unallocated_payment', 'client_payable')), 3,
  'and the client-money ledger accounts (cash, pooled unallocated, client A''s payable)');
select is((select count(*)::int from public.ledger_entry where entry_type = 'cash_in'), 2, 'and the cash entries');
select ok((select count(*) from public.client_money_balances('00000000-0000-0000-0000-0000000000a1')) = 1,
  'and client money balances');
reset role;

select pg_temp.as_user('10000000-0000-0000-0000-000000000002', 'aal2');
set local role authenticated;
select is((select count(*)::int from public.bank_account), 0, 'collectors see no bank account');
select is((select array_agg(id) from public.payment), array['90000000-0000-0000-0000-000000000002'::uuid],
  'collectors see only the payments of their portfolios (never unmatched ones)');
select is((select count(*)::int from public.ledger_account
           where book in ('client_money_cash', 'unallocated_payment', 'client_payable')), 0,
  'nor any client-money ledger account (M2a risk #6)');
select is((select count(*)::int from public.ledger_entry where portfolio_id is null), 0, 'nor cash, forward or refund entries');
select throws_ok($$ select * from public.client_money_balances('00000000-0000-0000-0000-0000000000a2') $$, '42501', null,
  'nor client money balances');
select throws_ok(format($$ select public.ledger_balance(%L) $$,
  (select id from public.ledger_account where book = 'client_money_cash' limit 1)), '42501', null,
  'nor the cash balance');
select is((select count(*)::int from public.payment_reference), 1, 'they read the references of their portfolio');
reset role;

select pg_temp.as_user('10000000-0000-0000-0000-000000000003', 'aal1');
set local role authenticated;
select is((select count(*)::int from public.bank_account) + (select count(*)::int from public.payment), 0,
  'clients see no bank account and no payment (bank lines carry third-party data)');
select is((select array_agg(distinct book) from public.ledger_account
           where book in ('client_money_cash', 'unallocated_payment', 'client_payable')), array['client_payable'],
  'client A sees its own payable, not the cash or the pooled unallocated money');
select is((select count(*)::int from public.ledger_account where client_organization_id = '00000000-0000-0000-0000-0000000000a2'), 0,
  'nor anything of client B');
select is((select count(*)::int from public.ledger_entry where entry_type = 'forward'), 1, 'it sees the forward made to it');
select is((select count(*)::int from public.payment_reference where account_id = '30000000-0000-0000-0000-0000000000a1'), 2,
  'and the references of its accounts (to print on letters), retired ones included');
select is((select count(*)::int from public.payment_reference where client_organization_id <> '00000000-0000-0000-0000-0000000000a1'), 0,
  'not client B''s');
select throws_ok(format($$ select public.ledger_balance(%L) $$,
  (select id from public.ledger_account where book = 'unallocated_payment' limit 1)), '42501', null,
  'and cannot read the pooled balance');
reset role;

select pg_temp.as_user('10000000-0000-0000-0000-000000000005', 'aal1');
set local role authenticated;
select is((select count(*)::int from public.payment_reference where client_organization_id = '00000000-0000-0000-0000-0000000000a1'), 0,
  'client B never sees client A''s references');
reset role;

select pg_temp.as_user('10000000-0000-0000-0000-000000000001', 'aal1');
set local role authenticated;
select is((select count(*)::int from public.bank_account) + (select count(*)::int from public.payment)
          + (select count(*)::int from public.payment_reference), 0, 'staff below two-factor see nothing');
reset role;

create or replace function pg_temp.write_attempts() returns setof text language sql as $$
  values ($q$insert into public.bank_account (organization_id, iban, currency, label, feed, opened_on)
             values ('00000000-0000-0000-0000-00000000000a', 'FR7630004000031234567890143', 'EUR', 'x', 'csv', '2026-01-01')$q$),
         ($q$insert into public.payment (organization_id, bank_account_id, channel, method, amount_minor, currency, booking_date)
             values ('00000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000001', 'csv', 'sct', 1, 'EUR', '2026-03-01')$q$),
         ($q$insert into public.payment_reference (organization_id, client_organization_id, portfolio_id, account_id, rf)
             values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1',
                     '30000000-0000-0000-0000-0000000000b1', 'RF18539007547034')$q$),
         ($q$update public.payment set status = 'allocated'$q$), ($q$update public.bank_account set label = 'x'$q$),
         ($q$update public.payment_reference set status = 'retired'$q$);
$$;
create or replace function pg_temp.refused_writes() returns integer language plpgsql as $$
declare q text; n integer := 0;
begin
  for q in select * from pg_temp.write_attempts() loop
    begin execute q; exception when insufficient_privilege then n := n + 1; end;
  end loop;
  return n;
end $$;
select pg_temp.as_user('10000000-0000-0000-0000-000000000004', 'aal2');
set local role authenticated;
select is(pg_temp.refused_writes(), 6, 'signed-in users (even admins) write none of these tables directly');
reset role;

select * from finish();
rollback;
