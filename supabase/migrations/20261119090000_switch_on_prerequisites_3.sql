-- M2c-6b-3b part 1: the last switch-on prerequisites (ADR-0014 « M2c-6b-3a-2 review fixes » « Open after round 4 », «
-- M2c-6b-3b part 1 »; COMPLIANCE CPCE-08). THE SWITCH STAYS OFF: no statement here writes private.feature_switch; 6b-3b
-- flips 'downloaded_file_cancellation' with a one-line migration once the founder answers Q1 (OQ-81 (a)). Every rule
-- below bites only for a run whose payout chain holds another transfer (a payout cancelled out of a downloaded file and
-- re-issued, or a late predecessor booked while its re-issue exists): production has none, and pgTAP 033 (the
-- switch-off test) is unchanged — but for review round 1's snapshot rule, which also reaches the nightly check's in-flight
-- branch of every run (below).
--   * booking-rows-skip-chain-coverage-and-waiting-lines (CPCE-08): the booking of such a run's payout writes its R124-6
--     rows only once the paying account's statements cover [least(e0, L), L] — e0 the earliest execution date of the
--     chain's transfers handed out — and no other transfer of the chain handed out has a line dated by L that may be
--     its debit and is not yet counted by the chain's rule (private.remittance_chain_holds); the sheet's late flag says
--     the same; the nightly check's booked branch judges such a run at the chain's paid date once both hold — a line
--     that may be such a transfer's debit and offers no booking of it past the bound days writing the row « bloqué :
--     débit possible non comptabilisé » — each item's row written once (append-only).
--   * review round 1 (ADR-0014 « M2c-6b-3b part 1 review fixes »; CPCE-08):
--     - nightly-null-paid-date-skips-standing-run: the nightly booked branch judges a run whose chain paid nothing while
--       its payout booking stands at that booking's line date, as the booking does;
--     - chain-holds-snapshot-race: every reader that writes an R124-6 row from the holds or the suppression — the
--       booking, its sheet, the nightly booked branch, and the nightly in-flight branch of every run (the switch off
--       included: a race since 6b-2c) — reads its facts in one snapshot (private.remittance_chain_hold_facts,
--       private.remittance_inflight_facts), waits when the chain's paid date moved since the caller's own read, and
--       writes a row resting on the options of an old line only if the facts read again afterwards have not moved
--       (private.remittance_chain_holds, private.remittance_inflight_judge).
--
-- New (internal): private.transfer_debit_lines (the lines private.transfer_debit_suppression reads, shared with the
-- holds), private.remittance_chain_hold_facts (the holds' facts in one snapshot), private.remittance_chain_holds (the
-- two holds at L), private.remittance_chain_rows (a chained run's rows due at a date: its lines late then whose holds
-- pass), private.remittance_inflight_facts and private.remittance_inflight_judge (the in-flight branch's rule on facts
-- read in one snapshot). Redefined, each copied from its latest definition across all the
-- migration files and changed only as its comment says, with SECURITY DEFINER, every SET clause, search_path and its
-- grants restated:
--   private.transfer_debit_suppression (20261117113000_transfer_line_pages_fixes.sql:175)
--   private.bank_booking_post_rows (20261118100000_switch_on_prerequisites_2.sql:2344)
--   private.transfer_line_check (20261118100000_switch_on_prerequisites_2.sql:801)
--   private.run_remittance_runs_checks (20261118100000_switch_on_prerequisites_2.sql:3889)
-- and private.remittance_chain_events (20261118100000_switch_on_prerequisites_2.sql:164) gets its comment corrected
-- (COMMENT ON FUNCTION: its body is unchanged).

------------------------------------------------------------------------------------------
-- The lines that may be a transfer's debit, and the two holds of a chained run's rows
------------------------------------------------------------------------------------------

-- The lines that may still be this transfer's debit up to p_to (as of the statements), as
-- private.transfer_debit_suppression has read them since 6b-2c (its predicate moved here unchanged, so that the holds of
-- a chained run's rows read the same lines): on the transfer's account, booked from its requested execution date to p_to,
-- not booked nor linked — a debit carrying its end-to-end id, naming its PmtInf in its current file with no end-to-end
-- id, carrying neither reference for exactly its amount, or of its amount to its payee's IBAN whatever its references
-- but ours (rule 3b on classes O and E0, never a line naming another transfer or lot of ours); an entry kept unsplit
-- whose stored details name its debit. None when p_to is before its requested execution date. Keyed: the transfer by
-- its key, the account's lines by (account, booking date).
create or replace function private.transfer_debit_lines(p_transfer_id uuid, p_to date)
returns table (line_id uuid, line_date date)
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transfer;
  v_pmt_inf text;
begin
  select * into t from public.bank_transfer q where q.id = p_transfer_id;
  if t.id is null or p_to is null or p_to < t.requested_execution_date then
    return;
  end if;
  select i.pmt_inf_id into v_pmt_inf from public.transfer_file_item i
  where i.file_id = t.transfer_file_id and i.transfer_id = t.id;
  return query
    select x.id, x.booking_date
    from (select x.id, x.direction, x.end_to_end_id, x.payment_info_id, x.amount_minor, x.currency, x.booking_date,
                 x.counterparty_iban, x.unsplit_details
          from public.bank_transaction x
          where x.bank_account_id = t.debtor_bank_account_id
            and x.booking_date between t.requested_execution_date and p_to offset 0) x
    where ((x.direction = 'debit'
            and (x.end_to_end_id = t.end_to_end_id
                 or (x.end_to_end_id is null and x.payment_info_id = v_pmt_inf)
                 or (x.end_to_end_id is null and x.payment_info_id is null and x.amount_minor = t.amount_minor
                     and x.currency = t.currency)
                 -- (review 6b-2c legal-deadlines-1) rule 3b's lines with a reference that is not ours: a debit of its
                 -- amount to its payee's IBAN whatever its foreign end-to-end id or PmtInfId (classes O, E0) — (round
                 -- 3, new:suppression-counts-other-transfer-line) never one naming another transfer or lot of ours
                 -- (class E, B, U), read last and by key — (6b-2d, suppression-e0-names-our-other-lot) nor an E0 line
                 -- whose TF PmtInfId names another lot of ours on the account
                 or (x.amount_minor = t.amount_minor and x.currency = t.currency
                     and x.counterparty_iban = t.payee_iban
                     and private.transfer_line_class(x.id) in ('N', 'O', 'E0')
                     and not (x.payment_info_id is distinct from v_pmt_inf
                              and private.pmt_inf_names_account_lot(t.debtor_bank_account_id, x.payment_info_id)))))
            -- (legal-deadlines-1) an entry kept unsplit whose stored details name this transfer's debit, whatever the
            -- entry's total and direction (netted with a return: the options book its details)
            or x.unsplit_details @> jsonb_build_array(jsonb_build_object('id', t.end_to_end_id, 'direction', 'debit')))
      -- every such line not booked nor linked yet (a line booked or classified is no longer a debit that may be seen)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id offset 0);
end;
$$;

-- private.transfer_debit_suppression, redefined from 20261117113000_transfer_line_pages_fixes.sql (line 175; same
-- signature and settings, its grants restated below). M2c-6b-3b part 1: its lines are read by
-- private.transfer_debit_lines (the same predicate, moved there to be shared with private.remittance_chain_holds), newest
-- first as before. Nothing else changes: 'waiting' when one of them offers the transfer's booking or is younger than
-- private.transfer_debit_bound_days() business days, 'expired' when every one is that old and offers none, null when
-- there is none.
create or replace function private.transfer_debit_suppression(p_transfer_id uuid, p_to date, p_today date)
returns text
language plpgsql
volatile
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_line record;
  v_expired boolean := false;
begin
  for v_line in
    select l.line_id, l.line_date from private.transfer_debit_lines(p_transfer_id, p_to) l
    order by l.line_date desc, l.line_id
  loop
    if private.business_days_between(v_line.line_date, coalesce(p_today, private.paris_today()))
         < private.transfer_debit_bound_days()
       or private.transfer_line_offers(v_line.line_id, p_transfer_id) then
      return 'waiting';
    end if;
    v_expired := true;
  end loop;
  return case when v_expired then 'expired' end;
end;
$$;

