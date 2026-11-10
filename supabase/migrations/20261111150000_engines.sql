-- M2c-3 (M2-13): the engines' reference data and the SQL twin of the remittance deadline. The commission engine
-- itself is pure Python (collectoo_worker.remittance.commission, engine `commission-1`); what the database needs from
-- this slice is the data both sides read and the deadline the guard and the alerts will compute in SQL (M2c-4).
-- Design: docs/design/m2c-remittances.md §3 (CGI 256, 269, 278, 289; the 2027 recodification in the CIBS), §8.4, §8.5,
-- §9.2, §9.3, §18, §21 (M2c-3), §24 (founder decisions, all accepted 2026-11-09: #1 runs on the 1st and the 16th and
-- a guard before any deadline, #2 the shorter of the mandate's delay and one calendar month from the earlier of the
-- booking and value dates, with no weekend or holiday extension). Decisions: docs/adr/0014 (M2c-3 addendum).
-- Forward-only: nothing earlier is edited or redefined.
--
-- What it adds:
--   * `public.vat_rate`: the VAT rate rows of rule pack worker/rule_packs/vat/fr.yaml (the standard rate in mainland
--     France, CGI 278 until 2026-12-31, CIBS L213-151 from 2027-01-01), each with its legal reference and, for the
--     2027 row, the review it awaits (due 2026-12-01). A CI test checks the table equals the YAML. Rows are reference
--     data: never deleted; an update may only close an open row (valid_to) or record its review, once;
--   * `public.business_calendar`: every day of the seeded horizon (2026-01-01 … 2031-12-31) of the FR-conservative
--     calendar of rule pack worker/rule_packs/remittance/fr.yaml — closed on Saturdays, Sundays, French public
--     holidays (C. trav. L3133-1) and TARGET closing days — with its French label and sources. The holiday rows below
--     are generated from the pack (`python -m collectoo_worker.remittance.calendar`); a CI test checks the table equals
--     the calendar the Python engine computes. Append-only: a later migration adds years;
--   * the SQL twin of the R124-6 deadline (§9.2): private.encaissement_date, private.add_month_cpc641,
--     private.remittance_deadline (deadline, last business day, latest execution date, alert dates, and whether the
--     delay leaves no business day to pay out after the encaissement) — the same as collectoo_worker.remittance.deadline
--     on 10,000 generated encaissements (CI parity); both refuse a date whose computation leaves the seeded horizon
--     (22023);
--   * private.vat_rate_on(day) and private.reference_data_alerts(today): `vat_pack_review` (a row's review is due and
--     not recorded) and `calendar_horizon` (less than 12 months seeded). M2c-4 adds them to the nightly checks when it
--     redefines private.run_payment_checks; CI fails on both already (worker/tests/test_vat.py, test_deadline.py).
-- Plans (ARCHITECTURE §4): the calendar is read by key only — one index range scan of at most 41 rows per deadline,
-- under `enable_seqscan = off`, so no statistics can turn it into a scan of the table; callers compute one deadline
-- per distinct (encaissement date, delay), not per line.

------------------------------------------------------------------------------------------
-- VAT rates (rule pack vat/fr)
------------------------------------------------------------------------------------------

create table public.vat_rate (
  code text not null check (code in ('standard')),
  territory text not null check (territory in ('FR-metro')),
  rate numeric(6, 4) not null check (rate >= 0 and rate <= 1),
  valid_from date not null,
  valid_to date,                                                  -- exclusive
  legal_ref text not null check (length(btrim(legal_ref)) between 1 and 200),
  legal_url text not null check (legal_url like 'https://librejustice.fr/norm/%'),
  review_due_on date,                                             -- the dated tripwire (2027 recodification)
  reviewed_on date,
  reviewed_by text check (length(btrim(reviewed_by)) between 1 and 200),
  primary key (code, territory, valid_from),
  check (valid_to is null or valid_to > valid_from),
  check ((reviewed_on is null) = (reviewed_by is null)),
  check (reviewed_on is null or review_due_on is not null),
  exclude using gist (code with =, territory with =, daterange(valid_from, valid_to, '[)') with &&)
);
comment on table public.vat_rate is
  'VAT rates with their legal reference (rule pack worker/rule_packs/vat/fr.yaml; CI checks the table equals it).';
