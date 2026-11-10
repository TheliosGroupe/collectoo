-- M2c-3 (M2-13): the engines' reference data and the SQL twin of the R124-6 deadline. VAT rates with their legal
-- references and the 2027 review tripwire (rule pack vat/fr); the conservative business calendar, every day of
-- 2026–2031 (rule pack remittance/fr: weekends, French public holidays, TARGET closing days); the deadline (founder
-- #2: the shorter of the mandate's delay and one calendar month, no weekend or holiday extension; latest execution
-- the business day before the last business day); the reference-data alerts; read access, writes and plans.
-- Design docs/design/m2c-remittances.md §3, §8.5, §9.2, §15, §18; ADR-0014 (M2c-3). The equality with the YAML packs
-- and the parity with the Python engine on 10,000 dates: worker/tests/test_engines_integration.py.
begin;
select plan(48);

create or replace function pg_temp.as_user(p_user uuid, p_aal text default 'aal1') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
grant execute on all functions in schema pg_temp to authenticated;
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-0000000020aa', 'servicer', 'Cabinet E');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000020a1', 'creditor_client', '00000000-0000-0000-0000-0000000020aa', 'Client E');
insert into auth.users (id, email, aud, role) values
  ('20000000-0000-0000-0000-000000000001', 'collector@engines.test', 'authenticated', 'authenticated'),
  ('20000000-0000-0000-0000-000000000002', 'client@engines.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role) values
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000020aa', 'collector'),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000020a1', 'client_viewer');

-- VAT rates ------------------------------------------------------------------------------------------------
select is((select array_agg(r.legal_ref || ' ' || r.rate || ' ' || r.valid_from || '…' || coalesce(r.valid_to::text, '')
                            order by r.valid_from) from public.vat_rate r),
  array['CGI art. 278 0.2000 2014-01-01…2027-01-01', 'CIBS art. L213-151 0.2000 2027-01-01…'],
  'the standard rate: CGI 278 until 2026-12-31, CIBS L213-151 from 2027-01-01 (rule pack vat/fr)');
select is(array[private.vat_rate_on('2026-11-10'), private.vat_rate_on('2026-12-31'), private.vat_rate_on('2027-01-01')],
  array[0.2000, 0.2000, 0.2000]::numeric[], 'the rate in force on a day');
select throws_ok($$ select private.vat_rate_on('2013-12-31') $$, '22023', null, 'no rate before the first row');
select throws_ok($$ select private.vat_rate_on('2026-11-10', 'standard', 'FR-971') $$, '22023', null,
  'no rate outside mainland France (OQ-42)');
select throws_ok($$ insert into public.vat_rate (code, territory, rate, valid_from, valid_to, legal_ref, legal_url)
                    values ('standard', 'FR-metro', 0.2100, '2026-06-01', '2026-07-01', 'X',
                            'https://librejustice.fr/norm/fr/x/1') $$,
  '23P01', null, 'two rows of a rate never overlap');
select throws_ok($$ update public.vat_rate set rate = 0.2100 where valid_from = '2014-01-01' $$, '23514', null,
  'a rate never changes');
select throws_ok($$ update public.vat_rate set valid_to = '2026-12-01' where valid_from = '2014-01-01' $$, '23514', null,
  'a closed row''s end never moves');
select throws_ok($$ delete from public.vat_rate where valid_from = '2014-01-01' $$, '23514', null,
  'a rate is never deleted');
select throws_ok($$ truncate public.vat_rate $$, '23514', null, 'nor truncated');
savepoint review;
select lives_ok($$ update public.vat_rate set reviewed_on = '2026-11-20', reviewed_by = 'Le fondateur'
                   where valid_from = '2027-01-01' $$, 'the 2027 row''s review is recorded (by a migration)');
select throws_ok($$ update public.vat_rate set reviewed_on = '2026-11-21' where valid_from = '2027-01-01' $$,
  '23514', null, 'once');
select is((select count(*)::int from private.reference_data_alerts('2026-12-01') a where a.code = 'vat_pack_review'),
  0, 'reviewed: no vat_pack_review alert');
select lives_ok($$ update public.vat_rate set valid_to = '2028-01-01' where valid_from = '2027-01-01' $$,
  'an open row may be closed (the next rate follows in a new row)');
rollback to savepoint review;
select throws_ok($$ update public.vat_rate set reviewed_on = '2026-11-20' where valid_from = '2027-01-01' $$,
  '23514', null, 'a review names who reviewed');

-- Business calendar ------------------------------------------------------------------------------------------
select is((select array[count(*), count(*) filter (where c.closed), count(*) filter (where 'weekend' = any (c.sources)),
                        count(*) filter (where c.sources && array['public_holiday', 'target'])]::int[]
           from public.business_calendar c),
  array[2191, 690, 626, 78],
  'every day of 2026–2031; 626 weekend days and 78 holidays or TARGET days (13 a year), 690 closed');
