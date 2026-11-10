-- M2c-5 Documents (M2-14 statement, M2-15 PDF; design docs/design/m2c-remittances.md §10, §14, §16, §17, §19, §21;
-- ADR-0014 M2c-5 addendum; founder decisions #3, #12 of 2026-11-09).
--
--   * the client statement (« Relevé de reversement », C. civ. 1993 « rendre compte »): its payload built in SQL, once,
--     from the run's frozen lines and repricings, its entries, documents and settlement plan, the payout ordered and the
--     identities as they stand when it is drawn (`private.remittance_statement_build`, canonical jsonb, amounts as text in
--     minor units, dates ISO); the worker renders the CSV and the PDF from it (deterministic bytes), both stored in the
--     private bucket with their SHA-256 (`public.remittance_statement`, append-only);
--   * the PDF of every commission invoice and credit note, rendered by the worker from the payload M2c-4 froze at issue
--     (never from the current settings; locked template `facture-commission-fr-1`), stored with its SHA-256
--     (`public.commission_invoice_document`, append-only); whether the buyer accepted electronic invoices (CGI 289 VI)
--     is read from that payload: without it the client space lists the invoice « adressée par courrier » and does not
--     serve its PDF;
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
-- Nothing earlier is redefined.

------------------------------------------------------------------------------------------
-- Documents to draw (one row per invoice, credit note or approved run without its files)
------------------------------------------------------------------------------------------

create table private.remittance_document_todo (
  organization_id uuid not null references public.organization (id),
  kind text not null check (kind in ('invoice', 'statement')),
  ref_id uuid not null,                   -- commission_invoice.id or remittance_run.id
  created_at timestamptz not null default clock_timestamp(),
  primary key (kind, ref_id)
);
create index remittance_document_todo_org_idx on private.remittance_document_todo (organization_id, created_at, ref_id);
comment on table private.remittance_document_todo is
  'Statements and invoice PDFs still to draw (deleted when the documents job records them).';

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
create or replace function private.remittance_statement_line_columns()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '["line_no", "mandate", "portfolio", "file", "debtor", "items", "components", "nature", "nature_reason",
           "from_run", "encaissement_date", "effective_date", "deadline", "amount_minor", "rules", "rates",
           "basis_minor", "commission_minor", "commission_state", "invoice", "receipt", "late", "late_reason"]'::jsonb;
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

