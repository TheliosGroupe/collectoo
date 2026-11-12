-- M2c-6b-1 « bookings core » (plan docs/design/m2c-6b-plan.md §1.2 row 6b-1, §2.1–§2.5, §4.3; design §5, §7, §12,
-- §13, §15; ADR-0014 « M2c-6b-1 »). The debits of our transfers booked from the imported statements, as the debit job
-- books them (its funds pass emulated: the rows its pure rules decide, pg_temp._bank_booking, then
-- private.apply_bank_bookings, which re-checks every row under its locks):
--   * individual debits (RMT, SWP): the remittance, the run's settlement at the debit date, the sweep; the transfers and
--     runs booked; an idempotent second pass; PmtInf grouping by kind;
--   * batch lines (no end-to-end id, our PmtInfId) of kinds batch_unsplit and transfer_out, booked as one booking per
--     member (seq 1..n); a sweep's batch line to our own IBAN booked, never own_transfer_out; a single-refund batch line
--     linked by the M2b pass (I20 clean with executed and bounced file-mode refunds);
--   * returns of our payouts: the remittance reversed at the return date, a payout_returned item, the payout account
--     returned (only while active), the settlement kept; a return with the bank's charges (a fee on the same line,
--     signed completeness); I20's two indexes (a return booking after its debit booking; a second debit booking 23505);
--   * never booked: a second debit, a debit of a transfer never handed out (ordered, or in a file never downloaded), a
--     debit of a cancelled transfer (e2e and batch line), a foreign or predecessor PmtInf or an old id for a re-issue
--     (switch on in its own subtransaction); `explained` refused on our lines; a fee refused on our batch line;
--   * the booking-time cover (payout_overrun advance, no LG008; without it LG008); a chunk where one line's posting
--     fails and a batch line is booked (posting_failed, per line);
--   * R124-6 breach rows: none in flight before the statements cover the latest execution date, then one; at the
--     booking for a late debit, none for an on-time one;
--   * the set-based settlements against post_run_settlement (parity), client_advance RLS and its guards, the new
--     alerts, I9/I19/I20/I13/I14 clean after each step.
-- Review round 1: our transfers' lines refuse every link (`own_transfer_line`; a refund whose transfer is in a handed-out
-- file reaches its own trigger); a returned payout paid again records its breach `payout_returned` at the approval, the
-- booking and in flight; no breach row while a line could still be the payout's debit; the payments the breach rows name
-- key-share locked before the allocation lock; each nightly check fires on its fault (I20's rules, bank_line_booked,
-- bank_line_unbooked, servicer_funds_unswept, top_up_pending); each last-line rule of the re-check fed a row only it
-- refuses (a return before its debit reviewed `return_before_debit`); a debit dated before the job's day (and on the
-- previous month's last day) dates everything at the debit; I20's refund rule keyed; the client's returned runs.
-- Review round 2: a returned payout paid again late is « hors délai » on the statement for its own cause
-- (payout_returned); the client's returned run names the run that paid it again once booked (repaid_by); « Perte » refused
-- on every shape of our lines; « Débits et retours » offers on our lines only what the database accepts, and nothing on a
-- PmtInf with a member cancelled and not returned (the refund exception's switch-on hole, switch on in a rolled-back
-- subtransaction); I20's sub-clauses each seeded alone; each remaining last-line rule of the re-check fed a row only it
-- refuses (the batch rule's « not handed out » and « all booked » arms are shadowed by the row rule: no row reaches them).
-- Cancellation after download stays off (033 and 034 unchanged); some scenarios switch it on in their own subtransaction.
begin;
select plan(119);


-- Fixtures (as 034: the servicer aa, its dedicated account cf and own account c0; Martin a1, Lilas a2, Cyprès a3;
-- and Lambert a4, Roux a5, Dupont a6, Durand a7, Petit a8, Moreau a9, all with French payout IBANs) ---------------------
insert into public.organization (id, kind, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo SAS', '732829320'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Autre cabinet SAS', null);
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren)
select ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, 'creditor_client', '00000000-0000-0000-0000-0000000000aa',
       x.name, '552100554'
from (values ('a1', 'Martin SAS'), ('a2', 'Lilas Finance'), ('a3', 'Cyprès SA'), ('a4', 'Lambert SA'),
             ('a5', 'Roux SA'), ('a6', 'Dupont SA'), ('a7', 'Durand SARL'), ('a8', 'Petit SAS'),
             ('a9', 'Moreau SA')) x (c, name);
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@book.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '07', '08', '10', '13']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a8', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a8', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000a2', 'client_admin'),
  ('10000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-0000000000aa', 'ops_manager');
insert into public.portfolio (id, organization_id, client_organization_id, name)
select ('20000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'P' || c
from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c;
-- the restricted viewer of Petit (a portfolio access row: not the whole client)
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-0000000000a8');
insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000cf', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
   'FR3430001007940000000001001', 'TESTFRPPXXX', 'EUR', 'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000c0', '00000000-0000-0000-0000-0000000000aa', 'own',
   'FR7610107001011234567890129', null, 'EUR', 'Compte propre', null, '2026-01-01');
insert into public.servicer_billing_settings (organization_id, own_bank_account_id)
values ('00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000c0');
insert into public.billing_identity (organization_id, legal_form, share_capital_minor, rcs_city, registered_office,
                                     vat_number, is_professional)
select o.id, case when o.kind = 'servicer' then 'SAS' end, case when o.kind = 'servicer' then 1000000 end,
       case when o.kind = 'servicer' then 'Paris' end,
       '{"line1": "1 rue de la Paix", "postcode": "75002", "city": "Paris", "country": "FR"}',
       case when o.kind = 'servicer'
            then 'FR' || lpad(((12 + 3 * (o.siren::bigint % 97)) % 97)::text, 2, '0') || o.siren end, true
from public.organization o
where o.id = '00000000-0000-0000-0000-0000000000aa' or o.servicer_organization_id = '00000000-0000-0000-0000-0000000000aa';
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-000000000' || x.n || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || x.c || '.pdf',
       repeat('a', 64), 'application/pdf'
from (select c, n, case n when '1' then 'mandate_document' else 'payout_rib' end as kind
      from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c
      cross join unnest(array['1', '2']) n) x;
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on,
                            insurance_clause_ref)
select ('70000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'MAND-' || c, 'mandate_amicable', '2026-01-01', 'art. 9'
from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c;
insert into public.mandate_terms (id, mandate_id, valid_from, commission_schedule, commission_clause_ref, remittance_terms,
                                  remittance_clause_ref, document_id)
select ('71000000-0000-0000-0000-0000000000' || c)::uuid, ('70000000-0000-0000-0000-0000000000' || c)::uuid,
       '2026-01-01',
       '{"schema": "commission-1", "basis": {"families": "all", "forwards": {"file_recalled": false,
         "before_servicing_start": false, "client_ratification": false}, "on_reversal": "credit"},
         "rules": [{"id": "tout", "tier_key": "tout", "label_fr": "Toutes créances", "match": {},
                    "rate": {"kind": "flat", "rate": "0.15"}}]}',
       'art. 6', '{"schema": "remittance-1", "frequency": "twice_monthly", "netting": {"clause_ref": "art. 7.2"},
                   "clawback": null, "invoice_payment_days": 30}', 'art. 7',
       ('d0000000-0000-0000-0000-0000000001' || c)::uuid
from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c;
update public.portfolio set mandate_id = ('70000000-0000-0000-0000-0000000000' || right(id::text, 2))::uuid
where organization_id = '00000000-0000-0000-0000-0000000000aa';
insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                          evidence_document_id, proposed_by)
select ('90000000-0000-0000-0000-0000000000' || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, 'EUR', x.iban, x.holder,
       ('d0000000-0000-0000-0000-0000000002' || x.c)::uuid, '10000000-0000-0000-0000-000000000004'
from (values ('a1', 'FR7630004000031234567890143', 'MARTIN SAS'),
             ('a2', 'FR1420041010050500013M02606', 'LILAS FINANCE'),
             ('a3', 'FR7630006000011234567890189', 'CYPRES SA'),
             ('a4', 'FR7688685684899121950048661', 'LAMBERT SA'),
             ('a5', 'FR7674816825839554342314455', 'ROUX SA'),
             ('a6', 'FR7627523466751211650709822', 'DUPONT SA'),
             ('a7', 'FR7640105632892063255029835', 'DURAND SARL'),
             ('a8', 'FR7662603642123444042514350', 'PETIT SAS'),
             ('a9', 'FR7692640312371024797365028', 'MOREAU SA')) x (c, iban, holder);
update public.client_payout_account set status = 'active', confirmed_at = now(), confirmed_via = 'second_admin',
  confirmed_by = '10000000-0000-0000-0000-000000000001'
where organization_id = '00000000-0000-0000-0000-0000000000aa';

create or replace function pg_temp.f(p_n text) returns uuid language sql as $$
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.it(p_n text) returns uuid language sql as $$
  select ('c1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.pay(p_n text) returns uuid language sql as $$
  select ('f1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.file(p_n text, p_portfolio uuid, p_amount bigint) returns void language plpgsql as $$
begin
  insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                              legal_regime, currency, status)
  select pg_temp.f(p_n), p.organization_id, p.client_organization_id, p.id, 'b2b_invoice', 'D-' || p_n,
         'commercial_b2b', 'EUR', 'in_collection'
  from public.portfolio p where p.id = p_portfolio;
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type,
                                             valid_from)
  select pg_temp.f(p_n), p.client_organization_id, p.organization_id, 'mandate_amicable', '2026-09-30'
  from public.portfolio p where p.id = p_portfolio;
  insert into public.claim_item (id, account_id, kind, ref, due_date, original_minor)
  values (pg_temp.it(p_n), pg_temp.f(p_n), 'invoice', 'F-' || p_n, '2026-09-01', p_amount);
  perform private.ledger_post('00000000-0000-0000-0000-0000000000aa', 'adjustment', '2026-09-30', 'tf-owe-' || p_n,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', pg_temp.it(p_n), 'component', 'principal'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', 'principal')),
    jsonb_build_object('account_id', pg_temp.f(p_n), 'reason', 'ouverture (test)'));
end $$;
-- A payment on the dedicated account (its line, the payment, its cash_in); matched to the file and allocated unless
-- p_allocate is false (an unidentified payment ops may refund).
create or replace function pg_temp.collect(p_n text, p_amount bigint, p_day date, p_allocate boolean default true)
returns void language plpgsql as $$
declare s uuid := ('e1000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 'r.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, counterparty_iban,
                                       counterparty_name)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, 1, 't:' || s, 'credit',
          p_amount, 'EUR', p_day, 'debtor_credit', 'E2E-' || p_n, 'FR7630004000031234567890143', 'PAYEUR ' || p_n);
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, payer_name, payer_iban, end_to_end_id)
  values (pg_temp.pay(p_n), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s,
          'camt053', 'sct', p_amount, 'EUR', p_day, 'PAYEUR ' || p_n, 'FR7630004000031234567890143', 'E2E-' || p_n);
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_in', p_day, 'cash_in:' || s || ':' || p_day,
          'bank_statement', s::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cf'),
    (1, 2, 'unallocated_payment', -p_amount, 'EUR', null);
  perform private.ledger_post_set();
  if not p_allocate then
    return;
  end if;
  update public.payment set account_id = pg_temp.f(p_n), status = 'matched', match_method = 'rf_structured',
                            matched_at = now()
  where id = pg_temp.pay(p_n);
  perform private.allocation_begin();
  insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy, inputs_hash)
  values (pg_temp.pay(p_n), 1, pg_temp.f(p_n), 'allocate', p_day,
          '{"accessory_rank": "before_principal", "unclassified": "last"}', repeat('0', 64));
  insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
  values (pg_temp.pay(p_n), 1, pg_temp.it(p_n), 'principal', p_amount);
  perform private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1');
end $$;
-- An imported statement of the dedicated account (p_from, default p_to, to p_to, closing p_closing) with debit lines
-- [{e2e, amount, kind, pmt_inf}] booked on p_to, uploaded at p_uploaded_at (default now), camt.053 unless p_format,
-- created by the bank at p_created_at (default: its upload; its sections as given by p_sections).
create or replace function pg_temp.statement(p_n text, p_to date, p_closing bigint, p_debits jsonb default '[]',
                                             p_from date default null, p_uploaded_at timestamptz default null,
                                             p_format text default 'camt053', p_created_at timestamptz default null,
                                             p_sections jsonb default null, p_opening bigint default 0)
returns uuid language plpgsql as $$
declare s uuid := ('e2000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', p_format, 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = coalesce(p_uploaded_at, now()) where id = s;
  insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       original_end_to_end_id)
  select '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, d.ord, 't:' || s || d.ord,
         coalesce(d.v ->> 'dir', 'debit'), (d.v ->> 'amount')::bigint, 'EUR', p_to,
         coalesce(d.v ->> 'kind', 'transfer_out'), d.v ->> 'e2e', d.v ->> 'pmt_inf', d.v ->> 'orig_e2e'
  from jsonb_array_elements(p_debits) with ordinality d (v, ord);
  -- a camt.053's sections as the parser gives them (review round 4, G3): its period, the whole days it shows, its
  -- balances and the bank's creation time (Stmt/CreDtTm), by default its upload's; or as given (p_sections)
  update public.bank_statement set status = 'imported',
    from_date = coalesce((select min((v ->> 'from_date')::date) from jsonb_array_elements(p_sections) v), p_from, p_to),
    to_date = coalesce((select max((v ->> 'to_date')::date) from jsonb_array_elements(p_sections) v), p_to),
    opening_booked_minor = p_opening, closing_booked_minor = p_closing, counts = '{}', finished_at = clock_timestamp(),
    sections = case when p_format = 'camt053'
                    then coalesce(p_sections, jsonb_build_array(jsonb_build_object(
                           'from_date', coalesce(p_from, p_to), 'to_date', p_to,
                           'covers_from', coalesce(p_from, p_to), 'covers_to', p_to,
                           'opening_minor', p_opening::text, 'closing_minor', p_closing::text,
                           'created_at', coalesce(p_created_at, p_uploaded_at, now())))) end
  where id = s;
  return s;
end $$;
-- What the prepare job writes (emulated, as 027).
create or replace function pg_temp.prepare(p_run uuid, p_docs jsonb, p_keys jsonb, p_plan jsonb) returns integer
language plpgsql as $$
declare r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         pf.mandate_id, ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid, e.payment_id,
         e.effective_date, e.effective_date, q.posted_at, e.effective_date + 30, e.effective_date + 27, q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text),
         (select (k ->> 'commission')::bigint from jsonb_array_elements(p_keys) k
          where (k ->> 'account_id')::uuid = e.account_id), 'charged', '[]', true
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  join public.account a on a.id = e.account_id
  join public.portfolio pf on pf.id = a.portfolio_id
  where q.draft_run_id = p_run;
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', (select sum(amount_minor)::text from private.remittance_draft_line where run_id = p_run),
    'invoice_ht', p_plan ->> 'invoice_ht', 'invoice_vat', p_plan ->> 'invoice_vat', 'invoice_ttc', p_plan ->> 'invoice_ttc',
    'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0', 'taken', p_plan ->> 'dc', 'advances', '0', 'refunds', '0',
    'settlement', p_plan ->> 'settlement', 'net', p_plan ->> 'net', 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || p_plan::text, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', p_docs, 'key_states', p_keys, 'plan', p_plan));
  return (select version from public.remittance_run where id = p_run);
end $$;
create or replace function pg_temp.doc(p_c text, p_files jsonb, p_num bigint, p_den bigint) returns jsonb
language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'ref', 'new:70000000-0000-0000-0000-0000000000' || p_c, 'kind', 'invoice',
    'mandate_id', '70000000-0000-0000-0000-0000000000' || p_c, 'ht', ht::text, 'vat', (ht / 5)::text,
    'ttc', (ht + ht / 5)::text, 'vat_rate', '0.2', 'settlement', 'netted', 'clause_ref', 'art. 7.2',
    'lines', jsonb_build_array(jsonb_build_object('kind', 'commission', 'designation_fr', 'Commission (test)',
      'claim_type', 'b2b_invoice', 'rule_id', 'tout', 'families', '["principal"]'::jsonb,
      'tiers', '[]'::jsonb, 'ht', ht::text, 'vat_rate', '0.2')),
    'charges', (select jsonb_agg(jsonb_build_object('account_id', pg_temp.f(x.key), 'tier_key', 'tout',
                                                    'amount', ((x.value)::bigint * p_num / p_den)::text))
                from jsonb_each_text(p_files) x)))
  from (select sum((x.value)::bigint * p_num / p_den)::bigint as ht from jsonb_each_text(p_files) x) s;
$$;
create or replace function pg_temp.keys(p_c text, p_files jsonb, p_num bigint, p_den bigint) returns jsonb
language sql as $$
  select jsonb_agg(jsonb_build_object('account_id', pg_temp.f(x.key), 'tier_key', 'tout',
    'basis', jsonb_build_array(jsonb_build_array('71000000-0000-0000-0000-0000000000' || p_c, x.value)),
    'kept_basis', '0', 'kept', '0', 'commission', ((x.value)::bigint * p_num / p_den)::text))
  from jsonb_each_text(p_files) x;
$$;
create or replace function pg_temp.plan(p_c text, p_gross bigint, p_ht bigint, p_take bigint, p_vat_moved bigint)
returns jsonb language sql as $$
  select jsonb_build_object('settles', case when p_take > 0 then jsonb_build_array(jsonb_build_object(
           'ref', 'new:70000000-0000-0000-0000-0000000000' || p_c, 'kind', 'compensation',
           'mandate_id', '70000000-0000-0000-0000-0000000000' || p_c, 'amount', p_take::text,
           'vat_moved', p_vat_moved::text, 'open_before', (p_ht + p_ht / 5)::text)) else '[]'::jsonb end,
         'net', (p_gross - p_take)::text, 'settlement', p_take::text, 'dc', p_take::text,
         'da', '0', 'vat_moved', p_vat_moved::text, 'deferred', p_take = 0, 'invoice_ht', p_ht::text,
         'invoice_vat', (p_ht / 5)::text, 'invoice_ttc', (p_ht + p_ht / 5)::text);
