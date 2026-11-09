-- M2b-6: money leaving the client-funds account — bank returns and chargebacks, refunds to payers — plus payments the
-- debtor made to the client directly, CSV suspected duplicates resolved, and the nightly checks of the payments books.
-- Design: docs/design/m2b-payments.md §2 #3 #13, §6 (bank_debit_link, refund_request), §7, §8.1, §9, §11, §12, §13;
-- decisions: docs/adr/0013-payments-allocation-client-money.md (founder #8, #9, #11, #13, #18, #20; M2b-6 addendum).
-- Forward-only: nothing of 20261110090000 or earlier is edited; the functions listed below are redefined.
--
-- What changes for money:
--   * a bank return or chargeback of a payment (a debit linked to the payment, automatically by its end-to-end id or
--     bank transaction id, or by ops) reverses the payment's live allocations and forwards AT THE RETURN DATE (design §2
--     #3: never back-dated), then books a `cash_out` (Dr 4710 pool / Cr 5120 bank account) at the return date; the
--     payment is `returned` (final), its receipt gets a final void version (receipts job), the client is told
--     (founder #13). A partial return reverses the allocations too and leaves the rest of the payment to ops;
--   * a refund to the payer (founder #8 overpayment, #9 other currency, #11 rolled-back batch, 1302-1 unidentified,
--     #12 held file) is requested by ops (`refund_request`, our end-to-end id RFD…), executed by ops in the bank, and
--     booked as a `cash_out` only when the bank's debit shows it (linked by its RFD id, or by ops): the ledger cash keeps
--     following the bank (I9). Never more than what is left of the payment (LG007). A refund that comes back unpaid
--     reverses its cash_out;
--   * a payment the debtor made to the client directly lowers the receivables by an `adjustment` (−1100 / +3100) in the
--     legal order (the worker's waterfall, designation = the debts the client names): no client money moves;
--   * bank fees and other debits are not booked (founder #20): an explained gap;
--   * a CSV suspected duplicate is released (it becomes a payment and its cash_in, or a debit to classify) or kept out
--     as a duplicate;
--   * nightly checks (pg_cron → worker job → private.run_payment_checks): client money closed per currency (I8), the
--     cash of each bank account = what its payments brought in less what went back out, cash_in = payments per
--     statement day (I11), each payment's position against its status (I4, I5, design §7), no receivable allocated
--     below zero (I6), the owner-claim mirror, one current receipt per identified payment, one notification per
--     entry, statement continuity and the bank balance (I9), and the ageing of money not allocated, refunds, debits and
--     duplicates (alerts).
--
-- Redefined: private.client_notification_guard, private.bank_unposted, private.payment_insert_guard,
-- private.post_allocations (dated after a partial return's reversals), public.allocate_payment (from `partial_return`
-- too), public.payment_detail, public.account_detail, public.client_payment_feed.

------------------------------------------------------------------------------------------
-- Payments: ops may send what is left after a partial return to allocation again; states the refunds and returns keep
------------------------------------------------------------------------------------------

alter table public.payment drop constraint payment_allocation_instruction_check,
  add constraint payment_allocation_instruction_check check (
    allocation_instruction is null
    or (jsonb_typeof(allocation_instruction) = 'object'
        and jsonb_typeof(allocation_instruction -> 'releases') = 'array'
        and jsonb_array_length(allocation_instruction -> 'releases') >= 1
        and (allocation_instruction -> 'releases')
            <@ '["allocation_reversed", "nothing_due", "credit_note_to_apply", "before_servicing_start",
                 "hold_blocks_allocation", "overpayment", "partial_return"]'::jsonb
        and jsonb_typeof(coalesce(allocation_instruction -> 'decisions', '[]')) = 'array'));

-- Lines the debit job and the pages look at (returns, our refunds, suspected duplicates), led by the servicer.
create index bank_transaction_debit_idx on public.bank_transaction (organization_id, booking_date, id)
  where kind in ('return', 'refund_out', 'suspected_duplicate');
-- A return names the bank transaction id of the credit it undoes (camt.053 Refs/TxId).
create index bank_transaction_tx_idx on public.bank_transaction (bank_account_id, tx_id)
  where tx_id is not null and direction = 'credit';
-- Fees and other debits: shown as explained gaps (founder #20).
create index bank_transaction_other_debit_idx on public.bank_transaction (organization_id, booking_date, id)
  where kind = 'other_debit';

------------------------------------------------------------------------------------------
-- Refund requests (design §6; founder #8, #9, #11, #12; C. civ. 1302-1): ops ask, the bank executes, the statement
-- shows it. Our own end-to-end id RFD… is what the bank's debit carries back.
------------------------------------------------------------------------------------------

create table public.refund_request (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  payment_id uuid not null,
  bank_account_id uuid not null,
  currency char(3) not null,
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  payee_iban text not null check (private.iban_valid(payee_iban)),
  payee_name text not null check (length(btrim(payee_name)) between 1 and 140),
  payee_is_payer boolean not null,                     -- the IBAN the payment came from (1302-1: « à celui de qui… »)
  end_to_end_id text not null unique check (end_to_end_id ~ '^RFD[0-9A-F]{12}$'),
  reason_code text not null check (reason_code in ('overpayment', 'currency_mismatch', 'no_mandate', 'unidentified',
                                                   'held_file', 'account_closed', 'partial_return', 'other')),
  reason text not null check (length(btrim(reason)) between 1 and 2000),   -- ops' motif (staff only)
  status text not null default 'requested' check (status in ('requested', 'executed', 'cancelled', 'bounced')),
  prior_status text not null,                          -- the payment's state when asked (back to it if cancelled)
  prior_review_reason text,
  requested_by uuid not null,
  requested_at timestamptz not null default now(),
  bank_transaction_id uuid unique references public.bank_transaction (id),     -- the debit that executed it
  cash_out_entry_id uuid unique references public.ledger_entry (id),
  executed_on date,
  bounce_transaction_id uuid unique references public.bank_transaction (id),   -- the credit that brought it back
  bounce_entry_id uuid unique references public.ledger_entry (id),
  cancelled_at timestamptz,
  cancelled_by uuid,
  cancel_reason text check (length(btrim(cancel_reason)) between 1 and 2000),
  updated_at timestamptz not null default now(),
  constraint refund_request_payment_fk foreign key (payment_id, organization_id)
    references public.payment (id, organization_id),
  constraint refund_request_bank_fk foreign key (bank_account_id, organization_id, currency)
    references public.bank_account (id, organization_id, currency),
  constraint refund_request_executed check ((status in ('executed', 'bounced'))
    = (bank_transaction_id is not null and cash_out_entry_id is not null and executed_on is not null)),
  constraint refund_request_bounced check ((status = 'bounced') = (bounce_transaction_id is not null
                                                                   and bounce_entry_id is not null)),
  constraint refund_request_cancelled check ((status = 'cancelled') = (cancelled_at is not null
                                                                       and cancel_reason is not null))
);
-- One refund at a time per payment: « ≤ what is left − pending refunds » (design §9) without arithmetic on pending ones.
create unique index refund_request_pending_uq on public.refund_request (payment_id) where status = 'requested';
create index refund_request_payment_idx on public.refund_request (payment_id);
create index refund_request_waiting_idx on public.refund_request (organization_id, requested_at) where status = 'requested';
comment on table public.refund_request is
  'A refund ops asked for (RFD end-to-end id); booked as a cash_out when the bank''s debit shows it (design §6, §8.1).';

-- Starts requested on its payment's bank account; afterwards only requested → executed | cancelled, executed → bounced.
create or replace function private.refund_request_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  p public.payment;
begin
  if tg_op = 'INSERT' then
    select * into p from public.payment where id = new.payment_id;
    if new.status <> 'requested' or p.bank_account_id is distinct from new.bank_account_id
       or p.currency is distinct from new.currency then
      raise exception 'refund request: it starts requested, on its payment''s bank account and currency'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.payment_id, new.bank_account_id, new.currency, new.amount_minor, new.payee_iban,
      new.payee_name, new.payee_is_payer, new.end_to_end_id, new.reason_code, new.reason, new.prior_status,
      new.prior_review_reason, new.requested_by, new.requested_at)
     is distinct from (old.id, old.organization_id, old.payment_id, old.bank_account_id, old.currency, old.amount_minor,
                       old.payee_iban, old.payee_name, old.payee_is_payer, old.end_to_end_id, old.reason_code, old.reason,
                       old.prior_status, old.prior_review_reason, old.requested_by, old.requested_at)
     or not ((old.status = 'requested' and new.status in ('executed', 'cancelled'))
             or (old.status = 'executed' and new.status = 'bounced'))
     or (old.status = 'executed' and (new.bank_transaction_id, new.cash_out_entry_id, new.executed_on)
                                     is distinct from (old.bank_transaction_id, old.cash_out_entry_id, old.executed_on)) then
    raise exception 'refund request %: only requested → executed | cancelled and executed → bounced', old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger refund_request_guard before insert or update on public.refund_request
  for each row execute function private.refund_request_guard();
alter table public.refund_request enable always trigger refund_request_guard;
create trigger refund_request_no_delete before delete or truncate on public.refund_request
  for each statement execute function private.refuse_delete();
alter table public.refund_request enable always trigger refund_request_no_delete;
create trigger refund_request_touch before update on public.refund_request
  for each row execute function private.touch_updated_at();
create trigger refund_request_change_log after insert or update or delete on public.refund_request
  for each row execute function private.log_change();

-- A payment waits for its refund while one is requested, and only then (whatever path changes it: a reversal while a
-- refund is pending is refused); a payment the bank took back stays returned and on its file.
create or replace function private.payment_money_out_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_pending boolean;
begin
  if old.status = 'returned' and (new.status, new.account_id) is distinct from (old.status, old.account_id) then
    raise exception 'payment %: returned by the bank, it stays so', old.id using errcode = 'check_violation';
  end if;
  select exists (select 1 from public.refund_request q where q.payment_id = new.id and q.status = 'requested')
  into v_pending;
  if (new.status = 'refund_pending') <> v_pending then
    raise exception 'payment %: a refund is pending: cancel it first (or none is: it cannot wait for one)', new.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger payment_money_out_guard before update on public.payment
  for each row when (old.status in ('returned', 'refund_pending') or new.status = 'refund_pending')
  execute function private.payment_money_out_guard();
alter table public.payment enable always trigger payment_money_out_guard;

------------------------------------------------------------------------------------------
-- Bank lines: what each debit (or credit undoing one) is (design §6 bank_debit_link), what the debit job could not
-- decide, and ops' decisions on CSV suspected duplicates
------------------------------------------------------------------------------------------

-- kind: return (the bank took back a payment: R-transaction, chargeback, reversal), refund (our refund executed),
-- refund_returned (our refund came back unpaid), explained (ops: not booked in M2b — a fee taken back, a bank error
-- corrected by the bank…; founder #20). Fees and other debits need no row: they are explained by their kind.
create table public.bank_debit_link (
  bank_transaction_id uuid primary key references public.bank_transaction (id),
  organization_id uuid not null references public.organization (id),
  bank_account_id uuid not null,
  kind text not null check (kind in ('return', 'refund', 'refund_returned', 'explained')),
  payment_id uuid,
  refund_request_id uuid references public.refund_request (id),
  cash_entry_id uuid unique references public.ledger_entry (id),    -- the cash_out, or the reversal of a refund's one
  method text not null check (method in ('auto', 'ops')),
  reason text check (length(btrim(reason)) between 1 and 2000),   -- ops' motif (staff only)
  decided_by uuid,
  decided_at timestamptz not null default now(),
  constraint bank_debit_link_payment_fk foreign key (payment_id, organization_id)
    references public.payment (id, organization_id),
  constraint bank_debit_link_shape check (
    (kind = 'explained') = (payment_id is null)
    and (kind in ('refund', 'refund_returned')) = (refund_request_id is not null)
    and (kind = 'explained') = (cash_entry_id is null)
    and (method = 'ops') = (decided_by is not null)
    and (kind <> 'explained' or (method = 'ops' and reason is not null)))
);
create index bank_debit_link_payment_idx on public.bank_debit_link (payment_id) where payment_id is not null;
create index bank_debit_link_org_idx on public.bank_debit_link (organization_id, decided_at desc);
comment on table public.bank_debit_link is
  'What a bank debit (or a credit undoing one) is: a payment''s return, our refund, its bounce, or explained by ops.';

-- What the debit job found for a line it could not link (derived, replaced at each run, gone once linked).
create table public.bank_debit_review (
  bank_transaction_id uuid primary key references public.bank_transaction (id),
  organization_id uuid not null references public.organization (id),
  reason text not null check (reason in ('no_candidate', 'ambiguous', 'amount_differs', 'partial_return',
                                         'refund_not_pending', 'already_returned', 'changed')),
  candidates jsonb not null default '[]' check (jsonb_typeof(candidates) = 'array'),
  checked_at timestamptz not null default now()
);
create index bank_debit_review_org_idx on public.bank_debit_review (organization_id);
comment on table public.bank_debit_review is
  'Debits the job left to ops: why, and the payments or refunds it found (derived; replaced at each run).';

-- What a CSV line held as a suspected duplicate was read as before it was held (kind and method of the parser), kept by
-- a trigger while the import's stage rows still exist: a released line becomes what it was.
create table private.bank_line_held_kind (
  bank_transaction_id uuid primary key references public.bank_transaction (id),
  kind text not null check (kind in ('debtor_credit', 'return', 'refund_out', 'other_debit', 'batch_unsplit')),
  method text not null check (method in ('sct', 'sdd', 'card', 'cheque', 'other'))
);

create table public.bank_duplicate_resolution (
  bank_transaction_id uuid primary key references public.bank_transaction (id),
  organization_id uuid not null references public.organization (id),
  bank_account_id uuid not null,
  decision text not null check (decision in ('released', 'duplicate')),
  released_kind text check (released_kind in ('debtor_credit', 'return', 'refund_out', 'other_debit', 'batch_unsplit')),
  reason text not null check (length(btrim(reason)) between 1 and 2000),
  decided_by uuid not null,
  decided_at timestamptz not null default now(),
  constraint bank_duplicate_resolution_kind check ((decision = 'released') = (released_kind is not null))
);
create index bank_duplicate_resolution_org_idx on public.bank_duplicate_resolution (organization_id, decided_at desc);
comment on table public.bank_duplicate_resolution is
  'Ops'' decision on a CSV line held as a suspected duplicate: released (booked as what it is) or a duplicate (never booked).';

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
     or (n.cash_entry_id is not null and (e.payment_id is distinct from n.payment_id
                                          or (n.kind in ('return', 'refund') and e.entry_type <> 'cash_out')
                                          or (n.kind = 'refund_returned' and e.entry_type <> 'reversal')));
  if v_bad is not null then
    raise exception 'bank debit link %: it does not match its line, payment, refund or entry', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger bank_debit_link_guard after insert on public.bank_debit_link
  referencing new table as new_rows for each statement execute function private.bank_debit_link_guard();
alter table public.bank_debit_link enable always trigger bank_debit_link_guard;
create trigger bank_debit_link_append_only before update or delete or truncate on public.bank_debit_link
  for each statement execute function private.refuse_change();
alter table public.bank_debit_link enable always trigger bank_debit_link_append_only;

create or replace function private.bank_duplicate_resolution_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare v_bad text;
begin
  select min(n.bank_transaction_id::text) into v_bad
  from new_rows n left join public.bank_transaction t on t.id = n.bank_transaction_id
  where t.id is null or t.kind <> 'suspected_duplicate' or t.organization_id <> n.organization_id
     or t.bank_account_id <> n.bank_account_id
     or (n.released_kind in ('debtor_credit', 'batch_unsplit') and t.direction <> 'credit')
     or (n.released_kind in ('refund_out', 'other_debit') and t.direction <> 'debit');
  if v_bad is not null then
    raise exception 'duplicate resolution %: the line is not a held duplicate of this bank account, or not of that kind', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger bank_duplicate_resolution_guard after insert on public.bank_duplicate_resolution
  referencing new table as new_rows for each statement execute function private.bank_duplicate_resolution_guard();
alter table public.bank_duplicate_resolution enable always trigger bank_duplicate_resolution_guard;
create trigger bank_duplicate_resolution_append_only before update or delete or truncate on public.bank_duplicate_resolution
  for each statement execute function private.refuse_change();
alter table public.bank_duplicate_resolution enable always trigger bank_duplicate_resolution_append_only;

-- The parser's reading of a line held as a duplicate, from the import's stage rows (same transaction as the insert).
-- Fires on every import's insert (up to 250k lines): a scan of the new rows and, for each held one only, one key
-- lookup of its stage row (lateral: no plan cached for a small first insert can turn into a pairwise join).
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
                      where x.statement_id = n.statement_id and x.line_no = n.line_no) s
  where n.kind = 'suspected_duplicate' and s.kind in ('debtor_credit', 'return', 'refund_out', 'other_debit', 'batch_unsplit')
  on conflict (bank_transaction_id) do nothing;
  return null;
end;
$$;
create trigger bank_transaction_held_kind after insert on public.bank_transaction
  referencing new table as new_rows for each statement execute function private.bank_transaction_held_kind();
alter table public.bank_transaction enable always trigger bank_transaction_held_kind;

-- What a held line is, for lines held before this migration (no stage row left): from its own facts, as the parsers
-- read them (a return reason, a reversal or an original end-to-end id → return; our RFD id → refund_out). A CSV return
-- read from the bank's words in the label (« RETOUR VIR SEPA ») has none of these: the page shows the label to ops,
-- who release it or not.
create or replace function private.held_line_kind(p_bank_transaction_id uuid)
returns table (kind text, method text)
language sql
stable
set search_path = ''
as $$
  select coalesce(h.kind, case
           when t.return_reason is not null or t.reversal_indicator or t.original_end_to_end_id is not null then 'return'
           when t.direction = 'credit' then 'debtor_credit'
           when t.end_to_end_id like 'RFD%' then 'refund_out'
           else 'other_debit' end),
         coalesce(h.method, 'other')
  from public.bank_transaction t
  left join private.bank_line_held_kind h on h.bank_transaction_id = t.id
  where t.id = p_bank_transaction_id;
$$;

------------------------------------------------------------------------------------------
-- A released duplicate credit is a payment (redefined from 20261109120000): its line is a credit a debtor paid, a
-- single payment or an unsplit batch, or a line held as a suspected duplicate that ops released as a credit.
------------------------------------------------------------------------------------------

create or replace function private.payment_insert_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(n.id::text) into v_bad
  from new_rows n
  join public.bank_transaction t on t.id = n.bank_transaction_id
  join public.bank_statement s on s.id = t.statement_id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
  where t.direction <> 'credit' or s.format <> n.channel
     or not (t.kind in ('debtor_credit', 'batch_unsplit')
             or (t.kind = 'suspected_duplicate' and coalesce(r.decision = 'released'
                                                              and r.released_kind in ('debtor_credit', 'batch_unsplit'),
                                                              false)));
  if v_bad is not null then
    raise exception 'payment %: its bank line is not a debtor credit of a statement in this channel', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

-- Lines of a bank account booked on or before a date that are not in the ledger (redefined from 20261109120000; I9:
-- closing balance at D = 5120[bank](D) + this): every line but the payments (credits, released duplicates included)
-- and the debits and credits booked by a link (return, refund, refund_returned). Fees, other debits, lines ops
-- explained, lines to classify and held duplicates remain: the explained or open gap.
create or replace function private.bank_unposted(p_bank_account_id uuid, p_as_of date)
returns table (minor bigint, lines bigint)
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(case t.direction when 'credit' then t.amount_minor else -t.amount_minor end), 0)::bigint,
         count(*)
  from public.bank_transaction t
  where t.bank_account_id = p_bank_account_id and t.booking_date <= p_as_of
    and not (t.direction = 'credit' and t.kind in ('debtor_credit', 'batch_unsplit'))
    and not exists (select 1 from public.payment p where p.bank_transaction_id = t.id)
    and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id and l.kind <> 'explained');
$$;

------------------------------------------------------------------------------------------
-- Creditor notifications (redefined from 20261109190000): a return tells the client (founder #13) — each reversed
-- allocation (`payment_allocation_reversed`, reason `bank_return`), each reversed forward (`payment_forward_reversed`)
-- and the return itself (`payment_returned`, its cash_out entry) when the payment had a file.
------------------------------------------------------------------------------------------

alter table public.client_notification drop constraint client_notification_kind_check,
  add constraint client_notification_kind_check check (kind in (
    'payment_allocated', 'payment_forwarded', 'payment_allocation_reversed', 'payment_held',
    'payment_forward_reversed', 'payment_returned'));
alter table public.client_notification drop constraint client_notification_reason_check,
  add constraint client_notification_reason_check check (reason in (
    'hold_blocks_allocation', 'ops_correction', 'file_recalled', 'before_servicing_start', 'client_ratification',
    'bank_return'));

create or replace function private.client_notification_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
set enable_bitmapscan = off
as $$
declare v_bad text;
begin
  select min(n.id::text) into v_bad
  from new_rows n
  left join public.payment p on p.id = n.payment_id
  left join public.ledger_entry e on e.id = n.ledger_entry_id
  left join public.ledger_entry t on t.id = e.reverses_entry_id
  left join public.account a on a.id = n.account_id
  where p.id is null or p.organization_id <> n.organization_id
     or (n.ledger_entry_id is not null and e.id is null)
     or (n.portfolio_id is not null and n.account_id is null
         and not exists (select 1 from public.portfolio x where x.id = n.portfolio_id
                           and x.client_organization_id = n.client_organization_id))
     or (n.account_id is not null and (a.id is null or a.organization_id <> n.organization_id
                                       or a.client_organization_id <> n.client_organization_id
                                       or a.portfolio_id is distinct from n.portfolio_id))
     or (n.kind not in ('payment_held', 'payment_returned')
         and (e.payment_id is distinct from n.payment_id or e.client_organization_id is distinct from n.client_organization_id))
     or (n.kind = 'payment_allocated' and (e.entry_type <> 'allocation' or e.account_id is distinct from n.account_id))
     or (n.kind = 'payment_allocation_reversed'
         and (e.entry_type <> 'reversal' or t.entry_type <> 'allocation' or e.account_id is distinct from n.account_id))
     or (n.kind = 'payment_forwarded' and e.entry_type <> 'forward')
     or (n.kind = 'payment_forward_reversed' and (e.entry_type <> 'reversal' or t.entry_type <> 'forward'))
     -- the return of a payment, told to the client of its file
     or (n.kind = 'payment_returned' and (e.entry_type <> 'cash_out' or e.payment_id is distinct from n.payment_id
                                          or n.account_id is null or p.account_id is distinct from n.account_id));
  if v_bad is not null then
    raise exception 'client notification %: it does not match its payment, entry or file', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- Posting money out (design §8.1): returns, refunds, refunds that bounce, lines ops explain. One function for the job
-- (automatic links, set-based) and ops' `link_debit` (one link, every refusal raised).
------------------------------------------------------------------------------------------

-- Working tables of the caller: the links to post and, for the job, what it leaves to ops.
create or replace function private.debit_link_begin()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._debit_link;
  drop table if exists pg_temp._debit_review;
  drop table if exists pg_temp._debit_skipped;
  create temp table _debit_link (
    ord integer not null unique,
    bank_transaction_id uuid primary key,
    kind text not null check (kind in ('return', 'refund', 'refund_returned', 'explained')),
    payment_id uuid,
    refund_request_id uuid,
    method text not null check (method in ('auto', 'ops')),
    decided_by uuid,
    reason text,
    expected_left_minor bigint      -- ops: what is left of the payment as the page showed it (compare and set)
  ) on commit drop;
  create temp table _debit_review (
    bank_transaction_id uuid primary key,
    reason text not null,
    candidates jsonb not null default '[]'
  ) on commit drop;
  create temp table _debit_skipped (
    bank_transaction_id uuid primary key,
    why text not null
  ) on commit drop;
end;
$$;

-- Posts pg_temp._debit_link. Locks in the order every payments writer takes them (ADR-0013): the payments' files FOR
-- KEY SHARE, the payments FOR UPDATE, their refund requests, the bank accounts FOR SHARE, then the servicer's
-- allocation lock. Re-checks every link on what it finds under these locks; `p_strict` (ops) raises the first refusal,
-- otherwise (job) refused links are left in pg_temp._debit_skipped for the next run. Then, per link:
--   return:          the payment's live allocations and forwards reversed at the return date (an entry dated after
--                    it, at its own date), the client told of each; a cash_out at the return date; returned in full →
--                    `returned` (pending refund cancelled; the receipts job issues the final void version), in part →
--                    waits for ops (`partial_return`); the client of its file told of the return;
--   refund:          a cash_out at the debit's date; the request executed; the payment `refunded`, `allocated`, or
--                    back to its earlier reason if something is left;
--   refund_returned: the refund's cash_out reversed at the credit's date; the request bounced; the payment back to the
--                    reason it had when the refund was asked;
--   explained:       nothing booked (founder #20), ops' motif kept.
create or replace function private.post_debit_links(p_organization_id uuid, p_strict boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_why record;
  r record;
  e record;
  v_n_account uuid;
  v_n_portfolio uuid;
  v_rev uuid;
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

  -- The facts, read under the locks.
  drop table if exists pg_temp._dl;
  create temp table _dl on commit drop as
  select l.*, t.organization_id as line_org, t.bank_account_id as line_bank, t.direction, t.currency,
         t.amount_minor as line_minor, t.booking_date as line_date, coalesce(dr.released_kind, t.kind) as line_kind,
         (t.kind = 'suspected_duplicate' and dr.decision is distinct from 'released') as held,
         exists (select 1 from public.bank_debit_link x where x.bank_transaction_id = l.bank_transaction_id) as linked,
         p.organization_id as pay_org, p.bank_account_id as pay_bank, p.booking_date as pay_date, p.status as pay_status,
         p.account_id, p.amount_minor as pay_minor,
         q.payment_id as req_payment, q.status as req_status, q.amount_minor as req_minor, q.bank_account_id as req_bank,
         q.cash_out_entry_id as req_entry, q.executed_on as req_executed_on, q.prior_review_reason as req_prior_reason,
         0::bigint as allocated, 0::bigint as returned, 0::bigint as unallocated, 0::bigint as pending,
         null::text as why, null::uuid as cash_entry_id
  from pg_temp._debit_link l
  left join public.bank_transaction t on t.id = l.bank_transaction_id
  left join public.bank_duplicate_resolution dr on dr.bank_transaction_id = l.bank_transaction_id
  left join public.payment p on p.id = l.payment_id
  left join public.refund_request q on q.id = l.refund_request_id;
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
    when d.held then 'held_duplicate'
    when d.kind = 'explained' then case
      when d.payment_id is not null or d.refund_request_id is not null then 'bad_request'
      when d.direction = 'credit' and d.line_kind in ('debtor_credit', 'batch_unsplit') then 'payment_line'
      when nullif(btrim(d.reason), '') is null then 'reason_required' end
    when d.pay_org is distinct from p_organization_id then 'payment_unknown'
    when d.pay_bank is distinct from d.line_bank then 'other_bank_account'
    when d.kind = 'return' then case
      when d.direction <> 'debit' or d.line_kind not in ('return', 'refund_out', 'other_debit') then 'not_a_return'
      when d.refund_request_id is not null then 'bad_request'
      when d.pay_status = 'returned' then 'already_returned'
      when d.line_date < d.pay_date then 'before_payment'
      when d.line_minor > d.pay_minor - d.returned then 'amount_exceeds'
      when d.line_minor < d.pay_minor - d.returned and d.pending > 0 then 'refund_pending'  -- partial: cancel it first
      when d.method = 'ops' and d.expected_left_minor is distinct from d.pay_minor - d.returned then 'payment_changed' end
    when d.kind = 'refund' then case
      when d.direction <> 'debit' or d.line_kind not in ('refund_out', 'other_debit', 'return') then 'not_a_refund'
      when d.req_status is distinct from 'requested' or d.req_payment is distinct from d.payment_id then 'refund_not_pending'
      when d.req_bank is distinct from d.line_bank then 'other_bank_account'
      when d.line_minor <> d.req_minor then 'amount_differs'
      when d.line_date < d.pay_date then 'before_payment'
      when d.line_minor > d.unallocated then 'amount_exceeds' end
    when d.kind = 'refund_returned' then case
      when d.direction <> 'credit' or d.line_kind <> 'return' then 'not_a_refund_return'
      when d.req_status is distinct from 'executed' or d.req_payment is distinct from d.payment_id then 'refund_not_executed'
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
    raise exception 'debit link refused: %', v_why.why using errcode = 'check_violation';
  end if;
  insert into pg_temp._debit_skipped (bank_transaction_id, why)
  select d.bank_transaction_id, d.why from pg_temp._dl d where d.why is not null
  on conflict (bank_transaction_id) do update set why = excluded.why;
  delete from pg_temp._dl d where d.why is not null;
  analyze pg_temp._dl;

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

  return jsonb_build_object(
    'returns', (select count(*) from pg_temp._dl where kind = 'return'),
    'refunds', (select count(*) from pg_temp._dl where kind = 'refund'),
    'refunds_returned', (select count(*) from pg_temp._dl where kind = 'refund_returned'),
    'explained', (select count(*) from pg_temp._dl where kind = 'explained'),
    'skipped', (select count(*) from pg_temp._debit_skipped));
end;
$$;

-- The lines the debit job looks at (unlinked returns, our refunds, credits undoing a debit; released duplicates as what
-- they were), in date order after `p_after`, and what each may be: the payment its end-to-end id or bank transaction id
-- names (a return), the refund request its RFD id names (a refund, or a refund that came back). One row per (line,
-- candidate), a line without any once with nulls. Keyed lookups whatever the statistics (a just-imported statement is
-- not analysed).
create or replace function private.debit_candidates(p_organization_id uuid, p_after_date date, p_after_id uuid,
                                                    p_limit integer)
returns table (line_id uuid, line_kind text, direction text, bank_account_id uuid, amount_minor bigint,
               booking_date date, payment_id uuid, refund_request_id uuid, via text, cand_bank_account_id uuid,
               cand_amount_minor bigint, cand_left_minor bigint, cand_unallocated_minor bigint,
               cand_pending_minor bigint, cand_status text, cand_date date)
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
    select p.id as payment_id, 'end_to_end_id'::text as via from public.payment p
    where p.end_to_end_id = coalesce(x.original_end_to_end_id, x.end_to_end_id) and p.bank_account_id = x.bank_account_id
    union
    select p.id, 'tx_id' from public.bank_transaction o join public.payment p on p.bank_transaction_id = o.id
    where x.tx_id is not null and o.bank_account_id = x.bank_account_id and o.tx_id = x.tx_id and o.direction = 'credit'
  ) c
  where x.direction = 'debit' and x.kind = 'return'
  union all
  -- our refund: the request whose RFD id the debit carries; a refund that came back: the one the credit names
  select x.id, q.payment_id, q.id, 'end_to_end_id'
  from pg_temp._dc_line x
  join public.refund_request q
    on q.end_to_end_id = case when x.direction = 'debit' then x.end_to_end_id
                              else coalesce(x.original_end_to_end_id, x.end_to_end_id) end
  where x.kind = 'refund_out' or (x.direction = 'credit' and x.kind = 'return');
  analyze pg_temp._dc_cand;

  return query
  select x.id, x.kind, x.direction, x.bank_account_id, x.amount_minor, x.booking_date, c.payment_id, c.refund_request_id,
         c.via, coalesce(q.bank_account_id, p.bank_account_id), coalesce(q.amount_minor, p.amount_minor),
         pos.amount_minor - pos.returned_minor, pos.unallocated_minor,
         coalesce((select sum(z.amount_minor) from public.refund_request z
                   where z.payment_id = c.payment_id and z.status = 'requested'), 0)::bigint,
         coalesce(q.status, p.status), coalesce(q.executed_on, p.booking_date)
  from pg_temp._dc_line x
  left join pg_temp._dc_cand c on c.line_id = x.id
  left join public.payment p on p.id = c.payment_id
  left join public.refund_request q on q.id = c.refund_request_id
  left join private.payment_positions(array(select y.payment_id from pg_temp._dc_cand y)) pos
    on pos.payment_id = c.payment_id
  order by x.booking_date, x.id, c.payment_id;
end;
$$;

-- The job's decisions (pg_temp._debit_link: automatic links; pg_temp._debit_review: lines left to ops): links posted,
-- reviews replaced. Returns the run's summary.
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
  insert into pg_temp._debit_review (bank_transaction_id, reason)
  select s.bank_transaction_id, 'changed' from pg_temp._debit_skipped s
  on conflict (bank_transaction_id) do nothing;
  delete from public.bank_debit_review v using pg_temp._debit_review r where v.bank_transaction_id = r.bank_transaction_id;
  insert into public.bank_debit_review (bank_transaction_id, organization_id, reason, candidates)
  select r.bank_transaction_id, p_organization_id, r.reason, r.candidates
  from pg_temp._debit_review r
  join public.bank_transaction t on t.id = r.bank_transaction_id and t.organization_id = p_organization_id
  where not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = r.bank_transaction_id);
  return v || jsonb_build_object('reviews', (select count(*) from pg_temp._debit_review));
end;
$$;

------------------------------------------------------------------------------------------
-- Commands (admins and ops managers at aal2, founder #18): idempotency key + request hash, compare and set with what
-- the page showed, milliseconds; a running allocation or debit job holds the allocation lock: they wait at most 2 s.
------------------------------------------------------------------------------------------

-- « Rembourser » (founder #8, #9, #11, #12; C. civ. 1302-1): what is left of a payment, to the payer's IBAN unless ops
-- give another one (ISO 13616 checked), with a reason code that matches the payment's state. Nothing is booked now: the
-- refund is booked when the bank's debit shows it (by its RFD id). One pending refund per payment.
create or replace function public.request_refund(p_idempotency_key text, p_payment_id uuid, p_amount_minor text,
                                                 p_payee_iban text, p_payee_name text, p_reason_code text,
                                                 p_expected_review_reason text, p_expected_left_minor text,
                                                 p_reason text)
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
  pos record;
  v_amount bigint;
  v_payer text;
  v_iban text;
  v_name text;
  v_e2e text;
  v_id uuid;
  v_fits boolean;
begin
  select * into p from public.payment where id = p_payment_id;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'amount_minor', p_amount_minor, 'payee_iban', p_payee_iban,
                                  'payee_name', p_payee_name, 'reason_code', p_reason_code,
                                  'expected_review_reason', p_expected_review_reason,
                                  'expected_left_minor', p_expected_left_minor, 'reason', v_reason);
  v_result := private.command_replay('request_refund', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if coalesce(p_amount_minor, '') !~ '^[0-9]{1,16}$' or p_amount_minor::bigint <= 0 then
    raise exception 'refund: invalid amount' using errcode = 'check_violation';
  end if;
  v_amount := p_amount_minor::bigint;
  -- file first, then the payment (ADR-0013 lock order)
  if p.account_id is not null then
    perform 1 from public.account a where a.id = p.account_id for key share;
  end if;
  select * into p from public.payment where id = p_payment_id for update;
  select * into pos from private.payment_positions(array[p.id]);
  if p.review_reason is distinct from p_expected_review_reason or p_expected_left_minor is distinct from pos.unallocated_minor::text then
    raise exception 'the payment changed: reload the page' using errcode = 'check_violation';
  end if;
  -- What is left and not waiting for allocation: unmatched, or held for a reason ops decide.
  if not (p.status = 'unmatched' or (p.status in ('matched', 'partially_allocated') and p.review_reason is not null)) then
    raise exception 'refund: this payment cannot be refunded from here' using errcode = 'check_violation';
  end if;
  if v_amount > pos.unallocated_minor then
    raise exception 'refund: more than what is left of the payment' using errcode = 'check_violation';
  end if;
  v_fits := case p_reason_code
      when 'overpayment' then p.review_reason in ('overpayment', 'nothing_due')
      when 'currency_mismatch' then p.review_reason = 'currency_mismatch'
      when 'no_mandate' then p.review_reason = 'no_mandate'
      when 'unidentified' then p.status = 'unmatched' and p.review_reason in ('no_match', 'ambiguous')
      when 'held_file' then p.review_reason = 'hold_blocks_allocation'
      when 'account_closed' then p.review_reason = 'account_closed'
      when 'partial_return' then p.review_reason = 'partial_return'
      when 'other' then true
      else false end;
  if not coalesce(v_fits, false) then
    raise exception 'refund: the reason does not match the payment''s state' using errcode = 'check_violation';
  end if;
  v_payer := nullif(private.rf_normalise(coalesce(p.payer_iban, '')), '');
  v_iban := coalesce(nullif(private.rf_normalise(coalesce(p_payee_iban, '')), ''), v_payer);
  if v_iban is null then
    raise exception 'refund: the payee''s IBAN is required (the bank gave none)' using errcode = 'check_violation';
  end if;
  if not private.iban_valid(v_iban) then
    raise exception 'refund: invalid IBAN' using errcode = 'check_violation';
  end if;
  v_name := coalesce(nullif(btrim(coalesce(p_payee_name, '')), ''), nullif(btrim(coalesce(p.payer_name, '')), ''));
  if v_name is null or length(v_name) > 140 then
    raise exception 'refund: the payee''s name is required' using errcode = 'check_violation';
  end if;
  v_e2e := 'RFD' || upper(substr(md5(gen_random_uuid()::text), 1, 12));
  insert into public.refund_request (organization_id, payment_id, bank_account_id, currency, amount_minor, payee_iban,
                                     payee_name, payee_is_payer, end_to_end_id, reason_code, reason, prior_status,
                                     prior_review_reason, requested_by)
  values (p.organization_id, p.id, p.bank_account_id, p.currency, v_amount, v_iban, v_name,
          v_iban is not distinct from v_payer, v_e2e, p_reason_code, v_reason, p.status, p.review_reason, auth.uid())
  returning id into v_id;
  update public.payment set status = 'refund_pending', review_reason = null, allocation_instruction = null where id = p.id;
  -- the debit may be on a statement already (ops executed the transfer before recording it)
  perform pgmq.send('payments', jsonb_build_object('type', 'process_debits', 'organization_id', p.organization_id));
  v_result := jsonb_build_object('refund_request_id', v_id, 'end_to_end_id', v_e2e, 'amount_minor', v_amount::text,
                                 'payee_iban_end', right(v_iban, 4));
  perform private.command_record('request_refund', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Annuler le remboursement »: a refund not executed yet (the transfer was not made, or the IBAN was wrong); the payment
-- goes back to the state it had when the refund was asked.
create or replace function public.cancel_refund(p_idempotency_key text, p_refund_request_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  q public.refund_request;
  p public.payment;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
begin
  select * into q from public.refund_request where id = p_refund_request_id;
  if not found or not private.has_role(q.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('refund_request_id', p_refund_request_id, 'reason', v_reason);
  v_result := private.command_replay('cancel_refund', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  select * into p from public.payment where id = q.payment_id;
  if p.account_id is not null then
    perform 1 from public.account a where a.id = p.account_id for key share;
  end if;
  select * into p from public.payment where id = q.payment_id for update;
  select * into q from public.refund_request where id = p_refund_request_id for update;
  if q.status <> 'requested' then
    raise exception 'refund: no longer pending: reload the page' using errcode = 'check_violation';
  end if;
  update public.refund_request set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(),
                                   cancel_reason = v_reason
  where id = q.id;
  update public.payment set status = q.prior_status, review_reason = q.prior_review_reason where id = p.id;
  v_result := jsonb_build_object('refund_request_id', q.id, 'payment_id', p.id, 'status', q.prior_status);
  perform private.command_record('cancel_refund', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Lier » a bank line ops looked at: the return of a payment (what is left of it as the page showed it: compare and
-- set; less than that is a partial return), our refund (its request), a refund that came back, or « expliqué » (not
-- booked: founder #20, the motif kept). Posted at once, as the job would.
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
  if p_kind is null or p_kind not in ('return', 'refund', 'refund_returned', 'explained') then
    raise exception 'debit link refused: bad_request' using errcode = 'check_violation';
  end if;
  if (p_kind = 'return') <> (p_expected_left_minor is not null)
     or (p_expected_left_minor is not null and p_expected_left_minor !~ '^[0-9]{1,16}$')
     or (p_kind = 'return') <> (p_payment_id is not null)
     or (p_kind in ('refund', 'refund_returned')) <> (p_refund_request_id is not null) then
    raise exception 'debit link refused: bad_request' using errcode = 'check_violation';
  end if;
  perform private.debit_link_begin();
  insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, refund_request_id, method, decided_by,
                                   reason, expected_left_minor)
  values (1, t.id, p_kind, p_payment_id, p_refund_request_id, 'ops', auth.uid(), v_reason, p_expected_left_minor::bigint);
  v_out := private.post_debit_links(t.organization_id, true);
  v_result := jsonb_build_object('bank_transaction_id', t.id, 'kind', p_kind, 'result', v_out);
  perform private.command_record('link_debit', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Libérer » / « Doublon confirmé » (design §8.3 step 5, ADR-0013 M2b-2 #5): a CSV line held as a suspected duplicate.
-- Released, it is what the parser read: a credit a debtor paid becomes a payment and a cash_in of its statement day
-- (I11 sums every cash_in of a statement day), then is matched; a debit or a return goes to the debit job. A duplicate
-- is never booked. Serialised with the imports of its bank account.
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
  s public.bank_statement;
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
    v_result := jsonb_build_object('bank_transaction_id', t.id, 'decision', 'duplicate');
  else
    select * into k from private.held_line_kind(t.id);
    insert into public.bank_duplicate_resolution (bank_transaction_id, organization_id, bank_account_id, decision,
                                                  released_kind, reason, decided_by)
    values (t.id, t.organization_id, t.bank_account_id, 'released', k.kind, v_reason, auth.uid());
    if k.kind in ('debtor_credit', 'batch_unsplit') then
      select * into s from public.bank_statement where id = t.statement_id;
      insert into public.payment (organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                                  currency, booking_date, value_date, payer_name, payer_iban, end_to_end_id,
                                  remittance_text, creditor_reference)
      values (t.organization_id, t.bank_account_id, t.id, s.format, k.method, t.amount_minor, t.currency, t.booking_date,
              t.value_date, coalesce(t.counterparty_name, t.ultimate_counterparty_name), t.counterparty_iban,
              t.end_to_end_id, t.remittance_text, t.creditor_reference)
      returning id into v_payment;
      perform private.ledger_post_set_begin();
      insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                      source_id)
      values (1, t.organization_id, 'cash_in', t.booking_date,
              'cash_in:' || t.statement_id || ':' || t.booking_date || ':' || t.id, 'bank_statement', t.statement_id::text);
      insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
        (1, 1, 'client_money_cash', t.amount_minor, t.currency, t.bank_account_id),
        (1, 2, 'unallocated_payment', -t.amount_minor, t.currency, null);
      perform private.ledger_post_set();
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
-- Payments the debtor made to the client directly (design §8.1, §9 record_direct_payment): the client's statement
-- (evidence filed on the file) says what was paid and which debts; the worker's waterfall splits it in the legal order
-- (the debts named first, interest first inside each: 1342-10, 1343-1) and an `adjustment` lowers the receivables
-- (−1100 per item and component / +3100). No client money moves; no receipt (we did not receive it: OQ-22) and no
-- notification (the client told us).
------------------------------------------------------------------------------------------

create table public.direct_payment (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null,
  portfolio_id uuid not null,
  account_id uuid not null,
  currency char(3) not null references public.currency (code),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  paid_on date not null,                                  -- the date the client's statement gives
  item_ids uuid[] not null default '{}',                  -- the debts the client names (designation), in no order
  evidence_document_id uuid not null references public.document (id),
  reason text not null check (length(btrim(reason)) between 1 and 2000),
  status text not null default 'requested' check (status in ('requested', 'posted', 'refused')),
  refusal_code text check (refusal_code in ('more_than_due', 'nothing_due', 'before_servicing_start', 'file_closed')),
  entry_id uuid unique references public.ledger_entry (id),
  requested_by uuid not null,
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint direct_payment_account_fk foreign key (account_id, organization_id, client_organization_id, portfolio_id)
    references public.account (id, organization_id, client_organization_id, portfolio_id),
  constraint direct_payment_posted check ((status = 'posted') = (entry_id is not null)),
  constraint direct_payment_refused check ((status = 'refused') = (refusal_code is not null)),
  constraint direct_payment_decided check ((status = 'requested') = (decided_at is null))
);
create index direct_payment_account_idx on public.direct_payment (account_id, requested_at desc);
create index direct_payment_waiting_idx on public.direct_payment (organization_id, requested_at) where status = 'requested';
comment on table public.direct_payment is
  'A payment the debtor made to the client directly (client''s statement as evidence): an adjustment of the receivables.';

create or replace function private.direct_payment_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'requested' then
      raise exception 'direct payment: it starts requested' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.client_organization_id, new.portfolio_id, new.account_id, new.currency,
      new.amount_minor, new.paid_on, new.item_ids, new.evidence_document_id, new.reason, new.requested_by,
      new.requested_at)
     is distinct from (old.id, old.organization_id, old.client_organization_id, old.portfolio_id, old.account_id,
                       old.currency, old.amount_minor, old.paid_on, old.item_ids, old.evidence_document_id, old.reason,
                       old.requested_by, old.requested_at)
     or old.status <> 'requested' or new.status = 'requested' then
    raise exception 'direct payment %: decided once, nothing else changes', old.id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger direct_payment_guard before insert or update on public.direct_payment
  for each row execute function private.direct_payment_guard();
alter table public.direct_payment enable always trigger direct_payment_guard;
create trigger direct_payment_no_delete before delete or truncate on public.direct_payment
  for each statement execute function private.refuse_delete();
alter table public.direct_payment enable always trigger direct_payment_no_delete;
create trigger direct_payment_touch before update on public.direct_payment
  for each row execute function private.touch_updated_at();
create trigger direct_payment_change_log after insert or update or delete on public.direct_payment
  for each row execute function private.log_change();

create or replace function public.record_direct_payment(p_idempotency_key text, p_account_id uuid, p_item_ids uuid[],
                                                        p_amount_minor text, p_paid_on date,
                                                        p_evidence_document_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  a public.account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_items uuid[];
  v_request jsonb;
  v_result jsonb;
  v_id uuid;
  v_start date;
begin
  select * into a from public.account where id = p_account_id;
  if not found or not private.has_role(a.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_items from unnest(coalesce(p_item_ids, '{}')) x;
  v_request := jsonb_build_object('account_id', p_account_id, 'item_ids', to_jsonb(v_items), 'amount_minor', p_amount_minor,
                                  'paid_on', p_paid_on, 'evidence_document_id', p_evidence_document_id,
                                  'reason', v_reason);
  v_result := private.command_replay('record_direct_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if coalesce(p_amount_minor, '') !~ '^[0-9]{1,16}$' or p_amount_minor::bigint <= 0 then
    raise exception 'direct payment: invalid amount' using errcode = 'check_violation';
  end if;
  select * into a from public.account where id = p_account_id for key share;
  if a.status = 'staged' or a.status like 'closed%' then
    raise exception 'direct payment: the file is not open' using errcode = 'check_violation';
  end if;
  select min(o.valid_from) into v_start from public.claim_ownership_period o where o.account_id = a.id;
  if p_paid_on is null or p_paid_on > private.paris_today() or v_start is null or p_paid_on < v_start then
    raise exception 'direct payment: the date is in the future or before the servicing started' using errcode = 'check_violation';
  end if;
  if (select count(*) from public.claim_item i where i.account_id = a.id and i.id = any (v_items)) <> cardinality(v_items) then
    raise exception 'direct payment: invoices of this file only' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null or not private.document_of_file(p_evidence_document_id, a.id) then
    raise exception 'direct payment: the client''s statement is required, filed on this file' using errcode = 'check_violation';
  end if;
  insert into public.direct_payment (organization_id, client_organization_id, portfolio_id, account_id, currency,
                                     amount_minor, paid_on, item_ids, evidence_document_id, reason, requested_by)
  values (a.organization_id, a.client_organization_id, a.portfolio_id, a.id, a.currency, p_amount_minor::bigint, p_paid_on,
          v_items, p_evidence_document_id, v_reason, auth.uid())
  returning id into v_id;
  perform pgmq.send('payments', jsonb_build_object('type', 'direct_payment', 'organization_id', a.organization_id,
                                                   'direct_payment_id', v_id));
  v_result := jsonb_build_object('direct_payment_id', v_id, 'queued', true);
  perform private.command_record('record_direct_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- The worker's plan (lines from the waterfall, Σ = the amount) posted as one adjustment under the allocation lock; the
-- ledger re-checks the receivables (I6, LG007). Or the plan's refusal.
create or replace function private.post_direct_payment(p_id uuid, p_lines jsonb, p_engine_version text,
                                                       p_inputs_hash text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.direct_payment;
  v_entry uuid;
  v_sum bigint;
begin
  select * into d from public.direct_payment where id = p_id for update;
  if not found or d.status <> 'requested' then
    return null;
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'direct payment %: no lines', p_id using errcode = '22023';
  end if;
  select sum((l ->> 'amount_minor')::bigint) into v_sum from jsonb_array_elements(p_lines) l;
  if v_sum is distinct from d.amount_minor
     or exists (select 1 from jsonb_array_elements(p_lines) l
                where (l ->> 'amount_minor')::bigint <= 0
                   or not exists (select 1 from public.claim_item i
                                  where i.id = (l ->> 'claim_item_id')::uuid and i.account_id = d.account_id)) then
    raise exception 'direct payment %: the lines do not add up to the amount on the file''s items', p_id using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('payments:' || d.organization_id::text));
  select x.entry_id into v_entry
  from private.ledger_post(
    d.organization_id, 'adjustment', d.paid_on, 'direct:' || d.id,
    (select jsonb_agg(z.v order by z.k) from (
       select 1 as k, jsonb_build_object('book', 'debtor_receivable', 'amount_minor', -(l ->> 'amount_minor')::bigint,
                                         'currency', d.currency, 'claim_item_id', l ->> 'claim_item_id',
                                         'component', l ->> 'component') as v
       from jsonb_array_elements(p_lines) l
       union all
       select 2, jsonb_build_object('book', 'owner_claim', 'amount_minor', sum((l ->> 'amount_minor')::bigint),
                                    'currency', d.currency, 'component', l ->> 'component')
       from jsonb_array_elements(p_lines) l group by l ->> 'component') z),
    jsonb_build_object('account_id', d.account_id, 'reason', 'Paiement direct au créancier (relevé du client)',
                       'source_type', 'direct_payment', 'source_id', d.id::text, 'engine_version', p_engine_version,
                       'inputs_hash', p_inputs_hash)) x;
  update public.direct_payment set status = 'posted', entry_id = v_entry, decided_at = now() where id = d.id;
  return v_entry;
end;
$$;

create or replace function private.refuse_direct_payment(p_id uuid, p_code text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.direct_payment set status = 'refused', refusal_code = p_code, decided_at = now()
  where id = p_id and status = 'requested';
$$;

------------------------------------------------------------------------------------------
-- Nightly checks (design §9 `invariants`, `suspense_ageing`): violations of the books' invariants and ageing alerts,
-- per servicer, written to a run and its results (the back-office « Contrôles »). Thresholds: money not allocated
-- 20 days after its booking (design §9; R124-6 « délai d'un mois », OQ-16, OQ-26), refunds 5 days, lines to classify
-- or duplicates to decide 3 days, a direct payment or a receipt not processed after an hour.
------------------------------------------------------------------------------------------

create table public.payment_check_run (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  violations integer,
  alerts integer,
  summary jsonb
);
create index payment_check_run_org_idx on public.payment_check_run (organization_id, started_at desc);
comment on table public.payment_check_run is 'One run of the nightly payments checks of a servicer (design §9).';

create table public.payment_check_result (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.payment_check_run (id),
  organization_id uuid not null references public.organization (id),
  code text not null,
  severity text not null check (severity in ('violation', 'alert')),
  subject_type text not null,
  subject_id uuid,
  currency char(3),
  amount_minor bigint,
  count integer,
  oldest_days integer,
  details jsonb not null default '{}'
);
create index payment_check_result_run_idx on public.payment_check_result (run_id);
comment on table public.payment_check_result is 'A violation of the payments invariants, or an ageing alert, found by a check run.';

create or replace function private.payment_check_result_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from new_rows n join public.payment_check_run r on r.id = n.run_id
             where r.organization_id <> n.organization_id or r.finished_at is not null) then
    raise exception 'payment check result: written by its own run, before it finishes' using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger payment_check_result_guard after insert on public.payment_check_result
  referencing new table as new_rows for each statement execute function private.payment_check_result_guard();
alter table public.payment_check_result enable always trigger payment_check_result_guard;
create trigger payment_check_result_append_only before update or delete or truncate on public.payment_check_result
  for each statement execute function private.refuse_change();
alter table public.payment_check_result enable always trigger payment_check_result_append_only;

create or replace function private.run_payment_checks(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
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

  -- Every payment's position from its tagged entries (one pass), and its pending refunds.
  drop table if exists pg_temp._chk_pos;
  create temp table _chk_pos on commit drop as
  select p.id, p.status, p.review_reason, p.account_id, p.amount_minor, p.currency, p.booking_date, p.bank_account_id,
         p.updated_at, coalesce(s.a, 0)::bigint as allocated, coalesce(s.r, 0)::bigint as returned,
         (p.amount_minor - coalesce(s.a, 0) - coalesce(s.r, 0))::bigint as unallocated,
         coalesce(q.pending, 0)::bigint as pending, coalesce(q.n, 0) as pending_n
  from public.payment p
  left join (select e.payment_id,
                    sum(lp.amount_minor) filter (where coalesce(t.entry_type, e.entry_type) in ('allocation', 'forward')) as a,
                    sum(lp.amount_minor) filter (where coalesce(t.entry_type, e.entry_type) = 'cash_out') as r
             from public.ledger_entry e
             left join public.ledger_entry t on t.id = e.reverses_entry_id
             join public.ledger_posting lp on lp.entry_id = e.id
             join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment'
             where e.organization_id = p_organization_id and e.payment_id is not null
             group by e.payment_id) s on s.payment_id = p.id
  left join (select q.payment_id, sum(q.amount_minor) as pending, count(*) as n from public.refund_request q
             where q.organization_id = p_organization_id and q.status = 'requested' group by q.payment_id) q
    on q.payment_id = p.id
  where p.organization_id = p_organization_id;
  create index on pg_temp._chk_pos (id);
  analyze pg_temp._chk_pos;

  -- I8: client money closed per currency (5120 + 4710 + 4670 = 0).
  insert into pg_temp._chk (code, severity, subject_type, currency, amount_minor, details)
  select 'client_money_identity', 'violation', 'servicer', x.currency, x.total,
         jsonb_build_object('cash_minor', x.cash::text, 'unallocated_minor', x.pool::text, 'owed_minor', x.owed::text)
  from (select la.currency, sum(lp.amount_minor) as total,
               sum(lp.amount_minor) filter (where la.book = 'client_money_cash') as cash,
               sum(lp.amount_minor) filter (where la.book = 'unallocated_payment') as pool,
               sum(lp.amount_minor) filter (where la.book = 'client_payable') as owed
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id
          and la.book in ('client_money_cash', 'unallocated_payment', 'client_payable')
        group by la.currency) x
  where x.total <> 0;

  -- Per bank account: its cash = what its payments brought in less what went back out = Σ unallocated + Σ allocated
  -- or forwarded (owed to the clients until remitted, M2c).
  insert into pg_temp._chk (code, severity, subject_type, subject_id, currency, amount_minor, details)
  select 'bank_cash_identity', 'violation', 'bank_account', coalesce(c.bank_account_id, y.bank_account_id), b.currency,
         coalesce(c.cash, 0) - coalesce(y.held, 0),
         jsonb_build_object('cash_minor', coalesce(c.cash, 0)::text, 'unallocated_minor', coalesce(y.unallocated, 0)::text,
                            'allocated_minor', coalesce(y.allocated, 0)::text)
  from (select la.bank_account_id, sum(lp.amount_minor) as cash
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'client_money_cash'
        group by la.bank_account_id) c
  full join (select x.bank_account_id, sum(x.amount_minor - x.returned) as held, sum(x.unallocated) as unallocated,
                    sum(x.allocated) as allocated
             from pg_temp._chk_pos x where x.bank_account_id is not null group by x.bank_account_id) y
    on y.bank_account_id = c.bank_account_id
  join public.bank_account b on b.id = coalesce(c.bank_account_id, y.bank_account_id)
  where coalesce(c.cash, 0) <> coalesce(y.held, 0);

  -- I11: the cash booked for a statement day = its payments (released duplicates included).
  insert into pg_temp._chk (code, severity, subject_type, subject_id, amount_minor, details)
  select 'cash_in_statement', 'violation', 'bank_statement', coalesce(ci.statement_id, pd.statement_id),
         coalesce(ci.total, 0) - coalesce(pd.total, 0),
         jsonb_build_object('date', coalesce(ci.d, pd.d), 'cash_in_minor', coalesce(ci.total, 0)::text,
                            'payments_minor', coalesce(pd.total, 0)::text)
  from (select e.source_id::uuid as statement_id, e.effective_date as d, sum(lp.amount_minor) as total
        from public.ledger_entry e
        join public.ledger_posting lp on lp.entry_id = e.id
        join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'client_money_cash'
        where e.organization_id = p_organization_id and e.entry_type = 'cash_in'
        group by e.source_id, e.effective_date) ci
  full join (select t.statement_id, p.booking_date as d, sum(p.amount_minor) as total
             from public.payment p join public.bank_transaction t on t.id = p.bank_transaction_id
             where p.organization_id = p_organization_id
             group by t.statement_id, p.booking_date) pd
    on pd.statement_id = ci.statement_id and pd.d = ci.d
  where coalesce(ci.total, 0) <> coalesce(pd.total, 0);

  -- I4, I5 and design §7: each payment's position against its status.
  insert into pg_temp._chk (code, severity, subject_type, subject_id, currency, amount_minor, oldest_days, details)
  select 'payment_position', 'violation', 'payment', c.id, c.currency, c.unallocated, v_today - c.booking_date,
         jsonb_build_object('status', c.status, 'allocated_minor', c.allocated::text,
                            'unallocated_minor', c.unallocated::text, 'returned_minor', c.returned::text,
                            'pending_refund_minor', c.pending::text)
  from pg_temp._chk_pos c
  where c.unallocated < 0 or c.allocated < 0 or c.returned < 0
     or (c.status = 'allocated' and not (c.allocated > 0 and c.unallocated = 0))
     or (c.status = 'partially_allocated' and not (c.allocated > 0 and c.unallocated > 0))
     or (c.status in ('unmatched', 'matched') and not (c.allocated = 0 and c.unallocated > 0))
     or (c.status = 'unmatched' and c.account_id is not null)
     or (c.status = 'refunded' and not (c.allocated = 0 and c.unallocated = 0 and c.returned = c.amount_minor))
     or (c.status = 'returned' and not (c.allocated = 0 and c.unallocated = 0))
     or ((c.status = 'refund_pending') <> (c.pending_n > 0))
     or c.pending > c.unallocated;
  -- the net allocated per (payment, file) is never negative
  insert into pg_temp._chk (code, severity, subject_type, subject_id, amount_minor, details)
  select 'payment_negative_allocation', 'violation', 'payment', x.payment_id, x.total,
         jsonb_build_object('account_id', x.account_id)
  from (select e.payment_id, e.account_id, sum(lp.amount_minor) as total
        from public.ledger_entry e
        left join public.ledger_entry t on t.id = e.reverses_entry_id
        join public.ledger_posting lp on lp.entry_id = e.id
        join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment'
        where e.organization_id = p_organization_id and e.payment_id is not null
          and coalesce(t.entry_type, e.entry_type) = 'allocation'
        group by e.payment_id, e.account_id) x
  where x.total < 0;

  -- I6: no receivable a payment (or a credit note, or a payment made to the client) lowered is below zero now; no item
  -- below zero as a whole once such an entry touched it.
  insert into pg_temp._chk (code, severity, subject_type, subject_id, currency, amount_minor, details)
  select 'receivable_negative', 'violation', 'claim_item', x.claim_item_id, x.currency, x.balance,
         jsonb_build_object('component', x.component)
  from (select la.claim_item_id, la.component, la.currency, sum(lp.amount_minor) as balance
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'debtor_receivable'
          and exists (select 1 from public.ledger_posting q join public.ledger_entry e on e.id = q.entry_id
                      where q.ledger_account_id = la.id and q.amount_minor < 0
                        and (e.entry_type in ('allocation', 'netting')
                             or (e.entry_type = 'adjustment' and e.source_type = 'direct_payment')))
        group by la.claim_item_id, la.component, la.currency) x
  where x.balance < 0
  union all
  select 'item_negative', 'violation', 'claim_item', y.claim_item_id, y.currency, y.balance, '{}'::jsonb
  from (select la.claim_item_id, la.currency, sum(lp.amount_minor) as balance
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'debtor_receivable'
          and la.claim_item_id in (
            select l2.claim_item_id from public.ledger_account l2
            join public.ledger_posting q on q.ledger_account_id = l2.id
            join public.ledger_entry e on e.id = q.entry_id
            where l2.organization_id = p_organization_id and l2.book = 'debtor_receivable' and q.amount_minor < 0
              and (e.entry_type = 'allocation' or (e.entry_type = 'adjustment' and e.source_type = 'direct_payment')))
        group by la.claim_item_id, la.currency) y
  where y.balance < 0;

  -- The owner-claim mirror (M2a risk #5): per portfolio, component and currency, 3100 = −Σ1100.
  insert into pg_temp._chk (code, severity, subject_type, subject_id, currency, amount_minor, details)
  select 'owner_claim_mirror', 'violation', 'portfolio', x.portfolio_id, x.currency, x.total,
         jsonb_build_object('component', x.component)
  from (select la.portfolio_id, la.component, la.currency, sum(lp.amount_minor) as total
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book in ('debtor_receivable', 'owner_claim')
        group by la.portfolio_id, la.component, la.currency) x
  where x.total <> 0;

  -- R124-6: one receipt number per payment on a file and a current version about its file (void once returned). A
  -- payment changed in the last hour may still be in the receipts queue.
  insert into pg_temp._chk (code, severity, subject_type, subject_id, oldest_days, details)
  select y.code, 'violation', 'payment', y.id, v_today - y.booking_date, jsonb_build_object('status', y.status)
  from (select c.id, c.booking_date, c.status,
               case when r.payment_id is null and c.status <> 'returned' then 'receipt_missing'
                    when r.numbers > 1 then 'receipt_numbers'
                    when c.status = 'returned' and r.payment_id is not null and cur.kind <> 'void' then 'receipt_not_void'
                    when c.status <> 'returned' and r.payment_id is not null
                         and (cur.kind = 'void' or cur.account_id is distinct from c.account_id) then 'receipt_stale'
               end as code
        from pg_temp._chk_pos c
        left join (select x.payment_id, count(distinct x.number) as numbers, max(x.version) as v
                   from public.receipt x where x.organization_id = p_organization_id group by x.payment_id) r
          on r.payment_id = c.id
        left join public.receipt cur on cur.payment_id = c.id and cur.version = r.v
        where c.account_id is not null and c.updated_at < now() - interval '1 hour'
          and not (c.status in ('matched', 'partially_allocated') and c.review_reason is null)) y
  where y.code is not null;

  -- R124-5: one notification per entry that moves what a client is owed, one per payment held for a file, one per
  -- return of a payment on a file.
  insert into pg_temp._chk (code, severity, subject_type, subject_id, details)
  select 'notification_missing', 'violation', 'ledger_entry', e.id,
         jsonb_build_object('entry_type', e.entry_type, 'payment_id', e.payment_id)
  from public.ledger_entry e
  left join public.ledger_entry t on t.id = e.reverses_entry_id
  where e.organization_id = p_organization_id and e.payment_id is not null
    and (e.entry_type in ('allocation', 'forward') or (e.entry_type = 'reversal' and t.entry_type in ('allocation', 'forward')))
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = e.id);
  insert into pg_temp._chk (code, severity, subject_type, subject_id, details)
  select 'notification_missing', 'violation', 'payment', c.id, jsonb_build_object('kind', 'payment_held')
  from pg_temp._chk_pos c
  where c.review_reason = 'hold_blocks_allocation' and c.account_id is not null
    and not exists (select 1 from public.client_notification n
                    where n.payment_id = c.id and n.account_id = c.account_id and n.kind = 'payment_held');
  insert into pg_temp._chk (code, severity, subject_type, subject_id, details)
  select 'notification_missing', 'violation', 'payment', l.payment_id, jsonb_build_object('kind', 'payment_returned')
  from public.bank_debit_link l
  join public.payment p on p.id = l.payment_id
  where l.organization_id = p_organization_id and l.kind = 'return' and p.account_id is not null
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = l.cash_entry_id);

  -- Statements (I9): a camt.053 statement whose opening is not the previous closing (« relevé manquant »), and each
  -- bank account's balance at its last statement against the ledger cash plus the lines not booked.
  insert into pg_temp._chk (code, severity, subject_type, subject_id, amount_minor, details)
  select 'statement_gap', 'alert', 'bank_statement', x.id, x.opening_booked_minor - x.prev_closing,
         jsonb_build_object('bank_account_id', x.bank_account_id, 'from_date', x.from_date, 'previous_to_date', x.prev_to)
  from (select s.id, s.bank_account_id, s.from_date, s.opening_booked_minor,
               lag(s.closing_booked_minor) over w as prev_closing, lag(s.to_date) over w as prev_to
        from public.bank_statement s
        where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
        window w as (partition by s.bank_account_id order by s.from_date, s.to_date, s.finished_at)) x
  where x.prev_closing is not null and x.prev_to < x.from_date and x.opening_booked_minor <> x.prev_closing;
  insert into pg_temp._chk (code, severity, subject_type, subject_id, currency, amount_minor, details)
  select 'bank_balance_gap', 'alert', 'bank_account', z.bank_account_id, z.currency,
         z.closing - z.cash - z.unposted,
         jsonb_build_object('as_of', z.to_date, 'closing_minor', z.closing::text, 'cash_minor', z.cash::text,
                            'unposted_minor', z.unposted::text, 'unposted_lines', z.unposted_lines)
  from (select l.bank_account_id, l.currency, l.to_date, l.closing_booked_minor as closing,
               coalesce((select sum(lp.amount_minor) from public.ledger_account la
                         join public.ledger_posting lp on lp.ledger_account_id = la.id and lp.effective_date <= l.to_date
                         where la.bank_account_id = l.bank_account_id and la.book = 'client_money_cash'), 0) as cash,
               u.minor as unposted, u.lines as unposted_lines
        from (select distinct on (s.bank_account_id) s.bank_account_id, s.currency, s.to_date, s.closing_booked_minor
              from public.bank_statement s
              where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
              order by s.bank_account_id, s.to_date desc, s.finished_at desc) l
        cross join lateral private.bank_unposted(l.bank_account_id, l.to_date) u) z
  where z.closing - z.cash - z.unposted <> 0;

  -- Ageing (alerts, one row per code with the oldest and up to 50 payments or lines).
  insert into pg_temp._chk (code, severity, subject_type, currency, amount_minor, count, oldest_days, details)
  select x.code, 'alert', 'servicer', x.currency, x.total, x.n, x.oldest, jsonb_build_object('ids', x.ids)
  from (select 'unmatched_ageing' as code, c.currency, sum(c.unallocated)::bigint as total, count(*)::integer as n,
               max(v_today - c.booking_date) as oldest,
               (array_agg(c.id order by c.booking_date, c.id))[1:50] as ids
        from pg_temp._chk_pos c
        where c.status = 'unmatched' and v_today - c.booking_date >= 20
        group by c.currency
        union all
        select 'unallocated_ageing', c.currency, sum(c.unallocated)::bigint, count(*)::integer,
               max(v_today - c.booking_date), (array_agg(c.id order by c.booking_date, c.id))[1:50]
        from pg_temp._chk_pos c
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
        select 'debit_unclassified', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from public.bank_transaction t
        left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
        where t.organization_id = p_organization_id and t.kind in ('return', 'refund_out', 'suspected_duplicate')
          and (t.kind <> 'suspected_duplicate' or r.released_kind in ('return', 'refund_out'))
          and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
          and v_today - t.booking_date >= 3
        group by t.currency
        union all
        select 'duplicate_unresolved', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from public.bank_transaction t
        where t.organization_id = p_organization_id and t.kind = 'suspected_duplicate'
          and not exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id)
          and v_today - t.booking_date >= 3
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
  select coalesce(jsonb_object_agg(x.code, x.n), '{}') into v_summary
  from (select c.code, count(*) as n from pg_temp._chk c group by c.code) x;
  select count(*) filter (where c.severity = 'violation'), count(*) filter (where c.severity = 'alert')
  into v_violations, v_alerts from pg_temp._chk c;
  update public.payment_check_run
  set finished_at = clock_timestamp(), violations = v_violations, alerts = v_alerts, summary = v_summary
  where id = v_run;
  return jsonb_build_object('run_id', v_run, 'violations', v_violations, 'alerts', v_alerts, 'by_code', v_summary);
end;
$$;

create or replace function private.queue_payment_checks()
returns integer
language sql
security definer
set search_path = ''
as $$
  with sent as (
    select pgmq.send('payments', jsonb_build_object('type', 'invariants', 'organization_id', o.id)) as msg_id
    from public.organization o
    where o.kind = 'servicer')
  select count(*)::integer from sent;
$$;

select cron.schedule('payments-invariants', '47 1 * * *', 'select private.queue_payment_checks()');

-- « Lancer les contrôles » (back-office): the same job now, for one servicer.
create or replace function public.request_payment_checks(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.has_role(p_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  perform pgmq.send('payments', jsonb_build_object('type', 'invariants', 'organization_id', p_organization_id));
  return jsonb_build_object('queued', true);
end;
$$;

------------------------------------------------------------------------------------------
-- « Imputer » after a partial return (redefined from 20261109190000: `partial_return` joins the reasons it sends to
-- allocation again; nothing else changes)
------------------------------------------------------------------------------------------

create or replace function public.allocate_payment(p_idempotency_key text, p_payment_id uuid, p_expected_reason text,
                                                   p_account_id uuid, p_evidence_document_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  p public.payment;
  src public.account;
  dst public.account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_instruction jsonb;
  v_left bigint;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'expected_reason', p_expected_reason,
                                  'account_id', p_account_id, 'evidence_document_id', p_evidence_document_id,
                                  'reason', v_reason);
  v_result := private.command_replay('allocate_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p.review_reason is distinct from p_expected_reason or p.account_id is null then
    raise exception 'the payment changed: reload the page' using errcode = 'check_violation';
  end if;
  select * into src from public.account where id = p.account_id;
  if p_account_id is null or p_account_id = p.account_id then
    if not ((p.status = 'matched'
             and p.review_reason in ('allocation_reversed', 'nothing_due', 'credit_note_to_apply', 'before_servicing_start',
                                     'partial_return'))
            or (p.status = 'partially_allocated' and p.review_reason = 'allocation_reversed')) then
      raise exception 'this payment cannot be sent to allocation from here' using errcode = 'check_violation';
    end if;
    v_instruction := private.instruction_release(p.allocation_instruction, p.review_reason,
                                                 jsonb_build_object('reason', v_reason, 'decided_by', auth.uid(),
                                                                    'decided_at', now()));
  else
    if not ((p.status = 'partially_allocated' and p.review_reason = 'overpayment')
            or (p.status = 'matched' and p.review_reason = 'nothing_due')) then
      raise exception 'only what is left of a payment over its file can go to another file' using errcode = 'check_violation';
    end if;
    select * into dst from public.account where id = p_account_id;
    if not found or dst.organization_id <> p.organization_id or dst.client_organization_id <> src.client_organization_id
       or dst.status = 'staged' or dst.status like 'closed%' or dst.currency <> p.currency then
      raise exception 'the other file must be an open file of the same client, in the payment''s currency'
        using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.account_party x join public.account_party y on y.party_id = x.party_id
                   where x.account_id = src.id and y.account_id = dst.id
                     and x.role in ('borrower', 'co_borrower') and y.role in ('borrower', 'co_borrower')) then
      raise exception 'the other file is not a file of the same debtor' using errcode = 'check_violation';
    end if;
    if p_evidence_document_id is null
       or not (private.document_of_file(p_evidence_document_id, src.id)
               or private.document_of_file(p_evidence_document_id, dst.id)) then
      raise exception 'the debtor''s written request is required, filed on one of the two files'
        using errcode = 'check_violation';
    end if;
    select unallocated_minor into v_left from private.payment_positions(array[p.id]);
    if v_left <= 0 then
      raise exception 'nothing is left of this payment' using errcode = 'check_violation';
    end if;
    v_instruction := jsonb_build_object(
      'releases', jsonb_build_array('overpayment'), 'account_id', dst.id,
      'decisions', jsonb_build_array(jsonb_build_object('release', 'overpayment', 'account_id', dst.id,
                                                        'evidence_document_id', p_evidence_document_id,
                                                        'reason', v_reason, 'decided_by', auth.uid(),
                                                        'decided_at', now())));
  end if;
  update public.payment set allocation_instruction = v_instruction, review_reason = null where id = p.id;
  v_result := jsonb_build_object('payment_id', p.id, 'account_id', coalesce(p_account_id, p.account_id),
                                 'queued', true);
  perform private.command_record('allocate_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The allocation's date after a partial return (redefined from 20261109190000; one change): an allocation is dated
-- greatest(booking date, servicing start, the latest date at which an allocation of the payment was reversed after its
-- own date). A bank return reverses the allocations at the return date (design §2 #3): what is left of the payment is
-- free again from then on only, so « Imputer » after a partial return allocates it from the return date (I4).
------------------------------------------------------------------------------------------

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
         or (t.holds > 0 and not (t.released ? 'hold_blocks_allocation')));
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
-- Reads for the back-office pages (money staff; bounded; amounts as text)
------------------------------------------------------------------------------------------

-- « Débits à classer » (design §12): lines to classify (returns, our refunds, credits undoing a debit, released
-- duplicates of those kinds) with what the job found; suspected duplicates to decide; lines decided (latest first);
-- fees and other debits (explained gaps, founder #20). One query per tab on a partial index led by the servicer.
create or replace function public.debit_queue(p_tab text default 'a-classer', p_offset integer default 0,
                                              p_limit integer default 20)
returns table (bank_transaction_id uuid, statement_id uuid, bank_account_id uuid, direction text, kind text,
               amount_minor text, currency char(3), booking_date date, age_days integer, counterparty_name text,
               counterparty_iban_end text, remittance_text text, end_to_end_id text, original_end_to_end_id text,
               return_reason text, review_reason text, candidates jsonb, decision text, decided_at timestamptz,
               decided_payment_id uuid, total bigint)
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
    select t.*, null::text as eff_kind from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.kind = 'suspected_duplicate'
      and not exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id);
  elsif p_tab = 'frais' then
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.kind = 'other_debit'
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id);
  elsif p_tab = 'traites' then
    -- from the decisions (a few per day), never from the servicer's lines
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind from public.bank_transaction t
    where t.id in (select l.bank_transaction_id from public.bank_debit_link l where l.organization_id = any (v_orgs)
                   union
                   select r.bank_transaction_id from public.bank_duplicate_resolution r
                   where r.organization_id = any (v_orgs)
                     and not (r.decision = 'released' and r.released_kind in ('return', 'refund_out')
                              and not exists (select 1 from public.bank_debit_link l
                                              where l.bank_transaction_id = r.bank_transaction_id)));
  else
    create temp table _dq on commit drop as
    select t.*, coalesce(r.released_kind, t.kind) as eff_kind from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = any (v_orgs) and t.kind in ('return', 'refund_out', 'suspected_duplicate')
      and (t.kind <> 'suspected_duplicate' or r.released_kind in ('return', 'refund_out'))
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id);
  end if;
  select count(*) into v_total from pg_temp._dq;
  return query
  select t.id, t.statement_id, t.bank_account_id, t.direction, coalesce(t.eff_kind, t.kind), t.amount_minor::text,
         t.currency, t.booking_date, (v_today - t.booking_date)::integer, t.counterparty_name, right(t.counterparty_iban, 4),
         t.remittance_text, t.end_to_end_id, t.original_end_to_end_id, t.return_reason, v.reason,
         coalesce((select jsonb_agg(c.v || coalesce(
                     (select jsonb_build_object('amount_minor', p.amount_minor::text, 'currency', p.currency,
                                                'booking_date', p.booking_date, 'payer_name', p.payer_name,
                                                'status', p.status, 'left_minor', (pos.amount_minor - pos.returned_minor)::text,
                                                'file_reference', a.external_ref)
                      from public.payment p
                      left join public.account a on a.id = p.account_id
                      cross join lateral private.payment_positions(array[p.id]) pos
                      where p.id = (c.v ->> 'payment_id')::uuid), '{}')
                   || coalesce((select jsonb_build_object('end_to_end_id', q.end_to_end_id, 'refund_status', q.status,
                                                          'refund_minor', q.amount_minor::text)
                                from public.refund_request q where q.id = (c.v ->> 'refund_request_id')::uuid), '{}')
                     order by c.ord)
                   from jsonb_array_elements(v.candidates) with ordinality c (v, ord)), '[]'::jsonb),
         coalesce(l.kind, case r.decision when 'duplicate' then 'duplicate'
                                           when 'released' then 'released' end),
         coalesce(l.decided_at, r.decided_at), l.payment_id, v_total
  from (select * from pg_temp._dq x
        order by (case when p_tab = 'traites' then x.created_at end) desc nulls last, x.booking_date, x.id
        offset v_offset limit v_limit) t
  left join public.bank_debit_review v on v.bank_transaction_id = t.id
  left join public.bank_debit_link l on l.bank_transaction_id = t.id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
  order by (case when p_tab = 'traites' then t.created_at end) desc nulls last, t.booking_date, t.id;
end;
$$;

-- What ops may link a line to when the job found nothing: payments of the same bank account booked on or before it,
-- not returned, with at least the line's amount left (the same amount first), and pending (or, for a credit, executed)
-- refunds of the same amount. At most 20 of each.
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
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id
    and organization_id = any (private.money_staff_org_ids());
  if not found then
    return null;
  end if;
  select coalesce(r.released_kind, t.kind) into v_kind
  from (select 1) x left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id;
  return jsonb_build_object(
    'payments', case when t.direction = 'debit' then coalesce((
      select jsonb_agg(jsonb_build_object('payment_id', y.id, 'amount_minor', y.amount_minor::text,
                                          'booking_date', y.booking_date, 'payer_name', y.payer_name, 'status', y.status,
                                          'left_minor', y.left_minor::text, 'file_reference', y.external_ref)
                       order by (y.left_minor = t.amount_minor) desc, y.booking_date desc, y.id)
      from (select p.id, p.amount_minor, p.booking_date, p.payer_name, p.status, a.external_ref,
                   pos.amount_minor - pos.returned_minor as left_minor
            from public.payment p
            left join public.account a on a.id = p.account_id
            cross join lateral private.payment_positions(array[p.id]) pos
            where p.bank_account_id = t.bank_account_id and p.booking_date <= t.booking_date
              and p.status <> 'returned' and p.amount_minor >= t.amount_minor
            order by (p.amount_minor = t.amount_minor) desc, p.booking_date desc, p.id
            limit 60) y
      where y.left_minor >= t.amount_minor
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
            order by q.requested_at desc limit 20) q), '[]'),
    'kind', v_kind);
end;
$$;

-- The payment page (redefined from 20261109190000): the same, plus what is left of the payment once returns and
-- refunds are counted (`left_minor`: compare and set of a return), its refund requests and the bank lines linked to it,
-- and whether the bank gave a usable IBAN for a refund.
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
                                           'forwarded_minor', (select coalesce(sum(lp.amount_minor), 0)
                                                               from public.ledger_entry e
                                                               left join public.ledger_entry t on t.id = e.reverses_entry_id
                                                               join public.ledger_posting lp on lp.entry_id = e.id
                                                               join public.ledger_account la on la.id = lp.ledger_account_id
                                                                 and la.book = 'unallocated_payment'
                                                               where e.payment_id = p.id
                                                                 and coalesce(t.entry_type, e.entry_type) = 'forward')::text)
                 from private.payment_positions(array[p.id]) x),
    'file', (select jsonb_build_object('account_id', a.id, 'external_ref', a.external_ref, 'status', a.status,
                                       'client_organization_id', a.client_organization_id, 'client_name', c.legal_name,
                                       'currency', a.currency, 'legal_regime', a.legal_regime,
                                       'debtor_name', (select min(pa.display_name) from public.account_party ap
                                                       join public.party pa on pa.id = ap.party_id
                                                       where ap.account_id = a.id and ap.role = 'borrower'),
                                       'holds', coalesce((select jsonb_agg(h.kind order by h.kind)
                                                          from public.account_hold h
                                                          where h.account_id = a.id and h.ended_at is null
                                                            and h.kind in ('surendettement', 'collective_proceeding')),
                                                         '[]'))
             from public.account a join public.organization c on c.id = a.client_organization_id
             where a.id = p.account_id),
    'matches', coalesce((select jsonb_agg(jsonb_build_object('action', m.action, 'account_id', m.account_id,
                                                             'external_ref', a.external_ref, 'method', m.method,
                                                             'rule', m.rule, 'trigger', m.trigger, 'reason', m.reason,
                                                             'review_reason', m.review_reason, 'decided_at', m.decided_at,
                                                             'by_ops', m.decided_by is not null)
                                          order by m.decided_at, m.id)
                         from public.payment_match m join public.account a on a.id = m.account_id
                         where m.payment_id = p.id), '[]'),
    'entries', coalesce((select jsonb_agg(jsonb_build_object(
                           'entry_id', e.id, 'entry_type', e.entry_type, 'effective_date', e.effective_date,
                           'posted_at', e.posted_at, 'reason', e.reason, 'account_id', e.account_id,
                           'ops_note', (select o.note from private.payment_ops_note o where o.entry_id = e.id),
                           'external_ref', (select a.external_ref from public.account a where a.id = e.account_id),
                           'reverses_entry_id', e.reverses_entry_id,
                           'reverses_type', (select t.entry_type from public.ledger_entry t where t.id = e.reverses_entry_id),
                           'reversed_by', (select r.id from public.ledger_entry r where r.reverses_entry_id = e.id),
                           'amount_minor', (select sum(lp.amount_minor) from public.ledger_posting lp
                                            join public.ledger_account la on la.id = lp.ledger_account_id
                                            where lp.entry_id = e.id and la.book = 'unallocated_payment')::text,
                           'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                                              'claim_item_id', la.claim_item_id, 'item_ref', i.ref, 'item_kind', i.kind,
                                              'due_date', i.due_date, 'component', la.component,
                                              'amount_minor', (-lp.amount_minor)::text)
                                            order by lp.line_no), '[]')
                                     from public.ledger_posting lp
                                     join public.ledger_account la on la.id = lp.ledger_account_id
                                     join public.claim_item i on i.id = la.claim_item_id
                                     where lp.entry_id = e.id and la.book = 'debtor_receivable'))
                         order by e.posted_at, e.id)
                         from public.ledger_entry e where e.payment_id = p.id), '[]'),
    'notifications', coalesce((select jsonb_agg(jsonb_build_object('kind', n.kind, 'created_at', n.created_at,
                                                                   'client_name', c.legal_name, 'reason', n.reason,
                                                                   'ledger_entry_id', n.ledger_entry_id,
                                                                   'delivered_at', n.delivered_at)
                                                order by n.created_at, n.id)
                               from public.client_notification n
                               join public.organization c on c.id = n.client_organization_id
                               where n.payment_id = p.id), '[]'),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object(
                           'id', q.id, 'amount_minor', q.amount_minor::text, 'payee_name', q.payee_name,
                           'payee_iban_end', right(q.payee_iban, 4), 'payee_is_payer', q.payee_is_payer,
                           'end_to_end_id', q.end_to_end_id, 'reason_code', q.reason_code, 'reason', q.reason,
                           'status', q.status, 'requested_at', q.requested_at, 'executed_on', q.executed_on,
                           'cancelled_at', q.cancelled_at, 'cancel_reason', q.cancel_reason)
                         order by q.requested_at, q.id)
                         from public.refund_request q where q.payment_id = p.id), '[]'),
    'bank_lines', coalesce((select jsonb_agg(jsonb_build_object(
                              'bank_transaction_id', l.bank_transaction_id, 'kind', l.kind, 'method', l.method,
                              'booking_date', t.booking_date, 'amount_minor', t.amount_minor::text,
                              'direction', t.direction, 'return_reason', t.return_reason,
                              'statement_id', t.statement_id, 'decided_at', l.decided_at, 'reason', l.reason)
                            order by t.booking_date, l.decided_at)
                            from public.bank_debit_link l join public.bank_transaction t on t.id = l.bank_transaction_id
                            where l.payment_id = p.id), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'created_at', d.created_at)
                                            order by d.created_at desc, d.id)
                           from public.document d where p.account_id is not null and d.account_id = p.account_id), '[]'),
    'other_files', coalesce((select jsonb_agg(jsonb_build_object('account_id', o.id, 'external_ref', o.external_ref)
                                              order by o.external_ref)
                             from public.account o
                             where p.account_id is not null and o.id <> p.account_id
                               and o.status not in ('staged', 'closed_paid', 'closed_settled', 'closed_uncollectable',
                                                    'closed_recalled')
                               and o.currency = p.currency
                               and exists (select 1 from public.account_party x
                                           join public.account_party y on y.party_id = x.party_id
                                           where x.account_id = p.account_id and y.account_id = o.id
                                             and x.role in ('borrower', 'co_borrower')
                                             and y.role in ('borrower', 'co_borrower'))), '[]')
  ) into v;
  return v;
end;
$$;

-- The file page (redefined from 20261109190000): the same, plus the payments the debtor made to the client directly.
create or replace function public.account_detail(p_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.account;
  v jsonb;
  v_money boolean;
  v_readable uuid[];
begin
  select * into a from public.account where id = p_account_id;
  if not found or not (a.organization_id = any (private.staff_org_ids())) or not private.can_read_portfolio(a.portfolio_id) then
    return null;
  end if;
  v_money := a.organization_id = any (private.money_staff_org_ids());
  v_readable := case when v_money then '{}'::uuid[] else private.readable_portfolio_ids() end;
  select jsonb_build_object(
    'account', jsonb_build_object('id', a.id, 'external_ref', a.external_ref, 'status', a.status, 'currency', a.currency,
                                  'legal_regime', a.legal_regime, 'claim_type', a.claim_type_code,
                                  'client_name', (select o.legal_name from public.organization o
                                                  where o.id = a.client_organization_id),
                                  'portfolio_name', (select x.name from public.portfolio x where x.id = a.portfolio_id),
                                  'servicing_start', (select min(o.valid_from) from public.claim_ownership_period o
                                                      where o.account_id = a.id)),
    'can_act', v_money,
    'parties', coalesce((select jsonb_agg(jsonb_build_object('name', pa.display_name, 'role', ap.role)
                                          order by ap.role, pa.display_name)
                         from public.account_party ap join public.party pa on pa.id = ap.party_id
                         where ap.account_id = a.id), '[]'),
    'rf', (select r.rf from public.payment_reference r where r.account_id = a.id and r.status = 'active'),
    'balances', coalesce((select jsonb_agg(jsonb_build_object('claim_item_id', i.id, 'item_ref', i.ref, 'kind', i.kind,
                                                              'due_date', i.due_date, 'component', b.component,
                                                              'balance_minor', b.balance_minor::text)
                                           order by i.due_date nulls last, i.ref, c.sort_order)
                          from private.account_balances(a.id, private.paris_today(), null) b
                          join public.claim_item i on i.id = b.claim_item_id
                          join public.ledger_component c on c.code = b.component), '[]'),
    'holds', coalesce((select jsonb_agg(jsonb_build_object('kind', h.kind, 'started_at', h.started_at,
                                                           'legal_basis', h.legal_basis, 'reason', h.reason)
                                        order by h.started_at)
                       from public.account_hold h where h.account_id = a.id and h.ended_at is null), '[]'),
    'payments', coalesce((select jsonb_agg(x.j order by x.booking_date desc, x.id) from (
                            select p.id, p.booking_date,
                                   jsonb_build_object('id', p.id, 'amount_minor', p.amount_minor::text,
                                                      'currency', p.currency, 'booking_date', p.booking_date,
                                                      'status', p.status, 'review_reason', p.review_reason,
                                                      'payer_name', p.payer_name,
                                                      'forwarded', exists (select 1 from public.ledger_entry f
                                                                           where f.payment_id = p.id
                                                                             and f.entry_type = 'forward')) as j
                            from (select y.id from public.payment y where y.account_id = a.id
                                  union
                                  select e.payment_id from public.ledger_entry e
                                  where e.account_id = a.id and e.payment_id is not null) ids
                            join public.payment p on p.id = ids.id
                            where v_money or p.portfolio_id = any (v_readable)
                            order by p.booking_date desc, p.id limit 50) x), '[]'),
    'direct_payments', coalesce((select jsonb_agg(jsonb_build_object(
                                   'id', d.id, 'amount_minor', d.amount_minor::text, 'currency', d.currency,
                                   'paid_on', d.paid_on, 'status', d.status, 'refusal_code', d.refusal_code,
                                   'requested_at', d.requested_at, 'reason', case when v_money then d.reason end,
                                   'items', (select coalesce(jsonb_agg(i.ref order by i.ref), '[]')
                                             from public.claim_item i where i.id = any (d.item_ids)),
                                   'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                                                      'item_ref', i.ref, 'component', la.component,
                                                      'amount_minor', (-lp.amount_minor)::text) order by lp.line_no), '[]')
                                             from public.ledger_posting lp
                                             join public.ledger_account la on la.id = lp.ledger_account_id
                                             join public.claim_item i on i.id = la.claim_item_id
                                             where lp.entry_id = d.entry_id and la.book = 'debtor_receivable'))
                                 order by d.requested_at desc, d.id)
                                 from public.direct_payment d where d.account_id = a.id), '[]'),
    'documents', case when v_money then coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind,
                                                                                      'created_at', d.created_at)
                                                                   order by d.created_at desc, d.id)
                                                  from public.document d where d.account_id = a.id
                                                    and d.kind <> 'receipt'), '[]') end,
    'proposal', case when v_money then (
                  select jsonb_build_object(
                    'credit_item_id', min(c.credit_item_id::text), 'credit_ref', min(ci.ref),
                    'netting_date', min(c.netting_date), 'proposal_key', min(c.proposal_key),
                    'amount_minor', sum(c.amount_minor)::text,
                    'targets', jsonb_agg(jsonb_build_object('item_id', c.target_item_id, 'item_ref', ti.ref,
                                                            'amount_minor', c.amount_minor::text)
                                         order by ti.ref))
                  from private.credit_note_proposals(array[a.id]) c
                  join public.claim_item ci on ci.id = c.credit_item_id
                  join public.claim_item ti on ti.id = c.target_item_id
                  having count(*) > 0) end
  ) into v;
  return v;