select is((select array_agg(c.day::text || ' ' || c.label order by c.day) from public.business_calendar c
           where c.day between '2026-01-01' and '2026-12-31' and c.sources && array['public_holiday', 'target']),
  array['2026-01-01 Jour de l''an', '2026-04-03 Vendredi saint', '2026-04-06 Lundi de Pâques', '2026-05-01 1er mai',
        '2026-05-08 8 mai', '2026-05-14 Ascension', '2026-05-25 Lundi de Pentecôte', '2026-07-14 14 juillet',
        '2026-08-15 Assomption ; samedi', '2026-11-01 Toussaint ; dimanche', '2026-11-11 11 novembre', '2026-12-25 Noël',
        '2026-12-26 26 décembre ; samedi'],
  '2026: the French public holidays (C. trav. L3133-1) and the TARGET days, with their labels');
select is((select array_agg(c.day order by c.day) from public.business_calendar c
           where c.label like 'Lundi de Pâques%'),
  array['2026-04-06', '2027-03-29', '2028-04-17', '2029-04-02', '2030-04-22', '2031-04-14']::date[],
  'Easter Monday each year (Gregorian computus)');
select is((select array[c.closed::text, array_to_string(c.sources, ',')] from public.business_calendar c
           where c.day = '2026-04-03'), array['true', 'target'], 'Good Friday: a TARGET day, not a public holiday');
select is((select array_agg(c.closed order by c.day) from public.business_calendar c
           where c.day between '2026-11-09' and '2026-11-15'),
  array[false, false, true, false, false, true, true], 'a week of November 2026');
select is(private.business_calendar_horizon(), '2031-12-31'::date, 'the seeded horizon ends 2031-12-31');
select throws_ok($$ update public.business_calendar set closed = false where day = '2026-11-11' $$, '23514', null,
  'the calendar is append-only (no update)');
select throws_ok($$ delete from public.business_calendar where day = '2026-11-11' $$, '23514', null, 'no delete');
select throws_ok($$ insert into public.business_calendar (day, closed) values ('2026-11-12', false) $$, '23505', null,
  'one row per day');
select throws_ok($$ insert into public.business_calendar (day, closed, label, sources)
                    values ('2032-01-01', true, null, array['target']) $$, '23514', null,
  'a closed day has a label and sources');

-- The deadline (§9.2) ----------------------------------------------------------------------------------------
select is(array[private.add_month_cpc641('2027-01-31'), private.add_month_cpc641('2028-01-31'),
                private.add_month_cpc641('2026-03-31'), private.add_month_cpc641('2026-12-31'),
                private.add_month_cpc641('2026-10-12')],
  array['2027-02-28', '2028-02-29', '2026-04-30', '2027-01-31', '2026-11-12']::date[],
  'one month (CPC 641 al. 2): the same day of the next month, else its last day');
select is(array[private.encaissement_date('2026-10-12', '2026-10-09'), private.encaissement_date('2026-10-12', null),
                private.encaissement_date('2026-10-12', '2026-10-13')],
  array['2026-10-09', '2026-10-12', '2026-10-12']::date[], 'E = the earlier of the booking and value dates');
select is((select array[d.deadline, d.last_business_day, d.latest_execution_date, d.alert_soon_date,
                        d.alert_critical_date] from private.remittance_deadline('2026-10-12', 30) d),
  array['2026-11-11', '2026-11-10', '2026-11-09', '2026-11-02', '2026-11-06']::date[],
  'E 12/10/2026: deadline Wed 11/11 (a holiday) → Tue 10/11 → latest execution Mon 09/11 (design §9.2)');
select is((select array[d.deadline, d.last_business_day, d.latest_execution_date]
           from private.remittance_deadline('2027-01-31', 30) d),
  array['2027-02-28', '2027-02-26', '2027-02-25']::date[],
  'E Sun 31/01/2027: least(02/03, 28/02) = Sun 28/02 → Fri 26/02 → Thu 25/02');
select is((select array[d.deadline, d.latest_execution_date] from private.remittance_deadline('2026-11-10', 30) d),
  array['2026-12-10', '2026-12-09']::date[], 'E 10/11/2026 (P6, §7.2): 10/12 → latest execution Wed 09/12');
select is((select array[d.deadline, d.latest_execution_date] from private.remittance_deadline('2026-10-12', 10) d),
  array['2026-10-22', '2026-10-21']::date[], 'a shorter delay in the mandate wins');
select is((select array[d.deadline, d.last_business_day, d.latest_execution_date]
           from private.remittance_deadline('2026-11-26', 30) d),
  array['2026-12-26', '2026-12-24', '2026-12-23']::date[], 'Christmas: no extension, two days earlier');
