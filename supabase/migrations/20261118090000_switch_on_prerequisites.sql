-- M2c-6b-3a: the switch-on prerequisites (docs/design/m2c-6b-3-plan.md §2 A, A′, B, C, D, K, L, M, N; ADR-0014
-- « M2c-6b-3a »; COMPLIANCE OQ-80 (k), (n), (o), (p), OQ-81, OQ-82). THE SWITCH STAYS OFF: no statement here writes
-- private.feature_switch; 6b-3b flips 'downloaded_file_cancellation' with a one-line migration once the founder answers
-- Q1 (OQ-81 (a)). Every rule below bites only in states that need a downloaded file's transfer to be cancelled (a
-- cancelled transfer of a downloaded file, a re-issue, a file superseded or rejected after download, a cancellation
-- request — whose commands refuse `bank_booking_required` before reading the evidence while the switch is off):
-- production has none, and pgTAP 033 (the switch-off test) is unchanged. The two partial indexes, and the transfer line
-- options' reading of a re-issue's or a re-made sweep's own debit (below, K), are the only changes that are not inert.
-- pgTAP 034 passes with its todo() lines removed; 039 holds the follow-ups, each with the switch on inside its own
-- subtransaction.
--   * L: a debit carrying none of our references (a CSV export without the end-to-end column, a camt.053 entry without
--     references) at a cancelled transfer's amount, to its payee's IBAN or none, from its execution date in a
--     downloaded file, not booked nor linked, is a possible late execution of it (private.transfer_unreferenced_lines):
--     private.transfer_debited_before counts it for a chain member and a cancelled transfer — the re-issue is held, the
--     run's and the refund's cancellation refused, the alerts raised (OQ-80 (p): until ops classify the line);
--   * K: rule 3b's (iv), a refund or a sweep cancelled out of a downloaded file, is a candidate: the line is ambiguous
--     beside another; alone, a sweep's late debit is proposed and booked as that sweep's (`unplanned_sweep` of it), a
--     refund's is refused `cancelled_transfer_matches` (no booking kind yet: OQ-81 (b), S25), never an unplanned payout
--     or sweep with no transfer. Review round 1 (LD-1, LD-2): never a cancelled payout (iii) beside an in-flight payout
--     (i) that re-issues it or whose run took its run's collections again, nor a cancelled sweep (iv) beside an
--     in-flight sweep (i) made after its cancellation — the line is that in-flight transfer's own debit (OQ-80 (q));
--   * N: the cancellation evidence refuses `unreferenced_debit_open` while such a line may be the file's (or the one
--     transfer's) execution, or a PmtInf's sum as one line;
--   * A, A′: a sweep made after a cancelled sweep whose late debit is open, or was booked after it was made, is held
--     (`cancelled_sweep_debited`: generation's D4, the download's two re-checks, the nightly alert) — servicer-wide over
--     its dedicated accounts of the currency, whatever their status; the new sweep's created_at is the clock time read
--     under the remit lock, the booking compared by its entry's posted_at;
--   * B: once ops book a cancelled sweep's late debit, generation proposes the servicer's share again (private.
--     debited_cancelled_sweeps reads the open late debits only); a second late line stops it again;
--   * C (G1c): a cancelled payout or refund that was in a downloaded file, debited after all, its line not booked nor
--     linked, is alerted whatever its run's or refund's state — but while the live end of its chain is alerted instead;
--   * D (H-PAY): such a line does not execute a refund in a downloaded or sent file while a cancelled refund of the
--     account at its amount (any payment) may be it — its hint by the account's feed; « Lier » does not offer it; a
--     refund whose transfer is ordered is still executed by it — review round 1 (DP-1): unless that cancelled refund is
--     of another payment (refused `cancelled_transfer_matches`); (DP-2) nor while a payout or a sweep cancelled out of a
--     downloaded file may be it (`private.link_debit_guard`: `payout_candidate`; the trigger alike);
--   * M: a payout in flight is held while a cancelled payout of its client (its run ended) shows an open late debit, a
--     refund while another refund of its payment does (`client_payout_debited_late`, `payment_refund_debited_late`);
--   * public.cancellation_after_download: the flag, for the pages that word their texts both ways.
-- E–J of the plan (the late predecessor booked as its run's payout, its readers and its return, the release's defence in
-- depth, the R124-6 in-flight rows of a re-issue, P across two transfers) are 6b-3a-2's (plan §5's split point: this
-- migration passed 2,500 lines with A–D and K–N): 6b-3b needs both.
--
-- New: private.transfer_unreferenced_lines, private.transfer_late_debit_open, private.sweep_after_debited_cancelled,
-- private.transfer_sibling_debited_late, private.refund_line_barred_by (internal), public.cancellation_after_download
-- (the back office's). Redefined, each copied from its latest definition across all the migration files and changed only
-- as its comment says, with SECURITY DEFINER, every SET clause, search_path and its grants restated:
--   private.transfer_debited_before (20261115090000_transfers_files.sql:1221)
--   private.debited_cancelled_sweeps (20261115090000_transfers_files.sql:1269)
--   private.transfer_line_candidates (20261117110000_transfer_line_pages.sql:2009)
--   private.transfer_line_check (20261117110000_transfer_line_pages.sql:452)
--   private.transfer_line_options_of (20261117110000_transfer_line_pages.sql:117)
--   private.transfer_cancel_evidence (20261115090000_transfers_files.sql:1435)
--   private.run_transfer_checks (20261117110000_transfer_line_pages.sql:1637)
--   public.transfer_overview (20261115090000_transfers_files.sql:3308)
--   public.generate_transfer_file (20261116090000_debit_bookings.sql:276)
--   public.transfer_file_download (20261117090000_transfer_line_foundations.sql:1596)
--   private.transfer_hold_reason (20261115090000_transfers_files.sql:1587)
--   private.refund_transfer_follow (20261116090000_debit_bookings.sql:4683)
--   public.debit_link_options (20261117110000_transfer_line_pages.sql:2623)
--   private.link_debit_guard (20261117113000_transfer_line_pages_fixes.sql:265; review round 1, DP-2)

------------------------------------------------------------------------------------------
-- L: a debit carrying none of our references, a possible late execution of a cancelled transfer (plan §2 L)
------------------------------------------------------------------------------------------

-- The account's debits of a transfer's amount (L, N, D: transfer_unreferenced_lines and the evidence's batch sum probe
-- (account, amount) on the debits; bank_transaction_other_debit_amount_idx is kind 'other_debit' only, and
-- bank_transaction_same_day_idx leads with the booking date after the account)
create index bank_transaction_debit_amount_idx on public.bank_transaction (bank_account_id, amount_minor)
  where direction = 'debit';
-- A client's cancelled payouts that were filed (M: the client's other payouts held; bank_transfer_payout_iban_idx is the
-- booked payouts', bank_transfer_cancelled_filed_idx is led by the servicer and the paying account)
create index bank_transfer_client_cancelled_idx on public.bank_transfer (client_organization_id, currency)
  where kind = 'payout' and status = 'cancelled' and transfer_file_id is not null;
-- (A refund transfer's request, M: by refund_request_transfer_id_key, the unique index of refund_request.transfer_id
-- since 20261115090000. Review round 1, CSC-2: the quadratic plan the 5,000-refund scale file showed — each in-flight
-- refund's hold reading every waiting refund of the servicer by refund_request_waiting_idx — came from the probe holding
-- the servicer and the status beside the key; private.transfer_sibling_debited_late keeps its key alone inside the
-- probe, so no second index on the column is needed.)

-- The debits of a transfer's paying account that may be its late execution although they carry none of our references
-- (a CSV export without the end-to-end column, a camt.053 entry without references: COMPLIANCE OQ-80 (n), (p)): only
-- for a transfer that was an item of a file downloaded at least once, from the earliest execution date of such an item;
-- of its currency and amount; with neither an end-to-end id nor a PmtInfId (class N) and no counterparty IBAN or its
-- payee's, or with a reference that is not ours (classes O, E0) to its payee's IBAN — never an E0 naming another lot of
-- ours on the account (its PmtInfId says it is that lot's line); never a line of an entry kept unsplit, nor one the bank
-- flags as a return (a debtor's payment taken back); not booked, not linked but as `explained`, not a payment, not
-- decided a duplicate (private.transfer_late_lines' four exclusions). It never reads the options nor rule 3b's
-- candidates: a line that offers nothing still counts. Keyed: the transfer by its key, its items by transfer, the lines by
-- bank_transaction_debit_amount_idx, each line's class by its key.
create or replace function private.transfer_unreferenced_lines(p_transfer_id uuid)
returns table (id uuid, booking_date date)
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transfer;
  v_from date;
begin
  select * into t from public.bank_transfer q where q.id = p_transfer_id;
  if t.id is null then
    return;
  end if;
  select min(i.execution_date) into v_from
  from (select q.file_id, q.execution_date from public.transfer_file_item q where q.transfer_id = t.id offset 0) i
  cross join lateral (select f.download_count from public.transfer_file f where f.id = i.file_id offset 0) f
  where f.download_count > 0;
  if v_from is null then
    return;
  end if;
  return query
  select x.id, x.booking_date
  from (select q.id, q.booking_date, q.currency, q.kind, q.end_to_end_id, q.payment_info_id, q.counterparty_iban,
               q.unsplit_ours
        from public.bank_transaction q
        where q.bank_account_id = t.debtor_bank_account_id and q.amount_minor = t.amount_minor
          and q.direction = 'debit'
        offset 0) x
  where x.booking_date >= v_from and x.currency = t.currency and x.unsplit_ours is null
    and ((x.end_to_end_id is null and x.payment_info_id is null
          and (x.counterparty_iban is null or x.counterparty_iban = t.payee_iban))
         or (x.counterparty_iban = t.payee_iban
             and private.transfer_line_class(x.id) in ('O', 'E0')
             and not (private.pmt_inf_names_account_lot(t.debtor_bank_account_id, x.payment_info_id)
                      and not exists (select 1 from public.transfer_file_item i
                                      where i.transfer_id = t.id and i.pmt_inf_id = x.payment_info_id))))
    and coalesce((select d.released_kind from public.bank_duplicate_resolution d where d.bank_transaction_id = x.id),
                 x.kind) <> 'return'
    and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
    and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id and l.kind <> 'explained'
                    offset 0)
    and not exists (select 1 from public.payment p where p.bank_transaction_id = x.id offset 0)
    and not exists (select 1 from public.bank_duplicate_resolution r
                    where r.bank_transaction_id = x.id and r.decision = 'duplicate' offset 0);
end;
$$;

-- A cancelled transfer's late debit is open (A, B, C, M): a line of it not booked nor linked yet — its own end-to-end id
-- or a batch line of its PmtInf (private.transfer_late_lines, its chain's), or one carrying none of our references
-- (private.transfer_unreferenced_lines) — and its return not seen. Ops' booking or link of the line closes it.
create or replace function private.transfer_late_debit_open(p_transfer_id uuid)
returns boolean
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select (exists (select 1 from private.transfer_late_lines(p_transfer_id))
          or exists (select 1 from private.transfer_unreferenced_lines(p_transfer_id)))
         and not private.transfer_return_seen(p_transfer_id);
$$;

------------------------------------------------------------------------------------------
-- A, A′: a sweep made after a cancelled sweep that the bank debited late (SW2/SW3; plan §2 A)
------------------------------------------------------------------------------------------

-- A sweep in flight (ordered or in a file) was made while the servicer's share had already left once (A, A′): a sweep of
-- the same servicer and currency — on any of its dedicated accounts, whatever its status since (a sweep of an account
-- closed since can still be executed late) —, an item of a file downloaded at least once, cancelled before this one was
-- made (`cancelled_at < created_at`: both clock times, the generation reading its own under the remit lock), its return
-- not seen, whose late debit was not settled before this one was made: still open (private.transfer_late_debit_open:
-- its own SWP id, a batch line of its PmtInf, or a line carrying none of our references), or booked by ops
-- (`unplanned_sweep` of it) after this one was made (the booking entry's posted_at, a clock time — never the booking's
-- decided_at, the transaction's start). Not private.transfer_debited_before: once the cancelled sweep's line without
-- our references is booked it no longer counts there, and this sweep, made before that booking, would be released.
-- Keyed: the sweep by its key, the servicer's dedicated accounts, their cancelled filed transfers by
-- bank_transfer_cancelled_filed_idx, each one's items, files and bookings by key.
create or replace function private.sweep_after_debited_cancelled(p_sweep_id uuid)
returns boolean
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select exists (
    select 1
    from (select s.organization_id, s.currency, s.created_at from public.bank_transfer s
          where s.id = p_sweep_id and s.kind = 'sweep' and s.status in ('ordered', 'in_file') offset 0) s
    cross join lateral (select a.id from public.bank_account a
                        where a.organization_id = s.organization_id and a.purpose = 'client_funds'
                          and a.currency = s.currency offset 0) a
    cross join lateral (select c.id, c.kind, c.cancelled_at from public.bank_transfer c
                        where c.organization_id = s.organization_id and c.debtor_bank_account_id = a.id
                          and c.status = 'cancelled' and c.transfer_file_id is not null offset 0) c
    where c.kind = 'sweep' and c.id <> p_sweep_id and c.cancelled_at < s.created_at
      and exists (select 1 from public.transfer_file_item i
                  cross join lateral (select f.download_count from public.transfer_file f where f.id = i.file_id offset 0) f
                  where i.transfer_id = c.id and f.download_count > 0)
      and not private.transfer_return_seen(c.id)
      and (private.transfer_late_debit_open(c.id)
           or exists (select 1
                      from (select k.entry_id from public.bank_line_booking k
                            where k.transfer_id = c.id and k.kind = 'unplanned_sweep' offset 0) k
                      cross join lateral (select e.posted_at from public.ledger_entry e where e.id = k.entry_id offset 0) e
                      where e.posted_at >= s.created_at)));
$$;

------------------------------------------------------------------------------------------
-- M: holds beyond the replaces chain — the client's other payouts, the payment's other refunds (plan §2 M)
------------------------------------------------------------------------------------------

-- Why a payout or a refund in flight is held for a cancelled transfer outside its own chain (M):
-- `client_payout_debited_late` — a payout of the same client and currency, an item of a file downloaded at least once,
-- cancelled since, not in this one's chain, whose run is no longer approved or sent (with its run live, its late line
-- is that run's payout, and the client's cap already counts that run), with an open late debit
-- (private.transfer_late_debit_open): its collections were paid again by a later run, or are about to be;
-- `payment_refund_debited_late` — another refund request of this refund's payment has in its transfer's chain a transfer
-- that was in a downloaded file, cancelled since, with an open late debit: the debtor may already have that money.
-- Null otherwise. Keyed: the client's cancelled filed payouts by bank_transfer_client_cancelled_idx, the refund's
-- request by refund_request_transfer_id_key, its payment's requests by refund_request_payment_idx, each one's chain,
-- items, files and lines by key.
create or replace function private.transfer_sibling_debited_late(p_transfer_id uuid)
returns text
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transfer;
begin
  select * into t from public.bank_transfer where id = p_transfer_id;
  if t.kind = 'payout' and t.client_organization_id is not null then
    if exists (
         select 1
         from (select x.id, x.run_id from public.bank_transfer x
               where x.client_organization_id = t.client_organization_id and x.currency = t.currency
                 and x.kind = 'payout' and x.status = 'cancelled' and x.transfer_file_id is not null offset 0) x
         where not exists (select 1 from private.transfer_chain(t.id) c where c.transfer_id = x.id)
           and not exists (select 1 from public.remittance_run r
                           where r.id = x.run_id and r.status in ('approved', 'sent'))
           and exists (select 1 from public.transfer_file_item i
                       cross join lateral (select f.download_count from public.transfer_file f
                                           where f.id = i.file_id offset 0) f
                       where i.transfer_id = x.id and f.download_count > 0)
           and private.transfer_late_debit_open(x.id)) then
      return 'client_payout_debited_late';
    end if;
  elsif t.kind = 'refund' then
    if exists (
         select 1
         -- (the probes hold their key alone, the other conditions outside: with the servicer and the status beside
         -- it, a fresh table's statistics read every waiting refund by refund_request_waiting_idx, once per refund)
         from (select q.id, q.payment_id, q.organization_id, q.status from public.refund_request q
               where q.transfer_id = t.id offset 0) q
         cross join lateral (select o.id, o.transfer_id from public.refund_request o
                             where o.payment_id = q.payment_id offset 0) o
         cross join lateral private.transfer_chain(o.transfer_id) c
         cross join lateral (select y.status from public.bank_transfer y where y.id = c.transfer_id offset 0) y
         where q.organization_id = t.organization_id and q.status = 'requested' and o.id <> q.id
           and o.transfer_id is not null and y.status = 'cancelled'
           and exists (select 1 from public.transfer_file_item i
                       cross join lateral (select f.download_count from public.transfer_file f
                                           where f.id = i.file_id offset 0) f
                       where i.transfer_id = c.transfer_id and f.download_count > 0)
           and private.transfer_late_debit_open(c.transfer_id)) then
      return 'payment_refund_debited_late';
    end if;
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- D: H-PAY — a debit with no reference and a refund still in a downloaded file (plan §2 D)
------------------------------------------------------------------------------------------

-- A transfer of ours cancelled out of a downloaded file that this debit, carrying neither an end-to-end id nor a PmtInf,
-- may be the late execution of, and that bars it from executing this refund request: {file, kind} of the first by file
-- number, null when there is none. Rule 3b's candidates (private.transfer_line_candidates: of the line's account,
-- currency and amount, its execution date in that file on or before the line's date, to the line's counterparty IBAN
-- when it has one, its return not seen):
--   * a refund cancelled so (iv) — whatever the payment while this refund's transfer is in a downloaded or sent file
--     (the line's amount must be the refund's to execute it, so a cancelled refund of another payment at that amount may
--     be it too: Q2 (a); a re-issue's own predecessor is refused there by round 7's rule already); while it is not handed
--     out (ordered, or in a file not downloaded), only one of another payment (review round 1, DP-1): the same payment's
--     earlier refund executed late — this request's own chain among them — is this request's money (D7, M's exit),
--     another payment's would show its payer refunded and release the first payment's re-issue;
--   * (review round 1, DP-2) a payout cancelled so (iii, cancelled — never one only returned: OQ-86), or a sweep (iv):
--     linked to a refund, the line would close their late debit and lift M's and A's holds (the client's next payout,
--     the next share) although it may be their execution.
create or replace function private.refund_line_barred_by(p_line_id uuid, p_refund_request_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select jsonb_build_object('file', f.number, 'kind', c.kind)
  from (select q.transfer_id, q.payment_id from public.refund_request q where q.id = p_refund_request_id offset 0) q
  left join lateral (select y.status, y.transfer_file_id from public.bank_transfer y where y.id = q.transfer_id offset 0) m
    on true
  left join lateral (select g.download_count, g.status from public.transfer_file g where g.id = m.transfer_file_id
                     offset 0) mf on true
  cross join lateral private.transfer_line_candidates(p_line_id, private.transfer_line_class(p_line_id)) c
  cross join lateral (select y.transfer_file_id from public.bank_transfer y where y.id = c.transfer_id offset 0) y
  cross join lateral (select f.number from public.transfer_file f where f.id = y.transfer_file_id offset 0) f
  where (c.cand = 'iii' and c.status = 'cancelled')
     or (c.cand = 'iv' and c.kind = 'sweep')
     or (c.cand = 'iv' and c.kind = 'refund'
         and ((m.status = 'in_file' and coalesce(mf.download_count, 0) > 0 and mf.status in ('downloaded', 'sent'))
              or not exists (select 1
                             from (select o.transfer_id from public.refund_request o
                                   where o.payment_id = q.payment_id offset 0) o
                             cross join lateral private.transfer_chain(o.transfer_id) h
                             where h.transfer_id = c.transfer_id)))
  order by f.number
  limit 1;
$$;

------------------------------------------------------------------------------------------
-- The pages' read of the flag (plan §4)
------------------------------------------------------------------------------------------

-- Whether cancellation after download is on (private.feature_switch 'downloaded_file_cancellation'), for the pages that
-- word their texts both ways (the run page, the payment page, the credit-note page, « Contrôles », « Débits et
-- retours »): to any member of a servicer organisation, whatever its role and aal (a collector reads the payment page);
-- false to anyone else. The flag is configuration, not tenant data (public.transfer_file_detail already carries it).
create or replace function public.cancellation_after_download()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.membership m
                 join public.organization o on o.id = m.organization_id
                 where m.user_id = (select auth.uid()) and o.kind = 'servicer')
         and private.switch_on('downloaded_file_cancellation');
$$;

------------------------------------------------------------------------------------------
-- The redefinitions (each copied from its latest definition; only the lines its comment names change)
------------------------------------------------------------------------------------------

-- private.transfer_debited_before, redefined from 20261115090000_transfers_files.sql (line 1221; same signature and settings, its grants restated below).
-- M2c-6b-3a (L): a chain member deeper than the transfer, or the transfer itself once cancelled, is also « debited
-- before » while a debit carrying none of our references at its amount, from its execution date in a downloaded file, is
-- not booked nor linked (private.transfer_unreferenced_lines) and its return not seen — never the transfer's own
-- execution out of the live downloaded file it is in. Every guard reading this inherits it: the holds, the re-download,
-- the run's and the refund's cancellation, the alerts. Nothing else changes.
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
       and private.transfer_own_debit_seen(t.debtor_bank_account_id, t.end_to_end_id)
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

-- private.debited_cancelled_sweeps, redefined from 20261115090000_transfers_files.sql (line 1269; same signature and settings, its grants restated below).
-- M2c-6b-3a (B): a cancelled sweep counts while its late debit is open (private.transfer_late_debit_open: a line of it
-- not booked nor linked yet — its SWP id, a batch line of its PmtInf, or one carrying none of our references — and no
-- return seen), no longer once ops booked that line (`unplanned_sweep` of it: 4679 then shows that the share left): the
-- next sweep is proposed again; a second late line stops it again. Per account, as before (generation reads every
-- dedicated account of the servicer: A′). Review round 1 (CSC-1): the account's cancelled filed transfers by
-- bank_transfer_cancelled_filed_idx's own key (the servicer, the account), the kind outside the probe, then each one's
-- current file by its key (downloaded at least once) — the probe by file left no index condition but the status, and
-- read every cancelled filed transfer of every servicer once per downloaded file of the account.
create or replace function private.debited_cancelled_sweeps(p_bank_account_id uuid)
returns setof uuid
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select x.id
  from (select a.organization_id from public.bank_account a where a.id = p_bank_account_id offset 0) a
  cross join lateral (select t.id, t.kind, t.transfer_file_id from public.bank_transfer t
                      where t.organization_id = a.organization_id and t.debtor_bank_account_id = p_bank_account_id
                        and t.status = 'cancelled' and t.transfer_file_id is not null offset 0) x
  cross join lateral (select f.download_count from public.transfer_file f where f.id = x.transfer_file_id offset 0) f
  where x.kind = 'sweep' and f.download_count > 0
    and private.transfer_late_debit_open(x.id);
$$;

-- private.transfer_line_candidates, redefined from 20261117110000_transfer_line_pages.sql (line 2009; same signature and settings, its grants restated below).
-- M2c-6b-3a (K): rule 3b's (iv) — a refund or a sweep cancelled out of a file downloaded at least once (its current
-- file), of the line's account, currency and amount, its execution date there on or before the line's, to the line's
-- counterparty IBAN when it has one, its return not seen: the line may be its late execution. Review round 1 (LD-1,
-- LD-2; COMPLIANCE OQ-80 (q)): a payout cancelled out of a downloaded file (iii) is no candidate beside an in-flight
-- payout (i) that re-issues it (it is in that payout's replaces chain) or whose run holds, not released, an item its run
-- released (the collections run again) — as a returned payout's item re-paid by such a run already is (critic2) —; a
-- sweep cancelled so (iv) is none beside an in-flight sweep (i) made after its cancellation (generation's D4 re-made
-- it). On a feed without our references the in-flight transfer's own execution was otherwise ambiguous with its
-- predecessor for good: never booked, the run past R124-6, the next share stopped. The line is then that transfer's
-- debit; if it was in fact the predecessor's late execution, the in-flight transfer's own execution comes as a second
-- line with the predecessor alone (« Virement hors reversement » of it, an advance: OQ-82; or `unplanned_sweep` of the
-- cancelled sweep, A's booked arm holding the next share). Nothing else changes.
create or replace function private.transfer_line_candidates(p_line_id uuid, p_class text)
returns table (transfer_id uuid, cand text, kind text, status text, run_id uuid)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with l as materialized (
    select t.organization_id, t.bank_account_id, t.amount_minor, t.currency, t.booking_date, t.counterparty_iban
    from (select q.organization_id, q.bank_account_id, q.amount_minor, q.currency, q.booking_date,
                 q.counterparty_iban, q.direction
          from public.bank_transaction q where q.id = p_line_id offset 0) t
    where t.direction = 'debit' and p_class in ('N', 'O', 'E0')
      and (p_class = 'N' or t.counterparty_iban is not null)),
  x as materialized (
    select q.id, q.kind, q.status, q.run_id, q.replaces_transfer_id, q.return_entry_id, q.created_at, q.cancelled_at,
           i.execution_date, f.status as file_status, f.download_count, ru.status as run_status,
           ru.transfer_id as run_transfer
    from l
    cross join lateral (select q.id, q.organization_id, q.kind, q.status, q.currency, q.payee_iban, q.transfer_file_id,
                               q.run_id, q.replaces_transfer_id, q.return_entry_id, q.created_at, q.cancelled_at
                        from public.bank_transfer q
                        where q.debtor_bank_account_id = l.bank_account_id and q.amount_minor = l.amount_minor
                        offset 0) q
    cross join lateral (select f.status, f.download_count from public.transfer_file f
                        where f.id = q.transfer_file_id offset 0) f
    cross join lateral (select i.execution_date from public.transfer_file_item i
                        where i.file_id = q.transfer_file_id and i.transfer_id = q.id offset 0) i
    left join lateral (select r.status, r.transfer_id from public.remittance_run r where r.id = q.run_id offset 0) ru
      on true
    where q.transfer_file_id is not null and q.organization_id = l.organization_id and q.currency = l.currency
      and (l.counterparty_iban is null or q.payee_iban = l.counterparty_iban)
      and i.execution_date <= l.booking_date),
  c as materialized (
    select x.id, case
             when x.kind in ('payout', 'sweep') and x.status = 'in_file' and x.download_count > 0
                  and x.file_status in ('downloaded', 'sent')
                  and (x.kind = 'sweep' or (x.run_status in ('approved', 'sent') and x.run_transfer = x.id)) then 'i'
             when x.kind = 'refund' and x.status = 'in_file' and x.download_count > 0
                  and x.file_status in ('downloaded', 'sent') and x.replaces_transfer_id is null then 'ii'
             when x.kind = 'payout' and x.status in ('cancelled', 'returned') and x.download_count > 0 then 'iii'
             -- M2c-6b-3a (K): a refund or a sweep cancelled out of a downloaded file, its return not seen
             when x.kind in ('refund', 'sweep') and x.status = 'cancelled' and x.download_count > 0
                  and not private.transfer_return_seen(x.id) then 'iv'
           end as cand,
           x.kind, x.status, x.run_id, x.return_entry_id, x.created_at, x.cancelled_at
    from x)
  select c.id, c.cand, c.kind, c.status, c.run_id
  from c
  where c.cand is not null
    and not (c.cand = 'iii' and c.status = 'returned' and exists (
      select 1
      from (select rl.run_id from public.remittance_line rl
            where rl.ledger_entry_id = c.return_entry_id and not rl.released offset 0) rl
      cross join lateral (select r.status, r.transfer_id from public.remittance_run r where r.id = rl.run_id offset 0) r
      join c c2 on c2.id = r.transfer_id and c2.cand = 'i'
      where r.status in ('approved', 'sent')))
    -- review round 1 (LD-1): a cancelled payout beside the in-flight payout re-issuing it, or paying its run's released
    -- items again (that run's lines by the run, the live line of each item by remittance_line_live_uq)
    and not (c.cand = 'iii' and c.status = 'cancelled' and exists (
      select 1 from c c2
      where c2.cand = 'i' and c2.kind = 'payout'
        and (exists (select 1 from private.transfer_chain(c2.id) h where h.transfer_id = c.id)
             or exists (select 1
                        from (select q.ledger_entry_id, q.released from public.remittance_line q
                              where q.run_id = c.run_id offset 0) rx
                        cross join lateral (select q.run_id from public.remittance_line q
                                            where q.ledger_entry_id = rx.ledger_entry_id and not q.released offset 0) ry
                        where rx.released and ry.run_id = c2.run_id))))
    -- review round 1 (LD-2): a cancelled sweep beside the in-flight sweep made after its cancellation
    and not (c.cand = 'iv' and c.kind = 'sweep' and exists (
      select 1 from c c2 where c2.cand = 'i' and c2.kind = 'sweep' and c2.created_at > c.cancelled_at));
$$;

-- private.transfer_line_check, redefined from 20261117110000_transfer_line_pages.sql (line 452; same signature and settings, its grants restated below).
-- M2c-6b-3a (K): an unplanned payout or an unplanned sweep with no transfer of ours is refused
-- `cancelled_transfer_matches` while rule 3b's candidates hold a refund or a sweep cancelled out of a downloaded file
-- (iv) — the line may be its late execution (for an unplanned sweep, a sweep candidate keeps `sweep_in_flight_matches`).
-- A part naming such a cancelled sweep (`unplanned_sweep` of it) is that sweep's late debit, as before. Nothing else
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
begin
  -- (the working tables every branch's statements name exist, so each statement plans whatever the class)
  create temp table if not exists _tl_locked_runs (run_id uuid primary key) on commit drop;
  drop table if exists pg_temp._tl_u;
  create temp table _tl_u (k integer, id text, dir text, amount bigint, transfer_id uuid, tr_kind text,
                           tr_status text, tr_debtor uuid, part_kind text, returns_line_id uuid) on commit drop;
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
         null::uuid as adv_entry_id, null::uuid as rev_entry_id, null::uuid as rev_adv_entry_id
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
      insert into pg_temp._tl_u (k, id, dir, amount, transfer_id, tr_kind, tr_status, tr_debtor)
      select d.o::integer, d.v ->> 'id', d.v ->> 'direction', (d.v ->> 'amount_minor')::bigint,
             x.id, x.kind, x.status, x.debtor_bank_account_id
      from jsonb_array_elements(l.unsplit_details) with ordinality d (v, o)
      -- (critic2 CSO2-10) by (the line's servicer, the id), then its account: never another servicer's transfer (CI
      -- scale fix: the probe holds the id alone, the servicer compared outside it)
      left join lateral (select y.id, y.kind, y.status, y.debtor_bank_account_id
                         from (select q.id, q.kind, q.status, q.debtor_bank_account_id, q.organization_id
                               from public.bank_transfer q where q.end_to_end_id = d.v ->> 'id' offset 0) y
                         where y.organization_id = l.organization_id) x
        on true;
      if exists (select 1 from pg_temp._tl_u u
                 where u.id !~ '^(RMT|SWP)' or u.transfer_id is null or u.tr_debtor <> l.bank_account_id
                    or u.tr_kind not in ('payout', 'sweep'))
         or (select count(distinct u.id) <> count(*) from pg_temp._tl_u u) then
        v_why := 'unsplit_not_bookable'; exit rules;
      end if;
      -- the kind each detail gives: a debit, the planned debit of a live transfer or the unplanned one of a cancelled,
      -- booked or returned one; a credit, the planned return, or the unplanned booking's return while one is open
      update pg_temp._tl_u u set part_kind = case
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
    insert into pg_temp._tl_pool (n, ledger_entry_id)
    select distinct t.n, y.ledger_entry_id
    from pg_temp._tl t
    cross join lateral (select q.ledger_entry_id, q.released from public.remittance_line q
                        where q.run_id = t.tr_run offset 0) y
    where t.kind = 'unplanned_payout' and t.tr_status = 'cancelled' and t.tr_run is not null and y.released
    union
    select t.n, t.tr_return_entry from pg_temp._tl t
    where t.kind = 'unplanned_payout' and t.tr_status = 'returned' and t.tr_return_entry is not null;

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
        if r.amount <> r.tr_minor then v_why := 'amount_differs'; exit rules; end if;
        -- (review 6b-2c money-3, legal-deadlines-2) late, and the date its breach is recorded against, as
        -- private.bank_booking_post_rows records the row: the run's lines late at the line's date by their own date, a
        -- line whose delay cannot be met by its one-month date (private.remittance_run_late_on: the run's lines by its
        -- key, as the CI scale fix reads them)
        update pg_temp._tl t set c = r.tr_client, a = r.amount,
          late_date = case when r.kind = 'payout' then private.remittance_run_late_on(r.tr_run, l.booking_date) end
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
                 when 'B' then exists (select 1 from pg_temp._tl_pre p where p.role = 'returnable'
                                         and p.transfer_id = r.transfer_id)
                 when 'U' then true
                 else false end) then
          v_why := 'not_its_line'; exit rules;
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
        if r.tr_status = 'cancelled' then v_why := 'transfer_cancelled'; exit rules; end if;
        if r.tr_status <> 'booked' or r.tr_entry is null
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
          and k.transfer_id is not distinct from r.transfer_id
          and (r.client_id is null or e.client_organization_id = r.client_id)
        order by k.seq limit 1;
        if v_bk.entry_id is null then v_why := 'transfer_unknown'; exit rules; end if;
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

-- private.transfer_line_options_of, redefined from 20261117110000_transfer_line_pages.sql (line 117; same signature and settings, its grants restated below).
-- M2c-6b-3a (K): rule 3b's only candidate a sweep cancelled out of a downloaded file (iv) is proposed as that sweep's
-- late debit (`unplanned_sweep` of it); a refund cancelled so is proposed nothing, the refusal
-- `cancelled_transfer_matches` (no booking kind for a cancelled refund's late debit yet: COMPLIANCE OQ-81 (b), S25).
-- Nothing else changes.
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
    v_action := case when v_x.status in ('cancelled', 'booked', 'returned') then 'unplanned_' || v_x.kind
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
             'kind', case when d.v ->> 'direction' = 'debit' and x.status in ('cancelled', 'booked', 'returned')
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
        v_action := case when v_cand.cand = 'iii' then 'unplanned_payout' when v_cand.cand = 'iv' then 'unplanned_sweep'
                         else 'payout' end;
        v_parts := jsonb_build_array(jsonb_build_object(
                     'kind', case when v_cand.cand = 'iii' then 'unplanned_payout'
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

-- private.transfer_cancel_evidence, redefined from 20261115090000_transfers_files.sql (line 1435; same signature and settings, its grants restated below).
-- M2c-6b-3a (N): the evidence also refuses `unreferenced_debit_open` (after `debit_seen`, before `batch_ambiguous`)
-- while a debit carrying none of our references may be the file's execution: for the file, a line of an in-file
-- transfer's amount from its execution date (private.transfer_unreferenced_lines), or a line with no reference at the
-- sum of one of its PmtInfs' in-file transfers (a bank ignoring BtchBookg false, COMPLIANCE OQ-83) from the file's first
-- execution date; for one transfer, a line of its amount (the same reader). Both not booked nor linked: ops book or
-- classify the line first. The card carries {unreferenced_debit, unreferenced_from}. The confirmations recompute it, as
-- every evidence. Nothing else changes.
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
                                     and private.transfer_own_debit_seen(f.debtor_bank_account_id, bt.end_to_end_id)
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
    if private.transfer_own_debit_seen(t.debtor_bank_account_id, t.end_to_end_id) then
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

-- private.run_transfer_checks, redefined from 20261117110000_transfer_line_pages.sql (line 1637; same signature and settings, its grants restated below).
-- M2c-6b-3a: (A) a sweep in flight made after a cancelled sweep the bank debited late is alerted
-- (`transfer_already_debited`, kind sweep, its status: private.sweep_after_debited_cancelled); (C, G1c) the G1 branch
-- reads the servicer's cancelled payouts and refunds that were in a downloaded file — a materialized set shared with
-- the P0 `cancelled_transfer_debited` branch — debited after all (private.transfer_debited_before, with L's lines) and
-- their late line not booked nor linked (private.transfer_late_debit_open), whatever their run's or refund's state, but
-- while the live end of their chain (their run's transfer, approved or sent, or their requested refund's, ordered or in
-- a file) is alerted instead by the ordered or in-file branch; (M) a payout or a refund in flight held for a cancelled
-- one of its client or payment debited late (private.transfer_sibling_debited_late: `reason`). Nothing else changes.
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
      -- M2c-6b-2a: the transfer's own payout (an unplanned payout's return is the branch below)
      and bt.entry_id = e.reverses_entry_id
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

-- public.transfer_overview, redefined from 20261115090000_transfers_files.sql (line 3308; same signature and settings, its grants restated below).
-- M2c-6b-3a (A′): « Virements » says no sweep is proposed while a cancelled sweep of any dedicated account of the
-- servicer in the currency (whatever its status) shows an open late debit — generation's D4 rule; review round 1
-- (CSC-1): read once per currency (`held`), not once per account row. Nothing else changes.
create or replace function public.transfer_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_org uuid := (private.money_staff_org_ids())[1];
  v_today date := private.paris_today();
  v_accounts jsonb;
  v_checks jsonb;
  v_own jsonb;
  v_sweep bigint := 0;
  v_owed_servicer bigint;
  v_sweeps bigint;
begin
  if v_org is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select jsonb_build_object('id', a.id, 'label', a.label, 'iban_last4', right(a.iban, 4)) into v_own
  from public.servicer_billing_settings s join public.bank_account a on a.id = s.own_bank_account_id
  where s.organization_id = v_org and a.status = 'active';
  if v_own is not null then
    select coalesce(sum(lp.amount_minor), 0) into v_owed_servicer
    from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
    where la.organization_id = v_org and la.book = 'due_to_servicer' and la.currency = 'EUR';
    select coalesce(sum(x.amount_minor), 0) into v_sweeps from public.bank_transfer x
    where x.organization_id = v_org and x.kind = 'sweep' and x.currency = 'EUR' and x.status in ('ordered', 'in_file');
    v_sweep := greatest(0, -v_owed_servicer - v_sweeps);
  end if;
  with held as materialized (   -- the currencies whose servicer-wide share a cancelled sweep debited late holds
    select distinct a.currency from public.bank_account a
    cross join lateral private.debited_cancelled_sweeps(a.id) s
    where a.organization_id = v_org and a.purpose = 'client_funds'),
  acc as (
    select b.*, private.transfer_earliest_execution_date(b.id) as earliest,
           -- review round 2 (D4): no sweep while a cancelled one of the account left it all the same
           case when exists (select 1 from held h where h.currency = b.currency) then 'cancelled_sweep_debited' end
             as sweep_hold
    from public.bank_account b
    where b.organization_id = v_org and b.purpose = 'client_funds' and b.status = 'active'),
  todo as materialized (
    select t.id, t.debtor_bank_account_id, t.amount_minor, t.created_at,
           private.transfer_hold_reason(t.id, v_today, greatest(t.requested_execution_date, a.earliest), null) as hold,
           greatest(t.requested_execution_date, a.earliest) as execution_date
    from acc a join public.bank_transfer t on t.debtor_bank_account_id = a.id
    where t.status = 'ordered' and t.kind in ('payout', 'refund'))
  select coalesce(jsonb_agg(jsonb_build_object(
           'bank_account_id', a.id, 'label', a.label, 'iban_last4', right(a.iban, 4), 'bic', a.bic,
           'currency', a.currency, 'pain_version', a.pain_version, 'earliest_execution_date', a.earliest,
           'cash', private.transfer_cash_position(a.id),
           'sweep_preview_minor', case when a.currency = 'EUR' and a.sweep_hold is null then v_sweep else 0 end::text,
           'sweep_hold', case when v_sweep > 0 then a.sweep_hold end,
           'to_file_count', (select count(*) from todo x where x.debtor_bank_account_id = a.id),
           'eligible_count', (select count(*) from todo x where x.debtor_bank_account_id = a.id
                                and (x.hold is null or x.hold = 'late_reason_required')),
           'eligible_total_minor', (select coalesce(sum(x.amount_minor), 0) from todo x
                                    where x.debtor_bank_account_id = a.id
                                      and (x.hold is null or x.hold = 'late_reason_required'))::text,
           'late_count', (select count(*) from todo x where x.debtor_bank_account_id = a.id
                            and x.hold = 'late_reason_required'),
           'to_file', (select coalesce(jsonb_agg(private.transfer_card(x.id, x.hold)
                                                 || jsonb_build_object('execution_date', x.execution_date)
                                                 order by x.created_at, x.id), '[]')
                       from (select * from todo y where y.debtor_bank_account_id = a.id
                             order by y.created_at, y.id limit 200) x),
           'files', (select coalesce(jsonb_agg(private.transfer_file_card(f) order by f.created_at desc), '[]')
                     from (select * from public.transfer_file y where y.debtor_bank_account_id = a.id
                           order by y.created_at desc limit 20) f))
           order by a.label, a.id), '[]')
  into v_accounts from acc a;
  select coalesce(jsonb_agg(jsonb_build_object(
           'check_id', c.id, 'client_id', c.client_organization_id, 'client_name', o.legal_name,
           'payout_account_id', c.payout_account_id, 'iban_last4', right(pa.iban, 4), 'holder_name', pa.holder_name,
           'result', c.result, 'bank_name', c.bank_name, 'note', c.note, 'recorded_at', c.recorded_at,
           'recorded_by', (select coalesce(u.display_name, u.email) from public.app_user u where u.id = c.recorded_by),
           'recorded_by_me', c.recorded_by = auth.uid(), 'transfer_id', c.transfer_id,
           -- review T5, round 2 (S1): none of who recorded it, or proposed or confirmed that IBAN for the client
           'can_clear', not (auth.uid() = any (private.payee_check_parties(c.id))))
           order by c.recorded_at), '[]')
  into v_checks
  from public.payee_name_check c
  join public.organization o on o.id = c.client_organization_id
  join public.client_payout_account pa on pa.id = c.payout_account_id
  -- review T5 (tests-ui#7), round 2 (S1): a check closes once no current account of the client carries its IBAN (a
  -- replacement with another IBAN confirmed), not when the same IBAN is confirmed again
  where c.organization_id = v_org and c.cleared_at is null and private.payee_check_open(c.payout_account_id);
  return jsonb_build_object('today', v_today, 'accounts', v_accounts, 'own_account', v_own, 'payee_checks', v_checks,
                            'can_admin', private.has_role(v_org, array['admin']),
                            -- review round 5 (fail-closed): whether a downloaded file can be cancelled (off until M2c-6b)
                            'cancellation_after_download', private.switch_on('downloaded_file_cancellation'));
end;
$$;

-- public.generate_transfer_file, redefined from 20261116090000_debit_bookings.sql (line 276; same signature and settings, its grants restated below).
-- M2c-6b-3a (A, A′): the new sweep's created_at is the clock time read right after the remit lock (v_now), never the
-- transaction's start: a generation that waited for the lock behind a cancellation is then later than that
-- cancellation's clock time, and private.sweep_after_debited_cancelled compares the two exactly; and D4 reads every
-- dedicated account of the servicer in the currency, whatever its status (the share is servicer-wide: a cancelled sweep
-- of one account debited late stops the next sweep from any). Nothing else changes.
create or replace function public.generate_transfer_file(p_idempotency_key text, p_bank_account_id uuid,
                                                         p_late_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  b public.bank_account;
  v_late text := nullif(btrim(coalesce(p_late_reason, '')), '');
  v_request jsonb := jsonb_build_object('bank_account_id', p_bank_account_id,
                                        'late_reason', nullif(btrim(coalesce(p_late_reason, '')), ''));
  v_result jsonb;
  v_now timestamptz;
  v_today date;
  v_earliest date;
  v_file uuid := gen_random_uuid();
  v_token uuid := gen_random_uuid();
  v_number text;
  v_name text;
  v_superseded uuid[];
  v_sum bigint;
  v_n integer;
  v_cash jsonb;
  v_available bigint;
  v_own public.bank_account;
  v_owed_servicer bigint;
  v_sweeps bigint;
  v_sweep bigint := 0;
  v_sweep_left bigint := 0;
  v_sweep_id uuid;
  v_sweep_hold text;
  v_e2e text;
  v_offset integer;
  v_held jsonb;
begin
  select * into b from public.bank_account where id = p_bank_account_id;
  if not found or not private.has_role(b.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('generate_transfer_file', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if length(v_late) > 2000 then
    raise exception 'transfer file refused: late_reason_too_long' using errcode = 'check_violation';
  end if;
  -- top-up files from the own account are M2c-7's (design §21); a paying account is an active dedicated one in EUR
  if b.purpose <> 'client_funds' or b.status <> 'active' then
    raise exception 'transfer file refused: not_a_paying_account' using errcode = 'check_violation';
  end if;
  if b.currency <> 'EUR' then
    raise exception 'transfer file refused: not_eur' using errcode = 'check_violation';
  end if;
  -- lock order: the account row, the allocation lock, the remit lock, then files and transfers
  perform 1 from public.bank_account x where x.id = b.id for share;
  perform private.remittance_command_locks(b.organization_id, true);
  v_now := clock_timestamp();
  v_today := (v_now at time zone 'Europe/Paris')::date;
  v_earliest := private.transfer_earliest_execution_date(b.id, v_now);

  -- one live file per account: a file not downloaded yet is replaced by this one (its transfers come in it again)
  select coalesce(array_agg(f.id order by f.id), '{}') into v_superseded from public.transfer_file f
  where f.debtor_bank_account_id = b.id and f.status in ('pending', 'generated');
  perform private.transfer_file_release(x, 'superseded', 'Remplacé par un nouveau fichier', null, v_file)
  from unnest(v_superseded) x;

  -- the candidates: the account's ordered payouts and refunds, locked; each one's date and why it is held, if it is
  perform 1 from public.bank_transfer t
  where t.debtor_bank_account_id = b.id and t.status = 'ordered' and t.kind in ('payout', 'refund')
  order by t.id for update;
  drop table if exists pg_temp._tf;
  create temp table _tf on commit drop as
  select t.id, t.kind, t.amount_minor, t.run_id, t.created_at, t.end_to_end_id,
         greatest(t.requested_execution_date, v_earliest) as execution_date,
         private.transfer_hold_reason(t.id, v_today, greatest(t.requested_execution_date, v_earliest), v_late) as hold
  from public.bank_transfer t
  where t.debtor_bank_account_id = b.id and t.status = 'ordered' and t.kind in ('payout', 'refund');
  select coalesce(sum(x.amount_minor), 0), count(*) into v_sum, v_n from pg_temp._tf x where x.hold is null;
  select coalesce(jsonb_agg(jsonb_build_object('transfer_id', x.id, 'kind', x.kind, 'end_to_end_id', x.end_to_end_id,
                                               'amount_minor', x.amount_minor::text, 'reason', x.hold)
                            order by x.created_at, x.id), '[]')
  into v_held from pg_temp._tf x where x.hold is not null;

  -- the sweep (§11, §13 #8; founder #9): the servicer's share settled on the account, less the sweeps already ordered
  -- or in a file, to its own account; read under the remit lock (every writer of 4679 holds it)
  select a.* into v_own from public.servicer_billing_settings s
  join public.bank_account a on a.id = s.own_bank_account_id
  where s.organization_id = b.organization_id and a.purpose = 'own' and a.status = 'active' and a.currency = b.currency;
  if v_own.id is not null then
    select coalesce(sum(lp.amount_minor), 0) into v_owed_servicer
    from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
    where la.organization_id = b.organization_id and la.book = 'due_to_servicer' and la.currency = b.currency;
    select coalesce(sum(x.amount_minor), 0) into v_sweeps from public.bank_transfer x
    where x.organization_id = b.organization_id and x.kind = 'sweep' and x.currency = b.currency
      and x.status in ('ordered', 'in_file');
    v_sweep := greatest(0, -v_owed_servicer - v_sweeps);
    -- review round 2 (D4): a cancelled sweep left the account all the same (its debit seen, no return): none again
    -- M2c-6b-3a (A′): of any dedicated account of the servicer in the currency, whatever its status since
    if v_sweep > 0 and exists (select 1 from public.bank_account a
                               cross join lateral private.debited_cancelled_sweeps(a.id) s
                               where a.organization_id = b.organization_id and a.purpose = 'client_funds'
                                 and a.currency = b.currency) then
      v_sweep := 0;
      v_sweep_hold := 'cancelled_sweep_debited';
    end if;
  end if;

  -- the cash check (ops critique #5): what the account can still pay covers the file; the servicer's sweep goes first
  -- when it does not (clients are paid first, founder #9)
  v_cash := private.transfer_cash_position(b.id);
  if v_cash is null then
    raise exception 'transfer file refused: no_closing_balance' using errcode = 'check_violation',
      hint = 'Importez un relevé du compte avec son solde de clôture.';
  end if;
  v_available := (v_cash ->> 'available_minor')::bigint;
  if v_available < v_sum + v_sweep then
    v_sweep_left := v_sweep;
    v_sweep := 0;
  end if;
  if v_available < v_sum then
    raise exception 'transfer file refused: cash_not_covered' using errcode = 'check_violation',
      detail = jsonb_build_object('available_minor', v_available::text, 'needed_minor', v_sum::text,
                                  'cash', v_cash)::text;
  end if;
  if v_n = 0 and v_sweep = 0 then
    raise exception 'transfer file refused: nothing_to_file' using errcode = 'check_violation',
      detail = jsonb_build_object('held', v_held, 'sweep_hold', v_sweep_hold)::text;
  end if;

  select legal_name into v_name from public.organization where id = b.organization_id;
  v_number := private.transfer_file_number(v_today, nextval('private.transfer_file_number_seq'));
  if v_sweep > 0 then
    v_e2e := 'SWP' || upper(substr(md5(gen_random_uuid()::text), 1, 12));
    insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id, creditor_bank_account_id, currency,
                                      amount_minor, payee_name, payee_iban, payee_bic, end_to_end_id, remittance_info,
                                      requested_execution_date, ordered_by, created_at)
    values (b.organization_id, 'sweep', b.id, v_own.id, b.currency, v_sweep, left(btrim(v_name), 70), v_own.iban,
            v_own.bic, v_e2e, 'VIREMENT AU COMPTE PROPRE ' || v_number, v_earliest, auth.uid(), v_now)
    returning id into v_sweep_id;
    insert into pg_temp._tf (id, kind, amount_minor, run_id, created_at, end_to_end_id, execution_date, hold)
    values (v_sweep_id, 'sweep', v_sweep, null, clock_timestamp(), v_e2e, v_earliest, null);
  end if;

  -- CreDtTm frozen now, Paris time with its offset
  v_offset := (extract(epoch from (v_now at time zone 'Europe/Paris') - (v_now at time zone 'UTC')) / 60)::integer;
  insert into public.transfer_file (id, organization_id, debtor_bank_account_id, currency, number, msg_id, pain_version,
                                    created_at_iso, initiating_party, debtor_name, debtor_iban, debtor_bic, nb_of_txs,
                                    ctrl_sum_minor, first_execution_date, last_execution_date, late_reason, cash_check,
                                    held, job_token, created_by)
  select v_file, b.organization_id, b.id, b.currency, v_number, v_number, b.pain_version,
         to_char(v_now at time zone 'Europe/Paris', 'YYYY-MM-DD"T"HH24:MI:SS')
           || case when v_offset < 0 then '-' else '+' end
           || lpad((abs(v_offset) / 60)::text, 2, '0') || ':' || lpad((abs(v_offset) % 60)::text, 2, '0'),
         v_name, v_name, b.iban, b.bic, count(*), sum(x.amount_minor), min(x.execution_date), max(x.execution_date),
         case when bool_or(x.kind = 'payout' and x.execution_date > r.earliest_latest_execution_date) then v_late end,
         v_cash || jsonb_build_object('ctrl_sum_minor', sum(x.amount_minor)::text,
                                      'sweep_left_minor', v_sweep_left::text, 'sweep_hold', v_sweep_hold),
         v_held, v_token, auth.uid()
  from pg_temp._tf x left join public.remittance_run r on r.id = x.run_id
  where x.hold is null;
  -- one PmtInf per kind and execution date — the payouts, then the refunds, then the sweep (M2c-6b-1, plan §2.1: a
  -- batch line is then one kind) — transactions in order
  insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id, pmt_inf_id, execution_date, late)
  select v_file, row_number() over (order by g.grp, x.execution_date, x.created_at, x.id), x.id, b.organization_id,
         v_number || '-' || dense_rank() over (order by g.grp, x.execution_date), x.execution_date,
         coalesce(x.kind = 'payout' and x.execution_date > r.earliest_latest_execution_date, false)
  from pg_temp._tf x
  cross join lateral (select case x.kind when 'payout' then 1 when 'refund' then 2 else 3 end as grp) g
  left join public.remittance_run r on r.id = x.run_id
  where x.hold is null;
  update public.bank_transfer t set status = 'in_file', transfer_file_id = v_file
  from pg_temp._tf x where x.id = t.id and x.hold is null;
  perform pgmq.send('remittances', jsonb_build_object('type', 'transfer_file', 'file_id', v_file, 'token', v_token));

  v_result := jsonb_build_object('file_id', v_file, 'number', v_number, 'status', 'pending',
                                 'nb_of_txs', v_n + (v_sweep > 0)::integer, 'ctrl_sum_minor', (v_sum + v_sweep)::text,
                                 'sweep_minor', v_sweep::text, 'sweep_left_minor', v_sweep_left::text,
                                 'sweep_hold', v_sweep_hold,
                                 'first_execution_date', (select min(execution_date) from pg_temp._tf where hold is null),
                                 'held', v_held, 'superseded', to_jsonb(v_superseded));
  perform private.command_record('generate_transfer_file', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- public.transfer_file_download, redefined from 20261117090000_transfer_line_foundations.sql (line 1596; same signature and settings, its grants restated below).
-- M2c-6b-3a: (A) at a generated file's first download the holds run over its sweep too (`cancelled_sweep_debited`:
-- private.transfer_hold_reason), and a re-download refuses `holds_debited_transfer` for an in-file sweep made after a
-- cancelled sweep the bank debited late; (M) and for an in-file payout or refund held for a cancelled one of its client
-- or payment debited late (private.transfer_sibling_debited_late) — the detail names each such transfer with its reason;
-- the hint is true of each. Nothing else changes.
create or replace function public.transfer_file_download(p_file_id uuid, p_sha256 text,
                                                         p_acknowledged boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  f public.transfer_file;
  v_n integer;
  v_first text;
  v_now timestamptz;
  v_earliest date;
  v_blocked jsonb;
  v_cash jsonb;
  v_refused text;
  v_sweep_id uuid;
  v_sweep_minor bigint;
  v_share bigint;
begin
  select * into f from public.transfer_file where id = p_file_id;
  if not found or not private.has_role(f.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  -- the generation's locks (the account row, the allocation then remit locks), the file's runs first (ADR-0014 order)
  perform private.transfer_file_lock_runs(f.id);
  perform 1 from public.bank_account x where x.id = f.debtor_bank_account_id for share;
  perform private.remittance_command_locks(f.organization_id, true);
  select * into f from public.transfer_file where id = p_file_id for update;
  if f.status = 'pending' then
    raise exception 'transfer file refused: not_ready' using errcode = 'check_violation';
  end if;
  if f.status not in ('generated', 'downloaded', 'sent') then
    raise exception 'transfer file refused: not_downloadable' using errcode = 'check_violation';
  end if;
  if p_sha256 is distinct from f.file_sha256 then
    raise exception 'transfer file refused: hash_mismatch' using errcode = 'check_violation';
  end if;
  if f.status = 'generated' then
    v_now := clock_timestamp();
    v_earliest := private.transfer_earliest_execution_date(f.debtor_bank_account_id, v_now);
    select coalesce(jsonb_agg(jsonb_build_object('transfer_id', x.id, 'kind', x.kind, 'end_to_end_id', x.end_to_end_id,
                                                 'amount_minor', x.amount_minor::text, 'reason', x.hold)
                              order by x.seq), '[]')
    into v_blocked
    from (select i.seq, t.id, t.kind, t.end_to_end_id, t.amount_minor,
                 private.transfer_hold_reason(t.id, (v_now at time zone 'Europe/Paris')::date, i.execution_date,
                                              f.late_reason) as hold
          from public.transfer_file_item i
          cross join lateral (select t.id, t.kind, t.end_to_end_id, t.amount_minor from public.bank_transfer t
                              where t.id = i.transfer_id offset 0) t
          where i.file_id = f.id and t.kind in ('payout', 'refund', 'sweep')) x
    where x.hold is not null;
    v_cash := private.transfer_cash_position(f.debtor_bank_account_id);
    if v_cash is null or (v_cash ->> 'available_minor')::bigint < f.ctrl_sum_minor then
      v_blocked := v_blocked || jsonb_build_array(jsonb_build_object(
        'transfer_id', null, 'reason', case when v_cash is null then 'no_closing_balance' else 'cash_not_covered' end,
        'available_minor', v_cash ->> 'available_minor', 'needed_minor', f.ctrl_sum_minor::text));
    end if;
    -- M2c-6b-2a (plan §2.4; critic CSO-2, F10, CSO-10): the file's sweep against the servicer's share now — read under
    -- the remit lock held above (every writer of 4679 holds it), by generate_transfer_file's own formula: −Σ 4679 of the
    -- servicer and currency, less the other sweeps ordered or in a file. A cover, a fee or an advance booked since the
    -- generation may have lowered it: such a file is not served (its sweep is cancelled and recomputed by the next file,
    -- its payouts ordered again)
    select t.id, t.amount_minor into v_sweep_id, v_sweep_minor
    from public.transfer_file_item i
    cross join lateral (select t.id, t.kind, t.status, t.amount_minor, t.transfer_file_id from public.bank_transfer t
                        where t.id = i.transfer_id offset 0) t
    where i.file_id = f.id and t.kind = 'sweep' and t.status = 'in_file' and t.transfer_file_id = f.id;
    if v_sweep_id is not null then
      select -coalesce(sum(lp.amount_minor), 0) into v_share
      from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
      where la.organization_id = f.organization_id and la.book = 'due_to_servicer' and la.currency = f.currency;
      v_share := v_share - (select coalesce(sum(x.amount_minor), 0) from public.bank_transfer x
                            where x.organization_id = f.organization_id and x.kind = 'sweep' and x.currency = f.currency
                              and x.status in ('ordered', 'in_file') and x.id <> v_sweep_id);
      if v_sweep_minor > v_share then
        v_blocked := v_blocked || jsonb_build_array(jsonb_build_object(
          'transfer_id', v_sweep_id, 'kind', 'sweep', 'reason', 'sweep_exceeds_share',
          'sweep_minor', v_sweep_minor::text, 'share_minor', v_share::text));
      end if;
    end if;
    v_refused := case when f.first_execution_date < v_earliest then 'file_stale'
                      when jsonb_array_length(v_blocked) > 0 then 'file_blocked' end;
    if v_refused is not null then
      perform private.transfer_file_release(f.id, 'superseded',
        case v_refused when 'file_stale' then 'Date d''exécution dépassée avant le téléchargement : fichier à régénérer'
                       else 'Contrôles changés depuis la génération : fichier à régénérer' end, null, null);
      return jsonb_build_object('file_id', f.id, 'number', f.number, 'refused', v_refused, 'status', 'superseded',
                                'first_execution_date', f.first_execution_date,
                                'earliest_execution_date', v_earliest, 'blocked', v_blocked, 'cash', v_cash);
    end if;
  elsif exists (select 1 from public.transfer_file_item i
                cross join lateral (select t.status from public.bank_transfer t where t.id = i.transfer_id offset 0) t
                where i.file_id = f.id and t.status = 'cancelled') then
    raise exception 'transfer file refused: holds_cancelled_transfer' using errcode = 'check_violation',
      hint = 'Un virement de ce fichier a été annulé depuis son téléchargement : ne le déposez plus.';
  elsif exists (select 1 from public.transfer_file_item i
                cross join lateral (select t.id, t.kind, t.status, t.transfer_file_id from public.bank_transfer t
                                    where t.id = i.transfer_id offset 0) t
                where i.file_id = f.id and t.status = 'in_file' and t.transfer_file_id = f.id
                  and ((t.kind in ('payout', 'refund')
                        and (private.transfer_debited_before(t.id)
                             or private.transfer_sibling_debited_late(t.id) is not null))
                       or (t.kind = 'sweep' and private.sweep_after_debited_cancelled(t.id)))) then
    raise exception 'transfer file refused: holds_debited_transfer' using errcode = 'check_violation',
      detail = (select jsonb_agg(jsonb_build_object('transfer_id', x.id, 'kind', x.kind, 'reason', x.reason)
                                 order by x.seq)
                from (select i.seq, t.id, t.kind,
                             case when t.kind = 'sweep' then
                                    case when private.sweep_after_debited_cancelled(t.id)
                                         then 'cancelled_sweep_debited' end
                                  when private.transfer_debited_before(t.id) then 'already_debited'
                                  else private.transfer_sibling_debited_late(t.id) end as reason
                      from public.transfer_file_item i
                      cross join lateral (select t.id, t.kind, t.status, t.transfer_file_id from public.bank_transfer t
                                          where t.id = i.transfer_id offset 0) t
                      where i.file_id = f.id and t.status = 'in_file' and t.transfer_file_id = f.id
                        and t.kind in ('payout', 'refund', 'sweep')) x
                where x.reason is not null)::text,
      hint = 'Un virement de ce fichier a peut-être déjà quitté le compte (débité sous la référence du virement qu''il remplace, dans une ligne groupée de son lot ou sans référence), ou un virement annulé du même client ou du même paiement a été débité en retard, ou la quote-part du cabinet de ce fichier a déjà été virée par une quote-part annulée exécutée en retard : ne déposez pas ce fichier ; s''il l''a été, demandez à la banque de ne pas l''exécuter.';
  -- review round 6 (round 5's verifier, p_redl): the bank executed the file, in full or in part — a debit of one of its
  -- PmtInfIds or its transfers' end-to-end ids, or a return (private.transfer_file_executed), or one of its payouts,
  -- refunds or sweeps shows its own debit (private.transfer_debit_seen: its id, or a batch line of its PmtInf) —:
  -- uploaded again, it would pay it all a second time. Whatever the switch; acknowledged or not. Review round 7 (N5):
  -- also when one of them is booked or returned already — a refund booked by a line with no reference (a CSV feed)
  -- leaves no debit of the file to read, yet it left the account.
  elsif private.transfer_file_executed(f.id)
        or exists (select 1 from public.transfer_file_item i
                   cross join lateral (select t.id, t.kind, t.status, t.transfer_file_id from public.bank_transfer t
                                       where t.id = i.transfer_id offset 0) t
                   where i.file_id = f.id and t.kind in ('payout', 'refund', 'sweep') and t.transfer_file_id = f.id
                     and (t.status in ('booked', 'returned') or private.transfer_debit_seen(t.id))) then
    raise exception 'transfer file refused: file_executed' using errcode = 'check_violation',
      hint = 'La banque a déjà exécuté ce fichier, en tout ou partie : ne le déposez plus.';
  end if;
  if f.download_count > 0 and not coalesce(p_acknowledged, false) then
    select coalesce(u.display_name, u.email, 'un utilisateur') into v_first from public.app_user u
    where u.id = f.first_downloaded_by;
    raise exception 'transfer file refused: already_downloaded' using errcode = 'check_violation',
      detail = jsonb_build_object('by', v_first, 'at', f.first_downloaded_at)::text;
  end if;
  v_n := f.download_count + 1;
  insert into public.transfer_file_download (file_id, organization_id, n, downloaded_by, warning_acknowledged, sha256)
  values (f.id, f.organization_id, v_n, auth.uid(), f.download_count > 0, p_sha256);
  update public.transfer_file set download_count = v_n,
    first_downloaded_by = coalesce(first_downloaded_by, auth.uid()),
    first_downloaded_at = coalesce(first_downloaded_at, clock_timestamp()),
    status = case when status = 'generated' then 'downloaded' else status end, version = version + 1
  where id = f.id;
  update public.remittance_run r set status = 'sent', version = version + 1
  from public.bank_transfer t
  where t.transfer_file_id = f.id and t.status = 'in_file' and t.run_id = r.id and r.status = 'approved';
  return jsonb_build_object('file_id', f.id, 'number', f.number, 'download', v_n, 'status',
                            case when f.status = 'generated' then 'downloaded' else f.status end,
                            'storage_path', f.storage_path, 'file_name', f.number || '.xml');
end;
$$;

-- private.transfer_hold_reason, redefined from 20261115090000_transfers_files.sql (line 1587; same signature and settings, its grants restated below).
-- M2c-6b-3a: (A) a sweep is held `cancelled_sweep_debited` when it was made after a cancelled sweep the bank debited
-- late (private.sweep_after_debited_cancelled; generation never asks for its own new sweep, the download's re-check
-- does); (M) a payout or a refund, after `already_debited`, `client_payout_debited_late` or
-- `payment_refund_debited_late` (private.transfer_sibling_debited_late). Nothing else changes.
create or replace function private.transfer_hold_reason(p_transfer_id uuid, p_today date, p_execution_date date,
                                                        p_late_reason text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  t public.bank_transfer;
  r public.remittance_run;
  v_blockers text[];
  v_owed bigint;
  v_inflight bigint;
  v_sibling text;
begin
  select * into t from public.bank_transfer where id = p_transfer_id;
  if t.currency <> 'EUR' then
    return 'not_eur';
  end if;
  -- M2c-6b-3a (A): the servicer's share left once already, by a cancelled sweep executed late
  if t.kind = 'sweep' then
    return case when private.sweep_after_debited_cancelled(t.id) then 'cancelled_sweep_debited' end;
  end if;
  if t.kind in ('payout', 'refund') and private.transfer_debited_before(t.id) then
    return 'already_debited';
  end if;
  -- M2c-6b-3a (M): a cancelled payout of its client, or refund of its payment, debited late
  v_sibling := private.transfer_sibling_debited_late(t.id);
  if v_sibling is not null then
    return v_sibling;
  end if;
  if t.kind = 'refund' then
    if not exists (select 1 from public.refund_request q where q.transfer_id = t.id and q.status = 'requested') then
      return 'refund_not_pending';
    end if;
    if private.epc_name_empty(t.payee_name) then
      return 'payee_name_not_epc';
    end if;
    if not private.iban_in_sepa(t.payee_iban) then
      return 'iban_not_sepa';
    end if;
    return null;
  end if;
  if t.kind <> 'payout' then
    return null;
  end if;
  select * into r from public.remittance_run where id = t.run_id;
  if r.id is null or r.status not in ('approved', 'sent') then
    return 'run_not_in_flight';
  end if;
  v_blockers := private.remittance_payout_blockers(r.client_organization_id, r.currency, p_today);
  if cardinality(v_blockers) > 0 then
    return 'payout_blocked:' || v_blockers[1];
  end if;
  if r.payout_account_id is distinct from (
       select pa.id from public.client_payout_account pa
       where pa.client_organization_id = r.client_organization_id and pa.currency = r.currency
         and pa.status = 'active') then
    return 'payout_account_changed';
  end if;
  select -b.balance_minor into v_owed from private.client_payable_balance b
  where b.client_organization_id = r.client_organization_id and b.currency = r.currency;
  select coalesce(sum(x.net_minor + x.settlement_minor), 0) into v_inflight from public.remittance_run x
  where x.client_organization_id = r.client_organization_id and x.currency = r.currency
    and x.status in ('approved', 'sent') and x.id <> r.id;
  if r.gross_minor > coalesce(v_owed, 0) - v_inflight then
    return 'payout_not_covered';
  end if;
  if private.epc_name_empty(t.payee_name) then
    return 'payee_name_not_epc';
  end if;
  if not private.iban_in_sepa(t.payee_iban) then
    return 'iban_not_sepa';
  end if;
  if r.earliest_latest_execution_date is not null and p_execution_date > r.earliest_latest_execution_date
     and r.late_reason is null and p_late_reason is null then
    return 'late_reason_required';
  end if;
  return null;
end;
$$;

-- private.refund_transfer_follow, redefined from 20261116090000_debit_bookings.sql (line 4683; same signature and settings, its grants restated below).
-- M2c-6b-3a (D, H-PAY): a debit naming neither an end-to-end id nor a PmtInf executes a refund whose transfer is in a
-- downloaded or sent file only while it re-issues none (round 7) and no refund cancelled out of a downloaded file of the
-- account at the line's amount, of any payment, may be the line's late execution (rule 3b's (iv)) — else `reissue_in_downloaded_file`, its hint by the account's feed. A refund whose transfer is ordered
-- (never handed out) is still executed by such a line and its transfer booked. Review round 1: the reader is
-- private.refund_line_barred_by — (DP-2) a payout (iii, cancelled) or a sweep (iv) cancelled out of a downloaded file
-- may be the line too, the hint naming its kind; (DP-1) a refund whose transfer is not handed out (ordered, or in a file
-- not downloaded) is refused `cancelled_transfer_matches` while a cancelled one of another payment, or such a payout or
-- sweep, may be the line (the same payment's earlier refund executed late still executes it: D7, M's exit); (LD-3) the
-- `already_debited` hint names a debit without our references too. Nothing else changes.
create or replace function private.refund_transfer_follow()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.bank_transfer;
  f public.transfer_file;
  x public.bank_transaction;
  v_bar jsonb;
begin
  if new.transfer_id is null or new.status = old.status then
    return null;
  end if;
  perform private.remittance_command_locks(new.organization_id, true);
  select * into t from public.bank_transfer where id = new.transfer_id for update;
  if new.status in ('executed', 'cancelled') and t.status = 'in_file' then
    select * into f from public.transfer_file where id = t.transfer_file_id for update;
    if f.status in ('pending', 'generated') then
      perform private.transfer_file_release(f.id, 'superseded',
        case new.status when 'executed' then 'Remboursement ' || new.end_to_end_id || ' exécuté hors du fichier'
                        else 'Remboursement ' || new.end_to_end_id || ' annulé' end, null, null);
      select * into t from public.bank_transfer where id = t.id;
    -- review round 6 (round 4's G2 rule, now): executed only by a debit carrying this transfer's own end-to-end id, or
    -- by a batch line (no end-to-end id) of its own PmtInf in this file — never another id, another PmtInf (of this file,
    -- or a predecessor's: the re-issue would be booked here, its bytes still to be uploaded); review round 7 (N1 (b)):
    -- or by a line naming neither, while this transfer re-issues none (as in M2b: a CSV feed without the reference)
    elsif new.status = 'executed' and not exists (
            select 1 from public.bank_transaction b where b.id = new.bank_transaction_id
              and (b.end_to_end_id = t.end_to_end_id
                   or (b.end_to_end_id is null and b.payment_info_id = (
                         select i.pmt_inf_id from public.transfer_file_item i
                         where i.file_id = f.id and i.transfer_id = t.id))
                   or (b.end_to_end_id is null and b.payment_info_id is null and t.replaces_transfer_id is null
                       -- M2c-6b-3a (D): nor while a transfer cancelled out of a downloaded file may be this line
                       and private.refund_line_barred_by(b.id, new.id) is null))) then
      select * into x from public.bank_transaction where id = new.bank_transaction_id;
      if x.end_to_end_id is null and x.payment_info_id is null and t.replaces_transfer_id is null then
        v_bar := private.refund_line_barred_by(x.id, new.id);
      end if;
      raise exception 'refund refused: reissue_in_downloaded_file' using errcode = 'check_violation',
        detail = jsonb_build_object('file', f.number, 'transfer_id', t.id, 'cancelled_file', v_bar ->> 'file',
                                    'cancelled_kind', v_bar ->> 'kind')::text,
        hint = case when v_bar is not null then
                 'Ce débit ne porte aucune référence, et un '
                 || case v_bar ->> 'kind' when 'payout' then 'reversement' when 'sweep' then 'virement au compte propre'
                                          else 'remboursement' end
                 || ' de ce montant était dans le fichier '
                 || (v_bar ->> 'file') || ', annulé après téléchargement : il peut en être l''exécution tardive. Il ne peut pas '
                 || 'exécuter ce remboursement, dont le virement est dans le fichier ' || f.number
                 || ', déjà téléchargé. '
                 || case when (select a.feed from public.bank_account a where a.id = t.debtor_bank_account_id) = 'csv'
                         then 'Ce relevé ne porte pas nos références : demandez à la banque le détail de ce débit et prévenez le support.'
                         else 'Ne le rattachez pas : attendez la ligne qui porte sa référence RFD ou celle de son lot, ou voyez avec la banque.' end
               else 'Ce débit '
               || case when x.end_to_end_id is not null then 'porte la référence d''un autre virement'
                       when x.payment_info_id is not null then 'porte la référence d''un autre lot'
                       else 'ne porte aucune référence, et le virement de ce remboursement en remplace un autre' end
               || ' : il ne peut pas exécuter ce remboursement, dont le virement est dans le fichier ' || f.number
               || ', déjà téléchargé. '
               || case when private.switch_on('downloaded_file_cancellation') and t.replaces_transfer_id is not null
                       then 'S''il exécute, en retard, le virement que celui-ci remplace, faites d''abord annuler ce fichier, relevé à l''appui, puis rattachez ce débit : rattaché avant, le remboursement serait payé une seconde fois si la banque exécute ce fichier. Sinon, ne le rattachez pas à ce remboursement.'
                       else 'Ne le rattachez pas à ce remboursement ; gardez le fichier tel quel, vérifiez le relevé et voyez avec la banque.' end
               end;
    elsif new.status = 'cancelled' then
      raise exception 'refund refused: in_downloaded_file' using errcode = 'check_violation',
        detail = jsonb_build_object('file', f.number, 'transfer_id', t.id)::text,
        hint = case when private.switch_on('downloaded_file_cancellation')
                    then 'Le fichier a été téléchargé : faites d''abord annuler son virement, relevé à l''appui.'
                    else 'Le virement de ce remboursement est dans un fichier déjà téléchargé : il reste en cours jusqu''à ce que son débit soit comptabilisé depuis le relevé, à son arrivée (de même, ensuite, le retour de la banque du bénéficiaire, si elle le renvoie), et le remboursement ne peut pas être annulé d''ici là (l''annulation après téléchargement n''est pas encore disponible). Un virement que la banque refuse avant son exécution n''apparaît sur aucun relevé : il reste « en cours » jusqu''à ce que l''annulation après téléchargement soit disponible. Gardez le fichier tel quel, vérifiez le relevé, voyez avec la banque et prévenez le support.' end;
    end if;
  end if;
  -- review round 1 (DP-1, DP-2): a refund not handed out (ordered, its file just superseded above) executed by a line
  -- carrying neither an end-to-end id nor a PmtInf, while a transfer cancelled out of a downloaded file that bars it
  -- (a refund of another payment, a payout, a sweep) may be that line
  if new.status = 'executed' and t.status = 'ordered' then
    select * into x from public.bank_transaction where id = new.bank_transaction_id;
    if x.end_to_end_id is null and x.payment_info_id is null then
      v_bar := private.refund_line_barred_by(x.id, new.id);
      if v_bar is not null then
        raise exception 'refund refused: cancelled_transfer_matches' using errcode = 'check_violation',
          detail = jsonb_build_object('transfer_id', t.id, 'cancelled_file', v_bar ->> 'file',
                                      'cancelled_kind', v_bar ->> 'kind')::text,
          hint = 'Ce débit ne porte aucune référence, et un '
                 || case v_bar ->> 'kind' when 'payout' then 'reversement' when 'sweep' then 'virement au compte propre'
                                          else 'remboursement d''un autre paiement' end
                 || ' de ce montant était dans le fichier ' || (v_bar ->> 'file')
                 || ', annulé après téléchargement : il peut en être l''exécution tardive. Ne le rattachez pas à ce '
                 || 'remboursement ; demandez à la banque le détail de ce débit.';
      end if;
    end if;
  end if;
  if new.status = 'executed' then
    update public.bank_transfer set status = 'booked', entry_id = new.cash_out_entry_id
    where id = t.id and status in ('ordered', 'in_file');
  elsif new.status = 'cancelled' then
    if private.transfer_debited_before(t.id) then
      raise exception 'refund refused: already_debited' using errcode = 'check_violation',
        detail = jsonb_build_object('transfer_id', t.id, 'end_to_end_id', t.end_to_end_id)::text,
        -- review round 1 (LD-3): true of L's line too (a debit without our references only may be the earlier one's)
        hint = 'Un relevé montre déjà le débit de ce remboursement (sous sa référence, celle du virement qu''il remplace, ou dans une ligne groupée de son lot), ou un débit sans nos références de son montant peut être l''exécution tardive du virement qu''il remplace : ne l''annulez pas ; voyez ce débit dans « Débits et retours » (sinon, demandez à la banque le détail de ce débit).';
    end if;
    update public.bank_transfer set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
      cancel_reason = left('Remboursement annulé : ' || coalesce(new.cancel_reason, ''), 2000)
    where id = t.id and status = 'ordered';
  elsif new.status = 'bounced' then
    update public.bank_transfer set status = 'returned', return_entry_id = new.bounce_entry_id
    where id = t.id and status = 'booked';
  end if;
  return null;
end;
$$;

-- public.debit_link_options, redefined from 20261117110000_transfer_line_pages.sql (line 2623; same signature and settings, its grants restated below).
-- M2c-6b-3a (D): a debit naming neither an end-to-end id nor a PmtInf no longer lists a refund that a transfer cancelled
-- out of a downloaded file bars from it (private.refund_line_barred_by, review round 1: whatever the refund's transfer's
-- status — a refund of another payment, a payout or a sweep for one not handed out): the refund's trigger would refuse
-- the link. Nothing else changes.
create or replace function public.debit_link_options(p_bank_transaction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare
  t public.bank_transaction;
  v_kind text;
  v_batch boolean;
  v_no_payment boolean;
  v_return_guard text;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id
    and organization_id = any (private.money_staff_org_ids());
  if not found then
    return null;
  end if;
  select coalesce(r.released_kind, t.kind) into v_kind
  from (select 1) x left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id;
  -- review round 7 (S2): a line of an entry kept unsplit holding a detail of ours takes no link (private.post_debit_links)
  if coalesce(t.unsplit_ours, 0) > 0 then
    return jsonb_build_object('payments', '[]'::jsonb, 'refunds', '[]'::jsonb, 'kind', v_kind);
  end if;
  -- our batch line, read as private.post_debit_links reads it
  v_batch := coalesce(t.direction = 'debit' and t.end_to_end_id is null
                      and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
                      and exists (select 1 from public.transfer_file_item i
                                  cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                                      where f.id = i.file_id offset 0) f
                                  where i.pmt_inf_id = t.payment_info_id
                                    and f.debtor_bank_account_id = t.bank_account_id), false);
  if v_batch then
    return jsonb_build_object(
      'payments', '[]'::jsonb,
      'refunds', case when exists (
                          select 1 from public.transfer_file_item i
                          cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                              where f.id = i.file_id offset 0) f
                          cross join lateral (select m.status, m.transfer_file_id from public.bank_transfer m
                                              where m.id = i.transfer_id offset 0) m
                          where i.pmt_inf_id = t.payment_info_id and f.debtor_bank_account_id = t.bank_account_id
                            and m.transfer_file_id = i.file_id and m.status = 'cancelled'
                            and not private.transfer_return_seen(i.transfer_id))
                      then '[]'::jsonb
                      else coalesce((
        select jsonb_agg(jsonb_build_object('refund_request_id', q.id, 'payment_id', q.payment_id,
                                            'amount_minor', q.amount_minor::text, 'end_to_end_id', q.end_to_end_id,
                                            'status', q.status, 'payee_name', q.payee_name,
                                            'payee_iban_end', right(q.payee_iban, 4), 'requested_at', q.requested_at)
                         order by q.requested_at desc, q.id)
        from (select y.file_id, y.transfer_id from public.transfer_file_item y
              where y.pmt_inf_id = t.payment_info_id offset 0) i
        cross join lateral (select f.debtor_bank_account_id, f.status from public.transfer_file f
                            where f.id = i.file_id offset 0) f
        cross join lateral (select m.kind, m.status, m.transfer_file_id from public.bank_transfer m
                            where m.id = i.transfer_id offset 0) m
        cross join lateral (select q.* from public.refund_request q where q.transfer_id = i.transfer_id offset 0) q
        where f.debtor_bank_account_id = t.bank_account_id and f.status in ('downloaded', 'sent')
          and m.kind = 'refund' and m.status = 'in_file' and m.transfer_file_id = i.file_id
          and q.status = 'requested' and q.bank_account_id = t.bank_account_id
          and q.amount_minor = t.amount_minor), '[]') end,
      'kind', v_kind);
  end if;
  if coalesce(t.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
     or coalesce(coalesce(t.original_end_to_end_id, t.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$', false) then
    return jsonb_build_object('payments', '[]'::jsonb, 'refunds', '[]'::jsonb, 'kind', v_kind);
  end if;
  -- review round 5 (Q1): a credit that is one of our transfers coming back (private.names_our_transfer, as
  -- private.post_debit_links reads it): no payment, and as refund only the one that function accepts there — on a
  -- `return` naming one of our lots with no end-to-end id, the refund that lot held alone
  -- (private.pmt_inf_refund_back), executed, on the line's account and of its amount
  -- review round 6 (R2): or one naming one of our lots on its account (a file handed out) whatever its end-to-end id
  if t.direction = 'credit'
     and (private.names_our_transfer(t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id)
          or private.names_our_lot(t.bank_account_id, t.payment_info_id)) then
    return jsonb_build_object(
      'payments', '[]'::jsonb,
      'refunds', coalesce((
        select jsonb_agg(jsonb_build_object('refund_request_id', q.id, 'payment_id', q.payment_id,
                                            'amount_minor', q.amount_minor::text, 'end_to_end_id', q.end_to_end_id,
                                            'status', q.status, 'payee_name', q.payee_name,
                                            'payee_iban_end', right(q.payee_iban, 4), 'requested_at', q.requested_at))
        from public.refund_request q
        where v_kind = 'return'
          and q.id = private.pmt_inf_refund_back(t.bank_account_id, t.payment_info_id)
          and q.status = 'executed' and q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor),
        '[]'),
      'kind', v_kind);
  end if;
  -- review 6b-2c (money-1, money-2): no payment on a debit « Comptabiliser… » books (private.link_debit_guard refuses
  -- its return and its loss: payout_candidate, client_payout_line — round 2: only on a kind it books, never on a debit
  -- the bank flags as a return), and only the refunds that guard lets through (the refund link, « Remboursement revenu »
  -- on the flagged return from a client's payout IBAN)
  if t.direction = 'debit' then
    v_return_guard := private.link_debit_guard(t.id, 'return', null);
  end if;
  v_no_payment := t.direction = 'debit' and v_return_guard is not null;
  return case when t.direction = 'debit' then jsonb_build_object('return_guard', v_return_guard) else '{}'::jsonb end
    || jsonb_build_object(
    'payments', case when t.direction = 'debit' and not v_no_payment then coalesce((
      with y as (select p.id, p.amount_minor, p.booking_date, p.payer_name, p.status, p.account_id
                 from public.payment p
                 where p.bank_account_id = t.bank_account_id and p.booking_date <= t.booking_date
                   and p.status <> 'returned' and p.amount_minor >= t.amount_minor
                 order by (p.amount_minor = t.amount_minor) desc, p.booking_date desc, p.id
                 limit 60)
      select jsonb_agg(jsonb_build_object('payment_id', y.id, 'amount_minor', y.amount_minor::text,
                                          'booking_date', y.booking_date, 'payer_name', y.payer_name, 'status', y.status,
                                          'left_minor', (pos.amount_minor - pos.returned_minor)::text,
                                          'file_reference', a.external_ref)
                       order by (pos.amount_minor - pos.returned_minor = t.amount_minor) desc, y.booking_date desc, y.id)
      from y
      join private.payment_positions(array(select y2.id from y y2)) pos on pos.payment_id = y.id
      left join public.account a on a.id = y.account_id
      where pos.amount_minor - pos.returned_minor >= t.amount_minor
      ), '[]') else '[]'::jsonb end,
    'refunds', coalesce((
      select jsonb_agg(jsonb_build_object('refund_request_id', q.id, 'payment_id', q.payment_id,
                                          'amount_minor', q.amount_minor::text, 'end_to_end_id', q.end_to_end_id,
                                          'status', q.status, 'payee_name', q.payee_name,
                                          'payee_iban_end', right(q.payee_iban, 4), 'requested_at', q.requested_at)
                       order by q.requested_at desc)
      from (select * from public.refund_request q
            where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
              and q.status = case when t.direction = 'debit' then 'requested' else 'executed' end
            order by q.requested_at desc limit 20) q
      where private.link_debit_guard(t.id, case when t.direction = 'debit' then 'refund' else 'refund_returned' end,
                                     q.id) is null
        -- M2c-6b-3a (D): never one the refund's trigger refuses for a cancelled transfer this line may be
        and not (t.direction = 'debit' and t.end_to_end_id is null and t.payment_info_id is null
                 and private.refund_line_barred_by(t.id, q.id) is not null)), '[]'),
    'kind', v_kind);
end;
$$;

-- private.link_debit_guard, redefined from 20261117113000_transfer_line_pages_fixes.sql (line 265; same signature and settings, its grants restated below).
-- M2c-6b-3a review round 1 (DP-2): the refund link on a debit without our reference is also refused payout_candidate
-- while rule 3b finds a payout cancelled out of a downloaded file (iii, cancelled — whatever its run's state; never a
-- payout only returned: OQ-86) or a sweep cancelled so (iv): the line may be its late execution, and once linked as a
-- refund it is no longer that transfer's open late debit (private.transfer_unreferenced_lines skips linked lines) —
-- the client's next payout (M) or the servicer's next share (A, B) would be released although the money may have left
-- for it. The sweep exemption of round 7 (N1 (b)) stays for a sweep in flight (i). The fee and the explanation, the
-- return and the loss (OQ-86, its switch-on default: COMPLIANCE OQ-86 (b)) are unchanged. Nothing else changes.
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

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new internals revoked, the new read the back office's)
------------------------------------------------------------------------------------------

-- the new internals (PostgreSQL grants EXECUTE to PUBLIC by default): only the SECURITY DEFINER callers use them
revoke execute on function private.transfer_unreferenced_lines(uuid), private.transfer_late_debit_open(uuid),
  private.sweep_after_debited_cancelled(uuid), private.transfer_sibling_debited_late(uuid),
  private.refund_line_barred_by(uuid, uuid)
  from public, anon, authenticated, service_role;
-- the redefined guard, as granted by 20261117113000 (private.link_debit_guard: internal)
revoke execute on function private.link_debit_guard(uuid, text, uuid) from public, anon, authenticated, service_role;
-- the redefined internals as granted by 20261115090000 (private.transfer_debited_before,
-- private.debited_cancelled_sweeps, private.transfer_cancel_evidence, private.transfer_hold_reason)
revoke execute on function private.transfer_debited_before(uuid), private.debited_cancelled_sweeps(uuid),
  private.transfer_cancel_evidence(uuid, uuid, boolean), private.transfer_hold_reason(uuid, date, date, text)
  from public, anon, authenticated;
-- as granted by 20261117110000 (private.transfer_line_candidates, private.transfer_line_check,
-- private.transfer_line_options_of, private.run_transfer_checks)
revoke execute on function private.transfer_line_candidates(uuid, text), private.transfer_line_check(uuid, boolean),
  private.transfer_line_options_of(uuid), private.run_transfer_checks(uuid, uuid, date)
  from public, anon, authenticated, service_role;
-- the trigger function, as granted by 20261116090000 (internal)
revoke execute on function private.refund_transfer_follow() from public, anon, authenticated;
-- the back office's commands and reads, as granted by 20261115090000 (public.transfer_overview), 20261116090000
-- (public.generate_transfer_file), 20261117090000 (public.transfer_file_download) and 20261117110000
-- (public.debit_link_options); the new read alike (any member of a servicer reads the flag: checked inside)
revoke execute on function public.transfer_overview(), public.generate_transfer_file(text, uuid, text),
  public.transfer_file_download(uuid, text, boolean), public.debit_link_options(uuid),
  public.cancellation_after_download()
  from public, anon;
grant execute on function public.transfer_overview(), public.generate_transfer_file(text, uuid, text),
  public.transfer_file_download(uuid, text, boolean), public.debit_link_options(uuid),
  public.cancellation_after_download()
  to authenticated;
