-- M2c-6b-2d « Suivi » (plan docs/design/m2c-6b-2-plan.md §5, §8.1 038; ADR-0014 « M2c-6b-2d »): the statement's
-- `previous_payouts`, the events of the client's earlier approved runs of the currency posted in the window from the
-- previous approved run's K to this run's K (critic L17; ADR-0012: ledger_entry.posted_at and remittance_run.cancelled_at
-- against K), and the late cause `paid_by_unplanned` read as of K (critic L9, critic2 ML-9). On 037b's fixtures (copied:
-- the servicer aa, its accounts cf/c0, clients a1–a9, the other servicer bb; no base run), each scenario in its own
-- rolled-back subtransaction (pg_temp.iso: its error returned, so that before this slice's migration each case fails,
-- not the file):
--   A. the window (L17): RV-1's debit booked after K₁ is in RV-2's « Suivi » with its date; RV-2's own debit, booked
--      between RV-2's K and its statement's drawing, is not in RV-2 (drawn again later: the same « Suivi ») but in RV-3;
--      a first statement has nothing to follow;
--   B. a return after K₁: held by RV-2 → `returned`, `here`; RV-2 cancelled before its statement is drawn → `pending`
--      (its items back in the queue); RV-3's window starts at RV-2's K: RV-2 `cancelled`, the return not repeated;
--   C. (switch on) a run cancelled after download whose payout the bank executes late, booked unplanned (P = A) →
--      `executed_after_cancellation` only (not `cancelled` too), `here`; the late lines its P paid → `paid_by_unplanned`
--      with the booking's date, in full and in part (« dont … »); its unplanned return posted after K changes nothing;
--   C2. the same booking returned before K: the lines keep their own cause, the return is `unplanned_returned` and its
--      line's nature is the unplanned one (critic L4);
--   D. P bounded by the queue (critic2 ML-9: all of the run still owed): `p_bound` queue, the advance, a partial
--      attribution;
--   E. P bounded by the items (a released collection bounced): `p_bound` items;
--   F. S03: a booked payout debited a second time → `debited_again` (P = 0, advance A, `none`); its copy back →
--      `unplanned_returned` in the next window, ordered by date then run number;
--   G. S13: a debit to the client's payout IBAN with no transfer → `executed_outside` (the IBAN's last four characters);
--      its return → `unplanned_returned` without a run;
--   H. (switch on; critic2 ML-12) the run's payout re-issued, the run cancelled, the bank executing the old transfer →
--      `executed_after_cancellation` read on the run's chain;
--   I. N = 0 runs bound the window and are never listed; a prepared draft discarded with its RV number neither (critic
--      L7); another client's debit and S13 booking in the window are never listed;
--   R. the reads are keyed (pg_stat_xact_user_tables, the « Suivi » and late-cause helpers with seq scans off) and the
--      helpers are internal (no grant to a client, a collector or another servicer's staff: no role but the owner).
-- Review round 1 (ADR-0014 « M2c-6b-2d review fixes »): an unplanned execution's rank among its chain's executions and,
-- executed again, the planned debit's date and whether it came first (F-before, F-thrice, H-released, D-twice); the
-- same-day order of an S13 and its return, `here` false once the run is cancelled (G-same-day, F-thrice); the window's
-- other bounds, the as-of-K bound on `repaid` and the currency filters (G-window, B, I-currency); a partial return's
-- owed amount (F-partial), the dates besides `on` (G-same-day, H, D-twice); a late line paid in part keeps its own cause
-- (C, D, D-twice); the chain's transfers read by key alone with other clients' rows present (R-reads); the record
-- step refuses a statement of another template (R-record).
-- Cancellation after download stays off (033 and 034 unchanged): C, C2, D, E and H switch it on inside their own
-- rolled-back subtransaction.
begin;
select plan(24);

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

-- (D's helpers, as 037's)
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
-- the parts of a proposal as [kind, amount, paid, advance, bound], by amount (a lot's members are in the file's order,
-- which follows ids)
create or replace function pg_temp.parts_of(p_preview jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(p ->> 'kind', p ->> 'amount_minor', p ->> 'paid_minor',
                                              p ->> 'advance_minor', p ->> 'p_bound')
                            order by (p ->> 'amount_minor')::bigint), '[]')
  from jsonb_array_elements(p_preview -> 'parts') p $$;
-- a line's bookings as « kind amount », by amount, and their seqs
create or replace function pg_temp.booked_set(p_line uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'kinds', coalesce(jsonb_agg(b.kind || ' ' || b.amount_minor order by b.amount_minor), '[]'),
    'seqs', coalesce(jsonb_agg(b.seq order by b.seq), '[]'))
  from public.bank_line_booking b where b.bank_transaction_id = p_line $$;
grant execute on all functions in schema pg_temp to authenticated;

-- 038's helpers -------------------------------------------------------------------------------------------------------
-- a scenario in its own subtransaction, always rolled back: its value, or its error (so that before this slice's
-- migration the cases fail one by one, not the file)
create or replace function pg_temp.iso(p_scenario text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  begin
    execute format('select pg_temp.%I()', p_scenario) into v;
    raise exception 'scenario % rolled back', p_scenario using errcode = 'TR001';
  exception when sqlstate 'TR001' then
    null;
  when others then
    return jsonb_build_object('error', sqlerrm);
  end;
  return v;
end $$;
-- a run's label in t (RV0, RV1, …), else its number; a date as its offset from today (d0, d-1); an end-to-end id as its
-- place in the run's chain (chain:0 the run's transfer, chain:1 the one it re-issues)
create or replace function pg_temp.lbl(p_number text) returns text language sql as $$
  select coalesce((select t.k from t join public.remittance_run r on r.id = t.v
                   where r.number = p_number and t.k like 'RV%' order by t.k limit 1), p_number) $$;
create or replace function pg_temp.dd(p_date text) returns text language sql as $$
  select 'd' || (p_date::date - private.paris_today())::text $$;
create or replace function pg_temp.chain_of(p_number text, p_e2e text) returns text language sql as $$
  select coalesce((select 'chain:' || c.depth from public.remittance_run r
                   cross join lateral private.transfer_chain(r.transfer_id) c
                   join public.bank_transfer x on x.id = c.transfer_id
                   where r.number = p_number and x.end_to_end_id = p_e2e limit 1), p_e2e) $$;