end;
$$;

-- The client payment feed (redefined from 20261110090000): a return row's amount is what the bank took back (its
-- cash_out), never the client's 4670; everything else unchanged.
create or replace function public.client_payment_feed(p_client uuid, p_after text default null,
                                                      p_limit integer default 50)
returns table (notification_id uuid, cursor text, created_at timestamptz, kind text, reason text, account_id uuid,
               file_reference text, debtor_name text, amount_minor text, currency char(3), booking_date date,
               effective_date date, lines jsonb, receipt_id uuid, receipt_number text, receipt_version integer,
               receipt_kind text, delivered_at timestamptz, first_view boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_member boolean := p_client = any (private.client_org_ids());
  v_staff boolean := false;
  v_readable uuid[] := '{}';
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_at timestamptz;
  v_id uuid;
begin
  select coalesce(o.servicer_organization_id = any (private.money_staff_org_ids()), false) into v_staff
  from public.organization o where o.id = p_client;
  if not (v_member or coalesce(v_staff, false)) then
    raise exception 'client payment feed: not allowed' using errcode = '42501';
  end if;
  if v_member then
    v_readable := private.readable_portfolio_ids();
  end if;
  if p_after is not null then
    begin
      v_at := split_part(p_after, '|', 1)::timestamptz;
      v_id := split_part(p_after, '|', 2)::uuid;
    exception when others then
      raise exception 'client payment feed: unreadable cursor' using errcode = '22023';
    end;
  end if;
  return query
  with page as (
    select n.id, n.created_at, n.kind, n.reason, n.account_id, n.payment_id, n.ledger_entry_id, n.delivered_at
    from public.client_notification n
    where n.client_organization_id = p_client
      and (coalesce(v_staff, false) or n.portfolio_id is null or n.portfolio_id = any (v_readable))
      and (p_after is null or (n.created_at, n.id) < (v_at, v_id))
    order by n.created_at desc, n.id desc
    limit v_limit
  ), marked as (
    update public.client_notification c set delivered_at = now()
    from page
    where c.id = page.id and v_member and c.delivered_at is null
    returning c.id, c.delivered_at
  )
  select page.id,
         to_char(page.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || '|' || page.id,
         page.created_at, page.kind, page.reason, page.account_id, a.external_ref,
         (select min(pa.display_name) from public.account_party ap join public.party pa on pa.id = ap.party_id
          where ap.account_id = page.account_id and ap.role = 'borrower'),
         coalesce(e.amount, e.cash, p.amount_minor)::text, p.currency, p.booking_date, le.effective_date,
         coalesce(l.lines, '[]'::jsonb), r.id, r.number, r.version, r.kind,
         coalesce(m.delivered_at, page.delivered_at), m.id is not null
  from page
  left join marked m on m.id = page.id
  join public.payment p on p.id = page.payment_id
  left join public.account a on a.id = page.account_id
  left join public.ledger_entry le on le.id = page.ledger_entry_id
  left join lateral (select abs(sum(lp.amount_minor) filter (where la.book = 'client_payable'))::bigint as amount,
                            abs(sum(lp.amount_minor) filter (where la.book = 'client_money_cash'))::bigint as cash
                     from public.ledger_posting lp
                     join public.ledger_account la on la.id = lp.ledger_account_id
                       and la.book in ('client_payable', 'client_money_cash')
                     where lp.entry_id = page.ledger_entry_id) e on page.ledger_entry_id is not null
  left join lateral (select jsonb_agg(jsonb_build_object('item_ref', i.ref, 'item_kind', i.kind,
                                                         'due_date', i.due_date, 'component', la.component,
                                                         'amount_minor', abs(lp.amount_minor)::text)
                                      order by lp.line_no) as lines
                     from public.ledger_posting lp
                     join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'debtor_receivable'
                     join public.claim_item i on i.id = la.claim_item_id
                     where lp.entry_id = page.ledger_entry_id) l on page.ledger_entry_id is not null
  left join lateral (select x.id, x.number, x.version, x.kind from public.receipt x
                     where x.payment_id = page.payment_id and x.client_organization_id = p_client
                       and (coalesce(v_staff, false) or x.portfolio_id = any (v_readable))
                     order by (x.account_id is not distinct from page.account_id) desc, x.version desc
                     limit 1) r on true
  order by page.created_at desc, page.id desc;
end;
$$;

------------------------------------------------------------------------------------------
-- Read access (founder #18): bank lines, refunds and their decisions are third-party payer data (admins and ops
-- managers); direct payments by money staff and the staff who read the portfolio; check runs by money staff.
------------------------------------------------------------------------------------------

alter table public.refund_request enable row level security;
alter table public.bank_debit_link enable row level security;
alter table public.bank_debit_review enable row level security;
alter table public.bank_duplicate_resolution enable row level security;
alter table private.bank_line_held_kind enable row level security;
alter table public.direct_payment enable row level security;
alter table public.payment_check_run enable row level security;
alter table public.payment_check_result enable row level security;
revoke all on public.refund_request, public.bank_debit_link, public.bank_debit_review, public.bank_duplicate_resolution,
  public.direct_payment, public.payment_check_run, public.payment_check_result from public, anon, authenticated;
revoke all on private.bank_line_held_kind from public, anon, authenticated;
grant select on public.refund_request, public.bank_debit_link, public.bank_debit_review, public.bank_duplicate_resolution,
  public.direct_payment, public.payment_check_run, public.payment_check_result to authenticated;

create policy refund_request_read on public.refund_request for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy bank_debit_link_read on public.bank_debit_link for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy bank_debit_review_read on public.bank_debit_review for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy bank_duplicate_resolution_read on public.bank_duplicate_resolution for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy direct_payment_read on public.direct_payment for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or (organization_id = any ((select private.staff_org_ids())::uuid[])
      and portfolio_id = any ((select private.readable_portfolio_ids())::uuid[])));
create policy payment_check_run_read on public.payment_check_run for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy payment_check_result_read on public.payment_check_result for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));

