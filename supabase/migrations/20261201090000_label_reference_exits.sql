-- M2c-7e-3 « our references in CSV labels: the three exits » (plan docs/design/m2c-7-plan.md §7.3's exits (a), (b) and
-- (c), §7.4's actions, §7.5's 047c, §7.6; [critic] M7-MONEY-6, [check 2] gap 1 (1), (2), (4); founder Q15 and its added
-- question, defaults a, still open; ADR-0014 « M2c-7e-3 »). Forward-only.
--
-- A CSV credit held `label_reference` because its label cites one of our transfers of the statement's account (7e-2:
-- never a payment, never booked by the debit job, never a return by itself, never linked) leaves review by one of its
-- exits, each through the existing command and its rights (admins and ops managers at aal2, an idempotency key):
--   (a) the return of exactly that transfer — public.book_transfer_line (« Oui, c'est son retour »): the line is of
--       class L, its only returnable transfer the payout or the sweep its label cites (a top-up has none); a part
--       naming another transfer is label_reference_transfer, a fee part or an amount other than exactly that
--       transfer's label_reference_amount. Booked, the return counts in the chain's events, so a payout that came back
--       never reads « versé »;
--   (b) a client's payment — public.book_client_payment_line with the client ops name (« Règlement du client »):
--       client_required without one, client_unknown for a non-client, client_mismatch when the line's IBAN is another
--       client's confirmed payout IBAN; our reference read from the label is ignored;
--   (c) a debtor's payment — public.release_own_credit (« Paiement d'un débiteur »): its release row, the payment to
--       assign and its cash_in; its payer the line's own counterparty, or « Versement relayé par le client » with no
--       IBAN when that IBAN is a client's confirmed payout IBAN;
--   (d) founder Q15's added question, default a (ADR-0014 « M2c-7e-2 » review round 1, MB-3): our own top-up's credit
--       on a CSV export with no counterparty IBAN — public.book_top_up_credit naming the TOP its label cites, at exactly
--       its amount (« C'est cet approvisionnement »).
-- Every exit deletes the line's review (the commands' own delete); the nightly's label_reference_waiting, the debit
-- job's candidates and « À classer » leave a booked or released line at their next read (unchanged: they already read
-- bookings, links and releases). The guards still refuse anything else on such a line.
-- The cancellation-after-download switch is not written here (it stays off); no rule of this slice reads it.
--
-- Redefined (each copied whole from its latest definition across every migration — the last one wins —, its header
-- naming the file and line; SECURITY DEFINER, every SET clause, search_path '' and the grants restated):
--   private.transfer_line_class (20261117100000_transfer_line_ops.sql:124), private.transfer_line_pre
--     (20261117113000_transfer_line_pages_fixes.sql:59), private.transfer_line_check (20261125090000_repayment_requests.sql
--     :1225, 7c-2's), private.transfer_line_options_of (20261118100000_switch_on_prerequisites_2.sql:1597);
--   private.bank_line_booking_guard (20261121090000_switch_on_prerequisites_4.sql:641);
--   private.remittance_chain_events (20261118100000:164);
--   private.client_line_facts (20261124090000_client_payments.sql:1666: a second argument, the client ops name; the
--     one-argument form a wrapper), public.client_payment_line and public.book_client_payment_line
--     (20261125090000:2154, :2216, 7c-2's; dropped and created, a trailing p_client_organization_id);
--   public.release_own_credit (20261117110000_transfer_line_pages.sql:3128), private.bank_own_credit_release_guard,
--     private.payment_insert_guard (20261111120000_identities_terms.sql:2497, :2591);
--   public.book_top_up_credit (20261129090000_top_ups.sql:945), private.bank_booking_recheck (20261129090000:1470, 7e-1's);
--   (ADR-0014 « M2c-7e-3 review fixes » round 2: the returned payouts' accounts set 'returned' by their key alone, the
--     one update a BitmapAnd with a partial index read whole under stale statistics) private.transfer_line_post
--     (20261123080000_cover_reads_by_run_key.sql:304) and private.bank_booking_post_rows
--     (20261122090000_remitted_reversals_covered.sql:1789).
-- Not redefined: private.transfer_line_bookable_as and public.debit_queue (« À classer » offers « Oui, c'est son retour »
-- from the queue's own label_transfer — its kind a payout or a sweep — and its sheet reads the options, class L: ADR
-- deviation), private.run_advance_checks (label_reference_waiting already leaves a booked, linked or released line).
-- private.transfer_line_post's posting reads the parts, not the line's kind, and deletes the review: its one change is
-- the payout account's update (round 2, above).


------------------------------------------------------------------------------------------
-- Exit (a): the return of exactly that transfer (plan §7.3; [check 1] [check 2] gap 1 (1))
------------------------------------------------------------------------------------------

-- private.transfer_line_class, redefined from 20261117100000_transfer_line_ops.sql (line 124; same signature and
-- settings, its grants restated below). M2c-7e-3 (plan §7.3 exit (a)): class L — a credit held because its CSV label
-- cites one of our transfers (label_reference, as read or a held line released so), after our own ids and lots (the
-- bank's word on the line stands: such a line carries neither, or it would not be of this kind) and before E0, N and O.
-- Nothing else changes.
create or replace function private.transfer_line_class(p_line_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case
    when coalesce(t.unsplit_ours, 0) > 0 then 'U'
    when t.direction = 'debit' and t.end_to_end_id is not null
         and exists (select 1 from (select x.organization_id from public.bank_transfer x
                                    where x.end_to_end_id = t.end_to_end_id offset 0) x
                     where x.organization_id = t.organization_id) then 'E'
    when t.direction = 'credit' and coalesce(t.original_end_to_end_id, t.end_to_end_id) is not null
         and exists (select 1 from (select x.organization_id from public.bank_transfer x
                                    where x.end_to_end_id = coalesce(t.original_end_to_end_id, t.end_to_end_id)
                                    offset 0) x
                     where x.organization_id = t.organization_id) then 'E'
    when t.direction = 'debit' and t.end_to_end_id is null and t.payment_info_id is not null
         and exists (select 1
                     from (select i.file_id from public.transfer_file_item i where i.pmt_inf_id = t.payment_info_id
                           offset 0) i
                     cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                         where f.id = i.file_id offset 0) f
                     where f.debtor_bank_account_id = t.bank_account_id) then 'B'
    when t.direction = 'credit' and private.names_our_lot(t.bank_account_id, t.payment_info_id) then 'B'
    -- M2c-7e-3 (plan §7.3 exit (a)): L, a credit held because its CSV label cites one of our transfers (label_reference,
    -- as read or a held line released so; its resolution by its key)
    when t.direction = 'credit'
         and coalesce((select r.released_kind from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id),
                      t.kind) = 'label_reference' then 'L'
    when coalesce(case when t.direction = 'credit' then coalesce(t.original_end_to_end_id, t.end_to_end_id)
                       else t.end_to_end_id end ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
         or coalesce(t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$', false) then 'E0'
    when t.end_to_end_id is null and t.payment_info_id is null then 'N'
    else 'O' end
  from public.bank_transaction t where t.id = p_line_id;
$$;


-- private.transfer_line_pre, redefined from 20261117113000_transfer_line_pages_fixes.sql (line 59; same signature and
-- settings, its grants restated below). M2c-7e-3 (plan §7.3 exit (a)): for a line of class L, its only returnable
-- transfer — the payout or the sweep its label cites (bank_transaction.reference_from_label, kept by the import only for
-- a transfer of the statement's account), by the unique end-to-end id, the servicer and the account compared outside the
-- probe; a top-up has no return exit (none). Nothing else changes.
create or replace function private.transfer_line_pre(p_line_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  v_class text := private.transfer_line_class(p_line_id);
  v_cap integer := private.transfer_line_lot_cap();
  v_n integer;
  v_idx integer[];
  v_role text;
begin
  select * into t from public.bank_transaction where id = p_line_id;
  drop table if exists pg_temp._tl_pre;
  create temp table _tl_pre (
    role text not null,                  -- member (debit lot), returnable (lot credit), candidate (rule 3b)
    ord integer not null,
    transfer_id uuid not null,
    kind text, status text, amount_minor bigint, cand text,
    in_subset boolean not null default false,
    unplanned_open boolean,
    primary key (role, transfer_id)
  ) on commit drop;
  drop table if exists pg_temp._tl_meta;
  create temp table _tl_meta (k text primary key, v text) on commit drop;
  insert into pg_temp._tl_meta values ('class', v_class);
  if v_class = 'U' then
    insert into pg_temp._tl_meta values ('member_count', coalesce(jsonb_array_length(t.unsplit_details), 0)::text);
    if jsonb_typeof(t.unsplit_details) = 'array' and jsonb_array_length(t.unsplit_details) > v_cap then
      return 'lot_too_large';
    end if;
    return null;
  end if;
  if v_class = 'B' then
    if t.direction = 'debit' then
      v_role := 'member';
      select count(*) into v_n
      from (select i.file_id from public.transfer_file_item i where i.pmt_inf_id = t.payment_info_id offset 0) i
      cross join lateral (select f.debtor_bank_account_id from public.transfer_file f where f.id = i.file_id offset 0) f
      where f.debtor_bank_account_id = t.bank_account_id;
      insert into pg_temp._tl_meta values ('member_count', v_n::text);
      if v_n > v_cap then
        return 'lot_too_large';
      end if;
      insert into pg_temp._tl_pre (role, ord, transfer_id, kind, status, amount_minor)
      select 'member', m.seq, m.transfer_id, m.kind, m.status, m.amount_minor
      from private.transfer_line_members(p_line_id) m;
    else
      v_role := 'returnable';
      -- the lot's items counted first (keyed), the returnable members read only below the cap
      select count(*) into v_n
      from (select i.file_id from public.transfer_file_item i where i.pmt_inf_id = t.payment_info_id offset 0) i
      cross join lateral (select f.debtor_bank_account_id from public.transfer_file f where f.id = i.file_id offset 0) f
      where f.debtor_bank_account_id = t.bank_account_id;
      if v_n > v_cap then
        insert into pg_temp._tl_meta values ('member_count', v_n::text);
        return 'lot_too_large';
      end if;
      insert into pg_temp._tl_pre (role, ord, transfer_id, kind, status, amount_minor, unplanned_open)
      select 'returnable', m.seq, m.transfer_id, m.kind, m.status, m.amount_minor, m.unplanned_open
      from private.transfer_line_returnable(p_line_id) m;
      insert into pg_temp._tl_meta
      values ('member_count', (select count(*) from pg_temp._tl_pre p where p.role = 'returnable')::text);
    end if;
    v_idx := private.unique_subset(array(select p.amount_minor from pg_temp._tl_pre p where p.role = v_role
                                         order by p.ord), t.amount_minor);
    update pg_temp._tl_pre p set in_subset = true
    from (select p2.transfer_id, row_number() over (order by p2.ord)::integer as k from pg_temp._tl_pre p2
          where p2.role = v_role) x
    where p.role = v_role and p.transfer_id = x.transfer_id and x.k = any (v_idx);
    insert into pg_temp._tl_meta values ('subset', case when v_idx is null then 'none' else 'one' end);
  elsif v_class = 'L' then
    -- M2c-7e-3 (plan §7.3 exit (a)): the only returnable transfer of a credit held because its label cites one of ours —
    -- the payout or the sweep it cites, of the line's account (by the unique end-to-end id alone, the servicer and the
    -- account compared outside); a top-up cited has no return exit
    insert into pg_temp._tl_pre (role, ord, transfer_id, kind, status, amount_minor, unplanned_open)
    select 'returnable', 1, x.id, x.kind, x.status, x.amount_minor, private.transfer_unplanned_open(x.id)
    from (select y.id, y.kind, y.status, y.amount_minor, y.organization_id, y.debtor_bank_account_id
          from public.bank_transfer y where y.end_to_end_id = t.reference_from_label offset 0) x
    where x.organization_id = t.organization_id and x.debtor_bank_account_id = t.bank_account_id
      and x.kind in ('payout', 'sweep');
  elsif v_class in ('N', 'O', 'E0') and t.direction = 'debit' then
    insert into pg_temp._tl_pre (role, ord, transfer_id, kind, status, cand)
    select 'candidate', (row_number() over (order by c.transfer_id))::integer, c.transfer_id, c.kind, c.status, c.cand
    from private.transfer_line_candidates(p_line_id, v_class) c;
    -- (6b-2d, suppression-e0-names-our-other-lot) the line names a lot of ours, and a candidate is outside it: each
    -- candidate's item in its current file by key (the transfer, then the item by (file, transfer))
    if v_class = 'E0' and private.pmt_inf_names_account_lot(t.bank_account_id, t.payment_info_id)
       and exists (select 1
                   from pg_temp._tl_pre p
                   cross join lateral (select y.transfer_file_id from public.bank_transfer y
                                       where y.id = p.transfer_id offset 0) y
                   left join lateral (select i.pmt_inf_id from public.transfer_file_item i
                                      where i.file_id = y.transfer_file_id and i.transfer_id = p.transfer_id
                                      offset 0) i on true
                   where p.role = 'candidate' and i.pmt_inf_id is distinct from t.payment_info_id) then
      return 'names_other_lot';
    end if;
  end if;
  return null;
end;
$$;


-- private.transfer_line_check, redefined from 20261125090000_repayment_requests.sql (line 1225, 7c-2's — 7b's body with
-- advance_requested; same signature and settings, its grants restated below). M2c-7e-3:
--   (plan §7.3 exit (a), [critic] M7-MONEY-6, D14) a line of class L takes return parts only, of the transfer its label
--   cites (its only returnable one) — else label_reference_transfer — and only for exactly that transfer's amount, the
--   line's amount too, with no fee part — else label_reference_amount: a partial amount may be a client's repayment or
--   a debtor's payment quoting our reference, never booked as our transfer's return with the rest as a bank fee. Then
--   the return's own rules, as for our id (E): its booked debit, no open unplanned booking, no pending debit, once;
--   (ADR-0014 7b round 2 « Left open », « M2c-7c-1 » low 5) advance_settled fenced: the double payout's advance first,
--   by its cause entry alone (client_advance_cause_idx; the cause compared outside), then its settlements by the
--   document alone (commission_settlement_document_idx; the kind compared outside) — joined, with stale statistics and
--   generic plans the read went through the whole settlement index (10,000 rows on the preview, 20,000 on the booking).
-- Nothing else changes.
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
                   and v_kind not in ('return', 'own_transfer_in', 'client_transfer_in')
                   -- M2c-7e-3 (exit (a)): a credit held because its label cites one of ours, of class L (below)
                   and not (v_kind = 'label_reference' and v_class = 'L')) then
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
    -- M2c-7e-3 (plan §7.3 exit (a), [critic] M7-MONEY-6, D14): a credit held because its CSV label cites one of our
    -- transfers (class L) is booked as the return of that transfer only — its only returnable one, pg_temp._tl_pre (a
    -- payout or a sweep of the line's account; a top-up has none): any other part, or none, is label_reference_transfer
    -- — and only for exactly that transfer's amount, the line's too, with no fee part: label_reference_amount
    if v_class = 'L' then
      if not exists (select 1 from pg_temp._tl t where t.kind <> 'fee')
         or exists (select 1 from pg_temp._tl t
                    where t.kind <> 'fee'
                      and (t.kind not in ('payout_returned', 'sweep_returned', 'unplanned_payout_returned',
                                          'unplanned_sweep_returned')
                           or not exists (select 1 from pg_temp._tl_pre p
                                          where p.role = 'returnable' and p.transfer_id = t.transfer_id))) then
        v_why := 'label_reference_transfer'; exit rules;
      end if;
      if exists (select 1 from pg_temp._tl t where t.kind = 'fee')
         or exists (select 1 from pg_temp._tl t
                    join pg_temp._tl_pre p on p.role = 'returnable' and p.transfer_id = t.transfer_id
                    where t.amount <> p.amount_minor or l.amount_minor <> p.amount_minor) then
        v_why := 'label_reference_amount'; exit rules;
      end if;
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
                 -- M2c-7e-3 (exit (a)): the transfer the label cites, the line's only returnable one
                 when 'L' then exists (select 1 from pg_temp._tl_pre p where p.role = 'returnable'
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
                -- M2c-7e-3 (exit (a)): the transfer a label_reference line's label cites, its only returnable one
                or (v_class = 'L' and r.transfer_id is not null
                    and exists (select 1 from pg_temp._tl_pre p where p.role = 'returnable'
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
        -- (M2c-7e-3, ADR-0014 7b round 2 « Left open ») fenced: the advance by its cause entry alone, then its
        -- settlements by the document alone, each kind compared outside the probe
        if exists (select 1
                   from (select a.id, a.cause from public.client_advance a
                         where a.cause_entry_id = v_bk.entry_id offset 0) a
                   cross join lateral (select s.document_kind from public.commission_settlement s
                                       where s.document_id = a.id offset 0) s
                   where a.cause = 'double_payout' and s.document_kind = 'advance') then
          v_why := 'advance_settled'; exit rules;
        end if;
        -- (M2c-7b) a run approved or sent takes the advance back: refused until its debit settles it
        if exists (select 1 from public.client_advance a
                   cross join lateral private.advance_in_flight_run(a.id) f
                   where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout') then
          v_why := 'advance_in_flight'; exit rules;
        end if;
        -- (M2c-7c-2 review round 1, MONEY-1) a repayment request not withdrawn names the advance: the return would
        -- reverse it while a letter asks the client to repay it (a payout the client did not keep) — refused until the
        -- request is withdrawn (« Retirer la demande »)
        if exists (select 1 from public.client_advance a
                   cross join lateral private.advance_live_request(a.id) q
                   where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout') then
          v_why := 'advance_requested'; exit rules;
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


-- private.transfer_line_options_of, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 1597; same
-- signature and settings, its grants restated below). M2c-7e-3 (plan §7.4 « Oui, c'est son retour »): a line of class L
-- is proposed the return of exactly the transfer its label cites, as a credit of our id (E) is — its unplanned booking's
-- return while one is open, else its planned return; a pending debit of it first (debit_pending) — and never a fee
-- part; the preview refuses a line of another amount (label_reference_amount); with no returnable transfer (a top-up
-- cited) the refusal is label_reference_transfer. Nothing else changes.
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
  elsif v_class = 'L' then
    -- M2c-7e-3 (plan §7.4 « Oui, c'est son retour »): the return of exactly the transfer the label cites (the line's
    -- only returnable one, private.transfer_line_pre), as an E credit's — never a fee part
    select y.* into v_x
    from pg_temp._tl_pre p
    cross join lateral (select q.* from public.bank_transfer q where q.id = p.transfer_id offset 0) y
    where p.role = 'returnable';
    if v_x.id is null then
      v_refusal := 'label_reference_transfer';
    else
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
        v_action := 'returned';
      else
        v_parts := jsonb_build_array(jsonb_build_object('kind', v_x.kind || '_returned', 'transfer_id', v_x.id,
                                                        'amount', v_x.amount_minor::text));
        v_action := 'returned';
      end if;
    end if;
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


-- private.bank_line_booking_guard, redefined from 20261121090000_switch_on_prerequisites_4.sql (line 641; same
-- signature and settings — hash and merge joins and sequential scans off —, its trigger unchanged, its grants restated
-- below). M2c-7e-3 ([check 2] gap 1 (1)): its per-row read gains whether the line is a credit held because its label
-- cites one of our transfers (label_reference, as read or released so) naming, as the booking's transfer, exactly the
-- one it cites (that transfer's end-to-end id by its key, as tr_kind is), and whether the statement gives no
-- counterparty IBAN. The four return arms admit such a line for that transfer only — an unplanned return with no
-- transfer, or naming a run-mate payout, stays refused on it —, every other condition of each arm unchanged; the
-- client_payment arm admits it (exit (b)); the top_up arm admits it, the TOP it cites, with no counterparty IBAN (the
-- fourth exit). Nothing else changes.
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
           -- M2c-7e-3: a credit held because its label cites one of our transfers (label_reference, as read or
           -- released so) that names, as this booking's transfer, exactly the one it cites (that transfer by its key)
           coalesce((case when t.kind = 'suspected_duplicate' then r.released_kind else t.kind end) = 'label_reference'
                    and n.transfer_id is not null
                    and (select x.end_to_end_id from public.bank_transfer x where x.id = n.transfer_id)
                        = t.reference_from_label, false) as label_cites,
           -- (the fourth exit) its statement gives no counterparty IBAN
           t.counterparty_iban is null as no_iban,
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
                                  and ((x.kind = 'own_transfer_in'
                                        and ((n.transfer_id is null and x.source_type = 'bank_transaction'
                                              and x.source_id = n.bank_transaction_id::text)
                                             or (n.transfer_id is not null and x.tr_kind = 'top_up'
                                                 and x.tr_creditor = n.bank_account_id
                                                 and x.source_type = 'bank_transfer'
                                                 and x.source_id = n.transfer_id::text)))
                                       -- M2c-7e-3 (the fourth exit): a credit held because its label cites this
                                       -- top-up, its statement giving no counterparty IBAN
                                       or (x.label_cites and x.no_iban and x.tr_kind = 'top_up'
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
                                                 and (x.kind in ('return', 'own_transfer_in', 'client_transfer_in')
                                                      or x.label_cites))
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
                                                and (x.kind in ('return', 'own_transfer_in', 'client_transfer_in')
                                                     or x.label_cites))
                                               or x.unsplit)
                                          and n.transfer_id is not null and x.tr_kind = 'sweep'
                                          and x.tr_debtor = n.bank_account_id
                                          and x.reverses_entry_id is not distinct from x.tr_entry)
          -- M2c-6b-2b: the return of an unplanned payout or sweep reverses the entry of an unplanned booking of the
          -- same transfer (or of none), on a credit coming back (or a line of an entry kept unsplit)
          when 'unplanned_payout_returned' then not (x.entry_type = 'reversal'
                                                     and ((x.direction = 'credit'
                                                           and (x.kind in ('return', 'own_transfer_in',
                                                                           'client_transfer_in')
                                                                or x.label_cites))
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
                                                          and (x.kind in ('return', 'own_transfer_in',
                                                                          'client_transfer_in')
                                                               or x.label_cites))
                                                         or x.unsplit)
                                                    and x.reversed_kind = 'unplanned_sweep'
                                                    and x.reversed_transfer is not distinct from n.transfer_id
                                                    and (n.transfer_id is null
                                                         or (x.tr_kind = 'sweep' and x.tr_debtor = n.bank_account_id)))
          when 'client_payment' then not (x.entry_type = 'client_payment_dedicated' and x.direction = 'credit'
                                          -- M2c-7e-3 (exit (b)): a credit held because its label cites ours
                                          and x.kind in ('client_transfer_in', 'label_reference')
                                          and n.transfer_id is null
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


-- private.remittance_chain_events, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 164; same
-- signature and settings, its grants restated below). M2c-7e-3 ([check 2] gap 1 (4)): its third return branch — the
-- credits booked payout_returned or unplanned_payout_returned for this transfer (bank_line_booking_transfer_idx), each
-- line by its key — also counts a line whose label cites this transfer (bank_transaction.reference_from_label = its
-- end-to-end id): exit (a)'s CSV credit carries no id of ours, so remittance_chain_paid, remittance_run_paid_on,
-- run_settled_on, entry_remitted, the nightly's booked branch and request_advance_repayment's payout_not_received now
-- see the payout came back. Only a booked line counts: a label_reference line in review may be the client's payment
-- (D14). A line carrying a /REF that is not ours (its end-to-end id, never one of ours on this kind) counts too: the
-- plan's « carries no end-to-end id » is the lot branch's own condition, kept for it. Nothing else changes.
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
      cross join lateral (select q.id, q.direction, q.payment_info_id, q.end_to_end_id, q.original_end_to_end_id,
                                 q.reference_from_label
                          from public.bank_transaction q where q.id = k.bank_transaction_id offset 0) q
      where q.direction = 'credit'
        and ((q.end_to_end_id is null and q.original_end_to_end_id is null
              and exists (select 1 from public.transfer_file_item i
                          where i.transfer_id = t.id and i.pmt_inf_id = q.payment_info_id))
             -- M2c-7e-3 ([check 2] gap 1 (4)): booked as its return (exit (a)), a line whose label cites it
             or q.reference_from_label = t.end_to_end_id)
    ) l
    cross join lateral (select q.id, q.booking_date, q.kind from public.bank_transaction q where q.id = l.id offset 0) x
    -- (a line held as a suspected duplicate counts once released: the kind its release gives it, above)
    where not exists (select 1 from public.payment p where p.bank_transaction_id = x.id offset 0)
  ) e;
$$;


------------------------------------------------------------------------------------------
-- Exit (b): a client's payment (plan §7.3; [check 2])
------------------------------------------------------------------------------------------

-- private.client_line_facts, redefined from 20261124090000_client_payments.sql (line 1666) with a second argument, the
-- client ops name (null: none; the one-argument form below a wrapper passing null). M2c-7e-3 (plan §7.3 exit (b)): a
-- credit held because its label cites one of our transfers (label_reference, as read or released so) is a client's
-- payment — our reference in its label ignored (the client quoting it); every other our_reference rule (our id as its
-- own or original end-to-end id, our lot, an entry kept unsplit holding ours, a TOP end-to-end id) unchanged — of the
-- client ops name: client_unknown when it is not a client of the line's servicer; client_mismatch when the line's IBAN
-- is another client's confirmed payout IBAN; with no client named, the client whose confirmed payout IBAN the line
-- comes from (as a client_transfer_in line's), else client_required (« le compte émetteur n'est pas un compte de
-- reversement confirmé », plan §7.4). A client_transfer_in line is its IBAN's client's, as before; a client named for
-- it must be that one (client_mismatch). Same settings.
create or replace function private.client_line_facts(p_bank_transaction_id uuid, p_client_organization_id uuid)
returns table (refusal text, client_id uuid)
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  v_kind text;
  v_held boolean;
  v_clients uuid[];
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  select coalesce(r.released_kind, t.kind), (t.kind = 'suspected_duplicate' and r.decision is distinct from 'released')
  into v_kind, v_held
  from (select 1) d
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id;
  -- (M2c-7e-3) or a credit held because its label cites one of our transfers (exit (b))
  if t.id is null or t.direction <> 'credit' or coalesce(v_kind, '') not in ('client_transfer_in', 'label_reference')
     or v_held
     or not exists (select 1 from public.bank_account b where b.id = t.bank_account_id and b.purpose = 'client_funds'
                      and b.status = 'active') then
    return query select 'not_a_client_credit'::text, null::uuid;
    return;
  end if;
  if private.names_our_transfer(t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id)
     or private.names_our_lot(t.bank_account_id, t.payment_info_id) or coalesce(t.unsplit_ours, 0) > 0
     or coalesce(t.end_to_end_id ~ '^TOP[0-9A-F]{12}$', false)
     -- (M2c-7e-3, exit (b)) our reference in a label_reference line's label is ignored: the client quoting it
     or (v_kind <> 'label_reference' and coalesce(upper(t.remittance_text) ~ '(RMT|SWP|TOP)[0-9A-F]{12}', false)) then
    return query select 'our_reference'::text, null::uuid;
    return;
  end if;
  if exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
     or exists (select 1 from public.payment p where p.bank_transaction_id = t.id) then
    return query select 'line_booked'::text, null::uuid;
    return;
  end if;
  select array_agg(distinct a.client_organization_id) into v_clients
  from (select q.client_organization_id, q.confirmed_at from public.client_payout_account q
        where q.organization_id = t.organization_id and q.iban = t.counterparty_iban offset 0) a
  where a.confirmed_at is not null;
  -- (M2c-7e-3, exit (b)) a label_reference line: the client ops name — a client of the line's servicer (by its key),
  -- never another client than the one whose confirmed payout IBAN the line comes from; with none named, that IBAN's
  -- client when there is one (as for a client_transfer_in line), else client_required
  if v_kind = 'label_reference' then
    if p_client_organization_id is null then
      if coalesce(cardinality(v_clients), 0) = 0 then
        return query select 'client_required'::text, null::uuid;
      elsif cardinality(v_clients) > 1 then
        return query select 'ambiguous_client'::text, null::uuid;
      else
        return query select null::text, v_clients[1];
      end if;
    elsif not exists (select 1 from public.organization o
                      where o.id = p_client_organization_id and o.servicer_organization_id = t.organization_id) then
      return query select 'client_unknown'::text, null::uuid;
    elsif exists (select 1 from unnest(coalesce(v_clients, '{}')) c where c <> p_client_organization_id) then
      return query select 'client_mismatch'::text, null::uuid;
    else
      return query select null::text, p_client_organization_id;
    end if;
    return;
  end if;
  if coalesce(cardinality(v_clients), 0) = 0 then
    return query select 'not_a_client_credit'::text, null::uuid;
  elsif cardinality(v_clients) > 1 then
    return query select 'ambiguous_client'::text, null::uuid;
  -- (M2c-7e-3) a client named for a client_transfer_in line is its IBAN's client
  elsif p_client_organization_id is not null and p_client_organization_id <> v_clients[1] then
    return query select 'client_mismatch'::text, null::uuid;
  else
    return query select null::text, v_clients[1];
  end if;
end;
$$;


-- The one-argument form (M2c-7c-1's callers): no client named.
create or replace function private.client_line_facts(p_bank_transaction_id uuid)
returns table (refusal text, client_id uuid)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select f.refusal, f.client_id from private.client_line_facts(p_bank_transaction_id, null) f;
$$;


-- public.client_payment_line, redefined from 20261125090000_repayment_requests.sql (line 2154, 7c-2's; dropped and
-- created: a trailing p_client_organization_id, the client « Règlement du client » names on a label_reference line,
-- private.client_line_facts reads it; same settings, its grants restated below). Nothing else changes.
drop function public.client_payment_line(uuid, uuid[], uuid[]);
create function public.client_payment_line(p_bank_transaction_id uuid, p_documents uuid[] default null,
                                           p_recover_written_off uuid[] default null,
                                           p_client_organization_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  f record;
  v_name text;
  v_named jsonb;
  v_preview jsonb;
  v_docs jsonb;
  v_reqs jsonb;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select * into f from private.client_line_facts(t.id, p_client_organization_id);
  if f.client_id is not null then
    select o.legal_name into v_name from public.organization o where o.id = f.client_id;
    -- (review round 4) only an invoice issued on or before the line's day: the client cannot have designated one that
    -- did not exist (a later one is not the line's to settle: the default order skips it too)
    v_docs := private.client_payment_docs(f.client_id, t.currency, t.booking_date);
    select coalesce(jsonb_agg(x ->> 'id' order by x ->> 'number'), '[]') into v_named
    from jsonb_array_elements(v_docs) x
    where x ->> 'kind' = 'invoice' and (x ->> 'open_on')::boolean
      and position(upper(x ->> 'number') in upper(coalesce(t.remittance_text, ''))) > 0;
    -- (M2c-7c-2 review round 1, MONEY-2) then the advances of the client's repayment requests its label names, open on
    -- the line's day, in the requests' and the letters' order, each once
    v_reqs := private.label_requested_advances(t.organization_id, f.client_id, t.currency, t.remittance_text,
                                               t.booking_date);
    v_named := v_named || coalesce((
      select jsonb_agg(y.id order by y.k)
      from (select a.id, min(r.n * 1000 + a.n) as k
            from jsonb_array_elements(v_reqs) with ordinality r (v, n)
            cross join lateral jsonb_array_elements_text(r.v -> 'advance_ids') with ordinality a (id, n)
            where exists (select 1 from jsonb_array_elements(v_docs) x
                          where x ->> 'id' = a.id and x ->> 'kind' = 'advance' and (x ->> 'open_on')::boolean)
            group by a.id) y), '[]');
    v_preview := public.client_payment_preview(f.client_id, t.currency,
                                               (t.amount_minor / 100)::text || ',' || lpad((t.amount_minor % 100)::text, 2, '0'),
                                               p_documents, p_recover_written_off, t.booking_date);
  end if;
  return jsonb_build_object(
    'bank_transaction_id', t.id, 'client_id', f.client_id, 'client_name', v_name, 'currency', t.currency,
    'amount_minor', t.amount_minor::text, 'booking_date', t.booking_date, 'label', t.remittance_text,
    'named_documents', coalesce(v_named, '[]'), 'named_requests', coalesce(v_reqs, '[]'), 'refusal', f.refusal,
    'preview', v_preview);
end;
$$;


-- public.book_client_payment_line, redefined from 20261125090000_repayment_requests.sql (line 2216, 7c-2's; dropped and
-- created: a trailing p_client_organization_id; same settings, its grants restated below; the web caller updated).
-- M2c-7e-3 (plan §7.3 exit (b)): the client ops name, read by private.client_line_facts under the command's locks; in
-- the request (its hash) only when given, so that a key recorded before this slice replays as it was. Its
-- client_payment booking passes the booking guard's widened arm. Nothing else changes.
drop function public.book_client_payment_line(text, uuid, uuid[], uuid, uuid[], text, text);
create function public.book_client_payment_line(p_idempotency_key text, p_bank_transaction_id uuid,
                                                p_documents uuid[], p_designation_document_id uuid,
                                                p_recover_written_off uuid[], p_expected_open_text text,
                                                p_reason text, p_client_organization_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  f record;
  v_docs jsonb;
  v_free jsonb;
  v_rec jsonb;
  v_why record;
  v_rows jsonb;
  v_label jsonb;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'documents', p_documents,
                                  'designation_document_id', p_designation_document_id,
                                  'recover_written_off', p_recover_written_off, 'expected_open', p_expected_open_text,
                                  'reason', v_reason)
               -- (M2c-7e-3) the client ops name, only when given: a key recorded before this slice replays as it was
               || case when p_client_organization_id is not null
                       then jsonb_build_object('client_organization_id', p_client_organization_id) else '{}'::jsonb end;
  v_result := private.command_replay('book_client_payment_line', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'client payment refused: reason_required' using errcode = 'check_violation';
  end if;
  if p_expected_open_text is null or p_expected_open_text !~ '^[0-9]{1,16}$'
     or array_position(p_documents, null) is not null or array_position(p_recover_written_off, null) is not null
     or coalesce(cardinality(p_documents), 0) <> (select count(distinct x) from unnest(p_documents) x)
     or coalesce(cardinality(p_recover_written_off), 0) <> (select count(distinct x) from unnest(p_recover_written_off) x)
  then
    raise exception 'client payment refused: bad_request' using errcode = 'check_violation';
  end if;
  -- [critic] F7: the funds pass's order — the allocation lock, the line, then the remit lock; the facts re-read
  perform private.remittance_command_locks(t.organization_id, false);
  perform 1 from public.bank_transaction x where x.id = t.id for no key update;
  perform private.remittance_command_locks(t.organization_id, true);
  select * into f from private.client_line_facts(t.id, p_client_organization_id);
  if f.refusal is not null then
    raise exception 'client payment refused: %', f.refusal using errcode = 'check_violation';
  end if;
  v_docs := private.client_payment_docs(f.client_id, t.currency, t.booking_date);
  -- (M2c-7c-2 review round 1, MONEY-2) the client's repayment requests its label names
  v_label := private.label_requested_advances(t.organization_id, f.client_id, t.currency, t.remittance_text,
                                              t.booking_date);
  if coalesce(cardinality(p_recover_written_off), 0) > 0
     and (p_designation_document_id is null
          or not private.client_document_of(p_designation_document_id, f.client_id, 'payment_designation_evidence'))
     or coalesce(cardinality(p_documents), 0) > 0
        and (p_designation_document_id is null
             or not private.client_document_of(p_designation_document_id, f.client_id, 'payment_designation_evidence'))
        -- [critic] L16: a label naming each designated invoice by its number is the client's designation
        -- (M2c-7c-2 review round 1, MONEY-2) or an advance of a repayment request it names by its DRA-… number
        and exists (select 1 from unnest(p_documents) n (id)
                    where not exists (select 1 from jsonb_array_elements(v_docs) x
                                      where (x ->> 'id')::uuid = n.id and x ->> 'kind' = 'invoice'
                                        and position(upper(x ->> 'number') in upper(coalesce(t.remittance_text, ''))) > 0)
                      and not exists (select 1 from jsonb_array_elements(v_label) r
                                      cross join lateral jsonb_array_elements_text(r -> 'advance_ids') a (id)
                                      where a.id::uuid = n.id))
  then
    raise exception 'client payment refused: designation_evidence_required' using errcode = 'check_violation';
  end if;
  v_free := private.client_payment_free(v_docs);
  v_rec := private.client_payment_recoveries(f.client_id, t.currency, p_recover_written_off, t.booking_date);
  select * into v_why from private.client_payment_named_refusal(v_docs, p_documents, p_recover_written_off, v_rec);
  if v_why.code is not null then
    raise exception 'client payment refused: %', v_why.code using errcode = 'check_violation',
      detail = coalesce(v_why.detail, '');
  end if;
  if private.client_payment_considered(v_free, p_documents, v_rec) <> p_expected_open_text::bigint then
    raise exception 'client payment refused: open_changed' using errcode = 'check_violation';
  end if;
  v_rows := private.client_payment_rows(v_free, t.amount_minor, p_documents, v_rec,
                                        private.client_proceeding_stands(f.client_id, t.booking_date), t.booking_date);
  v_result := private.client_payment_post(
    'client_payment_dedicated', t.organization_id, f.client_id, t.currency, t.amount_minor, t.booking_date, v_rows,
    v_docs, 'cpayd:' || t.id, 'bank_transaction', t.id::text,
    'Règlement du client reçu sur le compte dédié (le ' || to_char(t.booking_date, 'DD/MM/YYYY') || ')',
    t.bank_account_id);
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, entry_id,
                                        amount_minor, method, reason, decided_by)
  values (t.id, 1, t.organization_id, t.bank_account_id, 'client_payment', (v_result ->> 'entry_id')::uuid,
          t.amount_minor, 'ops', v_reason, auth.uid());
  delete from public.bank_debit_review v where v.bank_transaction_id = t.id;
  perform private.ledger_check_now();
  set constraints public.bank_line_booking_complete immediate;
  set constraints public.bank_line_booking_complete deferred;
  perform private.command_record('book_client_payment_line', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


------------------------------------------------------------------------------------------
-- Exit (c): a debtor's payment (plan §7.3; [check 2] gap 1 (2))
------------------------------------------------------------------------------------------

-- public.release_own_credit, redefined from 20261117110000_transfer_line_pages.sql (line 3128; same signature and
-- settings, its grants restated below). M2c-7e-3 (plan §7.3 exit (c)): a credit held because its label cites one of our
-- transfers (label_reference, as read or released so) becomes a debtor's payment as an own or a client's credit does —
-- its release row, the payment (unmatched, for ops to assign) and its cash_in —, our reference in its label ignored
-- (its other our_reference refusals unchanged). Its payer ([check 2]): « Versement relayé par le client » with no IBAN
-- when the line's counterparty IBAN is a client's confirmed payout IBAN (by the servicer and the IBAN,
-- client_payout_account_iban_idx), else the line's own counterparty name and IBAN (as public.resolve_duplicate books a
-- released debtor credit), so a later refund goes to the payer; the result says « Paiement d'un débiteur citant notre
-- référence (vérifié par l'équipe) » (`note`, shown on « Traités »). Review round 1 (CC-1): `enable_seqscan = off`, as
-- private.client_line_facts and book_client_payment_line, which make the same payout-account read — under the
-- statistics the scale files leave (a servicer's and an IBAN's n_distinct 2, generic plans) the probe would scan
-- client_payout_account whole; keyed, it reads the line's IBAN's rows alone (test_label_reference_exit_reads_integration
-- bounds it). Nothing else changes.
create or replace function public.release_own_credit(p_idempotency_key text, p_bank_transaction_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('bank_transaction_id', p_bank_transaction_id,
                                        'reason', btrim(coalesce(p_reason, '')));
  v_result jsonb;
  v_kind text;
  v_held boolean;
  v_payment uuid;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('release_own_credit', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'own credit release refused: reason_required' using errcode = 'check_violation';
  end if;
  perform 1 from public.bank_account b where b.id = t.bank_account_id for share;
  perform 1 from public.bank_transaction x where x.id = t.id for no key update;
  -- the facts, read under the locks
  select coalesce(r.released_kind, t.kind), (t.kind = 'suspected_duplicate' and r.decision is distinct from 'released')
  into v_kind, v_held
  from (select 1) d
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id;
  -- (M2c-7e-3, exit (c)) or a credit held because its label cites one of our transfers
  if t.direction <> 'credit' or v_kind not in ('own_transfer_in', 'client_transfer_in', 'label_reference') or v_held then
    raise exception 'own credit release refused: not_own_credit' using errcode = 'check_violation';
  end if;
  -- review round 3 (M1): one of our own transfers coming back — a credit carrying our RMT/SWP id as its own or as the
  -- original it returns, or a line of one of our PmtInfIds without an end-to-end id — is never a debtor's payment (nor
  -- a top-up): it is booked from the statement as that transfer's return (automatically when the bank flags it as a
  -- return; otherwise by ops, M2c-6b-2's line booking). Released, a payout sent back by the client's bank would credit a
  -- debtor's file with money the debtor never paid, be charged commission and be remitted again.
  -- (review round 4: the predicate as private.names_our_transfer, shared with the import's classifier and the refusals of
  -- assign_payment, accept_suggestions, the match job and resolve_duplicate). Review round 7: (S3, verdict
  -- new:own-client-credit-naming-our-lot-relay-top-up) nor a credit naming one of our lots of its account
  -- (private.names_our_lot: a file of that account handed out) whatever its end-to-end id — our outgoing transfer
  -- coming back, never a debtor's money relayed by us or the client; (S2) nor a line of an entry kept unsplit holding a
  -- detail of ours (no parser writes one of these kinds: refused all the same)
  if private.names_our_transfer(t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id)
     or private.names_our_lot(t.bank_account_id, t.payment_info_id) or coalesce(t.unsplit_ours, 0) > 0 then
    raise exception 'own credit release refused: own_transfer_line' using errcode = 'check_violation',
      hint = private.own_transfer_line_hint('own_credit');
  end if;
  -- review round 4 (N2, older than the round: the page hides the action since M2c-1, the API did not refuse it): a
  -- credit carrying our TOP id is the servicer's own top-up, booked as « Approvisionnement par le compte propre » (the
  -- debit job when it matches the order, else ops), never a debtor's payment — relayed, the servicer's money would be
  -- assigned to a debtor's file and remitted, its TOP transfer left unbooked
  if coalesce(t.end_to_end_id ~ '^TOP[0-9A-F]{12}$', false) then
    raise exception 'own credit release refused: top_up_line' using errcode = 'check_violation',
      hint = 'Ce crédit porte la référence de l''un de nos approvisionnements (TOP…) : c''est l''argent du cabinet, '
             'jamais le paiement d''un débiteur. Il se comptabilise comme « Approvisionnement par le compte propre » : '
             'automatiquement quand il correspond à l''approvisionnement demandé, sinon par l''équipe.';
  end if;
  if exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id) then
    raise exception 'own credit release refused: already_linked' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
     or exists (select 1 from public.payment p where p.bank_transaction_id = t.id) then
    raise exception 'own credit release refused: already_booked' using errcode = 'check_violation';
  end if;
  insert into public.bank_own_credit_release (bank_transaction_id, organization_id, bank_account_id, reason, decided_by)
  values (t.id, t.organization_id, t.bank_account_id, v_reason, auth.uid());
  if v_kind = 'label_reference' then
    -- (M2c-7e-3, exit (c), [check 2]) its payer: a client relaying its debtor's payment from its confirmed payout IBAN
    -- (never that IBAN as the payer's: a refund goes to the IBAN ops give), else the line's own counterparty
    if t.counterparty_iban is not null
       and exists (select 1 from (select q.confirmed_at from public.client_payout_account q
                                  where q.organization_id = t.organization_id and q.iban = t.counterparty_iban
                                  offset 0) q
                   where q.confirmed_at is not null) then
      v_payment := private.book_credit_payment(t.id, 'other', 'Versement relayé par le client', null, 'no_match');
    else
      v_payment := private.book_credit_payment(t.id, 'other',
                                               coalesce(t.counterparty_name, t.ultimate_counterparty_name),
                                               t.counterparty_iban, 'no_match');
    end if;
  else
    v_payment := private.book_credit_payment(t.id, 'other',
                                             case v_kind when 'client_transfer_in' then 'Versement relayé par le client'
                                                         else 'Versement relayé par le cabinet' end, null, 'no_match');
  end if;
  delete from public.bank_debit_review v where v.bank_transaction_id = t.id;
  v_result := jsonb_build_object('payment_id', v_payment, 'status', 'unmatched')
              || case when v_kind = 'label_reference'
                      then jsonb_build_object('note', 'Paiement d''un débiteur citant notre référence (vérifié par '
                                                      'l''équipe)')
                      else '{}'::jsonb end;
  perform private.command_record('release_own_credit', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


-- private.bank_own_credit_release_guard, redefined from 20261111120000_identities_terms.sql (line 2497; same settings,
-- its trigger unchanged, its grants restated below). M2c-7e-3 ([check 2] gap 1 (2)): its kind lists — as read, and a
-- held duplicate released so — gain label_reference (exit (c)). Nothing else changes.
create or replace function private.bank_own_credit_release_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare v_bad text;
begin
  select min(n.bank_transaction_id::text) into v_bad
  from new_rows n
  left join lateral (select q.organization_id, q.bank_account_id, q.direction, q.kind from public.bank_transaction q
                     where q.id = n.bank_transaction_id offset 0) t on true
  left join lateral (select q.decision, q.released_kind from public.bank_duplicate_resolution q
                     where q.bank_transaction_id = n.bank_transaction_id offset 0) r on true
  where t.organization_id is distinct from n.organization_id or t.bank_account_id is distinct from n.bank_account_id
     or t.direction <> 'credit'
     or not coalesce(t.kind in ('own_transfer_in', 'client_transfer_in', 'label_reference')
                     or (t.kind = 'suspected_duplicate' and r.decision = 'released'
                         and r.released_kind in ('own_transfer_in', 'client_transfer_in', 'label_reference')), false)
     or exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = n.bank_transaction_id offset 0)
     or exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = n.bank_transaction_id offset 0);
  if v_bad is not null then
    raise exception 'own credit release %: not a credit from our own account or a client''s of its bank account, '
                    'or already booked or linked', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;


-- private.payment_insert_guard, redefined from 20261111120000_identities_terms.sql (line 2591; same settings, its
-- trigger unchanged, its grants restated below). M2c-7e-3 ([check 2] gap 1 (2)): a payment of a label_reference line
-- only with its release row (exit (c)) — the release branch's kind list gains it; the import's own payment step never
-- makes one (its kinds unchanged). Nothing else changes.
create or replace function private.payment_insert_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(n.id::text) into v_bad
  from new_rows n
  join public.bank_transaction t on t.id = n.bank_transaction_id
  join public.bank_statement s on s.id = t.statement_id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
  where t.direction <> 'credit' or s.format <> n.channel
     or not (t.kind in ('debtor_credit', 'batch_unsplit')
             or (t.kind = 'suspected_duplicate' and coalesce(r.decision = 'released'
                                                              and r.released_kind in ('debtor_credit', 'batch_unsplit'),
                                                              false))
             -- (M2c-7e-3, exit (c)) a label_reference line too, with its release row
             or (coalesce(r.released_kind, t.kind) in ('own_transfer_in', 'client_transfer_in', 'label_reference')
                 and exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id
                             offset 0)));
  if v_bad is not null then
    raise exception 'payment %: its bank line is not a debtor credit of a statement in this channel', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;


------------------------------------------------------------------------------------------
-- The fourth exit: our own top-up's credit with no counterparty IBAN (founder Q15's added question, default a)
------------------------------------------------------------------------------------------

-- public.book_top_up_credit, redefined from 20261129090000_top_ups.sql (line 945, 7e-1's; same signature and settings,
-- its grants restated below). M2c-7e-3 (ADR-0014 « M2c-7e-2 » review round 1, MB-3; plan §7.3): on a CSV export with
-- no counterparty IBAN column our own top-up's credit, the bank printing our motif with the TOP id in its label, is held
-- label_reference (nothing says it comes from the own account). « C'est cet approvisionnement » books it as that top-up:
-- a label_reference line (as read or released so) whose statement gives no counterparty IBAN (with one it is not the
-- own account's — a registered own IBAN would have read it own_transfer_in: not_an_own_credit), naming the TOP its
-- label cites (its kept candidate; another TOP: label_reference_transfer), open (ordered, or in_file of an own-account
-- file: top_up_not_open), at exactly its amount and currency, ordered to the line's account (amount_differs). The
-- own-account rule (not_its_own_account) reads a counterparty IBAN, which this line does not give. Then one
-- `_bank_booking` row (kind top_up, that transfer) through private.post_bank_bookings(org, true), whose re-check admits
-- it on the same facts. Nothing else changes.
create or replace function public.book_top_up_credit(p_idempotency_key text, p_bank_transaction_id uuid,
                                                     p_transfer_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  x public.bank_transfer;
  v_kind text;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_out jsonb;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'transfer_id', p_transfer_id,
                                  'reason', v_reason);
  v_result := private.command_replay('book_top_up_credit', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  select coalesce((select r.released_kind from public.bank_duplicate_resolution r
                   where r.bank_transaction_id = t.id and r.decision = 'released'), t.kind) into v_kind;
  -- (M2c-7e-3, the fourth exit) or a credit held because its label cites our top-up, its statement giving no
  -- counterparty IBAN
  if t.direction <> 'credit' or v_kind not in ('own_transfer_in', 'label_reference')
     or (v_kind = 'label_reference' and t.counterparty_iban is not null) then
    raise exception 'top-up credit refused: not_an_own_credit' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id) then
    raise exception 'top-up credit refused: line_booked' using errcode = 'check_violation';
  end if;
  if coalesce(t.end_to_end_id ~ '^TOP[0-9A-F]{12}$', false) then
    raise exception 'top-up credit refused: carries_top_up_id' using errcode = 'check_violation';
  end if;
  select * into x from public.bank_transfer where id = p_transfer_id;
  if not found or x.organization_id <> t.organization_id or x.kind <> 'top_up'
     or not (x.status = 'ordered' or (x.status = 'in_file' and private.top_up_in_own_file(x.id))) then
    raise exception 'top-up credit refused: top_up_not_open' using errcode = 'check_violation';
  end if;
  -- (M2c-7e-3, the fourth exit) on a label_reference line, only the top-up its label cites (its kept candidate)
  if v_kind = 'label_reference' and x.end_to_end_id is distinct from t.reference_from_label then
    raise exception 'top-up credit refused: label_reference_transfer' using errcode = 'check_violation';
  end if;
  if x.amount_minor <> t.amount_minor or x.currency <> t.currency or x.creditor_bank_account_id <> t.bank_account_id then
    raise exception 'top-up credit refused: amount_differs' using errcode = 'check_violation';
  end if;
  -- review round 1 (MONEY-BANK-1): the credit came from the own account the top-up is ordered from (its IBAN the line's
  -- counterparty's) — a credit of own account A booked as the top-up of own account B would post −5122[B] and close
  -- B's top-up although B never paid it (the re-check refuses it too)
  -- (M2c-7e-3) a label_reference line gives no counterparty IBAN (above): the TOP its label cites is the proof
  if v_kind <> 'label_reference'
     and not exists (select 1 from public.bank_account a where a.id = x.debtor_bank_account_id
                       and a.iban = t.counterparty_iban) then
    raise exception 'top-up credit refused: not_its_own_account' using errcode = 'check_violation';
  end if;
  perform private.bank_booking_begin();
  insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method, decided_by, reason)
  values (1, t.id, 'top_up', x.id, 'ops', auth.uid(), v_reason);
  v_out := private.post_bank_bookings(t.organization_id, true);
  v_result := jsonb_build_object('status', 'booked', 'kind', 'top_up', 'result', v_out);
  perform private.command_record('book_top_up_credit', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


-- private.bank_booking_recheck, redefined from 20261129090000_top_ups.sql (line 1470, 7e-1's; same signature and
-- settings, its grants restated below). M2c-7e-3 (the fourth exit): its top-up rule admits, from ops (method ops: the
-- debit job reviews such a line and never proposes it — payments/debits.py decide_line, unchanged, its twin), a credit
-- held because its label cites the top-up the row names (label_reference; the line's reference_from_label its
-- end-to-end id), its statement giving no counterparty IBAN — the own-account rule (not_its_own_account) then reads
-- none; every other rule unchanged (open, amount, currency, creditor). The line's reference_from_label is read by its
-- key in that rule only: pg_temp._bb keeps its columns (private.transfer_line_bb builds the same table, 037 pins the
-- two alike). Nothing else changes.
create or replace function private.bank_booking_recheck(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
begin
  -- The keys first (what a transfer pays, its file history and its run never change): the transfers the rows name and
  -- every member of the PmtInf a batch line names — read once per LINE (review round 3, M3: once per row of the line,
  -- a batch line of N members read its PmtInf's N items N times, N² rows sorted for the distinct: 16 million rows and
  -- 766 MB of temporary files at 2,000 members).
  drop table if exists pg_temp._bb_keys;
  create temp table _bb_keys on commit drop as
  select distinct k.transfer_id, x.run_id, x.debtor_bank_account_id, x.creditor_bank_account_id
  from (select b.transfer_id from pg_temp._bank_booking b where b.transfer_id is not null
        union
        select i.transfer_id
        from (select distinct b.bank_transaction_id from pg_temp._bank_booking b where b.kind in ('payout', 'sweep')) l
        cross join lateral (select q.direction, q.end_to_end_id, q.payment_info_id from public.bank_transaction q
                            where q.id = l.bank_transaction_id offset 0) t
        cross join lateral (select y.transfer_id from public.transfer_file_item y
                            where y.pmt_inf_id = t.payment_info_id offset 0) i
        where t.direction = 'debit' and t.end_to_end_id is null and t.payment_info_id is not null) k
  cross join lateral (select q.run_id, q.debtor_bank_account_id, q.creditor_bank_account_id from public.bank_transfer q
                      where q.id = k.transfer_id offset 0) x;

  drop table if exists pg_temp._bb_cover;
  create temp table _bb_cover (ord integer) on commit drop;   -- (the advances posted: bank_booking_post_rows)

  perform 1 from public.remittance_run r
  where r.id = any (array(select k.run_id from pg_temp._bb_keys k where k.run_id is not null))
  order by r.id for update;
  perform 1 from public.client_payout_account a
  where a.id = any (array(select r.payout_account_id from public.remittance_run r
                          where r.id = any (array(select k.run_id from pg_temp._bb_keys k
                                                  join pg_temp._bank_booking b on b.transfer_id = k.transfer_id
                                                  where b.kind = 'payout_returned' and k.run_id is not null))
                            and r.payout_account_id is not null))
  order by a.id for no key update;
  perform 1 from public.bank_account a
  where a.id = any (array(
          select t.bank_account_id from pg_temp._bank_booking b
          cross join lateral (select q.bank_account_id from public.bank_transaction q
                              where q.id = b.bank_transaction_id offset 0) t
          union
          select k.debtor_bank_account_id from pg_temp._bb_keys k
          union
          select k.creditor_bank_account_id from pg_temp._bb_keys k where k.creditor_bank_account_id is not null))
  order by a.id for share;
  drop table if exists pg_temp._bb_pay_locks;
  create temp table _bb_pay_locks on commit drop as
  select distinct y.payment_id
  from pg_temp._bank_booking b
  join pg_temp._bb_keys k on k.transfer_id = b.transfer_id
  cross join lateral (select q.booking_date from public.bank_transaction q where q.id = b.bank_transaction_id offset 0) t
  cross join lateral (select x.payment_id from public.remittance_line x
                      where x.run_id = k.run_id and x.amount_minor > 0 and not x.released and x.payment_id is not null
                        and x.latest_execution_date < t.booking_date offset 0) y
  where b.kind = 'payout' and k.run_id is not null;
  perform 1 from public.payment p
  where p.id = any (array(select l.payment_id from pg_temp._bb_pay_locks l))
  order by p.id for key share;
  -- M2c-6b-2b (review CSR-1): a sweep's return too — every row whose posting reverses an entry (private.ledger_reverse
  -- always takes `payments:`) takes it here, before the lines and `remit:`, the order every other writer takes them
  if exists (select 1 from pg_temp._bank_booking b
             where b.kind in ('payout', 'payout_returned', 'sweep_returned', 'unplanned_payout')) then
    perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  end if;
  perform 1 from public.bank_transaction t
  where t.id = any (array(select b.bank_transaction_id from pg_temp._bank_booking b))
  order by t.id for no key update;
  if exists (select 1 from pg_temp._bank_booking) then
    perform pg_advisory_xact_lock(hashtext('remit:' || p_organization_id::text));
  end if;
  perform 1 from public.transfer_file f
  where f.id = any (array(select q.transfer_file_id from pg_temp._bb_keys k
                          cross join lateral (select y.transfer_file_id from public.bank_transfer y
                                              where y.id = k.transfer_id offset 0) q
                          where q.transfer_file_id is not null))
  order by f.id for share;
  perform 1 from public.bank_transfer x
  where x.id = any (array(select k.transfer_id from pg_temp._bb_keys k))
  order by x.id for update;

  -- The facts, read under the locks (one keyed lookup per row: laterals holding only the key).
  drop table if exists pg_temp._bb;
  create temp table _bb on commit drop as
  select b.*, t.organization_id as line_org, t.bank_account_id as line_bank, t.direction, t.currency,
         t.amount_minor as line_minor, t.booking_date as line_date, coalesce(dr.released_kind, t.kind) as line_kind,
         (t.kind = 'suspected_duplicate' and dr.decision is distinct from 'released') as held,
         t.counterparty_iban, t.end_to_end_id, coalesce(t.original_end_to_end_id, t.end_to_end_id) as returned_id,
         t.payment_info_id, t.unsplit_ours,
         (t.direction = 'debit' and t.end_to_end_id is null and t.payment_info_id is not null) as batch_line,
         -- booked in the funds, or an own credit released as a relayed debtor payment (booked by its cash_in)
         (exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = b.bank_transaction_id offset 0)
          or exists (select 1 from public.bank_own_credit_release c
                     where c.bank_transaction_id = b.bank_transaction_id offset 0)) as booked,
         (select l.kind from public.bank_debit_link l where l.bank_transaction_id = b.bank_transaction_id) as link_kind,
         coalesce((select -sum(p.amount_minor) from public.bank_debit_link l
                   join public.ledger_posting p on p.entry_id = l.cash_entry_id
                   where l.bank_transaction_id = b.bank_transaction_id and l.kind = 'return'
                     and (select la.book from public.ledger_account la where la.id = p.ledger_account_id)
                         = 'client_money_cash'), 0)::bigint as linked_minor,
         x.organization_id as tr_org, x.kind as tr_kind, x.status as tr_status, x.creditor_bank_account_id as tr_creditor,
         x.debtor_bank_account_id as tr_debtor, x.amount_minor as tr_minor, x.currency as tr_currency,
         x.end_to_end_id as tr_e2e, x.transfer_file_id as tr_file, x.run_id as tr_run,
         x.client_organization_id as tr_client, x.entry_id as tr_entry,
         f.status as file_status, f.download_count as file_downloads,
         (select i.pmt_inf_id from public.transfer_file_item i
          where i.file_id = x.transfer_file_id and i.transfer_id = x.id) as tr_pmt_inf,
         exists (select 1 from public.bank_line_booking k where k.transfer_id = b.transfer_id
                   and k.kind in ('payout', 'sweep', 'top_up') offset 0) as tr_debit_booked,
         exists (select 1 from public.bank_line_booking k where k.transfer_id = b.transfer_id
                   and k.kind in ('payout_returned', 'sweep_returned') offset 0) as tr_return_booked,
         -- M2c-6b-2a (plan §2.3; critic F1, L5; critic2 ML-3): for a return of a transfer of this servicer, an unplanned
         -- booking of it whose entry is not reversed, and a debit line of it on a statement not booked beyond its booked
         -- debit (each by key)
         case when b.kind in ('payout_returned', 'sweep_returned') and x.organization_id = p_organization_id
              then private.transfer_unplanned_open(b.transfer_id) end as tr_unplanned_open,
         case when b.kind in ('payout_returned', 'sweep_returned') and x.organization_id = p_organization_id
              then exists (select 1 from private.transfer_late_lines(b.transfer_id)) end as tr_debit_pending,
         (select e.effective_date from public.ledger_entry e where e.id = x.entry_id) as tr_entry_date,
         ru.status as run_status, ru.transfer_id as run_transfer, ru.payout_account_id as run_payout_account,
         null::uuid as own_bank, null::bigint as book_minor, null::text as why
  from pg_temp._bank_booking b
  left join lateral (select q.organization_id, q.bank_account_id, q.direction, q.currency, q.amount_minor,
                            q.booking_date, q.kind, q.counterparty_iban, q.end_to_end_id, q.original_end_to_end_id,
                            q.payment_info_id, q.unsplit_ours
                     from public.bank_transaction q where q.id = b.bank_transaction_id offset 0) t on true
  left join lateral (select q.decision, q.released_kind from public.bank_duplicate_resolution q
                     where q.bank_transaction_id = b.bank_transaction_id offset 0) dr on true
  left join lateral (select q.organization_id, q.kind, q.status, q.creditor_bank_account_id, q.debtor_bank_account_id,
                            q.amount_minor, q.currency, q.end_to_end_id, q.transfer_file_id, q.run_id,
                            q.client_organization_id, q.entry_id, q.id
                     from public.bank_transfer q where q.id = b.transfer_id offset 0) x on true
  left join lateral (select q.status, q.download_count from public.transfer_file q where q.id = x.transfer_file_id
                     offset 0) f on true
  left join lateral (select q.status, q.transfer_id, q.payout_account_id from public.remittance_run q
                     where q.id = x.run_id offset 0) ru on true;
  -- review round 3 (M3): its size known to the planner (a temporary table is never analysed by autovacuum: unanalysed,
  -- the rules' joins of _bb to itself were planned as nested loops over every pair of a batch line's rows)
  analyze pg_temp._bb;
  -- a top-up's own account: its transfer's, or (ops, no transfer) the registered own account the credit came from
  update pg_temp._bb b set own_bank = coalesce(b.tr_debtor, (
    select o.id from public.bank_account o
    where o.organization_id = b.line_org and o.purpose = 'own' and o.status = 'active' and o.iban = b.counterparty_iban
      and o.currency = b.currency))
  where b.kind = 'top_up';
  update pg_temp._bb b set book_minor = case when b.kind = 'loss' then b.amount_minor
                                             when b.kind in ('payout', 'sweep', 'payout_returned', 'sweep_returned')
                                               then b.tr_minor
                                             else b.line_minor end
  where b.bank_transaction_id is not null;

  update pg_temp._bb b set why = case
    when b.line_org is distinct from p_organization_id then 'line_unknown'
    when b.held then 'held_duplicate'
    when b.booked then 'already_booked'
    when b.method = 'ops' and nullif(btrim(b.reason), '') is null then 'reason_required'
    when b.kind = 'fee' then case
      when b.link_kind is not null then 'already_linked'
      -- an other debit only: our own transfers out are booked as sweeps and payouts or left to ops, never as fees
      -- (M2c-1 review: a withdrawal to the own account read as a bank fee); M2c-6b-1: nor a line carrying our RMT/SWP
      -- id or one of our PmtInfIds (plan §2.2)
      when b.direction <> 'debit' or b.line_kind <> 'other_debit' then 'not_a_fee'
      -- (review round 3, M2: its OWN id only, never the original it names — a bank charge naming our payout or sweep,
      -- e.g. the payee's bank's charge on a payout it sent back, is a charge on our account, the servicer's cost, booked
      -- as a fee as the job books every coded charge (CHRG/FEES) whatever its original id; ADR-0014)
      when b.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$'
           or (b.batch_line and b.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$') then 'not_a_fee'
      when b.transfer_id is not null or b.amount_minor is not null then 'bad_request' end
    when b.kind = 'top_up' then case
      -- review round 3 (M2, round 2's L4): never one of our payouts' or sweeps' lines — a credit carrying our RMT/SWP
      -- id as its own or as the original it returns (a sweep back from the own IBAN that the feed did not flag as a
      -- return: a CSV label missing RETURN_RE reads it own_transfer_in), as the loss rule below; such a credit is
      -- booked from the statement as that transfer's return (sweep_returned), never as a top-up. Nor (integration of
      -- round 3, as public.release_own_credit reads a credit) a line naming one of our PmtInfIds without an end-to-end
      -- id, whatever its direction: our batch line, or a lot of one of our files coming back as one credit (a top-up is
      -- never in a file of the dedicated account: an own-account top-up file's lots are the own account's — M2c-7e-1)
      -- Review round 7: (S3, verdict new:own-client-credit-naming-our-lot-relay-top-up) nor a credit naming one of our
      -- lots of its account (private.names_our_lot: a file of that account handed out) whatever its end-to-end id — our
      -- outgoing transfer coming back (a top-up is never in a file of this dedicated account: its lot would be a file of
      -- the own account); (S2) nor a line of an entry kept unsplit holding a detail of ours
      when coalesce(b.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or coalesce(b.returned_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or (b.end_to_end_id is null and coalesce(b.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$', false))
           or coalesce(b.unsplit_ours, 0) > 0
           or (b.direction = 'credit' and private.names_our_lot(b.line_bank, b.payment_info_id))
        then 'own_transfer_line'
      when b.link_kind is not null then 'already_linked'
      -- (M2c-7e-3, the fourth exit; ops only) or a credit held because its label cites the top-up the row names
      -- (the line's candidate by its key: pg_temp._bb keeps its columns, the transfer line's own build of it alike),
      -- its statement giving no counterparty IBAN
      when b.direction <> 'credit'
           or not (b.line_kind = 'own_transfer_in'
                   or (b.line_kind = 'label_reference' and b.method = 'ops' and b.counterparty_iban is null
                       and b.transfer_id is not null
                       and (select q.reference_from_label from public.bank_transaction q
                            where q.id = b.bank_transaction_id) is not distinct from b.tr_e2e))
        then 'not_an_own_credit'
      when b.amount_minor is not null then 'bad_request'
      when b.transfer_id is not null and (b.tr_org is distinct from p_organization_id or b.tr_kind <> 'top_up'
                                          or b.tr_creditor is distinct from b.line_bank) then 'transfer_unknown'
      -- M2c-7e-1 ([critic] M7-MONEY-4): a credit naming a cancelled top-up waits for ops (top_up_cancelled_credit:
      -- booked with no transfer, the servicer's own money); a top-up books from ordered, or in_file of an own-account
      -- file of this servicer (filing puts it in_file; its credit closes it: private.top_up_in_own_file)
      when b.transfer_id is not null and b.tr_status = 'cancelled' then 'top_up_cancelled_credit'
      when b.transfer_id is not null and b.tr_status <> 'ordered'
           and not (b.tr_status = 'in_file' and private.top_up_in_own_file(b.transfer_id)) then 'transfer_not_pending'
      when b.transfer_id is not null and (b.tr_minor <> b.line_minor or b.tr_currency <> b.currency) then 'amount_differs'
      -- M2c-7e-1 review round 1 (MONEY-BANK-1): a top-up picked for a credit that does not carry its TOP id
      -- (« Rattacher à TOP… ») is one ordered from the own account the credit came from (its IBAN the line's
      -- counterparty's); a credit carrying the id is its top-up whatever account sent it (the job's rule, unchanged)
      when b.transfer_id is not null and b.end_to_end_id is distinct from b.tr_e2e
           -- (M2c-7e-3) a label_reference line gives no IBAN: the TOP its label cites is the proof (above)
           and b.line_kind <> 'label_reference'
           and not exists (select 1 from public.bank_account o where o.id = b.tr_debtor
                             and o.iban = b.counterparty_iban)
        then 'not_its_own_account'
      when b.own_bank is null then 'own_account_unknown' end
    when b.kind = 'loss' then case
      -- review round 2 (L4, money-1's defence in depth): never one of our payouts' or sweeps' lines — a line carrying our
      -- RMT/SWP id as its own or as the original it returns, or a batch line of one of our PmtInfIds — whatever kind the
      -- statement gives it: as for every other link (private.post_debit_links), such a line is only booked
      -- (review round 7, S2: or a line of an entry kept unsplit holding a detail of ours, whose ids are not on its line)
      when coalesce(b.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or coalesce(b.returned_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or (b.batch_line and b.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
           or coalesce(b.unsplit_ours, 0) > 0 then 'own_transfer_line'
      when b.direction <> 'debit' or b.line_kind <> 'return' then 'not_a_return'
      when b.link_kind is not null and b.link_kind <> 'return' then 'already_linked'
      when b.transfer_id is not null or b.amount_minor is null or b.amount_minor <= 0 then 'bad_request'
      when b.amount_minor + b.linked_minor <> b.line_minor then 'amount_differs' end
    when b.kind in ('payout', 'sweep') then case
      when b.amount_minor is not null or b.client_organization_id is not null then 'bad_request'
      when b.link_kind is not null then 'already_linked'
      when b.direction <> 'debit' or b.line_kind not in ('transfer_out', 'other_debit', 'batch_unsplit')
        then 'not_a_transfer_line'
      when b.transfer_id is null or b.tr_org is distinct from p_organization_id or b.tr_kind is distinct from b.kind
        then 'transfer_unknown'
      -- own id first (plan §2.4 rule 1): a line carrying an end-to-end id is that id's transfer only — a re-issue is
      -- never booked by its predecessor's id; a batch line names the transfer's PmtInf in its current file (rule 2)
      when not coalesce(b.end_to_end_id = b.tr_e2e or (b.batch_line and b.payment_info_id = b.tr_pmt_inf), false)
        then 'not_its_line'
      when b.tr_status = 'cancelled' then 'cancelled_transfer_debited'
      when b.tr_status in ('booked', 'returned') or b.tr_debit_booked then 'transfer_debited_twice'
      when b.tr_status <> 'in_file' or coalesce(b.file_downloads, 0) = 0
           or b.file_status not in ('downloaded', 'sent') then 'transfer_not_handed_out'
      when b.tr_debtor is distinct from b.line_bank or b.tr_currency is distinct from b.currency then 'transfer_differs'
      when not b.batch_line and b.tr_minor <> b.line_minor then 'transfer_differs'
      when b.kind = 'payout' and (b.run_status is null or b.run_status not in ('approved', 'sent')
                                  or b.run_transfer is distinct from b.transfer_id) then 'run_not_in_flight'
      -- review round 7 (S2, verdict new:debit-entry-unsplit-with-our-details-explainable): never from an entry the bank
      -- kept unsplit holding a detail of ours — by the id its one detail gives (one shown of several: the entry's total)
      -- nor as a batch line whose details are given but do not add up (payments.debits; COMPLIANCE OQ-84 (h)); a batch
      -- line the bank sent with no details (a count of 0) keeps the batch rule
      when coalesce(b.unsplit_ours, 0) > 0 or (not b.batch_line and b.unsplit_ours is not null) then 'batch_partial' end
    when b.kind in ('payout_returned', 'sweep_returned') then case
      when b.amount_minor is not null or b.client_organization_id is not null then 'bad_request'
      when b.link_kind is not null then 'already_linked'
      when b.direction <> 'credit' or b.line_kind <> 'return' then 'not_a_return'
      when b.transfer_id is null or b.tr_org is distinct from p_organization_id
           or b.tr_kind is distinct from case b.kind when 'payout_returned' then 'payout' else 'sweep' end
        then 'transfer_unknown'
      when b.returned_id is distinct from b.tr_e2e then 'not_its_line'
      when b.tr_status in ('ordered', 'in_file') then 'return_before_debit'
      -- M2c-6b-2a (critic F1, L5): a copy coming back of a transfer that has an open unplanned booking (a booked or
      -- returned transfer executed again, a cancelled one executed late) is that unplanned payout's return, booked by ops
      -- (6b-2b): booked here as the planned payout's, it would pay the client again
      when b.tr_unplanned_open then 'unplanned_payout_return'
      -- (critic2 ML-3) a second or late debit of it on a statement, not booked yet: that debit is booked first
      when b.tr_debit_pending then 'return_debit_pending'
      when b.tr_status = 'returned' or b.tr_return_booked then 'already_returned'
      when b.tr_status <> 'booked' or not b.tr_debit_booked or b.tr_entry is null then 'return_differs'
      when b.tr_debtor is distinct from b.line_bank or b.tr_currency is distinct from b.currency then 'transfer_differs'
      when b.line_minor > b.tr_minor then 'return_differs'
      -- review round 6 (R1, a regression of round 5): a line read from a camt.053 entry kept unsplit carries the
      -- entry's total, not this transfer's return — less than the transfer is never its return with the rest as the
      -- bank's charge (the round-5 verifier's netted entry: our payout's return beside another payout's debit booked
      -- that debit as our bank fee; or a chargeback), nor any amount with several details of ours (the first one's id
      -- only what the refusals read). Review round 7 (S1, verdict new:unsplit-exact-total-other-details): nor with one
      -- detail of ours for the transfer's exact amount — the entry's other details (a debtor's credit, netting debits),
      -- a detail of ours short of the entry or shown alone of several, are not ours to read: never booked
      -- (payments.debits). A detail of ours that is the whole entry is a line of its own (payments.camt053)
      when b.unsplit_ours is not null then 'return_differs'
      when b.line_date < b.tr_entry_date then 'return_before_debit' end
    -- the unplanned kinds are ops' (M2c-6b-2: public.book_transfer_line)
    else 'bad_request'
  end
  where b.bank_transaction_id is not null;  -- (every row: PostgREST sessions refuse an UPDATE without WHERE)

  -- A line is one kind of booking (the job's): a payout, sweep or return line holds nothing else. Review round 3 (M3):
  -- per line, aggregated once (two kinds or more, one of them ours) — the same lines as « another row of the line of
  -- another kind, one of the two ours », which, as a correlated EXISTS, hashed a batch line's N rows into one bucket
  -- and compared every pair (25 million join-filter rows at 5,000 members).
  update pg_temp._bb b set why = 'bad_request'
  from (select o.bank_transaction_id from pg_temp._bb o
        group by o.bank_transaction_id
        having count(distinct o.kind) > 1
           and bool_or(o.kind in ('payout', 'sweep', 'payout_returned', 'sweep_returned'))) k
  where b.why is null and b.bank_transaction_id = k.bank_transaction_id;
  -- A batch line (plan §2.3 row 3, §2.4 rule 2): booked only for exactly the in_file members of the PmtInf it names, in
  -- its file of the line's account (the members that file holds), none cancelled (but returned), of one kind, adding up
  -- to the line — never a « best subset ». The members are read under their locks.
  -- Linear whatever the line's size (review round 2, P1): each step is MATERIALIZED, so it runs once — the lines, the
  -- rows each line holds, the members of each line's PmtInf by keyed laterals (each item, file and transfer read
  -- once), then the verdict per line. (As one grouped subquery joined to the rows, the planner re-ran it once per row
  -- of the line: 150 members read 23,250 items and ~25,000 transfers.) Review round 3 (M3): the members aggregated per
  -- line first (a), then compared with the line's rows (w) — never an array growing with the line in a sort or group
  -- key (grouped by the array of the line's N transfer ids, each of the N joined rows carried it into the sort: N² bytes,
  -- 392 MB of temporary files at 5,000 members).
  with l as materialized (
    select distinct o.bank_transaction_id, o.line_bank, o.payment_info_id, o.line_minor from pg_temp._bb o
    where o.batch_line and o.kind in ('payout', 'sweep') and o.why is null),
  r as materialized (   -- every row the line holds (the job's, whatever their verdict)
    select o.bank_transaction_id, array_agg(o.transfer_id order by o.transfer_id) as ids
    from pg_temp._bb o
    where o.bank_transaction_id in (select l.bank_transaction_id from l)
    group by o.bank_transaction_id),
  m as materialized (
    select l.bank_transaction_id, t.id, t.kind, t.status, t.amount_minor, fl.download_count, fl.status as file_status,
           case when t.status = 'cancelled' then private.transfer_return_seen(t.id) else false end as returned
    from l
    cross join lateral (select y.file_id, y.transfer_id from public.transfer_file_item y
                        where y.pmt_inf_id = l.payment_info_id offset 0) i
    cross join lateral (select q.debtor_bank_account_id, q.status, q.download_count from public.transfer_file q
                        where q.id = i.file_id offset 0) fl
    cross join lateral (select q.id, q.kind, q.status, q.amount_minor, q.transfer_file_id from public.bank_transfer q
                        where q.id = i.transfer_id offset 0) t
    where fl.debtor_bank_account_id = l.line_bank and t.transfer_file_id = i.file_id),
  a as materialized (   -- each line's members, aggregated once (grouped by the line's key only)
    select l.bank_transaction_id, l.line_minor, count(m.id) as members,
           bool_or(m.status = 'cancelled' and not m.returned) as cancelled_unreturned,
           bool_and(m.status = 'in_file' and (coalesce(m.download_count, 0) = 0
                                              or m.file_status not in ('downloaded', 'sent'))) as none_handed_out,
           count(m.id) filter (where m.status = 'in_file') as live,
           count(distinct m.kind) filter (where m.status = 'in_file') as live_kinds,
           bool_or(m.status = 'in_file' and m.kind = 'refund') as live_refund,
           coalesce(sum(m.amount_minor) filter (where m.status = 'in_file'), 0) as live_minor,
           array_agg(m.id order by m.id) filter (where m.status = 'in_file') as live_ids
    from l
    left join m on m.bank_transaction_id = l.bank_transaction_id
    group by l.bank_transaction_id, l.line_minor),
  w as materialized (   -- the verdict per line: one row of a, compared with the one row of r
    select a.bank_transaction_id,
           case
             when a.members = 0 then 'transfer_unknown'
             when a.cancelled_unreturned then 'cancelled_transfer_debited'
             when a.none_handed_out then 'transfer_not_handed_out'
             when a.live = 0 then 'transfer_debited_twice'
             when a.live_kinds > 1 or a.live_refund then 'batch_mixed'
             when a.live_minor <> a.line_minor then 'batch_partial'
             when a.live_ids is distinct from r.ids then 'batch_incomplete'
           end as why
    from a
    left join r on r.bank_transaction_id = a.bank_transaction_id)
  update pg_temp._bb b set why = w.why
  from w
  where b.bank_transaction_id = w.bank_transaction_id and b.why is null and w.why is not null;
  -- a transfer booked once per call (a later line waits: ops, or the next run): a row whose transfer an earlier row
  -- still accepted, of another line, books the same way (a debit, or a return). Review round 3 (M3): counted by a
  -- window over the accepted rows, by the transfer's key (as a correlated EXISTS over the unanalysed _bb, a nested loop
  -- compared every pair of a batch line's rows: 25 million at 5,000 members).
  update pg_temp._bb b set why = 'transfer_twice'
  from (select o.ord,
               count(*) over (partition by o.transfer_id, o.returns order by o.ord
                              rows between unbounded preceding and 1 preceding) as before_any,
               count(*) over (partition by o.transfer_id, o.returns, o.bank_transaction_id order by o.ord
                              rows between unbounded preceding and 1 preceding) as before_here
        from (select x.ord, x.transfer_id, x.bank_transaction_id,
                     x.kind in ('payout_returned', 'sweep_returned') as returns
              from pg_temp._bb x where x.why is null and x.transfer_id is not null) o) w
  where b.ord = w.ord and w.before_any > w.before_here and b.why is null;
  -- one refused row refuses its line (a line is booked whole)
  update pg_temp._bb b set why = w.why
  from (select distinct on (o.bank_transaction_id) o.bank_transaction_id, o.why from pg_temp._bb o
        where o.why is not null order by o.bank_transaction_id, o.ord) w
  where b.bank_transaction_id = w.bank_transaction_id and b.why is null;
end;
$$;


------------------------------------------------------------------------------------------
-- The ops command's posting (review round 2: the payout account's return by its key)
------------------------------------------------------------------------------------------

-- private.transfer_line_post, redefined from 20261123080000_cover_reads_by_run_key.sql (line 304; same signature,
-- SECURITY DEFINER, search_path '' and enable_seqscan off, its privileges restated below). ADR-0014 « M2c-7e-3 review
-- fixes » round 2: exit (a)'s return (and every return « Comptabiliser… » books) sets its run's payout account
-- 'returned'. The one statement over the parts' accounts (`a.id = any (array(…)) and a.status = 'active'`), with
-- client_payout_account analysed under the exits reads test's plant (n_distinct 2) and generic plans, was a BitmapAnd
-- of client_payout_account_pkey and client_payout_account_current_uq — a partial index (status active or returned) the
-- status filter implies, read whole: 95 then 323 rows, every servicer's active and returned accounts, per booking
-- (test_label_reference_exit_reads_integration's bound 62). Each account is now updated by its key alone, one
-- statement per distinct account (`a.id = v_pa`: one row estimated, the primary key whatever the statistics); the same
-- rows, the same status, the same triggers. Nothing else changes.
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
  v_pa uuid;
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
  -- (M2c-7e-3 review round 2) each payout account by its key alone: one statement for them all, its status filter
  -- implying client_payout_account_current_uq's predicate, was planned under stale statistics as a BitmapAnd of
  -- that partial index read whole (every servicer's active and returned accounts) and the key
  for v_pa in select distinct t.payout_account from pg_temp._tl t
              where t.payout_account is not null order by 1 loop
    update public.client_payout_account a set status = 'returned'
    where a.id = v_pa and a.status = 'active';
  end loop;

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
-- The bookings' posting (review round 2: the payout account's return by its key)
------------------------------------------------------------------------------------------

-- private.bank_booking_post_rows, redefined from 20261122090000_remitted_reversals_covered.sql (line 1789; same
-- signature, SECURITY DEFINER, search_path '' and enable_seqscan off, its privileges restated below). ADR-0014
-- « M2c-7e-3 review fixes » round 2: as private.transfer_line_post's (above), its update of the returned payouts'
-- accounts (`a.id = any (array(…)) … and a.status = 'active'`), with client_payout_account analysed under the exits
-- reads test's plant and generic plans, was a BitmapAnd of client_payout_account_pkey and the whole of
-- client_payout_account_current_uq — read on every call of private.post_bank_bookings (the fourth exit, « C'est cet
-- approvisionnement », read 305 rows with no payout returned among its parts; the debit job's funds pass the same).
-- Each account is now updated by its key alone, one statement per distinct account; the same rows, the same status,
-- the same triggers. Nothing else changes.
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
  v_pa uuid;
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

  -- (3b) M2c-7a (plan §3.2.12; design §13 #3 as built): the booked runs' lines reversed while the runs were in flight,
  -- covered first (each line's reversal, never a same-run pair); the overrun cover below then reads the balances
  -- after these covers and arises only for what no reversed line explains (LG008's backstop)
  if exists (select 1 from pg_temp._bb b where b.kind = 'payout') then
    perform private.cover_booked_run_reversals(
      array(select b.tr_run from pg_temp._bb b where b.kind = 'payout' order by b.ord),
      array(select b.line_date from pg_temp._bb b where b.kind = 'payout' order by b.ord),
      array(select b.transfer_id from pg_temp._bb b where b.kind = 'payout' order by b.ord),
      array(select b.bank_transaction_id from pg_temp._bb b where b.kind = 'payout' order by b.ord));
  end if;

  -- (4) the cover: what a booked payout left in debit on its client's 4670 (all its entries posted: the running
  -- balance), advanced by the servicer at the debit date
  drop table if exists pg_temp._bb_cover;
  create temp table _bb_cover on commit drop as
  select distinct on (b.tr_client, b.currency) b.ord, b.tr_client as client_organization_id, b.currency, b.transfer_id,
         b.bank_transaction_id, b.line_date, c.balance_minor as overrun, e.entry_id as cause_entry_id,
         gen_random_uuid() as advance_id,
         -- M2c-7a ([critic] F10): the single mandate of the run's lines (its primary key prefix), else none
         (select case when count(distinct q.mandate_id) = 1 and count(q.mandate_id) = count(*)
                      then (array_agg(q.mandate_id))[1] end
          from public.remittance_line q where q.run_id = b.tr_run) as mandate_id
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
    insert into public.client_advance (id, organization_id, client_organization_id, mandate_id, currency, amount_minor,
                                       cause, cause_entry_id, entry_id, bank_transaction_id, transfer_id)
    select c.advance_id, p_organization_id, c.client_organization_id, c.mandate_id, c.currency, c.overrun,
           'payout_overrun', c.cause_entry_id, x.entry_id, c.bank_transaction_id, c.transfer_id
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
  -- (M2c-7e-3 review round 2) each payout account by its key alone: one statement for them all, its status filter
  -- implying client_payout_account_current_uq's predicate, was planned under stale statistics as a BitmapAnd of
  -- that partial index read whole (every servicer's active and returned accounts) and the key — on every call, the
  -- partial index read even when no part is a payout's return
  for v_pa in select distinct x.run_payout_account from pg_temp._bb x
              where x.kind = 'payout_returned' and x.run_payout_account is not null order by 1 loop
    update public.client_payout_account a set status = 'returned'
    where a.id = v_pa and a.status = 'active';
  end loop;

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
-- Privileges (restated for every function redefined here)
------------------------------------------------------------------------------------------

-- the transfer line's class, pre-read, check and options' body: internal (20261117100000, 20261117113000,
-- 20261125090000, 20261118100000)
revoke execute on function private.transfer_line_class(uuid), private.transfer_line_pre(uuid),
  private.transfer_line_check(uuid, boolean), private.transfer_line_options_of(uuid)
  from public, anon, authenticated, service_role;
-- the guards (trigger functions) and the chain's events: internal (20261121090000, 20261111120000, 20261118100000)
revoke execute on function private.bank_line_booking_guard(), private.bank_own_credit_release_guard(),
  private.payment_insert_guard(), private.remittance_chain_events(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
-- the ops command's posting and the bookings' posting: internal (20261123080000, 20261122090000)
revoke execute on function private.transfer_line_post(uuid, text), private.bank_booking_post_rows(uuid)
  from public, anon, authenticated, service_role;
-- the client line's facts (both forms) and the re-check: internal (20261124090000, 20261129090000)
revoke execute on function private.client_line_facts(uuid), private.client_line_facts(uuid, uuid),
  private.bank_booking_recheck(uuid)
  from public, anon, authenticated, service_role;
-- the back office's reads and commands: authenticated (money staff at aal2, checked inside); never anon
-- (20261125090000, 20261117110000, 20261129090000)
revoke execute on function public.client_payment_line(uuid, uuid[], uuid[], uuid),
  public.book_client_payment_line(text, uuid, uuid[], uuid, uuid[], text, text, uuid),
  public.release_own_credit(text, uuid, text), public.book_top_up_credit(text, uuid, uuid, text)
  from public, anon;
grant execute on function public.client_payment_line(uuid, uuid[], uuid[], uuid),
  public.book_client_payment_line(text, uuid, uuid[], uuid, uuid[], text, text, uuid),
  public.release_own_credit(text, uuid, text), public.book_top_up_credit(text, uuid, uuid, text)
  to authenticated;
