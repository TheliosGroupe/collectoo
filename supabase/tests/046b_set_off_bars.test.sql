-- M2c-7d-2 « set-off bars » (plan docs/design/m2c-7-plan.md §6.2.2, §6.2.4–§6.2.6, §6.2.9, §6.2.11 with the withheld kind
-- and every redefinition it needs, §6.3's set_off_after_bar, §6.6 046b; ADR-0014 « M2c-7d-2 »). Every rule the law does
-- not fix is the servicer's default (founder Q9, Q11, Q12, Q17–Q19; OQ-41, OQ-91, OQ-92).
--   b     the bars (§6.2.2, §6.2.4–§6.2.6): the opening (a liquidation recorded alone opens it), each claim's birth
--         (an invoice by the earliest collection it charges, a corrective invoice by its period, an advance by its
--         birth), client_set_off_barred per kind and day (liquidation, mandate end, a standing seizure, an advance
--         while a proceeding stands), document_before_opening on the birth (not the issue date), document_nettable,
--         document_client_payable (an advance while a proceeding stands: gap 11);
--   r     how an advance is recovered (carried from 7c-1: the claw-back read the proceeding only): a liquidation
--         recorded alone or a proceeding bars every advance, a mandate end or a seizure turns a clause into a request;
--   q     the request refused in_proceeding (an advance born after the opening, L4); the default order of a client's
--         payment skips such an advance and a designated payment of it is held for the procedure (gap 11);
--   a     the approval (§6.2.9): a standing seizure refuses an N = 0 run whatever N (L14; 046a sp9's pin changed),
--         released it passes, two seizures one released still refuse; client_status_changed when the opening (a
--         liquidation alone too) or the bars differ from the draft's, or when the plan sets off a document barred
--         today (the run's own new invoice born before the opening, L1 — review round 1, MLAW-1: its repriced lines
--         counted); the prepare's due invoice issued with its payment note (TUI-4); the same bars passing;
--   h     the hold before download (§6.2.11 (b)): a payout whose run sets off what is barred today is held
--         client_status_changed;
--   w     ([check 1] gap 1) the withholding at the debit, switch off and on: (i) a pre-opening invoice and an advance
--         withheld, the post-opening invoice set off (two entries, the reversal, the withheld item, the ledger, the
--         invariants); (ii) the whole plan barred; (iii) a refund settle larger than the allowed invoices: the whole
--         plan withheld; (iv) the next run carries W (its line, outside every mandate, no commission, its deadline the
--         withheld run's) and its debit pays it; (v) LG003 still raised for every other reversal; (vi) a barred
--         settlement without its reversal fails the commit check; the client's members read the pair, no one else;
--         (review round 1) the run page's read names the barred parts and the refund not paid (TUI-2), the run giving
--         W back only once booked (MLAW-4, TUI-3); the « Lier » preview says what the debit sets off and withholds
--         (MLAW-2); a run id naming no run shifts no other run's gate (CC-4);
--   s     ([check 2] gap 3) the schedule's candidates: a withheld item alone, with a returned payout; the run's trigger;
--   n     the nightly's set_off_after_bar (an event recorded after the debit; a withheld run never listed; review
--         round 1, MLAW-3: a set-off made before a mandate's end was recorded, barred by that end alone, is valid —
--         C. civ. 2008 — and not listed) and the full list of codes;
--   c     the privileges of the new functions.
-- Each scenario runs in its own rolled-back subtransaction; the ones that touch payouts run with the switch off and on
-- (pg_temp.iso(…, true)) — no 7d-2 rule reads it — and a guard at the end checks it is off.
begin;
select plan(29);

-- Fixtures and helpers (045's, copied: 044's, 037's fixture, 035's, 043's and 045's helpers) ----------------------------
-- Fixtures and helpers (044's, copied: 037's fixture, 035's, 043's and 044's helpers) -----------------------------------

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
select ('d0000000-0000-0000-0000-000000000' || x.n || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa'::uuid,
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
-- (review 6b-2c money-3) and the items of an account whose mandate's delay cannot be met (`unmeetable_acct`: the job
-- marks them unmeetable, held to one month after their collection)
create temporary table unmeetable_acct (account_id uuid primary key) on commit drop;
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
  update private.remittance_draft_line l set unmeetable = true
  from unmeetable_acct u where l.run_id = p_run and l.account_id = u.account_id;
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
    'unmeetable', (select count(*) from private.remittance_draft_line where run_id = p_run and unmeetable),
    'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
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
-- [{dir, kind, amount, e2e, orig, pmt, iban, code, unsplit}]: opened with the ledger cash, closed with it moved by the
-- lines (review round 6: `unsplit`, a line read from an entry kept unsplit and how many of its details are ours)
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
                                       original_end_to_end_id, counterparty_iban, bank_tx_code, batch_entry_ref,
                                       unsplit_ours)
  select pg_temp.ln(p_n, l.ord::integer), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
         s, l.ord, 't:' || s || l.ord, coalesce(l.v ->> 'dir', 'debit'), (l.v ->> 'amount')::bigint, 'EUR', p_day,
         coalesce(l.v ->> 'kind', 'transfer_out'), l.v ->> 'e2e', l.v ->> 'pmt', l.v ->> 'orig', l.v ->> 'iban',
         l.v ->> 'code', case when l.v ? 'unsplit' then 'E-' || s || '-' || l.ord end, (l.v ->> 'unsplit')::smallint
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



-- 037's own helpers ---------------------------------------------------------------------------------------------------
-- an imported camt.053 of an account (the dedicated one by default) for p_day with its lines [{dir, kind, amount, e2e,
-- orig, pmt, iban, unsplit, details, count, nb, charges, read}], opened with the ledger cash and closed with it moved:
-- line k of statement n is pg_temp.l2(n, k) (n up to 6 hex digits)
create or replace function pg_temp.l2(p_n text, p_k integer) returns uuid language sql as $$
  select ('e4' || lpad(p_n, 6, '0') || '-0000-0000-0001-' || lpad(p_k::text, 12, '0'))::uuid $$;
create or replace function pg_temp.stmt2(p_n text, p_day date, p_lines jsonb,
                                         p_account uuid default '80000000-0000-0000-0000-0000000000cf')
returns uuid language plpgsql as $$
declare
  s uuid := ('e4' || lpad(p_n, 6, '0') || '-0000-0000-0000-000000000000')::uuid;
  v_open bigint := case when p_account = '80000000-0000-0000-0000-0000000000cf'
                        then pg_temp.cash() + (select u.minor from private.bank_unposted(
                                                 '80000000-0000-0000-0000-0000000000cf', 'infinity'::date) u)
                        else 0 end;
  v_close bigint;
begin
  select v_open + coalesce(sum(case coalesce(l.v ->> 'dir', 'debit') when 'credit' then 1 else -1 end
                               * (l.v ->> 'amount')::bigint), 0)
  into v_close from jsonb_array_elements(p_lines) l (v);
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', p_account, 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                       original_end_to_end_id, counterparty_iban, batch_entry_ref, unsplit_ours,
                                       unsplit_details, unsplit_detail_count, unsplit_batch_count, charges_minor,
                                       charges_read)
  select pg_temp.l2(p_n, l.ord::integer), '00000000-0000-0000-0000-0000000000aa', p_account, s, l.ord,
         't:' || s || l.ord, coalesce(l.v ->> 'dir', 'debit'), (l.v ->> 'amount')::bigint, 'EUR', p_day,
         coalesce(l.v ->> 'kind', 'transfer_out'), l.v ->> 'e2e', l.v ->> 'pmt', l.v ->> 'orig', l.v ->> 'iban',
         case when l.v ? 'unsplit' then 'E-' || s || '-' || l.ord end, (l.v ->> 'unsplit')::smallint, l.v -> 'details',
         (l.v ->> 'count')::integer, (l.v ->> 'nb')::integer, (l.v ->> 'charges')::bigint, (l.v ->> 'read')::boolean
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  update public.bank_statement set status = 'imported', from_date = p_day, to_date = p_day,
    opening_booked_minor = v_open, closing_booked_minor = v_close, counts = '{}', finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object('from_date', p_day, 'to_date', p_day, 'covers_from', p_day,
                                                    'covers_to', p_day, 'opening_minor', v_open::text,
                                                    'closing_minor', v_close::text, 'created_at', now()))
  where id = s;
  return s;
end $$;
-- a part, as the sheets send it
create or replace function pg_temp.pt(p_kind text, p_transfer uuid, p_amount bigint, p_client uuid default null,
                                      p_returns uuid default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('kind', p_kind, 'transfer_id', p_transfer, 'client_id', p_client,
                                              'returns_line_id', p_returns, 'amount', p_amount::text)) $$;
create or replace function pg_temp.pv(p_line uuid, p_parts jsonb, p_user text default '01', p_aal text default 'aal2')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.transfer_line_preview(p_line, p_parts);
  reset role;
  return v;
end $$;
create or replace function pg_temp.op(p_line uuid, p_user text default '01', p_aal text default 'aal2')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.transfer_line_options(p_line);
  reset role;
  return v;
end $$;
-- the parts the options propose for a line (its first proposal's request)
create or replace function pg_temp.prop(p_line uuid) returns jsonb language sql as $$
  select pg_temp.op(p_line) -> 'proposals' -> 0 -> 'request' $$;
-- « Comptabiliser » by ops (user 01 by default) with the preview's text (as the sheet sends it)
create or replace function pg_temp.bk(p_line uuid, p_parts jsonb, p_key text default null, p_user text default '01',
                                      p_text text default null, p_reason text default 'motif de test',
                                      p_aal text default 'aal2') returns jsonb language plpgsql as $$
declare v jsonb; v_text text := p_text;
begin
  if v_text is null then
    v_text := coalesce(pg_temp.pv(p_line, p_parts) ->> 'expected_text', 'none');
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  v := public.book_transfer_line(coalesce(p_key, 'bk-' || md5(p_line::text || coalesce(p_parts::text, ''))), p_line,
                                 p_parts, v_text, p_reason);
  reset role;
  return v;
end $$;
-- the same, its refusal's code (or ok), its effects kept only when it books
create or replace function pg_temp.bkx(p_line uuid, p_parts jsonb, p_key text default null, p_user text default '01',
                                       p_text text default null, p_reason text default 'motif de test',
                                       p_aal text default 'aal2') returns text language plpgsql as $$
begin
  perform pg_temp.bk(p_line, p_parts, p_key, p_user, p_text, p_reason, p_aal);
  return 'ok';
exception when others then
  return regexp_replace(sqlerrm, '^transfer line booking refused: ', '');
end $$;
-- the preview's refusal (or ok)
create or replace function pg_temp.why(p_line uuid, p_parts jsonb) returns text language sql as $$
  select coalesce(pg_temp.pv(p_line, p_parts) ->> 'why', 'ok') $$;
-- a payout in flight: client c's collection n of p_amount (three days ago), its run (its commission set off: N = 82 %),
-- the file generated and handed out (every ordered payout and the sweep in it); returns the payout
create or replace function pg_temp.inflight(p_c text, p_n text, p_amount bigint, p_key text) returns uuid
language plpgsql as $$
declare v_run uuid; v_file uuid;
begin
  perform pg_temp.queued(p_c, p_n, p_amount, p_key);
  v_file := (pg_temp.gen('01', 'gen-' || p_key) ->> 'file_id')::uuid;
  insert into t values ('file-' || p_key, v_file) on conflict (k) do update set v = excluded.v;
  perform pg_temp.write(v_file);
  perform pg_temp.download('01', v_file);
  return pg_temp.v('tr-' || p_key);
end $$;
-- the same up to the approval (the payout ordered, in no file)
create or replace function pg_temp.queued(p_c text, p_n text, p_amount bigint, p_key text) returns uuid
language plpgsql as $$
declare v_run uuid;
begin
  perform pg_temp.file(p_n, ('20000000-0000-0000-0000-0000000000' || p_c)::uuid, p_amount);
  perform pg_temp.collect(p_n, p_amount, private.paris_today() - 3);
  v_run := pg_temp.runk(p_c, jsonb_build_object(p_n, p_amount::text), p_amount * 18 / 100, p_amount * 3 / 100, p_key);
  insert into t values ('run-' || p_key, v_run) on conflict (k) do update set v = excluded.v;
  insert into t values ('tr-' || p_key, (select transfer_id from public.remittance_run where id = v_run))
  on conflict (k) do update set v = excluded.v;
  return pg_temp.v('tr-' || p_key);
end $$;
-- (test only) the items of a file executed on p_day: its execution dates moved back (files generated today execute on
-- the next business day after the account's cut-off, and a statement line is never dated in the future)
create or replace function pg_temp.exec_on(p_file uuid, p_day date) returns void language plpgsql as $$
begin
  alter table public.transfer_file_item disable trigger transfer_file_item_append_only;
  update public.transfer_file_item set execution_date = p_day where file_id = p_file;
  alter table public.transfer_file_item enable always trigger transfer_file_item_append_only;
end $$;
-- a client's waiting queue (its pending items, reserved or not), its returned-payout items, its payout account
create or replace function pg_temp.queued_minor(p_c text) returns bigint language sql as $$
  select coalesce(sum(q.amount_minor), 0)::bigint from private.remittance_pending q
  where q.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.returned_items(p_c text) returns bigint language sql as $$
  select count(*) from private.remittance_pending q
  where q.client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid and q.kind = 'payout_returned' $$;
create or replace function pg_temp.payout_account(p_c text) returns text language sql as $$
  select status from public.client_payout_account
  where client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid order by created_at limit 1 $$;
create or replace function pg_temp.iban(p_c text) returns text language sql as $$
  select iban from public.client_payout_account
  where client_organization_id = ('00000000-0000-0000-0000-0000000000' || p_c)::uuid order by created_at limit 1 $$;
create or replace function pg_temp.c(p_c text) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.amt(p_transfer uuid) returns bigint language sql as $$
  select amount_minor from public.bank_transfer where id = p_transfer $$;
-- a line's bookings, its entries' keys
create or replace function pg_temp.keys(p_line uuid) returns text[] language sql as $$
  select coalesce(array_agg(regexp_replace(e.idempotency_key, '[0-9a-f-]{36}', '·', 'g') order by k.seq), '{}')
  from public.bank_line_booking k join public.ledger_entry e on e.id = k.entry_id
  where k.bank_transaction_id = p_line $$;
-- the advance and pending rows an unplanned booking of line p_line posted
create or replace function pg_temp.unplanned_rows(p_line uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'entries', (select jsonb_agg(e.entry_type || ':' || regexp_replace(e.idempotency_key, '[0-9a-f-]{36}', '·', 'g')
                                 order by e.idempotency_key)
                from public.ledger_entry e
                where e.organization_id = '00000000-0000-0000-0000-0000000000aa'
                  and (e.idempotency_key like 'remit:line:' || p_line || ':%'
                       or e.idempotency_key like 'adv:line:' || p_line || ':%')),
    'pending', (select jsonb_agg(q.kind || ':' || q.amount_minor order by q.kind)
                from private.remittance_pending q
                join public.ledger_entry e on e.id = q.ledger_entry_id
                where e.idempotency_key like 'remit:line:' || p_line || ':%'
                   or e.idempotency_key like 'adv:line:' || p_line || ':%'),
    'advance', (select jsonb_agg(a.cause || ':' || a.amount_minor) from public.client_advance a
                where a.bank_transaction_id = p_line)) $$;
-- the funds pass messages queued (process_debits with funds_after)
create or replace function pg_temp.funds_msgs() returns bigint language sql as $$
  select count(*) from pgmq.q_payments m
  where m.message ->> 'type' = 'process_debits' and m.message ? 'funds_after' and m.message -> 'funds_after' = 'null' $$;
-- (review CSR-2) whether this session holds the one-bigint advisory lock of key k, as pg_advisory_xact_lock(bigint) takes
-- it (pg_locks: classid the high 32 bits, objid the low 32 bits, objsubid 1)
create or replace function pg_temp.holds_advisory(p_key bigint) returns boolean language sql as $$
  select exists (select 1 from pg_locks k where k.locktype = 'advisory' and k.pid = pg_backend_pid() and k.granted
                   and k.objsubid = 1 and k.classid = ((p_key >> 32) & 4294967295)::text::oid
                   and k.objid = (p_key & 4294967295)::text::oid) $$;
-- a client's returned payout account retired and its IBAN confirmed again (as a client who gives its RIB again after the
-- return: the payout_account_returned blocker lifts)
create or replace function pg_temp.reconfirm(p_c text) returns void language plpgsql as $$
begin
  update public.client_payout_account set status = 'retired', closed_by = '10000000-0000-0000-0000-000000000001',
    closed_at = now(), closed_reason = 'Reconfirmé après le retour du virement (test)'
  where client_organization_id = pg_temp.c(p_c) and status = 'returned';
  insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                            evidence_document_id, proposed_by)
  select gen_random_uuid(), a.organization_id, a.client_organization_id, a.currency, a.iban, a.holder_name,
         a.evidence_document_id, '10000000-0000-0000-0000-000000000004'
  from public.client_payout_account a where a.client_organization_id = pg_temp.c(p_c)
  order by a.created_at limit 1;
  update public.client_payout_account set status = 'active', confirmed_at = now(), confirmed_via = 'second_admin',
    confirmed_by = '10000000-0000-0000-0000-000000000001'
  where client_organization_id = pg_temp.c(p_c) and confirmed_at is null;
end $$;
-- a part's facts in a preview: [kind, paid, advance, bound]
create or replace function pg_temp.pp(p_preview jsonb, p_n integer default 0) returns jsonb language sql as $$
  select jsonb_build_array(p_preview -> 'parts' -> p_n ->> 'kind', p_preview -> 'parts' -> p_n ->> 'paid_minor',
                           p_preview -> 'parts' -> p_n ->> 'advance_minor', p_preview -> 'parts' -> p_n ->> 'p_bound') $$;
grant execute on all functions in schema pg_temp to authenticated;


-- (037's plain prepare and approval, its cancellation helpers)
create or replace function pg_temp.prepare_plain(p_run uuid) returns integer language plpgsql as $$
declare r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         pf.mandate_id, case when pf.mandate_id is not null
                             then ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid end,
         e.payment_id, e.effective_date, e.effective_date, q.posted_at,
         case when q.amount_minor > 0 then e.effective_date + 30 end,
         case when q.amount_minor > 0 then e.effective_date + 27 end, q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text), 0, 'none', '[]', false
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  left join public.account a on a.id = e.account_id
  left join public.portfolio pf on pf.id = a.portfolio_id
  where q.draft_run_id = p_run;
  -- (M2c-7b) an advance's item on its advance's mandate, as the job reads it (the line insert guard checks it)
  update private.remittance_draft_line l set mandate_id = ca.mandate_id
  from public.ledger_entry e, public.client_advance ca
  where l.run_id = p_run and l.kind in ('client_advance', 'client_advance_reversal') and e.id = l.ledger_entry_id
    and ca.entry_id = case l.kind when 'client_advance' then e.id else e.reverses_entry_id end;
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', (select sum(amount_minor)::text from private.remittance_draft_line where run_id = p_run),
    'invoice_ht', '0', 'invoice_vat', '0', 'invoice_ttc', '0', 'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0',
    'taken', '0', 'advances', '0', 'refunds', '0', 'settlement', '0',
    'net', (select sum(amount_minor)::text from private.remittance_draft_line where run_id = p_run), 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || 'plain', 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', '[]'::jsonb, 'key_states', '[]'::jsonb,
    'plan', '{"settles": [], "net": "0", "settlement": "0", "dc": "0", "da": "0", "vat_moved": "0", "deferred": true}'));
  return (select version from public.remittance_run where id = p_run);
