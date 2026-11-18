-- M2c-6b-2c « pages » (plan docs/design/m2c-6b-2-plan.md §4, the 6b-2c parts of §6–§12; ADR-0014 « M2c-6b-2c »). The
-- screen that books our transfer lines ships (« Débits et retours »: the options read when a sheet opens, the preview,
-- public.book_transfer_line with a UUID key and the expected text), so:
--   * the mis-booking guards it replaces (§4.1): « Frais bancaires » and « Classer sans comptabiliser » are refused on a
--     reference-less debit a transfer of ours may be (payout_candidate: rule 3b's keyed probe) and on a debit to a
--     client's payout IBAN (client_payout_line); the explanation of a transfer out to our own IBAN
--     (own_transfer_out_line); the refund link when a transfer of ours other than that refund (and other than a sweep:
--     033's round-7 N1 (b)) may be the line (critic F9); (review 6b-2c money-1) a payment's return and its loss on such
--     a debit of a kind « Comptabiliser… » books (round 2: never on a debit the bank flags as a return; round 3: only
--     while a candidate may still be paid out by the line, never for a payout only returned or cancelled with its run
--     ended — COMPLIANCE OQ-86; a refund's own link and its return from the IBAN it was sent to are never
--     client_payout_line) — public.link_debit (public.debit_link_options says the return's answer: return_guard); the queue gives each row a cheap bookable_as (critic CSO-4) and lists in « À classer »,
--     not « Frais », the reference-less debits a transfer of ours may be (payout_amount_match) or that went to a client's
--     payout IBAN (client_payout_iban), found from the lines (critic2 CSO2-13) — public.debit_queue;
--   * the end of a suppression (§4.2; critic L8, critic2 ML-7): an in-flight payout's R124-6 breach row is suppressed by
--     a line that could be its debit only while that line offers its booking (private.transfer_line_offers: true exactly
--     when the options read proposes a booking containing it — the same code) or is younger than five business days
--     (Q14's default, private.transfer_debit_bound_days; round 3: never a line naming another transfer or lot of
--     ours); past that, the nightly check writes the row « bloqué : débit
--     possible non comptabilisé » (blocked_reason debit_unbooked); bank_line_unbooked also counts a reference-less debit
--     with a rule-3b candidate (P0 once an in-flight candidate's latest execution date has passed);
--   * the hints reworded now that the screen exists (§4.3): private.own_transfer_line_hint gives the link's and the
--     relay's too (private.post_debit_links and public.release_own_credit call it);
--   * the reads of the run page, « Virements » and the client space (§4.4; critic CSO-9, CSO-6, L6, critic2 ML-12):
--     public.remittance_run_payout (with whether the run's payout account is blocked now and the run that paid a
--     returned payout again), public.transfer_bookings, client_remittance_summary.unplanned_runs, each keyed on the
--     run's transfer chain (run.transfer_id, then each replaces_transfer_id);
--   * the sheets' facts the preview did not carry (the run's set-off, the date the breach is recorded against, the share
--     after an unplanned sweep, the payout account a return blocks, the date of the unplanned booking a return reverses)
--     and the options' line facts (its booking date, the statement's charges, the counterparty IBAN's last four).
-- Every read of a run's lines or of a transfer's bookings these statements add holds the run's or the transfer's key
-- alone, its other conditions outside an offset 0 subquery (PR #33's CI scale fix's rule, ADR-0014 « M2c-6b-2b review
-- fixes »: plans that stay keyed whatever the statistics the 50,000-line runs leave).
-- The cancellation-after-download switch stays OFF; pgTAP 033 and 034 unchanged.
--
-- New: private.transfer_debit_bound_days, private.transfer_line_options_of (the options' body, without the caller's
-- rights: the nightly check reads it through private.transfer_line_offers), private.transfer_line_offers,
-- private.transfer_debit_suppression, private.transfer_line_bookable_as, private.transfer_line_queue_reason,
-- private.link_debit_guard, private.transfer_chain, public.remittance_run_payout, public.transfer_bookings,
-- private.remittance_run_late_on (review 6b-2c money-3); the blocked reason debit_unbooked;
-- bank_transfer_account_amount_idx (rule 3b's probe by key whatever the statistics).
-- Redefined, each copied from its latest definition and changed only as its comment says, with its settings and grants
-- restated: public.transfer_line_options (20261117105000), private.transfer_line_parts_json and
-- private.transfer_line_candidates (20261117100000 as PR #33's CI scale fix left it; the last read by key whatever the
-- statistics — the class's end-to-end probes were already keyed there by that fix),
-- private.own_transfer_line_hint (20261117090000), public.link_debit (20261111090000), public.debit_queue,
-- private.post_debit_links, public.release_own_credit, private.transfer_debit_may_be_seen,
-- private.run_remittance_runs_checks and public.client_remittance_summary (20261116090000), private.run_transfer_checks
-- (20261117090000); review 6b-2c (round 1, ADR-0014 « M2c-6b-2c review fixes »): private.transfer_line_check
-- (20261117100000 as PR #33's CI scale fix left it) and public.debit_link_options (20261116090000).

------------------------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------------------------

-- (critic L8; Q14's default, COMPLIANCE CPCE-08, OQ-83) the breach row an in-flight item gets once the lines that could
-- be its payout's debit offered no booking of it for five business days: « bloqué : débit possible non comptabilisé »
alter table public.remittance_deadline_breach drop constraint remittance_deadline_breach_blocked_reason_check,
  add constraint remittance_deadline_breach_blocked_reason_check
    check (blocked_reason in ('unmeetable_delay', 'payout_returned', 'debit_unbooked'));
comment on column public.remittance_deadline_breach.blocked_reason is
  'Why the breach was recorded blocked: unmeetable_delay, payout_returned (« virement revenu impayé »), debit_unbooked '
  '(« débit possible non comptabilisé »: a line that could be the payout''s debit offered no booking of it for five '
  'business days, M2c-6b-2c).';

------------------------------------------------------------------------------------------
-- Constants and the transfer chain
------------------------------------------------------------------------------------------

-- The bound of a suppression (plan §4.2; critic L8; founder Q14's default, COMPLIANCE CPCE-08, OQ-83): a line that could
-- be an in-flight payout's debit but offers no booking of it suppresses the payout's R124-6 breach row only while it is
-- younger than this many business days (its booking date against the check's day). One constant: the nightly check and
-- its pgTAP read it.
create or replace function private.transfer_debit_bound_days()
returns integer
language sql
immutable
parallel safe
set search_path = ''
as $$
  select 5;
$$;

-- A transfer and the transfers it re-issues (critic2 ML-12): itself, then each replaces_transfer_id, by key — the set
-- bank_transfer.run_id = its run holds (a re-issue moves run.transfer_id to the new transfer, transfer_file_release),
-- with no new index (bank_transfer_run_uq excludes cancelled rows). Depth bounded (a chain is a few re-issues).
create or replace function private.transfer_chain(p_transfer_id uuid)
returns table (transfer_id uuid, depth integer)
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  with recursive c (transfer_id, depth) as (
    select p_transfer_id, 0 where p_transfer_id is not null
    union all
    select q.replaces_transfer_id, c.depth + 1
    from c
    cross join lateral (select y.replaces_transfer_id from public.bank_transfer y where y.id = c.transfer_id offset 0) q
    where q.replaces_transfer_id is not null and c.depth < 50)
  select c.transfer_id, c.depth from c;
$$;


------------------------------------------------------------------------------------------
-- The options read and its sheets' facts (plan §3.11, §7.3)
------------------------------------------------------------------------------------------

-- What a line may be booked as (plan §3.11): the body of public.transfer_line_options as 20261117105000 last defines it
-- (20261117100000's with PR #33's CI scale fix — its id probes and the members' file items read by key alone — and
-- 6b-2b's deferred tests' fix: a stored detail without its amount refused unsplit_detail_missing), moved here unchanged
-- but for the caller's rights (public.transfer_line_options checks them, then calls this) and three facts of the line
-- the sheets word (§7.3): its booking date, the charges its statement records (the fee's sentence,
-- critic2 ML-10) and the last four characters of its counterparty IBAN (the page masks it « IBAN …1234 »); review 6b-2c
-- (pages-5): whether a pending debit it names is held in « Doublons possibles » (pending_held). Internal: read by the
-- options and by private.transfer_line_offers (the nightly check's bound, critic2 ML-7), never by a client.
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


-- public.transfer_line_options, redefined from 20261117105000 (same signature and settings; its grants restated below):
-- the caller's rights (money staff of the line's servicer at aal2, else null) and the body, which moves unchanged to
-- private.transfer_line_options_of — so that private.transfer_line_offers (the nightly check's) reads the very same
-- proposals (critic2 ML-7: true exactly when the options propose a booking containing the transfer). Nothing else
-- changes.
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
begin
  select * into l from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not (l.organization_id = any (private.money_staff_org_ids())) then
    return null;
  end if;
  return private.transfer_line_options_of(l.id);
end;
$$;

-- Whether a line offers a booking containing this transfer (plan §4.2; critic2 ML-7): the options read of the line
-- (private.transfer_line_options_of, the rules of §3.4 through transfer_line_check, its helpers shared) proposes parts
-- naming it — an E line carrying its id at its amount, or above it by a fee the statement's charges allow; an N/O/E0
-- line of which it is rule 3b's only candidate (not run_still_live); a lot line whose only subset holds it (at most the
-- lot cap, else no); an entry kept unsplit whose stored details are bookable and name it. Volatile (the options build
-- their working tables, on commit drop); called by the nightly check for a line older than the bound only.
create or replace function private.transfer_line_offers(p_line_id uuid, p_transfer_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
set enable_seqscan = off
as $$
begin
  if p_line_id is null or p_transfer_id is null then
    return false;
  end if;
  return coalesce((select bool_or(x ->> 'transfer_id' = p_transfer_id::text)
                   from jsonb_array_elements(coalesce(private.transfer_line_options_of(p_line_id) -> 'proposals',
                                                      '[]'::jsonb)) p
                   cross join lateral jsonb_array_elements(p -> 'request') x), false);
end;
$$;


-- The date a payout's run is held to at p_on, as private.bank_booking_post_rows records its breach rows (review 6b-2c
-- money-3, legal-deadlines-2): among the run's positive unreleased lines late at p_on (private.remittance_run_late_lines,
-- by the run's key), each one's own latest execution date, or for a line whose mandate's delay cannot be met
-- (remittance_line.unmeetable) the one-month date of its collection (private.remittance_deadline_or_null(encaissement
-- date, 30), as private.remittance_late_lines) when that date is before p_on — the earliest of them; null when the run has
-- no such line (a debit at p_on records no breach). Read by the check (pg_temp._tl.late, late_date) for the sheets.
create or replace function private.remittance_run_late_on(p_run_id uuid, p_on date)
returns date
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select min(case when l.unmeetable then m.latest_execution_date else l.latest_execution_date end)
  from private.remittance_run_late_lines(p_run_id, p_on) l
  left join lateral (select d.latest_execution_date
                     from private.remittance_deadline_or_null(l.encaissement_date, 30) d
                     where l.unmeetable and l.encaissement_date is not null) m on true
  where not l.unmeetable or m.latest_execution_date < p_on;
$$;

-- private.transfer_line_check, redefined from 20261117100000 (as PR #33's CI scale fix left it; same signature and
-- settings, its grants restated below). Review 6b-2c (money-3, legal-deadlines-2): a payout part is late, and
-- pg_temp._tl.late_date says the date its breach is recorded against, by the rule private.bank_booking_post_rows applies
-- (private.remittance_run_late_on) — before, an item whose mandate's delay cannot be met was late from its short date
-- although the booking records its breach only after its one-month date, and the sheet said a breach was recorded that
-- the booking does not write. Nothing else changes.
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


-- private.transfer_line_parts_json, redefined from 20261117100000 (same signature and settings; its grants restated
-- below). M2c-6b-2c (plan §7.3): each part also carries the facts its sheet words, read by key, none computed by the
-- page — a payout part its run's set-off (settlement_minor) and, when the debit is late, the date its breach is
-- recorded against (latest_execution_date: review 6b-2c money-3, the check's pg_temp._tl.late_date, by the booking's
-- rule — a line whose delay cannot be met held to its one-month date); an unplanned sweep the
-- servicer's share left on the dedicated account once it and the unplanned sweeps before it are booked
-- (share_after_minor, −Σ 4679 of the servicer and currency less them); a return the last four characters of the payout
-- account it marks returned and whether it blocks it (only an active account is marked, blocks_account); an unplanned
-- return the date of the line it reverses (returns_on). Nothing else changes.
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


------------------------------------------------------------------------------------------
-- The end of a suppression (plan §4.2; critic L8, critic2 ML-7)
------------------------------------------------------------------------------------------

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
                 -- (class E, B, U), read last and by key
                 or (x.amount_minor = t.amount_minor and x.currency = t.currency
                     and x.counterparty_iban = t.payee_iban
                     and private.transfer_line_class(x.id) in ('N', 'O', 'E0'))))
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

-- private.transfer_debit_may_be_seen, redefined from 20261116090000 (same signature and settings but volatile: it now
-- reads the options of an older line; its grants restated below): whether a line could still be this transfer's debit
-- and suppresses its breach row today — private.transfer_debit_suppression's 'waiting' (plan §4.2: a line that offers no
-- booking of it suppresses five business days only). Kept for its callers (the nightly check reads the suppression
-- itself, the blocked reason with it).
create or replace function private.transfer_debit_may_be_seen(p_transfer_id uuid, p_to date)
returns boolean
language plpgsql
volatile
set search_path = ''
set enable_seqscan = off
as $$
begin
  return coalesce(private.transfer_debit_suppression(p_transfer_id, p_to, private.paris_today()) = 'waiting', false);
end;
$$;


-- private.run_remittance_runs_checks, redefined from 20261116090000 (same signature and settings; its grants restated
-- below). M2c-6b-2c (plan §4.2; critic L8, critic2 ML-7): an in-flight item's breach row is suppressed by a line that
-- could be its payout's debit only while private.transfer_debit_suppression says 'waiting' (the line offers its
-- booking, or is younger than five business days, Q14's default); once only lines that offer no booking of it remain,
-- older than that ('expired'), the row is written « bloqué : débit possible non comptabilisé » (debit_unbooked) — first
-- of the blocked reasons: it says why a row was written while a line could still be the debit. The suppression read once
-- per (run, latest execution date), only for a payout handed out whose statements cover its date with no debit seen.
-- Nothing else changes.
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
  olc as materialized (
    select k.run_id, k.latest_execution_date,
           coalesce(t.status = 'ordered' or (t.status = 'in_file' and coalesce(t.download_count, 0) = 0)
                    or (e.unseen and e.suppression is distinct from 'waiting'), false) as proven,
           -- M2c-6b-2c (plan §4.2): proven only because the lines that could be its debit offered no booking of it for
           -- five business days
           coalesce(t.status = 'in_file' and coalesce(t.download_count, 0) > 0 and e.unseen
                    and e.suppression = 'expired', false) as debit_unbooked
    from (select distinct o.run_id, o.latest_execution_date from ol o where not o.out_of_horizon) k
    left join lateral (select q.id, q.debtor_bank_account_id, q.status,
                              (select f.download_count from public.transfer_file f where f.id = q.transfer_file_id)
                                as download_count
                       from public.remittance_run r join public.bank_transfer q on q.id = r.transfer_id
                       where r.id = k.run_id offset 0) t on true
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


-- private.run_transfer_checks, redefined from 20261117090000 (same signature and settings; its grants restated below).
-- M2c-6b-2c (plan §4.2; critic2 ML-7): bank_line_unbooked also counts, after one business day, an other debit without
-- our reference that rule 3b's keyed probe finds a transfer of ours for (the line keeps suppressing its payout's breach
-- row while it offers its booking: ops are told) — from the servicer's unbooked other debits by their index, never
-- from the transfers — and says p0 when an in-flight candidate's run has a positive live line whose latest execution
-- date has passed. Nothing else changes.
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
    where b.organization_id = p_organization_id and b.purpose = 'client_funds')
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
    -- review round 4 (G1): a cancelled payout or refund whose run or refund is still live, debited after all (cancelling
    -- the run or the refund is refused; M2c-6b books the debit). Keyed: the live runs and the waiting refunds.
    select 'transfer_already_debited', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'status', t.status, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id)
    from (select r.transfer_id from public.remittance_run r
          where r.organization_id = p_organization_id and r.status in ('approved', 'sent') and r.transfer_id is not null
          union
          select q.transfer_id from public.refund_request q
          where q.organization_id = p_organization_id and q.status = 'requested' and q.transfer_id is not null) l
    cross join lateral (select x.* from public.bank_transfer x where x.id = l.transfer_id offset 0) t
    where t.status = 'cancelled' and t.kind in ('payout', 'refund')
      and exists (select 1 from public.bank_account b where b.id = t.debtor_bank_account_id
                    and b.purpose = 'client_funds')
      and private.transfer_debited_before(t.id)
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
                from public.bank_account b
                cross join lateral (select q.id, q.kind, q.run_id from public.bank_transfer q
                                    where q.organization_id = p_organization_id and q.debtor_bank_account_id = b.id
                                      and q.status = 'cancelled' and q.transfer_file_id is not null offset 0) t
                cross join lateral private.transfer_late_lines(t.id) ll (line_id)
                where b.organization_id = p_organization_id and b.purpose = 'client_funds'
                  and exists (select 1 from public.transfer_file_item i
                              cross join lateral (select f.download_count from public.transfer_file f
                                                  where f.id = i.file_id offset 0) f
                              where i.transfer_id = t.id and f.download_count > 0)
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


-- private.transfer_line_candidates, redefined from 20261117100000 (same signature and settings; its grants restated
-- below). M2c-6b-2c (critic2 CSO2-13, found by 037 P's read bound): the line is read by its primary key first (offset 0),
-- then its direction and class — with statistics that do not know the table yet (a fresh one, a bulk load), the planner
-- read the line through bank_transaction_unposted_idx (a partial index on the debits) and filtered every unposted line of
-- the servicer for its id, on each probe: « À classer » probes each reference-less debit it lists, the nightly check each
-- line it counts; and the account's transfers of its amount by bank_transfer_account_amount_idx (below), the filter on
-- a file outside the probe — with the probe implying bank_transfer_file_idx's predicate, the same statistics read every
-- filed transfer of the servicer by that index for each line (« À classer », 24,000 reads for 40 lines in 037 P).
-- Nothing else changes.
create index bank_transfer_account_amount_idx on public.bank_transfer (debtor_bank_account_id, amount_minor);

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
    select q.id, q.kind, q.status, q.run_id, q.replaces_transfer_id, q.return_entry_id, i.execution_date,
           f.status as file_status, f.download_count, ru.status as run_status, ru.transfer_id as run_transfer
    from l
    cross join lateral (select q.id, q.organization_id, q.kind, q.status, q.currency, q.payee_iban, q.transfer_file_id,
                               q.run_id, q.replaces_transfer_id, q.return_entry_id
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
           end as cand,
           x.kind, x.status, x.run_id, x.return_entry_id
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
      where r.status in ('approved', 'sent')));
$$;


------------------------------------------------------------------------------------------
-- The queue's cheap facts and the guards of « Lier » (plan §4.1; critic CSO-4, F9, L8; critic2 CSO2-13)
------------------------------------------------------------------------------------------

-- What a line of the queue may be booked as by « Comptabiliser… » (critic CSO-4), by key and with no search — the
-- options are read only when ops open that line's sheet: e our id (private.transfer_line_class E), b our lot (B), u an
-- entry kept unsplit holding ours (U, its stored details), n a debit without our reference (N, O, E0) of a transfer
-- kind that rule 3b's probe finds a candidate for, or that went to a client's confirmed payout IBAN or one of our own
-- accounts, or a credit the bank flags as a return from a client's confirmed payout IBAN (critic2 ML-11: an unplanned
-- payout's return); else null. An entry kept unsplit holding nothing of ours is never n (review money-1).
create or replace function private.transfer_line_bookable_as(p_line_id uuid)
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
begin
  select * into t from public.bank_transaction where id = p_line_id;
  if not found then
    return null;
  end if;
  v_class := private.transfer_line_class(t.id);
  if v_class = 'U' then return 'u'; end if;
  if v_class = 'E' then return 'e'; end if;
  if v_class = 'B' then return 'b'; end if;
  if t.unsplit_ours is not null then return null; end if;
  select coalesce(d.released_kind, t.kind) into v_kind
  from (select 1) z left join public.bank_duplicate_resolution d on d.bank_transaction_id = t.id;
  if t.direction = 'debit' and v_kind in ('transfer_out', 'other_debit', 'batch_unsplit')
     and (exists (select 1 from private.transfer_line_candidates(t.id, v_class))
          or (t.counterparty_iban is not null
              and (exists (select 1 from public.client_payout_account a
                           where a.organization_id = t.organization_id and a.iban = t.counterparty_iban
                             and a.currency = t.currency and a.confirmed_at is not null
                             and a.status in ('active', 'returned', 'retired'))
                   or exists (select 1 from public.bank_account o
                              where o.organization_id = t.organization_id and o.purpose = 'own'
                                and o.status = 'active' and o.iban = t.counterparty_iban
                                and o.currency = t.currency)))) then
    return 'n';
  end if;
  if t.direction = 'credit' and v_kind = 'return' and t.counterparty_iban is not null
     and exists (select 1 from public.client_payout_account a
                 where a.organization_id = t.organization_id and a.iban = t.counterparty_iban
                   and a.currency = t.currency and a.confirmed_at is not null
                   and a.status in ('active', 'returned', 'retired')) then
    return 'n';
  end if;
  return null;
end;
$$;

-- Why « À classer » lists an other debit without our reference (plan §4.1; critic2 CSO2-13: from the line, by rule 3b's
-- keyed probe — one probe of bank_transfer_filed_amount_idx on (account, amount), then each transfer's file, item, run
-- and payee IBAN by key; never from the transfers): payout_amount_match with the candidates (a transfer of ours in
-- flight, a refund in a file, or a cancelled or returned payout whose bytes the bank holds, of its amount to its IBAN),
-- else client_payout_iban with the client (a debit to a client's confirmed payout IBAN), else own_transfer_out (to one
-- of our own accounts); none for anything else (a fee or another debit: « Frais »). A line of an entry kept unsplit is
-- never one (review money-1).
create or replace function private.transfer_line_queue_reason(p_line_id uuid)
returns table (reason text, candidates jsonb)
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  v_class text;
  v_cands jsonb;
begin
  select * into t from public.bank_transaction where id = p_line_id;
  if not found or t.direction <> 'debit' or t.unsplit_ours is not null then
    return;
  end if;
  v_class := private.transfer_line_class(t.id);
  if v_class not in ('N', 'O', 'E0') then
    return;
  end if;
  -- (review 6b-2c cs-1) rule 3b's probe only when a transfer of this account and amount was ever put in a file: one
  -- probe of bank_transfer_account_amount_idx here, in this function's cached plan — the probe's own function is planned
  -- again at each call (its settings), 0.5–0.8 ms a line, which every unbooked other debit of the servicer paid on each
  -- read of « À classer » and « Frais » (10,000 lines: the API's 8 s). The key alone inside the fence, the file
  -- outside (PR #33's CI scale fix's rule: with the file condition beside it, stale statistics read every filed transfer
  -- of the servicer by bank_transfer_file_idx, once per line)
  if exists (select 1
             from (select q.transfer_file_id from public.bank_transfer q
                   where q.debtor_bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor offset 0) q
             where q.transfer_file_id is not null) then
    select jsonb_agg(jsonb_build_object('transfer_id', c.transfer_id, 'kind', c.kind, 'status', c.status,
                                        'amount_minor', t.amount_minor::text) order by c.transfer_id)
    into v_cands from private.transfer_line_candidates(t.id, v_class) c;
  end if;
  if v_cands is not null then
    return query select 'payout_amount_match'::text, v_cands;
    return;
  end if;
  if t.counterparty_iban is null then
    return;
  end if;
  select jsonb_agg(distinct jsonb_build_object('client_id', a.client_organization_id))
  into v_cands
  from public.client_payout_account a
  where a.organization_id = t.organization_id and a.iban = t.counterparty_iban and a.currency = t.currency
    and a.confirmed_at is not null and a.status in ('active', 'returned', 'retired');
  if v_cands is not null then
    return query select 'client_payout_iban'::text, v_cands;
    return;
  end if;
  if exists (select 1 from public.bank_account o
             where o.organization_id = t.organization_id and o.purpose = 'own' and o.status = 'active'
               and o.iban = t.counterparty_iban and o.currency = t.currency) then
    return query select 'own_transfer_out'::text, '[]'::jsonb;
  end if;
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
  select coalesce(bool_or(c.transfer_id is distinct from v_refund_transfer
                          and (p_kind <> 'refund' or c.kind <> 'sweep')
                          and (p_kind not in ('return', 'loss') or c.cand in ('i', 'ii')
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


-- « Débits et retours » (redefined from 20261116090000, dropped and created: a column added last; same settings, its
-- grants restated below). M2c-6b-2c (plan §4.1; critic CSO-4, critic2 CSO2-13): each row of « À classer » and « Frais »
-- with its cheap bookable_as (private.transfer_line_bookable_as, by key: the page offers « Comptabiliser… » and reads
-- the options only when ops open the sheet); « À classer » also lists an other debit without our reference a transfer
-- of ours may be (payout_amount_match, its candidates) or that went to a client's payout IBAN (client_payout_iban, the
-- client) or to our own account (own_transfer_out) — found from the lines, each unbooked other debit of the servicer by
-- its index and rule 3b's keyed probe (private.transfer_line_queue_reason), never from the transfers; « Frais » no
-- longer lists them; a candidate naming a transfer of ours comes with its run's status and number (the
-- cancelled_transfer_debited text is worded by it, critic2 ML-4). Nothing else changes.
drop function public.debit_queue(text, integer, integer);
create function public.debit_queue(p_tab text default 'a-classer', p_offset integer default 0,
                                   p_limit integer default 20)
returns table (bank_transaction_id uuid, statement_id uuid, bank_account_id uuid, direction text, kind text,
               amount_minor text, currency char(3), booking_date date, age_days integer, counterparty_name text,
               counterparty_iban_end text, remittance_text text, end_to_end_id text, original_end_to_end_id text,
               return_reason text, review_reason text, candidates jsonb, decision text, decided_at timestamptz,
               decided_payment_id uuid, total bigint, held_kind text, payment_info_id text, unsplit_ours smallint,
               names_our_lot boolean, bookable_as text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_orgs uuid[] := private.money_staff_org_ids();
  v_today date := private.paris_today();
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_total bigint;
begin
  drop table if exists pg_temp._dq;
  if p_tab = 'doublons' then
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.kind = 'suspected_duplicate'
      and not exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id);
  elsif p_tab = 'frais' then
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.kind = 'other_debit'
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
      -- M2c-6b-1: a batch line of our files is one of our transfers (« À classer »), never a fee
      and not (t.end_to_end_id is null and coalesce(t.payment_info_id, '') ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
      and not (t.direction = 'debit'
               and exists (select 1 from public.refund_request q
                           where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
                             and q.organization_id = t.organization_id and q.status = 'requested'))
      -- M2c-6b-2c: a debit a transfer of ours may be, or to a client's payout IBAN or our own account: « À classer »
      and not exists (select 1 from private.transfer_line_queue_reason(t.id) n);
  elsif p_tab = 'traites' then
    -- from the decisions (a few per day), never from the servicer's lines
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    where t.id in (select l.bank_transaction_id from public.bank_debit_link l where l.organization_id = any (v_orgs)
                   union
                   select k.bank_transaction_id from public.bank_line_booking k
                   where k.organization_id = any (v_orgs)
                   union
                   select c.bank_transaction_id from public.bank_own_credit_release c
                   where c.organization_id = any (v_orgs)
                   union
                   select r.bank_transaction_id from public.bank_duplicate_resolution r
                   where r.organization_id = any (v_orgs)
                     and not (r.decision = 'released' and r.released_kind in ('return', 'refund_out')
                              and not exists (select 1 from public.bank_debit_link l
                                              where l.bank_transaction_id = r.bank_transaction_id)));
  else
    create temp table _dq on commit drop as
    select t.*, coalesce(r.released_kind, t.kind) as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = any (v_orgs) and t.kind in ('return', 'refund_out', 'suspected_duplicate')
      and (t.kind <> 'suspected_duplicate' or r.released_kind in ('return', 'refund_out'))
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
    union all
    -- M2c: our transfers out, credits from our own account or from a client (released duplicates of those kinds
    -- too), not booked, explained or released as a relayed debtor payment yet
    select t.*, coalesce(r.released_kind, t.kind), null::text, null::jsonb
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = any (v_orgs)
      and (t.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
           or (t.kind = 'suspected_duplicate'
               and r.released_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')))
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
    union all
    -- M2c-6b-1: a batch line of our files (no end-to-end id, our PmtInfId) the debit job left to ops
    select t.*, t.kind, null::text, null::jsonb
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.direction = 'debit' and t.end_to_end_id is null
      and t.kind in ('other_debit', 'batch_unsplit') and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
    union all
    -- review round 7 (S2): a debit of an entry kept unsplit holding a detail of ours, not our batch line (listed above),
    -- the funds pass reviewed (it takes no link: it waits for ops' booking), by its partial index
    select t.*, t.kind, null::text, null::jsonb
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.unsplit_ours > 0 and t.direction = 'debit' and t.kind = 'batch_unsplit'
      and not (t.end_to_end_id is null and coalesce(t.payment_info_id, '') ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
    union all
    -- an other debit of a pending refund's amount on its bank account: maybe that refund (from the pending requests,
    -- a few, to the lines of their amount); not one booked already (review fix: a fee the job booked stayed listed,
    -- with no action that works)
    select t.*, t.kind, 'refund_amount_match', m.candidates
    from (select o.id, jsonb_agg(jsonb_build_object('refund_request_id', q.id, 'payment_id', q.payment_id)
                                 order by q.requested_at, q.id) as candidates
          from public.refund_request q
          join public.bank_transaction o
            on o.bank_account_id = q.bank_account_id and o.amount_minor = q.amount_minor and o.kind = 'other_debit'
           and o.direction = 'debit' and o.organization_id = q.organization_id
          where q.organization_id = any (v_orgs) and q.status = 'requested'
            and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = o.id)
            and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = o.id)
            and not (o.end_to_end_id is null and coalesce(o.payment_info_id, '') ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
          group by o.id) m
    join public.bank_transaction t on t.id = m.id
    union all
    -- M2c-6b-2c (plan §4.1; critic CSO-4, critic2 CSO2-13): an other debit without our reference a transfer of ours may
    -- be, or to a client's payout IBAN or our own account — from the servicer's unbooked other debits (by their index)
    -- and rule 3b's keyed probe; a line a pending refund's amount lists above is not listed twice, nor (review 6b-2c
    -- cs-2) a batch line of our files' PmtInf format, listed above
    select t.*, t.kind, n.reason, n.candidates
    from public.bank_transaction t
    cross join lateral private.transfer_line_queue_reason(t.id) n
    where t.organization_id = any (v_orgs) and t.kind = 'other_debit' and t.direction = 'debit'
      and not (t.end_to_end_id is null and coalesce(t.payment_info_id, '') ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
      and not exists (select 1 from public.refund_request q
                      where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
                        and q.organization_id = t.organization_id and q.status = 'requested');
  end if;
  select count(*) into v_total from pg_temp._dq;
  return query
  select t.id, t.statement_id, t.bank_account_id, t.direction, coalesce(t.eff_kind, t.kind), t.amount_minor::text,
         t.currency, t.booking_date, (v_today - t.booking_date)::integer, t.counterparty_name, right(t.counterparty_iban, 4),
         t.remittance_text, t.end_to_end_id, t.original_end_to_end_id, t.return_reason, coalesce(v.reason, t.dq_reason),
         coalesce((select jsonb_agg(c.v || coalesce(
                     (select jsonb_build_object('amount_minor', p.amount_minor::text, 'currency', p.currency,
                                                'booking_date', p.booking_date, 'payer_name', p.payer_name,
                                                'status', p.status, 'left_minor', (pos.amount_minor - pos.returned_minor)::text,
                                                'file_reference', a.external_ref)
                      from public.payment p
                      left join public.account a on a.id = p.account_id
                      cross join lateral private.payment_positions(array[p.id]) pos
                      where p.id = (c.v ->> 'payment_id')::uuid and p.organization_id = t.organization_id), '{}')
                   || coalesce((select jsonb_build_object('end_to_end_id', q.end_to_end_id, 'refund_status', q.status,
                                                          'refund_minor', q.amount_minor::text)
                                from public.refund_request q
                                where q.id = (c.v ->> 'refund_request_id')::uuid
                                  and q.organization_id = t.organization_id), '{}')
                   -- M2c-6b-2c (critic2 ML-4): a transfer of ours named, with its run's status and number
                   -- (by key: the transfer first, then its run; never the servicer's transfers, critic2 CSO2-13)
                   || coalesce((select jsonb_build_object('run_status', r.status, 'run_number', r.number)
                                from (select y.run_id, y.organization_id from public.bank_transfer y
                                      where c.v ? 'transfer_id' and y.id = (c.v ->> 'transfer_id')::uuid offset 0) x
                                cross join lateral (select z.status, z.number from public.remittance_run z
                                                    where z.id = x.run_id offset 0) r
                                where x.organization_id = t.organization_id), '{}')
                     order by c.ord)
                   from jsonb_array_elements(coalesce(v.candidates, t.dq_candidates)) with ordinality c (v, ord)),
                  '[]'::jsonb),
         coalesce((select string_agg(k.kind, '+' order by k.seq) from public.bank_line_booking k
                   where k.bank_transaction_id = t.id),
                  case when c.bank_transaction_id is not null then 'relayed_payment' end, l.kind,
                  case r.decision when 'duplicate' then 'duplicate'
                                           when 'released' then 'released' end),
         coalesce(l.decided_at, c.decided_at, r.decided_at),
         coalesce(l.payment_id, (select p.id from public.payment p
                                 where c.bank_transaction_id is not null and p.bank_transaction_id = t.id)),
         v_total,
         -- a held duplicate: how the import read it (the « Libérer » sheet says what it becomes)
         case when t.kind = 'suspected_duplicate' then (select h.kind from private.held_line_kind(t.id) h) end,
         t.payment_info_id, t.unsplit_ours,
         case when t.direction = 'credit' and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
              then private.names_our_lot(t.bank_account_id, t.payment_info_id) else false end,
         -- M2c-6b-2c: what « Comptabiliser… » may book it as (the lines to classify and the fees only)
         case when coalesce(p_tab, 'a-classer') not in ('traites', 'doublons')
              then private.transfer_line_bookable_as(t.id) end
  from (select * from pg_temp._dq x
        order by (case when p_tab = 'traites' then x.created_at end) desc nulls last, x.booking_date, x.id
        offset v_offset limit v_limit) t
  left join public.bank_debit_review v on v.bank_transaction_id = t.id
  left join public.bank_debit_link l on l.bank_transaction_id = t.id
  left join public.bank_own_credit_release c on c.bank_transaction_id = t.id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
  order by (case when p_tab = 'traites' then t.created_at end) desc nulls last, t.booking_date, t.id;
end;
$$;


-- « Lier » / « Classer » by ops (public.link_debit, redefined from 20261111090000; same signature and settings, its
-- grants restated below). M2c-6b-2c (plan §4.1; critic F9, L8): « Frais bancaires », « Classer sans comptabiliser » and
-- the refund link are refused when the screen books the line instead (private.link_debit_guard: payout_candidate,
-- client_payout_line, own_transfer_out_line), after the request's shape and before anything is posted. Nothing else
-- changes.
create or replace function public.link_debit(p_idempotency_key text, p_bank_transaction_id uuid, p_kind text,
                                             p_payment_id uuid, p_refund_request_id uuid, p_expected_left_minor text,
                                             p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_out jsonb;
  v_left bigint;
  v_transfer uuid;
  v_guard text;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'kind', p_kind, 'payment_id', p_payment_id,
                                  'refund_request_id', p_refund_request_id, 'expected_left_minor', p_expected_left_minor,
                                  'reason', v_reason);
  v_result := private.command_replay('link_debit', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p_kind is null or p_kind not in ('return', 'refund', 'refund_returned', 'explained', 'fee', 'own_credit', 'loss') then
    raise exception 'debit link refused: bad_request' using errcode = 'check_violation';
  end if;
  if (p_kind in ('return', 'loss')) <> (p_expected_left_minor is not null)
     or (p_expected_left_minor is not null and p_expected_left_minor !~ '^[0-9]{1,16}$')
     or (p_kind in ('return', 'loss')) <> (p_payment_id is not null)
     or (p_kind in ('refund', 'refund_returned')) <> (p_refund_request_id is not null) then
    raise exception 'debit link refused: bad_request' using errcode = 'check_violation';
  end if;
  -- M2c-6b-2c (plan §4.1): never a fee, an explanation or another refund on a line the screen books as ours
  v_guard := private.link_debit_guard(t.id, p_kind, p_refund_request_id);
  if v_guard is not null then
    raise exception 'debit link refused: %', v_guard using errcode = 'check_violation';
  end if;

  if p_kind in ('return', 'refund', 'refund_returned', 'explained') then
    perform private.debit_link_begin();
    insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, refund_request_id, method, decided_by,
                                     reason, expected_left_minor)
    values (1, t.id, p_kind, p_payment_id, p_refund_request_id, 'ops', auth.uid(), v_reason,
            p_expected_left_minor::bigint);
    v_out := private.post_debit_links(t.organization_id, true);
  elsif p_kind = 'loss' then
    v_left := p_expected_left_minor::bigint;
    if v_left >= t.amount_minor then
      raise exception 'debit link refused: not_a_loss' using errcode = 'check_violation';
    end if;
    v_out := '{}';
    if v_left > 0 then
      -- the payment's return of what is left of it (the M2b path: its allocations reversed at the return date)
      perform private.debit_link_begin();
      insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, method, decided_by, reason,
                                       expected_left_minor, amount_minor)
      values (1, t.id, 'return', p_payment_id, 'ops', auth.uid(), v_reason, v_left, v_left);
      v_out := private.post_debit_links(t.organization_id, true);
    elsif not exists (select 1 from private.payment_positions(array[p_payment_id]) x
                      join public.payment p on p.id = x.payment_id
                      where p.organization_id = t.organization_id and p.bank_account_id = t.bank_account_id
                        and x.amount_minor - x.returned_minor = 0) then
      -- nothing is left of the payment (as the page showed): the whole line is the servicer's loss
      raise exception 'debit link refused: payment_changed' using errcode = 'check_violation';
    end if;
    perform private.bank_booking_begin();
    insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, amount_minor, method, decided_by, reason)
    values (1, t.id, 'loss', t.amount_minor - v_left, 'ops', auth.uid(), v_reason);
    v_out := v_out || jsonb_build_object('booking', private.post_bank_bookings(t.organization_id, true));
  else
    -- a credit carrying the TOP id of a pending top-up is that top-up
    if p_kind = 'own_credit' then
      select x.id into v_transfer from public.bank_transfer x
      where x.end_to_end_id = t.end_to_end_id and x.organization_id = t.organization_id and x.kind = 'top_up'
        and x.status = 'ordered';
    end if;
    perform private.bank_booking_begin();
    insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method, decided_by, reason)
    values (1, t.id, case p_kind when 'fee' then 'fee' else 'top_up' end, v_transfer, 'ops', auth.uid(), v_reason);
    v_out := jsonb_build_object('booking', private.post_bank_bookings(t.organization_id, true));
  end if;
  v_result := jsonb_build_object('bank_transaction_id', t.id, 'kind', p_kind, 'result', v_out);
  perform private.command_record('link_debit', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


-- What a line can be linked to (public.debit_link_options, redefined from 20261116090000; same signature and settings,
-- its grants restated below). Review 6b-2c (money-1, money-2): on a debit « Comptabiliser… » books — rule 3b finds a
-- transfer of ours it may be, or it went to a client's confirmed payout IBAN — no payment (« Lier » refuses its return
-- and its loss: private.link_debit_guard), and on any line only the refunds that guard lets through; (round 2) a debit
-- the bank flags as a return keeps its payments, as the guard keeps its return; (round 3) a debit also says the guard's
-- answer for a payment's return (`return_guard`: its code, null when « Lier » takes it), which the page follows on a
-- line « Comptabiliser… » books. Nothing else changes.
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
                                     q.id) is null), '[]'),
    'kind', v_kind);
end;
$$;


------------------------------------------------------------------------------------------
-- The hints reworded now that the screen exists (plan §4.3; critic L15)
------------------------------------------------------------------------------------------

-- private.own_transfer_line_hint, redefined from 20261117090000 (same signature and settings; its grants restated
-- below): the screen ships, so the hint names « Débits et retours » and its actions, else the bank's detail; it gives
-- the link's (private.post_debit_links) and the relay's (public.release_own_credit) too.
create or replace function private.own_transfer_line_hint(p_where text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_where in ('bank_booking', 'debit_link') then
    return 'Cette ligne est un débit ou un retour de nos propres virements (reversement, quote-part du cabinet, lot de '
           'notre fichier) : elle se comptabilise depuis le relevé, automatiquement à l''import ou par l''équipe dans '
           '« Débits et retours » (débit d''un reversement, virement hors reversement, virement au compte propre, '
           'virement revenu) ; sinon elle attend le détail de la banque : prévenez le support. Elle ne se rattache pas '
           'à un paiement et ne se classe pas sans comptabilisation.';
  end if;
  if p_where = 'own_credit' then
    return 'Ce crédit est l''un de nos propres virements qui revient (reversement, quote-part du cabinet, lot de notre '
           'fichier) : il se comptabilise depuis le relevé, automatiquement quand la banque le signale comme un retour, '
           'sinon par l''équipe dans « Débits et retours » (« Virement revenu »), ou il attend le détail de la banque. '
           'Il ne devient jamais le paiement d''un débiteur ni un approvisionnement.';
  end if;
  raise exception 'own_transfer_line_hint: unknown caller %', p_where using errcode = '22023';
end;
$$;

-- private.post_debit_links, redefined from 20261116090000 (same signature, body and settings; its grants restated
-- below): its own_transfer_line hint only, from private.own_transfer_line_hint('debit_link').
create or replace function private.post_debit_links(p_organization_id uuid, p_strict boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_why record;
  r record;
  v_state text;
  v_msg text;
begin
  -- a refund (or its bounce) is the request's payment
  update pg_temp._debit_link l set payment_id = q.payment_id
  from public.refund_request q where q.id = l.refund_request_id and l.payment_id is null;
  analyze pg_temp._debit_link;

  perform 1 from public.account a
  where a.id in (select p.account_id from public.payment p
                 where p.id in (select l.payment_id from pg_temp._debit_link l where l.payment_id is not null))
  order by a.id for key share;
  perform 1 from public.payment p
  where p.id in (select l.payment_id from pg_temp._debit_link l where l.payment_id is not null)
  order by p.id for update;
  perform 1 from public.refund_request q
  where q.payment_id in (select l.payment_id from pg_temp._debit_link l where l.payment_id is not null)
  order by q.id for update;
  perform 1 from public.bank_account b
  where b.id in (select t.bank_account_id from public.bank_transaction t
                 where t.id in (select l.bank_transaction_id from pg_temp._debit_link l))
  order by b.id for share;
  perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  -- M2c: the lines themselves (the lock every decision on a line takes: a booking in private.post_bank_bookings, an
  -- own credit released as a payment; review fix: a line was linked here and booked there at once, each not seeing
  -- the other). After the allocation lock: the job holds it while its funds pass locks lines.
  perform 1 from public.bank_transaction t
  where t.id = any (array(select l.bank_transaction_id from pg_temp._debit_link l))
  order by t.id for no key update;

  -- The facts, read under the locks. free_from: the latest reversal of the payment dated after the entry it reverses
  -- (a return, a refund that bounced, an allocation ops reversed later): until then its money was allocated or out, so
  -- nothing goes out of it before that date (I4; post_allocations' not_before). One keyed lookup per link (laterals
  -- holding only the key).
  drop table if exists pg_temp._dl;
  create temp table _dl on commit drop as
  select l.*, t.organization_id as line_org, t.bank_account_id as line_bank, t.direction, t.currency,
         coalesce(l.amount_minor, t.amount_minor) as line_minor, t.booking_date as line_date,
         coalesce(dr.released_kind, t.kind) as line_kind, t.end_to_end_id as line_e2e,
         coalesce(t.original_end_to_end_id, t.end_to_end_id) as line_returned_id,
         -- review round 5 (Q1): a credit that is one of our transfers coming back (private.names_our_transfer: our
         -- RMT/SWP id as its own or its original, or one of our lots' PmtInfIds with no end-to-end id), and the one
         -- refund such a credit naming our lot may be (the refund that lot held alone, private.pmt_inf_refund_back)
         (t.direction = 'credit'
          and private.names_our_transfer(t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id)) as our_credit,
         -- review round 6 (R2): a credit naming one of our lots on its account (a file handed out), whatever its
         -- end-to-end id (one that is not ours included: outside names_our_transfer's lot arm); the refund that lot held
         -- alone the one it may be, as for a lot with no end-to-end id
         coalesce(t.direction = 'credit' and private.names_our_lot(t.bank_account_id, t.payment_info_id), false)
           as our_lot,
         -- review round 7 (S2): a line of an entry the bank kept unsplit holding a detail of ours, whatever its direction
         coalesce(t.unsplit_ours, 0) > 0 as unsplit_ours_line,
         case when t.direction = 'credit' and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
              then private.pmt_inf_refund_back(t.bank_account_id, t.payment_info_id) end as lot_refund,
         -- M2c-6b-1: a debit with no end-to-end id carrying the PmtInfId of one of our files (a batch line)
         coalesce(t.direction = 'debit' and t.end_to_end_id is null
                  and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
                  and exists (select 1 from public.transfer_file_item i
                              cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                                  where f.id = i.file_id offset 0) f
                              where i.pmt_inf_id = t.payment_info_id and f.debtor_bank_account_id = t.bank_account_id),
                  false) as our_batch_line,
         -- review round 2 (L5, K1 with the switch on): that PmtInf has, in its current file, a member cancelled and not
         -- returned by the bank — the line may be that cancelled transfer's execution (the funds pass's P0,
         -- cancelled_transfer_debited); a refund linked to it would hide it. A transfer the request's own transfer
         -- re-issues is not such a member: the line may be that old file's late execution, which the refund's trigger
         -- answers (reissue_in_downloaded_file: cancel the re-issue's file first; 034's G2)
         coalesce(t.direction = 'debit' and t.end_to_end_id is null
                  and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
                  and exists (select 1 from public.transfer_file_item i
                              cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                                  where f.id = i.file_id offset 0) f
                              cross join lateral (select m.status, m.transfer_file_id from public.bank_transfer m
                                                  where m.id = i.transfer_id offset 0) m
                              where i.pmt_inf_id = t.payment_info_id and f.debtor_bank_account_id = t.bank_account_id
                                and m.transfer_file_id = i.file_id and m.status = 'cancelled'
                                and not private.transfer_return_seen(i.transfer_id)
                                and not exists (
                                  with recursive c (id, n) as (
                                    select x.replaces_transfer_id, 1 from public.bank_transfer x
                                    where x.id = q.transfer_id and x.replaces_transfer_id is not null
                                    union all
                                    select x.replaces_transfer_id, c.n + 1 from c
                                    join public.bank_transfer x on x.id = c.id
                                    where x.replaces_transfer_id is not null and c.n < 32)
                                  select 1 from c where c.id = i.transfer_id)),
                  false) as pmt_inf_cancelled,
         -- the request's transfer in a file handed out to the bank (its PmtInf the only batch line that can execute it)
         coalesce(rt.status = 'in_file' and rf.status in ('downloaded', 'sent'), false) as req_handed_out,
         (t.kind = 'suspected_duplicate' and dr.decision is distinct from 'released') as held,
         exists (select 1 from public.bank_debit_link x where x.bank_transaction_id = l.bank_transaction_id offset 0)
           as linked,
         -- booked in the funds, or an own credit released as a relayed debtor payment
         (exists (select 1 from public.bank_line_booking x where x.bank_transaction_id = l.bank_transaction_id offset 0)
          or exists (select 1 from public.bank_own_credit_release x
                     where x.bank_transaction_id = l.bank_transaction_id offset 0)) as booked,
         p.organization_id as pay_org, p.bank_account_id as pay_bank, p.booking_date as pay_date, p.status as pay_status,
         p.account_id, p.amount_minor as pay_minor, nb.d as free_from,
         q.payment_id as req_payment, q.status as req_status, q.amount_minor as req_minor, q.bank_account_id as req_bank,
         q.cash_out_entry_id as req_entry, q.executed_on as req_executed_on, q.prior_status as req_prior_status,
         q.prior_review_reason as req_prior_reason,
         0::bigint as allocated, 0::bigint as returned, 0::bigint as unallocated, 0::bigint as pending,
         null::text as why, null::uuid as cash_entry_id
  from pg_temp._debit_link l
  left join lateral (select x.organization_id, x.bank_account_id, x.direction, x.currency, x.amount_minor,
                            x.booking_date, x.kind, x.end_to_end_id, x.payment_info_id, x.original_end_to_end_id,
                            x.unsplit_ours
                     from public.bank_transaction x where x.id = l.bank_transaction_id offset 0) t on true
  left join lateral (select x.decision, x.released_kind from public.bank_duplicate_resolution x
                     where x.bank_transaction_id = l.bank_transaction_id offset 0) dr on true
  left join lateral (select x.organization_id, x.bank_account_id, x.booking_date, x.status, x.account_id, x.amount_minor
                     from public.payment x where x.id = l.payment_id offset 0) p on true
  left join lateral (select x.payment_id, x.status, x.amount_minor, x.bank_account_id, x.cash_out_entry_id,
                            x.executed_on, x.prior_status, x.prior_review_reason, x.transfer_id
                     from public.refund_request x where x.id = l.refund_request_id offset 0) q on true
  left join lateral (select x.status, x.transfer_file_id from public.bank_transfer x where x.id = q.transfer_id
                     offset 0) rt on true
  left join lateral (select x.status from public.transfer_file x where x.id = rt.transfer_file_id offset 0) rf on true
  left join lateral (select max(e.effective_date) as d from public.ledger_entry e
                     join public.ledger_entry v on v.id = e.reverses_entry_id
                     where e.payment_id = l.payment_id and e.effective_date > v.effective_date) nb on true;
  update pg_temp._dl d set allocated = x.allocated_minor, returned = x.returned_minor, unallocated = x.unallocated_minor
  from private.payment_positions(array(select l.payment_id from pg_temp._debit_link l where l.payment_id is not null)) x
  where x.payment_id = d.payment_id;
  update pg_temp._dl d set pending = s.total
  from (select q.payment_id, sum(q.amount_minor) as total from public.refund_request q
        where q.payment_id in (select l.payment_id from pg_temp._debit_link l) and q.status = 'requested'
        group by q.payment_id) s
  where s.payment_id = d.payment_id;

  update pg_temp._dl d set why = case
    when d.line_org is distinct from p_organization_id then 'line_unknown'
    when d.linked then 'already_linked'
    when d.booked then 'already_booked'
    -- a part of a line (M2c: the return of what is left of a payment, its excess the servicer's loss) is ops' only
    when d.amount_minor is not null and (d.method <> 'ops' or d.kind <> 'return' or d.amount_minor <= 0) then 'bad_request'
    when d.held then 'held_duplicate'
    -- M2c-6b-1 (plan §2.4 rule 5 [critic]; review money-1): our payouts' and sweeps' lines — a debit carrying our
    -- RMT/SWP id, a batch line of one of our files (whatever kind the bank's statement gives it), a credit returning one
    -- of them — are only ever booked (private.post_bank_bookings: the job, or ops in M2c-6b-2), never a payment's
    -- return (nor its loss), a refund, a refund that came back or an explanation: one person's link would hide the
    -- payouts' debits, their returns' items and the P0 alerts (cancelled_transfer_debited, transfer_not_handed_out).
    -- The one link a batch line takes: a refund whose transfer is in a file handed out to the bank (downloaded or sent)
    -- — the refund a PmtInf of one refund alone is (private.pmt_inf_single_refund, the M2b pass's), or ops' link of a
    -- refund of a PmtInf of refunds — which private.refund_transfer_follow (M2c-6a round 6's G2 rule) then executes
    -- only by a batch line of its own PmtInf in that file, refusing any other (reissue_in_downloaded_file); never a
    -- manual refund (no transfer), nor one whose transfer is not handed out (nothing the bank could have debited).
    -- Review round 2: a line whose own or original id is one of ours, whatever its direction and kind (L4: a debit
    -- « return » naming our RMT id as its original included); and the refund exception only while its PmtInf has no
    -- member cancelled and not returned in its current file (L5: with the cancellation after download on, the line may
    -- be that cancelled transfer's debit — the funds pass reviews it cancelled_transfer_debited).
    -- Review round 5 (Q1, round 4's N1 residual): a credit that is one of our transfers coming back, as every refusal
    -- reads it (private.names_our_transfer) — a credit naming one of our lots with no end-to-end id included, which the
    -- import reads as a `return` since round 4 — whatever the link kind; its one exception (COMPLIANCE OQ-84's
    -- default): « Remboursement revenu » of the refund that lot held alone (private.pmt_inf_refund_back: a file-mode
    -- refund alone in its PmtInf, executed, coming back with only its lot's reference). Before, such a credit took any
    -- executed refund of its amount (that refund's payment then holding our lot's money, assignable to a debtor's file)
    -- and « Classer sans comptabiliser ». Review round 6 (R2, verdict new:tf-lot-credit-with-foreign-e2e): so is a
    -- credit naming one of our lots on its account (private.names_our_lot: a file handed out) whatever its end-to-end id
    -- — the round-5 verifier's n30, a payouts' lot with VIR-X-0030, took an unrelated refund and the explanation; whether
    -- a bank returns our lot's transfer with our PmtInfId but another end-to-end id is unknown (COMPLIANCE OQ-84) — with
    -- the same one exception.
    -- Review round 7 (S2, verdict new:debit-entry-unsplit-with-our-details-explainable): a line read from a camt.053 entry
    -- the bank kept unsplit holding a detail of ours (unsplit_ours > 0), whatever its direction and kind, takes no link
    -- at all, the explanation included, with no exception — the verifier's d01 (our payout's return netted into an
    -- outgoing debit), d02, d03 (two debits of ours in one debit entry) took « Classer sans comptabiliser », which hid
    -- our transfers from the funds for good (private.bank_unposted). It waits for ops' booking (M2c-6b-2; COMPLIANCE
    -- OQ-84 (h)); the funds pass reviews it
    when d.unsplit_ours_line then 'own_transfer_line'
    when ((coalesce(d.line_e2e ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or coalesce(d.line_returned_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false) or d.our_batch_line)
          and not (d.kind = 'refund' and d.our_batch_line and d.req_handed_out and not d.pmt_inf_cancelled))
         or ((coalesce(d.our_credit, false) or d.our_lot)
             and not (d.kind = 'refund_returned' and d.lot_refund is not null
                      and d.refund_request_id is not distinct from d.lot_refund))
      then 'own_transfer_line'
    -- our own transfers out and the credits from our own account or a client are never a payment's return, refund or
    -- refund that came back (whatever payment or request is named)
    when d.kind <> 'explained' and d.line_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
      then 'not_a_return'
    when d.kind = 'explained' then case
      when d.payment_id is not null or d.refund_request_id is not null then 'bad_request'
      when d.direction = 'credit' and d.line_kind in ('debtor_credit', 'batch_unsplit') then 'payment_line'
      -- money that went back out for one of our payments is booked, never only explained: our refund (RFD id), or a
      -- return whose references name a payment of this bank account (end-to-end id, or the bank transaction id of the
      -- credit it takes back). The line waits in « À classer » (and the ageing alert) until it is linked (I9; review
      -- fix: a chargeback larger than what is left of its payment is never hidden as an explained gap, OQ-34). A
      -- return naming nothing of ours (e.g. a fee's direct debit the bank rejected) is explained with a motif.
      when d.direction = 'debit' and d.line_kind = 'refund_out' then 'not_explainable'
      -- (our payouts' and sweeps' lines: own_transfer_line above, whatever the kind)
      when d.direction = 'debit' and d.line_kind = 'return' and exists (
             select 1 from public.bank_transaction x
             where x.id = d.bank_transaction_id
               and (exists (select 1 from public.payment p
                            where p.end_to_end_id = coalesce(x.original_end_to_end_id, x.end_to_end_id)
                              and p.bank_account_id = x.bank_account_id)
                    or (x.tx_id is not null
                        and exists (select 1 from public.bank_transaction o join public.payment p on p.bank_transaction_id = o.id
                                    where o.bank_account_id = x.bank_account_id and o.tx_id = x.tx_id
                                      and o.direction = 'credit')))) then 'not_explainable'
      when nullif(btrim(d.reason), '') is null then 'reason_required' end
    when d.pay_org is distinct from p_organization_id then 'payment_unknown'
    when d.pay_bank is distinct from d.line_bank then 'other_bank_account'
    when d.kind = 'return' then case
      when d.direction <> 'debit' or d.line_kind not in ('return', 'refund_out', 'other_debit') then 'not_a_return'
      when d.refund_request_id is not null then 'bad_request'
      when d.pay_status = 'returned' then 'already_returned'
      when d.line_date < d.pay_date then 'before_payment'
      when d.line_date < d.free_from then 'before_previous_return'
      -- the job links exactly what is left (payments.debits): anything else, the payment changed since it read it
      when d.method = 'auto' and d.line_minor <> d.pay_minor - d.returned then 'payment_changed'
      when d.line_minor > d.pay_minor - d.returned then 'amount_exceeds'
      when d.line_minor < d.pay_minor - d.returned and d.pending > 0 then 'refund_pending'  -- partial: cancel it first
      when d.method = 'ops' and d.expected_left_minor is distinct from d.pay_minor - d.returned then 'payment_changed' end
    when d.kind = 'refund' then case
      when d.direction <> 'debit' or d.line_kind not in ('refund_out', 'other_debit', 'return', 'batch_unsplit')
        then 'not_a_refund'
      -- M2c-6b-1: a batch line kept unsplit is a refund only as one of our PmtInfs (of one refund alone)
      when d.line_kind = 'batch_unsplit' and not d.our_batch_line then 'not_a_refund'
      when d.req_status is distinct from 'requested' or d.req_payment is distinct from d.payment_id then 'refund_not_pending'
      when d.req_bank is distinct from d.line_bank then 'other_bank_account'
      when d.line_minor <> d.req_minor then 'amount_differs'
      when d.line_date < d.pay_date then 'before_payment'
      when d.line_date < d.free_from then 'before_previous_return'
      when d.line_minor > d.unallocated then 'amount_exceeds' end
    when d.kind = 'refund_returned' then case
      when d.direction <> 'credit' or d.line_kind <> 'return' then 'not_a_refund_return'
      when d.req_status is distinct from 'executed' or d.req_payment is distinct from d.payment_id then 'refund_not_executed'
      -- the bank took the payment back after the refund: where the money that came back goes is not decided (OQ)
      when d.pay_status = 'returned' then 'payment_returned'
      when d.line_minor <> d.req_minor then 'amount_differs'
      when d.line_date < d.req_executed_on then 'before_refund' end
  end
  where d.bank_transaction_id is not null;  -- (every row: PostgREST sessions refuse an UPDATE without WHERE)
  -- one link per payment per call (a later one waits for the next run)
  update pg_temp._dl d set why = 'payment_twice'
  where d.why is null and d.payment_id is not null
    and exists (select 1 from pg_temp._dl o where o.payment_id = d.payment_id and o.why is null and o.ord < d.ord);
  select d.why, d.bank_transaction_id into v_why from pg_temp._dl d where d.why is not null order by d.ord limit 1;
  if found and p_strict then
    if v_why.why = 'own_transfer_line' then
      raise exception 'debit link refused: %', v_why.why using errcode = 'check_violation',
        hint = private.own_transfer_line_hint('debit_link');
    end if;
    raise exception 'debit link refused: %', v_why.why using errcode = 'check_violation';
  end if;
  insert into pg_temp._debit_skipped (bank_transaction_id, why)
  select d.bank_transaction_id, d.why from pg_temp._dl d where d.why is not null
  on conflict (bank_transaction_id) do update set why = excluded.why;
  delete from pg_temp._dl d where d.why is not null;
  analyze pg_temp._dl;

  if p_strict then
    begin
      perform private.debit_post_rows(p_organization_id);
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      if v_state like 'LG%' or v_state like '22%' or v_state like '23%' then
        raise exception 'debit link refused: posting_failed (%: %)', v_state, left(v_msg, 500)
          using errcode = 'check_violation';
      end if;
      raise;
    end;
  elsif exists (select 1 from pg_temp._dl) then
    begin
      perform private.debit_post_rows(p_organization_id);   -- the whole chunk at once
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
        raise;  -- not the data's doing (a lock, the machine): the queue retries the run
      end if;
      -- A link the posting refuses (the chunk's subtransaction rolled back): each link is tried on its own in a
      -- subtransaction that is always rolled back (a try leaves nothing, not even its locks: the posting's working
      -- tables would otherwise hold some until commit, for every link); the ones refused go to ops, then the others
      -- are posted together (one link per payment: each posts as it did alone).
      drop table if exists pg_temp._dl_all;
      create temp table _dl_all on commit drop as select * from pg_temp._dl;
      create index on pg_temp._dl_all (ord);
      for r in select a.ord, a.bank_transaction_id, a.payment_id, a.refund_request_id from pg_temp._dl_all a
               order by a.ord loop
        begin
          delete from pg_temp._dl d where d.bank_transaction_id is not null;
          insert into pg_temp._dl select * from pg_temp._dl_all a where a.ord = r.ord;
          perform private.debit_post_rows(p_organization_id);
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
          raise exception 'debit link tried' using errcode = 'DL000';   -- posts on its own: undo the try
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
          if v_state <> 'DL000' then
            if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
              raise;
            end if;
            insert into pg_temp._debit_failed (bank_transaction_id, candidates, detail)
            values (r.bank_transaction_id,
                    jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('payment_id', r.payment_id,
                                                                           'refund_request_id', r.refund_request_id))),
                    left(v_state || ': ' || v_msg, 2000))
            on conflict (bank_transaction_id) do nothing;
          end if;
        end;
      end loop;
      delete from pg_temp._dl d where d.bank_transaction_id is not null;
      insert into pg_temp._dl select * from pg_temp._dl_all a
      where not exists (select 1 from pg_temp._debit_failed f where f.bank_transaction_id = a.bank_transaction_id);
      if exists (select 1 from pg_temp._dl) then
        perform private.debit_post_rows(p_organization_id);
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
      end if;
    end;
  end if;

  return jsonb_build_object(
    'returns', (select count(*) from pg_temp._dl where kind = 'return'),
    'refunds', (select count(*) from pg_temp._dl where kind = 'refund'),
    'refunds_returned', (select count(*) from pg_temp._dl where kind = 'refund_returned'),
    'explained', (select count(*) from pg_temp._dl where kind = 'explained'),
    'skipped', (select count(*) from pg_temp._debit_skipped),
    'failed', (select count(*) from pg_temp._debit_failed));
end;
$$;


-- public.release_own_credit, redefined from 20261116090000 (same signature, body and settings; its grants restated
-- below): its own_transfer_line hint only, from private.own_transfer_line_hint('own_credit').
create or replace function public.release_own_credit(p_idempotency_key text, p_bank_transaction_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
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
  if t.direction <> 'credit' or v_kind not in ('own_transfer_in', 'client_transfer_in') or v_held then
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
  v_payment := private.book_credit_payment(t.id, 'other',
                                           case v_kind when 'client_transfer_in' then 'Versement relayé par le client'
                                                       else 'Versement relayé par le cabinet' end, null, 'no_match');
  delete from public.bank_debit_review v where v.bank_transaction_id = t.id;
  v_result := jsonb_build_object('payment_id', v_payment, 'status', 'unmatched');
  perform private.command_record('release_own_credit', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


------------------------------------------------------------------------------------------
-- Reads for the run page, « Virements » and the client space (plan §4.4; critic CSO-9, CSO-6, L6; critic2 ML-12)
------------------------------------------------------------------------------------------

-- What became of a run's payout (the run page): its transfers — the run's chain, run.transfer_id then each transfer it
-- re-issues (private.transfer_chain) — with their status, the date and line of their debit and of their return (and,
-- for a returned payout paid again, the number of the booked run that paid it: repaid_by); whether
-- the run's payout account is blocked now (status returned: a return marked it, until it is replaced or reconfirmed); the
-- run's set-off (its client_settlement entry's date, D, Dc, Da); the servicer's advances at their debit (payout_overrun:
-- what the payout went beyond the client's due), with what is still open; the unplanned bookings of its transfers
-- (their line, amount, date, P and the advance; after_cancellation when the transfer was cancelled); for a draft, the
-- unplanned bookings whose rows it holds and what it deducts of each (critic CSO-6: the durable reason it changed, never
-- last_failure; review 6b-2c money-4: the −A row with its advance's +(A − P) row, P — none when P = 0) with the line
-- and the statement they come from. Money staff of the run's servicer at aal2 only
-- (another servicer's staff, a client member, a collector, an aal1 session: null). Keyed: the run, its chain, each
-- transfer's bookings by bank_line_booking_transfer_idx, each entry's advance by client_advance_cause_idx, the draft's
-- pending rows by remittance_pending_run_idx. Amounts as text.
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
               'return_line_id', rt.line_id, 'repaid_by', p.number) order by c.depth), '[]')
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
      left join lateral (select l.booking_date, l.id as line_id
                         from (select k.bank_transaction_id, k.kind from public.bank_line_booking k
                               where k.transfer_id = x.id offset 0) k
                         cross join lateral (select q.id, q.booking_date from public.bank_transaction q
                                             where q.id = k.bank_transaction_id offset 0) l
                         where k.kind in ('payout_returned', 'sweep_returned')
                         order by l.booking_date limit 1) rt on true
      -- a returned payout paid again: the booked run whose live line holds the payout_returned item its return put
      -- back (as client_remittance_summary's repaid_by)
      left join lateral (select y.number
                         from (select l.run_id from public.remittance_line l
                               where l.ledger_entry_id = x.return_entry_id and not l.released
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
      cross join lateral (select y.entry_id from public.bank_transfer y where y.id = c.transfer_id offset 0) x
      cross join lateral (select q.* from public.client_advance q
                          where q.cause_entry_id = x.entry_id and q.cause = 'payout_overrun' offset 0) a
      left join lateral (select sum(z.amount_minor) as settled from public.commission_settlement z
                         where z.document_kind = 'advance' and z.document_id = a.id) s on true),
    'unplanned', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'line_id', k.bank_transaction_id, 'kind', k.kind, 'amount_minor', k.amount_minor::text,
               'on', l.booking_date, 'paid_minor', (k.amount_minor - coalesce(a.amount_minor, 0))::text,
               'advance_minor', coalesce(a.amount_minor, 0)::text, 'after_cancellation', x.status = 'cancelled',
               'returned', exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id))
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

-- What « Virements » says of each transfer it lists (plan §4.4): the date and line of its debit and of its return as
-- booked from the statement, and, for a transfer the bank executed outside its run (an unplanned booking: a cancelled
-- payout executed all the same, a second execution), the date of the first such booking. At most 500 ids a call; only
-- the transfers of the caller's servicers (money staff at aal2, private.money_staff_org_ids()) — other ids are ignored,
-- with nothing said about them. Keyed: each transfer by its key, its bookings by bank_line_booking_transfer_idx.
create or replace function public.transfer_bookings(p_transfer_ids uuid[])
returns table (transfer_id uuid, debited_on date, returned_on date, debit_line_id uuid, return_line_id uuid,
               unplanned_on date)
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
begin
  if coalesce(cardinality(p_transfer_ids), 0) > 500 then
    raise exception 'transfer bookings refused: too_many_ids' using errcode = 'check_violation';
  end if;
  return query
  select x.id, d.booking_date, rt.booking_date, d.line_id, rt.line_id, u.unplanned_on
  from (select distinct i.id from unnest(coalesce(p_transfer_ids, '{}'::uuid[])) i (id) where i.id is not null) i
  cross join lateral (select y.id, y.organization_id from public.bank_transfer y where y.id = i.id offset 0) x
  left join lateral (select l.booking_date, l.id as line_id
                     from (select k.bank_transaction_id, k.kind from public.bank_line_booking k
                           where k.transfer_id = x.id offset 0) k
                     cross join lateral (select q.id, q.booking_date from public.bank_transaction q
                                         where q.id = k.bank_transaction_id offset 0) l
                     where k.kind in ('payout', 'sweep')
                     order by l.booking_date limit 1) d on true
  left join lateral (select l.booking_date, l.id as line_id
                     from (select k.bank_transaction_id, k.kind from public.bank_line_booking k
                           where k.transfer_id = x.id offset 0) k
                     cross join lateral (select q.id, q.booking_date from public.bank_transaction q
                                         where q.id = k.bank_transaction_id offset 0) l
                     where k.kind in ('payout_returned', 'sweep_returned')
                     order by l.booking_date limit 1) rt on true
  left join lateral (select min(l.booking_date) as unplanned_on
                     from (select k.bank_transaction_id, k.kind from public.bank_line_booking k
                           where k.transfer_id = x.id offset 0) k
                     cross join lateral (select q.booking_date from public.bank_transaction q
                                         where q.id = k.bank_transaction_id offset 0) l
                     where k.kind in ('unplanned_payout', 'unplanned_sweep')) u on true
  where x.organization_id = any (private.money_staff_org_ids());
end;
$$;


-- What the client space shows (public.client_remittance_summary, redefined from 20261116090000; same signature and
-- settings, its grants restated below). M2c-6b-2c (plan §4.4; critic L6, critic2 ML-12): `unplanned_runs`, the client's
-- cancelled runs any of whose transfers — the run's chain, run.transfer_id then each transfer it re-issues — the bank
-- executed all the same (an unplanned payout booking), with the date of the first such booking: the client space says
-- « Annulé — la banque a néanmoins exécuté son virement le … » in place of « Annulé avant la remise de son virement à la
-- banque », which would be false. Same rights (whole-client members, the servicer's money staff). Keyed: the client's
-- cancelled runs, each chain by key, each transfer's bookings by bank_line_booking_transfer_idx. Nothing else changes.
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
  select coalesce(jsonb_agg(jsonb_build_object('run_id', r.id, 'returned_on', x.returned_on,
                                               'amount_minor', t.amount_minor::text, 'repaid_by', p.number)
                            order by x.returned_on, r.number), '[]')
  into v_returned
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
  where r.client_organization_id = c.id and r.transfer_id is not null and t.status = 'returned';
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
  return jsonb_build_object('owed', v_owed, 'in_flight', v_flight, 'returned_runs', v_returned,
                            'unplanned_runs', v_unplanned,
                            'next_run_day', private.next_scheduled_run_day(c.id, v_today + 1),
                            'today', v_today);
end;
$$;


------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new internals revoked, the new reads the back office's)
------------------------------------------------------------------------------------------

-- the new internals (PostgreSQL grants EXECUTE to PUBLIC by default): only the SECURITY DEFINER callers use them
revoke execute on function private.transfer_debit_bound_days(), private.transfer_chain(uuid),
  private.transfer_line_options_of(uuid), private.transfer_line_offers(uuid, uuid),
  private.transfer_debit_suppression(uuid, date, date), private.transfer_line_bookable_as(uuid),
  private.transfer_line_queue_reason(uuid), private.link_debit_guard(uuid, text, uuid),
  private.remittance_run_late_on(uuid, date)
  from public, anon, authenticated, service_role;
-- the redefined internals: as granted by 20261117100000 (private.transfer_line_parts_json,
-- private.transfer_line_candidates, and private.transfer_line_check: review 6b-2c), 20261117090000
-- (private.own_transfer_line_hint, private.run_transfer_checks) and 20261116090000 (private.post_debit_links,
-- private.transfer_debit_may_be_seen, private.run_remittance_runs_checks: called by the SECURITY DEFINER checks only)
revoke execute on function private.transfer_line_parts_json(), private.transfer_line_candidates(uuid, text),
  private.transfer_line_check(uuid, boolean), private.post_debit_links(uuid, boolean),
  private.transfer_debit_may_be_seen(uuid, date), private.run_remittance_runs_checks(uuid, uuid, date),
  private.run_transfer_checks(uuid, uuid, date)
  from public, anon, authenticated, service_role;
revoke execute on function private.own_transfer_line_hint(text) from public, anon, authenticated;
-- the back office's commands and reads (aal2 money staff or whole-client members, checked inside), as granted by
-- 20261110120000 (public.link_debit), 20261116090000 (public.debit_queue, public.release_own_credit,
-- public.client_remittance_summary, public.debit_link_options: review 6b-2c) and 20261117100000
-- (public.transfer_line_options); the two new reads alike
revoke execute on function public.link_debit(text, uuid, text, uuid, uuid, text, text),
  public.debit_queue(text, integer, integer), public.release_own_credit(text, uuid, text),
  public.client_remittance_summary(uuid), public.transfer_line_options(uuid), public.remittance_run_payout(uuid),
  public.transfer_bookings(uuid[]), public.debit_link_options(uuid)
  from public, anon;
grant execute on function public.link_debit(text, uuid, text, uuid, uuid, text, text),
  public.debit_queue(text, integer, integer), public.release_own_credit(text, uuid, text),
  public.client_remittance_summary(uuid), public.transfer_line_options(uuid), public.remittance_run_payout(uuid),
  public.transfer_bookings(uuid[]), public.debit_link_options(uuid)
  to authenticated;
