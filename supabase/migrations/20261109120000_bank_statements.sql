-- M2b-2 (M2-07): bank statements, statement lines, the import and the cash_in of each statement day.
-- Design: docs/design/m2b-payments.md §6–§9, §12; decisions: docs/adr/0013-payments-allocation-client-money.md
-- (M2b-2 addendum). Forward-only: nothing of 20261109090000 is edited; payment gains the key to its bank line.
--
-- What changes for money:
--   * every credit line of a client_funds statement that a debtor paid becomes a `payment` row, and each
--     statement day is booked at once: one cash_in per (statement, booking date), Dr 5120[bank account] /
--     Cr 4710[pool] (founder decision #1, design §2 #1);
--   * a payment IS the bank line it comes from: same servicer, bank account, currency, amount and booking
--     date (composite foreign key), so I11 (cash_in of a statement day = Σ its payments) is checkable from
--     the tables;
--   * lines are deduplicated per bank account: importing a file twice, or an overlapping statement, creates
--     nothing new, and a known bank reference reported with other facts refuses the file (never skipped);
--   * debits, returns and lines held for ops are recorded, not booked (M2b-6, decision #20); the gap they
--     leave between the ledger cash and the bank's closing balance is shown with its lines (I9).

create extension if not exists pg_trgm with schema extensions;

------------------------------------------------------------------------------------------
-- Statements: one row per uploaded file
------------------------------------------------------------------------------------------

create table public.bank_statement (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  bank_account_id uuid not null,
  currency char(3) not null,
  format text not null check (format in ('camt053', 'csv')),
  file_name text not null check (length(file_name) between 1 and 255 and file_name !~ '[/\\[:cntrl:]]'),
  file_sha256 text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes bigint not null check (size_bytes between 1 and 524288000),
  storage_bucket text not null default 'bank-statements' check (storage_bucket = 'bank-statements'),
  storage_path text not null unique,
  -- awaiting_upload -> uploaded (file stored, import queued) -> imported | rejected | failed.
  -- The import is one transaction (exactly once), so "importing" is never a stored state.
  status text not null default 'awaiting_upload'
    check (status in ('awaiting_upload', 'uploaded', 'imported', 'rejected', 'failed')),
  -- What the file says (camt.053: id and sequence of the first <Stmt>, opening of the first and closing of
  -- the last; every <Stmt> in `sections`). Amounts in jsonb are text (no JS number for money).
  format_version text check (format_version ~ '^[0-9]{2}$'),            -- camt.053.001.<xx>
  stmt_id text check (length(stmt_id) <= 140),
  electronic_seq_no bigint,
  from_date date,
  to_date date,
  opening_booked_minor bigint,
  closing_booked_minor bigint,
  sections jsonb check (sections is null or jsonb_typeof(sections) = 'array'),
  counts jsonb check (counts is null or jsonb_typeof(counts) = 'object'),
  warnings jsonb not null default '[]' check (jsonb_typeof(warnings) = 'array'),
  bank_check jsonb check (bank_check is null or jsonb_typeof(bank_check) = 'object'),  -- I9 at import
  error_code text check (error_code ~ '^[a-z0-9_]{1,64}$'),
  error text check (length(error) <= 2000),
  created_by uuid references public.app_user (id),
  idempotency_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  uploaded_at timestamptz,
  finished_at timestamptz,
  constraint bank_statement_bank_fk foreign key (bank_account_id, organization_id, currency)
    references public.bank_account (id, organization_id, currency),
  constraint bank_statement_line_key unique (id, organization_id, bank_account_id, currency),
  constraint bank_statement_dates check (to_date >= from_date),
  constraint bank_statement_outcome check ((status in ('rejected', 'failed')) = (error_code is not null)
                                           and (status = 'imported') = (counts is not null)
                                           and (status in ('imported', 'rejected', 'failed')) = (finished_at is not null)
                                           and (status = 'awaiting_upload') = (uploaded_at is null))
);
-- The same file for the same bank account is one statement (a rejected or failed one can be sent again).
create unique index bank_statement_file_uq on public.bank_statement (bank_account_id, file_sha256)
  where status not in ('rejected', 'failed');
create index bank_statement_org_idx on public.bank_statement (organization_id, created_at desc);
-- A file is the statement of one bank account of the servicer (the upload and the import check it).
create index bank_statement_file_org_idx on public.bank_statement (organization_id, file_sha256);
create index bank_statement_account_idx on public.bank_statement (bank_account_id, created_at desc);
create index bank_statement_continuity_idx on public.bank_statement (bank_account_id, to_date) where status = 'imported';
comment on table public.bank_statement is
  'Bank statement files (camt.053 or CSV) of a client_funds account, and the outcome of their import.';

-- Identity and file are fixed; the status only moves forward; a finished statement never changes.
create or replace function private.bank_statement_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'awaiting_upload' or new.counts is not null or new.error_code is not null
       or new.sections is not null or new.uploaded_at is not null or new.finished_at is not null then
      raise exception 'bank statement: a new statement waits for its file' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.bank_account b
                   where b.id = new.bank_account_id and b.status = 'active' and b.purpose = 'client_funds') then
      raise exception 'bank statement: the bank account is not an active client_funds account (R124-2)'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.bank_account_id, new.currency, new.format, new.file_name, new.file_sha256,
      new.size_bytes, new.storage_bucket, new.storage_path, new.created_by, new.idempotency_key, new.created_at)
     is distinct from
     (old.id, old.organization_id, old.bank_account_id, old.currency, old.format, old.file_name, old.file_sha256,
      old.size_bytes, old.storage_bucket, old.storage_path, old.created_by, old.idempotency_key, old.created_at) then
    raise exception 'bank statement %: its bank account and file are fixed', old.id using errcode = 'check_violation';
  end if;
  if (old.status, new.status) not in (('awaiting_upload', 'uploaded'), ('uploaded', 'imported'),
                                      ('uploaded', 'rejected'), ('uploaded', 'failed')) then
    raise exception 'bank statement %: % -> % is not allowed (a finished statement never changes)',
      old.id, old.status, new.status using errcode = 'check_violation';
  end if;
  if old.status = 'awaiting_upload'
     and (new.format_version, new.stmt_id, new.electronic_seq_no, new.from_date, new.to_date, new.opening_booked_minor,
          new.closing_booked_minor, new.sections, new.counts, new.warnings, new.bank_check, new.error_code, new.error,
          new.finished_at) is distinct from
         (old.format_version, old.stmt_id, old.electronic_seq_no, old.from_date, old.to_date, old.opening_booked_minor,
          old.closing_booked_minor, old.sections, old.counts, old.warnings, old.bank_check, old.error_code, old.error,
          old.finished_at) then
    raise exception 'bank statement %: nothing is known of the file before its import', old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger bank_statement_guard before insert or update on public.bank_statement
  for each row execute function private.bank_statement_guard();
