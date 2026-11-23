-- M2c-7a « remitted reversals covered everywhere, and the backstop » (plan docs/design/m2c-7-plan.md §2.1, §3; design
-- §7.2, §13; ADR-0014 « M2c-7a »). A reversal R of an allocation or a forward E is covered by an advance of the servicer
-- (client_advance, cause remitted_reversal) for T(R): E's line when E is remitted (a live line of a booked run that
-- does not also hold R: a same-run pair is never remitted), else what live unplanned payouts paid of E (switch on).
-- I23 — C(R) = T(R) — holds at every commit (LG009) and every night (remitted_reversal_uncovered):
--   1–3   « Désimputer » of a remitted, of a remitted alone, of a pending allocation; the cover dated no earlier than
--         the payout it covers (a back-dated reversal), balances at the day before the payout show no advance;
--   4, 5d a reversal of a line in flight (draft, approved, sent) covered when its run is booked (adv:<R>:<run>, the
--         payout's transfer and debit line), before any overrun cover; the run page lists it;
--   5a–5c a same-run pair never covered (N = 0 at approval, a run debited, a pair after a cancellation);
--   5e, 5f switch on: an attribution covered and released when its unplanned payout comes back; a pair booked after
--         an unplanned payout paid E (Q17's default: the cover stays when that payout comes back);
--   6–8   M2b returns (ops' strict link, a forward too, a partial return; the job's chunk with a forgotten cover planted:
--         posting_failed LG009, the others posted, the working table begun again and again; « Retour au-delà »);
--   9, 10, 18 LG009: a raw reversal, a run set booked uncovered (and a pair that is not), a cover reversed raw;
--   11, 12 switch on: the release (a re-post of the remainder; refused while settled or taken by a run in flight), a
--         late predecessor booked as its run's payout;
--   13    idempotency and roles of « Désimputer » and « Couvrir »;
--   14, 19 the nightly checks: the delta window and its overlap, the monthly and requested full pass, its request table,
--         advance_ledger, advance_open at 30 days, the full list of codes; (review round 1) the runs whose booking was
--         recorded since the last run, whatever their booked_on (CC-1), the window a key range under a generic plan
--         (CC-2); and every scenario that posts, releases or re-posts a cover ends with no remitted_reversal_uncovered
--         nor advance_ledger row (tests-ui-5);
--   15    RLS and grants;
--   16    the overrun backstop (a forged 4670 debit) with its mandate and its payout_overrun alert;
--   17    paid_on (a payout come back then paid again, twice; set-off; still in flight; a late predecessor's return;
--         (review round 1) an N = 0 run netting its own unplanned payout's return, switch off and on; a run without a
--         transfer paid through a later run, run_transfer);
--   §3.3  the worked example's 12/11 return through the job's mode.
-- The cancellation-after-download switch stays off: every switch-on case runs in its own rolled-back scenario
-- (pg_temp.isolated_on); a guard at the end checks it is off.
begin;
select plan(51);


-- Fixtures and helpers (as 037_transfer_line_ops: its fixture, 035's helpers and its own) ---------------------


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

-- The base: the account's cash (an unidentified payment of 10 000,00 €) and its statement of yesterday
select pg_temp.collect('13', 1000000, private.paris_today() - 6, false);
select pg_temp.stmt('00', private.paris_today() - 1);


-- 1–3. « Désimputer » ---------------------------------------------------------------------------------------------------
-- 1. Martin's collection E (200 000) remitted (its payout debited yesterday), another collection of his pending; E's
-- allocation reversed today at its own date (three days ago, before the payout): the cover A1, dated at the payout
create or replace function pg_temp.s1() returns jsonb language plpgsql as $$
declare v_run uuid; v jsonb; v_r uuid; a public.client_advance; d date := private.paris_today();
begin
  v_run := pg_temp.remitted('a1', '11', 200000, 'a11');
  perform pg_temp.pending('a1', '12', 50000);
  v := pg_temp.unalloc('11');
  v_r := pg_temp.rev(pg_temp.alloc('11'));
  a := pg_temp.adv_of(v_r);
  return (jsonb_build_object(
    'result', jsonb_build_array(jsonb_array_length(v -> 'advances'), v -> 'advances' -> 0 ->> 'amount_minor',
                                (v -> 'advances' -> 0 ->> 'advance_id')::uuid = a.id),
    'advance', jsonb_build_array(a.cause, a.amount_minor, a.mandate_id = pg_temp.mandate('a1'),
                                 pg_temp.ekey(a.entry_id) = 'adv:' || v_r),
    'dates', jsonb_build_array(pg_temp.edate(v_r) = d - 3, pg_temp.edate(a.entry_id) = d - 1),
    'books', pg_temp.books(a.entry_id),
    'queue', pg_temp.queue('a1'),
    'day_before_payout', jsonb_build_array(pg_temp.bal('client_payable', 'a1', d - 2),
                                           pg_temp.bal('client_advance_receivable', 'a1', d - 2),
                                           pg_temp.bal('due_to_servicer', null, d - 2)),
    'today', jsonb_build_array(pg_temp.bal('client_payable', 'a1', d),
                               pg_temp.bal('client_advance_receivable', 'a1', d),
                               pg_temp.bal('due_to_servicer', null, d)),
    'check', pg_temp.state('select private.ledger_check_now()')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s1'),
  '{"result": [1, "200000", true], "advance": ["remitted_reversal", 200000, true, true], "dates": [true, true],
    "books": {"due_to_servicer": 200000, "client_payable": -200000, "client_advance_receivable": 200000,
              "due_from_client_funds": -200000},
    "queue": ["allocation:50000", "allocation_reversal:-200000", "client_advance:200000"],
    "day_before_payout": [-50000, 0, 0], "today": [-50000, 200000, 200000], "check": "ok", "nightly": []}'::jsonb,
  '1 (F3): a remitted allocation reversed → one advance (cause, R, line amount, its mandate, adv:<R>) dated at the payout, '
  'not at R''s back date; the queue holds R and A1, the other item unchanged; nothing of it shows before the payout');

-- 2. Lilas' collection remitted, nothing else pending: reversed, no LG008 and no overrun advance
create or replace function pg_temp.s2() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.remitted('a2', '21', 100000, 'a21');
  v := pg_temp.unalloc('21');
  return (jsonb_build_object('error', v -> 'error', 'advances', pg_temp.advs('a2'), 'owed', pg_temp.owed('a2'),
                            'check', pg_temp.state('select private.ledger_check_now()')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s2'),
  '{"error": null, "advances": ["remitted_reversal:100000"], "owed": 0, "check": "ok", "nightly": []}'::jsonb,
  '2: with nothing else pending the cover keeps 4670 at 0 (no LG008), and no payout_overrun');

-- 3. a pending allocation (in no run) reversed: no advance, the queue nets the pair
create or replace function pg_temp.s3() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.pending('a2', '31', 100000);
  v := pg_temp.unalloc('31');
  return jsonb_build_object('result', v -> 'advances', 'advances', pg_temp.advs('a2'), 'queue', pg_temp.queue('a2'));
end $$;
select is(pg_temp.iso('s3'),
  '{"result": [], "advances": [], "queue": ["allocation:100000", "allocation_reversal:-100000"]}'::jsonb,
  '3: a pending allocation reversed → no advance; the queue nets the pair');


-- 4, 5. In flight, and the same-run pairs --------------------------------------------------------------------------------
-- 4 (a draft): an allocation held by a draft reversed → no advance
create or replace function pg_temp.s4d() returns jsonb language plpgsql as $$
declare v_d uuid; v jsonb;
begin
  perform pg_temp.pending('a1', '4a', 30000);
  v_d := pg_temp.request('a1', 'draft-run-draft-4a');
  perform pg_temp.prepare_plain(v_d);
  v := pg_temp.unalloc('4a');
  return jsonb_build_object('run', pg_temp.rstatus(v_d), 'result', v -> 'advances', 'advances', pg_temp.advs('a1'));
end $$;
select is(pg_temp.iso('s4d'), '{"run": "draft", "result": [], "advances": []}'::jsonb,
  '4: an allocation held by a draft reversed → no advance');

-- 4: approved (not filed yet): no advance
create or replace function pg_temp.s4a() returns jsonb language plpgsql as $$
declare v_run uuid; v jsonb;
begin
  perform pg_temp.pending('a1', '4b', 30000);
  v_run := pg_temp.flight('a1', 'f4b');
  v := pg_temp.unalloc('4b');
  return jsonb_build_object('run', pg_temp.rstatus(v_run), 'result', v -> 'advances', 'advances', pg_temp.advs('a1'),
                            'check', pg_temp.state('select private.ledger_check_now()'));
end $$;
select is(pg_temp.iso('s4a'), '{"run": "approved", "result": [], "advances": [], "check": "ok"}'::jsonb,
  '4: an allocation held by an approved run reversed → no advance (design §13 #3), no LG009 while in flight');

-- 4, 5d: sent (its file handed out): no advance; its payout booked → adv:<R>:<run> at the debit date, with the payout and its
-- debit line, no payout_overrun, the run page lists it
create or replace function pg_temp.s4() returns jsonb language plpgsql as $$
declare v_run uuid; v_r uuid; v_t uuid; v_line uuid; a public.client_advance; w jsonb; d date := private.paris_today();
begin
  perform pg_temp.pending('a1', '41', 200000);
  v_run := pg_temp.flight('a1', 'f41');
  perform pg_temp.handed_out('file-b41', 'gen-file-b41');
  w := jsonb_build_object('run_sent', pg_temp.rstatus(v_run), 'sent', pg_temp.unalloc('41') -> 'advances',
                          'after_sent', pg_temp.advs('a1'));
  v_r := pg_temp.rev(pg_temp.alloc('41'));
  v_t := pg_temp.rtransfer(v_run);
  v_line := pg_temp.debit(v_run, 'b41');
  a := pg_temp.adv_of(v_r);
  return (w || jsonb_build_object(
    'booked', pg_temp.advs('a1'), 'run', pg_temp.rstatus(v_run),
    'key', pg_temp.ekey(a.entry_id) = 'adv:' || v_r || ':' || v_run, 'date', pg_temp.edate(a.entry_id) = d - 1,
    'transfer', a.transfer_id = v_t, 'line', a.bank_transaction_id = v_line, 'mandate', a.mandate_id = pg_temp.mandate('a1'),
    'owed', pg_temp.owed('a1'), 'check', pg_temp.state('select private.ledger_check_now()'),
    'page', pg_temp.page_advances(v_run)))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s4'),
  '{"run_sent": "sent", "sent": [], "after_sent": [], "booked": ["remitted_reversal:200000"],
    "run": "booked", "key": true, "date": true, "transfer": true, "line": true, "mandate": true, "owed": 0, "check": "ok",
    "page": [["remitted_reversal", "200000"]], "nightly": []}'::jsonb,
  '4, 5d (F5): a line reversed after its run''s approval → no advance in flight; covered when the payout is booked '
  '(adv:<R>:<run>, the debit date, its transfer and line), never payout_overrun; the run page lists it');

-- 5a. a same-run pair (E and R both pending at the prepare) in an N = 0 run booked at approval → no advance, no LG009
create or replace function pg_temp.s5a() returns jsonb language plpgsql as $$
declare v_run uuid; a text;
begin
  perform pg_temp.pending('a2', '51', 100000);
  perform pg_temp.unalloc('51');
  v_run := pg_temp.request('a2', 'draft-run-p51');
  perform pg_temp.prepare_plain(v_run);
  a := pg_temp.approve_plain(v_run, 'approve-run-p51');
  return (jsonb_build_object('approval', a, 'advances', pg_temp.advs('a2'),
                            'gap', private.remitted_cover_gap(pg_temp.rev(pg_temp.alloc('51'))),
                            'check', pg_temp.state('select private.ledger_check_now()')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s5a'), '{"approval": "booked:booked", "advances": [], "gap": 0, "check": "ok", "nightly": []}'::jsonb,
  '5a (M7-MONEY-1): a same-run pair in an N = 0 run booked at approval → no advance, no LG009');

-- 5b. the same pair in a run with another line, its payout booked by the job → no advance
create or replace function pg_temp.s5b() returns jsonb language plpgsql as $$
declare v_run uuid;
begin
  perform pg_temp.pending('a2', '52', 100000);
  perform pg_temp.unalloc('52');
  perform pg_temp.pending('a2', '53', 30000);
  v_run := pg_temp.flight('a2', 'p52');
  perform pg_temp.debit(v_run, 'b52');
  return (jsonb_build_object('net', (select net_minor from public.remittance_run where id = v_run),
                            'run', pg_temp.rstatus(v_run), 'advances', pg_temp.advs('a2'), 'owed', pg_temp.owed('a2'),
                            'check', pg_temp.state('select private.ledger_check_now()')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s5b'), '{"net": 30000, "run": "booked", "advances": [], "owed": 0, "check": "ok", "nightly": []}'::jsonb,
  '5b: a same-run pair beside another line, its payout booked → no advance for the pair');

-- 5c. a run cancelled before download (E released), R posted, the next run carrying the pair → no advance
create or replace function pg_temp.s5c() returns jsonb language plpgsql as $$
declare v_x uuid; v_y uuid; v jsonb; a text;
begin
  perform pg_temp.pending('a2', '54', 100000);
  v_x := pg_temp.flight('a2', 'p54');
  perform pg_temp.cancel_run(v_x, 'p54');
  v := pg_temp.unalloc('54');
  v_y := pg_temp.request('a2', 'draft-run-q54');
  perform pg_temp.prepare_plain(v_y);
  a := pg_temp.approve_plain(v_y, 'approve-run-q54');
  return (jsonb_build_object('cancelled', pg_temp.rstatus(v_x), 'result', v -> 'advances', 'approval', a,
                            'advances', pg_temp.advs('a2'), 'check', pg_temp.state('select private.ledger_check_now()')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s5c'),
  '{"cancelled": "cancelled", "result": [], "approval": "booked:booked", "advances": [], "check": "ok", "nightly": []}'::jsonb,
  '5c: a run cancelled before download, the reversal then carried with its collection by the next run → no advance');

-- 5e (switch on). E's run cancelled after download; its payout U executed late pays E (P = A, an attribution); E
-- reversed → covered for the attribution (T = 40 000); the pair then booked at approval (N = 0, T unchanged); U comes
-- back → the cover released (return:rr:…), none left, no LG009, 4670 at 0
create or replace function pg_temp.s5e() returns jsonb language plpgsql as $$
declare v_x uuid; v_y uuid; v_r uuid; a public.client_advance; w jsonb;
begin
  v_x := pg_temp.late_cancel('a4', '5e', 40000, '5e0');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, '5e1'));
  perform pg_temp.unalloc('5e');
  v_r := pg_temp.rev(pg_temp.alloc('5e'));
  a := pg_temp.adv_of(v_r);
  w := w || jsonb_build_object('covered', pg_temp.live_advs('a4'), 'target', private.remitted_cover_target(v_r));
  v_y := pg_temp.request('a4', 'draft-run-5e2');
  perform pg_temp.prepare_plain(v_y);
  w := w || jsonb_build_object('pair_run', pg_temp.approve_plain(v_y, 'approve-run-5e2'),
                               'pair_target', private.remitted_cover_target(v_r));
  w := w || jsonb_build_object('returned', pg_temp.late_return(v_x, '5e3'));
  return (w || jsonb_build_object(
    'after', pg_temp.live_advs('a4'), 'released', pg_temp.ekey(pg_temp.rev(a.entry_id)) like 'return:rr:%',
    'gap', private.remitted_cover_gap(v_r), 'owed', pg_temp.owed('a4'),
    'check', pg_temp.state('select private.ledger_check_now()')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s5e', true),
  '{"exec": "ok", "covered": ["remitted_reversal:40000"], "target": 40000, "pair_run": "booked:booked",
    "pair_target": 40000, "returned": "ok", "after": [], "released": true, "gap": 0, "owed": 0, "check": "ok", "nightly": []}'::jsonb,
  '5e (switch on): a pair with an unplanned attribution of E: T = the attribution, covered; the unplanned payout back → '
  'the cover released, none left, no LG009');

-- 5f (switch on; Q17's default a). X's payout cancelled after download, U executed late (its −A row attributes E); the
-- next run Y holds E (+A) and U's row (−A): N = 0, booked at approval; R(E) → E remitted in Y, T = A, A1 = A (adv:<R>);
-- U back → U's reversal re-queues +A, A1 stays (no release), no LG009; the queue holds +A; paid_on null
create or replace function pg_temp.s5f() returns jsonb language plpgsql as $$
declare v_x uuid; v_y uuid; v_e uuid; v_r uuid; w jsonb;
begin
  v_x := pg_temp.late_cancel('a5', '5f', 40000, '5f0');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, '5f1'));
  v_y := pg_temp.request('a5', 'draft-run-5f2');
  perform pg_temp.prepare_plain(v_y);
  w := w || jsonb_build_object('y', pg_temp.approve_plain(v_y, 'approve-run-5f2'));
  v_e := pg_temp.alloc('5f');
  w := w || jsonb_build_object('how_before', (select x.paid_how from private.entry_remitted(v_e) x));
  perform pg_temp.unalloc('5f');
  v_r := pg_temp.rev(v_e);
  w := w || jsonb_build_object('target', private.remitted_cover_target(v_r), 'covered', pg_temp.live_advs('a5'),
                               'key', pg_temp.ekey((pg_temp.adv_of(v_r)).entry_id) = 'adv:' || v_r);
  w := w || jsonb_build_object('returned', pg_temp.late_return(v_x, '5f3'));
  return (w || jsonb_build_object(
    'after', pg_temp.live_advs('a5'), 'gap', private.remitted_cover_gap(v_r),
    'queue_total', (select sum(q.amount_minor) from private.remittance_pending q
                    where q.client_organization_id = pg_temp.c('a5')),
    'paid_on', (select x.paid_on from private.entry_remitted(v_e) x),
    'remitted_in_y', (select x.run_id = v_y from private.entry_remitted(v_e) x),
    'check', pg_temp.state('select private.ledger_check_now()')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s5f', true),
  '{"exec": "ok", "y": "booked:booked", "how_before": "netted", "target": 40000, "covered": ["remitted_reversal:40000"],
    "key": true, "returned": "ok", "after": ["remitted_reversal:40000"], "gap": 0, "queue_total": 40000,
    "paid_on": null, "remitted_in_y": true, "check": "ok", "nightly": []}'::jsonb,
  '5f (switch on, Q17 a): E remitted in an N = 0 run netted by an unplanned payout; reversed → A1 = A; the payout back '
  '→ A re-queued, A1 kept, no release, no LG009; paid_on null (rule 4); before, « netted »');

-- 5f (allocation_remitted): the same, U back before any reversal: the « Désimputer » read shows paid_on null
create or replace function pg_temp.s5g() returns jsonb language plpgsql as $$
declare v_x uuid; v_y uuid; p jsonb; w jsonb;
begin
  v_x := pg_temp.late_cancel('a5', '5a', 40000, '5a0');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, '5a1'));
  v_y := pg_temp.request('a5', 'draft-run-5a2');
  perform pg_temp.prepare_plain(v_y);
  w := w || jsonb_build_object('y', pg_temp.approve_plain(v_y, 'approve-run-5a2'), 'returned', pg_temp.late_return(v_x, '5a3'));
  p := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('5a')));
  return w || jsonb_build_object('listed', jsonb_array_length(p), 'run', p -> 0 ->> 'run_number' = pg_temp.rnum(v_y),
                                 'amount', p -> 0 ->> 'amount_minor', 'paid_on', p -> 0 -> 'paid_on',
                                 'paid_how', p -> 0 -> 'paid_how');
