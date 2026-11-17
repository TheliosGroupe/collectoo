-- M2c-6b-2a « foundations » (plan docs/design/m2c-6b-2-plan.md §2, the 6b-2a parts of §6–§9; ADR-0014 « M2c-6b-2a »).
-- What the ops booking of our transfer lines (6b-2b) rests on, kept by the import and the job, and a 6b-1 gap closed:
--   * the statement's own detail of an entry it kept unsplit, stored at import with its line (critic F8, L11): the
--     details of ours in the file's order — id, direction, amount — the entry's detail count and NbOfTxs (critic2
--     ML-5), and the charges the statement records for a line that is its entry's only line (critic2 ML-6, ML-10); a
--     malformed one refused (line_invalid), a known line coming back with other details refused (entry_detail_differs,
--     critic2 CSO2-8); a line imported before this migration keeps none (it is neither compared nor filled);
--   * the job never books a return of a transfer that has an open unplanned booking (`unplanned_payout_return`: the copy
--     that comes back is the unplanned payout's, critic F1, L5), nor one whose second or late debit is on a statement and
--     not booked yet (`return_debit_pending`, critic2 ML-3) — both reviewed, their worker twin with them;
--   * a generated file's sweep is re-checked against the servicer's share at its first download (critic CSO-2, F10,
--     CSO-10): `sweep_exceeds_share`, the file refused `file_blocked` and superseded;
--   * private.unique_subset (6b-2b's lots), the lot cap, the own-line hint in one place;
--   * the alerts transfer_unknown (P0, debits and credits), double_payout_open, own_transfer_payment (P0), payout_returned
--     and sweep_returned for the unplanned returns, bank_line_unbooked's missing members; the M2b pass's own reason
--     own_transfer_line; the S23 texts (« ne peut pas encore »).
-- Nothing a user sees changes but these labels, a download refusal and the S23 texts. No row of the new booking kinds
-- exists before 6b-2b. The cancellation-after-download switch stays OFF; pgTAP 033 and 034 unchanged.
--
-- New: bank_line_booking kinds unplanned_payout_returned and unplanned_sweep_returned (and the partial index of those
-- rows the checks read); bank_debit_review reasons own_transfer_line, unplanned_payout_return, return_debit_pending;
-- bank_transaction (and private.bank_import_stage) unsplit_details, unsplit_detail_count, unsplit_batch_count,
-- charges_minor; private.unsplit_details_valid, private.transfer_unplanned_open, private.own_transfer_line_hint,
-- private.transfer_line_lot_cap, private.unique_subset_trace, private.unique_subset.
-- Redefined, each copied from its latest definition and changed only as its comment says, with its settings and grants
-- restated: private.ingest_statement, private.post_bank_bookings, private.apply_bank_bookings,
-- private.run_transfer_checks, public.assign_payment, public.resolve_duplicate, private.transfer_late_lines (review
-- M2c-6b-2a M1: a line decided a duplicate is no late debit) (20261116090000),
-- private.bank_booking_candidates (20261116090000, dropped and created: two new columns), public.transfer_file_download
-- (20261115090000), private.apply_debit_decisions (20261111090000).

------------------------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------------------------

-- The returns of an unplanned payout or sweep (6b-2b books them, by ops): new kinds, since a planned return reverses the
-- transfer's own entry and is one per transfer (bank_line_booking_return_uq). No row exists before 6b-2b; the job and the
-- alerts read them by name. No new index on transfer_id (bank_line_booking_transfer_idx serves every kind, critic F14);
-- the nightly checks read the unplanned returns of a servicer by this small partial index.
alter table public.bank_line_booking drop constraint bank_line_booking_kind_check,
  add constraint bank_line_booking_kind_check check (kind in ('payout', 'sweep', 'top_up', 'payout_returned',
    'sweep_returned', 'unplanned_payout', 'unplanned_sweep', 'unplanned_payout_returned', 'unplanned_sweep_returned',
    'fee', 'loss', 'client_payment'));
create index bank_line_booking_unplanned_return_idx on public.bank_line_booking (organization_id)
  where kind in ('unplanned_payout_returned', 'unplanned_sweep_returned');
comment on table public.bank_line_booking is
  'Entries of the funds a bank line was booked by: fees, top-ups, the servicer''s losses, payouts, sweeps, their '
  'returns (M2c-6b), unplanned payouts and sweeps and their returns (ops, M2c-6b-2).';

-- Why a line waits for ops: the M2b pass's own reason on one of our lines (S20, OQ-84 (i): before, `changed`); the job's
-- return of a transfer that has an open unplanned booking (critic F1), or whose second debit is pending (critic2 ML-3).
alter table public.bank_debit_review drop constraint bank_debit_review_reason_check,
  add constraint bank_debit_review_reason_check check (reason in ('no_candidate', 'ambiguous', 'amount_differs',
    'partial_return', 'refund_not_pending', 'already_returned', 'changed', 'payment_returned', 'before_previous_return',
    'posting_failed', 'top_up_not_found', 'top_up_differs', 'client_credit', 'own_transfer_out',
    'cancelled_transfer_debited', 'transfer_debited_twice', 'transfer_not_handed_out', 'transfer_unknown',
    'transfer_differs', 'run_not_in_flight', 'batch_partial', 'batch_mixed', 'return_differs', 'return_before_debit',
    'own_transfer_line', 'unplanned_payout_return', 'return_debit_pending'));

-- The statement's own detail of an entry kept unsplit (plan §2.1–§2.2; critic F8, L11; critic2 ML-5, ML-6, ML-10): what a
-- booking of such an entry may rest on (6b-2b) — the bank's file kept on the line, never one person's transcription.
-- unsplit_details: null, or the array of exactly unsplit_ours details of ours {id, direction, amount_minor} in the
-- file's order (amount_minor digits as text, or null when the detail gives no amount in the statement's currency; the
-- element shape is checked at import, private.unsplit_details_valid). unsplit_detail_count and unsplit_batch_count: how
-- many TxDtls the entry has in all (ours or not) and its Btch/NbOfTxs, only beside the details (integer: the count of
-- every detail never overflows; review M2c-6b-2a CS-3: unsplit_ours, 6b-1's smallint, still bounds an entry kept
-- unsplit to 32,767 details of ours — past it the stage's COPY refuses the file, a known limit, COMPLIANCE OQ-85).
-- charges_minor: the charges the statement
-- records for a line that is its entry's only line (Ntry/Chrgs and its one TxDtls/Chrgs: debit records in the
-- account's currency included in the entry amount, else null). Lines imported before this migration keep none.
alter table public.bank_transaction
  add column unsplit_details jsonb,
  add column unsplit_detail_count integer,
  add column unsplit_batch_count integer,
  add column charges_minor bigint check (charges_minor > 0 and charges_minor <= 1000000000000000),
  add constraint bank_transaction_unsplit_details_check check (
    unsplit_details is null
    or (unsplit_ours is not null
        and case when jsonb_typeof(unsplit_details) = 'array'
                 then jsonb_array_length(unsplit_details) = unsplit_ours else false end)),
  add constraint bank_transaction_unsplit_counts_check check (
    (unsplit_details is null) = (unsplit_detail_count is null)
    and (unsplit_batch_count is null or unsplit_details is not null)
    and (unsplit_detail_count is null or (unsplit_ours is not null and unsplit_detail_count >= unsplit_ours))
    and (unsplit_batch_count is null or unsplit_batch_count > 0));
comment on column public.bank_transaction.unsplit_details is
  'camt.053 entry kept unsplit: the details of ours the statement itself gives for it ({id, direction, amount_minor}, '
  'the file''s order; amount_minor text or null), what a booking of the entry may rest on (M2c-6b-2a, plan §2.2).';
comment on column public.bank_transaction.unsplit_detail_count is
  'camt.053 entry kept unsplit: how many TxDtls it has in all, ours or not — what lets a booking tell an entry made '
  'only of our details from one that also holds others, even netting to zero (critic2 ML-5).';
comment on column public.bank_transaction.unsplit_batch_count is
  'camt.053 entry kept unsplit: its NbOfTxs, null when absent (critic2 ML-5).';
comment on column public.bank_transaction.charges_minor is
  'The charges the statement records for the entry of a line that is its entry''s only line (Ntry/Chrgs, its one '
  'TxDtls/Chrgs; debit records in the account''s currency included in the entry amount): the bank''s own record of its '
  'charge, the only fee a booking takes without a third party''s doubt (critic2 ML-6, ML-10).';
alter table private.bank_import_stage
  add column unsplit_details jsonb,
  add column unsplit_detail_count integer,
  add column unsplit_batch_count integer,
  add column charges_minor bigint;

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

-- The element shape of the details the import stores (private.ingest_statement: line_invalid otherwise): exactly
-- p_ours objects, each with exactly the keys id (an id we issue: RMT, SWP, RFD, TOP and 12 upper-case hex digits),
-- direction (debit, credit) and amount_minor (positive digits as text, at most 10^15, or null).
create or replace function private.unsplit_details_valid(p_details jsonb, p_ours integer)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  d jsonb;
begin
  if p_details is null then
    return true;
  end if;
  if p_ours is null or jsonb_typeof(p_details) <> 'array' or jsonb_array_length(p_details) <> p_ours then
    return false;
  end if;
  for d in select e from jsonb_array_elements(p_details) e loop
    if jsonb_typeof(d) <> 'object'
       or (select array_agg(k order by k) from jsonb_object_keys(d) k) is distinct from
          array['amount_minor', 'direction', 'id']
       or jsonb_typeof(d -> 'id') <> 'string' or (d ->> 'id') !~ '^(RMT|SWP|RFD|TOP)[0-9A-F]{12}$'
       or jsonb_typeof(d -> 'direction') <> 'string' or (d ->> 'direction') not in ('debit', 'credit') then
      return false;
    end if;
    if jsonb_typeof(d -> 'amount_minor') <> 'null'
       and (jsonb_typeof(d -> 'amount_minor') <> 'string' or (d ->> 'amount_minor') !~ '^[1-9][0-9]{0,15}$'
            or (d ->> 'amount_minor')::numeric > 1000000000000000) then
      return false;
    end if;
  end loop;
  return true;
end;
$$;

-- Whether a transfer has an unplanned booking (unplanned_payout, unplanned_sweep: 6b-2b) whose entry is not reversed —
-- by key: its bookings by bank_line_booking_transfer_idx, each entry's reversal by ledger_entry_reversed_once_uq.
create or replace function private.transfer_unplanned_open(p_transfer_id uuid)
returns boolean
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select p_transfer_id is not null and exists (
    select 1
    from (select k.entry_id from public.bank_line_booking k
          where k.transfer_id = p_transfer_id and k.kind in ('unplanned_payout', 'unplanned_sweep') offset 0) k
    where not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = k.entry_id offset 0));
$$;

-- The hint of an own_transfer_line refusal, one place per caller (plan §2.6): `bank_booking` (private.post_bank_bookings'
-- strict refusal) here; 6b-2c adds `debit_link` and `own_credit` and rewords them with the screen. Today's wording.
create or replace function private.own_transfer_line_hint(p_where text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_where = 'bank_booking' then
    return 'Cette ligne est un débit ou un retour de nos propres virements (reversement, quote-part du cabinet, lot de '
           'notre fichier) : elle se comptabilise depuis le relevé, automatiquement ou par l''équipe (écran à venir). '
           'Elle ne se rattache pas à un paiement et ne se classe pas sans comptabilisation.';
  end if;
  raise exception 'own_transfer_line_hint: unknown caller %', p_where using errcode = '22023';
end;
$$;

-- The lot cap (plan §1.3 item 15; critic CSO-3; critic2 CSO2-2): a PmtInf, an unsplit entry or a lot credit of more
-- items is refused lot_too_large by 6b-2b (support books it). One constant, read by the parse, the options, the
-- preview, the command and the label's test; its value set by 6b-2b's scale run with 2× headroom under the API's 8 s.
create or replace function private.transfer_line_lot_cap()
returns integer
language sql
immutable
parallel safe
set search_path = ''
as $$
  select 500;
$$;

-- The only subset of a lot's amounts that makes a line (plan §2.5; critic2 CSO2-2), traced: the 1-based indexes of the
-- only subset of p_amounts summing to p_target, or null — none, several, an amount that is not positive, or past a
-- bound — with, when a bound stopped it, which (`cap`, `sums`, `paths`, `work`) and at which item (0 for the cap). The
-- Python twin is payments.debits.unique_subset_trace (the integration test compares them, the bound and the item
-- included).
-- A dynamic programme over partial sums with a count capped at 2 and, for a count of 1, its path. It works on the
-- smaller side t' = least(p_target, Σ − p_target) — a subset makes t iff its complement makes Σ − t — and answers the
-- complement when t' is not the target. Amounts above t' are skipped; the others are visited in the order given (the
-- callers pass a PmtInf's items by seq, members by theirs), so both twins trip a bound at the same item. Bounds: more
-- amounts than private.transfer_line_lot_cap() → null at once; past p_sums_bound partial sums (10,000, as
-- private.amounts_make_up) or p_paths_bound stored path entries (Σ of the path lengths of the sums one subset alone
-- reaches: 200,000) → null; and the work bound: Σ over the items visited of the number of partial sums before each,
-- past p_work_bound (1,000,000) → null — the partial-sum bound alone does not bound the run time (below 10,000 minor
-- units the sums saturate at t' + 1 and never trip it).
-- Two representations, the same counts: when t' (divided by the gcd of t' and the amounts visited) is below 2^18, the
-- partial sums are a bit string (reached: one OR of a shift per item, its size bit_count) and only the sums one subset
-- alone reaches are kept as rows with their path (a record per sum: its item and the record it extends) — the worst
-- saturating input (500 amounts of 5–90 €, t' = 8 000) trips the work bound in well under 0.5 s; otherwise every
-- partial sum is a row with its count (the partial-sum bound keeps them under 10,000).
create or replace function private.unique_subset_trace(p_amounts bigint[], p_target bigint,
                                                       p_sums_bound integer default 10000,
                                                       p_paths_bound integer default 200000,
                                                       p_work_bound bigint default 1000000)
returns table (indexes integer[], tripped_at integer, bound text)
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  n integer := coalesce(cardinality(p_amounts), 0);
  v_total numeric;
  v_t bigint;
  v_g bigint;
  v_tn bigint;
  v_bits boolean;
  v_b1 varbit;
  v_sh varbit;
  -- the sums reached by exactly one subset (bit mode), or every sum (row mode): sum, count, record, path length
  v_s bigint[] := array[0::bigint];
  v_c smallint[] := array[1::smallint];
  v_r integer[] := array[0];
  v_l integer[] := array[0];
  v_ns bigint[];
  v_nr integer[];
  v_nl integer[];
  -- the records: item and the record it extends (0: the empty subset)
  v_ri integer[] := '{}';
  v_rp integer[] := '{}';
  v_work bigint := 0;
  v_sums bigint;
  v_paths bigint;
  a bigint;
  i integer;
  v_k integer;
  v_rec integer;
  v_path integer[] := '{}';
begin
  if n > private.transfer_line_lot_cap() then
    return query select null::integer[], 0, 'cap'::text;
    return;
  end if;
  if p_target is null or p_target < 0 or exists (select 1 from unnest(p_amounts) x where x is null or x <= 0) then
    return query select null::integer[], null::integer, null::text;
    return;
  end if;
  select coalesce(sum(x), 0) into v_total from unnest(p_amounts) x;
  if p_target > v_total then
    return query select null::integer[], null::integer, null::text;
    return;
  end if;
  v_t := least(p_target, (v_total - p_target)::bigint);
  v_g := v_t;
  for i in 1 .. n loop
    if p_amounts[i] <= v_t then
      v_g := gcd(v_g, p_amounts[i]);
    end if;
  end loop;
  if v_g = 0 then
    v_g := 1;
  end if;
  v_tn := v_t / v_g;
  v_bits := v_tn < 262144;
  if v_bits then
    v_b1 := B'1' || repeat('0', v_tn::integer)::varbit;
  end if;
  for i in 1 .. n loop
    a := p_amounts[i];
    continue when a > v_t;
    v_work := v_work + case when v_bits then bit_count(v_b1) else cardinality(v_s) end;
    if v_work > p_work_bound then
      return query select null::integer[], i, 'work'::text;
      return;
    end if;
    if v_bits then
      a := a / v_g;
      v_sh := v_b1 >> a::integer;
      -- the sums one subset alone reaches now: those nothing reaches through this item (s − a not reached), and the new
      -- ones, reached through it from one such sum where nothing was
      select coalesce(array_agg(c.s + a order by c.s), '{}'), coalesce(array_agg(c.r order by c.s), '{}'),
             coalesce(array_agg(c.l + 1 order by c.s), '{}')
      into v_ns, v_nr, v_nl
      from unnest(v_s, v_r, v_l) c (s, r, l)
      where case when c.s + a > v_tn then false else get_bit(v_b1, (c.s + a)::integer) = 0 end;
      select coalesce(array_agg(c.s), '{}'), coalesce(array_agg(c.r), '{}'), coalesce(array_agg(c.l), '{}')
      into v_s, v_r, v_l
      from unnest(v_s, v_r, v_l) c (s, r, l)
      where case when c.s < a then true else get_bit(v_b1, (c.s - a)::integer) = 0 end;
      v_k := cardinality(v_ri);
      v_s := v_s || v_ns;
      v_r := v_r || array(select v_k + g from generate_series(1, cardinality(v_ns)) g);
      v_l := v_l || v_nl;
      v_ri := v_ri || array_fill(i, array[cardinality(v_ns)]);
      v_rp := v_rp || v_nr;
      v_b1 := v_b1 | v_sh;
      v_sums := bit_count(v_b1);
      select coalesce(sum(x), 0) into v_paths from unnest(v_l) x;
    else
      -- every sum with its count (capped at 2): the old ones and the ones this item extends, merged
      with cur as (select u.s, u.c, u.r, u.l from unnest(v_s, v_c, v_r, v_l) u (s, c, r, l)),
      g as (select z.s, least(2, sum(z.c))::smallint as c,
                   max(z.r) filter (where z.src = 0 and z.c = 1) as old_r,
                   max(z.r) filter (where z.src = 1 and z.c = 1) as ext_r,
                   max(z.l) filter (where z.src = 0) as old_l,
                   max(z.l) filter (where z.src = 1) as ext_l,
                   bool_or(z.src = 0) as had
            from (select cur.s, cur.c, cur.r, cur.l, 0 as src from cur
                  union all
                  select cur.s + a, cur.c, cur.r, cur.l + 1, 1 from cur where cur.s <= v_t - a) z
            group by z.s),
      k as (select g.*, case when g.c = 1 and not g.had
                             then row_number() over (partition by g.c = 1 and not g.had order by g.s) end as nk
            from g)
      select array_agg(k.s), array_agg(k.c),
             array_agg(case when k.c = 1 then case when k.had then k.old_r else cardinality(v_ri) + k.nk::integer end end),
             array_agg(case when k.c = 1 then case when k.had then k.old_l else k.ext_l end else 0 end),
             v_ri || coalesce(array_agg(i order by k.nk) filter (where k.c = 1 and not k.had), '{}'),
             v_rp || coalesce(array_agg(k.ext_r order by k.nk) filter (where k.c = 1 and not k.had), '{}')
      into v_s, v_c, v_r, v_l, v_ri, v_rp
      from k;
      v_sums := cardinality(v_s);
      select coalesce(sum(x), 0) into v_paths from unnest(v_l) x;
    end if;
    if v_sums > p_sums_bound then
      return query select null::integer[], i, 'sums'::text;
      return;
    end if;
    if v_paths > p_paths_bound then
      return query select null::integer[], i, 'paths'::text;
      return;
    end if;
  end loop;
  if v_bits then
    select x.k into v_k from unnest(v_s) with ordinality x (s, k) where x.s = v_tn;
  else
    select x.k into v_k from unnest(v_s, v_c) with ordinality x (s, c, k) where x.s = v_t and x.c = 1;
  end if;
  if v_k is null then
    return query select null::integer[], null::integer, null::text;
    return;
  end if;
  v_rec := v_r[v_k];
  while v_rec > 0 loop
    v_path := v_ri[v_rec] || v_path;
    v_rec := v_rp[v_rec];
  end loop;
  if v_t <> p_target then
    v_path := array(select g from generate_series(1, n) g where g <> all (v_path) order by g);
  end if;
  return query select v_path, null::integer, null::text;
end;
$$;

-- The only subset (plan §2.5): private.unique_subset_trace's answer with the default bounds.
create or replace function private.unique_subset(p_amounts bigint[], p_target bigint)
returns integer[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select x.indexes from private.unique_subset_trace(p_amounts, p_target) x;
$$;

------------------------------------------------------------------------------------------
-- The import keeps the statement's own detail of an entry kept unsplit (plan §2.2)
------------------------------------------------------------------------------------------

-- private.ingest_statement, redefined from 20261116090000 (same signature, body and settings; its grants restated below).
-- M2c-6b-2a: the stage's unsplit_details, unsplit_detail_count, unsplit_batch_count and charges_minor are copied with
-- the line; a line is well formed only with its details of the shape private.unsplit_details_valid checks (exactly
-- unsplit_ours details of ours), its counts only beside them (the detail count at least unsplit_ours, NbOfTxs
-- positive) and a positive charge on a camt.053 line (line_invalid otherwise). (critic2 CSO2-8) A known line (same
-- account and dedup_key) is still skipped, but when its stored details, detail count and NbOfTxs, or charges differ
-- from the file's, the file is refused `entry_detail_differs`, as an entry that comes back split another way — the
-- bank's corrected statement is never silently ignored; a stored null (a line imported before this migration, or a line
-- the statement gave no charge for) is neither compared nor filled. Nothing else changes.
create or replace function private.ingest_statement(p_statement_id uuid, p_header jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.bank_statement;
  b public.bank_account;
  prev public.bank_statement;
  v_sections jsonb := coalesce(p_header -> 'sections', '[]');
  v_bad text;
  v_n bigint;
  v_new bigint;
  v_entries bigint := 0;
  v_cash_in jsonb;
  v_counts jsonb;
  v_warnings jsonb := '[]';
  v_check jsonb;
  v_from date;
  v_to date;
  v_cash bigint;
  v_unposted record;
  v_own text[];
begin
  select * into s from public.bank_statement where id = p_statement_id for update;
  if not found then
    raise exception 'statement_unknown: statement % does not exist', p_statement_id using errcode = '22023';
  end if;
  if s.status <> 'uploaded' then
    return jsonb_build_object('skipped', s.status);  -- a redelivered job: already done
  end if;
  -- One import at a time per bank account: dedup, overlaps and suspected duplicates see every earlier line.
  perform pg_advisory_xact_lock(hashtext('bank_import:' || s.bank_account_id::text));
  select * into b from public.bank_account where id = s.bank_account_id for share;  -- a closure waits
  if b.status <> 'active' or b.purpose <> 'client_funds' then
    raise exception 'bank_account_closed: bank account % is not an active client_funds account', b.id
      using errcode = '22023';
  end if;
  -- A file is the statement of one bank account: imported for another account of the servicer (the
  -- wrong one chosen first), it is refused, so its money is never booked on two accounts. Imports of
  -- the same file are serialised across the servicer's accounts.
  perform pg_advisory_xact_lock(hashtext('bank_import_file:' || s.organization_id::text || ':' || s.file_sha256));
  select min(p.bank_account_id::text) into v_bad from public.bank_statement p
  where p.organization_id = s.organization_id and p.file_sha256 = s.file_sha256
    and p.bank_account_id <> s.bank_account_id and p.status = 'imported';
  if v_bad is not null then
    raise exception 'imported_on_other_account: this file was imported for bank account %', v_bad using errcode = '22023';
  end if;
  if coalesce(p_header ->> 'format', '') <> s.format or jsonb_typeof(v_sections) <> 'array'
     or (s.format = 'camt053' and jsonb_array_length(v_sections) = 0)
     or (s.format = 'csv' and jsonb_array_length(v_sections) <> 0)
     or coalesce(p_header ->> 'version', '00') !~ '^[0-9]{2}$' then
    raise exception 'header_invalid: the parsed header does not describe a % statement', s.format using errcode = '22023';
  end if;

  -- This statement's lines, in a working table of our own (ADR-0012 temp-schema rule), analysed: every
  -- later query starts from it, so no plan depends on the statistics of the tables loaded below.
  drop table if exists pg_temp._bi_stage;
  create temp table _bi_stage on commit drop as
  select * from private.bank_import_stage where statement_id = p_statement_id;
  alter table pg_temp._bi_stage add primary key (line_no);
  analyze pg_temp._bi_stage;
  -- M2c-1 (§12): our own transfers and credits are classified here whatever the parser knew (the registered own IBANs
  -- may be newer than the job's list): a credit carrying our TOP id or from a registered own IBAN is ours, never a
  -- debtor payment; one from a client's payout IBAN goes to ops; a debit carrying our RMT/SWP id or to our own IBAN
  -- is a transfer out. The stage rows are kept in step (a line held as a duplicate keeps this reading).
  v_own := array(select o.iban from public.bank_account o
                 where o.organization_id = s.organization_id and o.purpose = 'own');
  -- M2c-2: the clients' IBANs in one pass over the lines (private.stage_refined_kinds), never a scan of the servicer's
  -- whole list per line
  drop table if exists pg_temp._bi_refined;
  create temp table _bi_refined on commit drop as
  select r.line_no, r.kind from private.stage_refined_kinds(s.organization_id, v_own) r;
  if exists (select 1 from pg_temp._bi_refined) then
    update pg_temp._bi_stage x set kind = r.kind from pg_temp._bi_refined r where r.line_no = x.line_no;
    update private.bank_import_stage x set kind = r.kind from pg_temp._bi_refined r
    where x.statement_id = p_statement_id and x.line_no = r.line_no;
  end if;
  -- review M2c-6b-1 round 8 (T1): a credit naming a handed-out lot of this account, whatever its end-to-end id, is our
  -- transfer coming back — a return, never a payment (the database's reading, after the pure classifier's; the lot read
  -- only for a credit read as a debtor's credit or an unsplit batch whose PmtInfId has our form)
  drop table if exists pg_temp._bi_lot;
  create temp table _bi_lot on commit drop as
  select x.line_no from pg_temp._bi_stage x
  where x.direction = 'credit' and x.kind in ('debtor_credit', 'batch_unsplit')
    and case when x.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
             then private.names_our_lot(s.bank_account_id, x.payment_info_id) else false end;
  if exists (select 1 from pg_temp._bi_lot) then
    update pg_temp._bi_stage x set kind = 'return' from pg_temp._bi_lot l where l.line_no = x.line_no;
    update private.bank_import_stage x set kind = 'return' from pg_temp._bi_lot l
    where x.statement_id = p_statement_id and x.line_no = l.line_no;
  end if;
  select count(*) into v_n from pg_temp._bi_stage;
  if v_n <> coalesce((p_header ->> 'line_count')::bigint, -1) then
    raise exception 'header_invalid: % staged lines, % announced', v_n, p_header ->> 'line_count' using errcode = '22023';
  end if;

  -- Lines are well formed (first offending line named).
  select min(x.line_no)::text into v_bad from pg_temp._bi_stage x where x.currency <> s.currency;
  if v_bad is not null then
    raise exception 'currency_mismatch: line % is not in %', v_bad, s.currency using errcode = '22023';
  end if;
  select min(x.line_no)::text into v_bad from pg_temp._bi_stage x where x.booking_date > private.paris_today();
  if v_bad is not null then
    raise exception 'future_booking_date: line % is booked after today', v_bad using errcode = '22023';
  end if;
  select min(x.line_no)::text into v_bad from pg_temp._bi_stage x
  where x.direction is null or x.direction not in ('credit', 'debit')
     or x.amount_minor is null or x.amount_minor <= 0 or x.amount_minor > 1000000000000000
     or x.booking_date is null or x.dedup_key is null or x.dedup_key !~ '^[tech]:' or length(x.dedup_key) > 300
     or x.method is null or x.method not in ('sct', 'sdd', 'card', 'cheque', 'other')
     or x.kind is null or x.kind not in ('debtor_credit', 'return', 'refund_out', 'other_debit', 'batch_unsplit',
                                         'transfer_out', 'own_transfer_in', 'client_transfer_in')
     or (x.direction = 'credit' and x.kind not in ('debtor_credit', 'return', 'batch_unsplit', 'own_transfer_in',
                                                   'client_transfer_in'))
     or (x.direction = 'debit' and x.kind in ('debtor_credit', 'own_transfer_in', 'client_transfer_in'))
     or length(x.payment_info_id) not between 1 and 35
     or (s.format = 'csv' and (x.section_no <> 0 or x.dedup_key !~ '^[ch]:' or x.entry_ref is not null))
     or (s.format = 'camt053' and (x.section_no < 1 or x.section_no > jsonb_array_length(v_sections)
                                   or x.dedup_key !~ '^[teh]:'))
     or length(x.entry_ref) not between 1 and 300
     -- review M2c-6b-1 round 6 (R1): the count of an unsplit entry's details of ours, on a camt.053 line of an entry only
     or x.unsplit_ours < 0 or (x.unsplit_ours is not null and (s.format <> 'camt053' or x.batch_entry_ref is null))
     -- review round 7 (S2): a credit of an entry kept unsplit holding a detail of ours is a return, never a payment
     or (x.direction = 'credit' and x.unsplit_ours > 0 and x.kind <> 'return')
     -- review round 8 (T2): a line of an entry kept unsplit carrying an id we issue (RMT, SWP, RFD, TOP) counts it
     or (x.unsplit_ours = 0 and (coalesce(x.end_to_end_id ~ '^(RMT|SWP|RFD|TOP)[0-9A-F]{12}$', false)
                                 or coalesce(x.original_end_to_end_id ~ '^(RMT|SWP|RFD|TOP)[0-9A-F]{12}$', false)))
     -- M2c-6b-2a (plan §2.1–§2.2; critic F8, L11; critic2 ML-5, ML-6): the statement's own details of an entry kept
     -- unsplit — an array of exactly unsplit_ours details of ours, each {id, direction, amount_minor}
     -- (private.unsplit_details_valid); its detail count (at least unsplit_ours) and NbOfTxs only with them; a charge
     -- positive, on a camt.053 line only
     or (x.unsplit_details is not null and not private.unsplit_details_valid(x.unsplit_details, x.unsplit_ours))
     or ((x.unsplit_details is null) <> (x.unsplit_detail_count is null))
     or x.unsplit_detail_count < 0 or x.unsplit_detail_count < x.unsplit_ours
     or x.unsplit_batch_count <= 0 or (x.unsplit_batch_count is not null and x.unsplit_details is null)
     or x.charges_minor <= 0 or x.charges_minor > 1000000000000000
     or (x.charges_minor is not null and s.format <> 'camt053')
     -- an entry key is e:<the line's entry reference>#<n>, n from 1
     or (x.dedup_key ~ '^e:' and not coalesce(left(x.dedup_key, length(x.entry_ref) + 3) = 'e:' || x.entry_ref || '#'
                                              and substr(x.dedup_key, length(x.entry_ref) + 4) ~ '^[1-9][0-9]*$', false));
  if v_bad is not null then
    raise exception 'line_invalid: line % is not a well-formed bank line', v_bad using errcode = '22023';
  end if;
  select min(d.dedup_key) into v_bad
  from (select x.dedup_key from pg_temp._bi_stage x group by x.dedup_key having count(*) > 1) d;
  if v_bad is not null then
    raise exception 'duplicate_reference_in_file: % appears twice in the file', v_bad using errcode = '22023';
  end if;

  -- camt.053: per <Stmt>, opening + credits - debits = closing (the parser checked it already).
  if s.format = 'camt053' then
    select min(sec.ord)::text into v_bad
    from jsonb_array_elements(v_sections) with ordinality as sec (v, ord)
    left join (select x.section_no,
                      sum(case x.direction when 'credit' then x.amount_minor else -x.amount_minor end) as moved
               from pg_temp._bi_stage x group by x.section_no) m on m.section_no = sec.ord
    where sec.v ->> 'opening_minor' is null or sec.v ->> 'closing_minor' is null
       or (sec.v ->> 'opening_minor')::numeric + coalesce(m.moved, 0) <> (sec.v ->> 'closing_minor')::numeric;
    if v_bad is not null then
      raise exception 'unbalanced: statement % of the file: opening + lines <> closing balance', v_bad
        using errcode = '22023';
    end if;
  end if;

  -- 1. Lines this bank account reported already (the same file again, an overlapping statement): skipped,
  --    but only when the bank tells the same facts. A known reference with another amount, direction or
  --    date refuses the file: a line is never dropped because its reference was reused.
  drop table if exists pg_temp._bi_known;
  create temp table _bi_known on commit drop as
  select x.line_no, (x.direction, x.amount_minor, x.booking_date) is distinct from
                    (t.direction, t.amount_minor, t.booking_date) as conflict,
         -- M2c-6b-2a (critic2 CSO2-8): the details, counts or charges the bank now gives for a line it gave before
         -- with others (a line imported before 6b-2a, without them, is neither compared nor filled)
         (t.unsplit_details is not null and x.unsplit_details is not null
          and x.unsplit_details is distinct from t.unsplit_details)
         or (t.unsplit_detail_count is not null
             and (x.unsplit_detail_count, x.unsplit_batch_count)
                 is distinct from (t.unsplit_detail_count, t.unsplit_batch_count))
         or (t.charges_minor is not null and x.charges_minor is distinct from t.charges_minor) as detail_differs
  from pg_temp._bi_stage x
  join public.bank_transaction t on t.bank_account_id = s.bank_account_id and t.dedup_key = x.dedup_key;
  select min(k.line_no)::text into v_bad from pg_temp._bi_known k where k.conflict;
  if v_bad is not null then
    raise exception 'reference_conflict: line % has the bank reference of an earlier line with another amount, direction or date',
      v_bad using errcode = '22023';
  end if;
  -- M2c-6b-2a (critic2 CSO2-8): the bank's corrected statement is never silently ignored — a known line whose stored
  -- details, detail count or charges differ from the file's refuses it, as an entry that comes back split another way
  select min(k.line_no)::text into v_bad from pg_temp._bi_known k where k.detail_differs;
  if v_bad is not null then
    raise exception 'entry_detail_differs: line % is a bank line imported earlier with other details, counts or charges',
      v_bad using errcode = '22023';
  end if;
  drop table if exists pg_temp._bi_new;
  create temp table _bi_new on commit drop as
  select x.* from pg_temp._bi_stage x
  where not exists (select 1 from pg_temp._bi_known k where k.line_no = x.line_no);
  alter table pg_temp._bi_new add primary key (line_no);
  analyze pg_temp._bi_new;

  -- A camt.053 entry (Ntry/AcctSvcrRef) is booked once, at the level of detail of its first import: a new
  -- line of an entry this bank account already has means the entry comes back split another way (unsplit
  -- then detailed, or the reverse, or other detail references). Refused: the money would be booked twice.
  v_bad := private.bank_import_entry_known(s.bank_account_id)::text;
  if v_bad is not null then
    raise exception 'entry_detail_differs: line % is part of a bank entry imported earlier with other details', v_bad
      using errcode = '22023';
  end if;

  -- 2. CSV safety net (design §8.3 step 5): same day, amount and direction as a line of another import,
  --    with a similar label -> held as a suspected duplicate (no payment, no cash) until ops decide. Two
  --    lines that both carry the bank's own id are different transactions by the bank's word.
  if s.format = 'csv' then
    -- The same operation on another bank account of the servicer (an export uploaded on the wrong
    -- account first): with the bank's id and the same day, amount and direction, the bank says it is the
    -- same operation and the file is refused; with the same fingerprint (no bank id), the line is held.
    drop table if exists pg_temp._bi_elsewhere;
    create temp table _bi_elsewhere on commit drop as
    select * from private.bank_import_lines_elsewhere(s.organization_id, s.bank_account_id);
    select min(e.line_no)::text into v_bad from pg_temp._bi_elsewhere e where e.dedup_key like 'c:%';
    if v_bad is not null then
      raise exception 'imported_on_other_account: line % was imported for another bank account', v_bad
        using errcode = '22023';
    end if;
    update pg_temp._bi_new n set kind = 'suspected_duplicate'
    from pg_temp._bi_elsewhere e where e.line_no = n.line_no;

    update pg_temp._bi_new n set kind = 'suspected_duplicate'
    from (select distinct x.line_no
          from pg_temp._bi_new x
          join public.bank_transaction t on t.bank_account_id = s.bank_account_id and t.booking_date = x.booking_date
            and t.amount_minor = x.amount_minor and t.direction = x.direction
          where not (x.dedup_key like 'c:%' and t.dedup_key like 'c:%')
            and extensions.similarity(upper(coalesce(t.counterparty_name, '') || ' ' || coalesce(t.remittance_text, '')),
                                      upper(coalesce(x.counterparty_name, '') || ' ' || coalesce(x.remittance_text, '')))
                >= 0.5) d
    where n.line_no = d.line_no;
  end if;

  -- 3. The facts.
  drop table if exists pg_temp._bi_ins;
  create temp table _bi_ins (id uuid primary key, line_no integer not null unique) on commit drop;
  with ins as (
    insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
      amount_minor, currency, booking_date, value_date, reversal_indicator, bank_tx_code, acct_svcr_ref, end_to_end_id,
      tx_id, mandate_ref, counterparty_name, ultimate_counterparty_name, counterparty_iban, remittance_text,
      creditor_reference, return_reason, original_end_to_end_id, batch_entry_ref, entry_ref, kind, payment_info_id,
      unsplit_ours, unsplit_details, unsplit_detail_count, unsplit_batch_count, charges_minor)
    select s.organization_id, s.bank_account_id, s.id, n.line_no, n.dedup_key, n.direction, n.amount_minor, s.currency,
           n.booking_date, n.value_date, coalesce(n.reversal_indicator, false), n.bank_tx_code, n.acct_svcr_ref,
           n.end_to_end_id, n.tx_id, n.mandate_ref, n.counterparty_name, n.ultimate_counterparty_name,
           n.counterparty_iban, n.remittance_text, n.creditor_reference, n.return_reason, n.original_end_to_end_id,
           n.batch_entry_ref, n.entry_ref, n.kind, n.payment_info_id, n.unsplit_ours, n.unsplit_details,
           n.unsplit_detail_count, n.unsplit_batch_count, n.charges_minor
    from pg_temp._bi_new n
    order by n.line_no
    on conflict (bank_account_id, dedup_key) do nothing
    returning id, line_no
  )
  insert into pg_temp._bi_ins select ins.id, ins.line_no from ins;
  analyze pg_temp._bi_ins;
  select count(*) into v_new from pg_temp._bi_ins;
  if v_new <> (select count(*) from pg_temp._bi_new) then
    -- cannot happen under the per-account lock; retried by the queue if it ever does
    raise exception 'statement %: lines were imported concurrently', s.id using errcode = '40001';
  end if;

  -- 4. One payment per credit a debtor paid (bank facts copied; unmatched until M2b-3 matches it).
  drop table if exists pg_temp._bi_pay;
  create temp table _bi_pay on commit drop as
  select i.id as bank_transaction_id, n.line_no, n.booking_date, n.amount_minor
  from pg_temp._bi_ins i join pg_temp._bi_new n on n.line_no = i.line_no
  where n.direction = 'credit' and n.kind in ('debtor_credit', 'batch_unsplit');
  analyze pg_temp._bi_pay;
  insert into public.payment (organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, value_date, payer_name, payer_iban, end_to_end_id,
                              remittance_text, creditor_reference)
  select s.organization_id, s.bank_account_id, p.bank_transaction_id, s.format, n.method, n.amount_minor, s.currency,
         n.booking_date, n.value_date, coalesce(n.counterparty_name, n.ultimate_counterparty_name), n.counterparty_iban,
         n.end_to_end_id, n.remittance_text, n.creditor_reference
  from pg_temp._bi_pay p join pg_temp._bi_new n on n.line_no = p.line_no
  order by p.line_no;

  -- 5. cash_in: one entry per booking date of this statement (design §2 #1), Dr 5120 / Cr 4710 pool.
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  select (row_number() over (order by d.booking_date))::integer, s.organization_id, 'cash_in', d.booking_date,
         'cash_in:' || s.id::text || ':' || d.booking_date::text, 'bank_statement', s.id::text
  from (select distinct p.booking_date from pg_temp._bi_pay p) d;
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
  select e.entry_no, l.line_no, l.book, l.sign * t.total, s.currency,
         case when l.book = 'client_money_cash' then s.bank_account_id end
  from pg_temp._lps_entry e
  join (select p.booking_date, sum(p.amount_minor) as total from pg_temp._bi_pay p group by p.booking_date) t
    on t.booking_date = e.effective_date
  cross join (values (1, 'client_money_cash', 1), (2, 'unallocated_payment', -1)) as l (line_no, book, sign);
  if exists (select 1 from pg_temp._lps_entry) then
    select count(*) into v_entries from private.ledger_post_set() r where r.created;
  end if;

  -- 6. I11, from the tables: for each booking date, the cash booked for this statement = Σ of its payments.
  select coalesce(jsonb_agg(jsonb_build_object('date', y.d, 'entry_id', y.entry_id, 'minor', y.total::text)
                            order by y.d), '[]')
  into v_cash_in
  from (select e.effective_date as d, e.id as entry_id, sum(lp.amount_minor) as total
        from (select distinct p.booking_date from pg_temp._bi_pay p) k
        join public.ledger_entry e on e.organization_id = s.organization_id
          and e.idempotency_key = 'cash_in:' || s.id::text || ':' || k.booking_date::text
        join public.ledger_posting lp on lp.entry_id = e.id
        join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'client_money_cash'
        group by e.effective_date, e.id) y;
  select min(coalesce(x.d, (y.v ->> 'date')::date)::text) into v_bad
  from (select p.booking_date as d, sum(p.amount_minor) as total
        from pg_temp._bi_pay k join public.payment p on p.bank_transaction_id = k.bank_transaction_id
        group by p.booking_date) x
  full join jsonb_array_elements(v_cash_in) y (v) on (y.v ->> 'date')::date = x.d
  where x.total is distinct from (y.v ->> 'minor')::bigint;
  if v_bad is not null then
    raise exception 'statement %: the cash booked on % differs from its payments (I11)', s.id, v_bad using errcode = 'LG001';
  end if;

  -- 7. What the import did (amounts as text).
  select jsonb_build_object(
    'lines', v_n,
    'new_lines', v_new,
    'known_lines', v_n - v_new,
    'skipped_not_booked', coalesce((p_header ->> 'skipped_not_booked')::bigint, 0),
    'credits', jsonb_build_object('lines', count(*) filter (where n.direction = 'credit'),
                                  'minor', coalesce(sum(n.amount_minor) filter (where n.direction = 'credit'), 0)::text),
    'debits', jsonb_build_object('lines', count(*) filter (where n.direction = 'debit'),
                                 'minor', coalesce(sum(n.amount_minor) filter (where n.direction = 'debit'), 0)::text),
    'payments', jsonb_build_object('count', count(p.line_no), 'minor', coalesce(sum(p.amount_minor), 0)::text),
    'unposted', jsonb_build_object(
      'lines', count(*) filter (where p.line_no is null),
      'minor', coalesce(sum(case n.direction when 'credit' then n.amount_minor else -n.amount_minor end)
                        filter (where p.line_no is null), 0)::text),
    'cash_in', v_cash_in,
    'cash_in_entries', v_entries,
    'returns', count(*) filter (where n.kind = 'return'),
    'refunds_out', count(*) filter (where n.kind = 'refund_out'),
    'other_debits', count(*) filter (where n.kind = 'other_debit'),
    'batch_unsplit', count(*) filter (where n.kind = 'batch_unsplit'),
    'suspected_duplicates', count(*) filter (where n.kind = 'suspected_duplicate'),
    'transfers_out', count(*) filter (where n.kind = 'transfer_out'),
    'own_transfers_in', count(*) filter (where n.kind = 'own_transfer_in'),
    'client_transfers_in', count(*) filter (where n.kind = 'client_transfer_in'))
  into v_counts
  from pg_temp._bi_new n left join pg_temp._bi_pay p on p.line_no = n.line_no;

  -- 8. Dates and balances of the file; continuity with the previous statement (« relevé manquant »).
  if s.format = 'camt053' then
    select min((v ->> 'from_date')::date), max((v ->> 'to_date')::date) into v_from, v_to
    from jsonb_array_elements(v_sections) v;
    -- within the file
    select coalesce(jsonb_agg(jsonb_build_object('code', 'opening_differs', 'stmt_id', cur.v ->> 'stmt_id',
                                                 'expected_minor', pre.v ->> 'closing_minor',
                                                 'actual_minor', cur.v ->> 'opening_minor') order by cur.ord), '[]')
    into v_warnings
    from jsonb_array_elements(v_sections) with ordinality as cur (v, ord)
    join jsonb_array_elements(v_sections) with ordinality as pre (v, ord) on pre.ord = cur.ord - 1
    where (cur.v ->> 'opening_minor')::bigint <> (pre.v ->> 'closing_minor')::bigint;
    -- with the statement that covers the day before this one: of the imported statements starting before
    -- it, the one that ends last (an index scan). If it ends on or after this one's first day, the day
    -- before is covered already (the overlap warning says so): nothing to compare. Only the closing at
    -- its last day is known, so an older statement is never compared.
    select * into prev from public.bank_statement p
    where p.bank_account_id = s.bank_account_id and p.status = 'imported' and p.format = 'camt053'
      and p.from_date < v_from
    order by p.to_date desc, p.finished_at desc
    limit 1;
    if found and prev.to_date < v_from then
      if prev.closing_booked_minor is distinct from (v_sections -> 0 ->> 'opening_minor')::bigint then
        v_warnings := v_warnings || jsonb_build_object('code', 'opening_differs', 'previous_statement_id', prev.id,
          'expected_minor', prev.closing_booked_minor::text, 'actual_minor', v_sections -> 0 ->> 'opening_minor');
      end if;
      if (prev.sections -> -1 ->> 'seq') is not null and (v_sections -> 0 ->> 'seq') is not null
         and (v_sections -> 0 ->> 'seq')::bigint not in ((prev.sections -> -1 ->> 'seq')::bigint + 1, 1) then
        v_warnings := v_warnings || jsonb_build_object('code', 'sequence_gap', 'previous_statement_id', prev.id,
          'previous_seq', prev.sections -> -1 ->> 'seq', 'seq', v_sections -> 0 ->> 'seq');
      end if;
    end if;
  else
    select min(x.booking_date), max(x.booking_date) into v_from, v_to from pg_temp._bi_stage x;
  end if;
  select count(*) into v_n from public.bank_statement p
  where p.bank_account_id = s.bank_account_id and p.status = 'imported' and p.from_date <= v_to and p.to_date >= v_from;
  if v_n > 0 then
    v_warnings := v_warnings || jsonb_build_object('code', 'overlap', 'statements', v_n);
  end if;

  -- 9. I9 at import: closing balance = 5120[bank] + lines not booked (camt.053 only: a CSV has no balance).
  if s.format = 'camt053' then
    select coalesce(sum(lp.amount_minor), 0)::bigint into v_cash
    from public.ledger_account la
    join public.ledger_posting lp on lp.ledger_account_id = la.id and lp.effective_date <= v_to
    where la.bank_account_id = s.bank_account_id and la.book = 'client_money_cash';
    select * into v_unposted from private.bank_unposted(s.bank_account_id, v_to);
    v_check := jsonb_build_object(
      'as_of', v_to,
      'closing_minor', v_sections -> -1 ->> 'closing_minor',
      'cash_minor', v_cash::text,
      'unposted_minor', v_unposted.minor::text,
      'unposted_lines', v_unposted.lines,
      'difference_minor', ((v_sections -> -1 ->> 'closing_minor')::bigint - v_cash - v_unposted.minor)::text);
  end if;

  update public.bank_statement
  set status = 'imported', finished_at = now(),
      format_version = case when s.format = 'camt053' then p_header ->> 'version' end,
      stmt_id = v_sections -> 0 ->> 'stmt_id',
      electronic_seq_no = (v_sections -> 0 ->> 'seq')::bigint,
      from_date = v_from, to_date = v_to,
      opening_booked_minor = (v_sections -> 0 ->> 'opening_minor')::bigint,
      closing_booked_minor = (v_sections -> -1 ->> 'closing_minor')::bigint,
      sections = case when s.format = 'camt053' then v_sections end,
      counts = v_counts, warnings = v_warnings, bank_check = v_check
  where id = s.id;
  delete from private.bank_import_stage where statement_id = s.id;
  return v_counts;
end;
$$;

------------------------------------------------------------------------------------------
-- The job: a return of a transfer that has an open unplanned booking, or a debit pending (plan §2.3)
------------------------------------------------------------------------------------------

-- private.transfer_late_lines, redefined from 20261116090000 (same signature and settings; its grants restated below).
-- Review M2c-6b-2a (M1): a line held as a suspected duplicate that ops decided is a duplicate of another line
-- (bank_duplicate_resolution, by its key) is no movement — it is never booked, linked nor paid — so it is never a late
-- debit of the transfer. Without this, `debit_pending` (the job's return rule, its candidates and its SQL re-check) read
-- it as a debit waiting to be booked, and reviewed the transfer's every return `return_debit_pending` for good: the
-- client's returned payout was never owed nor paid again; and the P0 cancelled_transfer_debited named it for good. A
-- held line not decided yet is still counted (it may be released as a second debit): its return waits, and the review's
-- label says to decide it first. Nothing else changes.
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

-- private.bank_booking_candidates, redefined from 20261116090000 (dropped and created: two new columns; same settings,
-- its grants restated below): a return's facts, `unplanned_open` (private.transfer_unplanned_open: an unplanned booking
-- of the transfer whose entry is not reversed) and `debit_pending` (private.transfer_late_lines: a debit line of the
-- transfer on a statement not booked beyond its booked debit), each by key, for a return row only. Nothing else changes.
drop function private.bank_booking_candidates(uuid, date, uuid, integer);
create function private.bank_booking_candidates(p_organization_id uuid, p_after_date date, p_after_id uuid,
                                                p_limit integer)
returns table (line_id uuid, line_kind text, direction text, bank_account_id uuid, currency char(3),
               amount_minor bigint, booking_date date, bank_tx_code text, end_to_end_id text,
               original_end_to_end_id text, payment_info_id text, role text, transfer_id uuid, transfer_kind text,
               transfer_status text, transfer_amount_minor bigint, transfer_currency char(3),
               transfer_debtor_bank_account_id uuid, transfer_creditor_bank_account_id uuid, transfer_date date,
               transfer_file_id uuid, file_status text, file_download_count integer, pmt_inf_id text,
               batch_file_id uuid, batch_file_status text, batch_file_download_count integer, run_id uuid,
               run_status text, run_transfer_id uuid, replaces_transfer_id uuid, debit_booked boolean,
               return_booked boolean, return_seen boolean, unsplit_ours smallint, names_our_lot boolean,
               unplanned_open boolean, debit_pending boolean)
language plpgsql
stable
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare
  v_limit integer := greatest(coalesce(p_limit, 2000), 1);
begin
  return query
  with k as materialized (
    select z.id, z.booking_date
    from (
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id
         and t.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id offset 0)
       order by t.booking_date, t.id limit v_limit)
      union
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id and t.direction = 'debit' and t.end_to_end_id is null
         and t.payment_info_id is not null and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
         and t.kind in ('other_debit', 'batch_unsplit', 'transfer_out')
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
         and (t.kind = 'transfer_out' or private.pmt_inf_single_refund(t.bank_account_id, t.payment_info_id) is null)
       order by t.booking_date, t.id limit v_limit)
      union
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id and t.direction = 'credit' and t.kind = 'return'
         and coalesce(t.original_end_to_end_id, t.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$'
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
       order by t.booking_date, t.id limit v_limit)
      union
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id and t.kind = 'other_debit'
         and split_part(t.bank_tx_code, '/', 3) in ('CHRG', 'FEES')
         and not (t.end_to_end_id is null and coalesce(t.payment_info_id, '') ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
       order by t.booking_date, t.id limit v_limit)
      union
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id and t.kind = 'suspected_duplicate'
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id
                       and r.decision = 'released'
                       and (r.released_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
                            -- review round 4 (N1): a held credit returning our payout or sweep, released as a return
                            -- (the M2b pass leaves it to this pass, as the import's)
                            or (r.released_kind = 'return' and t.direction = 'credit'
                                and coalesce(t.original_end_to_end_id, t.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$'))
                     offset 0)
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id offset 0)
       order by t.booking_date, t.id limit v_limit)
      union
      -- review round 7 (S2): a line of an entry kept unsplit holding a detail of ours, whatever its kind and direction
      -- (never booked, always reviewed: the M2b pass never reads it)
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id and t.unsplit_ours > 0
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id offset 0)
       order by t.booking_date, t.id limit v_limit)) z
    order by z.booking_date, z.id
    limit v_limit),
  x as materialized (
    select t.id, coalesce(r.released_kind, t.kind) as kind, t.direction, t.bank_account_id, t.currency, t.amount_minor,
           t.booking_date, t.bank_tx_code, t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id, t.unsplit_ours,
           -- review round 7 (S3): a credit naming one of our lots of its account (a file handed out), whatever its
           -- end-to-end id: never a top-up
           case when t.direction = 'credit' and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
                then private.names_our_lot(t.bank_account_id, t.payment_info_id) else false end as names_our_lot
    from k
    cross join lateral (select q.* from public.bank_transaction q where q.id = k.id offset 0) t
    left join lateral (select q.decision, q.released_kind from public.bank_duplicate_resolution q
                       where q.bank_transaction_id = t.id offset 0) r on true),
  -- what each line names: its own id's transfer, the members of its PmtInf, the transfer it returns, the top-up — each
  -- transfer read once, by its key (its whole row carried on)
  f as materialized (
    select x.id as line_id, n.role, n.tr, n.batch_file_id
    from x
    cross join lateral (
      select 'own'::text as role, q.t as tr, null::uuid as batch_file_id
      from (select y as t from public.bank_transfer y
            where x.direction = 'debit' and x.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$'
              and y.end_to_end_id = x.end_to_end_id offset 0) q
      where (q.t).organization_id = p_organization_id
      union all
      select 'return', q.t, null
      from (select y as t from public.bank_transfer y
            where x.direction = 'credit' and x.kind = 'return'
              and coalesce(x.original_end_to_end_id, x.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$'
              and y.end_to_end_id = coalesce(x.original_end_to_end_id, x.end_to_end_id) offset 0) q
      where (q.t).organization_id = p_organization_id
      union all
      select 'top_up', q.t, null
      from (select y as t from public.bank_transfer y
            where x.kind = 'own_transfer_in' and y.end_to_end_id = x.end_to_end_id offset 0) q
      where (q.t).organization_id = p_organization_id
      union all
      select 'member', m.t, i.file_id
      from (select y.file_id, y.transfer_id from public.transfer_file_item y
            where x.direction = 'debit' and x.end_to_end_id is null
              and x.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$' and y.pmt_inf_id = x.payment_info_id
            offset 0) i
      cross join lateral (select y.debtor_bank_account_id, y.organization_id from public.transfer_file y
                          where y.id = i.file_id offset 0) fl
      cross join lateral (select y as t from public.bank_transfer y where y.id = i.transfer_id offset 0) m
      where fl.debtor_bank_account_id = x.bank_account_id and fl.organization_id = p_organization_id
        and (m.t).transfer_file_id = i.file_id) n)
  select x.id, x.kind, x.direction, x.bank_account_id, x.currency, x.amount_minor, x.booking_date, x.bank_tx_code,
         x.end_to_end_id, x.original_end_to_end_id, x.payment_info_id, f.role, (f.tr).id, (f.tr).kind, (f.tr).status,
         (f.tr).amount_minor, (f.tr).currency, (f.tr).debtor_bank_account_id, (f.tr).creditor_bank_account_id,
         ((f.tr).created_at at time zone 'Europe/Paris')::date, (f.tr).transfer_file_id, tf.status, tf.download_count,
         (select i.pmt_inf_id from public.transfer_file_item i
          where i.file_id = (f.tr).transfer_file_id and i.transfer_id = (f.tr).id),
         f.batch_file_id, bf.status, bf.download_count, (f.tr).run_id, ru.status, ru.transfer_id,
         (f.tr).replaces_transfer_id,
         case when (f.tr).id is not null then exists (select 1 from public.bank_line_booking b
                                                        where b.transfer_id = (f.tr).id
                                                          and b.kind in ('payout', 'sweep', 'top_up') offset 0) end,
         case when (f.tr).id is not null then exists (select 1 from public.bank_line_booking b
                                                        where b.transfer_id = (f.tr).id
                                                          and b.kind in ('payout_returned', 'sweep_returned')
                                                        offset 0) end,
         case when (f.tr).status = 'cancelled' then private.transfer_return_seen((f.tr).id) end, x.unsplit_ours,
         x.names_our_lot,
         -- M2c-6b-2a (plan §2.3): a return's facts, keyed as private.post_bank_bookings reads them — an unplanned booking
         -- of the transfer whose entry is not reversed, a debit line of it on a statement not booked beyond its booked
         -- debit
         case when f.role = 'return' then private.transfer_unplanned_open((f.tr).id) end,
         case when f.role = 'return' then exists (select 1 from private.transfer_late_lines((f.tr).id)) end
  from x
  left join f on f.line_id = x.id
  left join lateral (select q.status, q.download_count from public.transfer_file q
                     where q.id = (f.tr).transfer_file_id offset 0) tf on true
  left join lateral (select q.status, q.download_count from public.transfer_file q where q.id = f.batch_file_id
                     offset 0) bf on true
  left join lateral (select q.status, q.transfer_id from public.remittance_run q where q.id = (f.tr).run_id offset 0)
    ru on true
  order by x.booking_date, x.id, (f.tr).id;
end;
$$;

-- private.post_bank_bookings, redefined from 20261116090000 (same signature, body and settings; its grants restated
-- below). M2c-6b-2a: `_bb` gains, for a return of a transfer of this servicer, `tr_unplanned_open` and
-- `tr_debit_pending` (as private.bank_booking_candidates reads them), and the return rules two, right after
-- `return_before_debit` and before `already_returned`: an open unplanned booking → `unplanned_payout_return` (critic F1,
-- L5: a booked or returned transfer executed again, a cancelled one executed late — until now return_differs); a debit
-- pending on a statement → `return_debit_pending` (critic2 ML-3: booked as the planned payout's return, its re-owed item
-- could be paid by a run handed out before ops book that debit). The strict own-line hint comes from
-- private.own_transfer_line_hint('bank_booking'), unchanged. Nothing else changes.
create or replace function private.post_bank_bookings(p_organization_id uuid, p_strict boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_why record;
  v_l record;
  v_state text;
  v_msg text;
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
  if exists (select 1 from pg_temp._bank_booking b where b.kind in ('payout', 'payout_returned', 'unplanned_payout')) then
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
      -- never in a file: our TOP id, typed in the bank)
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
      when b.direction <> 'credit' or b.line_kind <> 'own_transfer_in' then 'not_an_own_credit'
      when b.amount_minor is not null then 'bad_request'
      when b.transfer_id is not null and (b.tr_org is distinct from p_organization_id or b.tr_kind <> 'top_up'
                                          or b.tr_creditor is distinct from b.line_bank) then 'transfer_unknown'
      when b.transfer_id is not null and b.tr_status <> 'ordered' then 'transfer_not_pending'
      when b.transfer_id is not null and (b.tr_minor <> b.line_minor or b.tr_currency <> b.currency) then 'amount_differs'
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

  select b.why into v_why from pg_temp._bb b where b.why is not null order by b.ord limit 1;
  if found and p_strict then
    if v_why.why = 'own_transfer_line' then
      raise exception 'bank booking refused: %', v_why.why using errcode = 'check_violation',
        hint = private.own_transfer_line_hint('bank_booking');
    end if;
    raise exception 'bank booking refused: %', v_why.why using errcode = 'check_violation';
  end if;
  insert into pg_temp._booking_skipped (bank_transaction_id, why)
  select distinct on (b.bank_transaction_id) b.bank_transaction_id, b.why from pg_temp._bb b where b.why is not null
  order by b.bank_transaction_id, b.ord
  on conflict (bank_transaction_id) do update set why = excluded.why;
  delete from pg_temp._bb b where b.why is not null;
  analyze pg_temp._bb;

  if p_strict then
    begin
      perform private.bank_booking_post_rows(p_organization_id);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      if v_state like 'LG%' or v_state like '22%' or v_state like '23%' then
        raise exception 'bank booking refused: posting_failed (%: %)', v_state, left(v_msg, 500)
          using errcode = 'check_violation';
      end if;
      raise;
    end;
  elsif exists (select 1 from pg_temp._bb) then
    begin
      perform private.bank_booking_post_rows(p_organization_id);   -- the whole chunk at once
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
        raise;
      end if;
      -- a line the posting refuses: each LINE tried alone with all its rows (always rolled back), the refused ones to
      -- ops, then the others together
      drop table if exists pg_temp._bb_all;
      create temp table _bb_all on commit drop as select * from pg_temp._bb;
      for v_l in select a.bank_transaction_id from pg_temp._bb_all a group by a.bank_transaction_id
               order by min(a.ord) loop
        begin
          delete from pg_temp._bb b where b.bank_transaction_id is not null;
          insert into pg_temp._bb select * from pg_temp._bb_all a where a.bank_transaction_id = v_l.bank_transaction_id;
          perform private.bank_booking_post_rows(p_organization_id);
          raise exception 'bank booking tried' using errcode = 'BB000';
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
          if v_state <> 'BB000' then
            if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
              raise;
            end if;
            insert into pg_temp._booking_failed (bank_transaction_id, detail)
            values (v_l.bank_transaction_id, left(v_state || ': ' || v_msg, 2000))
            on conflict (bank_transaction_id) do nothing;
          end if;
        end;
      end loop;
      delete from pg_temp._bb b where b.bank_transaction_id is not null;
      insert into pg_temp._bb select * from pg_temp._bb_all a
      where not exists (select 1 from pg_temp._booking_failed f where f.bank_transaction_id = a.bank_transaction_id);
      if exists (select 1 from pg_temp._bb) then
        perform private.bank_booking_post_rows(p_organization_id);
      end if;
    end;
  end if;

  -- M2c-1's counts, then (only when some were posted) the debits' bookings
  return jsonb_build_object(
    'fees', (select count(*) from pg_temp._bb where kind = 'fee'),
    'top_ups', (select count(*) from pg_temp._bb where kind = 'top_up'),
    'losses', (select count(*) from pg_temp._bb where kind = 'loss'),
    'skipped', (select count(*) from pg_temp._booking_skipped),
    'failed', (select count(*) from pg_temp._booking_failed))
    || jsonb_strip_nulls(jsonb_build_object(
         'payouts', (select nullif(count(*), 0) from pg_temp._bb where kind = 'payout'),
         'sweeps', (select nullif(count(*), 0) from pg_temp._bb where kind = 'sweep'),
         'returns', (select nullif(count(*), 0) from pg_temp._bb where kind in ('payout_returned', 'sweep_returned')),
         'advances', (select nullif(count(*), 0) from pg_temp._bb_cover)));
end;
$$;

-- private.apply_bank_bookings, redefined from 20261116090000 (same settings; its grants restated below): a row the
-- re-check refused `unplanned_payout_return` or `return_debit_pending` — the line's own state, as the job's rules review
-- it — is reviewed under that reason, as `return_before_debit` is, not `changed`. Nothing else changes.
create or replace function private.apply_bank_bookings(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb;
begin
  update pg_temp._bank_booking set method = 'auto', decided_by = null where bank_transaction_id is not null;
  v := private.post_bank_bookings(p_organization_id, false);
  insert into pg_temp._booking_review (bank_transaction_id, reason, detail)
  select f.bank_transaction_id, 'posting_failed', f.detail from pg_temp._booking_failed f
  on conflict (bank_transaction_id) do update set reason = excluded.reason, detail = excluded.detail;
  insert into pg_temp._booking_review (bank_transaction_id, reason, detail)
  select s.bank_transaction_id,
         case when s.why in ('return_before_debit', 'unplanned_payout_return', 'return_debit_pending') then s.why
              else 'changed' end,
         case when s.why in ('return_before_debit', 'unplanned_payout_return', 'return_debit_pending') then null
              else s.why end
  from pg_temp._booking_skipped s
  on conflict (bank_transaction_id) do nothing;
  delete from public.bank_debit_review v using pg_temp._booking_review r where v.bank_transaction_id = r.bank_transaction_id;
  insert into public.bank_debit_review (bank_transaction_id, organization_id, reason, candidates, detail)
  select r.bank_transaction_id, p_organization_id, r.reason, r.candidates, r.detail
  from pg_temp._booking_review r
  cross join lateral (select q.organization_id from public.bank_transaction q
                      where q.id = r.bank_transaction_id offset 0) t
  where t.organization_id = p_organization_id
    and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_own_credit_release c
                    where c.bank_transaction_id = r.bank_transaction_id offset 0);
  return v || jsonb_build_object('reviews', (select count(*) from pg_temp._booking_review));
end;
$$;

------------------------------------------------------------------------------------------
-- The M2b pass's own reason (plan §2.6; S20, OQ-84 (i))
------------------------------------------------------------------------------------------

-- private.apply_debit_decisions, redefined from 20261111090000 (same settings; its grants restated below): a link the
-- re-check refused because its line is one of our transfers' (`own_transfer_line`) is reviewed `own_transfer_line`, not
-- `changed` — the line waits for its booking, never for another try. Nothing else changes.
create or replace function private.apply_debit_decisions(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb;
begin
  update pg_temp._debit_link set method = 'auto', decided_by = null, expected_left_minor = null
  where bank_transaction_id is not null;
  v := private.post_debit_links(p_organization_id, false);
  -- refused by the posting itself: ops decide (never retried in a loop: the next run tries it once more)
  insert into pg_temp._debit_review (bank_transaction_id, reason, candidates, detail)
  select f.bank_transaction_id, 'posting_failed', f.candidates, f.detail from pg_temp._debit_failed f
  on conflict (bank_transaction_id) do update
    set reason = excluded.reason, candidates = excluded.candidates, detail = excluded.detail;
  -- M2c-6b-2a (plan §2.6; S20, OQ-84 (i)): a link refused because the line is one of our transfers' is reviewed so
  insert into pg_temp._debit_review (bank_transaction_id, reason)
  select s.bank_transaction_id, case when s.why = 'own_transfer_line' then s.why else 'changed' end
  from pg_temp._debit_skipped s
  on conflict (bank_transaction_id) do nothing;
  delete from public.bank_debit_review v using pg_temp._debit_review r where v.bank_transaction_id = r.bank_transaction_id;
  insert into public.bank_debit_review (bank_transaction_id, organization_id, reason, candidates, detail)
  select r.bank_transaction_id, p_organization_id, r.reason, r.candidates, r.detail
  from pg_temp._debit_review r
  cross join lateral (select q.organization_id from public.bank_transaction q
                      where q.id = r.bank_transaction_id offset 0) t
  where t.organization_id = p_organization_id
    and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_own_credit_release c
                    where c.bank_transaction_id = r.bank_transaction_id offset 0);
  return v || jsonb_build_object('reviews', (select count(*) from pg_temp._debit_review));
end;
$$;

------------------------------------------------------------------------------------------
-- A generated file's sweep re-checked at its first download (plan §2.4)
------------------------------------------------------------------------------------------

-- public.transfer_file_download, redefined from 20261115090000 (same signature, settings and body; its grants restated
-- below). M2c-6b-2a (critic CSO-2, F10, CSO-10): at the first download of a generated file, beside the holds and the
-- cash check, its `in_file` sweep is compared with the servicer's share now, read under the remit lock the function
-- already holds (every writer of 4679 holds it) by generate_transfer_file's own formula — −Σ 4679 of the servicer and
-- currency, less the other sweeps ordered or in a file. A sweep above it is blocked `{transfer_id, kind: 'sweep',
-- reason: 'sweep_exceeds_share', sweep_minor, share_minor}`: the file is refused `file_blocked` and superseded — the
-- sweep cancelled (sweeps are never re-queued), the payouts ordered again with their dates, the next file recomputing
-- the share. This covers every movement between generation and download (the job's payout_overrun covers and bank fees,
-- 6b-2b's advances and fees). A pending file is never served (not_ready) and is re-checked when downloaded generated. A
-- sweep already handed out may still over-sweep: 4679 then goes into debit and servicer_shortfall (P0) asks for a
-- top-up. 6b-3 adds generation's D4 rule (private.debited_cancelled_sweeps) here with the switch. Nothing else changes.
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
          where i.file_id = f.id and t.kind in ('payout', 'refund')) x
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
                where i.file_id = f.id and t.kind in ('payout', 'refund') and t.status = 'in_file'
                  and t.transfer_file_id = f.id and private.transfer_debited_before(t.id)) then
    raise exception 'transfer file refused: holds_debited_transfer' using errcode = 'check_violation',
      hint = 'Un virement de ce fichier a déjà quitté le compte (débité sous la référence du virement qu''il remplace, ou dans une ligne groupée de son lot) : ne déposez pas ce fichier ; s''il l''a été, demandez à la banque de ne pas l''exécuter.';
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

------------------------------------------------------------------------------------------
-- Alerts (plan §2.6)
------------------------------------------------------------------------------------------

-- private.run_transfer_checks, redefined from 20261116090000 (same settings; its grants restated below). M2c-6b-2a:
-- transfer_unknown is a P0 alert, the lines the job reviewed so (debits and credits, critic L14) not booked nor linked,
-- as transfer_debited_twice; double_payout_open: a double payout's advance (cause double_payout), open until recovered,
-- none once its entry is reversed; own_transfer_payment (P0, critic L10): a payment made of a line carrying our RMT/SWP
-- id or naming one of our lots, unassigned for more than one business day; payout_returned also for an unplanned
-- payout's return (its item waiting), sweep_returned for an unplanned sweep's (the share not swept again) — the planned
-- payout_returned branch now only for the transfer's own payout; bank_line_unbooked also counts an entry kept unsplit
-- holding ours, a credit naming our lot, an own or client credit carrying our RMT/SWP id (the inventory: they were
-- missed), and the lines reviewed unplanned_payout_return or return_debit_pending; review M2c-6b-2a (M2, T1): it reads a
-- held line released by ops as the kind it was released as (a released line keeps the kind suspected_duplicate: a
-- released return was not counted before). Nothing else changes.
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
                              'reasons', to_jsonb(array_agg(distinct v.reason)))
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

------------------------------------------------------------------------------------------
-- The S23 texts (plan §2.6; critic L10; founder Q13's default)
------------------------------------------------------------------------------------------

-- public.assign_payment, redefined from 20261116090000 (same signature, settings and body; its grants restated below):
-- its own_transfer_line hint only — such a payment is one of our transfers coming back, which Collectoo cannot book as
-- that return yet (a recorded payment is not undone; M2c-7): support is told, no screen is promised.
create or replace function public.assign_payment(p_idempotency_key text, p_payment_id uuid, p_splits jsonb,
                                                 p_designation jsonb, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  p public.payment;
  a public.account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_account uuid;
  v_items uuid[];
  v_source text;
  v_doc uuid;
  v_designation jsonb;
  v_suggested jsonb;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'splits', p_splits, 'designation', p_designation,
                                  'reason', v_reason);
  v_result := private.command_replay('assign_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  -- review M2c-6b-1 round 4 (N1, in depth): a payment whose bank line carries one of our transfers' ids (made before
  -- round 4 read such a credit as a return) is our own money coming back, never a debtor's payment
  if exists (select 1 from public.bank_transaction t
             where t.id = p.bank_transaction_id
               and (private.names_our_transfer(t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id)
                    -- review round 8 (T1): a handed-out lot of its account named, whatever its end-to-end id
                    or case when t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
                            then private.names_our_lot(t.bank_account_id, t.payment_info_id) else false end)) then
    raise exception 'payment assignment refused: own_transfer_line' using errcode = 'check_violation',
      hint = 'Ce paiement vient d''une ligne qui porte la référence de l''un de nos propres virements (reversement, '
             'quote-part du cabinet, lot de notre fichier) : c''est ce virement qui revient, pas le paiement d''un '
             'débiteur. Il ne s''affecte à aucun dossier, et Collectoo ne peut pas encore le comptabiliser comme le '
             'retour de ce virement (un paiement enregistré ne se défait pas ; prévu avec M2c-7) : prévenez le support.';
  end if;
  if p.status <> 'unmatched' or p.account_id is not null then
    raise exception 'the payment is already matched: unassign it first' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_splits) is distinct from 'array' or jsonb_array_length(p_splits) <> 1
     or jsonb_typeof(p_splits -> 0) <> 'object' or (p_splits -> 0) ? 'amount_text'
     or coalesce(p_splits -> 0 ->> 'account_id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'one file for the whole payment (splitting comes with allocation)' using errcode = 'check_violation';
  end if;
  v_account := (p_splits -> 0 ->> 'account_id')::uuid;
  select * into a from public.account where id = v_account;
  if not found or a.organization_id <> p.organization_id then
    raise exception 'unknown file' using errcode = 'check_violation';
  end if;
  if a.status = 'staged' then
    raise exception 'the file is not confirmed yet' using errcode = 'check_violation';
  end if;
  if p_designation is not null then
    -- The debtor's own indication « lorsqu'il paie » (1342-10): invoices of this file only.
    v_source := p_designation ->> 'source';
    if jsonb_typeof(p_designation -> 'item_ids') is distinct from 'array'
       or v_source is null or v_source not in ('remittance_text', 'document', 'portal') then
      raise exception 'invalid designation' using errcode = 'check_violation';
    end if;
    select array_agg(distinct x.v::uuid) into v_items
    from jsonb_array_elements_text(p_designation -> 'item_ids') x (v)
    where x.v ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    if coalesce(cardinality(v_items), 0) = 0 or cardinality(v_items) <> jsonb_array_length(p_designation -> 'item_ids')
       or (select count(*) from public.claim_item i where i.account_id = a.id and i.id = any (v_items))
          <> cardinality(v_items) then
      raise exception 'invalid designation: invoices of this file only' using errcode = 'check_violation';
    end if;
    if v_source = 'document' then
      -- the debtor's letter or e-mail, filed on this file (not any document of the client)
      v_doc := nullif(p_designation ->> 'evidence_document_id', '')::uuid;
      if v_doc is null or not exists (select 1 from public.document d where d.id = v_doc
                                        and d.organization_id = a.organization_id
                                        and d.client_organization_id = a.client_organization_id
                                        and d.account_id = a.id) then
        raise exception 'invalid designation: the document is required, filed on this file'
          using errcode = 'check_violation';
      end if;
    end if;
    v_designation := jsonb_build_object('item_ids', to_jsonb(v_items), 'source', v_source,
                                        'evidence_document_id', v_doc, 'captured_at', now());
  end if;
  -- what ops saw proposed, kept with the decision
  select jsonb_agg(jsonb_build_object('rank', c.rank, 'account_id', c.account_id, 'rule', c.rule) order by c.rank)
  into v_suggested from public.payment_match_candidate c where c.payment_id = p.id;
  perform private.assign_begin();
  insert into pg_temp._assign (ord, payment_id, account_id, method, rule, rule_version, evidence, designation, teaches)
  values (1, p.id, a.id, 'manual', null, 'ops',
          jsonb_strip_nulls(jsonb_build_object('suggested', v_suggested)), v_designation, true);
  perform private.record_assignments(p.organization_id, 'ops', auth.uid(), v_reason);
  select jsonb_build_object('payment_id', x.id, 'account_id', a.id, 'review_reason', x.review_reason)
  into v_result from public.payment x where x.id = p.id;
  perform private.command_record('assign_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- public.resolve_duplicate, redefined from 20261116090000 (same signature, settings and body; its grants restated below):
-- its own_transfer_line hint only. Build check (plan §2.6): « Libérer » cannot release such a held line as a return —
-- its reading recorded before round 4 says debtor_credit (private.held_line_kind keeps a recorded reading), and the
-- command takes no other kind — so the line stays in « Doublons possibles »; the hint says so. Review M2c-6b-2a (M1): a
-- debit decided a duplicate queues the debit job (`process_debits`), as a release as a return already does: a return of
-- our transfer it kept waiting (`return_debit_pending`, private.transfer_late_lines) is read again at once, not at the
-- next import that queues the job. Nothing else changes.
create or replace function public.resolve_duplicate(p_idempotency_key text, p_bank_transaction_id uuid,
                                                    p_is_duplicate boolean, p_reason text)
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
  k record;
  v_payment uuid;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'is_duplicate', p_is_duplicate,
                                  'reason', v_reason);
  v_result := private.command_replay('resolve_duplicate', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if t.kind <> 'suspected_duplicate' or p_is_duplicate is null then
    raise exception 'duplicate: this line is not held as a suspected duplicate' using errcode = 'check_violation';
  end if;
  perform pg_advisory_xact_lock(hashtext('bank_import:' || t.bank_account_id::text));
  if exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id) then
    raise exception 'duplicate: already decided: reload the page' using errcode = 'check_violation';
  end if;
  if p_is_duplicate then
    insert into public.bank_duplicate_resolution (bank_transaction_id, organization_id, bank_account_id, decision,
                                                  reason, decided_by)
    values (t.id, t.organization_id, t.bank_account_id, 'duplicate', v_reason, auth.uid());
    -- review M2c-6b-2a (M1): a debit decided a duplicate is no late debit of our transfer any more
    -- (private.transfer_late_lines): a return it kept waiting (return_debit_pending) is read again now
    if t.direction = 'debit' then
      perform pgmq.send('payments', jsonb_build_object('type', 'process_debits', 'organization_id', t.organization_id));
    end if;
    v_result := jsonb_build_object('bank_transaction_id', t.id, 'decision', 'duplicate');
  else
    select * into k from private.held_line_kind(t.id);
    -- review round 4 (N1, in depth): a line carrying one of our transfers' ids is never released as a payment (a reading
    -- recorded before round 4 may say debtor_credit; read from its facts it is a return)
    if k.kind in ('debtor_credit', 'batch_unsplit')
       and private.names_our_transfer(t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id) then
      raise exception 'duplicate release refused: own_transfer_line' using errcode = 'check_violation',
        hint = 'Cette ligne porte la référence de l''un de nos propres virements (reversement, quote-part du cabinet, '
               'lot de notre fichier) : c''est ce virement qui revient, jamais le paiement d''un débiteur. Lue ainsi '
               'avant la correction de l''import, elle ne peut être ni libérée comme un paiement ni encore '
               'comptabilisée comme ce retour : elle reste dans « Doublons possibles ». Prévenez le support.';
    end if;
    insert into public.bank_duplicate_resolution (bank_transaction_id, organization_id, bank_account_id, decision,
                                                  released_kind, reason, decided_by)
    values (t.id, t.organization_id, t.bank_account_id, 'released', k.kind, v_reason, auth.uid());
    if k.kind in ('debtor_credit', 'batch_unsplit') then
      v_payment := private.book_credit_payment(t.id, k.method,
                                               coalesce(t.counterparty_name, t.ultimate_counterparty_name),
                                               t.counterparty_iban, null);
      perform pgmq.send('payments', jsonb_build_object('type', 'match', 'organization_id', t.organization_id,
                                                       'trigger', 'import'));
    elsif k.kind in ('return', 'refund_out') then
      perform pgmq.send('payments', jsonb_build_object('type', 'process_debits', 'organization_id', t.organization_id));
    end if;
    v_result := jsonb_build_object('bank_transaction_id', t.id, 'decision', 'released', 'kind', k.kind,
                                   'payment_id', v_payment);
  end if;
  perform private.command_record('resolve_duplicate', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new ones internal)
------------------------------------------------------------------------------------------

-- critic2 CSO2-11: the new helpers are internal (PostgreSQL grants EXECUTE to PUBLIC by default); only the SECURITY
-- DEFINER callers use them
revoke execute on function private.unsplit_details_valid(jsonb, integer), private.transfer_unplanned_open(uuid),
  private.own_transfer_line_hint(text), private.transfer_line_lot_cap(),
  private.unique_subset_trace(bigint[], bigint, integer, integer, bigint), private.unique_subset(bigint[], bigint)
  from public, anon, authenticated;
-- the redefined internals as granted by 20261116090000 (the funds pass's: the worker's)
revoke execute on function private.bank_booking_candidates(uuid, date, uuid, integer),
  private.post_bank_bookings(uuid, boolean), private.apply_bank_bookings(uuid),
  private.run_transfer_checks(uuid, uuid, date), private.transfer_late_lines(uuid)
  from public, anon, authenticated, service_role;
grant execute on function private.bank_booking_candidates(uuid, date, uuid, integer), private.apply_bank_bookings(uuid)
  to service_role;
-- the import, as granted by 20261109120000 (the worker's)
revoke execute on function private.ingest_statement(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function private.ingest_statement(uuid, jsonb) to service_role;
-- the M2b pass's decisions, as granted by 20261110120000 and 20261111090000 (the worker's)
revoke execute on function private.apply_debit_decisions(uuid) from public, anon, authenticated, service_role;
grant execute on function private.apply_debit_decisions(uuid) to service_role;
-- the commands, as granted by 20261115090000 and 20261116090000 (the back office's)
revoke execute on function public.transfer_file_download(uuid, text, boolean),
  public.assign_payment(text, uuid, jsonb, jsonb, text), public.resolve_duplicate(text, uuid, boolean, text)
  from public, anon;
grant execute on function public.transfer_file_download(uuid, text, boolean),
  public.assign_payment(text, uuid, jsonb, jsonb, text), public.resolve_duplicate(text, uuid, boolean, text)
  to authenticated;
