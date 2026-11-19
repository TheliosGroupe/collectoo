-- M2c-6b-2b « the ops command », the tests 6b-2b deferred (plan docs/design/m2c-6b-2-plan.md §8.1 037; ADR-0014
-- « M2c-6b-2b » not-done list and « M2c-6b-2b deferred tests »; 037's header). 037 holds groups A–L (and 6b-2c's P);
-- this file adds, on 037's fixtures (copied: the servicer aa, its accounts cf/c0, clients a1–a9, the other servicer bb,
-- and 037's base — x1 booked by the job and debited a second time today, x2 in flight):
--   J. every read's tenant isolation: book_transfer_line, transfer_line_preview and transfer_line_options on the
--      servicer's lines of each class (E, N, B, U, an E credit) for another servicer's ops manager, a client admin, a
--      client's restricted viewer, the line's own client's admin, a collector, a user of no organization, and the
--      servicer's admin and ops manager at aal1 — null, or « not allowed », nothing booked nor recorded; the servicer's
--      staff on the other servicer's line; the other servicer's staff on its own lines naming our ids, our lot, our
--      return and our detail: nothing of ours in its answers, our ids refused as absent ones;
--   M. the funds pass after an ops booking (critic CSO-11, critic2 CSO2-7): a planned payout, a payout with its fee, an
--      unplanned payout, an unplanned return queue one process_debits message with funds_after null; a planned return
--      alone queues none; two flagged returns of x reviewed unplanned_payout_return in one pass — ops book the first as
--      the unplanned booking's return, and the queued pass (the job's SQL re-check) books the second as
--      payout_returned(x), the line among the pass's candidates again;
--   S. S04 (every member of a lot booked, the lot debited again: an unplanned payout per member, each its advance) and
--      S02 (switch on: a lot of a live member and a member cancelled after download — payout + unplanned payout, P from
--      the cancelled member's run; with that run still sent, run_still_live);
--   F. F1's lot variant (critic F1): a and b of one lot both booked and both executed again (booked unplanned); a credit
--      naming the lot at b's amount is b's unplanned return — b's client owed nothing again, a's advance still open;
--      and with b cancelled after download (switch on), then debited with the lot as its unplanned payout, b is in the
--      lot's returnable universe by its open unplanned booking alone — the credit is that booking's return;
--   D. ML-1's signed pool with a payout_overrun cover (critic2 ML-1, the plan's example): the pool of a late payout
--      holds a collection, a bounced collection's −X and the cover's +X advance — the advance counted (P = A while the
--      collection is owed), and once the collection bounces too the signed net is 0 (P = 0, never X);
--   C. ML-8's CSV form and its second line (critic2 ML-8): without an IBAN, a reference-less debit of a returned payout's
--      amount while the run re-paying it is in flight is that run's payout; a later second line of that amount is the
--      returned payout's execution again (rule 3b's (iii)), P from its return item as it stands (0: frozen in the
--      booked re-payment), the advance all of it.
-- run_payment_checks is asserted free of violations in each scenario and after the groups. Cancellation after download
-- stays off (033 and 034 unchanged): the scenarios that need it switch it on inside their own rolled-back
-- subtransaction.
begin;
select plan(27);


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

-- Collections (three days ago) and the first runs: Martin 200 000 → net 164 000; Lilas 512 000 → net 419 840;

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

-- The base: Martin's and Lilas' collections and runs; FA handed out (x1 Martin 164 000, x2 Lilas 419 840: no sweep, the
-- servicer's share nil before their debits); x1's debit booked by the job yesterday, x2 still in flight
select pg_temp.file(x.n, ('20000000-0000-0000-0000-0000000000' || x.c)::uuid, x.amount)
from (values ('01', 'a1', 200000), ('02', 'a2', 512000)) x (n, c, amount);
select pg_temp.collect(x.n, x.amount, private.paris_today() - 3)
from (values ('01', 200000), ('02', 512000)) x (n, amount);
select pg_temp.collect('13', 1000000, private.paris_today() - 3, false);
insert into t select 'r1', pg_temp.run('a1', '{"01": "200000"}', 36000, 6000);
insert into t select 'r2', pg_temp.run('a2', '{"02": "512000"}', 92160, 15360);
select pg_temp.stmt('00', private.paris_today() - 1);
select pg_temp.handed_out('fa', 'gen-file-a');
insert into t values ('x1', pg_temp.trid('r1')), ('x2', pg_temp.trid('r2'));
select pg_temp.stmt2('b1', private.paris_today() - 1, jsonb_build_array(
  jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1')))));
select pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('b1', 1), 'payout', pg_temp.v('x1'))));
-- S03: x1 debited a second time today (E: its RMT id), reviewed transfer_debited_twice by the job
select pg_temp.stmt2('b2', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 164000, 'e2e', pg_temp.e2e(pg_temp.v('x1')))));
select pg_temp.book('[]', jsonb_build_array(jsonb_build_object('line', pg_temp.l2('b2', 1),
                                                               'reason', 'transfer_debited_twice')));
-- another servicer, bb: its client, its accounts, a payout of its own and a line (the tenant filter's foreign ids)
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Client de BB',
   '552100554');
insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000bf', '00000000-0000-0000-0000-0000000000bb', 'client_funds',
   'FR8130004000039876543210134', 'TESTFRPPXXX', 'EUR', 'Fonds BB', 'camt053', '2026-01-01');
insert into public.bank_transfer (id, organization_id, kind, debtor_bank_account_id, currency, amount_minor, payee_name,
                                  payee_iban, end_to_end_id, requested_execution_date, client_organization_id)
values ('b0000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000bb', 'payout',
        '80000000-0000-0000-0000-0000000000bf', 'EUR', 164000, 'CLIENT DE BB', 'FR7630004000031234567890143',
        'RMT00000000BB01', private.paris_today(), '00000000-0000-0000-0000-0000000000b1');
insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                   size_bytes, storage_path)
values ('e6000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000bb',
        '80000000-0000-0000-0000-0000000000bf', 'EUR', 'camt053', 'b.xml', repeat('b', 64), 1, 'test/bb');
update public.bank_statement set status = 'uploaded', uploaded_at = now()
where id = 'e6000000-0000-0000-0000-0000000000b1';
insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind, end_to_end_id)
values ('e6000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000bb',
        '80000000-0000-0000-0000-0000000000bf', 'e6000000-0000-0000-0000-0000000000b1', 1, 't:bb1', 'debit', 164000,
        'EUR', private.paris_today(), 'transfer_out', 'RMT00000000BB01');



