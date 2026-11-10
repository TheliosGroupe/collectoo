-- M2c-1 (M2-12): the funds ledger. Two funds closed in every entry (I2′), the 4679 / 4689 mirror (I12), the shapes of
-- the thirteen M2c types (I3′), the lock decided by the lines and the remit lock, the per-client running balance of 4670
-- with its commit guard (I13, LG008), the pending queue of remittance items, the own bank account, one client_funds
-- account per currency, our own transfers classified at import, bank lines booked in the funds (fees, top-ups, the
-- servicer's loss on a return larger than its payment, OQ-34), an own credit released as a debtor payment the servicer
-- relayed, one decision per bank line, the nightly checks (I8′, I12, I13, I14, I19, the shortfall alert) and the read
-- policies (clients A/B, a restricted client viewer). Design docs/design/m2c-remittances.md §5, §6, §7, §12, §13, §15,
-- §18; ADR-0014.
-- Servicer aa: the shapes and the §7 worked example, posted directly through private.ledger_post_set (no bank lines:
-- I19 flags them, which is checked last). Servicer bb: a statement imported, booked by the debit job's path and by ops,
-- with 5120 = the bank's closing balance and no violation. Servicer cc: the checks fire on tampered data. Servicer dd:
-- the funds candidates' reads at zero rows over the pages.
begin;
select plan(174);

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
from unnest(array['01', '02', '03', '04', '05', '06', '07']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000bb', 'admin'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a1', 'client_viewer');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', 'P1'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2', 'P2');
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1'),
  ('10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-0000000000a1');  -- a client viewer of P1 only
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
create temporary table n (k text primary key, v bigint) on commit drop;   -- counts computed as postgres
grant all on n to authenticated;

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
select is((select pg_get_triggerdef(oid) ~ 'WHEN \(\(new\.balance_minor > 0\)\)' from pg_trigger
           where tgname = 'client_payable_in_credit'), true,
  'one check queued per update leaving a balance in debit, not per update (a loop of reversals stays linear)');
select is((select array_agg(proname::text || '=' || prosecdef::text order by proname) from pg_proc
           where pronamespace = 'private'::regnamespace
             and proname in ('client_payable_check', 'bank_line_booking_check', 'ledger_posting_client_payable')),
  array['bank_line_booking_check=true', 'client_payable_check=true', 'ledger_posting_client_payable=true'],
  'the funds'' commit checks run as their owner (a command''s commit runs them as the API''s role)');
select is((select array_agg(relrowsecurity order by relname) from pg_class
           where oid in ('public.bank_transfer'::regclass, 'public.bank_line_booking'::regclass,
                         'public.bank_own_credit_release'::regclass,
                         'private.client_payable_balance'::regclass, 'private.remittance_pending'::regclass)),
  array[true, true, true, true, true], 'RLS on the new tables');
select is((select count(*)::int from pg_trigger
           where tgname in ('bank_own_credit_release_guard', 'bank_own_credit_release_append_only') and tgenabled = 'A'),
  2, 'an own credit''s release is checked and append-only, always');

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
-- In debit for a moment within the transaction, back to zero before the commit: it commits (the check queued by the
-- update in debit reads the balance at commit).
insert into t select 'dip', pg_temp.fund('remittance', 'remit:dip:0001', 'a2', 'bank_transfer/RMT00000000000D',
  '[["client_payable", 300], ["client_money_cash", -300, "cf"]]', '2026-11-08');
select is(pg_temp.bal('client_payable', 'a2'), 300::bigint, 'a payout puts Lilas''s 4670 in debit for a moment');
insert into t select 'dip_rev', z.entry_id from private.ledger_reverse((select v from t where k = 'dip'),
  'reverse-dip-0001', 'Virement revenu (test)', '2026-11-08') z;
select lives_ok($$ select private.ledger_check_now() $$,
  'its payout returned before the commit: back to zero, it commits (I13 is checked at commit)');

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
select throws_ok($$ select public.register_bank_account('register-own-usd-0001', '00000000-0000-0000-0000-0000000000aa',
  'Compte propre USD', 'FR3430001007940000000001001', 'USD', null, null, null, 'own') $$, '23505',
  'this IBAN is already registered for another purpose',
  'the dedicated account''s IBAN is never registered as an own account, in any currency');
