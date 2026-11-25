-- M2c-7c-2 « repayment requests » (plan docs/design/m2c-7-plan.md §5.1, §5.2.7, §5.2.8, §5.3, §5.6, §5.7 045b; design
-- §7.3, §13 #5; ADR-0014 « M2c-7c-2 »). « Demande de remboursement d'avance »: a letter (not an invoice) asking a client
-- to repay an advance no claw-back clause recovers. It moves no money.
--   q     request_advance_repayment: the request (DRA-AAAA-NNNNNN, its total, its frozen payload — amounts as text, no
--         payer data — and its hash, the template), its items, the letter's job queued; replay and a key reused for
--         another request; roles and aal2; the change log;
--   r     every refusal, nothing written: bad_request, not_open (another client's, nothing open), in_flight (with its
--         run), before_opening (born before the client's proceeding opened), recently_requested (with the day; [the
--         30-day window: 29 days refused, 30 accepted]), clawback_applies (with the clause), total_changed,
--         no_own_account, identity_incomplete, recipient_unknown (death, guardianship, liquidation; since M2c-7d-1 a
--         mandate end is no longer refused: the letter goes to the client);
--         the preview states no amount of another client's advance (0, not_open);
--   a     ([critic] M7-MONEY-3, L7) a request is never also a claw-back: refused under a claw-back clause; a request
--         sent, then the terms gain a clause: the prepare's read still marks it requested; a draft whose plan takes an
--         advance requested since → documents_changed (the approval's re-check), approved once the request is
--         withdrawn;
--   w     the withdrawal: once (already_withdrawn), its motif, roles; the advance can be requested anew at once; the
--         rows append-only but for the document and the withdrawal, each set once;
--   g, m  ([critic] M7-MONEY-8, L5; [check 1] gap 6) payout_not_received exactly while entry_remitted(E).paid_on is
--         null: a payout come back, its re-queued item in a draft, in an approved run, then paid by RV-2 → accepted
--         (« versé … après le retour du virement du relevé RV-1 »); an N = 0 run (set off) requestable; a cover posted
--         at the booking (the reversal recorded while the run was in flight); an overrun whose payout came back;
--   n     ([check 3]) the request halves of 043 cases 5f and 17 (d) on their fixtures (switch on); the cover of what
--         an unplanned payout paid of a released item (043 #11): its origin the payout outside any run, released
--         once that payout came back (switch on);
--   cd    (carried default, ADR-0014 « M2c-7a review fixes » Left open) a collection an unplanned payout paid only in
--         part, in a run whose own payout came back: the advance not requested (payout_not_received; switch on);
--   s     (plan §5.6, switch off and on) an advance a sent run takes is in flight; the switch on, that run cancelled
--         after download: requestable;
--   d     the worker's document: set once from the stored bytes' hash (the object at repayment-requests/<servicer>/
--         <request>.pdf), the job's row read;
--   h     ([critic] F11) the PDF readable — row and file — by money staff and the client's whole-client members, never by
--         another tenant, a restricted viewer or a collector; the request and item rows the same;
--   p     the pages: the preview (its total from SQL), « Avances » (« Demandé le »), the client's requests (staff and
--         client space);
--   c, x  the nightly: advance_open's requested_on; repayment_request_document_missing after one hour; the full list
--         of codes run_advance_checks emits (045 x extended).
-- Review fixes round 1 (ADR-0014 « M2c-7c-2 review fixes »):
--   v     (MONEY-1) a return that would release an advance a request not withdrawn names is refused advance_requested
--         — the double payout's return (switch off, and on), the release of an unplanned payout's cover (switch on) —,
--         booked once the request is withdrawn;
--   l     (MONEY-2; plan §5.2.5, [critic] L16) a dedicated-account line whose label names the client's DRA-… number
--         designates that request's advances: it pays the advance, not the due invoice; another client's DRA names none;
--   c2    (NIGHT-1, TUI-4, CC-1) a request withdrawn before its letter was drawn: no letter drawn, no alert;
--   w2    (UI-1) the withdrawal of a reminder says which request still names the advance;
--   h2    (TUI-3, CC-2) the withdrawal's motif and the staff's ids are not the client's to read;
--   b     (TUI-6) a bank return's origin, in full and in part.
-- The cancellation-after-download switch stays off: its cases (n, cd, s, v) run in their own rolled-back scenarios with
-- it on (pg_temp.iso(…, true)); a guard at the end checks it is off.
begin;
select plan(32);

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


-- q. The request (§5.2.7) ----------------------------------------------------------------------------------------------
-- Petit (a8; its mandate without a claw-back clause): its collection 91 (30 000) remitted (debited d − 2), then
-- « Désimputer »: the cover A. The request: its number, total, items, frozen payload (amounts as text, no payer data),
-- its hash, the letter's job queued; no money moved; replay, a key reused, roles, the change log
create or replace function pg_temp.sq1() returns jsonb language plpgsql as $$
declare a public.client_advance; r jsonb; q public.advance_repayment_request; p jsonb; w jsonb; v_run text;
        n_entries bigint; d date := private.paris_today();
begin
  a := pg_temp.adv('a8', '91', 30000, '910');
  v_run := (select x.run_number from private.entry_remitted(pg_temp.alloc('91')) x);
  n_entries := (select count(*) from public.ledger_entry);
  r := pg_temp.dra('q1', 'a8', array[a.id]);
  q := pg_temp.rq(r);
  p := q.payload;
  w := jsonb_build_object(
    'number', jsonb_build_array(r ->> 'number' = q.number, q.number ~ ('^DRA-' || to_char(d, 'YYYY') || '-[0-9]{6}$')),
    'row', jsonb_build_array(q.client_organization_id = pg_temp.c('a8'), q.currency, q.issue_date = d, q.total_minor,
                             q.template_version, q.document_id, q.pdf_sha256, q.renderer_version,
                             q.issued_by = '10000000-0000-0000-0000-000000000001', q.withdrawn_at),
    'items', (select jsonb_agg(jsonb_build_array(i.advance_id = a.id, i.open_minor))
              from public.advance_repayment_request_item i where i.request_id = q.id),
    'hash', q.payload_sha256 = encode(sha256(convert_to(q.payload::text, 'UTF8')), 'hex'),
    'payload', jsonb_build_array(p ->> 'number' = q.number, p ->> 'issue_date' = d::text, p ->> 'currency',
                                 p -> 'total_minor', p ->> 'template', p -> 'recipient' ->> 'name',
                                 p -> 'issuer' ->> 'name', p -> 'issuer' ->> 'siren', p -> 'own_account' ->> 'iban',
                                 p -> 'own_account' ->> 'holder', jsonb_array_length(p -> 'rows')),
    'row0', (select jsonb_build_array(x ->> 'advance_id' = a.id::text, x ->> 'recorded_on' = d::text, x ->> 'mandate',
                                      x ->> 'cause', x -> 'amount_minor', x -> 'repaid_minor', x -> 'open_minor')
             from jsonb_array_elements(p -> 'rows') x),
    'origin', (select jsonb_build_array(o ->> 'collected_on' = (d - 3)::text, o ->> 'file_ref', o ->> 'run_number' = v_run,
                                        o ->> 'paid_how', o ->> 'paid_on' = (d - 2)::text, o ->> 'paid_run_number' = v_run,
                                        o -> 'returned_via', o ->> 'reversal', o ->> 'reversed_on' = d::text,
                                        o -> 'returned_minor', o -> 'reversed_minor', o -> 'in_flight')
               from (select p -> 'rows' -> 0 -> 'origin' as o) z),
    -- no payer data: neither the payer's name nor its IBAN, nor the client's payout IBAN
    'no_payer', jsonb_build_array(position('PAYEUR' in p::text) = 0,
                                  position('FR7630004000031234567890143' in p::text) = 0,
                                  position('FR7662603642123444042514350' in p::text) = 0),
    'queued', (select count(*) from pgmq.q_remittances m
               where m.message ->> 'type' = 'repayment_request' and m.message ->> 'request_id' = q.id::text),
    'no_money', (select count(*) from public.ledger_entry) - n_entries);
  w := w || jsonb_build_object('replay', pg_temp.dra('q1', 'a8', array[a.id]) = r);
  w := w || jsonb_build_object(
    'requests', (select count(*) from public.advance_repayment_request x where x.client_organization_id = pg_temp.c('a8')),
    'reuse', pg_temp.dra('q1', 'a8', array[a.id], '29999') ->> 'error',
    'roles', jsonb_build_array(pg_temp.dra('q2', 'a8', array[a.id], p_user => '02') ->> 'error',
                               pg_temp.dra('q3', 'a8', array[a.id], p_aal => 'aal1') ->> 'error',
                               pg_temp.dra('q4', 'a8', array[a.id], p_user => '05') ->> 'error',
                               pg_temp.dra('q5', 'a8', array[a.id], p_user => '03') ->> 'error'),
    'change_log', jsonb_build_array(
      (select count(*) from private.change_log l where l.table_name = 'public.advance_repayment_request'
         and l.row_id = q.id::text and l.op = 'INSERT'),
      (select count(*) from private.change_log l where l.table_name = 'public.advance_repayment_request_item'
         and l.row_id = q.id || ':' || a.id and l.op = 'INSERT')));
  return w;
end $$;
select is(pg_temp.iso('sq1'),
  '{"number": [true, true],
    "row": [true, "EUR", true, 30000, "demande-remboursement-avance-fr-1", null, null, null, true, null],
    "items": [[true, 30000]], "hash": true,
    "payload": [true, true, "EUR", "30000", "demande-remboursement-avance-fr-1", "Petit SAS", "Collectoo SAS",
                "732829320", "FR7610107001011234567890129", "Collectoo SAS", 1],
    "row0": [true, true, "MAND-a8", "remitted_reversal", "30000", "0", "30000"],
    "origin": [true, "D-91", true, "paid", true, true, null, "unallocated", true, null, "30000", false],
    "no_payer": [true, true, true], "queued": 1, "no_money": 0, "replay": true, "requests": 1,
    "reuse": "idempotency key dra-045b-q1 was used for a different request",
    "roles": ["not allowed", "not allowed", "not allowed", "not allowed"], "change_log": [1, 1]}'::jsonb,
  'q: a request DRA-AAAA-NNNNNN for the advance''s open part — its items, its payload frozen (amounts as text, no '
  'payer data, the origin''s facts: collected, remitted and paid, then taken back), its hash, the letter''s job '
  'queued, no money moved; a replay returns it, a key reused for another request, another role, aal1 or another '
  'servicer refused; the change log');


