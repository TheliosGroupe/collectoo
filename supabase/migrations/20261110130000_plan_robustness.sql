-- Plan robustness: the per-row lookups of the payment functions keep their order whatever the statistics say.
-- Forward-only: nothing of 20261110120000 or earlier is edited; the functions below are redefined with the same
-- signature, the same results, the same privileges and the same SET clauses, except where a comment says which one
-- changes. Only the plans change.
--
-- The trap (CI scale job, auto_explain, M2b-6): `enable_hashjoin = off` / `enable_mergejoin = off` forbid join methods,
-- not a join order. With statistics a few minutes stale (a table loaded and not analysed yet, or analysed before the
-- rows a test adds), a forced nested loop put the wrong side outside:
--   * private.payment_positions took 439 s for a 10k-payment allocation chunk: inside its per-payment lateral the
--     planner started from the pooled 4710 accounts (book = 'unallocated_payment', estimated 2 rows), read all their
--     postings (estimated 19 an account, tens of thousands in fact) and kept those of the payment's entries: every
--     posting of the pool read once per payment;
--   * private.bank_import_entry_known took 133 s in a 50k import: bank_transaction outside (estimated 1 line for the
--     account, 13.5k in fact), the 50k new lines scanned for each of them.
-- The order is made structural instead: a lateral subquery that cannot be pulled up (LIMIT, or OFFSET 0) referencing
-- the outer row, so the outer row is always outside; a correlated scalar subquery for a keyed lookup (as
-- private.ledger_entry_verify does). Each function below drives from the row it is about and reaches every other row
-- by its key. Where one pass over a set is the right plan (bank_import_lines_elsewhere), the nested loop is forbidden
-- instead, so the join is a hash join: linear whatever the estimates.
--
-- Redefined: private.bank_import_entry_known, private.bank_import_lines_elsewhere (20261109120000),
-- public.unassign_payment (20261109150000), private.payment_positions (20261109190000), private.receipt_payload
-- (20261110090000), public.payment_detail and private.debit_candidates (20261110120000, M2b-6 as merged: their bodies
-- are copied from it, only the lookups named in their comments change).

------------------------------------------------------------------------------------------
-- Statement import: the new lines (pg_temp._bi_new of private.ingest_statement) against the stored ones
------------------------------------------------------------------------------------------

-- The first new line whose bank entry (camt.053 Ntry/AcctSvcrRef) this bank account has already. The new lines are
-- outside by construction (lateral, LIMIT 1): one probe of bank_transaction_entry_idx per new line that has an entry
-- reference, never the account's lines scanned per new line (CI: 133 s for 50k new lines on an account whose 13.5k
-- lines the statistics did not know yet). The account is compared through an init-plan parameter: estimated as an
-- average account, never as « no line », so the probe uses the index on (account, entry reference) and not one that
-- reads every line of the account. `enable_seqscan = off` (added): the LIMIT divides a scan's cost by the rows it is
-- expected to find, so on an account whose lines share few bank entries (batch bookings, n_distinct 25 on 50k lines,
-- pages not all-visible yet) a seq scan of bank_transaction per new line looked cheaper than the probe: 4.2 s for 500
-- new lines (about 17 min for 50k) against 1.8 ms with the probe.
create or replace function private.bank_import_entry_known(p_bank_account_id uuid)
returns integer
language plpgsql
stable
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
set enable_bitmapscan = off
set enable_seqscan = off
as $$
begin
  return (select min(x.line_no)
          from pg_temp._bi_new x
          cross join lateral (select 1 from public.bank_transaction t
                              where t.bank_account_id = (select p_bank_account_id) and t.entry_ref = x.entry_ref
                              limit 1) k
          where x.entry_ref is not null);
end;
$$;

-- New lines whose key is on another bank account of the servicer with the same day, amount and direction: one hash
-- join of the new lines with the other accounts' lines on the key (enable_nestloop and enable_mergejoin off; the SET
-- clauses change from hashjoin/mergejoin/bitmapscan off). One pass over each side whatever the statistics: a probe per
-- new line (a nested loop) was not robust, the old join reading the other account's lines once per new line (197 s for
-- 50k CSV lines when bank_transaction's statistics were stale), a keyed probe on `= any (others)` reading the whole of
-- bank_transaction_payment_key per new line once bank_transaction counted zero rows over its pages (9.9 ms a line,
-- about 8 min for 50k). One row per line found on each other account, as the join it replaces.
create or replace function private.bank_import_lines_elsewhere(p_organization_id uuid, p_bank_account_id uuid)
returns table (line_no integer, dedup_key text)
language plpgsql
stable
set search_path = ''
set enable_nestloop = off
set enable_mergejoin = off
as $$
#variable_conflict use_column
declare
  v_others uuid[];
