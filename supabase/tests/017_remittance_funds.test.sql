-- M2c-1 (M2-12): the funds ledger. Two funds closed in every entry (I2′), the 4679 / 4689 mirror (I12), the shapes of
-- the thirteen M2c types (I3′), the lock decided by the lines and the remit lock, the per-client running balance of 4670
-- with its commit guard (I13, LG008), the pending queue of remittance items, the own bank account, one client_funds
-- account per currency, our own transfers classified at import, bank lines booked in the funds (fees, top-ups, the
-- servicer's loss on a return larger than its payment, OQ-34), the nightly checks (I8′, I12, I13, I14, I19) and the read
-- policies. Design docs/design/m2c-remittances.md §5, §6, §7, §12, §13, §15, §18; ADR-0014.
-- Servicer aa: the shapes and the §7 worked example, posted directly through private.ledger_post_set (no bank lines:
-- I19 flags them, which is checked last). Servicer bb: a statement imported, booked by the debit job's path and by ops,
-- with 5120 = the bank's closing balance and no violation.
begin;
select plan(117);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo SAS'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Autre cabinet SAS'),
  ('00000000-0000-0000-0000-0000000000cc', 'servicer', 'Troisième cabinet SAS');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Martin SAS'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Lilas Finance'),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Bleu SARL'),
  ('00000000-0000-0000-0000-0000000000c1', 'creditor_client', '00000000-0000-0000-0000-0000000000cc', 'Vert SAS');
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@funds.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '06']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000bb', 'admin');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', 'P1'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2', 'P2');
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1');
-- cf: the dedicated account (5120); own: the servicer's own account (5122); the same for servicer bb
insert into public.bank_account (id, organization_id, purpose, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000cf', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
   'FR3430001007940000000001001', 'EUR', 'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000aa', 'own',
   'FR1420041010050500013M02606', 'EUR', 'Compte propre', null, '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000bf', '00000000-0000-0000-0000-0000000000bb', 'client_funds',
   'FR7630004000031234567890143', 'EUR', 'Fonds de tiers B', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000bb', 'own',
   'FR7030001007940000000002002', 'EUR', 'Compte propre B', null, '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000cc', '00000000-0000-0000-0000-0000000000cc', 'client_funds',
   'FR8130001007940000000005005', 'EUR', 'Fonds de tiers C', 'camt053', '2026-01-01');

create or replace function pg_temp.f(p_n text) returns uuid language sql as $$
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.it(p_n text) returns uuid language sql as $$
  select ('c1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.pay(p_n text) returns uuid language sql as $$
  select ('f1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
-- A file of servicer aa with one invoice owed (opening as an adjustment).
create or replace function pg_temp.file(p_n text, p_portfolio uuid, p_amount bigint) returns void language plpgsql as $$
begin
  insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                              legal_regime, currency, status)
  select pg_temp.f(p_n), p.organization_id, p.client_organization_id, p.id, 'b2b_invoice', 'D-' || p_n,
         'commercial_b2b', 'EUR', 'in_collection'
  from public.portfolio p where p.id = p_portfolio;
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type,
                                             valid_from)
  select pg_temp.f(p_n), p.client_organization_id, p.organization_id, 'mandate_amicable', '2026-09-30'
  from public.portfolio p where p.id = p_portfolio;
  insert into public.claim_item (id, account_id, kind, ref, due_date, original_minor)
  values (pg_temp.it(p_n), pg_temp.f(p_n), 'invoice', 'F-' || p_n, '2026-09-01', p_amount);
  perform private.ledger_post('00000000-0000-0000-0000-0000000000aa', 'adjustment', '2026-09-30', 'funds-owe-' || p_n,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', pg_temp.it(p_n), 'component', 'principal'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', 'principal')),
    jsonb_build_object('account_id', pg_temp.f(p_n), 'reason', 'ouverture (test)'));
end $$;
-- A statement being imported, of a bank account.
create or replace function pg_temp.stmt(p_id uuid, p_bank uuid) returns void language plpgsql as $$
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  select p_id, b.organization_id, b.id, 'EUR', b.feed, 'r.xml', encode(sha256(convert_to(p_id::text, 'UTF8')), 'hex'), 1,
         'test/' || p_id
  from public.bank_account b where b.id = p_bank;
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = p_id;
end $$;
-- A payment of servicer aa on its dedicated account (its line, the payment, its cash_in), matched to a file and allocated.
create or replace function pg_temp.collect(p_n text, p_amount bigint) returns void language plpgsql as $$
declare s uuid := ('e1000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  perform pg_temp.stmt(s, '80000000-0000-0000-0000-0000000000cf');
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, 1, 't:' || s, 'credit',
          p_amount, 'EUR', '2026-10-12', 'debtor_credit', 'E2E-' || p_n);
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, payer_name, end_to_end_id)
  values (pg_temp.pay(p_n), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s,
          'camt053', 'sct', p_amount, 'EUR', '2026-10-12', 'PAYEUR ' || p_n, 'E2E-' || p_n);
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_in', '2026-10-12', 'cash_in:' || s || ':2026-10-12',
          'bank_statement', s::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cf'),
    (1, 2, 'unallocated_payment', -p_amount, 'EUR', null);
  perform private.ledger_post_set();
  update public.payment set account_id = pg_temp.f(p_n), status = 'matched', match_method = 'rf_structured',
                            matched_at = now()
  where id = pg_temp.pay(p_n);
  perform private.allocation_begin();
  insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy, inputs_hash)
  values (pg_temp.pay(p_n), 1, pg_temp.f(p_n), 'allocate', '2026-10-12',
          '{"accessory_rank": "before_principal", "unclassified": "last"}', repeat('0', 64));
  insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
  values (pg_temp.pay(p_n), 1, pg_temp.it(p_n), 'principal', p_amount);
  perform private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1');
end $$;
-- A funds entry through private.ledger_post_set. Lines: [[book, amount, bank?]] with bank cf | own | cfb | ownb.
create or replace function pg_temp.fund(p_type text, p_key text, p_client text, p_source text, p_lines jsonb,
                                        p_date date default '2026-11-02', p_reason text default null,
                                        p_org uuid default '00000000-0000-0000-0000-0000000000aa')
returns uuid language plpgsql as $$
declare v uuid;
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason)
  values (1, p_org, p_type, p_date, p_key,
          case p_client when 'a1' then '00000000-0000-0000-0000-0000000000a1'::uuid
                        when 'a2' then '00000000-0000-0000-0000-0000000000a2'::uuid
                        when 'b1' then '00000000-0000-0000-0000-0000000000b1'::uuid
                        when 'c1' then '00000000-0000-0000-0000-0000000000c1'::uuid end,
          split_part(p_source, '/', 1), nullif(split_part(p_source, '/', 2), ''), p_reason);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
  select 1, x.ord::integer, x.l ->> 0, (x.l ->> 1)::bigint, 'EUR',
         case x.l ->> 2 when 'cf' then '80000000-0000-0000-0000-0000000000cf'::uuid
                        when 'own' then '80000000-0000-0000-0000-0000000000a0'::uuid
                        when 'cfb' then '80000000-0000-0000-0000-0000000000bf'::uuid
                        when 'ownb' then '80000000-0000-0000-0000-0000000000b0'::uuid
                        when 'cfc' then '80000000-0000-0000-0000-0000000000cc'::uuid end
  from jsonb_array_elements(p_lines) with ordinality x (l, ord);
  select r.entry_id into v from private.ledger_post_set() r;
  return v;