end $$;
select is(pg_temp.iso('s5g', true),
  '{"exec": "ok", "y": "booked:booked", "returned": "ok", "listed": 1, "run": true, "amount": "40000",
    "paid_on": null, "paid_how": null}'::jsonb,
  '5f: allocation_remitted lists E remitted in Y, paid_on null once the unplanned payout that netted it came back');


-- 6–8. M2b returns -------------------------------------------------------------------------------------------------------
-- 6. ops' strict link of a payment with an allocation and a forward in a booked run → two advances, dated at the return
-- (after the payout: R's own date), the forward's on no mandate
create or replace function pg_temp.s6() returns jsonb language plpgsql as $$
declare v_run uuid; k text; d date := private.paris_today();
begin
  perform pg_temp.split_pay('a1', '61', 300000, 200000);
  v_run := pg_temp.flight('a1', 'f61');
  perform pg_temp.debit(v_run, 'b61');
  perform pg_temp.stmt2('b62', d, jsonb_build_array(jsonb_build_object('amount', 300000, 'kind', 'return',
                                                                         'e2e', 'E2E-61')));
  k := pg_temp.link('link-key-61', pg_temp.l2('b62', 1), 'return', pg_temp.pay('61'), null, '300000');
  return (jsonb_build_object(
    'link', k, 'advances', pg_temp.advs('a1'),
    'mandates', (select jsonb_agg(a.mandate_id = pg_temp.mandate('a1') order by a.amount_minor desc)
                 from public.client_advance a where a.client_organization_id = pg_temp.c('a1')),
    'dated', (select bool_and(pg_temp.edate(a.entry_id) = d) from public.client_advance a
              where a.client_organization_id = pg_temp.c('a1')),
    'owed', pg_temp.owed('a1')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s6'),
  '{"link": "return", "advances": ["remitted_reversal:200000", "remitted_reversal:100000"], "mandates": [true, null],
    "dated": true, "owed": 0, "nightly": []}'::jsonb,
  '6: an M2b return (ops) of a payment whose allocation and forward were remitted → two advances, at the return date');

-- 6 (partial). a partial return of a remitted payment: every remitted entry covered in full
create or replace function pg_temp.s6b() returns jsonb language plpgsql as $$
declare k text;
begin
  perform pg_temp.remitted('a1', '63', 200000, 'b63');
  perform pg_temp.stmt2('b64', private.paris_today(), jsonb_build_array(jsonb_build_object(
    'amount', 150000, 'kind', 'return', 'e2e', 'E2E-63')));
  k := pg_temp.link('link-key-63', pg_temp.l2('b64', 1), 'return', pg_temp.pay('63'), null, '200000');
  return (jsonb_build_object('link', k, 'advances', pg_temp.advs('a1'), 'owed', pg_temp.owed('a1')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s6b'), '{"link": "return", "advances": ["remitted_reversal:200000"], "owed": 0, "nightly": []}'::jsonb,
  '6: a partial return reverses every allocation (M2b), each remitted one covered in full (founder Q1 default)');

-- 7. the job's mode: three returns in one chunk, one of a remitted payment → its advance, all three posted
create or replace function pg_temp.s7a() returns jsonb language plpgsql as $$
declare d date := private.paris_today();
begin
  perform pg_temp.remitted('a1', '71', 100000, 'b71');
  perform pg_temp.pending('a2', '72', 20000);
  perform pg_temp.pending('a2', '73', 30000);
  perform pg_temp.stmt2('b72', d, jsonb_build_array(
    jsonb_build_object('amount', 100000, 'kind', 'return', 'e2e', 'E2E-71'),
    jsonb_build_object('amount', 20000, 'kind', 'return', 'e2e', 'E2E-72'),
    jsonb_build_object('amount', 30000, 'kind', 'return', 'e2e', 'E2E-73')));
  perform pg_temp.job_returns(jsonb_build_array(jsonb_build_array(pg_temp.l2('b72', 1), '71'),
                                                jsonb_build_array(pg_temp.l2('b72', 2), '72'),
                                                jsonb_build_array(pg_temp.l2('b72', 3), '73')));
  return (jsonb_build_object(
    'linked', (select count(*) from public.bank_debit_link
               where bank_transaction_id in (pg_temp.l2('b72', 1), pg_temp.l2('b72', 2), pg_temp.l2('b72', 3))),
    'advances', pg_temp.advs('a1') || pg_temp.advs('a2'), 'owed', pg_temp.owed('a1')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s7a'), '{"linked": 3, "advances": ["remitted_reversal:100000"], "owed": 0, "nightly": []}'::jsonb,
  '7: the debit job''s chunk of three returns, one remitted → its advance, the three posted');

-- 7. a planted forgotten cover in the chunk (the cover skips payment 76's reversals: a wrapper, rolled back) → that link
-- posting_failed (LG009), the two remitted others posted and covered; the chunk's cover working table begun again at each
-- try and at the final post (F18: never « already exists »)
create or replace function pg_temp.s7b() returns jsonb language plpgsql as $$
declare d date := private.paris_today();
begin
  perform pg_temp.remitted('a1', '74', 100000, 'b74');
  perform pg_temp.remitted('a2', '75', 50000, 'b75');
  perform pg_temp.remitted('a4', '76', 40000, 'b76');
  alter function private.cover_remitted_reversals(uuid[], uuid[]) rename to cover_remitted_reversals_planted;
  create function private.cover_remitted_reversals(p_reversal_ids uuid[], p_line_ids uuid[] default null)
  returns integer language sql security definer set search_path = '' as $f$
    select private.cover_remitted_reversals_planted(
      array(select x from unnest(p_reversal_ids) x
            where not exists (select 1 from public.ledger_entry e
                              where e.id = x and e.payment_id = 'f1000000-0000-0000-0000-000000000076')),
      null) $f$;
  perform pg_temp.stmt2('b77', d, jsonb_build_array(
    jsonb_build_object('amount', 100000, 'kind', 'return', 'e2e', 'E2E-74'),
    jsonb_build_object('amount', 50000, 'kind', 'return', 'e2e', 'E2E-75'),
    jsonb_build_object('amount', 40000, 'kind', 'return', 'e2e', 'E2E-76')));
  perform pg_temp.job_returns(jsonb_build_array(jsonb_build_array(pg_temp.l2('b77', 1), '74'),
                                                jsonb_build_array(pg_temp.l2('b77', 2), '75'),
                                                jsonb_build_array(pg_temp.l2('b77', 3), '76')));
  return jsonb_build_object(
    'linked', (select count(*) from public.bank_debit_link
               where bank_transaction_id in (pg_temp.l2('b77', 1), pg_temp.l2('b77', 2), pg_temp.l2('b77', 3))),
    'failed', left(pg_temp.review(pg_temp.l2('b77', 3)), 20),
    'advances', jsonb_build_array(pg_temp.advs('a1'), pg_temp.advs('a2'), pg_temp.advs('a4')),
    'check', pg_temp.state('select private.ledger_check_now()'));
end $$;
select is(pg_temp.iso('s7b'),
  '{"linked": 2, "failed": "posting_failed:LG009", "advances": [["remitted_reversal:100000"],
    ["remitted_reversal:50000"], []], "check": "ok"}'::jsonb,
  '7 (F18): a forgotten cover in the job''s chunk → that link posting_failed (LG009), the others posted and covered, '
  'the cover''s working table begun again at every try');

-- 8. « Retour au-delà du paiement » of a remitted payment → the M2b part covered, the excess the servicer's loss
create or replace function pg_temp.s8() returns jsonb language plpgsql as $$
declare k text;
begin
  perform pg_temp.remitted('a1', '81', 100000, 'b81');
  perform pg_temp.stmt2('b82', private.paris_today(), jsonb_build_array(jsonb_build_object(
    'amount', 120000, 'kind', 'return', 'e2e', 'E2E-81')));
  k := pg_temp.link('link-key-81', pg_temp.l2('b82', 1), 'loss', pg_temp.pay('81'), null, '100000');
  return (jsonb_build_object('link', k, 'advances', pg_temp.advs('a1'), 'bookings', pg_temp.bookings(pg_temp.l2('b82', 1)),
                            'owed', pg_temp.owed('a1')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s8'),
  '{"link": "loss", "advances": ["remitted_reversal:100000"], "bookings": ["1 loss 20000"], "owed": 0, "nightly": []}'::jsonb,
  '8: a return beyond its remitted payment → its M2b part covered, the excess booked as the servicer''s loss');


-- 9, 10, 18. LG009 ------------------------------------------------------------------------------------------------------
create or replace function pg_temp.s9() returns jsonb language plpgsql as $$
begin
  perform pg_temp.remitted('a1', '91', 100000, 'b91');
  perform private.ledger_reverse(pg_temp.alloc('91'), 'raw-test-91', 'Retour (test)', private.paris_today());
  return jsonb_build_object('gap', private.remitted_cover_gap(pg_temp.rev(pg_temp.alloc('91'))),
                            'check', pg_temp.state('select private.ledger_check_now()'));
end $$;
select is(pg_temp.iso('s9'), '{"gap": 100000, "check": "LG009"}'::jsonb,
  '9: a raw reversal of a remitted allocation → LG009 at private.ledger_check_now()');

-- 10. a run set booked with a reversed line and no cover (a direct update) → LG009
create or replace function pg_temp.s10a() returns jsonb language plpgsql as $$
declare v_run uuid; w jsonb;
begin
  perform pg_temp.pending('a1', 'a0', 100000);
  v_run := pg_temp.flight('a1', 'pa0');
  perform private.ledger_reverse(pg_temp.alloc('a0'), 'raw-test-a0', 'Retour (test)', private.paris_today());
  w := jsonb_build_object('in_flight', pg_temp.state('select private.ledger_check_now()'));
  update public.remittance_run set status = 'booked', booked_on = private.paris_today(), version = version + 1
  where id = v_run;
  return w || jsonb_build_object('booked', pg_temp.state('select private.ledger_check_now()'));
end $$;
select is(pg_temp.iso('s10a'), '{"in_flight": "ok", "booked": "LG009"}'::jsonb,
  '10: a reversal of a line in flight passes; its run set booked with no cover → LG009');

-- 10. the same with a same-run pair → no LG009
create or replace function pg_temp.s10b() returns jsonb language plpgsql as $$
declare v_run uuid;
begin
  perform pg_temp.pending('a2', 'b0', 100000);
  perform pg_temp.unalloc('b0');
  perform pg_temp.pending('a2', 'b2', 30000);
  v_run := pg_temp.flight('a2', 'pb0');
  update public.remittance_run set status = 'booked', booked_on = private.paris_today(), version = version + 1
  where id = v_run;
  return jsonb_build_object('booked', pg_temp.state('select private.ledger_check_now()'));
end $$;
select is(pg_temp.iso('s10b'), '{"booked": "ok"}'::jsonb,
  '10 (M7-MONEY-1): a run set booked with a same-run pair → no LG009');

-- 18 (F6). a raw reversal of a remitted_reversal cover's entry → LG009
create or replace function pg_temp.s18() returns jsonb language plpgsql as $$
declare a public.client_advance;
begin
  perform pg_temp.remitted('a1', 'c1', 100000, 'bc1');
  perform pg_temp.unalloc('c1');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('c1')));
  perform private.ledger_reverse(a.entry_id, 'raw-cover-c1', 'Avance annulée (test)', private.paris_today());
  return jsonb_build_object('check', pg_temp.state('select private.ledger_check_now()'));
end $$;
select is(pg_temp.iso('s18'), '{"check": "LG009"}'::jsonb,
  '18 (F6): a cover reversed by any path but the release → LG009');


-- 11, 12 (switch on). The release, the late predecessor --------------------------------------------------------------------
-- 11. a cancelled run's item paid by an unplanned payout, then reversed → advance = the attribution; the unplanned
-- return → the cover reversed (return:rr:…, at the return's date), queue and 4670 as without the pair
create or replace function pg_temp.s11a() returns jsonb language plpgsql as $$
declare v_x uuid; v_r uuid; a public.client_advance; w jsonb;
begin
  v_x := pg_temp.late_cancel('a4', 'ba', 40000, 'ba0');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, 'ba1'));
  perform pg_temp.unalloc('ba');
  v_r := pg_temp.rev(pg_temp.alloc('ba'));
  a := pg_temp.adv_of(v_r);
  w := w || jsonb_build_object('cover', jsonb_build_array(a.cause, a.amount_minor),
                               'returned', pg_temp.late_return(v_x, 'ba2'));
  return (w || jsonb_build_object(
    'live', pg_temp.live_advs('a4'), 'key', pg_temp.ekey(pg_temp.rev(a.entry_id)) = 'return:rr:' || pg_temp.l2('ba2', 1)
                                             || ':' || a.id,
    'date', pg_temp.edate(pg_temp.rev(a.entry_id)) = private.paris_today(), 'gap', private.remitted_cover_gap(v_r),
    'owed', pg_temp.owed('a4'),
    'queue_total', (select sum(q.amount_minor) from private.remittance_pending q
                    where q.client_organization_id = pg_temp.c('a4')),
    'check', pg_temp.state('select private.ledger_check_now()')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s11a', true),
  '{"exec": "ok", "cover": ["remitted_reversal", 40000], "returned": "ok", "live": [], "key": true, "date": true,
    "gap": 0, "owed": 0, "queue_total": 0, "check": "ok", "nightly": []}'::jsonb,
  '11 (switch on): an attributed item reversed → covered for the attribution; the unplanned payout back → the cover '
  'released, queue and 4670 as without the pair');