begin
  select coalesce(array_agg(o.id), '{}') into v_others
  from public.bank_account o
  where o.organization_id = p_organization_id and o.id <> p_bank_account_id;
  if cardinality(v_others) = 0 then
    return;
  end if;
  return query
  select x.line_no, x.dedup_key
  from pg_temp._bi_new x
  join public.bank_transaction t on t.dedup_key = x.dedup_key
  where t.bank_account_id = any (v_others)
    and (t.direction, t.amount_minor, t.booking_date) = (x.direction, x.amount_minor, x.booking_date);
end;
$$;

------------------------------------------------------------------------------------------
-- A payment's 4710 postings: from its entries (ledger_entry_payment_idx), their postings by entry (ledger_posting_pkey),
-- the book of each posting's account by its key. Never from the pooled 4710 accounts, whose postings are every payment's.
------------------------------------------------------------------------------------------

-- Position of payments from their tagged entries (I5: amount = allocated + unallocated + returned): allocated =
-- allocation and forward entries (net of reversals), returned = cash_out entries (M2b-6). Same results as 20261109190000;
-- the order is structural now: payment (by key) → its entries → each entry's postings (lateral, OFFSET 0) → the book of
-- the posting's account (scalar lookup by key); index lookups only (enable_seqscan off). CI: 439 s for a 10k-payment
-- chunk when the planner, with ledger_entry not analysed yet, started from the pooled 4710 accounts.
create or replace function private.payment_positions(p_payment_ids uuid[])
returns table (payment_id uuid, amount_minor bigint, allocated_minor bigint, returned_minor bigint,
               unallocated_minor bigint)
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select p.id, p.amount_minor, coalesce(s.a, 0)::bigint, coalesce(s.r, 0)::bigint,
         (p.amount_minor - coalesce(s.a, 0) - coalesce(s.r, 0))::bigint
  from (select distinct x from unnest(p_payment_ids) x) ids
  cross join lateral (select q.id, q.amount_minor from public.payment q where q.id = ids.x offset 0) p
  left join lateral (
    select sum(m.amount_minor) filter (where m.k in ('allocation', 'forward')) as a,
           sum(m.amount_minor) filter (where m.k = 'cash_out') as r
    from public.ledger_entry e
    cross join lateral (
      select lp.amount_minor,
             coalesce((select t.entry_type from public.ledger_entry t where t.id = e.reverses_entry_id), e.entry_type) as k
      from public.ledger_posting lp
      where lp.entry_id = e.id
        and (select la.book from public.ledger_account la where la.id = lp.ledger_account_id) = 'unallocated_payment'
      offset 0) m
    where e.payment_id = p.id) s on true;
$$;