------------------------------------------------------------------------------------------
-- Statement triggers that join their two transition tables (new_rows ⋈ old_rows on the payment) cache the plan of the
-- session's first, small update; a nested loop reused for a 50k-row update compares every pair (the 50k match apply
-- took minutes instead of seconds). No nested loop there, whatever the first update was (the same setting as the M2b-5
-- review fix of these two functions; idempotent).
------------------------------------------------------------------------------------------

alter function private.payment_after_update() set enable_nestloop = off;
alter function private.receipts_after_payment() set enable_nestloop = off;

------------------------------------------------------------------------------------------
-- Privileges
------------------------------------------------------------------------------------------

revoke execute on function private.refund_request_guard(), private.payment_money_out_guard(),
  private.bank_debit_link_guard(), private.bank_duplicate_resolution_guard(), private.bank_transaction_held_kind(),
  private.held_line_kind(uuid), private.debit_link_begin(), private.post_debit_links(uuid, boolean),
  private.debit_candidates(uuid, date, uuid, integer), private.apply_debit_decisions(uuid),
  private.direct_payment_guard(), private.post_direct_payment(uuid, jsonb, text, text),
  private.refuse_direct_payment(uuid, text), private.payment_check_result_guard(), private.run_payment_checks(uuid),
  private.queue_payment_checks()
  from public, anon, authenticated, service_role;
