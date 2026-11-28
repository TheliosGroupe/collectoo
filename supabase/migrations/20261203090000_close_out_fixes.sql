-- M2c-7f-2 « what the close-out volume run found » (plan docs/design/m2c-7f-plan.md §3, V1; docs/design/m2c-7-plan.md
-- §8.3 row 6; ADR-0014 « M2c-7f-2 »). Forward-only. The cancellation-after-download switch is not written here (it
-- stays off).
--
-- « Règlement du client » (public.record_client_payment, and every read of private.client_payment_docs: the preview,
-- « Ce que le client doit au cabinet », the credit line of the dedicated account) read, for each of the client's open
-- documents, its « before the opening » and « payable » through private.document_before_opening and
-- private.document_client_payable: the client's opening (private.client_opening_date, twice) and whether its
-- proceeding stands (private.client_proceeding_stands) once per document, though both are the client's, the same for
-- every document; and private.client_open_advances' lateral, flattened, computed each advance's open part in its
-- select list and again in its filter. At volume — a client with 1,000 open advances (the covers of 1,000 returns of
-- remitted collections) — a call took up to 529 ms (median 185 ms), against the 200 ms of §8.3 row 6
-- (worker/tests/test_close_out_scale_integration.py; docs/benchmarks/remittances.md « M2c-7f-2, part 2 »).
--
-- Here, each redefined whole from its latest definition (the change only; settings, SECURITY DEFINER, search_path ''
-- and grants restated):
--   private.client_payment_docs (20261127090000_set_off_bars.sql line 347): the client's opening and proceeding read
--     once per call, in a fenced subquery; each document's « before the opening » is the same comparison
--     private.document_before_opening makes (its birth, private.document_born_on, before the opening; never when the
--     client has none), its « payable » private.document_client_payable's (not before the opening; and an advance,
--     not while a proceeding stands). The documents, their order and every field are unchanged
--     (worker/tests/test_close_out_fixes_reads_integration.py compares the earlier body and this one side by side);
--   private.client_open_advances (20261123090000_advance_recovery.sql line 177): its lateral fenced (offset 0), each
--     advance's open part computed once.
-- The two helpers stay for their other callers.
--
-- The 5,000-payout funds pass (§8.3 row 8, ≤ 24 s × 1.1) took 28.2 s, 14 s of it private.ledger_post_set's
-- pooled-dimension lookup (ADR-0014 « M2c-7a », Left open; plan m2c-7f V3): each pooled ledger account was found by
-- the first three columns of ledger_account_pooled_uq (servicer, book, currency) — « is not distinct from » is no
-- index condition — so each client's dimension read every account of the servicer's book, one per client (a lot of
-- n clients read n × the servicer's clients rows). Redefined from its latest body (20261124090000_client_payments.sql
-- line 113): each dimension by its own key — its eight columns as one text (private.ledger_pooled_key, nulls spelt
-- apart) compared with the expression of a unique index of its own, ledger_account_pooled_key_uq (every account but
-- the receivables), and nothing else of the account, so no other index has a condition to work with whatever the
-- statistics (review round 1, VC-1: the first version, a client's dimension by ledger_account_client_idx, read every
-- account of the servicer's book again with the table analysed while nearly empty, its predicate and « book = »
-- pricing ledger_account_portfolio_idx and ledger_account_org_book_idx alike) —, and each receivable line's account by
-- ledger_account_receivable_uq (joined, stale statistics hashed the whole table at each call); the same accounts
-- found. 7a's per-row run check took 0.37 s of the pass (5,000 checks): V2's statement-level trigger is not built.
-- One function and one index added (no table, no grant change). Review round 1 also redefines
-- private.ledger_entry_verify (each line's account by its primary key alone) and adds the prepare's two keyed reads of
-- the earlier charges (private.remittance_earlier_charges, private.remittance_charge_totals).

------------------------------------------------------------------------------------------
-- A client's open documents: the client's facts once per call
------------------------------------------------------------------------------------------

-- private.client_payment_docs, redefined from 20261127090000_set_off_bars.sql (line 347; same signature and settings,
-- its grants restated below). M2c-7f-2: the client's opening (private.client_opening_date) and whether its proceeding
-- stands (private.client_proceeding_stands) read once, in a fenced subquery, instead of once and twice per document
-- through private.document_client_payable and private.document_before_opening; each document's two answers are those
-- helpers' own comparisons. Nothing else changes.
create or replace function private.client_payment_docs(p_client_organization_id uuid, p_currency char(3), p_on date)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(jsonb_agg(x.doc order by x.kind, x.at, x.id), '[]')
  -- (M2c-7f-2) the client's facts, once: fenced, never substituted into each document's expressions
  from (select private.client_opening_date(p_client_organization_id, p_on) as opening,
               private.client_proceeding_stands(p_client_organization_id, p_on) as stands offset 0) c
  cross join lateral (
        select 'invoice' as kind, i.issue_date::timestamptz as at, i.id,
               jsonb_build_object(
                 'kind', 'invoice', 'id', i.id, 'number', i.number, 'issue_date', i.issue_date, 'due_date', i.due_date,
                 'settlement', i.settlement, 'ttc_minor', i.ttc_minor::text, 'open', o.open::text,
                 'pending_vat', private.document_pending_vat(i.id)::text, 'payable', not b.before,
                 'before_opening', b.before, 'year', i.year, 'seq', i.seq, 'since', i.issue_date,
                 'open_on', i.issue_date <= p_on,
                 'in_flight_run', (select jsonb_build_object('run_id', f.run_id, 'number', f.run_number)
                                   from private.document_in_flight_run(i.id, i.client_organization_id, i.currency) f
                                   limit 1)) as doc
        from (select q.id, q.number, q.kind, q.currency, q.issue_date, q.due_date, q.settlement, q.ttc_minor, q.year,
                     q.seq, q.client_organization_id
              from public.commission_invoice q where q.client_organization_id = p_client_organization_id offset 0) i
        cross join lateral (select private.document_open(i.id) as open) o
        -- (M2c-7f-2) private.document_before_opening's comparison, the opening read once above
        cross join lateral (select case when c.opening is null then false
                                        else coalesce(private.document_born_on(i.id) < c.opening, false) end
                                   as before) b
        where i.kind = 'invoice' and i.currency = p_currency and o.open > 0
        union all
        select 'advance', a.created_at, a.advance_id,
               jsonb_build_object(
                 'kind', 'advance', 'id', a.advance_id, 'cause', a.cause, 'born_on', a.born_on,
                 'created_at', a.created_at, 'created_on', (a.created_at at time zone 'Europe/Paris')::date,
                 'amount_minor', (select q.amount_minor from public.client_advance q where q.id = a.advance_id)::text,
                 'open', a.open_minor::text, 'pending_vat', '0', 'mandate_id', a.mandate_id,
                 -- (M2c-7f-2) private.document_client_payable's: not before the opening, nor while a proceeding stands
                 'payable', not b.before and not c.stands, 'before_opening', b.before, 'year', 0, 'seq', 0,
                 'since', a.born_on, 'open_on', coalesce(a.born_on <= p_on, false),
                 'in_flight_run', (select jsonb_build_object('run_id', f.run_id, 'number', f.run_number)
                                   from private.advance_in_flight_run(a.advance_id) f order by f.run_number limit 1))
        from private.client_open_advances(p_client_organization_id, p_currency) a
        cross join lateral (select case when c.opening is null then false
                                        else coalesce(private.document_born_on(a.advance_id) < c.opening, false) end
                                   as before) b) x;
$$;

-- private.client_open_advances, redefined from 20261123090000_advance_recovery.sql (line 177; same signature and
-- settings, its grants restated below). M2c-7f-2: its lateral fenced (offset 0), so each advance's open part
-- (private.advance_open) is computed once, not again for the filter. Nothing else changes.
create or replace function private.client_open_advances(p_client_organization_id uuid, p_currency char(3))
returns table (advance_id uuid, mandate_id uuid, cause text, born_on date, created_at timestamptz, open_minor bigint)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select a.id, a.mandate_id, a.cause, private.advance_born_on(a.id), a.created_at, o.open_minor
  from (select q.id, q.mandate_id, q.cause, q.created_at from public.client_advance q
        where q.client_organization_id = p_client_organization_id and q.currency = p_currency offset 0) a
  cross join lateral (select private.advance_open(a.id) as open_minor offset 0) o
  where o.open_minor > 0;
$$;

------------------------------------------------------------------------------------------
-- The prepare's earlier charges: summed per key, whole only where the run credits a key
------------------------------------------------------------------------------------------

-- (M2c-7f-2 review round 1, VC-3; §8.3 row 5) What each earlier invoice still charges each (file, tier key) of the
-- given files, one row per invoice and key: its charge, what the credit notes took back on it (every allocation, a
-- manual one's included) and what manual credit notes left waived on it. Each file's charges by its own key
-- (commission_invoice_charge_key_idx), each charge's credits and waivers by theirs (commission_credit_alloc_original_idx,
-- commission_waiver_key_idx), fenced: the same rows the prepare's own statement read (jobs/remittances.py, until this
-- round), whose plan scanned commission_invoice whole under stale statistics.
create or replace function private.remittance_earlier_charges(p_account_ids uuid[])
returns table (account_id uuid, tier_key text, invoice_id uuid, charged_minor bigint, credited_minor bigint,
               waived_minor bigint)
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select ch.account_id, ch.tier_key, ch.invoice_id, ch.charged_minor,
         coalesce((select -sum(x.ht_minor) from public.commission_credit_alloc x
                   where x.original_invoice_id = ch.invoice_id and x.account_id = ch.account_id
                     and x.tier_key = ch.tier_key), 0)::bigint,
         coalesce((select sum(w.amount_minor) from public.commission_waiver w
                   where w.invoice_id = ch.invoice_id and w.account_id = ch.account_id
                     and w.tier_key = ch.tier_key), 0)::bigint
  from unnest(p_account_ids) a (id)
  cross join lateral (select q.account_id, q.tier_key, q.invoice_id, q.charged_minor
                      from public.commission_invoice_charge q where q.account_id = a.id offset 0) ch;
