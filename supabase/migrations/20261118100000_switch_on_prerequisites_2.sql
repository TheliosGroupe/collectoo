-- M2c-6b-3a-2: the switch-on prerequisites, part 2 (docs/design/m2c-6b-3-plan.md §2 E–J, §4 T13–T18; ADR-0014
-- « M2c-6b-3a-2 »; COMPLIANCE OQ-80 (i), (m), OQ-82, CPCE-08). THE SWITCH STAYS OFF: no statement here writes
-- private.feature_switch; 6b-3b flips 'downloaded_file_cancellation' with a one-line migration once the founder answers
-- Q1 (OQ-81 (a)). Every rule below bites only in states that need a downloaded file's transfer to be cancelled (a payout
-- cancelled out of a downloaded file, a re-issue, a downloaded file cancelled whole): production has none, and pgTAP 033
-- (the switch-off test) is unchanged. The manual refund's link (a low item of 6b-3a's review) and J's netting are the
-- only changes that are not inert; J only changes a part whose item another transfer's late execution already netted.
--   * E, the late predecessor (LP): a payout cancelled out of a downloaded file whose run is still approved or sent, in
--     the chain of that run's transfer, executed late — under its RMT id, as a batch line of its PmtInf, as a detail of
--     an entry kept unsplit, or as rule 3b's only candidate — is that run's payout: proposed and booked `payout` of it
--     (remit:<x>, settle:<run>, the run booked at the line's date, x still cancelled with no entry of its own); the run's
--     live transfer y (re-read after the remit lock) is cancelled when ordered, withdrawn with its file (superseded)
--     when that file is not downloaded yet, and the booking refused `reissue_in_downloaded_file` while y's file is
--     downloaded or sent (ops have it cancelled on the evidence first); the compare text carries y, its status and its
--     file (`split_changed` when they moved since the preview);
--   * F: every reader of « booked » takes such a transfer as the run's payout: I20, the deadlines of its return and the
--     payout_returned alert, the client's « Reversements » (and, T17, what a cancelled run's transfer became), the run
--     page (its debit, its return, its advances);
--   * G: its return is « Virement revenu » of it (the payout booking's entry reversed), the lot credit included;
--   * H: a downloaded file cancelled whole never re-issues a payout whose run is no longer in flight, nor a refund no
--     longer requested;
--   * I: the R124-6 in-flight rows of a re-issue and of a run whose payout was cancelled alone — written once the
--     statements cover [the chain's first execution, L] with no possible debit of a chain transfer by L;
--   * J (OQ-82, Q3 (a)): an item another transfer's late execution already netted is not netted again;
--   * 6b-3a's lows: a manual refund linked to a debit without reference is refused beside a cancelled transfer that bars
--     it (private.link_debit_guard); cancel_remittance_run's transfer_already_debited hint names the exit.
--
-- New: private.transfer_late_predecessor (internal). Redefined, each copied from its latest definition across all the
-- migration files and changed only as its comment says, with SECURITY DEFINER, every SET clause, search_path and its
-- grants restated:
--   private.transfer_line_check (20261118090000_switch_on_prerequisites.sql:514)
--   private.transfer_line_options_of (20261118090000_switch_on_prerequisites.sql:1173)
--   private.transfer_line_locks (20261117105000_transfer_line_ops_fixes.sql:47)
--   private.transfer_line_text (20261117100000_transfer_line_ops.sql:1187)
--   private.transfer_line_parts_json (20261117110000_transfer_line_pages.sql:1108)
--   private.transfer_line_post (20261117100000_transfer_line_ops.sql:1487)
--   private.bank_booking_post_rows (20261117100000_transfer_line_ops.sql:2496)
--   private.bank_line_booking_guard (20261117100000_transfer_line_ops.sql:2197)
--   private.transfer_line_returnable (20261117100000_transfer_line_ops.sql:254)
--   private.pending_item_deadlines (20261117100000_transfer_line_ops.sql:2344)
--   private.run_transfer_checks (20261118090000_switch_on_prerequisites.sql:1600)
--   private.run_payment_checks (20261116090000_debit_bookings.sql:2617)
--   private.run_remittance_runs_checks (20261117110000_transfer_line_pages.sql:1251)
--   public.remittance_run_payout (20261117110000_transfer_line_pages.sql:3230)
--   public.client_remittance_summary (20261117110000_transfer_line_pages.sql:3391)
--   private.transfer_file_release (20261115090000_transfers_files.sql:1669)
--   private.link_debit_guard (20261118090000_switch_on_prerequisites.sql:2820)
--   public.cancel_remittance_run (20261116090000_debit_bookings.sql:5080)
-- Review round 1 (ADR-0014 « M2c-6b-3a-2 review fixes »): new private.transfer_unsplit_debit_seen and
-- private.transfer_named_debit_on (internal) and the index bank_transaction_unsplit_details_idx; redefined as well:
--   private.transfer_debited_before (20261118090000_switch_on_prerequisites.sql:346)
--   private.transfer_late_lines (20261117090000_transfer_line_foundations.sql:825)
--   private.transfer_cancel_evidence (20261118090000_switch_on_prerequisites.sql:1442)
-- Review round 2 (ADR-0014 « M2c-6b-3a-2 review fixes », round 2): new private.transfer_chain_unplanned,
-- private.transfer_return_partner and private.remittance_run_paid_on (internal); private.transfer_named_debit_on takes
-- p_booked; redefined as well:
--   private.transfer_unplanned_open (20261117090000_transfer_line_foundations.sql:146)
--   private.transfer_line_open_unplanned (20261117100000_transfer_line_ops.sql:277)
-- Review round 3 (ADR-0014 « M2c-6b-3a-2 review fixes », round 3): new private.transfer_return_known (internal);
-- edited in place: private.transfer_named_debit_on (with p_booked: a batch line booked for several members, a return
-- known from the bookings and the statement details), private.remittance_run_paid_on (its comment) and
-- private.run_remittance_runs_checks (the booked branch's « return seen »).
-- Review round 4 (ADR-0014 « M2c-6b-3a-2 review fixes », round 4; CPCE-08): one rule for the date a run's client was
-- paid and stayed paid, over the run's whole payout chain — new private.remittance_chain_events (every execution and
-- every return of the chain, each counted for the transfer it names) and private.remittance_chain_paid (a transfer paid
-- while its executions outnumber its returns), both internal; they replace private.transfer_named_debit_on and
-- private.transfer_return_known (both new in this unmerged migration, no longer created). Edited in place:
-- private.remittance_run_paid_on, the late flag of private.transfer_line_check, the R124-6 rows of
-- private.bank_booking_post_rows, and the chained and booked branches of private.run_remittance_runs_checks.

------------------------------------------------------------------------------------------
-- E: the late predecessor (plan §2 E)
------------------------------------------------------------------------------------------

-- Whether a transfer is a late predecessor (E): a payout cancelled since, an item of a file downloaded at least once,
-- whose run is still approved or sent and holds it in the chain of its transfer (private.transfer_chain: the run's
-- transfer, then each transfer it re-issues). Its late execution is that run's payout — never a « Virement hors
-- reversement » while the run waits for it. Keyed: the transfer, its run, its items and their files, the chain, by key.
create or replace function private.transfer_late_predecessor(p_transfer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce((
    select true
    from (select x.id, x.kind, x.status, x.run_id from public.bank_transfer x where x.id = p_transfer_id offset 0) x
    cross join lateral (select r.status, r.transfer_id from public.remittance_run r where r.id = x.run_id offset 0) r
    where x.kind = 'payout' and x.status = 'cancelled' and r.status in ('approved', 'sent')
      and exists (select 1 from public.transfer_file_item i
                  cross join lateral (select f.download_count from public.transfer_file f where f.id = i.file_id offset 0) f
                  where i.transfer_id = x.id and f.download_count > 0)
      and exists (select 1 from private.transfer_chain(r.transfer_id) h where h.transfer_id = x.id)), false);
$$;

------------------------------------------------------------------------------------------
-- Review round 1 (ADR-0014 « M2c-6b-3a-2 review fixes »): a transfer's debit as a detail of an entry the bank kept
-- unsplit (DP-1, CSC-1), and the debit that names a transfer by our references (LD-1, LD-2)
------------------------------------------------------------------------------------------

-- The details of ours of an entry the bank kept unsplit, by their content (private.transfer_unsplit_debit_seen,
-- private.transfer_late_lines, private.remittance_chain_events): one keyed probe of a detail's end-to-end id and
-- direction, whatever the statistics (the planner reads @> through it only; the account is compared on the lines found).
-- Not inert in the sense of a function, but no reader of it bites before the switch: only cancelled transfers and
-- re-issues read it.
create index bank_transaction_unsplit_details_idx on public.bank_transaction using gin (unsplit_details jsonb_path_ops)
  where unsplit_details is not null;

-- Our own debit of a transfer as a detail of an entry the bank kept unsplit (camt.053: an entry with TxDtls of ours
-- that does not add up to their sum — the bank's charge taken from it — or holds other movements), on an imported
-- statement of its account: a stored detail (bank_transaction.unsplit_details, the statement's own) carrying its
-- end-to-end id as a debit, whatever the entry's total, its charges or its PmtInfId. private.transfer_own_debit_seen
-- reads the line's own end-to-end id only, which such an entry carries only when it holds one detail of ours (the
-- parser's single-detail shape); with two or more it carries none, and private.batch_debit_may_hold misses it once a
-- charge breaks the sums. Keyed by the detail alone (bank_transaction_unsplit_details_idx), the account compared on the
-- lines found (as private.transfer_own_debit_seen).
create or replace function private.transfer_unsplit_debit_seen(p_bank_account_id uuid, p_end_to_end_id text)
returns boolean
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select count(*) > 0
  from (select x.bank_account_id from public.bank_transaction x
        where x.unsplit_details @> jsonb_build_array(jsonb_build_object('id', p_end_to_end_id, 'direction', 'debit'))
        offset 0) x
  where x.bank_account_id = p_bank_account_id;
$$;

-- Review round 4 (ADR-0014 « M2c-6b-3a-2 review fixes », round 4; CPCE-08): one rule for the date a run's client was
-- paid and stayed paid, over the run's whole payout chain (private.transfer_chain: the run's transfer, then each
-- transfer it re-issues). It replaces round 1's private.transfer_named_debit_on (and its p_booked mode, round 2) and
-- round 3's private.transfer_return_known, whose per-shape tests each missed the next shape (a lot line booked for
-- several members, a return the bank did not flag, more executions than returns).
--
-- The events of a run's payout chain: each line of the statements that executes or returns one of its transfers,
-- counted once for that transfer (+1 an execution, -1 a return) at its booking date —
--   executions: a debit on the transfer's account dated from its requested execution date carrying its end-to-end id
--     as its own or original; a debit entry kept unsplit holding a detail of it (bank_transaction.unsplit_details); a
--     batch line (no end-to-end id) of its PmtInf in a file downloaded at least once that certainly holds it — the
--     line can hold it (private.batch_line_may_hold) and the PmtInf's other transfers not debited on their own cannot
--     make its amount without it (private.amounts_make_up); a line holding its payout or unplanned payout booking (a
--     lot line booked for several members, rule 3b's line booked as a late predecessor or « Virement hors
--     reversement »); and p_line_id when it is being booked (or previewed) as p_line_transfer's payout. A line booked
--     or linked otherwise (an explanation aside), a payment, a line held as a suspected duplicate and not released:
--     never. A line carrying none of our references, or a batch line other transfers can make, only may be its debit:
--     not counted (rule 3b and private.transfer_debit_suppression hold the row back while one waits — Q14's default);
--   returns: a credit on its account carrying its end-to-end id as its own or original, of a kind a return part sits
--     on — return, client_transfer_in, own_transfer_in (the bank's unflagged return from the client's payout IBAN under
--     our id included; booked or not, the statement says it came back); a credit entry kept unsplit holding a credit
--     detail of it; a lot credit (no end-to-end id) of its PmtInf booked as its return (payout_returned,
--     unplanned_payout_returned: the booking names the member that came back). A payment, a line held as a suspected
--     duplicate and not released (its kind is not a return's until its release): never. A return carrying none of our
--     references (rule 3b) is not counted — it may be either copy's (COMPLIANCE CPCE-08's default) — nor a lot credit
--     not booked yet (it names no member).
-- A return carries the id of the transfer that came back, whatever booking it closes (round 2's return closing another
-- copy, its partner booked as the run's payout returned on the copy's line): it counts for that transfer. Keyed: the
-- chain, each transfer, its id's lines (bank_transaction_end_to_end_idx, bank_transaction_return_e2e_idx), its details'
-- lines (bank_transaction_unsplit_details_idx), its items, files and PmtInf lines, its bookings
-- (bank_line_booking_transfer_idx) and their lines, each by key.
create or replace function private.remittance_chain_events(p_transfer_id uuid, p_line_id uuid default null,
                                                         p_line_transfer uuid default null)
returns table (transfer_id uuid, line_id uuid, on_date date, delta integer)
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select distinct on (e.transfer_id, e.line_id) e.transfer_id, e.line_id, e.on_date, e.delta
  from (select c.transfer_id from private.transfer_chain(p_transfer_id) c offset 0) c
  cross join lateral (select q.id, q.debtor_bank_account_id, q.end_to_end_id, q.requested_execution_date
                      from public.bank_transfer q where q.id = c.transfer_id offset 0) t
  cross join lateral (
    -- its executions
    select t.id as transfer_id, x.id as line_id, x.booking_date as on_date, 1 as delta
    from (
      select y.id
      from (select q.id, q.bank_account_id, q.direction from public.bank_transaction q
            where q.end_to_end_id = t.end_to_end_id offset 0) y
      where y.bank_account_id = t.debtor_bank_account_id and y.direction = 'debit'
      union
      select y.id
      from (select q.id, q.bank_account_id, q.direction from public.bank_transaction q
            where coalesce(q.original_end_to_end_id, q.end_to_end_id) = t.end_to_end_id offset 0) y
      where y.bank_account_id = t.debtor_bank_account_id and y.direction = 'debit'
      union
      select y.id
      from (select q.id, q.bank_account_id from public.bank_transaction q
            where q.unsplit_details @> jsonb_build_array(jsonb_build_object('id', t.end_to_end_id, 'direction', 'debit'))
            offset 0) y
      where y.bank_account_id = t.debtor_bank_account_id
      union
      select y.id
      from (select q.file_id, q.pmt_inf_id from public.transfer_file_item q where q.transfer_id = t.id offset 0) i
      cross join lateral (select f.download_count from public.transfer_file f where f.id = i.file_id offset 0) f
      cross join lateral (select q.id, q.amount_minor from public.bank_transaction q
                          where q.bank_account_id = t.debtor_bank_account_id and q.payment_info_id = i.pmt_inf_id
                            and q.direction = 'debit' and q.end_to_end_id is null offset 0) y
      where f.download_count > 0 and private.batch_line_may_hold(y.id, i.file_id, i.pmt_inf_id, t.id)
        -- certainly this transfer's: the PmtInf's other transfers (not debited on their own) cannot make the line alone
        and not private.amounts_make_up(
              (select coalesce(array_agg(o.amount_minor order by o.amount_minor desc), '{}')
               from public.transfer_file_item j
               cross join lateral (select o.amount_minor, o.end_to_end_id from public.bank_transfer o
                                   where o.id = j.transfer_id offset 0) o
               where j.file_id = i.file_id and j.pmt_inf_id = i.pmt_inf_id and j.transfer_id <> t.id
                 and not private.transfer_own_debit_seen(t.debtor_bank_account_id, o.end_to_end_id)),
              y.amount_minor)
      union
      select k.bank_transaction_id from public.bank_line_booking k
      where k.transfer_id = t.id and k.kind in ('payout', 'unplanned_payout')
      union
      select p_line_id where p_line_transfer = t.id
    ) l
    cross join lateral (select q.id, q.booking_date, q.kind from public.bank_transaction q where q.id = l.id offset 0) x
    where x.booking_date >= t.requested_execution_date
      -- not booked nor linked (an explanation aside), but as this transfer's own payout or unplanned payout — then
      -- whatever else is booked on the line (a batch line's other members: its bookings add up to its amount)
      and ((x.id = p_line_id and p_line_transfer = t.id)
           or exists (select 1 from public.bank_line_booking k
                      where k.bank_transaction_id = x.id and k.transfer_id = t.id
                        and k.kind in ('payout', 'unplanned_payout') offset 0)
           or (not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
               and not exists (select 1 from public.bank_debit_link k
                               where k.bank_transaction_id = x.id and k.kind <> 'explained' offset 0)))
      and not exists (select 1 from public.payment p where p.bank_transaction_id = x.id offset 0)
      and (x.kind <> 'suspected_duplicate'
           or exists (select 1 from public.bank_duplicate_resolution r
                      where r.bank_transaction_id = x.id and r.decision = 'released' offset 0))
    union all
    -- its returns
    select t.id, x.id, x.booking_date, -1
    from (
      select y.id
      from (select q.id, q.bank_account_id, q.direction, q.kind from public.bank_transaction q
            where coalesce(q.original_end_to_end_id, q.end_to_end_id) = t.end_to_end_id offset 0) y
      where y.bank_account_id = t.debtor_bank_account_id and y.direction = 'credit'
        and coalesce((select r.released_kind from public.bank_duplicate_resolution r
                      where r.bank_transaction_id = y.id and r.decision = 'released' offset 0), y.kind)
              in ('return', 'client_transfer_in', 'own_transfer_in')
      union
      select y.id
      from (select q.id, q.bank_account_id from public.bank_transaction q
            where q.unsplit_details @> jsonb_build_array(jsonb_build_object('id', t.end_to_end_id, 'direction', 'credit'))
            offset 0) y
      where y.bank_account_id = t.debtor_bank_account_id
      union
      select q.id
      from (select k.bank_transaction_id from public.bank_line_booking k
            where k.transfer_id = t.id and k.kind in ('payout_returned', 'unplanned_payout_returned') offset 0) k
      cross join lateral (select q.id, q.direction, q.payment_info_id, q.end_to_end_id, q.original_end_to_end_id
                          from public.bank_transaction q where q.id = k.bank_transaction_id offset 0) q
      where q.direction = 'credit' and q.end_to_end_id is null and q.original_end_to_end_id is null
        and exists (select 1 from public.transfer_file_item i
                    where i.transfer_id = t.id and i.pmt_inf_id = q.payment_info_id)
    ) l
    cross join lateral (select q.id, q.booking_date, q.kind from public.bank_transaction q where q.id = l.id offset 0) x
    -- (a line held as a suspected duplicate counts once released: the kind its release gives it, above)
    where not exists (select 1 from public.payment p where p.bank_transaction_id = x.id offset 0)
  ) e;
$$;

-- The date a run's payout chain paid the client and stayed paid (review round 4; CPCE-08), from the chain of
-- p_transfer_id (the run's transfer) and its events (private.remittance_chain_events): per transfer, its events in date
-- order — on one date its executions first (a return the same day undoes that day's execution) — counted, a return with
-- nothing outstanding undoing nothing (its execution is on no line counted here); the transfer is paid from the first
-- date from which its executions outnumber its returns for the rest of what the statements show — of two executions
-- and one return, the earlier execution is the one kept (the duplicate is the one that comes back: COMPLIANCE CPCE-08's
-- default) — and never when every execution came back. paid_on: the earliest such date of the chain's transfers, null
-- when none stayed paid. A return counts for the transfer it names only: the copy that came back paid nothing, whatever
-- the other copies did. returned: a return of the chain is on the statements (the nightly booked branch judges a booked
-- run again only then — an execution can only move the date earlier, never a row more). Keyed as its events.
create or replace function private.remittance_chain_paid(p_transfer_id uuid, p_line_id uuid default null,
                                                       p_line_transfer uuid default null,
                                                       out paid_on date, out returned boolean)
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
declare
  r record;
  v_transfer uuid;
  v_n integer := 0;
  v_from date;
begin
  returned := false;
  for r in select e.transfer_id, e.on_date, e.delta
           from private.remittance_chain_events(p_transfer_id, p_line_id, p_line_transfer) e
           order by e.transfer_id, e.on_date, e.delta desc, e.line_id loop
    if r.transfer_id is distinct from v_transfer then
      if v_n >= 1 then
        paid_on := least(paid_on, v_from);
      end if;
      v_transfer := r.transfer_id;
      v_n := 0;
      v_from := null;
    end if;
    returned := returned or r.delta < 0;
    v_n := greatest(v_n + r.delta, 0);
    if v_n = 0 then
      v_from := null;
    elsif v_from is null then
      v_from := r.on_date;
    end if;
  end loop;
  if v_n >= 1 then
    paid_on := least(paid_on, v_from);
  end if;
end;
$$;

------------------------------------------------------------------------------------------
-- Review round 2 (ADR-0014 « M2c-6b-3a-2 review fixes », round 2): the copies of one run's payout (ld2-reissue-return-
-- pays-twice) and the date a booked run's client stayed paid (ld2-named-debit-returned-after-booking)
------------------------------------------------------------------------------------------

-- The other transfers of a payout's run chain whose open « Virement hors reversement » a return of this payout closes
-- (critic F1 over the run's chain): this transfer is its run's payout — a payout booking of it whose entry is not
-- reversed (the run's transfer booked, or a late predecessor) — or its own « Virement hors reversement » was closed by a
-- return of another transfer of the run (both copies came back: another open copy closes first, else the run's payout,
-- private.transfer_return_partner); and it has no unplanned payout of its own still open (that one closes first, as
-- before); then every other transfer of the chain of its run's transfer (private.transfer_chain). The chain's transfers
-- are copies of one payment to one client: when one copy is the run's payout and another was booked « Virement hors
-- reversement » (the servicer's advance), the copy that comes back is the unplanned one — booked as the run's payout
-- returned, the run's sums would be owed again while the client keeps the other copy (paid twice). Keyed: the transfer,
-- its run, the chain, each one's bookings and their reversals by key.
create or replace function private.transfer_chain_unplanned(p_transfer_id uuid)
returns setof uuid
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select c.transfer_id
  from (select x.id, x.kind, x.run_id from public.bank_transfer x where x.id = p_transfer_id offset 0) t
  cross join lateral (select r.transfer_id from public.remittance_run r where r.id = t.run_id offset 0) r
  cross join lateral private.transfer_chain(r.transfer_id) c
  where t.kind = 'payout' and c.transfer_id <> t.id
    -- its run's payout: a payout booking of it, its entry not reversed
    and (exists (select 1
                 from (select k.entry_id from public.bank_line_booking k
                       where k.transfer_id = t.id and k.kind = 'payout' offset 0) k
                 where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id offset 0))
         -- or its « Virement hors reversement » closed by a return of another transfer of the run
         or exists (select 1
                    from (select k.entry_id from public.bank_line_booking k
                          where k.transfer_id = t.id and k.kind = 'unplanned_payout' offset 0) k
                    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = k.entry_id
                                        offset 0) z
                    cross join lateral (select q.transfer_id from public.bank_line_booking q
                                        where q.entry_id = z.id and q.kind = 'unplanned_payout_returned' offset 0) q
                    where q.transfer_id is distinct from t.id))
    -- no unplanned payout of its own still open
    and not exists (select 1
                    from (select k.entry_id from public.bank_line_booking k
                          where k.transfer_id = t.id and k.kind = 'unplanned_payout' offset 0) k
                    where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id
                                      offset 0))
    -- the chain holds it (a payout's run never changes: defence in depth)
    and exists (select 1 from private.transfer_chain(r.transfer_id) h where h.transfer_id = t.id);
$$;

-- private.transfer_unplanned_open, redefined from 20261117090000_transfer_line_foundations.sql (line 146; same signature and settings, its grants restated below).
-- Review round 2 (ld2-reissue-return-pays-twice): also an open unplanned payout of another transfer of its run's chain
-- when this one is its run's payout, or a copy whose own unplanned payout another's return closed
-- (private.transfer_chain_unplanned) — the job reviews such a return
-- (unplanned_payout_return), the command refuses it as the run's payout (unplanned_open) and « Comptabiliser… »
-- proposes it as that unplanned payout's return (private.transfer_line_open_unplanned). Nothing else changes.
create or replace function private.transfer_unplanned_open(p_transfer_id uuid)
returns boolean
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select p_transfer_id is not null and (exists (
    select 1
    from (select k.entry_id from public.bank_line_booking k
          where k.transfer_id = p_transfer_id and k.kind in ('unplanned_payout', 'unplanned_sweep') offset 0) k
    where not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = k.entry_id offset 0))
    -- review round 2: another transfer of its run's chain (private.transfer_chain_unplanned)
    or exists (
    select 1
    from private.transfer_chain_unplanned(p_transfer_id) c (transfer_id)
    cross join lateral (select k.entry_id from public.bank_line_booking k
                        where k.transfer_id = c.transfer_id and k.kind = 'unplanned_payout' offset 0) k
    where not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = k.entry_id offset 0)));
$$;

-- private.transfer_line_open_unplanned, redefined from 20261117100000_transfer_line_ops.sql (line 277; same signature and settings, its grants restated below).
-- Review round 2 (ld2-reissue-return-pays-twice): for a payout's unplanned payouts, also those of the other transfers of
-- its run's chain when it is its run's payout (or a copy whose own another's return closed) with none of its own open
-- (private.transfer_chain_unplanned): its return closes the largest advance of them first, as before. Nothing else
-- changes.
create or replace function private.transfer_line_open_unplanned(p_org uuid, p_transfer uuid, p_client uuid,
                                                                p_iban text, p_kind text)
returns table (line_id uuid, entry_id uuid, amount_minor bigint, advance_minor bigint, advance_id uuid,
               advance_entry_id uuid, line_date date, entry_date date, client_organization_id uuid, iban text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select k.bank_transaction_id, k.entry_id, k.amount_minor, coalesce(a.amount_minor, 0), a.id, a.entry_id,
         t.booking_date, e.effective_date, e.client_organization_id, t.counterparty_iban
  from (select q.bank_transaction_id, q.entry_id, q.amount_minor from public.bank_line_booking q
        where p_transfer is not null and q.transfer_id = p_transfer and q.kind = p_kind
        union all
        -- review round 2: the other transfers of its run's chain (by key: the chain, each one's bookings)
        select q.bank_transaction_id, q.entry_id, q.amount_minor
        from private.transfer_chain_unplanned(p_transfer) c (transfer_id)
        cross join lateral (select q.bank_transaction_id, q.entry_id, q.amount_minor from public.bank_line_booking q
                            where q.transfer_id = c.transfer_id and q.kind = 'unplanned_payout' offset 0) q
        where p_transfer is not null and p_kind = 'unplanned_payout'
        union all
        select q.bank_transaction_id, q.entry_id, q.amount_minor
        from (select le.id from public.ledger_entry le
              where p_transfer is null and le.organization_id = p_org and le.client_organization_id = p_client
                and le.entry_type = 'remittance' and le.source_type = 'bank_transaction' offset 0) le
        cross join lateral (select q.bank_transaction_id, q.entry_id, q.amount_minor, q.transfer_id
                            from public.bank_line_booking q where q.entry_id = le.id offset 0) q
        where q.transfer_id is null) k
  cross join lateral (select q.effective_date, q.client_organization_id, q.posted_at from public.ledger_entry q
                      where q.id = k.entry_id offset 0) e
  cross join lateral (select q.booking_date, q.counterparty_iban from public.bank_transaction q
                      where q.id = k.bank_transaction_id offset 0) t
  left join lateral (select q.id, q.amount_minor, q.entry_id from public.client_advance q
                     where q.cause_entry_id = k.entry_id and q.cause = 'double_payout' offset 0) a on true
  where not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = k.entry_id offset 0)
    and (p_transfer is not null or t.counterparty_iban = p_iban)
  order by coalesce(a.amount_minor, 0) desc, t.booking_date, e.posted_at, k.bank_transaction_id;
$$;

-- The run's payout a return of this transfer comes back as (review round 2, ld2-reissue-return-pays-twice): this
-- transfer is a payout that is not its run's payout (no payout booking of it) whose « Virement hors reversement » a return
-- of its run's payout p closed (private.transfer_chain_unplanned: a booking unplanned_payout_returned of p reversed it),
-- none of its own still open; p's payout still stands (its payout booking's entry not reversed). Read only once no
-- other copy of the run is open (private.transfer_unplanned_open first: such a copy closes first, and the command
-- refuses p's return while one is open — unplanned_open). Both copies then came back: this return is p's payout's — its
-- run's sums owed again (« Virement revenu », booked on this line, naming this transfer) — never a return nobody can
-- book. Null otherwise. Keyed: the transfer, its bookings, their reversals and the bookings of those, p and its
-- bookings, each by key.
create or replace function private.transfer_return_partner(p_transfer_id uuid)
returns uuid
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select p.id
  from (select x.id, x.kind, x.run_id from public.bank_transfer x where x.id = p_transfer_id offset 0) m
  cross join lateral (select k.entry_id from public.bank_line_booking k
                      where k.transfer_id = m.id and k.kind = 'unplanned_payout' offset 0) k
  cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = k.entry_id offset 0) z
  cross join lateral (select q.transfer_id from public.bank_line_booking q
                      where q.entry_id = z.id and q.kind = 'unplanned_payout_returned' offset 0) c
  cross join lateral (select y.id, y.run_id from public.bank_transfer y where y.id = c.transfer_id offset 0) p
  where m.kind = 'payout' and p.id <> m.id and p.run_id = m.run_id
    and not exists (select 1 from public.bank_line_booking q where q.transfer_id = m.id and q.kind = 'payout')
    and not exists (select 1
                    from (select q.entry_id from public.bank_line_booking q
                          where q.transfer_id = m.id and q.kind = 'unplanned_payout' offset 0) q
                    where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = q.entry_id
                                      offset 0))
    and exists (select 1
                from (select q.entry_id from public.bank_line_booking q
                      where q.transfer_id = p.id and q.kind = 'payout' offset 0) q
                where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = q.entry_id offset 0))
  limit 1;
$$;

-- The date a booked run's client was paid and stayed paid (review round 2, ld2-named-debit-returned-after-booking;
-- CPCE-08): review round 4, the one rule over the run's payout chain (private.remittance_chain_paid, from the run's
-- transfer); null when no transfer of the chain stayed paid. The nightly check judges a booked run's R124-6 rows at it
-- once a return of its chain is on the statements (private.run_remittance_runs_checks); pgTAP 040 reads it. Keyed: the
-- run, then its chain's events.
create or replace function private.remittance_run_paid_on(p_run_id uuid)
returns date
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select p.paid_on
  from (select r.transfer_id from public.remittance_run r where r.id = p_run_id offset 0) r
  cross join lateral private.remittance_chain_paid(r.transfer_id) p;
