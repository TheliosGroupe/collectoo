-- M2c-7e-2 « our references in CSV labels, held and reviewed » (plan docs/design/m2c-7-plan.md §7.3's S24 up to the
-- review, §7.4, §7.5's 047b, §7.6; [critic] M7-MONEY-6, [check 1] gap 5, [check 2] gap 1 (3), [check 3]; ADR-0014
-- « M2c-7e-2 »). Forward-only.
--
-- A CSV export of the dedicated account may cite one of our transfers in a credit's label only (« /MOTIF REMB
-- RMT0123456789AB »: a debtor repaying it, the client quoting it, or our payout coming back unflagged — the label cannot
-- say which; D14). Until now such a credit was a debtor's payment (COMPLIANCE OQ-84 (e), (h)). From 7e-2 the CSV
-- parser reads every whole token of our form (RMT, SWP or TOP and 12 upper-case hexadecimal digits) of the label, in
-- its order — on a line whose end-to-end column is empty, absent or NOTPROVIDED (SEPA's « none »), never the line's own
-- end-to-end id — into the stage's `label_references`; of those that are the end-to-end id of one of our transfers of
-- the statement's account (a payout or a sweep it pays, a top-up it receives; review round 1, MB-1 and MB-2) the import
-- keeps the payout of a booked run (the nightly's P0), else the first in the label's order (review round 3), stores it
-- in `bank_transaction.reference_from_label` — never in an end-to-end id, so no rule reads it as our transfer — and
-- holds
-- the credit under its own kind `label_reference`: no payment, no cash_in, never booked by the debit job, never a return
-- by itself, never explained away or linked. The debit job reviews it (`label_reference`), « Débits et retours » lists
-- it with its candidate and that transfer, the nightly alerts it after two business days (`label_reference_waiting`).
-- Its three exits (the return of exactly that transfer — a payout or a sweep: a top-up has none —, the client's
-- payment, a debtor's payment) are 7e-3's.
-- The cancellation-after-download switch is not written here (it stays off); 7e-2's rules do not read it.
--
-- Redefined (each copied whole from its latest definition across every migration — the last one wins —, its header
-- naming the file and line; SECURITY DEFINER, every SET clause, search_path '' and the grants restated):
--   constraints bank_transaction_kind_check, bank_transaction_kind (20261111090000_remittance_funds.sql:1804),
--     bank_line_held_kind_kind_check, bank_duplicate_resolution_released_kind_check (20261111090000:1819, :1822),
--     bank_debit_review_reason_check (20261129090000_top_ups.sql:133, 7e-1's), index bank_transaction_own_idx
--     (20261111090000:1813);
--   private.bank_line_refined_kind — its eight-argument form (20261116090000_debit_bookings.sql:5384) becomes a wrapper
--     of a new ninth-argument classifier, as the six-argument one (20261116090000:5419) already is;
--   private.stage_refined_kinds (20261116090000:5435), private.held_line_kind (20261116090000:5460),
--     private.bank_transaction_held_kind() (20261111090000:1882; not in the plan's table: the held reading it records
--     must admit the new kind);
--   private.ingest_statement (20261117100000_transfer_line_ops.sql:2749);
--   private.bank_booking_candidates (20261117090000_transfer_line_foundations.sql:882);
--   public.debit_queue (20261117110000_transfer_line_pages.sql:2323; dropped and created: two columns more);
--   private.link_debit_guard (20261118100000_switch_on_prerequisites_2.sql:4743), private.bank_debit_link_guard()
--     (20261111090000:3586);
--   private.run_advance_checks (20261129090000_top_ups.sql:2274, 7e-1's).
-- Not redefined, as the plan says: private.bank_booking_recheck (7e-1's body refuses a top-up, a fee, a loss and a
-- return on such a line by its kind rules), private.apply_bank_bookings (it writes the job's review as given),
-- public.resolve_duplicate (it books no payment for this kind and leaves the line to the job).

------------------------------------------------------------------------------------------
-- The kind and its candidate (plan §7.3, [check 1] gap 5)
------------------------------------------------------------------------------------------

-- bank_transaction (constraints redefined from 20261111090000_remittance_funds.sql line 1804): the reference of ours a
-- CSV label cites, kept by the import (our form only), and the kind `label_reference` — a credit, which always carries
-- its candidate. A candidate on another kind (our own account's credit citing it, a coded charge naming our payout, a
-- return the label flags) is stored as read and changes nothing.
alter table public.bank_transaction
  add column reference_from_label text
    constraint bank_transaction_reference_from_label_check check (reference_from_label ~ '^(RMT|SWP|TOP)[0-9A-F]{12}$'),
  drop constraint bank_transaction_kind_check,
  add constraint bank_transaction_kind_check check (kind in ('debtor_credit', 'return', 'refund_out', 'psp_payout',
    'other_debit', 'batch_unsplit', 'suspected_duplicate', 'transfer_out', 'own_transfer_in', 'client_transfer_in',
    'label_reference')),
  drop constraint bank_transaction_kind,
  add constraint bank_transaction_kind check (case direction
    when 'credit' then kind in ('debtor_credit', 'return', 'psp_payout', 'batch_unsplit', 'suspected_duplicate',
                                'own_transfer_in', 'client_transfer_in', 'label_reference')
    else kind in ('return', 'refund_out', 'other_debit', 'batch_unsplit', 'suspected_duplicate', 'transfer_out') end),
  add constraint bank_transaction_label_reference check (kind <> 'label_reference' or reference_from_label is not null);
comment on column public.bank_transaction.reference_from_label is
  'M2c-7e-2 (S24): the reference of ours (RMT/SWP/TOP) a CSV label cites, kept only when it is a transfer of the line''s '
  'account; never an end-to-end id. A credit holding one is label_reference: held for review, never booked alone.';
-- The stage's (the worker's COPY): every reference of our form a CSV line's label cites, in the label's order, each once
-- (review round 1, MB-1: not only the first — a look-alike, another account's or another servicer's reference before
-- the real one never hides it); the import keeps, of those that are transfers of the statement's account, a booked
-- run's payout, else the first (review round 3)
alter table private.bank_import_stage add column label_references text[];

-- The job's and the queue's index of our transfers and credits (recreated from 20261111090000 line 1813): the held
-- credits too
drop index public.bank_transaction_own_idx;
create index bank_transaction_own_idx on public.bank_transaction (organization_id, booking_date, id)
  where kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in', 'label_reference');
-- the nightly's: the held credits alone (a few), and the held lines released so. On the servicer's key alone (CI round,
-- PR #50; ADR-0014 « M2c-7e-2 — CI round (PR #50) »): on (organization_id, booking_date, id), when the statistics knew
-- none of the servicer's lines and organization_id followed the heap's order, the nightly's read took
-- bank_transaction_org_idx instead (a single-column index gets the whole correlation discount on its heap page, a
-- multi-column one three quarters of it) and read every line of the servicer: 10,000 more in the scale job. Keyed by
-- the servicer alone, this index is a subset of bank_transaction_org_idx priced the same way, never above it; the
-- read's booking date is a filter on its few lines.
create index bank_transaction_label_reference_idx on public.bank_transaction (organization_id)
  where kind = 'label_reference';

-- A held duplicate's reading and its release (constraints redefined from 20261111090000 lines 1819 and 1822)
alter table private.bank_line_held_kind drop constraint bank_line_held_kind_kind_check,
  add constraint bank_line_held_kind_kind_check check (kind in ('debtor_credit', 'return', 'refund_out', 'other_debit',
    'batch_unsplit', 'transfer_out', 'own_transfer_in', 'client_transfer_in', 'label_reference'));
alter table public.bank_duplicate_resolution drop constraint bank_duplicate_resolution_released_kind_check,
  add constraint bank_duplicate_resolution_released_kind_check check (released_kind in ('debtor_credit', 'return',
    'refund_out', 'other_debit', 'batch_unsplit', 'transfer_out', 'own_transfer_in', 'client_transfer_in',
    'label_reference'));
create index bank_duplicate_resolution_label_reference_idx on public.bank_duplicate_resolution (organization_id)
  where released_kind = 'label_reference';

-- Why a line waits for ops (constraint redefined from 20261129090000_top_ups.sql line 133, 7e-1's): M2c-7e-2 a credit
-- whose label cites one of our transfers (« Le libellé cite notre virement … : est-ce ce virement qui revient ? »).
-- Nothing else changes.
alter table public.bank_debit_review drop constraint bank_debit_review_reason_check,
  add constraint bank_debit_review_reason_check check (reason in ('no_candidate', 'ambiguous', 'amount_differs',
    'partial_return', 'refund_not_pending', 'already_returned', 'changed', 'payment_returned', 'before_previous_return',
    'posting_failed', 'top_up_not_found', 'top_up_differs', 'client_credit', 'own_transfer_out',
    'cancelled_transfer_debited', 'transfer_debited_twice', 'transfer_not_handed_out', 'transfer_unknown',
    'transfer_differs', 'run_not_in_flight', 'batch_partial', 'batch_mixed', 'return_differs', 'return_before_debit',
    'own_transfer_line', 'unplanned_payout_return', 'return_debit_pending', 'top_up_cancelled_credit',
    'label_reference'));

------------------------------------------------------------------------------------------
-- Both twins: the classifier's ninth argument (plan §7.3 « Both twins »)
------------------------------------------------------------------------------------------

-- The kind of a line once our own transfers are recognised (twin of payments.statement.refine_kind; the parity tests
-- compare them), from the eight-argument form of 20261116090000 line 5384 with a ninth argument: the candidate the
-- import kept (p_reference_from_label). A credit whose base kind is debtor_credit and which is not refined to
-- own_transfer_in, client_transfer_in or return becomes label_reference when it is set; a client_transfer_in with it
-- too; our own account's credits, returns, batches and every debit are unchanged (a coded charge naming our payout stays
-- other_debit and books as a fee). A parser's label_reference reading is read again from the facts (its base is a
-- debtor's credit), as our other kinds are.
create or replace function private.bank_line_refined_kind(p_kind text, p_direction text, p_end_to_end_id text,
                                                          p_original_end_to_end_id text, p_payment_info_id text,
                                                          p_counterparty_iban text, p_own_ibans text[],
                                                          p_client_ibans text[], p_reference_from_label text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case
    when b.base in ('debtor_credit', 'batch_unsplit') and p_direction = 'credit' then
      case when b.base = 'debtor_credit'
                and (coalesce(p_end_to_end_id ~ '^TOP[0-9A-F]{12}$', false)
                     or coalesce(p_counterparty_iban = any (p_own_ibans), false)) then 'own_transfer_in'
           when b.base = 'debtor_credit' and coalesce(p_counterparty_iban = any (p_client_ibans), false)
             then case when p_reference_from_label is not null then 'label_reference' else 'client_transfer_in' end
           -- private.names_our_transfer's three arms, written out: the import calls this once per line, and a nested
           -- function call per credit cost ~1 s on a 50,000-line re-import (the parity test and pgTAP 035 pin both)
           when coalesce(p_end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
                or coalesce(p_original_end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
                or (p_end_to_end_id is null and coalesce(p_payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$', false))
             then 'return'
           -- M2c-7e-2: a debtor's credit citing one of our transfers of its account in its label is held
           when b.base = 'debtor_credit' and p_reference_from_label is not null then 'label_reference'
           else b.base end
    when b.base = 'other_debit' and p_direction = 'debit' then
      case when coalesce(p_end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
                or coalesce(p_counterparty_iban = any (p_own_ibans), false) then 'transfer_out'
           else 'other_debit' end
    else b.base end
  from (select case p_kind when 'own_transfer_in' then 'debtor_credit' when 'client_transfer_in' then 'debtor_credit'
                           when 'label_reference' then 'debtor_credit'
                           when 'transfer_out' then 'other_debit' else p_kind end as base) b;
$$;

-- The eight-argument form (redefined from 20261116090000 line 5384; its callers' signature): the line with no
-- candidate, read by the ninth-argument form — never a second classifier.
create or replace function private.bank_line_refined_kind(p_kind text, p_direction text, p_end_to_end_id text,
                                                          p_original_end_to_end_id text, p_payment_info_id text,
                                                          p_counterparty_iban text, p_own_ibans text[],
                                                          p_client_ibans text[])
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select private.bank_line_refined_kind(p_kind, p_direction, p_end_to_end_id, p_original_end_to_end_id,
                                        p_payment_info_id, p_counterparty_iban, p_own_ibans, p_client_ibans, null::text);
$$;

-- The six-argument form (redefined from 20261116090000 line 5419): the line without an original end-to-end id, a
-- PmtInfId or a candidate, read by the ninth-argument form.
create or replace function private.bank_line_refined_kind(p_kind text, p_direction text, p_end_to_end_id text,
                                                          p_counterparty_iban text, p_own_ibans text[],
                                                          p_client_ibans text[])
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select private.bank_line_refined_kind(p_kind, p_direction, p_end_to_end_id, null::text, null::text,
                                        p_counterparty_iban, p_own_ibans, p_client_ibans, null::text);
$$;

-- This import's lines whose kind changes (redefined from 20261116090000_debit_bookings.sql line 5435; same settings):
-- M2c-7e-2, the stage's candidate (kept by private.ingest_statement before it) handed to the classifier too. Nothing
-- else changes.
create or replace function private.stage_refined_kinds(p_organization_id uuid, p_own_ibans text[])
returns table (line_no integer, kind text)
language plpgsql
stable
set search_path = ''
set enable_nestloop = off
set enable_mergejoin = off
as $$
begin
  return query
  select y.line_no, y.kind from (
    select x.line_no, x.kind as old_kind,
           private.bank_line_refined_kind(x.kind, x.direction, x.end_to_end_id, x.original_end_to_end_id,
                                          x.payment_info_id, x.counterparty_iban, p_own_ibans,
                                          case when c.iban is null then '{}'::text[] else array[c.iban] end,
                                          x.reference_from_label) as kind
    from pg_temp._bi_stage x
    left join (select distinct a.iban from public.client_payout_account a
               where a.organization_id = p_organization_id and a.confirmed_at is not null) c
      on c.iban = x.counterparty_iban) y
  where y.kind is distinct from y.old_kind;
end;
$$;

-- What a held line is without a recorded reading (redefined from 20261116090000_debit_bookings.sql line 5460): M2c-7e-2,
-- its stored candidate read too (a held duplicate of a credit citing one of our transfers is label_reference). A
-- recorded reading is kept (the stage's, refined at its import). Nothing else changes.
create or replace function private.held_line_kind(p_bank_transaction_id uuid)
returns table (kind text, method text)
language sql
stable
set search_path = ''
as $$
  select coalesce(h.kind, private.bank_line_refined_kind(case
           when t.return_reason is not null or t.reversal_indicator or t.original_end_to_end_id is not null then 'return'
           when t.direction = 'credit' then 'debtor_credit'
           when t.end_to_end_id like 'RFD%' then 'refund_out'
           else 'other_debit' end, t.direction, t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id,
           t.counterparty_iban,
           array(select o.iban from public.bank_account o where o.organization_id = t.organization_id and o.purpose = 'own'),
           case when exists (select 1 from public.client_payout_account a
                             where a.organization_id = t.organization_id and a.iban = t.counterparty_iban
                               and a.confirmed_at is not null)
                then array[t.counterparty_iban] else '{}'::text[] end,
           t.reference_from_label)),
         coalesce(h.method, 'other')
  from public.bank_transaction t
  left join private.bank_line_held_kind h on h.bank_transaction_id = t.id
  where t.id = p_bank_transaction_id;
$$;

-- The parser's reading of a line held as a duplicate (redefined from 20261111090000_remittance_funds.sql line 1882; same
-- settings, its trigger unchanged): M2c-7e-2, a held credit read label_reference is recorded so. Nothing else changes.
create or replace function private.bank_transaction_held_kind()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
begin
  insert into private.bank_line_held_kind (bank_transaction_id, kind, method)
  select n.id, s.kind, s.method
  from new_rows n
  cross join lateral (select x.kind, x.method from private.bank_import_stage x
                      where x.statement_id = n.statement_id and x.line_no = n.line_no
                      offset 0) s
  where n.kind = 'suspected_duplicate'
    and s.kind in ('debtor_credit', 'return', 'refund_out', 'other_debit', 'batch_unsplit', 'transfer_out',
                   'own_transfer_in', 'client_transfer_in', 'label_reference')
  on conflict (bank_transaction_id) do nothing;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- The import (plan §7.3 « private.ingest_statement »)
------------------------------------------------------------------------------------------

-- private.ingest_statement, redefined from 20261117100000_transfer_line_ops.sql (line 2749; same signature and settings,
-- its grants restated below). M2c-7e-2 (plan §7.3, S24; [critic] M7-MONEY-6, [check 1] gap 5): before the refinement,
-- the stage's candidates have our form on a CSV line only (line_invalid), and of those that are the end-to-end id of
-- one of our transfers of this account (a payout or a sweep it pays, a top-up it receives: by the unique
-- bank_transfer.end_to_end_id, one probe per candidate; review round 1, MB-1: a candidate before it that is not one
-- never hides it) the line keeps the payout of a booked run (its run by key, one probe per payout: review round 3, the
-- nightly's P0 — a payout that came back may be waiting — never hidden by our sweep or top-up cited before it), else
-- the first in the label's order, else none; the refinement reads it (its ninth argument:
-- label_reference); the import's kind lists admit label_reference (a credit, with its candidate); the candidate is
-- copied to bank_transaction; the payment step keeps n.kind in ('debtor_credit', 'batch_unsplit'), so a held line gets
-- no payment and no cash_in; the counts gain `label_references`. Nothing else changes.
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
  -- M2c-7e-2: the candidate this import keeps from the line's label (below), never the stage's to give
  alter table pg_temp._bi_stage add column reference_from_label text;
  analyze pg_temp._bi_stage;
  -- M2c-7e-2 (plan §7.3, S24; [critic] M7-MONEY-6): the references of ours the CSV parser read from a line's label (its
  -- candidates, in the label's order) have our form, on a CSV line only, one or more, none null (first offending line
  -- named); of those that are the end-to-end id of one of our transfers of this account — a payout or a sweep it pays,
  -- a top-up it receives (bank_transfer.end_to_end_id is unique: one probe per candidate, the id alone in it) — the line
  -- keeps the payout of a booked run (review round 3, first-kept-candidate-hides-p0: the nightly's P0, so « À classer »
  -- and its alert name that payout, never only our sweep or top-up cited before it; its run read by key, one probe per
  -- payout of the account), else the first in the label's order, else none, so a look-alike or another account's
  -- reference changes nothing and never hides a real one after it (review round 1, MB-1). Kept, it never reaches an
  -- end-to-end id: the classifier's ninth argument holds the line (label_reference, below)
  select min(x.line_no)::text into v_bad from pg_temp._bi_stage x
  where x.label_references is not null
    and (s.format <> 'csv' or coalesce(array_ndims(x.label_references), 0) <> 1
         or exists (select 1 from unnest(x.label_references) u (ref)
                    where u.ref is null or u.ref !~ '^(RMT|SWP|TOP)[0-9A-F]{12}$'));
  if v_bad is not null then
    raise exception 'line_invalid: line % is not a well-formed bank line', v_bad using errcode = '22023';
  end if;
  if exists (select 1 from pg_temp._bi_stage x where x.label_references is not null) then
    -- (review round 3) each line's candidates read once, in a lateral join (a line keeping none has no row): a scalar
    -- subquery here would be planned twice, in the filter and in the value
    update pg_temp._bi_stage x set reference_from_label = k.ref
    from (select z.line_no, c.ref
          from pg_temp._bi_stage z
          cross join lateral (
            select u.ref
            from unnest(z.label_references) with ordinality u (ref, n)
            cross join lateral (select y.organization_id, y.kind, y.run_id, y.debtor_bank_account_id,
                                       y.creditor_bank_account_id
                                from public.bank_transfer y where y.end_to_end_id = u.ref offset 0) y
            -- (review round 3) a payout's run, by its key: booked, it is the nightly's P0
            left join lateral (select r.status from public.remittance_run r
                               where r.id = y.run_id and y.kind = 'payout' offset 0) r on true
            where y.organization_id = s.organization_id
              and case when y.kind = 'top_up' then y.creditor_bank_account_id = s.bank_account_id
                       else y.kind in ('payout', 'sweep') and y.debtor_bank_account_id = s.bank_account_id end
            order by (y.kind = 'payout' and r.status is not distinct from 'booked') desc, u.n
            limit 1) c
          where z.label_references is not null) k
    where k.line_no = x.line_no;
  end if;
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
                                         'transfer_out', 'own_transfer_in', 'client_transfer_in', 'label_reference')
     or (x.direction = 'credit' and x.kind not in ('debtor_credit', 'return', 'batch_unsplit', 'own_transfer_in',
                                                   'client_transfer_in', 'label_reference'))
     or (x.direction = 'debit' and x.kind in ('debtor_credit', 'own_transfer_in', 'client_transfer_in',
                                              'label_reference'))
     -- M2c-7e-2: a line held under its own kind carries the candidate that holds it
     or (x.kind = 'label_reference' and x.reference_from_label is null)
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
     -- M2c-6b-2b (COMPLIANCE OQ-84 (j)): whether the charges were read, on a camt.053 line only, never false beside a
     -- charge; whether each detail of ours gave its CdtDbtInd, one flag per stored detail
     or (x.charges_read is not null and s.format <> 'camt053')
     or (x.charges_read is false and x.charges_minor is not null)
     or (x.unsplit_direction_given is not null
         and case when jsonb_typeof(x.unsplit_details) = 'array'
                  then cardinality(x.unsplit_direction_given) <> jsonb_array_length(x.unsplit_details)
                       or array_position(x.unsplit_direction_given, null) is not null
                  else true end)
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
         -- M2c-6b-2b (COMPLIANCE OQ-84 (j); review CSR-4): every value the new file gives is compared with the stored
         -- one, given by the stored file or not — a detail's amount when the new file gives one, its direction when the
         -- new file gave its CdtDbtInd, the charges when the new file read them (a camt.053.001.02 `Chrgs` is never
         -- read; a stage row without the flag, written before M2c-6b-2b, is read as « read », as 6b-2a compared it)
         -- against a stored line that says what it held (its charges, or charges_read set); a value the new file
         -- leaves out is not compared
         (t.unsplit_details is not null and x.unsplit_details is not null
          and private.unsplit_details_differ(t.unsplit_details, x.unsplit_details, x.unsplit_direction_given))
         or (t.unsplit_detail_count is not null
             and (x.unsplit_detail_count, x.unsplit_batch_count)
                 is distinct from (t.unsplit_detail_count, t.unsplit_batch_count))
         or (x.charges_read is distinct from false and (t.charges_minor is not null or t.charges_read is not null)
             and x.charges_minor is distinct from t.charges_minor) as detail_differs
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
      unsplit_ours, unsplit_details, unsplit_detail_count, unsplit_batch_count, charges_minor, charges_read,
      unsplit_direction_given, reference_from_label)
    select s.organization_id, s.bank_account_id, s.id, n.line_no, n.dedup_key, n.direction, n.amount_minor, s.currency,
           n.booking_date, n.value_date, coalesce(n.reversal_indicator, false), n.bank_tx_code, n.acct_svcr_ref,
           n.end_to_end_id, n.tx_id, n.mandate_ref, n.counterparty_name, n.ultimate_counterparty_name,
           n.counterparty_iban, n.remittance_text, n.creditor_reference, n.return_reason, n.original_end_to_end_id,
           n.batch_entry_ref, n.entry_ref, n.kind, n.payment_info_id, n.unsplit_ours, n.unsplit_details,
           n.unsplit_detail_count, n.unsplit_batch_count, n.charges_minor, n.charges_read, n.unsplit_direction_given,
           n.reference_from_label
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
    'client_transfers_in', count(*) filter (where n.kind = 'client_transfer_in'),
    -- M2c-7e-2: the credits held because their label cites one of our transfers (the debit job reviews them)
    'label_references', count(*) filter (where n.kind = 'label_reference'))
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
-- The debit job reaches it ([check 2] gap 1 (3)); « Débits et retours » lists it
------------------------------------------------------------------------------------------

-- private.bank_booking_candidates, redefined from 20261117090000_transfer_line_foundations.sql (line 882, the `create
-- function` after its drop at line 881; same signature, return columns and settings, so `create or replace`; its
-- grants restated below). M2c-7e-2 ([check 2] gap 1 (3)): both kind lists gain label_reference — the first branch (a
-- line imported so, by bank_transaction_own_idx, recreated with it) and the held-duplicate branch (a held line
-- public.resolve_duplicate released so: it books no payment for that kind, and the line must still reach review). Such
-- a line comes with no transfer (no role reads its kind: `f` reads end-to-end ids only); payments.debits.decide_line
-- reviews it label_reference before any other rule and private.apply_bank_bookings writes the review. Nothing else
-- changes.
create or replace function private.bank_booking_candidates(p_organization_id uuid, p_after_date date, p_after_id uuid,
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
         -- M2c-7e-2 ([check 2] gap 1 (3)): and a credit held because its label cites one of our transfers
         and t.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in', 'label_reference')
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
                       -- M2c-7e-2 ([check 2] gap 1 (3)): a held line released as label_reference (resolve_duplicate
                       -- books no payment for that kind: the line must still reach review)
                       and (r.released_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in',
                                                'label_reference')
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

-- « Débits et retours » (public.debit_queue, redefined from 20261117110000_transfer_line_pages.sql line 2323; dropped and
-- created: two columns added last; same settings, its grants restated below). M2c-7e-2 (plan §7.3, §7.4): « À classer »
-- lists the credits held because their label cites one of our transfers (label_reference, as read or released so)
-- beside our own and the clients' credits; each row returns the candidate (`reference_from_label`) and that transfer
-- (`label_transfer`: its kind, status, amount, currency, end-to-end id, its run's number and status — by key, the
-- transfer by its unique end-to-end id then its run); `bookable_as` is null on such a line (nothing to book in 7e-2).
-- Nothing else changes.
drop function public.debit_queue(text, integer, integer);
create function public.debit_queue(p_tab text default 'a-classer', p_offset integer default 0,
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
    -- too), not booked, explained or released as a relayed debtor payment yet; M2c-7e-2 (plan §7.3): and the credits
    -- held because their label cites one of our transfers (label_reference, as read or released so)
    select t.*, coalesce(r.released_kind, t.kind), null::text, null::jsonb
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = any (v_orgs)
      and (t.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in', 'label_reference')
           or (t.kind = 'suspected_duplicate'
               and r.released_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in', 'label_reference')))
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
  left join public.bank_debit_review v on v.bank_transaction_id = t.id
  left join public.bank_debit_link l on l.bank_transaction_id = t.id
  left join public.bank_own_credit_release c on c.bank_transaction_id = t.id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
  order by (case when p_tab = 'traites' then t.created_at end) desc nulls last, t.booking_date, t.id;
end;
$$;

------------------------------------------------------------------------------------------
-- No other way out ([check 3])
------------------------------------------------------------------------------------------

-- private.link_debit_guard, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 4743; same signature and
-- settings, its grants restated below). M2c-7e-2 (plan §7.3 [check 3]): every link kind is refused on a credit held
-- because its label cites one of our transfers (label_reference, as read or a held line released so):
-- `label_reference_line` (public.link_debit raises « debit link refused: label_reference_line »; « Débits et retours »
-- words it), `label_reference_top_up_line` when the transfer cited is our top-up (review round 3,
-- top-cited-line-lists-a-return-exit: a top-up has no return exit, plan §7.3 — the page words its classes without one;
-- the candidate's prefix is its transfer's kind, bank_transfer_prefix). Explained, the line would leave the debit job's
-- candidates and never become a payment, a client payment or a return (a debtor's money never allocated, or a returned
-- payout never paid again). Nothing else changes.
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
  -- M2c-7e-2 (plan §7.3 [check 3]): a credit held because its label cites one of our transfers (label_reference — as
  -- read, or a held line released so) takes no link of any kind: neither explained away, nor a payment's return or
  -- loss, a refund or its return, a fee or a top-up — it waits for one of its exits (7e-3: the return of exactly that
  -- transfer, the client's payment, a debtor's payment). Explained, it would leave the debit job's candidates for good.
  -- (review round 3) Citing our top-up (TOP: bank_transfer_prefix), its own code: it has no return exit
  if t.direction = 'credit'
     and coalesce((select d.released_kind from public.bank_duplicate_resolution d where d.bank_transaction_id = t.id),
                  t.kind) = 'label_reference' then
    return case when left(t.reference_from_label, 3) = 'TOP' then 'label_reference_top_up_line'
                else 'label_reference_line' end;
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
  -- M2c-6b-3a-2 (6b-3a review, low): a manual refund (no transfer of ours: the refund's trigger never reads the line) on
  -- a debit naming neither an end-to-end id nor a PmtInf, while a transfer cancelled out of a downloaded file bars it
  -- (private.refund_line_barred_by: the trigger's rule for a refund not handed out — another payment's cancelled
  -- refund, a cancelled payout, a cancelled sweep): refused here too, not only hidden by « Lier »
  if p_kind = 'refund' and v_refund_transfer is null and t.end_to_end_id is null and t.payment_info_id is null
     and private.refund_line_barred_by(t.id, p_refund_request_id) is not null then
    return 'payout_candidate';
  end if;
  -- (the refund link: a candidate other than that refund's own transfer, a sweep apart — review round 7's founder
  -- decision, N1 (b), pinned by 033: a reference-less line executes a refund in a downloaded or sent file even beside
  -- the servicer's sweep of its amount in the same file)
  -- (round 3) a payment's return and its loss: only a candidate that may still be paid out by this line — (i), (ii),
  -- or a cancelled payout whose run is still approved or sent (its run by key) — never one only returned, or cancelled
  -- with its run ended (iii for good: COMPLIANCE OQ-86's default)
  -- (6b-2d, refund-link-blocked-by-returned-payout-twin) the refund link alike: (iii) never refuses it (OQ-86)
  -- (M2c-6b-3a review round 1, DP-2) but for the refund link a payout cancelled out of a downloaded file (iii, cancelled:
  -- never one only returned) or a sweep cancelled so (iv) refuses it whatever its run: the line may be its late
  -- execution, and linked as a refund it would close that late debit and lift M's and A's holds
  select coalesce(bool_or(c.transfer_id is distinct from v_refund_transfer
                          and (p_kind <> 'refund' or c.kind <> 'sweep' or c.cand = 'iv')
                          and (p_kind not in ('return', 'loss', 'refund') or c.cand in ('i', 'ii')
                               or (c.status = 'cancelled' and r.status in ('approved', 'sent'))
                               or (p_kind = 'refund' and c.status = 'cancelled' and c.kind in ('payout', 'sweep')))),
                  false),
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

-- A link fits its line (private.bank_debit_link_guard, redefined from 20261111090000_remittance_funds.sql line 3586; same
-- settings, its trigger unchanged): M2c-7e-2 (plan §7.3 [check 3]), the backstop of private.link_debit_guard — a link
-- written on a credit held because its label cites one of our transfers (as read, or released so) is refused, the
-- explanation first (check_violation): the plan's `explained` refusal, widened to every link kind (none of 7e-3's exits
-- is a link). Nothing else changes.
create or replace function private.bank_debit_link_guard()
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
  left join public.bank_transaction t on t.id = n.bank_transaction_id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = n.bank_transaction_id
  left join public.payment p on p.id = n.payment_id
  left join public.refund_request q on q.id = n.refund_request_id
  left join public.ledger_entry e on e.id = n.cash_entry_id
  where t.id is null or t.organization_id <> n.organization_id or t.bank_account_id <> n.bank_account_id
     or (t.kind = 'suspected_duplicate' and r.decision is distinct from 'released')
     or (n.payment_id is not null and p.bank_account_id is distinct from t.bank_account_id)
     or (n.refund_request_id is not null and (q.payment_id is distinct from n.payment_id
                                              or q.bank_account_id is distinct from t.bank_account_id))
     or (n.kind in ('return', 'refund') and t.direction <> 'debit')
     or (n.kind = 'refund_returned' and t.direction <> 'credit')
     or (n.kind = 'explained' and t.direction = 'credit' and coalesce(r.released_kind, t.kind) in ('debtor_credit', 'batch_unsplit'))
     -- M2c-7e-2 (plan §7.3 [check 3]): the backstop of private.link_debit_guard — a credit held because its label
     -- cites one of our transfers (as read, or a held line released so) takes no link, the explanation first
     or (t.direction = 'credit' and coalesce(r.released_kind, t.kind) = 'label_reference')
     or (n.cash_entry_id is not null and (e.payment_id is distinct from n.payment_id
                                          or (n.kind in ('return', 'refund') and e.entry_type <> 'cash_out')
                                          or (n.kind = 'refund_returned' and e.entry_type <> 'reversal')))
     or exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = n.bank_transaction_id offset 0)
     or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = n.bank_transaction_id
                offset 0);
  if v_bad is not null then
    raise exception 'bank debit link %: it does not match its line, payment, refund or entry', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- The nightly ([check 3]): label_reference_waiting
------------------------------------------------------------------------------------------

-- private.run_advance_checks, redefined from 20261129090000_top_ups.sql (line 2274, 7e-1's: 7d-3's body with the
-- top-ups' checks; same signature and settings, its grants restated below). M2c-7e-2 (plan §7.3 [check 3]): one check
-- after the others — label_reference_waiting (alert; P0 when the candidate is the payout of a booked run): a credit held
-- because its CSV label cites one of our transfers, as read or released so, unbooked, unlinked and unreleased, imported
-- more than two business days ago. (run_transfer_checks is left unchanged, D6: its bank_line_unbooked reads other
-- kinds; run_payment_checks' debit_unclassified too.) Its other statements are unchanged.
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
  v_from_ts timestamptz;
  v_from_date date;
  v_proc uuid[];
  v_curr char(3);
  v_need bigint;
  v_bd3 date;   -- (M2c-7e-2) the third business day on or before today: a day before it is more than 2 business days ago
begin
  select r.id, r.started_at - interval '1 day' into v_prev, v_since
  from public.payment_check_run r
  where r.organization_id = p_organization_id and r.finished_at is not null and r.id <> p_check_run_id
  order by r.started_at desc limit 1;
  if v_prev is null then
    v_full := true;
  end if;
  v_since_date := (v_since at time zone 'Europe/Paris')::date;
  -- (review round 1, CC-2) the window's lower bounds, -infinity for the full pass: a key range in every plan — a
  -- « v_full or … » predicate is a filter under the generic plan PL/pgSQL caches after five calls in one backend, and
  -- the delta pass would then read every booked run, attribution and cover of the servicer
  v_from_ts := case when v_full then '-infinity'::timestamptz else v_since end;
  v_from_date := case when v_full then '-infinity'::date else v_since_date end;
  -- (M2c-7d-3, plan §6.3) the servicer's clients with a proceeding or a liquidation in effect today — the clients of the
  -- declarations' checks below, whose advances advance_open leaves out: the servicer's clients by
  -- organization_servicer_idx, each one's events by client_status_event_client_idx (a probe per client, fenced)
  select coalesce(array_agg(o.id order by o.id), '{}') into v_proc
  from (select q.id from public.organization q where q.servicer_organization_id = p_organization_id offset 0) o
  where exists (select 1
                from (select e.kind from public.client_status_event e
                      where e.client_organization_id = o.id and e.effective_date <= v_today offset 0) e
                where e.kind in ('proceeding_opened', 'liquidation'));

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with day_rev as materialized (     -- the reversals posted since (ledger_entry_reversal_posted_idx)
    select x.id, x.reverses_entry_id from public.ledger_entry x
    where not v_full and x.organization_id = p_organization_id and x.entry_type = 'reversal' and x.posted_at >= v_since),
  booked as materialized (           -- the runs booked since (remittance_run_booked_idx), every one in the full pass
    select q.id from public.remittance_run q
    where q.organization_id = p_organization_id and q.status = 'booked' and q.booked_on >= v_from_date
    union
    -- (review round 1, CC-1) and the runs whose payout booking was recorded since, whatever their booked_on (the
    -- debit's date: a statement imported late, a late predecessor): bank_line_booking_org_idx, each transfer's run by key
    select t.run_id
    from (select b.transfer_id from public.bank_line_booking b
          where not v_full and b.organization_id = p_organization_id and b.decided_at >= v_from_ts
            and b.kind = 'payout' offset 0) b
    cross join lateral (select t.run_id from public.bank_transfer t
                        where t.id = b.transfer_id and t.run_id is not null offset 0) t),
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
    from booked r
    -- (CI round, main) each run's lines by the run's key alone, their conditions outside the fence
    cross join lateral (select l.ledger_entry_id, l.released, l.kind from public.remittance_line l
                        where l.run_id = r.id offset 0) l
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = l.ledger_entry_id offset 0) z
    where not l.released and l.kind in ('allocation', 'forward')
    union
    select z.id
    from (select u.ledger_entry_id from private.unplanned_paid_item u
          where u.organization_id = p_organization_id and u.created_at >= v_from_ts offset 0) u
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = u.ledger_entry_id offset 0) z
    union
    select a.cause_entry_id from public.client_advance a
    where a.organization_id = p_organization_id and a.cause = 'remitted_reversal' and a.created_at >= v_from_ts
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
                            'created_on', (a.created_at at time zone 'Europe/Paris')::date,
                            -- (M2c-7b) how it is recovered (review round 1: barred_proceeding when it was born before
                            -- the client's proceeding opened)
                            'recovery', (select r.recovery
                                         from private.advance_recovery_of(a.mandate_id, a.client_organization_id,
                                                                          private.advance_born_on(a.id), v_today) r))
         -- (M2c-7c-2, plan §5.2.8) the day it was last requested (a request not withdrawn), when it is
         || coalesce((select jsonb_build_object('requested_on', q.issue_date)
                      from private.advance_live_request(a.id) q), '{}'::jsonb)
         || case when a.cause = 'remitted_reversal'
                      and exists (select 1
                                  from (select z.reverses_entry_id from public.ledger_entry z
                                        where z.id = a.cause_entry_id offset 0) z
                                  cross join lateral (select l.run_id from public.remittance_line l
                                                      where l.ledger_entry_id = z.reverses_entry_id and not l.released
                                                      offset 0) l
                                  cross join lateral private.item_settled_at(z.reverses_entry_id, l.run_id, 0) t
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
    and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id)
    -- (M2c-7d-3, plan §6.2.10 [critic] L4; carried item 1) never an advance of a client with a proceeding or a
    -- liquidation in effect: claims_to_declare lists it (each such advance in one alert; none once declared)
    and not (a.client_organization_id = any (v_proc));

  -- (M2c-7c-1, plan §5.2.8) [critic] client_credit_owed (alert): what the servicer owes a client back, still open more
  -- than 15 days after it was recorded — at once (P0, `p0` in its details) for a sum held for the client's collective
  -- proceeding (cause procedure: ops and counsel decide, OQ-98). The servicer's credits by client_credit_org_idx, each
  -- one's refunds by commission_settlement_document_idx.
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'client_credit_owed', 'alert', 'client_credit', c.id, c.currency, o.open_minor,
         1, v_today - (c.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', c.client_organization_id, 'cause', c.cause,
                            'created_on', (c.created_at at time zone 'Europe/Paris')::date, 'p0', c.cause = 'procedure')
  from (select q.id, q.client_organization_id, q.currency, q.cause, q.created_at from public.client_credit q
        where q.organization_id = p_organization_id offset 0) c
  cross join lateral (select private.client_credit_open(c.id) as open_minor) o
  where o.open_minor > 0
    and (c.cause = 'procedure' or c.created_at < ((v_today - 15)::timestamp at time zone 'Europe/Paris'));

  -- (M2c-7c-1, plan §5.0 (7)) [check 1] client_credit_ledger (violation, per client): Σ the open parts of its credits
  -- owed back = −Σ its 419 postings
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with cc as materialized (
    select c.client_organization_id, c.currency, sum(c.amount_minor - coalesce(r.refunded, 0))::bigint as open_minor
    from (select q.id, q.client_organization_id, q.currency, q.amount_minor from public.client_credit q
          where q.organization_id = p_organization_id offset 0) c
    left join lateral (select sum(s.amount_minor) as refunded from public.commission_settlement s
                       where s.document_id = c.id and s.document_kind = 'client_credit') r on true
    group by c.client_organization_id, c.currency),
  led as materialized (
    select la.client_organization_id, la.currency, coalesce(-sum(p.s), 0)::bigint as owed_minor
    from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'client_credit_owed' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.client_organization_id, la.currency)
  select p_check_run_id, p_organization_id, 'client_credit_ledger', 'violation', 'client',
         coalesce(c.client_organization_id, l.client_organization_id), coalesce(c.currency, l.currency),
         coalesce(l.owed_minor, 0) - coalesce(c.open_minor, 0), 1, null,
         jsonb_build_object('client_id', coalesce(c.client_organization_id, l.client_organization_id),
                            'credits_open', coalesce(c.open_minor, 0)::text, 'ledger', coalesce(l.owed_minor, 0)::text)
  from cc c
  full join led l on l.client_organization_id = c.client_organization_id and l.currency = c.currency
  where coalesce(c.open_minor, 0) <> coalesce(l.owed_minor, 0);

  -- (M2c-7c-1, plan §5.0 (7)) [check 1] written_off_recovery_ledger (violation, the servicer): Σ the recoveries of its
  -- advances passed as a loss = −Σ its 7714 postings, per currency
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with rec as materialized (
    select r.currency, sum(r.amount_minor)::bigint as recovered_minor
    from (select q.currency, q.amount_minor from public.advance_write_off_recovery q
          where q.organization_id = p_organization_id offset 0) r
    group by r.currency),
  led as materialized (
    select la.currency, coalesce(-sum(p.s), 0)::bigint as income_minor
    from (select l.id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'written_off_recovered' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.currency)
  select p_check_run_id, p_organization_id, 'written_off_recovery_ledger', 'violation', 'servicer', null,
         coalesce(r.currency, l.currency), coalesce(l.income_minor, 0) - coalesce(r.recovered_minor, 0), 1, null,
         jsonb_build_object('recovered', coalesce(r.recovered_minor, 0)::text, 'ledger', coalesce(l.income_minor, 0)::text)
  from rec r
  full join led l on l.currency = r.currency
  where coalesce(r.recovered_minor, 0) <> coalesce(l.income_minor, 0);

  -- (M2c-7c-2, plan §5.2.8) repayment_request_document_missing (alert): a request not withdrawn whose letter is not
  -- drawn one hour after it was recorded (its job failing, or dead). The servicer's undrawn requests by
  -- advance_repayment_request_undrawn_idx (its predicate stated literally here: never every request); (review round 1,
  -- NIGHT-1, CC-1) a withdrawn one gets no letter (its job draws none): never alerted — withdrawing and requesting again
  -- (the remedy for a dead job) leaves no alert behind.
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'repayment_request_document_missing', 'alert', 'advance_repayment_request',
         q.id, q.currency, q.total_minor, 1, v_today - (q.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', q.client_organization_id, 'number', q.number,
                            'created_on', (q.created_at at time zone 'Europe/Paris')::date)
  from (select r.id, r.client_organization_id, r.currency, r.total_minor, r.number, r.created_at
        from public.advance_repayment_request r
        where r.organization_id = p_organization_id and r.document_id is null and r.withdrawn_at is null
          and r.created_at < now() - interval '1 hour' offset 0) q;

  -- (M2c-7d-1, plan §6.3; [critic] L17) protection_event_to_qualify (alert): an old « Tutelle ou curatelle » row
  -- (qualified_at null) ops have not yet said to be a tutelle or a curatelle — its payouts held meanwhile. The
  -- servicer's rows still to qualify by client_status_event_to_qualify_idx (its predicate stated literally), each one's
  -- qualification by its key (offset 0: a correlated probe, never an anti-join reading the qualifications whole).
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'protection_event_to_qualify', 'alert', 'client_status_event', e.id, null,
         null, 1, v_today - (e.recorded_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', e.client_organization_id, 'effective_date', e.effective_date,
                            'recorded_on', (e.recorded_at at time zone 'Europe/Paris')::date)
  from (select x.id, x.client_organization_id, x.effective_date, x.recorded_at from public.client_status_event x
        where x.organization_id = p_organization_id and x.kind = 'guardianship' and x.qualified_at is null offset 0) e
  where not exists (select 1 from public.client_status_event_qualification q where q.event_id = e.id offset 0);

  -- (M2c-7d-1, plan §6.3; [critic] L14, [check 2] gap 6) seizure_standing (alert; P0 for 15 days after its recording,
  -- `p0` in its details): a seizure served on the servicer that no release naming it lifts by today — payouts and
  -- set-off stay blocked; the declaration to the bailiff and the payment of the causes are ops' and counsel's (CPCE
  -- L211-3, R211-4, R211-5). (M2c-7d-2) The servicer's clients by organization_servicer_idx, each one's seizures by
  -- client_status_event_client_seizure_idx (7d-1's index of the servicer's seizures dropped above), each seizure's
  -- release by client_status_event_release_uq (offset 0: a correlated probe per seizure — as an anti-join it read the
  -- release index whole under stale statistics).
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'seizure_standing', 'alert', 'client_status_event', e.id, null, null, 1,
         v_today - (e.recorded_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', e.client_organization_id, 'effective_date', e.effective_date,
                            'recorded_on', (e.recorded_at at time zone 'Europe/Paris')::date,
                            'p0', v_today - (e.recorded_at at time zone 'Europe/Paris')::date < 15)
  from (select o.id from public.organization o where o.servicer_organization_id = p_organization_id offset 0) o
  cross join lateral (select x.id, x.organization_id, x.client_organization_id, x.effective_date, x.recorded_at
                      from public.client_status_event x
                      where x.client_organization_id = o.id and x.kind = 'seizure' offset 0) e
  where e.organization_id = p_organization_id and e.effective_date <= v_today
    and not exists (select 1 from public.client_status_event r
                    where r.refers_to_event_id = e.id and r.kind = 'seizure_released' and r.effective_date <= v_today
                    offset 0);

  -- (M2c-7d-2, plan §6.3 [critic] M7-MONEY-5) set_off_after_bar (alert, P0): a run's settlement posted on or after a
  -- bar's date that set off a document barred that day — an event recorded after the debit, which the debit's
  -- withholding could not see; its amount the barred documents' settlements (private.set_off_after_bar_rows). Counsel
  -- says what follows (kept, or given back): it stays alerted meanwhile.
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'set_off_after_bar', 'alert', 'ledger_entry', x.entry_id, x.currency,
         x.amount_minor, 1, v_today - x.settled_on,
         jsonb_build_object('client_id', x.client_organization_id, 'run_id', x.run_id, 'settled_on', x.settled_on,
                            'bar', x.bar, 'bar_on', x.bar_on, 'documents', x.documents, 'p0', true)
  from private.set_off_after_bar_rows(p_organization_id, v_today) x
  -- (M2c-7d-3; carried item 2) until its outcome is recorded (public.record_set_off_outcome: kept), by its key
  where not exists (select 1 from public.set_off_outcome o where o.entry_id = x.entry_id);

  -- (M2c-7d-3, plan §6.3 [critic] L8, L4; [check 2]) claims_to_declare (alert; P0 from 15 days before its deadline): per
  -- document of a client with a proceeding or a liquidation, an open invoice born before the opening or an open advance,
  -- not named by a declaration (private.client_claims_to_declare): its open part, its birth, its deadline (two months
  -- after the BODACC publication for a claim born before the opening, R622-24 al. 1; after its exigibility for one born
  -- after, L622-24 al. 6) — `publication_missing` without a publication date (then no P0: the deadline is unknown)
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'claims_to_declare', 'alert',
         case x.document_kind when 'invoice' then 'commission_invoice' else 'client_advance' end, x.document_id,
         x.currency, x.open_minor, 1, v_today - x.opening_on,
         jsonb_build_object('client_id', c.id, 'document_kind', x.document_kind, 'number', x.number,
                            'born_on', x.born_on, 'pre_opening', x.pre_opening, 'opening_on', x.opening_on,
                            'opening_kind', x.opening_kind, 'publication_date', x.publication_date,
                            'liquidation_on', x.liquidation_on, 'deadline', x.deadline,
                            'deadline_basis', x.deadline_basis,
                            'p0', coalesce(x.deadline - v_today <= 15, false))
  from unnest(v_proc) c (id)
  cross join lateral private.client_claims_to_declare(c.id, v_today) x;

  -- (M2c-7d-3, plan §6.3 [critic] L8) post_opening_unpaid (alert): an invoice of a client with a proceeding or a
  -- liquidation, born on or after the opening, unpaid at its due date and not declared
  -- (private.client_post_opening_unpaid); no deadline computed (L622-17 IV: the end of the observation period is not
  -- modelled; L641-13 III in liquidation). (Review round 2) an invoice its run set off in full, whose set-off the debit
  -- withheld: from that day (`withheld_on`, standing for its due date); (review round 3) one whose run is in flight
  -- while the client's invoice bar applies: from the day the bar was recorded (`barred_on`, its code `bar`)
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'post_opening_unpaid', 'alert', 'commission_invoice', x.document_id,
         x.currency, x.open_minor, 1, v_today - coalesce(x.due_date, x.withheld_on, x.barred_on),
         jsonb_build_object('client_id', c.id, 'number', x.number, 'due_date', x.due_date, 'born_on', x.born_on,
                            'opening_on', x.opening_on, 'opening_kind', x.opening_kind,
                            'publication_date', x.publication_date, 'liquidation_on', x.liquidation_on,
                            'withheld_on', x.withheld_on, 'barred_on', x.barred_on, 'bar', x.bar)
  from unnest(v_proc) c (id)
  cross join lateral private.client_post_opening_unpaid(c.id, v_today) x;

  -- (M2c-7d-3, plan §6.3 [critic] L11, [check 1] gap 9) payout_after_liquidation (alert, P0): a payout made to the
  -- client after its liquidation, to an account that is not its liquidator's — in its file (`cancellable` while the
  -- file is not downloaded, or once downloaded with the cancellation-after-download switch on) or debited — until a
  -- disposition is recorded (private.client_payouts_after_liquidation), never by elapsed time
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'payout_after_liquidation', 'alert', 'bank_transfer', x.transfer_id,
         x.currency, x.amount_minor, 1, v_today - x.liquidation_on,
         jsonb_build_object('client_id', c.id, 'run_id', x.run_id, 'run_number', x.run_number, 'status', x.status,
                            'requested_execution_date', x.requested_execution_date, 'debited_on', x.debited_on,
                            'liquidation_on', x.liquidation_on, 'downloaded', x.downloaded,
                            'cancellable', case when x.status = 'in_file'
                                                then not x.downloaded or public.cancellation_after_download() end,
                            'p0', true)
  from unnest(v_proc) c (id)
  cross join lateral private.client_payouts_after_liquidation(c.id, v_today) x
  where not x.disposed;

  -- (M2c-7e-1, plan §7.1) top_up_account_missing (alert): the servicer owes the dedicated account (design §13 #4's
  -- need > 0) and no active own account of that currency is in its billing settings — the hourly job orders nothing
  for v_curr in select distinct b.currency from public.bank_account b
                where b.organization_id = p_organization_id and b.purpose = 'client_funds' and b.status = 'active'
                order by b.currency loop
    v_need := private.top_up_needed(p_organization_id, v_curr);
    if v_need > 0 and not exists (select 1 from public.servicer_billing_settings s
                                  join public.bank_account a on a.id = s.own_bank_account_id
                                  where s.organization_id = p_organization_id and a.purpose = 'own'
                                    and a.status = 'active' and a.currency = v_curr) then
      -- (review round 1, TUI-9) as old as the open shortfall period (the Paris date of its opening; none before the
      -- hourly job opened one: no age), by servicer_shortfall_period_open_uq
      insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id,
                                               currency, amount_minor, count, oldest_days, details)
      values (p_check_run_id, p_organization_id, 'top_up_account_missing', 'alert', 'organization', p_organization_id,
              v_curr, v_need, 1,
              v_today - (select (q.opened_at at time zone 'Europe/Paris')::date
                         from private.servicer_shortfall_period q
                         where q.organization_id = p_organization_id and q.currency = v_curr and q.closed_at is null),
              jsonb_build_object('currency', v_curr, 'needed_minor', v_need::text));
    end if;
  end loop;

  -- (M2c-7e-1, plan §7.1 [critic] F8) top_up_order_failed (alert): the hourly job missed the servicer three times in a
  -- row (its lock held past 2 s) or failed (any other error) — what is needed is not ordered meanwhile. Review round 1
  -- (MONEY-BANK-4): or it no longer runs — its last run more than three hours back, or none for a servicer whose
  -- active dedicated account is older than that (pg_cron disabled, the remittances queue not consumed): `stale`.
  -- Review round 2 (stale-alert-no-dedicated-account): only while the servicer has an active dedicated account — the
  -- job is queued for no other (private.queue_top_ups) and orders nothing without one, so a state row left by its last
  -- run before the account's closure is never refreshed and would raise the alert every night for ever
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'top_up_order_failed', 'alert', 'organization', p_organization_id, null,
         null, greatest(coalesce(s.consecutive_misses, 0), 1),
         v_today - (coalesce(s.last_run_at, a.since) at time zone 'Europe/Paris')::date,
         jsonb_build_object('outcome', s.last_outcome, 'misses', coalesce(s.consecutive_misses, 0),
                            'error', s.last_error, 'last_run_at', s.last_run_at,
                            'stale', coalesce(s.last_run_at, a.since) < clock_timestamp() - interval '3 hours')
  from (select min(b.created_at) as since from public.bank_account b
        where b.organization_id = p_organization_id and b.purpose = 'client_funds' and b.status = 'active') a
  left join private.top_up_order_state s on s.organization_id = p_organization_id
  where a.since is not null
    and (s.last_outcome = 'failed' or (s.last_outcome = 'missed' and s.consecutive_misses >= 3)
         or coalesce(s.last_run_at, a.since) < clock_timestamp() - interval '3 hours');

  -- (M2c-7e-2, plan §7.3 [check 3]) label_reference_waiting (alert; P0 when the candidate is the payout of a booked
  -- run, since a payout that came back may be waiting): a credit held because its CSV label cites one of our transfers
  -- of its account (label_reference — as read, or a held line released so), unbooked, unlinked and unreleased, imported
  -- more than two business days ago (its booking date before the third business day on or before today, the business
  -- calendar bank_line_unbooked reads); it stops once one of its exits is taken (7e-3). Every pass, delta or full. The
  -- servicer's such lines by bank_transaction_label_reference_idx, its released ones by
  -- bank_duplicate_resolution_label_reference_idx; each line, its candidate's transfer and its run by their keys
  select c.day into v_bd3 from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day <= v_today and c.day > v_today - 30
  order by c.day desc offset 2 limit 1;
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'label_reference_waiting', 'alert', 'bank_transaction', x.id, x.currency,
         x.amount_minor, 1, v_today - x.booking_date,
         jsonb_build_object('reference_from_label', x.reference_from_label, 'candidate_transfer_id', tr.id,
                            'candidate_kind', tr.kind, 'run_id', tr.run_id, 'run_number', ru.number,
                            'run_status', ru.status, 'oldest_days', v_today - x.booking_date,
                            'p0', coalesce(tr.kind = 'payout' and ru.status = 'booked', false))
  from ((select q.id from public.bank_transaction q
         where q.organization_id = p_organization_id and q.kind = 'label_reference' and q.booking_date < v_bd3
         offset 0)
        union
        (select d.bank_transaction_id from public.bank_duplicate_resolution d
         where d.organization_id = p_organization_id and d.released_kind = 'label_reference' offset 0)) k
  cross join lateral (select q.id, q.organization_id, q.currency, q.amount_minor, q.booking_date,
                             q.reference_from_label
                      from public.bank_transaction q where q.id = k.id offset 0) x
  left join lateral (select y.id, y.kind, y.run_id, y.organization_id from public.bank_transfer y
                     where y.end_to_end_id = x.reference_from_label offset 0) tr
    on tr.organization_id = x.organization_id
  left join lateral (select r.number, r.status from public.remittance_run r where r.id = tr.run_id offset 0) ru on true
  where x.booking_date < v_bd3
    and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = x.id offset 0)
    and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id offset 0)
    and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = x.id offset 0);
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here)
------------------------------------------------------------------------------------------

-- the classifier internal, the worker's parity tests (service role) reading every form (as granted by 20261116090000);
-- the stage's refinement and the held line's reading internal (20261116090000, 20261110120000)
revoke execute on function
  private.bank_line_refined_kind(text, text, text, text, text, text, text[], text[], text),
  private.bank_line_refined_kind(text, text, text, text, text, text, text[], text[]),
  private.bank_line_refined_kind(text, text, text, text, text[], text[]), private.held_line_kind(uuid)
  from public, anon, authenticated, service_role;
grant execute on function
  private.bank_line_refined_kind(text, text, text, text, text, text, text[], text[], text),
  private.bank_line_refined_kind(text, text, text, text, text, text, text[], text[]),
  private.bank_line_refined_kind(text, text, text, text, text[], text[])
  to service_role;
revoke execute on function private.stage_refined_kinds(uuid, text[]) from public, anon, authenticated;
-- the trigger functions: internal, as granted by 20261110120000
revoke execute on function private.bank_transaction_held_kind(), private.bank_debit_link_guard()
  from public, anon, authenticated, service_role;
-- the import, as granted by 20261109120000 (the worker's)
revoke execute on function private.ingest_statement(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function private.ingest_statement(uuid, jsonb) to service_role;
-- the funds pass's candidates, as granted by 20261116090000 (the worker's)
revoke execute on function private.bank_booking_candidates(uuid, date, uuid, integer)
  from public, anon, authenticated, service_role;
grant execute on function private.bank_booking_candidates(uuid, date, uuid, integer) to service_role;
-- « Débits et retours », as granted by 20261116090000 and 20261117110000 (the back office's: money staff, checked inside)
revoke execute on function public.debit_queue(text, integer, integer) from public, anon;
grant execute on function public.debit_queue(text, integer, integer) to authenticated;
-- the link guard, as granted by 20261117113000 (internal)
revoke execute on function private.link_debit_guard(uuid, text, uuid) from public, anon, authenticated, service_role;
-- the advance checks: internal (20261129090000)
revoke execute on function private.run_advance_checks(uuid, uuid, date, boolean)
  from public, anon, authenticated, service_role;