-- r. The refusals, nothing written (§5.2.7) ---------------------------------------------------------------------------
-- the shape, an advance of another client, one with nothing open or unknown, the total the page showed
create or replace function pg_temp.sr1() returns jsonb language plpgsql as $$
declare a public.client_advance; b public.client_advance; l public.client_advance; w jsonb; n0 bigint;
begin
  a := pg_temp.adv('a8', '92', 30000, '920');
  b := pg_temp.adv('a8', '93', 10000, '930');
  l := pg_temp.adv('a2', '94', 20000, '940');
  perform pg_temp.plant_settlement(b.id, 10000);
  n0 := (select count(*) from public.advance_repayment_request);
  w := jsonb_build_object(
    'empty', pg_temp.why_not(pg_temp.dra('r1', 'a8', array[]::uuid[], '0')),
    'null', pg_temp.why_not(pg_temp.dra('r2', 'a8', null, '0')),
    'twice', pg_temp.why_not(pg_temp.dra('r3', 'a8', array[a.id, a.id], '60000')),
    'a_null', pg_temp.why_not(pg_temp.dra('r4', 'a8', array[a.id, null], '30000')),
    'euros', pg_temp.why_not(pg_temp.dra('r5', 'a8', array[a.id], '300,00')),
    'other_client', pg_temp.why_not(pg_temp.dra('r6', 'a8', array[a.id, l.id], '50000')),
    'nothing_open', pg_temp.why_not(pg_temp.dra('r7', 'a8', array[b.id], '0')),
    'unknown', pg_temp.why_not(pg_temp.dra('r8', 'a8', array[gen_random_uuid()], '0')),
    'total', pg_temp.why_not(pg_temp.dra('r9', 'a8', array[a.id], '29999')));
  -- the sheet's preview never states another client's advance's amount
  w := w || jsonb_build_object('preview_other', (select jsonb_build_array(x -> 'rows' -> 0 ->> 'open_minor',
                                                                          x -> 'rows' -> 0 ->> 'refusal', x ->> 'total_minor')
                                                 from (select pg_temp.read_as('01', format(
                                                         'select public.advance_repayment_preview(%L, ''EUR'', %L)',
                                                         pg_temp.c('a8'), array[l.id])) as x) z));
  return w || jsonb_build_object('written', (select count(*) from public.advance_repayment_request) - n0);
end $$;
select is(pg_temp.iso('sr1'),
  '{"empty": "bad_request", "null": "bad_request", "twice": "bad_request", "a_null": "bad_request",
    "euros": "bad_request", "other_client": "not_open", "nothing_open": "not_open", "unknown": "not_open",
    "total": "total_changed", "preview_other": ["0", "not_open", "0"], "written": 0}'::jsonb,
  'r: a request of no advance, of one twice, of a null, with a total that is not minor units → bad_request; an advance '
  'of another client, with nothing open or unknown → not_open; a total other than the page''s → total_changed; '
  'nothing written');

-- in flight (its run in the detail), born before the client's proceeding opened, under a claw-back clause (the clause in
-- the detail)
create or replace function pg_temp.sr2() returns jsonb language plpgsql as $$
declare a public.client_advance; o public.client_advance; c public.client_advance; v uuid; w jsonb; r jsonb; n0 bigint;
        d date := private.paris_today();
begin
  a := pg_temp.adv('a8', '95', 30000, '950');
  v := pg_temp.sent_taking('a8', a.id, '96', '961');
  o := pg_temp.adv('a6', '97', 30000, '970');
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, note, recorded_by)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a6'), 'proceeding_opened', d, pg_temp.ev('8', 'a6'),
          'Redressement judiciaire (test)', '10000000-0000-0000-0000-000000000004');
  c := pg_temp.adv('a7', '98', 30000, '980');
  perform pg_temp.clawback('a7', 'art. 7.4');
  n0 := (select count(*) from public.advance_repayment_request);
  r := pg_temp.dra('r10', 'a8', array[a.id]);
  w := jsonb_build_object('in_flight', jsonb_build_array(pg_temp.why_not(r), r ->> 'detail' = pg_temp.rnum(v),
                                                          pg_temp.rstatus(v)));
  w := w || jsonb_build_object('before_opening', pg_temp.why_not(pg_temp.dra('r11', 'a6', array[o.id])));
  r := pg_temp.dra('r12', 'a7', array[c.id]);
  return w || jsonb_build_object('clawback', jsonb_build_array(pg_temp.why_not(r), r ->> 'detail'),
                                 'written', (select count(*) from public.advance_repayment_request) - n0);
end $$;
select is(pg_temp.iso('sr2'),
  '{"in_flight": ["in_flight", true, "sent"], "before_opening": "before_opening",
    "clawback": ["clawback_applies", "art. 7.4"], "written": 0}'::jsonb,
  'r: an advance a sent run takes back → in_flight (its run); born before the client''s proceeding opened → '
  'before_opening (L622-7 I); under a claw-back clause in force today → clawback_applies (the clause: the next run takes '
  'it, a request would make the client pay twice); nothing written');

-- the 30-day window: a second request the same day, then with the first issued 29 days ago → recently_requested (its
-- day); issued 30 days ago → a reminder (a new request)
create or replace function pg_temp.sr3() returns jsonb language plpgsql as $$
declare a public.client_advance; r jsonb; r2 jsonb; w jsonb; d date := private.paris_today();
begin
  a := pg_temp.adv('a8', '99', 30000, '990');
  r := pg_temp.dra('r20', 'a8', array[a.id]);
  r2 := pg_temp.dra('r21', 'a8', array[a.id]);
  w := jsonb_build_object('today', jsonb_build_array(pg_temp.why_not(r2), r2 ->> 'detail' = d::text));
  perform pg_temp.dra_back((r ->> 'request_id')::uuid, d - 29);
  r2 := pg_temp.dra('r22', 'a8', array[a.id]);
  w := w || jsonb_build_object('d29', jsonb_build_array(pg_temp.why_not(r2), r2 ->> 'detail' = (d - 29)::text));
  perform pg_temp.dra_back((r ->> 'request_id')::uuid, d - 30);
  r2 := pg_temp.dra('r23', 'a8', array[a.id]);
  return w || jsonb_build_object('d30', pg_temp.why_not(r2),
    'live', (select count(*) from public.advance_repayment_request_item i where i.advance_id = a.id),
    -- and the newest names the advance as requested
    'requested_on', (select x.issue_date = d from private.advance_live_request(a.id) x));
end $$;
select is(pg_temp.iso('sr3'),
  '{"today": ["recently_requested", true], "d29": ["recently_requested", true], "d30": "ok", "live": 2,
    "requested_on": true}'::jsonb,
  'r: an advance requested less than 30 days ago → recently_requested (the day of the request); 30 days after, a '
  'reminder is a new request');

-- the servicer's own account and identity; an event after which 7c-2 sends nothing (recipient_unknown)
create or replace function pg_temp.sr4() returns jsonb language plpgsql as $$
declare a public.client_advance; m public.client_advance; w jsonb := '{}'; k text; n0 bigint;
        d date := private.paris_today();
begin
  a := pg_temp.adv('a8', '9a', 30000, '9a0');
  m := pg_temp.adv('a9', '9b', 30000, '9b0');
  n0 := (select count(*) from public.advance_repayment_request);
  update public.servicer_billing_settings set own_bank_account_id = null
  where organization_id = '00000000-0000-0000-0000-0000000000aa';
  w := w || jsonb_build_object('no_own_account', pg_temp.why_not(pg_temp.dra('r30', 'a8', array[a.id])));
  update public.servicer_billing_settings set own_bank_account_id = '80000000-0000-0000-0000-0000000000c0'
  where organization_id = '00000000-0000-0000-0000-0000000000aa';
  update public.billing_identity set rcs_city = null where organization_id = '00000000-0000-0000-0000-0000000000aa';
  w := w || jsonb_build_object('identity', pg_temp.why_not(pg_temp.dra('r31', 'a8', array[a.id])));
  update public.billing_identity set rcs_city = 'Paris' where organization_id = '00000000-0000-0000-0000-0000000000aa';
  foreach k in array array['death', 'guardianship', 'liquidation', 'mandate_ended'] loop
    begin
      insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                              evidence_document_id, note, recorded_by)
      values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a9'), k,
              case k when 'liquidation' then d - 5 else d end, pg_temp.ev('8', 'a9'), 'Événement (test)',
              '10000000-0000-0000-0000-000000000004');
      w := w || jsonb_build_object(k, pg_temp.why_not(pg_temp.dra('r32-' || k, 'a9', array[m.id])));
      raise exception 'event rolled back' using errcode = 'TR004';
    exception when sqlstate 'TR004' then
      null;
    end;
  end loop;
  return w || jsonb_build_object('written', (select count(*) from public.advance_repayment_request) - n0,
                                 'then', pg_temp.why_not(pg_temp.dra('r33', 'a9', array[m.id])));