$$;
create or replace function pg_temp.item(p_run uuid) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('run_id', r.id, 'inputs_hash', r.inputs_hash, 'net_text', r.net_minor::text))
  from public.remittance_run r where r.id = p_run;
$$;
create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
-- one run of a client: requested, prepared as given (its invoice set off by p_take), approved, its job run
create or replace function pg_temp.run(p_c text, p_files jsonb, p_take bigint, p_vat_moved bigint,
                                       p_num bigint default 15, p_den bigint default 100) returns uuid
language plpgsql as $$
declare v_run uuid; v_gross bigint; v_ht bigint;
begin
  select sum((x.value)::bigint), sum((x.value)::bigint * p_num / p_den) into v_gross, v_ht
  from jsonb_each_text(p_files) x;
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_run := (public.request_remittance_run('rq-tf-' || p_c, ('00000000-0000-0000-0000-0000000000' || p_c)::uuid)
            ->> 'run_id')::uuid;
  reset role;
  perform pg_temp.prepare(v_run, pg_temp.doc(p_c, p_files, p_num, p_den), pg_temp.keys(p_c, p_files, p_num, p_den),
                          pg_temp.plan(p_c, v_gross, v_ht, p_take, p_vat_moved));
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs('ap-tf-' || p_c, pg_temp.item(v_run));
  reset role;
  perform private.approve_remittance_run(v_run, (select job_token from public.remittance_run where id = v_run));
  return v_run;
end $$;
-- a command as user p_user (aal2 unless said)
create or replace function pg_temp.gen(p_user text, p_key text, p_late text default null, p_aal text default 'aal2',
                                       p_account uuid default '80000000-0000-0000-0000-0000000000cf')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.generate_transfer_file(p_key, p_account, p_late);
  reset role;
  return v;
end $$;
-- what the worker job does with a file (emulated: no bytes; their hash stands for them)
create or replace function pg_temp.write(p_file uuid) returns jsonb language plpgsql as $$
declare f public.transfer_file;
begin
  select * into f from public.transfer_file where id = p_file;
  return private.transfer_file_record(f.id, f.job_token, encode(sha256(convert_to(f.id::text, 'UTF8')), 'hex'), 1234,
                                      f.organization_id || '/' || f.id || '/' || f.number || '.xml', false, 'pain001-1',
                                      f.nb_of_txs, f.ctrl_sum_minor);
end $$;
create or replace function pg_temp.sha(p_file uuid) returns text language sql as $$
  select encode(sha256(convert_to(p_file::text, 'UTF8')), 'hex');
$$;
create or replace function pg_temp.download(p_user text, p_file uuid, p_ack boolean default false) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  v := public.transfer_file_download(p_file, pg_temp.sha(p_file), p_ack);
  reset role;
  return v;
end $$;
create or replace function pg_temp.tr(p_run uuid) returns public.bank_transfer language sql as $$
  select t.* from public.bank_transfer t where t.id = (select transfer_id from public.remittance_run where id = p_run);
$$;
create or replace function pg_temp.fl(p_file uuid) returns public.transfer_file language sql as $$
  select * from public.transfer_file where id = p_file;
$$;
grant execute on all functions in schema pg_temp to authenticated;
create temporary table t (k text primary key, v uuid) on commit drop;
grant all on t to authenticated;
create temporary table j (k text primary key, v jsonb) on commit drop;

-- The prepare (as 034's) with two knobs for the R124-6 cases: a line's latest execution date per file (`dated`), and the
-- header's earliest one per run (`earliest_hdr`; a header later than its lines lets a run be approved on time while a
-- line is already late at its debit — the booking-time breach, which no single test day reaches otherwise).
create temporary table dated (account_id uuid primary key, latest date not null) on commit drop;
create temporary table earliest_hdr (client text primary key, d date not null) on commit drop;
create or replace function pg_temp.prepare(p_run uuid, p_docs jsonb, p_keys jsonb, p_plan jsonb) returns integer
language plpgsql as $$
declare r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         pf.mandate_id, ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid, e.payment_id,
         e.effective_date, e.effective_date, q.posted_at, coalesce(d.latest + 3, e.effective_date + 30),
         coalesce(d.latest, e.effective_date + 27), q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text),
         (select (k ->> 'commission')::bigint from jsonb_array_elements(p_keys) k
          where (k ->> 'account_id')::uuid = e.account_id), 'charged', '[]', true
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  join public.account a on a.id = e.account_id
  join public.portfolio pf on pf.id = a.portfolio_id
  left join dated d on d.account_id = e.account_id
  where q.draft_run_id = p_run;
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', (select sum(amount_minor)::text from private.remittance_draft_line where run_id = p_run),
    'invoice_ht', p_plan ->> 'invoice_ht', 'invoice_vat', p_plan ->> 'invoice_vat', 'invoice_ttc', p_plan ->> 'invoice_ttc',
    'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0', 'taken', p_plan ->> 'dc', 'advances', '0', 'refunds', '0',
    'settlement', p_plan ->> 'settlement', 'net', p_plan ->> 'net', 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date',
      coalesce((select h.d from earliest_hdr h where h.client = right(r.client_organization_id::text, 2)),
               (select min(latest_execution_date) from private.remittance_draft_line where run_id = p_run)),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || p_plan::text, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', p_docs, 'key_states', p_keys, 'plan', p_plan));
  return (select version from public.remittance_run where id = p_run);
end $$;

create or replace function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
create or replace function pg_temp.trid(p_run text) returns uuid language sql as $$
  select transfer_id from public.remittance_run where id = pg_temp.v(p_run) $$;
create or replace function pg_temp.e2e(p_transfer uuid) returns text language sql as $$
  select end_to_end_id from public.bank_transfer where id = p_transfer $$;
create or replace function pg_temp.status(p_transfer uuid) returns text language sql as $$
  select status from public.bank_transfer where id = p_transfer $$;
create or replace function pg_temp.pmt(p_transfer uuid) returns text language sql as $$
  select i.pmt_inf_id from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
  where t.id = p_transfer and i.file_id = t.transfer_file_id $$;
create or replace function pg_temp.sweep(p_file uuid) returns public.bank_transfer language sql as $$
  select t.* from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
  where i.file_id = p_file and t.kind = 'sweep' $$;
-- a file generated by ops (user 01), written by the job, downloaded (its runs sent)
create or replace function pg_temp.handed_out(p_k text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := (pg_temp.gen('01', p_key) ->> 'file_id')::uuid;
  insert into t values (p_k, v);
  perform pg_temp.write(v);
  perform pg_temp.download('01', v);
  return v;
end $$;
-- the dedicated account's cash in the ledger (every line before booked, it is the bank's balance)
create or replace function pg_temp.cash() returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.book = 'client_money_cash' and la.bank_account_id = '80000000-0000-0000-0000-0000000000cf' $$;
-- line k of statement n
create or replace function pg_temp.ln(p_n text, p_k integer) returns uuid language sql as $$
  select ('e3' || lpad(p_n, 6, '0') || '-0000-0000-0000-' || lpad(p_k::text, 12, '0'))::uuid $$;
-- an imported camt.053 of the dedicated account for p_day (a whole day, produced now) with its lines
-- [{dir, kind, amount, e2e, orig, pmt, iban, code}]: opened with the ledger cash, closed with it moved by the lines
create or replace function pg_temp.stmt(p_n text, p_day date, p_lines jsonb default '[]') returns uuid
language plpgsql as $$
declare
  s uuid := ('e3000000-0000-0000-0000-0000000000' || p_n)::uuid;
  -- the bank's balance before this statement: the ledger's cash and the lines not booked yet
  v_open bigint := pg_temp.cash() + (select u.minor from private.bank_unposted('80000000-0000-0000-0000-0000000000cf',
                                                                               'infinity'::date) u);
  v_close bigint;
begin
  select v_open + coalesce(sum(case coalesce(l.v ->> 'dir', 'debit') when 'credit' then 1 else -1 end
                               * (l.v ->> 'amount')::bigint), 0)
  into v_close from jsonb_array_elements(p_lines) l (v);
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       original_end_to_end_id, counterparty_iban, bank_tx_code)
  select pg_temp.ln(p_n, l.ord::integer), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
         s, l.ord, 't:' || s || l.ord, coalesce(l.v ->> 'dir', 'debit'), (l.v ->> 'amount')::bigint, 'EUR', p_day,
         coalesce(l.v ->> 'kind', 'transfer_out'), l.v ->> 'e2e', l.v ->> 'pmt', l.v ->> 'orig', l.v ->> 'iban',
         l.v ->> 'code'
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  update public.bank_statement set status = 'imported', from_date = p_day, to_date = p_day,
    opening_booked_minor = v_open, closing_booked_minor = v_close, counts = '{}', finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object('from_date', p_day, 'to_date', p_day, 'covers_from', p_day,
                                                    'covers_to', p_day, 'opening_minor', v_open::text,
                                                    'closing_minor', v_close::text, 'created_at', now()))
  where id = s;
  return s;
end $$;
-- the debit job's funds pass, emulated: its pure rules' rows (line, kind, transfer) and reviews, then the SQL's
-- re-check under its locks and the posting (private.apply_bank_bookings)
create or replace function pg_temp.row(p_line uuid, p_kind text, p_transfer uuid default null) returns jsonb
language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('line', p_line, 'kind', p_kind, 'transfer', p_transfer)) $$;
create or replace function pg_temp.book(p_rows jsonb, p_reviews jsonb default '[]') returns jsonb language plpgsql as $$
begin
  perform private.bank_booking_begin();
  insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method)
  select r.ord, (r.v ->> 'line')::uuid, r.v ->> 'kind', (r.v ->> 'transfer')::uuid, 'auto'
  from jsonb_array_elements(p_rows) with ordinality r (v, ord);
  insert into pg_temp._booking_review (bank_transaction_id, reason, candidates)
  select (r.v ->> 'line')::uuid, r.v ->> 'reason', coalesce(r.v -> 'candidates', '[]')
  from jsonb_array_elements(p_reviews) r (v);
  return private.apply_bank_bookings('00000000-0000-0000-0000-0000000000aa');
end $$;
select private.bank_booking_begin();   -- (its working tables exist, for the helpers below)
create or replace function pg_temp.skipped(p_line uuid) returns text language sql as $$
  select why from pg_temp._booking_skipped where bank_transaction_id = p_line $$;
create or replace function pg_temp.review(p_line uuid) returns text language sql as $$
  select reason || coalesce(':' || detail, '') from public.bank_debit_review where bank_transaction_id = p_line $$;
create or replace function pg_temp.bookings(p_line uuid) returns text[] language sql as $$
  select coalesce(array_agg(b.seq || ' ' || b.kind || ' ' || b.amount_minor order by b.seq), '{}')
  from public.bank_line_booking b where b.bank_transaction_id = p_line $$;
create or replace function pg_temp.ek(p_key text) returns uuid language sql as $$
  select id from public.ledger_entry
  where organization_id = '00000000-0000-0000-0000-0000000000aa' and idempotency_key = p_key $$;
create or replace function pg_temp.books(p_entry uuid) returns jsonb language sql as $$
  select coalesce(jsonb_object_agg(x.book, x.s), '{}')
  from (select la.book, sum(p.amount_minor)::bigint as s from public.ledger_posting p
        join public.ledger_account la on la.id = p.ledger_account_id
        where p.entry_id = p_entry group by la.book) x $$;
create or replace function pg_temp.owed(p_c text) returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.book = 'client_payable' and la.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.share() returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.book = 'due_to_servicer' and la.organization_id = '00000000-0000-0000-0000-0000000000aa' $$;
-- the invariants this slice keeps, after a step: none of these violations (I8′, I12, the servicer's fund, I13, I14, I15,
-- I16, I18, I19 and its per-line twin, I20) nor the statement gap of I9
create or replace function pg_temp.dirty() returns text[] language plpgsql as $$
declare v uuid;
begin
  v := (private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'run_id')::uuid;
  return coalesce((select array_agg(distinct c.code order by c.code) from public.payment_check_result c
                   where c.run_id = v
                     and c.code in ('client_money_identity', 'own_fund_identity', 'fund_mirror', 'client_payable_debit',
                                    'remittance_completeness', 'bank_cash_identity', 'bank_line_booked',
                                    'transfer_booked_once', 'bank_balance_gap', 'remittance_item_twice',
                                    'remittance_run_totals', 'settlement_ledger', 'vat_pending_ledger')), '{}');
end $$;
-- the transfer checks' rows of a code (P0 alerts), as their subject and amount
create or replace function pg_temp.alerts(p_code text) returns jsonb language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_transfer_checks(v, '00000000-0000-0000-0000-0000000000aa', null);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return coalesce((select jsonb_agg(jsonb_build_array(c.subject_id, c.amount_minor) order by c.amount_minor, c.subject_id)
                   from public.payment_check_result c where c.run_id = v and c.code = p_code), '[]');
end $$;
-- a statement as user p_user at aal2: its single value as text, or the error's message
create or replace function pg_temp.try(p_user text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  begin
    execute p_sql into v;
  exception when others then
    reset role;
    return sqlerrm;
  end;
  reset role;
  return coalesce(v, 'null');
end $$;
create or replace function pg_temp.isolated(p_scenario text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  begin
    execute format('select pg_temp.%I()', p_scenario) into v;
    raise exception 'scenario % rolled back', p_scenario using errcode = 'TR001';
  exception when sqlstate 'TR001' then
    null;
  end;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- a run with its own idempotency keys (a client's second run)
create or replace function pg_temp.runk(p_c text, p_files jsonb, p_take bigint, p_vat_moved bigint, p_key text)
returns uuid language plpgsql as $$
declare v_run uuid; v_gross bigint; v_ht bigint;
begin
  select sum((x.value)::bigint), sum((x.value)::bigint * 15 / 100) into v_gross, v_ht from jsonb_each_text(p_files) x;
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_run := (public.request_remittance_run('rq-run-' || p_key, ('00000000-0000-0000-0000-0000000000' || p_c)::uuid)
            ->> 'run_id')::uuid;
  reset role;
  perform pg_temp.prepare(v_run, pg_temp.doc(p_c, p_files, 15, 100), pg_temp.keys(p_c, p_files, 15, 100),
                          pg_temp.plan(p_c, v_gross, v_ht, p_take, p_vat_moved));
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs('ap-run-' || p_key, pg_temp.item(v_run));
  reset role;
  perform private.approve_remittance_run(v_run, (select job_token from public.remittance_run where id = v_run));
  return v_run;
end $$;
-- Review round 1 (M2c-6b-1): the n-th business day after today (the checks' clocks, whatever day the suite runs)
create or replace function pg_temp.bd_after(p_n integer) returns date language sql as $$
  select c.day from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day > private.paris_today()
  order by c.day offset p_n - 1 limit 1 $$;
-- the transfer checks' codes as of p_today
create or replace function pg_temp.tcodes(p_today date) returns text[] language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa') returning id into v;
  perform private.run_transfer_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return coalesce((select array_agg(distinct c.code order by c.code) from public.payment_check_result c
                   where c.run_id = v), '{}');
end $$;
-- the payment checks' rows, as [code, subject]
create or replace function pg_temp.pchecks() returns jsonb language plpgsql as $$
declare v uuid;
begin
  v := (private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'run_id')::uuid;
  return coalesce((select jsonb_agg(distinct jsonb_build_array(c.code, c.subject_id)) from public.payment_check_result c
                   where c.run_id = v), '[]');
end $$;
-- « Lier » by ops (user 01), its refusal raised
create or replace function pg_temp.link(p_key text, p_line uuid, p_kind text, p_payment uuid, p_refund uuid,
                                        p_expected text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.link_debit(p_key, p_line, p_kind, p_payment, p_refund, p_expected, 'motif de test') ->> 'kind';
  reset role;
  return v;
end $$;
-- a statement in a subtransaction always rolled back: its value as text, or the error's message and hint
create or replace function pg_temp.attempt(p_sql text) returns text language plpgsql as $$
declare v text; h text;
begin
  begin
    execute p_sql into v;
    raise exception 'attempt rolled back' using errcode = 'TR002';
  exception when sqlstate 'TR002' then
    null;
  when others then
    get stacked diagnostics v = message_text, h = pg_exception_hint;
    v := v || coalesce(' | ' || nullif(h, ''), '');
  end;
  reset role;
  return coalesce(v, 'null');
end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- Collections (three days ago) and the first runs: Martin 200 000 → net 164 000; Lilas 512 000 → net 419 840;
-- Cyprès 12 000, all set off (N = 0: settled at approval, 120,00 € of the servicer now on 4679, swept in F1)
select pg_temp.file(x.n, ('20000000-0000-0000-0000-0000000000' || x.c)::uuid, x.amount)
from (values ('01', 'a1', 200000), ('02', 'a2', 512000), ('03', 'a3', 12000), ('04', 'a4', 40000),
             ('05', 'a5', 30000), ('06', 'a6', 100000), ('07', 'a7', 50000), ('08', 'a8', 100000),
             ('09', 'a9', 30000), ('11', 'a5', 10000), ('12', 'a2', 40000)) x (n, c, amount);
select pg_temp.collect(x.n, x.amount, private.paris_today() - 3)
from (values ('01', 200000), ('02', 512000), ('03', 12000), ('04', 40000), ('05', 30000), ('06', 100000),
             ('07', 50000), ('08', 100000), ('09', 30000), ('11', 10000)) x (n, amount);
select pg_temp.collect('10', 5000, private.paris_today() - 3, false);
-- an unidentified payment of 10 000,00 € (the account's cash, for the files of the scenarios below)
select pg_temp.collect('13', 1000000, private.paris_today() - 3, false);
insert into t select 'r1', pg_temp.run('a1', '{"01": "200000"}', 36000, 6000);
insert into t select 'r2', pg_temp.run('a2', '{"02": "512000"}', 92160, 15360);
insert into t select 'r3', pg_temp.run('a3', '{"03": "12000"}', 12000, 2000, 10, 12);
-- the account's statement of yesterday: what the bank holds (the cash check's closing balance)
select pg_temp.stmt('00', private.paris_today() - 1);


-- 1. Individual debits: the payouts' RMT ids and the sweep's SWP id, on yesterday's statement imported today (review T5:
-- everything dated at the debit, never at the job's day) ---------------------------------------------------------------
select pg_temp.handed_out('f1', 'gen-file-1');
select is(array[pg_temp.pmt(pg_temp.trid('r1')), pg_temp.pmt(pg_temp.trid('r2')),
                pg_temp.pmt((pg_temp.sweep(pg_temp.v('f1'))).id)],
          array[(pg_temp.fl(pg_temp.v('f1'))).number || '-1', (pg_temp.fl(pg_temp.v('f1'))).number || '-1',
                (pg_temp.fl(pg_temp.v('f1'))).number || '-2'],
  'one PmtInf per kind: the payouts in -1, the sweep in -2 (as M2c-6a numbered such a file)');
select is((pg_temp.sweep(pg_temp.v('f1'))).amount_minor, 12000::bigint, 'F1 sweeps Cyprès'' settled 120,00 €');
insert into t select 's1', (pg_temp.sweep(pg_temp.v('f1'))).id;
select pg_temp.stmt('01', private.paris_today() - 1, jsonb_build_array(
  jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.trid('r1'))),
  jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.trid('r2'))),
  jsonb_build_object('amount', 12000, 'e2e', pg_temp.e2e(pg_temp.v('s1')), 'iban', 'FR7610107001011234567890129')));
select results_eq(
  $$ select line_id, role, transfer_id, transfer_status, file_download_count > 0
     from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 100)
     where line_id in (pg_temp.ln('01', 1), pg_temp.ln('01', 2), pg_temp.ln('01', 3)) order by line_id $$,
  $$ values (pg_temp.ln('01', 1), 'own'::text, pg_temp.trid('r1'), 'in_file'::text, true),
            (pg_temp.ln('01', 2), 'own', pg_temp.trid('r2'), 'in_file', true),
            (pg_temp.ln('01', 3), 'own', pg_temp.v('s1'), 'in_file', true) $$,
  'the funds pass reads each debit with the transfer its own id names (its file handed out)');
