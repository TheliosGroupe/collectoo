-- Opening balances (M2-05, ADR-0012): planned at commit, posted at confirmation by the worker job.
begin;
select plan(32);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-00000000000a', 'servicer', 'Collectoo');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-00000000000a', 'Client A');
insert into auth.users (id, email, aud, role) values
  ('10000000-0000-0000-0000-000000000001', 'ops@s.test', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000003', 'admin@a.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin');
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on) values
  ('70000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   'M-1', 'mandate_amicable', '2026-01-01'),
  ('70000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   'M-2', 'mandate_amicable', '2026-01-01');
insert into public.mandate_terms (mandate_id, valid_from, commission_rate) values
  ('70000000-0000-0000-0000-000000000001', '2026-01-01', 0.15),
  ('70000000-0000-0000-0000-000000000002', '2026-01-01', 0.15);
insert into public.portfolio (id, organization_id, client_organization_id, name, mandate_id) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   'A', '70000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
   'A2', '70000000-0000-0000-0000-000000000002');

-- Batches walked to `staged` (B1 the real one; B2 with a tampered report; B3 without cut-off; B4 for an
-- expiring mandate).
create or replace function pg_temp.staged_batch(p_id uuid, p_portfolio uuid, p_version int, p_cut_off date, p_opening jsonb)
returns void language sql as $$
  insert into public.boarding_batch (id, organization_id, client_organization_id, portfolio_id, version, cut_off_date, dq_report)
  values (p_id, '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', p_portfolio, p_version,
          p_cut_off, jsonb_build_object('staging', jsonb_build_object('opening', p_opening)));
  select private.transition_batch(p_id, s, 'test')
  from unnest(array['uploaded', 'profiled', 'mapping_proposed', 'mapping_approved', 'transformed', 'validated', 'staged'])
       with ordinality as x (s, n) order by n;
$$;
create or replace function pg_temp.stage(p_batch uuid, p_entity text, p_key text, p_data jsonb)
returns void language sql as $$
  insert into private.boarding_staging (batch_id, entity, key, data) values (p_batch, p_entity, p_key, p_data);
$$;
create or replace function pg_temp.stage_tape(p_batch uuid, p_suffix text) returns void language sql as $$
  -- Civil account C: invoice 1250.00 paid 250.00, invoice 500.00, credit note 100.00, invoice paid in full.
  select pg_temp.stage(p_batch, 'party', 'C' || p_suffix, jsonb_build_object('kind', 'legal_entity', 'display_name', 'Boulangerie', 'seller_ref', 'C' || p_suffix));
  select pg_temp.stage(p_batch, 'account', 'C' || p_suffix, jsonb_build_object('external_ref', 'C' || p_suffix, 'claim_type', 'b2b_invoice', 'legal_regime', 'commercial_b2b', 'capacity', 'legal_entity'));
  select pg_temp.stage(p_batch, 'claim_item', 'C' || p_suffix, jsonb_build_object('account_key', 'C' || p_suffix, 'kind', 'invoice', 'ref', 'F-1', 'due_date', '2026-05-31', 'original_minor', 125000, 'seller_paid_minor', 25000));
  select pg_temp.stage(p_batch, 'claim_item', 'C' || p_suffix, jsonb_build_object('account_key', 'C' || p_suffix, 'kind', 'invoice', 'ref', 'F-2', 'due_date', '2026-06-30', 'original_minor', 50000));
  select pg_temp.stage(p_batch, 'claim_item', 'C' || p_suffix, jsonb_build_object('account_key', 'C' || p_suffix, 'kind', 'credit_note', 'ref', 'A-1', 'due_date', '2026-06-15', 'original_minor', 10000));
  select pg_temp.stage(p_batch, 'claim_item', 'C' || p_suffix, jsonb_build_object('account_key', 'C' || p_suffix, 'kind', 'invoice', 'ref', 'F-3', 'due_date', '2026-04-30', 'original_minor', 30000, 'seller_paid_minor', 30000));
  -- Civil account Z: fully paid (no opening entry).
  select pg_temp.stage(p_batch, 'party', 'Z' || p_suffix, jsonb_build_object('kind', 'legal_entity', 'display_name', 'Soldée', 'seller_ref', 'Z' || p_suffix));
  select pg_temp.stage(p_batch, 'account', 'Z' || p_suffix, jsonb_build_object('external_ref', 'Z' || p_suffix, 'claim_type', 'b2b_invoice', 'legal_regime', 'commercial_b2b', 'capacity', 'legal_entity'));
  select pg_temp.stage(p_batch, 'claim_item', 'Z' || p_suffix, jsonb_build_object('account_key', 'Z' || p_suffix, 'kind', 'invoice', 'ref', 'G-1', 'original_minor', 20000, 'seller_paid_minor', 20000));
  -- EU loan L: 3.09 800.00, 3.10 150.00, 3.11 50.00, 3.12 1000.07 (balancing line +0.07).
  select pg_temp.stage(p_batch, 'account', 'L' || p_suffix, jsonb_build_object('external_ref', 'L' || p_suffix, 'claim_type', 'professional_loan', 'legal_regime', 'professional_credit'));
  select pg_temp.stage(p_batch, 'claim_item', 'L' || p_suffix, jsonb_build_object('account_key', 'L' || p_suffix, 'kind', 'loan_principal', 'ref', 'L' || p_suffix, 'original_minor', 100007));
  select pg_temp.stage(p_batch, 'eba.t3_loan', '1', jsonb_build_object('source_row', 1, 'f3_01_loan_identifier', 'L' || p_suffix,
    'f3_09_principal_amount', '800.00', 'f3_10_accrued_interest', '150.00', 'f3_11_other_balances', '50.00', 'f3_12_legal_balance', '1000.07'));
$$;

create temporary table t (k text primary key, v jsonb) on commit drop;
grant all on t to authenticated;
insert into t values ('opening', '{"currencies": {"EUR": {"accounts": 2, "accounts_without_balance": 1,
  "outstanding_minor": "240007", "components": {"principal": "220000", "accrued_interest": "15000",
  "other_balances": "5000", "balancing_line": "7"}}}}');