comment on column public.vat_rate.review_due_on is
  'From this day the row must have been re-read and its review recorded (CI tripwire, vat_pack_review alert).';

create or replace function private.vat_rate_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op <> 'UPDATE' then
    raise exception 'vat rate: % refused (rates are dated reference data: close a row and add the next one)', tg_op
      using errcode = 'check_violation';
  end if;
  if (new.code, new.territory, new.rate, new.valid_from, new.legal_ref, new.legal_url, new.review_due_on)
     is distinct from (old.code, old.territory, old.rate, old.valid_from, old.legal_ref, old.legal_url,
                       old.review_due_on)
     or (old.valid_to is not null and new.valid_to is distinct from old.valid_to)
     or (old.reviewed_on is not null and (new.reviewed_on, new.reviewed_by) is distinct from (old.reviewed_on,
                                                                                         old.reviewed_by)) then
    raise exception 'vat rate: only an open row''s end and a review not yet recorded may be set'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger vat_rate_guard before update or delete on public.vat_rate
  for each row execute function private.vat_rate_guard();
alter table public.vat_rate enable always trigger vat_rate_guard;
create trigger vat_rate_no_truncate before truncate on public.vat_rate
  for each statement execute function private.refuse_change();
alter table public.vat_rate enable always trigger vat_rate_no_truncate;

insert into public.vat_rate (code, territory, rate, valid_from, valid_to, legal_ref, legal_url, review_due_on) values
  ('standard', 'FR-metro', 0.2000, '2014-01-01', '2027-01-01', 'CGI art. 278',
   'https://librejustice.fr/norm/fr/code-general-des-impots/278', null),
  ('standard', 'FR-metro', 0.2000, '2027-01-01', null, 'CIBS art. L213-151',
   'https://librejustice.fr/norm/fr/code-des-impositions-sur-les-biens-et-services/l213-151', '2026-12-01');

