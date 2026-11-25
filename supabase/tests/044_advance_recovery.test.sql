-- M2c-7b « claw-back and write-off » (plan docs/design/m2c-7-plan.md §4; design §7.2, §9.6, §13; ADR-0014 « M2c-7b »).
-- An advance of the servicer (client_advance) is open for its amount less its settlements (every kind), 0 once its entry
-- is reversed; it belongs to its mandate (set at insert, 7a), is clawed back by a run's settlement plan under that
-- mandate's claw-back clause, or passed as a loss by an admin with its evidence:
--   a     private.advance_open / document_open / advance_mandate / advance_born_on: fresh, after a compensation, a
--         write-off, a reversal; an unknown id;
--   b     advance_mandate: a one-mandate run's overrun on its mandate; a run of two mandates and a client part with no
--         transfer (S13) on none;
--   c     the approval sent back documents_changed when the advance it plans to take was written off since the prepare;
--   d     (switch off, then on) a double_payout advance taken by an approved run: its unplanned return refused
--         advance_in_flight (and its write-off in_flight), nothing booked; the run's debit posts the settlement
--         (compensation, −4112 Da); the return then refused advance_settled;
--   e     (switch on) the same for a remitted_reversal cover's release;
--   f     write_off_advance: roles (admin at aal2 only), amount rules, compare and set, evidence, reason, the posting
--         (+6780 / −4112[c], its document the evidence, key awo:…), its settlement, replay, the rest, not_open, LG003, the
--         entry type's label, I18 clean;
--   g     the settlement guard (beyond its amount, at its amount, in two statements, another client, not an advance,
--         a reversed advance);
--   h     public.client_advances (money staff; rows, recovery, in-flight run, totals, paging), public.client_space_advances
--         (the client's whole-client members), the recovery on the « Désimputer » read and on the run page, the nightly's
--         advance_open recovery detail and the full list of codes;
--   i     the evidence kind advance_write_off_evidence: registered by money staff, read (row and file) by money staff only;
--   j     the remittance line insert guard: an advance item's line carries its advance's mandate (none with none);
--   k     (7a round 3 carry-over; switch on) an item an unplanned payout paid in full, its run's own payout back, then that
--         unplanned payout back too: returned_via « unplanned » while the money waits and once a later run pays it;
--   l     (review round 1) a double payout's or an overrun's advance row carries no mandate (only a cover's does);
--   m     (review round 1) an advance born before the client's proceeding is barred_proceeding on every read;
--         (review round 2) « Avances » and the client space date it by its birth (born_on), the date that rule reads —
--         before the opening — and never by its recording only (created_on, after it);
--   n     (review round 1) the write-off refused in_flight names the run in its detail.
-- The cancellation-after-download switch stays off: every switch-on case runs in its own rolled-back scenario
-- (pg_temp.iso(…, true)); a guard at the end checks it is off.
begin;
select plan(18);



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

-- The base: the account's cash (an unidentified payment of 10 000,00 €) and its statement of yesterday
select pg_temp.collect('13', 1000000, private.paris_today() - 6, false);
select pg_temp.stmt('00', private.paris_today() - 1);


-- a. What is open of an advance (4.1.1–4.1.4) ----------------------------------------------------------------------------
-- Martin's collection (100 000) remitted (debited d − 2), « Désimputer » → its cover A (on the line's mandate, dated at
-- the payout); a compensation of 30 000 (planted: a run's settlement row), a write-off of 20 000, then a raw reversal of
-- A's entry (never committed: I23 would refuse it)
create or replace function pg_temp.sa() returns jsonb language plpgsql as $$
declare a public.client_advance; w jsonb; d date := private.paris_today();
begin
  perform pg_temp.remitted('a1', '10', 100000, '100', d - 2, d - 3);
  perform pg_temp.unalloc('10');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('10')));
  w := jsonb_build_object('fresh', jsonb_build_array(
         private.advance_open(a.id), private.document_open(a.id), private.advance_mandate(a.id) = pg_temp.mandate('a1'),
         private.advance_born_on(a.id) = pg_temp.edate(a.entry_id), private.advance_born_on(a.id) = d - 2));
  perform pg_temp.plant_settlement(a.id, 30000);
  w := w || jsonb_build_object('compensated', jsonb_build_array(private.advance_open(a.id), private.document_open(a.id)));
  w := w || jsonb_build_object('write_off', pg_temp.wo('wo-a', a.id, '200,00', '70000') ->> 'open_after_minor');
  w := w || jsonb_build_object('written', jsonb_build_array(private.advance_open(a.id), private.document_open(a.id)));
  perform private.ledger_reverse(a.entry_id, 'raw-adv-a', 'Retour (test)', d);
  return w || jsonb_build_object(
    'reversed', jsonb_build_array(private.advance_open(a.id), private.document_open(a.id)),
    'unknown', jsonb_build_array(private.advance_open(gen_random_uuid()), private.document_open(gen_random_uuid()),
                                 private.advance_mandate(gen_random_uuid()), private.advance_born_on(gen_random_uuid())));
end $$;
select is(pg_temp.iso('sa'),
  '{"fresh": [100000, 100000, true, true, true], "compensated": [70000, 70000], "write_off": "50000",
    "written": [50000, 50000], "reversed": [0, 0], "unknown": [null, null, null, null]}'::jsonb,
  'a: an advance is open for its amount less every settlement (compensation, write-off), 0 once its entry is reversed; '
  'document_open reads it; its mandate the line''s; born on its entry''s date (the payout''s)');


-- b. The mandate of an advance (4.1.2) -----------------------------------------------------------------------------------
-- a one-mandate run's overrun (a forged 4670 debit before its booking) on that mandate; a run of two mandates' overrun on
-- none; a client part with no transfer (S13: a debit to Cyprès' payout IBAN matching nothing of ours) on none
create or replace function pg_temp.sb() returns jsonb language plpgsql as $$
declare v_run uuid; w jsonb; d date := private.paris_today();
begin
  perform pg_temp.pending('a1', '20', 100000);
  v_run := pg_temp.flight('a1', 'pb0');
  perform pg_temp.handed_out('file-b0', 'gen-file-b0');
  perform pg_temp.forge('a1', 3000, 'b0');
  perform pg_temp.debit(v_run, 'b0');
  perform pg_temp.second_mandate('a9');
  perform pg_temp.pending('a9', '21', 50000);
  perform pg_temp.file('22', pg_temp.pf2('a9'), 60000);
  perform pg_temp.collect('22', 60000, d - 3);
  v_run := pg_temp.flight('a9', 'pb1');
  perform pg_temp.handed_out('file-b1', 'gen-file-b1');
  perform pg_temp.forge('a9', 4000, 'b1');
  perform pg_temp.debit(v_run, 'b1');
  perform pg_temp.stmt2('b2', d, jsonb_build_array(jsonb_build_object('amount', 5000, 'kind', 'other_debit',
                                                                      'iban', pg_temp.iban('a3'))));
  w := jsonb_build_object('s13', pg_temp.bkx(pg_temp.l2('b2', 1), pg_temp.prop(pg_temp.l2('b2', 1))));
  return w || jsonb_build_object('mandates', (
    select jsonb_agg(jsonb_build_array(right(a.client_organization_id::text, 2), a.cause, a.amount_minor,
                                       private.advance_mandate(a.id) is not distinct from a.mandate_id,
                                       coalesce(right(private.advance_mandate(a.id)::text, 2), 'none'))
                     order by a.client_organization_id, a.cause)
    from public.client_advance a where a.organization_id = '00000000-0000-0000-0000-0000000000aa'));
end $$;
select is(pg_temp.iso('sb'),
  '{"s13": "ok", "mandates": [["a1", "payout_overrun", 3000, true, "a1"], ["a3", "double_payout", 5000, true, "none"],
                               ["a9", "payout_overrun", 4000, true, "none"]]}'::jsonb,
  'b: an advance''s mandate is the one set at its insert — a one-mandate run''s; none for a run of two mandates or a '
  'client part with no transfer (repayment request only)');