-- The worker (service_role) runs the debit, direct-payment and checks jobs.
grant execute on function private.debit_link_begin(), private.debit_candidates(uuid, date, uuid, integer),
  private.apply_debit_decisions(uuid), private.post_direct_payment(uuid, jsonb, text, text),
  private.refuse_direct_payment(uuid, text), private.run_payment_checks(uuid)
  to service_role;
revoke execute on function public.request_refund(text, uuid, text, text, text, text, text, text, text),
  public.cancel_refund(text, uuid, text), public.link_debit(text, uuid, text, uuid, uuid, text, text),
  public.resolve_duplicate(text, uuid, boolean, text),
  public.record_direct_payment(text, uuid, uuid[], text, date, uuid, text),
  public.request_payment_checks(uuid), public.debit_queue(text, integer, integer), public.debit_link_options(uuid)
  from public, anon;
grant execute on function public.request_refund(text, uuid, text, text, text, text, text, text, text),
  public.cancel_refund(text, uuid, text), public.link_debit(text, uuid, text, uuid, uuid, text, text),
  public.resolve_duplicate(text, uuid, boolean, text),
  public.record_direct_payment(text, uuid, uuid[], text, date, uuid, text),
  public.request_payment_checks(uuid), public.debit_queue(text, integer, integer), public.debit_link_options(uuid)
  to authenticated;

------------------------------------------------------------------------------------------
-- Lines held before this migration: their reading from their facts (see private.held_line_kind); returns and refunds
-- already on statements: one debit job per servicer.
------------------------------------------------------------------------------------------

insert into private.bank_line_held_kind (bank_transaction_id, kind, method)
select t.id, k.kind, k.method
from public.bank_transaction t cross join lateral private.held_line_kind(t.id) k
where t.kind = 'suspected_duplicate'
on conflict (bank_transaction_id) do nothing;

select pgmq.send('payments', jsonb_build_object('type', 'process_debits', 'organization_id', x.organization_id))
from (select distinct t.organization_id from public.bank_transaction t where t.kind in ('return', 'refund_out')) x;