-- The rate in force on a day (the invoice's issue date, design §8.4); none → 22023.
create or replace function private.vat_rate_on(p_day date, p_code text default 'standard',
                                               p_territory text default 'FR-metro')
returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  v numeric;
begin
  select r.rate into v from public.vat_rate r
  where r.code = p_code and r.territory = p_territory and r.valid_from <= p_day
    and (r.valid_to is null or p_day < r.valid_to);
  if v is null then
    raise exception 'vat rate: no % rate for % on %', p_code, p_territory, p_day using errcode = '22023';
  end if;
  return v;
end;
$$;

------------------------------------------------------------------------------------------
-- Business calendar (rule pack remittance/fr, scope FR-conservative)
------------------------------------------------------------------------------------------

create table public.business_calendar (
  scope text not null default 'FR-conservative' check (scope = 'FR-conservative'),
  day date not null,
  closed boolean not null,
  label text,                                            -- French: « Toussaint ; dimanche »; null on a business day
  sources text[] not null default '{}'
    check (sources <@ array['public_holiday', 'target', 'weekend']::text[]),
  primary key (scope, day),
  check (closed = (cardinality(sources) > 0)),
  check ((label is null) = (not closed))
);
create index business_calendar_open_idx on public.business_calendar (scope, day) where not closed;
comment on table public.business_calendar is
  'Every day of the seeded horizon of the conservative calendar (rule pack worker/rule_packs/remittance/fr.yaml): '
  'closed on weekends, French public holidays (C. trav. L3133-1) and TARGET closing days. CI checks it equals the '
  'calendar of the Python engine.';

create trigger business_calendar_append_only before update or delete or truncate on public.business_calendar
  for each statement execute function private.refuse_change();
alter table public.business_calendar enable always trigger business_calendar_append_only;

-- Every day of 2026–2031; the holidays and TARGET days generated from the pack, the weekends here.
insert into public.business_calendar (scope, day, closed, label, sources)
select 'FR-conservative', d.day, h.day is not null or w.weekend,
       nullif(concat_ws(' ; ', h.label, case when w.weekend then
         (array['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'])[w.isodow] end), ''),
       array(select s from unnest(coalesce(h.sources, '{}') || case when w.weekend then array['weekend'] end) s
             where s is not null order by s)
from generate_series('2026-01-01'::date, '2031-12-31'::date, interval '1 day') g (ts)
cross join lateral (select g.ts::date as day) d
cross join lateral (select extract(isodow from d.day)::int as isodow,
                           extract(isodow from d.day) in (6, 7) as weekend) w
left join (values
  ('2026-01-01', 'Jour de l''an', array['public_holiday', 'target']::text[]),
  ('2026-04-03', 'Vendredi saint', array['target']::text[]),
  ('2026-04-06', 'Lundi de Pâques', array['public_holiday', 'target']::text[]),
  ('2026-05-01', '1er mai', array['public_holiday', 'target']::text[]),
  ('2026-05-08', '8 mai', array['public_holiday']::text[]),
  ('2026-05-14', 'Ascension', array['public_holiday']::text[]),
  ('2026-05-25', 'Lundi de Pentecôte', array['public_holiday']::text[]),
  ('2026-07-14', '14 juillet', array['public_holiday']::text[]),
  ('2026-08-15', 'Assomption', array['public_holiday']::text[]),
  ('2026-11-01', 'Toussaint', array['public_holiday']::text[]),
  ('2026-11-11', '11 novembre', array['public_holiday']::text[]),
  ('2026-12-25', 'Noël', array['public_holiday', 'target']::text[]),
  ('2026-12-26', '26 décembre', array['target']::text[]),
  ('2027-01-01', 'Jour de l''an', array['public_holiday', 'target']::text[]),
  ('2027-03-26', 'Vendredi saint', array['target']::text[]),
  ('2027-03-29', 'Lundi de Pâques', array['public_holiday', 'target']::text[]),
  ('2027-05-01', '1er mai', array['public_holiday', 'target']::text[]),
  ('2027-05-06', 'Ascension', array['public_holiday']::text[]),
  ('2027-05-08', '8 mai', array['public_holiday']::text[]),
  ('2027-05-17', 'Lundi de Pentecôte', array['public_holiday']::text[]),
  ('2027-07-14', '14 juillet', array['public_holiday']::text[]),
  ('2027-08-15', 'Assomption', array['public_holiday']::text[]),
  ('2027-11-01', 'Toussaint', array['public_holiday']::text[]),
  ('2027-11-11', '11 novembre', array['public_holiday']::text[]),
  ('2027-12-25', 'Noël', array['public_holiday', 'target']::text[]),
  ('2027-12-26', '26 décembre', array['target']::text[]),
  ('2028-01-01', 'Jour de l''an', array['public_holiday', 'target']::text[]),
  ('2028-04-14', 'Vendredi saint', array['target']::text[]),
  ('2028-04-17', 'Lundi de Pâques', array['public_holiday', 'target']::text[]),
  ('2028-05-01', '1er mai', array['public_holiday', 'target']::text[]),
  ('2028-05-08', '8 mai', array['public_holiday']::text[]),
  ('2028-05-25', 'Ascension', array['public_holiday']::text[]),
  ('2028-06-05', 'Lundi de Pentecôte', array['public_holiday']::text[]),
  ('2028-07-14', '14 juillet', array['public_holiday']::text[]),
  ('2028-08-15', 'Assomption', array['public_holiday']::text[]),
  ('2028-11-01', 'Toussaint', array['public_holiday']::text[]),
  ('2028-11-11', '11 novembre', array['public_holiday']::text[]),
  ('2028-12-25', 'Noël', array['public_holiday', 'target']::text[]),
  ('2028-12-26', '26 décembre', array['target']::text[]),
  ('2029-01-01', 'Jour de l''an', array['public_holiday', 'target']::text[]),
  ('2029-03-30', 'Vendredi saint', array['target']::text[]),
  ('2029-04-02', 'Lundi de Pâques', array['public_holiday', 'target']::text[]),
  ('2029-05-01', '1er mai', array['public_holiday', 'target']::text[]),
  ('2029-05-08', '8 mai', array['public_holiday']::text[]),
  ('2029-05-10', 'Ascension', array['public_holiday']::text[]),
  ('2029-05-21', 'Lundi de Pentecôte', array['public_holiday']::text[]),
  ('2029-07-14', '14 juillet', array['public_holiday']::text[]),
  ('2029-08-15', 'Assomption', array['public_holiday']::text[]),
  ('2029-11-01', 'Toussaint', array['public_holiday']::text[]),
  ('2029-11-11', '11 novembre', array['public_holiday']::text[]),
  ('2029-12-25', 'Noël', array['public_holiday', 'target']::text[]),
  ('2029-12-26', '26 décembre', array['target']::text[]),
  ('2030-01-01', 'Jour de l''an', array['public_holiday', 'target']::text[]),
  ('2030-04-19', 'Vendredi saint', array['target']::text[]),
  ('2030-04-22', 'Lundi de Pâques', array['public_holiday', 'target']::text[]),
  ('2030-05-01', '1er mai', array['public_holiday', 'target']::text[]),
  ('2030-05-08', '8 mai', array['public_holiday']::text[]),
  ('2030-05-30', 'Ascension', array['public_holiday']::text[]),
  ('2030-06-10', 'Lundi de Pentecôte', array['public_holiday']::text[]),
  ('2030-07-14', '14 juillet', array['public_holiday']::text[]),
  ('2030-08-15', 'Assomption', array['public_holiday']::text[]),
  ('2030-11-01', 'Toussaint', array['public_holiday']::text[]),
  ('2030-11-11', '11 novembre', array['public_holiday']::text[]),
  ('2030-12-25', 'Noël', array['public_holiday', 'target']::text[]),
  ('2030-12-26', '26 décembre', array['target']::text[]),
  ('2031-01-01', 'Jour de l''an', array['public_holiday', 'target']::text[]),
  ('2031-04-11', 'Vendredi saint', array['target']::text[]),
  ('2031-04-14', 'Lundi de Pâques', array['public_holiday', 'target']::text[]),
  ('2031-05-01', '1er mai', array['public_holiday', 'target']::text[]),
  ('2031-05-08', '8 mai', array['public_holiday']::text[]),
  ('2031-05-22', 'Ascension', array['public_holiday']::text[]),
  ('2031-06-02', 'Lundi de Pentecôte', array['public_holiday']::text[]),
  ('2031-07-14', '14 juillet', array['public_holiday']::text[]),
  ('2031-08-15', 'Assomption', array['public_holiday']::text[]),
  ('2031-11-01', 'Toussaint', array['public_holiday']::text[]),
  ('2031-11-11', '11 novembre', array['public_holiday']::text[]),
  ('2031-12-25', 'Noël', array['public_holiday', 'target']::text[]),
  ('2031-12-26', '26 décembre', array['target']::text[])
) h (day, label, sources) on h.day::date = d.day;

-- The last seeded day (the horizon's end).
create or replace function private.business_calendar_horizon()
returns date
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select max(c.day) from public.business_calendar c where c.scope = 'FR-conservative';
$$;

------------------------------------------------------------------------------------------
-- The R124-6 deadline (§9.2; Python twin collectoo_worker.remittance.deadline)
------------------------------------------------------------------------------------------

-- E: the earlier of the booking and value dates (founder #2; OQ-36).
create or replace function private.encaissement_date(p_booking_date date, p_value_date date)
returns date
language sql
immutable
set search_path = ''
as $$ select least(p_booking_date, coalesce(p_value_date, p_booking_date)) $$;

-- One month after a day: the same day of the next month, else its last day (CPC 641 al. 2, by analogy; Postgres
-- clamps `date + interval '1 month'` to the end of the month exactly so).
create or replace function private.add_month_cpc641(p_day date)
returns date
language sql
immutable
set search_path = ''
as $$ select (p_day + interval '1 month')::date $$;

-- The deadline of an encaissement under a delay of 1..30 days (mandate_terms.remittance_max_days):
--   deadline       = least(E + delay, E + one month)            — never extended over a weekend or a holiday;
--   last business day ≤ deadline;
--   latest execution date = the business day before it          — the payee's bank is credited by D+1 (L133-13 I);
--   alert dates = latest execution − 5 and − 1 business days     — the pack's margins (the parity test checks these
--                                                                   defaults against the YAML);
--   unmeetable = latest execution ≤ E                            — a delay of 1–5 days can leave no business day
--                                                                   after the money arrives (E Fri 13/11/2026, 2 days:
--                                                                   latest execution Thu 12/11); M2c-4 records such a
--                                                                   line as « délai intenable », not as a breach; from
--                                                                   6 days on it never happens on 2026–2031 (OQ-71).
-- One keyed range scan of the calendar (at most 41 days back from the deadline); a deadline beyond the horizon, or
-- a computation that walks back before it, raises 22023 « business calendar: … horizon » (the Python twin raises
-- CalendarHorizonError in the same cases). Exactly one row (`rows 1`: a lateral join is estimated as such).
create or replace function private.remittance_deadline(p_encaissement date, p_max_days integer,
                                                       p_soon_days integer default 5,
                                                       p_critical_days integer default 1)
returns table (encaissement_date date, deadline date, last_business_day date, latest_execution_date date,
               alert_soon_date date, alert_critical_date date, unmeetable boolean)
language plpgsql
stable
rows 1
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_deadline date;
  v_end date;
  v_open date[];
begin
  if p_encaissement is null or p_max_days is null or p_max_days not between 1 and 30 then
    raise exception 'remittance deadline: the mandate''s delay is 1..30 days, not %', p_max_days
      using errcode = '22023';
  end if;
  if p_soon_days is null or p_critical_days is null or p_soon_days not between 1 and 10
     or p_critical_days not between 1 and 10 then
    raise exception 'remittance deadline: alert margins are 1..10 business days' using errcode = '22023';
  end if;
  v_deadline := least(p_encaissement + p_max_days, private.add_month_cpc641(p_encaissement));
  v_end := private.business_calendar_horizon();
  if v_end is null or v_deadline > v_end then
    raise exception 'business calendar: % is outside the seeded horizon (… %)', v_deadline, v_end
      using errcode = '22023';
  end if;
  select array_agg(c.day order by c.day desc) into v_open
  from public.business_calendar c
  where c.scope = 'FR-conservative' and c.day between v_deadline - 40 and v_deadline and not c.closed;
  if coalesce(cardinality(v_open), 0) < 2 + greatest(p_soon_days, p_critical_days) then
    raise exception 'business calendar: the days before % are outside the seeded horizon', v_deadline
      using errcode = '22023';
  end if;
  return query select p_encaissement, v_deadline, v_open[1], v_open[2], v_open[2 + p_soon_days],
                      v_open[2 + p_critical_days], v_open[2] <= p_encaissement;
end;
$$;

------------------------------------------------------------------------------------------
-- Reference-data alerts (§15 `vat_pack_review`, `calendar_horizon`; wired into the nightly checks by M2c-4)
------------------------------------------------------------------------------------------

create or replace function private.reference_data_alerts(p_today date, p_min_horizon_months integer default 12)
returns table (code text, details jsonb)
language sql
stable
set search_path = ''
as $$
  select 'vat_pack_review'::text,
         jsonb_build_object('code', r.code, 'territory', r.territory, 'valid_from', r.valid_from,
                            'legal_ref', r.legal_ref, 'legal_url', r.legal_url, 'review_due_on', r.review_due_on)
  from public.vat_rate r
  where r.review_due_on <= p_today and r.reviewed_on is null
  union all
  select 'calendar_horizon'::text, jsonb_build_object('seeded_to', h.last_day, 'needed_to', h.needed_to)
  from (select private.business_calendar_horizon() as last_day,
               (p_today + make_interval(months => p_min_horizon_months))::date as needed_to) h
  where h.last_day is null or h.last_day < h.needed_to;
$$;

------------------------------------------------------------------------------------------
-- Read access and grants: reference data, read by every signed-in user; written by migrations only
------------------------------------------------------------------------------------------

alter table public.vat_rate enable row level security;
alter table public.business_calendar enable row level security;
revoke all on public.vat_rate, public.business_calendar from public, anon, authenticated;
grant select on public.vat_rate, public.business_calendar to authenticated;
create policy vat_rate_read on public.vat_rate for select to authenticated
  using ((select auth.uid()) is not null);
create policy business_calendar_read on public.business_calendar for select to authenticated
  using ((select auth.uid()) is not null);

revoke execute on function private.vat_rate_guard(), private.vat_rate_on(date, text, text),
  private.business_calendar_horizon(), private.encaissement_date(date, date), private.add_month_cpc641(date),
  private.remittance_deadline(date, integer, integer, integer), private.reference_data_alerts(date, integer)
  from public, anon, authenticated;
-- the worker (service role): runs, guard and alerts (M2c-4), the parity and equality tests
grant execute on function private.vat_rate_on(date, text, text), private.business_calendar_horizon(),
  private.encaissement_date(date, date), private.add_month_cpc641(date),
  private.remittance_deadline(date, integer, integer, integer), private.reference_data_alerts(date, integer)
  to service_role;