end $$;
select is(pg_temp.iso('sr4'),
  '{"no_own_account": "no_own_account", "identity": "identity_incomplete", "death": "recipient_unknown",
    "guardianship": "recipient_unknown", "liquidation": "recipient_unknown", "mandate_ended": "ok",
    "written": 0, "then": "ok"}'::jsonb,
  'r: no own account to repay to → no_own_account; the servicer''s billing identity incomplete → identity_incomplete; a '
  'death, a guardianship or a liquidation recorded with nobody who acts for the client → recipient_unknown; '
  '(M2c-7d-1, ADR-0014 « M2c-7d-1 », house rule R3: the refusal narrowed, plan §6.2.12) after a mandate end the '
  'letter goes to the client: made (rolled back with its event); nothing written, then the request once the client''s '
  'status is plain');


-- a. ([critic] M7-MONEY-3, L7) a requested advance is never also clawed back -----------------------------------------
-- Petit's A and B; a draft whose plan takes A (prepared before the request, emulated); A requested: the prepare's read
-- marks it; the terms gain a claw-back clause: A stays requested, B is refused clawback_applies; the draft's approval is
-- refused documents_changed (the approval's re-check), the run back to draft
create or replace function pg_temp.sa1() returns jsonb language plpgsql as $$
declare a public.client_advance; b public.client_advance; v uuid; r jsonb; w jsonb;
begin
  a := pg_temp.adv('a8', '9c', 30000, '9c0');
  b := pg_temp.adv('a8', '9d', 10000, '9d0');
  perform pg_temp.pending('a8', '9e', 150000);
  v := pg_temp.request('a8', 'run-sa1');
  perform pg_temp.prepare_adv(v, jsonb_build_array(jsonb_build_array(a.id, 30000)));
  r := pg_temp.dra('a1', 'a8', array[a.id]);
  w := jsonb_build_object('request', pg_temp.why_not(r), 'requested', pg_temp.requested('a8') = jsonb_build_array(a.id));
  perform pg_temp.clawback('a8', 'art. 7.4');
  w := w || jsonb_build_object('still', pg_temp.requested('a8') = jsonb_build_array(a.id),
                               'b', pg_temp.why_not(pg_temp.dra('a2', 'a8', array[b.id])));
  w := w || jsonb_build_object('approval', pg_temp.approve_plain(v, 'run-sa1'));
  return w || jsonb_build_object('reason', (select last_failure ->> 'code' from public.remittance_run where id = v),
                                 'open', private.advance_open(a.id));
end $$;
select is(pg_temp.iso('sa1'),
  '{"request": "ok", "requested": true, "still": true, "b": "clawback_applies", "approval": "back_to_draft:draft",
    "reason": "documents_changed", "open": 30000}'::jsonb,
  'a (M7-MONEY-3, L7): a requested advance is never also taken by a run — the prepare reads it requested (also once '
  'the terms gain a claw-back clause, which refuses a new request), and the approval sends back a draft that takes an '
  'advance requested since it was prepared (documents_changed)');
-- the same draft, the request withdrawn before the approval: approved, the run takes A
create or replace function pg_temp.sa2() returns jsonb language plpgsql as $$
declare a public.client_advance; v uuid; r jsonb; w jsonb;
begin
  a := pg_temp.adv('a8', '9c', 30000, '9c0');
  perform pg_temp.pending('a8', '9e', 150000);
  v := pg_temp.request('a8', 'run-sa2');
  perform pg_temp.prepare_adv(v, jsonb_build_array(jsonb_build_array(a.id, 30000)));
  r := pg_temp.dra('a3', 'a8', array[a.id]);
  perform pg_temp.wd('a3', (r ->> 'request_id')::uuid);
  w := jsonb_build_object('withdrawn', pg_temp.requested('a8'));
  w := w || jsonb_build_object('approval', pg_temp.approve_plain(v, 'run-sa2'));
  return w || jsonb_build_object('taken', (select s ->> 'amount' from public.remittance_run x
                                           cross join lateral jsonb_array_elements(x.settlement_plan -> 'settles') s
                                           where x.id = v and s ->> 'document_id' = a.id::text));
end $$;
select is(pg_temp.iso('sa2'), '{"withdrawn": [], "approval": "approved:approved", "taken": "30000"}'::jsonb,
  'a: once its request is withdrawn the advance is no longer requested: the approval takes it back');


-- w. The withdrawal ---------------------------------------------------------------------------------------------------
create or replace function pg_temp.sw() returns jsonb language plpgsql as $$
declare a public.client_advance; r jsonb; x jsonb; q public.advance_repayment_request; w jsonb;
        d date := private.paris_today();
begin
  a := pg_temp.adv('a8', '9f', 30000, '9f0');
  r := pg_temp.dra('w1', 'a8', array[a.id]);
  q := pg_temp.rq(r);
  w := jsonb_build_object(
    'roles', jsonb_build_array(pg_temp.wd('w0a', q.id, p_user => '02') ->> 'error',
                               pg_temp.wd('w0b', q.id, p_aal => 'aal1') ->> 'error',
                               pg_temp.wd('w0c', q.id, p_user => '05') ->> 'error',
                               pg_temp.wd('w0d', q.id, p_user => '03') ->> 'error',
                               pg_temp.wd('w0e', gen_random_uuid()) ->> 'error'),
    'no_reason', pg_temp.wd('w0f', q.id, p_reason => '   ') ->> 'error');
  x := pg_temp.wd('w1', q.id);
  q := pg_temp.rq(r);
  w := w || jsonb_build_object(
    'result', jsonb_build_array(x ->> 'request_id' = q.id::text, x ->> 'number' = q.number,
                                x ->> 'withdrawn_on' = d::text),
    'row', jsonb_build_array(q.withdrawn_at is not null, q.withdrawn_by = '10000000-0000-0000-0000-000000000001',
                             q.withdrawal_reason),
    'items', (select count(*) from public.advance_repayment_request_item i where i.request_id = q.id),
    'requested', pg_temp.requested('a8'));
  w := w || jsonb_build_object('replay', pg_temp.wd('w1', q.id) = x);
  w := w || jsonb_build_object('again', pg_temp.wd('w2', q.id) ->> 'error');
  w := w || jsonb_build_object('anew', pg_temp.why_not(pg_temp.dra('w2', 'a8', array[a.id])));
  return w || jsonb_build_object(
    'guard', jsonb_build_array(
      pg_temp.state(format('update public.advance_repayment_request set withdrawn_at = now() where id = %L', q.id)),
      pg_temp.state(format('update public.advance_repayment_request set withdrawal_reason = ''x'' where id = %L', q.id)),
      pg_temp.state(format('update public.advance_repayment_request set total_minor = 1 where id = %L', q.id)),
      pg_temp.state(format('update public.advance_repayment_request set payload = ''{}'' where id = %L', q.id)),
      pg_temp.state(format('delete from public.advance_repayment_request where id = %L', q.id)),
      pg_temp.state(format('update public.advance_repayment_request_item set open_minor = 1 where request_id = %L',
                           q.id)),
      pg_temp.state(format('delete from public.advance_repayment_request_item where request_id = %L', q.id))),
    'change_log', (select count(*) from private.change_log l where l.table_name = 'public.advance_repayment_request'
                     and l.row_id = q.id::text and l.op = 'UPDATE'));
end $$;
select is(pg_temp.iso('sw'),
  '{"roles": ["not allowed", "not allowed", "not allowed", "not allowed", "not allowed"],
    "no_reason": "repayment request refused: reason_required",
    "result": [true, true, true], "row": [true, true, "Le client conteste la somme (test)"], "items": 1,
    "requested": [], "replay": true, "again": "repayment request refused: already_withdrawn", "anew": "ok",
    "guard": ["23514", "23514", "23514", "23514", "23514", "23514", "23514"], "change_log": 1}'::jsonb,
  'w: « Retirer la demande » (admins and ops managers at aal2, with a motif) sets the withdrawal once — a replay '
  'returns it, a second one is refused already_withdrawn —; the advance is no longer requested and may be requested '
  'anew; the request''s rows are append-only but for the document and the withdrawal, each set once; the change log');


-- g, m. payout_not_received, and what is requestable ([critic] M7-MONEY-8, L5; [check 1] gap 6) ------------------------
-- Martin's RV-1 debited (d − 5), its payout returned (d − 4: +N re-queued), then its collection taken back: A1. Refused
-- payout_not_received (RV-1, its own payout) while the re-queued item waits, sits in a draft, in an approved run; once
-- RV-2's debit is booked (d − 3) accepted, its origin « versé … après le retour du virement du relevé RV-1 »
create or replace function pg_temp.sg() returns jsonb language plpgsql as $$
declare v1 uuid; v2 uuid; a public.client_advance; w jsonb; r jsonb; d date := private.paris_today();
begin
  v1 := pg_temp.remitted('a1', 'c1', 100000, 'bc1', d - 5, d - 6);
  perform pg_temp.bounce(v1, 'bc11', d - 4);
  perform pg_temp.unalloc('c1');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('c1')));
  r := pg_temp.dra('g1', 'a1', array[a.id]);
  w := jsonb_build_object('returned', jsonb_build_array(pg_temp.why_not(r), r ->> 'detail' = pg_temp.rnum(v1) || ':run'));
  perform pg_temp.reconfirm('a1');
  v2 := pg_temp.request('a1', 'run-g2');
  perform pg_temp.prepare_plain(v2);
  w := w || jsonb_build_object('draft', pg_temp.why_not(pg_temp.dra('g2', 'a1', array[a.id])));
  w := w || jsonb_build_object('approval', pg_temp.approve_plain(v2, 'run-g2'));
  w := w || jsonb_build_object('approved', pg_temp.why_not(pg_temp.dra('g3', 'a1', array[a.id])));
  perform pg_temp.debit(v2, 'bc2', d - 3);
  r := pg_temp.dra('g4', 'a1', array[a.id]);
  return w || jsonb_build_object(
    'paid', pg_temp.why_not(r),
    'origin', (select jsonb_build_array(o ->> 'run_number' = pg_temp.rnum(v1), o ->> 'paid_how',
                                        o ->> 'paid_on' = (d - 3)::text, o ->> 'paid_run_number' = pg_temp.rnum(v2),
                                        o ->> 'returned_via', o ->> 'reversal')
               from (select pg_temp.origin(r) as o) z));
