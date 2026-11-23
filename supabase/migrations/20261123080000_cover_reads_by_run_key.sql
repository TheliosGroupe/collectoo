-- M2c-7a — CI round on main (ADR-0014 « M2c-7a — CI round (main) »). Forward-only.
--
-- CI run 45206756541 (the scale job, the push of 245296d): booking the 500-member lot short of one read 25,202,495 rows of
-- remittance_line (about 50,500 a member: every live line of the table) and took 6.2 s. private.cover_booked_run_reversals
-- read each booked run's lines through a lateral subquery « run_id = u.run_id and not released and kind in (…) »; when
-- remittance_line's last analyse saw two runs holding every line (the 50,000-line run cancelled, its lines released, and
-- its re-run: n_distinct of run_id 2), the probe of the run's key (a parameter: half the table estimated) was priced
-- above a bitmap of the whole partial index remittance_line_live_uq, whose predicate `not released` the filter implies —
-- read once per run. The same read sat in private.run_booked_cover_check (its generic plan of new.id) and in the
-- nightly's booked runs (private.run_advance_checks).
--
-- Each now reads the run's lines by the run's key alone inside the fence (remittance_line_pkey's prefix: no partial index's
-- predicate is implied there), `not released` and the kinds applied outside it; and « R is a live line of that run »
-- reads R's own live line by its key (remittance_line_live_uq, unique), its run compared outside. The same rows: a line
-- is read when it is a live allocation or forward line of the run, as before. Redefined, each copied whole from its
-- latest definition (20261122090000_remitted_reversals_covered.sql, lines 547, 731 and 895; its settings, SECURITY
-- DEFINER, search_path '' and grants restated, the reads above the only change): private.cover_booked_run_reversals,
-- private.run_booked_cover_check, private.run_advance_checks.
--
-- A second 7a read had the same exposure: the double payout's advance (private.transfer_line_post, [critic] F10) reads
-- the single mandate of its transfer's run's lines once per unplanned_payout part, and that function had no
-- enable_seqscan off — under the same statistics, a sequential scan of remittance_line per part (a 500-member PmtInf
-- the bank debits twice: 51,502,500 rows, 14.28 s, above the API's 8 s). Redefined, copied whole from its latest
-- definition (20261122090000 line 1602), with `set enable_seqscan = off` added and the body unchanged (its SECURITY
-- DEFINER, search_path '' and grants restated): the run's lines by remittance_line_pkey's prefix, the same mandate or
-- none.
-- The cancellation-after-download switch stays off: nothing here writes private.feature_switch.

------------------------------------------------------------------------------------------
-- The covers at the booking (20261122090000 line 547)
------------------------------------------------------------------------------------------

-- private.cover_booked_run_reversals, redefined from 20261122090000_remitted_reversals_covered.sql (line 547; same
-- signature and settings, its grants restated below): each run's lines by the run's key alone. Nothing else changes.
-- At the booking (plan §3.2.5, design §13 #3 as built): the runs booked in this transaction (before or after this call:
-- the amounts come from their lines, not from their status). For each live line of kind allocation or forward whose
-- entry has a reversal R that is not itself a live line of that run ([critic] M7-MONEY-1: a same-run pair), a cover of
-- line − C(R) when positive, dated greatest(R's date, the run's date), key adv:<R>:<run>, the payout's transfer and debit
-- line ([critic] F5; null for an N = 0 run booked at approval). Keyed: each run's lines by the primary key prefix, each
-- entry's reversal by ledger_entry_reversed_once_uq.
create or replace function private.cover_booked_run_reversals(p_run_ids uuid[], p_dates date[],
                                                              p_transfer_ids uuid[] default null,
                                                              p_line_ids uuid[] default null)
returns integer
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
begin
  if coalesce(cardinality(p_run_ids), 0) = 0 then
    return 0;
  end if;
  perform private.remitted_cover_begin();
  insert into pg_temp._rcv (n, reversal_id, organization_id, client_organization_id, currency, mandate_id, amount_minor,
                            on_date, idem_key, transfer_id, bank_transaction_id)
  select row_number() over (order by u.ord, l.line_no), r.id, x.organization_id, l.client_organization_id, l.currency,
         coalesce(l.mandate_id, (select pf.mandate_id from public.portfolio pf where pf.id = l.portfolio_id)),
         l.amount_minor - private.remitted_cover_held(r.id), greatest(r.effective_date, u.on_date),
         'adv:' || r.id || ':' || u.run_id, u.transfer_id, u.line_id
  from (select distinct on (y.run_id) y.run_id, y.on_date, y.transfer_id, y.line_id, y.ord
        from unnest(p_run_ids, p_dates, p_transfer_ids, p_line_ids) with ordinality y (run_id, on_date, transfer_id,
                                                                                        line_id, ord)
        where y.run_id is not null
        order by y.run_id, y.ord) u
  cross join lateral (select q.organization_id from public.remittance_run q where q.id = u.run_id offset 0) x
  -- (CI round, main) the run's lines by the run's key alone, their conditions outside the fence: with `not released`
  -- inside it, remittance_line_live_uq (that predicate) could stand for the key, read whole once per run
  cross join lateral (select q.line_no, q.ledger_entry_id, q.client_organization_id, q.currency, q.mandate_id,
                             q.portfolio_id, q.amount_minor, q.released, q.kind
                      from public.remittance_line q
                      where q.run_id = u.run_id offset 0) l
  cross join lateral (select q.id, q.effective_date from public.ledger_entry q
                      where q.reverses_entry_id = l.ledger_entry_id offset 0) r
  where not l.released and l.kind in ('allocation', 'forward')
    -- (CI round, main) R's own live line by its key (remittance_line_live_uq, unique), its run compared outside
    and not exists (select 1 from (select z.run_id from public.remittance_line z
                                   where z.ledger_entry_id = r.id and not z.released offset 0) z
                    where z.run_id = u.run_id)
    and l.amount_minor > private.remitted_cover_held(r.id);
  return private.remitted_cover_post();
end;
$$;

------------------------------------------------------------------------------------------
-- The check of a run set booked (LG009; 20261122090000 line 731)
------------------------------------------------------------------------------------------

-- private.run_booked_cover_check, redefined from 20261122090000_remitted_reversals_covered.sql (line 731; same
-- settings; the trigger remittance_run_booked_cover unchanged): the run's lines by its key alone. Nothing else changes.
-- On a run set booked: each live allocation or forward line whose entry has a reversal R that is not itself a live
-- line of that run ([critic]) is covered (gap 0). Keyed: the lines by the primary key prefix, each reversal by key.
create or replace function private.run_booked_cover_check()
returns trigger
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v record;
begin
  -- (CI round, main) the run's lines by its key alone, their conditions outside the fence (a generic plan of « new.id »
  -- priced a bitmap of remittance_line_live_uq whole below the key), R's own live line by its key
  for v in select r.id, private.remitted_cover_gap(r.id) as gap
           from (select l.ledger_entry_id, l.released, l.kind from public.remittance_line l
                 where l.run_id = new.id offset 0) l
           cross join lateral (select q.id from public.ledger_entry q
                               where q.reverses_entry_id = l.ledger_entry_id offset 0) r
           where not l.released and l.kind in ('allocation', 'forward')
             and not exists (select 1 from (select z.run_id from public.remittance_line z
                                            where z.ledger_entry_id = r.id and not z.released offset 0) z
                             where z.run_id = new.id) loop
    if v.gap <> 0 then
      raise exception 'ledger: run % booked with reversal % of a line remitted to client % not covered by an advance (gap %)',
        new.number, v.id, new.client_organization_id, v.gap using errcode = 'LG009';
    end if;
  end loop;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- The nightly's booked runs (20261122090000 line 895)