end $$;
create or replace function pg_temp.bal(p_book text, p_client text default null,
                                       p_org uuid default '00000000-0000-0000-0000-0000000000aa')
returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.organization_id = p_org and la.book = p_book
    and (p_client is null or la.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_client)::uuid);
$$;
create or replace function pg_temp.fund_sum(p_money_of text, p_org uuid default '00000000-0000-0000-0000-0000000000aa')
returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  join public.ledger_book b on b.code = la.book
  where la.organization_id = p_org and b.money_of = p_money_of;
$$;
create or replace function pg_temp.lock_held(p_key text) returns boolean language sql as $$
  select exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.pid = pg_backend_pid()
                   and l.objid::bigint = (hashtext(p_key)::bigint & x'FFFFFFFF'::bigint));
$$;
create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
grant execute on all functions in schema pg_temp to authenticated;
create temporary table t (k text primary key, v uuid) on commit drop;
grant all on t to authenticated;

select pg_temp.file('01', '20000000-0000-0000-0000-0000000000a1', 200000);
select pg_temp.file('02', '20000000-0000-0000-0000-0000000000a2', 512000);
select pg_temp.collect('01', 200000);   -- E2: P1 allocated on Martin's file
select pg_temp.collect('02', 512000);   -- E3: P2 allocated on Lilas's file
insert into t select 'e2', id from public.ledger_entry where payment_id = pg_temp.pay('01') and entry_type = 'allocation';

-- Structure ---------------------------------------------------------------------------------------
select is((select string_agg(code || '=' || account_number || '/' || money_of || '/' || dimension, ' ' order by account_number)
           from public.ledger_book where account_number in ('4679', '4689', '5122', '4111', '4112', '44571', '44574',
                                                            '6270', '6780')),
  'commission_receivable=4111/servicer/client client_advance_receivable=4112/servicer/client '
  || 'vat_collected=44571/servicer/pooled vat_pending=44574/servicer/pooled due_to_servicer=4679/client/pooled '
  || 'due_from_client_funds=4689/servicer/pooled own_cash=5122/servicer/bank bank_fees=6270/servicer/pooled '
  || 'servicer_losses=6780/servicer/pooled',
  'the nine M2c books, 4679 in the client fund and the other eight in the servicer''s fund');
select is((select client_visible from public.ledger_book where code = 'servicer_revenue'), false,
  '7060 is no longer client-visible');
select is((select count(*)::int from public.ledger_entry_type
           where code in ('commission_invoice', 'commission_credit_note', 'client_settlement', 'remittance',
                          'servicer_sweep', 'servicer_top_up', 'bank_fee', 'client_advance', 'servicer_loss',
                          'client_payment_own', 'client_payment_dedicated', 'client_refund_own', 'advance_write_off')),
  13, 'the thirteen M2c entry types');
select is((select count(*)::int from public.ledger_entry_type
           where allowed_books && array['debtor_receivable', 'owner_claim', 'unallocated_payment']
             and code in ('commission_invoice', 'commission_credit_note', 'client_settlement', 'remittance',
                          'servicer_sweep', 'servicer_top_up', 'bank_fee', 'client_advance', 'servicer_loss',
                          'client_payment_own', 'client_payment_dedicated', 'client_refund_own', 'advance_write_off')),
  0, 'no M2c type touches 1100, 3100 or 4710 (L111-8; unallocated money is never remitted)');
select is((select array_agg(code order by code) from public.ledger_entry_type where 'servicer_revenue' = any (allowed_books)),
  array['commission_credit_note', 'commission_invoice'], '7060 is reached only by the two commission types (I10′)');
select is((select count(*)::int from public.ledger_entry_type
           where code in ('opening', 'adjustment', 'cash_in', 'allocation', 'forward', 'cash_out', 'netting')
             and allowed_books && array['due_to_servicer', 'due_from_client_funds', 'own_cash', 'commission_receivable',
                                        'client_advance_receivable', 'vat_collected', 'vat_pending', 'servicer_revenue',
                                        'bank_fees', 'servicer_losses']),
  0, 'no M2b type reaches a servicer-fund book or 4679 (I10′)');
select is((select count(*)::int from pg_trigger
           where tgname in ('ledger_posting_client_payable', 'client_payable_in_credit', 'bank_line_booking_guard',
                            'bank_line_booking_complete', 'bank_line_booking_append_only', 'bank_transfer_guard',
                            'bank_transfer_no_delete', 'bank_statement_purpose_guard')
             and tgenabled = 'A'), 8, 'the funds'' triggers fire always (owner and replica included)');
select is((select tgdeferrable and tginitdeferred from pg_trigger where tgname = 'client_payable_in_credit'), true,
  'the 4670 guard is checked at commit (LG008)');
select is((select array_agg(relrowsecurity order by relname) from pg_class
           where oid in ('public.bank_transfer'::regclass, 'public.bank_line_booking'::regclass,
                         'private.client_payable_balance'::regclass, 'private.remittance_pending'::regclass)),
  array[true, true, true, true], 'RLS on the new tables');

-- I3′: the thirteen shapes, the §7 worked example (Martin 15 %, Lilas marginal; VAT 20 % on encaissements) -------------
select isnt(pg_temp.fund('commission_invoice', 'inv:rv1:martin', 'a1', 'commission_invoice/FC-2026-000001',
  '[["commission_receivable", 36000], ["servicer_revenue", -30000], ["vat_pending", -6000]]'), null,
  'C1 commission_invoice: +4111 TTC / −7060 HT / −44574 VAT');
select isnt(pg_temp.fund('commission_invoice', 'inv:rv2:lilas', 'a2', 'commission_invoice/FC-2026-000002',
  '[["commission_receivable", 60864], ["servicer_revenue", -50720], ["vat_pending", -10144]]'), null, 'C2 likewise');
select throws_ok($$ select pg_temp.fund('commission_invoice', 'inv:bad:0001', 'a1', 'commission_invoice/FC-X',
  '[["commission_receivable", -36000], ["servicer_revenue", 30000], ["vat_pending", 6000]]') $$, 'LG001', null,
  'an invoice that credits 4111 is not an invoice (a credit note is)');
select isnt(pg_temp.fund('remittance', 'remit:tr-rv1', 'a1', 'bank_transfer/RMT000000000001',
  '[["client_payable", 164000], ["client_money_cash", -164000, "cf"]]', '2026-11-03'), null,
  'E5 remittance: +4670[Martin] N / −5120 N');
select throws_ok($$ select pg_temp.fund('remittance', 'remit:bad:0001', 'a1', 'bank_transfer/x',
  '[["client_payable", -100], ["client_money_cash", 100, "cf"]]', '2026-11-03') $$, 'LG001', null,
  'a remittance never credits 4670');