end $$;
select is(pg_temp.iso('sg'),
  '{"returned": ["payout_not_received", true], "draft": "payout_not_received", "approval": "approved:approved",
    "approved": "payout_not_received", "paid": "ok",
    "origin": [true, "paid", true, true, "run", "unallocated"]}'::jsonb,
  'g (M7-MONEY-8, L5): an advance whose item came back with its run''s payout is not requested while the re-queued '
  'item waits, in a draft or an approved run (payout_not_received, the run in the detail); once a later run''s debit '
  'paid it again, it is — the letter''s origin « versé le … (relevé RV-2, après le retour du virement du relevé RV-1) »');

-- m. ([check 1] gap 6) an advance of an N = 0 run (booked at approval, its set-off paid E: « réglé par compensation »)
-- is requestable; and a cover posted at the booking (E reversed while its run was in flight)
create or replace function pg_temp.sm() returns jsonb language plpgsql as $$
declare v uuid; v4 uuid; a public.client_advance; b public.client_advance; r jsonb; r2 jsonb;
        d date := private.paris_today();
begin
  perform pg_temp.pending('a3', 'c2', 12000);
  v := pg_temp.run('a3', '{"c2": "12000"}', 12000, 2000, 10, 12);
  perform pg_temp.unalloc('c2');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('c2')));
  r := pg_temp.dra('m1', 'a3', array[a.id]);
  perform pg_temp.pending('a4', 'c3', 50000);
  v4 := pg_temp.flight('a4', 'm2');
  perform pg_temp.handed_out('file-bc3', 'gen-file-bc3');
  perform pg_temp.unalloc('c3');
  perform pg_temp.debit(v4, 'bc3', d - 1);
  b := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('c3')));
  r2 := pg_temp.dra('m2', 'a4', array[b.id]);
  return jsonb_build_object(
    'set_off', (select jsonb_build_array(pg_temp.why_not(r), pg_temp.rstatus(v), o ->> 'paid_how', o ->> 'paid_on' = d::text,
                                         o ->> 'run_number' = pg_temp.rnum(v), o ->> 'paid_run_number' = pg_temp.rnum(v),
                                         o -> 'in_flight')
                from (select pg_temp.origin(r) as o) z),
    'at_booking', (select jsonb_build_array(pg_temp.why_not(r2), o ->> 'paid_how', o ->> 'paid_on' = (d - 1)::text,
                                            o ->> 'reversal', o ->> 'reversed_on' = d::text, o -> 'in_flight')
                   from (select pg_temp.origin(r2) as o) z));
end $$;
select is(pg_temp.iso('sm'),
  '{"set_off": ["ok", "booked", "set_off", true, true, true, false],
    "at_booking": ["ok", "paid", true, "unallocated", true, true]}'::jsonb,
  'm (check 1, gap 6): an advance of an N = 0 run is requestable (paid_how « set_off »: never « versé »); a cover '
  'posted at the booking says the reversal was recorded while its run was in flight');

-- an overrun's advance (043 #16's forged 4670 debit): requestable while its run's payout stays paid; once that payout came
-- back, payout_not_received (the client no longer holds it)
create or replace function pg_temp.so() returns jsonb language plpgsql as $$
declare v uuid; a public.client_advance; r jsonb; w jsonb; d date := private.paris_today();
begin
  perform pg_temp.pending('a1', 'c4', 100000);
  v := pg_temp.flight('a1', 'pc4');
  perform pg_temp.handed_out('file-bc4', 'gen-file-bc4');
  perform pg_temp.forge('a1', 3000, 'c4');
  perform pg_temp.debit(v, 'bc4');
  a := (select x from public.client_advance x where x.client_organization_id = pg_temp.c('a1') and x.cause = 'payout_overrun');
  r := pg_temp.dra('o1', 'a1', array[a.id]);
  w := jsonb_build_object('paid', jsonb_build_array(pg_temp.why_not(r), a.amount_minor),
                          'origin', (select jsonb_build_array(o ->> 'run_number' = pg_temp.rnum(v),
                                                              o ->> 'paid_on' = (d - 1)::text)
                                     from (select pg_temp.origin(r) as o) z));
  perform pg_temp.wd('o1', (r ->> 'request_id')::uuid);
  perform pg_temp.bounce(v, 'bc41');
  r := pg_temp.dra('o2', 'a1', array[a.id]);
  return w || jsonb_build_object('returned', jsonb_build_array(pg_temp.why_not(r),
                                                               r ->> 'detail' = pg_temp.rnum(v) || ':run'));
end $$;
select is(pg_temp.iso('so'),
  '{"paid": ["ok", 3000], "origin": [true, true], "returned": ["payout_not_received", true]}'::jsonb,
  'm: an overrun''s advance is requested while its run''s payout stays paid (« Reversement RV-… versé le … »), never '
  'once that payout came back (payout_not_received)');


-- n. ([check 3]) the request halves of 043 cases 5f and 17 (d), on their fixtures (switch on) --------------------------
-- 5f: Roux's X cancelled after download, U executed late; Y holds E and U's −A row (N = 0, « compris … montant net nul »,
-- booked at approval); R(E) → A1. Requestable then; U back (+A re-queued) → payout_not_received; once Z's debit pays the
-- re-queued +A → accepted, « versé … après le retour d'un virement hors reversement »
create or replace function pg_temp.sn1() returns jsonb language plpgsql as $$
declare v_x uuid; v_y uuid; v_z uuid; a public.client_advance; w jsonb; r jsonb; d date := private.paris_today();
begin
  v_x := pg_temp.late_cancel('a5', 'c5', 40000, 'c50');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, 'c51'));
  v_y := pg_temp.request('a5', 'draft-run-c52');
  perform pg_temp.prepare_plain(v_y);
  w := w || jsonb_build_object('y', pg_temp.approve_plain(v_y, 'approve-run-c52'));
  perform pg_temp.unalloc('c5');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('c5')));
  r := pg_temp.dra('n1', 'a5', array[a.id]);
  w := w || jsonb_build_object('netted', (select jsonb_build_array(pg_temp.why_not(r), o ->> 'paid_how')
                                          from (select pg_temp.origin(r) as o) z));
  perform pg_temp.wd('n1', (r ->> 'request_id')::uuid);
  w := w || jsonb_build_object('returned', pg_temp.late_return(v_x, 'c53'));
  r := pg_temp.dra('n2', 'a5', array[a.id]);
  w := w || jsonb_build_object('back', jsonb_build_array(pg_temp.why_not(r), r ->> 'detail' = pg_temp.rnum(v_y) || ':unplanned'));
  perform pg_temp.reconfirm('a5');
  v_z := pg_temp.flight('a5', 'c54');
  perform pg_temp.debit(v_z, 'bc54', d - 1);
  r := pg_temp.dra('n3', 'a5', array[a.id]);
  return w || jsonb_build_object(
    'paid', (select jsonb_build_array(pg_temp.why_not(r), o ->> 'run_number' = pg_temp.rnum(v_y), o ->> 'paid_how',
                                      o ->> 'paid_on' = (d - 1)::text, o ->> 'paid_run_number' = pg_temp.rnum(v_z),
                                      o ->> 'returned_via')
             from (select pg_temp.origin(r) as o) z));
end $$;
select is(pg_temp.iso('sn1', true),
  '{"exec": "ok", "y": "booked:booked", "netted": ["ok", "netted"], "returned": "ok",
    "back": ["payout_not_received", true], "paid": ["ok", true, "paid", true, true, "unplanned"]}'::jsonb,
  'n (check 3; 043 5f, switch on): an advance of an N = 0 run netted by an unplanned payout is requested; once that '
  'payout came back, payout_not_received until a later run pays the re-queued item');

-- 17 (d): Durand's RV-1, a late predecessor booked as its payout (x1 stays cancelled), then x1 returned (no
-- return_entry_id), its collection taken back → payout_not_received; RV-2's debit pays the re-queued +N → accepted
create or replace function pg_temp.sn2() returns jsonb language plpgsql as $$
declare v1 uuid; v2 uuid; a public.client_advance; w jsonb; r jsonb; d date := private.paris_today();
begin
  v1 := pg_temp.late_pred('a7', 'c6', 100000, 'bc6', false, d - 4);
  perform pg_temp.stmt2('bc61', d - 3, jsonb_build_array(jsonb_build_object(
    'dir', 'credit', 'kind', 'return', 'amount', 100000, 'orig', pg_temp.e2e(pg_temp.v('x1-bc6')))));
  w := jsonb_build_object('booked', pg_temp.v('lp-booked-bc6') = v1,
                          'returned', pg_temp.bkx(pg_temp.l2('bc61', 1), pg_temp.prop(pg_temp.l2('bc61', 1))),
                          'x1', pg_temp.status(pg_temp.v('x1-bc6')));
  perform pg_temp.unalloc('c6');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('c6')));
  r := pg_temp.dra('n5', 'a7', array[a.id]);
  w := w || jsonb_build_object('back', jsonb_build_array(pg_temp.why_not(r), r ->> 'detail' = pg_temp.rnum(v1) || ':run'));
  perform pg_temp.reconfirm('a7');
  v2 := pg_temp.flight('a7', 'c62');
  perform pg_temp.debit(v2, 'bc62', d - 1);
  r := pg_temp.dra('n6', 'a7', array[a.id]);
  return w || jsonb_build_object(
    'paid', (select jsonb_build_array(pg_temp.why_not(r), o ->> 'paid_on' = (d - 1)::text,
                                      o ->> 'paid_run_number' = pg_temp.rnum(v2), o ->> 'returned_via')
             from (select pg_temp.origin(r) as o) z));