-- The facts the two holds of a chained run's rows judge at L, read in one snapshot (M2c-6b-3b part 1 review round 1,
-- chain-holds-snapshot-race; CPCE-08): a STABLE function's queries all read the snapshot of the query that calls it, so
-- an import or a booking another session commits meanwhile is seen by all three or by none —
--   covered: the paying account's statements cover [least(e0, L), L] (private.statement_covers), e0 the earliest
--     execution date of the chain's transfers handed out (an item of a file downloaded at least once);
--   paid_on: the date the chain paid the client and stayed paid (private.remittance_chain_paid, round 4's rule; the line
--     p_line_id, previewed, counted as p_paying's payout);
--   lines: [transfer, line, date] of each line dated by L that may be the debit of another transfer of the chain handed
--     out (not p_paying, the transfer the run is booked by; private.transfer_debit_lines) that the chain's rule does not
--     count yet as one of its executions (private.remittance_chain_events), p_line_id never one; newest first — read only
--     when covered.
-- Keyed: the run's transfer, its chain, each transfer's items and files, its lines and the chain's events by key.
create or replace function private.remittance_chain_hold_facts(p_transfer_id uuid, p_paying uuid, p_latest date,
                                                               p_line_id uuid,
                                                               out covered boolean, out paid_on date, out lines jsonb)
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  with h as materialized (     -- the chain's transfers handed out, each with its earliest execution date
    select c.transfer_id, min(i.execution_date) as e0
    from private.transfer_chain(p_transfer_id) c
    cross join lateral (select q.file_id, q.execution_date from public.transfer_file_item q
                        where q.transfer_id = c.transfer_id offset 0) i
    cross join lateral (select f.download_count from public.transfer_file f where f.id = i.file_id offset 0) f
    where f.download_count > 0
    group by c.transfer_id),
  cv as materialized (
    select coalesce(private.statement_covers((select q.debtor_bank_account_id from public.bank_transfer q
                                              where q.id = p_transfer_id),
                                             least((select min(h.e0) from h), p_latest), p_latest), false) as covered),
  ev as materialized (         -- the executions the chain's rule counts
    select e.transfer_id, e.line_id from private.remittance_chain_events(p_transfer_id) e where e.delta > 0)
  select cv.covered,
         (select x.paid_on from private.remittance_chain_paid(p_transfer_id, p_line_id, p_paying) x),
         case when cv.covered
              then coalesce((select jsonb_agg(jsonb_build_array(h.transfer_id, l.line_id, l.line_date)
                                              order by l.line_date desc, l.line_id, h.transfer_id)
                             from h
                             cross join lateral private.transfer_debit_lines(h.transfer_id, p_latest) l
                             where h.transfer_id is distinct from p_paying and l.line_id is distinct from p_line_id
                               and not exists (select 1 from ev where ev.transfer_id = h.transfer_id
                                                                  and ev.line_id = l.line_id)), '[]')
              else '[]' end
  from cv;
$$;

-- The two holds of the R124-6 rows at L of a run whose payout chain holds another transfer (M2c-6b-3b part 1,
-- booking-rows-skip-chain-coverage-and-waiting-lines; CPCE-08), p_transfer_id the run's transfer:
--   covered: the paying account's statements cover [least(e0, L), L] (private.statement_covers), e0 the earliest
--     execution date of the chain's transfers handed out (an item of a file downloaded at least once) — as the nightly
--     chained branch has read it since 6b-3a-2 (I);
--   waiting: another transfer of the chain handed out (not p_paying, the transfer the run is booked by) has a line that
--     may be its debit by L (private.transfer_debit_lines) that the chain's rule does not count yet as one of its
--     executions (private.remittance_chain_events: a line carrying its id, a detail of an entry kept unsplit, a batch
--     line that certainly holds it, a line booked as its payout or « Virement hors reversement » are counted already,
--     whether or not they are booked) — a line without our references, a batch line other transfers can make, a line
--     held as a suspected duplicate: it may have paid the client by L. With p_decide (the nightly check), as
--     private.transfer_debit_suppression decides it: such a line younger than the bound days or offering that
--     transfer's booking waits, one that offers none past them is expired (the row « bloqué : débit possible non
--     comptabilisé »); without (the booking and its sheet, which cannot build the options' working tables inside their
--     own), any such line waits — the nightly check decides the next night. p_line_id, the line being previewed as the
--     run's payout, is never one (once booked it is none).
-- Review round 1 (chain-holds-snapshot-race; CPCE-08): the three facts are read in one snapshot
-- (private.remittance_chain_hold_facts) together with the chain's paid date, which must be p_paid — the paid date the
-- caller judged the run at, in its own statement's snapshot (null when no copy stayed): an import of an earlier statement
-- or a booking of a line committed since then moves it, and the run waits (the nightly check judges it again on facts
-- read together); and an 'expired' — decided by the options of each old line, asked after that snapshot — stands only if
-- the facts read again afterwards have not moved (a line booked meanwhile no longer offers its booking). A line arriving
-- after the first read is not in it, and is decided the next night.
-- Volatile (the options of an old line, with p_decide). Keyed as its facts.
create or replace function private.remittance_chain_holds(p_transfer_id uuid, p_paying uuid, p_latest date,
                                                          p_today date, p_decide boolean, p_line_id uuid,
                                                          p_paid date,
                                                          out covered boolean, out waiting boolean,
                                                          out expired boolean)
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
  -- one snapshot: the coverage, the chain's paid date and the possible debits its rule does not count yet
  select x.covered, x.paid_on, x.lines into f
  from private.remittance_chain_hold_facts(p_transfer_id, p_paying, p_latest, p_line_id) x;
  covered := coalesce(f.covered, false);
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

-- The R124-6 rows due at p_on for run p_run_id whose payout chain holds another transfer (M2c-6b-3b part 1; CPCE-08):
-- its positive unreleased lines late at p_on (private.remittance_run_late_lines), each held to its latest execution date
-- or, for a delay that cannot be met, to the one-month date of its collection when that date is before p_on (as
-- private.bank_booking_post_rows has recorded them since 6b-2c), whose two holds at that date pass
-- (private.remittance_chain_holds, once per date: the statements cover it, no other transfer of the chain may have paid
-- by it); debit_unbooked when a line that may have been such a transfer's debit offers no booking of it past the bound
-- days (p_decide: the nightly check). p_paid: the chain's paid date the caller read p_on from (review round 1: p_on is
-- p_paid, or the payout line's date when no copy stayed; the holds wait when the chain's paid date has moved since).
-- Read by the booking (p_paying the transfer it books; p_decide false), its sheet's late flag (with the previewed line,
-- p_line_id) and the nightly check's booked branch (p_decide). Volatile (the holds').
create or replace function private.remittance_chain_rows(p_run_id uuid, p_on date, p_paid date, p_paying uuid,
                                                         p_line_id uuid, p_today date, p_decide boolean)
returns table (ledger_entry_id uuid, payment_id uuid, deadline date, latest_execution_date date, kind text,
               debit_unbooked boolean)
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
    select d.latest, x.covered, x.waiting, x.expired
    from (select distinct l.latest from l) d
    cross join (select r.transfer_id from public.remittance_run r where r.id = p_run_id) r
    cross join lateral private.remittance_chain_holds(r.transfer_id, p_paying, d.latest, p_today, p_decide,
                                                      p_line_id, p_paid) x)
  select l.ledger_entry_id, l.payment_id, l.deadline, l.latest, l.kind, h.expired
  from l
  join h on h.latest = l.latest
  where h.covered and not h.waiting;
$$;