select throws_ok($$ select public.register_bank_account('register-cf-usd-0001', '00000000-0000-0000-0000-0000000000aa',
  'Fonds de tiers USD', 'FR0930001007940000000003003', 'USD', 'camt053') $$, '23505',
  'this IBAN is already registered for another purpose', 'nor an own account''s IBAN as a dedicated account');
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
select throws_ok(format($$ select public.link_debit('link-fee-0004', %L, 'fee', null, null, null, 'retrait') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 7)),
  '23514', 'bank booking refused: not_a_fee',
  'our transfer out is never a bank fee (a withdrawal to the own account or a payout is not the bank''s charge)');
select throws_ok(format($$ select public.link_debit('link-ret-0002', %L, 'return', %L, null, '10000', 'retour') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 7),
  (select id from public.payment where end_to_end_id = 'E2E-B1')),
  '23514', 'debit link refused: not_a_return', 'nor a payment''s return');
select lives_ok(format($$ select public.link_debit('link-exp-0002', %L, 'explained', null, null, null,
  'virement manuel vers le compte propre (balayage, M2c-6)') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 7)),
  'our transfer out is explained for now (sweeps are booked from M2c-6)');
select throws_ok(format($$ select public.link_debit('link-fee-0005', %L, 'fee', null, null, null, 'frais') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 7)),
  '23514', 'bank booking refused: already_linked', 'a line explained is not booked as well');
-- A pending refund of the charge's amount: the charge the job booked is not listed to classify as maybe that refund.
insert into t select 'rfd150', (public.request_refund('refund-150-0001',
  (select id from public.payment where end_to_end_id = 'E2E-B1'), '150', 'FR1420041010050500013M02606', 'PAYEUR B1',
  'other', null, '10000', 'trop-perçu (test)') ->> 'refund_request_id')::uuid;
select is((select count(*)::int from public.debit_queue('a-classer', 0, 100) q
           where q.bank_transaction_id = (select x.id from public.bank_transaction x
                                          where x.statement_id = 'b0000000-0000-0000-0000-000000000001'
                                            and x.line_no = 3)), 0,
  'a bank charge booked by the job never waits in « À classer » as maybe a pending refund of its amount');
select lives_ok(format($$ select public.cancel_refund('refund-150-cancel', %L, 'test') $$, (select v from t where k = 'rfd150')),
  'the refund is cancelled');
reset role;
select throws_ok($$ insert into public.bank_debit_link (bank_transaction_id, organization_id, bank_account_id, kind, method,
  reason, decided_by) select x.id, x.organization_id, x.bank_account_id, 'explained', 'ops', 'x',
  '10000000-0000-0000-0000-000000000005' from public.bank_transaction x
  where x.statement_id = 'b0000000-0000-0000-0000-000000000001' and x.line_no = 5 $$, '23514', null,
  'even written directly, a line booked in the funds is not linked as well (the backstop of the line lock)');
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

-- A debtor's payment the servicer received on its own account and passed on to the dedicated account (§12): ops
-- release the own credit as a payment. And a return when nothing is left of its payment: the whole line is the loss.
insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind, end_to_end_id, original_end_to_end_id,
                                     return_reason, counterparty_iban, remittance_text)
values ('b1000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000bb', '80000000-0000-0000-0000-0000000000bf',
        'b0000000-0000-0000-0000-000000000002', 2, 't:BR2', 'credit', 4000, 'EUR', '2026-11-07', 'own_transfer_in',
        'E2E-RELAY', null, null, 'FR7030001007940000000002002', 'REGLEMENT DOSSIER D-77'),
       ('b1000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000bb', '80000000-0000-0000-0000-0000000000bf',
        'b0000000-0000-0000-0000-000000000002', 3, 't:BR3', 'credit', 600, 'EUR', '2026-11-07', 'own_transfer_in',
        'E2E-OWN-600', null, null, 'FR7030001007940000000002002', null),
       ('b1000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000bb', '80000000-0000-0000-0000-0000000000bf',
        'b0000000-0000-0000-0000-000000000002', 4, 't:BR4', 'debit', 300, 'EUR', '2026-11-07', 'return', 'E2E-LOSS',
        'E2E-LOSS', 'MD06', null, null);