end $$;
create or replace function pg_temp.approve_plain(p_run uuid, p_key text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs('ap-' || p_key, pg_temp.item(p_run));
  reset role;
  v := private.approve_remittance_run(p_run, (select job_token from public.remittance_run where id = p_run)) ->> 'status';
  return coalesce(v, '?') || ':' || (select status from public.remittance_run where id = p_run);
end $$;
create or replace function pg_temp.request(p_c text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := (public.request_remittance_run('rq-' || p_key, pg_temp.c(p_c)) ->> 'run_id')::uuid;
  reset role;
  return v;
end $$;
create or replace function pg_temp.cancel_run(p_run uuid, p_key text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user('04');
  set local role authenticated;
  v := public.cancel_remittance_run('cancel-' || p_key, p_run, (select version from public.remittance_run where id = p_run),
                                    'annulé (test)') ->> 'status';
  reset role;
  return v;
end $$;
-- a payout cancelled after its file was handed out (the switch on, as 6b-3 will do it), its run cancelled
create or replace function pg_temp.cancelled_late(p_c text, p_n text, p_amount bigint, p_key text,
                                                  p_cancel_run boolean default true) returns uuid language plpgsql as $$
declare v_t uuid;
begin
  v_t := pg_temp.inflight(p_c, p_n, p_amount, p_key);
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_t;
  if p_cancel_run then
    perform pg_temp.cancel_run(pg_temp.v('run-' || p_key), p_key);
  end if;
  return v_t;
end $$;

-- 043's own helpers -----------------------------------------------------------------------------------------------------
-- another servicer's admin (06): the full check's refusal
insert into auth.users (id, email, aud, role)
values ('10000000-0000-0000-0000-000000000006', 'u06@book.test', 'authenticated', 'authenticated');
insert into public.membership (user_id, organization_id, role)
values ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000bb', 'admin');
create or replace function pg_temp.pf(p_c text) returns uuid language sql as $$
  select ('20000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.mandate(p_c text) returns uuid language sql as $$
  select ('70000000-0000-0000-0000-0000000000' || p_c)::uuid $$;
create or replace function pg_temp.alloc(p_n text) returns uuid language sql as $$
  select id from public.ledger_entry where payment_id = pg_temp.pay(p_n) and entry_type = 'allocation'
  order by posted_at, id limit 1 $$;
create or replace function pg_temp.rev(p_entry uuid) returns uuid language sql as $$
  select id from public.ledger_entry where reverses_entry_id = p_entry $$;
create or replace function pg_temp.adv_of(p_r uuid) returns public.client_advance language sql as $$
  select a.* from public.client_advance a where a.cause_entry_id = p_r order by a.created_at, a.id limit 1 $$;
-- a client's advances [cause:amount] (in a fixed order), and those whose entry is not reversed
create or replace function pg_temp.advs(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(a.cause || ':' || a.amount_minor order by a.cause, a.amount_minor desc), '[]')
  from public.client_advance a where a.client_organization_id = pg_temp.c(p_c) $$;
create or replace function pg_temp.live_advs(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(a.cause || ':' || a.amount_minor order by a.cause, a.amount_minor desc), '[]')
  from public.client_advance a where a.client_organization_id = pg_temp.c(p_c)
    and not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = a.entry_id) $$;
-- a client's pending queue [kind:amount] and its total
create or replace function pg_temp.queue(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(q.kind || ':' || q.amount_minor order by q.kind, q.amount_minor), '[]')
  from private.remittance_pending q where q.client_organization_id = pg_temp.c(p_c) $$;
-- a book of the servicer (a client's when p_c is given) as of p_on
create or replace function pg_temp.bal(p_book text, p_c text, p_on date) returns bigint language sql as $$
  select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_posting p
  join public.ledger_account la on la.id = p.ledger_account_id
  where la.organization_id = '00000000-0000-0000-0000-0000000000aa' and la.book = p_book
    and (p_c is null or la.client_organization_id = pg_temp.c(p_c)) and p.effective_date <= p_on $$;
create or replace function pg_temp.edate(p_entry uuid) returns date language sql as $$
  select effective_date from public.ledger_entry where id = p_entry $$;
create or replace function pg_temp.ekey(p_entry uuid) returns text language sql as $$
  select idempotency_key from public.ledger_entry where id = p_entry $$;
create or replace function pg_temp.rnum(p_run uuid) returns text language sql as $$
  select number from public.remittance_run where id = p_run $$;
create or replace function pg_temp.rstatus(p_run uuid) returns text language sql as $$
  select status from public.remittance_run where id = p_run $$;
create or replace function pg_temp.rtransfer(p_run uuid) returns uuid language sql as $$
  select transfer_id from public.remittance_run where id = p_run $$;
-- the SQLSTATE a statement raises ('ok' when none), in a rolled-back subtransaction
create or replace function pg_temp.state(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'state rolled back' using errcode = 'TR003';
  exception when sqlstate 'TR003' then
    v := 'ok';
  when others then
    get stacked diagnostics v = returned_sqlstate;
  end;
  return v;
end $$;
-- a scenario in a rolled-back subtransaction, the switch on when p_on, its outcome kept (or its error's text)
create or replace function pg_temp.iso(p_scenario text, p_on boolean default false) returns jsonb language plpgsql as $$
declare v jsonb; v_msg text; v_state text;
begin
  begin
    if p_on then
      update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
    end if;
    execute format('select pg_temp.%I()', p_scenario) into v;
    raise exception 'scenario % rolled back', p_scenario using errcode = 'TR001';
  exception when sqlstate 'TR001' then
    null;
  when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    v := jsonb_build_object('error', v_state || ': ' || v_msg);
  end;
  reset role;
  return v;
end $$;
-- a client's collection n of p_amount on its file (p_day, three days ago by default): pending
create or replace function pg_temp.pending(p_c text, p_n text, p_amount bigint, p_day date default null)
returns void language plpgsql as $$
begin
  perform pg_temp.file(p_n, pg_temp.pf(p_c), p_amount);
  perform pg_temp.collect(p_n, p_amount, coalesce(p_day, private.paris_today() - 3));
end $$;
-- the client's run: requested, prepared without commission, approved; the run
create or replace function pg_temp.flight(p_c text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := pg_temp.request(p_c, 'run-' || p_key);
  perform pg_temp.prepare_plain(v);
  perform pg_temp.approve_plain(v, 'run-' || p_key);
  return v;
end $$;
-- (test only) a transfer executed from p_day: its execution dates moved back (a statement line is never dated in the
-- future, and a debit counts for its chain only from the transfer's execution date)
create or replace function pg_temp.exec_back(p_transfer uuid, p_day date) returns void language plpgsql as $$
begin
  alter table public.bank_transfer disable trigger bank_transfer_guard;
  update public.bank_transfer set requested_execution_date = p_day where id = p_transfer;
  alter table public.bank_transfer enable always trigger bank_transfer_guard;
  alter table public.transfer_file_item disable trigger transfer_file_item_append_only;
  update public.transfer_file_item set execution_date = p_day where transfer_id = p_transfer;
  alter table public.transfer_file_item enable always trigger transfer_file_item_append_only;
end $$;
-- the run's payout debited on p_day (yesterday by default): its file handed out if it is not, its debit on statement
-- p_s (hex), booked by the job's funds pass; the debit line
create or replace function pg_temp.debit(p_run uuid, p_s text, p_day date default null) returns uuid
language plpgsql as $$
declare v_t uuid := pg_temp.rtransfer(p_run); v_day date := coalesce(p_day, private.paris_today() - 1);
begin
  if pg_temp.status(v_t) = 'ordered' then
    perform pg_temp.handed_out('file-' || p_s, 'gen-file-' || p_s);
  end if;
  perform pg_temp.exec_back(v_t, v_day);
  perform pg_temp.stmt2(p_s, v_day, jsonb_build_array(jsonb_build_object('amount', pg_temp.amt(v_t),
                                                                         'e2e', pg_temp.e2e(v_t))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2(p_s, 1), 'payout', v_t)));
  return pg_temp.l2(p_s, 1);
end $$;
-- a client's collection n of p_amount (collected on p_coll, three days ago by default) remitted in a run whose payout is
-- debited on p_day; the run
create or replace function pg_temp.remitted(p_c text, p_n text, p_amount bigint, p_s text, p_day date default null,
                                            p_coll date default null) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount, p_coll);
  v := pg_temp.flight(p_c, 'rm-' || p_s);
  perform pg_temp.debit(v, p_s, p_day);
  return v;
end $$;
-- the run's payout returned by the client's bank on p_day (statement p_s), booked by the job's funds pass
create or replace function pg_temp.bounce(p_run uuid, p_s text, p_day date default null) returns void
language plpgsql as $$
declare v_t uuid := pg_temp.rtransfer(p_run);
begin
  perform pg_temp.stmt2(p_s, coalesce(p_day, private.paris_today()), jsonb_build_array(jsonb_build_object(
    'dir', 'credit', 'kind', 'return', 'amount', pg_temp.amt(v_t), 'orig', pg_temp.e2e(v_t))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2(p_s, 1), 'payout_returned', v_t)));
end $$;
-- « Désimputer » as p_user: the payment's live allocations on its file (or p_entries); the result, or its error
create or replace function pg_temp.unalloc(p_n text, p_key text default null, p_user text default '01',
                                           p_aal text default 'aal2', p_entries uuid[] default null)
returns jsonb language plpgsql as $$
declare v jsonb; v_state text; v_msg text;
        v_e uuid[] := coalesce(p_entries, array(
          select x.id from public.ledger_entry x where x.payment_id = pg_temp.pay(p_n) and x.entry_type = 'allocation'
            and not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = x.id)));
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.reverse_allocation(coalesce(p_key, 'unalloc-' || p_n), pg_temp.pay(p_n), pg_temp.f(p_n), v_e,
                                   'motif de test');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v := jsonb_build_object('error', v_state, 'message', v_msg);
  end;
  reset role;
  return v;
end $$;
-- « Couvrir » as p_user (an admin by default): its result, or its error's message
create or replace function pg_temp.cover(p_key text, p_r uuid, p_expected text, p_user text default '04',
                                         p_aal text default 'aal2') returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.cover_remitted_reversal(p_key, p_r, p_expected);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Vérification complète des avances » as p_user for servicer p_org: its result, or its error's message
create or replace function pg_temp.full_req(p_key text, p_user text default '04', p_aal text default 'aal2',
                                            p_org uuid default '00000000-0000-0000-0000-0000000000aa')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.request_full_advance_check(p_key, p_org);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- a public read as p_user (aal2 unless said): its jsonb, or its error's message
create or replace function pg_temp.read_as(p_user text, p_sql text, p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    execute p_sql into v;
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- the run page's advances [[cause, amount]] (as ops)
create or replace function pg_temp.page_advances(p_run uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(x ->> 'cause', x ->> 'amount_minor') order by x ->> 'cause'), '[]')
  from jsonb_array_elements(pg_temp.read_as('01', format('select public.remittance_run_payout(%L)', p_run))
                              -> 'advances') x $$;
-- the advance checks alone into a check run of their own (finished), as of p_today, full pass or not; the run
create or replace function pg_temp.adv_run(p_today date default null, p_full boolean default false) returns uuid
language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_advance_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today, p_full);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return v;
end $$;
-- a check run's rows of a code: [subject is p_subject, amount]
create or replace function pg_temp.rows_of(p_run uuid, p_code text, p_subject uuid default null) returns jsonb
language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(c.subject_id = p_subject, c.amount_minor)
                            order by c.amount_minor, c.subject_id), '[]')
  from public.payment_check_result c where c.run_id = p_run and c.code = p_code $$;
-- (test only) a completed check run started p_days from now (the delta window's start), with its listed reversals
-- a finished check run of the servicer started at p_at, listing nothing
create or replace function pg_temp.prior_run_at(p_at timestamptz) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id, started_at)
  values ('00000000-0000-0000-0000-0000000000aa', p_at) returning id into v;
  update public.payment_check_run set finished_at = p_at, violations = 0, alerts = 0, summary = '{}' where id = v;
  return v;
end $$;
create or replace function pg_temp.prior_run(p_days integer, p_listed uuid[] default '{}') returns uuid
language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id, started_at)
  values ('00000000-0000-0000-0000-0000000000aa', now() + make_interval(days => p_days))
  returning id into v;
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count)
  select v, '00000000-0000-0000-0000-0000000000aa', 'remitted_reversal_uncovered', 'violation', 'ledger_entry', x, 'EUR',
         1, 1
  from unnest(p_listed) x;
  update public.payment_check_run set finished_at = now() + make_interval(days => p_days), violations = 0, alerts = 0,
    summary = '{}' where id = v;
  return v;
end $$;
-- (switch on) client c's collection n of p_amount in a run whose payout, handed out, is cancelled after the download and
-- its run cancelled (the item back in the queue); the payout
create or replace function pg_temp.late_cancel(p_c text, p_n text, p_amount bigint, p_s text) returns uuid
language plpgsql as $$
declare v_run uuid; v_t uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount);
  v_run := pg_temp.flight(p_c, 'lc-' || p_s);
  perform pg_temp.handed_out('file-' || p_s, 'gen-file-' || p_s);
  v_t := pg_temp.rtransfer(v_run);
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_t;
  perform pg_temp.cancel_run(v_run, 'lc-' || p_s);
  return v_t;
end $$;
-- (switch on) transfer x executed late, on statement p_s today: booked « hors reversement » for its whole amount
create or replace function pg_temp.late_exec(p_x uuid, p_s text) returns text language plpgsql as $$
begin
  perform pg_temp.stmt2(p_s, private.paris_today(), jsonb_build_array(jsonb_build_object(
    'amount', pg_temp.amt(p_x), 'e2e', pg_temp.e2e(p_x))));
  return pg_temp.bkx(pg_temp.l2(p_s, 1), jsonb_build_array(pg_temp.pt('unplanned_payout', p_x, pg_temp.amt(p_x))));
end $$;
-- transfer x coming back today (statement p_s), booked as the options propose (its refusal's code, or ok)
create or replace function pg_temp.late_return(p_x uuid, p_s text) returns text language plpgsql as $$
begin
  perform pg_temp.stmt2(p_s, private.paris_today(), jsonb_build_array(jsonb_build_object(
    'dir', 'credit', 'kind', 'return', 'amount', pg_temp.amt(p_x), 'orig', pg_temp.e2e(p_x))));
  return pg_temp.bkx(pg_temp.l2(p_s, 1), pg_temp.prop(pg_temp.l2(p_s, 1)));
end $$;
-- payment n of p_amount on a file owing p_file_amount: p_file_amount allocated, the rest forwarded to the client (as
-- « Reverser au client » posts it: +4710 / −4670[c]), three days ago
create or replace function pg_temp.split_pay(p_c text, p_n text, p_amount bigint, p_file_amount bigint)
returns void language plpgsql as $$
declare d date := private.paris_today() - 3;
begin
  perform pg_temp.file(p_n, pg_temp.pf(p_c), p_file_amount);
  perform pg_temp.collect(p_n, p_amount, d, false);
  update public.payment set account_id = pg_temp.f(p_n), status = 'matched', match_method = 'rf_structured',
                            matched_at = now()
  where id = pg_temp.pay(p_n);
  perform private.allocation_begin();
  insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy, inputs_hash)
  values (pg_temp.pay(p_n), 1, pg_temp.f(p_n), 'allocate', d,
          '{"accessory_rank": "before_principal", "unclassified": "last"}', repeat('0', 64));
  insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
  values (pg_temp.pay(p_n), 1, pg_temp.it(p_n), 'principal', p_file_amount);
  perform private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-' || p_n);
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, payment_id, source_type, source_id, reason)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'forward', d, 'forward:test-' || p_n, pg_temp.c(p_c),
          pg_temp.pay(p_n), 'payment', pg_temp.pay(p_n)::text, 'Reversement sans imputation (test)');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency) values
    (1, 1, 'unallocated_payment', p_amount - p_file_amount, 'EUR'),
    (1, 2, 'client_payable', -(p_amount - p_file_amount), 'EUR');
  perform private.ledger_post_set();
end $$;
-- the job's mode: return links (method auto) of [line, payment n] through private.apply_debit_decisions
create or replace function pg_temp.job_returns(p_links jsonb) returns jsonb language plpgsql as $$
begin
  perform private.debit_link_begin();
  insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, method)
  select x.ord, (x.v ->> 0)::uuid, 'return', pg_temp.pay(x.v ->> 1), 'auto'
  from jsonb_array_elements(p_links) with ordinality x (v, ord);
  return private.apply_debit_decisions('00000000-0000-0000-0000-0000000000aa');
end $$;
-- a planted settlement of an advance (a claw-back or a payment of 7b/7c, which do not exist yet)
create or replace function pg_temp.plant_settlement(p_advance uuid, p_amount bigint) returns void language sql as $$
  insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id, kind,
                                            amount_minor, settled_on)
  select a.organization_id, a.client_organization_id, 'advance', a.id, 'compensation', p_amount, private.paris_today()
  from public.client_advance a where a.id = p_advance $$;
-- advances read as p_user
create or replace function pg_temp.n_advances(p_user text, p_aal text default 'aal2') returns integer
language plpgsql as $$
declare n integer;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  select count(*) into n from public.client_advance;
  reset role;
  return n;
end $$;
-- a late predecessor (switch on): client c's run (collection n) handed out, its transfer x1 cancelled after the
-- download and re-issued as x2 (ordered), the run in flight again on x2; x1 then executed late (statement p_s, on p_day),
-- booked from « Débits et retours » as its run's payout (x2 withdrawn). The run
create or replace function pg_temp.late_pred(p_c text, p_n text, p_amount bigint, p_s text, p_unalloc boolean,
                                             p_day date default null) returns uuid language plpgsql as $$
declare v_run uuid; v_x1 uuid; v_x2 uuid; v_day date := coalesce(p_day, private.paris_today() - 1);
begin
  perform pg_temp.pending(p_c, p_n, p_amount, private.paris_today() - 6);
  v_run := pg_temp.flight(p_c, 'lp-' || p_s);
  perform pg_temp.handed_out('file-' || p_s, 'gen-file-' || p_s);
  v_x1 := pg_temp.rtransfer(v_run);
  perform pg_temp.exec_back(v_x1, v_day);
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_x1;
  insert into public.bank_transfer (organization_id, client_organization_id, kind, debtor_bank_account_id, currency,
                                    amount_minor, payee_name, payee_iban, payee_bic, end_to_end_id, remittance_info,
                                    requested_execution_date, run_id, ordered_by, replaces_transfer_id)
  select x.organization_id, x.client_organization_id, 'payout', x.debtor_bank_account_id, x.currency, x.amount_minor,
         x.payee_name, x.payee_iban, x.payee_bic, 'RMT' || upper(substr(md5(gen_random_uuid()::text), 1, 12)),
         x.remittance_info, x.requested_execution_date, x.run_id, x.ordered_by, x.id
  from public.bank_transfer x where x.id = v_x1
  returning id into v_x2;
  alter table public.remittance_run disable trigger remittance_run_guard;
  update public.remittance_run set transfer_id = v_x2, status = 'approved', version = version + 1 where id = v_run;
  alter table public.remittance_run enable always trigger remittance_run_guard;
  insert into t values ('x1-' || p_s, v_x1), ('x2-' || p_s, v_x2);
  if p_unalloc then
    perform pg_temp.unalloc(p_n);
  end if;
  perform pg_temp.stmt2(p_s, v_day, jsonb_build_array(jsonb_build_object('amount', pg_temp.amt(v_x1),
                                                                         'e2e', pg_temp.e2e(v_x1))));
  insert into t values ('lp-booked-' || p_s, null);
  update t set v = case pg_temp.bkx(pg_temp.l2(p_s, 1), pg_temp.prop(pg_temp.l2(p_s, 1))) when 'ok' then v_run end
  where k = 'lp-booked-' || p_s;
  return v_run;