insert into j select 'b1', pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('01', 1), 'payout', pg_temp.trid('r1')),
                                                          pg_temp.row(pg_temp.ln('01', 2), 'payout', pg_temp.trid('r2')),
                                                          pg_temp.row(pg_temp.ln('01', 3), 'sweep', pg_temp.v('s1'))));
select is((select array[v ->> 'payouts', v ->> 'sweeps', v ->> 'skipped', v ->> 'failed'] from j where k = 'b1'),
          array['2', '1', '0', '0'], 'two payouts and the sweep booked, nothing skipped or refused');
select is(pg_temp.bookings(pg_temp.ln('01', 1)) || pg_temp.bookings(pg_temp.ln('01', 2))
            || pg_temp.bookings(pg_temp.ln('01', 3)),
          array['1 payout 164000', '1 payout 419840', '1 sweep 12000'],
          'one booking per line, of its kind and amount');
select results_eq(
  $$ select entry_type, effective_date, source_type, source_id from public.ledger_entry
     where id in (pg_temp.ek('remit:' || pg_temp.trid('r1')), pg_temp.ek('settle:' || pg_temp.v('r1')),
                  pg_temp.ek('sweep:' || pg_temp.v('s1'))) order by entry_type $$,
  $$ values ('client_settlement'::text, private.paris_today() - 1, 'remittance_run'::text, pg_temp.v('r1')::text),
            ('remittance', private.paris_today() - 1, 'bank_transfer', pg_temp.trid('r1')::text),
            ('servicer_sweep', private.paris_today() - 1, 'bank_transfer', pg_temp.v('s1')::text) $$,
  'the remittance, the run''s settlement and the sweep, dated at the debit (yesterday, not the job''s day), each naming '
  'its document');
select is(pg_temp.books(pg_temp.ek('remit:' || pg_temp.trid('r1'))),
          '{"client_payable": 164000, "client_money_cash": -164000}'::jsonb, 'remittance: +4670[Martin] N / −5120 N');
select is(pg_temp.books(pg_temp.ek('settle:' || pg_temp.v('r1'))),
          '{"client_payable": 36000, "due_to_servicer": -36000, "due_from_client_funds": 36000,
            "commission_receivable": -36000, "vat_pending": 6000, "vat_collected": -6000}'::jsonb,
  'settlement at the debit: +4670 D / −4679 D ‖ +4689 D / −4111 D, its VAT due (+44574 / −44571)');
select is(pg_temp.books(pg_temp.ek('sweep:' || pg_temp.v('s1'))),
          '{"due_to_servicer": 12000, "client_money_cash": -12000, "own_cash": 12000, "due_from_client_funds": -12000}'::jsonb,
  'sweep: +4679 S / −5120 S ‖ +5122 S / −4689 S');
select results_eq(
  $$ select t.status, t.entry_id = coalesce(pg_temp.ek('remit:' || t.id), pg_temp.ek('sweep:' || t.id))
     from public.bank_transfer t where t.id in (pg_temp.trid('r1'), pg_temp.trid('r2'), pg_temp.v('s1'))
     order by t.amount_minor $$,
  $$ values ('booked'::text, true), ('booked', true), ('booked', true) $$,
  'the transfers booked, each with its entry');
select results_eq(
  $$ select status, booked_on from public.remittance_run where id in (pg_temp.v('r1'), pg_temp.v('r2')) order by number $$,
  $$ values ('booked'::text, private.paris_today() - 1), ('booked', private.paris_today() - 1) $$,
  'runs sent → booked at the debit date (yesterday)');
select results_eq(
  $$ select kind, amount_minor, vat_moved_minor, settled_on, entry_id = pg_temp.ek('settle:' || run_id)
     from public.commission_settlement where run_id = pg_temp.v('r1') $$,
  $$ values ('compensation'::text, 36000::bigint, 6000::bigint, private.paris_today() - 1, true) $$,
  'the invoice set off at the debit date (commission_settlement of the settlement entry)');
select is(array[pg_temp.owed('a1'), pg_temp.owed('a2'), pg_temp.share()], array[0, 0, -128160]::bigint[],
  'Martin and Lilas owed nothing; the servicer''s settled share (360,00 + 921,60 €) on the account, Cyprès'' swept');
select is((select count(*) from public.client_advance)::integer, 0, 'no cover needed: no advance');
select is(pg_temp.dirty(), '{}'::text[], 'I8′, I12, I13, I14, I19, I20 and I9 clean after the individual debits');
-- review T3: the servicer's settled share on the account, no sweep ordered or in a file: servicer_funds_unswept once it
-- has been so for more than two business days, not before
select is(array['servicer_funds_unswept' = any (pg_temp.tcodes(pg_temp.bd_after(3))),
                'servicer_funds_unswept' = any (pg_temp.tcodes(private.paris_today()))],
          array[true, false],
  'servicer_funds_unswept: 4679 in debit three business days on, no sweep ordered (an alert); not on the day');
insert into j select 'b1bis', pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('01', 1), 'payout', pg_temp.trid('r1')),
                                                             pg_temp.row(pg_temp.ln('01', 2), 'payout', pg_temp.trid('r2')),
                                                             pg_temp.row(pg_temp.ln('01', 3), 'sweep', pg_temp.v('s1'))));
select is(array[(select v ->> 'skipped' from j where k = 'b1bis'), pg_temp.skipped(pg_temp.ln('01', 1)),
                (select count(*)::text from public.bank_line_booking
                 where bank_transaction_id in (pg_temp.ln('01', 1), pg_temp.ln('01', 2), pg_temp.ln('01', 3)))],
          array['3', 'already_booked', '3'], 'the same rows again (a redelivered job): skipped, nothing booked twice');
select is(pg_temp.review(pg_temp.ln('01', 3)), null, 'the sweep''s line to the own IBAN booked, never own_transfer_out');


-- 2. Batch lines (the bank ignored BtchBookg false): payouts, a single refund, the sweep ------------------------------
insert into t select 'r6', pg_temp.run('a6', '{"06": "100000"}', 18000, 3000);
insert into t select 'r7', pg_temp.run('a7', '{"07": "50000"}', 0, 0);
create or replace function pg_temp.refund_q1() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.request_refund('refund-q1-0001', pg_temp.pay('10'), '5000', null, null, 'other', null, '5000', 'payeur inconnu');
  reset role;
  return v;
end $$;
insert into j select 'q1', pg_temp.refund_q1();
-- the set-based settlement posts what post_run_settlement posts, run by run (parity on D > 0 and D = 0)
create or replace function pg_temp.settle_one() returns jsonb language plpgsql as $$
declare e1 uuid; e2 uuid;
begin
  e1 := private.post_run_settlement(pg_temp.v('r6'), (select settlement_plan from public.remittance_run
                                                       where id = pg_temp.v('r6')), private.paris_today());
  e2 := private.post_run_settlement(pg_temp.v('r7'), (select settlement_plan from public.remittance_run
                                                       where id = pg_temp.v('r7')), private.paris_today());
  return jsonb_build_array(pg_temp.books(e1), e2,
    (select jsonb_agg(jsonb_build_array(document_kind, kind, amount_minor, vat_moved_minor, settled_on) order by id)
     from public.commission_settlement where run_id in (pg_temp.v('r6'), pg_temp.v('r7'))));
end $$;
create or replace function pg_temp.settle_set() returns jsonb language plpgsql as $$
declare e1 uuid; e2 uuid;
begin
  select entry_id into e1 from private.post_run_settlements(array[pg_temp.v('r6'), pg_temp.v('r7')],
                                                            array[private.paris_today(), private.paris_today()])
  where run_id = pg_temp.v('r6');
  return jsonb_build_array(pg_temp.books(e1), e2,
    (select jsonb_agg(jsonb_build_array(document_kind, kind, amount_minor, vat_moved_minor, settled_on) order by id)
     from public.commission_settlement where run_id in (pg_temp.v('r6'), pg_temp.v('r7'))));
end $$;
select is(pg_temp.isolated('settle_set'), pg_temp.isolated('settle_one'),
  'post_run_settlements (one call) = post_run_settlement run by run: the same entry and settlements (D > 0, D = 0)');
select pg_temp.handed_out('f2', 'gen-file-2');
select ok(not ('servicer_funds_unswept' = any (pg_temp.tcodes(pg_temp.bd_after(3)))),
  'no servicer_funds_unswept once the share''s sweep is in a file');
insert into t select 'q1t', (select transfer_id from public.refund_request where id = (select (v ->> 'refund_request_id')::uuid from j where k = 'q1'));
insert into t select 's2', (pg_temp.sweep(pg_temp.v('f2'))).id;
select is(array[pg_temp.pmt(pg_temp.trid('r6')), pg_temp.pmt(pg_temp.trid('r7')), pg_temp.pmt(pg_temp.v('q1t')),
                pg_temp.pmt(pg_temp.v('s2'))],
          array[(pg_temp.fl(pg_temp.v('f2'))).number || '-1', (pg_temp.fl(pg_temp.v('f2'))).number || '-1',
                (pg_temp.fl(pg_temp.v('f2'))).number || '-2', (pg_temp.fl(pg_temp.v('f2'))).number || '-3'],
  'one PmtInf per kind: payouts, then the refund, then the sweep — a batch line is one kind');
select is((pg_temp.sweep(pg_temp.v('f2'))).amount_minor, 128160::bigint, 'F2 sweeps the share settled at the debits');
select pg_temp.stmt('02', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 132000, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(pg_temp.trid('r6'))),
  jsonb_build_object('amount', 5000, 'kind', 'other_debit', 'pmt', pg_temp.pmt(pg_temp.v('q1t'))),
  jsonb_build_object('amount', 128160, 'pmt', pg_temp.pmt(pg_temp.v('s2')), 'iban', 'FR7610107001011234567890129')));
select results_eq(
  $$ select line_id, role, transfer_id from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa',
                                                                            null, null, 100)
     where line_id in (pg_temp.ln('02', 1), pg_temp.ln('02', 2), pg_temp.ln('02', 3)) order by line_id, transfer_id $$,
  $$ select * from (values (pg_temp.ln('02', 1), 'member'::text, least(pg_temp.trid('r6'), pg_temp.trid('r7'))),
                           (pg_temp.ln('02', 1), 'member', greatest(pg_temp.trid('r6'), pg_temp.trid('r7'))),
                           (pg_temp.ln('02', 3), 'member', pg_temp.v('s2'))) x $$,
  'a batch line reads every member of its PmtInf; the single-refund line is not the funds pass''s');
select results_eq(
  $$ select line_id, refund_request_id, via from private.debit_candidates('00000000-0000-0000-0000-0000000000aa',
                                                                           null, null, 100)
     where line_id = pg_temp.ln('02', 2) $$,
  $$ select pg_temp.ln('02', 2), (select (v ->> 'refund_request_id')::uuid from j where k = 'q1'),
            'payment_info_id'::text $$,
  'the M2b pass proposes the single-refund batch line with its refund (by its transfer)');
-- the M2b pass links it (as the job: its pure rules decide « refund »)
select private.debit_link_begin();
insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, refund_request_id, method)
select 1, pg_temp.ln('02', 2), 'refund', pg_temp.pay('10'), (v ->> 'refund_request_id')::uuid, 'auto' from j where k = 'q1';
select private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
select results_eq(
  $$ select q.status, t.status, t.entry_id = q.cash_out_entry_id from public.refund_request q
     join public.bank_transfer t on t.id = q.transfer_id where q.id = (select (v ->> 'refund_request_id')::uuid from j where k = 'q1') $$,
  $$ values ('executed'::text, 'booked'::text, true) $$,
  'the single-refund batch line executes its refund (M2b link), its transfer booked with the refund''s cash_out');
-- review T4 (the batch rule's last line): with the switch on (rolled back), Durand's payout cancelled alone out of F2,
-- a line of Dupont's amount on that PmtInf and a row for Dupont only — the live members add up, the cancelled one could
-- be in the line: never booked
create or replace function pg_temp.sc_batch_cancelled() returns jsonb language plpgsql as $$
begin
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = pg_temp.trid('r7');
  perform pg_temp.stmt('11', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 82000, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(pg_temp.trid('r6')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('11', 1), 'payout', pg_temp.trid('r6'))));
  return jsonb_build_object('why', pg_temp.skipped(pg_temp.ln('11', 1)), 'r6', pg_temp.status(pg_temp.trid('r6')),
                            'bookings', cardinality(pg_temp.bookings(pg_temp.ln('11', 1))));
end $$;
select is(pg_temp.isolated('sc_batch_cancelled'),
          '{"why": "cancelled_transfer_debited", "r6": "in_file", "bookings": 0}'::jsonb,
  'a batch line its live members add up to, with a cancelled member of the PmtInf: cancelled_transfer_debited, '
  'nothing booked');
insert into j select 'b2', pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('02', 1), 'payout', pg_temp.trid('r6')),
                                                          pg_temp.row(pg_temp.ln('02', 1), 'payout', pg_temp.trid('r7')),
                                                          pg_temp.row(pg_temp.ln('02', 3), 'sweep', pg_temp.v('s2'))));
select is(pg_temp.bookings(pg_temp.ln('02', 1)) || pg_temp.bookings(pg_temp.ln('02', 3)),
          array['1 payout 82000', '2 payout 50000', '1 sweep 128160'],
  'a batch line of two payouts booked as two bookings (seq 1, 2); the sweep''s batch line to the own IBAN booked');
select results_eq(
  $$ select r.status, t.status from public.remittance_run r join public.bank_transfer t on t.id = r.transfer_id
     where r.id in (pg_temp.v('r6'), pg_temp.v('r7')) order by r.number $$,
  $$ values ('booked'::text, 'booked'::text), ('booked', 'booked') $$, 'both runs and their transfers booked');
select is(pg_temp.ek('settle:' || pg_temp.v('r7')), null, 'D = 0 (the commission deferred): no settlement entry');
select is(pg_temp.dirty(), '{}'::text[], 'clean after the batch lines (I20 with an executed file-mode refund)');


-- 3. Returns: a payout back, a payout back less the bank's charges, the sweep back, a refund back -----------------------
-- Martin replaced his payout account after the debit (a second admin confirmed it): the old one is retired
create or replace function pg_temp.replace_martin() returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.as_user('04');
  set local role authenticated;
  v := (public.propose_payout_account('pa-a1-new', '00000000-0000-0000-0000-0000000000a1', 'EUR',
                                      'FR7630004000031234567890143', 'MARTIN SAS', null,
                                      'd0000000-0000-0000-0000-0000000002a1') ->> 'payout_account_id')::uuid;
  perform pg_temp.as_user('10');
  perform public.confirm_payout_account('pa-a1-new-ok', v, 'FR7630004000031234567890143');
  reset role;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into t select 'pa1', pg_temp.replace_martin();
select pg_temp.stmt('03', private.paris_today(), jsonb_build_array(
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.trid('r1'))),
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 81000, 'orig', pg_temp.e2e(pg_temp.trid('r6'))),
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 12000, 'orig', pg_temp.e2e(pg_temp.v('s1'))),
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 5000, 'orig', pg_temp.e2e(pg_temp.v('q1t')))));
select results_eq(
  $$ select line_id, role, transfer_id from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa',
                                                                            null, null, 100)
     where line_id in (pg_temp.ln('03', 1), pg_temp.ln('03', 2), pg_temp.ln('03', 3), pg_temp.ln('03', 4))
     order by line_id $$,
  $$ values (pg_temp.ln('03', 1), 'return'::text, pg_temp.trid('r1')), (pg_temp.ln('03', 2), 'return', pg_temp.trid('r6')),
            (pg_temp.ln('03', 3), 'return', pg_temp.v('s1')) $$,
  'the funds pass reads the returns of our payouts and sweep (the refund''s return stays the M2b pass''s)');
