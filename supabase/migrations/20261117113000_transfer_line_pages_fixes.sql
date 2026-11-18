-- M2c-6b-2d, what 6b-2c left (ADR-0014 « M2c-6b-2c review fixes », « Left open after round 3 »; « M2c-6b-2c
-- carry-overs (in 6b-2d) »): two of round 3's three low items, in SQL (the third is the page's text):
--   * refund-link-blocked-by-returned-payout-twin (COMPLIANCE OQ-86): « Lier »'s refund link on a debit without our
--     reference treats the line's other candidates as round 3 treats them for a payment's return — refused
--     payout_candidate only for another payout in flight (i), another refund in a file (ii), or a cancelled payout whose
--     run is still approved or sent (critic2 ML-4), never for a payout only returned, or cancelled with its run ended
--     (rule 3b's (iii), a candidate for good: refused, the refund's own debit could never be linked — the refund « en
--     cours » for good, the line unbooked); public.debit_link_options lists what the guard lets through, unchanged. This
--     fix WIDENS what « Lier » accepts — the one exception the rules allow: the item shows the link wrongly refused;
--   * suppression-e0-names-our-other-lot (COMPLIANCE OQ-83, CPCE-08): a debit with an end-to-end id that is not ours and
--     the TF PmtInfId of a lot of ours on its account (class E0) is, by that PmtInfId, a line of that lot: it no longer
--     holds back the breach row of an in-flight transfer of another lot (private.transfer_debit_suppression's
--     legal-deadlines-1 branch), and the check's pre-read (private.transfer_line_pre: the command, its preview and the
--     options) refuses it names_other_lot whenever rule 3b finds a transfer of ours outside the lot it names — so it is
--     never booked as such a transfer's debit, nor, while such a transfer may be it, as anything else. Rule 3b's
--     candidates themselves (private.transfer_line_candidates) are unchanged: they also give « Lier »'s refusals, the
--     queue's reason and the bank_line_unbooked alert, which keep what they had. Both changes only narrow what is
--     booked and what is suppressed.
-- The cancellation-after-download switch stays OFF; pgTAP 033 and 034 unchanged.
--
-- New: private.pmt_inf_names_account_lot. Redefined, each copied from its latest definition and changed only as its
-- comment says, with SECURITY DEFINER, every SET clause, search_path and its grants restated: private.transfer_line_pre
-- (20261117100000), private.transfer_debit_suppression and private.link_debit_guard (20261117110000).

-- Whether a PmtInfId of our files' form names a lot of a file of this bank account (transfer_file_item.pmt_inf_id;
-- plan §3.3's class B test, whatever the file's status: our PmtInfIds are unique per servicer, the account tells two
-- servicers' apart). Keyed: the items by their PmtInfId (transfer_file_item_pmt_inf_idx), each file by its key.
create or replace function private.pmt_inf_names_account_lot(p_bank_account_id uuid, p_pmt_inf_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(p_pmt_inf_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$', false) and exists (
    select 1
    from (select i.file_id from public.transfer_file_item i where i.pmt_inf_id = p_pmt_inf_id offset 0) i
    cross join lateral (select f.debtor_bank_account_id from public.transfer_file f where f.id = i.file_id offset 0) f
    where f.debtor_bank_account_id = p_bank_account_id);
$$;

-- What runs before the locks (§3.2 step 6; critic CSO-3, critic2 CSO2-3): for a lot (class B) or an entry kept
-- unsplit (class U), the keyed count of its items first (lot_too_large above the cap, before any other read of them),
-- then, for a lot, the only subset of its members whose amounts make the line (private.unique_subset, the PmtInf's
-- items in seq order: a debit lot's items never change; a lot credit's universe is read again under the locks and
-- must be the same, else split_changed); for a debit without our reference, rule 3b's candidates. pg_temp._tl_pre keeps
-- the members, the subset (in_subset) and the candidates for the check and the lock's key collection; pg_temp._tl_meta
-- the line's class, its member count and whether a subset was found. Returns lot_too_large or null. (CI scale fix:
-- enable_seqscan off, as every reader it calls: the keyed count of the PmtInf's items never becomes a scan of every
-- file's items when the statistics say a few PmtInfs hold them all.)
-- private.transfer_line_pre, redefined from 20261117100000 (same signature and settings; its grants restated below).
-- M2c-6b-2d (suppression-e0-names-our-other-lot): a debit of class E0 whose PmtInfId names a lot of ours on its account
-- (private.pmt_inf_names_account_lot) is refused names_other_lot when one of rule 3b's candidates is a transfer outside
-- that lot (its item in its current file under another PmtInfId: each by key) — the bank says the line is that lot's,
-- so it is never booked as another lot's transfer, nor as anything else while such a transfer may be it (the options
-- propose nothing; the command and its preview refuse). A line naming the lot of each of its candidates, or no lot of
-- ours, is unchanged. Nothing else changes.
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