------------------------------------------------------------------------------------------

-- private.run_advance_checks, redefined from 20261122090000_remitted_reversals_covered.sql (line 895; same signature
-- and settings, its grants restated below): the runs booked since read each run's lines by the run's key alone. Nothing
-- else changes.
-- One statement per check into payment_check_result (one snapshot each):
--   remitted_reversal_uncovered (violation, subject the reversal): gap(R) ≠ 0 over [critic] F9 the reversals posted since
--     the servicer's last completed check run less one day (and, when they reverse a cover or an unplanned booking, the
--     cover's reversal and the booking's items' reversals), the reversals of the live allocation and forward lines of
--     the runs booked since (booked_on in the window, or — review round 1, CC-1 — their payout booking recorded in it,
--     whatever the debit's date), the reversals of the items attributed since, the reversals covered since, and the
--     reversals the last run listed uncovered — the day's activity, not the history, each window a key range whatever
--     the plan (CC-2); with p_full ([check 2] the 1st
--     of the month, Paris, or an admin's request: private.run_remittance_checks) every booked run's lines, every
--     attribution and every cover of the servicer. No previous run: the full pass;
--   advance_ledger (violation, subject the client): per client and currency, Σ (amount − settled) of its advances whose
--     entry is not reversed ≠ Σ its 4112 postings (I18's advance half, design §5.4); amount: 4112 less the advances;
--   advance_open (alert, subject the advance): open > 0, its entry not reversed, created more than 30 days before the
--     day the checks hold the books to (Paris); amount: open; details: its client, cause, mandate, recording date (and
--     settled_on_depth when the reversed item's settlement chain is deeper than private.item_settled_at follows).
-- Later slices redefine it with this signature (7b … 7e), and pgTAP 043 pins the full list of its codes ([critic] F12).
create or replace function private.run_advance_checks(p_check_run_id uuid, p_organization_id uuid,
                                                      p_today date default null, p_full boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_today date := coalesce(p_today, private.paris_today());
  v_prev uuid;
  v_since timestamptz;
  v_since_date date;
  v_full boolean := coalesce(p_full, false);
  v_from_ts timestamptz;
  v_from_date date;
begin
  select r.id, r.started_at - interval '1 day' into v_prev, v_since
  from public.payment_check_run r
  where r.organization_id = p_organization_id and r.finished_at is not null and r.id <> p_check_run_id
  order by r.started_at desc limit 1;
  if v_prev is null then
    v_full := true;
  end if;
  v_since_date := (v_since at time zone 'Europe/Paris')::date;
  -- (review round 1, CC-2) the window's lower bounds, -infinity for the full pass: a key range in every plan — a
  -- « v_full or … » predicate is a filter under the generic plan PL/pgSQL caches after five calls in one backend, and
  -- the delta pass would then read every booked run, attribution and cover of the servicer
  v_from_ts := case when v_full then '-infinity'::timestamptz else v_since end;
  v_from_date := case when v_full then '-infinity'::date else v_since_date end;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with day_rev as materialized (     -- the reversals posted since (ledger_entry_reversal_posted_idx)
    select x.id, x.reverses_entry_id from public.ledger_entry x
    where not v_full and x.organization_id = p_organization_id and x.entry_type = 'reversal' and x.posted_at >= v_since),
  booked as materialized (           -- the runs booked since (remittance_run_booked_idx), every one in the full pass
    select q.id from public.remittance_run q
    where q.organization_id = p_organization_id and q.status = 'booked' and q.booked_on >= v_from_date
    union
    -- (review round 1, CC-1) and the runs whose payout booking was recorded since, whatever their booked_on (the
    -- debit's date: a statement imported late, a late predecessor): bank_line_booking_org_idx, each transfer's run by key
    select t.run_id
    from (select b.transfer_id from public.bank_line_booking b
          where not v_full and b.organization_id = p_organization_id and b.decided_at >= v_from_ts
            and b.kind = 'payout' offset 0) b
    cross join lateral (select t.run_id from public.bank_transfer t
                        where t.id = b.transfer_id and t.run_id is not null offset 0) t),
  cand as materialized (
    select d.id as reversal_id from day_rev d
    union
    select a.cause_entry_id from day_rev d
    cross join lateral (select q.cause_entry_id from public.client_advance q
                        where q.entry_id = d.reverses_entry_id and q.cause = 'remitted_reversal' offset 0) a
    union
    select z.id from day_rev d
    cross join lateral (select u.ledger_entry_id from private.unplanned_paid_item u
                        where u.booking_entry_id = d.reverses_entry_id offset 0) u
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = u.ledger_entry_id offset 0) z
    union
    select z.id
    from booked r
    -- (CI round, main) each run's lines by the run's key alone, their conditions outside the fence
    cross join lateral (select l.ledger_entry_id, l.released, l.kind from public.remittance_line l
                        where l.run_id = r.id offset 0) l
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = l.ledger_entry_id offset 0) z
    where not l.released and l.kind in ('allocation', 'forward')
    union
    select z.id
    from (select u.ledger_entry_id from private.unplanned_paid_item u
          where u.organization_id = p_organization_id and u.created_at >= v_from_ts offset 0) u
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = u.ledger_entry_id offset 0) z
    union
    select a.cause_entry_id from public.client_advance a
    where a.organization_id = p_organization_id and a.cause = 'remitted_reversal' and a.created_at >= v_from_ts
    union
    select c.subject_id from public.payment_check_result c
    where c.run_id = v_prev and c.code = 'remitted_reversal_uncovered' and c.subject_id is not null)
  select p_check_run_id, p_organization_id, 'remitted_reversal_uncovered', 'violation', 'ledger_entry', c.reversal_id,
         f.currency, f.target - f.held, 1, v_today - (e.posted_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', f.client_organization_id, 'reversed_entry_id', e.reverses_entry_id,
                            'run_id', f.run_id, 'target', f.target::text, 'held', f.held::text,
                            'recorded_on', (e.posted_at at time zone 'Europe/Paris')::date)
  from cand c
  cross join lateral private.remitted_cover_fact(c.reversal_id) f
  cross join lateral (select q.posted_at, q.reverses_entry_id from public.ledger_entry q
                      where q.id = c.reversal_id offset 0) e
  where f.target <> f.held;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with adv as materialized (
    select a.client_organization_id, a.currency, sum(a.amount_minor - coalesce(s.settled, 0))::bigint as open_minor
    from (select q.id, q.client_organization_id, q.currency, q.amount_minor, q.entry_id from public.client_advance q
          where q.organization_id = p_organization_id offset 0) a
    left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                       where c.document_kind = 'advance' and c.document_id = a.id) s on true
    where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id)
    group by a.client_organization_id, a.currency),
  led as materialized (
    select la.client_organization_id, la.currency, coalesce(sum(p.s), 0)::bigint as balance_minor
    from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'client_advance_receivable' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.client_organization_id, la.currency)
  select p_check_run_id, p_organization_id, 'advance_ledger', 'violation', 'client',
         coalesce(a.client_organization_id, l.client_organization_id), coalesce(a.currency, l.currency),
         coalesce(l.balance_minor, 0) - coalesce(a.open_minor, 0), 1, null,
         jsonb_build_object('client_id', coalesce(a.client_organization_id, l.client_organization_id),
                            'advances_open', coalesce(a.open_minor, 0)::text,
                            'receivable', coalesce(l.balance_minor, 0)::text)
  from adv a
  full join led l on l.client_organization_id = a.client_organization_id and l.currency = a.currency
  where coalesce(a.open_minor, 0) <> coalesce(l.balance_minor, 0);

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'advance_open', 'alert', 'client_advance', a.id, a.currency,
         a.amount_minor - coalesce(s.settled, 0), 1, v_today - (a.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', a.client_organization_id, 'cause', a.cause, 'mandate_id', a.mandate_id,
                            'created_on', (a.created_at at time zone 'Europe/Paris')::date)
         || case when a.cause = 'remitted_reversal'
                      and exists (select 1
                                  from (select z.reverses_entry_id from public.ledger_entry z
                                        where z.id = a.cause_entry_id offset 0) z
                                  cross join lateral (select l.run_id from public.remittance_line l
                                                      where l.ledger_entry_id = z.reverses_entry_id and not l.released
                                                      offset 0) l
                                  cross join lateral private.item_settled_at(z.reverses_entry_id, l.run_id, 0) t
                                  where t.too_deep)
                 then jsonb_build_object('settled_on_depth', true) else '{}'::jsonb end
  from (select q.id, q.client_organization_id, q.currency, q.amount_minor, q.cause, q.mandate_id, q.created_at,
               q.entry_id, q.cause_entry_id
        from public.client_advance q
        where q.organization_id = p_organization_id
          and q.created_at < ((v_today - 30)::timestamp at time zone 'Europe/Paris') offset 0) a
  left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                     where c.document_kind = 'advance' and c.document_id = a.id) s on true
  where a.amount_minor > coalesce(s.settled, 0)
    and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id);