-- J. Every read's tenant isolation (plan §3.2 step 1, §3.11; §8.1 037 J; critic CSO-5) ---------------------------------
-- a user of no organization
insert into auth.users (id, email, aud, role)
values ('10000000-0000-0000-0000-000000000099', 'u99@book.test', 'authenticated', 'authenticated');
-- the servicer's lines of each class, today: N (a debit to Cyprès' payout IBAN naming nothing), B (FA's PmtInf debited
-- as one line: x2, x1 left), U (an entry kept unsplit holding x2's detail), an E credit (x1 back, flagged), and the base's
-- E debit (x1's second debit, l2('b2', 1))
select pg_temp.stmt2('a011', private.paris_today(), jsonb_build_array(
  jsonb_build_object('amount', 1234, 'kind', 'other_debit', 'iban', pg_temp.iban('a3')),
  jsonb_build_object('amount', 419840, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(pg_temp.v('x2'))),
  jsonb_build_object('amount', 419840, 'kind', 'batch_unsplit', 'unsplit', 1, 'count', 1,
                     'details', jsonb_build_array(jsonb_build_object('id', pg_temp.e2e(pg_temp.v('x2')),
                                                                     'direction', 'debit', 'amount_minor', '419840'))),
  jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1')),
                     'iban', pg_temp.iban('a1'))));
create temporary table j_line (n integer primary key, line uuid not null, parts jsonb, expected text) on commit drop;
insert into j_line (n, line) values (1, pg_temp.l2('b2', 1)), (2, pg_temp.l2('a011', 1)), (3, pg_temp.l2('a011', 2)),
                                    (4, pg_temp.l2('a011', 3)), (5, pg_temp.l2('a011', 4));
-- what the servicer's ops manager is offered (the parts the outsiders then send, with its expected text)
update j_line set parts = coalesce(pg_temp.prop(line),
                                   jsonb_build_array(pg_temp.pt('payout_returned', pg_temp.v('x1'), 164000)))
where true;
update j_line set expected = pg_temp.pv(line, parts) ->> 'expected_text' where true;
-- the outsiders: another servicer's ops manager, Petit's client admin and its restricted viewer, Lilas' client admin
-- (x2's client), the servicer's collector, a user of no organization; the servicer's admins and ops manager at aal1
create temporary table j_who (u text, aal text, primary key (u, aal)) on commit drop;
insert into j_who values ('05', 'aal2'), ('03', 'aal2'), ('07', 'aal2'), ('08', 'aal2'), ('02', 'aal2'), ('99', 'aal2'),
                         ('04', 'aal1'), ('10', 'aal1'), ('01', 'aal1'), ('13', 'aal1');
grant all on j_line, j_who to authenticated;

select is((select array_agg(x.v order by x.n)
           from (select l.n, jsonb_build_array(o -> 'class', jsonb_array_length(o -> 'proposals'), o -> 'refusal') as v
                 from j_line l cross join lateral (select pg_temp.op(l.line) as o) z) x),
          array['["E", 1, null]', '["N", 1, null]', '["B", 1, null]', '["U", 1, null]',
                '["E", 0, "debit_pending"]']::jsonb[],
  'J: the servicer''s ops manager at aal2 reads each line''s options (E, N, B, U, an E credit waiting on x1''s second '
  'debit)');
select is((select array_agg(distinct (pg_temp.op(l.line, w.u, w.aal) is null)) from j_line l cross join j_who w),
          array[true],
  'J: transfer_line_options is null for another servicer''s ops manager, a client admin, a client''s restricted viewer, '
  'the line''s own client''s admin, a collector, a user of no organization, and the servicer''s admins and ops '
  'manager at aal1 — on lines of every class');
select is((select array_agg(distinct (pg_temp.pv(l.line, l.parts, w.u, w.aal) is null)) from j_line l cross join j_who w),
          array[true],
  'J: transfer_line_preview is null for each of them, with the parts the servicer''s staff are offered');
select is((select array_agg(distinct pg_temp.bkx(l.line, l.parts, 'j-' || l.n || '-' || w.u || '-' || w.aal, w.u,
                                                 coalesce(l.expected, 'none'), 'motif', w.aal))
           from j_line l cross join j_who w),
          array['not allowed'],
  'J: book_transfer_line refuses each of them « not allowed » (42501), with the staff''s parts and expected text');
select is(array[(select count(*) from public.bank_line_booking k join j_line l on l.line = k.bank_transaction_id),
                (select count(*) from private.command_log c
                 where c.command = 'book_transfer_line' and c.idempotency_key like 'j-%')],
          array[0::bigint, 0::bigint],
  'J: and nothing is booked nor recorded for them');
select is(array[pg_temp.op(l.line, '10')::text = pg_temp.op(l.line)::text,
                pg_temp.pv(l.line, l.parts, '10')::text = pg_temp.pv(l.line, l.parts)::text]
                || array[pg_temp.op(l.line, '13') is not null],
          array[true, true, true],
  'J: the servicer''s admin at aal2 reads what its ops manager reads (and another ops manager too)')
from j_line l where l.n = 3;
select is(array[pg_temp.op('e6000000-0000-0000-0000-0000000000b2')::text,
                pg_temp.op('e6000000-0000-0000-0000-0000000000b2', '10')::text,
                pg_temp.pv('e6000000-0000-0000-0000-0000000000b2',
                           jsonb_build_array(pg_temp.pt('payout', 'b0000000-0000-0000-0000-0000000000b1', 164000)))::text,
                pg_temp.bkx('e6000000-0000-0000-0000-0000000000b2',
                            jsonb_build_array(pg_temp.pt('payout', 'b0000000-0000-0000-0000-0000000000b1', 164000)),
                            'j-bb-line-key', '01', 'x')],
          array[null, null, null, 'not allowed'],
  'J: the servicer''s staff read nothing of the other servicer''s line and cannot book it');
-- the other servicer's lines naming what is ours: x2's RMT id to Lilas' IBAN, FA's PmtInf, x1's return from Martin's
-- IBAN, an entry kept unsplit holding x2's detail
insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id,
                                     original_end_to_end_id, counterparty_iban, batch_entry_ref, unsplit_ours,
                                     unsplit_details, unsplit_detail_count)
values
  ('e6000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000bb', '80000000-0000-0000-0000-0000000000bf',
   'e6000000-0000-0000-0000-0000000000b1', 2, 't:bb2', 'debit', 419840, 'EUR', private.paris_today(), 'transfer_out',
   pg_temp.e2e(pg_temp.v('x2')), null, null, pg_temp.iban('a2'), null, null, null, null),
  ('e6000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000bb', '80000000-0000-0000-0000-0000000000bf',
   'e6000000-0000-0000-0000-0000000000b1', 3, 't:bb3', 'debit', 419840, 'EUR', private.paris_today(), 'batch_unsplit',
   null, pg_temp.pmt(pg_temp.v('x2')), null, null, null, null, null, null),
  ('e6000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-0000000000bb', '80000000-0000-0000-0000-0000000000bf',
   'e6000000-0000-0000-0000-0000000000b1', 4, 't:bb4', 'credit', 164000, 'EUR', private.paris_today(), 'return',
   null, null, pg_temp.e2e(pg_temp.v('x1')), pg_temp.iban('a1'), null, null, null, null),
  ('e6000000-0000-0000-0000-0000000000b6', '00000000-0000-0000-0000-0000000000bb', '80000000-0000-0000-0000-0000000000bf',
   'e6000000-0000-0000-0000-0000000000b1', 5, 't:bb5', 'debit', 419840, 'EUR', private.paris_today(), 'batch_unsplit',
   null, null, null, null, 'E-bb-5', 1,
   jsonb_build_array(jsonb_build_object('id', pg_temp.e2e(pg_temp.v('x2')), 'direction', 'debit',
                                        'amount_minor', '419840')), 1);
-- every id, name and number of ours its answers could show
create or replace function pg_temp.ours() returns text language sql as $$
  select '(' || array_to_string(array[pg_temp.v('x1')::text, pg_temp.v('x2')::text, pg_temp.v('r1')::text,
                                      pg_temp.v('r2')::text, pg_temp.v('fa')::text, pg_temp.e2e(pg_temp.v('x1')),
                                      pg_temp.e2e(pg_temp.v('x2')),
                                      (select number from public.remittance_run where id = pg_temp.v('r1')),
                                      (select number from public.remittance_run where id = pg_temp.v('r2')),
                                      (select number from public.transfer_file where id = pg_temp.v('fa')),
                                      'Martin', 'Lilas', '00000000-0000-0000-0000-0000000000a'], '|') || ')' $$;
grant execute on all functions in schema pg_temp to authenticated;
select is((select array_agg(jsonb_build_array(o -> 'class', jsonb_array_length(o -> 'proposals'), o -> 'refusal',
                                              o -> 'members', o::text ~ pg_temp.ours())
                            order by l.id)
           from public.bank_transaction l cross join lateral (select pg_temp.op(l.id, '05') as o) z
           where l.id in ('e6000000-0000-0000-0000-0000000000b3', 'e6000000-0000-0000-0000-0000000000b4',
                          'e6000000-0000-0000-0000-0000000000b5', 'e6000000-0000-0000-0000-0000000000b6')),
          array['["E0", 0, null, null, false]', '["E0", 0, null, null, false]', '["E0", 0, null, null, false]',
                '["U", 0, "unsplit_not_bookable", null, false]']::jsonb[],
  'J: the other servicer''s lines naming our RMT id, our PmtInf, our return and our detail: no proposal, no member, '
  'nothing of ours in its answers (none of our ids, end-to-end ids, run or file numbers, client names)');
select is(array[pg_temp.pv('e6000000-0000-0000-0000-0000000000b3',
                           jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'), 419840)))::text,
                pg_temp.pv('e6000000-0000-0000-0000-0000000000b3',
                           jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'), 419840)), '05') ->> 'why',
                pg_temp.pv('e6000000-0000-0000-0000-0000000000b3',
                           jsonb_build_array(pg_temp.pt('unplanned_payout', null, 419840, pg_temp.c('a2'))), '05')
                  ->> 'why',
                pg_temp.pv('e6000000-0000-0000-0000-0000000000b5',
                           jsonb_build_array(pg_temp.pt('unplanned_payout_returned', null, 164000, pg_temp.c('a1'),
                                                        pg_temp.l2('b2', 1))), '05') ->> 'why',
                (pg_temp.pv('e6000000-0000-0000-0000-0000000000b4',
                           jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'), 419840)), '05')::text
                  ~ pg_temp.ours())::text,
                pg_temp.bkx('e6000000-0000-0000-0000-0000000000b3',
                            jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'), 419840)), 'j-bb-x2-key', '05', 'x'),
                pg_temp.bkx('e6000000-0000-0000-0000-0000000000b6',
                            jsonb_build_array(pg_temp.pt('payout', pg_temp.v('x2'), 419840)), 'j-bb-u-key1', '05', 'x'),
                pg_temp.bkx('e6000000-0000-0000-0000-0000000000b5',
                            jsonb_build_array(pg_temp.pt('unplanned_payout_returned', null, 164000, pg_temp.c('a1'),
                                                         pg_temp.l2('b2', 1))), 'j-bb-ret-key', '05', 'x')],
          array[null, 'transfer_unknown', 'client_unknown', 'transfer_unknown', 'false', 'transfer_unknown',
                'transfer_unknown', 'transfer_unknown'],
  'J: on its own lines, the other servicer''s ops manager naming our transfer, our client or our line is refused as '
  'for an absent id (transfer_unknown, client_unknown; a part naming our line and our client: the line first) by the '
  'preview and the command; our staff read none of it');
select is(array[has_function_privilege('anon', 'public.transfer_line_options(uuid)', 'execute'),
                has_function_privilege('anon', 'public.transfer_line_preview(uuid, jsonb)', 'execute'),
                has_function_privilege('anon', 'public.book_transfer_line(text, uuid, jsonb, text, text)', 'execute'),
                has_function_privilege('authenticated', 'public.transfer_line_preview(uuid, jsonb)', 'execute')],
          array[false, false, false, true],
  'J: the three are not executable by anon; the preview by authenticated (checked inside)');
select is((select array_agg(distinct coalesce(pg_temp.pv(l.line, p.v) ->> 'why', 'raised'))
           from j_line l
           cross join (values ('null'::jsonb), ('3'), ('[{"kind": "payout", "transfer_id": "not-a-uuid", "amount": "1"}]'),
                              ('[{"kind": "payout", "transfer_id": null, "amount": "1"}]'), ('[]')) p (v)),
          array['bad_request'],
  'J: the preview never raises: a null, a number, a malformed id, a missing transfer, no part → bad_request, on every '
  'class');
select is(pg_temp.dirty(), '{}'::text[], 'J: clean');


-- M. The funds pass after an ops booking (plan §3.2 step 11; critic CSO-11, critic2 CSO2-7, ML-3) ------------------------
-- each kind of call: a planned payout (x2 on its RMT id), its flagged return alone, a payout with the bank's recorded
-- charge on its own line (S08), an unplanned payout (S03: x1's second debit, the base); the message each queues
create or replace function pg_temp.m_kinds() returns jsonb language plpgsql as $$
declare n0 bigint; w jsonb := '{}'; v_t4 uuid;
begin
  perform pg_temp.stmt2('bb01', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 419840, 'e2e', pg_temp.e2e(pg_temp.v('x2')))));
  n0 := pg_temp.funds_msgs();
  w := w || jsonb_build_object('payout_parts', (select jsonb_agg(p ->> 'kind')
                                                from jsonb_array_elements(pg_temp.prop(pg_temp.l2('bb01', 1))) p));
  perform pg_temp.bk(pg_temp.l2('bb01', 1), pg_temp.prop(pg_temp.l2('bb01', 1)));
  w := w || jsonb_build_object('payout', pg_temp.funds_msgs() - n0,
                               'message', (select m.message - 'organization_id' || jsonb_build_object(
                                                    'ours', m.message ->> 'organization_id'
                                                            = '00000000-0000-0000-0000-0000000000aa')
                                           from pgmq.q_payments m where m.message ->> 'type' = 'process_debits'
                                           order by m.msg_id desc limit 1));
  perform pg_temp.stmt2('bb02', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 419840, 'orig', pg_temp.e2e(pg_temp.v('x2')))));
  n0 := pg_temp.funds_msgs();
  w := w || jsonb_build_object('return_parts', (select jsonb_agg(p ->> 'kind')
                                                from jsonb_array_elements(pg_temp.prop(pg_temp.l2('bb02', 1))) p));
  perform pg_temp.bk(pg_temp.l2('bb02', 1), pg_temp.prop(pg_temp.l2('bb02', 1)));
  w := w || jsonb_build_object('planned_return', pg_temp.funds_msgs() - n0);
  v_t4 := pg_temp.inflight('a4', '04', 40000, 'm-s08');   -- 32 800 to Lambert
  perform pg_temp.stmt2('bb03', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 32920, 'e2e', pg_temp.e2e(v_t4), 'charges', 120, 'read', true)));
  n0 := pg_temp.funds_msgs();
  w := w || jsonb_build_object('s08_parts', (select jsonb_agg(p ->> 'kind')
                                             from jsonb_array_elements(pg_temp.prop(pg_temp.l2('bb03', 1))) p));
  perform pg_temp.bk(pg_temp.l2('bb03', 1), pg_temp.prop(pg_temp.l2('bb03', 1)));
  w := w || jsonb_build_object('payout_fee', pg_temp.funds_msgs() - n0);
  n0 := pg_temp.funds_msgs();
  perform pg_temp.bk(pg_temp.l2('b2', 1), pg_temp.prop(pg_temp.l2('b2', 1)));
  w := w || jsonb_build_object('unplanned', pg_temp.funds_msgs() - n0);
  return w || jsonb_build_object('dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('m_kinds'),
  '{"payout_parts": ["payout"], "payout": 1,
    "message": {"type": "process_debits", "funds_after": null, "ours": true},
    "return_parts": ["payout_returned"], "planned_return": 0, "s08_parts": ["payout", "fee"], "payout_fee": 1,
    "unplanned": 1, "dirty": []}'::jsonb,
  'M (CSO-11): a call booking a planned payout, a payout with its fee, or an unplanned payout queues one funds pass '
  '(process_debits of the servicer, funds_after null); a call booking only a planned return queues none');