-- Take a payment off its file (nothing allocated yet): redefined from 20261109150000 for its 4710 sum only (the same
-- trap as payment_positions: the payment's entries first, never the pool's postings). The rest is unchanged.
create or replace function public.unassign_payment(p_idempotency_key text, p_payment_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  p public.payment;
  a public.account;
  last public.payment_match;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_iban text;
  v_moved bigint;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'reason', v_reason);
  v_result := private.command_replay('unassign_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p.account_id is null then
    raise exception 'the payment is not matched' using errcode = 'check_violation';
  end if;
  -- Nothing allocated, forwarded or returned: the payment's entries net to zero on 4710 (and its status says so).
  -- The payment's entries, then their postings by entry, the book by the posting's account key.
  select coalesce(sum(m.amount_minor), 0) into v_moved
  from public.ledger_entry e
  cross join lateral (
    select lp.amount_minor from public.ledger_posting lp
    where lp.entry_id = e.id
      and (select la.book from public.ledger_account la where la.id = lp.ledger_account_id) = 'unallocated_payment'
    offset 0) m
  where e.payment_id = p.id;
  if p.status <> 'matched' or v_moved <> 0 then
    raise exception 'money of this payment is allocated: reverse the allocation first' using errcode = 'check_violation';
  end if;
  select * into a from public.account where id = p.account_id;
  select * into last from public.payment_match m
  where m.payment_id = p.id and m.action = 'assign' and m.account_id = p.account_id
  order by m.decided_at desc, m.id desc limit 1;

  update public.payment
  set account_id = null, status = 'unmatched', match_method = null, matched_at = null, designation = null,
      review_reason = 'no_match', candidate_account_id = null
  where id = p.id;
  insert into public.payment_match (organization_id, payment_id, action, account_id, client_organization_id,
                                    portfolio_id, method, rule, rule_version, trigger, evidence, reason, decided_by)
  values (p.organization_id, p.id, 'unassign', a.id, a.client_organization_id, a.portfolio_id, 'manual', null, 'ops',
          'ops', jsonb_build_object('undoes', last.id), v_reason, auth.uid());
  if coalesce(last.iban_link, false) then
    v_iban := private.rf_normalise(p.payer_iban);
    update private.payer_account_link
    set confirmed_count = greatest(confirmed_count - 1, 0), updated_at = now()
    where organization_id = p.organization_id and payer_iban = v_iban and account_id = a.id;
  end if;
  delete from public.payment_match_candidate where payment_id = p.id;
  perform private.regate_account(a.id);  -- the file's other payments may find something left to pay
  -- fresh suggestions for ops (never this file again)
  perform pgmq.send('payments', jsonb_build_object('type', 'match', 'organization_id', p.organization_id,
                                                   'trigger', 'ops', 'payment_ids', jsonb_build_array(p.id)));
  v_result := jsonb_build_object('payment_id', p.id, 'unassigned_from', a.id);
  perform private.command_record('unassign_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The receipt payload (redefined from 20261110090000): the same payload, byte for byte (the receipt hashes do not
-- change). Every table is reached from the payment by its key: the file, the organizations and the currency, the
-- file's parties, the payment's entries and their postings (as payment_positions), and for each allocation line its
-- item, the item's file and the component. The 4710 totals had payment_positions' shape (the pool's postings read for
-- each receipt when ledger_entry is not analysed: 3000 payloads in 67 s against 0.84 s); the allocation lines read
-- 1100 postings the same way. The plain joins left on claim_item, account and party read the whole of one of their
-- indexes for each receipt once those tables counted zero rows over their pages (Index Scan using
-- claim_item_account_key without an index condition, 105k rows: 209 ms a receipt, growing with the tables, against
-- 0.5 ms with keyed laterals).
------------------------------------------------------------------------------------------

create or replace function private.receipt_payload(p_payment_id uuid)
returns table (recipient_party_id uuid, payload jsonb)
language sql
stable
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
  select d.party_id,
         jsonb_build_object(
           'schema', 1,
           'state', 'issued',
           'issuer', jsonb_build_object('name', s.legal_name),
           'creditor', jsonb_build_object('name', c.legal_name),
           'file', jsonb_build_object('reference', a.external_ref),
           'debtor', jsonb_build_object('name', d.name),
           -- founder #15: named only if the payer is certainly a party to the file, by the party's own name
           'payer', jsonb_build_object('name', pp.name, 'third_party', pp.name is null),
           'payment', jsonb_build_object('amount_minor', p.amount_minor::text, 'currency', p.currency,
                                         'exponent', cur.minor_exponent, 'method', p.method,
                                         'booking_date', p.booking_date, 'value_date', p.value_date,
                                         'reference', p.end_to_end_id),
           'allocation', coalesce(l.lines, '[]'),
           'totals', jsonb_build_object(
             'allocated_minor', t.allocated::text,
             'forwarded_minor', t.forwarded::text,
             'returned_minor', t.returned::text,
             'unallocated_minor', (p.amount_minor - t.allocated - t.forwarded - t.returned)::text),
           'first_letter', null)
  from public.payment p
  cross join lateral (select q.id, q.external_ref, q.client_organization_id from public.account q
                      where q.id = p.account_id offset 0) a
  cross join lateral (select q.legal_name from public.organization q where q.id = p.organization_id offset 0) s
  cross join lateral (select q.legal_name from public.organization q where q.id = a.client_organization_id offset 0) c
  cross join lateral (select q.minor_exponent from public.currency q where q.code = p.currency offset 0) cur
  cross join lateral (
    select (array_agg(ap.party_id order by pa.display_name, pa.id))[1] as party_id,
           (array_agg(pa.display_name order by pa.display_name, pa.id))[1] as name
    from public.account_party ap
    cross join lateral (select q.id, q.display_name from public.party q where q.id = ap.party_id offset 0) pa
    where ap.account_id = a.id and ap.role = 'borrower') d
  cross join lateral (
    select (array_agg(pa.display_name order by pa.display_name, pa.id)
              filter (where private.payer_is_party(p.payer_name, pa.kind, pa.display_name, pa.first_name,
                                                   pa.last_name)))[1] as name
    from public.account_party ap
    cross join lateral (select q.id, q.kind, q.display_name, q.first_name, q.last_name from public.party q
                        where q.id = ap.party_id offset 0) pa
    where ap.account_id = a.id and p.payer_name is not null) pp
  -- what the payment's entries moved out of 4710 (net of reversals): allocated, forwarded, returned (M2b-6); the
  -- payment's entries, their postings by entry, the book by the posting's account key
  cross join lateral (
    select coalesce(sum(m.amount_minor) filter (where m.k = 'allocation'), 0)::bigint as allocated,
           coalesce(sum(m.amount_minor) filter (where m.k = 'forward'), 0)::bigint as forwarded,
           coalesce(sum(m.amount_minor) filter (where m.k = 'cash_out'), 0)::bigint as returned
    from public.ledger_entry e
    cross join lateral (
      select lp.amount_minor,
             coalesce((select r.entry_type from public.ledger_entry r where r.id = e.reverses_entry_id), e.entry_type) as k
      from public.ledger_posting lp
      where lp.entry_id = e.id
        and (select la.book from public.ledger_account la where la.id = lp.ledger_account_id) = 'unallocated_payment'
      offset 0) m
    where e.payment_id = p.id) t
  -- the allocation per item and component, from the postings of the live allocation entries (net of reversals); the
  -- payment's own file first, in a total order (review #3: tied lines would change the hash with the plan). The
  -- component is a code: the locked template words it for the debtor (review #2), never the ledger's staff label.
  -- The payment's allocation entries (and reversals of them), their postings by entry, each posting's 1100 account by
  -- its key; then each line's item, the item's file and the component, by key.
  left join lateral (
    select jsonb_agg(jsonb_build_object('file_reference', fa.external_ref, 'item_ref', i.ref, 'item_kind', i.kind,
                                        'due_date', i.due_date, 'component', x.component,
                                        'amount_minor', x.amount::text)
                     order by (fa.id <> a.id), fa.external_ref, fa.id, i.due_date nulls last, i.ref, i.kind, i.id,
                              lc.sort_order) as lines
    from (select m.claim_item_id, m.component, -sum(m.amount_minor) as amount
          from public.ledger_entry e
          cross join lateral (
            select lp.amount_minor, la.claim_item_id, la.component
            from public.ledger_posting lp
            cross join lateral (select q.claim_item_id, q.component from public.ledger_account q
                                where q.id = lp.ledger_account_id and q.book = 'debtor_receivable'
                                offset 0) la
            where lp.entry_id = e.id
            offset 0) m
          where e.payment_id = p.id
            and coalesce((select r.entry_type from public.ledger_entry r where r.id = e.reverses_entry_id),
                         e.entry_type) = 'allocation'
          group by m.claim_item_id, m.component
          having sum(m.amount_minor) <> 0) x
    cross join lateral (select q.id, q.ref, q.kind, q.due_date, q.account_id from public.claim_item q
                        where q.id = x.claim_item_id offset 0) i
    cross join lateral (select q.id, q.external_ref from public.account q where q.id = i.account_id offset 0) fa
    cross join lateral (select q.sort_order from public.ledger_component q where q.code = x.component offset 0) lc
    ) l on true
  where p.id = p_payment_id;
$$;

------------------------------------------------------------------------------------------
-- The payment page (redefined from 20261110120000, M2b-6, as merged): the same page. Its 4710 sums had
-- payment_positions' old shape, with no order forced: the forwarded amount (ledger_entry, its reversed entry,
-- ledger_posting, ledger_account where book = 'unallocated_payment') could start from the pooled 4710 accounts, whose
-- postings are every payment's, and so could each entry's 4710 amount; each entry's allocation lines (ledger_posting,
-- ledger_account where book = 'debtor_receivable', claim_item) from the receivable accounts or a whole claim_item index.
-- They drive from the payment's entries now: each entry's postings by entry, the book by the posting's account key (a
-- scalar lookup, or a keyed lateral where the account's columns are read). The rows the page names (parties, files,
-- organizations, bank lines) are reached by key from the row that names them, and the payer's other files from the
-- file's parties (they were found by testing every account against them). The lists ordered by a date then the id
-- (entries, matches, notifications, refunds, documents) read their rows in a subquery holding the key alone (OFFSET
-- 0): with the order passed down, a table counting zero rows over its pages was read whole through its primary key
-- (sorted by id, the list's last key) instead of probed by the payment (ledger_entry_pkey, 212k rows removed by the
-- filter for a payment's entries: 157 ms a page). Every table it reads at zero rows over its pages (perf stack,
-- 117k payments on files, 1.27M postings): one page did not finish in 300 s before (cancelled), 188 ms with the keyed
-- lookups alone, 3.7 ms now (2000 pages in 7.3 s). Same page; SET clauses (search_path only), security definer,
-- volatility and grants as before.
------------------------------------------------------------------------------------------