-- 11. two bookings attributing one item (the second planted: a live attribution of 5 000), one returned → the cover
-- reversed, then the remainder posted again under adv:<R>:rel:<line>:<booking>
create or replace function pg_temp.s11b() returns jsonb language plpgsql as $$
declare v_x uuid; v_r uuid; v_e uuid; a public.client_advance; w jsonb;
begin
  v_x := pg_temp.late_cancel('a4', 'bb', 40000, 'bb0');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, 'bb1'));
  v_e := pg_temp.alloc('bb');
  -- planted: a second live attribution of E (by an entry never reversed, the base cash_in standing for its booking)
  insert into private.unplanned_paid_item (booking_entry_id, ledger_entry_id, organization_id, client_organization_id,
                                           currency, amount_minor)
  select (select id from public.ledger_entry
          where idempotency_key like 'cash_in:e1000000-0000-0000-0000-000000000013:%'), v_e,
         '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a4'), 'EUR', 5000;
  perform pg_temp.unalloc('bb');
  v_r := pg_temp.rev(v_e);
  a := pg_temp.adv_of(v_r);
  w := w || jsonb_build_object('cover', a.amount_minor, 'returned', pg_temp.late_return(v_x, 'bb2'));
  return (w || jsonb_build_object(
    'advances', pg_temp.advs('a4'), 'live', pg_temp.live_advs('a4'),
    'repost', (select pg_temp.ekey(b.entry_id) like 'adv:' || v_r || ':rel:' || pg_temp.l2('bb2', 1) || ':%'
               from public.client_advance b where b.cause_entry_id = v_r and b.id <> a.id),
    'gap', private.remitted_cover_gap(v_r), 'check', pg_temp.state('select private.ledger_check_now()')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s11b', true),
  '{"exec": "ok", "cover": 45000, "returned": "ok", "advances": ["remitted_reversal:45000", "remitted_reversal:5000"],
    "live": ["remitted_reversal:5000"], "repost": true, "gap": 0, "check": "ok", "nightly": []}'::jsonb,
  '11: two bookings attributing one item, one returned → its cover released, the remainder re-posted');