-- CSO2-7: both copies of x1 back on one statement (S03 booked by ops: x1's open unplanned booking), the job's pass
-- reviews both unplanned_payout_return; ops book the first as the unplanned booking's return; the pass it queues
-- reads the second again (a reviewed line stays a candidate) and the job's SQL re-check books it as x1's planned return
create or replace function pg_temp.m_two_returns() returns jsonb language plpgsql as $$
declare n0 bigint; w jsonb; l1 uuid := pg_temp.l2('bb11', 1); l2 uuid := pg_temp.l2('bb11', 2);
begin
  perform pg_temp.bk(pg_temp.l2('b2', 1), pg_temp.prop(pg_temp.l2('b2', 1)));
  perform pg_temp.stmt2('bb11', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1')),
                       'iban', pg_temp.iban('a1')),
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 164000, 'orig', pg_temp.e2e(pg_temp.v('x1')),
                       'iban', pg_temp.iban('a1'))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(l1, 'payout_returned', pg_temp.v('x1')),
                                         pg_temp.row(l2, 'payout_returned', pg_temp.v('x1'))));
  w := jsonb_build_object('reviewed', jsonb_build_array(pg_temp.review(l1), pg_temp.review(l2)),
                          'queue_before', pg_temp.queued_minor('a1'));
  n0 := pg_temp.funds_msgs();
  w := w || jsonb_build_object('proposed', (select jsonb_agg(p ->> 'kind')
                                            from jsonb_array_elements(pg_temp.prop(l1)) p));
  perform pg_temp.bk(l1, pg_temp.prop(l1));
  w := w || jsonb_build_object(
    'queued', pg_temp.funds_msgs() - n0,
    'candidates', (select jsonb_agg(c.line_id = l2) from private.bank_booking_candidates(
                     '00000000-0000-0000-0000-0000000000aa', null, null, 10000) c where c.line_id in (l1, l2)),
    'after_first', jsonb_build_array(pg_temp.queued_minor('a1'), pg_temp.status(pg_temp.v('x1')),
                                     pg_temp.payout_account('a1')));
  -- the queued pass: the job's row for the second line, re-checked under its locks
  perform pg_temp.book(jsonb_build_array(pg_temp.row(l2, 'payout_returned', pg_temp.v('x1'))));
  return w || jsonb_build_object(
    'second', pg_temp.bookings(l2), 'review', pg_temp.review(l2),
    'after', jsonb_build_array(pg_temp.queued_minor('a1'), pg_temp.status(pg_temp.v('x1')), pg_temp.returned_items('a1'),
                               pg_temp.payout_account('a1')),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('m_two_returns'),
  '{"reviewed": ["unplanned_payout_return", "unplanned_payout_return"], "queue_before": 0,
    "proposed": ["unplanned_payout_returned"], "queued": 1, "candidates": [true],
    "after_first": [0, "booked", "returned"], "second": ["1 payout_returned 164000"], "review": null,
    "after": [164000, "returned", 2, "returned"], "dirty": []}'::jsonb,
  'M (CSO2-7): two flagged returns of x1 reviewed unplanned_payout_return in one pass — ops book the first as the '
  'unplanned booking''s return (nothing re-owed, the funds pass queued); the second, still a candidate of the pass, is '
  'then x1''s planned return: booked payout_returned, x1 returned, its collection owed once again');