create or replace function pg_temp.nev(e jsonb) returns jsonb language plpgsql as $$
declare k text; x jsonb; v jsonb := '{}';
begin
  for k, x in select * from jsonb_each(e) loop
    v := v || jsonb_build_object(k, case
      when jsonb_typeof(x) <> 'string' then x
      when k in ('run_number', 'repaid_by') then to_jsonb(pg_temp.lbl(x #>> '{}'))
      when k in ('on', 'debited_on', 'cancelled_on', 'executed_on') then to_jsonb(pg_temp.dd(x #>> '{}'))
      when k = 'end_to_end_id' then to_jsonb(pg_temp.chain_of(e ->> 'run_number', x #>> '{}'))
      else x end);
  end loop;
  return v;
end $$;
-- the run's statement « Suivi » (payload previous_payouts), labelled: since [the previous approved run, its K as the
-- payload states it], the events in the payload's order; null when the payload has none (before this slice)
create or replace function pg_temp.suivi(p_run uuid) returns jsonb language plpgsql as $$
declare p jsonb := private.remittance_statement_build(p_run) -> 'previous_payouts';
begin
  if p is null then
    return null;
  end if;
  return jsonb_build_object(
    'since', case when jsonb_typeof(p -> 'since') = 'object' then jsonb_build_array(
               pg_temp.lbl(p #>> '{since,number}'),
               (select p #>> '{since,known_at}'
                       = to_char(r.known_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                from public.remittance_run r where r.number = p #>> '{since,number}')) end,
    'events', coalesce((select jsonb_agg(pg_temp.nev(e) order by o)
                        from jsonb_array_elements(p -> 'events') with ordinality z (e, o)), '[]'));
end $$;
-- a statement line's facts, by the run's line of that entry: its nature, why late, what an unplanned payout paid of it
create or replace function pg_temp.lf(p_run uuid, p_entry uuid) returns jsonb language plpgsql as $$
declare p jsonb := private.remittance_statement_build(p_run); c jsonb; n integer; x jsonb;
begin
  select jsonb_object_agg(z.c, z.o - 1) into c
  from jsonb_array_elements_text(p -> 'line_columns') with ordinality z (c, o);
  select l.line_no into n from public.remittance_line l where l.run_id = p_run and l.ledger_entry_id = p_entry;
  select y into x from jsonb_array_elements(p -> 'lines') y where (y ->> (c ->> 'line_no')::integer)::integer = n;
  return jsonb_build_object(
    'nature', x ->> (c ->> 'nature')::integer, 'reason', x ->> (c ->> 'nature_reason')::integer,
    'late', x -> (c ->> 'late')::integer, 'cause', x ->> (c ->> 'late_cause')::integer,
    'paid', x ->> (c ->> 'paid_by_unplanned_minor')::integer,
    'paid_on', pg_temp.dd(x ->> (c ->> 'paid_by_unplanned_on')::integer));
end $$;
create or replace function pg_temp.alloc(p_n text) returns uuid language sql as $$
  select id from public.ledger_entry where payment_id = pg_temp.pay(p_n) and entry_type = 'allocation' $$;
-- the prepare (as prepare_plain) with every positive line's latest execution date p_latest: the approval is late
create or replace function pg_temp.prepare_late(p_run uuid, p_latest date) returns integer language plpgsql as $$
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
         case when q.amount_minor > 0 then p_latest + 3 end, case when q.amount_minor > 0 then p_latest end,
         q.amount_minor, jsonb_build_object('principal', q.amount_minor::text), 0, 'none', '[]', false
  from private.remittance_pending q
  join public.ledger_entry e on e.id = q.ledger_entry_id
  left join public.account a on a.id = e.account_id
  left join public.portfolio pf on pf.id = a.portfolio_id
  where q.draft_run_id = p_run;
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
    'inputs_hash', encode(sha256(convert_to(p_run::text || 'late', 'UTF8')), 'hex'),
    'payout_account_id', (select pa.id from public.client_payout_account pa
                          where pa.client_organization_id = r.client_organization_id and pa.status = 'active'),
    'history_seq', (select coalesce(max(seq), 0) from public.remittance_key_state
                    where client_organization_id = r.client_organization_id),
    'documents', '[]'::jsonb, 'key_states', '[]'::jsonb,
    'plan', '{"settles": [], "net": "0", "settlement": "0", "dc": "0", "da": "0", "vat_moved": "0", "deferred": true}'));
  return (select version from public.remittance_run where id = p_run);
end $$;
-- the late approval (its reason given; the late lines' rows recorded by the approval)
create or replace function pg_temp.approve_late(p_run uuid, p_key text) returns text language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := public.approve_remittance_runs('ap-late-' || p_key, pg_temp.item(p_run), null, 'validation tardive (test)');
  reset role;
  if v -> 'results' -> 0 ->> 'status' = 'queued' then
    perform private.approve_remittance_run(p_run, (select job_token from public.remittance_run where id = p_run));
  end if;
  return coalesce(v -> 'results' -> 0 ->> 'reason', '') || ':' || (select status from public.remittance_run where id = p_run);
end $$;
-- a cancelled run's payout executed all the same (switch on): Roux's two collections of 100 000 (RV1: 164 000), RV1
-- handed out, its payout cancelled after download and RV1 cancelled (its items back), Roux's draft RV2 requested, the
-- payout's late debit on today's statement (line l of statement s)
create or replace function pg_temp.cancelled_after_download(p_c text, p_s text) returns uuid language plpgsql as $$
declare v_x uuid;
begin
  perform pg_temp.file(p_s || '1', ('20000000-0000-0000-0000-0000000000' || p_c)::uuid, 100000);
  perform pg_temp.collect(p_s || '1', 100000, private.paris_today() - 3);
  perform pg_temp.file(p_s || '2', ('20000000-0000-0000-0000-0000000000' || p_c)::uuid, 100000);
  perform pg_temp.collect(p_s || '2', 100000, private.paris_today() - 3);
  insert into t values ('RV1', pg_temp.runk(p_c, jsonb_build_object(p_s || '1', '100000', p_s || '2', '100000'), 36000,
                                            6000, p_s || '-r1'));
  v_x := (select transfer_id from public.remittance_run where id = pg_temp.v('RV1'));
  perform pg_temp.handed_out('f' || p_s, 'gen-x038-' || p_s);
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_x;
  perform pg_temp.cancel_run(pg_temp.v('RV1'), p_s || '-r1');
  insert into t values ('RV2', pg_temp.request(p_c, p_s || '-r2'));
  perform pg_temp.stmt2(p_s || '1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(v_x))));
  return v_x;
end $$;
-- (038) 037's request and plain approval, their idempotency keys eight characters at least whatever the scenario's key
create or replace function pg_temp.request(p_c text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  v := (public.request_remittance_run('rq-038-' || p_key, pg_temp.c(p_c)) ->> 'run_id')::uuid;
  reset role;
  return v;
end $$;
create or replace function pg_temp.approve_plain(p_run uuid, p_key text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user('01');
  set local role authenticated;
  perform public.approve_remittance_runs('ap-038-' || p_key, pg_temp.item(p_run));
  reset role;
  v := private.approve_remittance_run(p_run, (select job_token from public.remittance_run where id = p_run)) ->> 'status';
  return coalesce(v, '?') || ':' || (select status from public.remittance_run where id = p_run);
end $$;
-- the bookings' tuples read so far in this transaction (the servicer-wide probes must read only their rare rows)
create or replace function pg_temp.booking_reads() returns bigint language sql as $$
  select coalesce(sum(x.seq_tup_read + coalesce(x.idx_tup_fetch, 0)), 0)::bigint from pg_stat_xact_user_tables x
  where x.relid = 'public.bank_line_booking'::regclass $$;
-- the tables « Suivi » and the late cause read, and their sequential scans so far in this transaction
create or replace function pg_temp.scans() returns bigint language sql as $$
  select coalesce(sum(x.seq_scan), 0)::bigint from pg_stat_xact_user_tables x
  where x.relid in ('public.remittance_run'::regclass, 'public.bank_transfer'::regclass,
                    'public.bank_line_booking'::regclass, 'public.ledger_entry'::regclass,
                    'public.client_advance'::regclass, 'public.remittance_line'::regclass,
                    'public.bank_transaction'::regclass, 'private.unplanned_paid_item'::regclass) $$;
-- the late cause's helper calls so far in this transaction (the build must call it for its late lines only)
set track_functions = 'all';
create or replace function pg_temp.helper_calls() returns bigint language sql as $$
  select coalesce(sum(x.calls), 0)::bigint from pg_stat_xact_user_functions x
  where x.funcid = 'private.remittance_statement_paid_by_unplanned(uuid, timestamptz)'::regprocedure $$;
grant execute on all functions in schema pg_temp to authenticated;

-- The base: an unidentified payment of 1 000 000 three days ago and yesterday's statement holding it (the cash the
-- files' checks see); no run
select pg_temp.collect('00', 1000000, private.paris_today() - 3, false);
select pg_temp.stmt('00', private.paris_today() - 1);


-- A. The window (critic L17) ------------------------------------------------------------------------------------------
-- Martin's RV1 (164 000) approved and handed out, its debit booked yesterday (after K₁); RV2 (82 000) approved and
-- handed out, its statement drawn; RV2's debit booked today (after K₂); RV3 (41 000) approved
create or replace function pg_temp.a_window() returns jsonb language plpgsql as $$
declare v_x1 uuid; v_x2 uuid; w jsonb; s1 jsonb; s2 jsonb;
begin
  v_x1 := pg_temp.queued('a1', '11', 200000, 'a1');
  insert into t values ('RV1', pg_temp.v('run-a1'));
  perform pg_temp.handed_out('fa1', 'gen-x038-a1');
  s1 := private.remittance_statement_build(pg_temp.v('RV1')) -> 'previous_payouts';
  w := jsonb_build_object('rv1', pg_temp.suivi(pg_temp.v('RV1')));
  perform pg_temp.stmt2('a11', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(v_x1))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('a11', 1), 'payout', v_x1)));
  v_x2 := pg_temp.queued('a1', '12', 100000, 'a2');
  insert into t values ('RV2', pg_temp.v('run-a2'));
  perform pg_temp.handed_out('fa2', 'gen-x038-a2');
  s2 := private.remittance_statement_build(pg_temp.v('RV2')) -> 'previous_payouts';
  w := w || jsonb_build_object('rv2', pg_temp.suivi(pg_temp.v('RV2')));
  perform pg_temp.stmt2('a12', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_x2))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('a12', 1), 'payout', v_x2)));
  perform pg_temp.queued('a1', '13', 50000, 'a3');
  insert into t values ('RV3', pg_temp.v('run-a3'));
  return w || jsonb_build_object(
    'rv3', pg_temp.suivi(pg_temp.v('RV3')),
    'rv2_later', private.remittance_statement_build(pg_temp.v('RV2')) -> 'previous_payouts' = s2,
    'rv1_later', private.remittance_statement_build(pg_temp.v('RV1')) -> 'previous_payouts' = s1,
    -- (M2c-6b-3b part 3 review round 1: the runs share their transaction's created_at — their numbers, drawn from one
    -- sequence as they are requested, keep their order whatever plan reads them)
    'runs', (select jsonb_agg(r.status order by r.created_at, r.number) from public.remittance_run r
             where r.client_organization_id = pg_temp.c('a1')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('a_window'),
  '{"rv1": {"since": null, "events": []},
    "rv2": {"since": ["RV1", true], "events": [{"kind": "debited", "run_number": "RV1", "amount_minor": "164000",
                                                 "end_to_end_id": "chain:0", "on": "d-1"}]},
    "rv3": {"since": ["RV2", true], "events": [{"kind": "debited", "run_number": "RV2", "amount_minor": "82000",
                                                 "end_to_end_id": "chain:0", "on": "d0"}]},
    "rv2_later": true, "rv1_later": true, "runs": ["booked", "booked", "approved"]}'::jsonb,
  'A (plan §5, critic L17): RV1''s debit booked after K₁ is in RV2''s « Suivi » with its date and reference; RV2''s own '
  'debit booked after K₂ is not in RV2 (drawn again after it: the same « Suivi ») but in RV3, whose window starts at '
  'K₂ (RV1''s debit not repeated); a first statement has nothing to follow');

-- B. A return: here, pending; a run cancelled before its file (`cancelled`) ------------------------------------------
-- Lilas' RV1 (164 000) debited two days ago, returned yesterday (after K₁); RV2 holds the return item, then is cancelled
-- before its statement is drawn again (no file); RV3 holds it next
create or replace function pg_temp.b_returned() returns jsonb language plpgsql as $$
declare v_x uuid; w jsonb;
begin
  v_x := pg_temp.queued('a2', '21', 200000, 'b1');
  insert into t values ('RV1', pg_temp.v('run-b1'));
  perform pg_temp.handed_out('fb1', 'gen-x038-b1');
  perform pg_temp.stmt2('b11', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('b11', 1), 'payout', v_x)));
  perform pg_temp.stmt2('b12', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('b12', 1), 'payout_returned', v_x)));
  perform pg_temp.reconfirm('a2');
  insert into t values ('RV2', pg_temp.request('a2', 'b2'));
  perform pg_temp.prepare_plain(pg_temp.v('RV2'));
  w := jsonb_build_object('rv2_approved', pg_temp.approve_plain(pg_temp.v('RV2'), 'b2'),
                          'rv2', pg_temp.suivi(pg_temp.v('RV2')));
  perform pg_temp.cancel_run(pg_temp.v('RV2'), 'b2');
  w := w || jsonb_build_object('rv2_cancelled', pg_temp.suivi(pg_temp.v('RV2')));
  insert into t values ('RV3', pg_temp.request('a2', 'b3'));
  perform pg_temp.prepare_plain(pg_temp.v('RV3'));
  w := w || jsonb_build_object('rv3_approved', pg_temp.approve_plain(pg_temp.v('RV3'), 'b3'),
                               'rv3', pg_temp.suivi(pg_temp.v('RV3')));
  -- (review round 1 tests-2) RV2's statement drawn again once RV3 (approved after RV2's K) holds the item: still pending
  return w || jsonb_build_object('rv2_rebuilt', pg_temp.suivi(pg_temp.v('RV2')) = w -> 'rv2_cancelled');
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('b_returned'),
  '{"rv2_approved": "approved:approved",
    "rv2": {"since": ["RV1", true], "events": [
      {"kind": "debited", "run_number": "RV1", "amount_minor": "164000", "end_to_end_id": "chain:0", "on": "d-2"},
      {"kind": "returned", "run_number": "RV1", "amount_minor": "164000", "end_to_end_id": "chain:0",
       "debited_on": "d-2", "on": "d-1", "repaid": "here", "repaid_by": null}]},
    "rv2_cancelled": {"since": ["RV1", true], "events": [
      {"kind": "debited", "run_number": "RV1", "amount_minor": "164000", "end_to_end_id": "chain:0", "on": "d-2"},
      {"kind": "returned", "run_number": "RV1", "amount_minor": "164000", "end_to_end_id": "chain:0",
       "debited_on": "d-2", "on": "d-1", "repaid": "pending", "repaid_by": null}]},
    "rv3_approved": "approved:approved",
    "rv3": {"since": ["RV2", true], "events": [{"kind": "cancelled", "run_number": "RV2", "on": "d0"}]},
    "rv2_rebuilt": true}'::jsonb,
  'B (plan §5): a return after K₁ held by RV2 is `returned`, `here`, with its debit''s date; RV2 cancelled before its '
  'statement is drawn says `pending` (the item back in the queue), and still does once RV3, approved after RV2''s K, '
  'holds it (as of K); RV3''s window starts at RV2''s K: RV2 `cancelled` before its file, the return not repeated');