-- 11. a cover with a settlement (planted) → the unplanned return refused advance_settled, nothing booked
create or replace function pg_temp.s11c() returns jsonb language plpgsql as $$
declare v_x uuid; a public.client_advance; w jsonb;
begin
  v_x := pg_temp.late_cancel('a4', 'bc', 40000, 'bc0');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, 'bc1'));
  perform pg_temp.unalloc('bc');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('bc')));
  perform pg_temp.plant_settlement(a.id, 1000);
  return w || jsonb_build_object('returned', pg_temp.late_return(v_x, 'bc2'),
                                 'bookings', pg_temp.bookings(pg_temp.l2('bc2', 1)), 'live', pg_temp.live_advs('a4'));
end $$;
select is(pg_temp.iso('s11c', true),
  '{"exec": "ok", "returned": "advance_settled", "bookings": [], "live": ["remitted_reversal:40000"]}'::jsonb,
  '11: a cover partly recovered → the unplanned return refused advance_settled, nothing booked');

-- 11 (M7-MONEY-2). a cover an approved run is taking back (its planted plan names it) → advance_in_flight, nothing booked
create or replace function pg_temp.s11d() returns jsonb language plpgsql as $$
declare v_x uuid; v_y uuid; a public.client_advance; w jsonb;
begin
  v_x := pg_temp.late_cancel('a4', 'bd', 40000, 'bd0');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, 'bd1'));
  perform pg_temp.unalloc('bd');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('bd')));
  perform pg_temp.pending('a4', 'be', 60000);
  v_y := pg_temp.flight('a4', 'pbd');
  alter table public.remittance_run disable trigger remittance_run_guard;
  update public.remittance_run
  set settlement_plan = jsonb_build_object('settles', jsonb_build_array(jsonb_build_object(
        'ref', a.id, 'kind', 'advance', 'document_id', a.id, 'amount', '1000')))
  where id = v_y;
  alter table public.remittance_run enable always trigger remittance_run_guard;
  return w || jsonb_build_object('y', pg_temp.rstatus(v_y), 'in_flight', (select x.run_id = v_y
                                                                          from private.advance_in_flight_run(a.id) x),
                                 'returned', pg_temp.late_return(v_x, 'bd2'),
                                 'bookings', pg_temp.bookings(pg_temp.l2('bd2', 1)));
end $$;
select is(pg_temp.iso('s11d', true),
  '{"exec": "ok", "y": "approved", "in_flight": true, "returned": "advance_in_flight", "bookings": []}'::jsonb,
  '11 (M7-MONEY-2): a cover an approved run''s plan takes back → the unplanned return refused advance_in_flight');

-- 11. the release skipped (planted: private.remitted_cover_release made a no-op inside the scenario) → the unplanned
-- payout back leaves the cover above its target: refused LG009 at the booking (I23 holds both ways: a cover too large is
-- refused as a missing one is), nothing booked
create or replace function pg_temp.s11e() returns jsonb language plpgsql as $$
declare v_x uuid; v_r uuid; w jsonb; v_back text;
begin
  v_x := pg_temp.late_cancel('a4', 'cf', 40000, 'cf0');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, 'cf1'));
  perform pg_temp.unalloc('cf');
  v_r := pg_temp.rev(pg_temp.alloc('cf'));
  execute $q$ create or replace function private.remitted_cover_release(p_booking_entry_id uuid, p_line_id uuid,
                                                                       p_on date) returns integer
              language sql as 'select 0' $q$;
  v_back := pg_temp.late_return(v_x, 'cf2');
  return w || jsonb_build_object(
    'returned', v_back like 'posting_failed (LG009: ledger: reversal % of an entry remitted to client % is not covered by '
                            'an advance (gap -40000))',
    'gap', private.remitted_cover_gap(v_r), 'check', pg_temp.state('select private.ledger_check_now()'));
end $$;
select is(pg_temp.iso('s11e', true), '{"exec": "ok", "returned": true, "gap": 0, "check": "ok"}'::jsonb,
  '11: the release skipped (planted) → the unplanned payout back refused LG009 (a cover above its target), nothing booked');

-- 12. a late predecessor booked as its run's payout, with a line reversed in flight → the at-booking cover
create or replace function pg_temp.s12() returns jsonb language plpgsql as $$
declare v_run uuid; v_r uuid; a public.client_advance;
begin
  v_run := pg_temp.late_pred('a7', 'd2', 100000, 'bd2a', true);
  v_r := pg_temp.rev(pg_temp.alloc('d2'));
  a := pg_temp.adv_of(v_r);
  return (jsonb_build_object(
    'booked', pg_temp.v('lp-booked-bd2a') = v_run, 'run', pg_temp.rstatus(v_run),
    'x1', pg_temp.status(pg_temp.v('x1-bd2a')), 'x2', pg_temp.status(pg_temp.v('x2-bd2a')),
    'advances', pg_temp.advs('a7'), 'key', pg_temp.ekey(a.entry_id) = 'adv:' || v_r || ':' || v_run,
    'transfer', a.transfer_id = pg_temp.v('x1-bd2a'), 'owed', pg_temp.owed('a7')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s12', true),
  '{"booked": true, "run": "booked", "x1": "cancelled", "x2": "cancelled", "advances": ["remitted_reversal:100000"],
    "key": true, "transfer": true, "owed": 0, "nightly": []}'::jsonb,
  '12 (switch on): a late predecessor booked as its run''s payout covers its run''s reversed line at the booking');


-- 13. Idempotency and roles ---------------------------------------------------------------------------------------------
create or replace function pg_temp.s13() returns jsonb language plpgsql as $$
declare v1 jsonb; v2 jsonb; v_e uuid; v_r uuid; v_g uuid; a public.client_advance; w jsonb; c jsonb;
begin
  perform pg_temp.remitted('a1', 'd3', 100000, 'bd3');
  v_e := pg_temp.alloc('d3');
  v1 := pg_temp.unalloc('d3', 'unalloc-key-d3', '01', 'aal2', array[v_e]);
  v2 := pg_temp.unalloc('d3', 'unalloc-key-d3', '01', 'aal2', array[v_e]);
  v_r := pg_temp.rev(v_e);
  w := jsonb_build_object('replay', v1 = v2, 'one', (select count(*) from public.client_advance
                                                     where cause_entry_id = v_r),
                          'covered', pg_temp.cover('cover-key-1', v_r, '0') ->> 'error');
  -- a gap planted (a raw reversal of another remitted allocation): « Couvrir »'s compare and set and roles
  perform pg_temp.remitted('a2', 'd4', 60000, 'bd4');
  perform private.ledger_reverse(pg_temp.alloc('d4'), 'raw-test-d4', 'Retour (test)', private.paris_today());
  v_g := pg_temp.rev(pg_temp.alloc('d4'));
  w := w || jsonb_build_object(
    'stale', pg_temp.cover('cover-key-2', v_g, '1') ->> 'error',
    'ops', pg_temp.cover('cover-key-3', v_g, '60000', '01') ->> 'error',
    'aal1', pg_temp.cover('cover-key-4', v_g, '60000', '04', 'aal1') ->> 'error');
  c := pg_temp.cover('cover-key-5', v_g, '60000');
  w := w || jsonb_build_object(
    'covered_now', c ->> 'amount_minor', 'gap', private.remitted_cover_gap(v_g),
    'key', pg_temp.ekey((c ->> 'entry_id')::uuid) like 'adv:' || v_g || ':cov:%',
    'replay_cover', pg_temp.cover('cover-key-5', v_g, '60000') = c);
  -- (F18) after a release left a gap (planted: the first cover reversed by its release's key), « Couvrir » posts under
  -- its own key and the gap closes
  a := pg_temp.adv_of(v_r);
  perform private.ledger_reverse(a.entry_id, 'return:rr:test:' || a.id, 'Avance annulée (test)', private.paris_today());
  c := pg_temp.cover('cover-key-6', v_r, '100000');
  return (w || jsonb_build_object(
    'after_release', c ->> 'amount_minor', 'gap_after', private.remitted_cover_gap(v_r),
    'own_key', pg_temp.ekey((c ->> 'entry_id')::uuid) like 'adv:' || v_r || ':cov:%',
    'check', pg_temp.state('select private.ledger_check_now()')))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s13'),
  '{"replay": true, "one": 1, "covered": "remitted cover refused: nothing_to_cover",
    "stale": "remitted cover refused: gap_changed", "ops": "not allowed", "aal1": "not allowed",
    "covered_now": "60000", "gap": 0, "key": true, "replay_cover": true,
    "after_release": "100000", "gap_after": 0, "own_key": true, "check": "ok", "nightly": []}'::jsonb,
  '13 (F18): « Désimputer » replayed → one advance; « Couvrir »: nothing_to_cover, gap_changed, admins at aal2 only, '
  'replayed once; after a release left a gap, its own key adv:<R>:cov:…');


-- 14, 19. The nightly checks ---------------------------------------------------------------------------------------------
-- 14. clean after a covered reversal; a planted raw reversal → one violation with its gap; the delta window (F9): a gap
-- on a reversal posted before the last clean run less a day is not read, the full pass finds it, and a reversal listed
-- uncovered by the last run is read again
create or replace function pg_temp.s14a() returns jsonb language plpgsql as $$
declare v_r uuid; w jsonb; c uuid;
begin
  perform pg_temp.remitted('a1', 'e1', 100000, 'be1');
  perform pg_temp.unalloc('e1');
  c := pg_temp.adv_run();
  w := jsonb_build_object('clean', (select coalesce(jsonb_agg(x.code), '[]') from public.payment_check_result x
                                    where x.run_id = c and x.code in ('remitted_reversal_uncovered', 'advance_ledger')));
  perform pg_temp.remitted('a2', 'e2', 50000, 'be2');
  perform private.ledger_reverse(pg_temp.alloc('e2'), 'raw-test-e2', 'Retour (test)', private.paris_today());
  v_r := pg_temp.rev(pg_temp.alloc('e2'));
  c := pg_temp.adv_run();
  w := w || jsonb_build_object(
    'planted', pg_temp.rows_of(c, 'remitted_reversal_uncovered', v_r),
    'details', (select jsonb_build_array(x.details ->> 'target', x.details ->> 'held', x.severity,
                                         x.details ->> 'client_id' = pg_temp.c('a2')::text)
                from public.payment_check_result x where x.run_id = c and x.code = 'remitted_reversal_uncovered'));
  -- the last run started 23 hours after R was posted and did not list it (a reversal committed after that run's
  -- snapshot): the window's one-day overlap reads it again
  perform pg_temp.prior_run_at((select q.posted_at from public.ledger_entry q where q.id = v_r) + interval '23 hours');
  w := w || jsonb_build_object('overlap', pg_temp.rows_of(pg_temp.adv_run(), 'remitted_reversal_uncovered', v_r));
  -- the last clean run started 41 days from now: R (posted today) is 40 days before its window
  perform pg_temp.prior_run(41);
  w := w || jsonb_build_object('delta', pg_temp.rows_of(pg_temp.adv_run(), 'remitted_reversal_uncovered', v_r),
                               'full', pg_temp.rows_of(pg_temp.adv_run(null, true), 'remitted_reversal_uncovered', v_r));
  -- listed uncovered by the last run: read again
  perform pg_temp.prior_run(42, array[v_r]);
  return w || jsonb_build_object('relisted', pg_temp.rows_of(pg_temp.adv_run(), 'remitted_reversal_uncovered', v_r));