select isnt(pg_temp.fund('client_settlement', 'settle:rv1', 'a1', 'remittance_run/RV-2026-000001',
  '[["client_payable", 36000], ["due_to_servicer", -36000], ["due_from_client_funds", 36000],
    ["commission_receivable", -36000], ["vat_pending", 6000], ["vat_collected", -6000]]', '2026-11-03'), null,
  'E6 client_settlement: +4670 D / −4679 D ‖ +4689 D / −4111 Dc; VAT pending → due');
select throws_ok($$ select pg_temp.fund('client_settlement', 'settle:bad:0001', 'a1', 'remittance_run/x',
  '[["client_payable", 100], ["due_to_servicer", -100], ["due_from_client_funds", 100],
    ["commission_receivable", -200], ["client_advance_receivable", 100]]', '2026-11-03') $$, 'LG001', null,
  'a settlement never raises an advance (4112 is only credited)');
select throws_ok($$ select pg_temp.fund('client_settlement', 'settle:bad:0002', 'a1', 'remittance_run/x',
  '[["client_payable", 100], ["due_to_servicer", -100], ["due_from_client_funds", 100],
    ["commission_receivable", -100], ["vat_pending", -20], ["vat_collected", 20]]', '2026-11-03') $$, 'LG001', null,
  'a settlement moves VAT from pending to due, never back');
select isnt(pg_temp.fund('remittance', 'remit:tr-rv2', 'a2', 'bank_transfer/RMT000000000002',
  '[["client_payable", 451136], ["client_money_cash", -451136, "cf"]]', '2026-11-03'), null, 'E7 remittance (Lilas)');
select isnt(pg_temp.fund('client_settlement', 'settle:rv2', 'a2', 'remittance_run/RV-2026-000002',
  '[["client_payable", 60864], ["due_to_servicer", -60864], ["due_from_client_funds", 60864],
    ["commission_receivable", -60864], ["vat_pending", 10144], ["vat_collected", -10144]]', '2026-11-03'), null,
  'E8 client_settlement (Lilas)');