select is(pg_temp.dirty(), '{}'::text[], 'M: clean');


-- S. Lots of unplanned members: S04 and S02 (plan §3.5, §3.6.1; §8.1 037 D « S04 … S02 ») ------------------------------
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

-- S04: Roux's v5 (24 600) and Dupont's v6 (82 000), one PmtInf, its batch line booked (both members booked); the bank
-- debits the lot a second time — each member's unplanned payout (no items: P = 0), each its double_payout advance
create or replace function pg_temp.s_s04() returns jsonb language plpgsql as $$
declare v_5 uuid; v_6 uuid; v_p jsonb; w jsonb;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 's04-5');
  v_6 := pg_temp.queued('a6', '06', 100000, 's04-6');
  perform pg_temp.handed_out('fs4', 'gen-s04-file');
  perform pg_temp.stmt2('c041', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  perform pg_temp.bk(pg_temp.l2('c041', 1), pg_temp.prop(pg_temp.l2('c041', 1)));
  perform pg_temp.stmt2('c042', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  v_p := pg_temp.op(pg_temp.l2('c042', 1));
  w := jsonb_build_object(
    'first', jsonb_build_array(pg_temp.status(v_5), pg_temp.status(v_6)),
    'class', v_p ->> 'class', 'action', v_p -> 'proposals' -> 0 ->> 'action',
    'parts', pg_temp.parts_of(v_p -> 'proposals' -> 0 -> 'preview'),
    'members', (select jsonb_agg(m ->> 'in_proposal') from jsonb_array_elements(v_p -> 'members') m),
    'booked', pg_temp.bkx(pg_temp.l2('c042', 1), pg_temp.prop(pg_temp.l2('c042', 1))));
  return w || jsonb_build_object(
    'bookings', pg_temp.booked_set(pg_temp.l2('c042', 1)), 'keys', pg_temp.keys(pg_temp.l2('c042', 1)),
    'advances', (select jsonb_agg(a.cause || ':' || a.amount_minor || ':' || a.p_bound order by a.amount_minor)
                 from public.client_advance a where a.bank_transaction_id = pg_temp.l2('c042', 1)),
    'queues', jsonb_build_array(pg_temp.queued_minor('a5'), pg_temp.queued_minor('a6')),
    'transfers', jsonb_build_array(pg_temp.status(v_5), pg_temp.status(v_6)),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('s_s04'),
  '{"first": ["booked", "booked"], "class": "B", "action": "lot",
    "parts": [["unplanned_payout", "24600", "0", "24600", "none"], ["unplanned_payout", "82000", "0", "82000", "none"]],
    "members": ["true", "true"], "booked": "ok",
    "bookings": {"kinds": ["unplanned_payout 24600", "unplanned_payout 82000"], "seqs": [1, 2]},
    "keys": ["remit:line:·:1", "remit:line:·:2"],
    "advances": ["double_payout:24600:none", "double_payout:82000:none"], "queues": [0, 0],
    "transfers": ["booked", "booked"], "dirty": []}'::jsonb,
  'S (S04): a lot whose members are all booked, debited a second time, is the only subset of its members: each one''s '
  'unplanned payout (its items: none, P = 0), each its double_payout advance of A, the queues unchanged (net 0), the '
  'transfers still booked');
-- S02 (switch on): v5 (24 600) live and v6 (82 000) cancelled after download with its run (its 100 000 item back, then
-- reserved by Dupont's draft); the bank debits the whole PmtInf as one line — v5's payout and v6's unplanned payout,
-- P from v6's cancelled run (its released item, net 100 000; P = A), no advance, Dupont's draft re-prepared
create or replace function pg_temp.s_s02() returns jsonb language plpgsql as $$
declare v_5 uuid; v_6 uuid; v_d uuid; v_p jsonb; w jsonb;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 's02-5');
  v_6 := pg_temp.queued('a6', '06', 100000, 's02-6');
  perform pg_temp.handed_out('fs2', 'gen-s02-file');
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_6;
  perform pg_temp.cancel_run(pg_temp.v('run-s02-6'), 's02-6');
  v_d := pg_temp.request('a6', 's02-draft');
  perform pg_temp.prepare_plain(v_d);
  perform pg_temp.stmt2('c021', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  v_p := pg_temp.op(pg_temp.l2('c021', 1));
  w := jsonb_build_object(
    'class', v_p ->> 'class', 'action', v_p -> 'proposals' -> 0 ->> 'action',
    'parts', pg_temp.parts_of(v_p -> 'proposals' -> 0 -> 'preview'),
    'drafts', (v_p -> 'proposals' -> 0 -> 'preview' -> 'drafts' -> 0 ->> 'run_id')::uuid = v_d,
    'queue_before', pg_temp.queued_minor('a6'),
    'booked', pg_temp.bkx(pg_temp.l2('c021', 1), pg_temp.prop(pg_temp.l2('c021', 1))));
  return w || jsonb_build_object(
    'bookings', pg_temp.bookings(pg_temp.l2('c021', 1)),
    'transfers', jsonb_build_array(pg_temp.status(v_5), pg_temp.status(v_6)),
    'runs', jsonb_build_array((select status from public.remittance_run where id = pg_temp.v('run-s02-5')),
                              (select status from public.remittance_run where id = pg_temp.v('run-s02-6'))),
    'attributed', (select jsonb_agg(u.amount_minor) from private.unplanned_paid_item u
                   join public.bank_line_booking k on k.entry_id = u.booking_entry_id
                   where k.bank_transaction_id = pg_temp.l2('c021', 1)),
    'advances', (select count(*) from public.client_advance a where a.bank_transaction_id = pg_temp.l2('c021', 1)),
    'draft', (select jsonb_build_array(r.job, r.last_failure is null) from public.remittance_run r where r.id = v_d),
    'queue_after', pg_temp.queued_minor('a6'), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('s_s02'),
  '{"class": "B", "action": "lot",
    "parts": [["payout", "24600", "0", "0", null], ["unplanned_payout", "82000", "82000", "0", "amount"]],
    "drafts": true, "queue_before": 100000, "booked": "ok",
    "bookings": ["1 unplanned_payout 82000", "2 payout 24600"], "transfers": ["booked", "cancelled"],
    "runs": ["booked", "cancelled"], "attributed": [82000], "advances": 0, "draft": ["prepare", true],
    "queue_after": 18000, "dirty": []}'::jsonb,
  'S (S02, switch on): a lot of a live member and a member cancelled after download with its run, debited whole — the '
  'live member''s payout (its run booked) and the cancelled one''s unplanned payout, P = A from its run''s released '
  'item still waiting (reserved by the client''s draft, which is re-prepared), no advance, the queue net of it');
-- ML-4 in a lot (switch on): v6 cancelled alone, its run still sent — the lot's line is that run's payout: no proposal,
-- run_still_live with the run's number; the command refuses it
create or replace function pg_temp.s_s02_live() returns jsonb language plpgsql as $$
declare v_5 uuid; v_6 uuid; v_p jsonb;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 's2l-5');
  v_6 := pg_temp.queued('a6', '06', 100000, 's2l-6');
  perform pg_temp.handed_out('fs3', 'gen-s2l-file');
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_6;
  perform pg_temp.stmt2('c022', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  v_p := pg_temp.op(pg_temp.l2('c022', 1));
  return jsonb_build_object(
    'proposals', jsonb_array_length(v_p -> 'proposals'), 'refusal', v_p ->> 'refusal',
    'detail', v_p ->> 'refusal_detail' = (select number from public.remittance_run where id = pg_temp.v('run-s2l-6')),
    'command', pg_temp.bkx(pg_temp.l2('c022', 1), jsonb_build_array(pg_temp.pt('payout', v_5, 24600),
                                                                     pg_temp.pt('unplanned_payout', v_6, 82000)),
                           null, '01', 'x'),
    'run', (select status from public.remittance_run where id = pg_temp.v('run-s2l-6')),
    'bookings', pg_temp.bookings(pg_temp.l2('c022', 1)));
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('s_s02_live'),
  '{"proposals": 1, "refusal": null, "detail": null, "command": "run_still_live", "run": "sent",
    "bookings": []}'::jsonb,
  'S (S02, ML-4): the lot''s cancelled member whose run is still sent is that run''s payout — M2c-6b-3a-2 (E): '
  'proposed as payout + payout (late predecessor), nothing refused; the command asking an unplanned payout of it is '
  'refused run_still_live');
