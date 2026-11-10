-- M2c-4 review fixes of the nightly checks, the deadlines, the reservation and the reads (design §9.2, §9.3, §9.4,
-- §15, §19; ARCHITECTURE §4):
--   * nc#0   a collection, an approved line or a matched payment whose E is before the business calendar's horizon no
--            longer breaks the queue's deadlines, the schedule's candidates, the nightly checks or the overview: it is
--            flagged `out_of_horizon` and raised as `remittance_deadline_not_computable`, with no breach row;
--   * legal#2 a collection dated before the mandate's first terms version is held to one month (R124-6) and checked;
--            files under no mandate, or under a mandate that never had terms, are not;
--   * legal#1 a mandate delay that cannot be met (1 day) is an alert while the month runs, then due soon, then the
--            violation and a breach row against one month;
--   * legal#3 a run approved whose payout is not debited: `remittance_payout_not_executed` past its requested date,
--            `remittance_payout_overdue` and breach rows past its lines' date (one month for an unmeetable delay);
--   * legal#0 each recorded client event but a proceeding blocks the payout today, fail-closed (M2c-7 brings the exit);
--   * tests-ui#3 / C4 a draft whose preparation failed raises `draft_waiting` at once;
--   * nc#0   the schedule's failures recorded by the worker raise `remittance_schedule_failed`;
--   * perf#0, #2, #3, #5, #6 what the readers read (pg_stat_xact_user_tables), not how long they take.
-- The date-dependent checks run at a given Paris date (run_remittance_checks' p_today), so they never drift with the
-- calendar.
begin;
select plan(52);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000cc', 'servicer', 'Collectoo SAS', '732829320');
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren)
select ('00000000-0000-0000-0000-0000000000c' || n)::uuid, 'creditor_client', '00000000-0000-0000-0000-0000000000cc',
       'Client ' || n, '552100554'
from unnest(array['1', '2', '3', '4', '5', '6', '7', '8']) n;
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000c' || n)::uuid, 'u' || n || '@checks.test', 'authenticated', 'authenticated'
from unnest(array['1', '2']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000cc', 'ops_manager'),
  ('10000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000cc', 'admin');
insert into public.portfolio (id, organization_id, client_organization_id, name)
select ('20000000-0000-0000-0000-0000000000c' || n)::uuid, '00000000-0000-0000-0000-0000000000cc',
       ('00000000-0000-0000-0000-0000000000c' || n)::uuid, 'P' || n
from unnest(array['1', '2', '3', '4', '5', '6', '7', '8']) n;
insert into public.bank_account (id, organization_id, purpose, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000cc', '00000000-0000-0000-0000-0000000000cc', 'client_funds',
   'FR3430001007940000000001001', 'EUR', 'Fonds de tiers', 'camt053', '2025-01-01');
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-0000000000c' || n)::uuid, '00000000-0000-0000-0000-0000000000cc',
       ('00000000-0000-0000-0000-0000000000c' || n)::uuid, 'mandate_document', 'client/checks/m' || n || '.pdf',
       repeat('a', 64), 'application/pdf'
from unnest(array['1', '2', '3', '4', '6', '7', '8']) n;
-- mandates: c1 a 1-day delay; c2 terms from 01/10/2026 only; c3, c4, c7, c8 30 days from 01/01/2026; c6 no terms at
-- all (never confirmable); c5's portfolio has no mandate
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on,
                            insurance_clause_ref)
select ('70000000-0000-0000-0000-0000000000c' || n)::uuid, '00000000-0000-0000-0000-0000000000cc',
       ('00000000-0000-0000-0000-0000000000c' || n)::uuid, 'MAND-C' || n, 'mandate_amicable', '2026-01-01', 'art. 9'
from unnest(array['1', '2', '3', '4', '6', '7', '8']) n;
insert into public.mandate_terms (id, mandate_id, valid_from, remittance_max_days, commission_schedule,
                                  commission_clause_ref, remittance_terms, remittance_clause_ref, document_id)
select ('71000000-0000-0000-0000-0000000000c' || x.n)::uuid, ('70000000-0000-0000-0000-0000000000c' || x.n)::uuid,
       x.valid_from::date, x.days,
       '{"schema": "commission-1", "basis": {"families": "all", "forwards": {"file_recalled": false,
         "before_servicing_start": false, "client_ratification": false}, "on_reversal": "credit"},
         "rules": [{"id": "tout", "tier_key": "tout", "label_fr": "Toutes créances", "match": {},
                    "rate": {"kind": "flat", "rate": "0.15"}}]}',
       'art. 6', '{"schema": "remittance-1", "frequency": "twice_monthly", "netting": {"clause_ref": "art. 7.2"},
                   "clawback": null, "invoice_payment_days": 30}', 'art. 7',
       ('d0000000-0000-0000-0000-0000000000c' || x.n)::uuid
