-- M2c-4 Runs and invoices (M2-14 core, M2-15 numbering; design docs/design/m2c-remittances.md §6, §8.3–§8.4, §9, §14,
-- §15, §17; ADR-0014 M2c-4 addendum; founder decisions #1–#3, #6, #7, #11, #12 of 2026-11-09).
--
--   * remittance runs per (client, currency), at most one pending per pair: a draft reserves the client's pending items
--     under the allocation lock (K), the worker prices them (`remittances.prepare`: deadlines, commission, documents,
--     settlement plan) into replaceable draft lines; « Actualiser » reserves again, « Abandonner » releases them;
--   * approval (one admin or ops manager at aal2, founder #11) compares each run's inputs hash and net with what the page
--     showed and queues one job per run (`remittances.approve`): each run in its own transaction — re-checks (VAT rate of
--     the issue date, payout blockers, the client's 4670 cap, execution date, the documents and tier history the plan
--     assumed), freezes the lines (each item in exactly one live line), issues the mandate's invoice and credit note,
--     numbered gapless in one yearly series per servicer (FC-AAAA-NNNNNN, founder #12; a counter row locked in the
--     issuing transaction, last), posts their entries, then orders the payout (N > 0, nothing leaves 5120 before the
--     bank's debit: M2c-6) or posts the settlement at once (N = 0); a failing run goes back to draft with its reason and
--     never blocks the others;
--   * the commission history the engine continues from: per (file, tier key) the net basis per terms version, the kept
--     basis and fee and what is charged (remittance_key_state), what each invoice charges each key and what credit
--     notes took back (commission_invoice_charge, commission_credit_alloc), each line's invoice, parts as jsonb;
--   * cancellation of an approved run before its transfer is in a file: the transfer cancelled, one full credit note per
--     invoice of the run, the lines released and the items back in the pending queue, the history restored;
--   * the hourly schedule (pg_cron → worker job: the 1st and 16th or the mandate's weekday, the deadline guard, a payout
--     come back), the nightly checks I14–I17, the R124-6 deadline alerts and breach rows (wired into the payments
--     checks), the reference-data alerts of M2c-3;
--   * reads for « Reversements » (back office).
--
-- Redefined: private.run_payment_checks (I14 with the runs in flight; the runs' checks), private.bank_transfer_guard
-- (a payout's run never changes); bank_transfer gains run_id.

select pgmq.create('remittances');
select pgmq.create('remittances_dlq');

------------------------------------------------------------------------------------------
-- Runs (§6.1 remittance_run; §9.8 state machine)
------------------------------------------------------------------------------------------

create sequence private.remittance_run_number_seq;

create table public.remittance_run (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  currency char(3) not null references public.currency (code),
  number text not null unique check (number ~ '^RV-[0-9]{4}-[0-9]{6,}$'),   -- unique, not gapless
  status text not null default 'draft' check (status in ('draft', 'approved', 'sent', 'booked', 'cancelled')),
  trigger text not null check (trigger in ('schedule', 'deadline', 'payout_returned', 'manual')),
  schedule_key text unique check (schedule_key ~ '^sched:'),               -- sched:<client>:<currency>:<Paris date>
  job text check (job in ('prepare', 'approve')),                         -- the job in flight
  job_token uuid,                                                          -- a later request makes it a no-op
  job_queued_at timestamptz,
  version integer not null default 1 check (version >= 1),               -- compare and set of the commands
  known_at timestamptz not null,                                           -- K: the items reserved, under the lock
  prepared_at timestamptz,
  previous_run_id uuid references public.remittance_run (id),
  service_from date,                                                       -- previous K → this K (269 1 a bis)
  service_to date,
  item_count integer not null default 0 check (item_count >= 0),
  line_count integer check (line_count >= 0),
  gross_minor bigint,
  invoice_ht_minor bigint, invoice_vat_minor bigint, invoice_ttc_minor bigint,      -- Σ invoices of the run
  credit_ht_minor bigint, credit_vat_minor bigint, credit_ttc_minor bigint,          -- Σ credit notes (magnitudes)
  commission_taken_minor bigint,                                           -- Σ take (TTC compensated)
  advance_recovered_minor bigint,                                          -- Σ take_adv
  refund_minor bigint,                                                     -- refunds owed paid with the payout
  settlement_minor bigint,                                                 -- D
  net_minor bigint,                                                        -- N
  vat_rate numeric(6, 4),                                                  -- the rate the run's invoices bear
  earliest_deadline date,
  earliest_latest_execution_date date,
  unmeetable_count integer not null default 0,
  requested_execution_date date,
  late_reason text check (length(btrim(late_reason)) between 1 and 2000),
  payout_account_id uuid references public.client_payout_account (id),
  payout_snapshot jsonb,                                                   -- the payee frozen at approval
  blockers text[] not null default '{}',                                   -- what blocks the payout
  commission_blockers text[] not null default '{}',                        -- what keeps the commission pending
  engine_version text,
  inputs_hash text check (inputs_hash ~ '^[0-9a-f]{64}$'),
  settlement_plan jsonb,                                                   -- per mandate and document (amounts text)
  last_failure jsonb,                                                      -- {code, detail, at}: back to draft
  transfer_id uuid unique references public.bank_transfer (id),
  approval_requested_by uuid references public.app_user (id),
  approved_by uuid references public.app_user (id),
  approved_at timestamptz,
  invoice_late boolean not null default false,                             -- approved > 2 business days after K
  booked_on date,
  cancelled_by uuid references public.app_user (id),
  cancelled_at timestamptz,
  cancel_reason text check (length(btrim(cancel_reason)) between 1 and 2000),
  created_by uuid references public.app_user (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint remittance_run_totals check (prepared_at is null or (gross_minor is not null and net_minor is not null
    and settlement_minor is not null and net_minor + settlement_minor = gross_minor)),
  constraint remittance_run_approved check ((status in ('approved', 'sent', 'booked')) <= (approved_at is not null)),
  constraint remittance_run_booked check ((status = 'booked') = (booked_on is not null)),
  constraint remittance_run_cancelled check ((status = 'cancelled') = (cancelled_at is not null and cancel_reason is not null)),
  constraint remittance_run_job check ((job is null) = (job_token is null) and (job is null) = (job_queued_at is null)
    and (job is null or status = 'draft'))
);
-- one pending run per (client, currency): a draft, or approved and not yet debited
create unique index remittance_run_pending_uq on public.remittance_run (client_organization_id, currency)
  where status in ('draft', 'approved', 'sent');
create index remittance_run_org_idx on public.remittance_run (organization_id, status, created_at desc);
create index remittance_run_client_idx on public.remittance_run (client_organization_id, currency, created_at desc);
create index remittance_run_job_idx on public.remittance_run (job_queued_at) where job is not null;
comment on table public.remittance_run is
  'A remittance run of one client and currency (R124-6): its items reserved at K, its lines, documents and payout.';

alter table private.remittance_pending
  add constraint remittance_pending_run_fk foreign key (draft_run_id) references public.remittance_run (id);
create index remittance_pending_run_idx on private.remittance_pending (draft_run_id) where draft_run_id is not null;

-- What was asked never changes; the status only moves forward (§9.8); a draft's totals change only by its own job.
create or replace function private.remittance_run_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'remittance run: starts as a draft' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.organization c where c.id = new.client_organization_id
                     and c.servicer_organization_id = new.organization_id) then
      raise exception 'remittance run: a client of the servicer' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.client_organization_id, new.currency, new.number, new.trigger, new.schedule_key,
      new.previous_run_id, new.created_by, new.created_at)
     is distinct from
     (old.id, old.organization_id, old.client_organization_id, old.currency, old.number, old.trigger, old.schedule_key,
      old.previous_run_id, old.created_by, old.created_at)
     or (new.status <> old.status and not (
           (old.status = 'draft' and new.status in ('approved', 'booked', 'cancelled'))
           or (old.status = 'approved' and new.status in ('sent', 'booked', 'cancelled'))
           or (old.status = 'sent' and new.status in ('booked', 'cancelled'))))
     or (old.status <> 'draft' and (
           (new.gross_minor, new.net_minor, new.settlement_minor, new.inputs_hash, new.vat_rate, new.invoice_ttc_minor,
            new.credit_ttc_minor, new.payout_snapshot, new.settlement_plan, new.requested_execution_date,
            new.approved_by, new.approved_at, new.known_at, new.line_count)
           is distinct from
           (old.gross_minor, old.net_minor, old.settlement_minor, old.inputs_hash, old.vat_rate, old.invoice_ttc_minor,
            old.credit_ttc_minor, old.payout_snapshot, old.settlement_plan, old.requested_execution_date,
            old.approved_by, old.approved_at, old.known_at, old.line_count))) then
    raise exception 'remittance run %: what was asked never changes, its status only moves forward', old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger remittance_run_guard before insert or update on public.remittance_run
  for each row execute function private.remittance_run_guard();
alter table public.remittance_run enable always trigger remittance_run_guard;
create trigger remittance_run_no_delete before delete or truncate on public.remittance_run
  for each statement execute function private.refuse_delete();
alter table public.remittance_run enable always trigger remittance_run_no_delete;
create trigger remittance_run_touch before update on public.remittance_run
  for each row execute function private.touch_updated_at();
create trigger remittance_run_change_log after insert or update or delete on public.remittance_run
  for each row execute function private.log_change();

-- The payout a run orders (M2c-6 puts it in a file and books it from the bank's debit).
alter table public.bank_transfer add column run_id uuid references public.remittance_run (id);
create unique index bank_transfer_run_uq on public.bank_transfer (run_id) where run_id is not null and status <> 'cancelled';
-- (a payout booked before runs existed, or an unplanned one M2c-6 records, has none)
alter table public.bank_transfer add constraint bank_transfer_payout_run check (run_id is null or kind = 'payout');

------------------------------------------------------------------------------------------
-- Drafts (§9.4): replaceable, private; copied into the frozen tables at approval
------------------------------------------------------------------------------------------

-- One line per item reserved by the draft, priced by the prepare job (amounts in minor units; jsonb amounts as text).
create table private.remittance_draft_line (
  run_id uuid not null references public.remittance_run (id),
  line_no integer not null check (line_no >= 1),
  ledger_entry_id uuid not null,
  kind text not null,
  account_id uuid,
  portfolio_id uuid,
  mandate_id uuid,
  mandate_terms_id uuid,
  payment_id uuid,
  encaissement_date date,
  effective_date date not null,
  posted_at timestamptz not null,
  deadline date,
  latest_execution_date date,
  unmeetable boolean not null default false,
  amount_minor bigint not null,
  basis jsonb not null default '{}',
  commission_minor bigint not null default 0,
  commission_state text not null check (commission_state in ('charged', 'pending', 'none')),
  commission_reason text,
  parts jsonb not null default '[]',
  original_entry_id uuid,
  invoiced boolean not null default false,          -- charged by the run's invoice of its mandate
  primary key (run_id, line_no)
);
create index remittance_draft_line_entry_idx on private.remittance_draft_line (run_id, ledger_entry_id);

-- Lines of earlier runs whose commission was left pending, priced by this draft (§9.1: « the next run invoices them »).
create table private.remittance_draft_repricing (
  run_id uuid not null references public.remittance_run (id),
  line_run_id uuid not null,
  line_no integer not null,
  ledger_entry_id uuid not null,
  commission_minor bigint not null,
  commission_state text not null check (commission_state in ('charged', 'none')),
  commission_reason text,
  parts jsonb not null default '[]',
  invoiced boolean not null default false,
  primary key (run_id, line_run_id, line_no)
);

-- The rest of the draft: its documents per mandate, the tier history after it, its settlement plan.
create table private.remittance_draft (
  run_id uuid primary key references public.remittance_run (id),
  vat_rate numeric(6, 4) not null,
  documents jsonb not null default '[]',
  key_states jsonb not null default '[]',
  history_seq bigint not null default 0,            -- the latest key state of the client when prepared
  plan jsonb not null default '{}',
  -- what the plan assumed, re-checked at approval (money review #1, #2): the VAT book of the run's invoices (VAT on
  -- debits: 44571 at once, else 44574 until settled, 242 nonies A 11° bis) and the client's proceeding (§9.6: the
  -- documents dated before its opening are not set off, L622-7 I)
  vat_on_debits boolean not null default false,
  proceeding_opened_on date,
  created_at timestamptz not null default now()
);

------------------------------------------------------------------------------------------
-- Frozen lines (§6.1 remittance_line): one per item, each item in exactly one live line (I15)
------------------------------------------------------------------------------------------

create table public.remittance_line (
  run_id uuid not null references public.remittance_run (id),
  line_no integer not null check (line_no >= 1),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  currency char(3) not null,
  ledger_entry_id uuid not null references public.ledger_entry (id),
  kind text not null check (kind in ('allocation', 'allocation_reversal', 'forward', 'forward_reversal', 'client_advance',
                                     'client_advance_reversal', 'payout_returned', 'unplanned_payout')),
  account_id uuid references public.account (id),
  portfolio_id uuid references public.portfolio (id),
  mandate_id uuid references public.mandate (id),
  mandate_terms_id uuid references public.mandate_terms (id),
  payment_id uuid references public.payment (id),
  encaissement_date date,
  effective_date date not null,
  posted_at timestamptz not null,
  deadline date,
  latest_execution_date date,
  unmeetable boolean not null default false,       -- « délai intenable » (a delay of 1–5 days, OQ-71)
  amount_minor bigint not null check (amount_minor <> 0),   -- signed: + owed to the client; = the entry's 4670
  basis jsonb not null default '{}',                -- commissionable basis per family (text)
  commission_minor bigint not null default 0,       -- signed HT of the line in its run
  commission_state text not null check (commission_state in ('charged', 'pending', 'none')),
  commission_reason text,
  parts jsonb not null default '[]',                -- the engine's parts (bands, re-tiering, hold, kept)
  original_entry_id uuid references public.ledger_entry (id),
  invoice_id uuid,                                  -- the invoice that charged it (FK below)
  released boolean not null default false,          -- the run was cancelled: the item went back to pending
  released_at timestamptz,
  primary key (run_id, line_no),
  constraint remittance_line_released check (released = (released_at is not null)),
  constraint remittance_line_priced check (commission_state = 'charged' or commission_minor = 0)
);
create unique index remittance_line_live_uq on public.remittance_line (ledger_entry_id) where not released;
create index remittance_line_account_idx on public.remittance_line (account_id) where not released;
create index remittance_line_pending_idx on public.remittance_line (client_organization_id, currency)
  where commission_state = 'pending' and not released;
create index remittance_line_invoice_idx on public.remittance_line (invoice_id) where invoice_id is not null;
comment on table public.remittance_line is
  'A remittance item frozen into a run: the 4670 posting of one entry, its R124-6 deadline and its commission.';

-- A later run's pricing of a line whose commission its own run left pending (live while that run is not cancelled).
create table public.remittance_line_repricing (
  pricing_run_id uuid not null references public.remittance_run (id),
  run_id uuid not null,
  line_no integer not null,
  ledger_entry_id uuid not null references public.ledger_entry (id),
  commission_minor bigint not null,
  commission_state text not null check (commission_state in ('charged', 'none')),
  commission_reason text,
  parts jsonb not null default '[]',
  invoice_id uuid,
  primary key (pricing_run_id, run_id, line_no),
  foreign key (run_id, line_no) references public.remittance_line (run_id, line_no)
);
create index remittance_line_repricing_line_idx on public.remittance_line_repricing (run_id, line_no);

------------------------------------------------------------------------------------------
-- Commission invoices and credit notes (§6.1, §14; founder #12): one gapless yearly series per servicer
------------------------------------------------------------------------------------------

create table private.invoice_counter (
  organization_id uuid not null references public.organization (id),
  series text not null,
  year integer not null check (year between 2000 and 2999),
  last_seq integer not null check (last_seq >= 0),
  last_issue_date date,
  primary key (organization_id, series, year)
);
comment on table private.invoice_counter is
  'The last number of each (servicer, series, year): locked FOR UPDATE in the issuing transaction, last (gapless).';

create table public.commission_invoice (
  id uuid primary key,
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  mandate_id uuid not null references public.mandate (id),
  run_id uuid references public.remittance_run (id),
  kind text not null check (kind in ('invoice', 'credit_note')),
  series text not null check (series ~ '^[A-Z]{2,6}$'),
  year integer not null,
  seq integer not null check (seq >= 1),
  number text not null,
  issue_date date not null,
  service_from date,
  service_to date,
  currency char(3) not null check (currency = 'EUR'),
  ht_minor bigint not null,
  vat_rate numeric(6, 4),                  -- an invoice's rate (a credit note: each corrected invoice's, below)
  vat_minor bigint not null,
  ttc_minor bigint not null,
  vat_book text check (vat_book in ('vat_pending', 'vat_collected')),   -- where an invoice's VAT went (11° bis)
  settlement text not null check (settlement in ('netted', 'due')),
  due_date date,
  reason text not null check (reason in ('commission', 'reversal', 'run_cancelled')),
  payload jsonb not null,                  -- seller, buyer, lines, totals (frozen; M2c-5 renders it)
  payload_sha256 text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  ledger_entry_id uuid not null unique references public.ledger_entry (id),
  created_at timestamptz not null default clock_timestamp(),
  unique (organization_id, series, year, seq),
  unique (organization_id, number),
  constraint commission_invoice_number check (number = series || '-' || year || '-' || lpad(seq::text, 6, '0')),
  constraint commission_invoice_year check (year = extract(year from issue_date)),
  constraint commission_invoice_totals check (ttc_minor = ht_minor + vat_minor and case kind
    when 'invoice' then ht_minor > 0 and vat_minor >= 0 and vat_rate is not null and vat_book is not null
    else ht_minor < 0 and vat_minor <= 0 and vat_rate is null and vat_book is null end),
  constraint commission_invoice_due check ((settlement = 'due') = (due_date is not null))
);
create index commission_invoice_client_idx on public.commission_invoice (client_organization_id, issue_date desc);
create index commission_invoice_run_idx on public.commission_invoice (run_id) where run_id is not null;
create index commission_invoice_mandate_idx on public.commission_invoice (mandate_id, kind);
comment on table public.commission_invoice is
  'Commission invoices and credit notes (CGI 289, 242 nonies A): one gapless yearly series per servicer.';
-- (checked at commit: the approval freezes the lines naming the invoices it issues next)
alter table public.remittance_line add constraint remittance_line_invoice_fk foreign key (invoice_id)
  references public.commission_invoice (id) deferrable initially deferred;
alter table public.remittance_line_repricing add constraint remittance_line_repricing_invoice_fk foreign key (invoice_id)
  references public.commission_invoice (id) deferrable initially deferred;

create table public.commission_invoice_line (
  invoice_id uuid not null references public.commission_invoice (id),
  line_no integer not null check (line_no >= 1),
  kind text not null check (kind in ('commission', 'regularisation', 'credit')),
  designation_fr text not null check (length(designation_fr) between 1 and 1000),
  claim_type_code text,
  rule_id text,
  families text[] not null default '{}',
  tiers jsonb not null default '[]',        -- [[rate, base moved (text)]] of the collections' own bands
  quantity integer not null default 1 check (quantity = 1),
  ht_minor bigint not null,                 -- unit price HT (quantity 1)
  vat_rate numeric(6, 4) not null,
  original_invoice_id uuid references public.commission_invoice (id),   -- a credit note's line: the invoice corrected
  primary key (invoice_id, line_no)
);

-- What each invoice charges each (file, tier key): what the next runs' credit notes allocate against (LIFO, §8.4).
create table public.commission_invoice_charge (
  invoice_id uuid not null references public.commission_invoice (id),
  account_id uuid not null references public.account (id),
  tier_key text not null,
  charged_minor bigint not null check (charged_minor > 0),
  primary key (invoice_id, account_id, tier_key)
);
create index commission_invoice_charge_key_idx on public.commission_invoice_charge (account_id, tier_key);

-- What a credit note takes back from an earlier invoice, per (file, tier key) and line it credits (289 I 5).
create table public.commission_credit_alloc (
  credit_note_id uuid not null references public.commission_invoice (id),
  line_no integer not null check (line_no >= 1),
  original_invoice_id uuid not null references public.commission_invoice (id),
  account_id uuid not null references public.account (id),
  tier_key text not null,
  ht_minor bigint not null check (ht_minor < 0),
  entry_id uuid references public.ledger_entry (id),    -- the line credited (a reversal: the line undoing a collection)
  primary key (credit_note_id, line_no)
);
create index commission_credit_alloc_original_idx
  on public.commission_credit_alloc (original_invoice_id, account_id, tier_key);
create index commission_credit_alloc_entry_idx on public.commission_credit_alloc (entry_id) where entry_id is not null;

-- Per corrected invoice: the HT and VAT a credit note takes back (VAT by cumulative difference at that invoice's rate),
-- the VAT split — off the pending VAT first (44574), the rest off the VAT already due (44571) — and its TTC applied to
-- the invoice's open part, the rest being a refund owed to the client.
create table public.commission_credit_correction (
  credit_note_id uuid not null references public.commission_invoice (id),
  original_invoice_id uuid not null references public.commission_invoice (id),
  vat_rate numeric(6, 4) not null,
  ht_minor bigint not null check (ht_minor < 0),
  vat_minor bigint not null check (vat_minor <= 0),
  vat_pending_minor bigint not null check (vat_pending_minor >= 0),
  vat_collected_minor bigint not null check (vat_collected_minor >= 0),
  applied_minor bigint not null check (applied_minor >= 0),
  excess_minor bigint not null check (excess_minor >= 0),
  primary key (credit_note_id, original_invoice_id),
  constraint commission_credit_correction_vat check (vat_pending_minor + vat_collected_minor = -vat_minor),
  constraint commission_credit_correction_ttc check (applied_minor + excess_minor = -(ht_minor + vat_minor))
);
create index commission_credit_correction_original_idx on public.commission_credit_correction (original_invoice_id);

-- The settlement sub-ledger (§6.1, I18; 290 A data): what settles each document. An invoice's open part = TTC − Σ its
-- rows; a credit note's refund owed = its TTC − what it applied to the invoices it corrects − the refunds paid.
create table public.commission_settlement (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  document_kind text not null check (document_kind in ('invoice', 'credit_note', 'advance')),
  document_id uuid not null,
  credit_note_id uuid references public.commission_invoice (id),   -- kind credit_note: the credit note applied
  entry_id uuid references public.ledger_entry (id),               -- the settlement entry (compensation, refund)
  kind text not null check (kind in ('compensation', 'credit_note', 'refund', 'payment_own', 'payment_dedicated',
                                     'write_off')),
  amount_minor bigint not null check (amount_minor >= 0),          -- TTC settled
  vat_moved_minor bigint not null default 0 check (vat_moved_minor >= 0),   -- VAT leaving 44574 for this document
  settled_on date not null,
  run_id uuid references public.remittance_run (id),
  created_at timestamptz not null default clock_timestamp(),
  constraint commission_settlement_something check (amount_minor > 0 or vat_moved_minor > 0),
  constraint commission_settlement_credit check ((kind = 'credit_note') = (credit_note_id is not null))
);
create index commission_settlement_document_idx on public.commission_settlement (document_id);
create index commission_settlement_credit_note_idx on public.commission_settlement (credit_note_id)
  where credit_note_id is not null;
create index commission_settlement_client_idx on public.commission_settlement (client_organization_id);

-- The commission history per (file, tier key) the engine continues from (ADR-0014 M2c-3 « For M2c-4 »): the net basis
-- per terms version, the basis and fee kept by `keep` reversals, the commission charged (= Σ the open charges of its
-- invoices). Append-only: the latest row is the state; an approval writes the keys it priced, a cancellation the keys
-- back as before the run (with what its invoices still charge).
create table public.remittance_key_state (
  seq bigint generated always as identity primary key,
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  account_id uuid not null references public.account (id),
  tier_key text not null,
  run_id uuid not null references public.remittance_run (id),
  cause text not null check (cause in ('approved', 'cancelled')),
  basis jsonb not null default '[]',              -- [[terms version id, net basis (text)]], by version id
  kept_basis_minor bigint not null default 0 check (kept_basis_minor >= 0),
  kept_minor bigint not null default 0 check (kept_minor >= 0),
  commission_minor bigint not null default 0 check (commission_minor >= 0),
  created_at timestamptz not null default clock_timestamp()
);
create index remittance_key_state_key_idx on public.remittance_key_state (account_id, tier_key, seq desc);
create index remittance_key_state_run_idx on public.remittance_key_state (run_id);
create index remittance_key_state_client_idx on public.remittance_key_state (client_organization_id, seq desc);

-- R124-6 breaches (§9.2, I21): a positive item not paid by its latest execution date, or approved for a later date.
create table public.remittance_deadline_breach (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  ledger_entry_id uuid not null unique references public.ledger_entry (id),
  payment_id uuid references public.payment (id),
  run_id uuid references public.remittance_run (id),
  deadline date,
  latest_execution_date date not null,
  requested_execution_date date,
  blocked_reason text check (blocked_reason in ('unmeetable_delay')),
  late_reason text,
  detected_at timestamptz not null default clock_timestamp()
);
create index remittance_deadline_breach_org_idx on public.remittance_deadline_breach (organization_id, detected_at desc);
comment on table public.remittance_deadline_breach is
  'R124-6 breaches: an item approved for after its latest execution date, or not paid by it (append-only).';

-- Each late approval (§9.5 step 2: « a later date is allowed only with a recorded late_reason »): per run and positive
-- line whose latest execution date is before the payout's requested execution date (N > 0) or the settlement date
-- (N = 0), the approver's reason and the date, whether or not the nightly checks already wrote the item's breach row
-- (which is unique per item and append-only: review M2c-4, tests-ui #2, legal #8).
create table public.remittance_late_approval (
  run_id uuid not null references public.remittance_run (id),
  ledger_entry_id uuid not null references public.ledger_entry (id),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  latest_execution_date date not null,
  requested_execution_date date not null,          -- the payout's; the settlement date when N = 0
  late_reason text not null check (length(btrim(late_reason)) between 1 and 2000),
  approved_by uuid references public.app_user (id),
  created_at timestamptz not null default clock_timestamp(),
  primary key (run_id, ledger_entry_id),
  constraint remittance_late_approval_late check (latest_execution_date < requested_execution_date)
);
create index remittance_late_approval_entry_idx on public.remittance_late_approval (ledger_entry_id);
create index remittance_late_approval_org_idx on public.remittance_late_approval (organization_id, created_at desc);
create index remittance_late_approval_client_idx on public.remittance_late_approval (client_organization_id);
comment on table public.remittance_late_approval is
  'R124-6: each line approved for after its latest execution date, with the approver''s reason (append-only).';

-- Append-only facts (§6.2): lines change only by their release (false → true, by the cancellation); invoices, their
-- lines, charges, credit allocations and corrections, settlements, key states, breaches, late approvals and
-- repricings never change. The line's release is checked by a column comparison in the trigger's WHEN, so a released
-- line costs no function call (a 50k-line cancellation stays within the API's 8 s: performance review #1); a column
-- added to remittance_line must be added to this list (pgTAP 023 counts them).
create or replace function private.remittance_line_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'remittance line %/%: frozen (only its release by a cancellation)', old.run_id, old.line_no
    using errcode = 'check_violation';
end;
$$;
create trigger remittance_line_guard before update on public.remittance_line
  for each row when (old.released or not new.released
    or (new.run_id, new.line_no, new.organization_id, new.client_organization_id, new.currency, new.ledger_entry_id,
        new.kind, new.account_id, new.portfolio_id, new.mandate_id, new.mandate_terms_id, new.payment_id,
        new.encaissement_date, new.effective_date, new.posted_at, new.deadline, new.latest_execution_date,
        new.unmeetable, new.amount_minor, new.basis, new.commission_minor, new.commission_state, new.commission_reason,
        new.parts, new.original_entry_id, new.invoice_id)
       is distinct from
       (old.run_id, old.line_no, old.organization_id, old.client_organization_id, old.currency, old.ledger_entry_id,
        old.kind, old.account_id, old.portfolio_id, old.mandate_id, old.mandate_terms_id, old.payment_id,
        old.encaissement_date, old.effective_date, old.posted_at, old.deadline, old.latest_execution_date,
        old.unmeetable, old.amount_minor, old.basis, old.commission_minor, old.commission_state, old.commission_reason,
        old.parts, old.original_entry_id, old.invoice_id))
  execute function private.remittance_line_guard();
alter table public.remittance_line enable always trigger remittance_line_guard;
create trigger remittance_line_no_truncate before delete or truncate on public.remittance_line
  for each statement execute function private.refuse_change();
alter table public.remittance_line enable always trigger remittance_line_no_truncate;

do $$
declare t text;
begin
  foreach t in array array['commission_invoice', 'commission_invoice_line', 'commission_invoice_charge',
                           'commission_credit_alloc', 'commission_credit_correction', 'commission_settlement',
                           'remittance_key_state', 'remittance_deadline_breach', 'remittance_line_repricing',
                           'remittance_late_approval'] loop
    execute format('create trigger %I before update or delete or truncate on public.%I '
                   'for each statement execute function private.refuse_change()', t || '_append_only', t);
    execute format('alter table public.%I enable always trigger %I', t, t || '_append_only');
  end loop;
end;
$$;

-- A line equals its entry's 4670 posting (§6.1 guard) for the run's client and currency: one pass over the
-- statement's new lines, each entry's postings by key.
create or replace function private.remittance_line_insert_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_bad text;
begin
  select min(n.run_id || '/' || n.line_no) into v_bad
  from new_rows n
  cross join lateral (
    select coalesce(-sum(p.amount_minor), 0) as owed, min(la.client_organization_id::text) as client,
           min(la.currency) as currency, count(*) as n
    from public.ledger_posting p
    join public.ledger_account la on la.id = p.ledger_account_id and la.book = 'client_payable'
    where p.entry_id = n.ledger_entry_id) x
  where x.n = 0 or x.owed <> n.amount_minor or x.client <> n.client_organization_id::text or x.currency <> n.currency;
  if v_bad is not null then
    raise exception 'remittance line %: not the 4670 posting of its entry for the run''s client and currency', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger remittance_line_insert_guard after insert on public.remittance_line
  referencing new table as new_rows for each statement execute function private.remittance_line_insert_guard();
alter table public.remittance_line enable always trigger remittance_line_insert_guard;

-- The series (§14.1, I17): each document takes the next number of its series and year, never a date before the
-- previous one's, and only a number the counter gave (the counter row is updated first, in the same transaction);
-- its entry is its own.
create or replace function private.commission_invoice_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_prev record;
  v_last integer;
begin
  select i.seq, i.issue_date into v_prev from public.commission_invoice i
  where i.organization_id = new.organization_id and i.series = new.series and i.year = new.year
  order by i.seq desc limit 1;
  select c.last_seq into v_last from private.invoice_counter c
  where c.organization_id = new.organization_id and c.series = new.series and c.year = new.year;
  if new.seq <> coalesce(v_prev.seq, 0) + 1 or v_last is null or new.seq > v_last
     or new.issue_date < coalesce(v_prev.issue_date, new.issue_date) then
    raise exception 'commission invoice %: numbers follow each other in the series and year, dates never go back',
      new.number using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.ledger_entry e where e.id = new.ledger_entry_id
                   and e.entry_type = case new.kind when 'invoice' then 'commission_invoice' else 'commission_credit_note' end
                   and e.source_type = 'commission_invoice' and e.source_id = new.id::text
                   and e.effective_date = new.issue_date and e.client_organization_id = new.client_organization_id) then
    raise exception 'commission invoice %: its entry is its own (type, document, date, client)', new.number
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger commission_invoice_guard before insert on public.commission_invoice
  for each row execute function private.commission_invoice_guard();
alter table public.commission_invoice enable always trigger commission_invoice_guard;

------------------------------------------------------------------------------------------
-- Business days (the FR-conservative calendar of M2c-3) and what blocks a run
------------------------------------------------------------------------------------------

create or replace function private.is_business_day(p_day date)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare v boolean;
begin
  select not c.closed into v from public.business_calendar c where c.scope = 'FR-conservative' and c.day = p_day;
  if v is null then
    raise exception 'business calendar: % is outside the seeded horizon', p_day using errcode = '22023';
  end if;
  return v;
end;
$$;

-- The first business day after a day.
create or replace function private.next_business_day(p_day date)
returns date
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select min(c.day) from public.business_calendar c
  where c.scope = 'FR-conservative' and c.day > p_day and c.day <= p_day + 15 and not c.closed;
$$;

-- Business days in (p_from, p_to].
create or replace function private.business_days_between(p_from date, p_to date)
returns integer
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select count(*)::integer from public.business_calendar c
  where c.scope = 'FR-conservative' and c.day > p_from and c.day <= p_to and not c.closed;
$$;

-- The dedicated account paying a client: the one active client_funds account of the servicer in the currency
-- (founder #14); none or two: the payout is blocked.
create or replace function private.paying_account(p_organization_id uuid, p_currency char(3))
returns uuid
language sql
stable
set search_path = ''
as $$
  select case when count(*) = 1 then (array_agg(b.id))[1] end from public.bank_account b
  where b.organization_id = p_organization_id and b.purpose = 'client_funds' and b.status = 'active'
    and b.currency = p_currency;
$$;

-- What blocks the payout of a client's run (§9.1): the dedicated account, the payout account (missing, not confirmed,
-- come back), a recorded event (C. civ. 2003; L641-9 I: in liquidation only a court-appointed account confirmed after
-- the event). A proceeding opened does not block the payout (§13 #9): its pre-opening documents are not netted.
create or replace function private.remittance_payout_blockers(p_client_organization_id uuid, p_currency char(3),
                                                              p_on date)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select array_remove(array[
    case (select count(*) from public.bank_account b
          where b.organization_id = o.servicer_organization_id and b.purpose = 'client_funds' and b.status = 'active'
            and b.currency = p_currency)
      when 0 then 'client_funds_account_missing' when 1 then null else 'several_client_funds_accounts' end,
    case when pa.id is null then
           case when exists (select 1 from public.client_payout_account x
                             where x.client_organization_id = o.id and x.currency = p_currency and x.status = 'proposed')
                then 'payout_account_unconfirmed' else 'payout_account_missing' end
         when pa.status = 'returned' then 'payout_account_returned' end,
    (select 'client_status:' || e.kind from public.client_status_event e
     where e.client_organization_id = o.id and e.effective_date <= p_on and e.kind <> 'proceeding_opened'
       and not (e.kind = 'liquidation' and pa.kind = 'court_appointed' and pa.confirmed_at > e.recorded_at)
     order by e.effective_date, e.recorded_at limit 1)], null)
  from public.organization o
  left join public.client_payout_account pa on pa.client_organization_id = o.id and pa.currency = p_currency
    and pa.status in ('active', 'returned')
  where o.id = p_client_organization_id;
$$;

-- What keeps the commission of a run pending (§9.1): the servicer's identity incomplete, the client no longer a
-- professional established in mainland France (founder #13). The run remits gross; a later run invoices the lines.
create or replace function private.remittance_commission_blockers(p_client_organization_id uuid)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select array_remove(array[
    case when cardinality(private.billing_identity_gaps(o.servicer_organization_id)) > 0
         then 'servicer_identity_incomplete' end,
    case when cardinality(private.billing_identity_gaps(o.id)) > 0 then 'client_identity_changed' end], null)
  from public.organization o where o.id = p_client_organization_id;
$$;

------------------------------------------------------------------------------------------
-- Drafts: created (schedule, guard, payout returned, « Préparer maintenant ») with the client's pending items reserved
-- under the allocation lock (K); « Actualiser » reserves again; « Abandonner » releases (§9.3, §9.4)
------------------------------------------------------------------------------------------

-- Creates the draft of (client, currency) and queues its prepare job; null when a run is pending for the pair, the
-- schedule key was used, or nothing is pending. The caller sets the lock timeout.
create or replace function private.create_remittance_run(p_organization_id uuid, p_client_organization_id uuid,
                                                         p_currency char(3), p_trigger text, p_schedule_key text,
                                                         p_actor uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_n integer;
  v_prev public.remittance_run;
  v_k timestamptz;
  v_from date;
  v_token uuid := gen_random_uuid();
begin
  perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  if exists (select 1 from public.remittance_run r where r.client_organization_id = p_client_organization_id
               and r.currency = p_currency and r.status in ('draft', 'approved', 'sent'))
     or (p_schedule_key is not null and exists (select 1 from public.remittance_run r
                                                where r.schedule_key = p_schedule_key)) then
    return null;
  end if;
  -- the service period of a first run starts at its earliest encaissement (a payment's E, else the posting day)
  select min(least((q.posted_at at time zone 'Europe/Paris')::date,
                   coalesce((select private.encaissement_date(p.booking_date, p.value_date)
                             from public.ledger_entry e join public.payment p on p.id = e.payment_id
                             where e.id = q.ledger_entry_id), 'infinity'::date)))
  into v_from from private.remittance_pending q
  where q.organization_id = p_organization_id and q.client_organization_id = p_client_organization_id
    and q.currency = p_currency and q.draft_run_id is null;
  if v_from is null then
    return null;
  end if;
  select * into v_prev from public.remittance_run r
  where r.client_organization_id = p_client_organization_id and r.currency = p_currency and r.status <> 'cancelled'
  order by r.created_at desc limit 1;
  v_k := clock_timestamp();
  insert into public.remittance_run (organization_id, client_organization_id, currency, number, trigger, schedule_key,
                                     job, job_token, job_queued_at, known_at, previous_run_id, service_from, service_to,
                                     created_by)
  values (p_organization_id, p_client_organization_id, p_currency,
          'RV-' || to_char(v_k at time zone 'Europe/Paris', 'YYYY') || '-'
            || lpad(nextval('private.remittance_run_number_seq')::text, 6, '0'),
          p_trigger, p_schedule_key, 'prepare', v_token, v_k, v_k, v_prev.id,
          coalesce((v_prev.known_at at time zone 'Europe/Paris')::date, v_from), (v_k at time zone 'Europe/Paris')::date,
          p_actor)
  returning id into v_id;
  update private.remittance_pending q set draft_run_id = v_id
  where q.organization_id = p_organization_id and q.client_organization_id = p_client_organization_id
    and q.currency = p_currency and q.draft_run_id is null;
  get diagnostics v_n = row_count;
  update public.remittance_run set item_count = v_n where id = v_id;
  perform pgmq.send('remittances', jsonb_build_object('type', 'prepare', 'run_id', v_id, 'token', v_token));
  return v_id;
end;
$$;

-- « Préparer maintenant » (§9.3 d): admins and ops managers at aal2.
create or replace function public.request_remittance_run(p_idempotency_key text, p_client_organization_id uuid,
                                                         p_currency text default 'EUR')
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  c public.organization;
  v_request jsonb;
  v_result jsonb;
  v_id uuid;
begin
  select * into c from public.organization where id = p_client_organization_id;
  if not found or c.servicer_organization_id is null
     or not private.has_role(c.servicer_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('client_organization_id', p_client_organization_id, 'currency', p_currency);
  v_result := private.command_replay('request_remittance_run', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  v_id := private.create_remittance_run(c.servicer_organization_id, c.id, p_currency::char(3), 'manual', null,
                                        auth.uid());
  if v_id is null then
    if exists (select 1 from public.remittance_run r where r.client_organization_id = c.id
                 and r.currency = p_currency and r.status in ('draft', 'approved', 'sent')) then
      raise exception 'remittance run refused: run_pending' using errcode = 'unique_violation';
    end if;
    raise exception 'remittance run refused: nothing_pending' using errcode = 'check_violation';
  end if;
  select jsonb_build_object('run_id', r.id, 'number', r.number, 'items', r.item_count) into v_result
  from public.remittance_run r where r.id = v_id;
  perform private.command_record('request_remittance_run', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- The draft's prepared state, cleared (its job queued again or the draft abandoned).
create or replace function private.remittance_clear_draft(p_run_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from private.remittance_draft_line where run_id = p_run_id;
  delete from private.remittance_draft_repricing where run_id = p_run_id;
  delete from private.remittance_draft where run_id = p_run_id;
$$;

-- A draft, by a command: the row locked, then the allocation lock (the order of the approval job).
create or replace function private.remittance_draft_for_command(p_run_id uuid, p_expected_version integer,
                                                                p_roles text[])
returns public.remittance_run
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or not private.has_role(r.organization_id, p_roles) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select * into r from public.remittance_run where id = p_run_id for update;
  perform private.remittance_command_locks(r.organization_id);
  if r.status <> 'draft' then
    raise exception 'remittance run refused: not_draft' using errcode = 'check_violation';
  end if;
  if r.job = 'approve' then
    raise exception 'remittance run refused: approval_in_progress' using errcode = 'check_violation';
  end if;
  if p_expected_version is distinct from r.version then
    raise exception 'remittance run refused: version_changed' using errcode = 'check_violation';
  end if;
  return r;
end;
$$;

-- « Actualiser » (§9.4 step 3): releases the reservation and reserves the client's pending items again (a new K),
-- then prepares again. A draft with nothing left is abandoned.
create or replace function public.refresh_remittance_run(p_idempotency_key text, p_run_id uuid,
                                                         p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  r public.remittance_run;
  v_request jsonb := jsonb_build_object('run_id', p_run_id, 'expected_version', p_expected_version);
  v_result jsonb;
  v_n integer;
  v_token uuid := gen_random_uuid();
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or not private.has_role(r.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('refresh_remittance_run', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  r := private.remittance_draft_for_command(p_run_id, p_expected_version, array['admin', 'ops_manager']);
  update private.remittance_pending set draft_run_id = null where draft_run_id = r.id;
  update private.remittance_pending q set draft_run_id = r.id
  where q.organization_id = r.organization_id and q.client_organization_id = r.client_organization_id
    and q.currency = r.currency and q.draft_run_id is null;
  get diagnostics v_n = row_count;
  perform private.remittance_clear_draft(r.id);
  if v_n = 0 then
    update public.remittance_run set status = 'cancelled', job = null, job_token = null, job_queued_at = null,
      cancelled_by = auth.uid(), cancelled_at = clock_timestamp(), cancel_reason = 'Plus rien à reverser',
      item_count = 0, version = version + 1
    where id = r.id;
    v_result := jsonb_build_object('run_id', r.id, 'status', 'cancelled', 'items', 0);
  else
    update public.remittance_run set job = 'prepare', job_token = v_token, job_queued_at = clock_timestamp(),
      known_at = clock_timestamp(), service_to = (clock_timestamp() at time zone 'Europe/Paris')::date,
      prepared_at = null, item_count = v_n, line_count = null, last_failure = null, inputs_hash = null,
      version = version + 1
    where id = r.id;
    perform pgmq.send('remittances', jsonb_build_object('type', 'prepare', 'run_id', r.id, 'token', v_token));
    v_result := jsonb_build_object('run_id', r.id, 'status', 'draft', 'items', v_n);
  end if;
  perform private.command_record('refresh_remittance_run', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Abandonner » a draft (§9.8): its items go back to pending, unreserved.
create or replace function public.discard_remittance_run(p_idempotency_key text, p_run_id uuid,
                                                         p_expected_version integer, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  r public.remittance_run;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('run_id', p_run_id, 'expected_version', p_expected_version, 'reason', v_reason);
  v_result jsonb;
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or not private.has_role(r.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('discard_remittance_run', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  r := private.remittance_draft_for_command(p_run_id, p_expected_version, array['admin', 'ops_manager']);
  update private.remittance_pending set draft_run_id = null where draft_run_id = r.id;
  perform private.remittance_clear_draft(r.id);
  update public.remittance_run set status = 'cancelled', job = null, job_token = null, job_queued_at = null,
    cancelled_by = auth.uid(), cancelled_at = clock_timestamp(), cancel_reason = v_reason, version = version + 1
  where id = r.id;
  v_result := jsonb_build_object('run_id', r.id, 'status', 'cancelled');
  perform private.command_record('discard_remittance_run', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The prepare job's writes (§9.4 step 2): the draft lines (COPY by the job), then the header
------------------------------------------------------------------------------------------

-- The job's turn: the run locked; false when it is no longer this job's (a later « Actualiser », an abandon).
create or replace function private.remittance_prepare_begin(p_run_id uuid, p_token uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run_id for update;
  if not found or r.status <> 'draft' or r.job is distinct from 'prepare' or r.job_token is distinct from p_token then
    return false;
  end if;
  perform private.remittance_clear_draft(p_run_id);
  return true;
end;
$$;

-- The header of a prepared draft. p: {line_count, gross, invoice_ht, invoice_vat, invoice_ttc, credit_ht, credit_vat,
-- credit_ttc, taken, advances, refunds, settlement, net (text amounts), vat_rate, earliest_deadline,
-- earliest_latest_execution_date, unmeetable, blockers, commission_blockers, engine_version, inputs_hash,
-- payout_account_id, history_seq, vat_on_debits, proceeding_opened_on, documents, key_states, plan, repricing}. The
-- lines must be the items reserved.
create or replace function private.remittance_record_draft(p_run_id uuid, p_token uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = ''
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
  select count(*) into v_reserved from private.remittance_pending q
  cross join lateral (select 1 from private.remittance_draft_line d where d.run_id = p_run_id
                        and d.ledger_entry_id = q.ledger_entry_id and d.amount_minor = q.amount_minor
                      limit 1) d
  where q.draft_run_id = p_run_id;
  if v_lines <> r.item_count or v_reserved <> r.item_count or v_gross <> (p ->> 'gross')::bigint
     or v_lines <> (p ->> 'line_count')::integer then
    raise exception 'remittance draft %: its lines are not the items reserved (% lines, % reserved, % items)',
      p_run_id, v_lines, v_reserved, r.item_count using errcode = '23514';
  end if;
  insert into private.remittance_draft (run_id, vat_rate, documents, key_states, history_seq, plan, vat_on_debits,
                                        proceeding_opened_on)
  values (p_run_id, (p ->> 'vat_rate')::numeric, coalesce(p -> 'documents', '[]'), coalesce(p -> 'key_states', '[]'),
          coalesce((p ->> 'history_seq')::bigint, 0), coalesce(p -> 'plan', '{}'),
          coalesce((p ->> 'vat_on_debits')::boolean, false), (p ->> 'proceeding_opened_on')::date);
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

-- A prepare that cannot be done (a data error): the draft says why; « Actualiser » tries again.
create or replace function private.remittance_prepare_failed(p_run_id uuid, p_token uuid, p_code text, p_detail text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.remittance_run set job = null, job_token = null, job_queued_at = null, version = version + 1,
    last_failure = jsonb_build_object('code', p_code, 'detail', left(p_detail, 500), 'at', clock_timestamp(),
                                      'step', 'prepare')
  where id = p_run_id and status = 'draft' and job = 'prepare' and job_token = p_token;
$$;

------------------------------------------------------------------------------------------
-- Issuing invoices and credit notes (§8.4, §14.1; founder #12): numbered in the issuing transaction from the counter
-- row, locked last; dated by the transaction's Paris day, which the clock read after the lock must still be (compliance
-- critique D3; numbering review #1: else 40001, retried); entries posted at once
------------------------------------------------------------------------------------------

-- A party as the document prints it (frozen into the payload; 242 nonies A 1°–2°, R123-237/238, L441-9).
create or replace function private.invoice_party(p_organization_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select private.receipt_issuer(o.id) || jsonb_build_object(
           'billing_address', coalesce(b.billing_address, b.registered_office),
           'vat_number', b.vat_number,
           'is_professional', b.is_professional,
           'invoice_acceptance_ref', b.invoice_acceptance_ref)
  from public.organization o
  left join public.billing_identity b on b.organization_id = o.id
  where o.id = p_organization_id;
$$;

-- Issues the documents `p_docs` (in order; each with its `id`, `key`, kind, mandate_id, amounts as text, lines,
-- charges, allocations, corrections, settlement mode and due days) for a client: one number each, the counter row of
-- the servicer's series and year locked (after the allocation and remit locks the caller holds), dated the
-- transaction's day; their entries in one ledger_post_set, the invoices' VAT in the book `p_vat_on_debits` says (the
-- plan's; null: the servicer's setting); each credit note applied to the invoices it corrects (commission_settlement
-- kind credit_note); the payload frozen with the mentions in force (L441-9). Returns {issue_date, documents: {ref:
-- {id, number}}}.
create or replace function private.issue_commission_documents(p_organization_id uuid, p_client_organization_id uuid,
                                                              p_run_id uuid, p_docs jsonb, p_reason text,
                                                              p_vat_on_debits boolean default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_set public.servicer_billing_settings;
  v_series text;
  v_on_debits boolean;
  v_issue date;
  v_last integer;
  v_n integer := jsonb_array_length(p_docs);
  v_run public.remittance_run;
  v_out jsonb := '{}';
  v_doc record;
  v_seller jsonb;
  v_buyer jsonb;
  v_own jsonb;
  v_indemnity boolean;
  v_pay jsonb;
begin
  if v_n = 0 then
    return jsonb_build_object('issue_date', null, 'documents', '{}'::jsonb);
  end if;
  -- the settings in force at issue, held to the commit (the payload freezes them: L441-9, legal review #4)
  select * into v_set from public.servicer_billing_settings s where s.organization_id = p_organization_id for share;
  v_series := coalesce(v_set.invoice_prefix, 'FC');
  -- the VAT book of the invoices: the one their plan assumed (the approval checked it is still the servicer's), else
  -- the servicer's now (money review #1)
  v_on_debits := coalesce(p_vat_on_debits, v_set.vat_on_debits, false);
  select * into v_run from public.remittance_run where id = p_run_id;
  -- Numbered on the transaction's Paris day: the counter of its year created if needed and locked in one statement
  -- (the year of the issue date). The ledger dates entries up to the transaction's day (paris_today() = now()): a
  -- clock past midnight once the counter is ours means the transaction began the day before; it is retried in a
  -- fresh one rather than refused as data (numbering review #1). The dates then follow the numbers.
  v_issue := private.paris_today();
  insert into private.invoice_counter as c (organization_id, series, year, last_seq, last_issue_date)
  values (p_organization_id, v_series, extract(year from v_issue)::integer, v_n, v_issue)
  on conflict (organization_id, series, year)
    do update set last_seq = c.last_seq + excluded.last_seq, last_issue_date = excluded.last_issue_date
  returning c.last_seq - v_n into v_last;
  if (clock_timestamp() at time zone 'Europe/Paris')::date <> v_issue then
    raise exception 'commission documents: the day turned during the transaction, retry' using errcode = '40001';
  end if;

  -- the parties, the indemnity (L441-10 II, D441-5: 40 € to a professional buyer; not claimed while a proceeding of
  -- the client is recorded, design §14.2), the own account a due invoice is paid to
  v_seller := private.invoice_party(p_organization_id);
  v_buyer := private.invoice_party(p_client_organization_id);
  v_indemnity := coalesce((v_buyer ->> 'is_professional')::boolean, false)
                 and not exists (select 1 from public.client_status_event e
                                 where e.client_organization_id = p_client_organization_id
                                   and e.kind in ('proceeding_opened', 'liquidation') and e.effective_date <= v_issue);
  select jsonb_build_object('iban', b.iban, 'bic', b.bic, 'holder', o.legal_name) into v_own
  from public.bank_account b join public.organization o on o.id = b.organization_id
  where b.id = v_set.own_bank_account_id;
  -- an approval's documents are paid with its run: set off on its payout of the requested date, or on the approval
  -- date when nothing is transferred (N = 0)
  v_pay := case when p_reason = 'commission' and v_run.id is not null
                then jsonb_build_object('run_number', v_run.number,
                                        'execution_date', coalesce(v_run.requested_execution_date, v_issue)) end;

  drop table if exists pg_temp._docs;
  create temp table _docs on commit drop as
  select x.ord::integer as entry_no, (x.doc ->> 'id')::uuid as id, x.doc ->> 'ref' as ref, x.doc ->> 'key' as key,
         x.doc ->> 'kind' as kind, (x.doc ->> 'mandate_id')::uuid as mandate_id,
         (x.doc ->> 'ht')::bigint as ht, (x.doc ->> 'vat')::bigint as vat, (x.doc ->> 'ttc')::bigint as ttc,
         (x.doc ->> 'vat_rate')::numeric as vat_rate,
         case when x.doc ->> 'kind' = 'invoice' and x.doc ->> 'settlement' = 'due' then 'due' else 'netted' end
           as settlement,
         case when x.doc ->> 'kind' = 'invoice' and x.doc ->> 'settlement' = 'due'
              then v_issue + least(coalesce((x.doc ->> 'due_days')::integer, 30), 45) end as due_date,
         (x.doc ->> 'due_days')::integer as due_days, x.doc,
         v_last + x.ord::integer as seq,
         coalesce((select sum((c ->> 'vat_pending')::bigint) from jsonb_array_elements(x.doc -> 'corrections') c), 0)
           as v_pending,
         coalesce((select sum((c ->> 'vat_collected')::bigint) from jsonb_array_elements(x.doc -> 'corrections') c), 0)
           as v_collected
  from jsonb_array_elements(p_docs) with ordinality x (doc, ord);
  if exists (select 1 from pg_temp._docs where kind not in ('invoice', 'credit_note') or ttc <> ht + vat
               or (kind = 'invoice' and (ht <= 0 or vat < 0)) or (kind = 'credit_note' and (ht >= 0 or vat > 0
                   or v_pending + v_collected <> -vat)))
     or exists (select 1 from pg_temp._docs d cross join lateral jsonb_array_elements(coalesce(d.doc -> 'corrections', '[]')) c
                where (c ->> 'vat_pending')::bigint < 0 or (c ->> 'vat_collected')::bigint < 0) then
    raise exception 'commission documents: amounts out of shape' using errcode = '23514';
  end if;

  perform private.ledger_post_set_begin();
  -- the engine and the run's inputs hash on each entry (ADR-0012: what computed it)
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason, engine_version,
                                  inputs_hash)
  select d.entry_no, p_organization_id,
         case d.kind when 'invoice' then 'commission_invoice' else 'commission_credit_note' end, v_issue, d.key,
         p_client_organization_id, 'commission_invoice', d.id::text, null,
         case when v_run.inputs_hash is not null then coalesce(v_run.engine_version, 'commission-1') end,
         v_run.inputs_hash
  from pg_temp._docs d;
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
  select l.entry_no, row_number() over (partition by l.entry_no order by l.o)::integer, l.book, l.amount, 'EUR'
  from (select d.entry_no, 1 as o, 'commission_receivable' as book, d.ttc as amount from pg_temp._docs d
        union all select d.entry_no, 2, 'servicer_revenue', -d.ht from pg_temp._docs d
        union all select d.entry_no, 3, case when v_on_debits then 'vat_collected' else 'vat_pending' end, -d.vat
          from pg_temp._docs d where d.kind = 'invoice' and d.vat > 0
        union all select d.entry_no, 3, 'vat_pending', d.v_pending from pg_temp._docs d
          where d.kind = 'credit_note' and d.v_pending > 0
        union all select d.entry_no, 4, 'vat_collected', d.v_collected from pg_temp._docs d
          where d.kind = 'credit_note' and d.v_collected > 0) l;
  drop table if exists pg_temp._doc_entries;
  create temp table _doc_entries on commit drop as select * from private.ledger_post_set();

  for v_doc in select x.*, e.entry_id from pg_temp._docs x join pg_temp._doc_entries e on e.entry_no = x.entry_no
           order by x.seq loop
    insert into public.commission_invoice (id, organization_id, client_organization_id, mandate_id, run_id, kind,
                                           series, year, seq, number, issue_date, service_from, service_to, currency,
                                           ht_minor, vat_rate, vat_minor, ttc_minor, vat_book, settlement, due_date,
                                           reason, payload, payload_sha256, ledger_entry_id)
    select v_doc.id, p_organization_id, p_client_organization_id, v_doc.mandate_id, p_run_id, v_doc.kind, v_series,
           extract(year from v_issue)::integer, v_doc.seq,
           v_series || '-' || extract(year from v_issue)::integer || '-' || lpad(v_doc.seq::text, 6, '0'), v_issue,
           v_run.service_from, v_run.service_to, 'EUR', v_doc.ht, case when v_doc.kind = 'invoice' then v_doc.vat_rate end, v_doc.vat,
           v_doc.ttc, case when v_doc.kind = 'invoice' then case when v_on_debits then 'vat_collected' else 'vat_pending' end end,
           v_doc.settlement, v_doc.due_date,
           p_reason, y.payload, encode(sha256(convert_to(y.payload::text, 'UTF8')), 'hex'), v_doc.entry_id
    from (select jsonb_build_object(
            'kind', v_doc.kind,
            'number', v_series || '-' || extract(year from v_issue)::integer || '-' || lpad(v_doc.seq::text, 6, '0'),
            'issue_date', v_issue,
            'seller', v_seller,
            'buyer', v_buyer,
            'mandate', (select jsonb_build_object('id', m.id, 'reference', m.reference) from public.mandate m
                        where m.id = v_doc.mandate_id),
            'run', case when v_run.id is not null then jsonb_build_object('id', v_run.id, 'number', v_run.number) end,
            'service_period', jsonb_build_object('from', v_run.service_from, 'to', v_run.service_to),
            'lines', coalesce(v_doc.doc -> 'lines', '[]'),
            'corrections', coalesce(v_doc.doc -> 'corrections', '[]'),
            'totals', jsonb_build_object('ht_minor', v_doc.ht::text, 'vat_minor', v_doc.vat::text, 'ttc_minor', v_doc.ttc::text,
                                         'vat_rate', v_doc.vat_rate::text, 'currency', 'EUR'),
            'settlement', jsonb_build_object('mode', v_doc.settlement, 'clause_ref', v_doc.doc ->> 'clause_ref',
                                             'due_days', v_doc.due_days),
            -- the mentions that change over time, as in force at issue (L441-9 I; legal review #4)
            'due_date', v_doc.due_date,
            'payment_reference', v_pay,
            'own_account', case when v_doc.settlement = 'due' then v_own end,
            'penalty_text', coalesce(v_set.penalty_text,
              'Pénalités de retard : taux d''intérêt appliqué par la Banque centrale européenne à son opération de '
              'refinancement la plus récente, majoré de 10 points de pourcentage.'),
            'flat_indemnity', jsonb_build_object('applies', v_indemnity,
                                                 'amount_minor', case when v_indemnity then '4000' end),
            'vat_on_debits', v_on_debits,
            'reason', p_reason) as payload) y;
    v_out := v_out || jsonb_build_object(v_doc.ref, jsonb_build_object(
      'id', v_doc.id, 'number', v_series || '-' || extract(year from v_issue)::integer || '-' || lpad(v_doc.seq::text, 6, '0')));
  end loop;

  insert into public.commission_invoice_line (invoice_id, line_no, kind, designation_fr, claim_type_code, rule_id,
                                              families, tiers, ht_minor, vat_rate, original_invoice_id)
  select d.id, l.ord::integer, l.line ->> 'kind', l.line ->> 'designation_fr', l.line ->> 'claim_type',
         l.line ->> 'rule_id', coalesce(array(select jsonb_array_elements_text(l.line -> 'families')), '{}'),
         coalesce(l.line -> 'tiers', '[]'), (l.line ->> 'ht')::bigint, (l.line ->> 'vat_rate')::numeric,
         (l.line ->> 'original_invoice_id')::uuid
  from pg_temp._docs d cross join lateral jsonb_array_elements(d.doc -> 'lines') with ordinality l (line, ord);
  insert into public.commission_invoice_charge (invoice_id, account_id, tier_key, charged_minor)
  select d.id, (c ->> 'account_id')::uuid, c ->> 'tier_key', (c ->> 'amount')::bigint
  from pg_temp._docs d cross join lateral jsonb_array_elements(coalesce(d.doc -> 'charges', '[]')) c
  where d.kind = 'invoice';
  insert into public.commission_credit_alloc (credit_note_id, line_no, original_invoice_id, account_id, tier_key,
                                              ht_minor, entry_id)
  select d.id, a.ord::integer, (a.x ->> 'original_invoice_id')::uuid, (a.x ->> 'account_id')::uuid, a.x ->> 'tier_key',
         (a.x ->> 'ht')::bigint, (a.x ->> 'entry_id')::uuid
  from pg_temp._docs d cross join lateral jsonb_array_elements(coalesce(d.doc -> 'allocations', '[]'))
    with ordinality a (x, ord)
  where d.kind = 'credit_note';
  insert into public.commission_credit_correction (credit_note_id, original_invoice_id, vat_rate, ht_minor, vat_minor,
                                                   vat_pending_minor, vat_collected_minor, applied_minor, excess_minor)
  select d.id, (c ->> 'original_invoice_id')::uuid, (c ->> 'vat_rate')::numeric, (c ->> 'ht')::bigint,
         (c ->> 'vat')::bigint, (c ->> 'vat_pending')::bigint, (c ->> 'vat_collected')::bigint,
         (c ->> 'applied')::bigint, (c ->> 'excess')::bigint
  from pg_temp._docs d cross join lateral jsonb_array_elements(coalesce(d.doc -> 'corrections', '[]')) c
  where d.kind = 'credit_note';
  -- A credit note reduces the invoices it corrects first (a price correction, 289 I 5): settled at once.
  insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id,
                                            credit_note_id, entry_id, kind, amount_minor, vat_moved_minor, settled_on,
                                            run_id)
  select p_organization_id, p_client_organization_id, 'invoice', (c ->> 'original_invoice_id')::uuid, d.id, null,
         'credit_note', (c ->> 'applied')::bigint, (c ->> 'vat_pending')::bigint, v_issue, p_run_id
  from pg_temp._docs d cross join lateral jsonb_array_elements(coalesce(d.doc -> 'corrections', '[]')) c
  where d.kind = 'credit_note' and ((c ->> 'applied')::bigint > 0 or (c ->> 'vat_pending')::bigint > 0);
  -- what was credited never exceeds what each invoice charged each key, nor its HT, nor its VAT
  if exists (select 1 from pg_temp._docs d
             join public.commission_credit_alloc a on a.credit_note_id = d.id
             cross join lateral (select ch.charged_minor + coalesce((select sum(x.ht_minor)
                                   from public.commission_credit_alloc x
                                   where x.original_invoice_id = ch.invoice_id and x.account_id = ch.account_id
                                     and x.tier_key = ch.tier_key), 0) as open
                                 from public.commission_invoice_charge ch
                                 where ch.invoice_id = a.original_invoice_id and ch.account_id = a.account_id
                                   and ch.tier_key = a.tier_key) o
             where o.open < 0)
     or exists (select 1 from pg_temp._docs d
                join public.commission_credit_correction c on c.credit_note_id = d.id
                join public.commission_invoice i on i.id = c.original_invoice_id
                cross join lateral (select coalesce(sum(y.ht_minor), 0) as ht, coalesce(sum(y.vat_minor), 0) as vat
                                    from public.commission_credit_correction y
                                    where y.original_invoice_id = i.id) t
                where i.ht_minor + t.ht < 0 or i.vat_minor + t.vat < 0
                   or c.ht_minor <> (select coalesce(sum(a.ht_minor), 0) from public.commission_credit_alloc a
                                     where a.credit_note_id = d.id and a.original_invoice_id = i.id)) then
    raise exception 'commission credit note: more credited than the invoice charged' using errcode = '23514';
  end if;
  return jsonb_build_object('issue_date', v_issue, 'documents', v_out);
end;
$$;

------------------------------------------------------------------------------------------
-- The settlement (§9.6): posted at the payout's debit (M2c-6) — or at approval when nothing is transferred (N = 0)
------------------------------------------------------------------------------------------

-- p_plan: the run's resolved plan (refs → document ids). Posts the client_settlement entry (+4670 D / −4679 D ‖
-- +4689 D / −4111 Dc / −4112 Da ‖ +44574 v / −44571 v; zero lines left out) and its settlement rows. Nothing when
-- D = 0 (§9.6: such a plan settles nothing).
create or replace function private.post_run_settlement(p_run_id uuid, p_plan jsonb, p_on date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.remittance_run;
  v_d bigint := coalesce((p_plan ->> 'settlement')::bigint, 0);
  v_dc bigint := coalesce((p_plan ->> 'dc')::bigint, 0);
  v_da bigint := coalesce((p_plan ->> 'da')::bigint, 0);
  v_vat bigint := coalesce((p_plan ->> 'vat_moved')::bigint, 0);
  v_entry uuid;
begin
  select * into r from public.remittance_run where id = p_run_id;
  if v_d = 0 then
    if exists (select 1 from jsonb_array_elements(coalesce(p_plan -> 'settles', '[]'))) then
      raise exception 'settlement of %: documents to settle with D = 0', r.number using errcode = '23514';
    end if;
    return null;
  end if;
  if v_dc + v_da <> v_d then
    raise exception 'settlement of %: D ≠ Dc + Da', r.number using errcode = '23514';
  end if;
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id)
  values (1, r.organization_id, 'client_settlement', p_on, 'settle:' || r.id, r.client_organization_id,
          'remittance_run', r.id::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
  select 1, row_number() over (order by l.o)::integer, l.book, l.amount, r.currency
  from (values (1, 'client_payable', v_d), (2, 'due_to_servicer', -v_d), (3, 'due_from_client_funds', v_d),
               (4, 'commission_receivable', -v_dc), (5, 'client_advance_receivable', -v_da),
               (6, 'vat_pending', v_vat), (7, 'vat_collected', -v_vat)) l (o, book, amount)
  where l.amount <> 0;
  select x.entry_id into v_entry from private.ledger_post_set() x;
  insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id,
                                            entry_id, kind, amount_minor, vat_moved_minor, settled_on, run_id)
  select r.organization_id, r.client_organization_id,
         case s ->> 'kind' when 'refund' then 'credit_note' when 'advance' then 'advance' else 'invoice' end,
         (s ->> 'document_id')::uuid, v_entry, case s ->> 'kind' when 'advance' then 'compensation' else s ->> 'kind' end,
         (s ->> 'amount')::bigint, (s ->> 'vat_moved')::bigint, p_on, r.id
  from jsonb_array_elements(coalesce(p_plan -> 'settles', '[]')) s;
  return v_entry;
end;
$$;

------------------------------------------------------------------------------------------
-- Approval (§9.5; founder #11: one approver): the command checks what the page showed and queues a job per run
------------------------------------------------------------------------------------------

-- Today is allowed only before the paying account's cut-off (Paris time, « Facturation »): L133-9 « jour convenu ».
create or replace function private.execution_date_refusal(p_organization_id uuid, p_currency char(3), p_date date)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_today date := private.paris_today();
  v_cutoff text;
begin
  if p_date is null or p_date < v_today then
    return 'execution_date_passed';
  end if;
  if not private.is_business_day(p_date) then
    return 'execution_date_not_business_day';
  end if;
  if p_date = v_today then
    select s.bank_cutoff ->> private.paying_account(p_organization_id, p_currency)::text into v_cutoff
    from public.servicer_billing_settings s where s.organization_id = p_organization_id;
    if v_cutoff is null or (clock_timestamp() at time zone 'Europe/Paris')::time >= v_cutoff::time then
      return 'execution_date_after_cutoff';
    end if;
  end if;
  return null;
end;
$$;

-- « Valider » (one or many, ≤ 200): each item {run_id, inputs_hash, net_text} as the page showed it; the requested
-- execution date (default: the next business day) and, when it is after a run's latest execution date, the reason
-- (paying late beats not paying; a breach row is written). Admins and ops managers at aal2.
create or replace function public.approve_remittance_runs(p_idempotency_key text, p_items jsonb,
                                                          p_requested_execution_date date default null,
                                                          p_late_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  v_org uuid;
  v_orgs integer;
  v_request jsonb;
  v_result jsonb;
  v_out jsonb := '[]';
  v_date date;
  v_reason text := nullif(btrim(coalesce(p_late_reason, '')), '');
  v_why text;
  v_token uuid;
  v_found boolean;
  v_busy boolean;
  v_late boolean;
  it record;
  r public.remittance_run;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 200 then
    raise exception 'approval: 1 to 200 runs' using errcode = '22023';
  end if;
  select min(x.organization_id::text)::uuid, count(distinct x.organization_id) into v_org, v_orgs
  from jsonb_array_elements(p_items) e
  left join public.remittance_run x on x.id = (e ->> 'run_id')::uuid;
  if v_orgs <> 1 or not private.has_role(v_org, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('items', p_items, 'requested_execution_date', p_requested_execution_date,
                                  'late_reason', v_reason);
  v_result := private.command_replay('approve_remittance_runs', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  v_date := coalesce(p_requested_execution_date, private.next_business_day(private.paris_today()));
  for it in select (e ->> 'run_id')::uuid as run_id, e ->> 'inputs_hash' as inputs_hash, e ->> 'net_text' as net_text
            from jsonb_array_elements(p_items) e order by (e ->> 'run_id') loop
    -- read first without a lock (an unknown run keeps its reason), then locked without waiting: a run a job or
    -- another command holds is refused alone ('busy') and the others go on (numbering review #2, tests-ui #5)
    select * into r from public.remittance_run where id = it.run_id;
    v_found := found and r.organization_id = v_org;
    v_busy := false;
    if v_found then
      begin
        select * into r from public.remittance_run where id = it.run_id for update nowait;
      exception when lock_not_available then
        v_busy := true;
      end;
    end if;
    v_why := case
      when not v_found then 'unknown_run'
      when v_busy then 'busy'
      when r.status <> 'draft' then 'not_draft'
      when r.job = 'prepare' then 'preparing'
      when r.job = 'approve' then 'approval_in_progress'
      when r.prepared_at is null then 'not_prepared'
      when r.inputs_hash is distinct from it.inputs_hash or r.net_minor::text is distinct from it.net_text then 'stale'
      when r.net_minor < 0 then 'negative_net'
      when r.net_minor > 0 and cardinality(r.blockers) > 0 then 'payout_blocked'
      when r.net_minor > 0 then private.execution_date_refusal(r.organization_id, r.currency, v_date)
      end;
    -- paid after its latest execution date: by the payout's requested date (N > 0), or by the settlement today
    -- (N = 0, money review #3); allowed only with the reason (paying late beats not paying)
    v_late := v_found and not v_busy and coalesce(case when r.net_minor > 0 then v_date
                                                      else private.paris_today() end
                                                 > r.earliest_latest_execution_date, false);
    if v_why is null and v_late and v_reason is null then
      v_why := 'late_reason_required';
    end if;
    if v_why is null then
      v_token := gen_random_uuid();
      update public.remittance_run set job = 'approve', job_token = v_token, job_queued_at = clock_timestamp(),
        requested_execution_date = case when r.net_minor > 0 then v_date end,
        late_reason = case when v_late then v_reason end,
        approval_requested_by = auth.uid(), last_failure = null, version = version + 1
      where id = r.id;
      perform pgmq.send('remittances', jsonb_build_object('type', 'approve', 'run_id', r.id, 'token', v_token));
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('run_id', it.run_id, 'number', r.number,
                                                           'status', case when v_why is null then 'queued'
                                                                          else 'refused' end,
                                                           'reason', v_why));
  end loop;
  v_result := jsonb_build_object('requested_execution_date', v_date, 'results', v_out);
  perform private.command_record('approve_remittance_runs', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- Back to draft with its reason (§9.5: data errors, a stale plan, a timeout, a dead-lettered job). The reservation
-- and the draft stay; the page says why and the run is approved again or « Actualiser ».
create or replace function private.remittance_back_to_draft(p_run_id uuid, p_token uuid, p_code text, p_detail text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.remittance_run set job = null, job_token = null, job_queued_at = null, requested_execution_date = null,
    late_reason = null, version = version + 1,
    last_failure = jsonb_build_object('code', p_code, 'detail', left(coalesce(p_detail, ''), 500),
                                      'at', clock_timestamp(), 'step', 'approve')
  where id = p_run_id and status = 'draft' and job = 'approve' and (p_token is null or job_token = p_token);
$$;

-- What the approval job finds changed since the page showed the run (null: nothing). Read under the run's row lock and
-- the allocation lock.
create or replace function private.remittance_approval_refusal(p_run public.remittance_run,
                                                               p_draft private.remittance_draft, p_today date)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owed bigint;
  v_inflight bigint;
  v_blockers text[];
  v_bad text;
begin
  if p_draft.run_id is null then
    return 'not_prepared';
  end if;
  if (select count(*) from private.remittance_pending q where q.draft_run_id = p_run.id) <> p_run.item_count then
    return 'items_changed';
  end if;
  if jsonb_array_length(p_draft.documents) > 0 and private.vat_rate_on(p_today) <> p_draft.vat_rate then
    return 'vat_rate_changed';
  end if;
  -- the VAT book the plan assumed for the run's invoices (money review #1): 44571 at once on debits, else 44574
  if jsonb_array_length(p_draft.documents) > 0
     and coalesce((select s.vat_on_debits from public.servicer_billing_settings s
                   where s.organization_id = p_run.organization_id), false) <> p_draft.vat_on_debits then
    return 'vat_option_changed';
  end if;
  if jsonb_array_length(p_draft.documents) > 0
     and cardinality(private.remittance_commission_blockers(p_run.client_organization_id)) > 0 then
    return 'commission_blocked';
  end if;
  -- the client's proceeding the plan's set-offs assumed (§9.6, L622-7 I; money review #2): recorded or in force since
  if exists (select 1 from jsonb_array_elements(coalesce(p_draft.plan -> 'settles', '[]')) s
             where s ->> 'kind' in ('compensation', 'advance'))
     and (select min(e.effective_date) from public.client_status_event e
          where e.client_organization_id = p_run.client_organization_id and e.kind = 'proceeding_opened'
            and e.effective_date <= p_today) is distinct from p_draft.proceeding_opened_on then
    return 'client_status_changed';
  end if;
  if p_run.net_minor > 0 then
    v_blockers := private.remittance_payout_blockers(p_run.client_organization_id, p_run.currency, p_today);
    if cardinality(v_blockers) > 0 then
      return 'payout_blocked:' || v_blockers[1];
    end if;
    if p_run.payout_account_id is distinct from (
         select pa.id from public.client_payout_account pa
         where pa.client_organization_id = p_run.client_organization_id and pa.currency = p_run.currency
           and pa.status = 'active') then
      return 'payout_account_changed';
    end if;
    v_bad := private.execution_date_refusal(p_run.organization_id, p_run.currency, p_run.requested_execution_date);
    if v_bad is not null then
      return v_bad;
    end if;
    if p_run.requested_execution_date > p_run.earliest_latest_execution_date and p_run.late_reason is null then
      return 'late_reason_required';
    end if;
  end if;
  -- N = 0 settles today: after the latest execution date, the reason too (money review #3)
  if p_run.net_minor = 0 and p_today > p_run.earliest_latest_execution_date and p_run.late_reason is null then
    return 'late_reason_required';
  end if;
  if p_run.net_minor < 0 then
    return 'negative_net';
  end if;
  -- the cap (§9.5, ledger critique #1): gross ≤ what the client is owed less the runs in flight
  select -b.balance_minor into v_owed from private.client_payable_balance b
  where b.client_organization_id = p_run.client_organization_id and b.currency = p_run.currency;
  select coalesce(sum(x.net_minor + x.settlement_minor), 0) into v_inflight from public.remittance_run x
  where x.client_organization_id = p_run.client_organization_id and x.currency = p_run.currency
    and x.status in ('approved', 'sent') and x.id <> p_run.id;
  if p_run.gross_minor > coalesce(v_owed, 0) - v_inflight then
    return 'balance_changed';
  end if;
  -- the tier history and the documents the plan continued from (the run's own key states, written before the locks
  -- in this transaction, excepted)
  if coalesce((select max(k.seq) from public.remittance_key_state k
               where k.client_organization_id = p_run.client_organization_id and k.run_id <> p_run.id), 0)
     <> p_draft.history_seq then
    return 'history_changed';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_draft.plan -> 'settles', '[]')) s
             where (s ->> 'ref') !~ '^new' and private.document_open((s ->> 'ref')::uuid) <> (s ->> 'open_before')::bigint)
     or exists (select 1 from jsonb_array_elements(p_draft.documents) d
                cross join lateral jsonb_array_elements(coalesce(d -> 'corrections', '[]')) c
                where private.document_open((c ->> 'original_invoice_id')::uuid) <> (c ->> 'open_before')::bigint) then
    return 'documents_changed';
  end if;
  return null;
end;
$$;

-- A document's open part: an invoice's TTC not settled; a credit note's refund still owed; an advance's (M2c-7).
create or replace function private.document_open(p_document_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case i.kind
           when 'invoice' then i.ttc_minor - coalesce((select sum(s.amount_minor) from public.commission_settlement s
                                                       where s.document_id = i.id), 0)
           else -i.ttc_minor
                - coalesce((select sum(s.amount_minor) from public.commission_settlement s
                            where s.credit_note_id = i.id), 0)
                - coalesce((select sum(s.amount_minor) from public.commission_settlement s
                            where s.document_id = i.id and s.kind = 'refund'), 0) end
  from public.commission_invoice i where i.id = p_document_id;
$$;

-- The pending VAT of an invoice (44574 for its open part).
create or replace function private.document_pending_vat(p_document_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case when i.kind = 'invoice' and i.vat_book = 'vat_pending'
              then i.vat_minor - coalesce((select sum(s.vat_moved_minor) from public.commission_settlement s
                                           where s.document_id = i.id), 0)
              else 0 end
  from public.commission_invoice i where i.id = p_document_id;
$$;

-- The approval job's transaction for one run (§9.5 steps 1–6). Returns {status: approved | booked | back_to_draft |
-- skipped, reason}. Business refusals send the run back to draft here; a data error raised inside is caught by the job
-- (a savepoint) and sent back the same way.
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
    -- the lines, their repricings and the tier history depend only on the draft and on immutable entries; the
    -- refusal below rolls them back with this block. Holding the allocation lock is then the checks, the queue, the
    -- documents and the payout (each item in exactly one live line, I15).
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
                                             cause, basis, kept_basis_minor, kept_minor, commission_minor)
    select r.organization_id, r.client_organization_id, (k ->> 'account_id')::uuid, k ->> 'tier_key', r.id, 'approved',
           coalesce(k -> 'basis', '[]'), (k ->> 'kept_basis')::bigint, (k ->> 'kept')::bigint,
           (k ->> 'commission')::bigint
    from jsonb_array_elements(coalesce(d.key_states, '[]')) k;

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
    v_issued := private.issue_commission_documents(r.organization_id, r.client_organization_id, r.id, v_docs,
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

-- The lines of an approved run paid after their latest execution date (§9.5 step 2: approved late with its reason):
-- a breach row per item unless the nightly checks wrote it first (I21; one per item, append-only), and the late
-- approval itself, always (review M2c-4: tests-ui #2, legal #8). p_paid_on: the payout's requested execution date, or
-- the settlement date when N = 0.
create or replace function private.remittance_late_lines(r public.remittance_run, p_paid_on date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if r.earliest_latest_execution_date is null or p_paid_on <= r.earliest_latest_execution_date then
    return;   -- no line late (the header's earliest date is the lines' minimum)
  end if;
  insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                 run_id, deadline, latest_execution_date, requested_execution_date,
                                                 blocked_reason, late_reason)
  select r.organization_id, r.client_organization_id, l.ledger_entry_id, l.payment_id, r.id, l.deadline,
         l.latest_execution_date, p_paid_on, case when l.unmeetable then 'unmeetable_delay' end, r.late_reason
  from public.remittance_line l
  where l.run_id = r.id and l.amount_minor > 0 and l.latest_execution_date < p_paid_on
  on conflict (ledger_entry_id) do nothing;
  insert into public.remittance_late_approval (run_id, ledger_entry_id, organization_id, client_organization_id,
                                               latest_execution_date, requested_execution_date, late_reason,
                                               approved_by)
  select r.id, l.ledger_entry_id, r.organization_id, r.client_organization_id, l.latest_execution_date, p_paid_on,
         r.late_reason, r.approval_requested_by
  from public.remittance_line l
  where l.run_id = r.id and l.amount_minor > 0 and l.latest_execution_date < p_paid_on;
end;
$$;

------------------------------------------------------------------------------------------
-- Cancellation of an approved run before its transfer is in a file (§9.7; the attestation path after download is
-- M2c-6's): the transfer cancelled, one full credit note per invoice of the run and one corrective invoice restoring
-- what its credit notes took back from earlier invoices (numbers never reused), the lines released and their items
-- back to pending, the tier history exactly as before the run. Nothing else is reversed: the settlement is not booked
-- before the debit. One synchronous command within the API's 8 s at 50k lines (performance review #1).
------------------------------------------------------------------------------------------

-- The servicer's allocation lock (and, for what numbers documents, the remit lock) taken by a command: a wait past the
-- command's lock timeout (an allocation, or an approval job holding it while it numbers and orders) is refused with a
-- reason the page says (« réessayez »), not the database's text (performance review #4).
create or replace function private.remittance_command_locks(p_organization_id uuid, p_remit boolean default false)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  if p_remit then
    perform pg_advisory_xact_lock(hashtext('remit:' || p_organization_id::text));
  end if;
exception when lock_not_available then
  raise exception 'remittance run refused: allocation_busy' using errcode = '55P03',
    hint = 'An allocation or an approval of this servicer holds the lock: retry in a few seconds.';
end;
$$;

create or replace function public.cancel_remittance_run(p_idempotency_key text, p_run_id uuid,
                                                        p_expected_version integer, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  r public.remittance_run;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('run_id', p_run_id, 'expected_version', p_expected_version, 'reason', v_reason);
  v_result jsonb;
  v_docs jsonb;
  v_restore jsonb;
  v_issued jsonb;
  v_n integer;
  v_today date := private.paris_today();
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or not private.has_role(r.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('cancel_remittance_run', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  select * into r from public.remittance_run where id = p_run_id for update;
  perform private.remittance_command_locks(r.organization_id, true);
  if r.status <> 'approved' then
    raise exception 'remittance run refused: %', case r.status when 'draft' then 'draft_use_discard'
                                                               when 'sent' then 'already_sent'
                                                               else 'not_cancellable' end
      using errcode = 'check_violation';
  end if;
  if p_expected_version is distinct from r.version then
    raise exception 'remittance run refused: version_changed' using errcode = 'check_violation';
  end if;
  update public.bank_transfer set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = clock_timestamp(),
    cancel_reason = 'Reversement ' || r.number || ' annulé : ' || v_reason
  where run_id = r.id and kind = 'payout' and status = 'ordered';
  if exists (select 1 from public.bank_transfer t where t.run_id = r.id and t.status not in ('ordered', 'cancelled')) then
    raise exception 'remittance run refused: transfer_in_file' using errcode = 'check_violation';
  end if;

  -- 1. one full credit note per invoice of the run: what each still charges each key, its VAT by cumulative
  -- difference at the invoice's own rate, off its pending VAT first
  with inv as (
    select i.*, coalesce((select -sum(c.ht_minor) from public.commission_credit_correction c
                          where c.original_invoice_id = i.id), 0) as credited_before,
           private.document_open(i.id) as open_before, private.document_pending_vat(i.id) as pending_before
    from public.commission_invoice i where i.run_id = r.id and i.kind = 'invoice' and i.reason = 'commission'),
  keys as (
    select i.id as invoice_id, ch.account_id, ch.tier_key,
           ch.charged_minor + coalesce((select sum(a.ht_minor) from public.commission_credit_alloc a
                                        where a.original_invoice_id = ch.invoice_id and a.account_id = ch.account_id
                                          and a.tier_key = ch.tier_key), 0) as open
    from inv i join public.commission_invoice_charge ch on ch.invoice_id = i.id),
  amounts as (
    select i.*, k.ht, round((i.credited_before + k.ht) * i.vat_rate) - round(i.credited_before * i.vat_rate) as vat
    from inv i join (select invoice_id, sum(open) as ht from keys where open > 0 group by invoice_id) k
      on k.invoice_id = i.id)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', gen_random_uuid(), 'ref', 'cancel:' || a.id, 'key', 'crn-cancel:' || a.id, 'kind', 'credit_note',
           'mandate_id', a.mandate_id, 'ht', (-a.ht)::text, 'vat', (-a.vat)::bigint::text,
           'ttc', (-a.ht - a.vat)::bigint::text,
           'lines', jsonb_build_array(jsonb_build_object(
             'kind', 'credit', 'designation_fr', 'Annulation du reversement ' || r.number || ' — avoir rectifiant la '
                                                  || 'facture ' || a.number || ' du ' || to_char(a.issue_date, 'DD/MM/YYYY'),
             'ht', (-a.ht)::text, 'vat_rate', a.vat_rate::text, 'original_invoice_id', a.id)),
           'allocations', (select jsonb_agg(jsonb_build_object('original_invoice_id', k.invoice_id,
                                                               'account_id', k.account_id, 'tier_key', k.tier_key,
                                                               'ht', (-k.open)::text)
                                            order by k.account_id, k.tier_key)
                           from keys k where k.invoice_id = a.id and k.open > 0),
           'corrections', jsonb_build_array(jsonb_build_object(
             'original_invoice_id', a.id, 'vat_rate', a.vat_rate::text, 'ht', (-a.ht)::text,
             'vat', (-a.vat)::bigint::text,
             'vat_pending', least(a.vat::bigint, a.pending_before)::text,
             'vat_collected', (a.vat::bigint - least(a.vat::bigint, a.pending_before))::text,
             'applied', least(a.ht + a.vat::bigint, a.open_before)::text,
             'excess', (a.ht + a.vat::bigint - least(a.ht + a.vat::bigint, a.open_before))::text,
             'open_before', a.open_before::text))) order by a.seq), '[]')
  into v_docs from amounts a;

  -- 2. the run's own credit notes on earlier invoices undone (money review #0): per mandate and VAT rate, one corrective
  -- invoice charging again, per (file, tier key), what they took back — its HT and VAT exactly what they credited, at
  -- each credited invoice's own rate — so that the tier history goes back exactly as before the run and the next run
  -- credits each reversal once (on this invoice: it charges the line now). Settled as the mandate's terms say today.
  with crd as (   -- per credit note of the run and invoice it corrected: what it took back
    select cn.mandate_id, cn.number as credit_number, c.original_invoice_id, o.number as original_number,
           o.issue_date as original_date, o.vat_rate, -c.ht_minor as ht, -c.vat_minor as vat, cn.seq
    from public.commission_invoice cn
    join public.commission_credit_correction c on c.credit_note_id = cn.id
    join public.commission_invoice o on o.id = c.original_invoice_id
    where cn.run_id = r.id and cn.kind = 'credit_note' and cn.reason = 'commission'),
  keys as (       -- per mandate, rate and (file, tier key): what they took back
    select cn.mandate_id, o.vat_rate, a.account_id, a.tier_key, -sum(a.ht_minor) as ht
    from public.commission_invoice cn
    join public.commission_credit_alloc a on a.credit_note_id = cn.id
    join public.commission_invoice o on o.id = a.original_invoice_id
    where cn.run_id = r.id and cn.kind = 'credit_note' and cn.reason = 'commission'
    group by cn.mandate_id, o.vat_rate, a.account_id, a.tier_key),
  docs as (
    select x.mandate_id, x.vat_rate, sum(x.ht) as ht, sum(x.vat) as vat, m.reference,
           (select mt.remittance_terms from public.mandate_terms mt
            where mt.mandate_id = x.mandate_id and mt.valid_from <= v_today
              and (mt.valid_to is null or v_today < mt.valid_to)
            order by mt.valid_from desc limit 1) as terms
    from crd x join public.mandate m on m.id = x.mandate_id
    group by x.mandate_id, x.vat_rate, m.reference)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', gen_random_uuid(), 'ref', 'restore:' || d.mandate_id || ':' || d.vat_rate,
           'key', 'inv-restore:' || r.id || ':' || d.mandate_id || ':' || d.vat_rate, 'kind', 'invoice',
           'mandate_id', d.mandate_id, 'ht', d.ht::text, 'vat', d.vat::text, 'ttc', (d.ht + d.vat)::text,
           'vat_rate', d.vat_rate::text,
           'settlement', case when jsonb_typeof(d.terms -> 'netting') = 'object' then 'netted' else 'due' end,
           'due_days', case when jsonb_typeof(d.terms -> 'netting') = 'object' then null
                            else coalesce((d.terms ->> 'invoice_payment_days')::integer, 30) end,
           'clause_ref', d.terms #>> '{netting,clause_ref}',
           'lines', (select jsonb_agg(jsonb_build_object(
                       'kind', 'commission',
                       'designation_fr', 'Annulation du reversement ' || r.number || ' — rétablissement de l''avoir '
                                         || x.credit_number || ' (facture ' || x.original_number || ' du '
                                         || to_char(x.original_date, 'DD/MM/YYYY') || ')',
                       'ht', x.ht::text, 'vat_rate', x.vat_rate::text) order by x.seq, x.original_number)
                     from crd x where x.mandate_id = d.mandate_id and x.vat_rate = d.vat_rate),
           'charges', (select jsonb_agg(jsonb_build_object('account_id', k.account_id, 'tier_key', k.tier_key,
                                                           'amount', k.ht::text) order by k.account_id, k.tier_key)
                       from keys k where k.mandate_id = d.mandate_id and k.vat_rate = d.vat_rate))
           order by d.reference, d.mandate_id, d.vat_rate), '[]')
  into v_restore from docs d;
  v_issued := private.issue_commission_documents(r.organization_id, r.client_organization_id, r.id,
                                                 v_docs || v_restore, 'run_cancelled');

  -- 3. the lines released, their items back in the queue (posted when they were); the history exactly as before the
  -- run (its documents credited or restored: what the invoices still charge each key is that state's commission)
  update public.remittance_line set released = true, released_at = clock_timestamp() where run_id = r.id;
  get diagnostics v_n = row_count;
  insert into private.remittance_pending (ledger_entry_id, organization_id, client_organization_id, currency, kind,
                                          amount_minor, posted_at)
  select l.ledger_entry_id, l.organization_id, l.client_organization_id, l.currency, l.kind, l.amount_minor, l.posted_at
  from public.remittance_line l where l.run_id = r.id;
  insert into public.remittance_key_state (organization_id, client_organization_id, account_id, tier_key, run_id, cause,
                                           basis, kept_basis_minor, kept_minor, commission_minor)
  select r.organization_id, r.client_organization_id, k.account_id, k.tier_key, r.id, 'cancelled',
         coalesce(p.basis, '[]'), coalesce(p.kept_basis_minor, 0), coalesce(p.kept_minor, 0),
         coalesce(p.commission_minor, 0)
  from public.remittance_key_state k
  left join lateral (select x.basis, x.kept_basis_minor, x.kept_minor, x.commission_minor
                     from public.remittance_key_state x
                     where x.account_id = k.account_id and x.tier_key = k.tier_key and x.seq < k.seq
                     order by x.seq desc limit 1) p on true
  where k.run_id = r.id and k.cause = 'approved';
  -- (the engine's input check where the run credited earlier invoices — elsewhere the run's invoice is credited in
  -- full: what the invoices still charge each key it credited is the state's commission again; keyed, per such key)
  if exists (select 1
             from (select distinct a.account_id, a.tier_key from public.commission_invoice cn
                   join public.commission_credit_alloc a on a.credit_note_id = cn.id
                   where cn.run_id = r.id and cn.kind = 'credit_note' and cn.reason = 'commission' offset 0) x
             cross join lateral (select k.commission_minor from public.remittance_key_state k
                                 where k.account_id = x.account_id and k.tier_key = x.tier_key
                                 order by k.seq desc limit 1) st
             cross join lateral (select coalesce(sum(ch.charged_minor + coalesce(
                                   (select sum(a.ht_minor) from public.commission_credit_alloc a
                                    where a.original_invoice_id = ch.invoice_id and a.account_id = ch.account_id
                                      and a.tier_key = ch.tier_key), 0)), 0) as open
                                 from public.commission_invoice_charge ch
                                 where ch.account_id = x.account_id and ch.tier_key = x.tier_key) o
             where o.open <> st.commission_minor) then
    raise exception 'cancellation of %: the tier history and the documents disagree', r.number using errcode = '23514';
  end if;
  update public.remittance_run set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = clock_timestamp(),
    cancel_reason = v_reason, version = version + 1
  where id = r.id;
  v_result := jsonb_build_object('run_id', r.id, 'status', 'cancelled', 'lines_released', v_n,
                                 'credit_notes', v_issued -> 'documents');
  perform private.command_record('cancel_remittance_run', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- Deadlines of the items not yet in an approved run (§9.2: one deadline per distinct (E, delay), not per line)
------------------------------------------------------------------------------------------

-- The positive collections waiting in the queue (reserved by a draft or not) with their R124-6 dates: E from their
-- payment, the delay of their file's mandate version on E (one month when none: R124-6 « un mois »).
create or replace function private.pending_item_deadlines(p_organization_id uuid)
returns table (ledger_entry_id uuid, client_organization_id uuid, currency char(3), amount_minor bigint,
               draft_run_id uuid, payment_id uuid, has_terms boolean, encaissement_date date, deadline date,
               latest_execution_date date, alert_soon_date date, alert_critical_date date, unmeetable boolean)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with items as materialized (
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, e.payment_id,
           x.e_date, t.days
    from private.remittance_pending q
    join lateral (select le.payment_id, le.account_id from public.ledger_entry le
                  where le.id = q.ledger_entry_id offset 0) e on true
    left join lateral (select private.encaissement_date(p.booking_date, p.value_date) as e_date,
                              coalesce(e.account_id, p.account_id) as account_id
                       from public.payment p where p.id = e.payment_id offset 0) x on true
    left join lateral (select mt.remittance_max_days as days
                       from public.account a
                       join public.portfolio pf on pf.id = a.portfolio_id
                       join public.mandate_terms mt on mt.mandate_id = pf.mandate_id and mt.valid_from <= x.e_date
                         and (mt.valid_to is null or x.e_date < mt.valid_to)
                       where a.id = x.account_id
                       limit 1) t on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind in ('allocation', 'forward')),
  dl as (
    select k.e_date, k.days, d.*
    from (select distinct i.e_date, coalesce(i.days, 30) as days from items i where i.e_date is not null) k
    cross join lateral private.remittance_deadline(k.e_date, k.days) d)
  select i.ledger_entry_id, i.client_organization_id, i.currency, i.amount_minor, i.draft_run_id, i.payment_id,
         i.days is not null, i.e_date, dl.deadline, dl.latest_execution_date, dl.alert_soon_date, dl.alert_critical_date,
         dl.unmeetable
  from items i left join dl on dl.e_date = i.e_date and dl.days = coalesce(i.days, 30);
$$;

------------------------------------------------------------------------------------------
-- The schedule (§9.3; founder #1): pg_cron hourly → one worker job per servicer, which decides once per Paris business
-- date (the 1st and 16th or the mandate's weekday, the deadline guard, a payout come back) with the pure engines and
-- creates the drafts (`private.create_remittance_run`, key sched:<client>:<currency>:<date>); it also sends back to
-- draft an approval stuck for more than 10 minutes (ledger critique #24) and queues again a stuck prepare.
------------------------------------------------------------------------------------------

create or replace function private.queue_remittance_schedule()
returns integer
language sql
security definer
set search_path = ''
as $$
  with orgs as (
    select o.id from public.organization o
    where o.kind = 'servicer'
      and (exists (select 1 from private.remittance_pending q where q.organization_id = o.id)
           or exists (select 1 from public.remittance_run r where r.organization_id = o.id and r.job is not null))),
  sent as (select pgmq.send('remittances', jsonb_build_object('type', 'schedule', 'organization_id', id)) as m
           from orgs)
  select count(*)::integer from sent;
$$;
select cron.schedule('remittances-schedule', '7 * * * *', 'select private.queue_remittance_schedule()');

-- What the schedule job reads: per (client, currency) with unreserved items and no pending run, the client's
-- remittance terms in force today, whether a payout came back, and the latest execution dates of its positive items.
create or replace function private.remittance_schedule_candidates(p_organization_id uuid, p_today date)
returns table (client_organization_id uuid, currency char(3), terms jsonb[], payout_returned boolean,
               latest_execution_dates date[])
language sql
stable
security definer
set search_path = ''
as $$
  with c as (
    select q.client_organization_id, q.currency, bool_or(q.kind = 'payout_returned') as payout_returned
    from private.remittance_pending q
    where q.organization_id = p_organization_id and q.draft_run_id is null
    group by q.client_organization_id, q.currency),
  d as (select * from private.pending_item_deadlines(p_organization_id) where draft_run_id is null)
  select c.client_organization_id, c.currency,
         coalesce((select array_agg(mt.remittance_terms order by mt.id) from public.mandate m
                   join public.mandate_terms mt on mt.mandate_id = m.id and mt.valid_from <= p_today
                     and (mt.valid_to is null or p_today < mt.valid_to)
                   where m.client_organization_id = c.client_organization_id and mt.remittance_terms is not null),
                  '{}'),
         c.payout_returned,
         coalesce((select array_agg(d.latest_execution_date order by d.latest_execution_date) from d
                   where d.client_organization_id = c.client_organization_id and d.currency = c.currency
                     and d.latest_execution_date is not null), '{}')
  from c
  where not exists (select 1 from public.remittance_run r where r.client_organization_id = c.client_organization_id
                      and r.currency = c.currency and r.status in ('draft', 'approved', 'sent'));
$$;

-- Jobs stuck in flight (§9.5: an approval over 10 minutes goes back to draft; a prepare is queued again).
create or replace function private.remittance_stuck_jobs(p_organization_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_n integer := 0;
  v_token uuid;
begin
  for r in select x.id, x.job, x.job_token from public.remittance_run x
           where x.organization_id = p_organization_id and x.job is not null
             and x.job_queued_at < clock_timestamp() - interval '10 minutes'
           for update skip locked loop
    if r.job = 'approve' then
      perform private.remittance_back_to_draft(r.id, r.job_token, 'approval_timeout', 'more than 10 minutes in the job');
    else
      v_token := gen_random_uuid();
      update public.remittance_run set job_token = v_token, job_queued_at = clock_timestamp() where id = r.id;
      perform pgmq.send('remittances', jsonb_build_object('type', 'prepare', 'run_id', r.id, 'token', v_token));
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

------------------------------------------------------------------------------------------
-- Nightly checks (§15): I14–I17 (and I18), the R124-6 deadline alerts and breach rows (I21), the runs' alerts, the
-- reference-data alerts of M2c-3. Added to every payments check run when it finishes (a trigger on
-- payment_check_run: the payments checks are not copied here), each check one statement.
------------------------------------------------------------------------------------------

create or replace function private.run_remittance_checks(p_check_run_id uuid, p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := private.paris_today();
begin
  -- I21: a positive item not paid by its latest execution date: a breach row, once (an unmeetable delay recorded as
  -- such, not as an operational breach: M2c-3, OQ-71)
  insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                 run_id, deadline, latest_execution_date, blocked_reason)
  select p_organization_id, d.client_organization_id, d.ledger_entry_id, d.payment_id, d.draft_run_id, d.deadline,
         d.latest_execution_date, case when d.unmeetable then 'unmeetable_delay' end
  from private.pending_item_deadlines(p_organization_id) d
  where d.has_terms and d.latest_execution_date < v_today
  on conflict (ledger_entry_id) do nothing;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, u.code, u.severity, u.subject_type, u.subject_id, u.currency,
         u.amount_minor, u.count, u.oldest_days, coalesce(u.details, '{}')
  from (
  with dl as materialized (select * from private.pending_item_deadlines(p_organization_id) where has_terms)
  -- (I14 is in run_payment_checks)
  -- I15: an item both waiting and in a live line
  select 'remittance_item_twice'::text, 'violation'::text, 'ledger_entry'::text, q.ledger_entry_id, q.currency::char(3),
         q.amount_minor::bigint, null::integer, null::integer, '{}'::jsonb
  from private.remittance_pending q
  join public.remittance_line l on l.ledger_entry_id = q.ledger_entry_id and not l.released
  where q.organization_id = p_organization_id
  union all
  -- I16: a run's arithmetic — gross = Σ lines, N + D = gross, N ≥ 0, the payout = N, documents' HT = Σ line commissions
  select 'remittance_run_totals', 'violation', 'remittance_run', r.id, r.currency, r.gross_minor, null, null,
         jsonb_build_object('number', r.number, 'lines_minor', s.gross::text, 'documents_ht_minor', s.docs::text,
                            'commission_minor', s.commission::text)
  from public.remittance_run r
  cross join lateral (
    select (select coalesce(sum(l.amount_minor), 0) from public.remittance_line l where l.run_id = r.id) as gross,
           (select count(*) from public.remittance_line l where l.run_id = r.id) as n,
           (select coalesce(sum(i.ht_minor), 0) from public.commission_invoice i
            where i.run_id = r.id and i.reason = 'commission') as docs,
           (select coalesce(sum(l.commission_minor), 0) from public.remittance_line l
            where l.run_id = r.id and l.commission_state = 'charged')
           + (select coalesce(sum(x.commission_minor), 0) from public.remittance_line_repricing x
              where x.pricing_run_id = r.id and x.commission_state = 'charged') as commission,
           (select t.amount_minor from public.bank_transfer t where t.id = r.transfer_id) as payout) s
  where r.organization_id = p_organization_id and r.status in ('approved', 'sent', 'booked', 'cancelled')
    and r.approved_at is not null
    and (s.gross <> r.gross_minor or s.n <> r.line_count or r.net_minor < 0
         or r.net_minor + r.settlement_minor <> r.gross_minor or s.docs <> s.commission
         or (r.status <> 'cancelled' and r.net_minor > 0 and s.payout is distinct from r.net_minor)
         or (r.net_minor = 0 and r.transfer_id is not null))
  union all
  -- I17 numbering: per series and year, 1…n with no gap, the counter at n, dates never going back
  select 'invoice_numbering', 'violation', 'servicer', null, null, null, x.n::integer, null,
         jsonb_build_object('series', x.series, 'year', x.year, 'max_seq', x.mx, 'counter', c.last_seq,
                            'dates_back', x.back)
  from (select i.series, i.year, count(*) as n, max(i.seq) as mx, min(i.seq) as mn,
               bool_or(i.issue_date < i.prev_date) as back
        from (select y.*, lag(y.issue_date) over (partition by y.series, y.year order by y.seq) as prev_date
              from public.commission_invoice y where y.organization_id = p_organization_id) i
        group by i.series, i.year) x
  left join private.invoice_counter c on c.organization_id = p_organization_id and c.series = x.series
    and c.year = x.year
  where x.n <> x.mx or x.mn <> 1 or c.last_seq is distinct from x.mx or x.back
  union all
  -- I17 ledger: each document's entry is the document (4111 = TTC, 7060 = −HT)
  select 'invoice_ledger', 'violation', 'commission_invoice', i.id, i.currency, i.ttc_minor, null, null,
         jsonb_build_object('number', i.number, 'receivable_minor', e.receivable::text, 'revenue_minor', e.revenue::text)
  from public.commission_invoice i
  cross join lateral (
    select coalesce(sum(p.amount_minor) filter (where la.book = 'commission_receivable'), 0) as receivable,
           coalesce(sum(p.amount_minor) filter (where la.book = 'servicer_revenue'), 0) as revenue
    from public.ledger_posting p join public.ledger_account la on la.id = p.ledger_account_id
    where p.entry_id = i.ledger_entry_id) e
  where i.organization_id = p_organization_id and (e.receivable <> i.ttc_minor or e.revenue <> -i.ht_minor)
  union all
  -- I18: per client, Σ open invoices − Σ refunds owed = 4111[c]; 44574 = Σ pending VAT of the documents
  select 'settlement_ledger', 'violation', 'client', y.client_organization_id, 'EUR', (y.ledger - y.docs)::bigint, null,
         null, jsonb_build_object('documents_minor', y.docs::text, 'ledger_minor', y.ledger::text)
  from (select c.client_organization_id,
               coalesce((select sum(private.document_open(i.id) * case i.kind when 'invoice' then 1 else -1 end)
                         from public.commission_invoice i where i.client_organization_id = c.client_organization_id),
                        0) as docs,
               coalesce((select sum(p.amount_minor) from public.ledger_account la
                         join public.ledger_posting p on p.ledger_account_id = la.id
                         where la.book = 'commission_receivable' and la.client_organization_id = c.client_organization_id),
                        0) as ledger
        from (select distinct i.client_organization_id from public.commission_invoice i
              where i.organization_id = p_organization_id) c) y
  where y.docs <> y.ledger
  union all
  select 'vat_pending_ledger', 'violation', 'servicer', null, 'EUR', (v.ledger - v.docs)::bigint, null, null,
         jsonb_build_object('documents_minor', v.docs::text, 'ledger_minor', v.ledger::text)
  from (select coalesce((select sum(private.document_pending_vat(i.id)) from public.commission_invoice i
                         where i.organization_id = p_organization_id and i.kind = 'invoice'), 0) as docs,
               coalesce((select -sum(p.amount_minor) from public.ledger_account la
                         join public.ledger_posting p on p.ledger_account_id = la.id
                         where la.organization_id = p_organization_id and la.book = 'vat_pending'), 0) as ledger) v
  where v.docs <> v.ledger
  union all
  -- I21: items past their latest execution date, not paid (violation), or whose delay could not be met (alert)
  select case when bool_and(d.unmeetable) then 'remittance_delay_unmeetable' else 'remittance_deadline_breached' end,
         case when bool_and(d.unmeetable) then 'alert' else 'violation' end, 'client', d.client_organization_id,
         d.currency, sum(d.amount_minor)::bigint, count(*)::integer, max(v_today - d.latest_execution_date),
         jsonb_build_object('earliest_latest_execution_date', min(d.latest_execution_date),
                            'ids', (array_agg(d.ledger_entry_id order by d.latest_execution_date))[1:50])
  from dl d where d.latest_execution_date < v_today
  group by d.client_organization_id, d.currency, d.unmeetable
  union all
  -- due soon (D-5 business days) and critical (D-1): per client, the earliest date
  select case when min(d.alert_critical_date) <= v_today then 'remittance_due_critical' else 'remittance_due_soon' end,
         'alert', 'client', d.client_organization_id, d.currency, sum(d.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('earliest_latest_execution_date', min(d.latest_execution_date))
  from dl d where d.latest_execution_date >= v_today and d.alert_soon_date <= v_today
  group by d.client_organization_id, d.currency
  union all
  -- a draft whose payout is blocked, with its reason and its deadline
  select 'payout_blocked', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null, null,
         jsonb_build_object('number', r.number, 'blockers', to_jsonb(r.blockers),
                            'earliest_latest_execution_date', r.earliest_latest_execution_date)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status = 'draft' and r.net_minor > 0
    and cardinality(r.blockers) > 0
  union all
  -- a draft waiting more than one business day; an approval more than 2 business days after K (invoice_late)
  select 'draft_waiting', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null,
         private.business_days_between((r.prepared_at at time zone 'Europe/Paris')::date, v_today),
         jsonb_build_object('number', r.number)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status = 'draft' and r.prepared_at is not null
    and private.business_days_between((r.prepared_at at time zone 'Europe/Paris')::date, v_today) > 1
  union all
  select 'invoice_late', 'alert', 'remittance_run', r.id, r.currency, r.invoice_ttc_minor, null, null,
         jsonb_build_object('number', r.number, 'known_at', r.known_at, 'approved_at', r.approved_at)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.invoice_late and r.approved_at > clock_timestamp() - interval '30 days'
  union all
  -- money matched to a client's file but not allocated (still in 4710) gets the same clock (OQ-26, compliance B7)
  select 'unallocated_deadline', 'alert', 'servicer', null, u.currency, sum(u.unallocated)::bigint, count(*)::integer,
         null, jsonb_build_object('earliest_latest_execution_date', min(u.latest_execution_date),
                                  'held', count(*) filter (where u.held),
                                  'ids', (array_agg(u.id order by u.latest_execution_date))[1:50])
  from (select p.id, p.currency, p.review_reason = 'hold_blocks_allocation' as held,
               p.amount_minor - coalesce((select sum(lp.amount_minor) from public.ledger_entry e
                                          join public.ledger_posting lp on lp.entry_id = e.id
                                          join public.ledger_account la on la.id = lp.ledger_account_id
                                            and la.book = 'unallocated_payment'
                                          where e.payment_id = p.id and e.entry_type <> 'cash_in'), 0) as unallocated,
               k.latest_execution_date, k.alert_soon_date
        from public.payment p
        cross join lateral private.remittance_deadline(private.encaissement_date(p.booking_date, p.value_date),
                                                       30) k
        where p.organization_id = p_organization_id and p.account_id is not null
          and p.status in ('matched', 'partially_allocated')) u
  where u.unallocated > 0 and u.alert_soon_date <= v_today
  group by u.currency
  union all
  -- reference data (M2c-3): the VAT pack's review, the calendar's horizon
  select a.code, 'alert', 'servicer', null, null, null, null, null, a.details
  from private.reference_data_alerts(v_today) a
  ) u (code, severity, subject_type, subject_id, currency, amount_minor, count, oldest_days, details);
end;
$$;

------------------------------------------------------------------------------------------
-- The payments checks (redefined from 20261111090000; same settings and grants): I14 with the runs approved and not
-- booked yet; the runs' checks added before the counts. Each check stays one statement.
------------------------------------------------------------------------------------------

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

  -- Every check reads the books in ONE statement, so in one snapshot: an entry or a payment committed while the
  -- checks run (a link, a release, an allocation from a PostgREST session) is in every check or in none — never a gap
  -- between the cash read by one check and the payments read by another (review fix: the job runs READ COMMITTED,
  -- where each statement of a function sees the latest commits).
  insert into pg_temp._chk (code, severity, subject_type, subject_id, currency, amount_minor, count, oldest_days, details)
  with pos as materialized (
    -- Every payment's position from its tagged entries (one pass), and its pending refunds.
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
    where p.organization_id = p_organization_id
  )
  -- I8′: the dedicated-account fund closed per currency (5120 + 4710 + 4670 + 4679 = 0), the servicer's fund closed
  -- per currency (own_fund_identity), and the 4679 / 4689 mirror (fund_mirror, I12), from one pass over the funds.
  select x.code, 'violation'::text, 'servicer'::text, null::uuid, x.currency::char(3), x.total::bigint,
         null::integer, null::integer, x.details
  from (select f.currency, v.code, v.total, v.details
        from (select la.currency,
                     sum(lp.amount_minor) filter (where b.money_of = 'client') as client_total,
                     sum(lp.amount_minor) filter (where b.money_of = 'servicer') as servicer_total,
                     sum(lp.amount_minor) filter (where la.book in ('due_to_servicer', 'due_from_client_funds'))
                       as mirror_total,
                     sum(lp.amount_minor) filter (where la.book = 'client_money_cash') as cash,
                     sum(lp.amount_minor) filter (where la.book = 'unallocated_payment') as pool,
                     sum(lp.amount_minor) filter (where la.book = 'client_payable') as owed,
                     sum(lp.amount_minor) filter (where la.book = 'due_to_servicer') as servicer_share,
                     sum(lp.amount_minor) filter (where la.book = 'due_from_client_funds') as servicer_claim
              from public.ledger_account la
              join public.ledger_book b on b.code = la.book and b.money_of in ('client', 'servicer')
              join public.ledger_posting lp on lp.ledger_account_id = la.id
              where la.organization_id = p_organization_id and la.portfolio_id is null
              group by la.currency) f
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
  from (select la.client_organization_id, la.currency, sum(lp.amount_minor) as total
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'client_payable'
        group by la.client_organization_id, la.currency) p
  full join (select c.client_organization_id, c.currency, c.balance_minor from private.client_payable_balance c
             where c.organization_id = p_organization_id) r
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
  from (select c.client_organization_id, c.currency, c.balance_minor from private.client_payable_balance c
        where c.organization_id = p_organization_id) r
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
  -- (returns, refunds) + what its lines booked in the funds moved (top-ups in; fees, losses out; payouts and sweeps
  -- from M2c-6). Every 5120 movement of a funds entry comes from a bank line booked here.
  select 'bank_cash_identity', 'violation', 'bank_account', coalesce(c.bank_account_id, y.bank_account_id, k.bank_account_id),
         b.currency, (coalesce(c.cash, 0) - coalesce(y.held, 0) - coalesce(k.moved, 0))::bigint, null, null,
         jsonb_build_object('cash_minor', coalesce(c.cash, 0)::text, 'unallocated_minor', coalesce(y.unallocated, 0)::text,
                            'allocated_minor', coalesce(y.allocated, 0)::text,
                            'booked_lines_minor', coalesce(k.moved, 0)::text)
  from (select la.bank_account_id, sum(lp.amount_minor) as cash
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'client_money_cash'
        group by la.bank_account_id) c
  full join (select x.bank_account_id, sum(x.amount_minor - x.returned) as held, sum(x.unallocated) as unallocated,
                    sum(x.allocated) as allocated
             from pos x where x.bank_account_id is not null group by x.bank_account_id) y
    on y.bank_account_id = c.bank_account_id
  full join (select k.bank_account_id,
                    sum(case t.direction when 'credit' then k.amount_minor else -k.amount_minor end) as moved
             from public.bank_line_booking k join public.bank_transaction t on t.id = k.bank_transaction_id
             where k.organization_id = p_organization_id
             group by k.bank_account_id) k on k.bank_account_id = coalesce(c.bank_account_id, y.bank_account_id)
  join public.bank_account b on b.id = coalesce(c.bank_account_id, y.bank_account_id, k.bank_account_id)
  where coalesce(c.cash, 0) <> coalesce(y.held, 0) + coalesce(k.moved, 0)

  union all
  -- I11: the cash booked for a statement day = its payments (released duplicates included).
  select 'cash_in_statement', 'violation', 'bank_statement', coalesce(ci.statement_id, pd.statement_id), null,
         (coalesce(ci.total, 0) - coalesce(pd.total, 0))::bigint, null, null,
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
  from (select e.payment_id, e.account_id, sum(lp.amount_minor) as total
        from public.ledger_entry e
        left join public.ledger_entry t on t.id = e.reverses_entry_id
        join public.ledger_posting lp on lp.entry_id = e.id
        join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment'
        where e.organization_id = p_organization_id and e.payment_id is not null
          and coalesce(t.entry_type, e.entry_type) = 'allocation'
        group by e.payment_id, e.account_id) x
  where x.total < 0

  union all
  -- I6: no receivable a payment (or a credit note, or a payment made to the client) lowered is below zero now; no item
  -- below zero as a whole once such an entry touched it.
  select 'receivable_negative', 'violation', 'claim_item', x.claim_item_id, x.currency, x.balance::bigint, null, null,
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
  select 'item_negative', 'violation', 'claim_item', y.claim_item_id, y.currency, y.balance::bigint, null, null,
         '{}'::jsonb
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
  where y.balance < 0

  union all
  -- The owner-claim mirror (M2a risk #5): per portfolio, component and currency, 3100 = −Σ1100.
  select 'owner_claim_mirror', 'violation', 'portfolio', x.portfolio_id, x.currency, x.total::bigint, null, null,
         jsonb_build_object('component', x.component)
  from (select la.portfolio_id, la.component, la.currency, sum(lp.amount_minor) as total
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book in ('debtor_receivable', 'owner_claim')
        group by la.portfolio_id, la.component, la.currency) x
  where x.total <> 0

  union all
  -- R124-6: one receipt number per payment on a file and a current version about its file (void once returned). A
  -- payment changed in the last hour may still be in the receipts queue.
  select y.code, 'violation', 'payment', y.id, null, null, null, v_today - y.booking_date,
         jsonb_build_object('status', y.status)
  from (select c.id, c.booking_date, c.status,
               case when r.payment_id is null and c.status <> 'returned' then 'receipt_missing'
                    when r.numbers > 1 then 'receipt_numbers'
                    when c.status = 'returned' and r.payment_id is not null and cur.kind <> 'void' then 'receipt_not_void'
                    when c.status <> 'returned' and r.payment_id is not null
                         and (cur.kind = 'void' or cur.account_id is distinct from c.account_id) then 'receipt_stale'
               end as code
        from pos c
        left join (select x.payment_id, count(distinct x.number) as numbers, max(x.version) as v
                   from public.receipt x where x.organization_id = p_organization_id group by x.payment_id) r
          on r.payment_id = c.id
        left join public.receipt cur on cur.payment_id = c.id and cur.version = r.v
        where c.account_id is not null and c.updated_at < now() - interval '1 hour'
          and not (c.status in ('matched', 'partially_allocated') and c.review_reason is null)) y
  where y.code is not null

  union all
  -- R124-5: one notification per entry that moves what a client is owed, one per payment held for a file, one per
  -- return of a payment on a file.
  select 'notification_missing', 'violation', 'ledger_entry', e.id, null, null, null, null,
         jsonb_build_object('entry_type', e.entry_type, 'payment_id', e.payment_id)
  from public.ledger_entry e
  left join public.ledger_entry t on t.id = e.reverses_entry_id
  where e.organization_id = p_organization_id and e.payment_id is not null
    and (e.entry_type in ('allocation', 'forward') or (e.entry_type = 'reversal' and t.entry_type in ('allocation', 'forward')))
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = e.id)
  union all
  select 'notification_missing', 'violation', 'payment', c.id, null, null, null, null,
         jsonb_build_object('kind', 'payment_held')
  from pos c
  where c.review_reason = 'hold_blocks_allocation' and c.account_id is not null
    and not exists (select 1 from public.client_notification n
                    where n.payment_id = c.id and n.account_id = c.account_id and n.kind = 'payment_held')
  union all
  select 'notification_missing', 'violation', 'payment', l.payment_id, null, null, null, null,
         jsonb_build_object('kind', 'payment_returned')
  from public.bank_debit_link l
  join public.payment p on p.id = l.payment_id
  where l.organization_id = p_organization_id and l.kind = 'return' and p.account_id is not null
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = l.cash_entry_id)

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
               coalesce((select sum(lp.amount_minor) from public.ledger_account la
                         join public.ledger_posting lp on lp.ledger_account_id = la.id and lp.effective_date <= l.to_date
                         where la.bank_account_id = l.bank_account_id and la.book = 'client_money_cash'), 0) as cash,
               u.minor as unposted, u.lines as unposted_lines
        from (select distinct on (s.bank_account_id) s.bank_account_id, s.currency, s.to_date, s.closing_booked_minor
              from public.bank_statement s
              where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
              order by s.bank_account_id, s.to_date desc, s.finished_at desc) l
        cross join lateral private.bank_unposted(l.bank_account_id, l.to_date) u) z
  where z.closing - z.cash - z.unposted <> 0

  union all
  -- servicer_shortfall (§15, P0; review fix): the servicer owes the dedicated account more than the top-ups ordered
  -- cover — 4679 in debit (the fees and losses booked on the account are the servicer's cost, founder #8, #9) less
  -- the top-ups ordered and not booked yet: an approvisionnement from the own account is to order, for this amount.
  select 'servicer_shortfall', 'alert', 'servicer', null, s.currency, (s.owed - coalesce(o.ordered, 0))::bigint, null,
         null, jsonb_build_object('due_to_servicer_minor', s.owed::text,
                                  'top_ups_ordered_minor', coalesce(o.ordered, 0)::text)
  from (select la.currency, sum(lp.amount_minor) as owed
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'due_to_servicer'
        group by la.currency) s
  left join (select x.currency, sum(x.amount_minor) as ordered from public.bank_transfer x
             where x.organization_id = p_organization_id and x.kind = 'top_up' and x.status in ('ordered', 'in_file')
             group by x.currency) o on o.currency = s.currency
  where s.owed - coalesce(o.ordered, 0) > 0

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
        -- only be booked, never explained — and other debits of a pending refund's amount on its bank account
        select 'debit_unclassified', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from public.bank_transaction t
        left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
        where t.organization_id = p_organization_id
          and (t.kind in ('return', 'refund_out', 'transfer_out', 'own_transfer_in', 'client_transfer_in')
               or (t.kind = 'suspected_duplicate'
                   and r.released_kind in ('return', 'refund_out', 'transfer_out', 'own_transfer_in',
                                           'client_transfer_in'))
               or (t.kind = 'other_debit' and t.direction = 'debit'
                   and exists (select 1 from public.refund_request q
                               where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
                                 and q.organization_id = t.organization_id and q.status = 'requested')))
          and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
          and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
          and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
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
-- Reads for « Reversements » (§17.1, §17.2): money staff at aal2; amounts as text
------------------------------------------------------------------------------------------

-- The chip of a latest execution date (§17.1): ok, soon (5 business days or less), critical (1 or less), late.
create or replace function private.deadline_state(p_latest date)
returns text
language sql
stable
set search_path = ''
as $$
  select case when p_latest is null then null
              when p_latest < private.paris_today() then 'late'
              when private.business_days_between(private.paris_today(), p_latest) <= 1 then 'critical'
              when private.business_days_between(private.paris_today(), p_latest) <= 5 then 'soon'
              else 'ok' end;
$$;

create or replace function private.remittance_run_card(r public.remittance_run)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', r.id, 'number', r.number, 'status', r.status, 'trigger', r.trigger, 'currency', r.currency,
    'client_id', r.client_organization_id, 'client_name', c.legal_name, 'version', r.version, 'job', r.job,
    'known_at', r.known_at, 'prepared_at', r.prepared_at, 'item_count', r.item_count, 'line_count', r.line_count,
    'gross_minor', r.gross_minor::text, 'net_minor', r.net_minor::text, 'settlement_minor', r.settlement_minor::text,
    'invoice_ttc_minor', r.invoice_ttc_minor::text, 'credit_ttc_minor', r.credit_ttc_minor::text,
    'commission_taken_minor', r.commission_taken_minor::text, 'refund_minor', r.refund_minor::text,
    'advance_recovered_minor', r.advance_recovered_minor::text,
    'earliest_latest_execution_date', r.earliest_latest_execution_date, 'earliest_deadline', r.earliest_deadline,
    'unmeetable_count', r.unmeetable_count, 'requested_execution_date', r.requested_execution_date,
    'blockers', to_jsonb(r.blockers), 'commission_blockers', to_jsonb(r.commission_blockers),
    'inputs_hash', r.inputs_hash, 'last_failure', r.last_failure, 'approved_at', r.approved_at,
    'booked_on', r.booked_on, 'cancelled_at', r.cancelled_at, 'cancel_reason', r.cancel_reason,
    'invoice_late', r.invoice_late,
    'deadline_state', private.deadline_state(r.earliest_latest_execution_date),
    'payout', case when pa.id is not null then jsonb_build_object(
       'iban_last4', right(pa.iban, 4), 'holder_name', pa.holder_name, 'confirmed_at', pa.confirmed_at,
       'new_iban', not exists (select 1 from public.bank_transfer t
                               where t.client_organization_id = r.client_organization_id and t.payee_iban = pa.iban
                                 and t.kind = 'payout' and t.status = 'booked')) end)
  from public.organization c
  left join public.client_payout_account pa on pa.id = coalesce((r.payout_snapshot ->> 'payout_account_id')::uuid,
                                                                r.payout_account_id)
  where c.id = r.client_organization_id;
$$;

-- p_tab: a-valider (drafts, oldest deadline first) | en-cours (approved, sent) | termines (booked, cancelled: 100).
create or replace function public.remittance_overview(p_tab text default 'a-valider')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid := (private.money_staff_org_ids())[1];
  v_runs jsonb;
  v_prepare jsonb;
  v_counts jsonb;
begin
  if v_org is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(jsonb_agg(private.remittance_run_card(r) order by
           case when p_tab = 'a-valider' then r.earliest_latest_execution_date end nulls last,
           case when p_tab <> 'a-valider' then r.created_at end desc, r.number), '[]')
  into v_runs
  from (select * from public.remittance_run x
        where x.organization_id = v_org
          and x.status = any (case p_tab when 'en-cours' then array['approved', 'sent']
                                         when 'termines' then array['booked', 'cancelled']
                                         else array['draft'] end)
        order by x.created_at desc limit case when p_tab = 'termines' then 100 else 500 end) r;
  -- clients with collections waiting and no pending run: « Préparer maintenant »
  select coalesce(jsonb_agg(jsonb_build_object(
           'client_id', w.client_organization_id, 'client_name', o.legal_name, 'currency', w.currency,
           'owed_minor', w.owed::text, 'items', w.n, 'earliest_latest_execution_date', d.latest,
           'deadline_state', private.deadline_state(d.latest))
           order by d.latest nulls last, o.legal_name), '[]')
  into v_prepare
  from (select q.client_organization_id, q.currency, sum(q.amount_minor) as owed, count(*) as n
        from private.remittance_pending q
        where q.organization_id = v_org and q.draft_run_id is null
        group by q.client_organization_id, q.currency) w
  join public.organization o on o.id = w.client_organization_id
  left join (select x.client_organization_id, x.currency, min(x.latest_execution_date) as latest
             from private.pending_item_deadlines(v_org) x where x.draft_run_id is null
             group by x.client_organization_id, x.currency) d
    on d.client_organization_id = w.client_organization_id and d.currency = w.currency
  where not exists (select 1 from public.remittance_run r where r.client_organization_id = w.client_organization_id
                      and r.currency = w.currency and r.status in ('draft', 'approved', 'sent'));
  select jsonb_build_object(
    'a-valider', count(*) filter (where r.status = 'draft'),
    'en-cours', count(*) filter (where r.status in ('approved', 'sent')))
  into v_counts from public.remittance_run r where r.organization_id = v_org and r.status in ('draft', 'approved', 'sent');
  return jsonb_build_object('tab', p_tab, 'runs', v_runs, 'to_prepare', v_prepare, 'counts', v_counts,
                            'today', private.paris_today(),
                            'next_business_day', private.next_business_day(private.paris_today()),
                            'can_approve', private.has_role(v_org, array['admin', 'ops_manager']),
                            'can_cancel', private.has_role(v_org, array['admin']));
end;
$$;

-- One run: the card, its lines (paged; draft lines while a draft), its documents and its transfer.
create or replace function public.remittance_run_detail(p_run_id uuid, p_offset integer default 0,
                                                        p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.remittance_run;
  v_lines jsonb;
  v_docs jsonb;
  v_transfer jsonb;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or not (r.organization_id = any (private.money_staff_org_ids())) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', l.line_no, 'kind', l.kind, 'entry_id', l.ledger_entry_id, 'account_id', l.account_id,
           'file_ref', (select a.external_ref from public.account a where a.id = l.account_id),
           'amount_minor', l.amount_minor::text, 'encaissement_date', l.encaissement_date,
           'deadline', l.deadline, 'latest_execution_date', l.latest_execution_date, 'unmeetable', l.unmeetable,
           'commission_minor', l.commission_minor::text, 'commission_state', l.commission_state,
           'commission_reason', l.commission_reason, 'parts', l.parts) order by l.line_no), '[]')
  into v_lines
  from (select x.line_no, x.kind, x.ledger_entry_id, x.account_id, x.amount_minor, x.encaissement_date, x.deadline,
               x.latest_execution_date, x.unmeetable, x.commission_minor, x.commission_state, x.commission_reason,
               x.parts
        from public.remittance_line x where x.run_id = r.id and r.status <> 'draft'
        union all
        select x.line_no, x.kind, x.ledger_entry_id, x.account_id, x.amount_minor, x.encaissement_date, x.deadline,
               x.latest_execution_date, x.unmeetable, x.commission_minor, x.commission_state, x.commission_reason,
               x.parts
        from private.remittance_draft_line x where x.run_id = r.id and r.status = 'draft'
        order by 1 offset v_offset limit v_limit) l;
  if r.status = 'draft' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'kind', d ->> 'kind', 'number', null, 'mandate_id', d ->> 'mandate_id',
             'mandate_reference', (select m.reference from public.mandate m where m.id = (d ->> 'mandate_id')::uuid),
             'ht_minor', d ->> 'ht', 'vat_minor', d ->> 'vat', 'ttc_minor', d ->> 'ttc', 'settlement', d ->> 'settlement',
             'lines', d -> 'lines',
             'corrects', (select coalesce(jsonb_agg(i.number order by i.seq), '[]') from public.commission_invoice i
                          where i.id in (select (c ->> 'original_invoice_id')::uuid
                                         from jsonb_array_elements(coalesce(d -> 'corrections', '[]')) c)))
             order by x.ord), '[]')
    into v_docs
    from private.remittance_draft dr cross join lateral jsonb_array_elements(dr.documents) with ordinality x (d, ord)
    where dr.run_id = r.id;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', i.id, 'kind', i.kind, 'number', i.number, 'issue_date', i.issue_date, 'reason', i.reason,
             'mandate_id', i.mandate_id,
             'mandate_reference', (select m.reference from public.mandate m where m.id = i.mandate_id),
             'ht_minor', i.ht_minor::text, 'vat_minor', i.vat_minor::text, 'ttc_minor', i.ttc_minor::text,
             'settlement', i.settlement, 'due_date', i.due_date, 'payload_sha256', i.payload_sha256,
             'lines', (select coalesce(jsonb_agg(jsonb_build_object('designation_fr', l.designation_fr, 'kind', l.kind,
                                                                    'ht_minor', l.ht_minor::text) order by l.line_no),
                                       '[]')
                       from public.commission_invoice_line l where l.invoice_id = i.id),
             'corrects', (select coalesce(jsonb_agg(o.number order by o.seq), '[]')
                          from public.commission_credit_correction c
                          join public.commission_invoice o on o.id = c.original_invoice_id
                          where c.credit_note_id = i.id)) order by i.seq), '[]')
    into v_docs from public.commission_invoice i where i.run_id = r.id;
  end if;
  select jsonb_build_object('id', t.id, 'status', t.status, 'end_to_end_id', t.end_to_end_id,
                            'amount_minor', t.amount_minor::text, 'requested_execution_date', t.requested_execution_date,
                            'payee_name', t.payee_name, 'iban_last4', right(t.payee_iban, 4),
                            'remittance_info', t.remittance_info)
  into v_transfer from public.bank_transfer t where t.id = r.transfer_id;
  return jsonb_build_object('run', private.remittance_run_card(r), 'lines', v_lines, 'offset', v_offset,
                            'limit', v_limit, 'documents', v_docs, 'transfer', v_transfer,
                            'service_from', r.service_from, 'service_to', r.service_to,
                            'today', private.paris_today(),
                            'next_business_day', private.next_business_day(private.paris_today()),
                            'can_approve', private.has_role(r.organization_id, array['admin', 'ops_manager']),
                            'can_cancel', private.has_role(r.organization_id, array['admin']));
end;
$$;

------------------------------------------------------------------------------------------
-- bank_transfer_guard (redefined from 20261111120000): a payout's run never changes either. Same settings.
------------------------------------------------------------------------------------------

create or replace function private.bank_transfer_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'ordered' then
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
    if new.kind = 'payout' and not exists (select 1 from public.organization c where c.id = new.client_organization_id
                                             and c.servicer_organization_id = new.organization_id) then
      raise exception 'bank transfer: a payout goes to a client of the servicer' using errcode = 'check_violation';
    end if;
    if new.run_id is not null and not exists (select 1 from public.remittance_run r where r.id = new.run_id
                                             and r.client_organization_id = new.client_organization_id
                                             and r.currency = new.currency) then
      raise exception 'bank transfer: a payout belongs to a run of its client' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.client_organization_id, new.kind, new.debtor_bank_account_id,
      new.creditor_bank_account_id, new.currency, new.run_id,
      new.amount_minor, new.payee_name, new.payee_iban, new.payee_bic, new.end_to_end_id, new.remittance_info,
      new.requested_execution_date, new.reason, new.ordered_by, new.created_at)
     is distinct from
     (old.id, old.organization_id, old.client_organization_id, old.kind, old.debtor_bank_account_id,
      old.creditor_bank_account_id, old.currency, old.run_id,
      old.amount_minor, old.payee_name, old.payee_iban, old.payee_bic, old.end_to_end_id, old.remittance_info,
      old.requested_execution_date, old.reason, old.ordered_by, old.created_at)
     or (old.entry_id is not null and new.entry_id is distinct from old.entry_id)
     or (old.return_entry_id is not null and new.return_entry_id is distinct from old.return_entry_id)
     or (new.status <> old.status and not (
           (old.status = 'ordered' and new.status in ('in_file', 'booked', 'cancelled'))
           or (old.status = 'in_file' and new.status in ('booked', 'cancelled'))
           or (old.status = 'booked' and new.status = 'returned'))) then
    raise exception 'bank transfer %: what was ordered never changes, and its status only moves forward', old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

------------------------------------------------------------------------------------------
-- Read access (§6.2; OQ-48): money staff (admins and ops managers at aal2); a client's members with access to the
-- whole client read its runs once approved, their lines and its documents and settlements; the rest is staff's only.
-- No write policy: writes go through the definer functions above or the worker.
------------------------------------------------------------------------------------------

alter table public.remittance_run enable row level security;
alter table public.remittance_line enable row level security;
alter table public.remittance_line_repricing enable row level security;
alter table public.commission_invoice enable row level security;
alter table public.commission_invoice_line enable row level security;
alter table public.commission_invoice_charge enable row level security;
alter table public.commission_credit_alloc enable row level security;
alter table public.commission_credit_correction enable row level security;
alter table public.commission_settlement enable row level security;
alter table public.remittance_key_state enable row level security;
alter table public.remittance_deadline_breach enable row level security;
alter table public.remittance_late_approval enable row level security;
alter table private.remittance_draft_line enable row level security;
alter table private.remittance_draft_repricing enable row level security;
alter table private.remittance_draft enable row level security;
alter table private.invoice_counter enable row level security;

revoke all on public.remittance_run, public.remittance_line, public.remittance_line_repricing,
  public.commission_invoice, public.commission_invoice_line, public.commission_invoice_charge,
  public.commission_credit_alloc, public.commission_credit_correction, public.commission_settlement,
  public.remittance_key_state, public.remittance_deadline_breach, public.remittance_late_approval
  from public, anon, authenticated;
revoke all on private.remittance_draft_line, private.remittance_draft_repricing, private.remittance_draft,
  private.invoice_counter from public, anon, authenticated;
revoke all on sequence private.remittance_run_number_seq from public, anon, authenticated;
grant select on public.remittance_run, public.remittance_line, public.remittance_line_repricing,
  public.commission_invoice, public.commission_invoice_line, public.commission_invoice_charge,
  public.commission_credit_alloc, public.commission_credit_correction, public.commission_settlement,
  public.remittance_key_state, public.remittance_deadline_breach, public.remittance_late_approval to authenticated;

-- a client member with access to the whole client: a run once approved (a draft is the servicer's work)
create or replace function private.client_reads_run(p_client_organization_id uuid, p_status text,
                                                    p_approved_at timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_client_organization_id = any ((select private.client_whole_org_ids())::uuid[])
         and p_status <> 'draft' and p_approved_at is not null;
$$;

create policy remittance_run_read on public.remittance_run for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or (select private.client_reads_run(client_organization_id, status, approved_at)));
create policy remittance_line_read on public.remittance_line for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or (client_organization_id = any ((select private.client_whole_org_ids())::uuid[])
      and exists (select 1 from public.remittance_run r where r.id = run_id and r.approved_at is not null)));
create policy remittance_line_repricing_read on public.remittance_line_repricing for select to authenticated using (
  exists (select 1 from public.remittance_run r where r.id = pricing_run_id
            and r.organization_id = any ((select private.money_staff_org_ids())::uuid[])));
create policy commission_invoice_read on public.commission_invoice for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or client_organization_id = any ((select private.client_whole_org_ids())::uuid[]));
create policy commission_invoice_line_read on public.commission_invoice_line for select to authenticated using (
  exists (select 1 from public.commission_invoice i where i.id = invoice_id));
create policy commission_invoice_charge_read on public.commission_invoice_charge for select to authenticated using (
  exists (select 1 from public.commission_invoice i where i.id = invoice_id
            and i.organization_id = any ((select private.money_staff_org_ids())::uuid[])));
create policy commission_credit_alloc_read on public.commission_credit_alloc for select to authenticated using (
  exists (select 1 from public.commission_invoice i where i.id = credit_note_id
            and i.organization_id = any ((select private.money_staff_org_ids())::uuid[])));
create policy commission_credit_correction_read on public.commission_credit_correction for select to authenticated
  using (exists (select 1 from public.commission_invoice i where i.id = credit_note_id));
create policy commission_settlement_read on public.commission_settlement for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or client_organization_id = any ((select private.client_whole_org_ids())::uuid[]));
create policy remittance_key_state_read on public.remittance_key_state for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy remittance_deadline_breach_read on public.remittance_deadline_breach for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[]));
-- a client's members with access to the whole client read the late approvals of its runs (always approved runs)
create policy remittance_late_approval_read on public.remittance_late_approval for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or client_organization_id = any ((select private.client_whole_org_ids())::uuid[]));

-- Functions: the commands and reads are the API's; the rest the worker's (service role) or internal.
revoke execute on function
  private.remittance_run_guard(), private.remittance_line_guard(), private.remittance_line_insert_guard(),
  private.commission_invoice_guard(), private.is_business_day(date), private.next_business_day(date),
  private.business_days_between(date, date), private.paying_account(uuid, char),
  private.remittance_payout_blockers(uuid, char, date), private.remittance_commission_blockers(uuid),
  private.create_remittance_run(uuid, uuid, char, text, text, uuid), private.remittance_clear_draft(uuid),
  private.remittance_draft_for_command(uuid, integer, text[]), private.remittance_prepare_begin(uuid, uuid),
  private.remittance_record_draft(uuid, uuid, jsonb), private.remittance_prepare_failed(uuid, uuid, text, text),
  private.invoice_party(uuid), private.issue_commission_documents(uuid, uuid, uuid, jsonb, text, boolean),
  private.remittance_late_lines(public.remittance_run, date), private.remittance_command_locks(uuid, boolean),
  private.post_run_settlement(uuid, jsonb, date), private.execution_date_refusal(uuid, char, date),
  private.remittance_back_to_draft(uuid, uuid, text, text),
  private.remittance_approval_refusal(public.remittance_run, private.remittance_draft, date),
  private.document_open(uuid), private.document_pending_vat(uuid), private.approve_remittance_run(uuid, uuid),
  private.pending_item_deadlines(uuid), private.queue_remittance_schedule(),
  private.remittance_schedule_candidates(uuid, date), private.remittance_stuck_jobs(uuid),
  private.run_remittance_checks(uuid, uuid),
  private.remittance_run_card(public.remittance_run), private.client_reads_run(uuid, text, timestamptz),
  private.deadline_state(date)
  from public, anon, authenticated;
-- the RLS helper runs as the caller
grant execute on function private.client_reads_run(uuid, text, timestamptz) to authenticated;
-- the worker (service role): the schedule, prepare and approve jobs
grant execute on function private.is_business_day(date), private.next_business_day(date),
  private.business_days_between(date, date), private.paying_account(uuid, char),
  private.remittance_payout_blockers(uuid, char, date), private.remittance_commission_blockers(uuid),
  private.create_remittance_run(uuid, uuid, char, text, text, uuid), private.remittance_prepare_begin(uuid, uuid),
  private.remittance_record_draft(uuid, uuid, jsonb), private.remittance_prepare_failed(uuid, uuid, text, text),
  private.remittance_back_to_draft(uuid, uuid, text, text), private.approve_remittance_run(uuid, uuid),
  private.document_open(uuid), private.document_pending_vat(uuid), private.pending_item_deadlines(uuid),
  private.remittance_schedule_candidates(uuid, date), private.remittance_stuck_jobs(uuid)
  to service_role;
revoke execute on function public.request_remittance_run(text, uuid, text),
  public.refresh_remittance_run(text, uuid, integer), public.discard_remittance_run(text, uuid, integer, text),
  public.approve_remittance_runs(text, jsonb, date, text), public.cancel_remittance_run(text, uuid, integer, text),
  public.remittance_overview(text), public.remittance_run_detail(uuid, integer, integer) from public, anon;
grant execute on function public.request_remittance_run(text, uuid, text),
  public.refresh_remittance_run(text, uuid, integer), public.discard_remittance_run(text, uuid, integer, text),
  public.approve_remittance_runs(text, jsonb, date, text), public.cancel_remittance_run(text, uuid, integer, text),
  public.remittance_overview(text), public.remittance_run_detail(uuid, integer, integer) to authenticated;
grant select, insert, update, delete on private.remittance_draft_line to service_role;
grant select on private.remittance_pending, private.client_payable_balance to service_role;