alter table public.bank_statement enable always trigger bank_statement_guard;
create trigger bank_statement_no_delete before delete or truncate on public.bank_statement
  for each statement execute function private.refuse_delete();
alter table public.bank_statement enable always trigger bank_statement_no_delete;
create trigger bank_statement_touch before update on public.bank_statement
  for each row execute function private.touch_updated_at();
create trigger bank_statement_change_log after insert or update or delete on public.bank_statement
  for each row execute function private.log_change();

------------------------------------------------------------------------------------------
-- Statement lines: facts as the bank reported them (append-only, deduplicated per bank account)
------------------------------------------------------------------------------------------

create table public.bank_transaction (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  bank_account_id uuid not null,
  statement_id uuid not null,
  line_no integer not null check (line_no > 0),                -- position in its file
  -- t:<TxDtls AcctSvcrRef> | e:<Ntry AcctSvcrRef>#<n> | c:<bank id column> | h:<sha256 of the facts>#<n>
  dedup_key text not null check (dedup_key ~ '^[tech]:' and length(dedup_key) <= 300),
  direction text not null check (direction in ('credit', 'debit')),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  currency char(3) not null,
  booking_date date not null,
  value_date date,
  reversal_indicator boolean not null default false,
  bank_tx_code text,
  acct_svcr_ref text,
  end_to_end_id text,
  tx_id text,
  mandate_ref text,
  counterparty_name text,
  ultimate_counterparty_name text,
  counterparty_iban text,
  remittance_text text,
  creditor_reference text,
  return_reason text,
  original_end_to_end_id text,
  batch_entry_ref text,
  -- camt.053: the reference of the bank entry (Ntry/AcctSvcrRef) the line comes from, whatever its key
  entry_ref text check (length(entry_ref) between 1 and 300),
  -- debtor_credit: a debtor's payment (booked at import); batch_unsplit: a batch booking whose details do
  -- not add up (a credit is still one payment, booked, that ops split across files); return: the bank undoes
  -- an earlier movement (either direction); refund_out: our refund (end-to-end id RFD…); other_debit: fees
  -- and the like (not booked in M2b, decision #20); suspected_duplicate: a CSV line that looks like one
  -- already imported (held for ops: no payment, no cash); psp_payout: M5.
  kind text not null check (kind in ('debtor_credit', 'return', 'refund_out', 'psp_payout', 'other_debit',
                                     'batch_unsplit', 'suspected_duplicate')),
  created_at timestamptz not null default now(),
  constraint bank_transaction_statement_fk foreign key (statement_id, organization_id, bank_account_id, currency)
    references public.bank_statement (id, organization_id, bank_account_id, currency),
  constraint bank_transaction_dedup_uq unique (bank_account_id, dedup_key),
  constraint bank_transaction_line_uq unique (statement_id, line_no),
  -- what a payment copies from its line (payment_bank_transaction_fk)
  constraint bank_transaction_payment_key unique (id, organization_id, bank_account_id, currency, amount_minor, booking_date),
  constraint bank_transaction_kind check (case direction
    when 'credit' then kind in ('debtor_credit', 'return', 'psp_payout', 'batch_unsplit', 'suspected_duplicate')
    else kind in ('return', 'refund_out', 'other_debit', 'batch_unsplit', 'suspected_duplicate') end)
);
create index bank_transaction_same_day_idx on public.bank_transaction (bank_account_id, booking_date, amount_minor);
create index bank_transaction_org_idx on public.bank_transaction (organization_id);
create index bank_transaction_e2e_idx on public.bank_transaction (original_end_to_end_id) where original_end_to_end_id is not null;
-- The lines of one bank entry, whatever their keys (a camt.053 entry is booked once at one level of detail).
create index bank_transaction_entry_idx on public.bank_transaction (bank_account_id, entry_ref) where entry_ref is not null;
-- Lines that are not in the ledger in M2b-2 (I9), read without touching the payment lines.
create index bank_transaction_unposted_idx on public.bank_transaction (bank_account_id, booking_date)
  where not (direction = 'credit' and kind in ('debtor_credit', 'batch_unsplit'));
comment on table public.bank_transaction is
  'Bank statement lines (append-only facts). One row per line, deduplicated per bank account by dedup_key.';

-- Facts: never changed, never deleted.
create or replace function private.refuse_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% on % refused: these rows are facts (append-only)', tg_op, tg_table_name
    using errcode = 'check_violation';
end;
$$;
create trigger bank_transaction_append_only before update or delete or truncate on public.bank_transaction
  for each statement execute function private.refuse_change();
alter table public.bank_transaction enable always trigger bank_transaction_append_only;

-- Lines are added only to a statement being imported (aggregate over the new rows, not LIMIT 1).
create or replace function private.bank_transaction_insert_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(n.statement_id::text) into v_bad
  from (select distinct statement_id from new_rows) n
  join public.bank_statement s on s.id = n.statement_id
  where s.status <> 'uploaded';
  if v_bad is not null then
    raise exception 'bank lines: statement % is not being imported', v_bad using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger bank_transaction_insert_guard after insert on public.bank_transaction
  referencing new table as new_rows for each statement execute function private.bank_transaction_insert_guard();
alter table public.bank_transaction enable always trigger bank_transaction_insert_guard;

------------------------------------------------------------------------------------------
-- A payment is the bank line it comes from (ADR-0013 choice #3: the key arrives with the lines)
------------------------------------------------------------------------------------------

alter table public.payment
  add constraint payment_bank_transaction_fk
    foreign key (bank_transaction_id, organization_id, bank_account_id, currency, amount_minor, booking_date)
    references public.bank_transaction (id, organization_id, bank_account_id, currency, amount_minor, booking_date),
  add constraint payment_bank_line check ((channel in ('camt053', 'csv')) = (bank_transaction_id is not null));

-- The line is a credit a debtor paid (a single payment or an unsplit batch) of a statement in the payment's
-- channel. M2b-3 widens this when ops release a suspected duplicate.
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
  where t.direction <> 'credit' or t.kind not in ('debtor_credit', 'batch_unsplit') or s.format <> n.channel;
  if v_bad is not null then
    raise exception 'payment %: its bank line is not a debtor credit of a statement in this channel', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger payment_insert_guard after insert on public.payment
  referencing new table as new_rows for each statement execute function private.payment_insert_guard();
alter table public.payment enable always trigger payment_insert_guard;

------------------------------------------------------------------------------------------
-- Import: the worker parses the file, COPYs its lines here, then calls private.ingest_statement
-- in the same transaction (design §8.3). Rows live only inside that transaction.
------------------------------------------------------------------------------------------

create unlogged table private.bank_import_stage (
  statement_id uuid not null,
  line_no integer not null,
  section_no integer not null,
  dedup_key text not null,
  direction text not null,
  amount_minor bigint not null,
  currency char(3) not null,
  booking_date date not null,
  value_date date,
  reversal_indicator boolean not null default false,
  bank_tx_code text,
  acct_svcr_ref text,
  end_to_end_id text,
  tx_id text,
  mandate_ref text,
  counterparty_name text,
  ultimate_counterparty_name text,
  counterparty_iban text,
  remittance_text text,
  creditor_reference text,
  return_reason text,
  original_end_to_end_id text,
  batch_entry_ref text,
  entry_ref text,
  kind text not null,
  method text not null,
  primary key (statement_id, line_no)
);
alter table private.bank_import_stage enable row level security;

-- Signed amount and number of the lines of a bank account booked on or before a date that are not in
-- the ledger (M2b-2: every line but the credits that are payments; M2b-3 and M2b-6 redefine it when held
-- lines are released and debits are booked). I9: closing balance at D = 5120[bank](D) + this.
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
    and not (t.direction = 'credit' and t.kind in ('debtor_credit', 'batch_unsplit'));
$$;

-- Lookups of the import's new lines (pg_temp._bi_new of ingest_statement) among the stored lines: one
-- index probe per new line, whatever the statistics say (bank_transaction is often just loaded and not
-- analysed; a hash join would read every line of the account, however old, for a 500-line day).
-- The first new line whose bank entry (camt.053 Ntry/AcctSvcrRef) this bank account has already.
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
          join public.bank_transaction t on t.bank_account_id = p_bank_account_id and t.entry_ref = x.entry_ref);
end;
$$;

-- New lines whose key is on another bank account of the servicer with the same day, amount and direction.
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
begin
  return query
  select x.line_no, x.dedup_key
  from pg_temp._bi_new x
  join public.bank_account o on o.organization_id = p_organization_id and o.id <> p_bank_account_id
  join public.bank_transaction t on t.bank_account_id = o.id and t.dedup_key = x.dedup_key
  where (t.direction, t.amount_minor, t.booking_date) = (x.direction, x.amount_minor, x.booking_date);
end;
$$;

-- p_header: {format, version, line_count, skipped_not_booked, sections: [{stmt_id, seq, from_date, to_date,
-- opening_minor, closing_minor}]} (amounts as text). Refusals raise "<code>: <detail>" (SQLSTATE 22023):
-- the job records the code on the statement, and nothing of the import is kept.
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
     or x.kind is null or x.kind not in ('debtor_credit', 'return', 'refund_out', 'other_debit', 'batch_unsplit')
     or (x.direction = 'credit' and x.kind not in ('debtor_credit', 'return', 'batch_unsplit'))
     or (x.direction = 'debit' and x.kind = 'debtor_credit')
     or (s.format = 'csv' and (x.section_no <> 0 or x.dedup_key !~ '^[ch]:' or x.entry_ref is not null))
     or (s.format = 'camt053' and (x.section_no < 1 or x.section_no > jsonb_array_length(v_sections)
                                   or x.dedup_key !~ '^[teh]:'))
     or length(x.entry_ref) not between 1 and 300
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
                    (t.direction, t.amount_minor, t.booking_date) as conflict
  from pg_temp._bi_stage x
  join public.bank_transaction t on t.bank_account_id = s.bank_account_id and t.dedup_key = x.dedup_key;
  select min(k.line_no)::text into v_bad from pg_temp._bi_known k where k.conflict;
  if v_bad is not null then
    raise exception 'reference_conflict: line % has the bank reference of an earlier line with another amount, direction or date',
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
      creditor_reference, return_reason, original_end_to_end_id, batch_entry_ref, entry_ref, kind)
    select s.organization_id, s.bank_account_id, s.id, n.line_no, n.dedup_key, n.direction, n.amount_minor, s.currency,
           n.booking_date, n.value_date, coalesce(n.reversal_indicator, false), n.bank_tx_code, n.acct_svcr_ref,
           n.end_to_end_id, n.tx_id, n.mandate_ref, n.counterparty_name, n.ultimate_counterparty_name,
           n.counterparty_iban, n.remittance_text, n.creditor_reference, n.return_reason, n.original_end_to_end_id,
           n.batch_entry_ref, n.entry_ref, n.kind
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
    'suspected_duplicates', count(*) filter (where n.kind = 'suspected_duplicate'))
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
-- Commands: upload a statement (admin or ops manager at aal2; decision #18)
------------------------------------------------------------------------------------------

-- Where to upload a statement, and how far it got (shared by the command and its replays).
create or replace function private.statement_upload_target(p_statement_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'statement_id', s.id, 'bucket', s.storage_bucket, 'storage_path', s.storage_path, 'status', s.status,
    'format', s.format,
    -- already submitted (or finished): not a second import
    'duplicate', s.status <> 'awaiting_upload',
    'uploaded', s.status <> 'awaiting_upload'
      or exists (select 1 from storage.objects o where o.bucket_id = s.storage_bucket and o.name = s.storage_path))
  from public.bank_statement s where s.id = p_statement_id;
$$;

create or replace function public.create_statement_upload(
  p_idempotency_key text, p_bank_account_id uuid, p_file_name text, p_sha256 text, p_size_bytes bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bank_account;
  v_request jsonb;
  v_result jsonb;
  v_existing uuid;
  v_ext text;
  v_format text;
  v_id uuid := gen_random_uuid();
begin
  select * into b from public.bank_account where id = p_bank_account_id;
  if not found or not private.has_role(b.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_account_id', p_bank_account_id, 'file_name', p_file_name,
                                  'sha256', lower(p_sha256), 'size_bytes', p_size_bytes);
  v_result := private.command_replay('create_statement_upload', p_idempotency_key, v_request);
  if v_result is not null then
    return private.statement_upload_target((v_result ->> 'statement_id')::uuid);
  end if;
  if b.status <> 'active' then
    raise exception 'the bank account is closed' using errcode = 'check_violation';
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-fA-F]{64}$' or p_size_bytes is null or p_size_bytes < 1
     or p_file_name is null or length(p_file_name) not between 1 and 255 or p_file_name ~ '[/\\[:cntrl:]]' then
    raise exception 'invalid file' using errcode = 'check_violation';
  end if;
  if p_size_bytes > 524288000 then
    raise exception 'the file is too large' using errcode = 'check_violation';
  end if;
  v_ext := lower(substring(p_file_name from '\.([A-Za-z0-9]+)$'));
  v_format := case v_ext when 'xml' then 'camt053' when 'csv' then 'csv' when 'txt' then 'csv' end;
  if v_format is null then
    raise exception 'unsupported statement file type' using errcode = 'check_violation';
  end if;
  -- One feed per bank account: CAMT and CSV lines carry different dedup keys, so mixing them could book
  -- the same money twice.
  if v_format <> b.feed then
    raise exception 'the file format does not match the bank account feed' using errcode = 'check_violation';
  end if;
  -- A file sent for another bank account of the servicer (the wrong account chosen first) is not sent
  -- again for this one: its money would be booked on both. A registration whose file never came does not
  -- count. ingest_statement checks it again, under a lock.
  if exists (select 1 from public.bank_statement p
             where p.organization_id = b.organization_id and p.file_sha256 = lower(p_sha256)
               and p.bank_account_id <> b.id and p.status in ('uploaded', 'imported')) then
    raise exception 'the file is already a statement of another bank account' using errcode = 'check_violation';
  end if;
  -- The same file for the same bank account: the statement already registered, never a second one.
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path, created_by, idempotency_key)
  values (v_id, b.organization_id, b.id, b.currency, v_format, p_file_name, lower(p_sha256), p_size_bytes,
          -- ASCII key built from ids only (storage rejects accents); the name stays in file_name
          b.organization_id::text || '/' || b.id::text || '/' || v_id::text || '.' || v_ext, auth.uid(),
          p_idempotency_key)
  on conflict (bank_account_id, file_sha256) where status not in ('rejected', 'failed') do nothing;
  select s.id into v_existing from public.bank_statement s
  where s.bank_account_id = b.id and s.file_sha256 = lower(p_sha256) and s.status not in ('rejected', 'failed');
  perform private.command_record('create_statement_upload', p_idempotency_key, v_request,
                                 jsonb_build_object('statement_id', v_existing));
  return private.statement_upload_target(v_existing);