from (values ('1', '2026-01-01', 1), ('2', '2026-10-01', 30), ('3', '2026-01-01', 30), ('4', '2026-01-01', 30),
             ('7', '2026-01-01', 30), ('8', '2026-01-01', 30)) x (n, valid_from, days);
update public.portfolio set mandate_id = ('70000000-0000-0000-0000-0000000000c' || right(id::text, 1))::uuid
where id in (select ('20000000-0000-0000-0000-0000000000c' || n)::uuid
             from unnest(array['1', '2', '3', '4', '6', '7', '8']) n);

create or replace function pg_temp.c(p_n text) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000000c' || p_n)::uuid;
$$;
create or replace function pg_temp.f(p_n text) returns uuid language sql as $$
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.it(p_n text) returns uuid language sql as $$
  select ('c1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.pay(p_n text) returns uuid language sql as $$
  select ('f1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
-- A file of client p_c with one invoice owed (opening as an adjustment), owned and serviced from p_from.
create or replace function pg_temp.file(p_n text, p_c text, p_amount bigint, p_from date) returns void
language plpgsql as $$
begin
  insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                              legal_regime, currency, status)
  values (pg_temp.f(p_n), '00000000-0000-0000-0000-0000000000cc', pg_temp.c(p_c),
          ('20000000-0000-0000-0000-0000000000c' || p_c)::uuid, 'b2b_invoice', 'K-' || p_n, 'commercial_b2b', 'EUR',
          'in_collection');
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type,
                                             valid_from)
  values (pg_temp.f(p_n), pg_temp.c(p_c), '00000000-0000-0000-0000-0000000000cc', 'mandate_amicable', p_from);
  insert into public.claim_item (id, account_id, kind, ref, due_date, original_minor)
  values (pg_temp.it(p_n), pg_temp.f(p_n), 'invoice', 'F-' || p_n, p_from, p_amount);
  perform private.ledger_post('00000000-0000-0000-0000-0000000000cc', 'adjustment', p_from, 'checks-owe-' || p_n,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', pg_temp.it(p_n), 'component', 'principal'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', 'principal')),
    jsonb_build_object('account_id', pg_temp.f(p_n), 'reason', 'ouverture (test)'));
end $$;
-- A payment on the dedicated account (its line, the payment, its cash_in), matched to the file and, unless
-- p_allocate is false, allocated (p_allocated of it; all by default).
create or replace function pg_temp.collect(p_n text, p_amount bigint, p_day date, p_allocate boolean default true,
                                           p_allocated bigint default null)
returns void language plpgsql as $$
declare s uuid := ('e1000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000cc', '80000000-0000-0000-0000-0000000000cc', 'EUR', 'camt053', 'k.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id)
  values (s, '00000000-0000-0000-0000-0000000000cc', '80000000-0000-0000-0000-0000000000cc', s, 1, 't:' || s, 'credit',
          p_amount, 'EUR', p_day, 'debtor_credit', 'E2E-K' || p_n);
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, payer_name, end_to_end_id)
  values (pg_temp.pay(p_n), '00000000-0000-0000-0000-0000000000cc', '80000000-0000-0000-0000-0000000000cc', s,
          'camt053', 'sct', p_amount, 'EUR', p_day, 'PAYEUR ' || p_n, 'E2E-K' || p_n);
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  values (1, '00000000-0000-0000-0000-0000000000cc', 'cash_in', p_day, 'cash_in:' || s || ':' || p_day,
          'bank_statement', s::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cc'),
    (1, 2, 'unallocated_payment', -p_amount, 'EUR', null);
  perform private.ledger_post_set();
  update public.payment set account_id = pg_temp.f(p_n), status = 'matched', match_method = 'rf_structured',
                            matched_at = now()
  where id = pg_temp.pay(p_n);
  if p_allocate then
    perform private.allocation_begin();
    insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy, inputs_hash)
    values (pg_temp.pay(p_n), 1, pg_temp.f(p_n), 'allocate', p_day,
            '{"accessory_rank": "before_principal", "unclassified": "last"}', repeat('0', 64));
    insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
    values (pg_temp.pay(p_n), 1, pg_temp.it(p_n), 'principal', coalesce(p_allocated, p_amount));
    perform private.post_allocations('00000000-0000-0000-0000-0000000000cc', 'ready', 'alloc-k' || p_n);
  end if;