end $$;
-- (review round 1) a run of client c prepared from its whole queue, its invoice (p_num / p_den of file n's collection,
-- 20 % VAT) set off for the whole gross — the caller sizes it so that the invoice's TTC is the gross: N = 0, booked at
-- approval with its settlement; the version
create or replace function pg_temp.prepare_off(p_run uuid, p_c text, p_n text, p_num bigint, p_den bigint)
returns integer language plpgsql as $$
declare r public.remittance_run; v_files jsonb; v_keys jsonb; v_gross bigint; v_ht bigint; v_plan jsonb;
begin
  select * into r from public.remittance_run where id = p_run;
  v_files := jsonb_build_object(p_n, (select amount_minor from public.payment where id = pg_temp.pay(p_n))::text);
  v_keys := pg_temp.keys(p_c, v_files, p_num, p_den);
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         pf.mandate_id, case when pf.mandate_id is not null
                             then ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid end,
         e.payment_id, e.effective_date, e.effective_date, q.posted_at,
         case when q.amount_minor > 0 then e.effective_date + 30 end,
         case when q.amount_minor > 0 then e.effective_date + 27 end, q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text),
         coalesce((select (k ->> 'commission')::bigint from jsonb_array_elements(v_keys) k
                   where (k ->> 'account_id')::uuid = e.account_id), 0),
         case when e.account_id is not distinct from pg_temp.f(p_n) then 'charged' else 'none' end, '[]',
         e.account_id is not distinct from pg_temp.f(p_n)
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  left join public.account a on a.id = e.account_id
  left join public.portfolio pf on pf.id = a.portfolio_id
  where q.draft_run_id = p_run;
  v_gross := (select sum(amount_minor) from private.remittance_draft_line where run_id = p_run);
  v_ht := (select sum((x.value)::bigint * p_num / p_den) from jsonb_each_text(v_files) x);
  if v_ht + v_ht / 5 <> v_gross then
    raise exception 'prepare_off: the invoice''s TTC % is not the gross %', v_ht + v_ht / 5, v_gross;
  end if;
  v_plan := pg_temp.plan(p_c, v_gross, v_ht, v_gross, v_ht / 5);
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', v_gross::text,
    'invoice_ht', v_plan ->> 'invoice_ht', 'invoice_vat', v_plan ->> 'invoice_vat', 'invoice_ttc', v_plan ->> 'invoice_ttc',
    'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0', 'taken', v_plan ->> 'dc', 'advances', '0', 'refunds', '0',
    'settlement', v_plan ->> 'settlement', 'net', v_plan ->> 'net', 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || v_plan::text, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', pg_temp.doc(p_c, v_files, p_num, p_den), 'key_states', v_keys, 'plan', v_plan));
  return (select version from public.remittance_run where id = p_run);
end $$;
-- (review round 1, tests-ui-5) the nightly's two violations of the advances after a scenario (a full pass of
-- run_advance_checks): [code, amount] — none expected wherever the scenario posts, releases or re-posts a cover
create or replace function pg_temp.nightly() returns jsonb language plpgsql as $$
declare c uuid := pg_temp.adv_run(null, true);
begin
  return (select coalesce(jsonb_agg(jsonb_build_array(x.code, x.amount_minor) order by x.code, x.amount_minor), '[]')
          from public.payment_check_result x
          where x.run_id = c and x.code in ('remitted_reversal_uncovered', 'advance_ledger'));
end $$;
-- (review round 2) the sequential scans of the tables an item's settlement reads, so far in this transaction
create or replace function pg_temp.seqs() returns bigint language sql as $$
  select coalesce(sum(x.seq_scan), 0)::bigint from pg_stat_xact_user_tables x
  where x.relid in ('private.unplanned_paid_item'::regclass, 'public.remittance_line'::regclass,
                    'public.remittance_run'::regclass, 'public.bank_line_booking'::regclass,
                    'public.ledger_entry'::regclass) $$;
-- (review round 1, CC-2) the rows a table's index scans fetched so far in this transaction
create or replace function pg_temp.fetched(p_table regclass) returns bigint language sql as $$
  select coalesce((select x.idx_tup_fetch from pg_stat_xact_user_tables x where x.relid = p_table), 0) $$;
grant execute on all functions in schema pg_temp to authenticated;


-- 044's own helpers ---------------------------------------------------------------------------------------------------
-- the write-off evidence of Martin (a1), Lilas (a2) and Petit (a8): d…3<client>
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-0000000003' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'advance_write_off_evidence', 'client/test/3' || c || '.pdf',
       repeat('a', 64), 'application/pdf'
from unnest(array['a1', 'a2', 'a8']) c;
-- « Passer en perte » as p_user (an admin at aal2 by default): its result, or its error's message
create or replace function pg_temp.wo(p_key text, p_adv uuid, p_amount text, p_expected text,
                                      p_reason text default 'Client liquidé, créance irrécouvrable (test)',
                                      p_evidence uuid default 'd0000000-0000-0000-0000-0000000003a1',
                                      p_user text default '04', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.write_off_advance('woff-044-' || p_key, p_adv, p_amount, p_expected, p_reason, p_evidence);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- a forged 4670 debit of client c (a planted overrun before its payout's booking, as 043 #39)
create or replace function pg_temp.forge(p_c text, p_amount bigint, p_tag text) returns void language plpgsql as $$
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'remittance', private.paris_today() - 1, 'remit:test-forged-' || p_tag,
          pg_temp.c(p_c), 'bank_transaction', 'e1000000-0000-0000-0000-000000000013');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_payable', p_amount, 'EUR', null),
    (1, 2, 'client_money_cash', -p_amount, 'EUR', '80000000-0000-0000-0000-0000000000cf');
  perform private.ledger_post_set();
end $$;
-- client c's second portfolio (20…b<c's last digit>) on a second mandate (70…b<…>, its terms 71…b<…>)
create or replace function pg_temp.pf2(p_c text) returns uuid language sql as $$
  select ('20000000-0000-0000-0000-0000000000b' || right(p_c, 1))::uuid $$;
create or replace function pg_temp.second_mandate(p_c text) returns void language plpgsql as $$
declare v_m uuid := ('70000000-0000-0000-0000-0000000000b' || right(p_c, 1))::uuid;
begin
  insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on,
                              insurance_clause_ref)
  values (v_m, '00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_c), 'MAND-b' || right(p_c, 1), 'mandate_amicable',
          '2026-01-01', 'art. 9');
  insert into public.mandate_terms (id, mandate_id, valid_from, commission_schedule, commission_clause_ref,
                                    remittance_terms, remittance_clause_ref, document_id)
  select ('71000000-0000-0000-0000-0000000000b' || right(p_c, 1))::uuid, v_m, t.valid_from, t.commission_schedule,
         t.commission_clause_ref, t.remittance_terms, t.remittance_clause_ref, t.document_id
  from public.mandate_terms t where t.mandate_id = pg_temp.mandate(p_c);
  insert into public.portfolio (id, organization_id, client_organization_id, name, mandate_id)
  values (pg_temp.pf2(p_c), '00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_c), 'P2' || p_c, v_m);
end $$;
-- (test only) the claw-back clause in client c's terms (its version immutable once in force: the guard set aside)
create or replace function pg_temp.clawback(p_c text, p_ref text) returns void language plpgsql as $$
begin
  alter table public.mandate_terms disable trigger mandate_terms_guard;
  update public.mandate_terms
  set remittance_terms = jsonb_set(remittance_terms, '{clawback}', jsonb_build_object('clause_ref', p_ref))
  where mandate_id = pg_temp.mandate(p_c);
  alter table public.mandate_terms enable always trigger mandate_terms_guard;
end $$;
-- What the prepare job writes for a run that takes advances back (emulated): its whole queue as lines, a remitted
-- reversal's cover's item on its advance's mandate and any other advance's on none (as the job reads them; review round
-- 1, M7B-MONEY-1), no commission; its plan settles each [advance, amount] of p_takes
-- (kind advance, open_before its open as the job reads it), N = gross − Σ, D = Da = Σ
create or replace function pg_temp.prepare_adv(p_run uuid, p_takes jsonb) returns integer language plpgsql as $$
declare r public.remittance_run; v_gross bigint; v_take bigint; v_settles jsonb; v_plan jsonb;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         coalesce(pf.mandate_id, case when ca.cause = 'remitted_reversal' then ca.mandate_id end),
         case when pf.mandate_id is not null
              then ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid end,
         e.payment_id, e.effective_date, e.effective_date, q.posted_at,
         case when q.amount_minor > 0 then e.effective_date + 30 end,
         case when q.amount_minor > 0 then e.effective_date + 27 end, q.amount_minor,
         jsonb_build_object('principal', q.amount_minor::text), 0, 'none', '[]', false
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  left join public.account a on a.id = e.account_id
  left join public.portfolio pf on pf.id = a.portfolio_id
  left join public.client_advance ca on ca.entry_id = case q.kind when 'client_advance' then e.id
                                                                  when 'client_advance_reversal' then e.reverses_entry_id end
  where q.draft_run_id = p_run;
  v_gross := (select sum(amount_minor) from private.remittance_draft_line where run_id = p_run);
  select coalesce(sum((x ->> 1)::bigint), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'ref', x ->> 0, 'kind', 'advance', 'mandate_id', ca.mandate_id, 'amount', x ->> 1, 'vat_moved', '0',
           'open_before', (ca.amount_minor - coalesce((select sum(s.amount_minor) from public.commission_settlement s
                                                       where s.document_kind = 'advance' and s.document_id = ca.id),
                                                      0))::text)), '[]')
  into v_take, v_settles
  from jsonb_array_elements(p_takes) x
  join public.client_advance ca on ca.id = (x ->> 0)::uuid;
  v_plan := jsonb_build_object('settles', v_settles, 'net', (v_gross - v_take)::text, 'settlement', v_take::text,
                               'dc', '0', 'da', v_take::text, 'vat_moved', '0', 'deferred', v_take = 0);
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', v_gross::text,
    'invoice_ht', '0', 'invoice_vat', '0', 'invoice_ttc', '0', 'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0',
    'taken', '0', 'advances', v_take::text, 'refunds', '0', 'settlement', v_take::text,
    'net', (v_gross - v_take)::text, 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || v_plan::text, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', '[]'::jsonb, 'key_states', '[]'::jsonb, 'plan', v_plan));
  return (select version from public.remittance_run where id = p_run);