select pg_temp.staged_batch('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1', 2, '2026-09-30',
  jsonb_set((select v from t where k = 'opening'), '{currencies,EUR,outstanding_minor}', '"240008"'));
select pg_temp.stage_tape('30000000-0000-0000-0000-000000000002', '-1');
select pg_temp.staged_batch('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-0000000000a1', 3, null,
  (select v from t where k = 'opening'));
select pg_temp.stage_tape('30000000-0000-0000-0000-000000000003', '-1');
select pg_temp.staged_batch('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 1, '2026-09-30',
  (select v from t where k = 'opening'));
select pg_temp.stage_tape('30000000-0000-0000-0000-000000000001', '-1');
select pg_temp.staged_batch('30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-0000000000a2', 1, '2026-09-30',
  (select v from t where k = 'opening'));
select pg_temp.stage_tape('30000000-0000-0000-0000-000000000004', '-4');

-- Commit: the plan is computed and checked, nothing is posted -------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated", "aal": "aal1"}', true);
set local role authenticated;
select throws_ok($$select public.commit_boarding_batch('30000000-0000-0000-0000-000000000002')$$, 'LG005', null,
  'a plan that does not reconcile with the data-quality report is refused (nothing committed)');
select throws_ok($$select public.commit_boarding_batch('30000000-0000-0000-0000-000000000003')$$, '23514', null,
  'a batch without cut-off date cannot be committed');
select lives_ok($$select public.commit_boarding_batch('30000000-0000-0000-0000-000000000001')$$, 'the batch is committed');
select lives_ok($$select public.commit_boarding_batch('30000000-0000-0000-0000-000000000004')$$, 'and another one');
reset role;
select is(private.opening_normal((select opening_plan from public.boarding_batch where id = '30000000-0000-0000-0000-000000000001')),
  private.opening_normal((select v from t where k = 'opening')), 'commit stores the opening plan = the staged report');
select is((select count(*)::int from public.ledger_entry), 0, 'nothing reaches the ledger at commit');
select is((select count(*)::int from public.claim_ownership_period o join public.account a on a.id = o.account_id
           where a.boarding_batch_id = '30000000-0000-0000-0000-000000000001' and o.valid_from = '2026-09-30'), 3,
  'servicing starts at the cut-off date');