-- c. The approval re-checks a planned advance settle (4.1.4) -----------------------------------------------------------
-- Martin's cover A (100 000) planned by the next run (its whole queue, A taken); a write-off of 10 000 between the
-- prepare and the approval → back to draft, documents_changed
create or replace function pg_temp.sc() returns jsonb language plpgsql as $$
declare v_run uuid; a public.client_advance; w jsonb; d date := private.paris_today();
begin
  perform pg_temp.remitted('a1', '30', 100000, '300', d - 2, d - 3);
  perform pg_temp.unalloc('30');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('30')));
  perform pg_temp.pending('a1', '31', 150000);
  v_run := pg_temp.request('a1', 'run-044-pc');
  perform pg_temp.prepare_adv(v_run, jsonb_build_array(jsonb_build_array(a.id, 100000)));
  perform pg_temp.wo('wo-c', a.id, '100,00', '100000');
  w := jsonb_build_object('approval', pg_temp.approve_plain(v_run, 'run-044-pc'));
  return w || jsonb_build_object('reason', (select last_failure ->> 'code' from public.remittance_run where id = v_run),
                                 'open', private.advance_open(a.id));
end $$;
select is(pg_temp.iso('sc'),
  '{"approval": "back_to_draft:draft", "reason": "documents_changed", "open": 90000}'::jsonb,
  'c: an advance written off between the prepare and the approval sends the run back (documents_changed)');


-- d. A double payout's advance taken by an approved run (4.1.10, [critic] M7-MONEY-2, F2) ------------------------------
-- Roux's X (50 000) debited d − 3, its payout returned d − 2 (re-queued), paid again by Y (debited d − 1); the bank then
-- executes X's payout again (S03r: nothing pending, the advance all of it, on X's mandate); Z takes it back (its plan),
-- approved: the unplanned return refused advance_in_flight, nothing booked, the write-off refused in_flight; Z's debit
-- posts the settlement (compensation, −4112 Da); the same return then refused advance_settled
create or replace function pg_temp.sd() returns jsonb language plpgsql as $$
declare v_x uuid; v_t uuid; v_y uuid; v_z uuid; a public.client_advance; w jsonb; v_parts jsonb;
        d date := private.paris_today();
begin
  v_x := pg_temp.remitted('a5', '40', 50000, '400', d - 3, d - 4);
  v_t := pg_temp.rtransfer(v_x);
  perform pg_temp.bounce(v_x, '401', d - 2);
  perform pg_temp.reconfirm('a5');
  v_y := pg_temp.flight('a5', 'pd');
  perform pg_temp.debit(v_y, '402', d - 1);
  w := jsonb_build_object('exec', pg_temp.late_exec(v_t, '403'));
  a := (select x from public.client_advance x where x.client_organization_id = pg_temp.c('a5') and x.cause = 'double_payout');
  w := w || jsonb_build_object('advance', jsonb_build_array(a.amount_minor, a.mandate_id = pg_temp.mandate('a5')));
  perform pg_temp.pending('a5', '41', 80000);
  v_z := pg_temp.request('a5', 'run-044-pd2');
  perform pg_temp.prepare_adv(v_z, jsonb_build_array(jsonb_build_array(a.id, a.amount_minor)));
  w := w || jsonb_build_object('approval', pg_temp.approve_plain(v_z, 'run-044-pd2'));
  w := w || jsonb_build_object('in_flight', (select x.run_id = v_z from private.advance_in_flight_run(a.id) x),
                               'write_off', pg_temp.wo('wo-d', a.id, '10,00', a.amount_minor::text) ->> 'error');
  -- U's return (T back today), as the sheet sends it: its part returns U's line
  perform pg_temp.stmt2('404', d, jsonb_build_array(jsonb_build_object(
    'dir', 'credit', 'kind', 'return', 'amount', 50000, 'orig', pg_temp.e2e(v_t))));
  v_parts := jsonb_build_array(pg_temp.pt('unplanned_payout_returned', v_t, 50000, null, pg_temp.l2('403', 1)));
  w := w || jsonb_build_object('why', pg_temp.why(pg_temp.l2('404', 1), v_parts));
  w := w || jsonb_build_object('returned', pg_temp.bkx(pg_temp.l2('404', 1), v_parts));
  w := w || jsonb_build_object('bookings', pg_temp.bookings(pg_temp.l2('404', 1)), 'live', pg_temp.live_advs('a5'));
  perform pg_temp.debit(v_z, '405', d);
  w := w || jsonb_build_object(
    'z', pg_temp.rstatus(v_z),
    'settlement', (select jsonb_agg(jsonb_build_array(s.document_kind, s.kind, s.amount_minor, s.settled_on = d,
                                                      s.run_id = v_z))
                   from public.commission_settlement s where s.document_id = a.id),
    'books', pg_temp.books(pg_temp.ek('settle:' || v_z)), 'open', private.advance_open(a.id));
  w := w || jsonb_build_object('again', pg_temp.bkx(pg_temp.l2('404', 1), v_parts));
  w := w || jsonb_build_object('bookings_then', pg_temp.bookings(pg_temp.l2('404', 1)));
  return w || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('sd'),
  '{"exec": "ok", "advance": [50000, true], "approval": "approved:approved", "in_flight": true,
    "write_off": "advance write-off refused: in_flight", "why": "advance_in_flight", "returned": "advance_in_flight",
    "bookings": [],
    "live": ["double_payout:50000"], "z": "booked", "settlement": [["advance", "compensation", 50000, true, true]],
    "books": {"client_payable": 50000, "due_to_servicer": -50000, "due_from_client_funds": 50000,
              "client_advance_receivable": -50000},
    "open": 0, "again": "advance_settled", "bookings_then": [], "nightly": []}'::jsonb,
  'd (switch off): a double payout''s advance an approved run takes back — its unplanned return refused advance_in_flight '
  'and its write-off in_flight; the run''s debit posts the settlement (−4112 Da); the return then advance_settled');
select is(pg_temp.iso('sd', true),
  '{"exec": "ok", "advance": [50000, true], "approval": "approved:approved", "in_flight": true,
    "write_off": "advance write-off refused: in_flight", "why": "advance_in_flight", "returned": "advance_in_flight",
    "bookings": [],
    "live": ["double_payout:50000"], "z": "booked", "settlement": [["advance", "compensation", 50000, true, true]],
    "books": {"client_payable": 50000, "due_to_servicer": -50000, "due_from_client_funds": 50000,
              "client_advance_receivable": -50000},
    "open": 0, "again": "advance_settled", "bookings_then": [], "nightly": []}'::jsonb,
  'd (switch on): the same');