end;
$$;

-- File stored: queue the import (the worker does the work; this takes milliseconds).
create or replace function public.submit_statement_import(p_idempotency_key text, p_statement_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.bank_statement;
  v_request jsonb := jsonb_build_object('statement_id', p_statement_id);
begin
  select * into s from public.bank_statement where id = p_statement_id for update;
  if not found or not private.has_role(s.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if private.command_replay('submit_statement_import', p_idempotency_key, v_request) is not null then
    return (select status from public.bank_statement where id = p_statement_id);
  end if;
  if s.status = 'awaiting_upload' then
    if not exists (select 1 from storage.objects o where o.bucket_id = s.storage_bucket and o.name = s.storage_path) then
      raise exception 'the file is not uploaded yet' using errcode = 'check_violation';
    end if;
    update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s.id;
    perform pgmq.send('payments', jsonb_build_object('type', 'import', 'statement_id', s.id));
  end if;  -- otherwise already submitted: nothing to do
  perform private.command_record('submit_statement_import', p_idempotency_key, v_request,
                                 jsonb_build_object('statement_id', s.id));
  return (select status from public.bank_statement where id = p_statement_id);
end;
$$;

select pgmq.create('payments');
select pgmq.create('payments_dlq');

-- Storage: a user may upload only to the exact key of a statement awaiting its file that they may import.
-- No read or delete for users: the worker reads with the service role.
create or replace function private.can_upload_statement_object(p_bucket text, p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.bank_statement s
    where s.storage_bucket = p_bucket and s.storage_path = p_name and s.status = 'awaiting_upload'
      and private.has_role(s.organization_id, array['admin', 'ops_manager'])
  );
$$;
create policy bank_statement_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'bank-statements' and (select private.can_upload_statement_object(bucket_id, name)));

------------------------------------------------------------------------------------------
-- Read access: bank lines carry third-party payer data (admins and ops managers, decision #18)
------------------------------------------------------------------------------------------

alter table public.bank_statement enable row level security;
alter table public.bank_transaction enable row level security;
revoke all on public.bank_statement, public.bank_transaction from public, anon, authenticated;
revoke all on private.bank_import_stage from public, anon, authenticated;
grant select on public.bank_statement, public.bank_transaction to authenticated;
grant select, insert, delete on private.bank_import_stage to service_role;

create policy bank_statement_read on public.bank_statement for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy bank_transaction_read on public.bank_transaction for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));

------------------------------------------------------------------------------------------
-- Privileges
------------------------------------------------------------------------------------------

revoke execute on function private.ingest_statement(uuid, jsonb), private.bank_unposted(uuid, date),
  private.bank_import_entry_known(uuid), private.bank_import_lines_elsewhere(uuid, uuid),
  private.statement_upload_target(uuid), private.can_upload_statement_object(text, text),
  private.bank_statement_guard(), private.bank_transaction_insert_guard(), private.payment_insert_guard(),
  private.refuse_change()
  from public, anon, authenticated, service_role;
grant execute on function private.ingest_statement(uuid, jsonb), private.bank_unposted(uuid, date) to service_role;
grant execute on function private.can_upload_statement_object(text, text) to authenticated;
revoke execute on function public.create_statement_upload(text, uuid, text, text, bigint),
  public.submit_statement_import(text, uuid) from public, anon;
grant execute on function public.create_statement_upload(text, uuid, text, text, bigint),
  public.submit_statement_import(text, uuid) to authenticated;