select is(pg_temp.dirty(), '{}'::text[], 'S: clean');


-- F. F1's lot variant (plan §3.5 lot credit, §3.4.13; §8.1 037 F « the lot variant »; critic F1) -------------------------
-- Roux's a (v5, 24 600) and Dupont's b (v6, 82 000), one PmtInf, its batch line booked; each executed a second time on
-- its RMT id and booked by ops as its unplanned payout (P = 0, the advance A); then a credit naming the lot at b's amount
-- comes back: its only returnable subset is b, which takes its open unplanned booking's return — Dupont is owed nothing
-- again (+82 000 and −82 000: net 0), b's advance closed, a's still open, b still booked
create or replace function pg_temp.f_lot_f1() returns jsonb language plpgsql as $$
declare v_5 uuid; v_6 uuid; v_p jsonb; w jsonb;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 'f1l-5');
  v_6 := pg_temp.queued('a6', '06', 100000, 'f1l-6');
  perform pg_temp.handed_out('ff1', 'gen-f1l-file');
  perform pg_temp.stmt2('f101', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  perform pg_temp.bk(pg_temp.l2('f101', 1), pg_temp.prop(pg_temp.l2('f101', 1)));
  perform pg_temp.stmt2('f102', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 24600, 'e2e', pg_temp.e2e(v_5)),
    jsonb_build_object('amount', 82000, 'e2e', pg_temp.e2e(v_6))));
  perform pg_temp.bk(pg_temp.l2('f102', 1), pg_temp.prop(pg_temp.l2('f102', 1)));
  perform pg_temp.bk(pg_temp.l2('f102', 2), pg_temp.prop(pg_temp.l2('f102', 2)));
  perform pg_temp.stmt2('f103', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 82000, 'pmt', pg_temp.pmt(v_5))));
  v_p := pg_temp.op(pg_temp.l2('f103', 1));
  w := jsonb_build_object(
    'class', v_p ->> 'class', 'action', v_p -> 'proposals' -> 0 ->> 'action',
    'proposed', pg_temp.prop(pg_temp.l2('f103', 1))
                = jsonb_build_array(pg_temp.pt('unplanned_payout_returned', v_6, 82000, null, pg_temp.l2('f102', 2))),
    'members', (select jsonb_agg(jsonb_build_array(m ->> 'amount_minor', m ->> 'in_proposal')
                                 order by (m ->> 'amount_minor')::bigint)
                from jsonb_array_elements(v_p -> 'members') m),
    'queue_before', jsonb_build_array(pg_temp.queued_minor('a5'), pg_temp.queued_minor('a6')),
    'planned_refused', pg_temp.why(pg_temp.l2('f103', 1), jsonb_build_array(pg_temp.pt('payout_returned', v_6, 82000))),
    'booked', pg_temp.bkx(pg_temp.l2('f103', 1), pg_temp.prop(pg_temp.l2('f103', 1))));
  return w || jsonb_build_object(
    'bookings', pg_temp.bookings(pg_temp.l2('f103', 1)), 'keys', pg_temp.keys(pg_temp.l2('f103', 1)),
    'queue_after', jsonb_build_array(pg_temp.queued_minor('a5'), pg_temp.queued_minor('a6')),
    'open', jsonb_build_array(private.transfer_unplanned_open(v_5), private.transfer_unplanned_open(v_6)),
    'transfers', jsonb_build_array(pg_temp.status(v_5), pg_temp.status(v_6)),
    'alerts', (select jsonb_agg(x -> 1 order by (x ->> 1)::bigint) from jsonb_array_elements(pg_temp.alerts('double_payout_open')) x),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('f_lot_f1'),
  '{"class": "B", "action": "returned", "proposed": true, "members": [["24600", "false"], ["82000", "true"]],
    "queue_before": [0, 0], "planned_refused": "unplanned_open", "booked": "ok",
    "bookings": ["1 unplanned_payout_returned 82000"], "keys": ["return:·:1"], "queue_after": [0, 0],
    "open": [true, false], "transfers": ["booked", "booked"], "alerts": [24600], "dirty": []}'::jsonb,
  'F (F1, the lot variant): a credit naming our lot at one member''s amount, both members booked and both executed '
  'again (booked unplanned), is that member''s unplanned booking''s return — never its planned return (unplanned_open) '
  '— its client owed nothing again, its advance closed, the other member''s advance still open');