end $$;
select is(pg_temp.iso('s14a'),
  '{"clean": [], "planted": [[true, 50000]], "details": ["50000", "0", "violation", true], "overlap": [[true, 50000]],
    "delta": [], "full": [[true, 50000]], "relisted": [[true, 50000]]}'::jsonb,
  '14 (F9): the nightly finds a planted gap with its target and held; the window reads a day before the last run (one '
  'posted 23 hours before it, not listed, is found); the delta window skips one posted long before it, the full pass '
  'finds it, and a reversal listed uncovered by the last run is read again');

-- 14. a planted settlement on an advance → advance_ledger; advance_open at 31 days, not at 30
create or replace function pg_temp.s14b() returns jsonb language plpgsql as $$
declare a public.client_advance; w jsonb; d date := private.paris_today(); c31 uuid; c30 uuid;
begin
  perform pg_temp.remitted('a1', 'e3', 100000, 'be3');
  perform pg_temp.unalloc('e3');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('e3')));
  c31 := pg_temp.adv_run(d + 31);
  c30 := pg_temp.adv_run(d + 30);
  w := jsonb_build_object('open_31', pg_temp.rows_of(c31, 'advance_open', a.id),
                          'open_30', pg_temp.rows_of(c30, 'advance_open', a.id),
                          'details', (select jsonb_build_array(x.details ->> 'cause', x.oldest_days,
                                                               x.details ->> 'mandate_id' = a.mandate_id::text)
                                      from public.payment_check_result x
                                      where x.run_id = c31 and x.code = 'advance_open'));
  perform pg_temp.plant_settlement(a.id, 1000);
  return w || jsonb_build_object('ledger', pg_temp.rows_of(pg_temp.adv_run(), 'advance_ledger', pg_temp.c('a1')),
                                 'open_after', pg_temp.rows_of(pg_temp.adv_run(d + 31), 'advance_open', a.id));
end $$;
select is(pg_temp.iso('s14b'),
  '{"open_31": [[true, 100000]], "open_30": [], "details": ["remitted_reversal", 31, true],
    "ledger": [[true, 1000]], "open_after": [[true, 99000]]}'::jsonb,
  '14: advance_open after 30 days (31 → alert, 30 → none); a planted settlement → advance_ledger (I18), the open amount less it');

-- 14. run_remittance_checks passes the full pass on the 1st of a month (Paris), not on the 2nd
create or replace function pg_temp.s14c() returns jsonb language plpgsql as $$
declare v_r uuid; c1 uuid; c2 uuid;
begin
  perform pg_temp.remitted('a2', 'e4', 50000, 'be4');
  perform private.ledger_reverse(pg_temp.alloc('e4'), 'raw-test-e4', 'Retour (test)', private.paris_today());
  v_r := pg_temp.rev(pg_temp.alloc('e4'));
  perform pg_temp.prior_run(41);
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa') returning id into c1;
  perform private.run_remittance_checks(c1, '00000000-0000-0000-0000-0000000000aa', '2026-12-02');
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa') returning id into c2;
  perform private.run_remittance_checks(c2, '00000000-0000-0000-0000-0000000000aa', '2026-12-01');
  return jsonb_build_object('second', pg_temp.rows_of(c1, 'remitted_reversal_uncovered', v_r),
                            'first', pg_temp.rows_of(c2, 'remitted_reversal_uncovered', v_r));
end $$;
select is(pg_temp.iso('s14c'), '{"second": [], "first": [[true, 50000]]}'::jsonb,
  '14 (check 2): run_remittance_checks runs the full pass when the day it holds the books to is the 1st (2026-12-01), '
  'not the 2nd');

-- 14. « Vérification complète des avances »: one request and one queued checks message; replayed; refused while one is
-- open, to an ops manager, an admin at aal1, another servicer's admin; a check run that fails after the take leaves it
-- open; the next run_payment_checks takes it and finds the old gap, the run after it takes nothing; the row's guard
create or replace function pg_temp.s14d() returns jsonb language plpgsql as $$
declare v_r uuid; v1 jsonb; v2 jsonb; w jsonb; c uuid; r1 uuid; r2 uuid; m0 bigint;
        v_org uuid := '00000000-0000-0000-0000-0000000000aa';  -- (review round 1) its requests only: other tests' servicers may hold some
begin
  perform pg_temp.remitted('a2', 'e5', 50000, 'be5');
  perform private.ledger_reverse(pg_temp.alloc('e5'), 'raw-test-e5', 'Retour (test)', private.paris_today());
  v_r := pg_temp.rev(pg_temp.alloc('e5'));
  perform pg_temp.prior_run(41);
  m0 := (select count(*) from pgmq.q_payments m where m.message ->> 'type' = 'invariants'
           and m.message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000aa');
  v1 := pg_temp.full_req('full-check-1');
  v2 := pg_temp.full_req('full-check-1');
  w := jsonb_build_object(
    'queued', v1 -> 'queued', 'replay', v1 = v2,
    'rows', (select count(*) from private.advance_full_check_request r where r.organization_id = v_org),
    'msgs', (select count(*) from pgmq.q_payments m where m.message ->> 'type' = 'invariants'
               and m.message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000aa') - m0,
    'again', pg_temp.full_req('full-check-2') ->> 'error',
    'ops', pg_temp.full_req('full-check-3', '01') ->> 'error',
    'aal1', pg_temp.full_req('full-check-4', '04', 'aal1') ->> 'error',
    'other', pg_temp.full_req('full-check-5', '06') ->> 'error',
    'rows_after', (select count(*) from private.advance_full_check_request r where r.organization_id = v_org));
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa') returning id into c;
  begin
    perform private.run_remittance_checks(c, '00000000-0000-0000-0000-0000000000aa', null);
    raise exception 'planted failure after the take' using errcode = 'TR009';
  exception when sqlstate 'TR009' then
    null;
  end;
  w := w || jsonb_build_object('open_after_failure',
                               (select r.run_id is null from private.advance_full_check_request r
                                where r.organization_id = v_org));
  r1 := (private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'run_id')::uuid;
  r2 := (private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'run_id')::uuid;
  return w || jsonb_build_object(
    'taken', (select r.run_id = r1 and r.taken_at is not null from private.advance_full_check_request r
              where r.organization_id = v_org),
    'found', pg_temp.rows_of(r1, 'remitted_reversal_uncovered', v_r),
    'still_r1', (select r.run_id = r1 from private.advance_full_check_request r where r.organization_id = v_org),
    'update', pg_temp.state(format('update private.advance_full_check_request set run_id = %L where organization_id = %L',
                                    r2, v_org)),
    'delete', pg_temp.state(format('delete from private.advance_full_check_request where organization_id = %L',
                                    v_org)));
end $$;
select is(pg_temp.iso('s14d'),
  '{"queued": true, "replay": true, "rows": 1, "msgs": 1, "again": "advance check refused: already_requested",
    "ops": "not allowed", "aal1": "not allowed", "other": "not allowed", "rows_after": 1, "open_after_failure": true,
    "taken": true, "found": [[true, 50000]], "still_r1": true, "update": "23514", "delete": "23514"}'::jsonb,
  '14 (check 2): request_full_advance_check — one request, one checks message, replayed; refusals; taken by the next '
  'complete check run (the old gap found), once; a failing run leaves it open; its guard');

-- 14 (review round 1, CC-1). The window reads the runs whose booking was recorded since the last check run, whatever
-- their booked_on: Martin's X in flight, E reversed then (no cover due yet; recorded three days ago, before the window:
-- planted); last night's run clean; the at-booking cover planted missing (its function a no-op, its commit-time check
-- off: the bug the nightly backstops); X's payout debited five days ago, its statement imported and booked today → the
-- delta pass finds the gap, as the full pass does
create or replace function pg_temp.s14e() returns jsonb language plpgsql as $$
declare v_run uuid; v_r uuid; w jsonb; d date := private.paris_today();
begin
  perform pg_temp.pending('a1', '9a', 100000, d - 9);
  v_run := pg_temp.flight('a1', 'p9a');
  perform pg_temp.handed_out('file-b9a', 'gen-file-b9a');
  perform private.ledger_reverse(pg_temp.alloc('9a'), 'raw-test-9a', 'Retour (test)', d - 4);
  v_r := pg_temp.rev(pg_temp.alloc('9a'));
  set constraints all immediate;
  set constraints all deferred;
  alter table public.ledger_entry disable trigger ledger_entry_append_only;
  update public.ledger_entry set posted_at = now() - interval '3 days' where id = v_r;
  alter table public.ledger_entry enable always trigger ledger_entry_append_only;
  perform pg_temp.prior_run_at(now() - interval '1 hour');
  execute $q$ create or replace function private.cover_booked_run_reversals(p_run_ids uuid[], p_dates date[],
              p_transfer_ids uuid[] default null, p_line_ids uuid[] default null) returns integer
              language sql as 'select 0' $q$;
  set constraints all immediate;
  set constraints all deferred;
  alter table public.remittance_run disable trigger remittance_run_booked_cover;
  perform pg_temp.debit(v_run, 'b9a', d - 5);
  return jsonb_build_object(
    'run', pg_temp.rstatus(v_run), 'booked_on', (select q.booked_on = d - 5 from public.remittance_run q where q.id = v_run),
    'gap', private.remitted_cover_gap(v_r),
    'delta', pg_temp.rows_of(pg_temp.adv_run(), 'remitted_reversal_uncovered', v_r),
    'full', pg_temp.rows_of(pg_temp.adv_run(null, true), 'remitted_reversal_uncovered', v_r));
end $$;
select is(pg_temp.iso('s14e'),
  '{"run": "booked", "booked_on": true, "gap": 100000, "delta": [[true, 100000]], "full": [[true, 100000]]}'::jsonb,
  '14 (review round 1, CC-1): a run booked today from a debit five days old, its line reversed before the window and '
  'its cover planted missing → the delta pass finds the gap (the runs whose booking was recorded since), as the full '
  'pass does');

-- 14 (review round 1, CC-2). The delta window is a key range in every plan: six runs booked twenty days ago, the last
-- check run's window starting forty days from now (nothing inside it); under a generic plan (as PL/pgSQL caches after
-- five calls in one backend) the delta pass fetches no booked run, the full pass every one
create or replace function pg_temp.s14f() returns jsonb language plpgsql as $$
declare c text; i integer := 0; b bigint; w jsonb; d date := private.paris_today();
begin
  foreach c in array array['a1', 'a2', 'a3', 'a4', 'a5', 'a6'] loop
    i := i + 1;
    perform pg_temp.remitted(c, '9' || i, 10000 * i, 'b9' || i, d - 20, d - 25);
  end loop;
  perform pg_temp.prior_run(41);
  set local plan_cache_mode = force_generic_plan;
  b := pg_temp.fetched('public.remittance_run');
  perform pg_temp.adv_run();
  w := jsonb_build_object('delta', pg_temp.fetched('public.remittance_run') - b);
  b := pg_temp.fetched('public.remittance_run');
  perform pg_temp.adv_run(null, true);
  return w || jsonb_build_object('full', pg_temp.fetched('public.remittance_run') - b >= 6);
end $$;
select is(pg_temp.iso('s14f'), '{"delta": 0, "full": true}'::jsonb,
  '14 (review round 1, CC-2): under a generic plan the delta pass fetches no booked run outside its window (a key '
  'range, not a filter), the full pass every one');