select pg_temp.as_user('05');
set local role authenticated;
select throws_ok($$ select public.link_debit('link-rfd-0009', 'b1000000-0000-0000-0000-000000000002', 'refund', null,
  gen_random_uuid(), null, 'x') $$, '23514', 'debit link refused: not_a_return',
  'an own credit is never a refund (whatever request is named)');
select throws_ok($$ select public.link_debit('link-rfd-0010', 'b1000000-0000-0000-0000-000000000002', 'refund_returned',
  null, gen_random_uuid(), null, 'x') $$, '23514', 'debit link refused: not_a_return', 'nor a refund that came back');
select throws_ok($$ select public.release_own_credit('release-0000', 'b1000000-0000-0000-0000-000000000002', '  ') $$,
  '23514', 'own credit release refused: reason_required', 'a release needs its motif');
select throws_ok(format($$ select public.release_own_credit('release-0001', %L, 'paiement du débiteur') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 1)),
  '23514', 'own credit release refused: not_own_credit', 'a debtor''s credit is not an own credit');
select throws_ok(format($$ select public.release_own_credit('release-0002', %L, 'paiement du débiteur') $$,
  (select id from public.bank_transaction where statement_id = 'b0000000-0000-0000-0000-000000000001' and line_no = 4)),
  '23514', 'own credit release refused: already_booked', 'an own credit booked as a top-up is not released');
select lives_ok($$ select public.link_debit('link-exp-0600', 'b1000000-0000-0000-0000-000000000003', 'explained', null,
  null, null, 'trop-versé au cabinet, rendu') $$, 'an own credit explained');
select throws_ok($$ select public.release_own_credit('release-0003', 'b1000000-0000-0000-0000-000000000003',
  'en fait un paiement') $$, '23514', 'own credit release refused: already_linked',
  'an own credit explained is not released as well');
insert into t select 'relay', (public.release_own_credit('release-0004', 'b1000000-0000-0000-0000-000000000002',
  'paiement de M. Durand reçu sur le compte du cabinet, reversé') ->> 'payment_id')::uuid;
select is(public.release_own_credit('release-0004', 'b1000000-0000-0000-0000-000000000002',
  'paiement de M. Durand reçu sur le compte du cabinet, reversé'),
  jsonb_build_object('payment_id', (select v from t where k = 'relay'), 'status', 'unmatched'),
  'ops release an own credit as a debtor payment relayed by the cabinet (a replay returns the same)');
select throws_ok($$ select public.release_own_credit('release-0005', 'b1000000-0000-0000-0000-000000000002', 'encore') $$,
  '23514', 'own credit release refused: already_booked', 'once');
select throws_ok($$ select public.link_debit('link-own-0009', 'b1000000-0000-0000-0000-000000000002', 'own_credit', null,
  null, null, 'approvisionnement') $$, '23514', 'bank booking refused: already_booked',
  'a released own credit is not booked as a top-up as well');
select throws_ok($$ select public.link_debit('link-exp-0009', 'b1000000-0000-0000-0000-000000000002', 'explained', null,
  null, null, 'x') $$, '23514', 'debit link refused: already_booked', 'nor explained');
select is((select count(*)::int from public.debit_queue('a-classer', 0, 100) q
           where q.bank_transaction_id = 'b1000000-0000-0000-0000-000000000002'), 0, 'it leaves « À classer »');
select is((select array[q.decision, (q.decided_payment_id = (select v from t where k = 'relay'))::text]
           from public.debit_queue('traites', 0, 100) q where q.bank_transaction_id = 'b1000000-0000-0000-0000-000000000002'),
  array['relayed_payment', 'true'], 'and is listed among the lines decided, with its payment');