$$;

-- private.transfer_debited_before, redefined from 20261118090000_switch_on_prerequisites.sql (line 346; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 review round 1 (DP-1, CSC-1): a transfer's own debit counts also as a detail of an entry the bank kept
-- unsplit (private.transfer_unsplit_debit_seen) — under the same conditions as its own end-to-end id: a chain member
-- deeper than the transfer, or the transfer not in a live downloaded file, its return not seen. A late predecessor
-- executed so holds its re-issue (already_debited: generation, the download's re-checks, the run's cancellation, the
-- alerts) as it does under its RMT id. Nothing else changes.
create or replace function private.transfer_debited_before(p_transfer_id uuid)
returns boolean
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transfer;
  v_live uuid;   -- the downloaded file the transfer is in now (its own debit there is its execution)
  v_depth integer := 0;
begin
  select * into t from public.bank_transfer where id = p_transfer_id;
  if t.status = 'in_file' then
    select f.id into v_live from public.transfer_file f where f.id = t.transfer_file_id and f.download_count > 0;
  end if;
  while t.id is not null and v_depth < 1000 loop
    if (v_depth > 0 or v_live is null)
       and (private.transfer_own_debit_seen(t.debtor_bank_account_id, t.end_to_end_id)
            -- M2c-6b-3a-2 review round 1 (DP-1, CSC-1): or as a detail of an entry the bank kept unsplit
            or private.transfer_unsplit_debit_seen(t.debtor_bank_account_id, t.end_to_end_id))
       and not private.transfer_return_seen(t.id) then
      return true;
    end if;
    -- M2c-6b-3a (L): a possible late execution carrying none of our references (not booked nor linked yet)
    if (v_depth > 0 or t.status = 'cancelled')
       and exists (select 1 from private.transfer_unreferenced_lines(t.id))
       and not private.transfer_return_seen(t.id) then
      return true;
    end if;
    if exists (select 1 from public.transfer_file_item i
               cross join lateral (select f.download_count, f.status from public.transfer_file f
                                   where f.id = i.file_id offset 0) f
               where i.transfer_id = t.id and f.download_count > 0
                 and ((f.status in ('superseded', 'rejected')
                       and private.batch_debit_may_hold(i.file_id, i.pmt_inf_id, t.id))
                      or (t.status = 'cancelled' and f.status in ('downloaded', 'sent')
                          and private.batch_debit_may_hold(i.file_id, i.pmt_inf_id, t.id,
                                                           private.next_business_day(i.execution_date)))))
       and not private.transfer_return_seen(t.id) then
      return true;
    end if;
    exit when t.replaces_transfer_id is null;
    select * into t from public.bank_transfer where id = t.replaces_transfer_id;
    v_depth := v_depth + 1;
  end loop;
  return false;
end;
$$;

-- private.transfer_late_lines, redefined from 20261117090000_transfer_line_foundations.sql (line 825; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 review round 1 (DP-1, CSC-1): for a chain member deeper than the transfer, or the transfer itself once
-- cancelled, also the lines of entries kept unsplit holding a detail of its debit, not booked nor linked — the P0
-- cancelled_transfer_debited, the open late debit of A, B, C and M (private.transfer_late_debit_open), and a return's
-- debit_pending read them as they read its own end-to-end id. Nothing else changes.
create or replace function private.transfer_late_lines(p_transfer_id uuid)
returns setof uuid
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transfer;
  v_account uuid;
  v_depth integer := 0;
begin
  select * into t from public.bank_transfer where id = p_transfer_id;
  v_account := t.debtor_bank_account_id;
  while t.id is not null and v_depth < 1000 loop
    return query
    select x.id
    from (select q.id, q.bank_account_id, q.direction from public.bank_transaction q
          where q.end_to_end_id = t.end_to_end_id offset 0) x
    where x.bank_account_id = v_account and x.direction = 'debit'
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id and l.kind <> 'explained'
                      offset 0)
      and not exists (select 1 from public.payment p where p.bank_transaction_id = x.id offset 0)
      -- review M2c-6b-2a (M1): never a line decided a duplicate (by its key)
      and not exists (select 1 from public.bank_duplicate_resolution r
                      where r.bank_transaction_id = x.id and r.decision = 'duplicate' offset 0);
    -- M2c-6b-3a-2 review round 1 (DP-1, CSC-1): a chain member deeper than the transfer, or the transfer itself once
    -- cancelled — a detail of an entry the bank kept unsplit carrying its end-to-end id as a debit (the entry's own
    -- end-to-end id is none once it holds two details or more), not booked nor linked
    if v_depth > 0 or t.status = 'cancelled' then
      return query
      select x.id
      from (select q.id, q.bank_account_id from public.bank_transaction q
            where q.unsplit_details @> jsonb_build_array(jsonb_build_object('id', t.end_to_end_id, 'direction', 'debit'))
            offset 0) x
      where x.bank_account_id = v_account
        and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
        and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id
                          and l.kind <> 'explained' offset 0)
        and not exists (select 1 from public.payment p where p.bank_transaction_id = x.id offset 0)
        and not exists (select 1 from public.bank_duplicate_resolution r
                        where r.bank_transaction_id = x.id and r.decision = 'duplicate' offset 0);
    end if;
    return query
    select x.id
    from public.transfer_file_item i
    cross join lateral (select f.download_count, f.status from public.transfer_file f where f.id = i.file_id offset 0) f
    cross join lateral (select q.id, q.booking_date from public.bank_transaction q
                        where q.bank_account_id = v_account and q.payment_info_id = i.pmt_inf_id
                          and q.direction = 'debit' and q.end_to_end_id is null offset 0) x
    where i.transfer_id = t.id and f.download_count > 0
      and (f.status in ('superseded', 'rejected')
           or (t.status = 'cancelled' and f.status in ('downloaded', 'sent')
               and x.booking_date > private.next_business_day(i.execution_date)))
      and private.batch_line_may_hold(x.id, i.file_id, i.pmt_inf_id, t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id and l.kind <> 'explained'
                      offset 0)
      -- review M2c-6b-2a (M1): never a line decided a duplicate (by its key)
      and not exists (select 1 from public.bank_duplicate_resolution r
                      where r.bank_transaction_id = x.id and r.decision = 'duplicate' offset 0);
    exit when t.replaces_transfer_id is null;
    select * into t from public.bank_transfer where id = t.replaces_transfer_id;
    v_depth := v_depth + 1;
  end loop;
end;
$$;