create or replace function public.payment_detail(p_payment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p public.payment;
  v jsonb;
begin
  select * into p from public.payment where id = p_payment_id and organization_id = any (private.money_staff_org_ids());
  if not found then
    return null;
  end if;
  select jsonb_build_object(
    'payment', jsonb_build_object(
      'id', p.id, 'amount_minor', p.amount_minor::text, 'currency', p.currency, 'booking_date', p.booking_date,
      'value_date', p.value_date, 'payer_name', p.payer_name, 'payer_iban_end', right(p.payer_iban, 4),
      'payer_iban_valid', coalesce(private.iban_valid(private.rf_normalise(p.payer_iban)), false),
      'remittance_text', p.remittance_text, 'creditor_reference', p.creditor_reference, 'end_to_end_id', p.end_to_end_id,
      'status', p.status, 'review_reason', p.review_reason, 'account_id', p.account_id, 'match_method', p.match_method,
      'matched_at', p.matched_at, 'designation', p.designation, 'instruction', p.allocation_instruction,
      'channel', p.channel, 'method', p.method),
    'position', (select jsonb_build_object('allocated_minor', x.allocated_minor::text,
                                           'unallocated_minor', x.unallocated_minor::text,
                                           'returned_minor', x.returned_minor::text,
                                           'left_minor', (x.amount_minor - x.returned_minor)::text,
                                           -- the payment's forward entries (net of reversals), their 4710 postings
                                           'forwarded_minor', (select coalesce(sum(m.amount_minor), 0)
                                                               from public.ledger_entry e
                                                               cross join lateral (
                                                                 select lp.amount_minor from public.ledger_posting lp
                                                                 where lp.entry_id = e.id
                                                                   and (select la.book from public.ledger_account la
                                                                        where la.id = lp.ledger_account_id)
                                                                       = 'unallocated_payment'
                                                                 offset 0) m
                                                               where e.payment_id = p.id
                                                                 and coalesce((select t.entry_type
                                                                               from public.ledger_entry t
                                                                               where t.id = e.reverses_entry_id),
                                                                              e.entry_type) = 'forward')::text)
                 from private.payment_positions(array[p.id]) x),
    'file', (select jsonb_build_object('account_id', a.id, 'external_ref', a.external_ref, 'status', a.status,
                                       'client_organization_id', a.client_organization_id, 'client_name', c.legal_name,
                                       'currency', a.currency, 'legal_regime', a.legal_regime,
                                       'debtor_name', (select min(pa.display_name) from public.account_party ap
                                                       cross join lateral (select q.display_name from public.party q
                                                                           where q.id = ap.party_id offset 0) pa
                                                       where ap.account_id = a.id and ap.role = 'borrower'),
                                       'holds', coalesce((select jsonb_agg(h.kind order by h.kind)
                                                          from public.account_hold h
                                                          where h.account_id = a.id and h.ended_at is null
                                                            and h.kind in ('surendettement', 'collective_proceeding')),
                                                         '[]'))
             from public.account a
             cross join lateral (select q.legal_name from public.organization q
                                 where q.id = a.client_organization_id offset 0) c
             where a.id = p.account_id),
    'matches', coalesce((select jsonb_agg(jsonb_build_object('action', m.action, 'account_id', m.account_id,
                                                             'external_ref', a.external_ref, 'method', m.method,
                                                             'rule', m.rule, 'trigger', m.trigger, 'reason', m.reason,
                                                             'review_reason', m.review_reason, 'decided_at', m.decided_at,
                                                             'by_ops', m.decided_by is not null)
                                          order by m.decided_at, m.id)
                         from (select q.* from public.payment_match q where q.payment_id = p.id offset 0) m
                         cross join lateral (select q.external_ref from public.account q
                                             where q.id = m.account_id offset 0) a), '[]'),
    'entries', coalesce((select jsonb_agg(jsonb_build_object(
                           'entry_id', e.id, 'entry_type', e.entry_type, 'effective_date', e.effective_date,
                           'posted_at', e.posted_at, 'reason', e.reason, 'account_id', e.account_id,
                           'ops_note', (select o.note from private.payment_ops_note o where o.entry_id = e.id),
                           'external_ref', (select a.external_ref from public.account a where a.id = e.account_id),
                           'reverses_entry_id', e.reverses_entry_id,
                           'reverses_type', (select t.entry_type from public.ledger_entry t where t.id = e.reverses_entry_id),
                           'reversed_by', (select r.id from public.ledger_entry r where r.reverses_entry_id = e.id),
                           -- the entry's postings by entry, the book by the posting's account key
                           'amount_minor', (select sum(lp.amount_minor) from public.ledger_posting lp
                                            where lp.entry_id = e.id
                                              and (select la.book from public.ledger_account la
                                                   where la.id = lp.ledger_account_id) = 'unallocated_payment')::text,
                           'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                                              'claim_item_id', la.claim_item_id, 'item_ref', i.ref, 'item_kind', i.kind,
                                              'due_date', i.due_date, 'component', la.component,
                                              'amount_minor', (-lp.amount_minor)::text)
                                            order by lp.line_no), '[]')
                                     from public.ledger_posting lp
                                     cross join lateral (select q.claim_item_id, q.component from public.ledger_account q
                                                         where q.id = lp.ledger_account_id
                                                           and q.book = 'debtor_receivable' offset 0) la
                                     cross join lateral (select q.ref, q.kind, q.due_date from public.claim_item q
                                                         where q.id = la.claim_item_id offset 0) i
                                     where lp.entry_id = e.id))
                         order by e.posted_at, e.id)
                         from (select q.* from public.ledger_entry q where q.payment_id = p.id offset 0) e), '[]'),
    'notifications', coalesce((select jsonb_agg(jsonb_build_object('kind', n.kind, 'created_at', n.created_at,
                                                                   'client_name', c.legal_name, 'reason', n.reason,
                                                                   'ledger_entry_id', n.ledger_entry_id,
                                                                   'delivered_at', n.delivered_at)
                                                order by n.created_at, n.id)
                               from (select q.* from public.client_notification q where q.payment_id = p.id
                                     offset 0) n
                               cross join lateral (select q.legal_name from public.organization q
                                                   where q.id = n.client_organization_id offset 0) c), '[]'),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object(
                           'id', q.id, 'amount_minor', q.amount_minor::text, 'payee_name', q.payee_name,
                           'payee_iban_end', right(q.payee_iban, 4), 'payee_is_payer', q.payee_is_payer,
                           'end_to_end_id', q.end_to_end_id, 'reason_code', q.reason_code, 'reason', q.reason,
                           'status', q.status, 'requested_at', q.requested_at, 'executed_on', q.executed_on,
                           'cancelled_at', q.cancelled_at, 'cancel_reason', q.cancel_reason)
                         order by q.requested_at, q.id)
                         from (select r.* from public.refund_request r where r.payment_id = p.id offset 0) q), '[]'),
    'bank_lines', coalesce((select jsonb_agg(jsonb_build_object(
                              'bank_transaction_id', l.bank_transaction_id, 'kind', l.kind, 'method', l.method,
                              'booking_date', t.booking_date, 'amount_minor', t.amount_minor::text,
                              'direction', t.direction, 'return_reason', t.return_reason,
                              'statement_id', t.statement_id, 'decided_at', l.decided_at, 'reason', l.reason)
                            order by t.booking_date, l.decided_at)
                            from public.bank_debit_link l
                            cross join lateral (select q.booking_date, q.amount_minor, q.direction, q.return_reason,
                                                       q.statement_id
                                                from public.bank_transaction q
                                                where q.id = l.bank_transaction_id offset 0) t
                            where l.payment_id = p.id), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'created_at', d.created_at)
                                            order by d.created_at desc, d.id)
                           from (select q.* from public.document q
                                 where p.account_id is not null and q.account_id = p.account_id offset 0) d), '[]'),
    -- the files of the file's borrowers and co-borrowers (each once), then each file by its key
    'other_files', coalesce((select jsonb_agg(jsonb_build_object('account_id', o.id, 'external_ref', o.external_ref)
                                              order by o.external_ref)
                             from (select distinct y.account_id
                                   from public.account_party x
                                   cross join lateral (select q.account_id from public.account_party q
                                                       where q.party_id = x.party_id
                                                         and q.role in ('borrower', 'co_borrower') offset 0) y
                                   where p.account_id is not null and x.account_id = p.account_id
                                     and x.role in ('borrower', 'co_borrower')) k
                             cross join lateral (select q.id, q.external_ref from public.account q
                                                 where q.id = k.account_id and q.id <> p.account_id
                                                   and q.status not in ('staged', 'closed_paid', 'closed_settled',
                                                                        'closed_uncollectable', 'closed_recalled')
                                                   and q.currency = p.currency
                                                 offset 0) o), '[]')
  ) into v;
  return v;