select is((select array[d.deadline, d.last_business_day, d.latest_execution_date]
           from private.remittance_deadline('2027-02-26', 30) d),
  array['2027-03-26', '2027-03-25', '2027-03-24']::date[], 'Good Friday 2027 (TARGET closed)');
select is((select array[d.alert_soon_date, d.alert_critical_date] from private.remittance_deadline('2026-10-12', 30, 3, 2) d),
  array['2026-11-04', '2026-11-05']::date[], 'other alert margins (business days before the latest execution)');
select throws_ok($$ select * from private.remittance_deadline('2031-12-15', 30) $$, '22023', null,
  'a deadline beyond the seeded horizon is refused, never guessed');
select throws_ok($$ select * from private.remittance_deadline('2025-12-31', 1) $$, '22023', null,
  'so is a computation that walks back before it');
select throws_ok($$ select * from private.remittance_deadline('2026-10-12', 31) $$, '22023', null,
  'the mandate''s delay is 1..30 days');
select throws_ok($$ select * from private.remittance_deadline('2026-10-12', 30, 0, 1) $$, '22023', null,
  'alert margins are business days, at least 1');

-- Plans (ARCHITECTURE §4): the calendar is read by key whatever the statistics (enable_seqscan off) -------------
create temporary table scans as
  select s.seq_scan, s.idx_scan from pg_stat_xact_user_tables s
  where s.schemaname = 'public' and s.relname = 'business_calendar';
select count(*) from generate_series(0, 199) k
cross join lateral private.remittance_deadline('2026-02-01'::date + k, 30) d;
select is((select s.seq_scan - (select seq_scan from scans) from pg_stat_xact_user_tables s
           where s.schemaname = 'public' and s.relname = 'business_calendar'), 0::bigint,
  '200 deadlines: no sequential scan of the calendar');
select ok((select s.idx_scan - (select idx_scan from scans) from pg_stat_xact_user_tables s
           where s.schemaname = 'public' and s.relname = 'business_calendar') between 200 and 400,
  'one or two index scans per deadline (the horizon, the window)');

-- Reference-data alerts (§15) --------------------------------------------------------------------------------
select is((select count(*)::int from private.reference_data_alerts('2026-11-30')), 0,
  '2026-11-30: no alert');
select is((select array_agg(a.code || ' ' || (a.details ->> 'legal_ref')) from private.reference_data_alerts('2026-12-01') a),
  array['vat_pack_review CIBS art. L213-151'], 'from 2026-12-01 the 2027 VAT row awaits its review');
select is((select array_agg(a.code order by a.code) from private.reference_data_alerts('2031-01-01') a),
  array['calendar_horizon', 'vat_pack_review'], 'from 2031-01-01 less than 12 months are seeded');
select is((select count(*)::int from private.reference_data_alerts('2030-12-31') a where a.code = 'calendar_horizon'), 0,
  '2030-12-31: 12 months still seeded');

-- Read access, writes, grants --------------------------------------------------------------------------------
select is((select array_agg(c.relname::text order by c.relname) from pg_class c
           join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relname in ('vat_rate', 'business_calendar') and c.relrowsecurity),
  array['business_calendar', 'vat_rate'], 'RLS on both new tables');
select is((select array_agg(p order by p) from unnest(array['public.vat_rate', 'public.business_calendar']) p
           where has_table_privilege('authenticated', p, 'INSERT') or has_table_privilege('authenticated', p, 'UPDATE')
              or has_table_privilege('authenticated', p, 'DELETE') or has_table_privilege('anon', p, 'SELECT')),
  null, 'no direct write by the API''s roles, no read by anon');
set local role authenticated;
select pg_temp.as_user('20000000-0000-0000-0000-000000000001');
select is((select array[(select count(*) from public.vat_rate), (select count(*) from public.business_calendar)]::int[]),
  array[2, 2191], 'a collector reads the reference data (rates, calendar)');
select pg_temp.as_user('20000000-0000-0000-0000-000000000002');
select is((select array[(select count(*) from public.vat_rate), (select count(*) from public.business_calendar)]::int[]),
  array[2, 2191], 'so does a client user');
reset role;
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'private' and p.proname in ('vat_rate_on', 'business_calendar_horizon', 'encaissement_date',
                                                         'add_month_cpc641', 'remittance_deadline', 'reference_data_alerts')
             and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE')
             and has_function_privilege('service_role', p.oid, 'EXECUTE')
             and p.proconfig @> array['search_path=""']),
  array['add_month_cpc641', 'business_calendar_horizon', 'encaissement_date', 'reference_data_alerts',
        'remittance_deadline', 'vat_rate_on'],
  'the engines'' functions: the worker''s (service role) only, with an empty search path');

select * from finish();
rollback;