select is((select count(*)::int from public.bank_own_credit_release), 1, 'money staff read the servicer''s releases');
reset role;
select pg_temp.as_user('05', 'aal1');
set local role authenticated;
select throws_ok($$ select public.release_own_credit('release-0006', 'b1000000-0000-0000-0000-000000000002', 'x') $$,
  '42501', null, 'at aal2 only');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok($$ select public.release_own_credit('release-0007', 'b1000000-0000-0000-0000-000000000002', 'x') $$,
  '42501', null, 'never another servicer''s line');
reset role;
select is((select array[p.status, p.review_reason, p.payer_name, coalesce(p.payer_iban, '-'), p.amount_minor::text,
                        p.booking_date::text, p.channel, p.method, p.remittance_text]
           from public.payment p where p.id = (select v from t where k = 'relay')),
  array['unmatched', 'no_match', 'Versement relayé par le cabinet', '-', '4000', '2026-11-07', 'camt053', 'other',
        'REGLEMENT DOSSIER D-77'],
  'a payment of the dedicated account, unmatched, for ops to assign (« Paiements à traiter »); never the own IBAN as payer');
select is((select array[e.entry_type, e.effective_date::text, e.source_type || '/' || e.source_id,
                        (select lp.amount_minor::text from public.ledger_posting lp
                         join public.ledger_account la on la.id = lp.ledger_account_id
                         where lp.entry_id = e.id and la.book = 'client_money_cash')]
           from public.ledger_entry e where e.organization_id = '00000000-0000-0000-0000-0000000000bb'
             and e.idempotency_key = 'cash_in:b0000000-0000-0000-0000-000000000002:2026-11-07:'
                                     || 'b1000000-0000-0000-0000-000000000002'),
  array['cash_in', '2026-11-07', 'bank_statement/b0000000-0000-0000-0000-000000000002', '4000'],
  'its cash_in at the line''s date, tagged with its statement (as a released duplicate credit is: I11)');
select is((select array[r.reason, r.decided_by::text] from public.bank_own_credit_release r
           where r.bank_transaction_id = 'b1000000-0000-0000-0000-000000000002'),
  array['paiement de M. Durand reçu sur le compte du cabinet, reversé', '10000000-0000-0000-0000-000000000005'],
  'ops'' motif is kept');
select is((select count(*)::int from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000bb', null, null, 100) c
           where c.line_id in ('b1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000003')), 0,
  'the job looks at neither own credit again');
select throws_ok($$ update public.bank_own_credit_release set reason = 'autre'
  where bank_transaction_id = 'b1000000-0000-0000-0000-000000000002' $$, '23514', null, 'a release is a fact (append-only)');
select throws_ok($$ insert into public.bank_own_credit_release (bank_transaction_id, organization_id, bank_account_id, reason,
  decided_by) values ('b1000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000bb',
  '80000000-0000-0000-0000-0000000000bf', 'x', '10000000-0000-0000-0000-000000000005') $$, '23514', null,
  'even written directly, an own credit explained is not released');
-- the return when nothing is left of its payment (E2E-LOSS returned in full above)
select pg_temp.as_user('05');
set local role authenticated;
select is(public.link_debit('link-loss-0002', 'b1000000-0000-0000-0000-000000000004', 'loss',
  (select id from public.payment where end_to_end_id = 'E2E-LOSS'), null, '0', 'second rejet, rien ne reste du paiement')
  -> 'result' -> 'booking' ->> 'losses', '1', 'a return when nothing is left of its payment: the whole line is the loss');
reset role;
select is((select string_agg(k.kind || ':' || k.amount_minor, ' ') from public.bank_line_booking k
           where k.bank_transaction_id = 'b1000000-0000-0000-0000-000000000004')
          || ' links:' || (select count(*) from public.bank_debit_link l
                           where l.bank_transaction_id = 'b1000000-0000-0000-0000-000000000004'),
  'loss:300 links:0', 'booked as the servicer''s loss, with no link');
select is((select count(*)::int from private.debit_candidates('00000000-0000-0000-0000-0000000000bb', null, null, 100) c
           where c.line_id = 'b1000000-0000-0000-0000-000000000004'), 0,
  'and no longer a candidate of the debit job (every run decided it again)');
select private.debit_link_begin();
insert into pg_temp._debit_review (bank_transaction_id, reason) values ('b1000000-0000-0000-0000-000000000004', 'already_returned');
select is(private.apply_debit_decisions('00000000-0000-0000-0000-0000000000bb') ->> 'reviews', '1',
  'a stale decision of the job about it');