-- F1's lot variant with a member that only its open unplanned booking makes returnable (switch on): Roux's a (v5,
-- 24 600) live and Dupont's b (v6, 82 000) cancelled after download with its run; the bank debits the whole PmtInf —
-- a's payout and b's unplanned payout (P = A, from its run's released item); then a credit naming the lot at b's
-- amount comes back: b is cancelled, so its open unplanned booking alone puts it in the lot's returnable universe —
-- the credit is that booking's return, Dupont's item waiting again (the queue back to 100 000), a still paid
create or replace function pg_temp.f_lot_f1_cancelled() returns jsonb language plpgsql as $$
declare v_5 uuid; v_6 uuid; v_p jsonb; w jsonb;
begin
  v_5 := pg_temp.queued('a5', '05', 30000, 'f1c-5');
  v_6 := pg_temp.queued('a6', '06', 100000, 'f1c-6');
  perform pg_temp.handed_out('ff2', 'gen-f1c-file');
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_6;
  perform pg_temp.cancel_run(pg_temp.v('run-f1c-6'), 'f1c-6');
  perform pg_temp.stmt2('f111', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 106600, 'kind', 'batch_unsplit', 'pmt', pg_temp.pmt(v_5))));
  perform pg_temp.bk(pg_temp.l2('f111', 1), pg_temp.prop(pg_temp.l2('f111', 1)));
  perform pg_temp.stmt2('f112', private.paris_today(), jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 82000, 'pmt', pg_temp.pmt(v_5))));
  v_p := pg_temp.op(pg_temp.l2('f112', 1));
  w := jsonb_build_object(
    'first', pg_temp.bookings(pg_temp.l2('f111', 1)),
    'class', v_p ->> 'class', 'action', v_p -> 'proposals' -> 0 ->> 'action',
    'proposed', pg_temp.prop(pg_temp.l2('f112', 1))
                = jsonb_build_array(pg_temp.pt('unplanned_payout_returned', v_6, 82000, null, pg_temp.l2('f111', 1))),
    'members', (select jsonb_agg(jsonb_build_array(m ->> 'amount_minor', m ->> 'in_proposal')
                                 order by (m ->> 'amount_minor')::bigint)
                from jsonb_array_elements(v_p -> 'members') m),
    'queue_before', jsonb_build_array(pg_temp.queued_minor('a5'), pg_temp.queued_minor('a6')),
    'booked', pg_temp.bkx(pg_temp.l2('f112', 1), pg_temp.prop(pg_temp.l2('f112', 1))));
  return w || jsonb_build_object(
    'bookings', pg_temp.bookings(pg_temp.l2('f112', 1)),
    'queue_after', jsonb_build_array(pg_temp.queued_minor('a5'), pg_temp.queued_minor('a6')),
    'open', jsonb_build_array(private.transfer_unplanned_open(v_5), private.transfer_unplanned_open(v_6)),
    'transfers', jsonb_build_array(pg_temp.status(v_5), pg_temp.status(v_6)),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('f_lot_f1_cancelled'),
  '{"first": ["1 unplanned_payout 82000", "2 payout 24600"], "class": "B", "action": "returned", "proposed": true,
    "members": [["24600", "false"], ["82000", "true"]], "queue_before": [0, 18000], "booked": "ok",
    "bookings": ["1 unplanned_payout_returned 82000"], "queue_after": [0, 100000], "open": [false, false],
    "transfers": ["booked", "cancelled"], "dirty": []}'::jsonb,
  'F (F1, the lot variant, a cancelled member): a credit naming our lot at the amount of a member cancelled after '
  'download, then debited with the lot (its unplanned payout), finds that member by its open unplanned booking alone '
  '— the booking''s return, its client''s item waiting again, the live member still paid');