select is((select count(*)::integer from private.debit_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 100)
           where line_id in (pg_temp.ln('03', 1), pg_temp.ln('03', 2), pg_temp.ln('03', 3))), 0,
  'the M2b pass no longer reads a credit carrying our RMT/SWP id');
-- review money-1 (K1): a credit returning our payout is never linked as a refund that came back (only the funds pass
-- books it: its item, the account returned, the P0)
select is(pg_temp.attempt(format($q$ select pg_temp.link('rr-on-rmt-0001', %L, 'refund_returned', null, %L, null) $q$,
                                 pg_temp.ln('03', 1), (select (v ->> 'refund_request_id')::uuid from j where k = 'q1'))),
          'debit link refused: own_transfer_line | Cette ligne est un débit ou un retour de nos propres virements '
          '(reversement, quote-part du cabinet, lot de notre fichier) : elle se comptabilise depuis le relevé, '
          'automatiquement ou par l''équipe (écran à venir). Elle ne se rattache pas à un paiement et ne se classe pas '
          'sans comptabilisation.',
  '« Remboursement revenu » refused on the return of our RMT payout: own_transfer_line, with its hint');
-- review T4/K5: a return dated before its payout's debit (yesterday's) is left to ops as return_before_debit
create or replace function pg_temp.sc_early_return() returns jsonb language plpgsql as $$
begin
  perform pg_temp.stmt('12', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.trid('r1')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('12', 1), 'payout_returned', pg_temp.trid('r1'))));
  return jsonb_build_object('why', pg_temp.skipped(pg_temp.ln('12', 1)), 'review', pg_temp.review(pg_temp.ln('12', 1)),
                            'r1', pg_temp.status(pg_temp.trid('r1')));
end $$;
select is(pg_temp.isolated('sc_early_return'),
          '{"why": "return_before_debit", "review": "return_before_debit", "r1": "booked"}'::jsonb,
  'a return dated before its debit: refused under the locks and reviewed return_before_debit (not « changed »)');
insert into j select 'b3', pg_temp.book(jsonb_build_array(
  pg_temp.row(pg_temp.ln('03', 1), 'payout_returned', pg_temp.trid('r1')),
  pg_temp.row(pg_temp.ln('03', 2), 'payout_returned', pg_temp.trid('r6')),
  pg_temp.row(pg_temp.ln('03', 3), 'sweep_returned', pg_temp.v('s1'))));
select is(pg_temp.bookings(pg_temp.ln('03', 1)) || pg_temp.bookings(pg_temp.ln('03', 2))
            || pg_temp.bookings(pg_temp.ln('03', 3)),
          array['1 payout_returned 164000', '1 payout_returned 82000', '2 fee 1000', '1 sweep_returned 12000'],
  'returns booked; less the charges: the full reversal and a fee of the difference on the same line (seq 1, 2)');
select results_eq(
  $$ select e.entry_type, e.reverses_entry_id, e.effective_date from public.ledger_entry e
     where e.id = pg_temp.ek('return:' || pg_temp.ln('03', 1)) $$,
  $$ values ('reversal'::text, pg_temp.ek('remit:' || pg_temp.trid('r1')), private.paris_today()) $$,
  'the returned payout''s remittance reversed at the return date');
select is(pg_temp.books(pg_temp.ek('fee:' || pg_temp.ln('03', 2))),
          '{"due_to_servicer": 1000, "client_money_cash": -1000, "bank_fees": 1000, "due_from_client_funds": -1000}'::jsonb,
  'the bank''s charge on the return: a bank_fee (the servicer''s cost)');
select results_eq(
  $$ select t.status, t.return_entry_id = pg_temp.ek('return:' || l.line), r.status
     from (values (pg_temp.trid('r1'), pg_temp.ln('03', 1), pg_temp.v('r1')),
                  (pg_temp.trid('r6'), pg_temp.ln('03', 2), pg_temp.v('r6'))) l (transfer, line, run)
     join public.bank_transfer t on t.id = l.transfer join public.remittance_run r on r.id = l.run
     order by t.amount_minor $$,
  $$ values ('returned'::text, true, 'booked'::text), ('returned', true, 'booked') $$,
  'the transfers returned with their reversal; their runs stay booked (the settlement stays, §9.7)');
select results_eq(
  $$ select client_organization_id, kind, amount_minor from private.remittance_pending
     where kind = 'payout_returned' order by amount_minor $$,
  $$ values ('00000000-0000-0000-0000-0000000000a6'::uuid, 'payout_returned'::text, 82000::bigint),
            ('00000000-0000-0000-0000-0000000000a1', 'payout_returned', 164000) $$,
  'each returned payout is a payout_returned item for its client (the 4670 trigger)');
select results_eq(
  $$ select client_organization_id, status, id = pg_temp.v('pa1') from public.client_payout_account
     where client_organization_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a6')
     order by client_organization_id, status $$,
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid, 'active'::text, true),
            ('00000000-0000-0000-0000-0000000000a1', 'retired', false),
            ('00000000-0000-0000-0000-0000000000a6', 'returned', false) $$,
  'Dupont''s payout account returned (it blocks payouts until replaced or reconfirmed); Martin''s, replaced before '
  'the return, stays retired and his new one active (only an active account is marked; review T4)');
select ok('payout_account_returned' = any (private.remittance_payout_blockers('00000000-0000-0000-0000-0000000000a6', 'EUR',
                                                                               private.paris_today())),
  'Dupont''s next payout is blocked: payout_account_returned');
select is((select latest_execution_date from private.pending_item_deadlines('00000000-0000-0000-0000-0000000000aa')
           where client_organization_id = '00000000-0000-0000-0000-0000000000a1'),
          (select d.latest_execution_date
           from public.remittance_line l cross join lateral private.remittance_deadline_or_null(l.encaissement_date, 30) d
           where l.run_id = pg_temp.v('r1')),
  'the returned payout''s item is held to its run''s line: that collection''s E and its mandate''s delay (§9.2)');
select is(pg_temp.status(pg_temp.v('s1')), 'returned', 'the sweep returned');
-- the refund that came back: the M2b pass bounces it (its transfer returned)
select private.debit_link_begin();
insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, refund_request_id, method)
select 1, pg_temp.ln('03', 4), 'refund_returned', pg_temp.pay('10'), (v ->> 'refund_request_id')::uuid, 'auto' from j where k = 'q1';
select private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
select is(pg_temp.status(pg_temp.v('q1t')), 'returned', 'the bounced refund''s transfer returned (M2b link)');
select is(jsonb_array_length(pg_temp.alerts('payout_returned')), 2, 'payout_returned alerts while the items wait');
select is(pg_temp.alerts('sweep_returned'), jsonb_build_array(jsonb_build_array(pg_temp.v('s1'), 12000)),
  'sweep_returned while the share is not swept again');
select is(pg_temp.dirty(), '{}'::text[],
  'clean after the returns (I19 signed with the charges; I20 with a bounced file-mode refund)');
-- review legal-texts#6 (K4): the client space knows its payout came back (it cannot read the transfer: RLS)
insert into auth.users (id, email, aud, role)
values ('10000000-0000-0000-0000-000000000014', 'u14@book.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role)
values ('10000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-0000000000a1', 'client_admin');
select is(array[pg_temp.try('14', $q$ select (public.client_remittance_summary('00000000-0000-0000-0000-0000000000a1')
                                               -> 'returned_runs')::text $q$),
                pg_temp.try('08', $q$ select (public.client_remittance_summary('00000000-0000-0000-0000-0000000000a2')
                                               -> 'returned_runs')::text $q$),
                pg_temp.try('08', $q$ select (public.client_remittance_summary('00000000-0000-0000-0000-0000000000a1')
                                               -> 'returned_runs')::text $q$)],
          array[jsonb_build_array(jsonb_build_object('run_id', pg_temp.v('r1'), 'returned_on', private.paris_today(),
                                                     'amount_minor', '164000', 'repaid_by', null))::text,
                '[]', 'not allowed'],
  'client_remittance_summary: Martin''s admin reads his returned run (the return''s date, the amount); Lilas'' none; '
  'Lilas'' admin never Martin''s');
-- I20's two indexes: a second debit booking of a transfer is refused at once
select throws_ok(
  $$ insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                           entry_id, amount_minor, method)
     values (pg_temp.ln('03', 1), 9, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
             'payout', pg_temp.trid('r2'), pg_temp.ek('settle:' || pg_temp.v('r6')), 419840, 'auto') $$,
  '23505', null, 'a second debit booking of a transfer: 23505 (bank_line_booking_debit_uq)');


-- 4. Never booked automatically: a second debit, a transfer never handed out, a cancelled transfer --------------------
insert into t select 'r9', pg_temp.run('a9', '{"09": "30000"}', 5400, 900);
insert into t select 't9', pg_temp.trid('r9');
-- in a file generated, never downloaded: the bank cannot have its bytes
insert into t select 'f3', (pg_temp.gen('01', 'gen-file-3') ->> 'file_id')::uuid;
select pg_temp.write(pg_temp.v('f3'));
-- review T4 (the row rule): a debit carrying the RMT id of a payout whose file was never downloaded (rolled back)
create or replace function pg_temp.sc_not_handed_out() returns jsonb language plpgsql as $$
begin
  perform pg_temp.stmt('13', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 24600, 'e2e', pg_temp.e2e(pg_temp.v('t9')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('13', 1), 'payout', pg_temp.v('t9'))));
  return jsonb_build_object('why', pg_temp.skipped(pg_temp.ln('13', 1)), 't9', pg_temp.status(pg_temp.v('t9')));
end $$;
select is(pg_temp.isolated('sc_not_handed_out'), '{"why": "transfer_not_handed_out", "t9": "in_file"}'::jsonb,
  'an RMT debit of a payout in a file never downloaded: transfer_not_handed_out, never booked');
select pg_temp.stmt('04', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.trid('r2'))),
  jsonb_build_object('amount', 24600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(pg_temp.v('t9')))));
insert into j select 'b4', pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('04', 1), 'payout', pg_temp.trid('r2')),
                                                          pg_temp.row(pg_temp.ln('04', 2), 'payout', pg_temp.v('t9'))));
select is(array[pg_temp.skipped(pg_temp.ln('04', 1)), pg_temp.skipped(pg_temp.ln('04', 2))],
          array['transfer_debited_twice', 'transfer_not_handed_out'],
  'refused under the locks: a second debit of a booked payout; a batch line of a file never downloaded');
select is(pg_temp.review(pg_temp.ln('04', 2)), 'changed:transfer_not_handed_out',
  'a line the re-check refused is left to ops with its code');
-- the job's own reviews of them (its pure rules), and their P0 alerts
select pg_temp.book('[]', jsonb_build_array(
  jsonb_build_object('line', pg_temp.ln('04', 1), 'reason', 'transfer_debited_twice'),
  jsonb_build_object('line', pg_temp.ln('04', 2), 'reason', 'transfer_not_handed_out')));
select is(array[pg_temp.alerts('transfer_debited_twice'), pg_temp.alerts('transfer_not_handed_out')],
          array[jsonb_build_array(jsonb_build_array(pg_temp.ln('04', 1), 419840)),
                jsonb_build_array(jsonb_build_array(pg_temp.ln('04', 2), 24600))],
  'P0 alerts: transfer_debited_twice, transfer_not_handed_out');
-- cancelled before download (its file superseded): a later debit of its id is never booked
select is(pg_temp.try('04', format($q$ select public.cancel_remittance_run('cancel-r9-0001', %L, %s, 'à refaire') ->> 'status' $q$,
                                   pg_temp.v('r9'), (select version from public.remittance_run where id = pg_temp.v('r9')))),
          'cancelled', 'Moreau''s run cancelled before its file was downloaded (a line of a file never handed out is no debit)');
select pg_temp.stmt('05', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 24600, 'e2e', pg_temp.e2e(pg_temp.v('t9'))),
  jsonb_build_object('amount', 1000, 'kind', 'other_debit', 'pmt', pg_temp.pmt(pg_temp.trid('r2')),
                     'code', 'PMNT/CCRD/CHRG')));
select pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('05', 1), 'payout', pg_temp.v('t9'))));
select is(pg_temp.skipped(pg_temp.ln('05', 1)), 'cancelled_transfer_debited',
  'a debit of a cancelled transfer''s id is never booked');
select pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.ln('05', 1),
                                                               'reason', 'cancelled_transfer_debited')));
select ok(pg_temp.alerts('cancelled_transfer_debited') @> jsonb_build_array(jsonb_build_array(pg_temp.ln('05', 1), 24600)),
  'P0 cancelled_transfer_debited for that line');
-- never « explained » (plan §2.4 rule 5): our RMT line, our batch line
select is(array[pg_temp.try('01', format($q$ select public.link_debit('explain-0001', %L, 'explained', null, null, null, 'vu')
                                            ->> 'kind' $q$, pg_temp.ln('05', 1))),
                pg_temp.try('01', format($q$ select public.link_debit('explain-0002', %L, 'explained', null, null, null, 'vu')
                                            ->> 'kind' $q$, pg_temp.ln('04', 2)))],
          array['debit link refused: own_transfer_line', 'debit link refused: own_transfer_line'],
  '« explained » refused on a debit carrying our RMT id and on a batch line of our file');
-- review money-1 (K1): nor a payment's return, nor a refund (but a PmtInf's single refund), whatever the line's kind
create or replace function pg_temp.refusal(p_text text) returns text language sql as $$
  select split_part(p_text, ' | ', 1) $$;
create or replace function pg_temp.k1_manual_refund() returns text language plpgsql as $$
declare q uuid; v text;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  q := (public.request_refund('k1-manual-0001', pg_temp.pay('13'), '1000', 'FR7630004000031234567890143', 'PAYEUR 13',
                              'other', null, '1000000', 'payeur inconnu', 'manual') ->> 'refund_request_id')::uuid;
  v := public.link_debit('k1-manual-link', pg_temp.ln('05', 2), 'refund', null, q, null, 'remboursement') ->> 'kind';
  reset role;
  return v;
end $$;
create or replace function pg_temp.k1_other_debit_rmt() returns text language plpgsql as $$
begin
  perform pg_temp.stmt('14', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 1000, 'kind', 'other_debit', 'e2e', pg_temp.e2e(pg_temp.trid('r2')))));
  return pg_temp.link('k1-ret-rmt-od', pg_temp.ln('14', 1), 'return', pg_temp.pay('13'), null, '1000000');
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(array[pg_temp.refusal(pg_temp.attempt(format($q$ select pg_temp.link('k1-ret-batch', %L, 'return', %L, null,
                                                                                 '1000000') $q$,
                                                       pg_temp.ln('05', 2), pg_temp.pay('13')))),
                pg_temp.refusal(pg_temp.attempt('select pg_temp.k1_manual_refund()')),
                pg_temp.refusal(pg_temp.attempt(format($q$ select pg_temp.link('k1-ret-rmt', %L, 'return', %L, null,
                                                                                 '1000000') $q$,
                                                       pg_temp.ln('05', 1), pg_temp.pay('13')))),
                pg_temp.refusal(pg_temp.attempt(format($q$ select pg_temp.link('k1-ref-rmt', %L, 'refund', null, %L,
                                                                                 null) $q$,
                                                       pg_temp.ln('05', 1),
                                                       (select (v ->> 'refund_request_id')::uuid from j where k = 'q1')))),
                pg_temp.refusal(pg_temp.attempt('select pg_temp.k1_other_debit_rmt()'))],
          array_fill('debit link refused: own_transfer_line'::text, array[5]),
  '« Retour du paiement » on our batch line, a manual refund on it, a return or a refund on an RMT debit (transfer_out '
  'or other_debit): own_transfer_line');
-- a refund whose transfer is in a file handed out reaches its own trigger (M2c-6a's G2 rule: only its own PmtInf's batch
-- line in that file executes it), which refuses our payouts' batch line
create or replace function pg_temp.k1_handed_out_refund() returns text language plpgsql as $$
declare q uuid; v text;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  q := (public.request_refund('k1-filed-0001', pg_temp.pay('13'), '1000', null, null, 'other', null, '1000000',
                              'payeur inconnu') ->> 'refund_request_id')::uuid;
  reset role;
  perform pg_temp.handed_out('fk1', 'gen-file-k1');
  return pg_temp.link('k1-filed-link', pg_temp.ln('05', 2), 'refund', null, q, null);
end $$;
select ok(pg_temp.attempt('select pg_temp.k1_handed_out_refund()')
            ~ '^debit link refused: posting_failed \(23514: refund refused: reissue_in_downloaded_file',
  'a refund in a downloaded file, linked on our payouts'' batch line: refused by its trigger (another PmtInf)');
select is(pg_temp.try('01', format($q$ select public.link_debit('fee-line-0001', %L, 'fee', null, null, null, 'frais')
                                      ->> 'kind' $q$, pg_temp.ln('05', 2))),
          'bank booking refused: not_a_fee', 'a fee refused on a batch line of our file (even coded as a charge)');
create or replace function pg_temp.queue(p_tab text, p_line uuid) returns boolean language plpgsql as $$
declare v boolean;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  select exists (select 1 from public.debit_queue(p_tab, 0, 100) q where q.bank_transaction_id = p_line) into v;
  reset role;
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(array[pg_temp.queue('a-classer', pg_temp.ln('04', 2)), pg_temp.queue('a-classer', pg_temp.ln('05', 2)),
                pg_temp.queue('frais', pg_temp.ln('05', 2))],
          array[true, true, false],
  '« Débits et retours »: our batch lines « À classer », never among the fees');
-- every review reason the job may write
create or replace function pg_temp.reasons() returns text[] language plpgsql as $$
declare r text; v_bad text[] := '{}';
begin
  foreach r in array array['cancelled_transfer_debited', 'transfer_debited_twice', 'transfer_not_handed_out',
                           'transfer_unknown', 'transfer_differs', 'run_not_in_flight', 'batch_partial', 'batch_mixed',
                           'return_differs', 'return_before_debit', 'own_transfer_out'] loop
    begin
      update public.bank_debit_review set reason = r where bank_transaction_id = pg_temp.ln('05', 1);
    exception when others then
      v_bad := v_bad || r;
    end;
  end loop;
  return v_bad;