$$;

-- The same charges summed per (file, tier key) and VAT rate of their invoice: the invoices whose capacity (open charge
-- plus waiver) is above 0 and that capacity, the open charges' and the waivers' sums, and whether one of them is below
-- 0 (that key is then read whole: the engine refuses it). The engine needs no more of a key the run does not credit
-- (worker remittance/commission.py ChargeTotals): one row per key and rate instead of one per earlier invoice and key
-- (ten 50k-line runs behind a 50k-line run: 550,000 rows, every one built and hashed by the prepare). Every invoice of
-- the files is the client's: the client's invoices by its key (commission_invoice_client_idx), each one's charges of
-- the files by the primary key (the invoice, then the files: its charges in their own pages' order), a charge's
-- credits and waivers by their keys only on an invoice that has some (most have none; each invoice probed once, by
-- its key). Summed by hash (work_mem: the
-- groups of a 50k-file client fit; a sort spilled to disk).
create or replace function private.remittance_charge_totals(p_client_organization_id uuid, p_account_ids uuid[])
returns table (account_id uuid, tier_key text, vat_rate numeric, open_invoices integer, open_capacity_minor bigint,
               open_minor bigint, waived_minor bigint, negative boolean)
language sql
stable
set search_path = ''
set enable_seqscan = off
set work_mem = '64MB'
as $$
  select c.account_id, c.tier_key, c.vat_rate,
         (count(*) filter (where c.open + c.waived > 0))::integer,
         coalesce(sum(c.open + c.waived) filter (where c.open + c.waived > 0), 0)::bigint,
         sum(c.open)::bigint, sum(c.waived)::bigint, bool_or(c.open < 0 or c.waived < 0)
  from (select i.id, i.vat_rate,
               -- (a scalar probe, never an exists: hashed, that read every allocation and waiver of the table)
               (select true from public.commission_credit_alloc x where x.original_invoice_id = i.id limit 1)
                 as credited,
               (select true from public.commission_waiver w where w.invoice_id = i.id limit 1) as waived
        from public.commission_invoice i where i.client_organization_id = p_client_organization_id offset 0) i
  cross join lateral (
        select q.account_id, q.tier_key, i.vat_rate,
               q.charged_minor
                 - case when i.credited
                        then coalesce((select -sum(x.ht_minor) from public.commission_credit_alloc x
                                       where x.original_invoice_id = q.invoice_id and x.account_id = q.account_id
                                         and x.tier_key = q.tier_key), 0)
                        else 0 end as open,
               case when i.waived
                    then coalesce((select sum(w.amount_minor) from public.commission_waiver w
                                   where w.invoice_id = q.invoice_id and w.account_id = q.account_id
                                     and w.tier_key = q.tier_key), 0)
                    else 0 end as waived
        from public.commission_invoice_charge q
        where q.invoice_id = i.id and q.account_id = any(p_account_ids) offset 0) c
  group by 1, 2, 3;
$$;

------------------------------------------------------------------------------------------
-- The posting core: a client's pooled ledger account found by its own key
------------------------------------------------------------------------------------------

-- private.ledger_entry_verify, redefined from 20261124090000_client_payments.sql (line 442; same signature and
-- settings; a trigger's function, no grant). M2c-7f-2 review round 1: the receivable / owner-claim mirror reads each
-- line's ledger account by its primary key alone (its book compared on the row read): with the book a condition of the
-- subquery too, ledger_account analysed while (nearly) empty priced ledger_account_org_book_idx alike, and each line
-- of each entry read every receivable and owner-claim account of every servicer (36,804 rows for a lot of 100 entries
-- after the db job's first integration files; test_close_out_fixes_reads_integration's « analysed while empty »).
-- The same components found. Nothing else changes.
create or replace function private.ledger_entry_verify()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_lines bigint;
  v_cur text;
  v_bad text;
  v_pay public.payment;
  v_ok boolean;
  v_shape record;
  f record;
begin
  select coalesce(sum(n), 0), min(currency) filter (where s <> 0) into v_lines, v_cur
  from (select currency, count(*) n, sum(amount_minor) s from public.ledger_posting
        where entry_id = new.id group by currency) x;
  if v_lines <> new.line_count then
    raise exception 'ledger: entry % has % of its % lines', new.id, v_lines, new.line_count using errcode = 'LG001';
  end if;
  if v_cur is not null then
    raise exception 'ledger: entry % is not balanced in %', new.id, v_cur using errcode = 'LG001';
  end if;
  -- Receivable and owner claim move by opposite amounts per (component, currency).
  -- One key lookup per line (a hash join would scan every ledger account for every entry).
  select min(y.k) into v_bad from (
    select x.component || ' ' || x.currency as k
    from (select p.currency, p.amount_minor,
                 -- (M2c-7f-2 review round 1) the account by its primary key alone, its book read from the row:
                 -- with « book in (…) » a condition too, an analyse of a near-empty table priced
                 -- ledger_account_org_book_idx alike and read every receivable account of the table per line
                 (select case when la.book in ('debtor_receivable', 'owner_claim') then la.component end
                  from public.ledger_account la where la.id = p.ledger_account_id) as component
          from public.ledger_posting p where p.entry_id = new.id) x
    where x.component is not null
    group by x.component, x.currency having sum(x.amount_minor) <> 0) y;
  if v_bad is not null then
    raise exception 'ledger: entry % breaks the receivable/owner-claim mirror (%)', new.id, v_bad using errcode = 'LG001';
  end if;
  -- A reversal negates the reversed entry line by line, on the same ledger accounts.
  if new.reverses_entry_id is not null and exists (
    select 1
    from (select line_no, ledger_account_id, amount_minor from public.ledger_posting where entry_id = new.id) r
    full join (select line_no, ledger_account_id, amount_minor from public.ledger_posting
               where entry_id = new.reverses_entry_id) o using (line_no)
    where r.ledger_account_id is distinct from o.ledger_account_id or r.amount_minor is distinct from -o.amount_minor
  ) then
    raise exception 'ledger: reversal % does not mirror entry %', new.id, new.reverses_entry_id using errcode = 'LG003';
  end if;
  if new.entry_type = 'opening' then
    return null;  -- claim books only, on new ledger accounts: nothing below applies
  end if;

  -- I2′: each fund is closed in every entry, per currency — the client fund (5120, 4710, 4670, 4679) and the servicer's
  -- fund (5122, 4111, 4112, 44571, 44574, 4689, 7060, 6270, 6780). I12: Σ4679 + Σ4689 = 0, per currency (the only way
  -- money crosses between the funds). One pass over the entry's postings, each account and book by its key.
  select min(case when y.money_of in ('client', 'servicer') and y.s <> 0 then y.money_of || ' fund in ' || y.currency
                  when y.mm <> 0 then '4679/4689 mirror in ' || y.currency end)
  into v_bad
  from (select g.money_of, g.s, sum(g.m) over (partition by g.currency) as mm, g.currency
        from (select p.currency, a.money_of, sum(p.amount_minor) as s,
                     coalesce(sum(p.amount_minor) filter (where a.book in ('due_to_servicer', 'due_from_client_funds')), 0)
                       as m
              from public.ledger_posting p
              cross join lateral (select la.book,
                                         (select b.money_of from public.ledger_book b where b.code = la.book) as money_of
                                  from public.ledger_account la where la.id = p.ledger_account_id offset 0) a
              where p.entry_id = new.id
              group by p.currency, a.money_of) g) y;
  if v_bad is not null then
    raise exception 'ledger: entry % leaves the % open (closure per fund, mirror 4679/4689)', new.id, v_bad
      using errcode = 'LG001';
  end if;

  -- I3: the shape of each payment entry type (4710 lines are on the pooled account).
  if new.entry_type in ('cash_in', 'allocation', 'forward', 'cash_out', 'netting') then
    select count(*) as n,
           count(*) filter (where x.book = 'client_money_cash' and x.amount_minor > 0) as cash_dr,
           count(*) filter (where x.book = 'client_money_cash' and x.amount_minor < 0) as cash_cr,
           count(*) filter (where x.book = 'unallocated_payment') as pool_n,
           count(*) filter (where x.book = 'unallocated_payment' and x.client_organization_id is null
                            and x.amount_minor > 0) as pool_dr,
           count(*) filter (where x.book = 'unallocated_payment' and x.client_organization_id is null
                            and x.amount_minor < 0) as pool_cr,
           count(*) filter (where x.book = 'client_payable') as pay_n,
           count(*) filter (where x.book = 'client_payable' and x.amount_minor < 0) as pay_cr,
           count(*) filter (where x.book = 'debtor_receivable' and x.amount_minor < 0) as rec_cr,
           count(*) filter (where x.book = 'debtor_receivable' and x.amount_minor > 0) as rec_dr,
           count(*) filter (where x.book = 'owner_claim' and x.amount_minor > 0) as own_dr,
           count(*) filter (where x.component is distinct from 'principal') as not_principal,
           coalesce(sum(x.amount_minor) filter (where x.book = 'unallocated_payment'), 0) as s_pool,
           coalesce(sum(x.amount_minor) filter (where x.book = 'debtor_receivable'), 0) as s_rec
    into v_shape
    from (select p.amount_minor, la.book, la.client_organization_id, la.component
          from public.ledger_posting p
          cross join lateral (select l.book, l.client_organization_id, l.component
                              from public.ledger_account l where l.id = p.ledger_account_id offset 0) la
          where p.entry_id = new.id) x;
    v_ok := case new.entry_type
      when 'cash_in' then v_shape.n = 2 and v_shape.cash_dr = 1 and v_shape.pool_cr = 1
      when 'cash_out' then v_shape.n = 2 and v_shape.pool_dr = 1 and v_shape.cash_cr = 1
      when 'forward' then v_shape.n = 2 and v_shape.pool_dr = 1 and v_shape.pay_cr = 1
      when 'allocation' then v_shape.pool_n = 1 and v_shape.pool_dr = 1 and v_shape.pay_n = 1 and v_shape.pay_cr = 1 and v_shape.rec_cr >= 1
        and v_shape.rec_dr = 0 and v_shape.n = 2 + v_shape.rec_cr + v_shape.own_dr
        -- the debt goes down by exactly the money allocated (no rounding gap, no free extinction)
        and v_shape.s_rec = -v_shape.s_pool
      when 'netting' then v_shape.not_principal = 0
    end;
    if not v_ok then
      raise exception 'ledger: entry % does not have the shape of a % entry', new.id, new.entry_type using errcode = 'LG001';
    end if;
  end if;

  -- I3′: the shapes of the M2c types (§5.2; + debit, − credit), in one currency. n_<book>: lines on the book, d_<book>:
  -- of which debits. With I2′ and I12 they fix every amount (e.g. a sweep's four lines are all S).
  if new.entry_type in ('commission_invoice', 'commission_credit_note', 'client_settlement', 'remittance', 'servicer_sweep',
                        'servicer_top_up', 'bank_fee', 'client_advance', 'servicer_loss', 'client_payment_own',
                        'client_payment_dedicated', 'client_refund_own', 'advance_write_off') then
    select count(*) as n, count(distinct x.currency) as ncur,
           count(*) filter (where x.book = 'client_money_cash') as n_cash,
           count(*) filter (where x.book = 'client_money_cash' and x.amount_minor > 0) as d_cash,
           count(*) filter (where x.book = 'client_payable') as n_pay,
           count(*) filter (where x.book = 'client_payable' and x.amount_minor > 0) as d_pay,
           count(*) filter (where x.book = 'due_to_servicer') as n_dts,
           count(*) filter (where x.book = 'due_to_servicer' and x.amount_minor > 0) as d_dts,
           count(*) filter (where x.book = 'due_from_client_funds') as n_dfc,
           count(*) filter (where x.book = 'due_from_client_funds' and x.amount_minor > 0) as d_dfc,
           count(*) filter (where x.book = 'own_cash') as n_own,
           count(*) filter (where x.book = 'own_cash' and x.amount_minor > 0) as d_own,
           count(*) filter (where x.book = 'commission_receivable') as n_com,
           count(*) filter (where x.book = 'commission_receivable' and x.amount_minor > 0) as d_com,
           count(*) filter (where x.book = 'client_advance_receivable') as n_adv,
           count(*) filter (where x.book = 'client_advance_receivable' and x.amount_minor > 0) as d_adv,
           count(*) filter (where x.book = 'servicer_revenue') as n_rev,
           count(*) filter (where x.book = 'servicer_revenue' and x.amount_minor > 0) as d_rev,
           count(*) filter (where x.book = 'vat_pending') as n_vatp,
           count(*) filter (where x.book = 'vat_pending' and x.amount_minor > 0) as d_vatp,
           count(*) filter (where x.book = 'vat_collected') as n_vatc,
           count(*) filter (where x.book = 'vat_collected' and x.amount_minor > 0) as d_vatc,
           count(*) filter (where x.book = 'bank_fees' and x.amount_minor > 0) as d_fee,
           count(*) filter (where x.book = 'servicer_losses' and x.amount_minor > 0) as d_loss,
           -- (M2c-7c-1) 419, the client's credits owed back, and 7714, the recovery of an advance passed as a loss
           count(*) filter (where x.book = 'client_credit_owed') as n_cco,
           count(*) filter (where x.book = 'client_credit_owed' and x.amount_minor > 0) as d_cco,
           count(*) filter (where x.book = 'written_off_recovered') as n_rec,
           count(*) filter (where x.book = 'written_off_recovered' and x.amount_minor > 0) as d_rec,
           coalesce(sum(x.amount_minor) filter (where x.book in ('vat_pending', 'vat_collected')), 0) as s_vat
    into f
    from (select p.amount_minor, p.currency, la.book
          from public.ledger_posting p
          cross join lateral (select l.book from public.ledger_account l where l.id = p.ledger_account_id offset 0) la
          where p.entry_id = new.id) x;
    v_ok := f.ncur = 1 and case new.entry_type
      -- +4111[c] TTC / −7060[c] HT / −44574 VAT (−44571 when the servicer opted for débits); no VAT line when it is 0
      when 'commission_invoice' then f.n_com = 1 and f.d_com = 1 and f.n_rev = 1 and f.d_rev = 0
        and f.n_vatp + f.n_vatc <= 1 and f.d_vatp = 0 and f.d_vatc = 0 and f.n = 2 + f.n_vatp + f.n_vatc
      -- −4111[c] TTC / +7060[c] HT / +44574 v₁ / +44571 v₂
      when 'commission_credit_note' then f.n_com = 1 and f.d_com = 0 and f.n_rev = 1 and f.d_rev = 1
        and f.n_vatp <= 1 and f.n_vatc <= 1 and f.d_vatp = f.n_vatp and f.d_vatc = f.n_vatc
        and f.n = 2 + f.n_vatp + f.n_vatc
      -- +4670[c] D / −4679 D ‖ +4689 D / −4111[c] Dc / −4112[c] Da; one VAT pair +44574 v / −44571 v; D = Dc + Da
      when 'client_settlement' then f.n_pay = 1 and f.n_dts = 1 and f.n_dfc = 1
        and f.n_com <= 1 and f.n_adv <= 1 and f.n_com + f.n_adv >= 1 and f.d_adv = 0
        and f.n_vatp = f.n_vatc and f.n_vatp <= 1 and f.d_vatp = f.n_vatp and f.d_vatc = 0 and f.s_vat = 0
        and f.n = 3 + f.n_com + f.n_adv + f.n_vatp + f.n_vatc
      -- +4670[c] N / −5120[b] N
      when 'remittance' then f.n = 2 and f.n_pay = 1 and f.d_pay = 1 and f.n_cash = 1 and f.d_cash = 0
      -- +4679 S / −5120[b] S ‖ +5122[own] S / −4689 S
      when 'servicer_sweep' then f.n = 4 and f.n_dts = 1 and f.d_dts = 1 and f.n_cash = 1 and f.d_cash = 0
        and f.n_own = 1 and f.d_own = 1 and f.n_dfc = 1 and f.d_dfc = 0
      -- +5120[b] T / −4679 T ‖ +4689 T / −5122[own] T
      when 'servicer_top_up' then f.n = 4 and f.n_cash = 1 and f.d_cash = 1 and f.n_dts = 1 and f.d_dts = 0
        and f.n_dfc = 1 and f.d_dfc = 1 and f.n_own = 1 and f.d_own = 0
      -- +4679 F / −5120[b] F ‖ +6270 F / −4689 F
      when 'bank_fee' then f.n = 4 and f.n_dts = 1 and f.d_dts = 1 and f.n_cash = 1 and f.d_cash = 0
        and f.d_fee = 1 and f.n_dfc = 1 and f.d_dfc = 0
      -- +4679 A / −4670[c] A ‖ +4112[c] A / −4689 A
      when 'client_advance' then f.n = 4 and f.n_dts = 1 and f.d_dts = 1 and f.n_pay = 1 and f.d_pay = 0
        and f.n_adv = 1 and f.d_adv = 1 and f.n_dfc = 1 and f.d_dfc = 0
      -- +4679 X / −5120[b] X ‖ +6780 X / −4689 X
      when 'servicer_loss' then f.n = 4 and f.n_dts = 1 and f.d_dts = 1 and f.n_cash = 1 and f.d_cash = 0
        and f.d_loss = 1 and f.n_dfc = 1 and f.d_dfc = 0
      -- +5122[own] P / −4111[c] / −4112[c] / (M2c-7c-1) −419[c] surplus / −7714 recovery; VAT pair
      when 'client_payment_own' then f.n_own = 1 and f.d_own = 1
        and f.n_com <= 1 and f.d_com = 0 and f.n_adv <= 1 and f.d_adv = 0
        and f.n_cco <= 1 and f.d_cco = 0 and f.n_rec <= 1 and f.d_rec = 0
        and f.n_com + f.n_adv + f.n_cco + f.n_rec >= 1
        and f.n_vatp = f.n_vatc and f.n_vatp <= 1 and f.d_vatp = f.n_vatp and f.d_vatc = 0 and f.s_vat = 0
        and f.n = 1 + f.n_com + f.n_adv + f.n_cco + f.n_rec + f.n_vatp + f.n_vatc
      -- +5120[b] P / −4679 P ‖ +4689 P / −4111[c] / −4112[c] / (M2c-7c-1) −419[c] / −7714; VAT pair
      when 'client_payment_dedicated' then f.n_cash = 1 and f.d_cash = 1 and f.n_dts = 1 and f.d_dts = 0
        and f.n_dfc = 1 and f.d_dfc = 1
        and f.n_com <= 1 and f.d_com = 0 and f.n_adv <= 1 and f.d_adv = 0
        and f.n_cco <= 1 and f.d_cco = 0 and f.n_rec <= 1 and f.d_rec = 0
        and f.n_com + f.n_adv + f.n_cco + f.n_rec >= 1
        and f.n_vatp = f.n_vatc and f.n_vatp <= 1 and f.d_vatp = f.n_vatp and f.d_vatc = 0 and f.s_vat = 0
        and f.n = 3 + f.n_com + f.n_adv + f.n_cco + f.n_rec + f.n_vatp + f.n_vatc
      -- +4111[c] R (a credit note's refund) or (M2c-7c-1) +419[c] R (a credit owed back) / −5122[own] R
      when 'client_refund_own' then f.n = 2 and f.n_own = 1 and f.d_own = 0
        and ((f.n_com = 1 and f.d_com = 1 and f.n_cco = 0) or (f.n_cco = 1 and f.d_cco = 1 and f.n_com = 0))
      -- +6780 W / −4112[c] W
      when 'advance_write_off' then f.n = 2 and f.d_loss = 1 and f.n_adv = 1 and f.d_adv = 0
    end;
    if not v_ok then
      raise exception 'ledger: entry % does not have the shape of a % entry', new.id, new.entry_type using errcode = 'LG001';
    end if;
  end if;

  -- I4: per payment, at every date, what is left of it is never negative; per (payment, account),
  -- the net amount allocated is never negative. A payment has a handful of entries.
  if new.payment_id is not null then
    select * into v_pay from public.payment where id = new.payment_id;
    select min(p.currency) into v_bad from public.ledger_posting p
    where p.entry_id = new.id and p.currency <> v_pay.currency;
    if v_bad is not null then
      raise exception 'ledger: entry % moves % for a payment in %', new.id, v_bad, v_pay.currency using errcode = 'LG002';
    end if;
    with t as (
      select e.effective_date as d, e.account_id,
             coalesce((select sum(x.amount_minor) from public.ledger_posting x
                       where x.entry_id = e.id
                         and (select la.book from public.ledger_account la where la.id = x.ledger_account_id)
                             = 'unallocated_payment'), 0) as pool
      from public.ledger_entry e where e.payment_id = new.payment_id
    ),
    per_day as (select d, sum(pool) as pool from t group by d),
    per_account as (select d, account_id, sum(pool) as pool from t group by d, account_id),
    left_over as (
      select d, case when d >= v_pay.booking_date then v_pay.amount_minor else 0 end
                - sum(pool) over (order by d) as u
      from per_day),
    net as (select d, sum(pool) over (partition by account_id order by d) as allocated from per_account)
    select min(z.d)::text into v_bad
    from (select d from left_over where u < 0 union all select d from net where allocated < 0) z;
    if v_bad is not null then
      raise exception 'ledger: payment % would be overdrawn on % (entry %)', new.payment_id, v_bad, new.id
        using errcode = 'LG007';
    end if;
  end if;

  -- I6: a receivable credited by an allocation or a netting dated D never goes below zero from D
  -- on; a credit item debited by a netting dated D never goes above zero from D on. Checked for
  -- every entry that moves such a receivable (corrections and reversals included), so it holds
  -- after any sequence of entries.
  if new.entry_type in ('allocation', 'netting', 'adjustment', 'reversal') then
    select min(x.ledger_account_id::text) into v_bad
    from (
      select a.ledger_account_id, a.has_cr, a.has_dr,
             (select min(q.effective_date) from public.ledger_posting q
              where q.ledger_account_id = a.ledger_account_id and q.amount_minor < 0
                and (select e.entry_type from public.ledger_entry e where e.id = q.entry_id)
                    in ('allocation', 'netting')) as d_cr,
             (select min(q.effective_date) from public.ledger_posting q
              where q.ledger_account_id = a.ledger_account_id and q.amount_minor > 0
                and (select e.entry_type from public.ledger_entry e where e.id = q.entry_id) = 'netting') as d_dr
      from (select p.ledger_account_id, bool_or(p.amount_minor < 0) as has_cr, bool_or(p.amount_minor > 0) as has_dr
            from public.ledger_posting p
            where p.entry_id = new.id
              and (select la.book from public.ledger_account la where la.id = p.ledger_account_id) = 'debtor_receivable'
            group by p.ledger_account_id) a
    ) x
    cross join lateral (
      select min(r.bal) filter (where r.d >= x.d_cr) as low, max(r.bal) filter (where r.d >= x.d_dr) as high
      from (select g.d, sum(g.s) over (order by g.d) as bal
            from (select q.effective_date as d, sum(q.amount_minor) as s from public.ledger_posting q
                  where q.ledger_account_id = x.ledger_account_id group by q.effective_date) g) r
    ) w
    where (x.has_cr and x.d_cr is not null and w.low < 0)
       or (x.has_dr and x.d_dr is not null and w.high > 0);
    if v_bad is not null then
      raise exception 'ledger: entry % would overdraw receivable %', new.id, v_bad using errcode = 'LG007';
    end if;
  end if;
  return null;
end;
$$;

-- (M2c-7f-2, review round 1) A pooled ledger account's key: its eight dimension columns as one text, each null spelt
-- apart (« - », a component « = »-prefixed), so that two dimensions have the same key exactly when every column is
-- « not distinct » (one-to-one: a uuid's text never is « - », nor holds « | »; the book and the currency never are
-- null). Immutable: it is the expression of ledger_account_pooled_key_uq.
create or replace function private.ledger_pooled_key(p_organization_id uuid, p_book text, p_currency char(3),
                                                     p_client_organization_id uuid, p_owner_organization_id uuid,
                                                     p_portfolio_id uuid, p_component text, p_bank_account_id uuid)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select p_organization_id::text || '|' || p_book || '|' || p_currency::text
         || '|' || coalesce(p_client_organization_id::text, '-') || '|' || coalesce(p_owner_organization_id::text, '-')
         || '|' || coalesce(p_portfolio_id::text, '-') || '|' || coalesce('=' || p_component, '-')
         || '|' || coalesce(p_bank_account_id::text, '-')
$$;

-- Every ledger account but a receivable (one per claim item and component, ledger_account_receivable_uq) by that key:
-- unique, as ledger_account_pooled_uq makes those accounts (none of them has a claim item: ledger_account_shape).
create unique index ledger_account_pooled_key_uq on public.ledger_account
  (private.ledger_pooled_key(organization_id, book, currency, client_organization_id, owner_organization_id,
                             portfolio_id, component, bank_account_id))
  where book <> 'debtor_receivable';

-- private.ledger_post_set, redefined from 20261124090000_client_payments.sql (line 113; same signature and settings —
-- SECURITY DEFINER, search_path '' —, its grants restated below). M2c-7f-2 (§8.3 row 8; ADR-0014 « M2c-7a », Left
-- open: « make it an index-equality lookup in a later slice, with LG006 checked again »): each pooled dimension found
-- by its own key whatever the statistics (its key, private.ledger_pooled_key, by ledger_account_pooled_key_uq: the
-- one index the lookup gives a condition to; review round 1), no longer by the unique index's first three columns;
-- and each receivable line's account by a probe of ledger_account_receivable_uq instead of a join. The same accounts
-- found (the key one-to-one with ledger_account_pooled_uq's columns, « is not distinct from » each); the LG006 check
-- of a line without its account unchanged. Nothing else changes.
create or replace function private.ledger_post_set()
returns table (entry_no integer, entry_id uuid, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_bad text;
begin
  -- Entries with their derived scope, in our own working table.
  drop table if exists pg_temp._lps_e;
  create temp table _lps_e on commit drop as
  select e.entry_no, e.organization_id, e.entry_type, e.effective_date, e.idempotency_key, e.account_id,
         e.client_organization_id as given_client, coalesce(a.client_organization_id, e.client_organization_id) as client_organization_id,
         e.payment_id, e.source_type, e.source_id, nullif(btrim(e.reason), '') as reason, e.engine_version, e.inputs_hash,
         a.organization_id as account_organization_id, a.status as account_status, a.portfolio_id,
         a.currency as account_currency, own.servicing_start, o.owner_organization_id,
         t.allowed_books, t.requires_reason, p.organization_id as payment_organization_id, p.currency as payment_currency,
         gen_random_uuid() as id
  from pg_temp._lps_entry e
  left join public.account a on a.id = e.account_id
  left join (select o.account_id, min(o.valid_from) as servicing_start from public.claim_ownership_period o
             where o.account_id in (select x.account_id from pg_temp._lps_entry x where x.account_id is not null)
             group by o.account_id) own on own.account_id = e.account_id
  left join public.claim_ownership_period o on o.account_id = e.account_id and o.valid_from <= e.effective_date
    and (o.valid_to is null or o.valid_to > e.effective_date)
  left join public.ledger_entry_type t on t.code = e.entry_type
  left join public.payment p on p.id = e.payment_id;
  analyze pg_temp._lps_e;

  drop table if exists pg_temp._lps_l;
  create temp table _lps_l on commit drop as
  select l.entry_no, l.line_no, l.book, l.amount_minor, l.currency, l.claim_item_id, l.component, l.bank_account_id,
         e.organization_id, e.entry_type,
         -- (M2c-7c-1) 419, the client's credits owed back, is the client's too
         case when l.book in ('debtor_receivable', 'owner_claim', 'client_payable', 'commission_receivable', 'client_advance_receivable', 'servicer_revenue',
                              'client_credit_owed')
              then e.client_organization_id end
           as client_organization_id,
         case when l.book = 'owner_claim' then e.owner_organization_id end as owner_organization_id,
         case when l.book in ('debtor_receivable', 'owner_claim') then e.portfolio_id end as portfolio_id,
         case when l.book = 'debtor_receivable' then e.account_id end as account_id
  from pg_temp._lps_line l join pg_temp._lps_e e on e.entry_no = l.entry_no;
  analyze pg_temp._lps_l;

  -- Request: types, dates, reasons, keys, lines (LG006).
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.entry_type not in ('cash_in', 'allocation', 'forward', 'cash_out', 'netting',
                             'commission_invoice', 'commission_credit_note', 'client_settlement', 'remittance', 'servicer_sweep',
                             'servicer_top_up', 'bank_fee', 'client_advance', 'servicer_loss', 'client_payment_own',
                             'client_payment_dedicated', 'client_refund_own', 'advance_write_off')
     or e.allowed_books is null;
  if v_bad is not null then
    raise exception 'ledger: entry % has a type that cannot be posted here', v_bad using errcode = 'LG006';
  end if;
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.effective_date is null or e.effective_date > private.paris_today()
     or (e.requires_reason and e.reason is null)
     or e.idempotency_key !~ '^[A-Za-z0-9:._#-]{8,200}$'
     or (e.entry_type in ('allocation', 'forward', 'cash_out')) <> (e.payment_id is not null)
     or (e.account_id is not null) <> (e.entry_type in ('allocation', 'netting'))
     -- the client is given for the entries without an account that concern one: a forward, and the M2c entries
     -- with a client line (4670, 4111, 4112, 7060, (M2c-7c-1) 419); never for the others — (M2c-7c-1) but a client's
     -- payment, which names its client whatever it settles (a recovery alone posts 7714, a pooled book)
     or (e.given_client is not null and e.account_id is null
         and e.entry_type not in ('client_payment_own', 'client_payment_dedicated')
         and not exists (select 1 from pg_temp._lps_l l where l.entry_no = e.entry_no
                           and l.book in ('client_payable', 'commission_receivable', 'client_advance_receivable', 'servicer_revenue',
                                          'client_credit_owed')))
     or (e.given_client is not null and e.entry_type in ('allocation', 'netting'));
  if v_bad is not null then
    raise exception 'ledger: entry % needs a past date, its reason, a valid key, and the account or payment its type requires',
      v_bad using errcode = 'LG006';
  end if;
  select min(k) into v_bad from (select e.organization_id::text || ' ' || e.idempotency_key as k from pg_temp._lps_e e
                                 group by e.organization_id, e.idempotency_key having count(*) > 1) d;
  if v_bad is not null then
    raise exception 'ledger: idempotency key % appears twice in one request', v_bad using errcode = 'LG006';
  end if;
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  left join (select l.entry_no, count(*) as n, min(l.line_no) as lo, max(l.line_no) as hi
             from pg_temp._lps_l l group by l.entry_no) c on c.entry_no = e.entry_no
  where c.n is null or c.n < 2 or c.n > 100000 or c.lo <> 1 or c.hi <> c.n;
  if v_bad is not null then
    raise exception 'ledger: entry % needs 2 to 100000 lines numbered from 1', v_bad using errcode = 'LG006';
  end if;
  select min(l.entry_no || ':' || l.line_no) into v_bad from pg_temp._lps_l l
  where l.amount_minor = 0 or abs(l.amount_minor) > 1000000000000000 or l.currency !~ '^[A-Z]{3}$'
     or (l.claim_item_id is not null) <> (l.book = 'debtor_receivable')
     or (l.component is not null) <> (l.book in ('debtor_receivable', 'owner_claim'))
     or (l.bank_account_id is not null) <> (l.book in ('client_money_cash', 'own_cash'));
  if v_bad is not null then
    raise exception 'ledger: line % needs a non-zero amount, a currency, and only the item, component or bank account of its book',
      v_bad using errcode = 'LG006';
  end if;

  -- Books allowed for the type (LG002).
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l join pg_temp._lps_e e on e.entry_no = l.entry_no
  where not (l.book = any (e.allowed_books));
  if v_bad is not null then
    raise exception 'ledger: line % uses a book not allowed for its entry type', v_bad using errcode = 'LG002';
  end if;

  -- Claims: a confirmed account of this servicer, servicing started, an owner on the date.
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.account_id is not null and (e.account_organization_id is distinct from e.organization_id
                                      or (e.given_client is not null and e.given_client <> e.client_organization_id));
  if v_bad is not null then
    raise exception 'ledger: entry % names an account outside this organization', v_bad using errcode = 'LG002';
  end if;
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.account_id is not null and (e.account_status = 'staged' or e.servicing_start is null
                                      or e.effective_date < e.servicing_start or e.owner_organization_id is null);
  if v_bad is not null then
    raise exception 'ledger: entry % is on an account not confirmed yet, before its servicing started, or without an owner',
      v_bad using errcode = 'LG006';
  end if;
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l join pg_temp._lps_e e on e.entry_no = l.entry_no
  left join public.claim_item i on i.id = l.claim_item_id
  where l.book in ('debtor_receivable', 'owner_claim')
    and (l.currency <> e.account_currency
         or (l.book = 'debtor_receivable' and i.account_id is distinct from e.account_id));
  if v_bad is not null then
    raise exception 'ledger: claim line % must name an item of its entry''s account, in the account''s currency', v_bad
      using errcode = 'LG002';
  end if;

  -- Clients, bank accounts and payments belong to the servicer (LG002).
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where (e.client_organization_id is not null and not exists (
           select 1 from public.organization o
           where o.id = e.client_organization_id and o.servicer_organization_id = e.organization_id))
     or (exists (select 1 from pg_temp._lps_l l where l.entry_no = e.entry_no
                   and l.book in ('client_payable', 'commission_receivable', 'client_advance_receivable', 'servicer_revenue',
                                  'client_credit_owed'))
         and e.client_organization_id is null)
     or (e.payment_id is not null and e.payment_organization_id is distinct from e.organization_id);
  if v_bad is not null then
    raise exception 'ledger: entry % pays no client of this servicer, or names a payment of another one', v_bad
      using errcode = 'LG002';
  end if;
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l join pg_temp._lps_e e on e.entry_no = l.entry_no
  where e.payment_id is not null and l.currency <> e.payment_currency;
  if v_bad is not null then
    raise exception 'ledger: line % is not in the currency of its payment', v_bad using errcode = 'LG002';
  end if;
  -- Debtor cash only on an active account dedicated to client funds, own cash (5122) only on an active own account;
  -- a concurrent closure waits.
  perform 1 from public.bank_account b
  where b.id in (select l.bank_account_id from pg_temp._lps_l l where l.bank_account_id is not null)
  order by b.id for share;
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l left join public.bank_account b on b.id = l.bank_account_id
  where l.book in ('client_money_cash', 'own_cash')
    and (b.id is null or b.organization_id <> l.organization_id or b.currency <> l.currency
         or b.purpose <> case l.book when 'client_money_cash' then 'client_funds' else 'own' end
         or b.status <> 'active');
  if v_bad is not null then
    raise exception 'ledger: line % is not on an active bank account of its purpose of this servicer (R124-2)', v_bad
      using errcode = 'LG002';
  end if;

  -- Fail fast (the deferred check is the backstop): balanced, receivable mirror, each fund closed (I2′), the
  -- 4679 / 4689 mirror (I12) (LG001).
  select min(k) into v_bad from (
    select l.entry_no || ' ' || l.currency as k from pg_temp._lps_l l
    group by l.entry_no, l.currency having sum(l.amount_minor) <> 0
    union all
    select l.entry_no || ' ' || l.component || ' ' || l.currency from pg_temp._lps_l l
    where l.book in ('debtor_receivable', 'owner_claim')
    group by l.entry_no, l.component, l.currency having sum(l.amount_minor) <> 0
    union all
    select l.entry_no || ' client fund ' || l.currency from pg_temp._lps_l l
    where l.book in ('client_money_cash', 'unallocated_payment', 'client_payable', 'due_to_servicer')
    group by l.entry_no, l.currency having sum(l.amount_minor) <> 0
    union all
    select l.entry_no || ' servicer fund ' || l.currency from pg_temp._lps_l l
    where l.book in ('due_from_client_funds', 'own_cash', 'commission_receivable', 'client_advance_receivable',
                     'vat_collected', 'vat_pending', 'servicer_revenue', 'bank_fees', 'servicer_losses',
                     'client_credit_owed', 'written_off_recovered')
    group by l.entry_no, l.currency having sum(l.amount_minor) <> 0
    union all
    select l.entry_no || ' 4679/4689 ' || l.currency from pg_temp._lps_l l
    where l.book in ('due_to_servicer', 'due_from_client_funds')
    group by l.entry_no, l.currency having sum(l.amount_minor) <> 0) x;
  if v_bad is not null then
    raise exception 'ledger: entry % is not balanced, breaks a mirror, or leaves a fund open', v_bad
      using errcode = 'LG001';
  end if;

  -- Whatever lowers a payment's remainder or a receivable, and every entry that moves 4670 (decided by its lines, not
  -- its type: the pending queue is read under this lock, M2c §5.5), waits for the servicer's allocation lock; then
  -- every writer of 4679 takes the remit lock. Order: allocation lock, then remit lock (then the invoice counter).
  perform pg_advisory_xact_lock(hashtext('payments:' || x.org))
  from (select distinct e.organization_id::text as org from pg_temp._lps_e e
        where e.entry_type in ('allocation', 'forward', 'cash_out', 'netting')
           or exists (select 1 from pg_temp._lps_l l where l.entry_no = e.entry_no and l.book = 'client_payable')
        order by 1) x;
  perform pg_advisory_xact_lock(hashtext('remit:' || x.org))
  from (select distinct e.organization_id::text as org from pg_temp._lps_e e
        where exists (select 1 from pg_temp._lps_l l where l.entry_no = e.entry_no and l.book = 'due_to_servicer')
        order by 1) x;

  -- Get or create the ledger accounts.
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, portfolio_id,
                                     account_id, claim_item_id, component)
  select distinct l.organization_id, 'debtor_receivable', l.currency, l.client_organization_id, l.portfolio_id,
         l.account_id, l.claim_item_id, l.component
  from pg_temp._lps_l l where l.book = 'debtor_receivable'
  on conflict (claim_item_id, component) do nothing;
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, owner_organization_id,
                                     portfolio_id, component, bank_account_id)
  select distinct l.organization_id, l.book, l.currency, l.client_organization_id, l.owner_organization_id,
         l.portfolio_id, l.component, l.bank_account_id
  from pg_temp._lps_l l where l.book <> 'debtor_receivable'
  on conflict (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component,
               bank_account_id)
    where claim_item_id is null do nothing;

  -- Pooled ledger accounts: a few distinct dimensions, each found by the unique index prefix.
  -- (M2c-7f-2) each dimension by its own key, by the one index that can serve it whatever the statistics: by the first
  -- three columns alone (« is not distinct from » is no index condition) a client's dimension read every account of
  -- the servicer's book, one per client. Now the dimension's key (private.ledger_pooled_key: its eight columns, a
  -- null spelt apart) is compared with ledger_account_pooled_key_uq's expression, and nothing else of the account is:
  -- no other index of ledger_account has a condition to work with (« book <> … », its predicate, is no btree
  -- condition), so no planted, stale or missing statistics, nor an index's size, can price another one the cheaper
  -- (with a client's own index, its predicate « portfolio_id is null » priced ledger_account_portfolio_idx, the
  -- « book = » ledger_account_org_book_idx, alike when the table was analysed empty). The key is one-to-one with the
  -- eight columns, and every account outside debtor_receivable has no claim item (ledger_account_shape): the account
  -- found is ledger_account_pooled_uq's.
  drop table if exists pg_temp._lps_dim;
  create temp table _lps_dim on commit drop as
  select d.*, (select la.id from public.ledger_account la
               where la.book <> 'debtor_receivable'
                 and private.ledger_pooled_key(la.organization_id, la.book, la.currency, la.client_organization_id,
                                               la.owner_organization_id, la.portfolio_id, la.component,
                                               la.bank_account_id)
                     = private.ledger_pooled_key(d.organization_id, d.book, d.currency, d.client_organization_id,
                                                 d.owner_organization_id, d.portfolio_id, d.component,
                                                 d.bank_account_id)) as ledger_account_id
  from (select distinct l.organization_id, l.book, l.currency, l.client_organization_id, l.owner_organization_id,
               l.portfolio_id, l.component, l.bank_account_id
        from pg_temp._lps_l l where l.book <> 'debtor_receivable') d;

  -- (M2c-7f-2) a receivable line's account by its own key (ledger_account_receivable_uq: item, component), one probe
  -- per line: joined, stale statistics hashed the whole of ledger_account — every servicer's accounts — at each call
  drop table if exists pg_temp._lps_x;
  create temp table _lps_x on commit drop as
  select l.entry_no, l.line_no, l.amount_minor, l.currency,
         coalesce(case when l.book = 'debtor_receivable' then
                    (select r.id from public.ledger_account r
                     where r.claim_item_id = l.claim_item_id and r.component = l.component) end,
                  d.ledger_account_id) as ledger_account_id
  from pg_temp._lps_l l
  left join pg_temp._lps_dim d on l.book <> 'debtor_receivable' and d.organization_id = l.organization_id
    and d.book = l.book and d.currency = l.currency
    and d.client_organization_id is not distinct from l.client_organization_id
    and d.owner_organization_id is not distinct from l.owner_organization_id
    and d.portfolio_id is not distinct from l.portfolio_id
    and d.component is not distinct from l.component
    and d.bank_account_id is not distinct from l.bank_account_id;
  if exists (select 1 from pg_temp._lps_x where ledger_account_id is null)
     or (select count(*) from pg_temp._lps_x) <> (select count(*) from pg_temp._lps_l) then
    raise exception 'ledger: lines without their ledger accounts' using errcode = 'LG006';
  end if;
  analyze pg_temp._lps_x;

  -- Canonical request hash per entry: line order does not matter.
  drop table if exists pg_temp._lps_h;
  create temp table _lps_h on commit drop as
  select e.entry_no, c.line_count,
         encode(sha256(convert_to(jsonb_build_object(
           'type', e.entry_type,
           'effective_date', e.effective_date,
           'account_id', e.account_id,
           'client_organization_id', e.client_organization_id,
           'payment_id', e.payment_id,
           'source', jsonb_build_array(e.source_type, e.source_id),
           'reason', e.reason,
           'engine', jsonb_build_array(e.engine_version, e.inputs_hash),
           'lines', c.lines)::text, 'UTF8')), 'hex') as request_hash
  from pg_temp._lps_e e
  join (select x.entry_no, count(*)::integer as line_count,
               jsonb_agg(jsonb_build_array(x.ledger_account_id, x.currency, x.amount_minor)
                         order by x.ledger_account_id, x.amount_minor) as lines
        from pg_temp._lps_x x group by x.entry_no) c on c.entry_no = e.entry_no;

  drop table if exists pg_temp._lps_new;
  create temp table _lps_new (id uuid primary key) on commit drop;
  with ins as (
    insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                     effective_date, line_count, idempotency_key, request_hash, payment_id, source_type,
                                     source_id, reason, engine_version, inputs_hash)
    select e.id, e.organization_id, e.client_organization_id, e.portfolio_id, e.account_id, e.entry_type,
           e.effective_date, h.line_count, e.idempotency_key, h.request_hash, e.payment_id, e.source_type,
           e.source_id, e.reason, e.engine_version, e.inputs_hash
    from pg_temp._lps_e e join pg_temp._lps_h h on h.entry_no = e.entry_no
    order by e.entry_no
    on conflict (organization_id, idempotency_key) do nothing
    returning id
  )
  insert into pg_temp._lps_new select ins.id from ins;

  -- A key already used: the same request returns its entry, another request is refused.
  select min(e.idempotency_key) into v_bad
  from pg_temp._lps_e e
  join pg_temp._lps_h h on h.entry_no = e.entry_no
  join public.ledger_entry x on x.organization_id = e.organization_id and x.idempotency_key = e.idempotency_key
  where not exists (select 1 from pg_temp._lps_new n where n.id = e.id) and x.request_hash <> h.request_hash;
  if v_bad is not null then
    raise exception 'ledger: idempotency key % was used for a different request', v_bad using errcode = 'LG004';
  end if;

  insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency, effective_date)
  select e.id, x.line_no, x.ledger_account_id, x.amount_minor, x.currency, e.effective_date
  from pg_temp._lps_e e
  join pg_temp._lps_new n on n.id = e.id
  join pg_temp._lps_x x on x.entry_no = e.entry_no;

  -- Every pending check now (balance, mirror, closure, shapes, payments, receivables): a refused
  -- request fails here, inside the caller's call, with its SQLSTATE.
  set constraints public.ledger_entry_balanced immediate;
  set constraints public.ledger_entry_balanced deferred;

  return query
  select e.entry_no, coalesce(n.id, x.id), n.id is not null
  from pg_temp._lps_e e
  left join pg_temp._lps_new n on n.id = e.id
  left join public.ledger_entry x on n.id is null and x.organization_id = e.organization_id
    and x.idempotency_key = e.idempotency_key
  order by e.entry_no;
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here, as their latest migrations left them)
------------------------------------------------------------------------------------------

-- (20261127090000) what the client may pay: internal
revoke execute on function private.client_payment_docs(uuid, char, date) from public, anon, authenticated, service_role;
-- (20261123090000) the worker's prepare reads: the worker's only
revoke execute on function private.client_open_advances(uuid, char) from public, anon, authenticated;
grant execute on function private.client_open_advances(uuid, char) to service_role;
-- (20261124090000) the ledger's posting set: internal
revoke execute on function private.ledger_post_set() from public, anon, authenticated, service_role;
-- (M2c-7f-2 review round 1) the prepare's earlier charges, whole and summed: the worker's
revoke execute on function private.remittance_earlier_charges(uuid[]), private.remittance_charge_totals(uuid, uuid[])
  from public, anon, authenticated;
grant execute on function private.remittance_earlier_charges(uuid[]), private.remittance_charge_totals(uuid, uuid[])
  to service_role;
-- (M2c-7f-2) the pooled accounts' key: internal (an index expression; ledger_post_set's lookup)
revoke execute on function private.ledger_pooled_key(uuid, text, char, uuid, uuid, uuid, text, uuid)
  from public, anon, authenticated, service_role;