-- Builds the payload of the run's statement and keeps it in pg_temp._rd_statement for the record step (the worker
-- renders the files from the returned copy). Keyed lookups from the run's lines (ARCHITECTURE §4): each line's file,
-- borrower, mandate, portfolio, items and components (its entry's 1100 postings), notification reason, invoice,
-- receipt and late approval by their keys, whatever the statistics.
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
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or r.approved_at is null then
    raise exception 'statement of %: not an approved run', p_run_id using errcode = 'check_violation';
  end if;
  select c.minor_exponent into v_exp from public.currency c where c.code = r.currency;
  v_k_day := (r.known_at at time zone 'Europe/Paris')::date;
  v_issue := (r.approved_at at time zone 'Europe/Paris')::date;

  -- the run's lines, then the earlier lines whose commission this run priced (amount 0: remitted then)
  drop table if exists pg_temp._rd_line;
  create temp table _rd_line on commit drop as
  select 0 as section, l.line_no, l.line_no as source_line_no, null::text as from_run, l.kind, l.ledger_entry_id,
         l.account_id, l.portfolio_id, l.mandate_id, l.payment_id, l.encaissement_date, l.effective_date, l.deadline,
         l.amount_minor, l.commission_minor, l.commission_state, l.parts, l.invoice_id
  from public.remittance_line l where l.run_id = r.id
  union all
  select 1, 0, l.line_no, (select x.number from public.remittance_run x where x.id = l.run_id), l.kind,
         l.ledger_entry_id, l.account_id, l.portfolio_id, l.mandate_id, l.payment_id, l.encaissement_date,
         l.effective_date, l.deadline, 0, rp.commission_minor, rp.commission_state, rp.parts, rp.invoice_id
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
         coalesce(pt.basis, 0) as basis, inv.number as invoice, rc.number as receipt,
         la.ledger_entry_id is not null as late, la.late_reason
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
  left join lateral (select q.number from public.receipt q where q.payment_id = x.payment_id
                     order by q.version limit 1) rc on true
  left join lateral (select q.ledger_entry_id, q.late_reason from public.remittance_late_approval q
                     where q.run_id = r.id and q.ledger_entry_id = x.ledger_entry_id and x.section = 0
                     offset 0) la on true;

  select coalesce(jsonb_agg(jsonb_build_array(
           f.source_line_no, f.mandate, f.portfolio, f.file, f.debtor, f.items, f.components, f.kind, f.nature_reason,
           f.from_run, f.encaissement_date, f.effective_date, f.deadline, f.amount_minor::text, f.rules, f.rates,
           f.basis::text, f.commission_minor::text, f.commission_state, f.invoice, f.receipt, f.late, f.late_reason)
           order by f.section, f.from_run, f.source_line_no), '[]')
  into v_lines from pg_temp._rd_fact f;

  -- per file (the PDF's table): the run's lines and the commission priced on the file in this run
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
  -- with the invoices it corrects and what this payout sets off
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
           'settles_minor', (select coalesce(sum((s ->> 'amount')::bigint), 0)::text
                             from jsonb_array_elements(coalesce(r.settlement_plan -> 'settles', '[]')) s
                             where s ->> 'document_id' = i.id::text))
           order by i.seq), '[]')
  into v_docs
  from public.commission_invoice i where i.run_id = r.id;

  -- what this payout sets off from documents of earlier runs (compensation, a refund owed, an advance)
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', s ->> 'kind', 'document_kind', i.kind, 'number', i.number, 'issue_date', i.issue_date,
           'amount_minor', s ->> 'amount') order by i.seq nulls last, s ->> 'document_id'), '[]')
  into v_earlier
  from jsonb_array_elements(coalesce(r.settlement_plan -> 'settles', '[]')) s
  left join lateral (select q.kind, q.number, q.issue_date, q.seq, q.run_id from public.commission_invoice q
                     where q.id::text = s ->> 'document_id' offset 0) i on true
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

  -- money received on the client's files and not remitted (C. civ. 1993, OQ-40): what still waits on 4710 per file
  -- and reason, and what was refunded to payers since the previous statement; no payer data
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', h.file, 'reason', h.reason, 'currency', h.currency, 'amount_minor', h.amount::text,
           'first_date', h.first_date, 'last_date', h.last_date, 'count', h.n::text)
           order by h.file, h.reason, h.currency), '[]')
  into v_held
  from (select a.external_ref as file, coalesce(p.review_reason, 'pending') as reason, p.currency,
               sum(u.unallocated) as amount, min(p.booking_date) as first_date, max(p.booking_date) as last_date,
               count(*) as n
        from public.payment p
        cross join lateral (
          select (p.amount_minor - coalesce(sum(lp.amount_minor), 0))::bigint as unallocated
          from (select e.id from public.ledger_entry e
                where e.payment_id = p.id and e.entry_type <> 'cash_in' offset 0) e
          cross join lateral (select y.amount_minor from public.ledger_posting y
                              where y.entry_id = e.id
                                and (select la.book from public.ledger_account la where la.id = y.ledger_account_id)
                                    = 'unallocated_payment'
                              offset 0) lp) u
        cross join lateral (select q.external_ref from public.account q where q.id = p.account_id offset 0) a
        where p.organization_id = r.organization_id and p.status in ('matched', 'partially_allocated')
          and p.client_organization_id = r.client_organization_id and u.unallocated > 0
        group by a.external_ref, coalesce(p.review_reason, 'pending'), p.currency) h;

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
        where q.organization_id = r.organization_id and q.status in ('executed', 'bounced')
          and p.client_organization_id = r.client_organization_id
          and e.posted_at <= r.known_at and (v_prev.known_at is null or e.posted_at > v_prev.known_at)
        group by a.external_ref, q.reason_code, q.currency) h;

  -- the position (§10.7): owed to the client at K — every item pending then is this run's (one live run per client
  -- and currency, I14) — and after this payout; what the client owes the servicer (4111 + 4112) as known at K and
  -- after this statement's documents and the settlement at the payout's debit
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
  from public.commission_invoice i where i.run_id = r.id and i.reason <> 'run_cancelled';
  v_position := jsonb_build_object(
    'owed_before_minor', r.gross_minor::text,
    'owed_after_minor', '0',
    'receivable_before_minor', v_receivable::text,
    'receivable_after_minor', (v_receivable + v_docs_ttc - coalesce((r.settlement_plan ->> 'dc')::bigint, 0))::text,
    'advances_before_minor', v_advances::text,
    'advances_after_minor', (v_advances - coalesce((r.settlement_plan ->> 'da')::bigint, 0))::text);

  v_payload := jsonb_build_object(
    'schema', 1,
    'number', r.number,
    'issue_date', v_issue,
    'known_at', to_char(r.known_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'currency', r.currency,
    'exponent', v_exp,
    'status', r.status,
    'cancelled_on', case when r.status = 'cancelled' then (r.cancelled_at at time zone 'Europe/Paris')::date end,
    'issuer', private.invoice_party(r.organization_id),
    'client', private.invoice_party(r.client_organization_id),
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
-- (oldest first), each with its key in the private bucket.
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
        order by t.created_at, t.ref_id limit greatest(p_statements, 0)) t
  cross join lateral (select x.id, x.number, x.organization_id, x.client_organization_id from public.remittance_run x
                      where x.id = t.ref_id offset 0) r
  union all
  select 'invoice'::text, i.id, i.number,
         private.commission_invoice_path(i.organization_id, i.client_organization_id, i.year, i.number), null::text
  from (select t.ref_id from private.remittance_document_todo t
        where t.organization_id = p_organization_id and t.kind = 'invoice'
        order by t.created_at, t.ref_id limit greatest(p_invoices, 0)) t
  cross join lateral (select x.id, x.number, x.organization_id, x.client_organization_id, x.year
                      from public.commission_invoice x where x.id = t.ref_id offset 0) i;
end;
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
-- in this transaction, the invoice document rows; the work done leaves the queue. Every prepared statement was
-- rendered, nothing else. Returns {statements, invoices, more}.
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
                                           issue_date, known_at, line_count, file_count, payload, payload_sha256,
                                           template_version, renderer_version, pdf_document_id, pdf_sha256,
                                           csv_document_id, csv_sha256)
  select n.run_id, n.organization_id, n.client_organization_id, n.currency, n.number, n.issue_date, n.known_at,
         n.line_count, n.file_count, n.payload, n.payload_sha256, p_statement_template, p_renderer_version, n.pdf_id,
         n.pdf_sha256, n.csv_id, n.csv_sha256
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
  return jsonb_build_object('statements', v_s, 'invoices', v_i,
                            'more', exists (select 1 from private.remittance_document_todo t
                                            where t.organization_id = p_organization_id));
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