end $$;
select pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.ln('05', 1), 'reason', 'batch_partial')));
select is(pg_temp.reasons(), '{}'::text[], 'every review reason of the funds pass is accepted');


-- 5. The booking-time cover, and a chunk with a line the posting refuses -------------------------------------------------
insert into t select 'r8', pg_temp.run('a8', '{"08": "100000"}', 18000, 3000);
select pg_temp.handed_out('f4', 'gen-file-4');
-- Petit's collection reversed after the approval (the payment taken back): 4670[Petit] now 0, the run in flight
select private.ledger_reverse((select id from public.ledger_entry where payment_id = pg_temp.pay('08')
                                 and entry_type = 'allocation'), 'rev-test-0008', 'Retour du paiement (test)',
                              private.paris_today());
-- a PmtInf of one payout the bank booked as one line without TxDtls (NbOfTxs 1: the parser's other_debit; review T4)
select pg_temp.stmt('06', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 82000, 'kind', 'other_debit', 'pmt', pg_temp.pmt(pg_temp.trid('r8')))));
select results_eq(
  $$ select line_kind, role, transfer_id from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa',
                                                                              null, null, 100)
     where line_id = pg_temp.ln('06', 1) $$,
  $$ values ('other_debit'::text, 'member'::text, pg_temp.trid('r8')) $$,
  'a one-payout PmtInf''s line read as other_debit is the funds pass''s: its member');
select pg_temp.stmt('07', private.paris_today() + 1, jsonb_build_array(
  jsonb_build_object('amount', 700, 'kind', 'other_debit', 'code', 'PMNT/CCRD/CHRG')));
insert into j select 'b5', pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('06', 1), 'payout', pg_temp.trid('r8')),
                                                          pg_temp.row(pg_temp.ln('07', 1), 'fee')));
select is(array[(select v ->> 'payouts' from j where k = 'b5'), (select v ->> 'failed' from j where k = 'b5'),
                pg_temp.bookings(pg_temp.ln('06', 1))::text, left(pg_temp.review(pg_temp.ln('07', 1)), 20)],
          array['1', '1', '{"1 payout 82000"}', 'posting_failed:LG006'],
  'one chunk: the batch line booked, the line the posting refuses (a future date) left to ops alone');
select results_eq(
  $$ select client_organization_id, amount_minor, cause, cause_entry_id, entry_id, transfer_id, bank_transaction_id
     from public.client_advance $$,
  $$ values ('00000000-0000-0000-0000-0000000000a8'::uuid, 100000::bigint, 'payout_overrun'::text,
             pg_temp.ek('remit:' || pg_temp.trid('r8')), pg_temp.ek('adv:payout:' || pg_temp.trid('r8')),
             pg_temp.trid('r8'), pg_temp.ln('06', 1)) $$,
  'the booking-time cover: an advance of what the payout left in debit on Petit''s 4670 (cause payout_overrun)');
select is(pg_temp.books(pg_temp.ek('adv:payout:' || pg_temp.trid('r8'))),
          '{"due_to_servicer": 100000, "client_payable": -100000, "client_advance_receivable": 100000,
            "due_from_client_funds": -100000}'::jsonb,
  'client_advance: +4679 A / −4670[c] A ‖ +4112[c] A / −4689 A');
select is(pg_temp.owed('a8'), 0::bigint, 'Petit''s 4670 never in debit (no LG008)');
select is(pg_temp.alerts('payout_overrun'),
          jsonb_build_array(jsonb_build_array((select id from public.client_advance), 100000)),
  'payout_overrun alert while the advance is open');
select is(pg_temp.dirty(), '{}'::text[], 'clean after the cover (I13, I14: the advance item offsets the reversal)');
create or replace function pg_temp.uncovered() returns text language plpgsql as $$
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'remittance', private.paris_today(), 'remit:test-uncovered',
          '00000000-0000-0000-0000-0000000000a8', 'bank_transaction', pg_temp.ln('06', 1)::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_payable', 100, 'EUR', null),
    (1, 2, 'client_money_cash', -100, 'EUR', '80000000-0000-0000-0000-0000000000cf');
  perform private.ledger_post_set();
  perform private.ledger_check_now();
  return 'posted';
exception when others then
  return sqlstate;
end $$;
select is(pg_temp.uncovered(), 'LG008', 'without the cover, a payout beyond what the client is owed fails (LG008)');


-- 6. R124-6 breach rows: in flight only once the statements cover the date; at the debit for a late one -----------------
create or replace function pg_temp.bd_before(p_day date) returns date language sql as $$
  select max(c.day) from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day < p_day $$;
insert into dated values (pg_temp.f('04'), pg_temp.bd_before(private.paris_today() - 1)),
                         (pg_temp.f('05'), private.paris_today() - 1), (pg_temp.f('11'), private.paris_today());
insert into earliest_hdr values ('a4', private.paris_today() + 20), ('a5', private.paris_today() + 20);
insert into t select 'r4', pg_temp.run('a4', '{"04": "40000"}', 7200, 1200);
select pg_temp.handed_out('f5', 'gen-file-5');
create or replace function pg_temp.chk() returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa') returning id into v;
  perform private.run_remittance_runs_checks(v, '00000000-0000-0000-0000-0000000000aa', null);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return v;
end $$;
insert into t select 'c1', pg_temp.chk();
select is(array[(select count(*) from public.remittance_deadline_breach where run_id = pg_temp.v('r4'))::integer,
                (select count(*) from public.payment_check_result where run_id = pg_temp.v('c1')
                   and code = 'remittance_payout_overdue' and subject_id = pg_temp.v('r4'))::integer],
          array[0, 1],
  'in flight past its date, no statement covering that day yet: the alert only, no breach row (append-only)');
select pg_temp.stmt('08', pg_temp.bd_before(private.paris_today() - 1));
insert into t select 'c2', pg_temp.chk();
select results_eq(
  $$ select latest_execution_date, requested_execution_date from public.remittance_deadline_breach
     where run_id = pg_temp.v('r4') $$,
  $$ select pg_temp.bd_before(private.paris_today() - 1), (select requested_execution_date from public.remittance_run
                                                           where id = pg_temp.v('r4')) $$,
  'once a statement covers that day without the debit: the breach row');
insert into t select 'r5', pg_temp.run('a5', '{"05": "30000", "11": "10000"}', 7200, 1200);
select pg_temp.handed_out('f6', 'gen-file-6');
select pg_temp.stmt('09', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(pg_temp.trid('r5')))));
select pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('09', 1), 'payout', pg_temp.trid('r5'))));
select results_eq(
  $$ select b.latest_execution_date, l.account_id from public.remittance_deadline_breach b
     join public.remittance_line l on l.ledger_entry_id = b.ledger_entry_id where b.run_id = pg_temp.v('r5') $$,
  $$ values (private.paris_today() - 1, pg_temp.f('05')) $$,
  'at the debit: a breach row for the item debited after its date, none for the one debited on its last execution '
  'day (review T4)');
-- review concurrency-2: the pass took the key-share locks its breach rows' payments need before the allocation lock — the
-- set it locked holds every payment a breach row of the booking names
create or replace function pg_temp.key_shared() returns uuid[] language plpgsql as $$
declare v uuid[];
begin
  if to_regclass('pg_temp._bb_pay_locks') is null then
    return null;
  end if;
  execute 'select array_agg(l.payment_id order by l.payment_id) from pg_temp._bb_pay_locks l' into v;
  return v;
end $$;
select is(pg_temp.key_shared(),
          (select array_agg(b.payment_id order by b.payment_id) from public.remittance_deadline_breach b
           where b.run_id = pg_temp.v('r5') and b.payment_id is not null),
  'the payments locked FOR KEY SHARE before the allocation lock: those of the late lines, the breach rows'' payments');


-- 7. client_advance: who reads it, nobody writes it -----------------------------------------------------------------
create or replace function pg_temp.reads(p_user text, p_aal text default 'aal2') returns integer language plpgsql as $$
declare n integer;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  select count(*) into n from public.client_advance;
  reset role;
  return n;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(array[pg_temp.reads('01'), pg_temp.reads('01', 'aal1'), pg_temp.reads('03'), pg_temp.reads('08'),
                pg_temp.reads('07'), pg_temp.reads('02'), pg_temp.reads('05')],
          array[1, 0, 1, 0, 0, 0, 0],
  'client_advance: money staff at aal2; Petit''s admin (the whole client); not Lilas, a restricted viewer, a collector, another servicer');
select is(pg_temp.try('01', $q$ insert into public.client_advance (organization_id, client_organization_id, currency,
                                  amount_minor, cause, cause_entry_id, entry_id)
                                values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a8',
                                        'EUR', 1, 'payout_overrun', gen_random_uuid(), gen_random_uuid()) returning 'x' $q$),
          'permission denied for table client_advance', 'no direct write (42501)');
select throws_ok($$ update public.client_advance set amount_minor = 1 $$, '23514', null,
  'append-only: an advance never changes');
select throws_like(
  $$ insert into public.client_advance (organization_id, client_organization_id, currency, amount_minor, cause,
                                        cause_entry_id, entry_id)
     values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a8', 'EUR', 99,
             'payout_overrun', pg_temp.ek('remit:' || pg_temp.trid('r8')), pg_temp.ek('remit:' || pg_temp.trid('r1'))) $$,
  '%not the client_advance entry of its client for its amount%', 'its guard: the entry must be that advance''s');


-- 8. A re-issue is never booked by its predecessor's id or PmtInf, nor by another file's (switch on, rolled back) --------
create or replace function pg_temp.sc_g2() returns jsonb language plpgsql as $$
declare v_run uuid; v_x uuid; v_y uuid; v_fx uuid; v_fy uuid; v jsonb := '{}';
begin
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  perform pg_temp.collect('12', 40000, private.paris_today() - 3);
  v_run := pg_temp.runk('a2', '{"12": "40000"}', 7200, 1200, 'g2');
  v_x := (select transfer_id from public.remittance_run where id = v_run);
  v_fx := (pg_temp.gen('01', 'gen-file-g2x') ->> 'file_id')::uuid;
  perform pg_temp.write(v_fx);
  perform pg_temp.download('01', v_fx);
  perform private.transfer_file_release(v_fx, 'rejected', 'Rejeté par la banque (test)', 'rejected_by_bank', null);
  v_y := (select transfer_id from public.remittance_run where id = v_run);
  v_fy := (pg_temp.gen('01', 'gen-file-g2y') ->> 'file_id')::uuid;
  perform pg_temp.write(v_fy);
  perform pg_temp.download('01', v_fy);
  perform pg_temp.stmt('10', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(v_x)),
    jsonb_build_object('amount', 32800, 'kind', 'batch_unsplit',
                       'pmt', (select i.pmt_inf_id from public.transfer_file_item i
                               where i.file_id = v_fx and i.transfer_id = v_x)),
    jsonb_build_object('amount', 32800, 'kind', 'batch_unsplit', 'pmt', (pg_temp.fl(pg_temp.v('f1'))).number || '-1')));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('10', 1), 'payout', v_y)));
  v := v || jsonb_build_object('old_id_y', pg_temp.skipped(pg_temp.ln('10', 1)));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('10', 2), 'payout', v_y)));
  v := v || jsonb_build_object('old_pmt_y', pg_temp.skipped(pg_temp.ln('10', 2)));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('10', 3), 'payout', v_y)));
  v := v || jsonb_build_object('foreign_pmt_y', pg_temp.skipped(pg_temp.ln('10', 3)));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('10', 1), 'payout', v_x)));
  v := v || jsonb_build_object('old_id_x', pg_temp.skipped(pg_temp.ln('10', 1)));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('10', 2), 'payout', v_x)));
  v := v || jsonb_build_object('old_pmt_x', pg_temp.skipped(pg_temp.ln('10', 2)));
  v := v || jsonb_build_object('y', pg_temp.status(v_y),
                               'bookings', (select count(*) from public.bank_line_booking b
                                            where b.transfer_id in (v_x, v_y)),
                               'alerted', (select jsonb_agg(a -> 0 order by a ->> 1, a ->> 0)
                                           from jsonb_array_elements(pg_temp.alerts('cancelled_transfer_debited')) a
                                           where (a ->> 0)::uuid in (pg_temp.ln('10', 1), pg_temp.ln('10', 2),
                                                                     pg_temp.ln('10', 3))));
  return v;
end $$;
insert into j select 'g2', pg_temp.isolated('sc_g2');
select is((select v - 'alerted' from j where k = 'g2'),
          '{"old_id_y": "not_its_line", "old_pmt_y": "not_its_line", "foreign_pmt_y": "not_its_line",
            "old_id_x": "cancelled_transfer_debited", "old_pmt_x": "cancelled_transfer_debited", "y": "in_file",
            "bookings": 0}'::jsonb,
  'G2 for payouts (switch on): the re-issue is never booked by the old id, the old file''s PmtInf or another file''s; '
  'the cancelled predecessor never automatically');
select is((select jsonb_array_length(v -> 'alerted') from j where k = 'g2'), 2,
  'cancelled_transfer_debited raised for the old id''s line and the old PmtInf''s batch line (not the foreign one)');
select is(private.switch_on('downloaded_file_cancellation'), false, 'and the switch is off again (033 and 034 unchanged)');


-- 9. Review round 1 -------------------------------------------------------------------------------------------------------
-- T3: each nightly check fires on the one fault it watches (seeded in a subtransaction rolled back)
create or replace function pg_temp.free_entry(p_n integer) returns uuid language sql as $$
  select e.id from public.ledger_entry e
  where e.organization_id = '00000000-0000-0000-0000-0000000000aa' and e.entry_type = 'client_settlement'
    and not exists (select 1 from public.bank_transfer t where t.entry_id = e.id or t.return_entry_id = e.id)
  order by e.id offset p_n limit 1 $$;
-- I20, status rule: Lambert's payout (in its downloaded file) `booked` with an entry and no debit booking
create or replace function pg_temp.sc_i20_payout() returns jsonb language plpgsql as $$
begin
  update public.bank_transfer set status = 'booked', entry_id = pg_temp.free_entry(0) where id = pg_temp.trid('r4');
  return pg_temp.pchecks();
end $$;
-- I20, run rule: Lambert's run `booked` while its payout is still in its file
create or replace function pg_temp.sc_i20_run() returns jsonb language plpgsql as $$
begin
  update public.remittance_run set status = 'booked', booked_on = private.paris_today() where id = pg_temp.v('r4');
  return pg_temp.pchecks();
end $$;
-- I20, status rule: the booked sweep of F2 `returned` with no return booking
create or replace function pg_temp.sc_i20_returned() returns jsonb language plpgsql as $$
begin
  update public.bank_transfer set status = 'returned', return_entry_id = pg_temp.free_entry(1) where id = pg_temp.v('s2');
  return pg_temp.pchecks();
end $$;
-- I20, refund rule: a file-mode refund's transfer `booked` with an entry that is not its request's cash_out (no link)
create or replace function pg_temp.sc_i20_refund() returns jsonb language plpgsql as $$
declare q uuid; v uuid;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  q := (public.request_refund('i20-refund-0001', pg_temp.pay('13'), '1000', null, null, 'other', null, '1000000',
                              'payeur inconnu') ->> 'refund_request_id')::uuid;
  reset role;
  v := (select transfer_id from public.refund_request where id = q);
  update public.bank_transfer set status = 'booked', entry_id = pg_temp.free_entry(0) where id = v;
  return jsonb_build_object('transfer', v, 'checks', pg_temp.pchecks());
end $$;
-- bank_line_booked: a fee of 4,00 € booked on the 10,00 € other debit (the deferred completeness check not run yet)
create or replace function pg_temp.sc_line_booked() returns jsonb language plpgsql as $$
declare v_entry uuid;
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id, reason)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'bank_fee', private.paris_today(), 'fee:' || pg_temp.ln('05', 2),
          'bank_transaction', pg_temp.ln('05', 2)::text, 'frais (test)');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'due_to_servicer', 400, 'EUR', null),
    (1, 2, 'client_money_cash', -400, 'EUR', '80000000-0000-0000-0000-0000000000cf'),
    (1, 3, 'bank_fees', 400, 'EUR', null), (1, 4, 'due_from_client_funds', -400, 'EUR', null);
  select x.entry_id into v_entry from private.ledger_post_set() x;
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, entry_id,
                                        amount_minor, method)
  values (pg_temp.ln('05', 2), 1, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'fee',
          v_entry, 400, 'auto');
  return pg_temp.pchecks();
end $$;
-- top_up_pending: a top-up ordered today, still not credited
create or replace function pg_temp.sc_top_up() returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.request_top_up('top-up-test-0001', '80000000-0000-0000-0000-0000000000c0',
                                '80000000-0000-0000-0000-0000000000cf', '5000', 'approvisionnement (test)');
  reset role;
  return jsonb_build_array('top_up_pending' = any (pg_temp.tcodes(pg_temp.bd_after(3))),
                           'top_up_pending' = any (pg_temp.tcodes(private.paris_today())));
end $$;
select ok(pg_temp.isolated('sc_i20_payout')
            @> jsonb_build_array(jsonb_build_array('transfer_booked_once', pg_temp.trid('r4'))),
  'I20: a payout booked without its debit booking');
select ok(pg_temp.isolated('sc_i20_run') @> jsonb_build_array(jsonb_build_array('transfer_booked_once', pg_temp.v('r4'))),
  'I20: a run booked while its payout is not');
select ok(pg_temp.isolated('sc_i20_returned')
            @> jsonb_build_array(jsonb_build_array('transfer_booked_once', pg_temp.v('s2'))),
  'I20: a sweep returned without its return booking');
select ok((select (x.v -> 'checks') @> jsonb_build_array(jsonb_build_array('transfer_booked_once', x.v ->> 'transfer'))
           from (select pg_temp.isolated('sc_i20_refund') as v) x),
  'I20: a refund''s transfer booked with an entry that is not its request''s cash_out (no M2b link)');