select is((select count(*)::int from public.bank_debit_review where bank_transaction_id = 'b1000000-0000-0000-0000-000000000004'),
  0, 'writes no review for it');
-- Nightly checks: servicer bb has none; servicer aa's direct test postings are caught ------------------------------
insert into t select 'run_bb', (private.run_payment_checks('00000000-0000-0000-0000-0000000000bb') ->> 'run_id')::uuid;
select is((select violations from public.payment_check_run where id = (select v from t where k = 'run_bb')), 0,
  'servicer bb (its lines imported, booked by the job and by ops, an own credit released): no violation (I8′, I11, I12, '
  || 'I13, I14, I19 hold)');
select is((select count(*)::int from public.payment_check_result r
           where r.run_id = (select v from t where k = 'run_bb') and r.code = 'servicer_shortfall'), 0,
  'its fees and losses are covered by its top-ups (4679 in credit): no shortfall');
insert into t select 'run_cc', (private.run_payment_checks('00000000-0000-0000-0000-0000000000cc') ->> 'run_id')::uuid;
insert into t select 'run_aa', (private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'run_id')::uuid;
select is((select string_agg(r.code, ' ') from public.payment_check_result r
           where r.run_id = (select v from t where k = 'run_cc') and r.severity = 'violation'),
  'bank_cash_identity', 'servicer cc''s fee posted without its bank line is caught (I19: no 5120 movement without its line)');
select is((select array[r.amount_minor::text, r.currency::text, r.details ->> 'due_to_servicer_minor',
                        r.details ->> 'top_ups_ordered_minor']
           from public.payment_check_result r
           where r.run_id = (select v from t where k = 'run_cc') and r.code = 'servicer_shortfall' and r.severity = 'alert'),
  array['200', 'EUR', '200', '0'],
  'servicer cc''s fee and advance left it owing the dedicated account 200, no top-up ordered: an alert to top up');
select is((select string_agg(distinct r.code, ' ' order by r.code) from public.payment_check_result r
           where r.run_id = (select v from t where k = 'run_aa') and r.severity = 'violation'),
  'bank_cash_identity notification_missing payment_position remittance_completeness',
  'servicer aa, after the worked example: I8′, the servicer''s fund, I12 and I13 hold; only the test''s direct postings '
  || 'are flagged (no bank lines, a reversal without its notification, remittances outside a run)');
update private.client_payable_balance set balance_minor = balance_minor - 1
where client_organization_id = '00000000-0000-0000-0000-0000000000c1';
delete from private.remittance_pending where client_organization_id = '00000000-0000-0000-0000-0000000000c1';
-- (and a top-up of 150 ordered from an own account of cc)
insert into public.bank_account (id, organization_id, purpose, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000c0', '00000000-0000-0000-0000-0000000000cc', 'own', 'FR7652911690573468086161054',
   'EUR', 'Compte propre C', null, '2026-01-01');
insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id, creditor_bank_account_id, currency,
                                  amount_minor, payee_name, payee_iban, end_to_end_id, requested_execution_date)
values ('00000000-0000-0000-0000-0000000000cc', 'top_up', '80000000-0000-0000-0000-0000000000c0',
        '80000000-0000-0000-0000-0000000000cc', 'EUR', 150, 'Troisième cabinet SAS', 'FR8130001007940000000005005',
        'TOP000000000CC1', '2026-11-09');
insert into t select 'run_cc2', (private.run_payment_checks('00000000-0000-0000-0000-0000000000cc') ->> 'run_id')::uuid;
select is((select string_agg(distinct r.code, ' ' order by r.code) from public.payment_check_result r
           where r.run_id = (select v from t where k = 'run_cc2') and r.severity = 'violation'),
  'bank_cash_identity client_payable_debit remittance_completeness',
  'a running balance that drifts and a missing pending item are caught (I13, I14)');
select is((select r.amount_minor::text || ' ' || (r.details ->> 'top_ups_ordered_minor') from public.payment_check_result r
           where r.run_id = (select v from t where k = 'run_cc2') and r.code = 'servicer_shortfall'), '50 150',
  'the top-up ordered counts: 50 left to order');
