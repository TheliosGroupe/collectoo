-- M2c-7a « remitted reversals covered everywhere, and the backstop » (plan docs/design/m2c-7-plan.md §0, §2, §3; design
-- docs/design/m2c-remittances.md §7.2, §13; ADR-0014 « M2c-7a »). Forward-only.
--
-- Design §13 #1, as built: a reversal R of an allocation or a forward E already remitted to its client — E is a live line
-- of a booked run that does not also hold R (a same-run pair nets to 0 there and was never paid out, [critic]
-- M7-MONEY-1) — is advanced by the servicer (client_advance, cause remitted_reversal: +4679 A / −4670[c] A ‖ +4112[c] A
-- / −4689 A) in the transaction that posts R, so the client's other collections stay owed in full: no reversal of a
-- remitted item is ever netted against them (C. civ. 1993; the compensation design §13 excludes). With the switch on,
-- an item an unplanned payout paid is covered for that part (OQ-82's residual), and the cover goes when that payout
-- comes back (D4). Its target T(R), its cover C(R) and I23 (C(R) = T(R)) are plan §2.1's.
--
-- New: private.run_settled_at / run_settled_on ([check 1] [check 2]), private.entry_remitted (M3c-2's predicate),
-- private.remitted_cover_fact / _held / _target / _gap, private.remitted_cover_begin / _post,
-- private.cover_remitted_reversals (at the reversal), private.cover_booked_run_reversals (at the booking: D2),
-- private.advance_in_flight_run ([critic] M7-MONEY-2), private.remitted_cover_release (the unplanned return),
-- the deferred constraint triggers ledger_entry_remitted_cover and remittance_run_booked_cover (SQLSTATE LG009: I23 at
-- every commit, D3), private.run_advance_checks (remitted_reversal_uncovered — delta window and full pass —,
-- advance_ledger, advance_open), private.advance_full_check_request with private.advance_full_check_take and
-- public.request_full_advance_check ([check 2]), public.cover_remitted_reversal (« Couvrir »), public.allocation_remitted
-- (the « Désimputer » read); three indexes for the nightly's keyed reads.
-- Redefined, each copied whole from its latest definition across every migration file (the change only, its settings,
-- search_path '' and grants restated): private.ledger_check_now (20261111090000:1335), public.reverse_allocation
-- (20261109190000:1079), private.debit_post_rows (20261110120000:549), private.approve_remittance_run
-- (20261114090000:786), private.run_remittance_checks (20261115090000:3710), private.transfer_line_post
-- (20261118100000:2163), private.bank_booking_post_rows (20261121090000:808), public.remittance_run_payout
-- (20261118100000:4380).
-- The cancellation-after-download switch stays off: nothing here writes private.feature_switch.

------------------------------------------------------------------------------------------
-- The nightly's keyed reads (plan §3.4 [critic] F9): the day's reversals, the runs booked since, the attributions since
------------------------------------------------------------------------------------------

create index ledger_entry_reversal_posted_idx on public.ledger_entry (organization_id, posted_at)
  where entry_type = 'reversal';
create index remittance_run_booked_idx on public.remittance_run (organization_id, booked_on) where status = 'booked';
create index unplanned_paid_item_org_idx on private.unplanned_paid_item (organization_id, created_at);

------------------------------------------------------------------------------------------
-- What a run settled, and when (plan §3.2.1 [check 1] [check 2])
------------------------------------------------------------------------------------------

-- The date a booked run's items reached the client, how, and through which run: (1) a run not booked → no row; (2) a
-- run with a transfer whose chain paid the client and stayed paid (private.remittance_chain_paid, as
-- private.remittance_run_paid_on reads it) → that date, « paid », its number; a chain none of whose transfers came back
-- on the statements → the run's booked_on (its payout's debit), « paid »; (3) a chain that stayed unpaid after a return: the chain's returns, read from its bookings (bank_line_booking
-- of kind payout_returned of a transfer of the chain — a late predecessor that came back keeps no return_entry_id, the
-- switch on), each followed through its re-queued item's live line in a booked run Y: when every one has a row, the
-- latest; else no row; (4) an N = 0 run (no transfer, booked at approval): its live unplanned_payout lines whose
-- booking came back (reversed) followed the same way; none came back → its booked_on, « set_off » when it set off
-- something (settlement_minor > 0), else « netted » (its lines netted to nothing). Recursion bounded at depth 10:
-- deeper, a row with too_deep (private.run_settled_on gives no row; the nightly's advance_open says
-- settled_on_depth). Keyed: the run, its chain's bookings by bank_line_booking_transfer_idx, each re-queued item's line
-- by remittance_line_live_uq, an N = 0 run's lines by its primary key prefix.
create or replace function private.run_settled_at(p_run_id uuid, p_depth integer)
returns table (on_date date, how text, run_number text, too_deep boolean)
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  r record;
  v_paid date;
  v_returned boolean;
  v_rev uuid;
  v_y uuid;
  s record;
  v_any boolean := false;
  v_all boolean := true;
  v_deep boolean := false;
  v_date date;
  v_how text;
  v_num text;
begin
  if p_depth > 10 then
    return query select null::date, null::text, null::text, true;
    return;
  end if;
  select q.status, q.transfer_id, q.booked_on, q.number, q.settlement_minor into r
  from public.remittance_run q where q.id = p_run_id;
  if not found or r.status <> 'booked' then
    return;
  end if;
  if r.transfer_id is not null then
    select c.paid_on, c.returned into v_paid, v_returned from private.remittance_chain_paid(r.transfer_id) c;
    if v_paid is not null then
      return query select v_paid, 'paid'::text, r.number, false;
      return;
    end if;
    -- nothing of the chain came back on the statements: the debit that booked the run paid the client (a debit the
    -- chain rule does not count — dated before its transfer's requested execution date — is still that payout)
    if not coalesce(v_returned, false) then
      return query select r.booked_on, 'paid'::text, r.number, false;
      return;
    end if;
  end if;
  for v_rev in
    select k.entry_id
    from (select c.transfer_id from private.transfer_chain(r.transfer_id) c offset 0) c
    cross join lateral (select b.entry_id from public.bank_line_booking b
                        where b.transfer_id = c.transfer_id and b.kind = 'payout_returned' offset 0) k
    where r.transfer_id is not null
    union all
    select z.id
    from (select l.ledger_entry_id from public.remittance_line l
          where l.run_id = p_run_id and l.kind = 'unplanned_payout' and not l.released offset 0) l
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = l.ledger_entry_id offset 0) z
    where r.transfer_id is null
  loop
    v_any := true;
    v_y := null;
    select l.run_id into v_y
    from (select q.run_id from public.remittance_line q where q.ledger_entry_id = v_rev and not q.released offset 0) l
    cross join lateral (select x.status from public.remittance_run x where x.id = l.run_id offset 0) x
    where x.status = 'booked';
    if v_y is null then
      v_all := false;
      continue;
    end if;
    select * into s from private.run_settled_at(v_y, p_depth + 1) limit 1;
    if not found then
      v_all := false;
    elsif s.too_deep then
      v_deep := true;
    elsif v_date is null or s.on_date > v_date then
      v_date := s.on_date;
      v_how := s.how;
      v_num := s.run_number;
    end if;
  end loop;
  if v_deep then
    return query select null::date, null::text, null::text, true;
    return;
  end if;
  if not v_any then
    if r.transfer_id is null then
      return query select r.booked_on, case when coalesce(r.settlement_minor, 0) > 0 then 'set_off' else 'netted' end,
                          r.number, false;
    end if;
    return;
  end if;
  if v_all then
    return query select v_date, v_how, v_num, false;
  end if;
end;
$$;