select ok((select x.v @> jsonb_build_array(jsonb_build_array('bank_line_booked', pg_temp.ln('05', 2)))
                  and not x.v @> jsonb_build_array(jsonb_build_array('bank_cash_identity',
                                                                     '80000000-0000-0000-0000-0000000000cf'))
           from (select pg_temp.isolated('sc_line_booked') as v) x),
  'bank_line_booked: a line booked for less than its amount (I19 itself balanced)');
select is(array['bank_line_unbooked' = any (pg_temp.tcodes(pg_temp.bd_after(3))),
                'bank_line_unbooked' = any (pg_temp.tcodes(private.paris_today()))],
          array[true, false],
  'bank_line_unbooked: our lines left to ops more than a business day (an I9 gap), not on the day');
select is(pg_temp.isolated('sc_top_up'), '[true, false]'::jsonb,
  'top_up_pending: a top-up not credited more than a business day after its order, not on the day');

-- K2 (legal-texts#1, money-2): Martin's returned payout paid again keeps its returned run's date (the worker's prepare
-- dates its line: emulated here) and a breach of it is recorded « bloqué : virement revenu impayé », at the approval,
-- at the debit, in flight
create or replace function pg_temp.prepare_returned(p_run uuid, p_latest date, p_hdr date) returns void
language plpgsql as $$
declare r public.remittance_run; l public.remittance_line;
begin
  select * into r from public.remittance_run where id = p_run;
  select * into l from public.remittance_line x where x.run_id = pg_temp.v('r1') and x.amount_minor > 0
  order by x.latest_execution_date, x.line_no limit 1;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, mandate_id, mandate_terms_id,
                                             encaissement_date, effective_date, posted_at, deadline,
                                             latest_execution_date, amount_minor, commission_state)
  select p_run, 1, q.ledger_entry_id, q.kind, l.mandate_id, l.mandate_terms_id, l.encaissement_date, e.effective_date,
         q.posted_at, p_latest + 1, p_latest, q.amount_minor, 'none'
  from private.remittance_pending q join public.ledger_entry e on e.id = q.ledger_entry_id
  where q.draft_run_id = p_run;
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', 1, 'gross', '164000', 'invoice_ht', '0', 'invoice_vat', '0', 'invoice_ttc', '0', 'credit_ht', '0',
    'credit_vat', '0', 'credit_ttc', '0', 'taken', '0', 'advances', '0', 'refunds', '0', 'settlement', '0',
    'net', '164000', 'vat_rate', '0.2', 'earliest_deadline', p_latest + 1, 'earliest_latest_execution_date', p_hdr,
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text, 'UTF8')), 'hex'), 'payout_account_id', pg_temp.v('pa1'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', '[]'::jsonb, 'key_states', '[]'::jsonb,
    'plan', jsonb_build_object('settles', '[]'::jsonb, 'net', '164000', 'settlement', '0', 'dc', '0', 'da', '0',
                               'vat_moved', '0', 'deferred', true, 'invoice_ht', '0', 'invoice_vat', '0',
                               'invoice_ttc', '0')));
end $$;
create or replace function pg_temp.returned_run(p_key text, p_latest date, p_hdr date) returns uuid language plpgsql as $$
declare v_run uuid;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v_run := (public.request_remittance_run('rq-' || p_key, '00000000-0000-0000-0000-0000000000a1') ->> 'run_id')::uuid;
  reset role;
  perform pg_temp.prepare_returned(v_run, p_latest, p_hdr);
  return v_run;
end $$;
-- approved by ops for the next business day (with p_reason when given), the approval job run when queued
create or replace function pg_temp.approve(p_key text, p_run uuid, p_reason text default null) returns text
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.approve_remittance_runs('ap-' || p_key, pg_temp.item(p_run), null, p_reason);
  reset role;
  if v -> 'results' -> 0 ->> 'status' = 'queued' then
    perform private.approve_remittance_run(p_run, (select job_token from public.remittance_run where id = p_run));
  end if;
  return coalesce(v -> 'results' -> 0 ->> 'reason', v -> 'results' -> 0 ->> 'status');
end $$;
grant execute on all functions in schema pg_temp to authenticated;
create or replace function pg_temp.sc_returned_late_approval() returns jsonb language plpgsql as $$
declare v_run uuid; v_first text; v_second text;
begin
  v_run := pg_temp.returned_run('k2-late-approval', private.paris_today() - 1, private.paris_today() - 1);
  v_first := pg_temp.approve('k2-late-approval-1', v_run);
  v_second := pg_temp.approve('k2-late-approval-2', v_run, 'payé de nouveau après son retour (test)');
  return jsonb_build_object('without_reason', v_first, 'with_reason', v_second,
    'run', (select status from public.remittance_run where id = v_run),
    'late_approvals', (select count(*) from public.remittance_late_approval where run_id = v_run),
    'breach', (select jsonb_agg(jsonb_build_array(b.blocked_reason, b.latest_execution_date = private.paris_today() - 1))
               from public.remittance_deadline_breach b where b.run_id = v_run));
end $$;
create or replace function pg_temp.sc_returned_late_debit() returns jsonb language plpgsql as $$
declare v_run uuid; v_tr uuid;
begin
  v_run := pg_temp.returned_run('k2-late-debit', private.paris_today() - 1, private.paris_today() + 20);
  perform pg_temp.approve('k2-late-debit', v_run);
  v_tr := (select transfer_id from public.remittance_run where id = v_run);
  perform pg_temp.handed_out('fk2b', 'gen-file-k2b');
  perform pg_temp.stmt('15', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(v_tr))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('15', 1), 'payout', v_tr)));
  return jsonb_build_object('run', (select status from public.remittance_run where id = v_run),
    'late_approvals', (select count(*) from public.remittance_late_approval where run_id = v_run),
    'breach', (select jsonb_agg(jsonb_build_array(b.blocked_reason, b.requested_execution_date is not null))
               from public.remittance_deadline_breach b where b.run_id = v_run));
end $$;
create or replace function pg_temp.sc_returned_overdue() returns jsonb language plpgsql as $$
declare v_run uuid; v_c uuid;
begin
  v_run := pg_temp.returned_run('k2-overdue', private.paris_today() - 1, private.paris_today() + 20);
  perform pg_temp.approve('k2-overdue', v_run);
  v_c := pg_temp.chk();
  return jsonb_build_object(
    'transfer', (select t.status from public.bank_transfer t join public.remittance_run r on r.transfer_id = t.id
                 where r.id = v_run),
    'breach', (select jsonb_agg(b.blocked_reason) from public.remittance_deadline_breach b where b.run_id = v_run),
    'overdue', exists (select 1 from public.payment_check_result c where c.run_id = v_c
                         and c.code = 'remittance_payout_overdue' and c.subject_id = v_run));
end $$;
select is(pg_temp.isolated('sc_returned_late_approval'),
          '{"without_reason": "late_reason_required", "with_reason": "queued", "run": "approved", "late_approvals": 1,
            "breach": [["payout_returned", true]]}'::jsonb,
  'a returned payout paid again after its date: late_reason_required without a reason; with one, its late approval '
  'and its breach row « bloqué : virement revenu impayé » (payout_returned)');
select is(pg_temp.isolated('sc_returned_late_debit'),
          '{"run": "booked", "late_approvals": 0, "breach": [["payout_returned", true]]}'::jsonb,
  'approved on time, debited after its date: the booking''s breach row is payout_returned');
select is(pg_temp.isolated('sc_returned_overdue'),
          '{"transfer": "ordered", "breach": ["payout_returned"], "overdue": true}'::jsonb,
  'in flight past its date (never handed out): the nightly check''s breach row is payout_returned');
-- legal-texts#1 item 3 (integration of the worker's K2): a payout returned a second time. Its re-proposed line has the
-- worker's shape (jobs/remittances.py _held_to: no mandate — no file, no mandate's gross — but the terms version it was
-- held to); the new item waiting is still held to the first run's line: its E, that version's delay, and monitored
-- (the nightly J-5/J-1 alerts and its breach row), as the worker's prepare holds it (parity)
create or replace function pg_temp.held_returned() returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_array(d.encaissement_date, d.max_days, d.deadline, d.latest_execution_date, d.unmeetable,
                                     d.monitored))
  from private.pending_item_deadlines('00000000-0000-0000-0000-0000000000aa') d
  join private.remittance_pending q on q.ledger_entry_id = d.ledger_entry_id
  where q.kind = 'payout_returned' and q.client_organization_id = '00000000-0000-0000-0000-0000000000a1' $$;
create or replace function pg_temp.sc_returned_twice() returns jsonb language plpgsql as $$
declare v_run uuid; v_tr uuid; v_first jsonb; l public.remittance_line;
begin
  select * into l from public.remittance_line x where x.run_id = pg_temp.v('r1') and x.amount_minor > 0
  order by x.latest_execution_date, x.line_no limit 1;
  v_first := pg_temp.held_returned();   -- the first return's item, waiting
  v_run := pg_temp.returned_run('k2-twice', private.paris_today() + 5, private.paris_today() + 20);
  update private.remittance_draft_line set mandate_id = null where run_id = v_run;
  perform pg_temp.approve('k2-twice', v_run);
  v_tr := (select transfer_id from public.remittance_run where id = v_run);
  perform pg_temp.handed_out('fk2t', 'gen-file-k2t');
  perform pg_temp.stmt('18', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(v_tr))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('18', 1), 'payout', v_tr)));
  perform pg_temp.stmt('19', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(v_tr))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('19', 1), 'payout_returned', v_tr)));
  return jsonb_build_object(
    'line', (select jsonb_build_array(x.mandate_id is null, x.mandate_terms_id = l.mandate_terms_id,
                                      x.encaissement_date = l.encaissement_date)
             from public.remittance_line x where x.run_id = v_run),
    'transfer', pg_temp.status(v_tr),
    'first', jsonb_build_array(v_first -> 0 -> 0 = to_jsonb(l.encaissement_date), v_first -> 0 -> 5),
    'same', pg_temp.held_returned() = v_first);
end $$;
select is(pg_temp.isolated('sc_returned_twice'),
          '{"line": [true, true, true], "transfer": "returned", "first": [true, true], "same": true}'::jsonb,
  'a payout returned twice: the new item is held as the first was (the first run''s line: its E, its terms'' delay), '
  'monitored');

-- K3 (legal-texts#2): proven unpaid only with evidence of absence — a debit line that could hold the payout (a batch line
-- of its PmtInf whatever its amount, a line with neither reference of exactly its amount) in its window keeps the
-- alert only; a line of another amount does not (Cyprès, paid early on a CSV export without the end-to-end column)
create or replace function pg_temp.csv(p_n text, p_lines jsonb, p_from date, p_to date, p_uploaded timestamptz)
returns uuid language plpgsql as $$
declare s uuid := ('e4000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'csv', 'r.csv',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = p_uploaded where id = s;
  insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id)
  select '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, l.ord, 'c:' || s || l.ord,
         'debit', (l.v ->> 'amount')::bigint, 'EUR', (l.v ->> 'day')::date, l.v ->> 'kind', l.v ->> 'e2e', l.v ->> 'pmt'
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  update public.bank_statement set status = 'imported', from_date = p_from, to_date = p_to, counts = '{}',
    finished_at = clock_timestamp()
  where id = s;
  return s;
end $$;
create or replace function pg_temp.k3(p_plus bigint, p_batch boolean) returns jsonb language plpgsql as $$
declare v_r date; v_l date; v_l1 date; v_run uuid; v_tr public.bank_transfer; v_c uuid;
begin
  v_r := private.next_business_day(private.paris_today());
  v_l := private.next_business_day(private.next_business_day(v_r));
  v_l1 := private.next_business_day(v_l);
  perform pg_temp.file('15', '20000000-0000-0000-0000-0000000000a3', 40000);
  perform pg_temp.collect('15', 40000, private.paris_today() - 3);
  insert into dated values (pg_temp.f('15'), v_l);
  v_run := pg_temp.runk('a3', '{"15": "40000"}', 7200, 1200, 'k3');
  perform pg_temp.handed_out('fk3', 'gen-file-k3');
  select x.* into v_tr from public.bank_transfer x join public.remittance_run r on r.transfer_id = x.id where r.id = v_run;
  perform pg_temp.csv('01', jsonb_build_array(
      jsonb_build_object('day', v_r, 'kind', 'transfer_out', 'amount', v_tr.amount_minor + p_plus,
                         'pmt', case when p_batch then pg_temp.pmt(v_tr.id) end),
      jsonb_build_object('day', v_l1, 'kind', 'other_debit', 'amount', 150)),
    v_r, v_l1, (v_l1 + 1 + time '09:00') at time zone 'Europe/Paris');
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v_c;
  perform private.run_remittance_runs_checks(v_c, '00000000-0000-0000-0000-0000000000aa', v_l1);
  return jsonb_build_object(
    'window', v_tr.requested_execution_date = v_r
              and (select min(l.latest_execution_date) from public.remittance_line l where l.run_id = v_run) = v_l,
    'covered', private.statement_covers('80000000-0000-0000-0000-0000000000cf', v_l, v_l),
    'breach_rows', (select count(*) from public.remittance_deadline_breach where run_id = v_run),
    'overdue', exists (select 1 from public.payment_check_result c where c.run_id = v_c
                         and c.code = 'remittance_payout_overdue' and c.subject_id = v_run));
end $$;
create or replace function pg_temp.sc_k3_exact() returns jsonb language sql as $$ select pg_temp.k3(0, false) $$;
create or replace function pg_temp.sc_k3_batch() returns jsonb language sql as $$ select pg_temp.k3(500, true) $$;
create or replace function pg_temp.sc_k3_other() returns jsonb language sql as $$ select pg_temp.k3(1, false) $$;
select is(array[pg_temp.isolated('sc_k3_exact'), pg_temp.isolated('sc_k3_batch'), pg_temp.isolated('sc_k3_other')],
          array['{"window": true, "covered": true, "breach_rows": 0, "overdue": true}'::jsonb,
                '{"window": true, "covered": true, "breach_rows": 0, "overdue": true}',
                '{"window": true, "covered": true, "breach_rows": 1, "overdue": true}'],
  'statements covering its date: a reference-less line of its amount, or a batch line of its PmtInf, in its window '
  'keeps the alert only (no permanent breach row); a line of another amount is no evidence: the row');

-- T5: a payout debited on the last day of the previous month, imported this month: the remittance, the settlement (its
-- VAT due) and the run's booked_on in the month of the debit
create or replace function pg_temp.sc_month_end() returns jsonb language plpgsql as $$
declare v_d date := date_trunc('month', private.paris_today())::date - 1; v_run uuid; v_tr uuid; v_settle uuid;
begin
  perform pg_temp.file('16', '20000000-0000-0000-0000-0000000000a3', 40000);
  perform pg_temp.collect('16', 40000, v_d - 3);
  insert into dated values (pg_temp.f('16'), private.paris_today() + 20);
  v_run := pg_temp.runk('a3', '{"16": "40000"}', 7200, 1200, 'month-end');
  v_tr := (select transfer_id from public.remittance_run where id = v_run);
  perform pg_temp.handed_out('fme', 'gen-file-me');
  perform pg_temp.stmt('16', v_d, jsonb_build_array(jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(v_tr))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('16', 1), 'payout', v_tr)));
  v_settle := pg_temp.ek('settle:' || v_run);
  return jsonb_build_object(
    'previous_month', to_char(v_d, 'YYYY-MM') < to_char(private.paris_today(), 'YYYY-MM'),
    'remit', (select effective_date = v_d from public.ledger_entry where id = pg_temp.ek('remit:' || v_tr)),
    'settle', (select effective_date = v_d from public.ledger_entry where id = v_settle),
    'vat', (select count(*) = 2 and bool_and(p.effective_date = v_d) from public.ledger_posting p
            join public.ledger_account la on la.id = p.ledger_account_id
            where p.entry_id = v_settle and la.book in ('vat_pending', 'vat_collected') and p.amount_minor <> 0),
    'settled_on', (select bool_and(c.settled_on = v_d) from public.commission_settlement c where c.run_id = v_run),
    'booked_on', (select r.booked_on = v_d from public.remittance_run r where r.id = v_run));
end $$;
select is(pg_temp.isolated('sc_month_end'),
          '{"previous_month": true, "remit": true, "settle": true, "vat": true, "settled_on": true,
            "booked_on": true}'::jsonb,
  'debited on the last day of the previous month: remit:, settle: (its VAT due), settled_on and booked_on all dated '
  'that day');

-- T7 (K6): I20's refund rule counts each executed refund's links by its request's key (private.refund_debit_links, the
-- partial index on refund_request_id) — never the whole link table once per executed refund (quadratic). Proven
-- structurally, whatever the plans the rest of the checks get: the nightly checks call the keyed count once per executed
-- refund (pg_stat_xact_user_functions), and each call reads only that request's links (pg_stat_xact_user_tables)
create or replace function pg_temp.sc_refund_links_keyed() returns jsonb language plpgsql as $$
declare i integer; n text; v_calls bigint; v_read bigint; v_requests uuid[];
begin
  set local track_functions = 'pl';
  for i in 1..20 loop
    n := to_hex(64 + i);   -- payments 41 … 54 (hex), 1,00 € each, unidentified
    perform pg_temp.collect(n, 100, private.paris_today() - 3, false);
    perform pg_temp.as_user('01');
    set local role authenticated;
    perform public.request_refund('t7-refund-' || n, pg_temp.pay(n), '100', null, null, 'other', null, '100',
                                  'payeur inconnu');
    reset role;
  end loop;
  v_requests := array(select q.id from public.refund_request q
                      where q.payment_id in (select pg_temp.pay(to_hex(64 + g)) from generate_series(1, 20) g));
  perform pg_temp.handed_out('ft7', 'gen-file-t7');
  perform pg_temp.stmt('17', private.paris_today(),
    (select jsonb_agg(jsonb_build_object('amount', 100, 'kind', 'refund_out', 'e2e', x.end_to_end_id)
                      order by x.end_to_end_id)
     from public.refund_request q join public.bank_transfer x on x.id = q.transfer_id where q.id = any (v_requests)));
  perform private.debit_link_begin();
  insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, refund_request_id, method)
  select row_number() over (order by l.id), l.id, 'refund', q.payment_id, q.id, 'auto'
  from public.bank_transaction l
  join public.bank_transfer x on x.end_to_end_id = l.end_to_end_id
  join public.refund_request q on q.transfer_id = x.id
  where l.statement_id = 'e3000000-0000-0000-0000-000000000017';
  perform private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
  select coalesce(sum(f.calls), 0) into v_calls from pg_stat_xact_user_functions f
  where f.schemaname = 'private' and f.funcname = 'refund_debit_links';
  perform private.run_payment_checks('00000000-0000-0000-0000-0000000000aa');
  select coalesce(sum(f.calls), 0) - v_calls into v_calls from pg_stat_xact_user_functions f
  where f.schemaname = 'private' and f.funcname = 'refund_debit_links';
  select s.seq_tup_read + coalesce(s.idx_tup_fetch, 0) into v_read from pg_stat_xact_user_tables s
  where s.relid = 'public.bank_debit_link'::regclass;
  perform private.refund_debit_links(r) from unnest(v_requests) r;
  select s.seq_tup_read + coalesce(s.idx_tup_fetch, 0) - v_read into v_read from pg_stat_xact_user_tables s
  where s.relid = 'public.bank_debit_link'::regclass;
  return jsonb_build_object('executed', (select count(*) from public.refund_request q
                                         where q.id = any (v_requests) and q.status = 'executed'),
                            'keyed_per_refund', v_calls >= 20,
                            'reads_per_call', v_read <= 2 * 20);