end $$;
select is(pg_temp.iso('sn2', true),
  '{"booked": true, "returned": "ok", "x1": "cancelled", "back": ["payout_not_received", true],
    "paid": ["ok", true, true, "run"]}'::jsonb,
  'n (check 3; 043 17 (d), switch on): a late predecessor''s return read from its booking: payout_not_received until '
  'the later run''s debit, then requested, dated by it');


-- (switch on; 043 #11) a cancelled run's item paid by an unplanned payout, then reversed: the cover is the attribution (no
-- booked run holds the collection) — requested, its origin « versé … par un virement hors reversement » dated by that
-- payout's booking, no run named; that payout back releases the cover: nothing left to request
create or replace function pg_temp.sn3() returns jsonb language plpgsql as $$
declare v_x uuid; a public.client_advance; w jsonb; r jsonb;
begin
  v_x := pg_temp.late_cancel('a4', 'c9', 40000, 'c90');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, 'c91'));
  perform pg_temp.unalloc('c9');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('c9')));
  r := pg_temp.dra('n7', 'a4', array[a.id]);
  w := w || jsonb_build_object(
    'request', (select jsonb_build_array(pg_temp.why_not(r), o ->> 'paid_how', o ->> 'paid_on' = private.paris_today()::text,
                                         o -> 'run_number', o ->> 'reversed_minor')
                from (select pg_temp.origin(r) as o) z));
  perform pg_temp.wd('n7', (r ->> 'request_id')::uuid);
  w := w || jsonb_build_object('returned', pg_temp.late_return(v_x, 'c92'));
  return w || jsonb_build_object('after', pg_temp.why_not(pg_temp.dra('n8', 'a4', array[a.id])));
end $$;
select is(pg_temp.iso('sn3', true),
  '{"exec": "ok", "request": ["ok", "unplanned", true, null, "40000"], "returned": "ok", "after": "not_open"}'::jsonb,
  'n (switch on): a cover of what an unplanned payout paid of a released item is requested, its origin the payout '
  'outside any run (no run named); once that payout came back, the cover released: not_open');


-- cd. The carried default (ADR-0014 « M2c-7a review fixes » Left open) ------------------------------------------------
-- 043 17 (l), switch on: Durand's collection c7 paid only in part (32 800 of 40 000) by an unplanned payout, the rest in
-- run Y whose own payout came back: E reads not with the client (paid_on null); its cover is not requested
create or replace function pg_temp.scd() returns jsonb language plpgsql as $$
declare v_t uuid; v_y uuid; a public.client_advance; w jsonb; r jsonb; d date := private.paris_today();
begin
  v_t := pg_temp.cancelled_late('a7', 'c7', 40000, 'late-c70');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_t, 'c71'));
  w := w || jsonb_build_object('attrib', (select jsonb_agg(u.amount_minor) from private.unplanned_paid_item u
                                          where u.ledger_entry_id = pg_temp.alloc('c7')));
  perform pg_temp.pending('a7', 'c8', 25000);
  v_y := pg_temp.flight('a7', 'c72');
  perform pg_temp.debit(v_y, 'c73', d);
  perform pg_temp.bounce(v_y, 'c74', d);
  perform pg_temp.unalloc('c7');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('c7')));
  r := pg_temp.dra('cd1', 'a7', array[a.id]);
  return w || jsonb_build_object(
    'cover', a.amount_minor, 'paid_on', (select x.paid_on from private.entry_remitted(pg_temp.alloc('c7')) x),
    'request', jsonb_build_array(pg_temp.why_not(r), r ->> 'detail' = pg_temp.rnum(v_y) || ':run'));
end $$;
select is(pg_temp.iso('scd', true),
  '{"exec": "ok", "attrib": [32800], "cover": 40000, "paid_on": null,
    "request": ["payout_not_received", true]}'::jsonb,
  'cd (carried default; switch on): a collection an unplanned payout paid only in part, the rest in a run whose payout '
  'came back, reads not received as a whole: its advance is not requested (Q22 asks whether a run''s set-off should be '
  'shared out over its items)');


-- s. The switch (plan §5.6) ---------------------------------------------------------------------------------------------
-- off: an advance a sent run takes (its file downloaded) is in flight; that payout is never cancelled
create or replace function pg_temp.ss1() returns jsonb language plpgsql as $$
declare a public.client_advance; v uuid; r jsonb;
begin
  a := pg_temp.adv('a8', 'd1', 30000, 'd10');
  v := pg_temp.sent_taking('a8', a.id, 'd2', 'd21');
  r := pg_temp.dra('s1', 'a8', array[a.id]);
  return jsonb_build_object('status', pg_temp.rstatus(v), 'request', pg_temp.why_not(r),
                            'switch', private.switch_on('downloaded_file_cancellation'));
end $$;
select is(pg_temp.iso('ss1'), '{"status": "sent", "request": "in_flight", "switch": false}'::jsonb,
  's (switch off): an advance a sent run takes back stays in flight (its downloaded payout is never cancelled)');
-- on: that run's payout cancelled after download and the run cancelled: its plan no longer holds the advance
create or replace function pg_temp.ss2() returns jsonb language plpgsql as $$
declare a public.client_advance; v uuid; r jsonb;
begin
  a := pg_temp.adv('a8', 'd1', 30000, 'd10');
  v := pg_temp.sent_taking('a8', a.id, 'd2', 'd21');
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = pg_temp.rtransfer(v);
  perform pg_temp.cancel_run(v, 'tk-d21');
  r := pg_temp.dra('s2', 'a8', array[a.id]);
  return jsonb_build_object('status', pg_temp.rstatus(v), 'request', pg_temp.why_not(r),
                            'switch', private.switch_on('downloaded_file_cancellation'));
end $$;
select is(pg_temp.iso('ss2', true), '{"status": "cancelled", "request": "ok", "switch": true}'::jsonb,
  's (switch on): a run cancelled after download no longer holds the advance its plan took: requestable');


-- d. The letter's document (the worker's: §5.2.7, §5.4) -----------------------------------------------------------------
create or replace function pg_temp.sd1() returns jsonb language plpgsql as $$
declare a public.client_advance; r jsonb; q public.advance_repayment_request; v_doc uuid; w jsonb;
begin
  a := pg_temp.adv('a8', 'd3', 30000, 'd30');
  r := pg_temp.dra('d1', 'a8', array[a.id]);
  q := pg_temp.rq(r);
  w := jsonb_build_object(
    'job', (select jsonb_build_array(j ->> 'number' = q.number, j ->> 'storage_path' = pg_temp.dra_path(q.id),
                                     j -> 'payload' = q.payload, j ->> 'template_version', j -> 'document_id')
            from (select private.repayment_request_job(q.id) as j) z),
    'unstored', pg_temp.attempt(format('select private.repayment_request_document_done(%L, %L, %L)', q.id,
                                       repeat('c', 64), 'reportlab-test')));
  v_doc := pg_temp.drawn(q.id);
  q := pg_temp.rq(r);
  return w || jsonb_build_object(
    'done', jsonb_build_array(q.document_id = v_doc, q.pdf_sha256 = repeat('c', 64), q.renderer_version),
    'document', (select jsonb_build_array(x.kind, x.storage_bucket, x.storage_path = pg_temp.dra_path(q.id),
                                          x.sha256 = repeat('c', 64), x.mime_type, x.file_name = q.number || '.pdf',
                                          x.client_organization_id = pg_temp.c('a8'),
                                          x.organization_id = '00000000-0000-0000-0000-0000000000aa')
                 from public.document x where x.id = v_doc),
    'again', pg_temp.drawn(q.id) = v_doc,
    'other_bytes', pg_temp.attempt(format('select private.repayment_request_document_done(%L, %L, %L)', q.id,
                                          repeat('d', 64), 'reportlab-test')),
    'job_after', (select private.repayment_request_job(q.id) ->> 'document_id' = v_doc::text),
    'grants', jsonb_build_array(
      has_function_privilege('authenticated', 'private.repayment_request_document_done(uuid, text, text)', 'execute'),
      has_function_privilege('authenticated', 'private.repayment_request_job(uuid)', 'execute'),
      has_function_privilege('service_role', 'private.repayment_request_document_done(uuid, text, text)', 'execute'),
      has_function_privilege('service_role', 'private.repayment_request_job(uuid)', 'execute'),
      has_function_privilege('authenticated', 'private.advance_repayment_payload(public.advance_repayment_request, uuid[])',
                             'execute'),
      has_function_privilege('authenticated', 'private.client_requested_advances(uuid, char)', 'execute'),
      has_function_privilege('anon', 'public.request_advance_repayment(text, uuid, char, uuid[], text)', 'execute'),
      has_function_privilege('authenticated', 'public.request_advance_repayment(text, uuid, char, uuid[], text)',
                             'execute'),
      has_function_privilege('authenticated', 'public.withdraw_advance_repayment_request(text, uuid, text)', 'execute')));
end $$;
select is(pg_temp.iso('sd1'),
  '{"job": [true, true, true, "demande-remboursement-avance-fr-1", null],
    "unstored": "repayment request document: the file is not stored at its key",
    "done": [true, true, "reportlab-test"],
    "document": ["advance_repayment_request_pdf", "documents", true, true, "application/pdf", true, true, true],
    "again": true, "other_bytes": "repayment request document: already drawn with other bytes", "job_after": true,
    "grants": [false, false, true, true, false, false, false, true, true]}'::jsonb,
  'd: the worker''s job reads the request (its number, key, frozen payload, template); its document is recorded once the '
  'file is stored at repayment-requests/<servicer>/<request>.pdf, with the bytes'' hash — again the same, never other '
  'bytes; the internals are the worker''s');