-- Documents due for longer than the given age (§15 `document_missing`), oldest first.
create or replace function private.remittance_documents_missing(p_organization_id uuid, p_older_than interval)
returns table (kind text, ref_id uuid, number text, due_since timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select t.kind, t.ref_id,
         coalesce((select i.number from public.commission_invoice i where i.id = t.ref_id),
                  (select r.number from public.remittance_run r where r.id = t.ref_id)),
         t.created_at
  from private.remittance_document_todo t
  where t.organization_id = p_organization_id and t.created_at < clock_timestamp() - p_older_than
  order by t.created_at, t.ref_id;
$$;

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
  -- owed today per currency: the client's running 4670 balance (a credit is owed to the client), all dates
  select coalesce(jsonb_agg(jsonb_build_object('currency', b.currency, 'owed_minor', (-b.balance_minor)::text)
                            order by b.currency), '[]')
  into v_owed from private.client_payable_balance b
  where b.client_organization_id = c.id and b.balance_minor <> 0;
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
------------------------------------------------------------------------------------------

create or replace function public.accounting_export_documents(p_from date, p_to date)
returns table (number text, kind text, issue_date date, client_name text, client_siren text, mandate text,
               run_number text, service_from date, service_to date, ht_minor bigint, vat_rate numeric,
               vat_minor bigint, ttc_minor bigint, vat_book text, settlement text, due_date date, corrects text,
               settled_minor bigint, settlements text, open_minor bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid := (private.money_staff_org_ids())[1];
begin
  if v_org is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'accounting export refused: period' using errcode = '22023';
  end if;
  return query
  select i.number, i.kind, i.issue_date, cl.legal_name, cl.siren, m.reference, r.number, i.service_from, i.service_to,
         i.ht_minor, i.vat_rate, i.vat_minor, i.ttc_minor, i.vat_book, i.settlement, i.due_date,
         (select string_agg(o.number, ' ' order by o.seq) from public.commission_credit_correction cc
          cross join lateral (select q.number, q.seq from public.commission_invoice q
                              where q.id = cc.original_invoice_id offset 0) o
          where cc.credit_note_id = i.id),
         coalesce(s.amount, 0)::bigint, s.detail,
         case when i.kind = 'invoice' then (i.ttc_minor - coalesce(s.amount, 0))::bigint end
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
    where x.document_id = i.id and x.document_kind = 'invoice') s on true
  where i.organization_id = v_org and i.issue_date between p_from and p_to
  order by i.year, i.seq;
end;
$$;

create or replace function public.accounting_export_entries(p_from date, p_to date)
returns table (effective_date date, entry_id uuid, entry_type text, source_type text, source_ref text,
               client_name text, account_number text, book text, debit_minor bigint, credit_minor bigint,
               currency char(3), posted_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid := (private.money_staff_org_ids())[1];
begin
  if v_org is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'accounting export refused: period' using errcode = '22023';
  end if;
  return query
  select p.effective_date, e.id, e.entry_type, e.source_type,
         coalesce((select i.number from public.commission_invoice i
                   where e.source_type = 'commission_invoice' and i.id::text = e.source_id),
                  (select x.number from public.remittance_run x
                   where e.source_type = 'remittance_run' and x.id::text = e.source_id),
                  e.source_id),
         (select o.legal_name from public.organization o where o.id = la.client_organization_id),
         b.account_number, la.book,
         case when p.amount_minor > 0 then p.amount_minor else 0 end::bigint,
         case when p.amount_minor < 0 then -p.amount_minor else 0 end::bigint,
         p.currency, e.posted_at
  from public.ledger_account la
  cross join lateral (select q.account_number from public.ledger_book q where q.code = la.book offset 0) b
  cross join lateral (select q.* from public.ledger_posting q
                      where q.ledger_account_id = la.id and q.effective_date between p_from and p_to offset 0) p
  cross join lateral (select q.* from public.ledger_entry q where q.id = p.entry_id offset 0) e
  where la.organization_id = v_org
    and la.book in ('servicer_revenue', 'vat_collected', 'vat_pending', 'bank_fees', 'servicer_losses',
                    'commission_receivable', 'client_advance_receivable', 'own_cash')
  order by p.effective_date, e.posted_at, e.id, p.line_no;
end;
$$;

------------------------------------------------------------------------------------------
-- Functions: the reads are the API's; the job's the worker's (service role); the rest internal
------------------------------------------------------------------------------------------

revoke execute on function private.queue_invoice_documents(), private.queue_statement(),
  private.remittance_statement_line_columns(), private.iban_masked(text), private.remittance_statement_build(uuid),
  private.remittance_documents_begin(uuid, integer, integer), private.remittance_statement_path(uuid, uuid, text),
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
  private.remittance_statement_prepare(uuid), private.remittance_statement_build(uuid),
  private.commission_invoice_render_rows(uuid[]), private.remittance_documents_record(uuid, text, text, text),
  private.remittance_document_orphans(uuid, interval, integer), private.remittance_documents_missing(uuid, interval),
  private.next_scheduled_run_day(uuid, date)
  to service_role;
revoke execute on function public.client_remittance_summary(uuid), public.accounting_export_documents(date, date),
  public.accounting_export_entries(date, date) from public, anon;
grant execute on function public.client_remittance_summary(uuid), public.accounting_export_documents(date, date),
  public.accounting_export_entries(date, date) to authenticated;