end $$;
select is(pg_temp.isolated('sc_refund_links_keyed'),
          '{"executed": 20, "keyed_per_refund": true, "reads_per_call": true}'::jsonb,
  'I20 with 20 more executed refunds: one keyed count per executed refund, each reading only its request''s links');

-- 10. Review round 2 ------------------------------------------------------------------------------------------------------
-- L1 (new:statement-late-cause): a returned payout paid again after its date is late on the client's statement because its
-- payout came back, never « encaissement identifié tardivement » nor « validation tardive » (collections' causes)
create or replace function pg_temp.sc_returned_statement() returns jsonb language plpgsql as $$
declare v_run uuid; p jsonb; v_late integer; v_cause integer; v_kind integer;
begin
  v_run := pg_temp.returned_run('k2-statement', private.paris_today() - 1, private.paris_today() - 1);
  perform pg_temp.approve('k2-statement', v_run, 'payé de nouveau après son retour (test)');
  p := private.remittance_statement_build(v_run);
  select x.ord - 1 into v_kind from jsonb_array_elements_text(p -> 'line_columns') with ordinality x (c, ord)
  where x.c = 'nature';
  select x.ord - 1 into v_late from jsonb_array_elements_text(p -> 'line_columns') with ordinality x (c, ord)
  where x.c = 'late';
  select x.ord - 1 into v_cause from jsonb_array_elements_text(p -> 'line_columns') with ordinality x (c, ord)
  where x.c = 'late_cause';
  return jsonb_build_object('lines', jsonb_array_length(p -> 'lines'), 'nature', p -> 'lines' -> 0 -> v_kind,
                            'late', p -> 'lines' -> 0 -> v_late, 'late_cause', p -> 'lines' -> 0 -> v_cause,
                            'late_count', p #> '{totals,late_count}');
end $$;
select is(pg_temp.isolated('sc_returned_statement'),
          '{"lines": 1, "nature": "payout_returned", "late": true, "late_cause": "payout_returned", "late_count": 1}'::jsonb,
  'the statement of a returned payout paid again late: its line hors délai, cause payout_returned (not a collection''s)');

-- L2 (new:client-returned-stale): the client's returned run names the run that paid it again, once that run's line holding
-- the payout_returned item is booked (live); null while none is
create or replace function pg_temp.sc_repaid() returns jsonb language plpgsql as $$
declare v_run uuid; v_tr uuid; v_draft jsonb; v_flight jsonb; v_after jsonb;
  q text := $q$ select (public.client_remittance_summary('00000000-0000-0000-0000-0000000000a1') -> 'returned_runs')::text $q$;
begin
  v_run := pg_temp.returned_run('k4-repaid', private.paris_today() + 5, private.paris_today() + 20);
  v_draft := pg_temp.try('14', q)::jsonb;
  perform pg_temp.approve('k4-repaid', v_run);
  v_tr := (select transfer_id from public.remittance_run where id = v_run);
  perform pg_temp.handed_out('fk4', 'gen-file-k4');
  v_flight := pg_temp.try('14', q)::jsonb;
  perform pg_temp.stmt('20', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(v_tr))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('20', 1), 'payout', v_tr)));
  v_after := pg_temp.try('14', q)::jsonb;
  return jsonb_build_object('keyed', v_draft -> 0 ? 'repaid_by' and v_flight -> 0 ? 'repaid_by',
                            'draft', v_draft -> 0 -> 'repaid_by', 'in_flight', v_flight -> 0 -> 'repaid_by',
                            'booked', v_after -> 0 ->> 'repaid_by'
                                      = (select number from public.remittance_run where id = v_run),
                            'runs', jsonb_array_length(v_after), 'run', v_after -> 0 ->> 'run_id' = pg_temp.v('r1')::text,
                            'status', (select status from public.remittance_run where id = v_run));
end $$;
select is(pg_temp.isolated('sc_repaid'),
          '{"keyed": true, "draft": null, "in_flight": null, "booked": true, "runs": 1, "run": true, "status": "booked"}'::jsonb,
  'returned_runs.repaid_by: null while the payout_returned item is in a draft or a run in flight, then the number of the '
  'run that paid it again once that run is booked');

-- L4 (money-1, defence in depth): « Perte » (link_debit loss, nothing left of the payment) on every shape of our lines —
-- an RMT or SWP debit, our batch lines, a debit return carrying our id (as its own or as its original), a credit returning
-- an RMT or SWP transfer — is own_transfer_line: never the servicer's loss
create or replace function pg_temp.sc_loss_own() returns jsonb language plpgsql as $$
declare v jsonb := '[]'; k integer;
begin
  perform pg_temp.collect('30', 2000, private.paris_today() - 3, false);
  perform pg_temp.stmt('30', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 2000, 'kind', 'return', 'e2e', 'E2E-30')));
  perform pg_temp.link('loss-own-ret', pg_temp.ln('30', 1), 'return', pg_temp.pay('30'), null, '2000');
  perform pg_temp.stmt('31', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 1000, 'kind', 'transfer_out', 'e2e', pg_temp.e2e(pg_temp.trid('r2'))),
    jsonb_build_object('amount', 1000, 'kind', 'other_debit', 'e2e', pg_temp.e2e(pg_temp.trid('r2'))),
    jsonb_build_object('amount', 1000, 'kind', 'other_debit', 'e2e', pg_temp.e2e(pg_temp.v('s1'))),
    jsonb_build_object('amount', 1000, 'kind', 'other_debit', 'pmt', pg_temp.pmt(pg_temp.trid('r2'))),
    jsonb_build_object('amount', 1000, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(pg_temp.trid('r2'))),
    jsonb_build_object('amount', 1000, 'kind', 'transfer_out', 'pmt', pg_temp.pmt(pg_temp.v('s2'))),
    jsonb_build_object('amount', 1000, 'kind', 'return', 'e2e', pg_temp.e2e(pg_temp.trid('r2'))),
    jsonb_build_object('amount', 1000, 'kind', 'return', 'orig', pg_temp.e2e(pg_temp.trid('r2'))),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 1000, 'orig', pg_temp.e2e(pg_temp.trid('r2'))),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 1000, 'e2e', pg_temp.e2e(pg_temp.v('s2')))));
  for k in 1..10 loop
    v := v || to_jsonb(pg_temp.refusal(pg_temp.attempt(format(
           $q$ select pg_temp.link(%L, %L, 'loss', %L, null, '0') $q$, 'loss-own-' || k, pg_temp.ln('31', k),
           pg_temp.pay('30')))));
  end loop;
  -- and the links on a debit « return » naming our RMT id as its original (post_debit_links reads its original id too)
  v := jsonb_build_object('returned', (select status from public.payment where id = pg_temp.pay('30')), 'loss', v,
    'links', jsonb_build_array(
      pg_temp.refusal(pg_temp.attempt(format($q$ select pg_temp.link('own-orig-ret', %L, 'return', %L, null, '1000000') $q$,
                                             pg_temp.ln('31', 8), pg_temp.pay('13')))),
      pg_temp.refusal(pg_temp.attempt(format($q$ select pg_temp.link('own-orig-exp', %L, 'explained', null, null, null) $q$,
                                             pg_temp.ln('31', 8))))));
  return v;
end $$;
select is(pg_temp.isolated('sc_loss_own'),
          jsonb_build_object('returned', 'returned',
                             'loss', to_jsonb(array_fill('bank booking refused: own_transfer_line'::text, array[10])),
                             'links', to_jsonb(array_fill('debit link refused: own_transfer_line'::text, array[2]))),
  '« Perte » (the servicer''s loss of a returned payment) refused on each shape of our lines, and a return or an '
  'explanation of a debit naming our RMT id as its original: own_transfer_line');

-- L4 / L5 (K1's switch-on hole): two file-mode refunds R_a and R_b of 10,00 € in one refunds PmtInf of a downloaded file,
-- a manual one R_m and one not filed yet R_c of the same amount. On our lines « Débits et retours » offers only what the
-- database accepts: on that PmtInf's batch line its own handed-out refunds (never a payment, a manual refund or another
-- file's), on an RMT debit or the return of one nothing; with R_b cancelled after download (switch on), nothing, and the
-- link of R_a is refused (the line may be R_b's: the funds pass's P0, cancelled_transfer_debited, must stay)
-- a refund of 10,00 € of payment p_pay asked by ops (in the next file unless p_mode says otherwise), as the page asks it
create or replace function pg_temp.rq(p_key text, p_pay text, p_mode text default null) returns uuid
language plpgsql as $$
declare q uuid; v_reason text; v_left text;
begin
  select p.review_reason, x.unallocated_minor::text into v_reason, v_left
  from public.payment p cross join lateral private.payment_positions(array[p.id]) x where p.id = pg_temp.pay(p_pay);
  perform pg_temp.as_user('01');
  set local role authenticated;
  q := (public.request_refund(p_key, pg_temp.pay(p_pay), '1000', 'FR7630004000031234567890143', 'PAYEUR ' || p_pay,
                              'other', v_reason, v_left, 'payeur inconnu', p_mode) ->> 'refund_request_id')::uuid;
  reset role;
  return q;
end $$;
create or replace function pg_temp.options(p_line uuid) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  v := pg_temp.try('01', format($q$ select public.debit_link_options(%L)::text $q$, p_line))::jsonb;
  return jsonb_build_object(
    'payments', jsonb_array_length(v -> 'payments'),
    'refunds', coalesce((select jsonb_agg(t.k order by t.k) from jsonb_array_elements(v -> 'refunds') r (x)
                         join t on t.v = (r.x ->> 'refund_request_id')::uuid and t.k in ('qa', 'qb', 'qm', 'qc')), '[]'),
    'others', (select count(*) from jsonb_array_elements(v -> 'refunds') r (x)
               where not exists (select 1 from t where t.v = (r.x ->> 'refund_request_id')::uuid
                                   and t.k in ('qa', 'qb', 'qm', 'qc'))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
create or replace function pg_temp.k1_refunds() returns void language plpgsql as $$
begin
  perform pg_temp.collect(x.n, 1000, private.paris_today() - 3, false) from unnest(array['31', '32', '33', '34']) x (n);
  insert into t select 'qa', pg_temp.rq('k1b-qa-0001', '31');
  insert into t select 'qb', pg_temp.rq('k1b-qb-0001', '32');
  insert into t select 'qat', (select transfer_id from public.refund_request where id = pg_temp.v('qa'));
  insert into t select 'qbt', (select transfer_id from public.refund_request where id = pg_temp.v('qb'));
  perform pg_temp.handed_out('fq', 'gen-file-k1b');
  insert into t select 'qm', pg_temp.rq('k1b-qm-0001', '33', 'manual');
  insert into t select 'qc', pg_temp.rq('k1b-qc-0001', '34');
  perform pg_temp.stmt('36', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 1000, 'kind', 'other_debit', 'pmt', pg_temp.pmt(pg_temp.v('qat'))),
    jsonb_build_object('amount', 1000, 'e2e', pg_temp.e2e(pg_temp.trid('r2'))),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 1000, 'orig', pg_temp.e2e(pg_temp.trid('r2')))));
end $$;
create or replace function pg_temp.sc_options_off() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.k1_refunds();
  v := jsonb_build_object('same_pmt_inf', pg_temp.pmt(pg_temp.v('qat')) = pg_temp.pmt(pg_temp.v('qbt')),
                          'batch', pg_temp.options(pg_temp.ln('36', 1)), 'rmt', pg_temp.options(pg_temp.ln('36', 2)));
  -- the M2c-6a path kept: ops link R_a to its own PmtInf's batch line (it executes R_a), then the return of an RMT debit
  -- offers no refund that came back (R_a, executed, of its amount)
  v := v || jsonb_build_object('link', pg_temp.link('k1b-link-off', pg_temp.ln('36', 1), 'refund', null,
                                                    pg_temp.v('qa'), null));
  v := v || jsonb_build_object('qa', (select status from public.refund_request where id = pg_temp.v('qa')),
                               'rmt_return', pg_temp.options(pg_temp.ln('36', 3)));
  return v;
end $$;
create or replace function pg_temp.sc_options_on() returns jsonb language plpgsql as $$
declare v_before integer; v jsonb;
begin
  perform pg_temp.k1_refunds();
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = pg_temp.v('qbt');
  select count(*) into v_before from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa', null, null, 100)
  where line_id = pg_temp.ln('36', 1);
  v := jsonb_build_object('batch', pg_temp.options(pg_temp.ln('36', 1)),
                          'link', pg_temp.refusal(pg_temp.attempt(format(
                                    $q$ select pg_temp.link('k1b-link-on', %L, 'refund', null, %L, null) $q$,
                                    pg_temp.ln('36', 1), pg_temp.v('qa')))),
                          'qa', (select status from public.refund_request where id = pg_temp.v('qa')),
                          'candidates', jsonb_build_array(v_before,
                            (select count(*) from private.bank_booking_candidates('00000000-0000-0000-0000-0000000000aa',
                                                                                   null, null, 100)
                             where line_id = pg_temp.ln('36', 1))));
  return v;
end $$;
select is(pg_temp.isolated('sc_options_off'),
          '{"same_pmt_inf": true,
            "batch": {"payments": 0, "refunds": ["qa", "qb"], "others": 0},
            "rmt": {"payments": 0, "refunds": [], "others": 0},
            "link": "refund", "qa": "executed",
            "rmt_return": {"payments": 0, "refunds": [], "others": 0}}'::jsonb,
  'debit_link_options on our lines: on a refunds PmtInf''s batch line its handed-out refunds only (no payment, no manual '
  'refund, none not filed); on an RMT debit and on its return nothing; the link of R_a to its own PmtInf still accepted');
select is(pg_temp.isolated('sc_options_on'),
          '{"batch": {"payments": 0, "refunds": [], "others": 0}, "link": "debit link refused: own_transfer_line",
            "qa": "requested", "candidates": [2, 2]}'::jsonb,
  'switch on, R_b cancelled after download and not returned: its PmtInf''s batch line offers no refund and the link of R_a '
  'is refused (own_transfer_line), the line left to the funds pass (its two members still its candidates)');

-- T3 (hardening): I20's sub-clauses, each seeded alone (rolled back)
-- a payout debit booking of a transfer still in its file (the booking without the status update)
create or replace function pg_temp.seed_payout_booking(p_n text, p_transfer uuid, p_amount bigint) returns uuid
language plpgsql as $$
declare v_entry uuid;
begin
  perform pg_temp.stmt(p_n, private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', p_amount, 'e2e', pg_temp.e2e(p_transfer))));
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id)
  select 1, '00000000-0000-0000-0000-0000000000aa', 'remittance', private.paris_today(), 'remit:seed-' || p_n,
         x.client_organization_id, 'bank_transfer', x.id::text
  from public.bank_transfer x where x.id = p_transfer;
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_payable', p_amount, 'EUR', null),
    (1, 2, 'client_money_cash', -p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cf');
  select x.entry_id into v_entry from private.ledger_post_set() x;
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method)
  values (pg_temp.ln(p_n, 1), 1, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
          'payout', p_transfer, v_entry, p_amount, 'auto');
  return v_entry;
end $$;
create or replace function pg_temp.sc_i20_in_file() returns jsonb language plpgsql as $$
begin
  perform pg_temp.seed_payout_booking('32', pg_temp.trid('r4'), 32800);
  return jsonb_build_object('status', pg_temp.status(pg_temp.trid('r4')), 'checks', pg_temp.pchecks());
end $$;
select ok((select x.v ->> 'status' = 'in_file'
                  and (x.v -> 'checks') @> jsonb_build_array(jsonb_build_array('transfer_booked_once', pg_temp.trid('r4')))
           from (select pg_temp.isolated('sc_i20_in_file') as v) x),
  'I20: a debit booking of a payout still in its file (its status never updated)');
-- an executed file-mode refund, its transfer booked with the refund's cash_out, linked 0 or 2 times (the link count arm
-- alone), and a bounced one whose bounce is not its transfer's return entry (the bounce arm alone)
create or replace function pg_temp.cash_out(p_line uuid, p_pay uuid, p_amount bigint) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, payment_id,
                                  source_type, source_id, reason)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_out', private.paris_today(), 'cash_out:' || p_line, p_pay,
          'bank_transaction', p_line::text, 'Remboursement au payeur');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'unallocated_payment', p_amount, 'EUR', null),
    (1, 2, 'client_money_cash', -p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cf');
  select x.entry_id into v from private.ledger_post_set() x;
  return v;
end $$;
create or replace function pg_temp.filed_refund(p_n text) returns uuid language plpgsql as $$
declare q uuid;
begin
  q := pg_temp.rq('t3-refund-' || p_n, '13');
  perform pg_temp.handed_out('ft3' || p_n, 'gen-file-t3-' || p_n);
  perform pg_temp.stmt(p_n, private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 1000, 'kind', 'refund_out',
                       'e2e', (select end_to_end_id from public.refund_request where id = q)),
    jsonb_build_object('amount', 1000, 'kind', 'refund_out'),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 1000,
                       'orig', (select end_to_end_id from public.refund_request where id = q))));
  return q;
