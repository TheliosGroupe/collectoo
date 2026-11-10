-- M2c-5 Documents (M2-14 statement, M2-15 PDF; design docs/design/m2c-remittances.md §10, §14, §16, §17, §19, §21;
-- ADR-0014 M2c-5 addendum; founder decisions #3, #12 of 2026-11-09).
--
--   * the client statement (« Relevé de reversement », C. civ. 1993 « rendre compte »): its payload built in SQL, once,
--     from the run's frozen lines and repricings, its entries, documents and settlement plan, the payout ordered and the
--     identities as they stand when it is drawn (`private.remittance_statement_build`, canonical jsonb, amounts as text in
--     minor units, dates ISO); the worker renders the CSV and the PDF from it (deterministic bytes), both stored in the
--     private bucket with their SHA-256 (`public.remittance_statement`, append-only);
--   * the PDF of every commission invoice and credit note, rendered by the worker from the payload M2c-4 froze at issue
--     (never from the current settings; locked template `facture-commission-fr-2`), stored with its SHA-256
--     (`public.commission_invoice_document`, append-only); whether the buyer accepted electronic invoices (CGI 289 VI)
--     is read from that payload: without it the client space does not serve its PDF (it is sent otherwise, OQ-74);
--   * a queue of documents to draw (`private.remittance_document_todo`, fed by a trigger on every new invoice or credit
--     note and on every run's approval) and the job that draws them (`remittances.documents`, one servicer at a time);
--   * read access: money staff; the client's members with access to the whole client (OQ-48); the storage policy of the
--     private bucket follows the same rule; collectors and portfolio-restricted users read none of it;
--   * the client space's summary (`public.client_remittance_summary`) and the accountant's export
--     (`public.accounting_export_documents`, `public.accounting_export_entries`).
--
-- The manual credit note (`issue_credit_note`, design §14.1, risk R2) is not here: it needs a waived amount in the
-- commission engine's key state (ADR-0014 M2c-5, « Left for later slices »).
--
-- Review fixes (M2c-5 review): redefined from 20261112090000 with the same settings and grants —
-- `private.issue_commission_documents` (the 40 € flat indemnity frozen as applying to every professional buyer, a
-- recorded proceeding kept apart for the dunning step: legal#0; the payment reference states what the plan sets off on
-- the run, and a remainder its latest date and `due_date`: legal#4; N = 0 frozen as « no transfer »: legal#5),
-- `private.run_remittance_checks` (`remittance_document_failed`, `remittance_document_missing`: perf#2; the remainders
-- in `invoice_overdue`: legal#4), `private.queue_remittance_schedule` (the hourly cron also queues the documents job of
-- a servicer with documents due: perf#2); the constraint `commission_invoice_due` lets a netted invoice carry the date
-- of its remainder.

------------------------------------------------------------------------------------------
-- Documents to draw (one row per invoice, credit note or approved run without its files)
------------------------------------------------------------------------------------------

create table private.remittance_document_todo (
  organization_id uuid not null references public.organization (id),
  kind text not null check (kind in ('invoice', 'statement')),
  ref_id uuid not null,                   -- commission_invoice.id or remittance_run.id
  created_at timestamptz not null default clock_timestamp(),
  -- failed attempts (review perf#2: one document that cannot be drawn never blocks the others; it is retried after
  -- next_attempt_at and raises `remittance_document_failed`)
  attempts integer not null default 0 check (attempts >= 0),
  last_error text check (length(last_error) between 1 and 2000),
  last_attempt_at timestamptz,
  next_attempt_at timestamptz,            -- null: due now
  primary key (kind, ref_id),
  check ((attempts = 0) = (last_error is null and last_attempt_at is null and next_attempt_at is null))
);
create index remittance_document_todo_org_idx on private.remittance_document_todo (organization_id, created_at, ref_id);
comment on table private.remittance_document_todo is
  'Statements and invoice PDFs still to draw (deleted when the documents job records them), with failed attempts.';

-- Every new invoice or credit note (an approval's, a cancellation's, a manual credit note): its PDF is due. One message
-- per servicer of the statement (the job draws everything due for that servicer).
create or replace function private.queue_invoice_documents()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.remittance_document_todo (organization_id, kind, ref_id)
  select n.organization_id, 'invoice', n.id from new_rows n
  on conflict do nothing;
  perform pgmq.send('remittances', jsonb_build_object('type', 'documents', 'organization_id', o.organization_id))
  from (select distinct n.organization_id from new_rows n) o;
  return null;
end;
$$;
create trigger commission_invoice_documents after insert on public.commission_invoice
  referencing new table as new_rows for each statement execute function private.queue_invoice_documents();

-- A run approved (approved, or booked at approval when nothing is transferred): its statement is due.
create or replace function private.queue_statement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.remittance_document_todo (organization_id, kind, ref_id)
  values (new.organization_id, 'statement', new.id)
  on conflict do nothing;
  perform pgmq.send('remittances', jsonb_build_object('type', 'documents', 'organization_id', new.organization_id));
  return null;
end;
$$;
create trigger remittance_run_statement after update of approved_at on public.remittance_run
  for each row when (old.approved_at is null and new.approved_at is not null)
  execute function private.queue_statement();

------------------------------------------------------------------------------------------
-- Stored documents (append-only facts)
------------------------------------------------------------------------------------------

-- The statement of a run (« Relevé de reversement », number = the run's RV number): its payload and the two files.
create table public.remittance_statement (
  run_id uuid primary key references public.remittance_run (id),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  currency char(3) not null references public.currency (code),
  number text not null unique,
  issue_date date not null,                 -- the Paris day of the run's approval
  known_at timestamptz not null,            -- K
  line_count integer not null check (line_count >= 0),
  file_count integer not null check (file_count >= 0),
  -- what a list shows without reading the payload (review perf#4: a 50k-line payload is ≈ 10 MB), as the statement
  -- states them; the run's live status is the run's (remittance_run.status), this is the one the PDF words
  gross_minor bigint not null,
  net_minor bigint not null,
  drawn_status text not null check (drawn_status in ('approved', 'sent', 'booked', 'cancelled')),
  payload jsonb not null,
  payload_sha256 text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  template_version text not null,
  renderer_version text not null,
  pdf_document_id uuid not null unique references public.document (id),
  pdf_sha256 text not null check (pdf_sha256 ~ '^[0-9a-f]{64}$'),
  csv_document_id uuid not null unique references public.document (id),
  csv_sha256 text not null check (csv_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default clock_timestamp()
);
create index remittance_statement_client_idx on public.remittance_statement (client_organization_id, issue_date desc);
create index remittance_statement_org_idx on public.remittance_statement (organization_id, issue_date desc);
comment on table public.remittance_statement is
  'The client statement of a run (C. civ. 1993): its payload and its PDF and CSV with their SHA-256 (append-only).';

-- The PDF of an invoice or credit note, rendered from its frozen payload.
create table public.commission_invoice_document (
  invoice_id uuid primary key references public.commission_invoice (id),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  document_id uuid not null unique references public.document (id),
  pdf_sha256 text not null check (pdf_sha256 ~ '^[0-9a-f]{64}$'),
  template_version text not null,
  renderer_version text not null,
  electronic boolean not null,              -- the buyer's acceptance of electronic invoices, at issue (CGI 289 VI)
  created_at timestamptz not null default clock_timestamp()
);
create index commission_invoice_document_client_idx on public.commission_invoice_document (client_organization_id);
comment on table public.commission_invoice_document is
  'The PDF of a commission invoice or credit note (CGI 289 V: its SHA-256 kept; append-only).';

do $$
declare t text;
begin
  foreach t in array array['remittance_statement', 'commission_invoice_document'] loop
    execute format('create trigger %I before update or delete or truncate on public.%I '
                   'for each statement execute function private.refuse_change()', t || '_append_only', t);
    execute format('alter table public.%I enable always trigger %I', t, t || '_append_only');
  end loop;
end;
$$;

------------------------------------------------------------------------------------------
-- The statement payload (§10): built once, in SQL, from the run's frozen facts
------------------------------------------------------------------------------------------

-- The CSV's line columns, in order (the payload's `lines` are arrays in this order; the template words the codes).
-- `late_cause` is a category the data supports (review legal#6), never the approver's free text.
create or replace function private.remittance_statement_line_columns()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '["line_no", "mandate", "portfolio", "file", "debtor", "items", "components", "nature", "nature_reason",
           "from_run", "encaissement_date", "effective_date", "deadline", "amount_minor", "rules", "rates",
           "basis_minor", "commission_minor", "commission_state", "invoice", "receipt", "late", "late_cause"]'::jsonb;
$$;

-- An IBAN as the statement prints it: its country and check digits, then its last four characters.
create or replace function private.iban_masked(p_iban text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_iban is null then null
              else left(p_iban, 4) || ' •••• •••• •••• ' || right(p_iban, 4) end;
$$;

-- Builds the payload of the run's statement (the job keeps it in pg_temp._rd_statement for the record step; the worker
-- renders the files from the returned copy). Keyed lookups from the run's lines (ARCHITECTURE §4): each line's file,
-- borrower, mandate, portfolio, items and components (its entry's 1100 postings), notification reason, invoice (or the
-- run's credit note that credits it), receipt and late approval by their keys, whatever the statistics.
--
-- One state (review figures#6): the run row is held FOR SHARE to the commit, so a cancellation (FOR UPDATE) either
-- committed before and is read here, or waits for the documents job; what is not the run's own (the ledger at K, the
-- money not remitted at K) is read as of K. A run cancelled before its statement is drawn (review legal#2, figures#0)
-- says so: nothing set off (every `settles_minor` 0, no earlier document settled), the client still owed the gross,
-- 4111 after = before + every document of the run (the approval's and the cancellation's).
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
         n.reason as nature_reason, x.encaissement_date, x.effective_date, x.deadline, x.commission_state,
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
  -- in the back office): the mandate's delay could not be met (held to one month, R124-6), the collection reached the
  -- queue after its J-5 date (the deadline guard's margin, 5 business days before its latest execution date), or the
  -- approval came late
  left join lateral (select case when x.unmeetable then 'unmeetable'
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
                    then f.nature_reason end as reason,
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
-- The documents job (`remittances.documents {organization_id}`): one servicer at a time
------------------------------------------------------------------------------------------

-- The servicer's documents lock, the work tables, and up to p_invoices invoice PDFs and p_statements statements due
-- (oldest first), each with its key in the private bucket. A document whose last attempt failed waits for its
-- next_attempt_at (review perf#2: the others are drawn meanwhile).
create or replace function private.remittance_documents_begin(p_organization_id uuid, p_invoices integer,
                                                             p_statements integer)
returns table (kind text, ref_id uuid, number text, pdf_path text, csv_path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtext('documents:' || p_organization_id::text));
  drop table if exists pg_temp._rd_statement;
  create temp table _rd_statement (run_id uuid primary key, payload jsonb not null, payload_sha256 text not null,
                                   line_count integer not null, file_count integer not null) on commit drop;
  drop table if exists pg_temp._rd_statement_files;
  create temp table _rd_statement_files (run_id uuid primary key, pdf_sha256 text not null, csv_sha256 text not null)
    on commit drop;
  drop table if exists pg_temp._rd_invoice_pdf;
  create temp table _rd_invoice_pdf (invoice_id uuid primary key, pdf_sha256 text not null) on commit drop;
  return query
  select 'statement'::text, r.id, r.number,
         private.remittance_statement_path(r.organization_id, r.client_organization_id, r.number) || '.pdf',
         private.remittance_statement_path(r.organization_id, r.client_organization_id, r.number) || '.csv'
  from (select t.ref_id from private.remittance_document_todo t
        where t.organization_id = p_organization_id and t.kind = 'statement'
          and (t.next_attempt_at is null or t.next_attempt_at <= clock_timestamp())
        order by t.created_at, t.ref_id limit greatest(p_statements, 0)) t
  cross join lateral (select x.id, x.number, x.organization_id, x.client_organization_id from public.remittance_run x
                      where x.id = t.ref_id offset 0) r
  union all
  select 'invoice'::text, i.id, i.number,
         private.commission_invoice_path(i.organization_id, i.client_organization_id, i.year, i.number), null::text
  from (select t.ref_id from private.remittance_document_todo t
        where t.organization_id = p_organization_id and t.kind = 'invoice'
          and (t.next_attempt_at is null or t.next_attempt_at <= clock_timestamp())
        order by t.created_at, t.ref_id limit greatest(p_invoices, 0)) t
  cross join lateral (select x.id, x.number, x.organization_id, x.client_organization_id, x.year
                      from public.commission_invoice x where x.id = t.ref_id offset 0) i;
end;
$$;

-- Whether documents of the servicer are due now (not waiting for a retry).
create or replace function private.remittance_documents_due(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.remittance_document_todo t
                 where t.organization_id = p_organization_id
                   and (t.next_attempt_at is null or t.next_attempt_at <= clock_timestamp()));
$$;

-- A document the job could not draw (the worker rolled its attempt back to a savepoint): the attempt recorded on its
-- row, retried after a delay that doubles from 2 minutes up to 6 hours (the hourly schedule queues the job again);
-- `remittance_document_failed` raises it every night until it is drawn. Returns {attempts, next_attempt_at}.
create or replace function private.remittance_document_failed(p_organization_id uuid, p_kind text, p_ref_id uuid,
                                                             p_error text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  update private.remittance_document_todo t
  set attempts = t.attempts + 1,
      last_error = left(coalesce(nullif(btrim(p_error), ''), 'unknown error'), 2000),
      last_attempt_at = clock_timestamp(),
      next_attempt_at = clock_timestamp() + least(interval '1 minute' * power(2, least(t.attempts + 1, 10)),
                                                  interval '6 hours')
  where t.organization_id = p_organization_id and t.kind = p_kind and t.ref_id = p_ref_id
  returning jsonb_build_object('attempts', t.attempts, 'next_attempt_at', t.next_attempt_at);
$$;

-- The keys of the files in the private bucket `documents` (the year is the number's).
create or replace function private.remittance_statement_path(p_organization_id uuid, p_client_organization_id uuid,
                                                            p_number text)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'statements/' || p_organization_id || '/' || p_client_organization_id || '/' || substr(p_number, 4, 4) || '/'
         || p_number;
$$;
create or replace function private.commission_invoice_path(p_organization_id uuid, p_client_organization_id uuid,
                                                          p_year integer, p_number text)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'invoices/' || p_organization_id || '/' || p_client_organization_id || '/' || p_year || '/' || p_number
         || '.pdf';
$$;

-- The statement's payload, built and kept for the record step (the worker renders from the returned copy).
create or replace function private.remittance_statement_prepare(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb;
begin
  v := private.remittance_statement_build(p_run_id);
  insert into pg_temp._rd_statement (run_id, payload, payload_sha256, line_count, file_count)
  values (p_run_id, v, encode(sha256(convert_to(v::text, 'UTF8')), 'hex'), (v #>> '{totals,line_count}')::integer,
          (v #>> '{totals,file_count}')::integer)
  on conflict (run_id) do update set payload = excluded.payload, payload_sha256 = excluded.payload_sha256,
    line_count = excluded.line_count, file_count = excluded.file_count;
  return v;
end;
$$;

-- What an invoice or credit note is rendered from: its row, its frozen payload, and the number and date of every
-- invoice its lines or corrections name (append-only rows: the same bytes every time).
create or replace function private.commission_invoice_render_rows(p_ids uuid[])
returns table (invoice_id uuid, number text, kind text, issue_date date, payload jsonb, refs jsonb)
language sql
stable
security definer
set search_path = ''
as $$
  select i.id, i.number, i.kind, i.issue_date, i.payload,
         (select coalesce(jsonb_object_agg(o.id::text, jsonb_build_object('number', o.number,
                                                                          'issue_date', o.issue_date)), '{}')
          from (select distinct (c ->> 'original_invoice_id')::uuid as id
                from jsonb_array_elements(coalesce(i.payload -> 'corrections', '[]')
                                          || coalesce(i.payload -> 'lines', '[]')) c
                where c ->> 'original_invoice_id' is not null) x
          cross join lateral (select q.id, q.number, q.issue_date from public.commission_invoice q
                              where q.id = x.id offset 0) o)
  from unnest(p_ids) with ordinality u (id, ord)
  cross join lateral (select q.* from public.commission_invoice q where q.id = u.id offset 0) i
  order by u.ord;
$$;

-- Records what the job rendered (pg_temp._rd_statement_files, _rd_invoice_pdf, filled by the worker after its
-- uploads): one document per file (private bucket `documents`, SHA-256), the statement rows with the payload prepared
-- in this transaction, the invoice document rows; the work done leaves the queue and the work tables (the worker
-- records each statement and each chunk of invoices under its own savepoint: review perf#2). Every prepared statement
-- was rendered, nothing else. Returns {statements, invoices, more} (more: documents due now, not waiting for a retry).
create or replace function private.remittance_documents_record(p_organization_id uuid, p_statement_template text,
                                                              p_invoice_template text, p_renderer_version text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bad text;
  v_s integer;
  v_i integer;
begin
  select min(coalesce(s.run_id, f.run_id)::text) into v_bad
  from pg_temp._rd_statement s full join pg_temp._rd_statement_files f on f.run_id = s.run_id
  where s.run_id is null or f.run_id is null;
  if v_bad is not null then
    raise exception 'statement of run %: prepared and rendered statements differ', v_bad
      using errcode = 'check_violation';
  end if;

  drop table if exists pg_temp._rd_new_statement;
  create temp table _rd_new_statement on commit drop as
  select r.id as run_id, r.organization_id, r.client_organization_id, r.currency, r.number, r.known_at,
         (r.approved_at at time zone 'Europe/Paris')::date as issue_date, s.payload, s.payload_sha256, s.line_count,
         s.file_count, f.pdf_sha256, f.csv_sha256, gen_random_uuid() as pdf_id, gen_random_uuid() as csv_id,
         private.remittance_statement_path(r.organization_id, r.client_organization_id, r.number) as path
  from pg_temp._rd_statement s
  join pg_temp._rd_statement_files f on f.run_id = s.run_id
  cross join lateral (select x.* from public.remittance_run x where x.id = s.run_id offset 0) r
  where r.organization_id = p_organization_id;
  if (select count(*) from pg_temp._rd_new_statement) <> (select count(*) from pg_temp._rd_statement) then
    raise exception 'statements: a run of another servicer' using errcode = 'check_violation';
  end if;
  insert into public.document (id, organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                               mime_type, file_name)
  select n.pdf_id, n.organization_id, n.client_organization_id, 'remittance_statement_pdf', 'documents',
         n.path || '.pdf', n.pdf_sha256, 'application/pdf', n.number || '.pdf'
  from pg_temp._rd_new_statement n
  union all
  select n.csv_id, n.organization_id, n.client_organization_id, 'remittance_statement_csv', 'documents',
         n.path || '.csv', n.csv_sha256, 'text/csv', n.number || '.csv'
  from pg_temp._rd_new_statement n;
  insert into public.remittance_statement (run_id, organization_id, client_organization_id, currency, number,
                                           issue_date, known_at, line_count, file_count, gross_minor, net_minor,
                                           drawn_status, payload, payload_sha256, template_version, renderer_version,
                                           pdf_document_id, pdf_sha256, csv_document_id, csv_sha256)
  select n.run_id, n.organization_id, n.client_organization_id, n.currency, n.number, n.issue_date, n.known_at,
         n.line_count, n.file_count, (n.payload #>> '{totals,gross_minor}')::bigint,
         (n.payload #>> '{totals,net_minor}')::bigint, n.payload ->> 'status', n.payload, n.payload_sha256,
         p_statement_template, p_renderer_version, n.pdf_id, n.pdf_sha256, n.csv_id, n.csv_sha256
  from pg_temp._rd_new_statement n;
  get diagnostics v_s = row_count;

  drop table if exists pg_temp._rd_new_invoice;
  create temp table _rd_new_invoice on commit drop as
  select i.id as invoice_id, i.organization_id, i.client_organization_id, i.number, f.pdf_sha256,
         gen_random_uuid() as document_id,
         private.commission_invoice_path(i.organization_id, i.client_organization_id, i.year, i.number) as path,
         nullif(btrim(coalesce(i.payload #>> '{buyer,invoice_acceptance_ref}', '')), '') is not null as electronic
  from pg_temp._rd_invoice_pdf f
  cross join lateral (select x.* from public.commission_invoice x where x.id = f.invoice_id offset 0) i
  where i.organization_id = p_organization_id;
  if (select count(*) from pg_temp._rd_new_invoice) <> (select count(*) from pg_temp._rd_invoice_pdf) then
    raise exception 'invoice documents: an invoice of another servicer, or unknown' using errcode = 'check_violation';
  end if;
  insert into public.document (id, organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                               mime_type, file_name)
  select n.document_id, n.organization_id, n.client_organization_id, 'commission_invoice_pdf', 'documents', n.path,
         n.pdf_sha256, 'application/pdf', n.number || '.pdf'
  from pg_temp._rd_new_invoice n;
  insert into public.commission_invoice_document (invoice_id, organization_id, client_organization_id, document_id,
                                                  pdf_sha256, template_version, renderer_version, electronic)
  select n.invoice_id, n.organization_id, n.client_organization_id, n.document_id, n.pdf_sha256, p_invoice_template,
         p_renderer_version, n.electronic
  from pg_temp._rd_new_invoice n;
  get diagnostics v_i = row_count;

  delete from private.remittance_document_todo t
  where (t.kind = 'statement' and t.ref_id in (select n.run_id from pg_temp._rd_new_statement n))
     or (t.kind = 'invoice' and t.ref_id in (select n.invoice_id from pg_temp._rd_new_invoice n));
  delete from pg_temp._rd_statement;
  delete from pg_temp._rd_statement_files;
  delete from pg_temp._rd_invoice_pdf;
  return jsonb_build_object('statements', v_s, 'invoices', v_i,
                            'more', private.remittance_documents_due(p_organization_id));
end;
$$;

-- Objects of the servicer's statements and invoice PDFs that no document names, older than the given age (a killed
-- attempt's uploads): listed for the worker to delete under the documents lock (as the receipts sweep does).
create or replace function private.remittance_document_orphans(p_organization_id uuid, p_older_than interval,
                                                              p_limit integer)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select o.name
  from storage.objects o
  where o.bucket_id = 'documents'
    and (o.name like 'statements/' || p_organization_id::text || '/%'
         or o.name like 'invoices/' || p_organization_id::text || '/%')
    and greatest(o.created_at, o.updated_at) < now() - p_older_than
    and not exists (select 1 from public.document d where d.storage_bucket = 'documents' and d.storage_path = o.name)
  order by o.name
  limit greatest(coalesce(p_limit, 1000), 1);
$$;

-- Documents due for longer than the given age (§15 `document_missing`; the nightly checks ask 24 hours), oldest first,
-- with their failed attempts.
create or replace function private.remittance_documents_missing(p_organization_id uuid, p_older_than interval)
returns table (kind text, ref_id uuid, number text, due_since timestamptz, attempts integer, last_error text)
language sql
stable
security definer
set search_path = ''
as $$
  select t.kind, t.ref_id,
         case t.kind when 'invoice' then (select i.number from public.commission_invoice i where i.id = t.ref_id)
                     else (select r.number from public.remittance_run r where r.id = t.ref_id) end,
         t.created_at, t.attempts, t.last_error
  from private.remittance_document_todo t
  where t.organization_id = p_organization_id and t.created_at < clock_timestamp() - p_older_than
  order by t.created_at, t.ref_id;
$$;

------------------------------------------------------------------------------------------
-- Review fixes (M2c-5 review): functions of 20261112090000 redefined, with the same settings and grants
------------------------------------------------------------------------------------------

-- A netted invoice may carry a date: the one by which the next run sets off what its own run's plan leaves of it
-- (legal#4), as a cancellation's corrective invoice does (OQ-72); a due one always has its due date.
alter table public.commission_invoice drop constraint commission_invoice_due;
alter table public.commission_invoice add constraint commission_invoice_due
  check (case settlement when 'due' then due_date is not null else due_date is null or kind = 'invoice' end);

-- Issues the documents `p_docs` (in order; each with its `id`, `key`, kind, mandate_id, amounts as text, lines,
-- charges, allocations, corrections, settlement mode and due days; optionally its own service period `service_from`,
-- `service_to`, and `payment` 'next_run' for a netted invoice set off on the client's next run by a date) for a
-- client: one number each, the counter row of the servicer's series and year locked (after the allocation and remit
-- locks the caller holds), dated the transaction's day; their entries in one ledger_post_set, the invoices' VAT in the
-- book `p_vat_on_debits` says (the plan's; null: the servicer's setting); each credit note applied to the invoices it
-- corrects (commission_settlement kind credit_note); the payload frozen with the mentions in force (L441-9). Returns
-- {issue_date, documents: {ref: {id, number}}}.
--
-- Redefined from 20261112090000 (M2c-5 review; same settings and grants):
--   * the 40 € flat indemnity (L441-9 I: the invoice states « le montant de l'indemnité forfaitaire pour frais de
--     recouvrement due au créancier en cas de retard de paiement »; L441-10 II, D441-5) is frozen as applying to every
--     professional buyer; a proceeding of the client recorded by the issue date is frozen beside it (`proceeding`) for
--     the dunning step only — L441-10 II bars invoking the indemnity while the opening forbids paying the claim at its
--     date, it does not remove the mention (legal#0);
--   * an approval's netted document names what the run's settlement plan sets off on its payout (`amount_minor`) and,
--     for an invoice the plan leaves partly or wholly open (older invoices taken first, the pool's cap, a deferred
--     plan), the remainder with the date it is set off by at the latest — the next run, by the issue date plus the
--     mandate's `invoice_payment_days` (30 without, never more than 45), as OQ-72 has it for a corrective invoice —,
--     also its `due_date` (the `invoice_overdue` alert's) (legal#4, figures#4);
--   * `transfer` says whether the run transfers anything: when N = 0 the plan is posted at approval, with no transfer
--     (legal#5).
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
  v_professional boolean;
  v_proceeding jsonb;
  v_plan jsonb;
  v_transfer boolean;
  v_exec date;
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

  -- the parties, the indemnity (L441-9 I, L441-10 II, D441-5: 40 €, stated to every professional buyer; the latest
  -- proceeding of the client recorded by the issue date kept beside it, for the dunning step), the own account a due
  -- invoice is paid to
  v_seller := private.invoice_party(p_organization_id);
  v_buyer := private.invoice_party(p_client_organization_id);
  v_professional := coalesce((v_buyer ->> 'is_professional')::boolean, false);
  select jsonb_build_object('kind', e.kind, 'effective_date', e.effective_date) into v_proceeding
  from public.client_status_event e
  where e.client_organization_id = p_client_organization_id and e.kind in ('proceeding_opened', 'liquidation')
    and e.effective_date <= v_issue
  order by e.effective_date desc, e.recorded_at desc, e.id desc limit 1;
  select jsonb_build_object('iban', b.iban, 'bic', b.bic, 'holder', o.legal_name) into v_own
  from public.bank_account b join public.organization o on o.id = b.organization_id
  where b.id = v_set.own_bank_account_id;
  -- an approval's netted documents are set off with its run, as far as its settlement plan (the draft's, approved
  -- here) sets them off: on its payout of the requested date, or on the approval date when nothing is transferred
  -- (N = 0, the plan posted at approval); a due document's date is its due date (legal review #4, round 2)
  if p_reason = 'commission' and v_run.id is not null then
    select d.plan into v_plan from private.remittance_draft d where d.run_id = v_run.id;
    v_transfer := coalesce(v_run.net_minor, 0) > 0;
    v_exec := coalesce(v_run.requested_execution_date, v_issue);
  end if;

  drop table if exists pg_temp._docs;
  create temp table _docs on commit drop as
  select x.ord::integer as entry_no, (x.doc ->> 'id')::uuid as id, x.doc ->> 'ref' as ref, x.doc ->> 'key' as key,
         x.doc ->> 'kind' as kind, (x.doc ->> 'mandate_id')::uuid as mandate_id,
         (x.doc ->> 'ht')::bigint as ht, (x.doc ->> 'vat')::bigint as vat, (x.doc ->> 'ttc')::bigint as ttc,
         (x.doc ->> 'vat_rate')::numeric as vat_rate,
         case when x.doc ->> 'kind' = 'invoice' and x.doc ->> 'settlement' = 'due' then 'due' else 'netted' end
           as settlement,
         -- what the run's plan sets off on this document (a run's own documents only)
         pl.planned,
         -- a due invoice's date, a corrective invoice's set off on the next run at the latest by then (OQ-72), and
         -- the date by which the next run sets off what this run's plan leaves of a netted invoice (legal#4): the
         -- mandate's term, 30 days without one, never more than 45 after issue (L441-10 I)
         case when x.doc ->> 'kind' = 'invoice'
                   and (x.doc ->> 'settlement' = 'due' or x.doc ->> 'payment' = 'next_run'
                        or (v_plan is not null and pl.planned < (x.doc ->> 'ttc')::bigint))
              then v_issue + least(coalesce((x.doc ->> 'due_days')::integer, tm.days, 30), 45) end as due_date,
         (x.doc ->> 'due_days')::integer as due_days, x.doc,
         coalesce((x.doc ->> 'service_from')::date, v_run.service_from) as service_from,
         coalesce((x.doc ->> 'service_to')::date, v_run.service_to) as service_to,
         v_last + x.ord::integer as seq,
         coalesce((select sum((c ->> 'vat_pending')::bigint) from jsonb_array_elements(x.doc -> 'corrections') c), 0)
           as v_pending,
         coalesce((select sum((c ->> 'vat_collected')::bigint) from jsonb_array_elements(x.doc -> 'corrections') c), 0)
           as v_collected
  from jsonb_array_elements(p_docs) with ordinality x (doc, ord)
  cross join lateral (select coalesce(sum((s ->> 'amount')::bigint), 0)::bigint as planned
                      from jsonb_array_elements(coalesce(v_plan -> 'settles', '[]')) s
                      where s ->> 'ref' = x.doc ->> 'ref') pl
  left join lateral (select (mt.remittance_terms ->> 'invoice_payment_days')::integer as days
                     from public.mandate_terms mt
                     where mt.mandate_id = (x.doc ->> 'mandate_id')::uuid and mt.valid_from <= v_issue
                       and (mt.valid_to is null or v_issue < mt.valid_to)
                     order by mt.valid_from desc limit 1) tm on true;
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
           v_doc.service_from, v_doc.service_to, 'EUR', v_doc.ht, case when v_doc.kind = 'invoice' then v_doc.vat_rate end,
           v_doc.vat,
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
            'service_period', jsonb_build_object('from', v_doc.service_from, 'to', v_doc.service_to),
            'lines', coalesce(v_doc.doc -> 'lines', '[]'),
            'corrections', coalesce(v_doc.doc -> 'corrections', '[]'),
            'totals', jsonb_build_object('ht_minor', v_doc.ht::text, 'vat_minor', v_doc.vat::text, 'ttc_minor', v_doc.ttc::text,
                                         'vat_rate', v_doc.vat_rate::text, 'currency', 'EUR'),
            'settlement', jsonb_build_object('mode', v_doc.settlement, 'clause_ref', v_doc.doc ->> 'clause_ref',
                                             'due_days', v_doc.due_days),
            -- the mentions that change over time, as in force at issue (L441-9 I; legal review #4)
            'due_date', v_doc.due_date,
            -- netted documents only: what the run sets off (its payout of the requested date; the approval date and
            -- no transfer when N = 0) and the remainder set off on the next run by a date, or all of it on the next
            -- run by a date; a due one is paid by its due date to the own account below
            'payment_reference', case when v_doc.settlement = 'netted' then
                                   case when v_doc.doc ->> 'payment' = 'next_run'
                                          or (v_plan is not null and v_doc.kind = 'invoice' and v_doc.planned = 0)
                                        then jsonb_build_object('mode', 'next_run', 'latest_date', v_doc.due_date)
                                             || case when v_plan is not null
                                                     then jsonb_build_object('amount_minor', v_doc.ttc::text)
                                                     else '{}' end
                                        when v_plan is not null
                                        then jsonb_build_object('mode', 'run', 'run_number', v_run.number,
                                                                'execution_date', v_exec, 'transfer', v_transfer,
                                                                'amount_minor', v_doc.planned::text)
                                             || case when v_doc.kind = 'invoice' and v_doc.planned < v_doc.ttc
                                                     then jsonb_build_object(
                                                            'remainder_minor', (v_doc.ttc - v_doc.planned)::text,
                                                            'latest_date', v_doc.due_date)
                                                     else '{}' end
                                        when p_reason = 'commission' and v_run.id is not null
                                        then jsonb_build_object('mode', 'run', 'run_number', v_run.number,
                                                                'execution_date', v_exec, 'transfer', v_transfer)
                                   end end,
            'own_account', case when v_doc.settlement = 'due' then v_own end,
            'penalty_text', coalesce(v_set.penalty_text,
              'Pénalités de retard : taux d''intérêt appliqué par la Banque centrale européenne à son opération de '
              'refinancement la plus récente, majoré de 10 points de pourcentage.'),
            'flat_indemnity', jsonb_build_object('applies', v_professional,
                                                 'amount_minor', case when v_professional then '4000' end,
                                                 'proceeding', v_proceeding),
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


-- Redefined from 20261112090000 (M2c-5 review; same settings and grants): the documents the job could not draw
-- (`remittance_document_failed`) or has not drawn within 24 hours (`remittance_document_missing`, §15
-- `document_missing`; review perf#2), and in `invoice_overdue` the remainder of a run's netted invoice its plan did not
-- set off, by the date the invoice states (review legal#4).
-- p_today: the Paris date the checks hold the books to (today; another date only for tests). Every check reads the
-- books in ONE statement, so in one snapshot; the breach rows are written by the same statement, from the same
-- deadlines (computed once). Plans hold whatever the statistics: the deadlines' readers drive from the rows they are
-- about by key, and nothing here scans a table an index can serve (ARCHITECTURE §4).
create or replace function private.run_remittance_checks(p_check_run_id uuid, p_organization_id uuid,
                                                         p_today date default null)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_today date := coalesce(p_today, private.paris_today());
  v_since timestamptz;      -- the previous check run of the servicer
  v_full boolean;           -- I16 over every run (Sundays, or the first check run), else over the runs changed lately
  v_failures timestamptz;   -- the schedule's failures reported from (at least the last 24 hours)
begin
  select max(c.started_at) into v_since from public.payment_check_run c
  where c.organization_id = p_organization_id and c.id <> p_check_run_id and c.finished_at is not null;
  v_full := v_since is null or extract(isodow from v_today) = 7;
  v_failures := least(coalesce(v_since, clock_timestamp()), clock_timestamp() - interval '24 hours');

  with dl as materialized (     -- the collections waiting, of files under a mandate with terms (review legal#2)
    select * from private.pending_item_deadlines(p_organization_id) d where d.monitored),
  ol as materialized (          -- the collections of runs approved or sent, not debited by their date (legal#3)
    select * from private.inflight_overdue_lines(p_organization_id, v_today)),
  ua as materialized (          -- money matched to a file, not allocated (legal#7, perf#0)
    select * from private.unallocated_payment_deadlines(p_organization_id)),
  -- I21: a positive collection not paid by its latest execution date — one month after E when its mandate's delay
  -- cannot be met (review legal#1) — writes a breach row, once; one the calendar cannot place has no date to hold it
  -- to (its alert below)
  waiting_breach as (
    insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                   run_id, deadline, latest_execution_date)
    select p_organization_id, d.client_organization_id, d.ledger_entry_id, d.payment_id, d.draft_run_id,
           d.check_deadline, d.check_latest_execution_date
    from dl d where not d.out_of_horizon and d.check_latest_execution_date < v_today
    on conflict (ledger_entry_id) do nothing),
  -- … and so does a collection whose run was approved but whose payout is not debited by then (§9.2: paid means
  -- debited; until M2c-6 books payouts, every approved run's collections are held to it)
  inflight_breach as (
    insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                   run_id, deadline, latest_execution_date, requested_execution_date,
                                                   late_reason)
    select p_organization_id, o.client_organization_id, o.ledger_entry_id, o.payment_id, o.run_id, o.deadline,
           o.latest_execution_date, o.requested_execution_date, o.late_reason
    from ol o where not o.out_of_horizon
    on conflict (ledger_entry_id) do nothing)
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, u.code, u.severity, u.subject_type, u.subject_id, u.currency,
         u.amount_minor, u.count, u.oldest_days, coalesce(u.details, '{}')
  from (
  -- (I14 is in run_payment_checks)
  -- I15: an item both waiting and in a live line
  select 'remittance_item_twice'::text, 'violation'::text, 'ledger_entry'::text, q.ledger_entry_id, q.currency::char(3),
         q.amount_minor::bigint, null::integer, null::integer, '{}'::jsonb
  from private.remittance_pending q
  join public.remittance_line l on l.ledger_entry_id = q.ledger_entry_id and not l.released
  where q.organization_id = p_organization_id
  union all
  -- I16: a run's arithmetic — gross = Σ lines, N + D = gross, N ≥ 0, the payout = N, documents' HT = Σ line
  -- commissions. A run's lines and totals are frozen once approved: each run is read in one pass over its lines, the
  -- runs changed since the previous check run (with a day's margin), every run on Sundays (review perf#5).
  select 'remittance_run_totals', 'violation', 'remittance_run', r.id, r.currency, r.gross_minor, null, null,
         jsonb_build_object('number', r.number, 'lines_minor', l.gross::text, 'documents_ht_minor', s.docs::text,
                            'commission_minor', (l.charged + s.repriced)::text)
  from public.remittance_run r
  cross join lateral (select coalesce(sum(x.amount_minor), 0) as gross, count(*) as n,
                             coalesce(sum(x.commission_minor) filter (where x.commission_state = 'charged'), 0)
                               as charged
                      from public.remittance_line x where x.run_id = r.id) l
  cross join lateral (
    select (select coalesce(sum(i.ht_minor), 0) from public.commission_invoice i
            where i.run_id = r.id and i.reason = 'commission') as docs,
           (select coalesce(sum(x.commission_minor), 0) from public.remittance_line_repricing x
            where x.pricing_run_id = r.id and x.commission_state = 'charged') as repriced,
           (select t.amount_minor from public.bank_transfer t where t.id = r.transfer_id) as payout) s
  where r.organization_id = p_organization_id and r.status in ('approved', 'sent', 'booked', 'cancelled')
    and r.approved_at is not null and (v_full or r.updated_at > v_since - interval '1 day')
    and (l.gross <> r.gross_minor or l.n <> r.line_count or r.net_minor < 0
         or r.net_minor + r.settlement_minor <> r.gross_minor or s.docs <> l.charged + s.repriced
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
    -- the entry's postings by key first, then each one's account by key (plan robustness, ARCHITECTURE §4)
    select coalesce(sum(p.amount_minor) filter (where la.book = 'commission_receivable'), 0) as receivable,
           coalesce(sum(p.amount_minor) filter (where la.book = 'servicer_revenue'), 0) as revenue
    from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
          where q.entry_id = i.ledger_entry_id offset 0) p
    cross join lateral (select a.book from public.ledger_account a where a.id = p.ledger_account_id offset 0) la) e
  where i.organization_id = p_organization_id and (e.receivable <> i.ttc_minor or e.revenue <> -i.ht_minor)
  union all
  -- I18: per client, Σ open invoices − Σ refunds owed = 4111[c]; 44574 = Σ pending VAT of the documents (the client's
  -- and the servicer's pooled accounts by their indexes: 4111 has no portfolio, 44574 no claim item; review perf#2)
  select 'settlement_ledger', 'violation', 'client', y.client_organization_id, 'EUR', (y.ledger - y.docs)::bigint, null,
         null, jsonb_build_object('documents_minor', y.docs::text, 'ledger_minor', y.ledger::text)
  from (select c.client_organization_id,
               coalesce((select sum(private.document_open(i.id) * case i.kind when 'invoice' then 1 else -1 end)
                         from public.commission_invoice i where i.client_organization_id = c.client_organization_id),
                        0) as docs,
               coalesce((select sum(p.amount_minor) from public.ledger_account la
                         join public.ledger_posting p on p.ledger_account_id = la.id
                         where la.book = 'commission_receivable' and la.client_organization_id = c.client_organization_id
                           and la.portfolio_id is null),
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
                         where la.organization_id = p_organization_id and la.book = 'vat_pending'
                           and la.claim_item_id is null), 0) as ledger) v
  where v.docs <> v.ledger
  union all
  -- I21: collections waiting past the date they are held to (violation, per client)
  select 'remittance_deadline_breached', 'violation', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, max(v_today - d.check_latest_execution_date),
         jsonb_build_object('earliest_latest_execution_date', min(d.check_latest_execution_date),
                            'unmeetable', count(*) filter (where d.unmeetable),
                            'ids', (array_agg(d.ledger_entry_id order by d.check_latest_execution_date))[1:50])
  from dl d where not d.out_of_horizon and d.check_latest_execution_date < v_today
  group by d.client_organization_id, d.currency
  union all
  -- … whose mandate's delay could not be met (OQ-71: « délai intenable », an alert) while the month still runs
  select 'remittance_delay_unmeetable', 'alert', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, max(v_today - d.latest_execution_date),
         jsonb_build_object('earliest_latest_execution_date', min(d.latest_execution_date),
                            'one_month_latest_execution_date', min(d.check_latest_execution_date),
                            'ids', (array_agg(d.ledger_entry_id order by d.latest_execution_date))[1:50])
  from dl d
  where d.unmeetable and not d.out_of_horizon and d.latest_execution_date < v_today
    and d.check_latest_execution_date >= v_today
  group by d.client_organization_id, d.currency
  union all
  -- due soon (D-5 business days) and critical (D-1): per client, the earliest date (one month's for an unmeetable
  -- delay)
  select case when min(d.check_alert_critical_date) <= v_today then 'remittance_due_critical'
              else 'remittance_due_soon' end,
         'alert', 'client', d.client_organization_id, d.currency, sum(d.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('earliest_latest_execution_date', min(d.check_latest_execution_date))
  from dl d
  where not d.out_of_horizon and d.check_latest_execution_date >= v_today and d.check_alert_soon_date <= v_today
  group by d.client_organization_id, d.currency
  union all
  -- collections the business calendar cannot place (E before its horizon: long past any deadline; review nc#0)
  select 'remittance_deadline_not_computable', 'alert', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('of', 'items', 'earliest_encaissement_date', min(d.encaissement_date),
                            'ids', (array_agg(d.ledger_entry_id order by d.encaissement_date))[1:50])
  from dl d where d.out_of_horizon
  group by d.client_organization_id, d.currency
  union all
  select 'remittance_deadline_not_computable', 'alert', 'remittance_run', o.run_id, o.currency,
         sum(o.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('of', 'lines', 'number', min(o.number),
                            'ids', (array_agg(o.ledger_entry_id order by o.ledger_entry_id))[1:50])
  from ol o where o.out_of_horizon
  group by o.run_id, o.currency
  union all
  select 'remittance_deadline_not_computable', 'alert', 'servicer', null, u.currency, sum(u.unallocated_minor)::bigint,
         count(*)::integer, null,
         jsonb_build_object('of', 'payments', 'earliest_encaissement_date', min(u.encaissement_date),
                            'ids', (array_agg(u.payment_id order by u.encaissement_date))[1:50])
  from ua u where u.out_of_horizon
  group by u.currency
  union all
  -- a run approved or sent whose payout is not debited by its lines' date (violation; review legal#3) …
  select 'remittance_payout_overdue', 'violation', 'remittance_run', o.run_id, o.currency, sum(o.amount_minor)::bigint,
         count(*)::integer, max(v_today - o.latest_execution_date),
         jsonb_build_object('number', min(o.number), 'earliest_latest_execution_date', min(o.latest_execution_date),
                            'requested_execution_date', min(o.requested_execution_date),
                            'ids', (array_agg(o.ledger_entry_id order by o.latest_execution_date))[1:50])
  from ol o where not o.out_of_horizon
  group by o.run_id, o.currency
  union all
  -- … or by the date it was ordered for (alert)
  select 'remittance_payout_not_executed', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null,
         v_today - r.requested_execution_date,
         jsonb_build_object('number', r.number, 'requested_execution_date', r.requested_execution_date,
                            'transfer_status', (select t.status from public.bank_transfer t where t.id = r.transfer_id))
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status in ('approved', 'sent')
    and r.requested_execution_date < v_today
    and not exists (select 1 from public.bank_transfer t where t.id = r.transfer_id and t.status = 'booked')
  union all
  -- a draft whose payout is blocked, with its reason and its deadline
  select 'payout_blocked', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null, null,
         jsonb_build_object('number', r.number, 'blockers', to_jsonb(r.blockers),
                            'earliest_latest_execution_date', r.earliest_latest_execution_date)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status = 'draft' and r.net_minor > 0
    and cardinality(r.blockers) > 0
  union all
  -- a draft waiting more than one business day; one whose preparation failed at once (nothing retries it before
  -- « Actualiser »; review tests-ui#3)
  select 'draft_waiting', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null,
         private.business_days_between((coalesce(r.prepared_at, (r.last_failure ->> 'at')::timestamptz, r.known_at)
                                        at time zone 'Europe/Paris')::date, v_today),
         jsonb_build_object('number', r.number)
         || case when r.prepared_at is null
                 then jsonb_build_object('prepare_failed', true, 'failure_code', r.last_failure ->> 'code')
                 else '{}'::jsonb end
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status = 'draft'
    and ((r.prepared_at is not null
          and private.business_days_between((r.prepared_at at time zone 'Europe/Paris')::date, v_today) > 1)
         or (r.prepared_at is null and r.job is null and r.last_failure ->> 'step' = 'prepare'))
  union all
  -- an approval more than 2 business days after K (invoice_late)
  select 'invoice_late', 'alert', 'remittance_run', r.id, r.currency, r.invoice_ttc_minor, null, null,
         jsonb_build_object('number', r.number, 'known_at', r.known_at, 'approved_at', r.approved_at)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.invoice_late and r.approved_at > clock_timestamp() - interval '30 days'
  union all
  -- an invoice still open after the date it is paid by (§15 invoice_overdue; L441-10 II: penalties run from the next
  -- day): a due invoice, a cancellation's corrective invoice the next run did not set off in time (legal review #4,
  -- round 2; OQ-72), or a run's netted invoice whose plan left a remainder for the next run by its date (M2c-5 review
  -- legal#4; what its own run sets off is held to that run's payout by the payout checks above)
  select 'invoice_overdue', 'alert', 'commission_invoice', i.id, i.currency, o.open, null, v_today - i.due_date,
         jsonb_build_object('number', i.number, 'client_id', i.client_organization_id, 'settlement', i.settlement,
                            'due_date', i.due_date)
  from public.commission_invoice i
  cross join lateral (select private.document_open(i.id) as open) o
  where i.organization_id = p_organization_id and i.due_date is not null and i.due_date < v_today and o.open > 0
  union all
  -- money matched to a client's file but not allocated (still in 4710) gets the same clock (OQ-26, compliance B7)
  select 'unallocated_deadline', 'alert', 'servicer', null, u.currency, sum(u.unallocated_minor)::bigint,
         count(*)::integer, null,
         jsonb_build_object('earliest_latest_execution_date', min(u.latest_execution_date),
                            'held', count(*) filter (where u.held),
                            'ids', (array_agg(u.payment_id order by u.latest_execution_date))[1:50])
  from ua u where not u.out_of_horizon and u.alert_soon_date <= v_today
  group by u.currency
  union all
  -- the hourly schedule could not create a client's draft, or read its candidates, or its job died (review nc#0)
  select 'remittance_schedule_failed', 'alert', 'servicer', null, null, null, count(*)::integer, null,
         jsonb_build_object('last_failed_at', max(f.failed_at),
                            'last_error', (array_agg(f.error order by f.failed_at desc))[1],
                            'codes', to_jsonb(array_agg(distinct f.code)),
                            'client_ids', to_jsonb(coalesce(array_agg(distinct f.client_organization_id)
                                                              filter (where f.client_organization_id is not null),
                                                            '{}')))
  from private.remittance_schedule_failure f
  where f.organization_id = p_organization_id and f.failed_at >= v_failures
  having count(*) > 0
  union all
  -- documents the job could not draw (M2c-5 review perf#2): each failure is recorded on its row and retried; until it
  -- is drawn, the alert names it with its last error
  select 'remittance_document_failed', 'alert', 'servicer', null, null, null, count(*)::integer,
         max(v_today - (t.created_at at time zone 'Europe/Paris')::date),
         jsonb_build_object('statements', count(*) filter (where t.kind = 'statement'),
                            'invoices', count(*) filter (where t.kind = 'invoice'),
                            'last_failed_at', max(t.last_attempt_at),
                            'last_error', (array_agg(t.last_error order by t.last_attempt_at desc, t.ref_id))[1],
                            'ids', to_jsonb((array_agg(t.ref_id order by t.created_at, t.ref_id))[1:50]))
  from private.remittance_document_todo t
  where t.organization_id = p_organization_id and t.attempts > 0
  having count(*) > 0
  union all
  -- … and the documents still due 24 hours after they were (§15 document_missing): a statement or a PDF the client
  -- space says « en préparation »
  select 'remittance_document_missing', 'alert', 'servicer', null, null, null, count(*)::integer,
         max(v_today - (m.due_since at time zone 'Europe/Paris')::date),
         jsonb_build_object('statements', count(*) filter (where m.kind = 'statement'),
                            'invoices', count(*) filter (where m.kind = 'invoice'),
                            'oldest_due_since', min(m.due_since),
                            'numbers', to_jsonb((array_agg(m.number order by m.due_since, m.ref_id))[1:50]))
  from private.remittance_documents_missing(p_organization_id, interval '24 hours') m
  having count(*) > 0
  union all
  -- reference data (M2c-3): the VAT pack's review, the calendar's horizon
  select a.code, 'alert', 'servicer', null, null, null, null, null, a.details
  from private.reference_data_alerts(v_today) a
  ) u (code, severity, subject_type, subject_id, currency, amount_minor, count, oldest_days, details);
end;
$$;


-- The hourly cron (redefined from 20261112090000): the schedule of each servicer with work, as before, and — review
-- perf#2 — the documents job of each servicer with documents due now (a retry whose delay has passed, or a message
-- that never ran). Returns the number of messages queued.
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
           from orgs),
  docs as (select o.id from public.organization o
           where o.kind = 'servicer' and private.remittance_documents_due(o.id)),
  sent_docs as (select pgmq.send('remittances', jsonb_build_object('type', 'documents', 'organization_id', id)) as m
                from docs)
  select ((select count(*) from sent) + (select count(*) from sent_docs))::integer;
$$;

revoke execute on function private.issue_commission_documents(uuid, uuid, uuid, jsonb, text, boolean),
  private.run_remittance_checks(uuid, uuid, date), private.queue_remittance_schedule()
  from public, anon, authenticated;

-- What is still due at this migration (runs approved and invoices issued before it): queued once.
insert into private.remittance_document_todo (organization_id, kind, ref_id, created_at)
select i.organization_id, 'invoice', i.id, i.created_at from public.commission_invoice i
union all
select r.organization_id, 'statement', r.id, r.approved_at from public.remittance_run r where r.approved_at is not null
on conflict do nothing;
select pgmq.send('remittances', jsonb_build_object('type', 'documents', 'organization_id', o.organization_id))
from (select distinct t.organization_id from private.remittance_document_todo t) o;

------------------------------------------------------------------------------------------
-- Read access (§6.2; OQ-48): money staff; the client's members with access to the whole client — an invoice's PDF
-- only when the buyer accepted electronic invoices (CGI 289 VI); collectors and portfolio-restricted users none
------------------------------------------------------------------------------------------

alter table public.remittance_statement enable row level security;
alter table public.commission_invoice_document enable row level security;
alter table private.remittance_document_todo enable row level security;
revoke all on public.remittance_statement, public.commission_invoice_document from public, anon, authenticated;
revoke all on private.remittance_document_todo from public, anon, authenticated;
grant select on public.remittance_statement, public.commission_invoice_document to authenticated;

create policy remittance_statement_read on public.remittance_statement for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or client_organization_id = any ((select private.client_whole_org_ids())::uuid[]));
create policy commission_invoice_document_read on public.commission_invoice_document for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[])
         or (electronic and client_organization_id = any ((select private.client_whole_org_ids())::uuid[])));

-- Who reads a statement's or an invoice's file (row and object).
create or replace function private.can_read_remittance_document(p_document_id uuid, p_kind text,
                                                               p_organization_id uuid,
                                                               p_client_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_organization_id = any (private.money_staff_org_ids())
      or (p_client_organization_id = any (private.client_whole_org_ids())
          and (p_kind <> 'commission_invoice_pdf'
               or exists (select 1 from public.commission_invoice_document d
                          where d.document_id = p_document_id and d.electronic)));
$$;
create or replace function private.can_read_remittance_document_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.document d
                 where d.storage_bucket = 'documents' and d.storage_path = p_name
                   and d.kind in ('remittance_statement_pdf', 'remittance_statement_csv', 'commission_invoice_pdf')
                   and private.can_read_remittance_document(d.id, d.kind, d.organization_id,
                                                            d.client_organization_id));
$$;
create policy remittance_document_object_read on storage.objects for select to authenticated
  using (bucket_id = 'documents' and (name like 'statements/%' or name like 'invoices/%')
         and (select private.can_read_remittance_document_object(name)));
-- document_read lets every staff member and every member of the client read its documents; these kinds are narrower.
create policy document_remittance_scope on public.document as restrictive for select to authenticated
  using (kind not in ('remittance_statement_pdf', 'remittance_statement_csv', 'commission_invoice_pdf')
         or private.can_read_remittance_document(id, kind, organization_id, client_organization_id));

------------------------------------------------------------------------------------------
-- Client space (§17.7): what is owed today, the run in flight, the next scheduled run
------------------------------------------------------------------------------------------

-- The next run day of the client's mandates on or after p_from (design §9.3, founder #1: the 1st and the 16th — the
-- rule pack's twice_monthly_days, which the parity test checks — or the mandate's weekday, each moved to the next
-- business day); null when none of its mandates has terms in force. The deadline guard may run earlier.
create or replace function private.next_scheduled_run_day(p_client_organization_id uuid, p_from date)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select min(x.run_day)
  from (select distinct (mt.remittance_terms ->> 'frequency') as frequency,
               (mt.remittance_terms ->> 'weekday')::integer as weekday
        from public.mandate m
        join public.mandate_terms mt on mt.mandate_id = m.id and mt.valid_from <= p_from
          and (mt.valid_to is null or p_from < mt.valid_to)
        where m.client_organization_id = p_client_organization_id
          and jsonb_typeof(mt.remittance_terms) = 'object') t
  cross join lateral generate_series(p_from - 7, p_from + 40, interval '1 day') g (ts)
  cross join lateral (select q.day, q.closed from public.business_calendar q
                      where q.scope = 'FR-conservative' and q.day = g.ts::date) c
  cross join lateral (select case when c.closed then private.next_business_day(c.day) else c.day end as run_day) x
  where case t.frequency when 'weekly' then extract(isodow from c.day) = t.weekday
                         else extract(day from c.day) in (1, 16) end
    and x.run_day >= p_from;
$$;

-- What the client space shows (§17.7): per currency, what is owed today (the client's running 4670 balance: a credit
-- is owed to the client, all dates) and how much of it the runs approved or sent and not booked already cover (their
-- gross leaves 4670 only at the payout's debit, M2c-6), each run with its net to transfer and what it sets off — so
-- that nothing reads as an extra amount (review tests-ui#5): gross = net + commission + advances − refund. The runs
-- in flight (as before), the next scheduled run day.
create or replace function public.client_remittance_summary(p_client_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.organization;
  v_owed jsonb;
  v_flight jsonb;
  v_today date := private.paris_today();
begin
  select * into c from public.organization where id = p_client_organization_id;
  if not found or not (c.id = any (private.client_whole_org_ids())
                       or c.servicer_organization_id = any (private.money_staff_org_ids())) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('currency', x.currency, 'owed_minor', x.owed::text,
                                               'in_flight_gross_minor', x.gross::text, 'in_flight_runs', x.runs)
                            order by x.currency), '[]')
  into v_owed
  from (select coalesce(b.currency, f.currency) as currency, coalesce(-b.balance_minor, 0) as owed,
               coalesce(f.gross, 0) as gross, coalesce(f.runs, '[]'::jsonb) as runs
        from (select y.currency, y.balance_minor from private.client_payable_balance y
              where y.client_organization_id = c.id and y.balance_minor <> 0) b
        full join (select r.currency, sum(r.gross_minor) as gross,
                          jsonb_agg(jsonb_build_object(
                            'number', r.number, 'status', r.status,
                            'gross_minor', r.gross_minor::text, 'net_minor', r.net_minor::text,
                            'commission_minor', coalesce(r.commission_taken_minor, 0)::text,
                            'advance_minor', coalesce(r.advance_recovered_minor, 0)::text,
                            'refund_minor', coalesce(r.refund_minor, 0)::text,
                            'requested_execution_date', r.requested_execution_date)
                            order by r.approved_at, r.number) as runs
                   from public.remittance_run r
                   where r.client_organization_id = c.id and r.status in ('approved', 'sent')
                   group by r.currency) f on f.currency = b.currency) x;
  select coalesce(jsonb_agg(jsonb_build_object('number', r.number, 'status', r.status, 'currency', r.currency,
                                               'net_minor', r.net_minor::text,
                                               'requested_execution_date', r.requested_execution_date,
                                               'approved_on', (r.approved_at at time zone 'Europe/Paris')::date)
                            order by r.approved_at), '[]')
  into v_flight from public.remittance_run r
  where r.client_organization_id = c.id and r.status in ('approved', 'sent');
  return jsonb_build_object('owed', v_owed, 'in_flight', v_flight,
                            'next_run_day', private.next_scheduled_run_day(c.id, v_today + 1),
                            'today', v_today);
end;
$$;

------------------------------------------------------------------------------------------
-- The accountant's export (§14.2; money staff at aal2): the invoices and credit notes of a period with their
-- settlements, and the postings of the servicer's books (7060, 44571, 44574, 6270, 6780, 4111, 4112, 5122) in it.
-- Not a FEC: the servicer's general ledger is out of scope (§1).
--
-- Paged (review perf#0: the API returns at most 1,000 rows a call): each call returns up to p_limit rows (1,000 at
-- most) after the row whose `page_key` is p_after, in the export's order; the caller asks again with the last row's
-- key until a page comes back shorter. A key is opaque text, increasing in that order.
------------------------------------------------------------------------------------------

-- The documents issued in the period, by number; what settled them by the period's end and what was still open then
-- (review figures#7: a closed period exports the same figures whenever it is exported, as the entries do).
create or replace function public.accounting_export_documents(p_from date, p_to date, p_after text default null,
                                                             p_limit integer default 1000)
returns table (number text, kind text, issue_date date, client_name text, client_siren text, mandate text,
               run_number text, service_from date, service_to date, ht_minor bigint, vat_rate numeric,
               vat_minor bigint, ttc_minor bigint, vat_book text, settlement text, due_date date, corrects text,
               settled_minor bigint, settlements text, open_minor bigint, page_key text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid := (private.money_staff_org_ids())[1];
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 1000);
  v_year integer;
  v_seq integer;
  v_id uuid;
begin
  if v_org is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'accounting export refused: period' using errcode = '22023';
  end if;
  if p_after is not null then
    begin
      v_year := split_part(p_after, ':', 1)::integer;
      v_seq := split_part(p_after, ':', 2)::integer;
      v_id := split_part(p_after, ':', 3)::uuid;
    exception when others then
      raise exception 'accounting export refused: page' using errcode = '22023';
    end;
  end if;
  return query
  select i.number, i.kind, i.issue_date, cl.legal_name, cl.siren, m.reference, r.number, i.service_from, i.service_to,
         i.ht_minor, i.vat_rate, i.vat_minor, i.ttc_minor, i.vat_book, i.settlement, i.due_date,
         (select string_agg(o.number, ' ' order by o.seq) from public.commission_credit_correction cc
          cross join lateral (select q.number, q.seq from public.commission_invoice q
                              where q.id = cc.original_invoice_id offset 0) o
          where cc.credit_note_id = i.id),
         coalesce(s.amount, 0)::bigint, s.detail,
         case when i.kind = 'invoice' then (i.ttc_minor - coalesce(s.amount, 0))::bigint end,
         lpad(i.year::text, 4, '0') || ':' || lpad(i.seq::text, 10, '0') || ':' || i.id::text
  from public.commission_invoice i
  cross join lateral (select q.legal_name, q.siren from public.organization q where q.id = i.client_organization_id
                      offset 0) cl
  cross join lateral (select q.reference from public.mandate q where q.id = i.mandate_id offset 0) m
  left join lateral (select q.number from public.remittance_run q where q.id = i.run_id offset 0) r on true
  left join lateral (
    select sum(x.amount_minor) as amount,
           string_agg(x.kind || ' ' || to_char(x.settled_on, 'YYYY-MM-DD') || ' ' || x.amount_minor::text, ' | '
                      order by x.settled_on, x.created_at, x.id) as detail
    from public.commission_settlement x
    where x.document_id = i.id and x.document_kind = 'invoice' and x.settled_on <= p_to) s on true
  where i.organization_id = v_org and i.issue_date between p_from and p_to
    and (p_after is null or (i.year, i.seq, i.id) > (v_year, v_seq, v_id))
  order by i.year, i.seq, i.id
  limit v_limit;
end;
$$;

-- The postings of the period, by date, posting time, entry and line. Every lookup is keyed (review perf#1): a
-- posting's document or run by its id (the source id cast under its type), its client by id; the servicer's
-- accounts of the eight books by the pooled index, their postings of the period by account and date.
create or replace function public.accounting_export_entries(p_from date, p_to date, p_after text default null,
                                                           p_limit integer default 1000)
returns table (effective_date date, entry_id uuid, entry_type text, source_type text, source_ref text,
               client_name text, account_number text, book text, debit_minor bigint, credit_minor bigint,
               currency char(3), posted_at timestamptz, page_key text)
language plpgsql
stable
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare
  v_org uuid := (private.money_staff_org_ids())[1];
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 1000);
  v_date date;
  v_posted timestamptz;
  v_entry uuid;
  v_line integer;
begin
  if v_org is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'accounting export refused: period' using errcode = '22023';
  end if;
  if p_after is not null then
    begin
      v_date := split_part(p_after, '|', 1)::date;
      v_posted := (split_part(p_after, '|', 2) || '+00')::timestamptz;
      v_entry := split_part(p_after, '|', 3)::uuid;
      v_line := split_part(p_after, '|', 4)::integer;
    exception when others then
      raise exception 'accounting export refused: page' using errcode = '22023';
    end;
  end if;
  return query
  select p.effective_date, e.id, e.entry_type, e.source_type,
         coalesce(case e.source_type
                    when 'commission_invoice'
                      then (select i.number from public.commission_invoice i where i.id = e.source_id::uuid)
                    when 'remittance_run'
                      then (select x.number from public.remittance_run x where x.id = e.source_id::uuid) end,
                  e.source_id),
         (select o.legal_name from public.organization o where o.id = la.client_organization_id),
         b.account_number, la.book,
         case when p.amount_minor > 0 then p.amount_minor else 0 end::bigint,
         case when p.amount_minor < 0 then -p.amount_minor else 0 end::bigint,
         p.currency, e.posted_at,
         to_char(p.effective_date, 'YYYY-MM-DD') || '|'
           || to_char(e.posted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|' || e.id::text || '|'
           || lpad(p.line_no::text, 6, '0')
  from public.ledger_account la
  cross join lateral (select q.account_number from public.ledger_book q where q.code = la.book offset 0) b
  cross join lateral (select q.* from public.ledger_posting q
                      where q.ledger_account_id = la.id
                        and q.effective_date between greatest(p_from, coalesce(v_date, p_from)) and p_to
                      offset 0) p
  cross join lateral (select q.* from public.ledger_entry q where q.id = p.entry_id offset 0) e
  where la.organization_id = v_org and la.claim_item_id is null
    and la.book in ('servicer_revenue', 'vat_collected', 'vat_pending', 'bank_fees', 'servicer_losses',
                    'commission_receivable', 'client_advance_receivable', 'own_cash')
    and (p_after is null or (p.effective_date, e.posted_at, e.id, p.line_no) > (v_date, v_posted, v_entry, v_line))
  order by p.effective_date, e.posted_at, e.id, p.line_no
  limit v_limit;
end;
$$;

------------------------------------------------------------------------------------------
-- Functions: the reads are the API's; the job's the worker's (service role); the rest internal
------------------------------------------------------------------------------------------

revoke execute on function private.queue_invoice_documents(), private.queue_statement(),
  private.remittance_statement_line_columns(), private.iban_masked(text), private.remittance_statement_build(uuid),
  private.remittance_documents_begin(uuid, integer, integer), private.remittance_documents_due(uuid),
  private.remittance_document_failed(uuid, text, uuid, text), private.remittance_statement_path(uuid, uuid, text),
  private.commission_invoice_path(uuid, uuid, integer, text), private.remittance_statement_prepare(uuid),
  private.commission_invoice_render_rows(uuid[]), private.remittance_documents_record(uuid, text, text, text),
  private.remittance_document_orphans(uuid, interval, integer), private.remittance_documents_missing(uuid, interval),
  private.can_read_remittance_document(uuid, text, uuid, uuid), private.can_read_remittance_document_object(text),
  private.next_scheduled_run_day(uuid, date)
  from public, anon, authenticated;
-- the RLS and storage helpers run as the caller
grant execute on function private.can_read_remittance_document(uuid, text, uuid, uuid),
  private.can_read_remittance_document_object(text) to authenticated;
grant execute on function private.remittance_documents_begin(uuid, integer, integer),
  private.remittance_documents_due(uuid), private.remittance_document_failed(uuid, text, uuid, text),
  private.remittance_statement_prepare(uuid), private.remittance_statement_build(uuid),
  private.commission_invoice_render_rows(uuid[]), private.remittance_documents_record(uuid, text, text, text),
  private.remittance_document_orphans(uuid, interval, integer), private.remittance_documents_missing(uuid, interval),
  private.next_scheduled_run_day(uuid, date)
  to service_role;
revoke execute on function public.client_remittance_summary(uuid),
  public.accounting_export_documents(date, date, text, integer),
  public.accounting_export_entries(date, date, text, integer) from public, anon;
grant execute on function public.client_remittance_summary(uuid),
  public.accounting_export_documents(date, date, text, integer),
  public.accounting_export_entries(date, date, text, integer) to authenticated;

-- Review M2c-5, round 2 (legal#6): the approver's free text is staff data (GDPR minimisation). The statement prints a
-- cause category (K5); the reason itself stays with money staff. A client member read it through PostgREST in two
-- places: the late approvals (M2c-4 let the whole client read them) and remittance_run's columns. The cancellation
-- reason and the job's last failure are staff free texts too. Staff read runs through the SECURITY DEFINER
-- remittance_run_detail; the client space reads status and amounts only (remittance_run!run_id embed, K7).
drop policy remittance_late_approval_read on public.remittance_late_approval;
create policy remittance_late_approval_read on public.remittance_late_approval for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[]));
revoke select on public.remittance_run from authenticated;
grant select (id, organization_id, client_organization_id, currency, number, status, trigger, schedule_key, job,
              job_token, job_queued_at, version, known_at, prepared_at, previous_run_id, service_from, service_to,
              item_count, line_count, gross_minor, invoice_ht_minor, invoice_vat_minor, invoice_ttc_minor,
              credit_ht_minor, credit_vat_minor, credit_ttc_minor, commission_taken_minor, advance_recovered_minor,
              refund_minor, settlement_minor, net_minor, vat_rate, earliest_deadline, earliest_latest_execution_date,
              unmeetable_count, requested_execution_date, payout_account_id, payout_snapshot, blockers,
              commission_blockers, engine_version, inputs_hash, settlement_plan, transfer_id, approval_requested_by,
              approved_by, approved_at, invoice_late, booked_on, cancelled_by, cancelled_at, created_by, created_at,
              updated_at)
  on public.remittance_run to authenticated;

-- CI scale run of PR #26: the remittance line insert guard (M2c-4) took 149 s for a 50k-line approval. Its lateral joined
-- ledger_posting to ledger_account with a filter on the account's book; with the statistics of a crowded database the
-- planner started from the client's single 4670 account and BitmapAnd-ed its postings with the entry's, once per line:
-- quadratic in the account's postings. The lateral now reads the entry's postings by key (2 to 6 rows, offset 0 keeps
-- it a separate plan) and each posting's account by its key, so no estimate can turn it around (ARCHITECTURE §4).
create or replace function private.remittance_line_insert_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_bad text;
begin
  if exists (select 1 from (select distinct n.run_id, n.organization_id, n.client_organization_id, n.currency
                            from new_rows n) n
             left join lateral (select r.organization_id, r.client_organization_id, r.currency
                                from public.remittance_run r where r.id = n.run_id offset 0) r on true
             where (r.organization_id, r.client_organization_id, r.currency)
                   is distinct from (n.organization_id, n.client_organization_id, n.currency)) then
    raise exception 'remittance line: its run''s servicer, client and currency' using errcode = 'check_violation';
  end if;
  select min(n.run_id || '/' || n.line_no) into v_bad
  from new_rows n
  cross join lateral (
    select coalesce(-sum(p.amount_minor), 0) as owed, min(la.client_organization_id::text) as client,
           min(la.currency) as currency, count(*) as n
    from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
          where q.entry_id = n.ledger_entry_id offset 0) p
    cross join lateral (select a.client_organization_id, a.currency from public.ledger_account a
                        where a.id = p.ledger_account_id and a.book = 'client_payable' offset 0) la) x
  where x.n = 0 or x.owed <> n.amount_minor or x.client <> n.client_organization_id::text or x.currency <> n.currency;
  if v_bad is not null then
    raise exception 'remittance line %: not the 4670 posting of its entry for the run''s client and currency', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
revoke execute on function private.remittance_line_insert_guard() from public, anon, authenticated;