-- h. ([critic] F11) Who reads the request and its PDF ------------------------------------------------------------------
create or replace function pg_temp.sh() returns jsonb language plpgsql as $$
declare a public.client_advance; r jsonb; q public.advance_repayment_request; v_doc uuid;
begin
  a := pg_temp.adv('a8', 'd4', 30000, 'd40');
  r := pg_temp.dra('h1', 'a8', array[a.id]);
  q := pg_temp.rq(r);
  v_doc := pg_temp.drawn(q.id);
  return jsonb_build_object(
    'requests', (select jsonb_object_agg(u, pg_temp.try(u, 'select count(*) from public.advance_repayment_request'))
                 from unnest(array['01', '04', '03', '07', '08', '02', '05']) u),
    'items', (select jsonb_object_agg(u, pg_temp.try(u, 'select count(*) from public.advance_repayment_request_item'))
              from unnest(array['01', '04', '03', '07', '08', '02', '05']) u),
    'document', (select jsonb_object_agg(u, pg_temp.try(u, format('select count(*) from public.document where id = %L',
                                                                  v_doc)))
                 from unnest(array['01', '04', '03', '07', '08', '02', '05']) u),
    'object', (select jsonb_object_agg(u, pg_temp.try(u, format('select count(*) from storage.objects where name = %L',
                                                                pg_temp.dra_path(q.id))))
               from unnest(array['01', '03', '07', '08', '02']) u),
    'grants', jsonb_build_array(
      (select c.relrowsecurity from pg_class c where c.oid = 'public.advance_repayment_request'::regclass),
      (select c.relrowsecurity from pg_class c where c.oid = 'public.advance_repayment_request_item'::regclass),
      has_table_privilege('anon', 'public.advance_repayment_request', 'select'),
      has_table_privilege('authenticated', 'public.advance_repayment_request', 'insert'),
      has_table_privilege('authenticated', 'public.advance_repayment_request', 'update'),
      has_table_privilege('authenticated', 'public.advance_repayment_request_item', 'insert')));
end $$;
select is(pg_temp.iso('sh'),
  '{"requests": {"01": "1", "04": "1", "03": "1", "07": "0", "08": "0", "02": "0", "05": "0"},
    "items": {"01": "1", "04": "1", "03": "1", "07": "0", "08": "0", "02": "0", "05": "0"},
    "document": {"01": "1", "04": "1", "03": "1", "07": "0", "08": "0", "02": "0", "05": "0"},
    "object": {"01": "1", "03": "1", "07": "0", "08": "0", "02": "0"},
    "grants": [true, true, false, false, false, false]}'::jsonb,
  'h (F11): the request, its items and its PDF — row and file at repayment-requests/… — are read by money staff and '
  'the client''s whole-client members (Petit''s administrator), never by a restricted viewer, another client, a '
  'collector or another servicer; written only through the commands and the worker');


-- p. The pages: the preview, « Avances », the client's requests (staff and client space) -------------------------------
create or replace function pg_temp.sp() returns jsonb language plpgsql as $$
declare a public.client_advance; b public.client_advance; r jsonb; x jsonb; y jsonb; w jsonb;
        d date := private.paris_today();
begin
  a := pg_temp.adv('a8', 'd5', 30000, 'd50');
  b := pg_temp.adv('a8', 'd6', 10000, 'd60');
  x := pg_temp.read_as('01', format('select public.advance_repayment_preview(%L, ''EUR'', %L)', pg_temp.c('a8'),
                                    array[a.id, b.id]));
  w := jsonb_build_object(
    'preview', jsonb_build_array(x ->> 'total_minor', x -> 'refusal',
                                 (select jsonb_agg(jsonb_build_array(z ->> 'open_minor', z -> 'refusal') order by z ->> 'open_minor')
                                  from jsonb_array_elements(x -> 'rows') z)),
    'preview_client', pg_temp.read_as('03', format('select public.advance_repayment_preview(%L, ''EUR'', %L)',
                                                   pg_temp.c('a8'), array[a.id])) ->> 'error');
  r := pg_temp.dra('p1', 'a8', array[a.id, b.id]);
  x := pg_temp.read_as('01', format('select public.advance_repayment_preview(%L, ''EUR'', %L)', pg_temp.c('a8'),
                                    array[a.id]));
  w := w || jsonb_build_object(
    'preview_after', jsonb_build_array(x -> 'rows' -> 0 ->> 'refusal', x -> 'rows' -> 0 ->> 'detail' = d::text),
    'advances', (select jsonb_agg(jsonb_build_array(z -> 'request' ->> 'number' = r ->> 'number',
                                                    z -> 'request' ->> 'issue_date' = d::text) order by z ->> 'open_minor')
                 from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_advances(%L, %L)',
                                                                        '00000000-0000-0000-0000-0000000000aa',
                                                                        pg_temp.c('a8'))) -> 'rows') z));
  y := pg_temp.read_as('01', format('select public.client_repayment_requests(%L)', pg_temp.c('a8')));
  w := w || jsonb_build_object(
    'staff', (select jsonb_agg(jsonb_build_array(z ->> 'number' = r ->> 'number', z ->> 'issue_date' = d::text,
                                                 z ->> 'currency', z ->> 'total_minor', z -> 'withdrawn_on',
                                                 z -> 'document_id', jsonb_array_length(z -> 'advance_ids')))
              from jsonb_array_elements(y -> 'rows') z),
    'space', jsonb_build_array(
      jsonb_array_length(pg_temp.read_as('03', format('select public.client_repayment_requests(%L)', pg_temp.c('a8')))
                         -> 'rows'),
      pg_temp.read_as('07', format('select public.client_repayment_requests(%L)', pg_temp.c('a8'))) ->> 'error',
      pg_temp.read_as('08', format('select public.client_repayment_requests(%L)', pg_temp.c('a8'))) ->> 'error',
      pg_temp.read_as('02', format('select public.client_repayment_requests(%L)', pg_temp.c('a8'))) ->> 'error'));
  perform pg_temp.wd('p1', (r ->> 'request_id')::uuid);
  return w || jsonb_build_object(
    'withdrawn', (select z ->> 'withdrawn_on' = d::text
                  from jsonb_array_elements(pg_temp.read_as('03', format('select public.client_repayment_requests(%L)',
                                                                         pg_temp.c('a8'))) -> 'rows') z),
    'advances_after', (select jsonb_agg(z -> 'request')
                       from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_advances(%L, %L)',
                                                                              '00000000-0000-0000-0000-0000000000aa',
                                                                              pg_temp.c('a8'))) -> 'rows') z));
end $$;
select is(pg_temp.iso('sp'),
  '{"preview": ["40000", null, [["10000", null], ["30000", null]]], "preview_client": "not allowed",
    "preview_after": ["recently_requested", true], "advances": [[true, true], [true, true]],
    "staff": [[true, true, "EUR", "40000", null, null, 2]],
    "space": [1, "not allowed", "not allowed", "not allowed"], "withdrawn": true,
    "advances_after": [null, null]}'::jsonb,
  'p: the sheet''s preview gives the total from SQL and each advance''s refusal (staff only); « Avances » says « Demandé '
  'le »; the client''s requests read by staff and by the client''s whole-client members (never a restricted viewer, '
  'another client or a collector), with « Demande retirée le … » once withdrawn');


-- c. The nightly (§5.2.8) -----------------------------------------------------------------------------------------------
-- advance_open's requested_on (the last request not withdrawn); repayment_request_document_missing after one hour
create or replace function pg_temp.sc1() returns jsonb language plpgsql as $$
declare a public.client_advance; b public.client_advance; r jsonb; c uuid; w jsonb; d date := private.paris_today();
begin
  a := pg_temp.adv('a8', 'd7', 30000, 'd70');
  b := pg_temp.adv('a4', 'd8', 10000, 'd80');
  r := pg_temp.dra('c1', 'a8', array[a.id]);
  c := pg_temp.adv_run(d + 31, true);
  w := jsonb_build_object('requested_on', (select jsonb_agg(jsonb_build_array(x.amount_minor,
                                                                               x.details ->> 'requested_on' = d::text)
                                                             order by x.amount_minor)
                                           from public.payment_check_result x where x.run_id = c and x.code = 'advance_open'),
                          'missing_now', pg_temp.adv_rows('repayment_request_document_missing', (r ->> 'request_id')::uuid));
  perform pg_temp.dra_back((r ->> 'request_id')::uuid, d, now() - interval '59 minutes');
  w := w || jsonb_build_object('missing_59', pg_temp.adv_rows('repayment_request_document_missing',
                                                              (r ->> 'request_id')::uuid));
  perform pg_temp.dra_back((r ->> 'request_id')::uuid, d, now() - interval '61 minutes');
  w := w || jsonb_build_object('missing_61', pg_temp.adv_rows('repayment_request_document_missing',
                                                              (r ->> 'request_id')::uuid));
  perform pg_temp.drawn((r ->> 'request_id')::uuid);
  return w || jsonb_build_object('drawn', pg_temp.adv_rows('repayment_request_document_missing',
                                                           (r ->> 'request_id')::uuid));
end $$;
select is(pg_temp.iso('sc1'),
  '{"requested_on": [[10000, null], [30000, true]], "missing_now": [], "missing_59": [],
    "missing_61": [[true, 30000, "alert"]], "drawn": []}'::jsonb,
  'c: advance_open says the day the advance was last requested; a request whose letter is not drawn one hour after it '
  'was recorded → repayment_request_document_missing (alert), until its document is recorded');