end $$;
-- a line planted into run p_run for entry p_entry (kind, amount, mandate), its line number or the refusal
create or replace function pg_temp.plant_line(p_run uuid, p_entry uuid, p_kind text, p_amount bigint, p_mandate uuid)
returns text language sql as $$
  select regexp_replace(pg_temp.attempt(format(
    'insert into public.remittance_line (run_id, line_no, organization_id, client_organization_id, currency, '
    'ledger_entry_id, kind, mandate_id, effective_date, posted_at, amount_minor, commission_state) '
    'select r.id, 99, r.organization_id, r.client_organization_id, r.currency, %L, %L, %L, current_date, now(), %s, '
    '''none'' from public.remittance_run r where r.id = %L returning line_no', p_entry, p_kind, p_mandate, p_amount,
    p_run)), '[0-9a-f-]{36}/', '') $$;
grant execute on all functions in schema pg_temp to authenticated;



-- The base (as 044's): the account's cash (an unidentified payment of 10 000,00 €) and its statement of yesterday
select pg_temp.collect('13', 1000000, private.paris_today() - 6, false);
select pg_temp.stmt('00', private.paris_today() - 1);

-- 045's own helpers ---------------------------------------------------------------------------------------------------
-- each client's evidence: a payment's (d…5<c>), a refund's (d…6<c>), a designation's (d…7<c>), a status event's
-- (d…8<c>); a write-off's (044's kind) for Dupont (a6)
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-000000000' || x.n || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa'::uuid,
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || x.c || '.pdf',
       repeat('a', 64), 'application/pdf'
from (select c, n, case n when '5' then 'client_payment_evidence' when '6' then 'client_refund_evidence'
                          when '7' then 'payment_designation_evidence' else 'client_status_evidence' end as kind
      from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c
      cross join unnest(array['5', '6', '7', '8']) n) x
union all
select 'd0000000-0000-0000-0000-0000000003a6'::uuid, '00000000-0000-0000-0000-0000000000aa'::uuid,
       '00000000-0000-0000-0000-0000000000a6'::uuid, 'advance_write_off_evidence', 'client/test/3a6.pdf', repeat('a', 64),
       'application/pdf';
create or replace function pg_temp.ev(p_n text, p_c text) returns uuid language sql as $$
  select ('d0000000-0000-0000-0000-000000000' || p_n || p_c)::uuid $$;
-- an invoice of client c: its collection n of p_amount (three days ago) in a run (key inv-<s>) whose plan sets off p_take
-- of it (VAT moved p_vat), approved, its payout debited on statement s (hex) unless p_debit is false; the invoice (the run
-- kept as run-<s>). Commission 15 %, VAT 20 %: 200 000 collected → 30 000 HT, 6 000 VAT, 36 000 TTC
create or replace function pg_temp.inv(p_c text, p_n text, p_amount bigint, p_s text, p_take bigint default 0,
                                       p_vat bigint default 0, p_debit boolean default true) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount);
  v := pg_temp.runk(p_c, jsonb_build_object(p_n, p_amount::text), p_take, p_vat, 'inv-' || p_s);
  insert into t values ('run-' || p_s, v) on conflict (k) do update set v = excluded.v;
  if p_debit then
    perform pg_temp.debit(v, p_s);
  end if;
  return (select i.id from public.commission_invoice i where i.run_id = v and i.kind = 'invoice');
end $$;
-- (test only) an invoice's due date, or its issue date, moved (its append-only guard, and its year check, set aside)
create or replace function pg_temp.due(p_inv uuid, p_day date) returns void language plpgsql as $$
begin
  alter table public.commission_invoice disable trigger commission_invoice_append_only;
  update public.commission_invoice set due_date = p_day where id = p_inv;
  alter table public.commission_invoice enable always trigger commission_invoice_append_only;
end $$;
create or replace function pg_temp.issued(p_inv uuid, p_day date) returns void language plpgsql as $$
begin
  alter table public.commission_invoice drop constraint if exists commission_invoice_year;
  alter table public.commission_invoice disable trigger commission_invoice_append_only;
  update public.commission_invoice set issue_date = p_day where id = p_inv;
  alter table public.commission_invoice enable always trigger commission_invoice_append_only;
end $$;
create or replace function pg_temp.num(p_inv uuid) returns text language sql as $$
  select number from public.commission_invoice where id = p_inv $$;
-- an advance of client c: its collection n of p_amount remitted (debited d − 2 on statement s), then taken back
-- (« Désimputer »): its cover
create or replace function pg_temp.adv(p_c text, p_n text, p_amount bigint, p_s text) returns public.client_advance
language plpgsql as $$
begin
  perform pg_temp.remitted(p_c, p_n, p_amount, p_s, private.paris_today() - 2, private.paris_today() - 3);
  perform pg_temp.unalloc(p_n);
  return pg_temp.adv_of(pg_temp.rev(pg_temp.alloc(p_n)));
end $$;
-- « Enregistrer un règlement » (own account) as p_user (ops 01 at aal2 by default): its result, or its error's message.
-- The open the page showed is the preview's unless given; the evidence the client's own (p_ev 'own'), none, or a uuid
create or replace function pg_temp.cpay(p_key text, p_c text, p_amount text, p_value date default null,
                                        p_docs uuid[] default null, p_desig uuid default null,
                                        p_recover uuid[] default null, p_expected text default null,
                                        p_ev text default 'own', p_user text default '01', p_aal text default 'aal2')
returns jsonb language plpgsql as $$
declare v jsonb; v_exp text := p_expected; v_on date := coalesce(p_value, private.paris_today());
begin
  if v_exp is null then
    v_exp := pg_temp.read_as('01', format('select public.client_payment_preview(%L, ''EUR'', %L, %L, %L, %L)',
                                          pg_temp.c(p_c), p_amount, p_docs, p_recover, v_on)) ->> 'open_minor';
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.record_client_payment('cpay-045-' || p_key, pg_temp.c(p_c), 'EUR', p_amount, v_on,
                                      case p_ev when 'own' then pg_temp.ev('5', p_c) when 'none' then null
                                                else p_ev::uuid end,
                                      p_docs, p_desig, p_recover, v_exp, 'Virement reçu (test)');
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Règlement d'une facture ou d'une avance du cabinet » on a dedicated-account line, as p_user (ops 01 at aal2)
create or replace function pg_temp.cline(p_key text, p_line uuid, p_docs uuid[] default null, p_desig uuid default null,
                                         p_recover uuid[] default null, p_expected text default null,
                                         p_user text default '01', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb; v_exp text := p_expected;
begin
  if v_exp is null then
    v_exp := pg_temp.read_as('01', format('select public.client_payment_line(%L, %L, %L)', p_line, p_docs, p_recover))
             #>> '{preview,open_minor}';
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.book_client_payment_line('cpayl-045-' || p_key, p_line, p_docs, p_desig, p_recover, v_exp,
                                         'Règlement du client (test)');
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Enregistrer le remboursement » (a credit note or a client credit) as p_user: the owed the page showed is today's
-- unless given; the evidence the client's (p_ev 'own'), none, or a uuid
create or replace function pg_temp.crfd(p_key text, p_doc uuid, p_amount text, p_paid date default null,
                                        p_expected text default null, p_ev text default 'own',
                                        p_user text default '01', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb; v_c uuid; v_exp text := p_expected;
begin
  v_c := coalesce((select i.client_organization_id from public.commission_invoice i where i.id = p_doc),
                  (select c.client_organization_id from public.client_credit c where c.id = p_doc));
  if v_exp is null then
    v_exp := coalesce(private.document_open(p_doc), private.client_credit_open(p_doc), 0)::text;
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.record_client_refund('crfd-045-' || p_key, p_doc, p_amount, coalesce(p_paid, private.paris_today()),
                                     case p_ev when 'own' then pg_temp.ev('6', right(v_c::text, 2))
                                               when 'none' then null else p_ev::uuid end,
                                     v_exp, 'Virement de remboursement (test)');
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- a document's settlements [[kind, amount, VAT moved]], in their order
create or replace function pg_temp.sets(p_doc uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(s.kind, s.amount_minor, s.vat_moved_minor) order by s.created_at, s.id),
                  '[]')
  from public.commission_settlement s where s.document_id = p_doc $$;
-- a client's credits owed back [[cause, amount, open]]
create or replace function pg_temp.ccs(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(c.cause, c.amount_minor, private.client_credit_open(c.id))
                            order by c.cause), '[]')
  from public.client_credit c where c.client_organization_id = pg_temp.c(p_c) $$;
-- the advance checks' rows of 7c-1's codes as of p_today (the full pass): [code, severity, amount, cause, p0]
create or replace function pg_temp.cchecks(p_today date default null) returns jsonb language plpgsql as $$
declare c uuid := pg_temp.adv_run(p_today, true);
begin
  return (select coalesce(jsonb_agg(jsonb_build_array(x.code, x.severity, x.amount_minor, x.details ->> 'cause',
                                                      x.details -> 'p0') order by x.code, x.amount_minor), '[]')
          from public.payment_check_result x
          where x.run_id = c and x.code in ('client_credit_owed', 'client_credit_ledger', 'written_off_recovery_ledger'));
end $$;
-- a book's balance as of today (a client's when p_c is given)
create or replace function pg_temp.bk0(p_book text, p_c text default null) returns bigint language sql as $$
  select pg_temp.bal(p_book, p_c, private.paris_today()) $$;
-- a credit line on the dedicated account (statement s, hex; yesterday unless p_day) of kind p_kind from p_iban,
-- labelled p_label, carrying p_e2e; and the debit job's review of it (client_credit for a client's credit); the line
create or replace function pg_temp.ctin(p_s text, p_amount bigint, p_iban text, p_label text default null,
                                        p_kind text default 'client_transfer_in', p_e2e text default null,
                                        p_day date default null) returns uuid language plpgsql as $$
declare
  v_day date := coalesce(p_day, private.paris_today() - 1);
  s uuid := ('e4' || lpad(p_s, 6, '0') || '-0000-0000-0000-000000000000')::uuid;
  v_open bigint := pg_temp.cash() + (select u.minor from private.bank_unposted('80000000-0000-0000-0000-0000000000cf',
                                                                               'infinity'::date) u);
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, counterparty_iban,
                                       counterparty_name, remittance_text)
  values (pg_temp.l2(p_s, 1), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, 1,
          't:' || s || '1', 'credit', p_amount, 'EUR', v_day, p_kind, p_e2e, p_iban, 'CLIENT (test)', p_label);
  update public.bank_statement set status = 'imported', from_date = v_day, to_date = v_day,
    opening_booked_minor = v_open, closing_booked_minor = v_open + p_amount, counts = '{}',
    finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object('from_date', v_day, 'to_date', v_day, 'covers_from', v_day,
                                                    'covers_to', v_day, 'opening_minor', v_open::text,
                                                    'closing_minor', (v_open + p_amount)::text, 'created_at', now()))
  where id = s;
  if p_kind = 'client_transfer_in' then
    perform pg_temp.book('[]'::jsonb, jsonb_build_array(jsonb_build_object('line', pg_temp.l2(p_s, 1),
                                                                           'reason', 'client_credit')));
  end if;
  return pg_temp.l2(p_s, 1);
end $$;
-- the IBAN of client c's confirmed payout account
create or replace function pg_temp.iban_of(p_c text) returns text language sql as $$
  select iban from public.client_payout_account where client_organization_id = pg_temp.c(p_c) and status = 'active' $$;
-- (test only) a run's plan made to pay p_doc as a refund (the run in flight, as an approval would freeze it)
create or replace function pg_temp.plan_refund(p_run uuid, p_doc uuid, p_amount bigint) returns void
language plpgsql as $$
begin
  alter table public.remittance_run disable trigger remittance_run_guard;
  update public.remittance_run
  set settlement_plan = jsonb_build_object('settles', jsonb_build_array(jsonb_build_object(
                          'kind', 'refund', 'document_id', p_doc, 'amount', p_amount::text, 'vat_moved', '0')))
  where id = p_run;
  alter table public.remittance_run enable always trigger remittance_run_guard;
end $$;
-- the remittance checks' rows of a code as of p_today: [subject, amount]
create or replace function pg_temp.rrc(p_code text, p_today date) returns jsonb language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa') returning id into v;
  perform private.run_remittance_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return coalesce((select jsonb_agg(jsonb_build_array(c.subject_id, c.amount_minor) order by c.amount_minor)
                   from public.payment_check_result c where c.run_id = v and c.code = p_code), '[]');
end $$;
-- a raw entry of the servicer's fund (lines [book, amount], a 5122 line on the own account, 5120 on the dedicated one)
-- of type p_type for client c, posted by the ledger's write path: 'ok', or the SQLSTATE it raised (rolled back)
create or replace function pg_temp.post(p_type text, p_key text, p_lines jsonb, p_c text default 'a1') returns text
language sql as $$
  select pg_temp.state(format(
    $q$
    do $d$
    begin
      perform private.ledger_post_set_begin();
      insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                      client_organization_id, source_type, source_id, reason)
      values (1, '00000000-0000-0000-0000-0000000000aa', %L, private.paris_today(), %L, %L,
              case when %L in ('client_payment_dedicated', 'client_settlement') then
                     case %L when 'client_settlement' then 'remittance_run' else 'bank_transaction' end
                   else 'document' end,
              'e1000000-0000-0000-0000-000000000013', 'Écriture de test');
      insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
      select 1, l.ord, l.v ->> 0, (l.v ->> 1)::bigint, 'EUR',
             case l.v ->> 0 when 'own_cash' then '80000000-0000-0000-0000-0000000000c0'::uuid
                            when 'client_money_cash' then '80000000-0000-0000-0000-0000000000cf'::uuid end
      from jsonb_array_elements(%L::jsonb) with ordinality l (v, ord);
      perform private.ledger_post_set();
      perform private.ledger_check_now();
    end $d$
    $q$, p_type, 'raw-045-' || p_key, pg_temp.c(p_c), p_type, p_type, p_lines)) $$;
-- the same, kept (a planted posting, for the nightly to see)
create or replace function pg_temp.plant(p_type text, p_key text, p_lines jsonb, p_c text default 'a1') returns void
language plpgsql as $$
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason)
  values (1, '00000000-0000-0000-0000-0000000000aa', p_type, private.paris_today(), 'raw-045-' || p_key, pg_temp.c(p_c),
          'document', 'e1000000-0000-0000-0000-000000000013', 'Écriture de test');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
  select 1, l.ord, l.v ->> 0, (l.v ->> 1)::bigint, 'EUR',
         case l.v ->> 0 when 'own_cash' then '80000000-0000-0000-0000-0000000000c0'::uuid end
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  perform private.ledger_post_set();
end $$;
grant execute on all functions in schema pg_temp to authenticated;


-- 045b's own helpers -------------------------------------------------------------------------------------------------
-- « Demander le remboursement » as p_user (ops 01 at aal2 by default) for client c's advances: its result, or its
-- error's message and detail. The total the sheet showed is the advances' open part now unless given.
create or replace function pg_temp.dra(p_key text, p_c text, p_advances uuid[], p_expected text default null,
                                       p_user text default '01', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb; v_msg text; v_detail text; v_exp text := p_expected;
begin
  if v_exp is null then
    v_exp := (select coalesce(sum(private.advance_open(a)), 0)::text from unnest(p_advances) a);
  end if;
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.request_advance_repayment('dra-045b-' || p_key, pg_temp.c(p_c), 'EUR', p_advances, v_exp);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
    v := jsonb_build_object('error', v_msg)
         || case when coalesce(v_detail, '') <> '' then jsonb_build_object('detail', v_detail) else '{}'::jsonb end;
  end;
  reset role;
  return v;
end $$;
-- a request's refusal code (or 'ok'; another error's message as it is)
create or replace function pg_temp.why_not(p_r jsonb) returns text language sql as $$
  select case when p_r ? 'error' then coalesce(substring(p_r ->> 'error' from 'repayment request refused: (\w+)'),
                                               p_r ->> 'error')
              else 'ok' end $$;
-- « Retirer la demande » as p_user (ops 01 at aal2 by default): its result, or its error's message
create or replace function pg_temp.wd(p_key text, p_request uuid, p_reason text default 'Le client conteste la somme (test)',
                                      p_user text default '01', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.withdraw_advance_repayment_request('wd-045b-' || p_key, p_request, p_reason);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- the request a result names
create or replace function pg_temp.rq(p_r jsonb) returns public.advance_repayment_request language sql as $$
  select q.* from public.advance_repayment_request q where q.id = (p_r ->> 'request_id')::uuid $$;
-- its payload's first row's origin
create or replace function pg_temp.origin(p_r jsonb) returns jsonb language sql as $$
  select q.payload -> 'rows' -> 0 -> 'origin' from public.advance_repayment_request q
  where q.id = (p_r ->> 'request_id')::uuid $$;
-- the advances the worker's prepare reads as requested for client c (private.client_requested_advances)
create or replace function pg_temp.requested(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(x.advance_id order by x.advance_id), '[]')
  from private.client_requested_advances(pg_temp.c(p_c), 'EUR') x $$;
-- a request's storage key, and the worker's job emulated: the object stored there, then the document recorded
create or replace function pg_temp.dra_path(p_request uuid) returns text language sql as $$
  select 'repayment-requests/' || q.organization_id || '/' || q.id || '.pdf'
  from public.advance_repayment_request q where q.id = p_request $$;
create or replace function pg_temp.drawn(p_request uuid, p_sha text default repeat('c', 64)) returns uuid
language plpgsql as $$
begin
  if not exists (select 1 from storage.objects o where o.bucket_id = 'documents' and o.name = pg_temp.dra_path(p_request))
  then
    insert into storage.objects (bucket_id, name) values ('documents', pg_temp.dra_path(p_request));
  end if;
  return private.repayment_request_document_done(p_request, p_sha, 'reportlab-test');
end $$;
-- (test only) a request's issue date or recording time moved (its guard set aside)
create or replace function pg_temp.dra_back(p_request uuid, p_issue date, p_created timestamptz default null)
returns void language plpgsql as $$
begin
  alter table public.advance_repayment_request disable trigger advance_repayment_request_guard;
  update public.advance_repayment_request set issue_date = p_issue, created_at = coalesce(p_created, created_at)
  where id = p_request;
  alter table public.advance_repayment_request enable always trigger advance_repayment_request_guard;
end $$;
-- advance a of client c taken by a run whose file was handed out (its plan names it; emulated as 045's taking, with no
-- claw-back clause: a draft prepared before the terms changed): the run
create or replace function pg_temp.sent_taking(p_c text, p_adv uuid, p_n text, p_s text) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending(p_c, p_n, 100000);
  v := pg_temp.request(p_c, 'tk-' || p_s);
  perform pg_temp.prepare_adv(v, jsonb_build_array(jsonb_build_array(p_adv, private.advance_open(p_adv)::text)));
  perform pg_temp.approve_plain(v, 'tk-' || p_s);
  perform pg_temp.handed_out('file-tk' || p_s, 'gen-file-tk' || p_s);
  return v;
end $$;
-- the rows of a code in a full pass of the advance checks as of p_today: [subject is p_subject, amount, details]
create or replace function pg_temp.adv_rows(p_code text, p_subject uuid, p_today date default null) returns jsonb
language plpgsql as $$
declare c uuid := pg_temp.adv_run(p_today, true);
begin
  return (select coalesce(jsonb_agg(jsonb_build_array(x.subject_id = p_subject, x.amount_minor, x.severity)
                                    order by x.amount_minor), '[]')
          from public.payment_check_result x where x.run_id = c and x.code = p_code);
end $$;
grant execute on all functions in schema pg_temp to authenticated;



-- 046a's own helpers --------------------------------------------------------------------------------------------------
-- each client's second status evidence (d…9<c>), its authority evidence (d…b<c>: the notary's attestation, the
-- judgment naming the tutor, curator or liquidator), two more RIBs (d…c<c>, d…e<c>)
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-000000000' || x.n || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa'::uuid,
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || x.c || '.pdf',
       repeat('a', 64), 'application/pdf'
from (select c, n, case n when '9' then 'client_status_evidence' when 'b' then 'payout_authority_evidence'
                          else 'payout_rib' end as kind
      from unnest(array['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']) c
      cross join unnest(array['9', 'b', 'c', 'e']) n) x;
-- (test only) the current account of client c confirmed p_ago before now (before every event a scenario plants)
create or replace function pg_temp.confirmed_ago(p_c text, p_ago interval default '1 day') returns void
language plpgsql as $$
begin
  alter table public.client_payout_account disable trigger client_payout_account_guard;
  update public.client_payout_account set confirmed_at = now() - p_ago
  where client_organization_id = pg_temp.c(p_c) and status in ('active', 'returned');
  alter table public.client_payout_account enable always trigger client_payout_account_guard;
end $$;
-- (test only) an account's confirmation moved to p_at
create or replace function pg_temp.confirmed_at(p_account uuid, p_at timestamptz) returns void language plpgsql as $$
begin
  alter table public.client_payout_account disable trigger client_payout_account_guard;
  update public.client_payout_account set confirmed_at = p_at where id = p_account;
  alter table public.client_payout_account enable always trigger client_payout_account_guard;
end $$;
-- an event of client c as the command records it (the table is append-only: inserted), recorded p_ago before now — a
-- command records every event of one transaction at the same now(), the confirmations too; the order matters here
create or replace function pg_temp.evt(p_c text, p_kind text, p_on date, p_ago interval default '2 hours',
                                       p_refers uuid default null) returns uuid language sql as $$
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, recorded_by, recorded_at, refers_to_event_id)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_c), p_kind, p_on, pg_temp.ev('8', p_c),
          '10000000-0000-0000-0000-000000000004', now() - p_ago, p_refers)
  returning id $$;
-- an old « Tutelle ou curatelle » row, as recorded before 7d-1 (qualified_at null: no command can write one since, so
-- the guard is set aside)
create or replace function pg_temp.old_tutelle(p_c text, p_on date, p_ago interval default '2 days') returns uuid
language plpgsql as $$
declare v uuid;
begin
  alter table public.client_status_event disable trigger client_status_event_guard;
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, recorded_by, recorded_at, qualified_at)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_c), 'guardianship', p_on, pg_temp.ev('8', p_c),
          '10000000-0000-0000-0000-000000000004', now() - p_ago, null)
  returning id into v;
  alter table public.client_status_event enable always trigger client_status_event_guard;
  return v;
end $$;
-- a person who acts for a client (synthetic names, one address)
create or replace function pg_temp.person(p_role text, p_name text default null) returns jsonb language sql as $$
  select jsonb_build_object(
    'role', p_role,
    'name', coalesce(p_name, case p_role when 'notary' then 'Me Claire Lenoir, notaire'
                                         when 'heirs' then 'Les héritiers de M. Martin'
                                         when 'tutor' then 'UDAF du Rhône'
                                         when 'curator' then 'Association Tutélaire de Lyon'
                                         when 'liquidator' then 'SELARL MJ Synergie'
                                         else 'SCP Administrateurs Associés' end),
    'address_lines', jsonb_build_array('3 place du Palais', '69002 Lyon')) $$;
-- a command's refusal code (« … refused: <code> »), 'ok' for a result, the message otherwise
create or replace function pg_temp.code(p_r jsonb) returns text language sql as $$
  select case when p_r ? 'error' then coalesce(substring(p_r ->> 'error' from 'refused: (\w+)'), p_r ->> 'error')
              else 'ok' end $$;
create or replace function pg_temp.eid(p_r jsonb) returns uuid language sql as $$
  select (p_r ->> 'client_status_event_id')::uuid $$;
create or replace function pg_temp.pid(p_r jsonb) returns uuid language sql as $$
  select (p_r ->> 'payout_account_id')::uuid $$;
-- « Enregistrer un événement » as p_user (admin 04 at aal2 by default): its result, or its error's message
create or replace function pg_temp.rec(p_key text, p_c text, p_kind text, p_on date, p_rep jsonb default null,
                                       p_refers uuid default null, p_declared jsonb default null,
                                       p_publication date default null, p_user text default '04',
                                       p_aal text default 'aal2', p_ev uuid default null)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.record_client_status_event('evt-046a-' || p_key, pg_temp.c(p_c), p_kind, p_on,
                                           coalesce(p_ev, pg_temp.ev('8', p_c)), 'Événement (test)', null,
                                           p_publication, p_rep, p_refers, p_declared);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Personne qui agit pour le client » as p_user (admin 04 at aal2): its result, or its error's message (the evidence:
-- the client's second status evidence unless given)
create or replace function pg_temp.rep(p_key text, p_event uuid, p_rep jsonb, p_ev uuid default null,
                                       p_user text default '04', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb; v_c text;
begin
  v_c := (select right(e.client_organization_id::text, 2) from public.client_status_event e where e.id = p_event);
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.set_client_representative('rep-046a-' || p_key, p_event, p_rep,
                                          coalesce(p_ev, pg_temp.ev('9', coalesce(v_c, 'a1'))));
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Préciser : tutelle ou curatelle » as p_user (admin 04 at aal2): its result, or its error's message
create or replace function pg_temp.qual(p_key text, p_event uuid, p_kind text, p_ev uuid default null,
                                        p_user text default '04', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb; v_c text;
begin
  v_c := (select right(e.client_organization_id::text, 2) from public.client_status_event e where e.id = p_event);
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.qualify_protection_event('qual-046a-' || p_key, p_event, p_kind,
                                         coalesce(p_ev, pg_temp.ev('9', coalesce(v_c, 'a1'))));
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Proposer un IBAN de reversement » as p_user (ops 01 at aal2): kind, holder, the authority document (the client's
-- d…b<c> unless p_auth is false), the explanation; its result, or its error's message
create or replace function pg_temp.propose(p_key text, p_c text, p_iban text, p_holder text,
                                           p_kind text default 'client', p_auth boolean default true,
                                           p_att text default null, p_user text default '01', p_rib text default 'c')
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  begin
    v := public.propose_payout_account('prop-046a-' || p_key, pg_temp.c(p_c), 'EUR', p_iban, p_holder, null,
                                       pg_temp.ev(p_rib, p_c), p_kind,
                                       case when p_auth then pg_temp.ev('b', p_c) end, p_att);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Confirmer l'IBAN » as p_user (admin 10 — a second admin: 01 and 04 propose — at aal2 unless said)
create or replace function pg_temp.confirm(p_key text, p_account uuid, p_user text default '10',
                                           p_aal text default 'aal2') returns jsonb language plpgsql as $$
declare v jsonb; v_iban text := (select a.iban from public.client_payout_account a where a.id = p_account);
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.confirm_payout_account('conf-046a-' || p_key, p_account, v_iban);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- proposed by ops and confirmed by the second admin: the account
create or replace function pg_temp.payee(p_key text, p_c text, p_iban text, p_holder text,
                                         p_kind text default 'client', p_auth boolean default true,
                                         p_att text default null) returns uuid language plpgsql as $$
declare r jsonb := pg_temp.propose(p_key, p_c, p_iban, p_holder, p_kind, p_auth, p_att);
begin
  if r ? 'error' then
    raise exception 'payee %: %', p_key, r ->> 'error';
  end if;
  r := pg_temp.confirm(p_key, pg_temp.pid(r));
  if r ? 'error' then
    raise exception 'payee % confirmed: %', p_key, r ->> 'error';
  end if;
  return pg_temp.pid(r);
end $$;
-- the payout blockers of client c (today unless said)
create or replace function pg_temp.blk(p_c text, p_on date default null) returns jsonb language sql as $$
  select to_jsonb(private.remittance_payout_blockers(pg_temp.c(p_c), 'EUR', coalesce(p_on, private.paris_today()))) $$;
-- who receives client c's letters today: [role, name, copy]
create or replace function pg_temp.addr(p_c text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(x.role, x.name, x.copy) order by x.copy, x.role), '[]')
  from private.client_addressee(pg_temp.c(p_c), private.paris_today()) x $$;
-- the seizures of client c standing on p_on, in effective order
create or replace function pg_temp.standing(p_c text, p_on date) returns uuid[] language sql as $$
  select coalesce(array_agg(x.id order by e.effective_date, e.id), '{}')
  from private.client_seizures_standing(pg_temp.c(p_c), p_on) x (id)
  join public.client_status_event e on e.id = x.id $$;
-- a payment of p_amount booked p_day on a new file n of client c, matched as the import's rules match it (the real
-- gate: private.record_assignments); its review reason ('ready' when none)
create or replace function pg_temp.match(p_c text, p_n text, p_amount bigint, p_day date) returns text
language plpgsql as $$
begin
  perform pg_temp.file(p_n, pg_temp.pf(p_c), p_amount);
  perform pg_temp.collect(p_n, p_amount, p_day, false);
  perform private.assign_begin();
  insert into pg_temp._assign (ord, payment_id, account_id, method, rule, rule_version)
  values (1, pg_temp.pay(p_n), pg_temp.f(p_n), 'rf_structured', 'R1', 'test');
  perform private.record_assignments('00000000-0000-0000-0000-0000000000aa', 'import', null, null);
  return coalesce((select p.review_reason from public.payment p where p.id = pg_temp.pay(p_n)), 'ready');
end $$;
-- « Reverser au client » as ops (01 at aal2) for payment n: its result, or its error's message
create or replace function pg_temp.fwd(p_key text, p_n text) returns jsonb language plpgsql as $$
declare v jsonb; v_left text := (select x.unallocated_minor::text from private.payment_positions(array[pg_temp.pay(p_n)]) x);
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  begin
    v := public.forward_payment('fwd-046a-' || p_key, pg_temp.pay(p_n), null, v_left, null,
                                'Reçu après la fin du mandat (test)');
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- the rows of a code in a full pass of the advance checks as of today: [subject is p_subject, p0]
create or replace function pg_temp.night(p_code text, p_subject uuid) returns jsonb language plpgsql as $$
declare c uuid := pg_temp.adv_run(null, true);
begin
  return (select coalesce(jsonb_agg(jsonb_build_array(x.subject_id = p_subject, coalesce((x.details ->> 'p0')::boolean,
                                                                                         false))
                                    order by x.subject_id = p_subject desc, x.oldest_days), '[]')
          from public.payment_check_result x where x.run_id = c and x.code = p_code);
end $$;
-- fresh valid IBANs (synthetic), by letter
create or replace function pg_temp.ib(p_k text) returns text language sql as $$
  select case p_k when 'A' then 'FR6430004424452125091990850' when 'B' then 'FR4330004853190879732321668'
                  when 'C' then 'FR4830004123377888003327207' when 'D' then 'FR6130004665100521708897211'
                  when 'E' then 'FR4730004568381038597033130' when 'F' then 'FR9730004118895820130478207'
                  when 'G' then 'FR2930004741158685814997780' when 'H' then 'FR7230004764140836534621773'
                  when 'I' then 'FR8330004767480599869698028' when 'J' then 'FR5030004061053922668714953'
                  when 'K' then 'FR3830004189071520713009273' when 'L' then 'FR1030004404332440401576413'
                  when 'M' then 'FR4230004762318835265008924' else 'FR8830004488107343290517091' end $$;
grant execute on all functions in schema pg_temp to authenticated;


-- 046b's own helpers ---------------------------------------------------------------------------------------------------
-- an invoice of client c for its collection n of p_amount collected on p_day (the claim's birth,
-- private.document_born_on), in a run (key inv-<s>) whose plan sets off p_take of it (VAT p_vat), approved today and
-- its payout debited yesterday on statement s; the invoice (the run kept as run-<s>)
create or replace function pg_temp.inv_on(p_c text, p_n text, p_amount bigint, p_s text, p_day date,
                                          p_take bigint default 0, p_vat bigint default 0) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount, p_day);
  v := pg_temp.runk(p_c, jsonb_build_object(p_n, p_amount::text), p_take, p_vat, 'inv-' || p_s);
  insert into t values ('run-' || p_s, v) on conflict (k) do update set v = excluded.v;
  perform pg_temp.debit(v, p_s);
  return (select i.id from public.commission_invoice i where i.run_id = v and i.kind = 'invoice');
end $$;
-- What the prepare job writes for a run that sets off earlier documents (emulated): its whole queue as lines (an
-- advance's item on its advance's mandate, as 044's), no commission, no documents; its plan settles each
-- {ref, kind (compensation | advance | refund), amount, vat} of p_settles, open_before the document's open part now;
-- D = Σ compensation + Σ advance − Σ refund, Dc and Da apart, N = gross − D. No set-off state written (as before 7d-2):
-- pg_temp.draft_state writes what 7d-2's prepare writes.
create or replace function pg_temp.prepare_set(p_run uuid, p_settles jsonb) returns integer language plpgsql as $$
declare r public.remittance_run; v_gross bigint; v_settles jsonb; v_d bigint; v_dc bigint; v_da bigint; v_v bigint; v_rf bigint;
        v_plan jsonb;
begin
  select * into r from public.remittance_run where id = p_run;
  perform private.remittance_prepare_begin(p_run, r.job_token);
  insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind, account_id, mandate_id,
                                             mandate_terms_id, payment_id, encaissement_date, effective_date, posted_at,
                                             deadline, latest_execution_date, amount_minor, basis, commission_minor,
                                             commission_state, parts, invoiced)
  select p_run, row_number() over (order by q.posted_at, q.ledger_entry_id), q.ledger_entry_id, q.kind, e.account_id,
         coalesce(pf.mandate_id, case when ca.cause = 'remitted_reversal' then ca.mandate_id end),
         case when pf.mandate_id is not null
              then ('71000000-0000-0000-0000-0000000000' || right(pf.mandate_id::text, 2))::uuid end,
         e.payment_id, e.effective_date, e.effective_date, q.posted_at,
         case when q.amount_minor > 0 and q.kind in ('allocation', 'forward') then e.effective_date + 30 end,
         case when q.amount_minor > 0 and q.kind in ('allocation', 'forward') then e.effective_date + 27 end,
         q.amount_minor, jsonb_build_object('principal', q.amount_minor::text), 0, 'none', '[]', false
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  left join public.account a on a.id = e.account_id
  left join public.portfolio pf on pf.id = a.portfolio_id
  left join public.client_advance ca on ca.entry_id = case q.kind when 'client_advance' then e.id
                                                                  when 'client_advance_reversal' then e.reverses_entry_id end
  where q.draft_run_id = p_run;
  v_gross := (select sum(amount_minor) from private.remittance_draft_line where run_id = p_run);
  select coalesce(jsonb_agg(jsonb_build_object(
           'ref', x.v ->> 'ref', 'kind', x.v ->> 'kind',
           'mandate_id', coalesce((select i.mandate_id::text from public.commission_invoice i
                                   where i.id = (x.v ->> 'ref')::uuid),
                                  (select a.mandate_id::text from public.client_advance a
                                   where a.id = (x.v ->> 'ref')::uuid)),
           'amount', x.v ->> 'amount', 'vat_moved', coalesce(x.v ->> 'vat', '0'),
           'open_before', private.document_open((x.v ->> 'ref')::uuid)::text) order by x.n), '[]'),
         coalesce(sum(case x.v ->> 'kind' when 'refund' then -1 else 1 end * (x.v ->> 'amount')::bigint), 0),
         coalesce(sum(case x.v ->> 'kind' when 'compensation' then 1 when 'refund' then -1 else 0 end
                      * (x.v ->> 'amount')::bigint), 0),
         coalesce(sum(case x.v ->> 'kind' when 'advance' then (x.v ->> 'amount')::bigint else 0 end), 0),
         coalesce(sum(coalesce((x.v ->> 'vat')::bigint, 0)), 0),
         -- (review round 1, TUI-2) the refunds the plan pays, in the header as the prepare writes them
         coalesce(sum(case x.v ->> 'kind' when 'refund' then (x.v ->> 'amount')::bigint else 0 end), 0)
  into v_settles, v_d, v_dc, v_da, v_v, v_rf
  from jsonb_array_elements(p_settles) with ordinality x (v, n);
  v_plan := jsonb_build_object('settles', v_settles, 'net', (v_gross - v_d)::text, 'settlement', v_d::text,
                               'dc', v_dc::text, 'da', v_da::text, 'vat_moved', v_v::text, 'deferred', v_d = 0);
  perform private.remittance_record_draft(p_run, r.job_token, jsonb_build_object(
    'line_count', (select count(*) from private.remittance_draft_line where run_id = p_run),
    'gross', v_gross::text,
    'invoice_ht', '0', 'invoice_vat', '0', 'invoice_ttc', '0', 'credit_ht', '0', 'credit_vat', '0', 'credit_ttc', '0',
    'taken', v_dc::text, 'advances', v_da::text, 'refunds', v_rf::text, 'settlement', v_d::text,
    'net', (v_gross - v_d)::text, 'vat_rate', '0.2',
    'earliest_deadline', (select min(deadline) from private.remittance_draft_line where run_id = p_run),
    'earliest_latest_execution_date', (select min(latest_execution_date) from private.remittance_draft_line
                                       where run_id = p_run),
    'unmeetable', 0, 'blockers', '[]'::jsonb, 'commission_blockers', '[]'::jsonb, 'engine_version', 'commission-1',
    'inputs_hash', encode(sha256(convert_to(p_run::text || v_plan::text, 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', '[]'::jsonb, 'key_states', '[]'::jsonb, 'plan', v_plan));
  return (select version from public.remittance_run where id = p_run);
end $$;
-- what 7d-2's prepare writes of the client's status into the draft (the opening and the bars of the day), as the job
-- reads them (private.client_opening_date, private.client_set_off_bars)
create or replace function pg_temp.draft_state(p_run uuid) returns void language plpgsql as $$
declare c uuid := (select client_organization_id from public.remittance_run where id = p_run);
        d date := private.paris_today();
begin
  update private.remittance_draft
  set proceeding_opened_on = private.client_opening_date(c, d), opening_on = private.client_opening_date(c, d),
      set_off_barred = private.client_set_off_bars(c, d)
  where run_id = p_run;
end $$;
-- a settle of p_settles
create or replace function pg_temp.st(p_ref uuid, p_kind text, p_amount bigint, p_vat bigint default 0) returns jsonb
language sql as $$
  select jsonb_build_object('ref', p_ref, 'kind', p_kind, 'amount', p_amount::text, 'vat', p_vat::text) $$;
-- a run's refusal at approval: [status, code]
create or replace function pg_temp.refused(p_run uuid) returns jsonb language sql as $$
  select jsonb_build_array(r.status, r.last_failure ->> 'code') from public.remittance_run r where r.id = p_run $$;
-- a run's settlements [[document kind, document is p_doc…, kind, amount, VAT moved]] in their order (the document by its
-- position in p_docs: 0-based, -1 when it is none of them)
create or replace function pg_temp.run_sets(p_run uuid, p_docs uuid[]) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(s.document_kind, coalesce(array_position(p_docs, s.document_id) - 1, -1),
                                              s.kind, s.amount_minor, s.vat_moved_minor) order by s.id), '[]')
  from public.commission_settlement s where s.run_id = p_run $$;
-- (review round 1) the run page's withheld set-off as ops read it: [W, its invoices' part, its advances' part, the refund
-- not paid, what the debit set off of invoices, the booked run that gave W back, the run in flight giving it back]
create or replace function pg_temp.withheld_read(p_run uuid) returns jsonb language sql as $$
  select jsonb_build_array(r ->> 'withheld_minor', r ->> 'commission_minor', r ->> 'advances_minor',
                           r ->> 'refund_unpaid_minor', r ->> 'set_off_commission_minor', r ->> 'given_back_by',
                           r ->> 'giving_back_by')
  from (select pg_temp.read_as('01', format('select public.remittance_run_withheld(%L)', p_run)) as r) z $$;
-- a planted barred settlement of run p_run for client c (lines +4670 / −4679 ‖ +4689 / −4111 of p_amount), never
-- reversed: what only a bug could leave; the entry
create or replace function pg_temp.plant_barred(p_run uuid, p_c text, p_amount bigint) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'client_settlement', private.paris_today(),
          'settle:' || p_run || ':barred', pg_temp.c(p_c), 'remittance_run', p_run::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency) values
    (1, 1, 'client_payable', p_amount, 'EUR'), (1, 2, 'due_to_servicer', -p_amount, 'EUR'),
    (1, 3, 'due_from_client_funds', p_amount, 'EUR'), (1, 4, 'commission_receivable', -p_amount, 'EUR');
  select x.entry_id into v from private.ledger_post_set() x;
  return v;
end $$;
-- the reversal of p_entry under key p_key (today), as a SQLSTATE ('ok' when posted), rolled back
create or replace function pg_temp.rev_as(p_entry uuid, p_key text) returns text language sql as $$
  select pg_temp.state(format('select private.ledger_reverse(%L, %L, %L, %L)', p_entry, p_key,
                              'Retour (test)', private.paris_today())) $$;
grant execute on all functions in schema pg_temp to authenticated;


-- b. The bars (§6.2.2, §6.2.4–§6.2.6) -----------------------------------------------------------------------------------
-- per client and day: client_set_off_barred(invoice), (advance), client_set_off_bars (the draft's text),
-- client_opening_date. None; a redressement (advances only); a liquidation recorded alone (both, and the opening:
-- carried from 7c-1); a death and a mandate end (both); a standing seizure (both), released the day it is effective; the
-- order liquidation > mandate end > seizure > proceeding
create or replace function pg_temp.sb1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); s uuid; w jsonb := '[]'; v jsonb; c uuid; o date;
begin
  perform pg_temp.evt('a2', 'proceeding_opened', d - 6);
  perform pg_temp.evt('a3', 'liquidation', d - 5);
  perform pg_temp.evt('a4', 'death', d - 5);
  perform pg_temp.evt('a5', 'mandate_ended', d - 5);
  s := pg_temp.evt('a6', 'seizure', d - 4);
  perform pg_temp.evt('a6', 'seizure_released', d - 2, '1 hour', s);
  perform pg_temp.evt('a7', 'seizure', d - 4);
  perform pg_temp.evt('a7', 'liquidation', d - 3);
  perform pg_temp.evt('a8', 'seizure', d - 4);
  perform pg_temp.evt('a8', 'death', d - 3);
  perform pg_temp.evt('a9', 'proceeding_opened', d - 6);
  perform pg_temp.evt('a9', 'seizure', d - 4);
  -- [client, the day (d − n), the opening expected (d − m), or null]
  foreach v in array array[
      '["a1", 0, null]', '["a2", 7, null]', '["a2", 6, 6]', '["a3", 5, 5]', '["a4", 5, null]', '["a5", 5, null]',
      '["a6", 3, null]', '["a6", 2, null]', '["a7", 0, 3]', '["a8", 0, null]', '["a9", 0, 6]']::jsonb[] loop
    c := pg_temp.c(v ->> 0);
    o := d - (v ->> 1)::integer;
    w := w || jsonb_build_array(jsonb_build_array(
      (v ->> 0) || '@-' || (v ->> 1), private.client_set_off_barred(c, o, 'invoice'),
      private.client_set_off_barred(c, o, 'advance'), private.client_set_off_bars(c, o),
      private.client_opening_date(c, o) is not distinct from d - (v ->> 2)::integer));
  end loop;
  return w;
end $$;
select is(pg_temp.iso('sb1'),
  '[["a1@-0", null, null, null, true],
    ["a2@-7", null, null, null, true],
    ["a2@-6", null, "proceeding", "-/proceeding", true],
    ["a3@-5", "liquidation", "liquidation", "liquidation/liquidation", true],
    ["a4@-5", "mandate_ended", "mandate_ended", "mandate_ended/mandate_ended", true],
    ["a5@-5", "mandate_ended", "mandate_ended", "mandate_ended/mandate_ended", true],
    ["a6@-3", "seizure", "seizure", "seizure/seizure", true],
    ["a6@-2", null, null, null, true],
    ["a7@-0", "liquidation", "liquidation", "liquidation/liquidation", true],
    ["a8@-0", "mandate_ended", "mandate_ended", "mandate_ended/mandate_ended", true],
    ["a9@-0", "seizure", "seizure", "seizure/seizure", true]]'::jsonb,
  'b: the bars per kind and day — none; a redressement bars advances only, from its date; a liquidation recorded alone '
  'bars both and opens the procedure (carried from 7c-1); a death or a mandate end bars both; a seizure while it '
  'stands (not from its release''s date); the order liquidation, end, seizure, proceeding');

-- each claim's birth (§6.2.4; default OQ-92): an invoice issued today for collections of d − 12 is born d − 12 (and so
-- before an opening of d − 6: document_before_opening reads the birth, never the issue date — the old criterion's
-- mutant); one for collections of d − 4 after it; an advance by its birth; a credit note by its issue; document_nettable
-- (§6.2.6) and document_client_payable (gap 11: an advance while a proceeding stands, whatever its birth)
create or replace function pg_temp.sb2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f6 uuid; f8 uuid; a public.client_advance; cn uuid; w jsonb;
begin
  f6 := pg_temp.inv_on('a2', '61', 200000, '610', d - 12);
  f8 := pg_temp.inv_on('a2', '62', 200000, '620', d - 4);
  a := pg_temp.adv('a2', '63', 50000, '630');
  perform pg_temp.as_user('04');
  set local role authenticated;
  cn := (public.issue_credit_note('cn-046b-b2', f8, '10,00', 'terms_error', 'taux erroné (test)', '30000')
         ->> 'credit_note_id')::uuid;
  reset role;
  w := jsonb_build_object(
    'born', jsonb_build_array(private.document_born_on(f6) = d - 12, private.document_born_on(f8) = d - 4,
                              private.document_born_on(a.id) = private.advance_born_on(a.id),
                              private.document_born_on(cn) = d, private.document_born_on(gen_random_uuid())),
    'issued_today', (select bool_and(i.issue_date = d) from public.commission_invoice i where i.id in (f6, f8)),
    'before_any', jsonb_build_array(private.document_before_opening(f6, d), private.document_nettable(f6, d),
                                    private.document_nettable(a.id, d), private.document_client_payable(a.id, d)));
  perform pg_temp.evt('a2', 'proceeding_opened', d - 6);
  return w || jsonb_build_object(
    'before_opening', jsonb_build_array(private.document_before_opening(f6, d), private.document_before_opening(f8, d),
                                        private.document_before_opening(a.id, d)),
    'nettable', jsonb_build_array(private.document_nettable(f6, d), private.document_nettable(f8, d),
                                  private.document_nettable(a.id, d), private.document_nettable(cn, d),
                                  private.document_nettable(f6, d - 7)),
    'payable', jsonb_build_array(private.document_client_payable(f6, d), private.document_client_payable(f8, d),
                                 private.document_client_payable(a.id, d), private.document_client_payable(a.id, d - 7)));
end $$;
select is(pg_temp.iso('sb2'),
  '{"born": [true, true, true, true, null], "issued_today": true,
    "before_any": [false, true, true, true],
    "before_opening": [true, false, false],
    "nettable": [false, true, false, true, true],
    "payable": [false, true, false, true]}'::jsonb,
  'b: a claim is born at the earliest collection its invoice charges (FC issued today for d − 12 is before an opening '
  'of d − 6, the one for d − 4 is not), an advance at its birth; not nettable before the opening, nor an advance while '
  'the proceeding stands (born after it too: L4), and the client may not pay that advance (gap 11); a credit note '
  'still applies; none of it before the opening''s date');


-- r. How an advance is recovered (carried from 7c-1 rounds 2–3: the claw-back read proceeding_opened only) ------------
-- advance_recovery_of for a claw-back clause's mandate: no event → clawback; a redressement (an advance born after it
-- too) and a liquidation recorded alone → barred_proceeding; a mandate end and a standing seizure → request (the clause
-- no longer, or not now, applies: founder Q9, Q12); the seizure released → clawback; no clause in a proceeding →
-- barred_proceeding
create or replace function pg_temp.sr1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); s uuid; w jsonb := '[]';
  c text;
begin
  foreach c in array array['a1', 'a2', 'a3', 'a4', 'a5'] loop
    perform pg_temp.clawback(c, 'art. 7.4');
  end loop;
  perform pg_temp.evt('a2', 'proceeding_opened', d - 6);
  perform pg_temp.evt('a3', 'liquidation', d - 6);
  perform pg_temp.evt('a4', 'mandate_ended', d - 1);
  s := pg_temp.evt('a5', 'seizure', d - 1);
  perform pg_temp.evt('a6', 'proceeding_opened', d - 6);
  foreach c in array array['a1', 'a2', 'a3', 'a4', 'a5', 'a6'] loop
    w := w || (select jsonb_build_array(jsonb_build_array(c, r.recovery, r.clause_ref))
               from private.advance_recovery_of(pg_temp.mandate(c), pg_temp.c(c), d - 2, d) r);
  end loop;
  perform pg_temp.evt('a5', 'seizure_released', d, '1 minute', s);
  return w || (select jsonb_build_array(jsonb_build_array('a5 released', r.recovery, r.clause_ref))
               from private.advance_recovery_of(pg_temp.mandate('a5'), pg_temp.c('a5'), d - 2, d) r);
end $$;
select is(pg_temp.iso('sr1'),
  '[["a1", "clawback", "art. 7.4"], ["a2", "barred_proceeding", null], ["a3", "barred_proceeding", null],
    ["a4", "request", null], ["a5", "request", null], ["a6", "barred_proceeding", null],
    ["a5 released", "clawback", "art. 7.4"]]'::jsonb,
  'r: with a claw-back clause, an advance born after a redressement, or a liquidation recorded alone, is barred (no '
  'run takes it); after a mandate end or under a seizure it is requested, the seizure released the clause applies again');


-- q. The request (L4) and the client's payment (gap 11) ---------------------------------------------------------------
-- Lilas's advance born d − 2 (no claw-back clause): a redressement opened d − 6 → request refused in_proceeding; opened
-- d − 1 (the advance before it) → before_opening, as 7c-2. Its post-opening invoice (d − 4) and the advance: 500,00 €
-- with no designation pay the invoice only, the rest held for the procedure; designated, the advance is held too, never
-- settled
create or replace function pg_temp.sq1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); a public.client_advance; f8 uuid; e uuid; r jsonb; w jsonb;
begin
  f8 := pg_temp.inv_on('a2', '62', 200000, '620', d - 4);
  a := pg_temp.adv('a2', '63', 50000, '630');
  e := pg_temp.evt('a2', 'proceeding_opened', d - 6);
  w := jsonb_build_object('request', pg_temp.dra('q1', 'a2', array[a.id]) ->> 'error');
  r := pg_temp.cpay('q2', 'a2', '500,00');
  w := w || jsonb_build_object(
    'default', jsonb_build_array(pg_temp.sets(f8), pg_temp.sets(a.id), pg_temp.ccs('a2')),
    'designated', pg_temp.cpay('q3', 'a2', '200,00', p_docs => array[a.id], p_desig => pg_temp.ev('7', 'a2'))
                    -> 'credits');
  return w || jsonb_build_object('advance_open', private.advance_open(a.id));
end $$;
select is(pg_temp.iso('sq1'),
  '{"request": "repayment request refused: in_proceeding",
    "default": [[["payment_own", 36000, 6000]], [], [["procedure", 14000, 14000]]],
    "designated": [{"cause": "procedure", "amount_minor": "20000"}], "advance_open": 50000}'::jsonb,
  'q: an advance born after the client''s redressement is neither requested (in_proceeding, L4) nor paid by the '
  'client''s money: the default order skips it, a designated payment of it is held for the procedure (gap 11)');
create or replace function pg_temp.sq2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); a public.client_advance;
begin
  a := pg_temp.adv('a2', '63', 50000, '630');
  perform pg_temp.evt('a2', 'proceeding_opened', d - 1);
  return jsonb_build_object('request', pg_temp.dra('q4', 'a2', array[a.id]) ->> 'error');
end $$;
select is(pg_temp.iso('sq2'), '{"request": "repayment request refused: before_opening"}'::jsonb,
  'q: an advance born before the opening is still refused before_opening (7c-2), not in_proceeding');


-- a. The approval (§6.2.9) ---------------------------------------------------------------------------------------------
-- [critic] L14: a seizure standing, an N = 0 run (every collection set off: 046a sp9's case) → refused
-- payout_blocked:client_status:seizure, nothing set off; released before the prepare → approved with its set-off; two
-- seizures, one released → still refused
create or replace function pg_temp.sa1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); v uuid; s uuid; s2 uuid; w jsonb;
begin
  s := pg_temp.evt('a8', 'seizure', d - 2);
  perform pg_temp.pending('a8', '8b', 150000);
  v := pg_temp.request('a8', 'k046b-draft-run-8b');
  perform pg_temp.prepare_off(v, 'a8', '8b', 5, 6);
  w := jsonb_build_object('standing', jsonb_build_array(pg_temp.approve_plain(v, 'k046b-approve-run-8b'), pg_temp.refused(v),
                                                        pg_temp.run_sets(v, '{}')));
  perform pg_temp.evt('a8', 'seizure_released', d - 1, '1 hour', s);
  s2 := pg_temp.evt('a9', 'seizure', d - 3);
  perform pg_temp.evt('a9', 'seizure', d - 2);
  perform pg_temp.evt('a9', 'seizure_released', d - 1, '1 hour', s2);
  return w;
end $$;
create or replace function pg_temp.sa1b() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); v uuid; v2 uuid; s uuid; s2 uuid;
begin
  s := pg_temp.evt('a8', 'seizure', d - 2, '3 hours');
  perform pg_temp.evt('a8', 'seizure_released', d - 1, '2 hours', s);
  perform pg_temp.pending('a8', '8b', 150000);
  v := pg_temp.request('a8', 'k046b-draft-run-8b');
  perform pg_temp.prepare_off(v, 'a8', '8b', 5, 6);
  perform pg_temp.draft_state(v);
  s2 := pg_temp.evt('a9', 'seizure', d - 3, '3 hours');
  perform pg_temp.evt('a9', 'seizure', d - 2, '3 hours');
  perform pg_temp.evt('a9', 'seizure_released', d - 1, '2 hours', s2);
  perform pg_temp.pending('a9', '9b', 150000);
  v2 := pg_temp.request('a9', 'k046b-draft-run-9b');
  perform pg_temp.prepare_off(v2, 'a9', '9b', 5, 6);
  return jsonb_build_object(
    'released', jsonb_build_array(pg_temp.approve_plain(v, 'k046b-approve-run-8b'), pg_temp.run_sets(v, '{}')),
    'one_of_two_released', jsonb_build_array(pg_temp.approve_plain(v2, 'k046b-approve-run-9b'), pg_temp.refused(v2)));
end $$;
select is(pg_temp.iso('sa1'),
  '{"standing": ["back_to_draft:draft", ["draft", "payout_blocked:client_status:seizure"], []]}'::jsonb,
  'a (L14): an N = 0 run under a standing seizure is refused payout_blocked:client_status:seizure whatever N — nothing '
  'set off (046a sp9''s pin, changed: R3)');
select is(pg_temp.iso('sa1', true), pg_temp.iso('sa1'), 'a (L14): the same with the switch on');
select is(pg_temp.iso('sa1b'),
  '{"released": ["booked:booked", [["invoice", -1, "compensation", 150000, 25000]]],
    "one_of_two_released": ["back_to_draft:draft", ["draft", "payout_blocked:client_status:seizure"]]}'::jsonb,
  'a (L14): released before the prepare, the N = 0 run is approved with its set-off; two seizures, one released, still '
  'refuse it');

-- client_status_changed (§6.2.9): a liquidation recorded alone after the prepare (carried from 7c-1: the opening is
-- client_opening_date's); a redressement after the prepare with a post-opening invoice planned (the bars differ from
-- the draft's); the same state as the draft's: approved; the draft's state equal but a pre-opening invoice planned (the
-- plan itself re-read); (L1) the run's own new invoice born before the opening, netted by the plan
create or replace function pg_temp.sa2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; v uuid; w jsonb := '{}';
begin
  -- liquidation alone after the prepare
  f := pg_temp.inv_on('a2', '21', 200000, '210', d - 12);
  perform pg_temp.pending('a2', '22', 100000);
  v := pg_temp.request('a2', 'k046b-sa2-1');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  perform pg_temp.evt('a2', 'liquidation', d - 1, '1 minute');
  w := w || jsonb_build_object('liquidation_alone', jsonb_build_array(pg_temp.approve_plain(v, 'k046b-sa2-1'),
                                                                      pg_temp.refused(v)));
  -- a redressement after the prepare, a post-opening invoice planned
  f := pg_temp.inv_on('a3', '31', 200000, '310', d - 4);
  perform pg_temp.pending('a3', '32', 100000);
  v := pg_temp.request('a3', 'k046b-sa2-2');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  perform pg_temp.evt('a3', 'proceeding_opened', d - 6, '1 minute');
  w := w || jsonb_build_object('bars_differ', jsonb_build_array(pg_temp.approve_plain(v, 'k046b-sa2-2'), pg_temp.refused(v)));
  -- the same, prepared after the event: the same state, approved
  f := pg_temp.inv_on('a4', '41', 200000, '410', d - 4);
  perform pg_temp.pending('a4', '42', 100000);
  perform pg_temp.evt('a4', 'proceeding_opened', d - 6, '10 minutes');
  v := pg_temp.request('a4', 'k046b-sa2-3');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  w := w || jsonb_build_object('same_state', jsonb_build_array(pg_temp.approve_plain(v, 'k046b-sa2-3'), pg_temp.refused(v)));
  -- the draft's state equal, a pre-opening invoice planned
  f := pg_temp.inv_on('a5', '51', 200000, '510', d - 12);
  perform pg_temp.pending('a5', '52', 100000);
  perform pg_temp.evt('a5', 'proceeding_opened', d - 6, '10 minutes');
  v := pg_temp.request('a5', 'k046b-sa2-4');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  w := w || jsonb_build_object('barred_planned', jsonb_build_array(pg_temp.approve_plain(v, 'k046b-sa2-4'),
                                                                   pg_temp.refused(v)));
  -- (L1) the run's own invoice, its collection d − 3, the opening d − 2 known to the prepare: netted by the plan
  perform pg_temp.evt('a6', 'proceeding_opened', d - 2, '10 minutes');
  perform pg_temp.pending('a6', '6b', 150000);
  v := pg_temp.request('a6', 'k046b-sa2-5');
  perform pg_temp.prepare_off(v, 'a6', '6b', 5, 6);
  perform pg_temp.draft_state(v);
  return w || jsonb_build_object('new_invoice_before_opening',
                                 jsonb_build_array(pg_temp.approve_plain(v, 'k046b-sa2-5'), pg_temp.refused(v)));
end $$;
select is(pg_temp.iso('sa2'),
  '{"liquidation_alone": ["back_to_draft:draft", ["draft", "client_status_changed"]],
    "bars_differ": ["back_to_draft:draft", ["draft", "client_status_changed"]],
    "same_state": ["approved:approved", ["approved", null]],
    "barred_planned": ["back_to_draft:draft", ["draft", "client_status_changed"]],
    "new_invoice_before_opening": ["back_to_draft:draft", ["draft", "client_status_changed"]]}'::jsonb,
  'a: sent back client_status_changed when a liquidation recorded alone opens the procedure after the prepare, when the '
  'bars differ from the draft''s, when the plan sets off a document barred today, and (L1) the run''s own invoice born '
  'before the opening; the draft''s own state passes');


-- (review round 1, MLAW-1; plan §6.2.4 [critic] L1, OQ-92) the run's own invoice also reprices an earlier run's line
-- whose commission was left pending: RV-A's collection of d − 12 (approved and debited before the client's redressement,
-- effective d − 8), priced now on RV-B's invoice with RV-B's collection of d − 3. That invoice is born d − 12, as
-- private.document_born_on counts it (its repricings), so before the opening: (a) a draft that sets it off with N = 0
-- is sent back client_status_changed, nothing settled; (b) one that sets part of it off with N > 0 is sent back too —
-- never approved to be held at the file, then repriced onto the next run's invoice; (c) (TUI-4) the draft as the
-- prepare now writes it (the invoice due, its procedure's payment line, nothing of it set off) is approved: the invoice
-- is issued due with that payment note and no « par compensation » reference, born d − 12, and its payout is not held
create or replace function pg_temp.repriced_run(p_c text, p_s text, p_docs jsonb, p_plan jsonb) returns uuid
language plpgsql as $$
declare d date := private.paris_today(); v0 uuid; v1 uuid; e0 uuid;
begin
  perform pg_temp.pending(p_c, p_s || '0', 100000, d - 12);
  v0 := pg_temp.request(p_c, 'k046b-sa3-' || p_s || '-0');
  perform pg_temp.prepare_plain(v0);
  update private.remittance_draft_line set commission_state = 'pending', commission_reason = 'commission_input_error: test'
  where run_id = v0;
  perform pg_temp.approve_plain(v0, 'k046b-sa3-' || p_s || '-0');
  perform pg_temp.debit(v0, p_s || '30');
  perform pg_temp.evt(p_c, 'proceeding_opened', d - 8, '10 minutes');
  perform pg_temp.pending(p_c, p_s || '1', 10000, d - 3);
  v1 := pg_temp.request(p_c, 'k046b-sa3-' || p_s || '-1');
  perform pg_temp.prepare(v1, p_docs, pg_temp.keys(p_c, jsonb_build_object(p_s || '1', '10000'), 165, 100), p_plan);
  select l.ledger_entry_id into e0 from public.remittance_line l where l.run_id = v0 and l.line_no = 1;
  insert into private.remittance_draft_repricing (run_id, line_run_id, line_no, ledger_entry_id, commission_minor,
                                                  commission_state, commission_reason, parts, invoiced)
  values (v1, v0, 1, e0, 15000, 'charged', null, '[]', true);
  perform pg_temp.draft_state(v1);
  return v1;
end $$;
create or replace function pg_temp.sa3() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); v uuid; inv uuid; w jsonb := '{}';
        v_note jsonb := jsonb_build_object('text', 'Créance née avant l''ouverture de la procédure collective du client '
                                                   || '(jugement du ' || to_char(d - 8, 'DD/MM/YYYY') || ') : à déclarer '
                                                   || 'au mandataire judiciaire (au liquidateur en liquidation) ; ni payée '
                                                   || 'ni compensée hors de la procédure.', 'pay', false);
begin
  -- (a) N = 0: the invoice netted in full
  v := pg_temp.repriced_run('a2', 'a', pg_temp.doc('a2', '{"a1": "10000"}', 165, 100),
                            pg_temp.plan('a2', 10000, 16500, 10000, 1666));
  w := w || jsonb_build_object('n0', jsonb_build_array(
    (select r.net_minor from public.remittance_run r where r.id = v), pg_temp.approve_plain(v, 'k046b-sa3-a-1'),
    pg_temp.refused(v), pg_temp.run_sets(v, '{}'),
    (select count(*) from public.commission_invoice i where i.run_id = v)));
  -- (b) N > 0: part of it netted
  v := pg_temp.repriced_run('a3', 'b', pg_temp.doc('a3', '{"b1": "10000"}', 165, 100),
                            pg_temp.plan('a3', 10000, 16500, 5000, 833));
  w := w || jsonb_build_object('n_pos', jsonb_build_array(
    (select r.net_minor from public.remittance_run r where r.id = v), pg_temp.approve_plain(v, 'k046b-sa3-b-1'),
    pg_temp.refused(v), pg_temp.run_sets(v, '{}')));
  -- (c) the prepare's draft: due, the procedure's payment line, nothing of it set off
  v := pg_temp.repriced_run('a4', 'c',
                            jsonb_build_array((pg_temp.doc('a4', '{"c1": "10000"}', 165, 100) -> 0)
                                              || jsonb_build_object('settlement', 'due', 'due_days', 30,
                                                                    'payment_note', v_note)),
                            pg_temp.plan('a4', 10000, 16500, 0, 0));
  w := w || jsonb_build_object('due_approval', pg_temp.approve_plain(v, 'k046b-sa3-c-1'));
  select i.id into inv from public.commission_invoice i where i.run_id = v and i.kind = 'invoice';
  return w || jsonb_build_object('due', (select jsonb_build_array(
    i.settlement, i.payload -> 'payment_note' = v_note, i.payload -> 'settlement' ->> 'mode', i.payload -> 'payment_reference',
    i.payload::text like '%compensation%', jsonb_typeof(i.payload -> 'own_account') = 'object', i.due_date - i.issue_date,
    private.document_born_on(i.id) - d, private.document_nettable(i.id, d),
    private.transfer_hold_reason(pg_temp.rtransfer(v), d, d, null), pg_temp.run_sets(v, '{}'))
    from public.commission_invoice i where i.id = inv));
end $$;
select is(pg_temp.iso('sa3'),
  '{"n0": [0, "back_to_draft:draft", ["draft", "client_status_changed"], [], 0],
    "n_pos": [5000, "back_to_draft:draft", ["draft", "client_status_changed"], []],
    "due_approval": "approved:approved",
    "due": ["due", true, "due", null, false, true, 30, -12, false, null, []]}'::jsonb,
  'a (review round 1, MLAW-1): the run''s own invoice repricing an earlier run''s line collected before the opening is '
  'born then — a draft netting it is sent back client_status_changed whatever N, nothing settled; (TUI-4) the prepare''s '
  'draft (due, its procedure''s payment line) is approved, the invoice issued due with that note and no set-off '
  'reference, its payout not held');
select is(pg_temp.iso('sa3', true), pg_temp.iso('sa3'), 'a (MLAW-1, TUI-4): the same with the switch on');


-- h. The hold before download (§6.2.11 (b)) ------------------------------------------------------------------------------
-- Durand's run approved with a pre-opening invoice planned; the redressement recorded after the approval → its payout is
-- held client_status_changed, left out of the file (ordered); before the event nothing held; a run setting nothing off
-- is never held for it
create or replace function pg_temp.sh1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; v uuid; v2 uuid; w jsonb;
begin
  f := pg_temp.inv_on('a7', '71', 200000, '710', d - 12);
  perform pg_temp.pending('a7', '72', 100000);
  v := pg_temp.request('a7', 'k046b-sh1');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046b-sh1');
  perform pg_temp.pending('a6', '6c', 100000);
  v2 := pg_temp.flight('a6', 'sh1-b');
  w := jsonb_build_object('before', private.transfer_hold_reason(pg_temp.rtransfer(v), d, d, null));
  perform pg_temp.evt('a7', 'proceeding_opened', d - 6, '1 minute');
  perform pg_temp.evt('a6', 'proceeding_opened', d - 6, '1 minute');
  perform pg_temp.gen('01', 'gen-file-sh1');
  return w || jsonb_build_object(
    'held', private.transfer_hold_reason(pg_temp.rtransfer(v), d, d, null),
    'status', pg_temp.status(pg_temp.rtransfer(v)),
    'nothing_set_off', private.transfer_hold_reason(pg_temp.rtransfer(v2), d, d, null),
    'nothing_set_off_status', pg_temp.status(pg_temp.rtransfer(v2)));
end $$;
select is(pg_temp.iso('sh1'),
  '{"before": null, "held": "client_status_changed", "status": "ordered", "nothing_set_off": null,
    "nothing_set_off_status": "in_file"}'::jsonb,
  'h: a payout whose run sets off what a redressement recorded since bars is held client_status_changed (not in the '
  'file); one setting nothing off goes in the file');
select is(pg_temp.iso('sh1', true), pg_temp.iso('sh1'), 'h: the same with the switch on');


-- w. The withholding at the debit (§6.2.11 (a), [check 1] gap 1) --------------------------------------------------------
-- (i) Lilas: FC-6 (born d − 12), FC-8 (born d − 4), A2 (born d − 2, a claw-back clause); RV-7 (300 000) nets 20 000 of
-- FC-6 (VAT 3 333), FC-8 in full (36 000, VAT 6 000) and takes 10 000 of A2: approved, its file handed out; the
-- redressement (effective d − 6) recorded after the download; the debit booked d − 1: settle:<RV-7> carries FC-8's part
-- alone, settle:<RV-7>:barred the barred 30 000 (FC-6 20 000, A2 10 000, VAT 3 333) and return:barred:<RV-7> reverses
-- it the same day; the withheld item of 30 000 in the queue, its entry the reversal; FC-6 and A2 still open; the
-- invariants clean; the client's members read the pair, no one else. (iv) the item's deadline is RV-7's, the next run
-- carries it as a line of its own kind outside every mandate, no commission, and its debit pays it
create or replace function pg_temp.sw1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f6 uuid; f8 uuid; a public.client_advance; v uuid; v8 uuid; b uuid; x uuid;
        w jsonb;
begin
  perform pg_temp.clawback('a2', 'art. 7.4');
  f6 := pg_temp.inv_on('a2', '61', 200000, '610', d - 12);
  f8 := pg_temp.inv_on('a2', '62', 200000, '620', d - 4);
  a := pg_temp.adv('a2', '63', 50000, '630');
  perform pg_temp.pending('a2', '64', 300000);
  v := pg_temp.request('a2', 'k046b-sw1');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f6, 'compensation', 20000, 3333),
                                                   pg_temp.st(f8, 'compensation', 36000, 6000),
                                                   pg_temp.st(a.id, 'advance', 10000)));
  perform pg_temp.draft_state(v);
  w := jsonb_build_object('approval', pg_temp.approve_plain(v, 'k046b-sw1'));
  perform pg_temp.handed_out('file-700', 'gen-file-700');
  perform pg_temp.evt('a2', 'proceeding_opened', d - 6, '1 minute');
  perform pg_temp.debit(v, '700', d - 1);
  b := pg_temp.ek('settle:' || v || ':barred');
  x := pg_temp.ek('return:barred:' || v);
  w := w || jsonb_build_object(
    'allowed', pg_temp.books(pg_temp.ek('settle:' || v)),
    'barred', pg_temp.books(b),
    'reversal', jsonb_build_array(pg_temp.books(x), pg_temp.rev(b) = x, pg_temp.edate(b) = d - 1,
                                  pg_temp.edate(x) = d - 1,
                                  (select e.reason from public.ledger_entry e where e.id = x)
                                    = 'Compensation retenue : procédure collective depuis le '
                                      || to_char(d - 6, 'DD/MM/YYYY') || ' (règle du cabinet)'),
    'settlements', pg_temp.run_sets(v, array[f6, f8, a.id]),
    'open', jsonb_build_array(private.document_open(f6), private.document_open(f8), private.advance_open(a.id)),
    'queue', pg_temp.queue('a2'),
    'item_is_the_reversal', (select q.ledger_entry_id = x from private.remittance_pending q
                             where q.client_organization_id = pg_temp.c('a2')),
    'owed', pg_temp.owed('a2'), 'dirty', pg_temp.dirty(),
    'read', jsonb_build_array(
      pg_temp.read_as('08', format('select to_jsonb(count(*)) from public.ledger_entry where id in (%L, %L)', b, x)),
      pg_temp.read_as('05', format('select to_jsonb(count(*)) from public.ledger_entry where id in (%L, %L)', b, x)),
      pg_temp.read_as('03', format('select to_jsonb(count(*)) from public.ledger_entry where id in (%L, %L)', b, x))),
    -- held to RV-7's line with the earliest latest execution date: its E (the collection of d − 3) and its delay
    'deadline', (select jsonb_build_array(y.encaissement_date = d - 3, y.max_days, y.latest_execution_date is not null)
                 from private.pending_item_deadlines('00000000-0000-0000-0000-0000000000aa') y
                 where y.ledger_entry_id = x));
  -- (iv) the next run carries W and its debit pays it
  v8 := pg_temp.request('a2', 'k046b-sw1-next');
  perform pg_temp.prepare_plain(v8);
  w := w || jsonb_build_object('next', pg_temp.approve_plain(v8, 'k046b-sw1-next'));
  w := w || jsonb_build_object(
    'next_line', (select jsonb_agg(jsonb_build_array(l.kind, l.mandate_id is null, l.commission_minor, l.amount_minor))
                  from public.remittance_line l where l.run_id = v8));
  perform pg_temp.debit(v8, '701', d - 1);
  return w || jsonb_build_object('paid', jsonb_build_array(pg_temp.queue('a2'), pg_temp.owed('a2'), pg_temp.dirty()));
end $$;
select is(pg_temp.iso('sw1'),
  '{"approval": "approved:approved",
    "allowed": {"client_payable": 36000, "due_to_servicer": -36000, "due_from_client_funds": 36000,
                "commission_receivable": -36000, "vat_pending": 6000, "vat_collected": -6000},
    "barred": {"client_payable": 30000, "due_to_servicer": -30000, "due_from_client_funds": 30000,
               "commission_receivable": -20000, "client_advance_receivable": -10000, "vat_pending": 3333,
               "vat_collected": -3333},
    "reversal": [{"client_payable": -30000, "due_to_servicer": 30000, "due_from_client_funds": -30000,
                  "commission_receivable": 20000, "client_advance_receivable": 10000, "vat_pending": -3333,
                  "vat_collected": 3333}, true, true, true, true],
    "settlements": [["invoice", 1, "compensation", 36000, 6000]],
    "open": [36000, 0, 50000], "queue": ["settlement_withheld:30000"], "item_is_the_reversal": true,
    "owed": -30000, "dirty": [], "read": [2, 0, 0], "deadline": [true, 30, true],
    "next": "approved:approved", "next_line": [["settlement_withheld", true, 0, 30000]],
    "paid": [[], 0, []]}'::jsonb,
  'w (i), (iv): the barred set-off posted and reversed at the debit (FC-6 and A2 still open, the withheld item of W in '
  'the queue, the invariants clean), FC-8 set off alone; the next run pays W, outside every mandate, no commission');
select is(pg_temp.iso('sw1', true), pg_temp.iso('sw1'), 'w (i), (iv): the same with the switch on');

-- (ii) Lambert: the whole plan barred (a death recorded after the download): only the barred pair, W = D, no
-- settle:<run>; (iii) Roux: a refund owed (12 000) larger than the allowed invoice's part (5 000), the pre-opening one
-- barred (30 000): the whole plan withheld (W = D = 23 000; no zero or negative entry, no settlement, the refund still
-- owed)
create or replace function pg_temp.sw2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; v uuid; r1 uuid; r2 uuid; r3 uuid; cn uuid; v2 uuid; w jsonb;
begin
  f := pg_temp.inv_on('a4', '41', 200000, '410', d - 12);
  perform pg_temp.pending('a4', '42', 100000);
  v := pg_temp.request('a4', 'k046b-sw2');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046b-sw2');
  perform pg_temp.handed_out('file-710', 'gen-file-710');
  perform pg_temp.evt('a4', 'death', d - 5, '1 minute');
  perform pg_temp.debit(v, '710', d - 1);
  w := jsonb_build_object('whole', jsonb_build_array(
    pg_temp.ek('settle:' || v) is null, pg_temp.books(pg_temp.ek('settle:' || v || ':barred')),
    pg_temp.rev(pg_temp.ek('settle:' || v || ':barred')) = pg_temp.ek('return:barred:' || v),
    (select e.reason from public.ledger_entry e where e.id = pg_temp.ek('return:barred:' || v))
      = 'Compensation retenue : fin du mandat depuis le ' || to_char(d - 5, 'DD/MM/YYYY') || ' (règle du cabinet)',
    pg_temp.run_sets(v, array[f]), private.document_open(f), pg_temp.queue('a4'), pg_temp.dirty()));
  -- (review round 1, TUI-2) the run page's read: W and its parts from the frozen plan
  w := w || jsonb_build_object('whole_read', pg_temp.withheld_read(v));
  -- (iii)
  r1 := pg_temp.inv_on('a5', '51', 200000, '510', d - 12, 36000, 6000);
  perform pg_temp.as_user('04');
  set local role authenticated;
  cn := (public.issue_credit_note('cn-046b-w2', r1, '100,00', 'terms_error', 'taux erroné (test)', '30000')
         ->> 'credit_note_id')::uuid;
  reset role;
  r2 := pg_temp.inv_on('a5', '52', 200000, '520', d - 4);
  r3 := pg_temp.inv_on('a5', '53', 200000, '530', d - 12);
  perform pg_temp.pending('a5', '54', 100000);
  v2 := pg_temp.request('a5', 'k046b-sw2-r');
  perform pg_temp.prepare_set(v2, jsonb_build_array(pg_temp.st(r3, 'compensation', 30000, 5000),
                                                    pg_temp.st(r2, 'compensation', 5000, 833),
                                                    pg_temp.st(cn, 'refund', 12000)));
  perform pg_temp.draft_state(v2);
  perform pg_temp.approve_plain(v2, 'k046b-sw2-r');
  perform pg_temp.handed_out('file-720', 'gen-file-720');
  perform pg_temp.evt('a5', 'proceeding_opened', d - 6, '1 minute');
  perform pg_temp.debit(v2, '720', d - 1);
  return w || jsonb_build_object('refund', jsonb_build_array(
    pg_temp.ek('settle:' || v2) is null, pg_temp.books(pg_temp.ek('settle:' || v2 || ':barred')),
    pg_temp.run_sets(v2, array[r2, r3, cn]),
    jsonb_build_array(private.document_open(r2), private.document_open(r3), private.document_open(cn)),
    pg_temp.queue('a5'), pg_temp.dirty()),
    -- (review round 1, TUI-2) the invoices withheld (35 000) and the refund not paid (12 000): W = 35 000 − 12 000
    'refund_read', pg_temp.withheld_read(v2),
    'refund_settled', (select r.refund_minor from public.remittance_run r where r.id = v2));
end $$;
select is(pg_temp.iso('sw2'),
  '{"whole": [true, {"client_payable": 20000, "due_to_servicer": -20000, "due_from_client_funds": 20000,
                     "commission_receivable": -20000, "vat_pending": 3333, "vat_collected": -3333},
              true, true, [], 36000, ["settlement_withheld:20000"], []],
    "refund": [true, {"client_payable": 23000, "due_to_servicer": -23000, "due_from_client_funds": 23000,
                      "commission_receivable": -23000, "vat_pending": 5833, "vat_collected": -5833},
               [], [36000, 36000, 12000], ["settlement_withheld:23000"], []],
    "whole_read": ["20000", "20000", "0", "0", "0", null, null],
    "refund_read": ["23000", "35000", "0", "12000", "0", null, null], "refund_settled": 12000}'::jsonb,
  'w (ii), (iii): a plan barred in full posts only the barred pair (W = D); a refund owed at least as large as the '
  'allowed invoices withholds the whole plan — never a zero or negative settlement, the refund still owed; the run '
  'page''s read names the withheld invoices and the refund not paid (TUI-2)');
select is(pg_temp.iso('sw2', true), pg_temp.iso('sw2'), 'w (ii), (iii): the same with the switch on');

-- (v) LG003 still raised for every other reversal, each in its own subtransaction: Petit's run RX set off its invoice
-- at its debit (settle:<RX>); a barred settlement of RX planted (never reversed); RY another run. A barred settlement
-- reversed under another run's key, under any other key; RX's own settlement under return:barred:<RX> or any key; a
-- commission invoice and a write-off under return:barred:<RX> → LG003. The barred one under its own key → posted.
-- (vi) the planted barred settlement without its reversal → LG003 at ledger_check_now (the commit check), with it → ok
create or replace function pg_temp.sw3() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; rx uuid; ry uuid; b uuid; a public.client_advance; inv_e uuid;
        wo_e uuid;
begin
  f := pg_temp.inv_on('a8', '81', 200000, '810', d - 3, 36000, 6000);
  rx := pg_temp.v('run-810');
  ry := gen_random_uuid();  -- another run's id
  a := pg_temp.adv('a8', '82', 40000, '820');
  perform pg_temp.wo('sw3', a.id, '100,00', '40000', p_evidence => 'd0000000-0000-0000-0000-0000000003a8');
  perform pg_temp.pending('a8', '83', 100000);  -- (Petit owed something: the planted entry leaves 4670 in credit)
  b := pg_temp.plant_barred(rx, 'a8', 1000);
  select e.id into inv_e from public.ledger_entry e
  where e.entry_type = 'commission_invoice' and e.source_id = f::text;
  select e.id into wo_e from public.ledger_entry e
  where e.entry_type = 'advance_write_off' and e.client_organization_id = pg_temp.c('a8');
  return jsonb_build_object(
    'other_run_key', pg_temp.rev_as(b, 'return:barred:' || ry),
    'other_key', pg_temp.rev_as(b, 'rev:barred:' || rx),
    'settlement_under_barred_key', pg_temp.rev_as(pg_temp.ek('settle:' || rx), 'return:barred:' || rx),
    'settlement_any_key', pg_temp.rev_as(pg_temp.ek('settle:' || rx), 'raw-046b-settle'),
    'invoice_under_barred_key', pg_temp.rev_as(inv_e, 'return:barred:' || rx),
    'write_off_under_barred_key', pg_temp.rev_as(wo_e, 'return:barred:' || rx),
    'own_key', pg_temp.rev_as(b, 'return:barred:' || rx),
    'unreversed', pg_temp.state('select private.ledger_check_now()'),
    'reversed', pg_temp.state(format('select private.ledger_reverse(%L, %L, ''Retour (test)'', %L); '
                                     'select private.ledger_check_now()', b, 'return:barred:' || rx, d)),
    'found', jsonb_build_array(inv_e is not null, wo_e is not null));
end $$;
select is(pg_temp.iso('sw3'),
  '{"other_run_key": "LG003", "other_key": "LG003", "settlement_under_barred_key": "LG003",
    "settlement_any_key": "LG003", "invoice_under_barred_key": "LG003", "write_off_under_barred_key": "LG003",
    "own_key": "ok", "unreversed": "LG003", "reversed": "ok", "found": [true, true]}'::jsonb,
  'w (v), (vi): only a barred settlement''s reversal under its own run''s key passes LG003 — never under another run''s '
  'or any other key, never for a run''s settlement, a commission invoice or a write-off; a barred settlement without its '
  'reversal fails the commit check');
-- the commit check is a deferred constraint trigger, enabled always, on barred settlements only
select is((select jsonb_build_array(t.tgenabled, t.tgdeferrable, t.tginitdeferred,
                                    pg_get_triggerdef(t.oid) like '%client_settlement%' and pg_get_triggerdef(t.oid) like '%:barred%')
           from pg_trigger t where t.tgname = 'ledger_entry_barred_reversed'),
  '["A", true, true, true]'::jsonb,
  'w (vi): ledger_entry_barred_reversed is deferrable, initially deferred, enabled always, for barred settlements only');


-- (iv) the withheld item paid late: Cyprès's RV-7 sets off a pre-opening invoice, the redressement recorded after the
-- download, its debit withholds W; the next run pays W after the item's date (its line's latest execution date moved
-- back, test only) → a breach recorded with no blocked reason (the servicer's own withholding, never an outside cause:
-- remittance_deadline_breach_blocked_reason_check unchanged). The run page's withheld set-off
-- (public.remittance_run_withheld): the servicer's money staff read it (W, its parts, the reason, the run that gave it
-- back); a collector, another servicer's staff and the client's own admin read nothing
create or replace function pg_temp.sw4() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; v uuid; v8 uuid; x uuid; w jsonb;
begin
  f := pg_temp.inv_on('a3', '31', 200000, '310', d - 12);
  perform pg_temp.pending('a3', '32', 100000);
  v := pg_temp.request('a3', 'k046b-sw4');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046b-sw4');
  perform pg_temp.handed_out('file-740', 'gen-file-740');
  perform pg_temp.evt('a3', 'proceeding_opened', d - 6, '1 minute');
  perform pg_temp.debit(v, '740', d - 2);
  x := pg_temp.ek('return:barred:' || v);
  v8 := pg_temp.request('a3', 'k046b-sw4-next');
  perform pg_temp.prepare_plain(v8);
  w := jsonb_build_object('next', pg_temp.approve_plain(v8, 'k046b-sw4-next'));
  -- (review round 1, MLAW-4, TUI-3) the next run approved, its payout not executed: W is being given back, not given
  w := w || jsonb_build_object('in_flight', (select jsonb_build_array(q9 ->> 5, q9 ->> 6 = pg_temp.rnum(v8))
                                             from (select pg_temp.withheld_read(v) as q9) z));
  set constraints all immediate;   -- (the deferred checks pass first: an ALTER waits for no pending trigger event)
  alter table public.remittance_line disable trigger remittance_line_guard;
  update public.remittance_line set latest_execution_date = d - 3, deadline = d - 2
  where run_id = v8 and ledger_entry_id = x;
  alter table public.remittance_line enable always trigger remittance_line_guard;
  set constraints all deferred;
  perform pg_temp.debit(v8, '741', d - 1);
  w := w || jsonb_build_object(
    'breach', (select jsonb_agg(jsonb_build_array(b.ledger_entry_id = x, b.blocked_reason, b.latest_execution_date = d - 3))
               from public.remittance_deadline_breach b where b.run_id = v8),
    'read_ops', (select jsonb_build_array(r ->> 'withheld_minor', r ->> 'commission_minor', r ->> 'advances_minor',
                                          (r ->> 'withheld_on')::date = d - 2,
                                          r ->> 'reason' = 'Compensation retenue : procédure collective depuis le '
                                                           || to_char(d - 6, 'DD/MM/YYYY') || ' (règle du cabinet)',
                                          r ->> 'set_off_commission_minor',
                                          r ->> 'given_back_by' = (select q.number from public.remittance_run q where q.id = v8),
                                          r ->> 'giving_back_by', r ->> 'refund_unpaid_minor')
                 from (select pg_temp.read_as('01', format('select public.remittance_run_withheld(%L)', v)) as r) z),
    'read_others', jsonb_build_array(
      pg_temp.read_as('02', format('select public.remittance_run_withheld(%L)', v)),
      pg_temp.read_as('05', format('select public.remittance_run_withheld(%L)', v)),
      pg_temp.read_as('06', format('select public.remittance_run_withheld(%L)', v)),
      pg_temp.read_as('01', format('select public.remittance_run_withheld(%L)', v), 'aal1')),
    'not_withheld', pg_temp.read_as('01', format('select public.remittance_run_withheld(%L)', v8)),
    'anon', has_function_privilege('anon', 'public.remittance_run_withheld(uuid)', 'execute'));
  return w;
end $$;
select is(pg_temp.iso('sw4'),
  '{"next": "approved:approved", "in_flight": [null, true], "breach": [[true, null, true]],
    "read_ops": ["20000", "20000", "0", true, true, "0", true, null, "0"],
    "read_others": [null, null, null, null], "not_withheld": null, "anon": false}'::jsonb,
  'w (iv): the withheld item paid after its date is a breach with no blocked reason (the servicer''s own withholding); '
  'the run page''s withheld set-off is read by the servicer''s money staff (aal2) only; the run giving W back named as '
  'such only once booked (review round 1, MLAW-4, TUI-3)');
select is(pg_temp.iso('sw4', true), pg_temp.iso('sw4'), 'w (iv): the same with the switch on');


-- (review round 1, MLAW-2) the « Lier » preview of a payout's debit says what its booking sets off and withholds, by the
-- rule the debit applies (private.run_settlement_split, post_run_settlements' twin): Lilas (sw1's plan, the redressement
-- recorded after the download) → settlement_minor D − W = 36 000 and withheld_minor W = 30 000, the booking's two
-- entries those amounts; Lambert (a death, the whole plan barred) → 0 and 20 000; Roux (sw2 (iii): a refund owed
-- larger than the allowed invoice, the whole plan withheld) → 0 and D = 23 000; Martin (no event) → D and 0.
-- (CC-4) post_run_settlements given a run id that names no run before a barred run still withholds the barred run's
-- set-off (the event gate read by each run's own position)
create or replace function pg_temp.sw5() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f6 uuid; f8 uuid; a public.client_advance; v uuid; t uuid; pv jsonb;
        w jsonb := '{}'; r2 uuid; r3 uuid; cn uuid;
begin
  perform pg_temp.clawback('a2', 'art. 7.4');
  f6 := pg_temp.inv_on('a2', '61', 200000, '610', d - 12);
  f8 := pg_temp.inv_on('a2', '62', 200000, '620', d - 4);
  a := pg_temp.adv('a2', '63', 50000, '630');
  perform pg_temp.pending('a2', '64', 300000);
  v := pg_temp.request('a2', 'k046b-sw5');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f6, 'compensation', 20000, 3333),
                                                   pg_temp.st(f8, 'compensation', 36000, 6000),
                                                   pg_temp.st(a.id, 'advance', 10000)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046b-sw5');
  perform pg_temp.handed_out('file-750', 'gen-file-750');
  perform pg_temp.evt('a2', 'proceeding_opened', d - 6, '1 minute');
  t := pg_temp.rtransfer(v);
  perform pg_temp.exec_back(t, d - 1);
  perform pg_temp.stmt2('750', d - 1, jsonb_build_array(jsonb_build_object('amount', pg_temp.amt(t), 'e2e', pg_temp.e2e(t))));
  pv := pg_temp.pv(pg_temp.l2('750', 1), jsonb_build_array(pg_temp.pt('payout', t, pg_temp.amt(t))));
  w := w || jsonb_build_object('partial', jsonb_build_array(pv -> 'parts' -> 0 ->> 'settlement_minor',
                                                            pv -> 'parts' -> 0 ->> 'withheld_minor'));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('750', 1), 'payout', t)));
  w := w || jsonb_build_object('partial_booked', jsonb_build_array(
    pg_temp.books(pg_temp.ek('settle:' || v)) -> 'client_payable',
    pg_temp.books(pg_temp.ek('settle:' || v || ':barred')) -> 'client_payable'));
  -- the whole plan barred
  f6 := pg_temp.inv_on('a4', '41', 200000, '410', d - 12);
  perform pg_temp.pending('a4', '42', 100000);
  v := pg_temp.request('a4', 'k046b-sw5-whole');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f6, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046b-sw5-whole');
  perform pg_temp.handed_out('file-760', 'gen-file-760');
  perform pg_temp.evt('a4', 'death', d - 5, '1 minute');
  t := pg_temp.rtransfer(v);
  perform pg_temp.exec_back(t, d - 1);
  perform pg_temp.stmt2('760', d - 1, jsonb_build_array(jsonb_build_object('amount', pg_temp.amt(t), 'e2e', pg_temp.e2e(t))));
  pv := pg_temp.pv(pg_temp.l2('760', 1), jsonb_build_array(pg_temp.pt('payout', t, pg_temp.amt(t))));
  w := w || jsonb_build_object('whole', jsonb_build_array(pv -> 'parts' -> 0 ->> 'settlement_minor',
                                                          pv -> 'parts' -> 0 ->> 'withheld_minor'));
  -- a refund owed larger than the allowed invoice (sw2 (iii)'s Roux): the whole plan withheld, W = D = 23 000
  f6 := pg_temp.inv_on('a5', '51', 200000, '510', d - 12, 36000, 6000);
  perform pg_temp.as_user('04');
  set local role authenticated;
  cn := (public.issue_credit_note('cn-046b-w5', f6, '100,00', 'terms_error', 'taux erroné (test)', '30000')
         ->> 'credit_note_id')::uuid;
  reset role;
  r2 := pg_temp.inv_on('a5', '52', 200000, '520', d - 4);
  r3 := pg_temp.inv_on('a5', '53', 200000, '530', d - 12);
  perform pg_temp.pending('a5', '54', 100000);
  v := pg_temp.request('a5', 'k046b-sw5-refund');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(r3, 'compensation', 30000, 5000),
                                                   pg_temp.st(r2, 'compensation', 5000, 833),
                                                   pg_temp.st(cn, 'refund', 12000)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046b-sw5-refund');
  perform pg_temp.handed_out('file-765', 'gen-file-765');
  perform pg_temp.evt('a5', 'proceeding_opened', d - 6, '1 minute');
  t := pg_temp.rtransfer(v);
  perform pg_temp.exec_back(t, d - 1);
  perform pg_temp.stmt2('765', d - 1, jsonb_build_array(jsonb_build_object('amount', pg_temp.amt(t), 'e2e', pg_temp.e2e(t))));
  pv := pg_temp.pv(pg_temp.l2('765', 1), jsonb_build_array(pg_temp.pt('payout', t, pg_temp.amt(t))));
  w := w || jsonb_build_object('refund', jsonb_build_array(pv -> 'parts' -> 0 ->> 'settlement_minor',
                                                           pv -> 'parts' -> 0 ->> 'withheld_minor'));
  -- no event
  f6 := pg_temp.inv_on('a1', '11', 200000, '110', d - 12);
  perform pg_temp.pending('a1', '12', 100000);
  v := pg_temp.request('a1', 'k046b-sw5-plain');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f6, 'compensation', 20000, 3333)));
  perform pg_temp.approve_plain(v, 'k046b-sw5-plain');
  perform pg_temp.handed_out('file-770', 'gen-file-770');
  t := pg_temp.rtransfer(v);
  perform pg_temp.exec_back(t, d - 1);
  perform pg_temp.stmt2('770', d - 1, jsonb_build_array(jsonb_build_object('amount', pg_temp.amt(t), 'e2e', pg_temp.e2e(t))));
  pv := pg_temp.pv(pg_temp.l2('770', 1), jsonb_build_array(pg_temp.pt('payout', t, pg_temp.amt(t))));
  w := w || jsonb_build_object('no_event', jsonb_build_array(pv -> 'parts' -> 0 ->> 'settlement_minor',
                                                             pv -> 'parts' -> 0 ->> 'withheld_minor'));
  -- (CC-4) a run id naming no run first: Durand's barred run still withheld
  f6 := pg_temp.inv_on('a7', '71', 200000, '780', d - 12);
  perform pg_temp.pending('a7', '72', 100000);
  v := pg_temp.request('a7', 'k046b-sw5-shift');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f6, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046b-sw5-shift');
  perform pg_temp.evt('a7', 'proceeding_opened', d - 6, '1 minute');
  perform private.post_run_settlements(array[gen_random_uuid(), v], array[d - 1, d - 1]);
  return w || jsonb_build_object('shifted', jsonb_build_array(
    pg_temp.ek('settle:' || v) is null, pg_temp.ek('settle:' || v || ':barred') is not null,
    pg_temp.ek('return:barred:' || v) is not null, pg_temp.run_sets(v, array[f6])));
end $$;
select is(pg_temp.iso('sw5'),
  '{"partial": ["36000", "30000"], "partial_booked": [36000, 30000], "whole": ["0", "20000"],
    "refund": ["0", "23000"],
    "no_event": ["20000", "0"], "shifted": [true, true, true, []]}'::jsonb,
  'w (review round 1, MLAW-2): the preview of a payout''s debit gives what its booking sets off (D − W) and withholds '
  '(W), by the debit''s own rule; (CC-4) a run id naming no run never shifts another run''s event gate');
select is(pg_temp.iso('sw5', true), pg_temp.iso('sw5'), 'w (MLAW-2, CC-4): the same with the switch on');


-- s. The schedule ([check 2] gap 3) -----------------------------------------------------------------------------------
-- Martin: a withheld item alone (a death recorded after the download) → the candidates say settlement_withheld, not
-- payout_returned; its run's payout coming back too → both; the run's trigger takes settlement_withheld and refuses an
-- unknown one
create or replace function pg_temp.ss1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; v uuid; w jsonb;
begin
  f := pg_temp.inv_on('a1', '11', 200000, '110', d - 12);
  perform pg_temp.pending('a1', '12', 100000);
  v := pg_temp.request('a1', 'k046b-ss1');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046b-ss1');
  perform pg_temp.handed_out('file-111', 'gen-file-111');
  perform pg_temp.evt('a1', 'death', d - 5, '1 minute');
  perform pg_temp.debit(v, '111', d - 1);
  w := jsonb_build_object('alone', (select jsonb_build_array(x.settlement_withheld, x.payout_returned)
                                    from private.remittance_schedule_candidates('00000000-0000-0000-0000-0000000000aa', d) x
                                    where x.client_organization_id = pg_temp.c('a1')));
  perform pg_temp.bounce(v, '112');
  return w || jsonb_build_object(
    'both', (select jsonb_build_array(x.settlement_withheld, x.payout_returned)
             from private.remittance_schedule_candidates('00000000-0000-0000-0000-0000000000aa', d) x
             where x.client_organization_id = pg_temp.c('a1')),
    'trigger', pg_temp.state(format('select private.create_remittance_run(%L, %L, ''EUR'', ''settlement_withheld'', %L, null)',
                                    '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'), 'sched:ss1')),
    'unknown', pg_temp.state(format('select private.create_remittance_run(%L, %L, ''EUR'', ''foo'', %L, null)',
                                    '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'), 'sched:ss1b')));
end $$;
select is(pg_temp.iso('ss1'),
  '{"alone": [true, false], "both": [true, true], "trigger": "ok", "unknown": "23514"}'::jsonb,
  's: a withheld item alone is a candidate of its own kind (settlement_withheld, not payout_returned); with a returned '
  'payout both; the run''s trigger takes settlement_withheld and still refuses an unknown one');


-- n. The nightly (§6.3) ------------------------------------------------------------------------------------------------
-- Moreau's run set off FC-6 (born d − 12) and FC-8 (born d − 4) at its debit (d − 1); a redressement effective d − 6
-- recorded after the debit (which could not see it) → set_off_after_bar (P0) lists the settlement with FC-6's part only.
-- (Review round 1, TUI-6) a withheld run (Lilas: its redressement recorded after the download, before the debit, which
-- withheld FC-L6 and set off FC-L8) is not listed. (MLAW-3; C. civ. 2008, LEX-27, OQ-93) Lambert's run set its invoice
-- off at its debit; a death effective d − 5 recorded after that set-off: made before the servicer knew of the end, and
-- barred by it alone, it is valid — not listed; Durand's the same, the death recorded before the set-off was posted
-- (an event the debit's read missed): listed, its bar mandate_ended
create or replace function pg_temp.sn1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f6 uuid; f8 uuid; v uuid; c uuid; l6 uuid; l8 uuid; vl uuid; w jsonb;
begin
  -- Lilas: withheld at the debit
  l6 := pg_temp.inv_on('a2', '21', 200000, '210', d - 12);
  l8 := pg_temp.inv_on('a2', '22', 200000, '220', d - 4);
  perform pg_temp.pending('a2', '23', 300000);
  vl := pg_temp.request('a2', 'k046b-sn1-l');
  perform pg_temp.prepare_set(vl, jsonb_build_array(pg_temp.st(l6, 'compensation', 20000, 3333),
                                                    pg_temp.st(l8, 'compensation', 36000, 6000)));
  perform pg_temp.draft_state(vl);
  perform pg_temp.approve_plain(vl, 'k046b-sn1-l');
  perform pg_temp.handed_out('file-230', 'gen-file-230');
  perform pg_temp.evt('a2', 'proceeding_opened', d - 6, '1 minute');
  perform pg_temp.debit(vl, '230', d - 1);
  -- Lambert and Durand: their run's own invoice set off at its debit, then a death recorded
  perform pg_temp.inv_on('a4', '41', 200000, '410', d - 3, 30000, 5000);
  perform pg_temp.evt('a4', 'death', d - 5, '-1 hour');
  perform pg_temp.inv_on('a7', '71', 200000, '710', d - 3, 30000, 5000);
  perform pg_temp.evt('a7', 'death', d - 5, '2 hours');
  f6 := pg_temp.inv_on('a9', '91', 200000, '910', d - 12);
  f8 := pg_temp.inv_on('a9', '92', 200000, '920', d - 4);
  perform pg_temp.pending('a9', '93', 300000);
  v := pg_temp.request('a9', 'k046b-sn1');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f6, 'compensation', 20000, 3333),
                                                   pg_temp.st(f8, 'compensation', 36000, 6000)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046b-sn1');
  perform pg_temp.debit(v, '930', d - 1);
  perform pg_temp.evt('a9', 'proceeding_opened', d - 6, '1 minute');
  c := pg_temp.adv_run(null, true);
  w := jsonb_build_object('moreau', (select coalesce(jsonb_agg(jsonb_build_array(
                   x.subject_type, x.subject_id = pg_temp.ek('settle:' || v), x.amount_minor, x.severity,
                   (x.details ->> 'p0')::boolean, x.details ->> 'bar', (x.details ->> 'bar_on')::date = d - 6,
                   x.details -> 'documents' -> 0 ->> 'document_id' = f6::text,
                   jsonb_array_length(x.details -> 'documents'))), '[]')
          from public.payment_check_result x where x.run_id = c and x.code = 'set_off_after_bar'
            and x.subject_id = pg_temp.ek('settle:' || v)));
  return w || jsonb_build_object(
    'withheld_lilas', jsonb_build_array(pg_temp.ek('settle:' || vl || ':barred') is not null,
                                        pg_temp.ek('settle:' || vl) is not null),
    'listed', (select jsonb_agg(jsonb_build_array(
                        case x.subject_id when pg_temp.ek('settle:' || v) then 'moreau'
                                          when pg_temp.ek('settle:' || pg_temp.v('run-410')) then 'lambert'
                                          when pg_temp.ek('settle:' || pg_temp.v('run-710')) then 'durand'
                                          else 'other' end, x.details ->> 'bar', x.amount_minor) order by x.amount_minor, x.subject_id)
               from public.payment_check_result x where x.run_id = c and x.code = 'set_off_after_bar'));
end $$;
select is(pg_temp.iso('sn1'),
  '{"moreau": [["ledger_entry", true, 20000, "alert", true, "proceeding", true, true, 1]],
    "withheld_lilas": [true, true],
    "listed": [["moreau", "proceeding", 20000], ["durand", "mandate_ended", 30000]]}'::jsonb,
  'n: a set-off posted after a bar''s date that an event recorded later reveals is alerted (P0) with the barred '
  'document''s part only, from the ledger''s settlements; a withheld run is not; (review round 1, MLAW-3) one made '
  'before the mandate''s end was recorded and barred by it alone is valid (C. civ. 2008), not alerted');

-- the full list of codes run_advance_checks emits (046a n, extended with set_off_after_bar)
create or replace function pg_temp.sn2() returns jsonb language plpgsql as $$
declare a public.client_advance; m public.client_advance; c uuid; r jsonb; v uuid; f uuid; d date := private.paris_today();
begin
  -- 7d-2's: a set-off a later event bars
  f := pg_temp.inv_on('a6', '91', 200000, '910', d - 12);
  perform pg_temp.pending('a6', '93', 100000);
  v := pg_temp.request('a6', 'k046b-sn2');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.approve_plain(v, 'k046b-sn2');
  perform pg_temp.debit(v, '930', d - 1);
  perform pg_temp.evt('a6', 'proceeding_opened', d - 6, '1 minute');
  m := pg_temp.adv('a9', 'da', 30000, 'da0');
  r := pg_temp.dra('x0', 'a9', array[m.id]);
  perform pg_temp.dra_back((r ->> 'request_id')::uuid, private.paris_today(), now() - interval '2 hours');
  perform pg_temp.cpay('x1', 'a8', '50,00', p_expected => '0');
  perform pg_temp.remitted('a1', 'e6', 100000, 'be6');
  perform pg_temp.unalloc('e6');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('e6')));
  perform pg_temp.plant_settlement(a.id, 1000);
  perform pg_temp.remitted('a2', 'e7', 50000, 'be7');
  perform private.ledger_reverse(pg_temp.alloc('e7'), 'raw-test-e7', 'Retour (test)', private.paris_today());
  perform pg_temp.plant('client_payment_own', 'x2', '[["own_cash", 500], ["client_credit_owed", -500]]');
  perform pg_temp.plant('client_payment_own', 'x3', '[["own_cash", 700], ["written_off_recovered", -700]]');
  perform pg_temp.old_tutelle('a7', private.paris_today() - 3);
  perform pg_temp.evt('a5', 'seizure', private.paris_today() - 1);
  c := pg_temp.adv_run(private.paris_today() + 31, true);
  return (select jsonb_agg(distinct x.code order by x.code) from public.payment_check_result x where x.run_id = c);
end $$;
-- (M2c-7d-3, house rule R3, ADR-0014 « M2c-7d-3 ») the list extended, as F12 says each later slice does: Dupont's
-- invoice born before its redressement is still open in part (16 000), so claims_to_declare lists it (046c n pins the
-- full list with 7d-3's three codes)
select is(pg_temp.iso('sn2'),
  '["advance_ledger", "advance_open", "claims_to_declare", "client_credit_ledger", "client_credit_owed",
    "protection_event_to_qualify", "remitted_reversal_uncovered", "repayment_request_document_missing",
    "seizure_standing", "set_off_after_bar", "written_off_recovery_ledger"]'::jsonb,
  'n (F12): run_advance_checks emits exactly advance_ledger, advance_open, claims_to_declare, client_credit_ledger, '
  'client_credit_owed, protection_event_to_qualify, remitted_reversal_uncovered, repayment_request_document_missing, '
  'seizure_standing, set_off_after_bar, written_off_recovery_ledger (later slices extend this list)');


-- c. The privileges of the new functions --------------------------------------------------------------------------------
-- the bars and the births: never a caller's (authenticated); the four the worker's prepare reads granted to its role
select is((select jsonb_agg(jsonb_build_array(f, has_function_privilege('authenticated', f, 'execute'),
                                              has_function_privilege('service_role', f, 'execute')) order by f)
           from unnest(array['private.client_opening_date(uuid, date)', 'private.client_set_off_bars(uuid, date)',
                             'private.client_set_off_barred(uuid, date, text)', 'private.document_born_on(uuid)',
                             'private.document_nettable(uuid, date)', 'private.barred_settlement_check()']) f),
  '[["private.barred_settlement_check()", false, false], ["private.client_opening_date(uuid, date)", false, true],
    ["private.client_set_off_barred(uuid, date, text)", false, true],
    ["private.client_set_off_bars(uuid, date)", false, true], ["private.document_born_on(uuid)", false, true],
    ["private.document_nettable(uuid, date)", false, false]]'::jsonb,
  'c: no caller executes the bars or the births; the worker''s role reads the opening, the bars and the births');
-- the kinds: the queue and the lines take settlement_withheld (the line's guard unchanged) and still refuse another
select is((select jsonb_build_array(
             pg_get_constraintdef((select c.oid from pg_constraint c where c.conname = 'remittance_pending_kind_check'))
               like '%settlement_withheld%',
             pg_get_constraintdef((select c.oid from pg_constraint c where c.conname = 'remittance_line_kind_check'))
               like '%settlement_withheld%',
             pg_get_constraintdef((select c.oid from pg_constraint c where c.conname = 'remittance_run_trigger_check'))
               like '%settlement_withheld%')),
  '[true, true, true]'::jsonb,
  'c: the queue''s and the lines'' kinds and the run''s triggers take settlement_withheld');


-- The switch is still off (no M2c-7 migration writes it) --------------------------------------------------------------
select is(private.switch_on('downloaded_file_cancellation'), false,
  'the cancellation-after-download switch is still off');

select * from finish();
rollback;