-- What the lines that could still be this in-flight transfer's debit say of its R124-6 breach row as of p_today (the
-- nightly check's day): the lines 6b-1 counts (private.transfer_debit_may_be_seen, review legal-texts#2) — not booked
-- nor linked, booked from the transfer's requested execution date to p_to, carrying its end-to-end id, or naming its
-- PmtInf in its current file with no end-to-end id, or carrying neither reference for exactly its amount — and (review
-- 6b-2c legal-deadlines-1) the other lines the options can book as its debit: a debit of its amount to its payee's IBAN
-- whatever its references but ours (rule 3b on classes O and E0; round 3: never a line naming another transfer or lot
-- of ours), an entry kept unsplit whose stored details name its debit
-- (class U, whatever the entry's total: netted with a return). 'waiting' when
-- one of them offers the transfer's booking (private.transfer_line_offers: ops can book it as this payout's debit, and
-- its booking writes the true row at its own date — it raises bank_line_unbooked meanwhile), or is younger than
-- private.transfer_debit_bound_days() business days; 'expired' when every such line offers no booking of it and is that
-- old (line_ambiguous, batch_ambiguous, lot_too_large, batch_mixed, the unsplit refusals, fee_unexplained, S08b, a line
-- below the amount): the row is then written « bloqué : débit possible non comptabilisé »; null when there is none.
-- The lines newest first, so that a young one answers before any options read; offers is read only for older lines.
-- Keyed: the transfer by its key, the account's lines by (account, booking date).
-- private.transfer_debit_suppression, redefined from 20261117110000 (same signature and settings; its grants restated
-- below). M2c-6b-2d (suppression-e0-names-our-other-lot): the legal-deadlines-1 branch also skips a line whose TF
-- PmtInfId names a lot of ours on the account other than this transfer's own PmtInf in its current file (a class-E0
-- line with a foreign end-to-end id: by its PmtInfId, a line of that other lot — an execution again of one of its
-- transfers, never this one's debit; private.pmt_inf_names_account_lot, read last and by key). Nothing else changes.
create or replace function private.transfer_debit_suppression(p_transfer_id uuid, p_to date, p_today date)
returns text
language plpgsql
volatile
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transfer;
  v_pmt_inf text;
  v_line record;
  v_expired boolean := false;
begin
  select * into t from public.bank_transfer where id = p_transfer_id;
  if t.id is null or p_to is null or p_to < t.requested_execution_date then
    return null;
  end if;
  select i.pmt_inf_id into v_pmt_inf from public.transfer_file_item i
  where i.file_id = t.transfer_file_id and i.transfer_id = t.id;
  for v_line in
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
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id offset 0)
    order by x.booking_date desc, x.id
  loop
    if private.business_days_between(v_line.booking_date, coalesce(p_today, private.paris_today()))
         < private.transfer_debit_bound_days()
       or private.transfer_line_offers(v_line.id, t.id) then
      return 'waiting';
    end if;
    v_expired := true;
  end loop;
  return case when v_expired then 'expired' end;
end;
$$;

