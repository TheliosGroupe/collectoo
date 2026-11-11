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
-- Cancellation after download stays off (033 and 034 unchanged); one scenario switches it on in its own subtransaction.
begin;
select plan(70);


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


-- 1. Individual debits: the payouts' RMT ids and the sweep's SWP id ---------------------------------------------------
select pg_temp.handed_out('f1', 'gen-file-1');
select is(array[pg_temp.pmt(pg_temp.trid('r1')), pg_temp.pmt(pg_temp.trid('r2')),
                pg_temp.pmt((pg_temp.sweep(pg_temp.v('f1'))).id)],
          array[(pg_temp.fl(pg_temp.v('f1'))).number || '-1', (pg_temp.fl(pg_temp.v('f1'))).number || '-1',
                (pg_temp.fl(pg_temp.v('f1'))).number || '-2'],
  'one PmtInf per kind: the payouts in -1, the sweep in -2 (as M2c-6a numbered such a file)');
select is((pg_temp.sweep(pg_temp.v('f1'))).amount_minor, 12000::bigint, 'F1 sweeps Cyprès'' settled 120,00 €');
insert into t select 's1', (pg_temp.sweep(pg_temp.v('f1'))).id;
select pg_temp.stmt('01', private.paris_today(), jsonb_build_array(
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
  $$ values ('client_settlement'::text, private.paris_today(), 'remittance_run'::text, pg_temp.v('r1')::text),
            ('remittance', private.paris_today(), 'bank_transfer', pg_temp.trid('r1')::text),
            ('servicer_sweep', private.paris_today(), 'bank_transfer', pg_temp.v('s1')::text) $$,
  'the remittance, the run''s settlement and the sweep, dated at the debit, each naming its document');
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
  $$ values ('booked'::text, private.paris_today()), ('booked', private.paris_today()) $$,
  'runs sent → booked at the debit date');
select results_eq(
  $$ select kind, amount_minor, vat_moved_minor, settled_on, entry_id = pg_temp.ek('settle:' || run_id)
     from public.commission_settlement where run_id = pg_temp.v('r1') $$,
  $$ values ('compensation'::text, 36000::bigint, 6000::bigint, private.paris_today(), true) $$,
  'the invoice set off at the debit (commission_settlement of the settlement entry)');
select is(array[pg_temp.owed('a1'), pg_temp.owed('a2'), pg_temp.share()], array[0, 0, -128160]::bigint[],
  'Martin and Lilas owed nothing; the servicer''s settled share (360,00 + 921,60 €) on the account, Cyprès'' swept');
select is((select count(*) from public.client_advance)::integer, 0, 'no cover needed: no advance');
select is(pg_temp.dirty(), '{}'::text[], 'I8′, I12, I13, I14, I19, I20 and I9 clean after the individual debits');
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
  $$ select client_organization_id, status from public.client_payout_account
     where client_organization_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a6')
     order by client_organization_id $$,
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid, 'returned'::text),
            ('00000000-0000-0000-0000-0000000000a6', 'returned') $$,
  'the payout accounts returned (they block payouts until replaced or reconfirmed)');
select ok('payout_account_returned' = any (private.remittance_payout_blockers('00000000-0000-0000-0000-0000000000a1', 'EUR',
                                                                               private.paris_today())),
  'Martin''s next payout is blocked: payout_account_returned');
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
          array['debit link refused: not_explainable', 'debit link refused: not_explainable'],
  '« explained » refused on a debit carrying our RMT id and on a batch line of our file');
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
select pg_temp.stmt('06', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 82000, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(pg_temp.trid('r8')))));
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
                         (pg_temp.f('05'), private.paris_today() - 1), (pg_temp.f('11'), private.paris_today() + 5);
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
  'at the debit: a breach row for the item debited after its date, none for the one on time');


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

select * from finish();
rollback;