-- e (switch on). A remitted_reversal cover's release while a run takes it back (§3.2.8 with 7b's plans) ------------------
-- Lambert's run cancelled after download (E 40 000 released), its payout U executed late (its P paid E); E reversed → its
-- cover (T = the attribution); Y takes the cover back (its plan), approved: U's return refused advance_in_flight; Y's
-- debit settles the cover; U's return then refused advance_settled
create or replace function pg_temp.se() returns jsonb language plpgsql as $$
declare v_x uuid; v_y uuid; a public.client_advance; w jsonb; d date := private.paris_today();
begin
  v_x := pg_temp.late_cancel('a4', '50', 40000, '500');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, '501'));
  perform pg_temp.unalloc('50');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('50')));
  perform pg_temp.pending('a4', '51', 60000);
  v_y := pg_temp.request('a4', 'run-044-pe');
  perform pg_temp.prepare_adv(v_y, jsonb_build_array(jsonb_build_array(a.id, 40000)));
  w := w || jsonb_build_object('approval', pg_temp.approve_plain(v_y, 'run-044-pe'));
  w := w || jsonb_build_object('returned', pg_temp.late_return(v_x, '502'));
  w := w || jsonb_build_object('bookings', pg_temp.bookings(pg_temp.l2('502', 1)), 'live', pg_temp.live_advs('a4'));
  perform pg_temp.debit(v_y, '503', d);
  return w || jsonb_build_object(
    'y', pg_temp.rstatus(v_y), 'open', private.advance_open(a.id))
         || jsonb_build_object('again', pg_temp.bkx(pg_temp.l2('502', 1), pg_temp.prop(pg_temp.l2('502', 1))))
         || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('se', true),
  '{"exec": "ok", "approval": "approved:approved", "returned": "advance_in_flight", "bookings": [],
    "live": ["remitted_reversal:40000"], "y": "booked", "open": 0, "again": "advance_settled", "nightly": []}'::jsonb,
  'e (switch on): a remitted reversal''s cover a run takes back is never released under it (advance_in_flight), then '
  'settled at its debit (advance_settled)');


-- f. « Passer en perte » (4.1.6) ---------------------------------------------------------------------------------------------
create or replace function pg_temp.sf() returns jsonb language plpgsql as $$
declare a public.client_advance; w jsonb; r jsonb; d date := private.paris_today(); v_e uuid;
begin
  perform pg_temp.remitted('a1', '60', 100000, '600', d - 2, d - 3);
  perform pg_temp.unalloc('60');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('60')));
  w := jsonb_build_object(
    'ops_manager', pg_temp.wo('wo-1', a.id, '10,00', '100000', p_user => '01') ->> 'error',
    'aal1', pg_temp.wo('wo-2', a.id, '10,00', '100000', p_aal => 'aal1') ->> 'error',
    'other_servicer', pg_temp.wo('wo-3', a.id, '10,00', '100000', p_user => '06') ->> 'error',
    'bad', jsonb_build_array(pg_temp.wo('wo-4', a.id, 'abc', '100000') ->> 'error',
                             pg_temp.wo('wo-5', a.id, '0', '100000') ->> 'error',
                             pg_temp.wo('wo-6', a.id, '1,234', '100000') ->> 'error',
                             pg_temp.wo('wo-6b', a.id, '-5', '100000') ->> 'error',
                             pg_temp.wo('wo-6c', a.id, '10,00', 'x') ->> 'error'),
    'changed', pg_temp.wo('wo-7', a.id, '10,00', '99999') ->> 'error',
    'exceeds', pg_temp.wo('wo-8', a.id, '1000,01', '100000') ->> 'error',
    'no_evidence', pg_temp.wo('wo-9', a.id, '10,00', '100000', p_evidence => null) ->> 'error',
    'wrong_kind', pg_temp.wo('wo-10', a.id, '10,00', '100000',
                             p_evidence => 'd0000000-0000-0000-0000-0000000002a1') ->> 'error',
    'other_client', pg_temp.wo('wo-11', a.id, '10,00', '100000',
                               p_evidence => 'd0000000-0000-0000-0000-0000000003a2') ->> 'error',
    'no_reason', pg_temp.wo('wo-12', a.id, '10,00', '100000', p_reason => ' ') ->> 'error',
    'none_written', (select count(*) from public.commission_settlement s where s.document_id = a.id));
  r := pg_temp.wo('wo-13', a.id, '200,00', '100000');
  v_e := (r ->> 'entry_id')::uuid;
  w := w || jsonb_build_object(
    'partial', r ->> 'open_after_minor',
    'entry', (select jsonb_build_array(e.entry_type, e.effective_date = d, e.source_type,
                                       e.source_id = 'd0000000-0000-0000-0000-0000000003a1',
                                       e.client_organization_id = pg_temp.c('a1'),
                                       e.reason = 'Avance passée en perte (décision du ' || to_char(d, 'DD/MM/YYYY') || ')',
                                       e.idempotency_key = 'awo:' || md5('woff-044-wo-13'))
              from public.ledger_entry e where e.id = v_e),
    'books', pg_temp.books(v_e),
    'settlement', (select jsonb_agg(jsonb_build_array(s.document_kind, s.kind, s.amount_minor, s.vat_moved_minor,
                                                      s.entry_id = v_e, s.settled_on = d, s.run_id is null))
                   from public.commission_settlement s where s.document_id = a.id),
    'replay', pg_temp.wo('wo-13', a.id, '200,00', '100000') = r,
    'entries', (select count(*) from public.ledger_entry e
                where e.organization_id = '00000000-0000-0000-0000-0000000000aa' and e.entry_type = 'advance_write_off'));
  w := w || jsonb_build_object(
    'rest', pg_temp.wo('wo-14', a.id, '800,00', '80000') ->> 'open_after_minor',
    'not_open', pg_temp.wo('wo-15', a.id, '1,00', '0') ->> 'error',
    'lg003', pg_temp.state(format('select private.ledger_reverse(%L, ''raw-test-wo-044'', ''Retour (test)'', %L)', v_e, d)),
    'label', (select t.label_fr from public.ledger_entry_type t where t.code = 'advance_write_off'),
    'receivable', pg_temp.bal('client_advance_receivable', 'a1', d), 'losses', pg_temp.bal('servicer_losses', null, d));
  return w || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('sf'),
  '{"ops_manager": "not allowed", "aal1": "not allowed", "other_servicer": "not allowed",
    "bad": ["advance write-off refused: bad_amount", "advance write-off refused: bad_amount",
            "advance write-off refused: bad_amount", "advance write-off refused: bad_amount",
            "advance write-off refused: bad_request"],
    "changed": "advance write-off refused: open_changed", "exceeds": "advance write-off refused: amount_exceeds_open",
    "no_evidence": "advance write-off refused: evidence_required",
    "wrong_kind": "advance write-off refused: evidence_required",
    "other_client": "advance write-off refused: evidence_required",
    "no_reason": "advance write-off refused: reason_required", "none_written": 0,
    "partial": "80000", "entry": ["advance_write_off", true, "document", true, true, true, true],
    "books": {"servicer_losses": 20000, "client_advance_receivable": -20000},
    "settlement": [["advance", "write_off", 20000, 0, true, true, true]], "replay": true, "entries": 1,
    "rest": "0", "not_open": "advance write-off refused: not_open", "lg003": "LG003", "label": "Avance passée en perte",
    "receivable": 0, "losses": 100000, "nightly": []}'::jsonb,
  'f: « Passer en perte » — an admin at aal2 only; the amount in euros, within what is open, the open the page showed; '
  'its evidence of that client; +6780 / −4112[c] (its document the evidence), a write_off settlement; replayed; never '
  'reversed (LG003); I18 clean');