-- C. A cancelled run's payout executed late, booked unplanned (switch on; critic F17, L9, critic2 ML-9) --------------
-- Roux: P = A = 164 000 (its run's released items, still waiting), attributed 100 000 to c1 and 64 000 to c2; RV2
-- prepared with every line late and approved; then the unplanned booking returned (after RV2's K)
create or replace function pg_temp.c_late() returns jsonb language plpgsql as $$
declare v_x uuid; v_d uuid; v_s0 bigint; v_b0 bigint; v_f0 bigint; v_k timestamptz; v_entries uuid[]; w jsonb;
        s jsonb;
begin
  v_x := pg_temp.cancelled_after_download('a5', 'c');
  v_d := pg_temp.v('RV2');
  w := jsonb_build_object('booked', pg_temp.bkx(pg_temp.l2('c1', 1), pg_temp.prop(pg_temp.l2('c1', 1))));
  perform pg_temp.prepare_late(v_d, private.paris_today() - 5);
  w := w || jsonb_build_object('approved', pg_temp.approve_late(v_d, 'c-r2'));
  s := jsonb_build_object('suivi', pg_temp.suivi(v_d), 'c1', pg_temp.lf(v_d, pg_temp.alloc('c1')),
                          'c2', pg_temp.lf(v_d, pg_temp.alloc('c2')));
  w := w || s || jsonb_build_object(
    'unplanned_line', pg_temp.lf(v_d, pg_temp.ek('remit:line:' || pg_temp.l2('c1', 1) || ':1')));
  -- (R) the reads, keyed: the « Suivi » and the late cause of each of RV2's lines (read before the count starts)
  v_k := (select known_at from public.remittance_run where id = v_d);
  v_entries := array(select l.ledger_entry_id from public.remittance_line l where l.run_id = v_d);
  v_s0 := pg_temp.scans();
  v_b0 := pg_temp.booking_reads();
  execute 'select private.remittance_statement_previous_payouts($1)' using v_d;
  execute 'select count(*) from unnest($1::uuid[]) e (id)
           cross join lateral private.remittance_statement_paid_by_unplanned(e.id, $2) u' using v_entries, v_k;
  w := w || jsonb_build_object('seq_scans', pg_temp.scans() - v_s0, 'booking_reads', pg_temp.booking_reads() - v_b0);
  -- (R) the build calls the late cause's helper for RV2's late lines only (c1, c2), not for its unplanned line
  v_f0 := pg_temp.helper_calls();
  perform private.remittance_statement_build(v_d);
  w := w || jsonb_build_object('helper_calls', pg_temp.helper_calls() - v_f0,
                               'lines', (select count(*) from public.remittance_line l where l.run_id = v_d));
  -- the unplanned booking returned after RV2's K: as of K it paid the lines, and its return is not in RV2's window
  perform pg_temp.stmt2('c3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(v_x))));
  w := w || jsonb_build_object('returned', pg_temp.bkx(pg_temp.l2('c3', 1), pg_temp.prop(pg_temp.l2('c3', 1))));
  return w || jsonb_build_object('after_return', jsonb_build_object(
    'suivi', pg_temp.suivi(v_d), 'c1', pg_temp.lf(v_d, pg_temp.alloc('c1')), 'c2', pg_temp.lf(v_d, pg_temp.alloc('c2')))
    = s);
end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into j select 'c', pg_temp.iso('c_late');
select is((select v - 'seq_scans' - 'booking_reads' - 'helper_calls' - 'lines' from j where k = 'c'),
  '{"booked": "ok", "approved": ":approved",
    "suivi": {"since": ["RV1", true], "events": [
      {"kind": "executed_after_cancellation", "run_number": "RV1", "cancelled_on": "d0", "unplanned_minor": "164000",
       "advance_minor": "0", "p_bound": "amount", "execution_no": 1, "on": "d0", "here": true}]},
    "c1": {"nature": "allocation", "reason": null, "late": true, "cause": "paid_by_unplanned", "paid": "100000",
           "paid_on": "d0"},
    "c2": {"nature": "allocation", "reason": null, "late": true, "cause": "identified_late", "paid": "64000",
           "paid_on": "d0"},
    "unplanned_line": {"nature": "unplanned_payout", "reason": null, "late": false, "cause": null, "paid": null,
                       "paid_on": null},
    "returned": "ok", "after_return": true}'::jsonb,
  'C (switch on; plan §5, critic F17, L9, critic2 ML-9): a run cancelled after download whose payout the bank executes '
  'late, booked unplanned, is `executed_after_cancellation` (never `cancelled` too, its first execution), here, P = A: '
  'no advance; the late line its P paid in full is « versé le … » with the booking''s date (c1); the one it paid in '
  'part keeps its own cause, the amount attributed and the date beside it (c2: review round 1 legal-texts-3); the '
  'booking returned after K changes neither the lines nor the window');
select is((select jsonb_build_array(v -> 'seq_scans', v -> 'booking_reads') from j where k = 'c'), '[0, 1]'::jsonb,
  'R (plan §5 read cost): « Suivi » and the late cause read every table by key (no sequential scan: runs, transfers, '
  'bookings, entries, advances, lines, statement lines, attributions), and of the bookings only the one of RV1''s chain '
  '(the transfer-less probes read only the servicer''s unplanned payouts without a transfer and their returns: none)');
select is((select jsonb_build_array(v -> 'helper_calls', v -> 'lines') from j where k = 'c'), '[2, 3]'::jsonb,
  'R (plan §5 read cost; scale run: 50 000 lines, none late): the build reads the late cause''s attributions for its '
  'late lines only — one call each for RV2''s c1 and c2, none for its unplanned line');

-- C2. The same booking returned before K (critic2 ML-9, critic L4) ---------------------------------------------------
create or replace function pg_temp.c_reversed() returns jsonb language plpgsql as $$
declare v_x uuid; v_d uuid; w jsonb;
begin
  v_x := pg_temp.cancelled_after_download('a5', 'b');
  v_d := pg_temp.v('RV2');
  w := jsonb_build_object('booked', pg_temp.bkx(pg_temp.l2('b1', 1), pg_temp.prop(pg_temp.l2('b1', 1))));
  perform pg_temp.stmt2('b3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(v_x))));
  w := w || jsonb_build_object('returned', pg_temp.bkx(pg_temp.l2('b3', 1), pg_temp.prop(pg_temp.l2('b3', 1))));
  perform pg_temp.reconfirm('a5');   -- the return marked Roux's payout account returned
  perform pg_temp.prepare_late(v_d, private.paris_today() - 5);
  return w || jsonb_build_object(
    'approved', pg_temp.approve_late(v_d, 'b-r2'), 'suivi', pg_temp.suivi(v_d),
    'k1', pg_temp.lf(v_d, pg_temp.alloc('b1')), 'k2', pg_temp.lf(v_d, pg_temp.alloc('b2')),
    'return_line', pg_temp.lf(v_d, (select e.id from public.ledger_entry e
                                     where e.reverses_entry_id = pg_temp.ek('remit:line:' || pg_temp.l2('b1', 1) || ':1'))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('c_reversed'),
  '{"booked": "ok", "returned": "ok", "approved": ":approved",
    "suivi": {"since": ["RV1", true], "events": [
      {"kind": "executed_after_cancellation", "run_number": "RV1", "cancelled_on": "d0", "unplanned_minor": "164000",
       "advance_minor": "0", "p_bound": "amount", "execution_no": 1, "on": "d0", "here": true},
      {"kind": "unplanned_returned", "run_number": "RV1", "unplanned_minor": "164000", "advance_minor": "0",
       "owed_minor": "164000", "executed_on": "d0", "on": "d0", "here": true}]},
    "k1": {"nature": "allocation", "reason": null, "late": true, "cause": "identified_late", "paid": null,
           "paid_on": null},
    "k2": {"nature": "allocation", "reason": null, "late": true, "cause": "identified_late", "paid": null,
           "paid_on": null},
    "return_line": {"nature": "payout_returned", "reason": "unplanned", "late": true,
                    "cause": "unplanned_payout_returned", "paid": null, "paid_on": null}}'::jsonb,
  'C2 (critic2 ML-9, critic L4): an unplanned booking returned before K no longer counts: the lines keep their own '
  'cause; its return is `unplanned_returned` (P owed again), here, and its line keeps the unplanned nature');

-- D. P bounded by the queue (critic2 ML-9: all of the run still owed) ------------------------------------------------
-- (M2c-7a, ADR-0014 « M2c-7a », R3) a remitted collection taken back WITHOUT its cover — the state M2c-7a forbids at every
-- commit (LG009) — planted for the Suivi's wording of a payout whose P the client's queue bounds, which only such a state
-- produced here: the cover's check is set aside while these three scenarios run (its trigger disabled at the top level
-- around their calls, once the pending events are run, then enabled again; PostgreSQL refuses the ALTER inside the
-- scenario's subtransaction); every assertion below is unchanged
create or replace function pg_temp.raw_bounce(p_entry uuid, p_key text, p_day date) returns void language plpgsql as $$
begin
  perform private.ledger_reverse(p_entry, p_key, 'Retour du paiement (test)', p_day);
end $$;
create or replace function pg_temp.cover_check(p_on boolean) returns void language plpgsql as $$
begin
  set constraints all immediate;
  set constraints all deferred;
  if p_on then
    alter table public.ledger_entry enable always trigger ledger_entry_remitted_cover;
  else
    alter table public.ledger_entry disable trigger ledger_entry_remitted_cover;
  end if;
end $$;
-- Durand's R0 (127 920) booked, its collection then taken back (−156 000 waits); RV1 (164 000) handed out, then
-- cancelled after download: the queue nets 44 000; the late execution's P = 44 000 (queue), the advance 120 000
create or replace function pg_temp.d_queue() returns jsonb language plpgsql as $$
declare v_t0 uuid; v_x uuid; v_d uuid; w jsonb;
begin
  v_t0 := pg_temp.queued('a7', '70', 156000, 'd0');
  insert into t values ('RV0', pg_temp.v('run-d0'));
  perform pg_temp.handed_out('fd0', 'gen-x038-d0');
  perform pg_temp.stmt2('d01', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', 127920, 'e2e', pg_temp.e2e(v_t0))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('d01', 1), 'payout', v_t0)));
  v_x := pg_temp.queued('a7', '71', 200000, 'd1');
  insert into t values ('RV1', pg_temp.v('run-d1'));
  perform pg_temp.handed_out('fd1', 'gen-x038-d1');
  perform pg_temp.raw_bounce(pg_temp.alloc('70'), 'rev-x038-d70', private.paris_today() - 1);
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_x;
  perform pg_temp.cancel_run(pg_temp.v('RV1'), 'd1');
  v_d := pg_temp.request('a7', 'd-r2');
  insert into t values ('RV2', v_d);
  perform pg_temp.stmt2('d11', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(v_x))));
  w := jsonb_build_object('queue', pg_temp.queued_minor('a7'),
                          'booked', pg_temp.bkx(pg_temp.l2('d11', 1), pg_temp.prop(pg_temp.l2('d11', 1))));
  perform pg_temp.prepare_late(v_d, private.paris_today() - 5);
  return w || jsonb_build_object('approved', pg_temp.approve_late(v_d, 'd-r2'), 'suivi', pg_temp.suivi(v_d),
                                 'd71', pg_temp.lf(v_d, pg_temp.alloc('71')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select pg_temp.cover_check(false);
select is(pg_temp.iso('d_queue'),
  '{"queue": 44000, "booked": "ok", "approved": ":booked",
    "suivi": {"since": ["RV1", true], "events": [
      {"kind": "executed_after_cancellation", "run_number": "RV1", "cancelled_on": "d0", "unplanned_minor": "164000",
       "advance_minor": "120000", "p_bound": "queue", "execution_no": 1, "on": "d0", "here": true}]},
    "d71": {"nature": "allocation", "reason": null, "late": true, "cause": "identified_late", "paid": "44000",
            "paid_on": "d0"}}'::jsonb,
  'D (critic2 ML-9): all of the cancelled run still owed, P bounded by the queue (44 000): `p_bound` queue and the '
  'advance (the clause the renderer words by it), the late line paid in part (its own cause kept, the amount and date '
  'beside it)');
select pg_temp.cover_check(true);

-- E. P bounded by the items --------------------------------------------------------------------------------------------
-- Dupont: RV1 (164 000) cancelled after download; e2 taken back by the payer's bank (its chain nets 0), e3 (50 000)
-- arrives; the late execution's P = 100 000 (the items' signed net), the advance 64 000
create or replace function pg_temp.e_items() returns jsonb language plpgsql as $$
declare v_x uuid; v_d uuid; w jsonb;
begin
  v_x := pg_temp.cancelled_after_download('a6', 'e');
  v_d := pg_temp.v('RV2');
  perform private.ledger_reverse(pg_temp.alloc('e2'), 'rev-x038-e2', 'Retour du paiement (test)', private.paris_today());
  perform pg_temp.file('e3', '20000000-0000-0000-0000-0000000000a6', 50000);
  perform pg_temp.collect('e3', 50000, private.paris_today());
  w := jsonb_build_object('booked', pg_temp.bkx(pg_temp.l2('e1', 1), pg_temp.prop(pg_temp.l2('e1', 1))));
  perform pg_temp.prepare_plain(v_d);
  return w || jsonb_build_object('approved', pg_temp.approve_plain(v_d, 'e-r2'), 'suivi', pg_temp.suivi(v_d));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('e_items'),
  '{"booked": "ok", "approved": "approved:approved",
    "suivi": {"since": ["RV1", true], "events": [
      {"kind": "executed_after_cancellation", "run_number": "RV1", "cancelled_on": "d0", "unplanned_minor": "164000",
       "advance_minor": "64000", "p_bound": "items", "execution_no": 1, "on": "d0", "here": true}]}}'::jsonb,
  'E (critic F17, critic2 ML-9): P bounded by what was still owed of the run''s items (a collection taken back since): '
  '`p_bound` items and the advance');

