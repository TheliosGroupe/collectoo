-- M2c-6b-2b « the ops command » (plan docs/design/m2c-6b-2-plan.md §3, the 6b-2b parts of §6–§12; ADR-0014
-- « M2c-6b-2b »). Ops book the lines of our own transfers that the debit job leaves to them (S01–S05, S03r, S07–S09,
-- S12–S16, S20–S22, S26–S28), one line at a time, from what the database proposes — never composing a batch line's
-- members nor an unsplit entry's details:
--   * public.book_transfer_line(key, line, parts, expected_text, reason): admins and ops managers at aal2, one person
--     (Q6's default), an idempotency key (its advisory lock first, under a 7 s lock_timeout, then 2 s), the parts
--     parsed and their ids filtered by the line's servicer before any rule or lock (critic CSO-5), the job's lock order
--     plus the drafts (§3.8), the rules of §3.4 read under the locks, compare and set on the expected text (§3.9),
--     the posting (§3.7), the drafts re-prepared (§3.6.5) and the funds pass queued (critic CSO-11, critic2 CSO2-7);
--   * an unplanned payout's P per item (§3.6.1, Q4's default: what the late or second payout paid of the items it was
--     meant to pay, still owed and waiting, signed, net of reversals, counted once across bookings, capped by the
--     queue), its −A pending row, its `double_payout` advance of A − P, its attributions (private.unplanned_paid_item);
--   * the returns the job does not book (S16, S20, U) and the two unplanned return kinds (S27, S28);
--   * the reads public.transfer_line_options and public.transfer_line_preview (6b-2c's sheets; money staff only).
-- No page ships in this slice (6b-2c): the command is callable through the API by an aal2 admin or ops manager. The
-- cancellation-after-download switch stays OFF; pgTAP 033 and 034 unchanged.
--
-- New: private.unplanned_paid_item (append-only, RLS on, every privilege revoked), client_advance_cause_idx,
-- bank_transfer_filed_amount_idx, client_advance.p_bound (review LT-4); bank_transaction (and
-- private.bank_import_stage) charges_read and unsplit_direction_given (COMPLIANCE OQ-84 (j), 6b-2a's known limit: a
-- re-import compares the stored values with every value the new file gives, and only with those);
-- private.transfer_line_class, private.transfer_line_candidates, private.transfer_line_members,
-- private.transfer_line_returnable, private.transfer_line_parse, private.transfer_line_check,
-- private.transfer_line_text, private.transfer_line_locks, private.transfer_line_post, private.remittance_draft_requeue,
-- private.unsplit_details_differ, private.transfer_line_preview_of (review CSR-3), private.remittance_run_late_lines
-- and private.transfer_line_bb (CI scale fix), public.book_transfer_line, public.transfer_line_preview,
-- public.transfer_line_options.
-- Redefined, each copied from its latest definition and changed only as its comment says, with its settings and grants
-- restated: private.bank_line_booking_guard (20261116090000), private.pending_item_deadlines (20261116090000),
-- private.bank_booking_post_rows (20261116090000), private.ingest_statement (20261117090000),
-- private.post_bank_bookings (20261117090000; review CSR-1), private.remittance_statement_build (20261116090000; review
-- LT-2).

------------------------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------------------------

-- What each unplanned booking's P counted, item by item (plan §3.1, §3.6.4; critic F4, F2, L1): the booking's
-- `remittance` entry and the item it counted. An attribution counts while its booking entry is not reversed (an
-- unplanned return reverses it: those items are owed again, the +P the return re-queues). Written only by
-- private.transfer_line_post (SECURITY DEFINER); read by private.pending_item_deadlines (the re-owed item's date,
-- critic2 ML-2) and by 6b-2d's « Suivi ». Private, never exposed: RLS on with no policy, every privilege revoked
-- (critic2 CSO2-11, as private.remittance_pending); append-only, each row its own history (no change-log trigger: like
-- every private table).
create table private.unplanned_paid_item (
  booking_entry_id uuid not null references public.ledger_entry (id),
  ledger_entry_id uuid not null references public.ledger_entry (id),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  currency char(3) not null,
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  created_at timestamptz not null default clock_timestamp(),
  primary key (booking_entry_id, ledger_entry_id)
);
create index unplanned_paid_item_entry_idx on private.unplanned_paid_item (ledger_entry_id);
create trigger unplanned_paid_item_append_only before update or delete or truncate on private.unplanned_paid_item
  for each statement execute function private.refuse_change();
alter table private.unplanned_paid_item enable always trigger unplanned_paid_item_append_only;
alter table private.unplanned_paid_item enable row level security;
revoke all on private.unplanned_paid_item from public, anon, authenticated, service_role;
comment on table private.unplanned_paid_item is
  'What each unplanned payout''s P counted, item by item (M2c-6b-2b, plan §3.6.1): counts while its booking entry is '
  'not reversed.';

-- The advance of an unplanned booking, by key (the rules, the reads and the return read it by its remittance).
create index client_advance_cause_idx on public.client_advance (cause_entry_id);
-- (review LT-4, critic2 ML-9) which bound set the P of the unplanned payout a double_payout advance covers: `items` (what
-- was still owed of the items its transfer was meant to pay), `queue` (what the client's queue could net) or `none` (no
-- items: a booked payout debited again, a client part). An advance exists only when P < A (`amount`: none). Kept with the
-- advance, written by private.transfer_line_post, so « Suivi » (6b-2d) words the advance clause from it, never from a
-- guess; null on the other causes.
alter table public.client_advance
  add column p_bound text,
  add constraint client_advance_p_bound_check check (
    p_bound is null or (cause = 'double_payout' and p_bound in ('items', 'queue', 'none')));
comment on column public.client_advance.p_bound is
  'A double_payout advance: the bound that set its unplanned payout''s P (items, queue, none). Null otherwise.';
-- Every transfer ever put in a file, by account and amount (critic2 CSO2-13, ML-10): rule 3b's probe per line
-- (§3.4.4) and the fee check (§3.4.10). bank_transfer_debtor_idx holds only ordered/in_file transfers,
-- bank_transfer_cancelled_filed_idx is led by the servicer and holds no amount.
create index bank_transfer_filed_amount_idx on public.bank_transfer (debtor_bank_account_id, amount_minor)
  where transfer_file_id is not null;

-- COMPLIANCE OQ-84 (j), 6b-2a's known limit (the verifier's: the same entries exported again in another camt.053
-- version, or without the details' CdtDbtInd, refused the whole file entry_detail_differs). A re-import compares the
-- stored values with every value the new file gives, and only with those (review CSR-4: whether or not the stored file
-- gave the value), so the line keeps what its file gave:
--   * charges_read — whether the charges of a line that is its entry's only line were read: true when the entry had no
--     charges block or every record was readable (charges_minor the total, or null for none), false when a block was
--     seen but not read (camt.053.001.02's `Chrgs`, a record not the bank's debit in the account's currency included in
--     the entry); null on every other line and on lines imported before this migration (treated as given);
--   * unsplit_direction_given — for an entry kept unsplit, per detail of ours (the details' order), whether its
--     CdtDbtInd was given (else the parser takes the entry's); null when unknown (treated as given).
alter table public.bank_transaction
  add column charges_read boolean,
  add column unsplit_direction_given boolean[],
  add constraint bank_transaction_charges_read_check check (charges_read is not false or charges_minor is null),
  add constraint bank_transaction_direction_given_check check (
    unsplit_direction_given is null
    or (unsplit_details is not null and cardinality(unsplit_direction_given) = jsonb_array_length(unsplit_details)
        and array_position(unsplit_direction_given, null) is null));
comment on column public.bank_transaction.charges_read is
  'Whether the statement''s charges of a line that is its entry''s only line were read (false: a block seen, not '
  'read); null otherwise. A re-import compares the charges when the new file read them (COMPLIANCE OQ-84 (j)).';
comment on column public.bank_transaction.unsplit_direction_given is
  'Entry kept unsplit: per detail of ours, whether its CdtDbtInd was given (else the entry''s was taken). A re-import '
  'compares a detail''s direction when the new file gives it (COMPLIANCE OQ-84 (j)).';
alter table private.bank_import_stage
  add column charges_read boolean,
  add column unsplit_direction_given boolean[];

------------------------------------------------------------------------------------------
-- Line facts (plan §3.3–§3.5): the class, rule 3b's candidates, a lot's members (debit) and returnable members (credit)
------------------------------------------------------------------------------------------

-- The line's class (§3.3; the first that applies): U an entry kept unsplit holding a detail of ours; E our id — a
-- debit's end-to-end id, a credit's original (else own) id naming a transfer of the line's servicer (of any of its
-- accounts: another account is transfer_differs, each kind's rule); B our lot — a debit with no end-to-end id naming
-- a PmtInf of a file of the line's account, or a credit naming a handed-out lot of it (private.names_our_lot) whose
-- ids name nothing of ours; E0 (« E∅ ») an RMT/SWP-shaped id or a TF PmtInfId naming nothing of ours; N neither an
-- end-to-end id nor a PmtInfId; O anything else. Keyed (bank_transfer's end_to_end_id is unique; the PmtInf's items
-- by transfer_file_item_pmt_inf_idx; CI scale fix: each probe of an id holds the id alone, the servicer compared outside
-- it — a second condition lets stale statistics read every transfer of the servicer through bank_transfer_org_idx).
create or replace function private.transfer_line_class(p_line_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case
    when coalesce(t.unsplit_ours, 0) > 0 then 'U'
    when t.direction = 'debit' and t.end_to_end_id is not null
         and exists (select 1 from (select x.organization_id from public.bank_transfer x
                                    where x.end_to_end_id = t.end_to_end_id offset 0) x
                     where x.organization_id = t.organization_id) then 'E'
    when t.direction = 'credit' and coalesce(t.original_end_to_end_id, t.end_to_end_id) is not null
         and exists (select 1 from (select x.organization_id from public.bank_transfer x
                                    where x.end_to_end_id = coalesce(t.original_end_to_end_id, t.end_to_end_id)
                                    offset 0) x
                     where x.organization_id = t.organization_id) then 'E'
    when t.direction = 'debit' and t.end_to_end_id is null and t.payment_info_id is not null
         and exists (select 1
                     from (select i.file_id from public.transfer_file_item i where i.pmt_inf_id = t.payment_info_id
                           offset 0) i
                     cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                         where f.id = i.file_id offset 0) f
                     where f.debtor_bank_account_id = t.bank_account_id) then 'B'
    when t.direction = 'credit' and private.names_our_lot(t.bank_account_id, t.payment_info_id) then 'B'
    when coalesce(case when t.direction = 'credit' then coalesce(t.original_end_to_end_id, t.end_to_end_id)
                       else t.end_to_end_id end ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
         or coalesce(t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$', false) then 'E0'
    when t.end_to_end_id is null and t.payment_info_id is null then 'N'
    else 'O' end
  from public.bank_transaction t where t.id = p_line_id;
$$;

-- Rule 3b's candidates of a debit carrying no reference of ours (§3.4.4; critic F9, F12, F13, L12; critic2 ML-4, ML-8,
-- CSO2-13), driven from the line: one probe of bank_transfer_filed_amount_idx on (account, amount), then each
-- transfer's file, item, run and payee IBAN by key — never a date range scan of the account's lines:
--   (i)   payouts and sweeps in_file in a downloaded or sent file of the account, a re-issue included, a payout's run
--         approved or sent with it, the item's execution date in that file on or before the line's date;
--   (ii)  refunds in_file in a downloaded or sent file, re-issuing none, executed on or before the line's date;
--   (iii) payouts cancelled or returned that were in a file of the account downloaded at least once, executed on or
--         before the line's date — a returned one not while its return item is held by a live line of a run whose
--         payout is a (i) candidate of this line (ML-8: that run re-pays it to the same account);
-- each to the line's counterparty IBAN when it has one; a line of class O or E0 without one has none. The line's
-- class is the caller's (p_class). cand: 'i', 'ii', 'iii'.
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
    from public.bank_transaction t
    where t.id = p_line_id and t.direction = 'debit' and p_class in ('N', 'O', 'E0')
      and (p_class = 'N' or t.counterparty_iban is not null)),
  x as materialized (
    select q.id, q.kind, q.status, q.run_id, q.replaces_transfer_id, q.return_entry_id, i.execution_date,
           f.status as file_status, f.download_count, ru.status as run_status, ru.transfer_id as run_transfer
    from l
    cross join lateral (select q.id, q.organization_id, q.kind, q.status, q.currency, q.payee_iban, q.transfer_file_id,
                               q.run_id, q.replaces_transfer_id, q.return_entry_id
                        from public.bank_transfer q
                        where q.debtor_bank_account_id = l.bank_account_id and q.amount_minor = l.amount_minor
                          and q.transfer_file_id is not null offset 0) q
    cross join lateral (select f.status, f.download_count from public.transfer_file f
                        where f.id = q.transfer_file_id offset 0) f
    cross join lateral (select i.execution_date from public.transfer_file_item i
                        where i.file_id = q.transfer_file_id and i.transfer_id = q.id offset 0) i
    left join lateral (select r.status, r.transfer_id from public.remittance_run r where r.id = q.run_id offset 0) ru
      on true
    where q.organization_id = l.organization_id and q.currency = l.currency
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

-- A debit lot's universe M (§3.5): every item of the PmtInf the line names in its file of the line's account, whatever
-- the member's status, in the file's order (seq) — the order private.unique_subset visits. Keyed: the PmtInf's items,
-- then each file and transfer by key. The caller counts first (lot_too_large) by a keyed count.
create or replace function private.transfer_line_members(p_line_id uuid)
returns table (seq integer, file_id uuid, transfer_id uuid, kind text, status text, amount_minor bigint,
               transfer_file_id uuid, file_downloads integer, file_status text, client_organization_id uuid,
               run_id uuid, end_to_end_id text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select i.seq, i.file_id, m.id, m.kind, m.status, m.amount_minor, m.transfer_file_id, f.download_count, f.status,
         m.client_organization_id, m.run_id, m.end_to_end_id
  from (select t.bank_account_id, t.payment_info_id from public.bank_transaction t where t.id = p_line_id) l
  cross join lateral (select y.file_id, y.seq, y.transfer_id from public.transfer_file_item y
                      where y.pmt_inf_id = l.payment_info_id offset 0) i
  cross join lateral (select q.debtor_bank_account_id, q.download_count, q.status from public.transfer_file q
                      where q.id = i.file_id offset 0) f
  cross join lateral (select q.id, q.kind, q.status, q.amount_minor, q.transfer_file_id, q.client_organization_id,
                             q.run_id, q.end_to_end_id
                      from public.bank_transfer q where q.id = i.transfer_id offset 0) m
  where f.debtor_bank_account_id = l.bank_account_id
  order by i.seq;
$$;

-- A lot credit's returnable members (§3.5; critic F1): the PmtInf's members booked there and not returned, and its
-- members with an open unplanned booking (private.transfer_unplanned_open), one element per member at its amount, in
-- the file's order. Such a member takes the unplanned return of its open booking with the largest advance.
create or replace function private.transfer_line_returnable(p_line_id uuid)
returns table (seq integer, transfer_id uuid, kind text, status text, amount_minor bigint, unplanned_open boolean,
               client_organization_id uuid, run_id uuid, end_to_end_id text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select m.seq, m.transfer_id, m.kind, m.status, m.amount_minor, u.open, m.client_organization_id, m.run_id,
         m.end_to_end_id
  from private.transfer_line_members(p_line_id) m
  cross join lateral (select private.transfer_unplanned_open(m.transfer_id) as open) u
  where m.kind in ('payout', 'sweep')
    and ((m.status = 'booked' and m.transfer_file_id = m.file_id) or u.open)
  order by m.seq;
$$;

-- The open unplanned bookings of a transfer (or, with p_transfer null, of client p_client on debits to the IBAN
-- p_iban), by the advance each still carries: the largest first, ties by the earliest line — its booking date, then
-- the unplanned entry's posting time (§3.4.13 rule 4). Keyed:
-- the transfer's bookings by bank_line_booking_transfer_idx (or the servicer's client-only unplanned bookings by the
-- entries' client), each entry's reversal by ledger_entry_reversed_once_uq, its advance by client_advance_cause_idx.
create or replace function private.transfer_line_open_unplanned(p_org uuid, p_transfer uuid, p_client uuid,
                                                                p_iban text, p_kind text)
returns table (line_id uuid, entry_id uuid, amount_minor bigint, advance_minor bigint, advance_id uuid,
               advance_entry_id uuid, line_date date, entry_date date, client_organization_id uuid, iban text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select k.bank_transaction_id, k.entry_id, k.amount_minor, coalesce(a.amount_minor, 0), a.id, a.entry_id,
         t.booking_date, e.effective_date, e.client_organization_id, t.counterparty_iban
  from (select q.bank_transaction_id, q.entry_id, q.amount_minor from public.bank_line_booking q
        where p_transfer is not null and q.transfer_id = p_transfer and q.kind = p_kind
        union all
        select q.bank_transaction_id, q.entry_id, q.amount_minor
        from (select le.id from public.ledger_entry le
              where p_transfer is null and le.organization_id = p_org and le.client_organization_id = p_client
                and le.entry_type = 'remittance' and le.source_type = 'bank_transaction' offset 0) le
        cross join lateral (select q.bank_transaction_id, q.entry_id, q.amount_minor, q.transfer_id
                            from public.bank_line_booking q where q.entry_id = le.id offset 0) q
        where q.transfer_id is null) k
  cross join lateral (select q.effective_date, q.client_organization_id, q.posted_at from public.ledger_entry q
                      where q.id = k.entry_id offset 0) e
  cross join lateral (select q.booking_date, q.counterparty_iban from public.bank_transaction q
                      where q.id = k.bank_transaction_id offset 0) t
  left join lateral (select q.id, q.amount_minor, q.entry_id from public.client_advance q
                     where q.cause_entry_id = k.entry_id and q.cause = 'double_payout' offset 0) a on true
  where not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = k.entry_id offset 0)
    and (p_transfer is not null or t.counterparty_iban = p_iban)
  order by coalesce(a.amount_minor, 0) desc, t.booking_date, e.posted_at, k.bank_transaction_id;
$$;

------------------------------------------------------------------------------------------
-- The request (plan §3.4.0, §3.4.1)
------------------------------------------------------------------------------------------

-- The parts asked (§3.4.0; critic CSO-3, critic2 CSO2-2): an array of 1 to private.transfer_line_lot_cap() objects
-- {kind, transfer_id?, client_id?, returns_line_id?, amount} (amount digits, as text or a number, > 0), into
-- pg_temp._tl_req; null, else 'bad_request'. payout, sweep and their returns take a transfer; an unplanned payout and
-- its return exactly one of a transfer or a client; an unplanned sweep and its return a transfer or nothing; the two
-- unplanned returns, and only they, the debit line they return (returns_line_id); a fee nothing. No two parts alike,
-- no transfer named twice (a line books a transfer once: one copy of a member per lot), at most one fee and at most
-- one part without a transfer (critic F15: the fee sits only beside a transfer part, so the two never meet). Part n is
-- its 1-based position: it keys the entries.
create or replace function private.transfer_line_parse(p_parts jsonb)
returns text
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._tl_req;
  create temp table _tl_req (
    n integer primary key,
    kind text not null,
    transfer_id uuid,
    client_id uuid,
    returns_line_id uuid,
    amount bigint not null
  ) on commit drop;
  if p_parts is null or jsonb_typeof(p_parts) <> 'array' or jsonb_array_length(p_parts) < 1
     or jsonb_array_length(p_parts) > private.transfer_line_lot_cap() then
    return 'bad_request';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_parts) e
    where jsonb_typeof(e) <> 'object'
       or exists (select 1 from jsonb_object_keys(e) k
                  where k not in ('kind', 'transfer_id', 'client_id', 'returns_line_id', 'amount'))
       or jsonb_typeof(e -> 'kind') is distinct from 'string'
       or coalesce(jsonb_typeof(e -> 'amount') not in ('string', 'number'), true)
       or coalesce((e ->> 'amount') !~ '^[0-9]{1,16}$', true)
       or exists (select 1 from unnest(array['transfer_id', 'client_id', 'returns_line_id']) f
                  where e ? f and jsonb_typeof(e -> f) <> 'null'
                    and (jsonb_typeof(e -> f) <> 'string' or not pg_input_is_valid(e ->> f, 'uuid')))) then
    return 'bad_request';
  end if;
  insert into pg_temp._tl_req (n, kind, transfer_id, client_id, returns_line_id, amount)
  select x.o::integer, x.e ->> 'kind', (x.e ->> 'transfer_id')::uuid, (x.e ->> 'client_id')::uuid,
         (x.e ->> 'returns_line_id')::uuid, (x.e ->> 'amount')::bigint
  from jsonb_array_elements(p_parts) with ordinality x (e, o);
  if exists (
    select 1 from pg_temp._tl_req r
    where r.amount <= 0 or r.amount > 1000000000000000
       or r.kind not in ('payout', 'sweep', 'unplanned_payout', 'unplanned_sweep', 'fee', 'payout_returned',
                         'sweep_returned', 'unplanned_payout_returned', 'unplanned_sweep_returned')
       or (r.kind in ('payout', 'sweep', 'payout_returned', 'sweep_returned')
           and (r.transfer_id is null or r.client_id is not null))
       or (r.kind in ('unplanned_payout', 'unplanned_payout_returned') and (r.transfer_id is null) = (r.client_id is null))
       or (r.kind in ('unplanned_sweep', 'unplanned_sweep_returned') and r.client_id is not null)
       or (r.kind = 'fee' and (r.transfer_id is not null or r.client_id is not null))
       or (r.kind in ('unplanned_payout_returned', 'unplanned_sweep_returned')) <> (r.returns_line_id is not null))
     or (select count(*) <> count(distinct (r.kind, r.transfer_id, r.client_id, r.returns_line_id))
         from pg_temp._tl_req r)
     or (select count(r.transfer_id) <> count(distinct r.transfer_id) from pg_temp._tl_req r)
     or (select count(*) filter (where r.kind = 'fee') > 1 or count(*) filter (where r.transfer_id is null) > 1
         from pg_temp._tl_req r) then
    return 'bad_request';
  end if;
  return null;
end;
$$;

-- The tenant filter (§3.4.1; critic CSO-5, F16), before any rule and any lock, in the command and the preview alike:
-- every transfer_id a bank_transfer of the line's servicer and every returns_line_id one of its bank lines, else
-- transfer_unknown; every client_id a client of the servicer, else client_unknown — the same code for an absent id and
-- another servicer's, in part order. Keyed (primary keys; CI scale fix: each id's row by its key alone, in a lateral,
-- the servicer compared outside it, enable_seqscan off — as `not exists (… and organization_id = p_org)` the planner
-- hashed every transfer, bank line or client of the servicer, once per call, by its servicer index or a sequential scan).
create or replace function private.transfer_line_tenant(p_org uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
begin
  return (select case
    when r.transfer_id is not null and x.organization_id is distinct from p_org then 'transfer_unknown'
    when r.returns_line_id is not null and t.organization_id is distinct from p_org then 'transfer_unknown'
    else 'client_unknown' end
  from pg_temp._tl_req r
  left join lateral (select q.organization_id from public.bank_transfer q where q.id = r.transfer_id offset 0) x on true
  left join lateral (select q.organization_id from public.bank_transaction q where q.id = r.returns_line_id
                     offset 0) t on true
  left join lateral (select q.servicer_organization_id from public.organization q where q.id = r.client_id
                     offset 0) o on true
  where (r.transfer_id is not null and x.organization_id is distinct from p_org)
     or (r.returns_line_id is not null and t.organization_id is distinct from p_org)
     or (r.client_id is not null and o.servicer_organization_id is distinct from p_org)
  order by r.n
  limit 1);
end;
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
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- The rules (plan §3.4, §3.5) and the effects (§3.6), read under the command's locks or, for the preview, without
------------------------------------------------------------------------------------------

-- Whether a pending item is an unplanned booking's own (critic2 ML-1): the −A row of an unplanned payout, the
-- `double_payout` advance posted with it, or the reversal of either. The attributions already count what those
-- bookings netted, so a pool never counts them again. Keyed.
create or replace function private.unplanned_own_item(p_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select exists (select 1 from public.bank_line_booking k where k.entry_id = e.id and k.kind = 'unplanned_payout')
      or exists (select 1 from public.client_advance a where a.entry_id = e.id and a.cause = 'double_payout')
      or (e.reverses_entry_id is not null
          and (exists (select 1 from public.bank_line_booking k where k.entry_id = e.reverses_entry_id
                         and k.kind = 'unplanned_payout')
               or exists (select 1 from public.client_advance a where a.entry_id = e.reverses_entry_id
                            and a.cause = 'double_payout')))
  from public.ledger_entry e where e.id = p_entry_id;
$$;

-- The check (§3.4 in order; the first failure is the refusal): the request pg_temp._tl_req (parsed and filtered by
-- tenant), the facts pg_temp._tl_pre / _tl_meta read before the locks (private.transfer_line_pre). Fills pg_temp._tl
-- (one row per part: its facts and effects — the client, A, P, the advance, which bound set P, late, the account
-- credited, the unplanned booking a return reverses), pg_temp._tl_items (P's attributions per part) and
-- pg_temp._tl_drafts (the client drafts to re-prepare). Returns {why, detail}: why null when the parts may be booked.
-- p_locked (the command, under private.transfer_line_locks): every status the subset, the candidates or the drafts
-- depended on is read again and a change is `split_changed` — a draft found that the locks did not take, a candidate or
-- a lot credit's member that was not collected. The preview runs it unlocked and never raises.
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
        -- (CI scale fix) the run's lines by its key alone, the conditions outside: `not released` inside let a stale
        -- estimate of the run pick a whole scan of remittance_line_live_uq or remittance_line_account_idx, per part
        update pg_temp._tl t set c = r.tr_client, a = r.amount,
          late = r.kind = 'payout' and exists (
            select 1
            from (select q.amount_minor, q.released, q.latest_execution_date from public.remittance_line q
                  where q.run_id = r.tr_run offset 0) q
            where q.amount_minor > 0 and not q.released and q.latest_execution_date < l.booking_date)
        where t.n = r.n;

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

-- The compare-and-set text (§3.9): the parts in order, each kind:transfer_or_client:amount:P:advance:returns_line,
-- joined by `;`, then `|drafts:` and the client drafts to re-prepare. The options read, the preview and the command
-- compute it with this function on the same rules; any difference under the locks is split_changed.
create or replace function private.transfer_line_text()
returns text
language plpgsql
stable
set search_path = ''
as $$
begin
  return coalesce((select string_agg(t.kind || ':' || coalesce(coalesce(t.transfer_id, t.client_id)::text, '') || ':'
                                     || t.amount || ':' || t.p || ':' || t.adv || ':'
                                     || coalesce(t.returns_line_id::text, ''), ';' order by t.n)
                   from pg_temp._tl t), '')
         || '|drafts:' || coalesce((select string_agg(d.run_id::text, ',' order by d.run_id)
                                    from pg_temp._tl_drafts d), '');
end;
$$;

------------------------------------------------------------------------------------------
-- The locks (plan §3.8): the job's order (private.post_bank_bookings), plus the drafts
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
-- CI scale fix (ADR-0014 « M2c-6b-2b review fixes »): every read is keyed whatever the statistics — enable_seqscan off,
-- each lateral holding its row's key alone and the other conditions outside it. Step 4 held the run's conditions inside
-- its lateral: after the 50,000-line runs (two runs holding 100,000 of remittance_line's 101,000 lines), each of a
-- 500-member lot's runs was read by a sequential scan of remittance_line, 500 times, past the API's 8 s. Same rows,
-- same locks, same order.
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
          select i.file_id from public.transfer_file_item i where i.pmt_inf_id = l.payment_info_id
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
-- The posting (plan §3.6, §3.7), the drafts (§3.6.5)
------------------------------------------------------------------------------------------

-- The command's pg_temp._bb (private.transfer_line_post, step 2): private.post_bank_bookings' select list
-- (20261117090000, unchanged by its redefinition below), copied — the same columns in the same order (pgTAP 037) —,
-- book_minor the part's amount (pg_temp._tl), analysed. CI scale fix (ADR-0014 « M2c-6b-2b review fixes »): built under
-- enable_seqscan off in this function's own settings, so its lookups by key, once per part (the line's bookings and
-- debit links, each transfer's bookings), are never a sequential scan per part when the statistics call those tables
-- small (a lot at the cap read bank_line_booking whole about 2,000 times); the posting that follows keeps its caller's
-- settings.
create or replace function private.transfer_line_bb(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  l public.bank_transaction;
begin
  select * into l from public.bank_transaction where id = p_line_id;
  drop table if exists pg_temp._bb;
  create temp table _bb on commit drop as
  select b.*, t.organization_id as line_org, t.bank_account_id as line_bank, t.direction, t.currency,
         t.amount_minor as line_minor, t.booking_date as line_date, coalesce(dr.released_kind, t.kind) as line_kind,
         (t.kind = 'suspected_duplicate' and dr.decision is distinct from 'released') as held,
         t.counterparty_iban, t.end_to_end_id, coalesce(t.original_end_to_end_id, t.end_to_end_id) as returned_id,
         t.payment_info_id, t.unsplit_ours,
         (t.direction = 'debit' and t.end_to_end_id is null and t.payment_info_id is not null) as batch_line,
         (exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = b.bank_transaction_id offset 0)
          or exists (select 1 from public.bank_own_credit_release c
                     where c.bank_transaction_id = b.bank_transaction_id offset 0)) as booked,
         (select l2.kind from public.bank_debit_link l2 where l2.bank_transaction_id = b.bank_transaction_id) as link_kind,
         coalesce((select -sum(p.amount_minor) from public.bank_debit_link l2
                   join public.ledger_posting p on p.entry_id = l2.cash_entry_id
                   where l2.bank_transaction_id = b.bank_transaction_id and l2.kind = 'return'
                     and (select la.book from public.ledger_account la where la.id = p.ledger_account_id)
                         = 'client_money_cash'), 0)::bigint as linked_minor,
         x.organization_id as tr_org, x.kind as tr_kind, x.status as tr_status,
         x.creditor_bank_account_id as tr_creditor, x.debtor_bank_account_id as tr_debtor,
         x.amount_minor as tr_minor, x.currency as tr_currency, x.end_to_end_id as tr_e2e,
         x.transfer_file_id as tr_file, x.run_id as tr_run, x.client_organization_id as tr_client,
         x.entry_id as tr_entry,
         f.status as file_status, f.download_count as file_downloads,
         (select i.pmt_inf_id from public.transfer_file_item i
          where i.file_id = x.transfer_file_id and i.transfer_id = x.id) as tr_pmt_inf,
         exists (select 1 from public.bank_line_booking k where k.transfer_id = b.transfer_id
                   and k.kind in ('payout', 'sweep', 'top_up') offset 0) as tr_debit_booked,
         exists (select 1 from public.bank_line_booking k where k.transfer_id = b.transfer_id
                   and k.kind in ('payout_returned', 'sweep_returned') offset 0) as tr_return_booked,
         case when b.kind in ('payout_returned', 'sweep_returned') and x.organization_id = l.organization_id
              then private.transfer_unplanned_open(b.transfer_id) end as tr_unplanned_open,
         case when b.kind in ('payout_returned', 'sweep_returned') and x.organization_id = l.organization_id
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
  update pg_temp._bb b set book_minor = t.amount from pg_temp._tl t where t.n = b.ord;
  analyze pg_temp._bb;
end;
$$;

-- Posts pg_temp._tl (checked under the locks), all at the line's booking date, in this order:
-- 1. what this function posts itself: the unplanned remittances (+4670[c] A / −5120 A, remit:line:<line>:<n>, the
--    transfer or the line their document) and sweeps (+4679 S / −5120 S ‖ +5122[own] S / −4689 S, sweep:line:<line>:<n>);
--    their advances of A − P (client_advance, cause double_payout: +4679 / −4670[c] ‖ +4112[c] / −4689,
--    adv:line:<line>:<n>, the trigger queueing +(A − P)); each unplanned payout's −A pending row (the 4670 trigger skips
--    remittance entries) and its attributions; the returns (the transfer's entry reversed, return:<line>:<transfer>,
--    one key per transfer for a lot credit, §1.3 item 12) and the unplanned returns (the unplanned entry reversed,
--    return:<line>:<n>, and its advance, return:adv:<line>:<n>: the trigger queues +A and −(A − P), net +P); the
--    bookings of these parts (seq: the line's last + their rank); the transfers returned; the payout accounts
--    returned (only while active);
-- 2. the planned parts (payout, sweep, fee) through private.bank_booking_post_rows, pg_temp._bb built with exactly the
--    columns private.post_bank_bookings builds (its select list, as redefined by 20261117090000, copied; book_minor =
--    the part's amount): settlements, covers, breach rows, runs booked, the line's review deleted, the ledger's checks
--    and the line's completeness (a fee's and a sweep's entry take the motif as their reason, as the job's rows take
--    theirs: those entries are the servicer's own);
-- 3. without planned parts: the line's review deleted, the ledger's checks, the line's signed completeness.
-- The entries a client's whole-client members read (remittance, client_advance, reversal: critic CSO-1) take fixed French
-- texts, never ops' motif; the motif goes to bank_line_booking.reason (staff only) and — as public.link_debit does
-- for the fees, top-ups and losses ops book (M2c-1) — is the reason of the servicer's own fee and sweep
-- entries (bank_fee, servicer_sweep of a planned `fee` or `sweep` part: no client, read by money staff only; review LT-7).
-- Its pg_temp._bb (private.transfer_line_bb) is private.post_bank_bookings' (its select list unchanged since
-- 20261117090000).
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
    insert into public.client_advance (id, organization_id, client_organization_id, currency, amount_minor, cause,
                                       cause_entry_id, entry_id, bank_transaction_id, transfer_id, p_bound)
    select t.adv_id, l.organization_id, t.c, l.currency, t.adv, 'double_payout', t.entry_id, t.adv_entry_id, l.id,
           t.transfer_id, t.p_bound
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
    and x.id = s.transfer_id;
  update public.client_payout_account a set status = 'returned'
  where a.id = any (array(select t.payout_account from pg_temp._tl t where t.payout_account is not null))
    and a.status = 'active';

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

-- A client's draft re-prepared after an unplanned payout or return (plan §3.6.5; critic CSO-6, CSO-7, CSO-12; §1.3
-- item 4): its row locked by the command (step 1 of the locks), the client's unreserved pending items reserved (the
-- −A row and the advance just posted among them), then the job queued under a new token, K now, the prepared fields,
-- the approval's request (execution date, late reason) and last_failure reset (a requeue is not a failure: the web
-- words any last_failure of step prepare as a failed preparation), item_count recounted, version + 1. The prepared
-- draft is not cleared here: private.remittance_prepare_begin clears it under the run lock when the new token's job
-- starts (clearing a 50,000-line draft under both servicer-wide locks would hold off the allocation and every approval),
-- and the approval refuses job = 'prepare'. An approval or prepare in flight finds another token and does nothing.
create or replace function private.remittance_draft_requeue(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.remittance_run;
  v_token uuid := gen_random_uuid();
  v_n integer;
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or r.status <> 'draft' then
    return;
  end if;
  update private.remittance_pending q set draft_run_id = r.id
  where q.organization_id = r.organization_id and q.client_organization_id = r.client_organization_id
    and q.currency = r.currency and q.draft_run_id is null;
  select count(*)::integer into v_n from private.remittance_pending q where q.draft_run_id = r.id;
  update public.remittance_run set job = 'prepare', job_token = v_token, job_queued_at = clock_timestamp(),
    known_at = clock_timestamp(), service_to = (clock_timestamp() at time zone 'Europe/Paris')::date,
    prepared_at = null, inputs_hash = null, line_count = null, item_count = v_n, requested_execution_date = null,
    late_reason = null, last_failure = null, version = version + 1
  where id = r.id;
  perform pgmq.send('remittances', jsonb_build_object('type', 'prepare', 'run_id', r.id, 'token', v_token));
end;
$$;

------------------------------------------------------------------------------------------
-- The command (plan §3.2) and its reads (§3.11)
------------------------------------------------------------------------------------------

-- The parts of pg_temp._tl as the reads and the result give them (amounts as text), with what the sheets show of
-- each: the transfer's id, run and status, the client's name (never another servicer's: every id passed the tenant
-- filter).
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
           order by t.n), '[]')
  from pg_temp._tl t);
end;
$$;

-- Whether the booking checked in pg_temp._tl lowers the servicer's share under a generated file's sweep (§3.11;
-- critic2 CSO2-4): its effect on 4679 — the planned payouts' settlements (+D), their payout_overrun covers, a fee, an
-- unplanned payout's advance, an unplanned sweep (−) — read against generate_transfer_file's formula (−Σ 4679 of the
-- servicer and currency, less the other sweeps ordered or in a file) for each generated file's in_file sweep; the first
-- such file whose sweep would then exceed the share, {file_id, number}, or null. Only when the booking lowers it.
create or replace function private.transfer_line_supersedes(p_line_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  l public.bank_transaction;
  v_lower bigint;
  v_raise bigint;
  v_share bigint;
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
  for v_file in
    select f.id, f.number, s.id as sweep_id, s.amount_minor
    from public.transfer_file f
    cross join lateral (select t.id, t.amount_minor from public.bank_transfer t
                        where t.transfer_file_id = f.id and t.kind = 'sweep' and t.status = 'in_file' offset 0) s
    where f.organization_id = l.organization_id and f.status = 'generated' and f.currency = l.currency
    order by f.created_at, f.id
  loop
    if v_file.amount_minor > v_share - (select coalesce(sum(x.amount_minor), 0) from public.bank_transfer x
                                        where x.organization_id = l.organization_id and x.kind = 'sweep'
                                          and x.currency = l.currency and x.status in ('ordered', 'in_file')
                                          and x.id <> v_file.sweep_id) then
      return jsonb_build_object('file_id', v_file.id, 'number', v_file.number);
    end if;
  end loop;
  return null;
end;
$$;

-- « Comptabiliser » a line of our transfers (plan §3.2): admins and ops managers of the line's servicer at aal2 (one
-- person: Q6's default), by idempotency key. Steps: the role (the same answer for an absent line); the key's advisory
-- lock, under a 7 s lock_timeout (a double tap waits for the first call, up to its 4 s budget, and gets its stored
-- result, never already_booked: critic CSO-12, critic2 CSO2-6), then 2 s again for every later lock; the replay (the
-- normalised request); the reason; the parts parsed, the expected text required; the tenant filter; what runs before
-- the locks (a lot's count and subset, rule 3b's candidates); the locks (§3.8); the check under them (§3.4: the first
-- refusal raised, `transfer line booking refused: <code>`, check_violation); compare and set on the expected text
-- (split_changed); the posting (§3.7; a ledger refusal raised posting_failed); the drafts re-prepared (§3.6.5); the
-- funds pass queued whenever a payout or sweep part (planned or unplanned) or an unplanned return was booked (critic
-- CSO-11, critic2 CSO2-7: S18's exit, and the job's next reading of the transfer's other return lines); the result
-- recorded. Budget (critic CSO-3): ≤ 4 s at the lot cap, under the API's 8 s statement_timeout.
create or replace function public.book_transfer_line(p_idempotency_key text, p_bank_transaction_id uuid, p_parts jsonb,
                                                     p_expected_text text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  l public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_why text;
  v_chk jsonb;
  v_text text;
  v_state text;
  v_msg text;
  v_funds boolean;
begin
  select * into l from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(l.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  perform set_config('lock_timeout', '7s', true);
  -- (review CSR-2) the two-key form, in a class of its own: its lock tag never equals a one-key advisory lock — a key
  -- whose hash is another servicer's `payments:` or `remit:` (or this servicer's, taken before its runs) never holds it
  perform pg_advisory_xact_lock(hashtext('cmd:book_transfer_line'), hashtext(coalesce(p_idempotency_key, '')));
  perform set_config('lock_timeout', '2s', true);
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'parts', p_parts,
                                  'expected_text', p_expected_text, 'reason', v_reason);
  v_result := private.command_replay('book_transfer_line', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  v_why := private.transfer_line_parse(p_parts);
  if v_why is null and (p_expected_text is null or btrim(p_expected_text) = '' or length(p_expected_text) > 100000) then
    v_why := 'bad_request';
  end if;
  v_why := coalesce(v_why, private.transfer_line_tenant(l.organization_id));
  v_why := coalesce(v_why, private.transfer_line_pre(l.id));
  if v_why is not null then
    raise exception 'transfer line booking refused: %', v_why using errcode = 'check_violation';
  end if;
  perform private.transfer_line_locks(l.id);
  v_chk := private.transfer_line_check(l.id, true);
  if v_chk ->> 'why' is not null then
    raise exception 'transfer line booking refused: %', v_chk ->> 'why' using errcode = 'check_violation',
      detail = coalesce(v_chk ->> 'detail', '');
  end if;
  v_text := private.transfer_line_text();
  if v_text is distinct from p_expected_text then
    raise exception 'transfer line booking refused: split_changed' using errcode = 'check_violation';
  end if;
  begin
    perform private.transfer_line_post(l.id, v_reason);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    if v_state like 'LG%' or v_state like '22%' or v_state like '23%' then
      raise exception 'transfer line booking refused: posting_failed (%: %)', v_state, left(v_msg, 500)
        using errcode = 'check_violation';
    end if;
    raise;
  end;
  perform private.remittance_draft_requeue(d.run_id) from pg_temp._tl_drafts d;
  v_funds := exists (select 1 from pg_temp._tl t
                     where t.kind in ('payout', 'sweep', 'unplanned_payout', 'unplanned_sweep',
                                      'unplanned_payout_returned', 'unplanned_sweep_returned'));
  if v_funds then
    perform pgmq.send('payments', jsonb_build_object('type', 'process_debits', 'organization_id', l.organization_id,
                                                     'funds_after', null));
  end if;
  v_result := jsonb_build_object(
    'bank_transaction_id', l.id,
    'bookings', (select coalesce(jsonb_agg(jsonb_build_object(
                   'seq', k.seq, 'kind', k.kind, 'transfer_id', k.transfer_id, 'client_id', coalesce(t.client_id, t.c),
                   'amount_minor', k.amount_minor::text, 'entry_id', k.entry_id, 'paid_minor', coalesce(t.p, 0)::text,
                   'advance_minor', coalesce(t.adv, 0)::text,
                   -- (review LT-4, critic2 ML-9) the bound that set an unplanned payout's P; null for every other kind
                   'p_bound', case when k.kind = 'unplanned_payout' then t.p_bound end) order by k.seq), '[]')
                 from public.bank_line_booking k
                 left join pg_temp._tl t on t.entry_id = k.entry_id or t.rev_entry_id = k.entry_id
                 where k.bank_transaction_id = l.id),
    'drafts_requeued', (select coalesce(jsonb_agg(d.run_id order by d.run_id), '[]') from pg_temp._tl_drafts d),
    'funds_pass_queued', v_funds,
    'expected_text', v_text);
  perform private.command_record('book_transfer_line', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- The preview of these parts on a line its caller may read (public.transfer_line_preview, public.transfer_line_options):
-- the parse, the tenant filter, what runs before the locks (private.transfer_line_pre) — unless p_pre is false: the
-- options' own call built pg_temp._tl_pre and _tl_meta for this line just before (review CSR-3: the lot's subset search,
-- the costliest read of a 500-member lot, then runs once per options call, not twice) — and the check, unlocked.
create or replace function private.transfer_line_preview_of(p_bank_transaction_id uuid, p_parts jsonb, p_pre boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  l public.bank_transaction;
  v_why text;
  v_chk jsonb;
begin
  select * into l from public.bank_transaction where id = p_bank_transaction_id;
  v_why := private.transfer_line_parse(p_parts);
  v_why := coalesce(v_why, private.transfer_line_tenant(l.organization_id));
  if p_pre then
    v_why := coalesce(v_why, private.transfer_line_pre(l.id));
  end if;
  if v_why is not null then
    return jsonb_build_object('ok', false, 'why', v_why, 'detail', null, 'parts', '[]'::jsonb, 'drafts', '[]'::jsonb,
                              'supersedes_file', null, 'expected_text', null);
  end if;
  v_chk := private.transfer_line_check(l.id, false);
  return jsonb_build_object(
    'ok', v_chk ->> 'why' is null, 'why', v_chk ->> 'why', 'detail', v_chk ->> 'detail',
    'parts', private.transfer_line_parts_json(),
    'drafts', (select coalesce(jsonb_agg(jsonb_build_object('run_id', d.run_id, 'number', d.number)
                                         order by d.number), '[]') from pg_temp._tl_drafts d),
    'supersedes_file', case when v_chk ->> 'why' is null then private.transfer_line_supersedes(l.id) end,
    'expected_text', case when v_chk ->> 'why' is null then private.transfer_line_text() end);
end;
$$;

-- What a booking of these parts would do (plan §3.11): the same check (§3.4) on the same rules, unlocked, never
-- raising — {ok, why, detail, parts: [{…, paid_minor, advance_minor, p_bound, late}], drafts: [{run_id, number}],
-- supersedes_file, expected_text}. Money staff of the line's servicer only (another servicer's line, a client member or
-- a collector: null); the tenant filter first (§3.4.1). Keyed.
create or replace function public.transfer_line_preview(p_bank_transaction_id uuid, p_parts jsonb)
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
  return private.transfer_line_preview_of(l.id, p_parts, true);
end;
$$;

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
    -- (critic2 CSO2-10) a detail naming nothing of this servicer and account is never shown: no parts proposed
    if l.unsplit_details is null or jsonb_array_length(v_parts) = 0
       or exists (select 1 from jsonb_array_elements(v_parts) p where p ->> 'transfer_id' is null) then
      v_parts := null;
      v_refusal := case when l.unsplit_details is null then 'unsplit_detail_missing' else 'unsplit_not_bookable' end;
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
-- Redefinitions (plan §3.12; each copied from its latest definition, changed only as its comment says)
------------------------------------------------------------------------------------------

-- private.bank_line_booking_guard, redefined from 20261116090000 (same settings; its grants restated below). M2c-6b-2b
-- (plan §3.12): a fee also on a debit of kind transfer_out or batch_unsplit (S08: the bank's charge on our transfer's
-- own line, class E, or the ISO shape on an entry kept unsplit), still on a credit only of kind return; payout_returned
-- and sweep_returned also on own and client credits (S16); every transfer kind, planned, unplanned and their returns,
-- in either direction on a line of an entry kept unsplit holding ours (its parts are the statement's own details: a
-- debit detail inside a credit entry, or the reverse); the new kinds unplanned_payout_returned and
-- unplanned_sweep_returned: a reversal of the entry of an unplanned_payout (unplanned_sweep) booking of the same
-- transfer (or of none), on a credit of kind return, own_transfer_in or client_transfer_in. Still one keyed lookup per
-- row (the reversed entry's booking by its unique entry_id). Nothing else changes.
create or replace function private.bank_line_booking_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare v_bad text;
begin
  select min(n.bank_transaction_id::text || ':' || n.seq) into v_bad
  from new_rows n
  cross join lateral (
    select t.organization_id, t.bank_account_id, t.direction, t.booking_date,
           case when t.kind = 'suspected_duplicate' then r.released_kind else t.kind end as kind,
           e.entry_type, e.effective_date, e.source_type, e.source_id, e.organization_id as entry_org,
           e.reverses_entry_id,
           (select l.kind from public.bank_debit_link l where l.bank_transaction_id = t.id) as link_kind,
           exists (select 1 from public.payment p where p.bank_transaction_id = t.id offset 0) as paid,
           (select x.creditor_bank_account_id from public.bank_transfer x where x.id = n.transfer_id) as tr_creditor,
           (select x.debtor_bank_account_id from public.bank_transfer x where x.id = n.transfer_id) as tr_debtor,
           (select x.kind from public.bank_transfer x where x.id = n.transfer_id) as tr_kind,
           (select x.entry_id from public.bank_transfer x where x.id = n.transfer_id) as tr_entry,
           coalesce(t.unsplit_ours, 0) > 0 as unsplit,
           (select k.kind from public.bank_line_booking k where k.entry_id = e.reverses_entry_id) as reversed_kind,
           (select k.transfer_id from public.bank_line_booking k where k.entry_id = e.reverses_entry_id)
             as reversed_transfer,
           (select count(*) from public.ledger_posting p
            where p.entry_id = n.entry_id
              and (select la.bank_account_id from public.ledger_account la where la.id = p.ledger_account_id)
                  = t.bank_account_id) as on_line_bank
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    left join public.ledger_entry e on e.id = n.entry_id
    where t.id = n.bank_transaction_id
    offset 0) x
  where x.organization_id <> n.organization_id or x.bank_account_id <> n.bank_account_id
     or x.entry_org is distinct from n.organization_id or x.effective_date is distinct from x.booking_date
     or x.on_line_bank <> 1
     or x.kind is null
     -- a line explained without booking, or a payment's return or refund, is not also booked; a loss completes a
     -- return of what was left of its payment; a line that is a payment is booked by its cash_in, never in the funds
     or (x.link_kind is not null and not (n.kind = 'loss' and x.link_kind = 'return'))
     or x.paid
     or case n.kind
          when 'fee' then not (x.entry_type = 'bank_fee' and n.transfer_id is null
                               and x.source_type = 'bank_transaction' and x.source_id = n.bank_transaction_id::text
                               and ((x.direction = 'debit' and x.kind in ('other_debit', 'transfer_out',
                                                                           'batch_unsplit'))
                                    or (x.direction = 'credit' and x.kind = 'return')))
          when 'loss' then not (x.entry_type = 'servicer_loss' and n.transfer_id is null and x.direction = 'debit'
                                and x.kind = 'return' and x.source_type = 'bank_transaction'
                                and x.source_id = n.bank_transaction_id::text)
          when 'top_up' then not (x.entry_type = 'servicer_top_up' and x.direction = 'credit'
                                  and x.kind = 'own_transfer_in'
                                  and ((n.transfer_id is null and x.source_type = 'bank_transaction'
                                        and x.source_id = n.bank_transaction_id::text)
                                       or (n.transfer_id is not null and x.tr_kind = 'top_up'
                                           and x.tr_creditor = n.bank_account_id and x.source_type = 'bank_transfer'
                                           and x.source_id = n.transfer_id::text)))
          when 'payout' then not (x.entry_type = 'remittance'
                                  and ((x.direction = 'debit'
                                        and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit')) or x.unsplit)
                                  and n.transfer_id is not null and x.tr_kind = 'payout'
                                  and x.tr_debtor = n.bank_account_id and x.source_type = 'bank_transfer'
                                  and x.source_id = n.transfer_id::text)
          when 'unplanned_payout' then not (x.entry_type = 'remittance'
                                            and ((x.direction = 'debit'
                                                  and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit'))
                                                 or x.unsplit)
                                            and ((n.transfer_id is null and x.source_type = 'bank_transaction'
                                                  and x.source_id = n.bank_transaction_id::text)
                                                 or (n.transfer_id is not null and x.tr_kind = 'payout'
                                                     and x.tr_debtor = n.bank_account_id
                                                     and x.source_type = 'bank_transfer'
                                                     and x.source_id = n.transfer_id::text)))
          when 'sweep' then not (x.entry_type = 'servicer_sweep'
                                 and ((x.direction = 'debit'
                                       and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit')) or x.unsplit)
                                 and n.transfer_id is not null and x.tr_kind = 'sweep'
                                 and x.tr_debtor = n.bank_account_id and x.source_type = 'bank_transfer'
                                 and x.source_id = n.transfer_id::text)
          when 'unplanned_sweep' then not (x.entry_type = 'servicer_sweep'
                                           and ((x.direction = 'debit'
                                                 and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit'))
                                                or x.unsplit)
                                           and ((n.transfer_id is null and x.source_type = 'bank_transaction'
                                                 and x.source_id = n.bank_transaction_id::text)
                                                or (n.transfer_id is not null and x.tr_kind = 'sweep'
                                                    and x.tr_debtor = n.bank_account_id
                                                    and x.source_type = 'bank_transfer'
                                                    and x.source_id = n.transfer_id::text)))
          when 'payout_returned' then not (x.entry_type = 'reversal'
                                           and ((x.direction = 'credit'
                                                 and x.kind in ('return', 'own_transfer_in', 'client_transfer_in'))
                                                or x.unsplit)
                                           and n.transfer_id is not null and x.tr_kind = 'payout'
                                           and x.tr_debtor = n.bank_account_id
                                           and x.reverses_entry_id is not distinct from x.tr_entry)
          when 'sweep_returned' then not (x.entry_type = 'reversal'
                                          and ((x.direction = 'credit'
                                                and x.kind in ('return', 'own_transfer_in', 'client_transfer_in'))
                                               or x.unsplit)
                                          and n.transfer_id is not null and x.tr_kind = 'sweep'
                                          and x.tr_debtor = n.bank_account_id
                                          and x.reverses_entry_id is not distinct from x.tr_entry)
          -- M2c-6b-2b: the return of an unplanned payout or sweep reverses the entry of an unplanned booking of the
          -- same transfer (or of none), on a credit coming back (or a line of an entry kept unsplit)
          when 'unplanned_payout_returned' then not (x.entry_type = 'reversal'
                                                     and ((x.direction = 'credit'
                                                           and x.kind in ('return', 'own_transfer_in',
                                                                          'client_transfer_in'))
                                                          or x.unsplit)
                                                     and x.reversed_kind = 'unplanned_payout'
                                                     and x.reversed_transfer is not distinct from n.transfer_id
                                                     and (n.transfer_id is null
                                                          or (x.tr_kind = 'payout' and x.tr_debtor = n.bank_account_id)))
          when 'unplanned_sweep_returned' then not (x.entry_type = 'reversal'
                                                    and ((x.direction = 'credit'
                                                          and x.kind in ('return', 'own_transfer_in',
                                                                         'client_transfer_in'))
                                                         or x.unsplit)
                                                    and x.reversed_kind = 'unplanned_sweep'
                                                    and x.reversed_transfer is not distinct from n.transfer_id
                                                    and (n.transfer_id is null
                                                         or (x.tr_kind = 'sweep' and x.tr_debtor = n.bank_account_id)))
          when 'client_payment' then not (x.entry_type = 'client_payment_dedicated' and x.direction = 'credit'
                                          and x.kind = 'client_transfer_in' and n.transfer_id is null
                                          and x.source_type = 'bank_transaction'
                                          and x.source_id = n.bank_transaction_id::text)
          else true end;
  if v_bad is not null then
    raise exception 'bank line booking %: it does not match its line, entry or transfer', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;


-- private.pending_item_deadlines, redefined from 20261116090000 (same signature and settings; its grants restated
-- below). M2c-6b-2b (plan §3.12; critic F11, L4; critic2 ML-2): the payout_returned branch is kept for a transfer's own
-- planned remittance only (`bt.entry_id` = the reversed entry): the item of a reversed unplanned remittance is not
-- monitored while the items its P paid are still pending (no deadline, as an advance's: those items kept their own
-- clocks, Q15's default, and its A − P is netted by the advance's reversal) — so a returned S03 (P = 0, net 0) writes
-- no breach row, raises no remittance_due_critical and needs no late reason; a third branch holds it, once a run froze
-- those items, to their earliest line's date (blocked_reason payout_returned, as a planned return). The worker's twin,
-- jobs/remittances.py _held_to, has the same branches (parity test). Nothing else changes.
create or replace function private.pending_item_deadlines(p_organization_id uuid,
                                                          p_unreserved_only boolean default false)
returns table (ledger_entry_id uuid, client_organization_id uuid, currency char(3), amount_minor bigint,
               draft_run_id uuid, payment_id uuid, monitored boolean, encaissement_date date, max_days integer,
               deadline date, latest_execution_date date, alert_soon_date date, alert_critical_date date,
               unmeetable boolean, check_deadline date, check_latest_execution_date date, check_alert_soon_date date,
               check_alert_critical_date date, out_of_horizon boolean)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with items as materialized (
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, e.payment_id,
           x.e_date, coalesce(t.days, 30) as days, f.mandate_id
    from private.remittance_pending q
    join lateral (select le.payment_id, le.account_id from public.ledger_entry le
                  where le.id = q.ledger_entry_id offset 0) e on true
    left join lateral (select private.encaissement_date(p.booking_date, p.value_date) as e_date,
                              coalesce(e.account_id, p.account_id) as account_id
                       from public.payment p where p.id = e.payment_id offset 0) x on true
    left join lateral (select pf.mandate_id
                       from public.account a join public.portfolio pf on pf.id = a.portfolio_id
                       where a.id = coalesce(x.account_id, e.account_id) offset 0) f on true
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = f.mandate_id and mt.valid_from <= x.e_date
                         and (mt.valid_to is null or x.e_date < mt.valid_to)
                       limit 1) t on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind in ('allocation', 'forward')
      and (not p_unreserved_only or q.draft_run_id is null)
    union all
    -- M2c-6b-1 (design §9.2, Q7's default): a payout that came back is held to the earliest date of the returned run's
    -- positive live lines — its E and its mandate's delay, those of the line with the earliest latest execution date
    -- (the reversal → the reversed remittance → its transfer → its run → its lines, each by key). A line that is itself
    -- a re-proposed payout (returned a second time) has no mandate (the worker's prepare: no file, no mandate's gross)
    -- but the terms version it was held to: that version gives the delay and the mandate (monitored), as the worker's
    -- prepare reads it (jobs/remittances.py _held_to; review M2c-6b-1 legal-texts#1 item 3, parity)
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, rl.payment_id,
           rl.encaissement_date, coalesce(t.days, ti.days, 30), coalesce(rl.mandate_id, ti.mandate_id)
    from private.remittance_pending q
    cross join lateral (select le.reverses_entry_id from public.ledger_entry le
                        where le.id = q.ledger_entry_id offset 0) e
    cross join lateral (select re.source_id from public.ledger_entry re
                        where re.id = e.reverses_entry_id and re.entry_type = 'remittance'
                          and re.source_type = 'bank_transfer' offset 0) re
    cross join lateral (select bt.run_id from public.bank_transfer bt
                        where bt.id = case when pg_input_is_valid(re.source_id, 'uuid') then re.source_id::uuid end
                          -- M2c-6b-2b (critic F11, L4): the transfer's own planned remittance only
                          and bt.entry_id = e.reverses_entry_id
                        offset 0) bt
    cross join lateral (select l.payment_id, l.encaissement_date, l.mandate_id, l.mandate_terms_id
                        from public.remittance_line l
                        where l.run_id = bt.run_id and l.amount_minor > 0 and not l.released
                          and l.latest_execution_date is not null and l.encaissement_date is not null
                        order by l.latest_execution_date, l.line_no limit 1) rl
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.mandate_id, mt.remittance_max_days as days from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id offset 0) ti on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind = 'payout_returned'
      and (not p_unreserved_only or q.draft_run_id is null)
    union all
    -- M2c-6b-2b (critic2 ML-2): the re-owed item of an unplanned remittance returned after a run froze the items its
    -- P paid (their clocks ended at that run, the −A row netting them) is held like a planned return: to the earliest
    -- latest execution date of those items' live lines — the reversal → the reversed remittance → its attributions
    -- (private.unplanned_paid_item by booking_entry_id) → each item's live line (remittance_line_live_uq), each by key —
    -- its E, mandate and terms version as the planned branch reads them. While those items are still pending: no line,
    -- no deadline (critic F11, L4: they keep their own clocks, Q15's default). Parity: jobs/remittances.py _held_to
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, rl.payment_id,
           rl.encaissement_date, coalesce(t.days, ti.days, 30), coalesce(rl.mandate_id, ti.mandate_id)
    from private.remittance_pending q
    cross join lateral (select le.reverses_entry_id from public.ledger_entry le
                        where le.id = q.ledger_entry_id offset 0) e
    cross join lateral (select re.id from public.ledger_entry re
                        where re.id = e.reverses_entry_id and re.entry_type = 'remittance' offset 0) re
    cross join lateral (select l.payment_id, l.encaissement_date, l.mandate_id, l.mandate_terms_id
                        from (select u.ledger_entry_id from private.unplanned_paid_item u
                              where u.booking_entry_id = re.id offset 0) u
                        cross join lateral (select x.payment_id, x.encaissement_date, x.mandate_id, x.mandate_terms_id,
                                                   x.latest_execution_date, x.run_id, x.line_no, x.amount_minor
                                            from public.remittance_line x
                                            where x.ledger_entry_id = u.ledger_entry_id and not x.released offset 0) l
                        where l.amount_minor > 0 and l.latest_execution_date is not null
                          and l.encaissement_date is not null
                        order by l.latest_execution_date, l.run_id, l.line_no limit 1) rl
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.mandate_id, mt.remittance_max_days as days from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id offset 0) ti on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind = 'payout_returned'
      and (not p_unreserved_only or q.draft_run_id is null)),
  mon as (
    select k.mandate_id, exists (select 1 from public.mandate_terms v where v.mandate_id = k.mandate_id) as monitored
    from (select distinct i.mandate_id from items i where i.mandate_id is not null) k),
  -- one deadline per distinct (E, delay), whatever the estimates (review perf#0, round 2: an inlined CTE was joined
  -- first and its deadline computed once per item when the queue had no statistics)
  dl as materialized (
    select k.e_date, k.days, d.*
    from (select distinct i.e_date, i.days from items i where i.e_date is not null) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, k.days) d),
  m as materialized (   -- one month, for the delays that cannot be met: once per distinct E
    select k.e_date, d.*
    from (select distinct dl.e_date from dl where dl.unmeetable) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, 30) d)
  select i.ledger_entry_id, i.client_organization_id, i.currency, i.amount_minor, i.draft_run_id, i.payment_id,
         coalesce(mon.monitored, false), i.e_date, i.days, dl.deadline, dl.latest_execution_date, dl.alert_soon_date,
         dl.alert_critical_date, coalesce(dl.unmeetable, false),
         case when dl.unmeetable then m.deadline else dl.deadline end,
         case when dl.unmeetable then m.latest_execution_date else dl.latest_execution_date end,
         case when dl.unmeetable then m.alert_soon_date else dl.alert_soon_date end,
         case when dl.unmeetable then m.alert_critical_date else dl.alert_critical_date end,
         coalesce(dl.out_of_horizon, false) or coalesce(m.out_of_horizon, false)
  from items i
  left join mon on mon.mandate_id = i.mandate_id
  left join dl on dl.e_date = i.e_date and dl.days = i.days
  left join m on m.e_date = i.e_date and dl.unmeetable;
$$;


-- A run's lines late at a date (CI scale fix, ADR-0014 « M2c-6b-2b review fixes »): the positive, unreleased lines of
-- p_run_id whose latest execution date is before p_before — read by the run's key alone (remittance_line_pkey's leading
-- column) and the conditions outside it, enable_seqscan off in its own settings, so its callers' settings never decide
-- the plan. Held inside a lateral with the run's key, `not released` let a stale estimate of the run pick a whole scan of
-- remittance_line_live_uq; without enable_seqscan off, a sequential scan of remittance_line — once per payout booked:
-- after the 50,000-line runs, 500 of them for a lot at the cap. Read by private.bank_booking_post_rows, once per payout
-- row. Not inlined (its settings): planned once per calling statement.
create or replace function private.remittance_run_late_lines(p_run_id uuid, p_before date)
returns table (ledger_entry_id uuid, payment_id uuid, deadline date, latest_execution_date date, unmeetable boolean,
               encaissement_date date, kind text)
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select q.ledger_entry_id, q.payment_id, q.deadline, q.latest_execution_date, q.unmeetable, q.encaissement_date, q.kind
  from (select x.ledger_entry_id, x.payment_id, x.deadline, x.latest_execution_date, x.unmeetable, x.encaissement_date,
               x.kind, x.amount_minor, x.released
        from public.remittance_line x where x.run_id = p_run_id offset 0) q
  where q.amount_minor > 0 and not q.released and q.latest_execution_date < p_before;
$$;

-- private.bank_booking_post_rows, redefined from 20261116090000 (same signature and settings; its grants restated
-- below). M2c-6b-2b (plan §3.12; critic CSO-1): a `payout` row's remittance entry reason is null (the job's), whatever
-- the row's reason — an ops payout's motif (public.book_transfer_line) goes to bank_line_booking.reason only, which
-- staff alone read; parity with the job's entries is pinned by pgTAP 037 C. CI scale fix: the late lines of each
-- payout's run through private.remittance_run_late_lines, and the clients' balances, the runs booked and the payout
-- accounts returned by the arrays of their keys (the same rows, by key whatever the statistics). Nothing else changes.
create or replace function private.bank_booking_post_rows(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
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

  -- (4) the cover: what a booked payout left in debit on its client's 4670 (all its entries posted: the running
  -- balance), advanced by the servicer at the debit date
  drop table if exists pg_temp._bb_cover;
  create temp table _bb_cover on commit drop as
  select distinct on (b.tr_client, b.currency) b.ord, b.tr_client as client_organization_id, b.currency, b.transfer_id,
         b.bank_transaction_id, b.line_date, c.balance_minor as overrun, e.entry_id as cause_entry_id,
         gen_random_uuid() as advance_id
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
    insert into public.client_advance (id, organization_id, client_organization_id, currency, amount_minor, cause,
                                       cause_entry_id, entry_id, bank_transaction_id, transfer_id)
    select c.advance_id, p_organization_id, c.client_organization_id, c.currency, c.overrun, 'payout_overrun',
           c.cause_entry_id, x.entry_id, c.bank_transaction_id, c.transfer_id
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
    and x.id = s.transfer_id;
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
  with late as materialized (
    select b.tr_run as run_id, b.line_date, ru.organization_id, ru.client_organization_id,
           ru.requested_execution_date, ru.late_reason, l.ledger_entry_id, l.payment_id, l.deadline,
           l.latest_execution_date, l.unmeetable, l.encaissement_date, l.kind
    from pg_temp._bb b
    cross join lateral (select q.organization_id, q.client_organization_id, q.requested_execution_date, q.late_reason
                        from public.remittance_run q where q.id = b.tr_run offset 0) ru
    cross join lateral private.remittance_run_late_lines(b.tr_run, b.line_date) l
    where b.kind = 'payout'),
  m as materialized (
    select k.e_date, d.*
    from (select distinct l.encaissement_date as e_date from late l
          where l.unmeetable and l.encaissement_date is not null) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, 30) d)
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


-- Whether a re-imported line's stored details differ from the new file's (COMPLIANCE OQ-84 (j), 6b-2a's known limit;
-- review CSR-4): the same number of details, the same ids in the same order, and every value the new file gives equal
-- to the stored one — a detail's amount when the new file gives one (a stored amount missing counts as different), its
-- direction when the new file gave its CdtDbtInd (a null flag array: given, as before this migration), whether or not
-- the stored file gave it: a value the new file leaves out is not compared, a value it gives is never dropped. Immutable.
create or replace function private.unsplit_details_differ(p_stored jsonb, p_new jsonb, p_new_given boolean[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_array_length(p_stored) <> jsonb_array_length(p_new)
      or exists (
        select 1
        from jsonb_array_elements(p_stored) with ordinality a (v, o)
        join jsonb_array_elements(p_new) with ordinality b (v, o) on b.o = a.o
        where a.v ->> 'id' is distinct from b.v ->> 'id'
           or (b.v ->> 'amount_minor' is not null and a.v ->> 'amount_minor' is distinct from b.v ->> 'amount_minor')
           or (coalesce(p_new_given[a.o], true) and a.v ->> 'direction' is distinct from b.v ->> 'direction'));
$$;

-- private.ingest_statement, redefined from 20261117090000 (same signature, body and settings; its grants restated
-- below). M2c-6b-2b (COMPLIANCE OQ-84 (j), the 6b-2a verifier's known limit: the same entries exported again in another
-- camt.053 version — v08 stored, then v02, whose charges are never read and whose details give no CdtDbtInd — or a v08
-- export omitting the details' CdtDbtInd, refused the whole file entry_detail_differs): the stage's charges_read and
-- unsplit_direction_given are checked (line_invalid) and kept with the line, and a known line's stored values are
-- compared with every value the new file gives, and only with those (private.unsplit_details_differ; the charges only
-- when the new file read them; review CSR-4: whether or not the stored file gave the value — a value the new file gives
-- is never dropped). A line imported before 6b-2a, with no details nor charges, is still neither compared nor filled.
-- Nothing else changes.
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
      unsplit_direction_given)
    select s.organization_id, s.bank_account_id, s.id, n.line_no, n.dedup_key, n.direction, n.amount_minor, s.currency,
           n.booking_date, n.value_date, coalesce(n.reversal_indicator, false), n.bank_tx_code, n.acct_svcr_ref,
           n.end_to_end_id, n.tx_id, n.mandate_ref, n.counterparty_name, n.ultimate_counterparty_name,
           n.counterparty_iban, n.remittance_text, n.creditor_reference, n.return_reason, n.original_end_to_end_id,
           n.batch_entry_ref, n.entry_ref, n.kind, n.payment_info_id, n.unsplit_ours, n.unsplit_details,
           n.unsplit_detail_count, n.unsplit_batch_count, n.charges_minor, n.charges_read, n.unsplit_direction_given
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


-- private.post_bank_bookings, redefined from 20261117090000 (same signature, body and settings; its grants restated
-- below). M2c-6b-2b (review CSR-1): the allocation lock `payments:` is also taken, before the lines and `remit:`, for a
-- batch holding a sweep's return — its posting reverses the sweep's entry (private.ledger_reverse takes `payments:`
-- whatever the entry), so a batch of a sweep's flagged return alone took the line and `remit:` first and `payments:`
-- inside its posting: the inverse of public.book_transfer_line's order (§3.8), and of the approvals', a deadlock (40P01)
-- when both met. Nothing else changes.
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
  -- M2c-6b-2b (review CSR-1): a sweep's return too — every row whose posting reverses an entry (private.ledger_reverse
  -- always takes `payments:`) takes it here, before the lines and `remit:`, the order every other writer takes them
  if exists (select 1 from pg_temp._bank_booking b
             where b.kind in ('payout', 'payout_returned', 'sweep_returned', 'unplanned_payout')) then
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

-- private.remittance_statement_build, redefined from 20261116090000 (same signature and settings; its grants restated
-- below). M2c-6b-2b (review LT-2; plan §5 [critic L4], brought forward from 6b-2d: ops book unplanned returns from this
-- slice on): a payout_returned line whose entry reverses an unplanned remittance (the reversed entry's booking is an
-- unplanned_payout: a payout executed twice, or late, whose copy came back) carries nature_reason `unplanned` — in its
-- line and in its nature total — and, when late, late_cause `unplanned_payout_returned`: its money was paid by that
-- unplanned payout and is owed again, never « reversé à nouveau ». New codes only: no payload drawn before carries such a
-- line (no unplanned booking existed), so their bytes are unchanged and the template version stays. Nothing else changes.
create or replace function private.remittance_statement_build(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare
  r public.remittance_run;
  v_cancelled boolean;
  v_exp integer;
  v_lines jsonb;
  v_files jsonb;
  v_natures jsonb;
  v_totals jsonb;
  v_docs jsonb;
  v_earlier jsonb;
  v_mandates jsonb;
  v_payout jsonb;
  v_follow jsonb;
  v_held jsonb;
  v_refunded jsonb;
  v_position jsonb;
  v_prev public.remittance_run;
  v_k_day date;
  v_issue date;
  v_payload jsonb;
  v_receivable bigint;
  v_advances bigint;
  v_docs_ttc bigint;
  v_issuer jsonb;
  v_client jsonb;
begin
  select * into r from public.remittance_run where id = p_run_id for share;
  if not found or r.approved_at is null then
    raise exception 'statement of %: not an approved run', p_run_id using errcode = 'check_violation';
  end if;
  v_cancelled := r.status = 'cancelled';
  select c.minor_exponent into v_exp from public.currency c where c.code = r.currency;
  v_k_day := (r.known_at at time zone 'Europe/Paris')::date;
  v_issue := (r.approved_at at time zone 'Europe/Paris')::date;

  -- the run's lines, then the earlier lines whose commission this run priced (amount 0: remitted then)
  drop table if exists pg_temp._rd_line;
  create temp table _rd_line on commit drop as
  select 0 as section, l.line_no, l.line_no as source_line_no, null::text as from_run, l.kind, l.ledger_entry_id,
         l.account_id, l.portfolio_id, l.mandate_id, l.payment_id, l.encaissement_date, l.effective_date, l.deadline,
         l.amount_minor, l.commission_minor, l.commission_state, l.parts, l.invoice_id, l.posted_at,
         l.latest_execution_date, l.unmeetable
  from public.remittance_line l where l.run_id = r.id
  union all
  select 1, 0, l.line_no, (select x.number from public.remittance_run x where x.id = l.run_id), l.kind,
         l.ledger_entry_id, l.account_id, l.portfolio_id, l.mandate_id, l.payment_id, l.encaissement_date,
         l.effective_date, l.deadline, 0, rp.commission_minor, rp.commission_state, rp.parts, rp.invoice_id,
         l.posted_at, l.latest_execution_date, l.unmeetable
  from public.remittance_line_repricing rp
  cross join lateral (select y.* from public.remittance_line y where y.run_id = rp.run_id and y.line_no = rp.line_no
                      offset 0) l
  where rp.pricing_run_id = r.id;

  drop table if exists pg_temp._rd_fact;
  create temp table _rd_fact on commit drop as
  select x.section, x.line_no, x.source_line_no, x.from_run, x.kind, x.account_id, x.amount_minor, x.commission_minor,
         a.external_ref as file, d.name as debtor, m.reference as mandate, pf.name as portfolio,
         coalesce(it.items, '[]'::jsonb) as items, coalesce(it.components, '[]'::jsonb) as components,
         -- M2c-6b-2b (review LT-2, critic L4): the item an unplanned payout's return re-owes is marked `unplanned`: the
         -- renderer words it « Virement exécuté hors reversement revenu », never « Virement revenu impayé — reversé à
         -- nouveau »
         case when un.unplanned then 'unplanned' else n.reason end as nature_reason,
         x.encaissement_date, x.effective_date, x.deadline, x.commission_state,
         coalesce(pt.rules, '[]'::jsonb) as rules, coalesce(pt.rates, '[]'::jsonb) as rates,
         coalesce(pt.basis, 0) as basis, coalesce(inv.number, cn.number) as invoice, rc.number as receipt,
         la.ledger_entry_id is not null as late, lc.cause as late_cause
  from pg_temp._rd_line x
  left join lateral (select q.external_ref from public.account q where q.id = x.account_id offset 0) a on true
  left join lateral (
    select (array_agg(pa.display_name order by pa.display_name, pa.id))[1] as name
    from public.account_party ap
    cross join lateral (select q.id, q.display_name from public.party q where q.id = ap.party_id offset 0) pa
    where ap.account_id = x.account_id and ap.role = 'borrower') d on true
  left join lateral (select q.reference from public.mandate q where q.id = x.mandate_id offset 0) m on true
  left join lateral (select q.name from public.portfolio q where q.id = x.portfolio_id offset 0) pf on true
  -- the items and components the entry moved (its 1100 postings), each item once, in a total order
  left join lateral (
    with y as (
      select q.claim_item_id, q.component
      from public.ledger_posting lp
      cross join lateral (select v.claim_item_id, v.component from public.ledger_account v
                          where v.id = lp.ledger_account_id and v.book = 'debtor_receivable' offset 0) q
      where lp.entry_id = x.ledger_entry_id)
    select (select jsonb_agg(jsonb_build_array(z.kind, z.ref) order by z.due_date nulls last, z.ref, z.kind, z.id)
            from (select distinct ci.id, ci.kind, ci.ref, ci.due_date
                  from y cross join lateral (select c.id, c.kind, c.ref, c.due_date from public.claim_item c
                                             where c.id = y.claim_item_id offset 0) ci) z) as items,
           (select jsonb_agg(z.component order by z.sort_order)
            from (select distinct y.component, lc.sort_order
                  from y cross join lateral (select c.sort_order from public.ledger_component c
                                             where c.code = y.component offset 0) lc) z) as components) it on true
  left join lateral (select q.reason from public.client_notification q where q.ledger_entry_id = x.ledger_entry_id
                     offset 0) n on true
  -- M2c-6b-2b (review LT-2): a payout_returned line reversing an unplanned remittance (the reversed entry's booking is an
  -- unplanned_payout), by key: the line's entry, then the reversed entry's booking by its entry
  left join lateral (select exists (select 1 from public.bank_line_booking k
                                    where k.entry_id = e.reverses_entry_id and k.kind = 'unplanned_payout') as unplanned
                     from (select q.reverses_entry_id from public.ledger_entry q where q.id = x.ledger_entry_id
                           offset 0) e
                     where x.kind = 'payout_returned') un on true
  -- the rules and band rates of the line's parts, and the basis they priced
  left join lateral (
    select (select jsonb_agg(distinct p ->> 'label_fr') from jsonb_array_elements(x.parts) p
            where p ->> 'label_fr' is not null) as rules,
           (select jsonb_agg(distinct t ->> 0) from jsonb_array_elements(x.parts) p
            cross join lateral jsonb_array_elements(coalesce(p -> 'tiers', '[]')) t) as rates,
           (select sum((p ->> 'basis')::bigint) from jsonb_array_elements(x.parts) p) as basis) pt on true
  left join lateral (select q.number from public.commission_invoice q where q.id = x.invoice_id offset 0) inv on true
  -- a reversal's negative commission is on the run's credit note, which names its entry (review figures#5)
  left join lateral (select q.number
                     from public.commission_credit_alloc ca
                     cross join lateral (select y.number, y.seq from public.commission_invoice y
                                         where y.id = ca.credit_note_id and y.run_id = r.id
                                           and y.kind = 'credit_note' and y.reason = 'commission' offset 0) q
                     where x.invoice_id is null and ca.entry_id = x.ledger_entry_id
                     order by q.seq limit 1) cn on true
  left join lateral (select q.number from public.receipt q where q.payment_id = x.payment_id
                     order by q.version limit 1) rc on true
  left join lateral (select q.ledger_entry_id from public.remittance_late_approval q
                     where q.run_id = r.id and q.ledger_entry_id = x.ledger_entry_id and x.section = 0
                     offset 0) la on true
  -- why a line was paid after its latest execution date, from the data (review legal#6; the approver's reason stays
  -- in the back office): a payout of it that came back unpaid, paid again (M2c-6b-1 review round 2, L1: the line keeps
  -- the date of the run line it came from, K2), the mandate's delay could not be met (held to one month, R124-6), the
  -- collection reached the queue after its J-5 date (the deadline guard's margin, 5 business days before its latest
  -- execution date), or the approval came late
  -- (M2c-6b-2b, review LT-2: the item an unplanned payout's return re-owes, held to the date of the items its P paid,
  -- critic2 ML-2 — the unplanned payout came back unpaid, never « reversé à nouveau »)
  left join lateral (select case when x.kind = 'payout_returned' and un.unplanned then 'unplanned_payout_returned'
                                 when x.kind = 'payout_returned' then 'payout_returned'
                                 when x.unmeetable then 'unmeetable'
                                 when private.business_days_between((x.posted_at at time zone 'Europe/Paris')::date,
                                                                    x.latest_execution_date) < 5
                                 then 'identified_late'
                                 else 'approved_late' end as cause
                     where la.ledger_entry_id is not null offset 0) lc on true;

  select coalesce(jsonb_agg(jsonb_build_array(
           f.source_line_no, f.mandate, f.portfolio, f.file, f.debtor, f.items, f.components, f.kind, f.nature_reason,
           f.from_run, f.encaissement_date, f.effective_date, f.deadline, f.amount_minor::text, f.rules, f.rates,
           f.basis::text, f.commission_minor::text, f.commission_state, f.invoice, f.receipt, f.late, f.late_cause)
           order by f.section, f.from_run, f.source_line_no), '[]')
  into v_lines from pg_temp._rd_fact f;

  -- per file (the PDF's table): the run's lines and the commission priced on the file in this run (a file with only
  -- earlier lines priced now has 0 lines: counted apart in the totals, review tests-ui#4)
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', g.file, 'debtor', g.debtor, 'lines', g.n::text, 'amount_minor', g.amount::text,
           'commission_minor', g.commission::text, 'late', g.late::text)
           order by g.file nulls last, g.account_id), '[]')
  into v_files
  from (select f.account_id, min(f.file) as file, min(f.debtor) as debtor,
               count(*) filter (where f.section = 0) as n, sum(f.amount_minor) as amount,
               sum(f.commission_minor) as commission, count(*) filter (where f.late) as late
        from pg_temp._rd_fact f group by f.account_id) g;

  -- per nature (the run's lines by kind and reason; the earlier lines priced now as one row)
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', n.kind, 'reason', n.reason, 'count', n.c::text, 'amount_minor', n.amount::text,
           'commission_minor', n.commission::text) order by n.section, n.kind, n.reason nulls first), '[]')
  into v_natures
  from (select f.section, case when f.section = 1 then 'repricing' else f.kind end as kind,
               case when f.section = 0 and f.kind in ('forward', 'allocation_reversal', 'forward_reversal')
                    then f.nature_reason
                    -- M2c-6b-2b (review LT-2): the unplanned returns' items apart from the planned returns'
                    when f.section = 0 and f.kind = 'payout_returned' and f.nature_reason = 'unplanned'
                    then 'unplanned' end as reason,
               count(*) as c, sum(f.amount_minor) as amount, sum(f.commission_minor) as commission
        from pg_temp._rd_fact f group by 1, 2, 3) n;

  select jsonb_build_object(
           'line_count', count(*) filter (where f.section = 0),
           'repriced_count', count(*) filter (where f.section = 1),
           'file_count', count(distinct f.account_id) filter (where f.section = 0),
           'repriced_only_file_count',
             (select count(*) from (select g.account_id from pg_temp._rd_fact g group by g.account_id
                                    having bool_and(g.section = 1)) o),
           'collected_minor', coalesce(sum(f.amount_minor) filter (where f.amount_minor > 0), 0)::text,
           'reversed_minor', coalesce(sum(f.amount_minor) filter (where f.amount_minor < 0), 0)::text,
           'commission_ht_minor', coalesce(sum(f.commission_minor), 0)::text,
           'late_count', count(*) filter (where f.late))
         || jsonb_build_object(
           'gross_minor', r.gross_minor::text,
           'invoice_ht_minor', coalesce(r.invoice_ht_minor, 0)::text,
           'invoice_vat_minor', coalesce(r.invoice_vat_minor, 0)::text,
           'invoice_ttc_minor', coalesce(r.invoice_ttc_minor, 0)::text,
           'credit_ht_minor', coalesce(r.credit_ht_minor, 0)::text,
           'credit_vat_minor', coalesce(r.credit_vat_minor, 0)::text,
           'credit_ttc_minor', coalesce(r.credit_ttc_minor, 0)::text,
           'commission_taken_minor', coalesce(r.commission_taken_minor, 0)::text,
           'advance_recovered_minor', coalesce(r.advance_recovered_minor, 0)::text,
           'refund_minor', coalesce(r.refund_minor, 0)::text,
           'settlement_minor', r.settlement_minor::text,
           'net_minor', r.net_minor::text)
         -- M2c-5b: what the run's credits absorbed of manual credit notes' waivers (lines with no document: a
         -- manual credit note credited it already), named with the invoices it was on and the manual credit notes
         -- that waived it (review legal#4: « avoir n° … rectifiant la facture … », followed back through a
         -- cancellation's corrective invoice); absent when nothing was (payloads drawn before keep their bytes)
         || coalesce((select jsonb_build_object('waived_absorbed_minor', (-sum(w.amount_minor))::text,
                                                'waived_absorbed_invoices',
                                                jsonb_agg(distinct i.number order by i.number),
                                                'waived_absorbed_credit_notes',
                                                private.absorbed_credit_notes(r.id))
                      from public.commission_waiver w
                      cross join lateral (select q.number from public.commission_invoice q
                                          where q.id = w.invoice_id offset 0) i
                      where w.run_id = r.id and w.cause = 'absorbed'
                      having count(*) > 0), '{}'::jsonb)
  into v_totals from pg_temp._rd_fact f;

  -- the run's documents (its approval's; a cancellation's too when the run was cancelled before this was drawn), each
  -- with the invoices it corrects, the credit notes of the cancellation that annul it, and what this payout sets off
  -- (nothing once cancelled)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'kind', i.kind, 'number', i.number, 'issue_date', i.issue_date, 'reason', i.reason,
           'mandate', (select m.reference from public.mandate m where m.id = i.mandate_id),
           'ht_minor', i.ht_minor::text, 'vat_minor', i.vat_minor::text, 'ttc_minor', i.ttc_minor::text,
           'vat_rate', i.vat_rate::text, 'settlement', i.settlement, 'due_date', i.due_date,
           'clause_ref', i.payload #>> '{settlement,clause_ref}',
           'payment_reference', i.payload -> 'payment_reference',
           'own_account', case when i.payload -> 'own_account' is not null
                               and jsonb_typeof(i.payload -> 'own_account') = 'object'
                               then jsonb_build_object('iban', private.iban_masked(i.payload #>> '{own_account,iban}'),
                                                       'holder', i.payload #>> '{own_account,holder}') end,
           'corrects', (select coalesce(jsonb_agg(jsonb_build_object('number', o.number, 'issue_date', o.issue_date,
                                                                     'ht_minor', c.ht_minor::text,
                                                                     'vat_minor', c.vat_minor::text)
                                                  order by o.seq), '[]')
                        from public.commission_credit_correction c
                        cross join lateral (select q.number, q.issue_date, q.seq from public.commission_invoice q
                                            where q.id = c.original_invoice_id offset 0) o
                        where c.credit_note_id = i.id),
           'cancelled_by', (select coalesce(jsonb_agg(jsonb_build_object('number', o.number,
                                                                         'issue_date', o.issue_date)
                                                      order by o.seq), '[]')
                            from public.commission_credit_correction c
                            cross join lateral (select q.number, q.issue_date, q.seq from public.commission_invoice q
                                                where q.id = c.credit_note_id and q.run_id = r.id
                                                  and q.reason = 'run_cancelled' offset 0) o
                            where c.original_invoice_id = i.id),
           'settles_minor', case when v_cancelled then '0'
                                 else (select coalesce(sum((s ->> 'amount')::bigint), 0)::text
                                       from jsonb_array_elements(coalesce(r.settlement_plan -> 'settles', '[]')) s
                                       where s ->> 'document_id' = i.id::text) end)
           order by i.seq), '[]')
  into v_docs
  from public.commission_invoice i where i.run_id = r.id;

  -- what this payout sets off from documents of earlier runs (compensation, a refund owed, an advance); nothing once
  -- the run is cancelled
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', s ->> 'kind', 'document_kind', i.kind, 'number', i.number, 'issue_date', i.issue_date,
           'amount_minor', s ->> 'amount') order by i.seq nulls last, s ->> 'document_id'), '[]')
  into v_earlier
  from jsonb_array_elements(case when v_cancelled then '[]'::jsonb
                                 else coalesce(r.settlement_plan -> 'settles', '[]') end) s
  left join lateral (select q.kind, q.number, q.issue_date, q.seq, q.run_id from public.commission_invoice q
                     where q.id = (s ->> 'document_id')::uuid offset 0) i on true
  where i.run_id is distinct from r.id and (s ->> 'amount')::bigint <> 0;

  -- the mandates the statement covers, with the clause references of their terms on K's day (R124-3 3°, 4°)
  select coalesce(jsonb_agg(jsonb_build_object(
           'reference', m.reference, 'signed_on', m.signed_on,
           'commission_clause_ref', t.commission_clause_ref, 'remittance_clause_ref', t.remittance_clause_ref,
           'netting_clause_ref', t.remittance_terms #>> '{netting,clause_ref}',
           'clawback_clause_ref', t.remittance_terms #>> '{clawback,clause_ref}')
           order by m.reference, m.id), '[]')
  into v_mandates
  from (select distinct x.mandate_id from pg_temp._rd_line x where x.mandate_id is not null
        union select i.mandate_id from public.commission_invoice i where i.run_id = r.id) mm
  cross join lateral (select q.* from public.mandate q where q.id = mm.mandate_id offset 0) m
  left join lateral (select q.commission_clause_ref, q.remittance_clause_ref, q.remittance_terms
                     from public.mandate_terms q
                     where q.mandate_id = m.id and q.valid_from <= v_k_day
                     order by q.valid_from desc limit 1) t on true;

  -- the payout as ordered (never « payé » before the bank's debit: M2c-6 books it)
  select jsonb_build_object('amount_minor', t.amount_minor::text, 'ordered_on', v_issue,
                            'requested_execution_date', t.requested_execution_date,
                            'iban', private.iban_masked(t.payee_iban), 'holder', t.payee_name,
                            'end_to_end_id', t.end_to_end_id, 'status', t.status)
  into v_payout from public.bank_transfer t where t.id = r.transfer_id;

  -- the previous run's payout: what became of it (« Suivi »)
  select * into v_prev from public.remittance_run x where x.id = r.previous_run_id;
  if v_prev.id is not null then
    select jsonb_agg(jsonb_build_object(
             'number', v_prev.number, 'status', v_prev.status, 'net_minor', v_prev.net_minor::text,
             'transfer_status', t.status, 'requested_execution_date', t.requested_execution_date,
             'amount_minor', t.amount_minor::text,
             'debited_on', (select e.effective_date from public.ledger_entry e where e.id = t.entry_id),
             'returned_on', (select e.effective_date from public.ledger_entry e where e.id = t.return_entry_id),
             'booked_on', v_prev.booked_on))
    into v_follow
    from (select 1) one left join public.bank_transfer t on t.id = v_prev.transfer_id;
  end if;

  -- money received on the client's files and not remitted, as of K (C. civ. 1993, OQ-40; review figures#2): per file
  -- and reason, what each payment matched to one of them by K still held on 4710 at K — its amount less what its
  -- other entries posted by K moved (allocations, forwards, refunds, returns, and their reversals: a refund that came
  -- back by K is held again, review legal#3). The payments that can have held money at K: those holding some now,
  -- those refunded or returned since K, and those allocated or forwarded since K (their entries are the client's
  -- pending items posted after K). No payer data.
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', h.file, 'reason', h.reason, 'currency', h.currency, 'amount_minor', h.amount::text,
           'first_date', h.first_date, 'last_date', h.last_date, 'count', h.n::text)
           order by h.file, h.reason, h.currency), '[]')
  into v_held
  from (select a.external_ref as file,
               coalesce(p.review_reason, case when p.status in ('refund_pending', 'refunded') then 'refund_pending'
                                              else 'pending' end) as reason,
               p.currency, sum(u.unallocated) as amount, min(p.booking_date) as first_date,
               max(p.booking_date) as last_date, count(*) as n
        from (select distinct c.id
              from (select y.id from public.payment y
                    where y.organization_id = r.organization_id
                      and y.status in ('matched', 'partially_allocated', 'refund_pending')
                      and y.client_organization_id = r.client_organization_id
                    union all
                    select y.id from public.payment y
                    where y.organization_id = r.organization_id and y.status in ('refunded', 'returned')
                      and y.client_organization_id = r.client_organization_id and y.updated_at > r.known_at
                    union all
                    select e.payment_id from private.remittance_pending q
                    cross join lateral (select y.payment_id from public.ledger_entry y where y.id = q.ledger_entry_id
                                        offset 0) e
                    where q.organization_id = r.organization_id
                      and q.client_organization_id = r.client_organization_id
                      and q.posted_at > r.known_at and e.payment_id is not null) c) c
        cross join lateral (select y.* from public.payment y where y.id = c.id offset 0) p
        cross join lateral (
          select (p.amount_minor - coalesce(sum(lp.amount_minor), 0))::bigint as unallocated
          from (select e.id from public.ledger_entry e
                where e.payment_id = p.id and e.entry_type <> 'cash_in' and e.posted_at <= r.known_at offset 0) e
          cross join lateral (select y.amount_minor from public.ledger_posting y
                              where y.entry_id = e.id
                                and (select la.book from public.ledger_account la where la.id = y.ledger_account_id)
                                    = 'unallocated_payment'
                              offset 0) lp) u
        cross join lateral (select q.external_ref from public.account q where q.id = p.account_id offset 0) a
        where p.client_organization_id = r.client_organization_id and p.created_at <= r.known_at
          and p.matched_at <= r.known_at and u.unallocated > 0
        group by 1, 2, 3) h;

  -- refunded to payers between the previous K and this K, and not back by K (a refund that bounced by K is money held
  -- again, above: review legal#3, figures#3)
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', h.file, 'reason', h.reason, 'currency', h.currency, 'amount_minor', h.amount::text,
           'first_date', h.first_date, 'last_date', h.last_date, 'count', h.n::text)
           order by h.file, h.reason, h.currency), '[]')
  into v_refunded
  from (select a.external_ref as file, q.reason_code as reason, q.currency, sum(q.amount_minor) as amount,
               min(q.executed_on) as first_date, max(q.executed_on) as last_date, count(*) as n
        from public.refund_request q
        cross join lateral (select y.account_id, y.client_organization_id from public.payment y
                            where y.id = q.payment_id offset 0) p
        cross join lateral (select y.external_ref from public.account y where y.id = p.account_id offset 0) a
        cross join lateral (select y.posted_at from public.ledger_entry y where y.id = q.cash_out_entry_id offset 0) e
        left join lateral (select y.posted_at from public.ledger_entry y where y.id = q.bounce_entry_id offset 0) b
          on true
        where q.organization_id = r.organization_id and q.status in ('executed', 'bounced')
          and p.client_organization_id = r.client_organization_id
          and e.posted_at <= r.known_at and (v_prev.known_at is null or e.posted_at > v_prev.known_at)
          and (q.status = 'executed' or b.posted_at > r.known_at)
        group by a.external_ref, q.reason_code, q.currency) h;

  -- the position (§10.7): owed to the client at K — every item pending then is this run's (one live run per client
  -- and currency, I14) — and after this payout (still owed once the run is cancelled); what the client owes the
  -- servicer (4111 + 4112) as known at K and after this statement's documents and the settlement at the payout's debit
  -- (none once cancelled: every document of the run counts, the approval's and the cancellation's)
  select coalesce(sum(private.ledger_balance(la.id, '9999-12-31'::date, r.known_at)), 0)
  into v_receivable
  from public.ledger_account la
  where la.organization_id = r.organization_id and la.book = 'commission_receivable'
    and la.client_organization_id = r.client_organization_id and la.currency = r.currency;
  select coalesce(sum(private.ledger_balance(la.id, '9999-12-31'::date, r.known_at)), 0)
  into v_advances
  from public.ledger_account la
  where la.organization_id = r.organization_id and la.book = 'client_advance_receivable'
    and la.client_organization_id = r.client_organization_id and la.currency = r.currency;
  select coalesce(sum(i.ttc_minor), 0) into v_docs_ttc
  from public.commission_invoice i where i.run_id = r.id and (v_cancelled or i.reason <> 'run_cancelled');
  v_position := jsonb_build_object(
    'owed_before_minor', r.gross_minor::text,
    'owed_after_minor', case when v_cancelled then r.gross_minor else 0 end::text,
    'receivable_before_minor', v_receivable::text,
    'receivable_after_minor',
      (v_receivable + v_docs_ttc
       - case when v_cancelled then 0 else coalesce((r.settlement_plan ->> 'dc')::bigint, 0) end)::text,
    'advances_before_minor', v_advances::text,
    'advances_after_minor',
      (v_advances - case when v_cancelled then 0 else coalesce((r.settlement_plan ->> 'da')::bigint, 0) end)::text);

  -- the parties as the run's invoices froze them at approval (review figures#2), else as they stand
  select i.payload -> 'seller', i.payload -> 'buyer' into v_issuer, v_client
  from public.commission_invoice i where i.run_id = r.id and i.reason = 'commission'
  order by i.seq limit 1;

  v_payload := jsonb_build_object(
    'schema', 1,
    'number', r.number,
    'issue_date', v_issue,
    'known_at', to_char(r.known_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'currency', r.currency,
    'exponent', v_exp,
    'status', r.status,
    'cancelled_on', case when v_cancelled then (r.cancelled_at at time zone 'Europe/Paris')::date end,
    -- N = 0: the settlement was posted at approval, nothing is transferred (review legal#5)
    'settled_on', case when r.status = 'booked' and r.transfer_id is null then r.booked_on end,
    'issuer', coalesce(v_issuer, private.invoice_party(r.organization_id)),
    'client', coalesce(v_client, private.invoice_party(r.client_organization_id)),
    'mandates', v_mandates,
    'service_period', jsonb_build_object('from', r.service_from, 'to', r.service_to),
    'totals', v_totals,
    'files', v_files,
    'natures', v_natures,
    'line_columns', private.remittance_statement_line_columns(),
    'lines', v_lines,
    'documents', v_docs,
    'earlier_settled', v_earlier,
    'payout', v_payout,
    'requested_execution_date', r.requested_execution_date,
    'follow_up', coalesce(v_follow, '[]'),
    'not_remitted', jsonb_build_object('held', v_held, 'refunded', v_refunded),
    'position', v_position);

  return v_payload;
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new ones internal, the command and its reads the back
-- office's)
------------------------------------------------------------------------------------------

-- critic2 CSO2-11: the new internals (PostgreSQL grants EXECUTE to PUBLIC by default); only the SECURITY DEFINER
-- callers use them
revoke execute on function private.transfer_line_class(uuid), private.transfer_line_candidates(uuid, text),
  private.transfer_line_members(uuid), private.transfer_line_returnable(uuid),
  private.transfer_line_open_unplanned(uuid, uuid, uuid, text, text), private.transfer_line_parse(jsonb),
  private.transfer_line_tenant(uuid), private.transfer_line_pre(uuid), private.unplanned_own_item(uuid),
  private.transfer_line_check(uuid, boolean), private.transfer_line_text(), private.transfer_line_locks(uuid),
  private.transfer_line_post(uuid, text), private.remittance_draft_requeue(uuid), private.transfer_line_parts_json(),
  private.transfer_line_supersedes(uuid), private.unsplit_details_differ(jsonb, jsonb, boolean[]),
  private.transfer_line_preview_of(uuid, jsonb, boolean), private.remittance_run_late_lines(uuid, date),
  private.transfer_line_bb(uuid)
  from public, anon, authenticated, service_role;
-- the redefined internals, as granted by 20261116090000 (the worker's: the debit job, the checks, the schedule) and by
-- 20261117090000 (the funds pass's: called by private.apply_bank_bookings and the commands only)
revoke execute on function private.bank_line_booking_guard(), private.bank_booking_post_rows(uuid),
  private.post_bank_bookings(uuid, boolean)
  from public, anon, authenticated, service_role;
revoke execute on function private.pending_item_deadlines(uuid, boolean), private.remittance_statement_build(uuid)
  from public, anon, authenticated;
grant execute on function private.pending_item_deadlines(uuid, boolean), private.remittance_statement_build(uuid)
  to service_role;
-- the import, as granted by 20261109120000 (the worker's)
revoke execute on function private.ingest_statement(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function private.ingest_statement(uuid, jsonb) to service_role;
-- the command and its reads (aal2 money staff, checked inside)
revoke execute on function public.book_transfer_line(text, uuid, jsonb, text, text),
  public.transfer_line_preview(uuid, jsonb), public.transfer_line_options(uuid)
  from public, anon;
grant execute on function public.book_transfer_line(text, uuid, jsonb, text, text),
  public.transfer_line_preview(uuid, jsonb), public.transfer_line_options(uuid)
  to authenticated;
