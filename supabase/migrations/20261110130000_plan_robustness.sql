-- Plan robustness: the per-row lookups of the payment functions keep their order whatever the statistics say.
-- Forward-only: nothing of 20261110120000 or earlier is edited; the functions below are redefined with the same
-- signature, the same results, the same SET clauses (one added where said) and the same privileges. Only the plans
-- change.
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
-- by its key.
--
-- Redefined: private.bank_import_entry_known, private.bank_import_lines_elsewhere (20261109120000),
-- public.unassign_payment (20261109150000), private.payment_positions (20261109190000), private.receipt_payload
-- (20261110090000).

------------------------------------------------------------------------------------------
-- Statement import: one keyed probe per new line (pg_temp._bi_new of private.ingest_statement)
------------------------------------------------------------------------------------------

-- The first new line whose bank entry (camt.053 Ntry/AcctSvcrRef) this bank account has already. The new lines are
-- outside by construction (lateral, LIMIT 1): one probe of bank_transaction_entry_idx per new line that has an entry
-- reference, never the account's lines scanned per new line (CI: 133 s for 50k new lines on an account whose 13.5k
-- lines the statistics did not know yet). The account is compared through an init-plan parameter: estimated as an
-- average account, never as « no line », so the probe uses the index on (account, entry reference) and not one that
-- reads every line of the account.
create or replace function private.bank_import_entry_known(p_bank_account_id uuid)
returns integer
language plpgsql
stable
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
set enable_bitmapscan = off
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

-- New lines whose key is on another bank account of the servicer with the same day, amount and direction. The other
-- accounts first (a handful), then one probe of bank_transaction_dedup_uq per new line (lateral, OFFSET 0: one row per
-- line found, as the join it replaces), the new lines outside whatever the statistics of the stored lines.
create or replace function private.bank_import_lines_elsewhere(p_organization_id uuid, p_bank_account_id uuid)
returns table (line_no integer, dedup_key text)
language plpgsql
stable
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
set enable_bitmapscan = off
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
  cross join lateral (select 1 from public.bank_transaction t
                      where t.bank_account_id = any ((select v_others)::uuid[]) and t.dedup_key = x.dedup_key
                        and (t.direction, t.amount_minor, t.booking_date) = (x.direction, x.amount_minor, x.booking_date)
                      offset 0) k;
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
-- change); its two ledger laterals drive from the payment's entries as payment_positions does. The 4710 totals had
-- payment_positions' shape (the pool's postings read for each receipt when ledger_entry is not analysed); the
-- allocation lines read 1100 postings the same way (every receivable posting when ledger_account says few).
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
  join public.account a on a.id = p.account_id
  join public.organization s on s.id = p.organization_id
  join public.organization c on c.id = a.client_organization_id
  join public.currency cur on cur.code = p.currency
  cross join lateral (
    select (array_agg(ap.party_id order by pa.display_name, pa.id))[1] as party_id,
           (array_agg(pa.display_name order by pa.display_name, pa.id))[1] as name
    from public.account_party ap join public.party pa on pa.id = ap.party_id
    where ap.account_id = a.id and ap.role = 'borrower') d
  cross join lateral (
    select (array_agg(pa.display_name order by pa.display_name, pa.id)
              filter (where private.payer_is_party(p.payer_name, pa.kind, pa.display_name, pa.first_name,
                                                   pa.last_name)))[1] as name
    from public.account_party ap
    join public.party pa on pa.id = ap.party_id
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
  -- its key.
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
    join public.claim_item i on i.id = x.claim_item_id
    join public.account fa on fa.id = i.account_id
    join public.ledger_component lc on lc.code = x.component) l on true
  where p.id = p_payment_id;
$$;

------------------------------------------------------------------------------------------
-- Privileges: as before (CREATE OR REPLACE keeps the owner and the grants; restated, unchanged)
------------------------------------------------------------------------------------------

revoke execute on function private.bank_import_entry_known(uuid), private.bank_import_lines_elsewhere(uuid, uuid),
  private.payment_positions(uuid[]), private.receipt_payload(uuid)
  from public, anon, authenticated, service_role;
grant execute on function private.payment_positions(uuid[]) to service_role;
revoke execute on function public.unassign_payment(text, uuid, text) from public, anon;
grant execute on function public.unassign_payment(text, uuid, text) to authenticated;