end;
$$;

------------------------------------------------------------------------------------------
-- The debit job's candidates (redefined from 20261110120000, M2b-6, as merged): the same rows. Its working tables
-- were already keyed (the review fixes: candidates indexed by line, positions by payment); the lookups that build the
-- candidates were not structural. The refund requests were a plain join: with refund_request's statistics from when
-- it held few rows, or counting zero rows over its pages, the planner put the requests outside and scanned every
-- line of the chunk for each (20k refunds × 2000 lines: 40M rows removed by the join filter, 4.5 s), or kept the
-- lines outside over a materialised copy of every request (the same 40M comparisons); and a lateral probe on
-- (end-to-end id, bank account) still picked the bank account's index and read every request of the account per line
-- (4.8 s). The payments named by a return's end-to-end id were read the same way: with payment at zero rows over its
-- pages, a whole scan of payment_org_key per line (2000 returns: cancelled after 120 s). Each lookup is now a keyed
-- lateral holding the key alone (OFFSET 0: the other conditions are not pushed into it, so no index but the key's can
-- serve it), the other conditions applied to the rows it returns: the refund request by its RFD id (unique), the
-- payment by its end-to-end id, the payment of a line by its bank line (unique): 3.5 ms for the 2000 refunds above.
-- Left as it was: the line a return names by its bank transaction id is found on (bank account, tx id), and at zero
-- rows over bank_transaction's pages every index led by (or holding) the bank account costs the same, so the planner
-- may read the account's lines for each such return (394 of the 2000 returns on a 63.5k-line account: 14 s for the
-- chunk); bounded by one chunk, and only until bank_transaction is analysed. SET clauses, security definer and grants
-- as before.
------------------------------------------------------------------------------------------