-- F. S03: a booked payout debited a second time, then its copy back -------------------------------------------------
create or replace function pg_temp.f_twice() returns jsonb language plpgsql as $$
declare v_x uuid; v_t2 uuid; w jsonb;
begin
  v_x := pg_temp.queued('a4', '41', 100000, 'f1');        -- RV1: 82 000 to Lambert
  insert into t values ('RV1', pg_temp.v('run-f1'));
  perform pg_temp.handed_out('ff1', 'gen-x038-f1');
  perform pg_temp.stmt2('f11', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('f11', 1), 'payout', v_x)));
  perform pg_temp.stmt2('f12', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_x))));
  w := jsonb_build_object('second', pg_temp.bkx(pg_temp.l2('f12', 1), pg_temp.prop(pg_temp.l2('f12', 1))));
  perform pg_temp.file('42', '20000000-0000-0000-0000-0000000000a4', 50000);
  perform pg_temp.collect('42', 50000, private.paris_today() - 1);
  insert into t values ('RV2', pg_temp.request('a4', 'f2'));
  perform pg_temp.prepare_plain(pg_temp.v('RV2'));
  w := w || jsonb_build_object('rv2_approved', pg_temp.approve_plain(pg_temp.v('RV2'), 'f2'),
                               'rv2', pg_temp.suivi(pg_temp.v('RV2')));
  v_t2 := (select transfer_id from public.remittance_run where id = pg_temp.v('RV2'));
  perform pg_temp.handed_out('ff2', 'gen-x038-f2');
  perform pg_temp.stmt2('f13', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 50000, 'e2e', pg_temp.e2e(v_t2))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('f13', 1), 'payout', v_t2)));
  perform pg_temp.stmt2('f14', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 82000, 'orig', pg_temp.e2e(v_x))));
  w := w || jsonb_build_object('back', pg_temp.bkx(pg_temp.l2('f14', 1), pg_temp.prop(pg_temp.l2('f14', 1))));
  perform pg_temp.file('43', '20000000-0000-0000-0000-0000000000a4', 30000);
  perform pg_temp.collect('43', 30000, private.paris_today());
  perform pg_temp.reconfirm('a4');   -- the copy's return marked Lambert's payout account returned
  insert into t values ('RV3', pg_temp.request('a4', 'f3'));
  perform pg_temp.prepare_plain(pg_temp.v('RV3'));
  return w || jsonb_build_object(
    'rv3_approved', pg_temp.approve_plain(pg_temp.v('RV3'), 'f3'), 'rv3', pg_temp.suivi(pg_temp.v('RV3')),
    'rv3_line', pg_temp.lf(pg_temp.v('RV3'), (select e.id from public.ledger_entry e where e.reverses_entry_id
                                               = pg_temp.ek('remit:line:' || pg_temp.l2('f12', 1) || ':1'))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('f_twice'),
  '{"second": "ok", "rv2_approved": "approved:approved",
    "rv2": {"since": ["RV1", true], "events": [
      {"kind": "debited", "run_number": "RV1", "amount_minor": "82000", "end_to_end_id": "chain:0", "on": "d-1"},
      {"kind": "debited_again", "run_number": "RV1", "unplanned_minor": "82000", "advance_minor": "82000",
       "p_bound": "none", "execution_no": 2, "debited_on": "d-1", "before_debit": false, "on": "d0", "here": true}]},
    "back": "ok", "rv3_approved": "approved:approved",
    "rv3": {"since": ["RV2", true], "events": [
      {"kind": "unplanned_returned", "run_number": "RV1", "unplanned_minor": "82000", "advance_minor": "82000",
       "owed_minor": "0", "executed_on": "d0", "on": "d0", "here": true},
      {"kind": "debited", "run_number": "RV2", "amount_minor": "50000", "end_to_end_id": "chain:0", "on": "d0"}]},
    "rv3_line": {"nature": "payout_returned", "reason": "unplanned", "late": false, "cause": null, "paid": null,
                 "paid_on": null}}'::jsonb,
  'F (S03, S28; critic L13, L4): a booked payout debited again is `debited_again` (P = 0: no items, the advance all of '
  'it, `none`; its second execution, after the planned debit of d-1); its copy back is `unplanned_returned` in the next window (nothing owed again), events by date then run '
  'number, its line the unplanned nature');

-- G. S13: a debit to the client's payout IBAN with no transfer of ours (critic L16, critic2 ML-11) ------------------
create or replace function pg_temp.g_outside() returns jsonb language plpgsql as $$
declare v_t1 uuid; w jsonb;
begin
  perform pg_temp.stmt2('611', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 5000, 'kind', 'other_debit', 'iban', pg_temp.iban('a8'))));
  w := jsonb_build_object('s13', pg_temp.bkx(pg_temp.l2('611', 1), jsonb_build_array(
                                   pg_temp.pt('unplanned_payout', null, 5000, pg_temp.c('a8')))));
  perform pg_temp.file('81', '20000000-0000-0000-0000-0000000000a8', 40000);
  perform pg_temp.collect('81', 40000, private.paris_today() - 1);
  insert into t values ('RV1', pg_temp.request('a8', 'g1'));
  perform pg_temp.prepare_plain(pg_temp.v('RV1'));
  w := w || jsonb_build_object('rv1_approved', pg_temp.approve_plain(pg_temp.v('RV1'), 'g1'),
                               'rv1', pg_temp.suivi(pg_temp.v('RV1')));
  v_t1 := (select transfer_id from public.remittance_run where id = pg_temp.v('RV1'));
  perform pg_temp.handed_out('fg1', 'gen-x038-g1');
  perform pg_temp.stmt2('612', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 40000, 'e2e', pg_temp.e2e(v_t1))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('612', 1), 'payout', v_t1)));
  perform pg_temp.stmt2('613', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 5000, 'iban', pg_temp.iban('a8'))));
  w := w || jsonb_build_object('back', pg_temp.bkx(pg_temp.l2('613', 1), pg_temp.prop(pg_temp.l2('613', 1))));
  perform pg_temp.file('82', '20000000-0000-0000-0000-0000000000a8', 20000);
  perform pg_temp.collect('82', 20000, private.paris_today());
  perform pg_temp.reconfirm('a8');   -- the return marked Petit's payout account returned
  insert into t values ('RV2', pg_temp.request('a8', 'g2'));
  perform pg_temp.prepare_plain(pg_temp.v('RV2'));
  return w || jsonb_build_object('rv2_approved', pg_temp.approve_plain(pg_temp.v('RV2'), 'g2'),
                                 'rv2', pg_temp.suivi(pg_temp.v('RV2')), 'last4', right(pg_temp.iban('a8'), 4));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('g_outside'),
  '{"s13": "ok", "rv1_approved": "approved:approved",
    "rv1": {"since": null, "events": [
      {"kind": "executed_outside", "run_number": null, "amount_minor": "5000", "advance_minor": "5000",
       "iban_last4": "4350", "on": "d0", "here": true}]},
    "back": "ok", "rv2_approved": "approved:approved",
    "rv2": {"since": ["RV1", true], "events": [
      {"kind": "debited", "run_number": "RV1", "amount_minor": "40000", "end_to_end_id": "chain:0", "on": "d0"},
      {"kind": "unplanned_returned", "run_number": null, "unplanned_minor": "5000", "advance_minor": "5000",
       "owed_minor": "0", "executed_on": "d0", "on": "d0", "here": true}]},
    "last4": "4350"}'::jsonb,
  'G (S13; critic L16, critic2 ML-11): a debit to the client''s payout IBAN with no transfer of ours is '
  '`executed_outside` (the IBAN''s last four characters, the advance), listed by a first statement; its return is '
  '`unplanned_returned` with no run, after the run''s debit of the same day');

-- H. The run's chain (switch on; critic2 ML-12) ----------------------------------------------------------------------
-- Moreau's x (24 600) handed out, cancelled and re-issued as x' (the run's transfer now x'), then the run cancelled;
-- the bank executes x
create or replace function pg_temp.h_chain() returns jsonb language plpgsql as $$
declare v_y uuid; v_y2 uuid; v_d uuid; w jsonb;
begin
  v_y := pg_temp.inflight('a9', '91', 30000, 'x038h1');
  insert into t values ('RV1', pg_temp.v('run-x038h1'));
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_y;
  alter table public.bank_transfer disable trigger user;
  insert into public.bank_transfer (id, organization_id, kind, debtor_bank_account_id, currency, amount_minor,
                                    payee_name, payee_iban, end_to_end_id, requested_execution_date, status,
                                    client_organization_id, run_id, replaces_transfer_id)
  select gen_random_uuid(), y.organization_id, y.kind, y.debtor_bank_account_id, y.currency, y.amount_minor,
         y.payee_name, y.payee_iban, 'RMT00000000C9A2', y.requested_execution_date, 'ordered',
         y.client_organization_id, y.run_id, y.id
  from public.bank_transfer y where y.id = v_y
  returning id into v_y2;
  alter table public.bank_transfer enable trigger user;
  alter table public.remittance_run disable trigger user;
  update public.remittance_run set transfer_id = v_y2 where id = pg_temp.v('RV1');
  alter table public.remittance_run enable trigger user;
  perform pg_temp.cancel_run(pg_temp.v('RV1'), 'h1');
  v_d := pg_temp.request('a9', 'h-r2');
  insert into t values ('RV2', v_d);
  -- (review round 1 tests-3) the bank executed x yesterday, the run cancelled today: two dates
  perform pg_temp.stmt2('911', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 24600, 'e2e', pg_temp.e2e(v_y))));
  w := jsonb_build_object('booked', pg_temp.bkx(pg_temp.l2('911', 1), pg_temp.prop(pg_temp.l2('911', 1))),
                          'run_transfer', (select transfer_id from public.remittance_run where id = pg_temp.v('RV1'))
                                          = v_y2);
  perform pg_temp.prepare_plain(v_d);
  return w || jsonb_build_object('approved', pg_temp.approve_plain(v_d, 'h-r2'), 'suivi', pg_temp.suivi(v_d));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('h_chain'),
  '{"booked": "ok", "run_transfer": true, "approved": "approved:approved",
    "suivi": {"since": ["RV1", true], "events": [
      {"kind": "executed_after_cancellation", "run_number": "RV1", "cancelled_on": "d0", "unplanned_minor": "24600",
       "advance_minor": "0", "p_bound": "amount", "execution_no": 1, "on": "d-1", "here": true}]}}'::jsonb,
  'H (switch on; critic2 ML-12): a run whose payout was re-issued, then cancelled, the bank executing the old transfer '
  'and booked unplanned: `executed_after_cancellation`, read on the run''s chain (not `cancelled`), with the '
  'cancellation''s date and the execution''s own');