-- 19 (F12). the full list of the codes run_advance_checks emits
create or replace function pg_temp.s19() returns jsonb language plpgsql as $$
declare a public.client_advance; c uuid;
begin
  perform pg_temp.remitted('a1', 'e6', 100000, 'be6');
  perform pg_temp.unalloc('e6');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('e6')));
  perform pg_temp.plant_settlement(a.id, 1000);
  perform pg_temp.remitted('a2', 'e7', 50000, 'be7');
  perform private.ledger_reverse(pg_temp.alloc('e7'), 'raw-test-e7', 'Retour (test)', private.paris_today());
  c := pg_temp.adv_run(private.paris_today() + 31, true);
  return (select jsonb_agg(distinct x.code order by x.code) from public.payment_check_result x where x.run_id = c);
end $$;
select is(pg_temp.iso('s19'), '["advance_ledger", "advance_open", "remitted_reversal_uncovered"]'::jsonb,
  '19 (F12): run_advance_checks emits exactly advance_ledger, advance_open, remitted_reversal_uncovered (later slices '
  'extend this list)');


-- 15. RLS and grants ------------------------------------------------------------------------------------------------------
create or replace function pg_temp.s15() returns jsonb language plpgsql as $$
begin
  perform pg_temp.remitted('a8', 'f8', 100000, 'bf8');
  perform pg_temp.unalloc('f8');
  return jsonb_build_object(
    'reads', jsonb_build_array(pg_temp.n_advances('01'), pg_temp.n_advances('01', 'aal1'), pg_temp.n_advances('03'),
                               pg_temp.n_advances('07'), pg_temp.n_advances('08'), pg_temp.n_advances('02'),
                               pg_temp.n_advances('05')),
    'remitted_read', jsonb_build_array(
      jsonb_array_length(pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('f8')))),
      pg_temp.read_as('02', format('select public.allocation_remitted(%L)', pg_temp.pay('f8'))) ->> 'error',
      pg_temp.read_as('05', format('select public.allocation_remitted(%L)', pg_temp.pay('f8'))) ->> 'error',
      pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('f8')), 'aal1') ->> 'error'));
end $$;
select is(pg_temp.iso('s15'),
  '{"reads": [1, 0, 1, 0, 0, 0, 0], "remitted_read": [0, "not allowed", "not allowed", "not allowed"]}'::jsonb,
  '15: a cover is read by money staff at aal2 and the client''s whole-client members only (not a restricted viewer, '
  'another client, a collector, another servicer); allocation_remitted is money staff''s');
select is(array[has_function_privilege('authenticated', 'private.cover_remitted_reversals(uuid[], uuid[])', 'execute'),
                has_function_privilege('authenticated', 'private.cover_booked_run_reversals(uuid[], date[], uuid[], uuid[])',
                                       'execute'),
                has_function_privilege('authenticated', 'private.remitted_cover_release(uuid, uuid, date)', 'execute'),
                has_function_privilege('authenticated', 'private.remitted_cover_post()', 'execute'),
                has_function_privilege('authenticated', 'private.run_advance_checks(uuid, uuid, date, boolean)', 'execute'),
                has_function_privilege('authenticated', 'private.advance_full_check_take(uuid, uuid)', 'execute'),
                has_function_privilege('authenticated', 'private.entry_remitted(uuid, uuid)', 'execute'),
                has_function_privilege('authenticated', 'private.run_settled_on(uuid)', 'execute'),
                has_function_privilege('authenticated', 'private.item_settled_at(uuid, uuid, integer)', 'execute'),
                has_function_privilege('anon', 'public.cover_remitted_reversal(text, uuid, text)', 'execute'),
                has_function_privilege('anon', 'public.request_full_advance_check(text, uuid)', 'execute'),
                has_function_privilege('anon', 'public.allocation_remitted(uuid)', 'execute')],
          array[false, false, false, false, false, false, false, false, false, false, false, false],
  '15: the cover''s internals, the checks and the take are out of reach of authenticated; the commands of anon');
select is(array[has_function_privilege('authenticated', 'public.cover_remitted_reversal(text, uuid, text)', 'execute'),
                has_function_privilege('authenticated', 'public.request_full_advance_check(text, uuid)', 'execute'),
                has_function_privilege('authenticated', 'public.allocation_remitted(uuid)', 'execute'),
                has_function_privilege('service_role', 'private.ledger_check_now()', 'execute')],
          array[true, true, true, true],
  '15: authenticated may call « Couvrir », the full check''s request and the read (each checks the caller inside)');
select is(array[(select c.relrowsecurity from pg_class c where c.oid = 'private.advance_full_check_request'::regclass),
                has_table_privilege('anon', 'private.advance_full_check_request', 'select'),
                has_table_privilege('authenticated', 'private.advance_full_check_request', 'select'),
                has_table_privilege('authenticated', 'private.advance_full_check_request', 'insert'),
                has_table_privilege('authenticated', 'private.advance_full_check_request', 'update'),
                has_table_privilege('authenticated', 'private.advance_full_check_request', 'delete'),
                has_table_privilege('anon', 'private.advance_full_check_request', 'insert')],
          array[true, false, false, false, false, false, false],
  '15 (check 2): private.advance_full_check_request has RLS on and no privilege for anon or authenticated');
select is(pg_temp.try('01', $q$ insert into public.client_advance (organization_id, client_organization_id, currency,
                                  amount_minor, cause, cause_entry_id, entry_id)
                                values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
                                        'EUR', 1, 'remitted_reversal', gen_random_uuid(), gen_random_uuid()) returning 'x' $q$),
          'permission denied for table client_advance', '15: authenticated never inserts an advance');


-- 16. The overrun backstop ------------------------------------------------------------------------------------------------
-- a forged 4670 debit of Martin before his payout's booking (no reversed line explains it) → payout_overrun of that
-- amount, on the run's single mandate (F10)
create or replace function pg_temp.s16() returns jsonb language plpgsql as $$
declare v_run uuid; a public.client_advance;
begin
  perform pg_temp.pending('a1', 'f1', 100000);
  v_run := pg_temp.flight('a1', 'pf1');
  perform pg_temp.handed_out('file-bf1', 'gen-file-bf1');
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'remittance', private.paris_today() - 1, 'remit:test-forged-f1',
          pg_temp.c('a1'), 'bank_transaction', 'e1000000-0000-0000-0000-000000000013');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_payable', 3000, 'EUR', null),
    (1, 2, 'client_money_cash', -3000, 'EUR', '80000000-0000-0000-0000-0000000000cf');
  perform private.ledger_post_set();
  perform pg_temp.debit(v_run, 'bf1');
  a := (select x from public.client_advance x where x.client_organization_id = pg_temp.c('a1'));
  -- (review round 1, tests-ui-3) and the backstop's P0 alert « Reversement au-delà du dû » (plan D6): the open advance
  return jsonb_build_object('advances', pg_temp.advs('a1'), 'mandate', a.mandate_id = pg_temp.mandate('a1'),
                            'owed', pg_temp.owed('a1'),
                            'alert', (select jsonb_agg(jsonb_build_array(x ->> 0 = a.id::text, x -> 1))
                                      from jsonb_array_elements(pg_temp.alerts('payout_overrun')) x));
end $$;
select is(pg_temp.iso('s16'),
  '{"advances": ["payout_overrun:3000"], "mandate": true, "owed": 0, "alert": [[true, 3000]]}'::jsonb,
  '16: the overrun backstop stays — a forged 4670 debit no reversed line explains → payout_overrun, on its run''s '
  'mandate, and its P0 alert payout_overrun for the open advance');


-- 17. paid_on (run_settled_on, entry_remitted.paid_how) --------------------------------------------------------------------
-- (a) RV-1 booked, its payout returned (+N re-queued), then P1 reversed → A1 and paid_on null; (c) while the re-queued
-- item is in an approved run → null; RV-2 debited → its date, « paid », RV-2; RV-2 returned → null; RV-3 → its date
create or replace function pg_temp.s17a() returns jsonb language plpgsql as $$
declare v1 uuid; v2 uuid; v3 uuid; v_e uuid; w jsonb; d date := private.paris_today();
begin
  v1 := pg_temp.remitted('a1', 'f7', 100000, 'bf7', d - 5, d - 6);
  v_e := pg_temp.alloc('f7');
  w := jsonb_build_object('paid', (select jsonb_build_array(x.paid_on = d - 5, x.paid_how, x.paid_run_number = pg_temp.rnum(v1))
                                   from private.entry_remitted(v_e) x));
  perform pg_temp.bounce(v1, 'bf71', d - 4);
  perform pg_temp.unalloc('f7');
  w := w || jsonb_build_object('advances', pg_temp.advs('a1'),
                               'returned', (select x.paid_on from private.entry_remitted(v_e) x));
  perform pg_temp.reconfirm('a1');
  v2 := pg_temp.flight('a1', 'f72');
  w := w || jsonb_build_object('in_flight', (select x.paid_on from private.entry_remitted(v_e) x));
  perform pg_temp.debit(v2, 'bf72', d - 3);
  w := w || jsonb_build_object('rv2', (select jsonb_build_array(x.paid_on = d - 3, x.paid_how,
                                                                x.paid_run_number = pg_temp.rnum(v2))
                                       from private.entry_remitted(v_e) x));
  perform pg_temp.bounce(v2, 'bf73', d - 2);
  w := w || jsonb_build_object('rv2_returned', (select x.paid_on from private.entry_remitted(v_e) x));
  perform pg_temp.reconfirm('a1');
  v3 := pg_temp.flight('a1', 'f74');
  perform pg_temp.debit(v3, 'bf74', d - 1);
  return w || jsonb_build_object('rv3', (select jsonb_build_array(x.paid_on = d - 1, x.paid_how,
                                                                  x.paid_run_number = pg_temp.rnum(v3))
                                         from private.entry_remitted(v_e) x),
                                 'run1', (select jsonb_build_array(s.on_date = d - 1, s.how, s.run_number = pg_temp.rnum(v3))
                                          from private.run_settled_on(v1) s));
end $$;
select is(pg_temp.iso('s17a'),
  '{"paid": [true, "paid", true], "advances": ["remitted_reversal:100000"], "returned": null, "in_flight": null,
    "rv2": [true, "paid", true], "rv2_returned": null, "rv3": [true, "paid", true], "run1": [true, "paid", true]}'::jsonb,
  '17 (a), (c) (M7-MONEY-8, L5; check 1): a payout come back: A1 posted (D1), paid_on null until the re-queued item is '
  'paid by a later run (its date, « paid », its number), null again when that one comes back, then the next (depth 2)');

-- (b) an N = 0 run with D > 0 holding E → paid_on its booked_on, « set_off »
create or replace function pg_temp.s17b() returns jsonb language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending('a3', 'f9', 12000);
  v := pg_temp.run('a3', '{"f9": "12000"}', 12000, 2000, 10, 12);
  return (select jsonb_build_array(pg_temp.rstatus(v), x.paid_on = private.paris_today(), x.paid_how,
                                   x.paid_run_number = pg_temp.rnum(v))
          from private.entry_remitted(pg_temp.alloc('f9')) x);
end $$;
select is(pg_temp.iso('s17b'), '["booked", true, "set_off", true]'::jsonb,
  '17 (b) (check 1): an N = 0 run whose set-off paid E → paid_on its booked_on, « set_off », never « paid »');