-- The facts the nightly check's in-flight branch judges a run's lines held to L by (M2c-6b-3b part 1 review round 1,
-- chain-holds-snapshot-race; CPCE-08), read in one snapshot (a STABLE function's queries all read the snapshot of the
-- query that calls it): whether the run is still in flight (approved or sent), its transfer, and —
--   a run whose transfer re-issues another or is itself cancelled (6b-3a-2 (I)): whether the statements cover
--     [least(e0, L), L] (e0 the earliest execution date of its chain's transfers handed out; L alone when none is),
--     whether the chain paid the client by L and stayed paid (named: private.remittance_chain_paid, round 4), and
--     [transfer, line, date] of each line dated by L that may be the debit of a transfer of its chain handed out
--     (private.transfer_debit_lines: the very lines private.transfer_debit_suppression reads);
--   another run (6b-1, 6b-2c): whether its transfer is handed out and not seen debited (unseen: in a downloaded file,
--     the statements covering L and showing no debit of it) and, then, the lines that may be its debit by L.
-- Lines newest first. Keyed: the run, its transfer and file, its chain, each transfer's items, files and lines by key.
create or replace function private.remittance_inflight_facts(p_run_id uuid, p_latest date)
returns jsonb
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
declare
  r record;
  t record;
  v jsonb;
begin
  select q.status, q.transfer_id into r from public.remittance_run q where q.id = p_run_id;
  select q.id, q.debtor_bank_account_id, q.status, f.download_count,
         q.replaces_transfer_id is not null or q.status = 'cancelled' as chained
  into t
  from (select y.id, y.debtor_bank_account_id, y.status, y.transfer_file_id, y.replaces_transfer_id
        from public.bank_transfer y where y.id = r.transfer_id offset 0) q
  left join lateral (select g.download_count from public.transfer_file g where g.id = q.transfer_file_id offset 0) f
    on true;
  v := jsonb_build_object('live', coalesce(r.status in ('approved', 'sent'), false), 'transfer', t.id,
                          'status', t.status, 'downloads', coalesce(t.download_count, 0), 'chained', t.chained);
  if t.id is null then
    return v;
  end if;
  if t.chained then
    return v || (
      with h as materialized (
        select c.transfer_id, min(i.execution_date) as e0
        from private.transfer_chain(t.id) c
        cross join lateral (select q.file_id, q.execution_date from public.transfer_file_item q
                            where q.transfer_id = c.transfer_id offset 0) i
        cross join lateral (select g.download_count from public.transfer_file g where g.id = i.file_id offset 0) g
        where g.download_count > 0
        group by c.transfer_id)
      select jsonb_build_object(
               'covered', coalesce(private.statement_covers(t.debtor_bank_account_id,
                                                            least((select min(h.e0) from h), p_latest), p_latest),
                                   false),
               'named', coalesce((select c.paid_on <= p_latest from private.remittance_chain_paid(t.id) c), false),
               'lines', coalesce((select jsonb_agg(jsonb_build_array(h.transfer_id, l.line_id, l.line_date)
                                                   order by l.line_date desc, l.line_id, h.transfer_id)
                                  from h cross join lateral private.transfer_debit_lines(h.transfer_id, p_latest) l),
                                 '[]')));
  end if;
  v := v || jsonb_build_object('unseen', coalesce(t.status = 'in_file' and coalesce(t.download_count, 0) > 0
                                                  and private.statement_covers(t.debtor_bank_account_id, p_latest,
                                                                               p_latest)
                                                  and not private.transfer_debit_seen(t.id), false));
  return v || jsonb_build_object('lines', case when (v ->> 'unseen')::boolean
                                               then coalesce((select jsonb_agg(jsonb_build_array(t.id, l.line_id,
                                                                                                 l.line_date)
                                                                               order by l.line_date desc, l.line_id)
                                                              from private.transfer_debit_lines(t.id, p_latest) l),
                                                             '[]')
                                               else '[]' end);
end;
$$;

-- Whether the nightly check's in-flight branch proves a run unpaid at L (its lines held to L get their R124-6 row), and
-- whether only because the lines that could be its debit offered no booking of it for the bound days (« bloqué : débit
-- possible non comptabilisé »): the rule of private.run_remittance_runs_checks' in-flight branch since 6b-2c and 6b-3a-2
-- (I), unchanged —
--   a run whose transfer re-issues another or is itself cancelled: the statements cover [least(e0, L), L], its chain did
--     not pay the client by L and stay paid (round 4), and no line that may be a debit of its chain's transfers handed
--     out by L waits;
--   another run: its transfer never handed out (ordered, or in a file nobody downloaded) — proven at once; else handed
--     out and not seen debited with the statements covering L, and no line that may be its debit by L waits;
-- a line waits while younger than private.transfer_debit_bound_days() business days or while it offers that transfer's
-- booking (Q14's rule, as private.transfer_debit_suppression), and is expired past them offering none.
-- Review round 1 (chain-holds-snapshot-race; CPCE-08): judged on facts read in one snapshot
-- (private.remittance_inflight_facts, the run still in flight) — no longer the nightly statement's snapshot beside the
-- suppression's own later reads, between which ops' booking of the run's on-time debit without our references could
-- land and the row be written for a run paid on time — and a proof that rests on the options asked after that snapshot
-- stands only if the facts read again afterwards have not moved. Volatile (the options).
create or replace function private.remittance_inflight_judge(p_run_id uuid, p_latest date, p_today date,
                                                             out proven boolean, out debit_unbooked boolean)
language plpgsql
volatile
set search_path = ''
set enable_seqscan = off
as $$
declare
  f jsonb;
  v_line record;
  v_any boolean := false;
  v_again jsonb;
begin
  proven := false;
  debit_unbooked := false;
  select private.remittance_inflight_facts(p_run_id, p_latest) into f;
  if not (f ->> 'live')::boolean or f ->> 'transfer' is null then
    return;
  end if;
  if (f ->> 'chained')::boolean then
    if not (f ->> 'covered')::boolean or (f ->> 'named')::boolean then
      return;
    end if;
  elsif f ->> 'status' = 'ordered' or (f ->> 'status' = 'in_file' and (f ->> 'downloads')::integer = 0) then
    -- never handed out to the bank: unpaid whatever the statements
    proven := true;
    return;
  elsif not (f ->> 'unseen')::boolean then
    return;
  end if;
  for v_line in
    select (x.v ->> 0)::uuid as transfer_id, (x.v ->> 1)::uuid as line_id, (x.v ->> 2)::date as line_date
    from jsonb_array_elements(f -> 'lines') with ordinality x (v, o)
    order by x.o
  loop
    if private.business_days_between(v_line.line_date, coalesce(p_today, private.paris_today()))
         < private.transfer_debit_bound_days()
       or private.transfer_line_offers(v_line.line_id, v_line.transfer_id) then
      return;
    end if;
    v_any := true;
  end loop;
  -- a proof resting on the options asked after the facts' snapshot: the facts read again must not have moved
  if v_any then
    select private.remittance_inflight_facts(p_run_id, p_latest) into v_again;
    if v_again is distinct from f then
      return;
    end if;
  end if;
  proven := true;
  debit_unbooked := v_any;
end;
$$;


------------------------------------------------------------------------------------------
-- The readers: the booking, its sheet, the nightly check
------------------------------------------------------------------------------------------

-- private.bank_booking_post_rows, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 2344; same signature
-- and settings, its grants restated below). M2c-6b-3b part 1 (booking-rows-skip-chain-coverage-and-waiting-lines;
-- CPCE-08): the R124-6 rows of a run whose payout chain holds another transfer are written at the booking only once
-- the statements cover [least(e0, L), L] and no other transfer of the chain handed out may have been debited by L
-- without the chain's rule counting it (private.remittance_chain_rows); else the nightly check's booked branch writes
-- them once that holds. Review round 1 (chain-holds-snapshot-race): the chain's paid date read here is passed to the
-- holds, which wait when it moved. Nothing else changes.
create or replace function private.bank_booking_post_rows(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
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

-- private.transfer_line_check, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 801; same signature and
-- settings, its grants restated below). M2c-6b-3b part 1 (CPCE-08): a payout part of a run whose chain holds another
-- transfer is late, and its late date set, by the lines whose rows its booking writes (private.remittance_chain_rows,
-- the previewed line counted as its execution and never as a possible debit of another transfer): the sheet says « le
-- dépassement du délai est enregistré » only when the booking records it. Review round 1 (chain-holds-snapshot-race): the
-- chain's paid date read here is passed to the holds, which wait when it moved. Nothing else changes.
create or replace function private.transfer_line_check(p_line_id uuid, p_locked boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
<<chk>>
declare
  l public.bank_transaction;
  v_kind text;
  v_held boolean;
  v_class text := (select m.v from pg_temp._tl_meta m where m.k = 'class');
  v_returned_id text;
  v_why text;
  v_detail text;
  v_parts_signed bigint;
  v_cands integer;
  v_file uuid;
  v_file_downloads integer;
  v_fee record;
  v_main record;
  r record;
  v_x record;
  v_cap bigint;
  v_queue bigint;
  v_p bigint;
  v_n_el integer;
  v_c uuid;
  v_bk record;
  v_first uuid;
  v_live_id uuid;
  v_live_status text;
  v_live_number text;
  v_own uuid;
  v_iban_clients integer;
  v_y record;          -- M2c-6b-3a-2 (E): a late predecessor's live transfer
  v_lp_entry uuid;     -- (G): its payout booking's entry
  v_lp_n integer;
  v_chained boolean;   -- M2c-6b-3b part 1 review round 1: a payout part's run whose chain holds another transfer
  v_chain_paid date;   -- … the date its chain paid the client and stayed paid, this line its execution
begin
  -- (the working tables every branch's statements name exist, so each statement plans whatever the class)
  create temp table if not exists _tl_locked_runs (run_id uuid primary key) on commit drop;
  drop table if exists pg_temp._tl_u;
  create temp table _tl_u (k integer, id text, dir text, amount bigint, transfer_id uuid, tr_kind text,
                           tr_status text, tr_debtor uuid, part_kind text, returns_line_id uuid, tr_run uuid)
    on commit drop;
  select * into l from public.bank_transaction where id = p_line_id;
  select coalesce(d.released_kind, l.kind), (l.kind = 'suspected_duplicate' and d.decision is distinct from 'released')
  into v_kind, v_held
  from (select 1) z left join public.bank_duplicate_resolution d on d.bank_transaction_id = l.id;
  v_returned_id := coalesce(l.original_end_to_end_id, l.end_to_end_id);

  drop table if exists pg_temp._tl;
  create temp table _tl on commit drop as
  select q.n, q.kind, q.transfer_id, q.client_id, q.returns_line_id, q.amount,
         x.kind as tr_kind, x.status as tr_status, x.end_to_end_id as tr_e2e, x.debtor_bank_account_id as tr_debtor,
         x.creditor_bank_account_id as tr_creditor, x.currency as tr_currency, x.amount_minor as tr_minor,
         x.transfer_file_id as tr_file, x.run_id as tr_run, x.client_organization_id as tr_client,
         x.entry_id as tr_entry, x.return_entry_id as tr_return_entry, x.payee_iban as tr_iban,
         ru.status as run_status, ru.transfer_id as run_transfer, ru.number as run_number,
         ru.payout_account_id as run_payout_account,
         null::uuid as c, 0::bigint as a, 0::bigint as p, 0::bigint as adv, null::text as p_bound, false as late,
         null::date as late_date,
         null::uuid as own_bank, null::uuid as ub_entry, null::uuid as ub_adv_entry, null::uuid as ub_adv_id,
         0::bigint as ub_adv, null::uuid as payout_account, null::uuid as entry_id, null::uuid as adv_id,
         null::uuid as adv_entry_id, null::uuid as rev_entry_id, null::uuid as rev_adv_entry_id,
         -- M2c-6b-3a-2 (E): a late predecessor part — its run's live transfer y, y's status, the transfer the booking
         -- cancels (y, ordered or in a file not downloaded yet) and the file it withdraws (y's, not downloaded yet)
         false as lp, null::uuid as lp_y, null::text as lp_status, null::uuid as lp_cancel, null::text as lp_cancel_e2e,
         null::uuid as lp_file, null::text as lp_file_number,
         -- review round 2 (ld2-reissue-return-pays-twice): the other transfer of the run's chain the part concerns —
         -- the unplanned payout a return of the run's payout closes, or the transfer whose return is the run's payout's
         null::text as other_e2e
  from pg_temp._tl_req q
  left join lateral (select y.* from public.bank_transfer y where y.id = q.transfer_id offset 0) x on true
  left join lateral (select y.status, y.transfer_id, y.number, y.payout_account_id from public.remittance_run y
                     where y.id = x.run_id offset 0) ru on true;
  drop table if exists pg_temp._tl_items;
  create temp table _tl_items (n integer not null, ledger_entry_id uuid not null, amount_minor bigint not null,
                               primary key (n, ledger_entry_id)) on commit drop;
  drop table if exists pg_temp._tl_drafts;
  create temp table _tl_drafts (run_id uuid primary key, number text not null, client_organization_id uuid not null)
    on commit drop;
  drop table if exists pg_temp._tl_pool;
  create temp table _tl_pool (n integer not null, ledger_entry_id uuid not null, primary key (n, ledger_entry_id))
    on commit drop;

  <<rules>>
  begin
    -- §3.4.2 the line's state
    if v_held then v_why := 'held_duplicate'; exit rules; end if;
    if exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = l.id)
       or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = l.id) then
      v_why := 'already_booked'; exit rules;
    end if;
    if exists (select 1 from public.bank_debit_link k where k.bank_transaction_id = l.id) then
      v_why := 'already_linked'; exit rules;
    end if;
    if exists (select 1 from public.payment p where p.bank_transaction_id = l.id) then
      v_why := 'line_is_payment'; exit rules;
    end if;
    -- (critic F16) the kinds a part may sit on, as the job reads them (class U: per stored detail, below). Review LT-6:
    -- the line's direction first — a debit part on a credit line (our payout's flagged return among them) or a return
    -- part on a debit line is wrong_direction — then its kind (a refund, a direct debit, a payment's return: not a
    -- transfer line; a credit that is not coming back: not a return)
    if v_class = 'U' then
      if v_kind not in ('transfer_out', 'other_debit', 'batch_unsplit', 'return', 'own_transfer_in',
                        'client_transfer_in') then
        v_why := case when l.direction = 'debit' then 'not_a_transfer_line' else 'not_a_return' end; exit rules;
      end if;
    else
      if exists (select 1 from pg_temp._tl t
                 where (t.kind in ('payout', 'sweep', 'unplanned_payout', 'unplanned_sweep') and l.direction <> 'debit')
                    or (t.kind in ('payout_returned', 'sweep_returned', 'unplanned_payout_returned',
                                   'unplanned_sweep_returned') and l.direction <> 'credit')) then
        v_why := 'wrong_direction'; exit rules;
      end if;
      if exists (select 1 from pg_temp._tl t
                 where t.kind in ('payout', 'sweep', 'unplanned_payout', 'unplanned_sweep')
                   and v_kind not in ('transfer_out', 'other_debit', 'batch_unsplit')) then
        v_why := 'not_a_transfer_line'; exit rules;
      end if;
      if exists (select 1 from pg_temp._tl t
                 where t.kind in ('payout_returned', 'sweep_returned', 'unplanned_payout_returned',
                                  'unplanned_sweep_returned')
                   and v_kind not in ('return', 'own_transfer_in', 'client_transfer_in')) then
        v_why := 'not_a_return'; exit rules;
      end if;
    end if;
    -- (review money-1) an entry the bank kept unsplit holding no detail of ours (unsplit_ours 0, its details or NbOfTxs
    -- counted) carries the entry's total, not one movement: never booked as one — rule 3b's one candidate, a client's
    -- or our own IBAN's part, the return of an unplanned payout — as the job never books such a line (batch_partial,
    -- return_differs). Only our lot (class B, its count checked against its only subset below) and an entry holding
    -- ours (class U, from its stored details) are booked from it
    if l.unsplit_ours is not null and v_class not in ('U', 'B') then
      v_why := 'unsplit_not_bookable'; exit rules;
    end if;
    -- a lot holding a refund, or of two kinds (S11: left)
    if v_class = 'B' and l.direction = 'debit'
       and exists (select 1 from pg_temp._tl_pre p where p.role = 'member'
                   having bool_or(p.kind = 'refund') or count(distinct p.kind) > 1) then
      v_why := 'batch_mixed'; exit rules;
    end if;

    -- §3.4.12 an entry kept unsplit: its parts are the statement's own details, never ops' (critic F8, F7, L11)
    if v_class = 'U' then
      if l.unsplit_details is null
         or exists (select 1 from jsonb_array_elements(l.unsplit_details) d where d ->> 'amount_minor' is null) then
        v_why := 'unsplit_detail_missing'; exit rules;
      end if;
      -- (critic2 ML-5) every detail of the entry ours, and NbOfTxs, when given, the count
      if l.unsplit_detail_count is distinct from l.unsplit_ours::integer
         or (l.unsplit_batch_count is not null and l.unsplit_batch_count <> l.unsplit_detail_count) then
        v_why := 'unsplit_not_bookable'; exit rules;
      end if;
      insert into pg_temp._tl_u (k, id, dir, amount, transfer_id, tr_kind, tr_status, tr_debtor, tr_run)
      select d.o::integer, d.v ->> 'id', d.v ->> 'direction', (d.v ->> 'amount_minor')::bigint,
             x.id, x.kind, x.status, x.debtor_bank_account_id, x.run_id
      from jsonb_array_elements(l.unsplit_details) with ordinality d (v, o)
      -- (critic2 CSO2-10) by (the line's servicer, the id), then its account: never another servicer's transfer (CI
      -- scale fix: the probe holds the id alone, the servicer compared outside it)
      left join lateral (select y.id, y.kind, y.status, y.debtor_bank_account_id, y.run_id
                         from (select q.id, q.kind, q.status, q.debtor_bank_account_id, q.organization_id, q.run_id
                               from public.bank_transfer q where q.end_to_end_id = d.v ->> 'id' offset 0) y
                         where y.organization_id = l.organization_id) x
        on true;
      if exists (select 1 from pg_temp._tl_u u
                 where u.id !~ '^(RMT|SWP)' or u.transfer_id is null or u.tr_debtor <> l.bank_account_id
                    or u.tr_kind not in ('payout', 'sweep'))
         or (select count(distinct u.id) <> count(*) from pg_temp._tl_u u) then
        v_why := 'unsplit_not_bookable'; exit rules;
      end if;
      -- M2c-6b-3a-2 review round 1 (CSC-2): two debits of one run's payout chain in one entry (a payout and the transfer
      -- it re-issues, or two of its re-issues, the bank executing both) are never two payouts of that run — one run
      -- settled twice — nor its payout and a « Virement hors reversement » derived from the details alone: not bookable
      -- here (ops ask the bank for the detail, the support books it)
      if exists (select 1 from pg_temp._tl_u u
                 where u.dir = 'debit' and u.tr_kind = 'payout' and u.tr_run is not null
                 group by u.tr_run having count(*) > 1) then
        v_why := 'unsplit_not_bookable'; exit rules;
      end if;
      -- the kind each detail gives: a debit, the planned debit of a live transfer or the unplanned one of a cancelled,
      -- booked or returned one; a credit, the planned return, or the unplanned booking's return while one is open
      update pg_temp._tl_u u set part_kind = case
          -- M2c-6b-3a-2 review round 1 (DP-2, CSC-2): a late predecessor's debit is its run's payout, as the options
          -- propose it (private.transfer_line_options_of); the late predecessor's rules below then decide
          when u.dir = 'debit' and u.tr_status = 'cancelled' and u.tr_kind = 'payout'
               and private.transfer_late_predecessor(u.transfer_id) then u.tr_kind
          when u.dir = 'debit' and u.tr_status in ('cancelled', 'booked', 'returned') then 'unplanned_' || u.tr_kind
          when u.dir = 'debit' then u.tr_kind
          when private.transfer_unplanned_open(u.transfer_id) then 'unplanned_' || u.tr_kind || '_returned'
          else u.tr_kind || '_returned' end
      where true;  -- every row (an API session refuses an UPDATE without WHERE: pg-safeupdate)
      update pg_temp._tl_u u set returns_line_id = (
          select o.line_id from private.transfer_line_open_unplanned(l.organization_id, u.transfer_id, null, null,
                                                                     'unplanned_' || u.tr_kind) o limit 1)
      where u.part_kind like 'unplanned_%_returned';
      if (select count(*) from pg_temp._tl t where t.kind <> 'fee') <> (select count(*) from pg_temp._tl_u)
         or exists (select 1 from pg_temp._tl_u u
                    where not exists (select 1 from pg_temp._tl t
                                      where t.kind = u.part_kind and t.transfer_id = u.transfer_id
                                        and t.amount = u.amount
                                        and t.returns_line_id is not distinct from u.returns_line_id)) then
        v_why := 'unsplit_parts_differ'; exit rules;
      end if;
    end if;

    -- §3.5 a lot: its parts among its members (debit) or returnable members (credit)
    if v_class = 'B' then
      v_file := (select i.file_id
                 from (select y.file_id from public.transfer_file_item y where y.pmt_inf_id = l.payment_info_id offset 0) i
                 cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                     where f.id = i.file_id offset 0) f
                 where f.debtor_bank_account_id = l.bank_account_id limit 1);
      select f.download_count into v_file_downloads from public.transfer_file f where f.id = v_file;
      if l.direction = 'debit' and coalesce(v_file_downloads, 0) = 0 then
        v_why := 'not_handed_out'; exit rules;
      end if;
      if exists (select 1 from pg_temp._tl t
                 where t.kind <> 'fee'
                   and not exists (select 1 from pg_temp._tl_pre p
                                   where p.role in ('member', 'returnable') and p.transfer_id = t.transfer_id)) then
        v_why := 'not_its_line'; exit rules;
      end if;
      -- (lot credit) its universe depends on statuses: read again under the locks, it must be the one the subset
      -- was computed on
      if p_locked and l.direction = 'credit'
         and (select coalesce(array_agg(m.transfer_id || ':' || m.amount_minor || ':' || m.unplanned_open
                                        order by m.seq), '{}')
              from private.transfer_line_returnable(l.id) m)
             is distinct from
             (select coalesce(array_agg(p.transfer_id || ':' || p.amount_minor || ':' || p.unplanned_open
                                        order by p.ord), '{}')
              from pg_temp._tl_pre p where p.role = 'returnable') then
        v_why := 'split_changed'; exit rules;
      end if;
    end if;

    -- §3.4.2 the signed sum: debit parts and a fee −, return parts +, against the signed line
    select coalesce(sum(case when t.kind in ('payout_returned', 'sweep_returned', 'unplanned_payout_returned',
                                             'unplanned_sweep_returned') then t.amount else -t.amount end), 0)
    into v_parts_signed from pg_temp._tl t;
    if v_parts_signed <> (case l.direction when 'credit' then l.amount_minor else -l.amount_minor end) then
      v_why := 'parts_do_not_add_up'; exit rules;
    end if;

    -- §3.4.10 a fee only on our transfer's own line (critic L2, F7; critic2 ML-6, ML-10, CSO2-1)
    select t.* into v_fee from pg_temp._tl t where t.kind = 'fee';
    if found then
      if v_class = 'E' and l.direction = 'debit' then
        select t.* into v_main from pg_temp._tl t
        where t.kind in ('payout', 'sweep', 'unplanned_payout', 'unplanned_sweep') and t.tr_e2e = l.end_to_end_id;
        if not found or l.amount_minor <= v_main.tr_minor then
          v_why := 'fee_not_allowed'; exit rules;
        end if;
      elsif v_class = 'E' and l.direction = 'credit' and v_kind = 'return' then
        select t.* into v_main from pg_temp._tl t
        where t.kind in ('payout_returned', 'sweep_returned', 'unplanned_payout_returned', 'unplanned_sweep_returned')
          and t.tr_e2e = v_returned_id;
        if not found or l.amount_minor >= v_main.amount then
          v_why := 'fee_not_allowed'; exit rules;
        end if;
      elsif v_class = 'U' and l.direction = 'debit' and l.unsplit_ours = 1 and l.unsplit_detail_count = 1
            and coalesce(l.unsplit_batch_count, 1) = 1
            and (select u.dir from pg_temp._tl_u u) = 'debit' then
        -- (c) the ISO shape of S08: one detail in all, ours, at N; the entry N + F, F the statement's own charge
        if l.charges_minor is null then
          v_why := 'unsplit_detail_missing'; exit rules;
        end if;
        if l.charges_minor <> v_fee.amount then
          v_why := 'amount_differs'; exit rules;
        end if;
      else
        v_why := 'fee_not_allowed'; exit rules;
      end if;
      if v_class = 'E' then
        -- (review LT-3) a charges block the import saw and could not read (camt.053.001.02's `Chrgs`, a record not the
        -- bank's debit in the account's currency): the statement records a charge Collectoo cannot read — never booked as
        -- a line that records none (COMPLIANCE OQ-84 (j))
        if l.charges_read is false then
          v_why := 'unsplit_detail_missing'; exit rules;
        end if;
        -- (critic2 ML-10) the statement's charge when it records one; with none, never the amount of one of our
        -- transfers put in a file on this account (the line's own included: a double debit in one entry)
        if l.charges_minor is not null and l.charges_minor <> v_fee.amount then
          v_why := 'amount_differs'; exit rules;
        end if;
        if l.charges_minor is null
           and exists (select 1 from public.bank_transfer y
                       where y.debtor_bank_account_id = l.bank_account_id and y.amount_minor = v_fee.amount
                         and y.transfer_file_id is not null) then
          v_why := 'fee_unexplained'; exit rules;
        end if;
      end if;
    end if;

    -- §3.5 the only subset of the lot making the line (critic CSO-3: computed before the locks)
    if v_class = 'B' then
      if (select m.v from pg_temp._tl_meta m where m.k = 'subset') is distinct from 'one'
         or exists (select 1 from pg_temp._tl_pre p
                    where p.role in ('member', 'returnable') and p.in_subset
                      and not exists (select 1 from pg_temp._tl t where t.transfer_id = p.transfer_id)) then
        v_why := 'batch_ambiguous'; exit rules;
      end if;
      -- (review money-1) our lot kept unsplit by the bank: the count of its transactions the statement gives — NbOfTxs,
      -- or its details (none of them ours) — is the only subset's, else the entry holds a movement that is not ours
      if l.unsplit_ours is not null
         and ((l.unsplit_batch_count is not null
               and l.unsplit_batch_count <> (select count(*) from pg_temp._tl_pre p
                                             where p.role in ('member', 'returnable') and p.in_subset))
              or (coalesce(l.unsplit_detail_count, 0) > 0
                  and l.unsplit_detail_count <> (select count(*) from pg_temp._tl_pre p
                                                 where p.role in ('member', 'returnable') and p.in_subset))) then
        v_why := 'unsplit_not_bookable'; exit rules;
      end if;
    end if;

    -- rule 3b's candidates (classes N, O, E0): read again under the locks, never one the locks did not take
    if v_class in ('N', 'O', 'E0') and l.direction = 'debit' then
      if p_locked and exists (select 1 from private.transfer_line_candidates(l.id, v_class) c
                              where not exists (select 1 from pg_temp._tl_pre p
                                                where p.role = 'candidate' and p.transfer_id = c.transfer_id)) then
        v_why := 'split_changed'; exit rules;
      end if;
      select count(*) into v_cands from pg_temp._tl_pre p where p.role = 'candidate';
      if v_cands > 1 then
        v_why := 'line_ambiguous'; exit rules;
      end if;
    end if;

    -- the items an unplanned payout of a cancelled or returned transfer was meant to pay (§3.6.1): a cancelled
    -- transfer's run's released lines, a returned one's return item (by key)
    -- M2c-6b-3a-2 review round 1 (DP-3): and the return items of its run's payout chain — the payout_returned bookings'
    -- entries of every transfer of the chain of its run's transfer (a late predecessor booked as the run's payout, then
    -- returned, keeps no return entry of its own; a re-issue booked then returned): this debit paid the client that
    -- money again, which the client's next run would otherwise pay a second time (by key: the chain, each one's
    -- bookings)
    insert into pg_temp._tl_pool (n, ledger_entry_id)
    select distinct t.n, y.ledger_entry_id
    from pg_temp._tl t
    cross join lateral (select q.ledger_entry_id, q.released from public.remittance_line q
                        where q.run_id = t.tr_run offset 0) y
    where t.kind = 'unplanned_payout' and t.tr_status = 'cancelled' and t.tr_run is not null and y.released
    union
    select t.n, t.tr_return_entry from pg_temp._tl t
    where t.kind = 'unplanned_payout' and t.tr_status = 'returned' and t.tr_return_entry is not null
    union
    select t.n, k.entry_id
    from pg_temp._tl t
    cross join lateral private.transfer_chain(t.run_transfer) h
    cross join lateral (select q.entry_id, q.kind from public.bank_line_booking q
                        where q.transfer_id = h.transfer_id offset 0) k
    where t.kind = 'unplanned_payout' and t.tr_kind = 'payout' and t.tr_status in ('cancelled', 'returned')
      and t.run_transfer is not null and k.kind = 'payout_returned';

    -- each part's own rules (§3.4.3–§3.4.13), in its order
    for r in select * from pg_temp._tl t order by t.n loop
      if r.kind in ('payout', 'sweep') then
        -- (review LT-6) a transfer of this servicer of another kind (a sweep part naming one of our payouts)
        if r.tr_kind is distinct from r.kind then v_why := 'transfer_kind_differs'; exit rules; end if;
        if v_class <> 'U' and l.direction <> 'debit' then v_why := 'wrong_direction'; exit rules; end if;
        if not (case v_class
                 when 'E' then l.end_to_end_id = r.tr_e2e
                 when 'B' then exists (select 1 from pg_temp._tl_pre p where p.role = 'member'
                                         and p.transfer_id = r.transfer_id) and r.tr_file = v_file
                 when 'U' then true
                 else v_cands = 1 and exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate'
                                                and p.transfer_id = r.transfer_id) end) then
          v_why := 'not_its_line'; exit rules;
        end if;
        -- M2c-6b-3a-2 (E): a payout cancelled out of a downloaded file whose run is still approved or sent, in the
        -- chain of that run's transfer (private.transfer_late_predecessor), executed late: that run's payout (the late
        -- predecessor). The run's live transfer y — read here, under the locks for the command (private.
        -- transfer_line_locks re-reads it after the remit lock and locks it) — decides: nothing to cancel (y is x, or y
        -- cancelled already); y cancelled (ordered) or withdrawn with its file (in a file not downloaded yet:
        -- superseded, private.transfer_line_post); refused reissue_in_downloaded_file while y's file is downloaded or
        -- sent (the bank may still execute it: ops have that file cancelled on the evidence first, OQ-80 (n)); already
        -- debited once a transfer of the chain is
        if r.tr_status = 'cancelled' and r.kind = 'payout' and private.transfer_late_predecessor(r.transfer_id) then
          if exists (select 1
                     from private.transfer_chain(r.run_transfer) h
                     cross join lateral (select k.kind from public.bank_line_booking k
                                         where k.transfer_id = h.transfer_id offset 0) k
                     where k.kind = 'payout') then
            v_why := 'already_debited'; exit rules;
          end if;
          if r.tr_debtor <> l.bank_account_id or r.tr_currency <> l.currency then
            v_why := 'transfer_differs'; exit rules;
          end if;
          select y.id, y.status, y.end_to_end_id, y.transfer_file_id, f.status as file_status, f.download_count,
                 f.number
          into v_y
          from (select q.id, q.status, q.end_to_end_id, q.transfer_file_id from public.bank_transfer q
                where q.id = r.run_transfer offset 0) y
          left join lateral (select g.status, g.download_count, g.number from public.transfer_file g
                             where g.id = y.transfer_file_id offset 0) f on true;
          if v_y.status in ('booked', 'returned') then v_why := 'already_debited'; exit rules; end if;
          if v_y.status = 'in_file' and (coalesce(v_y.download_count, 0) > 0
                                         or v_y.file_status not in ('pending', 'generated')) then
            v_why := 'reissue_in_downloaded_file'; v_detail := v_y.number; exit rules;
          end if;
          update pg_temp._tl t set lp = true, lp_y = v_y.id, lp_status = v_y.status,
            lp_cancel = case when v_y.id <> r.transfer_id and v_y.status in ('ordered', 'in_file') then v_y.id end,
            lp_cancel_e2e = case when v_y.id <> r.transfer_id and v_y.status in ('ordered', 'in_file')
                                 then v_y.end_to_end_id end,
            lp_file = case when v_y.status = 'in_file' then v_y.transfer_file_id end,
            lp_file_number = case when v_y.status = 'in_file' then v_y.number end
          where t.n = r.n;
        else
          if r.tr_status = 'cancelled' then v_why := 'transfer_cancelled'; exit rules; end if;
          if r.tr_status in ('booked', 'returned')
             or exists (select 1 from public.bank_line_booking k where k.transfer_id = r.transfer_id
                          and k.kind in ('payout', 'sweep')) then
            v_why := 'already_debited'; exit rules;
          end if;
          if r.tr_status <> 'in_file'
             or not exists (select 1 from public.transfer_file f where f.id = r.tr_file and f.download_count > 0
                              and f.status in ('downloaded', 'sent')) then
            v_why := 'not_handed_out'; exit rules;
          end if;
          if r.tr_debtor <> l.bank_account_id or r.tr_currency <> l.currency then
            v_why := 'transfer_differs'; exit rules;
          end if;
          if r.kind = 'payout' and (r.run_status is null or r.run_status not in ('approved', 'sent')
                                    or r.run_transfer is distinct from r.transfer_id) then
            v_why := 'run_not_in_flight'; exit rules;
          end if;
        end if;
        if r.amount <> r.tr_minor then v_why := 'amount_differs'; exit rules; end if;
        -- (review 6b-2c money-3, legal-deadlines-2) late, and the date its breach is recorded against, as
        -- private.bank_booking_post_rows records the row: the run's lines late at the line's date by their own date, a
        -- line whose delay cannot be met by its one-month date (private.remittance_run_late_on: the run's lines by its
        -- key, as the CI scale fix reads them)
        -- M2c-6b-3a-2 review round 1 (LD-2): judged at the earliest debit naming another transfer of the run's chain by
        -- our references, when earlier than this line (a late predecessor's own debit paid the client then), as
        -- private.bank_booking_post_rows records the row. Review round 4 (CPCE-08): for a run whose chain holds another
        -- transfer, at the date its chain paid the client and stayed paid with this line booked as this part's payout
        -- (private.remittance_chain_paid: every execution and return of the chain, each counted for the transfer it
        -- names), this line's date when none stayed paid; a run with no other transfer, at this line's date as before
        -- M2c-6b-3b part 1 review round 1 (chain-holds-snapshot-race): the chain's paid date read here (null when no
        -- copy stayed) is passed to the holds, which read it again with the coverage and the possible debits and wait
        -- when it moved
        v_chained := r.kind = 'payout'
                     and exists (select 1 from private.transfer_chain(r.run_transfer) h
                                 where h.transfer_id <> r.transfer_id);
        v_chain_paid := case when v_chained
                             then (select p.paid_on
                                   from private.remittance_chain_paid(r.run_transfer, l.id, r.transfer_id) p) end;
        update pg_temp._tl t set c = r.tr_client, a = r.amount,
          -- M2c-6b-3b part 1 (CPCE-08): for a run whose chain holds another transfer, only the lines whose rows the
          -- booking writes (private.remittance_chain_rows: the statements cover L, no other transfer of the chain may
          -- have paid by L uncounted; this line, previewed, none of them) — the sheet says late only then
          late_date = case when r.kind = 'payout' then
            case when v_chained
                 then (select min(x.latest_execution_date)
                       from private.remittance_chain_rows(r.tr_run, coalesce(v_chain_paid, l.booking_date), v_chain_paid,
                                                          r.transfer_id, l.id, null, false) x)
                 else private.remittance_run_late_on(r.tr_run, l.booking_date) end end
        where t.n = r.n;
        update pg_temp._tl t set late = t.late_date is not null where t.n = r.n;

      elsif r.kind in ('unplanned_payout', 'unplanned_sweep') and r.transfer_id is not null then
        if r.tr_kind is distinct from (case r.kind when 'unplanned_payout' then 'payout' else 'sweep' end) then
          v_why := 'transfer_kind_differs'; exit rules;
        end if;
        if v_class <> 'U' and l.direction <> 'debit' then v_why := 'wrong_direction'; exit rules; end if;
        if not (case v_class
                 when 'E' then l.end_to_end_id = r.tr_e2e
                 when 'B' then exists (select 1 from pg_temp._tl_pre p where p.role = 'member'
                                         and p.transfer_id = r.transfer_id)
                 when 'U' then true
                 else v_cands = 1 and exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate'
                                                and p.transfer_id = r.transfer_id) end) then
          v_why := 'not_its_line'; exit rules;
        end if;
        if r.tr_status not in ('cancelled', 'booked', 'returned') then
          v_why := 'not_cancelled_nor_booked'; exit rules;
        end if;
        -- (critic2 ML-4) a cancelled payout whose run is still approved or sent: this debit is that run's payout
        if r.kind = 'unplanned_payout' and r.tr_status = 'cancelled' and r.run_status in ('approved', 'sent') then
          v_why := 'run_still_live'; v_detail := r.run_number; exit rules;
        end if;
        if r.tr_debtor <> l.bank_account_id or r.tr_currency <> l.currency then
          v_why := 'transfer_differs'; exit rules;
        end if;
        if r.amount <> r.tr_minor then v_why := 'amount_differs'; exit rules; end if;
        if r.kind = 'unplanned_payout' then
          -- (critic F6) what this payout paid sits in a run of the client approved but not handed out yet: that run
          -- is cancelled first, so that its items come back to the queue and this debit is netted against them
          select rr.number into v_detail
          from pg_temp._tl_pool p
          cross join lateral (select q.run_id from public.remittance_line q
                              where q.ledger_entry_id = p.ledger_entry_id and not q.released offset 0) q
          cross join lateral (select y.status, y.number, y.transfer_id, y.client_organization_id
                              from public.remittance_run y where y.id = q.run_id offset 0) rr
          left join lateral (select y.status, y.transfer_file_id from public.bank_transfer y
                             where y.id = rr.transfer_id offset 0) bt on true
          left join lateral (select y.download_count from public.transfer_file y where y.id = bt.transfer_file_id
                             offset 0) f on true
          where p.n = r.n and rr.status in ('approved', 'sent') and rr.client_organization_id = r.tr_client
            and (bt.status is null or bt.status = 'ordered' or (bt.status = 'in_file' and coalesce(f.download_count, 0) = 0))
          order by rr.number limit 1;
          if v_detail is not null then v_why := 'client_run_cancellable'; exit rules; end if;
          update pg_temp._tl t set c = r.tr_client, a = r.amount where t.n = r.n;
        else
          update pg_temp._tl t set a = r.amount, own_bank = r.tr_creditor where t.n = r.n;
        end if;

      elsif r.kind = 'unplanned_payout' then
        -- §3.4.6 to a client's registered payout IBAN, matching nothing of ours (S13, S07)
        if v_class not in ('N', 'O', 'E0') or l.direction <> 'debit' then v_why := 'not_its_line'; exit rules; end if;
        if not exists (select 1 from public.client_payout_account a
                       where a.client_organization_id = r.client_id and a.iban = l.counterparty_iban
                         and a.currency = l.currency and a.confirmed_at is not null
                         and a.status in ('active', 'returned', 'retired')) then
          v_why := 'client_iban_mismatch'; exit rules;
        end if;
        -- (critic CSO-5) the same IBAN registered for another client of this servicer
        select count(distinct a.client_organization_id) into v_iban_clients
        from public.client_payout_account a
        where a.iban = l.counterparty_iban and a.organization_id = l.organization_id;
        if v_iban_clients > 1 then v_why := 'client_ambiguous'; exit rules; end if;
        -- (critic F13, F12, L12) on every class: never while a transfer of ours may be this debit
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate' and p.cand in ('i', 'ii')) then
          v_why := 'payout_in_flight_matches'; exit rules;
        end if;
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate' and p.cand = 'iii') then
          v_why := 'cancelled_payout_matches'; exit rules;
        end if;
        -- M2c-6b-3a (K): a refund or a sweep cancelled out of a downloaded file may be this debit
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate' and p.cand = 'iv') then
          v_why := 'cancelled_transfer_matches'; exit rules;
        end if;
        if exists (select 1 from public.bank_transfer y
                   left join public.transfer_file f on f.id = y.transfer_file_id
                   where y.debtor_bank_account_id = l.bank_account_id and y.status in ('ordered', 'in_file')
                     and y.kind = 'payout' and y.client_organization_id = r.client_id
                     and y.amount_minor = l.amount_minor and y.payee_iban = l.counterparty_iban
                     and (y.status = 'ordered' or coalesce(f.download_count, 0) = 0)) then
          v_why := 'payout_not_handed_out_matches'; exit rules;
        end if;
        if r.amount <> l.amount_minor then v_why := 'amount_differs'; exit rules; end if;
        update pg_temp._tl t set c = r.client_id, a = r.amount, p = 0, adv = r.amount, p_bound = 'none'
        where t.n = r.n;

      elsif r.kind = 'unplanned_sweep' then
        -- §3.4.8 to our own IBAN, without an order of ours (S14, S07)
        if v_class not in ('N', 'O', 'E0') or l.direction <> 'debit' then v_why := 'not_its_line'; exit rules; end if;
        select o.id into v_own from public.bank_account o
        where o.organization_id = l.organization_id and o.purpose = 'own' and o.status = 'active'
          and o.iban = l.counterparty_iban and o.currency = l.currency;
        if v_own is null then v_why := 'own_account_unknown'; exit rules; end if;
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate' and p.kind = 'sweep') then
          v_why := 'sweep_in_flight_matches'; exit rules;
        end if;
        -- M2c-6b-3a (K): a refund cancelled out of a downloaded file may be this debit
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate' and p.cand = 'iv') then
          v_why := 'cancelled_transfer_matches'; exit rules;
        end if;
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate') then
          v_why := 'payout_in_flight_matches'; exit rules;
        end if;
        if r.amount <> l.amount_minor then v_why := 'amount_differs'; exit rules; end if;
        update pg_temp._tl t set a = r.amount, own_bank = v_own where t.n = r.n;

      elsif r.kind in ('payout_returned', 'sweep_returned') then
        if r.tr_kind is distinct from (case r.kind when 'payout_returned' then 'payout' else 'sweep' end) then
          v_why := 'transfer_kind_differs'; exit rules;
        end if;
        if v_class <> 'U' and l.direction <> 'credit' then v_why := 'wrong_direction'; exit rules; end if;
        if not (case v_class
                 when 'E' then v_returned_id = r.tr_e2e
                               -- review round 2 (ld2-reissue-return-pays-twice): the line returns another transfer of
                               -- the run's chain whose unplanned payout a return of this payout closed — both copies came
                               -- back, this one is the run's payout's (private.transfer_return_partner)
                               or (r.kind = 'payout_returned'
                                   and private.transfer_return_partner(
                                         (select y.id from (select q.id, q.organization_id from public.bank_transfer q
                                                            where q.end_to_end_id = v_returned_id offset 0) y
                                          where y.organization_id = l.organization_id))
                                       is not distinct from r.transfer_id)
                 when 'B' then exists (select 1 from pg_temp._tl_pre p where p.role = 'returnable'
                                         and p.transfer_id = r.transfer_id)
                 when 'U' then true
                 else false end) then
          v_why := 'not_its_line'; exit rules;
        end if;
        if v_class = 'E' and v_returned_id is distinct from r.tr_e2e then
          update pg_temp._tl t set other_e2e = v_returned_id where t.n = r.n;
        end if;
        if r.tr_status in ('ordered', 'in_file') then v_why := 'return_before_debit'; exit rules; end if;
        -- (critic F1) the copy that comes back is the unplanned booking's: booked as this one, it would pay again
        if private.transfer_unplanned_open(r.transfer_id) then v_why := 'unplanned_open'; exit rules; end if;
        -- (critic2 ML-3) a second or late debit of it waits on a statement: booked first
        select x into v_detail from private.transfer_late_lines(r.transfer_id) x limit 1;
        if v_detail is not null then v_why := 'debit_pending'; exit rules; end if;
        if r.tr_status = 'returned'
           or exists (select 1 from public.bank_line_booking k where k.transfer_id = r.transfer_id
                        and k.kind in ('payout_returned', 'sweep_returned')) then
          v_why := 'already_returned'; exit rules;
        end if;
        -- M2c-6b-3a-2 (G): a late predecessor booked as its run's payout — a payout cancelled with exactly one payout
        -- booking and no return booked (above) — comes back as that booking's entry reversed (it has no entry of its own)
        if r.tr_status = 'cancelled' and r.tr_kind = 'payout' then
          select count(*), min(k.entry_id::text)::uuid into v_lp_n, v_lp_entry
          from public.bank_line_booking k where k.transfer_id = r.transfer_id and k.kind = 'payout';
          if v_lp_n <> 1 then v_why := 'transfer_cancelled'; exit rules; end if;
          r.tr_entry := v_lp_entry;
          update pg_temp._tl t set tr_entry = v_lp_entry where t.n = r.n;
        elsif r.tr_status = 'cancelled' then
          v_why := 'transfer_cancelled'; exit rules;
        elsif r.tr_status <> 'booked' or r.tr_entry is null
           or not exists (select 1 from public.bank_line_booking k where k.transfer_id = r.transfer_id
                            and k.kind in ('payout', 'sweep')) then
          v_why := 'return_differs'; exit rules;
        end if;
        if r.tr_debtor <> l.bank_account_id or r.tr_currency <> l.currency then
          v_why := 'transfer_differs'; exit rules;
        end if;
        if l.booking_date < (select e.effective_date from public.ledger_entry e where e.id = r.tr_entry) then
          v_why := 'return_before_debit'; exit rules;
        end if;
        if v_class = 'E' and l.amount_minor > r.tr_minor then v_why := 'return_differs'; exit rules; end if;
        if r.amount <> r.tr_minor then v_why := 'amount_differs'; exit rules; end if;
        update pg_temp._tl t set c = r.tr_client, a = r.amount,
          payout_account = case when r.kind = 'payout_returned' then r.run_payout_account end
        where t.n = r.n;

      elsif r.kind in ('unplanned_payout_returned', 'unplanned_sweep_returned') then
        -- §3.4.13 the return of an unplanned booking (S27, S28)
        select q.* into v_x from public.bank_transaction q where q.id = r.returns_line_id;
        if v_x.bank_account_id <> l.bank_account_id or v_x.currency <> l.currency then
          v_why := 'transfer_differs'; exit rules;
        end if;
        if r.transfer_id is not null and r.tr_kind is distinct from
           (case r.kind when 'unplanned_payout_returned' then 'payout' else 'sweep' end) then
          v_why := 'transfer_kind_differs'; exit rules;
        end if;
        select k.entry_id, k.amount_minor, k.transfer_id, e.effective_date, e.client_organization_id
        into v_bk
        from public.bank_line_booking k
        join public.ledger_entry e on e.id = k.entry_id
        where k.bank_transaction_id = r.returns_line_id
          and k.kind = case r.kind when 'unplanned_payout_returned' then 'unplanned_payout' else 'unplanned_sweep' end
          and (k.transfer_id is not distinct from r.transfer_id
               -- review round 2 (ld2-reissue-return-pays-twice): the return of a run's payout closes the unplanned
               -- payout of another transfer of the run's chain (private.transfer_chain_unplanned)
               or (r.kind = 'unplanned_payout_returned' and r.transfer_id is not null
                   and k.transfer_id in (select c from private.transfer_chain_unplanned(r.transfer_id) c)))
          and (r.client_id is null or e.client_organization_id = r.client_id)
        order by k.seq limit 1;
        if v_bk.entry_id is null then v_why := 'transfer_unknown'; exit rules; end if;
        if v_bk.transfer_id is distinct from r.transfer_id then
          update pg_temp._tl t set other_e2e = (select y.end_to_end_id from public.bank_transfer y
                                                where y.id = v_bk.transfer_id)
          where t.n = r.n;
        end if;
        if exists (select 1 from public.ledger_entry z where z.reverses_entry_id = v_bk.entry_id) then
          v_why := 'already_returned'; exit rules;
        end if;
        -- (critic L3) our id, or the bank's own return from the IBAN the unplanned payout went to
        if not (v_class = 'U'
                or (v_class = 'E' and r.transfer_id is not null and v_returned_id = r.tr_e2e)
                or (v_class = 'B' and exists (select 1 from pg_temp._tl_pre p where p.role = 'returnable'
                                                and p.transfer_id = r.transfer_id))
                or (v_kind = 'return' and v_class in ('N', 'O', 'E0') and l.counterparty_iban is not null
                    and l.counterparty_iban = coalesce(r.tr_iban, v_x.counterparty_iban))) then
          v_why := 'not_its_line'; exit rules;
        end if;
        -- (critic F1) of several open unplanned bookings, the one with the largest advance (ties: the earliest line)
        if r.transfer_id is not null or r.kind = 'unplanned_payout_returned' then
          select o.line_id into v_first
          from private.transfer_line_open_unplanned(l.organization_id, r.transfer_id, v_bk.client_organization_id,
                                                    v_x.counterparty_iban,
                                                    case r.kind when 'unplanned_payout_returned' then 'unplanned_payout'
                                                                else 'unplanned_sweep' end) o
          limit 1;
          if v_first is distinct from r.returns_line_id then v_why := 'return_differs'; exit rules; end if;
        end if;
        if l.booking_date < v_bk.effective_date then v_why := 'return_before_debit'; exit rules; end if;
        if exists (select 1 from public.client_advance a
                   join public.commission_settlement s on s.document_kind = 'advance' and s.document_id = a.id
                   where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout') then
          v_why := 'advance_settled'; exit rules;
        end if;
        if r.amount <> v_bk.amount_minor then v_why := 'amount_differs'; exit rules; end if;
        update pg_temp._tl t set c = case when r.kind = 'unplanned_payout_returned' then v_bk.client_organization_id end,
          a = r.amount, ub_entry = v_bk.entry_id,
          ub_adv_entry = (select a.entry_id from public.client_advance a
                          where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout'),
          ub_adv_id = (select a.id from public.client_advance a
                       where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout'),
          ub_adv = coalesce((select a.amount_minor from public.client_advance a
                             where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout'), 0),
          payout_account = case
            when r.kind <> 'unplanned_payout_returned' then null
            when r.transfer_id is not null then r.run_payout_account
            else (select a.id from public.client_payout_account a
                  where a.client_organization_id = v_bk.client_organization_id and a.iban = v_x.counterparty_iban
                    and a.currency = l.currency and a.status = 'active' limit 1) end
        where t.n = r.n;
        update pg_temp._tl t set p = t.a - t.ub_adv, adv = t.ub_adv where t.n = r.n;
      end if;
    end loop;

    -- §3.6.1 P per item (Q4's default; critic F2, F3, F4, F5, L1; critic2 ML-1; review money-2), part by part in their
    -- order: least(A, what the queue nets, the signed net of the items still owed, A less what earlier unreversed
    -- unplanned bookings of the same transfer netted)
    for r in select * from pg_temp._tl t where t.kind = 'unplanned_payout' and t.transfer_id is not null order by t.n loop
      drop table if exists pg_temp._tl_el;
      create temp table _tl_el on commit drop as
      select p.ledger_entry_id as i, q.amount_minor as pend, e.posted_at,
             (select z.id from public.ledger_entry z where z.reverses_entry_id = p.ledger_entry_id) as rev,
             0::bigint as net, 0::bigint as paid
      from pg_temp._tl_pool p
      cross join lateral (select y.amount_minor from private.remittance_pending y
                          where y.ledger_entry_id = p.ledger_entry_id offset 0) q
      cross join lateral (select y.posted_at from public.ledger_entry y where y.id = p.ledger_entry_id offset 0) e
      where p.n = r.n and not private.unplanned_own_item(p.ledger_entry_id);
      -- an item that reverses another pending item of the pool is counted in that item's chain, once
      delete from pg_temp._tl_el a using pg_temp._tl_el b where b.rev = a.i;
      update pg_temp._tl_el e set
        net = e.pend + coalesce((select q.amount_minor from private.remittance_pending q
                                 where q.ledger_entry_id = e.rev), 0),
        paid = coalesce((select sum(u.amount_minor) from private.unplanned_paid_item u
                         where u.ledger_entry_id = e.i
                           and not exists (select 1 from public.ledger_entry z
                                           where z.reverses_entry_id = u.booking_entry_id)), 0)
               + coalesce((select sum(t.amount_minor) from pg_temp._tl_items t where t.ledger_entry_id = e.i), 0)
      where true;  -- every row (pg-safeupdate, as above)
      -- M2c-6b-3a-2 (J; COMPLIANCE OQ-82, Q3 (a)): an item another transfer's late execution already netted — an
      -- unreversed unplanned booking of another transfer attributed it, or an earlier part of this call for another
      -- transfer — is left out (it counts nothing here): its gross left is the commission its run set off, which the
      -- next run on the item takes; netted again it would be taken from the client's other collections, a hold-back
      -- without a clause. The rest of A is the servicer's advance (recovered only under a claw-back clause)
      update pg_temp._tl_el e set paid = greatest(e.net, e.paid)
      where exists (select 1
                    from (select u.booking_entry_id from private.unplanned_paid_item u
                          where u.ledger_entry_id = e.i offset 0) u
                    cross join lateral (select k.transfer_id from public.bank_line_booking k
                                        where k.entry_id = u.booking_entry_id offset 0) k
                    where k.transfer_id is distinct from r.transfer_id
                      and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = u.booking_entry_id))
         or exists (select 1 from pg_temp._tl_items i join pg_temp._tl t on t.n = i.n
                    where i.ledger_entry_id = e.i and i.amount_minor > 0
                      and t.transfer_id is distinct from r.transfer_id);
      select count(*), greatest(0, coalesce(sum(e.net), 0) - coalesce(sum(e.paid), 0))
      into v_n_el, v_cap from pg_temp._tl_el e;
      -- (review money-2, LT-1) the unreversed unplanned bookings of one transfer together never net more than its amount:
      -- x's amount is all its run would have paid the client of its items (their gross less the commission that run set
      -- off). An item's gross left after a first execution paid x in full is that commission, owed to the servicer by
      -- the next run on the item: netted again, it would be taken from the client's unrelated collections — a hold-back
      -- without a claw-back clause (Q4, founder #7). A second execution of x is then the servicer's advance in full
      v_cap := least(v_cap, greatest(0, r.amount - coalesce((
                 select sum(k.amount_minor - coalesce(a.amount_minor, 0))
                 from (select q.entry_id, q.amount_minor from public.bank_line_booking q
                       where q.transfer_id = r.transfer_id and q.kind = 'unplanned_payout' offset 0) k
                 left join lateral (select y.amount_minor from public.client_advance y
                                    where y.cause_entry_id = k.entry_id and y.cause = 'double_payout' offset 0) a on true
                 where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id)), 0)));
      v_queue := greatest(0, coalesce((select sum(q.amount_minor) from private.remittance_pending q
                                       where q.organization_id = l.organization_id
                                         and q.client_organization_id = r.tr_client and q.currency = l.currency), 0))
                 - coalesce((select sum(t.p) from pg_temp._tl t
                             where t.n < r.n and t.kind = 'unplanned_payout' and t.c = r.tr_client), 0);
      v_p := greatest(0, least(r.amount, v_queue, v_cap));
      insert into pg_temp._tl_items (n, ledger_entry_id, amount_minor)
      select r.n, z.i, least(z.lft, v_p - z.before)
      from (select e.i, e.net - e.paid as lft,
                   coalesce(sum(e.net - e.paid) over (order by e.posted_at, e.i
                                                     rows between unbounded preceding and 1 preceding), 0) as before
            from pg_temp._tl_el e where e.net - e.paid > 0) z
      where z.before < v_p;
      update pg_temp._tl t set p = v_p, adv = t.a - v_p,
        p_bound = case when v_n_el = 0 then 'none' when v_p = t.a then 'amount' when v_p = v_cap then 'items'
                       else 'queue' end
      where t.n = r.n;
    end loop;

    -- §3.6.5 the drafts: the live run of each client of an unplanned payout or return, re-read here; a draft is
    -- re-prepared; under the locks, a live run the locks did not take is split_changed (critic CSO-12)
    for v_c in select distinct t.c from pg_temp._tl t
               where t.kind in ('unplanned_payout', 'unplanned_payout_returned') and t.c is not null loop
      select y.id, y.status, y.number into v_live_id, v_live_status, v_live_number from public.remittance_run y
      where y.client_organization_id = v_c and y.currency = l.currency and y.status in ('draft', 'approved', 'sent');
      if v_live_id is not null then
        if p_locked and not exists (select 1 from pg_temp._tl_locked_runs k where k.run_id = v_live_id) then
          v_why := 'split_changed'; exit rules;
        end if;
        if v_live_status = 'draft' then
          insert into pg_temp._tl_drafts values (v_live_id, v_live_number, v_c) on conflict do nothing;
        end if;
      end if;
    end loop;
  end rules;

  return jsonb_build_object('why', v_why, 'detail', v_detail);
end;
$$;

-- private.run_remittance_runs_checks, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 3889; same
-- signature and settings, its grants restated below). M2c-6b-3b part 1 (booking-rows-skip-chain-coverage-and-waiting-
-- lines; CPCE-08): the booked branch judges every booked run whose chain holds a payout cancelled out of a downloaded
-- file, its payout standing, at the chain's paid date (private.remittance_chain_paid) — its lines late then with no row
-- yet, once the statements cover each one's L and no other transfer of the chain may have paid by it uncounted
-- (private.remittance_chain_rows, decided: 'expired' writes « bloqué : débit possible non comptabilisé ») — no longer
-- only once a return of the chain is on the statements: the booking now leaves to it the rows it could not judge.
-- Review round 1 (CPCE-08): the booked branch judges a chain that paid nothing while its payout stands at that payout
-- line's date (nightly-null-paid-date-skips-standing-run) and passes the chain's paid date it read to the holds
-- (chain-holds-snapshot-race); the in-flight branch, its rule unchanged, judges each run by
-- private.remittance_inflight_judge (facts in one snapshot, read again after the options). Every other check as before.
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
  with bc as materialized (
    select distinct x.run_id
    from (select q.run_id, q.kind from public.bank_transfer q
          where q.organization_id = p_organization_id and q.status = 'cancelled' and q.transfer_file_id is not null
          offset 0) x
    where x.kind = 'payout' and x.run_id is not null),
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
  bp as materialized (
    select r.id as run_id, r.organization_id, r.client_organization_id, r.requested_execution_date, r.late_reason,
           s.transfer_id as paying, p.paid_on as chain_paid, coalesce(p.paid_on, s.line_date) as paid_on
    from bc
    cross join lateral (select q.id, q.organization_id, q.client_organization_id, q.requested_execution_date,
                               q.late_reason, q.status, q.transfer_id
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
                                    where b.ledger_entry_id = q.ledger_entry_id offset 0))),
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
-- The rule's comment (its body unchanged)
------------------------------------------------------------------------------------------

comment on function private.remittance_chain_events(uuid, uuid, uuid) is
  'Every execution (+1) and return (-1) of the transfers of a run''s payout chain on the statements, each counted for '
  'the transfer it names, at its booking date (ADR-0014 « M2c-6b-3a-2 review fixes » round 4; CPCE-08). A line that only '
  'may be a chain transfer''s debit — carrying none of our references, a batch line other transfers can make, a line '
  'held as a suspected duplicate — is not counted: it holds the run''s R124-6 rows back while it may have paid the '
  'client by L, at the booking of the run''s payout (any such line), in its sheet''s late flag and in the nightly '
  'check''s chained and booked branches (Q14''s rule: while it is young or offers that transfer''s booking; past the '
  'bound days with none, the row « bloqué : débit possible non comptabilisé »), and so do statements not yet covering '
  'least(e0, L) to L (private.remittance_chain_holds, M2c-6b-3b part 1). The holds read these events, the coverage and '
  'the chain''s paid date in one snapshot (private.remittance_chain_hold_facts, review round 1), and wait when the paid '
  'date the reader judged at has moved since.';

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new internals revoked)
------------------------------------------------------------------------------------------

-- the new internals (PostgreSQL grants EXECUTE to PUBLIC by default): only the SECURITY DEFINER callers use them
revoke execute on function private.transfer_debit_lines(uuid, date),
  private.remittance_chain_hold_facts(uuid, uuid, date, uuid),
  private.remittance_chain_holds(uuid, uuid, date, date, boolean, uuid, date),
  private.remittance_chain_rows(uuid, date, date, uuid, uuid, date, boolean),
  private.remittance_inflight_facts(uuid, date),
  private.remittance_inflight_judge(uuid, date, date)
  from public, anon, authenticated, service_role;
-- the redefined internals, as 20261117113000 (private.transfer_debit_suppression), 20261117100000
-- (private.bank_booking_post_rows) and 20261118100000 (private.transfer_line_check, private.run_remittance_runs_checks)
-- left them
revoke execute on function private.transfer_debit_suppression(uuid, date, date),
  private.bank_booking_post_rows(uuid), private.transfer_line_check(uuid, boolean),
  private.run_remittance_runs_checks(uuid, uuid, date)
  from public, anon, authenticated, service_role;