-- private.transfer_cancel_evidence, redefined from 20261118090000_switch_on_prerequisites.sql (line 1442; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 review round 1 (DP-1): a transfer's debit as a detail of an entry the bank kept unsplit
-- (private.transfer_unsplit_debit_seen) is its debit seen — for the file (an in-file transfer of it) and for one
-- transfer: the bank executed it, the file is not cancelled on that evidence (debit_seen). Nothing else changes.
create or replace function private.transfer_cancel_evidence(p_file_id uuid, p_transfer_id uuid,
                                                            p_file_executed boolean default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  f public.transfer_file;
  t public.bank_transfer;
  v_pmt_inf text;
  v_from date;
  v_to date;
  v_over boolean;
  v_covered boolean;
  v_debit boolean := false;
  v_returned boolean := false;
  v_ambiguous boolean := false;
  v_executed boolean;
  v_unref_from date;
  v_others bigint;
  v_amounts bigint[];
begin
  select * into f from public.transfer_file where id = p_file_id;
  if p_transfer_id is null then
    v_from := f.first_execution_date;
    v_to := private.next_business_day(f.last_execution_date);
    v_debit := exists (select 1 from (select distinct i.pmt_inf_id from public.transfer_file_item i
                                      where i.file_id = f.id) p
                       where exists (select 1 from public.bank_transaction x
                                     where x.bank_account_id = f.debtor_bank_account_id
                                       and x.payment_info_id = p.pmt_inf_id and x.direction = 'debit'))
               or exists (select 1 from public.transfer_file_item i
                          cross join lateral (select x.id, x.status, x.end_to_end_id, x.transfer_file_id
                                              from public.bank_transfer x where x.id = i.transfer_id offset 0) bt
                          where i.file_id = f.id and bt.transfer_file_id = f.id
                            and (bt.status = 'booked'
                                 or (bt.status = 'in_file'
                                     and (private.transfer_own_debit_seen(f.debtor_bank_account_id, bt.end_to_end_id)
                                          -- M2c-6b-3a-2 review round 1 (DP-1): or as a detail of an entry kept unsplit
                                          or private.transfer_unsplit_debit_seen(f.debtor_bank_account_id,
                                                                                 bt.end_to_end_id))
                                     and not private.transfer_return_seen(bt.id))));
    v_returned := not v_debit and exists (
      select 1 from public.transfer_file_item i
      cross join lateral (select x.id, x.status, x.transfer_file_id from public.bank_transfer x
                          where x.id = i.transfer_id offset 0) bt
      where i.file_id = f.id and bt.status = 'in_file' and bt.transfer_file_id = f.id
        and private.transfer_return_seen(bt.id));
    -- M2c-6b-3a (N): a debit carrying none of our references that may be one of its transfers' execution, or its
    -- PmtInf's (the sum of its in-file transfers, as one line), not booked nor linked
    if not v_debit then
      select min(u.booking_date) into v_unref_from
      from public.transfer_file_item i
      cross join lateral (select x.id, x.status, x.transfer_file_id from public.bank_transfer x
                          where x.id = i.transfer_id offset 0) bt
      cross join lateral private.transfer_unreferenced_lines(bt.id) u
      where i.file_id = f.id and bt.transfer_file_id = f.id and bt.status = 'in_file';
      select least(v_unref_from, min(x.booking_date)) into v_unref_from
      from (select i.pmt_inf_id, sum(bt.amount_minor) as total, count(*) as n
            from public.transfer_file_item i
            cross join lateral (select x.amount_minor, x.status, x.transfer_file_id from public.bank_transfer x
                                where x.id = i.transfer_id offset 0) bt
            where i.file_id = f.id and bt.transfer_file_id = f.id and bt.status = 'in_file'
            group by i.pmt_inf_id) p
      cross join lateral (select q.id, q.booking_date, q.currency, q.end_to_end_id, q.payment_info_id, q.unsplit_ours
                          from public.bank_transaction q
                          where q.bank_account_id = f.debtor_bank_account_id and q.amount_minor = p.total
                            and q.direction = 'debit' offset 0) x
      where p.n > 1 and x.booking_date >= f.first_execution_date and x.currency = f.currency
        and x.end_to_end_id is null and x.payment_info_id is null and x.unsplit_ours is null
        and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
        and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id
                          and l.kind <> 'explained' offset 0)
        and not exists (select 1 from public.payment y where y.bank_transaction_id = x.id offset 0)
        and not exists (select 1 from public.bank_duplicate_resolution r
                        where r.bank_transaction_id = x.id and r.decision = 'duplicate' offset 0);
    end if;
  else
    select * into t from public.bank_transfer where id = p_transfer_id;
    select i.pmt_inf_id, i.execution_date, private.next_business_day(i.execution_date)
    into v_pmt_inf, v_from, v_to
    from public.transfer_file_item i where i.file_id = f.id and i.transfer_id = t.id;
    if private.transfer_own_debit_seen(t.debtor_bank_account_id, t.end_to_end_id)
       -- M2c-6b-3a-2 review round 1 (DP-1): or as a detail of an entry kept unsplit
       or private.transfer_unsplit_debit_seen(t.debtor_bank_account_id, t.end_to_end_id) then
      v_returned := private.transfer_return_seen(t.id);
      v_debit := not v_returned;
    elsif exists (select 1 from public.bank_transaction x
                  where x.bank_account_id = t.debtor_bank_account_id and x.payment_info_id = v_pmt_inf
                    and x.direction = 'debit' and x.end_to_end_id is null) then
      -- the PmtInf's other open transfers: their sum (the batch must be exactly it) and, of those not above this one's
      -- amount, the amounts that could stand in for it (review round 2, D3); one returned was in the batch: in the sum
      -- even once cancelled, standing in for nothing (review round 3, E3)
      select coalesce(sum(o.amount_minor), 0),
             coalesce(array_agg(o.amount_minor order by o.amount_minor desc)
                        filter (where o.amount_minor <= t.amount_minor and not o.returned), '{}')
      into v_others, v_amounts
      from public.transfer_file_item i
      cross join lateral (select o.amount_minor, o.end_to_end_id, o.status, o.transfer_file_id,
                                 private.transfer_return_seen(o.id) as returned
                          from public.bank_transfer o where o.id = i.transfer_id offset 0) o
      where i.pmt_inf_id = v_pmt_inf and i.file_id = f.id and i.transfer_id <> t.id and o.transfer_file_id = f.id
        and (o.status <> 'cancelled' or o.returned)
        and not private.transfer_own_debit_seen(t.debtor_bank_account_id, o.end_to_end_id);
      v_debit := not exists (select 1 from public.bank_transaction x
                             where x.bank_account_id = t.debtor_bank_account_id and x.payment_info_id = v_pmt_inf
                               and x.direction = 'debit' and x.end_to_end_id is null
                               and x.amount_minor = v_others)
                 or exists (select 1 from public.bank_transaction x
                            where x.bank_account_id = t.debtor_bank_account_id and x.payment_info_id = v_pmt_inf
                              and x.direction = 'debit' and x.end_to_end_id is null
                              and x.amount_minor <> v_others);
      if private.transfer_return_seen(t.id) then
        v_debit := false;
        v_returned := true;
      elsif not v_debit then
        v_ambiguous := private.amounts_make_up(v_amounts, t.amount_minor);
      end if;
    elsif private.transfer_return_seen(t.id) then
      v_returned := true;
    end if;
    -- M2c-6b-3a (N): a debit carrying none of our references at its amount, not booked nor linked
    if not v_debit and not v_returned then
      select min(u.booking_date) into v_unref_from from private.transfer_unreferenced_lines(t.id) u;
    end if;
  end if;
  -- review round 2 (D1): a day counts only once it is over
  v_over := v_to < private.paris_today();
  v_covered := v_over and private.statement_covers(f.debtor_bank_account_id, v_from, v_to);
  -- review round 2 (D2): one transfer only from a file the bank executed in part (computed only when it decides)
  if p_transfer_id is not null and not v_debit and v_unref_from is null and not v_ambiguous and v_covered then
    v_executed := v_returned or coalesce(p_file_executed, private.transfer_file_executed(f.id));
  end if;
  return jsonb_build_object(
    'window_from', v_from, 'needed_to_date', v_to, 'available_from', v_to + 1, 'window_over', v_over,
    'covered', v_covered, 'debit_seen', v_debit, 'batch_ambiguous', v_ambiguous,
    'unreferenced_debit', v_unref_from is not null, 'unreferenced_from', v_unref_from,
    'returned', v_returned and v_covered, 'file_executed', v_executed,
    'statement_to_date', (select max(s.to_date) from public.bank_statement s
                          where s.bank_account_id = f.debtor_bank_account_id and s.status = 'imported'),
    'statements', (select coalesce(jsonb_agg(s.id order by s.to_date, s.id), '[]') from public.bank_statement s
                   where s.bank_account_id = f.debtor_bank_account_id and s.status = 'imported'
                     and s.to_date >= v_from and s.from_date <= v_to),
    'refusal', case when v_debit then 'debit_seen' when v_unref_from is not null then 'unreferenced_debit_open'
                    when v_ambiguous then 'batch_ambiguous'
                    when not v_covered then 'no_statement_evidence'
                    when p_transfer_id is not null and not v_executed then 'file_not_executed' end,
    'checked_at', clock_timestamp());
end;
$$;

------------------------------------------------------------------------------------------
-- The redefinitions (each copied from its latest definition; only the lines its comment names change)
------------------------------------------------------------------------------------------

-- private.transfer_line_check, redefined from 20261118090000_switch_on_prerequisites.sql (line 514; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (E): a `payout` part on a payout cancelled out of a downloaded file whose run is still approved or sent and
-- holds it in its chain is that run's payout (the late predecessor): its run's live transfer, read here, decides what
-- the booking cancels or withdraws, or refuses it (reissue_in_downloaded_file, its file's number the detail;
-- already_debited once a transfer of the chain is debited); new pg_temp._tl columns lp, lp_y, lp_status, lp_cancel,
-- lp_cancel_e2e, lp_file, lp_file_number. (G) its return (`payout_returned` of it: exactly one payout booking, no return
-- booked) reverses its payout booking's entry. (J; OQ-82) an item another transfer's late execution already netted is
-- left out of a part's P. Review round 1: (DP-2, CSC-2) an entry kept unsplit derives a late predecessor's detail as
-- `payout` (the options' kind), and two debit details of one run's chain are unsplit_not_bookable; (DP-3) an unplanned
-- payout's pool also holds the return items of its run's chain; (LD-2) a payout's late date is judged at the earliest
-- debit naming another transfer of its run's chain when earlier. Review round 2 (ld2-reissue-return-pays-twice): the
-- return of a run's payout closes another transfer's open unplanned payout of the run's chain (the booking found through
-- private.transfer_chain_unplanned), and the return of a transfer whose unplanned payout that closed is the run's payout's
-- (private.transfer_return_partner); new pg_temp._tl column other_e2e (the other transfer the part names). Nothing else
-- changes.
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
        update pg_temp._tl t set c = r.tr_client, a = r.amount,
          late_date = case when r.kind = 'payout' then private.remittance_run_late_on(r.tr_run,
            case when exists (select 1 from private.transfer_chain(r.run_transfer) h where h.transfer_id <> r.transfer_id)
                 then coalesce((select p.paid_on
                                from private.remittance_chain_paid(r.run_transfer, l.id, r.transfer_id) p),
                               l.booking_date)
                 else l.booking_date end) end
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

-- private.transfer_line_options_of, redefined from 20261118090000_switch_on_prerequisites.sql (line 1173; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (E): a late predecessor (private.transfer_late_predecessor) is proposed as its run's payout (`payout` of
-- it), not « Virement hors reversement », on its own line (class E), in its lot (B), from an entry kept unsplit (U) and
-- as rule 3b's only candidate (N, O, E0); the preview's refusal (reissue_in_downloaded_file) is the refusal shown.
-- Review round 2 (ld2-reissue-return-pays-twice): a return naming a transfer whose unplanned payout a return of its
-- run's payout closed is proposed as that run's payout's return (private.transfer_return_partner); a return of the run's
-- payout while another transfer of its chain has an open unplanned payout is proposed as that one's return (through
-- private.transfer_unplanned_open and private.transfer_line_open_unplanned). Nothing else changes.
create or replace function private.transfer_line_options_of(p_bank_transaction_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  l public.bank_transaction;
  v_class text;
  v_kind text;
  v_returned text;
  v_pre text;
  v_x public.bank_transfer;
  v_parts jsonb;
  v_action text;
  v_props jsonb := '[]';
  v_refusal text;
  v_refusal_detail text;
  v_pending uuid;
  v_members jsonb;
  v_count integer;
  v_chk jsonb;
  v_cand record;
  v_open record;
  v_own uuid;
  v_client uuid;
  v_prev jsonb;
  v_lp boolean;
  v_partner public.bank_transfer;   -- review round 2: the run's payout a return of a closed copy comes back as
begin
  select * into l from public.bank_transaction where id = p_bank_transaction_id;
  if not found then
    return null;
  end if;
  v_class := private.transfer_line_class(l.id);
  select coalesce(d.released_kind, l.kind) into v_kind
  from (select 1) z left join public.bank_duplicate_resolution d on d.bank_transaction_id = l.id;
  v_returned := coalesce(l.original_end_to_end_id, l.end_to_end_id);
  v_pre := private.transfer_line_pre(l.id);
  v_count := (select m.v::integer from pg_temp._tl_meta m where m.k = 'member_count');
  if v_pre is not null then
    v_refusal := v_pre;
  elsif v_class = 'E' and l.direction = 'debit' then
    -- (CI scale fix) the transfer by its id alone, the servicer compared outside the probe
    select x.* into v_x
    from (select y.* from public.bank_transfer y where y.end_to_end_id = l.end_to_end_id offset 0) x
    where x.organization_id = l.organization_id;
    -- M2c-6b-3a-2 (E): a late predecessor is its run's payout
    v_action := case when v_x.status = 'cancelled' and private.transfer_late_predecessor(v_x.id) then v_x.kind
                     when v_x.status in ('cancelled', 'booked', 'returned') then 'unplanned_' || v_x.kind
                     else v_x.kind end;
    v_parts := jsonb_build_array(jsonb_build_object('kind', v_action, 'transfer_id', v_x.id,
                                                    'amount', least(v_x.amount_minor, l.amount_minor)::text));
    if l.amount_minor > v_x.amount_minor then
      v_parts := v_parts || jsonb_build_array(jsonb_build_object('kind', 'fee',
                                                                 'amount', (l.amount_minor - v_x.amount_minor)::text));
    end if;
    v_action := case when v_action like 'unplanned_%' then v_action else 'payout' end;
  elsif v_class = 'E' and l.direction = 'credit' then
    select x.* into v_x
    from (select y.* from public.bank_transfer y where y.end_to_end_id = v_returned offset 0) x
    where x.organization_id = l.organization_id;
    v_pending := (select x from private.transfer_late_lines(v_x.id) x limit 1);
    if v_pending is not null and not private.transfer_unplanned_open(v_x.id) then
      v_refusal := 'debit_pending';
    elsif private.transfer_unplanned_open(v_x.id) then
      v_pending := null;
      select o.* into v_open
      from private.transfer_line_open_unplanned(l.organization_id, v_x.id, null, null, 'unplanned_' || v_x.kind) o
      limit 1;
      v_parts := jsonb_build_array(jsonb_build_object('kind', 'unplanned_' || v_x.kind || '_returned',
                                                      'transfer_id', v_x.id, 'returns_line_id', v_open.line_id,
                                                      'amount', v_open.amount_minor::text));
      if v_kind = 'return' and l.amount_minor < v_open.amount_minor then
        v_parts := v_parts || jsonb_build_array(jsonb_build_object('kind', 'fee',
                                                                   'amount', (v_open.amount_minor - l.amount_minor)::text));
      end if;
      v_action := 'returned';
    elsif private.transfer_return_partner(v_x.id) is not null then
      -- review round 2 (ld2-reissue-return-pays-twice): this transfer's « Virement hors reversement » was closed by a
      -- return of its run's payout: this return is that payout's (the run's sums owed again)
      select y.* into v_partner from public.bank_transfer y where y.id = private.transfer_return_partner(v_x.id);
      v_parts := jsonb_build_array(jsonb_build_object('kind', 'payout_returned', 'transfer_id', v_partner.id,
                                                      'amount', v_partner.amount_minor::text));
      if v_kind = 'return' and l.amount_minor < v_partner.amount_minor then
        v_parts := v_parts || jsonb_build_array(jsonb_build_object(
                     'kind', 'fee', 'amount', (v_partner.amount_minor - l.amount_minor)::text));
      end if;
      v_action := 'returned';
    else
      v_parts := jsonb_build_array(jsonb_build_object('kind', v_x.kind || '_returned', 'transfer_id', v_x.id,
                                                      'amount', v_x.amount_minor::text));
      if v_kind = 'return' and l.amount_minor < v_x.amount_minor then
        v_parts := v_parts || jsonb_build_array(jsonb_build_object('kind', 'fee',
                                                                   'amount', (v_x.amount_minor - l.amount_minor)::text));
      end if;
      v_action := 'returned';
    end if;
  elsif v_class = 'B' then
    if (select m.v from pg_temp._tl_meta m where m.k = 'subset') = 'one' then
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'kind', case when l.direction = 'debit' then
                              case when x.status = 'in_file' and x.transfer_file_id = x.f then x.kind
                                   -- M2c-6b-3a-2 (E): a member that is a late predecessor
                                   when x.status = 'cancelled' and x.transfer_file_id = x.f
                                        and private.transfer_late_predecessor(p.transfer_id) then x.kind
                                   else 'unplanned_' || x.kind end
                            when p.unplanned_open then 'unplanned_' || x.kind || '_returned'
                            else x.kind || '_returned' end,
               'transfer_id', p.transfer_id,
               'returns_line_id', case when l.direction = 'credit' and p.unplanned_open then
                                    (select o.line_id from private.transfer_line_open_unplanned(
                                       l.organization_id, p.transfer_id, null, null, 'unplanned_' || x.kind) o limit 1)
                                  end,
               'amount', p.amount_minor::text)) order by p.ord), '[]')
      into v_parts
      from pg_temp._tl_pre p
      -- (CI scale fix) the member's file items by the member alone (a transfer is in a few files), the PmtInf compared
      -- outside: with both inside, a stale estimate of the PmtInf read its 500 items once per member
      cross join lateral (select y.kind, y.status, y.transfer_file_id,
                                 (select i.file_id
                                  from (select q.file_id, q.pmt_inf_id from public.transfer_file_item q
                                        where q.transfer_id = y.id offset 0) i
                                  where i.pmt_inf_id = l.payment_info_id limit 1) as f
                          from public.bank_transfer y where y.id = p.transfer_id offset 0) x
      where p.role in ('member', 'returnable') and p.in_subset;
      v_action := case when l.direction = 'credit' then 'returned' else 'lot' end;
    else
      v_refusal := 'batch_ambiguous';
    end if;
  elsif v_class = 'U' then
    -- the stored details' parts, as the check computes them (§3.4.12)
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'kind', case when d.v ->> 'direction' = 'debit' and x.status = 'cancelled'
                               and private.transfer_late_predecessor(x.id) then x.kind  -- M2c-6b-3a-2 (E)
                          when d.v ->> 'direction' = 'debit' and x.status in ('cancelled', 'booked', 'returned')
                            then 'unplanned_' || x.kind
                          when d.v ->> 'direction' = 'debit' then x.kind
                          when private.transfer_unplanned_open(x.id) then 'unplanned_' || x.kind || '_returned'
                          else x.kind || '_returned' end,
             'transfer_id', x.id,
             'returns_line_id', case when d.v ->> 'direction' = 'credit' and private.transfer_unplanned_open(x.id) then
                                  (select o.line_id from private.transfer_line_open_unplanned(
                                     l.organization_id, x.id, null, null, 'unplanned_' || x.kind) o limit 1) end,
             'amount', d.v ->> 'amount_minor')) order by d.o), '[]')
    into v_parts
    from jsonb_array_elements(case when jsonb_typeof(l.unsplit_details) = 'array' then l.unsplit_details
                                   else '[]'::jsonb end) with ordinality d (v, o)
    left join lateral (select y.id, y.kind, y.status
                       from (select q.id, q.kind, q.status, q.organization_id, q.debtor_bank_account_id
                             from public.bank_transfer q where q.end_to_end_id = d.v ->> 'id' offset 0) y
                       where y.organization_id = l.organization_id and y.debtor_bank_account_id = l.bank_account_id) x
      on true;
    -- (critic2 CSO2-10) a detail naming nothing of this servicer and account is never shown: no parts proposed.
    -- (M2c-6b-2b deferred tests) a stored detail without its amount is unsplit_detail_missing, as the check reads it
    -- first (§3.4.12): its part would carry no amount, and the preview refused it bad_request
    if l.unsplit_details is null or jsonb_array_length(v_parts) = 0
       or exists (select 1 from jsonb_array_elements(v_parts) p where p ->> 'transfer_id' is null)
       or exists (select 1 from jsonb_array_elements(l.unsplit_details) d where d ->> 'amount_minor' is null) then
      v_parts := null;
      v_refusal := case when l.unsplit_details is null
                          or exists (select 1 from jsonb_array_elements(l.unsplit_details) d
                                     where d ->> 'amount_minor' is null)
                        then 'unsplit_detail_missing' else 'unsplit_not_bookable' end;
    elsif l.direction = 'debit' and l.unsplit_ours = 1 and l.unsplit_detail_count = 1
          and l.amount_minor > (v_parts -> 0 ->> 'amount')::bigint then
      v_parts := v_parts || jsonb_build_array(jsonb_build_object(
                   'kind', 'fee', 'amount', (l.amount_minor - (v_parts -> 0 ->> 'amount')::bigint)::text));
    end if;
    v_action := 'detail';
  elsif v_class in ('N', 'O', 'E0') and l.direction = 'debit' then
    select count(*) into v_count from pg_temp._tl_pre p where p.role = 'candidate';
    if v_count > 1 then
      v_refusal := 'line_ambiguous';
    elsif v_count = 1 then
      select p.* into v_cand from pg_temp._tl_pre p where p.role = 'candidate';
      if v_cand.cand = 'ii' then
        v_refusal := 'payout_in_flight_matches';   -- the refund's M2b link (link_debit), not this command
      elsif v_cand.cand = 'iv' and v_cand.kind <> 'sweep' then
        v_refusal := 'cancelled_transfer_matches';   -- M2c-6b-3a (K): a cancelled refund's late debit (S25)
      else
        -- M2c-6b-3a-2 (E): rule 3b's only candidate a cancelled payout (iii) that is a late predecessor: its run's
        -- payout
        v_lp := v_cand.cand = 'iii' and v_cand.status = 'cancelled'
                and private.transfer_late_predecessor(v_cand.transfer_id);
        v_action := case when v_lp then 'payout' when v_cand.cand = 'iii' then 'unplanned_payout'
                         when v_cand.cand = 'iv' then 'unplanned_sweep'
                         else 'payout' end;
        v_parts := jsonb_build_array(jsonb_build_object(
                     'kind', case when v_lp then 'payout' when v_cand.cand = 'iii' then 'unplanned_payout'
                                  when v_cand.cand = 'iv' then 'unplanned_sweep' else v_cand.kind end,
                     'transfer_id', v_cand.transfer_id, 'amount', l.amount_minor::text));
      end if;
    else
      select a.client_organization_id into v_client from public.client_payout_account a
      where a.organization_id = l.organization_id and a.iban = l.counterparty_iban and a.currency = l.currency
        and a.confirmed_at is not null and a.status in ('active', 'returned', 'retired')
      order by a.client_organization_id limit 1;
      select o.id into v_own from public.bank_account o
      where o.organization_id = l.organization_id and o.purpose = 'own' and o.status = 'active'
        and o.iban = l.counterparty_iban and o.currency = l.currency;
      if v_client is not null then
        v_action := 'unplanned_payout';
        v_parts := jsonb_build_array(jsonb_build_object('kind', 'unplanned_payout', 'client_id', v_client,
                                                        'amount', l.amount_minor::text));
      elsif v_own is not null then
        v_action := 'unplanned_sweep';
        v_parts := jsonb_build_array(jsonb_build_object('kind', 'unplanned_sweep', 'amount', l.amount_minor::text));
      end if;
    end if;
    v_count := null;
  elsif v_class in ('N', 'O', 'E0') and l.direction = 'credit' and v_kind = 'return' and l.counterparty_iban is not null
  then
    -- (critic2 ML-11) the bank's own return, without our reference, from the IBAN an open unplanned payout went to at
    -- this amount: the largest advance first (ties: the earliest line)
    select o.* into v_open from (
      select k.transfer_id, x.kind as tr_kind, q.*
      from (select y.transfer_id, y.entry_id, y.kind from public.bank_line_booking y
            where y.organization_id = l.organization_id and y.kind = 'unplanned_payout' and y.amount_minor = l.amount_minor
            offset 0) k
      left join lateral (select z.kind, z.payee_iban from public.bank_transfer z where z.id = k.transfer_id offset 0) x
        on true
      cross join lateral (select e.client_organization_id from public.ledger_entry e where e.id = k.entry_id offset 0) e
      cross join lateral private.transfer_line_open_unplanned(l.organization_id, k.transfer_id,
                                                              e.client_organization_id, l.counterparty_iban,
                                                              'unplanned_payout') q
      where q.entry_id = k.entry_id and coalesce(x.payee_iban, q.iban) = l.counterparty_iban) o
    order by o.advance_minor desc, o.line_date, o.line_id limit 1;
    if v_open.line_id is not null then
      v_action := 'returned';
      v_parts := jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                   'kind', 'unplanned_payout_returned', 'transfer_id', v_open.transfer_id,
                   'client_id', case when v_open.transfer_id is null then v_open.client_organization_id end,
                   'returns_line_id', v_open.line_id, 'amount', v_open.amount_minor::text)));
    end if;
  end if;

  -- each proposal checked as the preview checks it: offered only when it may be booked (review CSR-3: on the pre-read
  -- above, for this same line — the lot's subset search runs once per call)
  if v_parts is not null and jsonb_array_length(v_parts) > 0 and v_refusal is null then
    v_prev := private.transfer_line_preview_of(l.id, v_parts, false);
    if (v_prev ->> 'ok')::boolean then
      v_props := jsonb_build_array(jsonb_build_object('action', v_action, 'request', v_parts,
                                                      'parts', v_prev -> 'parts', 'preview', v_prev));
    else
      v_refusal := v_prev ->> 'why';
      v_refusal_detail := v_prev ->> 'detail';
      if v_refusal = 'debit_pending' then
        v_pending := v_refusal_detail::uuid;
      end if;
    end if;
    -- (pg_temp._tl_pre is this line's: the members below are the pre-read's)
  end if;
  if v_class = 'B' and coalesce(v_pre, '') <> 'lot_too_large' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'transfer_id', p.transfer_id, 'kind', x.kind, 'status', x.status, 'amount_minor', p.amount_minor::text,
             'run_number', ru.number, 'client_name', o.legal_name, 'end_to_end_id', x.end_to_end_id,
             'in_proposal', p.in_subset and jsonb_array_length(v_props) > 0) order by p.ord), '[]')
    into v_members
    from (select * from pg_temp._tl_pre p where p.role in ('member', 'returnable') order by p.ord limit 50) p
    cross join lateral (select y.kind, y.status, y.end_to_end_id, y.run_id, y.client_organization_id
                        from public.bank_transfer y where y.id = p.transfer_id offset 0) x
    left join lateral (select q.number from public.remittance_run q where q.id = x.run_id offset 0) ru on true
    left join lateral (select q.legal_name from public.organization q where q.id = x.client_organization_id offset 0) o
      on true;
  end if;
  return jsonb_build_object(
    'class', v_class, 'kind', v_kind, 'direction', l.direction, 'amount_minor', l.amount_minor::text,
    -- M2c-6b-2c (§7.3): the line's facts the sheets word
    'booking_date', l.booking_date, 'charges_minor', l.charges_minor::text,
    'counterparty_iban_end', right(l.counterparty_iban, 4),
    'unsplit_ours', l.unsplit_ours, 'proposals', v_props, 'members', v_members,
    'member_count', case when v_class = 'B' then (select m.v::integer from pg_temp._tl_meta m where m.k = 'member_count')
                    end,
    'refusal', v_refusal, 'refusal_detail', v_refusal_detail, 'pending_line_id', v_pending,
    -- (review 6b-2c pages-5) the pending debit held as a suspected duplicate, undecided: it waits in « Doublons
    -- possibles », not « À classer »
    'pending_held', coalesce((select q.kind = 'suspected_duplicate'
                                     and not exists (select 1 from public.bank_duplicate_resolution d
                                                     where d.bank_transaction_id = q.id)
                              from public.bank_transaction q where q.id = v_pending), false));
end;
$$;