select is(pg_temp.dirty(), '{}'::text[], 'F: clean');

-- D. ML-1's signed pool with a payout_overrun cover (plan §3.6.1's example; critic2 ML-1) ------------------------------
-- Moreau's R0 holds p (20 000) and b (3 000), no commission, approved and handed out; b bounces (r −3 000 waits); R0's
-- debit is booked by the job: 4670 would go into debit by 3 000, so the cover (a payout_overrun advance, v +3 000 waits);
-- Moreau's R1 holds a (10 000), r and v (y = 10 000), handed out, then cancelled after download with y (switch on).
-- n (20 000) arrives; y executed late: its items' signed net is 10 000 − 3 000 + 3 000 (the cover is an item, not an
-- unplanned booking's own row) → P = A; once a bounces too (its chain nets 0): 0 − 3 000 + 3 000 = 0 → P = 0, the
-- advance all of it, n still owed (never the 3 000 a per-item floor would net)
create or replace function pg_temp.d_ml1_cover() returns jsonb language plpgsql as $$
declare v_r0 uuid; v_t0 uuid; v_r1 uuid; v_y uuid; v_f uuid; w jsonb;
begin
  perform pg_temp.file('d0', '20000000-0000-0000-0000-0000000000a9', 20000);
  perform pg_temp.collect('d0', 20000, private.paris_today() - 3);
  perform pg_temp.file('d1', '20000000-0000-0000-0000-0000000000a9', 3000);
  perform pg_temp.collect('d1', 3000, private.paris_today() - 3);
  v_r0 := pg_temp.request('a9', 'ml1c-r0');
  perform pg_temp.prepare_plain(v_r0);
  perform pg_temp.approve_plain(v_r0, 'ml1c-r0');
  v_t0 := (select transfer_id from public.remittance_run where id = v_r0);
  v_f := (pg_temp.gen('01', 'gen-ml1c-r0') ->> 'file_id')::uuid;
  perform pg_temp.write(v_f);
  perform pg_temp.download('01', v_f);
  perform private.ledger_reverse((select id from public.ledger_entry where payment_id = pg_temp.pay('d1')
                                    and entry_type = 'allocation'), 'rev-ml1c-d1', 'Retour du paiement (test)',
                                 private.paris_today() - 2);
  perform pg_temp.stmt2('d101', private.paris_today() - 2, jsonb_build_array(
    jsonb_build_object('amount', pg_temp.amt(v_t0), 'e2e', pg_temp.e2e(v_t0))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('d101', 1), 'payout', v_t0)));
  w := jsonb_build_object(
    't0', jsonb_build_array(pg_temp.amt(v_t0), pg_temp.status(v_t0)),
    'cover', (select jsonb_agg(a.cause || ':' || a.amount_minor) from public.client_advance a
              where a.client_organization_id = pg_temp.c('a9')));
  -- (review 6b-2c T3) the run page's advance of the servicer at R0's debit: its cause, amount and what is still open
  perform pg_temp.as_user('01');
  set local role authenticated;
  w := w || jsonb_build_object('r0_page', (
    select jsonb_agg(jsonb_build_array(a ->> 'cause', a ->> 'amount_minor', a ->> 'open_minor',
                                       (a ->> 'created_on')::date = private.paris_today()))
    from jsonb_array_elements(public.remittance_run_payout(v_r0) -> 'advances') a));
  reset role;
  perform pg_temp.file('d2', '20000000-0000-0000-0000-0000000000a9', 10000);
  perform pg_temp.collect('d2', 10000, private.paris_today() - 1);
  v_r1 := pg_temp.request('a9', 'ml1c-r1');
  perform pg_temp.prepare_plain(v_r1);
  perform pg_temp.approve_plain(v_r1, 'ml1c-r1');
  v_y := (select transfer_id from public.remittance_run where id = v_r1);
  w := w || jsonb_build_object('r1_items', (select jsonb_agg(l.kind || ':' || l.amount_minor order by l.amount_minor)
                                            from public.remittance_line l where l.run_id = v_r1));
  v_f := (pg_temp.gen('01', 'gen-ml1c-r1') ->> 'file_id')::uuid;
  perform pg_temp.write(v_f);
  perform pg_temp.download('01', v_f);
  update private.feature_switch set enabled = true where key = 'downloaded_file_cancellation';
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = v_y;
  perform pg_temp.cancel_run(v_r1, 'ml1c-r1');
  -- n (20 000) arrives
  perform pg_temp.file('d3', '20000000-0000-0000-0000-0000000000a9', 20000);
  perform pg_temp.collect('d3', 20000, private.paris_today());
  perform pg_temp.stmt2('d102', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', pg_temp.amt(v_y), 'e2e', pg_temp.e2e(v_y))));
  w := w || jsonb_build_object('y', pg_temp.amt(v_y),
    'owed', pg_temp.pp(pg_temp.pv(pg_temp.l2('d102', 1), pg_temp.prop(pg_temp.l2('d102', 1)))));
  -- a bounces
  perform private.ledger_reverse((select id from public.ledger_entry where payment_id = pg_temp.pay('d2')
                                    and entry_type = 'allocation'), 'rev-ml1c-d2', 'Retour du paiement (test)',
                                 private.paris_today());
  w := w || jsonb_build_object(
    'queue', pg_temp.queued_minor('a9'),
    'bounced', pg_temp.pp(pg_temp.pv(pg_temp.l2('d102', 1), pg_temp.prop(pg_temp.l2('d102', 1)))),
    'booked', pg_temp.bkx(pg_temp.l2('d102', 1), pg_temp.prop(pg_temp.l2('d102', 1))));
  return w || jsonb_build_object('queue_after', pg_temp.queued_minor('a9'),
    'advances', (select jsonb_agg(a.cause || ':' || a.amount_minor order by a.cause) from public.client_advance a
                 where a.client_organization_id = pg_temp.c('a9')),
    'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('d_ml1_cover'),
  '{"t0": [23000, "booked"], "cover": ["payout_overrun:3000"], "r0_page": [["payout_overrun", "3000", "3000", true]],
    "r1_items": ["allocation_reversal:-3000", "client_advance:3000", "allocation:10000"], "y": 10000,
    "owed": ["unplanned_payout", "10000", "0", "amount"], "queue": 20000,
    "bounced": ["unplanned_payout", "0", "10000", "items"], "booked": "ok", "queue_after": 20000,
    "advances": ["double_payout:10000", "payout_overrun:3000"], "dirty": []}'::jsonb,
  'D (ML-1, the plan''s example): a cancelled run''s released lines holding a bounced collection''s −X and its '
  'payout_overrun cover''s +X count signed, the cover as an item — P = A while the collection is owed; once it bounces '
  'too the net is 0: P = 0, the advance all of it, the new collection still owed (never the cover''s X)');