-- g. The settlement guard (4.1.5) -----------------------------------------------------------------------------------------
create or replace function pg_temp.sg() returns jsonb language plpgsql as $$
declare a public.client_advance; b public.client_advance; w jsonb; d date := private.paris_today();
  ins text := 'insert into public.commission_settlement (organization_id, client_organization_id, document_kind, '
              'document_id, kind, amount_minor, settled_on) values ';
begin
  perform pg_temp.remitted('a1', '70', 100000, '700', d - 2, d - 3);
  perform pg_temp.unalloc('70');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('70')));
  perform pg_temp.remitted('a2', '71', 50000, '701', d - 2, d - 3);
  perform pg_temp.unalloc('71');
  b := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('71')));
  w := jsonb_build_object(
    'beyond', pg_temp.attempt(ins || format('(%L, %L, ''advance'', %L, ''compensation'', 100001, %L) returning 1',
                                            a.organization_id, a.client_organization_id, a.id, d)),
    'exact', pg_temp.attempt(ins || format('(%L, %L, ''advance'', %L, ''compensation'', 100000, %L) returning 1',
                                           a.organization_id, a.client_organization_id, a.id, d)),
    'one_statement', pg_temp.attempt(ins || format('(%L, %L, ''advance'', %L, ''compensation'', 60000, %L), '
                                                   '(%L, %L, ''advance'', %L, ''write_off'', 40001, %L) returning 1',
                                                   a.organization_id, a.client_organization_id, a.id, d,
                                                   a.organization_id, a.client_organization_id, a.id, d)),
    'other_client', pg_temp.attempt(ins || format('(%L, %L, ''advance'', %L, ''compensation'', 1000, %L) returning 1',
                                                  a.organization_id, b.client_organization_id, a.id, d)),
    'not_an_advance', pg_temp.attempt(ins || format('(%L, %L, ''advance'', %L, ''compensation'', 1000, %L) returning 1',
                                                    a.organization_id, a.client_organization_id, a.entry_id, d)),
    'invoice', pg_temp.attempt(ins || format('(%L, %L, ''invoice'', %L, ''compensation'', 1000, %L) returning 1',
                                             a.organization_id, a.client_organization_id, gen_random_uuid(), d)));
  -- in two statements: 60 000, then 40 001 more
  perform pg_temp.plant_settlement(a.id, 60000);
  w := w || jsonb_build_object('two_statements', pg_temp.attempt(ins || format(
    '(%L, %L, ''advance'', %L, ''compensation'', 40001, %L) returning 1', a.organization_id, a.client_organization_id,
    a.id, d)));
  -- an advance whose entry is reversed (raw, never committed)
  perform private.ledger_reverse(b.entry_id, 'raw-test-g-044', 'Retour (test)', d);
  return w || jsonb_build_object('reversed', pg_temp.attempt(ins || format(
    '(%L, %L, ''advance'', %L, ''compensation'', 1000, %L) returning 1', b.organization_id, b.client_organization_id,
    b.id, d)));
end $$;
select is(pg_temp.iso('sg'),
  '{"beyond": "commission settlement: an advance settled beyond its amount", "exact": "1",
    "one_statement": "commission settlement: an advance settled beyond its amount",
    "two_statements": "commission settlement: an advance settled beyond its amount",
    "other_client": "commission settlement: not an advance of its client, or its advance reversed",
    "not_an_advance": "commission settlement: not an advance of its client, or its advance reversed",
    "reversed": "commission settlement: not an advance of its client, or its advance reversed", "invoice": "1"}'::jsonb,
  'g: an advance is never settled beyond its amount (one statement or two), for another client, nor once reversed; '
  'other documents are not this guard''s');


-- h. The « Avances » page, the client space, the recovery (4.1.7, 4.1.8) ------------------------------------------------
-- Petit: cover A (100 000; no claw-back clause: a request) and cover B (30 000) written off in full; Martin under a
-- claw-back clause (art. 7.4): cover C (50 000), 20 000 of it taken by an approved run
create or replace function pg_temp.sh() returns jsonb language plpgsql as $$
declare a public.client_advance; b public.client_advance; c public.client_advance; v_y uuid; v_ra uuid; v_rc uuid;
        r jsonb; r2 jsonb; w jsonb; v_chk uuid; d date := private.paris_today();
