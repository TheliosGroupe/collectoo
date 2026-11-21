-- M2c-6b-3b part 2: the held-rows alert and the booking guard's plans (ADR-0014 « M2c-6b-3b part 2 »; COMPLIANCE
-- CPCE-08). THE SWITCH STAYS OFF: no statement here writes private.feature_switch; 6b-3b part 3 flips
-- 'downloaded_file_cancellation' with a one-line migration once the founder answers Q1 (OQ-81 (a)). pgTAP 033 (the
-- switch-off test) is unchanged.
--   * « remittance_breach_held » (founder question 2 of « M2c-6b-3b part 1 », its default; CPCE-08): since 6b-3b part
--     1 the R124-6 rows of a booked run whose payout chain holds another transfer wait until the paying account's
--     statements cover [least(e0, L), L] and no line that may be another transfer's debit waits
--     (private.remittance_chain_holds); while they wait, the nightly checks now raise an alert of their own on the run,
--     naming the days no statement covers (or a break in the balances) or the lines waiting
--     (private.remittance_breach_held). It is read after the booked branch wrote the rows that are due, so it resolves
--     itself: the check that writes the row, or finds the client paid on time, raises none. An operational safeguard,
--     not a legal deadline — no rule of law gives it a date. Reachable only for a chain (a payout cancelled out of a
--     downloaded file and re-issued, or a late predecessor): production has none while the switch is off.
--   * PR #38's known limit: private.bank_line_booking_guard() (the statement trigger on bank_line_booking) runs under
--     enable_seqscan off, as the re-check (private.bank_booking_recheck) since PR #38's CI round, and its one join (the
--     reversed booking's run) is read by key: its keyed reads per new row are probes of their indexes whatever the
--     statistics. The same rows and verdict; only the plans change.
--
-- New (internal, EXECUTE revoked from every role): private.remittance_booked_chain_runs (the nightly booked branch's
-- runs, its CTEs moved there unchanged, shared with the alert) and private.remittance_breach_held (the alert's rows).
-- Redefined, each copied from its latest definition across all the migration files and changed only as its comment
-- says, with SECURITY DEFINER where it was, every SET clause, search_path and its grants restated:
--   private.run_remittance_runs_checks (20261119090000_switch_on_prerequisites_3.sql:1552)
--   private.bank_line_booking_guard (20261118100000_switch_on_prerequisites_2.sql:2595)
--   private.bank_booking_post_rows (20261119090000_switch_on_prerequisites_3.sql:457; review round 1, tests-ui-1: the
--     funds pass's posting under enable_seqscan off too — its last-seq read was a scan per new booking)

------------------------------------------------------------------------------------------
-- The held rows' alert
------------------------------------------------------------------------------------------

-- The booked runs the nightly check's booked branch judges (M2c-6b-3b part 1 and its review round 1; CPCE-08), moved
-- here unchanged from private.run_remittance_runs_checks (20261119090000_switch_on_prerequisites_3.sql, its bc and bp
-- CTEs) so that the held rows' alert reads the very same runs: every booked run of the servicer whose payout chain holds
-- a payout cancelled out of a downloaded file, its payout standing (the transfer of its chain whose `payout` booking's
-- entry is not reversed), with a line late at the chain's paid date (private.remittance_chain_paid) — or, the chain
-- having paid nothing, at that payout booking's line date — that has no R124-6 row yet. paying: the transfer the run is
-- booked by; chain_paid: the chain's paid date (null when no copy stayed); paid_on: the date the run is judged at. Also
-- the run's transfer, number and currency (the alert's). Keyed: the servicer's cancelled filed transfers by
-- bank_transfer_cancelled_filed_idx, each run, chain and line by key.
create or replace function private.remittance_booked_chain_runs(p_organization_id uuid)
returns table (run_id uuid, organization_id uuid, client_organization_id uuid, requested_execution_date date,
               late_reason text, paying uuid, chain_paid date, paid_on date, transfer_id uuid, number text,
               currency char(3))
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  with bc as materialized (
    select distinct x.run_id
    from (select q.run_id, q.kind from public.bank_transfer q
          where q.organization_id = p_organization_id and q.status = 'cancelled' and q.transfer_file_id is not null
          offset 0) x
    where x.kind = 'payout' and x.run_id is not null)
  -- M2c-6b-3b part 1 (booking-rows-skip-chain-coverage-and-waiting-lines): every booked run of them whose payout
  -- stands — the transfer of its chain whose payout booking's entry is not reversed (a run whose payout came back has
  -- its sums owed again, their rows the queue's) — at the chain's paid date, its lines late then with no row yet
  -- (rows append-only, once: a row the booking wrote stays), whose two holds pass (private.remittance_chain_rows,
  -- decided: a line that may have been another transfer's debit waits while young or while it offers that transfer's
  -- booking, else « bloqué : débit possible non comptabilisé »). The rows the booking did not write (the statements not
  -- covering L then, or such a line waiting) are written here once both hold; a return that undid a copy moves the paid
  -- date later (round 2) — an execution only ever moves it earlier, never a row more.
  -- Review round 1 (nightly-null-paid-date-skips-standing-run; CPCE-08): a chain that paid nothing (every execution came
  -- back, the return not booked as the payout's yet) while its payout booking stands is judged at that booking's line
  -- date, as private.bank_booking_post_rows judges it — the same row whichever of the return and the cover reaches the
  -- statements first. (chain-holds-snapshot-race) The chain's paid date read here is passed to the holds, which read it
  -- again with the coverage and the possible debits in one snapshot and wait when it moved.
  select r.id, r.organization_id, r.client_organization_id, r.requested_execution_date, r.late_reason,
         s.transfer_id, p.paid_on, coalesce(p.paid_on, s.line_date), r.transfer_id, r.number, r.currency
  from bc
  cross join lateral (select q.id, q.organization_id, q.client_organization_id, q.requested_execution_date,
                             q.late_reason, q.status, q.transfer_id, q.number, q.currency
                      from public.remittance_run q where q.id = bc.run_id offset 0) r
  cross join lateral (select k.transfer_id, x.booking_date as line_date
                      from private.transfer_chain(r.transfer_id) h
                      cross join lateral (select k.entry_id, k.transfer_id, k.bank_transaction_id
                                          from public.bank_line_booking k
                                          where k.transfer_id = h.transfer_id and k.kind = 'payout' offset 0) k
                      cross join lateral (select q.booking_date from public.bank_transaction q
                                          where q.id = k.bank_transaction_id offset 0) x
                      where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id
                                        offset 0)
                      limit 1) s
  cross join lateral (select c.paid_on from private.remittance_chain_paid(r.transfer_id) c offset 0) p
  where r.status = 'booked'
    and exists (select 1 from private.remittance_run_late_lines(r.id, coalesce(p.paid_on, s.line_date)) q
                where not exists (select 1 from public.remittance_deadline_breach b
                                  where b.ledger_entry_id = q.ledger_entry_id offset 0));
$$;

-- « remittance_breach_held » (M2c-6b-3b part 2; CPCE-08; founder question 2 of « M2c-6b-3b part 1 », its default): the
-- booked runs of private.remittance_booked_chain_runs whose lines due at the date the run is judged at — each held to
-- its latest execution date, or to the one-month date of its collection for a delay that cannot be met once that date
-- is before the run's (as private.remittance_chain_rows reads them) — have no R124-6 row: the two holds of
-- private.remittance_chain_holds keep it back. Per run: its currency, the held lines' amount and count, the days since
-- the earliest date they are held to, and in details its number, the date it is judged at (judged_on), that earliest
-- date, and why the rows wait, from the holds' own facts (private.remittance_chain_hold_facts, per date held to: one
-- snapshot, this statement's) —
--   uncovered_days: the business days of [least(e0, L), L] (e0 the earliest execution date of the chain's transfers
--     handed out) no imported statement of the paying account covers yet (private.statement_covers of each day; the
--     first 31, uncovered_count all of them); balance_break: a window whose every day is covered but whose statements'
--     balances do not follow (a statement missing between two: private.statement_covers' break);
--   waiting: once the dates are covered, the lines dated by L that may be the debit of another transfer of the chain
--     handed out and that the chain's rule does not count yet ([line, its booking date, amount and currency, the
--     end-to-end id of the transfer it may be]; the first 10 by date, waiting_count all of them) — each waits while
--     younger than bound_days (private.transfer_debit_bound_days) business days or while it offers that transfer's
--     booking; past them offering none, the row is written « bloqué : débit possible non comptabilisé »;
--   ids: the held lines' ledger entries (the first 50).
-- Neither days nor lines: the facts moved while the check ran (another session's import or booking between the booked
-- branch's statement and this one); the next check judges the run again. Read by private.run_remittance_runs_checks
-- after its booked branch wrote the rows that are due: a run whose rows are written raises nothing — the alert resolves
-- itself. An operational safeguard, not a legal deadline. Keyed as its facts.
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

-- private.run_remittance_runs_checks, redefined from 20261119090000_switch_on_prerequisites_3.sql (line 1552; same
-- signature and settings, its grants restated below). M2c-6b-3b part 2 (CPCE-08): the booked branch's runs come from
-- private.remittance_booked_chain_runs (its bc and bp CTEs moved there unchanged), and the results gain the alert
-- « remittance_breach_held » (private.remittance_breach_held), read after the booked branch wrote the rows that are
-- due. Every other check as before.
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
  with bp as materialized (
    select * from private.remittance_booked_chain_runs(p_organization_id)),
  late as materialized (
    select p.run_id, p.organization_id, p.client_organization_id, p.requested_execution_date, p.late_reason,
           x.ledger_entry_id, x.payment_id, x.deadline, x.latest_execution_date, x.kind, x.debit_unbooked
    from bp p
    cross join lateral private.remittance_chain_rows(p.run_id, p.paid_on, p.chain_paid, p.paying, null, v_today,
                                                     true) x)
  insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                 run_id, deadline, latest_execution_date, requested_execution_date,
                                                 late_reason, blocked_reason)
  select l.organization_id, l.client_organization_id, l.ledger_entry_id, l.payment_id, l.run_id, l.deadline,
         l.latest_execution_date, l.requested_execution_date, l.late_reason,
         case when l.debit_unbooked then 'debit_unbooked' when l.kind = 'payout_returned' then 'payout_returned' end
  from late l
  on conflict (ledger_entry_id) do nothing;

  with dl as materialized (     -- the collections waiting, of files under a mandate with terms (review legal#2)
    select * from private.pending_item_deadlines(p_organization_id) d where d.monitored),
  ol as materialized (          -- the collections of runs approved or sent, not debited by their date (legal#3)
    select * from private.inflight_overdue_lines(p_organization_id, v_today)),
  ua as materialized (          -- money matched to a file, not allocated (legal#7, perf#0)
    select * from private.unallocated_payment_deadlines(p_organization_id)),
  -- M2c-6b-3b part 2 (CPCE-08; founder question 2 of « M2c-6b-3b part 1 », its default): the booked runs of a chain
  -- whose R124-6 rows the holds keep back — read after the first statement above wrote the rows that are due, so a
  -- run whose row is written raises nothing
  bh as materialized (
    select * from private.remittance_breach_held(p_organization_id, v_today)),
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

-- private.bank_line_booking_guard, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 2595; same
-- signature, its grants restated below). M2c-6b-3b part 2 (PR #38's known limit; ADR-0014 « M2c-6b-3b part 2 »):
-- enable_seqscan off in its own settings, beside hash and merge joins off — each of its keyed reads per new row (the
-- line, its duplicate resolution, the entry, the debit link, the payment, the transfer, the bookings of the reversed
-- entry, the entry's postings and their accounts) is a probe of that key's index whatever the statistics, never a
-- scan of the table once per row: a 2,000-member batch line posted in one statement, a probe priced at 1,000 pages and
-- the statistics forgotten, handled 36 million rows (bank_transfer scanned once per new row, five times over); and the
-- reversed booking's run, a join that enable_seqscan off alone left reading bank_line_booking whole per new row
-- through another index, is read by key (below): 48,001 rows. The transition table (new_rows) is read whole as before.
-- Nothing else changes.
create or replace function private.bank_line_booking_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
set enable_seqscan = off
as $$
declare v_bad text;
begin
  select min(n.bank_transaction_id::text || ':' || n.seq) into v_bad
  from new_rows n
  cross join lateral (
    select t.organization_id, t.bank_account_id, t.direction, t.booking_date,
           case when t.kind = 'suspected_duplicate' then r.released_kind else t.kind end as kind,
           e.entry_type, e.effective_date, e.source_type, e.source_id, e.organization_id as entry_org,
           e.reverses_entry_id,
           (select l.kind from public.bank_debit_link l where l.bank_transaction_id = t.id) as link_kind,
           exists (select 1 from public.payment p where p.bank_transaction_id = t.id offset 0) as paid,
           (select x.creditor_bank_account_id from public.bank_transfer x where x.id = n.transfer_id) as tr_creditor,
           (select x.debtor_bank_account_id from public.bank_transfer x where x.id = n.transfer_id) as tr_debtor,
           (select x.kind from public.bank_transfer x where x.id = n.transfer_id) as tr_kind,
           (select x.entry_id from public.bank_transfer x where x.id = n.transfer_id) as tr_entry,
           coalesce(t.unsplit_ours, 0) > 0 as unsplit,
           (select k.kind from public.bank_line_booking k where k.entry_id = e.reverses_entry_id) as reversed_kind,
           (select k.transfer_id from public.bank_line_booking k where k.entry_id = e.reverses_entry_id)
             as reversed_transfer,
           -- review round 2: the run of the booking's transfer, and of the reversed booking's
           (select x.run_id from public.bank_transfer x where x.id = n.transfer_id) as tr_run,
           -- (M2c-6b-3b part 2) the reversed booking's transfer read by its entry, then that transfer's run by its key:
           -- joined, bank_line_booking was read whole through bank_line_booking_transfer_idx once per new row whatever
           -- enable_seqscan (a probe priced at 1,000 pages, the statistics forgotten: the guard's statement handled 12
           -- million rows for a 2,000-member batch line). The same row: entry_id is unique, a booking without a transfer
           -- has no run
           (select y.run_id from public.bank_transfer y
            where y.id = (select k.transfer_id from public.bank_line_booking k where k.entry_id = e.reverses_entry_id))
             as reversed_run,
           (select count(*) from public.ledger_posting p
            where p.entry_id = n.entry_id
              and (select la.bank_account_id from public.ledger_account la where la.id = p.ledger_account_id)
                  = t.bank_account_id) as on_line_bank
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    left join public.ledger_entry e on e.id = n.entry_id
    where t.id = n.bank_transaction_id
    offset 0) x
  where x.organization_id <> n.organization_id or x.bank_account_id <> n.bank_account_id
     or x.entry_org is distinct from n.organization_id or x.effective_date is distinct from x.booking_date
     or x.on_line_bank <> 1
     or x.kind is null
     -- a line explained without booking, or a payment's return or refund, is not also booked; a loss completes a
     -- return of what was left of its payment; a line that is a payment is booked by its cash_in, never in the funds
     or (x.link_kind is not null and not (n.kind = 'loss' and x.link_kind = 'return'))
     or x.paid
     or case n.kind
          when 'fee' then not (x.entry_type = 'bank_fee' and n.transfer_id is null
                               and x.source_type = 'bank_transaction' and x.source_id = n.bank_transaction_id::text
                               and ((x.direction = 'debit' and x.kind in ('other_debit', 'transfer_out',
                                                                           'batch_unsplit'))
                                    or (x.direction = 'credit' and x.kind = 'return')))
          when 'loss' then not (x.entry_type = 'servicer_loss' and n.transfer_id is null and x.direction = 'debit'
                                and x.kind = 'return' and x.source_type = 'bank_transaction'
                                and x.source_id = n.bank_transaction_id::text)
          when 'top_up' then not (x.entry_type = 'servicer_top_up' and x.direction = 'credit'
                                  and x.kind = 'own_transfer_in'
                                  and ((n.transfer_id is null and x.source_type = 'bank_transaction'
                                        and x.source_id = n.bank_transaction_id::text)
                                       or (n.transfer_id is not null and x.tr_kind = 'top_up'
                                           and x.tr_creditor = n.bank_account_id and x.source_type = 'bank_transfer'
                                           and x.source_id = n.transfer_id::text)))
          when 'payout' then not (x.entry_type = 'remittance'
                                  and ((x.direction = 'debit'
                                        and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit')) or x.unsplit)
                                  and n.transfer_id is not null and x.tr_kind = 'payout'
                                  and x.tr_debtor = n.bank_account_id and x.source_type = 'bank_transfer'
                                  and x.source_id = n.transfer_id::text)
          when 'unplanned_payout' then not (x.entry_type = 'remittance'
                                            and ((x.direction = 'debit'
                                                  and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit'))
                                                 or x.unsplit)
                                            and ((n.transfer_id is null and x.source_type = 'bank_transaction'
                                                  and x.source_id = n.bank_transaction_id::text)
                                                 or (n.transfer_id is not null and x.tr_kind = 'payout'
                                                     and x.tr_debtor = n.bank_account_id
                                                     and x.source_type = 'bank_transfer'
                                                     and x.source_id = n.transfer_id::text)))
          when 'sweep' then not (x.entry_type = 'servicer_sweep'
                                 and ((x.direction = 'debit'
                                       and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit')) or x.unsplit)
                                 and n.transfer_id is not null and x.tr_kind = 'sweep'
                                 and x.tr_debtor = n.bank_account_id and x.source_type = 'bank_transfer'
                                 and x.source_id = n.transfer_id::text)
          when 'unplanned_sweep' then not (x.entry_type = 'servicer_sweep'
                                           and ((x.direction = 'debit'
                                                 and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit'))
                                                or x.unsplit)
                                           and ((n.transfer_id is null and x.source_type = 'bank_transaction'
                                                 and x.source_id = n.bank_transaction_id::text)
                                                or (n.transfer_id is not null and x.tr_kind = 'sweep'
                                                    and x.tr_debtor = n.bank_account_id
                                                    and x.source_type = 'bank_transfer'
                                                    and x.source_id = n.transfer_id::text)))
          when 'payout_returned' then not (x.entry_type = 'reversal'
                                           and ((x.direction = 'credit'
                                                 and x.kind in ('return', 'own_transfer_in', 'client_transfer_in'))
                                                or x.unsplit)
                                           and n.transfer_id is not null and x.tr_kind = 'payout'
                                           and x.tr_debtor = n.bank_account_id
                                           and (x.reverses_entry_id is not distinct from x.tr_entry
                                                -- M2c-6b-3a-2 (G): a late predecessor (no entry of its own): the
                                                -- entry of its payout booking
                                                or (x.tr_entry is null and x.reversed_kind = 'payout'
                                                    and x.reversed_transfer = n.transfer_id)))
          when 'sweep_returned' then not (x.entry_type = 'reversal'
                                          and ((x.direction = 'credit'
                                                and x.kind in ('return', 'own_transfer_in', 'client_transfer_in'))
                                               or x.unsplit)
                                          and n.transfer_id is not null and x.tr_kind = 'sweep'
                                          and x.tr_debtor = n.bank_account_id
                                          and x.reverses_entry_id is not distinct from x.tr_entry)
          -- M2c-6b-2b: the return of an unplanned payout or sweep reverses the entry of an unplanned booking of the
          -- same transfer (or of none), on a credit coming back (or a line of an entry kept unsplit)
          when 'unplanned_payout_returned' then not (x.entry_type = 'reversal'
                                                     and ((x.direction = 'credit'
                                                           and x.kind in ('return', 'own_transfer_in',
                                                                          'client_transfer_in'))
                                                          or x.unsplit)
                                                     and x.reversed_kind = 'unplanned_payout'
                                                     and (x.reversed_transfer is not distinct from n.transfer_id
                                                          -- review round 2: another payout of the same run
                                                          or (n.transfer_id is not null and x.tr_run is not null
                                                              and x.reversed_run = x.tr_run))
                                                     and (n.transfer_id is null
                                                          or (x.tr_kind = 'payout' and x.tr_debtor = n.bank_account_id)))
          when 'unplanned_sweep_returned' then not (x.entry_type = 'reversal'
                                                    and ((x.direction = 'credit'
                                                          and x.kind in ('return', 'own_transfer_in',
                                                                         'client_transfer_in'))
                                                         or x.unsplit)
                                                    and x.reversed_kind = 'unplanned_sweep'
                                                    and x.reversed_transfer is not distinct from n.transfer_id
                                                    and (n.transfer_id is null
                                                         or (x.tr_kind = 'sweep' and x.tr_debtor = n.bank_account_id)))
          when 'client_payment' then not (x.entry_type = 'client_payment_dedicated' and x.direction = 'credit'
                                          and x.kind = 'client_transfer_in' and n.transfer_id is null
                                          and x.source_type = 'bank_transaction'
                                          and x.source_id = n.bank_transaction_id::text)
          else true end;
  if v_bad is not null then
    raise exception 'bank line booking %: it does not match its line, entry or transfer', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

-- private.bank_booking_post_rows, redefined from 20261119090000_switch_on_prerequisites_3.sql (line 457; same
-- signature, its grants restated below). Review round 1 of M2c-6b-3b part 2 (tests-ui-1; ADR-0014 « M2c-6b-3b part 2
-- review fixes »): the funds pass's posting runs under enable_seqscan off, as its re-check
-- (private.bank_booking_recheck) and the booking guard — since PR #38's CI round it kept its callers' settings, and its
-- one correlated read of a stored table per new booking, the line's last seq (bank_line_booking by its primary key),
-- was then a scan of bank_line_booking once per row whenever the planner priced it below a probe: the guard's test,
-- with bookings already stored (a first 2,000-member batch line), saw the posting's insert handle 4,024,001 rows for the
-- second line's 2,000 (2,000 stored rows read per new row; production's bookings would be read whole per row). Every
-- other read of a stored table here is by its key already (the arrays of ids, the balances by client); the job's
-- temporary tables are read whole as before (no index: the only plan). The same rows written in the same order; only
-- the plans change. Nothing else changes.
create or replace function private.bank_booking_post_rows(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_ret record;
  v_entry uuid;
  v_bad text;
begin
  drop table if exists pg_temp._bb_entry;
  create temp table _bb_entry (entry_no integer primary key, entry_id uuid not null) on commit drop;

  -- (1) the remittances, sweeps, fees, top-ups and losses, and a returned transfer's bank charge (entry_no −ord)
  if exists (select 1 from pg_temp._bb b
             where b.kind in ('payout', 'sweep', 'fee', 'top_up', 'loss')
                or (b.kind in ('payout_returned', 'sweep_returned') and b.tr_minor > b.line_minor)) then
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                    client_organization_id, source_type, source_id, reason)
    select b.ord, p_organization_id,
           case b.kind when 'payout' then 'remittance' when 'sweep' then 'servicer_sweep' when 'fee' then 'bank_fee'
                       when 'top_up' then 'servicer_top_up' else 'servicer_loss' end,
           b.line_date,
           case b.kind when 'payout' then 'remit:' || b.transfer_id when 'sweep' then 'sweep:' || b.transfer_id
                       when 'fee' then 'fee:' || b.bank_transaction_id when 'top_up' then 'topup:' || b.bank_transaction_id
                       else 'loss:' || b.bank_transaction_id end,
           case when b.kind = 'payout' then b.tr_client end,
           case when b.transfer_id is not null then 'bank_transfer' else 'bank_transaction' end,
           coalesce(b.transfer_id, b.bank_transaction_id)::text,
           -- M2c-6b-2b (critic CSO-1): a payout's remittance entry never takes ops' motif as its reason (the client's
           -- whole-client members read that entry); the motif stays on bank_line_booking.reason, staff only
           case when b.kind = 'payout' then null
                else coalesce(nullif(btrim(b.reason), ''),
                              case b.kind when 'loss' then 'Excédent du retour sur le paiement (OQ-34)' end) end
    from pg_temp._bb b where b.kind in ('payout', 'sweep', 'fee', 'top_up', 'loss')
    union all
    select -b.ord, p_organization_id, 'bank_fee', b.line_date, 'fee:' || b.bank_transaction_id, null,
           'bank_transaction', b.bank_transaction_id::text,
           'Frais de la banque déduits du virement revenu impayé (relevé du ' || to_char(b.line_date, 'DD/MM/YYYY') || ')'
    from pg_temp._bb b where b.kind in ('payout_returned', 'sweep_returned') and b.tr_minor > b.line_minor;
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
    select e.entry_no, v.line_no, v.book, v.sign * e.amount, e.currency,
           case v.book when 'client_money_cash' then e.line_bank when 'own_cash' then e.own_bank end
    from (select b.ord as entry_no, b.kind, b.book_minor as amount, b.currency, b.line_bank,
                 case b.kind when 'sweep' then b.tr_creditor else b.own_bank end as own_bank
          from pg_temp._bb b where b.kind in ('payout', 'sweep', 'fee', 'top_up', 'loss')
          union all
          select -b.ord, 'fee', b.tr_minor - b.line_minor, b.currency, b.line_bank, null
          from pg_temp._bb b where b.kind in ('payout_returned', 'sweep_returned') and b.tr_minor > b.line_minor) e
    cross join lateral (
      select * from (values
        -- remittance: +4670[c] N / −5120 N
        ('payout', 1, 'client_payable', 1), ('payout', 2, 'client_money_cash', -1),
        -- servicer_sweep: +4679 S / −5120 S ‖ +5122[own] S / −4689 S
        ('sweep', 1, 'due_to_servicer', 1), ('sweep', 2, 'client_money_cash', -1),
        ('sweep', 3, 'own_cash', 1), ('sweep', 4, 'due_from_client_funds', -1),
        -- bank_fee: +4679 / −5120 ‖ +6270 / −4689
        ('fee', 1, 'due_to_servicer', 1), ('fee', 2, 'client_money_cash', -1),
        ('fee', 3, 'bank_fees', 1), ('fee', 4, 'due_from_client_funds', -1),
        -- servicer_top_up: +5120 / −4679 ‖ +4689 / −5122
        ('top_up', 1, 'client_money_cash', 1), ('top_up', 2, 'due_to_servicer', -1),
        ('top_up', 3, 'due_from_client_funds', 1), ('top_up', 4, 'own_cash', -1),
        -- servicer_loss: +4679 / −5120 ‖ +6780 / −4689
        ('loss', 1, 'due_to_servicer', 1), ('loss', 2, 'client_money_cash', -1),
        ('loss', 3, 'servicer_losses', 1), ('loss', 4, 'due_from_client_funds', -1)
      ) w (kind, line_no, book, sign) where w.kind = e.kind) v;
    insert into pg_temp._bb_entry (entry_no, entry_id) select x.entry_no, x.entry_id from private.ledger_post_set() x;
  end if;

  -- (2) the returned transfers: their entry reversed at the return date (few: one by one)
  for v_ret in select b.ord, b.tr_entry, b.bank_transaction_id, b.line_date, b.kind from pg_temp._bb b
           where b.kind in ('payout_returned', 'sweep_returned') order by b.ord loop
    select x.entry_id into v_entry
    from private.ledger_reverse(v_ret.tr_entry, 'return:' || v_ret.bank_transaction_id,
                                case v_ret.kind when 'payout_returned' then 'Virement de reversement revenu impayé'
                                            else 'Virement au compte propre revenu impayé' end
                                || ' (relevé du ' || to_char(v_ret.line_date, 'DD/MM/YYYY') || ')',
                                v_ret.line_date) x;
    insert into pg_temp._bb_entry (entry_no, entry_id) values (v_ret.ord, v_entry);
  end loop;

  -- (3) the booked runs' settlements, at the debit date (§5.2, OQ-37 default)
  if exists (select 1 from pg_temp._bb b where b.kind = 'payout') then
    perform private.post_run_settlements(array(select b.tr_run from pg_temp._bb b where b.kind = 'payout' order by b.ord),
                                         array(select b.line_date from pg_temp._bb b where b.kind = 'payout'
                                               order by b.ord));
  end if;

  -- (4) the cover: what a booked payout left in debit on its client's 4670 (all its entries posted: the running
  -- balance), advanced by the servicer at the debit date
  drop table if exists pg_temp._bb_cover;
  create temp table _bb_cover on commit drop as
  select distinct on (b.tr_client, b.currency) b.ord, b.tr_client as client_organization_id, b.currency, b.transfer_id,
         b.bank_transaction_id, b.line_date, c.balance_minor as overrun, e.entry_id as cause_entry_id,
         gen_random_uuid() as advance_id
  from pg_temp._bb b
  join pg_temp._bb_entry e on e.entry_no = b.ord
  -- (CI scale fix) the balances by their key, the clients' array its condition: joined to the rows alone, a table
  -- estimated tiny was scanned once per payout row
  join (select q.client_organization_id, q.currency, q.balance_minor from private.client_payable_balance q
        where q.client_organization_id = any (array(select x.tr_client from pg_temp._bb x where x.kind = 'payout'))) c
    on c.client_organization_id = b.tr_client and c.currency = b.currency
  where b.kind = 'payout' and c.balance_minor > 0
  order by b.tr_client, b.currency, b.ord;
  if exists (select 1 from pg_temp._bb_cover) then
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                    client_organization_id, source_type, source_id, reason)
    select c.ord, p_organization_id, 'client_advance', c.line_date, 'adv:payout:' || c.transfer_id,
           c.client_organization_id, 'client_advance', c.advance_id::text,
           'Reversement au-delà de ce qui restait dû au mandant : avance du cabinet'
    from pg_temp._bb_cover c;
    -- client_advance: +4679 A / −4670[c] A ‖ +4112[c] A / −4689 A
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
    select c.ord, v.line_no, v.book, v.sign * c.overrun, c.currency
    from pg_temp._bb_cover c
    cross join (values (1, 'due_to_servicer', 1), (2, 'client_payable', -1), (3, 'client_advance_receivable', 1),
                       (4, 'due_from_client_funds', -1)) v (line_no, book, sign);
    drop table if exists pg_temp._bb_cover_posted;
    create temp table _bb_cover_posted on commit drop as select * from private.ledger_post_set();
    insert into public.client_advance (id, organization_id, client_organization_id, currency, amount_minor, cause,
                                       cause_entry_id, entry_id, bank_transaction_id, transfer_id)
    select c.advance_id, p_organization_id, c.client_organization_id, c.currency, c.overrun, 'payout_overrun',
           c.cause_entry_id, x.entry_id, c.bank_transaction_id, c.transfer_id
    from pg_temp._bb_cover c join pg_temp._bb_cover_posted x on x.entry_no = c.ord;
  end if;

  -- the bookings: one per row, the returned transfer's charge after its return; seq = the line's last + its rank
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method, reason, decided_by)
  select z.bank_transaction_id,
         coalesce((select max(k.seq) from public.bank_line_booking k where k.bank_transaction_id = z.bank_transaction_id),
                  0) + row_number() over (partition by z.bank_transaction_id order by z.o),
         p_organization_id, z.line_bank, z.kind, z.transfer_id, z.entry_id, z.amount, z.method, z.reason, z.decided_by
  from (select b.bank_transaction_id, b.ord::bigint * 2 as o, b.line_bank, b.kind, b.transfer_id, e.entry_id,
               b.book_minor as amount, b.method, nullif(btrim(b.reason), '') as reason, b.decided_by
        from pg_temp._bb b join pg_temp._bb_entry e on e.entry_no = b.ord
        union all
        select b.bank_transaction_id, b.ord::bigint * 2 + 1, b.line_bank, 'fee', null, e.entry_id,
               b.tr_minor - b.line_minor, b.method, nullif(btrim(b.reason), ''), b.decided_by
        from pg_temp._bb b join pg_temp._bb_entry e on e.entry_no = -b.ord
        where b.kind in ('payout_returned', 'sweep_returned')) z
  order by z.bank_transaction_id, z.o;

  -- the transfers booked (their entry) or returned (the reversal); the runs booked at the debit date; the run's payout
  -- account returned (it blocks payouts until replaced or reconfirmed: payout_account_returned). The transfers are
  -- reached by key whatever the statistics (review round 2, P2: joined to the rows alone, a table whose statistics are
  -- forgotten was hashed over a sequential scan of every servicer's transfers, once per chunk): the array of their
  -- ids is the index's condition.
  update public.bank_transfer x set status = 'booked', entry_id = s.entry_id
  from (select b.transfer_id, e.entry_id from pg_temp._bb b join pg_temp._bb_entry e on e.entry_no = b.ord
        where b.kind in ('payout', 'sweep', 'top_up') and b.transfer_id is not null) s
  where x.id = any (array(select b.transfer_id from pg_temp._bb b
                          where b.kind in ('payout', 'sweep', 'top_up') and b.transfer_id is not null))
    and x.id = s.transfer_id
    -- M2c-6b-3a-2 (E): a late predecessor stays cancelled, with no entry of its own (bank_transfer_guard keeps
    -- cancelled terminal): its debit is its payout booking's
    and x.status <> 'cancelled';
  update public.bank_transfer x set status = 'returned', return_entry_id = s.entry_id
  from (select b.transfer_id, e.entry_id from pg_temp._bb b join pg_temp._bb_entry e on e.entry_no = b.ord
        where b.kind in ('payout_returned', 'sweep_returned')) s
  where x.id = any (array(select b.transfer_id from pg_temp._bb b
                          where b.kind in ('payout_returned', 'sweep_returned') and b.transfer_id is not null))
    and x.id = s.transfer_id;
  -- (CI scale fix) the runs and the payout accounts by key as the transfers above: the array of their ids the index's
  -- condition (joined to the rows alone, remittance_run was hashed over a sequential scan of every servicer's runs)
  update public.remittance_run r set status = 'booked', booked_on = b.line_date, version = r.version + 1
  from pg_temp._bb b
  where r.id = any (array(select x.tr_run from pg_temp._bb x where x.kind = 'payout' and x.tr_run is not null))
    and b.kind = 'payout' and r.id = b.tr_run and r.status in ('approved', 'sent');
  update public.client_payout_account a set status = 'returned'
  from pg_temp._bb b
  where a.id = any (array(select x.run_payout_account from pg_temp._bb x
                          where x.kind = 'payout_returned' and x.run_payout_account is not null))
    and b.kind = 'payout_returned' and a.id = b.run_payout_account and a.status = 'active';

  -- R124-6 (I21): an item of a booked run debited after the date it is held to (its latest execution date, or one
  -- month for a delay that cannot be met, as private.remittance_late_lines) gets its breach row, once; a returned
  -- payout paid again is recorded « bloqué : virement revenu impayé » (Q7's default, OQ-36; review legal-texts#1).
  -- Its payment's key-share lock (the foreign key) was taken before the allocation lock (post_bank_bookings).
  -- M2c-6b-3a-2 review round 1 (LD-2; CPCE-08): judged at the earliest debit naming another transfer of the run's
  -- chain by our references (a late predecessor's own id, a detail of an entry kept
  -- unsplit, its PmtInf's batch line), not booked yet and dated before this line, when there is one — that execution
  -- paid the client at its date, and the re-issue's later debit booked here as the run's payout (the import books it)
  -- would otherwise record an append-only row for a run paid on time; the predecessor's line is then « Virement hors
  -- reversement ». The run is booked at this line's date (its transfer's debit), as before.
  -- Review round 4 (CPCE-08): one rule — for a run whose chain holds another transfer, the rows are judged at the date
  -- the chain paid the client and stayed paid (private.remittance_chain_paid: every execution and return of the chain
  -- on the statements, each counted for the transfer it names, this line its payout's execution): a predecessor whose
  -- every execution came back paid nothing (its return unflagged included), one executed again after its return or
  -- more often than it came back stays paid; this line's date when no transfer of the chain stayed paid. A run with
  -- no other transfer: this line's date, as before.
  -- M2c-6b-3b part 1 (booking-rows-skip-chain-coverage-and-waiting-lines; CPCE-08): a run whose chain holds another
  -- transfer gets its rows here only once the paying account's statements cover [least(e0, L), L] and no other
  -- transfer of the chain handed out has a line dated by L that may be its debit and that the chain's rule does not
  -- count yet (private.remittance_chain_rows, its holds undecided: any such line waits) — an earlier statement
  -- imported later, or a line without our references, may show the client paid on time, and the row is append-only;
  -- the nightly check's booked branch judges the run once they hold (private.run_remittance_runs_checks). A run with no
  -- other transfer: as before.
  -- Review round 1 (chain-holds-snapshot-race; CPCE-08): the holds read the chain's paid date again with the coverage and
  -- the possible debits, in one snapshot, and wait when it is not the one read here (chain_paid, null when no copy
  -- stayed): an earlier statement imported, or a line booked, by another session since this statement began.
  with pr0 as materialized (    -- each payout row's run, whether its chain holds another transfer, the chain's paid date
    select b.tr_run as run_id, b.transfer_id, b.line_date, ru.organization_id, ru.client_organization_id,
           ru.requested_execution_date, ru.late_reason, c.chained,
           case when c.chained
                then (select x.paid_on
                      from private.remittance_chain_paid(ru.transfer_id, b.bank_transaction_id, b.transfer_id) x)
                end as chain_paid
    from pg_temp._bb b
    cross join lateral (select q.organization_id, q.client_organization_id, q.requested_execution_date, q.late_reason,
                               q.transfer_id
                        from public.remittance_run q where q.id = b.tr_run offset 0) ru
    cross join lateral (select exists (select 1 from private.transfer_chain(ru.transfer_id) h
                                       where h.transfer_id is distinct from b.transfer_id) as chained) c
    where b.kind = 'payout'),
  pr as materialized (          -- … and the date its rows are judged at: this line's when no copy stayed
    select p.run_id, p.transfer_id, p.organization_id, p.client_organization_id, p.requested_execution_date,
           p.late_reason, p.chained, p.chain_paid,
           case when p.chained then coalesce(p.chain_paid, p.line_date) else p.line_date end as paid_on
    from pr0 p),
  late as materialized (
    select p.run_id, p.paid_on as line_date, p.organization_id, p.client_organization_id,
           p.requested_execution_date, p.late_reason, l.ledger_entry_id, l.payment_id, l.deadline,
           l.latest_execution_date, l.unmeetable, l.encaissement_date, l.kind
    from pr p
    cross join lateral private.remittance_run_late_lines(p.run_id, p.paid_on) l
    where not p.chained),
  m as materialized (
    select k.e_date, d.*
    from (select distinct l.encaissement_date as e_date from late l
          where l.unmeetable and l.encaissement_date is not null) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, 30) d),
  ch as materialized (
    select p.run_id, p.organization_id, p.client_organization_id, p.requested_execution_date, p.late_reason,
           x.ledger_entry_id, x.payment_id, x.deadline, x.latest_execution_date, x.kind, x.debit_unbooked
    from pr p
    cross join lateral private.remittance_chain_rows(p.run_id, p.paid_on, p.chain_paid, p.transfer_id, null, null,
                                                     false) x
    where p.chained)
  insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                 run_id, deadline, latest_execution_date, requested_execution_date,
                                                 late_reason, blocked_reason)
  select l.organization_id, l.client_organization_id, l.ledger_entry_id, l.payment_id, l.run_id,
         case when l.unmeetable then m.deadline else l.deadline end,
         case when l.unmeetable then m.latest_execution_date else l.latest_execution_date end,
         l.requested_execution_date, l.late_reason,
         case when l.kind = 'payout_returned' then 'payout_returned' end
  from late l left join m on l.unmeetable and m.e_date = l.encaissement_date
  where not l.unmeetable or m.latest_execution_date < l.line_date
  union all
  select c.organization_id, c.client_organization_id, c.ledger_entry_id, c.payment_id, c.run_id, c.deadline,
         c.latest_execution_date, c.requested_execution_date, c.late_reason,
         case when c.debit_unbooked then 'debit_unbooked' when c.kind = 'payout_returned' then 'payout_returned' end
  from ch c
  on conflict (ledger_entry_id) do nothing;

  delete from public.bank_debit_review v using pg_temp._bb b where v.bank_transaction_id = b.bank_transaction_id;
  perform private.ledger_check_now();
  -- each line booked whole, signed (I19 per line), set-based before the deferred trigger's own check
  select min(c.bank_transaction_id::text) into v_bad
  from (select distinct b.bank_transaction_id from pg_temp._bb b) l
  cross join lateral (select q.id as bank_transaction_id, q.direction, q.amount_minor, q.bank_account_id
                      from public.bank_transaction q where q.id = l.bank_transaction_id offset 0) c
  where private.bank_line_cash_moved(c.bank_transaction_id, c.bank_account_id)
        <> case c.direction when 'credit' then c.amount_minor else -c.amount_minor end;
  if v_bad is not null then
    raise exception 'bank line %: not booked whole', v_bad using errcode = 'LG001';
  end if;
  set constraints public.bank_line_booking_complete immediate;
  set constraints public.bank_line_booking_complete deferred;
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new internals revoked)
------------------------------------------------------------------------------------------

-- the new internals (PostgreSQL grants EXECUTE to PUBLIC by default): only the SECURITY DEFINER nightly checks use them
revoke execute on function private.remittance_booked_chain_runs(uuid), private.remittance_breach_held(uuid, date)
  from public, anon, authenticated, service_role;
-- the redefined, as 20261119090000 (private.run_remittance_runs_checks, private.bank_booking_post_rows) and
-- 20261118100000 (private.bank_line_booking_guard) left them
revoke execute on function private.run_remittance_runs_checks(uuid, uuid, date), private.bank_line_booking_guard(),
  private.bank_booking_post_rows(uuid)
  from public, anon, authenticated, service_role;