select is(pg_temp.dirty(), '{}'::text[], 'D: clean');

-- C. ML-8's CSV form and its second line (plan §3.4.4 (iii); critic2 ML-8) ---------------------------------------------
-- Durand's x (41 000) booked and returned (ρ owed), Durand's IBAN reconfirmed, R2 holds ρ alone (t2 41 000 to the same
-- IBAN, handed out); a CSV line without the IBAN column (class N): t2's payout, not line_ambiguous; a later second line
-- of 41 000 (t2 booked, no longer in flight): x's execution again (iii), P from ρ as it stands — 0, frozen in R2 — the
-- advance all of it
create or replace function pg_temp.c_ml8_csv() returns jsonb language plpgsql as $$
declare v_x uuid; v_d uuid; v_t2 uuid; v_f uuid; w jsonb;
begin
  v_x := pg_temp.inflight('a7', '07', 50000, 'c8csv');
  perform pg_temp.stmt2('d801', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('amount', 41000, 'e2e', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('d801', 1), 'payout', v_x)));
  perform pg_temp.stmt2('d802', private.paris_today() - 1, jsonb_build_array(
    jsonb_build_object('dir', 'credit', 'kind', 'return', 'amount', 41000, 'orig', pg_temp.e2e(v_x))));
  perform pg_temp.book(jsonb_build_array(pg_temp.row(pg_temp.l2('d802', 1), 'payout_returned', v_x)));
  perform pg_temp.reconfirm('a7');
  v_d := pg_temp.request('a7', 'c8c-r2');
  perform pg_temp.prepare_plain(v_d);
  perform pg_temp.approve_plain(v_d, 'c8c-r2');
  v_t2 := (select transfer_id from public.remittance_run where id = v_d);
  v_f := pg_temp.handed_out('fc8', 'gen-c8c-r2');
  perform pg_temp.exec_on(v_f, private.paris_today() - 1);
  perform pg_temp.exec_on(pg_temp.v('file-c8csv'), private.paris_today() - 1);
  perform pg_temp.stmt2('d803', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 41000, 'kind', 'other_debit')));
  w := jsonb_build_object(
    'class', pg_temp.op(pg_temp.l2('d803', 1)) ->> 'class',
    'first', pg_temp.prop(pg_temp.l2('d803', 1)) = jsonb_build_array(pg_temp.pt('payout', v_t2, 41000)),
    'first_booked', pg_temp.bkx(pg_temp.l2('d803', 1), pg_temp.prop(pg_temp.l2('d803', 1))));
  -- (read in a statement of its own: a subquery beside the booking's call would be read before it)
  w := w || jsonb_build_object('r2', (select status from public.remittance_run where id = v_d));
  perform pg_temp.stmt2('d804', private.paris_today(), jsonb_build_array(
    jsonb_build_object('amount', 41000, 'kind', 'other_debit')));
  w := w || jsonb_build_object(
    'second', pg_temp.prop(pg_temp.l2('d804', 1)) = jsonb_build_array(pg_temp.pt('unplanned_payout', v_x, 41000)),
    'second_part', pg_temp.pp(pg_temp.pv(pg_temp.l2('d804', 1), pg_temp.prop(pg_temp.l2('d804', 1)))),
    'second_booked', pg_temp.bkx(pg_temp.l2('d804', 1), pg_temp.prop(pg_temp.l2('d804', 1))));
  return w || jsonb_build_object(
    'advances', (select jsonb_agg(a.cause || ':' || a.amount_minor || ':' || a.p_bound) from public.client_advance a
                 where a.bank_transaction_id = pg_temp.l2('d804', 1)),
    'x', pg_temp.status(v_x), 't2', pg_temp.status(v_t2), 'dirty', pg_temp.dirty());
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select is(pg_temp.isolated('c_ml8_csv'),
  '{"class": "N", "first": true, "first_booked": "ok", "r2": "booked", "second": true,
    "second_part": ["unplanned_payout", "0", "41000", "none"], "second_booked": "ok",
    "advances": ["double_payout:41000:none"], "x": "returned", "t2": "booked", "dirty": []}'::jsonb,
  'C (ML-8, CSV): without an IBAN, a reference-less debit of a returned payout''s amount while the run re-paying its '
  'return item is in flight is that run''s payout; a later second line of that amount is the returned payout executed '
  'again (rule 3b''s (iii)), P from its return item as it stands — 0, frozen in the booked re-payment — the advance all '
  'of it');
select is(pg_temp.dirty(), '{}'::text[], 'J, M, S, F, D, C: clean');
select is(private.switch_on('downloaded_file_cancellation'), false, 'and the switch is off (033 and 034 unchanged)');

select * from finish();
rollback;