-- x. The full list of codes run_advance_checks emits (043 #33, 044 h, 045 x; [critic] F12) -------------------------------
create or replace function pg_temp.sx() returns jsonb language plpgsql as $$
declare a public.client_advance; m public.client_advance; c uuid; r jsonb;
begin
  -- 7c-2: a request whose letter is not drawn after an hour (its command first: the raw reversal below would fail its
  -- commit checks); 7c-1's: a credit owed back, a 419 and a 7714 posting without their rows; 7a/7b's
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
  c := pg_temp.adv_run(private.paris_today() + 31, true);
  return (select jsonb_agg(distinct x.code order by x.code) from public.payment_check_result x where x.run_id = c);
end $$;
select is(pg_temp.iso('sx'),
  '["advance_ledger", "advance_open", "client_credit_ledger", "client_credit_owed", "remitted_reversal_uncovered",
    "repayment_request_document_missing", "written_off_recovery_ledger"]'::jsonb,
  'x (F12): run_advance_checks emits exactly advance_ledger, advance_open, client_credit_ledger, client_credit_owed, '
  'remitted_reversal_uncovered, repayment_request_document_missing, written_off_recovery_ledger (later slices extend '
  'this list)');


-- v. (review round 1, MONEY-1) A return never releases an advance a request names ----------------------------------------
-- 044 d's path: Roux's X debited d − 3, its payout returned d − 2, paid again by Y (d − 1); the bank executes X again (a
-- double payout: the advance, no clause → requested, its letter drawn); that execution comes back: refused
-- advance_requested while the request stands (the letter would ask for a payout the client did not keep), nothing booked;
-- booked once the request is withdrawn (the advance reversed)
create or replace function pg_temp.sv1() returns jsonb language plpgsql as $$
declare v_x uuid; v_t uuid; v_y uuid; a public.client_advance; w jsonb; v_parts jsonb; r jsonb;
        d date := private.paris_today();
begin
  v_x := pg_temp.remitted('a5', 'b0', 50000, 'b00', d - 3, d - 4);
  v_t := pg_temp.rtransfer(v_x);
  perform pg_temp.bounce(v_x, 'b01', d - 2);
  perform pg_temp.reconfirm('a5');
  v_y := pg_temp.flight('a5', 'v1');
  perform pg_temp.debit(v_y, 'b02', d - 1);
  w := jsonb_build_object('exec', pg_temp.late_exec(v_t, 'b03'));
  a := (select x from public.client_advance x where x.client_organization_id = pg_temp.c('a5') and x.cause = 'double_payout');
  r := pg_temp.dra('v1', 'a5', array[a.id]);
  perform pg_temp.drawn((r ->> 'request_id')::uuid);
  perform pg_temp.stmt2('b04', d, jsonb_build_array(jsonb_build_object(
    'dir', 'credit', 'kind', 'return', 'amount', 50000, 'orig', pg_temp.e2e(v_t))));
  v_parts := jsonb_build_array(pg_temp.pt('unplanned_payout_returned', v_t, 50000, null, pg_temp.l2('b03', 1)));
  -- (each read in its own statement: a stable function sees the snapshot of the statement that calls it)
  w := w || jsonb_build_object('request', pg_temp.why_not(r), 'why', pg_temp.why(pg_temp.l2('b04', 1), v_parts));
  w := w || jsonb_build_object('returned', pg_temp.bkx(pg_temp.l2('b04', 1), v_parts));
  w := w || jsonb_build_object('bookings', pg_temp.bookings(pg_temp.l2('b04', 1)), 'open', private.advance_open(a.id));
  perform pg_temp.wd('v1', (r ->> 'request_id')::uuid);
  w := w || jsonb_build_object('why_after', pg_temp.why(pg_temp.l2('b04', 1), v_parts));
  w := w || jsonb_build_object('returned_after', pg_temp.bkx(pg_temp.l2('b04', 1), v_parts));
  w := w || jsonb_build_object('open_after', private.advance_open(a.id));
  return w || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('sv1'),
  '{"exec": "ok", "request": "ok", "why": "advance_requested", "returned": "advance_requested", "bookings": [],
    "open": 50000, "why_after": "ok", "returned_after": "ok", "open_after": 0, "nightly": []}'::jsonb,
  'v (MONEY-1, switch off): the return of a double payout whose advance a request names is refused advance_requested '
  '(preview and booking), nothing booked; booked once the request is withdrawn');
select is(pg_temp.iso('sv1', true),
  '{"exec": "ok", "request": "ok", "why": "advance_requested", "returned": "advance_requested", "bookings": [],
    "open": 50000, "why_after": "ok", "returned_after": "ok", "open_after": 0, "nightly": []}'::jsonb,
  'v (MONEY-1, switch on): the same');
-- (switch on) n's 043 #11 path without the withdrawal first: the cover of what an unplanned payout paid of a released
-- item, requested; that payout back would release the cover: refused advance_requested until the request is withdrawn
create or replace function pg_temp.sv2() returns jsonb language plpgsql as $$
declare v_x uuid; a public.client_advance; w jsonb; r jsonb;
begin
  v_x := pg_temp.late_cancel('a4', 'b5', 40000, 'b50');
  w := jsonb_build_object('exec', pg_temp.late_exec(v_x, 'b51'));
  perform pg_temp.unalloc('b5');
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('b5')));
  r := pg_temp.dra('v2', 'a4', array[a.id]);
  perform pg_temp.drawn((r ->> 'request_id')::uuid);
  w := w || jsonb_build_object('request', pg_temp.why_not(r), 'returned', pg_temp.late_return(v_x, 'b52'));
  w := w || jsonb_build_object('bookings', pg_temp.bookings(pg_temp.l2('b52', 1)), 'open', private.advance_open(a.id));
  perform pg_temp.wd('v2', (r ->> 'request_id')::uuid);
  w := w || jsonb_build_object('returned_after', pg_temp.bkx(pg_temp.l2('b52', 1), pg_temp.prop(pg_temp.l2('b52', 1))));
  w := w || jsonb_build_object('open_after', private.advance_open(a.id));
  return w || jsonb_build_object('nightly', pg_temp.nightly());
end $$;
select is(pg_temp.iso('sv2', true),
  '{"exec": "ok", "request": "ok", "returned": "advance_requested", "bookings": [], "open": 40000,
    "returned_after": "ok", "open_after": 0, "nightly": []}'::jsonb,
  'v (MONEY-1, switch on): an unplanned payout''s return that would release a requested cover is refused '
  'advance_requested, nothing booked; booked (the cover released) once the request is withdrawn');


-- l. (review round 1, MONEY-2; plan §5.2.5, [critic] L16) A dedicated-account line naming its DRA-… --------------------
-- Petit owes a due invoice (18 000) and an advance (30 000) it was asked to repay (DRA-…); a line from its payout IBAN for
-- 30 000 labelled with that number designates the advance (C. civ. 1342-10 al. 1): the page names it, the booking needs
-- no other evidence and pays the advance, not the due invoice (whose VAT stays pending). A label naming another
-- client's DRA designates nothing
create or replace function pg_temp.sl() returns jsonb language plpgsql as $$
declare i uuid; a public.client_advance; b public.client_advance; r jsonb; r2 jsonb; l uuid; x jsonb; w jsonb;
        d date := private.paris_today();