-- (d) (switch on; check 2) RV-1's payout x1 cancelled after download and re-issued, x1 executed late and booked as
-- RV-1's payout (a late predecessor: x1 stays cancelled), then x1 returned (its payout_returned booking; x1's
-- return_entry_id stays null): run_settled_on(RV-1) no row, paid_on null; RV-2 pays the re-queued item → its date
create or replace function pg_temp.s17d() returns jsonb language plpgsql as $$
declare v1 uuid; v2 uuid; v_e uuid; w jsonb; p jsonb; d date := private.paris_today();
begin
  v1 := pg_temp.late_pred('a7', 'fa', 100000, 'bfa', false, d - 4);
  v_e := pg_temp.alloc('fa');
  w := jsonb_build_object('booked', pg_temp.v('lp-booked-bfa') = v1, 'run', pg_temp.rstatus(v1),
                          'paid', (select x.paid_how from private.entry_remitted(v_e) x));
  perform pg_temp.stmt2('bfa1', d - 3, jsonb_build_array(jsonb_build_object(
    'dir', 'credit', 'kind', 'return', 'amount', 100000, 'orig', pg_temp.e2e(pg_temp.v('x1-bfa')))));
  w := w || jsonb_build_object('returned', pg_temp.bkx(pg_temp.l2('bfa1', 1), pg_temp.prop(pg_temp.l2('bfa1', 1))),
                               'x1', jsonb_build_array(pg_temp.status(pg_temp.v('x1-bfa')),
                                                       (select return_entry_id from public.bank_transfer
                                                        where id = pg_temp.v('x1-bfa'))));
  p := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('fa')));
  w := w || jsonb_build_object(
    'settled', (select count(*) from private.run_settled_on(v1)),
    'paid_on', (select x.paid_on from private.entry_remitted(v_e) x), 'read', p -> 0 -> 'paid_on');
  perform pg_temp.reconfirm('a7');
  v2 := pg_temp.flight('a7', 'fa2');
  perform pg_temp.debit(v2, 'bfa2', d - 1);
  return w || jsonb_build_object('rv2', (select jsonb_build_array(x.paid_on = d - 1, x.paid_how,
                                                                  x.paid_run_number = pg_temp.rnum(v2))
                                         from private.entry_remitted(v_e) x));
end $$;
select is(pg_temp.iso('s17d', true),
  '{"booked": true, "run": "booked", "paid": "paid", "returned": "ok", "x1": ["cancelled", null], "settled": 0,
    "paid_on": null, "read": null, "rv2": [true, "paid", true]}'::jsonb,
  '17 (d) (switch on; check 2): a late predecessor''s return is read from its booking (not return_entry_id): paid_on '
  'null until the later run pays the re-queued item');


-- (e) (review round 1, M7A-MONEY-1; switch off) S03r: Petit's X (E1 30 000) debited, its payout T1 returned, executed
-- again by the bank (an unplanned payout: its −30 000 row) and returned again (+30 000); the next run Y holds E2
-- (150 000), both +30 000 and the −30 000 row, its invoice set off for the whole gross 180 000: N = 0, booked at
-- approval. The second return is a line of Y itself: netted in Y, never followed into Y again (the recursion that ended
-- too_deep) — Y settled by set-off on its booked_on, and X through Y; allocation_remitted says so for both collections
create or replace function pg_temp.s17e() returns jsonb language plpgsql as $$
declare v_x uuid; v_t uuid; v_y uuid; w jsonb; p1 jsonb; p2 jsonb; d date := private.paris_today();
begin
  v_x := pg_temp.remitted('a8', '8a', 30000, '8a0');
  v_t := pg_temp.rtransfer(v_x);
  perform pg_temp.bounce(v_x, '8a1');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_t, '8a2'), 'returned', pg_temp.late_return(v_t, '8a3'));
  perform pg_temp.reconfirm('a8');
  perform pg_temp.pending('a8', '8b', 150000);
  v_y := pg_temp.request('a8', 'draft-run-8b');
  perform pg_temp.prepare_off(v_y, 'a8', '8b', 1, 1);
  w := w || jsonb_build_object('y', pg_temp.approve_plain(v_y, 'approve-run-8b'));
  w := w || jsonb_build_object('y_lines', (select jsonb_agg(l.kind || ':' || l.amount_minor order by l.kind, l.amount_minor)
                                           from public.remittance_line l where l.run_id = v_y),
                               'y_net', (select jsonb_build_array(q.net_minor, q.settlement_minor, q.transfer_id is null)
                                         from public.remittance_run q where q.id = v_y));
  p1 := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('8a')));
  p2 := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('8b')));
  return w || jsonb_build_object(
    'y_settled', (select jsonb_build_array(s.on_date = d, s.how, s.run_number = pg_temp.rnum(v_y))
                  from private.run_settled_on(v_y) s),
    'x_settled', (select jsonb_build_array(s.on_date = d, s.how, s.run_number = pg_temp.rnum(v_y))
                  from private.run_settled_on(v_x) s),
    'e1', jsonb_build_array(p1 -> 0 ->> 'run_number' = pg_temp.rnum(v_x), p1 -> 0 ->> 'paid_on' = d::text,
                            p1 -> 0 ->> 'paid_how', p1 -> 0 ->> 'paid_run_number' = pg_temp.rnum(v_y)),
    'e2', jsonb_build_array(p2 -> 0 ->> 'run_number' = pg_temp.rnum(v_y), p2 -> 0 ->> 'paid_on' = d::text,
                            p2 -> 0 ->> 'paid_how', p2 -> 0 ->> 'paid_run_number' = pg_temp.rnum(v_y)),
    -- (review round 2) what came back first: X's own payout for E1, nothing for E2
    'via', jsonb_build_array(p1 -> 0 -> 'returned_via', p2 -> 0 -> 'returned_via'),
    'nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s17e'),
  '{"exec": "ok", "returned": "ok", "y": "booked:booked",
    "y_lines": ["allocation:150000", "payout_returned:30000", "payout_returned:30000", "unplanned_payout:-30000"],
    "y_net": [0, 180000, true], "y_settled": [true, "set_off", true], "x_settled": [true, "set_off", true],
    "e1": [true, true, "set_off", true], "e2": [true, true, "set_off", true], "via": ["run", null],
    "nightly": []}'::jsonb,
  '17 (e) (review round 1, M7A-MONEY-1; switch off): an N = 0 run holding an unplanned payout''s −P row and the +P its '
  'return re-queued nets that return in itself — settled by set-off on its booked_on, never too_deep; the earlier '
  'run whose payout came back is settled through it');

-- (f) (review round 1, M7A-MONEY-1; switch on) Dupont's run cancelled after download (E released), its payout executed
-- late (−60 000) and returned (+60 000) before the next run Y; Y holds E, both rows, its invoice set off for the whole
-- gross: N = 0, booked at approval, settled by set-off (the return netted in Y itself)
create or replace function pg_temp.s17f() returns jsonb language plpgsql as $$
declare v_t uuid; v_y uuid; w jsonb; p jsonb; d date := private.paris_today();
begin
  v_t := pg_temp.late_cancel('a6', '6a', 60000, '6a0');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_t, '6a1'), 'returned', pg_temp.late_return(v_t, '6a2'));
  v_y := pg_temp.request('a6', 'draft-run-6a');
  perform pg_temp.prepare_off(v_y, 'a6', '6a', 5, 6);
  w := w || jsonb_build_object('y', pg_temp.approve_plain(v_y, 'approve-run-6a'));
  w := w || jsonb_build_object('y_lines', (select jsonb_agg(l.kind || ':' || l.amount_minor order by l.kind, l.amount_minor)
                                           from public.remittance_line l where l.run_id = v_y));
  p := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('6a')));
  return w || jsonb_build_object(
    'y_settled', (select jsonb_build_array(s.on_date = d, s.how, s.run_number = pg_temp.rnum(v_y))
                  from private.run_settled_on(v_y) s),
    'read', jsonb_build_array(p -> 0 ->> 'paid_on' = d::text, p -> 0 ->> 'paid_how',
                              p -> 0 ->> 'paid_run_number' = pg_temp.rnum(v_y)),
    -- (review round 2) the unplanned payout's return netted in Y itself: nothing came back on E's way
    'via', p -> 0 -> 'returned_via',
    'nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s17f', true),
  '{"exec": "ok", "returned": "ok", "y": "booked:booked",
    "y_lines": ["allocation:60000", "payout_returned:60000", "unplanned_payout:-60000"],
    "y_settled": [true, "set_off", true], "read": [true, "set_off", true], "via": null, "nightly": []}'::jsonb,
  '17 (f) (review round 1, M7A-MONEY-1; switch on): after a cancellation after download, the late payout executed and '
  'returned before the next run: that N = 0 run settles the collection by set-off (« Désimputer » reads it so)');

-- (g) (review round 1, M7A-MONEY-2; switch on) rule 4 paid through a later run: Durand's run cancelled after download
-- (E released), its payout U executed late; Y holds E (+40 000) and U's −40 000 row (N = 0, booked at approval, no
-- transfer); U comes back (+40 000 re-queued) and Z pays it (with another collection): allocation_remitted says E was
-- remitted in Y — a run without a transfer of its own (run_transfer false: the payout that came back was U, « hors
-- reversement ») — and paid by Z; Z's own collection was remitted in a run with its transfer
create or replace function pg_temp.s17g() returns jsonb language plpgsql as $$
declare v_t uuid; v_y uuid; v_z uuid; w jsonb; p jsonb; q jsonb; d date := private.paris_today();
begin
  v_t := pg_temp.late_cancel('a7', '7a', 40000, '7a0');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_t, '7a1'));
  v_y := pg_temp.request('a7', 'draft-run-7a2');
  perform pg_temp.prepare_plain(v_y);
  w := w || jsonb_build_object('y', pg_temp.approve_plain(v_y, 'approve-run-7a2'));
  w := w || jsonb_build_object('y_transfer', pg_temp.rtransfer(v_y));
  w := w || jsonb_build_object('returned', pg_temp.late_return(v_t, '7a3'));
  perform pg_temp.reconfirm('a7');
  perform pg_temp.pending('a7', '7b', 25000);
  v_z := pg_temp.flight('a7', '7a4');
  perform pg_temp.debit(v_z, '7a4', d - 1);
  p := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('7a')));
  q := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('7b')));
  return w || jsonb_build_object(
    'e', jsonb_build_array(p -> 0 ->> 'run_number' = pg_temp.rnum(v_y), p -> 0 -> 'run_transfer', p -> 0 ->> 'paid_how',
                           p -> 0 ->> 'paid_on' = (d - 1)::text, p -> 0 ->> 'paid_run_number' = pg_temp.rnum(v_z)),
    'z_own', jsonb_build_array(q -> 0 ->> 'run_number' = pg_temp.rnum(v_z), q -> 0 -> 'run_transfer',
                               q -> 0 ->> 'paid_how', q -> 0 ->> 'paid_run_number' = pg_temp.rnum(v_z)),
    -- (review round 2) what came back first: U, outside any run, for E; nothing for Z's own collection
    'via', jsonb_build_array(p -> 0 -> 'returned_via', q -> 0 -> 'returned_via'));
end $$;
select is(pg_temp.iso('s17g', true),
  '{"exec": "ok", "y": "booked:booked", "y_transfer": null, "returned": "ok",
    "e": [true, false, "paid", true, true], "z_own": [true, true, "paid", true], "via": ["unplanned", null]}'::jsonb,
  '17 (g) (review round 1, M7A-MONEY-2; switch on): a collection remitted in an N = 0 run and paid by a later run after '
  'the unplanned payout that netted it came back: allocation_remitted says the remitted run had no transfer of its own '
  '(run_transfer false), and true for a run paid by its own payout');