-- Confirmation request: staff at aal2; the worker job is queued -------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated", "aal": "aal2"}', true);
set local role authenticated;
select lives_ok($$select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000001')$$, 'staff request the confirmation');
select lives_ok($$select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000004')$$, 'for both batches');
reset role;
select is((select status from public.boarding_batch where id = '30000000-0000-0000-0000-000000000001'), 'confirming',
  'the batch waits for the worker');
select is((select count(*)::int from pgmq.q_boarding where message ->> 'type' = 'confirm'
           and message ->> 'batch_id' = '30000000-0000-0000-0000-000000000001'), 1, 'one confirmation job is queued');
select throws_ok($$select public.rollback_boarding_batch('30000000-0000-0000-0000-000000000001', 'x')$$, '23514', null,
  'no rollback while confirming');

-- The worker job posts the openings ------------------------------------------------------------------
select is(private.complete_batch_confirmation('30000000-0000-0000-0000-000000000001'), 'confirmed', 'the job confirms the batch');
select is((select array_agg(distinct status) from public.account where boarding_batch_id = '30000000-0000-0000-0000-000000000001'),
  array['awaiting_first_letter'], 'its accounts become workable');
select is((select count(*)::int from public.ledger_entry where boarding_batch_id = '30000000-0000-0000-0000-000000000001'), 2,
  'one opening entry per account with a balance (none for the fully paid account)');
select is((select array_agg(distinct effective_date) from public.ledger_entry where boarding_batch_id = '30000000-0000-0000-0000-000000000001'),
  array['2026-09-30'::date], 'dated at the cut-off');
select is((select count(*)::int from public.ledger_entry e join public.account a on a.id = e.account_id
           where e.boarding_batch_id = '30000000-0000-0000-0000-000000000001'
             and e.idempotency_key = 'opening:30000000-0000-0000-0000-000000000001:' || a.id), 2,
  'keyed opening:<batch>:<account>');
select is((select array_agg(distinct actor_id) from public.ledger_entry where boarding_batch_id = '30000000-0000-0000-0000-000000000001'),
  array['10000000-0000-0000-0000-000000000001'::uuid], 'posted on behalf of the staff member who confirmed');
select is(private.opening_normal(private.opening_totals('30000000-0000-0000-0000-000000000001', true)),
  private.opening_normal((select v from t where k = 'opening')), 'Σ posted openings per component = the staged report');
select is((select p.amount_minor from public.ledger_posting p join public.ledger_account la on la.id = p.ledger_account_id
           join public.claim_item i on i.id = la.claim_item_id where i.ref = 'A-1'), -10000::bigint,
  'a credit note is a negative line on its own item');
select is((select jsonb_object_agg(la.component, p.amount_minor) from public.ledger_posting p
           join public.ledger_account la on la.id = p.ledger_account_id and la.book = 'debtor_receivable'
           join public.claim_item i on i.id = la.claim_item_id and i.ref = 'L-1'),
  '{"principal": 80000, "accrued_interest": 15000, "other_balances": 5000, "balancing_line": 7}'::jsonb,
  'an EU loan opens with 3.09 / 3.10 / 3.11 and a balancing line up to 3.12');
select is((select count(*)::int from (
             select la.component, sum(p.amount_minor) from public.ledger_posting p
             join public.ledger_entry e on e.id = p.entry_id and e.boarding_batch_id = '30000000-0000-0000-0000-000000000001'
             join public.ledger_account la on la.id = p.ledger_account_id
             group by la.component having sum(p.amount_minor) <> 0) x), 0,
  'the owner claim mirrors the receivable per component');
select lives_ok($$ set constraints all immediate $$, 'every opening entry is balanced');
select is(private.complete_batch_confirmation('30000000-0000-0000-0000-000000000001'), 'skipped', 'a redelivered job does nothing');
select is((select count(*)::int from public.ledger_entry), 2, 'no second opening');

-- A mandate that expires between the request and the job sends the batch back -----------------------
update public.mandate_terms set valid_to = private.paris_today() where mandate_id = '70000000-0000-0000-0000-000000000002';
select is(private.complete_batch_confirmation('30000000-0000-0000-0000-000000000004'), 'mandate_inactive',
  'no posting without an active mandate (R124-3)');
select is((select status from public.boarding_batch where id = '30000000-0000-0000-0000-000000000004'), 'committed',
  'the batch is back to committed');

-- After confirmation: the source of the openings is frozen -------------------------------------------
select throws_ok($$ update public.claim_item set original_minor = 1 where ref = 'F-2' $$, 'LG002', null,
  'claim items of a confirmed account cannot change');
select throws_ok($$ update public.account set currency = 'USD' where external_ref = 'C-1' $$, '23503', null,
  'nor the account''s currency');
select throws_ok($$ delete from public.claim_item where ref = 'F-2' $$, '23503', null,
  'nor can an item with ledger history be deleted');
select throws_ok($$ select * from private.ledger_post('00000000-0000-0000-0000-00000000000a', 'opening', '2026-09-30',
  'second-opening-01', '[]', '{}') $$, 'LG006', null, 'a second opening cannot be posted by hand');
select throws_ok($$ insert into public.ledger_entry (organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                     effective_date, line_count, idempotency_key, request_hash, boarding_batch_id)
  select organization_id, client_organization_id, portfolio_id, account_id, 'opening', effective_date, 2, 'opening-again-001',
         request_hash, boarding_batch_id from public.ledger_entry limit 1 $$, '23505', null,
  'one opening per account');

select * from finish();
rollback;