end $$;
-- A check run of the servicer's remittance checks at Paris date p_today (finished, as the nightly's).
create or replace function pg_temp.chk(p_today date) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000cc')
  returning id into v;
  perform private.run_remittance_checks(v, '00000000-0000-0000-0000-0000000000cc', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return v;
end $$;
-- The codes a check run raised about a subject.
create or replace function pg_temp.codes(p_run uuid, p_subject uuid) returns text[] language sql as $$
  select coalesce(array_agg(r.code order by r.code), '{}') from public.payment_check_result r
  where r.run_id = p_run and r.subject_id = p_subject;
$$;
-- What the approval job leaves (emulated: its own tests are 021's): the draft's items frozen into lines with their
-- R124-6 dates, the run approved for p_requested.
create or replace function pg_temp.freeze(p_run uuid, p_requested date) returns void language plpgsql as $$
declare v_transfer uuid;
begin
  update public.remittance_run set job = null, job_token = null, job_queued_at = null where id = p_run;
  insert into public.remittance_line (run_id, line_no, organization_id, client_organization_id, currency,
                                      ledger_entry_id, kind, account_id, portfolio_id, payment_id, encaissement_date,
                                      effective_date, posted_at, deadline, latest_execution_date, unmeetable,
                                      amount_minor, commission_state)
  with i as materialized (   -- the run's items first (the deadline is computed for them only)
    select q.*, e.account_id, a.portfolio_id, e.payment_id, e.effective_date,
           private.encaissement_date(p.booking_date, p.value_date) as e_date,
           coalesce((select mt.remittance_max_days from public.mandate_terms mt
                     join public.portfolio pf on pf.mandate_id = mt.mandate_id
                     where pf.id = a.portfolio_id limit 1), 30) as days
    from private.remittance_pending q
    join public.ledger_entry e on e.id = q.ledger_entry_id
    join public.account a on a.id = e.account_id
    join public.payment p on p.id = e.payment_id
    where q.draft_run_id = p_run)
  select p_run, row_number() over (order by i.posted_at, i.ledger_entry_id), i.organization_id,
         i.client_organization_id, i.currency, i.ledger_entry_id, i.kind, i.account_id, i.portfolio_id, i.payment_id,
         i.e_date, i.effective_date, i.posted_at, d.deadline, d.latest_execution_date, d.unmeetable, i.amount_minor,
         'none'
  from i cross join lateral private.remittance_deadline(i.e_date, i.days) d;
  delete from private.remittance_pending where draft_run_id = p_run;
  update public.remittance_run r set status = 'approved', approved_at = now(),
    approved_by = '10000000-0000-0000-0000-0000000000c1', requested_execution_date = p_requested,
    prepared_at = now(), line_count = s.n, gross_minor = s.gross, net_minor = s.gross, settlement_minor = 0
  from (select count(*)::int as n, sum(l.amount_minor)::bigint as gross from public.remittance_line l
        where l.run_id = p_run) s
  where r.id = p_run;
  insert into public.bank_transfer (organization_id, client_organization_id, kind, debtor_bank_account_id, currency,
                                    amount_minor, payee_name, payee_iban, end_to_end_id, requested_execution_date, run_id)
  select r.organization_id, r.client_organization_id, 'payout', '80000000-0000-0000-0000-0000000000cc', r.currency,
         r.net_minor, 'CLIENT', 'FR7630004000031234567890143', 'RMT' || upper(substr(md5(r.id::text), 1, 12)),
         p_requested, r.id
  from public.remittance_run r where r.id = p_run
  returning id into v_transfer;
  update public.remittance_run set transfer_id = v_transfer where id = p_run;
end $$;
create temporary table t (k text primary key, v uuid) on commit drop;
create temporary table j (k text primary key, v jsonb) on commit drop;
grant all on t, j to authenticated;
-- what this transaction has read of the tables since the last mark
create temporary table _mark (relid oid primary key, seq_scan bigint, idx_tup_fetch bigint, n_tup_upd bigint,
                              idx_scan bigint);
create function pg_temp.mark() returns void language sql as $$
  delete from _mark;
  insert into _mark select x.relid, x.seq_scan, coalesce(x.idx_tup_fetch, 0), x.n_tup_upd, coalesce(x.idx_scan, 0)
  from pg_stat_xact_user_tables x where x.schemaname in ('public', 'private');
$$;
create function pg_temp.since_mark(p_table regclass)
returns table (seq_scan bigint, idx_tup_fetch bigint, n_tup_upd bigint, idx_scan bigint) language sql as $$
  select x.seq_scan - coalesce(m.seq_scan, 0), coalesce(x.idx_tup_fetch, 0) - coalesce(m.idx_tup_fetch, 0),
         x.n_tup_upd - coalesce(m.n_tup_upd, 0), coalesce(x.idx_scan, 0) - coalesce(m.idx_scan, 0)
  from pg_stat_xact_user_tables x left join _mark m on m.relid = x.relid where x.relid = p_table;
$$;

-- the collections
select pg_temp.file('21', '2', 20000, '2026-09-01');
select pg_temp.collect('21', 20000, '2026-09-21');                   -- c2: E before its mandate's first version
select pg_temp.file('41', '4', 40000, '2025-11-01');
select pg_temp.collect('41', 40000, '2025-12-01');                   -- c4: E before the calendar's horizon
select pg_temp.file('42', '4', 42000, '2025-11-01');
select pg_temp.collect('42', 42000, '2025-12-01', false);            -- … and a payment matched, not allocated
select pg_temp.file('51', '5', 50000, '2026-09-01');
select pg_temp.collect('51', 50000, '2026-09-21');                   -- c5: a portfolio under no mandate
select pg_temp.file('61', '6', 60000, '2026-09-01');
select pg_temp.collect('61', 60000, '2026-09-21');                   -- c6: a mandate that never had terms
select pg_temp.file('81', '8', 80000, '2026-09-01');
select pg_temp.collect('81', 80000, private.paris_today() - 3);      -- c8: a recent collection

-- nc#0: the calendar's horizon ---------------------------------------------------------------------------
select results_eq($$ select deadline, latest_execution_date, unmeetable, out_of_horizon
                     from private.remittance_deadline_or_null('2025-12-01', 30) $$,
  $$ values (null::date, null::date, null::boolean, true) $$,
  'an E before the seeded horizon: no dates, out of horizon (instead of 22023)');
select results_eq($$ select deadline, latest_execution_date, unmeetable, out_of_horizon
                     from private.remittance_deadline_or_null('2026-10-12', 30) $$,
  $$ select deadline, latest_execution_date, unmeetable, false from private.remittance_deadline('2026-10-12', 30) $$,
  'within it: remittance_deadline''s dates');
select throws_ok($$ select * from private.remittance_deadline_or_null('2026-10-12', 0) $$, '22023', null,
  'any other error is raised (a delay out of 1..30)');
select results_eq($$ select out_of_horizon, latest_execution_date, monitored from private.pending_item_deadlines(
                       '00000000-0000-0000-0000-0000000000cc') where client_organization_id = pg_temp.c('4') $$,
  $$ values (true, null::date, true) $$,
  'the queue''s deadlines are computed for the servicer: c4''s collection flagged out of horizon');
select results_eq($$ select out_of_horizon, latest_execution_date is null from private.unallocated_payment_deadlines(
                       '00000000-0000-0000-0000-0000000000cc') where payment_id = pg_temp.pay('42') $$,
  $$ values (true, true) $$,
  'so is the payment matched to c4''s file, still in 4710');
select is((select array_agg(client_organization_id::text order by client_organization_id::text)
           from private.remittance_schedule_candidates('00000000-0000-0000-0000-0000000000cc', private.paris_today())
           where client_organization_id in (pg_temp.c('4'), pg_temp.c('8'))),
  array[pg_temp.c('4')::text, pg_temp.c('8')::text], 'the schedule''s candidates are read, c4 among them');
select is((select cardinality(latest_execution_dates)
           from private.remittance_schedule_candidates('00000000-0000-0000-0000-0000000000cc', private.paris_today())
           where client_organization_id = pg_temp.c('4')), 0,
  '(c4 has no date to guard: its alert says so)');
insert into j select 'pc', private.run_payment_checks('00000000-0000-0000-0000-0000000000cc');
insert into t select 'pc', (v ->> 'run_id')::uuid from j where k = 'pc';
select ok((select v ? 'run_id' from j where k = 'pc'), 'the nightly checks run through');
select results_eq($$ select r.subject_type, r.count, r.details ->> 'of' from public.payment_check_result r
                     where r.run_id = (select v from t where k = 'pc') and r.code = 'remittance_deadline_not_computable'
                     order by r.subject_type $$,
  $$ values ('client'::text, 1, 'items'::text), ('servicer'::text, 1, 'payments'::text) $$,
  'and raise remittance_deadline_not_computable for the collection and for the payment');
select is((select count(*)::int from public.remittance_deadline_breach where client_organization_id = pg_temp.c('4')),
  0, 'no breach row for a date the calendar cannot place');
select set_config('request.jwt.claims', json_build_object('sub', '10000000-0000-0000-0000-0000000000c1',
                                                          'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;
select is((select count(*)::int from jsonb_array_elements(public.remittance_overview('a-valider') -> 'to_prepare') x
           where x ->> 'client_id' = '00000000-0000-0000-0000-0000000000c4'), 1,
  '« Reversements » loads, c4 to prepare');
reset role;

-- legal#2: before the first terms version, one month; files under no mandate (with terms) are not checked ------
select results_eq($$ select monitored, max_days, latest_execution_date from private.pending_item_deadlines(
                       '00000000-0000-0000-0000-0000000000cc') where client_organization_id = pg_temp.c('2') $$,
  $$ values (true, 30, '2026-10-20'::date) $$,
  'E 21/09, before the version of 01/10: held to one month (latest execution Tue 20/10)');
select ok(pg_temp.codes((select v from t where k = 'pc'), pg_temp.c('2')) @> array['remittance_deadline_breached'],
  'not paid by then: the violation');
select results_eq($$ select latest_execution_date, blocked_reason from public.remittance_deadline_breach
                     where client_organization_id = pg_temp.c('2') $$,
  $$ values ('2026-10-20'::date, null::text) $$, 'and a breach row');
select is((select array_agg(monitored order by client_organization_id) from private.pending_item_deadlines(
             '00000000-0000-0000-0000-0000000000cc') where client_organization_id in (pg_temp.c('5'), pg_temp.c('6'))),
  array[false, false], 'a portfolio under no mandate, a mandate that never had terms: not monitored');
select is((select count(*)::int from public.payment_check_result r where r.run_id = (select v from t where k = 'pc')
             and r.subject_id in (pg_temp.c('5'), pg_temp.c('6'))), 0, 'no alert or violation for them');
select is((select count(*)::int from public.remittance_deadline_breach
           where client_organization_id in (pg_temp.c('5'), pg_temp.c('6'))), 0, 'nor a breach row');

-- legal#1 and legal#3: a 1-day delay cannot be met, one month can; a run approved and not debited -------------------
select pg_temp.file('11', '1', 10000, '2026-09-01');
select pg_temp.collect('11', 10000, '2026-10-05');                   -- c1: E Mon 05/10 under a 1-day delay
select pg_temp.file('31', '3', 30000, '2026-09-01');
select pg_temp.collect('31', 30000, '2026-10-05');                   -- c3: E Mon 05/10, 30 days: latest Tue 03/11
-- c3's collection approved for Fri 30/10 (its latest execution Tue 03/11), its payout never debited
insert into t select 'r3', private.create_remittance_run('00000000-0000-0000-0000-0000000000cc', pg_temp.c('3'), 'EUR',
                                                         'manual', null, null);
select pg_temp.freeze((select v from t where k = 'r3'), '2026-10-30');
select results_eq($$ select latest_execution_date, unmeetable, check_latest_execution_date, check_alert_soon_date
                     from private.pending_item_deadlines('00000000-0000-0000-0000-0000000000cc')
                     where client_organization_id = pg_temp.c('1') $$,
  $$ values ('2026-10-05'::date, true, '2026-11-03'::date, '2026-10-27'::date) $$,
  'E Mon 05/10 under 1 day: latest execution on E (unmeetable); held to one month (Tue 03/11, J-5 Tue 27/10)');
insert into t select 'k1', pg_temp.chk('2026-10-20');
select is(pg_temp.codes((select v from t where k = 'k1'), pg_temp.c('1')), array['remittance_delay_unmeetable'],
  '20/10: « délai intenable », an alert while the month runs');
select is(pg_temp.codes((select v from t where k = 'k1'), (select v from t where k = 'r3')), '{}'::text[],
  'the approved run: nothing before the date it was ordered for');
insert into t select 'k2', pg_temp.chk('2026-10-28');
select is(pg_temp.codes((select v from t where k = 'k2'), pg_temp.c('1')),
  array['remittance_delay_unmeetable', 'remittance_due_soon'], '28/10: and due soon against the month (J-5)');
select is((select count(*)::int from public.remittance_deadline_breach
           where client_organization_id in (pg_temp.c('1'), pg_temp.c('3'))), 0, 'no breach row yet');
insert into t select 'k3', pg_temp.chk('2026-11-04');
select is(pg_temp.codes((select v from t where k = 'k3'), pg_temp.c('1')), array['remittance_deadline_breached'],
  '04/11: the month passed — the violation');
select results_eq($$ select deadline, latest_execution_date, blocked_reason from public.remittance_deadline_breach
                     where client_organization_id = pg_temp.c('1') $$,
  $$ values ('2026-11-04'::date, '2026-11-03'::date, null::text) $$,
  'and a breach row against one month');
select is(pg_temp.codes((select v from t where k = 'k3'), (select v from t where k = 'r3')),
  array['remittance_payout_not_executed', 'remittance_payout_overdue'],
  'the approved run, not debited past its lines'' date: the violation (and past its requested date, the alert)');
select results_eq($$ select run_id, latest_execution_date, requested_execution_date from public.remittance_deadline_breach
                     where client_organization_id = pg_temp.c('3') $$,
  $$ select (select v from t where k = 'r3'), '2026-11-03'::date, '2026-10-30'::date $$,
  'and a breach row naming the run and the date it was ordered for');
select is(pg_temp.codes((select v from t where k = 'k3'), pg_temp.c('3')), '{}'::text[],
  '(its collection is no longer reported as waiting)');
-- c1's collection approved for 30/10 too: its own date (05/10) long past, it is held to one month
insert into t select 'r1', private.create_remittance_run('00000000-0000-0000-0000-0000000000cc', pg_temp.c('1'), 'EUR',
                                                         'manual', null, null);
select pg_temp.freeze((select v from t where k = 'r1'), '2026-10-30');
insert into t select 'k4', pg_temp.chk('2026-10-31');
select is(pg_temp.codes((select v from t where k = 'k4'), (select v from t where k = 'r1')),
  array['remittance_payout_not_executed'], '31/10: not debited on its date: an alert; within the month: no breach');
select is(pg_temp.codes((select v from t where k = 'k4'), (select v from t where k = 'r3')),
  array['remittance_payout_not_executed'], '(c3''s run within its lines'' date then)');
insert into t select 'k5', pg_temp.chk('2026-11-04');
select ok(pg_temp.codes((select v from t where k = 'k5'), (select v from t where k = 'r1'))
          @> array['remittance_payout_overdue'], '04/11: past the month: the violation');
update public.remittance_run set status = 'booked', booked_on = '2026-11-02' where id = (select v from t where k = 'r3');
insert into t select 'k6', pg_temp.chk('2026-11-05');
select is(pg_temp.codes((select v from t where k = 'k6'), (select v from t where k = 'r3')), '{}'::text[],
  'booked (the payout debited): nothing');

-- perf#3: a later run's reservation reads no payment; « Actualiser » reserves only what came since ---------------
select pg_temp.file('32', '3', 32000, '2026-09-01');
select pg_temp.collect('32', 32000, private.paris_today() - 3);
select pg_temp.mark();
insert into t select 'r3b', private.create_remittance_run('00000000-0000-0000-0000-0000000000cc', pg_temp.c('3'), 'EUR',
                                                          'manual', null, null);
select results_eq($$ select idx_scan, seq_scan from pg_temp.since_mark('public.payment') $$,
  $$ values (0::bigint, 0::bigint) $$, 'a run after a booked one: its service period from the previous K, no probe');
select is((select service_from from public.remittance_run where id = (select v from t where k = 'r3b')),
  (select (known_at at time zone 'Europe/Paris')::date from public.remittance_run where id = (select v from t where k = 'r3')),
  'the previous run''s K');
select pg_temp.file('33', '3', 33000, '2026-09-01');
select pg_temp.collect('33', 33000, private.paris_today() - 3);
update public.remittance_run set job = null, job_token = null, job_queued_at = null
where id = (select v from t where k = 'r3b');
select pg_temp.mark();
select set_config('request.jwt.claims', json_build_object('sub', '10000000-0000-0000-0000-0000000000c1',
                                                          'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;
insert into j select 'rf', public.refresh_remittance_run('rf-checks-0001', (select v from t where k = 'r3b'),
  (select version from public.remittance_run where id = (select v from t where k = 'r3b')));
reset role;
select is((select v ->> 'items' from j where k = 'rf'), '2', '« Actualiser »: the reserved item and the new one');
select is((select n_tup_upd from pg_temp.since_mark('private.remittance_pending')), 1::bigint,
  'one item updated: the reservation kept, only the new one reserved');

-- perf#7: the prepare reads the latest tier-history state of each key, not the history ------------------------------
insert into public.remittance_key_state (organization_id, client_organization_id, account_id, tier_key, run_id, cause,
                                         commission_minor)
select '00000000-0000-0000-0000-0000000000cc', pg_temp.c('3'), pg_temp.f('31'), 'tout', (select v from t where k = 'r3'),
       'approved', g * 100
from generate_series(1, 12) g;
select pg_temp.mark();
select results_eq($$ select tier_key, commission_minor from private.remittance_key_states(
                       array[pg_temp.f('31'), pg_temp.f('32')], array['tout', 'tout']) $$,
  $$ values ('tout'::text, 1200::bigint) $$, 'the latest state of each key asked (none for a key never priced)');
select results_eq($$ select seq_scan, idx_tup_fetch from pg_temp.since_mark('public.remittance_key_state') $$,
  $$ values (0::bigint, 1::bigint) $$, 'one row read, not the twelve');
select is(private.remittance_history_seq(pg_temp.c('3')),
  (select max(seq) from public.remittance_key_state where client_organization_id = pg_temp.c('3')),
  'the client''s last history number');

-- perf#6: the unreserved collections only ------------------------------------------------------------------------
select is((select count(*)::int from private.pending_item_deadlines('00000000-0000-0000-0000-0000000000cc', true)
           where client_organization_id = pg_temp.c('3')), 0, 'reserved by the draft: left out on request');
select is((select count(*)::int from private.pending_item_deadlines('00000000-0000-0000-0000-0000000000cc')
           where client_organization_id = pg_temp.c('3')), 2, '(counted otherwise)');

-- C4 / tests-ui#3: a failed preparation alerts at once -------------------------------------------------------------
insert into t select 'r8', private.create_remittance_run('00000000-0000-0000-0000-0000000000cc', pg_temp.c('8'), 'EUR',
                                                         'manual', null, null);
select private.remittance_prepare_failed((select v from t where k = 'r8'),
  (select job_token from public.remittance_run where id = (select v from t where k = 'r8')), 'prepare_failed',
  'business calendar: test');
insert into t select 'k7', pg_temp.chk(private.paris_today());
select results_eq($$ select code, details ->> 'prepare_failed', details ->> 'failure_code' from public.payment_check_result
                     where run_id = (select v from t where k = 'k7') and subject_id = (select v from t where k = 'r8') $$,
  $$ values ('draft_waiting'::text, 'true'::text, 'prepare_failed'::text) $$,
  'a draft whose preparation failed: draft_waiting, at once, with why');

-- nc#0: the schedule's failures, as the worker records them ----------------------------------------------------------
select private.record_remittance_schedule_failure('00000000-0000-0000-0000-0000000000cc', pg_temp.c('8'), 'client',
                                                  'remittance run: a client of the servicer');
select private.record_remittance_schedule_failure('00000000-0000-0000-0000-0000000000cc', null, 'dead', '');
select private.record_remittance_schedule_failure(gen_random_uuid(), null, 'dead', 'an unknown servicer: nothing');
insert into t select 'k8', pg_temp.chk(private.paris_today());
select results_eq($$ select count, details -> 'codes', details -> 'client_ids' from public.payment_check_result
                     where run_id = (select v from t where k = 'k8') and code = 'remittance_schedule_failed' $$,
  $$ values (2, '["client", "dead"]'::jsonb, '["00000000-0000-0000-0000-0000000000c8"]'::jsonb) $$,
  'remittance_schedule_failed: the failures of the last day, the clients named');

-- legal#0: each recorded event but a proceeding blocks the payout today (fail-closed until M2c-7) -----------------------
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type) values
  ('d1000000-0000-0000-0000-0000000000c7', '00000000-0000-0000-0000-0000000000cc', pg_temp.c('7'), 'payout_rib',
   'client/checks/rib7.pdf', repeat('b', 64), 'application/pdf'),
  ('d2000000-0000-0000-0000-0000000000c7', '00000000-0000-0000-0000-0000000000cc', pg_temp.c('7'),
   'client_status_evidence', 'client/checks/ev7.pdf', repeat('c', 64), 'application/pdf');
insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                          evidence_document_id, proposed_by)
values ('90000000-0000-0000-0000-0000000000c7', '00000000-0000-0000-0000-0000000000cc', pg_temp.c('7'), 'EUR',
        'FR7630004000031234567890143', 'CLIENT 7', 'd1000000-0000-0000-0000-0000000000c7',
        '10000000-0000-0000-0000-0000000000c1');
update public.client_payout_account set status = 'active', confirmed_at = now(), confirmed_via = 'second_admin',
  confirmed_by = '10000000-0000-0000-0000-0000000000c2' where id = '90000000-0000-0000-0000-0000000000c7';
select is(private.remittance_payout_blockers(pg_temp.c('7'), 'EUR', private.paris_today()), '{}'::text[],
  'a confirmed payee: nothing blocks');
create function pg_temp.blockers_after(p_kind text) returns text[] language plpgsql as $$
declare v text[];
begin
  -- recorded before the payee was confirmed: re-confirming the payee does not lift it either
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, recorded_by, recorded_at)
  values ('00000000-0000-0000-0000-0000000000cc', pg_temp.c('7'), p_kind, private.paris_today() - 1,
          'd2000000-0000-0000-0000-0000000000c7', '10000000-0000-0000-0000-0000000000c1', now() - interval '1 hour');
  v := private.remittance_payout_blockers(pg_temp.c('7'), 'EUR', private.paris_today());
  raise exception using errcode = 'P0001', message = coalesce(array_to_string(v, ','), '');
exception when sqlstate 'P0001' then
  return string_to_array(nullif(sqlerrm, ''), ',');
end $$;
select is(pg_temp.blockers_after('death'), array['client_status:death'], 'a death blocks the payout');
select is(pg_temp.blockers_after('guardianship'), array['client_status:guardianship'], 'a guardianship too');
select is(pg_temp.blockers_after('mandate_ended'), array['client_status:mandate_ended'], 'a mandate''s end too');
select is(pg_temp.blockers_after('liquidation'), array['client_status:liquidation'],
  'a liquidation too (until a court-appointed account is confirmed after it)');
select is(pg_temp.blockers_after('proceeding_opened'), null::text[],
  'a proceeding opened does not (§13 #9: its pre-opening documents are not netted)');

-- perf#0, #2, #5: what the nightly checks read -----------------------------------------------------------------------
select pg_temp.file('82', '8', 82000, '2026-09-01');
select pg_temp.collect('82', 82000, private.paris_today() - 3, true, 30000);      -- overpaid: partially allocated
select is((select unallocated_minor from private.unallocated_payment_deadlines('00000000-0000-0000-0000-0000000000cc')
           where payment_id = pg_temp.pay('82')), 52000::bigint, 'a partly allocated payment: 520 € still in 4710');
select pg_temp.mark();
select private.unallocated_payment_deadlines('00000000-0000-0000-0000-0000000000cc');
select results_eq($$ select (select seq_scan from pg_temp.since_mark('public.ledger_account')),
                            (select seq_scan from pg_temp.since_mark('public.ledger_posting')),
                            (select seq_scan from pg_temp.since_mark('public.ledger_entry')),
                            (select seq_scan from pg_temp.since_mark('public.payment')) $$,
  $$ values (0::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'the unallocated money is read by key from each payment (no scan of the 4710 pool or the accounts)');
-- a run approved long ago, not changed since the previous check run: I16 leaves its lines alone but on Sundays
alter table public.remittance_run disable trigger remittance_run_touch;
update public.remittance_run set updated_at = now() - interval '5 days' where id = (select v from t where k = 'r3');
alter table public.remittance_run enable trigger remittance_run_touch;
select pg_temp.mark();
select pg_temp.chk('2026-11-05');       -- a Thursday
insert into j select 'thu', to_jsonb((select idx_tup_fetch from pg_temp.since_mark('public.remittance_line')));
select results_eq($$ select (select seq_scan from pg_temp.since_mark('public.ledger_account')),
                            (select seq_scan from pg_temp.since_mark('public.ledger_posting')),
                            (select seq_scan from pg_temp.since_mark('public.ledger_entry')),
                            (select seq_scan from pg_temp.since_mark('public.remittance_line')) $$,
  $$ values (0::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'the nightly checks scan no ledger table and no run''s lines whole (I18 by the accounts'' indexes)');
select pg_temp.mark();
select pg_temp.chk('2026-11-08');       -- a Sunday
select is((select idx_tup_fetch from pg_temp.since_mark('public.remittance_line'))
          - (select (v #>> '{}')::bigint from j where k = 'thu'), 1::bigint,
  'I16 reads a run frozen long ago only on Sundays (the booked run''s one line more than on Thursday)');

select * from finish();
rollback;