-- (h) (review round 2, run-settled-transfer-run-unplanned-return; switch off) S03r with a run debited between the two
-- returns: Petit's X (E1 30 000) debited, its payout T1 returned (R1 +30 000 re-queued), executed again by the bank (an
-- unplanned payout U whose P paid R1: its −30 000 row); the next run Y holds E2 (150 000), R1 and U's row (net
-- 150 000), its payout debited today; then U comes back (+30 000 re-queued). Y's own payout paid E2 and stayed paid; R1
-- was paid by U, which came back: E1 is not with the client (paid_on null; what came back first is X's own payout) and
-- run X is not settled; once Z pays the re-queued +30 000, E1 is paid on Z's debit
create or replace function pg_temp.s17h() returns jsonb language plpgsql as $$
declare v_x uuid; v_t uuid; v_y uuid; v_z uuid; w jsonb; p1 jsonb; p2 jsonb; d date := private.paris_today();
begin
  v_x := pg_temp.remitted('a8', '8c', 30000, 'c80', d - 2, d - 3);
  v_t := pg_temp.rtransfer(v_x);
  perform pg_temp.bounce(v_x, 'c81', d - 1);
  w := jsonb_build_object('exec', pg_temp.late_exec(v_t, 'c82'));
  perform pg_temp.reconfirm('a8');
  perform pg_temp.pending('a8', '8d', 150000);
  v_y := pg_temp.flight('a8', 'c83');
  perform pg_temp.debit(v_y, 'c84', d);
  w := w || jsonb_build_object(
    'y_lines', (select jsonb_agg(l.kind || ':' || l.amount_minor order by l.kind, l.amount_minor)
                from public.remittance_line l where l.run_id = v_y),
    'y', jsonb_build_array(pg_temp.rstatus(v_y), (select q.net_minor from public.remittance_run q where q.id = v_y)),
    -- (before U comes back, X's chain paid again by T1's late execution, today: run_settled_on rule 2)
    'before', (select jsonb_build_array(x.paid_on = d, x.paid_how, x.paid_run_number = pg_temp.rnum(v_x))
               from private.entry_remitted(pg_temp.alloc('8c')) x));
  w := w || jsonb_build_object('returned', pg_temp.late_return(v_t, 'c85'), 'queue', pg_temp.queue('a8'));
  p1 := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('8c')));
  p2 := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('8d')));
  w := w || jsonb_build_object(
    'e1', jsonb_build_array(p1 -> 0 ->> 'run_number' = pg_temp.rnum(v_x), p1 -> 0 -> 'run_transfer', p1 -> 0 -> 'paid_on',
                            p1 -> 0 -> 'paid_how', p1 -> 0 -> 'paid_run_number', p1 -> 0 -> 'returned_via'),
    'x_settled', (select count(*) from private.run_settled_on(v_x)),
    'e2', jsonb_build_array(p2 -> 0 ->> 'run_number' = pg_temp.rnum(v_y), p2 -> 0 ->> 'paid_on' = d::text,
                            p2 -> 0 ->> 'paid_how', p2 -> 0 ->> 'paid_run_number' = pg_temp.rnum(v_y),
                            p2 -> 0 -> 'returned_via'),
    'nightly', pg_temp.nightly());
  -- (the unplanned return marks the payout account of X's run returned: retired already, the current one stays)
  v_z := pg_temp.flight('a8', 'c86');
  perform pg_temp.debit(v_z, 'c87', d);
  p1 := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('8c')));
  return w || jsonb_build_object(
    'z', jsonb_build_array(p1 -> 0 ->> 'paid_on' = d::text, p1 -> 0 ->> 'paid_how',
                           p1 -> 0 ->> 'paid_run_number' = pg_temp.rnum(v_z), p1 -> 0 -> 'returned_via'),
    'x_then', (select jsonb_build_array(s.on_date = d, s.how, s.run_number = pg_temp.rnum(v_z))
               from private.run_settled_on(v_x) s));
end $$;
select is(pg_temp.iso('s17h'),
  '{"exec": "ok", "y_lines": ["allocation:150000", "payout_returned:30000", "unplanned_payout:-30000"],
    "y": ["booked", 150000], "before": [true, "paid", true], "returned": "ok", "queue": ["payout_returned:30000"],
    "e1": [true, true, null, null, null, "run"], "x_settled": 0, "e2": [true, true, "paid", true, null],
    "nightly": [], "z": [true, "paid", true, "run"], "x_then": [true, "paid", true]}'::jsonb,
  '17 (h) (review round 2; switch off): a run debited with its own payout and the −P row of an unplanned payout that '
  'paid an earlier run''s return: once that unplanned payout comes back, the earlier run''s collection is not with the '
  'client (paid_on null) while the run''s own collection stays paid; a later run paying the re-queued item settles it');

-- (i) (review round 2; switch on) Durand's run cancelled after download (E released), its payout U executed late (its
-- P paid E); Y holds E (40 000), F (25 000) and U's −40 000 row (net 25 000), its payout debited today; then U comes back
-- (+40 000 re-queued). Y's payout paid F; E was paid by U, which came back: E's paid_on null (returned_via « unplanned »:
-- what came back was the payout outside any run, not Y's), F paid by Y, Y's own settlement « paid »; once Z pays the
-- re-queued +40 000, E is paid on Z's debit
create or replace function pg_temp.s17i() returns jsonb language plpgsql as $$
declare v_t uuid; v_y uuid; v_z uuid; v_e uuid; b bigint; w jsonb; p jsonb; q jsonb; d date := private.paris_today();
begin
  v_t := pg_temp.late_cancel('a7', '7c', 40000, 'c70');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_t, 'c71'));
  perform pg_temp.pending('a7', '7d', 25000);
  v_y := pg_temp.flight('a7', 'c72');
  perform pg_temp.debit(v_y, 'c73', d);
  w := w || jsonb_build_object(
    'y_lines', (select jsonb_agg(l.kind || ':' || l.amount_minor order by l.kind, l.amount_minor)
                from public.remittance_line l where l.run_id = v_y),
    'y', jsonb_build_array(pg_temp.rstatus(v_y), (select q.net_minor from public.remittance_run q where q.id = v_y)),
    'before', (select jsonb_build_array(x.paid_on = d, x.paid_how, x.paid_run_number = pg_temp.rnum(v_y))
               from private.entry_remitted(pg_temp.alloc('7c')) x));
  w := w || jsonb_build_object('returned', pg_temp.late_return(v_t, 'c74'), 'queue', pg_temp.queue('a7'));
  p := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('7c')));
  q := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('7d')));
  w := w || jsonb_build_object(
    'e', jsonb_build_array(p -> 0 ->> 'run_number' = pg_temp.rnum(v_y), p -> 0 -> 'run_transfer', p -> 0 -> 'paid_on',
                           p -> 0 -> 'paid_how', p -> 0 -> 'paid_run_number', p -> 0 -> 'returned_via'),
    'f', jsonb_build_array(q -> 0 ->> 'run_number' = pg_temp.rnum(v_y), q -> 0 ->> 'paid_on' = d::text,
                           q -> 0 ->> 'paid_how', q -> 0 ->> 'paid_run_number' = pg_temp.rnum(v_y), q -> 0 -> 'returned_via'),
    'y_settled', (select jsonb_build_array(s.on_date = d, s.how, s.run_number = pg_temp.rnum(v_y))
                  from private.run_settled_on(v_y) s),
    'nightly', pg_temp.nightly());
  -- the item's read keyed whatever the statistics: analysed as they stand (a few rows: a scan priced lowest), it scans
  -- none of the tables it reads
  v_e := pg_temp.alloc('7c');
  analyze private.unplanned_paid_item, public.remittance_line, public.remittance_run, public.bank_line_booking,
          public.ledger_entry;
  b := pg_temp.seqs();
  perform x.paid_on from private.entry_remitted(v_e) x;
  w := w || jsonb_build_object('seq_scans', pg_temp.seqs() - b);
  perform pg_temp.reconfirm('a7');
  v_z := pg_temp.flight('a7', 'c75');
  perform pg_temp.debit(v_z, 'c76', d);
  p := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('7c')));
  return w || jsonb_build_object(
    'z', jsonb_build_array(p -> 0 ->> 'paid_on' = d::text, p -> 0 ->> 'paid_how',
                           p -> 0 ->> 'paid_run_number' = pg_temp.rnum(v_z), p -> 0 -> 'returned_via'));
end $$;
select is(pg_temp.iso('s17i', true),
  '{"exec": "ok", "y_lines": ["allocation:25000", "allocation:40000", "unplanned_payout:-40000"],
    "y": ["booked", 25000], "before": [true, "paid", true], "returned": "ok", "queue": ["payout_returned:40000"],
    "e": [true, true, null, null, null, "unplanned"], "f": [true, true, "paid", true, null],
    "y_settled": [true, "paid", true], "nightly": [], "seq_scans": 0, "z": [true, "paid", true, "unplanned"]}'::jsonb,
  '17 (i) (review round 2; switch on): a run debited with its own payout and the −P row of an unplanned payout that '
  'paid one of its collections: once that payout comes back, that collection is not with the client (returned_via '
  '« unplanned »), the run''s other collection stays paid by its payout; a later run paying the re-queued item settles it');


-- §3.3 The worked example's return of 12/11 (design §7.2): P1's return through the job's mode, one transaction ----------
-- E2 (200 000) remitted in RV-1; P6 (300 000) allocated since; P1 returned → R(E2), the cash_out and A1 (adv:<R(E2)>,
-- MAND-a1) at the return date; 4670[Martin] −300 000 (P6 owed in full); the queue P6 +300 000, R(E2) −200 000, A1 +200 000
create or replace function pg_temp.s33() returns jsonb language plpgsql as $$
declare v_r uuid; a public.client_advance; d date := private.paris_today();
begin
  perform pg_temp.remitted('a1', 'e9', 200000, 'be9');
  perform pg_temp.pending('a1', 'ea', 300000, d - 1);
  perform pg_temp.stmt2('be91', d, jsonb_build_array(jsonb_build_object('amount', 200000, 'kind', 'return',
                                                                          'e2e', 'E2E-e9')));
  perform pg_temp.job_returns(jsonb_build_array(jsonb_build_array(pg_temp.l2('be91', 1), 'e9')));
  v_r := pg_temp.rev(pg_temp.alloc('e9'));
  a := pg_temp.adv_of(v_r);
  return (jsonb_build_object(
    'r', jsonb_build_array(pg_temp.edate(v_r) = d, pg_temp.books(v_r) -> 'client_payable'),
    'a1', jsonb_build_array(pg_temp.ekey(a.entry_id) = 'adv:' || v_r, pg_temp.edate(a.entry_id) = d,
                            a.mandate_id = pg_temp.mandate('a1'), pg_temp.books(a.entry_id)),
    'owed', pg_temp.owed('a1'), 'queue', pg_temp.queue('a1'), 'due_to_servicer', pg_temp.bal('due_to_servicer', null, d),
    'cash_out', (select count(*) from public.ledger_entry where idempotency_key = 'cash_out:' || pg_temp.l2('be91', 1))))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s33'),
  '{"r": [true, 200000],
    "a1": [true, true, true, {"due_to_servicer": 200000, "client_payable": -200000, "client_advance_receivable": 200000,
                              "due_from_client_funds": -200000}],
    "owed": -300000, "queue": ["allocation:300000", "allocation_reversal:-200000", "client_advance:200000"],
    "due_to_servicer": 200000, "cash_out": 1, "nightly": []}'::jsonb,
  '§3.3: P1''s return of 12/11 through the debit job — R(E2), the cash_out and A1 in one transaction; P6 owed in full');


-- The switch is still off (no M2c-7 migration writes it) --------------------------------------------------------------------
select is(private.switch_on('downloaded_file_cancellation'), false,
  'the cancellation-after-download switch is still off');

select * from finish();
rollback;