end;
$$;

------------------------------------------------------------------------------------------
-- The ops command's unplanned parts (20261122090000 line 1602)
------------------------------------------------------------------------------------------

-- private.transfer_line_post, redefined from 20261122090000_remitted_reversals_covered.sql (line 1602; same signature,
-- SECURITY DEFINER and search_path '', its grants restated below): `set enable_seqscan = off` added, the body unchanged.
-- (CI round, main, second read) The double payout's advance reads the single mandate of its transfer's run's lines
-- ([critic] F10) once per unplanned_payout part with an advance; the function had no enable_seqscan off (nor has its
-- caller public.book_transfer_line), so with remittance_line analysed at two runs the run's key (half the table
-- estimated) was read by a sequential scan of remittance_line per part. A fence alone does not help: a key estimated at
-- half the table is cheaper by a sequential scan whatever the shape. Under the setting, the run's lines by
-- remittance_line_pkey's prefix (no partial index's predicate is implied by the key alone); the same rows, the same
-- mandate or none. The setting also holds for its callees that have none of their own (the ledger's posting set and
-- reversals, private.transfer_file_release, private.ledger_check_now): measured at the 500-member lots, ADR-0014.
create or replace function private.transfer_line_post(p_line_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  l public.bank_transaction;
  v_date text;
  v_ret record;
  v_entry uuid;
  v_adv uuid;
  v_bad text;
  v_lp record;
begin
  select * into l from public.bank_transaction where id = p_line_id;
  v_date := to_char(l.booking_date, 'DD/MM/YYYY');

  -- 1. the unplanned remittances and sweeps
  if exists (select 1 from pg_temp._tl t where t.kind in ('unplanned_payout', 'unplanned_sweep')) then
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                    client_organization_id, source_type, source_id, reason)
    select t.n, l.organization_id, case t.kind when 'unplanned_payout' then 'remittance' else 'servicer_sweep' end,
           l.booking_date,
           case t.kind when 'unplanned_payout' then 'remit:line:' else 'sweep:line:' end || l.id || ':' || t.n,
           case when t.kind = 'unplanned_payout' then t.c end,
           case when t.transfer_id is not null then 'bank_transfer' else 'bank_transaction' end,
           coalesce(t.transfer_id, l.id)::text,
           case t.kind when 'unplanned_payout' then 'Virement exécuté hors reversement (relevé du ' || v_date || ')'
                       else 'Virement au compte propre hors ordre de Collectoo (relevé du ' || v_date || ')' end
    from pg_temp._tl t where t.kind in ('unplanned_payout', 'unplanned_sweep');
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
    select t.n, v.line_no, v.book, v.sign * t.a, l.currency,
           case v.book when 'client_money_cash' then l.bank_account_id when 'own_cash' then t.own_bank end
    from pg_temp._tl t
    cross join lateral (
      select * from (values
        -- remittance: +4670[c] A / −5120 A
        ('unplanned_payout', 1, 'client_payable', 1), ('unplanned_payout', 2, 'client_money_cash', -1),
        -- servicer_sweep: +4679 S / −5120 S ‖ +5122[own] S / −4689 S
        ('unplanned_sweep', 1, 'due_to_servicer', 1), ('unplanned_sweep', 2, 'client_money_cash', -1),
        ('unplanned_sweep', 3, 'own_cash', 1), ('unplanned_sweep', 4, 'due_from_client_funds', -1)
      ) w (kind, line_no, book, sign) where w.kind = t.kind) v
    where t.kind in ('unplanned_payout', 'unplanned_sweep');
    update pg_temp._tl t set entry_id = x.entry_id from private.ledger_post_set() x where x.entry_no = t.n;
  end if;
  -- their advances (A − P > 0), posted after the remittance (LG008 at ledger_check_now)
  update pg_temp._tl t set adv_id = gen_random_uuid() where t.kind = 'unplanned_payout' and t.adv > 0;
  if exists (select 1 from pg_temp._tl t where t.adv_id is not null) then
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                    client_organization_id, source_type, source_id, reason)
    select t.n, l.organization_id, 'client_advance', l.booking_date, 'adv:line:' || l.id || ':' || t.n, t.c,
           'client_advance', t.adv_id::text, 'Virement hors reversement : avance du cabinet'
    from pg_temp._tl t where t.adv_id is not null;
    -- client_advance: +4679 X / −4670[c] X ‖ +4112[c] X / −4689 X
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
    select t.n, v.line_no, v.book, v.sign * t.adv, l.currency
    from pg_temp._tl t
    cross join (values (1, 'due_to_servicer', 1), (2, 'client_payable', -1), (3, 'client_advance_receivable', 1),
                       (4, 'due_from_client_funds', -1)) v (line_no, book, sign)
    where t.adv_id is not null;
    update pg_temp._tl t set adv_entry_id = x.entry_id from private.ledger_post_set() x where x.entry_no = t.n;
    -- M2c-7a ([critic] F10): the advance's mandate is the single mandate of the lines (released or not) of its
    -- transfer's run, computed once per part; none when they hold several, or no run
    insert into public.client_advance (id, organization_id, client_organization_id, mandate_id, currency, amount_minor,
                                       cause, cause_entry_id, entry_id, bank_transaction_id, transfer_id, p_bound)
    select t.adv_id, l.organization_id, t.c,
           (select case when count(distinct q.mandate_id) = 1 and count(q.mandate_id) = count(*)
                        then (array_agg(q.mandate_id))[1] end
            from public.remittance_line q
            where q.run_id = (select x.run_id from public.bank_transfer x where x.id = t.transfer_id)),
           l.currency, t.adv, 'double_payout', t.entry_id, t.adv_entry_id, l.id, t.transfer_id, t.p_bound
    from pg_temp._tl t where t.adv_id is not null;
  end if;
  -- the −A pending rows (§3.6.2: with the advance's +(A − P), net −P in the queue) and the attributions (§3.6.4)
  insert into private.remittance_pending (ledger_entry_id, organization_id, client_organization_id, currency, kind,
                                          amount_minor, posted_at)
  select t.entry_id, l.organization_id, t.c, l.currency, 'unplanned_payout', -t.a, e.posted_at
  from pg_temp._tl t
  cross join lateral (select q.posted_at from public.ledger_entry q where q.id = t.entry_id offset 0) e
  where t.kind = 'unplanned_payout';
  insert into private.unplanned_paid_item (booking_entry_id, ledger_entry_id, organization_id, client_organization_id,
                                           currency, amount_minor)
  select t.entry_id, i.ledger_entry_id, l.organization_id, t.c, l.currency, i.amount_minor
  from pg_temp._tl_items i join pg_temp._tl t on t.n = i.n
  where i.amount_minor > 0;
  -- the returns and the unplanned returns (few: one by one)
  for v_ret in select * from pg_temp._tl t
               where t.kind in ('payout_returned', 'sweep_returned', 'unplanned_payout_returned',
                                'unplanned_sweep_returned')
               order by t.n loop
    v_adv := null;
    if v_ret.kind in ('payout_returned', 'sweep_returned') then
      select x.entry_id into v_entry
      from private.ledger_reverse(v_ret.tr_entry, 'return:' || l.id || ':' || v_ret.transfer_id,
                                  case v_ret.kind when 'payout_returned' then 'Virement de reversement revenu impayé'
                                                  else 'Virement au compte propre revenu impayé' end
                                  || ' (relevé du ' || v_date || ')', l.booking_date) x;
    else
      select x.entry_id into v_entry
      from private.ledger_reverse(v_ret.ub_entry, 'return:' || l.id || ':' || v_ret.n,
                                  case v_ret.kind when 'unplanned_payout_returned' then 'Virement hors reversement revenu'
                                                  else 'Virement au compte propre hors ordre de Collectoo revenu' end
                                  || ' (relevé du ' || v_date || ')', l.booking_date) x;
      if v_ret.ub_adv_entry is not null then
        select x.entry_id into v_adv
        from private.ledger_reverse(v_ret.ub_adv_entry, 'return:adv:' || l.id || ':' || v_ret.n,
                                    'Avance du cabinet annulée : virement hors reversement revenu (relevé du '
                                    || v_date || ')', l.booking_date) x;
      end if;
      -- M2c-7a (plan §3.2.8): the covers of the items this booking paid and that were reversed since, released
      -- down to what the other live bookings still paid (refused while settled or taken by a run in flight)
      perform private.remitted_cover_release(v_ret.ub_entry, l.id, l.booking_date);
    end if;
    update pg_temp._tl t set rev_entry_id = v_entry, rev_adv_entry_id = v_adv where t.n = v_ret.n;
  end loop;
  -- the bookings of these parts, then the transfers returned and the payout accounts returned
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method, reason, decided_by)
  select l.id,
         coalesce((select max(k.seq) from public.bank_line_booking k where k.bank_transaction_id = l.id), 0)
           + row_number() over (order by t.n),
         l.organization_id, l.bank_account_id, t.kind, t.transfer_id,
         case when t.kind in ('unplanned_payout', 'unplanned_sweep') then t.entry_id else t.rev_entry_id end,
         t.a, 'ops', p_reason, auth.uid()
  from pg_temp._tl t
  where t.kind in ('unplanned_payout', 'unplanned_sweep', 'payout_returned', 'sweep_returned',
                   'unplanned_payout_returned', 'unplanned_sweep_returned')
  order by t.n;
  update public.bank_transfer x set status = 'returned', return_entry_id = s.rev_entry_id
  from (select t.transfer_id, t.rev_entry_id from pg_temp._tl t where t.kind in ('payout_returned', 'sweep_returned')) s
  where x.id = any (array(select t.transfer_id from pg_temp._tl t where t.kind in ('payout_returned', 'sweep_returned')))
    and x.id = s.transfer_id
    -- M2c-6b-3a-2 (G): a late predecessor stays cancelled (its return is its payout_returned booking)
    and x.status <> 'cancelled';
  update public.client_payout_account a set status = 'returned'
  where a.id = any (array(select t.payout_account from pg_temp._tl t where t.payout_account is not null))
    and a.status = 'active';

  -- M2c-6b-3a-2 (E): a late predecessor's live end withdrawn before its payout is booked — its file, not downloaded
  -- yet, superseded (its other payouts and refunds back in the queue, its sweep cancelled: recomputed at the next file),
  -- then the re-issue cancelled; checked and locked as private.transfer_line_check and private.transfer_line_locks
  -- left them
  for v_lp in select t.lp_cancel, t.lp_cancel_e2e, t.lp_file, t.tr_e2e from pg_temp._tl t
              where t.lp and t.lp_cancel is not null order by t.n loop
    if v_lp.lp_file is not null then
      perform private.transfer_file_release(v_lp.lp_file, 'superseded',
        left('Virement ' || coalesce(v_lp.lp_cancel_e2e, '') || ' retiré : le virement qu''il remplace a été débité '
             || '(relevé du ' || v_date || ')', 2000), null, null);
    end if;
    update public.bank_transfer set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
      cancel_reason = left('Réémission annulée : le virement ' || coalesce(v_lp.tr_e2e, '') || ' qu''elle remplace a '
                           || 'été débité (relevé du ' || v_date || ')', 2000)
    where id = v_lp.lp_cancel and status = 'ordered';
  end loop;

  -- 2. the planned parts, through the job's posting
  if exists (select 1 from pg_temp._tl t where t.kind in ('payout', 'sweep', 'fee')) then
    perform private.bank_booking_begin();
    insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method, decided_by, reason)
    select t.n, l.id, t.kind, t.transfer_id, 'ops', auth.uid(), p_reason
    from pg_temp._tl t where t.kind in ('payout', 'sweep', 'fee');
    -- pg_temp._bb, private.post_bank_bookings' select list copied (private.transfer_line_bb)
    perform private.transfer_line_bb(l.id);
    perform private.bank_booking_post_rows(l.organization_id);
    update pg_temp._tl t set entry_id = e.entry_id
    from pg_temp._bb_entry e where e.entry_no = t.n and t.kind in ('payout', 'sweep', 'fee');
  else
    -- 3. no planned part: the line's review deleted, the ledger's checks, the line booked whole (signed)
    delete from public.bank_debit_review v where v.bank_transaction_id = l.id;
    perform private.ledger_check_now();
    if private.bank_line_cash_moved(l.id, l.bank_account_id)
       <> (case l.direction when 'credit' then l.amount_minor else -l.amount_minor end) then
      raise exception 'bank line %: not booked whole', l.id using errcode = 'LG001';
    end if;
    set constraints public.bank_line_booking_complete immediate;
    set constraints public.bank_line_booking_complete deferred;
  end if;
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (as 20261122090000 left them)
------------------------------------------------------------------------------------------

-- internal: the SECURITY DEFINER paths, the trigger, private.run_remittance_checks and public.book_transfer_line call
-- them
revoke execute on function private.cover_booked_run_reversals(uuid[], date[], uuid[], uuid[]),
  private.run_booked_cover_check(), private.run_advance_checks(uuid, uuid, date, boolean),
  private.transfer_line_post(uuid, text)
  from public, anon, authenticated, service_role;