-- Plans that hold whatever the statistics (ARCHITECTURE §4): the debit job's funds candidates, checked by what they read
-- (pg_stat_xact_user_tables: this transaction's scans), in the state that made them slow — bank_line_booking and
-- bank_transfer counted at (nearly) zero rows over their pages, as after aborted inserts. Servicer dd: 300 charges
-- booked, 5 more charges and 5 credits carrying the TOP ids of 5 of its 305 orders, not booked yet.
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-0000000000dd', 'servicer', 'Quatrième cabinet SAS');
insert into public.bank_account (id, organization_id, purpose, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000df', '00000000-0000-0000-0000-0000000000dd', 'client_funds',
   'FR3130001007940000000009009', 'EUR', 'Fonds de tiers D', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000d0', '00000000-0000-0000-0000-0000000000dd', 'own',
   'FR6730001007940000000010010', 'EUR', 'Compte propre D', null, '2026-01-01');
select pg_temp.stmt('b0000000-0000-0000-0000-0000000000d1', '80000000-0000-0000-0000-0000000000df');
insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind, bank_tx_code, end_to_end_id)
select '00000000-0000-0000-0000-0000000000dd', '80000000-0000-0000-0000-0000000000df',
       'b0000000-0000-0000-0000-0000000000d1', g, 't:D' || g, case when g between 301 and 305 then 'credit' else 'debit' end,
       100, 'EUR', '2026-11-05', case when g between 301 and 305 then 'own_transfer_in' else 'other_debit' end,
       case when g between 301 and 305 then 'PMNT/RCDT/ESCT' else 'ACMT/MDOP/CHRG' end,
       case when g between 301 and 305 then 'TOP' || upper(lpad(to_hex(g), 12, '0')) end
from generate_series(1, 310) g;
create or replace function pg_temp.dd_orders() returns void language sql as $$
  insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id, creditor_bank_account_id, currency,
                                    amount_minor, payee_name, payee_iban, end_to_end_id, requested_execution_date)
  select '00000000-0000-0000-0000-0000000000dd', 'top_up', '80000000-0000-0000-0000-0000000000d0',
         '80000000-0000-0000-0000-0000000000df', 'EUR', 100, 'Quatrième cabinet SAS', 'FR3130001007940000000009009',
         'TOP' || upper(lpad(to_hex(g), 12, '0')), '2026-11-05'
  from generate_series(1, 305) g;
$$;
create or replace function pg_temp.dd_fees() returns jsonb language plpgsql as $$
begin
  perform private.bank_booking_begin();
  insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, method)
  select x.line_no, x.id, 'fee', 'auto' from public.bank_transaction x
  where x.statement_id = 'b0000000-0000-0000-0000-0000000000d1' and x.line_no <= 300;
  return private.apply_bank_bookings('00000000-0000-0000-0000-0000000000dd');
end $$;
create temp table _mark (relid oid primary key, seq_scan bigint, idx_scan bigint, idx_tup_fetch bigint);
create or replace function pg_temp.mark() returns void language sql as $$
  delete from _mark;
  insert into _mark select x.relid, x.seq_scan, x.idx_scan, x.idx_tup_fetch from pg_stat_xact_user_tables x
  where x.relid in ('public.bank_line_booking'::regclass, 'public.bank_transfer'::regclass);
$$;
create or replace function pg_temp.read_since_mark(p_rel regclass)
returns table (seq_scan bigint, idx_scan bigint, idx_tup_fetch bigint) language sql as $$
  select x.seq_scan - m.seq_scan, x.idx_scan - m.idx_scan, x.idx_tup_fetch - m.idx_tup_fetch
  from pg_stat_xact_user_tables x join _mark m on m.relid = x.relid where x.relid = p_rel;
$$;
-- the orders and bookings written once and rolled back, the tables analysed then, then written again
savepoint zero_density;
select pg_temp.dd_orders();
select pg_temp.dd_fees();
rollback to savepoint zero_density;
analyze public.bank_line_booking;
analyze public.bank_transfer;
select pg_temp.dd_orders();
select is(pg_temp.dd_fees() - 'reviews', '{"fees": 300, "top_ups": 0, "losses": 0, "skipped": 0, "failed": 0}'::jsonb,
  'servicer dd: 300 charges booked by the job');