-- I. What bounds the window and what is never listed (critic L7; N = 0; other clients) ------------------------------
-- Cyprès' RV0 holds a collection and its return (gross 0, N = 0: settled at approval); a draft RV9 prepared and
-- discarded; Lambert's payout debited and Lambert's S13 booked meanwhile; Cyprès' RV1
create or replace function pg_temp.i_bounds() returns jsonb language plpgsql as $$
declare v_t4 uuid; w jsonb;
begin
  perform pg_temp.file('31', '20000000-0000-0000-0000-0000000000a3', 30000);
  perform pg_temp.collect('31', 30000, private.paris_today() - 3);
  perform private.ledger_reverse(pg_temp.alloc('31'), 'rev-x038-i31', 'Retour du paiement (test)', private.paris_today() - 2);
  insert into t values ('RV0', pg_temp.request('a3', 'i0'));
  perform pg_temp.prepare_plain(pg_temp.v('RV0'));
  w := jsonb_build_object('rv0', pg_temp.approve_plain(pg_temp.v('RV0'), 'i0'),
                          'rv0_suivi', pg_temp.suivi(pg_temp.v('RV0')));
  perform pg_temp.file('32', '20000000-0000-0000-0000-0000000000a3', 20000);
  perform pg_temp.collect('32', 20000, private.paris_today() - 1);
  insert into t values ('RV9', pg_temp.request('a3', 'i9'));
  perform pg_temp.prepare_plain(pg_temp.v('RV9'));
  perform pg_temp.as_user('04');
  set local role authenticated;
  perform public.discard_remittance_run('discard-i9', pg_temp.v('RV9'),
                                        (select version from public.remittance_run where id = pg_temp.v('RV9')),
                                        'abandonné (test)');
  reset role;
  v_t4 := pg_temp.queued('a4', '44', 10000, 'i4');
  perform pg_temp.handed_out('fi4', 'gen-x038-i4');
  perform pg_temp.stmt2('341', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 8200, 'e2e', pg_temp.e2e(v_t4)),
    jsonb_build_object('amount', 7000, 'kind', 'other_debit', 'iban', pg_temp.iban('a4'))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('341', 1), 'payout', v_t4)));
  w := w || jsonb_build_object('s13', pg_temp.bkx(pg_temp.l2('341', 2), jsonb_build_array(
                                        pg_temp.pt('unplanned_payout', null, 7000, pg_temp.c('a4')))));
  insert into t values ('RV1', pg_temp.request('a3', 'i1'));
  perform pg_temp.prepare_plain(pg_temp.v('RV1'));
  return w || jsonb_build_object(
    'rv9', (select jsonb_build_array(r.status, r.approved_at is null) from public.remittance_run r
            where r.id = pg_temp.v('RV9')),
    'rv1', pg_temp.approve_plain(pg_temp.v('RV1'), 'i1'), 'rv1_suivi', pg_temp.suivi(pg_temp.v('RV1')),
    'lambert', (select count(*) from public.bank_line_booking k
                where k.bank_transaction_id in (pg_temp.l2('341', 1), pg_temp.l2('341', 2))));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('i_bounds'),
  '{"rv0": "booked:booked", "rv0_suivi": {"since": null, "events": []}, "s13": "ok",
    "rv9": ["cancelled", true], "rv1": "approved:approved", "rv1_suivi": {"since": ["RV0", true], "events": []},
    "lambert": 2}'::jsonb,
  'I (critic L7, plan §8.1): an N = 0 run bounds the window and is never listed; a prepared draft discarded with its '
  'RV number neither bounds it nor is listed; another client''s debit and S13 booking in the window are never listed');

-- Review round 1 (ADR-0014 « M2c-6b-2d review fixes ») ------------------------------------------------------------

-- F-before (statement-money): the bank debits Lambert's x on d-2 and on d-1; the d-1 statement is imported first (the
-- planned payout), the d-2 one later, booked unplanned (switch off)
create or replace function pg_temp.f_before() returns jsonb language plpgsql as $$
declare v_x uuid; w jsonb;
begin
  v_x := pg_temp.queued('a4', '41', 100000, 'fb1');        -- RV1: 82 000 to Lambert
  insert into t values ('RV1', pg_temp.v('run-fb1'));
  perform pg_temp.handed_out('ffb1', 'gen-x038-fb1');
  perform pg_temp.stmt2('fb1', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('fb1', 1), 'payout', v_x)));
  perform pg_temp.stmt2('fb2', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_x))));
  w := jsonb_build_object('earlier', pg_temp.bkx(pg_temp.l2('fb2', 1), pg_temp.prop(pg_temp.l2('fb2', 1))));
  perform pg_temp.file('42', '20000000-0000-0000-0000-0000000000a4', 50000);
  perform pg_temp.collect('42', 50000, private.paris_today() - 1);
  insert into t values ('RV2', pg_temp.request('a4', 'fb2'));
  perform pg_temp.prepare_plain(pg_temp.v('RV2'));
  return w || jsonb_build_object('rv2_approved', pg_temp.approve_plain(pg_temp.v('RV2'), 'fb2'),
                                 'rv2', pg_temp.suivi(pg_temp.v('RV2')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('f_before'),
  '{"earlier": "ok", "rv2_approved": "approved:approved",
    "rv2": {"since": ["RV1", true], "events": [
      {"kind": "debited_again", "run_number": "RV1", "unplanned_minor": "82000", "advance_minor": "82000",
       "p_bound": "none", "execution_no": 1, "debited_on": "d-1", "before_debit": true, "on": "d-2", "here": true},
      {"kind": "debited", "run_number": "RV1", "amount_minor": "82000", "end_to_end_id": "chain:0", "on": "d-1"}]}}'::jsonb,
  'F-before (review round 1 statement-money): a debit the bank made before the planned one but booked after it is its '
  'chain''s first execution, `before_debit`, with the planned debit''s date — never « une seconde fois »');

-- F-thrice (legal-texts-1, tests-1): Lambert's booked payout executed a second time (booked as the sheet proposes),
-- RV2 approved, then cancelled before its statement is drawn; the payout executed a third time; RV3 approved (its window
-- holds the third execution alone)
create or replace function pg_temp.f_thrice() returns jsonb language plpgsql as $$
declare v_x uuid; w jsonb;
begin
  v_x := pg_temp.queued('a4', '41', 100000, 'f31');
  insert into t values ('RV1', pg_temp.v('run-f31'));
  perform pg_temp.handed_out('ff31', 'gen-x038-f31');
  perform pg_temp.stmt2('f31', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('f31', 1), 'payout', v_x)));
  perform pg_temp.stmt2('f32', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_x))));
  w := jsonb_build_object('second', pg_temp.bkx(pg_temp.l2('f32', 1), pg_temp.prop(pg_temp.l2('f32', 1))));
  perform pg_temp.file('42', '20000000-0000-0000-0000-0000000000a4', 50000);
  perform pg_temp.collect('42', 50000, private.paris_today() - 1);
  insert into t values ('RV2', pg_temp.request('a4', 'f32'));
  perform pg_temp.prepare_plain(pg_temp.v('RV2'));
  w := w || jsonb_build_object('rv2_approved', pg_temp.approve_plain(pg_temp.v('RV2'), 'f32'),
                               'rv2', pg_temp.suivi(pg_temp.v('RV2')));
  perform pg_temp.cancel_run(pg_temp.v('RV2'), 'f32');
  w := w || jsonb_build_object('rv2_cancelled', pg_temp.suivi(pg_temp.v('RV2')));
  -- the third execution (no warning: booked as proposed), in RV3's window only
  perform pg_temp.stmt2('f33', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_x))));
  w := w || jsonb_build_object('third_preview', pg_temp.why(pg_temp.l2('f33', 1), pg_temp.prop(pg_temp.l2('f33', 1))),
                               'third', pg_temp.bkx(pg_temp.l2('f33', 1), pg_temp.prop(pg_temp.l2('f33', 1))));
  -- a fourth the same day, booked after it: listed after it (the day's events in their posting order)
  perform pg_temp.stmt2('f34', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_x))));
  w := w || jsonb_build_object('fourth', pg_temp.bkx(pg_temp.l2('f34', 1), pg_temp.prop(pg_temp.l2('f34', 1))));
  insert into t values ('RV3', pg_temp.request('a4', 'f33'));
  perform pg_temp.prepare_plain(pg_temp.v('RV3'));
  return w || jsonb_build_object('rv3_approved', pg_temp.approve_plain(pg_temp.v('RV3'), 'f33'),
                                 'rv3', pg_temp.suivi(pg_temp.v('RV3')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('f_thrice'),
  '{"second": "ok", "rv2_approved": "approved:approved",
    "rv2": {"since": ["RV1", true], "events": [
      {"kind": "debited", "run_number": "RV1", "amount_minor": "82000", "end_to_end_id": "chain:0", "on": "d-2"},
      {"kind": "debited_again", "run_number": "RV1", "unplanned_minor": "82000", "advance_minor": "82000",
       "p_bound": "none", "execution_no": 2, "debited_on": "d-2", "before_debit": false, "on": "d-1", "here": true}]},
    "rv2_cancelled": {"since": ["RV1", true], "events": [
      {"kind": "debited", "run_number": "RV1", "amount_minor": "82000", "end_to_end_id": "chain:0", "on": "d-2"},
      {"kind": "debited_again", "run_number": "RV1", "unplanned_minor": "82000", "advance_minor": "82000",
       "p_bound": "none", "execution_no": 2, "debited_on": "d-2", "before_debit": false, "on": "d-1",
       "here": false}]},
    "third_preview": "ok", "third": "ok", "fourth": "ok", "rv3_approved": "approved:approved",
    "rv3": {"since": ["RV2", true], "events": [
      {"kind": "debited_again", "run_number": "RV1", "unplanned_minor": "82000", "advance_minor": "82000",
       "p_bound": "none", "execution_no": 3, "debited_on": "d-2", "before_debit": false, "on": "d0", "here": true},
      {"kind": "debited_again", "run_number": "RV1", "unplanned_minor": "82000", "advance_minor": "82000",
       "p_bound": "none", "execution_no": 4, "debited_on": "d-2", "before_debit": false, "on": "d0", "here": true},
      {"kind": "cancelled", "run_number": "RV2", "on": "d0"}]}}'::jsonb,
  'F-thrice (review round 1 legal-texts-1, tests-1): a payout executed a second, a third and a fourth time, each booked as '
  'proposed, each with its rank (only the second is « une seconde fois »; the third''s rank and the planned debit read '
  'outside RV3''s window); RV2 cancelled before its statement is drawn holds the second no longer (`here` false: « pris '
  'en compte dans un prochain reversement »)');