begin
  v_ra := pg_temp.remitted('a8', '80', 100000, '800', d - 2, d - 3);
  perform pg_temp.unalloc('80');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('80')));
  perform pg_temp.remitted('a8', '81', 30000, '801', d - 2, d - 3);
  perform pg_temp.unalloc('81');
  b := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('81')));
  perform pg_temp.wo('wo-h', b.id, '300,00', '30000', p_evidence => 'd0000000-0000-0000-0000-0000000003a8');
  perform pg_temp.clawback('a1', 'art. 7.4');
  v_rc := pg_temp.remitted('a1', '82', 50000, '802', d - 2, d - 3);
  -- the « Désimputer » read says how the cover it would post is recovered
  w := jsonb_build_object('desimputer', (select jsonb_build_array(x ->> 'recovery', x ->> 'clause_ref')
                                          from jsonb_array_elements(pg_temp.read_as('01', format(
                                            'select public.allocation_remitted(%L)', pg_temp.pay('82')))) x));
  perform pg_temp.unalloc('82');
  c := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('82')));
  perform pg_temp.pending('a1', '83', 90000);
  v_y := pg_temp.request('a1', 'run-044-ph');
  perform pg_temp.prepare_adv(v_y, jsonb_build_array(jsonb_build_array(c.id, 20000)));
  perform pg_temp.approve_plain(v_y, 'run-044-ph');
  r := pg_temp.read_as('01', 'select public.client_advances(''00000000-0000-0000-0000-0000000000aa'')');
  w := w || jsonb_build_object(
    'rows', (select jsonb_agg(jsonb_build_array(x ->> 'client_name', x ->> 'cause', x ->> 'amount_minor', x ->> 'open_minor',
                                                x -> 'recovered' ->> 'compensation', x -> 'recovered' ->> 'write_off',
                                                x ->> 'recovery', x ->> 'clause_ref', x ->> 'mandate_reference',
                                                x -> 'in_flight_run' ->> 'number' = pg_temp.rnum(v_y), x ->> 'file_ref',
                                                x ->> 'created_on' = d::text, x ->> 'cause_on' = d::text)
                              order by ord)
             from jsonb_array_elements(r -> 'rows') with ordinality y (x, ord)),
    'totals', (select jsonb_agg(jsonb_build_array(right(x ->> 'client_id', 2), x ->> 'currency', x ->> 'open_minor')
                                order by x ->> 'client_id')
               from jsonb_array_elements(r -> 'totals') x),
    'can_write_off', r -> 'can_write_off', 'admin_can', pg_temp.read_as('04', 'select public.client_advances('
                                                       '''00000000-0000-0000-0000-0000000000aa'')') -> 'can_write_off');
  -- paging over every advance (open or not), newest first: one, then the two after it
  r := pg_temp.read_as('01', 'select public.client_advances(''00000000-0000-0000-0000-0000000000aa'', null, false, null, 1)');
  r2 := pg_temp.read_as('01', format('select public.client_advances(''00000000-0000-0000-0000-0000000000aa'', null, false, '
                                     '%L::jsonb, 2)', r -> 'next'));
  w := w || jsonb_build_object(
    'page1', (select jsonb_agg((x ->> 'advance_id')::uuid = c.id) from jsonb_array_elements(r -> 'rows') x),
    'page2', (select jsonb_agg(x ->> 'advance_id' order by ord) from jsonb_array_elements(r2 -> 'rows') with ordinality y (x, ord))
             = jsonb_build_array(b.id, a.id),
    'page2_next', r2 -> 'next',
    'one_client', (select jsonb_agg(x ->> 'client_name') from jsonb_array_elements(pg_temp.read_as('01', format(
                     'select public.client_advances(''00000000-0000-0000-0000-0000000000aa'', %L)', pg_temp.c('a8')))
                     -> 'rows') x),
    'roles', jsonb_build_array(
      pg_temp.read_as('02', 'select public.client_advances(''00000000-0000-0000-0000-0000000000aa'')') ->> 'error',
      pg_temp.read_as('03', 'select public.client_advances(''00000000-0000-0000-0000-0000000000aa'')') ->> 'error',
      pg_temp.read_as('05', 'select public.client_advances(''00000000-0000-0000-0000-0000000000aa'')') ->> 'error',
      pg_temp.read_as('01', 'select public.client_advances(''00000000-0000-0000-0000-0000000000aa'')', 'aal1') ->> 'error'));
  -- the client space: the whole-client members of Petit read its open advances, how they are recovered
  r := pg_temp.read_as('03', format('select public.client_space_advances(%L)', pg_temp.c('a8')));
  w := w || jsonb_build_object(
    'space', (select jsonb_agg(jsonb_build_array(x ->> 'cause', x ->> 'open_minor', x ->> 'recovery', x ->> 'clause_ref',
                                                 x ->> 'created_on' = d::text))
              from jsonb_array_elements(r -> 'rows') x),
    'space_total', r -> 'total',
    'space_martin', (select jsonb_agg(jsonb_build_array(x ->> 'open_minor', x ->> 'recovery', x ->> 'clause_ref'))
                     from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_space_advances(%L)',
                                                                             pg_temp.c('a1'))) -> 'rows') x),
    'space_roles', jsonb_build_array(
      pg_temp.read_as('07', format('select public.client_space_advances(%L)', pg_temp.c('a8'))) ->> 'error',
      pg_temp.read_as('08', format('select public.client_space_advances(%L)', pg_temp.c('a8'))) ->> 'error',
      pg_temp.read_as('03', format('select public.client_space_advances(%L)', pg_temp.c('a1'))) ->> 'error',
      pg_temp.read_as('02', format('select public.client_space_advances(%L)', pg_temp.c('a8'))) ->> 'error'));
  -- the run pages: the advance recorded at each payout, with how it is recovered
  w := w || jsonb_build_object(
    'run_pages', jsonb_build_array(
      (select jsonb_agg(jsonb_build_array(x ->> 'cause', x ->> 'recovery', x ->> 'clause_ref', x ->> 'open_minor',
                                          x ->> 'written_off_minor'))
       from jsonb_array_elements(pg_temp.read_as('01', format('select public.remittance_run_payout(%L)', v_ra))
                                 -> 'advances') x),
      (select jsonb_agg(jsonb_build_array(x ->> 'cause', x ->> 'recovery', x ->> 'clause_ref', x ->> 'open_minor',
                                          x ->> 'written_off_minor'))
       from jsonb_array_elements(pg_temp.read_as('01', format('select public.remittance_run_payout(%L)', v_rc))
                                 -> 'advances') x)));
  -- the nightly 31 days on: advance_open with how each advance is recovered (the written-off one is not open)
  v_chk := pg_temp.adv_run(d + 31, true);
  return w || jsonb_build_object(
    'nightly', (select jsonb_agg(jsonb_build_array(x.amount_minor, x.details ->> 'recovery') order by x.amount_minor)
                from public.payment_check_result x where x.run_id = v_chk and x.code = 'advance_open'),
    'codes', (select jsonb_agg(distinct x.code order by x.code) from public.payment_check_result x where x.run_id = v_chk));
end $$;
select is(pg_temp.iso('sh'),
  '{"desimputer": ["clawback", "art. 7.4"],
    "rows": [["Martin SAS", "remitted_reversal", "50000", "50000", "0", "0", "clawback", "art. 7.4", "MAND-a1", true, "D-82",
              true, true],
             ["Petit SAS", "remitted_reversal", "100000", "100000", "0", "0", "request", null, "MAND-a8", null, "D-80",
              true, true]],
    "totals": [["a1", "EUR", "50000"], ["a8", "EUR", "100000"]], "can_write_off": false, "admin_can": true,
    "page1": [true], "page2": true, "page2_next": null, "one_client": ["Petit SAS"],
    "roles": ["not allowed", "not allowed", "not allowed", "not allowed"],
    "space": [["remitted_reversal", "100000", "request", null, true]], "space_total": [{"currency": "EUR", "open_minor": "100000"}],
    "space_martin": [["50000", "clawback", "art. 7.4"]],
    "space_roles": ["not allowed", "not allowed", "not allowed", "not allowed"],
    "run_pages": [[["remitted_reversal", "request", null, "100000", "0"]],
                  [["remitted_reversal", "clawback", "art. 7.4", "50000", "0"]]],
    "nightly": [[50000, "clawback"], [100000, "request"]],
    "codes": ["advance_open"]}'::jsonb,
  'h: « Avances » (money staff; open advances newest first, how each is recovered, the run taking it back, totals per '
  'client, paged), the client space (whole-client members, open advances only), the recovery on « Désimputer », on the '
  'run page and on the nightly''s advance_open');

-- (F12) the full list of codes run_advance_checks emits (unchanged by 7b: 043 #33's)
create or replace function pg_temp.sk() returns jsonb language plpgsql as $$
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
select is(pg_temp.iso('sk'), '["advance_ledger", "advance_open", "remitted_reversal_uncovered"]'::jsonb,
  'h (F12): run_advance_checks emits exactly advance_ledger, advance_open, remitted_reversal_uncovered');


-- i. The evidence kind (4.1.11) ---------------------------------------------------------------------------------------------
-- registered by an ops manager for Petit (its file at a client key of Petit); its row and its file read by money staff
-- only: never by Petit's administrator, its restricted viewer, a collector, another servicer's staff or another client
create or replace function pg_temp.si() returns jsonb language plpgsql as $$
declare v_name text := 'client/00000000-0000-0000-0000-0000000000aa/00000000-0000-0000-0000-0000000000a8/'
                       || gen_random_uuid() || '.pdf';
        v_ret jsonb; v_doc uuid;
begin
  insert into storage.objects (bucket_id, name) values ('documents', v_name);
  v_ret := pg_temp.read_as('01', format('select public.register_client_document(%L, %L, %L, %L, %L, %L, %L)', 'reg-044-i',
                                        pg_temp.c('a8'), 'advance_write_off_evidence', v_name, 'decision.pdf',
                                        repeat('b', 64), 'application/pdf'));
  v_doc := (v_ret ->> 'document_id')::uuid;
  return jsonb_build_object(
    'registered', (select d.kind from public.document d where d.id = v_doc),
    'rows', (select jsonb_object_agg(u, pg_temp.try(u, format('select count(*) from public.document where id = %L', v_doc)))
             from unnest(array['01', '04', '02', '03', '07', '05', '08']) u),
    'objects', (select jsonb_object_agg(u, pg_temp.try(u, format('select count(*) from storage.objects where name = %L',
                                                                 v_name)))
                from unnest(array['01', '04', '02', '03', '07', '05']) u),
    'fixture_rows', (select jsonb_object_agg(u, pg_temp.try(u,
                       'select count(*) from public.document where kind = ''advance_write_off_evidence'''))
                     from unnest(array['01', '03', '08', '07']) u),
    'bad_kind', pg_temp.read_as('01', format('select public.register_client_document(%L, %L, %L, %L, %L, %L, %L)',
                                             'reg-044-i2', pg_temp.c('a8'), 'write_off', v_name, 'decision.pdf',
                                             repeat('b', 64), 'application/pdf')) ->> 'error');
