-- M2c-7f-1 « hardening and the deferred fixes » (plan docs/design/m2c-7f-plan.md §2; docs/design/m2c-7-plan.md §8.1;
-- ADR-0014 « M2c-7f-1 »). Forward-only. The cancellation-after-download switch is not written here (it stays off).
--
-- The reads (the plan class that broke main after 7a and in PR #50's CI round):
--   H3  main's own nightly probes of bank_transaction_org_idx — debit_unclassified's three kind branches,
--       duplicate_unresolved, run_transfer_checks' other_debit read — served by single-column partial indexes of their
--       kinds (a subset of bank_transaction_org_idx, priced with its correlation and a shorter descent: never above it),
--       created beside the multi-column ones (which keep serving the ordered reads under true statistics);
--   H4  the funds pass's candidates (private.bank_booking_candidates): H3's indexes and three for its other branches;
--   H1  private.run_payment_checks with enable_seqscan off (H2's change in the same copy); the servicer's invoices of
--       a kind by a partial (organization_id) index; private.run_transfer_checks' failed-file probe by the file's
--       items, each transfer by its key, and (review round 1, CC-1) its transfers in flight by the servicer's key;
--   H5  public.debit_queue: enable_seqscan off, its probes of the review, link, release and resolution tables keyed
--       laterals by the line's key in each branch and in the final select;
--   H6  private.apply_bank_bookings: the review replacement by a keyed delete;
--   H19 private.inflight_overdue_lines: a run's lines by the run's key alone (the 7a CI round's form);
--   H7  the payout files' reads that read beyond a file's items under 7e-1 round 2's plant moved to them (D12):
--       private.transfer_file_lock_runs, private.transfer_file_release, public.mark_transfer_file_sent,
--       private.transfer_line_supersedes and the two-step confirmation's update, each with enable_seqscan off;
--       private.transfer_cancel_evidence's and private.transfer_file_executed's whole-file reads of the items by the
--       file's key; and
--       private.bank_transfer_guard's re-issue check by the predecessor's key; private.transfer_line_locks'
--       read of a late predecessor's file. bank_transfer_filed_amount_idx is kept (the plan's step 1 measured: its
--       drop flipped 7e-1's own-account file reads to a BitmapAnd with bank_transfer_org_idx's status column, every
--       servicer's ordered transfers read, in the db job's order; with every file-keyed read through the items it
--       no longer serves one);
--   H20 the prepare's loader reads (the pending items by draft, the terms by mandate) by key in SQL helpers, and the
--       prepare's begin and draft (private.remittance_prepare_begin, private.remittance_record_draft) by the draft's
--       key in a fence;
--   CI round (PR #52) bank_transfer_debtor_idx, bank_transfer_top_up_idx and bank_transfer_servicer_flight_idx serve
--       only reads that name their key (never read whole); private.top_up_needed reads the servicer's sweeps
--       and top-ups in flight by bank_transfer_servicer_flight_key_idx (the servicer's key as text) through
--       private.servicer_flight_minor (new);
--   CI round (PR #52), round 2: every other partial index of bank_transfer bound to its key the same way
--       (bank_transfer_to_file_idx, bank_transfer_payout_iban_idx, bank_transfer_cancelled_filed_idx,
--       bank_transfer_client_cancelled_idx, bank_transfer_filed_amount_idx), bank_transfer_debtor_idx keyed by the
--       paying account and the status; public.top_up_overview, public.generate_top_up_file,
--       public.top_up_credit_options (redefined) and private.transfer_line_supersedes read the servicer's sweeps and
--       top-ups in flight by the servicer's text key (private.servicer_flight_minor, private.servicer_flight: new),
--       private.transfers_in_flight an account's transfers in a file by the account's key.
-- The behaviour:
--   H2  servicer_shortfall = private.top_up_needed (the sweeps in flight);
--   H9  public.request_top_up takes the remit lock (MONEY-BANK-3: serialised with the hourly order);
--   H10 an own-account file refused by the switch-on two-step cancellation (not_a_payout_file);
--   H11 MONEY-2: a proof already recorded is refused (evidence_already_used), keyed on its SHA-256 among the client's
--       proofs, the client payments' entries by their source (a partial index);
--   H12 bad_date names the greatest refused day;
--   H13 the withdrawal names, per advance, the requests that still name it;
--   H14 private.post_allocations' backstop re-reads the client's mandate's end;
--   H15 a barred invoice is dated by the earliest bar in effect, least(withheld_on, that day) in the filter, and named
--       by the bar recorded that day (review round 1, TUI-H15-BAR-DAY);
--   H16 public.client_advance_totals: « Avances »' totals and the chip from the 4112[c] / 419[c] balances (CCS-2);
--       (review round 1) a client's page of public.client_advances by the client's key;
--   H17 private.requeue_repayment_letters, hourly: a letter whose job died is re-queued;
--   H22 public.match_queue_accounts and public.search_payment_files return the client's mandate's end (TUI-5).
-- Every redefinition is copied whole from its latest definition across every migration (the last one wins), its header
-- naming the file and line; SECURITY DEFINER, every SET clause, search_path '' and the grants restated (below).
-- No table is added.


------------------------------------------------------------------------------------------
-- H3, H4: the servicer's lines of a kind, by single-column partial indexes
------------------------------------------------------------------------------------------

-- debit_unclassified's first branch and duplicate_unresolved (their kinds imply its predicate)
create index bank_transaction_debit_kinds_org_idx on public.bank_transaction (organization_id)
  where kind in ('return', 'refund_out', 'suspected_duplicate');
-- debit_unclassified's second branch (its three kinds) and the funds pass's and the queue's own kinds
create index bank_transaction_own_kinds_org_idx on public.bank_transaction (organization_id)
  where kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in', 'label_reference');
-- debit_unclassified's third branch, run_transfer_checks' other_debit read, the funds pass's and the queue's
create index bank_transaction_other_debit_org_idx on public.bank_transaction (organization_id)
  where kind = 'other_debit';
-- (H4) the funds pass's other branches: our batch lines, the returns credited, the entries kept unsplit holding ours
create index bank_transaction_batch_line_org_idx on public.bank_transaction (organization_id)
  where direction = 'debit' and end_to_end_id is null and payment_info_id is not null;
create index bank_transaction_return_credit_org_idx on public.bank_transaction (organization_id)
  where direction = 'credit' and kind = 'return';
create index bank_transaction_unsplit_ours_org_idx on public.bank_transaction (organization_id)
  where unsplit_ours > 0;


------------------------------------------------------------------------------------------
-- H1: the servicer's invoices of a kind
------------------------------------------------------------------------------------------

-- private.run_remittance_runs_checks' pending-VAT sums read `organization_id = … and kind = 'invoice'`: with the only
-- index naming `kind` its second column (commission_invoice_mandate_idx), a planner that sees the servicer as most of
-- the table read every servicer's invoices there (the close-out reads test: 12,368 rows for the servicer's 10,001).
-- A single-column partial index, as H3's: a two-column (organization_id, kind) index was taken by the approval's
-- other reads of the servicer's invoices too, which then read every one of them (the set-off-bar reads test,
-- private.approve_remittance_run: 10,007 rows in the db job's aged state); a read without `kind = 'invoice'` cannot
-- take this one
create index commission_invoice_invoice_org_idx on public.commission_invoice (organization_id)
  where kind = 'invoice';


------------------------------------------------------------------------------------------
-- H11: one recording per proof
------------------------------------------------------------------------------------------

-- a client payment entry names its proof (source 'document', the evidence's id): the entries naming a proof, by its key
-- (not unique: 045b's and 046a's fixtures plant raw client payment entries on one source; the commands' own guard,
-- under the servicer's locks, refuses a proof recorded twice — ADR-0014 « M2c-7f-1 », deviation)
create index ledger_entry_client_payment_source_idx on public.ledger_entry (source_id)
  where entry_type = 'client_payment_own' and source_type = 'document';
-- the client's proofs of the same file, by the client and the file's SHA-256 (two uploads of one file are two documents)
create index document_client_payment_sha256_idx on public.document (client_organization_id, sha256)
  where kind = 'client_payment_evidence';


------------------------------------------------------------------------------------------
-- CI round (PR #52): the transfers in flight read by the servicer's key, never a whole partial index
------------------------------------------------------------------------------------------

-- In the db job's run 46054376194 the nightly's advance checks read 209 bank_transfer rows for a servicer with two:
-- private.top_up_needed's sums (`organization_id = …, currency = …, kind = 'sweep' | 'top_up', status in ('ordered',
-- 'in_file')`) took bank_transfer_debtor_idx and bank_transfer_top_up_idx whole — every servicer's transfers in flight,
-- every servicer's top-ups —, the sums' constants proving both predicates, bank_transfer then without statistics (only
-- ever analysed inside the reads tests' rolled-back transactions) and bank_transfer_servicer_flight_idx bloated by their
-- rolled-back plants (31 pages for 10 entries: priced above a whole read of either). The same reads served the nightly's
-- run_transfer_checks (its sweeps, payouts and refunds in flight, its top-ups pending): 618 rows for a servicer with 6
-- transfers. (ADR-0014 « M2c-7f-1 — CI round (PR #52) ».)
-- 1. The partial indexes read whole so serve only the reads that name their key: their key's `is not null` in their
--    predicates (each column is NOT NULL: the same entries), which a condition on the key proves and nothing else
--    does. Every reader keyed by the paying account keeps bank_transfer_debtor_idx and bank_transfer_top_up_idx, every
--    reader keyed by the servicer bank_transfer_servicer_flight_idx; no read by another key, or by none, can read one
--    whole (the reads test's plant also showed private.run_transfer_checks' check of each sweep, by its id, reading
--    bank_transfer_servicer_flight_idx whole: every servicer's sweeps in flight, once per sweep).
--    (Round 2) bank_transfer_debtor_idx is keyed by the paying account and then the status (the same entries): an
--    account's transfers in a file (private.transfers_in_flight, below) are read by both bounds, never with its
--    ordered ones. A read naming the account and a status in flight is then bounded by both of its conditions, where
--    bank_transfer_org_idx's status column alone (7f-1 review round 1, CC-1) returns every account's entries of that
--    status: never fewer entries, nor fewer rows to fetch.
drop index public.bank_transfer_debtor_idx;
create index bank_transfer_debtor_idx on public.bank_transfer (debtor_bank_account_id, status)
  where status in ('ordered', 'in_file') and debtor_bank_account_id is not null;
drop index public.bank_transfer_top_up_idx;
create index bank_transfer_top_up_idx on public.bank_transfer (debtor_bank_account_id, created_at desc)
  where kind = 'top_up' and debtor_bank_account_id is not null;
drop index public.bank_transfer_servicer_flight_idx;
create index bank_transfer_servicer_flight_idx on public.bank_transfer (organization_id, currency, kind)
  where kind in ('sweep', 'top_up') and status in ('ordered', 'in_file') and organization_id is not null;
-- 1b. (Round 2; round 1's Left open) The other partial indexes of bank_transfer with the same shape, a predicate a read
--    can prove without naming the key, bound to their key the same way (each key column NOT NULL, or, for a payout,
--    `bank_transfer_payout_client`: the same entries): the ordered transfers of a paying account
--    (bank_transfer_to_file_idx: `status = 'ordered'` alone took it whole), a client's booked payouts by IBAN
--    (bank_transfer_payout_iban_idx), the servicer's cancelled filed transfers (bank_transfer_cancelled_filed_idx), a
--    client's cancelled filed payouts (bank_transfer_client_cancelled_idx) and a paying account's filed transfers by
--    amount (bank_transfer_filed_amount_idx: a read by `transfer_file_id` proves its predicate — 7e-1 round 2 and
--    7f-1's H7 saw it taken whole). Every partial index of the table now holds its key's `is not null`
--    (test_close_out_reads_integration.py::test_no_partial_index_of_the_transfers_is_read_without_its_key).
drop index public.bank_transfer_to_file_idx;
create index bank_transfer_to_file_idx on public.bank_transfer (debtor_bank_account_id, created_at, id)
  where status = 'ordered' and debtor_bank_account_id is not null;
drop index public.bank_transfer_payout_iban_idx;
create index bank_transfer_payout_iban_idx on public.bank_transfer (client_organization_id, payee_iban)
  where kind = 'payout' and status = 'booked' and client_organization_id is not null;
drop index public.bank_transfer_cancelled_filed_idx;
create index bank_transfer_cancelled_filed_idx on public.bank_transfer (organization_id, debtor_bank_account_id)
  where status = 'cancelled' and transfer_file_id is not null and organization_id is not null;
drop index public.bank_transfer_client_cancelled_idx;
create index bank_transfer_client_cancelled_idx on public.bank_transfer (client_organization_id, currency)
  where kind = 'payout' and status = 'cancelled' and transfer_file_id is not null and client_organization_id is not null;
drop index public.bank_transfer_filed_amount_idx;
create index bank_transfer_filed_amount_idx on public.bank_transfer (debtor_bank_account_id, amount_minor)
  where transfer_file_id is not null and debtor_bank_account_id is not null;
-- 2. What is needed reads the servicer's sweeps and top-ups in flight of the currency through a key no other index holds
--    and no partial index's predicate: bank_transfer_servicer_flight_key_idx, the servicer's id as text, then the kind,
--    the currency and the status, read by private.servicer_flight_minor with the kind and the statuses as its
--    parameters. Keyed by `organization_id` the sums could also be served from bank_transfer_org_idx by the servicer and
--    the status (every transfer of the servicer in flight); with the kind and the statuses as constants, from
--    bank_transfer_servicer_flight_idx read whole by the currency and the kind (every servicer's sweeps or top-ups in
--    flight: measured, the planner alternated between it and this index under the reads test's plant). By the text key
--    with parameters, bank_transfer_org_idx has no bound (its whole) and no partial index's predicate is proved: this
--    index's four bounds are the only keyed path, its entries read the servicer's sweeps or top-ups in flight of the
--    currency. Its predicate, `(organization_id::text) is not null` (every row: the column is NOT NULL), is proved by a
--    condition on the text key only: no other read can take it whole.
--    (Round 2) The four in one text key, `servicer/kind/currency/status`, read by its values (one per status): with the
--    status a column of its own the read could still be served by bank_transfer_org_idx's status column alone, a
--    whole read of it (every servicer's transfers of those statuses: 5,140 rows under the reads test's plant once that
--    index is the plant's size, beside this one's dead pages). No column of the table is named bare in the read, so
--    no other index has a condition to serve: this index's key is the only path, its entries the servicer's
--    transfers of the kind and currency in those statuses (the booked past never read). The separators and the fixed
--    lengths (a uuid's text, a currency's three letters; no kind or status holds a « / ») keep each key one transfer
--    set's. Its predicate, the key's `is not null` (every row), is proved by a condition on the key only.
create index bank_transfer_servicer_flight_key_idx
  on public.bank_transfer ((organization_id::text || '/' || kind || '/' || currency || '/' || status))
  where (organization_id::text || '/' || kind || '/' || currency || '/' || status) is not null;

-- The servicer's transfers of a kind and a currency in one of the statuses, their sum (0 when none): by
-- bank_transfer_servicer_flight_key_idx alone (above, 2.). The kind and the statuses are parameters so that no partial
-- index's predicate is proved. Not inlined (SECURITY DEFINER, SET clauses): the caller's constants stay parameters.
-- (Round 2) By the index's text key, one value per status (the same rows).
create function private.servicer_flight_minor(p_organization_id uuid, p_currency char(3), p_kind text,
                                              p_statuses text[])
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(sum(x.amount_minor), 0)::bigint
  from public.bank_transfer x
  where (x.organization_id::text || '/' || x.kind || '/' || x.currency || '/' || x.status)
        = any (array(select p_organization_id::text || '/' || p_kind || '/' || p_currency || '/' || s.status
                     from unnest(p_statuses) s(status)));
$$;

-- (Round 2) The same transfers, each whole (the servicer's of a kind and a currency in one of the statuses), by
-- bank_transfer_servicer_flight_key_idx alone as private.servicer_flight_minor reads them: for the reads that list or
-- check them (« Approvisionnements »' ordered count, « Générer le fichier (compte propre) »'s locks and items,
-- « Rattacher à TOP… »'s options). In-line, with the kind and the statuses as constants, those reads proved
-- bank_transfer_servicer_flight_idx's predicate and, keyed by `organization_id`, could also be served by
-- bank_transfer_org_idx by the servicer and the status: under the reads test's plant (no statistics, the flight index
-- bloated) each read every transfer of the servicer in flight (its refunds, its payouts and its other currencies' too:
-- 558 rows for 5 top-ups, 5,558 beside a run's 5,000 payouts). Not inlined (SECURITY DEFINER, SET clauses): each
-- plan of it generic, the caller's constants parameters.
create function private.servicer_flight(p_organization_id uuid, p_currency char(3), p_kind text, p_statuses text[])
returns setof public.bank_transfer
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select x.*
  from public.bank_transfer x
  where (x.organization_id::text || '/' || x.kind || '/' || x.currency || '/' || x.status)
        = any (array(select p_organization_id::text || '/' || p_kind || '/' || p_currency || '/' || s.status
                     from unnest(p_statuses) s(status)));
$$;

-- private.top_up_needed, redefined from 20261129090000_top_ups.sql (line 181; same signature and settings, created or
-- replaced; SECURITY DEFINER, search_path '', enable_seqscan off and its privileges restated below). CI round (PR #52):
-- its two sums by private.servicer_flight_minor (the same rows: the servicer's sweeps, then its top-ups, of the currency,
-- ordered or in a file; a uuid's text is its canonical form); the formula is unchanged (design §13 #4: max(0, Σ 4679 +
-- the sweeps ordered or in a file − the top-ups ordered or in a file)).
create or replace function private.top_up_needed(p_organization_id uuid, p_currency char(3))
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select greatest(0, private.servicer_owed_minor(p_organization_id, p_currency)
                     + private.servicer_flight_minor(p_organization_id, p_currency, 'sweep', array['ordered', 'in_file'])
                     - private.servicer_flight_minor(p_organization_id, p_currency, 'top_up',
                                                     array['ordered', 'in_file']))::bigint;
$$;

-- private.run_payment_checks, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 3310; same signature,
-- SECURITY DEFINER, search_path '' and its grants restated below). M2c-7f-1:
--   H1 (ADR-0014 « M2c-6b-3b part 3 — CI round (PR #40) », Left open): `set enable_seqscan = off` — under forgotten
--     statistics its reads of refund_request by a payment's or a transfer's key ran as a scan of the table per row
--     (1.7 million rows for 640 payments) and bank_transfer was read by a scan of every servicer's transfers. The
--     setting holds for the checks it calls (run_remittance_checks and below: they read by key already). Every other
--     statement is unchanged; the servicer's invoices are read once per sub-check by design (H1's attribution, the
--     close-out reads test: run_remittance_runs_checks' sub-checks, ADR « M2c-7f-1 »).
--   H2 (plan D7, money rule 19): servicer_shortfall is private.top_up_needed (the sweeps in flight counted), its
--     details the three parts.
--   H3: its debit_unclassified branches and duplicate_unresolved are served by the single-column partial indexes above
--     (the bodies unchanged).
create or replace function private.run_payment_checks(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_run uuid;
  v_today date := private.paris_today();
  v_summary jsonb;
  v_violations integer;
  v_alerts integer;
begin
  if not exists (select 1 from public.organization o where o.id = p_organization_id and o.kind = 'servicer') then
    raise exception 'checks: unknown servicer %', p_organization_id using errcode = '22023';
  end if;
  insert into public.payment_check_run (organization_id) values (p_organization_id) returning id into v_run;
  drop table if exists pg_temp._chk;
  create temp table _chk (code text, severity text, subject_type text, subject_id uuid, currency char(3),
                          amount_minor bigint, count integer, oldest_days integer, details jsonb) on commit drop;

  -- Every check reads the books in ONE statement, so in one snapshot: an entry or a payment committed while the
  -- checks run (a link, a release, an allocation from a PostgREST session) is in every check or in none — never a gap
  -- between the cash read by one check and the payments read by another (review fix: the job runs READ COMMITTED,
  -- where each statement of a function sees the latest commits).
  -- Review round 2 (P3): every check reads the servicer's rows by its key and the rows it needs by theirs, whatever the
  -- statistics (ARCHITECTURE §4): a lateral holding only a key (OFFSET 0: never pulled up, nothing pushed into it) for
  -- each row reached from another, a correlated EXISTS (OFFSET 0: never turned into a hashed anti-join) for each test of
  -- presence. Joined to the servicer's rows by hash, a table was read whole — every servicer's postings, entries, bank
  -- lines and notifications, cold after a scale run's writes (5 to 7.6 s for a servicer of 5,000 refunds). A posting's
  -- account is its entry's servicer's (LG002), and an entry names a payment of its own servicer (LG002): the
  -- servicer's accounts reach every posting of its entries, its payments every entry tagged with a payment. A check
  -- that sums the servicer's ledger by definition (the funds' identities, each client's 4670, the receivables) reads
  -- each of its accounts' postings once, through the accounts.
  insert into pg_temp._chk (code, severity, subject_type, subject_id, currency, amount_minor, count, oldest_days, details)
  with pe as materialized (
    -- Each of the servicer's payments with its entries' postings on the unallocated pool (4710: what it allocated,
    -- forwarded or returned; a payment with none, one row of nulls), from the payment by keys: its entries by its
    -- id, their postings by theirs (those on the servicer's 4710 accounts), the entry each reverses by its id. (As a
    -- join of the payments to their grouped postings, a servicer whose payments the statistics did not know yet was
    -- joined by a nested loop: 5,000 payments × 2,500 groups = 12.5 million rows compared, 7.7 s.)
    select p.id, p.status, p.review_reason, p.account_id, p.amount_minor, p.currency, p.booking_date, p.bank_account_id,
           p.bank_transaction_id, p.updated_at, x.entry_account_id, x.entry_type, x.posted
    from public.payment p
    left join lateral (
      select e.account_id as entry_account_id, coalesce(t.entry_type, e.entry_type) as entry_type, lp.amount_minor as posted
      from (select q.id, q.organization_id, q.account_id, q.entry_type, q.reverses_entry_id from public.ledger_entry q
            where q.payment_id = p.id offset 0) e
      cross join lateral (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                          where q.entry_id = e.id offset 0) lp
      left join lateral (select q.entry_type from public.ledger_entry q where q.id = e.reverses_entry_id offset 0) t on true
      where e.organization_id = p_organization_id
        and lp.ledger_account_id = any (array(select a.id from public.ledger_account a
                                              where a.organization_id = p_organization_id
                                                and a.book = 'unallocated_payment'))) x on true
    where p.organization_id = p_organization_id
  ),
  pos as materialized (
    -- Every payment's position from its tagged entries (one pass), and its pending refund (by the payment's key).
    select g.id, g.status, g.review_reason, g.account_id, g.amount_minor, g.currency, g.booking_date, g.bank_account_id,
           g.bank_transaction_id, g.updated_at, g.allocated, g.returned,
           (g.amount_minor - g.allocated - g.returned)::bigint as unallocated,
           coalesce(q.pending, 0)::bigint as pending, coalesce(q.n, 0) as pending_n
    from (select c.id, c.status, c.review_reason, c.account_id, c.amount_minor, c.currency, c.booking_date,
                 c.bank_account_id, c.bank_transaction_id, c.updated_at,
                 coalesce(sum(c.posted) filter (where c.entry_type in ('allocation', 'forward')), 0)::bigint as allocated,
                 coalesce(sum(c.posted) filter (where c.entry_type = 'cash_out'), 0)::bigint as returned
          from pe c
          group by c.id, c.status, c.review_reason, c.account_id, c.amount_minor, c.currency, c.booking_date,
                   c.bank_account_id, c.bank_transaction_id, c.updated_at) g
    left join lateral (select sum(q.amount_minor) filter (where q.status = 'requested') as pending,
                              count(*) filter (where q.status = 'requested') as n
                       from (select q.amount_minor, q.status from public.refund_request q
                             where q.payment_id = g.id offset 0) q) q on true
    -- (by the payment's key only — a request's payment is its servicer's, its foreign key: with the servicer or the
    -- status in the lateral, stale statistics chose the index of the requests still requested, led by the servicer,
    -- and read every request of the servicer for each payment, the executed ones' dead versions included until
    -- vacuum: 1.44 million buffers, 2 s, for 5,000 refunds)
  ),
  bal as materialized (
    -- Each of the servicer's accounts of the funds' books (client and servicer money: 5120, 4710, 4670, 4679, the
    -- servicer's own) with what its postings add up to, read by the account's key.
    select la.id, la.book, b.money_of, la.currency, la.client_organization_id, la.bank_account_id, la.portfolio_id,
           s.total
    from public.ledger_account la
    join public.ledger_book b on b.code = la.book
    cross join lateral (select sum(q.amount_minor) as total
                        from (select q.amount_minor from public.ledger_posting q
                              where q.ledger_account_id = la.id offset 0) q) s
    where la.organization_id = p_organization_id
      and la.book = any (array(select k.code from public.ledger_book k where k.money_of in ('client', 'servicer')))
      and s.total is not null
  ),
  recv as materialized (
    -- Each of the servicer's receivable accounts (1100: one per claim item and component): what its postings add up
    -- to, and whether a payment (an allocation or a direct payment's adjustment) or a netting lowered it — each
    -- lowering posting's entry read by its id.
    select la.id, la.claim_item_id, la.component, la.currency, la.portfolio_id, b.balance, b.lowered, b.lowered_item
    from public.ledger_account la
    cross join lateral (
      select sum(q.amount_minor) as balance, coalesce(bool_or(e.lowers), false) as lowered,
             coalesce(bool_or(e.lowers_item), false) as lowered_item
      from (select q.entry_id, q.amount_minor from public.ledger_posting q where q.ledger_account_id = la.id offset 0) q
      left join lateral (
        select x.entry_type in ('allocation', 'netting')
                 or (x.entry_type = 'adjustment' and x.source_type = 'direct_payment') as lowers,
               x.entry_type = 'allocation'
                 or (x.entry_type = 'adjustment' and x.source_type = 'direct_payment') as lowers_item
        from public.ledger_entry x where q.amount_minor < 0 and x.id = q.entry_id offset 0) e on true) b
    where la.organization_id = p_organization_id and la.book = 'debtor_receivable' and b.balance is not null
  ),
  cpb as materialized (
    -- Review round 3 (M5, round 2's P3): each of the servicer's clients' running balances of 4670 (I13, I14), read once
    -- by the servicer's key (client_payable_balance_org_idx; before, twice, every servicer's balances by sequential scan).
    select c.client_organization_id, c.currency, c.balance_minor from private.client_payable_balance c
    where c.organization_id = p_organization_id
  )
  -- I8′: the dedicated-account fund closed per currency (5120 + 4710 + 4670 + 4679 = 0), the servicer's fund closed
  -- per currency (own_fund_identity), and the 4679 / 4689 mirror (fund_mirror, I12), from one pass over the funds.
  select x.code, 'violation'::text, 'servicer'::text, null::uuid, x.currency::char(3), x.total::bigint,
         null::integer, null::integer, x.details
  from (select f.currency, v.code, v.total, v.details
        from (select a.currency,
                     sum(a.total) filter (where a.money_of = 'client') as client_total,
                     sum(a.total) filter (where a.money_of = 'servicer') as servicer_total,
                     sum(a.total) filter (where a.book in ('due_to_servicer', 'due_from_client_funds')) as mirror_total,
                     sum(a.total) filter (where a.book = 'client_money_cash') as cash,
                     sum(a.total) filter (where a.book = 'unallocated_payment') as pool,
                     sum(a.total) filter (where a.book = 'client_payable') as owed,
                     sum(a.total) filter (where a.book = 'due_to_servicer') as servicer_share,
                     sum(a.total) filter (where a.book = 'due_from_client_funds') as servicer_claim
              from bal a where a.portfolio_id is null
              group by a.currency) f
        cross join lateral (values
          ('client_money_identity', coalesce(f.client_total, 0),
           jsonb_build_object('cash_minor', coalesce(f.cash, 0)::text, 'unallocated_minor', coalesce(f.pool, 0)::text,
                              'owed_minor', coalesce(f.owed, 0)::text,
                              'due_to_servicer_minor', coalesce(f.servicer_share, 0)::text)),
          ('own_fund_identity', coalesce(f.servicer_total, 0), '{}'::jsonb),
          ('fund_mirror', coalesce(f.mirror_total, 0),
           jsonb_build_object('due_to_servicer_minor', coalesce(f.servicer_share, 0)::text,
                              'due_from_client_funds_minor', coalesce(f.servicer_claim, 0)::text))
        ) v (code, total, details)) x
  where x.total <> 0

  union all
  -- I13: each client's 4670 never in debit, and its running balance = its postings (the commit guard's source).
  select 'client_payable_debit', 'violation', 'client', coalesce(p.client_organization_id, r.client_organization_id),
         coalesce(p.currency, r.currency), coalesce(p.total, 0)::bigint, null, null,
         jsonb_build_object('postings_minor', coalesce(p.total, 0)::text, 'running_minor', coalesce(r.balance_minor, 0)::text)
  from (select a.client_organization_id, a.currency, sum(a.total) as total
        from bal a where a.book = 'client_payable'
        group by a.client_organization_id, a.currency) p
  full join cpb r
    on r.client_organization_id = p.client_organization_id and r.currency = p.currency
  where coalesce(p.total, 0) > 0 or coalesce(p.total, 0) <> coalesce(r.balance_minor, 0)

  union all
  -- I14 (completeness; M2c-4): what each client is owed = its items waiting in the pending queue (reserved by a
  -- draft or not) + the gross (N + D) of its runs approved and not booked yet.
  select 'remittance_completeness', 'violation', 'client',
         coalesce(r.client_organization_id, q.client_organization_id, f.client_organization_id),
         coalesce(r.currency, q.currency, f.currency),
         (-coalesce(r.balance_minor, 0) - coalesce(q.total, 0) - coalesce(f.inflight, 0))::bigint, null, null,
         jsonb_build_object('owed_minor', (-coalesce(r.balance_minor, 0))::text, 'pending_minor', coalesce(q.total, 0)::text,
                            'in_flight_minor', coalesce(f.inflight, 0)::text)
  from cpb r
  full join (select q.client_organization_id, q.currency, sum(q.amount_minor) as total from private.remittance_pending q
             where q.organization_id = p_organization_id group by q.client_organization_id, q.currency) q
    on q.client_organization_id = r.client_organization_id and q.currency = r.currency
  full join (select x.client_organization_id, x.currency, sum(x.net_minor + x.settlement_minor) as inflight
             from public.remittance_run x
             where x.organization_id = p_organization_id and x.status in ('approved', 'sent')
             group by x.client_organization_id, x.currency) f
    on f.client_organization_id = coalesce(r.client_organization_id, q.client_organization_id)
   and f.currency = coalesce(r.currency, q.currency)
  where -coalesce(r.balance_minor, 0) <> coalesce(q.total, 0) + coalesce(f.inflight, 0)

  union all
  -- I19, per dedicated account: its cash = what its payments brought in less what went back out to the payers
  -- (returns, refunds) + what its lines booked in the funds moved (top-ups in; fees, losses, payouts and sweeps out;
  -- returned payouts and sweeps in). Every 5120 movement of a funds entry comes from a bank line booked here. M2c-6b-1:
  -- what a booking moved is its entry's 5120 posting, signed (a return with charges books +N and −(N − line): the
  -- booking amount × the line's direction counted it twice).
  select 'bank_cash_identity', 'violation', 'bank_account', coalesce(c.bank_account_id, y.bank_account_id, k.bank_account_id),
         b.currency, (coalesce(c.cash, 0) - coalesce(y.held, 0) - coalesce(k.moved, 0))::bigint, null, null,
         jsonb_build_object('cash_minor', coalesce(c.cash, 0)::text, 'unallocated_minor', coalesce(y.unallocated, 0)::text,
                            'allocated_minor', coalesce(y.allocated, 0)::text,
                            'booked_lines_minor', coalesce(k.moved, 0)::text)
  from (select a.bank_account_id, sum(a.total) as cash
        from bal a where a.book = 'client_money_cash'
        group by a.bank_account_id) c
  full join (select x.bank_account_id, sum(x.amount_minor - x.returned) as held, sum(x.unallocated) as unallocated,
                    sum(x.allocated) as allocated
             from pos x where x.bank_account_id is not null group by x.bank_account_id) y
    on y.bank_account_id = c.bank_account_id
  full join (select k.bank_account_id, sum(p.amount_minor) as moved
             from public.bank_line_booking k
             cross join lateral (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                                 where q.entry_id = k.entry_id offset 0) p
             cross join lateral (select q.book, q.bank_account_id from public.ledger_account q
                                 where q.id = p.ledger_account_id offset 0) la
             where k.organization_id = p_organization_id and la.book = 'client_money_cash'
               and la.bank_account_id = k.bank_account_id
             group by k.bank_account_id) k on k.bank_account_id = coalesce(c.bank_account_id, y.bank_account_id)
  cross join lateral (select q.currency from public.bank_account q
                      where q.id = coalesce(c.bank_account_id, y.bank_account_id, k.bank_account_id) offset 0) b
  where coalesce(c.cash, 0) <> coalesce(y.held, 0) + coalesce(k.moved, 0)

  union all
  -- bank_line_booked (M2c-6b-1): each booked line booked whole, signed — the commit-time check's nightly twin
  select 'bank_line_booked', 'violation', 'bank_transaction', l.id, l.currency, l.amount_minor, null, null,
         jsonb_build_object('moved_minor', m.moved::text, 'direction', l.direction)
  from (select distinct k.bank_transaction_id from public.bank_line_booking k
        where k.organization_id = p_organization_id) k
  cross join lateral (select q.id, q.currency, q.amount_minor, q.direction, q.bank_account_id
                      from public.bank_transaction q where q.id = k.bank_transaction_id offset 0) l
  cross join lateral (select private.bank_line_cash_moved(l.id, l.bank_account_id) as moved offset 0) m
  where m.moved <> case l.direction when 'credit' then l.amount_minor else -l.amount_minor end

  union all
  -- I20 transfer_booked_once (M2c-6b-1): a transfer is debited once and returned once, and its status is what its
  -- bookings say, per kind (plan §2.5 [critic]): a payout, sweep or top-up by bank_line_booking — booked or returned
  -- with exactly one debit booking whose entry is its entry, returned with its return booking, no booking while not
  -- booked; a refund by its request (the M2b RFD link: its cash_out the transfer's entry, one link; its bounce the
  -- transfer's return). A run booked with a payout has its transfer booked or returned. (Each transfer's bookings and
  -- its request read by its key.)
  select 'transfer_booked_once', 'violation', 'bank_transfer', x.id, x.currency, x.amount_minor, null, null,
         jsonb_build_object('kind', x.kind, 'status', x.status, 'debit_bookings', x.debits,
                            'return_bookings', x.returns)
  from (select t.id, t.kind, t.status, t.currency, t.amount_minor, t.entry_id, t.return_entry_id,
               c.debits, c.debit_own, c.returns, c.return_own, q.cash_out_entry_id, q.bounce_entry_id,
               case when t.kind = 'refund' and t.status in ('booked', 'returned')
                    then private.refund_debit_links(q.id) end as refund_links,
               -- M2c-6b-3a-2 (F): a late predecessor — a payout cancelled with one payout booking (and at most one
               -- return) whose run is booked and holds it in its chain, no other transfer of that chain booked so
               case when t.kind = 'payout' and t.status = 'cancelled' and c.debits = 1 and c.debit_payouts = 1
                         and c.returns <= 1
                    then exists (select 1 from public.remittance_run r
                                 where r.id = t.run_id and r.status = 'booked'
                                   and exists (select 1 from private.transfer_chain(r.transfer_id) h
                                               where h.transfer_id = t.id)
                                   and not exists (select 1
                                                   from private.transfer_chain(r.transfer_id) h
                                                   cross join lateral (select k.kind from public.bank_line_booking k
                                                                       where k.transfer_id = h.transfer_id offset 0) k
                                                   where h.transfer_id <> t.id and k.kind = 'payout'))
                    else false end as lp
        from public.bank_transfer t
        cross join lateral (
          select count(*) filter (where b.kind in ('payout', 'sweep', 'top_up')) as debits,
                 count(*) filter (where b.kind = 'payout') as debit_payouts,
                 count(*) filter (where b.kind in ('payout', 'sweep', 'top_up') and b.entry_id = t.entry_id) as debit_own,
                 count(*) filter (where b.kind in ('payout_returned', 'sweep_returned')) as returns,
                 count(*) filter (where b.kind in ('payout_returned', 'sweep_returned')
                                    and b.entry_id = t.return_entry_id) as return_own
          from (select b.kind, b.entry_id from public.bank_line_booking b where b.transfer_id = t.id offset 0) b) c
        left join lateral (select q.id, q.cash_out_entry_id, q.bounce_entry_id from public.refund_request q
                           where q.transfer_id = t.id offset 0) q on true
        where t.organization_id = p_organization_id) x
  where x.debits > 1 or x.returns > 1
     or (x.kind in ('payout', 'sweep', 'top_up')
         and ((x.status in ('booked', 'returned') and x.debit_own <> 1)
              or (x.status = 'returned' and x.return_own <> 1)
              or (x.status not in ('booked', 'returned') and (x.debits > 0 or x.returns > 0) and not x.lp)))
     or (x.kind = 'refund'
         and ((x.status in ('booked', 'returned')
               and (x.cash_out_entry_id is distinct from x.entry_id or x.refund_links <> 1))
              or (x.status = 'returned' and x.bounce_entry_id is distinct from x.return_entry_id)))
  union all
  select 'transfer_booked_once', 'violation', 'remittance_run', r.id, r.currency, r.net_minor, null, null,
         jsonb_build_object('number', r.number, 'transfer_status', t.status)
  from public.remittance_run r
  left join lateral (select q.status from public.bank_transfer q where q.id = r.transfer_id offset 0) t on true
  where r.organization_id = p_organization_id and r.status = 'booked' and r.net_minor > 0
    and (t.status is null or t.status not in ('booked', 'returned'))
    -- M2c-6b-3a-2 (F): a run booked by its late predecessor — exactly one payout of its chain cancelled and booked as
    -- its payout (read only for the rows already caught above)
    and case when t.status is null or t.status not in ('booked', 'returned') then
          (select count(*)
           from private.transfer_chain(r.transfer_id) h
           cross join lateral (select q.kind, q.status from public.bank_transfer q where q.id = h.transfer_id offset 0) q
           cross join lateral (select count(*) as n from public.bank_line_booking k
                               where k.transfer_id = h.transfer_id and k.kind = 'payout') k
           where q.kind = 'payout' and q.status = 'cancelled' and k.n = 1) <> 1
        else false end

  union all
  -- I11: the cash booked for a statement day = its payments (released duplicates included). The cash_in entries'
  -- 5120 postings through the servicer's 5120 accounts; each payment's line by its id.
  select 'cash_in_statement', 'violation', 'bank_statement', coalesce(ci.statement_id, pd.statement_id), null,
         (coalesce(ci.total, 0) - coalesce(pd.total, 0))::bigint, null, null,
         jsonb_build_object('date', coalesce(ci.d, pd.d), 'cash_in_minor', coalesce(ci.total, 0)::text,
                            'payments_minor', coalesce(pd.total, 0)::text)
  from (select e.source_id::uuid as statement_id, e.effective_date as d, sum(lp.amount_minor) as total
        from public.ledger_account la
        cross join lateral (select q.entry_id, q.amount_minor from public.ledger_posting q
                            where q.ledger_account_id = la.id offset 0) lp
        cross join lateral (select q.organization_id, q.entry_type, q.source_id, q.effective_date
                            from public.ledger_entry q where q.id = lp.entry_id offset 0) e
        where la.organization_id = p_organization_id and la.book = 'client_money_cash'
          and e.organization_id = p_organization_id and e.entry_type = 'cash_in'
        group by e.source_id, e.effective_date) ci
  full join (select t.statement_id, p.booking_date as d, sum(p.amount_minor) as total
             from pos p
             cross join lateral (select q.statement_id from public.bank_transaction q
                                 where q.id = p.bank_transaction_id offset 0) t
             group by t.statement_id, p.booking_date) pd
    on pd.statement_id = ci.statement_id and pd.d = ci.d
  where coalesce(ci.total, 0) <> coalesce(pd.total, 0)

  union all
  -- I4, I5 and design §7: each payment's position against its status.
  select 'payment_position', 'violation', 'payment', c.id, c.currency, c.unallocated, null, v_today - c.booking_date,
         jsonb_build_object('status', c.status, 'allocated_minor', c.allocated::text,
                            'unallocated_minor', c.unallocated::text, 'returned_minor', c.returned::text,
                            'pending_refund_minor', c.pending::text)
  from pos c
  where c.unallocated < 0 or c.allocated < 0 or c.returned < 0
     or (c.status = 'allocated' and not (c.allocated > 0 and c.unallocated = 0))
     or (c.status = 'partially_allocated' and not (c.allocated > 0 and c.unallocated > 0))
     or (c.status in ('unmatched', 'matched') and not (c.allocated = 0 and c.unallocated > 0))
     or (c.status = 'unmatched' and c.account_id is not null)
     or (c.status = 'refunded' and not (c.allocated = 0 and c.unallocated = 0 and c.returned = c.amount_minor))
     or (c.status = 'returned' and not (c.allocated = 0 and c.unallocated = 0))
     or ((c.status = 'refund_pending') <> (c.pending_n > 0))
     or c.pending > c.unallocated

  union all
  -- the net allocated per (payment, file) is never negative
  select 'payment_negative_allocation', 'violation', 'payment', x.payment_id, null, x.total::bigint, null, null,
         jsonb_build_object('account_id', x.account_id)
  from (select c.id as payment_id, c.entry_account_id as account_id, sum(c.posted) as total
        from pe c where c.entry_type = 'allocation'
        group by c.id, c.entry_account_id) x
  where x.total < 0

  union all
  -- I6: no receivable a payment (or a credit note, or a payment made to the client) lowered is below zero now; no item
  -- below zero as a whole once such an entry touched it.
  select 'receivable_negative', 'violation', 'claim_item', x.claim_item_id, x.currency, x.balance::bigint, null, null,
         jsonb_build_object('component', x.component)
  from (select r.claim_item_id, r.component, r.currency, sum(r.balance) as balance
        from recv r where r.lowered
        group by r.claim_item_id, r.component, r.currency) x
  where x.balance < 0
  union all
  select 'item_negative', 'violation', 'claim_item', y.claim_item_id, y.currency, y.balance::bigint, null, null,
         '{}'::jsonb
  from (select r.claim_item_id, r.currency, sum(r.balance) as balance
        from (select r.claim_item_id, r.currency, r.balance,
                     bool_or(r.lowered_item) over (partition by r.claim_item_id) as touched
              from recv r where r.claim_item_id is not null) r
        where r.touched
        group by r.claim_item_id, r.currency) y
  where y.balance < 0

  union all
  -- The owner-claim mirror (M2a risk #5): per portfolio, component and currency, 3100 = −Σ1100.
  select 'owner_claim_mirror', 'violation', 'portfolio', x.portfolio_id, x.currency, x.total::bigint, null, null,
         jsonb_build_object('component', x.component)
  from (select z.portfolio_id, z.component, z.currency, sum(z.balance) as total
        from (select r.portfolio_id, r.component, r.currency, r.balance from recv r
              union all
              select la.portfolio_id, la.component, la.currency, s.total
              from public.ledger_account la
              cross join lateral (select sum(q.amount_minor) as total
                                  from (select q.amount_minor from public.ledger_posting q
                                        where q.ledger_account_id = la.id offset 0) q) s
              where la.organization_id = p_organization_id and la.book = 'owner_claim' and s.total is not null) z
        group by z.portfolio_id, z.component, z.currency) x
  where x.total <> 0

  union all
  -- R124-6: one receipt number per payment on a file and a current version about its file (void once returned). A
  -- payment changed in the last hour may still be in the receipts queue. (Each payment's receipts by its key.)
  select y.code, 'violation', 'payment', y.id, null, null, null, v_today - y.booking_date,
         jsonb_build_object('status', y.status)
  from (select c.id, c.booking_date, c.status,
               case when r.v is null and c.status <> 'returned' then 'receipt_missing'
                    when r.numbers > 1 then 'receipt_numbers'
                    when c.status = 'returned' and r.v is not null and cur.kind <> 'void' then 'receipt_not_void'
                    when c.status <> 'returned' and r.v is not null
                         and (cur.kind = 'void' or cur.account_id is distinct from c.account_id) then 'receipt_stale'
               end as code
        from pos c
        cross join lateral (select count(distinct x.number) as numbers, max(x.version) as v
                            from (select x.number, x.version, x.organization_id from public.receipt x
                                  where x.payment_id = c.id offset 0) x
                            where x.organization_id = p_organization_id) r
        left join lateral (select x.kind, x.account_id from public.receipt x
                           where x.payment_id = c.id and x.version = r.v offset 0) cur on true
        where c.account_id is not null and c.updated_at < now() - interval '1 hour'
          and not (c.status in ('matched', 'partially_allocated') and c.review_reason is null)) y
  where y.code is not null

  union all
  -- R124-5: one notification per entry that moves what a client is owed, one per payment held for a file, one per
  -- return of a payment on a file. (The payments' entries from the payments, each notification by its key.)
  select 'notification_missing', 'violation', 'ledger_entry', e.id, null, null, null, null,
         jsonb_build_object('entry_type', e.entry_type, 'payment_id', e.payment_id)
  from pos c
  cross join lateral (select q.id, q.organization_id, q.entry_type, q.payment_id, q.reverses_entry_id
                      from public.ledger_entry q where q.payment_id = c.id offset 0) e
  left join lateral (select q.entry_type from public.ledger_entry q where q.id = e.reverses_entry_id offset 0) t on true
  where e.organization_id = p_organization_id
    and (e.entry_type in ('allocation', 'forward') or (e.entry_type = 'reversal' and t.entry_type in ('allocation', 'forward')))
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = e.id offset 0)
  union all
  select 'notification_missing', 'violation', 'payment', c.id, null, null, null, null,
         jsonb_build_object('kind', 'payment_held')
  from pos c
  where c.review_reason = 'hold_blocks_allocation' and c.account_id is not null
    and not exists (select 1 from public.client_notification n
                    where n.payment_id = c.id and n.account_id = c.account_id and n.kind = 'payment_held' offset 0)
  union all
  select 'notification_missing', 'violation', 'payment', c.id, null, null, null, null,
         jsonb_build_object('kind', 'payment_returned')
  from pos c
  cross join lateral (select l.organization_id, l.kind, l.cash_entry_id from public.bank_debit_link l
                      where l.payment_id = c.id offset 0) l   -- (a link's payment is its servicer's: its foreign key)
  where l.organization_id = p_organization_id and l.kind = 'return' and c.account_id is not null
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = l.cash_entry_id offset 0)

  union all
  -- Statements (I9): a camt.053 statement whose opening is not the previous closing (« relevé manquant »), and each
  -- bank account's balance at its last statement against the ledger cash plus the lines not booked.
  select 'statement_gap', 'alert', 'bank_statement', x.id, null, (x.opening_booked_minor - x.prev_closing)::bigint,
         null, null,
         jsonb_build_object('bank_account_id', x.bank_account_id, 'from_date', x.from_date, 'previous_to_date', x.prev_to)
  from (select s.id, s.bank_account_id, s.from_date, s.opening_booked_minor,
               lag(s.closing_booked_minor) over w as prev_closing, lag(s.to_date) over w as prev_to
        from public.bank_statement s
        where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
        window w as (partition by s.bank_account_id order by s.from_date, s.to_date, s.finished_at)) x
  where x.prev_closing is not null and x.prev_to < x.from_date and x.opening_booked_minor <> x.prev_closing
  union all
  select 'bank_balance_gap', 'alert', 'bank_account', z.bank_account_id, z.currency,
         (z.closing - z.cash - z.unposted)::bigint, null, null,
         jsonb_build_object('as_of', z.to_date, 'closing_minor', z.closing::text, 'cash_minor', z.cash::text,
                            'unposted_minor', z.unposted::text, 'unposted_lines', z.unposted_lines)
  from (select l.bank_account_id, l.currency, l.to_date, l.closing_booked_minor as closing,
               coalesce((select sum(lp.amount_minor)
                         from (select a.id from public.ledger_account a
                               where a.bank_account_id = l.bank_account_id and a.book = 'client_money_cash' offset 0) la
                         cross join lateral (select q.amount_minor from public.ledger_posting q
                                             where q.ledger_account_id = la.id and q.effective_date <= l.to_date
                                             offset 0) lp), 0) as cash,
               u.minor as unposted, u.lines as unposted_lines
        from (select distinct on (s.bank_account_id) s.bank_account_id, s.currency, s.to_date, s.closing_booked_minor
              from public.bank_statement s
              where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
              order by s.bank_account_id, s.to_date desc, s.finished_at desc) l
        cross join lateral private.bank_unposted(l.bank_account_id, l.to_date) u) z
  where z.closing - z.cash - z.unposted <> 0

  union all
  -- servicer_shortfall (§15, P0; review fix): the servicer owes the dedicated account more than the top-ups ordered
  -- cover. M2c-7f-1 (H2, plan D7): the amount is private.top_up_needed — the hourly order's and the shortfall log's own
  -- formula, 4679 + the sweeps in flight − the top-ups in flight —, one keyed call per currency of the servicer's 4679
  -- accounts; its details give the three parts (before, the sweeps in flight were left out: with one in flight the
  -- alert said less than the hourly job orders, or nothing while 4679 was in credit by less than the sweep).
  select 'servicer_shortfall', 'alert', 'servicer', null, s.currency, s.need, null, null,
         jsonb_build_object('due_to_servicer_minor', s.owed::text, 'top_ups_ordered_minor', s.tops::text,
                            'sweeps_in_flight_minor', s.sweeps::text)
  from (select c.currency, coalesce(o.owed, 0) as owed, private.top_up_needed(p_organization_id, c.currency) as need,
               coalesce((select sum(x.amount_minor) from public.bank_transfer x
                         where x.organization_id = p_organization_id and x.currency = c.currency
                           and x.kind = 'top_up' and x.status in ('ordered', 'in_file')), 0) as tops,
               coalesce((select sum(x.amount_minor) from public.bank_transfer x
                         where x.organization_id = p_organization_id and x.currency = c.currency
                           and x.kind = 'sweep' and x.status in ('ordered', 'in_file')), 0) as sweeps
        from (select distinct la.currency from public.ledger_account la
              where la.organization_id = p_organization_id and la.book = 'due_to_servicer') c
        left join (select a.currency, sum(a.total) as owed from bal a where a.book = 'due_to_servicer'
                   group by a.currency) o on o.currency = c.currency) s
  where s.need > 0

  union all
  -- Ageing (alerts, one row per code with the oldest and up to 50 payments or lines).
  select x.code, 'alert', 'servicer', null, x.currency, x.total, x.n, x.oldest, jsonb_build_object('ids', x.ids)
  from (select 'unmatched_ageing' as code, c.currency, sum(c.unallocated)::bigint as total, count(*)::integer as n,
               max(v_today - c.booking_date) as oldest,
               (array_agg(c.id order by c.booking_date, c.id))[1:50] as ids
        from pos c
        where c.status = 'unmatched' and v_today - c.booking_date >= 20
        group by c.currency
        union all
        select 'unallocated_ageing', c.currency, sum(c.unallocated)::bigint, count(*)::integer,
               max(v_today - c.booking_date), (array_agg(c.id order by c.booking_date, c.id))[1:50]
        from pos c
        where c.account_id is not null and c.unallocated > 0 and c.status in ('matched', 'partially_allocated')
          and c.review_reason is not null and v_today - c.booking_date >= 20
        group by c.currency
        union all
        select 'refund_pending_ageing', q.currency, sum(q.amount_minor)::bigint, count(*)::integer,
               max(v_today - (q.requested_at at time zone 'Europe/Paris')::date),
               (array_agg(q.payment_id order by q.requested_at, q.id))[1:50]
        from public.refund_request q
        where q.organization_id = p_organization_id and q.status = 'requested'
          and v_today - (q.requested_at at time zone 'Europe/Paris')::date >= 5
        group by q.currency
        union all
        -- returns, our refunds, credits undoing a debit (released duplicates of those kinds) not linked — they can
        -- only be booked, never explained — and other debits of a pending refund's amount on its bank account: the
        -- servicer's lines of those kinds, three days old at least, by the kinds' partial indexes; each test by key
        select 'debit_unclassified', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from (select q.id, q.kind, q.direction, q.currency, q.amount_minor, q.booking_date, q.bank_account_id,
                     q.organization_id
              from public.bank_transaction q
              where q.organization_id = p_organization_id and q.booking_date <= v_today - 3
                and q.kind in ('return', 'refund_out', 'suspected_duplicate')
              union all
              select q.id, q.kind, q.direction, q.currency, q.amount_minor, q.booking_date, q.bank_account_id,
                     q.organization_id
              from public.bank_transaction q
              where q.organization_id = p_organization_id and q.booking_date <= v_today - 3
                and q.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
              union all
              select q.id, q.kind, q.direction, q.currency, q.amount_minor, q.booking_date, q.bank_account_id,
                     q.organization_id
              from public.bank_transaction q
              where q.organization_id = p_organization_id and q.booking_date <= v_today - 3
                and q.kind = 'other_debit') t
        left join lateral (select r.released_kind from public.bank_duplicate_resolution r
                           where r.bank_transaction_id = t.id offset 0) r on true
        where (t.kind in ('return', 'refund_out', 'transfer_out', 'own_transfer_in', 'client_transfer_in')
               or (t.kind = 'suspected_duplicate'
                   and r.released_kind in ('return', 'refund_out', 'transfer_out', 'own_transfer_in',
                                           'client_transfer_in'))
               or (t.kind = 'other_debit' and t.direction = 'debit'
                   and exists (select 1 from (select q.organization_id, q.status from public.refund_request q
                                              where q.bank_account_id = t.bank_account_id
                                                and q.amount_minor = t.amount_minor offset 0) q
                               where q.organization_id = t.organization_id and q.status = 'requested' offset 0)))
          and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
          and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
          and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id offset 0)
        group by t.currency
        union all
        select 'duplicate_unresolved', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from public.bank_transaction t
        where t.organization_id = p_organization_id and t.kind = 'suspected_duplicate'
          and t.booking_date <= v_today - 3
          and not exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id offset 0)
        group by t.currency
        union all
        select 'direct_payment_waiting', d.currency, sum(d.amount_minor)::bigint, count(*)::integer,
               max(v_today - (d.requested_at at time zone 'Europe/Paris')::date),
               (array_agg(d.id order by d.requested_at, d.id))[1:50]
        from public.direct_payment d
        where d.organization_id = p_organization_id and d.status = 'requested' and d.requested_at < now() - interval '1 hour'
        group by d.currency) x;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select v_run, p_organization_id, c.code, c.severity, c.subject_type, c.subject_id, c.currency, c.amount_minor, c.count,
         c.oldest_days, coalesce(c.details, '{}')
  from pg_temp._chk c;
  -- M2c-4: the runs' checks (I15–I18, I21, the deadline alerts, the reference data), then the counts of everything
  perform private.run_remittance_checks(v_run, p_organization_id);
  select coalesce(jsonb_object_agg(x.code, x.n), '{}') into v_summary
  from (select c.code, count(*) as n from public.payment_check_result c where c.run_id = v_run group by c.code) x;
  select count(*) filter (where c.severity = 'violation'), count(*) filter (where c.severity = 'alert')
  into v_violations, v_alerts from public.payment_check_result c where c.run_id = v_run;
  update public.payment_check_run
  set finished_at = clock_timestamp(), violations = v_violations, alerts = v_alerts, summary = v_summary
  where id = v_run;
  return jsonb_build_object('run_id', v_run, 'violations', v_violations, 'alerts', v_alerts, 'by_code', v_summary);
end;
$$;


------------------------------------------------------------------------------------------
-- H1: private.run_transfer_checks
------------------------------------------------------------------------------------------

-- private.run_transfer_checks, redefined from 20261121120000_switch_on_prerequisites_5.sql (line 946; same signature,
-- SECURITY DEFINER, its SET clauses, search_path '' and its grants restated below). M2c-7f-1, H1: transfer_file_failed's
-- probe of a failed file's transfers still ordered reads the file's items, each transfer by its key in a fence (the
-- close-out reads test: under forgotten statistics the join read 2,433 transfers of every servicer for the servicer's
-- 40). (Review round 1, CC-1) transfer_already_debited's sweeps and payouts or refunds in flight read by the
-- servicer's key, their paying account checked on the row (before, per paying account by its key, which a planner that
-- sees few paying accounts read as every servicer's transfers in flight); and every « its paying account is a
-- client_funds one » check a correlated probe by the account's key (OFFSET 0: never a semi-join a generic plan drives
-- from every servicer's client_funds accounts, each one's transfers then read by debtor_bank_account_id — the db job's
-- order, 72 such index entries for the servicer's 5 transfers). Every other statement is unchanged.
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
                    and b.purpose = 'client_funds' offset 0)
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
      -- (M2c-7f-1, H1) the file's items, each transfer by its key (as the downloaded-file check above): joined, a
      -- planner that knows few ordered transfers read every servicer's (bank_transfer_to_file_idx) to find the files
      and exists (select 1 from public.transfer_file_item i
                  cross join lateral (select t.status from public.bank_transfer t where t.id = i.transfer_id
                                      offset 0) t
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
                    and b.purpose = 'client_funds' offset 0)
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
    -- (M2c-7f-1 review round 1, CC-1) the servicer's sweeps in flight by its key (bank_transfer_servicer_flight_idx's
    -- predicate stated, fenced), each one's paying account checked on the row (bank_transfer_debtor_fk: a transfer's
    -- debtor account is of its servicer); before, per paying account by debtor_bank_account_id, which a planner that
    -- sees few paying accounts read as every servicer's sweeps in flight, once per account
    from (select q.* from public.bank_transfer q
          where q.organization_id = p_organization_id and q.kind = 'sweep' and q.status in ('ordered', 'in_file')
          offset 0) t
    where exists (select 1 from public.bank_account b where b.id = t.debtor_bank_account_id
                    and b.purpose = 'client_funds' offset 0)
      and private.sweep_after_debited_cancelled(t.id)
    union all
    -- M2c-6b-3a (M): a payout or a refund in flight held for a cancelled one of its client or payment debited late (not
    -- alerted above already)
    select 'transfer_already_debited', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'status', t.status, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id, 'reason', s.reason)
    -- (M2c-7f-1 review round 1, CC-1) the servicer's payouts and refunds in flight by its key (fenced), each one's
    -- paying account checked on the row, as the sweeps above
    from (select q.* from public.bank_transfer q
          where q.organization_id = p_organization_id and q.status in ('ordered', 'in_file')
            and q.kind in ('payout', 'refund') offset 0) t
    cross join lateral (select private.transfer_sibling_debited_late(t.id) as reason) s
    where exists (select 1 from public.bank_account b where b.id = t.debtor_bank_account_id
                    and b.purpose = 'client_funds' offset 0)
      and s.reason is not null
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
      -- PR #40's CI round: the refund requests whose transfer's chain holds t, read from t forward by key
      -- (private.transfer_reissues: y is in it exactly when t is in private.transfer_chain(y)) — no longer every
      -- refund the servicer has waiting, each with its transfer and its chain, once per cancelled refund debited late
      and not exists (select 1
                      from private.transfer_reissues(t.id) c
                      cross join lateral (select q.organization_id, q.status from public.refund_request q
                                          where q.transfer_id = c.transfer_id offset 0) q
                      cross join lateral (select y.status from public.bank_transfer y where y.id = c.transfer_id offset 0) y
                      where t.kind = 'refund' and q.organization_id = p_organization_id and q.status = 'requested'
                        and y.status in ('ordered', 'in_file'))
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
                    and b.purpose = 'client_funds' offset 0)
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
      -- M2c-6b-2a: the transfer's own payout (an unplanned payout's return is the branch below) — M2c-6b-3a-2 (F): a
      -- late predecessor's, its payout booking's entry
      and (bt.entry_id = e.reverses_entry_id
           or exists (select 1 from public.bank_line_booking k
                      where k.entry_id = e.reverses_entry_id and k.kind = 'payout' and k.transfer_id = bt.id))
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

-- private.transfers_in_flight, redefined from 20261115090000_transfers_files.sql (line 1357; same signature and
-- settings — not SECURITY DEFINER, search_path '', enable_seqscan off — and its grants restated below). M2c-7f-1 review
-- round 1 (CC-1): the nightly's `flight` (private.run_transfer_checks, once per paying account) and
-- private.transfer_cash_position read an account's transfers in a file by debtor_bank_account_id and status 'in_file',
-- a filter that implies bank_transfer_debtor_idx's predicate: under statistics that see few paying accounts the planner
-- read bank_transfer_org_idx by its status column alone (every servicer's transfers in a file, once per account). Then
-- (round 1) the account's servicer's transfers in a file by its key (bank_transfer_org_idx's two first columns, fenced),
-- the account checked on the row. CI round (PR #52), round 2: that read the servicer's every transfer in a file once
-- per paying account (« Virements »' cash position, « Générer le fichier », « Télécharger » and the nightly's `flight`
-- each per account: 281 rows for an account with none in a file, 2,781 beside a run's 2,500 payouts in a file of
-- another account). Now the account's own transfers in a file by both bounds of bank_transfer_debtor_idx (the paying
-- account, then the status: above), fenced — never its ordered ones, never another account's (CC-1's kinds test and
-- the round's reads test bound both). The rows are the same (bank_transfer_debtor_fk: a transfer's debtor account is
-- of its servicer).
create or replace function private.transfers_in_flight(p_bank_account_id uuid)
returns table (transfer_id uuid, amount_minor bigint, execution_date date)
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  with tr as materialized (
    select t.id, t.amount_minor, t.end_to_end_id, t.transfer_file_id, i.pmt_inf_id, i.execution_date
    from (select q.id, q.amount_minor, q.end_to_end_id, q.transfer_file_id
          from public.bank_transfer q
          where q.debtor_bank_account_id = p_bank_account_id and q.status = 'in_file' offset 0) t
    cross join lateral (select f.status from public.transfer_file f where f.id = t.transfer_file_id offset 0) f
    cross join lateral (select x.pmt_inf_id, x.execution_date from public.transfer_file_item x
                        where x.file_id = t.transfer_file_id and x.transfer_id = t.id offset 0) i
    where f.status in ('downloaded', 'sent')),
  batch as materialized (
    select p.transfer_file_id, p.pmt_inf_id
    from (select distinct tr.transfer_file_id, tr.pmt_inf_id from tr) p
    where private.pmt_inf_batch_seen(p.transfer_file_id, p.pmt_inf_id))
  select tr.id, tr.amount_minor, tr.execution_date from tr
  where not private.transfer_own_debit_seen(p_bank_account_id, tr.end_to_end_id)
    and not exists (select 1 from batch b where b.transfer_file_id = tr.transfer_file_id
                      and b.pmt_inf_id = tr.pmt_inf_id);
$$;
-- public.debit_queue, redefined from 20261130090000_label_references.sql (line 964; same signature and result, created
-- or replaced; SECURITY DEFINER, search_path '' and its grant restated below). M2c-7f-1 (H5; ADR-0014 « M2c-7e-2 review
-- fixes », round 1, CC-1): `set enable_seqscan = off`; every presence test of the review, link, booking, release and
-- resolution tables a correlated probe by the line's key (OFFSET 0: never a hashed anti-join), the held line's released
-- kind and the final select's review, link, release and resolution keyed laterals by the line's key. Under stale
-- statistics the earlier body read those tables whole by hash joins (260,196 index rows for 65,000 lines measured by
-- the 7e-2 review) and the servicer's every line per branch; the servicer's lines of each branch's kinds are now read
-- by H3's single-column partial indexes. The rows are the same.
create or replace function public.debit_queue(p_tab text default 'a-classer', p_offset integer default 0,
                                   p_limit integer default 20)
returns table (bank_transaction_id uuid, statement_id uuid, bank_account_id uuid, direction text, kind text,
               amount_minor text, currency char(3), booking_date date, age_days integer, counterparty_name text,
               counterparty_iban_end text, remittance_text text, end_to_end_id text, original_end_to_end_id text,
               return_reason text, review_reason text, candidates jsonb, decision text, decided_at timestamptz,
               decided_payment_id uuid, total bigint, held_kind text, payment_info_id text, unsplit_ours smallint,
               names_our_lot boolean, bookable_as text, reference_from_label text, label_transfer jsonb)
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
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
      and not exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id offset 0);
  elsif p_tab = 'frais' then
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.kind = 'other_debit'
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
      -- M2c-6b-1: a batch line of our files is one of our transfers (« À classer »), never a fee
      and not (t.end_to_end_id is null and coalesce(t.payment_info_id, '') ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
      and not (t.direction = 'debit'
               and exists (select 1 from public.refund_request q
                           where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
                             and q.organization_id = t.organization_id and q.status = 'requested' offset 0))
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
    left join lateral (select q.released_kind from public.bank_duplicate_resolution q
                       where q.bank_transaction_id = t.id offset 0) r on true
    where t.organization_id = any (v_orgs) and t.kind in ('return', 'refund_out', 'suspected_duplicate')
      and (t.kind <> 'suspected_duplicate' or r.released_kind in ('return', 'refund_out'))
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
    union all
    -- M2c: our transfers out, credits from our own account or from a client (released duplicates of those kinds
    -- too), not booked, explained or released as a relayed debtor payment yet; M2c-7e-2 (plan §7.3): and the credits
    -- held because their label cites one of our transfers (label_reference, as read or released so)
    -- (M2c-7f-1, H5) in two branches — the lines of these kinds (bank_transaction_own_kinds_org_idx), then the held
    -- duplicates released so (bank_transaction_debit_kinds_org_idx) — never one OR over both, which no kind's index
    -- serves (a line is of one kind: the same rows)
    select t.*, t.kind, null::text, null::jsonb
    from public.bank_transaction t
    where t.organization_id = any (v_orgs)
      and t.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in', 'label_reference')
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id offset 0)
    union all
    select t.*, r.released_kind, null::text, null::jsonb
    from public.bank_transaction t
    cross join lateral (select q.released_kind from public.bank_duplicate_resolution q
                        where q.bank_transaction_id = t.id offset 0) r
    where t.organization_id = any (v_orgs) and t.kind = 'suspected_duplicate'
      and r.released_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in', 'label_reference')
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id offset 0)
    union all
    -- M2c-6b-1: a batch line of our files (no end-to-end id, our PmtInfId) the debit job left to ops
    select t.*, t.kind, null::text, null::jsonb
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.direction = 'debit' and t.end_to_end_id is null
      and t.kind in ('other_debit', 'batch_unsplit') and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
    union all
    -- review round 7 (S2): a debit of an entry kept unsplit holding a detail of ours, not our batch line (listed above),
    -- the funds pass reviewed (it takes no link: it waits for ops' booking), by its partial index
    select t.*, t.kind, null::text, null::jsonb
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.unsplit_ours > 0 and t.direction = 'debit' and t.kind = 'batch_unsplit'
      and not (t.end_to_end_id is null and coalesce(t.payment_info_id, '') ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
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
            and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = o.id offset 0)
            and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = o.id offset 0)
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
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.refund_request q
                      where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
                        and q.organization_id = t.organization_id and q.status = 'requested' offset 0);
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
         -- M2c-6b-2c: what « Comptabiliser… » may book it as (the lines to classify and the fees only); M2c-7e-2:
         -- nothing on a credit held because its label cites one of our transfers (its exits are 7e-3's)
         case when coalesce(p_tab, 'a-classer') not in ('traites', 'doublons')
                   and coalesce(t.eff_kind, t.kind) <> 'label_reference'
              then private.transfer_line_bookable_as(t.id) end,
         -- M2c-7e-2 (plan §7.3): the reference the label cites (kept only for a transfer of the line's account) and
         -- that transfer — its kind, status, amount and its run's number and status — by key: the transfer by its
         -- unique end-to-end id, then its run
         t.reference_from_label,
         (select jsonb_build_object('transfer_id', x.id, 'kind', x.kind, 'status', x.status,
                                    'amount_minor', x.amount_minor::text, 'currency', x.currency,
                                    'end_to_end_id', x.end_to_end_id,
                                    'run_number', (select z.number from public.remittance_run z where z.id = x.run_id),
                                    'run_status', (select z.status from public.remittance_run z where z.id = x.run_id))
          from (select y.id, y.kind, y.status, y.amount_minor, y.currency, y.end_to_end_id, y.run_id,
                       y.organization_id
                from public.bank_transfer y
                where t.reference_from_label is not null and y.end_to_end_id = t.reference_from_label offset 0) x
          where x.organization_id = t.organization_id)
  from (select * from pg_temp._dq x
        order by (case when p_tab = 'traites' then x.created_at end) desc nulls last, x.booking_date, x.id
        offset v_offset limit v_limit) t
  -- (M2c-7f-1, H5) each by the listed line's key, in a fence: never a hash of the table
  left join lateral (select q.reason, q.candidates from public.bank_debit_review q
                     where q.bank_transaction_id = t.id offset 0) v on true
  left join lateral (select q.kind, q.decided_at, q.payment_id from public.bank_debit_link q
                     where q.bank_transaction_id = t.id offset 0) l on true
  left join lateral (select q.bank_transaction_id, q.decided_at from public.bank_own_credit_release q
                     where q.bank_transaction_id = t.id offset 0) c on true
  left join lateral (select q.decision, q.decided_at from public.bank_duplicate_resolution q
                     where q.bank_transaction_id = t.id offset 0) r on true
  order by (case when p_tab = 'traites' then t.created_at end) desc nulls last, t.booking_date, t.id;
end;
$$;
------------------------------------------------------------------------------------------
-- H6: the funds pass's reviews replaced by key
------------------------------------------------------------------------------------------

-- private.apply_bank_bookings, redefined from 20261129090000_top_ups.sql (line 1845; same signature and settings,
-- SECURITY DEFINER, search_path '' and its grants restated below). M2c-7f-1 (H6; ADR-0014 « M2c-7e-2 », Left open,
-- founder default « a keyed delete in 7f's hardening »): the delete reads `bank_transaction_id = any (array(…))` of the
-- job's temporary table instead of joining it. Nothing else changes.
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
         case when s.why in ('return_before_debit', 'unplanned_payout_return', 'return_debit_pending',
                             'top_up_cancelled_credit') then s.why
              else 'changed' end,
         case when s.why in ('return_before_debit', 'unplanned_payout_return', 'return_debit_pending',
                             'top_up_cancelled_credit') then null
              else s.why end
  from pg_temp._booking_skipped s
  on conflict (bank_transaction_id) do nothing;
  -- (M2c-7f-1, H6) the reviews replaced by the lines' keys (the pass's temporary table is never analysed: joined, a
  -- hash over the whole review table under stale statistics)
  delete from public.bank_debit_review v
  where v.bank_transaction_id = any (array(select r.bank_transaction_id from pg_temp._booking_review r));
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
-- H19: an in-flight run's overdue lines by the run's key alone
------------------------------------------------------------------------------------------

-- private.inflight_overdue_lines, redefined from 20261112090000_remittance_runs.sql (line 2320; same signature and
-- settings, SECURITY DEFINER, search_path '' and its grants restated below). M2c-7f-1 (H19; ADR-0014 « M2c-7a — CI round
-- (main) », Left open): the 7a CI round's form (20261123080000) — `not x.released` in the fenced filter implied
-- remittance_line_live_uq's predicate, and under the plant every live line was read once per run in flight (10,048 for
-- one run). The same rows.
create or replace function private.inflight_overdue_lines(p_organization_id uuid, p_today date)
returns table (run_id uuid, number text, client_organization_id uuid, currency char(3),
               requested_execution_date date, late_reason text, ledger_entry_id uuid, payment_id uuid,
               amount_minor bigint, deadline date, latest_execution_date date, out_of_horizon boolean)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with l as materialized (
    select r.id as run_id, r.number, r.client_organization_id, r.currency, r.requested_execution_date, r.late_reason,
           y.ledger_entry_id, y.payment_id, y.amount_minor, y.encaissement_date, y.deadline, y.latest_execution_date,
           y.unmeetable
    from public.remittance_run r
    -- (M2c-7f-1, H19) the run's lines by the run's key alone inside the fence (remittance_line_pkey's prefix: no
    -- partial index's predicate is implied there), the conditions outside it
    cross join lateral (select x.ledger_entry_id, x.payment_id, x.amount_minor, x.encaissement_date, x.deadline,
                               x.latest_execution_date, x.unmeetable
                        from (select q.ledger_entry_id, q.payment_id, q.amount_minor, q.encaissement_date, q.deadline,
                                     q.latest_execution_date, q.unmeetable, q.released
                              from public.remittance_line q where q.run_id = r.id offset 0) x
                        where not x.released and x.amount_minor > 0 and x.latest_execution_date is not null
                          and (x.unmeetable or x.latest_execution_date < p_today)) y
    where r.organization_id = p_organization_id and r.status in ('approved', 'sent')
      and not exists (select 1 from public.bank_transfer t where t.id = r.transfer_id and t.status = 'booked')),
  m as materialized (   -- one month once per distinct E, whatever the estimates (review perf#0, round 2)
    select k.e_date, d.*
    from (select distinct l.encaissement_date as e_date from l where l.unmeetable and l.encaissement_date is not null) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, 30) d),
  c as (
    select l.*, case when l.unmeetable then m.deadline else l.deadline end as c_deadline,
           case when l.unmeetable then m.latest_execution_date else l.latest_execution_date end as c_latest,
           coalesce(l.unmeetable and (m.out_of_horizon or m.e_date is null), false) as c_out
    from l left join m on l.unmeetable and m.e_date = l.encaissement_date)
  select c.run_id, c.number, c.client_organization_id, c.currency, c.requested_execution_date, c.late_reason,
         c.ledger_entry_id, c.payment_id, c.amount_minor, c.c_deadline, c.c_latest, c.c_out
  from c where c.c_out or c.c_latest < p_today;
$$;


------------------------------------------------------------------------------------------
-- H9: ops' top-up serialised with the hourly order
------------------------------------------------------------------------------------------

-- public.request_top_up, redefined from 20261111090000_remittance_funds.sql (line 1548; same signature and settings —
-- its lock_timeout 2s already —, SECURITY DEFINER, search_path '' and its grants restated below). M2c-7f-1 (H9;
-- ADR-0014 « M2c-7e-1 », Left open, MONEY-BANK-3): it takes private.remittance_command_locks(…, true) after locking its
-- two accounts. « Comptes bancaires » words the 55P03.
create or replace function public.request_top_up(p_idempotency_key text, p_own_bank_account_id uuid,
                                                 p_client_funds_bank_account_id uuid, p_amount_minor text,
                                                 p_reason text, p_requested_execution_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  o public.bank_account;
  c public.bank_account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_date date := coalesce(p_requested_execution_date, private.paris_today());
  v_request jsonb;
  v_result jsonb;
  v_amount bigint;
  v_e2e text;
  v_id uuid;
  v_name text;
begin
  select * into o from public.bank_account where id = p_own_bank_account_id;
  if not found or not private.has_role(o.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('own_bank_account_id', p_own_bank_account_id,
                                  'client_funds_bank_account_id', p_client_funds_bank_account_id,
                                  'amount_minor', p_amount_minor, 'reason', v_reason,
                                  'requested_execution_date', p_requested_execution_date);
  v_result := private.command_replay('request_top_up', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p_amount_minor is null or p_amount_minor !~ '^[0-9]{1,16}$' or p_amount_minor::bigint <= 0 then
    raise exception 'invalid amount' using errcode = 'check_violation';
  end if;
  v_amount := p_amount_minor::bigint;
  -- Both accounts locked (in id order, like every writer) before they are checked: a concurrent close of either waits
  -- for this order (and then sees it in flight), or this order waits for the close and reads it closed (review fix:
  -- the own account was read unlocked, so a close could commit with a top-up in flight).
  perform 1 from public.bank_account b
  where b.id in (p_own_bank_account_id, p_client_funds_bank_account_id)
  order by b.id for share;
  -- (M2c-7f-1, H9: MONEY-BANK-3) the allocation and remit locks, as private.order_due_top_up takes them after the
  -- accounts (the same order): ops' order and the hourly job's read-then-order are serialised — while the job holds
  -- them, this order waits its 2 s and is refused 55P03 (allocation_busy), retried it is recorded beside the job's
  -- top-up; while this order is open, the job waits and then reads it (top_up_needed nets it)
  perform private.remittance_command_locks(o.organization_id, true);
  select * into o from public.bank_account where id = p_own_bank_account_id;
  select * into c from public.bank_account where id = p_client_funds_bank_account_id;
  if not found or c.organization_id <> o.organization_id or c.purpose <> 'client_funds' or c.status <> 'active'
     or o.purpose <> 'own' or o.status <> 'active' or c.currency <> o.currency then
    raise exception 'top-up: from an active own account to an active client_funds account in the same currency'
      using errcode = 'check_violation';
  end if;
  if v_date < private.paris_today() then
    raise exception 'the requested execution date is in the past' using errcode = 'check_violation';
  end if;
  select left(btrim(legal_name), 70) into v_name from public.organization where id = o.organization_id;
  v_e2e := 'TOP' || upper(substr(md5(gen_random_uuid()::text), 1, 12));
  insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id, creditor_bank_account_id, currency,
                                    amount_minor, payee_name, payee_iban, payee_bic, end_to_end_id, remittance_info,
                                    requested_execution_date, reason, ordered_by)
  values (o.organization_id, 'top_up', o.id, c.id, c.currency, v_amount, v_name, c.iban, c.bic, v_e2e,
          'APPROVISIONNEMENT COMPTE DEDIE ' || v_e2e, v_date, v_reason, auth.uid())
  returning id into v_id;
  v_result := jsonb_build_object('transfer_id', v_id, 'end_to_end_id', v_e2e, 'amount_minor', v_amount::text,
                                 'currency', c.currency, 'payee_name', v_name, 'payee_iban', c.iban,
                                 'debtor_iban', o.iban, 'requested_execution_date', v_date);
  perform private.command_record('request_top_up', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


------------------------------------------------------------------------------------------
-- H10: an own-account file refused by the switch-on two-step cancellation
------------------------------------------------------------------------------------------

-- public.request_transfer_file_cancellation and public.confirm_transfer_file_cancellation, redefined from
-- 20261116090000_debit_bookings.sql (lines 4813 and 4883; same signatures and settings, SECURITY DEFINER, search_path ''
-- and their grants restated below). M2c-7f-1 (H10): with the switch on, an own-account file is refused as
-- public.cancel_transfer_file refuses it (20261129090000 line 839), after the switch's own refusal (033 unchanged: with
-- it off both commands are refused first). H7: both run with enable_seqscan off, and the confirmation's update of the
-- returned transfers reads the file's items (each transfer by its key). Nothing else changes.
create or replace function public.request_transfer_file_cancellation(p_idempotency_key text, p_file_id uuid,
                                                                     p_expected_version integer, p_reason text,
                                                                     p_attestation text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set enable_seqscan = off
as $$
declare
  f public.transfer_file;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('file_id', p_file_id, 'expected_version', p_expected_version,
                                        'reason', btrim(coalesce(p_reason, '')), 'attestation', p_attestation);
  v_result jsonb;
  v_evidence jsonb;
  v_id uuid;
begin
  select * into f from public.transfer_file where id = p_file_id;
  if not found or not private.has_role(f.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('request_transfer_file_cancellation', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  -- review round 5 (fail-closed): off until M2c-6b books the debits from the statements
  if not private.switch_on('downloaded_file_cancellation') then
    raise exception 'transfer file refused: bank_booking_required' using errcode = 'check_violation',
      hint = 'L''annulation d''un fichier téléchargé n''est pas encore disponible dans Collectoo. Gardez le fichier tel quel ; ses virements restent en cours jusqu''à ce que leurs débits soient comptabilisés depuis le relevé, à leur arrivée (de même, ensuite, le retour d''un virement que la banque du bénéficiaire renvoie). Un virement que la banque refuse avant son exécution, ou un fichier jamais déposé, n''apparaît sur aucun relevé : il reste « en cours » jusqu''à ce que l''annulation après téléchargement soit disponible. Vérifiez le relevé, voyez avec la banque et prévenez le support.';
  end if;
  -- (M2c-7f-1, H10; ADR-0014 « M2c-7e-1 », Left open) an own-account file (its debtor the servicer's own account:
  -- only top-ups) is cancelled by « Annuler le fichier » (public.cancel_top_up_file), never here — as
  -- public.cancel_transfer_file refuses it: transfer_file_release re-queues payouts and reads runs, which such a file
  -- has none of
  if exists (select 1 from public.bank_account b where b.id = f.debtor_bank_account_id and b.purpose = 'own') then
    raise exception 'transfer file refused: not_a_payout_file' using errcode = 'check_violation',
      hint = 'Fichier d''approvisionnement du compte propre : annulez-le par « Annuler le fichier ».';
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p_attestation is null or p_attestation not in ('not_uploaded', 'rejected_by_bank') then
    raise exception 'transfer file refused: attestation_required' using errcode = 'check_violation';
  end if;
  perform private.transfer_file_lock_runs(f.id);
  perform private.remittance_command_locks(f.organization_id, true);
  select * into f from public.transfer_file where id = p_file_id for update;
  if p_expected_version is distinct from f.version then
    raise exception 'transfer file refused: version_changed' using errcode = 'check_violation';
  end if;
  if f.status in ('pending', 'generated') then
    raise exception 'transfer file refused: not_downloaded' using errcode = 'check_violation';
  elsif f.status not in ('downloaded', 'sent') then
    raise exception 'transfer file refused: not_live' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.transfer_cancellation_request q
             where q.file_id = f.id and q.transfer_id is null and q.file_version = f.version
               and q.confirmed_at is null) then
    raise exception 'transfer file refused: already_requested' using errcode = 'check_violation';
  end if;
  v_evidence := private.transfer_cancel_evidence(f.id, null);
  if v_evidence ->> 'refusal' is not null then
    raise exception 'transfer file refused: %', v_evidence ->> 'refusal' using errcode = 'check_violation',
      detail = v_evidence::text;
  end if;
  insert into public.transfer_cancellation_request (organization_id, kind, file_id, file_version, attestation, reason,
                                                    evidence, requested_by)
  values (f.organization_id, 'file', f.id, f.version, p_attestation, v_reason, v_evidence, auth.uid())
  returning id into v_id;
  v_result := jsonb_build_object('request_id', v_id, 'file_id', f.id, 'number', f.number, 'status', 'requested',
                                 'evidence', v_evidence);
  perform private.command_record('request_transfer_file_cancellation', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

create or replace function public.confirm_transfer_file_cancellation(p_idempotency_key text, p_file_id uuid,
                                                                     p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set enable_seqscan = off
as $$
declare
  f public.transfer_file;
  q public.transfer_cancellation_request;
  v_request jsonb := jsonb_build_object('file_id', p_file_id, 'expected_version', p_expected_version);
  v_result jsonb;
  v_evidence jsonb;
  v_status text;
  v_n integer;
  v_returned integer;
begin
  select * into f from public.transfer_file where id = p_file_id;
  if not found or not private.has_role(f.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('confirm_transfer_file_cancellation', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  -- review round 5 (fail-closed): off until M2c-6b — a request opened while it was on is not confirmed
  if not private.switch_on('downloaded_file_cancellation') then
    raise exception 'transfer file refused: bank_booking_required' using errcode = 'check_violation',
      hint = 'L''annulation d''un fichier téléchargé n''est pas encore disponible dans Collectoo : la demande en cours ne peut pas être confirmée. Gardez le fichier tel quel ; ses virements restent en cours jusqu''à ce que leurs débits soient comptabilisés depuis le relevé, à leur arrivée (de même, ensuite, le retour d''un virement que la banque du bénéficiaire renvoie). Un virement que la banque refuse avant son exécution, ou un fichier jamais déposé, n''apparaît sur aucun relevé : il reste « en cours » jusqu''à ce que l''annulation après téléchargement soit disponible. Vérifiez le relevé, voyez avec la banque et prévenez le support.';
  end if;
  -- (M2c-7f-1, H10; ADR-0014 « M2c-7e-1 », Left open) an own-account file (its debtor the servicer's own account:
  -- only top-ups) is cancelled by « Annuler le fichier » (public.cancel_top_up_file), never here — as
  -- public.cancel_transfer_file refuses it: transfer_file_release re-queues payouts and reads runs, which such a file
  -- has none of
  if exists (select 1 from public.bank_account b where b.id = f.debtor_bank_account_id and b.purpose = 'own') then
    raise exception 'transfer file refused: not_a_payout_file' using errcode = 'check_violation',
      hint = 'Fichier d''approvisionnement du compte propre : annulez-le par « Annuler le fichier ».';
  end if;
  perform private.transfer_file_lock_runs(f.id);
  perform private.remittance_command_locks(f.organization_id, true);
  select * into f from public.transfer_file where id = p_file_id for update;
  if p_expected_version is distinct from f.version then
    raise exception 'transfer file refused: version_changed' using errcode = 'check_violation';
  end if;
  if f.status not in ('downloaded', 'sent') then
    raise exception 'transfer file refused: not_live' using errcode = 'check_violation';
  end if;
  select * into q from public.transfer_cancellation_request x
  where x.file_id = f.id and x.transfer_id is null and x.file_version = f.version and x.confirmed_at is null
  for update;
  if not found then
    raise exception 'transfer file refused: not_requested' using errcode = 'check_violation';
  end if;
  if q.requested_by = auth.uid() then
    raise exception 'transfer file refused: same_person' using errcode = 'check_violation';
  end if;
  v_evidence := private.transfer_cancel_evidence(f.id, null);
  if v_evidence ->> 'refusal' is not null then
    raise exception 'transfer file refused: %', v_evidence ->> 'refusal' using errcode = 'check_violation',
      detail = v_evidence::text;
  end if;
  -- (M2c-7f-1, H7) the file's transfers in it through its items, each by its key
  update public.bank_transfer t set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
    cancel_reason = 'Fichier ' || f.number || ' annulé : virement retourné par la banque'
  where t.id = any (array(
          select x.id from public.transfer_file_item i
          cross join lateral (select b.id, b.status, b.transfer_file_id from public.bank_transfer b
                              where b.id = i.transfer_id offset 0) x
          where i.file_id = f.id and x.transfer_file_id = f.id and x.status = 'in_file'))
    and t.transfer_file_id = f.id and t.status = 'in_file' and private.transfer_return_seen(t.id);
  get diagnostics v_returned = row_count;
  v_status := case q.attestation when 'rejected_by_bank' then 'rejected' else 'superseded' end;
  v_n := private.transfer_file_release(f.id, v_status, q.reason, q.attestation, null);
  update public.transfer_cancellation_request set confirmed_by = auth.uid(), confirmed_at = clock_timestamp(),
    confirm_evidence = v_evidence
  where id = q.id;
  v_result := jsonb_build_object('request_id', q.id, 'file_id', f.id, 'number', f.number, 'status', v_status,
                                 'transfers_back', v_n, 'transfers_returned', v_returned);
  perform private.command_record('confirm_transfer_file_cancellation', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


------------------------------------------------------------------------------------------
-- H7 (steps 2 and 3): a payout file's transfers read through its items (D12)
------------------------------------------------------------------------------------------

-- Measured under 7e-1 round 2's plant (the close-out reads test, test_a_files_transfers_are_read_through_its_items_…:
-- other servicers' transfers in flight in two other files, their runs, dead index entries of rolled-back rows, a
-- file's transfers priced at half the table): a read by `transfer_file_id = f.id` — with a status filter implying
-- bank_transfer_debtor_idx's or bank_transfer_servicer_flight_idx's predicate, or a join to the runs — ran as a scan
-- of every servicer's transfers (or runs, or items). Each such read now takes the file's items (transfer_file_item by
-- its key) and each one's transfer by its own key in a fence, its file, status and kind checked on the row (the form
-- of 7e-1 round 2), and the function runs with enable_seqscan off.

-- private.transfer_line_locks, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 1888; same
-- signature, SECURITY DEFINER, search_path '', enable_seqscan off and its grants restated below). M2c-7f-1 (H7): a late
-- predecessor's file not downloaded yet (its body line 150, switch-on states) has its transfers read through the
-- file's items — by `transfer_file_id = p.file_id` the planner took bank_transfer_filed_amount_idx whole (its
-- predicate implied), 48,531 rows under the plant. Nothing else changes.
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
  -- M2c-6b-3a-2 (E): a late predecessor's live end, re-read after the remit lock (a generation files under that lock,
  -- and takes no run lock: one that committed since the keys were read moved it into its file) — the run's transfer
  -- (the run is locked, step 1: its pointer no longer moves) and the file it is in when not downloaded yet: that file
  -- FOR UPDATE, in id order, before the FOR SHARE set below; the transfer and every transfer of that file FOR UPDATE
  -- with the keys (step 9). The check reads them under these locks.
  v_step := 'files';
  drop table if exists pg_temp._tl_lp;
  create temp table _tl_lp on commit drop as
  select distinct y.id as transfer_id, y.transfer_file_id as file_id
  from pg_temp._tl_keys k
  cross join lateral (select q.id, q.run_id, q.kind, q.status from public.bank_transfer q
                      where q.id = k.transfer_id offset 0) x
  cross join lateral (select q.transfer_id from public.remittance_run q where q.id = x.run_id offset 0) ru
  cross join lateral (select q.id, q.transfer_file_id from public.bank_transfer q where q.id = ru.transfer_id offset 0) y
  where x.kind = 'payout' and x.status = 'cancelled' and y.id <> x.id;
  insert into pg_temp._tl_keys select p.transfer_id from pg_temp._tl_lp p on conflict do nothing;
  perform 1 from public.transfer_file f
  where f.id = any (array(select p.file_id from pg_temp._tl_lp p where p.file_id is not null))
    and f.download_count = 0
  order by f.id for update;
  insert into pg_temp._tl_keys
  select y.id
  from pg_temp._tl_lp p
  cross join lateral (select q.download_count from public.transfer_file q where q.id = p.file_id offset 0) f
  -- (M2c-7f-1, H7) the file's transfers through its items, each by its key, its file checked on the row
  cross join lateral (select x.id
                      from public.transfer_file_item i
                      cross join lateral (select q.id, q.transfer_file_id from public.bank_transfer q
                                          where q.id = i.transfer_id offset 0) x
                      where i.file_id = p.file_id and x.transfer_file_id = p.file_id offset 0) y
  where p.file_id is not null and f.download_count = 0
  on conflict do nothing;
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

-- private.transfer_file_lock_runs, redefined from 20261115090000_transfers_files.sql (line 2024; same signature,
-- SECURITY DEFINER, search_path '' and its grants restated below). M2c-7f-1 (H7): under the plant its join of the
-- file's items to their transfers read every servicer's items (a hash of the items table, with enable_seqscan on as
-- public.cancel_transfer_file calls it); now each run by its key, the items by the file's key and each one's transfer
-- by its own, the runs locked one by one in id order as before; enable_seqscan off.
create or replace function private.transfer_file_lock_runs(p_file_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_run uuid;
begin
  -- each run by its key, in id order (a statement by `id = any (…)` beside the runs' partial indexes may read every
  -- servicer's runs whole)
  for v_run in select distinct t.run_id
               from public.transfer_file_item i
               cross join lateral (select q.run_id from public.bank_transfer q where q.id = i.transfer_id offset 0) t
               where i.file_id = p_file_id and t.run_id is not null
               order by 1 loop
    perform 1 from public.remittance_run r where r.id = v_run for update;
  end loop;
end;
$$;

-- private.transfer_file_release, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 4663; same
-- signature, SECURITY DEFINER, search_path '' and its grants restated below). M2c-7f-1 (H7): its four reads of the
-- file's transfers (the sweeps cancelled, the payouts and refunds re-issued after a download — locked first in id
-- order, as before —, the rest ordered again, the runs back to approved) through the file's items; enable_seqscan off.
-- Every other statement is unchanged.
create or replace function private.transfer_file_release(p_file_id uuid, p_status text, p_reason text,
                                                         p_attestation text, p_superseded_by uuid)
returns integer
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  f public.transfer_file;
  v_n integer := 0;
  v_back integer;
  o public.bank_transfer;
  v_e2e text;
  v_new uuid;
  v_run uuid;
begin
  select * into f from public.transfer_file where id = p_file_id for update;
  if f.status in ('superseded', 'rejected', 'failed') then
    return 0;
  end if;
  update public.transfer_file set status = p_status, closed_at = clock_timestamp(), closed_by = auth.uid(),
    close_reason = p_reason, close_attestation = p_attestation, superseded_by = p_superseded_by,
    version = version + 1
  where id = f.id;
  update public.bank_transfer t set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
    cancel_reason = 'Fichier ' || f.number || ' retiré : la quote-part est recalculée au prochain fichier'
  where t.id = any (array(
          select x.id from public.transfer_file_item i
          cross join lateral (select q.id, q.kind, q.status, q.transfer_file_id from public.bank_transfer q
                              where q.id = i.transfer_id offset 0) x
          where i.file_id = f.id and x.transfer_file_id = f.id and x.status = 'in_file' and x.kind = 'sweep'))
    and t.transfer_file_id = f.id and t.status = 'in_file' and t.kind = 'sweep';
  if f.download_count > 0 then
    -- (M2c-7f-1, H7) the file's payouts and refunds still in it locked in id order, then read through its items
    perform 1 from public.bank_transfer t
    where t.id = any (array(
            select x.id from public.transfer_file_item i
            cross join lateral (select q.id, q.kind, q.status, q.transfer_file_id from public.bank_transfer q
                                where q.id = i.transfer_id offset 0) x
            where i.file_id = f.id and x.transfer_file_id = f.id and x.status = 'in_file'
              and x.kind in ('payout', 'refund')))
    order by t.id for update;
    for o in select t.* from public.transfer_file_item i
             cross join lateral (select q.* from public.bank_transfer q where q.id = i.transfer_id offset 0) t
             where i.file_id = f.id and t.transfer_file_id = f.id and t.status = 'in_file'
               and t.kind in ('payout', 'refund')
             order by t.id loop
      -- M2c-6b-3a-2 (H): a payout whose run is no longer approved or sent (booked: a late predecessor's), or a refund
      -- no longer requested, is cancelled and never re-issued (defence in depth: no command reaches it); its run's and
      -- its refund's pointers stay
      if (o.kind = 'payout' and not exists (select 1 from public.remittance_run r
                                            where r.id = o.run_id and r.status in ('approved', 'sent')))
         or (o.kind = 'refund' and not exists (select 1 from public.refund_request q
                                               where q.transfer_id = o.id and q.status = 'requested')) then
        update public.bank_transfer set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
          cancel_reason = 'Fichier ' || f.number || ' annulé après téléchargement : non réémis ('
                          || case o.kind when 'payout' then 'son reversement n''est plus en cours'
                                         else 'son remboursement n''est plus demandé' end || ')'
        where id = o.id;
        continue;
      end if;
      v_e2e := left(o.end_to_end_id, 3) || upper(substr(md5(gen_random_uuid()::text), 1, 12));
      update public.bank_transfer set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
        cancel_reason = 'Fichier ' || f.number || ' annulé après téléchargement : virement réémis sous ' || v_e2e
      where id = o.id;
      insert into public.bank_transfer (organization_id, client_organization_id, kind, debtor_bank_account_id,
                                        creditor_bank_account_id, currency, run_id, amount_minor, payee_name, payee_iban,
                                        payee_bic, end_to_end_id, remittance_info, requested_execution_date, reason,
                                        ordered_by, replaces_transfer_id)
      values (o.organization_id, o.client_organization_id, o.kind, o.debtor_bank_account_id, o.creditor_bank_account_id,
              o.currency, o.run_id, o.amount_minor, o.payee_name, o.payee_iban, o.payee_bic, v_e2e,
              case when o.kind = 'refund' then 'REMBOURSEMENT ' || v_e2e else o.remittance_info end,
              o.requested_execution_date, o.reason, o.ordered_by, o.id)
      returning id into v_new;
      update public.remittance_run set transfer_id = v_new, version = version + 1 where transfer_id = o.id;
      update public.refund_request set transfer_id = v_new, end_to_end_id = v_e2e where transfer_id = o.id;
      v_n := v_n + 1;
    end loop;
  end if;
  update public.bank_transfer t set status = 'ordered', transfer_file_id = null
  where t.id = any (array(
          select x.id from public.transfer_file_item i
          cross join lateral (select q.id, q.status, q.transfer_file_id from public.bank_transfer q
                              where q.id = i.transfer_id offset 0) x
          where i.file_id = f.id and x.transfer_file_id = f.id and x.status = 'in_file'))
    and t.transfer_file_id = f.id and t.status = 'in_file';
  get diagnostics v_back = row_count;
  v_n := v_n + v_back;
  -- its runs whose transfer is ordered again (the same, or the one re-issuing it)
  for v_run in select distinct t.run_id
               from public.transfer_file_item i
               cross join lateral (select q.run_id from public.bank_transfer q where q.id = i.transfer_id offset 0) t
               where i.file_id = f.id and t.run_id is not null
               order by 1 loop
    update public.remittance_run r set status = 'approved', version = version + 1
    where r.id = v_run and r.status = 'sent'
      and exists (select 1 from public.bank_transfer x where x.id = r.transfer_id and x.status = 'ordered');
  end loop;
  return v_n;
end;
$$;

-- public.mark_transfer_file_sent, redefined from 20261115090000_transfers_files.sql (line 2174; same signature,
-- SECURITY DEFINER, search_path '', lock_timeout and its grants restated below). M2c-7f-1 (H7): the file's runs sent
-- by its items (the update joined every in-file transfer to the runs: a scan of every servicer's runs in flight
-- under the plant); enable_seqscan off. Nothing else changes.
create or replace function public.mark_transfer_file_sent(p_idempotency_key text, p_file_id uuid,
                                                          p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set enable_seqscan = off
as $$
declare
  f public.transfer_file;
  v_request jsonb := jsonb_build_object('file_id', p_file_id, 'expected_version', p_expected_version);
  v_result jsonb;
  v_run uuid;
begin
  select * into f from public.transfer_file where id = p_file_id;
  if not found or not private.has_role(f.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('mark_transfer_file_sent', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  perform private.transfer_file_lock_runs(f.id);
  perform private.remittance_command_locks(f.organization_id, true);
  select * into f from public.transfer_file where id = p_file_id for update;
  if p_expected_version is distinct from f.version then
    raise exception 'transfer file refused: version_changed' using errcode = 'check_violation';
  end if;
  if f.status <> 'downloaded' then
    raise exception 'transfer file refused: %', case f.status when 'sent' then 'already_sent'
                                                              when 'generated' then 'not_downloaded'
                                                              when 'pending' then 'not_ready'
                                                              else 'not_live' end
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.transfer_file_item i
             cross join lateral (select t.status from public.bank_transfer t where t.id = i.transfer_id offset 0) t
             where i.file_id = f.id and t.status = 'cancelled')
     and not private.transfer_file_executed(f.id) then
    raise exception 'transfer file refused: holds_cancelled_transfer' using errcode = 'check_violation',
      hint = case when private.switch_on('downloaded_file_cancellation')
                  then 'Un virement de ce fichier a été annulé et la banque n''en a exécuté aucun : ne le déposez pas ; demandez l''annulation du fichier.'
                  else 'Un virement de ce fichier a été annulé et la banque n''en a exécuté aucun : ne le déposez pas. Gardez le fichier tel quel, vérifiez le relevé et voyez avec la banque.' end;
  end if;
  update public.transfer_file set status = 'sent', sent_marked_by = auth.uid(), sent_marked_at = clock_timestamp(),
    version = version + 1
  where id = f.id;
  for v_run in select distinct t.run_id
               from public.transfer_file_item i
               cross join lateral (select q.run_id, q.status, q.transfer_file_id from public.bank_transfer q
                                   where q.id = i.transfer_id offset 0) t
               where i.file_id = f.id and t.transfer_file_id = f.id and t.status = 'in_file' and t.run_id is not null
               order by 1 loop
    update public.remittance_run r set status = 'sent', version = version + 1
    where r.id = v_run and r.status = 'approved';
  end loop;
  v_result := jsonb_build_object('file_id', f.id, 'number', f.number, 'status', 'sent');
  perform private.command_record('mark_transfer_file_sent', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- private.transfer_line_supersedes, redefined from 20261117100000_transfer_line_ops.sql (line 1708; same signature,
-- STABLE, SECURITY DEFINER, search_path '' and its grants restated below). M2c-7f-1 (H7): a generated file's sweep
-- through its items; enable_seqscan off (public.transfer_line_preview, its caller, runs with it already). CI round
-- (PR #52), round 2: the servicer's other sweeps in flight of the currency, which each generated file's sweep is weighed
-- against, summed once by private.servicer_flight_minor (the servicer's text key), less that sweep's own amount when it
-- is one of them (by its key) — by `organization_id` and constants, once per sweep, the sum read every transfer of the
-- servicer in flight by bank_transfer_org_idx under the reads test's plant (567 rows for 4 sweeps; 5,567 beside a run's
-- 5,000 payouts). The same sum: the function is STABLE, every statement of it sees the same rows.
create or replace function private.transfer_line_supersedes(p_line_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  l public.bank_transaction;
  v_lower bigint;
  v_raise bigint;
  v_share bigint;
  v_flight bigint;
  v_file record;
begin
  select * into l from public.bank_transaction where id = p_line_id;
  select coalesce(sum(case when t.kind = 'fee' then t.amount when t.kind = 'unplanned_payout' then t.adv
                           when t.kind = 'unplanned_sweep' then t.amount else 0 end), 0)
         + coalesce(sum(case when t.kind = 'payout'
                             then greatest(0, coalesce((select b.balance_minor from private.client_payable_balance b
                                                        where b.client_organization_id = t.tr_client
                                                          and b.currency = l.currency), 0)
                                              + t.amount + coalesce(ru.settlement_minor, 0)) else 0 end), 0),
         coalesce(sum(case when t.kind = 'payout' then coalesce(ru.settlement_minor, 0) else 0 end), 0)
  into v_lower, v_raise
  from pg_temp._tl t
  left join lateral (select q.settlement_minor from public.remittance_run q where q.id = t.tr_run offset 0) ru on true;
  if v_lower <= 0 then
    return null;
  end if;
  select -coalesce(sum(lp.amount_minor), 0) into v_share
  from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
  where la.organization_id = l.organization_id and la.book = 'due_to_servicer' and la.currency = l.currency;
  v_share := v_share + v_raise - v_lower;
  -- the servicer's sweeps in flight of the currency, once (CI round, PR #52, round 2)
  v_flight := private.servicer_flight_minor(l.organization_id, l.currency, 'sweep', array['ordered', 'in_file']);
  for v_file in
    select f.id, f.number, s.id as sweep_id, s.amount_minor
    from public.transfer_file f
    cross join lateral (select t.id, t.amount_minor
                        from public.transfer_file_item i
                        cross join lateral (select q.id, q.amount_minor, q.kind, q.status, q.transfer_file_id
                                            from public.bank_transfer q where q.id = i.transfer_id offset 0) t
                        where i.file_id = f.id and t.transfer_file_id = f.id and t.kind = 'sweep'
                          and t.status = 'in_file'
                        offset 0) s
    where f.organization_id = l.organization_id and f.status = 'generated' and f.currency = l.currency
    order by f.created_at, f.id
  loop
    -- the others: all of them less this one when it is one of them (read by its key alone, fenced; checked on the row)
    if v_file.amount_minor > v_share - (v_flight
                                        - coalesce((select x.amount_minor
                                                    from (select q.amount_minor, q.organization_id, q.kind, q.currency,
                                                                 q.status
                                                          from public.bank_transfer q where q.id = v_file.sweep_id
                                                          offset 0) x
                                                    where x.organization_id = l.organization_id and x.kind = 'sweep'
                                                      and x.currency = l.currency
                                                      and x.status in ('ordered', 'in_file')), 0)) then
      return jsonb_build_object('file_id', v_file.id, 'number', v_file.number);
    end if;
  end loop;
  return null;
end;
$$;

-- private.transfer_cancel_evidence, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 628; same
-- signature, STABLE, SECURITY DEFINER, search_path '', enable_seqscan off and its grants restated below). M2c-7f-1 (H7):
-- a whole file's evidence (the two-step cancellation's) groups the file's items by PmtInf after reading them by the
-- file's key in a fence — ordered by its PmtInf, the planner read every servicer's items by
-- transfer_file_item_pmt_inf_idx to spare a sort. Nothing else changes.
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
    v_debit := exists (select 1 from (select distinct i.pmt_inf_id
                                      from (select y.pmt_inf_id from public.transfer_file_item y
                                            where y.file_id = f.id offset 0) i) p
                       where exists (select 1 from public.bank_transaction x
                                     where x.bank_account_id = f.debtor_bank_account_id
                                       and x.payment_info_id = p.pmt_inf_id and x.direction = 'debit'))
               or exists (select 1 from public.transfer_file_item i
                          cross join lateral (select x.id, x.status, x.end_to_end_id, x.transfer_file_id
                                              from public.bank_transfer x where x.id = i.transfer_id offset 0) bt
                          where i.file_id = f.id and bt.transfer_file_id = f.id
                            and (bt.status = 'booked'
                                 or (bt.status = 'in_file'
                                     and (private.transfer_own_debit_seen(f.debtor_bank_account_id, bt.end_to_end_id)
                                          -- M2c-6b-3a-2 review round 1 (DP-1): or as a detail of an entry kept unsplit
                                          or private.transfer_unsplit_debit_seen(f.debtor_bank_account_id,
                                                                                 bt.end_to_end_id))
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
            from (select y.pmt_inf_id, y.transfer_id, y.file_id from public.transfer_file_item y
                  where y.file_id = f.id offset 0) i
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
    if private.transfer_own_debit_seen(t.debtor_bank_account_id, t.end_to_end_id)
       -- M2c-6b-3a-2 review round 1 (DP-1): or as a detail of an entry kept unsplit
       or private.transfer_unsplit_debit_seen(t.debtor_bank_account_id, t.end_to_end_id) then
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

-- private.transfer_file_executed, redefined from 20261115090000_transfers_files.sql (line 1122; same signature, STABLE,
-- search_path '', enable_seqscan off, SECURITY INVOKER as there, its grants restated below). M2c-7f-1 (H7): as
-- private.transfer_cancel_evidence's, the file's items by the file's key in a fence before their PmtInf grouping
-- (« Télécharger » again, « Marquer comme déposé »: 7e-1's top-up reads test read 320 items in the db job's order, a
-- merge semi-join over transfer_file_item_pmt_inf_idx). Nothing else changes.
create or replace function private.transfer_file_executed(p_file_id uuid)
returns boolean
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select exists (select 1 from (select distinct i.pmt_inf_id
                                from (select y.pmt_inf_id from public.transfer_file_item y
                                      where y.file_id = f.id offset 0) i) p
                 where exists (select 1 from public.bank_transaction x
                               where x.bank_account_id = f.debtor_bank_account_id and x.payment_info_id = p.pmt_inf_id
                                 and x.direction = 'debit'))
      or exists (select 1 from public.transfer_file_item i
                 cross join lateral (select o.id, o.end_to_end_id, o.transfer_file_id from public.bank_transfer o
                                     where o.id = i.transfer_id offset 0) o
                 where i.file_id = f.id and o.transfer_file_id = f.id
                   and (private.transfer_own_debit_seen(f.debtor_bank_account_id, o.end_to_end_id)
                        or private.transfer_return_seen(o.id)))
  from public.transfer_file f where f.id = p_file_id;
$$;

-- private.bank_transfer_guard, redefined from 20261129090000_top_ups.sql (line 463; same signature and settings, its
-- trigger and grants unchanged, restated below). M2c-7f-1 (H7): a re-issue's predecessor read by its key in a fence —
-- its filter (cancelled, in a file) implies bank_transfer_cancelled_filed_idx's predicate, and under the plant the
-- check read every servicer's cancelled filed transfers once per re-issue (the switch-on release after a download).
-- Every rule unchanged.
create or replace function private.bank_transfer_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'ordered' or new.transfer_file_id is not null then
      raise exception 'bank transfer: starts ordered' using errcode = 'check_violation';
    end if;
    if new.kind = 'top_up' and not (
         exists (select 1 from public.bank_account b where b.id = new.debtor_bank_account_id and b.purpose = 'own'
                   and b.status = 'active')
         and exists (select 1 from public.bank_account b where b.id = new.creditor_bank_account_id
                       and b.purpose = 'client_funds' and b.status = 'active'
                       and b.iban = new.payee_iban)) then
      raise exception 'bank transfer: a top-up goes from an active own account to an active client_funds account'
        using errcode = 'check_violation';
    end if;
    if new.kind = 'sweep' and not (
         exists (select 1 from public.bank_account b where b.id = new.debtor_bank_account_id
                   and b.purpose = 'client_funds' and b.status = 'active')
         and exists (select 1 from public.bank_account b where b.id = new.creditor_bank_account_id
                       and b.purpose = 'own' and b.status = 'active' and b.iban = new.payee_iban)) then
      raise exception 'bank transfer: a sweep goes from an active client_funds account to an active own account'
        using errcode = 'check_violation';
    end if;
    if new.kind = 'payout' and not exists (select 1 from public.organization c where c.id = new.client_organization_id
                                             and c.servicer_organization_id = new.organization_id) then
      raise exception 'bank transfer: a payout goes to a client of the servicer' using errcode = 'check_violation';
    end if;
    if new.run_id is not null and not exists (select 1 from public.remittance_run r where r.id = new.run_id
                                             and r.client_organization_id = new.client_organization_id
                                             and r.currency = new.currency) then
      raise exception 'bank transfer: a payout belongs to a run of its client' using errcode = 'check_violation';
    end if;
    if new.kind = 'refund' and not exists (select 1 from public.bank_account b where b.id = new.debtor_bank_account_id
                                             and b.purpose = 'client_funds') then
      raise exception 'bank transfer: a refund goes out of a client_funds account' using errcode = 'check_violation';
    end if;
    -- review round 3 (E1): a re-issue orders again exactly what the cancelled payout or refund ordered, under a new id
    if new.replaces_transfer_id is not null and not exists (
         select 1
         from (select q.* from public.bank_transfer q where q.id = new.replaces_transfer_id offset 0) o
         where o.status = 'cancelled'
           and o.kind in ('payout', 'refund') and o.transfer_file_id is not null
           and (o.organization_id, o.client_organization_id, o.kind, o.debtor_bank_account_id, o.currency, o.run_id,
                o.amount_minor, o.payee_name, o.payee_iban, o.payee_bic, o.requested_execution_date)
               is not distinct from
               (new.organization_id, new.client_organization_id, new.kind, new.debtor_bank_account_id, new.currency,
                new.run_id, new.amount_minor, new.payee_name, new.payee_iban, new.payee_bic,
                new.requested_execution_date)
           and o.end_to_end_id <> new.end_to_end_id) then
      raise exception 'bank transfer: a re-issue orders again what a cancelled payout or refund of a file ordered'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.client_organization_id, new.kind, new.debtor_bank_account_id,
      new.creditor_bank_account_id, new.currency, new.run_id,
      new.amount_minor, new.payee_name, new.payee_iban, new.payee_bic, new.end_to_end_id, new.remittance_info,
      new.requested_execution_date, new.reason, new.ordered_by, new.created_at, new.replaces_transfer_id)
     is distinct from
     (old.id, old.organization_id, old.client_organization_id, old.kind, old.debtor_bank_account_id,
      old.creditor_bank_account_id, old.currency, old.run_id,
      old.amount_minor, old.payee_name, old.payee_iban, old.payee_bic, old.end_to_end_id, old.remittance_info,
      old.requested_execution_date, old.reason, old.ordered_by, old.created_at, old.replaces_transfer_id)
     or (old.entry_id is not null and new.entry_id is distinct from old.entry_id)
     or (old.return_entry_id is not null and new.return_entry_id is distinct from old.return_entry_id)
     or (new.status <> old.status and not (
           (old.status = 'ordered' and new.status in ('in_file', 'booked', 'cancelled'))
           or (old.status = 'in_file' and new.status in ('ordered', 'booked', 'cancelled'))
           or (old.status = 'booked' and new.status = 'returned')))
     -- the file: set when it goes in one, cleared when it comes back, kept after
     or (new.transfer_file_id is distinct from old.transfer_file_id and not (
           (old.status = 'ordered' and new.status = 'in_file' and old.transfer_file_id is null)
           or (old.status = 'in_file' and new.status = 'ordered' and new.transfer_file_id is null)))
     or (old.status = 'in_file' and new.status = 'ordered' and not exists (
           select 1 from public.transfer_file f where f.id = old.transfer_file_id
             and f.status in ('superseded', 'rejected', 'failed'))) then
    raise exception 'bank transfer %: what was ordered never changes, and its status only moves forward', old.id
      using errcode = 'check_violation';
  end if;
  -- review round 5 (fail-closed): a transfer of a file downloaded at least once does not leave it — cancelled, or back
  -- to ordered — while cancellation after download is off, whoever writes it (booked by its debit, it does)
  -- M2c-7e-1 ([check 1] gap 4): skipped only for a top-up whose file's debtor is an own account (such a file holds only
  -- top-ups: private.transfer_file_item_guard); payouts, refunds and sweeps stay fail-closed
  if old.status = 'in_file' and new.status in ('ordered', 'cancelled')
     and exists (select 1 from public.transfer_file f where f.id = old.transfer_file_id and f.download_count > 0)
     and not private.switch_on('downloaded_file_cancellation')
     and not (old.kind = 'top_up'
              and exists (select 1 from public.transfer_file f join public.bank_account b on b.id = f.debtor_bank_account_id
                          where f.id = old.transfer_file_id and b.purpose = 'own')) then
    raise exception 'bank transfer %: it stays in its downloaded file: cancellation after download is switched off until M2c-6b',
      old.id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;


------------------------------------------------------------------------------------------
-- H12: bad_date names the greatest refused day
------------------------------------------------------------------------------------------

-- private.client_payment_named_refusal, redefined from 20261124090000_client_payments.sql (line 1477; same signature and
-- settings, its grants restated below). M2c-7f-1 (H12; ADR-0014 « M2c-7c-1 review fixes », round 4's verifier q6): the
-- first refusal in the client's order as before; when it is bad_date, its day is the latest among the refused
-- designations (the web prints the day SQL names).
create or replace function private.client_payment_named_refusal(p_docs jsonb, p_named uuid[], p_recover uuid[],
                                                                p_recoveries jsonb)
returns table (code text, detail text)
language sql
immutable
set search_path = ''
as $$
  -- (M2c-7f-1, H12) the first refusal in the client's order; a bad_date names the greatest day among the refused
  -- designations (redated to it, the payment passes them all at once)
  with r as (
        select case when x.doc is null then 'not_open'
                    when (x.doc ->> 'open_on')::boolean is false then 'bad_date'
                    when jsonb_typeof(x.doc -> 'in_flight_run') = 'object' then 'in_flight' end as code,
               case when (x.doc ->> 'open_on')::boolean is false then x.doc ->> 'since'
                    else x.doc #>> '{in_flight_run,number}' end as detail, n.k
        from unnest(coalesce(p_named, '{}')) with ordinality n (id, k)
        left join lateral (select d as doc from jsonb_array_elements(coalesce(p_docs, '[]')) d
                           where (d ->> 'id')::uuid = n.id limit 1) x on true
        union all
        select case when w.rec is null then 'not_open' when (w.rec ->> 'open_on')::boolean is false then 'bad_date' end,
               w.rec ->> 'written_off_on', 1000000 + n.k
        from unnest(coalesce(p_recover, '{}')) with ordinality n (id, k)
        left join lateral (select q as rec from jsonb_array_elements(coalesce(p_recoveries, '[]')) q
                           where (q ->> 'id')::uuid = n.id limit 1) w on true)
  select r.code,
         case when r.code = 'bad_date'
              then (select max(b.detail) from r b where b.code = 'bad_date' and b.detail is not null)  -- ISO days: max as text
              else r.detail end
  from r
  where r.code is not null
  order by r.k
  limit 1;
$$;

------------------------------------------------------------------------------------------
-- H13: the withdrawal names, per advance, the requests that still name it
------------------------------------------------------------------------------------------

-- public.withdraw_advance_repayment_request, redefined from 20261125090000_repayment_requests.sql (line 603; same
-- signature and settings, SECURITY DEFINER, search_path '' and its grants restated below). M2c-7f-1 (H13; ADR-0014
-- « M2c-7c-2 review fixes », round 1's verifier): its result also says, per advance of the withdrawn request still
-- open, which other requests not withdrawn still name it; still_requested_by is kept (the union, for the older parse).
create or replace function public.withdraw_advance_repayment_request(p_idempotency_key text, p_request_id uuid,
                                                                    p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  q public.advance_repayment_request;
  v_request jsonb;
  v_result jsonb;
begin
  select * into q from public.advance_repayment_request where id = p_request_id;
  if not found or not private.has_role(q.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('request_id', p_request_id, 'reason', p_reason);
  v_result := private.command_replay('withdraw_advance_repayment_request', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_reason is null or length(btrim(p_reason)) not between 1 and 2000 then
    raise exception 'repayment request refused: reason_required' using errcode = 'check_violation';
  end if;
  perform private.remittance_command_locks(q.organization_id, true);
  select * into q from public.advance_repayment_request where id = p_request_id for update;
  if q.withdrawn_at is not null then
    raise exception 'repayment request refused: already_withdrawn' using errcode = 'check_violation';
  end if;
  update public.advance_repayment_request
  set withdrawn_at = clock_timestamp(), withdrawn_by = auth.uid(), withdrawal_reason = btrim(p_reason)
  where id = q.id
  returning * into q;
  v_result := jsonb_build_object(
    'request_id', q.id, 'number', q.number, 'withdrawn_on', (q.withdrawn_at at time zone 'Europe/Paris')::date,
    'still_requested_by', (
      select coalesce(jsonb_agg(distinct o.number order by o.number), '[]')
      from (select i.advance_id from public.advance_repayment_request_item i where i.request_id = q.id offset 0) i
      cross join lateral (select j.request_id from public.advance_repayment_request_item j
                          where j.advance_id = i.advance_id offset 0) j
      cross join lateral (select r.number, r.withdrawn_at from public.advance_repayment_request r
                          where r.id = j.request_id offset 0) o
      where j.request_id <> q.id and o.withdrawn_at is null and private.advance_open(i.advance_id) > 0),
    -- (M2c-7f-1, H13) per advance of the withdrawn request still open: its birth, its open part and the requests not
    -- withdrawn that still name it (none: it may be taken back or requested anew) — the notice words each one
    'advances', (
      select coalesce(jsonb_agg(jsonb_build_object('advance_id', a.id, 'born_on', a.born_on,
                                                   'open_minor', a.open_minor::text, 'currency', a.currency,
                                                   'still_requested_by', a.still)
                                order by a.born_on, a.id), '[]')
      from (select i.advance_id from public.advance_repayment_request_item i where i.request_id = q.id offset 0) i
      cross join lateral (select y.id, y.currency, private.advance_born_on(y.id) as born_on,
                                 private.advance_open(y.id) as open_minor,
                                 (select coalesce(jsonb_agg(distinct o.number order by o.number), '[]')
                                  from (select j.request_id from public.advance_repayment_request_item j
                                        where j.advance_id = y.id offset 0) j
                                  cross join lateral (select r.number, r.withdrawn_at
                                                      from public.advance_repayment_request r
                                                      where r.id = j.request_id offset 0) o
                                  where j.request_id <> q.id and o.withdrawn_at is null) as still
                          from public.client_advance y where y.id = i.advance_id offset 0) a
      where a.open_minor > 0));
  perform private.command_record('withdraw_advance_repayment_request', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


------------------------------------------------------------------------------------------
-- H15: a barred invoice dated by the earliest bar in effect
------------------------------------------------------------------------------------------

-- private.client_post_opening_unpaid, redefined from 20261128090000_declarations_statement.sql (line 376; same
-- signature and settings, created or replaced, SECURITY DEFINER, search_path '' and its grants restated below).
-- M2c-7f-1 (H15; ADR-0014 « M2c-7d-3 review fixes », round 3's verifier): the bar's day is the least of
-- private.client_set_off_bar_recorded_on over the invoice bars in effect (before, the strongest bar's: a seizure then
-- a liquidation moved it later); the filter is coalesce(due_date, least(withheld_on, that day)) < p_on. barred_on stays
-- null when withheld_on is set (the web and 046c read the debit's day then); private.run_advance_checks is not copied:
-- its age stays coalesce(due_date, withheld_on, barred_on), the day each help sentence names. (Review round 1,
-- TUI-H15-BAR-DAY) `bar` is the code of the bar recorded on barred_on (the strongest on a tie), not the strongest in
-- effect: « Contrôles » reads the pair as « depuis le <barred_on>, jour où le cabinet a enregistré <bar> ».
create or replace function private.client_post_opening_unpaid(p_client uuid, p_on date)
returns table (document_id uuid, currency char(3), open_minor bigint, number text, due_date date, born_on date,
               opening_on date, opening_kind text, publication_date date, liquidation_on date, withheld_on date,
               barred_on date, bar text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with f as materialized (select * from private.client_procedure_facts(p_client, p_on)),
  dec as materialized (select x.id from private.client_documents_declared(p_client, p_on) x (id)
                       where exists (select 1 from f)),
  -- (M2c-7f-1, H15) the day is the earliest recording among the invoice bars in effect (a liquidation, the mandate's
  -- end, a seizure standing: each one's own day, null when it is not in effect); (review round 1, TUI-H15-BAR-DAY) the
  -- code is the bar recorded that day — the strongest on a tie (liquidation, then the mandate's end, then a seizure) —,
  -- the one « Contrôles » names as recorded on it (before, the strongest bar in effect, with another bar's day)
  bar as materialized (
    select d.code, d.on_day
    from f
    cross join lateral (select private.client_set_off_barred(p_client, p_on, 'invoice') as code offset 0) b
    cross join lateral (select v.code, v.on_day
                        from (values (1, 'liquidation',
                                      private.client_set_off_bar_recorded_on(p_client, p_on, 'liquidation')),
                                     (2, 'mandate_ended',
                                      private.client_set_off_bar_recorded_on(p_client, p_on, 'mandate_ended')),
                                     (3, 'seizure', private.client_set_off_bar_recorded_on(p_client, p_on, 'seizure')))
                             v (strength, code, on_day)
                        where v.on_day is not null
                        order by v.on_day, v.strength
                        limit 1) d
    where b.code is not null),
  inv as materialized (
    -- (H15) the bar's day shown only for an invoice not withheld (a withheld one is dated by its debit, 046c's rule)
    select i.id, i.currency, i.number, i.due_date, w.withheld_on,
           case when w.withheld_on is null then x.on_day end as barred_on,
           case when w.withheld_on is null then x.code end as bar,
           private.document_open(i.id) as open
    from f
    cross join lateral (select q.id, q.currency, q.number, q.kind, q.due_date, q.settlement, q.run_id
                        from public.commission_invoice q where q.client_organization_id = p_client offset 0) i
    cross join lateral (select case when i.kind = 'invoice' and i.due_date is null
                                    then private.invoice_withheld_on(i.id) end as withheld_on offset 0) w
    left join lateral (select bar.code, bar.on_day
                       from bar
                       where i.kind = 'invoice' and i.due_date is null
                         and i.settlement = 'netted' and i.run_id is not null) x on true
    -- (H15) a withheld invoice from the earlier of its debit and its bar: a debit on the check's day no longer drops it
    -- for that night
    where i.kind = 'invoice' and coalesce(i.due_date, least(w.withheld_on, x.on_day)) < p_on)
  select i.id, i.currency, i.open, i.number, i.due_date, b.born, f.opening_on, f.opening_kind, f.publication_date,
         f.liquidation_on, i.withheld_on, i.barred_on, i.bar
  from inv i
  cross join lateral (select private.document_born_on(i.id) as born) b
  cross join f
  where i.open > 0 and b.born >= f.opening_on and not exists (select 1 from dec where dec.id = i.id);
$$;


------------------------------------------------------------------------------------------
-- H14: the allocation's backstop re-reads the mandate's end
------------------------------------------------------------------------------------------

-- private.post_allocations, redefined from 20261110120000_debits_refunds.sql (line 2017; same signature and settings,
-- SECURITY DEFINER, search_path '' and its grants restated below). M2c-7f-1 (H14; ADR-0014 « M2c-7d-1 », Left open):
-- its gates gain the client's mandate's end, as private.gate_assignments reads it (20261126090000 line 1149: a payment
-- received on or after the end is held client_mandate_ended, never allocated), for an end recorded after the payment's
-- match (the gate's own reads catch the others; 046c's fixtures post, by the job's SQL, payments received after an end
-- recorded before them). _alloc_t carries the payment's matched_at. Nothing else changes.
create or replace function private.post_allocations(p_organization_id uuid, p_trigger text, p_engine_version text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p_run_id uuid;
  v_bad text;
  v_today date := private.paris_today();
  v_interest text[];
  v_principal text[];
  v_summary jsonb;
begin
  if p_engine_version is null or p_engine_version !~ '^[a-z0-9.-]{1,40}$' then
    raise exception 'allocation: engine version required' using errcode = 'LG006';
  end if;
  if p_trigger is null or p_trigger not in ('ready', 'continuation') then
    raise exception 'allocation: unknown trigger %', p_trigger using errcode = 'LG006';
  end if;
  -- the allocation lock (design §5.2): the caller holds it already when it read the balances
  perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  insert into public.allocation_run (organization_id, trigger) values (p_organization_id, p_trigger)
  returning id into p_run_id;
  analyze pg_temp._alloc_target;
  analyze pg_temp._alloc_line;

  drop table if exists pg_temp._alloc_t;
  create temp table _alloc_t on commit drop as
  select t.payment_id, t.ord, t.account_id, t.outcome, t.effective_date, t.policy, t.designation, t.inputs_hash,
         p.organization_id as payment_org, p.amount_minor, p.currency as payment_currency, p.booking_date, p.status,
         p.review_reason, coalesce((p.allocation_instruction ->> 'account_id')::uuid, p.account_id) as payment_target,
         p.matched_at,  -- (M2c-7f-1, H14) when the payment was matched: the backstop's end recorded after it
         coalesce(p.allocation_instruction -> 'releases', '[]') as released,
         a.organization_id as account_org, a.client_organization_id, a.portfolio_id, a.status as account_status,
         a.currency as account_currency, s.start as servicing_start, coalesce(h.n, 0) as holds,
         nb.d as not_before,
         row_number() over (order by t.ord)::integer as entry_no
  from pg_temp._alloc_target t
  left join public.payment p on p.id = t.payment_id
  left join public.account a on a.id = t.account_id
  left join lateral (select min(o.valid_from) as start from public.claim_ownership_period o
                     where o.account_id = t.account_id) s on true
  left join lateral (select count(*) as n from public.account_hold x
                     where x.account_id = t.account_id and x.ended_at is null
                       and x.kind in ('surendettement', 'collective_proceeding')) h on true
  -- M2b-6: the money of an allocation reversed at a later date (a bank return: design §2 #3) is back from that date
  -- only, so the payment is allocated again from then on (I4)
  left join lateral (select max(e.effective_date) as d from public.ledger_entry e
                     join public.ledger_entry r on r.id = e.reverses_entry_id
                     where e.payment_id = t.payment_id and e.effective_date > r.effective_date) nb on true;
  alter table pg_temp._alloc_t add primary key (payment_id);
  analyze pg_temp._alloc_t;
  -- (M2c-7f-1, H14) the clients' mandates' ends read again here, as private.gate_assignments reads them (the earliest
  -- end of each client's mandate, private.client_end_event: one keyed read per client of the run), with the day each
  -- was recorded: an end committed between the job's read of its files and this post is caught
  drop table if exists pg_temp._alloc_end;
  create temp table _alloc_end on commit drop as
  select c.client_id, e.effective_date as ended_on, e.recorded_at
  from (select distinct t.client_organization_id as client_id from pg_temp._alloc_t t
        where t.client_organization_id is not null) c
  cross join lateral (select x.effective_date, x.recorded_at
                      from private.client_end_event(c.client_id, 'infinity') x) e;

  -- The run's payments: this servicer's, still ready, on the file the engine planned for.
  select min(t.payment_id::text) into v_bad from pg_temp._alloc_t t
  where t.payment_org is distinct from p_organization_id or t.account_org is distinct from p_organization_id
     or t.status not in ('matched', 'partially_allocated') or t.review_reason is not null
     or t.payment_target is distinct from t.account_id;
  if v_bad is not null then
    raise exception 'allocation: payment % is not ready for allocation on this file', v_bad using errcode = 'LG006';
  end if;
  -- Gates (design §8.4; the job read the same facts under the same locks): a confirmed open file, the payment's
  -- currency (1343-3), not before servicing started unless ops checked it (#10), no surendettement or collective
  -- proceeding unless a judge authorised it (#12); dated greatest(booking date, servicing start), never in the future.
  select min(t.payment_id::text) into v_bad from pg_temp._alloc_t t
  where t.outcome = 'allocate'
    and (t.account_status = 'staged' or t.account_status like 'closed%'
         or t.account_currency <> t.payment_currency
         or t.servicing_start is null
         or t.effective_date <> greatest(t.booking_date, t.servicing_start, coalesce(t.not_before, t.booking_date))
         or t.effective_date > v_today
         or (t.booking_date < t.servicing_start and not (t.released ? 'before_servicing_start'))
         or (t.holds > 0 and not (t.released ? 'hold_blocks_allocation'))
         -- (M2c-7f-1, H14) received on or after the end of the client's mandate (client_mandate_ended, never released),
         -- an end recorded after the payment's match: one the gate could not have read when it let the payment through
         -- (an end recorded before the match holds the payment at the match, and again at the job's own read)
         or exists (select 1 from pg_temp._alloc_end x
                    where x.client_id = t.client_organization_id and x.ended_on <= t.booking_date
                      and x.recorded_at > coalesce(t.matched_at, '-infinity'::timestamptz)));
  if v_bad is not null then
    raise exception 'allocation: payment % may not be allocated on this file now', v_bad using errcode = 'LG006';
  end if;
  -- Lines: only for allocations, on items of the planned file, with an allocation per line.
  select min(l.payment_id::text) into v_bad
  from pg_temp._alloc_line l
  left join pg_temp._alloc_t t on t.payment_id = l.payment_id
  left join public.claim_item i on i.id = l.claim_item_id
  left join public.ledger_component c on c.code = l.component
  where t.payment_id is null or t.outcome <> 'allocate' or i.account_id is distinct from t.account_id or c.code is null;
  if v_bad is not null then
    raise exception 'allocation: payment % has lines outside its plan or its file', v_bad using errcode = 'LG006';
  end if;
  select min(t.payment_id::text) into v_bad from pg_temp._alloc_t t
  where t.outcome = 'allocate' and not exists (select 1 from pg_temp._alloc_line l where l.payment_id = t.payment_id);
  if v_bad is not null then
    raise exception 'allocation: payment % has no line', v_bad using errcode = 'LG006';
  end if;

  -- What is left of each payment (I4 before posting; ledger_entry_verify re-checks every date).
  drop table if exists pg_temp._alloc_u;
  create temp table _alloc_u on commit drop as
  select t.payment_id, t.amount_minor, x.allocated_minor as allocated,
         x.allocated_minor + x.returned_minor as moved
  from pg_temp._alloc_t t
  join private.payment_positions(array(select y.payment_id from pg_temp._alloc_t y)) x on x.payment_id = t.payment_id;
  alter table pg_temp._alloc_u add primary key (payment_id);
  select min(x.payment_id::text) into v_bad
  from (select l.payment_id, sum(l.amount_minor) as s from pg_temp._alloc_line l group by l.payment_id) x
  join pg_temp._alloc_u u on u.payment_id = x.payment_id
  where x.s > u.amount_minor - u.moved;
  if v_bad is not null then
    raise exception 'allocation: payment % would allocate more than is left of it', v_bad using errcode = 'LG007';
  end if;

  -- An item as a whole (review fix): no allocation takes an item's receivable — every component summed, negative ones
  -- included (a negative balancing line: the seller's components above the legal balance 3.12) — below zero at any
  -- date from the allocation's on. What it does not owe stays an overpayment (founder #8). Each check is the lowest
  -- running total of the item from that date on, less this run's allocations on the item up to that one (in date
  -- order): one keyed lateral lookup per (payment, item), whatever the statistics of the ledger.
  drop table if exists pg_temp._alloc_item;
  create temp table _alloc_item on commit drop as
  select x.payment_id, x.claim_item_id, x.effective_date,
         sum(x.amount) over (partition by x.claim_item_id order by x.effective_date, x.ord
                             rows between unbounded preceding and current row) as cum
  from (select t.payment_id, t.ord, t.effective_date, l.claim_item_id, sum(l.amount_minor) as amount
        from pg_temp._alloc_t t join pg_temp._alloc_line l on l.payment_id = t.payment_id
        where t.outcome = 'allocate'
        group by t.payment_id, t.ord, t.effective_date, l.claim_item_id) x;
  select min(z.payment_id::text) into v_bad
  from pg_temp._alloc_item z
  cross join lateral (
    select least(coalesce(sum(g.s) filter (where g.d <= z.effective_date), 0),
                 min(g.bal) filter (where g.d > z.effective_date)) as low
    from (select q.effective_date as d, sum(q.amount_minor) as s,
                 sum(sum(q.amount_minor)) over (order by q.effective_date) as bal
          from public.ledger_account la
          join public.ledger_posting q on q.ledger_account_id = la.id
          where la.claim_item_id = z.claim_item_id and la.book = 'debtor_receivable'
          group by q.effective_date) g) w
  where w.low - z.cum < 0;
  if v_bad is not null then
    raise exception 'allocation: payment % would take an item below what it owes as a whole', v_bad
      using errcode = 'LG007';
  end if;

  -- 1343-1 « Le paiement partiel s'impute d'abord sur les intérêts »: no principal of an item while that item's
  -- interest still has something available at the date, after this run's earlier plans (same file: date order) and
  -- this entry's own interest lines.
  select coalesce(array_agg(c.code) filter (where c.family = 'interest'), '{}'),
         coalesce(array_agg(c.code) filter (where c.family = 'principal'), '{}')
  into v_interest, v_principal from public.ledger_component c;
  drop table if exists pg_temp._alloc_int;
  create temp table _alloc_int on commit drop as
  select x.payment_id, x.ord, x.effective_date, la.id as ledger_account_id
  from (select distinct t.payment_id, t.ord, t.effective_date, l.claim_item_id
        from pg_temp._alloc_t t join pg_temp._alloc_line l on l.payment_id = t.payment_id
        where l.component = any (v_principal)) x
  join public.ledger_account la on la.claim_item_id = x.claim_item_id and la.component = any (v_interest);
  if exists (select from pg_temp._alloc_int) then
    analyze pg_temp._alloc_int;
    drop table if exists pg_temp._alloc_cum;
    create temp table _alloc_cum on commit drop as
    select y.ledger_account_id, y.ord, sum(y.amount) over (partition by y.ledger_account_id order by y.ord) as cum
    from (select la.id as ledger_account_id, t.ord, sum(l.amount_minor) as amount
          from pg_temp._alloc_t t
          join pg_temp._alloc_line l on l.payment_id = t.payment_id and l.component = any (v_interest)
          join public.ledger_account la on la.claim_item_id = l.claim_item_id and la.component = l.component
          group by la.id, t.ord) y;
    create index on pg_temp._alloc_cum (ledger_account_id, ord);
    analyze pg_temp._alloc_cum;
    select min(z.payment_id::text) into v_bad
    from (select i.payment_id,
                 private.receivable_low(i.ledger_account_id, i.effective_date)
                 - coalesce((select c.cum from pg_temp._alloc_cum c
                             where c.ledger_account_id = i.ledger_account_id and c.ord <= i.ord
                             order by c.ord desc limit 1), 0) as left_over
          from pg_temp._alloc_int i) z
    where z.left_over > 0;
    if v_bad is not null then
      raise exception 'allocation: payment % pays principal while interest of the same debt is due (1343-1)', v_bad
        using errcode = 'LG006';
    end if;
  end if;

  -- One allocation entry per (payment, file): 4710 pool debit, 4670 credit to the file's client, one 1100 credit per
  -- (item, component) in the waterfall's order, one 3100 debit per component.
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, account_id,
                                  payment_id, source_type, source_id, engine_version, inputs_hash)
  select t.entry_no, p_organization_id, 'allocation', t.effective_date,
         'alloc:' || p_run_id || ':' || t.payment_id || ':' || t.account_id, t.account_id, t.payment_id,
         'allocation_run', p_run_id::text, p_engine_version, t.inputs_hash
  from pg_temp._alloc_t t where t.outcome = 'allocate';
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, claim_item_id, component)
  select t.entry_no, 1, 'unallocated_payment', s.total, t.account_currency, null::uuid, null::text
  from pg_temp._alloc_t t
  join (select l.payment_id, sum(l.amount_minor) as total from pg_temp._alloc_line l group by l.payment_id) s
    on s.payment_id = t.payment_id
  union all
  select t.entry_no, 2, 'client_payable', -s.total, t.account_currency, null, null
  from pg_temp._alloc_t t
  join (select l.payment_id, sum(l.amount_minor) as total from pg_temp._alloc_line l group by l.payment_id) s
    on s.payment_id = t.payment_id
  union all
  select t.entry_no, 2 + row_number() over (partition by l.payment_id order by l.seq), 'debtor_receivable',
         -l.amount_minor, t.account_currency, l.claim_item_id, l.component
  from pg_temp._alloc_t t join pg_temp._alloc_line l on l.payment_id = t.payment_id
  union all
  select t.entry_no, 2 + n.lines + row_number() over (partition by c.payment_id order by c.component), 'owner_claim',
         c.total, t.account_currency, null, c.component
  from (select l.payment_id, l.component, sum(l.amount_minor) as total from pg_temp._alloc_line l
        group by l.payment_id, l.component) c
  join pg_temp._alloc_t t on t.payment_id = c.payment_id
  join (select l.payment_id, count(*)::integer as lines from pg_temp._alloc_line l group by l.payment_id) n
    on n.payment_id = c.payment_id;

  drop table if exists pg_temp._alloc_posted;
  create temp table _alloc_posted on commit drop as
  select x.entry_no, x.entry_id, x.created from private.ledger_post_set() x;

  insert into private.allocation_plan (entry_id, run_id, payment_id, account_id, effective_date, policy, designation,
                                       inputs_hash, engine_version)
  select x.entry_id, p_run_id, t.payment_id, t.account_id, t.effective_date, t.policy, t.designation, t.inputs_hash,
         p_engine_version
  from pg_temp._alloc_posted x join pg_temp._alloc_t t on t.entry_no = x.entry_no
  where x.created;

  -- R124-5: the client is told of each allocation (exactly once: unique entry).
  insert into public.client_notification (organization_id, client_organization_id, portfolio_id, account_id,
                                          payment_id, ledger_entry_id, kind)
  select p_organization_id, t.client_organization_id, t.portfolio_id, t.account_id, t.payment_id, x.entry_id,
         'payment_allocated'
  from pg_temp._alloc_posted x join pg_temp._alloc_t t on t.entry_no = x.entry_no
  where x.created;

  -- The payments' states (design §7): allocated (nothing left), partially allocated (an overpayment, kept in 4710:
  -- founder #8), or still matched with the reason the engine gave (gated, nothing due, credit note to apply).
  update public.payment p set
    status = case when u.allocated + coalesce(s.total, 0) = 0 then 'matched'
                  when u.amount_minor - u.moved - coalesce(s.total, 0) = 0 then 'allocated'
                  else 'partially_allocated' end,
    -- an overpayment ops sent to another file that is now gated or owes nothing: back to where ops sent it from
    -- (the payment's own file is not the one held or closed)
    review_reason = case when t.outcome <> 'allocate' and t.account_id <> p.account_id
                           then case when u.allocated = 0 then 'nothing_due' else 'overpayment' end
                         when t.outcome <> 'allocate' then t.outcome
                         when u.amount_minor - u.moved - coalesce(s.total, 0) = 0 then null
                         else 'overpayment' end,
    -- ops' decisions are consumed by an allocation (or void back from another file); a payment stopped at another
    -- gate of its own file keeps them, so the gates ops released stay released (review fix)
    allocation_instruction = case when t.outcome = 'allocate' or t.account_id <> p.account_id then null
                                  else p.allocation_instruction end
  from pg_temp._alloc_t t
  join pg_temp._alloc_u u on u.payment_id = t.payment_id
  left join (select l.payment_id, sum(l.amount_minor) as total from pg_temp._alloc_line l group by l.payment_id) s
    on s.payment_id = t.payment_id
  where p.id = t.payment_id;

  select jsonb_build_object(
    'run_id', p_run_id,
    'payments', count(*),
    'entries', (select count(*) from pg_temp._alloc_posted where created),
    'allocated_minor', coalesce((select sum(l.amount_minor) from pg_temp._alloc_line l), 0)::text,
    'outcomes', coalesce((select jsonb_object_agg(o.outcome, o.n) from (
                  select t.outcome, count(*) as n from pg_temp._alloc_t t group by t.outcome) o), '{}'),
    'overpayments', count(*) filter (where t.outcome = 'allocate'
                                      and u.amount_minor - u.moved > (select sum(l.amount_minor) from pg_temp._alloc_line l
                                                                       where l.payment_id = t.payment_id)))
  into v_summary
  from pg_temp._alloc_t t join pg_temp._alloc_u u on u.payment_id = t.payment_id;
  update public.allocation_run set summary = v_summary, finished_at = now() where id = p_run_id;
  return v_summary;
end;
$$;


------------------------------------------------------------------------------------------
-- H11: MONEY-2, one recording per proof
------------------------------------------------------------------------------------------

-- public.record_client_payment and public.record_client_refund, redefined from 20261124090000_client_payments.sql
-- (lines 1940 and 2158; same signatures and settings, SECURITY DEFINER, search_path '' and their grants restated below).
-- M2c-7f-1 (H11; ADR-0014 « M2c-7c-1 », Left open, MONEY-2): evidence_already_used, keyed on the proof's content (its
-- SHA-256 among the client's proofs of that kind), after the locks; the refund's per document (one transfer refunding
-- two documents stays allowed). Nothing else changes.
create or replace function public.record_client_payment(p_idempotency_key text, p_client_organization_id uuid,
                                                        p_currency char(3), p_amount_text text, p_value_date date,
                                                        p_evidence_document_id uuid, p_documents uuid[],
                                                        p_designation_document_id uuid, p_recover_written_off uuid[],
                                                        p_expected_open_text text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  c public.organization;
  v_request jsonb;
  v_result jsonb;
  v_amount bigint := private.euros_to_minor(p_amount_text);
  v_own uuid;
  v_docs jsonb;
  v_free jsonb;
  v_rec jsonb;
  v_why record;
  v_rows jsonb;
  v_used date;
begin
  select * into c from public.organization where id = p_client_organization_id and kind <> 'servicer';
  if not found or c.servicer_organization_id is null
     or not private.has_role(c.servicer_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('client_organization_id', p_client_organization_id, 'currency', p_currency,
                                  'amount', p_amount_text, 'value_date', p_value_date,
                                  'evidence_document_id', p_evidence_document_id, 'documents', p_documents,
                                  'designation_document_id', p_designation_document_id,
                                  'recover_written_off', p_recover_written_off, 'expected_open', p_expected_open_text,
                                  'reason', p_reason);
  v_result := private.command_replay('record_client_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_amount is null or v_amount <= 0 then
    raise exception 'client payment refused: bad_amount' using errcode = 'check_violation';
  end if;
  if p_value_date is null or p_value_date > private.paris_today() then
    raise exception 'client payment refused: bad_date' using errcode = 'check_violation';
  end if;
  if p_expected_open_text is null or p_expected_open_text !~ '^[0-9]{1,16}$' or p_currency is null
     or array_position(p_documents, null) is not null or array_position(p_recover_written_off, null) is not null
     or coalesce(cardinality(p_documents), 0) <> (select count(distinct x) from unnest(p_documents) x)
     or coalesce(cardinality(p_recover_written_off), 0) <> (select count(distinct x) from unnest(p_recover_written_off) x)
     or length(p_reason) > 2000 then
    raise exception 'client payment refused: bad_request' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, c.id, 'client_payment_evidence') then
    raise exception 'client payment refused: evidence_required' using errcode = 'check_violation';
  end if;
  select b.id into v_own from public.servicer_billing_settings s
  join public.bank_account b on b.id = s.own_bank_account_id
  where s.organization_id = c.servicer_organization_id and b.purpose = 'own' and b.status = 'active'
    and b.currency = p_currency;
  if v_own is null then
    raise exception 'client payment refused: no_own_account' using errcode = 'check_violation';
  end if;
  if (coalesce(cardinality(p_documents), 0) > 0 or coalesce(cardinality(p_recover_written_off), 0) > 0)
     and (p_designation_document_id is null
          or not private.client_document_of(p_designation_document_id, c.id, 'payment_designation_evidence')) then
    raise exception 'client payment refused: designation_evidence_required' using errcode = 'check_violation';
  end if;
  -- the locks of an approval (the plans of approved runs, the documents' open parts): allocation, then remit
  perform private.remittance_command_locks(c.servicer_organization_id, true);
  -- (M2c-7f-1, H11: MONEY-2) the same proof recorded twice is refused: another proof of the client whose file has this
  -- one's SHA-256 (the same file uploaded again — the sheet uploads the proof at each recording: two uploads are two
  -- documents) already sources a client payment (its entry's source, by ledger_entry_client_payment_source_idx) —
  -- under the locks, so a second session waits and then reads the first one's commit. (This document itself recorded
  -- again under another key is not refused: ADR-0014 « M2c-7f-1 », deviation — 045–047c record several payments on
  -- each client's one proof document.)
  select e.effective_date into v_used
  from (select d.id from public.document d
        where d.client_organization_id = c.id and d.kind = 'client_payment_evidence'
          and d.sha256 = (select x.sha256 from public.document x where x.id = p_evidence_document_id)
          and d.id <> p_evidence_document_id
        offset 0) d
  cross join lateral (select q.effective_date from public.ledger_entry q
                      where q.source_id = d.id::text and q.entry_type = 'client_payment_own' and q.source_type = 'document'
                      offset 0) e
  order by e.effective_date
  limit 1;
  if v_used is not null then
    raise exception 'client payment refused: evidence_already_used' using errcode = 'check_violation',
      detail = to_char(v_used, 'YYYY-MM-DD');
  end if;
  v_docs := private.client_payment_docs(c.id, p_currency, p_value_date);
  v_free := private.client_payment_free(v_docs);
  v_rec := private.client_payment_recoveries(c.id, p_currency, p_recover_written_off, p_value_date);
  select * into v_why from private.client_payment_named_refusal(v_docs, p_documents, p_recover_written_off, v_rec);
  if v_why.code is not null then
    raise exception 'client payment refused: %', v_why.code using errcode = 'check_violation',
      detail = coalesce(v_why.detail, '');
  end if;
  if private.client_payment_considered(v_free, p_documents, v_rec) <> p_expected_open_text::bigint then
    raise exception 'client payment refused: open_changed' using errcode = 'check_violation';
  end if;
  v_rows := private.client_payment_rows(v_free, v_amount, p_documents, v_rec,
                                        private.client_proceeding_stands(c.id, p_value_date), p_value_date);
  v_result := private.client_payment_post(
    'client_payment_own', c.servicer_organization_id, c.id, p_currency, v_amount, p_value_date, v_rows, v_docs,
    'cpay:' || md5(p_idempotency_key), 'document', p_evidence_document_id::text,
    'Règlement du client par virement sur le compte du cabinet (valeur ' || to_char(p_value_date, 'DD/MM/YYYY') || ')',
    v_own);
  perform private.ledger_check_now();
  perform private.command_record('record_client_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

create or replace function public.record_client_refund(p_idempotency_key text, p_document_id uuid, p_amount_text text,
                                                       p_paid_on date, p_evidence_document_id uuid,
                                                       p_expected_owed_text text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  v_kind text;
  v_org uuid;
  v_client uuid;
  v_currency char(3);
  v_request jsonb;
  v_result jsonb;
  v_amount bigint := private.euros_to_minor(p_amount_text);
  v_own uuid;
  v_owed bigint;
  v_run text;
  v_entry uuid;
  v_since date;
  v_used date;
begin
  select case i.kind when 'credit_note' then 'credit_note' else 'invoice' end, i.organization_id,
         i.client_organization_id, i.currency
  into v_kind, v_org, v_client, v_currency
  from public.commission_invoice i where i.id = p_document_id;
  if v_kind is null then
    select 'client_credit', c.organization_id, c.client_organization_id, c.currency
    into v_kind, v_org, v_client, v_currency
    from public.client_credit c where c.id = p_document_id;
  end if;
  if v_kind is null or not private.has_role(v_org, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('document_id', p_document_id, 'amount', p_amount_text, 'paid_on', p_paid_on,
                                  'evidence_document_id', p_evidence_document_id, 'expected_owed', p_expected_owed_text,
                                  'reason', p_reason);
  v_result := private.command_replay('record_client_refund', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_amount is null or v_amount <= 0 then
    raise exception 'client refund refused: bad_amount' using errcode = 'check_violation';
  end if;
  if p_paid_on is null or p_paid_on > private.paris_today() then
    raise exception 'client refund refused: bad_date' using errcode = 'check_violation';
  end if;
  if p_expected_owed_text is null or p_expected_owed_text !~ '^[0-9]{1,16}$' or length(p_reason) > 2000 then
    raise exception 'client refund refused: bad_request' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, v_client, 'client_refund_evidence') then
    raise exception 'client refund refused: evidence_required' using errcode = 'check_violation';
  end if;
  select b.id into v_own from public.servicer_billing_settings s
  join public.bank_account b on b.id = s.own_bank_account_id
  where s.organization_id = v_org and b.purpose = 'own' and b.status = 'active' and b.currency = v_currency;
  if v_own is null then
    raise exception 'client refund refused: no_own_account' using errcode = 'check_violation';
  end if;
  perform private.remittance_command_locks(v_org, true);
  -- (M2c-7f-1, H11: MONEY-2) the same proof twice for this document is refused: this credit's or credit note's own
  -- refunds (by the document's key), each one's entry and its proof, compared by the file's SHA-256 (the same file
  -- uploaded again, another document); one transfer refunding two documents is two recordings of one proof, each of
  -- its own document (allowed); this proof document itself again (a refund in parts on one proof: 045's) allowed
  select s.settled_on into v_used
  from (select y.entry_id, y.settled_on from public.commission_settlement y
        where y.document_id = p_document_id and y.kind = 'refund' offset 0) s
  cross join lateral (select q.source_id from public.ledger_entry q
                      where q.id = s.entry_id and q.entry_type = 'client_refund_own' and q.source_type = 'document'
                      offset 0) e
  cross join lateral (select d.sha256 from public.document d
                      where d.id = e.source_id::uuid and d.client_organization_id = v_client
                        and d.kind = 'client_refund_evidence' and d.id <> p_evidence_document_id offset 0) d
  where d.sha256 = (select x.sha256 from public.document x where x.id = p_evidence_document_id)
  order by s.settled_on
  limit 1;
  if v_used is not null then
    raise exception 'client refund refused: evidence_already_used' using errcode = 'check_violation',
      detail = to_char(v_used, 'YYYY-MM-DD');
  end if;
  v_owed := case v_kind when 'credit_note' then private.document_open(p_document_id)
                        when 'client_credit' then private.client_credit_open(p_document_id) else 0 end;
  if coalesce(v_owed, 0) <= 0 then
    raise exception 'client refund refused: nothing_owed' using errcode = 'check_violation';
  end if;
  -- (review round 4) never before what it pays back existed: the credit's receipt (its payment's entry, by its primary
  -- key) or the credit note's issue — the append-only ledger would carry a refund of nothing on the days between
  v_since := case v_kind
               when 'credit_note' then (select i.issue_date from public.commission_invoice i where i.id = p_document_id)
               else (select e.effective_date
                     from (select c.entry_id from public.client_credit c where c.id = p_document_id offset 0) c
                     cross join lateral (select q.effective_date from public.ledger_entry q
                                         where q.id = c.entry_id offset 0) e) end;
  if v_since is null or p_paid_on < v_since then
    raise exception 'client refund refused: bad_date' using errcode = 'check_violation',
      detail = coalesce(to_char(v_since, 'YYYY-MM-DD'), '');
  end if;
  if v_kind = 'credit_note' then
    select f.run_number into v_run from private.document_in_flight_run(p_document_id, v_client, v_currency) f limit 1;
    if v_run is not null then
      raise exception 'client refund refused: in_flight' using errcode = 'check_violation', detail = v_run;
    end if;
  end if;
  if v_owed <> p_expected_owed_text::bigint then
    raise exception 'client refund refused: owed_changed' using errcode = 'check_violation';
  end if;
  if v_amount > v_owed then
    raise exception 'client refund refused: amount_exceeds_owed' using errcode = 'check_violation',
      detail = v_owed::text;
  end if;
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason)
  values (1, v_org, 'client_refund_own', p_paid_on, 'crfd:' || md5(p_idempotency_key), v_client, 'document',
          p_evidence_document_id::text,
          'Remboursement au client par virement depuis le compte du cabinet (le ' || to_char(p_paid_on, 'DD/MM/YYYY')
          || ')');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, case v_kind when 'credit_note' then 'commission_receivable' else 'client_credit_owed' end, v_amount,
     v_currency, null),
    (1, 2, 'own_cash', -v_amount, v_currency, v_own);
  select x.entry_id into v_entry from private.ledger_post_set() x;
  insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id,
                                            entry_id, kind, amount_minor, vat_moved_minor, settled_on)
  values (v_org, v_client, v_kind, p_document_id, v_entry, 'refund', v_amount, 0, p_paid_on);
  perform private.ledger_check_now();
  v_result := jsonb_build_object('entry_id', v_entry, 'owed_after_minor', (v_owed - v_amount)::text);
  perform private.command_record('record_client_refund', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- H20: the prepare's loader reads by key
------------------------------------------------------------------------------------------

-- the draft's reserved items as the prepare's loader reads them (jobs/remittances.py load_facts): each item's entry,
-- the entry it reverses, its payment and its advance (client_advance by its entry, unique) by key in fenced laterals,
-- the items by the draft's key (remittance_pending_run_idx) — as the worker's statement, a generic plan under the
-- 7b round 2 plant read the whole queue (10,013 rows for one draft's items)
create function private.draft_pending_items(p_run_id uuid)
returns table (ledger_entry_id uuid, kind text, amount_minor bigint, posted_at timestamptz, effective_date date,
               account_id uuid, payment_id uuid, encaissement_date date, reverses_entry_id uuid, mandate_id uuid,
               cause text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select q.ledger_entry_id, q.kind, q.amount_minor, q.posted_at, e.effective_date, coalesce(e.account_id, p.account_id),
         coalesce(e.payment_id, oe.payment_id), private.encaissement_date(p.booking_date, p.value_date),
         e.reverses_entry_id, ca.mandate_id, ca.cause
  from (select x.ledger_entry_id, x.kind, x.amount_minor, x.posted_at from private.remittance_pending x
        where x.draft_run_id = p_run_id offset 0) q
  cross join lateral (select y.id, y.effective_date, y.account_id, y.payment_id, y.reverses_entry_id
                      from public.ledger_entry y where y.id = q.ledger_entry_id offset 0) e
  left join lateral (select y.payment_id from public.ledger_entry y where y.id = e.reverses_entry_id offset 0) oe on true
  left join lateral (select y.account_id, y.booking_date, y.value_date from public.payment y
                     where y.id = coalesce(e.payment_id, oe.payment_id) offset 0) p on true
  left join lateral (select a.mandate_id, a.cause from public.client_advance a
                     where a.entry_id = case q.kind when 'client_advance' then e.id
                                                    when 'client_advance_reversal' then e.reverses_entry_id end
                     offset 0) ca on true;
$$;

-- the terms of the prepare's mandates, by each mandate's key (the loader's other read of 7b round 2's list:
-- mandate_terms 10,098 under the plant), in their order
create function private.mandates_terms(p_mandate_ids uuid[])
returns table (id uuid, mandate_id uuid, valid_from date, valid_to date, remittance_max_days integer,
               commission_schedule jsonb, remittance_terms jsonb, commission_clause_ref text,
               remittance_clause_ref text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select t.id, t.mandate_id, t.valid_from, t.valid_to, t.remittance_max_days, t.commission_schedule, t.remittance_terms,
         t.commission_clause_ref, t.remittance_clause_ref
  from (select distinct m.id from unnest(coalesce(p_mandate_ids, '{}')) m (id)) m
  cross join lateral (select q.id, q.mandate_id, q.valid_from, q.valid_to, q.remittance_max_days, q.commission_schedule,
                             q.remittance_terms, q.commission_clause_ref, q.remittance_clause_ref
                      from public.mandate_terms q where q.mandate_id = m.id offset 0) t
  order by t.valid_from;
$$;

-- private.remittance_record_draft, redefined from 20261127090000_set_off_bars.sql (line 663; same signature, SECURITY
-- DEFINER, search_path '' and its grants restated below). M2c-7f-1 (H20; ADR-0014 « M2c-7b review fixes, round 2 »,
-- Left open: write_draft's remittance_pending 10,006 under the plant): `set enable_seqscan = off` and the reserved items
-- by the draft's key in a fence. The same count.
create or replace function private.remittance_record_draft(p_run_id uuid, p_token uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  r public.remittance_run;
  v_lines integer;
  v_gross bigint;
  v_reserved integer;
begin
  select * into r from public.remittance_run where id = p_run_id for update;
  if not found or r.status <> 'draft' or r.job is distinct from 'prepare' or r.job_token is distinct from p_token then
    raise exception 'remittance draft %: no longer this job''s', p_run_id using errcode = '40001';
  end if;
  select count(*), coalesce(sum(d.amount_minor), 0) into v_lines, v_gross
  from private.remittance_draft_line d where d.run_id = p_run_id;
  -- each reserved item has its line (one keyed probe per item, whatever the statistics)
  -- (M2c-7f-1, H20) the draft's items by its key in a fence (remittance_pending_run_idx)
  select count(*) into v_reserved
  from (select x.ledger_entry_id, x.amount_minor from private.remittance_pending x
        where x.draft_run_id = p_run_id offset 0) q
  cross join lateral (select 1 from private.remittance_draft_line d where d.run_id = p_run_id
                        and d.ledger_entry_id = q.ledger_entry_id and d.amount_minor = q.amount_minor
                      limit 1) d;
  if v_lines <> r.item_count or v_reserved <> r.item_count or v_gross <> (p ->> 'gross')::bigint
     or v_lines <> (p ->> 'line_count')::integer then
    raise exception 'remittance draft %: its lines are not the items reserved (% lines, % reserved, % items)',
      p_run_id, v_lines, v_reserved, r.item_count using errcode = '23514';
  end if;
  insert into private.remittance_draft (run_id, vat_rate, documents, key_states, history_seq, plan, vat_on_debits,
                                        proceeding_opened_on, opening_on, set_off_barred)
  values (p_run_id, (p ->> 'vat_rate')::numeric, coalesce(p -> 'documents', '[]'), coalesce(p -> 'key_states', '[]'),
          coalesce((p ->> 'history_seq')::bigint, 0), coalesce(p -> 'plan', '{}'),
          coalesce((p ->> 'vat_on_debits')::boolean, false), (p ->> 'proceeding_opened_on')::date,
          (p ->> 'opening_on')::date, nullif(p ->> 'set_off_barred', ''));
  insert into private.remittance_draft_repricing (run_id, line_run_id, line_no, ledger_entry_id, commission_minor,
                                                  commission_state, commission_reason, parts, invoiced)
  select p_run_id, (x ->> 'run_id')::uuid, (x ->> 'line_no')::integer, (x ->> 'ledger_entry_id')::uuid,
         (x ->> 'commission')::bigint, x ->> 'state', x ->> 'reason', coalesce(x -> 'parts', '[]'),
         coalesce((x ->> 'invoiced')::boolean, false)
  from jsonb_array_elements(coalesce(p -> 'repricing', '[]')) x;
  update public.remittance_run set
    prepared_at = clock_timestamp(), job = null, job_token = null, job_queued_at = null, version = version + 1,
    line_count = v_lines, gross_minor = v_gross,
    invoice_ht_minor = (p ->> 'invoice_ht')::bigint, invoice_vat_minor = (p ->> 'invoice_vat')::bigint,
    invoice_ttc_minor = (p ->> 'invoice_ttc')::bigint, credit_ht_minor = (p ->> 'credit_ht')::bigint,
    credit_vat_minor = (p ->> 'credit_vat')::bigint, credit_ttc_minor = (p ->> 'credit_ttc')::bigint,
    commission_taken_minor = (p ->> 'taken')::bigint, advance_recovered_minor = (p ->> 'advances')::bigint,
    refund_minor = (p ->> 'refunds')::bigint, settlement_minor = (p ->> 'settlement')::bigint,
    net_minor = (p ->> 'net')::bigint, vat_rate = (p ->> 'vat_rate')::numeric,
    earliest_deadline = (p ->> 'earliest_deadline')::date,
    earliest_latest_execution_date = (p ->> 'earliest_latest_execution_date')::date,
    unmeetable_count = coalesce((p ->> 'unmeetable')::integer, 0),
    blockers = coalesce(array(select jsonb_array_elements_text(p -> 'blockers')), '{}'),
    commission_blockers = coalesce(array(select jsonb_array_elements_text(p -> 'commission_blockers')), '{}'),
    engine_version = p ->> 'engine_version', inputs_hash = p ->> 'inputs_hash',
    payout_account_id = (p ->> 'payout_account_id')::uuid, last_failure = null
  where id = p_run_id;
end;
$$;

------------------------------------------------------------------------------------------
-- H22: the « Lier » sheet's files carry the client's mandate's end (TUI-5)
------------------------------------------------------------------------------------------

-- public.match_queue_accounts and public.search_payment_files, from 20261109150000_payment_matching.sql (lines 902 and
-- 930; dropped and created: each returns mandate_ended_on, before found_by; SECURITY DEFINER, search_path '' and their
-- grants restated below). M2c-7f-1 (H22; ADR-0014 « M2c-7d-1 review fixes », TUI-5): the sheet's twin of the gate
-- (matching.ts gatingOutcome) words the hold after the end. Nothing else changes.
drop function public.search_payment_files(uuid, text);
drop function public.match_queue_accounts(uuid[]);
create function public.match_queue_accounts(p_account_ids uuid[])
returns table (account_id uuid, external_ref text, status text, client_name text, debtor_name text, currency char(3),
               balance_minor text, pending_minor text, rf text, servicing_start date, holds text[],
               mandate_ended_on date)
language sql
stable
security definer
set search_path = ''
as $$
  select a.id, a.external_ref, a.status, c.legal_name,
         (select min(pa.display_name) from public.account_party ap join public.party pa on pa.id = ap.party_id
          where ap.account_id = a.id and ap.role = 'borrower'),
         a.currency,
         coalesce((select sum(lp.amount_minor) from public.ledger_account la
                   join public.ledger_posting lp on lp.ledger_account_id = la.id
                   where la.account_id = a.id and la.book = 'debtor_receivable'), 0)::text,
         coalesce((select sum(p.amount_minor) from public.payment p where p.account_id = a.id and p.status = 'matched'), 0)::text,
         (select r.rf from public.payment_reference r where r.account_id = a.id and r.status = 'active'),
         (select min(o.valid_from) from public.claim_ownership_period o where o.account_id = a.id),
         coalesce((select array_agg(h.kind order by h.kind) from public.account_hold h
                   where h.account_id = a.id and h.ended_at is null
                     and h.kind in ('surendettement', 'collective_proceeding')), '{}'),
         -- (M2c-7f-1, H22) the earliest end of the client's mandate (private.client_end_event, by the client's key), as
         -- private.gate_assignments reads it: a payment received on or after it is held client_mandate_ended
         (select e.effective_date from private.client_end_event(a.client_organization_id, 'infinity') e)
  from public.account a
  join public.organization c on c.id = a.client_organization_id
  where a.id = any (p_account_ids[1:100])
    and a.organization_id = any (private.money_staff_org_ids());
$$;

create function public.search_payment_files(p_payment_id uuid, p_query text)
returns table (account_id uuid, external_ref text, status text, client_name text, debtor_name text, currency char(3),
               balance_minor text, pending_minor text, rf text, servicing_start date, holds text[],
               mandate_ended_on date, found_by text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid;
  v_key text := private.ref_key(coalesce(p_query, ''));
  v_rf text := private.rf_normalise(coalesce(p_query, ''));
begin
  select p.organization_id into v_org from public.payment p
  where p.id = p_payment_id and p.organization_id = any (private.money_staff_org_ids());
  if v_org is null or length(btrim(coalesce(p_query, ''))) < 3 then
    return;
  end if;
  return query
  with hits as (
    select a.id, 'reference'::text as found_by, 1 as rank_ from public.account a
    where a.organization_id = v_org and private.ref_key(a.external_ref) = v_key
    union all
    select i.account_id, 'invoice', 2 from public.claim_item i
    join public.account a on a.id = i.account_id and a.organization_id = v_org
    where private.ref_key(i.ref) = v_key
    union all
    select r.account_id, 'rf', 0 from public.payment_reference r where r.organization_id = v_org and r.rf = v_rf
    union all
    select x.account_id, 'name', 3 from (
      select ap.account_id, max(extensions.similarity(pa.display_name, p_query)) as sim
      from public.party pa join public.account_party ap on ap.party_id = pa.id
      where pa.organization_id = v_org and pa.display_name operator(extensions.%) p_query
      group by ap.account_id order by sim desc limit 10) x
  ), best as (
    select h.id, min(h.rank_) as rank_, (array_agg(h.found_by order by h.rank_))[1] as found_by
    from hits h group by h.id order by min(h.rank_) limit 10
  )
  select q.account_id, q.external_ref, q.status, q.client_name, q.debtor_name, q.currency, q.balance_minor,
         q.pending_minor, q.rf, q.servicing_start, q.holds, q.mandate_ended_on, b.found_by
  from best b
  join public.match_queue_accounts(array[b.id]) q on q.account_id = b.id
  where q.status <> 'staged'
  order by b.rank_, q.external_ref;
end;
$$;


------------------------------------------------------------------------------------------
-- H16: « Avances »' totals and the chip from the ledger (CCS-2)
------------------------------------------------------------------------------------------

-- per (client, currency): what the clients owe back of their advances (the balance of the servicer's 4112[c] accounts,
-- client_advance_receivable) and what is owed back to them (419[c], client_credit_owed, as a positive amount), read by
-- the accounts' key — the nightly's advance_ledger and client_credit_ledger prove them equal to Σ advance_open and
-- Σ client_credit_open. Before (CCS-2: ADR-0014 « M2c-7b », Left open), « Avances »' totals and the « Reversements »
-- chip summed private.advance_open over every advance the servicer ever recorded, settled ones included. Money staff
-- at aal2.
create function public.client_advance_totals(p_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
begin
  if p_organization_id is null or not private.has_role(p_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'advances', (select coalesce(jsonb_agg(jsonb_build_object('client_id', x.client, 'currency', x.currency,
                                                              'open_minor', x.total::text)
                                           order by x.client, x.currency), '[]')
                 from (select la.client_organization_id as client, la.currency, sum(p.s) as total
                       from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
                             where l.organization_id = p_organization_id and l.book = 'client_advance_receivable'
                             offset 0) la
                       cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                                           where q.ledger_account_id = la.id offset 0) p
                       group by la.client_organization_id, la.currency) x
                 where x.total > 0),
    'credits', (select coalesce(jsonb_agg(jsonb_build_object('client_id', x.client, 'currency', x.currency,
                                                             'owed_minor', x.total::text)
                                          order by x.client, x.currency), '[]')
                from (select la.client_organization_id as client, la.currency, -sum(p.s) as total
                      from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
                            where l.organization_id = p_organization_id and l.book = 'client_credit_owed' offset 0) la
                      cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                                          where q.ledger_account_id = la.id offset 0) p
                      group by la.client_organization_id, la.currency) x
                where x.total > 0));
end;
$$;


-- public.client_advances, redefined from 20261123090000_advance_recovery.sql (line 433; same signature and settings,
-- SECURITY DEFINER, search_path '' and its grants restated below). M2c-7f-1 (H16, CCS-2): its totals are the 4112[c]
-- balances, as public.client_advance_totals reads them; its rows (the client's or the servicer's page, its open part
-- per row) unchanged. (Review round 1, TEST-H16-CLIENT-ADVANCES) a client's page read by the client's key.
create or replace function public.client_advances(p_organization_id uuid, p_client uuid default null,
                                                  p_open_only boolean default true, p_after jsonb default null,
                                                  p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_open_only boolean := coalesce(p_open_only, true);
  v_at timestamptz;
  v_id uuid;
  v_rows jsonb;
  v_next jsonb;
begin
  if p_organization_id is null or not private.has_role(p_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_after is not null then
    begin
      v_at := (p_after ->> 'created_at')::timestamptz;
      v_id := (p_after ->> 'id')::uuid;
    exception when others then
      raise exception 'advances: a bad page cursor' using errcode = '22023';
    end;
  end if;
  -- (review round 1, TEST-H16-CLIENT-ADVANCES) the page by its key: a client's page reads the client's advances by
  -- client_advance_client_idx (fenced, the servicer checked outside, as public.client_space_advances), the servicer's
  -- page its advances by client_advance_org_idx in their order; each branch gated by p_client (before, one read for
  -- both, `p_client is null or …`: a generic plan read the client's page through the servicer's index, every advance
  -- of the servicer under its statistics)
  with page as materialized (
    select a.id, a.created_at, row_number() over (order by a.created_at desc, a.id desc) as n
    from (select c.id, c.created_at
          from (select q.id, q.created_at
                from (select x.id, x.created_at, x.organization_id from public.client_advance x
                      where x.client_organization_id = p_client offset 0) q
                where p_client is not null and q.organization_id = p_organization_id
                  and (v_at is null or (q.created_at, q.id) < (v_at, v_id))
                  and (not v_open_only or private.advance_open(q.id) > 0)
                order by q.created_at desc, q.id desc
                limit v_limit + 1) c
          union all
          select s.id, s.created_at
          from (select q.id, q.created_at from public.client_advance q
                where p_client is null and q.organization_id = p_organization_id
                  and (v_at is null or (q.created_at, q.id) < (v_at, v_id))
                  and (not v_open_only or private.advance_open(q.id) > 0)
                order by q.created_at desc, q.id desc
                limit v_limit + 1) s) a)
  select coalesce(jsonb_agg(private.advance_row(p.id) order by p.n) filter (where p.n <= v_limit), '[]'),
         (select jsonb_build_object('created_at', x.created_at, 'id', x.id) from page x where x.n = v_limit
          and exists (select 1 from page y where y.n = v_limit + 1))
  into v_rows, v_next
  from page p;
  return jsonb_build_object(
    'rows', v_rows, 'next', v_next,
    -- (M2c-7f-1, H16; CCS-2) the totals from the 4112[c] balances (the servicer's client_advance_receivable accounts
    -- by their key; the nightly's advance_ledger proves them Σ advance_open), never every advance one by one
    'totals', (select coalesce(jsonb_agg(jsonb_build_object('client_id', t.client, 'currency', t.currency,
                                                            'open_minor', t.open_minor::text)
                                         order by t.client, t.currency), '[]')
               from (select la.client_organization_id as client, la.currency, sum(p.s) as open_minor
                     from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
                           where l.organization_id = p_organization_id and l.book = 'client_advance_receivable'
                             and (p_client is null or l.client_organization_id = p_client) offset 0) la
                     cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                                         where q.ledger_account_id = la.id offset 0) p
                     group by la.client_organization_id, la.currency) t
               where t.open_minor > 0),
    'can_write_off', private.has_role(p_organization_id, array['admin']));
end;
$$;

------------------------------------------------------------------------------------------
-- H17: a repayment-request letter whose job died is re-queued
------------------------------------------------------------------------------------------

-- every request not withdrawn whose letter is not drawn an hour after it was recorded (the undrawn requests by
-- advance_repayment_request_undrawn_idx, its predicate stated literally) and whose message no longer waits in the
-- queue (its job died: archived after its retries): the message public.request_advance_repayment sends, sent again.
-- The letter's job holds the request's row, draws once, skips a withdrawn request and sets the document once
-- (private.repayment_request_job, private.repayment_request_document_done): a message sent twice draws one letter.
-- The nightly's repayment_request_document_missing stays (a letter still missing the next night). Hourly (pg_cron).
create function private.requeue_repayment_letters()
returns integer
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  r record;
  v_n integer := 0;
begin
  for r in
    select q.id, q.organization_id
    from (select x.id, x.organization_id from public.advance_repayment_request x
          where x.document_id is null and x.withdrawn_at is null and x.created_at < now() - interval '1 hour'
          offset 0) q
    where not exists (select 1 from pgmq.q_remittances m
                      where m.message ->> 'type' = 'repayment_request' and m.message ->> 'request_id' = q.id::text
                      offset 0)
    order by q.id
  loop
    perform pgmq.send('remittances', jsonb_build_object('type', 'repayment_request', 'request_id', r.id,
                                                        'organization_id', r.organization_id));
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
select cron.schedule('repayment-letters-requeue', '41 * * * *', 'select private.requeue_repayment_letters()');


------------------------------------------------------------------------------------------
-- Review round 1: « Approvisionnements »' ordered top-ups by the servicer's key
------------------------------------------------------------------------------------------

-- public.top_up_overview, redefined from 20261129090000_top_ups.sql (line 1022; same signature and settings, SECURITY
-- DEFINER, search_path '' and its grants restated below). M2c-7f-1 review round 1 (found by the db job's order: 7e-1's
-- top-up reads test failed after this round's other fixes, its BitmapAnd plan of the ordered count reading every
-- servicer's ordered transfers): the own account's ordered top-ups read through the servicer's top-ups in flight by its
-- key. Nothing else changes; the rows are the same (a top-up's debtor is the servicer's own account of its currency:
-- bank_transfer_debtor_fk, private.bank_transfer_guard).
-- CI round (PR #52), round 2 (ADR-0014 « M2c-7f-1 — CI round (PR #52) », round 2): the sums of the sweeps and top-ups in
-- flight by private.servicer_flight_minor and the ordered count by private.servicer_flight (the servicer's text key:
-- bank_transfer_servicer_flight_key_idx), what is needed from those sums (private.top_up_needed read them again): 1,705
-- rows under the reads test's plant, 16,746 beside the servicer's booked past and a run's payouts in flight; the same
-- values.
create or replace function public.top_up_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_org uuid := (private.money_staff_org_ids())[1];
  v_needed jsonb;
  v_accounts jsonb;
begin
  if v_org is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'currency', c.currency, 'owed_minor', v.owed::text,
           -- (review round 2, needed-line-sweep-in-flight) what the servicer owes once its sweeps in flight are
           -- executed (design §13 #4's Σ4679 + sweeps ordered or in a file): « Virements » says « ne doit rien » only
           -- when it is ≤ 0 — Σ4679 alone may be < 0 while a sweep in a file takes that share and more away
           'owed_with_sweeps_minor', (v.owed + v.sweeps)::text,
           -- (CI round, PR #52, round 2) private.top_up_needed's formula (design §13 #4) on the terms read once
           -- below: the function read the same sums a second time
           'needed_minor', greatest(0, v.owed + v.sweeps - v.tops)::text,
           -- (review round 1, TUI-2) the top-ups in flight beyond what the servicer owes once its sweeps in flight are
           -- executed (a cancelled top-up's late credit booked while its re-order waits): executed, they come back
           -- with the next sweep. design §13 #4's terms (v, below)
           'surplus_minor', greatest(0, v.tops - greatest(0, v.owed + v.sweeps))::text,
           'own_account', (select jsonb_build_object('id', a.id, 'label', a.label, 'iban_last4', right(a.iban, 4))
                           from public.servicer_billing_settings s join public.bank_account a on a.id = s.own_bank_account_id
                           where s.organization_id = v_org and a.status = 'active' and a.purpose = 'own'
                             and a.currency = c.currency))
         order by c.currency), '[]')
  into v_needed
  from (select distinct b.currency from public.bank_account b
        where b.organization_id = v_org and b.purpose = 'client_funds' and b.status = 'active') c
  -- (review round 2) Σ4679 and the sweeps and top-ups in flight read once per currency (fenced: never inlined into
  -- each use); (CI round, PR #52, round 2) the in-flight ones by private.servicer_flight_minor (the servicer's text key,
  -- as private.top_up_needed sums them): by `organization_id` and constants they could be served by
  -- bank_transfer_org_idx, every transfer of the servicer in flight read twice
  cross join lateral (
    select private.servicer_owed_minor(v_org, c.currency) as owed,
           private.servicer_flight_minor(v_org, c.currency, 'sweep', array['ordered', 'in_file']) as sweeps,
           private.servicer_flight_minor(v_org, c.currency, 'top_up', array['ordered', 'in_file']) as tops
    offset 0) v;
  select coalesce(jsonb_agg(jsonb_build_object(
           'bank_account_id', a.id, 'label', a.label, 'iban_last4', right(a.iban, 4), 'bic', a.bic,
           'currency', a.currency, 'pain_version', a.pain_version,
           'earliest_execution_date', private.transfer_earliest_execution_date(a.id, clock_timestamp()),
           -- the ordered top-ups a file would take (o, below), counted once
           'ordered_count', o.n,
           'can_generate', a.currency = 'EUR' and o.n > 0,
           'top_ups', coalesce((select jsonb_agg(jsonb_build_object(
                                  'transfer_id', t.id, 'end_to_end_id', t.end_to_end_id,
                                  'amount_minor', t.amount_minor::text, 'currency', t.currency, 'status', t.status,
                                  'requested_execution_date', t.requested_execution_date, 'created_at', t.created_at,
                                  'automatic', t.ordered_by is null,
                                  'ordered_by', (select coalesce(u.display_name, u.email) from public.app_user u
                                                 where u.id = t.ordered_by),
                                  'reason', t.reason, 'cancel_reason', t.cancel_reason, 'cancelled_at', t.cancelled_at,
                                  'file_id', t.transfer_file_id,
                                  'file_number', (select f.number from public.transfer_file f
                                                  where f.id = t.transfer_file_id),
                                  'cancellable', t.status = 'ordered'
                                                 or (t.status = 'in_file' and private.top_up_in_own_file(t.id)))
                                order by t.created_at desc, t.id)
                                -- the account's latest 50 (bank_transfer_top_up_idx, in its order)
                                from (select q.* from public.bank_transfer q
                                      where q.debtor_bank_account_id = a.id and q.kind = 'top_up'
                                      order by q.created_at desc limit 50) t), '[]'),
           'files', coalesce((select jsonb_agg(jsonb_build_object(
                                'id', f.id, 'number', f.number, 'status', f.status, 'nb_of_txs', f.nb_of_txs,
                                'ctrl_sum_minor', f.ctrl_sum_minor::text, 'currency', f.currency,
                                'first_execution_date', f.first_execution_date,
                                'last_execution_date', f.last_execution_date, 'created_at', f.created_at,
                                'pain_version', f.pain_version, 'xsd_validated', f.xsd_validated,
                                'download_count', f.download_count, 'first_downloaded_at', f.first_downloaded_at,
                                'first_downloaded_by', (select coalesce(u.display_name, u.email) from public.app_user u
                                                        where u.id = f.first_downloaded_by),
                                'sent_marked_at', f.sent_marked_at, 'closed_at', f.closed_at,
                                'close_reason', f.close_reason, 'error', f.error, 'version', f.version,
                                -- the file's items, each one's transfer by its key (never a status scan; review
                                -- round 2: never `transfer_file_id = f.id`, which may be served from
                                -- bank_transfer_filed_amount_idx — private.top_up_file_close's note)
                                'top_ups_open', (select count(*)
                                                 from (select q.transfer_id from public.transfer_file_item q
                                                       where q.file_id = f.id offset 0) i
                                                 cross join lateral (select q.status, q.transfer_file_id
                                                                     from public.bank_transfer q
                                                                     where q.id = i.transfer_id offset 0) t
                                                 where t.status = 'in_file' and t.transfer_file_id = f.id),
                                'top_ups_booked', (select count(*)
                                                   from (select q.transfer_id from public.transfer_file_item q
                                                         where q.file_id = f.id offset 0) i
                                                   cross join lateral (select q.status from public.bank_transfer q
                                                                       where q.id = i.transfer_id offset 0) t
                                                   where t.status = 'booked'))
                              order by f.created_at desc, f.id)
                              -- the account's latest 20 files (transfer_file_account_idx, in its order)
                              from (select q.* from public.transfer_file q where q.debtor_bank_account_id = a.id
                                    order by q.created_at desc limit 20) f), '[]'))
         order by a.label, a.id), '[]')
  into v_accounts
  from public.bank_account a
  -- the account's ordered top-ups (review round 1, MONEY-BANK-2: not those whose credit is already on a statement),
  -- counted once, never as an EXISTS. (M2c-7f-1 review round 1) read as the servicer's top-ups by its key, the account
  -- checked on the row: by the account's key and the status, a generic plan ANDed bank_transfer_debtor_idx with
  -- bank_transfer_org_idx's status column, every servicer's ordered transfers read (test_top_up_reads_integration.py in
  -- the db job's order: 2,905 index entries for one ordered top-up); never the account's booked past. (CI round, PR #52,
  -- round 2) the servicer's ordered top-ups of the currency by private.servicer_flight (its text key): by
  -- `organization_id` and constants the fence could be served by bank_transfer_org_idx, every transfer of the servicer
  -- in flight read (558 rows for its 5 top-ups under the reads test's plant)
  cross join lateral (select count(*)::integer as n
                      from private.servicer_flight(v_org, a.currency, 'top_up', array['ordered']) t
                      where t.debtor_bank_account_id = a.id and not private.top_up_credit_seen(t.id)) o
  where a.organization_id = v_org and a.purpose = 'own' and a.status = 'active';
  return jsonb_build_object('today', private.paris_today(), 'needed', v_needed, 'accounts', v_accounts,
                            'can_admin', private.has_role(v_org, array['admin']));
end;
$$;


-- public.generate_top_up_file, redefined from 20261129090000_top_ups.sql (line 659; same signature and settings,
-- SECURITY DEFINER, search_path '', its lock_timeout and enable_seqscan off, and its grants restated below). M2c-7f-1
-- review round 1 (the same db-job run): its two reads of the account's ordered top-ups (the locks, the file's items)
-- read through the servicer's top-ups in flight by its key, as public.top_up_overview's count above. The rows are the
-- same (a top-up's debtor is the servicer's own account of its currency: bank_transfer_debtor_fk); nothing else
-- changes.
-- CI round (PR #52), round 2: both by private.servicer_flight (the servicer's ordered top-ups of the currency, by its
-- text key), as the overview's count: 1,153 rows under the reads test's plant, 11,153 beside the servicer's booked past
-- and a run's payouts in flight; the same rows.
create or replace function public.generate_top_up_file(p_idempotency_key text, p_own_bank_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set enable_seqscan = off
as $$
declare
  b public.bank_account;
  v_request jsonb := jsonb_build_object('own_bank_account_id', p_own_bank_account_id);
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
  v_offset integer;
begin
  select * into b from public.bank_account where id = p_own_bank_account_id;
  if not found or not private.has_role(b.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('generate_top_up_file', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if b.purpose <> 'own' or b.status <> 'active' then
    raise exception 'top-up file refused: not_an_own_account' using errcode = 'check_violation';
  end if;
  if b.currency <> 'EUR' then
    raise exception 'top-up file refused: not_eur' using errcode = 'check_violation';
  end if;
  perform 1 from public.bank_account x where x.id = b.id for share;
  perform private.remittance_command_locks(b.organization_id, true);
  v_now := clock_timestamp();
  v_today := (v_now at time zone 'Europe/Paris')::date;
  v_earliest := private.transfer_earliest_execution_date(b.id, v_now);

  select coalesce(array_agg(f.id order by f.id), '{}') into v_superseded from public.transfer_file f
  where f.debtor_bank_account_id = b.id and f.status in ('pending', 'generated');
  perform private.top_up_file_close(x, 'Remplacé par un nouveau fichier', v_file) from unnest(v_superseded) x;

  -- the account's ordered top-ups. (M2c-7f-1 review round 1) read as the servicer's top-ups by its key, the account
  -- checked on the row: by the account's key and the status (7e-1 round 2's form), a generic plan ANDed
  -- bank_transfer_debtor_idx with bank_transfer_org_idx's status column, every servicer's ordered transfers read
  -- (test_top_up_reads_integration.py in the db job's order: about 5,300 rows per file); never the account's booked
  -- past either. (CI round, PR #52, round 2) the servicer's ordered top-ups of the currency by private.servicer_flight
  -- (its text key): by `organization_id` and constants the fence could be served by bank_transfer_org_idx, every
  -- transfer of the servicer in flight read, here and for the items below (1,153 rows under the reads test's plant)
  perform 1 from public.bank_transfer t
  where t.id = any (array(select q.id
                          from private.servicer_flight(b.organization_id, b.currency, 'top_up', array['ordered']) q
                          where q.debtor_bank_account_id = b.id))
  order by t.id for update;
  drop table if exists pg_temp._tuf;
  -- (review round 1, MONEY-BANK-2) never one whose credit (its TOP id) is already on a statement of the dedicated
  -- account: the bank executed it, the funds pass (or ops) books it — filed again, it would be executed twice
  create temp table _tuf on commit drop as
  select t.id, t.amount_minor, t.created_at, greatest(t.requested_execution_date, v_earliest) as execution_date
  -- (M2c-7f-1 review round 1; CI round, PR #52, round 2) as the locks above: the servicer's ordered top-ups of the
  -- currency by its text key, the account on the row (read again once locked)
  from private.servicer_flight(b.organization_id, b.currency, 'top_up', array['ordered']) t
  where t.debtor_bank_account_id = b.id and not private.top_up_credit_seen(t.id);
  select coalesce(sum(x.amount_minor), 0), count(*) into v_sum, v_n from pg_temp._tuf x;
  if v_n = 0 then
    raise exception 'top-up file refused: nothing_to_file' using errcode = 'check_violation';
  end if;

  select legal_name into v_name from public.organization where id = b.organization_id;
  v_number := private.transfer_file_number(v_today, nextval('private.transfer_file_number_seq'));
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
         null, '{"own_account": true}'::jsonb, '[]'::jsonb, v_token, auth.uid()
  from pg_temp._tuf x;
  insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id, pmt_inf_id, execution_date, late)
  select v_file, row_number() over (order by x.execution_date, x.created_at, x.id), x.id, b.organization_id,
         v_number || '-' || dense_rank() over (order by x.execution_date), x.execution_date, false
  from pg_temp._tuf x;
  -- (by our locked ids: a join with the temporary table, which has no statistics, read the table's whole primary key)
  update public.bank_transfer t set status = 'in_file', transfer_file_id = v_file
  where t.id = any (array(select x.id from pg_temp._tuf x));
  perform pgmq.send('remittances', jsonb_build_object('type', 'transfer_file', 'file_id', v_file, 'token', v_token));

  v_result := jsonb_build_object('file_id', v_file, 'number', v_number, 'status', 'pending', 'nb_of_txs', v_n,
                                 'ctrl_sum_minor', v_sum::text,
                                 'first_execution_date', (select min(x.execution_date) from pg_temp._tuf x),
                                 'superseded', to_jsonb(v_superseded));
  perform private.command_record('generate_top_up_file', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


-- public.top_up_credit_options, redefined from 20261129090000_top_ups.sql (line 1151; same signature and settings,
-- SECURITY DEFINER, search_path '', enable_seqscan off and its grants restated below). CI round (PR #52), round 2
-- (ADR-0014 « M2c-7f-1 — CI round (PR #52) », round 2): the servicer's top-ups in flight of the credit's currency by
-- private.servicer_flight (its text key: bank_transfer_servicer_flight_key_idx), the credit's account, amount and
-- counterparty checked on the row as before. By `organization_id` and constants (7e-1 round 1's fence, its constants
-- proving bank_transfer_servicer_flight_idx's predicate) the read could be served by bank_transfer_org_idx by the
-- servicer and the status: under the reads test's plant (no statistics, the flight index bloated) every transfer of the
-- servicer in flight was read (558 rows for its 5 top-ups; 5,558 beside a run's 5,000 payouts in flight — 672 and
-- 3,172 with the predicates as 538572e left them). Nothing else changes; the rows are the same.
create or replace function public.top_up_credit_options(p_bank_transaction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object('bank_transaction_id', t.id, 'top_ups', coalesce((
    select jsonb_agg(jsonb_build_object('transfer_id', x.id, 'end_to_end_id', x.end_to_end_id,
                                        'amount_minor', x.amount_minor::text, 'currency', x.currency,
                                        'status', x.status, 'created_at', x.created_at,
                                        'automatic', x.ordered_by is null,
                                        'file_number', (select f.number from public.transfer_file f
                                                        where f.id = x.transfer_file_id),
                                        'debtor_label', a.label, 'debtor_iban_last4', right(a.iban, 4))
                     order by x.created_at, x.id)
    from private.servicer_flight(t.organization_id, t.currency, 'top_up', array['ordered', 'in_file']) x
    cross join lateral (select o.label, o.iban from public.bank_account o where o.id = x.debtor_bank_account_id
                        offset 0) a
    where x.creditor_bank_account_id = t.bank_account_id and x.amount_minor = t.amount_minor
      and a.iban = t.counterparty_iban
      and (x.status = 'ordered' or (x.status = 'in_file' and private.top_up_in_own_file(x.id)))), '[]'));
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new ones)
------------------------------------------------------------------------------------------

-- the nightly's checks and the funds pass's posting: the worker's (service_role) (20261118100000, 20261129090000)
revoke execute on function private.run_payment_checks(uuid), private.apply_bank_bookings(uuid),
  private.post_allocations(uuid, text, text), private.remittance_record_draft(uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function private.run_payment_checks(uuid), private.apply_bank_bookings(uuid),
  private.post_allocations(uuid, text, text), private.remittance_record_draft(uuid, uuid, jsonb)
  to service_role;
-- the prepare's loader reads: the worker's (service_role)
revoke execute on function private.draft_pending_items(uuid), private.mandates_terms(uuid[])
  from public, anon, authenticated, service_role;
grant execute on function private.draft_pending_items(uuid), private.mandates_terms(uuid[]) to service_role;
-- internal: the nightly's transfer checks and in-flight lines, the refusal's choice, the unpaid invoices, the re-queue
-- (pg_cron's) — as 20261121120000 left run_transfer_checks: only private.run_payment_checks calls it
revoke execute on function private.run_transfer_checks(uuid, uuid, date), private.inflight_overdue_lines(uuid, date),
  private.client_payment_named_refusal(jsonb, uuid[], uuid[], jsonb), private.client_post_opening_unpaid(uuid, date),
  private.requeue_repayment_letters()
  from public, anon, authenticated, service_role;
-- (review round 1, CC-1) internal: an account's transfers in flight, as 20261115090000 left it
revoke execute on function private.transfers_in_flight(uuid) from public, anon, authenticated;
-- (CI round, PR #52) internal: what is needed, as 20261129090000 left it, and its sums (new); (round 2) the same
-- transfers listed (new)
revoke execute on function private.top_up_needed(uuid, character),
  private.servicer_flight_minor(uuid, character, text, text[]), private.servicer_flight(uuid, character, text, text[])
  from public, anon, authenticated, service_role;
-- (H7) internal: the file's helpers (as 20261115090000, 20261117100000 and 20261118100000 left them)
revoke execute on function private.transfer_file_lock_runs(uuid), private.transfer_line_locks(uuid),
  private.transfer_file_release(uuid, text, text, text, uuid), private.transfer_line_supersedes(uuid),
  private.transfer_cancel_evidence(uuid, uuid, boolean), private.transfer_file_executed(uuid)
  from public, anon, authenticated, service_role;
-- (H7) the trigger function: internal, as 20261129090000 left it
revoke execute on function private.bank_transfer_guard() from public, anon, authenticated;
-- the back office's reads and commands: authenticated (money staff at aal2, checked inside); never anon
revoke execute on function public.debit_queue(text, integer, integer),
  public.request_top_up(text, uuid, uuid, text, text, date), public.mark_transfer_file_sent(text, uuid, integer),
  public.request_transfer_file_cancellation(text, uuid, integer, text, text),
  public.confirm_transfer_file_cancellation(text, uuid, integer),
  public.record_client_payment(text, uuid, char, text, date, uuid, uuid[], uuid, uuid[], text, text),
  public.record_client_refund(text, uuid, text, date, uuid, text, text),
  public.withdraw_advance_repayment_request(text, uuid, text),
  public.match_queue_accounts(uuid[]), public.search_payment_files(uuid, text), public.client_advance_totals(uuid),
  public.client_advances(uuid, uuid, boolean, jsonb, integer), public.top_up_overview(),
  public.generate_top_up_file(text, uuid), public.top_up_credit_options(uuid)
  from public, anon;
grant execute on function public.debit_queue(text, integer, integer),
  public.request_top_up(text, uuid, uuid, text, text, date), public.mark_transfer_file_sent(text, uuid, integer),
  public.request_transfer_file_cancellation(text, uuid, integer, text, text),
  public.confirm_transfer_file_cancellation(text, uuid, integer),
  public.record_client_payment(text, uuid, char, text, date, uuid, uuid[], uuid, uuid[], text, text),
  public.record_client_refund(text, uuid, text, date, uuid, text, text),
  public.withdraw_advance_repayment_request(text, uuid, text),
  public.match_queue_accounts(uuid[]), public.search_payment_files(uuid, text), public.client_advance_totals(uuid),
  public.client_advances(uuid, uuid, boolean, jsonb, integer), public.top_up_overview(),
  public.generate_top_up_file(text, uuid), public.top_up_credit_options(uuid)
  to authenticated, service_role;