-- H-released (statement-money; switch on, critic2 ML-12's shape): Moreau's x released after download, y re-issued and
-- handed out; the bank executes the old x on d-1 (refused while the run is live) and y on d0; then x is booked
create or replace function pg_temp.h_released() returns jsonb language plpgsql as $$
declare v_y uuid; v_y2 uuid; v_d uuid; w jsonb;
begin
  v_y := pg_temp.inflight('a9', '91', 30000, 'x038hr');
  insert into t values ('RV1', pg_temp.v('run-x038hr'));
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  perform pg_temp.as_user('01');
  perform private.transfer_file_release(pg_temp.v('file-x038hr'), 'superseded', 'annulé après téléchargement (test)',
                                        'not_uploaded', null);
  v_y2 := (select transfer_id from public.remittance_run where id = pg_temp.v('RV1'));
  perform pg_temp.handed_out('fhr2', 'gen-x038-hr2');
  perform pg_temp.stmt2('9a1', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 24600, 'e2e', pg_temp.e2e(v_y))));
  w := jsonb_build_object('reissued', v_y2 <> v_y, 'x_live', pg_temp.op(pg_temp.l2('9a1', 1)) ->> 'refusal');
  perform pg_temp.stmt2('9a2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 24600, 'e2e', pg_temp.e2e(v_y2))));
  w := w || jsonb_build_object('y', pg_temp.bkx(pg_temp.l2('9a2', 1), pg_temp.prop(pg_temp.l2('9a2', 1))),
                               'x', pg_temp.bkx(pg_temp.l2('9a1', 1), pg_temp.prop(pg_temp.l2('9a1', 1))));
  perform pg_temp.file('92', '20000000-0000-0000-0000-0000000000a9', 10000);
  perform pg_temp.collect('92', 10000, private.paris_today());
  v_d := pg_temp.request('a9', 'hr-r2');
  insert into t values ('RV2', v_d);
  perform pg_temp.prepare_plain(v_d);
  return w || jsonb_build_object('approved', pg_temp.approve_plain(v_d, 'hr-r2'), 'suivi', pg_temp.suivi(v_d));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('h_released'),
  '{"reissued": true, "x_live": "reissue_in_downloaded_file", "y": "ok", "x": "ok", "approved": "approved:approved",
    "suivi": {"since": ["RV1", true], "events": [
      {"kind": "debited_again", "run_number": "RV1", "unplanned_minor": "24600", "advance_minor": "24600",
       "p_bound": "none", "execution_no": 1, "debited_on": "d0", "before_debit": true, "on": "d-1", "here": true},
      {"kind": "debited", "run_number": "RV1", "amount_minor": "24600", "end_to_end_id": "chain:0", "on": "d0"}]}}'::jsonb,
  'H-released (switch on; review round 1 statement-money, critic2 ML-12): the old transfer of a re-issued payout, '
  'executed the day before the new one and booked after it, is `before_debit` on the run''s chain');

-- G-same-day (legal-texts-2, tests-1, tests-3): Petit's S13 of 5 000 executed on d-2 and returned on d-1; another of
-- 3 000 executed and returned on d0; RV1 approved, then cancelled before its statement is drawn
create or replace function pg_temp.g_same_day() returns jsonb language plpgsql as $$
declare w jsonb;
begin
  perform pg_temp.stmt2('6a1', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', 5000, 'kind', 'other_debit', 'iban', pg_temp.iban('a8'))));
  w := jsonb_build_object('s13', pg_temp.bkx(pg_temp.l2('6a1', 1), jsonb_build_array(
                                   pg_temp.pt('unplanned_payout', null, 5000, pg_temp.c('a8')))));
  perform pg_temp.stmt2('6a2', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 5000, 'iban', pg_temp.iban('a8'))));
  w := w || jsonb_build_object('back', pg_temp.bkx(pg_temp.l2('6a2', 1), pg_temp.prop(pg_temp.l2('6a2', 1))));
  perform pg_temp.reconfirm('a8');
  perform pg_temp.stmt2('6a3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 3000, 'kind', 'other_debit', 'iban', pg_temp.iban('a8'))));
  w := w || jsonb_build_object('s13b', pg_temp.bkx(pg_temp.l2('6a3', 1), jsonb_build_array(
                                         pg_temp.pt('unplanned_payout', null, 3000, pg_temp.c('a8')))));
  perform pg_temp.stmt2('6a4', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 3000, 'iban', pg_temp.iban('a8'))));
  w := w || jsonb_build_object('backb', pg_temp.bkx(pg_temp.l2('6a4', 1), pg_temp.prop(pg_temp.l2('6a4', 1))));
  perform pg_temp.reconfirm('a8');
  perform pg_temp.file('81', '20000000-0000-0000-0000-0000000000a8', 40000);
  perform pg_temp.collect('81', 40000, private.paris_today() - 1);
  insert into t values ('RV1', pg_temp.request('a8', 'gs1'));
  perform pg_temp.prepare_plain(pg_temp.v('RV1'));
  w := w || jsonb_build_object('rv1_approved', pg_temp.approve_plain(pg_temp.v('RV1'), 'gs1'),
                               'rv1', pg_temp.suivi(pg_temp.v('RV1')));
  perform pg_temp.cancel_run(pg_temp.v('RV1'), 'gs1');
  return w || jsonb_build_object('rv1_cancelled', pg_temp.suivi(pg_temp.v('RV1')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('g_same_day'),
  '{"s13": "ok", "back": "ok", "s13b": "ok", "backb": "ok", "rv1_approved": "approved:approved",
    "rv1": {"since": null, "events": [
      {"kind": "executed_outside", "run_number": null, "amount_minor": "5000", "advance_minor": "5000",
       "iban_last4": "4350", "on": "d-2", "here": true},
      {"kind": "unplanned_returned", "run_number": null, "unplanned_minor": "5000", "advance_minor": "5000",
       "owed_minor": "0", "executed_on": "d-2", "on": "d-1", "here": true},
      {"kind": "executed_outside", "run_number": null, "amount_minor": "3000", "advance_minor": "3000",
       "iban_last4": "4350", "on": "d0", "here": true},
      {"kind": "unplanned_returned", "run_number": null, "unplanned_minor": "3000", "advance_minor": "3000",
       "owed_minor": "0", "executed_on": "d0", "on": "d0", "here": true}]},
    "rv1_cancelled": {"since": null, "events": [
      {"kind": "executed_outside", "run_number": null, "amount_minor": "5000", "advance_minor": "5000",
       "iban_last4": "4350", "on": "d-2", "here": false},
      {"kind": "unplanned_returned", "run_number": null, "unplanned_minor": "5000", "advance_minor": "5000",
       "owed_minor": "0", "executed_on": "d-2", "on": "d-1", "here": false},
      {"kind": "executed_outside", "run_number": null, "amount_minor": "3000", "advance_minor": "3000",
       "iban_last4": "4350", "on": "d0", "here": false},
      {"kind": "unplanned_returned", "run_number": null, "unplanned_minor": "3000", "advance_minor": "3000",
       "owed_minor": "0", "executed_on": "d0", "on": "d0", "here": false}]}}'::jsonb,
  'G-same-day (review round 1 legal-texts-2, tests-1, tests-3): an S13 is listed before its return of the same day; '
  'a return states its execution''s own date; once RV1 is cancelled before its statement is drawn it holds neither '
  '(`here` false)');