end $$;
select is(pg_temp.iso('si'),
  '{"registered": "advance_write_off_evidence",
    "rows": {"01": "1", "04": "1", "02": "0", "03": "0", "07": "0", "05": "0", "08": "0"},
    "objects": {"01": "1", "04": "1", "02": "0", "03": "0", "07": "0", "05": "0"},
    "fixture_rows": {"01": "4", "03": "0", "08": "0", "07": "0"}, "bad_kind": "document: invalid kind"}'::jsonb,
  'i: the write-off evidence is registered by money staff and read (row and file) by money staff only');


-- j. An advance item's line carries its advance's mandate (4.1.9, [critic] M7-MONEY-7, [check 1]) -------------------------
-- Martin's cover A (on MAND-a1); Cyprès' client part with no transfer (S13, on no mandate) and its raw reversal (its
-- queue item client_advance_reversal); lines planted into a run of each client
create or replace function pg_temp.sj() returns jsonb language plpgsql as $$
declare a public.client_advance; s public.client_advance; v_run uuid; v_run3 uuid; v_rev uuid; d date := private.paris_today();
begin
  v_run := pg_temp.remitted('a1', '90', 100000, '900', d - 2, d - 3);
  perform pg_temp.unalloc('90');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('90')));
  perform pg_temp.pending('a3', '91', 20000);
  v_run3 := pg_temp.flight('a3', 'pj');
  perform pg_temp.stmt2('901', d, jsonb_build_array(jsonb_build_object('amount', 5000, 'kind', 'other_debit',
                                                                       'iban', pg_temp.iban('a3'))));
  perform pg_temp.bkx(pg_temp.l2('901', 1), pg_temp.prop(pg_temp.l2('901', 1)));
  s := (select x from public.client_advance x where x.client_organization_id = pg_temp.c('a3'));
  perform private.ledger_reverse(s.entry_id, 'raw-adv-j', 'Retour (test)', d);
  v_rev := pg_temp.rev(s.entry_id);
  return jsonb_build_object(
    'own', pg_temp.plant_line(v_run, a.entry_id, 'client_advance', 100000, pg_temp.mandate('a1')),
    'other', pg_temp.plant_line(v_run, a.entry_id, 'client_advance', 100000, pg_temp.mandate('a2')),
    'none', pg_temp.plant_line(v_run, a.entry_id, 'client_advance', 100000, null),
    'null_none', pg_temp.plant_line(v_run3, s.entry_id, 'client_advance', 5000, null),
    'null_some', pg_temp.plant_line(v_run3, s.entry_id, 'client_advance', 5000, pg_temp.mandate('a3')),
    'rev_none', pg_temp.plant_line(v_run3, v_rev, 'client_advance_reversal', -5000, null),
    'rev_some', pg_temp.plant_line(v_run3, v_rev, 'client_advance_reversal', -5000, pg_temp.mandate('a3')),
    -- (a collection's line keeps the rules it had: the mandate is not this check's)
    'collection', pg_temp.plant_line(v_run, pg_temp.rev(pg_temp.alloc('90')), 'allocation_reversal', -100000,
                                     pg_temp.mandate('a2')));
end $$;
select is(pg_temp.iso('sj'),
  '{"own": "99", "other": "remittance line 99: an advance item outside its advance''s mandate",
    "none": "remittance line 99: an advance item outside its advance''s mandate", "null_none": "99",
    "null_some": "remittance line 99: an advance item outside its advance''s mandate", "rev_none": "99",
    "rev_some": "remittance line 99: an advance item outside its advance''s mandate", "collection": "99"}'::jsonb,
  'j: an advance item''s line (or its reversal''s) carries its advance''s mandate, none with none (the insert guard)');


-- k. (7a round 3 « Left open »: the return named for an item its run never carried; switch on) ------------------------
-- 043 #50's state (Durand's E 40 000 paid by U on d − 4; Y with E, F 25 000 and U's −40 000 row, debited d − 3, its
-- payout back d − 2), then U itself comes back (+40 000 re-queued): E's attributions not netted in Y cover its line, so
-- what came back on its way is U (« unplanned »), not Y's payout — while the money waits and once W pays it; F keeps
-- « run »
create or replace function pg_temp.late_exec_on(p_x uuid, p_s text, p_day date) returns text language plpgsql as $$
begin
  perform pg_temp.exec_back(p_x, p_day);
  perform pg_temp.stmt2(p_s, p_day, jsonb_build_array(jsonb_build_object(
    'amount', pg_temp.amt(p_x), 'e2e', pg_temp.e2e(p_x))));
  return pg_temp.bkx(pg_temp.l2(p_s, 1), jsonb_build_array(pg_temp.pt('unplanned_payout', p_x, pg_temp.amt(p_x))));
end $$;
create or replace function pg_temp.s17m() returns jsonb language plpgsql as $$
declare v_t uuid; v_y uuid; v_w uuid; w jsonb; p jsonb; q jsonb; d date := private.paris_today();
begin
  v_t := pg_temp.late_cancel('a7', '9c', 40000, 'c90');
  w := jsonb_build_object('exec', pg_temp.late_exec_on(v_t, 'c91', d - 4));
  perform pg_temp.pending('a7', '9d', 25000);
  v_y := pg_temp.flight('a7', 'c92');
  perform pg_temp.debit(v_y, 'c93', d - 3);
  perform pg_temp.bounce(v_y, 'c94', d - 2);
  w := w || jsonb_build_object('u_back', pg_temp.late_return(v_t, 'c97'), 'queue', pg_temp.queue('a7'));
  p := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('9c')));
  q := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('9d')));
  w := w || jsonb_build_object(
    'e', jsonb_build_array(p -> 0 ->> 'run_number' = pg_temp.rnum(v_y), p -> 0 -> 'paid_on', p -> 0 -> 'paid_how',
                           p -> 0 -> 'paid_run_number', p -> 0 -> 'returned_via'),
    'f', jsonb_build_array(q -> 0 -> 'paid_on', q -> 0 -> 'returned_via'),
    'nightly', pg_temp.nightly());
  perform pg_temp.reconfirm('a7');
  v_w := pg_temp.flight('a7', 'c95');
  perform pg_temp.debit(v_w, 'c96', d);
  p := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('9c')));
  q := pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('9d')));
  return w || jsonb_build_object(
    'w_lines', (select jsonb_agg(l.kind || ':' || l.amount_minor order by l.kind, l.amount_minor)
                from public.remittance_line l where l.run_id = v_w),
    'e_then', jsonb_build_array(p -> 0 ->> 'paid_on' = d::text, p -> 0 ->> 'paid_how',
                                p -> 0 ->> 'paid_run_number' = pg_temp.rnum(v_w), p -> 0 -> 'returned_via'),
    'f_then', jsonb_build_array(q -> 0 ->> 'paid_on' = d::text, q -> 0 ->> 'paid_how', q -> 0 -> 'returned_via'),
    'nightly_then', pg_temp.nightly());