create or replace function private.run_settled_on(p_run_id uuid)
returns table (on_date date, how text, run_number text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select s.on_date, s.how, s.run_number from private.run_settled_at(p_run_id, 0) s where not s.too_deep;
$$;

-- An entry remitted to its client (design §13 #1, plan §2.1 [critic] M7-MONEY-1): its live line (remittance_line_live_uq)
-- in a booked run, unless p_reversal_id — its reversal — is a live line of that same run (a same-run pair nets to 0 in
-- it: never paid out). With what that run settled and when (private.run_settled_on, [check 1]). The predicate M3c-2
-- calls (m3 §10 #7 (e)).
create or replace function private.entry_remitted(p_entry_id uuid, p_reversal_id uuid default null)
returns table (run_id uuid, run_number text, amount_minor bigint, mandate_id uuid, booked_on date, paid_on date,
               paid_how text, paid_run_number text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select l.run_id, x.number, l.amount_minor, l.mandate_id, x.booked_on, s.on_date, s.how, s.run_number
  from (select q.run_id, q.amount_minor, q.mandate_id from public.remittance_line q
        where q.ledger_entry_id = p_entry_id and not q.released offset 0) l
  cross join lateral (select x.number, x.status, x.booked_on from public.remittance_run x where x.id = l.run_id offset 0) x
  left join lateral (select y.on_date, y.how, y.run_number from private.run_settled_on(l.run_id) y limit 1) s on true
  where x.status = 'booked'
    and (p_reversal_id is null
         or not exists (select 1 from public.remittance_line z
                        where z.ledger_entry_id = p_reversal_id and not z.released and z.run_id = l.run_id));
$$;

------------------------------------------------------------------------------------------
-- The target, the cover, the gap (plan §2.1, §3.2.2): I23, C(R) = T(R)
------------------------------------------------------------------------------------------

-- The facts of a reversal R of an entry E: T(R) — E's line when E is remitted (live in a booked run that does not also
-- hold R), else what the live unplanned payouts paid of E (their attributions whose booking is not reversed; the switch
-- on), 0 for a reversal of anything but an allocation or a forward —, C(R) — R's live covers (client_advance of cause
-- remitted_reversal whose entry is not reversed) —, and what a cover posts with: E's client, its 4670 currency, the
-- mandate (E's line's, else its file's: portfolio.mandate_id; none for a forward on no file), the date of the payout it
-- covers (the run's booked_on, or the latest attributing booking's), the run and, with p_transfer, the run's payout
-- transfer (its chain's payout booking). Keyed reads only.
create or replace function private.remitted_cover_fact(p_reversal_id uuid, p_transfer boolean default false)
returns table (organization_id uuid, client_organization_id uuid, currency char(3), target bigint, held bigint,
               mandate_id uuid, payout_on date, run_id uuid, transfer_id uuid, reversal_date date)
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  r record;
  e record;
  l record;
  x record;
  v_att bigint;
  v_att_on date;
begin
  select q.organization_id, q.entry_type, q.reverses_entry_id, q.effective_date into r
  from public.ledger_entry q where q.id = p_reversal_id;
  if not found or r.entry_type <> 'reversal' then
    return;
  end if;
  select q.id, q.entry_type, q.client_organization_id, q.portfolio_id into e
  from public.ledger_entry q where q.id = r.reverses_entry_id;
  organization_id := r.organization_id;
  client_organization_id := e.client_organization_id;
  reversal_date := r.effective_date;
  target := 0;
  held := private.remitted_cover_held(p_reversal_id);
  select la.currency into currency
  from (select p.ledger_account_id from public.ledger_posting p where p.entry_id = e.id offset 0) p
  cross join lateral (select a.currency, a.book from public.ledger_account a where a.id = p.ledger_account_id offset 0) la
  where la.book = 'client_payable' limit 1;
  if e.entry_type not in ('allocation', 'forward') then
    return next;
    return;
  end if;
  mandate_id := (select pf.mandate_id from public.portfolio pf where pf.id = e.portfolio_id);
  select q.run_id, q.amount_minor, q.mandate_id, q.currency into l
  from public.remittance_line q where q.ledger_entry_id = e.id and not q.released;
  if found then
    mandate_id := coalesce(l.mandate_id, mandate_id);
    currency := coalesce(currency, l.currency);
    select q.status, q.booked_on, q.transfer_id into x from public.remittance_run q where q.id = l.run_id;
    if x.status = 'booked'
       and not exists (select 1 from public.remittance_line z
                       where z.ledger_entry_id = p_reversal_id and not z.released and z.run_id = l.run_id) then
      target := l.amount_minor;
      payout_on := x.booked_on;
      run_id := l.run_id;
      if p_transfer and x.transfer_id is not null then
        select k.transfer_id into transfer_id
        from (select c.transfer_id from private.transfer_chain(x.transfer_id) c offset 0) c
        cross join lateral (select b.transfer_id from public.bank_line_booking b
                            where b.transfer_id = c.transfer_id and b.kind = 'payout' offset 0) k
        limit 1;
      end if;
      return next;
      return;
    end if;
  end if;
  select coalesce(sum(u.amount_minor), 0), max(b.effective_date) into v_att, v_att_on
  from (select y.booking_entry_id, y.amount_minor from private.unplanned_paid_item y
        where y.ledger_entry_id = e.id offset 0) u
  cross join lateral (select q.effective_date from public.ledger_entry q where q.id = u.booking_entry_id offset 0) b
  where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = u.booking_entry_id);
  target := v_att;
  payout_on := v_att_on;
  return next;
end;
$$;

-- C(R): R's covers whose entry is not reversed (client_advance_cause_idx, then each entry's reversal by key)
create or replace function private.remitted_cover_held(p_reversal_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(sum(a.amount_minor), 0)::bigint
  from (select q.amount_minor, q.entry_id from public.client_advance q
        where q.cause_entry_id = p_reversal_id and q.cause = 'remitted_reversal' offset 0) a
  where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id);
$$;

-- T(R). M3c-2 redefines this one for a restatement group (net of the re-posted allocation), never the other two.
create or replace function private.remitted_cover_target(p_reversal_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce((select f.target from private.remitted_cover_fact(p_reversal_id) f), 0)::bigint;
$$;

-- gap(R) = T(R) − C(R): I23 holds when it is 0
create or replace function private.remitted_cover_gap(p_reversal_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select private.remitted_cover_target(p_reversal_id) - private.remitted_cover_held(p_reversal_id);
$$;

------------------------------------------------------------------------------------------
-- Posting covers (plan §3.2.3–§3.2.5, §2.1 keys and dates)
------------------------------------------------------------------------------------------

-- The covers to post, one row each (dense n from 1). Dropped first: the debit job's per-link tries, the chunk loop and
-- a release followed by a re-post begin it several times in one transaction ([critic] F18).
create or replace function private.remitted_cover_begin()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._rcv;
  create temp table _rcv (
    n integer primary key,
    reversal_id uuid not null,
    organization_id uuid not null,
    client_organization_id uuid not null,
    currency char(3) not null,
    mandate_id uuid,
    amount_minor bigint not null check (amount_minor > 0),
    on_date date not null,
    idem_key text not null,
    transfer_id uuid,
    bank_transaction_id uuid,
    advance_id uuid not null default gen_random_uuid()
  ) on commit drop;
end;
$$;

-- Posts pg_temp._rcv: one client_advance entry per row (+4679 A / −4670[c] A ‖ +4112[c] A / −4689 A, its document the
-- advance row, its key the row's, the fixed reason the client's whole-client members read), at most 2,000 entries per
-- private.ledger_post_set call (as post_run_settlements); then the advances of the entries it created (a replayed key
-- creates nothing and inserts nothing). The count posted.
create or replace function private.remitted_cover_post()
returns integer
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_max integer;
  v_from integer := 0;
  v_n integer := 0;
  v_c integer;
begin
  select max(c.n) into v_max from pg_temp._rcv c;
  while v_max is not null and v_from < v_max loop
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                    client_organization_id, source_type, source_id, reason)
    select c.n, c.organization_id, 'client_advance', c.on_date, c.idem_key, c.client_organization_id, 'client_advance',
           c.advance_id::text, 'Encaissement déjà reversé puis annulé : avance du cabinet'
    from pg_temp._rcv c where c.n > v_from and c.n <= v_from + 2000;
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
    select c.n, v.line_no, v.book, v.sign * c.amount_minor, c.currency
    from pg_temp._rcv c
    cross join (values (1, 'due_to_servicer', 1), (2, 'client_payable', -1), (3, 'client_advance_receivable', 1),
                       (4, 'due_from_client_funds', -1)) v (line_no, book, sign)
    where c.n > v_from and c.n <= v_from + 2000;
    drop table if exists pg_temp._rcv_posted;
    create temp table _rcv_posted on commit drop as select * from private.ledger_post_set();
    insert into public.client_advance (id, organization_id, client_organization_id, mandate_id, currency, amount_minor,
                                       cause, cause_entry_id, entry_id, bank_transaction_id, transfer_id)
    select c.advance_id, c.organization_id, c.client_organization_id, c.mandate_id, c.currency, c.amount_minor,
           'remitted_reversal', c.reversal_id, x.entry_id, c.bank_transaction_id, c.transfer_id
    from pg_temp._rcv c join pg_temp._rcv_posted x on x.entry_no = c.n
    where x.created and c.n > v_from and c.n <= v_from + 2000;
    get diagnostics v_c = row_count;
    v_n := v_n + v_c;
    v_from := v_from + 2000;
  end loop;
  return v_n;
end;
$$;

-- At the reversal (plan §3.2.4): each distinct reversal whose gap is positive gets one cover of the gap, dated
-- greatest(R's date, the payout it covers) ([critic] M7-MONEY-9, L3, F3: never before that payout), key adv:<R>, the
-- run's payout transfer and, given (p_line_ids, parallel), the bank line the reversal was posted at. Set-based: one call
-- per command or per debit chunk.
create or replace function private.cover_remitted_reversals(p_reversal_ids uuid[], p_line_ids uuid[] default null)
returns integer
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
begin
  if coalesce(cardinality(p_reversal_ids), 0) = 0 then
    return 0;
  end if;
  perform private.remitted_cover_begin();
  insert into pg_temp._rcv (n, reversal_id, organization_id, client_organization_id, currency, mandate_id, amount_minor,
                            on_date, idem_key, transfer_id, bank_transaction_id)
  select row_number() over (order by u.ord), u.id, f.organization_id, f.client_organization_id, f.currency, f.mandate_id,
         f.target - f.held, greatest(f.reversal_date, coalesce(f.payout_on, f.reversal_date)), 'adv:' || u.id,
         f.transfer_id, u.line
  from (select distinct on (x.id) x.id, x.line, x.ord
        from unnest(p_reversal_ids, p_line_ids) with ordinality x (id, line, ord)
        where x.id is not null
        order by x.id, x.ord) u
  cross join lateral private.remitted_cover_fact(u.id, true) f
  where f.target > f.held;
  return private.remitted_cover_post();
end;
$$;

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
  cross join lateral (select q.line_no, q.ledger_entry_id, q.client_organization_id, q.currency, q.mandate_id,
                             q.portfolio_id, q.amount_minor
                      from public.remittance_line q
                      where q.run_id = u.run_id and not q.released and q.kind in ('allocation', 'forward') offset 0) l
  cross join lateral (select q.id, q.effective_date from public.ledger_entry q
                      where q.reverses_entry_id = l.ledger_entry_id offset 0) r
  where not exists (select 1 from public.remittance_line z
                    where z.ledger_entry_id = r.id and not z.released and z.run_id = u.run_id)
    and l.amount_minor > private.remitted_cover_held(r.id);
  return private.remitted_cover_post();
end;
$$;

-- The approved or sent run whose plan takes the advance back (plan §3.2.13 [critic] M7-MONEY-2, F2): its settlement
-- is posted only at that run's debit (private.post_run_settlements), which never re-checks the advance, so nothing may
-- reverse or release the advance meanwhile. The client's runs by (client, currency) and status (a handful), their
-- plans' settles read in memory.
create or replace function private.advance_in_flight_run(p_advance_id uuid)
returns table (run_id uuid, run_number text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select r.id, r.number
  from (select a.client_organization_id, a.currency from public.client_advance a where a.id = p_advance_id offset 0) a
  cross join lateral (select q.id, q.number, q.settlement_plan, q.status from public.remittance_run q
                      where q.client_organization_id = a.client_organization_id and q.currency = a.currency
                        and q.status in ('approved', 'sent') offset 0) r
  where jsonb_typeof(r.settlement_plan) = 'object'
    and exists (select 1 from jsonb_array_elements(coalesce(r.settlement_plan -> 'settles', '[]')) s
                where s ->> 'kind' = 'advance' and s ->> 'document_id' = p_advance_id::text);
$$;

-- The release (plan §3.2.8): right after an unplanned booking is reversed (its payout came back), each item it attributed
-- whose reversal R is now over-covered (gap < 0: E not remitted, T fell) has its covers reversed, newest first, until
-- C(R) ≤ T(R) (key return:rr:<line>:<advance>, at the return's date), then the remainder re-posted when C(R) < T(R)
-- (several bookings attributed E; key adv:<R>:rel:<line>:<booking>). Refused, nothing reversed, while a cover of R has a
-- settlement (« advance_settled », as the double payout's advance, 6b-2) or an approved or sent run's plan takes it back
-- (« advance_in_flight »): raised as the command's refusal, never as posting_failed (SQLSTATE 55000).
create or replace function private.remitted_cover_release(p_booking_entry_id uuid, p_line_id uuid, p_on date)
returns integer
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  i record;
  f record;
  a record;
  v_held bigint;
  v_n integer := 0;
  v_k integer := 0;
begin
  perform private.remitted_cover_begin();
  for i in select z.id as reversal_id
           from (select u.ledger_entry_id from private.unplanned_paid_item u
                 where u.booking_entry_id = p_booking_entry_id offset 0) u
           cross join lateral (select z.id from public.ledger_entry z
                               where z.reverses_entry_id = u.ledger_entry_id offset 0) z
           order by z.id loop
    select * into f from private.remitted_cover_fact(i.reversal_id) limit 1;
    if not found or f.held <= f.target then
      continue;
    end if;
    for a in select q.id from public.client_advance q
             where q.cause_entry_id = i.reversal_id and q.cause = 'remitted_reversal'
               and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = q.entry_id) loop
      if exists (select 1 from public.commission_settlement s where s.document_kind = 'advance'
                   and s.document_id = a.id) then
        raise exception 'transfer line booking refused: advance_settled' using errcode = '55000';
      end if;
      if exists (select 1 from private.advance_in_flight_run(a.id)) then
        raise exception 'transfer line booking refused: advance_in_flight' using errcode = '55000';
      end if;
    end loop;
    v_held := f.held;
    for a in select q.id, q.entry_id, q.amount_minor, e.effective_date
             from public.client_advance q
             join public.ledger_entry e on e.id = q.entry_id
             where q.cause_entry_id = i.reversal_id and q.cause = 'remitted_reversal'
               and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = q.entry_id)
             order by q.created_at desc, q.id desc loop
      exit when v_held <= f.target;
      perform private.ledger_reverse(a.entry_id, 'return:rr:' || p_line_id || ':' || a.id,
                                     'Avance du cabinet annulée : le virement hors reversement qui avait payé cet '
                                     || 'encaissement est revenu (relevé du ' || to_char(p_on, 'DD/MM/YYYY') || ')',
                                     greatest(p_on, a.effective_date));
      v_held := v_held - a.amount_minor;
      v_n := v_n + 1;
    end loop;
    if v_held < f.target then
      v_k := v_k + 1;
      insert into pg_temp._rcv (n, reversal_id, organization_id, client_organization_id, currency, mandate_id,
                                amount_minor, on_date, idem_key, transfer_id, bank_transaction_id)
      values (v_k, i.reversal_id, f.organization_id, f.client_organization_id, f.currency, f.mandate_id,
              f.target - v_held, greatest(f.reversal_date, coalesce(f.payout_on, f.reversal_date)),
              'adv:' || i.reversal_id || ':rel:' || p_line_id || ':' || p_booking_entry_id, null, p_line_id);
    end if;
  end loop;
  return v_n + private.remitted_cover_post();
end;
$$;

------------------------------------------------------------------------------------------
-- I23 at every commit: LG009 (plan §3.1, §3.2.6; [critic] F6)
------------------------------------------------------------------------------------------

-- On each reversal inserted: its own gap; when it reverses an unplanned booking, the gap of every item that booking
-- attributed and that has a reversal (the release ran); when it reverses a remitted_reversal cover, that cover's reversal's
-- gap (a cover reversed by any path but the release, which re-posts or reaches T, lowers C(R) below T(R)). Keyed.
create or replace function private.remitted_cover_check()
returns trigger
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v record;
  v_gap bigint;
begin
  v_gap := private.remitted_cover_gap(new.id);
  if v_gap <> 0 then
    raise exception 'ledger: reversal % of an entry remitted to client % is not covered by an advance (gap %)',
      new.id, new.client_organization_id, v_gap using errcode = 'LG009';
  end if;
  for v in select z.id
           from (select u.ledger_entry_id from private.unplanned_paid_item u
                 where u.booking_entry_id = new.reverses_entry_id offset 0) u
           cross join lateral (select z.id from public.ledger_entry z
                               where z.reverses_entry_id = u.ledger_entry_id offset 0) z loop
    v_gap := private.remitted_cover_gap(v.id);
    if v_gap <> 0 then
      raise exception 'ledger: reversal % of an entry remitted to client % is not covered by an advance (gap %)',
        v.id, new.client_organization_id, v_gap using errcode = 'LG009';
    end if;
  end loop;
  for v in select a.cause_entry_id from public.client_advance a
           where a.entry_id = new.reverses_entry_id and a.cause = 'remitted_reversal' loop
    v_gap := private.remitted_cover_gap(v.cause_entry_id);
    if v_gap <> 0 then
      raise exception 'ledger: reversal % of an entry remitted to client % is not covered by an advance (gap %)',
        v.cause_entry_id, new.client_organization_id, v_gap using errcode = 'LG009';
    end if;
  end loop;
  return null;
end;
$$;
create constraint trigger ledger_entry_remitted_cover after insert on public.ledger_entry
  deferrable initially deferred for each row when (new.entry_type = 'reversal')
  execute function private.remitted_cover_check();
alter table public.ledger_entry enable always trigger ledger_entry_remitted_cover;

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
  for v in select r.id, private.remitted_cover_gap(r.id) as gap
           from (select l.ledger_entry_id from public.remittance_line l
                 where l.run_id = new.id and not l.released and l.kind in ('allocation', 'forward') offset 0) l
           cross join lateral (select q.id from public.ledger_entry q
                               where q.reverses_entry_id = l.ledger_entry_id offset 0) r
           where not exists (select 1 from public.remittance_line z
                             where z.ledger_entry_id = r.id and not z.released and z.run_id = new.id) loop
    if v.gap <> 0 then
      raise exception 'ledger: run % booked with reversal % of a line remitted to client % not covered by an advance (gap %)',
        new.number, v.id, new.client_organization_id, v.gap using errcode = 'LG009';
    end if;
  end loop;
  return null;
end;
$$;
create constraint trigger remittance_run_booked_cover after update on public.remittance_run
  deferrable initially deferred for each row
  when (new.status = 'booked' and old.status is distinct from 'booked')
  execute function private.run_booked_cover_check();
alter table public.remittance_run enable always trigger remittance_run_booked_cover;

------------------------------------------------------------------------------------------
-- The full pass on demand (plan §3.2.11 [check 2])
------------------------------------------------------------------------------------------

create table private.advance_full_check_request (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  requested_by uuid not null references public.app_user (id),
  requested_at timestamptz not null default clock_timestamp(),
  run_id uuid references public.payment_check_run (id),
  taken_at timestamptz,
  constraint advance_full_check_request_taken check ((run_id is null) = (taken_at is null))
);
create unique index advance_full_check_request_open_uq on private.advance_full_check_request (organization_id)
  where run_id is null;
comment on table private.advance_full_check_request is
  'An admin''s request for the full pass of the advance checks (« Vérification complète des avances »), taken by the '
  'next complete check run of its servicer (run_id, taken_at). Private: RLS on, no policy, every privilege revoked.';
alter table private.advance_full_check_request enable row level security;
revoke all on private.advance_full_check_request from public, anon, authenticated;

-- Only its run and the time it was taken may change, once, from null, to a check run of its servicer
create or replace function private.advance_full_check_request_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.run_id is not null or new.run_id is null or new.taken_at is null
     or (new.id, new.organization_id, new.requested_by, new.requested_at)
        is distinct from (old.id, old.organization_id, old.requested_by, old.requested_at)
     or not exists (select 1 from public.payment_check_run r
                    where r.id = new.run_id and r.organization_id = new.organization_id) then
    raise exception 'advance full check request %: only its run and the time it was taken, once, to a check run of its servicer',
      old.id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger advance_full_check_request_guard before update on private.advance_full_check_request
  for each row execute function private.advance_full_check_request_guard();
alter table private.advance_full_check_request enable always trigger advance_full_check_request_guard;
create trigger advance_full_check_request_no_delete before delete or truncate on private.advance_full_check_request
  for each statement execute function private.refuse_change();
alter table private.advance_full_check_request enable always trigger advance_full_check_request_no_delete;
create trigger advance_full_check_request_change_log after insert or update or delete
  on private.advance_full_check_request for each row execute function private.log_change();

-- The next check run of the servicer takes the open request (a run that fails rolls the take back: the request waits)
create or replace function private.advance_full_check_take(p_organization_id uuid, p_check_run_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v boolean;
begin
  update private.advance_full_check_request set run_id = p_check_run_id, taken_at = clock_timestamp()
  where organization_id = p_organization_id and run_id is null
  returning true into v;
  return coalesce(v, false);
end;
$$;

-- « Vérification complète des avances » on « Contrôles »: an admin of the servicer (aal2) asks for the full pass; the
-- ordinary checks job is queued (as « Lancer les contrôles »), whose complete run takes the request and runs it — never a
-- run of its own that would hide the other checks. One open request per servicer (its partial unique index: two admins
-- at once get one row and one refusal).
create or replace function public.request_full_advance_check(p_idempotency_key text, p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  v_request jsonb;
  v_result jsonb;
  v_id uuid;
begin
  if p_organization_id is null or not private.has_role(p_organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('organization_id', p_organization_id);
  v_result := private.command_replay('request_full_advance_check', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  begin
    insert into private.advance_full_check_request (organization_id, requested_by)
    values (p_organization_id, auth.uid())
    returning id into v_id;
  exception when unique_violation then
    raise exception 'advance check refused: already_requested' using errcode = 'check_violation';
  end;
  perform pgmq.send('payments', jsonb_build_object('type', 'invariants', 'organization_id', p_organization_id));
  v_result := jsonb_build_object('request_id', v_id, 'queued', true);
  perform private.command_record('request_full_advance_check', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The nightly checks of the advances (plan §3.4)
------------------------------------------------------------------------------------------

-- One statement per check into payment_check_result (one snapshot each):
--   remitted_reversal_uncovered (violation, subject the reversal): gap(R) ≠ 0 over [critic] F9 the reversals posted since
--     the servicer's last completed check run less one day (and, when they reverse a cover or an unplanned booking, the
--     cover's reversal and the booking's items' reversals), the reversals of the live allocation and forward lines of
--     the runs booked since, the reversals of the items attributed since, the reversals covered since, and the
--     reversals the last run listed uncovered — the day's activity, not the history; with p_full ([check 2] the 1st
--     of the month, Paris, or an admin's request: private.run_remittance_checks) every booked run's lines, every
--     attribution and every cover of the servicer. No previous run: the full pass;
--   advance_ledger (violation, subject the client): per client and currency, Σ (amount − settled) of its advances whose
--     entry is not reversed ≠ Σ its 4112 postings (I18's advance half, design §5.4); amount: 4112 less the advances;
--   advance_open (alert, subject the advance): open > 0, its entry not reversed, created more than 30 days before the
--     day the checks hold the books to (Paris); amount: open; details: its client, cause, mandate, recording date (and
--     settled_on_depth when its run's settlement chain is deeper than run_settled_on follows).
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
begin
  select r.id, r.started_at - interval '1 day' into v_prev, v_since
  from public.payment_check_run r
  where r.organization_id = p_organization_id and r.finished_at is not null and r.id <> p_check_run_id
  order by r.started_at desc limit 1;
  if v_prev is null then
    v_full := true;
  end if;
  v_since_date := (v_since at time zone 'Europe/Paris')::date;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with day_rev as materialized (     -- the reversals posted since (ledger_entry_reversal_posted_idx)
    select x.id, x.reverses_entry_id from public.ledger_entry x
    where not v_full and x.organization_id = p_organization_id and x.entry_type = 'reversal' and x.posted_at >= v_since),
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
    from (select q.id from public.remittance_run q
          where q.organization_id = p_organization_id and q.status = 'booked'
            and (v_full or q.booked_on >= v_since_date) offset 0) r
    cross join lateral (select l.ledger_entry_id from public.remittance_line l
                        where l.run_id = r.id and not l.released and l.kind in ('allocation', 'forward') offset 0) l
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = l.ledger_entry_id offset 0) z
    union
    select z.id
    from (select u.ledger_entry_id from private.unplanned_paid_item u
          where u.organization_id = p_organization_id and (v_full or u.created_at >= v_since) offset 0) u
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = u.ledger_entry_id offset 0) z
    union
    select a.cause_entry_id from public.client_advance a
    where a.organization_id = p_organization_id and a.cause = 'remitted_reversal' and (v_full or a.created_at >= v_since)
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
                                  cross join lateral private.run_settled_at(l.run_id, 0) t
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
-- « Couvrir » and the « Désimputer » read (plan §3.2.9, §3.2.10)
------------------------------------------------------------------------------------------

-- « Couvrir » on « Contrôles » (design §17): an admin of the reversal's servicer at aal2 records the cover the nightly
-- found missing, for the gap the page showed (compare and set). Refused (« remitted cover refused: <code> »):
-- nothing_to_cover (gap 0), gap_changed (not the gap shown), over_covered (gap < 0: support). Its own key
-- adv:<R>:cov:<md5 of the idempotency key> ([critic] F18: adv:<R> may exist, reversed by a release). Locks: the
-- allocation then the remit lock (private.remittance_command_locks). Returns {advance_id, entry_id, amount_minor}.
create or replace function public.cover_remitted_reversal(p_idempotency_key text, p_reversal_id uuid,
                                                          p_expected_gap_text text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  r public.ledger_entry;
  f record;
  v_request jsonb;
  v_result jsonb;
  v_gap bigint;
  v_adv uuid;
  v_entry uuid;
begin
  select * into r from public.ledger_entry where id = p_reversal_id;
  if not found or r.entry_type <> 'reversal' or not private.has_role(r.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('reversal_id', p_reversal_id, 'expected_gap', p_expected_gap_text);
  v_result := private.command_replay('cover_remitted_reversal', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_expected_gap_text is null or p_expected_gap_text !~ '^-?[0-9]{1,16}$' then
    raise exception 'remitted cover refused: bad_request' using errcode = 'check_violation';
  end if;
  perform private.remittance_command_locks(r.organization_id, true);
  select * into f from private.remitted_cover_fact(r.id, true) limit 1;
  v_gap := coalesce(f.target, 0) - coalesce(f.held, 0);
  if v_gap = 0 then
    raise exception 'remitted cover refused: nothing_to_cover' using errcode = 'check_violation';
  end if;
  if v_gap <> p_expected_gap_text::bigint then
    raise exception 'remitted cover refused: gap_changed' using errcode = 'check_violation';
  end if;
  if v_gap < 0 then
    raise exception 'remitted cover refused: over_covered' using errcode = 'check_violation';
  end if;
  perform private.remitted_cover_begin();
  insert into pg_temp._rcv (n, reversal_id, organization_id, client_organization_id, currency, mandate_id, amount_minor,
                            on_date, idem_key, transfer_id, bank_transaction_id)
  values (1, r.id, f.organization_id, f.client_organization_id, f.currency, f.mandate_id, v_gap,
          greatest(f.reversal_date, coalesce(f.payout_on, f.reversal_date)),
          'adv:' || r.id || ':cov:' || md5(p_idempotency_key), f.transfer_id, null)
  returning advance_id into v_adv;
  perform private.remitted_cover_post();
  perform private.ledger_check_now();
  select a.entry_id into v_entry from public.client_advance a where a.id = v_adv;
  v_result := jsonb_build_object('advance_id', v_adv, 'entry_id', v_entry, 'amount_minor', v_gap::text);
  perform private.command_record('cover_remitted_reversal', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- For « Désimputer » and « Retour »: the payment's live allocation and forward entries already remitted to the client
-- (private.entry_remitted), with their run, its date, the line's amount and what that run settled and how ([check 1]
-- paid_on, paid_how, paid_run_number). Money staff of the payment's servicer (aal2); « not allowed » otherwise.
create or replace function public.allocation_remitted(p_payment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_org uuid;
begin
  select q.organization_id into v_org from public.payment q where q.id = p_payment_id;
  if v_org is null or not private.has_role(v_org, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'entry_id', e.id, 'account_id', e.account_id, 'run_number', x.run_number, 'booked_on', x.booked_on,
             'amount_minor', x.amount_minor::text, 'paid_on', x.paid_on, 'paid_how', x.paid_how,
             'paid_run_number', x.paid_run_number) order by e.effective_date, e.id), '[]')
    from (select q.id, q.account_id, q.effective_date from public.ledger_entry q
          where q.payment_id = p_payment_id and q.entry_type in ('allocation', 'forward') offset 0) e
    cross join lateral private.entry_remitted(e.id) x
    where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = e.id));
end;
$$;


------------------------------------------------------------------------------------------
-- Redefinitions (each copied whole from its latest definition, the change only)
------------------------------------------------------------------------------------------

-- private.ledger_check_now, redefined from 20261111090000_remittance_funds.sql (line 1335; same signature and
-- settings, its grants restated below): the commit-time checks it runs now also hold I23 (LG009: the reversals'
-- covers and the runs booked; plan §3.2.7). Nothing else changes.
create or replace function private.ledger_check_now()
returns void
language plpgsql
set search_path = ''
as $$
begin
  set constraints public.ledger_entry_balanced, private.client_payable_in_credit, public.ledger_entry_remitted_cover,
    public.remittance_run_booked_cover immediate;
  set constraints public.ledger_entry_balanced, private.client_payable_in_credit, public.ledger_entry_remitted_cover,
    public.remittance_run_booked_cover deferred;
end;
$$;

-- public.reverse_allocation (« Désimputer »), redefined from 20261109190000_payment_allocation.sql (line 1079; same
-- signature and settings, its grants restated below). M2c-7a (plan §3.2.12): the reversals it posts are covered
-- (private.cover_remitted_reversals) and the ledger's commit-time checks run at once (LG009, LG008); its result
-- lists the advances posted. Its lock_timeout (2s) may now be reached on the remit lock a file generation holds: the
-- page says « Opération en cours sur les virements ». Nothing else changes.
create or replace function public.reverse_allocation(p_idempotency_key text, p_payment_id uuid, p_account_id uuid,
                                                     p_entry_ids uuid[], p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  p public.payment;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_live uuid[];
  v_shown uuid[];
  e record;
  v_rev uuid;
  v_reversals uuid[] := '{}';
  pos record;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_shown from unnest(p_entry_ids) x;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'account_id', p_account_id, 'entry_ids', to_jsonb(v_shown),
                                  'reason', v_reason);
  v_result := private.command_replay('reverse_allocation', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  select coalesce(array_agg(x.id order by x.id), '{}') into v_live
  from public.ledger_entry x
  where x.payment_id = p.id and x.entry_type = 'allocation' and x.account_id = p_account_id
    and not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = x.id);
  if cardinality(v_live) = 0 then
    raise exception 'nothing of this payment is allocated on this file' using errcode = 'check_violation';
  end if;
  if v_live <> v_shown then
    raise exception 'the allocation changed: reload the page' using errcode = 'check_violation';
  end if;
  -- The client reads the reversal entry and its notification: a fixed wording and a code; ops' motif stays internal
  -- (review fix: a motif may name a third party).
  for e in select x.id, x.client_organization_id, x.portfolio_id from public.ledger_entry x
           where x.id = any (v_live) order by x.effective_date, x.id loop
    select r.entry_id into v_rev
    from private.ledger_reverse(e.id, 'unalloc:' || e.id, 'Imputation annulée par le gestionnaire') r;
    v_reversals := v_reversals || v_rev;
    insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id,
                                            payment_id, ledger_entry_id, kind, reason)
    values (p.organization_id, e.client_organization_id, e.portfolio_id, p_account_id, p.id, v_rev,
            'payment_allocation_reversed', 'ops_correction');
    insert into private.payment_ops_note (entry_id, payment_id, command, note, decided_by)
    values (v_rev, p.id, 'reverse_allocation', v_reason, auth.uid());
  end loop;
  -- M2c-7a (plan §3.2.12; design §13 #1): each reversal of an entry already remitted to the client is covered by an
  -- advance of the servicer in this transaction (never netted against its other collections); I23 checked now (LG009)
  perform private.cover_remitted_reversals(v_reversals);
  perform private.ledger_check_now();
  select * into pos from private.payment_positions(array[p.id]);
  update public.payment
  set status = case when pos.allocated_minor = 0 then 'matched'
                    when pos.unallocated_minor = 0 then 'allocated' else 'partially_allocated' end,
      -- another file's allocation reversed while this file's remains: what is left is an overpayment again (founder
      -- #8); this file's own allocation reversed: it waits for ops, whatever another file keeps (review fix: this
      -- file may owe it again; « Imputer » sends it back here)
      review_reason = case when pos.allocated_minor > 0 and pos.unallocated_minor > 0 and p_account_id <> p.account_id
                             then 'overpayment'
                           else 'allocation_reversed' end,
      allocation_instruction = null
  where id = p.id;
  perform private.regate_account(p_account_id);  -- the file's other payments may find something due again
  v_result := jsonb_build_object('payment_id', p.id, 'account_id', p_account_id, 'reversals', to_jsonb(v_reversals),
    'advances', (select coalesce(jsonb_agg(jsonb_build_object('advance_id', a.id, 'amount_minor', a.amount_minor::text)
                                           order by a.created_at, a.id), '[]')
                 from public.client_advance a
                 where a.cause_entry_id = any (v_reversals) and a.cause = 'remitted_reversal'));
  perform private.command_record('reverse_allocation', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- private.debit_post_rows, redefined from 20261110120000_debits_refunds.sql (line 549; same signature and settings,
-- its grants restated below). M2c-7a (plan §3.2.12): step 1 collects the reversals it posts and covers those of
-- remitted entries before step 2. Its callers (private.post_debit_links, both modes, then ledger_check_now) are
-- unchanged: a link the posting refuses (LG009, LG008) is posting_failed in the job's mode and « debit link refused »
-- in ops' strict mode. Nothing else changes.
create or replace function private.debit_post_rows(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  e record;
  v_n_account uuid;
  v_n_portfolio uuid;
  v_rev uuid;
  v_revs uuid[] := '{}';
  v_lines uuid[] := '{}';
begin
  -- 1. Returns: undo the payment's allocations and forwards at the return date (founder #13; design §2 #3), the client
  --    told of each with a code (never ops' motif).
  for r in select d.* from pg_temp._dl d where d.kind = 'return' order by d.ord loop
    for e in select x.id, x.entry_type, x.effective_date, x.client_organization_id, x.portfolio_id, x.account_id
             from public.ledger_entry x
             where x.payment_id = r.payment_id and x.entry_type in ('allocation', 'forward')
               and not exists (select 1 from public.ledger_entry y where y.reverses_entry_id = x.id)
             order by x.effective_date, x.id loop
      select z.entry_id into v_rev
      from private.ledger_reverse(e.id, 'return:' || r.bank_transaction_id || ':' || e.id,
                                  case e.entry_type when 'allocation' then 'Imputation annulée : paiement retourné par la banque'
                                                    else 'Reversement annulé : paiement retourné par la banque' end,
                                  greatest(r.line_date, e.effective_date)) z;
      v_revs := v_revs || v_rev;
      v_lines := v_lines || r.bank_transaction_id;
      if e.entry_type = 'allocation' then
        insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id,
                                                payment_id, ledger_entry_id, kind, reason)
        values (p_organization_id, e.client_organization_id, e.portfolio_id, e.account_id, r.payment_id, v_rev,
                'payment_allocation_reversed', 'bank_return');
      else
        -- the forward's own notification says which file (if any) the client read it about
        v_n_account := null;
        v_n_portfolio := null;
        select c.account_id, c.portfolio_id into v_n_account, v_n_portfolio
        from public.client_notification c where c.ledger_entry_id = e.id;
        insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id,
                                                payment_id, ledger_entry_id, kind, reason)
        values (p_organization_id, e.client_organization_id, v_n_portfolio, v_n_account, r.payment_id, v_rev,
                'payment_forward_reversed', 'bank_return');
      end if;
    end loop;
  end loop;

  -- 1b. M2c-7a (plan §3.2.12): each reversal of an entry already remitted to the client covered by an advance of the
  --     servicer, at the return's line (one set-based call for the chunk; a partial return reverses every allocation
  --     and forward of the payment, each remitted one covered in full: founder Q1's default)
  perform private.cover_remitted_reversals(v_revs, v_lines);

  -- 2. cash_out of every return and refund, at the date the bank booked it (set-based; I4 → LG007).
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, payment_id,
                                  source_type, source_id, reason)
  select d.ord, p_organization_id, 'cash_out', d.line_date, 'cash_out:' || d.bank_transaction_id, d.payment_id,
         'bank_transaction', d.bank_transaction_id::text,
         case d.kind when 'return' then 'Paiement retourné par la banque' else 'Remboursement au payeur' end
  from pg_temp._dl d where d.kind in ('return', 'refund');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
  select d.ord, x.line_no, x.book, x.sign * d.line_minor, d.currency,
         case when x.book = 'client_money_cash' then d.line_bank end
  from pg_temp._dl d
  cross join (values (1, 'unallocated_payment', 1), (2, 'client_money_cash', -1)) x (line_no, book, sign)
  where d.kind in ('return', 'refund');
  if exists (select 1 from pg_temp._lps_entry) then
    drop table if exists pg_temp._dl_cash;
    create temp table _dl_cash on commit drop as select * from private.ledger_post_set();
    update pg_temp._dl d set cash_entry_id = c.entry_id from pg_temp._dl_cash c where c.entry_no = d.ord;
  end if;

  -- 3. A refund that came back unpaid: its cash_out reversed at the credit's date.
  for r in select d.* from pg_temp._dl d where d.kind = 'refund_returned' order by d.ord loop
    select z.entry_id into v_rev
    from private.ledger_reverse(r.req_entry, 'refund_bounce:' || r.bank_transaction_id,
                                'Remboursement revenu impayé', r.line_date) z;
    update pg_temp._dl set cash_entry_id = v_rev where bank_transaction_id = r.bank_transaction_id;
  end loop;

  -- 4. The links, the requests, the payments.
  insert into public.bank_debit_link (bank_transaction_id, organization_id, bank_account_id, kind, payment_id,
                                      refund_request_id, cash_entry_id, method, reason, decided_by)
  select d.bank_transaction_id, p_organization_id, d.line_bank, d.kind, d.payment_id, d.refund_request_id,
         d.cash_entry_id, d.method, nullif(btrim(d.reason), ''), d.decided_by
  from pg_temp._dl d order by d.ord;
  update public.refund_request q
  set status = 'executed', bank_transaction_id = d.bank_transaction_id, cash_out_entry_id = d.cash_entry_id,
      executed_on = d.line_date
  from pg_temp._dl d where d.kind = 'refund' and q.id = d.refund_request_id;
  update public.refund_request q
  set status = 'bounced', bounce_transaction_id = d.bank_transaction_id, bounce_entry_id = d.cash_entry_id
  from pg_temp._dl d where d.kind = 'refund_returned' and q.id = d.refund_request_id;
  -- a payment the bank took back in full: nothing is left to refund
  update public.refund_request q
  set status = 'cancelled', cancelled_at = now(), cancel_reason = 'Paiement retourné par la banque'
  from pg_temp._dl d
  where d.kind = 'return' and q.payment_id = d.payment_id and q.status = 'requested'
    and d.line_minor = d.pay_minor - d.returned;

  drop table if exists pg_temp._dl_pos;
  create temp table _dl_pos on commit drop as
  select x.* from private.payment_positions(array(select d.payment_id from pg_temp._dl d where d.payment_id is not null)) x;
  update public.payment p
  set status = s.status, review_reason = s.review_reason, allocation_instruction = null
  from (select d.payment_id,
               case when d.kind = 'return' and d.line_minor = d.pay_minor - d.returned then 'returned'
                    when exists (select 1 from public.refund_request q where q.payment_id = d.payment_id
                                   and q.status = 'requested') then 'refund_pending'
                    when x.unallocated_minor = 0 and x.allocated_minor = 0 then 'refunded'
                    when x.unallocated_minor = 0 then 'allocated'
                    when x.allocated_minor > 0 then 'partially_allocated'
                    when d.account_id is null then 'unmatched'
                    else 'matched' end as status,
               case when d.kind = 'return' and d.line_minor = d.pay_minor - d.returned then null
                    when exists (select 1 from public.refund_request q where q.payment_id = d.payment_id
                                   and q.status = 'requested') then null
                    when x.unallocated_minor = 0 then null
                    when d.kind = 'return' then 'partial_return'
                    -- a bounce: from the payment's facts now, not from when the refund was asked (review fix)
                    when d.kind = 'refund_returned' then
                      case when d.account_id is not null then null   -- on a file: the allocation job gates it again
                           when d.pay_status in ('unmatched', 'refunded') and d.req_prior_status = 'unmatched'
                                and d.req_prior_reason in ('no_match', 'ambiguous') then d.req_prior_reason
                           else 'no_match' end
                    else coalesce(d.req_prior_reason, case when x.allocated_minor > 0 then 'overpayment'
                                                           when d.account_id is null then 'no_match' end) end
                 as review_reason
        from pg_temp._dl d join pg_temp._dl_pos x on x.payment_id = d.payment_id
        where d.kind <> 'explained') s
  where p.id = s.payment_id;

  -- 5. The client of the payment's file is told it came back (founder #13).
  insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id, payment_id,
                                          ledger_entry_id, kind, reason)
  select p_organization_id, a.client_organization_id, a.portfolio_id, a.id, d.payment_id, d.cash_entry_id,
         'payment_returned', 'bank_return'
  from pg_temp._dl d join public.account a on a.id = d.account_id
  where d.kind = 'return';

  delete from public.bank_debit_review v using pg_temp._dl d where v.bank_transaction_id = d.bank_transaction_id;

  -- the ledger's checks of the reversals and cash_outs posted above, now (not at commit)
  set constraints public.ledger_entry_balanced immediate;
  set constraints public.ledger_entry_balanced deferred;
end;
$$;

-- private.approve_remittance_run, redefined from 20261114090000_manual_credit_note.sql (line 786; same signature and
-- settings, its grants restated below). M2c-7a: an N = 0 run booked at approval covers its reversed lines
-- (private.cover_booked_run_reversals). Nothing else changes.
create or replace function private.approve_remittance_run(p_run_id uuid, p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '10s'
as $$
declare
  r public.remittance_run;
  d private.remittance_draft;
  pa public.client_payout_account;
  v_today date;
  v_why text;
  v_docs jsonb;
  v_ids jsonb := '{}';
  v_issued jsonb;
  v_n integer;
  v_plan jsonb;
  v_bank uuid;
  v_transfer uuid;
  v_info text;
  v_entry uuid;
  v_late boolean;
begin
  select * into r from public.remittance_run where id = p_run_id for update;
  if not found or r.status <> 'draft' or r.job is distinct from 'approve' or r.job_token is distinct from p_token then
    return jsonb_build_object('status', 'skipped');
  end if;
  select * into d from private.remittance_draft where run_id = r.id;
  if r.net_minor > 0 then
    select * into pa from public.client_payout_account where id = r.payout_account_id for key share;
    v_bank := private.paying_account(r.organization_id, r.currency);
    perform 1 from public.bank_account b where b.id = v_bank for share;
  end if;
  -- the documents' ids first (the lines name their invoice; the foreign key is checked at commit)
  select coalesce(jsonb_agg(x.doc || jsonb_build_object('id', gen_random_uuid(),
                                                        'key', case x.doc ->> 'kind' when 'invoice' then 'inv:'
                                                                                     else 'crn:' end
                                                               || r.id || ':' || (x.doc ->> 'mandate_id'))
                            order by x.ord), '[]')
  into v_docs from jsonb_array_elements(coalesce(d.documents, '[]')) with ordinality x (doc, ord);
  select coalesce(jsonb_object_agg(x ->> 'ref', x ->> 'id'), '{}') into v_ids from jsonb_array_elements(v_docs) x;

  begin
    -- The frozen facts, written under the run's row lock only, before the allocation lock (performance review #4):
    -- the lines, their repricings, the tier history (with what the run's credits absorb of manual credit notes'
    -- waivers, M2c-5b: a manual credit note since the prepare is caught by `history_changed`) and the invoices'
    -- charges depend only on the draft and on
    -- immutable entries; the refusal below rolls them back with this block. Holding the allocation lock is then the
    -- checks, the queue, the numbering and posting of the documents and the payout (each item in exactly one live
    -- line, I15), then the deferred checks at commit: 5k lines, 0.09 s + 0.07 s of a 0.83 s job (all of it before).
    -- The row locks these inserts take on what the lines name are key-share locks, taken (as every command takes its
    -- row locks) before the advisory lock: no lock cycle with an allocation.
    insert into public.remittance_line (run_id, line_no, organization_id, client_organization_id, currency,
                                        ledger_entry_id, kind, account_id, portfolio_id, mandate_id, mandate_terms_id,
                                        payment_id, encaissement_date, effective_date, posted_at, deadline,
                                        latest_execution_date, unmeetable, amount_minor, basis, commission_minor,
                                        commission_state, commission_reason, parts, original_entry_id, invoice_id)
    select l.run_id, l.line_no, r.organization_id, r.client_organization_id, r.currency, l.ledger_entry_id, l.kind,
           l.account_id, l.portfolio_id, l.mandate_id, l.mandate_terms_id, l.payment_id, l.encaissement_date,
           l.effective_date, l.posted_at, l.deadline, l.latest_execution_date, l.unmeetable, l.amount_minor, l.basis,
           l.commission_minor, l.commission_state, l.commission_reason, l.parts, l.original_entry_id,
           case when l.invoiced then (v_ids ->> ('new:' || l.mandate_id))::uuid end
    from private.remittance_draft_line l where l.run_id = r.id;
    get diagnostics v_n = row_count;
    insert into public.remittance_line_repricing (pricing_run_id, run_id, line_no, ledger_entry_id, commission_minor,
                                                  commission_state, commission_reason, parts, invoice_id)
    select r.id, x.line_run_id, x.line_no, x.ledger_entry_id, x.commission_minor, x.commission_state,
           x.commission_reason, x.parts,
           case when x.invoiced then (v_ids ->> ('new:' || l.mandate_id))::uuid end
    from private.remittance_draft_repricing x
    join public.remittance_line l on l.run_id = x.line_run_id and l.line_no = x.line_no
    where x.run_id = r.id;
    insert into public.remittance_key_state (organization_id, client_organization_id, account_id, tier_key, run_id,
                                             cause, basis, kept_basis_minor, kept_minor, commission_minor,
                                             waived_minor)
    select r.organization_id, r.client_organization_id, (k ->> 'account_id')::uuid, k ->> 'tier_key', r.id, 'approved',
           coalesce(k -> 'basis', '[]'), (k ->> 'kept_basis')::bigint, (k ->> 'kept')::bigint,
           (k ->> 'commission')::bigint, coalesce((k ->> 'waived')::bigint, 0)
    from jsonb_array_elements(coalesce(d.key_states, '[]')) k;
    -- what the run's credits absorb of the waivers manual credit notes left on earlier invoices (M2c-5b): no document
    -- carries it; the waiver's guard keeps each (invoice, key) balance between 0 and what was waived
    insert into public.commission_waiver (organization_id, client_organization_id, invoice_id, account_id, tier_key,
                                          amount_minor, cause, run_id, entry_id)
    select r.organization_id, r.client_organization_id, (w ->> 0)::uuid, (k ->> 'account_id')::uuid, k ->> 'tier_key',
           -(w ->> 1)::bigint, 'absorbed', r.id, (w ->> 2)::uuid
    from jsonb_array_elements(coalesce(d.key_states, '[]')) k
    cross join lateral jsonb_array_elements(coalesce(k -> 'absorbed', '[]')) w;
    -- what the run's invoices charge each (file, tier key) (one row per file at 50k; the invoices numbered below)
    insert into public.commission_invoice_charge (invoice_id, account_id, tier_key, charged_minor)
    select (x.doc ->> 'id')::uuid, (c ->> 'account_id')::uuid, c ->> 'tier_key', (c ->> 'amount')::bigint
    from jsonb_array_elements(v_docs) x (doc)
    cross join lateral jsonb_array_elements(coalesce(x.doc -> 'charges', '[]')) c
    where x.doc ->> 'kind' = 'invoice';

    -- lock order (ADR-0014): the run row → allocation lock → remit lock → invoice counter (last, in
    -- issue_commission_documents)
    perform pg_advisory_xact_lock(hashtext('payments:' || r.organization_id::text));
    perform pg_advisory_xact_lock(hashtext('remit:' || r.organization_id::text));
    v_today := private.paris_today();
    v_why := private.remittance_approval_refusal(r, d, v_today);
    if v_why is not null then
      raise exception '%', v_why using errcode = 'RR001';
    end if;
    if v_n <> r.line_count then
      raise exception 'approval of %: % lines frozen for % prepared', r.number, v_n, r.line_count
        using errcode = '23514';
    end if;
    -- their items leave the pending queue
    delete from private.remittance_pending q where q.draft_run_id = r.id;

    -- invoices and credit notes, numbered (the counter locked last), their entries posted, in the VAT book the plan
    -- assumed (money review #1)
    v_issued := private.issue_commission_documents(r.organization_id, r.client_organization_id, r.id,
                                                   (select coalesce(jsonb_agg(x.doc - 'charges' order by x.ord), '[]')
                                                    from jsonb_array_elements(v_docs) with ordinality x (doc, ord)),
                                                   'commission', d.vat_on_debits);

    -- the plan with the run's documents named (M2c-6 posts it at the debit)
    select d.plan || jsonb_build_object('settles', coalesce(jsonb_agg(
             s || jsonb_build_object('document_id', coalesce(v_ids ->> (s ->> 'ref'), s ->> 'ref'))), '[]'))
    into v_plan from jsonb_array_elements(coalesce(d.plan -> 'settles', '[]')) s;

    v_late := private.business_days_between((r.known_at at time zone 'Europe/Paris')::date, v_today) > 2;
    if r.net_minor > 0 then
      select left('REVERSEMENT ' || r.number || coalesce(' FACTURE ' || string_agg(i.number, ' ' order by i.seq), ''),
                  140)
      into v_info from public.commission_invoice i where i.run_id = r.id and i.kind = 'invoice';
      insert into public.bank_transfer (organization_id, client_organization_id, kind, debtor_bank_account_id, currency,
                                        amount_minor, payee_name, payee_iban, payee_bic, end_to_end_id,
                                        remittance_info, requested_execution_date, run_id, ordered_by)
      values (r.organization_id, r.client_organization_id, 'payout', v_bank, r.currency, r.net_minor, pa.holder_name,
              pa.iban, pa.bic, 'RMT' || upper(substr(md5(gen_random_uuid()::text), 1, 12)), v_info,
              r.requested_execution_date, r.id, r.approval_requested_by)
      returning id into v_transfer;
      perform private.remittance_late_lines(r, r.requested_execution_date);
      update public.remittance_run set status = 'approved', approved_by = r.approval_requested_by,
        approved_at = clock_timestamp(), transfer_id = v_transfer, settlement_plan = v_plan, invoice_late = v_late,
        payout_snapshot = jsonb_build_object('payout_account_id', pa.id, 'holder_name', pa.holder_name,
                                             'iban', pa.iban, 'bic', pa.bic, 'kind', pa.kind,
                                             'confirmed_at', pa.confirmed_at),
        job = null, job_token = null, job_queued_at = null, version = version + 1
      where id = r.id;
      return jsonb_build_object('status', 'approved', 'transfer_id', v_transfer, 'documents', v_issued -> 'documents');
    end if;
    -- N = 0 (§9.5 step 5): nothing to transfer; the settlement is posted now and the run is booked — its date is the
    -- items' payment date (I21: « settled when N = 0 », money review #3)
    perform private.remittance_late_lines(r, v_today);
    v_entry := private.post_run_settlement(r.id, v_plan, v_today);
    -- M2c-7a (plan §3.2.12): the run is booked now: a line reversed since it was prepared is covered (a same-run pair
    -- posts nothing: [critic] M7-MONEY-1)
    perform private.cover_booked_run_reversals(array[r.id], array[v_today]);
    update public.remittance_run set status = 'booked', booked_on = v_today, approved_by = r.approval_requested_by,
      approved_at = clock_timestamp(), settlement_plan = v_plan || jsonb_build_object('entry_id', v_entry),
      invoice_late = v_late, job = null, job_token = null, job_queued_at = null, version = version + 1
    where id = r.id;
    return jsonb_build_object('status', 'booked', 'entry_id', v_entry, 'documents', v_issued -> 'documents');
  exception when sqlstate 'RR001' then
    -- a business refusal: everything above rolled back, the locks released; back to draft with the reason
    perform private.remittance_back_to_draft(r.id, p_token, sqlerrm, null);
    return jsonb_build_object('status', 'back_to_draft', 'reason', sqlerrm);
  end;
end;
$$;

-- private.run_remittance_checks, redefined from 20261115090000_transfers_files.sql (line 3710; same signature, so
-- run_payment_checks' calls with two arguments stay as they are; its settings and grants restated): M2c-7a runs the
-- advances' checks after the runs' and the transfers'. Nothing else changes.
create or replace function private.run_remittance_checks(p_check_run_id uuid, p_organization_id uuid, p_today date default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_full boolean;
begin
  perform private.run_remittance_runs_checks(p_check_run_id, p_organization_id, p_today);
  perform private.run_transfer_checks(p_check_run_id, p_organization_id, p_today);
  -- M2c-7a (plan §3.2.11 [check 2]): the advances' checks; their full pass when the day the checks hold the books to
  -- (Paris) is the 1st of a month, or when this run takes an admin's request (taken first: a run that fails rolls the
  -- take back)
  v_full := private.advance_full_check_take(p_organization_id, p_check_run_id);
  v_full := v_full or extract(day from coalesce(p_today, private.paris_today())) = 1;
  perform private.run_advance_checks(p_check_run_id, p_organization_id, p_today, v_full);
end;
$$;

-- private.transfer_line_post, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 2163; same signature
-- and settings, its grants restated below). M2c-7a: an unplanned payout's return releases the covers of the items it
-- paid that were reversed since (private.remitted_cover_release, plan §3.2.8); the double payout's advance gets the
-- single mandate of its transfer's run ([critic] F10). Nothing else changes.
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

-- private.bank_booking_post_rows, redefined from 20261121090000_switch_on_prerequisites_4.sql (line 808; same
-- signature and settings, its grants restated below). M2c-7a: between the settlements (3) and the overrun cover (4),
-- the booked runs' reversed lines are covered (private.cover_booked_run_reversals, plan §3.2.12); the overrun
-- advance gets the single mandate of its run's lines ([critic] F10). Nothing else changes.
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

-- public.remittance_run_payout, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 4380; same
-- signature and settings, its grants restated below). M2c-7a ([critic] F5): its advances are read by transfer
-- (client_advance_transfer_idx) for the chain's transfers, causes payout_overrun and remitted_reversal. Nothing else
-- changes.
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
      -- M2c-7a ([critic] F5): the advances posted for this chain's payout, by client_advance_transfer_idx — its overrun
      -- (payout_overrun) and the covers of its reversed collections (remitted_reversal: at the booking, or at a later
      -- reversal of a line it paid), each worded by its cause on the run page
      cross join lateral (select q.* from public.client_advance q
                          where q.transfer_id = c.transfer_id and q.cause in ('payout_overrun', 'remitted_reversal')
                          offset 0) a
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

------------------------------------------------------------------------------------------
-- Privileges (the new internals revoked; every redefined function's grants restated)
------------------------------------------------------------------------------------------

-- the new internals (PostgreSQL grants EXECUTE to PUBLIC by default): the SECURITY DEFINER paths and checks use them
revoke execute on function private.run_settled_at(uuid, integer), private.run_settled_on(uuid),
  private.entry_remitted(uuid, uuid), private.remitted_cover_fact(uuid, boolean), private.remitted_cover_held(uuid),
  private.remitted_cover_target(uuid), private.remitted_cover_gap(uuid), private.remitted_cover_begin(),
  private.remitted_cover_post(), private.cover_remitted_reversals(uuid[], uuid[]),
  private.cover_booked_run_reversals(uuid[], date[], uuid[], uuid[]), private.advance_in_flight_run(uuid),
  private.remitted_cover_release(uuid, uuid, date), private.remitted_cover_check(), private.run_booked_cover_check(),
  private.advance_full_check_request_guard(), private.advance_full_check_take(uuid, uuid),
  private.run_advance_checks(uuid, uuid, date, boolean)
  from public, anon, authenticated, service_role;
-- the worker's tests and M3c-2 read the predicate and the gap
grant execute on function private.entry_remitted(uuid, uuid), private.run_settled_on(uuid),
  private.remitted_cover_gap(uuid), private.remitted_cover_target(uuid), private.remitted_cover_held(uuid)
  to service_role;
-- the commands and the read: authenticated (each checks the caller inside); never anon
revoke execute on function public.cover_remitted_reversal(text, uuid, text),
  public.request_full_advance_check(text, uuid), public.allocation_remitted(uuid)
  from public, anon;
grant execute on function public.cover_remitted_reversal(text, uuid, text),
  public.request_full_advance_check(text, uuid), public.allocation_remitted(uuid)
  to authenticated;

-- the redefined, as their latest migrations left them
-- (20261111090000) the commit-time checks now: the worker's
revoke execute on function private.ledger_check_now() from public, anon, authenticated;
grant execute on function private.ledger_check_now() to service_role;
-- (20261109190000) « Désimputer »
revoke execute on function public.reverse_allocation(text, uuid, uuid, uuid[], text) from public, anon;
grant execute on function public.reverse_allocation(text, uuid, uuid, uuid[], text) to authenticated;
-- (20261110120000, 20261118100000, 20261121090000) internal
revoke execute on function private.debit_post_rows(uuid), private.transfer_line_post(uuid, text),
  private.bank_booking_post_rows(uuid)
  from public, anon, authenticated, service_role;
-- (20261114090000) the approval job: the worker's
revoke execute on function private.approve_remittance_run(uuid, uuid) from public, anon, authenticated;
grant execute on function private.approve_remittance_run(uuid, uuid) to service_role;
-- (20261115090000) the runs' checks, called by private.run_payment_checks
revoke execute on function private.run_remittance_checks(uuid, uuid, date) from public, anon, authenticated;
-- (20261118100000) the run page's read
revoke execute on function public.remittance_run_payout(uuid) from public, anon;
grant execute on function public.remittance_run_payout(uuid) to authenticated;