-- G-window (tests-2): Petit's RV1 approved; an S13 booked after K₁ (before RV1's statement is drawn); RV1 cancelled;
-- RV2 approved; the S13's return after K₂ (RV2 drawn again); RV2 cancelled; RV3 approved, cancelled; RV4 approved
create or replace function pg_temp.g_window() returns jsonb language plpgsql as $$
declare w jsonb;
begin
  perform pg_temp.file('81', '20000000-0000-0000-0000-0000000000a8', 40000);
  perform pg_temp.collect('81', 40000, private.paris_today() - 1);
  insert into t values ('RV1', pg_temp.request('a8', 'gw1'));
  perform pg_temp.prepare_plain(pg_temp.v('RV1'));
  w := jsonb_build_object('rv1_approved', pg_temp.approve_plain(pg_temp.v('RV1'), 'gw1'));
  perform pg_temp.stmt2('6b1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 5000, 'kind', 'other_debit', 'iban', pg_temp.iban('a8'))));
  w := w || jsonb_build_object('s13', pg_temp.bkx(pg_temp.l2('6b1', 1), jsonb_build_array(
                                        pg_temp.pt('unplanned_payout', null, 5000, pg_temp.c('a8')))),
                               'rv1', pg_temp.suivi(pg_temp.v('RV1')));
  perform pg_temp.cancel_run(pg_temp.v('RV1'), 'gw1');
  insert into t values ('RV2', pg_temp.request('a8', 'gw2'));
  perform pg_temp.prepare_plain(pg_temp.v('RV2'));
  w := w || jsonb_build_object('rv2_approved', pg_temp.approve_plain(pg_temp.v('RV2'), 'gw2'),
                               'rv2', pg_temp.suivi(pg_temp.v('RV2')));
  perform pg_temp.stmt2('6b2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 5000, 'iban', pg_temp.iban('a8'))));
  w := w || jsonb_build_object('back', pg_temp.bkx(pg_temp.l2('6b2', 1), pg_temp.prop(pg_temp.l2('6b2', 1))),
                               'rv2_later', pg_temp.suivi(pg_temp.v('RV2')) = w -> 'rv2');
  perform pg_temp.cancel_run(pg_temp.v('RV2'), 'gw2');
  perform pg_temp.reconfirm('a8');
  insert into t values ('RV3', pg_temp.request('a8', 'gw3'));
  perform pg_temp.prepare_plain(pg_temp.v('RV3'));
  w := w || jsonb_build_object('rv3_approved', pg_temp.approve_plain(pg_temp.v('RV3'), 'gw3'),
                               'rv3', pg_temp.suivi(pg_temp.v('RV3')));
  perform pg_temp.cancel_run(pg_temp.v('RV3'), 'gw3');
  insert into t values ('RV4', pg_temp.request('a8', 'gw4'));
  perform pg_temp.prepare_plain(pg_temp.v('RV4'));
  return w || jsonb_build_object('rv4_approved', pg_temp.approve_plain(pg_temp.v('RV4'), 'gw4'),
                                 'rv4', pg_temp.suivi(pg_temp.v('RV4')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('g_window'),
  '{"rv1_approved": "approved:approved", "s13": "ok", "rv1": {"since": null, "events": []},
    "rv2_approved": "approved:approved",
    "rv2": {"since": ["RV1", true], "events": [
      {"kind": "cancelled", "run_number": "RV1", "on": "d0"},
      {"kind": "executed_outside", "run_number": null, "amount_minor": "5000", "advance_minor": "5000",
       "iban_last4": "4350", "on": "d0", "here": true}]},
    "back": "ok", "rv2_later": true, "rv3_approved": "approved:approved",
    "rv3": {"since": ["RV2", true], "events": [
      {"kind": "cancelled", "run_number": "RV2", "on": "d0"},
      {"kind": "unplanned_returned", "run_number": null, "unplanned_minor": "5000", "advance_minor": "5000",
       "owed_minor": "0", "executed_on": "d0", "on": "d0", "here": true}]},
    "rv4_approved": "approved:approved",
    "rv4": {"since": ["RV3", true], "events": [{"kind": "cancelled", "run_number": "RV3", "on": "d0"}]}}'::jsonb,
  'G-window (review round 1 tests-2): an S13 posted after K₁ is in RV2 only, its return after K₂ in RV3 only (RV2 drawn '
  'again unchanged; RV4 lists neither); each run lists only the cancellation of the run before it');

-- I-currency (tests-2): Cyprès' RV0 approved and cancelled; a USD run cancelled after RV0's K; an S13 to Cyprès' USD
-- payout IBAN on the USD dedicated account, and its return; RV1 (EUR)
create or replace function pg_temp.usd_copy(p_run uuid, p_number text) returns uuid language plpgsql as $$
-- (test only) a copy of run p_run in USD, approved and cancelled now, with its own transfer on the USD dedicated
-- account: the filters of the window's bound and of the runs listed, not a USD run this fixture could prepare
declare v_t uuid := gen_random_uuid(); v_r uuid := gen_random_uuid();
begin
  alter table public.remittance_run disable trigger user;
  insert into public.remittance_run (id, organization_id, client_organization_id, currency, number, status, trigger,
                                     known_at, approved_at, cancelled_at, cancel_reason, inputs_hash)
  select v_r, r.organization_id, r.client_organization_id, 'USD', p_number, 'cancelled', 'manual', clock_timestamp(),
         clock_timestamp(), clock_timestamp(), 'annulé (test)', r.inputs_hash
  from public.remittance_run r where r.id = p_run;
  alter table public.bank_transfer disable trigger user;
  insert into public.bank_transfer (id, organization_id, kind, debtor_bank_account_id, currency, amount_minor,
                                    payee_name, payee_iban, end_to_end_id, requested_execution_date, status,
                                    client_organization_id, run_id, cancelled_at, cancel_reason)
  select v_t, y.organization_id, y.kind, '80000000-0000-0000-0000-0000000000cd', 'USD', y.amount_minor, y.payee_name,
         y.payee_iban, 'RMT0000000005D1', y.requested_execution_date, 'cancelled', y.client_organization_id, v_r,
         clock_timestamp(), 'annulé (test)'
  from public.bank_transfer y where y.id = (select transfer_id from public.remittance_run where id = p_run);
  alter table public.bank_transfer enable trigger user;
  update public.remittance_run set transfer_id = v_t where id = v_r;
  alter table public.remittance_run enable trigger user;
  return v_r;
end $$;
-- an imported camt.053 of the USD dedicated account (as stmt2, in USD, opened at 0)
create or replace function pg_temp.stmt_usd(p_n text, p_day date, p_lines jsonb) returns uuid
language plpgsql as $$
declare
  s uuid := ('e4' || lpad(p_n, 6, '0') || '-0000-0000-0000-000000000000')::uuid;
  v_close bigint;
begin
  select coalesce(sum(case coalesce(l.v ->> 'dir', 'debit') when 'credit' then 1 else -1 end
                      * (l.v ->> 'amount')::bigint), 0)
  into v_close from jsonb_array_elements(p_lines) l (v);
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cd', 'USD', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, counterparty_iban)
  select pg_temp.l2(p_n, l.ord::integer), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cd',
         s, l.ord, 't:' || s || l.ord, coalesce(l.v ->> 'dir', 'debit'), (l.v ->> 'amount')::bigint, 'USD', p_day,
         coalesce(l.v ->> 'kind', 'transfer_out'), l.v ->> 'e2e', l.v ->> 'iban'
  from jsonb_array_elements(p_lines) with ordinality l (v, ord);
  update public.bank_statement set status = 'imported', from_date = p_day, to_date = p_day,
    opening_booked_minor = 0, closing_booked_minor = v_close, counts = '{}', finished_at = clock_timestamp(),
    sections = jsonb_build_array(jsonb_build_object('from_date', p_day, 'to_date', p_day, 'covers_from', p_day,
                                                    'covers_to', p_day, 'opening_minor', '0',
                                                    'closing_minor', v_close::text, 'created_at', now()))
  where id = s;
  return s;
end $$;
create or replace function pg_temp.i_currency() returns jsonb language plpgsql as $$
declare w jsonb;
begin
  insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on)
  values ('80000000-0000-0000-0000-0000000000cd', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
          'FR7030001007940000000002002', 'TESTFRPPXXX', 'USD', 'Fonds de tiers USD', 'camt053', '2026-01-01');
  perform pg_temp.file('31', '20000000-0000-0000-0000-0000000000a3', 30000);
  perform pg_temp.collect('31', 30000, private.paris_today() - 3);
  insert into t values ('RV0', pg_temp.request('a3', 'ic0'));
  perform pg_temp.prepare_plain(pg_temp.v('RV0'));
  w := jsonb_build_object('rv0', pg_temp.approve_plain(pg_temp.v('RV0'), 'ic0'));
  perform pg_temp.cancel_run(pg_temp.v('RV0'), 'ic0');
  perform pg_temp.usd_copy(pg_temp.v('RV0'), 'RV-2026-900001');
  -- Cyprès' USD payout account (its S13's return marks it returned: RV1's prepare reads the EUR one alone)
  insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                            evidence_document_id, proposed_by)
  values ('90000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a3'), 'USD',
          pg_temp.iban('a3'), 'CYPRES SA', 'd0000000-0000-0000-0000-0000000002a3', '10000000-0000-0000-0000-000000000004');
  update public.client_payout_account set status = 'active', confirmed_at = now(), confirmed_via = 'second_admin',
    confirmed_by = '10000000-0000-0000-0000-000000000001'
  where id = '90000000-0000-0000-0000-0000000000d3';
  perform pg_temp.stmt_usd('3c1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 7000, 'kind', 'other_debit', 'iban', pg_temp.iban('a3'))));
  w := w || jsonb_build_object('s13', pg_temp.bkx(pg_temp.l2('3c1', 1), jsonb_build_array(
                                        pg_temp.pt('unplanned_payout', null, 7000, pg_temp.c('a3')))));
  perform pg_temp.stmt_usd('3c2', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 7000, 'iban', pg_temp.iban('a3'))));
  w := w || jsonb_build_object('back', pg_temp.bkx(pg_temp.l2('3c2', 1), pg_temp.prop(pg_temp.l2('3c2', 1))));
  insert into t values ('RV1', pg_temp.request('a3', 'ic1'));
  perform pg_temp.prepare_plain(pg_temp.v('RV1'));
  return w || jsonb_build_object('rv1', pg_temp.approve_plain(pg_temp.v('RV1'), 'ic1'),
                                 'rv1_suivi', pg_temp.suivi(pg_temp.v('RV1')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('i_currency'),
  '{"rv0": "approved:approved", "s13": "ok", "back": "ok", "rv1": "approved:approved",
    "rv1_suivi": {"since": ["RV0", true], "events": [{"kind": "cancelled", "run_number": "RV0", "on": "d0"}]}}'::jsonb,
  'I-currency (review round 1 tests-2): a run of another currency neither bounds the window nor is listed, nor are an '
  'S13 of another currency and its return');