select ok((select bool_and(c.reltuples < 50 and pg_relation_size(c.oid) / 8192 > c.relpages) from pg_class c
           where c.oid in ('public.bank_line_booking'::regclass, 'public.bank_transfer'::regclass))
          and (select count(*) from public.bank_line_booking) > 300 and (select count(*) from public.bank_transfer) > 300,
  'the statistics count (nearly) no booking and no order over their pages, while there are hundreds');
select pg_temp.mark();
create temp table _dd_cand as
select * from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000dd', null, null, 2000);
select is((select string_agg(c.line_kind || coalesce('+' || c.transfer_status, ''), ' ' order by c.line_kind)
           from (select distinct line_kind, transfer_status from _dd_cand) c)
          || ' ' || (select count(*) from _dd_cand),
  'other_debit own_transfer_in+ordered 10', 'the 5 charges not booked and the 5 credits with their orders');
-- Before the review fix, this read the bookings in a sequential scan per line (310 here; 48 150 bookings read through
-- a whole index on a fresh database) and 1 515 orders (each own credit read the servicer's orders through its
-- organization index).
select ok((select r.seq_scan = 0 and r.idx_tup_fetch <= 310 from pg_temp.read_since_mark('public.bank_line_booking') r),
  'each line probes the bookings by its key (one row at most per line of these kinds, never every booking per line)');
select ok((select r.seq_scan = 0 and r.idx_tup_fetch <= 5 from pg_temp.read_since_mark('public.bank_transfer') r),
  'each own credit finds its order by its TOP id (never the servicer''s other orders)');

-- Postings written straight to the tables for servicer cc, never committed (the deferred ledger checks would refuse
-- them at commit): 4679 moved without 4689 (70), and the servicer's 6270 against the client fund's 5120 (30). The nightly
-- checks see each break, whatever wrote it.
insert into public.ledger_entry (id, organization_id, entry_type, effective_date, line_count, idempotency_key,
                                 request_hash, source_type, source_id)
values ('e9000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000cc', 'bank_fee', '2026-11-06', 2,
        'tamper:mirror:0001', repeat('0', 64), 'bank_transaction', 'x'),
       ('e9000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000cc', 'bank_fee', '2026-11-06', 2,
        'tamper:fund:0001', repeat('0', 64), 'bank_transaction', 'y');
insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency, effective_date)
select x.e::uuid, x.n, la.id, x.amount, 'EUR', '2026-11-06'
from (values ('e9000000-0000-0000-0000-000000000001', 1, 'due_to_servicer', 70),
             ('e9000000-0000-0000-0000-000000000001', 2, 'client_money_cash', -70),
             ('e9000000-0000-0000-0000-000000000002', 1, 'bank_fees', 30),
             ('e9000000-0000-0000-0000-000000000002', 2, 'client_money_cash', -30)) x (e, n, book, amount)
join public.ledger_account la on la.organization_id = '00000000-0000-0000-0000-0000000000cc' and la.book = x.book;
insert into t select 'run_cc3', (private.run_payment_checks('00000000-0000-0000-0000-0000000000cc') ->> 'run_id')::uuid;
select is((select string_agg(r.code || ':' || r.amount_minor, ' ' order by r.code) from public.payment_check_result r
           where r.run_id = (select v from t where k = 'run_cc3')
             and r.code in ('client_money_identity', 'fund_mirror', 'own_fund_identity')),
  'client_money_identity:-30 fund_mirror:70 own_fund_identity:30',
  '4679 moved without 4689 breaks the mirror (I12); a servicer-fund book moved alone leaves both funds open');
-- Read access ------------------------------------------------------------------------------------------------
-- What each client should read without a portfolio, counted as postgres: its own 4670 and its own entries of the types
-- that move it (Lilas has rows of the same books and types).
insert into n select 'a1_acc', count(*) from public.ledger_account
  where portfolio_id is null and book = 'client_payable' and client_organization_id = '00000000-0000-0000-0000-0000000000a1';