end $$;
create or replace function pg_temp.link_refund(p_line uuid, p_q uuid) returns void language plpgsql as $$
begin
  perform private.debit_link_begin();
  insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, refund_request_id, method)
  values (1, p_line, 'refund', pg_temp.pay('13'), p_q, 'auto');
  perform private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
end $$;
create or replace function pg_temp.refund_checks(p_q uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'transfer', (select x.status || ':' || (x.entry_id = q.cash_out_entry_id)::text from public.bank_transfer x
                 where x.id = q.transfer_id),
    'links', (select count(*) from public.bank_debit_link l where l.refund_request_id = q.id and l.kind = 'refund'),
    'i20', pg_temp.pchecks() @> jsonb_build_array(jsonb_build_array('transfer_booked_once', q.transfer_id)))
  from public.refund_request q where q.id = p_q $$;
create or replace function pg_temp.sc_i20_refund_unlinked() returns jsonb language plpgsql as $$
declare q uuid; v_entry uuid;
begin
  q := pg_temp.filed_refund('33');
  v_entry := pg_temp.cash_out(pg_temp.ln('33', 1), pg_temp.pay('13'), 1000);
  update public.refund_request set status = 'executed', bank_transaction_id = pg_temp.ln('33', 1),
    cash_out_entry_id = v_entry, executed_on = private.paris_today()
  where id = q;
  return pg_temp.refund_checks(q);
end $$;
create or replace function pg_temp.sc_i20_refund_twice() returns jsonb language plpgsql as $$
declare q uuid;
begin
  q := pg_temp.filed_refund('34');
  perform pg_temp.link_refund(pg_temp.ln('34', 1), q);
  insert into public.bank_debit_link (bank_transaction_id, organization_id, bank_account_id, kind, payment_id,
                                      refund_request_id, cash_entry_id, method)
  values (pg_temp.ln('34', 2), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'refund',
          pg_temp.pay('13'), q, pg_temp.cash_out(pg_temp.ln('34', 2), pg_temp.pay('13'), 1000), 'auto');
  return pg_temp.refund_checks(q);
end $$;
create or replace function pg_temp.sc_i20_refund_bounce() returns jsonb language plpgsql as $$
declare q uuid; v_bounce uuid;
begin
  q := pg_temp.filed_refund('35');
  perform pg_temp.link_refund(pg_temp.ln('35', 1), q);
  update public.bank_transfer set status = 'returned', return_entry_id = pg_temp.free_entry(0)
  where id = (select transfer_id from public.refund_request where id = q);
  select x.entry_id into v_bounce
  from private.ledger_reverse((select cash_out_entry_id from public.refund_request where id = q), 'refund_bounce:t3-35',
                              'Remboursement revenu impayé', private.paris_today()) x;
  update public.refund_request set status = 'bounced', bounce_transaction_id = pg_temp.ln('35', 3),
    bounce_entry_id = v_bounce
  where id = q;
  return pg_temp.refund_checks(q) || jsonb_build_object(
    'bounce_is_return', (select q2.bounce_entry_id = x.return_entry_id from public.refund_request q2
                         join public.bank_transfer x on x.id = q2.transfer_id where q2.id = q));
end $$;
select is(array[pg_temp.isolated('sc_i20_refund_unlinked'), pg_temp.isolated('sc_i20_refund_twice')],
          array['{"transfer": "booked:true", "links": 0, "i20": true}'::jsonb,
                '{"transfer": "booked:true", "links": 2, "i20": true}'],
  'I20: an executed refund whose transfer is booked with its cash_out, linked 0 or 2 times (the link count alone)');
create or replace function pg_temp.sc_i20_refund_cash_out() returns jsonb language plpgsql as $$
declare q uuid;
begin
  q := pg_temp.filed_refund('37');
  update public.bank_transfer set status = 'booked', entry_id = pg_temp.free_entry(0)
  where id = (select transfer_id from public.refund_request where id = q);
  perform pg_temp.link_refund(pg_temp.ln('37', 1), q);
  return pg_temp.refund_checks(q);
end $$;
select is(pg_temp.isolated('sc_i20_refund_cash_out'), '{"transfer": "booked:false", "links": 1, "i20": true}'::jsonb,
  'I20: an executed refund linked once whose transfer was booked with another entry than its cash_out (the cash_out alone)');
select is(pg_temp.isolated('sc_i20_refund_bounce'),
          '{"transfer": "returned:true", "links": 1, "i20": true, "bounce_is_return": false}'::jsonb,
  'I20: a bounced refund whose bounce is not its transfer''s return entry (the bounce alone)');

-- T4 (residual): each last-line rule of post_bank_bookings' re-check fed a row only it refuses (the rows M2c-6b-2's ops path
-- sends: the job's pure rules refuse them first today). Lambert's payout (r4: in its downloaded file, its run sent, not
-- debited) and Roux's (r5: booked) are the rows' transfers; two payouts of a new downloaded file for the batch rules.
create or replace function pg_temp.r4_line(p_n text, p_amount bigint default 32800, p_e2e text default null)
returns uuid language sql as $$
  select pg_temp.stmt(p_n, private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', p_amount, 'e2e', coalesce(p_e2e, pg_temp.e2e(pg_temp.trid('r4')))))) $$;
create or replace function pg_temp.outcome(p_line uuid) returns jsonb language sql as $$
  select jsonb_build_object('why', pg_temp.skipped(p_line), 'bookings', to_jsonb(pg_temp.bookings(p_line))) $$;
-- a statement line of a second dedicated account of the servicer (another account than the transfers')
create or replace function pg_temp.other_line(p_n text, p_line jsonb) returns uuid language plpgsql as $$
declare s uuid := ('e5000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on)
  values ('80000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
          'FR7630006000011234567890189', 'TESTFRPPXXX', 'EUR', 'Fonds de tiers 2', 'camt053', '2026-01-01');
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000c2', 'EUR', 'camt053', 'o.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, original_end_to_end_id)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000c2', s, 1, 't:' || s,
          coalesce(p_line ->> 'dir', 'debit'), (p_line ->> 'amount')::bigint, 'EUR', private.paris_today(),
          coalesce(p_line ->> 'kind', 'transfer_out'), p_line ->> 'e2e', p_line ->> 'orig');
  update public.bank_statement set status = 'imported', from_date = private.paris_today(),
    to_date = private.paris_today(), opening_booked_minor = 0, closing_booked_minor = 0, counts = '{}',
    finished_at = clock_timestamp()
  where id = s;
  return s;
end $$;
-- two payouts (Cyprès 328,00 €, Durand 246,00 €) in one PmtInf of a downloaded file
create or replace function pg_temp.t4_pair() returns void language plpgsql as $$
begin
  perform pg_temp.file('21', '20000000-0000-0000-0000-0000000000a3', 40000);
  perform pg_temp.file('22', '20000000-0000-0000-0000-0000000000a7', 30000);
  perform pg_temp.collect('21', 40000, private.paris_today() - 3);
  perform pg_temp.collect('22', 30000, private.paris_today() - 3);
  insert into t select 'ra', pg_temp.runk('a3', '{"21": "40000"}', 7200, 1200, 't4-a');
  insert into t select 'rb', pg_temp.runk('a7', '{"22": "30000"}', 5400, 900, 't4-b');
  insert into t select 'ta', pg_temp.trid('ra');
  insert into t select 'tb', pg_temp.trid('rb');
  perform pg_temp.handed_out('ft4', 'gen-file-t4');
end $$;
create or replace function pg_temp.t4_batch(p_n text, p_amount bigint, p_rows text[]) returns jsonb
language plpgsql as $$
begin
  perform pg_temp.stmt(p_n, private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', p_amount, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(pg_temp.v('ta')))));
  perform pg_temp.book((select jsonb_agg(pg_temp.row(pg_temp.ln(p_n, 1), 'payout', pg_temp.v(r)) order by r)
                        from unnest(p_rows) r));
  return pg_temp.outcome(pg_temp.ln(p_n, 1));
end $$;
-- a transfer put in the t4 file's payouts PmtInf by an item (as no API writes it: the rule's own input)
create or replace function pg_temp.t4_item(p_transfer uuid) returns void language sql as $$
  insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id, pmt_inf_id, execution_date)
  select i.file_id, 99, p_transfer, i.organization_id, i.pmt_inf_id, i.execution_date
  from public.transfer_file_item i where i.file_id = pg_temp.v('ft4') and i.transfer_id = pg_temp.v('ta') $$;
create or replace function pg_temp.sc_t4_run() returns jsonb language plpgsql as $$
begin
  update public.remittance_run set status = 'booked', booked_on = private.paris_today() where id = pg_temp.v('r4');
  perform pg_temp.r4_line('40');
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('40', 1), 'payout', pg_temp.trid('r4'))));
  return pg_temp.outcome(pg_temp.ln('40', 1));
end $$;
create or replace function pg_temp.sc_t4_not_its_line() returns jsonb language plpgsql as $$
begin
  perform pg_temp.r4_line('41', 32800, pg_temp.e2e(pg_temp.v('t9')));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('41', 1), 'payout', pg_temp.trid('r4'))));
  return pg_temp.outcome(pg_temp.ln('41', 1));
end $$;
create or replace function pg_temp.sc_t4_return_not_its_line() returns jsonb language plpgsql as $$
begin
  perform pg_temp.stmt('42', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 32800, 'orig', pg_temp.e2e(pg_temp.v('t9')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('42', 1), 'payout_returned', pg_temp.trid('r5'))));
  return pg_temp.outcome(pg_temp.ln('42', 1));
end $$;
create or replace function pg_temp.sc_t4_one_kind() returns jsonb language plpgsql as $$
begin
  perform pg_temp.r4_line('43');
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('43', 1), 'payout', pg_temp.trid('r4')),
                                         pg_temp.row(pg_temp.ln('43', 1), 'fee')));
  return pg_temp.outcome(pg_temp.ln('43', 1));
end $$;
create or replace function pg_temp.sc_t4_mixed() returns jsonb language plpgsql as $$
declare q uuid; v_tr uuid;
begin
  perform pg_temp.t4_pair();
  q := pg_temp.rq('t4-mixed-0001', '13');
  v_tr := (select transfer_id from public.refund_request where id = q);
  update public.bank_transfer set status = 'in_file', transfer_file_id = pg_temp.v('ft4') where id = v_tr;
  perform pg_temp.t4_item(v_tr);
  return pg_temp.t4_batch('44', 32800 + 24600 + 1000, array['ta', 'tb']);
end $$;
create or replace function pg_temp.sc_t4_partial() returns jsonb language plpgsql as $$
begin
  perform pg_temp.t4_pair();
  return pg_temp.t4_batch('45', 32800, array['ta', 'tb']);
end $$;
create or replace function pg_temp.sc_t4_incomplete() returns jsonb language plpgsql as $$
begin
  perform pg_temp.t4_pair();
  return pg_temp.t4_batch('46', 32800 + 24600, array['ta']);
end $$;
create or replace function pg_temp.sc_t4_current_file() returns jsonb language plpgsql as $$
begin
  perform pg_temp.t4_pair();
  perform pg_temp.t4_item(pg_temp.trid('r4'));   -- r4 is in its own file f5: never a member of this PmtInf
  return pg_temp.t4_batch('47', 32800 + 24600, array['ta', 'tb']);
end $$;
create or replace function pg_temp.sc_t4_account() returns jsonb language plpgsql as $$
begin
  perform pg_temp.other_line('48', jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(pg_temp.trid('r4'))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row('e5000000-0000-0000-0000-000000000048', 'payout',
                                                     pg_temp.trid('r4'))));
  return pg_temp.outcome('e5000000-0000-0000-0000-000000000048');
end $$;
create or replace function pg_temp.sc_t4_amount() returns jsonb language plpgsql as $$
begin
  perform pg_temp.r4_line('49', 32801);
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('49', 1), 'payout', pg_temp.trid('r4'))));
  return pg_temp.outcome(pg_temp.ln('49', 1));
end $$;
create or replace function pg_temp.sc_t4_return_larger() returns jsonb language plpgsql as $$
begin
  perform pg_temp.stmt('50', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 32801, 'orig', pg_temp.e2e(pg_temp.trid('r5')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('50', 1), 'payout_returned', pg_temp.trid('r5'))));
  return pg_temp.outcome(pg_temp.ln('50', 1));
end $$;
create or replace function pg_temp.sc_t4_return_account() returns jsonb language plpgsql as $$
begin
  perform pg_temp.other_line('51', jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 32800,
                                                    'orig', pg_temp.e2e(pg_temp.trid('r5'))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row('e5000000-0000-0000-0000-000000000051', 'payout_returned',
                                                     pg_temp.trid('r5'))));
  return pg_temp.outcome('e5000000-0000-0000-0000-000000000051');
end $$;
create or replace function pg_temp.sc_t4_twice() returns jsonb language plpgsql as $$
begin
  perform pg_temp.stmt('52', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(pg_temp.trid('r4'))),
    jsonb_build_object('amount', 32800, 'e2e', pg_temp.e2e(pg_temp.trid('r4')))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('52', 1), 'payout', pg_temp.trid('r4')),
                                         pg_temp.row(pg_temp.ln('52', 2), 'payout', pg_temp.trid('r4'))));
  return jsonb_build_object('first', pg_temp.outcome(pg_temp.ln('52', 1)), 'second', pg_temp.outcome(pg_temp.ln('52', 2)));
end $$;
create or replace function pg_temp.sc_t4_debit_booked() returns jsonb language plpgsql as $$
begin
  perform pg_temp.seed_payout_booking('53', pg_temp.trid('r4'), 32800);
  perform pg_temp.r4_line('54');
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('54', 1), 'payout', pg_temp.trid('r4'))));
  return pg_temp.outcome(pg_temp.ln('54', 1));
end $$;
create or replace function pg_temp.sc_t4_review_replaced() returns jsonb language plpgsql as $$
declare v_before text;
begin
  perform pg_temp.r4_line('55');
  perform pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.ln('55', 1),
                                                                  'reason', 'batch_partial')));
  v_before := pg_temp.review(pg_temp.ln('55', 1));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.ln('55', 1), 'payout', pg_temp.trid('r4'))));
  return pg_temp.outcome(pg_temp.ln('55', 1)) || jsonb_build_object('before', v_before,
                                                                     'after', pg_temp.review(pg_temp.ln('55', 1)));
end $$;
select is(pg_temp.isolated('sc_t4_run'), '{"why": "run_not_in_flight", "bookings": []}'::jsonb,
  'T4: the debit of a payout whose run is no longer in flight (booked): run_not_in_flight');
select is(pg_temp.isolated('sc_t4_not_its_line'), '{"why": "not_its_line", "bookings": []}'::jsonb,
  'T4: a row naming a payout for a debit carrying another transfer''s id: not_its_line');
select is(pg_temp.isolated('sc_t4_return_not_its_line'), '{"why": "not_its_line", "bookings": []}'::jsonb,
  'T4: a row naming a booked payout for a credit returning another transfer: not_its_line');
select is(pg_temp.isolated('sc_t4_one_kind'), '{"why": "bad_request", "bookings": []}'::jsonb,
  'T4: a payout''s debit line given a second kind of row (a fee): bad_request, the line one kind of booking');
select is(pg_temp.isolated('sc_t4_mixed'), '{"why": "batch_mixed", "bookings": []}'::jsonb,
  'T4: a batch line of a PmtInf holding a payout and a refund in its file: batch_mixed');
select is(pg_temp.isolated('sc_t4_partial'), '{"why": "batch_partial", "bookings": []}'::jsonb,
  'T4: a batch line of one member''s amount, rows for both members: batch_partial');
select is(pg_temp.isolated('sc_t4_incomplete'), '{"why": "batch_incomplete", "bookings": []}'::jsonb,
  'T4: a batch line of both members'' sum, a row for one: batch_incomplete');
select is(pg_temp.isolated('sc_t4_current_file'),
          '{"why": null, "bookings": ["1 payout 32800", "2 payout 24600"]}'::jsonb,
  'T4: an item naming the PmtInf for a transfer whose current file is another counts no member: the line booked');
select is(pg_temp.isolated('sc_t4_account'), '{"why": "transfer_differs", "bookings": []}'::jsonb,
  'T4: a payout''s id and amount on another dedicated account''s statement: transfer_differs');
select is(pg_temp.isolated('sc_t4_amount'), '{"why": "transfer_differs", "bookings": []}'::jsonb,
  'T4: a payout''s id for another amount: transfer_differs');
select is(pg_temp.isolated('sc_t4_return_larger'), '{"why": "return_differs", "bookings": []}'::jsonb,
  'T4: a return larger than the payout: return_differs');
select is(pg_temp.isolated('sc_t4_return_account'), '{"why": "transfer_differs", "bookings": []}'::jsonb,
  'T4: a payout''s return credited to another dedicated account: transfer_differs');
select is(pg_temp.isolated('sc_t4_twice'),
          '{"first": {"why": null, "bookings": ["1 payout 32800"]}, "second": {"why": "transfer_twice", "bookings": []}}'::jsonb,
  'T4: two debits of one payout in one call: the first booked, the second transfer_twice');
select is(pg_temp.isolated('sc_t4_debit_booked'), '{"why": "transfer_debited_twice", "bookings": []}'::jsonb,
  'T4: a payout still in its file with a debit booking already: transfer_debited_twice');
select is(pg_temp.isolated('sc_t4_review_replaced'),
          '{"why": null, "bookings": ["1 payout 32800"], "before": "batch_partial", "after": null}'::jsonb,
  'T4: a line left to ops then booked: its review deleted');

select * from finish();
rollback;