-- private.transfer_line_locks, redefined from 20261117105000_transfer_line_ops_fixes.sql (line 47; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (E): after the remit lock, a late predecessor's run's live transfer is re-read (a generation that committed
-- since the keys were collected moved it into a file), the file it is in locked FOR UPDATE while not downloaded yet, and
-- that transfer and the file's transfers added to the transfers locked (step 9). Same order: runs → … → remit → files →
-- transfers. Nothing else changes.
create or replace function private.transfer_line_locks(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  l public.bank_transaction;
  v_step text := 'collect';
begin
  select * into l from public.bank_transaction where id = p_line_id;
  drop table if exists pg_temp._tl_keys;
  create temp table _tl_keys (transfer_id uuid primary key) on commit drop;
  insert into pg_temp._tl_keys select r.transfer_id from pg_temp._tl_req r where r.transfer_id is not null
  on conflict do nothing;
  insert into pg_temp._tl_keys select p.transfer_id from pg_temp._tl_pre p on conflict do nothing;
  insert into pg_temp._tl_keys
  select y.id
  from jsonb_array_elements(case when jsonb_typeof(l.unsplit_details) = 'array' then l.unsplit_details
                                 else '[]'::jsonb end) d
  cross join lateral (select q.id, q.organization_id, q.debtor_bank_account_id from public.bank_transfer q
                      where q.end_to_end_id = d ->> 'id' offset 0) y
  where y.organization_id = l.organization_id and y.debtor_bank_account_id = l.bank_account_id
  on conflict do nothing;
  insert into pg_temp._tl_keys
  select k.transfer_id
  from pg_temp._tl_req r
  cross join lateral (select q.transfer_id, q.kind from public.bank_line_booking q
                      where q.bank_transaction_id = r.returns_line_id offset 0) k
  where r.returns_line_id is not null and k.transfer_id is not null and k.kind in ('unplanned_payout', 'unplanned_sweep')
  on conflict do nothing;
  drop table if exists pg_temp._tl_lock_clients;
  create temp table _tl_lock_clients (client_organization_id uuid primary key) on commit drop;
  insert into pg_temp._tl_lock_clients
  select x.client_organization_id from public.bank_transfer x
  where x.id = any (array(select k.transfer_id from pg_temp._tl_keys k)) and x.kind = 'payout'
    and x.client_organization_id is not null
  union
  select r.client_id from pg_temp._tl_req r where r.client_id is not null
  union
  select e.client_organization_id
  from pg_temp._tl_req r
  cross join lateral (select q.entry_id, q.kind from public.bank_line_booking q
                      where q.bank_transaction_id = r.returns_line_id offset 0) k
  cross join lateral (select q.client_organization_id from public.ledger_entry q where q.id = k.entry_id offset 0) e
  where r.returns_line_id is not null and k.kind = 'unplanned_payout' and e.client_organization_id is not null
  on conflict do nothing;
  drop table if exists pg_temp._tl_locked_runs;
  create temp table _tl_locked_runs (run_id uuid primary key) on commit drop;
  insert into pg_temp._tl_locked_runs
  select distinct x.run_id from public.bank_transfer x
  where x.id = any (array(select k.transfer_id from pg_temp._tl_keys k)) and x.run_id is not null
  on conflict do nothing;
  insert into pg_temp._tl_locked_runs
  select y.id
  from pg_temp._tl_lock_clients c
  cross join lateral (select q.id from public.remittance_run q
                      where q.client_organization_id = c.client_organization_id and q.currency = l.currency
                        and q.status in ('draft', 'approved', 'sent') offset 0) y
  on conflict do nothing;

  -- 1. runs
  v_step := 'runs';
  perform 1 from public.remittance_run r
  where r.id = any (array(select k.run_id from pg_temp._tl_locked_runs k))
  order by r.id for update;
  -- 2. the payout accounts a return marks returned
  v_step := 'accounts';
  perform 1 from public.client_payout_account a
  where a.id = any (array(
          select ru.payout_account_id
          from pg_temp._tl_keys k
          cross join lateral (select q.run_id from public.bank_transfer q where q.id = k.transfer_id offset 0) x
          cross join lateral (select q.payout_account_id from public.remittance_run q where q.id = x.run_id offset 0) ru
          where l.direction = 'credit' or coalesce(l.unsplit_ours, 0) > 0
          union
          select y.id
          from pg_temp._tl_req r
          cross join lateral (select q.counterparty_iban from public.bank_transaction q
                              where q.id = r.returns_line_id offset 0) q
          cross join lateral (select q2.id from public.client_payout_account q2
                              where q2.client_organization_id = r.client_id and q2.iban = q.counterparty_iban
                              offset 0) y
          where r.kind = 'unplanned_payout_returned' and r.transfer_id is null))
  order by a.id for no key update;
  -- 3. the bank accounts
  v_step := 'bank_accounts';
  perform 1 from public.bank_account a
  where a.id = any (array(
          select l.bank_account_id
          union
          select x.debtor_bank_account_id from public.bank_transfer x
          where x.id = any (array(select k.transfer_id from pg_temp._tl_keys k))
          union
          select x.creditor_bank_account_id from public.bank_transfer x
          where x.id = any (array(select k.transfer_id from pg_temp._tl_keys k)) and x.creditor_bank_account_id is not null
          union
          select o.id from public.bank_account o
          where o.organization_id = l.organization_id and o.purpose = 'own' and o.iban = l.counterparty_iban))
  order by a.id for share;
  -- 4. the payments the payout parts' breach rows may name
  v_step := 'payments';
  perform 1 from public.payment p
  where p.id = any (array(
          select distinct y.payment_id
          from pg_temp._tl_keys k
          cross join lateral (select q.run_id, q.kind from public.bank_transfer q where q.id = k.transfer_id offset 0) x
          cross join lateral (select q.payment_id, q.amount_minor, q.released, q.latest_execution_date
                              from public.remittance_line q where q.run_id = x.run_id offset 0) y
          where x.kind = 'payout' and l.direction = 'debit' and y.amount_minor > 0 and not y.released
            and y.payment_id is not null and y.latest_execution_date < l.booking_date))
  order by p.id for key share;
  -- 5. the allocation lock
  v_step := 'allocation';
  perform pg_advisory_xact_lock(hashtext('payments:' || l.organization_id::text));
  -- 6. the bank lines
  v_step := 'lines';
  perform 1 from public.bank_transaction t
  where t.id = any (array(select l.id union select r.returns_line_id from pg_temp._tl_req r
                                          where r.returns_line_id is not null))
  order by t.id for no key update;
  -- 7. the remit lock
  v_step := 'allocation';
  perform pg_advisory_xact_lock(hashtext('remit:' || l.organization_id::text));
  -- M2c-6b-3a-2 (E): a late predecessor's live end, re-read after the remit lock (a generation files under that lock,
  -- and takes no run lock: one that committed since the keys were read moved it into its file) — the run's transfer
  -- (the run is locked, step 1: its pointer no longer moves) and the file it is in when not downloaded yet: that file
  -- FOR UPDATE, in id order, before the FOR SHARE set below; the transfer and every transfer of that file FOR UPDATE
  -- with the keys (step 9). The check reads them under these locks.
  v_step := 'files';
  drop table if exists pg_temp._tl_lp;
  create temp table _tl_lp on commit drop as
  select distinct y.id as transfer_id, y.transfer_file_id as file_id
  from pg_temp._tl_keys k
  cross join lateral (select q.id, q.run_id, q.kind, q.status from public.bank_transfer q
                      where q.id = k.transfer_id offset 0) x
  cross join lateral (select q.transfer_id from public.remittance_run q where q.id = x.run_id offset 0) ru
  cross join lateral (select q.id, q.transfer_file_id from public.bank_transfer q where q.id = ru.transfer_id offset 0) y
  where x.kind = 'payout' and x.status = 'cancelled' and y.id <> x.id;
  insert into pg_temp._tl_keys select p.transfer_id from pg_temp._tl_lp p on conflict do nothing;
  perform 1 from public.transfer_file f
  where f.id = any (array(select p.file_id from pg_temp._tl_lp p where p.file_id is not null))
    and f.download_count = 0
  order by f.id for update;
  insert into pg_temp._tl_keys
  select y.id
  from pg_temp._tl_lp p
  cross join lateral (select q.download_count from public.transfer_file q where q.id = p.file_id offset 0) f
  cross join lateral (select q.id from public.bank_transfer q where q.transfer_file_id = p.file_id offset 0) y
  where p.file_id is not null and f.download_count = 0
  on conflict do nothing;
  -- 8. the files
  v_step := 'files';
  perform 1 from public.transfer_file f
  where f.id = any (array(
          select x.transfer_file_id from public.bank_transfer x
          where x.id = any (array(select k.transfer_id from pg_temp._tl_keys k)) and x.transfer_file_id is not null
          union
          -- (M2c-6b-2b deferred tests) the PmtInf's files of the line's account only: the line's PmtInfId is the
          -- bank's data, and another servicer's lot may carry the same one (CSO-5: never a row of another servicer)
          select i.file_id
          from (select y.file_id from public.transfer_file_item y where y.pmt_inf_id = l.payment_info_id offset 0) i
          cross join lateral (select q.debtor_bank_account_id from public.transfer_file q where q.id = i.file_id
                              offset 0) q
          where q.debtor_bank_account_id = l.bank_account_id
          union
          select x.transfer_file_id
          from pg_temp._tl_locked_runs k
          cross join lateral (select q.transfer_id from public.remittance_run q where q.id = k.run_id offset 0) ru
          cross join lateral (select q.transfer_file_id from public.bank_transfer q where q.id = ru.transfer_id offset 0) x
          where x.transfer_file_id is not null))
  order by f.id for share;
  -- 9. the transfers
  v_step := 'transfers';
  perform 1 from public.bank_transfer x
  where x.id = any (array(select k.transfer_id from pg_temp._tl_keys k))
  order by x.id for update;
exception when lock_not_available then
  raise exception 'transfer line booking refused: %', case when v_step = 'allocation' then 'allocation_busy'
                                                          else 'busy' end
    using errcode = '55P03',
          hint = case when v_step = 'allocation'
                      then 'An allocation or an approval of this servicer holds the lock: retry in a few seconds.'
                      else 'This line or one of its transfers is being processed: retry in a moment.' end;
end;
$$;

-- private.transfer_line_text, redefined from 20261117100000_transfer_line_ops.sql (line 1187; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (E): a late predecessor's part appends `:lp:<its run's live transfer>:<its status>:<its file or ->` —
-- moved between the sheet and the command (filed, withdrawn, cancelled), the booking is refused split_changed. The
-- other parts' text is unchanged.
create or replace function private.transfer_line_text()
returns text
language plpgsql
stable
set search_path = ''
as $$
begin
  return coalesce((select string_agg(t.kind || ':' || coalesce(coalesce(t.transfer_id, t.client_id)::text, '') || ':'
                                     || t.amount || ':' || t.p || ':' || t.adv || ':'
                                     || coalesce(t.returns_line_id::text, '')
                                     -- M2c-6b-3a-2 (E): a late predecessor's live transfer, its status and its file
                                     || case when t.lp then ':lp:' || t.lp_y || ':' || t.lp_status || ':'
                                                            || coalesce(t.lp_file::text, '-') else '' end,
                                     ';' order by t.n)
                   from pg_temp._tl t), '')
         || '|drafts:' || coalesce((select string_agg(d.run_id::text, ',' order by d.run_id)
                                    from pg_temp._tl_drafts d), '');
end;
$$;

-- private.transfer_line_parts_json, redefined from 20261117110000_transfer_line_pages.sql (line 1108; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (E): a late predecessor's part also carries late_predecessor, cancels_transfer_id and
-- cancels_end_to_end_id (the re-issue the booking cancels; null when none), supersedes_file_number (the file it
-- withdraws) and replacement_status — keys only on that part (the others' unchanged). Review round 1 (DP-3): an
-- unplanned payout's part also carries run_status. Review round 2 (ld2-reissue-return-pays-twice): a return part naming
-- another transfer of the run's chain carries closes_end_to_end_id (the « Virement hors reversement » a return of the
-- run's payout closes) or returned_end_to_end_id (the transfer whose return is the run's payout's) — keys only on that
-- part. Nothing else changes.
create or replace function private.transfer_line_parts_json()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return (select coalesce(jsonb_agg(jsonb_build_object(
           'n', t.n, 'kind', t.kind, 'transfer_id', t.transfer_id, 'client_id', coalesce(t.client_id, t.c),
           'returns_line_id', t.returns_line_id, 'amount_minor', t.amount::text, 'paid_minor', t.p::text,
           'advance_minor', t.adv::text, 'p_bound', t.p_bound, 'late', t.late, 'end_to_end_id', t.tr_e2e,
           'run_id', t.tr_run, 'run_number', t.run_number, 'status', t.tr_status,
           'client_name', (select o.legal_name from public.organization o where o.id = coalesce(t.c, t.client_id)))
           -- M2c-6b-3a-2 (E): a late predecessor's facts, on its part only (the sheet words what the booking cancels)
           || case when t.lp then jsonb_build_object(
                'late_predecessor', true, 'cancels_transfer_id', t.lp_cancel, 'cancels_end_to_end_id', t.lp_cancel_e2e,
                'supersedes_file_number', t.lp_file_number, 'replacement_status', t.lp_status) else '{}'::jsonb end
           -- review round 1 (DP-3): an unplanned payout's run status (the sheet names what its P nets: a cancelled
           -- run's released items, or the items the return of a booked run's payout put back)
           || case when t.kind = 'unplanned_payout' then jsonb_build_object(
                'run_status', (select r.status from public.remittance_run r where r.id = t.tr_run)) else '{}'::jsonb end
           -- review round 2 (ld2-reissue-return-pays-twice): the other transfer of the run's chain the part concerns
           || case when t.other_e2e is null then '{}'::jsonb
                   when t.kind = 'unplanned_payout_returned' then jsonb_build_object('closes_end_to_end_id', t.other_e2e)
                   else jsonb_build_object('returned_end_to_end_id', t.other_e2e) end
           || jsonb_build_object(
           'settlement_minor', case when t.kind = 'payout' then
             (select coalesce(r.settlement_minor, 0)::text from public.remittance_run r where r.id = t.tr_run) end,
           -- (review 6b-2c money-3, legal-deadlines-2) the date a late debit's breach is recorded against, as the check
           -- found it by the booking's rule (pg_temp._tl.late_date: a line whose delay cannot be met by its one-month
           -- date); null when the debit is not late
           'latest_execution_date', case when t.kind = 'payout' then t.late_date end,
           'share_after_minor', case when t.kind = 'unplanned_sweep' then
             (select (-coalesce(sum(lp.amount_minor), 0)
                      - (select coalesce(sum(u.amount), 0) from pg_temp._tl u
                         where u.kind = 'unplanned_sweep' and u.n <= t.n))::text
              from public.bank_account b
              join public.ledger_account la on la.organization_id = b.organization_id and la.book = 'due_to_servicer'
                and la.currency = b.currency
              join public.ledger_posting lp on lp.ledger_account_id = la.id
              where b.id = t.own_bank) end,
           'payout_iban_end', (select right(a.iban, 4) from public.client_payout_account a where a.id = t.payout_account),
           'blocks_account', coalesce((select a.status = 'active' from public.client_payout_account a
                                       where a.id = t.payout_account), false),
           'returns_on', (select q.booking_date from public.bank_transaction q where q.id = t.returns_line_id))
           order by t.n), '[]')
  from pg_temp._tl t);
end;
$$;

-- private.transfer_line_post, redefined from 20261117100000_transfer_line_ops.sql (line 1487; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (E): before the planned parts, a late predecessor's live end is withdrawn — its file, not downloaded yet,
-- superseded (private.transfer_file_release), then the re-issue cancelled; (G) a returned late predecessor stays
-- cancelled. Nothing else changes.
create or replace function private.transfer_line_post(p_line_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
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
    insert into public.client_advance (id, organization_id, client_organization_id, currency, amount_minor, cause,
                                       cause_entry_id, entry_id, bank_transaction_id, transfer_id, p_bound)
    select t.adv_id, l.organization_id, t.c, l.currency, t.adv, 'double_payout', t.entry_id, t.adv_entry_id, l.id,
           t.transfer_id, t.p_bound
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

-- private.bank_booking_post_rows, redefined from 20261117100000_transfer_line_ops.sql (line 2496; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (E): the update that books the transfers skips a cancelled one (a late predecessor keeps its status and no
-- entry: bank_transfer_guard keeps cancelled terminal); its run is booked, settled and covered as any payout's. The job
-- never books a cancelled transfer (its review cancelled_transfer_debited). Review round 1 (LD-2): a payout's R124-6
-- rows are judged at the earliest debit naming another transfer of its run's chain when earlier than its line. Review
-- round 4: at the date the run's chain paid the client and stayed paid (private.remittance_chain_paid), this line its
-- payout's execution. Nothing else changes.
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
  with late as materialized (
    select b.tr_run as run_id, p.paid_on as line_date, ru.organization_id, ru.client_organization_id,
           ru.requested_execution_date, ru.late_reason, l.ledger_entry_id, l.payment_id, l.deadline,
           l.latest_execution_date, l.unmeetable, l.encaissement_date, l.kind
    from pg_temp._bb b
    cross join lateral (select q.organization_id, q.client_organization_id, q.requested_execution_date, q.late_reason,
                               q.transfer_id
                        from public.remittance_run q where q.id = b.tr_run offset 0) ru
    cross join lateral (select case when exists (select 1 from private.transfer_chain(ru.transfer_id) h
                                                 where h.transfer_id is distinct from b.transfer_id)
                                    then coalesce((select c.paid_on
                                                   from private.remittance_chain_paid(ru.transfer_id,
                                                                                      b.bank_transaction_id,
                                                                                      b.transfer_id) c),
                                                  b.line_date)
                                    else b.line_date end as paid_on) p
    cross join lateral private.remittance_run_late_lines(b.tr_run, p.paid_on) l
    where b.kind = 'payout'),
  m as materialized (
    select k.e_date, d.*
    from (select distinct l.encaissement_date as e_date from late l
          where l.unmeetable and l.encaissement_date is not null) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, 30) d)
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

-- private.bank_line_booking_guard, redefined from 20261117100000_transfer_line_ops.sql (line 2197; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (G): a `payout_returned` booking of a transfer with no entry of its own (a late predecessor) reverses the
-- entry of its `payout` booking. Review round 2 (ld2-reissue-return-pays-twice): an `unplanned_payout_returned` booking
-- of a payout may reverse the unplanned payout of another payout of the same run (the return of the run's payout
-- closing another copy). Nothing else changes.
create or replace function private.bank_line_booking_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
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
           (select y.run_id from public.bank_line_booking k join public.bank_transfer y on y.id = k.transfer_id
            where k.entry_id = e.reverses_entry_id) as reversed_run,
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

-- private.transfer_line_returnable, redefined from 20261117100000_transfer_line_ops.sql (line 254; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (F, G): a lot credit's returnable members also hold a late predecessor booked as its run's payout from
-- that file and not returned. Nothing else changes.
create or replace function private.transfer_line_returnable(p_line_id uuid)
returns table (seq integer, transfer_id uuid, kind text, status text, amount_minor bigint, unplanned_open boolean,
               client_organization_id uuid, run_id uuid, end_to_end_id text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select m.seq, m.transfer_id, m.kind, m.status, m.amount_minor, u.open, m.client_organization_id, m.run_id,
         m.end_to_end_id
  from private.transfer_line_members(p_line_id) m
  cross join lateral (select private.transfer_unplanned_open(m.transfer_id) as open) u
  where m.kind in ('payout', 'sweep')
    and ((m.status = 'booked' and m.transfer_file_id = m.file_id) or u.open
         -- M2c-6b-3a-2 (F, G): a late predecessor booked as its run's payout, from that file, not returned
         or (m.status = 'cancelled' and m.kind = 'payout' and m.transfer_file_id = m.file_id
             and exists (select 1 from public.bank_line_booking k where k.transfer_id = m.transfer_id
                           and k.kind = 'payout')
             and not exists (select 1 from public.bank_line_booking k where k.transfer_id = m.transfer_id
                               and k.kind = 'payout_returned')))
  order by m.seq;
$$;

-- private.pending_item_deadlines, redefined from 20261117100000_transfer_line_ops.sql (line 2344; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (F): the planned branch of a returned payout also follows a late predecessor's return (the reversed entry
-- is its payout booking's): its item keeps its run's R124-6 date (a missing deadline would write no breach row). The
-- worker's twin, jobs/remittances.py HELD_TO_SQL, alike (parity test). Nothing else changes.
create or replace function private.pending_item_deadlines(p_organization_id uuid,
                                                          p_unreserved_only boolean default false)
returns table (ledger_entry_id uuid, client_organization_id uuid, currency char(3), amount_minor bigint,
               draft_run_id uuid, payment_id uuid, monitored boolean, encaissement_date date, max_days integer,
               deadline date, latest_execution_date date, alert_soon_date date, alert_critical_date date,
               unmeetable boolean, check_deadline date, check_latest_execution_date date, check_alert_soon_date date,
               check_alert_critical_date date, out_of_horizon boolean)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with items as materialized (
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, e.payment_id,
           x.e_date, coalesce(t.days, 30) as days, f.mandate_id
    from private.remittance_pending q
    join lateral (select le.payment_id, le.account_id from public.ledger_entry le
                  where le.id = q.ledger_entry_id offset 0) e on true
    left join lateral (select private.encaissement_date(p.booking_date, p.value_date) as e_date,
                              coalesce(e.account_id, p.account_id) as account_id
                       from public.payment p where p.id = e.payment_id offset 0) x on true
    left join lateral (select pf.mandate_id
                       from public.account a join public.portfolio pf on pf.id = a.portfolio_id
                       where a.id = coalesce(x.account_id, e.account_id) offset 0) f on true
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = f.mandate_id and mt.valid_from <= x.e_date
                         and (mt.valid_to is null or x.e_date < mt.valid_to)
                       limit 1) t on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind in ('allocation', 'forward')
      and (not p_unreserved_only or q.draft_run_id is null)
    union all
    -- M2c-6b-1 (design §9.2, Q7's default): a payout that came back is held to the earliest date of the returned run's
    -- positive live lines — its E and its mandate's delay, those of the line with the earliest latest execution date
    -- (the reversal → the reversed remittance → its transfer → its run → its lines, each by key). A line that is itself
    -- a re-proposed payout (returned a second time) has no mandate (the worker's prepare: no file, no mandate's gross)
    -- but the terms version it was held to: that version gives the delay and the mandate (monitored), as the worker's
    -- prepare reads it (jobs/remittances.py _held_to; review M2c-6b-1 legal-texts#1 item 3, parity)
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, rl.payment_id,
           rl.encaissement_date, coalesce(t.days, ti.days, 30), coalesce(rl.mandate_id, ti.mandate_id)
    from private.remittance_pending q
    cross join lateral (select le.reverses_entry_id from public.ledger_entry le
                        where le.id = q.ledger_entry_id offset 0) e
    cross join lateral (select re.source_id from public.ledger_entry re
                        where re.id = e.reverses_entry_id and re.entry_type = 'remittance'
                          and re.source_type = 'bank_transfer' offset 0) re
    cross join lateral (select bt.run_id from public.bank_transfer bt
                        where bt.id = case when pg_input_is_valid(re.source_id, 'uuid') then re.source_id::uuid end
                          -- M2c-6b-2b (critic F11, L4): the transfer's own planned remittance only — M2c-6b-3a-2
                          -- (F): a late predecessor's is its payout booking's entry (by the booking's unique entry)
                          and (bt.entry_id = e.reverses_entry_id
                               or exists (select 1 from public.bank_line_booking k
                                          where k.entry_id = e.reverses_entry_id and k.kind = 'payout'
                                            and k.transfer_id = bt.id))
                        offset 0) bt
    cross join lateral (select l.payment_id, l.encaissement_date, l.mandate_id, l.mandate_terms_id
                        from public.remittance_line l
                        where l.run_id = bt.run_id and l.amount_minor > 0 and not l.released
                          and l.latest_execution_date is not null and l.encaissement_date is not null
                        order by l.latest_execution_date, l.line_no limit 1) rl
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.mandate_id, mt.remittance_max_days as days from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id offset 0) ti on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind = 'payout_returned'
      and (not p_unreserved_only or q.draft_run_id is null)
    union all
    -- M2c-6b-2b (critic2 ML-2): the re-owed item of an unplanned remittance returned after a run froze the items its
    -- P paid (their clocks ended at that run, the −A row netting them) is held like a planned return: to the earliest
    -- latest execution date of those items' live lines — the reversal → the reversed remittance → its attributions
    -- (private.unplanned_paid_item by booking_entry_id) → each item's live line (remittance_line_live_uq), each by key —
    -- its E, mandate and terms version as the planned branch reads them. While those items are still pending: no line,
    -- no deadline (critic F11, L4: they keep their own clocks, Q15's default). Parity: jobs/remittances.py _held_to
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, rl.payment_id,
           rl.encaissement_date, coalesce(t.days, ti.days, 30), coalesce(rl.mandate_id, ti.mandate_id)
    from private.remittance_pending q
    cross join lateral (select le.reverses_entry_id from public.ledger_entry le
                        where le.id = q.ledger_entry_id offset 0) e
    cross join lateral (select re.id from public.ledger_entry re
                        where re.id = e.reverses_entry_id and re.entry_type = 'remittance' offset 0) re
    cross join lateral (select l.payment_id, l.encaissement_date, l.mandate_id, l.mandate_terms_id
                        from (select u.ledger_entry_id from private.unplanned_paid_item u
                              where u.booking_entry_id = re.id offset 0) u
                        cross join lateral (select x.payment_id, x.encaissement_date, x.mandate_id, x.mandate_terms_id,
                                                   x.latest_execution_date, x.run_id, x.line_no, x.amount_minor
                                            from public.remittance_line x
                                            where x.ledger_entry_id = u.ledger_entry_id and not x.released offset 0) l
                        where l.amount_minor > 0 and l.latest_execution_date is not null
                          and l.encaissement_date is not null
                        order by l.latest_execution_date, l.run_id, l.line_no limit 1) rl
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.mandate_id, mt.remittance_max_days as days from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id offset 0) ti on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind = 'payout_returned'
      and (not p_unreserved_only or q.draft_run_id is null)),
  mon as (
    select k.mandate_id, exists (select 1 from public.mandate_terms v where v.mandate_id = k.mandate_id) as monitored
    from (select distinct i.mandate_id from items i where i.mandate_id is not null) k),
  -- one deadline per distinct (E, delay), whatever the estimates (review perf#0, round 2: an inlined CTE was joined
  -- first and its deadline computed once per item when the queue had no statistics)
  dl as materialized (
    select k.e_date, k.days, d.*
    from (select distinct i.e_date, i.days from items i where i.e_date is not null) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, k.days) d),
  m as materialized (   -- one month, for the delays that cannot be met: once per distinct E
    select k.e_date, d.*
    from (select distinct dl.e_date from dl where dl.unmeetable) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, 30) d)
  select i.ledger_entry_id, i.client_organization_id, i.currency, i.amount_minor, i.draft_run_id, i.payment_id,
         coalesce(mon.monitored, false), i.e_date, i.days, dl.deadline, dl.latest_execution_date, dl.alert_soon_date,
         dl.alert_critical_date, coalesce(dl.unmeetable, false),
         case when dl.unmeetable then m.deadline else dl.deadline end,
         case when dl.unmeetable then m.latest_execution_date else dl.latest_execution_date end,
         case when dl.unmeetable then m.alert_soon_date else dl.alert_soon_date end,
         case when dl.unmeetable then m.alert_critical_date else dl.alert_critical_date end,
         coalesce(dl.out_of_horizon, false) or coalesce(m.out_of_horizon, false)
  from items i
  left join mon on mon.mandate_id = i.mandate_id
  left join dl on dl.e_date = i.e_date and dl.days = i.days
  left join m on m.e_date = i.e_date and dl.unmeetable;
$$;

-- private.run_transfer_checks, redefined from 20261118090000_switch_on_prerequisites.sql (line 1600; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (F): the payout_returned P0 also for a late predecessor's return (its payout booking's entry reversed).
-- Nothing else changes.
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
      and not exists (select 1 from public.refund_request q
                      cross join lateral (select y.status from public.bank_transfer y where y.id = q.transfer_id offset 0) y
                      where t.kind = 'refund' and q.organization_id = p_organization_id and q.status = 'requested'
                        and q.transfer_id is not null and y.status in ('ordered', 'in_file')
                        and exists (select 1 from private.transfer_chain(q.transfer_id) c where c.transfer_id = t.id))
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

-- private.run_payment_checks, redefined from 20261116090000_debit_bookings.sql (line 2617; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (F): I20 takes a late predecessor as booked — a payout cancelled with exactly one payout booking (and at
-- most one return), whose run is booked and holds it in its chain with no other transfer of the chain booked so —
-- and the run it booked (its chain holds exactly one such payout). A cancelled payout with a payout booking under a run
-- not booked is still flagged. Nothing else changes.
create or replace function private.run_payment_checks(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run uuid;
  v_today date := private.paris_today();
  v_summary jsonb;
  v_violations integer;
  v_alerts integer;
begin
  if not exists (select 1 from public.organization o where o.id = p_organization_id and o.kind = 'servicer') then
    raise exception 'checks: unknown servicer %', p_organization_id using errcode = '22023';
  end if;
  insert into public.payment_check_run (organization_id) values (p_organization_id) returning id into v_run;
  drop table if exists pg_temp._chk;
  create temp table _chk (code text, severity text, subject_type text, subject_id uuid, currency char(3),
                          amount_minor bigint, count integer, oldest_days integer, details jsonb) on commit drop;

  -- Every check reads the books in ONE statement, so in one snapshot: an entry or a payment committed while the
  -- checks run (a link, a release, an allocation from a PostgREST session) is in every check or in none — never a gap
  -- between the cash read by one check and the payments read by another (review fix: the job runs READ COMMITTED,
  -- where each statement of a function sees the latest commits).
  -- Review round 2 (P3): every check reads the servicer's rows by its key and the rows it needs by theirs, whatever the
  -- statistics (ARCHITECTURE §4): a lateral holding only a key (OFFSET 0: never pulled up, nothing pushed into it) for
  -- each row reached from another, a correlated EXISTS (OFFSET 0: never turned into a hashed anti-join) for each test of
  -- presence. Joined to the servicer's rows by hash, a table was read whole — every servicer's postings, entries, bank
  -- lines and notifications, cold after a scale run's writes (5 to 7.6 s for a servicer of 5,000 refunds). A posting's
  -- account is its entry's servicer's (LG002), and an entry names a payment of its own servicer (LG002): the
  -- servicer's accounts reach every posting of its entries, its payments every entry tagged with a payment. A check
  -- that sums the servicer's ledger by definition (the funds' identities, each client's 4670, the receivables) reads
  -- each of its accounts' postings once, through the accounts.
  insert into pg_temp._chk (code, severity, subject_type, subject_id, currency, amount_minor, count, oldest_days, details)
  with pe as materialized (
    -- Each of the servicer's payments with its entries' postings on the unallocated pool (4710: what it allocated,
    -- forwarded or returned; a payment with none, one row of nulls), from the payment by keys: its entries by its
    -- id, their postings by theirs (those on the servicer's 4710 accounts), the entry each reverses by its id. (As a
    -- join of the payments to their grouped postings, a servicer whose payments the statistics did not know yet was
    -- joined by a nested loop: 5,000 payments × 2,500 groups = 12.5 million rows compared, 7.7 s.)
    select p.id, p.status, p.review_reason, p.account_id, p.amount_minor, p.currency, p.booking_date, p.bank_account_id,
           p.bank_transaction_id, p.updated_at, x.entry_account_id, x.entry_type, x.posted
    from public.payment p
    left join lateral (
      select e.account_id as entry_account_id, coalesce(t.entry_type, e.entry_type) as entry_type, lp.amount_minor as posted
      from (select q.id, q.organization_id, q.account_id, q.entry_type, q.reverses_entry_id from public.ledger_entry q
            where q.payment_id = p.id offset 0) e
      cross join lateral (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                          where q.entry_id = e.id offset 0) lp
      left join lateral (select q.entry_type from public.ledger_entry q where q.id = e.reverses_entry_id offset 0) t on true
      where e.organization_id = p_organization_id
        and lp.ledger_account_id = any (array(select a.id from public.ledger_account a
                                              where a.organization_id = p_organization_id
                                                and a.book = 'unallocated_payment'))) x on true
    where p.organization_id = p_organization_id
  ),
  pos as materialized (
    -- Every payment's position from its tagged entries (one pass), and its pending refund (by the payment's key).
    select g.id, g.status, g.review_reason, g.account_id, g.amount_minor, g.currency, g.booking_date, g.bank_account_id,
           g.bank_transaction_id, g.updated_at, g.allocated, g.returned,
           (g.amount_minor - g.allocated - g.returned)::bigint as unallocated,
           coalesce(q.pending, 0)::bigint as pending, coalesce(q.n, 0) as pending_n
    from (select c.id, c.status, c.review_reason, c.account_id, c.amount_minor, c.currency, c.booking_date,
                 c.bank_account_id, c.bank_transaction_id, c.updated_at,
                 coalesce(sum(c.posted) filter (where c.entry_type in ('allocation', 'forward')), 0)::bigint as allocated,
                 coalesce(sum(c.posted) filter (where c.entry_type = 'cash_out'), 0)::bigint as returned
          from pe c
          group by c.id, c.status, c.review_reason, c.account_id, c.amount_minor, c.currency, c.booking_date,
                   c.bank_account_id, c.bank_transaction_id, c.updated_at) g
    left join lateral (select sum(q.amount_minor) filter (where q.status = 'requested') as pending,
                              count(*) filter (where q.status = 'requested') as n
                       from (select q.amount_minor, q.status from public.refund_request q
                             where q.payment_id = g.id offset 0) q) q on true
    -- (by the payment's key only — a request's payment is its servicer's, its foreign key: with the servicer or the
    -- status in the lateral, stale statistics chose the index of the requests still requested, led by the servicer,
    -- and read every request of the servicer for each payment, the executed ones' dead versions included until
    -- vacuum: 1.44 million buffers, 2 s, for 5,000 refunds)
  ),
  bal as materialized (
    -- Each of the servicer's accounts of the funds' books (client and servicer money: 5120, 4710, 4670, 4679, the
    -- servicer's own) with what its postings add up to, read by the account's key.
    select la.id, la.book, b.money_of, la.currency, la.client_organization_id, la.bank_account_id, la.portfolio_id,
           s.total
    from public.ledger_account la
    join public.ledger_book b on b.code = la.book
    cross join lateral (select sum(q.amount_minor) as total
                        from (select q.amount_minor from public.ledger_posting q
                              where q.ledger_account_id = la.id offset 0) q) s
    where la.organization_id = p_organization_id
      and la.book = any (array(select k.code from public.ledger_book k where k.money_of in ('client', 'servicer')))
      and s.total is not null
  ),
  recv as materialized (
    -- Each of the servicer's receivable accounts (1100: one per claim item and component): what its postings add up
    -- to, and whether a payment (an allocation or a direct payment's adjustment) or a netting lowered it — each
    -- lowering posting's entry read by its id.
    select la.id, la.claim_item_id, la.component, la.currency, la.portfolio_id, b.balance, b.lowered, b.lowered_item
    from public.ledger_account la
    cross join lateral (
      select sum(q.amount_minor) as balance, coalesce(bool_or(e.lowers), false) as lowered,
             coalesce(bool_or(e.lowers_item), false) as lowered_item
      from (select q.entry_id, q.amount_minor from public.ledger_posting q where q.ledger_account_id = la.id offset 0) q
      left join lateral (
        select x.entry_type in ('allocation', 'netting')
                 or (x.entry_type = 'adjustment' and x.source_type = 'direct_payment') as lowers,
               x.entry_type = 'allocation'
                 or (x.entry_type = 'adjustment' and x.source_type = 'direct_payment') as lowers_item
        from public.ledger_entry x where q.amount_minor < 0 and x.id = q.entry_id offset 0) e on true) b
    where la.organization_id = p_organization_id and la.book = 'debtor_receivable' and b.balance is not null
  ),
  cpb as materialized (
    -- Review round 3 (M5, round 2's P3): each of the servicer's clients' running balances of 4670 (I13, I14), read once
    -- by the servicer's key (client_payable_balance_org_idx; before, twice, every servicer's balances by sequential scan).
    select c.client_organization_id, c.currency, c.balance_minor from private.client_payable_balance c
    where c.organization_id = p_organization_id
  )
  -- I8′: the dedicated-account fund closed per currency (5120 + 4710 + 4670 + 4679 = 0), the servicer's fund closed
  -- per currency (own_fund_identity), and the 4679 / 4689 mirror (fund_mirror, I12), from one pass over the funds.
  select x.code, 'violation'::text, 'servicer'::text, null::uuid, x.currency::char(3), x.total::bigint,
         null::integer, null::integer, x.details
  from (select f.currency, v.code, v.total, v.details
        from (select a.currency,
                     sum(a.total) filter (where a.money_of = 'client') as client_total,
                     sum(a.total) filter (where a.money_of = 'servicer') as servicer_total,
                     sum(a.total) filter (where a.book in ('due_to_servicer', 'due_from_client_funds')) as mirror_total,
                     sum(a.total) filter (where a.book = 'client_money_cash') as cash,
                     sum(a.total) filter (where a.book = 'unallocated_payment') as pool,
                     sum(a.total) filter (where a.book = 'client_payable') as owed,
                     sum(a.total) filter (where a.book = 'due_to_servicer') as servicer_share,
                     sum(a.total) filter (where a.book = 'due_from_client_funds') as servicer_claim
              from bal a where a.portfolio_id is null
              group by a.currency) f
        cross join lateral (values
          ('client_money_identity', coalesce(f.client_total, 0),
           jsonb_build_object('cash_minor', coalesce(f.cash, 0)::text, 'unallocated_minor', coalesce(f.pool, 0)::text,
                              'owed_minor', coalesce(f.owed, 0)::text,
                              'due_to_servicer_minor', coalesce(f.servicer_share, 0)::text)),
          ('own_fund_identity', coalesce(f.servicer_total, 0), '{}'::jsonb),
          ('fund_mirror', coalesce(f.mirror_total, 0),
           jsonb_build_object('due_to_servicer_minor', coalesce(f.servicer_share, 0)::text,
                              'due_from_client_funds_minor', coalesce(f.servicer_claim, 0)::text))
        ) v (code, total, details)) x
  where x.total <> 0

  union all
  -- I13: each client's 4670 never in debit, and its running balance = its postings (the commit guard's source).
  select 'client_payable_debit', 'violation', 'client', coalesce(p.client_organization_id, r.client_organization_id),
         coalesce(p.currency, r.currency), coalesce(p.total, 0)::bigint, null, null,
         jsonb_build_object('postings_minor', coalesce(p.total, 0)::text, 'running_minor', coalesce(r.balance_minor, 0)::text)
  from (select a.client_organization_id, a.currency, sum(a.total) as total
        from bal a where a.book = 'client_payable'
        group by a.client_organization_id, a.currency) p
  full join cpb r
    on r.client_organization_id = p.client_organization_id and r.currency = p.currency
  where coalesce(p.total, 0) > 0 or coalesce(p.total, 0) <> coalesce(r.balance_minor, 0)

  union all
  -- I14 (completeness; M2c-4): what each client is owed = its items waiting in the pending queue (reserved by a
  -- draft or not) + the gross (N + D) of its runs approved and not booked yet.
  select 'remittance_completeness', 'violation', 'client',
         coalesce(r.client_organization_id, q.client_organization_id, f.client_organization_id),
         coalesce(r.currency, q.currency, f.currency),
         (-coalesce(r.balance_minor, 0) - coalesce(q.total, 0) - coalesce(f.inflight, 0))::bigint, null, null,
         jsonb_build_object('owed_minor', (-coalesce(r.balance_minor, 0))::text, 'pending_minor', coalesce(q.total, 0)::text,
                            'in_flight_minor', coalesce(f.inflight, 0)::text)
  from cpb r
  full join (select q.client_organization_id, q.currency, sum(q.amount_minor) as total from private.remittance_pending q
             where q.organization_id = p_organization_id group by q.client_organization_id, q.currency) q
    on q.client_organization_id = r.client_organization_id and q.currency = r.currency
  full join (select x.client_organization_id, x.currency, sum(x.net_minor + x.settlement_minor) as inflight
             from public.remittance_run x
             where x.organization_id = p_organization_id and x.status in ('approved', 'sent')
             group by x.client_organization_id, x.currency) f
    on f.client_organization_id = coalesce(r.client_organization_id, q.client_organization_id)
   and f.currency = coalesce(r.currency, q.currency)
  where -coalesce(r.balance_minor, 0) <> coalesce(q.total, 0) + coalesce(f.inflight, 0)

  union all
  -- I19, per dedicated account: its cash = what its payments brought in less what went back out to the payers
  -- (returns, refunds) + what its lines booked in the funds moved (top-ups in; fees, losses, payouts and sweeps out;
  -- returned payouts and sweeps in). Every 5120 movement of a funds entry comes from a bank line booked here. M2c-6b-1:
  -- what a booking moved is its entry's 5120 posting, signed (a return with charges books +N and −(N − line): the
  -- booking amount × the line's direction counted it twice).
  select 'bank_cash_identity', 'violation', 'bank_account', coalesce(c.bank_account_id, y.bank_account_id, k.bank_account_id),
         b.currency, (coalesce(c.cash, 0) - coalesce(y.held, 0) - coalesce(k.moved, 0))::bigint, null, null,
         jsonb_build_object('cash_minor', coalesce(c.cash, 0)::text, 'unallocated_minor', coalesce(y.unallocated, 0)::text,
                            'allocated_minor', coalesce(y.allocated, 0)::text,
                            'booked_lines_minor', coalesce(k.moved, 0)::text)
  from (select a.bank_account_id, sum(a.total) as cash
        from bal a where a.book = 'client_money_cash'
        group by a.bank_account_id) c
  full join (select x.bank_account_id, sum(x.amount_minor - x.returned) as held, sum(x.unallocated) as unallocated,
                    sum(x.allocated) as allocated
             from pos x where x.bank_account_id is not null group by x.bank_account_id) y
    on y.bank_account_id = c.bank_account_id
  full join (select k.bank_account_id, sum(p.amount_minor) as moved
             from public.bank_line_booking k
             cross join lateral (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                                 where q.entry_id = k.entry_id offset 0) p
             cross join lateral (select q.book, q.bank_account_id from public.ledger_account q
                                 where q.id = p.ledger_account_id offset 0) la
             where k.organization_id = p_organization_id and la.book = 'client_money_cash'
               and la.bank_account_id = k.bank_account_id
             group by k.bank_account_id) k on k.bank_account_id = coalesce(c.bank_account_id, y.bank_account_id)
  cross join lateral (select q.currency from public.bank_account q
                      where q.id = coalesce(c.bank_account_id, y.bank_account_id, k.bank_account_id) offset 0) b
  where coalesce(c.cash, 0) <> coalesce(y.held, 0) + coalesce(k.moved, 0)

  union all
  -- bank_line_booked (M2c-6b-1): each booked line booked whole, signed — the commit-time check's nightly twin
  select 'bank_line_booked', 'violation', 'bank_transaction', l.id, l.currency, l.amount_minor, null, null,
         jsonb_build_object('moved_minor', m.moved::text, 'direction', l.direction)
  from (select distinct k.bank_transaction_id from public.bank_line_booking k
        where k.organization_id = p_organization_id) k
  cross join lateral (select q.id, q.currency, q.amount_minor, q.direction, q.bank_account_id
                      from public.bank_transaction q where q.id = k.bank_transaction_id offset 0) l
  cross join lateral (select private.bank_line_cash_moved(l.id, l.bank_account_id) as moved offset 0) m
  where m.moved <> case l.direction when 'credit' then l.amount_minor else -l.amount_minor end

  union all
  -- I20 transfer_booked_once (M2c-6b-1): a transfer is debited once and returned once, and its status is what its
  -- bookings say, per kind (plan §2.5 [critic]): a payout, sweep or top-up by bank_line_booking — booked or returned
  -- with exactly one debit booking whose entry is its entry, returned with its return booking, no booking while not
  -- booked; a refund by its request (the M2b RFD link: its cash_out the transfer's entry, one link; its bounce the
  -- transfer's return). A run booked with a payout has its transfer booked or returned. (Each transfer's bookings and
  -- its request read by its key.)
  select 'transfer_booked_once', 'violation', 'bank_transfer', x.id, x.currency, x.amount_minor, null, null,
         jsonb_build_object('kind', x.kind, 'status', x.status, 'debit_bookings', x.debits,
                            'return_bookings', x.returns)
  from (select t.id, t.kind, t.status, t.currency, t.amount_minor, t.entry_id, t.return_entry_id,
               c.debits, c.debit_own, c.returns, c.return_own, q.cash_out_entry_id, q.bounce_entry_id,
               case when t.kind = 'refund' and t.status in ('booked', 'returned')
                    then private.refund_debit_links(q.id) end as refund_links,
               -- M2c-6b-3a-2 (F): a late predecessor — a payout cancelled with one payout booking (and at most one
               -- return) whose run is booked and holds it in its chain, no other transfer of that chain booked so
               case when t.kind = 'payout' and t.status = 'cancelled' and c.debits = 1 and c.debit_payouts = 1
                         and c.returns <= 1
                    then exists (select 1 from public.remittance_run r
                                 where r.id = t.run_id and r.status = 'booked'
                                   and exists (select 1 from private.transfer_chain(r.transfer_id) h
                                               where h.transfer_id = t.id)
                                   and not exists (select 1
                                                   from private.transfer_chain(r.transfer_id) h
                                                   cross join lateral (select k.kind from public.bank_line_booking k
                                                                       where k.transfer_id = h.transfer_id offset 0) k
                                                   where h.transfer_id <> t.id and k.kind = 'payout'))
                    else false end as lp
        from public.bank_transfer t
        cross join lateral (
          select count(*) filter (where b.kind in ('payout', 'sweep', 'top_up')) as debits,
                 count(*) filter (where b.kind = 'payout') as debit_payouts,
                 count(*) filter (where b.kind in ('payout', 'sweep', 'top_up') and b.entry_id = t.entry_id) as debit_own,
                 count(*) filter (where b.kind in ('payout_returned', 'sweep_returned')) as returns,
                 count(*) filter (where b.kind in ('payout_returned', 'sweep_returned')
                                    and b.entry_id = t.return_entry_id) as return_own
          from (select b.kind, b.entry_id from public.bank_line_booking b where b.transfer_id = t.id offset 0) b) c
        left join lateral (select q.id, q.cash_out_entry_id, q.bounce_entry_id from public.refund_request q
                           where q.transfer_id = t.id offset 0) q on true
        where t.organization_id = p_organization_id) x
  where x.debits > 1 or x.returns > 1
     or (x.kind in ('payout', 'sweep', 'top_up')
         and ((x.status in ('booked', 'returned') and x.debit_own <> 1)
              or (x.status = 'returned' and x.return_own <> 1)
              or (x.status not in ('booked', 'returned') and (x.debits > 0 or x.returns > 0) and not x.lp)))
     or (x.kind = 'refund'
         and ((x.status in ('booked', 'returned')
               and (x.cash_out_entry_id is distinct from x.entry_id or x.refund_links <> 1))
              or (x.status = 'returned' and x.bounce_entry_id is distinct from x.return_entry_id)))
  union all
  select 'transfer_booked_once', 'violation', 'remittance_run', r.id, r.currency, r.net_minor, null, null,
         jsonb_build_object('number', r.number, 'transfer_status', t.status)
  from public.remittance_run r
  left join lateral (select q.status from public.bank_transfer q where q.id = r.transfer_id offset 0) t on true
  where r.organization_id = p_organization_id and r.status = 'booked' and r.net_minor > 0
    and (t.status is null or t.status not in ('booked', 'returned'))
    -- M2c-6b-3a-2 (F): a run booked by its late predecessor — exactly one payout of its chain cancelled and booked as
    -- its payout (read only for the rows already caught above)
    and case when t.status is null or t.status not in ('booked', 'returned') then
          (select count(*)
           from private.transfer_chain(r.transfer_id) h
           cross join lateral (select q.kind, q.status from public.bank_transfer q where q.id = h.transfer_id offset 0) q
           cross join lateral (select count(*) as n from public.bank_line_booking k
                               where k.transfer_id = h.transfer_id and k.kind = 'payout') k
           where q.kind = 'payout' and q.status = 'cancelled' and k.n = 1) <> 1
        else false end

  union all
  -- I11: the cash booked for a statement day = its payments (released duplicates included). The cash_in entries'
  -- 5120 postings through the servicer's 5120 accounts; each payment's line by its id.
  select 'cash_in_statement', 'violation', 'bank_statement', coalesce(ci.statement_id, pd.statement_id), null,
         (coalesce(ci.total, 0) - coalesce(pd.total, 0))::bigint, null, null,
         jsonb_build_object('date', coalesce(ci.d, pd.d), 'cash_in_minor', coalesce(ci.total, 0)::text,
                            'payments_minor', coalesce(pd.total, 0)::text)
  from (select e.source_id::uuid as statement_id, e.effective_date as d, sum(lp.amount_minor) as total
        from public.ledger_account la
        cross join lateral (select q.entry_id, q.amount_minor from public.ledger_posting q
                            where q.ledger_account_id = la.id offset 0) lp
        cross join lateral (select q.organization_id, q.entry_type, q.source_id, q.effective_date
                            from public.ledger_entry q where q.id = lp.entry_id offset 0) e
        where la.organization_id = p_organization_id and la.book = 'client_money_cash'
          and e.organization_id = p_organization_id and e.entry_type = 'cash_in'
        group by e.source_id, e.effective_date) ci
  full join (select t.statement_id, p.booking_date as d, sum(p.amount_minor) as total
             from pos p
             cross join lateral (select q.statement_id from public.bank_transaction q
                                 where q.id = p.bank_transaction_id offset 0) t
             group by t.statement_id, p.booking_date) pd
    on pd.statement_id = ci.statement_id and pd.d = ci.d
  where coalesce(ci.total, 0) <> coalesce(pd.total, 0)

  union all
  -- I4, I5 and design §7: each payment's position against its status.
  select 'payment_position', 'violation', 'payment', c.id, c.currency, c.unallocated, null, v_today - c.booking_date,
         jsonb_build_object('status', c.status, 'allocated_minor', c.allocated::text,
                            'unallocated_minor', c.unallocated::text, 'returned_minor', c.returned::text,
                            'pending_refund_minor', c.pending::text)
  from pos c
  where c.unallocated < 0 or c.allocated < 0 or c.returned < 0
     or (c.status = 'allocated' and not (c.allocated > 0 and c.unallocated = 0))
     or (c.status = 'partially_allocated' and not (c.allocated > 0 and c.unallocated > 0))
     or (c.status in ('unmatched', 'matched') and not (c.allocated = 0 and c.unallocated > 0))
     or (c.status = 'unmatched' and c.account_id is not null)
     or (c.status = 'refunded' and not (c.allocated = 0 and c.unallocated = 0 and c.returned = c.amount_minor))
     or (c.status = 'returned' and not (c.allocated = 0 and c.unallocated = 0))
     or ((c.status = 'refund_pending') <> (c.pending_n > 0))
     or c.pending > c.unallocated

  union all
  -- the net allocated per (payment, file) is never negative
  select 'payment_negative_allocation', 'violation', 'payment', x.payment_id, null, x.total::bigint, null, null,
         jsonb_build_object('account_id', x.account_id)
  from (select c.id as payment_id, c.entry_account_id as account_id, sum(c.posted) as total
        from pe c where c.entry_type = 'allocation'
        group by c.id, c.entry_account_id) x
  where x.total < 0

  union all
  -- I6: no receivable a payment (or a credit note, or a payment made to the client) lowered is below zero now; no item
  -- below zero as a whole once such an entry touched it.
  select 'receivable_negative', 'violation', 'claim_item', x.claim_item_id, x.currency, x.balance::bigint, null, null,
         jsonb_build_object('component', x.component)
  from (select r.claim_item_id, r.component, r.currency, sum(r.balance) as balance
        from recv r where r.lowered
        group by r.claim_item_id, r.component, r.currency) x
  where x.balance < 0
  union all
  select 'item_negative', 'violation', 'claim_item', y.claim_item_id, y.currency, y.balance::bigint, null, null,
         '{}'::jsonb
  from (select r.claim_item_id, r.currency, sum(r.balance) as balance
        from (select r.claim_item_id, r.currency, r.balance,
                     bool_or(r.lowered_item) over (partition by r.claim_item_id) as touched
              from recv r where r.claim_item_id is not null) r
        where r.touched
        group by r.claim_item_id, r.currency) y
  where y.balance < 0

  union all
  -- The owner-claim mirror (M2a risk #5): per portfolio, component and currency, 3100 = −Σ1100.
  select 'owner_claim_mirror', 'violation', 'portfolio', x.portfolio_id, x.currency, x.total::bigint, null, null,
         jsonb_build_object('component', x.component)
  from (select z.portfolio_id, z.component, z.currency, sum(z.balance) as total
        from (select r.portfolio_id, r.component, r.currency, r.balance from recv r
              union all
              select la.portfolio_id, la.component, la.currency, s.total
              from public.ledger_account la
              cross join lateral (select sum(q.amount_minor) as total
                                  from (select q.amount_minor from public.ledger_posting q
                                        where q.ledger_account_id = la.id offset 0) q) s
              where la.organization_id = p_organization_id and la.book = 'owner_claim' and s.total is not null) z
        group by z.portfolio_id, z.component, z.currency) x
  where x.total <> 0

  union all
  -- R124-6: one receipt number per payment on a file and a current version about its file (void once returned). A
  -- payment changed in the last hour may still be in the receipts queue. (Each payment's receipts by its key.)
  select y.code, 'violation', 'payment', y.id, null, null, null, v_today - y.booking_date,
         jsonb_build_object('status', y.status)
  from (select c.id, c.booking_date, c.status,
               case when r.v is null and c.status <> 'returned' then 'receipt_missing'
                    when r.numbers > 1 then 'receipt_numbers'
                    when c.status = 'returned' and r.v is not null and cur.kind <> 'void' then 'receipt_not_void'
                    when c.status <> 'returned' and r.v is not null
                         and (cur.kind = 'void' or cur.account_id is distinct from c.account_id) then 'receipt_stale'
               end as code
        from pos c
        cross join lateral (select count(distinct x.number) as numbers, max(x.version) as v
                            from (select x.number, x.version, x.organization_id from public.receipt x
                                  where x.payment_id = c.id offset 0) x
                            where x.organization_id = p_organization_id) r
        left join lateral (select x.kind, x.account_id from public.receipt x
                           where x.payment_id = c.id and x.version = r.v offset 0) cur on true
        where c.account_id is not null and c.updated_at < now() - interval '1 hour'
          and not (c.status in ('matched', 'partially_allocated') and c.review_reason is null)) y
  where y.code is not null

  union all
  -- R124-5: one notification per entry that moves what a client is owed, one per payment held for a file, one per
  -- return of a payment on a file. (The payments' entries from the payments, each notification by its key.)
  select 'notification_missing', 'violation', 'ledger_entry', e.id, null, null, null, null,
         jsonb_build_object('entry_type', e.entry_type, 'payment_id', e.payment_id)
  from pos c
  cross join lateral (select q.id, q.organization_id, q.entry_type, q.payment_id, q.reverses_entry_id
                      from public.ledger_entry q where q.payment_id = c.id offset 0) e
  left join lateral (select q.entry_type from public.ledger_entry q where q.id = e.reverses_entry_id offset 0) t on true
  where e.organization_id = p_organization_id
    and (e.entry_type in ('allocation', 'forward') or (e.entry_type = 'reversal' and t.entry_type in ('allocation', 'forward')))
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = e.id offset 0)
  union all
  select 'notification_missing', 'violation', 'payment', c.id, null, null, null, null,
         jsonb_build_object('kind', 'payment_held')
  from pos c
  where c.review_reason = 'hold_blocks_allocation' and c.account_id is not null
    and not exists (select 1 from public.client_notification n
                    where n.payment_id = c.id and n.account_id = c.account_id and n.kind = 'payment_held' offset 0)
  union all
  select 'notification_missing', 'violation', 'payment', c.id, null, null, null, null,
         jsonb_build_object('kind', 'payment_returned')
  from pos c
  cross join lateral (select l.organization_id, l.kind, l.cash_entry_id from public.bank_debit_link l
                      where l.payment_id = c.id offset 0) l   -- (a link's payment is its servicer's: its foreign key)
  where l.organization_id = p_organization_id and l.kind = 'return' and c.account_id is not null
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = l.cash_entry_id offset 0)

  union all
  -- Statements (I9): a camt.053 statement whose opening is not the previous closing (« relevé manquant »), and each
  -- bank account's balance at its last statement against the ledger cash plus the lines not booked.
  select 'statement_gap', 'alert', 'bank_statement', x.id, null, (x.opening_booked_minor - x.prev_closing)::bigint,
         null, null,
         jsonb_build_object('bank_account_id', x.bank_account_id, 'from_date', x.from_date, 'previous_to_date', x.prev_to)
  from (select s.id, s.bank_account_id, s.from_date, s.opening_booked_minor,
               lag(s.closing_booked_minor) over w as prev_closing, lag(s.to_date) over w as prev_to
        from public.bank_statement s
        where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
        window w as (partition by s.bank_account_id order by s.from_date, s.to_date, s.finished_at)) x
  where x.prev_closing is not null and x.prev_to < x.from_date and x.opening_booked_minor <> x.prev_closing
  union all
  select 'bank_balance_gap', 'alert', 'bank_account', z.bank_account_id, z.currency,
         (z.closing - z.cash - z.unposted)::bigint, null, null,
         jsonb_build_object('as_of', z.to_date, 'closing_minor', z.closing::text, 'cash_minor', z.cash::text,
                            'unposted_minor', z.unposted::text, 'unposted_lines', z.unposted_lines)
  from (select l.bank_account_id, l.currency, l.to_date, l.closing_booked_minor as closing,
               coalesce((select sum(lp.amount_minor)
                         from (select a.id from public.ledger_account a
                               where a.bank_account_id = l.bank_account_id and a.book = 'client_money_cash' offset 0) la
                         cross join lateral (select q.amount_minor from public.ledger_posting q
                                             where q.ledger_account_id = la.id and q.effective_date <= l.to_date
                                             offset 0) lp), 0) as cash,
               u.minor as unposted, u.lines as unposted_lines
        from (select distinct on (s.bank_account_id) s.bank_account_id, s.currency, s.to_date, s.closing_booked_minor
              from public.bank_statement s
              where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
              order by s.bank_account_id, s.to_date desc, s.finished_at desc) l
        cross join lateral private.bank_unposted(l.bank_account_id, l.to_date) u) z
  where z.closing - z.cash - z.unposted <> 0

  union all
  -- servicer_shortfall (§15, P0; review fix): the servicer owes the dedicated account more than the top-ups ordered
  -- cover — 4679 in debit (the fees and losses booked on the account are the servicer's cost, founder #8, #9) less
  -- the top-ups ordered and not booked yet: an approvisionnement from the own account is to order, for this amount.
  select 'servicer_shortfall', 'alert', 'servicer', null, s.currency, (s.owed - coalesce(o.ordered, 0))::bigint, null,
         null, jsonb_build_object('due_to_servicer_minor', s.owed::text,
                                  'top_ups_ordered_minor', coalesce(o.ordered, 0)::text)
  from (select a.currency, sum(a.total) as owed
        from bal a where a.book = 'due_to_servicer'
        group by a.currency) s
  left join (select x.currency, sum(x.amount_minor) as ordered from public.bank_transfer x
             where x.organization_id = p_organization_id and x.kind = 'top_up' and x.status in ('ordered', 'in_file')
             group by x.currency) o on o.currency = s.currency
  where s.owed - coalesce(o.ordered, 0) > 0

  union all
  -- Ageing (alerts, one row per code with the oldest and up to 50 payments or lines).
  select x.code, 'alert', 'servicer', null, x.currency, x.total, x.n, x.oldest, jsonb_build_object('ids', x.ids)
  from (select 'unmatched_ageing' as code, c.currency, sum(c.unallocated)::bigint as total, count(*)::integer as n,
               max(v_today - c.booking_date) as oldest,
               (array_agg(c.id order by c.booking_date, c.id))[1:50] as ids
        from pos c
        where c.status = 'unmatched' and v_today - c.booking_date >= 20
        group by c.currency
        union all
        select 'unallocated_ageing', c.currency, sum(c.unallocated)::bigint, count(*)::integer,
               max(v_today - c.booking_date), (array_agg(c.id order by c.booking_date, c.id))[1:50]
        from pos c
        where c.account_id is not null and c.unallocated > 0 and c.status in ('matched', 'partially_allocated')
          and c.review_reason is not null and v_today - c.booking_date >= 20
        group by c.currency
        union all
        select 'refund_pending_ageing', q.currency, sum(q.amount_minor)::bigint, count(*)::integer,
               max(v_today - (q.requested_at at time zone 'Europe/Paris')::date),
               (array_agg(q.payment_id order by q.requested_at, q.id))[1:50]
        from public.refund_request q
        where q.organization_id = p_organization_id and q.status = 'requested'
          and v_today - (q.requested_at at time zone 'Europe/Paris')::date >= 5
        group by q.currency
        union all
        -- returns, our refunds, credits undoing a debit (released duplicates of those kinds) not linked — they can
        -- only be booked, never explained — and other debits of a pending refund's amount on its bank account: the
        -- servicer's lines of those kinds, three days old at least, by the kinds' partial indexes; each test by key
        select 'debit_unclassified', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from (select q.id, q.kind, q.direction, q.currency, q.amount_minor, q.booking_date, q.bank_account_id,
                     q.organization_id
              from public.bank_transaction q
              where q.organization_id = p_organization_id and q.booking_date <= v_today - 3
                and q.kind in ('return', 'refund_out', 'suspected_duplicate')
              union all
              select q.id, q.kind, q.direction, q.currency, q.amount_minor, q.booking_date, q.bank_account_id,
                     q.organization_id
              from public.bank_transaction q
              where q.organization_id = p_organization_id and q.booking_date <= v_today - 3
                and q.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
              union all
              select q.id, q.kind, q.direction, q.currency, q.amount_minor, q.booking_date, q.bank_account_id,
                     q.organization_id
              from public.bank_transaction q
              where q.organization_id = p_organization_id and q.booking_date <= v_today - 3
                and q.kind = 'other_debit') t
        left join lateral (select r.released_kind from public.bank_duplicate_resolution r
                           where r.bank_transaction_id = t.id offset 0) r on true
        where (t.kind in ('return', 'refund_out', 'transfer_out', 'own_transfer_in', 'client_transfer_in')
               or (t.kind = 'suspected_duplicate'
                   and r.released_kind in ('return', 'refund_out', 'transfer_out', 'own_transfer_in',
                                           'client_transfer_in'))
               or (t.kind = 'other_debit' and t.direction = 'debit'
                   and exists (select 1 from (select q.organization_id, q.status from public.refund_request q
                                              where q.bank_account_id = t.bank_account_id
                                                and q.amount_minor = t.amount_minor offset 0) q
                               where q.organization_id = t.organization_id and q.status = 'requested' offset 0)))
          and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
          and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
          and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id offset 0)
        group by t.currency
        union all
        select 'duplicate_unresolved', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from public.bank_transaction t
        where t.organization_id = p_organization_id and t.kind = 'suspected_duplicate'
          and t.booking_date <= v_today - 3
          and not exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id offset 0)
        group by t.currency
        union all
        select 'direct_payment_waiting', d.currency, sum(d.amount_minor)::bigint, count(*)::integer,
               max(v_today - (d.requested_at at time zone 'Europe/Paris')::date),
               (array_agg(d.id order by d.requested_at, d.id))[1:50]
        from public.direct_payment d
        where d.organization_id = p_organization_id and d.status = 'requested' and d.requested_at < now() - interval '1 hour'
        group by d.currency) x;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select v_run, p_organization_id, c.code, c.severity, c.subject_type, c.subject_id, c.currency, c.amount_minor, c.count,
         c.oldest_days, coalesce(c.details, '{}')
  from pg_temp._chk c;
  -- M2c-4: the runs' checks (I15–I18, I21, the deadline alerts, the reference data), then the counts of everything
  perform private.run_remittance_checks(v_run, p_organization_id);
  select coalesce(jsonb_object_agg(x.code, x.n), '{}') into v_summary
  from (select c.code, count(*) as n from public.payment_check_result c where c.run_id = v_run group by c.code) x;
  select count(*) filter (where c.severity = 'violation'), count(*) filter (where c.severity = 'alert')
  into v_violations, v_alerts from public.payment_check_result c where c.run_id = v_run;
  update public.payment_check_run
  set finished_at = clock_timestamp(), violations = v_violations, alerts = v_alerts, summary = v_summary
  where id = v_run;
  return jsonb_build_object('run_id', v_run, 'violations', v_violations, 'alerts', v_alerts, 'by_code', v_summary);
end;
$$;

-- private.run_remittance_runs_checks, redefined from 20261117110000_transfer_line_pages.sql (line 1251; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (I; CPCE-08): the in-flight row of a run whose transfer re-issues another or is itself cancelled waits for
-- the statements to cover [e0, L] (e0: the chain's earliest execution in a downloaded file) with no possible debit of a
-- chain transfer by L (private.transfer_debit_suppression), 'expired' writing it debit_unbooked. Review round 1 (LD-1):
-- and never while a debit naming a chain transfer by our references, dated by L, waits unbooked. Review round 2
-- (ld2-named-debit-returned-after-booking): a booked run whose chain holds a payout cancelled out of a downloaded file
-- gets its R124-6 rows at the date a transfer of its chain paid the client and stayed paid (private.remittance_run_paid_on) once a statement shows the return of a transfer of that chain
-- (its payout standing). Review round 3 (paid-on-misses-lot-lines-and-return-shapes): a return known from the bookings
-- and the statement details as well. Review round 4: both branches read the one rule over the run's payout chain
-- (private.remittance_chain_paid): the chained branch never proves unpaid at L a run its chain paid by L and stayed
-- paid, the booked branch judges its rows at that date once a return of the chain is on the statements. Nothing else
-- changes.
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

  -- Review round 2 (ld2-named-debit-returned-after-booking; CPCE-08): a booked run whose payout chain holds a payout
  -- cancelled out of a downloaded file (a re-issue's run, or one booked by its late predecessor). Its booking judged its
  -- rows at the earliest debit naming a transfer of its chain then seen (private.bank_booking_post_rows); a transfer that
  -- comes back afterwards paid nothing — the client was paid only by what stayed: once a statement shows the return of
  -- a transfer of the chain, its rows are judged again at the earliest debit of a transfer of the chain whose return is
  -- not seen (private.remittance_run_paid_on, booked lines included), the run's payout standing (its payout booking's
  -- entry not reversed: a run whose payout came back has its sums owed again, their rows the queue's). Append-only, once
  -- (on conflict): a row the booking wrote stays. A return seen after L is a fact of the statements, whenever imported.
  -- Review round 3: « the return of a transfer » is known from its own or original id, a detail of an entry kept
  -- unsplit, or a lot credit booked as its return. Review round 4: the one rule over the chain
  -- (private.remittance_chain_paid) — its paid date, and whether a return of the chain is on the statements (an
  -- unflagged return carrying our id included); a transfer executed more often than it came back stays paid.
  -- Keyed: the servicer's cancelled filed transfers by bank_transfer_cancelled_filed_idx, each run, chain and line by key.
  with bc as materialized (
    select distinct x.run_id
    from (select q.run_id, q.kind from public.bank_transfer q
          where q.organization_id = p_organization_id and q.status = 'cancelled' and q.transfer_file_id is not null
          offset 0) x
    where x.kind = 'payout' and x.run_id is not null),
  bp as materialized (
    select r.id as run_id, r.organization_id, r.client_organization_id, r.requested_execution_date, r.late_reason,
           p.paid_on
    from bc
    cross join lateral (select q.id, q.organization_id, q.client_organization_id, q.requested_execution_date,
                               q.late_reason, q.status, q.transfer_id
                        from public.remittance_run q where q.id = bc.run_id offset 0) r
    cross join lateral (select c.paid_on, c.returned
                        from private.remittance_chain_paid(r.transfer_id) c
                        where r.status = 'booked'
                          and exists (select 1
                                      from private.transfer_chain(r.transfer_id) h
                                      cross join lateral (select k.entry_id from public.bank_line_booking k
                                                          where k.transfer_id = h.transfer_id and k.kind = 'payout'
                                                          offset 0) k
                                      where not exists (select 1 from public.ledger_entry z
                                                        where z.reverses_entry_id = k.entry_id offset 0))
                        offset 0) p
    where p.returned),
  late as materialized (
    select p.run_id, p.paid_on as line_date, p.organization_id, p.client_organization_id, p.requested_execution_date,
           p.late_reason, l.ledger_entry_id, l.payment_id, l.deadline, l.latest_execution_date, l.unmeetable,
           l.encaissement_date, l.kind
    from bp p
    cross join lateral private.remittance_run_late_lines(p.run_id, p.paid_on) l
    where p.paid_on is not null),
  m as materialized (
    select k.e_date, d.*
    from (select distinct l.encaissement_date as e_date from late l
          where l.unmeetable and l.encaissement_date is not null) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, 30) d)
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
  olc as materialized (
    select k.run_id, k.latest_execution_date,
           case when t.chained then coalesce(ch.covered and not coalesce(ch.waiting, false)
                                             and not coalesce(nm.named, false), false)
                else coalesce(t.status = 'ordered' or (t.status = 'in_file' and coalesce(t.download_count, 0) = 0)
                              or (e.unseen and e.suppression is distinct from 'waiting'), false) end as proven,
           -- M2c-6b-2c (plan §4.2): proven only because the lines that could be its debit offered no booking of it for
           -- five business days
           case when t.chained then coalesce(ch.covered and not coalesce(ch.waiting, false)
                                             and not coalesce(nm.named, false) and ch.expired, false)
                else coalesce(t.status = 'in_file' and coalesce(t.download_count, 0) > 0 and e.unseen
                              and e.suppression = 'expired', false) end as debit_unbooked
    from (select distinct o.run_id, o.latest_execution_date from ol o where not o.out_of_horizon) k
    left join lateral (select q.id, q.debtor_bank_account_id, q.status,
                              (select f.download_count from public.transfer_file f where f.id = q.transfer_file_id)
                                as download_count,
                              q.replaces_transfer_id is not null or q.status = 'cancelled' as chained
                       from public.remittance_run r join public.bank_transfer q on q.id = r.transfer_id
                       where r.id = k.run_id offset 0) t on true
    left join lateral (
      select private.statement_covers(t.debtor_bank_account_id, least(min(h.e0), k.latest_execution_date),
                                      k.latest_execution_date) as covered,
             bool_or(s.s = 'waiting') as waiting, bool_or(s.s = 'expired') as expired
      from (select c.transfer_id,
                   (select min(i.execution_date)
                    from (select q.file_id, q.execution_date from public.transfer_file_item q
                          where q.transfer_id = c.transfer_id offset 0) i
                    cross join lateral (select f.download_count from public.transfer_file f
                                        where f.id = i.file_id offset 0) f
                    where f.download_count > 0) as e0
            from private.transfer_chain(t.id) c
            where t.chained offset 0) h
      cross join lateral (select private.transfer_debit_suppression(h.transfer_id, k.latest_execution_date, v_today)
                                   as s) s
      where h.e0 is not null) ch on true
    -- review round 4 (CPCE-08): the chain paid the client by L and stayed paid (private.remittance_chain_paid: every
    -- execution and return of the chain, each counted for the transfer it names) — never proven unpaid, whether or not
    -- « Comptabiliser… » offers the booking yet
    left join lateral (select c.paid_on <= k.latest_execution_date as named
                       from private.remittance_chain_paid(t.id) c
                       where t.chained offset 0) nm on true
    left join lateral (select u.unseen,
                              case when u.unseen then private.transfer_debit_suppression(t.id, k.latest_execution_date,
                                                                                         v_today) end as suppression
                       from (select t.status = 'in_file' and coalesce(t.download_count, 0) > 0
                                    and private.statement_covers(t.debtor_bank_account_id, k.latest_execution_date,
                                                                 k.latest_execution_date)
                                    and not private.transfer_debit_seen(t.id) as unseen
                             where t.id is not null offset 0) u) e on true),
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

-- public.remittance_run_payout, redefined from 20261117110000_transfer_line_pages.sql (line 3230; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (F): each transfer says whether it is the late predecessor (a payout cancelled, booked as the run's
-- payout); repaid_by and the advances of its debit (payout_overrun) are read through its bookings' entries (it keeps no
-- entry of its own). Review round 1 (pages-texts-5): an unplanned booking of a late predecessor is not
-- after_cancellation (a second execution of the transfer that paid the run). Review round 2
-- (ld2-reissue-return-pays-twice): an unplanned booking closed by the return of another transfer of the chain carries
-- returned_by_end_to_end_id (that transfer's reference: its copy came back, not this one). Nothing else changes.
create or replace function public.remittance_run_payout(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or not (r.organization_id = any (private.money_staff_org_ids())) then
    return null;
  end if;
  return jsonb_build_object(
    'transfers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', x.id, 'status', x.status, 'end_to_end_id', x.end_to_end_id, 'amount_minor', x.amount_minor::text,
               'debited_on', d.booking_date, 'returned_on', rt.booking_date, 'line_id', d.line_id,
               'return_line_id', rt.line_id, 'repaid_by', p.number,
               -- M2c-6b-3a-2 (F): a payout cancelled and booked as its run's payout (the late predecessor)
               'late_predecessor', x.status = 'cancelled' and d.line_id is not null) order by c.depth), '[]')
      from private.transfer_chain(r.transfer_id) c
      cross join lateral (select y.id, y.status, y.end_to_end_id, y.amount_minor, y.return_entry_id
                          from public.bank_transfer y where y.id = c.transfer_id offset 0) x
      left join lateral (select l.booking_date, l.id as line_id
                         from (select k.bank_transaction_id, k.kind from public.bank_line_booking k
                               where k.transfer_id = x.id offset 0) k
                         cross join lateral (select q.id, q.booking_date from public.bank_transaction q
                                             where q.id = k.bank_transaction_id offset 0) l
                         where k.kind in ('payout', 'sweep')
                         order by l.booking_date limit 1) d on true
      left join lateral (select l.booking_date, l.id as line_id, k.entry_id
                         from (select k.bank_transaction_id, k.kind, k.entry_id from public.bank_line_booking k
                               where k.transfer_id = x.id offset 0) k
                         cross join lateral (select q.id, q.booking_date from public.bank_transaction q
                                             where q.id = k.bank_transaction_id offset 0) l
                         where k.kind in ('payout_returned', 'sweep_returned')
                         order by l.booking_date limit 1) rt on true
      -- a returned payout paid again: the booked run whose live line holds the payout_returned item its return put
      -- back (as client_remittance_summary's repaid_by)
      left join lateral (select y.number
                         -- M2c-6b-3a-2 (F): a late predecessor's return entry is its return booking's
                         from (select l.run_id from public.remittance_line l
                               where l.ledger_entry_id = coalesce(x.return_entry_id, rt.entry_id) and not l.released
                                 and l.kind = 'payout_returned' offset 0) l
                         cross join lateral (select q.number, q.status from public.remittance_run q
                                             where q.id = l.run_id offset 0) y
                         where y.status = 'booked' limit 1) p on true),
    'payout_account_blocked', coalesce((select a.status = 'returned' from public.client_payout_account a
                                        where a.id = r.payout_account_id), false),
    'settled_on', (select e.effective_date from public.ledger_entry e
                   where e.organization_id = r.organization_id and e.idempotency_key = 'settle:' || r.id),
    'settlement_minor', coalesce(r.settlement_minor, 0)::text,
    'commission_minor', coalesce(r.commission_taken_minor, 0)::text,
    'advances_recovered_minor', coalesce(r.advance_recovered_minor, 0)::text,
    'advances', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'cause', a.cause, 'amount_minor', a.amount_minor::text,
               'open_minor', (a.amount_minor - coalesce(s.settled, 0))::text,
               'created_on', (a.created_at at time zone 'Europe/Paris')::date) order by a.created_at, a.id), '[]')
      from private.transfer_chain(r.transfer_id) c
      -- M2c-6b-3a-2 (F): a late predecessor's debit entry is its payout booking's (it keeps no entry of its own)
      cross join lateral (select coalesce(y.entry_id, (select k.entry_id from public.bank_line_booking k
                                                       where k.transfer_id = y.id and k.kind = 'payout' limit 1))
                                   as entry_id
                          from public.bank_transfer y where y.id = c.transfer_id offset 0) x
      cross join lateral (select q.* from public.client_advance q
                          where q.cause_entry_id = x.entry_id and q.cause = 'payout_overrun' offset 0) a
      left join lateral (select sum(z.amount_minor) as settled from public.commission_settlement z
                         where z.document_kind = 'advance' and z.document_id = a.id) s on true),
    'unplanned', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'line_id', k.bank_transaction_id, 'kind', k.kind, 'amount_minor', k.amount_minor::text,
               'on', l.booking_date, 'paid_minor', (k.amount_minor - coalesce(a.amount_minor, 0))::text,
               -- review round 1 (pages-texts-5): a late predecessor (booked as the run's payout) executed again is
               -- a second execution, not one after the cancellation
               'advance_minor', coalesce(a.amount_minor, 0)::text,
               'after_cancellation', x.status = 'cancelled'
                                     and not exists (select 1 from public.bank_line_booking z
                                                     where z.transfer_id = x.id and z.kind = 'payout'),
               'returned', exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id))
               -- review round 2: closed by the return of another transfer of the chain (its reference; key only then)
               || coalesce((select jsonb_build_object('returned_by_end_to_end_id', y.end_to_end_id)
                            from (select z.id from public.ledger_entry z where z.reverses_entry_id = k.entry_id
                                  offset 0) z
                            cross join lateral (select q.transfer_id from public.bank_line_booking q
                                                where q.entry_id = z.id offset 0) q
                            cross join lateral (select y.end_to_end_id from public.bank_transfer y
                                                where y.id = q.transfer_id offset 0) y
                            where q.transfer_id is distinct from x.id), '{}'::jsonb)
               order by l.booking_date, k.bank_transaction_id), '[]')
      from private.transfer_chain(r.transfer_id) c
      cross join lateral (select y.id, y.status from public.bank_transfer y where y.id = c.transfer_id offset 0) x
      cross join lateral (select q.bank_transaction_id, q.kind, q.amount_minor, q.entry_id from public.bank_line_booking q
                          where q.transfer_id = x.id offset 0) k
      cross join lateral (select q.booking_date from public.bank_transaction q
                          where q.id = k.bank_transaction_id offset 0) l
      left join lateral (select q.amount_minor from public.client_advance q
                         where q.cause_entry_id = k.entry_id and q.cause = 'double_payout' offset 0) a on true
      where k.kind = 'unplanned_payout'),
    -- (review 6b-2c money-4) what the draft deducts of each unplanned booking: the net of that booking's own rows it
    -- holds — its −A row and its double_payout advance's +(A − P) row (private.unplanned_own_item's two), that is P;
    -- a booking whose rows net to nothing (P = 0) is not listed
    'draft_unplanned', case when r.status = 'draft' then (
      select coalesce(jsonb_agg(jsonb_build_object(
               'amount_minor', (-(q.amount_minor + coalesce(av.amount_minor, 0)))::text, 'on', l.booking_date,
               'line_id', k.bank_transaction_id, 'statement_on', s.to_date)
               order by l.booking_date, k.bank_transaction_id), '[]')
      from (select y.ledger_entry_id, y.amount_minor from private.remittance_pending y
            where y.draft_run_id = r.id and y.kind = 'unplanned_payout' offset 0) q
      cross join lateral (select z.bank_transaction_id from public.bank_line_booking z
                          where z.entry_id = q.ledger_entry_id and z.kind = 'unplanned_payout' offset 0) k
      left join lateral (select sum(y.amount_minor) as amount_minor
                         from (select a.entry_id from public.client_advance a
                               where a.cause_entry_id = q.ledger_entry_id and a.cause = 'double_payout' offset 0) a
                         cross join lateral (select y.amount_minor from private.remittance_pending y
                                             where y.ledger_entry_id = a.entry_id and y.draft_run_id = r.id
                                             offset 0) y) av on true
      cross join lateral (select z.booking_date, z.statement_id from public.bank_transaction z
                          where z.id = k.bank_transaction_id offset 0) l
      left join lateral (select z.to_date from public.bank_statement z where z.id = l.statement_id offset 0) s on true
      where q.amount_minor + coalesce(av.amount_minor, 0) <> 0)
      else '[]'::jsonb end);
end;
$$;

-- public.client_remittance_summary, redefined from 20261117110000_transfer_line_pages.sql (line 3391; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (F): returned_runs also holds a run booked by a late predecessor that came back; (T17) a new
-- cancelled_runs [{run_id, transfer_outcome}] says what became of each cancelled run's transfer (not_executed,
-- never_handed_out), from its chain's files; review round 1 (pages-texts-4) debit_pending while a possible late debit
-- of a transfer of the chain waits unbooked. Nothing else changes.
create or replace function public.client_remittance_summary(p_client_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.organization;
  v_owed jsonb;
  v_flight jsonb;
  v_returned jsonb;
  v_unplanned jsonb;
  v_cancelled jsonb;
  v_today date := private.paris_today();
begin
  select * into c from public.organization where id = p_client_organization_id;
  if not found or not (c.id = any (private.client_whole_org_ids())
                       or c.servicer_organization_id = any (private.money_staff_org_ids())) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('currency', x.currency, 'owed_minor', x.owed::text,
                                               'in_flight_gross_minor', x.gross::text, 'in_flight_runs', x.runs)
                            order by x.currency), '[]')
  into v_owed
  from (select coalesce(b.currency, f.currency) as currency, coalesce(-b.balance_minor, 0) as owed,
               coalesce(f.gross, 0) as gross, coalesce(f.runs, '[]'::jsonb) as runs
        from (select y.currency, y.balance_minor from private.client_payable_balance y
              where y.client_organization_id = c.id and y.balance_minor <> 0) b
        full join (select r.currency, sum(r.gross_minor) as gross,
                          jsonb_agg(jsonb_build_object(
                            'number', r.number, 'status', r.status,
                            'gross_minor', r.gross_minor::text, 'net_minor', r.net_minor::text,
                            'commission_minor', coalesce(r.commission_taken_minor, 0)::text,
                            'advance_minor', coalesce(r.advance_recovered_minor, 0)::text,
                            'refund_minor', coalesce(r.refund_minor, 0)::text,
                            'requested_execution_date', r.requested_execution_date)
                            order by r.approved_at, r.number) as runs
                   from public.remittance_run r
                   where r.client_organization_id = c.id and r.status in ('approved', 'sent')
                   group by r.currency) f on f.currency = b.currency) x;
  select coalesce(jsonb_agg(jsonb_build_object('number', r.number, 'status', r.status, 'currency', r.currency,
                                               'net_minor', r.net_minor::text,
                                               'requested_execution_date', r.requested_execution_date,
                                               'approved_on', (r.approved_at at time zone 'Europe/Paris')::date)
                            order by r.approved_at), '[]')
  into v_flight from public.remittance_run r
  where r.client_organization_id = c.id and r.status in ('approved', 'sent');
  -- the client's runs whose payout came back: the transfer by its key, the return's line by its booking; review round 2
  -- (L2): `repaid_by`, the number of the run whose live line holds the payout_returned item the return put back (its
  -- entry is the transfer's return entry: the live line by its key) once that run is booked — null until then
  -- M2c-6b-3a-2 (F): and the runs booked by a late predecessor that came back (its payout_returned booking: the
  -- return's line date; repaid_by by the return booking's entry), never read as « Virement débité »
  select coalesce(jsonb_agg(jsonb_build_object('run_id', z.run_id, 'returned_on', z.returned_on,
                                               'amount_minor', z.amount_minor::text, 'repaid_by', z.repaid_by)
                            order by z.returned_on, z.number), '[]')
  into v_returned
  from (
  select r.id as run_id, r.number, x.returned_on, t.amount_minor, p.number as repaid_by
  from public.remittance_run r
  cross join lateral (select q.id, q.status, q.amount_minor, q.return_entry_id from public.bank_transfer q
                      where q.id = r.transfer_id offset 0) t
  cross join lateral (select coalesce(
                               (select l.booking_date from public.bank_line_booking k
                                join public.bank_transaction l on l.id = k.bank_transaction_id
                                where k.transfer_id = t.id and k.kind = 'payout_returned' limit 1),
                               (select e.effective_date from public.ledger_entry e where e.id = t.return_entry_id))
                             as returned_on) x
  left join lateral (select y.number
                     from (select l.run_id from public.remittance_line l
                           where l.ledger_entry_id = t.return_entry_id and not l.released
                             and l.kind = 'payout_returned' offset 0) l
                     cross join lateral (select q.number, q.status from public.remittance_run q
                                         where q.id = l.run_id offset 0) y
                     where y.status = 'booked') p on true
  where r.client_organization_id = c.id and r.transfer_id is not null and t.status = 'returned'
  union all
  select r.id, r.number, l.booking_date, t.amount_minor, p.number
  from public.remittance_run r
  cross join lateral private.transfer_chain(r.transfer_id) ch
  cross join lateral (select q.id, q.kind, q.status, q.amount_minor from public.bank_transfer q
                      where q.id = ch.transfer_id offset 0) t
  cross join lateral (select k.entry_id, k.bank_transaction_id from public.bank_line_booking k
                      where k.transfer_id = t.id and k.kind = 'payout_returned' offset 0) k
  cross join lateral (select q.booking_date from public.bank_transaction q where q.id = k.bank_transaction_id offset 0) l
  left join lateral (select y.number
                     from (select l2.run_id from public.remittance_line l2
                           where l2.ledger_entry_id = k.entry_id and not l2.released
                             and l2.kind = 'payout_returned' offset 0) l2
                     cross join lateral (select q.number, q.status from public.remittance_run q
                                         where q.id = l2.run_id offset 0) y
                     where y.status = 'booked') p on true
  where r.client_organization_id = c.id and r.status = 'booked' and r.transfer_id is not null
    and t.kind = 'payout' and t.status = 'cancelled') z;
  -- M2c-6b-2c (critic L6, critic2 ML-12): the cancelled runs whose payout the bank executed all the same
  select coalesce(jsonb_agg(jsonb_build_object('run_id', r.id, 'executed_on', u.executed_on)
                            order by u.executed_on, r.number), '[]')
  into v_unplanned
  from public.remittance_run r
  cross join lateral (select min(l.booking_date) as executed_on
                      from private.transfer_chain(r.transfer_id) ch
                      cross join lateral (select k.bank_transaction_id, k.kind from public.bank_line_booking k
                                          where k.transfer_id = ch.transfer_id offset 0) k
                      cross join lateral (select q.booking_date from public.bank_transaction q
                                          where q.id = k.bank_transaction_id offset 0) l
                      where k.kind = 'unplanned_payout') u
  where r.client_organization_id = c.id and r.status = 'cancelled' and r.transfer_id is not null
    and u.executed_on is not null;
  -- M2c-6b-3a-2 (T17): what became of each cancelled run's transfer, from its chain's transfers and their files (never
  -- the download count alone): `not_executed` — a file of the chain closed « refusé par la banque », or a transfer of
  -- the chain cancelled alone out of its live downloaded file (the bank refused it); `never_handed_out` — no file of the
  -- chain downloaded, or each closed « jamais déposé » (the client space keeps « Annulé avant la remise de son virement à
  -- la banque », true); none else. Review round 1 (pages-texts-4): `debit_pending` first, while a transfer of the chain
  -- handed out has a possible late debit on a statement not booked nor linked yet (« Débits et retours » decides)
  select coalesce(jsonb_agg(jsonb_build_object('run_id', r.id, 'transfer_outcome', o.outcome) order by r.number), '[]')
  into v_cancelled
  from public.remittance_run r
  cross join lateral (
    select case
             -- review round 1 (pages-texts-4): a transfer of the chain handed out to the bank, cancelled, with a debit
             -- on a statement that may be its late execution, not booked nor linked yet
             -- (private.transfer_late_debit_open): neither outcome is known yet — `debit_pending`
             when coalesce(bool_or(f.download_count > 0 and x.status = 'cancelled'
                                   and private.transfer_late_debit_open(ch.transfer_id)), false)
               then 'debit_pending'
             when coalesce(bool_or(f.download_count > 0
                                   and (f.close_attestation = 'rejected_by_bank'
                                        or (f.status in ('downloaded', 'sent') and x.status = 'cancelled'))), false)
               then 'not_executed'
             when coalesce(bool_and(f.close_attestation = 'not_uploaded') filter (where f.download_count > 0), true)
               then 'never_handed_out'
           end as outcome
    from private.transfer_chain(r.transfer_id) ch
    cross join lateral (select q.status from public.bank_transfer q where q.id = ch.transfer_id offset 0) x
    left join lateral (select q.file_id from public.transfer_file_item q where q.transfer_id = ch.transfer_id
                       offset 0) i on true
    left join lateral (select g.status, g.download_count, g.close_attestation from public.transfer_file g
                       where g.id = i.file_id offset 0) f on true) o
  where r.client_organization_id = c.id and r.status = 'cancelled' and r.transfer_id is not null
    and o.outcome is not null;
  return jsonb_build_object('owed', v_owed, 'in_flight', v_flight, 'returned_runs', v_returned,
                            'unplanned_runs', v_unplanned, 'cancelled_runs', v_cancelled,
                            'next_run_day', private.next_scheduled_run_day(c.id, v_today + 1),
                            'today', v_today);
end;
$$;

-- private.transfer_file_release, redefined from 20261115090000_transfers_files.sql (line 1669; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (H): a downloaded file released never re-issues a payout whose run is no longer approved or sent, nor a
-- refund no longer requested: cancelled, its reason saying it was not re-issued. Nothing else changes.
create or replace function private.transfer_file_release(p_file_id uuid, p_status text, p_reason text,
                                                         p_attestation text, p_superseded_by uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.transfer_file;
  v_n integer := 0;
  v_back integer;
  o public.bank_transfer;
  v_e2e text;
  v_new uuid;
begin
  select * into f from public.transfer_file where id = p_file_id for update;
  if f.status in ('superseded', 'rejected', 'failed') then
    return 0;
  end if;
  update public.transfer_file set status = p_status, closed_at = clock_timestamp(), closed_by = auth.uid(),
    close_reason = p_reason, close_attestation = p_attestation, superseded_by = p_superseded_by,
    version = version + 1
  where id = f.id;
  update public.bank_transfer t set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
    cancel_reason = 'Fichier ' || f.number || ' retiré : la quote-part est recalculée au prochain fichier'
  where t.transfer_file_id = f.id and t.status = 'in_file' and t.kind = 'sweep';
  if f.download_count > 0 then
    for o in select * from public.bank_transfer t
             where t.transfer_file_id = f.id and t.status = 'in_file' and t.kind in ('payout', 'refund')
             order by t.id for update loop
      -- M2c-6b-3a-2 (H): a payout whose run is no longer approved or sent (booked: a late predecessor's), or a refund
      -- no longer requested, is cancelled and never re-issued (defence in depth: no command reaches it); its run's and
      -- its refund's pointers stay
      if (o.kind = 'payout' and not exists (select 1 from public.remittance_run r
                                            where r.id = o.run_id and r.status in ('approved', 'sent')))
         or (o.kind = 'refund' and not exists (select 1 from public.refund_request q
                                               where q.transfer_id = o.id and q.status = 'requested')) then
        update public.bank_transfer set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
          cancel_reason = 'Fichier ' || f.number || ' annulé après téléchargement : non réémis ('
                          || case o.kind when 'payout' then 'son reversement n''est plus en cours'
                                         else 'son remboursement n''est plus demandé' end || ')'
        where id = o.id;
        continue;
      end if;
      v_e2e := left(o.end_to_end_id, 3) || upper(substr(md5(gen_random_uuid()::text), 1, 12));
      update public.bank_transfer set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
        cancel_reason = 'Fichier ' || f.number || ' annulé après téléchargement : virement réémis sous ' || v_e2e
      where id = o.id;
      insert into public.bank_transfer (organization_id, client_organization_id, kind, debtor_bank_account_id,
                                        creditor_bank_account_id, currency, run_id, amount_minor, payee_name, payee_iban,
                                        payee_bic, end_to_end_id, remittance_info, requested_execution_date, reason,
                                        ordered_by, replaces_transfer_id)
      values (o.organization_id, o.client_organization_id, o.kind, o.debtor_bank_account_id, o.creditor_bank_account_id,
              o.currency, o.run_id, o.amount_minor, o.payee_name, o.payee_iban, o.payee_bic, v_e2e,
              case when o.kind = 'refund' then 'REMBOURSEMENT ' || v_e2e else o.remittance_info end,
              o.requested_execution_date, o.reason, o.ordered_by, o.id)
      returning id into v_new;
      update public.remittance_run set transfer_id = v_new, version = version + 1 where transfer_id = o.id;
      update public.refund_request set transfer_id = v_new, end_to_end_id = v_e2e where transfer_id = o.id;
      v_n := v_n + 1;
    end loop;
  end if;
  update public.bank_transfer t set status = 'ordered', transfer_file_id = null
  where t.transfer_file_id = f.id and t.status = 'in_file';
  get diagnostics v_back = row_count;
  v_n := v_n + v_back;
  -- its runs whose transfer is ordered again (the same, or the one re-issuing it)
  update public.remittance_run r set status = 'approved', version = version + 1
  where r.id in (select t.run_id from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
                 where i.file_id = f.id and t.run_id is not null)
    and r.status = 'sent'
    and exists (select 1 from public.bank_transfer x where x.id = r.transfer_id and x.status = 'ordered');
  return v_n;
end;
$$;

-- private.link_debit_guard, redefined from 20261118090000_switch_on_prerequisites.sql (line 2820; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (6b-3a review, low): a manual refund's link (its request has no transfer of ours) to a debit without
-- reference is refused payout_candidate while a transfer cancelled out of a downloaded file bars the line
-- (private.refund_line_barred_by). Nothing else changes.
create or replace function private.link_debit_guard(p_line_id uuid, p_kind text, p_refund_request_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  v_kind text;
  v_class text;
  v_refund_transfer uuid;
  v_refused boolean;
  v_own boolean;
begin
  select * into t from public.bank_transaction where id = p_line_id;
  if not found then
    return null;
  end if;
  if t.direction = 'credit' then
    -- (the line « Comptabiliser… » is offered on: private.transfer_line_bookable_as' n — never an entry kept unsplit,
    -- whose total is not one movement and which keeps the explanation)
    if p_kind not in ('explained', 'refund_returned') or t.counterparty_iban is null or t.unsplit_ours is not null then
      return null;
    end if;
    select coalesce(d.released_kind, t.kind) into v_kind
    from (select 1) z left join public.bank_duplicate_resolution d on d.bank_transaction_id = t.id;
    if v_kind = 'return' and private.transfer_line_class(t.id) in ('N', 'O', 'E0')
       and exists (select 1 from public.client_payout_account a
                   where a.organization_id = t.organization_id and a.iban = t.counterparty_iban
                     and a.currency = t.currency and a.confirmed_at is not null
                     and a.status in ('active', 'returned', 'retired'))
       -- (round 3) a refund sent to that IBAN comes back from it: « Remboursement revenu » of that refund
       and not (p_kind = 'refund_returned'
                and exists (select 1 from public.refund_request q
                            where q.id = p_refund_request_id and q.organization_id = t.organization_id
                              and q.payee_iban = t.counterparty_iban)) then
      return 'client_payout_line';
    end if;
    return null;
  end if;
  if t.direction <> 'debit' or p_kind not in ('fee', 'explained', 'refund', 'return', 'loss') then
    return null;
  end if;
  v_class := private.transfer_line_class(t.id);
  if v_class not in ('N', 'O', 'E0') then
    return null;
  end if;
  select coalesce(d.released_kind, t.kind) into v_kind
  from (select 1) z left join public.bank_duplicate_resolution d on d.bank_transaction_id = t.id;
  -- (review 6b-2c round 2, return-link-blocked-by-amount-twin) a payment's return and its loss are refused only on a
  -- debit of a kind « Comptabiliser… » books (private.transfer_line_bookable_as' n: transfer_out, other_debit,
  -- batch_unsplit, as a held line was released). A debit the bank flags as a return — a debtor's payment taken back —
  -- is never booked as a transfer of ours (not_a_transfer_line): were it refused here too, it would have no action at
  -- all, and the payment would stay allocated, its money paid to the client although the bank took it back (I13)
  if p_kind in ('return', 'loss') and v_kind not in ('transfer_out', 'other_debit', 'batch_unsplit') then
    return null;
  end if;
  if p_kind = 'refund' then
    select q.transfer_id into v_refund_transfer from public.refund_request q
    where q.id = p_refund_request_id and q.organization_id = t.organization_id;
  end if;
  -- M2c-6b-3a-2 (6b-3a review, low): a manual refund (no transfer of ours: the refund's trigger never reads the line) on
  -- a debit naming neither an end-to-end id nor a PmtInf, while a transfer cancelled out of a downloaded file bars it
  -- (private.refund_line_barred_by: the trigger's rule for a refund not handed out — another payment's cancelled
  -- refund, a cancelled payout, a cancelled sweep): refused here too, not only hidden by « Lier »
  if p_kind = 'refund' and v_refund_transfer is null and t.end_to_end_id is null and t.payment_info_id is null
     and private.refund_line_barred_by(t.id, p_refund_request_id) is not null then
    return 'payout_candidate';
  end if;
  -- (the refund link: a candidate other than that refund's own transfer, a sweep apart — review round 7's founder
  -- decision, N1 (b), pinned by 033: a reference-less line executes a refund in a downloaded or sent file even beside
  -- the servicer's sweep of its amount in the same file)
  -- (round 3) a payment's return and its loss: only a candidate that may still be paid out by this line — (i), (ii),
  -- or a cancelled payout whose run is still approved or sent (its run by key) — never one only returned, or cancelled
  -- with its run ended (iii for good: COMPLIANCE OQ-86's default)
  -- (6b-2d, refund-link-blocked-by-returned-payout-twin) the refund link alike: (iii) never refuses it (OQ-86)
  -- (M2c-6b-3a review round 1, DP-2) but for the refund link a payout cancelled out of a downloaded file (iii, cancelled:
  -- never one only returned) or a sweep cancelled so (iv) refuses it whatever its run: the line may be its late
  -- execution, and linked as a refund it would close that late debit and lift M's and A's holds
  select coalesce(bool_or(c.transfer_id is distinct from v_refund_transfer
                          and (p_kind <> 'refund' or c.kind <> 'sweep' or c.cand = 'iv')
                          and (p_kind not in ('return', 'loss', 'refund') or c.cand in ('i', 'ii')
                               or (c.status = 'cancelled' and r.status in ('approved', 'sent'))
                               or (p_kind = 'refund' and c.status = 'cancelled' and c.kind in ('payout', 'sweep')))),
                  false),
         coalesce(bool_or(c.transfer_id = v_refund_transfer), false)
  into v_refused, v_own
  from private.transfer_line_candidates(t.id, v_class) c
  left join lateral (select r.status from public.remittance_run r where r.id = c.run_id offset 0) r on true;
  if v_refused then
    return 'payout_candidate';
  end if;
  -- (round 3) the refund link on a line its own transfer may be (rule 3b's (ii): its payee IBAN is the line's) is that
  -- refund's debit, wherever it was sent
  if t.counterparty_iban is not null and not (p_kind = 'refund' and v_own)
     and exists (select 1 from public.client_payout_account a
                 where a.organization_id = t.organization_id and a.iban = t.counterparty_iban
                   and a.currency = t.currency and a.confirmed_at is not null
                   and a.status in ('active', 'returned', 'retired')) then
    return 'client_payout_line';
  end if;
  if p_kind = 'explained' and v_kind = 'transfer_out' and t.counterparty_iban is not null
     and exists (select 1 from public.bank_account o
                 where o.organization_id = t.organization_id and o.purpose = 'own' and o.status = 'active'
                   and o.iban = t.counterparty_iban and o.currency = t.currency) then
    return 'own_transfer_out_line';
  end if;
  return null;
end;
$$;

-- public.cancel_remittance_run, redefined from 20261116090000_debit_bookings.sql (line 5080; same signature and settings, its grants restated below).
-- M2c-6b-3a-2 (6b-3a review, LD-3): its transfer_already_debited hint names the exit (« Comptabiliser… » in « Débits et
-- retours »), true both ways. Nothing else changes.
create or replace function public.cancel_remittance_run(p_idempotency_key text, p_run_id uuid,
                                                        p_expected_version integer, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  r public.remittance_run;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('run_id', p_run_id, 'expected_version', p_expected_version, 'reason', v_reason);
  v_result jsonb;
  v_docs jsonb;
  v_restore jsonb;
  v_issued jsonb;
  v_n integer;
  v_today date := private.paris_today();
  t public.bank_transfer;
  f public.transfer_file;
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or not private.has_role(r.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('cancel_remittance_run', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  select * into r from public.remittance_run where id = p_run_id for update;
  perform private.remittance_command_locks(r.organization_id, true);
  if r.status not in ('approved', 'sent') then
    raise exception 'remittance run refused: %', case r.status when 'draft' then 'draft_use_discard'
                                                               else 'not_cancellable' end
      using errcode = 'check_violation';
  end if;
  if p_expected_version is distinct from r.version then
    raise exception 'remittance run refused: version_changed' using errcode = 'check_violation';
  end if;
  -- M2c-6a (§9.7; compliance critique D7, ops critique #6; review T1): the payout, under the remit lock. Before any file
  -- holding it is downloaded it is cancelled (its file, not downloaded, is superseded: the other transfers go in the
  -- next one). After download the file stays as it was handed out — counted by the cash check, the run by the
  -- per-client cap — until that transfer is cancelled on the statements' evidence by two people (then: `cancelled`).
  select * into t from public.bank_transfer x where x.id = r.transfer_id for update;
  if t.status = 'in_file' then
    select * into f from public.transfer_file x where x.id = t.transfer_file_id for update;
    if f.status in ('pending', 'generated') then
      perform private.transfer_file_release(f.id, 'superseded', 'Reversement ' || r.number || ' annulé', null, null);
      select * into t from public.bank_transfer x where x.id = t.id;
    else
      raise exception 'remittance run refused: payout_in_downloaded_file' using errcode = 'check_violation',
        detail = jsonb_build_object('file_id', f.id, 'file', f.number, 'transfer_id', t.id)::text,
        hint = case when private.switch_on('downloaded_file_cancellation')
                    then 'Le fichier a été téléchargé : faites d''abord annuler le virement, relevé à l''appui.'
                    else 'Le virement de ce reversement est dans un fichier déjà téléchargé : il reste en cours jusqu''à ce que son débit soit comptabilisé depuis le relevé, à son arrivée (de même, ensuite, le retour de la banque du bénéficiaire, si elle le renvoie), et le reversement ne peut pas être annulé d''ici là (l''annulation après téléchargement n''est pas encore disponible). Un virement que la banque refuse avant son exécution n''apparaît sur aucun relevé : il reste « en cours » jusqu''à ce que l''annulation après téléchargement soit disponible. Gardez le fichier tel quel, vérifiez le relevé, voyez avec la banque et prévenez le support.' end;
    end if;
  end if;
  if t.id is not null and t.status not in ('ordered', 'cancelled') then
    raise exception 'remittance run refused: transfer_%', t.status using errcode = 'check_violation';
  end if;
  -- review round 3 (E2, N2): its payout, or one it re-issues, has left the account already (a cancelled file executed
  -- late, a « refused » transfer debited after all): cancelling the run would put its lines back to be paid again
  if t.id is not null and private.transfer_debited_before(t.id) then
    raise exception 'remittance run refused: transfer_already_debited' using errcode = 'check_violation',
      detail = jsonb_build_object('transfer_id', t.id, 'end_to_end_id', t.end_to_end_id)::text,
      -- M2c-6b-3a-2 (6b-3a review, LD-3): the exit named, true both ways (a debit without our references only once
      -- cancellation after download is on)
      hint = 'Un relevé montre déjà le débit de ce reversement (sous sa référence, celle du virement qu''il remplace, ou dans une ligne groupée de son lot), ou un débit sans nos références de son montant peut en être l''exécution : ne l''annulez pas ; comptabilisez ce débit dans « Débits et retours » (« Comptabiliser… ») — le reversement est alors comptabilisé comme payé.';
  end if;
  update public.bank_transfer set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = clock_timestamp(),
    cancel_reason = left('Reversement ' || r.number || ' annulé : ' || v_reason, 2000)
  where id = t.id and status = 'ordered';

  -- 1. one full credit note per invoice of the run: what each still charges each key, its VAT by cumulative
  -- difference at the invoice's own rate, off its pending VAT first
  with inv as (
    select i.*, coalesce((select -sum(c.ht_minor) from public.commission_credit_correction c
                          where c.original_invoice_id = i.id), 0) as credited_before,
           private.document_open(i.id) as open_before, private.document_pending_vat(i.id) as pending_before
    from public.commission_invoice i where i.run_id = r.id and i.kind = 'invoice' and i.reason = 'commission'),
  keys as (
    select i.id as invoice_id, ch.account_id, ch.tier_key,
           ch.charged_minor + coalesce((select sum(a.ht_minor) from public.commission_credit_alloc a
                                        where a.original_invoice_id = ch.invoice_id and a.account_id = ch.account_id
                                          and a.tier_key = ch.tier_key), 0) as open
    from inv i join public.commission_invoice_charge ch on ch.invoice_id = i.id),
  amounts as (
    select i.*, k.ht, round((i.credited_before + k.ht) * i.vat_rate) - round(i.credited_before * i.vat_rate) as vat
    from inv i join (select invoice_id, sum(open) as ht from keys where open > 0 group by invoice_id) k
      on k.invoice_id = i.id)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', gen_random_uuid(), 'ref', 'cancel:' || a.id, 'key', 'crn-cancel:' || a.id, 'kind', 'credit_note',
           'mandate_id', a.mandate_id, 'ht', (-a.ht)::text, 'vat', (-a.vat)::bigint::text,
           'ttc', (-a.ht - a.vat)::bigint::text,
           'lines', jsonb_build_array(jsonb_build_object(
             'kind', 'credit', 'designation_fr', 'Annulation du reversement ' || r.number || ' — avoir rectifiant la '
                                                  || 'facture ' || a.number || ' du ' || to_char(a.issue_date, 'DD/MM/YYYY'),
             'ht', (-a.ht)::text, 'vat_rate', a.vat_rate::text, 'original_invoice_id', a.id)),
           'allocations', (select jsonb_agg(jsonb_build_object('original_invoice_id', k.invoice_id,
                                                               'account_id', k.account_id, 'tier_key', k.tier_key,
                                                               'ht', (-k.open)::text)
                                            order by k.account_id, k.tier_key)
                           from keys k where k.invoice_id = a.id and k.open > 0),
           'corrections', jsonb_build_array(jsonb_build_object(
             'original_invoice_id', a.id, 'vat_rate', a.vat_rate::text, 'ht', (-a.ht)::text,
             'vat', (-a.vat)::bigint::text,
             'vat_pending', least(a.vat::bigint, a.pending_before)::text,
             'vat_collected', (a.vat::bigint - least(a.vat::bigint, a.pending_before))::text,
             'applied', least(a.ht + a.vat::bigint, a.open_before)::text,
             'excess', (a.ht + a.vat::bigint - least(a.ht + a.vat::bigint, a.open_before))::text,
             'open_before', a.open_before::text))) order by a.seq), '[]')
  into v_docs from amounts a;

  -- 2. the run's own credit notes on earlier invoices undone (money review #0): per mandate and VAT rate, one corrective
  -- invoice charging again, per (file, tier key), the HT they took back, at each credited invoice's own rate — so that
  -- the tier history goes back exactly as before the run and the next run credits each reversal once (on this invoice:
  -- it charges the line now). Its VAT is its own HT's, R(HT × rate) half up as every invoice's (242 nonies A 11°) and
  -- as the engine assumes when it credits it (round 2: the sum of the VATs credited, each by cumulative difference on
  -- its own invoice, is not, and the re-run then credited a cent more than it charged, or left one pending); it differs
  -- from what was credited by under a cent per invoice credited, until the re-run credits it in full. Dated over the
  -- service periods of the invoices it charges again; settled as the mandate's terms say today — netted, set off on
  -- the next run at the latest by its due date, or due (legal review #4, round 2; OQ-72).
  with crd as (   -- per credit note of the run and invoice it corrected: what it took back
    select cn.mandate_id, cn.number as credit_number, c.original_invoice_id, o.number as original_number,
           o.issue_date as original_date, o.vat_rate, -c.ht_minor as ht, o.service_from, o.service_to, cn.seq
    from public.commission_invoice cn
    join public.commission_credit_correction c on c.credit_note_id = cn.id
    join public.commission_invoice o on o.id = c.original_invoice_id
    where cn.run_id = r.id and cn.kind = 'credit_note' and cn.reason = 'commission'),
  keys as (       -- per mandate, rate and (file, tier key): what they took back
    select cn.mandate_id, o.vat_rate, a.account_id, a.tier_key, -sum(a.ht_minor) as ht
    from public.commission_invoice cn
    join public.commission_credit_alloc a on a.credit_note_id = cn.id
    join public.commission_invoice o on o.id = a.original_invoice_id
    where cn.run_id = r.id and cn.kind = 'credit_note' and cn.reason = 'commission'
    group by cn.mandate_id, o.vat_rate, a.account_id, a.tier_key),
  docs as (
    select x.mandate_id, x.vat_rate, sum(x.ht) as ht, round(sum(x.ht) * x.vat_rate)::bigint as vat, m.reference,
           min(x.service_from) as service_from, max(x.service_to) as service_to,
           (select mt.remittance_terms from public.mandate_terms mt
            where mt.mandate_id = x.mandate_id and mt.valid_from <= v_today
              and (mt.valid_to is null or v_today < mt.valid_to)
            order by mt.valid_from desc limit 1) as terms
    from crd x join public.mandate m on m.id = x.mandate_id
    group by x.mandate_id, x.vat_rate, m.reference)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', gen_random_uuid(), 'ref', 'restore:' || d.mandate_id || ':' || d.vat_rate,
           'key', 'inv-restore:' || r.id || ':' || d.mandate_id || ':' || d.vat_rate, 'kind', 'invoice',
           'mandate_id', d.mandate_id, 'ht', d.ht::text, 'vat', d.vat::text, 'ttc', (d.ht + d.vat)::text,
           'vat_rate', d.vat_rate::text, 'service_from', d.service_from, 'service_to', d.service_to,
           'settlement', case when jsonb_typeof(d.terms -> 'netting') = 'object' then 'netted' else 'due' end,
           'payment', case when jsonb_typeof(d.terms -> 'netting') = 'object' then 'next_run' end,
           'due_days', coalesce((d.terms ->> 'invoice_payment_days')::integer, 30),
           'clause_ref', d.terms #>> '{netting,clause_ref}',
           'lines', (select jsonb_agg(jsonb_build_object(
                       'kind', 'commission',
                       'designation_fr', 'Annulation du reversement ' || r.number || ' — rétablissement de l''avoir '
                                         || x.credit_number || ' (facture ' || x.original_number || ' du '
                                         || to_char(x.original_date, 'DD/MM/YYYY') || ')',
                       'ht', x.ht::text, 'vat_rate', x.vat_rate::text) order by x.seq, x.original_number)
                     from crd x where x.mandate_id = d.mandate_id and x.vat_rate = d.vat_rate),
           'charges', (select jsonb_agg(jsonb_build_object('account_id', k.account_id, 'tier_key', k.tier_key,
                                                           'amount', k.ht::text) order by k.account_id, k.tier_key)
                       from keys k where k.mandate_id = d.mandate_id and k.vat_rate = d.vat_rate))
           order by d.reference, d.mandate_id, d.vat_rate), '[]')
  into v_restore from docs d;
  v_issued := private.issue_commission_documents(r.organization_id, r.client_organization_id, r.id,
                                                 v_docs || v_restore, 'run_cancelled');

  -- 3. the waivers (M2c-5b): the run's own invoices are credited in full above, so what manual credit notes left
  -- waived on them is cleared (none since review ledger-vat#0: a manual credit note on the invoice of a run in flight is
  -- refused); what the run's credits absorbed of earlier invoices' waivers is restored (review math#0) on the corrective
  -- invoice of the absorbing invoice's mandate and VAT rate, which then holds again all the run took at that rate — its
  -- charge what the run's credit notes credited (0 for a key the run only absorbed there), its waiver what they
  -- absorbed — as the corrective invoice of the same history without manual credit notes charges it; where the
  -- cancellation issued none at that rate (all the run took there was absorbed: nothing to charge again), on the
  -- absorbing invoice itself, so the file is exactly as before the run. One row per absorption, with its line: the next
  -- run credits each reversal first where its own share went back, up to that share (`jobs.remittances`).
  insert into public.commission_waiver (organization_id, client_organization_id, invoice_id, account_id, tier_key,
                                        amount_minor, cause, run_id)
  select r.organization_id, r.client_organization_id, w.invoice_id, w.account_id, w.tier_key, -sum(w.amount_minor),
         'run_cancelled', r.id
  from public.commission_invoice i
  join public.commission_waiver w on w.invoice_id = i.id
  where i.run_id = r.id and i.kind = 'invoice' and i.reason = 'commission'
  group by w.invoice_id, w.account_id, w.tier_key
  having sum(w.amount_minor) > 0;
  drop table if exists pg_temp._restore;
  create temp table _restore on commit drop as
  select w.account_id, w.tier_key, w.entry_id, -w.amount_minor as amount, coalesce(j.id, w.invoice_id) as invoice_id,
         j.id is not null as on_corrective
  from public.commission_waiver w
  cross join lateral (select q.mandate_id, q.vat_rate from public.commission_invoice q where q.id = w.invoice_id
                      offset 0) o
  left join lateral (select q.id from public.commission_invoice q
                     where q.run_id = r.id and q.kind = 'invoice' and q.reason = 'run_cancelled'
                       and q.mandate_id = o.mandate_id and q.vat_rate = o.vat_rate offset 0) j on true
  where w.run_id = r.id and w.cause = 'absorbed';
  insert into public.commission_invoice_charge (invoice_id, account_id, tier_key, charged_minor)
  select distinct x.invoice_id, x.account_id, x.tier_key, 0::bigint
  from pg_temp._restore x
  where x.on_corrective
    and not exists (select 1 from public.commission_invoice_charge ch
                    where ch.invoice_id = x.invoice_id and ch.account_id = x.account_id and ch.tier_key = x.tier_key);
  insert into public.commission_waiver (organization_id, client_organization_id, invoice_id, account_id, tier_key,
                                        amount_minor, cause, run_id, entry_id)
  select r.organization_id, r.client_organization_id, x.invoice_id, x.account_id, x.tier_key, x.amount, 'restored',
         r.id, x.entry_id
  from pg_temp._restore x;

  -- 4. the lines released, their items back in the queue (posted when they were); the history exactly as before the
  -- run (its documents credited or restored: what the invoices still charge each key, plus the waivers, is that
  -- state's commission; the waiver the key's invoices hold now — manual credit notes since the run included)
  update public.remittance_line set released = true, released_at = clock_timestamp() where run_id = r.id;
  get diagnostics v_n = row_count;
  insert into private.remittance_pending (ledger_entry_id, organization_id, client_organization_id, currency, kind,
                                          amount_minor, posted_at)
  select l.ledger_entry_id, l.organization_id, l.client_organization_id, l.currency, l.kind, l.amount_minor, l.posted_at
  from public.remittance_line l where l.run_id = r.id;
  insert into public.remittance_key_state (organization_id, client_organization_id, account_id, tier_key, run_id, cause,
                                           basis, kept_basis_minor, kept_minor, commission_minor, waived_minor)
  select r.organization_id, r.client_organization_id, k.account_id, k.tier_key, r.id, 'cancelled',
         coalesce(p.basis, '[]'), coalesce(p.kept_basis_minor, 0), coalesce(p.kept_minor, 0),
         coalesce(p.commission_minor, 0), w.waived
  from public.remittance_key_state k
  left join lateral (select x.basis, x.kept_basis_minor, x.kept_minor, x.commission_minor
                     from public.remittance_key_state x
                     where x.account_id = k.account_id and x.tier_key = k.tier_key and x.seq < k.seq
                     order by x.seq desc limit 1) p on true
  cross join lateral (select coalesce(sum(y.amount_minor), 0) as waived from public.commission_waiver y
                      where y.account_id = k.account_id and y.tier_key = k.tier_key) w
  where k.run_id = r.id and k.cause = 'approved';
  -- (the engine's input check where the run credited earlier invoices or moved waivers — elsewhere the run's invoice
  -- is credited in full: what the invoices still charge each such key, plus their waivers, is the state's commission
  -- again, the waivers the state's; keyed, per such key)
  if exists (select 1
             from (select a.account_id, a.tier_key from public.commission_invoice cn
                   join public.commission_credit_alloc a on a.credit_note_id = cn.id
                   where cn.run_id = r.id and cn.kind = 'credit_note' and cn.reason = 'commission'
                   union
                   select w.account_id, w.tier_key from public.commission_waiver w where w.run_id = r.id
                   offset 0) x
             cross join lateral (select k.commission_minor, k.waived_minor from public.remittance_key_state k
                                 where k.account_id = x.account_id and k.tier_key = x.tier_key
                                 order by k.seq desc limit 1) st
             cross join lateral private.commission_key_open(x.account_id, x.tier_key) o
             where o.open_minor + o.waived_minor <> st.commission_minor or o.waived_minor <> st.waived_minor
                or o.negative) then
    raise exception 'cancellation of %: the tier history and the documents disagree', r.number using errcode = '23514';
  end if;
  update public.remittance_run set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = clock_timestamp(),
    cancel_reason = v_reason, version = version + 1
  where id = r.id;
  v_result := jsonb_build_object('run_id', r.id, 'status', 'cancelled', 'lines_released', v_n,
                                 'credit_notes', v_issued -> 'documents');
  perform private.command_record('cancel_remittance_run', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new internal revoked)
------------------------------------------------------------------------------------------

-- the new internal (PostgreSQL grants EXECUTE to PUBLIC by default): only the SECURITY DEFINER callers use it
revoke execute on function private.transfer_late_predecessor(uuid) from public, anon, authenticated, service_role;
-- review round 1's new internal alike (its private.transfer_named_debit_on replaced in round 4)
revoke execute on function private.transfer_unsplit_debit_seen(uuid, text)
  from public, anon, authenticated, service_role;
-- review round 2's new internals alike
revoke execute on function private.transfer_chain_unplanned(uuid), private.transfer_return_partner(uuid),
  private.remittance_run_paid_on(uuid)
  from public, anon, authenticated, service_role;
-- review round 4's new internals alike (round 3's private.transfer_return_known replaced by them)
revoke execute on function private.remittance_chain_events(uuid, uuid, uuid),
  private.remittance_chain_paid(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
-- review round 2's redefined internals, as granted by 20261117090000 (private.transfer_unplanned_open) and
-- 20261117100000 (private.transfer_line_open_unplanned)
revoke execute on function private.transfer_unplanned_open(uuid) from public, anon, authenticated;
revoke execute on function private.transfer_line_open_unplanned(uuid, uuid, uuid, text, text)
  from public, anon, authenticated, service_role;
-- review round 1's redefined internals, as granted by 20261118090000 (private.transfer_debited_before,
-- private.transfer_cancel_evidence) and 20261117090000 (private.transfer_late_lines)
revoke execute on function private.transfer_debited_before(uuid), private.transfer_cancel_evidence(uuid, uuid, boolean)
  from public, anon, authenticated;
revoke execute on function private.transfer_late_lines(uuid) from public, anon, authenticated, service_role;
-- the command's internals, as granted by 20261117100000, 20261117105000 (private.transfer_line_locks), 20261117110000
-- (private.transfer_line_parts_json) and 20261118090000 (private.transfer_line_check, private.transfer_line_options_of,
-- private.run_transfer_checks, private.link_debit_guard)
revoke execute on function private.transfer_line_check(uuid, boolean), private.transfer_line_options_of(uuid),
  private.transfer_line_locks(uuid), private.transfer_line_text(), private.transfer_line_parts_json(),
  private.transfer_line_post(uuid, text), private.transfer_line_returnable(uuid),
  private.run_transfer_checks(uuid, uuid, date), private.run_remittance_runs_checks(uuid, uuid, date),
  private.link_debit_guard(uuid, text, uuid)
  from public, anon, authenticated, service_role;
-- as granted by 20261117100000 (the funds pass's posting and its guard: internal)
revoke execute on function private.bank_line_booking_guard(), private.bank_booking_post_rows(uuid)
  from public, anon, authenticated, service_role;
-- as granted by 20261117100000 and 20261116090000 (the worker's: the remittance schedule, the checks job)
revoke execute on function private.pending_item_deadlines(uuid, boolean), private.run_payment_checks(uuid)
  from public, anon, authenticated;
grant execute on function private.pending_item_deadlines(uuid, boolean), private.run_payment_checks(uuid)
  to service_role;
-- as granted by 20261115090000 (internal)
revoke execute on function private.transfer_file_release(uuid, text, text, text, uuid) from public, anon, authenticated;
-- the back office's commands and reads (aal2 money staff or whole-client members, checked inside), as granted by
-- 20261116090000 (public.cancel_remittance_run, public.client_remittance_summary) and 20261117110000
-- (public.remittance_run_payout)
revoke execute on function public.remittance_run_payout(uuid), public.client_remittance_summary(uuid),
  public.cancel_remittance_run(text, uuid, integer, text)
  from public, anon;
grant execute on function public.remittance_run_payout(uuid), public.client_remittance_summary(uuid),
  public.cancel_remittance_run(text, uuid, integer, text)
  to authenticated;