select isnt(pg_temp.fund('servicer_sweep', 'sweep:tr-swp1', null, 'bank_transfer/SWP000000000001',
  '[["due_to_servicer", 96864], ["client_money_cash", -96864, "cf"], ["own_cash", 96864, "own"],
    ["due_from_client_funds", -96864]]', '2026-11-04'), null, 'E9 servicer_sweep: +4679 / −5120 ‖ +5122 / −4689');
select throws_ok($$ select pg_temp.fund('servicer_sweep', 'sweep:bad:0001', null, 'bank_transfer/x',
  '[["due_to_servicer", -100], ["client_money_cash", 100, "cf"], ["own_cash", -100, "own"],
    ["due_from_client_funds", 100]]', '2026-11-04') $$, 'LG001', null, 'a sweep never brings money in');
select is(array[pg_temp.bal('client_money_cash'), pg_temp.bal('unallocated_payment'), pg_temp.bal('client_payable', 'a1'),
                pg_temp.bal('client_payable', 'a2'), pg_temp.bal('due_to_servicer'), pg_temp.bal('own_cash'),
                pg_temp.bal('servicer_revenue'), pg_temp.bal('vat_collected'), pg_temp.bal('vat_pending'),
                pg_temp.bal('commission_receivable'), pg_temp.bal('due_from_client_funds')],
  array[0, 0, 0, 0, 0, 96864, -80720, -16144, 0, 0, 0]::bigint[],
  'after E9 (§7.2): clients paid, the servicer swept; 5122 = 96 864, 7060 = −80 720, 44571 = −16 144');
select is(array[pg_temp.fund_sum('client'), pg_temp.fund_sum('servicer')], array[0, 0]::bigint[],
  'each fund nets to zero (I8′ and the servicer''s fund)');

-- A remitted collection reversed: 4670 would be in debit (LG008) until the servicer advances it (§13 #1).
insert into t select 'r2', z.entry_id from private.ledger_reverse((select v from t where k = 'e2'), 'reverse-e2-0001',
  'Imputation annulée (test)', '2026-11-05') z;
select is(pg_temp.bal('client_payable', 'a1'), 200000::bigint, 'the reversal leaves Martin''s 4670 in debit');
select throws_ok($$ select private.ledger_check_now() $$, 'LG008', null,
  'a commit leaving a client''s 4670 in debit is refused (I13): no other client''s money covers it');
select throws_ok($$ select pg_temp.fund('client_advance', 'adv:bad:0001', 'a1', 'client_advance/x',
  '[["due_to_servicer", -100], ["client_payable", 100], ["client_advance_receivable", -100],
    ["due_from_client_funds", 100]]', '2026-11-05') $$, 'LG001', null, 'an advance never debits 4670');
insert into t select 'a1', pg_temp.fund('client_advance', 'adv:' || (select v from t where k = 'e2'), 'a1',
  'client_advance/c0000000-0000-0000-0000-000000000001',
  '[["due_to_servicer", 200000], ["client_payable", -200000], ["client_advance_receivable", 200000],
    ["due_from_client_funds", -200000]]', '2026-11-05');
select lives_ok($$ select private.ledger_check_now() $$, 'A1 client_advance: +4679 / −4670 ‖ +4112 / −4689 covers it');
select isnt(pg_temp.fund('servicer_top_up', 'topup:line-t1', null, 'bank_transfer/TOP000000000001',
  '[["client_money_cash", 200000, "cf"], ["due_to_servicer", -200000], ["due_from_client_funds", 200000],
    ["own_cash", -200000, "own"]]', '2026-11-06'), null, 'T1 servicer_top_up: +5120 / −4679 ‖ +4689 / −5122');
select throws_ok($$ select pg_temp.fund('servicer_top_up', 'topup:bad:0001', null, 'bank_transfer/x',
  '[["client_money_cash", -100, "cf"], ["due_to_servicer", 100], ["due_from_client_funds", -100],
    ["own_cash", 100, "own"]]', '2026-11-06') $$, 'LG001', null, 'a top-up never takes money out');
select isnt(pg_temp.fund('bank_fee', 'fee:line-f1', null, 'bank_transaction/f1',
  '[["due_to_servicer", 1200], ["client_money_cash", -1200, "cf"], ["bank_fees", 1200],
    ["due_from_client_funds", -1200]]', '2026-11-06'), null, 'bank_fee: +4679 / −5120 ‖ +6270 / −4689 (the servicer''s cost)');
select throws_ok($$ select pg_temp.fund('bank_fee', 'fee:bad:0001', null, 'bank_transaction/x',
  '[["due_to_servicer", -100], ["client_money_cash", 100, "cf"], ["bank_fees", -100],
    ["due_from_client_funds", 100]]', '2026-11-06') $$, 'LG001', null, 'a fee is a debit of the account');
select isnt(pg_temp.fund('servicer_loss', 'loss:line-l1', null, 'bank_transaction/l1',
  '[["due_to_servicer", 500], ["client_money_cash", -500, "cf"], ["servicer_losses", 500],
    ["due_from_client_funds", -500]]', '2026-11-06', 'OQ-34 (test)'), null, 'servicer_loss: +4679 / −5120 ‖ +6780 / −4689');
select throws_ok($$ select pg_temp.fund('servicer_loss', 'loss:bad:0001', null, 'bank_transaction/x',
  '[["due_to_servicer", -100], ["client_money_cash", 100, "cf"], ["servicer_losses", -100],
    ["due_from_client_funds", 100]]', '2026-11-06', 'x') $$, 'LG001', null, 'a loss is a debit of the account');
select throws_ok($$ select pg_temp.fund('servicer_loss', 'loss:bad:0002', null, 'bank_transaction/x',
  '[["due_to_servicer", 100], ["client_money_cash", -100, "cf"], ["servicer_losses", 100],
    ["due_from_client_funds", -100]]', '2026-11-06') $$, 'LG006', null, 'a loss needs its motif');
select isnt(pg_temp.fund('client_payment_own', 'cpo:doc-1', 'a1', 'document/d1',
  '[["own_cash", 50000, "own"], ["client_advance_receivable", -50000]]', '2026-11-07', 'virement du mandant'), null,
  'client_payment_own: +5122 / −4112 (an advance repaid to the own account)');
select throws_ok($$ select pg_temp.fund('client_payment_own', 'cpo:bad:0001', 'a1', 'document/x',
  '[["own_cash", -100, "own"], ["commission_receivable", 100]]', '2026-11-07', 'x') $$, 'LG001', null,
  'a client payment never debits 4111');
select isnt(pg_temp.fund('client_payment_dedicated', 'cpd:line-p1', 'a1', 'bank_transaction/p1',
  '[["client_money_cash", 20000, "cf"], ["due_to_servicer", -20000], ["due_from_client_funds", 20000],
    ["client_advance_receivable", -20000]]', '2026-11-07', 'paiement reçu sur le compte dédié'), null,
  'client_payment_dedicated: +5120 / −4679 ‖ +4689 / −4112');
select throws_ok($$ select pg_temp.fund('client_payment_dedicated', 'cpd:bad:0001', 'a1', 'bank_transaction/x',
  '[["client_money_cash", 100, "cf"], ["due_to_servicer", -100], ["due_from_client_funds", 100],
    ["commission_receivable", -100], ["vat_pending", -20], ["vat_collected", 20]]', '2026-11-07', 'x') $$, 'LG001', null,
  'its VAT pair moves pending to due');
select isnt(pg_temp.fund('commission_credit_note', 'crn:rv3:lilas', 'a2', 'commission_invoice/FC-2026-000003',
  '[["commission_receivable", -12000], ["servicer_revenue", 10000], ["vat_collected", 2000]]', '2026-11-07'), null,
  'commission_credit_note: −4111 / +7060 / +44571 (the corrected invoice was settled)');
select throws_ok($$ select pg_temp.fund('commission_credit_note', 'crn:bad:0001', 'a2', 'commission_invoice/x',
  '[["commission_receivable", 100], ["servicer_revenue", -100]]', '2026-11-07') $$, 'LG001', null,
  'a credit note never debits 4111');
select isnt(pg_temp.fund('client_refund_own', 'cro:doc-2', 'a2', 'document/d2',
  '[["commission_receivable", 12000], ["own_cash", -12000, "own"]]', '2026-11-07', 'avoir remboursé'), null,
  'client_refund_own: +4111 / −5122');
select throws_ok($$ select pg_temp.fund('client_refund_own', 'cro:bad:0001', 'a2', 'document/x',
  '[["commission_receivable", -100], ["own_cash", 100, "own"]]', '2026-11-07', 'x') $$, 'LG001', null,
  'a refund leaves the own account');
insert into t select 'w1', pg_temp.fund('advance_write_off', 'awo:doc-3', 'a1', 'document/d3',
  '[["servicer_losses", 130000], ["client_advance_receivable", -130000]]', '2026-11-07', 'abandon décidé (test)');
select isnt((select v from t where k = 'w1'), null, 'advance_write_off: +6780 / −4112');
select throws_ok($$ select pg_temp.fund('advance_write_off', 'awo:bad:0001', 'a1', 'document/x',
  '[["servicer_losses", -100], ["client_advance_receivable", 100]]', '2026-11-07', 'x') $$, 'LG001', null,
  'a write-off lowers the advance');
select is(array[pg_temp.bal('client_advance_receivable', 'a1'), pg_temp.bal('commission_receivable', 'a2'),
                pg_temp.fund_sum('client'), pg_temp.fund_sum('servicer'),
                pg_temp.bal('due_to_servicer') + pg_temp.bal('due_from_client_funds')],
  array[0, 0, 0, 0, 0]::bigint[], 'the advance is cleared, the refund paid; both funds and the mirror net to zero');

-- I2′, I12 and the books: the funds stay closed ---------------------------------------------------------------
select throws_ok($$ select pg_temp.fund('bank_fee', 'fee:bad:0002', null, 'bank_transaction/x',
  '[["due_to_servicer", 100], ["client_money_cash", -100, "cf"]]', '2026-11-06') $$, 'LG001', null,
  '4679 without 4689 is refused (the mirror, I12)');
select throws_ok($$ select pg_temp.fund('commission_invoice', 'inv:bad:0002', 'a1', 'commission_invoice/x',
  '[["client_payable", 100], ["servicer_revenue", -100]]') $$, 'LG002', null,
  'Dr 4670 / Cr 7060 is refused: collections never reach the servicer''s revenue directly (M2-12)');
update public.ledger_entry_type set allowed_books = allowed_books || array['client_payable'] where code = 'commission_invoice';
select throws_ok($$ select pg_temp.fund('commission_invoice', 'inv:bad:0003', 'a1', 'commission_invoice/x',
  '[["client_payable", 100], ["servicer_revenue", -100]]') $$, 'LG001', null,
  'and a type allowed to try would still leave both funds open (I2′)');
update public.ledger_entry_type set allowed_books = array['commission_receivable', 'servicer_revenue', 'vat_pending',
                                                          'vat_collected'] where code = 'commission_invoice';
select throws_ok($$ do $d$ begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type, source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_in', '2026-11-06', 'cash_in:bad:0002', 'bank_statement', 'x');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', 100, 'EUR', '80000000-0000-0000-0000-0000000000cf'), (1, 2, 'due_to_servicer', -100, 'EUR', null);
  perform private.ledger_post_set();
end $d$ $$, 'LG002', null, 'no M2b type reaches 4679 (debtor money as the servicer''s share)');
select throws_ok($$ do $d$ begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type, source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_in', '2026-11-06', 'cash_in:bad:0001', 'bank_statement', 'x');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'own_cash', 100, 'EUR', '80000000-0000-0000-0000-0000000000a0'), (1, 2, 'unallocated_payment', -100, 'EUR', null);
  perform private.ledger_post_set();
end $d$ $$, 'LG002', null, 'nor a servicer-fund book (debtor money into own cash)');
select throws_ok($$ select pg_temp.fund('bank_fee', 'fee:bad:0003', null, 'bank_transaction/x',
  '[["due_to_servicer", 100], ["client_money_cash", -100, "own"], ["bank_fees", 100], ["due_from_client_funds", -100]]',
  '2026-11-06') $$, 'LG002', null, '5120 on the own account is refused');
select throws_ok($$ select pg_temp.fund('servicer_sweep', 'sweep:bad:0002', null, 'bank_transfer/x',
  '[["due_to_servicer", 100], ["client_money_cash", -100, "cf"], ["own_cash", 100, "cf"], ["due_from_client_funds", -100]]',
  '2026-11-06') $$, 'LG002', null, '5122 on the dedicated account is refused');
select throws_ok($$ insert into public.ledger_account (organization_id, book, currency, bank_account_id)
  values ('00000000-0000-0000-0000-0000000000aa', 'own_cash', 'EUR', '80000000-0000-0000-0000-0000000000cf') $$,
  'LG002', null, 'even written directly: a 5122 account lives on an own bank account');
select throws_ok($$ select pg_temp.fund('bank_fee', 'fee:bad:0004', 'a1', 'bank_transaction/x',
  '[["due_to_servicer", 100], ["client_money_cash", -100, "cf"], ["bank_fees", 100], ["due_from_client_funds", -100]]',
  '2026-11-06') $$, 'LG006', null, 'a fee concerns no client');
select throws_ok($$ select pg_temp.fund('bank_fee', 'fee:bad:0005', null, 'document/x',
  '[["due_to_servicer", 100], ["client_money_cash", -100, "cf"], ["bank_fees", 100], ["due_from_client_funds", -100]]',
  '2026-11-06') $$, '23514', null, 'a fee names its bank line (R123-174: its document)');
select throws_ok($$ select private.ledger_post('00000000-0000-0000-0000-0000000000aa', 'bank_fee', '2026-11-06',
  'fee:bad:0006', '[{"book": "bank_fees", "amount_minor": 100, "currency": "EUR"},
                    {"book": "due_from_client_funds", "amount_minor": -100, "currency": "EUR"}]', '{}') $$,
  'LG006', null, 'ledger_post refuses every M2c type (ledger_post_set only)');

-- LG003: commission documents, settlements and write-offs are never reversed ----------------------------------
select throws_ok(format($$ select private.ledger_reverse(%L, 'rev-inv-0001', 'test') $$,
  (select id from public.ledger_entry where idempotency_key = 'inv:rv1:martin')), 'LG003', null,
  'an invoice is never reversed (a credit note corrects it)');
select throws_ok(format($$ select private.ledger_reverse(%L, 'rev-crn-0001', 'test', '2026-11-08') $$,
  (select id from public.ledger_entry where idempotency_key = 'crn:rv3:lilas')), 'LG003', null, 'nor a credit note');
select throws_ok(format($$ select private.ledger_reverse(%L, 'rev-set-0001', 'test', '2026-11-08') $$,
  (select id from public.ledger_entry where idempotency_key = 'settle:rv1')), 'LG003', null,
  'nor a settlement (it survives a returned payout)');
select throws_ok(format($$ select private.ledger_reverse(%L, 'rev-awo-0001', 'test', '2026-11-08') $$,
  (select v from t where k = 'w1')), 'LG003', null, 'nor a write-off');
select lives_ok(format($$ select private.ledger_reverse(%L, 'rev-fee-0001', 'frais remboursé par la banque', '2026-11-08') $$,
  (select id from public.ledger_entry where idempotency_key = 'fee:line-f1')), 'a fee is reversed, with a motif');

-- The lock decided by the lines, the remit lock (servicer cc: none of its locks taken yet) -----------------------
select isnt(pg_temp.fund('bank_fee', 'fee:cc-lock', null, 'bank_transaction/cc1',
  '[["due_to_servicer", 100], ["client_money_cash", -100, "cfc"], ["bank_fees", 100], ["due_from_client_funds", -100]]',
  '2026-11-06', null, '00000000-0000-0000-0000-0000000000cc'), null, 'a fee of servicer cc');
select is(array[pg_temp.lock_held('remit:00000000-0000-0000-0000-0000000000cc'),
                pg_temp.lock_held('payments:00000000-0000-0000-0000-0000000000cc')], array[true, false],
  'a writer of 4679 takes the remit lock; without a 4670 line, not the allocation lock');
select isnt(pg_temp.fund('client_advance', 'adv:cc-lock', 'c1', 'client_advance/c0000000-0000-0000-0000-0000000000c1',
  '[["due_to_servicer", 100], ["client_payable", -100], ["client_advance_receivable", 100], ["due_from_client_funds", -100]]',
  '2026-11-06', null, '00000000-0000-0000-0000-0000000000cc'), null, 'an advance of servicer cc');
select is(pg_temp.lock_held('payments:00000000-0000-0000-0000-0000000000cc'), true,
  'an entry with a 4670 line takes the allocation lock, whatever its type');

-- The running balance (I13) and the pending queue ------------------------------------------------------------
select is((select count(*)::int from (
             select la.client_organization_id, la.currency, sum(p.amount_minor) as s
             from public.ledger_account la join public.ledger_posting p on p.ledger_account_id = la.id
             where la.book = 'client_payable' group by 1, 2) x
           full join private.client_payable_balance b using (client_organization_id, currency)
           where x.s is distinct from b.balance_minor), 0, 'the running balance of each client = its 4670 postings');
select is((select string_agg(e.idempotency_key || ':' || q.kind || ':' || q.amount_minor, ' ' order by q.posted_at, q.ledger_entry_id)
           from private.remittance_pending q join public.ledger_entry e on e.id = q.ledger_entry_id
           where q.client_organization_id = '00000000-0000-0000-0000-0000000000a1'),
  (select string_agg(x, ' ') from (select e.idempotency_key || ':allocation:200000' as x from public.ledger_entry e
                                   where e.id = (select v from t where k = 'e2')
                                   union all select 'reverse-e2-0001:allocation_reversal:-200000'
                                   union all select 'adv:' || (select v from t where k = 'e2') || ':client_advance:200000') y),
  'Martin''s queue: the allocation, its reversal and the advance (settlements and remittances are not items)');
select is((select count(*)::int from (
             select b.client_organization_id, b.currency, -b.balance_minor as owed,
                    (select coalesce(sum(q.amount_minor), 0) from private.remittance_pending q
                     where q.client_organization_id = b.client_organization_id and q.currency = b.currency) as pending
             from private.client_payable_balance b
             where b.organization_id = '00000000-0000-0000-0000-0000000000aa') x
           where x.owed <> x.pending - (select coalesce(sum(p.amount_minor), 0)::bigint
                                        from public.ledger_entry e join public.ledger_posting p on p.entry_id = e.id
                                        join public.ledger_account la on la.id = p.ledger_account_id
                                        where la.book = 'client_payable'
                                          and la.client_organization_id = x.client_organization_id
                                          and e.entry_type in ('remittance', 'client_settlement'))), 0,
  'what each client is owed = its pending items less what remittances and settlements paid (I14 before runs)');
select pg_temp.fund('remittance', 'remit:over:0001', 'a2', 'bank_transfer/RMT000000000009',
  '[["client_payable", 100], ["client_money_cash", -100, "cf"]]', '2026-11-08');
select throws_ok($$ select private.ledger_check_now() $$, 'LG008', null,
  'a payout beyond what a client is owed fails at commit (LG008)');
-- (cover it, as M2c-6's booking-time cover does: an advance for the excess)
select pg_temp.fund('client_advance', 'adv:payout:over', 'a2', 'client_advance/c0000000-0000-0000-0000-000000000002',
  '[["due_to_servicer", 100], ["client_payable", -100], ["client_advance_receivable", 100], ["due_from_client_funds", -100]]',
  '2026-11-08');
select lives_ok($$ select private.ledger_check_now() $$, 'covered by an advance, it commits');

-- Bank accounts: own account, one client_funds per currency, statements of client_funds accounts only ---------
select pg_temp.as_user('04');
set local role authenticated;
insert into t select 'own2', public.register_bank_account('register-own-0001', '00000000-0000-0000-0000-0000000000aa',
  'Compte propre 2', 'FR0930001007940000000003003', 'EUR', 'camt053', null, null, 'own');
reset role;
select is((select array[purpose, coalesce(feed, '-'), status] from public.bank_account where id = (select v from t where k = 'own2')),
  array['own', '-', 'active'], 'an admin registers an own account (no statement feed)');
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok($$ select public.register_bank_account('register-cf-0002', '00000000-0000-0000-0000-0000000000aa',
  'Deuxième compte dédié', 'FR4530001007940000000004004', 'EUR', 'camt053') $$, '23505', null,
  'a second active client_funds account in a currency is refused (founder #14)');
reset role;
select throws_ok($$ insert into public.bank_statement (organization_id, bank_account_id, currency, format, file_name, file_sha256,
  size_bytes, storage_path) values ('00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000a0', 'EUR',
  'camt053', 'r.xml', repeat('c', 64), 1, 'test/own') $$, '23514', null, 'an own account''s statements are not imported');

-- Top-ups ordered by hand (TOP id) ---------------------------------------------------------------------------
select pg_temp.as_user('05');
set local role authenticated;
insert into t select 'top', (public.request_top_up('topup-req-0001', '80000000-0000-0000-0000-0000000000b0',
  '80000000-0000-0000-0000-0000000000bf', '2000', 'couvrir les frais') ->> 'transfer_id')::uuid;
select is((select array[kind, status, payee_iban, (end_to_end_id ~ '^TOP[0-9A-F]{12}$')::text, amount_minor::text]
           from public.bank_transfer where id = (select v from t where k = 'top')),
  array['top_up', 'ordered', 'FR7630004000031234567890143', 'true', '2000'],
  'ops order a top-up of the dedicated account from the own account: our TOP id, nothing booked');
select is((public.request_top_up('topup-req-0001', '80000000-0000-0000-0000-0000000000b0',
  '80000000-0000-0000-0000-0000000000bf', '2000', 'couvrir les frais') ->> 'transfer_id')::uuid,
  (select v from t where k = 'top'), 'a replay returns the same order');
select throws_ok($$ select public.request_top_up('topup-req-0002', '80000000-0000-0000-0000-0000000000bf',
  '80000000-0000-0000-0000-0000000000b0', '2000', 'x') $$, '23514', null, 'a top-up goes from the own account');
insert into t select 'top2', (public.request_top_up('topup-req-0003', '80000000-0000-0000-0000-0000000000b0',
  '80000000-0000-0000-0000-0000000000bf', '700', 'erreur') ->> 'transfer_id')::uuid;
select lives_ok(format($$ select public.cancel_top_up('topup-cancel-0001', %L, 'saisi par erreur') $$,
  (select v from t where k = 'top2')), 'a pending top-up is cancelled');
select throws_ok(format($$ select public.cancel_top_up('topup-cancel-0002', %L, 'encore') $$,
  (select v from t where k = 'top2')), '23514', 'the top-up is no longer pending', 'once');
reset role;
select pg_temp.as_user('06');
set local role authenticated;
select throws_ok($$ select public.close_bank_account('close-ownb-0001', '80000000-0000-0000-0000-0000000000b0', 'x') $$,
  '23514', 'transfers from or to this bank account are in flight', 'an own account with a top-up in flight stays open');
reset role;
select pg_temp.as_user('02');
set local role authenticated;
select throws_ok($$ select public.request_top_up('topup-req-0009', '80000000-0000-0000-0000-0000000000a0',
  '80000000-0000-0000-0000-0000000000cf', '100', 'x') $$, '42501', null, 'collectors order nothing');
reset role;

-- Our own transfers at import (servicer bb): classified whatever the parser read, never a debtor payment --------------
select is(array[private.bank_line_refined_kind('debtor_credit', 'credit', 'TOPABCDEF012345', null, '{}', '{}'),
                private.bank_line_refined_kind('debtor_credit', 'credit', 'E2E-1', 'FR7030001007940000000002002',
                                               array['FR7030001007940000000002002'], '{}'),
                private.bank_line_refined_kind('debtor_credit', 'credit', 'E2E-1', 'FR111', '{}', array['FR111']),
                private.bank_line_refined_kind('other_debit', 'debit', 'RMTABCDEF012345', null, '{}', '{}'),
                private.bank_line_refined_kind('other_debit', 'debit', 'SWPABCDEF012345', null, '{}', '{}'),
                private.bank_line_refined_kind('other_debit', 'debit', null, 'FR7030001007940000000002002',
                                               array['FR7030001007940000000002002'], '{}'),
                private.bank_line_refined_kind('own_transfer_in', 'credit', 'E2E-2', 'FR999', '{}', '{}'),
                private.bank_line_refined_kind('return', 'credit', 'TOPABCDEF012345', null, '{}', '{}'),
                private.bank_line_refined_kind('debtor_credit', 'credit', 'TOPAZ-2026', null, '{}', '{}'),
                private.bank_line_refined_kind('refund_out', 'debit', 'RFDABCDEF012345', 'FR7030001007940000000002002',
                                               array['FR7030001007940000000002002'], '{}')],
  array['own_transfer_in', 'own_transfer_in', 'client_transfer_in', 'transfer_out', 'transfer_out', 'transfer_out',
        'debtor_credit', 'return', 'debtor_credit', 'refund_out'],
  'TOP id or own IBAN → own_transfer_in; client IBAN → client_transfer_in; RMT/SWP id or own IBAN → transfer_out; '
  || 'a reading without evidence is read again; returns, refunds and look-alike ids stay what they are');
select pg_temp.stmt('b0000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-0000000000bf');
insert into private.bank_import_stage (statement_id, line_no, section_no, dedup_key, direction, amount_minor, currency,
                                       booking_date, end_to_end_id, counterparty_iban, bank_tx_code, return_reason,
                                       original_end_to_end_id, payment_info_id, kind, method)
select 'b0000000-0000-0000-0000-000000000001', x.n, 1, 't:B' || x.n, x.dir, x.amount, 'EUR', '2026-11-06', x.e2e, x.iban,
       x.code, null, null, x.pmtinf, x.kind, 'sct'
from (values
  (1, 'credit', 10000::bigint, 'E2E-B1', null, 'PMNT/RCDT/ESCT', null, 'debtor_credit'),            -- a debtor's payment
  (2, 'credit', 2000::bigint, (select end_to_end_id from public.bank_transfer where id = (select v from t where k = 'top')),
   'FR7030001007940000000002002', 'PMNT/RCDT/ESCT', null, 'debtor_credit'),                        -- our top-up (TOP id)
  (3, 'debit', 150::bigint, null, null, 'ACMT/MDOP/CHRG', null, 'other_debit'),                     -- a bank charge
  (4, 'credit', 3000::bigint, 'E2E-B4', 'FR7030001007940000000002002', 'PMNT/RCDT/ESCT', null, 'debtor_credit'),  -- own IBAN
  (5, 'debit', 50::bigint, null, null, null, null, 'other_debit'),                                  -- a debit ops call a fee
  (6, 'credit', 1000::bigint, 'E2E-LOSS', null, 'PMNT/RCDT/ESCT', null, 'debtor_credit'),           -- paid, then returned
  (7, 'debit', 700::bigint, 'RMTABCDEF012345', null, 'PMNT/ICDT/ESCT', 'PMTINF-1', 'other_debit')    -- one of our transfers
) x (n, dir, amount, e2e, iban, code, pmtinf, kind);
select is((private.ingest_statement('b0000000-0000-0000-0000-000000000001', jsonb_build_object('format', 'camt053',
  'version', '08', 'line_count', 7, 'skipped_not_booked', 0, 'sections', jsonb_build_array(jsonb_build_object(
  'stmt_id', 'B1', 'seq', 1, 'from_date', '2026-11-06', 'to_date', '2026-11-06', 'opening_minor', '0',
  'closing_minor', '15100')))) - 'cash_in' - 'unposted' - 'credits' - 'debits' - 'payments' - 'cash_in_entries' - 'lines'
  - 'new_lines' - 'known_lines' - 'skipped_not_booked'),
  '{"returns": 0, "refunds_out": 0, "other_debits": 2, "batch_unsplit": 0, "transfers_out": 1, "own_transfers_in": 2,
    "client_transfers_in": 0, "suspected_duplicates": 0}'::jsonb,
  'the import counts our own credits and transfers out');
select is((select string_agg(t.line_no || '=' || t.kind, ' ' order by t.line_no) from public.bank_transaction t
           where t.statement_id = 'b0000000-0000-0000-0000-000000000001'),
  '1=debtor_credit 2=own_transfer_in 3=other_debit 4=own_transfer_in 5=other_debit 6=debtor_credit 7=transfer_out',
  'a credit carrying our TOP id or from our own IBAN is ours; a debit carrying our RMT id is a transfer out');
select is((select array_agg(p.amount_minor order by p.amount_minor) from public.payment p
           where p.organization_id = '00000000-0000-0000-0000-0000000000bb'), array[1000, 10000]::bigint[],
  'an own-IBAN or TOP credit never becomes a debtor payment (only the debtors'' credits do)');
select is((select payment_info_id from public.bank_transaction
           where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 7), 'PMTINF-1',
  'camt.053 PmtInfId is kept');

-- The debit job's bookings (its decisions as payments.debits makes them), then ops ---------------------------------
select is((select string_agg(c.line_kind || coalesce('+' || c.transfer_status, ''), ' ' order by c.booking_date, c.line_id)
           from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000bb', null, null, 100) c),
  (select string_agg(x, ' ') from (select case t.line_no when 2 then 'own_transfer_in+ordered' when 3 then 'other_debit'
                                                        when 4 then 'own_transfer_in' when 7 then 'transfer_out' end as x
                                   from public.bank_transaction t
                                   where t.statement_id = 'b0000000-0000-0000-0000-000000000001'
                                     and t.line_no in (2, 3, 4, 7) order by t.booking_date, t.id) y),
  'the job looks at the charge, our credits (the TOP one with its order) and our transfer out');
select private.bank_booking_begin();
insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method)
select 1, x.id, 'top_up', (select v from t where k = 'top'), 'auto'
from public.bank_transaction x where x.statement_id = 'b0000000-0000-0000-0000-000000000001' and x.line_no = 2
union all
select 2, t.id, 'fee', null, 'auto'
from public.bank_transaction t where t.statement_id = 'b0000000-0000-0000-0000-000000000001' and t.line_no = 3;
insert into pg_temp._booking_review (bank_transaction_id, reason)
select t.id, case t.line_no when 4 then 'top_up_not_found' else 'own_transfer_out' end
from public.bank_transaction t where t.statement_id = 'b0000000-0000-0000-0000-000000000001' and t.line_no in (4, 7);
select is(private.apply_bank_bookings('00000000-0000-0000-0000-0000000000bb') - 'reviews',
  '{"fees": 1, "top_ups": 1, "losses": 0, "skipped": 0, "failed": 0}'::jsonb,
  'the job books the top-up its TOP id names and the bank charge');
select is((select array[x.status, e.entry_type, k.kind] from public.bank_transfer x
           join public.ledger_entry e on e.id = x.entry_id
           join public.bank_line_booking k on k.entry_id = e.id
           where x.id = (select v from t where k = 'top')), array['booked', 'servicer_top_up', 'top_up'],
  'the top-up is booked from its credit (servicer_top_up), the transfer booked');
select is((select count(*)::int from public.bank_debit_review r join public.bank_transaction t on t.id = r.bank_transaction_id
           where t.statement_id = 'b0000000-0000-0000-0000-000000000001'), 2,
  'the own credit without an order and our transfer out wait for ops');
select pg_temp.as_user('05');
set local role authenticated;
select lives_ok(format($$ select public.link_debit('link-own-0001', %L, 'own_credit', null, null, null,
  'virement du compte propre') $$, (select id from public.bank_transaction
                                    where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 4)),
  'ops book a credit from the own account as a top-up (its own account from its IBAN)');
select lives_ok(format($$ select public.link_debit('link-fee-0001', %L, 'fee', null, null, null, 'frais de tenue de compte') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 5)),
  'ops book a plain debit as a bank fee (« Frais bancaires »)');
select throws_ok(format($$ select public.link_debit('link-fee-0002', %L, 'fee', null, null, null, 'encore') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 5)),
  '23514', 'bank booking refused: already_booked', 'a line is booked once');
select throws_ok(format($$ select public.link_debit('link-fee-0003', %L, 'fee', null, null, null, 'un crédit') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 1)),
  '23514', 'bank booking refused: not_a_fee', 'a credit is never a fee');
select throws_ok(format($$ select public.link_debit('link-exp-0001', %L, 'explained', null, null, null, 'déjà') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 5)),
  '23514', 'debit link refused: already_booked', 'a booked line is not explained as well');
select lives_ok(format($$ select public.link_debit('link-exp-0002', %L, 'explained', null, null, null,
  'virement manuel vers le compte propre (balayage, M2c-6)') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 7)),
  'our transfer out is explained for now (sweeps are booked from M2c-6)');
reset role;
-- 5120 = the bank after the fees and the top-ups: closing 15 100 = 5120 + the one line explained (−700)
select is(array[pg_temp.bal('client_money_cash', null, '00000000-0000-0000-0000-0000000000bb'),
                (select minor from private.bank_unposted('80000000-0000-0000-0000-0000000000bf', '2026-11-06'))],
  array[15800, -700]::bigint[],
  '5120 = the bank after the fees and the top-ups: closing 15 100 = 5120 (15 800) + the line explained, not booked (I9)');
select is((select (bank_check ->> 'difference_minor') from public.bank_statement
           where id = 'b0000000-0000-0000-0000-000000000001'), '0',
  'the import''s own check held too (the lines it did not book were counted as open)');

-- A return larger than what is left of its payment (OQ-34): the payment's return + the servicer's loss ------------
select pg_temp.stmt('b0000000-0000-0000-0000-000000000002', '80000000-0000-0000-0000-0000000000bf');
insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind, end_to_end_id, original_end_to_end_id,
                                     return_reason)
values ('b1000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000bb', '80000000-0000-0000-0000-0000000000bf',
        'b0000000-0000-0000-0000-000000000002', 1, 't:BR1', 'debit', 1500, 'EUR', '2026-11-07', 'return', 'E2E-LOSS',
        'E2E-LOSS', 'MD06');
select pg_temp.as_user('05');
set local role authenticated;
select throws_ok($$ select public.link_debit('link-ret-0001', 'b1000000-0000-0000-0000-000000000001', 'return',
  (select id from public.payment where end_to_end_id = 'E2E-LOSS'), null, '1000', 'retour') $$, '23514',
  'debit link refused: amount_exceeds', 'the return alone cannot be linked: it exceeds what is left of the payment');
select lives_ok($$ select public.link_debit('link-loss-0001', 'b1000000-0000-0000-0000-000000000001', 'loss',
  (select id from public.payment where end_to_end_id = 'E2E-LOSS'), null, '1000', 'rejet de prélèvement au-delà du paiement') $$,
  'ops book it as the payment''s return of what is left plus the servicer''s loss for the excess');
reset role;
select is((select array[p.status, l.kind, (select k.kind || ':' || k.amount_minor from public.bank_line_booking k
                                          where k.bank_transaction_id = l.bank_transaction_id),
                        (select (-sum(lp.amount_minor))::text from public.ledger_posting lp where lp.entry_id = l.cash_entry_id
                           and lp.amount_minor < 0)]
           from public.bank_debit_link l join public.payment p on p.id = l.payment_id
           where l.bank_transaction_id = 'b1000000-0000-0000-0000-000000000001'),
  array['returned', 'return', 'loss:500', '1000'], 'the payment is returned (1 000), the excess 500 is the servicer''s loss');
select is(pg_temp.bal('servicer_losses', null, '00000000-0000-0000-0000-0000000000bb'), 500::bigint,
  'borne by the servicer (6780), never by the client or another client');
select throws_ok($$ insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind,
  entry_id, amount_minor, method) select 'b1000000-0000-0000-0000-000000000001', 2, '00000000-0000-0000-0000-0000000000bb',
  '80000000-0000-0000-0000-0000000000bf', 'loss', id, 500, 'auto' from public.ledger_entry
  where idempotency_key = 'fee:cc-lock' $$, '23514', null, 'a booking fits its line and its entry');
-- Nightly checks: servicer bb has none; servicer aa's direct test postings are caught ------------------------------
select is((select (private.run_payment_checks('00000000-0000-0000-0000-0000000000bb') ->> 'violations')::int), 0,
  'servicer bb (its lines imported, booked by the job and by ops): no violation (I8′, I12, I13, I14, I19 hold)');
insert into t select 'run_cc', (private.run_payment_checks('00000000-0000-0000-0000-0000000000cc') ->> 'run_id')::uuid;
insert into t select 'run_aa', (private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'run_id')::uuid;
select is((select string_agg(r.code, ' ') from public.payment_check_result r
           where r.run_id = (select v from t where k = 'run_cc') and r.severity = 'violation'),
  'bank_cash_identity', 'servicer cc''s fee posted without its bank line is caught (I19: no 5120 movement without its line)');
select is((select string_agg(distinct r.code, ' ' order by r.code) from public.payment_check_result r
           where r.run_id = (select v from t where k = 'run_aa') and r.severity = 'violation'),
  'bank_cash_identity notification_missing payment_position remittance_completeness',
  'servicer aa, after the worked example: I8′, the servicer''s fund, I12 and I13 hold; only the test''s direct postings '
  || 'are flagged (no bank lines, a reversal without its notification, remittances outside a run)');
update private.client_payable_balance set balance_minor = balance_minor - 1
where client_organization_id = '00000000-0000-0000-0000-0000000000c1';
delete from private.remittance_pending where client_organization_id = '00000000-0000-0000-0000-0000000000c1';
insert into t select 'run_cc2', (private.run_payment_checks('00000000-0000-0000-0000-0000000000cc') ->> 'run_id')::uuid;
select is((select string_agg(distinct r.code, ' ' order by r.code) from public.payment_check_result r
           where r.run_id = (select v from t where k = 'run_cc2') and r.severity = 'violation'),
  'bank_cash_identity client_payable_debit remittance_completeness',
  'a running balance that drifts and a missing pending item are caught (I13, I14)');
-- Read access ------------------------------------------------------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
select is((select count(distinct book)::int from public.ledger_account
           where book in ('due_to_servicer', 'due_from_client_funds', 'own_cash', 'commission_receivable',
                          'client_advance_receivable', 'vat_collected', 'vat_pending', 'servicer_revenue', 'bank_fees',
                          'servicer_losses')), 10, 'money staff read every book of both funds');
select ok((select count(*) from public.bank_line_booking) = 0 and (select count(*) from public.bank_transfer) = 0,
  'and only their own servicer''s bookings and transfers');
reset role;
select pg_temp.as_user('05');
set local role authenticated;
select is((select count(*)::int from public.bank_line_booking), 5, 'servicer bb''s money staff read its bookings');
select is((select count(*)::int from public.bank_transfer), 2, 'and its transfers');
reset role;
select pg_temp.as_user('02');
set local role authenticated;
select is((select count(*)::int from public.ledger_account where portfolio_id is null), 0,
  'collectors read no book without a portfolio (7060 included)');
select is((select count(*)::int from public.ledger_entry where portfolio_id is null), 0, 'nor such entries');
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select is((select array_agg(distinct book) from public.ledger_account where portfolio_id is null), array['client_payable'],
  'a client reads its own 4670 only (not 4111, 4112, 7060 or 4679)');
select is((select array_agg(distinct entry_type order by entry_type) from public.ledger_entry where portfolio_id is null),
  array['client_advance', 'client_settlement', 'remittance'],
  'and its own entries of the types that move what it is owed (never commission documents or its payments to us)');
select throws_ok($$ select count(*) from private.client_payable_balance $$, '42501', null,
  'the running balance is not readable through the API');
select throws_ok($$ insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind,
  entry_id, amount_minor, method) values ('b1000000-0000-0000-0000-000000000001', 9, '00000000-0000-0000-0000-0000000000bb',
  '80000000-0000-0000-0000-0000000000bf', 'fee', gen_random_uuid(), 1, 'auto') $$, '42501', null,
  'nobody writes a booking directly');
select is((select count(*)::int from public.bank_transfer), 0, 'clients read no transfer');
reset role;

select * from finish();
rollback;