end $$;
select is(pg_temp.iso('s17m', true),
  '{"exec": "ok", "u_back": "ok", "queue": ["payout_returned:25000", "payout_returned:40000"],
    "e": [true, null, null, null, "unplanned"], "f": [null, "run"], "nightly": [],
    "w_lines": ["payout_returned:25000", "payout_returned:40000"], "e_then": [true, "paid", true, "unplanned"],
    "f_then": [true, "paid", "run"], "nightly_then": []}'::jsonb,
  'k (7a round 3 carry-over; switch on): an item an unplanned payout paid in full, its run''s own payout back, then that '
  'payout back too — what came back on its way is the payout outside any run (« unplanned »), waiting and once paid');


-- l. (review round 1, M7B-MONEY-1) Only a remitted reversal's cover counts in its mandate's money --------------------------
-- A double payout's advance (S03r, case d's path: on Roux's mandate) and a one-mandate run's overrun (case b's: on
-- Martin's) are documents of their mandate, but their queue rows pair with rows of no file (the unplanned payout's −U,
-- whatever left 4670 in debit): their lines carry no mandate, as before 7b — a line on the advance's mandate is refused;
-- a remitted reversal's cover keeps its own (case j)
create or replace function pg_temp.sl() returns jsonb language plpgsql as $$
declare v_x uuid; v_t uuid; v_y uuid; v_run uuid; o public.client_advance; a public.client_advance; v_rev uuid;
        d date := private.paris_today();
begin
  v_x := pg_temp.remitted('a5', '40', 50000, '400', d - 3, d - 4);
  v_t := pg_temp.rtransfer(v_x);
  perform pg_temp.bounce(v_x, '401', d - 2);
  perform pg_temp.reconfirm('a5');
  v_y := pg_temp.flight('a5', 'pl');
  perform pg_temp.debit(v_y, '402', d - 1);
  perform pg_temp.late_exec(v_t, '403');
  a := (select x from public.client_advance x where x.client_organization_id = pg_temp.c('a5') and x.cause = 'double_payout');
  perform pg_temp.pending('a1', '20', 100000);
  v_run := pg_temp.flight('a1', 'pl0');
  perform pg_temp.handed_out('file-l0', 'gen-file-l0');
  perform pg_temp.forge('a1', 3000, 'l0');
  perform pg_temp.debit(v_run, 'fd0');
  o := (select x from public.client_advance x where x.client_organization_id = pg_temp.c('a1') and x.cause = 'payout_overrun');
  perform private.ledger_reverse(a.entry_id, 'raw-adv-l', 'Retour (test)', d);
  v_rev := pg_temp.rev(a.entry_id);
  return jsonb_build_object(
    'mandates', jsonb_build_array(a.mandate_id = pg_temp.mandate('a5'), o.mandate_id = pg_temp.mandate('a1')),
    'double_none', pg_temp.plant_line(v_y, a.entry_id, 'client_advance', 50000, null),
    'double_own', pg_temp.plant_line(v_y, a.entry_id, 'client_advance', 50000, pg_temp.mandate('a5')),
    'double_rev_none', pg_temp.plant_line(v_y, v_rev, 'client_advance_reversal', -50000, null),
    'double_rev_own', pg_temp.plant_line(v_y, v_rev, 'client_advance_reversal', -50000, pg_temp.mandate('a5')),
    'overrun_none', pg_temp.plant_line(v_run, o.entry_id, 'client_advance', 3000, null),
    'overrun_own', pg_temp.plant_line(v_run, o.entry_id, 'client_advance', 3000, pg_temp.mandate('a1')));
end $$;
select is(pg_temp.iso('sl'),
  '{"mandates": [true, true], "double_none": "99",
    "double_own": "remittance line 99: an advance item outside its advance''s mandate", "double_rev_none": "99",
    "double_rev_own": "remittance line 99: an advance item outside its advance''s mandate", "overrun_none": "99",
    "overrun_own": "remittance line 99: an advance item outside its advance''s mandate"}'::jsonb,
  'l: a double payout''s or an overrun''s advance row (and its reversal''s) carries no mandate — it pairs with rows of no '
  'file; only a remitted reversal''s cover counts in its mandate''s money (the insert guard)');


-- m. (review round 1, M7B-MONEY-2) An advance born before the client's proceeding is never said to be clawed back -------
-- Petit under a claw-back clause (art. 7.4): collection 80 (100 000) remitted, its payout debited d − 2; collection 81
-- (30 000) remitted, debited today; a proceeding opened on d − 1 recorded (its evidence); « Désimputer » of both. 80's
-- cover is born d − 2, before the opening: the prepare never sets it off (run._advances' nettable rule, L622-7 I as the
-- plan applies it), so no page says « reprise » — barred_proceeding on the « Désimputer » read, « Avances », the client
-- space, the run page and the nightly; 81's, born today, keeps the clause
create or replace function pg_temp.sm() returns jsonb language plpgsql as $$
declare a public.client_advance; b public.client_advance; v_ra uuid; v_rb uuid; w jsonb; r jsonb; v_chk uuid;
        d date := private.paris_today();
begin
  perform pg_temp.clawback('a8', 'art. 7.4');
  v_ra := pg_temp.remitted('a8', '80', 100000, '800', d - 2, d - 3);
  v_rb := pg_temp.remitted('a8', '81', 30000, '801', d, d - 1);
  insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
  values ('d0000000-0000-0000-0000-0000000004a8', '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a8'),
          'client_status_evidence', 'client/test/4a8.pdf', repeat('a', 64), 'application/pdf');
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, note, recorded_by)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a8'), 'proceeding_opened', d - 1,
          'd0000000-0000-0000-0000-0000000004a8', 'Redressement judiciaire (test)', '10000000-0000-0000-0000-000000000004');
  w := jsonb_build_object('desimputer', jsonb_build_array(
    (select jsonb_build_array(x ->> 'recovery', x ->> 'clause_ref')
     from jsonb_array_elements(pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('80')))) x),
    (select jsonb_build_array(x ->> 'recovery', x ->> 'clause_ref')
     from jsonb_array_elements(pg_temp.read_as('01', format('select public.allocation_remitted(%L)', pg_temp.pay('81')))) x)));
  perform pg_temp.unalloc('80');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('80')));
  perform pg_temp.unalloc('81');
  b := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('81')));
  w := w || jsonb_build_object('born', jsonb_build_array(private.advance_born_on(a.id) = d - 2,
                                                         private.advance_born_on(b.id) = d));
  r := pg_temp.read_as('01', format('select public.client_advances(''00000000-0000-0000-0000-0000000000aa'', %L)',
                                    pg_temp.c('a8')));
  w := w || jsonb_build_object(
    'rows', (select jsonb_agg(jsonb_build_array(x ->> 'amount_minor', x ->> 'recovery', x ->> 'clause_ref')
                              order by x ->> 'amount_minor')
             from jsonb_array_elements(r -> 'rows') x),
    'space', (select jsonb_agg(jsonb_build_array(x ->> 'open_minor', x ->> 'recovery', x ->> 'clause_ref')
                               order by x ->> 'open_minor')
              from jsonb_array_elements(pg_temp.read_as('03', format('select public.client_space_advances(%L)',
                                                                      pg_temp.c('a8'))) -> 'rows') x),
    'run_pages', jsonb_build_array(
      (select jsonb_agg(jsonb_build_array(x ->> 'recovery', x ->> 'clause_ref'))
       from jsonb_array_elements(pg_temp.read_as('01', format('select public.remittance_run_payout(%L)', v_ra))
                                 -> 'advances') x),
      (select jsonb_agg(jsonb_build_array(x ->> 'recovery', x ->> 'clause_ref'))
       from jsonb_array_elements(pg_temp.read_as('01', format('select public.remittance_run_payout(%L)', v_rb))
                                 -> 'advances') x)));
  v_chk := pg_temp.adv_run(d + 31, true);
  return w || jsonb_build_object(
    'nightly', (select jsonb_agg(jsonb_build_array(x.amount_minor, x.details ->> 'recovery') order by x.amount_minor)
                from public.payment_check_result x where x.run_id = v_chk and x.code = 'advance_open'));