-- The guards of « Lier » that the screen replaces (plan §4.1; critic F9, L8), on a debit without our reference (N, O,
-- E0; our own lines keep post_debit_links' own_transfer_line): « Frais bancaires », « Classer sans comptabiliser » and
-- the refund link are refused payout_candidate while rule 3b finds a transfer of ours the line may be (for the refund
-- link: a payout or another refund, not that refund's own transfer nor a sweep), client_payout_line on a debit to a
-- client's confirmed payout IBAN (an unplanned payout, or its run's payout without its reference: never a fee nor
-- explained — booked elsewhere it would hide a double payout); the explanation is refused own_transfer_out_line on a
-- transfer out to one of our own accounts (money from client funds to our account is booked, never explained: I9).
-- Review 6b-2c (money-1): a payment's return and its loss likewise (payout_candidate, client_payout_line) — money that
-- went to a client, or that is our transfer, is never a debtor payment's return — on a debit of a kind « Comptabiliser… »
-- books (round 2: never on a debit the bank flags as a return, which keeps them); (money-2) on a credit the bank flags
-- as a return (its kind, or a held line released as one) from a client's confirmed payout IBAN — an unplanned payout's
-- return, which « Comptabiliser… » books as « Virement revenu » (critic2 ML-11), or a client's money that waits (Q13) —
-- the explanation and « Remboursement revenu » are refused client_payout_line: classified so, the line would leave the
-- funds ledger (5120 unequal to the bank) with the advance still « à récupérer ». Review 6b-2c round 3
-- (other-debit-return-blocked-by-returned-payout-twin; COMPLIANCE OQ-86's default): the return and the loss are refused
-- payout_candidate only while rule 3b finds a transfer of ours that may still be paid out by this line — a payout or a
-- sweep in flight (i), a refund in a file (ii), or a cancelled payout whose run is still approved or sent (critic2 ML-4:
-- the debit may be that run's payout) —, never for a payout only returned, or cancelled with its run ended (iii, for
-- good: refused, the debtor's payment taken back by a debit the bank does not flag would stay allocated and its money
-- paid to the client, I13); the fee and the explanation stay refused on every candidate. (new:refund-to-client-iban-
-- unlinkable) client_payout_line is not applied to the refund link when that refund's own transfer is the line's
-- candidate (its payee IBAN is the line's), nor to « Remboursement revenu » when the refund was sent to the IBAN the
-- credit comes from. Null when allowed.
-- private.link_debit_guard, redefined from 20261117110000 (same signature and settings; its grants restated below).
-- M2c-6b-2d (refund-link-blocked-by-returned-payout-twin; COMPLIANCE OQ-86's default): the refund link too is refused
-- payout_candidate only for a candidate that may still be paid out by the line — another payout in flight (i), another
-- refund in a file (ii), a cancelled payout whose run is still approved or sent — never for a payout only returned, or
-- cancelled with its run ended (iii): beside such a twin, a reference-less debit of the refund's amount is linked as
-- that refund's debit (the trade-off: COMPLIANCE OQ-86). Nothing else changes.
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
  select coalesce(bool_or(c.transfer_id is distinct from v_refund_transfer
                          and (p_kind <> 'refund' or c.kind <> 'sweep')
                          and (p_kind not in ('return', 'loss', 'refund') or c.cand in ('i', 'ii')
                               or (c.status = 'cancelled' and r.status in ('approved', 'sent')))), false),
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
-- Privileges (restated for every function redefined here; the new one internal)
------------------------------------------------------------------------------------------

-- the new internal (PostgreSQL grants EXECUTE to PUBLIC by default) and the redefined ones, as 20261117100000
-- (private.transfer_line_pre) and 20261117110000 (private.transfer_debit_suppression, private.link_debit_guard)
-- revoked them: only the SECURITY DEFINER callers use them
revoke execute on function private.pmt_inf_names_account_lot(uuid, text), private.transfer_line_pre(uuid),
  private.transfer_debit_suppression(uuid, date, date), private.link_debit_guard(uuid, text, uuid)
  from public, anon, authenticated, service_role;