-- F-partial (tests-3): Lambert's RV1 (two collections, 98 400) debited and returned; one of its collections taken back
-- (−20 000 waits); the returned payout executed again (P = 78 400 by the queue, the advance 20 000), then returned
create or replace function pg_temp.f_partial() returns jsonb language plpgsql as $$
declare v_x uuid; w jsonb;
begin
  perform pg_temp.file('41', '20000000-0000-0000-0000-0000000000a4', 100000);
  perform pg_temp.collect('41', 100000, private.paris_today() - 3);
  perform pg_temp.file('45', '20000000-0000-0000-0000-0000000000a4', 20000);
  perform pg_temp.collect('45', 20000, private.paris_today() - 3);
  insert into t values ('RV1', pg_temp.runk('a4', '{"41": "100000", "45": "20000"}', 21600, 3600, 'fp1'));
  v_x := (select transfer_id from public.remittance_run where id = pg_temp.v('RV1'));
  perform pg_temp.handed_out('ffp1', 'gen-x038-fp1');
  perform pg_temp.stmt2('fa1', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', 98400, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('fa1', 1), 'payout', v_x)));
  perform pg_temp.stmt2('fa2', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 98400, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('fa2', 1), 'payout_returned', v_x)));
  perform pg_temp.raw_bounce(pg_temp.alloc('45'), 'rev-x038-f45', private.paris_today() - 1);
  w := jsonb_build_object('queue', pg_temp.queued_minor('a4'));
  perform pg_temp.stmt2('fa3', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 98400, 'e2e', pg_temp.e2e(v_x))));
  w := w || jsonb_build_object('again', pg_temp.bkx(pg_temp.l2('fa3', 1), pg_temp.prop(pg_temp.l2('fa3', 1))));
  perform pg_temp.stmt2('fa4', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 98400, 'orig', pg_temp.e2e(v_x))));
  w := w || jsonb_build_object('back', pg_temp.bkx(pg_temp.l2('fa4', 1), pg_temp.prop(pg_temp.l2('fa4', 1))));
  perform pg_temp.reconfirm('a4');
  perform pg_temp.file('46', '20000000-0000-0000-0000-0000000000a4', 30000);
  perform pg_temp.collect('46', 30000, private.paris_today());
  insert into t values ('RV2', pg_temp.request('a4', 'fp2'));
  perform pg_temp.prepare_plain(pg_temp.v('RV2'));
  return w || jsonb_build_object('rv2_approved', pg_temp.approve_plain(pg_temp.v('RV2'), 'fp2'),
                                 'rv2', pg_temp.suivi(pg_temp.v('RV2')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select pg_temp.cover_check(false);
select is(pg_temp.iso('f_partial'),
  '{"queue": 78400, "again": "ok", "back": "ok", "rv2_approved": "approved:approved",
    "rv2": {"since": ["RV1", true], "events": [
      {"kind": "debited", "run_number": "RV1", "amount_minor": "98400", "end_to_end_id": "chain:0", "on": "d-2"},
      {"kind": "returned", "run_number": "RV1", "amount_minor": "98400", "end_to_end_id": "chain:0",
       "debited_on": "d-2", "on": "d-1", "repaid": "here", "repaid_by": null},
      {"kind": "debited_again", "run_number": "RV1", "unplanned_minor": "98400", "advance_minor": "20000",
       "p_bound": "queue", "execution_no": 2, "debited_on": "d-2", "before_debit": false, "on": "d-1", "here": true},
      {"kind": "unplanned_returned", "run_number": "RV1", "unplanned_minor": "98400", "advance_minor": "20000",
       "owed_minor": "78400", "executed_on": "d-1", "on": "d0", "here": true}]}}'::jsonb,
  'F-partial (S03r; review round 1 tests-3): a returned payout executed again with 0 < P < A, then returned: the '
  'advance A − P and P owed again, the execution''s date apart from the return''s');
select pg_temp.cover_check(true);

-- D-twice (tests-3, legal-texts-1, legal-texts-3): D's cancelled run executed on d-1 (P = 44 000 by the queue), a new
-- collection, executed again on d0 (P = 100 000): one late item paid by both, in part
create or replace function pg_temp.d_twice() returns jsonb language plpgsql as $$
declare v_t0 uuid; v_x uuid; v_d uuid; w jsonb;
begin
  v_t0 := pg_temp.queued('a7', '70', 156000, 'dt0');
  insert into t values ('RV0', pg_temp.v('run-dt0'));
  perform pg_temp.handed_out('fdt0', 'gen-x038-dt0');
  perform pg_temp.stmt2('da1', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', 127920, 'e2e', pg_temp.e2e(v_t0))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('da1', 1), 'payout', v_t0)));
  v_x := pg_temp.queued('a7', '71', 200000, 'dt1');
  insert into t values ('RV1', pg_temp.v('run-dt1'));
  perform pg_temp.handed_out('fdt1', 'gen-x038-dt1');
  perform pg_temp.raw_bounce(pg_temp.alloc('70'), 'rev-x038-dt70', private.paris_today() - 1);
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_x;
  perform pg_temp.cancel_run(pg_temp.v('RV1'), 'dt1');
  v_d := pg_temp.request('a7', 'dt-r2');
  insert into t values ('RV2', v_d);
  perform pg_temp.stmt2('da2', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(v_x))));
  w := jsonb_build_object('first', pg_temp.bkx(pg_temp.l2('da2', 1), pg_temp.prop(pg_temp.l2('da2', 1))));
  perform pg_temp.file('72', '20000000-0000-0000-0000-0000000000a7', 100000);
  perform pg_temp.collect('72', 100000, private.paris_today() - 1);
  perform pg_temp.stmt2('da3', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(v_x))));
  w := w || jsonb_build_object('second', pg_temp.bkx(pg_temp.l2('da3', 1), pg_temp.prop(pg_temp.l2('da3', 1))));
  perform pg_temp.prepare_late(v_d, private.paris_today() - 5);
  return w || jsonb_build_object(
    'approved', pg_temp.approve_late(v_d, 'dt-r2'), 'suivi', pg_temp.suivi(v_d),
    'd71', pg_temp.lf(v_d, pg_temp.alloc('71')), 'd72', pg_temp.lf(v_d, pg_temp.alloc('72')),
    'attributed', (select jsonb_agg(jsonb_build_array(q.amount_minor, pg_temp.dd(e.effective_date::text))
                                    order by e.effective_date)
                   from private.unplanned_paid_item q join public.ledger_entry e on e.id = q.booking_entry_id
                   where q.ledger_entry_id = pg_temp.alloc('71')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select pg_temp.cover_check(false);
select is(pg_temp.iso('d_twice'),
  '{"first": "ok", "second": "ok", "approved": ":booked",
    "suivi": {"since": ["RV1", true], "events": [
      {"kind": "executed_after_cancellation", "run_number": "RV1", "cancelled_on": "d0", "unplanned_minor": "164000",
       "advance_minor": "120000", "p_bound": "queue", "execution_no": 1, "on": "d-1", "here": true},
      {"kind": "executed_after_cancellation", "run_number": "RV1", "cancelled_on": "d0", "unplanned_minor": "164000",
       "advance_minor": "64000", "p_bound": "queue", "execution_no": 2, "on": "d0", "here": true}]},
    "d71": {"nature": "allocation", "reason": null, "late": true, "cause": "identified_late", "paid": "144000",
            "paid_on": "d0"},
    "d72": {"nature": "allocation", "reason": null, "late": true, "cause": "identified_late", "paid": null,
            "paid_on": null},
    "attributed": [[44000, "d-1"], [100000, "d0"]]}'::jsonb,
  'D-twice (review round 1 tests-3, legal-texts-1, legal-texts-3): a cancelled run''s payout executed twice, each '
  'with its rank; the late item both paid in part keeps its own cause, the amounts added and the latest booking''s '
  'date');
select pg_temp.cover_check(true);

-- R-reads (SR-1): Lilas, Cyprès, Lambert, Dupont and Martin each with two booked runs, Martin's S13, Roux's run approved
-- and not paid (another client's live lines); the « Suivi » of Martin's third run between two counts of the tuples read
create or replace function pg_temp.tuples(p_table regclass) returns bigint language sql as $$
  select coalesce(sum(coalesce(x.idx_tup_fetch, 0) + x.seq_tup_read), 0)::bigint from pg_stat_xact_user_tables x
  where x.relid = p_table $$;
create or replace function pg_temp.r_reads() returns jsonb language plpgsql as $$
declare v_c text; v_n integer := 0; v_x uuid; v_k integer; v_run uuid; v_t0 bigint; w jsonb;
begin
  foreach v_c in array array['a2', 'a3', 'a4', 'a6', 'a1'] loop
    for v_k in 1 .. 2 loop
      v_n := v_n + 1;
      v_x := pg_temp.queued(v_c, lpad(to_hex(100 + v_n), 2, '0'), 10000 * v_k, 'rr' || v_n);
      perform pg_temp.handed_out('frr' || v_n, 'gen-x038-rr' || v_n);
      perform pg_temp.stmt2(lpad(to_hex(3000 + v_n), 4, '0'), private.paris_today(), jsonb_build_array(
        jsonb_build_object('amount', 8200 * v_k, 'e2e', pg_temp.e2e(v_x))));
      perform pg_temp.book(jsonb_build_array(
        pg_temp.row(pg_temp.l2(lpad(to_hex(3000 + v_n), 4, '0'), 1), 'payout', v_x)));
    end loop;
  end loop;
  perform pg_temp.stmt2('4ff1', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 3000, 'kind', 'other_debit', 'iban', pg_temp.iban('a1'))));
  perform pg_temp.bk(pg_temp.l2('4ff1', 1), jsonb_build_array(pg_temp.pt('unplanned_payout', null, 3000, pg_temp.c('a1'))));
  perform pg_temp.queued('a5', 'f5', 20000, 'rr-a5');
  perform pg_temp.file('f1', '20000000-0000-0000-0000-0000000000a1', 20000);
  perform pg_temp.collect('f1', 20000, private.paris_today() - 1);
  v_run := pg_temp.request('a1', 'rr-a1');
  perform pg_temp.prepare_plain(v_run);
  perform pg_temp.approve_plain(v_run, 'rr-a1');
  w := jsonb_build_object('transfers', (select count(*) from public.bank_transfer),
                          'live_lines', (select count(*) from public.remittance_line where not released));
  v_t0 := pg_temp.tuples('public.bank_transfer');
  w := w || jsonb_build_object('events', (select jsonb_agg(e ->> 'kind') from jsonb_array_elements(
                                            private.remittance_statement_previous_payouts(v_run) -> 'events') e));
  -- (the live-line probe's tuples are not asserted: with empty statistics the planner may read
  -- remittance_line_account_idx whole whatever the probe's form — ADR-0014 « M2c-6b-2d review fixes », left open;
  -- bitmap scans are off in the helper, its settings below)
  return w || jsonb_build_object(
    'bank_transfer', pg_temp.tuples('public.bank_transfer') - v_t0,
    'settings', (select p.proconfig @> array['enable_bitmapscan=off', 'enable_seqscan=off'] from pg_proc p
                 where p.oid = 'private.remittance_statement_previous_payouts(uuid)'::regprocedure));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('r_reads'),
  '{"transfers": 21, "live_lines": 14, "events": ["debited", "executed_outside"], "bank_transfer": 4,
    "settings": true}'::jsonb,
  'R-reads (review round 1 SR-1): with 21 transfers and 14 live lines of five clients, Martin''s « Suivi » reads each '
  'transfer of its two earlier runs'' chains twice (the chain, then by key: 4 tuples), never every transfer of the '
  'servicer; the helper runs with sequential and bitmap scans off');

-- R-record (SR-2): the record step refuses a statement drawn by another template; fr-3's is recorded
create or replace function pg_temp.r_record() returns jsonb language plpgsql as $$
declare w jsonb;
begin
  perform pg_temp.queued('a1', '11', 200000, 'rec1');
  perform private.remittance_documents_begin('00000000-0000-0000-0000-0000000000aa', 10, 10);
  perform private.remittance_statement_prepare(pg_temp.v('run-rec1'));
  insert into pg_temp._rd_statement_files values (pg_temp.v('run-rec1'), repeat('b', 64), repeat('c', 64));
  w := jsonb_build_object('fr2', pg_temp.attempt($q$ select private.remittance_documents_record(
         '00000000-0000-0000-0000-0000000000aa', 'releve-reversement-fr-2', 'facture-commission-fr-2', 'test') $q$));
  w := w || jsonb_build_object('fr3', private.remittance_documents_record(
         '00000000-0000-0000-0000-0000000000aa', 'releve-reversement-fr-3', 'facture-commission-fr-2', 'test')
         -> 'statements');
  return w || jsonb_build_object('stored', (select jsonb_agg(s.template_version) from public.remittance_statement s
                                            where s.run_id = pg_temp.v('run-rec1')));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.iso('r_record'),
  '{"fr2": "statements drawn by template releve-reversement-fr-2: this payload is drawn by releve-reversement-fr-3 only",
    "fr3": 1, "stored": ["releve-reversement-fr-3"]}'::jsonb,
  'R-record (review round 1 SR-2): a statement drawn by an older template is refused at the record step (its attempt '
  'fails and is retried); one drawn by releve-reversement-fr-3 is recorded');

-- R. The helpers are internal (critic2 CSO2-11): no role but their owner may call them; the build stays the worker's --
select is((select jsonb_agg(jsonb_build_array(r, f, case when to_regprocedure(f) is null then null
                                                        else has_function_privilege(r, f, 'execute') end)
                            order by f, r)
           from unnest(array['anon', 'authenticated', 'service_role']) r,
                unnest(array['private.remittance_statement_previous_payouts(uuid)',
                             'private.remittance_statement_paid_by_unplanned(uuid,timestamp with time zone)',
                             'private.remittance_statement_build(uuid)']) f),
  '[["anon", "private.remittance_statement_build(uuid)", false],
    ["authenticated", "private.remittance_statement_build(uuid)", false],
    ["service_role", "private.remittance_statement_build(uuid)", true],
    ["anon", "private.remittance_statement_paid_by_unplanned(uuid,timestamp with time zone)", false],
    ["authenticated", "private.remittance_statement_paid_by_unplanned(uuid,timestamp with time zone)", false],
    ["service_role", "private.remittance_statement_paid_by_unplanned(uuid,timestamp with time zone)", false],
    ["anon", "private.remittance_statement_previous_payouts(uuid)", false],
    ["authenticated", "private.remittance_statement_previous_payouts(uuid)", false],
    ["service_role", "private.remittance_statement_previous_payouts(uuid)", false]]'::jsonb,
  'R: « Suivi » and the late cause are read inside the statement build only (no grant to any API role); the build is '
  'the documents job''s (service role)');
select is(private.switch_on('downloaded_file_cancellation'), false, 'and the switch is off (033 and 034 unchanged)');

select * from finish();
rollback;