end $$;
-- (M2c-7d-2, house rule R3, ADR-0014 « M2c-7d-2 ») plan §6.2.6 [critic] L4, founder Q18's default: while the
-- proceeding stands no advance is taken back or requested, whatever its birth — the one born since the opening no
-- longer keeps the clause (it was « clawback », « art. 7.4 » in 7b, whose rule read the birth alone)
-- (M2c-7d-3, house rule R3, ADR-0014 « M2c-7d-3 ») plan §6.2.10 [critic] L4, carried item 1: the nightly's advance_open
-- no longer lists an advance of a client in a proceeding (« nightly » was both advances, barred_proceeding):
-- claims_to_declare lists them, each in one alert (046c d) — the nightly still never says one is clawed back
select is(pg_temp.iso('sm'),
  '{"desimputer": [["barred_proceeding", null], ["barred_proceeding", null]], "born": [true, true],
    "rows": [["100000", "barred_proceeding", null], ["30000", "barred_proceeding", null]],
    "space": [["100000", "barred_proceeding", null], ["30000", "barred_proceeding", null]],
    "run_pages": [[["barred_proceeding", null]], [["barred_proceeding", null]]],
    "nightly": null}'::jsonb,
  'm: an advance born before the client''s proceeding opened is never said to be clawed back (barred_proceeding on '
  '« Désimputer », « Avances », the client space, the run page and the nightly); (M2c-7d-2, R3) nor one born since '
  '(L4: none while the proceeding stands)');

-- m (review round 2, advance-date-contradicts-barred). The same Petit: 80's cover, born d − 2 (its payout's debit) and
-- recorded today, after the opening (d − 1). « Avances » and the client space return its birth (born_on =
-- private.advance_born_on, before the opening: the date the barred rule reads) beside its recording (created_on), so
-- neither page dates « antérieure à l'ouverture » by a day after it
create or replace function pg_temp.sm2() returns jsonb language plpgsql as $$
declare a public.client_advance; r jsonb; s jsonb; v_open date; d date := private.paris_today();
begin
  perform pg_temp.clawback('a8', 'art. 7.4');
  perform pg_temp.remitted('a8', '80', 100000, '800', d - 2, d - 3);
  insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
  values ('d0000000-0000-0000-0000-0000000004a8', '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a8'),
          'client_status_evidence', 'client/test/4a8.pdf', repeat('a', 64), 'application/pdf');
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, note, recorded_by)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a8'), 'proceeding_opened', d - 1,
          'd0000000-0000-0000-0000-0000000004a8', 'Redressement judiciaire (test)', '10000000-0000-0000-0000-000000000004');
  perform pg_temp.unalloc('80');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('80')));
  v_open := private.client_opening_on(pg_temp.c('a8'), d);
  select x into r
  from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_advances(''00000000-0000-0000-0000-0000000000aa'', %L)',
                                                         pg_temp.c('a8'))) -> 'rows') x
  where x ->> 'advance_id' = a.id::text;
  select x into s
  from jsonb_array_elements(pg_temp.read_as('03', format('select public.client_space_advances(%L)', pg_temp.c('a8')))
                            -> 'rows') x
  where x ->> 'advance_id' = a.id::text;
  return jsonb_build_object(
    'born_before_opening', private.advance_born_on(a.id) = d - 2 and d - 2 < v_open,
    'recorded_after_opening', (a.created_at at time zone 'Europe/Paris')::date = d and v_open < d,
    'avances', jsonb_build_array(r ->> 'born_on' = private.advance_born_on(a.id)::text, r ->> 'created_on' = d::text,
                                 r ->> 'recovery'),
    'space', jsonb_build_array(s ->> 'born_on' = private.advance_born_on(a.id)::text, s ->> 'recovery'));
end $$;
select is(pg_temp.iso('sm2'),
  '{"born_before_opening": true, "recorded_after_opening": true, "avances": [true, true, "barred_proceeding"],
    "space": [true, "barred_proceeding"]}'::jsonb,
  'm (round 2): « Avances » and the client space date an advance by its birth (born_on, before the opening: the date '
  'the barred rule reads), its recording (created_on, after it) apart');


-- n. (review round 1, tests-ui-5) The write-off refused in_flight names the run taking the advance back ------------------
-- Martin's cover C (50 000) under a claw-back clause, taken by an approved run: « Passer en perte » is refused in_flight
-- with that run's number in its detail (the sheet words « … par le reversement RV-… en cours »)
create or replace function pg_temp.sn() returns jsonb language plpgsql as $$
declare c public.client_advance; v_y uuid; v_msg text; v_detail text; d date := private.paris_today();
begin
  perform pg_temp.clawback('a1', 'art. 7.4');
  perform pg_temp.remitted('a1', '82', 50000, '802', d - 2, d - 3);
  perform pg_temp.unalloc('82');
  c := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('82')));
  perform pg_temp.pending('a1', '83', 90000);
  v_y := pg_temp.request('a1', 'run-044-pn');
  perform pg_temp.prepare_adv(v_y, jsonb_build_array(jsonb_build_array(c.id, 20000)));
  perform pg_temp.approve_plain(v_y, 'run-044-pn');
  perform pg_temp.as_user('04');
  set local role authenticated;
  begin
    perform public.write_off_advance('woff-044-n', c.id, '10,00', '50000', 'Motif (test)',
                                     'd0000000-0000-0000-0000-0000000003a1');
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  end;
  reset role;
  return jsonb_build_object('message', v_msg, 'detail_is_the_run', v_detail = pg_temp.rnum(v_y));
end $$;
select is(pg_temp.iso('sn'),
  '{"message": "advance write-off refused: in_flight", "detail_is_the_run": true}'::jsonb,
  'n: « Passer en perte » refused in_flight names, in its detail, the run that takes the advance back');


-- The switch is still off (no M2c-7 migration writes it) --------------------------------------------------------------------
select is(private.switch_on('downloaded_file_cancellation'), false,
  'the cancellation-after-download switch is still off');

select * from finish();
rollback;
