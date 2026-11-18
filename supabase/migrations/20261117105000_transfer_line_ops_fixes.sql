-- M2c-6b-2b, fixes found by the tests 6b-2b deferred (plan docs/design/m2c-6b-2-plan.md §8.1, §8.2; ADR-0014
-- « M2c-6b-2b deferred tests »). Forward-only: 20261117100000_transfer_line_ops.sql is treated as merged and left
-- unchanged; each function below is copied from its definition there (its latest: as PR #33's CI scale fix left it, its
-- per-member reads keyed whatever the statistics — ADR-0014 « M2c-6b-2b review fixes », CI scale fix), with its
-- SECURITY DEFINER, every SET clause (enable_seqscan off included) and search_path restated, changed only as its comment
-- says, its grants restated at the end. The cancellation-after-download switch stays OFF; pgTAP 033 and 034 unchanged.
--   * private.transfer_line_locks: step 8 locked FOR SHARE every transfer_file holding an item of the line's PmtInfId,
--     whatever its account — a bank-given PmtInfId equal to another servicer's lot made one servicer's command lock
--     that servicer's file for its duration (its download or regeneration waited, then `busy`; critic CSO-5 « no row
--     of another servicer is ever locked »). Now the PmtInf's files of the line's account only, as every read of the
--     lot (private.transfer_line_class, private.transfer_line_pre, private.transfer_line_members) already filters it.
--     Test: worker tests/test_transfer_line_concurrency_integration.py
--     ::test_another_servicer_s_rows_are_never_locked_by_the_command.
--   * public.transfer_line_options: an entry kept unsplit whose stored detail has no amount was answered refusal
--     `bad_request` (its proposed part had no amount; the preview's parse refused it) — the sheet's label « La demande
--     est incomplète ou mal formée » — where the check, and the plan's options (§3.11, §3.4.12), say
--     `unsplit_detail_missing` (« Le relevé ne détaille pas assez cette écriture … »). Now unsplit_detail_missing, no
--     part proposed. Test: worker tests/test_transfer_line_ops_more_integration.py
--     ::test_the_iso_charged_debit_without_chrgs_and_an_unsplit_entry_without_amounts_stay.

------------------------------------------------------------------------------------------
-- The locks (plan §3.8), redefined from 20261117100000 (same settings; grants restated below): step 8, the PmtInf's
-- files of the line's account only — by the PmtInfId alone (transfer_file_item_pmt_inf_idx), each file's account by its
-- key, compared outside, as the CI scale fix keys the other steps. Nothing else changes.
------------------------------------------------------------------------------------------

-- The keys first, without locks, reading only ids that passed the tenant filter (critic CSO-5): the transfers named,
-- every member of a lot (debit or credit) and every rule-3b candidate (pg_temp._tl_pre), the transfers an entry kept
-- unsplit details (by the line's servicer and account, critic2 CSO2-10), the transfers of the unplanned bookings an
-- unplanned return names; the clients of the payouts among them, of a client part and of an unplanned return. Then,
-- each set in id order:
--   1. runs FOR UPDATE: the transfers' runs and the live run (draft, approved or sent) of each such client, by
--      remittance_run_pending_uq's key (pg_temp._tl_locked_runs: the check refuses split_changed a live run found
--      under the locks that is not there — a draft is never locked late, critic CSO-12);
--   2. client_payout_account FOR NO KEY UPDATE: the accounts a return marks returned;
--   3. bank_account FOR SHARE: the line's, the transfers' debtor and creditor accounts, the own account of the
--      counterparty IBAN;
--   4. payment FOR KEY SHARE: the payments of the payout parts' runs' lines late at this date (6b-1 concurrency-2);
--   5. the allocation lock `payments:<org>` (always: every part but a sweep's or a fee moves 4670);
--   6. bank_transaction FOR NO KEY UPDATE: the line and the debit lines the unplanned returns name;
--   7. the remit lock `remit:<org>`;
--   8. transfer_file FOR SHARE: the transfers' files (the lot's included) and the files of the live runs' payouts
--      (critic F6);
--   9. bank_transfer FOR UPDATE: every key transfer (every member of a lot, booked or not).
-- A lock not had within lock_timeout (2 s, 55P03) is re-raised with the step it waited at (critic2 CSO2-6): `busy` for
-- a row, `allocation_busy` for the servicer-wide `payments:` or `remit:` lock (an allocation chunk or an approval).
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

------------------------------------------------------------------------------------------
-- The options (plan §3.11), redefined from 20261117100000 (same settings; grants restated below): an entry kept
-- unsplit whose stored detail has no amount is refused unsplit_detail_missing. Nothing else changes.
------------------------------------------------------------------------------------------

-- What the line may be booked as (plan §3.11), for one line when ops open its sheet, never once per row of a list
-- (critic CSO-4): {class, kind, direction, amount_minor, unsplit_ours, proposals: [{action, parts, preview}], members,
-- member_count, refusal, refusal_detail, pending_line_id}. Each proposal is the parts the rules of §3.4 give the line,
-- evaluated by the preview's check: a proposal the check refuses is not offered, its refusal is. Per class:
--   E debit: payout(t) for a live t, the unplanned payout (sweep) of a cancelled, booked or returned t, a fee part
--     when the line exceeds t; E credit: payout_returned(t) (a fee part only on a flagged return short of t), or, while
--     t has an open unplanned booking, only that booking's return (the largest advance); a pending debit of t
--     (critic2 ML-3): refusal debit_pending and that line's id;
--   B: the only subset of the lot (members by seq; at most 50 listed, member_count all), live members payout, left
--     and cancelled ones unplanned (a debit), the planned or the unplanned return (a credit); above the cap
--     lot_too_large from the keyed count, no member read;
--   N, O, E0 debit: rule 3b's one candidate as its part, else the client by its payout IBAN, else our own IBAN; a
--     flagged return without our reference (critic2 ML-11): the open unplanned booking whose payout went to that IBAN
--     at that amount, the largest advance first;
--   U: the statement's stored details as parts (§3.4.12), a fee in the S08 shape.
-- action ∈ payout, lot, unplanned_payout, unplanned_sweep, returned, detail. Money staff of the line's servicer only.
create or replace function public.transfer_line_options(p_bank_transaction_id uuid)
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
  if not found or not (l.organization_id = any (private.money_staff_org_ids())) then
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
      else
        v_action := case when v_cand.cand = 'iii' then 'unplanned_payout' else 'payout' end;
        v_parts := jsonb_build_array(jsonb_build_object(
                     'kind', case when v_cand.cand = 'iii' then 'unplanned_payout' else v_cand.kind end,
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
    'unsplit_ours', l.unsplit_ours, 'proposals', v_props, 'members', v_members,
    'member_count', case when v_class = 'B' then (select m.v::integer from pg_temp._tl_meta m where m.k = 'member_count')
                    end,
    'refusal', v_refusal, 'refusal_detail', v_refusal_detail, 'pending_line_id', v_pending);
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges, restated as 20261117100000 set them
------------------------------------------------------------------------------------------

revoke execute on function private.transfer_line_locks(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.transfer_line_options(uuid) from public, anon;
grant execute on function public.transfer_line_options(uuid) to authenticated;