begin
  i := pg_temp.inv('a8', 'b8', 100000, 'b80');
  perform pg_temp.issued(i, d - 10);
  perform pg_temp.due(i, d - 2);
  a := pg_temp.adv('a8', 'b9', 30000, 'b90');
  b := pg_temp.adv('a9', 'ba', 20000, 'ba0');
  r := pg_temp.dra('l1', 'a8', array[a.id]);
  r2 := pg_temp.dra('l2', 'a9', array[b.id]);
  l := pg_temp.ctin('bb0', 30000, pg_temp.iban_of('a8'), 'REMB ' || (r2 ->> 'number'), p_day => d);
  x := pg_temp.read_as('01', format('select public.client_payment_line(%L)', l));
  w := jsonb_build_object('other', jsonb_build_array(x -> 'named_documents', x -> 'named_requests'));
  -- a line of the day before the request (its number could not be quoted yet): names nothing
  l := pg_temp.ctin('bd0', 30000, pg_temp.iban_of('a8'), 'REMB ' || (r ->> 'number'), p_day => d - 1);
  x := pg_temp.read_as('01', format('select public.client_payment_line(%L)', l));
  w := w || jsonb_build_object('before', jsonb_build_array(x -> 'named_documents', x -> 'named_requests'));
  l := pg_temp.ctin('bc0', 30000, pg_temp.iban_of('a8'), 'REMBOURSEMENT ' || (r ->> 'number'), p_day => d);
  x := pg_temp.read_as('01', format('select public.client_payment_line(%L, %L)', l, array[a.id]));
  w := w || jsonb_build_object(
    'named', jsonb_build_array(x -> 'named_documents' = jsonb_build_array(a.id),
                               x -> 'named_requests' = jsonb_build_array(jsonb_build_object(
                                 'number', r ->> 'number', 'advance_ids', jsonb_build_array(a.id))),
                               x #> '{preview,refusal}'));
  x := pg_temp.cline('l3', l, array[a.id]);
  return w || jsonb_build_object(
    'booked', jsonb_build_array(x ? 'entry_id',
                                (select jsonb_agg(jsonb_build_array(s ->> 'document_kind', s ->> 'amount_minor'))
                                 from jsonb_array_elements(x -> 'settled') s)),
    'advance_open', private.advance_open(a.id), 'invoice_open', private.document_open(i),
    'pending_vat', private.document_pending_vat(i), 'requested', pg_temp.requested('a8'));
end $$;
select is(pg_temp.iso('sl'),
  '{"other": [[], []], "before": [[], []], "named": [true, true, null], "booked": [true, [["advance", "30000"]]],
    "advance_open": 0, "invoice_open": 18000, "pending_vat": 3000, "requested": []}'::jsonb,
  'l (MONEY-2, L16): a dedicated-account line whose label names the client''s DRA number designates its advances — '
  'named on the page, booked without other evidence, the advance paid, not the due invoice; another client''s DRA, '
  'or a line dated before the request, designates nothing');


-- c2. (review round 1, NIGHT-1, TUI-4, CC-1) A request withdrawn before its letter was drawn ---------------------------
-- its job draws nothing (the job says it is withdrawn; the document refused), the nightly alerts nothing (tonight, nor
-- in 60 days) — the remedy for a dead job (withdraw, request again) leaves no alert behind
create or replace function pg_temp.sc2() returns jsonb language plpgsql as $$
declare a public.client_advance; r jsonb; r2 jsonb; q uuid; j jsonb; d date := private.paris_today();
begin
  a := pg_temp.adv('a8', 'c0', 30000, 'c00');
  r := pg_temp.dra('c2', 'a8', array[a.id]);
  q := (r ->> 'request_id')::uuid;
  perform pg_temp.dra_back(q, d, now() - interval '2 hours');
  perform pg_temp.wd('c2', q);
  r2 := pg_temp.dra('c3', 'a8', array[a.id]);
  perform pg_temp.drawn((r2 ->> 'request_id')::uuid);
  j := private.repayment_request_job(q);
  return jsonb_build_object(
    'again', pg_temp.why_not(r2),
    'tonight', pg_temp.adv_rows('repayment_request_document_missing', q),
    'later', pg_temp.adv_rows('repayment_request_document_missing', q, d + 60),
    'job', jsonb_build_array(j ->> 'withdrawn_on' = d::text, j -> 'document_id'),
    'job_live', private.repayment_request_job((r2 ->> 'request_id')::uuid) -> 'withdrawn_on',
    'done', pg_temp.attempt(format('select pg_temp.drawn(%L)', q)),
    'document', (pg_temp.rq(r)).document_id);
end $$;
select is(pg_temp.iso('sc2'),
  '{"again": "ok", "tonight": [], "later": [], "job": [true, null], "job_live": null,
    "done": "repayment request document: the request was withdrawn before its letter was drawn", "document": null}'::jsonb,
  'c2 (NIGHT-1, TUI-4, CC-1): a request withdrawn before its letter was drawn gets no letter (its job says it is '
  'withdrawn, its document refused) and no alert, tonight or later');


-- w2. (review round 1, UI-1) The withdrawal of a reminder ----------------------------------------------------------------
-- A requested on day − 30, then again today (a reminder: a new request); the reminder withdrawn: its result names the
-- first request, which still asks for A; that one withdrawn: nothing still names it
create or replace function pg_temp.sw2() returns jsonb language plpgsql as $$
declare a public.client_advance; r1 jsonb; r2 jsonb; x jsonb; y jsonb; d date := private.paris_today();
begin
  a := pg_temp.adv('a8', 'bf', 30000, 'bf0');
  r1 := pg_temp.dra('w3', 'a8', array[a.id]);
  perform pg_temp.dra_back((r1 ->> 'request_id')::uuid, d - 30);
  r2 := pg_temp.dra('w4', 'a8', array[a.id]);
  x := pg_temp.wd('w4', (r2 ->> 'request_id')::uuid);
  return jsonb_build_object(
    'reminder', pg_temp.why_not(r2),
    'first', jsonb_build_array(x -> 'still_requested_by' = jsonb_build_array(r1 ->> 'number'),
                               (select q.request_id::text = r1 ->> 'request_id' from private.advance_live_request(a.id) q),
                               pg_temp.requested('a8') = jsonb_build_array(a.id)),
    'second', (pg_temp.wd('w3', (r1 ->> 'request_id')::uuid) -> 'still_requested_by'),
    'requested', pg_temp.requested('a8'));
end $$;
select is(pg_temp.iso('sw2'),
  '{"reminder": "ok", "first": [true, true, true], "second": [], "requested": []}'::jsonb,
  'w2 (UI-1): withdrawing a reminder says which request still asks for the advance (still_requested_by); withdrawing '
  'that one too, none');


-- h2. (review round 1, TUI-3, CC-2) The withdrawal's motif and the staff's ids stay the servicer's ---------------------
-- Petit's administrator reads its request's number, total, letter and withdrawal, never the motif nor who issued or
-- withdrew it (column privileges): permission denied; nor do the pages' reads return them
create or replace function pg_temp.sh2() returns jsonb language plpgsql as $$
declare a public.client_advance; r jsonb; q public.advance_repayment_request; y jsonb;
begin
  a := pg_temp.adv('a8', 'be', 30000, 'be0');
  r := pg_temp.dra('h2', 'a8', array[a.id]);
  q := pg_temp.rq(r);
  perform pg_temp.wd('h2', q.id, 'Client en difficulté, recouvrement jugé inutile (interne)');
  y := pg_temp.read_as('03', format('select public.client_repayment_requests(%L)', pg_temp.c('a8')));
  return jsonb_build_object(
    'client', jsonb_build_array(
      pg_temp.try('03', format('select withdrawal_reason from public.advance_repayment_request where id = %L', q.id)),
      pg_temp.try('03', format('select issued_by::text from public.advance_repayment_request where id = %L', q.id)),
      pg_temp.try('03', format('select withdrawn_by::text from public.advance_repayment_request where id = %L', q.id)),
      pg_temp.try('03', format('select (number = %L and total_minor = 30000 and withdrawn_at is not null '
                               '         and payload ->> ''number'' = %L)::text '
                               'from public.advance_repayment_request where id = %L', q.number, q.number, q.id))),
    'staff', pg_temp.try('01', format('select withdrawal_reason from public.advance_repayment_request where id = %L',
                                      q.id)),
    'columns', (select jsonb_agg(has_column_privilege('authenticated', 'public.advance_repayment_request', c, 'select')
                                 order by n)
                from unnest(array['withdrawal_reason', 'issued_by', 'withdrawn_by', 'number', 'payload', 'document_id',
                                  'withdrawn_at']) with ordinality u (c, n)),
    'space', jsonb_build_array(y -> 'rows' -> 0 ? 'withdrawal_reason', y -> 'rows' -> 0 ? 'withdrawn_on'),
    'service_role', has_column_privilege('service_role', 'public.advance_repayment_request', 'withdrawal_reason',
                                         'select'));
end $$;
select is(pg_temp.iso('sh2'),
  '{"client": ["permission denied for table advance_repayment_request",
               "permission denied for table advance_repayment_request",
               "permission denied for table advance_repayment_request", "true"],
    "staff": "permission denied for table advance_repayment_request",
    "columns": [false, false, false, true, true, true, true], "space": [false, true], "service_role": true}'::jsonb,
  'h2 (TUI-3, CC-2): the withdrawal''s motif and who issued or withdrew a request are not readable over the API (column '
  'privileges): the client''s members read the request, its letter and its withdrawal, never ops'' internal note');


-- b. (review round 1, TUI-6) A bank return's origin ------------------------------------------------------------------------
-- Petit's collection bd (40 000) remitted (debited d − 2), then taken back by the payer's bank today: in full (the debit
-- job's return), or in part (25 000 of 40 000, linked by ops: every allocation reversed) — the origin says bank_return,
-- dated by the return line, with what the bank took back when it was only part of the payment
create or replace function pg_temp.sb(p_return bigint) returns jsonb language plpgsql as $$
declare a public.client_advance; r jsonb; d date := private.paris_today();
begin
  perform pg_temp.remitted('a8', 'bd', 40000, 'bd0', d - 2, d - 3);
  perform pg_temp.stmt2('bd1', d, jsonb_build_array(jsonb_build_object('amount', p_return, 'kind', 'return',
                                                                         'e2e', 'E2E-bd')));
  if p_return = 40000 then
    perform pg_temp.job_returns(jsonb_build_array(jsonb_build_array(pg_temp.l2('bd1', 1), 'bd')));
  else
    perform pg_temp.link('link-key-bd', pg_temp.l2('bd1', 1), 'return', pg_temp.pay('bd'), null, '40000');
  end if;
  a := pg_temp.adv_of(pg_temp.rev(pg_temp.alloc('bd')));
  r := pg_temp.dra('b1', 'a8', array[a.id]);
  return (select jsonb_build_array(pg_temp.why_not(r), a.amount_minor, o ->> 'reversal', o ->> 'reversed_on' = d::text,
                                   o -> 'returned_minor', o ->> 'reversed_minor', o ->> 'paid_how',
                                   o ->> 'paid_on' = (d - 2)::text, o -> 'in_flight')
          from (select pg_temp.origin(r) as o) z);
end $$;
create or replace function pg_temp.sb1() returns jsonb language sql as $$ select pg_temp.sb(40000) $$;
create or replace function pg_temp.sb2() returns jsonb language sql as $$ select pg_temp.sb(25000) $$;
select is(pg_temp.iso('sb1'), '["ok", 40000, "bank_return", true, null, "40000", "paid", true, false]'::jsonb,
  'b (TUI-6): a payment the payer''s bank took back in full — its origin bank_return, dated by the return line');
select is(pg_temp.iso('sb2'), '["ok", 40000, "bank_return", true, "25000", "40000", "paid", true, false]'::jsonb,
  'b (TUI-6): taken back in part (25 000 of 40 000, every allocation reversed) — what the bank took back stated');


-- The switch is still off (no M2c-7 migration writes it) --------------------------------------------------------------------
select is(private.switch_on('downloaded_file_cancellation'), false,
  'the cancellation-after-download switch is still off');

select * from finish();
rollback;