insert into n select 'a1_ent', count(*) from public.ledger_entry
  where portfolio_id is null and client_organization_id = '00000000-0000-0000-0000-0000000000a1' and entry_type in ('forward', 'reversal', 'remittance', 'client_settlement', 'client_advance');
insert into n select 'a2_rows', (select count(*) from public.ledger_account
                                 where portfolio_id is null and book = 'client_payable' and client_organization_id = '00000000-0000-0000-0000-0000000000a2')
                                * (select count(*) from public.ledger_entry
                                   where portfolio_id is null and client_organization_id = '00000000-0000-0000-0000-0000000000a2' and entry_type in ('forward', 'reversal', 'remittance', 'client_settlement', 'client_advance'));
insert into t select 'a1_4670', id from public.ledger_account
  where portfolio_id is null and book = 'client_payable' and client_organization_id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.as_user('01');
set local role authenticated;
select is((select count(distinct book)::int from public.ledger_account
           where book in ('due_to_servicer', 'due_from_client_funds', 'own_cash', 'commission_receivable',
                          'client_advance_receivable', 'vat_collected', 'vat_pending', 'servicer_revenue', 'bank_fees',
                          'servicer_losses')), 10, 'money staff read every book of both funds');
select ok((select count(*) from public.bank_line_booking) = 0 and (select count(*) from public.bank_transfer) = 0
          and (select count(*) from public.bank_own_credit_release) = 0,
  'and only their own servicer''s bookings, transfers and releases');
reset role;
select pg_temp.as_user('05');
set local role authenticated;
select is((select count(*)::int from public.bank_line_booking), 6, 'servicer bb''s money staff read its bookings');
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
select is(array[(select count(*) from public.ledger_account where portfolio_id is null),
                (select count(*) from public.ledger_entry where portfolio_id is null)],
          array[(select v from n where k = 'a1_acc'), (select v from n where k = 'a1_ent')],
  'exactly its own: as many rows as Martin has');
select is((select count(*)::int from public.ledger_account where client_organization_id = '00000000-0000-0000-0000-0000000000a2')
          + (select count(*)::int from public.ledger_entry where client_organization_id = '00000000-0000-0000-0000-0000000000a2'), 0,
  'never another client''s, though Lilas has 4670 rows and entries of the same types');
select ok((select v from n where k = 'a2_rows') > 0, '(Lilas has such rows)');
select isnt(public.ledger_balance((select v from t where k = 'a1_4670')), null, 'a client member reads its 4670 balance');
select is((select count(*)::int from public.bank_own_credit_release), 0, 'clients read no release');
select throws_ok($$ select count(*) from private.client_payable_balance $$, '42501', null,
  'the running balance is not readable through the API');
select throws_ok($$ insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind,
  entry_id, amount_minor, method) values ('b1000000-0000-0000-0000-000000000001', 9, '00000000-0000-0000-0000-0000000000bb',
  '80000000-0000-0000-0000-0000000000bf', 'fee', gen_random_uuid(), 1, 'auto') $$, '42501', null,
  'nobody writes a booking directly');
select is((select count(*)::int from public.bank_transfer), 0, 'clients read no transfer');
reset role;
-- A client viewer restricted to some of the client's portfolios (P1): what covers all of them (what the client is owed,
-- its remittances) is whole-client data (OQ-48 default: whole-client access only).
select pg_temp.as_user('07');
set local role authenticated;
select is(array[(select count(*)::int from public.ledger_account where portfolio_id is null),
                (select count(*)::int from public.ledger_entry where portfolio_id is null)], array[0, 0],
  'a client viewer restricted to some portfolios reads neither the client''s 4670 nor its remittances or advances');
select throws_ok(format($$ select public.ledger_balance(%L) $$, (select v from t where k = 'a1_4670')), '42501', null,
  'nor the 4670 balance by id');
select ok((select count(*) from public.ledger_account where portfolio_id = '20000000-0000-0000-0000-0000000000a1') > 0,
  'it reads its portfolio''s ledger');
reset role;

select * from finish();
rollback;