create or replace function private.debit_candidates(p_organization_id uuid, p_after_date date, p_after_id uuid,
                                                    p_limit integer)
returns table (line_id uuid, line_kind text, direction text, bank_account_id uuid, amount_minor bigint,
               booking_date date, payment_id uuid, refund_request_id uuid, via text, cand_bank_account_id uuid,
               cand_amount_minor bigint, cand_left_minor bigint, cand_unallocated_minor bigint,
               cand_pending_minor bigint, cand_status text, cand_date date, cand_payment_status text,
               cand_free_from date)
language plpgsql
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
#variable_conflict use_column
begin
  drop table if exists pg_temp._dc_line;
  create temp table _dc_line on commit drop as
  select x.* from (
    select t.id, coalesce(r.released_kind, t.kind) as kind, t.direction, t.bank_account_id, t.amount_minor,
           t.booking_date, t.end_to_end_id, t.original_end_to_end_id, t.tx_id
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = p_organization_id
      and t.kind in ('return', 'refund_out', 'suspected_duplicate')
      and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
      and (t.kind <> 'suspected_duplicate' or r.decision = 'released')
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
    order by t.booking_date, t.id) x
  where (x.direction = 'debit' and x.kind in ('return', 'refund_out')) or (x.direction = 'credit' and x.kind = 'return')
  order by x.booking_date, x.id
  limit greatest(coalesce(p_limit, 10000), 1);
  analyze pg_temp._dc_line;

  drop table if exists pg_temp._dc_cand;
  create temp table _dc_cand on commit drop as
  -- a return of a credit: the payment that carries its end-to-end id, or whose line carries its bank transaction id
  select x.id as line_id, c.payment_id, null::uuid as refund_request_id, c.via
  from pg_temp._dc_line x
  cross join lateral (
    select p.id as payment_id, 'end_to_end_id'::text as via
    from (select q.id, q.bank_account_id from public.payment q
          where q.end_to_end_id = coalesce(x.original_end_to_end_id, x.end_to_end_id) offset 0) p
    where p.bank_account_id = x.bank_account_id
    union
    select p.id, 'tx_id'
    from public.bank_transaction o
    cross join lateral (select q.id from public.payment q where q.bank_transaction_id = o.id offset 0) p
    where x.tx_id is not null and o.bank_account_id = x.bank_account_id and o.tx_id = x.tx_id and o.direction = 'credit'
  ) c
  where x.direction = 'debit' and x.kind = 'return'
  union all
  -- our refund: the request whose RFD id the debit carries; a refund that came back: the one the credit names
  select x.id, q.payment_id, q.id, 'end_to_end_id'
  from pg_temp._dc_line x
  cross join lateral (select r.id, r.payment_id, r.organization_id, r.bank_account_id from public.refund_request r
                      where r.end_to_end_id = case when x.direction = 'debit' then x.end_to_end_id
                                                   else coalesce(x.original_end_to_end_id, x.end_to_end_id) end
                      offset 0) q
  where (x.kind = 'refund_out' or (x.direction = 'credit' and x.kind = 'return'))
    and q.organization_id = p_organization_id and q.bank_account_id = x.bank_account_id;   -- never another tenant's
  create index on pg_temp._dc_cand (line_id);
  analyze pg_temp._dc_cand;

  -- Each payment named, once: its position, its pending refunds, its free-from date (keyed lookups per payment).
  drop table if exists pg_temp._dc_pos;
  create temp table _dc_pos on commit drop as
  select x.payment_id, x.amount_minor - x.returned_minor as left_minor, x.unallocated_minor,
         coalesce((select sum(z.amount_minor) from public.refund_request z
                   where z.payment_id = x.payment_id and z.status = 'requested'), 0)::bigint as pending_minor,
         (select max(e.effective_date) from public.ledger_entry e
          join public.ledger_entry v on v.id = e.reverses_entry_id
          where e.payment_id = x.payment_id and e.effective_date > v.effective_date) as free_from
  from private.payment_positions(array(select distinct y.payment_id from pg_temp._dc_cand y
                                       where y.payment_id is not null)) x;
  alter table pg_temp._dc_pos add primary key (payment_id);
  analyze pg_temp._dc_pos;

  return query
  select x.id, x.kind, x.direction, x.bank_account_id, x.amount_minor, x.booking_date, c.payment_id, c.refund_request_id,
         c.via, coalesce(q.bank_account_id, p.bank_account_id), coalesce(q.amount_minor, p.amount_minor),
         pos.left_minor, pos.unallocated_minor, pos.pending_minor,
         coalesce(q.status, p.status), coalesce(q.executed_on, p.booking_date), p.status, pos.free_from
  from pg_temp._dc_line x
  left join pg_temp._dc_cand c on c.line_id = x.id
  left join public.payment p on p.id = c.payment_id
  left join public.refund_request q on q.id = c.refund_request_id
  left join pg_temp._dc_pos pos on pos.payment_id = c.payment_id
  order by x.booking_date, x.id, c.payment_id;
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges: as before (CREATE OR REPLACE keeps the owner and the grants; restated, unchanged)
------------------------------------------------------------------------------------------

revoke execute on function private.bank_import_entry_known(uuid), private.bank_import_lines_elsewhere(uuid, uuid),
  private.payment_positions(uuid[]), private.receipt_payload(uuid), private.debit_candidates(uuid, date, uuid, integer)
  from public, anon, authenticated, service_role;
grant execute on function private.payment_positions(uuid[]), private.debit_candidates(uuid, date, uuid, integer)
  to service_role;
revoke execute on function public.unassign_payment(text, uuid, text), public.payment_detail(uuid) from public, anon;
grant execute on function public.unassign_payment(text, uuid, text), public.payment_detail(uuid) to authenticated;
