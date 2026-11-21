-- M2c-6b-3b part 3: the held rows' alert at volume (ADR-0014 « M2c-6b-3b part 3 »; COMPLIANCE CPCE-08; founder
-- question 3 of « M2c-6b-3b part 2 », its default). THE SWITCH STAYS OFF: no statement here writes
-- private.feature_switch; a later one-line migration flips 'downloaded_file_cancellation' once the founder answers Q1
-- (OQ-81 (a)). pgTAP 033 (the switch-off test) is unchanged; 041 passes unchanged; 042 keeps every assertion (review
-- round 1 adds to it).
--   « remittance_breach_held » cost the nightly checks a second pass over what their booked branch had just read: 2,001
--   held chained runs took private.run_remittance_runs_checks from 12 s to 22 s (the review of PR #39). The three
--   dedups its round 1 named, behaviour unchanged:
--   * the booked chained runs read once (private.remittance_booked_chain_runs into pg_temp._rc_runs), by the booked
--     branch and the alert alike;
--   * the booked branch's holds record what they found (private.remittance_chain_holds also returns the possible
--     debits it judged on; private.remittance_chain_judged: every line due at the run's date with its date's findings,
--     into pg_temp._rc_lines) and the alert reads those — no second reading of the run's late lines, the chain's paid
--     date, its events nor the holds' facts;
--   * the uncovered days computed once per paying account and window [least(e0, L), L], not once per run.
--   The rows are those of the lines whose holds pass, as before (private.remittance_chain_rows now filters
--   private.remittance_chain_judged: one rule for the booking, its sheet and the nightly check). The alert's rows are
--   those of private.remittance_breach_held (part 2's standalone reading, kept: the tests compare the two), but in
--   a race — a statement imported or a line booked by another session between the booked branch's statement and the
--   results' — the days and the window's coverage are read in the results' statement (as before) while the waiting
--   lines are those the booked branch judged on (named only when the window is covered and was so then; else the run is
--   judged again at the next check, as « ni jour ni ligne » already says).
--
-- New (internal, EXECUTE revoked from every role): private.remittance_chain_judged; private.transfer_reissues (PR #40's
-- CI round).
-- Dropped and created again (its result gains `lines`, which CREATE OR REPLACE cannot add), its body copied from its
-- latest definition with that one change, its settings and grants restated:
--   private.remittance_chain_holds (20261119090000_switch_on_prerequisites_3.sql:209)
-- Redefined, each copied from its latest definition across all the migration files and changed only as its comment
-- says, with SECURITY DEFINER where it was, every SET clause, search_path and its grants restated:
--   private.remittance_chain_rows (20261119090000_switch_on_prerequisites_3.sql:275): its body moved verbatim into
--     private.remittance_chain_judged (unfiltered, with the findings); it now returns its lines whose holds pass
--   private.run_remittance_runs_checks (20261121090000_switch_on_prerequisites_4.sql:208): the booked branch and the
--     alert as above; every other check as before
--   private.remittance_breach_held (20261121090000_switch_on_prerequisites_4.sql:114; review round 1): its details gain
--     last_uncovered_day; its comment is set (the nightly checks no longer read it: it is the standalone reading the
--     tests compare them with)
--   private.transfer_line_offers (20261117110000_transfer_line_pages.sql:405; review round 1): its answer read in a
--     subtransaction rolled back once read, so the options' working tables and their locks do not pile up in the
--     nightly check's transaction (the lock table filled after about a hundred lines)
--   private.run_transfer_checks (20261118100000_switch_on_prerequisites_2.sql:2905; PR #40's CI round, ADR-0014
--     « M2c-6b-3b part 3 — CI round (PR #40) »): a cancelled refund's chain read forward by key
--     (private.transfer_reissues) instead of every waiting refund's chain once per cancelled refund debited late
-- private.remittance_booked_chain_runs (20261121090000) is not redefined.
-- Review round 1 (ADR-0014 « M2c-6b-3b part 3 review fixes »): the alert's details gain last_uncovered_day (the last
-- day no statement covers: the day a CSV export must go past, also beyond the 31 days named), in the checks and the
-- standalone reading alike; the checks' alert never names a waiting line booked or linked since the booked branch
-- judged it (read again by key in the results' statement); and its days and waiting lines are aggregated once per run
-- and joined to it by key (cost-1: no scan of the per-run facts per run). Its rows are otherwise unchanged.

------------------------------------------------------------------------------------------
-- The holds, recording what they found
------------------------------------------------------------------------------------------

-- private.remittance_chain_holds, from 20261119090000_switch_on_prerequisites_3.sql (line 209; its comment there):
-- dropped and created again, because its result gains a column, which CREATE OR REPLACE cannot add — its body copied
-- from that latest definition with one change, its settings (volatile, search_path '', enable_seqscan off) and its
-- grants restated below. M2c-6b-3b part 3 (founder question 3 of « M2c-6b-3b part 2 », its default): besides its three
-- verdicts (covered, waiting, expired: the same values), `lines` — the possible debits the verdict was reached on, from
-- the first of its one-snapshot reads (private.remittance_chain_hold_facts): [transfer, line, date] of each line dated
-- by L that may be the debit of another transfer of the chain handed out and that the chain's rule does not count yet,
-- newest first; '[]' when the window is not covered. The nightly check's alert names them instead of reading the
-- facts again. Its one caller, private.remittance_chain_rows (redefined below), reads it through
-- private.remittance_chain_judged; no other function calls it. Volatile (the options of an old line, with p_decide).
-- Keyed as its facts.
drop function private.remittance_chain_holds(uuid, uuid, date, date, boolean, uuid, date);
create function private.remittance_chain_holds(p_transfer_id uuid, p_paying uuid, p_latest date,
                                               p_today date, p_decide boolean, p_line_id uuid,
                                               p_paid date,
                                               out covered boolean, out waiting boolean,
                                               out expired boolean, out lines jsonb)
language plpgsql
volatile
set search_path = ''
set enable_seqscan = off
as $$
declare
  f record;
  g record;
  v_line record;
begin
  waiting := false;
  expired := false;
  lines := '[]';
  -- one snapshot: the coverage, the chain's paid date and the possible debits its rule does not count yet
  select x.covered, x.paid_on, x.lines into f
  from private.remittance_chain_hold_facts(p_transfer_id, p_paying, p_latest, p_line_id) x;
  covered := coalesce(f.covered, false);
  -- M2c-6b-3b part 3: the possible debits judged on (newest first), recorded for the held rows' alert
  lines := coalesce(f.lines, '[]');
  if not covered then
    return;
  end if;
  -- the caller judged the run at another paid date: something was committed since its snapshot
  if f.paid_on is distinct from p_paid then
    waiting := true;
    return;
  end if;
  for v_line in
    select (x.v ->> 0)::uuid as transfer_id, (x.v ->> 1)::uuid as line_id, (x.v ->> 2)::date as line_date
    from jsonb_array_elements(f.lines) with ordinality x (v, o)
    order by x.o
  loop
    if not p_decide
       or private.business_days_between(v_line.line_date, coalesce(p_today, private.paris_today()))
            < private.transfer_debit_bound_days()
       or private.transfer_line_offers(v_line.line_id, v_line.transfer_id) then
      waiting := true;
      expired := false;
      return;
    end if;
    expired := true;
  end loop;
  -- 'expired' rests on the options asked after the facts' snapshot: the facts read again must not have moved
  if expired then
    select x.covered, x.paid_on, x.lines into g
    from private.remittance_chain_hold_facts(p_transfer_id, p_paying, p_latest, p_line_id) x;
    if g.covered is distinct from true or g.paid_on is distinct from f.paid_on or g.lines is distinct from f.lines then
      waiting := true;
      expired := false;
    end if;
  end if;
end;
$$;

------------------------------------------------------------------------------------------
-- A run's lines due, each with its hold's findings
------------------------------------------------------------------------------------------

-- Every R124-6 line due at p_on for run p_run_id whose payout chain holds another transfer (M2c-6b-3b part 3): the
-- lines of private.remittance_chain_rows (20261119090000_switch_on_prerequisites_3.sql:275, its body here verbatim, its
-- comment there) — its positive unreleased lines late at p_on, each held to its latest execution date or, for a delay
-- that cannot be met, to the one-month date of its collection when that date is before p_on — whether or not their
-- holds pass: each with its date's findings (private.remittance_chain_holds, once per date: covered, waiting,
-- expired, the possible debits judged on). Read by private.remittance_chain_rows (the lines whose holds pass) and by
-- the nightly check (once: its rows, and its alert on the rest). Volatile (the holds').
create or replace function private.remittance_chain_judged(p_run_id uuid, p_on date, p_paid date,
                                                           p_paying uuid, p_line_id uuid, p_today date,
                                                           p_decide boolean)
returns table (ledger_entry_id uuid, payment_id uuid, deadline date, latest_execution_date date, kind text,
               covered boolean, waiting boolean, expired boolean, lines jsonb)
language sql
volatile
set search_path = ''
set enable_seqscan = off
as $$
  with l as materialized (
    select q.ledger_entry_id, q.payment_id, q.kind,
           case when q.unmeetable then m.deadline else q.deadline end as deadline,
           case when q.unmeetable then m.latest_execution_date else q.latest_execution_date end as latest
    from private.remittance_run_late_lines(p_run_id, p_on) q
    left join lateral (select d.deadline, d.latest_execution_date
                       from private.remittance_deadline_or_null(q.encaissement_date, 30) d
                       where q.unmeetable and q.encaissement_date is not null) m on true
    where not q.unmeetable or m.latest_execution_date < p_on),
  h as materialized (
    select d.latest, x.covered, x.waiting, x.expired, x.lines
    from (select distinct l.latest from l) d
    cross join (select r.transfer_id from public.remittance_run r where r.id = p_run_id) r
    cross join lateral private.remittance_chain_holds(r.transfer_id, p_paying, d.latest, p_today, p_decide,
                                                      p_line_id, p_paid) x)
  select l.ledger_entry_id, l.payment_id, l.deadline, l.latest, l.kind, h.covered, h.waiting, h.expired, h.lines
  from l
  join h on h.latest = l.latest;
$$;

-- private.remittance_chain_rows, redefined from 20261119090000_switch_on_prerequisites_3.sql (line 275; same signature
-- and settings, its grants restated below). M2c-6b-3b part 3: its body moved verbatim into
-- private.remittance_chain_judged; it returns that function's lines whose holds pass (covered, not waiting),
-- debit_unbooked their date's `expired` — the same rows for the booking, its sheet's late flag and the nightly check.
create or replace function private.remittance_chain_rows(p_run_id uuid, p_on date, p_paid date, p_paying uuid,
                                                         p_line_id uuid, p_today date, p_decide boolean)
returns table (ledger_entry_id uuid, payment_id uuid, deadline date, latest_execution_date date, kind text,
               debit_unbooked boolean)
language sql
volatile
set search_path = ''
set enable_seqscan = off
as $$
  select j.ledger_entry_id, j.payment_id, j.deadline, j.latest_execution_date, j.kind, j.expired
  from private.remittance_chain_judged(p_run_id, p_on, p_paid, p_paying, p_line_id, p_today, p_decide) j
  where j.covered and not j.waiting;
$$;

------------------------------------------------------------------------------------------
-- The nightly checks: the booked runs and their findings read once, the alert from them
------------------------------------------------------------------------------------------

-- private.run_remittance_runs_checks, redefined from 20261121090000_switch_on_prerequisites_4.sql (line 208; same
-- signature and settings, its grants restated below). M2c-6b-3b part 3 (founder question 3 of « M2c-6b-3b part 2 »,
-- its default): the booked branch reads the booked chained runs once (pg_temp._rc_runs) and every line due at their
-- dates with its hold's findings once (pg_temp._rc_lines), writes the rows of the lines whose holds pass (as before),
-- and the alert « remittance_breach_held » reads those two tables (its days once per paying account and window) instead
-- of private.remittance_breach_held's second pass. Every other check as before.
create or replace function private.run_remittance_runs_checks(p_check_run_id uuid, p_organization_id uuid,
                                                              p_today date default null)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_today date := coalesce(p_today, private.paris_today());
  v_since timestamptz;      -- the previous check run of the servicer
  v_full boolean;           -- I16 over every run (Sundays, or the first check run), else over the runs changed lately
  v_failures timestamptz;   -- the schedule's failures reported from (at least the last 24 hours)
begin
  select max(c.started_at) into v_since from public.payment_check_run c
  where c.organization_id = p_organization_id and c.id <> p_check_run_id and c.finished_at is not null;
  v_full := v_since is null or extract(isodow from v_today) = 7;
  v_failures := least(coalesce(v_since, clock_timestamp()), clock_timestamp() - interval '24 hours');

  -- Review round 2 (ld2-named-debit-returned-after-booking; CPCE-08), rounds 3 and 4, M2c-6b-3b part 1: a booked run
  -- whose payout chain holds a payout cancelled out of a downloaded file (a re-issue's run, or one booked by its late
  -- predecessor) gets its R124-6 rows at the date its chain paid the client and stayed paid
  -- (private.remittance_chain_paid: every execution and return of the chain, each counted for the transfer it names).
  -- Keyed: the servicer's cancelled filed transfers by bank_transfer_cancelled_filed_idx, each run, chain and line by key.
  -- M2c-6b-3b part 2: the runs this branch judges are read by private.remittance_booked_chain_runs (its CTEs bc and
  -- bp moved there verbatim), which the alert « remittance_breach_held » below reads too: one rule for the rows and
  -- their alert.
  -- M2c-6b-3b part 3 (founder question 3 of « M2c-6b-3b part 2 », its default): read once each — the booked chained
  -- runs into pg_temp._rc_runs, and every line due at each run's date with what its hold found into pg_temp._rc_lines
  -- (private.remittance_chain_judged: private.remittance_chain_rows' lines, unfiltered, each with its date's
  -- coverage, waiting, expired and the possible debits judged on). The rows are those lines whose holds pass, as
  -- before; the alert below reads the same two tables instead of reading the runs and the holds' facts again.
  drop table if exists pg_temp._rc_runs;
  create temp table _rc_runs on commit drop as
  select * from private.remittance_booked_chain_runs(p_organization_id);
  create index on pg_temp._rc_runs (run_id);
  drop table if exists pg_temp._rc_lines;
  create temp table _rc_lines on commit drop as
  select p.run_id, x.ledger_entry_id, x.payment_id, x.deadline, x.latest_execution_date, x.kind, x.covered, x.waiting,
         x.expired, x.lines
  from pg_temp._rc_runs p
  cross join lateral private.remittance_chain_judged(p.run_id, p.paid_on, p.chain_paid, p.paying, null, v_today,
                                                     true) x;
  create index on pg_temp._rc_lines (run_id, latest_execution_date);
  insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                 run_id, deadline, latest_execution_date, requested_execution_date,
                                                 late_reason, blocked_reason)
  select p.organization_id, p.client_organization_id, l.ledger_entry_id, l.payment_id, l.run_id, l.deadline,
         l.latest_execution_date, p.requested_execution_date, p.late_reason,
         case when l.expired then 'debit_unbooked' when l.kind = 'payout_returned' then 'payout_returned' end
  from pg_temp._rc_lines l
  cross join lateral (select r.organization_id, r.client_organization_id, r.requested_execution_date, r.late_reason
                      from pg_temp._rc_runs r where r.run_id = l.run_id limit 1) p
  where l.covered and not l.waiting
  on conflict (ledger_entry_id) do nothing;

  with dl as materialized (     -- the collections waiting, of files under a mandate with terms (review legal#2)
    select * from private.pending_item_deadlines(p_organization_id) d where d.monitored),
  ol as materialized (          -- the collections of runs approved or sent, not debited by their date (legal#3)
    select * from private.inflight_overdue_lines(p_organization_id, v_today)),
  ua as materialized (          -- money matched to a file, not allocated (legal#7, perf#0)
    select * from private.unallocated_payment_deadlines(p_organization_id)),
  -- M2c-6b-3b part 2 (CPCE-08; founder question 2 of « M2c-6b-3b part 1 », its default): the booked runs of a chain
  -- whose R124-6 rows the holds keep back — read after the first statement above wrote the rows that are due, so a
  -- run whose row is written raises nothing.
  -- M2c-6b-3b part 3 (founder question 3 of « M2c-6b-3b part 2 », its default): the same alert as
  -- private.remittance_breach_held (part 2's reading, kept as the standalone one the tests compare it with), read from
  -- what the booked branch above recorded instead of a second pass: its runs (pg_temp._rc_runs) and its lines with
  -- their holds' findings (pg_temp._rc_lines); and the uncovered days once per account and window, not once per run.
  -- hl: the lines due at each run's date that still have no row, each with the date it is held to (the booked
  -- branch's own: its latest execution date, or the one-month date of a delay that cannot be met)
  hl as materialized (
    select c.run_id, c.ledger_entry_id, c.latest_execution_date as latest, x.amount_minor
    from pg_temp._rc_lines c
    cross join lateral (select y.amount_minor from public.remittance_line y
                        where y.ledger_entry_id = c.ledger_entry_id and not y.released offset 0) x
    where not exists (select 1 from public.remittance_deadline_breach b where b.ledger_entry_id = c.ledger_entry_id
                      offset 0)),
  -- he: per run with such a line, once: its paying account and e0, the earliest execution date of its chain's
  -- transfers handed out (an item of a file downloaded at least once)
  he as materialized (
    select k.run_id, e.account, e.e0
    from (select distinct h.run_id from hl h) k
    cross join lateral (select r.transfer_id from pg_temp._rc_runs r where r.run_id = k.run_id limit 1) t
    cross join lateral (
      select (select q.debtor_bank_account_id from public.bank_transfer q where q.id = t.transfer_id) as account,
             (select min(i.execution_date)
              from private.transfer_chain(t.transfer_id) c
              cross join lateral (select q.file_id, q.execution_date from public.transfer_file_item q
                                  where q.transfer_id = c.transfer_id offset 0) i
              cross join lateral (select ff.download_count from public.transfer_file ff where ff.id = i.file_id
                                  offset 0) ff
              where ff.download_count > 0) as e0) e),
  -- hk: per run and date held to: the window [least(e0, L), L], and the possible debits its hold judged on when the
  -- booked branch found the window covered
  hk as materialized (
    select k.run_id, k.latest, e.account, least(coalesce(e.e0, k.latest), k.latest) as d_from, f.covered as found,
           f.lines
    from (select distinct h.run_id, h.latest from hl h) k
    join he e on e.run_id = k.run_id
    cross join lateral (select c.covered, c.lines from pg_temp._rc_lines c
                        where c.run_id = k.run_id and c.latest_execution_date = k.latest limit 1) f),
  -- hw: per paying account and window, once: covered now (private.statement_covers), else the business days no
  -- imported statement covers yet (each read alone; none named: the balances' break)
  hw as materialized (
    select k.account, k.d_from, k.d_to, v.covered,
           case when not v.covered
                then array(select g.d::date
                           from generate_series(k.d_from, k.d_to, interval '1 day') g (d)
                           where private.is_business_day(g.d::date)
                             and not private.statement_covers(k.account, g.d::date, g.d::date)
                           order by 1) end as days
    from (select distinct h.account, h.d_from, h.latest as d_to from hk h) k
    cross join lateral (select coalesce(private.statement_covers(k.account, k.d_from, k.d_to), false) as covered
                        offset 0) v),
  -- hf: per run and date held to, the window's facts — the waiting lines named only when the window is covered and
  -- was so when the booked branch judged it (else the facts moved meanwhile: the next check judges the run again)
  hf as materialized (
    select h.run_id, h.latest, w.covered, w.days,
           case when w.covered and h.found then h.lines else '[]'::jsonb end as lines
    from hk h
    join hw w on w.account is not distinct from h.account and w.d_from = h.d_from and w.d_to = h.latest),
  -- hwl: the lines a covered date waits on: each once, with a transfer it may be the debit of. Review round 1
  -- (dt3-race-alert-for-run-paid-on-time): never a line booked or linked since the booked branch judged it — read
  -- again here by key (as private.transfer_debit_lines reads it): the alert never asks ops to book a booked line
  hwl as materialized (
    select distinct on (f.run_id, (v.v ->> 1)::uuid)
           f.run_id, (v.v ->> 1)::uuid as line_id, (v.v ->> 2)::date as line_date, (v.v ->> 0)::uuid as transfer_id
    from hf f
    cross join lateral jsonb_array_elements(f.lines) v (v)
    where f.covered
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = (v.v ->> 1)::uuid
                      offset 0)
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = (v.v ->> 1)::uuid
                      offset 0)
    order by f.run_id, (v.v ->> 1)::uuid, (v.v ->> 2)::date, (v.v ->> 0)::uuid),
  hs as materialized (
    select l.run_id, sum(l.amount_minor) as amount, count(*) as n, min(l.latest) as earliest,
           max(v_today - l.latest) as oldest,
           (array_agg(l.ledger_entry_id order by l.ledger_entry_id))[1:50] as ids
    from hl l group by l.run_id),
  -- Review round 1 (cost-1): each run's days and waiting lines aggregated once per run and joined to it by key —
  -- never a scan of hf or hwl per run. hd: the days no statement covers, each once, in order (the first 31 named), how
  -- many, the last of them (dt3-csv-hint-last-day-not-named: the day to export past, also beyond the 31 named), and a
  -- window whose every day is covered but whose balances do not follow (the break)
  hd as materialized (
    select f.run_id,
           array_agg(distinct u.d order by u.d) filter (where u.d is not null) as days,
           count(distinct u.d) as n, max(u.d) as last,
           coalesce(bool_or(not f.covered and cardinality(f.days) = 0), false) as brk
    from hf f
    left join lateral unnest(f.days) u (d) on true
    group by f.run_id),
  -- hwa: the waiting lines, numbered per run by date and id; the first 10 named with their amount and the transfer each
  -- may be the debit of (read by key for those only), all of them counted
  hwr as materialized (
    select w.run_id, w.line_id, w.line_date, w.transfer_id,
           row_number() over (partition by w.run_id order by w.line_date, w.line_id) as rn,
           count(*) over (partition by w.run_id) as n
    from hwl w),
  hwa as materialized (
    select r.run_id, max(r.n) as n,
           jsonb_agg(jsonb_build_object('line_id', r.line_id, 'booking_date', r.line_date,
                                        'amount_minor', x.amount_minor::text, 'currency', x.currency,
                                        'end_to_end_id', tr.end_to_end_id)
                     order by r.line_date, r.line_id) as waiting
    from hwr r
    cross join lateral (select q.amount_minor, q.currency from public.bank_transaction q where q.id = r.line_id
                        offset 0) x
    cross join lateral (select q.end_to_end_id from public.bank_transfer q where q.id = r.transfer_id offset 0) tr
    where r.rn <= 10
    group by r.run_id),
  bh as materialized (
    select p.run_id, p.currency, s.amount::bigint as amount_minor, s.n::integer as line_count,
           s.oldest::integer as oldest_days,
           jsonb_build_object(
             'number', p.number,
             'judged_on', p.paid_on,
             'earliest_latest_execution_date', s.earliest,
             'uncovered_days', to_jsonb((coalesce(d.days, '{}'::date[]))[1:31]),
             'uncovered_count', coalesce(d.n, 0),
             'last_uncovered_day', d.last,
             'balance_break', coalesce(d.brk, false),
             'waiting', coalesce(a.waiting, '[]'),
             'waiting_count', coalesce(a.n, 0),
             'bound_days', private.transfer_debit_bound_days(),
             'ids', to_jsonb(s.ids)) as details
    from hs s
    cross join lateral (select r.run_id, r.currency, r.number, r.paid_on from pg_temp._rc_runs r
                        where r.run_id = s.run_id limit 1) p
    left join hd d on d.run_id = s.run_id
    left join hwa a on a.run_id = s.run_id),
  -- I21: a positive collection not paid by its latest execution date — one month after E when its mandate's delay
  -- cannot be met (review legal#1) — writes a breach row, once; one the calendar cannot place has no date to hold it
  -- to (its alert below)
  waiting_breach as (
    insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                   run_id, deadline, latest_execution_date, blocked_reason)
    select p_organization_id, d.client_organization_id, d.ledger_entry_id, d.payment_id, d.draft_run_id,
           d.check_deadline, d.check_latest_execution_date,
           -- M2c-6b-1 (Q7's default, OQ-36): an item paid again after its payout came back keeps its lines' date, and
           -- its breach is recorded « bloqué : virement revenu impayé »
           case when exists (select 1 from private.remittance_pending q where q.ledger_entry_id = d.ledger_entry_id
                               and q.kind = 'payout_returned') then 'payout_returned' end
    from dl d where not d.out_of_horizon and d.check_latest_execution_date < v_today
    on conflict (ledger_entry_id) do nothing),
  -- … and so does a collection whose run was approved but whose payout is not debited by then (§9.2: paid means
  -- debited). M2c-6b-1 (plan §2.5 [critic]): « paid » is the bank's debit date, often imported a day later, and the
  -- table is append-only — so the row is written only once the paying account's statements cover that date
  -- (private.statement_covers) and show no debit of the payout, nor a line not booked yet that could be it (its
  -- PmtInf's batch line whatever its amount, a line of its amount with neither reference: review legal-texts#2); until
  -- then the alert below only. A payout never handed out to the bank (still ordered, or in a file nobody downloaded)
  -- is not paid whatever the statements: its row is written at once. A late debit booked later writes its row at the
  -- booking (private.bank_booking_post_rows).
  -- M2c-6b-3a-2 (I; CPCE-08): a run whose transfer re-issues another (its predecessor cancelled with a downloaded
  -- file) or is itself cancelled (refused by the bank, cancelled alone: the run still approved or sent) is proven unpaid
  -- at L only once the statements cover [e0, L] — e0 the earliest execution date of its chain's transfers that were in
  -- a file downloaded at least once, whether or not the re-issue itself was handed out — and no such transfer may have
  -- been debited by L (private.transfer_debit_suppression(x, L, today) not 'waiting': its own id, its PmtInf's batch
  -- lines, a line of its amount without our references or to its payee, dated up to L, not booked nor linked — a line
  -- dated after L never holds the row back, the payment being certainly late); 'expired' writes the row « bloqué :
  -- débit possible non comptabilisé ». A predecessor's late debit may have paid the run on time: written at once, the
  -- append-only row would be false (its booking writes none, on conflict). Other runs keep the two branches below.
  -- Review round 1 (LD-1): nor ever while a debit naming a chain transfer by our references (its own id, a detail of an
  -- entry kept unsplit, its PmtInf's batch line that can hold it), dated by L, waits unbooked — that transfer was
  -- executed on time; 'expired' is for lines that only may be its debit. Its booking (the late predecessor, or the
  -- re-issue's own debit) then writes the true row at its date. Review round 4 (CPCE-08): « executed on time » is the
  -- one rule over the chain (private.remittance_chain_paid): the chain paid the client by L and stayed paid — a
  -- transfer whose every execution came back (its return unflagged included) paid nothing, one executed more often
  -- than it came back stays paid.
  -- M2c-6b-3b part 1 review round 1 (chain-holds-snapshot-race; CPCE-08): the rule above, unchanged, judged by
  -- private.remittance_inflight_judge on facts read in one snapshot (the run still in flight, its transfer, the
  -- coverage, the chain's paid date, the lines that may be a debit) — no longer this statement's snapshot beside the
  -- suppression's own later reads, between which ops' booking of the run's on-time debit without our references (or an
  -- import) could land and the append-only row be written for a run paid on time — a proof resting on the options
  -- asked after that snapshot standing only if the facts read again afterwards have not moved. Every run in flight,
  -- chained or not (the in-flight branch of a run with no other transfer included: production since 6b-2c).
  olc as materialized (
    select k.run_id, k.latest_execution_date, j.proven, j.debit_unbooked
    from (select distinct o.run_id, o.latest_execution_date from ol o where not o.out_of_horizon) k
    cross join lateral private.remittance_inflight_judge(k.run_id, k.latest_execution_date, v_today) j),
  inflight_breach as (
    insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                   run_id, deadline, latest_execution_date, requested_execution_date,
                                                   late_reason, blocked_reason)
    select p_organization_id, o.client_organization_id, o.ledger_entry_id, o.payment_id, o.run_id, o.deadline,
           o.latest_execution_date, o.requested_execution_date, o.late_reason,
           -- M2c-6b-2c (plan §4.2, Q14's default): « bloqué : débit possible non comptabilisé »; else a returned
           -- payout paid again (Q7, review legal-texts#1): its line's kind, by the item's live line
           case when c.debit_unbooked then 'debit_unbooked'
                when (select x.kind from public.remittance_line x
                      where x.ledger_entry_id = o.ledger_entry_id and not x.released) = 'payout_returned'
                then 'payout_returned' end
    from ol o
    join olc c on c.run_id = o.run_id and c.latest_execution_date = o.latest_execution_date and c.proven
    where not o.out_of_horizon
    on conflict (ledger_entry_id) do nothing)
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, u.code, u.severity, u.subject_type, u.subject_id, u.currency,
         u.amount_minor, u.count, u.oldest_days, coalesce(u.details, '{}')
  from (
  -- (I14 is in run_payment_checks)
  -- I15: an item both waiting and in a live line
  select 'remittance_item_twice'::text, 'violation'::text, 'ledger_entry'::text, q.ledger_entry_id, q.currency::char(3),
         q.amount_minor::bigint, null::integer, null::integer, '{}'::jsonb
  from private.remittance_pending q
  join public.remittance_line l on l.ledger_entry_id = q.ledger_entry_id and not l.released
  where q.organization_id = p_organization_id
  union all
  -- I16: a run's arithmetic — gross = Σ lines, N + D = gross, N ≥ 0, the payout = N, documents' HT plus what the
  -- run's credits absorbed of manual credit notes' waivers (M2c-5b) = Σ line commissions. A run's lines and totals are frozen once approved: each run is read in one pass over its lines, the
  -- runs changed since the previous check run (with a day's margin), every run on Sundays (review perf#5).
  select 'remittance_run_totals', 'violation', 'remittance_run', r.id, r.currency, r.gross_minor, null, null,
         jsonb_build_object('number', r.number, 'lines_minor', l.gross::text, 'documents_ht_minor', s.docs::text,
                            'absorbed_minor', s.absorbed::text, 'commission_minor', (l.charged + s.repriced)::text)
  from public.remittance_run r
  cross join lateral (select coalesce(sum(x.amount_minor), 0) as gross, count(*) as n,
                             coalesce(sum(x.commission_minor) filter (where x.commission_state = 'charged'), 0)
                               as charged
                      from public.remittance_line x where x.run_id = r.id) l
  cross join lateral (
    select (select coalesce(sum(i.ht_minor), 0) from public.commission_invoice i
            where i.run_id = r.id and i.reason = 'commission') as docs,
           (select coalesce(sum(x.commission_minor), 0) from public.remittance_line_repricing x
            where x.pricing_run_id = r.id and x.commission_state = 'charged') as repriced,
           (select t.amount_minor from public.bank_transfer t where t.id = r.transfer_id) as payout,
           -- what the run's credits absorbed of manual credit notes' waivers (M2c-5b: lines with no document)
           (select coalesce(sum(w.amount_minor), 0) from public.commission_waiver w
            where w.run_id = r.id and w.cause = 'absorbed') as absorbed) s
  where r.organization_id = p_organization_id and r.status in ('approved', 'sent', 'booked', 'cancelled')
    and r.approved_at is not null and (v_full or r.updated_at > v_since - interval '1 day')
    and (l.gross <> r.gross_minor or l.n <> r.line_count or r.net_minor < 0
         or r.net_minor + r.settlement_minor <> r.gross_minor or s.docs + s.absorbed <> l.charged + s.repriced
         or (r.status <> 'cancelled' and r.net_minor > 0 and s.payout is distinct from r.net_minor)
         or (r.net_minor = 0 and r.transfer_id is not null))
  union all
  -- I22 (M2c-5b): each (file, tier key) whose state changed since the previous check run (with a day's margin): what
  -- its invoices still charge plus the waivers they hold is the commission charged, the waivers its state's, none below
  -- 0 (the engine's input: the prepare refuses a key that breaks it; keyed per key)
  select 'commission_key_state', 'violation', 'account', c.account_id, 'EUR',
         (o.open_minor + o.waived_minor - s.commission_minor)::bigint, null, null,
         jsonb_build_object('tier_key', c.tier_key, 'commission_minor', s.commission_minor::text,
                            'open_minor', o.open_minor::text, 'waived_minor', o.waived_minor::text,
                            'state_waived_minor', s.waived_minor::text)
  from (select distinct k.account_id, k.tier_key from public.remittance_key_state k
        where k.organization_id = p_organization_id
          and k.created_at > coalesce(v_since, '-infinity'::timestamptz) - interval '1 day') c
  cross join lateral (select k.commission_minor, k.waived_minor from public.remittance_key_state k
                      where k.account_id = c.account_id and k.tier_key = c.tier_key
                      order by k.seq desc limit 1) s
  cross join lateral private.commission_key_open(c.account_id, c.tier_key) o
  where o.open_minor + o.waived_minor <> s.commission_minor or o.waived_minor <> s.waived_minor or o.negative
  union all
  -- I17 numbering: per series and year, 1…n with no gap, the counter at n, dates never going back
  select 'invoice_numbering', 'violation', 'servicer', null, null, null, x.n::integer, null,
         jsonb_build_object('series', x.series, 'year', x.year, 'max_seq', x.mx, 'counter', c.last_seq,
                            'dates_back', x.back)
  from (select i.series, i.year, count(*) as n, max(i.seq) as mx, min(i.seq) as mn,
               bool_or(i.issue_date < i.prev_date) as back
        from (select y.*, lag(y.issue_date) over (partition by y.series, y.year order by y.seq) as prev_date
              from public.commission_invoice y where y.organization_id = p_organization_id) i
        group by i.series, i.year) x
  left join private.invoice_counter c on c.organization_id = p_organization_id and c.series = x.series
    and c.year = x.year
  where x.n <> x.mx or x.mn <> 1 or c.last_seq is distinct from x.mx or x.back
  union all
  -- I17 ledger: each document's entry is the document (4111 = TTC, 7060 = −HT)
  select 'invoice_ledger', 'violation', 'commission_invoice', i.id, i.currency, i.ttc_minor, null, null,
         jsonb_build_object('number', i.number, 'receivable_minor', e.receivable::text, 'revenue_minor', e.revenue::text)
  from public.commission_invoice i
  cross join lateral (
    -- the entry's postings by key first, then each one's account by key (plan robustness, ARCHITECTURE §4)
    select coalesce(sum(p.amount_minor) filter (where la.book = 'commission_receivable'), 0) as receivable,
           coalesce(sum(p.amount_minor) filter (where la.book = 'servicer_revenue'), 0) as revenue
    from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
          where q.entry_id = i.ledger_entry_id offset 0) p
    cross join lateral (select a.book from public.ledger_account a where a.id = p.ledger_account_id offset 0) la) e
  where i.organization_id = p_organization_id and (e.receivable <> i.ttc_minor or e.revenue <> -i.ht_minor)
  union all
  -- I18: per client, Σ open invoices − Σ refunds owed = 4111[c]; 44574 = Σ pending VAT of the documents (the client's
  -- and the servicer's pooled accounts by their indexes: 4111 has no portfolio, 44574 no claim item; review perf#2)
  select 'settlement_ledger', 'violation', 'client', y.client_organization_id, 'EUR', (y.ledger - y.docs)::bigint, null,
         null, jsonb_build_object('documents_minor', y.docs::text, 'ledger_minor', y.ledger::text)
  from (select c.client_organization_id,
               coalesce((select sum(private.document_open(i.id) * case i.kind when 'invoice' then 1 else -1 end)
                         from public.commission_invoice i where i.client_organization_id = c.client_organization_id),
                        0) as docs,
               coalesce((select sum(p.amount_minor) from public.ledger_account la
                         join public.ledger_posting p on p.ledger_account_id = la.id
                         where la.book = 'commission_receivable' and la.client_organization_id = c.client_organization_id
                           and la.portfolio_id is null),
                        0) as ledger
        from (select distinct i.client_organization_id from public.commission_invoice i
              where i.organization_id = p_organization_id) c) y
  where y.docs <> y.ledger
  union all
  select 'vat_pending_ledger', 'violation', 'servicer', null, 'EUR', (v.ledger - v.docs)::bigint, null, null,
         jsonb_build_object('documents_minor', v.docs::text, 'ledger_minor', v.ledger::text)
  from (select coalesce((select sum(private.document_pending_vat(i.id)) from public.commission_invoice i
                         where i.organization_id = p_organization_id and i.kind = 'invoice'), 0) as docs,
               coalesce((select -sum(p.amount_minor) from public.ledger_account la
                         join public.ledger_posting p on p.ledger_account_id = la.id
                         where la.organization_id = p_organization_id and la.book = 'vat_pending'
                           and la.claim_item_id is null), 0) as ledger) v
  where v.docs <> v.ledger
  union all
  -- I21: collections waiting past the date they are held to (violation, per client)
  select 'remittance_deadline_breached', 'violation', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, max(v_today - d.check_latest_execution_date),
         jsonb_build_object('earliest_latest_execution_date', min(d.check_latest_execution_date),
                            'unmeetable', count(*) filter (where d.unmeetable),
                            'ids', (array_agg(d.ledger_entry_id order by d.check_latest_execution_date))[1:50])
  from dl d where not d.out_of_horizon and d.check_latest_execution_date < v_today
  group by d.client_organization_id, d.currency
  union all
  -- … whose mandate's delay could not be met (OQ-71: « délai intenable », an alert) while the month still runs
  select 'remittance_delay_unmeetable', 'alert', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, max(v_today - d.latest_execution_date),
         jsonb_build_object('earliest_latest_execution_date', min(d.latest_execution_date),
                            'one_month_latest_execution_date', min(d.check_latest_execution_date),
                            'ids', (array_agg(d.ledger_entry_id order by d.latest_execution_date))[1:50])
  from dl d
  where d.unmeetable and not d.out_of_horizon and d.latest_execution_date < v_today
    and d.check_latest_execution_date >= v_today
  group by d.client_organization_id, d.currency
  union all
  -- due soon (D-5 business days) and critical (D-1): per client, the earliest date (one month's for an unmeetable
  -- delay)
  select case when min(d.check_alert_critical_date) <= v_today then 'remittance_due_critical'
              else 'remittance_due_soon' end,
         'alert', 'client', d.client_organization_id, d.currency, sum(d.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('earliest_latest_execution_date', min(d.check_latest_execution_date))
  from dl d
  where not d.out_of_horizon and d.check_latest_execution_date >= v_today and d.check_alert_soon_date <= v_today
  group by d.client_organization_id, d.currency
  union all
  -- collections the business calendar cannot place (E before its horizon: long past any deadline; review nc#0)
  select 'remittance_deadline_not_computable', 'alert', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('of', 'items', 'earliest_encaissement_date', min(d.encaissement_date),
                            'ids', (array_agg(d.ledger_entry_id order by d.encaissement_date))[1:50])
  from dl d where d.out_of_horizon
  group by d.client_organization_id, d.currency
  union all
  select 'remittance_deadline_not_computable', 'alert', 'remittance_run', o.run_id, o.currency,
         sum(o.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('of', 'lines', 'number', min(o.number),
                            'ids', (array_agg(o.ledger_entry_id order by o.ledger_entry_id))[1:50])
  from ol o where o.out_of_horizon
  group by o.run_id, o.currency
  union all
  select 'remittance_deadline_not_computable', 'alert', 'servicer', null, u.currency, sum(u.unallocated_minor)::bigint,
         count(*)::integer, null,
         jsonb_build_object('of', 'payments', 'earliest_encaissement_date', min(u.encaissement_date),
                            'ids', (array_agg(u.payment_id order by u.encaissement_date))[1:50])
  from ua u where u.out_of_horizon
  group by u.currency
  union all
  -- a run approved or sent whose payout is not debited by its lines' date (violation; review legal#3) …
  select 'remittance_payout_overdue', 'violation', 'remittance_run', o.run_id, o.currency, sum(o.amount_minor)::bigint,
         count(*)::integer, max(v_today - o.latest_execution_date),
         jsonb_build_object('number', min(o.number), 'earliest_latest_execution_date', min(o.latest_execution_date),
                            'requested_execution_date', min(o.requested_execution_date),
                            'ids', (array_agg(o.ledger_entry_id order by o.latest_execution_date))[1:50])
  from ol o where not o.out_of_horizon
  group by o.run_id, o.currency
  union all
  -- M2c-6b-3b part 2 (CPCE-08): a booked run whose payout chain holds another transfer, its payout standing, with lines
  -- late at the chain's paid date and no R124-6 row because the statements do not cover [least(e0, L), L] yet (the
  -- days named, or a break in the balances) or a line that may be another transfer's debit waits (the lines named):
  -- an operational safeguard, not a legal deadline — the row is written by the check that finds both holds passing,
  -- and the alert is then no longer raised
  select 'remittance_breach_held', 'alert', 'remittance_run', h.run_id, h.currency, h.amount_minor, h.line_count,
         h.oldest_days, h.details
  from bh h
  union all
  -- … or by the date it was ordered for (alert)
  select 'remittance_payout_not_executed', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null,
         v_today - r.requested_execution_date,
         jsonb_build_object('number', r.number, 'requested_execution_date', r.requested_execution_date,
                            'transfer_status', (select t.status from public.bank_transfer t where t.id = r.transfer_id))
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status in ('approved', 'sent')
    and r.requested_execution_date < v_today
    and not exists (select 1 from public.bank_transfer t where t.id = r.transfer_id and t.status = 'booked')
  union all
  -- a draft whose payout is blocked, with its reason and its deadline
  select 'payout_blocked', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null, null,
         jsonb_build_object('number', r.number, 'blockers', to_jsonb(r.blockers),
                            'earliest_latest_execution_date', r.earliest_latest_execution_date)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status = 'draft' and r.net_minor > 0
    and cardinality(r.blockers) > 0
  union all
  -- a draft waiting more than one business day; one whose preparation failed at once (nothing retries it before
  -- « Actualiser »; review tests-ui#3)
  select 'draft_waiting', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null,
         private.business_days_between((coalesce(r.prepared_at, (r.last_failure ->> 'at')::timestamptz, r.known_at)
                                        at time zone 'Europe/Paris')::date, v_today),
         jsonb_build_object('number', r.number)
         || case when r.prepared_at is null
                 then jsonb_build_object('prepare_failed', true, 'failure_code', r.last_failure ->> 'code')
                 else '{}'::jsonb end
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status = 'draft'
    and ((r.prepared_at is not null
          and private.business_days_between((r.prepared_at at time zone 'Europe/Paris')::date, v_today) > 1)
         or (r.prepared_at is null and r.job is null and r.last_failure ->> 'step' = 'prepare'))
  union all
  -- an approval more than 2 business days after K (invoice_late)
  select 'invoice_late', 'alert', 'remittance_run', r.id, r.currency, r.invoice_ttc_minor, null, null,
         jsonb_build_object('number', r.number, 'known_at', r.known_at, 'approved_at', r.approved_at)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.invoice_late and r.approved_at > clock_timestamp() - interval '30 days'
  union all
  -- an invoice still open after the date it is paid by (§15 invoice_overdue; L441-10 II: penalties run from the next
  -- day): a due invoice, a cancellation's corrective invoice the next run did not set off in time (legal review #4,
  -- round 2; OQ-72), or a run's netted invoice whose plan left a remainder for the next run by its date (M2c-5 review
  -- legal#4; what its own run sets off is held to that run's payout by the payout checks above)
  select 'invoice_overdue', 'alert', 'commission_invoice', i.id, i.currency, o.open, null, v_today - i.due_date,
         jsonb_build_object('number', i.number, 'client_id', i.client_organization_id, 'settlement', i.settlement,
                            'due_date', i.due_date)
  from public.commission_invoice i
  cross join lateral (select private.document_open(i.id) as open) o
  where i.organization_id = p_organization_id and i.due_date is not null and i.due_date < v_today and o.open > 0
  union all
  -- a refund owed to the client still unpaid 30 days after its credit note (M2c-5b review legal#0; an operating
  -- threshold, not a legal deadline): what a credit note gives back beyond what its invoices still owed is paid with a
  -- later run's payout (the plan's refunds); with no later run (no collection left, a proceeding, the mandate ended)
  -- nothing pays it until M2c-7's record_client_refund (design §16: an ops-ordered transfer from the own account).
  -- Credit notes that owed a refund at issue only, by their index; `planned_run`: a run in flight whose plan pays it.
  select 'credit_refund_owed', 'alert', 'commission_invoice', i.id, i.currency, o.open, null, v_today - i.issue_date,
         jsonb_build_object('number', i.number, 'client_id', i.client_organization_id, 'reason', i.reason,
                            'issue_date', i.issue_date,
                            'planned_run', (select r.number from public.remittance_run r
                                            where r.client_organization_id = i.client_organization_id
                                              and r.currency = i.currency and r.status in ('approved', 'sent')
                                              and exists (select 1 from jsonb_array_elements(
                                                                   coalesce(r.settlement_plan -> 'settles', '[]')) s
                                                          where s ->> 'document_id' = i.id::text)
                                            limit 1))
  from public.commission_invoice i
  cross join lateral (select private.document_open(i.id) as open) o
  where i.organization_id = p_organization_id and i.kind = 'credit_note' and i.issue_date < v_today - 30
    and exists (select 1 from public.commission_credit_correction c where c.credit_note_id = i.id and c.excess_minor > 0)
    and o.open > 0
  union all
  -- money matched to a client's file but not allocated (still in 4710) gets the same clock (OQ-26, compliance B7)
  select 'unallocated_deadline', 'alert', 'servicer', null, u.currency, sum(u.unallocated_minor)::bigint,
         count(*)::integer, null,
         jsonb_build_object('earliest_latest_execution_date', min(u.latest_execution_date),
                            'held', count(*) filter (where u.held),
                            'ids', (array_agg(u.payment_id order by u.latest_execution_date))[1:50])
  from ua u where not u.out_of_horizon and u.alert_soon_date <= v_today
  group by u.currency
  union all
  -- the hourly schedule could not create a client's draft, or read its candidates, or its job died (review nc#0)
  select 'remittance_schedule_failed', 'alert', 'servicer', null, null, null, count(*)::integer, null,
         jsonb_build_object('last_failed_at', max(f.failed_at),
                            'last_error', (array_agg(f.error order by f.failed_at desc))[1],
                            'codes', to_jsonb(array_agg(distinct f.code)),
                            'client_ids', to_jsonb(coalesce(array_agg(distinct f.client_organization_id)
                                                              filter (where f.client_organization_id is not null),
                                                            '{}')))
  from private.remittance_schedule_failure f
  where f.organization_id = p_organization_id and f.failed_at >= v_failures
  having count(*) > 0
  union all
  -- documents the job could not draw (M2c-5 review perf#2): each failure is recorded on its row and retried; until it
  -- is drawn, the alert names it with its last error
  select 'remittance_document_failed', 'alert', 'servicer', null, null, null, count(*)::integer,
         max(v_today - (t.created_at at time zone 'Europe/Paris')::date),
         jsonb_build_object('statements', count(*) filter (where t.kind = 'statement'),
                            'invoices', count(*) filter (where t.kind = 'invoice'),
                            'last_failed_at', max(t.last_attempt_at),
                            'last_error', (array_agg(t.last_error order by t.last_attempt_at desc, t.ref_id))[1],
                            'ids', to_jsonb((array_agg(t.ref_id order by t.created_at, t.ref_id))[1:50]))
  from private.remittance_document_todo t
  where t.organization_id = p_organization_id and t.attempts > 0
  having count(*) > 0
  union all
  -- … and the documents still due 24 hours after they were (§15 document_missing): a statement or a PDF the client
  -- space says « en préparation »
  select 'remittance_document_missing', 'alert', 'servicer', null, null, null, count(*)::integer,
         max(v_today - (m.due_since at time zone 'Europe/Paris')::date),
         jsonb_build_object('statements', count(*) filter (where m.kind = 'statement'),
                            'invoices', count(*) filter (where m.kind = 'invoice'),
                            'oldest_due_since', min(m.due_since),
                            'numbers', to_jsonb((array_agg(m.number order by m.due_since, m.ref_id))[1:50]))
  from private.remittance_documents_missing(p_organization_id, interval '24 hours') m
  having count(*) > 0
  union all
  -- reference data (M2c-3): the VAT pack's review, the calendar's horizon
  select a.code, 'alert', 'servicer', null, null, null, null, null, a.details
  from private.reference_data_alerts(v_today) a
  ) u (code, severity, subject_type, subject_id, currency, amount_minor, count, oldest_days, details);
end;
$$;

------------------------------------------------------------------------------------------
-- Review round 1 (found by the waiting lines' volume case): the options a nightly check asks, their working tables
-- released at once
------------------------------------------------------------------------------------------

-- private.transfer_line_offers, redefined from 20261117110000_transfer_line_pages.sql (line 405; same signature and
-- settings, its grants restated below; its comment there). The options of a line (private.transfer_line_options_of,
-- through private.transfer_line_check) build their working tables (pg_temp._tl_u, _tl, _tl_items, _tl_drafts, _tl_pool
-- …), dropped and created again at each call, and a dropped table's lock is held to the end of the transaction: the
-- nightly checks ask this of every possible debit past the bound days (private.remittance_chain_holds, the booked
-- branch; private.remittance_inflight_judge and private.transfer_debit_suppression, the in-flight branch — production
-- since 6b-2c), all in one transaction, and the lock table filled after about a hundred lines (« out of shared memory »:
-- the whole check failed — no R124-6 row written, no alert, that night and every night after). The answer is now read in
-- a subtransaction rolled back once read: the working tables and their locks go with it; nothing else is written there
-- (the options only read). The same answer, from the same reads.
create or replace function private.transfer_line_offers(p_line_id uuid, p_transfer_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v boolean;
begin
  if p_line_id is null or p_transfer_id is null then
    return false;
  end if;
  begin
    v := coalesce((select bool_or(x ->> 'transfer_id' = p_transfer_id::text)
                   from jsonb_array_elements(coalesce(private.transfer_line_options_of(p_line_id) -> 'proposals',
                                                      '[]'::jsonb)) p
                   cross join lateral jsonb_array_elements(p -> 'request') x), false);
    -- review round 1: the answer read, the subtransaction rolled back — its working tables and their locks with it
    raise exception 'transfer_line_offers: read' using errcode = 'CLO01';
  exception when sqlstate 'CLO01' then
    null;
  end;
  return v;
end;
$$;

-- private.remittance_breach_held, redefined from 20261121090000_switch_on_prerequisites_4.sql (line 114; same signature
-- and settings, its grants restated below; its comment there, and the one set below). M2c-6b-3b part 3 review round 1
-- (dt3-csv-hint-last-day-not-named): its details gain `last_uncovered_day`, the last business day no imported statement
-- covers (null when none) — the day an export must go past, also when more days are uncovered than the 31 named.
-- Otherwise unchanged: the standalone reading (one snapshot, its own correlated reads) the tests hold the nightly
-- checks' alert to, field by field; the checks no longer call it.
create or replace function private.remittance_breach_held(p_organization_id uuid, p_today date)
returns table (run_id uuid, currency char(3), amount_minor bigint, line_count integer, oldest_days integer,
               details jsonb)
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  with bp as materialized (
    select * from private.remittance_booked_chain_runs(p_organization_id)),
  l as materialized (           -- the lines due at the run's date with no row yet, each with the date it is held to
    select p.run_id, q.ledger_entry_id, x.amount_minor,
           case when q.unmeetable then m.latest_execution_date else q.latest_execution_date end as latest
    from bp p
    cross join lateral private.remittance_run_late_lines(p.run_id, p.paid_on) q
    left join lateral (select d.latest_execution_date
                       from private.remittance_deadline_or_null(q.encaissement_date, 30) d
                       where q.unmeetable and q.encaissement_date is not null) m on true
    cross join lateral (select y.amount_minor from public.remittance_line y
                        where y.ledger_entry_id = q.ledger_entry_id and not y.released offset 0) x
    where (not q.unmeetable or m.latest_execution_date < p.paid_on)
      and not exists (select 1 from public.remittance_deadline_breach b where b.ledger_entry_id = q.ledger_entry_id
                      offset 0)),
  f as materialized (           -- per run and date held to: the holds' facts, and the days no statement covers
    select k.run_id, k.latest, h.covered, h.lines,
           case when not h.covered
                then array(select g.d::date
                           from generate_series(least(coalesce(e.e0, k.latest), k.latest), k.latest,
                                                interval '1 day') g (d)
                           where private.is_business_day(g.d::date)
                             and not private.statement_covers(e.account, g.d::date, g.d::date)
                           order by 1) end as days
    from (select distinct l.run_id, l.latest, p.transfer_id, p.paying from l join bp p on p.run_id = l.run_id) k
    cross join lateral private.remittance_chain_hold_facts(k.transfer_id, k.paying, k.latest, null) h
    cross join lateral (
      select (select q.debtor_bank_account_id from public.bank_transfer q where q.id = k.transfer_id) as account,
             (select min(i.execution_date)
              from private.transfer_chain(k.transfer_id) c
              cross join lateral (select q.file_id, q.execution_date from public.transfer_file_item q
                                  where q.transfer_id = c.transfer_id offset 0) i
              cross join lateral (select ff.download_count from public.transfer_file ff where ff.id = i.file_id
                                  offset 0) ff
              where ff.download_count > 0) as e0) e),
  w as materialized (           -- the lines a covered date waits on: each once, with a transfer it may be the debit of
    select distinct on (f.run_id, (v.v ->> 1)::uuid)
           f.run_id, (v.v ->> 1)::uuid as line_id, (v.v ->> 2)::date as line_date, (v.v ->> 0)::uuid as transfer_id
    from f
    cross join lateral jsonb_array_elements(f.lines) v (v)
    where f.covered
    order by f.run_id, (v.v ->> 1)::uuid, (v.v ->> 2)::date, (v.v ->> 0)::uuid),
  s as materialized (
    select l.run_id, sum(l.amount_minor) as amount, count(*) as n, min(l.latest) as earliest,
           max(p_today - l.latest) as oldest,
           (array_agg(l.ledger_entry_id order by l.ledger_entry_id))[1:50] as ids
    from l group by l.run_id)
  select p.run_id, p.currency, s.amount::bigint, s.n::integer, s.oldest::integer,
         jsonb_build_object(
           'number', p.number,
           'judged_on', p.paid_on,
           'earliest_latest_execution_date', s.earliest,
           'uncovered_days', to_jsonb((array(select distinct u.d from f cross join unnest(f.days) u (d)
                                             where f.run_id = p.run_id order by 1))[1:31]),
           'uncovered_count', (select count(distinct u.d) from f cross join unnest(f.days) u (d)
                               where f.run_id = p.run_id),
           'last_uncovered_day', (select max(u.d) from f cross join unnest(f.days) u (d)
                                  where f.run_id = p.run_id),
           'balance_break', exists (select 1 from f where f.run_id = p.run_id and not f.covered
                                    and cardinality(f.days) = 0),
           'waiting', coalesce((select jsonb_agg(jsonb_build_object('line_id', z.line_id, 'booking_date', z.line_date,
                                                                    'amount_minor', z.amount_minor::text,
                                                                    'currency', z.currency,
                                                                    'end_to_end_id', z.end_to_end_id)
                                                 order by z.line_date, z.line_id)
                                from (select w.line_id, w.line_date, x.amount_minor, x.currency, tr.end_to_end_id
                                      from w
                                      cross join lateral (select q.amount_minor, q.currency
                                                          from public.bank_transaction q where q.id = w.line_id
                                                          offset 0) x
                                      cross join lateral (select q.end_to_end_id from public.bank_transfer q
                                                          where q.id = w.transfer_id offset 0) tr
                                      where w.run_id = p.run_id
                                      order by w.line_date, w.line_id
                                      limit 10) z), '[]'),
           'waiting_count', (select count(*) from w where w.run_id = p.run_id),
           'bound_days', private.transfer_debit_bound_days(),
           'ids', to_jsonb(s.ids))
  from bp p
  join s on s.run_id = p.run_id
  order by p.run_id;
$$;

-- M2c-6b-3b part 3: part 2's alert reading, kept as the standalone one (one snapshot) the tests compare the nightly
-- checks' alert with; the checks no longer call it.
comment on function private.remittance_breach_held(uuid, date) is
  'M2c-6b-3b part 2 (CPCE-08): the « remittance_breach_held » rows of the servicer''s booked chained runs read in one '
  'snapshot, standalone (the runs, their late lines without a row, the holds'' facts and the uncovered days read '
  'again; since its review round 1 its details also give last_uncovered_day). Since M2c-6b-3b part 3 the nightly '
  'checks raise the alert from what their booked branch recorded (pg_temp._rc_runs, pg_temp._rc_lines; '
  'private.run_remittance_runs_checks), the days once per account and window; this function is the reading the tests '
  'compare them with (pgTAP 042''s pg_temp.nightly, worker/tests/test_breach_held_integration.py).';

------------------------------------------------------------------------------------------
-- PR #40's CI round (ADR-0014 « M2c-6b-3b part 3 — CI round (PR #40) »): the nightly checks read each cancelled refund's
-- chain forward by key, whatever the statistics
------------------------------------------------------------------------------------------

-- A transfer and the transfers re-issuing it: itself, then the transfer whose replaces_transfer_id it is (at most one:
-- bank_transfer_replaces_transfer_id_key), and so on, by key — private.transfer_chain read the other way, with its depth
-- bound: y is in private.transfer_reissues(t) exactly when t is in private.transfer_chain(y) (replaces_transfer_id is
-- unique, so each transfer is re-issued at most once). Read by private.run_transfer_checks (below) for a cancelled
-- refund debited late, instead of every waiting refund of the servicer. Internal (EXECUTE revoked from every role).
create or replace function private.transfer_reissues(p_transfer_id uuid)
returns table (transfer_id uuid, depth integer)
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  with recursive c (transfer_id, depth) as (
    select p_transfer_id, 0 where p_transfer_id is not null
    union all
    select q.id, c.depth + 1
    from c
    cross join lateral (select y.id from public.bank_transfer y where y.replaces_transfer_id = c.transfer_id offset 0) q
    where c.depth < 50)
  select c.transfer_id, c.depth from c;
$$;

-- private.run_transfer_checks, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 2905; same signature
-- and settings — SECURITY DEFINER, search_path '', enable_seqscan off —, its grants restated below; its comments there).
-- PR #40's CI round (CI run 44909449352, the scale job: 486,480 rows of bank_transfer read by the nightly checks of
-- test_transfer_cancellation_scale_integration.py, its bound 183,008): the arm « transfer_already_debited » over the
-- cancelled transfers of a downloaded file debited late (cx) excluded a refund whose chain's live end is still waiting
-- by reading every refund request the servicer has waiting (refund_request_waiting_idx), each one's transfer and chain
-- (private.transfer_chain), once per cancelled transfer debited late, until one held it: refund_request analysed (as
-- autovacuum left it in that run), a bitmap scan of all 10,012 waiting requests, 21 times — 210,250 probes of
-- bank_transfer and 200,210 chains (200,424 rows), reproduced to the row on the main stack after the scale job's earlier
-- files, with main's bodies as with this migration's (486,521 and 486,480); not analysed yet, the waiting index read in
-- requested_at order met the early refunds' re-issues after 488 requests each (86,480 rows in all, as main's CI run).
-- The same exclusion is now read from the cancelled refund forward (private.transfer_reissues: its re-issues by key,
-- each one's request by refund_request_transfer_id_key and its transfer's status by key) — the same rows (75,850 rows
-- of bank_transfer in that state, 65,874 with the tables analysed in the transaction). Nothing else changes.
create or replace function private.run_transfer_checks(p_check_run_id uuid, p_organization_id uuid,
                                                       p_today date default null)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_today date := coalesce(p_today, private.paris_today());
  v_now timestamptz := case when p_today is null or p_today = private.paris_today() then clock_timestamp()
                            else (p_today + time '23:59:59') at time zone 'Europe/Paris' end;
  v_bd2 date;   -- the second business day on or before today: a day before it is more than 1 business day ago
  v_bd3 date;
begin
  select c.day into v_bd2 from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day <= v_today and c.day > v_today - 30
  order by c.day desc offset 1 limit 1;
  select c.day into v_bd3 from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day <= v_today and c.day > v_today - 30
  order by c.day desc offset 2 limit 1;
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with flight as materialized (   -- the transfers in flight, per paying account (one pass each, keyed)
    select b.id as bank_account_id, b.currency, x.transfer_id, x.amount_minor, x.execution_date
    from public.bank_account b
    cross join lateral private.transfers_in_flight(b.id) x
    where b.organization_id = p_organization_id and b.purpose = 'client_funds'),
  cx as materialized (   -- M2c-6b-3a (C): the servicer's cancelled transfers that were in a downloaded file (read once)
    select t.id, t.kind, t.status, t.run_id, t.currency, t.amount_minor, t.created_at, t.end_to_end_id,
           t.debtor_bank_account_id
    from public.bank_account b
    cross join lateral (select q.id, q.kind, q.status, q.run_id, q.currency, q.amount_minor, q.created_at,
                               q.end_to_end_id, q.debtor_bank_account_id
                        from public.bank_transfer q
                        where q.organization_id = p_organization_id and q.debtor_bank_account_id = b.id
                          and q.status = 'cancelled' and q.transfer_file_id is not null offset 0) t
    where b.organization_id = p_organization_id and b.purpose = 'client_funds'
      and exists (select 1 from public.transfer_file_item i
                  cross join lateral (select f.download_count from public.transfer_file f
                                      where f.id = i.file_id offset 0) f
                  where i.transfer_id = t.id and f.download_count > 0))
  select p_check_run_id, p_organization_id, u.code, 'alert', u.subject_type, u.subject_id, u.currency, u.amount_minor,
         u.count, u.oldest_days, coalesce(u.details, '{}')
  from (
    select 'transfer_not_filed' as code, 'bank_account' as subject_type, t.debtor_bank_account_id as subject_id,
           t.currency, sum(t.amount_minor)::bigint as amount_minor, count(*)::integer as count,
           max(v_today - (t.created_at at time zone 'Europe/Paris')::date) as oldest_days,
           jsonb_build_object('ids', (array_agg(t.id order by t.created_at, t.id))[1:50]) as details
    from public.bank_transfer t
    where t.organization_id = p_organization_id and t.status = 'ordered' and t.kind in ('payout', 'refund', 'sweep')
      and (t.created_at at time zone 'Europe/Paris')::date < v_bd2
      and exists (select 1 from public.bank_account b where b.id = t.debtor_bank_account_id
                    and b.purpose = 'client_funds')
    group by t.debtor_bank_account_id, t.currency
    union all
    select 'file_not_downloaded', 'transfer_file', f.id, f.currency, f.ctrl_sum_minor, f.nb_of_txs,
           v_today - (f.generated_at at time zone 'Europe/Paris')::date, jsonb_build_object('number', f.number)
    from public.transfer_file f
    where f.organization_id = p_organization_id and f.status = 'generated'
      and (f.generated_at at time zone 'Europe/Paris')::date < v_bd2
    union all
    select 'file_not_marked_sent', 'transfer_file', f.id, f.currency, f.ctrl_sum_minor, f.nb_of_txs,
           v_today - f.first_execution_date, jsonb_build_object('number', f.number,
                                                                'first_execution_date', f.first_execution_date)
    from public.transfer_file f
    where f.organization_id = p_organization_id and f.status = 'downloaded'
      and private.transfer_file_cutoff_at(f.id) <= v_now
      and not (exists (select 1 from public.transfer_file_item i
                       cross join lateral (select t.status from public.bank_transfer t where t.id = i.transfer_id
                                           offset 0) t
                       where i.file_id = f.id and t.status = 'cancelled')
               and not private.transfer_file_executed(f.id))
    union all
    select 'transfer_not_debited', 'bank_account', x.bank_account_id, x.currency, sum(x.amount_minor)::bigint,
           count(*)::integer, max(v_today - x.execution_date),
           jsonb_build_object('ids', (array_agg(x.transfer_id order by x.execution_date, x.transfer_id))[1:50])
    from flight x
    where x.execution_date < v_bd3
    group by x.bank_account_id, x.currency
    union all
    select 'transfer_file_failed', 'transfer_file', f.id, f.currency, f.ctrl_sum_minor, f.nb_of_txs,
           v_today - (f.closed_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('number', f.number, 'error', f.error)
    from public.transfer_file f
    where f.organization_id = p_organization_id and f.status = 'failed'
      and exists (select 1 from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
                  where i.file_id = f.id and t.status = 'ordered')
    union all
    select 'transfer_file_pending', 'transfer_file', f.id, f.currency, f.ctrl_sum_minor, f.nb_of_txs,
           v_today - (f.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('number', f.number, 'created_at', f.created_at)
    from public.transfer_file f
    where f.organization_id = p_organization_id and f.status = 'pending'
      and f.created_at + interval '15 minutes' <= v_now
    union all
    select 'payee_name_mismatch', 'client_payout_account', c.payout_account_id, null, null, 1,
           v_today - (c.recorded_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('client_id', c.client_organization_id, 'result', c.result, 'check_id', c.id)
    from public.payee_name_check c
    where c.organization_id = p_organization_id and c.cleared_at is null
      and private.payee_check_open(c.payout_account_id)
    union all
    select 'transfer_already_debited', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'status', t.status, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id)
    from public.bank_transfer t
    where t.organization_id = p_organization_id and t.kind in ('payout', 'refund')
      and (t.status = 'ordered' or (t.status = 'in_file' and t.replaces_transfer_id is not null))
      and exists (select 1 from public.bank_account b where b.id = t.debtor_bank_account_id
                    and b.purpose = 'client_funds')
      and private.transfer_debited_before(t.id)
    union all
    select 'transfer_already_debited', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'status', t.status, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id)
    from public.bank_account b
    cross join lateral private.debited_cancelled_sweeps(b.id) s (id)
    cross join lateral (select x.* from public.bank_transfer x where x.id = s.id offset 0) t
    where b.organization_id = p_organization_id and b.purpose = 'client_funds'
    union all
    -- M2c-6b-3a (A): a sweep in flight made after a cancelled sweep the bank debited late (its share left once already)
    select 'transfer_already_debited', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'status', t.status, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id, 'reason', 'cancelled_sweep_debited')
    from public.bank_account b
    cross join lateral (select q.* from public.bank_transfer q
                        where q.debtor_bank_account_id = b.id and q.status in ('ordered', 'in_file') and q.kind = 'sweep'
                        offset 0) t
    where b.organization_id = p_organization_id and b.purpose = 'client_funds'
      and private.sweep_after_debited_cancelled(t.id)
    union all
    -- M2c-6b-3a (M): a payout or a refund in flight held for a cancelled one of its client or payment debited late (not
    -- alerted above already)
    select 'transfer_already_debited', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'status', t.status, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id, 'reason', s.reason)
    from public.bank_account b
    cross join lateral (select q.* from public.bank_transfer q
                        where q.debtor_bank_account_id = b.id and q.status in ('ordered', 'in_file')
                          and q.kind in ('payout', 'refund') offset 0) t
    cross join lateral (select private.transfer_sibling_debited_late(t.id) as reason) s
    where b.organization_id = p_organization_id and b.purpose = 'client_funds' and s.reason is not null
      and not ((t.status = 'ordered' or t.replaces_transfer_id is not null) and private.transfer_debited_before(t.id))
    union all
    -- review round 4 (G1); M2c-6b-3a (C, G1c): a cancelled payout or refund that was in a downloaded file, debited after
    -- all, its late line not booked nor linked — whatever its run's or refund's state (the alert stops once ops book or
    -- link that line) —, but while the live end of its chain is alerted by the ordered or in-file branch above
    select 'transfer_already_debited', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'status', t.status, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id)
    from cx t
    where t.kind in ('payout', 'refund')
      and private.transfer_debited_before(t.id)
      and private.transfer_late_debit_open(t.id)
      and not exists (select 1 from public.remittance_run r
                      cross join lateral (select y.status from public.bank_transfer y where y.id = r.transfer_id offset 0) y
                      where t.kind = 'payout' and r.id = t.run_id and r.status in ('approved', 'sent')
                        and y.status in ('ordered', 'in_file')
                        and exists (select 1 from private.transfer_chain(r.transfer_id) c where c.transfer_id = t.id))
      -- PR #40's CI round: the refund requests whose transfer's chain holds t, read from t forward by key
      -- (private.transfer_reissues: y is in it exactly when t is in private.transfer_chain(y)) — no longer every
      -- refund the servicer has waiting, each with its transfer and its chain, once per cancelled refund debited late
      and not exists (select 1
                      from private.transfer_reissues(t.id) c
                      cross join lateral (select q.organization_id, q.status from public.refund_request q
                                          where q.transfer_id = c.transfer_id offset 0) q
                      cross join lateral (select y.status from public.bank_transfer y where y.id = c.transfer_id offset 0) y
                      where t.kind = 'refund' and q.organization_id = p_organization_id and q.status = 'requested'
                        and y.status in ('ordered', 'in_file'))
    union all
    select h.code, 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id)
    from public.bank_transfer t
    cross join lateral (select 'payee_name_not_epc' as code where private.epc_name_empty(t.payee_name)
                        union all
                        select 'iban_not_sepa' where not private.iban_in_sepa(t.payee_iban)) h
    where t.organization_id = p_organization_id and t.status = 'ordered' and t.kind in ('payout', 'refund')
      and exists (select 1 from public.bank_account b where b.id = t.debtor_bank_account_id
                    and b.purpose = 'client_funds')
    union all
    -- M2c-6b-1 (P0): a debit of a cancelled transfer — its own id, or a batch line that can hold it
    -- (private.transfer_late_lines: private.transfer_debited_before's two branches) — not booked nor linked, one row per
    -- line, whatever the state of its run or refund (a cancelled one included: G1c); and a line the debit job left to
    -- ops for it. The source: the cancelled transfers that were in a downloaded file (their partial index).
    select 'cancelled_transfer_debited', 'bank_transaction', x.id, x.currency, x.amount_minor, 1,
           v_today - x.booking_date,
           jsonb_build_object('transfer_ids', l.transfer_ids, 'kinds', l.kinds, 'run_ids', l.run_ids,
                              'refund_request_ids', l.refund_ids, 'pmt_inf_id', x.payment_info_id,
                              'end_to_end_id', x.end_to_end_id)
    from (select z.line_id,
                 coalesce(jsonb_agg(distinct z.transfer_id) filter (where z.transfer_id is not null), '[]') as transfer_ids,
                 coalesce(jsonb_agg(distinct z.kind) filter (where z.kind is not null), '[]') as kinds,
                 coalesce(jsonb_agg(distinct z.run_id) filter (where z.run_id is not null), '[]') as run_ids,
                 coalesce(jsonb_agg(distinct z.refund_id) filter (where z.refund_id is not null), '[]') as refund_ids
          from (select ll.line_id, t.id as transfer_id, t.kind, t.run_id,
                       (select q.id from public.refund_request q
                        where q.transfer_id = t.id
                           or q.transfer_id = (select y.id from public.bank_transfer y where y.replaces_transfer_id = t.id)
                        limit 1) as refund_id
                from cx t
                cross join lateral private.transfer_late_lines(t.id) ll (line_id)
                union all
                select v.bank_transaction_id, null::uuid, null::text, null::uuid, null::uuid
                from public.bank_debit_review v
                where v.organization_id = p_organization_id and v.reason = 'cancelled_transfer_debited') z
          group by z.line_id) l
    cross join lateral (select q.* from public.bank_transaction q where q.id = l.line_id offset 0) x
    where not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link k where k.bank_transaction_id = x.id and k.kind <> 'explained'
                      offset 0)
    union all
    -- a second debit of a transfer booked or returned, a debit of a transfer never handed out (the bank has bytes we
    -- never served): the lines the debit job left to ops for it (P0; plan §2.3); M2c-6b-2a (critic L14): a line, debit
    -- or credit, carrying a reference of ours (RMT, SWP, a lot) no transfer of ours has (transfer_unknown)
    select v.reason, 'bank_transaction', x.id, x.currency, x.amount_minor, 1, v_today - x.booking_date,
           jsonb_build_object('end_to_end_id', x.end_to_end_id, 'pmt_inf_id', x.payment_info_id,
                              'candidates', v.candidates)
    from public.bank_debit_review v
    cross join lateral (select q.* from public.bank_transaction q where q.id = v.bank_transaction_id offset 0) x
    where v.organization_id = p_organization_id and v.reason in ('transfer_debited_twice', 'transfer_not_handed_out',
                                                                 'transfer_unknown')
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link k where k.bank_transaction_id = x.id offset 0)
    union all
    -- a payout returned by the client's bank (P0 while its item waits to be paid again: drafted at once by the
    -- schedule, trigger payout_returned; the payout account `returned` until replaced or reconfirmed)
    select 'payout_returned', 'remittance_run', bt.run_id, q.currency, q.amount_minor, 1,
           v_today - (q.posted_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('client_id', q.client_organization_id, 'transfer_id', bt.id,
                              'end_to_end_id', bt.end_to_end_id, 'draft_run_id', q.draft_run_id)
    from private.remittance_pending q
    cross join lateral (select e.reverses_entry_id from public.ledger_entry e where e.id = q.ledger_entry_id offset 0) e
    cross join lateral (select r.source_id from public.ledger_entry r
                        where r.id = e.reverses_entry_id and r.source_type = 'bank_transfer' offset 0) re
    cross join lateral (select t.id, t.run_id, t.end_to_end_id, t.entry_id from public.bank_transfer t
                        where t.id = case when pg_input_is_valid(re.source_id, 'uuid') then re.source_id::uuid end
                        offset 0) bt
    where q.organization_id = p_organization_id and q.kind = 'payout_returned'
      -- M2c-6b-2a: the transfer's own payout (an unplanned payout's return is the branch below) — M2c-6b-3a-2 (F): a
      -- late predecessor's, its payout booking's entry
      and (bt.entry_id = e.reverses_entry_id
           or exists (select 1 from public.bank_line_booking k
                      where k.entry_id = e.reverses_entry_id and k.kind = 'payout' and k.transfer_id = bt.id))
    union all
    -- M2c-6b-2a (plan §2.6): the return of an unplanned payout (ops' unplanned_payout_returned, 6b-2b) while its item
    -- waits to be paid again, as a planned payout's (by the booking whose entry queued the item: keyed)
    select 'payout_returned', 'bank_transaction', k.bank_transaction_id, q.currency, q.amount_minor, 1,
           v_today - (q.posted_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('client_id', q.client_organization_id, 'transfer_id', k.transfer_id, 'unplanned', true,
                              'draft_run_id', q.draft_run_id)
    from private.remittance_pending q
    cross join lateral (select k.bank_transaction_id, k.transfer_id from public.bank_line_booking k
                        where k.entry_id = q.ledger_entry_id and k.kind = 'unplanned_payout_returned' offset 0) k
    where q.organization_id = p_organization_id and q.kind = 'payout_returned'
    union all
    -- a sweep returned by the own account's bank (P0 while the servicer's share is not swept again)
    select 'sweep_returned', 'bank_transfer', t.id, t.currency, t.amount_minor, 1, v_today - re.effective_date,
           jsonb_build_object('end_to_end_id', t.end_to_end_id, 'bank_account_id', t.debtor_bank_account_id)
    from public.bank_transfer t
    cross join lateral (select e.effective_date, e.posted_at from public.ledger_entry e
                        where e.id = t.return_entry_id offset 0) re
    where t.organization_id = p_organization_id and t.kind = 'sweep' and t.status = 'returned'
      and not exists (select 1 from public.bank_transfer s
                      where s.organization_id = t.organization_id and s.kind = 'sweep'
                        and s.debtor_bank_account_id = t.debtor_bank_account_id and s.created_at > re.posted_at
                        and s.status <> 'cancelled')
    union all
    -- M2c-6b-2a (plan §2.6): the return of an unplanned sweep (ops' unplanned_sweep_returned, 6b-2b), the same way (its
    -- booking by the partial index bank_line_booking_unplanned_return_idx)
    select 'sweep_returned', 'bank_transaction', k.bank_transaction_id, l.currency, k.amount_minor, 1,
           v_today - l.booking_date,
           jsonb_build_object('transfer_id', k.transfer_id, 'unplanned', true, 'bank_account_id', k.bank_account_id)
    from public.bank_line_booking k
    cross join lateral (select q.currency, q.booking_date from public.bank_transaction q
                        where q.id = k.bank_transaction_id offset 0) l
    cross join lateral (select e.posted_at from public.ledger_entry e where e.id = k.entry_id offset 0) re
    where k.organization_id = p_organization_id and k.kind = 'unplanned_sweep_returned'
      and not exists (select 1 from public.bank_transfer s
                      where s.organization_id = k.organization_id and s.kind = 'sweep'
                        and s.debtor_bank_account_id = k.bank_account_id and s.created_at > re.posted_at
                        and s.status <> 'cancelled')
    union all
    -- an advance the servicer made at a payout's debit (the payout went beyond what the client was owed: a collection
    -- reversed after the approval), open until recovered (M2c-7's advance_open takes it over)
    select 'payout_overrun', 'client_advance', a.id, a.currency, (a.amount_minor - coalesce(s.settled, 0))::bigint, 1,
           v_today - (a.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('client_id', a.client_organization_id, 'transfer_id', a.transfer_id,
                              'bank_transaction_id', a.bank_transaction_id)
    from public.client_advance a
    left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                       where c.document_kind = 'advance' and c.document_id = a.id) s on true
    where a.organization_id = p_organization_id and a.cause = 'payout_overrun'
      and a.amount_minor > coalesce(s.settled, 0)
    union all
    -- M2c-6b-2a (plan §2.6): the advance of a double payout (6b-2b's unplanned payouts: what P could not net), open
    -- until recovered (M2c-7) — none once its entry is reversed (the unplanned payout came back)
    select 'double_payout_open', 'client_advance', a.id, a.currency, (a.amount_minor - coalesce(s.settled, 0))::bigint,
           1, v_today - (a.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('client_id', a.client_organization_id, 'transfer_id', a.transfer_id,
                              'bank_transaction_id', a.bank_transaction_id)
    from public.client_advance a
    left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                       where c.document_kind = 'advance' and c.document_id = a.id) s on true
    where a.organization_id = p_organization_id and a.cause = 'double_payout'
      and a.amount_minor > coalesce(s.settled, 0)
      and not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = a.entry_id)
    union all
    -- M2c-6b-2a (plan §2.6; critic L10; COMPLIANCE OQ-84 (e)): a payment made of a line carrying our RMT/SWP id (own or
    -- original) or naming one of our lots — the flag « Paiements à traiter » shows, read the same way — unassigned for
    -- more than one business day: one of our transfers come back, sitting on 4710 with no R124-6 clock (P0)
    select 'own_transfer_payment', 'payment', p.id, p.currency, p.amount_minor, 1, v_today - p.booking_date,
           jsonb_build_object('bank_transaction_id', p.bank_transaction_id, 'end_to_end_id', t.end_to_end_id,
                              'original_end_to_end_id', t.original_end_to_end_id, 'pmt_inf_id', t.payment_info_id)
    from public.payment p
    cross join lateral (select q.end_to_end_id, q.original_end_to_end_id, q.payment_info_id, q.bank_account_id
                        from public.bank_transaction q where q.id = p.bank_transaction_id offset 0) t
    where p.organization_id = p_organization_id and p.status = 'unmatched' and p.booking_date < v_bd2
      and (private.names_our_transfer(t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id)
           or private.names_our_lot(t.bank_account_id, t.payment_info_id))
    union all
    -- our transfer lines left to ops more than one business day (an I9 gap: 5120 and the bank differ by them)
    select 'bank_line_unbooked', 'bank_account', x.bank_account_id, x.currency, sum(x.amount_minor)::bigint,
           count(*)::integer, max(v_today - x.booking_date),
           jsonb_build_object('ids', (array_agg(x.id order by x.booking_date, x.id))[1:50],
                              'reasons', to_jsonb(array_agg(distinct x.reason)), 'p0', bool_or(x.p0))
    from (
    select x.id, x.bank_account_id, x.currency, x.amount_minor, x.booking_date, v.reason, false as p0
    from public.bank_debit_review v
    cross join lateral (select q.* from public.bank_transaction q where q.id = v.bank_transaction_id offset 0) x
    -- review M2c-6b-2a (M2, T1): a line held as a suspected duplicate and released is read as the kind it was released
    -- as (bank_duplicate_resolution, by its key), as the job reads it (coalesce(released_kind, kind))
    left join lateral (select r.released_kind from public.bank_duplicate_resolution r
                       where r.bank_transaction_id = x.id and r.decision = 'released' offset 0) dr on true
    where v.organization_id = p_organization_id and x.booking_date < v_bd2
      and (coalesce(dr.released_kind, x.kind) = 'transfer_out'
           or (x.direction = 'debit' and x.end_to_end_id is null and x.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
           or (x.direction = 'credit' and coalesce(dr.released_kind, x.kind) = 'return'
               and coalesce(x.original_end_to_end_id, x.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$')
           -- M2c-6b-2a (plan §2.6; the inventory): an entry kept unsplit holding ours, a credit naming our lot, an own or
           -- a client's credit carrying our RMT/SWP id (S16), and (review M2, T1: the plan's clause, restored — a held
           -- line released as a return is no `return` by its own kind) the returns the job leaves for ops' booking
           or x.unsplit_ours > 0
           or (x.direction = 'credit' and private.names_our_lot(x.bank_account_id, x.payment_info_id))
           or (coalesce(dr.released_kind, x.kind) in ('own_transfer_in', 'client_transfer_in')
               and coalesce(x.original_end_to_end_id, x.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$')
           or v.reason in ('unplanned_payout_return', 'return_debit_pending'))
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link k where k.bank_transaction_id = x.id and k.kind <> 'explained'
                      offset 0)
    union all
    -- M2c-6b-2c (plan §4.2; critic2 ML-7): an other debit without our reference a transfer of ours may be (rule 3b's
    -- probe), not booked nor linked, with no review (counted above), by bank_transaction_other_debit_idx; p0 when an
    -- in-flight candidate's run has a positive live line past its latest execution date
    select x.id, x.bank_account_id, x.currency, x.amount_minor, x.booking_date, 'payout_amount_match', c.p0
    from (select q.id, q.bank_account_id, q.currency, q.amount_minor, q.booking_date, q.direction, q.unsplit_ours
          from public.bank_transaction q
          where q.organization_id = p_organization_id and q.kind = 'other_debit' and q.booking_date < v_bd2
          offset 0) x
    cross join lateral (select count(*) as n,
                               coalesce(bool_or(c.cand = 'i' and exists (
                                 select 1
                                 from (select q.amount_minor, q.released, q.latest_execution_date
                                       from public.remittance_line q where q.run_id = c.run_id offset 0) rl
                                 where rl.amount_minor > 0 and not rl.released
                                   and rl.latest_execution_date < v_today)), false) as p0
                        from private.transfer_line_candidates(x.id, private.transfer_line_class(x.id)) c) c
    where x.direction = 'debit' and x.unsplit_ours is null and c.n > 0
      and not exists (select 1 from public.bank_debit_review v where v.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link k where k.bank_transaction_id = x.id offset 0)
    ) x
    group by x.bank_account_id, x.currency
    union all
    -- the servicer's settled share on the dedicated account for more than two business days, no sweep ordered or in
    -- a file (§13 #8): −Σ4679 > 0 three business days ago and today
    select 'servicer_funds_unswept', 'servicer', null, s.currency, (-s.now_owed)::bigint, null, null,
           jsonb_build_object('due_to_servicer_minor', s.now_owed::text, 'as_of', v_bd3)
    from (select la.currency, sum(lp.amount_minor) as now_owed,
                 coalesce(sum(lp.amount_minor) filter (where lp.effective_date <= v_bd3), 0) as then_owed
          from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
          where la.organization_id = p_organization_id and la.book = 'due_to_servicer'
          group by la.currency) s
    where s.now_owed < 0 and s.then_owed < 0
      and not exists (select 1 from public.bank_transfer x
                      where x.organization_id = p_organization_id and x.kind = 'sweep' and x.currency = s.currency
                        and x.status in ('ordered', 'in_file'))
    union all
    -- a top-up ordered more than one business day ago, its credit not booked yet
    select 'top_up_pending', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('end_to_end_id', t.end_to_end_id, 'bank_account_id', t.creditor_bank_account_id)
    from public.bank_transfer t
    where t.organization_id = p_organization_id and t.kind = 'top_up' and t.status in ('ordered', 'in_file')
      and (t.created_at at time zone 'Europe/Paris')::date < v_bd2) u;
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new internals revoked)
------------------------------------------------------------------------------------------

-- the new internal and the one created again (PostgreSQL grants EXECUTE to PUBLIC by default): only the SECURITY
-- DEFINER callers use them
revoke execute on function private.remittance_chain_holds(uuid, uuid, date, date, boolean, uuid, date),
  private.remittance_chain_judged(uuid, date, date, uuid, uuid, date, boolean)
  from public, anon, authenticated, service_role;
-- the redefined, as 20261119090000 (private.remittance_chain_rows) and 20261121090000
-- (private.run_remittance_runs_checks) left them
revoke execute on function private.remittance_chain_rows(uuid, date, date, uuid, uuid, date, boolean),
  private.run_remittance_runs_checks(uuid, uuid, date)
  from public, anon, authenticated, service_role;
-- review round 1: private.remittance_breach_held, as 20261121090000 left it, and private.transfer_line_offers, as
-- 20261117110000 left it (internal: only the SECURITY DEFINER callers use them)
revoke execute on function private.remittance_breach_held(uuid, date), private.transfer_line_offers(uuid, uuid)
  from public, anon, authenticated, service_role;

-- PR #40's CI round: the new internal (PostgreSQL grants EXECUTE to PUBLIC by default), and private.run_transfer_checks
-- as 20261118100000 left it (internal: only private.run_payment_checks, SECURITY DEFINER, calls them)
revoke execute on function private.transfer_reissues(uuid), private.run_transfer_checks(uuid, uuid, date)
  from public, anon, authenticated, service_role;
